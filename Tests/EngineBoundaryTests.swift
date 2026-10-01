import AppKit
import XCTest
import SQLite3
@testable import Cobble

@MainActor final class EngineBoundaryTests: XCTestCase {
    private let secondID = EngineID(rawValue: "test.secondary")
    private let thirdID = EngineID(rawValue: "test.third")
    private let destination = URL(string: "https://figma.com/design")!

    func testFullFastFullKeepsWorkspaceAndRequestedEngines() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chromium = EngineID(rawValue: "chromium")
        let url = URL(string: "http://127.0.0.1:9/work")!
        var app = AppModel(store: SessionStore(directory: directory),
                           engines: EngineRegistry([TestEngine(.webKit), TestEngine(chromium)]))
        app.preferences.setDefaultEngine(chromium)
        app.preferences.setEngineRule(for: url, engineID: chromium)
        let window = try XCTUnwrap(app.windows.first)
        window.addTab(url: url)
        let tabID = try XCTUnwrap(window.selectedTab?.id)
        window.record.tabs[0].engineOverride = chromium
        let spaceIDs = app.spaces.map(\.id)
        let windowID = window.id
        app.newWindow(isPrivate: true, url: url)
        app.flush()
        app.windows.forEach { $0.closePages() }
        await app.engines.shutdown()

        app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        let fast = try XCTUnwrap(app.windows.first)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(fast.id, windowID)
        XCTAssertEqual(app.spaces.map(\.id), spaceIDs)
        XCTAssertEqual(fast.selectedTab?.id, tabID)
        fast.activateSelected()
        XCTAssertEqual(fast.selectedPage?.contextID.engineID, .webKit)
        XCTAssertEqual(fast.selectedTab?.engineID, chromium)
        XCTAssertEqual(fast.selectedTab?.engineOverride, chromium)
        XCTAssertEqual(app.preferences.defaultEngine, chromium)
        XCTAssertEqual(app.preferences.engineRules.first?.engineID, chromium)
        let parent = try XCTUnwrap(fast.selectedPage)
        let popup = TestPage(tabID: UUID(), contextID: parent.contextID)
        XCTAssertTrue(parent.events.onCreatePage?(popup, true) == true)
        XCTAssertEqual(fast.selectedTab?.engineID, chromium)
        XCTAssertEqual(fast.selectedTab?.engineOverride, chromium)
        popup.navigate(to: url)
        fast.select(tabID)
        fast.confirmEngineSwitch = { _ in XCTFail("Fallback must not prompt for an engine switch"); return false }
        fast.addressDraft = "http://127.0.0.1:9/next"
        fast.submitAddress()
        XCTAssertEqual(fast.selectedPage?.state.urlString, "http://127.0.0.1:9/next")
        fast.addTab(url: url)
        XCTAssertEqual(fast.selectedTab?.engineID, chromium)
        XCTAssertEqual(fast.selectedPage?.contextID.engineID, .webKit)
        // Routing from an explicit WebKit choice back to a Chromium site rule
        // changes the saved choice without replacing the effective WebKit page.
        fast.setEngine(.webKit, for: fast.selectedTab!.id)
        XCTAssertEqual(fast.selectedTab?.engineID, .webKit)
        fast.setEngine(nil, for: fast.selectedTab!.id)
        XCTAssertEqual(fast.selectedTab?.engineID, chromium)
        XCTAssertNil(fast.selectedTab?.engineOverride)
        let page = try XCTUnwrap(fast.selectedPage as? TestPage)
        let webKitURL = URL(string: "http://localhost:9/webkit")!
        app.preferences.setEngineRule(for: webKitURL, engineID: .webKit)
        fast.addressDraft = webKitURL.absoluteString
        fast.submitAddress()
        XCTAssertEqual(fast.selectedTab?.engineID, .webKit)
        XCTAssertTrue(fast.selectedPage === page)
        let loads = page.loadedURLs.count
        fast.submitAddress()
        XCTAssertEqual(page.loadedURLs.count, loads + 1)
        fast.addressDraft = url.absoluteString
        fast.submitAddress()
        XCTAssertEqual(fast.selectedTab?.engineID, chromium)
        app.flush()
        let saved = app.snapshot
        app.windows.forEach { $0.closePages() }
        await app.engines.shutdown()

        app = AppModel(store: SessionStore(directory: directory),
                       engines: EngineRegistry([TestEngine(.webKit), TestEngine(chromium)]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(app.snapshot), try encoder.encode(saved))
        let full = try XCTUnwrap(app.windows.first)
        full.activateSelected()
        XCTAssertEqual(full.selectedPage?.contextID.engineID, chromium)
        XCTAssertEqual(app.preferences.defaultEngine, chromium)
        app.windows.forEach { $0.closePages() }
        await app.engines.shutdown()
        app.library.close()
    }

