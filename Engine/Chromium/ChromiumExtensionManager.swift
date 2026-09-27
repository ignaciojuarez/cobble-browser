import Foundation
import CobbleChromium

@MainActor final class ChromiumExtensionManager: BrowserExtensionManaging {
    struct Snapshot: Codable {
        var version = 2
        var records: [Record]
    }
    struct Record: Codable, Equatable {
        enum Source: String, Codable { case store }
        var id: UUID
        var profileID: UUID
        var chromiumID: String
        var sourcePath: String?
        var source: Source?
        var name: String
        var version: String
        var hasAction: Bool
        var isEnabled: Bool
        var deniedPermissions: [String]
        var requestedOrigins: [String]
        var allowedOrigins: [String]
        var errorMessage: String?
    }

    let capabilities = ExtensionCapabilities(
        websiteAccess: .individualSites,
        supportsPrivateBrowsing: false,
        supportsProviderBundles: false)
    private(set) var lastError: String?
    var onChange: (() -> Void)?
    var profileMutationAllowed: ((UUID) -> Bool)?

    private unowned let engine: ChromiumEngine
    private let runtime: ChromiumRuntime
    private let root: URL
    private let snapshotURL: URL
    private var writable = true
    private var mutationInProgress = false
    private var refreshInProgress = false
    private var pendingRefreshes: [UUID: CobbleChromium.ChromiumContext] = [:]
    private var records: [Record] = []

    init(engine: ChromiumEngine, runtime: ChromiumRuntime, directory: URL) {
        self.engine = engine
        self.runtime = runtime
        root = directory.appendingPathComponent("ChromiumExtensions", isDirectory: true)
        snapshotURL = directory.appendingPathComponent("chromium-extensions.json")
        load()
    }

