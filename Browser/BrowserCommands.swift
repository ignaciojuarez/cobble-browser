import AppKit

// Stable names are persisted; menu tags are only used inside this process.
enum BrowserCommand: Int, CaseIterable, Identifiable {
    case settings, newWindow, newPrivateWindow, newTab, reopen, closeTab, closeWindow, printPage, undoWorkspace, find, sidebar, reload, stop, zoomIn, zoomOut, zoomReset, address, back, forward, nextTab, previousTab, history, nextSpace, previousSpace, pinTab, favoriteTab, bookmark, duplicateTab, detachTab, moveUp, moveDown, newSpace, newFolder, rename, unload, recentTab, copyURL, renameSpace, deleteSpace, chooseSpaceEmoji, revealTab, clearHistory, muteTab, closeOtherTabs
    case findNext, findPrevious, resetSavedURL, saveCurrentURL, reloadFromOrigin, screenshot, sharePage, openFile, savePage, viewPageDOM, openDevTools
    case closeTabsAbove, closeTabsBelow
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9
    case previousRecentTab
    var tabIndex: Int? {
        guard (Self.tab1.rawValue...Self.tab9.rawValue).contains(rawValue) else { return nil }
        return rawValue - Self.tab1.rawValue
    }
    var id: String { String(describing: self) }
    var explanation: String? {
        switch self {
        case .unload: String(localized: "Unloading discards unsaved forms and this page’s back/forward history. The tab stays; reload to open it again.")
        case .reloadFromOrigin: String(localized: "Revalidates this page with its origin. Valid cached resources may be reused; cookies and website data stay.")
        default: nil
        }
    }
    private var unlocalizedTitle: String {
        switch self {
        case .previousRecentTab: "Previous Recently Used Tab"
        case .closeTabsAbove: "Close Temporary Tabs Above"
        case .closeTabsBelow: "Close Temporary Tabs Below"
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9: "Select Tab %@"
        case .screenshot: "Save Screenshot…"
        case .sharePage: "Share Page…"
        case .openFile: "Open File…"
        case .savePage: "Save Page…"
        case .viewPageDOM: "View Current Page DOM…"
        case .openDevTools: "Open Developer Tools"
        case .closeOtherTabs: "Close Other Temporary Tabs"
        case .recentTab: "Toggle Recent Tabs"
        case .settings: "Settings…"
        case .newWindow: "New Window"
        case .newPrivateWindow: "New Private Window"
        case .newTab: "New Tab…"
        case .reopen: "Reopen Closed Tab"
        case .closeTab: "Close Tab"
        case .closeWindow: "Close Window"
        case .printPage: "Print…"
        case .undoWorkspace: "Undo Workspace Change"
        case .find: "Find in Page…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .resetSavedURL: "Reset to Saved URL"
        case .saveCurrentURL: "Use Current URL as Saved Destination"
        case .sidebar: "Toggle Sidebar"
        case .reloadFromOrigin: "Reload from Origin"
        case .reload: "Reload"
        case .stop: "Stop Loading"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomReset: "Actual Size"
        case .address: "Open Location…"
        case .back: "Back"
        case .forward: "Forward"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .history: "History…"
        case .nextSpace: "Next Space"
        case .previousSpace: "Previous Space"
        case .pinTab: "Pin/Unpin Tab"
        case .favoriteTab: "Add to Favorites"
        case .bookmark: "Add Library Bookmark"
        case .duplicateTab: "Duplicate Tab"
        case .detachTab: "Move Tab to New Window"
        case .moveUp: "Move Tab Up"
        case .moveDown: "Move Tab Down"
        case .newSpace: "New Space…"
        case .newFolder: "New Folder…"
        case .rename: "Rename Selected Pin…"
        case .unload: "Unload Tab"
        case .copyURL: "Copy Link"
        case .renameSpace: "Edit Space…"
        case .deleteSpace: "Delete Space"
        case .chooseSpaceEmoji: "Choose Emoji…"
        case .revealTab: "Reveal Tab in Sidebar"
        case .clearHistory: "Clear Recent History…"
        case .muteTab: "Mute Tab"
        }
    }
    var title: String {
        if let tabIndex { return String(format: NSLocalizedString(unlocalizedTitle, comment: "Browser command"), "\(tabIndex + 1)") }
        return NSLocalizedString(unlocalizedTitle, comment: "Browser command")
    }
    static func matching(_ query: String) -> [BrowserCommand] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? [.newSpace] : allCases.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var defaultShortcut: BrowserShortcut {
        switch self {
        case .previousRecentTab: BrowserShortcut("\t", [.control, .shift])
        case .closeTabsAbove, .closeTabsBelow, .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9: BrowserShortcut("")
        case .screenshot, .sharePage, .openFile, .savePage, .viewPageDOM: BrowserShortcut("")
        case .openDevTools: BrowserShortcut("i", [.command, .option])
        case .closeOtherTabs, .detachTab: BrowserShortcut("")
        case .recentTab: BrowserShortcut("\t", .control)
        case .settings: BrowserShortcut(",")
        case .newWindow: BrowserShortcut("n")
        case .newPrivateWindow: BrowserShortcut("n", [.command, .shift])
        case .newTab: BrowserShortcut("t")
        case .reopen: BrowserShortcut("t", [.command, .shift])
        case .closeTab: BrowserShortcut("w")
        case .closeWindow: BrowserShortcut("w", [.command, .shift])
        case .printPage: BrowserShortcut("p")
        case .undoWorkspace: BrowserShortcut("z", [.command, .option])
        case .find: BrowserShortcut("f")
        case .findNext: BrowserShortcut("g")
        case .findPrevious: BrowserShortcut("g", [.command, .shift])
        case .resetSavedURL, .saveCurrentURL: BrowserShortcut("")
        case .sidebar: BrowserShortcut("s")
        case .reloadFromOrigin: BrowserShortcut("r", [.command, .option])
        case .reload: BrowserShortcut("r")
        case .stop: BrowserShortcut(".")
        case .zoomIn: BrowserShortcut("+")
        case .zoomOut: BrowserShortcut("-")
        case .zoomReset: BrowserShortcut("0")
        case .address: BrowserShortcut("l")
        case .back: BrowserShortcut("[")
        case .forward: BrowserShortcut("]")
        case .nextTab: BrowserShortcut(String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option])
        case .previousTab: BrowserShortcut(String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option])
        case .history: BrowserShortcut("y")
        case .nextSpace: BrowserShortcut(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
        case .previousSpace: BrowserShortcut(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
        case .pinTab: BrowserShortcut("d")
        case .favoriteTab: BrowserShortcut("")
        case .bookmark: BrowserShortcut("")
        case .duplicateTab: BrowserShortcut("")
        case .moveUp: BrowserShortcut(String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .control])
        case .moveDown: BrowserShortcut(String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .control])
        case .newSpace: BrowserShortcut("")
        case .newFolder: BrowserShortcut("")
        case .rename: BrowserShortcut("")
        case .unload: BrowserShortcut("")
        case .copyURL: BrowserShortcut("c", [.command, .shift])
        case .renameSpace: BrowserShortcut("")
        case .deleteSpace: BrowserShortcut("")
        case .chooseSpaceEmoji: BrowserShortcut("")
        case .revealTab: BrowserShortcut("")
        case .clearHistory: BrowserShortcut("")
        case .muteTab: BrowserShortcut("")
        }
    }
}