    func testWorkspaceLockRejectsSecondWriterAndReleasesOnClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: WorkspaceLock? = try WorkspaceLock(directory: directory)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try WorkspaceLock(directory: directory))
        }
        first = nil
        let next = try WorkspaceLock(directory: directory)
        try withExtendedLifetime(next) {
            XCTAssertThrowsError(try WorkspaceLock(directory: directory))
        }
    }

    private func withApp(_ body: (AppModel, [TestEngine]) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleEngineTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engines = [TestEngine(.webKit), TestEngine(secondID), TestEngine(thirdID)]
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry(engines))
        do { try await body(app, engines) }
        catch {
            app.windows.forEach { $0.closePages() }; await app.engines.shutdown(); app.flush(); app.library.close()
            throw error
        }
        app.windows.forEach { $0.closePages() }; await app.engines.shutdown(); app.flush(); app.library.close()
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out", file: file, line: line)
        throw EngineError.notReady("Timed out")
    }

    func testFailedProvisionalLocalFileTabRollsBackSelectionAndBookmark() async throws {
        try await withApp { app, engines in
            let window = try XCTUnwrap(app.windows.first)
            window.record.tabs.removeAll()
            window.clearSelection()
            engines[0].capabilities.pageOperations.insert(.localFile)
            engines[0].localFileFailure = true
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleLocalRollback-\(UUID()).html")
            try "<title>Candidate</title>".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }

            do {
                try await window.acceptLocalFile(file)
                XCTFail("Expected the provisional local-file load to fail")
            } catch {}

            XCTAssertTrue(window.record.tabs.isEmpty)
            XCTAssertNil(window.selectedTab)
            XCTAssertNil(window.selectedPage)
            XCTAssertTrue(app.snapshot.windows.first?.tabs.isEmpty == true)
        }
    }

    func testPrivateLocalFileDuplicateRetainsEphemeralAuthorization() async throws {
        try await withApp { app, _ in
            let window = app.newWindow(isPrivate: true)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePrivateDuplicate-\(UUID()).html")
            try "<title>Private</title>".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }

            try await window.acceptLocalFile(file)
            let original = try XCTUnwrap(window.selectedTab?.id)
            window.duplicateTab(original)
            let duplicate = try XCTUnwrap(window.selectedTab)

            XCTAssertNotEqual(duplicate.id, original)
            XCTAssertNil(duplicate.localFileBookmark)
            XCTAssertNotNil(window.privateLocalFileBookmarks[original])
            XCTAssertNotNil(window.privateLocalFileBookmarks[duplicate.id])
            try await eventually {
                window.selectedPage?.state.urlString.isEmpty == false || window.selectedPage?.state.errorMessage != nil
            }
            XCTAssertNil(window.selectedPage?.state.errorMessage)
            let loaded = try XCTUnwrap(URL(string: window.selectedPage?.state.urlString ?? ""))
            XCTAssertEqual(loaded.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
            window.closeTab(duplicate.id)
            XCTAssertNil(window.privateLocalFileBookmarks[duplicate.id])
            XCTAssertNotNil(window.privateLocalFileBookmarks[original])
        }
    }

    func testLocalFileTabsKeepTheirLoadURLOutsideWebAddressValidation() {
        let file = URL(fileURLWithPath: "/tmp/CobbleLocalReopen.html")
        XCTAssertEqual(BrowserWindowModel.loadURL(for: Tab(urlString: file.absoluteString)), file)
    }

    func testProfileDeletionDoesNotWaitForAnotherProfilesClosingContext() async throws {
        try await withApp { app, engines in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let work = try XCTUnwrap(app.newWindow(url: self.destination, profileID: profile.id))
            work.activateSelected()
            XCTAssertNotNil(work.selectedPage)

            engines[0].delayClosure = true
            let privateWindow = app.newWindow(isPrivate: true, url: self.destination)
            privateWindow.activateSelected()
            let privatePage = try XCTUnwrap(privateWindow.selectedPage as? TestPage)
            app.closeWindow(privateWindow.id)
            try await eventually { privatePage.closure != nil }

            let deletion = Task { await app.deleteProfile(profile.id) }
            try await eventually { !app.profiles.contains(where: { $0.id == profile.id }) }
            let deletionResult = await deletion.value
            XCTAssertNil(deletionResult)

            privatePage.finishClosure()
        }
    }

    func testProfileDeletionWaitsForItsOwnPreviouslyClosingContext() async throws {
        try await withApp { app, engines in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            engines[0].delayClosure = true
            let privateWindow = try XCTUnwrap(app.newWindow(isPrivate: true, url: self.destination, profileID: profile.id))
            privateWindow.activateSelected()
            let page = try XCTUnwrap(privateWindow.selectedPage as? TestPage)
            app.closeWindow(privateWindow.id)
            try await eventually { page.closure != nil }

            let deletion = Task { await app.deleteProfile(profile.id) }
            await Task.yield()
            XCTAssertTrue(app.profiles.contains { $0.id == profile.id })

            page.finishClosure()
            let deletionResult = await deletion.value
            XCTAssertNil(deletionResult)
            XCTAssertFalse(app.profiles.contains { $0.id == profile.id })
        }
    }

    func testLocalFileBookmarkWaitsForEngineCommit() async throws {
        try await withApp { app, engines in
            let window = try XCTUnwrap(app.windows.first)
            engines[0].delayLocalFile = true
            window.addTab(url: URL(string: "https://before.example")!)
            let tab = try XCTUnwrap(window.selectedTab)
            let oldURL = tab.urlString
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.delayLocalFile = true
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleLocalCommit-\(UUID()).html")
            try "<title>Committed</title>".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }

            let opening = Task { try await window.acceptLocalFile(file, replacing: tab.id) }
            try await eventually { page.localFileContinuation != nil }
            XCTAssertEqual(window.selectedTab?.urlString, oldURL)
            XCTAssertNil(window.selectedTab?.localFileBookmark)

            page.finishLocalFile(.success(()))
            try await opening.value

            XCTAssertEqual(window.selectedTab?.id, tab.id)
            XCTAssertEqual(window.selectedTab?.urlString, file.absoluteString)
            XCTAssertNotNil(window.selectedTab?.localFileBookmark)
        }
    }

    func testFailedProvisionalLocalFileDoesNotReplaceNewerSelection() async throws {
        try await withApp { app, engines in
            let window = try XCTUnwrap(app.windows.first)
            window.record.tabs.removeAll()
            window.clearSelection()
            engines[0].capabilities.pageOperations.insert(.localFile)
            engines[0].delayLocalFile = true
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleLocalSelection-\(UUID()).html")
            try "<title>Candidate</title>".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }

            let opening = Task { try await window.acceptLocalFile(file) }
            try await eventually { engines[0].contexts.first?.pages.first?.localFileContinuation != nil }
            let candidate = try XCTUnwrap(window.selectedTab?.id)
            window.addTab(url: URL(string: "https://newer.example")!)
            let newer = try XCTUnwrap(window.selectedTab?.id)
            XCTAssertNotEqual(newer, candidate)
            engines[0].contexts.first?.pages.first?.finishLocalFile(.failure(EngineError.notReady("Injected failure")))
            do { try await opening.value; XCTFail("Expected the candidate to fail") } catch {}

            XCTAssertEqual(window.selectedTab?.id, newer)
            XCTAssertFalse(window.record.tabs.contains { $0.id == candidate })
        }
    }

    func testCommittedLocalFileBookmarkMatchesURLWhenHostIsRetiredBeforePersistence() async throws {
        try await withApp { app, engines in
            let window = try XCTUnwrap(app.windows.first)
            engines[0].capabilities.pageOperations.insert(.localFile)
            engines[0].delayLocalFile = true
            window.addTab(url: URL(string: "https://before.example")!)
            let tab = try XCTUnwrap(window.selectedTab)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.delayLocalFile = true
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CobbleLocalProvenance-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let old = directory.appendingPathComponent("old.html")
            let candidate = directory.appendingPathComponent("candidate.html")
            try "old".write(to: old, atomically: true, encoding: .utf8)
            try "candidate".write(to: candidate, atomically: true, encoding: .utf8)
            let index = try XCTUnwrap(window.record.tabs.firstIndex { $0.id == tab.id })
            window.record.tabs[index].urlString = old.absoluteString
            window.record.tabs[index].localFileBookmark = try old.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)

            let opening = Task { try await window.acceptLocalFile(candidate, replacing: tab.id) }
            try await eventually { page.localFileContinuation != nil }
            page.events.onChange?(tab.id, candidate.absoluteString, "Candidate")
            window.unloadPages()
            page.finishLocalFile(.success(()))
            do { try await opening.value; XCTFail("Expected retired ownership to reject") } catch {}

            let saved = try XCTUnwrap(window.record.tabs.first { $0.id == tab.id }?.localFileBookmark)
            var stale = false
            let resolved = try URL(resolvingBookmarkData: saved, options: [.withSecurityScope, .withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            XCTAssertEqual(resolved.standardizedFileURL, candidate.standardizedFileURL)
        }
    }

    func testRoutingUsesExactHostsExplicitChoiceAndArbitraryThirdEngine() async throws {
        try await withApp { app, engines in
            XCTAssertTrue(app.preferences.setDefaultEngine(self.secondID))
            XCTAssertTrue(app.preferences.setEngineRule(for: self.destination, engineID: self.thirdID))
            XCTAssertEqual(app.preferences.engine(for: self.destination), self.thirdID)
            XCTAssertEqual(app.preferences.engine(for: URL(string: "http://FIGMA.com.:8080/other")!), self.thirdID)
            XCTAssertEqual(app.preferences.engine(for: URL(string: "https://www.figma.com")!), self.secondID)
            XCTAssertEqual(app.preferences.engine(for: URL(string: "https://figma.com.evil.example")!), self.secondID)
            XCTAssertEqual(app.preferences.engine(for: self.destination, override: .webKit), .webKit)
            let window = app.windows[0]
            window.addTab(url: self.destination)
            XCTAssertEqual(window.selectedPage?.contextID.engineID, self.thirdID)
            XCTAssertEqual(engines[2].contexts.count, 1)
            XCTAssertEqual(engines[2].contexts[0].pageWindowIDs, [window.id])
            XCTAssertTrue(engines[0].contexts.isEmpty)
            let reopened = BrowserPreferences(directory: app.store.directory)
            XCTAssertEqual(reopened.defaultEngine, self.secondID)
            XCTAssertEqual(reopened.engineRules, app.preferences.engineRules)
        }
    }

    func testOnlyNonDefaultTabsExposeTheirRunningEngine() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            XCTAssertTrue(app.preferences.setEngineRule(for: self.destination, engineID: self.secondID))
            window.addTab(url: self.destination)
            let tab = try XCTUnwrap(window.selectedTab)
            XCTAssertEqual(window.nonDefaultEngine(for: tab)?.id, self.secondID)

            XCTAssertTrue(app.preferences.setDefaultEngine(self.secondID))
            XCTAssertNil(window.nonDefaultEngine(for: tab))
        }
    }

    func testProfileDeletionBlocksMutationsUntilClosePreflightCompletes() async throws {
        try await withApp { app, _ in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let window = try XCTUnwrap(app.newWindow(profileID: profile.id))
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true

            let deletion = Task { await app.deleteProfile(profile.id) }
            try await self.eventually { app.isDeletingProfile(profile.id) && page.closeRequest != nil }
            let nativeClose = try XCTUnwrap(page.events.onClose)
            XCTAssertNil(app.newWindow(profileID: profile.id))
            app.library.bookmark(urlString: self.destination.absoluteString, title: "Blocked", profileID: profile.id)
            XCTAssertNotNil(app.library.lastError)
            app.siteSettings.update(SiteSetting(profileID: profile.id, origin: "https://example.com", camera: .allow))
            XCTAssertTrue(app.siteSettings.entries.filter { $0.profileID == profile.id }.isEmpty)

            page.state.lifecycle = .closed
            nativeClose()
            page.finishCloseRequest(accepted: true)
            let result = await deletion.value
            XCTAssertNil(result)
        }
    }

    func testUnsupportedProfileDeletionFailsBeforeClosingOrRemovingAnything() async throws {
        try await withApp { app, engines in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let window = try XCTUnwrap(app.newWindow(profileID: profile.id))
            window.addTab(url: self.destination)
            app.library.bookmark(urlString: self.destination.absoluteString,
                                 title: "Keep", profileID: profile.id)
            _ = try app.engines.context(engineID: self.thirdID, profile: profile,
                                        siteSettings: app.siteSettings)
            engines[2].capabilities.supportsProfileDeletion = false

            let result = await app.deleteProfile(profile.id)

            XCTAssertTrue(result?.contains(engines[2].name) == true)
            XCTAssertTrue(app.profiles.contains { $0.id == profile.id })
            XCTAssertTrue(app.windows.contains { $0 === window })
            XCTAssertFalse(app.library.search("Keep", profileID: profile.id).isEmpty)
            XCTAssertTrue(engines.allSatisfy { $0.removedProfiles.isEmpty })
        }
    }

    func testProfileDeletionPreflightFailureDoesNotMutateAnything() async throws {
        try await withApp { app, engines in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let window = try XCTUnwrap(app.newWindow(profileID: profile.id))
            window.addTab(url: self.destination)
            _ = try app.engines.context(engineID: self.secondID, profile: profile,
                                        siteSettings: app.siteSettings)
            engines[1].profileDeletionPreflightFailure = true

            let result = await app.deleteProfile(profile.id)

            XCTAssertTrue(result?.contains(engines[1].name) == true)
            XCTAssertTrue(app.profiles.contains { $0.id == profile.id })
            XCTAssertTrue(app.windows.contains { $0 === window })
            XCTAssertTrue(engines.allSatisfy { $0.removedProfiles.isEmpty })
        }
    }

    func testProfileDeletionFailurePersistsTombstoneAndRetriesAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleEngineTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstEngines = [TestEngine(.webKit), TestEngine(secondID)]
        let first = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry(firstEngines))
        let profile = try XCTUnwrap(first.createProfile(name: "Work"))
        _ = first.newWindow(profileID: profile.id)
        _ = try first.engines.context(engineID: .webKit, profile: profile,
                                      siteSettings: first.siteSettings)
        _ = try first.engines.context(engineID: secondID, profile: profile,
                                      siteSettings: first.siteSettings)
        firstEngines[1].profileDeletionFailure = true

        let result = await first.deleteProfile(profile.id)

        XCTAssertTrue(result?.contains("could not finish") == true)
        XCTAssertTrue(first.isDeletingProfile(profile.id))
        let tombstone = try XCTUnwrap(first.snapshot.pendingProfileDeletions?.first)
        XCTAssertEqual(tombstone.profileID, profile.id)
        XCTAssertEqual(Set(tombstone.requiredEngineIDs), [.webKit, secondID])
        XCTAssertFalse(first.windows.contains { $0.record.profileID == profile.id })
        first.windows.forEach { $0.closePages() }
        await first.engines.shutdown()
        first.library.close()

        let secondEngines = [TestEngine(.webKit)]
        let second = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry(secondEngines))
        XCTAssertTrue(second.isDeletingProfile(profile.id))
        XCTAssertFalse(second.windows.contains { $0.record.profileID == profile.id })
        try await eventually { second.persistenceMessage?.contains("every engine") == true }
        XCTAssertTrue(second.profiles.contains { $0.id == profile.id })
        XCTAssertNotNil(second.snapshot.pendingProfileDeletions)
        second.library.bookmark(urlString: destination.absoluteString, title: "Still writable",
                                profileID: Profile.defaultID)
        XCTAssertNil(second.library.lastError)
        second.windows.forEach { $0.closePages() }
        await second.engines.shutdown()
        second.library.close()

        let thirdEngines = [TestEngine(.webKit), TestEngine(secondID)]
        let third = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry(thirdEngines))
        XCTAssertTrue(third.isDeletingProfile(profile.id))
        try await eventually { !third.isDeletingProfile(profile.id) }
        XCTAssertFalse(third.profiles.contains { $0.id == profile.id })
        XCTAssertNil(third.snapshot.pendingProfileDeletions)
        XCTAssertFalse(third.isDeletingProfile(profile.id))
        XCTAssertTrue(thirdEngines.allSatisfy { $0.removedProfiles.contains(profile.id) })
        third.windows.forEach { $0.closePages() }
        await third.engines.shutdown()
        third.library.close()
    }

    func testMalformedAndDuplicateDeletionTombstonesStayFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleEngineTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Profile(name: "Partial", storeBinding: .named(UUID()))
        let second = Profile(name: "Unknown", storeBinding: .named(UUID()))
        let firstSpace = Space(profileID: first.id)
        let secondSpace = Space(profileID: second.id)
        let snapshot = SessionSnapshot(
            profiles: [Profile(id: Profile.defaultID), first, second],
            spaces: [Space(id: Space.defaultID), firstSpace, secondSpace],
            windows: [WindowRecord(profileID: first.id, selectedSpaceID: firstSpace.id),
                      WindowRecord(profileID: second.id, selectedSpaceID: secondSpace.id)],
            pendingProfileDeletions: [
                PendingProfileDeletion(profileID: first.id, requiredEngineIDs: [.webKit]),
                PendingProfileDeletion(profileID: first.id,
                    requiredEngineIDs: [secondID, EngineID(rawValue: "")]),
                PendingProfileDeletion(profileID: second.id, requiredEngineIDs: [])
            ])
        let store = SessionStore(directory: directory)
        let saveError = await store.save(snapshot)
        XCTAssertNil(saveError)

        let engines = [TestEngine(.webKit), TestEngine(secondID)]
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry(engines))
        XCTAssertTrue(app.isDeletingProfile(first.id))
        XCTAssertTrue(app.isDeletingProfile(second.id))
        XCTAssertFalse(app.windows.contains { $0.record.profileID == first.id || $0.record.profileID == second.id })
        try await eventually { app.persistenceMessage?.contains("every engine") == true }
        XCTAssertTrue(app.profiles.contains { $0.id == first.id })
        XCTAssertTrue(app.profiles.contains { $0.id == second.id })
        let restored = app.snapshot.pendingProfileDeletions ?? []
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(Set(restored.first { $0.profileID == first.id }?.requiredEngineIDs ?? []),
                       [.webKit, secondID, EngineID(rawValue: "")])
        XCTAssertEqual(restored.first { $0.profileID == second.id }?.requiredEngineIDs, [])
        XCTAssertTrue(engines.allSatisfy(\.removedProfiles.isEmpty))
        await app.engines.shutdown()
        app.library.close()
    }

    func testLegacyProfileEngineUsageBlocksFreshFastDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleEngineTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = Profile(name: "Legacy", storeBinding: .named(UUID()))
        let space = Space(profileID: profile.id)
        let legacy = SessionSnapshot(version: 6,
            profiles: [Profile(id: Profile.defaultID), profile],
            spaces: [Space(id: Space.defaultID), space],
            windows: [WindowRecord(profileID: profile.id, selectedSpaceID: space.id)])
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("session.json"), options: .atomic)

        let app = AppModel(store: SessionStore(directory: directory),
                           engines: EngineRegistry([TestEngine(.webKit)]))
        let usage = try XCTUnwrap(app.snapshot.profileEngineUsage?.first { $0.profileID == profile.id })
        XCTAssertEqual(Set(usage.engineIDs), [.webKit, EngineID(rawValue: "chromium")])
        let deletion = await app.deleteProfile(profile.id)
        XCTAssertTrue(deletion?.contains("unavailable") == true)
        XCTAssertTrue(app.profiles.contains { $0.id == profile.id })
        await app.engines.shutdown()
        app.library.close()
    }

    func testRecordedEngineUsageSurvivesRestartBeforeDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleEngineTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fullEngines = [TestEngine(.webKit), TestEngine(secondID)]
        let full = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry(fullEngines))
        let profile = try XCTUnwrap(full.createProfile(name: "Used"))
        _ = try full.engines.context(engineID: secondID, profile: profile, siteSettings: full.siteSettings)
        XCTAssertEqual(Set(full.snapshot.profileEngineUsage?.first { $0.profileID == profile.id }?.engineIDs ?? []),
                       [secondID])
        full.flush()
        await full.engines.shutdown()
        full.library.close()

        let fast = AppModel(store: SessionStore(directory: directory),
                            engines: EngineRegistry([TestEngine(.webKit)]))
        let deletion = await fast.deleteProfile(profile.id)
        XCTAssertTrue(deletion?.contains("unavailable") == true)
        XCTAssertTrue(fast.profiles.contains { $0.id == profile.id })
        XCTAssertNil(fast.snapshot.pendingProfileDeletions)
        await fast.engines.shutdown()
        fast.library.close()
    }

    func testPrivatePagesDoNotPersistProfileEngineUsage() async throws {
        try await withApp { app, _ in
            let profile = try XCTUnwrap(app.createProfile(name: "Private only"))
            _ = try app.engines.context(engineID: self.secondID, profile: profile, privateWindowID: UUID(),
                                        siteSettings: app.siteSettings)

            XCTAssertNil(app.snapshot.profileEngineUsage?.first { $0.profileID == profile.id })
        }
    }

    func testEngineContextDoesNotOpenWhenUsageProvenanceCannotBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleEngineTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = TestEngine(secondID)
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([engine]))
        let profile = try XCTUnwrap(app.createProfile(name: "Unsaved"))
        try FileManager.default.createDirectory(at: app.store.url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try app.engines.context(engineID: secondID, profile: profile,
                                                     siteSettings: app.siteSettings))
        XCTAssertTrue(engine.contexts.isEmpty)
        XCTAssertTrue(app.snapshot.profileEngineUsage?.first { $0.profileID == profile.id } == nil)
        XCTAssertNotNil(app.persistenceMessage)
        app.library.close()
    }

    func testFindCommandsUseWindowQueryAndEngineCapability() async throws {
        try await withApp { app, _ in
            let first = app.windows[0]
            first.addTab(url: self.destination)
            let page = try XCTUnwrap(first.selectedPage as? TestPage)
            XCTAssertFalse(first.canPerform(.find))
            page.capabilities.pageOperations.insert(.find)
            XCTAssertTrue(first.canPerform(.find))
            XCTAssertFalse(first.perform(.findNext))
            let focus = first.findFocusRequest
            XCTAssertTrue(first.perform(.find))
            XCTAssertTrue(first.findPresented)
            XCTAssertNotEqual(first.findFocusRequest, focus)
            first.findText = "first window"
            XCTAssertTrue(first.perform(.findNext))
            XCTAssertTrue(first.perform(.findPrevious))
            XCTAssertEqual(page.findRequests.map(\.0), ["first window", "first window"])
            XCTAssertEqual(page.findRequests.map(\.1), [false, true])
            first.findPresented = false
            XCTAssertTrue(first.perform(.find))
            XCTAssertEqual(page.findRequests.map(\.0), ["first window", "first window", "first window"])
            XCTAssertFalse(page.findRequests.last?.1 ?? true)

            let second = app.newWindow(url: self.destination)
            second.activateSelected()
            let otherPage = try XCTUnwrap(second.selectedPage as? TestPage)
            otherPage.capabilities.pageOperations.insert(.find)
            XCTAssertFalse(second.canPerform(.findNext))
            second.findText = "second window"
            XCTAssertTrue(second.perform(.findNext))
            XCTAssertEqual(otherPage.findRequests.map(\.0), ["second window"])
            XCTAssertEqual(page.findRequests.count, 3)
            first.closeTab(page.tabID)
            XCTAssertFalse(first.canPerform(.findPrevious))
            XCTAssertEqual(BrowserCommand.findNext.defaultShortcut, BrowserShortcut("g"))
            XCTAssertEqual(BrowserCommand.findPrevious.defaultShortcut, BrowserShortcut("g", [.command, .shift]))
        }
    }

    func testSwitchCancellationFailureAndSuccessPreserveTabIdentity() async throws {
        try await withApp { app, engines in
            let window = app.windows[0]
            window.addTab(url: URL(string: "https://example.com")!)
            let original = try XCTUnwrap(window.selectedPage as? TestPage)
            let tab = try XCTUnwrap(window.selectedTab)
            let staleVisit = try XCTUnwrap(original.events.onVisit)
            let staleChange = try XCTUnwrap(original.events.onChange)
            let stalePopup = try XCTUnwrap(original.events.onCreatePage)
            XCTAssertTrue(app.preferences.setEngineRule(for: self.destination, engineID: self.secondID))
            var confirmations = 0
            window.confirmEngineSwitch = { text in confirmations += 1; XCTAssertTrue(text.contains("back/forward")); return false }
            window.addressDraft = self.destination.absoluteString; window.submitAddress()
            XCTAssertTrue(window.selectedPage === original)
            XCTAssertEqual(window.selectedTab, tab)
            XCTAssertEqual(confirmations, 1)

            window.confirmEngineSwitch = { _ in confirmations += 1; return true }
            engines[1].prepareFailure = true
            window.submitAddress()
            try await self.eventually { window.addressError != nil }
            XCTAssertTrue(window.selectedPage === original)
            XCTAssertEqual(window.selectedTab, tab)
            engines[1].prepareFailure = false
            window.submitAddress()
            try await self.eventually { window.selectedPage?.contextID.engineID == self.secondID }
            XCTAssertEqual(window.selectedTab?.id, tab.id)
            XCTAssertEqual(window.selectedTab?.urlString, self.destination.absoluteString)
            XCTAssertNotEqual(window.selectedTab?.isUnloaded, true)
            XCTAssertEqual(original.state.lifecycle, .closed)
            XCTAssertEqual(confirmations, 3)
            staleVisit(tab.id, "https://stale.example", "Stale")
            staleChange(tab.id, "https://stale.example", "Stale")
            XCTAssertFalse(stalePopup(TestPage(tabID: UUID(), contextID: original.contextID), true))
            XCTAssertTrue(app.library.search("stale", profileID: Profile.defaultID).isEmpty)
            XCTAssertEqual(window.selectedTab?.urlString, self.destination.absoluteString)
        }
    }

    func testPageNavigationAndPopupsKeepTheirContextAndExplicitOverride() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            window.confirmEngineSwitch = { _ in true }
            window.setEngine(self.secondID, for: window.selectedTab!.id)
            try await self.eventually { window.selectedPage?.contextID.engineID == self.secondID }
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.events.onChange?(page.tabID, "https://login.example/auth", "Sign In")
            XCTAssertEqual(window.selectedTab?.engineID, self.secondID)
            XCTAssertEqual(page.loadedURLs.count, 1, "Metadata must not issue a load")
            let child = TestPage(tabID: UUID(), contextID: page.contextID)
            XCTAssertTrue(page.events.onCreatePage?(child, true) == true)
            XCTAssertTrue(window.selectedPage === child)
            XCTAssertEqual(window.selectedTab?.engineOverride, self.secondID)
            XCTAssertTrue(child.loadedURLs.isEmpty, "Engine-owned popups must not be loaded twice")
            window.addressDraft = "https://other.example"; window.submitAddress()
            XCTAssertEqual(window.selectedTab?.engineID, self.secondID)
            XCTAssertEqual(child.loadedURLs.last, URL(string: "https://other.example"))
            let foreign = TestPage(tabID: UUID(), contextID: BrowsingContextID(engineID: self.thirdID, profileID: Profile.defaultID, privateWindowID: nil))
            XCTAssertFalse(child.events.onCreatePage?(foreign, true) == true)
        }
    }

    func testPopupKeepsItsOpenerSpaceAndIsRejectedAfterTheOpenerStartsClosing() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let parentTab = try XCTUnwrap(window.selectedTab)
            let parent = try XCTUnwrap(window.selectedPage as? TestPage)
            app.addSpace(name: "Other", profileID: Profile.defaultID)
            let otherSpace = try XCTUnwrap(app.spaces.last)
            window.selectSpace(otherSpace.id)
            window.addTab(url: URL(string: "https://other.example")!)

            let child = TestPage(tabID: UUID(), contextID: parent.contextID)
            XCTAssertTrue(parent.events.onCreatePage?(child, true) == true)
            XCTAssertEqual(window.selectedTab?.spaceID, parentTab.spaceID)

            parent.state.lifecycle = .closing
            let lateChild = TestPage(tabID: UUID(), contextID: parent.contextID)
            XCTAssertFalse(parent.events.onCreatePage?(lateChild, true) == true)
            XCTAssertFalse(window.record.tabs.contains { $0.id == lateChild.tabID })
        }
    }

    func testConnectionAndPopupControlsRequireEngineSignals() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            XCTAssertEqual(window.pageConnection, .unknown)
            page.state.urlString = "http://insecure.example/page"
            page.events.onChange?(page.tabID, "http://insecure.example/page", "Insecure")
            XCTAssertEqual(window.pageConnection, .insecure)
            page.state.isLoading = true
            XCTAssertEqual(window.pageConnection, .insecure)
            page.state.urlString = self.destination.absoluteString
            page.state.connection = .mixed
            page.events.onChange?(page.tabID, self.destination.absoluteString, "Mixed")
            XCTAssertEqual(window.pageConnection, .mixed)
            let favicon = try XCTUnwrap(NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.tiffRepresentation)
            let tabIndex = try XCTUnwrap(window.record.tabs.firstIndex { $0.id == page.tabID })
            window.record.tabs[tabIndex].favicon = CachedFavicon(origin: "https://figma.com", png: favicon)
            XCTAssertNotNil(window.icon(for: page.tabID))
            page.state.isCrashed = true
            XCTAssertNil(window.icon(for: page.tabID), "A crashed page must not show its stale cached favicon")
            page.state.camera = .active
            page.state.microphone = .muted
            page.state.isDisplayCapturing = true
            XCTAssertEqual(window.captureState(for: page.tabID).camera, .none)
            XCTAssertEqual(window.captureState(for: page.tabID).microphone, .none)
            XCTAssertFalse(window.captureState(for: page.tabID).display)
            XCTAssertFalse(window.isCapturing(page.tabID))
            page.state.isCrashed = false
            page.state.connection = .secure
            page.events.onChange?(page.tabID, "https://pending.example/page", "Pending")
            XCTAssertEqual(window.pageConnection, .unknown, "Do not attribute the prior page's security signal to a pending URL")
            page.state.isLoading = false
            page.state.urlString = self.destination.absoluteString
            page.state.connection = .unknown
            page.events.onChange?(page.tabID, self.destination.absoluteString, "Secure signal pending")
            XCTAssertEqual(window.pageConnection, .unknown)
            XCTAssertFalse(window.supportsPopupPolicy)

            window.setSitePermission(.camera, .allow)
            XCTAssertEqual(app.siteSettings.setting(origin: self.destination,
                profileID: window.record.profileID).camera, .ask)

            window.setPopups(.allow)
            XCTAssertEqual(app.siteSettings.setting(origin: self.destination,
                profileID: window.record.profileID).popups, .ask)

            page.capabilities.permissions = [.camera]
            page.capabilities.supportsPopupPolicy = true
            page.state.connection = .secure
            XCTAssertTrue(window.supportsPopupPolicy)
            XCTAssertEqual(window.pageConnection, .secure)
            window.setSitePermission(.camera, .allow)
            XCTAssertEqual(app.siteSettings.setting(origin: self.destination,
                profileID: window.record.profileID).camera, .allow)
            window.setPopups(.allow)
            XCTAssertEqual(app.siteSettings.setting(origin: self.destination,
                profileID: window.record.profileID).popups, .allow)
        }
    }

    func testMediaRequestRejectsWrongWindowOrEmbeddingOriginOnce() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.permissions = [.camera, .microphone]
            var decisions: [SitePermission] = []
            let wrongWindow = PageMediaPermissionRequest(tabID: page.tabID, contextID: page.contextID,
                windowID: UUID(), documentID: "document", frameID: "frame", kinds: [.camera],
                requestingOrigin: self.destination,
                embeddingOrigin: self.destination) { decisions.append($0) }
            page.events.onMediaPermissionRequest?(wrongWindow)
            wrongWindow.resolve(.allow)

            let wrongEmbedding = PageMediaPermissionRequest(tabID: page.tabID, contextID: page.contextID,
                windowID: window.id, documentID: "document", frameID: "frame", kinds: [.microphone],
                requestingOrigin: self.destination,
                embeddingOrigin: URL(string: "https://embedded.example")!) { decisions.append($0) }
            page.events.onMediaPermissionRequest?(wrongEmbedding)
            wrongEmbedding.resolve(.allow)
            XCTAssertEqual(decisions, [.deny, .deny])
            XCTAssertFalse(page.hasPendingPrompt)
        }
    }

    func testPagePromptsCancelWithoutAVisibleOwningWindow() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            let identity = PagePromptIdentity(tabID: page.tabID, contextID: page.contextID,
                windowID: window.id, documentID: "document", frameID: "frame",
                requestingOrigin: self.destination, topLevelOrigin: self.destination)
            var dialogs: [PageJavaScriptDialogResult] = []
            let dialog = PageJavaScriptDialogRequest(identity: identity,
                prompt: PageJavaScriptDialog(kind: .confirm, message: "Continue?", defaultText: nil, isReload: false)) {
                    dialogs.append($0)
                }
            var credentials: [PageHTTPAuthCredential?] = []
            let auth = PageHTTPAuthRequest(identity: identity,
                prompt: PageHTTPAuthChallenge(requestURL: self.destination, scheme: "basic", realm: nil,
                    isProxy: false, firstAttempt: true, primaryNavigation: true)) { credentials.append($0) }
            var files: [[URL]?] = []
            let chooser = PageFileChooserRequest(identity: identity,
                prompt: PageFileChooser(mode: .openMultiple, title: "Upload", defaultFilename: nil,
                    acceptedTypes: ["image/png"])) { files.append($0) }
            var externalProtocolDecisions: [Bool] = []
            let externalProtocol = PageExternalProtocolRequest(identity: identity,
                prompt: PageExternalProtocolPrompt(targetURL: URL(string: "mailto:test@example.com")!,
                    userGesture: true, primaryMainFrame: true, fencedFrame: false)) {
                        externalProtocolDecisions.append($0)
                    }
            let clientChoice = PageClientCertificateChoice(id: UUID(),
                certificate: PageCertificateDetails(subject: "Fixture Client", issuer: "Fixture CA",
                    validFrom: nil, validUntil: nil), serialNumber: "01")
            var clientCertificateChoices: [UUID?] = []
            let clientCertificate = PageClientCertificateRequest(identity: identity,
                prompt: PageClientCertificatePrompt(choices: [clientChoice],
                    choicesTruncated: false, context: .page(pageID: "fixture-page"))) {
                        clientCertificateChoices.append($0)
                    }
            page.events.onJavaScriptDialog?(dialog)
            page.events.onHTTPAuthRequest?(auth)
            page.events.onFileChooserRequest?(chooser)
            page.events.onExternalProtocolRequest?(externalProtocol)
            page.events.onClientCertificateRequest?(clientCertificate)
            dialog.resolve(.accept(nil)); auth.resolve(.init(username: "late", password: "late")); chooser.resolve([])
            externalProtocol.resolve(true)
            clientCertificate.resolve(clientChoice.id)
            XCTAssertEqual(dialogs.count, 1)
            if case .cancel = dialogs[0] {} else { XCTFail("Expected cancelled dialog") }
            XCTAssertEqual(credentials.count, 1); XCTAssertNil(credentials[0])
            XCTAssertEqual(files.count, 1); XCTAssertNil(files[0])
            XCTAssertEqual(externalProtocolDecisions, [false])
            XCTAssertEqual(clientCertificateChoices.count, 1)
            XCTAssertNil(clientCertificateChoices[0])
            XCTAssertFalse(page.hasPendingPrompt)
        }
    }

    func testUnloadPagesCancelsOwnedClientCertificatePromptBeforeRetiringHost() async throws {
        try await withApp { app, _ in
            let model = app.windows[0]
            model.addTab(url: self.destination)
            let page = try XCTUnwrap(model.selectedPage as? TestPage)
            let nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            nativeWindow.isReleasedWhenClosed = false
            nativeWindow.contentView = page.nativeView
            nativeWindow.makeKeyAndOrderFront(nil)
            defer { nativeWindow.contentView = nil; nativeWindow.close() }
            var identity = PagePromptIdentity(tabID: page.tabID, contextID: page.contextID,
                windowID: model.id, documentID: "", frameID: "",
                requestingOrigin: self.destination, topLevelOrigin: self.destination)
            identity.visiblePageOrigin = self.destination
            let choice = PageClientCertificateChoice(id: UUID(), certificate: PageCertificateDetails(
                subject: "Fixture Client", issuer: "Fixture CA", validFrom: nil, validUntil: nil),
                serialNumber: "01")
            var results: [UUID?] = []
            var replacement: PageClientCertificateRequest?
            let request = PageClientCertificateRequest(identity: identity,
                prompt: PageClientCertificatePrompt(choices: [choice], choicesTruncated: false,
                    context: .page(pageID: "fixture-page"))) { result in
                        results.append(result)
                        guard results.count == 1 else { return }
                        MainActor.assumeIsolated {
                            let next = PageClientCertificateRequest(identity: identity,
                                prompt: PageClientCertificatePrompt(choices: [choice], choicesTruncated: false,
                                    context: .page(pageID: "replacement-page"))) { results.append($0) }
                            replacement = next
                            page.events.onClientCertificateRequest?(next)
                        }
                    }
            page.events.onClientCertificateRequest?(request)
            for _ in 0..<100 where nativeWindow.attachedSheet == nil { await Task.yield() }
            XCTAssertNotNil(nativeWindow.attachedSheet)
            XCTAssertTrue(page.hasPendingPrompt)

            model.unloadPages()

            XCTAssertEqual(results.count, 2)
            XCTAssertTrue(results.allSatisfy { $0 == nil })
            XCTAssertFalse(try XCTUnwrap(replacement).isPending)
            XCTAssertNil(nativeWindow.attachedSheet)
            XCTAssertFalse(page.hasPendingPrompt)
            XCTAssertNil(model.selectedPage)
        }
    }

    func testClientCertificateTopLevelValidationPreservesPrimaryNavigationException() async throws {
        try await withApp { app, _ in
            let model = app.windows[0]
            model.addTab(url: self.destination)
            let page = try XCTUnwrap(model.selectedPage as? TestPage)
            let nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            nativeWindow.isReleasedWhenClosed = false
            nativeWindow.contentView = page.nativeView
            nativeWindow.makeKeyAndOrderFront(nil)
            defer { nativeWindow.contentView = nil; nativeWindow.close() }
            let other = URL(string: "https://other.example")!
            let choice = PageClientCertificateChoice(id: UUID(), certificate: PageCertificateDetails(
                subject: "Fixture Client", issuer: "Fixture CA", validFrom: nil, validUntil: nil),
                serialNumber: "01")

            @MainActor func publish(context: PageClientCertificateContext, topLevel: URL?, visible: URL?,
                         documentID: String = "", frameID: String = "") -> PageClientCertificateRequest {
                var identity = PagePromptIdentity(tabID: page.tabID, contextID: page.contextID,
                    windowID: model.id, documentID: documentID, frameID: frameID,
                    requestingOrigin: self.destination, topLevelOrigin: topLevel)
                identity.visiblePageOrigin = visible
                var request: PageClientCertificateRequest!
                request = PageClientCertificateRequest(identity: identity,
                    prompt: PageClientCertificatePrompt(choices: [choice], choicesTruncated: false,
                                                        context: context)) { _ in }
                page.events.onClientCertificateRequest?(request)
                return request
            }

            let malformedDocument = publish(context: .document(documentID: "doc", frameID: "frame"),
                topLevel: other, visible: self.destination, documentID: "doc", frameID: "frame")
            let malformedPage = publish(context: .page(pageID: "page"),
                topLevel: other, visible: self.destination)
            let malformedSubframe = publish(context: .navigation(navigationID: "7", primaryMainFrame: false),
                topLevel: other, visible: self.destination)
            XCTAssertFalse(malformedDocument.isPending)
            XCTAssertFalse(malformedPage.isPending)
            XCTAssertFalse(malformedSubframe.isPending)
            XCTAssertNil(nativeWindow.attachedSheet)

            let primary = publish(context: .navigation(navigationID: "8", primaryMainFrame: true),
                topLevel: other, visible: self.destination)
            for _ in 0..<100 where nativeWindow.attachedSheet == nil { await Task.yield() }
            XCTAssertNotNil(nativeWindow.attachedSheet)
            page.events.onPromptCancelled?(primary.id)
            XCTAssertFalse(primary.isPending)
            for _ in 0..<100 where nativeWindow.attachedSheet != nil { await Task.yield() }
            XCTAssertNil(nativeWindow.attachedSheet)

            page.state.urlString = ""
            let blankDocument = publish(context: .document(documentID: "blank-doc", frameID: "frame"),
                topLevel: nil, visible: nil, documentID: "blank-doc", frameID: "frame")
            let blankSubframe = publish(context: .navigation(navigationID: "9", primaryMainFrame: false),
                topLevel: nil, visible: nil)
            XCTAssertFalse(blankDocument.isPending)
            XCTAssertFalse(blankSubframe.isPending)
            XCTAssertNil(nativeWindow.attachedSheet)

            let pageChallenge = publish(context: .page(pageID: "initial-page"),
                topLevel: nil, visible: nil)
            for _ in 0..<100 where nativeWindow.attachedSheet == nil { await Task.yield() }
            XCTAssertNotNil(nativeWindow.attachedSheet)
            page.events.onPromptCancelled?(pageChallenge.id)
            XCTAssertFalse(pageChallenge.isPending)
            for _ in 0..<100 where nativeWindow.attachedSheet != nil { await Task.yield() }
            XCTAssertNil(nativeWindow.attachedSheet)

            let initial = publish(context: .navigation(navigationID: "9", primaryMainFrame: true),
                topLevel: nil, visible: nil)
            for _ in 0..<100 where nativeWindow.attachedSheet == nil { await Task.yield() }
            XCTAssertNotNil(nativeWindow.attachedSheet)
            page.events.onPromptCancelled?(initial.id)
            XCTAssertFalse(initial.isPending)
        }
    }

    func testFormRepostRequiresReloadMetadataAndNativeCancellationEndsOwnedSheet() async throws {
        try await withApp { app, _ in
            let model = app.windows[0]
            model.addTab(url: self.destination)
            let page = try XCTUnwrap(model.selectedPage as? TestPage)
            let identity = PagePromptIdentity(tabID: page.tabID, contextID: page.contextID,
                windowID: model.id, documentID: "committed-document", frameID: "9:4",
                requestingOrigin: self.destination, topLevelOrigin: self.destination)

            var malformedResults: [PageJavaScriptDialogResult] = []
            let malformed = PageJavaScriptDialogRequest(identity: identity,
                prompt: PageJavaScriptDialog(kind: .formRepost, message: "untrusted native copy",
                    defaultText: nil, isReload: false)) { malformedResults.append($0) }
            page.events.onJavaScriptDialog?(malformed)
            malformed.resolve(.accept(nil))
            XCTAssertEqual(malformedResults.count, 1)
            if case .cancel = malformedResults[0] {} else { XCTFail("Expected malformed repost cancellation") }

            var staleIdentity = identity
            staleIdentity.visiblePageOrigin = URL(string: "https://stale.example")!
            var staleResults: [PageJavaScriptDialogResult] = []
            let stale = PageJavaScriptDialogRequest(identity: staleIdentity,
                prompt: PageJavaScriptDialog(kind: .formRepost, message: "untrusted native copy",
                    defaultText: nil, isReload: true)) { staleResults.append($0) }
            page.events.onJavaScriptDialog?(stale)
            stale.resolve(.accept(nil))
            XCTAssertEqual(staleResults.count, 1)
            if case .cancel = staleResults[0] {} else { XCTFail("Expected stale repost cancellation") }

            let nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            nativeWindow.isReleasedWhenClosed = false
            nativeWindow.contentView = page.nativeView
            nativeWindow.makeKeyAndOrderFront(nil)
            defer { nativeWindow.contentView = nil; nativeWindow.close() }

            var results: [PageJavaScriptDialogResult] = []
            let request = PageJavaScriptDialogRequest(identity: identity,
                prompt: PageJavaScriptDialog(kind: .formRepost, message: "untrusted native copy",
                    defaultText: nil, isReload: true)) { results.append($0) }
            page.events.onJavaScriptDialog?(request)
            for _ in 0..<100 where nativeWindow.attachedSheet == nil { await Task.yield() }
            XCTAssertNotNil(nativeWindow.attachedSheet)
            XCTAssertTrue(page.hasPendingPrompt)

            page.events.onPromptCancelled?(request.id)
            for _ in 0..<100 where request.isPending { await Task.yield() }
            XCTAssertEqual(results.count, 1)
            if case .cancel = results[0] {} else { XCTFail("Expected native repost cancellation") }
            XCTAssertNil(nativeWindow.attachedSheet)
            XCTAssertFalse(page.hasPendingPrompt)
        }
    }

    func testPrimaryNavigationAuthUsesCommittedVisibleOriginWhileTargetIsPending() async throws {
        try await withApp { app, _ in
            let model = app.windows[0]
            model.addTab(url: self.destination)
            let page = try XCTUnwrap(model.selectedPage as? TestPage)
            let nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            nativeWindow.isReleasedWhenClosed = false
            nativeWindow.contentView = page.nativeView
            nativeWindow.makeKeyAndOrderFront(nil)
            defer { nativeWindow.contentView = nil; nativeWindow.close() }

            let target = URL(string: "https://auth.example/protected")!
            var identity = PagePromptIdentity(tabID: page.tabID, contextID: page.contextID,
                windowID: model.id, documentID: "committed-document", frameID: "0:-2",
                requestingOrigin: target, topLevelOrigin: target)
            identity.visiblePageOrigin = self.destination
            var results: [PageHTTPAuthCredential?] = []
            let request = PageHTTPAuthRequest(identity: identity,
                prompt: PageHTTPAuthChallenge(requestURL: target, scheme: "basic", realm: nil,
                    isProxy: false, firstAttempt: true, primaryNavigation: true)) { results.append($0) }
            page.events.onHTTPAuthRequest?(request)
            for _ in 0..<100 where nativeWindow.attachedSheet == nil { await Task.yield() }
            let sheet = try XCTUnwrap(nativeWindow.attachedSheet)
            nativeWindow.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            for _ in 0..<100 where request.isPending { await Task.yield() }
            XCTAssertEqual(results.count, 1)
            XCTAssertNil(results[0])
        }
    }

    func testDenyUsesAvailableCaptureStopControl() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.permissions = [.camera, .microphone]
            page.capabilities.captureControls = [.stopAllUserMedia]
            page.state.camera = .active
            page.state.microphone = .active
            window.setSitePermission(.camera, .deny)
            XCTAssertEqual(page.stopMediaCaptureCount, 1)
            XCTAssertTrue(page.captureRequests.isEmpty)

            page.capabilities.captureControls = [.stop(.camera)]
            window.setSitePermission(.camera, .deny)
            XCTAssertEqual(page.captureRequests.count, 1)
            XCTAssertEqual(page.captureRequests.first?.0, .camera)
            XCTAssertEqual(page.captureRequests.first?.1, PageCapture.none)
            XCTAssertEqual(page.stopMediaCaptureCount, 1)
        }
    }

    func testDenyStopsObservedCaptureAcrossProfileWithoutCrossingPrivateOrProfileBoundary() async throws {
        try await withApp { app, _ in
            let first = app.windows[0]
            first.addTab(url: self.destination)
            let selected = try XCTUnwrap(first.selectedPage as? TestPage)
            try await self.eventually { selected.state.urlString == self.destination.absoluteString }
            let selectedID = selected.tabID
            let sameURL = URL(string: "https://figma.com/another")!
            first.addTab(url: sameURL)
            let sameTab = try XCTUnwrap(first.selectedPage as? TestPage)
            try await self.eventually { sameTab.state.urlString == sameURL.absoluteString }
            let unrelatedURL = URL(string: "https://unrelated.example")!
            first.addTab(url: unrelatedURL)
            let unrelated = try XCTUnwrap(first.selectedPage as? TestPage)
            try await self.eventually { unrelated.state.urlString == unrelatedURL.absoluteString }
            let otherPortURL = URL(string: "https://figma.com:8443/another")!
            first.addTab(url: otherPortURL)
            let otherPort = try XCTUnwrap(first.selectedPage as? TestPage)
            try await self.eventually { otherPort.state.urlString == otherPortURL.absoluteString }
            first.select(selectedID)

            let second = app.newWindow(url: self.destination)
            second.activateSelected()
            let sameWindow = try XCTUnwrap(second.selectedPage as? TestPage)
            try await self.eventually { sameWindow.state.urlString == self.destination.absoluteString }
            let privateWindow = app.newWindow(isPrivate: true, url: self.destination)
            privateWindow.activateSelected()
            let privatePage = try XCTUnwrap(privateWindow.selectedPage as? TestPage)
            try await self.eventually { privatePage.state.urlString == self.destination.absoluteString }
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let workWindow = try XCTUnwrap(app.newWindow(url: self.destination, profileID: profile.id))
            workWindow.activateSelected()
            let workPage = try XCTUnwrap(workWindow.selectedPage as? TestPage)
            try await self.eventually { workPage.state.urlString == self.destination.absoluteString }
            app.preferences.setDefaultEngine(self.secondID)
            let otherEngineWindow = app.newWindow(url: self.destination)
            otherEngineWindow.activateSelected()
            let otherEnginePage = try XCTUnwrap(otherEngineWindow.selectedPage as? TestPage)
            try await self.eventually { otherEnginePage.state.urlString == self.destination.absoluteString }
            XCTAssertEqual(otherEnginePage.contextID.engineID, self.secondID)

            for page in [selected, sameTab, unrelated, otherPort, sameWindow, privatePage, workPage, otherEnginePage] {
                page.capabilities.permissions = [.camera, .microphone]
                page.capabilities.captureControls = [.stop(.camera), .stop(.microphone)]
                page.state.camera = .active
                page.state.microphone = .active
            }
            otherPort.state.camera = .none
            otherEnginePage.capabilities.captureControls = [.stopAllUserMedia]
            first.setSitePermission(.camera, .deny)

            for page in [selected, sameTab, unrelated, sameWindow] {
                XCTAssertEqual(page.captureRequests.count, 1)
                XCTAssertEqual(page.captureRequests.first?.0, .camera)
                XCTAssertEqual(page.captureRequests.first?.1, PageCapture.none)
            }
            XCTAssertEqual(otherEnginePage.stopMediaCaptureCount, 1)
            XCTAssertTrue(otherEnginePage.captureRequests.isEmpty)
            for page in [otherPort, privatePage, workPage] {
                XCTAssertTrue(page.captureRequests.isEmpty)
            }
            XCTAssertEqual(app.siteSettings.setting(origin: self.destination, profileID: profile.id).camera, .ask)
        }
    }

    func testFailedPermissionSaveDoesNotStopCapture() async throws {
        try await withApp { app, _ in
            let first = app.windows[0]
            first.addTab(url: self.destination)
            let selected = try XCTUnwrap(first.selectedPage as? TestPage)
            let second = app.newWindow(url: self.destination)
            second.activateSelected()
            let other = try XCTUnwrap(second.selectedPage as? TestPage)
            for page in [selected, other] {
                page.capabilities.permissions = [.camera]
                page.capabilities.captureControls = [.stop(.camera)]
                page.state.camera = .active
            }
            app.siteSettings.mutationsAllowed = { false }
            first.setSitePermission(.camera, .deny)

            XCTAssertTrue(selected.captureRequests.isEmpty)
            XCTAssertTrue(other.captureRequests.isEmpty)
            XCTAssertEqual(app.siteSettings.setting(origin: self.destination, profileID: first.record.profileID).camera, .ask)
            XCTAssertNotNil(app.siteSettings.lastError)
        }
    }

    func testDenyStopsGrantBeforeCaptureStatePublishesAndRetiresFailedStop() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.permissions = [.camera]
            page.capabilities.captureControls = [.stopAllUserMedia]
            page.state.grantedMediaKinds = [.camera]
            page.stopMediaCaptureSucceeds = false
            XCTAssertEqual(page.state.camera, .none)

            window.setSitePermission(.camera, .deny)

            XCTAssertEqual(page.stopMediaCaptureCount, 1)
            XCTAssertNil(window.selectedPage)
            XCTAssertEqual(page.state.lifecycle, .closed)
            XCTAssertTrue(window.record.tabs.first { $0.id == page.tabID }?.isUnloaded == true)
            XCTAssertNotNil(window.addressError)
        }
    }

    func testDelayedCreationCannotReviveClosedOrSupersededTabs() async throws {
        try await withApp { app, engines in
            engines[0].delayPreparation = true
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            try await self.eventually { page.preparation != nil }
            window.closeTab(page.tabID)
            page.finishPreparation()
            await Task.yield()
            XCTAssertNil(window.selectedPage)
            XCTAssertTrue(page.loadedURLs.isEmpty)

            engines[0].delayPreparation = false
            window.addTab(url: self.destination)
            let original = try XCTUnwrap(window.selectedPage)
            engines[1].delayPreparation = true
            window.confirmEngineSwitch = { _ in true }
            window.setEngine(self.secondID, for: original.tabID)
            try await self.eventually { engines[1].contexts.first?.pages.first?.preparation != nil }
            let candidate = engines[1].contexts[0].pages[0]
            window.addressDraft = "https://different.example"; window.submitAddress()
            candidate.finishPreparation()
            try await self.eventually { candidate.state.lifecycle == .closed }
            XCTAssertTrue(window.selectedPage === original)
            XCTAssertEqual(window.selectedTab?.urlString, "https://different.example")
        }
    }

    func testEngineActivationSelectsItsTabAndIgnoresClosedPageCallbacks() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let original = try XCTUnwrap(window.selectedPage)
            let activate = try XCTUnwrap(original.events.onActivate)
            window.addTab(url: URL(string: "https://example.com")!)
            let other = try XCTUnwrap(window.selectedTab?.id)
            activate()
            XCTAssertEqual(window.selectedTab?.id, original.tabID)
            window.addressDraft = "Unsaved address draft"
            activate()
            XCTAssertEqual(window.selectedTab?.id, original.tabID)
            XCTAssertEqual(window.addressDraft, "Unsaved address draft")
            window.closeTab(original.tabID)
            window.select(other)
            activate()
            XCTAssertEqual(window.selectedTab?.id, other)
        }
    }

    func testCloseConfirmationKeepsTheTabUntilAcceptedAndDeduplicatesRequests() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true

            window.closeTab(page.tabID)
            window.closeTab(page.tabID)
            try await self.eventually { page.closeRequest != nil }
            XCTAssertEqual(page.closeRequestCount, 1)
            XCTAssertTrue(window.selectedPage === page)

            page.finishCloseRequest(accepted: false)
            try await self.eventually { window.addressError != nil }
            XCTAssertTrue(window.selectedPage === page)
            XCTAssertEqual(window.selectedTab?.id, page.tabID)

            page.delayCloseRequest = false
            page.closeRequestResult = true
            window.closeTab(page.tabID)
            try await self.eventually { window.selectedTab == nil }
            XCTAssertEqual(page.closeRequestCount, 2)
            XCTAssertEqual(page.state.lifecycle, .closed)
        }
    }

    func testTerminationClosePreflightRetainsRecordsUntilRetirement() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let nativeClose = try XCTUnwrap(page.events.onClose)

            let preflight = Task { await window.requestClosePages() }
            try await self.eventually { page.closeRequest != nil }
            page.state.lifecycle = .closed
            nativeClose()
            XCTAssertEqual(window.selectedTab?.id, page.tabID)
            XCTAssertTrue(window.selectedPage === page)

            page.finishCloseRequest(accepted: true)
            let accepted = await preflight.value
            XCTAssertTrue(accepted)
            XCTAssertEqual(window.selectedTab?.id, page.tabID)

            window.addTab(url: self.destination)
            let addedPage = try XCTUnwrap(window.selectedPage as? TestPage)
            addedPage.capabilities.requiresCloseConfirmation = true
            let rechecked = await window.requestClosePages()
            XCTAssertFalse(rechecked)
            XCTAssertTrue(window.selectedPage === addedPage)

            window.closePages()
            XCTAssertEqual(page.state.lifecycle, .closed)
        }
    }

    func testTerminationPreflightRefusesWhileATabCloseIsPending() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true

            window.closeTab(page.tabID)
            try await self.eventually { page.closeRequest != nil }
            let canTerminate = await window.requestClosePages()
            XCTAssertFalse(canTerminate)
            XCTAssertEqual(window.selectedTab?.id, page.tabID)

            page.finishCloseRequest(accepted: false)
            try await self.eventually { window.addressError != nil }
        }
    }

    func testApplicationTerminationPreflightRestoresAcceptedPagesWhenALaterWindowRefuses() async throws {
        try await withApp { app, _ in
            let first = app.windows[0]
            first.addTab(url: self.destination)
            let firstPage = try XCTUnwrap(first.selectedPage as? TestPage)
            firstPage.capabilities.requiresCloseConfirmation = true
            firstPage.delayCloseRequest = true
            let firstNativeClose = try XCTUnwrap(firstPage.events.onClose)

            let second = app.newWindow(url: self.destination)
            second.activateSelected()
            let secondPage = try XCTUnwrap(second.selectedPage as? TestPage)
            secondPage.capabilities.requiresCloseConfirmation = true
            secondPage.delayCloseRequest = true
            let secondNativeClose = try XCTUnwrap(secondPage.events.onClose)

            let third = app.newWindow(url: self.destination)
            third.activateSelected()
            let thirdPage = try XCTUnwrap(third.selectedPage as? TestPage)
            thirdPage.capabilities.requiresCloseConfirmation = true
            thirdPage.delayCloseRequest = true
            let thirdNativeClose = try XCTUnwrap(thirdPage.events.onClose)

            let attempt = Task { await app.requestTerminationPreflight() }
            try await self.eventually { firstPage.closeRequest != nil }
            firstPage.state.lifecycle = .closed
            firstNativeClose()
            firstPage.finishCloseRequest(accepted: true)
            try await self.eventually { secondPage.closeRequest != nil }
            secondPage.finishCloseRequest(accepted: false)

            let refused = await attempt.value
            XCTAssertFalse(refused)
            XCTAssertTrue(first.record.tabs.contains { $0.id == firstPage.tabID && $0.isUnloaded == true })
            XCTAssertNil(first.selectedPage)
            XCTAssertEqual(secondPage.state.lifecycle, .ready)
            XCTAssertTrue(second.selectedPage === secondPage)
            XCTAssertNil(thirdPage.closeRequest)
            XCTAssertTrue(third.selectedPage === thirdPage)

            let retry = Task { await app.requestTerminationPreflight() }
            try await self.eventually { secondPage.closeRequest != nil }
            secondPage.state.lifecycle = .closed
            secondNativeClose()
            secondPage.finishCloseRequest(accepted: true)
            try await self.eventually { thirdPage.closeRequest != nil }
            thirdPage.state.lifecycle = .closed
            thirdNativeClose()
            thirdPage.finishCloseRequest(accepted: true)
            let accepted = await retry.value
            XCTAssertTrue(accepted)
        }
    }

    func testApplicationTerminationPreflightRefusesWindowAddedDuringConfirmation() async throws {
        try await withApp { app, _ in
            let first = app.windows[0]
            first.addTab(url: self.destination)
            let firstPage = try XCTUnwrap(first.selectedPage as? TestPage)
            firstPage.capabilities.requiresCloseConfirmation = true
            firstPage.delayCloseRequest = true
            let firstNativeClose = try XCTUnwrap(firstPage.events.onClose)

            let second = app.newWindow(url: self.destination)
            second.activateSelected()
            let secondPage = try XCTUnwrap(second.selectedPage as? TestPage)
            secondPage.capabilities.requiresCloseConfirmation = true
            secondPage.delayCloseRequest = true
            let secondNativeClose = try XCTUnwrap(secondPage.events.onClose)

            let attempt = Task { await app.requestTerminationPreflight() }
            try await self.eventually { firstPage.closeRequest != nil }
            firstPage.state.lifecycle = .closed
            firstNativeClose()
            firstPage.finishCloseRequest(accepted: true)
            try await self.eventually { secondPage.closeRequest != nil }

            let added = app.newWindow(url: self.destination)
            added.activateSelected()
            let addedPage = try XCTUnwrap(added.selectedPage as? TestPage)
            addedPage.capabilities.requiresCloseConfirmation = true
            addedPage.delayCloseRequest = true

            secondPage.state.lifecycle = .closed
            secondNativeClose()
            secondPage.finishCloseRequest(accepted: true)

            let accepted = await attempt.value
            XCTAssertFalse(accepted)
            XCTAssertNil(addedPage.closeRequest)
            XCTAssertEqual(addedPage.state.lifecycle, .ready)
            XCTAssertTrue(added.selectedPage === addedPage)
        }
    }

    func testLatestAddressWinsDuringPreparationAndClosingRetiresReplacement() async throws {
        try await withApp { app, engines in
            engines[0].delayPreparation = true
            let window = app.windows[0]; window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            try await self.eventually { page.preparation != nil }
            window.addressDraft = "https://latest.example"; window.submitAddress()
            try await self.eventually { page.additionalPreparations.count == 1 }
            page.finishPreparation()
            try await self.eventually { !page.loadedURLs.isEmpty }
            XCTAssertEqual(page.loadedURLs, [URL(string: "https://latest.example")!])
            engines[1].delayPreparation = true
            window.confirmEngineSwitch = { _ in true }
            window.setEngine(self.secondID, for: page.tabID)
            try await self.eventually { engines[1].contexts.first?.pages.first?.preparation != nil }
            let replacement = engines[1].contexts[0].pages[0]
            window.closePages()
            XCTAssertEqual(replacement.state.lifecycle, .closed)
            XCTAssertTrue(replacement.loadedURLs.isEmpty)
        }
    }

    func testDelayedSwitchPreservesOrganizationAndCurrentEngineCancelsReplacement() async throws {
        try await withApp { app, engines in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let original = try XCTUnwrap(window.selectedPage)
            window.confirmEngineSwitch = { _ in true }
            engines[1].delayPreparation = true
            window.setEngine(self.secondID, for: original.tabID)
            try await self.eventually { engines[1].contexts.first?.pages.first?.preparation != nil }
            let cancelled = engines[1].contexts[0].pages[0]
            window.setEngine(.webKit, for: original.tabID)
            cancelled.finishPreparation()
            try await self.eventually { cancelled.state.lifecycle == .closed }
            XCTAssertTrue(window.selectedPage === original)
            XCTAssertEqual(window.selectedTab?.engineOverride, .webKit)

            window.setEngine(self.secondID, for: original.tabID)
            try await self.eventually { engines[1].contexts[0].pages.last?.preparation != nil }
            let replacement = try XCTUnwrap(engines[1].contexts[0].pages.last)
            app.addSpace(name: "Moved during preparation", profileID: window.record.profileID)
            let space = try XCTUnwrap(app.spaces.last)
            window.moveTab(original.tabID, to: space.id)
            window.pinTab(original.tabID)
            let savedID = try XCTUnwrap(window.selectedTab?.savedItemID)
            replacement.finishPreparation()
            try await self.eventually { window.selectedPage === replacement }
            XCTAssertEqual(window.selectedTab?.spaceID, space.id)
            XCTAssertEqual(window.selectedTab?.savedItemID, savedID)
        }
    }

    func testContextIsolationAndUnifiedHistoryWithEngineProvenance() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let normal = try XCTUnwrap(window.selectedPage)
            let another = app.newWindow(url: self.destination); another.activateSelected()
            XCTAssertEqual(another.selectedPage?.contextID, normal.contextID)
            let privateOne = app.newWindow(isPrivate: true, url: self.destination); privateOne.activateSelected()
            let privateTwo = app.newWindow(isPrivate: true, url: self.destination); privateTwo.activateSelected()
            XCTAssertNotEqual(privateOne.selectedPage?.contextID, privateTwo.selectedPage?.contextID)
            XCTAssertNotEqual(privateOne.selectedPage?.contextID, normal.contextID)
            normal.events.onVisit?(normal.tabID, self.destination.absoluteString, "Design")
            let privatePage = try XCTUnwrap(privateOne.selectedPage)
            privatePage.events.onVisit?(privatePage.tabID, "https://private.example", "Private")
            privatePage.events.onFavicon?(privatePage.tabID, self.destination, Data())
            app.library.bookmark(urlString: self.destination.absoluteString, title: "Design", profileID: Profile.defaultID)
            window.confirmEngineSwitch = { _ in true }
            window.setEngine(self.secondID, for: normal.tabID)
            try await self.eventually { window.selectedPage?.contextID.engineID == self.secondID }
            let replacement = try XCTUnwrap(window.selectedPage)
            replacement.events.onVisit?(replacement.tabID, self.destination.absoluteString, "Design in second engine")
            let history = app.library.search("", profileID: Profile.defaultID, historyOnly: true)
            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history.first?.engineID, self.secondID)
            XCTAssertEqual(history.first?.title, "Design in second engine")
            XCTAssertEqual(history.first?.isBookmark, true)
            XCTAssertFalse(app.snapshot.windows.contains { $0.id == privateOne.id || $0.id == privateTwo.id })
            XCTAssertTrue(app.savedItems.isEmpty)
        }
    }

    func testWebsiteDataListingDoesNotRecordEngineUse() async throws {
        try await withApp { app, _ in
            let profile = try XCTUnwrap(app.profiles.first { $0.id == Profile.defaultID })
            _ = try app.engines.context(engineID: .webKit, profile: profile, siteSettings: app.siteSettings)
            XCTAssertEqual(Set(app.snapshot.profileEngineUsage?.first { $0.profileID == profile.id }?.engineIDs ?? []),
                           [.webKit])
            let listing = await app.websiteData(profileID: Profile.defaultID)
            XCTAssertNil(listing.error)
            XCTAssertEqual(listing.sites.count, 1)
            XCTAssertEqual(listing.sites.first?.members.count, 3)
            XCTAssertEqual(Set(app.snapshot.profileEngineUsage?.first { $0.profileID == profile.id }?.engineIDs ?? []),
                           [.webKit])
        }
    }

    func testWebsiteDataGroupsStoresAndWaitsForCloseWhileBlockingActivation() async throws {
        try await withApp { app, engines in
            engines[0].delayClosure = true
            let window = app.windows[0]; window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            let listing = await app.websiteData(profileID: Profile.defaultID)
            XCTAssertNil(listing.error)
            XCTAssertEqual(listing.sites.count, 1)
            XCTAssertEqual(listing.sites.first?.members.count, 3)
            let site = try XCTUnwrap(listing.sites.first)
            engines[1].contexts[0].failRemoval = true
            let operation = Task { await app.clearWebsiteData(profileID: Profile.defaultID, site: site) }
            try await self.eventually { page.closure != nil }
            window.addTab(url: self.destination)
            XCTAssertNil(window.selectedPage)
            XCTAssertTrue(engines[0].contexts[0].removedIDs.isEmpty)
            page.finishClosure()
            let error = await operation.value
            XCTAssertTrue(error?.contains("Some website data") == true)
            XCTAssertEqual(engines[0].contexts[0].removedIDs.count, 1)
            XCTAssertEqual(engines[2].contexts[0].removedIDs.count, 1)
            for context in [engines[0].contexts[0], engines[2].contexts[0]] {
                XCTAssertEqual(context.dataRemovalRequests.first?.categories, [.siteData, .cache])
                guard case .records = context.dataRemovalRequests.first?.scope else {
                    return XCTFail("Per-site removal must keep record scope")
                }
            }
            XCTAssertTrue(app.suspendedContexts.isEmpty)
            XCTAssertEqual(window.record.tabs.first(where: { $0.id == page.tabID })?.isUnloaded, true)
            engines[0].delayClosure = false
            window.select(page.tabID)
            let reopened = try XCTUnwrap(window.selectedPage as? TestPage)
            XCTAssertFalse(reopened === page)
            XCTAssertNotEqual(window.selectedTab?.isUnloaded, true)
            engines[1].contexts[0].failRemoval = false
            let cacheError = await app.clearWebsiteData(profileID: Profile.defaultID)
            XCTAssertNil(cacheError)
            XCTAssertTrue(engines.allSatisfy { $0.contexts[0].cacheClears == 1 })
            XCTAssertEqual(window.selectedTab?.isUnloaded, true)
        }
    }

    func testWebsiteDataListingFailurePublishesNoActionableRowsButDoesNotBlockGlobalClear() async throws {
        try await withApp { app, engines in
            engines[1].websiteDataFailure = true
            let listing = await app.websiteData(profileID: Profile.defaultID)
            XCTAssertTrue(listing.sites.isEmpty)
            XCTAssertTrue(listing.error?.contains("Injected website-data listing failure") == true)

            let error = await app.clearWebsiteData(profileID: Profile.defaultID)
            XCTAssertNil(error)
            XCTAssertTrue(engines.allSatisfy { $0.contexts[0].cacheClears == 1 })
        }
    }

    #if COBBLE_CHROMIUM_ABI4
    func testChromiumPrivateContextDoesNotAdvertiseWebsiteDataRemoval() {
        XCTAssertFalse(ChromiumContext.capabilities(isPrivate: false).websiteDataRemoval.isEmpty)
        XCTAssertTrue(ChromiumContext.capabilities(isPrivate: true).websiteDataRemoval.isEmpty)
    }
    #endif

    func testWebsiteDataRejectsCrossProfileAndPrivateMembersBeforeUnloading() async throws {
        try await withApp { app, engines in
            engines[0].delayClosure = true
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            let listing = await app.websiteData(profileID: Profile.defaultID)
            let listedSite = try XCTUnwrap(listing.sites.first)
            let member = try XCTUnwrap(listedSite.members.first)

            for contextID in [
                BrowsingContextID(engineID: member.contextID.engineID,
                                  profileID: UUID(), privateWindowID: nil),
                BrowsingContextID(engineID: member.contextID.engineID,
                                  profileID: Profile.defaultID, privateWindowID: UUID()),
            ] {
                let site = WebsiteDataGroup(
                    displayName: listedSite.displayName,
                    members: [.init(contextID: contextID, recordID: member.recordID)])
                let error = await app.clearWebsiteData(profileID: Profile.defaultID, site: site)
                XCTAssertEqual(error, "Website data selection changed. Refresh and try again.")
                XCTAssertEqual(page.state.lifecycle, .ready)
                XCTAssertNil(page.closure)
                XCTAssertTrue(engines.flatMap(\.contexts).allSatisfy { $0.removedIDs.isEmpty })
                XCTAssertTrue(app.suspendedContexts.isEmpty)
            }
            page.delayClosure = false
        }
    }

    func testWebsiteDataPreflightsContextsAndCapabilitiesBeforeUnloading() async throws {
        try await withApp { app, engines in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)

            engines[1].contextCreationFailure = true
            let creationError = await app.clearWebsiteData(profileID: Profile.defaultID)
            XCTAssertTrue(creationError?.contains("Injected context-creation failure") == true)
            XCTAssertEqual(page.state.lifecycle, .ready)
            XCTAssertNil(page.closure)
            XCTAssertTrue(engines.flatMap(\.contexts).allSatisfy { $0.cacheClears == 0 })

            engines[1].contextCreationFailure = false
            let listing = await app.websiteData(profileID: Profile.defaultID)
            let site = try XCTUnwrap(listing.sites.first)
            engines[1].contexts[0].capabilitiesOverride = EngineCapabilities()
            let capabilityError = await app.clearWebsiteData(profileID: Profile.defaultID, site: site)
            XCTAssertEqual(capabilityError, "That website data range is not supported by every active engine.")
            XCTAssertEqual(page.state.lifecycle, .ready)
            XCTAssertNil(page.closure)
            XCTAssertTrue(engines.flatMap(\.contexts).allSatisfy { $0.removedIDs.isEmpty })
            XCTAssertTrue(app.suspendedContexts.isEmpty)
        }
    }

    func testRecentCacheRemovalForwardsExactCutoffToEveryEngine() async throws {
        try await withApp { app, engines in
            let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
            let error = await app.removeWebsiteData(profileID: Profile.defaultID,
                categories: [.cache], modifiedSince: cutoff)
            XCTAssertNil(error)
            let expected = WebsiteDataRemovalRequest(categories: [.cache], scope: .profile(modifiedSince: cutoff))
            XCTAssertTrue(engines.allSatisfy { $0.contexts[0].dataRemovalRequests == [expected] })
        }
    }

    func testUnsupportedRecentScopeRejectsBeforeUnloadingPages() async throws {
        try await withApp { app, engines in
            let profile = try XCTUnwrap(app.profiles.first { $0.id == Profile.defaultID })
            let limited = try app.engines.context(engineID: engines[1].id, profile: profile,
                siteSettings: app.siteSettings) as! TestContext
            limited.capabilitiesOverride = engines[1].capabilities
            limited.capabilitiesOverride?.websiteDataRemoval.remove(
                .init(categories: [.cache], scope: .profileSince))
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            let error = await app.removeWebsiteData(profileID: Profile.defaultID,
                categories: [.cache], modifiedSince: Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(error, "That website data range is not supported by every active engine.")
            XCTAssertEqual(page.state.lifecycle, .ready)
            XCTAssertNil(page.closure)
            XCTAssertTrue(engines.flatMap(\.contexts).allSatisfy { $0.dataRemovalRequests.isEmpty })
            XCTAssertTrue(app.suspendedContexts.isEmpty)
        }
    }

    func testRecentSiteDataIsRejectedWithoutWideningToAllTime() async throws {
        try await withApp { app, engines in
            let window = app.windows[0]
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            for categories: Set<WebsiteDataCategory> in [[.siteData], [.siteData, .cache]] {
                let error = await app.removeWebsiteData(profileID: Profile.defaultID,
                    categories: categories, modifiedSince: Date(timeIntervalSince1970: 1_700_000_000))
                XCTAssertEqual(error, "That website data range is not supported by every active engine.")
            }
            XCTAssertEqual(page.state.lifecycle, .ready)
            XCTAssertNil(page.closure)
            XCTAssertTrue(engines.flatMap(\.contexts).allSatisfy { $0.dataRemovalRequests.isEmpty })
        }
    }

    func testDataRemovalWaitsForPreviouslyRetiredPagesInAffectedContext() async throws {
        for clearCache in [false, true] {
            try await withApp { app, engines in
                engines[0].delayClosure = true
                let window = app.windows[0]; window.addTab(url: self.destination)
                let page = try XCTUnwrap(window.selectedPage as? TestPage)
                defer { page.finishClosure() }
                let listing = await app.websiteData(profileID: Profile.defaultID)
                let site = try XCTUnwrap(listing.sites.first)
                window.closeTab(page.tabID)
                try await self.eventually { page.closure != nil }
                var finished = false
                let removal = Task {
                    let error = await app.clearWebsiteData(profileID: Profile.defaultID, site: clearCache ? nil : site)
                    finished = true
                    return error
                }
                // Give an incorrectly unblocked removal time to finish as well.
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertFalse(finished)
                XCTAssertEqual(engines[0].contexts[0].cacheClears, 0)
                XCTAssertTrue(engines[0].contexts[0].removedIDs.isEmpty)
                engines[0].delayClosure = false
                window.addTab(url: self.destination)
                XCTAssertNil(window.selectedPage)
                page.finishClosure()
                let error = await removal.value
                XCTAssertNil(error)
                XCTAssertEqual(engines[0].contexts[0].cacheClears, clearCache ? 1 : 0)
                XCTAssertEqual(engines[0].contexts[0].removedIDs.count, clearCache ? 0 : 1)
                engines[0].delayClosure = false
            }
        }
    }

    func testContextRetirementAndDataRemovalIgnoreUnrelatedClosingPages() async throws {
        try await withApp { app, engines in
            engines[0].delayClosure = true
            let normal = app.windows[0]; normal.addTab(url: self.destination)
            let normalPage = try XCTUnwrap(normal.selectedPage as? TestPage)
            defer { normalPage.finishClosure() }
            normal.closeTab(normalPage.tabID)
            let privateWindow = app.newWindow(isPrivate: true, url: self.destination)
            privateWindow.activateSelected()
            let privatePage = try XCTUnwrap(privateWindow.selectedPage as? TestPage)
            defer { privatePage.finishClosure() }
            let privateContext = try XCTUnwrap(engines[0].contexts.last)
            app.closeWindow(privateWindow.id)
            try await self.eventually { privatePage.closure != nil }
            XCTAssertFalse(privateContext.closed, "A context must wait for its own page")
            privatePage.finishClosure()
            try await self.eventually { privateContext.closed }
            XCTAssertEqual(normalPage.state.lifecycle, .closing)

            let listing = await app.websiteData(profileID: Profile.defaultID)
            var site = try XCTUnwrap(listing.sites.first)
            site.members.removeAll { $0.contextID.engineID != self.secondID }
            var removalFinished = false
            let removal = Task {
                let error = await app.clearWebsiteData(profileID: Profile.defaultID, site: site)
                XCTAssertNil(error)
                removalFinished = true
            }
            try await self.eventually { removalFinished }
            await removal.value
            XCTAssertEqual(normalPage.state.lifecycle, .closing)

            var shutdownFinished = false
            let shutdown = Task { await app.engines.shutdown(); shutdownFinished = true }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(shutdownFinished)
            normalPage.finishClosure()
            await shutdown.value
            XCTAssertTrue(shutdownFinished)
        }
    }

    func testPermissionGroupsStayIsolatedAndExplicitEditsApplyAcrossSupportedEngines() async throws {
        try await withApp { app, engines in
            let store = app.siteSettings
            store.update(SiteSetting(profileID: Profile.defaultID, origin: self.destination.absoluteString,
                                     camera: .allow, engineID: .webKit))
            XCTAssertEqual(store.setting(origin: self.destination, profileID: Profile.defaultID, engineID: self.secondID).camera, .ask)
            XCTAssertNil(store.summaries(profileID: Profile.defaultID, engines: engines).first?.camera)
            store.update(origin: self.destination.absoluteString, profileID: Profile.defaultID, camera: .deny, engines: engines)
            XCTAssertEqual(store.summaries(profileID: Profile.defaultID, engines: engines).first?.camera, .deny)
            let setting = store.setting(origin: self.destination, profileID: Profile.defaultID)
            XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.camera], setting: setting, isPrivate: true, sameOrigin: true), .ask)
            store.forget(origin: "https://figma.com", profileID: Profile.defaultID)
            XCTAssertTrue(store.entries.isEmpty)
        }
    }

    func testDisplayCaptureStateIsDisclosedWithoutAdvertisingControls() async throws {
        try await withApp { app, _ in
            let window = try XCTUnwrap(app.windows.first)
            window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities = EngineCapabilities()
            page.state.isDisplayCapturing = true
            let controls = SiteControlPopover(window: window)
            XCTAssertTrue(controls.showsDisplayCapture)
            XCTAssertEqual(controls.displayCaptureDisclosure,
                "Cobble can show that this page is sharing your screen, but cannot stop or change it here.")
            XCTAssertTrue(page.capabilities.permissions.isEmpty)
            XCTAssertTrue(page.capabilities.captureControls.isEmpty)
        }
    }

    func testUnsupportedCommandsAreDisabledAndDownloadsOutliveTabs() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]; window.addTab(url: self.destination)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            XCTAssertFalse(window.canPerform(.printPage))
            XCTAssertFalse(window.perform(.printPage))
            XCTAssertEqual(page.prints, 0)
            page.capabilities.pageOperations.insert(.printPage)
            XCTAssertTrue(window.perform(.printPage))
            XCTAssertEqual(page.prints, 1)
            let transfer = TestDownload()
            page.events.onDownload?(transfer)
            XCTAssertEqual(app.downloads.entries.count, 1)
            window.closeTab(page.tabID)
            XCTAssertFalse(transfer.cancelled)
            transfer.onProgress?(nil)
            XCTAssertNil(app.downloads.entries[0].progress)
            transfer.onProgress?(0.5)
            XCTAssertEqual(app.downloads.entries[0].progress, 0.5)
            app.downloads.cancel(id: app.downloads.entries[0].id)
            XCTAssertTrue(transfer.cancelled)
            XCTAssertTrue(transfer.detached)
        }
    }

    func testLegacyAndUnknownEngineRecordsRoundTripWithoutFallback() async throws {
        try await withApp { app, _ in
            var snapshot = app.snapshot
            snapshot.windows[0].tabs = [Tab(urlString: self.destination.absoluteString, title: "Design")]
            snapshot.windows[0].selectedTabID = snapshot.windows[0].tabs[0].id
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            json["version"] = 1
            var windows = json["windows"] as! [[String: Any]]
            var tabs = windows[0]["tabs"] as! [[String: Any]]
            tabs[0].removeValue(forKey: "engineID"); windows[0]["tabs"] = tabs; json["windows"] = windows
            let data = try JSONSerialization.data(withJSONObject: json)
            let migrated = try SessionSnapshot.decode(data)
            let legacy = try JSONSerialization.data(withJSONObject: ["tabs": [["id": UUID().uuidString, "urlString": self.destination.absoluteString, "title": "Legacy"]]])
            XCTAssertEqual(try SessionSnapshot.decode(legacy).windows[0].tabs[0].engineID, .webKit)
            XCTAssertEqual(migrated.version, SessionSnapshot.currentVersion)
            XCTAssertEqual(migrated.windows[0].tabs[0].engineID, .webKit)
            try data.write(to: app.store.url)
            let loaded = SessionStore(directory: app.store.directory).load()
            XCTAssertEqual(loaded.snapshot?.windows[0].tabs[0].engineID, .webKit)
            try app.replaceWorkspace(with: migrated)
            let missing = EngineID(rawValue: "future.engine")
            app.windows[0].record.tabs[0].engineID = missing
            app.windows[0].activateSelected()
            XCTAssertNil(app.windows[0].selectedPage)
            XCTAssertTrue(app.windows[0].addressError?.contains("unavailable") == true)
            let preserved = try SessionSnapshot.decode(JSONEncoder().encode(app.snapshot))
            XCTAssertEqual(preserved.windows[0].tabs[0].engineID, missing)
        }
    }

    func testLegacyPermissionAndFutureLibraryDataArePreserved() async throws {
        try await withApp { app, _ in
            let setting = SiteSetting(profileID: Profile.defaultID, origin: "https://figma.com", camera: .allow)
            var legacyEntry = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setting)) as? [String: Any])
            legacyEntry.removeValue(forKey: "engineID")
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [legacyEntry]])
            let permissionURL = app.store.directory.appendingPathComponent("site-settings.json")
            try data.write(to: permissionURL)
            let migrated = SiteSettingsStore(directory: app.store.directory)
            XCTAssertEqual(migrated.setting(origin: self.destination, profileID: Profile.defaultID).camera, .allow)
            XCTAssertEqual(migrated.setting(origin: self.destination, profileID: Profile.defaultID, engineID: self.thirdID).camera, .ask)
            XCTAssertEqual(try Data(contentsOf: permissionURL), data)
            var database: OpaquePointer?
            let path = app.store.directory.appendingPathComponent("library.sqlite").path
            XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
            let future = LibraryStore(directory: app.store.directory)
            XCTAssertNotNil(future.lastError)
            future.recordVisit(urlString: self.destination.absoluteString, title: "Must not write", profileID: Profile.defaultID)
            XCTAssertNotNil(future.lastError)
            var query: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &query, nil), SQLITE_OK)
            defer { sqlite3_finalize(query) }
            XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(query, 0), 999)
        }
    }

    func testWorkspaceRestoreReplacesContextsWhenStoreBindingChanges() async throws {
        try await withApp { app, engines in
            let work = Profile(name: "Work", storeBinding: .named(UUID()))
            let workSpace = Space(profileID: work.id, name: "Work")
            let tab = Tab(spaceID: workSpace.id, urlString: self.destination.absoluteString, title: "Figma")
            try app.replaceWorkspace(with: SessionSnapshot(profiles: [Profile(id: Profile.defaultID), work],
                                                           spaces: [Space(id: Space.defaultID), workSpace],
                                                           windows: [WindowRecord(profileID: work.id,
                                                                                 selectedSpaceID: workSpace.id,
                                                                                 selectedTabID: tab.id,
                                                                                 tabs: [tab])]))
            let window = app.windows[0]; window.activateSelected()
            let old = try XCTUnwrap(engines[0].contexts.first)
            var snapshot = app.snapshot
            let workIndex = try XCTUnwrap(snapshot.profiles.firstIndex { $0.id == work.id })
            snapshot.profiles[workIndex].storeBinding = .named(UUID())
            try app.replaceWorkspace(with: snapshot)
            app.windows[0].activateSelected()
            XCTAssertEqual(engines[0].contexts.count, 2)
            try await self.eventually { old.closed }
            XCTAssertFalse(engines[0].contexts[1].closed)
            XCTAssertEqual(app.windows[0].selectedPage?.contextID.profileID, work.id)
        }
    }

    func testSourceBoundaryHasNoRenderingSDKDependencies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = try NSRegularExpression(pattern: #"\b(import\s+(?:WebKit|CobbleChromium)|WK[A-Z]\w*|WebKit[A-Z]\w*|Chromium[A-Z]\w*|CCS_\w+)\b"#)
        for dependency in ["import WebKit", "import CobbleChromium", "WKWebView", "WebKitPage",
                           "WebKitContext", "ChromiumPage", "ChromiumRuntime", "CobbleChromium.ChromiumContext"] {
            XCTAssertNotNil(forbidden.firstMatch(in: dependency, range: NSRange(dependency.startIndex..., in: dependency)))
        }
        for directory in ["Browser", "Domain", "Persistence", "UI", "Engine/Contracts", "Engine/Shared"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)!
            for case let url as URL in files where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                XCTAssertNil(forbidden.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), url.path)
            }
        }
    }
}

