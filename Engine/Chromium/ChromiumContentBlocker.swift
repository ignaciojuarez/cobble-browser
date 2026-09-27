#if COBBLE_CHROMIUM_ABI4
import Foundation
import Observation
import CobbleChromium

/// Chromium owns matching through a script-free native rules extension.
/// User extensions and their site grants remain separately managed.
@MainActor @Observable final class ChromiumContentBlocker: EngineContentBlocker {
    let formatName = "Chromium block/allow JSON · Normal windows"
    var lastError: String?
    var onChange: (() -> Void)?
    var profileMutationAllowed: ((UUID) -> Bool)?
    var isReady: Bool { true }
    var canPersistRules: Bool { writable }
    private struct Configuration: Codable {
        var profileID: UUID
        var json: String
        var enabled = true
        var exceptions: [String] = []
        var source: URL?
    }
    private struct Snapshot: Codable { var version = 1; var configurations: [Configuration] }
    private var configurations: [UUID: Configuration] = [:]
    private var failed = Set<UUID>()
    private var installed: [UUID: String] = [:]
    private var writable = true
    @ObservationIgnored private var operations: [UUID: (UUID, Task<Void, Error>)] = [:]
    @ObservationIgnored private unowned let engine: ChromiumEngine
    @ObservationIgnored private let runtime: ChromiumRuntime
    @ObservationIgnored private let root: URL
    private var settingsURL: URL { root.appendingPathComponent("settings.json") }