struct BrowserShortcut: Codable, Equatable {
    var key: String
    var modifiers: UInt
    init(_ key: String, _ flags: NSEvent.ModifierFlags = .command) {
        self.key = key.lowercased()
        modifiers = flags.intersection([.command, .option, .control, .shift]).rawValue
    }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var label: String {
        guard !key.isEmpty else { return String(localized: "Unassigned") }
        let special = ["\t": "⇥", "\r": "↩", " ": String(localized: "Space"),
                       String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
                       String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
                       String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
                       String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"]
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            + (special[key] ?? key.uppercased())
    }
    var isValid: Bool {
        key.isEmpty || (key.count == 1 && key != "\u{1b}" && key != "\u{7f}"
            && !flags.intersection([.command, .control]).isEmpty
            && modifiers == flags.intersection([.command, .option, .control, .shift]).rawValue)
    }
}

extension BrowserWindowModel {
    @discardableResult func dispatch(_ command: BrowserCommand) -> Bool {
        onCommand?(command) ?? perform(command)
    }

    var otherTemporaryTabIDs: [UUID] {
        record.tabs.filter { $0.spaceID == record.selectedSpaceID && $0.savedItemID == nil && $0.id != record.selectedTabID }.map(\.id)
    }

    func directionalTemporaryTabIDs(above: Bool) -> [UUID] {
        // Saved rows precede temporary tabs, but are never targets of range closure.
        let destinations = sidebarDestinations
        let selection = selectedTab?.savedItemID ?? record.selectedTabID
        guard let index = destinations.firstIndex(where: { $0.id == selection }) else { return [] }
        return destinations.enumerated().compactMap { offset, item in
            guard !item.saved, above ? offset < index : offset > index else { return nil }
            return item.id
        }
    }

