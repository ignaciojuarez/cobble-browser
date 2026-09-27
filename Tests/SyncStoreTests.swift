import AppKit
import XCTest
import WebKit
@testable import Cobble

@MainActor
final class SyncStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSyncStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testPreferencesRoundTripKeepsDeviceChoicesLocal() throws {
        let source = BrowserPreferences(directory: try directory())
        let target = BrowserPreferences(directory: try directory())
        XCTAssertTrue(source.setTheme(.retro))
        XCTAssertTrue(source.setDefaultEngine(EngineID(rawValue: "chromium")))
        XCTAssertTrue(source.setWebInspectorEnabled(true))
        XCTAssertTrue(source.setNewTabsNextToActive(true))
        XCTAssertTrue(source.addSearchEngine(name: "Docs", template: "https://docs.example/?q={searchTerms}", bang: "docs"))
        let docs = try XCTUnwrap(source.searchEngines.first { $0.name == "Docs" })
        XCTAssertTrue(source.setDefaultSearchEngine(docs.id))
        XCTAssertTrue(source.set(BrowserShortcut("m", [.command, .shift]), for: .muteTab))
        XCTAssertTrue(target.setTheme(.legacy))
        XCTAssertTrue(target.setDefaultEngine(.webKit))
        try target.applySyncItems(source.syncItems())
        XCTAssertEqual(target.defaultSearchEngine.id, docs.id)
        XCTAssertTrue(target.newTabsNextToActive)
        XCTAssertEqual(target.shortcut(for: .muteTab), source.shortcut(for: .muteTab))
        XCTAssertEqual(target.theme, .legacy)
        XCTAssertEqual(target.defaultEngine, .webKit)
        XCTAssertFalse(target.webInspectorEnabled)
        XCTAssertFalse(source.syncItems().contains { $0.fields.values.contains("chromium") || $0.fields.values.contains("retro") })
    }

    func testSearchTemplateWithCredentialStaysLocal() throws {
        let source = BrowserPreferences(directory: try directory())
        XCTAssertTrue(source.addSearchEngine(name: "Private API", template: "https://search.example/?q={searchTerms}&api_key=secret", bang: "private"))
        let engine = try XCTUnwrap(source.searchEngines.first { $0.name == "Private API" })
        XCTAssertTrue(source.setDefaultSearchEngine(engine.id))
        let projection = source.syncItems()
        XCTAssertFalse(projection.contains { $0.id == "search:\(engine.id)" })
        XCTAssertEqual(projection.first { $0.id == "preferences" }?.fields["defaultSearchEngineID"], SearchEngine.duckDuckGo.id)
        try source.applySyncItems(projection)
        XCTAssertEqual(source.defaultSearchEngine.id, engine.id)
        XCTAssertTrue(source.searchEngines.contains { $0.id == engine.id })
    }

    func testZoomRoundTripKeepsPermissionsLocal() throws {
        let profile = UUID(), origin = URL(string: "https://example.com/path")!
        let source = SiteSettingsStore(directory: try directory())
        let target = SiteSettingsStore(directory: try directory())
        XCTAssertTrue(source.update(SiteSetting(profileID: profile, origin: origin.absoluteString, camera: .allow, microphone: .allow, popups: .allow, zoom: 1.5)))
        XCTAssertTrue(target.update(SiteSetting(profileID: profile, origin: origin.absoluteString, camera: .deny, microphone: .deny, popups: .deny)))
        let items = source.syncItems(profileIDs: [profile])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].fields.keys.contains("camera"))
        try target.applySyncItems(items, profileIDs: [profile])
        let setting = target.setting(origin: origin, profileID: profile)
        XCTAssertEqual(setting.zoom, 1.5)
        XCTAssertEqual(setting.camera, .deny)
        XCTAssertEqual(setting.microphone, .deny)
        XCTAssertEqual(setting.popups, .deny)
    }

    func testLibraryProjectsAllRowsAndKeepsBookmarkTitleApartFromHistory() throws {
        let profile = UUID()
        let source = LibraryStore(directory: try directory())
        let target = LibraryStore(directory: try directory())
        defer { source.close(); target.close() }
        source.recordVisit(urlString: "https://example.com/report", title: "History title", profileID: profile)
        source.bookmark(urlString: "https://example.com/report", title: "Saved title", profileID: profile)
        for index in 0..<120 {
            source.bookmark(urlString: "https://example.com/\(index)", title: "Saved \(index)", profileID: profile)
        }
        let bookmarks = try source.syncItems(module: .bookmarks, profileIDs: [profile])
        let history = try source.syncItems(module: .history, profileIDs: [profile])
        XCTAssertEqual(bookmarks.count, 121)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(bookmarks.first { $0.fields["url"] == "https://example.com/report" }?.fields["title"], "Saved title")
        XCTAssertEqual(history[0].fields["title"], "History title")
        try target.applySyncItems(bookmarks, module: .bookmarks, profileIDs: [profile])
        try target.applySyncItems(history, module: .history, profileIDs: [profile])
        XCTAssertEqual(target.search("Saved title", profileID: profile, bookmarksOnly: true).first?.title, "Saved title")
        XCTAssertEqual(target.search("History title", profileID: profile, historyOnly: true).first?.title, "History title")
        XCTAssertEqual(try target.syncItems(module: .bookmarks, profileIDs: [profile]).count, 121)
    }

    func testHistoryPruningDoesNotSignalDeletionButExplicitClearDoes() throws {
        let profile = UUID(), store = LibraryStore(directory: try directory())
        defer { store.close() }
        var deleted: [SyncItem] = []
        store.onSyncHistoryDeletion = { deleted += $0 }
        store.setRetentionDays(7, profileID: profile)
        store.recordVisit(urlString: "https://example.com/old", title: "Old", profileID: profile,
                          at: Date().addingTimeInterval(-10 * 86400))
        store.pruneHistory()
        XCTAssertTrue(deleted.isEmpty)
        store.recordVisit(urlString: "https://example.com/new", title: "New", profileID: profile)
        store.clearHistory(profileID: profile)
        XCTAssertEqual(deleted.map { $0.fields["url"] }, ["https://example.com/new"])
    }

    func testFailedHistoryJournalKeepsLocalVisit() throws {
        let profile = UUID(), store = LibraryStore(directory: try directory())
        defer { store.close() }
        store.recordVisit(urlString: "https://example.com/saved", title: "Saved", profileID: profile)
        store.onSyncHistoryDeletion = { _ in throw SyncFailure.localWrite("journal failed") }
        store.clearHistory(profileID: profile)
        XCTAssertEqual(store.search("Saved", profileID: profile, historyOnly: true).count, 1)
        XCTAssertEqual(store.lastError, "journal failed")
    }

    func testClearHistoryTombstonesVisitWithOversizeTitle() throws {
        let profile = UUID(), store = LibraryStore(directory: try directory())
        defer { store.close() }
        let url = "https://example.com/saved"
        store.recordVisit(urlString: url, title: "Short", profileID: profile)
        let expectedID = try XCTUnwrap(store.syncItems(module: .history, profileIDs: [profile]).first?.id)
        store.recordVisit(urlString: url, title: String(repeating: "x", count: 4097), profileID: profile)
        var deleted: [SyncItem] = []
        store.onSyncHistoryDeletion = { deleted += $0 }
        store.clearHistory(profileID: profile)
        XCTAssertEqual(deleted.map(\.id), [expectedID])
    }

    func testSyncRejectsCredentialAndTokenURLs() throws {
        let profile = UUID(), store = LibraryStore(directory: try directory())
        defer { store.close() }
        store.bookmark(urlString: "https://example.com/path?access_token=secret", title: "Token", profileID: profile)
        store.bookmark(urlString: "https://example.com/safe", title: "Safe", profileID: profile)
        XCTAssertEqual(try store.syncItems(module: .bookmarks, profileIDs: [profile]).count, 1)
        var item = try XCTUnwrap(store.syncItems(module: .bookmarks, profileIDs: [profile]).first)
        item.fields["url"] = "https://user:password@example.com/safe"
        XCTAssertThrowsError(try store.applySyncItems([item], module: .bookmarks, profileIDs: [profile]))
        XCTAssertEqual(try store.syncItems(module: .bookmarks, profileIDs: [profile]).count, 1)
    }

    func testOversizeSavedTitleFailsSyncInsteadOfDeletingItsCloudRecord() throws {
        let profile = UUID(), store = LibraryStore(directory: try directory())
        defer { store.close() }
        store.bookmark(urlString: "https://example.com/saved", title: "Saved", profileID: profile)
        XCTAssertEqual(try store.syncItems(module: .bookmarks, profileIDs: [profile]).count, 1)
        store.bookmark(urlString: "https://example.com/saved", title: String(repeating: "x", count: 4097), profileID: profile)
        XCTAssertThrowsError(try store.syncItems(module: .bookmarks, profileIDs: [profile]))
        XCTAssertEqual(store.search("example.com/saved", profileID: profile, bookmarksOnly: true).count, 1)
    }

    func testApplyingCloudRowsPreservesLocalOnlySensitiveURLs() throws {
        let profile = UUID(), source = LibraryStore(directory: try directory()), target = LibraryStore(directory: try directory())
        defer { source.close(); target.close() }
        source.bookmark(urlString: "https://example.com/shared", title: "Shared", profileID: profile)
        source.recordVisit(urlString: "https://example.com/shared", title: "Shared visit", profileID: profile)
        target.bookmark(urlString: "https://example.com/private?access_token=secret", title: "Local bookmark", profileID: profile)
        target.recordVisit(urlString: "https://example.com/private?access_token=secret", title: "Local visit", profileID: profile)
        try target.applySyncItems(source.syncItems(module: .bookmarks, profileIDs: [profile]), module: .bookmarks, profileIDs: [profile])
        try target.applySyncItems(source.syncItems(module: .history, profileIDs: [profile]), module: .history, profileIDs: [profile])
        XCTAssertEqual(target.search("Local bookmark", profileID: profile, bookmarksOnly: true).count, 1)
        XCTAssertEqual(target.search("Local visit", profileID: profile, historyOnly: true).count, 1)
        XCTAssertEqual(try target.syncItems(module: .bookmarks, profileIDs: [profile]).count, 1)
        XCTAssertEqual(try target.syncItems(module: .history, profileIDs: [profile]).count, 1)
    }

    func testDelayedProfileRecordsDoNotBlockKnownProfile() throws {
        let known = UUID(), delayed = UUID()
        let librarySource = LibraryStore(directory: try directory()), libraryTarget = LibraryStore(directory: try directory())
        defer { librarySource.close(); libraryTarget.close() }
        librarySource.bookmark(urlString: "https://example.com/known", title: "Known", profileID: known)
        librarySource.bookmark(urlString: "https://example.com/delayed", title: "Delayed", profileID: delayed)
        try libraryTarget.applySyncItems(librarySource.syncItems(module: .bookmarks, profileIDs: [known, delayed]),
                                         module: .bookmarks, profileIDs: [known])
        XCTAssertEqual(libraryTarget.search("Known", profileID: known, bookmarksOnly: true).count, 1)
        XCTAssertTrue(libraryTarget.search("Delayed", profileID: delayed, bookmarksOnly: true).isEmpty)

        let zoomSource = SiteSettingsStore(directory: try directory()), zoomTarget = SiteSettingsStore(directory: try directory())
        let origin = URL(string: "https://example.com")!
        zoomSource.setZoom(1.5, origin: origin, profileID: known)
        zoomSource.setZoom(2, origin: origin, profileID: delayed)
        try zoomTarget.applySyncItems(zoomSource.syncItems(profileIDs: [known, delayed]), profileIDs: [known])
        XCTAssertEqual(zoomTarget.setting(origin: origin, profileID: known).zoom, 1.5)
        XCTAssertNil(zoomTarget.setting(origin: origin, profileID: delayed).zoom)
    }

    func testBundledBlockerSettingsInstallOnFreshMac() async throws {
        let sourceDirectory = try directory(), targetDirectory = try directory()
        let sourceEngine = WebKitEngine(directory: sourceDirectory, dataStoreOverride: .nonPersistent())
        let targetEngine = WebKitEngine(directory: targetDirectory, dataStoreOverride: .nonPersistent())
        let source = AppModel(store: SessionStore(directory: sourceDirectory), engines: EngineRegistry([sourceEngine]))
        let target = AppModel(store: SessionStore(directory: targetDirectory), engines: EngineRegistry([targetEngine]))
        defer {
            source.windows.forEach { $0.closePages() }; source.flush(); source.library.close()
            target.windows.forEach { $0.closePages() }; target.flush(); target.library.close()
        }
        let profile = try XCTUnwrap(source.profiles.first?.id)
        XCTAssertEqual(target.profiles.first?.id, profile)
        await sourceEngine.blocker.installBundledRules(profileID: profile)
        await sourceEngine.blocker.setException(origin: URL(string: "https://example.com")!, enabled: true, profileID: profile)
        await sourceEngine.blocker.setEnabled(false, profileID: profile)
        let items = try source.contentBlockerSyncItems()
        XCTAssertEqual(items.first?.fields["rulesKind"], "bundled")
        let delayed = UUID()
        var delayedItem = try XCTUnwrap(items.first)
        delayedItem.id = "blocker:\(delayed.uuidString):webkit"
        delayedItem.fields["profileID"] = delayed.uuidString
        try await target.applyContentBlockerSyncItems(items + [delayedItem])
        XCTAssertTrue(targetEngine.blocker.usesBundledRules(profileID: profile))
        XCTAssertFalse(targetEngine.blocker.isEnabled(profileID: profile))
        XCTAssertEqual(targetEngine.blocker.exceptions(profileID: profile), ["https://example.com"])
    }

    func testFailedBlockerSourceDownloadPreservesPreviousRules() async throws {
        let blocker = WebKitContentBlocker(directory: try directory()), profile = UUID()
        await blocker.installBundledRules(profileID: profile)
        let previousSource = URL(string: "https://rules.example/old.json")!
        await blocker.setUpdateSource(previousSource, profileID: profile)
        let previousRules = blocker.rules(for: profile)
        XCTAssertEqual(blocker.updateSource(profileID: profile), previousSource)
        do {
            try await blocker.installRules(from: URL(string: "https://127.0.0.1:1/rules.json")!, profileID: profile)
            XCTFail("Expected local connection refusal")
        } catch {
            XCTAssertEqual(blocker.updateSource(profileID: profile), previousSource)
            XCTAssertTrue(blocker.rules(for: profile) === previousRules)
            XCTAssertTrue(blocker.isEnabled(profileID: profile))
        }
    }

    func testLocalCustomBlockerCannotBeDeletedOrReplacedBySync() async throws {
        let directory = try directory()
        let engine = WebKitEngine(directory: directory, dataStoreOverride: .nonPersistent())
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([engine]))
        defer { app.windows.forEach { $0.closePages() }; app.flush(); app.library.close() }
        let profile = try XCTUnwrap(app.profiles.first?.id)
        await engine.blocker.importRules(json: WebKitContentBlocker.bundledRules + "\n", profileID: profile)
        XCTAssertTrue(engine.blocker.hasRules(profileID: profile))
        XCTAssertThrowsError(try app.contentBlockerSyncItems())

        let remote = SyncItem(id: "blocker:\(profile.uuidString):webkit", module: .contentBlockers,
                              kind: "configuration", fields: [
                                "profileID": profile.uuidString, "engineID": "webkit", "enabled": "true",
                                "rulesKind": "bundled", "exceptions": ""
                              ])
        do {
            try await app.applyContentBlockerSyncItems([remote])
            XCTFail("Expected local custom rules to be preserved")
        } catch {
            XCTAssertFalse(engine.blocker.usesBundledRules(profileID: profile))
            XCTAssertTrue(engine.blocker.hasRules(profileID: profile))
        }
    }

    func testPrivateBlockerSourceDoesNotTurnIntoCloudDeletion() async throws {
        let directory = try directory()
        let engine = WebKitEngine(directory: directory, dataStoreOverride: .nonPersistent())
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([engine]))
        defer { app.windows.forEach { $0.closePages() }; app.flush(); app.library.close() }
        let profile = try XCTUnwrap(app.profiles.first?.id)
        await engine.blocker.installBundledRules(profileID: profile)
        let privateSource = URL(string: "https://rules.example/list.json?token=secret")!
        await engine.blocker.setUpdateSource(privateSource, profileID: profile)
        XCTAssertEqual(engine.blocker.updateSource(profileID: profile), privateSource)
        XCTAssertThrowsError(try app.contentBlockerSyncItems())
    }

    func testUnreadableBlockerStoreCannotPublishCloudDeletion() throws {
        let directory = try directory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("content-blockers.json"))
        let engine = WebKitEngine(directory: directory, dataStoreOverride: .nonPersistent())
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([engine]))
        defer { app.windows.forEach { $0.closePages() }; app.flush(); app.library.close() }
        XCTAssertFalse(engine.blocker.canPersistRules)
        XCTAssertThrowsError(try app.contentBlockerSyncItems())
    }
}
