import AppKit
import CryptoKit
import WebKit

@MainActor
final class WebKitExtensionManager: BrowserExtensionManaging {
    private struct Snapshot: Codable { var version = 1; var records: [Record] }
    fileprivate struct Record: Codable, Equatable {
        var id: UUID
        var profileID: UUID
        var sourcePath: String
        var appExtensionPath: String?
        var name: String
        var version: String
        var hasAction: Bool?
        var isEnabled: Bool
        var deniedPermissions: [String]?
        var allowedOptionalPermissions: [String]?
        var requestedOrigins: [String]
        var allowedOrigins: [String]
        var allowsPrivateBrowsing: Bool
        var errorMessage: String?
    }
    private struct WeakSession { weak var value: WebKitExtensionSession? }

    private(set) var lastError: String?
    var onChange: (() -> Void)?
    var profileMutationAllowed: ((UUID) -> Bool)?
    private let root: URL
    private let snapshotURL: URL
    private let persistentStorageAllowed: Bool
    private var writable = true
    fileprivate var records: [Record] = []
    private var extensionsByID: [UUID: WKWebExtension] = [:]
    private var sessions: [WeakSession] = []

    init(directory: URL, persistentStorageAllowed: Bool = true) {
        root = directory.appendingPathComponent("Extensions", isDirectory: true)
        snapshotURL = directory.appendingPathComponent("extensions.json")
        self.persistentStorageAllowed = persistentStorageAllowed
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        do {
            let data = try Data(contentsOf: snapshotURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else { throw CocoaError(.fileReadUnknown) }
            var ids = Set<UUID>()
            for record in snapshot.records {
                guard ids.insert(record.id).inserted,
                      Self.validRelativePath(record.sourcePath, profileID: record.profileID, id: record.id),
                      record.name.count <= 256, record.version.count <= 128,
                      Self.validNestedPath(record.appExtensionPath),
                      (record.deniedPermissions ?? []).allSatisfy({ $0 == "Native messaging" }),
                      (record.allowedOptionalPermissions ?? []).count <= 100,
                      (record.allowedOptionalPermissions ?? []).allSatisfy({ !$0.isEmpty && $0.count <= 128 && $0 != WKWebExtension.Permission.nativeMessaging.rawValue && $0 != WKWebExtension.Permission.activeTab.rawValue }),
                      Set(record.allowedOrigins).isSubset(of: Set(record.requestedOrigins)),
                      record.requestedOrigins.allSatisfy({ (try? WKWebExtension.MatchPattern(string: $0)) != nil }),
                      record.allowedOrigins.allSatisfy({ (try? WKWebExtension.MatchPattern(string: $0)) != nil }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            records = snapshot.records
        } catch {
            writable = false
            lastError = String(format: String(localized: "Extensions could not be read. The original file is preserved; changes are disabled: %@"), error.localizedDescription)
        }
    }

    func extensions(profileID: UUID) -> [BrowserExtensionInfo] {
        records.filter { $0.profileID == profileID }.map { record in
            BrowserExtensionInfo(id: record.id, profileID: record.profileID, name: record.name,
                version: record.version, sourceURL: root.appendingPathComponent(record.sourcePath),
                hasAction: record.hasAction ?? false,
                isEnabled: record.isEnabled, deniedPermissions: record.deniedPermissions ?? [],
                requestedOrigins: record.requestedOrigins,
                allowedOrigins: record.allowedOrigins, allowsPrivateBrowsing: record.allowsPrivateBrowsing,
                errorMessage: record.errorMessage,
                allowedOptionalPermissions: record.allowedOptionalPermissions ?? [])
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(from sourceURL: URL, profileID: UUID) async throws {
        try beginMutation(profileID)
        guard writable else { throw failure(lastError ?? String(localized: "Extension changes are disabled.")) }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let relative = "\(profileID.uuidString.lowercased())/\(id.uuidString.lowercased())/\(sourceURL.lastPathComponent)"
        let destination = root.appendingPathComponent(relative)
        let container = destination.deletingLastPathComponent()
        var committed = false
        do {
            let appExtensionPath = try await Task.detached(priority: .userInitiated) {
                try Self.copySource(from: sourceURL, to: destination, managedRoot: self.root)
            }.value
            let native = try await Self.load(from: destination, appExtensionPath: appExtensionPath)
            try beginMutation(profileID)
            let warnings = native.errors.map(\.localizedDescription)
            let record = Record(id: id, profileID: profileID, sourcePath: relative,
                appExtensionPath: appExtensionPath, name: native.displayName ?? sourceURL.deletingPathExtension().lastPathComponent,
                version: native.displayVersion ?? native.version ?? "", hasAction: Self.hasAction(native), isEnabled: true,
                deniedPermissions: Self.deniedPermissions(native),
                allowedOptionalPermissions: [],
                requestedOrigins: native.allRequestedMatchPatterns.map(\.string).sorted(), allowedOrigins: [],
                allowsPrivateBrowsing: false, errorMessage: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
            try save(records + [record])
            committed = true
            extensionsByID[id] = native
            try await reconcileSessions(profileID: profileID)
            try beginMutation(profileID)
        } catch {
            if committed { setRuntimeError(error.localizedDescription, id: id, profileID: profileID) }
            else { await Task.detached { try? FileManager.default.removeItem(at: container) }.value }
            throw error
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID, profileID: UUID) async throws {
        try await update(id: id, profileID: profileID) { $0.isEnabled = enabled }
    }

    func setAllowedOrigins(_ origins: [String], id: UUID, profileID: UUID) async throws {
        try await update(id: id, profileID: profileID) { record in
            let normalized = Array(Set(origins)).sorted()
            guard Set(normalized).isSubset(of: Set(record.requestedOrigins)),
                  normalized.allSatisfy({ (try? WKWebExtension.MatchPattern(string: $0)) != nil }) else {
                throw self.failure(String(localized: "Only host patterns declared by the extension can be allowed."))
            }
            record.allowedOrigins = normalized
        }
    }

    func setPrivateBrowsingAllowed(_ allowed: Bool, id: UUID, profileID: UUID) async throws {
        try await update(id: id, profileID: profileID) { $0.allowsPrivateBrowsing = allowed }
    }

    func setAllowedOptionalPermissions(_ permissions: [String], id: UUID, profileID: UUID) async throws {
        try await update(id: id, profileID: profileID) { record in
            let normalized = Array(Set(permissions)).sorted()
            guard Set(normalized).isSubset(of: Set(record.allowedOptionalPermissions ?? [])) else {
                throw self.failure(String(localized: "New extension permissions require an extension request and your approval."))
            }
            record.allowedOptionalPermissions = normalized
        }
    }

    func performAction(id: UUID, profileID: UUID, on page: (any BrowserPage)?) async throws {
        try beginMutation(profileID)
        guard let record = record(id: id, profileID: profileID), record.isEnabled else {
            throw failure(String(localized: "Enable this extension before opening its action."))
        }
        guard let page = page as? WebKitPage, page.contextID.profileID == profileID,
              let session = page.context?.extensionSession as? WebKitExtensionSession else {
            throw failure(String(localized: "Open the extension action from a WebKit tab in this profile."))
        }
        try await session.prepare()
        try beginMutation(profileID)
        try session.performAction(id: id, on: page)
    }

    func remove(id: UUID, profileID: UUID) async throws {
        try await remove(id: id, profileID: profileID, deletingProfile: false)
    }

    func removeForProfileDeletion(id: UUID, profileID: UUID) async throws {
        try await remove(id: id, profileID: profileID, deletingProfile: true)
    }

    private func remove(id: UUID, profileID: UUID, deletingProfile: Bool) async throws {
        if !deletingProfile { try beginMutation(profileID) }
        guard writable else { throw failure(lastError ?? String(localized: "Extension changes are disabled.")) }
        guard let record = records.first(where: { $0.id == id && $0.profileID == profileID }) else {
            throw failure(String(localized: "Extension not found."))
        }
        sessions.removeAll { $0.value == nil }
        var dataRecords: [(WKWebExtensionController, WKWebExtension.DataRecord)] = []
        var hasPersistentSession = false
        do {
            for session in sessions.compactMap(\.value) where session.id.profileID == profileID {
                hasPersistentSession = hasPersistentSession || session.controller.configuration.isPersistent
                if let dataRecord = try await session.stopForRemoval(id: id) {
                    dataRecords.append((session.controller, dataRecord))
                }
            }
            if persistentStorageAllowed && !hasPersistentSession {
                let configuration = WKWebExtensionController.Configuration(identifier:
                    Self.controllerIdentifier(profileID: profileID, namespace: root.path))
                let cleanupController = WKWebExtensionController(configuration: configuration)
                if let dataRecord = await cleanupController.dataRecords(
                    ofTypes: WKWebExtensionController.allExtensionDataTypes).first(where: {
                        $0.uniqueIdentifier == id.uuidString.lowercased()
                    }) {
                    dataRecords.append((cleanupController, dataRecord))
                }
            }
        } catch {
            setRuntimeError(String(format: String(localized: "The extension could not be stopped: %@"), error.localizedDescription), id: id, profileID: profileID)
            try? await reconcileSessions(profileID: profileID)
            throw error
        }
        if !deletingProfile { try beginMutation(profileID) }
        do { try save(records.filter { $0.id != id || $0.profileID != profileID }) }
        catch {
            try? await reconcileSessions(profileID: profileID)
            throw error
        }
        extensionsByID.removeValue(forKey: id)
        for (controller, dataRecord) in dataRecords {
            await controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [dataRecord])
        }
        let dataErrors = dataRecords.flatMap { $0.1.errors }.map(\.localizedDescription)
        try await reconcileSessions(profileID: profileID)
        if !deletingProfile { try beginMutation(profileID) }
        let container = root.appendingPathComponent(record.sourcePath).deletingLastPathComponent()
        do { try await Task.detached { try FileManager.default.removeItem(at: container) }.value }
        catch {
            lastError = String(format: String(localized: "The extension was removed, but its copied files could not be deleted: %@"), error.localizedDescription)
            onChange?()
            throw failure(lastError!)
        }
        if !dataErrors.isEmpty {
            lastError = String(format: String(localized: "The extension was removed, but some extension data could not be deleted: %@"), dataErrors.joined(separator: "\n"))
            onChange?()
            throw failure(lastError!)
        }
    }

    func makeSession(id: BrowsingContextID, dataStore: WKWebsiteDataStore) -> WebKitExtensionSession {
        sessions.removeAll { $0.value == nil }
        let session = WebKitExtensionSession(manager: self, id: id, dataStore: dataStore,
            controllerIdentifier: Self.controllerIdentifier(profileID: id.profileID, namespace: root.path))
        sessions.append(WeakSession(value: session))
        return session
    }

    nonisolated static func controllerIdentifier(profileID: UUID, namespace: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(namespace)\0\(profileID.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }

    fileprivate func extensionForRecord(_ record: Record) async throws -> WKWebExtension {
        if let loaded = extensionsByID[record.id] { return loaded }
        let url = root.appendingPathComponent(record.sourcePath)
        try await Task.detached { try Self.validateSource(url) }.value
        let loaded = try await Self.load(from: url, appExtensionPath: record.appExtensionPath)
        extensionsByID[record.id] = loaded
        let warning = loaded.errors.map(\.localizedDescription).joined(separator: "\n")
        try? updateMetadata(id: record.id, name: loaded.displayName ?? record.name,
            version: loaded.displayVersion ?? loaded.version ?? record.version,
            hasAction: Self.hasAction(loaded),
            deniedPermissions: Self.deniedPermissions(loaded),
            optionalPermissions: loaded.optionalPermissions.map(\.rawValue),
            requestedOrigins: loaded.allRequestedMatchPatterns.map(\.string).sorted(),
            errorMessage: warning.isEmpty ? nil : warning)
        return loaded
    }

    fileprivate func record(id: UUID, profileID: UUID) -> Record? {
        records.first { $0.id == id && $0.profileID == profileID }
    }

    fileprivate func setRuntimeError(_ message: String?, id: UUID, profileID: UUID) {
        try? updateMetadata(id: id, errorMessage: message)
    }

    fileprivate func grantOptionalPermissions(_ permissions: Set<WKWebExtension.Permission>, id: UUID,
                                              profileID: UUID) throws {
        try beginMutation(profileID)
        guard writable, let index = records.firstIndex(where: { $0.id == id && $0.profileID == profileID && $0.isEnabled }),
              let native = extensionsByID[id], permissions.isSubset(of: native.optionalPermissions),
              !permissions.contains(.nativeMessaging), !permissions.contains(.activeTab) else {
            throw failure(String(localized: "The extension permission request is no longer available."))
        }
        var next = records
        next[index].allowedOptionalPermissions = Array(Set(next[index].allowedOptionalPermissions ?? [])
            .union(permissions.map(\.rawValue))).sorted()
        try save(next)
        sessions.compactMap(\.value).filter { $0.id.profileID == profileID && !$0.id.isPrivate }
            .forEach { $0.applyOptionalPermissions(permissions, extensionID: id) }
    }

    fileprivate func removeOptionalPermissions(_ permissions: Set<WKWebExtension.Permission>, id: UUID,
                                               profileID: UUID) async {
        guard writable, let index = records.firstIndex(where: { $0.id == id && $0.profileID == profileID }) else { return }
        var next = records
        let previous = Set(next[index].allowedOptionalPermissions ?? [])
        next[index].allowedOptionalPermissions = Array(previous.subtracting(permissions.map(\.rawValue))).sorted()
        guard Set(next[index].allowedOptionalPermissions ?? []) != previous else { return }
        do {
            try beginMutation(profileID)
            try save(next)
            try await reconcileSessions(profileID: profileID)
        } catch {
            setRuntimeError(error.localizedDescription, id: id, profileID: profileID)
        }
    }

    private func update(id: UUID, profileID: UUID, change: (inout Record) throws -> Void) async throws {
        try beginMutation(profileID)
        guard writable else { throw failure(lastError ?? String(localized: "Extension changes are disabled.")) }
        guard let index = records.firstIndex(where: { $0.id == id && $0.profileID == profileID }) else {
            throw failure(String(localized: "Extension not found."))
        }
        var next = records
        try change(&next[index])
        try save(next)
        try await reconcileSessions(profileID: profileID)
        try beginMutation(profileID)
    }

    private func updateMetadata(id: UUID, name: String? = nil, version: String? = nil, hasAction: Bool? = nil,
                                deniedPermissions: [String]? = nil,
                                optionalPermissions: [String]? = nil,
                                requestedOrigins: [String]? = nil, errorMessage: String?) throws {
        guard writable, let index = records.firstIndex(where: { $0.id == id }) else { return }
        try beginMutation(records[index].profileID)
        var next = records
        if let name { next[index].name = name }
        if let version { next[index].version = version }
        if let hasAction { next[index].hasAction = hasAction }
        if let deniedPermissions { next[index].deniedPermissions = deniedPermissions }
        if let optionalPermissions {
            next[index].allowedOptionalPermissions = next[index].allowedOptionalPermissions?.filter(Set(optionalPermissions).contains)
        }
        if let requestedOrigins {
            next[index].requestedOrigins = requestedOrigins
            next[index].allowedOrigins = next[index].allowedOrigins.filter(Set(requestedOrigins).contains)
        }
        next[index].errorMessage = errorMessage
        guard next[index] != records[index] else { return }
        try save(next)
    }

    private func reconcileSessions(profileID: UUID) async throws {
        sessions.removeAll { $0.value == nil }
        for session in sessions.compactMap(\.value) where session.id.profileID == profileID {
            try await session.reconcile()
        }
    }

    private func save(_ next: [Record]) throws {
        do {
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(records: next)).write(to: snapshotURL, options: .atomic)
            records = next
            lastError = nil
            onChange?()
        } catch {
            lastError = String(format: String(localized: "Extensions could not be saved: %@"), error.localizedDescription)
            onChange?()
            throw failure(lastError!)
        }
    }

    private func failure(_ message: String) -> EngineError { .notReady(message) }

    private func beginMutation(_ profileID: UUID) throws {
        guard profileMutationAllowed?(profileID) != false else {
            throw failure(String(localized: "This profile is being deleted. Try again when cleanup finishes."))
        }
    }

    nonisolated private static func validRelativePath(_ path: String, profileID: UUID, id: UUID) -> Bool {
        let components = NSString(string: path).pathComponents
        return components.count == 3 && components[0] == profileID.uuidString.lowercased()
            && components[1] == id.uuidString.lowercased() && !components[2].isEmpty
            && components[2] != "." && components[2] != ".."
    }

    nonisolated private static func validNestedPath(_ path: String?) -> Bool {
        guard let path else { return true }
        if path == "." { return true }
        let components = NSString(string: path).pathComponents
        return !components.isEmpty && !path.hasPrefix("/") && !components.contains("..") && !components.contains(".")
    }

    nonisolated private static func copySource(from source: URL, to destination: URL, managedRoot: URL) throws -> String? {
        try validateSource(source)
        let sourcePath = source.standardizedFileURL.path
        let managedPath = managedRoot.standardizedFileURL.path
        guard managedPath != sourcePath, !managedPath.hasPrefix(sourcePath + "/") else {
            throw EngineError.notReady(String(localized: "Choose an extension outside Cobble's managed extension folder."))
        }
        let container = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try validateSource(destination)
            return try appExtensionPath(in: destination)
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
    }

    nonisolated private static func validateSource(_ url: URL) throws {
        guard url.isFileURL else { throw EngineError.notReady(String(localized: "Choose a local extension folder, ZIP archive, or app extension bundle.")) }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isRegularFile == true, url.pathExtension.lowercased() == "zip", values.isSymbolicLink != true {
            guard let size = values.fileSize, size <= 50 * 1_024 * 1_024 else {
                throw EngineError.notReady(String(localized: "Extension ZIP archives are limited to 50 MB."))
            }
            return
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw EngineError.notReady(String(localized: "Choose an extension folder, ZIP archive, or app extension bundle without symbolic links."))
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw EngineError.notReady(String(localized: "The extension folder could not be read."))
        }
        var files = 0
        var bytes = 0
        for case let child as URL in iterator {
            let childValues = try child.resourceValues(forKeys: keys)
            guard childValues.isSymbolicLink != true else {
                throw EngineError.notReady(String(localized: "Extensions containing symbolic links are not allowed."))
            }
            files += 1
            if childValues.isRegularFile == true { bytes += childValues.fileSize ?? 0 }
            guard files <= 10_000, bytes <= 50 * 1_024 * 1_024 else {
                throw EngineError.notReady(String(localized: "Extensions are limited to 10,000 files and 50 MB."))
            }
        }
        if let enumerationError { throw enumerationError }
    }

    nonisolated static func appExtensionPath(in url: URL) throws -> String? {
        if url.pathExtension.lowercased() == "appex" { return "." }
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let plugIns = url.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(at: plugIns,
            includingPropertiesForKeys: nil))?.filter { $0.pathExtension.lowercased() == "appex" } ?? []
        guard candidates.count == 1, let candidate = candidates.first else {
            throw EngineError.notReady(String(localized: "Choose an app containing exactly one web extension bundle."))
        }
        return "Contents/PlugIns/\(candidate.lastPathComponent)"
    }

    private static func hasAction(_ native: WKWebExtension) -> Bool {
        native.manifest["action"] != nil || native.manifest["browser_action"] != nil
            || native.manifest["page_action"] != nil
    }

    private static func deniedPermissions(_ native: WKWebExtension) -> [String] {
        native.requestedPermissions.contains(.nativeMessaging) ? ["Native messaging"] : []
    }

    private static func load(from url: URL, appExtensionPath: String?) async throws -> WKWebExtension {
        let native: WKWebExtension
        if let appExtensionPath {
            let bundleURL = appExtensionPath == "." ? url : url.appendingPathComponent(appExtensionPath)
            guard let bundle = Bundle(url: bundleURL) else { throw EngineError.notReady(String(localized: "The app extension bundle is invalid.")) }
            native = try await WKWebExtension(appExtensionBundle: bundle)
        } else {
            native = try await WKWebExtension(resourceBaseURL: url)
        }
        guard native.manifest["theme"] == nil else {
            throw EngineError.notReady(String(localized: "Browser themes are not supported by Cobble."))
        }
        return native
    }
}

@MainActor
final class WebKitExtensionSession: NSObject, WKWebExtensionControllerDelegate {
    private struct WeakPage { weak var value: WebKitPage? }
    private struct WeakWindow { weak var value: NSWindow? }
    private final class ObserverBag: @unchecked Sendable {
        var values: [NSObjectProtocol] = []
        deinit { values.forEach(NotificationCenter.default.removeObserver) }
    }
    @MainActor private final class PopupWindowLifetime: NSObject {
        let context: WKWebExtensionContext
        let popover: NSPopover
        let webView: WKWebView
        private var closeObserver: NSObjectProtocol?
        private var keepAlive: PopupWindowLifetime?
        var isVisible: Bool { popover.isShown }

        init(context: WKWebExtensionContext, popover: NSPopover, webView: WKWebView, anchorView: NSView,
             didClose: @escaping @MainActor @Sendable () -> Void) {
            self.context = context
            self.popover = popover
            self.webView = webView
            super.init()
            popover.animates = false
            closeObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification,
                object: popover, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let closeObserver = self.closeObserver {
                            NotificationCenter.default.removeObserver(closeObserver)
                        }
                        self.closeObserver = nil
                        didClose()
                        // AppKit still touches the popover while returning from didClose.
                        DispatchQueue.main.async { self.keepAlive = nil }
                    }
                }
            keepAlive = self
            present(relativeTo: anchorView)
        }

        func show(relativeTo anchorView: NSView) {
            guard !popover.isShown else { return }
            keepAlive = self
            present(relativeTo: anchorView)
        }

        private func present(relativeTo anchorView: NSView) {
            anchorView.window?.makeKeyAndOrderFront(nil)
            let bounds = anchorView.bounds
            let anchor = NSRect(x: max(bounds.minX, bounds.maxX - 1),
                                y: anchorView.isFlipped ? bounds.minY : max(bounds.minY, bounds.maxY - 1),
                                width: 1, height: 1)
            popover.show(relativeTo: anchor, of: anchorView,
                         preferredEdge: anchorView.isFlipped ? .minY : .maxY)
        }

        func close() {
            guard popover.isShown else { return }
            popover.performClose(nil)
        }
    }
    let id: BrowsingContextID
    let controller: WKWebExtensionController
    private weak var manager: WebKitExtensionManager?
    private let dataStore: WKWebsiteDataStore
    private let needsNonPersistentStoreAccessWorkaround: Bool
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private let observers = ObserverBag()
    private let windowObservers = ObserverBag()
    private var pages: [WeakPage] = []
    private var openedPages: Set<ObjectIdentifier> = []
    private var pageWindows: [ObjectIdentifier: WeakWindow] = [:]
    private var activePages: [ObjectIdentifier: WeakPage] = [:]
    private var movingPages: [ObjectIdentifier: (window: WebKitExtensionWindow, index: Int)] = [:]
    private var windows: [ObjectIdentifier: WebKitExtensionWindow] = [:]
    private var popupWindows: [ObjectIdentifier: PopupWindowLifetime] = [:]
    private var prepared = false
    private var revision = 0
    private var appliedRevision = 0
    private var reconcileTask: (id: UUID, task: Task<Void, Error>)?

    init(manager: WebKitExtensionManager, id: BrowsingContextID, dataStore: WKWebsiteDataStore,
         controllerIdentifier: UUID) {
        self.manager = manager
        self.id = id
        self.dataStore = dataStore
        let configuration: WKWebExtensionController.Configuration = id.isPrivate || !dataStore.isPersistent
            ? .nonPersistent() : .init(identifier: controllerIdentifier)
        // Older WebKit releases treat every ephemeral tab store as private, including the
        // nonpersistent controller's own store. Detect that behavior before replacing its default.
        needsNonPersistentStoreAccessWorkaround = !dataStore.isPersistent
            && configuration.defaultWebsiteDataStore.isPersistent
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.websiteDataStore = dataStore
        webViewConfiguration.userContentController = WKUserContentController()
        configuration.webViewConfiguration = webViewConfiguration
        configuration.defaultWebsiteDataStore = dataStore
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        observeWindowFocus()
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = dataStore
        configuration.userContentController = controller.configuration.webViewConfiguration.userContentController
        configuration.webExtensionController = controller
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    }

    func reconcile() async throws {
        revision += 1
        prepared = false
        let requestedRevision = revision
        while appliedRevision < requestedRevision {
            if let running = reconcileTask {
                try await running.task.value
                if reconcileTask?.id == running.id { reconcileTask = nil }
                continue
            }
            let targetRevision = revision
            let taskID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                try await self.applyRecords(revision: targetRevision)
            }
            reconcileTask = (taskID, task)
            do {
                try await task.value
                if reconcileTask?.id == taskID { reconcileTask = nil }
            } catch {
                if reconcileTask?.id == taskID { reconcileTask = nil }
                throw error
            }
        }
    }

    private func applyRecords(revision targetRevision: Int) async throws {
        observers.values.forEach(NotificationCenter.default.removeObserver)
        observers.values.removeAll()
        try unloadExistingContexts()
        guard let manager else { appliedRevision = targetRevision; prepared = true; return }
        let records = manager.records.filter { $0.profileID == id.profileID && $0.isEnabled
            && (!id.isPrivate || $0.allowsPrivateBrowsing) }
        for record in records {
            do {
                let native = try await manager.extensionForRecord(record)
                guard targetRevision == revision else { return }
                let context = WKWebExtensionContext(for: native)
                context.uniqueIdentifier = record.id.uuidString.lowercased()
                context.baseURL = URL(string: "webkit-extension://\(record.id.uuidString.lowercased())")!
                context.hasAccessToPrivateData = (id.isPrivate && record.allowsPrivateBrowsing)
                    || needsNonPersistentStoreAccessWorkaround
                context.unsupportedAPIs = ["browser.windows.create"]
                let optional = Set((record.allowedOptionalPermissions ?? [])
                    .map(WKWebExtension.Permission.init(rawValue:))).intersection(native.optionalPermissions)
                let permitted = native.requestedPermissions.union(optional)
                    .filter { $0 != .nativeMessaging && $0 != .activeTab }
                context.grantedPermissions = Dictionary(uniqueKeysWithValues: permitted.map { ($0, Date.distantFuture) })
                if native.requestedPermissions.contains(.nativeMessaging) {
                    context.deniedPermissions = [.nativeMessaging: .distantFuture]
                }
                let allowed = Set(record.allowedOrigins).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
                context.grantedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: allowed.map { ($0, Date.distantFuture) })
                let denied = native.allRequestedMatchPatterns.subtracting(allowed)
                context.deniedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: denied.map { ($0, Date.distantFuture) })
                try controller.load(context)
                contexts[record.id] = context
                observers.values.append(NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification,
                    object: context, queue: .main) { [weak self, weak context] _ in
                    Task { @MainActor in
                        guard let self, let context else { return }
                        let message = context.errors.map(\.localizedDescription).joined(separator: "\n")
                        self.manager?.setRuntimeError(message.isEmpty ? nil : message, id: record.id, profileID: record.profileID)
                    }
                })
                observers.values.append(NotificationCenter.default.addObserver(
                    forName: WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
                    object: context, queue: .main) { [weak self, weak context] notification in
                    let removed = notification.userInfo?[WKWebExtensionContext.NotificationUserInfoKey.permissions]
                        as? Set<WKWebExtension.Permission> ?? []
                    Task { @MainActor in
                        guard let self, let context, self.owns(context), !removed.isEmpty else { return }
                        await self.manager?.removeOptionalPermissions(removed, id: record.id, profileID: record.profileID)
                    }
                })
            } catch {
                manager.setRuntimeError(error.localizedDescription, id: record.id, profileID: record.profileID)
            }
        }
        guard targetRevision == revision else { return }
        appliedRevision = targetRevision
        prepared = true
    }

    func prepare() async throws {
        guard !prepared else { return }
        try await reconcile()
    }

    func stopForRemoval(id: UUID) async throws -> WKWebExtension.DataRecord? {
        let types = WKWebExtensionController.allExtensionDataTypes
        let record = await controller.dataRecords(ofTypes: types).first {
            $0.uniqueIdentifier == id.uuidString.lowercased()
        }
        if let context = contexts[id] {
            revokePermissions(for: context)
            try controller.unload(context)
            contexts.removeValue(forKey: id)
            disposePopups(for: context)
        }
        return record
    }

    private func unloadExistingContexts() throws {
        var retained: [UUID: WKWebExtensionContext] = [:]
        var firstError: Error?
        for (id, context) in contexts {
            revokePermissions(for: context)
            do {
                try controller.unload(context)
                disposePopups(for: context)
            }
            catch {
                retained[id] = context
                firstError = firstError ?? error
                manager?.setRuntimeError(String(format: String(localized: "The extension could not be stopped: %@"), error.localizedDescription),
                    id: id, profileID: self.id.profileID)
            }
        }
        contexts = retained
        if let firstError { throw firstError }
    }

    private func revokePermissions(for context: WKWebExtensionContext) {
        closePopups(for: context)
        let permissions = context.currentPermissions.union(context.webExtension.requestedPermissions)
            .union(context.webExtension.optionalPermissions)
        let patterns = context.currentPermissionMatchPatterns.union(context.webExtension.allRequestedMatchPatterns)
        context.grantedPermissions = [:]
        context.deniedPermissions = Dictionary(uniqueKeysWithValues: permissions.map { ($0, Date.distantFuture) })
        context.grantedPermissionMatchPatterns = [:]
        context.deniedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: patterns.map { ($0, Date.distantFuture) })
        context.hasAccessToPrivateData = false
    }

    func closePopups(for context: WKWebExtensionContext) {
        Array(popupWindows.values).filter { $0.context === context }.forEach { $0.close() }
    }

    private func disposePopups(for context: WKWebExtensionContext) {
        closePopups(for: context)
    }

    var presentedPopupCount: Int { popupWindows.values.filter(\.isVisible).count }
    var presentedPopupWebView: WKWebView? { popupWindows.values.first(where: \.isVisible)?.webView }

    func close() {
        observers.values.forEach(NotificationCenter.default.removeObserver)
        observers.values.removeAll()
        windowObservers.values.forEach(NotificationCenter.default.removeObserver)
        windowObservers.values.removeAll()
        for context in contexts.values {
            revokePermissions(for: context)
            try? controller.unload(context)
            disposePopups(for: context)
        }
        contexts.removeAll()
        pages.removeAll()
        openedPages.removeAll()
        pageWindows.removeAll()
        movingPages.removeAll()
        activePages.removeAll()
        windows.removeAll()
        prepared = false
        revision += 1
        reconcileTask?.task.cancel()
        reconcileTask = nil
        controller.delegate = nil
    }

    func didOpen(_ page: WebKitPage) {
        prunePages()
        guard !pages.contains(where: { $0.value === page }) else { return }
        pages.append(WeakPage(value: page))
    }

    func didClose(_ page: WebKitPage) {
        let pageID = ObjectIdentifier(page)
        let pendingMove = movingPages.removeValue(forKey: pageID)
        if openedPages.remove(pageID) != nil { controller.didCloseTab(page) }
        pages.removeAll { $0.value == nil || $0.value === page }
        if let window = pageWindows.removeValue(forKey: pageID)?.value {
            let windowID = ObjectIdentifier(window)
            if activePages[windowID]?.value === page { activePages.removeValue(forKey: windowID) }
            closeEmptyWindow(window)
        }
        if let oldWindow = pendingMove?.window.nativeWindow { closeEmptyWindow(oldWindow) }
    }

    private func closeEmptyWindow(_ window: NSWindow) {
        guard !pageWindows.values.contains(where: { $0.value === window }),
              !movingPages.values.contains(where: { $0.window.nativeWindow === window }) else { return }
        if let adapter = windows.removeValue(forKey: ObjectIdentifier(window)) {
            controller.didCloseWindow(adapter)
        }
    }

    func didChange(_ page: WebKitPage, properties: WKWebExtension.TabChangedProperties) {
        controller.didChangeTabProperties(properties, for: page)
    }

    func owns(_ context: WKWebExtensionContext) -> Bool { contexts.values.contains { $0 === context } }

    fileprivate func applyOptionalPermissions(_ permissions: Set<WKWebExtension.Permission>, extensionID: UUID) {
        guard let context = contexts[extensionID] else { return }
        var grants = context.grantedPermissions
        for permission in permissions { grants[permission] = .distantFuture }
        context.grantedPermissions = grants
    }

    func willMove(_ page: WebKitPage) {
        let pageID = ObjectIdentifier(page)
        guard let nativeWindow = pageWindows[pageID]?.value else { return }
        let windowID = ObjectIdentifier(nativeWindow)
        let adapter = window(for: nativeWindow)
        let index = tabs(in: nativeWindow).firstIndex(where: { $0 === page }) ?? 0
        movingPages[pageID] = (adapter, index)
        pageWindows.removeValue(forKey: pageID)
        if activePages[windowID]?.value === page {
            activePages.removeValue(forKey: windowID)
            controller.didDeselectTabs([page])
        }
    }

    func setActive(_ page: WebKitPage, active: Bool) {
        prunePages()
        let pageID = ObjectIdentifier(page)
        if let move = movingPages[pageID] {
            guard active, let currentWindow = page.storedWebViewForExtensions?.window,
                  currentWindow !== move.window.nativeWindow else { return }
        }
        if let currentWindow = page.storedWebViewForExtensions?.window {
            pageWindows[pageID] = WeakWindow(value: currentWindow)
        }
        guard let nativeWindow = pageWindows[pageID]?.value else { return }
        let windowID = ObjectIdentifier(nativeWindow)
        // A retained tab remains the browser window's selection while AppKit reparents or
        // temporarily detaches its view. The next activation reports the actual selection change.
        guard active else { return }
        let wasKnown = windows[windowID] != nil
        let adapter = window(for: nativeWindow)
        let previous = activePages[windowID]?.value
        activePages[windowID] = WeakPage(value: page)
        if !wasKnown { controller.didOpenWindow(adapter) }
        if openedPages.insert(pageID).inserted { controller.didOpenTab(page) }
        if let move = movingPages.removeValue(forKey: pageID) {
            controller.didMoveTab(page, from: move.index, in: move.window)
            if let oldWindow = move.window.nativeWindow { closeEmptyWindow(oldWindow) }
        }
        if previous !== page {
            if let previous { controller.didDeselectTabs([previous]) }
            controller.didActivateTab(page, previousActiveTab: previous)
            controller.didSelectTabs([page])
        }
        if nativeWindow.isKeyWindow { controller.didFocusWindow(adapter) }
    }

    func window(for page: WebKitPage) -> WebKitExtensionWindow? {
        guard movingPages[ObjectIdentifier(page)] == nil else { return nil }
        guard let nativeWindow = pageWindows[ObjectIdentifier(page)]?.value
                ?? page.storedWebViewForExtensions?.window else { return nil }
        return window(for: nativeWindow)
    }

    private func window(for nativeWindow: NSWindow) -> WebKitExtensionWindow {
        let key = ObjectIdentifier(nativeWindow)
        if let existing = windows[key] { return existing }
        let adapter = WebKitExtensionWindow(session: self, nativeWindow: nativeWindow)
        windows[key] = adapter
        return adapter
    }

    fileprivate func activePage(in nativeWindow: NSWindow?) -> WebKitPage? {
        guard let nativeWindow else { return nil }
        return activePages[ObjectIdentifier(nativeWindow)]?.value
    }

    fileprivate func tabs(in nativeWindow: NSWindow?) -> [WebKitPage] {
        prunePages()
        return pages.compactMap(\.value).filter { page in
            guard movingPages[ObjectIdentifier(page)] == nil else { return false }
            guard let pageWindow = pageWindows[ObjectIdentifier(page)]?.value
                    ?? page.storedWebViewForExtensions?.window else { return false }
            return pageWindow === nativeWindow
        }
    }

    private func prunePages() {
        let live = Set(pages.compactMap(\.value).map(ObjectIdentifier.init))
        pages.removeAll { $0.value == nil }
        openedPages.formIntersection(live)
        movingPages = movingPages.filter { live.contains($0.key) }
        pageWindows = pageWindows.filter { live.contains($0.key) && $0.value.value != nil }
        activePages = activePages.filter { $0.value.value != nil }
        windows = windows.filter { $0.value.nativeWindow != nil }
    }

    private func observeWindowFocus() {
        windowObservers.values = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window, let adapter = self.windows[ObjectIdentifier(window)] else { return }
                    self.controller.didFocusWindow(adapter)
                }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.windows.values.contains(where: { $0.nativeWindow?.isKeyWindow == true }) else { return }
                    self.controller.didFocusWindow(nil)
                }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window else { return }
                    let id = ObjectIdentifier(window)
                    guard let adapter = self.windows.removeValue(forKey: id) else { return }
                    self.activePages.removeValue(forKey: id)
                    self.controller.didCloseWindow(adapter)
                }
            }
        ]
    }

    func webExtensionController(_ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        prunePages()
        return Array(windows.values)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windows.values.first(where: { $0.nativeWindow?.isKeyWindow == true }) ?? windows.values.first
    }

    func webExtensionController(_ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        let requestedWindow = configuration.window as? WebKitExtensionWindow
        let host = requestedWindow?.activePage ?? activePages.values.compactMap(\.value).first
        guard let host, let child = host.createExtensionChild(url: configuration.url,
            configuration: configurationForPage(url: configuration.url, extensionContext: extensionContext)) else {
            completionHandler(nil, extensionError(String(localized: "Cobble could not open an extension tab in this window."))); return
        }
        completionHandler(child, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let url = extensionContext.optionsPageURL,
              let host = activePages.values.compactMap(\.value).first,
              host.createExtensionChild(url: url, configuration: configurationForPage(url: url, extensionContext: extensionContext)) != nil else {
            completionHandler(extensionError(String(localized: "The extension options page could not be opened."))); return
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        guard !id.isPrivate, owns(extensionContext),
              let record = record(for: extensionContext), record.isEnabled,
              let window = (tab as? WebKitPage)?.storedWebViewForExtensions?.window
                ?? windows.values.first(where: { $0.nativeWindow?.isKeyWindow == true })?.nativeWindow,
              !permissions.isEmpty,
              permissions.isSubset(of: extensionContext.webExtension.optionalPermissions),
              !permissions.contains(.nativeMessaging), !permissions.contains(.activeTab) else {
            completionHandler([], nil)
            return
        }
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        let alert = PagePresenter.alert(title: String(format: String(localized: "Allow %@ to use additional permissions?"), record.name),
            message: names, buttons: [String(localized: "Allow"), String(localized: "Deny")])
        alert.beginSheetModal(for: window) { [weak self, weak extensionContext] response in
            guard response == .alertFirstButtonReturn, let self, let extensionContext,
                  self.owns(extensionContext), !self.id.isPrivate, let manager = self.manager else {
                completionHandler([], nil)
                return
            }
            do {
                try manager.grantOptionalPermissions(permissions, id: record.id, profileID: record.profileID)
                completionHandler(permissions, nil)
            } catch {
                manager.setRuntimeError(error.localizedDescription, id: record.id, profileID: record.profileID)
                completionHandler([], nil)
            }
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void) {
        replyHandler(nil, extensionError(String(localized: "Native messaging is not supported by Cobble.")))
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(extensionError(String(localized: "Native messaging is not supported by Cobble.")))
    }

    func webExtensionController(_ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        guard let record = record(for: extensionContext) else { completionHandler([], nil); return }
        let allowed = urls.filter { url in record.allowedOrigins.contains {
            (try? WKWebExtension.MatchPattern(string: $0))?.matches(url) == true
        } }
        completionHandler(Set(allowed), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let allowed = Set(record(for: extensionContext)?.allowedOrigins ?? [])
        completionHandler(Set(patterns.filter { allowed.contains($0.string) }), nil)
    }

    private func record(for context: WKWebExtensionContext) -> WebKitExtensionManager.Record? {
        guard let uuid = UUID(uuidString: context.uniqueIdentifier) else { return nil }
        return manager?.record(id: uuid, profileID: id.profileID)
    }

    func performAction(id: UUID, on page: WebKitPage) throws {
        guard let context = contexts[id], owns(context), pages.contains(where: { $0.value === page }),
              let action = context.action(for: page), action.isEnabled else {
            throw EngineError.notReady(String(localized: "This extension has no enabled action for the current tab."))
        }
        if let popup = popupWindows[ObjectIdentifier(context)] {
            guard let view = page.storedWebViewForExtensions, view.window != nil else {
                throw EngineError.notReady(String(localized: "The extension popup has no active browser tab."))
            }
            popup.show(relativeTo: view)
            return
        }
        context.performAction(for: page)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        let page = action.associatedTab as? WebKitPage ?? activePages.values.compactMap(\.value).first
        guard let page else {
            completionHandler(extensionError(String(localized: "The extension popup has no active browser tab.")))
            return
        }
        do {
            try presentPopup(action: action, context: context, page: page)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    private func presentPopup(action: WKWebExtension.Action, context: WKWebExtensionContext,
                              page: WebKitPage) throws {
        guard let view = page.storedWebViewForExtensions, view.window != nil,
              let popover = action.popupPopover, let popupWebView = action.popupWebView else {
            throw extensionError(String(localized: "The extension popup has no active browser tab."))
        }
        let key = ObjectIdentifier(context)
        if let existing = popupWindows[key] { existing.show(relativeTo: view) }
        else {
            popupWindows[key] = PopupWindowLifetime(context: context, popover: popover,
                webView: popupWebView, anchorView: view) { [weak self] in
                    self?.popupWindows.removeValue(forKey: key)
                }
        }
    }

    private func configurationForPage(url: URL?, extensionContext: WKWebExtensionContext) -> WKWebViewConfiguration {
        if let url, url.scheme == extensionContext.baseURL.scheme, url.host == extensionContext.baseURL.host,
           let configuration = extensionContext.webViewConfiguration { return configuration }
        let configuration = WKWebViewConfiguration()
        configure(configuration)
        return configuration
    }

    private func extensionError(_ message: String) -> NSError {
        NSError(domain: "Cobble.WebExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class WebKitExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let session: WebKitExtensionSession
    weak var nativeWindow: NSWindow?
    init(session: WebKitExtensionSession, nativeWindow: NSWindow?) {
        self.session = session
        self.nativeWindow = nativeWindow
    }
    var activePage: WebKitPage? {
        session.activePage(in: nativeWindow)
    }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { session.tabs(in: nativeWindow) }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activePage }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { session.id.isPrivate }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nativeWindow?.screen?.frame ?? .null }
    func frame(for context: WKWebExtensionContext) -> CGRect { nativeWindow?.frame ?? .null }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        nativeWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let nativeWindow else {
            completionHandler(NSError(domain: "Cobble.WebExtension", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "The browser window is unavailable.")])); return
        }
        nativeWindow.performClose(nil)
        completionHandler(nil)
    }
}
