import AppKit

@MainActor enum VisibilityDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["COBBLE_VISIBILITY_DIAGNOSTICS"] == "1"

    static func log(_ event: String, owner: String, view: NSView?, window: NSWindow?, visible: Bool? = nil) {
        guard enabled else { return }
        let viewState = view.map {
            "view=\(ObjectIdentifier($0)) frame=\(NSStringFromRect($0.frame)) bounds=\(NSStringFromRect($0.bounds)) hidden=\($0.isHidden) super=\($0.superview.map { String(describing: ObjectIdentifier($0)) } ?? "nil") attached=\($0.window === window)"
        } ?? "view=nil"
        let windowState = window.map {
            let screen = $0.screen.map { "screen=\(NSStringFromRect($0.frame)) screenVisible=\(NSStringFromRect($0.visibleFrame))" } ?? "screen=nil"
            let order = NSApp.orderedWindows.firstIndex { $0 === window }.map(String.init) ?? "nil"
            return "window=\($0.windowNumber) frame=\(NSStringFromRect($0.frame)) visible=\($0.isVisible) occlusion=\($0.occlusionState.rawValue) key=\($0.isKeyWindow) main=\($0.isMainWindow) mini=\($0.isMiniaturized) sheet=\($0.attachedSheet != nil) activeSpace=\($0.isOnActiveSpace) level=\($0.level.rawValue) order=\(order) appActive=\(NSApp.isActive) appHidden=\(NSApp.isHidden) \(screen)"
        } ?? "window=nil"
        let requested = visible.map { " requestedVisible=\($0)" } ?? ""
        let line = "[CobbleVisibility] \(event) owner=\(owner) \(viewState) \(windowState)\(requested)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
