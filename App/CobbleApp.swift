import AppKit
import SwiftUI
import WebKit
#if COBBLE_CHROMIUM_CLIENT
import CobbleChromium
#endif

#if !COBBLE_CHROMIUM_CLIENT
@main
#endif
@MainActor
final class CobbleApp: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate, NSToolbarDelegate {
    private var workspaceLock: WorkspaceLock?
    private static var dataDirectory: URL {
        ProcessInfo.processInfo.environment["COBBLE_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cobble", isDirectory: true)
    }

    private func acquireWorkspace() -> Bool {
        guard !testing else { return true }
        do {
            workspaceLock = try WorkspaceLock(directory: Self.dataDirectory)
            return true
        } catch {
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ignacio.cobble")
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            existing?.activate()
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t open Cobble")
            alert.informativeText = String(localized: "Quit any other Cobble instance before opening this build.") + "\n" + error.localizedDescription
            alert.runModal()
            return false
        }
    }

    private var additionalEngines: [any BrowserEngine] = []
    private lazy var model: AppModel = {
        let store = SessionStore(directory: Self.dataDirectory)
        let isolated = ProcessInfo.processInfo.environment["COBBLE_DATA_DIRECTORY"] != nil
        var dataStore: WKWebsiteDataStore? = isolated ? .nonPersistent() : nil
        #if DEBUG && COBBLE_AUTH_FIXTURE
        dataStore = LoginSharingFixture.dataStore() ?? dataStore
        #endif
        let engine = WebKitEngine(directory: store.directory, dataStoreOverride: dataStore)
        return AppModel(store: store, engines: EngineRegistry([engine] + additionalEngines))
    }()
    private var controllers: [UUID: BrowserWindowController] = [:]
    private var devToolsControllers: [UUID: DevToolsWindowController] = [:]
    #if DEBUG
    @objc private func showResources() { model.resources.show() }
    #endif
    private var settingsWindow: NSWindow?
    private var terminating = false
    private var launched = false
    private var replacingWindows = false
    private var testing: Bool { ProcessInfo.processInfo.environment["COBBLE_TESTING"] == "1" }
    private var spacesMenu: NSMenu?
    private var historyMenu: NSMenu?
    private var recentlyClosedMenu: NSMenu?
    private var spaceJumpItems: [NSMenuItem] = []
    private var extraSpaceItems: [NSMenuItem] = []
    private var historyURLItems: [NSMenuItem] = []

    convenience init(model: AppModel) {
        self.init()
        self.model = model
    }

    #if COBBLE_CHROMIUM_CLIENT
    private static var chromiumClient: CobbleApp?
    private var chromiumRuntime: ChromiumRuntime?

