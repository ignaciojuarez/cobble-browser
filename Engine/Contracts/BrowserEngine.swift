import Foundation

@MainActor protocol ProfileMutationGuarded: AnyObject {
    var profileMutationAllowed: ((UUID) -> Bool)? { get set }
}

enum WebsiteDataCategory: Hashable, Sendable { case siteData, cache }
enum WebsiteDataRemovalScopeKind: Hashable, Sendable { case recordsAllTime, profileAllTime, profileSince }
struct WebsiteDataRemovalCapability: Hashable, Sendable {
    let categories: Set<WebsiteDataCategory>
    let scope: WebsiteDataRemovalScopeKind
}
enum WebsiteDataRemovalScope: Hashable, Sendable {
    case records([UUID])
    /// `nil` means all time. A date is passed through as the requested cutoff;
    /// an engine may also clear transient in-memory caches.
    case profile(modifiedSince: Date?)
}
struct WebsiteDataRemovalRequest: Hashable, Sendable {
    let categories: Set<WebsiteDataCategory>
    let scope: WebsiteDataRemovalScope

    var capability: WebsiteDataRemovalCapability {
        let kind: WebsiteDataRemovalScopeKind
        switch scope {
        case .records: kind = .recordsAllTime
        case .profile(nil): kind = .profileAllTime
        case .profile(.some): kind = .profileSince
        }
        return WebsiteDataRemovalCapability(categories: categories, scope: kind)
    }
}
struct EngineCapabilities: Sendable {
    var pageOperations: Set<PageOperation> = []
    /// A user-initiated close can be refused by the native engine, for example
    /// while Chromium is running before-unload handlers.
    var requiresCloseConfirmation = false
    var permissions: Set<PermissionKind> = []
    var captureControls: Set<PageCaptureControl> = []
    var websiteDataRemoval: Set<WebsiteDataRemovalCapability> = []
    var supportsPopupPolicy = false
    var supportsProfileDeletion = false
    var supportsCookieTransfer = false
    var supportsBrowserIdentity = false
}

extension EngineCapabilities {
    func supportsWebsiteDataRemoval(categories: Set<WebsiteDataCategory>, scope: WebsiteDataRemovalScopeKind) -> Bool {
        websiteDataRemoval.contains(.init(categories: categories, scope: scope))
    }
}

enum EngineError: LocalizedError {
    case unavailable(EngineID), unsupported(String), closed, notReady(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let id): String(format: String(localized: "The engine %@ is unavailable. Choose another engine to reopen this tab."), id.rawValue)
        case .unsupported(let operation): String(format: String(localized: "This engine does not support %@."), operation)
        case .closed: String(localized: "The page is closed.")
        case .notReady(let reason): reason
        }
    }
}

@MainActor protocol BrowserEngine: AnyObject {
    var id: EngineID { get }
    var name: String { get }
    var capabilities: EngineCapabilities { get }
    var contentBlocker: (any EngineContentBlocker)? { get }
    var extensionManager: (any BrowserExtensionManaging)? { get }
    func makeContext(profile: Profile, id: BrowsingContextID, siteSettings: SiteSettingsStore) throws -> any EngineContext
    func preflightProfileDeletion(_ profile: Profile) async throws
    func removeProfile(_ profile: Profile) async throws
    func shutdown() async
}

extension BrowserEngine {
    var extensionManager: (any BrowserExtensionManaging)? { nil }
    func preflightProfileDeletion(_: Profile) async throws {
        guard capabilities.supportsProfileDeletion else {
            throw EngineError.unsupported(String(format: String(localized: "Profile deletion for %@"), name))
        }
    }
    func removeProfile(_ profile: Profile) async throws {
        throw EngineError.unsupported(String(format: String(localized: "Profile deletion for %@"), name))
    }
}

struct WebsiteDataRecord: Identifiable, Hashable {
    let id: UUID
    let displayName: String
}

