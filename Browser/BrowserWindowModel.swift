import AppKit
import Observation

@MainActor @Observable
final class BrowserWindowModel: Identifiable {
    nonisolated let id: UUID
    unowned let app: AppModel
    var record: WindowRecord { didSet { if !isPrivate { app.persist() } } }
    let isPrivate: Bool
    var addressDraft = ""
    var isEditingAddress = false
    var addressFocusRequest = UUID()
    var commandBarPresented = false
    var commandQuery = ""
    var addressError: String?
    var findPresented = false
    var findText = ""
    var findFocusRequest = UUID()
    private var recentTabIDs: [UUID] = []
    private var recentCycleIDs: [UUID] = []
    private var selectingRecentTab = false
    /// Sidebar-only selection of ordinary tabs in this window and space.
    private(set) var selectedTemporaryTabIDs: Set<UUID> = []
    private var temporaryTabSelectionAnchorID: UUID?
    enum OrganizationEditor { case newSpace, newFolder, rename, editSpace }
    var organizationEditor: OrganizationEditor?
    #if DEBUG
    var resourcePages: [any BrowserPage] {
        var seen = Set<ObjectIdentifier>()
        return (Array(pages.values) + Array(pendingPages.values)).filter {
            $0.state.lifecycle != .closed && seen.insert(ObjectIdentifier($0)).inserted
        }
    }
    #endif
    private var pages: [UUID: any BrowserPage] = [:]
    private var historyVisits: [UUID: (url: String, date: Date)] = [:]
    @ObservationIgnored private var pendingPages: [UUID: any BrowserPage] = [:]
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private(set) var closedTabs: [Tab] = []
    @ObservationIgnored private var loads: [UUID: UUID] = [:]
    @ObservationIgnored private var switches: [UUID: UUID] = [:]
    @ObservationIgnored private var closeRequests: [UUID: UUID] = [:]
    @ObservationIgnored private var promptPresenters: [UUID: (tabID: UUID, presenter: PagePresenter)] = [:]
    @ObservationIgnored private var selectedCloseOperation: UUID?
    /// A termination preflight has accepted native page closes. Keep the
    /// persisted tab records until the app has flushed and retires this model.
    @ObservationIgnored private var preservingTabsForTermination = false
    @ObservationIgnored private var closePagesPreflightComplete = false
    @ObservationIgnored var confirmEngineSwitch: ((String) -> Bool)?
    @ObservationIgnored var confirmLoginReplacement: (() -> Bool)?
    @ObservationIgnored var onKeyEvent: ((NSEvent) -> Bool)?
    @ObservationIgnored var onOpenDevTools: ((any BrowserPage) -> Bool)?
    @ObservationIgnored lazy var pageFileOperations = PageFileOperations(owner: self)
    @ObservationIgnored private(set) var privateLocalFileBookmarks: [UUID: Data] = [:]
    @ObservationIgnored private var sharingPicker: NSSharingServicePicker?
    @ObservationIgnored var onCommand: ((BrowserCommand) -> Bool)?
    @ObservationIgnored weak var nativeWindow: NSWindow?
    init(app: AppModel, record: WindowRecord, isPrivate: Bool = false) {
        self.id = record.id
        self.app = app
        self.record = record
        self.isPrivate = isPrivate
        recentTabIDs = record.selectedTabID.map { [$0] } ?? []
        if let selected = record.selectedTabID,
           record.tabs.first(where: { $0.id == selected })?.savedItemID == nil {
            selectedTemporaryTabIDs = [selected]
            temporaryTabSelectionAnchorID = selected
        }
        addressDraft = record.tabs.first { $0.id == record.selectedTabID }?.urlString ?? ""
    }

    func focusAddress() {
        isEditingAddress = true
        addressFocusRequest = UUID()
    }

    var addressSuggestions: [LibraryEntry] {
        guard isEditingAddress, !isPrivate else { return [] }
        return Array(app.library.search(addressDraft, profileID: record.profileID).prefix(6))
    }

    var bangSuggestions: [SearchEngine] {
        guard isEditingAddress, !isPrivate else { return [] }
        return app.preferences.bangSuggestions(for: addressDraft)
    }

    func submitAddressSuggestion(_ id: Int64) {
        guard !isPrivate,
              let entry = app.library.search(addressDraft, profileID: record.profileID).prefix(6).first(where: { $0.id == id }) else { return }
        addressDraft = entry.urlString
        submitAddress()
    }

    func submitBangSuggestion(_ id: String) {
        guard !isPrivate, let engine = bangSuggestions.first(where: { $0.id == id }) else { return }
        addressDraft = "!\(engine.bang) "
    }

    func cancelAddressEditing() {
        addressDraft = selectedTab?.urlString ?? ""
        addressError = nil
        isEditingAddress = false
    }

    var selectedTab: Tab? { record.tabs.first { $0.id == record.selectedTabID } }
    func icon(for tabID: UUID) -> NSImage? {
        guard let tab = record.tabs.first(where: { $0.id == tabID }),
              let url = URL(string: tab.urlString), let origin = AddressResolver.canonicalOrigin(url) else { return nil }
        if pages[tabID]?.state.isCrashed == true { return nil }
        if let state = pages[tabID]?.state, state.faviconOrigin == origin, let icon = state.favicon { return icon }
        let icon = tab.favicon?.origin == origin ? tab.favicon : app.cachedFavicon(urlString: tab.urlString, profileID: record.profileID)
        return icon.flatMap { NSImage(data: $0.png) }
    }

    func icon(for item: SavedItem) -> NSImage? {
        let cached = item.favicon ?? app.cachedFavicon(urlString: item.urlString, profileID: record.profileID)
        guard let url = URL(string: item.urlString), cached?.origin == AddressResolver.canonicalOrigin(url) else { return nil }
        return cached.flatMap { NSImage(data: $0.png) }
    }

    func isSavedItemLoaded(_ id: UUID) -> Bool {
        record.tabs.contains { $0.savedItemID == id && pages[$0.id] != nil }
    }

    func unloadSavedItem(_ id: UUID) {
        guard let index = record.tabs.firstIndex(where: { $0.savedItemID == id }),
              let saved = app.savedItems.first(where: { $0.id == id }) else { return }
        let tabID = record.tabs[index].id
        retireHost(tabID, leavingUnloaded: true)
        record.tabs[index].urlString = saved.urlString
        record.tabs[index].title = saved.title
        if record.selectedTabID == tabID { clearSelection() }
    }

    func removeUnloadedSavedItem(_ id: UUID) {
        guard !isSavedItemLoaded(id) else { return }
        let tabID = record.tabs.first(where: { $0.savedItemID == id })?.id
        app.removeSavedItem(id)
        if let tabID { closeTab(tabID) }
    }

    func isLoading(_ tabID: UUID) -> Bool { pages[tabID]?.isLoading == true }
    func captureState(for tabID: UUID) -> (camera: PageCapture, microphone: PageCapture, display: Bool) {
        guard let state = pages[tabID]?.state, state.lifecycle == .ready, !state.isCrashed else { return (.none, .none, false) }
        return (state.camera, state.microphone, state.isDisplayCapturing)
    }
    func isPlayingAudio(_ tabID: UUID) -> Bool { pages[tabID]?.state.isPlayingAudio == true }
    func isAudioMuted(_ tabID: UUID) -> Bool { pages[tabID]?.state.isAudioMuted == true }
    func canMute(_ tabID: UUID) -> Bool {
        pages[tabID]?.capabilities.pageOperations.contains(.muteAudio) == true
    }
    func isCapturing(_ tabID: UUID) -> Bool {
        guard let state = pages[tabID]?.state, state.lifecycle == .ready, !state.isCrashed else { return false }
        return state.camera != .none || state.microphone != .none || state.isDisplayCapturing
    }
    func showsMuteControl(_ tabID: UUID) -> Bool {
        canMute(tabID) && !isCapturing(tabID) && pages[tabID]?.state.audioMuteBlocked != true
            && (isPlayingAudio(tabID) || isAudioMuted(tabID))
    }
    func toggleMute(_ tabID: UUID) {
        guard let host = pages[tabID], host.capabilities.pageOperations.contains(.muteAudio),
              host.state.audioMuteBlocked != true, !isCapturing(tabID) else { return }
        try? host.setAudioMuted(!host.state.isAudioMuted)
    }
    var selectedPage: (any BrowserPage)? { record.selectedTabID.flatMap { pages[$0] } }
    /// Scripting cannot safely change selection while native UI owns a page action.
    var scriptingMutationAllowed: Bool {
        canChangeTemporaryTabs && !isPrivate && !preservingTabsForTermination
            && selectedCloseOperation == nil && closeRequests.isEmpty
            && nativeWindow?.attachedSheet == nil && selectedPage?.hasPendingPrompt != true
            && !pageFileOperations.hasPendingOperations
    }
    var canDetachSelectedTab: Bool {
        guard !isPrivate, !isClosed, !preservingTabsForTermination, selectedCloseOperation == nil,
              !isEditingAddress, !findPresented,
              !app.isDeletingProfile(record.profileID),
              app.profiles.contains(where: { $0.id == record.profileID }),
              let tab = selectedTab, let host = pages[tab.id],
              host.state.lifecycle == .ready, !host.state.isLoading,
              host.capabilities.pageOperations.contains(.detach),
              !host.hasPendingPrompt,
              pendingPages[tab.id] == nil, loads[tab.id] == nil, switches[tab.id] == nil,
              closeRequests[tab.id] == nil,
              nativeWindow?.attachedSheet == nil,
              !pageFileOperations.hasPendingOperations else { return false }
        return !app.suspendedContexts.contains(host.contextID)
    }
    var requiresCloseConfirmation: Bool {
        !isClosed && pages.values.contains { $0.capabilities.requiresCloseConfirmation }
    }
    var selectedSpace: Space? { app.spaces.first { $0.id == record.selectedSpaceID } }
    var spaces: [Space] { app.spaces.filter { $0.profileID == record.profileID } }
    var favorites: [SavedItem] { app.savedItems.filter { $0.profileID == record.profileID && $0.spaceID == nil } }
    var pins: [SavedItem] { pins(in: record.selectedSpaceID) }
    func pins(in spaceID: UUID) -> [SavedItem] { app.savedItems.filter { $0.spaceID == spaceID } }
    var folders: [Folder] { folders(in: record.selectedSpaceID) }
    func folders(in spaceID: UUID, parentID: UUID? = nil) -> [Folder] {
        app.folders.filter { $0.spaceID == spaceID && $0.parentID == parentID }
    }
    var visibleTabs: [Tab] { record.tabs.filter { $0.spaceID == record.selectedSpaceID && $0.savedItemID == nil } }
    var sidebarPeeked = false
    var sidebarVisible: Bool {
        get { record.sidebarVisible }
        set {
            record.sidebarVisible = newValue
            sidebarPeeked = false
        }
    }
    func revealSidebarChrome() {
        if !sidebarVisible { sidebarPeeked = true }
    }
    func select(_ id: UUID) {
        guard let tab = record.tabs.first(where: { $0.id == id }) else { return }
        selectedTemporaryTabIDs = tab.savedItemID == nil ? [id] : []
        temporaryTabSelectionAnchorID = selectedTemporaryTabIDs.isEmpty ? nil : id
        activate(id)
    }

