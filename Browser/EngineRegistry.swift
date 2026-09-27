import Foundation

@MainActor final class EngineRegistry {
    let engines: [any BrowserEngine]
    private var bindings: [BrowsingContextID: Profile.StoreBinding] = [:]
    private var contexts: [BrowsingContextID: any EngineContext] = [:]
    private var closingPages: [ObjectIdentifier: (contextID: BrowsingContextID, task: Task<Void, Never>)] = [:]
    private var closingContexts: [UUID: (contextID: BrowsingContextID, task: Task<Void, Never>)] = [:]
    var engineUseAllowed: ((UUID, EngineID) -> Bool)?

    init(_ engines: [any BrowserEngine]) {
        precondition(Set(engines.map(\.id)).count == engines.count, "Engine IDs must be unique")
        self.engines = engines
    }
    func engine(_ id: EngineID) -> (any BrowserEngine)? { engines.first { $0.id == id } }
    /// Build availability affects execution, never the saved engine choice.
    func effectiveID(_ requested: EngineID) -> EngineID {
        if requested == EngineID(rawValue: "chromium"), engine(requested) == nil,
           engine(.webKit) != nil { return .webKit }
        return requested
    }
    func context(engineID: EngineID, profile: Profile, privateWindowID: UUID? = nil,
                 siteSettings: SiteSettingsStore, recordUse: Bool = true) throws -> any EngineContext {
        let tracksEngineUse = recordUse && privateWindowID == nil
        let id = BrowsingContextID(engineID: engineID, profileID: profile.id, privateWindowID: privateWindowID)
        if let context = contexts[id] {
            if tracksEngineUse {
                guard engineUseAllowed?(profile.id, engineID) != false else {
                    throw EngineError.notReady("Cobble could not save this profile’s engine ownership before opening it.")
                }
            }
            return context
        }
        guard let engine = engine(engineID) else { throw EngineError.unavailable(engineID) }
        if tracksEngineUse {
            guard engineUseAllowed?(profile.id, engineID) != false else {
                throw EngineError.notReady("Cobble could not save this profile’s engine ownership before opening it.")
            }
        }
        let context = try engine.makeContext(profile: profile, id: id, siteSettings: siteSettings)
        contexts[id] = context
        bindings[id] = profile.storeBinding
        return context
    }
    func retire(_ page: any BrowserPage) {
        let id = ObjectIdentifier(page)
        guard closingPages[id] == nil, page.state.lifecycle != .closed else { return }
        page.close()
        let task = Task { [weak self] in
            await page.waitUntilClosed()
            self?.closingPages.removeValue(forKey: id)
        }
        closingPages[id] = (page.contextID, task)
    }
    func waitForRetiredPages(in contexts: Set<BrowsingContextID>) async {
        // Callers suspend activation and retire live pages before taking this snapshot.
        let tasks = closingPages.values.filter { contexts.contains($0.contextID) }.map(\.task)
        for task in tasks { await task.value }
    }
    private func retireContext(_ id: BrowsingContextID) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        bindings.removeValue(forKey: id)
        let pages = closingPages.values.filter { $0.contextID == id }.map(\.task)
        let operation = UUID()
        let task = Task { [weak self] in
            for page in pages { await page.value }
            await context.close()
            self?.closingContexts.removeValue(forKey: operation)
        }
        closingContexts[operation] = (id, task)
    }
    func releasePrivateWindow(_ windowID: UUID) {
        for id in Array(contexts.keys) where id.privateWindowID == windowID { retireContext(id) }
    }
    func reconcileProfiles(_ profiles: [Profile]) {
        for id in Array(contexts.keys) {
            guard let profile = profiles.first(where: { $0.id == id.profileID }), bindings[id] == profile.storeBinding else {
                retireContext(id); continue
            }
        }
    }
    func retireProfile(_ profileID: UUID) async {
        for id in Array(contexts.keys) where id.profileID == profileID { retireContext(id) }
        for entry in Array(closingContexts.values) where entry.contextID.profileID == profileID {
            await entry.task.value
        }
    }
    func shutdown() async {
        for task in closingPages.values.map(\.task) { await task.value }
        for entry in Array(closingContexts.values) { await entry.task.value }
        for context in contexts.values { await context.close() }
        contexts.removeAll(); bindings.removeAll()
        for engine in engines { await engine.shutdown() }
    }
}