    init(engine: ChromiumEngine, runtime: ChromiumRuntime, directory: URL) {
        self.engine = engine
        self.runtime = runtime
        root = directory.appendingPathComponent("ChromiumContentRules", isDirectory: true)
        do {
            guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: settingsURL))
            guard snapshot.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            for configuration in snapshot.configurations {
                guard configurations[configuration.profileID] == nil,
                      configuration.source.map(Self.validSource) ?? true,
                      Set(configuration.exceptions).count == configuration.exceptions.count,
                      configuration.exceptions.allSatisfy({ URL(string: $0).flatMap(AddressResolver.canonicalOrigin) == $0 }) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                _ = try ChromiumBlockingRules.files(json: configuration.json, exceptions: configuration.exceptions)
                configurations[configuration.profileID] = configuration
            }
        } catch {
            writable = false
            configurations = [:]
            lastError = "Chromium content rules could not be read. The original is untouched and changes are disabled: \(error.localizedDescription)"
        }
    }

    func waitUntilReady() async {}
    func isEnabled(profileID: UUID) -> Bool { configurations[profileID]?.enabled ?? false }
    func hasRules(profileID: UUID) -> Bool { configurations[profileID] != nil }
    func usesBundledRules(profileID: UUID) -> Bool {
        configurations[profileID]?.json == ChromiumBlockingRules.bundledJSON && configurations[profileID]?.source == nil
    }
    func useBundledRules(profileID: UUID) async {
        if hasRules(profileID: profileID) { await importRules(json: ChromiumBlockingRules.bundledJSON, profileID: profileID) }
        else { await installBundledRules(profileID: profileID) }
    }
    func exceptions(profileID: UUID) -> [String] { configurations[profileID]?.exceptions ?? [] }
    func updateSource(profileID: UUID) -> URL? { configurations[profileID]?.source }
    func canLoad(profileID: UUID) -> Bool { writable && !failed.contains(profileID) }

    /// Run before a normal page navigates. Private contexts never install extensions.
    func prepare(profileID: UUID) async throws {
        if let operation = operations[profileID] { try await operation.1.value }
        guard canLoad(profileID: profileID) else {
            throw EngineError.notReady(lastError ?? "Chromium content rules could not load.")
        }
        guard installed[profileID] == nil else { return }
        try await enqueue(profileID) { $0 ?? Configuration(profileID: profileID, json: ChromiumBlockingRules.bundledJSON) }
    }

    func contextDidClose(_ profileID: UUID) { installed.removeValue(forKey: profileID) }

    func importRules(json: String, profileID: UUID) async {
        await change(profileID) { previous in
            var next = previous ?? Configuration(profileID: profileID, json: json)
            next.json = json
            next.source = nil
            return next
        }
    }
    func installBundledRules(profileID: UUID) async {
        await change(profileID) { previous in
            guard previous == nil else { throw EngineError.notReady("This profile already has rules. Import a replacement to change them.") }
            return Configuration(profileID: profileID, json: ChromiumBlockingRules.bundledJSON)
        }
    }
    func ensureBundledRules(profileID: UUID) async {
        guard !hasRules(profileID: profileID) else { return }
        do { try await prepare(profileID: profileID) }
        catch { lastError = error.localizedDescription; onChange?() }
    }
    func setEnabled(_ enabled: Bool, profileID: UUID) async {
        await change(profileID) { previous in
            guard var next = previous else { throw EngineError.notReady("Install or import content rules first.") }
            next.enabled = enabled
            return next
        }
    }
    func setException(origin: URL, enabled: Bool, profileID: UUID) async {
        await change(profileID) { previous in
            guard var next = previous, let origin = AddressResolver.canonicalOrigin(origin) else {
                throw EngineError.notReady("Content rules require a valid HTTP or HTTPS origin.")
            }
            next.exceptions.removeAll { $0 == origin }
            if enabled { next.exceptions.append(origin) }
            next.exceptions.sort()
            return next
        }
    }
    func replaceExceptions(_ origins: [String], profileID: UUID) async throws {
        guard origins.count <= 1000, Set(origins).count == origins.count,
              origins.allSatisfy({ URL(string: $0).flatMap(AddressResolver.canonicalOrigin) == $0 }) else {
            throw EngineError.notReady("Invalid content blocker exception.")
        }
        let desired = origins.sorted()
        guard configurations[profileID]?.exceptions != desired else { return }
        try await enqueue(profileID) { previous in
            guard var next = previous else { throw EngineError.notReady("Install or import content rules first.") }
            next.exceptions = desired
            return next
        }
    }
    func setUpdateSource(_ source: URL?, profileID: UUID) async {
        await change(profileID) { previous in
            guard var next = previous else { throw EngineError.notReady("Install or import content rules first.") }
            guard source.map(Self.validSource) ?? true else {
                throw EngineError.notReady("Update sources must be HTTPS addresses without credentials or fragments.")
            }
            next.source = source
            return next
        }
    }
    func updateRules(profileID: UUID) async {
        guard let source = updateSource(profileID: profileID) else {
            lastError = "Choose an HTTPS update source first."
            return
        }
        do {
            let json = try await downloadContentRules(from: source)
            guard !Task.isCancelled else { return }
            await change(profileID) { previous in
                guard var next = previous, next.source == source else {
                    throw EngineError.notReady("The update source changed. Run Update Now again.")
                }
                next.json = json
                return next
            }
        } catch { lastError = "Could not update rules. Existing rules are unchanged: \(error.localizedDescription)"; onChange?() }
    }

    func installRules(from source: URL, profileID: UUID) async throws {
        guard Self.validSource(source) else {
            throw EngineError.notReady(String(localized: "Update sources must be HTTPS addresses without credentials or fragments."))
        }
        let previousSource = configurations[profileID]?.source
        let json = try await downloadContentRules(from: source)
        try Task.checkCancellation()
        try await enqueue(profileID) { previous in
            guard previous?.source == previousSource else { throw EngineError.closed }
            var next = previous ?? Configuration(profileID: profileID, json: json)
            next.json = json
            next.source = source
            return next
        }
    }

    func removeProfile(_ profileID: UUID) async throws {
        if let operation = operations[profileID] { try await operation.1.value }
        guard writable else { throw EngineError.notReady(lastError ?? "Content-rule changes are disabled.") }
        if let context = engine.normalContext(profileID), !context.isClosed {
            // Profile deletion closes native contexts first; do not reopen one for cleanup.
            throw EngineError.notReady("Close the Chromium profile before removing its content rules.")
        }
        var next = configurations
        next.removeValue(forKey: profileID)
        try persist(next)
        configurations = next
        installed.removeValue(forKey: profileID)
        failed.remove(profileID)
        let directory = ruleDirectory(profileID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        onChange?()
    }

    private func change(_ profileID: UUID, _ transform: @escaping (Configuration?) throws -> Configuration) async {
        do { try await enqueue(profileID, transform) }
        catch { lastError = error.localizedDescription; onChange?() }
    }

    private func enqueue(_ profileID: UUID, _ transform: @escaping (Configuration?) throws -> Configuration) async throws {
        let previous = operations[profileID]?.1
        let id = UUID()
        let task = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            guard self.writable, self.profileMutationAllowed?(profileID) != false else {
                throw EngineError.notReady(self.lastError ?? "Content-rule changes are unavailable while this profile is being deleted.")
            }
            try await self.replace(try transform(self.configurations[profileID]))
        }
        operations[profileID] = (id, task)
        defer { if operations[profileID]?.0 == id { operations.removeValue(forKey: profileID) } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func replace(_ next: Configuration) async throws {
        let files = try ChromiumBlockingRules.files(json: next.json, exceptions: next.exceptions)
        let previous = configurations[next.profileID]
        let directory = ruleDirectory(next.profileID)
        let context = try await engine.extensionContext(next.profileID).context
        try Task.checkCancellation()
        guard profileMutationAllowed?(next.profileID) != false else { throw EngineError.closed }
        do {
            try write(files, to: directory)
            let id = try await runtime.installUnpackedExtension(at: directory, in: context)
            try Task.checkCancellation()
            try await runtime.setExtension(id, enabled: next.enabled, in: context)
            try Task.checkCancellation()
            guard try await runtime.installedExtensions(in: context).contains(where: {
                $0.id == id && URL(fileURLWithPath: $0.path).standardizedFileURL == directory.standardizedFileURL && $0.enabled == next.enabled
            }) else { throw EngineError.notReady("Chromium did not apply the content rules.") }
            try Task.checkCancellation()
            guard profileMutationAllowed?(next.profileID) != false else { throw EngineError.closed }
            var records = configurations
            records[next.profileID] = next
            try persist(records)
            configurations = records
            installed[next.profileID] = id
            failed.remove(next.profileID)
            lastError = nil
            onChange?()
        } catch {
            let original = error
            do {
                if let previous {
                    try write(ChromiumBlockingRules.files(json: previous.json, exceptions: previous.exceptions), to: directory)
                    let id = try await runtime.installUnpackedExtension(at: directory, in: context)
                    try await runtime.setExtension(id, enabled: previous.enabled, in: context)
                    guard try await runtime.installedExtensions(in: context).contains(where: {
                        $0.id == id && URL(fileURLWithPath: $0.path).standardizedFileURL == directory.standardizedFileURL
                            && $0.enabled == previous.enabled
                    }) else { throw EngineError.notReady("Chromium did not restore the previous content rules.") }
                    installed[next.profileID] = id
                } else {
                    for entry in try await runtime.installedExtensions(in: context)
                    where URL(fileURLWithPath: entry.path).standardizedFileURL == directory.standardizedFileURL {
                        try await runtime.removeExtension(entry.id, from: context)
                    }
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                }
            } catch {
                failed.insert(next.profileID)
                throw EngineError.notReady("Content rules failed and the previous state could not be restored: \(error.localizedDescription). Original error: \(original.localizedDescription)")
            }
            throw original
        }
    }

    private func ruleDirectory(_ profileID: UUID) -> URL { root.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true) }
    private func write(_ files: [String: Data], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
    }
    private func persist(_ values: [UUID: Configuration]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Snapshot(configurations: values.values.sorted { $0.profileID.uuidString < $1.profileID.uuidString }))
            .write(to: settingsURL, options: .atomic)
    }
    private static func validSource(_ source: URL) -> Bool {
        source.scheme?.lowercased() == "https" && source.host?.isEmpty == false && source.user == nil
            && source.password == nil && source.fragment == nil && source.absoluteString.utf8.count <= 2_048
    }
}
#endif