    func extensions(profileID: UUID) -> [BrowserExtensionInfo] {
        records.filter { Self.isVisible($0, profileID: profileID) }.map { record in
            BrowserExtensionInfo(
                id: record.id, profileID: record.profileID,
                name: record.name, version: record.version,
                sourceURL: record.sourcePath.map { root.appendingPathComponent($0) }
                    ?? URL(string: "https://chromewebstore.google.com/detail/\(record.chromiumID)")!,
                hasAction: record.hasAction, isEnabled: record.isEnabled,
                deniedPermissions: record.deniedPermissions,
                requestedOrigins: record.requestedOrigins,
                allowedOrigins: record.allowedOrigins,
                allowsPrivateBrowsing: false,
                errorMessage: record.errorMessage)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(from sourceURL: URL, profileID: UUID) async throws {
        try beginMutation(profileID)
        defer { endMutation() }
        guard sourceURL.isFileURL else { throw failure("Choose an unpacked extension directory.") }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let relative = "\(profileID.uuidString.lowercased())/\(id.uuidString.lowercased())"
        let destination = root.appendingPathComponent(relative, isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            try Self.copyUnpackedExtension(from: sourceURL, to: destination)
        }.value

        var installedID: String?
        var installedRecord: Record?
        do {
            let context = try await normalContext(profileID)
            installedID = try await runtime.installUnpackedExtension(at: destination, in: context)
            let native = try await nativeExtension(id: installedID!, in: context)
            guard Self.samePath(native.path, destination) else {
                throw failure("Chromium installed the extension from an unexpected path.")
            }
            let record = Self.record(
                id: id, profileID: profileID, chromiumID: installedID!,
                relative: relative, native: native)
            installedRecord = record
            try persist(records + [record])
            records.append(record)
            lastError = nil
            changed()
        } catch {
            guard let installedID else {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            let cleanupError: Error?
            do {
                let context = try await normalContext(profileID)
                try await runtime.removeExtension(installedID, from: context)
                cleanupError = nil
            } catch {
                cleanupError = error
            }
            guard let cleanupError else {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }

            // Never delete a source tree for an extension Chromium may still
            // have loaded. Keep a record where possible so it remains visible.
            var retained =
                installedRecord
                ?? Record(
                    id: id, profileID: profileID,
                    chromiumID: installedID, sourcePath: relative,
                    source: nil,
                    name: destination.lastPathComponent, version: "",
                    hasAction: false, isEnabled: true,
                    deniedPermissions: [], requestedOrigins: [],
                    allowedOrigins: [], errorMessage: nil)
            let detail =
                "Chromium installed this extension, but Cobble could not remove it after an error: \(cleanupError.localizedDescription)"
            retained.errorMessage = detail
            lastError = detail
            if index(id: retained.id, profileID: retained.profileID) == nil {
                let next = records + [retained]
                do {
                    try persist(next)
                    records = next
                } catch {
                    records = next
                }
            }
            changed()
            throw failure(detail)
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID, profileID: UUID) async throws {
        try beginMutation(profileID)
        defer { endMutation() }
        guard let record = record(id: id, profileID: profileID) else {
            throw failure("Extension not found.")
        }
        let context = try await normalContext(profileID)
        var nativeChanged = false
        do {
            try await runtime.setExtension(record.chromiumID, enabled: enabled, in: context)
            nativeChanged = true
            try await refreshAfterMutation(profileID: profileID, context: context)
        } catch {
            if nativeChanged { await refreshAfterNativeFailure(profileID: profileID, context: context) }
            throw error
        }
    }

    /// Chromium only grants concrete HTTP(S) origins. Pattern strings are never
    /// sent to the native bridge because that could broaden access.
    func setAllowedOrigins(_ origins: [String], id: UUID, profileID: UUID) async throws {
        try beginMutation(profileID)
        defer { endMutation() }
        guard let record = record(id: id, profileID: profileID) else {
            throw failure("Extension not found.")
        }
        let requested = try Set(origins.map(Self.concreteOrigin))
        let current = Set(record.allowedOrigins)
        let context = try await normalContext(profileID)
        var nativeChanged = false
        do {
            for origin in current.subtracting(requested) {
                try await runtime.setExtension(
                    record.chromiumID,
                    siteAccessAt: URL(string: origin)!,
                    allowed: false, in: context)
                nativeChanged = true
            }
            for origin in requested.subtracting(current) {
                try await runtime.setExtension(
                    record.chromiumID,
                    siteAccessAt: URL(string: origin)!,
                    allowed: true, in: context)
                nativeChanged = true
            }
            try await refreshAfterMutation(profileID: profileID, context: context)
        } catch {
            if nativeChanged { await refreshAfterNativeFailure(profileID: profileID, context: context) }
            throw error
        }
    }

    func setPrivateBrowsingAllowed(_ allowed: Bool, id: UUID, profileID: UUID) async throws {
        throw failure("Chromium extensions are unavailable in private browsing.")
    }

    func performAction(id: UUID, profileID: UUID, on page: (any BrowserPage)?) async throws {
        guard let record = record(id: id, profileID: profileID), record.isEnabled else {
            throw failure("Enable this extension before opening its action.")
        }
        guard let page = page as? ChromiumPage, page.contextID.profileID == profileID,
            !page.contextID.isPrivate, let nativePage = page.source
        else {
            throw failure("Open the extension action from a normal Chromium tab in this profile.")
        }
        let (contextHost, context) = try await engine.extensionContext(profileID)
        guard page.context === contextHost, nativePage.context === context else {
            throw failure("The extension action page does not belong to this Chromium context.")
        }
        try await runtime.performExtensionAction(record.chromiumID, on: nativePage, in: context)
    }

    func remove(id: UUID, profileID: UUID) async throws {
        try beginMutation(profileID)
        defer { endMutation() }
        guard let record = record(id: id, profileID: profileID) else {
            throw failure("Extension not found.")
        }
        let context = try await normalContext(profileID)
        try await runtime.removeExtension(record.chromiumID, from: context)
        let next = records.filter { $0.id != record.id }
        do {
            try persist(next)
            records = next
            lastError = nil
            if let sourcePath = record.sourcePath {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(sourcePath))
            }
            changed()
        } catch {
            // Chromium has removed it, but retain its source until a writable
            // snapshot can record that fact; this avoids losing ownership data.
            records = next
            let detail =
                "Chromium removed this extension, but Cobble could not save the update. \(error.localizedDescription)"
            lastError = detail
            changed()
            throw failure(detail)
        }
    }

    func removeProfile(_ profileID: UUID) throws {
        try beginMutation()
        defer { endMutation() }
        let next = records.filter { $0.profileID != profileID }
        try persist(next)
        records = next
        let directory = root.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        lastError = nil
        changed()
    }

    func refresh(profileID: UUID, context: CobbleChromium.ChromiumContext) async throws {
        guard writable, !context.isClosed, !context.isClosing else { return }
        if mutationInProgress || refreshInProgress {
            pendingRefreshes[profileID] = context
            return
        }
        refreshInProgress = true
        defer {
            refreshInProgress = false
            drainPendingRefreshes()
        }
        let baseline = records
        let next = try await refreshedRecords(profileID: profileID, context: context, from: baseline)
        guard records == baseline, !mutationInProgress else { return }
        try commitRefresh(next, profileID: profileID)
    }

    func refreshFromNative(profileID: UUID, context: CobbleChromium.ChromiumContext) async {
        do {
            try await refresh(profileID: profileID, context: context)
        } catch where context.isClosed || context.isClosing {
            return
        } catch {
            lastError = "Chromium extensions could not be refreshed. \(error.localizedDescription)"
            changed()
        }
    }

    func contextDidClose(_ context: ChromiumContext) {}

    private func normalContext(_ profileID: UUID) async throws -> CobbleChromium.ChromiumContext {
        try await engine.extensionContext(profileID).context
    }

    private func refreshAfterMutation(profileID: UUID, context: CobbleChromium.ChromiumContext) async throws {
        let next = try await refreshedRecords(profileID: profileID, context: context, from: records)
        try commitRefresh(next, profileID: profileID)
    }

    private func refreshAfterNativeFailure(profileID: UUID, context: CobbleChromium.ChromiumContext) async {
        guard writable else { return }
        do {
            try await refreshAfterMutation(profileID: profileID, context: context)
        } catch {
            // A native mutation without a trustworthy post-mutation listing
            // must fail closed; another grant could otherwise build on stale UI.
            writable = false
            lastError = "Chromium may have changed extension state, but Cobble could not verify and save it. \(error.localizedDescription)"
            changed()
        }
    }

    private func refreshedRecords(
        profileID: UUID, context: CobbleChromium.ChromiumContext,
        from baseline: [Record]
    ) async throws -> [Record] {
        let native = try await runtime.installedExtensions(in: context)
        let byID = Dictionary(uniqueKeysWithValues: native.map { ($0.id, $0) })
        var next = baseline
        for index in next.indices.reversed() where next[index].profileID == profileID {
            #if !COBBLE_CHROMIUM_ABI15
            if next[index].source == .store { continue }
            #endif
            guard let item = byID[next[index].chromiumID] else {
                if next[index].source == .store { next.remove(at: index); continue }
                next[index].errorMessage = "This extension is no longer installed in Chromium."
                continue
            }
            #if COBBLE_CHROMIUM_ABI15
            if next[index].source == .store {
                guard Self.canAdoptStore(item) else {
                    next.remove(at: index)
                    continue
                }
                next[index] = Self.storeRecord(id: next[index].id, profileID: profileID, native: item)
                continue
            }
            #endif
            guard let sourcePath = next[index].sourcePath,
                Self.samePath(item.path, root.appendingPathComponent(sourcePath)) else {
                next[index].errorMessage = "Chromium reported an unexpected extension path."
                continue
            }
            next[index] = Self.record(
                id: next[index].id, profileID: profileID,
                chromiumID: next[index].chromiumID,
                relative: sourcePath, native: item)
        }
        #if COBBLE_CHROMIUM_ABI15
        let known = Set(next.filter { $0.profileID == profileID }.map(\.chromiumID))
        next += native.filter { Self.canAdoptStore($0) && !known.contains($0.id) }
            .map { Self.storeRecord(id: UUID(), profileID: profileID, native: $0) }
        #endif
        return next
    }

    private func commitRefresh(_ next: [Record], profileID: UUID) throws {
        guard next != records else { return }
        do {
            try persist(next)
            records = next
            lastError = nil
            changed()
        } catch {
            let detail =
                "Chromium changed extension state, but Cobble could not save the update. \(error.localizedDescription)"
            records = next.map { record in
                guard record.profileID == profileID else { return record }
                var current = record
                current.errorMessage = detail
                return current
            }
            lastError = detail
            changed()
            throw failure(detail)
        }
    }

    private func nativeExtension(id: String, in context: CobbleChromium.ChromiumContext) async throws
        -> ChromiumExtension
    {
        let extensions = try await runtime.installedExtensions(in: context)
        guard let item = extensions.first(where: { $0.id == id }) else {
            throw failure("Chromium did not report the installed extension.")
        }
        return item
    }

    private func beginMutation(_ profileID: UUID? = nil) throws {
        guard writable else { throw failure(lastError ?? "Extension changes are disabled.") }
        if let profileID, profileMutationAllowed?(profileID) == false {
            throw failure("This profile is being deleted. Try again when cleanup finishes.")
        }
        guard !mutationInProgress, !refreshInProgress else {
            throw failure("Another extension operation is still in progress.")
        }
        mutationInProgress = true
    }

    private func endMutation() {
        mutationInProgress = false
        drainPendingRefreshes()
    }

    private func drainPendingRefreshes() {
        guard !mutationInProgress, !refreshInProgress else { return }
        let pending = pendingRefreshes
        pendingRefreshes.removeAll()
        for (profileID, context) in pending {
            Task { await refreshFromNative(profileID: profileID, context: context) }
        }
    }

    private func record(id: UUID, profileID: UUID) -> Record? {
        records.first { $0.id == id && $0.profileID == profileID }
    }

    private func index(id: UUID, profileID: UUID) -> Int? {
        records.firstIndex { $0.id == id && $0.profileID == profileID }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
            guard [1, 2].contains(snapshot.version),
                Set(snapshot.records.map(\.id)).count == snapshot.records.count,
                Set(snapshot.records.map { "\($0.profileID):\($0.chromiumID)" }).count == snapshot.records.count,
                snapshot.records.allSatisfy(Self.valid)
            else { throw CocoaError(.fileReadCorruptFile) }
            records = snapshot.records
        } catch {
            writable = false
            lastError =
                "Chromium extensions could not be read. Changes are disabled. \(error.localizedDescription)"
        }
    }

    private func persist(_ records: [Record]) throws {
        guard writable else { throw failure(lastError ?? "Extension changes are disabled.") }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Snapshot(records: records))
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            writable = false
            lastError = "Chromium extension changes are disabled because Cobble could not save its snapshot. \(error.localizedDescription)"
            throw error
        }
    }

