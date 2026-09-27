import Foundation

struct ExtensionCapabilities: Sendable {
    enum WebsiteAccess: Sendable { case declaredPatterns, individualSites }
    var websiteAccess: WebsiteAccess = .declaredPatterns
    var supportsPrivateBrowsing = true
    var supportsProviderBundles = true
}

struct BrowserExtensionInfo: Identifiable, Hashable, Sendable {
    let id: UUID
    let profileID: UUID
    let name: String
    let version: String
    let sourceURL: URL
    let hasAction: Bool
    let isEnabled: Bool
    let deniedPermissions: [String]
    let requestedOrigins: [String]
    let allowedOrigins: [String]
    let allowsPrivateBrowsing: Bool
    let errorMessage: String?
    var allowedOptionalPermissions: [String] = []
}

@MainActor protocol BrowserExtensionManaging: ProfileMutationGuarded {
    var capabilities: ExtensionCapabilities { get }
    var lastError: String? { get }
    var onChange: (() -> Void)? { get set }
    func extensions(profileID: UUID) -> [BrowserExtensionInfo]
    func install(from sourceURL: URL, profileID: UUID) async throws
    func setEnabled(_ enabled: Bool, id: UUID, profileID: UUID) async throws
    func setAllowedOrigins(_ origins: [String], id: UUID, profileID: UUID) async throws
    func setAllowedOptionalPermissions(_ permissions: [String], id: UUID, profileID: UUID) async throws
    func setPrivateBrowsingAllowed(_ allowed: Bool, id: UUID, profileID: UUID) async throws
    func performAction(id: UUID, profileID: UUID, on page: (any BrowserPage)?) async throws
    func remove(id: UUID, profileID: UUID) async throws
}

extension BrowserExtensionManaging {
    var capabilities: ExtensionCapabilities { ExtensionCapabilities() }
    func setAllowedOptionalPermissions(_: [String], id: UUID, profileID: UUID) async throws {
        throw EngineError.unsupported(String(localized: "optional extension permissions"))
    }
}
