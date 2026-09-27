import XCTest
@testable import Cobble

@MainActor
final class SearchSettingsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSearchTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCustomSearchTemplatesRoundTripEncodeAndRouteBangsLocally() throws {
        let directory = try directory()
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertFalse(preferences.addSearchEngine(name: "Broken", template: "https://example.com/search", bang: "broken"))
        XCTAssertFalse(preferences.addSearchEngine(name: "Broken", template: "javascript:alert({searchTerms})", bang: "broken"))
        XCTAssertFalse(preferences.addSearchEngine(name: "Broken", template: "https://{searchTerms}.example/search?q=x", bang: "broken"))
        XCTAssertFalse(preferences.addSearchEngine(name: "Broken", template: "https://user:{searchTerms}@example.com/search?q=x", bang: "broken"))
        XCTAssertTrue(preferences.addSearchEngine(name: "Docs", template: "https://docs.example/search?q={searchTerms}", bang: "docs"))
        let docs = try XCTUnwrap(preferences.searchEngines.first { $0.name == "Docs" })
        XCTAssertTrue(preferences.setDefaultSearchEngine(docs.id))
        XCTAssertEqual(preferences.bangSuggestions(for: "!do").map(\.id), [docs.id])
        XCTAssertTrue(preferences.bangSuggestions(for: "!docs terms").isEmpty)

        let reopened = BrowserPreferences(directory: directory)
        XCTAssertEqual(reopened.defaultSearchEngine.id, docs.id)
        XCTAssertEqual(reopened.searchEngines.first { $0.id == docs.id }, docs)
        guard case let .navigate(url) = AddressResolver.resolve("!docs swift & URL", engines: reopened.searchEngines,
                                                                defaultEngine: reopened.defaultSearchEngine) else {
            return XCTFail("Expected direct bang routing")
        }
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "swift & URL")
        guard case let .navigate(defaultURL) = AddressResolver.resolve("swift & URL", engines: reopened.searchEngines,
                                                                       defaultEngine: reopened.defaultSearchEngine) else {
            return XCTFail("Expected configured default routing")
        }
        XCTAssertEqual(defaultURL.host, "docs.example")
        guard case .invalid = AddressResolver.resolve("!docs", engines: reopened.searchEngines,
                                                       defaultEngine: reopened.defaultSearchEngine) else {
            return XCTFail("A known bang needs search terms")
        }
        XCTAssertTrue(reopened.updateSearchEngine(id: docs.id, name: "Documentation", template: docs.template, bang: "doc"))
        XCTAssertTrue(reopened.removeSearchEngine(docs.id))
        XCTAssertEqual(reopened.defaultSearchEngine, .duckDuckGo)
    }

    func testPrivateAddressCompletionDoesNotReadBangCatalog() throws {
        let directory = try directory()
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        defer { app.windows.forEach { $0.closePages() }; app.flush(); app.library.close() }
        XCTAssertTrue(app.preferences.addSearchEngine(name: "Docs", template: "https://docs.example/search?q={searchTerms}", bang: "docs"))
        let normal = try XCTUnwrap(app.windows.first)
        normal.focusAddress()
        normal.addressDraft = "!do"
        XCTAssertEqual(normal.bangSuggestions.map(\.bang), ["docs"])

        let privateWindow = app.newWindow(isPrivate: true)
        privateWindow.focusAddress()
        privateWindow.addressDraft = "!do"
        XCTAssertTrue(privateWindow.bangSuggestions.isEmpty)
        XCTAssertTrue(privateWindow.addressSuggestions.isEmpty)
        privateWindow.submitBangSuggestion("docs")
        XCTAssertEqual(privateWindow.addressDraft, "!do")
    }

    func testWebInspectorOptInPersists() throws {
        let directory = try directory()
        let original = BrowserPreferences(directory: directory)
        XCTAssertTrue(original.setDownloadFolder(directory))
        XCTAssertTrue(original.setDefaultSearchEngine("google"))
        let file = directory.appendingPathComponent("browser-preferences.json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        record["version"] = 4
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertFalse(preferences.webInspectorEnabled)
        XCTAssertEqual(preferences.downloadFolderName, directory.lastPathComponent)
        XCTAssertEqual(preferences.defaultSearchEngine.id, "google")
        XCTAssertTrue(preferences.setWebInspectorEnabled(true))
        let restored = BrowserPreferences(directory: directory)
        XCTAssertTrue(restored.webInspectorEnabled)
        XCTAssertEqual(restored.downloadFolderName, directory.lastPathComponent)
        XCTAssertEqual(restored.defaultSearchEngine.id, "google")
    }

    func testConfiguredDefaultRoutesAddressAndCommandSubmissions() throws {
        let directory = try directory()
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        defer { app.windows.forEach { $0.closePages() }; app.flush(); app.library.close() }
        XCTAssertTrue(app.preferences.addSearchEngine(name: "Docs", template: "https://docs.example/search?q={searchTerms}", bang: "docs"))
        let docs = try XCTUnwrap(app.preferences.searchEngines.first { $0.name == "Docs" })
        XCTAssertTrue(app.preferences.setDefaultSearchEngine(docs.id))
        let window = try XCTUnwrap(app.windows.first)
        window.addressDraft = "address query"
        window.submitAddress()
        XCTAssertEqual(window.selectedTab?.url?.host, "docs.example")
        window.commandQuery = "command query"
        window.submitCommand()
        XCTAssertEqual(window.selectedTab?.url?.host, "docs.example")
        XCTAssertEqual(window.record.tabs.count, 2)
    }

    func testFutureSearchPreferencesStayUntouched() throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("browser-preferences.json")
        let future = Data(#"{"version":8,"searchEngines":[]}"#.utf8)
        try future.write(to: url)
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertNotNil(preferences.errorMessage)
        XCTAssertFalse(preferences.addSearchEngine(name: "Docs", template: "https://docs.example/search?q={searchTerms}", bang: "docs"))
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testEmptyEngineIdentifiersCannotDisableBrowsing() throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("browser-preferences.json")
        let invalid = Data(#"{"version":6,"defaultEngine":"","engineRules":[{"host":"example.com","engineID":""}]}"#.utf8)
        try invalid.write(to: url)
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertEqual(preferences.defaultEngine, .webKit)
        XCTAssertNotNil(preferences.errorMessage)
        XCTAssertFalse(preferences.setDefaultEngine(EngineID(rawValue: "")))
        XCTAssertFalse(preferences.setEngineRule(for: URL(string: "https://example.com")!, engineID: EngineID(rawValue: "")))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }
}
