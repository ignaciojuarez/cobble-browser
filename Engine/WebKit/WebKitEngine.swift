import WebKit

@MainActor final class WebKitEngine: BrowserEngine {
    let id = EngineID.webKit
    let name = "WebKit"
    static var supported: EngineCapabilities {
        var operations: Set<PageOperation> = [.find, .zoom, .printPage, .reloadFromOrigin, .snapshot, .localFile, .savePage, .pageDOM, .inspect, .detach]
        if WebKitAudioMute.isAvailable { operations.insert(.muteAudio) }
        return EngineCapabilities(pageOperations: operations,
            permissions: [.camera, .microphone],
            captureControls: [.mute(.camera), .stop(.camera), .mute(.microphone), .stop(.microphone)],
            websiteDataRemoval: WebKitContext.dataRemovalCapabilities,
            supportsPopupPolicy: true, supportsProfileDeletion: true, supportsCookieTransfer: true,
            supportsBrowserIdentity: true)
    }
    var capabilities: EngineCapabilities { Self.supported }
    let blocker: WebKitContentBlocker
    var contentBlocker: (any EngineContentBlocker)? { blocker }
    private(set) var extensionManager: (any BrowserExtensionManaging)?
    let dataStoreOverride: WKWebsiteDataStore?

    init(directory: URL, dataStoreOverride: WKWebsiteDataStore? = nil) {
        self.dataStoreOverride = dataStoreOverride
        blocker = WebKitContentBlocker(directory: directory)
        extensionManager = WebKitExtensionManager(directory: directory,
            persistentStorageAllowed: dataStoreOverride?.isPersistent ?? true)
    }
    func makeContext(profile: Profile, id: BrowsingContextID, siteSettings: SiteSettingsStore) throws -> any EngineContext {
        let store: WKWebsiteDataStore
        if id.isPrivate { store = .nonPersistent() }
        else if let dataStoreOverride { store = dataStoreOverride }
        else {
            switch profile.storeBinding {
            case .legacyDefault: store = .default()
            case .named(let identifier): store = WKWebsiteDataStore(forIdentifier: identifier)
            }
        }
        let extensionSession: AnyObject?
        if let manager = extensionManager as? WebKitExtensionManager {
            extensionSession = manager.makeSession(id: id, dataStore: store)
        } else { extensionSession = nil }
        return WebKitContext(id: id, dataStore: store, blocker: blocker, siteSettings: siteSettings,
                             extensionSession: extensionSession)
    }
    func removeProfile(_ profile: Profile) async throws {
        guard case let .named(identifier) = profile.storeBinding else { return }
        if let manager = extensionManager as? WebKitExtensionManager {
            for item in manager.extensions(profileID: profile.id) {
                try await manager.removeForProfileDeletion(id: item.id, profileID: profile.id)
            }
        } else if let extensionManager {
            for item in extensionManager.extensions(profileID: profile.id) {
                try await extensionManager.remove(id: item.id, profileID: profile.id)
            }
        }
        try await blocker.removeProfile(profile.id)
        guard dataStoreOverride == nil else { return }
        do { try await removeDataStore(identifier) }
        catch {
            // WebKit can release its final file handles one run-loop turn after
            // the store dies. Retry once, but still surface a persistent error.
            try await Task.sleep(for: .milliseconds(100))
            try await removeDataStore(identifier)
        }
    }
    private func removeDataStore(_ identifier: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
    func shutdown() async {}
}

@MainActor final class WebKitContext: EngineContext {
    static let dataRemovalCapabilities: Set<WebsiteDataRemovalCapability> = [
        .init(categories: [.siteData], scope: .recordsAllTime),
        .init(categories: [.cache], scope: .recordsAllTime),
        .init(categories: [.siteData, .cache], scope: .recordsAllTime),
        .init(categories: [.siteData], scope: .profileAllTime),
        .init(categories: [.cache], scope: .profileAllTime),
        .init(categories: [.siteData, .cache], scope: .profileAllTime),
        .init(categories: [.cache], scope: .profileSince),
    ]
    let id: BrowsingContextID
    let dataStore: WKWebsiteDataStore
    let blocker: WebKitContentBlocker
    let siteSettings: SiteSettingsStore
    let extensionSession: AnyObject?
    var capabilities: EngineCapabilities {
        var result = WebKitEngine.supported
        result.supportsCookieTransfer = !id.isPrivate
        return result
    }
    private var records: [UUID: WKWebsiteDataRecord] = [:]
    private(set) var closed = false

    init(id: BrowsingContextID, dataStore: WKWebsiteDataStore, blocker: WebKitContentBlocker,
         siteSettings: SiteSettingsStore, extensionSession: AnyObject?) {
        self.id = id; self.dataStore = dataStore; self.blocker = blocker
        self.siteSettings = siteSettings; self.extensionSession = extensionSession
    }
    func makePage(tabID: UUID, windowID: UUID) throws -> any BrowserPage {
        guard !closed else { throw EngineError.closed }
        return WebKitPage(tabID: tabID, dataStore: dataStore, siteSettings: siteSettings,
                          profileID: id.profileID, isPrivate: id.isPrivate, context: self,
                          windowID: windowID) { _, _, _ in }
    }
    func websiteData() async throws -> [WebsiteDataRecord] {
        guard !closed else { throw EngineError.closed }
        let fetched = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        guard !closed else { throw EngineError.closed }
        // Reuse handles for records still present; never expose SDK records to Settings.
        var current: [UUID: WKWebsiteDataRecord] = [:]
        let result = fetched.map { record in
            let id = records.first(where: { $0.value.displayName == record.displayName })?.key ?? UUID()
            current[id] = record
            return WebsiteDataRecord(id: id, displayName: record.displayName)
        }
        records = current
        return result
    }
    func removeWebsiteData(_ request: WebsiteDataRemovalRequest) async throws {
        guard !closed else { throw EngineError.closed }
        guard Self.dataRemovalCapabilities.contains(request.capability), !request.categories.isEmpty else {
            throw EngineError.unsupported("this website data range")
        }
        let cacheTypes: Set<String> = [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache]
        var types = Set<String>()
        if request.categories.contains(.cache) { types.formUnion(cacheTypes) }
        if request.categories.contains(.siteData) {
            types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes))
        }
        switch request.scope {
        case .records(let ids):
            let selected = try ids.map { id in
                guard let record = records[id] else { throw EngineError.notReady(String(localized: "Website data changed. Refresh and try again.")) }
                return record
            }
            guard !selected.isEmpty else { return }
            await dataStore.removeData(ofTypes: types, for: selected)
            ids.forEach { records.removeValue(forKey: $0) }
        case .profile(let modifiedSince):
            if let modifiedSince {
                let seconds = modifiedSince.timeIntervalSince1970
                guard seconds.isFinite, seconds >= 0, modifiedSince <= Date() else {
                    throw EngineError.notReady(String(localized: "Choose a valid website data time range."))
                }
            }
            await dataStore.removeData(ofTypes: types, modifiedSince: modifiedSince ?? .distantPast)
            records.removeAll()
        }
    }
    func close() async {
        closed = true
        records.removeAll()
        if let session = extensionSession as? WebKitExtensionSession {
            session.close()
        }
    }
}