@MainActor protocol EngineContext: AnyObject {
    var id: BrowsingContextID { get }
    var capabilities: EngineCapabilities { get }
    func makePage(tabID: UUID, windowID: UUID) throws -> any BrowserPage
    func websiteData() async throws -> [WebsiteDataRecord]
    func removeWebsiteData(_ request: WebsiteDataRemovalRequest) async throws
    func exportCookies(for url: URL) async throws -> CookieTransferSnapshot
    /// Replaces supported cookies matching this HTTPS host, including all paths.
    /// Returns rejected writes. Implementations validate the whole batch first.
    func replaceCookies(_ cookies: [EngineCookie], for url: URL) async throws -> Int
    func close() async
}

extension EngineContext {
    func exportCookies(for url: URL) async throws -> CookieTransferSnapshot {
        throw EngineError.unsupported("cross-engine login sharing")
    }
    func replaceCookies(_ cookies: [EngineCookie], for url: URL) async throws -> Int {
        throw EngineError.unsupported("cross-engine login sharing")
    }
    func removeWebsiteData(ids: [UUID]) async throws {
        try await removeWebsiteData(.init(categories: [.siteData, .cache], scope: .records(ids)))
    }
    func clearCache() async throws {
        try await removeWebsiteData(.init(categories: [.cache], scope: .profile(modifiedSince: nil)))
    }
}

@MainActor protocol EngineContentBlocker: ProfileMutationGuarded {
    var formatName: String { get }
    var lastError: String? { get }
    var isReady: Bool { get }
    var canPersistRules: Bool { get }
    var onChange: (() -> Void)? { get set }
    func isEnabled(profileID: UUID) -> Bool
    func canLoad(profileID: UUID) -> Bool
    func waitUntilReady() async
    func hasRules(profileID: UUID) -> Bool
    func usesBundledRules(profileID: UUID) -> Bool
    func useBundledRules(profileID: UUID) async
    func installRules(from source: URL, profileID: UUID) async throws
    func exceptions(profileID: UUID) -> [String]
    func importRules(json: String, profileID: UUID) async
    func installBundledRules(profileID: UUID) async
    func ensureBundledRules(profileID: UUID) async
    func updateSource(profileID: UUID) -> URL?
    func setUpdateSource(_ source: URL?, profileID: UUID) async
    func updateRules(profileID: UUID) async
    func setEnabled(_ enabled: Bool, profileID: UUID) async
    func setException(origin: URL, enabled: Bool, profileID: UUID) async
    func replaceExceptions(_ origins: [String], profileID: UUID) async throws
    func removeProfile(_ profileID: UUID) async throws
}

extension EngineContentBlocker {
    func replaceExceptions(_ origins: [String], profileID: UUID) async throws {
        let previous = Set(exceptions(profileID: profileID)), desired = Set(origins)
        for origin in previous.subtracting(desired) {
            guard let url = URL(string: origin) else { throw EngineError.notReady(String(localized: "Invalid content blocker exception.")) }
            await setException(origin: url, enabled: false, profileID: profileID)
        }
        for origin in desired.subtracting(previous) {
            guard let url = URL(string: origin) else { throw EngineError.notReady(String(localized: "Invalid content blocker exception.")) }
            await setException(origin: url, enabled: true, profileID: profileID)
        }
        guard Set(exceptions(profileID: profileID)) == desired else {
            throw EngineError.notReady(lastError ?? String(localized: "Could not save content blocker exceptions."))
        }
    }

    func removeProfile(_: UUID) async throws {
        throw EngineError.unsupported(String(localized: "Content-blocker profile deletion"))
    }
}

extension EngineContentBlocker {
    func hasRules(profileID: UUID) -> Bool { false }
    func usesBundledRules(profileID: UUID) -> Bool { false }
    func useBundledRules(profileID: UUID) async { await installBundledRules(profileID: profileID) }
    func installRules(from _: URL, profileID _: UUID) async throws {
        throw EngineError.unsupported(String(localized: "Content blocker source installation"))
    }
    func installBundledRules(profileID: UUID) async {}
    func ensureBundledRules(profileID: UUID) async {}
    func updateSource(profileID: UUID) -> URL? { nil }
    func setUpdateSource(_ source: URL?, profileID: UUID) async {}
    func updateRules(profileID: UUID) async {}
}
