import SwiftUI

struct BrowserPageView: NSViewRepresentable {
    let host: any BrowserPage

    func makeNSView(context: Context) -> BrowserPageContainer {
        let container = BrowserPageContainer()
        container.mount(host)
        return container
    }

    func updateNSView(_ container: BrowserPageContainer, context: Context) {
        container.mount(host)
    }

    static func dismantleNSView(_ container: BrowserPageContainer, coordinator: ()) {
        container.unmount()
    }
}

/// Selection is reported after AppKit attaches the retained page to a window.
/// A former SwiftUI host cannot deactivate a page that has already moved.
@MainActor final class BrowserPageContainer: NSView {
    private var host: (any BrowserPage)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)),
                                                       name: name, object: window)
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(activationChanged(_:)),
                                                       name: name, object: window)
            }
        }
        if let host, host.nativeView.superview === self {
            diagnose("viewDidMoveToWindow")
            host.setActive(window != nil)
        }
        updateVisibility(event: "viewDidMoveToWindow")
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        updateVisibility(event: notification.name.rawValue)
    }

    @objc private func activationChanged(_ notification: Notification) {
        diagnose(notification.name.rawValue)
    }

    private func updateVisibility(event: String) {
        guard let host, host.nativeView.superview === self else { return }
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        VisibilityDiagnostics.log(event, owner: owner(host), view: host.nativeView, window: window, visible: visible)
        host.setVisible(visible)
    }

    private func diagnose(_ event: String) {
        guard let host else { return }
        VisibilityDiagnostics.log(event, owner: owner(host), view: host.nativeView, window: window)
    }

    private func owner(_ host: any BrowserPage) -> String {
        "target tab=\(host.tabID.uuidString) context=\(host.contextID.engineID.rawValue):\(host.contextID.profileID.uuidString)"
    }

    func mount(_ host: any BrowserPage) {
        let page = host.nativeView
        guard self.host !== host || page.superview !== self else { return }
        unmount()
        (page.superview as? BrowserPageContainer)?.unmount()
        page.removeFromSuperview()
        self.host = host
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
        diagnose("mount")
        host.setActive(window != nil)
        updateVisibility(event: "mount")
    }

    func unmount() {
        // The tab retains its page while deselected; only BrowserPage.close destroys it.
        if let host, host.nativeView.superview === self {
            VisibilityDiagnostics.log("unmount", owner: owner(host), view: host.nativeView, window: window, visible: false)
            host.setVisible(false)
            host.setActive(false)
            host.nativeView.removeFromSuperview()
        }
        host = nil
    }
}
