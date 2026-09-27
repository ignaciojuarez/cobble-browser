import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Cobble

final class ModelPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPersistenceFilesPreserveExactBytesAndLeaveOriginalOnEncodingFailure() throws {
        let root = try directory()
        let url = root.appendingPathComponent("nested/settings.json")
        let original = Data("original bytes".utf8)
        try PersistenceFile.write(original, to: url)
        let first = try PersistenceFile.preserve(original, in: root, prefix: "settings.corrupt")
        let second = try PersistenceFile.preserve(original, in: root, prefix: "settings.corrupt")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertThrowsError(try PersistenceFile.save([Double.nan], to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func save(_ snapshot: SessionSnapshot, to store: SessionStore) {
        let done = expectation(description: "session saved")
        store.save(snapshot) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    private func imageData(width: Int = 32, height: Int = 32, type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testNormalizedPNGFitsPersistedFaviconBounds() throws {
        let oversized = try imageData(width: 64, height: 64)
        XCTAssertNil(CachedFavicon(origin: "https://example.com", png: oversized)
            .validated(for: "https://example.com/"))
        let png = try XCTUnwrap(CachedFavicon.normalizedPNG(from: oversized))
        let icon = try XCTUnwrap(CachedFavicon(origin: "https://example.com", png: png)
            .validated(for: "https://example.com/"))
        XCTAssertEqual(icon.png, png)
        XCTAssertLessThanOrEqual(png.count, 16_384)
        XCTAssertNil(CachedFavicon.normalizedPNG(from: Data([1, 2, 3])))
        XCTAssertNil(CachedFavicon.normalizedPNG(from: Data()))
    }

    func testValidFaviconBoundsSurviveSessionRoundTrip() throws {
        for size in [1, 32] {
            let icon = CachedFavicon(origin: "https://example.com", png: try imageData(width: size, height: size))
            let item = SavedItem(urlString: "https://example.com/saved", favicon: icon)
            let tab = Tab(urlString: "https://example.com/current", favicon: icon)
            let store = SessionStore(directory: try directory())
            save(SessionSnapshot(savedItems: [item], windows: [WindowRecord(tabs: [tab])]), to: store)
            let loaded = try XCTUnwrap(store.load().snapshot)
            XCTAssertEqual(loaded.savedItems, [item])
            XCTAssertEqual(loaded.windows[0].tabs, [tab])
        }
    }

    func testLoadAndImportDropInvalidFaviconsWithoutDroppingRecords() throws {
        let png = try imageData()
        let invalid: [(String, CachedFavicon)] = [
            ("malformed", CachedFavicon(origin: "https://example.com", png: Data([1, 2, 3]))),
            ("truncated", CachedFavicon(origin: "https://example.com", png: Data(png.prefix(40)))),
            ("oversized", CachedFavicon(origin: "https://example.com", png: png + Data(count: 16_385))),
            ("too wide", CachedFavicon(origin: "https://example.com", png: try imageData(width: 33))),
            ("too tall", CachedFavicon(origin: "https://example.com", png: try imageData(height: 33))),
            ("wrong format", CachedFavicon(origin: "https://example.com", png: try imageData(type: .tiff))),
            ("sibling origin", CachedFavicon(origin: "https://sub.example.com", png: png)),
            ("other scheme", CachedFavicon(origin: "http://example.com", png: png)),
            ("other port", CachedFavicon(origin: "https://example.com:8443", png: png)),
            ("noncanonical", CachedFavicon(origin: "HTTPS://EXAMPLE.COM:443", png: png)),
            ("path in origin", CachedFavicon(origin: "https://example.com/path", png: png))
        ]
        for (reason, icon) in invalid {
            let item = SavedItem(urlString: "https://example.com/saved", favicon: icon)
            let tab = Tab(urlString: "https://example.com/current", favicon: icon)
            let snapshot = SessionSnapshot(savedItems: [item], windows: [WindowRecord(tabs: [tab])])
            let store = SessionStore(directory: try directory())
            // Write unvalidated external bytes to exercise the load boundary itself.
            try JSONEncoder().encode(snapshot).write(to: store.url)
            let loaded = try XCTUnwrap(store.load().snapshot)
            XCTAssertEqual(loaded.savedItems.map(\.id), [item.id], reason)
            XCTAssertEqual(loaded.windows[0].tabs.map(\.id), [tab.id], reason)
            XCTAssertNil(loaded.savedItems[0].favicon, reason)
            XCTAssertNil(loaded.windows[0].tabs[0].favicon, reason)
            try store.replace(with: snapshot, preserving: loaded)
            let imported = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: store.url))
            XCTAssertEqual(imported.savedItems, loaded.savedItems, reason)
            XCTAssertEqual(imported.windows, loaded.windows, reason)
        }
    }

    func testLegacyRecordsWithoutFaviconStillDecodeAndValidate() throws {
        let item = SavedItem(urlString: "https://example.com/saved")
        let tab = Tab(urlString: "https://example.com/current")
        let snapshot = SessionSnapshot(savedItems: [item], windows: [WindowRecord(tabs: [tab])])
        let bytes = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("favicon"))
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: bytes).validated()
        XCTAssertEqual(decoded.savedItems, [item])
        XCTAssertEqual(decoded.windows[0].tabs, [tab])
    }

