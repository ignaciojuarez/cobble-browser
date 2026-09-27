import AppKit
import Observation

enum SettingsSection: Int, CaseIterable {
    case general = 0, privacy, blockers, permissions, history, shortcuts, browsing, extensions, profiles, design, sync

    static let toolbarSections: [Self] = [.general, .browsing, .design, .extensions, .profiles, .privacy, .history, .shortcuts, .sync]
    var toolbarSection: Self { [.privacy, .blockers, .permissions].contains(self) ? .privacy : self }
    var title: String {
        switch self {
        case .sync: String(localized: "Sync")
        case .general: String(localized: "General")
        case .browsing: String(localized: "Browsing")
        case .design: String(localized: "Design")
        case .extensions: String(localized: "Extensions")
        case .profiles: String(localized: "Profiles")
        case .privacy: String(localized: "Privacy")
        case .blockers: String(localized: "Blockers")
        case .permissions: String(localized: "Permissions")
        case .history: String(localized: "History")
        case .shortcuts: String(localized: "Shortcuts")
        }
    }
    var symbol: String {
        switch self {
        case .sync: "icloud"
        case .general: "gearshape"
        case .browsing: "globe"
        case .design: "paintbrush"
        case .extensions: "puzzlepiece.extension"
        case .profiles: "person.2"
        case .privacy: "hand.raised"
        case .history: "clock.arrow.circlepath"
        case .shortcuts: "keyboard"
        case .blockers: "shield.lefthalf.filled"
        case .permissions: "camera"
        }
    }
}

@MainActor @Observable
final class AppModel {
    #if DEBUG
    @ObservationIgnored lazy var resources = ResourcePanelController(app: self)
    #endif
    var profiles: [Profile]
    var spaces: [Space]
    var folders: [Folder]
    var savedItems: [SavedItem]
    var windows: [BrowserWindowModel] = []
    var persistenceMessage: String?
    @ObservationIgnored lazy var sync = SyncCoordinator(app: self, provider: CloudKitSyncProvider())
    let updates = AppUpdater()
    let downloads: DownloadStore
    let preferences: BrowserPreferences
    var settingsSection = SettingsSection.general
    let library: LibraryStore
    let siteSettings: SiteSettingsStore
    let engines: EngineRegistry
    var contentBlocker: (any EngineContentBlocker)? { engines.engine(engines.effectiveID(preferences.defaultEngine))?.contentBlocker }
    var suspendedContexts = Set<BrowsingContextID>()
    var loginSharingMessage: String?
    @ObservationIgnored let store: SessionStore
    @ObservationIgnored var onReplaceWindows: (() -> Void)?
    @ObservationIgnored var onOpenWindow: ((BrowserWindowModel) -> Void)?
    @ObservationIgnored var onActivateWindow: ((BrowserWindowModel) -> Void)?
    @ObservationIgnored var onCloseWindows: (([UUID]) -> Void)?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var deletingProfiles = Set<UUID>()
    @ObservationIgnored private var pendingProfileDeletions: [UUID: Set<EngineID>] = [:]
    @ObservationIgnored private var profileEngineUsage: [UUID: Set<EngineID>] = [:]
    @ObservationIgnored private var undoStates: [OrganizationState] = []
    private(set) var canUndoOrganization = false
    private struct OrganizationState {
        var spaces: [Space]
        var folders: [Folder]
        var savedItems: [SavedItem]
        var placements: [UUID: (UUID, UUID?)]
        var tabOrders: [UUID: [UUID]]
    }

    init(store: SessionStore, engines: EngineRegistry) {
        self.engines = engines
        self.store = store
        self.preferences = BrowserPreferences(directory: store.directory)
        self.downloads = DownloadStore(preferences: preferences)
        self.library = LibraryStore(directory: store.directory)
        self.siteSettings = SiteSettingsStore(directory: store.directory)
        let result = store.load()
        let snapshot = result.snapshot ?? SessionSnapshot()
        profiles = snapshot.profiles
        spaces = snapshot.spaces
        folders = snapshot.folders
        savedItems = snapshot.savedItems
        pendingProfileDeletions = Dictionary(uniqueKeysWithValues: (snapshot.pendingProfileDeletions ?? []).map {
            ($0.profileID, Set($0.requiredEngineIDs))
        })
        profileEngineUsage = Dictionary(uniqueKeysWithValues: (snapshot.profileEngineUsage ?? []).map {
            ($0.profileID, Set($0.engineIDs))
        })
        persistenceMessage = result.message
        library.mutationsAllowed = { [weak self] in self?.deletingProfiles.isEmpty ?? false }
        siteSettings.mutationsAllowed = { [weak self] in self?.deletingProfiles.isEmpty ?? false }
        engines.engineUseAllowed = { [weak self] profileID, engineID in
            self?.recordEngineUse(profileID: profileID, engineID: engineID) == true
        }
        for engine in engines.engines {
            engine.contentBlocker?.profileMutationAllowed = { [weak self] id in
                self?.recordEngineUse(profileID: id, engineID: engine.id) == true
            }
            engine.extensionManager?.profileMutationAllowed = { [weak self] id in
                self?.recordEngineUse(profileID: id, engineID: engine.id) == true
            }
            engine.contentBlocker?.onChange = { [weak self] in self?.windows.forEach { $0.applyContentRules() } }
        }
        windows = snapshot.windows.filter { pendingProfileDeletions[$0.profileID] == nil }
            .map { BrowserWindowModel(app: self, record: $0) }
        if !pendingProfileDeletions.isEmpty {
            Task { [weak self] in await self?.resumePendingProfileDeletions() }
        }
    }

