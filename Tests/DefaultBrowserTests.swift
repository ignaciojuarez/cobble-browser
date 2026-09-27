import XCTest
@testable import Cobble

final class DefaultBrowserTests: XCTestCase {
    func testInfoPlistDeclaresBrowserURLAndHTMLDocumentTypes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("App/Info.plist")) as? [String: Any])
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(Set(schemes), ["http", "https"])
        XCTAssertEqual(urlTypes.first?["CFBundleTypeRole"] as? String, "Editor")

        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let types = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        XCTAssertEqual(types, ["public.html", "public.xhtml"])
        XCTAssertTrue(documents.allSatisfy { $0["LSHandlerRank"] as? String == "Default" })
        XCTAssertEqual(plist["NSUserActivityTypes"] as? [String], ["NSUserActivityTypeBrowsingWeb"])
    }

    func testIncomingURLsAcceptWebAndHTMLOnly() {
        XCTAssertEqual(DefaultBrowser.incoming(URL(string: "https://example.com/a")!), .web(URL(string: "https://example.com/a")!))
        XCTAssertEqual(DefaultBrowser.incoming(URL(string: "http://127.0.0.1/")!), .web(URL(string: "http://127.0.0.1/")!))
        XCTAssertEqual(
            DefaultBrowser.incoming(URL(fileURLWithPath: "/tmp/page.HTML")),
            .localHTML(URL(fileURLWithPath: "/tmp/page.HTML")))
        XCTAssertEqual(
            DefaultBrowser.incoming(URL(fileURLWithPath: "/tmp/index.xhtml")),
            .localHTML(URL(fileURLWithPath: "/tmp/index.xhtml")))
        XCTAssertNil(DefaultBrowser.incoming(URL(fileURLWithPath: "/tmp/secret.pdf")))
        XCTAssertNil(DefaultBrowser.incoming(URL(string: "mailto:a@example.com")!))
        XCTAssertNil(DefaultBrowser.incoming(URL(string: "ftp://example.com/a")!))
    }

    func testDefaultRegistrationSetsHTTPThenHTTPSAndIgnoresHTTPSFailure() {
        let app = URL(fileURLWithPath: "/Applications/Cobble.app")
        var schemes: [String] = []
        var completions: [(Error?) -> Void] = []
        var finished: Error? = NSError(domain: "unset", code: -1)
        DefaultBrowser.setDefault(applicationURL: app, using: { _, scheme, done in
            schemes.append(scheme)
            completions.append(done)
        }) { finished = $0 }
        XCTAssertEqual(schemes, ["http"])
        XCTAssertEqual(completions.count, 1)
        completions[0](nil)
        XCTAssertEqual(schemes, ["http", "https"])
        completions[1](NSError(domain: "https", code: 1))
        XCTAssertNil(finished)
    }

    func testDefaultRegistrationReportsHTTPFailureWithoutClaimingHTTPS() {
        let app = URL(fileURLWithPath: "/Applications/Cobble.app")
        var schemes: [String] = []
        var finished: Error?
        let httpError = NSError(domain: "http", code: 2)
        DefaultBrowser.setDefault(applicationURL: app, using: { _, scheme, done in
            schemes.append(scheme)
            done(httpError)
        }) { finished = $0 }
        XCTAssertEqual(schemes, ["http"])
        XCTAssertEqual((finished as NSError?)?.domain, "http")
    }

    @MainActor func testIncomingWebURLsOpenInTheNormalWindowAndIgnorePrivateAndFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDefaultBrowser-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(store: SessionStore(directory: directory), websiteDataStoreOverride: .nonPersistent())
        let delegate = CobbleApp(model: app)
        defer {
            app.windows.forEach { $0.closePages() }
            app.flush()
            app.library.close()
            withExtendedLifetime(delegate) {}
        }
        let window = try XCTUnwrap(app.windows.first { !$0.isPrivate })
        let before = window.record.tabs.count
        let privateWindow = app.newWindow(isPrivate: true)
        delegate.handleIncomingURLs([
            URL(string: "https://example.com/from-mail")!,
            URL(fileURLWithPath: "/tmp/secret.pdf"),
            URL(string: "mailto:a@example.com")!,
        ])
        XCTAssertEqual(window.record.tabs.count, before + 1)
        XCTAssertEqual(window.selectedTab?.urlString, "https://example.com/from-mail")
        XCTAssertTrue(privateWindow.record.tabs.isEmpty)
        XCTAssertEqual(app.windows.filter { !$0.isPrivate }.count, 1)
    }

    @MainActor func testIncomingHTMLOpensThroughTheLocalFilePath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDefaultBrowserHTML-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(store: SessionStore(directory: directory), websiteDataStoreOverride: .nonPersistent())
        let delegate = CobbleApp(model: app)
        defer {
            app.windows.forEach { $0.closePages() }
            app.flush()
            app.library.close()
            withExtendedLifetime(delegate) {}
        }
        let window = try XCTUnwrap(app.windows.first { !$0.isPrivate })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleIncoming-\(UUID()).html")
        try "<title>Incoming</title>".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        delegate.handleIncomingURLs([file])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while window.selectedTab?.urlString != file.absoluteString, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(window.selectedTab?.urlString, file.absoluteString)
        XCTAssertNotNil(window.selectedTab?.localFileBookmark)
    }
}
