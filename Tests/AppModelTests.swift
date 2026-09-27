import XCTest
import WebKit
@testable import Cobble

@MainActor
final class AppModelTests: XCTestCase {
    func testOpenFileUsesEffectiveEngineWithoutALoadedPage() throws {
        try withApp { app in
            let window = app.newWindow()
            app.preferences.setDefaultEngine(EngineID(rawValue: "chromium"))
            XCTAssertNil(window.selectedPage)
            XCTAssertTrue(window.canPerform(.openFile))
            app.preferences.setDefaultEngine(EngineID(rawValue: "future.engine"))
            XCTAssertFalse(window.canPerform(.openFile))
            let tab = Tab(isUnloaded: true, engineID: EngineID(rawValue: "chromium"))
            window.record.tabs = [tab]
            window.record.selectedTabID = tab.id
            XCTAssertTrue(window.canPerform(.openFile))
        }
    }

    func testCloseOtherTemporaryTabsPreservesSavedTabsOtherSpacesAndWindows() throws {
        let otherSpace = Space(name: "Other")
        let pin = SavedItem(spaceID: Space.defaultID, title: "Pin")
        let favorite = SavedItem(title: "Favorite")
        let selected = Tab(title: "Selected")
        let closed = Tab(title: "Close me")
        let saved = Tab(title: "Pin", savedItemID: pin.id)
        let favoriteTab = Tab(title: "Favorite", savedItemID: favorite.id)
        let elsewhere = Tab(spaceID: otherSpace.id, title: "Other space")
        let anotherWindowTab = Tab(title: "Other window")
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), otherSpace], savedItems: [pin, favorite],
            windows: [WindowRecord(selectedTabID: selected.id, tabs: [selected, closed, saved, favoriteTab, elsewhere]),
                      WindowRecord(selectedTabID: anotherWindowTab.id, tabs: [anotherWindowTab])])
        try withApp(snapshot) { app in
            let window = try XCTUnwrap(app.windows.first)
            XCTAssertTrue(window.perform(.closeOtherTabs))
            XCTAssertEqual(window.record.tabs.map(\.id), [selected.id, saved.id, favoriteTab.id, elsewhere.id])
            XCTAssertEqual(window.selectedTab?.id, selected.id)
            XCTAssertEqual(app.windows[1].record.tabs.map(\.id), [anotherWindowTab.id])
            XCTAssertEqual(app.savedItems.map(\.id), [pin.id, favorite.id])
            XCTAssertFalse(window.canPerform(.closeOtherTabs))
            window.reopenClosedTab()
            XCTAssertEqual(window.selectedTab?.id, closed.id)
            let privateWindow = app.newWindow(isPrivate: true)
            let privateSelected = Tab(title: "Private selected")
            privateWindow.record.tabs = [privateSelected, Tab(title: "Private other")]
            privateWindow.record.selectedTabID = privateSelected.id
            XCTAssertTrue(privateWindow.perform(.closeOtherTabs))
            XCTAssertEqual(privateWindow.record.tabs.map(\.id), [privateSelected.id])
            XCTAssertTrue(privateWindow.closedTabs.isEmpty)
        }
    }

    func testAddressSuggestionsStayLocalAndNavigateCurrentTab() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let originalID = try XCTUnwrap(window.selectedTab?.id)
            let count = window.record.tabs.count
            let destination = "http://127.0.0.1:9/library-destination"
            app.library.bookmark(urlString: destination, title: "Library needle", profileID: window.record.profileID)
            app.library.bookmark(urlString: "https://other-profile.example", title: "Library needle", profileID: UUID())
            window.focusAddress()
            window.addressDraft = "Library needle"
            let suggestion = try XCTUnwrap(window.addressSuggestions.first)
            XCTAssertEqual(window.addressSuggestions.count, 1)
            XCTAssertEqual(suggestion.urlString, destination)
            window.submitAddressSuggestion(suggestion.id)
            XCTAssertEqual(window.selectedTab?.id, originalID)
            XCTAssertEqual(window.record.tabs.count, count)
            XCTAssertEqual(window.addressDraft, destination)
            XCTAssertFalse(window.isEditingAddress)

            window.focusAddress()
            window.addressDraft = "Library needle"
            window.submitAddress()
            XCTAssertEqual(URLComponents(string: window.addressDraft)?.queryItems?.first(where: { $0.name == "q" })?.value, "Library needle")
            XCTAssertEqual(window.selectedTab?.id, originalID)
            window.focusAddress()
            window.addressDraft = "Do not navigate"
            window.cancelAddressEditing()
            XCTAssertEqual(window.addressDraft, window.selectedTab?.urlString ?? "")
            XCTAssertTrue(window.addressSuggestions.isEmpty)

            let privateWindow = app.newWindow(isPrivate: true)
            privateWindow.focusAddress()
            privateWindow.addressDraft = "Library needle"
            XCTAssertTrue(privateWindow.addressSuggestions.isEmpty)
            privateWindow.submitAddressSuggestion(suggestion.id)
            XCTAssertTrue(privateWindow.record.tabs.isEmpty)
            XCTAssertEqual(privateWindow.addressDraft, "Library needle")
        }
    }

    func testExplicitPageExportCommandsAllowPrivatePagesWithoutSavingHistory() throws {
        try withApp { app in
            let window = app.newWindow(isPrivate: true)
            XCTAssertFalse(window.canPerform(.screenshot))
            XCTAssertFalse(window.canPerform(.sharePage))
            let tab = Tab(urlString: "https://private-export.example", title: "Private export")
            window.record.tabs = [tab]
            window.select(tab.id)
            XCTAssertTrue(window.canPerform(.sharePage))
            let host = try XCTUnwrap(window.selectedPage)
            host.state.lifecycle = .ready
            XCTAssertTrue(window.canPerform(.screenshot))
            XCTAssertTrue(window.canPerform(.openFile))
            XCTAssertTrue(window.canPerform(.savePage))
            XCTAssertTrue(window.canPerform(.viewPageDOM))
            XCTAssertTrue(app.library.search("private-export", profileID: window.record.profileID).isEmpty)
            XCTAssertFalse(app.snapshot.windows.contains { $0.id == window.id })
            window.record.tabs[0].localFileBookmark = Data("private local file".utf8)
            XCTAssertFalse(app.snapshot.windows.contains { $0.tabs.contains { $0.localFileBookmark != nil } })
            window.closePages()
            XCTAssertFalse(window.canPerform(.screenshot))
            XCTAssertFalse(window.canPerform(.sharePage))
        }
    }

    func testLocalFilesRequireReauthorizationBeforeSavingOrOpeningAnEmptyWindow() async throws {
        try await withAppAsync { app in
            let window = try XCTUnwrap(app.windows.first)
            window.record.tabs.removeAll()
            window.clearSelection()
            XCTAssertTrue(window.canPerform(.openFile))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleEmptyOpen-\(UUID()).html")
            try "<title>Local</title>".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            try await window.acceptLocalFile(file)
            let local = try XCTUnwrap(window.selectedTab)
            XCTAssertEqual(local.urlString, file.absoluteString)
            XCTAssertNotNil(local.localFileBookmark)
            let bookmark = local.localFileBookmark
            let missing = file.deletingLastPathComponent().appendingPathComponent("Missing-\(UUID()).html")
            do {
                try await window.acceptLocalFile(missing, replacing: local.id)
                XCTFail("Expected a missing local file to fail")
            } catch {}
            XCTAssertEqual(window.selectedTab?.id, local.id)
            XCTAssertEqual(window.selectedTab?.urlString, file.absoluteString)
            XCTAssertEqual(window.selectedTab?.localFileBookmark, bookmark)
            XCTAssertFalse(window.canPerform(.pinTab))
            XCTAssertFalse(window.canPerform(.favoriteTab))
            XCTAssertFalse(window.canPerform(.bookmark))
            window.pinTab(local.id)
            window.bookmarkSelected()
            XCTAssertTrue(app.savedItems.isEmpty)
            XCTAssertNil(app.saveTab(local, profileID: window.record.profileID, favorite: false))
        }
    }

    func testPinningRejectsNonWebAddresses() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            for address in ["javascript:alert(1)", "data:text/plain,secret", "https://"] {
                let tab = Tab(urlString: address, title: "Invalid")
                window.record.tabs = [tab]
                window.record.selectedTabID = tab.id
                window.pinTab(tab.id)
                XCTAssertTrue(app.savedItems.isEmpty, "Saved \(address)")
                XCTAssertNil(window.record.tabs[0].savedItemID)
            }
        }
    }

    func testWorkspaceReplacementStripsImportedLocalFileAuthorization() throws {
        let bookmark = Data(repeating: 8, count: 32)
        let tab = Tab(urlString: "file:///tmp/imported.html", title: "Imported", localFileBookmark: bookmark)
        try withApp { app in
            try app.replaceWorkspace(with: SessionSnapshot(windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])]))
            XCTAssertEqual(app.windows[0].record.tabs[0].urlString, tab.urlString)
            XCTAssertNil(app.windows[0].record.tabs[0].localFileBookmark)
        }
    }

    func testCommandSearchUsesNativeCommandTitles() {
        XCTAssertEqual(BrowserCommand.matching("  DUPLICATE  "), [.duplicateTab])
        XCTAssertEqual(BrowserCommand.matching(" "), [.newSpace])
        XCTAssertTrue(BrowserCommand.matching("close other").contains(.closeOtherTabs))
        XCTAssertTrue(BrowserCommand.matching("https://unmatched.example").isEmpty)
    }

    func testExplicitProfileNewWindowUsesThatProfileAndRejectsUnknownProfile() throws {
        let work = Profile(name: "Work", storeBinding: .named(UUID()))
        let workSpace = Space(profileID: work.id, name: "Work")
        let snapshot = SessionSnapshot(profiles: [Profile(id: Profile.defaultID), work],
                                       spaces: [Space(id: Space.defaultID), workSpace])
        try withApp(snapshot) { app in
            let url = try XCTUnwrap(URL(string: "https://work.example"))
            let window = try XCTUnwrap(app.newWindow(url: url, profileID: work.id))
            XCTAssertEqual(window.record.profileID, work.id)
            XCTAssertEqual(window.record.selectedSpaceID, workSpace.id)
            XCTAssertEqual(window.selectedTab?.urlString, url.absoluteString)

            let count = app.windows.count
            XCTAssertNil(app.newWindow(url: url, profileID: UUID()))
            XCTAssertEqual(app.windows.count, count)
        }
    }

    func testProfilesCreateRenameSelectAndKeepTheirNamedStoreAcrossRestart() throws {
        try withApp { app in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let binding = profile.storeBinding
            XCTAssertEqual(app.spaces.filter { $0.profileID == profile.id }.count, 1)
            XCTAssertTrue(app.renameProfile(id: profile.id, name: "Team"))
            var activated = 0
            app.onActivateWindow = { _ in activated += 1 }
            let first = try XCTUnwrap(app.selectProfile(profile.id))
            let second = try XCTUnwrap(app.selectProfile(profile.id))
            XCTAssertTrue(first === second)
            XCTAssertEqual(activated, 1)
            XCTAssertEqual(first.record.profileID, profile.id)
            app.flush()
            let restored = AppModel(store: app.store, websiteDataStoreOverride: .nonPersistent())
            let saved = try XCTUnwrap(restored.profiles.first { $0.id == profile.id })
            XCTAssertEqual(saved.name, "Team")
            XCTAssertEqual(saved.storeBinding, binding)
        }
    }

    func testGeneratedProfileHomeLocalizesOnlyUntilRenamed() throws {
        try withApp { app in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let space = try XCTUnwrap(app.spaces.first { $0.profileID == profile.id })
            XCTAssertEqual(space.isGeneratedDefault, true)
            XCTAssertEqual(space.displayedName, String(localized: "Home"))
            app.renameSpace(id: space.id, name: "Studio")
            XCTAssertEqual(app.spaces.first { $0.id == space.id }?.displayedName, "Studio")
            app.renameSpace(id: space.id, name: "Home")
            XCTAssertEqual(app.spaces.first { $0.id == space.id }?.isGeneratedDefault, false)
            XCTAssertEqual(app.spaces.first { $0.id == space.id }?.displayedName, "Home")
            let restored = try SessionSnapshot.decode(JSONEncoder().encode(app.snapshot))
            XCTAssertEqual(restored.spaces.first { $0.id == space.id }?.isGeneratedDefault, false)
            XCTAssertEqual(restored.spaces.first { $0.id == space.id }?.displayedName, "Home")
            app.undoOrganization()
            XCTAssertEqual(app.spaces.first { $0.id == space.id }?.name, "Studio")
            XCTAssertEqual(app.spaces.first { $0.id == space.id }?.isGeneratedDefault, false)
            app.undoOrganization()
            XCTAssertEqual(app.spaces.first { $0.id == space.id }?.isGeneratedDefault, true)
            XCTAssertEqual(app.spaces.first { $0.id == space.id }?.displayedName, String(localized: "Home"))
        }
    }

    func testProfileDeletionRemovesProfileScopedRecordsAndKeepsPrivateRecordsEphemeral() async throws {
        try await withAppAsync { app in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let space = try XCTUnwrap(app.spaces.first { $0.profileID == profile.id })
            app.savedItems.append(SavedItem(profileID: profile.id, spaceID: space.id, urlString: "https://saved.example", title: "Saved"))
            app.library.bookmark(urlString: "https://bookmark.example", title: "Bookmark", profileID: profile.id)
            app.library.setRetentionDays(365, profileID: profile.id)
            app.siteSettings.update(SiteSetting(profileID: profile.id, origin: "https://permission.example", camera: .allow, zoom: 1.5))
            let normal = try XCTUnwrap(app.newWindow(profileID: profile.id))
            let privateWindow = try XCTUnwrap(app.newWindow(isPrivate: true, profileID: profile.id))
            XCTAssertFalse(app.snapshot.windows.contains { $0.id == privateWindow.id })
            let deletion = await app.deleteProfile(profile.id)
            XCTAssertNil(deletion)
            XCTAssertFalse(app.profiles.contains { $0.id == profile.id })
            XCTAssertFalse(app.spaces.contains { $0.profileID == profile.id })
            XCTAssertFalse(app.savedItems.contains { $0.profileID == profile.id })
            XCTAssertFalse(app.windows.contains { $0.id == normal.id || $0.id == privateWindow.id })
            XCTAssertTrue(app.library.search("", profileID: profile.id).isEmpty)
            XCTAssertEqual(app.library.retentionDays(profileID: profile.id), 90)
            XCTAssertTrue(app.siteSettings.entries.filter { $0.profileID == profile.id }.isEmpty)
        }
    }

    func testDefaultProfileCannotBeDeleted() async throws {
        try await withAppAsync { app in
            let result = await app.deleteProfile(Profile.defaultID)
            let message = try XCTUnwrap(result)
            XCTAssertTrue(message.contains("cannot be deleted"))
            XCTAssertTrue(app.profiles.contains { $0.id == Profile.defaultID })
        }
    }

    func testProfileDeletionReportsFinalSessionWriteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleAppModelTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        store.save(SessionSnapshot()) { XCTAssertNil($0) }
        store.flush()
        let app = AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
        defer { app.windows.forEach { $0.closePages() }; app.library.close() }
        let profile = try XCTUnwrap(app.createProfile(name: "Work"))
        let window = try XCTUnwrap(app.newWindow(profileID: profile.id))
        app.library.bookmark(urlString: "https://keep.example", title: "Keep", profileID: profile.id)
        app.siteSettings.update(SiteSetting(profileID: profile.id, origin: "https://keep.example", camera: .allow))
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        let result = await app.deleteProfile(profile.id)
        let message = try XCTUnwrap(result)

        XCTAssertTrue(message.contains("Could not save the session"))
        XCTAssertTrue(app.persistenceMessage?.contains("Could not save the session") == true)
        XCTAssertTrue(app.profiles.contains { $0.id == profile.id })
        XCTAssertTrue(app.windows.contains { $0 === window })
        XCTAssertFalse(app.library.search("keep.example", profileID: profile.id).isEmpty)
        XCTAssertFalse(app.siteSettings.entries.filter { $0.profileID == profile.id }.isEmpty)
    }

    func testFailedFinalSaveCanCancelTerminationAndLaterSuccessClearsTheWarning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleQuitSaveTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let initialSave = await store.save(SessionSnapshot())
        XCTAssertNil(initialSave)
        let app = AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
        defer { app.windows.forEach { $0.closePages() }; app.library.close() }
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        let canTerminate = await app.requestTerminationPreflight()
        XCTAssertTrue(canTerminate)
        let failure = await app.flushAndWait()
        app.windows.forEach { $0.cancelClosePages() }
        XCTAssertNotNil(failure)
        XCTAssertNotNil(app.persistenceMessage)

        try FileManager.default.removeItem(at: store.url)
        let retry = await app.flushAndWait()
        XCTAssertNil(retry)
        XCTAssertNil(app.persistenceMessage)
    }

    func testSidebarCyclingUsesSavedOrderAndStaysWindowLocalAfterRestore() throws {
        try withApp { app in
            let first = try XCTUnwrap(app.windows.first)
            let second = app.newWindow()
            let favorite = SavedItem(title: "Favorite")
            let folder = Folder(name: "Folder")
            let pin = SavedItem(spaceID: Space.defaultID, folderID: folder.id, title: "Pin")
            app.savedItems = [pin, favorite]; app.folders = [folder]
            first.record.collapsedFolderIDs = [folder.id]
            first.clearSelection()
            first.cycleTab(offset: 1)
            XCTAssertEqual(first.selectedTab?.savedItemID, favorite.id)
            first.cycleTab(offset: 1)
            XCTAssertEqual(first.selectedTab?.savedItemID, pin.id)
            XCTAssertFalse(first.record.collapsedFolderIDs.contains(folder.id))
            XCTAssertNil(second.selectedTab)
            first.cycleTab(offset: 1)
            XCTAssertNil(first.selectedTab?.savedItemID)
            first.cycleTab(offset: 1)
            XCTAssertEqual(first.selectedTab?.savedItemID, favorite.id)
            first.cycleTab(offset: -1)
            XCTAssertNil(first.selectedTab?.savedItemID)
            app.addSpace(name: "Work", profileID: Profile.defaultID)
            first.cycleSpace(offset: 1)
            XCTAssertEqual(first.selectedSpace?.name, "Work")
            XCTAssertEqual(second.selectedSpace?.id, Space.defaultID)
            first.sidebarVisible = false; first.record.sidebarWidth = 330
            app.flush()
            let restored = AppModel(store: SessionStore(directory: app.store.directory), websiteDataStoreOverride: .nonPersistent())
            defer { restored.windows.forEach { $0.closePages() }; restored.flush(); restored.library.close() }
            let restoredFirst = try XCTUnwrap(restored.windows.first { $0.id == first.id })
            XCTAssertEqual(restoredFirst.record.selectedSpaceID, first.record.selectedSpaceID)
            XCTAssertEqual(restoredFirst.record.sidebarWidth, 330)
            XCTAssertFalse(restoredFirst.sidebarVisible)
            XCTAssertFalse(restoredFirst.sidebarPeeked)
            XCTAssertEqual(restored.savedItems.map(\.id), app.savedItems.map(\.id))
        }
    }

    func testExpandingFolderLeavesOtherFoldersClosed() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let target = Folder(name: "Target")
            let other = Folder(name: "Other")
            window.record.collapsedFolderIDs = [target.id, other.id]

            window.expandFolder(target.id)

            XCTAssertEqual(window.record.collapsedFolderIDs, [other.id])
        }
    }

    func testUnpinnedSidebarPeekDoesNotPin() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            window.sidebarVisible = false
            window.revealSidebarChrome()
            XCTAssertTrue(window.sidebarPeeked)
            XCTAssertFalse(window.sidebarVisible)
            XCTAssertTrue(window.perform(.newSpace))
            XCTAssertTrue(window.sidebarPeeked)
            XCTAssertFalse(window.sidebarVisible)
            window.sidebarVisible = true
            XCTAssertFalse(window.sidebarPeeked)
            window.revealSidebarChrome()
            XCTAssertFalse(window.sidebarPeeked)
        }
    }

    func testShortcutConflictsPersistenceAndCorruptionProtection() throws {
        try withApp { app in
            let prefs = app.preferences
            for command in BrowserCommand.allCases {
                XCTAssertTrue(command.defaultShortcut.isValid)
                XCTAssertNil(prefs.conflict(for: command.defaultShortcut, excluding: command))
            }
            XCTAssertFalse(prefs.set(.init("q"), for: .nextTab))
            XCTAssertFalse(prefs.set(.init("n"), for: .nextTab))
            XCTAssertFalse(prefs.set(.init("k", .option), for: .nextTab))
            XCTAssertTrue(prefs.set(.init("j", [.command, .option]), for: .nextTab))
            XCTAssertEqual(prefs.conflict(for: .init("1"), excluding: .newTab), "Space 1")
            XCTAssertFalse(prefs.set(.init("1"), for: .nextTab))
            let restored = BrowserPreferences(directory: app.store.directory)
            XCTAssertEqual(restored.shortcut(for: .nextTab), .init("j", [.command, .option]))
            restored.resetShortcuts()
            XCTAssertEqual(restored.shortcut(for: .nextTab), BrowserCommand.nextTab.defaultShortcut)
            let url = app.store.directory.appendingPathComponent("browser-preferences.json")
            let corrupt = Data("future or damaged preferences".utf8)
            try corrupt.write(to: url)
            let damaged = BrowserPreferences(directory: app.store.directory)
            XCTAssertNotNil(damaged.errorMessage)
            damaged.errorMessage = nil // Opening the shortcut recorder clears transient errors.
            XCTAssertFalse(damaged.set(.init("j", .command), for: .nextTab))
            XCTAssertNotNil(damaged.errorMessage)
            damaged.errorMessage = nil
            damaged.resetShortcuts()
            XCTAssertNotNil(damaged.errorMessage)
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    func testSpaceIconUndoAndNumberedJumpSelectsNthSpace() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            app.addSpace(name: "Work", profileID: Profile.defaultID)
            app.addSpace(name: "Lab", profileID: Profile.defaultID)
            XCTAssertEqual(window.spaces.map(\.name), ["Home", "Work", "Lab"])
            XCTAssertTrue(window.selectSpace(at: 2))
            XCTAssertEqual(window.selectedSpace?.name, "Lab")
            XCTAssertFalse(window.selectSpace(at: 9))
            XCTAssertEqual(window.selectedSpace?.name, "Lab")
            let work = try XCTUnwrap(window.spaces.first(where: { $0.name == "Work" }))
            app.setSpaceIcon(id: work.id, icon: "pretzel")
            XCTAssertNil(window.spaces.first(where: { $0.id == work.id })?.icon)
            app.setSpaceIcon(id: work.id, icon: "🥨")
            XCTAssertEqual(window.spaces.first(where: { $0.id == work.id })?.icon, "🥨")
            app.undoOrganization()
            XCTAssertNil(window.spaces.first(where: { $0.id == work.id })?.icon)
            app.updateSpace(id: work.id, name: "Office", icon: "📁")
            XCTAssertEqual(window.spaces.first(where: { $0.id == work.id })?.name, "Office")
            XCTAssertEqual(window.spaces.first(where: { $0.id == work.id })?.icon, "📁")
            app.addFolder(name: "Notes", spaceID: work.id, color: .teal)
            let folder = try XCTUnwrap(app.folders.first { $0.name == "Notes" })
            XCTAssertEqual(folder.color, .teal)
            app.updateFolder(id: folder.id, name: "Reading", color: .purple)
            XCTAssertEqual(app.folders.first { $0.id == folder.id }?.name, "Reading")
            XCTAssertEqual(app.folders.first { $0.id == folder.id }?.color, .purple)
            app.setFolderColor(id: folder.id, color: .blue)
            XCTAssertEqual(app.folders.first { $0.id == folder.id }?.color, .blue)
        }
    }

    func testReopenClosedTabByIDUsesNewestLastOrder() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let first = Tab(spaceID: window.record.selectedSpaceID, title: "One")
            let second = Tab(spaceID: window.record.selectedSpaceID, title: "Two")
            window.record.tabs.append(contentsOf: [first, second])
            window.closeTab(first.id)
            window.closeTab(second.id)
            XCTAssertEqual(window.closedTabs.map(\.id), [first.id, second.id])
            window.reopenClosedTab(id: first.id)
            XCTAssertEqual(window.closedTabs.map(\.id), [second.id])
            XCTAssertTrue(window.record.tabs.contains { $0.id == first.id })
            window.reopenClosedTab()
            XCTAssertTrue(window.closedTabs.isEmpty)
            XCTAssertTrue(window.record.tabs.contains { $0.id == second.id })
        }
    }

    func testCommandZReopensClosedTab() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let nativeWindow = NSWindow()
            window.nativeWindow = nativeWindow
            let closed = try XCTUnwrap(window.selectedTab)

            window.closeTab(closed.id)
            XCTAssertTrue(nativeWindow.undoManager?.canUndo == true)
            nativeWindow.undoManager?.undo()

            XCTAssertEqual(window.selectedTab?.id, closed.id)
            XCTAssertTrue(window.closedTabs.isEmpty)
        }
    }

    func testRenamedTabKeepsOverrideUntilCleared() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let tab = Tab(urlString: "https://cobble.test/page", title: "Page")
            window.record.tabs = [tab]
            window.renameTab(tab.id, title: "Home")
            XCTAssertEqual(window.record.tabs[0].displayedTitle, "Home")
            window.record.tabs[0].title = "Other"
            XCTAssertEqual(window.record.tabs[0].displayedTitle, "Home")
            window.renameTab(tab.id, title: "  ")
            XCTAssertEqual(window.record.tabs[0].displayedTitle, "Other")
        }
    }

    func testCopyPageURLAndSitePermissionDenyUpdateStore() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let url = try XCTUnwrap(URL(string: "https://cobble.test/page"))
            window.addTab(url: url)
            window.copyPageURL()
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), url.absoluteString)
            XCTAssertTrue(window.canPerform(.copyURL))
            window.setSitePermission(.camera, .deny)
            XCTAssertEqual(app.siteSettings.setting(origin: url, profileID: window.record.profileID).camera, .deny)
            window.setPopups(.allow)
            XCTAssertEqual(app.siteSettings.setting(origin: url, profileID: window.record.profileID).popups, .allow)
            XCTAssertEqual(window.pageConnection, .unknown)
        }
    }

    func testPinCommandMakesExistingSavedItemGlobalWithUndo() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let saved = SavedItem(spaceID: Space.defaultID, title: "Saved")
            app.savedItems = [saved]
            window.openSavedItem(saved.id)
            let tab = try XCTUnwrap(window.selectedTab)
            window.pinTab(tab.id)
            XCTAssertNil(app.savedItems[0].spaceID)
            XCTAssertEqual(window.selectedTab?.savedItemID, saved.id)
            app.undoOrganization()
            XCTAssertEqual(app.savedItems[0].spaceID, Space.defaultID)
            XCTAssertEqual(app.savedItems.count, 1)
        }
    }

    func testSpaceSwipeTracksDistanceWithAxisLockAndReset() {
        var tracker = SidebarSwipeTracker()
        XCTAssertFalse(tracker.update(x: -4, y: 1).consume)
        XCTAssertEqual(tracker.update(x: -75, y: 2).translation,
                       (-4 + SidebarSwipeTracker.distanceDelta(-75)) / 2, accuracy: 0.000_001)
        XCTAssertEqual(tracker.update(x: 100, y: 0).translation,
                       (-4 + SidebarSwipeTracker.distanceDelta(-75) + SidebarSwipeTracker.distanceDelta(100)) / 2,
                       accuracy: 0.000_001)
        tracker.reset()
        XCTAssertFalse(tracker.update(x: 2, y: 20).consume)
        XCTAssertFalse(tracker.update(x: 100, y: 0).consume)
        tracker.reset()
        XCTAssertTrue(tracker.update(x: -80, y: 0).consume)
        tracker.reset()
        XCTAssertTrue(tracker.update(x: 10, y: 1).consume)
        XCTAssertFalse(tracker.update(x: 0, y: 12).consume)
        XCTAssertFalse(tracker.update(x: 100, y: 0).consume)
        tracker.reset()
        XCTAssertFalse(tracker.update(x: 8, y: 5).consume)
        XCTAssertTrue(tracker.update(x: 10, y: 0).consume)
        XCTAssertEqual(SidebarSwipeTracker.distanceDelta(3), 3)
        XCTAssertEqual(SidebarSwipeTracker.distanceDelta(100), 100 * 0.75 + (4 + sqrt(96)) * 0.25,
                       accuracy: 0.000_001)
    }

    func testShortSpaceSwipeTracksOneToOneAndCrossesAtCommitThreshold() {
        for width in [260.0, 280, 440] {
            for sign in [-1.0, 1] {
                var tracker = SidebarSwipeTracker()
                let threshold = width * SidebarSwipeTracker.commitFraction
                var remaining = threshold - 0.25
                var before = tracker.update(x: sign * min(4, remaining), y: 0)
                remaining -= min(4, remaining)
                while remaining > 0 {
                    let delta = min(4, remaining)
                    before = tracker.update(x: sign * delta, y: 0)
                    remaining -= delta
                }
                XCTAssertTrue(before.consume)
                XCTAssertNil(SidebarSwipeTracker.destination(translation: before.intent, width: width))
                let crossing = tracker.update(x: sign * 0.25, y: 0)
                XCTAssertEqual(crossing.translation, sign * threshold / 2, accuracy: 0.000_001)
                XCTAssertEqual(SidebarSwipeTracker.destination(translation: crossing.intent, width: width), sign < 0 ? 1 : -1)
                let reverse = tracker.update(x: -sign * 0.25, y: 0)
                XCTAssertNil(SidebarSwipeTracker.destination(translation: reverse.intent, width: width))
            }
        }
    }

    func testSpaceSwipeCapsVisualSpeedWithoutChangingCommitIntent() {
        var tracker = SidebarSwipeTracker()
        let first = tracker.update(x: 10, y: 0, timestamp: 0)
        XCTAssertEqual(first.translation, SidebarSwipeTracker.distanceDelta(10) / 2)
        let burst = tracker.update(x: 100, y: 0, timestamp: 1.0 / 120)
        XCTAssertEqual(burst.translation, first.translation + SidebarSwipeTracker.maximumSpeed / 120)
        XCTAssertEqual(burst.intent, SidebarSwipeTracker.distanceDelta(10) + SidebarSwipeTracker.distanceDelta(100), accuracy: 0.000_001)
    }

    func testSpaceSwipePreviewsWithoutLoadingAndCommitsOnlyOnRelease() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let source = window.record.selectedSpaceID
            let other = Space(name: "Other")
            app.spaces.append(other)
            let original = Tab(spaceID: source, title: "Original")
            let later = Tab(spaceID: source, title: "Later")
            let destination = Tab(spaceID: other.id, title: "Destination")
            window.record.tabs = [original, later, destination]
            window.select(original.id)
            let host = try XCTUnwrap(window.selectedPage)
            var swipe = SidebarSwipeSession(window: window, width: 280)
            swipe.update(translation: -83)
            XCTAssertEqual(window.selectedTab?.id, original.id)
            swipe.update(translation: -84)
            XCTAssertEqual(swipe.activeOffset, 1)
            XCTAssertEqual(window.selectedTab?.id, original.id, "A preview must not select or load the next space")
            swipe.update(translation: -85)
            XCTAssertTrue(window.selectedPage === host)
            swipe.update(translation: -83)
            XCTAssertNil(swipe.activeOffset)
            XCTAssertEqual(window.selectedTab?.id, original.id)
            swipe.update(translation: -84)
            swipe.commit(in: window)
            XCTAssertEqual(window.selectedTab?.id, destination.id)
            XCTAssertTrue(swipe.matchesSelection(in: window))

            var cancelled = SidebarSwipeSession(window: window, width: 280)
            cancelled.update(translation: 70)
            cancelled.cancel()
            XCTAssertNil(cancelled.activeOffset)
            XCTAssertEqual(window.selectedTab?.id, destination.id)

            window.select(original.id)
            swipe = SidebarSwipeSession(window: window, width: 280)
            swipe.update(translation: 300)
            XCTAssertEqual(window.selectedTab?.id, original.id, "No neighbor before first space")
            XCTAssertNil(swipe.activeOffset)
            window.select(later.id)
            XCTAssertFalse(swipe.matchesSelection(in: window))
        }
    }

    func testArcDefaultsAndLegacySwipePreferenceMigration() throws {
        try withApp { app in
            XCTAssertEqual(BrowserCommand.sidebar.defaultShortcut, .init("s"))
            XCTAssertEqual(BrowserCommand.pinTab.defaultShortcut, .init("d"))
            XCTAssertEqual(BrowserCommand.recentTab.defaultShortcut, .init("\t", .control))
            XCTAssertEqual(BrowserCommand.nextSpace.defaultShortcut, .init(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]))
            let url = app.store.directory.appendingPathComponent("browser-preferences.json")
            try Data(#"{"version":1,"swipe":"tabs","shortcuts":{"nextTab":{"key":"\t","modifiers":262144}}}"#.utf8).write(to: url)
            let preferences = BrowserPreferences(directory: app.store.directory)
            XCTAssertNil(preferences.errorMessage)
            XCTAssertEqual(preferences.shortcut(for: .nextTab), .init("\t", .control))
            XCTAssertTrue(preferences.shortcut(for: .recentTab).key.isEmpty)
            preferences.resetShortcuts()
            XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("swipe"))
            XCTAssertEqual(preferences.shortcut(for: .sidebar), .init("s"))
        }
    }

    func testRecentTabToggleAndPinToggleStayWindowLocal() throws {
        try withApp { app in
            let first = try XCTUnwrap(app.windows.first)
            let original = try XCTUnwrap(first.selectedTab?.id)
            let other = app.newWindow()
            let next = Tab(title: "Second")
            first.record.tabs.append(next); first.select(next.id)
            first.toggleRecentTab(); XCTAssertEqual(first.selectedTab?.id, original)
            first.toggleRecentTab(); XCTAssertEqual(first.selectedTab?.id, next.id)
            XCTAssertNil(other.selectedTab)
            let saved = SavedItem(spaceID: Space.defaultID, title: "Pin")
            app.savedItems.append(saved); first.openSavedItem(saved.id)
            first.togglePinSelected()
            XCTAssertFalse(app.savedItems.contains { $0.id == saved.id })
            XCTAssertNil(first.selectedTab?.savedItemID)
        }
    }

    /// Seed plain records and blank saved destinations; no test navigates to the network.
    private func withApp(_ snapshot: SessionSnapshot? = nil, body: (AppModel) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleAppModelTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let fixture = Tab(title: "Fixture")
        store.save(snapshot ?? SessionSnapshot(windows: [WindowRecord(selectedTabID: fixture.id, tabs: [fixture])])) { XCTAssertNil($0) }
        store.flush()
        let app = AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
        defer {
            app.windows.forEach { $0.closePages() }
            app.flush()
            app.library.close()
        }
        try body(app)
    }

    private func withAppAsync(_ snapshot: SessionSnapshot? = nil, body: (AppModel) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleAppModelTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let fixture = Tab(title: "Fixture")
        store.save(snapshot ?? SessionSnapshot(windows: [WindowRecord(selectedTabID: fixture.id, tabs: [fixture])])) { XCTAssertNil($0) }
        store.flush()
        let app = AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
        defer {
            app.windows.forEach { $0.closePages() }
            app.flush()
            app.library.close()
        }
        try await body(app)
    }

    func testClosedWindowCannotRecreatePageFromDelayedActivation() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            window.activateSelected()
            XCTAssertNotNil(window.selectedPage)
            app.closeWindow(window.id)
            window.activateSelected()
            XCTAssertNil(window.selectedPage)
            window.addressDraft = "https://example.invalid/late"
            window.submitAddress()
            XCTAssertNil(window.selectedPage)
        }
    }

    func testNormalFixturesUseOverrideAndPrivateWindowsKeepSeparateStores() throws {
        try withApp { app in
            let normal = try XCTUnwrap(app.windows.first)
            normal.activateSelected()
            let normalStore = try XCTUnwrap(normal.selectedPage?.webView.configuration.websiteDataStore)
            XCTAssertFalse(normal.isPrivate)
            XCTAssertFalse(normalStore.isPersistent)
            XCTAssertTrue(normalStore === app.websiteDataStoreOverride)
            for isPrivate in [false, true, true] {
                let window = app.newWindow(isPrivate: isPrivate)
                let tab = Tab(title: "Store fixture")
                window.record.tabs.append(tab)
                window.select(tab.id)
                let store = try XCTUnwrap(window.selectedPage?.webView.configuration.websiteDataStore)
                XCTAssertFalse(store.isPersistent)
                XCTAssertEqual(store === normalStore, !isPrivate)
            }
            let privateStores = app.windows.filter(\.isPrivate).compactMap { $0.selectedPage?.webView.configuration.websiteDataStore }
            XCTAssertFalse(privateStores[0] === privateStores[1])
            XCTAssertEqual(app.profiles[0].storeBinding, .legacyDefault)
        }
    }

    func testPrivateVisitCallbacksDoNotEnterNormalHistory() throws {
        try withApp { app in
            let normal = try XCTUnwrap(app.windows.first)
            normal.activateSelected()
            let normalTab = try XCTUnwrap(normal.selectedTab)
            let normalVisit = try XCTUnwrap(normal.selectedPage?.events.onVisit)
            normalVisit(normalTab.id, "https://normal.example/page", "Normal visit")
            let privateWindow = app.newWindow(isPrivate: true)
            let privateTab = Tab(title: "Private fixture")
            privateWindow.record.tabs.append(privateTab)
            privateWindow.select(privateTab.id)
            let privateVisit = try XCTUnwrap(privateWindow.selectedPage?.events.onVisit)
            privateVisit(privateTab.id, "https://private.example/page", "Private visit")
            XCTAssertEqual(app.library.search("", profileID: Profile.defaultID).map(\.urlString), ["https://normal.example/page"])
            XCTAssertNil(app.library.lastError)
        }
    }

    func testClosingWindowDuringBlockerRestorePreventsDeferredActivation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleActivationTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = WebKitContentBlocker(directory: directory)
        await blocker.importRules(json: #"[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}}]"#, profileID: Profile.defaultID)
        XCTAssertNil(blocker.lastError)
        let store = SessionStore(directory: directory)
        let tab = Tab(title: "Deferred fixture")
        store.save(SessionSnapshot(windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])])) { XCTAssertNil($0) }
        store.flush()
        let app = AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
        defer { app.windows.forEach { $0.closePages() }; app.flush(); app.library.close() }
        XCTAssertFalse(app.contentBlocker!.isReady)
        let closed = try XCTUnwrap(app.windows.first)
        closed.activateSelected()
        XCTAssertNil(closed.selectedPage)
        app.closeWindow(closed.id)
        await app.contentBlocker!.waitUntilReady()
        await Task.yield()
        XCTAssertTrue(app.contentBlocker!.isReady)
        XCTAssertNil(closed.selectedPage)
        XCTAssertFalse(app.windows.contains { $0.id == closed.id })
    }

    func testBlankAddressDoesNotActivateAnotherTabBeforeClearingSelection() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let first = Tab(title: "First fixture")
            let second = Tab(title: "Second fixture")
            window.record.tabs = [first, second]
            window.record.selectedTabID = first.id
            window.addressDraft = "about:blank"
            window.submitAddress()
            XCTAssertNil(window.selectedTab)
            XCTAssertEqual(window.record.tabs.map(\.id), [second.id])
            // Mark the remaining record as a saved item to inspect host ownership without loading it.
            let saved = SavedItem(spaceID: Space.defaultID, title: "Second fixture")
            app.savedItems.append(saved)
            window.record.tabs[0].savedItemID = saved.id
            XCTAssertFalse(window.isSavedItemLoaded(saved.id))
        }
    }

    func testClosingAndSpaceSelectionKeepExplicitlyUnloadedPinsDormant() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let item = SavedItem(spaceID: Space.defaultID, title: "Dormant pin")
            app.savedItems.append(item)
            window.openSavedItem(item.id)
            window.unloadSavedItem(item.id)
            let ordinary = Tab(title: "Ordinary fixture")
            window.record.tabs.append(ordinary)
            window.record.selectedTabID = ordinary.id
            window.closeTab(ordinary.id)
            XCTAssertFalse(window.isSavedItemLoaded(item.id))
            window.selectSpace(Space.defaultID)
            XCTAssertFalse(window.isSavedItemLoaded(item.id))
            XCTAssertTrue(window.record.tabs.first(where: { $0.savedItemID == item.id })?.isUnloaded == true)
        }
    }

    func testSpaceSwitchSkipsDormantSavedTabButSelectsOpenOne() throws {
        let work = Space(name: "Work")
        let pin = SavedItem(spaceID: work.id, title: "Saved page")
        let tab = Tab(spaceID: work.id, savedItemID: pin.id)
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], savedItems: [pin],
                                       windows: [WindowRecord(tabs: [tab])])
        try withApp(snapshot) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.selectSpace(work.id)
            XCTAssertNil(window.selectedTab)
            XCTAssertFalse(window.isSavedItemLoaded(pin.id))
            XCTAssertFalse(window.isEditingAddress)
            window.openSavedItem(pin.id)
            XCTAssertTrue(window.isSavedItemLoaded(pin.id))
            window.selectSpace(Space.defaultID)
            window.selectSpace(work.id)
            XCTAssertEqual(window.selectedTab?.id, tab.id)
        }
    }

    func testUnloadingLastSelectedPinKeepsEmptySpaceSelected() throws {
        let work = Space(name: "Work")
        let pin = SavedItem(spaceID: work.id, title: "Saved page")
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], savedItems: [pin])
        try withApp(snapshot) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.selectSpace(work.id)
            window.openSavedItem(pin.id)
            window.unloadSavedItem(pin.id)
            XCTAssertEqual(window.record.selectedSpaceID, work.id)
            XCTAssertNil(window.selectedTab)
            XCTAssertNil(window.selectedPage)
            XCTAssertFalse(window.isEditingAddress)
            window.selectSpace(Space.defaultID)
            window.selectSpace(work.id)
            XCTAssertNil(window.selectedTab)
        }
    }

    func testEscapeRestoresAddressAndTabCycleStartsAtFirstItemWithNoSelection() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            let first = Tab(title: "First fixture")
            let second = Tab(title: "Second fixture")
            window.record.tabs = [first, second]
            window.clearSelection()
            window.cycleTab(offset: 1)
            XCTAssertEqual(window.selectedTab?.id, first.id)
            window.addressDraft = "unsubmitted search"
            window.isEditingAddress = true
            window.addressError = "Invalid input"
            window.cancelAddressEditing()
            XCTAssertEqual(window.addressDraft, first.urlString)
            XCTAssertFalse(window.isEditingAddress)
            XCTAssertNil(window.addressError)
            window.clearSelection()
            window.cycleTab(offset: -1)
            XCTAssertEqual(window.selectedTab?.id, second.id)
        }
    }

    func testEmptyWindowsNewTabActionAndLastCloseDoNotCreatePlaceholders() throws {
        try withApp(SessionSnapshot()) { app in
            let window = try XCTUnwrap(app.windows.first)
            XCTAssertTrue(window.record.tabs.isEmpty)
            window.addTab()
            XCTAssertTrue(window.commandBarPresented)
            window.commandQuery = ""
            window.submitCommand()
            XCTAssertTrue(window.record.tabs.isEmpty)
            XCTAssertNil(window.selectedPage)
            let tab = Tab(urlString: "https://example.invalid/", title: "Page", isUnloaded: true)
            window.record.tabs = [tab]; window.record.selectedTabID = tab.id
            window.closeTab(tab.id)
            XCTAssertTrue(window.record.tabs.isEmpty)
            XCTAssertNil(window.selectedTab)
            XCTAssertNil(window.selectedPage)
            let work = Space(name: "Empty space")
            app.spaces.append(work)
            window.selectSpace(work.id)
            XCTAssertTrue(window.record.tabs.isEmpty)
            XCTAssertNil(window.selectedTab)
            XCTAssertTrue(app.newWindow().record.tabs.isEmpty)
        }
    }

    func testNewTabCommandTogglesCommandOverlay() throws {
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            XCTAssertTrue(window.perform(.newTab))
            XCTAssertTrue(window.commandBarPresented)
            window.commandQuery = "keep this query"
            XCTAssertTrue(window.perform(.newTab))
            XCTAssertFalse(window.commandBarPresented)
            XCTAssertEqual(window.commandQuery, "keep this query")
        }
    }

    func testTwoWindowOrganizationRoundTripPreservesLiveDestinationsAndLazyRestore() throws {
        let work = Space(name: "Work")
        let folder = Folder(spaceID: work.id, name: "Research")
        let pin = SavedItem(spaceID: Space.defaultID, urlString: "http://127.0.0.1:9/home", title: "Shared home")
        let firstTabs = [Tab(title: "First A"), Tab(title: "First B")]
        let secondTabs = [Tab(title: "Second A"), Tab(title: "Second B")]
        let fixture = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], folders: [folder], savedItems: [pin],
            windows: [WindowRecord(selectedTabID: firstTabs[0].id, tabs: firstTabs),
                      WindowRecord(selectedTabID: secondTabs[0].id, tabs: secondTabs)])
        try withApp(fixture) { app in
            let first = app.windows[0], second = app.windows[1]
            first.openSavedItem(pin.id)
            second.openSavedItem(pin.id)
            let firstHost = try XCTUnwrap(first.selectedPage), secondHost = try XCTUnwrap(second.selectedPage)
            XCTAssertFalse(firstHost === secondHost)
            let updatedHome = "http://127.0.0.1:9/new-home"
            let firstCurrent = "http://127.0.0.1:9/first-current"
            let secondCurrent = "http://127.0.0.1:9/second-current"
            firstHost.events.onChange?(firstHost.tabID, updatedHome, "First page")
            XCTAssertEqual(app.savedItems[0].urlString, pin.urlString)
            first.useCurrentURLAsSavedDestination(pin.id)
            XCTAssertEqual(app.savedItems[0].urlString, updatedHome)
            app.undoOrganization()
            XCTAssertEqual(app.savedItems[0].urlString, pin.urlString)
            first.useCurrentURLAsSavedDestination(pin.id)
            firstHost.events.onChange?(firstHost.tabID, firstCurrent, "First later page")
            secondHost.events.onChange?(secondHost.tabID, secondCurrent, "Second page")
            XCTAssertEqual(app.savedItems[0].urlString, updatedHome)
            XCTAssertEqual(app.savedItems[0].title, pin.title)

            app.moveSavedItem(id: pin.id, spaceID: nil, folderID: nil)
            XCTAssertEqual(first.favorites.map(\.id), [pin.id])
            XCTAssertEqual(second.favorites.map(\.id), [pin.id])
            app.moveSavedItem(id: pin.id, spaceID: work.id, folderID: folder.id)
            XCTAssertEqual(first.selectedTab?.spaceID, work.id)
            XCTAssertEqual(second.selectedTab?.spaceID, work.id)
            app.deleteFolder(folder.id)
            XCTAssertNil(app.savedItems[0].folderID)
            app.undoOrganization()
            XCTAssertEqual(app.savedItems[0].folderID, folder.id)
            XCTAssertEqual(app.folders.map(\.id), [folder.id])
            app.deleteFolder(folder.id)
            app.deleteSpace(work.id)
            XCTAssertEqual(app.savedItems[0].spaceID, Space.defaultID)
            app.undoOrganization()
            XCTAssertEqual(app.savedItems[0].spaceID, work.id)
            XCTAssertEqual(first.record.tabs.first { $0.savedItemID == pin.id }?.spaceID, work.id)
            XCTAssertEqual(second.record.tabs.first { $0.savedItemID == pin.id }?.spaceID, work.id)
            app.deleteSpace(work.id)
            first.select(firstHost.tabID)
            first.moveTab(firstTabs[1].id, before: firstTabs[0].id)
            second.select(secondTabs[0].id)
            XCTAssertTrue(first.selectedPage === firstHost)
            XCTAssertTrue(second.isSavedItemLoaded(pin.id))
            XCTAssertEqual(first.visibleTabs.map(\.id), [firstTabs[1].id, firstTabs[0].id])
            XCTAssertEqual(second.visibleTabs.map(\.id), secondTabs.map(\.id))

            let privateWindow = app.newWindow(isPrivate: true)
            privateWindow.record.tabs = [Tab(urlString: "https://private-roundtrip.example/secret", title: "Private canary")]
            let expected = app.snapshot
            XCTAssertEqual(expected.windows.count, 2)
            app.flush()
            XCTAssertNil(app.persistenceMessage)
            let persisted = try XCTUnwrap(app.store.load().snapshot)
            XCTAssertEqual(persisted.windows, expected.windows)
            let encoded = try JSONEncoder().encode(persisted)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-roundtrip.example"))
            // Retire original pages before reconstructing the two independent windows.
            app.windows.forEach { $0.closePages() }
            let restored = AppModel(store: SessionStore(directory: app.store.directory), websiteDataStoreOverride: .nonPersistent())
            defer { restored.windows.forEach { $0.closePages() }; restored.flush(); restored.library.close() }
            XCTAssertEqual(restored.snapshot.windows, expected.windows)
            XCTAssertEqual(restored.savedItems, expected.savedItems)
            XCTAssertEqual(restored.spaces, expected.spaces)
            XCTAssertEqual(restored.folders, expected.folders)
            XCTAssertEqual(restored.savedItems[0].urlString, updatedHome)
            let restoredFirst = try XCTUnwrap(restored.windows.first { $0.id == first.id })
            let restoredSecond = try XCTUnwrap(restored.windows.first { $0.id == second.id })
            XCTAssertEqual(restoredFirst.selectedTab?.urlString, firstCurrent)
            XCTAssertEqual(restoredSecond.record.tabs.first { $0.savedItemID == pin.id }?.urlString, secondCurrent)
            XCTAssertEqual(restoredSecond.selectedTab?.id, secondTabs[0].id)
            XCTAssertTrue(restored.windows.allSatisfy { $0.selectedPage == nil && !$0.isSavedItemLoaded(pin.id) })
            restoredFirst.activateSelected()
            XCTAssertNotNil(restoredFirst.selectedPage)
            XCTAssertTrue(restoredFirst.isSavedItemLoaded(pin.id))
            XCTAssertNil(restoredSecond.selectedPage)
            XCTAssertFalse(restoredSecond.isSavedItemLoaded(pin.id), "The other window's background pin remains lazy")
        }
    }

    func testSavedDestinationChangesPreserveLiveWindowsCustomTitleAndUndo() throws {
        try withApp { app in
            let home = "https://home.example/start", current = "https://current.example/page"
            let item = SavedItem(spaceID: Space.defaultID, urlString: home, title: "My custom pin",
                                 favicon: CachedFavicon(origin: "https://home.example", png: Data([1])))
            app.savedItems.append(item)
            let first = try XCTUnwrap(app.windows.first), second = app.newWindow()
            first.openSavedItem(item.id); second.openSavedItem(item.id)
            let firstHost = try XCTUnwrap(first.selectedPage), secondHost = try XCTUnwrap(second.selectedPage)
            let index = try XCTUnwrap(first.record.tabs.firstIndex(where: { $0.savedItemID == item.id }))
            first.record.tabs[index].urlString = current
            first.record.tabs[index].title = "Site-controlled page title"
            first.record.tabs[index].favicon = item.favicon
            let secondRecord = second.record
            XCTAssertTrue(first.canUseCurrentURLAsSavedDestination(item.id))
            first.useCurrentURLAsSavedDestination(item.id)
            XCTAssertEqual(app.savedItems.first?.urlString, current)
            XCTAssertEqual(app.savedItems.first?.title, "My custom pin")
            XCTAssertNil(app.savedItems.first?.favicon, "The old-origin icon must not follow a new destination")
            XCTAssertTrue(first.selectedPage === firstHost)
            XCTAssertTrue(second.selectedPage === secondHost)
            XCTAssertEqual(second.record, secondRecord)
            XCTAssertEqual(first.selectedTab?.urlString, current)
            XCTAssertFalse(first.canUseCurrentURLAsSavedDestination(item.id))
            app.undoOrganization()
            XCTAssertEqual(app.savedItems.first, item)
            XCTAssertEqual(first.selectedTab?.urlString, current)
            XCTAssertEqual(second.record, secondRecord)

            let privateWindow = app.newWindow(isPrivate: true)
            privateWindow.openSavedItem(item.id)
            let privateIndex = try XCTUnwrap(privateWindow.record.tabs.firstIndex(where: { $0.savedItemID == item.id }))
            privateWindow.record.tabs[privateIndex].urlString = "https://private.example/secret"
            XCTAssertFalse(privateWindow.canUseCurrentURLAsSavedDestination(item.id))
            privateWindow.useCurrentURLAsSavedDestination(item.id)
            XCTAssertEqual(app.savedItems.first, item)
            app.updateSavedDestination(id: item.id, profileID: UUID(), url: URL(string: current)!, favicon: nil)
            app.updateSavedDestination(id: item.id, profileID: Profile.defaultID, url: URL(string: "https://user:password@example.com")!, favicon: nil)
            XCTAssertEqual(app.savedItems.first, item)
        }
    }

    func testResetSavedDestinationKeepsTheLivePageOwnerAndOtherWindow() throws {
        try withApp { app in
            let item = SavedItem(spaceID: Space.defaultID, urlString: "https://home.example/start", title: "Home")
            app.savedItems.append(item)
            let first = try XCTUnwrap(app.windows.first), second = app.newWindow()
            first.openSavedItem(item.id); second.openSavedItem(item.id)
            let firstHost = try XCTUnwrap(first.selectedPage), secondHost = try XCTUnwrap(second.selectedPage)
            let index = try XCTUnwrap(first.record.tabs.firstIndex(where: { $0.savedItemID == item.id }))
            first.record.tabs[index].urlString = "https://elsewhere.example/current"
            let id = first.record.tabs[index].id, secondRecord = second.record
            first.resetSavedDestination(item.id)
            XCTAssertEqual(first.selectedTab?.id, id)
            XCTAssertEqual(first.addressDraft, item.urlString)
            XCTAssertTrue(first.selectedPage === firstHost)
            XCTAssertTrue(second.selectedPage === secondHost)
            XCTAssertEqual(second.record, secondRecord)
            XCTAssertEqual(app.savedItems.first, item)
            XCTAssertFalse(app.canUndoOrganization)
            first.unloadSavedItem(item.id)
            first.record.tabs[index].urlString = "https://stale.example/old"
            first.resetSavedDestination(item.id)
            XCTAssertEqual(first.selectedTab?.id, id)
            XCTAssertEqual(first.selectedTab?.urlString, item.urlString)
            XCTAssertTrue(first.isSavedItemLoaded(item.id))
            XCTAssertEqual(app.savedItems.first, item)
        }
    }

    func testPinnedUnloadIsWindowLocalDurableAndReopensAtSavedDestination() throws {
        try withApp { app in
            let item = SavedItem(spaceID: Space.defaultID, title: "Saved page")
            app.savedItems.append(item)
            let first = try XCTUnwrap(app.windows.first)
            let second = app.newWindow()
            first.openSavedItem(item.id); second.openSavedItem(item.id)
            let secondHost = try XCTUnwrap(second.selectedPage)
            XCTAssertTrue(first.isSavedItemLoaded(item.id))
            first.unloadSavedItem(item.id)
            XCTAssertFalse(first.isSavedItemLoaded(item.id))
            XCTAssertTrue(second.isSavedItemLoaded(item.id))
            XCTAssertTrue(second.selectedPage === secondHost)
            XCTAssertTrue(app.savedItems.contains { $0.id == item.id })
            first.activateSelected()
            XCTAssertNil(first.selectedPage, "Automatic rendering must not undo an explicit unload")
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(app.snapshot))
            let restored = BrowserWindowModel(app: app, record: try XCTUnwrap(snapshot.windows.first { $0.id == first.id }))
            restored.activateSelected()
            XCTAssertNil(restored.selectedPage)
            first.openSavedItem(item.id)
            XCTAssertTrue(first.isSavedItemLoaded(item.id))
            XCTAssertEqual(first.selectedTab?.urlString, item.urlString)
            first.unloadSavedItem(item.id)
            first.removeUnloadedSavedItem(item.id)
            XCTAssertFalse(app.savedItems.contains { $0.id == item.id })
            XCTAssertFalse(first.record.tabs.contains { $0.savedItemID == item.id })
            XCTAssertNil(second.selectedTab?.savedItemID)
            XCTAssertTrue(second.selectedPage === secondHost, "Unpinning must preserve another window's live page")
        }
    }

    func testFaviconsSurviveSnapshotsAndPrivatePagesCannotUpdateSharedIcons() throws {
        try withApp { app in
            let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aEVEAAAAASUVORK5CYII="))
            let pageURL = try XCTUnwrap(URL(string: "https://example.com/page"))
            let item = SavedItem(spaceID: Space.defaultID, urlString: pageURL.absoluteString, title: "Saved")
            app.savedItems.append(item)
            let window = try XCTUnwrap(app.windows.first)
            window.activateSelected()
            let tabID = try XCTUnwrap(window.selectedTab?.id)
            let callback = try XCTUnwrap(window.selectedPage?.events.onFavicon)
            callback(tabID, pageURL, png)
            XCTAssertEqual(app.savedItems.first?.favicon?.png, png)
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(app.snapshot))
            XCTAssertEqual(snapshot.savedItems.first?.favicon?.png, png)
            let second = app.newWindow()
            XCTAssertNotNil(second.icon(for: try XCTUnwrap(app.savedItems.first)), "No page load should be needed for a saved icon")
            XCTAssertNil(app.cachedFavicon(urlString: pageURL.absoluteString, profileID: UUID()))
            let privateWindow = app.newWindow(isPrivate: true)
            let privateTab = Tab(title: "Private fixture")
            privateWindow.record.tabs.append(privateTab)
            privateWindow.select(privateTab.id)
            privateWindow.activateSelected()
            let privateID = try XCTUnwrap(privateWindow.selectedTab?.id)
            privateWindow.selectedPage?.events.onFavicon?(privateID, pageURL, Data([1, 2, 3]))
            XCTAssertEqual(app.savedItems.first?.favicon?.png, png)
            XCTAssertFalse(app.snapshot.windows.contains { $0.id == privateWindow.id })
            window.closePages()
            callback(tabID, pageURL, Data([4, 5, 6]))
            XCTAssertEqual(app.savedItems.first?.favicon?.png, png, "Stale page callbacks must be rejected")
        }
    }

    func testBlankAddressClearsUnloadedDestinationBeforeCreatingPage() throws {
        try withApp { app in
            let tab = Tab(urlString: "https://example.invalid/old-destination", title: "Old page")
            let window = BrowserWindowModel(app: app,
                record: WindowRecord(selectedTabID: tab.id, tabs: [tab]), isPrivate: true)
            defer { window.closePages() }
            XCTAssertNil(window.selectedPage)
            window.addressDraft = "about:blank"
            window.submitAddress()
            XCTAssertNil(window.selectedTab)
            XCTAssertTrue(window.record.tabs.isEmpty)
            XCTAssertEqual(window.addressDraft, "")
            XCTAssertNil(window.selectedPage?.webView.url)
            XCTAssertFalse(window.selectedPage?.isLoading == true)
        }
    }

    func testWindowsKeepIndependentSelectionAndAddressDrafts() throws {
        try withApp { app in
            let first = try XCTUnwrap(app.windows.first)
            let firstTabID = first.record.selectedTabID
            let second = app.newWindow()
            first.addressDraft = "first draft"
            second.addressDraft = "second draft"
            second.record.sidebarVisible = false
            second.record.tabs.append(Tab(title: "Second window extra tab"))
            second.record.selectedTabID = second.record.tabs.last?.id
            XCTAssertEqual(first.record.selectedTabID, firstTabID)
            XCTAssertEqual(first.record.tabs.count, 1)
            XCTAssertEqual(first.addressDraft, "first draft")
            XCTAssertEqual(second.addressDraft, "second draft")
            XCTAssertTrue(first.record.sidebarVisible)
            XCTAssertFalse(second.record.sidebarVisible)
            app.closeWindow(second.id)
            XCTAssertEqual(app.windows.map(\.id), [first.id])
            XCTAssertEqual(first.record.selectedTabID, firstTabID)
        }
    }

    func testRemovingSharedSavedItemDetachesEveryInstanceAndUndoRestoresMembership() throws {
        let item = SavedItem(spaceID: Space.defaultID, urlString: "https://example.com", title: "Example")
        let firstTab = Tab(savedItemID: item.id)
        let secondTab = Tab(savedItemID: item.id)
        let windows = [WindowRecord(selectedTabID: firstTab.id, tabs: [firstTab]), WindowRecord(selectedTabID: secondTab.id, tabs: [secondTab])]
        try withApp(SessionSnapshot(savedItems: [item], windows: windows)) { app in
            app.removeSavedItem(item.id)
            XCTAssertTrue(app.savedItems.isEmpty)
            XCTAssertEqual(app.windows.flatMap { $0.record.tabs }.map(\.id), [firstTab.id, secondTab.id])
            XCTAssertTrue(app.windows.flatMap { $0.record.tabs }.allSatisfy { $0.savedItemID == nil })
            app.undoOrganization()
            XCTAssertEqual(app.savedItems.map(\.id), [item.id])
            XCTAssertEqual(app.windows.flatMap { $0.record.tabs }.map(\.savedItemID), [item.id, item.id])
        }
    }

    func testUndoPinCreationKeepsLiveTabAndRemovesMembership() throws {
        let tab = Tab(urlString: "https://example.com", title: "Example")
        try withApp(SessionSnapshot(windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.pinTab(tab.id)
            XCTAssertEqual(app.savedItems.count, 1)
            XCTAssertEqual(window.record.tabs[0].savedItemID, app.savedItems[0].id)
            app.undoOrganization()
            XCTAssertTrue(app.savedItems.isEmpty)
            XCTAssertNil(window.record.tabs[0].savedItemID)
            XCTAssertEqual(window.record.tabs[0].id, tab.id)
            XCTAssertEqual(window.record.tabs[0].urlString, tab.urlString)
        }
    }

    func testSpaceDeletionAndUndoPreserveFolderPinAndTabMemberships() throws {
        let work = Space(name: "Work")
        let folder = Folder(spaceID: work.id, name: "Research")
        let item = SavedItem(spaceID: work.id, folderID: folder.id, title: "Reference")
        let homeTab = Tab(title: "Home fixture")
        let workTab = Tab(spaceID: work.id, savedItemID: item.id)
        let window = WindowRecord(selectedTabID: homeTab.id, tabs: [homeTab, workTab])
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], folders: [folder], savedItems: [item], windows: [window])
        try withApp(snapshot) { app in
            app.deleteSpace(work.id)
            XCTAssertEqual(app.spaces.map(\.id), [Space.defaultID])
            XCTAssertEqual(app.folders[0].spaceID, Space.defaultID)
            XCTAssertEqual(app.savedItems[0].spaceID, Space.defaultID)
            XCTAssertEqual(app.windows[0].record.tabs[1].spaceID, Space.defaultID)
            XCTAssertEqual(app.windows[0].record.tabs[1].id, workTab.id)
            app.undoOrganization()
            XCTAssertEqual(app.spaces.map(\.id), [Space.defaultID, work.id])
            XCTAssertEqual(app.folders[0].spaceID, work.id)
            XCTAssertEqual(app.savedItems[0].spaceID, work.id)
            XCTAssertEqual(app.savedItems[0].folderID, folder.id)
            XCTAssertEqual(app.windows[0].record.tabs[1].spaceID, work.id)
            XCTAssertEqual(app.windows[0].record.tabs[1].savedItemID, item.id)
        }
    }

    func testSpaceDeletionUndoRestoresPrivateTabPlacementWithoutPersistingIt() throws {
        let work = Space(name: "Work")
        try withApp(SessionSnapshot(spaces: [Space(id: Space.defaultID), work])) { app in
            let window = app.newWindow(isPrivate: true)
            let tab = Tab(spaceID: work.id, urlString: "https://private.example/secret")
            window.record.selectedSpaceID = work.id
            window.record.selectedTabID = tab.id
            window.record.tabs = [tab]

            app.deleteSpace(work.id)
            XCTAssertEqual(window.selectedTab?.spaceID, Space.defaultID)
            app.undoOrganization()
            XCTAssertEqual(window.selectedTab?.spaceID, work.id)
            XCTAssertEqual(window.record.selectedSpaceID, work.id)
            app.flush()
            XCTAssertFalse(String(decoding: try Data(contentsOf: app.store.url), as: UTF8.self)
                .contains("private.example"))
        }
    }

    func testPrivateWindowsNeverEnterSnapshotsOrSavePins() throws {
        try withApp { app in
            let normalIDs = app.snapshot.windows.map(\.id)
            let privateWindow = app.newWindow(isPrivate: true)
            privateWindow.addressDraft = "private query"
            privateWindow.record.tabs.append(Tab(urlString: "https://private.example/secret", title: "Private page"))
            privateWindow.pinTab(privateWindow.record.tabs[0].id)
            XCTAssertTrue(app.savedItems.isEmpty)
            XCTAssertEqual(app.snapshot.windows.map(\.id), normalIDs)
            app.flush()
            let data = try Data(contentsOf: app.store.url)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private.example"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private query"))
            XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: data).windows.map(\.id), normalIDs)
        }
    }

    func testPrivateWindowLifecycleDoesNotRotateSessionBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePrivateSaveTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let first = SessionSnapshot(windows: [WindowRecord(tabs: [Tab(title: "First")])])
        let second = SessionSnapshot(windows: [WindowRecord(tabs: [Tab(title: "Second")])])
        let firstError = await store.save(first), secondError = await store.save(second)
        XCTAssertNil(firstError); XCTAssertNil(secondError)
        let app = AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
        defer { app.windows.forEach { $0.closePages() }; app.library.close() }
        let primary = try Data(contentsOf: store.url), backup = try Data(contentsOf: store.backupURL)

        let privateWindow = app.newWindow(isPrivate: true)
        try await Task.sleep(for: .milliseconds(300)); store.flush()
        XCTAssertEqual(try Data(contentsOf: store.url), primary)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)

        app.closeWindow(privateWindow.id)
        try await Task.sleep(for: .milliseconds(300)); store.flush()
        XCTAssertEqual(try Data(contentsOf: store.url), primary)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
    }

    func testDeletingLastSpaceIsIgnored() throws {
        try withApp { app in
            app.deleteSpace(Space.defaultID)
            XCTAssertEqual(app.spaces.map(\.id), [Space.defaultID])
            XCTAssertFalse(app.canUndoOrganization)
        }
    }

    func testDistantTemporaryTabMovePreservesIntermediateOrder() throws {
        let tabs = (1...4).map { Tab(title: "Tab \($0)") }
        try withApp(SessionSnapshot(windows: [WindowRecord(selectedTabID: tabs[0].id, tabs: tabs)])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.moveTab(tabs[0].id, offset: 3)
            XCTAssertEqual(window.visibleTabs.map(\.id), [tabs[1].id, tabs[2].id, tabs[3].id, tabs[0].id])
            XCTAssertEqual(window.record.selectedTabID, tabs[0].id)
            window.moveTab(tabs[0].id, offset: -3)
            XCTAssertEqual(window.visibleTabs.map(\.id), tabs.map(\.id))
        }
    }

    func testDistantSavedItemAndSpaceMovesPreserveIntermediateOrder() throws {
        let pins = (1...4).map { SavedItem(spaceID: Space.defaultID, title: "Pin \($0)") }
        let favorite = SavedItem(title: "Favorite")
        let spaces = [Space(id: Space.defaultID), Space(name: "Work"), Space(name: "Research"), Space(name: "Personal")]
        try withApp(SessionSnapshot(spaces: spaces, savedItems: [pins[0], favorite, pins[1], pins[2], pins[3]])) { app in
            app.moveSavedItem(id: pins[0].id, offset: 3)
            XCTAssertEqual(app.savedItems.filter { $0.spaceID == Space.defaultID }.map(\.id),
                           [pins[1].id, pins[2].id, pins[3].id, pins[0].id])
            XCTAssertEqual(app.savedItems.filter { $0.spaceID == nil }.map(\.id), [favorite.id])
            app.moveSpace(id: spaces[0].id, offset: 3)
            XCTAssertEqual(app.spaces.map(\.id), [spaces[1].id, spaces[2].id, spaces[3].id, spaces[0].id])
            app.moveSpace(id: spaces[0].id, before: spaces[2].id)
            XCTAssertEqual(app.spaces.map(\.id), [spaces[1].id, spaces[0].id, spaces[2].id, spaces[3].id])
            app.moveSpace(id: spaces[0].id, before: spaces[0].id)
            app.moveSpace(id: spaces[0].id, before: spaces[2].id)
            XCTAssertEqual(app.spaces.map(\.id), [spaces[1].id, spaces[0].id, spaces[2].id, spaces[3].id])
            XCTAssertTrue(app.canUndoOrganization)
        }
    }

    func testSpaceReorderSkipsOtherProfilesAndUndoRestoresOrder() throws {
        let work = Profile(name: "Work", storeBinding: .named(UUID()))
        let home = Space(id: Space.defaultID)
        let research = Space(name: "Research")
        let other = Space(profileID: work.id, name: "Work")
        let personal = Space(name: "Personal")
        try withApp(SessionSnapshot(profiles: [Profile(id: Profile.defaultID), work],
                                   spaces: [home, research, other, personal])) { app in
            app.moveSpace(id: home.id, offset: 1)
            XCTAssertEqual(app.spaces.map(\.id), [research.id, other.id, home.id, personal.id])
            app.moveSpace(id: home.id, before: nil)
            XCTAssertEqual(app.spaces.map(\.id), [research.id, other.id, personal.id, home.id])
            app.moveSpace(id: home.id, before: other.id)
            XCTAssertEqual(app.spaces.map(\.id), [research.id, other.id, personal.id, home.id])
            app.undoOrganization()
            XCTAssertEqual(app.spaces.map(\.id), [research.id, other.id, home.id, personal.id])
            app.undoOrganization()
            XCTAssertEqual(app.spaces.map(\.id), [home.id, research.id, other.id, personal.id])
        }
    }

    func testUndoTemporaryTabReorderRestoresOrderAndSelection() throws {
        let tabs = (1...4).map { Tab(title: "Tab \($0)") }
        try withApp(SessionSnapshot(windows: [WindowRecord(selectedTabID: tabs[2].id, tabs: tabs)])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.moveTab(tabs[0].id, offset: 3)
            XCTAssertTrue(app.canUndoOrganization)
            app.undoOrganization()
            XCTAssertEqual(window.record.tabs.map(\.id), tabs.map(\.id))
            XCTAssertEqual(window.record.selectedTabID, tabs[2].id)
            XCTAssertEqual(window.record.selectedSpaceID, Space.defaultID)
            XCTAssertFalse(app.canUndoOrganization)
        }
    }

    func testRemovingSelectedFavoriteKeepsItsPageVisibleInCurrentSpace() throws {
        let work = Space(name: "Work")
        let favorite = SavedItem(title: "Shared Favorite")
        let tab = Tab(title: "Favorite page", savedItemID: favorite.id)
        let record = WindowRecord(selectedSpaceID: work.id, selectedTabID: tab.id, tabs: [tab])
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], savedItems: [favorite], windows: [record])
        try withApp(snapshot) { app in
            let window = try XCTUnwrap(app.windows.first)
            XCTAssertEqual(window.record.selectedSpaceID, work.id)
            XCTAssertEqual(window.selectedTab?.spaceID, Space.defaultID)
            app.removeSavedItem(favorite.id)
            XCTAssertEqual(window.record.selectedSpaceID, work.id)
            XCTAssertEqual(window.selectedTab?.id, tab.id)
            XCTAssertEqual(window.selectedTab?.spaceID, work.id)
            XCTAssertNil(window.selectedTab?.savedItemID)
            XCTAssertEqual(window.visibleTabs.map(\.id), [tab.id])
            XCTAssertEqual(window.selectedTab?.title, tab.title)
        }
    }

    func testUndoSelectedPinMoveRestoresMatchingSpaceAndSelection() throws {
        let work = Space(name: "Work")
        let pin = SavedItem(spaceID: Space.defaultID, title: "Pinned page")
        let tab = Tab(savedItemID: pin.id)
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], savedItems: [pin],
                                       windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])])
        try withApp(snapshot) { app in
            let window = try XCTUnwrap(app.windows.first)
            app.moveSavedItem(id: pin.id, spaceID: work.id, folderID: nil)
            XCTAssertEqual(window.record.selectedSpaceID, work.id)
            XCTAssertEqual(window.selectedTab?.spaceID, work.id)
            app.undoOrganization()
            XCTAssertEqual(window.selectedTab?.id, tab.id)
            XCTAssertEqual(window.record.selectedSpaceID, Space.defaultID)
            XCTAssertEqual(window.selectedTab?.spaceID, Space.defaultID)
            XCTAssertEqual(window.pins.map(\.id), [pin.id])
        }
    }

    func testReopeningClosedPinUsesItsNewSavedSpace() throws {
        let work = Space(name: "Work")
        let pin = SavedItem(spaceID: Space.defaultID, title: "Pinned page")
        let selected = Tab(title: "Selected fixture")
        let pinned = Tab(savedItemID: pin.id)
        let snapshot = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], savedItems: [pin],
                                       windows: [WindowRecord(selectedTabID: selected.id, tabs: [selected, pinned])])
        try withApp(snapshot) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.closeTab(pinned.id)
            app.moveSavedItem(id: pin.id, spaceID: work.id, folderID: nil)
            window.reopenClosedTab()
            XCTAssertEqual(window.selectedTab?.id, pinned.id)
            XCTAssertEqual(window.selectedTab?.savedItemID, pin.id)
            XCTAssertEqual(window.selectedTab?.spaceID, work.id)
            XCTAssertEqual(window.record.selectedSpaceID, work.id)
            XCTAssertEqual(window.selectedTab?.urlString, "")
        }
    }

    func testFutureWorkspaceIsRejectedWithoutChangingLiveState() throws {
        try withApp { app in
            let before = app.snapshot
            let originalWindow = try XCTUnwrap(app.windows.first)
            var replacements = 0
            app.onReplaceWindows = { replacements += 1 }
            var future = SessionSnapshot()
            future.version = SessionSnapshot.currentVersion + 1
            XCTAssertThrowsError(try app.replaceWorkspace(with: future))
            XCTAssertTrue(app.windows[0] === originalWindow)
            XCTAssertEqual(app.snapshot.profiles, before.profiles)
            XCTAssertEqual(app.snapshot.spaces, before.spaces)
            XCTAssertEqual(app.snapshot.windows, before.windows)
            XCTAssertEqual(replacements, 0)
        }
    }

    func testWorkspaceWithPendingDeletionIsRejectedBeforeReplacingLiveWindows() throws {
        let profile = Profile(name: "Deleting", storeBinding: .named(UUID()))
        let space = Space(profileID: profile.id)
        let tab = Tab(spaceID: space.id, urlString: "https://example.com/private-profile")
        let incoming = SessionSnapshot(
            profiles: [Profile(id: Profile.defaultID), profile],
            spaces: [Space(id: Space.defaultID), space],
            windows: [WindowRecord(profileID: profile.id, selectedSpaceID: space.id,
                                   selectedTabID: tab.id, tabs: [tab])],
            pendingProfileDeletions: [PendingProfileDeletion(profileID: profile.id, requiredEngineIDs: [.webKit])])
        try withApp { app in
            let original = try XCTUnwrap(app.windows.first)
            let onDisk = try Data(contentsOf: app.store.url)
            XCTAssertThrowsError(try app.replaceWorkspace(with: incoming))
            XCTAssertTrue(app.windows.first === original)
            XCTAssertFalse(app.profiles.contains { $0.id == profile.id })
            XCTAssertEqual(try Data(contentsOf: app.store.url), onDisk)
        }
    }

    func testWorkspaceExportRefusesPendingDeletion() throws {
        let profile = Profile(name: "Deleting", storeBinding: .named(UUID()))
        let pending = SessionSnapshot(
            profiles: [Profile(id: Profile.defaultID), profile],
            spaces: [Space(id: Space.defaultID), Space(profileID: profile.id)],
            pendingProfileDeletions: [PendingProfileDeletion(profileID: profile.id, requiredEngineIDs: [.webKit])])
        try withApp(pending) { app in
            XCTAssertThrowsError(try app.workspaceExportSnapshot())
            XCTAssertNotNil(app.snapshot.pendingProfileDeletions)
        }
    }

    func testWorkspaceReplacementPreservesImportedIdentitiesAndClearsUndo() throws {
        let work = Space(name: "Imported work")
        let firstTab = Tab(title: "Imported home")
        let secondTab = Tab(spaceID: work.id, title: "Imported work")
        let records = [WindowRecord(selectedTabID: firstTab.id, tabs: [firstTab]),
                       WindowRecord(selectedSpaceID: work.id, selectedTabID: secondTab.id, tabs: [secondTab])]
        let incoming = SessionSnapshot(spaces: [Space(id: Space.defaultID), work], windows: records)
        try withApp { app in
            let originalWindow = try XCTUnwrap(app.windows.first)
            app.addSpace(name: "Pending undo", profileID: Profile.defaultID)
            XCTAssertTrue(app.canUndoOrganization)
            var replacements = 0
            app.onReplaceWindows = {
                replacements += 1
                let persisted = try? Data(contentsOf: app.store.url)
                let decoded = persisted.flatMap { try? JSONDecoder().decode(SessionSnapshot.self, from: $0) }
                XCTAssertEqual(decoded?.windows.map(\.id), records.map(\.id))
            }
            defer { app.onReplaceWindows = nil }
            try app.replaceWorkspace(with: incoming)
            XCTAssertFalse(app.windows.contains { $0 === originalWindow })
            XCTAssertEqual(app.profiles.map(\.id), [Profile.defaultID])
            XCTAssertEqual(app.profiles[0].storeBinding, .legacyDefault)
            XCTAssertEqual(app.spaces.map(\.id), [Space.defaultID, work.id])
            XCTAssertEqual(app.windows.map(\.record), records)
            XCTAssertEqual(app.windows.flatMap { $0.record.tabs }.map(\.id), [firstTab.id, secondTab.id])
            XCTAssertFalse(app.canUndoOrganization)
            XCTAssertEqual(replacements, 1)
        }
    }

    func testWorkspaceReplacementPreservesPendingDeletionMarker() throws {
        let oldProfile = Profile(name: "Old", storeBinding: .named(UUID()))
        let oldSpace = Space(profileID: oldProfile.id)
        let chromium = EngineID(rawValue: "chromium")
        let seeded = SessionSnapshot(
            profiles: [Profile(id: Profile.defaultID), oldProfile],
            spaces: [Space(id: Space.defaultID), oldSpace],
            pendingProfileDeletions: [
                PendingProfileDeletion(profileID: oldProfile.id, requiredEngineIDs: [chromium])
            ],
            profileEngineUsage: [
                ProfileEngineUsage(profileID: oldProfile.id, engineIDs: [.webKit, chromium])
            ])
        try withApp(seeded) { app in
            XCTAssertEqual(Set(app.snapshot.profileEngineUsage?.first { $0.profileID == oldProfile.id }?.engineIDs ?? []),
                           [.webKit, chromium])
            XCTAssertEqual(Set(app.snapshot.pendingProfileDeletions?.first { $0.profileID == oldProfile.id }?.requiredEngineIDs ?? []),
                           [chromium])
            let live = try XCTUnwrap(app.createProfile(name: "Live"))
            _ = try app.engines.context(engineID: .webKit, profile: live, siteSettings: app.siteSettings)
            XCTAssertEqual(Set(app.snapshot.profileEngineUsage?.first { $0.profileID == live.id }?.engineIDs ?? []), [.webKit])
            XCTAssertThrowsError(try app.replaceWorkspace(with: SessionSnapshot()))
            XCTAssertEqual(Set(app.snapshot.profileEngineUsage?.first { $0.profileID == oldProfile.id }?.engineIDs ?? []),
                           [.webKit, chromium])
            XCTAssertEqual(Set(app.snapshot.profileEngineUsage?.first { $0.profileID == live.id }?.engineIDs ?? []), [.webKit])
            XCTAssertEqual(app.snapshot.pendingProfileDeletions?.first?.profileID, oldProfile.id)
        }
    }

    func testTabCyclingWrapsWithinSpaceAndIncludesGlobalFavorites() throws {
        let work = Space(name: "Other space")
        let favorite = SavedItem(title: "Global favorite")
        let first = Tab(title: "First")
        let other = Tab(spaceID: work.id, title: "Other space ordinary tab")
        let second = Tab(title: "Second")
        let favoriteTab = Tab(spaceID: work.id, title: "Favorite", savedItemID: favorite.id)
        let record = WindowRecord(selectedTabID: first.id, tabs: [first, other, second, favoriteTab])
        try withApp(SessionSnapshot(spaces: [Space(id: Space.defaultID), work], savedItems: [favorite], windows: [record])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.cycleTab(offset: 1)
            XCTAssertEqual(window.record.selectedTabID, second.id)
            window.cycleTab(offset: 1)
            XCTAssertEqual(window.record.selectedTabID, favoriteTab.id)
            XCTAssertEqual(window.record.selectedSpaceID, Space.defaultID)
            window.cycleTab(offset: 1)
            XCTAssertEqual(window.record.selectedTabID, first.id)
            window.cycleTab(offset: -1)
            XCTAssertEqual(window.record.selectedTabID, favoriteTab.id)
            XCTAssertEqual(window.record.selectedSpaceID, Space.defaultID)
            XCTAssertNotEqual(window.record.selectedTabID, other.id)
        }
    }

    func testMoveSavedItemInsertsBeforeSiblingInsideFolder() throws {
        let folder = Folder(name: "Notes")
        let first = SavedItem(spaceID: Space.defaultID, folderID: folder.id, title: "A")
        let second = SavedItem(spaceID: Space.defaultID, folderID: folder.id, title: "B")
        let root = SavedItem(spaceID: Space.defaultID, title: "Root")
        try withApp(SessionSnapshot(folders: [folder], savedItems: [root, first, second])) { app in
            app.moveSavedItem(id: root.id, spaceID: Space.defaultID, folderID: folder.id, before: second.id)
            XCTAssertEqual(app.savedItems.filter { $0.folderID == folder.id }.map(\.id), [first.id, root.id, second.id])
            XCTAssertEqual(app.savedItems.first { $0.id == root.id }?.spaceID, Space.defaultID)
            XCTAssertEqual(app.savedItems.first { $0.id == root.id }?.folderID, folder.id)
        }
    }

    func testPinTabIntoFolderCreatesSavedItemInThatFolder() throws {
        let folder = Folder(name: "Notes")
        let tab = Tab(urlString: "https://example.com", title: "Example")
        try withApp(SessionSnapshot(folders: [folder], windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.pinTab(tab.id, folderID: folder.id)
            XCTAssertEqual(app.savedItems.count, 1)
            XCTAssertEqual(app.savedItems[0].folderID, folder.id)
            XCTAssertEqual(window.record.tabs[0].savedItemID, app.savedItems[0].id)
            XCTAssertTrue(window.visibleTabs.isEmpty)
        }
    }

    func testPinTabRejectsStaleDeletedAndWrongSpaceFolders() throws {
        let deleted = Folder(name: "Deleted")
        let work = Space(name: "Work")
        let wrongSpace = Folder(spaceID: work.id, name: "Wrong Space")
        let tab = Tab(urlString: "https://example.com", title: "Example")
        try withApp(SessionSnapshot(spaces: [Space(id: Space.defaultID), work], folders: [deleted, wrongSpace],
                                    windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            app.deleteFolder(deleted.id)
            for folderID in [UUID(), deleted.id, wrongSpace.id] {
                window.pinTab(tab.id, folderID: folderID)
                XCTAssertTrue(app.savedItems.isEmpty)
                XCTAssertNil(window.record.tabs.first?.savedItemID)
            }
        }
    }

    func testMoveFolderReordersAndMovesChildrenToAnotherSpace() throws {
        let work = Space(name: "Work")
        let first = Folder(name: "First")
        let second = Folder(name: "Second")
        let pin = SavedItem(spaceID: Space.defaultID, folderID: first.id, title: "Pin")
        try withApp(SessionSnapshot(spaces: [Space(id: Space.defaultID), work], folders: [first, second], savedItems: [pin])) { app in
            app.moveFolder(id: second.id, before: first.id)
            XCTAssertEqual(app.folders.map(\.id), [second.id, first.id])
            app.moveFolder(id: first.id, spaceID: work.id)
            XCTAssertEqual(app.folders.first { $0.id == first.id }?.spaceID, work.id)
            XCTAssertEqual(app.savedItems[0].spaceID, work.id)
            XCTAssertEqual(app.savedItems[0].folderID, first.id)
        }
    }

    func testNestedFolderMoveDeleteAndUndoPreserveSharedOrganization() throws {
        let work = Space(name: "Work")
        let root = Folder(name: "Root")
        let child = Folder(parentID: root.id, name: "Child")
        let grandchild = Folder(parentID: child.id, name: "Grandchild")
        let childPin = SavedItem(spaceID: Space.defaultID, folderID: child.id, title: "Child pin")
        let grandchildPin = SavedItem(spaceID: Space.defaultID, folderID: grandchild.id, title: "Grandchild pin")
        let tab = Tab(title: "Saved", savedItemID: grandchildPin.id)
        try withApp(SessionSnapshot(spaces: [Space(id: Space.defaultID), work],
                                    folders: [root, child, grandchild], savedItems: [childPin, grandchildPin],
                                    windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])])) { app in
            XCTAssertFalse(app.moveFolder(id: root.id, parentID: grandchild.id))
            XCTAssertEqual(app.folders.first { $0.id == root.id }?.parentID, nil)

            XCTAssertTrue(app.moveFolder(id: root.id, spaceID: work.id))
            XCTAssertEqual(Set(app.folders.map(\.spaceID)), [work.id])
            XCTAssertEqual(Set(app.savedItems.compactMap(\.spaceID)), [work.id])
            XCTAssertEqual(app.windows[0].selectedTab?.spaceID, work.id)

            app.deleteFolder(child.id)
            XCTAssertEqual(app.folders.first { $0.id == grandchild.id }?.parentID, root.id)
            XCTAssertEqual(app.savedItems.first { $0.id == childPin.id }?.folderID, root.id)
            XCTAssertEqual(app.savedItems.first { $0.id == grandchildPin.id }?.folderID, grandchild.id)
            app.undoOrganization()
            XCTAssertEqual(app.folders.first { $0.id == child.id }?.parentID, root.id)
            XCTAssertEqual(app.folders.first { $0.id == grandchild.id }?.parentID, child.id)
            XCTAssertEqual(app.savedItems.first { $0.id == childPin.id }?.folderID, child.id)
        }
    }

    func testMoveTabBeforeSiblingReordersVisibleTabs() throws {
        let tabs = (1...4).map { Tab(title: "Tab \($0)") }
        try withApp(SessionSnapshot(windows: [WindowRecord(selectedTabID: tabs[0].id, tabs: tabs)])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.moveTab(tabs[0].id, before: tabs[2].id)
            XCTAssertEqual(window.visibleTabs.map(\.id), [tabs[1].id, tabs[0].id, tabs[2].id, tabs[3].id])
            window.moveTab(tabs[1].id, before: nil)
            XCTAssertEqual(window.visibleTabs.map(\.id), [tabs[0].id, tabs[2].id, tabs[3].id, tabs[1].id])
        }
    }

    func testUnpinSavedItemTurnsPinIntoTemporaryTabAtIndex() throws {
        let item = SavedItem(spaceID: Space.defaultID, urlString: "https://example.com", title: "Pinned")
        let other = Tab(title: "Temp")
        let pinned = Tab(urlString: item.urlString, title: item.title, savedItemID: item.id)
        try withApp(SessionSnapshot(savedItems: [item], windows: [WindowRecord(selectedTabID: pinned.id, tabs: [other, pinned])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.unpinSavedItem(item.id, before: other.id)
            XCTAssertTrue(app.savedItems.isEmpty)
            XCTAssertNil(window.record.tabs.first { $0.id == pinned.id }?.savedItemID)
            XCTAssertEqual(window.visibleTabs.map(\.id), [pinned.id, other.id])
            XCTAssertEqual(window.record.tabs.first { $0.id == pinned.id }?.spaceID, Space.defaultID)
        }
    }

    func testRedactedDiagnosticsOmitsPageURLsAndIncludesEngineNames() throws {
        let canary = "https://redaction-canary.example/secret-token-xyz"
        try withApp { app in
            let window = try XCTUnwrap(app.windows.first)
            window.record.tabs[0].urlString = canary
            window.record.tabs[0].title = "Secret Title"
            app.persistenceMessage = "disk full"
            let report = app.redactedDiagnostics()
            XCTAssertEqual(report.registeredEngineNames, ["WebKit"])
            XCTAssertEqual(report.defaultEngineID, EngineID.webKit.rawValue)
            XCTAssertEqual(report.dataDirectory, app.store.directory.path)
            XCTAssertEqual(report.lastPersistenceError, "disk full")
            XCTAssertEqual(report.cobbleTesting, ProcessInfo.processInfo.environment["COBBLE_TESTING"] != nil)
            XCTAssertEqual(report.cobbleDataDirectorySet, ProcessInfo.processInfo.environment["COBBLE_DATA_DIRECTORY"] != nil)
            let json = String(decoding: try app.redactedDiagnosticsJSON(), as: UTF8.self)
            XCTAssertFalse(json.contains(canary))
            XCTAssertFalse(json.contains("secret-token-xyz"))
            XCTAssertFalse(json.contains("Secret Title"))
            XCTAssertTrue(json.contains("WebKit"))
            XCTAssertTrue(json.contains("webkit"))
            XCTAssertTrue(json.contains("disk full"))
        }
    }
}
