import WebKit
import ObjectiveC

/// Runtime-checked WebKit SPI for getDisplayMedia. WKWebView has no public
/// display-capture API, and without this delegate WebKit skips Cobble and opens
/// the stock macOS picker. Keep it adapter-local, like `WebKitAudioMute`.
@MainActor enum WebKitDisplayCapture {
    /// `WKDisplayCapturePermissionDecision`: WebKit then shows the macOS picker for that surface.
    enum Decision: Int { case deny = 0, screen = 1, window = 2 }

    /// What this WebKit offers. Anything short of `full` fails closed with `NotAllowedError`:
    /// `denyOnly` answers through the delegate, `absent` through `failClosedScript`.
    enum Support { case full, denyOnly, absent }

    static let request = NSSelectorFromString(
        "_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:")
    static let stateChanged = NSSelectorFromString("_webView:mediaCaptureStateDidChange:")
    private static let setDisplay = NSSelectorFromString("_setDisplayCaptureState:completionHandler:")
    private static let setSystemAudio = NSSelectorFromString("_setSystemAudioCaptureState:completionHandler:")

    /// Probed once per process. Stopping and showing capture also needs the getters `WebKitAudioMute` checks.
    static let support: Support = {
        guard let delegate = objc_getProtocol("WKUIDelegatePrivate"),
              signature(protocol_getMethodDescription(delegate, request, false, true).types) == "v@:@@@B@?" else {
            return .absent
        }
        guard WebKitAudioMute.isAvailable,
              signature(protocol_getMethodDescription(delegate, stateChanged, false, true).types) == "v@:@Q",
              [setDisplay, setSystemAudio].allSatisfy({ selector in
                  signature(class_getInstanceMethod(WKWebView.self, selector).flatMap(method_getTypeEncoding)) == "v@:q@?"
              }) else { return .denyOnly }
        return .full
    }()

    /// Without the request delegate WebKit would open the stock picker, so pages see a refusal instead.
    static let failClosedScript = WKUserScript(source: """
        (() => {
          const devices = globalThis.MediaDevices?.prototype;
          if (!devices || typeof devices.getDisplayMedia !== "function") return;
          const { getDisplayMedia } = { getDisplayMedia() {
            return Promise.reject(new DOMException("Screen sharing is not available.", "NotAllowedError"));
          } };
          Object.defineProperty(devices, "getDisplayMedia", { value: getDisplayMedia, writable: true, enumerable: true, configurable: true });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// Ends window, screen and system-audio capture. Needs `full`. The completion runs on the main thread.
    static func stop(_ view: WKWebView, completion: @escaping () -> Void) {
        typealias Setter = @convention(c) (AnyObject, Selector, Int, (@convention(block) () -> Void)?) -> Void
        let display = unsafeBitCast(view.method(for: setDisplay), to: Setter.self)
        let audio = unsafeBitCast(view.method(for: setSystemAudio), to: Setter.self)
        audio(view, setSystemAudio, 0, nil)
        display(view, setDisplay, 0) { MainActor.assumeIsolated { completion() } }
    }

    /// The Objective-C type encoding without frame offsets, for example `v@:q@?`.
    private static func signature(_ types: UnsafePointer<CChar>?) -> String? {
        types.map { String(cString: $0).filter { !$0.isNumber } }
    }
}
