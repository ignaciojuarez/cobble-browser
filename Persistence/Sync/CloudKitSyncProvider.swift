import CloudKit
import Foundation
import Security

@MainActor
struct CloudKitSyncProvider: SyncProvider {
    let name = "iCloud"

    private let containerID = "iCloud.com.ignacio.cobble"
    private let recordType = "CobbleSyncRecord"
    private let payloadKey = "payload"

    enum ProviderError: LocalizedError {
        case missingEntitlement, accountUnavailable, wrongAccount, invalidCursor
        case corruptRecord, unexpectedDeletion, conflict

        var errorDescription: String? {
            switch self {
            case .missingEntitlement: String(localized: "This Cobble build has no iCloud sync entitlement.")
            case .accountUnavailable: String(localized: "Sign in to iCloud to sync Cobble.")
            case .wrongAccount: String(localized: "The iCloud account changed. Reset sync state before continuing.")
            case .invalidCursor: String(localized: "The saved iCloud sync cursor is invalid.")
            case .corruptRecord: String(localized: "An iCloud sync record is invalid.")
            case .unexpectedDeletion: String(localized: "A sync record was removed from iCloud outside Cobble.")
            case .conflict: String(localized: "An iCloud record changed repeatedly during sync.")
            }
        }
    }

    private struct Cursor: Codable {
        let accountID: String
        let module: SyncModule
        let token: Data
    }

    private func checkedContainer() throws -> CKContainer {
        try Task.checkCancellation()
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
              services.contains("CloudKit"),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              containers.contains(containerID) else {
            throw ProviderError.missingEntitlement
        }
        return CKContainer(identifier: containerID)
    }

