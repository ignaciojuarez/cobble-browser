import XCTest
@testable import Cobble

@MainActor
final class SyncOrganizationReviewTests: XCTestCase {
    func testLocalSecretPinSurvivesOldCloudRecordWithSameID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSyncOrg-\(UUID())")
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        defer {
            app.windows.forEach { $0.closePages() }
            app.library.close()
            try? FileManager.default.removeItem(at: directory)
        }
        for url in ["https://user:pass@example.com/", "https://example.com/?access_token=fixture",
                    "https://example.com/#token=fixture", "https://999.999.999.999/"] {
            let id = UUID()
            let local = SavedItem(id: id, urlString: url, title: "Local secret")
            app.savedItems = [local]
            var remote = app.organizationSyncItems()
            XCTAssertFalse(remote.contains { $0.id == "saved.\(id)" })
            remote.append(SyncItem(id: "saved.\(id)", module: .organization, kind: "saved", fields: [
                "uuid": id.uuidString, "profileID": Profile.defaultID.uuidString,
                "spaceID": "", "folderID": "", "url": "https://old.example/", "title": "Old shared title", "rank": "0"
            ]))
            try await app.applySyncItems(remote, module: .organization)
            XCTAssertEqual(app.savedItems.first { $0.id == id }, local)
        }
    }

    func testOrganizationFiltersSecretPinsAndFavoritesAndRejectsUnsafeIncomingURLs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSyncOrg-\(UUID())")
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        defer {
            app.windows.forEach { $0.closePages() }
            app.library.close()
            try? FileManager.default.removeItem(at: directory)
        }
        for spaceID in [nil, Space.defaultID] as [UUID?] {
            let safe = SavedItem(spaceID: spaceID, urlString: "https://example.com/?q=public", title: "Safe")
            let secrets = ["https://example.com/?ACCESS_TOKEN=fixture", "https://example.com/#token=fixture",
                           "https://999.999.999.999/"]
                .map { SavedItem(spaceID: spaceID, urlString: $0, title: "Local") }
            app.savedItems = [safe] + secrets
            let projection = app.organizationSyncItems()
            XCTAssertEqual(projection.filter { $0.kind == "saved" }.map(\.id), ["saved.\(safe.id)"])
            try await app.applySyncItems(projection, module: .organization)
            XCTAssertEqual(Set(app.savedItems.map(\.id)), Set(([safe] + secrets).map(\.id)))
            for secret in secrets {
                var incoming = projection
                let index = try XCTUnwrap(incoming.firstIndex { $0.id == "saved.\(safe.id)" })
                incoming[index].fields["url"] = secret.urlString
                let before = app.savedItems
                do {
                    try await app.applySyncItems(incoming, module: .organization)
                    XCTFail("Unsafe remote URL must be rejected")
                } catch SyncFailure.invalidRecord {}
                XCTAssertEqual(app.savedItems, before)
            }
        }
    }

    func testMovedSpaceRepairsOldProfileReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSyncOrg-\(UUID())")
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        defer {
            app.windows.forEach { $0.closePages() }
            app.library.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let other = try XCTUnwrap(app.createProfile(name: "Other"))
        let moved = Space(profileID: Profile.defaultID, name: "Moved")
        app.spaces.append(moved)
        let folder = Folder(spaceID: moved.id, name: "Folder")
        app.folders.append(folder)
        let pin = SavedItem(spaceID: moved.id, folderID: folder.id,
                            urlString: "https://example.com/", title: "Pin")
        app.savedItems.append(pin)
        let window = app.windows[0]
        window.record.selectedSpaceID = moved.id
        window.record.tabs = [Tab(spaceID: moved.id, urlString: "https://example.com/")]
        let privateWindow = app.newWindow(isPrivate: true)
        privateWindow.record.selectedSpaceID = moved.id
        privateWindow.record.tabs = [Tab(spaceID: moved.id, urlString: "https://private.example/")]
        var remote = app.organizationSyncItems()
        let index = try XCTUnwrap(remote.firstIndex { $0.id == "space.\(moved.id)" })
        remote[index].fields["profileID"] = other.id.uuidString

        try await app.applySyncItems(remote, module: .organization)
        XCTAssertEqual(window.record.selectedSpaceID, Space.defaultID)
        XCTAssertEqual(window.record.tabs[0].spaceID, Space.defaultID)
        XCTAssertEqual(privateWindow.record.selectedSpaceID, Space.defaultID)
        XCTAssertEqual(privateWindow.record.tabs[0].spaceID, Space.defaultID)
        XCTAssertEqual(app.folders.first { $0.id == folder.id }?.spaceID, Space.defaultID)
        XCTAssertEqual(app.savedItems.first { $0.id == pin.id }?.spaceID, Space.defaultID)
        XCTAssertEqual(app.savedItems.first { $0.id == pin.id }?.folderID, folder.id)
        let data = try Data(contentsOf: app.store.url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private.example"))
    }

    func testSavedTabDetachesWhenPinChangesProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSyncOrg-\(UUID())")
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        defer {
            app.windows.forEach { $0.closePages() }
            app.library.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let other = try XCTUnwrap(app.createProfile(name: "Other"))
        let otherSpace = try XCTUnwrap(app.spaces.first { $0.profileID == other.id })
        let pin = SavedItem(spaceID: Space.defaultID, urlString: "https://example.com/", title: "Pin")
        app.savedItems = [pin]
        app.windows[0].record.tabs = [Tab(spaceID: Space.defaultID, urlString: pin.urlString, savedItemID: pin.id)]
        var remote = app.organizationSyncItems()
        let index = try XCTUnwrap(remote.firstIndex { $0.id == "saved.\(pin.id)" })
        remote[index].fields["profileID"] = other.id.uuidString
        remote[index].fields["spaceID"] = otherSpace.id.uuidString

        try await app.applySyncItems(remote, module: .organization)
        XCTAssertNil(app.windows[0].record.tabs[0].savedItemID)
        XCTAssertEqual(app.windows[0].record.tabs[0].spaceID, Space.defaultID)
        XCTAssertEqual(app.savedItems.first?.profileID, other.id)
    }
}
