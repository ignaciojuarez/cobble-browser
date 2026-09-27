import WebKit
import ObjectiveC

/// The user-approved WebKit SPI exception. Never substitute playback suspension.
/// The native setter also replaces capture flags, so it is only safe before capture.
@MainActor enum WebKitAudioMute {
    private static let muted = NSSelectorFromString("_mediaMutedState")
    private static let setMuted = NSSelectorFromString("_setPageMuted:")
    private static let audible = NSSelectorFromString("_isPlayingAudio")
    private static let display = NSSelectorFromString("_displayCaptureState")
    private static let systemAudio = NSSelectorFromString("_systemAudioCaptureState")

    static let isAvailable: Bool = {
        [(muted, "Q", 2), (setMuted, "v", 3), (audible, "B", 2),
         (display, "q", 2), (systemAudio, "q", 2)].allSatisfy { selector, result, count in
            guard let method = class_getInstanceMethod(WKWebView.self, selector),
                  method_getNumberOfArguments(method) == count else { return false }
            let type = method_copyReturnType(method)
            defer { free(type) }
            guard String(cString: type) == result else { return false }
            if selector == setMuted {
                guard let argument = method_copyArgumentType(method, 2) else { return false }
                defer { free(argument) }
                return String(cString: argument) == "Q"
            }
            return true
        }
    }()

    static func isMuted(_ view: WKWebView) -> Bool {
        isAvailable && unsignedValue(view, muted) & 1 != 0
    }

    // Source activity is measured before native output mute, including Web Audio.
    static func isPlayingAudio(_ view: WKWebView) -> Bool {
        guard isAvailable else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(view.method(for: audible), to: Getter.self)(view, audible)
    }

    static func isDisplayCapturing(_ view: WKWebView) -> Bool {
        isAvailable && (signedValue(view, display) != 0 || signedValue(view, systemAudio) != 0)
    }

    static func set(_ value: Bool, on view: WKWebView, hasCaptureHistory: Bool) throws {
        guard isAvailable else { throw EngineError.unsupported(String(localized: "tab audio muting on this WebKit version")) }
        let flags = unsignedValue(view, muted)
        guard (flags & 1 != 0) != value else { return }
        // Capture getters lose latent flags once a track ends; history must survive
        // stop/navigation too. Never round-trip the aggregate camera/microphone bit.
        guard !hasCaptureHistory, flags & ~UInt(1) == 0,
              view.cameraCaptureState == .none, view.microphoneCaptureState == .none,
              signedValue(view, display) == 0, signedValue(view, systemAudio) == 0 else {
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(view.method(for: setMuted), to: Setter.self)(view, setMuted, value ? 1 : 0)
        guard isMuted(view) == value else {
            throw EngineError.notReady(String(localized: "WebKit did not change this tab’s audio mute state."))
        }
    }

    private static func unsignedValue(_ view: WKWebView, _ selector: Selector) -> UInt {
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(view.method(for: selector), to: Getter.self)(view, selector)
    }

    private static func signedValue(_ view: WKWebView, _ selector: Selector) -> Int {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(view.method(for: selector), to: Getter.self)(view, selector)
    }
}