    private func changed() { onChange?() }
    private func failure(_ detail: String) -> EngineError { .notReady(detail) }

    private static func record(
        id: UUID, profileID: UUID, chromiumID: String,
        relative: String, native: ChromiumExtension
    ) -> Record {
        Record(
            id: id, profileID: profileID, chromiumID: chromiumID, sourcePath: relative,
            source: nil,
            name: native.name, version: native.version, hasAction: native.hasAction,
            isEnabled: native.enabled, deniedPermissions: native.deniedPermissions.sorted(),
            requestedOrigins: native.requestedOrigins.sorted(),
            allowedOrigins: concreteOrigins(native.allowedOrigins), errorMessage: nil)
    }

    #if COBBLE_CHROMIUM_ABI15
    static func canAdoptStore(_ native: ChromiumExtension) -> Bool {
        native.source == .store && native.userManageable
            && native.id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil
            && native.name.count <= 256 && native.version.count <= 128
    }

    private static func storeRecord(id: UUID, profileID: UUID, native: ChromiumExtension) -> Record {
        Record(id: id, profileID: profileID, chromiumID: native.id, sourcePath: nil,
               source: .store, name: native.name, version: native.version,
               hasAction: native.hasAction, isEnabled: native.enabled,
               deniedPermissions: native.deniedPermissions.sorted(),
               requestedOrigins: native.requestedOrigins.sorted(),
               allowedOrigins: concreteOrigins(native.allowedOrigins), errorMessage: nil)
    }
    #endif

