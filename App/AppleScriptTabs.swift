import AppKit

/// Apple Event automation for normal windows. macOS asks the user before another app may send these
/// (Privacy & Security › Automation). Cobble's own settings can stop all of them, and gate page access.
@MainActor
enum CobbleScriptTabs {
    static weak var app: AppModel?
    static let defaultTextLength = 100_000
    static let defaultOutlineLength = 40_000
    static let defaultActivityLength = 20_000
    static let maximumTextLength = 2_000_000
    static let defaultWaitSeconds = 30
    static let maximumWaitSeconds = 60
    /// Longest screenshot edge in pixels; models downscale larger images anyway.
    static let maximumImageEdge: CGFloat = 1_600
    /// When automation last started loading in a tab, so `wait` cannot return before loading begins.
    private static var navigationStarts: [UUID: ContinuousClock.Instant] = [:]
    private static let navigationGrace: Duration = .seconds(1)

    enum Error: LocalizedError {
        case unavailable, automationOff, busy, invalidURL, invalidWindow, invalidTab, invalidAction, unsafeClose
        case notLoaded, noHistory, otherEngine, pageAccessOff, pageControlOff, excludedSite, pageChanged, timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Cobble is not ready to handle scripting commands.")
            case .automationOff: String(localized: "Turn on Let Apps Control Tabs in Cobble Settings › Browsing first.")
            case .busy: String(localized: "Finish the current page action before changing tabs.")
            case .invalidURL: String(localized: "Use an absolute HTTP or HTTPS URL without embedded credentials.")
            case .invalidWindow: String(localized: "The normal window is unavailable.")
            case .invalidTab: String(localized: "The normal tab is unavailable.")
            case .invalidAction: String(localized: "Use click, fill, select, scroll or press, with a ref from the page outline.")
            case .unsafeClose: String(localized: "Finish the current page action before closing this tab.")
            case .notLoaded: String(localized: "This tab is not loaded. Select it first.")
            case .noHistory: String(localized: "This tab has no page in that direction.")
            case .otherEngine: String(localized: "This address opens in another web engine. Open it in a new tab instead.")
            case .pageAccessOff: String(localized: "Turn on Let Apps Read Pages in Cobble Settings › Browsing first.")
            case .pageControlOff: String(localized: "Turn on Let Apps Use Pages in Cobble Settings › Browsing first.")
            case .excludedSite: String(localized: "This site is private from apps in Cobble Settings › Browsing.")
            case .pageChanged: String(localized: "The page changed while Cobble was reading it. Try again.")
            case .timedOut: String(localized: "The page is still loading. Wait again or read it as it is.")
            }
        }
    }

    /// Normal windows, front to back.
    static func listWindows() throws -> [NSDictionary] {
        let app = try automation()
        let windows = ordered(app)
        return windows.map { entry in
            let window = entry.window
            let agentSpace = AppModel.agentSpaceID(for: window.record.profileID)
            return ["id": window.id.uuidString, "profileID": window.record.profileID.uuidString,
                    "tabCount": window.record.tabs.count,
                    "frontmost": entry.onScreen && window === windows.first?.window,
                    "selectedTabID": window.selectedTab?.id.uuidString ?? "",
                    "spaceID": window.record.selectedSpaceID.uuidString,
                    "agentSpaceID": app.spaces.contains { $0.id == agentSpace } ? agentSpace.uuidString : "",
                    "busy": !window.scriptingMutationAllowed] as NSDictionary
        }
    }

    static func listTabs(arguments: [String: Any]?) throws -> [NSDictionary] {
        let window = try window(arguments: arguments)
        return window.record.tabs.map { tabRecord($0, in: window) }
    }

    /// `agentSpace` opens in the profile's Agents space, created on first use, so agent tabs stay apart.
    static func openTab(directParameter: Any?, arguments: [String: Any]?) throws -> NSDictionary {
        let app = try automation()
        guard let string = directParameter as? String, let url = publicURL(string) else { throw Error.invalidURL }
        let window = try window(arguments: arguments)
        let activate = arguments?["activate"] as? Bool ?? true
        guard window.scriptingMutationAllowed else { throw Error.busy }
        let spaceID = arguments?["agentSpace"] as? Bool == true ? app.agentSpace(for: window.record.profileID) : nil
        guard arguments?["agentSpace"] as? Bool != true || spaceID != nil,
              let tab = window.addTabForScripting(url: url, activate: activate, spaceID: spaceID),
              tab.urlString == url.absoluteString else { throw Error.busy }
        noteNavigation(tab.id)
        return tabRecord(tab, in: window)
    }

    static func selectTab(directParameter: Any?, arguments: [String: Any]?) throws -> NSDictionary {
        let (window, tab) = try target(directParameter, arguments: arguments)
        guard let selected = window.selectTabForScripting(tab.id) else { throw Error.busy }
        window.noteAutomation(tab.id)
        return tabRecord(selected, in: window)
    }

    static func closeTab(directParameter: Any?, arguments: [String: Any]?) throws -> NSDictionary {
        let (window, tab) = try target(directParameter, arguments: arguments)
        guard window.closeTabForScripting(tab.id) else { throw Error.unsafeClose }
        navigationStarts[tab.id] = nil
        return tabRecord(tab, in: window)
    }

    static func loadURL(directParameter: Any?, arguments: [String: Any]?) throws -> NSDictionary {
        let app = try automation()
        guard let string = directParameter as? String, let url = publicURL(string) else { throw Error.invalidURL }
        let (window, tab) = try target(arguments?["tabID"], arguments: arguments)
        let host = try live(window, tab)
        guard app.engines.effectiveID(app.preferences.engine(for: url, override: tab.engineOverride))
                == host.contextID.engineID else { throw Error.otherEngine }
        guard window.navigateTabForScripting(tab.id, to: url) else { throw Error.busy }
        return navigated(tab, in: window)
    }

    static func go(directParameter: Any?, arguments: [String: Any]?, back: Bool) throws -> NSDictionary {
        let (window, tab) = try target(directParameter, arguments: arguments)
        let host = try live(window, tab)
        guard back ? host.canGoBack : host.canGoForward else { throw Error.noHistory }
        guard window.goForScripting(tab.id, back: back) else { throw Error.busy }
        return navigated(tab, in: window)
    }

    static func reloadTab(directParameter: Any?, arguments: [String: Any]?) throws -> NSDictionary {
        let (window, tab) = try target(directParameter, arguments: arguments)
        _ = try live(window, tab)
        guard window.reloadTabForScripting(tab.id) else { throw Error.busy }
        return navigated(tab, in: window)
    }

    /// Returns once the tab's page finishes loading. A loading start shortly after scripted navigation counts.
    static func waitForTab(directParameter: Any?, arguments: [String: Any]?) async throws -> NSDictionary {
        let (window, tab) = try target(directParameter, arguments: arguments)
        let seconds = min(max(arguments?["timeout"] as? Int ?? defaultWaitSeconds, 1), maximumWaitSeconds)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        var sawLoading = false
        window.noteAutomation(tab.id)
        while true {
            let app = try automation()
            guard usable(window, in: app), let current = window.record.tabs.first(where: { $0.id == tab.id }) else {
                throw Error.invalidTab
            }
            guard let state = window.pageState(tab.id) else { throw Error.notLoaded }
            sawLoading = sawLoading || state.isLoading || state.lifecycle != .ready
            let started = navigationStarts[tab.id].map { sawLoading || clock.now - $0 > navigationGrace } ?? true
            if state.lifecycle == .ready, !state.isLoading, started {
                navigationStarts[tab.id] = nil
                return tabRecord(current, in: window)
            }
            guard clock.now < deadline else { throw Error.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Rendered text of a live web page. Never private windows, local files, non-web pages or excluded sites.
    static func readTab(directParameter: Any?, arguments: [String: Any]?) async throws -> NSDictionary {
        let (window, tab, host, url) = try readable(directParameter, arguments: arguments)
        let result = try await host.renderedText(limit: limit(arguments, default: defaultTextLength))
        try confirmUnchanged(host, window: window, tab: tab, url: url)
        return content(tab, url: url, host: host, result)
    }

    /// Headings, text and controls with refs that `perform page action` targets.
    static func outlineTab(directParameter: Any?, arguments: [String: Any]?) async throws -> NSDictionary {
        let (window, tab, host, url) = try readable(directParameter, arguments: arguments)
        let result = try await host.pageOutline(limit: limit(arguments, default: defaultOutlineLength))
        try confirmUnchanged(host, window: window, tab: tab, url: url)
        return content(tab, url: url, host: host, result)
    }

    /// Script errors, failed loads and network requests, for developer agents.
    static func readActivity(directParameter: Any?, arguments: [String: Any]?) async throws -> NSDictionary {
        let (window, tab, host, url) = try readable(directParameter, arguments: arguments)
        let result = try await host.pageActivity(limit: limit(arguments, default: defaultActivityLength))
        try confirmUnchanged(host, window: window, tab: tab, url: url)
        return content(tab, url: url, host: host, result)
    }

    /// Clicks, fills, chooses, scrolls or presses a key, as described in `PageAction`.
    static func performAction(directParameter: Any?, arguments: [String: Any]?) async throws -> String {
        guard let raw = directParameter as? String, let kind = PageAction.Kind(rawValue: raw.lowercased()) else {
            throw Error.invalidAction
        }
        let ref = (arguments?["ref"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let value = arguments?["value"] as? String
        guard ref != nil || kind == .scroll || kind == .press, (value?.utf16.count ?? 0) <= maximumTextLength else {
            throw Error.invalidAction
        }
        let (window, tab, host, _) = try readable(arguments?["tabID"], arguments: arguments, control: true)
        guard window.scriptingMutationAllowed else { throw Error.busy }
        let result = try await host.perform(PageAction(kind: kind, ref: ref, value: value,
                                                      submit: arguments?["submit"] as? Bool ?? false))
        if kind != .scroll { noteNavigation(tab.id) }
        return result
    }

    /// The visible page viewport as base64 PNG, without browser chrome.
    static func captureTab(directParameter: Any?, arguments: [String: Any]?) async throws -> NSDictionary {
        let (window, tab, host, url) = try readable(directParameter, arguments: arguments)
        let image = try await host.snapshot()
        try confirmUnchanged(host, window: window, tab: tab, url: url)
        guard let (png, size) = pngData(image) else {
            throw EngineError.notReady(String(localized: "Cobble could not encode the screenshot."))
        }
        return ["id": tab.id.uuidString, "url": url.absoluteString, "width": Int(size.width), "height": Int(size.height),
                "pngData": png.base64EncodedString()] as NSDictionary
    }

    private static func automation() throws -> AppModel {
        guard let app else { throw Error.unavailable }
        guard app.preferences.automationTabAccess else { throw Error.automationOff }
        return app
    }

    private static func limit(_ arguments: [String: Any]?, default value: Int) -> Int {
        min(max(arguments?["maxLength"] as? Int ?? value, 1), maximumTextLength)
    }

    private static func content(_ tab: Tab, url: URL, host: any BrowserPage,
                                _ result: (text: String, truncated: Bool)) -> NSDictionary {
        ["id": tab.id.uuidString, "url": url.absoluteString, "title": String(host.state.title.prefix(512)),
         "text": result.text, "truncated": result.truncated] as NSDictionary
    }

    private static func navigated(_ tab: Tab, in window: BrowserWindowModel) -> NSDictionary {
        noteNavigation(tab.id)
        return tabRecord(tab, in: window)
    }

    /// Starts older than the grace period count as none, so they are dropped instead of kept for closed tabs.
    private static func noteNavigation(_ id: UUID) {
        let now = ContinuousClock.now
        navigationStarts = navigationStarts.filter { now - $0.value <= navigationGrace }
        navigationStarts[id] = now
    }

    private static func readable(_ raw: Any?, arguments: [String: Any]?, control: Bool = false) throws
        -> (BrowserWindowModel, Tab, any BrowserPage, URL) {
        let app = try automation()
        guard app.preferences.automationPageAccess else { throw Error.pageAccessOff }
        guard !control || app.preferences.automationPageControl else { throw Error.pageControlOff }
        let (window, tab) = try target(raw, arguments: arguments)
        let host = try live(window, tab)
        guard let url = publicURL(host.state.urlString) else { throw Error.invalidTab }
        guard !app.preferences.automationExcludes(url) else { throw Error.excludedSite }
        return (window, tab, host, url)
    }

    private static func confirmUnchanged(_ host: any BrowserPage, window: BrowserWindowModel, tab: Tab, url: URL) throws {
        guard let app, app.preferences.automationPageAccess, !app.preferences.automationExcludes(url),
              usable(window, in: app), window.scriptablePage(tab.id) === host,
              publicURL(host.state.urlString) == url else {
            throw Error.pageChanged
        }
    }

    private static func live(_ window: BrowserWindowModel, _ tab: Tab) throws -> any BrowserPage {
        if let host = window.scriptablePage(tab.id) { return host }
        throw window.pageState(tab.id) == nil ? Error.notLoaded : Error.busy
    }

    /// An explicit window, else the frontmost normal window.
    private static func window(arguments: [String: Any]?) throws -> BrowserWindowModel {
        let app = try automation()
        guard let raw = arguments?["windowID"] else {
            guard let window = ordered(app).first?.window else { throw Error.invalidWindow }
            return window
        }
        guard let string = raw as? String, let id = UUID(uuidString: string),
              let window = app.windows.first(where: { $0.id == id }), usable(window, in: app) else {
            throw Error.invalidWindow
        }
        return window
    }

    /// Tab IDs are unique, so the window is optional. Every tab an app targets is marked in the sidebar.
    private static func target(_ raw: Any?, arguments: [String: Any]?) throws -> (BrowserWindowModel, Tab) {
        let app = try automation()
        guard let string = raw as? String, let id = UUID(uuidString: string) else { throw Error.invalidTab }
        let windows = arguments?["windowID"] == nil ? ordered(app).map(\.window) : [try window(arguments: arguments)]
        for window in windows {
            if let tab = window.record.tabs.first(where: { $0.id == id }) {
                window.noteAutomation(id)
                return (window, tab)
            }
        }
        throw Error.invalidTab
    }

    private static func ordered(_ app: AppModel) -> [(window: BrowserWindowModel, onScreen: Bool)] {
        let stack = NSApp?.orderedWindows ?? []
        let ranked = app.windows.enumerated().filter { usable($0.element, in: app) }.map { offset, window in
            let native = window.nativeWindow.flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil }
            let rank = native.flatMap { native in stack.firstIndex { $0 === native } } ?? Int.max
            return (rank: rank, offset: offset, window: window)
        }
        return ranked.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map { ($0.window, $0.rank != Int.max) }
    }

    private static func usable(_ window: BrowserWindowModel, in app: AppModel) -> Bool {
        !window.isPrivate && !window.isClosed && !app.isDeletingProfile(window.record.profileID)
            && app.profiles.contains(where: { $0.id == window.record.profileID })
    }

    private static func publicURL(_ string: String) -> URL? {
        guard string.count <= 4_096, let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url, AddressResolver.canonicalOrigin(url) != nil else { return nil }
        return url
    }

    /// Excluded sites show only their origin: titles and paths can carry mail subjects or account numbers.
    private static func tabRecord(_ tab: Tab, in window: BrowserWindowModel) -> NSDictionary {
        let address = publicURL(tab.urlString)
        let excluded = address.map { app?.preferences.automationExcludes($0) == true } ?? false
        let url = excluded ? address.flatMap(AddressResolver.canonicalOrigin) ?? "" : address?.absoluteString ?? ""
        let title = url.isEmpty || excluded ? "" : String(tab.title.prefix(512))
        let state = window.pageState(tab.id)
        let engine = app?.engines.effectiveID(tab.engineID) ?? tab.engineID
        let space = app?.spaces.first { $0.id == tab.spaceID }
        return ["id": tab.id.uuidString, "url": url, "title": title,
                "selected": tab.id == window.selectedTab?.id,
                "loaded": state?.lifecycle == .ready, "loading": state?.isLoading == true,
                "engine": engine.rawValue, "saved": tab.savedItemID != nil,
                "audible": state?.isPlayingAudio == true, "muted": state?.isAudioMuted == true,
                "busy": state?.hasPendingPrompt == true, "excluded": excluded,
                "spaceID": tab.spaceID.uuidString, "spaceName": space?.displayedName ?? ""] as NSDictionary
    }

    private static func pngData(_ image: NSImage) -> (Data, NSSize)? {
        let scale = min(1, maximumImageEdge / max(image.size.width, image.size.height, 1))
        let size = NSSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]).map { ($0, size) }
    }
}

class CobbleScriptCommand: NSScriptCommand {
    func invoke(_ selector: Selector) -> Any? {
        precondition(Thread.isMainThread)
        return CobbleScriptBridge().perform(selector, with: self)?.takeUnretainedValue()
    }
}

private final class CobbleScriptBridge: NSObject {
    @MainActor private static func fail(_ command: NSScriptCommand, _ error: any Swift.Error) {
        command.scriptErrorNumber = switch error {
        case CobbleScriptTabs.Error.invalidURL, CobbleScriptTabs.Error.invalidWindow, CobbleScriptTabs.Error.invalidTab,
             CobbleScriptTabs.Error.invalidAction:
            NSArgumentsWrongScriptError
        default: NSReceiversCantHandleCommandScriptError
        }
        command.scriptErrorString = error.localizedDescription
    }

    @MainActor private func run(_ command: NSScriptCommand, _ operation: () throws -> Any) -> Any? {
        do { return try operation() }
        catch { Self.fail(command, error); return nil }
    }

    /// Replies after the page answers; Cocoa scripting holds the Apple Event until resumed.
    @MainActor private func runAsync(_ command: NSScriptCommand,
                                     _ operation: @escaping @MainActor () async throws -> Any) -> Any? {
        command.suspendExecution()
        Task { @MainActor in
            do { command.resumeExecution(withResult: try await operation()) }
            catch { Self.fail(command, error); command.resumeExecution(withResult: nil) }
        }
        return nil
    }

    @objc @MainActor func listWindows(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.listWindows() }
    }

    @objc @MainActor func listTabs(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.listTabs(arguments: command.evaluatedArguments) }
    }

    @objc @MainActor func openTab(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.openTab(directParameter: command.directParameter, arguments: command.evaluatedArguments) }
    }

    @objc @MainActor func selectTab(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.selectTab(directParameter: command.directParameter, arguments: command.evaluatedArguments) }
    }

    @objc @MainActor func closeTab(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.closeTab(directParameter: command.directParameter, arguments: command.evaluatedArguments) }
    }

    @objc @MainActor func loadURL(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.loadURL(directParameter: command.directParameter, arguments: command.evaluatedArguments) }
    }

    @objc @MainActor func goBack(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.go(directParameter: command.directParameter, arguments: command.evaluatedArguments, back: true) }
    }

    @objc @MainActor func goForward(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.go(directParameter: command.directParameter, arguments: command.evaluatedArguments, back: false) }
    }

    @objc @MainActor func reloadTab(_ command: NSScriptCommand) -> Any? {
        run(command) { try CobbleScriptTabs.reloadTab(directParameter: command.directParameter, arguments: command.evaluatedArguments) }
    }

    @objc @MainActor func readTab(_ command: NSScriptCommand) -> Any? {
        let (direct, arguments) = (command.directParameter, command.evaluatedArguments)
        return runAsync(command) { try await CobbleScriptTabs.readTab(directParameter: direct, arguments: arguments) }
    }

    @objc @MainActor func captureTab(_ command: NSScriptCommand) -> Any? {
        let (direct, arguments) = (command.directParameter, command.evaluatedArguments)
        return runAsync(command) { try await CobbleScriptTabs.captureTab(directParameter: direct, arguments: arguments) }
    }

    @objc @MainActor func waitForTab(_ command: NSScriptCommand) -> Any? {
        let (direct, arguments) = (command.directParameter, command.evaluatedArguments)
        return runAsync(command) { try await CobbleScriptTabs.waitForTab(directParameter: direct, arguments: arguments) }
    }

    @objc @MainActor func outlineTab(_ command: NSScriptCommand) -> Any? {
        let (direct, arguments) = (command.directParameter, command.evaluatedArguments)
        return runAsync(command) { try await CobbleScriptTabs.outlineTab(directParameter: direct, arguments: arguments) }
    }

    @objc @MainActor func performAction(_ command: NSScriptCommand) -> Any? {
        let (direct, arguments) = (command.directParameter, command.evaluatedArguments)
        return runAsync(command) { try await CobbleScriptTabs.performAction(directParameter: direct, arguments: arguments) }
    }

    @objc @MainActor func readActivity(_ command: NSScriptCommand) -> Any? {
        let (direct, arguments) = (command.directParameter, command.evaluatedArguments)
        return runAsync(command) { try await CobbleScriptTabs.readActivity(directParameter: direct, arguments: arguments) }
    }
}

