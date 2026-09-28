import AppKit
import XCTest
@testable import Cobble

final class AppleWebAuthTests: XCTestCase {
    private let authorize = URL(string: "https://appleid.apple.com/auth/authorize?client_id=com.x.web&redirect_uri=https%3A%2F%2Fx.com%2Fcallback&response_type=code%20id_token&response_mode=fragment&state=s1")!

    func testParsesAuthorizeURLAndRejectsLookalikes() throws {
        let request = try XCTUnwrap(AppleSignIn.request(from: authorize))
        XCTAssertEqual(request.clientID, "com.x.web")
        XCTAssertEqual(request.redirectURI.absoluteString, "https://x.com/callback")

        XCTAssertNil(AppleSignIn.request(from: URL(string: "http://appleid.apple.com/auth/authorize?client_id=a&redirect_uri=https://x.com/c")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://evil.example/auth/authorize?client_id=a&redirect_uri=https://x.com/c")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/account")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/auth/authorize-evil?client_id=a&redirect_uri=https://x.com/c")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://user@appleid.apple.com/auth/authorize?client_id=a&redirect_uri=https://x.com/c")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://appleid.apple.com:444/auth/authorize?client_id=a&redirect_uri=https://x.com/c")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/auth/authorize?client_id=a&redirect_uri=javascript:alert(1)")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/auth/authorize?client_id=a&client_id=b&redirect_uri=https://x.com/c")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/auth/authorize?client_id=a&redirect_uri=https://user@x.com/c")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/auth/authorize?client_id=a&redirect_uri=https%3A%2F%2Fx.com%3A70000%2Fc")!))
        XCTAssertNil(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/auth/authorize?redirect_uri=https://x.com/c")!))
    }

    func testOnlyURLResponseModesLeaveChromium() throws {
        var components = try XCTUnwrap(URLComponents(url: authorize, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems).filter { $0.name != "response_mode" }
        for mode in ["query", "fragment"] {
            components.queryItems = items + [URLQueryItem(name: "response_mode", value: mode)]
            XCTAssertNotNil(AppleSignIn.request(from: try XCTUnwrap(components.url)))
        }
        for mode in [nil, "form_post", "web_message", "", "unknown"] as [String?] {
            components.queryItems = items + (mode.map { [URLQueryItem(name: "response_mode", value: $0)] } ?? [])
            XCTAssertNil(AppleSignIn.request(from: try XCTUnwrap(components.url)),
                         "Must preserve Chromium's POST body, cookies and popup opener")
        }
        components.queryItems = items + [URLQueryItem(name: "response_mode", value: "query"),
                                         URLQueryItem(name: "response_mode", value: "form_post")]
        XCTAssertNil(AppleSignIn.request(from: try XCTUnwrap(components.url)))
    }

    func testCallbackMustMatchRedirectAndCarryACredential() throws {
        let request = try XCTUnwrap(AppleSignIn.request(from: authorize))
        XCTAssertEqual(
            AppleSignIn.callback(from: URL(string: "https://x.com/callback?code=abc&state=s1")!, for: request)?.absoluteString,
            "https://x.com/callback?code=abc&state=s1")
        XCTAssertNotNil(AppleSignIn.callback(from: URL(string: "https://x.com/callback#error=user_cancelled&state=s1")!, for: request))
        XCTAssertNotNil(AppleSignIn.callback(from: URL(string: "https://x.com/callback#id_token=tok&state=s1")!, for: request))
        XCTAssertNil(AppleSignIn.callback(from: URL(string: "https://x.com/callback")!, for: request))
        XCTAssertNil(AppleSignIn.callback(from: URL(string: "https://evil.example/callback?code=abc")!, for: request))
        XCTAssertNil(AppleSignIn.callback(from: URL(string: "https://x.com/other?code=abc")!, for: request))
        XCTAssertNil(AppleSignIn.callback(from: URL(string: "https://user@x.com/callback?code=abc&state=s1")!, for: request))

        let stateful = try XCTUnwrap(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/auth/authorize?client_id=a&redirect_uri=https%3A%2F%2Fx.com%2Fc%3Ftenant%3Done&state=expected&response_mode=query")!))
        XCTAssertNotNil(AppleSignIn.callback(from: URL(string: "https://x.com/c?tenant=one&code=abc&state=expected")!, for: stateful))
        XCTAssertNil(AppleSignIn.callback(from: URL(string: "https://x.com/c?tenant=one&code=abc&state=wrong")!, for: stateful))
        XCTAssertNil(AppleSignIn.callback(from: URL(string: "https://x.com/c?code=abc&state=expected")!, for: stateful))
        XCTAssertNil(AppleSignIn.callback(from: URL(string: "https://x.com/c?tenant=one&tenant=two&code=abc&state=expected")!, for: stateful))

        let injected = try XCTUnwrap(AppleSignIn.request(from: URL(string: "https://appleid.apple.com/auth/authorize?client_id=a&redirect_uri=https%3A%2F%2Fx.com%2Fc%3Fcode%3Dfixed%26state%3Dexpected&state=expected&response_mode=query")!))
        XCTAssertNil(AppleSignIn.callback(from: injected.redirectURI, for: injected))
    }

    func testNavigationAllowlistStaysOnAppleUntilCallback() throws {
        let request = try XCTUnwrap(AppleSignIn.request(from: authorize))
        XCTAssertTrue(AppleSignIn.allowsNavigation(authorize, for: request))
        XCTAssertTrue(AppleSignIn.allowsNavigation(URL(string: "https://idmsa.apple.com/appleauth/auth/signin")!, for: request))
        XCTAssertTrue(AppleSignIn.allowsNavigation(URL(string: "https://x.com/callback?code=abc&state=s1")!, for: request))
        XCTAssertFalse(AppleSignIn.allowsNavigation(URL(string: "https://x.com/")!, for: request))
        XCTAssertFalse(AppleSignIn.allowsNavigation(URL(string: "http://appleid.apple.com/auth/authorize")!, for: request))
        XCTAssertFalse(AppleSignIn.allowsNavigation(URL(string: "https://user@appleid.apple.com/auth/authorize")!, for: request))
        XCTAssertFalse(AppleSignIn.allowsNavigation(URL(string: "https://appleid.apple.com:444/auth/authorize")!, for: request))
    }

    @MainActor func testSignInDefersPreparationAndCanCancelBeforePresentation() async throws {
        let request = try XCTUnwrap(AppleSignIn.request(from: authorize))
        var prepared = false
        var completions = 0
        let session = AppleSignInSession.start(request: request, window: nil, prepare: {
            prepared = true
            return false
        }) { callback in
            XCTAssertNil(callback)
            completions += 1
        }
        XCTAssertFalse(prepared, "Must not stop Chromium from inside its navigation callback")
        session.cancel()
        session.cancel()
        await nextMainQueueTurn()
        XCTAssertFalse(prepared)
        XCTAssertEqual(completions, 1)
    }

    @MainActor func testSignInPreparationCanCancelReentrantly() async throws {
        let request = try XCTUnwrap(AppleSignIn.request(from: authorize))
        var session: AppleSignInSession?
        var completions = 0
        var prepared = false
        session = AppleSignInSession.start(request: request, window: nil, prepare: {
            prepared = true
            session?.cancel()
            return true
        }) { _ in completions += 1 }
        XCTAssertFalse(prepared)
        await nextMainQueueTurn()
        XCTAssertTrue(prepared)
        XCTAssertEqual(completions, 1)
        session?.cancel()
        XCTAssertEqual(completions, 1)
    }

    @MainActor func testSignInWindowDoesNotBlockParentAndIsRemovedOnCancel() async {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        // No account or network: exercise the real panel with an inert document.
        let request = AppleSignIn.Request(url: URL(string: "about:blank")!, clientID: "fixture",
                                          redirectURI: URL(string: "https://example.invalid/callback")!, state: nil)
        let session = AppleSignInSession.start(request: request, window: parent, prepare: { true }) { _ in }
        await nextMainQueueTurn()
        XCTAssertNil(parent.attachedSheet)
        let panel = parent.childWindows?.first
        XCTAssertNotNil(panel)
        panel?.performClose(nil)
        session.cancel()
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
        XCTAssertFalse(panel?.isVisible ?? false)
    }

    @MainActor private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor func testPasskeyPrepareIsNoOpWithoutEntitlement() {
        ApplePasskeys.prepareIfNeeded()
        XCTAssertFalse(BrowserEntitlements.hasPasskeys)
        XCTAssertFalse(BrowserEntitlements.hasWebBrowser)
    }
}
