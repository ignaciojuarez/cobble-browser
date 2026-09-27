#if DEBUG && COBBLE_AUTH_FIXTURE
import AppKit
import WebKit
import Network

/// Compiled only for the isolated local HTTPS test runner, never regular builds.
@MainActor enum LoginSharingFixture {
    private static var root: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["COBBLE_AUTH_FIXTURE_ROOT"],
              environment["COBBLE_DATA_DIRECTORY"] == path + "/data" else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func dataStore() -> WKWebsiteDataStore? {
        guard let root,
              let text = try? String(contentsOf: root.appendingPathComponent("proxy-port.txt"), encoding: .utf8),
              let port = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)), port > 1023,
              let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: endpointPort))
        proxy.matchDomains = ["cobble.test"]
        store.proxyConfigurations = [proxy]
        return store
    }

    static func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard let root,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              ["app.cobble.test", "login.cobble.test"].contains(challenge.protectionSpace.host),
              challenge.protectionSpace.port == 443,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first,
              let expected = try? Data(contentsOf: root.appendingPathComponent("certificate.der")),
              SecCertificateCopyData(certificate) as Data == expected else { return nil }
        return URLCredential(trust: trust)
    }

    static func start(_ app: AppModel) {
        guard let root else { return }
        Task {
            var passed: [String] = []
            var report: [String: Any]
            do {
                try await exercise(app, passed: &passed)
                report = ["passed": passed]
            } catch {
                report = ["passed": passed, "error": error.localizedDescription]
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: root.appendingPathComponent("result.json"), options: .atomic)
            } catch { NSLog("Auth fixture could not write result") }
            NSApp.terminate(nil)
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func exercise(_ app: AppModel, passed: inout [String]) async throws {
        let chromium = EngineID(rawValue: "chromium")
        guard app.engines.engine(chromium)?.capabilities.supportsCookieTransfer == true,
              let window = app.windows.first else { throw Failure(message: "A Full ABI 14 fixture build is required") }
        window.confirmEngineSwitch = { _ in true }
        window.confirmLoginReplacement = { false }
        app.preferences.setExperimentalLoginSharing(false)
        let initial = UUID().uuidString
        window.addTab(url: URL(string: "https://app.cobble.test/whoami?probe=" + initial)!)
        try await wait(window, probe: initial, title: "guest")

        // Establish an independently logged-out Chromium destination.
        try await switchEngine(window, to: chromium, probe: initial, title: "guest", sharing: false)
        try await switchEngine(window, to: .webKit, probe: initial, title: "guest", sharing: false)
        _ = try await navigate(window, path: "/login?user=alice", title: "alice")
        var probe = try await navigate(window, path: "/whoami", title: "alice")
        try await switchEngine(window, to: chromium, probe: probe, title: "guest", sharing: false)
        try await switchEngine(window, to: .webKit, probe: probe, title: "alice", sharing: false)
        passed.append("opt-out preserves independent engine sessions")

        app.preferences.setExperimentalLoginSharing(true)
        probe = try await navigate(window, path: "/exercise", title: "action:alice")
        try await switchEngine(window, to: chromium, probe: probe, title: "action:alice")
        _ = try await navigate(window, path: "/whoami", title: "alice")
        passed.append("WebKit to Chromium: server identity and CSRF-protected action")

        _ = try await navigate(window, path: "/login?user=bob", title: "bob")
        probe = try await navigate(window, path: "/exercise", title: "action:bob")
        try await switchEngine(window, to: .webKit, probe: probe, title: "action:alice")
        _ = try await navigate(window, path: "/exercise", title: "action:alice")
        passed.append("existing WebKit Alice survives unapproved Chromium Bob transfer")

        probe = try await navigate(window, path: "/exercise", title: "action:alice")
        try await switchEngine(window, to: chromium, probe: probe, title: "action:bob")
        _ = try await navigate(window, path: "/exercise", title: "action:bob")
        passed.append("existing Chromium Bob survives unapproved WebKit Alice transfer")

        window.confirmLoginReplacement = { true }
        probe = try await navigate(window, path: "/exercise", title: "action:bob")
        try await switchEngine(window, to: .webKit, probe: probe, title: "action:bob")
        window.confirmLoginReplacement = { false }
        _ = try await navigate(window, path: "/exercise", title: "action:bob")
        passed.append("approved Chromium Bob replaces WebKit Alice with valid CSRF")

        _ = try await navigate(window, path: "/rotate", title: "rotated:bob")
        probe = try await navigate(window, path: "/exercise", title: "action:bob")
        window.confirmLoginReplacement = { true }
        try await switchEngine(window, to: chromium, probe: probe, title: "action:bob")
        window.confirmLoginReplacement = { false }
        passed.append("rotated session survives engine transfer")

        _ = try await navigate(window, path: "/local-logout", title: "guest")
        probe = try await navigate(window, path: "/whoami", title: "guest")
        try await switchEngine(window, to: .webKit, probe: probe, title: "bob")
        _ = try await navigate(window, path: "/exercise", title: "action:bob")
        passed.append("empty source preserves a still-valid destination login and CSRF")

        probe = try await navigate(window, path: "/whoami", title: "bob")
        try await switchEngine(window, to: chromium, probe: probe, title: "bob")
        try await switchEngine(window, to: .webKit, probe: probe, title: "bob")
        _ = try await navigate(window, path: "/logout", title: "guest")
        probe = try await navigate(window, path: "/whoami", title: "guest")
        try await switchEngine(window, to: chromium, probe: probe, title: "guest")
        passed.append("server logout leaves both engines signed out")

        try await switchEngine(window, to: .webKit, probe: probe, title: "guest")
        _ = try await navigate(window, path: "/login?user=alice&storage=1", title: "alice")
        probe = try await navigate(window, path: "/exercise", title: "action:alice")
        window.confirmLoginReplacement = { true }
        try await switchEngine(window, to: chromium, probe: probe, title: "action:denied")
        window.confirmLoginReplacement = { false }
        _ = try await navigate(window, path: "/whoami", title: "alice")
        passed.append("cookie transfer cannot satisfy a local-storage-bound session")
    }

    @discardableResult private static func navigate(_ window: BrowserWindowModel, path: String, title: String) async throws -> String {
        let probe = UUID().uuidString
        window.addressDraft = "https://app.cobble.test" + path + (path.contains("?") ? "&" : "?") + "probe=" + probe
        window.submitAddress()
        try await wait(window, probe: probe, title: title)
        return probe
    }

    private static func switchEngine(_ window: BrowserWindowModel, to engine: EngineID,
                                     probe: String, title: String, sharing: Bool = true) async throws {
        guard let tab = window.selectedTab else { throw Failure(message: "Missing fixture tab") }
        window.setEngine(engine, for: tab.id)
        let deadline = Date().addingTimeInterval(15)
        while window.selectedPage?.contextID.engineID != engine {
            guard Date() < deadline else { throw Failure(message: "Engine switch timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await wait(window, probe: probe, title: title)
        if sharing, window.addressError != nil { throw Failure(message: "Transfer warning: " + (window.addressError ?? "")) }
    }

    private static func wait(_ window: BrowserWindowModel, probe: String, title: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let page = window.selectedPage, !page.state.isLoading,
               let dom = try? await page.currentDOM(), dom.contains(probe),
               dom.contains("<title>fixture:" + title + "</title>") { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let state = window.selectedPage?.state
        throw Failure(message: "Page assertion timed out: \(title); engine=\(window.selectedPage?.contextID.engineID.rawValue ?? "none"); title=\(state?.title ?? "none"); pageError=\(state?.errorMessage ?? "none"); transfer=\(window.addressError ?? "none")")
    }
}
#endif