    func testLocalFileBookmarkRoundTripsAndOversizedBookmarksAreDropped() throws {
        let bookmark = Data(repeating: 7, count: 64)
        let tab = Tab(urlString: "file:///tmp/cobble-fixture.html", title: "Fixture", localFileBookmark: bookmark)
        let snapshot = SessionSnapshot(windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])]).validated()
        XCTAssertEqual(snapshot.windows[0].tabs[0].localFileBookmark, bookmark)
        var oversized = tab
        oversized.localFileBookmark = Data(repeating: 1, count: 131_073)
        XCTAssertNil(SessionSnapshot(windows: [WindowRecord(selectedTabID: oversized.id, tabs: [oversized])]).validated().windows[0].tabs[0].localFileBookmark)
        var empty = tab
        empty.localFileBookmark = Data()
        XCTAssertNil(SessionSnapshot(windows: [WindowRecord(selectedTabID: empty.id, tabs: [empty])]).validated().windows[0].tabs[0].localFileBookmark)
    }

    func testWorkspaceExportStripsBookmarksAndValidationDropsUnauthorizedRecords() {
        let file = Tab(urlString: "file:///tmp/cobble-fixture.html", localFileBookmark: Data(repeating: 3, count: 8))
        let web = Tab(urlString: "https://example.com", localFileBookmark: Data(repeating: 4, count: 8))
        let savedFile = SavedItem(urlString: "file:///tmp/pin.html")
        let snapshot = SessionSnapshot(savedItems: [savedFile], windows: [WindowRecord(selectedTabID: file.id, tabs: [file, web])])
        let exported = snapshot.withoutLocalFileBookmarks()
        XCTAssertEqual(exported.windows[0].tabs[0].urlString, file.urlString)
        XCTAssertNil(exported.windows[0].tabs[0].localFileBookmark)
        let validated = snapshot.validated()
        XCTAssertNotNil(validated.windows[0].tabs[0].localFileBookmark)
        XCTAssertNil(validated.windows[0].tabs[1].localFileBookmark)
        XCTAssertTrue(validated.savedItems.isEmpty)
    }

    func testSpaceIconRoundTripAndInvalidValuesDropWithoutDroppingTheSpace() throws {
        XCTAssertEqual(Space.validatedIcon("🥨"), "🥨")
        XCTAssertEqual(Space.validatedIcon("🇺🇸"), "🇺🇸")
        XCTAssertNil(Space.validatedIcon("ab"))
        XCTAssertNil(Space.validatedIcon(" pretzel "))
        XCTAssertNil(Space.validatedIcon(" "))
        let space = Space(id: Space.defaultID, icon: "🥨")
        let store = SessionStore(directory: try directory())
        save(SessionSnapshot(spaces: [space]), to: store)
        XCTAssertEqual(try XCTUnwrap(store.load().snapshot).spaces.first { $0.id == Space.defaultID }?.icon, "🥨")
        let omitted = try JSONEncoder().encode(SessionSnapshot(spaces: [Space(id: Space.defaultID)]))
        XCTAssertFalse(String(decoding: omitted, as: UTF8.self).contains("icon"))
        try JSONEncoder().encode(SessionSnapshot(spaces: [Space(id: Space.defaultID, icon: "nope")])).write(to: store.url)
        let loaded = try XCTUnwrap(store.load().snapshot)
        XCTAssertEqual(loaded.spaces.first { $0.id == Space.defaultID }?.id, Space.defaultID)
        XCTAssertNil(loaded.spaces.first { $0.id == Space.defaultID }?.icon)
    }

    func testFolderColorRoundTripAndLegacyEmojiUsesThemeDefault() throws {
        let space = Space(id: Space.defaultID)
        let folder = Folder(spaceID: space.id, name: "Notes", color: .purple)
        let store = SessionStore(directory: try directory())
        save(SessionSnapshot(spaces: [space], folders: [folder]), to: store)
        XCTAssertEqual(try XCTUnwrap(store.load().snapshot).folders.first { $0.id == folder.id }?.color, .purple)
        let legacy = #"{"version":8,"profiles":[{"id":"00000000-0000-0000-0000-000000000001","name":"Default","storeBinding":{"legacyDefault":{}}}],"spaces":[{"id":"00000000-0000-0000-0000-000000000002","profileID":"00000000-0000-0000-0000-000000000001","name":"Home"}],"folders":[{"id":"\#(folder.id.uuidString)","spaceID":"00000000-0000-0000-0000-000000000002","name":"Notes","icon":"📝"}],"savedItems":[],"windows":[]}"#
        try Data(legacy.utf8).write(to: store.url)
        let loaded = try XCTUnwrap(store.load().snapshot)
        XCTAssertEqual(loaded.folders.first { $0.id == folder.id }?.name, "Notes")
        XCTAssertEqual(loaded.folders.first { $0.id == folder.id }?.color, .theme)
    }

    func testAddressResolution() {
        let examples = [
            "example.com/path": "https://example.com/path",
            "localhost:8080/test": "http://localhost:8080/test",
            "127.0.0.1:3000": "http://127.0.0.1:3000",
            "[::1]:8080": "http://[::1]:8080",
            "https://example.com?q=a%20b": "https://example.com?q=a%20b",
            "example.com:8443": "https://example.com:8443"
        ]
        for (input, expected) in examples {
            XCTAssertEqual(AddressResolver.resolve(input), .navigate(URL(string: expected)!), input)
        }
        XCTAssertEqual(AddressResolver.resolve(" \n "), .blank)
        XCTAssertEqual(AddressResolver.resolve("about:blank"), .blank)
        XCTAssertEqual(AddressResolver.resolve("mailto:a@example.com"), .external(URL(string: "mailto:a@example.com")!))
        guard case let .navigate(search) = AddressResolver.resolve("swift & webkit") else { return XCTFail("Expected search") }
        XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "swift & webkit")
    }

    func testCanonicalOriginStripsASingleTrailingDotFromTheHost() {
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "https://example.com.")!), "https://example.com")
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "https://Example.COM./path")!), "https://example.com")
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "http://example.com.:80")!), "http://example.com")
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "https://example.com.")!),
                       AddressResolver.canonicalOrigin(URL(string: "https://example.com")!))
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "https://example.com..")!), "https://example.com.")
    }

    func testAddressTrustBoundaries() {
        for input in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "unknown:payload", "https://", "https://user:pass@example.com", "https://example.com:70000", "http://999.1.1.1", "https://exa\nmple.com"] {
            guard case .invalid = AddressResolver.resolve(input) else { XCTFail("Accepted \(input)"); continue }
        }
        XCTAssertNil(Tab(urlString: "private search terms").url)
        XCTAssertNil(SavedItem(urlString: "private search terms").url)
    }

    func testSidebarWidthRoundTripAndMissingLegacyWidth() throws {
        var record = WindowRecord()
        record.sidebarWidth = 360
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(WindowRecord.self, from: data).sidebarWidth, 360)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sidebarWidth")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(WindowRecord.self, from: legacy).sidebarWidth)
    }

    func testLegacyPlaceholderTabsAreRemovedAndEmptySelectionSurvivesRestore() {
        let placeholder = Tab()
        let page = Tab(urlString: "https://example.com", title: "Page")
        let snapshot = SessionSnapshot(windows: [WindowRecord(selectedTabID: placeholder.id, tabs: [placeholder])]).validated()
        XCTAssertTrue(snapshot.windows[0].tabs.isEmpty)
        XCTAssertNil(snapshot.windows[0].selectedTabID)
        let deselected = SessionSnapshot(windows: [WindowRecord(tabs: [page])]).validated()
        XCTAssertNil(deselected.windows[0].selectedTabID)
        XCTAssertEqual(deselected.windows[0].tabs.map(\.id), [page.id])
    }

    func testBlankTabRepairUsesStableStoredTitleAcrossLocales() {
        let blank = Tab(title: "New Tab")
        let repaired = SessionSnapshot(windows: [WindowRecord(selectedTabID: blank.id, tabs: [blank])]).validated()
        XCTAssertTrue(repaired.windows[0].tabs.isEmpty)
        XCTAssertEqual(blank.displayedTitle, String(localized: "New Tab"))
        XCTAssertEqual(Tab(title: "Opening…").displayedTitle, String(localized: "Opening…"))

        let userNamed = Tab(title: "Pestaña nueva")
        let preserved = SessionSnapshot(windows: [WindowRecord(selectedTabID: userNamed.id, tabs: [userNamed])]).validated()
        XCTAssertEqual(preserved.windows[0].tabs.map(\.title), ["Pestaña nueva"])

        let renamedBlank = Tab(titleOverride: "Research")
        let preservedRename = SessionSnapshot(windows: [WindowRecord(selectedTabID: renamedBlank.id, tabs: [renamedBlank])]).validated()
        XCTAssertEqual(preservedRename.windows[0].tabs.first?.displayedTitle, "Research")
    }

    func testCanonicalDefaultsLocalizeOnlyUntilRenamed() {
        var profile = Profile(id: Profile.defaultID)
        XCTAssertEqual(profile.displayedName, String(localized: "Default"))
        profile.name = "Personal"
        XCTAssertEqual(profile.displayedName, "Personal")

        var space = Space(id: Space.defaultID)
        XCTAssertEqual(space.displayedName, String(localized: "Home"))
        space.name = "Inicio personal"
        XCTAssertEqual(space.displayedName, "Inicio personal")
    }

    func testVersionFourSpacesKeepAmbiguousSecondaryHomeVerbatim() throws {
        let profile = Profile(name: "Work", storeBinding: .named(UUID()))
        let legacy = SessionSnapshot(
            version: 4,
            profiles: [Profile(id: Profile.defaultID), profile],
            spaces: [Space(id: Space.defaultID), Space(profileID: profile.id, name: "Home")]
        )

        let decoded = try SessionSnapshot.decode(JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.version, SessionSnapshot.currentVersion)
        XCTAssertNil(decoded.spaces.first { $0.profileID == profile.id }?.isGeneratedDefault)
        XCTAssertEqual(decoded.spaces.first { $0.profileID == profile.id }?.displayedName, "Home")
    }

    func testVersionFiveRoundTripRetainsGeneratedSpaceMarkerAndRefusesFutureVersion() throws {
        let profile = Profile(name: "Work", storeBinding: .named(UUID()))
        let generated = Space(profileID: profile.id, isGeneratedDefault: true)
        let renamed = Space(profileID: profile.id, name: "Home", isGeneratedDefault: false)
        let snapshot = SessionSnapshot(profiles: [Profile(id: Profile.defaultID), profile],
                                       spaces: [Space(id: Space.defaultID, isGeneratedDefault: true), generated, renamed])
        let store = SessionStore(directory: try directory())
        save(snapshot, to: store)
        let bytes = try Data(contentsOf: store.url)
        let decoded = try SessionSnapshot.decode(bytes)
        XCTAssertEqual(decoded.version, SessionSnapshot.currentVersion)
        XCTAssertEqual(decoded.spaces.first { $0.id == generated.id }?.isGeneratedDefault, true)
        XCTAssertEqual(decoded.spaces.first { $0.id == renamed.id }?.isGeneratedDefault, false)

        var future = snapshot
        future.version = SessionSnapshot.currentVersion + 1
        XCTAssertThrowsError(try SessionSnapshot.decode(JSONEncoder().encode(future)))
    }

    func testVersionSevenRootPinsBecomeGlobalPins() throws {
        let folder = Folder(name: "Folder")
        let root = SavedItem(spaceID: Space.defaultID, title: "Root")
        let child = SavedItem(spaceID: Space.defaultID, folderID: folder.id, title: "Child")
        let legacy = SessionSnapshot(version: 7, folders: [folder], savedItems: [root, child])
        let decoded = try SessionSnapshot.decode(JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.savedItems.first { $0.id == root.id }?.spaceID)
        XCTAssertEqual(decoded.savedItems.first { $0.id == child.id }?.spaceID, Space.defaultID)
    }

    func testDefaultSnapshotIsConsistent() {
        let snapshot = SessionSnapshot()
        XCTAssertEqual(snapshot.profiles.first?.id, Profile.defaultID)
        XCTAssertEqual(snapshot.spaces.first?.id, Space.defaultID)
        XCTAssertEqual(snapshot.windows.first?.selectedTabID, snapshot.windows.first?.tabs.first?.id)
        XCTAssertTrue(snapshot.windows.first?.tabs.isEmpty == true)
    }

    func testValidationPreservesRecordsAndRepairsReferences() {
        let tab = Tab(spaceID: UUID(), urlString: "https://example.com", savedItemID: UUID())
        let folder = Folder(spaceID: UUID())
        let item = SavedItem(profileID: UUID(), spaceID: UUID(), folderID: UUID(), urlString: "https://saved.example")
        let window = WindowRecord(profileID: UUID(), selectedSpaceID: UUID(), selectedTabID: UUID(), tabs: [tab, tab], collapsedFolderIDs: [folder.id, folder.id, UUID()], frame: WindowFrame(x: 0, y: 0, width: -1, height: 50))
        let repaired = SessionSnapshot(folders: [folder, folder], savedItems: [item, item], windows: [window, window]).validated()
        XCTAssertEqual(repaired.windows.count, 2)
        XCTAssertEqual(repaired.windows.flatMap(\.tabs).count, 4)
        XCTAssertEqual(Set(repaired.windows.flatMap(\.tabs).map(\.id)).count, 4)
        XCTAssertEqual(Set(repaired.folders.map(\.id)).count, 2)
        XCTAssertEqual(Set(repaired.savedItems.map(\.id)).count, 2)
        XCTAssertNil(repaired.windows[0].frame)
        XCTAssertEqual(repaired.windows[0].selectedTabID, repaired.windows[0].tabs[0].id)
        XCTAssertEqual(repaired.windows[0].collapsedFolderIDs, [folder.id])
        XCTAssertNil(repaired.windows[0].tabs[0].savedItemID)
        XCTAssertNil(repaired.savedItems[0].spaceID)
        XCTAssertNil(repaired.savedItems[0].folderID)
    }

    func testValidationRepairsProfileIsolation() {
        let second = Profile(name: "Work", storeBinding: .named(UUID()))
        let work = Space(profileID: second.id, name: "Work")
        let item = SavedItem(profileID: second.id, spaceID: work.id)
        let tab = Tab(spaceID: work.id, title: "Profile fixture", savedItemID: item.id)
        let snapshot = SessionSnapshot(profiles: [Profile(id: Profile.defaultID), second], spaces: [Space(id: Space.defaultID), work], savedItems: [item], windows: [WindowRecord(tabs: [tab])]).validated()
        XCTAssertEqual(snapshot.windows[0].tabs[0].spaceID, Space.defaultID)
        XCTAssertNil(snapshot.windows[0].tabs[0].savedItemID)
    }

    func testValidationRepairsEmptyTabEnginesWithoutDiscardingUnknownOnes() {
        let empty = Tab(title: "Empty engine", engineID: EngineID(rawValue: ""), engineOverride: EngineID(rawValue: ""))
        let unknown = Tab(title: "Future engine", engineID: EngineID(rawValue: "future.engine"), engineOverride: EngineID(rawValue: "future.override"))
        let repaired = SessionSnapshot(windows: [WindowRecord(tabs: [empty, unknown])]).validated().windows[0].tabs
        XCTAssertEqual(repaired[0].engineID, .webKit)
        XCTAssertNil(repaired[0].engineOverride)
        XCTAssertEqual(repaired[1].engineID.rawValue, "future.engine")
        XCTAssertEqual(repaired[1].engineOverride?.rawValue, "future.override")
    }

    func testNestedFolderMigrationPreservesValidParentsAndRepairsCycles() throws {
        let root = Folder(name: "Root")
        let child = Folder(parentID: root.id, name: "Child")
        let work = Space(name: "Work")
        let foreign = Folder(spaceID: work.id, parentID: root.id, name: "Foreign")
        let first = Folder(name: "First")
        let second = Folder(parentID: first.id, name: "Second")
        var cycle = first
        cycle.parentID = second.id
        let snapshot = SessionSnapshot(version: 3, spaces: [Space(id: Space.defaultID), work], folders: [root, child, foreign, cycle, second])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var folders = try XCTUnwrap(json["folders"] as? [[String: Any]])
        folders[0].removeValue(forKey: "parentID") // Actual schema-3 folder record.
        json["folders"] = folders
        let decoded = try SessionSnapshot.decode(JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(decoded.version, SessionSnapshot.currentVersion)
        XCTAssertEqual(decoded.folders.first { $0.id == child.id }?.parentID, root.id)
        XCTAssertNil(decoded.folders.first { $0.id == foreign.id }?.parentID)
        XCTAssertNil(decoded.folders.first { $0.id == cycle.id }?.parentID)
        XCTAssertEqual(decoded.folders.first { $0.id == second.id }?.parentID, cycle.id)
    }

    func testValidationRestoresMissingDefaultProfileAndItsLegacyStore() {
        let imported = Profile(name: "Imported", storeBinding: .legacyDefault)
        let snapshot = SessionSnapshot(profiles: [imported], spaces: [Space(profileID: imported.id)]).validated()

        XCTAssertEqual(snapshot.profiles.map(\.id), [Profile.defaultID, imported.id])
        XCTAssertEqual(snapshot.profiles[0].storeBinding, .legacyDefault)
        XCTAssertNotEqual(snapshot.profiles[1].storeBinding, .legacyDefault)
    }

    func testValidationRepairsReboundAndDuplicateLegacyDefaultStores() {
        let imported = Profile(name: "Imported", storeBinding: .legacyDefault)
        let defaultProfile = Profile(id: Profile.defaultID, storeBinding: .named(UUID()))
        let snapshot = SessionSnapshot(profiles: [imported, defaultProfile],
                                       spaces: [Space(profileID: imported.id), Space(id: Space.defaultID)]).validated()

        XCTAssertEqual(snapshot.profiles.map(\.id), [Profile.defaultID, imported.id])
        XCTAssertEqual(snapshot.profiles[0].storeBinding, .legacyDefault)
        XCTAssertNotEqual(snapshot.profiles[1].storeBinding, .legacyDefault)
        XCTAssertEqual(Set(snapshot.profiles.map(\.storeBinding)).count, snapshot.profiles.count)
    }

    func testLegacyMigrationAndOriginalBackup() throws {
        let store = SessionStore(directory: try directory())
        let tabID = UUID()
        let original = Data("{\"tabs\":[{\"id\":\"\(tabID)\",\"urlString\":\"https://example.com\",\"title\":\"Example\"}],\"selectedTabID\":\"\(tabID)\"}".utf8)
        try original.write(to: store.url)
        let loaded = store.load()
        let snapshot = try XCTUnwrap(loaded.snapshot)
        XCTAssertTrue(loaded.canSave)
        XCTAssertNotNil(loaded.message)
        XCTAssertEqual(snapshot.windows[0].tabs[0].id, tabID)
        XCTAssertEqual(snapshot.windows[0].selectedTabID, tabID)
        XCTAssertEqual(snapshot.profiles[0].storeBinding, .legacyDefault)
        save(snapshot, to: store)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), original)
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: store.url)).version, SessionSnapshot.currentVersion)
    }

    func testSerialSavesAndLastValidBackup() throws {
        let store = SessionStore(directory: try directory())
        XCTAssertNil(store.load().snapshot)
        var first = SessionSnapshot(windows: [WindowRecord(tabs: [Tab(title: "Fixture")])])
        first.windows[0].tabs[0].title = "First"
        var second = first
        second.windows[0].tabs[0].title = "Second"
        store.save(first) { XCTAssertNil($0) }
        store.save(second) { XCTAssertNil($0) }
        store.flush()
        let loaded = try XCTUnwrap(store.load().snapshot)
        XCTAssertEqual(loaded.windows[0].tabs[0].title, "Second")
        let backup = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.windows[0].tabs[0].title, "First")
    }

    func testCorruptPrimaryRecoversBackupAndPreservesEvidence() throws {
        let dir = try directory()
        let store = SessionStore(directory: dir)
        let corrupt = Data("{broken".utf8)
        let snapshot = SessionSnapshot()
        try corrupt.write(to: store.url)
        try JSONEncoder().encode(snapshot).write(to: store.backupURL)
        let loaded = store.load()
        XCTAssertTrue(loaded.canSave)
        XCTAssertEqual(loaded.snapshot?.windows[0].id, snapshot.windows[0].id)
        let preserved = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), corrupt)
        save(try XCTUnwrap(loaded.snapshot), to: store)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), corrupt)
    }

    func testFutureVersionInEitherFilePreventsWrites() throws {
        for futureIsBackup in [false, true] {
            let store = SessionStore(directory: try directory())
            let future = Data("{\"version\":999,\"unknown\":true}".utf8)
            let futureURL = futureIsBackup ? store.backupURL : store.url
            let supportedURL = futureIsBackup ? store.url : store.backupURL
            try future.write(to: futureURL)
            let supported = try JSONEncoder().encode(SessionSnapshot())
            try supported.write(to: supportedURL)
            let result = store.load()
            XCTAssertFalse(result.canSave)
            XCTAssertNil(result.snapshot)
            let done = expectation(description: "save rejected")
            store.save(SessionSnapshot()) { error in XCTAssertNotNil(error); done.fulfill() }
            wait(for: [done], timeout: 3)
            XCTAssertEqual(try Data(contentsOf: futureURL), future)
            XCTAssertEqual(try Data(contentsOf: supportedURL), supported)
        }
    }

    func testSaveWithoutLoadStillProtectsFutureData() throws {
        let store = SessionStore(directory: try directory())
        let future = Data("{\"version\":99}".utf8)
        try future.write(to: store.url)
        let done = expectation(description: "save rejected")
        store.save(SessionSnapshot()) { error in XCTAssertNotNil(error); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: store.url), future)
    }

    func testWriteFailureIsReported() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: file)
        let store = SessionStore(directory: file)
        let done = expectation(description: "error reported")
        store.save(SessionSnapshot()) { error in XCTAssertNotNil(error); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: file), Data("file".utf8))
    }

    func testMissingTabInSelectedSpaceClearsSelectionWithoutLosingOtherTabs() {
        let work = Space(name: "Work")
        let homeTab = Tab(urlString: "https://example.com")
        let window = WindowRecord(selectedSpaceID: work.id, selectedTabID: homeTab.id, tabs: [homeTab])
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], windows: [window]).validated()
        let repaired = snapshot.windows[0]
        XCTAssertEqual(repaired.tabs.count, 1)
        XCTAssertEqual(repaired.tabs[0].id, homeTab.id)
        XCTAssertNil(repaired.selectedTabID)
    }

    func testPinnedInstancesFollowDefinitionAndDuplicateInstancesDetach() {
        let work = Space(name: "Work")
        let item = SavedItem(spaceID: work.id, urlString: "https://pinned.example")
        let first = Tab(urlString: "https://pinned.example/one", savedItemID: item.id)
        let second = Tab(urlString: "https://pinned.example/two", savedItemID: item.id)
        let window = WindowRecord(selectedTabID: first.id, tabs: [first, second])
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], savedItems: [item], windows: [window]).validated()
        let repaired = snapshot.windows[0]
        XCTAssertEqual(repaired.tabs.map(\.id), [first.id, second.id])
        XCTAssertEqual(repaired.tabs.map(\.spaceID), [work.id, work.id])
        XCTAssertEqual(repaired.tabs.map(\.urlString), [first.urlString, second.urlString])
        XCTAssertEqual(repaired.tabs[0].savedItemID, item.id)
        XCTAssertNil(repaired.tabs[1].savedItemID)
        XCTAssertEqual(repaired.selectedTabID, first.id)
        XCTAssertEqual(repaired.selectedSpaceID, work.id)
    }

    func testSelectedFavoriteRemainsSelectedAcrossSpaces() {
        let work = Space(name: "Work")
        let favorite = SavedItem(urlString: "https://favorite.example")
        let tab = Tab(savedItemID: favorite.id)
        let window = WindowRecord(selectedSpaceID: work.id, selectedTabID: tab.id, tabs: [tab])
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], savedItems: [favorite], windows: [window]).validated()
        XCTAssertEqual(snapshot.windows[0].selectedSpaceID, work.id)
        XCTAssertEqual(snapshot.windows[0].selectedTabID, tab.id)
        XCTAssertEqual(snapshot.windows[0].tabs.map(\.id), [tab.id])
        XCTAssertEqual(snapshot.windows[0].tabs[0].spaceID, Space.defaultID)
    }

    func testWorkspaceReplacementPreservesCurrentSnapshotAcrossAutosaves() throws {
        let store = SessionStore(directory: try directory())
        var original = SessionSnapshot(windows: [WindowRecord(tabs: [Tab(title: "Fixture")])])
        original.windows[0].tabs[0].title = "Original on disk"
        save(original, to: store)
        var current = original
        current.windows[0].tabs[0].title = "Latest unsaved workspace"
        var replacement = SessionSnapshot(windows: [WindowRecord(tabs: [Tab(title: "Fixture")])])
        replacement.windows[0].tabs[0].title = "Imported workspace"
        try store.replace(with: replacement, preserving: current)
        let preservedURL = store.directory.appendingPathComponent("workspace-before-restore.json")
        let preservedData = try Data(contentsOf: preservedURL)
        let preserved = try JSONDecoder().decode(SessionSnapshot.self, from: preservedData)
        XCTAssertEqual(preserved.windows, current.windows)
        XCTAssertEqual(try XCTUnwrap(store.load().snapshot).windows, replacement.windows)
        for title in ["First autosave", "Second autosave"] {
            replacement.windows[0].tabs[0].title = title
            save(replacement, to: store)
        }
        XCTAssertEqual(try Data(contentsOf: preservedURL), preservedData)
        XCTAssertEqual(try XCTUnwrap(store.load().snapshot).windows[0].tabs[0].title, "Second autosave")
    }

    func testFutureWorkspaceReplacementDoesNotChangePrimaryOrBackups() throws {
        let store = SessionStore(directory: try directory())
        let current = SessionSnapshot()
        save(current, to: store)
        save(current, to: store)
        let primary = try Data(contentsOf: store.url)
        let backup = try Data(contentsOf: store.backupURL)
        let dedicatedURL = store.directory.appendingPathComponent("workspace-before-restore.json")
        let dedicated = Data("previous restore recovery copy".utf8)
        try dedicated.write(to: dedicatedURL)
        var future = SessionSnapshot()
        future.version = SessionSnapshot.currentVersion + 1
        XCTAssertThrowsError(try store.replace(with: future, preserving: current))
        XCTAssertEqual(try Data(contentsOf: store.url), primary)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
        XCTAssertEqual(try Data(contentsOf: dedicatedURL), dedicated)
    }

    func testReplacementCannotOverwriteNewerSessionAlreadyOnDisk() throws {
        let store = SessionStore(directory: try directory())
        let future = Data("{\"version\":999}".utf8)
        let supported = try JSONEncoder().encode(SessionSnapshot())
        try future.write(to: store.url)
        try supported.write(to: store.backupURL)
        XCTAssertThrowsError(try store.replace(with: SessionSnapshot(), preserving: SessionSnapshot()))
        XCTAssertEqual(try Data(contentsOf: store.url), future)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), supported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("workspace-before-restore.json").path))
    }
}