    static func isVisible(_ record: Record, profileID: UUID) -> Bool {
        guard record.profileID == profileID else { return false }
        #if COBBLE_CHROMIUM_ABI15
        return true
        #else
        return record.source == nil
        #endif
    }

    static func valid(_ record: Record) -> Bool {
        record.chromiumID.range(of: "^[a-p]{32}$", options: .regularExpression) != nil
            && (record.source == .store
                ? record.sourcePath == nil
                : record.sourcePath
                    == "\(record.profileID.uuidString.lowercased())/\(record.id.uuidString.lowercased())")
            && record.name.count <= 256 && record.version.count <= 128
            && record.allowedOrigins.allSatisfy { (try? concreteOrigin($0)) != nil }
    }

    private static func concreteOrigins(_ patterns: [String]) -> [String] {
        Array(Set(patterns.compactMap { try? concreteOrigin($0) })).sorted()
    }

    static func concreteOrigin(_ value: String) throws -> String {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host?.lowercased(), !host.isEmpty,
            !host.contains("*"), components.user == nil, components.password == nil,
            components.port.map({ (1...65535).contains($0) }) ?? true,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/" || components.path == "/*"
        else {
            throw EngineError.unsupported(
                "Chromium grants individual HTTP(S) sites, not URL patterns.")
        }
        var result = URLComponents()
        result.scheme = scheme
        result.host = host
        result.port = components.port
        result.path = "/"
        guard let url = result.url else { throw EngineError.unsupported("Invalid HTTP(S) site.") }
        return url.absoluteString
    }

    private static func samePath(_ nativePath: String, _ expected: URL) -> Bool {
        URL(fileURLWithPath: nativePath).resolvingSymlinksInPath().standardizedFileURL
            == expected.resolvingSymlinksInPath().standardizedFileURL
    }

    private nonisolated static func copyUnpackedExtension(from source: URL, to destination: URL)
        throws
    {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        let sourceValues = try source.resourceValues(forKeys: keys)
        let manifestURL = source.appendingPathComponent("manifest.json")
        let manifestValues = try? manifestURL.resourceValues(forKeys: keys)
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true,
            manifestValues?.isRegularFile == true, manifestValues?.isSymbolicLink != true,
            (manifestValues?.fileSize ?? Int.max) <= 1_000_000
        else {
            throw EngineError.notReady(
                "Choose an unpacked extension directory containing a small regular manifest.json file.")
        }
        if let contents = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: Array(keys))
        {
            for case let item as URL in contents {
                if try item.resourceValues(forKeys: keys).isSymbolicLink == true {
                    throw EngineError.notReady("Extension folders cannot contain symbolic links.")
                }
            }
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        else {
            throw EngineError.notReady("The extension manifest is invalid.")
        }
        guard manifest["theme"] == nil else {
            throw EngineError.unsupported("Chromium themes are not supported by Cobble.")
        }
        guard manifest["app"] == nil else {
            throw EngineError.unsupported("Chrome Apps are not supported by Cobble.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw EngineError.notReady("The managed extension destination already exists.")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
