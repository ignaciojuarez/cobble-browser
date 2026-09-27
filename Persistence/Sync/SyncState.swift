import Foundation

/// The journal is committed before uploading and before advancing a provider cursor.
/// ponytail: retain tombstones until a device-expiry protocol can compact them safely.
struct SyncState: Codable {
    var version = 1
    var deviceID = UUID().uuidString
    var accountID: String?
    var accountChanged = false
    var enabled = false
    var modules: Set<SyncModule> = [.organization, .bookmarks]
    var counter: Int64 = 0
    var records: [String: SyncRecord] = [:]
    var baseline: [String: SyncItem] = [:]
    var pending: Set<String> = []
    var initialized: Set<SyncModule> = []
    var resuming: Set<SyncModule> = []
    var cursors: [SyncModule: Data] = [:]
    var lastSync: Date?

    mutating func stamp() throws -> SyncStamp {
        guard counter < Int64.max - 1 else { throw SyncFailure.invalidRecord }
        counter += 1
        return SyncStamp(counter: counter, deviceID: deviceID)
    }

    mutating func merge(_ incoming: SyncRecord) throws {
        _ = try incoming.validated()
        let merged = try records[incoming.id].map { try $0.merged(with: incoming) } ?? incoming
        counter = max(counter, incoming.counter)
        records[incoming.id] = merged
    }

    mutating func capture(_ items: [SyncItem], module: SyncModule, seed: Bool = false,
                          allowDeletions: Bool = true, retainAbsent: Set<String> = []) throws {
        var next = self
        try next.captureValidated(items, module: module, seed: seed,
                                  allowDeletions: allowDeletions, retainAbsent: retainAbsent)
        self = next
    }

    private mutating func captureValidated(_ items: [SyncItem], module: SyncModule, seed: Bool,
                                           allowDeletions: Bool, retainAbsent: Set<String>) throws {
        guard Set(items.map(\.id)).count == items.count else { throw SyncFailure.invalidRecord }
        let local = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            guard item.module == module else { throw SyncFailure.invalidRecord }
            let previous = baseline[item.id]
            if seed, records[item.id] != nil { continue }
            guard previous != item else { continue }
            var record = records[item.id] ?? SyncRecord(id: item.id, module: module, kind: item.kind)
            guard record.module == module, record.kind == item.kind else { throw SyncFailure.invalidRecord }
            let keys = Set(item.fields.keys).union(previous?.fields.keys.map { $0 } ?? [])
            let changed = keys.filter {
                previous?.fields[$0] != item.fields[$0] && record.fields[$0]?.value != item.fields[$0]
            }
            let recreating = record.isDeleted && previous == nil
            if record.isDeleted && !recreating { continue }
            guard !changed.isEmpty || recreating else { continue }
            let revision = try stamp()
            if recreating, let deletion = record.tombstone {
                // Only a local addition after observing deletion may recreate the identity.
                record.fields["_restored"] = SyncField(value: "\(deletion.counter):\(deletion.deviceID)", stamp: revision)
            }
            for key in changed {
                record.fields[key] = SyncField(value: item.fields[key], stamp: revision)
            }
            records[item.id] = try record.validated()
            pending.insert(item.id)
        }
        // History retention is device-local. Explicit user deletions enter through delete().
        if !seed, allowDeletions, module != .history {
            let removed = baseline.values.filter {
                $0.module == module && local[$0.id] == nil && !retainAbsent.contains($0.id)
            }.map(\.id)
            try delete(removed)
        }
        baseline = baseline.filter { $0.value.module != module || retainAbsent.contains($0.key) }
        baseline.merge(local) { _, new in new }
    }

    mutating func delete(_ ids: [String]) throws {
        for id in ids {
            guard var record = records[id], !record.isDeleted else { continue }
            record.tombstone = try stamp()
            records[id] = record
            pending.insert(id)
        }
    }
}