    func canPerform(_ command: BrowserCommand) -> Bool {
        guard !isClosed, !app.isDeletingProfile(record.profileID) else { return false }
        switch command {
        case .closeTabsAbove: return !directionalTemporaryTabIDs(above: true).isEmpty
        case .closeTabsBelow: return !directionalTemporaryTabIDs(above: false).isEmpty
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            return command.tabIndex.map { sidebarDestinations.indices.contains($0) } == true
        case .reopen: return !closedTabs.isEmpty
        case .screenshot: return !pageFileOperations.isSavingScreenshot && selectedPage?.state.lifecycle == .ready && selectedPage?.capabilities.pageOperations.contains(.snapshot) == true
        case .openFile:
            return !pageFileOperations.isOpeningLocalFile && ((selectedPage?.capabilities.pageOperations.contains(.localFile)
                ?? app.engines.engine(app.engines.effectiveID(selectedTab?.engineID ?? app.preferences.defaultEngine))?.capabilities.pageOperations.contains(.localFile)) == true)
        case .savePage: return !pageFileOperations.isSavingPage && selectedPage?.state.lifecycle == .ready && selectedPage?.capabilities.pageOperations.contains(.savePage) == true
        case .viewPageDOM: return selectedPage?.state.lifecycle == .ready && selectedPage?.capabilities.pageOperations.contains(.pageDOM) == true
        case .openDevTools:
            return app.preferences.webInspectorEnabled && selectedPage?.state.lifecycle == .ready
                && selectedPage?.hasPendingPrompt != true
                && selectedPage?.capabilities.pageOperations.contains(.openDevTools) == true
        case .sharePage: return selectedTab?.url.flatMap(AddressResolver.canonicalOrigin) != nil
        case .closeOtherTabs: return selectedTab != nil && !otherTemporaryTabIDs.isEmpty
        case .find: return selectedPage?.state.lifecycle == .ready && selectedPage?.capabilities.pageOperations.contains(.find) == true
        case .findNext, .findPrevious: return !findText.isEmpty && canPerform(.find)
        case .resetSavedURL: return selectedTab?.savedItemID != nil
        case .saveCurrentURL: return selectedTab?.savedItemID.map(canUseCurrentURLAsSavedDestination) == true
        case .zoomIn, .zoomOut, .zoomReset: return selectedPage?.state.lifecycle == .ready && selectedPage?.capabilities.pageOperations.contains(.zoom) == true
        case .printPage: return selectedPage?.state.lifecycle == .ready && selectedPage?.capabilities.pageOperations.contains(.printPage) == true
        case .back: return selectedPage?.canGoBack == true
        case .forward: return selectedPage?.canGoForward == true
        case .stop: return selectedPage?.isLoading == true
        case .reloadFromOrigin: return selectedPage?.state.lifecycle == .ready && selectedPage?.capabilities.pageOperations.contains(.reloadFromOrigin) == true
        case .reload: return selectedTab != nil
        case .bookmark, .pinTab, .favoriteTab:
            guard let tab = selectedTab, !tab.urlString.isEmpty else { return false }
            return !isPrivate && URL(string: tab.urlString)?.isFileURL != true
        case .copyURL: return selectedTab?.urlString.isEmpty == false
        case .duplicateTab, .moveUp, .moveDown, .closeTab: return selectedTab != nil
        case .detachTab: return canDetachSelectedTab
        case .unload: return selectedPage != nil
        case .undoWorkspace: return app.canUndoOrganization
        case .rename: return selectedTab?.savedItemID != nil
        case .renameSpace, .chooseSpaceEmoji: return selectedSpace != nil
        case .deleteSpace: return spaces.count > 1
        case .revealTab: return selectedTab != nil
        case .clearHistory: return !isPrivate
        case .muteTab:
            guard let id = selectedTab?.id else { return false }
            return canMute(id) && !isCapturing(id) && selectedPage?.state.audioMuteBlocked != true
        default: return true
        }
    }
    @discardableResult func perform(_ command: BrowserCommand) -> Bool {
        guard canPerform(command) else { return false }
        if command != .recentTab && command != .previousRecentTab { endRecentTabCycle() }
        switch command {
        case .closeTabsAbove, .closeTabsBelow:
            directionalTemporaryTabIDs(above: command == .closeTabsAbove).forEach { closeTab($0) }
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            if let index = command.tabIndex { selectSidebarDestination(at: index) }
        case .screenshot: pageFileOperations.saveScreenshot()
        case .openFile: pageFileOperations.openLocalFile()
        case .savePage: pageFileOperations.savePage()
        case .viewPageDOM: pageFileOperations.viewCurrentDOM()
        case .openDevTools:
            guard let page = selectedPage else { return false }
            return onOpenDevTools?(page) ?? false
        case .sharePage: sharePage()
        case .closeOtherTabs: otherTemporaryTabIDs.forEach { closeTab($0) }
        case .newTab:
            if commandBarPresented { commandBarPresented = false }
            else { openCommandBar() }
        case .closeTab: if let tab = selectedTab { closeTab(tab.id) }
        case .reopen: reopenClosedTab()
        case .address: focusAddress()
        case .reloadFromOrigin: selectedPage?.reloadFromOrigin()
        case .reload: reloadSelected()
        case .stop: selectedPage?.stop()
        case .back: selectedPage?.goBack()
        case .forward: selectedPage?.goForward()
        case .sidebar: sidebarVisible.toggle()
        case .find:
            let wasPresented = findPresented
            findPresented = true
            findFocusRequest = UUID()
            if !wasPresented, !findText.isEmpty { selectedPage?.find(findText, backwards: false) }
        case .findNext, .findPrevious:
            findPresented = true
            selectedPage?.find(findText, backwards: command == .findPrevious)
        case .resetSavedURL: if let id = selectedTab?.savedItemID { resetSavedDestination(id) }
        case .saveCurrentURL: if let id = selectedTab?.savedItemID { useCurrentURLAsSavedDestination(id) }
        case .zoomIn: selectedPage?.zoom(by: 1.1)
        case .zoomOut: selectedPage?.zoom(by: 1 / 1.1)
        case .zoomReset: selectedPage?.resetZoom()
        case .printPage: selectedPage?.printPage()
        case .undoWorkspace: app.undoOrganization()
        case .recentTab, .previousRecentTab:
            if app.preferences.cycleAllRecentTabs {
                cycleRecentTab(backwards: command == .previousRecentTab)
                let event = NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0 : nil }
                let shortcut = BrowserShortcut(event?.charactersIgnoringModifiers ?? "", event?.modifierFlags ?? [])
                // Menus/overlay have no held-key session to finish on modifier release.
                if event == nil || shortcut != app.preferences.shortcut(for: command) { endRecentTabCycle() }
            } else { toggleRecentTab() }
        case .nextTab: cycleTab(offset: 1)
        case .previousTab: cycleTab(offset: -1)
        case .nextSpace: cycleSpace(offset: 1)
        case .previousSpace: cycleSpace(offset: -1)
        case .pinTab: togglePinSelected()
        case .favoriteTab: if let tab = selectedTab { pinTab(tab.id, favorite: true) }
        case .bookmark: bookmarkSelected()
        case .duplicateTab: if let tab = selectedTab { duplicateTab(tab.id) }
        case .detachTab: return app.detachSelectedTab(from: self) != nil
        case .moveUp: moveSelected(offset: -1)
        case .moveDown: moveSelected(offset: 1)
        case .newSpace: revealSidebarChrome(); organizationEditor = .newSpace
        case .newFolder: revealSidebarChrome(); organizationEditor = .newFolder
        case .rename: revealSidebarChrome(); organizationEditor = .rename
        case .unload: discardSelected()
        case .copyURL: copyPageURL()
        case .renameSpace, .chooseSpaceEmoji: revealSidebarChrome(); organizationEditor = .editSpace
        case .deleteSpace: if let space = selectedSpace { app.deleteSpace(space.id) }
        case .revealTab: revealSidebarChrome()
        case .muteTab: if let tabID = selectedTab?.id { toggleMute(tabID) }
        default: return false
        }
        return true
    }

}