    private func activate(_ id: UUID) {
        guard let tab = record.tabs.first(where: { $0.id == id }) else { return }
        if !selectingRecentTab { endRecentTabCycle(); rememberRecentTab(id) }
        if let index = record.tabs.firstIndex(where: { $0.id == id }) { record.tabs[index].isUnloaded = nil }
        record.selectedTabID = id
        if tab.savedItemID.flatMap({ itemID in app.savedItems.first { $0.id == itemID } })?.spaceID != nil || tab.savedItemID == nil { record.selectedSpaceID = tab.spaceID }
        addressDraft = tab.urlString
        addressError = nil
        isEditingAddress = false
        activateSelected()
    }

    var selectedTemporaryTabs: [Tab] { visibleTabs.filter { selectedTemporaryTabIDs.contains($0.id) } }
    func isTemporaryTabSelected(_ id: UUID) -> Bool { selectedTemporaryTabIDs.contains(id) }
    private var canChangeTemporaryTabs: Bool {
        !isClosed && !app.isDeletingProfile(record.profileID)
            && app.profiles.contains(where: { $0.id == record.profileID })
    }

    func selectTemporaryTab(_ id: UUID, modifiers: NSEvent.ModifierFlags = []) {
        guard canChangeTemporaryTabs, selectedCloseOperation == nil else { return }
        let tabs = visibleTabs
        guard tabs.contains(where: { $0.id == id }) else { return }
        let flags = modifiers.intersection([.command, .shift])
        if flags.contains(.shift), let anchor = temporaryTabSelectionAnchorID,
           let a = tabs.firstIndex(where: { $0.id == anchor }), let b = tabs.firstIndex(where: { $0.id == id }) {
            selectedTemporaryTabIDs = Set(tabs[min(a, b)...max(a, b)].map(\.id))
        } else if flags.contains(.command) {
            if selectedTemporaryTabIDs.contains(id), selectedTemporaryTabIDs.count > 1 {
                selectedTemporaryTabIDs.remove(id)
                if record.selectedTabID == id, let next = selectedTemporaryTabs.last { activate(next.id) }
                if temporaryTabSelectionAnchorID == id {
                    temporaryTabSelectionAnchorID = record.selectedTabID.flatMap { selectedTemporaryTabIDs.contains($0) ? $0 : nil }
                        ?? selectedTemporaryTabs.last?.id
                }
            } else {
                selectedTemporaryTabIDs.insert(id)
                temporaryTabSelectionAnchorID = id
                activate(id)
            }
            return
        } else {
            selectedTemporaryTabIDs = [id]
            temporaryTabSelectionAnchorID = id
        }
        activate(id)
    }

    func clearTemporaryTabSelection() {
        selectedTemporaryTabIDs.removeAll()
        temporaryTabSelectionAnchorID = nil
    }

    private func contextID(for engineID: EngineID) -> BrowsingContextID {
        BrowsingContextID(engineID: app.engines.effectiveID(engineID), profileID: record.profileID, privateWindowID: isPrivate ? id : nil)
    }

    func activateSelected() {
        guard !isClosed, let tab = selectedTab, tab.isUnloaded != true, pages[tab.id] == nil,
              !app.suspendedContexts.contains(contextID(for: tab.engineID)), !app.isDeletingProfile(record.profileID) else { return }
        let blocker = app.engines.engine(app.engines.effectiveID(tab.engineID))?.contentBlocker
        if let blocker, !blocker.isReady {
            Task { [weak self] in
                await blocker.waitUntilReady()
                guard let self, self.record.selectedTabID == tab.id else { return }
                self.activateSelected()
            }
            return
        }
        do {
            let host = try createPage(for: tab)
            adopt(host)
            load(Self.loadURL(for: tab), in: host)
        } catch { addressError = error.localizedDescription }
    }

    static func loadURL(for tab: Tab) -> URL? {
        if let url = URL(string: tab.urlString), url.isFileURL { return url }
        return tab.url
    }

    private func createPage(for tab: Tab) throws -> any BrowserPage {
        guard !isClosed else { throw EngineError.closed }
        guard !app.isDeletingProfile(record.profileID) else { throw EngineError.notReady(String(localized: "This profile is being deleted.")) }
        guard !app.suspendedContexts.contains(contextID(for: tab.engineID)) else {
            throw EngineError.notReady(String(localized: "Website data is being cleared. Try again when it finishes."))
        }
        guard let profile = app.profiles.first(where: { $0.id == record.profileID }) else { throw EngineError.closed }
        if let blocker = app.engines.engine(app.engines.effectiveID(tab.engineID))?.contentBlocker,
           blocker.isReady, !blocker.canLoad(profileID: record.profileID) {
            throw EngineError.notReady(String(localized: "Content rules could not load. Disable or replace them in Settings before opening this page."))
        }
        let context = try app.engines.context(engineID: app.engines.effectiveID(tab.engineID), profile: profile,
            privateWindowID: isPrivate ? id : nil, siteSettings: app.siteSettings)
        let page = try context.makePage(tabID: tab.id, windowID: id)
        if let favicon = icon(for: tab.id) {
            page.state.favicon = favicon
            page.state.faviconOrigin = tab.url.flatMap(AddressResolver.canonicalOrigin)
        }
        return page
    }

    private func isCurrent(_ tabID: UUID, generation: UUID) -> Bool {
        !isClosed && !app.isDeletingProfile(record.profileID) && generations[tabID] == generation && record.tabs.contains { $0.id == tabID }
    }

    private func adopt(_ host: any BrowserPage, historyVisit: (url: String, date: Date)? = nil) {
        let generation = UUID()
        let tabID = host.tabID
        let contextID = host.contextID
        historyVisits[tabID] = historyVisit
        generations[tabID] = generation
        pages[tabID] = host
        host.setInspectable(app.preferences.webInspectorEnabled)
        host.events.onChange = { [weak self] id, url, title in
            guard let self, id == tabID, self.isCurrent(id, generation: generation),
                  let i = self.record.tabs.firstIndex(where: { $0.id == id }) else { return }
            if self.record.tabs[i].urlString != url {
                self.switches.removeValue(forKey: id)
                self.record.tabs[i].titleOverride = nil
            }
            self.record.tabs[i].urlString = url
            self.record.tabs[i].title = title.isEmpty ? (URL(string: url)?.host ?? "New Tab") : title
            if URL(string: url)?.isFileURL != true {
                self.record.tabs[i].localFileBookmark = nil
                self.privateLocalFileBookmarks.removeValue(forKey: id)
            }
            if self.record.selectedTabID == id && !self.isEditingAddress { self.addressDraft = url }
            if !self.isPrivate, let visit = self.historyVisits[tabID], visit.url == url {
                self.app.library.updateHistoryTitle(urlString: url, title: title,
                    profileID: self.record.profileID, engineID: contextID.engineID, visitedAt: visit.date)
            }
        }
        host.events.onCreatePage = { [weak self] child in
            guard let self, self.isCurrent(tabID, generation: generation), child.contextID == contextID,
                  host.state.lifecycle == .ready, self.closeRequests[tabID] == nil,
                  !self.preservingTabsForTermination,
                  !self.app.suspendedContexts.contains(contextID),
                  !self.record.tabs.contains(where: { $0.id == child.tabID }),
                  let parent = self.record.tabs.first(where: { $0.id == tabID }) else { return false }
            let tab = Tab(id: child.tabID, spaceID: parent.spaceID, title: "Opening…",
                          engineID: parent.engineID, engineOverride: parent.engineOverride)
            self.insertNewTemporaryTab(tab)
            self.adopt(child)
            self.select(tab.id)
            return true
        }
        host.events.onExternalURL = { [weak self] url in
            guard let self, self.isCurrent(tabID, generation: generation) else { return }
            self.openExternalURL(url)
        }
        host.events.onFavicon = { [weak self] id, url, png in
            guard id == tabID else { return }
            self?.receiveFavicon(tabID: id, generation: generation, url: url, png: png)
        }
        host.events.onVisit = { [weak self] id, url, title in
            guard let self, id == tabID, self.isCurrent(id, generation: generation), !self.isPrivate else { return }
            let date = Date()
            self.historyVisits[tabID] = (url, date)
            self.app.library.recordVisit(urlString: url, title: title, profileID: self.record.profileID, at: date, engineID: contextID.engineID)
        }
        host.events.onDownload = { [weak self] download in
            guard let self, self.isCurrent(tabID, generation: generation) else { download.cancel {}; return }
            self.app.downloads.accept(download, isPrivate: self.isPrivate)
        }
        host.events.onClose = { [weak self] in
            guard let self, self.isCurrent(tabID, generation: generation) else { return }
            // Chromium can close a page independently after accepting its
            // before-unload request. That callback must not request another
            // close while the original request is still awaiting its result.
            guard !self.preservingTabsForTermination else { return }
            self.completeCloseTab(tabID)
        }
        host.events.onActivate = { [weak self] in
            guard let self, self.isCurrent(tabID, generation: generation), self.record.selectedTabID != tabID else { return }
            self.select(tabID)
        }
        host.events.onKeyEvent = { [weak self] event in
            guard let self, self.isCurrent(tabID, generation: generation), self.record.selectedTabID == tabID else { return false }
            return self.onKeyEvent?(event) ?? false
        }
        host.events.onMediaPermissionRequest = { [weak self, weak host] request in
            guard let self, let host else { request.resolve(.deny); return }
            self.presentMediaPermission(request, from: host, generation: generation)
        }
        host.events.onJavaScriptDialog = { [weak self, weak host] request in
            guard let self, let host else { request.resolve(.cancel); return }
            self.presentJavaScriptDialog(request, from: host, generation: generation)
        }
        host.events.onHTTPAuthRequest = { [weak self, weak host] request in
            guard let self, let host else { request.resolve(nil); return }
            self.presentHTTPAuth(request, from: host, generation: generation)
        }
        host.events.onFileChooserRequest = { [weak self, weak host] request in
            guard let self, let host else { request.resolve(nil); return }
            self.presentFileChooser(request, from: host, generation: generation)
        }
        host.events.onExternalProtocolRequest = { [weak self, weak host] request in
            guard let self, let host else { request.resolve(false); return }
            self.presentExternalProtocol(request, from: host, generation: generation)
        }
        host.events.onClientCertificateRequest = { [weak self, weak host] request in
            guard let self, let host else { request.resolve(nil); return }
            self.presentClientCertificate(request, from: host, generation: generation)
        }
        host.events.onPromptCancelled = { [weak self] requestID in
            self?.cancelPagePrompt(requestID)
        }
        host.applyContentRules()
    }