    func cachedFavicon(urlString: String, profileID: UUID) -> CachedFavicon? {
        guard let url = URL(string: urlString), let origin = AddressResolver.canonicalOrigin(url) else { return nil }
        if let icon = savedItems.first(where: { $0.profileID == profileID && $0.favicon?.origin == origin })?.favicon { return icon }
        return windows.filter { !$0.isPrivate && $0.record.profileID == profileID }
            .lazy.compactMap { $0.record.tabs.first(where: { $0.favicon?.origin == origin })?.favicon }.first
    }

    func setWebInspectorEnabled(_ enabled: Bool) {
        guard preferences.setWebInspectorEnabled(enabled) else { return }
        windows.forEach { $0.applyInspectorPreference() }
    }

    var snapshot: SessionSnapshot {
        SessionSnapshot(profiles: profiles, spaces: spaces, folders: folders,
                        savedItems: savedItems, windows: windows.filter { !$0.isPrivate }.map(\.record),
                        pendingProfileDeletions: pendingProfileDeletions.map { id, engines in
                            PendingProfileDeletion(profileID: id,
                                requiredEngineIDs: engines.sorted { $0.rawValue < $1.rawValue })
                        }.sorted { $0.profileID.uuidString < $1.profileID.uuidString },
                        profileEngineUsage: profileEngineUsage.map { id, engines in
                            ProfileEngineUsage(profileID: id,
                                engineIDs: engines.sorted { $0.rawValue < $1.rawValue })
                        }.sorted { $0.profileID.uuidString < $1.profileID.uuidString })
    }

    func workspaceExportSnapshot() throws -> SessionSnapshot {
        guard deletingProfiles.isEmpty, pendingProfileDeletions.isEmpty else {
            throw EngineError.notReady(String(localized: "Wait for profile deletion to finish before exporting a workspace."))
        }
        return snapshot.withoutLocalFileBookmarks()
    }

    private func recordEngineUse(profileID: UUID, engineID: EngineID) -> Bool {
        guard !isDeletingProfile(profileID), !engineID.rawValue.isEmpty,
              profiles.contains(where: { $0.id == profileID }) else { return false }
        let previous = profileEngineUsage[profileID] ?? []
        guard !previous.contains(engineID) else { return true }
        profileEngineUsage[profileID] = previous.union([engineID])
        if let error = store.saveSynchronously(snapshot) {
            if previous.isEmpty { profileEngineUsage.removeValue(forKey: profileID) }
            else { profileEngineUsage[profileID] = previous }
            persistenceMessage = error
            return false
        }
        return true
    }

    func clearOrganizationUndoAfterSync() {
        undoStates.removeAll(); canUndoOrganization = false
    }