@MainActor final class TestEngine: BrowserEngine {
    let id: EngineID
    var name: String { id.rawValue }
    var capabilities = EngineCapabilities(permissions: [.camera, .microphone],
                                          captureControls: [.mute(.camera), .stop(.camera), .mute(.microphone), .stop(.microphone)],
                                          websiteDataRemoval: WebKitContext.dataRemovalCapabilities,
                                          supportsProfileDeletion: true)
    var contentBlocker: (any EngineContentBlocker)? { nil }
    var contexts: [TestContext] = []
    var prepareFailure = false
    var profileDeletionPreflightFailure = false
    var profileDeletionFailure = false
    var localFileFailure = false
    var delayLocalFile = false
    var delayPreparation = false
    var delayClosure = false
    var contextCreationFailure = false
    var websiteDataFailure = false
    init(_ id: EngineID) { self.id = id }
    func makeContext(profile: Profile, id: BrowsingContextID, siteSettings: SiteSettingsStore) throws -> any EngineContext {
        if contextCreationFailure { throw EngineError.notReady("Injected context-creation failure") }
        let context = TestContext(id: id, engine: self); contexts.append(context); return context
    }
    var removedProfiles: [UUID] = []
    func preflightProfileDeletion(_: Profile) async throws {
        if profileDeletionPreflightFailure {
            throw EngineError.notReady("Injected profile-deletion preflight failure")
        }
    }
    func removeProfile(_ profile: Profile) async throws {
        if profileDeletionFailure { throw EngineError.notReady("Injected profile-deletion failure") }
        removedProfiles.append(profile.id)
    }
    func shutdown() async { contexts.removeAll() }
}

