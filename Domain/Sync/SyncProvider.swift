import Foundation

/// Categories are independent transport scopes. Profile-bound categories depend on organization.
enum SyncModule: String, Codable, CaseIterable, Sendable {
    case organization, bookmarks, openTabs, history, preferences, siteSettings, contentBlockers
    var requiresOrganization: Bool { self != .organization && self != .preferences }
    var title: String {
        switch self {
        case .contentBlockers: String(localized: "Content blockers")
        case .organization: String(localized: "Spaces, pins, and favorites")
        case .bookmarks: String(localized: "Bookmarks")
        case .openTabs: String(localized: "Open tabs")
        case .history: String(localized: "History")
        case .preferences: String(localized: "Search and shortcuts")
        case .siteSettings: String(localized: "Site zoom")
        }
    }
    var detail: String {
        switch self {
        case .contentBlockers: String(localized: "Sync blocking preferences and exceptions for matching web engines.")
        case .organization: String(localized: "Includes folders and profile names. Website logins stay on each device.")
        case .bookmarks: String(localized: "Keep your saved library bookmarks available on every device.")
        case .openTabs: String(localized: "Keep tabs in your spaces in sync. Opening or closing a tab updates your other devices.")
        case .history: String(localized: "Include browsing history. Private browsing is never included.")
        case .preferences: String(localized: "Sync search engines, keyboard shortcuts, and tab behavior.")
        case .siteSettings: String(localized: "Remember website zoom levels. Website permissions stay on this Mac.")
        }
    }
}

/// A portable projection. Never put engine storage, secrets, or native objects here.
struct SyncItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var module: SyncModule
    var kind: String
    var fields: [String: String]
}

struct SyncStamp: Codable, Equatable, Comparable, Sendable {
    var counter: Int64
    var deviceID: String
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.deviceID < rhs.deviceID : lhs.counter < rhs.counter
    }
}
struct SyncField: Codable, Equatable, Sendable {
    var value: String?
    var stamp: SyncStamp
}

/// Field registers preserve unrelated concurrent edits and fields from newer clients.
/// Deletion wins over edits that have not observed it. Explicit recreation acknowledges the deletion.
struct SyncRecord: Codable, Equatable, Sendable {
    var id: String
    var module: SyncModule
    var kind: String
    var version: Int = 1
    var fields: [String: SyncField] = [:]
    var tombstone: SyncStamp?

    var isDeleted: Bool {
        guard let tombstone else { return false }
        guard let restored = fields["_restored"], restored.stamp > tombstone else { return true }
        return restored.value != "\(tombstone.counter):\(tombstone.deviceID)"
    }
    var item: SyncItem? {
        guard !isDeleted else { return nil }
        return SyncItem(id: id, module: module, kind: kind,
                        fields: fields.filter { $0.key != "_restored" }.compactMapValues(\.value))
    }
    var counter: Int64 { max(fields.values.map(\.stamp.counter).max() ?? 0, tombstone?.counter ?? 0) }
    func validated() throws -> Self {
        guard version == 1, !id.isEmpty, id.utf8.count <= 200, !kind.isEmpty,
              tombstone.map({ $0.counter >= 0 && !$0.deviceID.isEmpty }) ?? true,
              fields.count <= 100, fields.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 100 &&
                  ($0.value.value?.utf8.count ?? 0) <= 100_000 && $0.value.stamp.counter >= 0 &&
                  !$0.value.stamp.deviceID.isEmpty }), counter < Int64.max - 1,
              (try JSONEncoder().encode(self)).count <= 500_000 else { throw SyncFailure.invalidRecord }
        return self
    }
    func merged(with other: Self) throws -> Self {
        _ = try validated(); _ = try other.validated()
        guard id == other.id, module == other.module, kind == other.kind else { throw SyncFailure.invalidRecord }
        var result = self
        for (key, field) in other.fields {
            if let current = result.fields[key] {
                if current.stamp < field.stamp { result.fields[key] = field }
                else if current.stamp == field.stamp, current.value != field.value { throw SyncFailure.invalidRecord }
            } else { result.fields[key] = field }
        }
        if let deleted = other.tombstone, result.tombstone.map({ $0 < deleted }) ?? true { result.tombstone = deleted }
        return try result.validated()
    }
}
struct SyncBatch: Sendable {
    var records: [SyncRecord]
    var cursor: Data?
}

/// No CloudKit types cross this boundary. A provider owns authentication, opaque cursors,
/// conditional writes, and retries of server conflicts; the coordinator owns local data.
@MainActor protocol SyncProvider {
    var name: String { get }
    func accountID() async throws -> String
    func fetchChanges(module: SyncModule, cursor: Data?, expectedAccountID: String) async throws -> SyncBatch
    func save(_ records: [SyncRecord], module: SyncModule, expectedAccountID: String) async throws -> [SyncRecord]
}

/// Providers surface server backoff without leaking transport types to the coordinator.
struct SyncRetryFailure: LocalizedError {
    let message: String
    let retryAfter: Date
    var errorDescription: String? { message }
}

enum SyncFailure: LocalizedError {
    case invalidRecord, unavailable(String), localWrite(String)
    var errorDescription: String? {
        switch self {
        case .invalidRecord: String(localized: "Sync received unsupported or invalid data. Update Cobble before trying again.")
        case .unavailable(let message), .localWrite(let message): message
        }
    }
}