    func retryError(_ error: Error) -> Error {
        guard let cloud = error as? CKError else { return error }
        let delays = [cloud.retryAfterSeconds].compactMap { $0 } +
            (cloud.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.retryAfterSeconds } ?? [])
        guard let seconds = delays.max() else { return error }
        return SyncRetryFailure(message: error.localizedDescription,
                                retryAfter: Date().addingTimeInterval(max(0, seconds)))
    }

    func accountID() async throws -> String {
        do { return try await currentAccountID() }
        catch { throw retryError(error) }
    }

    private func currentAccountID() async throws -> String {
        let container = try checkedContainer()
        guard try await container.accountStatus() == .available else {
            throw ProviderError.accountUnavailable
        }
        try Task.checkCancellation()
        let id = try await container.userRecordID().recordName
        try Task.checkCancellation()
        return id
    }

    private func zoneID(_ module: SyncModule) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "cobble-\(module.rawValue)")
    }

    private func database() throws -> CKDatabase {
        try checkedContainer().privateCloudDatabase
    }

    private func requireAccount(_ expectedAccountID: String) async throws {
        try Task.checkCancellation()
        guard try await accountID() == expectedAccountID else { throw ProviderError.wrongAccount }
        try Task.checkCancellation()
    }

    private func ensureZone(_ module: SyncModule, in database: CKDatabase, createIfMissing: Bool = true, expectedAccountID: String) async throws {
        let id = zoneID(module)
        do {
            _ = try await database.recordZone(for: id)
        } catch let error as CKError where error.code == .zoneNotFound {
            guard createIfMissing else { throw ProviderError.unexpectedDeletion }
            try await requireAccount(expectedAccountID)
            _ = try await database.save(CKRecordZone(zoneID: id))
        }
    }

    func fetchChanges(module: SyncModule, cursor: Data?, expectedAccountID: String) async throws -> SyncBatch {
        do { return try await fetch(module: module, cursor: cursor, expectedAccountID: expectedAccountID) }
        catch { throw retryError(error) }
    }

    private func fetch(module: SyncModule, cursor: Data?, expectedAccountID: String) async throws -> SyncBatch {
        var token: CKServerChangeToken?
        if let cursor {
            let saved = try JSONDecoder().decode(Cursor.self, from: cursor)
            guard saved.accountID == expectedAccountID else { throw ProviderError.wrongAccount }
            guard saved.module == module else { throw ProviderError.invalidCursor }
            token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: saved.token)
            guard token != nil else { throw ProviderError.invalidCursor }
        }

        try await requireAccount(expectedAccountID)
        let database = try database()
        try await ensureZone(module, in: database, createIfMissing: cursor == nil, expectedAccountID: expectedAccountID)
        try await requireAccount(expectedAccountID)

        var records: [SyncRecord] = []
        var restarted = false
        while true {
            try Task.checkCancellation()
            let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                page = try await database.recordZoneChanges(inZoneWith: zoneID(module), since: token)
            } catch let error as CKError where error.code == .changeTokenExpired && !restarted {
                token = nil
                records.removeAll()
                restarted = true
                continue
            }
            try Task.checkCancellation()
            guard page.deletions.isEmpty else { throw ProviderError.unexpectedDeletion }
            for (_, result) in page.modificationResultsByID {
                let record = try result.get().record
                records.append(try decode(record, module: module))
            }
            try await requireAccount(expectedAccountID)
            token = page.changeToken
            if !page.moreComing { break }
        }
        guard let token else { throw ProviderError.invalidCursor }
        let archived = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        let nextCursor = try JSONEncoder().encode(Cursor(accountID: expectedAccountID, module: module, token: archived))
        return SyncBatch(records: records, cursor: nextCursor)
    }

    func save(_ records: [SyncRecord], module: SyncModule, expectedAccountID: String) async throws -> [SyncRecord] {
        do { return try await upload(records, module: module, expectedAccountID: expectedAccountID) }
        catch { throw retryError(error) }
    }

    private func upload(_ records: [SyncRecord], module: SyncModule, expectedAccountID: String) async throws -> [SyncRecord] {
        guard Set(records.map(\.id)).count == records.count else { throw ProviderError.corruptRecord }
        for record in records {
            guard record.module == module else { throw ProviderError.corruptRecord }
            _ = try record.validated()
        }
        try await requireAccount(expectedAccountID)
        let database = try database()
        try await ensureZone(module, in: database, expectedAccountID: expectedAccountID)
        try await requireAccount(expectedAccountID)
        var saved: [String: SyncRecord] = [:]
        // Each merged record may grow to 500 KB; four leave room for CloudKit metadata.
        for start in stride(from: 0, to: records.count, by: 4) {
            var pending = Dictionary(uniqueKeysWithValues: records[start..<min(start + 4, records.count)].map { ($0.id, $0) })
            for attempt in 0..<5 where !pending.isEmpty {
                try await requireAccount(expectedAccountID)
                let ids = pending.keys.map { CKRecord.ID(recordName: $0, zoneID: zoneID(module)) }
                let fetched = try await database.records(for: ids)
                try await requireAccount(expectedAccountID)
                var uploads: [CKRecord] = []
                for id in ids {
                    guard let original = pending[id.recordName], let result = fetched[id] else { throw ProviderError.corruptRecord }
                    let cloud: CKRecord?
                    switch result {
                    case .success(let value): cloud = value
                    case .failure(let error as CKError) where error.code == .unknownItem: cloud = nil
                    case .failure(let error): throw error
                    }
                    let candidate = try cloud.map { try original.merged(with: decode($0, module: module)) } ?? original
                    let upload = cloud ?? CKRecord(recordType: recordType, recordID: id)
                    upload.encryptedValues[payloadKey] = try JSONEncoder().encode(candidate) as NSData
                    uploads.append(upload)
                }
                try await requireAccount(expectedAccountID)
                let response = try await database.modifyRecords(saving: uploads, deleting: [],
                                                                savePolicy: .ifServerRecordUnchanged, atomically: false)
                try await requireAccount(expectedAccountID)
                for id in ids {
                    guard let result = response.saveResults[id] else { throw ProviderError.corruptRecord }
                    switch result {
                    case .success(let value):
                        saved[id.recordName] = try decode(value, module: module)
                        pending.removeValue(forKey: id.recordName)
                    case .failure(let error as CKError) where error.code == .serverRecordChanged || error.code == .unknownItem:
                        if attempt == 4 { throw ProviderError.conflict }
                    case .failure(let error): throw error
                    }
                }
            }
        }
        guard saved.count == records.count else { throw ProviderError.conflict }
        return try records.map { record in
            guard let result = saved[record.id] else { throw ProviderError.corruptRecord }
            return result
        }
    }

    private func decode(_ record: CKRecord, module: SyncModule) throws -> SyncRecord {
        guard record.recordType == recordType,
              let data = record.encryptedValues[payloadKey] as? Data else {
            throw ProviderError.corruptRecord
        }
        let value = try JSONDecoder().decode(SyncRecord.self, from: data)
        guard value.id == record.recordID.recordName, value.module == module else {
            throw ProviderError.corruptRecord
        }
        return try value.validated()
    }
}