@MainActor final class TestContext: EngineContext {
    let id: BrowsingContextID
    unowned let engine: TestEngine
    var capabilitiesOverride: EngineCapabilities?
    var capabilities: EngineCapabilities { capabilitiesOverride ?? engine.capabilities }
    var pages: [TestPage] = []
    var removedIDs: [UUID] = []
    var cacheClears = 0
    var dataRemovalRequests: [WebsiteDataRemovalRequest] = []
    var failRemoval = false
    var closed = false
    var pageWindowIDs: [UUID] = []
    var cookieSnapshot = CookieTransferSnapshot(cookies: [])
    var cookieSnapshotsByHost: [String: CookieTransferSnapshot] = [:]
    var cookieReplacementHosts: [String] = []
    var cookieExports = 0
    var cookieReplacements: [[EngineCookie]] = []
    var cookieRejections = 0
    var onCookieExport: (() async -> Void)?
    var onCookieReplace: (() -> Void)?
    let data = WebsiteDataRecord(id: UUID(), displayName: "figma.com")
    init(id: BrowsingContextID, engine: TestEngine) { self.id = id; self.engine = engine }
    func makePage(tabID: UUID, windowID: UUID) throws -> any BrowserPage {
        pageWindowIDs.append(windowID)
        let page = TestPage(tabID: tabID, contextID: id)
        page.prepareFailure = engine.prepareFailure; page.delayPreparation = engine.delayPreparation
        page.delayClosure = engine.delayClosure
        page.localFileFailure = engine.localFileFailure
        page.delayLocalFile = engine.delayLocalFile
        page.state.lifecycle = page.delayPreparation || page.prepareFailure ? .preparing : .ready
        pages.append(page); return page
    }
    func websiteData() async throws -> [WebsiteDataRecord] {
        if engine.websiteDataFailure { throw EngineError.notReady("Injected website-data listing failure") }
        return [data]
    }
    func exportCookies(for url: URL) async throws -> CookieTransferSnapshot {
        cookieExports += 1
        await onCookieExport?()
        return cookieSnapshotsByHost[url.host() ?? ""] ?? cookieSnapshot
    }
    func replaceCookies(_ cookies: [EngineCookie], for url: URL) async throws -> Int {
        onCookieReplace?()
        cookieReplacementHosts.append(url.host() ?? "")
        cookieReplacements.append(cookies)
        return cookieRejections
    }
    func removeWebsiteData(_ request: WebsiteDataRemovalRequest) async throws {
        if failRemoval { throw EngineError.notReady("Removal failed") }
        dataRemovalRequests.append(request)
        switch request.scope {
        case .records(let ids): removedIDs += ids
        case .profile:
            if request.categories == [.cache] { cacheClears += 1 }
        }
    }
    func close() async { closed = true }
}

