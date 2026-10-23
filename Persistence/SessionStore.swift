import Foundation

/// All disk access and mutable state are confined to queue.
final class SessionStore: @unchecked Sendable {
    struct LoadResult: Sendable {
        var snapshot: SessionSnapshot?
        var message: String?
        var canSave: Bool
    }

    private struct Version: Decodable { var version: Int? }
    private enum ReadResult {
        case missing, valid(SessionSnapshot, Data, migrated: Bool), corrupt(Data), future(Int), inaccessible(String)
    }

    let directory: URL
    var url: URL { directory.appendingPathComponent("session.json") }
    var backupURL: URL { directory.appendingPathComponent("session.backup.json") }
    private let queue = DispatchQueue(label: "com.ignacio.cobble.session", qos: .utility)
    private var loaded = false
    private var canSave = true
    private var lastValidData: Data?
    /// Value known to be in the primary file; nil after recovering from the backup.
    /// Compared by value: JSON bytes vary with Set/Dictionary iteration order.
    private var primarySnapshot: SessionSnapshot?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cobble", isDirectory: true)
    }

    var allowsSaving: Bool { queue.sync { canSave } }
    func load() -> LoadResult { queue.sync { loadLocked() } }
    func flush() { queue.sync {} }

    /// Autosaves skip a snapshot already in the primary file; explicit and final saves always write, surfacing disk failures.
    func save(_ snapshot: SessionSnapshot, skippingUnchanged: Bool = false, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in completion(saveLocked(snapshot, skippingUnchanged: skippingUnchanged)) }
    }

    func saveSynchronously(_ snapshot: SessionSnapshot) -> String? { queue.sync { saveLocked(snapshot) } }

    func save(_ snapshot: SessionSnapshot) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            save(snapshot) { continuation.resume(returning: $0) }
        }
    }

    private func saveLocked(_ snapshot: SessionSnapshot, skippingUnchanged: Bool = false) -> String? {
        if !loaded { _ = loadLocked() }
        guard canSave else { return String(localized: "Session saving is disabled to preserve unreadable or newer session data.") }
        guard snapshot.version == SessionSnapshot.currentVersion else { return String(localized: "Unsupported session version.") }
        do {
            let validated = snapshot.validated()
            // Unchanged autosaves skip both writes and keep the last distinct backup.
            if skippingUnchanged, validated == primarySnapshot { return nil }
            let data = try JSONEncoder().encode(validated)
            if let lastValidData { try PersistenceFile.write(lastValidData, to: backupURL) }
            try PersistenceFile.write(data, to: url)
            lastValidData = data
            primarySnapshot = validated
            return nil
        } catch {
            return String(format: String(localized: "Could not save the session: %@"), error.localizedDescription)
        }
    }

    /// Explicit imports keep a separate recovery copy, unaffected by subsequent autosaves.
    func replace(with snapshot: SessionSnapshot, preserving current: SessionSnapshot) throws {
        try queue.sync {
            if !loaded { _ = loadLocked() }
            guard canSave, snapshot.version == SessionSnapshot.currentVersion else { throw CocoaError(.fileWriteNoPermission) }
            let encoder = JSONEncoder()
            try PersistenceFile.save(current.validated(), to: directory.appendingPathComponent("workspace-before-restore.json"))
            let validated = snapshot.validated()
            let data = try encoder.encode(validated)
            if let lastValidData { try PersistenceFile.write(lastValidData, to: backupURL) }
            try PersistenceFile.write(data, to: url)
            lastValidData = data
            primarySnapshot = validated
        }
    }

    private func read(_ url: URL) -> ReadResult {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .missing }
        catch { return .inaccessible(error.localizedDescription) }
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(Version.self, from: data).version
            if let version, version > SessionSnapshot.currentVersion { return .future(version) }
            return .valid(try SessionSnapshot.decode(data), data, migrated: version != SessionSnapshot.currentVersion)
        } catch { return .corrupt(data) }
    }

    private func loadLocked() -> LoadResult {
        loaded = true
        let primary = read(url)
        let backup = read(backupURL)
        // Inspect both: an older app must never overwrite any newer schema it finds.
        for result in [primary, backup] {
            switch result {
            case let .future(version):
                canSave = false
                return LoadResult(message: String(format: String(localized: "This session uses version %@, which requires a newer Cobble. Existing files were preserved."), "\(version)"), canSave: false)
            case let .inaccessible(reason):
                canSave = false
                return LoadResult(message: String(format: String(localized: "The session could not be read: %@. Existing files were preserved."), reason), canSave: false)
            default: break
            }
        }
        canSave = true
        lastValidData = nil
        primarySnapshot = nil
        var recoveredCorruption = false
        do {
            for (result, name) in [(primary, "session"), (backup, "session.backup")] {
                if case let .corrupt(data) = result {
                    try PersistenceFile.preserve(data, in: directory, prefix: "\(name).corrupt")
                    recoveredCorruption = true
                }
            }
        } catch {
            canSave = false
            return LoadResult(message: String(format: String(localized: "Damaged session data could not be preserved: %@. Saving is disabled."), error.localizedDescription), canSave: false)
        }
        if case let .valid(snapshot, data, migrated) = primary {
            lastValidData = data
            primarySnapshot = snapshot
            let message = migrated ? String(localized: "The previous session was migrated; its original data will be retained as a backup.") :
                (recoveredCorruption ? String(localized: "A damaged backup was preserved separately.") : nil)
            return LoadResult(snapshot: snapshot, message: message, canSave: true)
        }
        if case let .valid(snapshot, data, _) = backup {
            lastValidData = data
            return LoadResult(snapshot: snapshot, message: String(localized: "The session was recovered from its last valid backup. Any damaged data was preserved separately."), canSave: true)
        }
        return LoadResult(message: recoveredCorruption ? String(localized: "The damaged session was preserved separately. A new session can be started.") : nil, canSave: true)
    }
}
