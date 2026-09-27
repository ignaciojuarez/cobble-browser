import AppKit
import Security
import XCTest
import WebKit
@testable import Cobble

private final class ClientCertificateChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

@MainActor
final class WebKitPageTests: XCTestCase {
    #if DEBUG
    func testResourceDiscoveryUsesLiveProcessesAndStopsReferencingClosedPage() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        page.webView.loadHTMLString("<title>Resource fixture</title>", baseURL: nil)
        try await waitFor { page.webView.title == "Resource fixture" && !page.webView.isLoading }
        let discovery = page.resourceProcesses
        XCTAssertTrue(discovery.processes.contains { $0.role == "Content" && $0.pid > 0 })
        XCTAssertTrue(discovery.processes.allSatisfy { $0.pid != getpid() })
        var sampler = ResourceSampler()
        let first = sampler.sample(discovery)
        XCTAssertFalse(first.readings.isEmpty)
        page.close()
        XCTAssertTrue(page.resourceProcesses.processes.isEmpty)
        // The next read either retains the identified process, reports denial,
        // or observes exit. No page reference is retained by the sampler.
        let next = sampler.sample(.init())
        XCTAssertTrue(next.readings.allSatisfy { row in discovery.processes.contains { $0.pid == row.process.pid } })
    }
    #endif

    func testDefaultUserAgentIdentifiesAsSafari() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        page.webView.loadHTMLString("<title>UA fixture</title>", baseURL: nil)
        try await waitFor { page.webView.title == "UA fixture" && !page.webView.isLoading }
        let evaluated = try await page.webView.evaluateJavaScript("navigator.userAgent")
        let agent = try XCTUnwrap(evaluated as? String)
        XCTAssertTrue(agent.contains("Version/"), agent)
        XCTAssertTrue(agent.contains("Safari/"), agent)
        XCTAssertFalse(agent.contains("Cobble"), agent)
    }

    func testSiteBrowserIdentityChangesHTTPAndJavaScriptWithoutResizing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteSettingsStore(directory: directory)
        let desktop = try LocalHTTPFixture { _ in .init(body: "<title>Desktop identity</title>") }
        try await desktop.start()
        defer { desktop.stop() }
        let mobile = try LocalHTTPFixture { request in
            if request.path == "/redirect" {
                return .init(status: "302 Found", headers: ["Location": desktop.url("/redirected").absoluteString])
            }
            return .init(body: "<title>Mobile identity</title>")
        }
        try await mobile.start()
        defer { mobile.stop() }
        XCTAssertTrue(store.setBrowserIdentity(.iPhone, for: mobile.url("/"), profileID: Profile.defaultID))
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), siteSettings: store) { _, _, _ in }
        defer { page.close() }
        page.webView.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        page.navigate(to: mobile.url("/first"))
        try await waitFor { page.webView.title == "Mobile identity" && !page.webView.isLoading }
        XCTAssertEqual(mobile.requests.first?.headers["user-agent"], SiteBrowserIdentity.iPhone.userAgent)
        let agent = try await page.webView.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(agent, SiteBrowserIdentity.iPhone.userAgent)
        XCTAssertEqual(page.webView.frame.width, 1000)

        _ = try await page.webView.evaluateJavaScript("location.href = '\(desktop.url("/linked").absoluteString)'; void 0")
        try await waitFor { page.webView.title == "Desktop identity" && !page.webView.isLoading }
        XCTAssertFalse(try XCTUnwrap(desktop.requests.last?.headers["user-agent"]).contains("iPhone"))
        page.goBack()
        try await waitFor { page.webView.url?.path == "/first" && !page.webView.isLoading }
        let restoredAgent = try await page.webView.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(restoredAgent, SiteBrowserIdentity.iPhone.userAgent)

        XCTAssertTrue(store.setBrowserIdentity(.androidPhone, for: mobile.url("/"), profileID: Profile.defaultID))
        page.reload()
        try await waitFor { mobile.requests.filter { $0.path == "/first" }.count >= 2 && !page.webView.isLoading }
        XCTAssertEqual(mobile.requests.last(where: { $0.path == "/first" })?.headers["user-agent"], SiteBrowserIdentity.androidPhone.userAgent)
        page.navigate(to: mobile.url("/redirect"))
        try await waitFor { page.webView.url?.path == "/redirected" && !page.webView.isLoading }
        XCTAssertFalse(try XCTUnwrap(desktop.requests.last?.headers["user-agent"]).contains("Android"))
    }

    func testPageToolsReadLiveDOMArchiveLocalFileAndInspectorOptIn() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        XCTAssertFalse(page.webView.isInspectable)
        page.setInspectable(true)
        XCTAssertTrue(page.webView.isInspectable)
        page.webView.loadHTMLString("<title>Page tools fixture</title><body>initial</body>", baseURL: nil)
        try await waitFor { page.webView.title == "Page tools fixture" && !page.webView.isLoading }
        _ = try await page.webView.evaluateJavaScript("document.body.textContent = 'live DOM'; void 0")
        let dom = try await page.currentDOM()
        XCTAssertTrue(dom.contains("live DOM"))
        let archive = try await page.pageArchive()
        XCTAssertFalse(archive.isEmpty)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePageTools-\(UUID()).html")
        try "<title>Authorized local fixture</title><body>local</body>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await page.openLocalFile(file)
        XCTAssertEqual(page.webView.url, file)
        XCTAssertEqual(page.scopedLocalFileURL, file)
        let missing = file.deletingLastPathComponent().appendingPathComponent("Missing-\(UUID()).html")
        do {
            try await page.openLocalFile(missing)
            XCTFail("Expected a missing local file to fail before commit")
        } catch {}
        XCTAssertEqual(page.webView.url, file)
        XCTAssertEqual(page.scopedLocalFileURL, file)
        try "<title>Rejected candidate</title><body>wrong file</body>".write(
            to: missing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: missing) }
        try "<title>Retained file reloaded</title><body>right file</body>".write(
            to: file, atomically: true, encoding: .utf8)
        page.reload()
        try await waitFor { page.webView.title == "Retained file reloaded" && !page.webView.isLoading }
        XCTAssertEqual(page.webView.url, file)
        XCTAssertEqual(page.scopedLocalFileURL, file)
        let retainedDOM = try await page.currentDOM()
        XCTAssertTrue(retainedDOM.contains("right file"))
        let failed = try LocalHTTPFixture { _ in .init(disconnect: true) }
        try await failed.start()
        defer { failed.stop() }
        page.navigate(to: failed.url("/fails"))
        try await waitFor { page.errorMessage != nil }
        XCTAssertEqual(page.scopedLocalFileURL, file)
        let server = try LocalHTTPFixture { _ in .init(body: "<title>Scope released</title>") }
        try await server.start()
        defer { server.stop() }
        page.navigate(to: server.url("/away"))
        try await waitFor { page.webView.title == "Scope released" && !page.webView.isLoading }
        XCTAssertNil(page.scopedLocalFileURL)
        page.close()
        do {
            _ = try await page.currentDOM()
            XCTFail("Closed pages must not return DOM")
        } catch EngineError.closed {}
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSnapshotCapturesOnlyTheVisibleViewportAndRejectsClosedPage() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        page.webView.loadHTMLString("<title>Snapshot fixture</title><body style='margin:0'><div style='height:200px;background:red'></div><div style='height:1000px;background:blue'></div></body>", baseURL: nil)
        try await waitFor { page.webView.title == "Snapshot fixture" && !page.webView.isLoading }
        XCTAssertTrue(page.capabilities.pageOperations.contains(.snapshot))
        let first = try await page.snapshot()
        XCTAssertEqual(first.size, page.webView.bounds.size)
        let bitmap = try XCTUnwrap(first.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let red = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(red.redComponent, 0.9)
        XCTAssertLessThan(red.blueComponent, 0.1)
        _ = try await page.webView.evaluateJavaScript("window.scrollTo(0, 300)")
        let second = try await page.snapshot()
        XCTAssertEqual(second.size, page.webView.bounds.size)
        let scrolled = try XCTUnwrap(second.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let blue = try XCTUnwrap(scrolled.colorAt(x: scrolled.pixelsWide / 2, y: scrolled.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(blue.blueComponent, 0.9)
        XCTAssertLessThan(blue.redComponent, 0.1)
        page.close()
        do {
            _ = try await page.snapshot()
            XCTFail("Closed pages must not produce screenshots")
        } catch EngineError.closed {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testReloadFromOriginRevalidatesCacheableResourcesPreservingWebsiteData() async throws {
        var version = 1
        let server = try LocalHTTPFixture { request in
            if request.path == "/asset.js" {
                return .init(headers: ["Content-Type": "application/javascript", "Cache-Control": "max-age=3600"],
                             body: "document.title = 'Version \(version)';")
            }
            return .init(headers: ["Cache-Control": "max-age=3600"],
                         body: "<title>Pending</title><script src='/asset.js'></script><body>Reload fixture</body>")
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        XCTAssertTrue(page.capabilities.pageOperations.contains(.reloadFromOrigin))
        let url = server.url("/cached")
        page.navigate(to: url)
        try await waitFor { page.webView.title == "Version 1" && !page.webView.isLoading }
        _ = try await page.webView.evaluateJavaScript("document.cookie = 'reloadToken=kept; SameSite=Lax'; localStorage.setItem('reloadToken', 'kept');")
        let initialRequests = server.requests.filter { $0.path == "/asset.js" }.count
        version = 2
        page.reloadFromOrigin()
        try await waitFor { page.webView.title == "Version 2" && !page.webView.isLoading }
        XCTAssertGreaterThan(server.requests.filter { $0.path == "/asset.js" }.count, initialRequests)
        XCTAssertEqual(page.webView.url, url)
        let preserved = try await page.webView.evaluateJavaScript("document.cookie.includes('reloadToken=kept') && localStorage.getItem('reloadToken') === 'kept'") as? Bool
        XCTAssertEqual(preserved, true)
    }

    func testFindReportsMatchAndMissAndRejectsSupersededResults() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        page.webView.loadHTMLString("<title>Find fixture</title><body>Cobble needle. Another COBBLE needle.</body>", baseURL: nil)
        try await waitFor { page.webView.title == "Find fixture" && !page.webView.isLoading }
        page.find("cobble")
        try await waitFor { page.state.findMatchFound == true }
        XCTAssertEqual(page.state.findQuery, "cobble")
        page.find("needle", backwards: true)
        try await waitFor { page.state.findMatchFound == true }
        page.find("absent phrase")
        try await waitFor { page.state.findMatchFound == false }
        page.find("cobble")
        page.find("replacement absent phrase")
        try await waitFor { page.state.findMatchFound == false }
        XCTAssertEqual(page.state.findQuery, "replacement absent phrase")
        page.find("cobble")
        page.find("")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(page.state.findQuery, "")
        XCTAssertNil(page.state.findMatchFound)
        page.find("cobble")
        page.navigate(to: nil)
        try await waitFor { page.webView.url?.absoluteString == "about:blank" && !page.webView.isLoading }
        XCTAssertEqual(page.state.findQuery, "")
        XCTAssertNil(page.state.findMatchFound)
        page.find("anything")
        page.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(page.state.findQuery, "")
        XCTAssertNil(page.state.findMatchFound)
    }

    func testCommittedHTTPVisitSurvivesStopAndCloseBeforeSubresourceFinishes() async throws {
        let server = try LocalHTTPFixture { request in
            request.path == "/pending.js"
                ? .init(body: nil)
                : .init(body: "<title>Committed before finish</title><script src='/pending.js'></script><body>Waiting</body>")
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        var visits: [String] = []
        page.events.onVisit = { _, url, _ in visits.append(url) }
        page.navigate(to: server.url("/committed"))
        try await waitFor { server.requests.contains { $0.path == "/pending.js" } && visits.count == 1 }
        XCTAssertTrue(page.webView.isLoading)
        XCTAssertEqual(visits, [server.url("/committed").absoluteString])
        page.stop()
        try await waitFor { !page.webView.isLoading }
        page.close()
        await Task.yield()
        XCTAssertEqual(visits, [server.url("/committed").absoluteString])
    }

    func testStoppingProvisionalNavigationKeepsVisibleCommittedPageActive() async throws {
        let server = try LocalHTTPFixture { request in
            request.path == "/pending" ? .init(body: nil) : .init(body: "<title>Initial</title><body>Still visible</body>")
        }
        try await server.start()
        defer { server.stop() }
        var titles: [String] = []
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, title in titles.append(title) }
        defer { page.close() }
        page.navigate(to: server.url("/initial"))
        try await waitFor { titles.last == "Initial" && !page.webView.isLoading }

        page.navigate(to: server.url("/pending"))
        try await waitFor { server.requests.contains { $0.path == "/pending" } && page.webView.isLoading }
        page.stop()
        try await waitFor { !page.webView.isLoading }
        _ = try await page.webView.evaluateJavaScript("document.title = 'Still active'")
        try await waitFor { titles.last == "Still active" }
        XCTAssertNil(page.errorMessage)
    }

    func testProvisionalFailureDoesNotRecordHistoryVisit() async throws {
        let server = try LocalHTTPFixture { _ in .init(disconnect: true) }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        var visits: [String] = []
        page.events.onVisit = { _, url, _ in visits.append(url) }
        page.navigate(to: server.url("/disconnect-before-headers"))
        try await waitFor { page.errorMessage != nil }
        XCTAssertTrue(visits.isEmpty)
    }

    func testPopupAllowDoesNotCarryIntoAnotherOriginsEarlyScript() async throws {
        let allowed = try LocalHTTPFixture { request in
            .init(body: "<title>Allowed origin</title><body>\(request.path)</body>")
        }
        let destination = try LocalHTTPFixture { request in
            .init(body: request.path == "/destination"
                ? "<title>/destination</title><script>window.earlyPopup = window.open('/child');</script><body>Destination</body>"
                : "<title>Child</title><body>Popup</body>")
        }
        try await allowed.start()
        try await destination.start()
        defer { allowed.stop(); destination.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePopupTransition-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SiteSettingsStore(directory: directory)
        var allowSetting = settings.setting(origin: allowed.url("/"), profileID: Profile.defaultID)
        allowSetting.popups = .allow
        settings.update(allowSetting)
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), siteSettings: settings) { _, _, _ in }
        var children: [WebKitPage] = []
        defer { page.close(); children.forEach { $0.close() } }
        page.events.onCreatePage = { child in
            guard let child = child as? WebKitPage else { return false }
            children.append(child)
            return true
        }
        for permission in [SitePermission.ask, .deny] {
            var setting = settings.setting(origin: destination.url("/"), profileID: Profile.defaultID)
            setting.popups = permission
            settings.update(setting)
            page.navigate(to: allowed.url("/parent"))
            try await waitFor { page.webView.title == "Allowed origin" && !page.webView.isLoading }
            XCTAssertTrue(page.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            let count = children.count
            page.navigate(to: destination.url("/destination"))
            try await waitFor { page.webView.title == "/destination" && !page.webView.isLoading }
            let popupWasBlocked = try await page.webView.evaluateJavaScript("window.earlyPopup === null") as? Bool
            XCTAssertEqual(popupWasBlocked, true)
            XCTAssertEqual(children.count, count)
            XCTAssertFalse(page.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        }
    }

    func testPopupAllowDoesNotGrantEmbeddedOrigins() async throws {
        let embedded = try LocalHTTPFixture { _ in
            .init(body: "<script>parent.postMessage(window.open('/child') === null, '*')</script>")
        }
        try await embedded.start()
        let parent = try LocalHTTPFixture { _ in
            .init(body: "<title>Parent</title><script>onmessage=e=>window.popupBlocked=e.data</script><iframe src='\(embedded.url("/embedded"))'></iframe>")
        }
        try await parent.start()
        defer { parent.stop(); embedded.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleEmbeddedPopup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SiteSettingsStore(directory: directory)
        var allow = settings.setting(origin: parent.url("/"), profileID: Profile.defaultID)
        allow.popups = .allow
        settings.update(allow)
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), siteSettings: settings) { _, _, _ in }
        var children: [WebKitPage] = []
        page.events.onCreatePage = { child in
            guard let child = child as? WebKitPage else { return false }
            children.append(child)
            return true
        }
        defer { page.close(); children.forEach { $0.close() } }
        page.navigate(to: parent.url("/"))
        try await waitFor { page.webView.title == "Parent" && !page.webView.isLoading }
        let blocked = try await page.webView.evaluateJavaScript("window.popupBlocked") as? Bool
        XCTAssertEqual(blocked, true)
        XCTAssertTrue(children.isEmpty)
    }

    func testHTTPBasicAuthenticationCancelsWhenPageCloses() async throws {
        let server = try LocalHTTPFixture { _ in
            .init(status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Cobble local fixture\""], body: "Authentication required")
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        var visits: [String] = []
        page.events.onVisit = { _, url, _ in visits.append(url) }
        page.navigate(to: server.url("/protected"))
        try await waitFor { window.attachedSheet != nil }
        XCTAssertTrue(visits.isEmpty)
        page.close()
        try await waitFor { window.attachedSheet == nil }
        XCTAssertEqual(page.state.lifecycle, .closed)
        XCTAssertEqual(server.requests.filter { $0.path == "/protected" }.count, 1)
    }

    func testFreshDownloadAuthenticationPromptSurvivesTabCloseAndCancelsWithTransfer() async throws {
        let server = try LocalHTTPFixture { _ in
            .init(status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Download fixture\""], body: "Authentication required")
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        var transfer: WebKitDownload?
        defer { transfer?.detach() }
        let started = expectation(description: "WKDownload starts")
        page.webView.startDownload(using: URLRequest(url: server.url("/private.bin"))) { native in
            let candidate = WebKitDownload(native, webView: page.webView)
            transfer = candidate
            candidate.onDestination = { _, completion in completion(nil) }
            candidate.start()
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 10)
        try await waitFor { window.attachedSheet != nil }
        page.close()
        XCTAssertNotNil(window.attachedSheet)
        let cancelled = expectation(description: "transfer cancellation resolves its prompt")
        try XCTUnwrap(transfer).cancel { cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 10)
        try await waitFor { window.attachedSheet == nil }
        XCTAssertEqual(server.requests.filter { $0.path == "/private.bin" }.count, 1)
    }

    func testFreshDownloadBasicAuthenticationUsesOwnedPromptAfterTabClose() async throws {
        let expected = "Basic \(Data("reader:secret".utf8).base64EncodedString())"
        let server = try LocalHTTPFixture { request in
            request.headers["authorization"] == expected
                ? .init(headers: ["Content-Type": "application/octet-stream",
                                  "Content-Disposition": "attachment; filename=private.bin"], body: "private bytes")
                : .init(status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Download fixture\""], body: "Authentication required")
        }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDownloadAuth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("private.bin")
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        var transfer: WebKitDownload?
        defer { transfer?.detach() }
        let started = expectation(description: "WKDownload starts")
        let finished = expectation(description: "authenticated download finishes")
        var transferError: Error?
        page.webView.startDownload(using: URLRequest(url: server.url("/private.bin"))) { native in
            let candidate = WebKitDownload(native, webView: page.webView)
            transfer = candidate
            candidate.onDestination = { _, completion in completion(destination) }
            candidate.onFinish = { finished.fulfill() }
            candidate.onFailure = { error in transferError = error; finished.fulfill() }
            candidate.start()
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 10)
        try await waitFor { window.attachedSheet != nil }
        page.close()
        let sheet = try XCTUnwrap(window.attachedSheet)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let fields = descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextField }
        try XCTUnwrap(fields.first { $0.placeholderString == String(localized: "Username") }).stringValue = "reader"
        try XCTUnwrap(fields.first { $0.placeholderString == String(localized: "Password") }).stringValue = "secret"
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertNil(transferError)
        XCTAssertEqual(try Data(contentsOf: destination), Data("private bytes".utf8))
        XCTAssertEqual(server.requests.filter { $0.path == "/private.bin" }.count, 2)
    }

    func testHTTPRedirectToUnhandledSchemeOffersExternalAppWithoutErrorPage() async throws {
        let callback = URL(string: "cobble-app://auth/callback")!
        let server = try LocalHTTPFixture { request in
            request.path == "/return"
                ? .init(status: "302 Found", headers: ["Location": callback.absoluteString], body: "")
                : .init(body: "<title>Login</title><body>Signed in</body>")
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        var opened: [URL] = []
        page.events.onExternalURL = { opened.append($0) }
        page.navigate(to: server.url("/login"))
        try await waitFor { page.webView.title == "Login" && !page.webView.isLoading }
        page.navigate(to: server.url("/return"))
        try await waitFor { window.attachedSheet != nil }
        XCTAssertNil(page.errorMessage)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(page.hasPendingPrompt)
        page.close()
        try await waitFor { window.attachedSheet == nil }
        XCTAssertTrue(opened.isEmpty)
    }

    func testJavaScriptLocationToUnhandledSchemeOffersExternalAppWithoutErrorPage() async throws {
        let callback = URL(string: "cobble-app://auth/callback")!
        let server = try LocalHTTPFixture { _ in
            .init(body: "<title>Logged in</title><body>Ready</body>")
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        var opened: [URL] = []
        page.events.onExternalURL = { opened.append($0) }
        page.navigate(to: server.url("/app"))
        try await waitFor { page.webView.title == "Logged in" && !page.webView.isLoading }
        _ = try? await page.webView.evaluateJavaScript("location.href = '\(callback.absoluteString)'")
        try await waitFor { window.attachedSheet != nil }
        XCTAssertNil(page.errorMessage)
        XCTAssertEqual(page.webView.title, "Logged in")
        page.close()
        try await waitFor { window.attachedSheet == nil }
        XCTAssertTrue(opened.isEmpty)
    }

    func testEmbeddedFrameUnhandledSchemeDoesNotInterruptPage() async throws {
        let child = try LocalHTTPFixture { _ in
            .init(status: "302 Found", headers: ["Location": "cobble-app://auth/callback"], body: "")
        }
        try await child.start()
        let parent = try LocalHTTPFixture { _ in
            .init(body: "<title>Parent</title><iframe src='\(child.url("/return"))'></iframe><body>Still here</body>")
        }
        try await parent.start()
        defer { parent.stop(); child.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        var opened: [URL] = []
        page.events.onExternalURL = { opened.append($0) }
        page.navigate(to: parent.url("/"))
        try await waitFor { page.webView.title == "Parent" && !page.webView.isLoading }
        try await waitFor { child.requests.contains { $0.path == "/return" } }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(page.errorMessage)
        XCTAssertFalse(page.hasPendingPrompt)
        XCTAssertEqual(page.webView.title, "Parent")
        let dom = try await page.currentDOM()
        XCTAssertTrue(dom.contains("Still here"))
    }

    func testHTTPUnrenderableResponseBecomesDownloadWithoutHistoryVisit() async throws {
        let server = try LocalHTTPFixture { _ in
            .init(headers: ["Content-Type": "application/x-cobble-fixture"], body: "HTTP download bytes")
        }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleHTTPDownload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("payload.cobble")
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        var transfer: (any EngineDownload)?
        defer { transfer?.detach() }
        var visits: [String] = []
        page.events.onVisit = { _, url, _ in visits.append(url) }
        let finished = expectation(description: "HTTP MIME response download finishes")
        var transferError: Error?
        page.events.onDownload = { download in
            XCTAssertNil(transfer)
            transfer = download
            download.onDestination = { _, completion in completion(destination); page.close() }
            download.onFinish = { finished.fulfill() }
            download.onFailure = { error in transferError = error; finished.fulfill() }
            download.start()
        }
        page.navigate(to: server.url("/payload.cobble"))
        await fulfillment(of: [finished], timeout: 15)
        if let transfer { await withCheckedContinuation { continuation in transfer.cancel { continuation.resume() } } }
        XCTAssertNil(transferError)
        XCTAssertNotNil(transfer)
        XCTAssertEqual(try Data(contentsOf: destination), Data("HTTP download bytes".utf8))
        XCTAssertTrue(visits.isEmpty)
    }

    func testHTTPDownloadHandoffKeepsCommittedPageUsableAndShowsLaterFailure() async throws {
        let server = try LocalHTTPFixture { request in
            switch request.path {
            case "/download":
                return .init(headers: ["Content-Type": "application/x-cobble-fixture"], body: "HTTP download bytes")
            case "/follow-up":
                return .init(body: "<title>Follow-up</title><body>Ready</body>")
            case "/fails":
                return .init(disconnect: true)
            default:
                return .init(body: "<title>Initial</title><body>Still here</body>")
            }
        }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleHTTPDownloadHandoff-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("payload.cobble")
        var changedURLs: [String] = []
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, url, _ in changedURLs.append(url) }
        defer { page.close() }
        var transfer: (any EngineDownload)?
        defer { transfer?.detach() }
        let destinationRequested = expectation(description: "download destination requested")
        let finished = expectation(description: "download finishes")
        var chooseDestination: ((URL?) -> Void)?
        defer { chooseDestination?(nil) }
        page.events.onDownload = { download in
            guard transfer == nil else {
                XCTFail("Page reload must not start another download")
                download.cancel {}
                return
            }
            transfer = download
            download.onDestination = { _, completion in
                chooseDestination = completion
                destinationRequested.fulfill()
            }
            download.onFinish = { finished.fulfill() }
            download.onFailure = { error in XCTFail("Download failed: \(error)") }
            download.start()
        }
        page.navigate(to: server.url("/initial"))
        try await waitFor { page.webView.title == "Initial" && !page.webView.isLoading }
        let changesBeforeDownload = changedURLs.count
        page.navigate(to: server.url("/download"))
        await fulfillment(of: [destinationRequested], timeout: 15)
        try await waitFor { changedURLs.count > changesBeforeDownload }
        XCTAssertEqual(changedURLs.last, server.url("/initial").absoluteString)
        XCTAssertNil(page.errorMessage)
        let completion = try XCTUnwrap(chooseDestination)
        completion(destination)
        chooseDestination = nil
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertEqual(try Data(contentsOf: destination), Data("HTTP download bytes".utf8))
        let dom = try await page.currentDOM()
        XCTAssertTrue(dom.contains("Still here"))
        let initialRequests = server.requests.filter { $0.path == "/initial" }.count
        page.reload()
        try await waitFor {
            server.requests.filter { $0.path == "/initial" }.count > initialRequests
                && page.webView.title == "Initial" && !page.webView.isLoading
        }
        XCTAssertEqual(server.requests.filter { $0.path == "/download" }.count, 1)
        page.navigate(to: server.url("/follow-up"))
        try await waitFor { page.webView.title == "Follow-up" && !page.webView.isLoading }
        page.navigate(to: server.url("/fails"))
        try await waitFor { page.errorMessage != nil }
    }

    func testHTTPDownloadActionKeepsCommittedPageUsable() async throws {
        let server = try LocalHTTPFixture { request in
            switch request.path {
            case "/download":
                return .init(body: "HTTP download bytes")
            case "/follow-up":
                return .init(body: "<title>Follow-up</title><body>Ready</body>")
            default:
                return .init(body: "<title>Action</title><a id='download' href='/download' download>Download</a><body>Still here</body>")
            }
        }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleHTTPDownloadAction-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("payload.txt")
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        var transfer: (any EngineDownload)?
        defer { transfer?.detach() }
        let finished = expectation(description: "download action finishes")
        page.events.onDownload = { download in
            transfer = download
            download.onDestination = { _, completion in completion(destination) }
            download.onFinish = { finished.fulfill() }
            download.onFailure = { error in XCTFail("Download failed: \(error)") }
            download.start()
        }
        page.navigate(to: server.url("/initial"))
        try await waitFor { page.webView.title == "Action" && !page.webView.isLoading }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#download').click()")
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertEqual(try Data(contentsOf: destination), Data("HTTP download bytes".utf8))
        XCTAssertNil(page.errorMessage)
        let dom = try await page.currentDOM()
        XCTAssertTrue(dom.contains("Still here"))
        page.navigate(to: server.url("/follow-up"))
        try await waitFor { page.webView.title == "Follow-up" && !page.webView.isLoading }
    }

    func testHTTPRenderableAttachmentBecomesDownload() async throws {
        let server = try LocalHTTPFixture { request in
            if request.path == "/chrome.svg" {
                return .init(headers: [
                    "Content-Type": "image/svg+xml",
                    "Content-Disposition": "attachment; filename=chrome.svg"
                ], body: "<svg xmlns='http://www.w3.org/2000/svg'/>")
            }
            return .init(body: "<title>SVG Repo</title><a id='download' href='/chrome.svg'>Download SVG</a><body>Still here</body>")
        }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSVGDownload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("chrome.svg")
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        var transfer: (any EngineDownload)?
        defer { transfer?.detach() }
        let finished = expectation(description: "renderable attachment download finishes")
        page.events.onDownload = { download in
            transfer = download
            download.onDestination = { name, completion in
                XCTAssertEqual(name, "chrome.svg")
                completion(destination)
            }
            download.onFinish = { finished.fulfill() }
            download.onFailure = { error in XCTFail("Download failed: \(error)") }
            download.start()
        }
        page.navigate(to: server.url("/"))
        try await waitFor { page.webView.title == "SVG Repo" && !page.webView.isLoading }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#download').click()")
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "<svg xmlns='http://www.w3.org/2000/svg'/>")
        XCTAssertNil(page.errorMessage)
        XCTAssertEqual(page.webView.title, "SVG Repo")
        let dom = try await page.currentDOM()
        XCTAssertTrue(dom.contains("Still here"))
    }

    func testHTTPRedirectRecordsOnlyFinalDestinationAndDoesNotReload() async throws {
        let server = try LocalHTTPFixture { request in
            if request.path == "/redirect" {
                return .init(status: "302 Found", headers: ["Location": "/final"])
            }
            return .init(body: "<title>HTTP final</title><body>Ready</body>")
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        var visits: [String] = []
        page.events.onVisit = { _, url, _ in visits.append(url) }
        page.navigate(to: server.url("/redirect"))
        try await waitFor { page.webView.title == "HTTP final" && !page.webView.isLoading }
        XCTAssertEqual(page.webView.url, server.url("/final"))
        XCTAssertEqual(visits, [server.url("/final").absoluteString])
        XCTAssertEqual(server.requests.filter { $0.path == "/redirect" }.count, 1)
        XCTAssertEqual(server.requests.filter { $0.path == "/final" }.count, 1)
        page.reload()
        try await waitFor { server.requests.filter { $0.path == "/final" }.count == 2 }
    }

    func testHTTPFormRedirectsPreserveOrConvertPostAsRequired() async throws {
        let server = try LocalHTTPFixture { request in
            switch request.path {
            case "/form":
                return .init(body: "<title>Form</title><form method='post'><input name='draft' value='hello world'></form>")
            case "/303": return .init(status: "303 See Other", headers: ["Location": "/result303"])
            case "/307": return .init(status: "307 Temporary Redirect", headers: ["Location": "/result307"])
            default: return .init(body: "<title>Result</title><body>Submitted</body>")
            }
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        for status in [303, 307] {
            page.navigate(to: server.url("/form"))
            try await waitFor { page.webView.title == "Form" && !page.webView.isLoading }
            _ = try await page.webView.evaluateJavaScript("document.forms[0].action = '/\(status)'; document.forms[0].submit(); void 0")
            try await waitFor { page.webView.url == server.url("/result\(status)") && !page.webView.isLoading }
            let original = try XCTUnwrap(server.requests.first { $0.path == "/\(status)" })
            let redirected = try XCTUnwrap(server.requests.first { $0.path == "/result\(status)" })
            XCTAssertEqual(original.method, "POST")
            XCTAssertEqual(original.body, "draft=hello+world")
            XCTAssertEqual(redirected.method, status == 303 ? "GET" : "POST")
            XCTAssertEqual(redirected.body, status == 303 ? "" : original.body)
            XCTAssertEqual(server.requests.filter { $0.path == "/result\(status)" }.count, 1)
            page.reload()
            if status == 303 {
                try await waitFor { server.requests.filter { $0.path == "/result303" }.count == 2 }
            } else {
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(server.requests.filter { $0.path == "/result307" }.count, 1)
            }
        }
    }

    func testHTTPBackForwardKeepsEachPagesHistoryIndependent() async throws {
        let server = try LocalHTTPFixture { request in
            .init(body: "<title>\(request.path)</title><body><input value=''><div style='height:4000px'>Long page</div></body>")
        }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let other = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close(); other.close() }
        page.navigate(to: server.url("/first"))
        other.navigate(to: server.url("/other"))
        try await waitFor { page.webView.title == "/first" && other.webView.title == "/other" && !page.webView.isLoading && !other.webView.isLoading }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('input').value = 'retained draft'; void 0")
        page.navigate(to: server.url("/second"))
        try await waitFor { page.webView.title == "/second" && !page.webView.isLoading }
        XCTAssertTrue(page.webView.canGoBack)
        XCTAssertFalse(other.webView.canGoBack)
        page.goBack()
        try await waitFor { page.webView.title == "/first" && !page.webView.isLoading }
        let restored = try await page.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(restored, "retained draft")
        XCTAssertTrue(page.webView.canGoForward)
        page.goForward()
        try await waitFor { page.webView.title == "/second" && !page.webView.isLoading }
        XCTAssertEqual(other.webView.url, server.url("/other"))
    }

    func testHTTPAllowedPopupRetainsOpenerAndClosesThroughPageEvent() async throws {
        let server = try LocalHTTPFixture { request in .init(body: "<title>\(request.path)</title><body>Popup fixture</body>") }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePopupFixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SiteSettingsStore(directory: directory)
        var setting = settings.setting(origin: server.url("/"), profileID: Profile.defaultID)
        setting.popups = .allow
        settings.update(setting)
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), siteSettings: settings) { _, _, _ in }
        var children: [WebKitPage] = []
        var closeCount = 0
        defer { page.close(); children.forEach { $0.close() } }
        page.events.onCreatePage = { child in
            guard let child = child as? WebKitPage else { return false }
            children.append(child)
            child.events.onClose = { closeCount += 1; child.close() }
            return true
        }
        page.navigate(to: server.url("/parent"))
        try await waitFor { page.webView.title == "/parent" && !page.webView.isLoading }
        _ = try await page.webView.evaluateJavaScript("window.popup = window.open('/child'); void 0")
        try await waitFor { children.first?.webView.title == "/child" && children.first?.webView.isLoading == false }
        let child = try XCTUnwrap(children.first)
        XCTAssertEqual(children.count, 1)
        XCTAssertTrue(child.webView.configuration.websiteDataStore === page.webView.configuration.websiteDataStore)
        let openerTitle = try await child.webView.evaluateJavaScript("window.opener.document.title") as? String
        XCTAssertEqual(openerTitle, "/parent")
        _ = try await page.webView.evaluateJavaScript("window.popup.close(); void 0")
        try await waitFor { closeCount == 1 }
        XCTAssertEqual(child.state.lifecycle, .closed)
        XCTAssertEqual(page.webView.title, "/parent")
    }

    func testDefaultPopupPolicyBlocksEarlyScriptAndAcceptsWebKitGesture() async throws {
        let server = try LocalHTTPFixture { _ in .init(body: "<title>Parent</title><script>window.popup = window.open('/child')</script>") }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        var children: [any BrowserPage] = []
        defer { page.close(); children.forEach { $0.close() } }
        page.events.onCreatePage = { child in children.append(child); return true }
        page.navigate(to: server.url("/parent"))
        try await waitFor { page.webView.title == "Parent" && !page.webView.isLoading }
        let blocked = try await page.webView.evaluateJavaScript("window.popup === null") as? Bool
        XCTAssertEqual(blocked, true)
        XCTAssertTrue(children.isEmpty)
        _ = try await page.webView.evaluateJavaScript("window.open('/child'); void 0")
        try await waitFor { children.count == 1 }
    }

    func testJavaScriptConfirmCancelsOnceOnTabSwitchButNotRepeatedActivation() async throws {
        let first = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let second = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let container = BrowserPageContainer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.mount(first)
        window.makeKeyAndOrderFront(nil)
        defer { container.unmount(); first.close(); second.close(); window.contentView = nil; window.close() }
        first.navigate(to: htmlURL(title: "Active dialog"))
        try await waitFor { first.webView.title == "Active dialog" && !first.webView.isLoading }
        let finished = expectation(description: "Confirm resolves once when its tab is detached")
        finished.assertForOverFulfill = true
        var completionCount = 0
        first.webView.evaluateJavaScript("confirm('Switch tabs fixture')") { result, error in
            completionCount += 1
            XCTAssertNil(error)
            XCTAssertEqual(result as? Bool, false)
            finished.fulfill()
        }
        try await waitFor { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        container.mount(first)
        first.setActive(true)
        await Task.yield()
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertEqual(completionCount, 0)
        container.mount(second)
        first.setActive(false)
        container.mount(second)
        await fulfillment(of: [finished], timeout: 5)
        try await waitFor { window.attachedSheet == nil }
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(first.state.lifecycle, .ready)
        container.mount(first)
        let answer = try await first.webView.evaluateJavaScript("40 + 2") as? Int
        XCTAssertEqual(answer, 42)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(completionCount, 1)
    }

    func testJavaScriptConfirmIsCancelledWhenOriginatingPageCloses() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        page.navigate(to: htmlURL(title: "Dialog"))
        try await waitFor { page.webView.title == "Dialog" && !page.webView.isLoading }
        let finished = expectation(description: "JavaScript delegate completion resolves after close")
        page.webView.evaluateJavaScript("confirm('Cobble local fixture')") { _, _ in finished.fulfill() }
        try await waitFor { window.attachedSheet != nil }
        page.close()
        await fulfillment(of: [finished], timeout: 5)
        try await waitFor { window.attachedSheet == nil }
        XCTAssertEqual(page.state.lifecycle, .closed)
    }

    func testIndependentTabsRetainDocumentStateWhenRemounted() async throws {
        let firstID = UUID()
        let secondID = UUID()
        var changes: [(UUID, String, String)] = []
        let first = WebKitPage(tabID: firstID, dataStore: .nonPersistent()) { changes.append(($0, $1, $2)) }
        let second = WebKitPage(tabID: secondID, dataStore: .nonPersistent()) { changes.append(($0, $1, $2)) }
        defer { first.close(); second.close() }
        let firstView = first.webView
        let secondView = second.webView
        XCTAssertFalse(firstView === secondView)
        first.navigate(to: htmlURL(title: "First"))
        second.navigate(to: htmlURL(title: "Second"))
        try await waitFor {
            changes.contains { $0.0 == firstID && $0.2 == "First" }
                && changes.contains { $0.0 == secondID && $0.2 == "Second" }
        }
        _ = try await firstView.evaluateJavaScript("document.querySelector('input').value = 'unsaved draft'")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.addSubview(firstView)
        firstView.removeFromSuperview()
        container.addSubview(secondView)
        secondView.removeFromSuperview()
        container.addSubview(first.webView)
        XCTAssertTrue(firstView === first.webView)
        let draft = try await firstView.evaluateJavaScript("document.querySelector('input').value") as? String
        let otherDraft = try await secondView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(draft, "unsaved draft")
        XCTAssertEqual(otherDraft, "")
        XCTAssertFalse(changes.contains { $0.0 == firstID && $0.2 == "Second" })
        XCTAssertFalse(changes.contains { $0.0 == secondID && $0.2 == "First" })
    }

    func testPageInitiatedURLAndTitleUpdatesDoNotReloadDocument() async throws {
        let id = UUID()
        var changes: [(String, String)] = []
        let host = WebKitPage(tabID: id, dataStore: .nonPersistent()) { _, url, title in changes.append((url, title)) }
        defer { host.close() }
        let url = URL(string: "https://cobble.test/page")!
        host.webView.loadSimulatedRequest(URLRequest(url: url),
            responseHTML: "<html><head><title>Initial</title></head><body></body></html>")
        try await waitFor { changes.contains { $0.1 == "Initial" } }
        _ = try await host.webView.evaluateJavaScript("window.cobbleMarker = 'retained'; location.hash = 'changed'; document.title = 'Changed';")
        try await waitFor { changes.contains { $0.0.hasSuffix("#changed") && $0.1 == "Changed" } }
        let marker = try await host.webView.evaluateJavaScript("window.cobbleMarker") as? String
        XCTAssertEqual(marker, "retained")
        XCTAssertNil(host.errorMessage)
    }

    func testRememberedZoomFollowsCommittedOriginsAndPrivatePagesStayLocal() async throws {
        let destination = try LocalHTTPFixture { _ in .init(body: "<title>Zoom destination</title><body>Destination</body>") }
        try await destination.start()
        let source = try LocalHTTPFixture { request in
            request.path == "/redirect"
                ? .init(status: "302 Found", headers: ["Location": destination.url("/final").absoluteString])
                : .init(body: "<title>Zoom source</title><body>Source</body>")
        }
        try await source.start()
        defer { source.stop(); destination.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSiteZoom-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SiteSettingsStore(directory: directory)
        settings.update(SiteSetting(profileID: Profile.defaultID, origin: destination.url("/").absoluteString, camera: .deny))
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), siteSettings: settings) { _, _, _ in }
        let other = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), siteSettings: settings) { _, _, _ in }
        let privatePage = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), siteSettings: settings, isPrivate: true) { _, _, _ in }
        defer { page.close(); other.close(); privatePage.close() }
        page.navigate(to: source.url("/start"))
        try await waitFor { page.webView.title == "Zoom source" && !page.webView.isLoading }
        page.zoom(by: 2)
        XCTAssertEqual(settings.setting(origin: source.url("/"), profileID: Profile.defaultID).zoom, 2)
        other.navigate(to: source.url("/other"))
        try await waitFor { other.webView.title == "Zoom source" && !other.webView.isLoading }
        XCTAssertEqual(other.webView.pageZoom, 2)
        page.navigate(to: source.url("/redirect"))
        try await waitFor { page.webView.title == "Zoom destination" && !page.webView.isLoading }
        XCTAssertEqual(page.webView.pageZoom, 1, "Redirect destination must not inherit the source origin's zoom")
        page.zoom(by: 1.5)
        XCTAssertEqual(settings.setting(origin: destination.url("/"), profileID: Profile.defaultID).zoom, 1.5)
        privatePage.navigate(to: source.url("/private"))
        try await waitFor { privatePage.webView.title == "Zoom source" && !privatePage.webView.isLoading }
        XCTAssertEqual(privatePage.webView.pageZoom, 1)
        privatePage.zoom(by: 1.2)
        privatePage.navigate(to: destination.url("/private"))
        try await waitFor { privatePage.webView.title == "Zoom destination" && !privatePage.webView.isLoading }
        XCTAssertEqual(privatePage.webView.pageZoom, 1.2, accuracy: 0.001)
        privatePage.applySiteSettings()
        privatePage.resetZoom()
        XCTAssertEqual(settings.setting(origin: source.url("/"), profileID: Profile.defaultID).zoom, 2)
        XCTAssertEqual(settings.setting(origin: destination.url("/"), profileID: Profile.defaultID).zoom, 1.5)
        page.resetZoom()
        XCTAssertNil(settings.setting(origin: destination.url("/"), profileID: Profile.defaultID).zoom)
        XCTAssertEqual(settings.setting(origin: destination.url("/"), profileID: Profile.defaultID).camera, .deny)
    }

    func testBlankNormalizationZoomBoundsAndCloseCleanup() async throws {
        var urls: [String] = []
        let host = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, url, _ in urls.append(url) }
        let view = host.webView
        host.navigate(to: nil)
        try await waitFor { urls.contains("") }
        XCTAssertFalse(urls.contains("about:blank"))
        host.zoom(by: 100)
        XCTAssertEqual(view.pageZoom, 3)
        host.zoom(by: 0.001)
        XCTAssertEqual(view.pageZoom, 0.5)
        host.resetZoom()
        XCTAssertEqual(view.pageZoom, 1)
        host.close()
        host.close()
        XCTAssertNil(view.navigationDelegate)
        XCTAssertNil(view.uiDelegate)
        let count = urls.count
        host.navigate(to: htmlURL(title: "Closed"))
        await Task.yield()
        XCTAssertEqual(urls.count, count)
    }

    func testRetryAfterInitialProvisionalFailureLoadsRequestedPage() async throws {
        for fromOrigin in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePageTest-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("retry.html")
            var title = ""
            let host = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, updated in title = updated }
            defer { host.close() }
            host.navigate(to: url)
            try await waitFor { host.errorMessage != nil }
            try Data("<html><title>Retry succeeded</title><body>Ready</body></html>".utf8).write(to: url)
            if fromOrigin { host.reloadFromOrigin() } else { host.reload() }
            try await waitFor { title == "Retry succeeded" }
            XCTAssertEqual(host.webView.url, url)
            XCTAssertNil(host.errorMessage)
        }
    }

    func testClientRedirectLoadsDestinationOnlyOnce() async throws {
        let handler = LocalPageHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "cobble-test")
        var title = ""
        let host = WebKitPage(tabID: UUID(), dataStore: configuration.websiteDataStore, configuration: configuration) {
            _, _, updated in title = updated
        }
        defer { host.close() }
        host.navigate(to: URL(string: "cobble-test://pages/redirect")!)
        try await waitFor { title == "Final" && !host.webView.isLoading }
        // Allow queued observations to drain; they must not issue another navigation.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handler.requests["/redirect"], 1)
        XCTAssertEqual(handler.requests["/final"], 1)
    }

    func testProcessTerminationCallbackRetriesOnceThenStops() async throws {
        let handler = LocalPageHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "cobble-test")
        let host = WebKitPage(tabID: UUID(), dataStore: configuration.websiteDataStore, configuration: configuration) { _, _, _ in }
        defer { host.close() }
        host.navigate(to: URL(string: "cobble-test://pages/final")!)
        try await waitFor { handler.requests["/final"] == 1 && host.webView.title == "Final" && !host.webView.isLoading }
        // Exercise the public delegate callback without killing unrelated WebKit processes.
        host.webViewWebContentProcessDidTerminate(host.webView)
        try await waitFor { handler.requests["/final"] == 2 && !host.isCrashed && !host.webView.isLoading }
        host.webViewWebContentProcessDidTerminate(host.webView)
        XCTAssertTrue(host.isCrashed)
        XCTAssertNotNil(host.errorMessage)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handler.requests["/final"], 2)
    }

    func testProcessTerminationDoesNotReplayPost() async throws {
        let handler = LocalPageHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "cobble-test")
        let host = WebKitPage(tabID: UUID(), dataStore: configuration.websiteDataStore, configuration: configuration) { _, _, _ in }
        defer { host.close() }
        var request = URLRequest(url: URL(string: "cobble-test://pages/final")!)
        request.httpMethod = "POST"
        request.httpBody = Data("purchase=1".utf8)
        host.webView.load(request)
        try await waitFor { handler.requests["/final"] == 1 && host.webView.title == "Final" && !host.webView.isLoading }
        host.webViewWebContentProcessDidTerminate(host.webView)
        XCTAssertTrue(host.isCrashed)
        XCTAssertNotNil(host.errorMessage)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handler.requests["/final"], 1)
    }

    func testHistoryVisitsAreSeparateFromMetadataObservations() async throws {
        let id = UUID()
        var titles: [String] = []
        var visits: [(UUID, String, String)] = []
        let config = iconConfiguration(fetchScript: "globalThis.fetch = async () => new Response(null, {status: 404});")
        let host = WebKitPage(tabID: id, dataStore: config.websiteDataStore, configuration: config) { _, _, title in titles.append(title) }
        host.events.onVisit = { visits.append(($0, $1, $2)) }
        defer { host.close() }
        let url = URL(string: "https://cobble.test/history")!
        let navigation = host.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<html><title>Visited</title><body>Offline fixture</body></html>")
        try await waitFor { visits.count == 1 }
        XCTAssertEqual(visits.first?.0, id)
        XCTAssertEqual(visits.first?.1, url.absoluteString)
        _ = try await host.webView.evaluateJavaScript("document.title = 'Metadata update'")
        try await waitFor { titles.last == "Metadata update" }
        host.webView(host.webView, didFinish: navigation)
        XCTAssertEqual(visits.count, 1)
        host.navigate(to: nil)
        try await waitFor { titles.last == "New Tab" }
        XCTAssertEqual(visits.count, 1)
    }

    func testSameDocumentRoutesEnterLocalHistoryOnce() async throws {
        var visits: [String] = []
        let config = iconConfiguration(fetchScript: "globalThis.fetch = async () => new Response(null, {status: 404});")
        let page = WebKitPage(tabID: UUID(), dataStore: config.websiteDataStore, configuration: config) { _, _, _ in }
        page.events.onVisit = { _, url, _ in visits.append(url) }
        defer { page.close() }
        let base = URL(string: "https://cobble.test/start")!
        page.webView.loadSimulatedRequest(URLRequest(url: base), responseHTML: "<title>Routes</title>")
        try await waitFor { visits == [base.absoluteString] }
        _ = try await page.webView.evaluateJavaScript("history.pushState(null, '', '/next')")
        try await waitFor { visits.count == 2 }
        XCTAssertEqual(visits, [base.absoluteString, "https://cobble.test/next"])
        _ = try await page.webView.evaluateJavaScript("document.title = 'Renamed'")
        try await waitFor { page.state.title == "Renamed" }
        XCTAssertEqual(visits.count, 2)
    }

    func testBlankCommandSupersedesQueuedPageObservations() async throws {
        var urls: [String] = []
        let host = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, url, _ in urls.append(url) }
        defer { host.close() }
        host.navigate(to: htmlURL(title: "Old"))
        try await waitFor { host.webView.title == "Old" }
        host.navigate(to: nil)
        try await waitFor { urls.last == "" && !host.webView.isLoading }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(urls.last, "")
        XCTAssertEqual(host.webView.url?.absoluteString, "about:blank")
    }

    func testFaviconUsesIsolatedWebKitFetchAndClearsForBlank() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII="
        let script = """
        globalThis.cobbleIconURL = null;
        globalThis.fetch = async function(url) {
            globalThis.cobbleIconURL = url;
            const bytes = Uint8Array.from(atob('\(png)'), character => character.charCodeAt(0));
            return new Response(bytes, {headers: {'content-type': 'image/png'}});
        };
        """
        let config = iconConfiguration(fetchScript: script)
        let host = WebKitPage(tabID: UUID(), dataStore: config.websiteDataStore, configuration: config) { _, _, _ in }
        defer { host.close() }
        host.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://cobble.test/page")!), responseHTML:
            "<html><head><title>Icon</title><link rel='icon' href='https://elsewhere.test/icon.png'></head><body>Offline fixture</body></html>")
        try await waitFor { host.favicon != nil }
        XCTAssertNotNil(host.favicon)
        let selectedURL: String? = try await withCheckedThrowingContinuation { continuation in
            host.webView.callAsyncJavaScript("return globalThis.cobbleIconURL", arguments: [:], in: nil, in: .defaultClient) { result in
                continuation.resume(with: result.map { $0 as? String })
            }
        }
        XCTAssertEqual(selectedURL, "https://elsewhere.test/icon.png")
        host.navigate(to: nil)
        XCTAssertNil(host.favicon)
        try await waitFor { host.webView.url?.absoluteString == "about:blank" && !host.webView.isLoading }
        XCTAssertNil(host.favicon)
    }

    func testFaviconFallsBackWhenTheDocumentIconFetchFails() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII="
        let script = """
        globalThis.cobbleIconURLs = [];
        globalThis.fetch = async function(url) {
            globalThis.cobbleIconURLs.push(url);
            if (!String(url).includes('/favicon.ico')) throw new TypeError('Failed to fetch');
            const bytes = Uint8Array.from(atob('\(png)'), character => character.charCodeAt(0));
            return new Response(bytes, {headers: {'content-type': 'image/png'}});
        };
        """
        let config = iconConfiguration(fetchScript: script)
        let host = WebKitPage(tabID: UUID(), dataStore: config.websiteDataStore, configuration: config) { _, _, _ in }
        defer { host.close() }
        host.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://cobble.test/page")!), responseHTML:
            "<html><head><title>Icon</title><link rel='icon' href='https://gstatic.com/missing.png'></head><body>Offline fixture</body></html>")
        try await waitFor { host.favicon != nil }
        let requested: [String]? = try await withCheckedThrowingContinuation { continuation in
            host.webView.callAsyncJavaScript("return globalThis.cobbleIconURLs", arguments: [:], in: nil, in: .defaultClient) { result in
                continuation.resume(with: result.map { $0 as? [String] })
            }
        }
        XCTAssertEqual(requested, ["https://gstatic.com/missing.png", "https://cobble.test/favicon.ico"])
    }

    func testFaviconFollowsCrossOriginRedirectWithoutCORS() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        let icons = try LocalHTTPFixture { _ in .init(headers: ["Content-Type": "image/png"], data: png) }
        try await icons.start()
        defer { icons.stop() }
        let pageServer = try LocalHTTPFixture { request in
            request.path == "/favicon.ico"
                ? .init(status: "302 Found", headers: ["Location": icons.url("/icon.png").absoluteString])
                : .init(body: "<title>Icon</title>")
        }
        try await pageServer.start()
        defer { pageServer.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        page.navigate(to: pageServer.url("/page"))
        try await waitFor { page.favicon != nil }
        XCTAssertNotNil(page.favicon)
        XCTAssertTrue(pageServer.requests.contains { $0.path == "/favicon.ico" && $0.headers["range"] == "bytes=0-65535" })
    }

    func testFaviconSurvivesSameOriginAddressChangeDuringFetch() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII="
        let script = """
        globalThis.fetch = async function(url) {
            history.replaceState(null, '', '/joined-meeting');
            const bytes = Uint8Array.from(atob('\(png)'), character => character.charCodeAt(0));
            return new Response(bytes, {headers: {'content-type': 'image/png'}});
        };
        """
        let config = iconConfiguration(fetchScript: script)
        let host = WebKitPage(tabID: UUID(), dataStore: config.websiteDataStore, configuration: config) { _, _, _ in }
        defer { host.close() }
        host.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://cobble.test/page")!), responseHTML:
            "<html><head><title>Icon</title><link rel='icon' href='https://elsewhere.test/icon.png'></head><body>Offline fixture</body></html>")
        try await waitFor { host.favicon != nil }
        XCTAssertEqual(host.webView.url?.path, "/joined-meeting")
    }

    func testPageConnectionClassificationAndHoveredLinkParsing() {
        XCTAssertEqual(PageConnection.classify(urlString: "https://cobble.test/x"), .unknown)
        XCTAssertEqual(PageConnection.classify(urlString: "http://cobble.test/x"), .insecure)
        XCTAssertEqual(PageConnection.classify(urlString: "about:blank"), .empty)
        XCTAssertEqual(PageConnection.classify(urlString: "https://cobble.test/x", hasOnlySecureContent: true), .secure)
        XCTAssertEqual(PageConnection.classify(urlString: "https://cobble.test/x", hasOnlySecureContent: false), .mixed)
        XCTAssertEqual(PageConnection.classify(urlString: "http://cobble.test/x", hasOnlySecureContent: true), .insecure)
        XCTAssertEqual(PageConnection.classify(urlString: "about:blank", hasOnlySecureContent: true), .empty)
        XCTAssertEqual(PageConnection.classify(urlString: "", hasOnlySecureContent: true), .empty)
        XCTAssertEqual(WebKitPage.hoveredLink(from: ["WebKitLinkURL": URL(string: "https://cobble.test/dest")!]), "https://cobble.test/dest")
        XCTAssertEqual(WebKitPage.hoveredLink(from: ["LinkURL": "https://cobble.test/alt"]), "https://cobble.test/alt")
        XCTAssertNil(WebKitPage.hoveredLink(from: ["WebKitLinkURL": URL(string: "javascript:alert(1)")!]))
        XCTAssertNil(WebKitPage.hoveredLink(from: [:]))
        let details = PageConnectionDetails(url: URL(string: "https://cobble.test")!, connection: .secure,
            certificate: nil, certificateErrors: [], mixedContent: PageMixedContentDetails(
                displayed: false, ran: false, containedForm: false,
                displayedWithCertificateErrors: false, ranWithCertificateErrors: false))
        XCTAssertTrue(details.certificateChain.isEmpty)
        XCTAssertFalse(details.certificateChainTruncated)
        XCTAssertEqual(details.connection, .secure)
    }

    func testConnectionDetailsRevisionClearsAndRefreshesAcrossSameURLReload() async throws {
        let server = try LocalHTTPFixture { _ in .init(body: "<title>Security revision</title>") }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        page.navigate(to: server.url("/same"))
        try await waitFor { page.state.connectionDetailsReady }
        let firstRevision = page.state.connectionDetailsRevision
        let loaded = try await page.connectionDetails()
        let first = try XCTUnwrap(loaded)
        XCTAssertEqual(first.url, server.url("/same"))
        XCTAssertEqual(first.connection, .insecure)
        XCTAssertFalse(first.mixedContent.hasIssues)
        XCTAssertTrue(first.certificateErrors.isEmpty)

        page.reload()
        XCTAssertFalse(page.state.connectionDetailsReady)
        XCTAssertNotEqual(page.state.connectionDetailsRevision, firstRevision)
        try await waitFor { page.state.connectionDetailsReady }
        XCTAssertNotEqual(page.state.connectionDetailsRevision, firstRevision)
        let reloaded = try await page.connectionDetails()
        XCTAssertEqual(reloaded?.url, server.url("/same"))
        XCTAssertEqual(reloaded?.connection, .insecure)
        XCTAssertFalse(reloaded?.mixedContent.hasIssues ?? true)
    }

    func testConnectionDetailsDoesNotInventMixedContentKinds() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        page.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://cobble.test/page")!),
            responseHTML: "<title>Padlock</title><body><img src='http://insecure.test/x.png'></body>")
        try await waitFor { page.state.connectionDetailsReady }
        let loaded = try await page.connectionDetails()
        let details = try XCTUnwrap(loaded)
        XCTAssertEqual(details.connection, page.state.connection)
        XCTAssertFalse(details.mixedContent.displayed)
        XCTAssertFalse(details.mixedContent.ran)
        XCTAssertFalse(details.mixedContent.hasIssues)
        XCTAssertTrue(details.certificateErrors.isEmpty)
    }

    func testAudioMuteSurvivesNavigationAndRejectsClosedPages() async throws {
        let host = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { host.close() }
        XCTAssertTrue(host.capabilities.pageOperations.contains(.muteAudio))
        XCTAssertFalse(host.state.isAudioMuted)
        _ = host.webView
        try host.setAudioMuted(true)
        XCTAssertTrue(host.state.isAudioMuted)
        try host.setAudioMuted(false)
        XCTAssertFalse(host.state.isAudioMuted)
        try host.setAudioMuted(true)
        host.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://cobble.test/media")!),
            responseHTML: "<html><head><title>Media</title></head><body>quiet</body></html>")
        try await waitFor { host.webView.title == "Media" && !host.webView.isLoading }
        XCTAssertTrue(host.state.isAudioMuted)
        XCTAssertTrue(WebKitAudioMute.isMuted(host.webView))
        host.close()
        XCTAssertThrowsError(try host.setAudioMuted(false))
    }

    func testClosedPageDoesNotReincarnateWebView() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        _ = page.webView
        XCTAssertNotNil(page.storedWebViewForExtensions)
        XCTAssertTrue(page.nativeView is WKWebView)
        page.close()
        XCTAssertEqual(page.state.lifecycle, .closed)
        XCTAssertNil(page.storedWebViewForExtensions)
        XCTAssertFalse(page.nativeView is WKWebView)

        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("CobbleClosedWebView-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        try #"{"manifest_version":3,"name":"Closed page fixture","version":"1"}"#
            .write(to: resources.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let webExtension = try await WKWebExtension(resourceBaseURL: resources)
        let extensionContext = WKWebExtensionContext(for: webExtension)
        XCTAssertNil(page.webView(for: extensionContext))
        XCTAssertNil(page.storedWebViewForExtensions)
        XCTAssertFalse(page.nativeView is WKWebView)

        _ = page.webView
        XCTAssertNil(page.storedWebViewForExtensions)
        XCTAssertFalse(page.nativeView is WKWebView)
    }

    func testPopupPolicyUsesWebKitGestureUnlessSiteAllowsOrDenies() throws {
        XCTAssertTrue(WebKitPage.allowsPopup(navigationType: .other, popups: .ask, isPrivate: false, automaticWindowsAllowed: false))
        XCTAssertTrue(WebKitPage.allowsPopup(navigationType: .other, popups: .allow, isPrivate: false, automaticWindowsAllowed: true))
        XCTAssertFalse(WebKitPage.allowsPopup(navigationType: .other, popups: .deny, isPrivate: false, automaticWindowsAllowed: true))
        XCTAssertTrue(WebKitPage.allowsPopup(navigationType: .linkActivated, popups: .deny, isPrivate: false, automaticWindowsAllowed: false))
        XCTAssertTrue(WebKitPage.allowsPopup(navigationType: .other, popups: .deny, isPrivate: true, automaticWindowsAllowed: false))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePopupSettings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteSettingsStore(directory: directory)
        var setting = store.setting(origin: URL(string: "https://cobble.test")!, profileID: Profile.defaultID)
        setting.popups = .allow
        store.update(setting)
        let allowed = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(), siteSettings: store) { _, _, _ in }
        defer { allowed.close() }
        allowed.state.urlString = "https://cobble.test/page"
        allowed.applySiteSettings()
        XCTAssertTrue(allowed.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        let blocked = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { blocked.close() }
        XCTAssertFalse(blocked.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }

    func testClientCertificateMatchingAcceptsUntrustedServerNamedRootWithoutInteraction() throws {
        var originalSearchList: CFArray?
        XCTAssertEqual(SecKeychainCopySearchList(&originalSearchList), errSecSuccess)
        let isolatedKeychain = try makeClientCertificateKeychain()
        defer { SecKeychainDelete(isolatedKeychain) }

        let unfiltered = WebKitPage.clientCertificateIdentities(
            acceptedIssuers: nil, searchList: [isolatedKeychain])
        let candidate = try XCTUnwrap(unfiltered.identities.first)
        XCTAssertGreaterThanOrEqual(candidate.certificates.count, 3)
        let rootName = try XCTUnwrap(Data(base64Encoded:
            "MB4xHDAaBgNVBAMME0NvYmJsZSBGaXh0dXJlIFJvb3Q="))
        let filtered = WebKitPage.clientCertificateIdentities(
            acceptedIssuers: [rootName], searchList: [isolatedKeychain])
        XCTAssertEqual(filtered.identities.count, 1)
        XCTAssertEqual(try XCTUnwrap(filtered.identities.first).choice.certificate.subject,
                       "Cobble Fixture Client")
        XCTAssertFalse(filtered.truncated)
        var currentSearchList: CFArray?
        XCTAssertEqual(SecKeychainCopySearchList(&currentSearchList), errSecSuccess)
        XCTAssertTrue(CFEqual(originalSearchList, currentSearchList))
    }

    func testStaleClientCertificateCancellationCannotClearReentrantReplacement() throws {
        let keychain = try makeClientCertificateKeychain()
        defer { SecKeychainDelete(keychain) }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent(),
                              clientCertificateSearchList: [keychain]) { _, _, _ in }
        defer { page.close() }
        let space = URLProtectionSpace(host: "mutual-tls.example", port: 443,
            protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        let challenge = URLAuthenticationChallenge(protectionSpace: space,
            proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: ClientCertificateChallengeSender())
        var published: [PageClientCertificateRequest] = []
        var dispositions: [URLSession.AuthChallengeDisposition] = []
        func publishChallenge() {
            page.webView(page.webView, didReceive: challenge) { disposition, _ in
                dispositions.append(disposition)
            }
        }
        page.events.onClientCertificateRequest = { published.append($0) }
        publishChallenge()
        let firstID = try XCTUnwrap(published.first?.id)
        page.events.onPromptCancelled = { id in
            if id == firstID { publishChallenge() }
        }

        page.setActive(false)
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(dispositions, [.cancelAuthenticationChallenge])
        let replacement = try XCTUnwrap(published.last)
        replacement.resolve(try XCTUnwrap(replacement.prompt.choices.first?.id))
        XCTAssertEqual(dispositions, [.cancelAuthenticationChallenge, .useCredential])
    }

    func testDownloadClientCertificatePromptOutlivesTabAndUsesSelectedIdentity() async throws {
        let keychain = try makeClientCertificateKeychain()
        defer { SecKeychainDelete(keychain) }
        let server = try LocalHTTPFixture { _ in .init(body: nil) }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        var nativeDownload: WKDownload?
        var transfer: WebKitDownload?
        defer { transfer?.detach() }
        let started = expectation(description: "WKDownload starts")
        page.webView.startDownload(using: URLRequest(url: server.url("/held"))) { native in
            nativeDownload = native
            transfer = WebKitDownload(native, webView: page.webView, clientCertificateSearchList: [keychain])
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 10)
        let space = URLProtectionSpace(host: "mutual-tls.example", port: 443,
            protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        let challenge = URLAuthenticationChallenge(protectionSpace: space,
            proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: ClientCertificateChallengeSender())
        let unavailable = WebKitDownload(try XCTUnwrap(nativeDownload), webView: page.webView,
            clientCertificateSearchList: [])
        var unavailableDisposition: URLSession.AuthChallengeDisposition?
        unavailable.download(try XCTUnwrap(nativeDownload), didReceive: challenge) { result, _ in
            unavailableDisposition = result
        }
        XCTAssertEqual(unavailableDisposition, .cancelAuthenticationChallenge)
        unavailable.detach()
        transfer?.start()
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?
        try XCTUnwrap(transfer).download(try XCTUnwrap(nativeDownload), didReceive: challenge) { result, choice in
            disposition = result
            credential = choice
        }
        try await waitFor { window.attachedSheet != nil }
        page.close()
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await waitFor { disposition != nil }
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertNotNil(credential?.identity)
        let cancelled = expectation(description: "held native transfer cancels")
        try XCTUnwrap(transfer).cancel { cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 10)
    }

    func testDownloadAuthenticationReentrantReplacementKeepsNewestPrompt() async throws {
        let server = try LocalHTTPFixture { _ in .init(body: nil) }
        try await server.start()
        defer { server.stop() }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.makeKeyAndOrderFront(nil)
        defer { page.close(); window.contentView = nil; window.close() }
        var nativeDownload: WKDownload?
        var transfer: WebKitDownload?
        defer { transfer?.detach() }
        let started = expectation(description: "WKDownload starts")
        page.webView.startDownload(using: URLRequest(url: server.url("/held"))) { native in
            nativeDownload = native
            transfer = WebKitDownload(native, webView: page.webView)
            transfer?.start()
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 10)
        let space = URLProtectionSpace(host: "fixture.example", port: 443,
            protocol: "https", realm: "Fixture",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space,
            proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: ClientCertificateChallengeSender())
        let native = try XCTUnwrap(nativeDownload)
        let candidate = try XCTUnwrap(transfer)
        var first: [URLSession.AuthChallengeDisposition] = []
        var second: [URLSession.AuthChallengeDisposition] = []
        var newest: [URLSession.AuthChallengeDisposition] = []
        candidate.download(native, didReceive: challenge) { disposition, _ in
            first.append(disposition)
            if disposition == .cancelAuthenticationChallenge {
                candidate.download(native, didReceive: challenge) { disposition, _ in
                    newest.append(disposition)
                }
            }
        }
        try await waitFor { window.attachedSheet != nil }
        let originalSheet = try XCTUnwrap(window.attachedSheet)
        candidate.download(native, didReceive: challenge) { disposition, _ in second.append(disposition) }
        XCTAssertEqual(first, [.cancelAuthenticationChallenge])
        XCTAssertEqual(second, [.cancelAuthenticationChallenge])
        try await waitFor { window.attachedSheet != nil && window.attachedSheet !== originalSheet }
        let currentSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(currentSheet, returnCode: .alertSecondButtonReturn)
        try await waitFor { newest.count == 1 }
        XCTAssertEqual(newest, [.cancelAuthenticationChallenge])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        let cancelled = expectation(description: "held native transfer cancels")
        candidate.cancel { cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 10)
    }

    private func makeClientCertificateKeychain() throws -> SecKeychain {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CobbleClientCertificate-\(UUID())")
        var keychain: SecKeychain?
        let password = "cobble-fixture"
        let status = url.path.withCString { path in
            password.withCString { bytes in
                SecKeychainCreate(path, UInt32(password.utf8.count), bytes, false, nil, &keychain)
            }
        }
        XCTAssertEqual(status, errSecSuccess)
        let result = try XCTUnwrap(keychain)
        let payload = try XCTUnwrap(Data(base64Encoded: Self.clientCertificatePKCS12))
        let options = [kSecImportExportPassphrase as String: password,
                       kSecImportExportKeychain as String: result] as CFDictionary
        var imported: CFArray?
        XCTAssertEqual(SecPKCS12Import(payload as CFData, options, &imported), errSecSuccess)
        return result
    }

    private static let clientCertificatePKCS12 = "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"

    private func iconConfiguration(fetchScript: String) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: fetchScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        return configuration
    }

    private func htmlURL(title: String) -> URL {
        let html = "<html><head><title>\(title)</title></head><body><input value=''></body></html>"
        return URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!
    }

    private func waitFor(_ condition: @MainActor () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for local WebKit navigation", file: file, line: line)
    }
}

@MainActor
private final class LocalPageHandler: NSObject, WKURLSchemeHandler {
    var requests: [String: Int] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        requests[url.path, default: 0] += 1
        let html = url.path == "/redirect"
            ? "<html><head><meta http-equiv='refresh' content='0;url=cobble-test://pages/final'><title>Redirect</title></head></html>"
            : "<html><head><title>Final</title></head><body>Local test page</body></html>"
        let data = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