@MainActor final class TestPage: BrowserPage {
    let tabID: UUID
    let contextID: BrowsingContextID
    let nativeView = NSView()
    let state = PageState()
    let events = PageEvents()
    var capabilities = EngineCapabilities()
    var movedWindowIDs: [UUID] = []
    var onMoveToWindow: ((UUID) -> Void)?
    var loadedURLs: [URL] = []
    var prints = 0
    var findRequests: [(String, Bool)] = []
    var prepareFailure = false
    var delayPreparation = false
    var delayClosure = false
    var delayCloseRequest = false
    var delayArchive = false
    var delayDOM = false
    var localFileFailure = false
    var delayLocalFile = false
    var closeRequestResult = true
    var closeRequestCount = 0
    var captureRequests: [(PermissionKind, PageCapture)] = []
    var stopMediaCaptureCount = 0
    var stopMediaCaptureSucceeds = true
    var devToolsSession: (any PageDevToolsSession)?
    var devToolsHostWindowIDs: [UUID] = []
    var connectionDetailsValue: PageConnectionDetails?
    var preparation: CheckedContinuation<Void, Never>?
    var additionalPreparations: [CheckedContinuation<Void, Never>] = []
    var closure: CheckedContinuation<Void, Never>?
    var closeRequest: CheckedContinuation<Bool, Never>?
    var archiveContinuation: CheckedContinuation<Data, Error>?
    var domContinuation: CheckedContinuation<String, Error>?
    var localFileContinuation: CheckedContinuation<Void, Error>?
    init(tabID: UUID, contextID: BrowsingContextID) {
        self.tabID = tabID; self.contextID = contextID; state.lifecycle = .ready
    }
    func prepare() async throws {
        if delayPreparation {
            await withCheckedContinuation {
                if preparation == nil { preparation = $0 } else { additionalPreparations.append($0) }
            }
        }
        if prepareFailure { throw EngineError.notReady("Preparation failed") }
        guard state.lifecycle != .closed && state.lifecycle != .closing else { throw EngineError.closed }
        state.lifecycle = .ready
    }
    func finishPreparation() {
        preparation?.resume(); preparation = nil
        additionalPreparations.forEach { $0.resume() }; additionalPreparations.removeAll()
    }
    func navigate(to url: URL?) {
        guard let url else { return }
        loadedURLs.append(url); state.urlString = url.absoluteString
        events.onChange?(tabID, url.absoluteString, url.host ?? "Page")
    }
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stop() {}
    func find(_ text: String, backwards: Bool) { findRequests.append((text, backwards)) }
    func zoom(by factor: Double) {}
    func resetZoom() {}
    func printPage() { prints += 1 }
    func setCapture(_ kind: PermissionKind, _ capture: PageCapture) { captureRequests.append((kind, capture)) }
    @discardableResult func stopMediaCapture() -> Bool {
        stopMediaCaptureCount += 1
        return stopMediaCaptureSucceeds
    }
    func openDevTools(hostWindowID: UUID) throws -> any PageDevToolsSession {
        devToolsHostWindowIDs.append(hostWindowID)
        guard let devToolsSession else { throw EngineError.unsupported("Developer Tools") }
        return devToolsSession
    }
    func moveToWindow(_ windowID: UUID) throws {
        onMoveToWindow?(windowID)
        movedWindowIDs.append(windowID)
    }
    func applyContentRules() {}
    func openLocalFile(_ url: URL) async throws {
        if localFileFailure { throw EngineError.notReady("Injected local-file failure") }
        if delayLocalFile {
            try await withCheckedThrowingContinuation { localFileContinuation = $0 }
        }
        state.urlString = url.absoluteString
    }
    func finishLocalFile(_ result: Result<Void, Error>) {
        localFileContinuation?.resume(with: result)
        localFileContinuation = nil
    }
    func pageArchive() async throws -> Data {
        if delayArchive { return try await withCheckedThrowingContinuation { archiveContinuation = $0 } }
        return Data()
    }
    func currentDOM() async throws -> String {
        if delayDOM { return try await withCheckedThrowingContinuation { domContinuation = $0 } }
        return "<html></html>"
    }
    func connectionDetails() async throws -> PageConnectionDetails? { connectionDetailsValue }
    func finishArchive(_ result: Result<Data, Error>) { archiveContinuation?.resume(with: result); archiveContinuation = nil }
    func finishDOM(_ result: Result<String, Error>) { domContinuation?.resume(with: result); domContinuation = nil }
    func requestClose() async -> Bool {
        closeRequestCount += 1
        if delayCloseRequest {
            return await withCheckedContinuation { closeRequest = $0 }
        }
        return closeRequestResult
    }
    func finishCloseRequest(accepted: Bool) {
        closeRequest?.resume(returning: accepted); closeRequest = nil
    }
    func close() { events.clear(); state.lifecycle = delayClosure ? .closing : .closed; finishPreparation() }
    func waitUntilClosed() async {
        if state.lifecycle == .closing {
            // Several owners may await teardown; observe the same completion.
            if closure == nil { await withCheckedContinuation { closure = $0 } }
            else { while state.lifecycle != .closed { await Task.yield() } }
        }
    }
    func finishClosure() { state.lifecycle = .closed; closure?.resume(); closure = nil }
}

@MainActor private final class TestDownload: EngineDownload {
    let id = UUID()
    let suggestedFilename = "file.txt"
    var window: NSWindow? { nil }
    var onProgress: ((Double?) -> Void)?
    var onDestination: ((String, @escaping (URL?) -> Void) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var cancelled = false
    var detached = false
    func start() {}
    func cancel(completion: @escaping () -> Void) { cancelled = true; completion() }
    func detach() { detached = true; onProgress = nil; onDestination = nil; onFinish = nil; onFailure = nil }
}