    private func presentMediaPermission(_ request: PageMediaPermissionRequest, from host: any BrowserPage,
                                        generation: UUID) {
        guard request.isPending, request.tabID == host.tabID, request.contextID == host.contextID,
              request.windowID == id, !request.documentID.isEmpty, !request.frameID.isEmpty,
              isCurrent(host.tabID, generation: generation), pages[host.tabID] === host,
              host.capabilities.permissions.isSuperset(of: request.kinds), !request.kinds.isEmpty,
              let pageURL = URL(string: host.state.urlString),
              let pageOrigin = AddressResolver.canonicalOrigin(pageURL),
              let embeddingOrigin = AddressResolver.canonicalOrigin(request.embeddingOrigin),
              let requestingOrigin = AddressResolver.canonicalOrigin(request.requestingOrigin),
              pageOrigin == embeddingOrigin else {
            request.resolve(.deny)
            return
        }
        guard promptPresenters[request.id] == nil else { request.resolve(.deny); return }
        let presenter = PagePresenter(window: { [weak host] in host?.nativeView.window }) { [weak host] pending in
            host?.setAppPromptPending(pending)
        }
        promptPresenters[request.id] = (host.tabID, presenter)
        presenter.requestMedia(id: request.id, kinds: request.kinds, origin: request.requestingOrigin,
            topLevelOrigin: embeddingOrigin, sameOrigin: requestingOrigin == embeddingOrigin,
            tabID: host.tabID, contextID: host.contextID, store: app.siteSettings,
            isCurrent: { [weak self, weak host] in
                guard let self, let host else { return false }
                return self.isCurrent(host.tabID, generation: generation) && self.pages[host.tabID] === host
                    && URL(string: host.state.urlString).flatMap(AddressResolver.canonicalOrigin) == embeddingOrigin
            }) { [weak self] decision in
                self?.promptPresenters.removeValue(forKey: request.id)
                request.resolve(decision)
            }
    }

    private func cancelPagePrompt(_ requestID: UUID) {
        promptPresenters[requestID]?.presenter.cancel(requestID)
        promptPresenters.removeValue(forKey: requestID)
    }

    private func promptIsCurrent(_ identity: PagePromptIdentity, host: any BrowserPage,
                                 generation: UUID) -> Bool {
        guard identity.tabID == host.tabID, identity.contextID == host.contextID,
              identity.windowID == id, !identity.documentID.isEmpty, !identity.frameID.isEmpty,
              isCurrent(host.tabID, generation: generation), pages[host.tabID] === host,
              let pageURL = URL(string: host.state.urlString),
              let pageOrigin = AddressResolver.canonicalOrigin(pageURL),
              let visiblePromptOrigin = identity.visiblePageOrigin ?? identity.topLevelOrigin,
              AddressResolver.canonicalOrigin(visiblePromptOrigin) == pageOrigin,
              AddressResolver.canonicalOrigin(identity.requestingOrigin) != nil else { return false }
        return true
    }

    private func presentJavaScriptDialog(_ request: PageJavaScriptDialogRequest, from host: any BrowserPage,
                                         generation: UUID) {
        let dialog = request.prompt
        guard request.isPending, dialog.kind != .formRepost || dialog.isReload,
              promptIsCurrent(request.identity, host: host, generation: generation),
              promptPresenters[request.id] == nil else { request.resolve(.cancel); return }
        let presenter = PagePresenter(window: { [weak host] in host?.nativeView.window }) { [weak host] pending in
            host?.setAppPromptPending(pending)
        }
        promptPresenters[request.id] = (host.tabID, presenter)
        let origin = AddressResolver.canonicalOrigin(request.identity.requestingOrigin) ?? request.identity.requestingOrigin.absoluteString
        let alert: NSAlert = switch dialog.kind {
        case .alert:
            PagePresenter.alert(title: origin, message: dialog.message, buttons: [String(localized: "OK")])
        case .confirm, .prompt:
            PagePresenter.alert(title: origin, message: dialog.message,
                buttons: [String(localized: "OK"), String(localized: "Cancel")])
        case .beforeUnload:
            PagePresenter.alert(
                title: dialog.isReload ? String(localized: "Reload this page?") : String(localized: "Leave this page?"),
                message: dialog.message,
                buttons: [dialog.isReload ? String(localized: "Reload") : String(localized: "Leave"),
                          String(localized: "Cancel")])
        case .formRepost:
            PagePresenter.formRepostAlert(origin: origin)
        }
        let field: NSTextField? = dialog.kind == .prompt ? NSTextField(string: dialog.defaultText ?? "") : nil
        if let field { field.frame = NSRect(x: 0, y: 0, width: 300, height: 24); alert.accessoryView = field }
        presenter.present(alert, id: request.id) { [weak self, weak host] response in
            self?.promptPresenters.removeValue(forKey: request.id)
            guard let self, let host, self.promptIsCurrent(request.identity, host: host, generation: generation) else {
                request.resolve(.cancel)
                return
            }
            request.resolve(response == .alertFirstButtonReturn ? .accept(field?.stringValue) : .cancel)
        }
    }

