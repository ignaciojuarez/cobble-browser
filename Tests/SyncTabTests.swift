import AppKit
import SwiftUI
import XCTest
@testable import Cobble

@MainActor
final class SyncTabTests: XCTestCase {
    func testExportExcludesPrivateNonwebCredentialsAndSavedTabs() async throws {
        try await withApp { app in
            let window = app.windows[0]
            let web = Tab(urlString: "https://example.com/a", title: "Web")
            let file = Tab(urlString: "file:///tmp/example", title: "File")
            let credentials = Tab(urlString: "https://user:pass@example.com/", title: "Secret")
            let saved = Tab(urlString: "https://saved.example/", title: "Pin", savedItemID: UUID())
            let malformed = Tab(urlString: "https://", title: "No host")
            let token = Tab(urlString: "https://example.com/callback?token=secret", title: "Token")
            let query = Tab(urlString: "https://example.com/list?page=2", title: "Page 2")
            window.record.tabs = [web, file, credentials, saved, malformed, token, query]
            let privateWindow = app.newWindow(isPrivate: true, url: URL(string: "https://private.example/")!)

            let exported = app.tabSyncItems()
            XCTAssertEqual(exported.map(\.id), [web, query].map { "tab.\($0.id.uuidString.lowercased())" })
            XCTAssertFalse(exported.contains { $0.fields["url"] == privateWindow.selectedTab?.urlString })
        }
    }

