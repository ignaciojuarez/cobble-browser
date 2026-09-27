import AppKit
import WebKit

/// Loads a Sign in with Apple authorize URL in WKWebView so Chromium can get
/// the system sheet (when entitled) and return the website callback URL.
@MainActor
final class AppleSignInSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private static var live: [AppleSignInSession] = []

    @discardableResult
    static func start(request: AppleSignIn.Request, window: NSWindow?, prepare: @escaping () -> Bool, completion: @escaping (URL?) -> Void) -> AppleSignInSession {
        let session = AppleSignInSession(request: request, completion: completion)
        live.append(session)
        // Chromium's page-change callback can run inside navigation setup. Never
        // stop that navigation or present AppKit UI until its stack has unwound.
        DispatchQueue.main.async { [weak window] in
            guard !session.finished else { return }
            guard prepare() else { session.cancel(); return }
            guard !session.finished else { return }
            session.show(on: window)
        }
        return session
    }

    func cancel() { finish(nil) }

    private let request: AppleSignIn.Request
    private let completion: (URL?) -> Void
    private var finished = false
    private var panel: NSPanel?
    private var webView: WKWebView?

    private init(request: AppleSignIn.Request, completion: @escaping (URL?) -> Void) {
        self.request = request
        self.completion = completion
    }

    private func show(on window: NSWindow?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        WebKitPage.applySafariCompatibleUserAgent(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        let panel = NSPanel(contentRect: webView.frame, styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = String(localized: "Sign in with Apple")
        panel.isReleasedWhenClosed = false
        panel.contentView = webView
        panel.delegate = self
        self.panel = panel
        webView.load(URLRequest(url: request.url))
        if let window {
            panel.setFrameOrigin(NSPoint(x: window.frame.midX - panel.frame.width / 2,
                                         y: window.frame.midY - panel.frame.height / 2))
            window.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if let callback = AppleSignIn.callback(from: url, for: request) {
            decisionHandler(.cancel)
            finish(callback)
            return
        }
        decisionHandler(AppleSignIn.allowsNavigation(url, for: request) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, AppleSignIn.allowsNavigation(url, for: request) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(nil) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(nil) }
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ url: URL?) {
        guard !finished else { return }
        finished = true
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        if let panel {
            panel.delegate = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        webView = nil
        Self.live.removeAll { $0 === self }
        completion(url)
    }
}
