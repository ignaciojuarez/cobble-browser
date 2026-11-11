import XCTest
import WebKit
@testable import Cobble

@MainActor
final class ContentBlockerTests: XCTestCase {
    private let json = #"[{"trigger":{"url-filter":"ads\\.example"},"action":{"type":"block"}}]"#

    private func withStore(body: (WebKitContentBlocker, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleBlockerTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WebKitContentBlocker(directory: directory)
        XCTAssertNil(store.lastError)
        try await body(store, directory)
    }

    private func eventually(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw EngineError.notReady("Timed out waiting for the local blocker fixture.")
    }

    func testCompilerProducesProfileScopedRulesAndEnabledState() async throws {
        try await withStore { store, _ in
            let profile = UUID(), other = UUID()
            XCTAssertFalse(store.isEnabled(profileID: profile))
            await store.importRules(json: json, profileID: profile)
            XCTAssertNil(store.lastError)
            let list = try XCTUnwrap(store.rules(for: profile))
            XCTAssertTrue(store.isEnabled(profileID: profile))
            XCTAssertNil(store.rules(for: other))
            let revision = store.revision
            await store.setEnabled(false, profileID: profile)
            XCTAssertFalse(store.isEnabled(profileID: profile))
            XCTAssertNil(store.rules(for: profile))
            XCTAssertGreaterThan(store.revision, revision)
            await store.setEnabled(true, profileID: profile)
            XCTAssertTrue(store.rules(for: profile) === list)
        }
    }

    func testBundledRulesAreLimitedAndDoNotReplaceExistingRules() async throws {
        try await withStore { store, _ in
            let profile = UUID()
            await store.installBundledRules(profileID: profile)
            XCTAssertTrue(store.isEnabled(profileID: profile))
            XCTAssertNotNil(store.rules(for: profile))
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(WebKitContentBlocker.bundledRules.utf8)) as? [[String: Any]])
            let filters = try rules.map { try XCTUnwrap($0["trigger"] as? [String: Any]) }.compactMap { $0["url-filter"] as? String }
            XCTAssertEqual(filters.count, 3)
            let expressions = try filters.map { try NSRegularExpression(pattern: $0) }
            for value in ["https://doubleclick.net/fixture.js", "https://google-analytics.com/fixture.js",
                          "https://doubleclick.net", "https://doubleclick.net?x=1", "https://doubleclick.net#part"] {
                XCTAssertTrue(expressions.contains { $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil })
            }
            let doubleClick = expressions[0]
            for value in ["http://sub.doubleclick.net:8443/fixture.js", "https://user:pass@doubleclick.net/fixture.js"] {
                XCTAssertNotNil(doubleClick.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)))
            }
            for value in ["https://notdoubleclick.net/fixture.js", "https://doubleclick.net.evil/fixture.js",
                          "https://content.example/path/doubleclick.net/fixture.js", "https://evil.example/?next=doubleclick.net"] {
                XCTAssertNil(doubleClick.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)))
            }

            await store.importRules(json: json, profileID: profile)
            await store.setEnabled(false, profileID: profile)
            await store.installBundledRules(profileID: profile)
            XCTAssertFalse(store.isEnabled(profileID: profile))
            XCTAssertNotNil(store.lastError)
        }
    }

    func testFirstNormalPageInstallsBaselineWithoutChangingConfiguredRules() async throws {
        try await withStore { blocker, directory in
            let profile = UUID()
            let context = WebKitContext(id: .init(engineID: .webKit, profileID: profile, privateWindowID: nil), dataStore: .nonPersistent(),
                                        blocker: blocker, siteSettings: SiteSettingsStore(directory: directory), extensionSession: nil)
            let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), profileID: profile, context: context) { _, _, _ in }
            defer { page.close() }
            // The window skips prepare() for ready pages, so an unconfigured profile must not start ready.
            XCTAssertEqual(page.state.lifecycle, .preparing)
            try await page.prepare()
            XCTAssertEqual(page.state.lifecycle, .ready)
            XCTAssertTrue(blocker.hasRules(profileID: profile))
            XCTAssertTrue(blocker.isEnabled(profileID: profile))
            XCTAssertNotNil(blocker.rules(for: profile))

            await blocker.setEnabled(false, profileID: profile)
            let later = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), profileID: profile, context: context) { _, _, _ in }
            defer { later.close() }
            XCTAssertEqual(later.state.lifecycle, .ready)
            try await later.prepare()
            XCTAssertFalse(blocker.isEnabled(profileID: profile))

            let second = UUID()
            let secondContext = WebKitContext(id: .init(engineID: .webKit, profileID: second, privateWindowID: nil), dataStore: .nonPersistent(),
                                              blocker: blocker, siteSettings: SiteSettingsStore(directory: directory), extensionSession: nil)
            let secondPage = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), profileID: second, context: secondContext) { _, _, _ in }
            defer { secondPage.close() }
            try await secondPage.prepare()
            XCTAssertTrue(blocker.hasRules(profileID: second))
        }
    }

    func testPrivateFirstPageDoesNotPersistBaselineUntilNormalPage() async throws {
        try await withStore { blocker, directory in
            let profile = UUID()
            let context = WebKitContext(id: .init(engineID: .webKit, profileID: profile, privateWindowID: UUID()), dataStore: .nonPersistent(),
                                        blocker: blocker, siteSettings: SiteSettingsStore(directory: directory), extensionSession: nil)
            let privatePage = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), profileID: profile, isPrivate: true, context: context) { _, _, _ in }
            defer { privatePage.close() }
            try await privatePage.prepare()
            XCTAssertFalse(blocker.hasRules(profileID: profile))

            let normalPage = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), profileID: profile, context: context) { _, _, _ in }
            defer { normalPage.close() }
            try await normalPage.prepare()
            XCTAssertTrue(blocker.hasRules(profileID: profile))
        }
    }

    func testFirstUseDoesNotOverlayUnreadableBlockerStorage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleBlockerReadOnly-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = directory.appendingPathComponent("content-blockers.json", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        let blocker = WebKitContentBlocker(directory: directory)
        let profile = UUID()
        let context = WebKitContext(id: .init(engineID: .webKit, profileID: profile, privateWindowID: nil), dataStore: .nonPersistent(),
                                    blocker: blocker, siteSettings: SiteSettingsStore(directory: directory), extensionSession: nil)
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), profileID: profile, context: context) { _, _, _ in }
        defer { page.close() }
        try await page.prepare()
        XCTAssertFalse(blocker.hasRules(profileID: profile))
        XCTAssertNotNil(blocker.lastError)
        let isDirectory = try metadata.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        XCTAssertTrue(isDirectory == true)
    }

    func testNativeRuleFixtureBlocksOnlyMatchedLocalResource() async throws {
        let server = try LocalHTTPFixture { request in
            switch request.path {
            case "/blocked.js": .init(headers: ["Content-Type": "application/javascript"], body: "document.title = 'blocked';")
            case "/allowed.js": .init(headers: ["Content-Type": "application/javascript"], body: "document.title = 'allowed';")
            default: .init(body: "<title>pending</title><script src='/blocked.js'></script><script src='/allowed.js'></script>")
            }
        }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleNativeBlocker-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let compiled = try await compiler.compileContentRuleList(forIdentifier: "fixture",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"blocked\\.js"},"action":{"type":"block"}}]"#)
        let list = try XCTUnwrap(compiled)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(list)
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), configuration: configuration) { _, _, _ in }
        defer { page.close() }
        page.navigate(to: server.url("/index"))
        try await eventually { page.webView.title == "allowed" && !page.webView.isLoading }
        XCTAssertFalse(server.requests.contains { $0.path == "/blocked.js" })
        XCTAssertTrue(server.requests.contains { $0.path == "/allowed.js" })
    }

    func testUpdateSourcesRequireExplicitHTTPSAndKeepRulesOnFailure() async throws {
        try await withStore { store, directory in
            let profile = UUID()
            await store.importRules(json: json, profileID: profile)
            let original = try XCTUnwrap(store.rules(for: profile))
            await store.setUpdateSource(URL(string: "http://fixture.invalid/rules.json"), profileID: profile)
            XCTAssertNotNil(store.lastError)
            XCTAssertNil(store.updateSource(profileID: profile))

            let source = try XCTUnwrap(URL(string: "https://127.0.0.1:1/rules.json"))
            await store.setUpdateSource(source, profileID: profile)
            XCTAssertEqual(store.updateSource(profileID: profile), source)
            XCTAssertEqual(WebKitContentBlocker(directory: directory).updateSource(profileID: profile), source)
            await store.setUpdateSource(URL(string: "not-a-url"), profileID: profile)
            XCTAssertNotNil(store.lastError)
            XCTAssertEqual(store.updateSource(profileID: profile), source)
            await store.updateRules(profileID: profile)
            XCTAssertNotNil(store.lastError)
            XCTAssertTrue(store.rules(for: profile) === original)
            XCTAssertEqual(store.updateSource(profileID: profile), source)
        }
    }

    func testExplicitUpdateRejectsRedirectBeforeContactingTarget() async throws {
        let target = try LocalHTTPFixture { _ in
            .init(headers: ["Content-Type": "application/json"], body: "[]")
        }
        try await target.start()
        defer { target.stop() }
        let source = try LocalHTTPFixture { _ in
            .init(status: "302 Found", headers: ["Location": target.url("/rules.json").absoluteString])
        }
        try await source.start()
        defer { source.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let followingSession = URLSession(configuration: configuration)
        defer { followingSession.invalidateAndCancel() }
        let (data, response) = try await followingSession.data(from: source.url("/rules.json"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data("[]".utf8))
        XCTAssertEqual(target.requests.count, 1)
        let sourceCount = source.requests.count
        let targetCount = target.requests.count
        do {
            _ = try await WebKitContentBlocker.downloadRules(from: source.url("/rules.json"), configuration: configuration)
            XCTFail("Redirected sources must fail.")
        } catch EngineError.notReady(let message) {
            XCTAssertEqual(message, "The update source did not return its selected HTTPS address.")
        } catch {
            XCTFail("Expected an explicit redirect rejection, not \(error)")
        }
        XCTAssertEqual(source.requests.count, sourceCount + 1)
        XCTAssertEqual(target.requests.count, targetCount)
    }

    func testUpdateSourcesStayScopedToTheirProfile() async throws {
        try await withStore { store, _ in
            let first = UUID(), second = UUID()
            await store.importRules(json: json, profileID: first)
            await store.importRules(json: json, profileID: second)
            let firstSource = try XCTUnwrap(URL(string: "https://first.fixture/rules.json"))
            let secondSource = try XCTUnwrap(URL(string: "https://second.fixture/rules.json"))
            await store.setUpdateSource(firstSource, profileID: first)
            await store.setUpdateSource(secondSource, profileID: second)
            XCTAssertEqual(store.updateSource(profileID: first), firstSource)
            XCTAssertEqual(store.updateSource(profileID: second), secondSource)
        }
    }

    func testInvalidCompilationKeepsWorkingRulesAndMetadata() async throws {
        try await withStore { store, directory in
            let profile = UUID()
            await store.importRules(json: json, profileID: profile)
            let original = try XCTUnwrap(store.rules(for: profile))
            let url = directory.appendingPathComponent("content-blockers.json")
            let metadata = try Data(contentsOf: url)
            let revision = store.revision
            await store.importRules(json: #"[{"trigger":{"url-filter":"["},"action":{"type":"block"}}]"#, profileID: profile)
            XCTAssertNotNil(store.lastError)
            XCTAssertTrue(store.rules(for: profile) === original)
            XCTAssertEqual(store.revision, revision)
            XCTAssertEqual(try Data(contentsOf: url), metadata)
            await store.importRules(json: "{}", profileID: profile)
            XCTAssertNotNil(store.lastError)
            XCTAssertTrue(store.rules(for: profile) === original)
            await store.importRules(json: String(repeating: " ", count: 1_000_001), profileID: profile)
            XCTAssertNotNil(store.lastError)
            XCTAssertTrue(store.rules(for: profile) === original)
        }
    }

    func testExactOriginExceptionsCompileAndDoNotMatchSiblingOrigins() async throws {
        try await withStore { store, _ in
            let profile = UUID()
            await store.importRules(json: json, profileID: profile)
            await store.setException(origin: URL(string: "HTTPS://EXAMPLE.COM:443/path?q=1")!, enabled: true, profileID: profile)
            XCTAssertNil(store.lastError)
            XCTAssertNotNil(store.rules(for: profile))
            XCTAssertEqual(store.exceptions(profileID: profile), ["https://example.com"])
            let patterns = try WebKitContentBlocker.exceptionPatterns(origin: "https://example.com").map { try NSRegularExpression(pattern: $0) }
            for value in ["https://example.com", "https://example.com/", "https://example.com/path?q=1", "https://example.com?query=1"] {
                XCTAssertTrue(patterns.contains { $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil })
            }
            for value in ["http://example.com/", "https://sub.example.com/", "https://example.com.evil/", "https://example.com:8443/", "https://exampleXcom/", "https://other.example/path/https://example.com/"] {
                XCTAssertFalse(patterns.contains { $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil })
            }
            await store.setException(origin: URL(string: "https://example.com/else")!, enabled: true, profileID: profile)
            XCTAssertEqual(store.exceptions(profileID: profile).count, 1)
            await store.setException(origin: URL(string: "https://example.com")!, enabled: false, profileID: profile)
            XCTAssertTrue(store.exceptions(profileID: profile).isEmpty)
            XCTAssertNil(store.lastError)
        }
    }

    func testPersistenceRestoresRulesAndExceptions() async throws {
        try await withStore { store, directory in
            let profile = UUID()
            await store.importRules(json: json, profileID: profile)
            await store.setException(origin: URL(string: "https://example.com:8443")!, enabled: true, profileID: profile)
            await store.setEnabled(false, profileID: profile)
            let reopened = WebKitContentBlocker(directory: directory)
            XCTAssertFalse(reopened.isReady)
            XCTAssertFalse(reopened.isEnabled(profileID: profile))
            XCTAssertEqual(reopened.exceptions(profileID: profile), ["https://example.com:8443"])
            await reopened.waitUntilReady()
            XCTAssertTrue(reopened.isReady)
            await reopened.setEnabled(true, profileID: profile)
            XCTAssertNil(reopened.lastError)
            XCTAssertNotNil(reopened.rules(for: profile))
        }
    }

    func testReplacementsRemoveOldCompiledCacheEntries() async throws {
        try await withStore { store, directory in
            let profile = UUID()
            await store.importRules(json: json, profileID: profile)
            await store.importRules(json: #"[{"trigger":{"url-filter":"tracker"},"action":{"type":"block"}}]"#, profileID: profile)
            await store.setException(origin: URL(string: "https://example.com")!, enabled: true, profileID: profile)
            let cache = try XCTUnwrap(WKContentRuleListStore(url: directory.appendingPathComponent("ContentRuleLists")))
            let identifiers = await cache.availableIdentifiers() ?? []
            XCTAssertEqual(identifiers.count, 1)
            XCTAssertEqual(identifiers.first, store.rules(for: profile)?.identifier)
        }
    }

    func testProfileRemovalDeletesOnlyThatProfilesRules() async throws {
        try await withStore { store, directory in
            let profile = UUID(), other = UUID()
            await store.importRules(json: json, profileID: profile)
            await store.importRules(json: #"[{"trigger":{"url-filter":"tracker"},"action":{"type":"block"}}]"#, profileID: other)
            try await store.removeProfile(profile)
            XCTAssertFalse(store.isEnabled(profileID: profile))
            XCTAssertNil(store.rules(for: profile))
            XCTAssertTrue(store.isEnabled(profileID: other))
            let reopened = WebKitContentBlocker(directory: directory)
            await reopened.waitUntilReady()
            XCTAssertFalse(reopened.isEnabled(profileID: profile))
            XCTAssertTrue(reopened.isEnabled(profileID: other))
        }
    }

    func testMetadataWriteFailurePreservesLiveRules() async throws {
        try await withStore { store, directory in
            let profile = UUID()
            await store.importRules(json: json, profileID: profile)
            let original = try XCTUnwrap(store.rules(for: profile))
            let metadata = directory.appendingPathComponent("content-blockers.json")
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            await store.setException(origin: URL(string: "https://example.com")!, enabled: true, profileID: profile)
            XCTAssertNotNil(store.lastError)
            XCTAssertTrue(store.rules(for: profile) === original)
            XCTAssertTrue(store.exceptions(profileID: profile).isEmpty)
        }
    }

    func testCorruptAndFutureConfigurationsArePreservedAndCannotBeOverwritten() async throws {
        for input in ["{broken", "{\"version\":999,\"configurations\":[]}"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleBlockerCorruptTests-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("content-blockers.json")
            let data = Data(input.utf8)
            try data.write(to: source)
            let store = WebKitContentBlocker(directory: directory)
            XCTAssertNotNil(store.lastError)
            let profile = UUID()
            await store.importRules(json: json, profileID: profile)
            await store.setEnabled(true, profileID: profile)
            await store.setException(origin: URL(string: "https://example.com")!, enabled: true, profileID: profile)
            XCTAssertEqual(try Data(contentsOf: source), data)
            XCTAssertNil(store.rules(for: profile))
            let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".corrupt-") }
            XCTAssertEqual(preserved.count, 1)
            XCTAssertEqual(try Data(contentsOf: preserved[0]), data)
        }
    }

    private func youTubeFixture(exceptions: [String], at address: String) async throws -> [String: Any] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: YouTubeAdBlock.script(exceptions: exceptions),
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString(#"""
            <title>pending</title>
            <ytd-rich-item-renderer id="ad"><div id="content"><ytd-ad-slot-renderer></ytd-ad-slot-renderer></div></ytd-rich-item-renderer>
            <ytd-rich-item-renderer id="video"><div id="content">Video</div></ytd-rich-item-renderer>
            <script>
            var ytInitialPlayerResponse = {"adPlacements": [1], "playerAds": [1], "adSlots": [1], "videoDetails": {"videoId": "v"}};
            const parsed = JSON.parse('{"playerResponse": {"adPlacements": [1], "streamingData": {}}, "entries": [' +
                '{"command": {"reelWatchEndpoint": {"adClientParams": {"isAd": true}}}}, {"command": {"reelWatchEndpoint": {}}}]}');
            const response = new Response('[{"playerResponse": {"adSlots": [1], "videoDetails": {}}}]');
            Object.defineProperty(response, 'url', { value: location.origin + '/youtubei/v1/get_watch?prettyPrint=false' });
            response.json().then(parts => {
                window.results = JSON.stringify({
                    initial: 'adPlacements' in ytInitialPlayerResponse || 'playerAds' in ytInitialPlayerResponse || 'adSlots' in ytInitialPlayerResponse,
                    video: ytInitialPlayerResponse.videoDetails.videoId,
                    parsed: 'adPlacements' in parsed.playerResponse, streaming: 'streamingData' in parsed.playerResponse,
                    shorts: parsed.entries.length, fetched: 'adSlots' in parts[0].playerResponse,
                    hidden: getComputedStyle(document.getElementById('ad')).display === 'none',
                    shown: getComputedStyle(document.getElementById('video')).display !== 'none'
                });
                document.title = 'done';
            });
            </script>
            """#, baseURL: URL(string: address))
        try await eventually { view.title == "done" }
        let results = try await view.evaluateJavaScript("window.results") as? String
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(results).utf8)) as? [String: Any])
    }

    func testYouTubeScriptRemovesPlayerAdsAndHidesAdSlotsOnlyOnYouTube() async throws {
        let blocked = try await youTubeFixture(exceptions: [], at: "https://www.youtube.com/watch?v=v")
        XCTAssertEqual(blocked["initial"] as? Bool, false)
        XCTAssertEqual(blocked["video"] as? String, "v")
        XCTAssertEqual(blocked["parsed"] as? Bool, false)
        XCTAssertEqual(blocked["streaming"] as? Bool, true)
        XCTAssertEqual(blocked["shorts"] as? Int, 1)
        XCTAssertEqual(blocked["fetched"] as? Bool, false)
        XCTAssertEqual(blocked["hidden"] as? Bool, true)
        XCTAssertEqual(blocked["shown"] as? Bool, true)

        for (exceptions, address) in [([], "https://example.com/watch"), (["https://www.youtube.com"], "https://www.youtube.com/watch?v=v")] {
            let untouched = try await youTubeFixture(exceptions: exceptions, at: address)
            XCTAssertEqual(untouched["initial"] as? Bool, true, address)
            XCTAssertEqual(untouched["parsed"] as? Bool, true, address)
            XCTAssertEqual(untouched["shorts"] as? Int, 2, address)
            XCTAssertEqual(untouched["fetched"] as? Bool, true, address)
            XCTAssertEqual(untouched["hidden"] as? Bool, false, address)
        }
    }

    func testYouTubeScriptFollowsBlockerStateAndKeepsOtherUserScripts() async throws {
        try await withStore { blocker, directory in
            let profile = UUID()
            let context = WebKitContext(id: .init(engineID: .webKit, profileID: profile, privateWindowID: nil), dataStore: .nonPersistent(),
                                        blocker: blocker, siteSettings: SiteSettingsStore(directory: directory), extensionSession: nil)
            let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), profileID: profile, context: context) { _, _, _ in }
            defer { page.close() }
            try await page.prepare()
            let controller = page.webView.configuration.userContentController
            let isYouTube = { (script: WKUserScript) in script.source.contains("ytInitialPlayerResponse") }
            let others = controller.userScripts.filter { !isYouTube($0) }
            XCTAssertFalse(others.isEmpty)
            XCTAssertEqual(controller.userScripts.filter(isYouTube).count, 1)

            await blocker.setException(origin: try XCTUnwrap(URL(string: "https://www.youtube.com")), enabled: true, profileID: profile)
            page.applyContentRules()
            let excepted = controller.userScripts.filter(isYouTube)
            XCTAssertEqual(excepted.count, 1)
            XCTAssertTrue(excepted[0].source.contains(#"["https:\/\/www.youtube.com"]"#))
            XCTAssertEqual(controller.userScripts.filter { !isYouTube($0) }.map(\.source), others.map(\.source))

            await blocker.setEnabled(false, profileID: profile)
            page.applyContentRules()
            XCTAssertEqual(controller.userScripts.map(\.source), others.map(\.source))
        }
    }
}