@objc(CobbleListWindowsCommand)
final class CobbleListWindowsCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.listWindows(_:))) }
}

@objc(CobbleListTabsCommand)
final class CobbleListTabsCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.listTabs(_:))) }
}

@objc(CobbleOpenTabCommand)
final class CobbleOpenTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.openTab(_:))) }
}

@objc(CobbleSelectTabCommand)
final class CobbleSelectTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.selectTab(_:))) }
}

@objc(CobbleCloseTabCommand)
final class CobbleCloseTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.closeTab(_:))) }
}

@objc(CobbleLoadURLCommand)
final class CobbleLoadURLCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.loadURL(_:))) }
}

@objc(CobbleGoBackCommand)
final class CobbleGoBackCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.goBack(_:))) }
}

@objc(CobbleGoForwardCommand)
final class CobbleGoForwardCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.goForward(_:))) }
}

@objc(CobbleReloadTabCommand)
final class CobbleReloadTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.reloadTab(_:))) }
}

@objc(CobbleReadTabCommand)
final class CobbleReadTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.readTab(_:))) }
}

@objc(CobbleCaptureTabCommand)
final class CobbleCaptureTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.captureTab(_:))) }
}

@objc(CobbleWaitForTabCommand)
final class CobbleWaitForTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.waitForTab(_:))) }
}

@objc(CobbleOutlineTabCommand)
final class CobbleOutlineTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.outlineTab(_:))) }
}

@objc(CobblePerformActionCommand)
final class CobblePerformActionCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.performAction(_:))) }
}

@objc(CobbleReadActivityCommand)
final class CobbleReadActivityCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? { invoke(#selector(CobbleScriptBridge.readActivity(_:))) }
}