    private func presentHTTPAuth(_ request: PageHTTPAuthRequest, from host: any BrowserPage,
                                 generation: UUID) {
        guard request.isPending, promptIsCurrent(request.identity, host: host, generation: generation),
              promptPresenters[request.id] == nil else { request.resolve(nil); return }
        let presenter = PagePresenter(window: { [weak host] in host?.nativeView.window }) { [weak host] pending in
            host?.setAppPromptPending(pending)
        }
        promptPresenters[request.id] = (host.tabID, presenter)
        let challenge = request.prompt
        let target = (challenge.isProxy ? request.identity.requestingOrigin.host : challenge.requestURL.host)
            ?? request.identity.requestingOrigin.host ?? "website"
        let title = challenge.isProxy ? String(format: String(localized: "Sign in to proxy %@"), target)
            : String(format: String(localized: "Sign in to %@"), target)
        let message: String
        if challenge.firstAttempt {
            message = challenge.isProxy ? String(localized: "This proxy requires a username and password.")
                : String(localized: "This website requires a username and password.")
        } else {
            message = challenge.isProxy ? String(localized: "Proxy sign-in failed. Check your username and password.")
                : String(localized: "Sign-in failed. Check your username and password.")
        }
        let alert = PagePresenter.alert(title: title, message: message,
            buttons: [String(localized: "Sign In"), String(localized: "Cancel")])
        let username = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        username.placeholderString = String(localized: "Username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = String(localized: "Password")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        fields.addSubview(username); fields.addSubview(password); alert.accessoryView = fields
        presenter.present(alert, id: request.id) { [weak self, weak host] response in
            self?.promptPresenters.removeValue(forKey: request.id)
            guard let self, let host, self.promptIsCurrent(request.identity, host: host, generation: generation) else {
                request.resolve(nil)
                return
            }
            request.resolve(response == .alertFirstButtonReturn
                ? PageHTTPAuthCredential(username: username.stringValue, password: password.stringValue) : nil)
        }
    }

    private func presentFileChooser(_ request: PageFileChooserRequest, from host: any BrowserPage,
                                    generation: UUID) {
        guard request.isPending, promptIsCurrent(request.identity, host: host, generation: generation),
              promptPresenters[request.id] == nil else { request.resolve(nil); return }
        let presenter = PagePresenter(window: { [weak host] in host?.nativeView.window }) { [weak host] pending in
            host?.setAppPromptPending(pending)
        }
        promptPresenters[request.id] = (host.tabID, presenter)
        let chooser = request.prompt
        if chooser.mode == .save {
            presenter.chooseSaveFile(id: request.id, acceptedTypes: chooser.acceptedTypes,
                title: chooser.title, defaultFilename: chooser.defaultFilename) { [weak self, weak host] url in
                    self?.promptPresenters.removeValue(forKey: request.id)
                    guard let self, let host, self.promptIsCurrent(request.identity, host: host, generation: generation) else {
                        request.resolve(nil)
                        return
                    }
                    request.resolve(url.map { [$0] })
                }
            return
        }
        presenter.chooseFiles(id: request.id, multiple: chooser.mode == .openMultiple,
            directories: chooser.mode == .uploadFolder || chooser.mode == .openDirectory,
            files: chooser.mode == .open || chooser.mode == .openMultiple,
            acceptedTypes: chooser.acceptedTypes, title: chooser.title, defaultFilename: chooser.defaultFilename) { [weak self, weak host] urls in
                self?.promptPresenters.removeValue(forKey: request.id)
                guard let self, let host, self.promptIsCurrent(request.identity, host: host, generation: generation) else {
                    request.resolve(nil)
                    return
                }
                request.resolve(urls)
            }
    }

    private func presentExternalProtocol(_ request: PageExternalProtocolRequest, from host: any BrowserPage,
                                         generation: UUID) {
        let prompt = request.prompt
        guard request.isPending, promptIsCurrent(request.identity, host: host, generation: generation),
              prompt.userGesture, prompt.primaryMainFrame, !prompt.fencedFrame,
              promptPresenters[request.id] == nil else { request.resolve(false); return }
        let presenter = PagePresenter(window: { [weak host] in host?.nativeView.window }) { [weak host] pending in
            host?.setAppPromptPending(pending)
        }
        promptPresenters[request.id] = (host.tabID, presenter)
        let requestingOrigin = AddressResolver.canonicalOrigin(request.identity.requestingOrigin)
            ?? request.identity.requestingOrigin.absoluteString
        let alert = PagePresenter.alert(title: String(localized: "Open another application?"),
            message: "\(requestingOrigin)\n\n\(prompt.targetURL.absoluteString)",
            buttons: [String(localized: "Open"), String(localized: "Cancel")])
        presenter.present(alert, id: request.id) { [weak self, weak host] response in
            self?.promptPresenters.removeValue(forKey: request.id)
            guard let self, let host, self.promptIsCurrent(request.identity, host: host, generation: generation) else {
                request.resolve(false)
                return
            }
            request.resolve(response == .alertFirstButtonReturn)
        }
    }

    private func presentClientCertificate(_ request: PageClientCertificateRequest,
                                          from host: any BrowserPage, generation: UUID) {
        let prompt = request.prompt
        guard request.isPending, !prompt.choices.isEmpty,
              Set(prompt.choices.map(\.id)).count == prompt.choices.count,
              clientCertificateIsCurrent(request, host: host, generation: generation),
              promptPresenters[request.id] == nil else { request.resolve(nil); return }
        let presenter = PagePresenter(window: { [weak host] in host?.nativeView.window }) { [weak host] pending in
            host?.setAppPromptPending(pending)
        }
        promptPresenters[request.id] = (host.tabID, presenter)
        let origin = AddressResolver.canonicalOrigin(request.identity.requestingOrigin)
            ?? request.identity.requestingOrigin.absoluteString
        presenter.chooseClientCertificate(id: request.id, origin: origin,
                                          choices: prompt.choices,
                                          truncated: prompt.choicesTruncated) { [weak self, weak host] choiceID in
            self?.promptPresenters.removeValue(forKey: request.id)
            guard let self, let host, self.clientCertificateIsCurrent(request, host: host, generation: generation) else {
                request.resolve(nil)
                return
            }
            request.resolve(choiceID)
        }
    }

    private func clientCertificateIsCurrent(_ request: PageClientCertificateRequest,
                                            host: any BrowserPage, generation: UUID) -> Bool {
        let identity = request.identity
        guard identity.tabID == host.tabID, identity.contextID == host.contextID,
              identity.windowID == id, isCurrent(host.tabID, generation: generation),
              pages[host.tabID] === host,
              AddressResolver.canonicalOrigin(identity.requestingOrigin) != nil else { return false }
        switch request.prompt.context {
        case .document(let documentID, let frameID):
            guard !documentID.isEmpty, !frameID.isEmpty,
                  identity.documentID == documentID, identity.frameID == frameID else { return false }
        case .navigation(let navigationID, _):
            guard !navigationID.isEmpty, identity.documentID.isEmpty,
                  identity.frameID.isEmpty else { return false }
        case .page(let pageID):
            guard !pageID.isEmpty, identity.documentID.isEmpty,
                  identity.frameID.isEmpty else { return false }
        }
        let permitsOpaqueCurrent: Bool = switch request.prompt.context {
        case .document: false
        case .navigation(_, let primaryMainFrame): primaryMainFrame
        case .page: true
        }
        guard let currentURL = URL(string: host.state.urlString) else {
            return permitsOpaqueCurrent && host.state.urlString.isEmpty
        }
        guard let currentOrigin = AddressResolver.canonicalOrigin(currentURL) else {
            guard permitsOpaqueCurrent,
                  host.state.urlString.isEmpty || host.state.urlString == "about:blank" else { return false }
            if case .page = request.prompt.context {
                return identity.topLevelOrigin.flatMap(AddressResolver.canonicalOrigin) == nil
                    && identity.visiblePageOrigin.flatMap(AddressResolver.canonicalOrigin) == nil
            }
            return true
        }
        guard let visible = identity.visiblePageOrigin else { return false }
        guard AddressResolver.canonicalOrigin(visible) == currentOrigin else { return false }
        let requiresMatchingTopLevel: Bool = switch request.prompt.context {
        case .document, .page: true
        case .navigation(_, let primaryMainFrame): !primaryMainFrame
        }
        guard requiresMatchingTopLevel, let topLevel = identity.topLevelOrigin else { return true }
        return AddressResolver.canonicalOrigin(topLevel) == currentOrigin
    }

    private func cancelPagePrompts(for tabID: UUID) {
        for (id, entry) in Array(promptPresenters) where entry.tabID == tabID { entry.presenter.cancel(id) }
        promptPresenters = promptPresenters.filter { $0.value.tabID != tabID }
    }

    private func cancelAllPagePrompts() {
        for (id, entry) in Array(promptPresenters) { entry.presenter.cancel(id) }
        promptPresenters.removeAll()
    }

    /// Transfers one retained page out of this window. The caller must adopt it
    /// immediately in a destination with the same normal browsing context.
    func takeSelectedTabForDetach(to destinationWindowID: UUID) throws -> (tab: Tab, host: any BrowserPage, historyVisit: (url: String, date: Date)?) {
        guard canDetachSelectedTab, let tab = selectedTab, let host = pages[tab.id] else {
            throw EngineError.notReady(String(localized: "Finish the current page action before moving this tab to a new window."))
        }
        try host.moveToWindow(destinationWindowID)
        pages.removeValue(forKey: tab.id)
        generations.removeValue(forKey: tab.id)
        loads.removeValue(forKey: tab.id)
        switches.removeValue(forKey: tab.id)
        closeRequests.removeValue(forKey: tab.id)
        recentTabIDs.removeAll { $0 == tab.id }
        recentCycleIDs.removeAll { $0 == tab.id }
        host.events.clear()
        record.tabs.removeAll { $0.id == tab.id }
        if let next = record.tabs.last(where: { $0.spaceID == record.selectedSpaceID && $0.isUnloaded != true }) {
            select(next.id)
        } else {
            clearSelection()
        }
        return (tab, host, historyVisits.removeValue(forKey: tab.id))
    }

    func adoptDetachedTab(_ tab: Tab, host: any BrowserPage, historyVisit: (url: String, date: Date)? = nil) {
        guard !isClosed, host.tabID == tab.id, host.contextID.profileID == record.profileID,
              !host.contextID.isPrivate else { return }
        record.tabs = [tab]
        record.selectedTabID = tab.id
        addressDraft = tab.urlString
        adopt(host, historyVisit: historyVisit)
    }

    func focusSelectedPageAfterAttach() {
        Task { [weak self] in
            await Task.yield()
            guard let self, !self.isClosed, !self.app.isDeletingProfile(self.record.profileID),
                  self.nativeWindow?.isKeyWindow == true else { return }
            self.selectedPage?.focus()
        }
    }

    private func load(_ url: URL?, in host: any BrowserPage) {
        let generation = generations[host.tabID]
        let request = UUID(); loads[host.tabID] = request
        if host.state.lifecycle == .ready {
            loads.removeValue(forKey: host.tabID)
            if let url { navigate(url, in: host) }
            return
        }
        Task { [weak self] in
            do {
                try await host.prepare()
                guard let self, let generation, self.isCurrent(host.tabID, generation: generation),
                      self.loads[host.tabID] == request, !self.app.suspendedContexts.contains(host.contextID) else { return }
                self.loads.removeValue(forKey: host.tabID)
                if let url { self.navigate(url, in: host) }
            } catch {
                guard let self, let generation, self.isCurrent(host.tabID, generation: generation), self.loads[host.tabID] == request else { return }
                self.loads.removeValue(forKey: host.tabID)
                host.state.errorMessage = error.localizedDescription
            }
        }
    }

    private func navigate(_ url: URL, in host: any BrowserPage) {
        guard url.isFileURL else { host.navigate(to: url); return }
        let generation = generations[host.tabID]
        Task { [weak self, weak host] in
            guard let self, let host else { return }
            do { try await host.openLocalFile(try self.localFileURL(for: host.tabID)) }
            catch {
                guard self.generations[host.tabID] == generation, self.pages[host.tabID] === host else { return }
                host.state.errorMessage = error.localizedDescription
            }
        }
    }

    private func localFileURL(for tabID: UUID) throws -> URL {
        guard let index = record.tabs.firstIndex(where: { $0.id == tabID }),
              let fallback = URL(string: record.tabs[index].urlString), fallback.isFileURL else {
            throw EngineError.notReady(String(localized: "Choose a local file with File > Open File…"))
        }
        let bookmark = isPrivate ? privateLocalFileBookmarks[tabID] : record.tabs[index].localFileBookmark
        guard let bookmark else {
            throw EngineError.notReady(String(localized: "Cobble no longer has permission to open this local file. Choose it again with File > Open File…"))
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { throw EngineError.notReady(String(localized: "The saved local-file permission is invalid. Choose the file again.")) }
        if stale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            if isPrivate { privateLocalFileBookmarks[tabID] = refreshed }
            else { record.tabs[index].localFileBookmark = refreshed }
        }
        return url
    }

    private func retireHost(_ id: UUID, leavingUnloaded: Bool = false) {
        generations.removeValue(forKey: id)
        cancelPagePrompts(for: id)
        historyVisits.removeValue(forKey: id)
        if leavingUnloaded, let index = record.tabs.firstIndex(where: { $0.id == id }) {
            record.tabs[index].isUnloaded = true
        }
        closeRequests.removeValue(forKey: id)
        switches.removeValue(forKey: id)
        loads.removeValue(forKey: id)
        if let host = pages.removeValue(forKey: id) { app.engines.retire(host) }
        if let pending = pendingPages.removeValue(forKey: id) { app.engines.retire(pending) }
    }

    /// Nil restores the default or site-rule choice.
    func setEngine(_ engineID: EngineID?, for tabID: UUID) {
        guard let tab = record.tabs.first(where: { $0.id == tabID }), let url = tab.url else { return }
        changeEngine(for: tab, to: app.preferences.engine(for: url, override: engineID), url: url, override: engineID)
    }

    func nonDefaultEngine(for tab: Tab) -> (any BrowserEngine)? {
        let engineID = app.engines.effectiveID(tab.engineID)
        guard engineID != app.engines.effectiveID(app.preferences.defaultEngine) else { return nil }
        return app.engines.engine(engineID)
    }

    private func changeEngine(for tab: Tab, to engineID: EngineID, url: URL, override: EngineID?) {
        guard !isClosed else { return }
        guard app.suspendedContexts.isDisjoint(with: [contextID(for: tab.engineID), contextID(for: engineID)]) else {
            addressError = String(localized: "Website data is being updated. Try switching engines again shortly.")
            return
        }
        guard let engine = app.engines.engine(app.engines.effectiveID(engineID)) else { addressError = EngineError.unavailable(engineID).localizedDescription; return }
        if app.engines.effectiveID(tab.engineID) == engine.id {
            switches.removeValue(forKey: tab.id)
            if let pending = pendingPages.removeValue(forKey: tab.id) { app.engines.retire(pending) }
            if let i = record.tabs.firstIndex(where: { $0.id == tab.id }) {
                record.tabs[i].engineID = engineID
                record.tabs[i].engineOverride = override
            }
            app.persist()
            return
        }
        let message = String(format: String(localized: "Reload with %@? Unsaved changes and back/forward history will be lost. You may need to sign in again."), engine.name)
        let accepted = confirmEngineSwitch?(message) ?? (PagePresenter.alert(title: String(localized: "Change engine?"), message: message,
            buttons: [String(localized: "Reload"), String(localized: "Cancel")]).runModal() == .alertFirstButtonReturn)
        guard accepted, !isClosed, record.tabs.contains(where: { $0.id == tab.id }) else { return }
        if let pending = pendingPages.removeValue(forKey: tab.id) { app.engines.retire(pending) }
        let operation = UUID(); switches[tab.id] = operation
        let oldGeneration = generations[tab.id]
        var destination = tab; destination.engineID = engineID; destination.engineOverride = override
        Task { [weak self] in
            guard let self, !self.isClosed, self.switches[tab.id] == operation else { return }
            var candidate: (any BrowserPage)?
            do {
                let page = try self.createPage(for: destination)
                candidate = page
                self.pendingPages[tab.id] = page
                try await page.prepare()
                let loginSharingWarning = await self.app.shareLogin(
                    from: self.contextID(for: tab.engineID), to: page.contextID, url: url,
                    confirmReplacement: {
                        self.confirmLoginReplacement?() ?? (PagePresenter.alert(
                            title: String(localized: "Replace existing website cookies?"),
                            message: String(format: String(localized: "%@ already has cookies for this website. Replacing them may sign you out or change accounts. Keep them, or replace them with cookies from the current engine?"), engine.name),
                            buttons: [String(localized: "Keep Existing"), String(localized: "Replace Cookies")]
                        ).runModal() == .alertSecondButtonReturn)
                    }) {
                        !self.isClosed && self.switches[tab.id] == operation
                            && self.generations[tab.id] == oldGeneration
                            && self.record.tabs.contains(where: { $0.id == tab.id })
                    }
                guard !self.isClosed, self.switches[tab.id] == operation,
                      self.generations[tab.id] == oldGeneration,
                      !self.app.suspendedContexts.contains(page.contextID),
                      let i = self.record.tabs.firstIndex(where: { $0.id == tab.id }) else {
                    if self.pendingPages[tab.id] === page { self.pendingPages.removeValue(forKey: tab.id) }
                    self.app.engines.retire(page); return
                }
                self.pendingPages.removeValue(forKey: tab.id)
                self.retireHost(tab.id)
                self.record.tabs[i].engineID = engineID
                self.record.tabs[i].engineOverride = override
                self.record.tabs[i].urlString = url.absoluteString
                self.record.tabs[i].favicon = nil
                self.record.tabs[i].isUnloaded = nil
                self.adopt(page)
                page.navigate(to: url)
                if self.record.selectedTabID == tab.id { self.addressDraft = url.absoluteString; self.isEditingAddress = false }
                self.addressError = loginSharingWarning
            } catch {
                if let candidate {
                    if self.pendingPages[tab.id] === candidate { self.pendingPages.removeValue(forKey: tab.id) }
                    self.app.engines.retire(candidate)
                }
                if self.switches[tab.id] == operation { self.switches.removeValue(forKey: tab.id); self.addressError = error.localizedDescription }
            }
        }
    }

    private func receiveFavicon(tabID: UUID, generation: UUID, url: URL, png: Data) {
        guard generations[tabID] == generation, let index = record.tabs.firstIndex(where: { $0.id == tabID }),
              let origin = AddressResolver.canonicalOrigin(url) else { return }
        guard let icon = CachedFavicon(origin: origin, png: png).validated(for: url.absoluteString) else { return }
        record.tabs[index].favicon = icon
        guard !isPrivate else { return }
        for i in app.savedItems.indices where app.savedItems[i].profileID == record.profileID {
            if let savedURL = URL(string: app.savedItems[i].urlString), AddressResolver.canonicalOrigin(savedURL) == origin {
                app.savedItems[i].favicon = icon
            }
        }
        app.persist()
    }

    func addTab(url: URL? = nil) {
        guard !app.isDeletingProfile(record.profileID) else { return }
        guard let url else {
            openCommandBar()
            return
        }
        let tab = Tab(spaceID: record.selectedSpaceID, urlString: url.absoluteString, title: url.host ?? "Loading…", engineID: app.preferences.engine(for: url))
        insertNewTemporaryTab(tab)
        select(tab.id)
    }

    @discardableResult
    func addTabForScripting(url: URL) -> Tab? {
        guard scriptingMutationAllowed else { return nil }
        addTab(url: url)
        return selectedTab
    }

    @discardableResult
    func selectTabForScripting(_ id: UUID) -> Tab? {
        guard scriptingMutationAllowed, record.tabs.contains(where: { $0.id == id }) else { return nil }
        select(id)
        return selectedTab
    }

    private func insertNewTemporaryTab(_ tab: Tab) {
        if app.preferences.newTabsNextToActive,
           let selected = selectedTab, selected.savedItemID == nil, selected.spaceID == tab.spaceID,
           let index = record.tabs.firstIndex(where: { $0.id == selected.id }) {
            record.tabs.insert(tab, at: index + 1)
        } else {
            // A saved row has no position inside the temporary-tab section.
            record.tabs.append(tab)
        }
    }

    func closeTab(_ id: UUID, selectReplacement: Bool = true) {
        guard canChangeTemporaryTabs, selectedCloseOperation == nil,
              record.tabs.contains(where: { $0.id == id }) else { return }
        guard let host = pages[id], host.capabilities.requiresCloseConfirmation else {
            completeCloseTab(id, selectReplacement: selectReplacement)
            return
        }
        Task { [weak self, host] in
            await self?.closeConfirmedTab(id, host: host, selectReplacement: selectReplacement)
        }
    }

    /// AppleScript commands cannot present before-unload or native sheets.
    @discardableResult
    func closeTabForScripting(_ id: UUID) -> Bool {
        guard scriptingMutationAllowed, closeRequests[id] == nil,
              loads[id] == nil, switches[id] == nil, pendingPages[id] == nil,
              record.tabs.contains(where: { $0.id == id }),
              pages[id]?.capabilities.requiresCloseConfirmation != true,
              pages[id]?.hasPendingPrompt != true else { return false }
        completeCloseTab(id)
        return true
    }

    /// A remote close follows the same native confirmation path as a user close.
    func closeTabForSync(_ id: UUID) async -> Bool {
        guard !Task.isCancelled, scriptingMutationAllowed,
              let tab = record.tabs.first(where: { $0.id == id }), tab.savedItemID == nil,
              closeRequests[id] == nil, loads[id] == nil, switches[id] == nil,
              pendingPages[id] == nil, pages[id]?.hasPendingPrompt != true else { return false }
        if let host = pages[id], host.capabilities.requiresCloseConfirmation {
            await closeConfirmedTab(id, host: host, selectReplacement: true,
                                    registerUndo: false, expectedTab: tab)
            return !record.tabs.contains(where: { $0.id == id })
        }
        guard record.tabs.first(where: { $0.id == id })?.matchesSyncSnapshot(tab) == true else { return false }
        completeCloseTab(id, registerUndo: false)
        return true
    }

    private func closeConfirmedTab(_ id: UUID, host: any BrowserPage, selectReplacement: Bool,
                                   registerUndo: Bool = true, expectedTab: Tab? = nil) async {
        guard canChangeTemporaryTabs, closeRequests[id] == nil else { return }
        let operation = UUID()
        let generation = generations[id]
        closeRequests[id] = operation
        let accepted = await host.requestClose()
        guard closeRequests[id] == operation else { return }
        closeRequests.removeValue(forKey: id)
        if expectedTab != nil && Task.isCancelled {
            if pages[id] === host, generations[id] == generation, host.state.lifecycle == .closed {
                retireAcceptedPagesAfterCancelledTermination([id])
            }
            return
        }
        guard canChangeTemporaryTabs, record.tabs.contains(where: { $0.id == id }),
              pages[id] === host, generations[id] == generation else { return }
        if let expectedTab,
           record.tabs.first(where: { $0.id == id })?.matchesSyncSnapshot(expectedTab) != true { return }
        guard accepted else {
            addressError = host.state.errorMessage ?? String(localized: "The page cancelled its close request.")
            return
        }
        completeCloseTab(id, selectReplacement: selectReplacement, registerUndo: registerUndo)
    }

    func closeSelectedTemporaryTabs() {
        guard canChangeTemporaryTabs, selectedCloseOperation == nil, closeRequests.isEmpty else { return }
        let ids = selectedTemporaryTabs.map(\.id)
        guard !ids.isEmpty else { return }
        let operation = UUID()
        selectedCloseOperation = operation
        Task { [weak self] in
            guard let self else { return }
            for id in ids {
                guard self.selectedCloseOperation == operation, self.canChangeTemporaryTabs,
                      self.record.tabs.contains(where: { $0.id == id }) else { break }
                if let host = self.pages[id], host.capabilities.requiresCloseConfirmation {
                    await self.closeConfirmedTab(id, host: host, selectReplacement: true)
                } else {
                    self.completeCloseTab(id)
                }
            }
            if self.selectedCloseOperation == operation { self.selectedCloseOperation = nil }
        }
    }

    var hasCompletedClosePagesPreflight: Bool {
        guard !isClosed else { return true }
        guard preservingTabsForTermination, closePagesPreflightComplete else { return false }
        return pages.values.allSatisfy { !$0.capabilities.requiresCloseConfirmation || $0.state.lifecycle == .closed }
    }

    /// Requests close confirmation from the native pages in this window
    /// without changing its recoverable tab records. The app flushes those
    /// records before calling `closePages()` after a successful result.
    func requestClosePages() async -> Bool {
        guard !isClosed else { return true }
        if preservingTabsForTermination {
            guard hasCompletedClosePagesPreflight else {
                cancelClosePages()
                return false
            }
            return true
        }
        preservingTabsForTermination = true
        closePagesPreflightComplete = false
        let candidates = pages.filter { $0.value.capabilities.requiresCloseConfirmation }

        for (id, host) in candidates {
            guard record.tabs.contains(where: { $0.id == id }) else { continue }
            // A user close is already awaiting its native before-unload result.
            // Do not let application termination force that page closed.
            guard closeRequests[id] == nil else {
                cancelClosePages()
                return false
            }
            let operation = UUID()
            closeRequests[id] = operation
            let closed = await host.requestClose()
            guard closeRequests[id] == operation else {
                cancelClosePages()
                return false
            }
            closeRequests.removeValue(forKey: id)
            if closed, pages[id] === host {
                continue
            }

            cancelClosePages()
            return false
        }
        closePagesPreflightComplete = true
        guard hasCompletedClosePagesPreflight else {
            cancelClosePages()
            return false
        }
        return true
    }

    /// Cancels a window-termination preflight. It is public so the app can
    /// reset windows that accepted a close when another window later refuses.
    func cancelClosePages() {
        closePagesPreflightComplete = false
        guard preservingTabsForTermination else { return }
        preservingTabsForTermination = false
        let closed = pages.compactMap { id, host in
            host.state.lifecycle == .closed ? id : nil
        }
        retireAcceptedPagesAfterCancelledTermination(closed)
    }

    /// A close accepted before a later tab refuses termination has already
    /// destroyed its native page. Retire that closed host but retain the tab
    /// record so selecting it can create a fresh page.
    private func retireAcceptedPagesAfterCancelledTermination(_ ids: [UUID]) {
        for id in ids {
            guard let index = record.tabs.firstIndex(where: { $0.id == id }) else { continue }
            record.tabs[index].isUnloaded = true
            retireHost(id)
        }
    }

    /// Removes a tab only after a user close was accepted, or when native code
    /// already closed it. Internal retirement intentionally bypasses this path.
    private func completeCloseTab(_ id: UUID, selectReplacement: Bool = true, registerUndo: Bool = true) {
        guard let i = record.tabs.firstIndex(where: { $0.id == id }) else { return }
        closeRequests.removeValue(forKey: id)
        let tab = record.tabs.remove(at: i)
        privateLocalFileBookmarks.removeValue(forKey: id)
        selectedTemporaryTabIDs.remove(id)
        if temporaryTabSelectionAnchorID == id { temporaryTabSelectionAnchorID = selectedTemporaryTabs.first?.id }
        if !isPrivate && registerUndo {
            closedTabs.append(tab)
            if closedTabs.count > 30 { closedTabs.removeFirst() }
            nativeWindow?.undoManager?.registerUndo(withTarget: self) { window in
                window.reopenClosedTab(id: id)
            }
            nativeWindow?.undoManager?.setActionName(String(localized: "Close Tab"))
        }
        retireHost(id)
        if record.selectedTabID == id {
            if let next = selectedTemporaryTabs.last(where: { $0.isUnloaded != true }) {
                activate(next.id)
            } else if selectReplacement, let next = record.tabs.last(where: {
                $0.spaceID == record.selectedSpaceID && $0.isUnloaded != true
                    && ($0.savedItemID == nil || pages[$0.id] != nil)
            }) {
                select(next.id)
            } else { clearSelection() }
        }
    }

    func renameTab(_ id: UUID, title: String) {
        guard let i = record.tabs.firstIndex(where: { $0.id == id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.tabs[i].titleOverride = name.isEmpty ? nil : name
    }

    func duplicateTab(_ id: UUID) {
        guard var tab = record.tabs.first(where: { $0.id == id }) else { return }
        let privateBookmark = privateLocalFileBookmarks[id]
        tab.id = UUID()
        tab.savedItemID = nil
        insertNewTemporaryTab(tab)
        if isPrivate, let privateBookmark { privateLocalFileBookmarks[tab.id] = privateBookmark }
        select(tab.id)
    }

    func reopenClosedTab(id: UUID? = nil) {
        let index = id.flatMap { target in closedTabs.lastIndex(where: { $0.id == target }) } ?? closedTabs.indices.last
        guard let index else { return }
        var tab = closedTabs.remove(at: index)
        if !spaces.contains(where: { $0.id == tab.spaceID }) { tab.spaceID = record.selectedSpaceID }
        if let itemID = tab.savedItemID {
            if let existing = record.tabs.first(where: { $0.savedItemID == itemID }) {
                select(existing.id)
                return
            }
            if let saved = app.savedItems.first(where: { $0.id == itemID }) { tab.spaceID = saved.spaceID ?? record.selectedSpaceID }
            else { tab.savedItemID = nil }
        }
        record.tabs.append(tab)
        select(tab.id)
    }

    func reloadSelected() {
        if let i = record.tabs.firstIndex(where: { $0.id == record.selectedTabID }) { record.tabs[i].isUnloaded = nil }
        if let host = selectedPage {
            if host.state.lifecycle == .preparing, let tab = selectedTab { load(Self.loadURL(for: tab), in: host) }
            else { host.reload() }
        }
        else { activateSelected() }
    }

    func submitAddress() {
        guard !isClosed else { return }
        switch AddressResolver.resolve(addressDraft, engines: app.preferences.searchEngines,
                                       defaultEngine: app.preferences.defaultSearchEngine) {
        case .navigate(let url):
            if selectedTab == nil {
                addTab(url: url)
                addressDraft = url.absoluteString
                addressError = nil
                isEditingAddress = false
                return
            }
            guard let tab = selectedTab else { return }
            let engineID = app.preferences.engine(for: url, override: tab.engineOverride)
            if app.engines.effectiveID(engineID) != app.engines.effectiveID(tab.engineID) {
                changeEngine(for: tab, to: engineID, url: url, override: tab.engineOverride)
                return
            }
            switches.removeValue(forKey: tab.id)
            if let pending = pendingPages.removeValue(forKey: tab.id) { app.engines.retire(pending) }
            guard !app.suspendedContexts.contains(contextID(for: engineID)) else { return }
            if let i = record.tabs.firstIndex(where: { $0.id == tab.id }) {
                record.tabs[i].engineID = engineID
                record.tabs[i].isUnloaded = nil
            }
            if let host = selectedPage { load(url, in: host) }
            else {
                if let i = record.tabs.firstIndex(where: { $0.id == tab.id }) { record.tabs[i].urlString = url.absoluteString }
                activateSelected()
            }
            addressDraft = url.absoluteString
            addressError = nil
            isEditingAddress = false
        case .external(let url): confirmExternalURL(url)
        case .blank:
            if addressDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "about:blank" {
                if let tab = selectedTab {
                    if let savedID = tab.savedItemID { unloadSavedItem(savedID) }
                    else { closeTab(tab.id, selectReplacement: false) }
                }
                clearSelection()
            }
        case .invalid(let message): addressError = message
        }
    }

    func openCommandBar() {
        cancelAddressEditing()
        commandQuery = ""
        commandBarPresented = true
    }

    func submitCommand() {
        switch AddressResolver.resolve(commandQuery, engines: app.preferences.searchEngines,
                                       defaultEngine: app.preferences.defaultSearchEngine) {
        case .navigate(let url):
            addTab(url: url)
            commandBarPresented = false
        case .blank: return
        case .external(let url):
            confirmExternalURL(url)
            commandBarPresented = false
        case .invalid(let message): addressError = message
        }
    }

    func clearSelection() {
        endRecentTabCycle()
        clearTemporaryTabSelection()
        record.selectedTabID = nil
        addressDraft = ""
        addressError = nil
        isEditingAddress = false
        findPresented = false
    }

    func selectSpace(_ id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        clearTemporaryTabSelection()
        record.selectedSpaceID = id
        let recent = recentTabIDs.compactMap { recentID in record.tabs.first { $0.id == recentID } }
            .first { $0.spaceID == id && $0.isUnloaded != true && ($0.savedItemID == nil || pages[$0.id] != nil) }
        let fallback = record.tabs.last { $0.spaceID == id && $0.savedItemID == nil && $0.isUnloaded != true }
            ?? record.tabs.last { $0.spaceID == id && $0.isUnloaded != true && pages[$0.id] != nil }
        if let tab = recent ?? fallback { select(tab.id) } else { clearSelection() }
    }

    func openSavedItem(_ id: UUID) {
        guard let item = app.savedItems.first(where: { $0.id == id && $0.profileID == record.profileID }) else { return }
        if let tab = record.tabs.first(where: { $0.savedItemID == id }) {
            select(tab.id)
            return
        }
        let tab = Tab(spaceID: item.spaceID ?? record.selectedSpaceID, urlString: item.urlString, title: item.title, savedItemID: id, engineID: URL(string: item.urlString).map { app.preferences.engine(for: $0) } ?? app.preferences.defaultEngine)
        record.tabs.append(tab)
        select(tab.id)
    }

    func pinTab(_ id: UUID, favorite: Bool = true, folderID: UUID? = nil, before: UUID? = nil) {
        guard !isPrivate, let i = record.tabs.firstIndex(where: { $0.id == id }),
              URL(string: record.tabs[i].urlString)?.isFileURL != true else { return }
        let global = favorite && folderID == nil
        let destination = global ? nil : record.selectedSpaceID
        let folder = global ? nil : folderID
        if let savedID = record.tabs[i].savedItemID {
            let current = app.savedItems.first { $0.id == savedID }
            if current?.spaceID != destination || current?.folderID != folder || before != nil {
                app.moveSavedItem(id: savedID, spaceID: destination, folderID: folder, before: before)
            }
        } else {
            guard let savedID = app.saveTab(record.tabs[i], profileID: record.profileID, favorite: global, folderID: folder, before: before) else { return }
            record.tabs[i].savedItemID = savedID
        }
    }

    func resetSavedDestination(_ id: UUID) {
        guard !isClosed, let item = app.savedItems.first(where: { $0.id == id && $0.profileID == record.profileID }),
              let url = URL(string: item.urlString), AddressResolver.canonicalOrigin(url) != nil,
              case .navigate = AddressResolver.resolve(item.urlString) else { return }
        guard let index = record.tabs.firstIndex(where: { $0.savedItemID == id }) else { openSavedItem(id); return }
        let tab = record.tabs[index]
        if pages[tab.id] == nil {
            // No live page state to transfer or discard; activate only the requested home.
            switches.removeValue(forKey: tab.id)
            if let pending = pendingPages.removeValue(forKey: tab.id) { app.engines.retire(pending) }
            record.tabs[index].urlString = item.urlString
            record.tabs[index].title = item.title
            record.tabs[index].favicon = item.favicon
            record.tabs[index].engineID = app.preferences.engine(for: url, override: tab.engineOverride)
            select(tab.id)
        } else {
            select(tab.id)
            addressDraft = item.urlString
            submitAddress()
        }
    }

    func canUseCurrentURLAsSavedDestination(_ id: UUID) -> Bool {
        guard !isClosed, !isPrivate,
              let item = app.savedItems.first(where: { $0.id == id && $0.profileID == record.profileID }),
              let tab = record.tabs.first(where: { $0.savedItemID == id }),
              let url = tab.url, AddressResolver.canonicalOrigin(url) != nil,
              case .navigate = AddressResolver.resolve(tab.urlString) else { return false }
        return tab.urlString != item.urlString
    }

    func useCurrentURLAsSavedDestination(_ id: UUID) {
        guard canUseCurrentURLAsSavedDestination(id),
              let tab = record.tabs.first(where: { $0.savedItemID == id }), let url = tab.url else { return }
        app.updateSavedDestination(id: id, profileID: record.profileID, url: url, favicon: tab.favicon)
    }

    func moveTab(_ id: UUID, to spaceID: UUID) {
        guard canChangeTemporaryTabs, selectedCloseOperation == nil, let i = record.tabs.firstIndex(where: { $0.id == id }),
              spaces.contains(where: { $0.id == spaceID }) else { return }
        if let itemID = record.tabs[i].savedItemID { app.moveSavedItem(id: itemID, spaceID: spaceID, folderID: nil) } else {
            if !isPrivate { app.rememberOrganization() }
            record.tabs[i].spaceID = spaceID
        }
        if record.selectedTabID == id { record.selectedSpaceID = spaceID }
        if selectedTemporaryTabIDs.contains(id) { clearTemporaryTabSelection() }
    }

    func moveSelectedTemporaryTabs(to spaceID: UUID) {
        let ids = selectedTemporaryTabIDs
        guard canChangeTemporaryTabs, selectedCloseOperation == nil,
              spaces.contains(where: { $0.id == spaceID }), !ids.isEmpty else { return }
        let targets = record.tabs.indices.filter { record.tabs[$0].savedItemID == nil && ids.contains(record.tabs[$0].id) }
        guard !targets.isEmpty else { clearTemporaryTabSelection(); return }
        if !isPrivate { app.rememberOrganization() }
        for index in targets { record.tabs[index].spaceID = spaceID }
        if record.selectedTabID.map(ids.contains) == true { record.selectedSpaceID = spaceID }
        clearTemporaryTabSelection()
    }

    func moveTab(_ id: UUID, offset: Int) {
        let siblings = record.tabs.indices.filter { record.tabs[$0].spaceID == record.selectedSpaceID && record.tabs[$0].savedItemID == nil }
        guard let position = siblings.firstIndex(where: { record.tabs[$0].id == id }), siblings.indices.contains(position + offset) else { return }
        let targetSiblingIndex = position + offset
        let beforeID: UUID?
        if offset > 0 {
            let nextIndex = targetSiblingIndex + 1
            beforeID = siblings.indices.contains(nextIndex) ? record.tabs[siblings[nextIndex]].id : nil
        } else {
            beforeID = record.tabs[siblings[targetSiblingIndex]].id
        }
        moveTab(id, before: beforeID)
    }

    func moveTab(_ id: UUID, before: UUID?, remember: Bool = true) {
        let siblings = record.tabs.indices.filter { record.tabs[$0].spaceID == record.selectedSpaceID && record.tabs[$0].savedItemID == nil }
        guard let position = siblings.firstIndex(where: { record.tabs[$0].id == id }) else { return }
        if before == id { return }
        if before == nil, position == siblings.count - 1 { return }
        if let before, position + 1 < siblings.count, record.tabs[siblings[position + 1]].id == before { return }
        if remember, !isPrivate { app.rememberOrganization() }
        let moved = record.tabs.remove(at: siblings[position])
        let remaining = record.tabs.indices.filter { record.tabs[$0].spaceID == record.selectedSpaceID && record.tabs[$0].savedItemID == nil }
        let insertAt: Int
        if let before, let index = remaining.first(where: { record.tabs[$0].id == before }) {
            insertAt = index
        } else if let last = remaining.last {
            insertAt = last + 1
        } else {
            insertAt = record.tabs.endIndex
        }
        record.tabs.insert(moved, at: min(insertAt, record.tabs.count))
    }

    func unpinSavedItem(_ id: UUID, before: UUID? = nil) {
        guard !isPrivate, let item = app.savedItems.first(where: { $0.id == id }) else { return }
        let tabID: UUID
        if let existing = record.tabs.first(where: { $0.savedItemID == id }) {
            tabID = existing.id
        } else {
            let tab = Tab(
                spaceID: record.selectedSpaceID,
                urlString: item.urlString,
                title: item.title,
                favicon: item.favicon,
                engineID: URL(string: item.urlString).map { app.preferences.engine(for: $0) } ?? app.preferences.defaultEngine
            )
            record.tabs.append(tab)
            tabID = tab.id
        }
        app.removeSavedItem(id)
        if let i = record.tabs.firstIndex(where: { $0.id == tabID }) {
            record.tabs[i].savedItemID = nil
            record.tabs[i].spaceID = record.selectedSpaceID
        }
        moveTab(tabID, before: before, remember: false)
    }

    // Cycle in the same order as sidebar rows, including saved destinations without live pages.
    var sidebarDestinations: [(id: UUID, saved: Bool)] {
        var destinations: [(id: UUID, saved: Bool)] = favorites.map { ($0.id, true) }
        destinations.append(contentsOf: pins.filter { $0.folderID == nil }.map { ($0.id, true) })
        for folder in folders {
            destinations.append(contentsOf: pins.filter { $0.folderID == folder.id }.map { ($0.id, true) })
        }
        destinations.append(contentsOf: visibleTabs.map { ($0.id, false) })
        return destinations
    }

    func cycleTab(offset: Int) {
        let available = sidebarDestinations
        guard !available.isEmpty else { return }
        let current = selectedTab?.savedItemID ?? record.selectedTabID
        let index = available.firstIndex { $0.id == current }
        let next = index.map { ($0 + offset % available.count + available.count) % available.count }
            ?? (offset < 0 ? available.count - 1 : 0)
        selectSidebarDestination(at: next)
    }

    func selectSidebarDestination(at index: Int) {
        let available = sidebarDestinations
        guard available.indices.contains(index) else { return }
        let destination = available[index]
        if destination.saved { openSavedItem(destination.id) } else { select(destination.id) }
        if let folder = selectedTab?.savedItemID.flatMap({ id in pins.first { $0.id == id }?.folderID }) {
            record.collapsedFolderIDs.removeAll { $0 == folder }
        }
    }

    func toggleRecentTab() {
        if let id = recentTabIDs.first(where: { candidate in candidate != record.selectedTabID && record.tabs.contains { $0.id == candidate } }) { select(id) }
    }

    func cycleRecentTab(backwards: Bool = false) {
        if recentCycleIDs.isEmpty {
            recentCycleIDs = recentTabIDs
            recentCycleIDs.append(contentsOf: record.tabs.map(\.id).filter { !recentCycleIDs.contains($0) })
        }
        recentCycleIDs.removeAll { id in !record.tabs.contains { $0.id == id } }
        guard !recentCycleIDs.isEmpty else { return }
        let index = recentCycleIDs.firstIndex { $0 == record.selectedTabID } ?? 0
        let next = (index + (backwards ? -1 : 1) + recentCycleIDs.count) % recentCycleIDs.count
        selectingRecentTab = true
        select(recentCycleIDs[next])
        selectingRecentTab = false
    }

    private func rememberRecentTab(_ id: UUID) {
        recentTabIDs.removeAll { $0 == id }
        recentTabIDs.insert(id, at: 0)
        recentTabIDs = Array(recentTabIDs.filter { candidate in record.tabs.contains { $0.id == candidate } }.prefix(50))
    }

    func endRecentTabCycle() {
        guard !recentCycleIDs.isEmpty else { return }
        recentCycleIDs = []
        if let id = record.selectedTabID { rememberRecentTab(id) }
    }

    func togglePinSelected() {
        guard !isPrivate, let tab = selectedTab else { return }
        if let saved = tab.savedItemID { app.removeSavedItem(saved) }
        else { pinTab(tab.id) }
    }

    func cycleSpace(offset: Int) {
        guard !spaces.isEmpty, let index = spaces.firstIndex(where: { $0.id == record.selectedSpaceID }) else { return }
        selectSpace(spaces[(index + offset % spaces.count + spaces.count) % spaces.count].id)
    }

    func selectSpace(at index: Int) -> Bool {
        guard spaces.indices.contains(index) else { return false }
        selectSpace(spaces[index].id)
        return true
    }

    func moveSelected(offset: Int) {
        guard let tab = selectedTab else { return }
        if let saved = tab.savedItemID { app.moveSavedItem(id: saved, offset: offset) }
        else { moveTab(tab.id, offset: offset) }
    }

    func toggleFolder(_ id: UUID) {
        if record.collapsedFolderIDs.contains(id) { record.collapsedFolderIDs.removeAll { $0 == id } } else { record.collapsedFolderIDs.append(id) }
    }

    func expandFolder(_ id: UUID) {
        record.collapsedFolderIDs.removeAll { $0 == id }
    }

    /// Writes a library bookmark. Sidebar pin/favorite is `pinTab`.
    func bookmarkSelected() {
        guard !isPrivate, let tab = selectedTab, URL(string: tab.urlString)?.isFileURL != true else { return }
        app.library.bookmark(urlString: tab.urlString, title: tab.title, profileID: record.profileID)
    }

    func acceptLocalFile(_ url: URL, replacing tabID: UUID? = nil) async throws {
        guard !app.isDeletingProfile(record.profileID) else { throw EngineError.notReady(String(localized: "This profile is being deleted.")) }
        guard url.isFileURL else { throw EngineError.notReady(String(localized: "Choose a local file.")) }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let targetID: UUID
        let provisional: Bool
        let previousSelection = record.selectedTabID
        if let tabID {
            guard record.selectedTabID == tabID, record.tabs.contains(where: { $0.id == tabID }) else { throw EngineError.closed }
            targetID = tabID
            provisional = false
        } else {
            let tab = Tab(spaceID: record.selectedSpaceID, engineID: app.preferences.defaultEngine)
            insertNewTemporaryTab(tab)
            targetID = tab.id
            provisional = true
            select(targetID)
        }
        guard let host = pages[targetID] else {
            if provisional { rollbackProvisionalLocalFileTab(targetID, previousSelection: previousSelection) }
            throw EngineError.notReady(String(localized: "The page is not ready to open a local file."))
        }
        do { try await host.openLocalFile(url) }
        catch {
            if provisional { rollbackProvisionalLocalFileTab(targetID, previousSelection: previousSelection) }
            throw error
        }
        guard !isClosed, !app.isDeletingProfile(record.profileID), pages[targetID] === host,
              let index = record.tabs.firstIndex(where: { $0.id == targetID }) else {
            preserveCommittedLocalFileBookmark(bookmark, url: url, tabID: targetID)
            if provisional { rollbackProvisionalLocalFileTab(targetID, previousSelection: previousSelection) }
            throw EngineError.closed
        }
        record.tabs[index].urlString = url.absoluteString
        record.tabs[index].title = url.lastPathComponent
        if isPrivate { privateLocalFileBookmarks[targetID] = bookmark }
        else { record.tabs[index].localFileBookmark = bookmark }
    }

    private func preserveCommittedLocalFileBookmark(_ bookmark: Data, url: URL, tabID: UUID) {
        guard !isClosed, let index = record.tabs.firstIndex(where: { $0.id == tabID }),
              URL(string: record.tabs[index].urlString)?.standardizedFileURL == url.standardizedFileURL else { return }
        if app.isDeletingProfile(record.profileID) {
            record.tabs[index].localFileBookmark = nil
            privateLocalFileBookmarks.removeValue(forKey: tabID)
            return
        }
        if isPrivate { privateLocalFileBookmarks[tabID] = bookmark }
        else { record.tabs[index].localFileBookmark = bookmark }
    }

    private func rollbackProvisionalLocalFileTab(_ id: UUID, previousSelection: UUID?) {
        let wasSelected = record.selectedTabID == id
        record.tabs.removeAll { $0.id == id }
        selectedTemporaryTabIDs.remove(id)
        if temporaryTabSelectionAnchorID == id { temporaryTabSelectionAnchorID = nil }
        retireHost(id)
        guard wasSelected else { return }
        if let previousSelection, record.tabs.contains(where: { $0.id == previousSelection }) { select(previousSelection) }
        else { clearSelection() }
    }

    func sharePage(from anchor: NSView? = nil, url: URL? = nil) {
        guard !isClosed, let url = url ?? selectedTab?.url, AddressResolver.canonicalOrigin(url) != nil,
              let view = anchor ?? nativeWindow?.contentView ?? selectedPage?.nativeView.window?.contentView,
              view.window != nil else {
            addressError = String(localized: "Open a visible web page before sharing its address.")
            return
        }
        addressError = nil
        sharingPicker?.close()
        let picker = NSSharingServicePicker(items: [url])
        sharingPicker = picker
        if anchor != nil {
            // The native site button calls this path on mouseDown while its anchor is visible.
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        } else {
            // Native menu and shortcut actions use the menu API; show(relativeTo:) requires mouseDown.
            let item = picker.standardShareMenuItem
            let menu = item.submenu ?? NSMenu()
            if item.submenu == nil { menu.addItem(item) }
            menu.popUp(positioning: nil,
                at: NSPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - 1), in: view)
        }
    }

    func copyPageURL(urlString: String? = nil) {
        guard let text = urlString ?? selectedTab?.urlString, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var pageConnection: PageConnection {
        let url = selectedTab?.urlString ?? selectedPage?.state.urlString ?? ""
        guard let state = selectedPage?.state else { return .classify(urlString: url) }
        guard state.urlString == url else { return .classify(urlString: url) }
        return state.connection == .unknown ? .classify(urlString: url) : state.connection
    }

    var supportsPopupPolicy: Bool {
        selectedPageCapabilities.supportsPopupPolicy
    }

    var selectedPageCapabilities: EngineCapabilities {
        if let host = selectedPage { return host.capabilities }
        guard let engineID = selectedTab?.engineID else { return EngineCapabilities() }
        return app.engines.engine(app.engines.effectiveID(engineID))?.capabilities ?? EngineCapabilities()
    }

    func setSitePermission(_ kind: PermissionKind, _ value: SitePermission) {
        guard !isClosed, !isPrivate, selectedPageCapabilities.permissions.contains(kind),
              let url = selectedTab?.url else { return }
        guard app.siteSettings.update(origin: url.absoluteString, profileID: record.profileID,
            camera: kind == .camera ? value : nil, microphone: kind == .microphone ? value : nil,
            engines: app.engines.engines), value == .deny else { return }
        // ponytail: Capture state has no frame origin; stop this device across the profile until engines expose it.
        for window in app.windows where !window.isClosed && !window.isPrivate && window.record.profileID == record.profileID {
            for host in Array(window.pages.values) where host.state.grantedMediaKinds.contains(kind)
                || (kind == .camera ? host.state.camera : host.state.microphone) != .none {
                if host.capabilities.captureControls.contains(.stop(kind)) { host.setCapture(kind, .none) }
                else if !host.capabilities.captureControls.contains(.stopAllUserMedia) || !host.stopMediaCapture() {
                    window.retireHost(host.tabID, leavingUnloaded: true)
                    window.addressError = String(localized: "A page was unloaded because camera or microphone capture could not be stopped safely. Unsaved page content may be lost.")
                }
            }
        }
    }

    func setPopups(_ value: SitePermission) {
        guard !isClosed, !isPrivate, supportsPopupPolicy, let url = selectedTab?.url else { return }
        var setting = app.siteSettings.setting(origin: url, profileID: record.profileID,
            engineID: selectedPage?.contextID.engineID ?? app.engines.effectiveID(selectedTab?.engineID ?? app.preferences.defaultEngine))
        setting.popups = value
        app.siteSettings.update(setting)
        selectedPage?.applySiteSettings()
    }

    func discardSelected() {
        guard let id = record.selectedTabID else { return }
        retireHost(id, leavingUnloaded: true)
    }

    func applyContentRules() { pages.values.forEach { $0.applyContentRules() } }
    func applyInspectorPreference() { pages.values.forEach { $0.setInspectable(app.preferences.webInspectorEnabled) } }
    func unloadPages(in contexts: Set<BrowsingContextID>) {
        let ids = Set((Array(pages.values) + Array(pendingPages.values)).filter { contexts.contains($0.contextID) }.map(\.tabID))
        for id in ids { retireHost(id, leavingUnloaded: true) }
    }
    func unloadPages() {
        generations.removeAll()
        cancelAllPagePrompts()
        switches.removeAll()
        loads.removeAll()
        pages.values.forEach { app.engines.retire($0) }
        pages.removeAll()
        historyVisits.removeAll()
        pendingPages.values.forEach { app.engines.retire($0) }
        pendingPages.removeAll()
    }

    func closePages() {
        isClosed = true
        cancelAllPagePrompts()
        pageFileOperations.cancelAll()
        privateLocalFileBookmarks.removeAll()
        sharingPicker?.close()
        sharingPicker = nil
        preservingTabsForTermination = false
        closePagesPreflightComplete = false
        unloadPages()
        closedTabs.removeAll()
        if isPrivate { app.engines.releasePrivateWindow(id) }
    }

    func repairSelection() {
        for i in record.tabs.indices {
            if let savedID = record.tabs[i].savedItemID {
                if let item = app.savedItems.first(where: { $0.id == savedID }) {
                    if let spaceID = item.spaceID { record.tabs[i].spaceID = spaceID }
                } else { record.tabs[i].savedItemID = nil }
            }
            if !spaces.contains(where: { $0.id == record.tabs[i].spaceID }) { record.tabs[i].spaceID = spaces[0].id }
        }
        if let tab = selectedTab {
            let favorite = tab.savedItemID.flatMap { id in app.savedItems.first { $0.id == id } }.map { $0.spaceID == nil } ?? false
            if !favorite { record.selectedSpaceID = tab.spaceID }
        }
        if !spaces.contains(where: { $0.id == record.selectedSpaceID }) { record.selectedSpaceID = spaces[0].id }
    }

    private func confirmExternalURL(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open an external application?")
        alert.informativeText = String(format: String(localized: "This link uses the %@ protocol."), url.scheme ?? String(localized: "external"))
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { openExternalURL(url) }
    }

    private func openExternalURL(_ url: URL) {
        if let application = NSWorkspace.shared.urlForApplication(toOpen: url),
           Bundle(url: application)?.bundleIdentifier == Bundle.main.bundleIdentifier {
            addressError = String(localized: "Cobble cannot open a link that routes back to Cobble.")
            return
        }
        if !NSWorkspace.shared.open(url) {
            addressError = String(localized: "No application could open this link.")
        }
    }
}
