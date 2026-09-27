import Foundation

struct WebsiteDataGroup: Identifiable {
    struct Member { let contextID: BrowsingContextID; let recordID: UUID }
    let displayName: String
    var members: [Member]
    var id: String { displayName }
}

extension AppModel {
    func websiteData(profileID: UUID) async -> (sites: [WebsiteDataGroup], error: String?) {
        guard !isDeletingProfile(profileID), let profile = profiles.first(where: { $0.id == profileID }) else { return ([], String(localized: "Profile unavailable or being deleted.")) }
        var groups: [String: WebsiteDataGroup] = [:]
        var failures: [String] = []
        let listing = WebsiteDataRemovalCapability(categories: [.siteData, .cache], scope: .recordsAllTime)
        for engine in engines.engines where engine.capabilities.websiteDataRemoval.contains(listing) {
            do {
                let context = try engines.context(engineID: engine.id, profile: profile, siteSettings: siteSettings,
                                                 recordUse: false)
                for record in try await context.websiteData() {
                    let member = WebsiteDataGroup.Member(contextID: context.id, recordID: record.id)
                    groups[record.displayName, default: WebsiteDataGroup(displayName: record.displayName, members: [])].members.append(member)
                }
            } catch { failures.append(String(format: String(localized: "%@: %@"), engine.name, error.localizedDescription)) }
        }
        guard failures.isEmpty else { return ([], failures.joined(separator: "\n")) }
        return (groups.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }, nil)
    }

    /// Caller confirms the loss of live page state before entering this operation.
    func clearWebsiteData(profileID: UUID, site: WebsiteDataGroup? = nil) async -> String? {
        await removeWebsiteData(profileID: profileID, site: site,
            categories: site == nil ? [.cache] : [.siteData, .cache])
    }

    func removeWebsiteData(profileID: UUID, site: WebsiteDataGroup? = nil,
                           categories: Set<WebsiteDataCategory>, modifiedSince: Date? = nil) async -> String? {
        if let site, site.members.contains(where: {
            $0.contextID.profileID != profileID || $0.contextID.privateWindowID != nil
        }) {
            return String(localized: "Website data selection changed. Refresh and try again.")
        }
        guard !categories.isEmpty else { return String(localized: "Choose website data to remove.") }
        if site != nil, modifiedSince != nil {
            return String(localized: "A time range cannot be used when removing one website.")
        }
        if let modifiedSince {
            let seconds = modifiedSince.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, modifiedSince <= Date() else {
                return String(localized: "Choose a valid website data time range.")
            }
        }
        guard !isDeletingProfile(profileID), let profile = profiles.first(where: { $0.id == profileID }) else { return String(localized: "Profile unavailable or being deleted.") }
        let scopeKind: WebsiteDataRemovalScopeKind = site != nil ? .recordsAllTime : (modifiedSince == nil ? .profileAllTime : .profileSince)
        let targetEngines: [any BrowserEngine]
        if let site {
            let engineIDs = Set(site.members.map(\.contextID.engineID))
            targetEngines = engineIDs.compactMap { engines.engine($0) }
            guard targetEngines.count == engineIDs.count else {
                return String(localized: "Website data selection changed. Refresh and try again.")
            }
        } else {
            targetEngines = engines.engines.filter { !$0.capabilities.websiteDataRemoval.isEmpty }
        }
        guard !targetEngines.isEmpty, targetEngines.allSatisfy({
            $0.capabilities.supportsWebsiteDataRemoval(categories: categories, scope: scopeKind)
        }) else { return String(localized: "That website data range is not supported by every active engine.") }
        let ids = Set(site?.members.map(\.contextID) ?? targetEngines.map {
            BrowsingContextID(engineID: $0.id, profileID: profileID, privateWindowID: nil)
        })
        var contexts: [BrowsingContextID: any EngineContext] = [:]
        do {
            for id in ids {
                let context = try engines.context(engineID: id.engineID, profile: profile, siteSettings: siteSettings, recordUse: false)
                guard context.capabilities.supportsWebsiteDataRemoval(categories: categories, scope: scopeKind) else {
                    return String(localized: "That website data range is not supported by every active engine.")
                }
                contexts[id] = context
            }
        } catch {
            return String(format: String(localized: "Website data could not be prepared: %@"), error.localizedDescription)
        }
        guard suspendedContexts.isDisjoint(with: ids) else { return String(localized: "Website data is already being cleared.") }
        suspendedContexts.formUnion(ids)
        defer { suspendedContexts.subtract(ids) }
        for window in windows where !window.isPrivate { window.unloadPages(in: ids) }
        await engines.waitForRetiredPages(in: ids)
        var failures: [String] = []
        for id in ids {
            do {
                guard let context = contexts[id] else { throw EngineError.closed }
                let scope: WebsiteDataRemovalScope = site.map {
                    .records($0.members.filter { $0.contextID == id }.map(\.recordID))
                } ?? .profile(modifiedSince: modifiedSince)
                try await context.removeWebsiteData(.init(categories: categories, scope: scope))
            } catch { failures.append(String(format: String(localized: "%@: %@"), engines.engine(id.engineID)?.name ?? id.engineID.rawValue, error.localizedDescription)) }
        }
        return failures.isEmpty ? nil : String(localized: "Some website data could not be removed.\n") + failures.joined(separator: "\n")
    }
}
