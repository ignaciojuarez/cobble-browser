import AppKit

@MainActor
enum CobbleScriptTabs {
    static weak var app: AppModel?

    enum Error: LocalizedError {
        case unavailable, busy, invalidURL, invalidWindow, invalidTab, unsafeClose

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Cobble is not ready to handle scripting commands.")
            case .busy: String(localized: "Finish the current page action before changing tabs.")
            case .invalidURL: String(localized: "Use an absolute HTTP or HTTPS URL without embedded credentials.")
            case .invalidWindow: String(localized: "The normal window is unavailable.")
            case .invalidTab: String(localized: "The normal tab is unavailable.")
            case .unsafeClose: String(localized: "Finish the current page action before closing this tab.")
            }
        }
    }

    static func listWindows() throws -> [NSDictionary] {
        guard let app else { throw Error.unavailable }
        return app.windows.compactMap { window in
            guard usable(window, in: app) else { return nil }
            return ["id": window.id.uuidString, "profileID": window.record.profileID.uuidString,
                    "tabCount": window.record.tabs.count] as NSDictionary
        }
    }

    static func listTabs(arguments: [String: Any]?) throws -> [NSDictionary] {
        let window = try window(arguments: arguments)
        return window.record.tabs.map { tabRecord($0, in: window) }
    }

    static func openTab(directParameter: Any?, arguments: [String: Any]?) throws -> NSDictionary {
        guard let string = directParameter as? String, let url = publicURL(string) else { throw Error.invalidURL }
        let window = try window(arguments: arguments)
        guard let tab = window.addTabForScripting(url: url), tab.urlString == url.absoluteString else { throw Error.busy }
        return tabRecord(tab, in: window)
    }

    static func selectTab(directParameter: Any?, arguments: [String: Any]?) throws -> NSDictionary {
        let window = try window(arguments: arguments)
        let tab = try tab(directParameter, in: window)
        guard let selected = window.selectTabForScripting(tab.id) else { throw Error.busy }
        return tabRecord(selected, in: window)
    }

    static func closeTab(directParameter: Any?, arguments: [String: Any]?) throws -> NSDictionary {
        let window = try window(arguments: arguments)
        let tab = try tab(directParameter, in: window)
        guard window.closeTabForScripting(tab.id) else { throw Error.unsafeClose }
        return tabRecord(tab, in: window)
    }

    private static func window(arguments: [String: Any]?) throws -> BrowserWindowModel {
        guard let raw = arguments?["windowID"] as? String, let id = UUID(uuidString: raw),
              let app, let window = app.windows.first(where: { $0.id == id }), usable(window, in: app) else {
            throw Error.invalidWindow
        }
        return window
    }

    private static func tab(_ raw: Any?, in window: BrowserWindowModel) throws -> Tab {
        guard let string = raw as? String, let id = UUID(uuidString: string),
              let tab = window.record.tabs.first(where: { $0.id == id }) else { throw Error.invalidTab }
        return tab
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

    private static func tabRecord(_ tab: Tab, in window: BrowserWindowModel) -> NSDictionary {
        let url = publicURL(tab.urlString)?.absoluteString ?? ""
        let title = url.isEmpty ? "" : String(tab.title.prefix(512))
        return ["id": tab.id.uuidString, "url": url, "title": title,
                "selected": tab.id == window.selectedTab?.id] as NSDictionary
    }
}

class CobbleScriptCommand: NSScriptCommand {
    func invoke(_ selector: Selector) -> Any? {
        precondition(Thread.isMainThread)
        return CobbleScriptBridge().perform(selector, with: self)?.takeUnretainedValue()
    }
}

private final class CobbleScriptBridge: NSObject {
    @MainActor private func run(_ command: NSScriptCommand, _ operation: () throws -> Any) -> Any? {
        do { return try operation() }
        catch {
            command.scriptErrorNumber = switch error {
            case CobbleScriptTabs.Error.unavailable, CobbleScriptTabs.Error.busy, CobbleScriptTabs.Error.unsafeClose:
                NSReceiversCantHandleCommandScriptError
            default: NSArgumentsWrongScriptError
            }
            command.scriptErrorString = error.localizedDescription
            return nil
        }
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
}

@objc(CobbleListWindowsCommand)
final class CobbleListWindowsCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? {
        invoke(#selector(CobbleScriptBridge.listWindows(_:)))
    }
}

@objc(CobbleListTabsCommand)
final class CobbleListTabsCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? {
        invoke(#selector(CobbleScriptBridge.listTabs(_:)))
    }
}

@objc(CobbleOpenTabCommand)
final class CobbleOpenTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? {
        invoke(#selector(CobbleScriptBridge.openTab(_:)))
    }
}

@objc(CobbleSelectTabCommand)
final class CobbleSelectTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? {
        invoke(#selector(CobbleScriptBridge.selectTab(_:)))
    }
}

@objc(CobbleCloseTabCommand)
final class CobbleCloseTabCommand: CobbleScriptCommand {
    override func performDefaultImplementation() -> Any? {
        invoke(#selector(CobbleScriptBridge.closeTab(_:)))
    }
}
