import XCTest
@testable import Cobble

@MainActor final class LoginSharingTests: XCTestCase {
    private let url = URL(string: "https://login.example.test/account")!
    private let secondID = EngineID(rawValue: "test.cookies")

    func testCookieScopeRejectsNonstandardPortsAndLookalikeHosts() throws {
        XCTAssertThrowsError(try EngineCookie.host(for: URL(string: "https://login.example.test:8443")!))
        XCTAssertThrowsError(try EngineCookie.host(for: URL(string: "http://login.example.test")!))
        XCTAssertThrowsError(try EngineCookie.host(for: URL(string: "https://user@login.example.test")!))
        XCTAssertEqual(try EngineCookie.host(for: URL(string: "https://login.example.test:443")!), "login.example.test")
        XCTAssertTrue(EngineCookie.matches(domain: ".example.test", host: "login.example.test"))
        XCTAssertFalse(EngineCookie.matches(domain: ".example.test", host: "badexample.test"))
        XCTAssertFalse(EngineCookie.matches(domain: "example.test", host: "login.example.test"))
    }

    func testSwitchSharesBeforeFirstNavigationAndEmptySnapshotPreservesDestination() async throws {
        try await withApp { app, first, second in
            let window = try XCTUnwrap(app.windows.first)
            window.addTab(url: self.url)
            let tabID = try XCTUnwrap(window.selectedTab?.id)
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            second.onCookieReplace = {
                XCTAssertTrue(second.pages.allSatisfy { $0.loadedURLs.isEmpty })
            }
            window.confirmEngineSwitch = { _ in true }
            window.setEngine(self.secondID, for: tabID)
            for _ in 0..<100 where window.selectedPage?.contextID.engineID != self.secondID { await Task.yield() }
            XCTAssertEqual(second.cookieReplacements, [[self.cookie()]])
            XCTAssertEqual(window.selectedPage?.state.urlString, self.url.absoluteString)
            XCTAssertTrue(app.suspendedContexts.isEmpty)
            XCTAssertNotNil(app.loginSharingMessage)
            second.onCookieReplace = nil
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [])
            second.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            let warning = await app.shareLogin(from: first.id, to: second.id, url: self.url,
                                               confirmReplacement: { true }) { true }
            XCTAssertNil(warning)
            XCTAssertEqual(second.cookieReplacements, [[self.cookie()]])
            XCTAssertEqual(app.loginSharingMessage, String(localized: "No transferable source cookies were found. Destination cookies were left unchanged."))
        }
    }

    func testOptOutPrivateDifferentProfileAndUnavailableEngineNeverTransfer() async throws {
        try await withApp { app, first, second in
            app.preferences.setExperimentalLoginSharing(false)
            _ = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            app.preferences.setExperimentalLoginSharing(true)
            let privateID = BrowsingContextID(engineID: first.id.engineID, profileID: first.id.profileID, privateWindowID: UUID())
            _ = await app.shareLogin(from: privateID, to: second.id, url: self.url) { true }
            let otherProfile = BrowsingContextID(engineID: second.id.engineID, profileID: UUID(), privateWindowID: nil)
            _ = await app.shareLogin(from: first.id, to: otherProfile, url: self.url) { true }
            second.engine.capabilities.supportsCookieTransfer = false
            let unavailable = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertEqual(unavailable, String(localized: "This build does not support login sharing between these engines. Use a compatible experimental Full build."))
            second.engine.capabilities.supportsCookieTransfer = true
            var contextCapabilities = second.capabilities
            contextCapabilities.supportsCookieTransfer = false
            second.capabilitiesOverride = contextCapabilities
            let unavailableContext = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertNotNil(unavailableContext)
            XCTAssertEqual(first.cookieExports, 0)
            XCTAssertTrue(second.cookieReplacements.isEmpty)
        }
    }

    func testIncompleteInvalidAndCancelledSnapshotsNeverEraseDestination() async throws {
        try await withApp { app, first, second in
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [], skipped: 1)
            let incomplete = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertEqual(incomplete, String(localized: "Some source cookies could not be safely shared. No cookies were copied. Sign in again in this engine."))
            var invalid = self.cookie(); invalid.domain = "other.test"
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [invalid])
            let invalidSnapshot = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertNotNil(invalidSnapshot)
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            var current = true
            first.onCookieExport = {
                XCTAssertEqual(app.suspendedContexts, Set([first.id, second.id]))
                current = false
            }
            _ = await app.shareLogin(from: first.id, to: second.id, url: self.url) { current }
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            XCTAssertTrue(app.suspendedContexts.isEmpty)
            first.onCookieExport = nil
        }
    }

    func testExportTimeoutReleasesFenceAndIgnoresLateSnapshot() async throws {
        try await withApp { app, first, second in
            var resumeExport: CheckedContinuation<Void, Never>?
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            first.onCookieExport = {
                await withCheckedContinuation { resumeExport = $0 }
            }

            let warning = await app.shareLogin(from: first.id, to: second.id, url: self.url,
                                               exportTimeout: .milliseconds(10)) { true }

            XCTAssertEqual(warning, String(localized: "Login cookies could not be read safely from the source engine. You may need to sign in again."))
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            XCTAssertTrue(app.suspendedContexts.isEmpty)
            XCTAssertNotNil(resumeExport)
            resumeExport?.resume()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(second.cookieReplacements.isEmpty)
        }
    }

    func testSupersededReplacementDoesNotPublishStatus() async throws {
        try await withApp { app, first, second in
            var current = true
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            second.onCookieReplace = { current = false }

            let warning = await app.shareLogin(from: first.id, to: second.id, url: self.url) { current }

            XCTAssertNil(warning)
            XCTAssertNil(app.loginSharingMessage)
            XCTAssertEqual(second.cookieReplacements, [[self.cookie()]])
            XCTAssertTrue(app.suspendedContexts.isEmpty)
        }
    }

    func testSecondEngineSwitchDuringReplacementIsRejected() async throws {
        try await withApp { app, first, second in
            let window = try XCTUnwrap(app.windows.first)
            window.addTab(url: self.url)
            let tabID = try XCTUnwrap(window.selectedTab?.id)
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            window.confirmEngineSwitch = { _ in true }
            second.onCookieReplace = {
                window.setEngine(.webKit, for: tabID)
                XCTAssertNotNil(window.addressError)
            }

            window.setEngine(self.secondID, for: tabID)
            for _ in 0..<100 where window.selectedPage?.contextID.engineID != self.secondID { await Task.yield() }

            XCTAssertEqual(window.selectedPage?.contextID.engineID, self.secondID)
            XCTAssertEqual(second.cookieReplacements, [[self.cookie()]])
            XCTAssertNotNil(app.loginSharingMessage)
            XCTAssertTrue(app.suspendedContexts.isEmpty)
        }
    }

    func testRejectedWritesStillReloadAndReportBoundedFailure() async throws {
        try await withApp { app, first, second in
            let window = try XCTUnwrap(app.windows.first)
            window.addTab(url: self.url)
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            second.cookieRejections = 1
            window.confirmEngineSwitch = { _ in true }
            window.setEngine(self.secondID, for: try XCTUnwrap(window.selectedTab?.id))
            for _ in 0..<100 where window.selectedPage?.contextID.engineID != self.secondID { await Task.yield() }
            XCTAssertEqual(window.selectedPage?.state.urlString, self.url.absoluteString)
            XCTAssertEqual(window.addressError, String(localized: "The destination engine could not accept or verify all login cookies. Sign in again in this engine."))
            XCTAssertFalse(try XCTUnwrap(app.loginSharingMessage).contains("fixture-secret"))
            XCTAssertTrue(app.suspendedContexts.isEmpty)
        }
    }

    func testGoogleGroupPreservesScopesAndPreflightsAllCookies() async throws {
        let googleURL = URL(string: "https://mail.google.com/mail/u/0/")!
        XCTAssertEqual(try AppModel.loginSharingURLs(for: googleURL).compactMap { $0.host() },
                       ["google.com", "accounts.google.com", "www.google.com", "mail.google.com"])
        for outside in ["https://notgoogle.com", "https://google.com.example.test", "https://youtube.com"] {
            let url = URL(string: outside)!
            XCTAssertEqual(try AppModel.loginSharingURLs(for: url), [url])
        }
        XCTAssertThrowsError(try AppModel.loginSharingURLs(for: URL(string: "http://accounts.google.com")!))
        try await withApp { app, first, second in
            var parent = self.cookie(); parent.domain = ".google.com"
            var account = self.cookie(); account.domain = "accounts.google.com"
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [parent])
            first.cookieSnapshotsByHost["accounts.google.com"] = CookieTransferSnapshot(cookies: [parent, account])
            second.onCookieReplace = { XCTAssertEqual(first.cookieExports, 4) }
            let warning = await app.shareLogin(from: first.id, to: second.id, url: googleURL) { true }
            XCTAssertNil(warning)
            XCTAssertEqual(second.cookieReplacementHosts, ["google.com", "accounts.google.com", "www.google.com", "mail.google.com"])
            XCTAssertEqual(second.cookieReplacements, [[parent], [parent, account], [parent], [parent]])
            second.onCookieReplace = nil
            second.cookieReplacements = []
            first.cookieSnapshotsByHost["mail.google.com"] = CookieTransferSnapshot(cookies: [parent], skipped: 2, partitioned: 1)
            let rejected = await app.shareLogin(from: first.id, to: second.id, url: googleURL) { true }
            XCTAssertEqual(rejected, String(localized: "Some source cookies could not be safely shared. No cookies were copied. Sign in again in this engine."))
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            first.cookieSnapshotsByHost["mail.google.com"] = CookieTransferSnapshot(cookies: [])
            let changed = await app.shareLogin(from: first.id, to: second.id, url: googleURL) { true }
            XCTAssertEqual(changed, String(localized: "Source login cookies changed during transfer. No cookies were copied. Try switching engines again."))
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            XCTAssertTrue(app.suspendedContexts.isEmpty)
        }
    }

    func testKnownPartitionsDoNotBlockCompleteUnpartitionedCookies() async throws {
        try await withApp { app, first, second in
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()], skipped: 1, partitioned: 1)
            let warning = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertNil(warning)
            XCTAssertEqual(second.cookieReplacements, [[self.cookie()]])
            XCTAssertEqual(app.loginSharingMessage, String(localized: "Unpartitioned login cookies were shared; partitioned cookies were left untouched. The website may still require sign-in."))
            second.cookieReplacements = []
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [], skipped: 1, partitioned: 1)
            let empty = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertEqual(empty, String(localized: "Only partitioned source cookies were found. Destination cookies were left unchanged."))
            XCTAssertTrue(second.cookieReplacements.isEmpty)
        }
    }

    func testExistingDestinationRequiresApprovalAcrossEveryScope() async throws {
        try await withApp { app, first, second in
            let source = self.cookie()
            var existing = source; existing.value = "destination-secret"
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [source])
            second.cookieSnapshot = CookieTransferSnapshot(cookies: [existing])
            let denied = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertNil(denied)
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            XCTAssertEqual(app.loginSharingMessage, String(localized: "Existing destination cookies were preserved. Sign in again if needed."))
            let approved = await app.shareLogin(from: first.id, to: second.id, url: self.url,
                                                confirmReplacement: { true }) { true }
            XCTAssertNil(approved)
            XCTAssertEqual(second.cookieReplacements, [[source]])
            second.cookieReplacements = []
            second.cookieSnapshot = CookieTransferSnapshot(cookies: [source])
            let same = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertNil(same)
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            XCTAssertEqual(app.loginSharingMessage, String(localized: "Destination cookies already match the source. No cookies were copied."))
        }
    }

    func testDestinationMetadataCannotBeReplacedEvenWithApproval() async throws {
        try await withApp { app, first, second in
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            second.cookieSnapshot = CookieTransferSnapshot(cookies: [], skipped: 1)
            let unknown = await app.shareLogin(from: first.id, to: second.id, url: self.url,
                                               confirmReplacement: { true }) { true }
            XCTAssertEqual(unknown, String(localized: "Some destination cookies cannot be safely replaced. Destination cookies were left unchanged."))
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            second.cookieSnapshot = CookieTransferSnapshot(cookies: [], skipped: 1, partitioned: 1)
            let denied = await app.shareLogin(from: first.id, to: second.id, url: self.url) { true }
            XCTAssertNil(denied)
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            let approved = await app.shareLogin(from: first.id, to: second.id, url: self.url,
                                                confirmReplacement: { true }) { true }
            XCTAssertNil(approved)
            XCTAssertEqual(second.cookieReplacements, [[self.cookie()]])
        }
    }

    func testGoogleDestinationConflictAndLateUnknownMetadataNeverWriteEarly() async throws {
        try await withApp { app, first, second in
            let googleURL = URL(string: "https://mail.google.com/")!
            var source = self.cookie(); source.domain = ".google.com"
            var existing = source; existing.value = "destination-secret"
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [source])
            second.cookieSnapshotsByHost["accounts.google.com"] = CookieTransferSnapshot(cookies: [existing])
            let denied = await app.shareLogin(from: first.id, to: second.id, url: googleURL) { true }
            XCTAssertNil(denied)
            XCTAssertEqual(second.cookieExports, 4)
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            second.cookieSnapshotsByHost["mail.google.com"] = CookieTransferSnapshot(cookies: [], skipped: 1)
            let blocked = await app.shareLogin(from: first.id, to: second.id, url: googleURL,
                                               confirmReplacement: { true }) { true }
            XCTAssertEqual(blocked, String(localized: "Some destination cookies cannot be safely replaced. Destination cookies were left unchanged."))
            XCTAssertTrue(second.cookieReplacements.isEmpty)
        }
    }

    func testStalePromptAndPartialWriteFailure() async throws {
        try await withApp { app, first, second in
            let googleURL = URL(string: "https://mail.google.com/")!
            var source = self.cookie(); source.domain = ".google.com"
            var existing = source; existing.value = "destination-secret"
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [source])
            second.cookieSnapshot = CookieTransferSnapshot(cookies: [existing])
            var current = true
            let stale = await app.shareLogin(from: first.id, to: second.id, url: googleURL,
                                             confirmReplacement: { current = false; return true }) { current }
            XCTAssertNil(stale)
            XCTAssertTrue(second.cookieReplacements.isEmpty)
            current = true
            second.onCookieReplace = {
                if second.cookieReplacements.count == 1 { second.cookieRejections = 1 }
            }
            let failed = await app.shareLogin(from: first.id, to: second.id, url: googleURL,
                                              confirmReplacement: { true }) { true }
            XCTAssertEqual(failed, String(localized: "The destination engine could not accept or verify all login cookies. Sign in again in this engine."))
            XCTAssertEqual(second.cookieReplacements.count, 2)
            XCTAssertTrue(app.suspendedContexts.isEmpty)
        }
    }

    func testDestinationChangeAfterApprovalStopsBeforeWrite() async throws {
        try await withApp { app, first, second in
            let source = self.cookie()
            var existing = source; existing.value = "destination-secret"
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [source])
            second.cookieSnapshot = CookieTransferSnapshot(cookies: [existing])
            second.onCookieExport = {
                if second.cookieExports == 2 { second.cookieSnapshot = CookieTransferSnapshot(cookies: []) }
            }
            let warning = await app.shareLogin(from: first.id, to: second.id, url: self.url,
                                               confirmReplacement: { true }) { true }
            XCTAssertEqual(warning, String(localized: "Destination cookies changed during transfer. Destination cookies were left unchanged."))
            XCTAssertTrue(second.cookieReplacements.isEmpty)
        }
    }

    func testOAuthHandoffSkipsTransfer() async throws {
        XCTAssertTrue(AppModel.isLoginHandoff(URL(string: "https://example.test/callback?state=one&code=two")!))
        XCTAssertTrue(AppModel.isLoginHandoff(URL(string: "https://example.test/authorize?client_id=one&response_type=code")!))
        XCTAssertFalse(AppModel.isLoginHandoff(URL(string: "https://example.test/search?q=code&state=one")!))
        try await withApp { app, first, second in
            first.cookieSnapshot = CookieTransferSnapshot(cookies: [self.cookie()])
            let warning = await app.shareLogin(from: first.id, to: second.id,
                                               url: URL(string: "https://login.example.test/callback?state=one&code=two")!) { true }
            XCTAssertNil(warning)
            XCTAssertEqual(first.cookieExports, 0)
            XCTAssertEqual(second.cookieExports, 0)
            XCTAssertTrue(second.cookieReplacements.isEmpty)
        }
    }

    private func cookie() -> EngineCookie {
        EngineCookie(name: "session", value: "fixture-secret", domain: ".example.test", path: "/",
                     expires: nil, secure: true, httpOnly: true, sameSite: .lax)
    }

    private func withApp(_ body: (AppModel, TestContext, TestContext) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TestEngine(.webKit), second = TestEngine(secondID)
        first.capabilities.supportsCookieTransfer = true
        second.capabilities.supportsCookieTransfer = true
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([first, second]))
        app.preferences.setExperimentalLoginSharing(true)
        let profile = try XCTUnwrap(app.profiles.first)
        let source = try XCTUnwrap(try app.engines.context(engineID: first.id, profile: profile, siteSettings: app.siteSettings) as? TestContext)
        let destination = try XCTUnwrap(try app.engines.context(engineID: second.id, profile: profile, siteSettings: app.siteSettings) as? TestContext)
        do { try await body(app, source, destination) }
        catch {
            app.windows.forEach { $0.closePages() }; await app.engines.shutdown(); app.flush()
            throw error
        }
        app.windows.forEach { $0.closePages() }
        await app.engines.shutdown()
        app.flush()
    }
}