    func testApplyUsesLocalEngineAndIsIdempotentWithOrder() async throws {
        try await withApp { app in
            XCTAssertTrue(app.preferences.setDefaultEngine(EngineID(rawValue: "chromium")))
            let a = item(url: "https://a.example/", rank: 1)
            let b = item(url: "https://b.example/", rank: 0)
            try await app.applySyncedTabs([a, b])
            let window = app.windows[0]
            XCTAssertEqual(window.record.tabs.map(\.urlString), ["https://b.example/", "https://a.example/"])
            XCTAssertTrue(window.record.tabs.allSatisfy { $0.isUnloaded == true })
            XCTAssertTrue(window.record.tabs.allSatisfy { $0.engineID.rawValue == "chromium" })
            try await app.applySyncedTabs([a, b])
            XCTAssertEqual(window.record.tabs.count, 2)
            XCTAssertEqual(app.tabSyncItems().map(\.id).count, 2)
            let hosting = NSHostingView(rootView: SyncSettingsView(app: app))
            hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.width, 0)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/cobble-sync-settings.png"))
        }
    }

    func testRemoteCloseVetoPreservesTabAndConcurrentNewTab() async throws {
        try await withApp { app in
            let window = app.windows[0]
            window.addTab(url: URL(string: "https://old.example/")!)
            let oldID = try XCTUnwrap(window.selectedTab?.id)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let applying = Task { try await app.applySyncedTabs([]) }
            for _ in 0..<200 where page.closeRequest == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(page.closeRequest)
            window.addTab(url: URL(string: "https://new.example/")!)
            let newID = try XCTUnwrap(window.selectedTab?.id)
            page.finishCloseRequest(accepted: false)
            do { try await applying.value; XCTFail("A veto must keep sync pending") }
            catch { }
            XCTAssertTrue(window.record.tabs.contains { $0.id == oldID })
            XCTAssertTrue(window.record.tabs.contains { $0.id == newID })
        }
    }

    func testNavigationDuringRemoteClosePreflightIsNotReplaced() async throws {
        try await withApp { app in
            let window = app.windows[0]
            window.addTab(url: URL(string: "https://old.example/")!)
            let id = try XCTUnwrap(window.selectedTab?.id)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let replacement = item(id: id, url: "https://remote.example/", rank: 0)
            let applying = Task { try await app.applySyncedTabs([replacement]) }
            for _ in 0..<200 where page.closeRequest == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(page.closeRequest)
            window.record.tabs[0].urlString = "https://local-new.example/"
            page.finishCloseRequest(accepted: true)
            do { try await applying.value; XCTFail("A changed local page must not be replaced") }
            catch { }
            XCTAssertEqual(window.record.tabs.first?.urlString, "https://local-new.example/")
        }
    }

    func testEditedTabIsNotOverwrittenWhileAnotherPageConfirmsClose() async throws {
        try await withApp { app in
            let window = app.windows[0]
            window.addTab(url: URL(string: "https://closing.example/")!)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let retained = Tab(urlString: "https://retained.example/", title: "Original")
            window.record.tabs.append(retained)
            let remote = item(id: retained.id, url: retained.urlString, rank: 0)
            let applying = Task { try await app.applySyncedTabs([remote]) }
            for _ in 0..<200 where page.closeRequest == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(page.closeRequest)
            window.renameTab(retained.id, title: "Edited locally")
            page.finishCloseRequest(accepted: true)
            do { try await applying.value; XCTFail("A concurrent edit must stay local") }
            catch { }
            XCTAssertEqual(window.record.tabs.first { $0.id == retained.id }?.titleOverride, "Edited locally")
        }
    }

    func testLocallyClosedTabIsNotRestoredWhileAnotherPageConfirmsClose() async throws {
        try await withApp { app in
            let window = app.windows[0]
            window.addTab(url: URL(string: "https://closing.example/")!)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let retained = Tab(urlString: "https://retained.example/")
            window.record.tabs.append(retained)
            let applying = Task { try await app.applySyncedTabs([item(id: retained.id, url: retained.urlString, rank: 0)]) }
            for _ in 0..<200 where page.closeRequest == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(page.closeRequest)
            window.closeTab(retained.id)
            page.finishCloseRequest(accepted: true)
            do { try await applying.value; XCTFail("Local deletion must be retried") }
            catch { }
            XCTAssertFalse(window.record.tabs.contains { $0.id == retained.id })
        }
    }

    func testCancelledRemoteCloseKeepsTabAndReleasesCloseRequest() async throws {
        try await withApp { app in
            let window = app.windows[0]
            window.addTab(url: URL(string: "https://old.example/")!)
            let id = try XCTUnwrap(window.selectedTab?.id)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let applying = Task { try await app.applySyncedTabs([]) }
            for _ in 0..<200 where page.closeRequest == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(page.closeRequest)
            applying.cancel()
            page.finishCloseRequest(accepted: true)
            do { try await applying.value; XCTFail("Cancelled sync must stop") }
            catch { }
            XCTAssertTrue(window.record.tabs.contains { $0.id == id })
            XCTAssertTrue(window.scriptingMutationAllowed)
        }
    }

    func testRemoteURLReplacementWaitsForCloseAndKeepsIdentity() async throws {
        try await withApp { app in
            let window = app.windows[0]
            window.addTab(url: URL(string: "https://old.example/")!)
            let id = try XCTUnwrap(window.selectedTab?.id)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.closeRequestResult = true
            window.record.tabs[0].engineOverride = EngineID(rawValue: "chromium")
            var remote = item(id: id, url: "https://remote.example/", rank: 0)
            remote.fields["titleOverride"] = "My project"
            try await app.applySyncedTabs([remote])
            XCTAssertEqual(page.closeRequestCount, 1)
            XCTAssertEqual(window.record.tabs.map(\.id), [id])
            XCTAssertEqual(window.record.tabs[0].urlString, "https://remote.example/")
            XCTAssertEqual(window.record.tabs[0].isUnloaded, true)
            XCTAssertEqual(window.record.selectedTabID, id)
            XCTAssertTrue(window.closedTabs.isEmpty)
            XCTAssertEqual(window.record.tabs[0].engineOverride?.rawValue, "chromium")
            XCTAssertEqual(window.record.tabs[0].titleOverride, "My project")
        }
    }

    func testInboundURLWithCredentialsIsRejectedBeforeMutation() async throws {
        try await withApp { app in
            let remote = item(url: "https://user:pass@example.com/", rank: 0)
            do { try await app.applySyncedTabs([remote]); XCTFail("Credentials must remain local") }
            catch { }
            XCTAssertTrue(app.windows[0].record.tabs.isEmpty)
        }
    }

    func testMalformedInboundURLRejectsBatchBeforeClosingLocalTab() async throws {
        try await withApp { app in
            let window = app.windows[0]
            let local = Tab(urlString: "https://local.example/", title: "Local")
            window.record.tabs = [local]
            do { try await app.applySyncedTabs([item(url: "https://", rank: 0)]); XCTFail("Hostless URL must fail") }
            catch { }
            XCTAssertEqual(window.record.tabs, [local])
        }
    }

    func testSensitiveInboundURLDoesNotCloseMatchingLocalTab() async throws {
        try await withApp { app in
            let window = app.windows[0]
            let local = Tab(urlString: "https://local.example/", title: "Local")
            let token = Tab(urlString: "https://local.example/callback?token=secret", title: "Token")
            window.record.tabs = [local, token]
            try await app.applySyncedTabs([item(id: local.id,
                url: "https://remote.example/callback?token=secret", rank: 0)])
            XCTAssertEqual(window.record.tabs, [local, token])
            XCTAssertTrue(app.tabSyncItems().map(\.id).contains("tab.\(local.id.uuidString.lowercased())"))
            XCTAssertFalse(app.tabSyncItems().map(\.id).contains("tab.\(token.id.uuidString.lowercased())"))
        }
    }

    func testLocalOnlyTabsIgnoreSameIDSafeRemoteMetadataAndProfile() async throws {
        try await withApp { app in
            let normal = app.windows[0]
            let token = Tab(urlString: "https://local.example/callback?token=secret", title: "Local token")
            let file = Tab(urlString: "file:///tmp/local-only", title: "Local file")
            let pin = SavedItem(spaceID: Space.defaultID, urlString: "https://saved.example/", title: "Local pin")
            app.savedItems.append(pin)
            let saved = Tab(urlString: pin.urlString, title: pin.title, savedItemID: pin.id)
            normal.record.tabs = [token, file, saved]
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let work = try XCTUnwrap(app.newWindow(profileID: profile.id))
            let workSpace = try XCTUnwrap(app.spaces.first { $0.profileID == profile.id })
            let workToken = Tab(spaceID: workSpace.id,
                urlString: "https://work.example/callback?access_token=secret", title: "Work token")
            work.record.tabs = [workToken]
            work.record.selectedTabID = workToken.id
            let privateWindow = app.newWindow(isPrivate: true)
            let privateTab = Tab(urlString: "https://private.example/", title: "Private")
            privateWindow.record.tabs = [privateTab]

            let remotes = [token, file, saved, workToken, privateTab].enumerated().map { rank, tab in
                item(id: tab.id, url: "https://remote.example/\(rank)", rank: rank)
            }
            try await app.applySyncedTabs(remotes)

            XCTAssertEqual(normal.record.tabs, [token, file, saved])
            XCTAssertEqual(work.record.tabs, [workToken])
            XCTAssertEqual(work.record.selectedSpaceID, workSpace.id)
            XCTAssertEqual(privateWindow.record.tabs, [privateTab])
            XCTAssertFalse(app.windows.filter { !$0.isPrivate }.flatMap { $0.record.tabs }
                .contains { $0.id == privateTab.id })
        }
    }

    func testNewTabInAnotherWindowSurvivesAwaitedRemoteClose() async throws {
        try await withApp { app in
            let first = app.windows[0]
            let second = app.newWindow()
            first.addTab(url: URL(string: "https://old.example/")!)
            let page = try XCTUnwrap(first.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let applying = Task { try await app.applySyncedTabs([]) }
            for _ in 0..<200 where page.closeRequest == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(page.closeRequest)
            second.addTab(url: URL(string: "https://new.example/")!)
            let newID = try XCTUnwrap(second.selectedTab?.id)
            page.finishCloseRequest(accepted: true)
            try await applying.value
            XCTAssertTrue(second.record.tabs.contains { $0.id == newID })
        }
    }

    func testDeletedSpaceFallsBackAndDeletedProfileTabIsIgnored() async throws {
        try await withApp { app in
            var orphanSpace = item(url: "https://space.example/", rank: 0)
            orphanSpace.fields["spaceID"] = UUID().uuidString.lowercased()
            var orphanProfile = item(url: "https://profile.example/", rank: 1)
            orphanProfile.fields["profileID"] = UUID().uuidString.lowercased()
            try await app.applySyncedTabs([orphanSpace, orphanProfile])
            XCTAssertEqual(app.windows[0].record.tabs.count, 1)
            XCTAssertEqual(app.windows[0].record.tabs[0].spaceID, Space.defaultID)
            XCTAssertEqual(app.windows[0].record.tabs[0].urlString, "https://space.example/")
        }
    }

    private func item(id: UUID = UUID(), url: String, rank: Int) -> SyncItem {
        SyncItem(id: "tab.\(id.uuidString.lowercased())", module: .openTabs, kind: "tab", fields: [
            "uuid": id.uuidString.lowercased(),
            "profileID": Profile.defaultID.uuidString.lowercased(),
            "spaceID": Space.defaultID.uuidString.lowercased(),
            "url": url,
            "title": url,
            "rank": String(rank)
        ])
    }

    private func withApp(_ body: (AppModel) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSyncTabs-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        do { try await body(app) }
        catch {
            app.windows.forEach { $0.closePages() }
            await app.engines.shutdown()
            app.library.close()
            throw error
        }
        app.windows.forEach { $0.closePages() }
        await app.engines.shutdown()
        app.library.close()
    }
}