    static func startChromiumClient(handle: UnsafeMutableRawPointer?) -> Int32 {
        guard chromiumClient == nil else { return -1 }
        let client = CobbleApp()
        // A nonzero result makes the launcher abort() with a crash report; the
        // user has already been told why, so leave quietly instead.
        guard client.acquireWorkspace() else { exit(EXIT_FAILURE) }
        do {
            let runtime = try ChromiumRuntime(launcherFrameworkHandle: handle)
            client.chromiumRuntime = runtime
            runtime.onReady = { [weak client] in
                guard let client else { return }
                client.additionalEngines = [ChromiumEngine(runtime: runtime,
                    directory: Self.dataDirectory)]
                client.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            }
            runtime.onReopen = { [weak client] in _ = client?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) }
            runtime.onOpenURLs = { [weak client] urls in client?.application(NSApp, open: urls) }
            runtime.onQuitRequested = { [weak client] _ in client?.quitChromiumClient() }
            runtime.hostWindow = { [weak client] windowID, _ in
                client?.controllers[windowID]?.window ?? client?.devToolsControllers[windowID]?.window
            }
            try runtime.registerClient()
            chromiumClient = client
            return 0
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t open Cobble")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }

    private func quitChromiumClient() {
        guard !terminating, let runtime = chromiumRuntime else { return }
        guard confirmQuitDespiteDownloads() else { runtime.cancelQuit(); return }
        terminating = true
        Task {
            if await prepareToQuit() { runtime.requestQuit() } else { runtime.cancelQuit() }
        }
    }
    #endif

    static func main() {
        let application = NSApplication.shared
        let delegate = CobbleApp()
        guard delegate.acquireWorkspace() else { return }
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !testing else { return }
        if ProcessInfo.processInfo.environment["COBBLE_DATA_DIRECTORY"] == nil { model.sync.start() }
        model.updates.start()
        model.startTabSleeping()
        CobbleScriptTabs.app = model
        buildMenus()
        model.preferences.onChange = { [weak self] in self?.buildMenus(); self?.model.updateTabSleepTimer() }
        model.onOpenWindow = { [weak self] in self?.show($0) }
        model.onActivateWindow = { [weak self] windowModel in
            self?.controllers[windowModel.id]?.showWindow(nil)
            self?.controllers[windowModel.id]?.window?.makeKeyAndOrderFront(nil)
        }
        model.onCloseWindows = { [weak self] ids in
            guard let self else { return }
            self.replacingWindows = true
            for id in ids {
                self.controllers[id]?.close()
                self.controllers.removeValue(forKey: id)
            }
            self.replacingWindows = false
        }
        model.onReplaceWindows = { [weak self] in
            guard let self else { return }
            self.replacingWindows = true
            Array(self.controllers.values).forEach { $0.close() }
            self.controllers.removeAll()
            self.replacingWindows = false
            if self.model.windows.isEmpty { self.model.newWindow() }
            else { self.model.windows.forEach(self.show) }
        }
        if model.windows.isEmpty { model.newWindow() }
        else { model.windows.forEach(show) }
        launched = true
        #if COBBLE_CHROMIUM_CLIENT
        // Chromium's launcher may have already installed its own dock icon.
        NSApp.applicationIconImage = nil
        replaceChromiumDockMenu()
        #endif
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG && COBBLE_AUTH_FIXTURE
        LoginSharingFixture.start(model)
        #endif
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !testing else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        guard confirmQuitDespiteDownloads() else { return .terminateCancel }
        terminating = true
        Task { [weak self] in
            sender.reply(toApplicationShouldTerminate: await self?.prepareToQuit() ?? false)
        }
        return .terminateLater
    }
    /// Shared by AppKit and Chromium-client quits. False means the quit was cancelled and browsing resumes.
    private func prepareToQuit() async -> Bool {
        model.sync.stop()
        guard await model.requestTerminationPreflight() else {
            model.sync.start()
            terminating = false
            return false
        }
        controllers.values.forEach { $0.recordFrame() }
        guard await model.flushAndWait() == nil else {
            model.windows.forEach { $0.cancelClosePages() }
            model.sync.start()
            terminating = false
            return false
        }
        closeAllDevTools()
        model.windows.forEach { $0.closePages() }
        await model.downloads.cancelAll()
        await model.engines.shutdown()
        return true
    }
    private func confirmQuitDespiteDownloads() -> Bool {
        guard let warning = DownloadStore.quitWarning(activeCount: model.downloads.activeCount) else { return true }
        let alert = NSAlert()
        alert.messageText = warning.title
        alert.informativeText = warning.message
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Clicking the Dock icon never adds a window while one exists, even minimized,
    /// hidden, or still restoring at launch. Only an explicit New Window does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if launched && !terminating { showExistingWindow() }
        return false
    }
    func showExistingWindow() {
        let windows = model.windows.filter { !$0.isPrivate } + model.windows.filter(\.isPrivate)
        guard let first = windows.first else { model.newWindow(); return }
        let onScreen = windows.contains { controllers[$0.id]?.window.map { $0.isVisible && !$0.isMiniaturized } == true }
        if !onScreen { showExisting(first) }
    }
    private func showExisting(_ window: BrowserWindowModel) {
        guard let native = controllers[window.id]?.window else { return }
        if native.isMiniaturized { native.deminiaturize(nil) }
        native.makeKeyAndOrderFront(nil)
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for command in [BrowserCommand.newWindow, .newPrivateWindow] {
            let item = NSMenuItem(title: command.title, action: #selector(performDockCommand(_:)), keyEquivalent: "")
            item.target = self; item.tag = command.rawValue + 1
            menu.addItem(item)
        }
        return menu
    }
    @objc private func performDockCommand(_ sender: NSMenuItem) {
        NSApp.activate()
        performBrowserCommand(sender)
    }
    #if COBBLE_CHROMIUM_CLIENT
    /// Chromium's AppController is NSApp's delegate; its Dock items open hidden Chromium browsers.
    private func replaceChromiumDockMenu() {
        guard let delegate = NSApp.delegate, let type = object_getClass(delegate) else { return }
        let dockMenu: @MainActor @convention(block) (AnyObject, NSApplication) -> NSMenu? = { [weak self] _, sender in
            self?.applicationDockMenu(sender)
        }
        class_replaceMethod(type, #selector(applicationDockMenu(_:)), imp_implementationWithBlock(dockMenu), "@@:@")
    }
    #endif
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !testing else { return }
        handleIncomingURLs(urls)
    }

    func handleIncomingURLs(_ urls: [URL]) {
        guard !terminating else { return }
        for url in urls {
            switch DefaultBrowser.incoming(url) {
            case .web(let web):
                if let window = incomingNormalWindow() {
                    window.addTab(url: web)
                    controllers[window.id]?.showWindow(nil)
                } else {
                    model.newWindow(url: web)
                }
            case .localHTML(let file):
                let window = incomingNormalWindow() ?? model.newWindow()
                controllers[window.id]?.showWindow(nil)
                Task { @MainActor [weak self] in
                    guard let self, !self.terminating, !window.isClosed else { return }
                    do { try await window.acceptLocalFile(file) }
                    catch where !window.isClosed {
                        window.addressError = String(format: String(localized: "Could not open the local file: %@"), error.localizedDescription)
                    }
                    catch {}
                }
            case nil:
                continue
            }
        }
    }

    private func incomingNormalWindow() -> BrowserWindowModel? {
        activeWindow.flatMap { $0.isPrivate ? nil : $0 } ?? model.windows.first { !$0.isPrivate }
    }
    private var activeWindow: BrowserWindowModel? {
        controllers.values.first { $0.window === NSApp.keyWindow && $0.window?.attachedSheet == nil }?.model
    }
    func show(_ windowModel: BrowserWindowModel) {
        windowModel.onCommand = { [weak self, weak windowModel] command in
            guard let self, let windowModel, self.activeWindow === windowModel else { return false }
            return self.dispatch(command)
        }
        windowModel.onKeyEvent = { [weak self, weak windowModel] event in
            guard let self, let windowModel, self.activeWindow === windowModel,
                  let key = event.charactersIgnoringModifiers else { return false }
            let shortcut = BrowserShortcut(key, event.modifierFlags)
            guard let command = BrowserCommand.allCases.first(where: { self.model.preferences.shortcut(for: $0) == shortcut }) else { return false }
            return self.dispatch(command)
        }
        windowModel.onOpenDevTools = { [weak self] page in self?.showDevTools(for: page) ?? false }
        let controller = BrowserWindowController(model: windowModel) { [weak self] id in
            guard let self, !self.terminating, !self.replacingWindows else { return }
            self.model.closeWindow(id)
            self.controllers.removeValue(forKey: id)
        }
        controllers[windowModel.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func showDevTools(for page: any BrowserPage) -> Bool {
        let pageID = ObjectIdentifier(page)
        if let existing = devToolsControllers.values.first(where: { $0.pageID == pageID }) {
            guard !existing.isClosed else { return false }
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.focus()
            return true
        }

        let hostWindowID = UUID()
        let controller = DevToolsWindowController(hostWindowID: hostWindowID, page: page,
            pageTitle: page.state.title) { [weak self] id in self?.devToolsControllers.removeValue(forKey: id) }
        // Chromium resolves the NSWindow synchronously while opening the session.
        devToolsControllers[hostWindowID] = controller
        do {
            try controller.attach(page.openDevTools(hostWindowID: hostWindowID))
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.focus()
            return true
        } catch {
            devToolsControllers.removeValue(forKey: hostWindowID)
            controller.closeWithoutSession()
            page.state.errorMessage = error.localizedDescription
            return false
        }
    }

    private func closeAllDevTools() {
        Array(devToolsControllers.values).forEach { $0.closeSession() }
    }
    func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let title = NSLocalizedString(title, comment: "Native menu")
            let item = NSMenuItem(); item.title = title
            let submenu = NSMenu(title: title); item.submenu = submenu; main.addItem(item)
            return submenu
        }
        func item(_ command: BrowserCommand, in menu: NSMenu) {
            let item = NSMenuItem(title: command.title, action: #selector(performBrowserCommand(_:)), keyEquivalent: "")
            item.toolTip = command.explanation
            let shortcut = model.preferences.shortcut(for: command)
            item.keyEquivalent = shortcut.key
            item.target = self; item.tag = command.rawValue + 1; item.keyEquivalentModifierMask = shortcut.flags; menu.addItem(item)
        }
        func native(_ title: String, _ selector: Selector, _ key: String, in menu: NSMenu) {
            menu.addItem(NSMenuItem(title: NSLocalizedString(title, comment: "Native menu"), action: selector, keyEquivalent: key))
        }
        let application = menu("Cobble")
        native("About Cobble", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", in: application)
        let updateItem = NSMenuItem(title: String(localized: "Check for Updates…"),
            action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        application.addItem(updateItem)
        item(.settings, in: application)
        #if DEBUG
        let resourcesItem = NSMenuItem(title: "Resources…", action: #selector(showResources), keyEquivalent: "")
        resourcesItem.target = self
        application.addItem(resourcesItem)
        #endif
        application.addItem(.separator())
        native("Hide Cobble", #selector(NSApplication.hide(_:)), "h", in: application)
        native("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", in: application)
        application.addItem(.separator())
        native("Quit Cobble", #selector(NSApplication.terminate(_:)), "q", in: application)
        let file = menu("File")
        item(.newWindow, in: file)
        item(.newPrivateWindow, in: file)
        item(.newTab, in: file)
        item(.openFile, in: file)
        item(.reopen, in: file)
        file.addItem(.separator())
        item(.closeTab, in: file)
        item(.closeWindow, in: file)
        item(.printPage, in: file)
        item(.savePage, in: file)
        let edit = menu("Edit")
        native("Undo", Selector(("undo:")), "z", in: edit)
        let redo = NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; edit.addItem(redo)
        item(.undoWorkspace, in: edit)
        edit.addItem(.separator())
        native("Cut", #selector(NSText.cut(_:)), "x", in: edit)
        native("Copy", #selector(NSText.copy(_:)), "c", in: edit)
        native("Paste", #selector(NSText.paste(_:)), "v", in: edit)
        native("Select All", #selector(NSText.selectAll(_:)), "a", in: edit)
        item(.find, in: edit)
        item(.findNext, in: edit)
        item(.findPrevious, in: edit)
        let view = menu("View")
        item(.sidebar, in: view)
        item(.reload, in: view)
        item(.reloadFromOrigin, in: view)
        item(.screenshot, in: view)
        item(.viewPageDOM, in: view)
        item(.openDevTools, in: view)
        item(.stop, in: view)
        item(.zoomIn, in: view)
        item(.zoomOut, in: view)
        item(.zoomReset, in: view)
        native("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "", in: view)
        let navigate = menu("Navigate")
        item(.address, in: navigate)
        item(.copyURL, in: navigate)
        item(.sharePage, in: navigate)
        item(.back, in: navigate)
        item(.forward, in: navigate)
        let spaces = menu("Spaces")
        spaces.delegate = self
        spacesMenu = spaces
        item(.newSpace, in: spaces)
        item(.renameSpace, in: spaces)
        item(.deleteSpace, in: spaces)
        spaces.addItem(.separator())
        item(.nextSpace, in: spaces)
        item(.previousSpace, in: spaces)
        spaces.addItem(.separator())
        extraSpaceItems = []
        spaceJumpItems = (0..<9).map { index in
            let row = NSMenuItem(title: String(format: String(localized: "Space %@"), "\(index + 1)"), action: #selector(selectSpaceAtIndex(_:)), keyEquivalent: "\(index + 1)")
            row.target = self
            row.tag = index
            spaces.addItem(row)
            return row
        }
        let tabs = menu("Tabs")
        item(.pinTab, in: tabs)
        item(.favoriteTab, in: tabs)
        item(.bookmark, in: tabs)
        item(.duplicateTab, in: tabs)
        item(.detachTab, in: tabs)
        item(.closeOtherTabs, in: tabs)
        item(.closeTabsAbove, in: tabs)
        item(.closeTabsBelow, in: tabs)
        item(.newFolder, in: tabs)
        item(.rename, in: tabs)
        item(.unload, in: tabs)
        item(.resetSavedURL, in: tabs)
        item(.saveCurrentURL, in: tabs)
        item(.muteTab, in: tabs)
        tabs.addItem(.separator())
        item(.nextTab, in: tabs)
        item(.previousTab, in: tabs)
        item(.moveUp, in: tabs)
        item(.moveDown, in: tabs)
        item(.revealTab, in: tabs)
        tabs.addItem(.separator())
        for command in BrowserCommand.allCases where command.tabIndex != nil { item(command, in: tabs) }
        let history = menu("History")
        history.delegate = self
        historyMenu = history
        historyURLItems = []
        item(.history, in: history)
        item(.clearHistory, in: history)
        history.addItem(.separator())
        let closed = NSMenuItem(title: String(localized: "Recently Closed Tabs"), action: nil, keyEquivalent: "")
        let closedMenu = NSMenu(title: String(localized: "Recently Closed Tabs"))
        closed.submenu = closedMenu
        recentlyClosedMenu = closedMenu
        history.addItem(closed)
        history.addItem(.separator())
        refreshSpaceTitles(spaces)
        refreshHistoryMenu(history)
        let windows = menu("Window")
        item(.recentTab, in: windows)
        item(.previousRecentTab, in: windows)
        native("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", in: windows)
        native("Zoom", #selector(NSWindow.performZoom(_:)), "", in: windows)
        native("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", in: windows)
        NSApp.windowsMenu = windows
        #if COBBLE_CHROMIUM_CLIENT
        // Chromium's AppController installs a BookmarkMenuBridge when a browser window becomes main.
        let chromiumBookmarks = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        chromiumBookmarks.tag = 57333 // kBookmarksMenuId
        chromiumBookmarks.submenu = NSMenu()
        chromiumBookmarks.isHidden = true
        main.addItem(chromiumBookmarks)
        #endif
        NSApp.mainMenu = main
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === spacesMenu { refreshSpaceTitles(menu) }
        // AppKit also populates menus while matching ⌘ shortcuts; dynamic history rows have none.
        // Keyboard menu navigation (no ⌘) still refreshes.
        else if menu === historyMenu, !Self.isCommandKeyDown(NSApp.currentEvent) { refreshHistoryMenu(menu) }
    }
    private func refreshSpaceTitles(_ menu: NSMenu) {
        let spaces = activeWindow?.spaces ?? []
        let selected = activeWindow?.record.selectedSpaceID
        for index in spaceJumpItems.indices {
            if index < spaces.count {
                spaceJumpItems[index].title = spaces[index].labeledName
                spaceJumpItems[index].state = spaces[index].id == selected ? .on : .off
                spaceJumpItems[index].isHidden = false
            } else {
                spaceJumpItems[index].title = String(format: String(localized: "Space %@"), "\(index + 1)")
                spaceJumpItems[index].state = .off
                spaceJumpItems[index].isHidden = true
            }
        }
        extraSpaceItems.forEach(menu.removeItem)
        extraSpaceItems = spaces.enumerated().dropFirst(9).map { index, space in
            let row = NSMenuItem(title: space.labeledName, action: #selector(selectSpaceAtIndex(_:)), keyEquivalent: "")
            row.target = self
            row.tag = index
            row.state = space.id == selected ? .on : .off
            menu.addItem(row)
            return row
        }
    }
    private static func isCommandKeyDown(_ event: NSEvent?) -> Bool {
        event?.type == .keyDown && event?.modifierFlags.contains(.command) == true
    }
    private func refreshHistoryMenu(_ menu: NSMenu) {
        let closed = recentlyClosedMenu ?? NSMenu(title: String(localized: "Recently Closed Tabs"))
        closed.removeAllItems()
        recentlyClosedMenu = closed
        let tabs = activeWindow?.closedTabs ?? []
        if tabs.isEmpty {
            let empty = NSMenuItem(title: String(localized: "None"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            closed.addItem(empty)
        } else {
            for tab in tabs.reversed() {
                let row = NSMenuItem(title: tab.displayedTitle.isEmpty ? tab.urlString : tab.displayedTitle,
                                     action: #selector(reopenListedClosedTab(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = tab.id
                row.image = menuImage(tab.favicon?.png)
                closed.addItem(row)
            }
        }
        historyURLItems.forEach(menu.removeItem)
        historyURLItems = []
        guard let window = activeWindow, !window.isPrivate else { return }
        historyURLItems = model.library.search("", profileID: window.record.profileID, historyOnly: true, limit: 15).map { entry in
            let row = NSMenuItem(title: entry.title.isEmpty ? entry.urlString : entry.title,
                                 action: #selector(openHistoryURL(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = entry.urlString
            row.toolTip = entry.urlString
            row.image = menuImage(model.cachedFavicon(urlString: entry.urlString, profileID: window.record.profileID)?.png)
            menu.addItem(row)
            return row
        }
    }
    private func menuImage(_ png: Data?) -> NSImage? {
        guard let png, let image = NSImage(data: png) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
    @objc private func selectSpaceAtIndex(_ sender: NSMenuItem) {
        _ = activeWindow?.selectSpace(at: sender.tag)
    }
    @objc private func reopenListedClosedTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        activeWindow?.reopenClosedTab(id: id)
    }
    @objc private func openHistoryURL(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let url = URL(string: value) else { return }
        activeWindow?.addTab(url: url)
    }
    @objc private func performBrowserCommand(_ sender: NSMenuItem) {
        guard let command = BrowserCommand(rawValue: sender.tag - 1) else { return }
        _ = dispatch(command)
    }
    @discardableResult private func dispatch(_ command: BrowserCommand) -> Bool {
        guard !terminating else { return false }
        if command == .closeTab || command == .closeWindow {
            guard NSApp.keyWindow?.sheetParent == nil, NSApp.keyWindow?.attachedSheet == nil else { return false }
        }
        if command == .newTab || command == .newWindow || command == .newPrivateWindow,
           NSApp.keyWindow?.attachedSheet != nil || NSApp.keyWindow?.sheetParent != nil {
            let owner = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
            if let window = controllers.values.first(where: { $0.window === owner })?.model,
               window.perform(command) { return true }
            return false
        }
        if command == .clearHistory { return confirmClearHistory() }
        if let activeWindow, activeWindow.perform(command) { return true }
        switch command {
        case .settings: showSettings()
        case .history: showSettings(section: .history)
        case .newWindow: model.newWindow(profileID: activeWindow?.record.profileID ?? Profile.defaultID)
        case .newPrivateWindow: model.newWindow(isPrivate: true, profileID: activeWindow?.record.profileID ?? Profile.defaultID)
        case .newTab:
            // ⌘T from Settings or DevTools reuses the browser window instead of adding one.
            if activeWindow == nil, let window = incomingNormalWindow(), window.canPerform(.newTab) {
                showExisting(window)
                window.openCommandBar()
            } else { model.newWindow(profileID: activeWindow?.record.profileID ?? Profile.defaultID)?.openCommandBar() }
        case .closeWindow: NSApp.keyWindow?.performClose(nil)
        case .closeTab where activeWindow == nil: NSApp.keyWindow?.performClose(nil)
        default: return false
        }
        return true
    }
    private func confirmClearHistory() -> Bool {
        guard let window = activeWindow, !window.isPrivate else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear all browsing history?")
        alert.informativeText = String(localized: "Bookmarks, saved tabs, and website data are preserved.")
        alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return true }
        model.library.clearHistory(profileID: window.record.profileID)
        return true
    }
    @objc private func checkForUpdates() { model.updates.checkForUpdates() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return model.updates.canCheck }
        if menuItem.action == #selector(selectSpaceAtIndex(_:)) {
            return activeWindow?.spaces.indices.contains(menuItem.tag) == true
        }
        if menuItem.action == #selector(reopenListedClosedTab(_:)) || menuItem.action == #selector(openHistoryURL(_:)) {
            return activeWindow != nil
        }
        guard let command = BrowserCommand(rawValue: menuItem.tag - 1) else { return true }
        if command == .muteTab {
            menuItem.title = activeWindow?.selectedPage?.state.isAudioMuted == true ? String(localized: "Unmute Tab") : String(localized: "Mute Tab")
        }
        switch command {
        case .settings, .history, .newWindow, .newPrivateWindow, .newTab: return true
        case .closeTab where activeWindow == nil, .closeWindow:
            return NSApp.keyWindow != nil && NSApp.keyWindow?.attachedSheet == nil && NSApp.keyWindow?.sheetParent == nil
        default: return activeWindow?.canPerform(command) == true
        }
    }
    private func showSettings(section: SettingsSection = .general) {
        let extensionActionPage = activeWindow?.selectedPage
        model.settingsSection = section
        if settingsWindow == nil {
            let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            let toolbar = NSToolbar(identifier: "settings")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            toolbar.sizeMode = .regular
            toolbar.allowsUserCustomization = false
            window.title = String(localized: "Cobble Settings")
            window.titleVisibility = .hidden
            window.toolbarStyle = .preference
            window.toolbar = toolbar
            window.minSize = NSSize(width: 760, height: 540)
            window.isReleasedWhenClosed = false
            window.center(); settingsWindow = window
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(app: model, extensionActionPage: extensionActionPage))
        let destination = section.toolbarSection
        settingsWindow?.toolbar?.selectedItemIdentifier = toolbarIdentifier(for: destination)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func toolbarIdentifier(for section: SettingsSection) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("settings.\(section.rawValue)")
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + SettingsSection.toolbarSections.map(toolbarIdentifier) + [.flexibleSpace]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space] + SettingsSection.toolbarSections.map(toolbarIdentifier)
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.toolbarSections.map(toolbarIdentifier)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = SettingsSection.toolbarSections.first(where: { toolbarIdentifier(for: $0) == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = section.title
        item.paletteLabel = section.title
        item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
        item.target = self
        item.action = #selector(selectSettingsSection(_:))
        item.tag = section.rawValue
        return item
    }
    @objc private func selectSettingsSection(_ sender: NSToolbarItem) {
        if let section = SettingsSection(rawValue: sender.tag) { model.settingsSection = section }
        settingsWindow?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
    }
}

/// Preference windows stay key-only. Chromium's AppController CHECKs in
/// BookmarkMenuBridge when a second window becomes main (settings close).
final class SettingsWindow: NSWindow {
    override var canBecomeMain: Bool { false }
}

#if COBBLE_CHROMIUM_CLIENT
@_cdecl("CCSClientMain")
public func CCSClientMain(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    let bits = handle.map { UInt(bitPattern: $0) } ?? 0
    return MainActor.assumeIsolated {
        CobbleApp.startChromiumClient(handle: bits == 0 ? nil : UnsafeMutableRawPointer(bitPattern: bits))
    }
}
#endif

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserWindowModel
    private let onClose: (UUID) -> Void
    private var allowingClose = false
    private var requestingClose = false
    private var eventMonitor: Any?
    /// Keys whose press keyboard privacy hid from the page; their release stays hidden too.
    private var hiddenKeyCodes: Set<UInt16> = []
    /// Keys the page saw pressed and not yet released.
    private var pressedKeys: [UInt16: NSEvent] = [:]
    init(model: BrowserWindowModel, onClose: @escaping (UUID) -> Void) {
        self.model = model; self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 800, height: 500)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        model.nativeWindow = window
        trackWindowTitle()
        window.delegate = self
        window.contentView = NSHostingView(rootView: BrowserView(window: model))
        // Keep AppKit's initial key-view selection out of the address field.
        window.initialFirstResponder = window.contentView
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.monitoredEvents) { [weak self] event in
            // Monitors run on the main thread; NSEvent itself is not Sendable.
            nonisolated(unsafe) var routed: NSEvent? = event
            MainActor.assumeIsolated { if let self { routed = self.route(event) } }
            return routed
        }
        if let saved = model.record.frame,
           let frame = Self.restoredFrame(saved, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(frame, display: false)
        } else { window.center() }
    }

    /// Reassigning an unchanged title still posts accessibility notifications, so compare first.
    private func trackWindowTitle() {
        let title = withObservationTracking { model.windowTitle } onChange: { [weak self] in
            Task { @MainActor in self?.trackWindowTitle() }
        }
        if window?.title != title { window?.title = title }
    }

    static func restoredFrame(_ saved: WindowFrame, visibleFrames: [NSRect]) -> NSRect? {
        guard let primary = visibleFrames.first else { return nil }
        let matching = visibleFrames.first {
            $0.contains(NSPoint(x: saved.x + 50, y: saved.y + saved.height - 15))
        }
        let bounds = matching ?? primary
        let width = min(max(800, saved.width), bounds.width)
        let height = min(max(500, saved.height), bounds.height)
        let x = matching == nil ? bounds.midX - width / 2 : min(max(saved.x, bounds.minX), bounds.maxX - width)
        let y = matching == nil ? bounds.midY - height / 2 : min(max(saved.y, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func editAction(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == [.command, .shift], key == "z" { return Selector(("redo:")) }
        guard flags == .command else { return nil }
        return ["z": Selector(("undo:")), "x": #selector(NSText.cut(_:)),
                "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
                "a": #selector(NSText.selectAll(_:))][key]
    }

    static func isQuitShortcut(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.charactersIgnoringModifiers?.lowercased() == "q"
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    }

    private func performChromiumEditShortcut(_ event: NSEvent) -> Bool {
        guard let firstResponder = chromiumPageFirstResponder(),
              let action = Self.editAction(for: event) else { return false }
        return firstResponder.tryToPerform(action, with: event)
    }

    func performChromiumBrowserShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, chromiumPageFirstResponder() != nil else { return false }
        if Self.isQuitShortcut(event) { NSApp.terminate(nil); return true }
        return model.onKeyEvent?(event) ?? false
    }

    private func chromiumPageFirstResponder() -> NSView? {
        guard model.selectedPage?.contextID.engineID == .chromium else { return nil }
        return pageFirstResponder()
    }

    private func pageFirstResponder() -> NSView? {
        guard let pageView = model.selectedPage?.nativeView,
              let firstResponder = window?.firstResponder as? NSView,
              firstResponder === pageView || firstResponder.isDescendant(of: pageView) else { return nil }
        return firstResponder
    }

    private static let keyEvents: [NSEvent.EventType] = [.keyDown, .keyUp, .flagsChanged]
    /// Pointer events that reach the focused page view even when the pointer is outside it.
    private static let focusedPointerEvents: [NSEvent.EventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    private static let hoverEvents: [NSEvent.EventType] = [.mouseEntered, .mouseExited]
    private static let monitoredEvents: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .mouseEntered, .mouseExited]

    private func route(_ event: NSEvent) -> NSEvent? {
        guard event.window === window || (event.window == nil && window?.isKeyWindow == true) else {
            guard let pageView = fullScreenPageView(in: event.window) else { return event }
            return hideCommandKeys(event, handled: false, pageView: pageView)
        }
        let pageView = model.selectedPage?.nativeView
        guard Self.keyEvents.contains(event.type) else { return hideCommandKeys(event, handled: false, pageView: pageView) }
        let handled = performChromiumBrowserShortcut(event) || performChromiumEditShortcut(event)
        if !handled { updateRecentTabCycle(event) }
        return hideCommandKeys(event, handled: handled, pageView: pageView)
    }

    /// Page full screen hosts the page in another window. WebKit moves the page view itself;
    /// the Chromium SDK moves the web contents inside it into its own full-screen window.
    /// Any tab counts, not only the selected one: a full-screen page can open and select a new tab.
    private func fullScreenPageView(in eventWindow: NSWindow?) -> NSView? {
        guard let eventWindow else { return nil }
        let pages = model.openPages
        if let page = pages.first(where: { $0.nativeView.window === eventWindow }) { return page.nativeView }
        guard pages.contains(where: { $0.contextID.engineID == .chromium }),
              NSStringFromClass(type(of: eventWindow)) == "CobbleContentFullscreenWindow" else { return nil }
        return eventWindow.contentView
    }

    private func updateRecentTabCycle(_ event: NSEvent) {
        let commands: [BrowserCommand] = [.recentTab, .previousRecentTab]
        if event.type == .flagsChanged {
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            let held = commands.contains { command in
                let required = model.app.preferences.shortcut(for: command).flags.intersection([.command, .control, .option])
                return !required.isEmpty && flags.isSuperset(of: required)
            }
            if !held { model.endRecentTabCycle() }
        } else if event.type == .keyDown {
            let shortcut = BrowserShortcut(event.charactersIgnoringModifiers ?? "", event.modifierFlags)
            if !commands.contains(where: { model.app.preferences.shortcut(for: $0) == shortcut }) {
                model.endRecentTabCycle()
            }
        }
    }

    /// Keyboard privacy: the page never sees ⌘ or ⌃ — not as keys, key releases, held with
    /// other modifiers, or held while the pointer moves or scrolls. Clicks keep them so ⌘-click
    /// and ⌃-click still work. Cobble's menu and text editing still run natively.
    private func hideCommandKeys(_ event: NSEvent, handled: Bool, pageView: NSView?) -> NSEvent? {
        let passed = handled ? nil : event
        if event.type == .keyUp {
            if hiddenKeyCodes.remove(event.keyCode) != nil { return nil }
            pressedKeys[event.keyCode] = nil
        }
        let isKey = Self.keyEvents.contains(event.type)
        guard isKey || Self.holdsCommandKey(event), model.app.preferences.hidesCommandKeysFromPages,
              let pageView, let pageWindow = pageView.window,
              event.window == nil || event.window === pageWindow else { return passed }
        func inPage(_ view: NSView?) -> Bool { view.map { $0 === pageView || $0.isDescendant(of: pageView) } ?? false }
        let responder = pageWindow.firstResponder as? NSView
        // Judge the pointer by position, not hit-testing: tracking areas ignore views drawn over the
        // page, and WebKit's are owned by a helper object, not a view. Exits happen off the page.
        let overPage = Self.hoverEvents.contains(event.type)
            || pageView.visibleRect.contains(pageView.convert(event.locationInWindow, from: nil))
        guard isKey ? inPage(responder)
                : overPage || Self.focusedPointerEvents.contains(event.type) && inPage(responder) else { return passed }
        if event.type == .keyDown, handled || Self.isCommandKey(event) {
            hiddenKeyCodes.insert(event.keyCode)
            if !handled, let responder { performNatively(event, in: responder) }
            return nil
        }
        if event.type == .flagsChanged, Self.isCommandKey(event) {
            // Chromium forwards releases made while ⌘ is held straight to the window, past this
            // filter. So when ⌘ or ⌃ goes down, release keys the page saw pressed and hide the real release.
            if Self.holdsCommandKey(event) {
                for (code, press) in pressedKeys {
                    if let release = NSEvent.keyEvent(with: .keyUp, location: press.locationInWindow,
                        modifierFlags: Self.withoutCommandBits(event.modifierFlags), timestamp: event.timestamp,
                        windowNumber: pageWindow.windowNumber, context: nil, characters: press.characters ?? "",
                        charactersIgnoringModifiers: press.charactersIgnoringModifiers ?? "", isARepeat: false, keyCode: code) {
                        pageWindow.sendEvent(release)
                    }
                    hiddenKeyCodes.insert(code)
                }
                pressedKeys.removeAll()
            }
            return nil
        }
        if event.type == .keyDown, !handled {
            hiddenKeyCodes.remove(event.keyCode)
            pressedKeys[event.keyCode] = event
        }
        return passed.map(Self.withoutCommandKeys)
    }

    private func performNatively(_ event: NSEvent, in responder: NSView) {
        guard NSApp.mainMenu?.performKeyEquivalent(with: event) != true else { return }
        // Input methods use ⌃ keys while composing, e.g. ⌃K for katakana; they stay native too.
        if (responder as? NSTextInputClient)?.hasMarkedText() == true,
           responder.inputContext?.handleEvent(event) == true { return }
        if let action = Self.editAction(for: event) {
            responder.tryToPerform(action, with: event)
        } else if event.charactersIgnoringModifiers == "`", event.modifierFlags.contains(.command) {
            Self.cycleWindows(backward: event.modifierFlags.contains(.shift))
        } else if let command = KeyBindingLookup.command(for: event) {
            // Text commands such as ⌘← or ⌘⌫ run as editing commands, not key events.
            responder.doCommand(by: command)
        }
    }

    /// ⌘ and ⌃, including their left/right device bits.
    private static let commandKeyBits = NSEvent.ModifierFlags([.command, .control]).rawValue | 0x2019

    static func holdsCommandKey(_ event: NSEvent) -> Bool { event.modifierFlags.rawValue & commandKeyBits != 0 }
    private static func withoutCommandBits(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: flags.rawValue & ~commandKeyBits)
    }

    /// The same event with ⌘ and ⌃ released.
    static func withoutCommandKeys(_ event: NSEvent) -> NSEvent {
        guard holdsCommandKey(event) else { return event }
        if keyEvents.contains(event.type) {
            let isFlags = event.type == .flagsChanged
            let characters = isFlags ? "" : (event.modifierFlags.contains(.control)
                ? event.charactersIgnoringModifiers : event.characters) ?? ""
            return NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
                modifierFlags: withoutCommandBits(event.modifierFlags), timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: isFlags ? "" : event.charactersIgnoringModifiers ?? "",
                isARepeat: isFlags ? false : event.isARepeat, keyCode: event.keyCode) ?? event
        }
        if hoverEvents.contains(event.type) {
            return NSEvent.enterExitEvent(with: event.type, location: event.locationInWindow,
                modifierFlags: withoutCommandBits(event.modifierFlags), timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                trackingNumber: event.trackingNumber, userData: event.userData) ?? event
        }
        guard let copy = event.cgEvent?.copy() else { return event }
        copy.flags = CGEventFlags(rawValue: copy.flags.rawValue & ~UInt64(commandKeyBits))
        return NSEvent(cgEvent: copy) ?? event
    }

    private static func cycleWindows(backward: Bool) {
        let windows = NSApp.orderedWindows.filter { $0.isVisible && $0.canBecomeKey && !$0.isMiniaturized }
        guard windows.count > 1, let next = backward ? windows.last : windows.dropFirst().first else { return }
        if !backward { windows[0].orderBack(nil) }
        next.makeKeyAndOrderFront(nil)
    }

    static func isCommandKey(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown, .keyUp: !event.modifierFlags.isDisjoint(with: [.command, .control])
        // Left/right Command and Control themselves.
        case .flagsChanged: [54, 55, 59, 62].contains(event.keyCode)
        default: false
        }
    }

    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowingClose, model.requiresCloseConfirmation else { return true }
        guard !requestingClose else { return false }
        requestingClose = true
        Task { [weak self] in
            guard let self else { return }
            let accepted = await model.requestClosePages()
            requestingClose = false
            guard accepted else { return }
            allowingClose = true
            window?.performClose(nil)
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        onClose(model.id)
    }
    func windowDidResignKey(_ notification: Notification) { model.endRecentTabCycle() }
    // The sidebar draws its own window buttons; full screen's titlebar needs the native ones.
    func windowWillEnterFullScreen(_ notification: Notification) { showNativeWindowButtons(true) }
    func windowDidExitFullScreen(_ notification: Notification) { showNativeWindowButtons(false) }
    private func showNativeWindowButtons(_ show: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !show
        }
    }
    func windowDidMove(_ notification: Notification) { recordFrame() }
    // Live resize records once at the end; each `record` write invalidates the chrome and schedules a save.
    func windowDidResize(_ notification: Notification) { if window?.inLiveResize != true { recordFrame() } }
    func windowDidEndLiveResize(_ notification: Notification) { recordFrame() }
    func recordFrame() {
        guard let frame = window?.frame else { return }
        let saved = WindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        if model.record.frame != saved { model.record.frame = saved }
    }
}

/// Chromium owns the DevTools frontend; Cobble owns and registers its window.
@MainActor
final class DevToolsWindowController: NSWindowController, NSWindowDelegate {
    let hostWindowID: UUID
    private var inspectedPage: (any BrowserPage)?
    var pageID: ObjectIdentifier? { inspectedPage.map(ObjectIdentifier.init) }
    private let didClose: (UUID) -> Void
    private var session: (any PageDevToolsSession)?
    private var shortcutMonitor: Any?
    private var allowingWindowClose = false
    private var evaluatingWindowClose = false
    private var evaluatingWindowShouldClose = false
    private var requestingSessionClose = false
    private var reportedClose = false

    var isClosed: Bool { session?.isClosed ?? allowingWindowClose }

    init(hostWindowID: UUID, page: any BrowserPage, pageTitle: String,
         didClose: @escaping (UUID) -> Void) {
        self.hostWindowID = hostWindowID
        inspectedPage = page
        self.didClose = didClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = title.isEmpty ? String(localized: "Developer Tools")
            : String(format: String(localized: "Developer Tools — %@"), title)
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSView(frame: window.contentLayoutRect)
        super.init(window: window)
        window.delegate = self
        window.center()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self,
                      event.window === self.window || (event.window == nil && self.window?.isKeyWindow == true),
                      let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
                let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard flags == .command else { return false }
                if key == "q" { NSApp.terminate(nil); return true }
                if key == "w" { self.window?.performClose(nil); return true }
                return false
            }
            return handled ? nil : event
        }
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateVisibility(event: "showWindow")
    }

    func attach(_ session: any PageDevToolsSession) throws {
        guard self.session == nil, !allowingWindowClose else {
            throw EngineError.notReady("Developer Tools could not attach to its window.")
        }
        self.session = session
        session.onClose = { [weak self] in self?.nativeDidClose() }
        guard !session.isClosed else {
            nativeDidClose()
            throw EngineError.closed
        }
        guard let contentView = window?.contentView else { throw EngineError.closed }
        let view = session.nativeView
        view.removeFromSuperview()
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
        updateVisibility(event: "attach")
    }

    func focus() { session?.focus() }

    func closeSession() {
        guard !allowingWindowClose, !requestingSessionClose else { return }
        guard let session else { closeWithoutSession(); return }
        requestingSessionClose = true
        evaluatingWindowClose = true
        _ = session.close()
        evaluatingWindowClose = false
        if allowingWindowClose, !evaluatingWindowShouldClose { finishWindowClose() }
    }

    func closeWithoutSession() {
        guard session == nil else { closeSession(); return }
        finishWindowClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowingWindowClose else { return true }
        evaluatingWindowShouldClose = true
        closeSession()
        evaluatingWindowShouldClose = false
        return allowingWindowClose
    }

    func windowWillClose(_ notification: Notification) {
        diagnose("windowWillClose", visible: false)
        session?.setVisible(false)
        session?.onClose = nil
        session?.nativeView.removeFromSuperview()
        session = nil
        inspectedPage = nil
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        guard !reportedClose else { return }
        reportedClose = true
        didClose(hostWindowID)
    }

    func windowDidBecomeKey(_ notification: Notification) { diagnose("windowDidBecomeKey"); focus() }
    func windowDidResignKey(_ notification: Notification) { diagnose("windowDidResignKey") }
    func windowDidBecomeMain(_ notification: Notification) { diagnose("windowDidBecomeMain") }
    func windowDidResignMain(_ notification: Notification) { diagnose("windowDidResignMain") }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility(event: "windowDidChangeOcclusionState") }
    func windowDidMiniaturize(_ notification: Notification) { updateVisibility(event: "windowDidMiniaturize") }
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility(event: "windowDidDeminiaturize") }

    private func updateVisibility(event: String) {
        guard let window else { return }
        let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        diagnose(event, visible: visible)
        session?.setVisible(visible)
    }

    private func diagnose(_ event: String, visible: Bool? = nil) {
        let target = inspectedPage.map { "tab=\($0.tabID.uuidString) page=\(ObjectIdentifier($0))" } ?? "nil"
        VisibilityDiagnostics.log(event, owner: "devtools host=\(hostWindowID.uuidString) target=\(target)",
                                  view: session?.nativeView, window: window, visible: visible)
    }

    private func nativeDidClose() {
        guard !allowingWindowClose else { return }
        allowingWindowClose = true
        if !evaluatingWindowClose { window?.close() }
    }

    private func finishWindowClose() {
        allowingWindowClose = true
        window?.close()
    }
}

/// Resolves a key to the system text command (e.g. ⌘← → moveToLeftEndOfLine:) without delivering it.
private final class KeyBindingLookup: NSResponder {
    private var command: Selector?
    override func doCommand(by selector: Selector) { command = selector }
    override func insertText(_ insertString: Any) {}

    static func command(for event: NSEvent) -> Selector? {
        let lookup = KeyBindingLookup()
        lookup.interpretKeyEvents([event])
        return lookup.command.flatMap { $0 == Selector(("noop:")) ? nil : $0 }
    }
}