    func persist() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        store.save(snapshot) { [weak self] message in
            Task { @MainActor in self?.persistenceMessage = message }
        }
    }

    private func saveNowAndWait() async -> String? {
        pendingSave?.cancel()
        pendingSave = nil
        let message = await store.save(snapshot)
        persistenceMessage = message
        return message
    }

    func flushAndWait() async -> String? {
        sync.captureLocalChanges()
        return await saveNowAndWait()
    }

    func flush() {
        saveNow()
        store.flush()
    }

    @discardableResult
    func createProfile(name: String) -> Profile? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let profile = Profile(name: name, storeBinding: .named(UUID()))
        profiles.append(profile)
        spaces.append(Space(profileID: profile.id, isGeneratedDefault: true))
        persist()
        return profile
    }

    @discardableResult
    func renameProfile(id: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDeletingProfile(id), let index = profiles.firstIndex(where: { $0.id == id }), !name.isEmpty else { return false }
        profiles[index].name = name
        persist()
        return true
    }

    /// Opens a profile without changing other windows or moving their tabs.
    @discardableResult
    func selectProfile(_ id: UUID) -> BrowserWindowModel? {
        guard !isDeletingProfile(id), profiles.contains(where: { $0.id == id }) else { return nil }
        if let window = windows.first(where: { !$0.isPrivate && $0.record.profileID == id }) {
            onActivateWindow?(window)
            return window
        }
        return newWindow(profileID: id)
    }

    func isDeletingProfile(_ id: UUID) -> Bool {
        deletingProfiles.contains(id) || pendingProfileDeletions[id] != nil
    }

    /// Failed deletion reports any cleanup that already completed.
    func deleteProfile(_ id: UUID) async -> String? {
        guard !isDeletingProfile(id), let profile = profiles.first(where: { $0.id == id }) else {
            return String(localized: "This profile is already being deleted or is no longer available.")
        }
        guard id != Profile.defaultID, case .named = profile.storeBinding else {
            return String(localized: "The default profile keeps your existing website data and cannot be deleted.")
        }
        guard downloads.activeCount == 0 else {
            return String(localized: "Wait for all active downloads to finish or cancel them before deleting a profile.")
        }
        guard suspendedContexts.isEmpty else { return String(localized: "Wait for website-data removal to finish before deleting a profile.") }
        let requiredEngineIDs = profileEngineUsage[id] ?? []
        let requiredEngines = requiredEngineIDs.compactMap(engines.engine)
        guard requiredEngineIDs.allSatisfy({ !$0.rawValue.isEmpty }), requiredEngines.count == requiredEngineIDs.count else {
            return String(localized: "This profile uses an engine that is unavailable. Open this version of Cobble with every used engine before deleting it.")
        }
        if let engine = requiredEngines.first(where: { !$0.capabilities.supportsProfileDeletion }) {
            return String(format: String(localized: "%@ cannot delete its profile data yet. No profile data was removed."), engine.name)
        }
        for engine in requiredEngines {
            do { try await engine.preflightProfileDeletion(profile) }
            catch {
                return String(format: String(localized: "%@ cannot prepare to delete its profile data. No profile data was removed: %@"),
                              engine.name, error.localizedDescription)
            }
        }
        deletingProfiles.insert(id)
        defer { deletingProfiles.remove(id) }
        let affected = windows.filter { $0.record.profileID == id }
        for window in affected {
            guard await window.requestClosePages() else {
                affected.forEach { $0.cancelClosePages() }
                return String(localized: "A page in this profile cancelled the close request. The profile was not deleted.")
            }
        }
        guard affected.allSatisfy(\.hasCompletedClosePagesPreflight) else {
            affected.forEach { $0.cancelClosePages() }
            return String(localized: "The profile could not close all of its pages. The profile was not deleted.")
        }
        guard downloads.activeCount == 0, suspendedContexts.isEmpty,
              profiles.first(where: { $0.id == id }) == profile,
              windows.filter({ $0.record.profileID == id }).allSatisfy({ candidate in affected.contains { $0 === candidate } }) else {
            affected.forEach { $0.cancelClosePages() }
            return String(localized: "The profile changed while deletion was being prepared. No profile data was removed.")
        }
        let hadUsageRecord = profileEngineUsage[id] != nil
        if requiredEngineIDs.isEmpty { profileEngineUsage[id] = [] }
        pendingProfileDeletions[id] = requiredEngineIDs
        if let error = await saveNowAndWait() {
            pendingProfileDeletions.removeValue(forKey: id)
            if !hadUsageRecord { profileEngineUsage.removeValue(forKey: id) }
            affected.forEach { $0.cancelClosePages() }
            return String(format: String(localized: "Profile deletion could not start because its recovery marker was not saved: %@"), error)
        }
        let ids = affected.map(\.id)
        affected.forEach { $0.closePages() }
        windows.removeAll { $0.record.profileID == id }
        onCloseWindows?(ids)
        await engines.retireProfile(id)
        if let error = await finishProfileDeletion(profile, requiredEngineIDs: requiredEngineIDs,
                                                     allowUnusedProfile: requiredEngineIDs.isEmpty) { return error }
        return nil
    }

    private func resumePendingProfileDeletions() async {
        var resumeMessage: String?
        for (id, requiredEngineIDs) in Array(pendingProfileDeletions) {
            guard let profile = profiles.first(where: { $0.id == id }) else {
                pendingProfileDeletions.removeValue(forKey: id); continue
            }
            deletingProfiles.insert(id)
            await engines.retireProfile(id)
            let unusedWasRecorded = requiredEngineIDs.isEmpty && profileEngineUsage[id]?.isEmpty == true
            if let error = await finishProfileDeletion(profile, requiredEngineIDs: requiredEngineIDs,
                                                        allowUnusedProfile: unusedWasRecorded) {
                resumeMessage = error
            }
            deletingProfiles.remove(id)
        }
        _ = await saveNowAndWait()
        if let resumeMessage { persistenceMessage = resumeMessage }
    }

    private func finishProfileDeletion(_ profile: Profile, requiredEngineIDs: Set<EngineID>,
                                       allowUnusedProfile: Bool = false) async -> String? {
        let id = profile.id
        let requiredEngines = requiredEngineIDs.compactMap(engines.engine)
        guard (allowUnusedProfile || !requiredEngineIDs.isEmpty),
              requiredEngineIDs.allSatisfy({ !$0.rawValue.isEmpty }),
              requiredEngines.count == requiredEngineIDs.count,
              requiredEngines.allSatisfy({ $0.capabilities.supportsProfileDeletion }) else {
            return String(localized: "Profile deletion will resume when every engine used by this profile is available.")
        }
        do { for engine in requiredEngines { try await engine.removeProfile(profile) } }
        catch {
            return String(format: String(localized: "Profile deletion could not finish. Its windows are closed and some profile data may already be removed: %@"), error.localizedDescription)
        }
        guard library.removeProfile(id) else {
            return String(format: String(localized: "Profile deletion could not finish. Some profile data may already be removed: %@"), library.lastError ?? String(localized: "Unknown library error."))
        }
        guard siteSettings.removeProfile(id) else {
            return String(format: String(localized: "Profile deletion could not finish. Some profile data may already be removed: %@"), siteSettings.lastError ?? String(localized: "Unknown settings error."))
        }
        profiles.removeAll { $0.id == id }
        let removedSpaces = Set(spaces.filter { $0.profileID == id }.map(\.id))
        spaces.removeAll { $0.profileID == id }
        folders.removeAll { removedSpaces.contains($0.spaceID) }
        savedItems.removeAll { $0.profileID == id }
        undoStates.removeAll()
        canUndoOrganization = false
        pendingProfileDeletions.removeValue(forKey: id)
        profileEngineUsage.removeValue(forKey: id)
        if let error = await saveNowAndWait() {
            return String(format: String(localized: "Profile deletion could not finish. Some profile data may already be removed: %@"), error)
        }
        return nil
    }

    @discardableResult
    func newWindow(isPrivate: Bool = false, url: URL? = nil) -> BrowserWindowModel {
        newWindow(isPrivate: isPrivate, url: url, profileID: profiles[0].id)!
    }

    @discardableResult
    func newWindow(isPrivate: Bool = false, url: URL? = nil, profileID: UUID) -> BrowserWindowModel? {
        guard !isDeletingProfile(profileID), let profile = profiles.first(where: { $0.id == profileID }) else { return nil }
        let space = spaces.first { $0.profileID == profile.id }!
        let tab = url.map { Tab(spaceID: space.id, urlString: $0.absoluteString, title: $0.host ?? "Loading…", engineID: preferences.engine(for: $0)) }
        let record = WindowRecord(profileID: profile.id, selectedSpaceID: space.id,
                                  selectedTabID: tab?.id, tabs: tab.map { [$0] } ?? [])
        let window = BrowserWindowModel(app: self, record: record, isPrivate: isPrivate)
        windows.append(window)
        onOpenWindow?(window)
        if !isPrivate { persist() }
        return window
    }

    /// AppKit presents the returned model in its own native window. The tab's
    /// retained page is moved, never recreated or navigated.
    @discardableResult
    func detachSelectedTab(from source: BrowserWindowModel) -> BrowserWindowModel? {
        guard windows.contains(where: { $0 === source }), !source.isPrivate,
              !source.isClosed, !isDeletingProfile(source.record.profileID),
              profiles.contains(where: { $0.id == source.record.profileID }) else { return nil }
        let destinationID = UUID()
        let record = WindowRecord(id: destinationID, profileID: source.record.profileID,
                                  selectedSpaceID: source.record.selectedSpaceID,
                                  selectedTabID: nil, tabs: [])
        let destination = BrowserWindowModel(app: self, record: record)
        // Chromium must resolve the destination NSWindow while moving its
        // native page, before SwiftUI reparents the retained page view.
        windows.append(destination)
        onOpenWindow?(destination)
        do {
            let moved = try source.takeSelectedTabForDetach(to: destinationID)
            destination.adoptDetachedTab(moved.tab, host: moved.host, historyVisit: moved.historyVisit)
            destination.focusSelectedPageAfterAttach()
            persist()
            return destination
        } catch {
            destination.closePages()
            windows.removeAll { $0 === destination }
            onCloseWindows?([destinationID])
            source.addressError = error.localizedDescription
            return nil
        }
    }

    func replaceWorkspace(with snapshot: SessionSnapshot) throws {
        guard deletingProfiles.isEmpty, pendingProfileDeletions.isEmpty else {
            throw EngineError.notReady(String(localized: "Wait for profile deletion before restoring a workspace."))
        }
        guard suspendedContexts.isEmpty else { throw EngineError.notReady(String(localized: "Wait for website data removal before restoring a workspace.")) }
        guard snapshot.pendingProfileDeletions?.isEmpty != false else {
            throw EngineError.notReady(String(localized: "This workspace contains an unfinished profile deletion. Restore a completed backup instead."))
        }
        let restored = try SessionSnapshot.decode(JSONEncoder().encode(snapshot.withoutLocalFileBookmarks()))
        pendingSave?.cancel()
        pendingSave = nil
        try store.replace(with: restored, preserving: self.snapshot)
        windows.forEach { $0.closePages() }
        engines.reconcileProfiles(restored.profiles)
        profiles = restored.profiles
        spaces = restored.spaces
        folders = restored.folders
        savedItems = restored.savedItems
        windows = restored.windows.map { BrowserWindowModel(app: self, record: $0) }
        pendingProfileDeletions = Dictionary(uniqueKeysWithValues: (restored.pendingProfileDeletions ?? []).map {
            ($0.profileID, Set($0.requiredEngineIDs))
        })
        profileEngineUsage = Dictionary(uniqueKeysWithValues: (restored.profileEngineUsage ?? []).map {
            ($0.profileID, Set($0.engineIDs))
        })
        undoStates.removeAll()
        canUndoOrganization = false
        onReplaceWindows?()
        if !pendingProfileDeletions.isEmpty {
            Task { [weak self] in await self?.resumePendingProfileDeletions() }
        }
    }

    func closeWindow(_ id: UUID) {
        guard let window = windows.first(where: { $0.id == id }) else { return }
        window.closePages()
        windows.removeAll { $0.id == id }
        if !window.isPrivate { persist() }
    }

    func requestTerminationPreflight() async -> Bool {
        for window in windows {
            guard await window.requestClosePages() else {
                windows.forEach { $0.cancelClosePages() }
                return false
            }
        }
        guard windows.allSatisfy({ $0.hasCompletedClosePagesPreflight }) else {
            windows.forEach { $0.cancelClosePages() }
            return false
        }
        return true
    }

    func rememberOrganization() {
        let placements = windows.flatMap { $0.record.tabs }.reduce(into: [UUID: (UUID, UUID?)]()) {
            $0[$1.id] = ($1.spaceID, $1.savedItemID)
        }
        let tabOrders = Dictionary(uniqueKeysWithValues: windows.filter { !$0.isPrivate }.map {
            ($0.id, $0.record.tabs.map(\.id))
        })
        undoStates.append(OrganizationState(spaces: spaces, folders: folders, savedItems: savedItems,
                                           placements: placements, tabOrders: tabOrders))
        if undoStates.count > 30 { undoStates.removeFirst() }
        canUndoOrganization = true
    }

    func undoOrganization() {
        guard deletingProfiles.isEmpty, let state = undoStates.popLast() else { return }
        spaces = state.spaces
        folders = state.folders
        savedItems = state.savedItems
        for window in windows {
            let fallback = spaces.first { $0.profileID == window.record.profileID }?.id ?? spaces.first?.id ?? Space.defaultID
            for i in window.record.tabs.indices {
                if let placement = state.placements[window.record.tabs[i].id] {
                    window.record.tabs[i].spaceID = placement.0
                    window.record.tabs[i].savedItemID = placement.1
                } else {
                    if !spaces.contains(where: { $0.id == window.record.tabs[i].spaceID }) { window.record.tabs[i].spaceID = fallback }
                    if !savedItems.contains(where: { $0.id == window.record.tabs[i].savedItemID }) { window.record.tabs[i].savedItemID = nil }
                }
            }
            if let order = state.tabOrders[window.id] {
                let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
                window.record.tabs = window.record.tabs.enumerated().sorted {
                    (rank[$0.element.id] ?? (order.count + $0.offset)) < (rank[$1.element.id] ?? (order.count + $1.offset))
                }.map(\.element)
            }
            window.repairSelection()
        }
        canUndoOrganization = !undoStates.isEmpty
        persist()
    }

    func addSpace(name: String, profileID: UUID, icon: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDeletingProfile(profileID), !name.isEmpty, profiles.contains(where: { $0.id == profileID }) else { return }
        rememberOrganization()
        spaces.append(Space(profileID: profileID, name: name, icon: Space.validatedIcon(icon)))
        persist()
    }

    func renameSpace(id: UUID, name: String) {
        guard let i = spaces.firstIndex(where: { $0.id == id }), !isDeletingProfile(spaces[i].profileID), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rememberOrganization()
        spaces[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        spaces[i].isGeneratedDefault = false
        persist()
    }

    func setSpaceIcon(id: UUID, icon: String?) {
        guard let i = spaces.firstIndex(where: { $0.id == id }), !isDeletingProfile(spaces[i].profileID) else { return }
        let next = Space.validatedIcon(icon)
        guard spaces[i].icon != next else { return }
        rememberOrganization()
        spaces[i].icon = next
        persist()
    }

    func updateSpace(id: UUID, name: String, icon: String?) {
        guard let i = spaces.firstIndex(where: { $0.id == id }), !isDeletingProfile(spaces[i].profileID) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let nextIcon = Space.validatedIcon(icon)
        let nameChanged = spaces[i].name != name
        let iconChanged = spaces[i].icon != nextIcon
        guard nameChanged || iconChanged else { return }
        rememberOrganization()
        spaces[i].name = name
        spaces[i].icon = nextIcon
        if nameChanged { spaces[i].isGeneratedDefault = false }
        persist()
    }

    func deleteSpace(_ id: UUID) {
        guard let space = spaces.first(where: { $0.id == id }), !isDeletingProfile(space.profileID), let fallback = spaces.first(where: { $0.profileID == space.profileID && $0.id != id }) else { return }
        rememberOrganization()
        for i in savedItems.indices where savedItems[i].spaceID == id { savedItems[i].spaceID = fallback.id }
        for i in folders.indices where folders[i].spaceID == id { folders[i].spaceID = fallback.id }
        for window in windows where window.record.profileID == space.profileID {
            for i in window.record.tabs.indices where window.record.tabs[i].spaceID == id { window.record.tabs[i].spaceID = fallback.id }
            if window.record.selectedSpaceID == id { window.selectSpace(fallback.id) }
        }
        spaces.removeAll { $0.id == id }
        persist()
    }

    func moveSpace(id: UUID, offset: Int) {
        guard let item = spaces.first(where: { $0.id == id }), !isDeletingProfile(item.profileID) else { return }
        let siblings = spaces.filter { $0.profileID == item.profileID }
        guard let position = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(position + offset) else { return }
        let dest = position + offset
        moveSpace(id: id, before: offset > 0
            ? (dest + 1 < siblings.count ? siblings[dest + 1].id : nil)
            : siblings[dest].id)
    }

    func moveSpace(id: UUID, before: UUID?) {
        guard let i = spaces.firstIndex(where: { $0.id == id }), !isDeletingProfile(spaces[i].profileID) else { return }
        let profileID = spaces[i].profileID
        if before == id { return }
        let resolvedBefore = before.flatMap { candidate in
            spaces.contains(where: { $0.id == candidate && $0.profileID == profileID && $0.id != id }) ? candidate : nil
        }
        if before != nil && resolvedBefore == nil { return }
        let oldNext = spaces.dropFirst(i + 1).first { $0.profileID == profileID }?.id
        if oldNext == resolvedBefore { return }
        rememberOrganization()
        let item = spaces.remove(at: i)
        if let resolvedBefore, let index = spaces.firstIndex(where: { $0.id == resolvedBefore }) {
            spaces.insert(item, at: index)
        } else if let last = spaces.lastIndex(where: { $0.profileID == profileID }) {
            spaces.insert(item, at: last + 1)
        } else {
            spaces.append(item)
        }
        persist()
    }

    func addFolder(name: String, spaceID: UUID, parentID: UUID? = nil, color: FolderColor = .theme) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = spaces.first(where: { $0.id == spaceID }), !isDeletingProfile(space.profileID), !name.isEmpty,
              parentID == nil || folders.contains(where: { $0.id == parentID && $0.spaceID == spaceID }) else { return }
        rememberOrganization()
        folders.append(Folder(spaceID: spaceID, parentID: parentID, name: name, color: color))
        persist()
    }

    func setFolderColor(id: UUID, color: FolderColor) {
        guard let i = folders.firstIndex(where: { $0.id == id }),
              let space = spaces.first(where: { $0.id == folders[i].spaceID }),
              !isDeletingProfile(space.profileID) else { return }
        guard folders[i].color != color else { return }
        rememberOrganization()
        folders[i].color = color
        persist()
    }

    func updateFolder(id: UUID, name: String, color: FolderColor) {
        guard let i = folders.firstIndex(where: { $0.id == id }),
              let space = spaces.first(where: { $0.id == folders[i].spaceID }),
              !isDeletingProfile(space.profileID) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard folders[i].name != name || folders[i].color != color else { return }
        rememberOrganization()
        folders[i].name = name
        folders[i].color = color
        persist()
    }

    func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }), let space = spaces.first(where: { $0.id == folder.spaceID }), !isDeletingProfile(space.profileID) else { return }
        rememberOrganization()
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = folder.parentID }
        for i in savedItems.indices where savedItems[i].folderID == id { savedItems[i].folderID = folder.parentID }
        for window in windows { window.record.collapsedFolderIDs.removeAll { $0 == id } }
        folders.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    func moveFolder(id: UUID, spaceID: UUID? = nil, parentID: UUID? = nil, before: UUID? = nil) -> Bool {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return false }
        let old = folders[i]
        let destination = spaceID ?? parentID.flatMap { parent in folders.first(where: { $0.id == parent })?.spaceID } ?? old.spaceID
        let profileID = spaces.first { $0.id == folders[i].spaceID }?.profileID
        let destinationParent = parentID ?? (spaceID == nil ? old.parentID : nil)
        guard let profileID, !isDeletingProfile(profileID), spaces.contains(where: { $0.id == destination && $0.profileID == profileID }),
              destinationParent == nil || folders.contains(where: { $0.id == destinationParent && $0.spaceID == destination }),
              destinationParent != id, !isDescendant(destinationParent, of: id) else { return false }
        let resolvedBefore = before.flatMap { candidate in
            folders.contains(where: { $0.id == candidate && $0.spaceID == destination && $0.parentID == destinationParent && $0.id != id }) ? candidate : nil
        }
        let oldNext = folders.dropFirst(i + 1).first { $0.spaceID == old.spaceID && $0.parentID == old.parentID }?.id
        if old.spaceID == destination, old.parentID == destinationParent, oldNext == resolvedBefore { return false }
        rememberOrganization()
        var folder = folders.remove(at: i)
        folder.spaceID = destination
        folder.parentID = destinationParent
        let subtree = descendants(of: id)
        for j in folders.indices where subtree.contains(folders[j].id) { folders[j].spaceID = destination }
        for j in savedItems.indices where savedItems[j].folderID.map({ subtree.contains($0) }) == true { savedItems[j].spaceID = destination }
        if destination != old.spaceID {
            for window in windows {
                for index in window.record.tabs.indices {
                    if let savedID = window.record.tabs[index].savedItemID,
                       savedItems.contains(where: { $0.id == savedID && $0.folderID.map({ subtree.contains($0) }) == true }) {
                        window.record.tabs[index].spaceID = destination
                    }
                }
                if let savedID = window.selectedTab?.savedItemID,
                   savedItems.contains(where: { $0.id == savedID && $0.folderID.map({ subtree.contains($0) }) == true }) {
                    window.record.selectedSpaceID = destination
                }
            }
        }
        if let resolvedBefore, let index = folders.firstIndex(where: { $0.id == resolvedBefore }) {
            folders.insert(folder, at: index)
        } else if let last = folders.lastIndex(where: { $0.spaceID == destination && $0.parentID == destinationParent }) {
            folders.insert(folder, at: last + 1)
        } else {
            folders.append(folder)
        }
        persist()
        return true
    }

    func canMoveFolder(id: UUID, to parentID: UUID?) -> Bool {
        guard let folder = folders.first(where: { $0.id == id }),
              let space = spaces.first(where: { $0.id == folder.spaceID }), !isDeletingProfile(space.profileID) else { return false }
        guard let parentID else { return true }
        return parentID != id && folders.contains(where: { $0.id == parentID && $0.spaceID == folder.spaceID })
            && !isDescendant(parentID, of: id)
    }

    private func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        while true {
            let additions = folders.compactMap { folder -> UUID? in
                guard let parentID = folder.parentID, result.contains(parentID) else { return nil }
                return folder.id
            }
            let count = result.count
            result.formUnion(additions)
            if result.count == count { return result }
        }
    }

    private func isDescendant(_ id: UUID?, of ancestor: UUID) -> Bool {
        guard var id else { return false }
        var visited = Set<UUID>()
        while visited.insert(id).inserted {
            if id == ancestor { return true }
            guard let parent = folders.first(where: { $0.id == id })?.parentID else { return false }
            id = parent
        }
        return true
    }

    func saveTab(_ tab: Tab, profileID: UUID, favorite: Bool, folderID: UUID? = nil, before: UUID? = nil) -> UUID? {
        guard !isDeletingProfile(profileID), tab.url != nil,
              spaces.contains(where: { $0.id == tab.spaceID && $0.profileID == profileID }),
              favorite || folderID == nil || folders.contains(where: { $0.id == folderID && $0.spaceID == tab.spaceID }) else { return nil }
        if let id = tab.savedItemID { return id }
        rememberOrganization()
        var item = SavedItem(profileID: profileID, spaceID: favorite ? nil : tab.spaceID, urlString: tab.urlString, title: tab.title, favicon: tab.favicon ?? cachedFavicon(urlString: tab.urlString, profileID: profileID))
        if !favorite { item.folderID = folderID }
        insertSaved(item, before: before)
        persist()
        return item.id
    }

    func renameSavedItem(id: UUID, title: String) {
        guard let i = savedItems.firstIndex(where: { $0.id == id }), !isDeletingProfile(savedItems[i].profileID), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rememberOrganization()
        savedItems[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func updateSavedDestination(id: UUID, profileID: UUID, url: URL, favicon: CachedFavicon?) {
        guard !isDeletingProfile(profileID), let i = savedItems.firstIndex(where: { $0.id == id && $0.profileID == profileID }),
              AddressResolver.canonicalOrigin(url) != nil,
              case .navigate(let validated) = AddressResolver.resolve(url.absoluteString),
              savedItems[i].urlString != validated.absoluteString else { return }
        let icon = favicon?.validated(for: validated.absoluteString)
            ?? cachedFavicon(urlString: validated.absoluteString, profileID: profileID)?.validated(for: validated.absoluteString)
        rememberOrganization()
        savedItems[i].urlString = validated.absoluteString
        savedItems[i].favicon = icon
        persist()
    }

    func removeSavedItem(_ id: UUID) {
        guard let item = savedItems.first(where: { $0.id == id }), !isDeletingProfile(item.profileID) else { return }
        rememberOrganization()
        for window in windows {
            for i in window.record.tabs.indices where window.record.tabs[i].savedItemID == id {
                window.record.tabs[i].savedItemID = nil
                if window.record.tabs[i].id == window.record.selectedTabID { window.record.tabs[i].spaceID = window.record.selectedSpaceID }
            }
        }
        savedItems.removeAll { $0.id == id }
        persist()
    }

    func moveSavedItem(id: UUID, spaceID: UUID?, folderID: UUID?, before: UUID? = nil) {
        guard let i = savedItems.firstIndex(where: { $0.id == id }), !isDeletingProfile(savedItems[i].profileID) else { return }
        if let spaceID, !spaces.contains(where: { $0.id == spaceID && $0.profileID == savedItems[i].profileID }) { return }
        if let folderID, !folders.contains(where: { $0.id == folderID && $0.spaceID == spaceID }) { return }
        let old = savedItems[i]
        let oldNext = savedItems.dropFirst(i + 1).first {
            $0.profileID == old.profileID && $0.spaceID == old.spaceID && $0.folderID == old.folderID
        }?.id
        if old.spaceID == spaceID, old.folderID == folderID, oldNext == before { return }
        rememberOrganization()
        var item = savedItems.remove(at: i)
        item.spaceID = spaceID
        item.folderID = folderID
        insertSaved(item, before: before)
        if let spaceID {
            for window in windows {
                for index in window.record.tabs.indices where window.record.tabs[index].savedItemID == id { window.record.tabs[index].spaceID = spaceID }
                if window.selectedTab?.savedItemID == id { window.record.selectedSpaceID = spaceID }
            }
        }
        persist()
    }

    private func insertSaved(_ item: SavedItem, before: UUID?) {
        if let before, let index = savedItems.firstIndex(where: {
            $0.id == before && $0.profileID == item.profileID && $0.spaceID == item.spaceID && $0.folderID == item.folderID
        }) {
            savedItems.insert(item, at: index)
        } else if let last = savedItems.lastIndex(where: {
            $0.profileID == item.profileID && $0.spaceID == item.spaceID && $0.folderID == item.folderID
        }) {
            savedItems.insert(item, at: last + 1)
        } else {
            savedItems.append(item)
        }
    }

    func moveSavedItem(id: UUID, offset: Int) {
        guard let item = savedItems.first(where: { $0.id == id }), !isDeletingProfile(item.profileID) else { return }
        let siblings = savedItems.indices.filter { savedItems[$0].profileID == item.profileID && savedItems[$0].spaceID == item.spaceID && savedItems[$0].folderID == item.folderID }
        guard let position = siblings.firstIndex(where: { savedItems[$0].id == id }), siblings.indices.contains(position + offset) else { return }
        rememberOrganization()
        let moved = savedItems.remove(at: siblings[position])
        savedItems.insert(moved, at: siblings[position + offset])
        persist()
    }

    func redactedDiagnostics() -> RedactedDiagnostics {
        let bundle = Bundle.main
        let env = ProcessInfo.processInfo.environment
        return RedactedDiagnostics(
            appName: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? "Cobble",
            marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deploymentTarget: bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
            cobbleTesting: env["COBBLE_TESTING"] != nil,
            cobbleDataDirectorySet: env["COBBLE_DATA_DIRECTORY"] != nil,
            dataDirectory: store.directory.path,
            lastPersistenceError: persistenceMessage,
            registeredEngineNames: engines.engines.map(\.name),
            defaultEngineID: preferences.defaultEngine.rawValue
        )
    }

    func redactedDiagnosticsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(redactedDiagnostics())
    }
}

struct RedactedDiagnostics: Codable, Equatable, Sendable {
    var appName: String
    var marketingVersion: String
    var buildVersion: String
    var bundleIdentifier: String
    var macOSVersion: String
    var deploymentTarget: String?
    var cobbleTesting: Bool
    var cobbleDataDirectorySet: Bool
    var dataDirectory: String
    var lastPersistenceError: String?
    var registeredEngineNames: [String]
    var defaultEngineID: String
}
