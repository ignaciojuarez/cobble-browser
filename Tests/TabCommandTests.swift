import AppKit
import XCTest
import WebKit
@testable import Cobble

@MainActor
final class TabCommandTests: XCTestCase {
    func testUnreadablePreferencesRequireBackupBeforeRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("browser-preferences.json")
        for source in ["not JSON", #"{"version":999,"futureSetting":true}"#] {
            let original = Data(source.utf8)
            try original.write(to: url)
            let preferences = BrowserPreferences(directory: directory)
            let readError = try XCTUnwrap(preferences.readError)
            XCTAssertEqual(preferences.persistenceStatus, .readOnly(readError))
            XCTAssertFalse(preferences.setDefaultEngine(EngineID(rawValue: "chromium")))
            XCTAssertFalse(preferences.setExperimentalLoginSharing(true))
            XCTAssertEqual(preferences.errorMessage, readError)
            XCTAssertEqual(try Data(contentsOf: url), original)

            let backup = try XCTUnwrap(preferences.resetUnreadableSettings())
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertNil(preferences.readError)
            XCTAssertEqual(preferences.persistenceStatus, .writable)
            XCTAssertTrue(preferences.setDefaultEngine(EngineID(rawValue: "chromium")))
            XCTAssertTrue(preferences.setExperimentalLoginSharing(true))
            let reloaded = BrowserPreferences(directory: directory)
            XCTAssertNil(reloaded.readError)
            XCTAssertEqual(reloaded.defaultEngine, EngineID(rawValue: "chromium"))
            XCTAssertTrue(reloaded.experimentalLoginSharing)
            XCTAssertNil(preferences.resetUnreadableSettings())
        }
        try Data("not JSON".utf8).write(to: url)
        let preferences = BrowserPreferences(directory: directory)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(preferences.resetUnreadableSettings(), "A failed backup must not enable writes")
        XCTAssertNotNil(preferences.readError)
        XCTAssertFalse(preferences.setExperimentalLoginSharing(true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeveloperToolsCommandRequiresOptInCapabilityAndNoPrompt() async throws {
        try await withTestApp(SessionSnapshot(windows: [WindowRecord()])) { app, engine in
            let window = try XCTUnwrap(app.windows.first)
            window.addTab(url: URL(string: "https://example.com")!)
            let page = try XCTUnwrap(engine.contexts.first?.pages.first)
            XCTAssertFalse(window.canPerform(.openDevTools))
            XCTAssertTrue(app.preferences.setWebInspectorEnabled(true))
            XCTAssertFalse(window.canPerform(.openDevTools))
            page.capabilities.pageOperations.insert(.openDevTools)
            XCTAssertTrue(window.canPerform(.openDevTools))
            var openedPage: (any BrowserPage)?
            window.onOpenDevTools = { openedPage = $0; return true }
            XCTAssertTrue(window.perform(.openDevTools))
            XCTAssertTrue(openedPage === page)
            page.state.hasPendingPrompt = true
            XCTAssertFalse(window.canPerform(.openDevTools))
            XCTAssertFalse(window.perform(.openDevTools))
        }
    }

    func testDeveloperToolsWindowWaitsForNativeCloseAndReportsOnce() throws {
        let hostID = UUID()
        let session = TestPageDevToolsSession(delayedClose: true)
        var page: TestPage? = TestPage(tabID: UUID(), contextID: BrowsingContextID(engineID: .webKit,
            profileID: Profile.defaultID, privateWindowID: nil))
        weak var retainedPage = page
        var closedHostIDs: [UUID] = []
        let controller = DevToolsWindowController(hostWindowID: hostID, page: try XCTUnwrap(page),
            pageTitle: "Fixture") { closedHostIDs.append($0) }
        page = nil
        let window = try XCTUnwrap(controller.window)
        try controller.attach(session)
        XCTAssertTrue(session.nativeView.superview === window.contentView)
        controller.closeSession()
        controller.closeSession()
        XCTAssertEqual(session.closeCount, 1)
        XCTAssertFalse(session.isClosed)
        XCTAssertTrue(session.nativeView.superview === window.contentView)
        XCTAssertTrue(closedHostIDs.isEmpty)
        XCTAssertNotNil(retainedPage)
        session.finishClose()
        XCTAssertEqual(closedHostIDs, [hostID])
        XCTAssertNil(session.nativeView.superview)
        XCTAssertNil(retainedPage)
    }

    func testDeveloperToolsWindowHandlesUnsolicitedNativeCloseOnce() throws {
        let hostID = UUID()
        let session = TestPageDevToolsSession(delayedClose: true)
        let page = TestPage(tabID: UUID(), contextID: BrowsingContextID(engineID: .webKit,
            profileID: Profile.defaultID, privateWindowID: nil))
        var closedHostIDs: [UUID] = []
        let controller = DevToolsWindowController(hostWindowID: hostID, page: page,
            pageTitle: "Fixture") { closedHostIDs.append($0) }
        try controller.attach(session)
        session.finishClose()
        session.finishClose()
        XCTAssertEqual(session.closeCount, 0)
        XCTAssertEqual(closedHostIDs, [hostID])
        XCTAssertNil(session.nativeView.superview)
    }

    func testDeveloperToolsAttachRejectsAlreadyClosedSessionAndRetiresHost() {
        let hostID = UUID()
        let session = TestPageDevToolsSession(initiallyClosed: true)
        let page = TestPage(tabID: UUID(), contextID: BrowsingContextID(engineID: .webKit,
            profileID: Profile.defaultID, privateWindowID: nil))
        var closedHostIDs: [UUID] = []
        let controller = DevToolsWindowController(hostWindowID: hostID, page: page,
            pageTitle: "Fixture") { closedHostIDs.append($0) }
        XCTAssertThrowsError(try controller.attach(session))
        controller.closeWithoutSession()
        XCTAssertEqual(closedHostIDs, [hostID])
        XCTAssertNil(session.nativeView.superview)
    }

    func testAdjacentInsertionPreferenceAndSavedRowFallbackPersist() throws {
        let a = Tab(title: "A"), b = Tab(title: "B")
        let favorite = SavedItem(title: "Favorite")
        try withApp(SessionSnapshot(savedItems: [favorite], windows: [WindowRecord(selectedTabID: a.id, tabs: [a, b])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            XCTAssertFalse(app.preferences.newTabsNextToActive)
            XCTAssertTrue(app.preferences.setNewTabsNextToActive(true))
            window.duplicateTab(a.id)
            let duplicate = try XCTUnwrap(window.selectedTab?.id)
            XCTAssertEqual(window.visibleTabs.map(\.id), [a.id, duplicate, b.id])
            window.select(a.id)
            let opener = try XCTUnwrap(window.selectedPage)
            let child = TestPage(tabID: UUID(), contextID: opener.contextID)
            XCTAssertTrue(opener.events.onCreatePage?(child) == true)
            XCTAssertEqual(window.visibleTabs.map(\.id), [a.id, child.tabID, duplicate, b.id])
            XCTAssertTrue(window.selectedPage === child)
            window.openSavedItem(favorite.id)
            window.duplicateTab(try XCTUnwrap(window.selectedTab?.id))
            XCTAssertEqual(window.visibleTabs.last?.id, window.selectedTab?.id)
            XCTAssertTrue(app.preferences.setCycleAllRecentTabs(true))
            let reloaded = BrowserPreferences(directory: app.store.directory)
            XCTAssertTrue(reloaded.newTabsNextToActive)
            XCTAssertTrue(reloaded.cycleAllRecentTabs)
        }
    }

    func testRecentCycleKeepsStableOrderUntilReleasedAndDropsClosedTabs() throws {
        let a = Tab(title: "A"), b = Tab(title: "B"), c = Tab(title: "C")
        try withApp(SessionSnapshot(windows: [WindowRecord(selectedTabID: a.id, tabs: [a, b, c])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.select(b.id)
            window.select(c.id)
            window.select(a.id)
            window.cycleRecentTab()
            XCTAssertEqual(window.selectedTab?.id, c.id)
            window.cycleRecentTab()
            XCTAssertEqual(window.selectedTab?.id, b.id)
            window.cycleRecentTab(backwards: true)
            XCTAssertEqual(window.selectedTab?.id, c.id)
            window.endRecentTabCycle()
            window.cycleRecentTab()
            XCTAssertEqual(window.selectedTab?.id, a.id, "Previewing B must not make it more recent than the committed A")
            window.closeTab(b.id)
            window.cycleRecentTab()
            XCTAssertEqual(window.selectedTab?.id, c.id)
            window.select(a.id)
            window.cycleRecentTab()
            XCTAssertEqual(window.selectedTab?.id, c.id)
        }
    }

    func testSpaceSwitchRestoresItsLastSelectedTabBeforePins() throws {
        let work = Space(name: "Work")
        let homePin = SavedItem(spaceID: Space.defaultID, title: "Home pin")
        let workPin = SavedItem(spaceID: work.id, title: "Work pin")
        let homeA = Tab(title: "Home A")
        let homeB = Tab(title: "Home B")
        let pinnedHome = Tab(savedItemID: homePin.id)
        let workTab = Tab(spaceID: work.id, title: "Work tab")
        let pinnedWork = Tab(spaceID: work.id, savedItemID: workPin.id)
        let record = WindowRecord(selectedTabID: homeB.id,
            tabs: [homeA, homeB, pinnedHome, workTab, pinnedWork])
        try withApp(SessionSnapshot(spaces: [Space(id: Space.defaultID), work],
                                    savedItems: [homePin, workPin], windows: [record])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.selectSpace(work.id)
            XCTAssertEqual(window.selectedTab?.id, workTab.id)
            window.selectSpace(Space.defaultID)
            XCTAssertEqual(window.selectedTab?.id, homeB.id)
        }
    }

    func testDirectionalCloseUsesSidebarOrderAndProtectsSavedItemsAndOtherSpaces() throws {
        let favorite = SavedItem(title: "Favorite")
        let a = Tab(title: "Above"), b = Tab(title: "Selected"), c = Tab(title: "Below")
        let other = Space(name: "Other")
        let hidden = Tab(spaceID: other.id, title: "Other space")
        let saved = Tab(title: "Favorite", savedItemID: favorite.id)
        try withApp(SessionSnapshot(spaces: [Space(id: Space.defaultID), other], savedItems: [favorite],
            windows: [WindowRecord(selectedTabID: b.id, tabs: [a, saved, b, hidden, c])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            XCTAssertEqual(window.directionalTemporaryTabIDs(above: true), [a.id])
            XCTAssertEqual(window.directionalTemporaryTabIDs(above: false), [c.id])
            XCTAssertTrue(window.perform(.closeTabsAbove))
            XCTAssertTrue(window.perform(.closeTabsBelow))
            XCTAssertEqual(window.record.tabs.map(\.id), [saved.id, b.id, hidden.id])
            XCTAssertEqual(window.selectedTab?.id, b.id)
            XCTAssertFalse(window.canPerform(.closeTabsBelow))
            window.reopenClosedTab()
            XCTAssertEqual(window.selectedTab?.id, c.id)
            window.select(saved.id)
            XCTAssertTrue(window.directionalTemporaryTabIDs(above: true).isEmpty)
            XCTAssertEqual(window.directionalTemporaryTabIDs(above: false), [b.id, c.id])
        }
    }

    func testTemporarySelectionRangesMoveOnlyTemporaryTabsAndResetsAcrossSpaces() throws {
        let other = Space(name: "Other")
        let secondProfile = Profile(name: "Second", storeBinding: .named(UUID()))
        let secondSpace = Space(profileID: secondProfile.id, name: "Second Home")
        let saved = SavedItem(title: "Saved")
        let a = Tab(title: "A"), b = Tab(title: "B"), c = Tab(title: "C")
        let secondTab = Tab(spaceID: secondSpace.id, title: "Second")
        try withApp(SessionSnapshot(profiles: [Profile(id: Profile.defaultID), secondProfile],
            spaces: [Space(id: Space.defaultID), other, secondSpace], savedItems: [saved],
            windows: [WindowRecord(selectedTabID: a.id, tabs: [a, Tab(savedItemID: saved.id), b, c]),
                      WindowRecord(profileID: secondProfile.id, selectedSpaceID: secondSpace.id,
                                   selectedTabID: secondTab.id, tabs: [secondTab])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            let unaffectedWindow = try XCTUnwrap(app.windows.last)
            window.selectTemporaryTab(c.id, modifiers: [.command])
            window.selectTemporaryTab(c.id, modifiers: [.command])
            window.selectTemporaryTab(b.id, modifiers: [.shift])
            XCTAssertEqual(window.selectedTemporaryTabs.map(\.id), [a.id, b.id])
            window.selectTemporaryTab(c.id, modifiers: [.shift])
            XCTAssertEqual(window.selectedTemporaryTabs.map(\.id), [a.id, b.id, c.id])
            window.moveSelectedTemporaryTabs(to: other.id)
            XCTAssertEqual(window.record.tabs.filter { $0.savedItemID == nil }.map(\.spaceID), [other.id, other.id, other.id])
            XCTAssertEqual(window.record.tabs.first(where: { $0.savedItemID == saved.id })?.spaceID, Space.defaultID)
            XCTAssertTrue(window.selectedTemporaryTabs.isEmpty)
            XCTAssertEqual(window.record.selectedSpaceID, other.id)
            window.selectTemporaryTab(a.id)
            window.selectTemporaryTab(b.id, modifiers: [.command])
            app.deleteSpace(other.id)
            XCTAssertEqual(window.selectedTemporaryTabs.map(\.id), [b.id],
                           "Space deletion clears multi-selection and keeps the most recently active moved tab")
            XCTAssertEqual(window.record.selectedSpaceID, Space.defaultID)
            XCTAssertEqual(unaffectedWindow.selectedTemporaryTabs.map(\.id), [secondTab.id])
            XCTAssertEqual(unaffectedWindow.record.selectedSpaceID, secondSpace.id)
        }
    }

    func testSelectedCloseSerializesNativeConfirmationAndContinuesAfterRefusal() async throws {
        let a = Tab(title: "A"), b = Tab(title: "B")
        try await withTestApp(SessionSnapshot(windows: [WindowRecord(selectedTabID: a.id, tabs: [a, b])])) { app, engine in
            let window = try XCTUnwrap(app.windows.first)
            window.select(a.id)
            window.selectTemporaryTab(b.id, modifiers: [.command])
            let pages = Dictionary(uniqueKeysWithValues: engine.contexts[0].pages.map { ($0.tabID, $0) })
            let first = try XCTUnwrap(pages[a.id])
            let second = try XCTUnwrap(pages[b.id])
            first.capabilities.requiresCloseConfirmation = true
            first.delayCloseRequest = true
            second.capabilities.requiresCloseConfirmation = true
            window.closeSelectedTemporaryTabs()
            for _ in 0..<200 where first.closeRequestCount == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(first.closeRequestCount, 1)
            XCTAssertEqual(second.closeRequestCount, 0)
            first.finishCloseRequest(accepted: false)
            for _ in 0..<200 where window.record.tabs.contains(where: { $0.id == b.id }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(second.closeRequestCount, 1)
            XCTAssertTrue(window.record.tabs.contains { $0.id == a.id })
            XCTAssertFalse(window.record.tabs.contains { $0.id == b.id })
            XCTAssertEqual(window.selectedTemporaryTabs.map(\.id), [a.id])
        }
    }

    func testTemporaryBatchActionsIgnoreADeletingProfile() async throws {
        let profile = Profile(name: "Deleting", storeBinding: .named(UUID()))
        let home = Space(profileID: profile.id, name: "Home")
        let destination = Space(profileID: profile.id, name: "Destination")
        let a = Tab(spaceID: home.id, title: "A"), b = Tab(spaceID: home.id, title: "B")
        try await withTestApp(SessionSnapshot(profiles: [Profile(id: Profile.defaultID), profile],
            spaces: [Space(id: Space.defaultID), home, destination],
            windows: [WindowRecord(profileID: profile.id, selectedSpaceID: home.id,
                                   selectedTabID: a.id, tabs: [a, b])])) { app, engine in
            let window = try XCTUnwrap(app.windows.first)
            window.select(a.id)
            let page = try XCTUnwrap(engine.contexts[0].pages.first)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let deletion = Task { await app.deleteProfile(profile.id) }
            await Task.yield()
            await Task.yield()
            XCTAssertTrue(app.isDeletingProfile(profile.id))
            window.selectTemporaryTab(b.id, modifiers: [.command])
            window.moveTab(a.id, to: destination.id)
            window.moveSelectedTemporaryTabs(to: destination.id)
            window.closeTab(a.id)
            window.closeSelectedTemporaryTabs()
            XCTAssertEqual(window.selectedTemporaryTabs.map(\.id), [a.id])
            XCTAssertEqual(window.record.tabs.map(\.spaceID), [home.id, home.id])
            XCTAssertEqual(window.record.tabs.map(\.id), [a.id, b.id])
            page.finishCloseRequest(accepted: false)
            let result = await deletion.value
            XCTAssertNotNil(result)
        }
    }

    func testNumberedCommandsFollowSavedAndTemporarySidebarDestinations() throws {
        let pin = SavedItem(spaceID: Space.defaultID, title: "Pin")
        let tab = Tab(title: "Temporary")
        try withApp(SessionSnapshot(savedItems: [pin], windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            XCTAssertTrue(window.perform(.tab1))
            XCTAssertEqual(window.selectedTab?.savedItemID, pin.id)
            XCTAssertTrue(window.perform(.tab2))
            XCTAssertEqual(window.selectedTab?.id, tab.id)
            XCTAssertFalse(window.canPerform(.tab9))
            XCTAssertFalse(window.perform(.tab9))
            XCTAssertEqual(BrowserCommand.tab1.defaultShortcut.key, "")
            XCTAssertEqual(app.preferences.conflict(for: BrowserShortcut("1"), excluding: .tab1), "Space 1")
        }
    }

    func testNewCopyDefaultPreservesPreviouslyCustomizedBindingsAndExplicitClearing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shortcut = BrowserShortcut("c", [.command, .shift])
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertEqual(preferences.shortcut(for: .copyURL), shortcut)
        XCTAssertTrue(preferences.set(BrowserShortcut(""), for: .copyURL))
        XCTAssertTrue(preferences.set(shortcut, for: .duplicateTab))
        let reloaded = BrowserPreferences(directory: directory)
        XCTAssertEqual(reloaded.shortcut(for: .duplicateTab), shortcut)
        XCTAssertEqual(reloaded.shortcut(for: .copyURL).key, "")
        XCTAssertNil(reloaded.errorMessage)
        let oldRecord = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "shortcuts": ["duplicateTab": ["key": "c", "modifiers": shortcut.modifiers]]
        ])
        try oldRecord.write(to: directory.appendingPathComponent("browser-preferences.json"))
        let migrated = BrowserPreferences(directory: directory)
        XCTAssertEqual(migrated.shortcut(for: .duplicateTab), shortcut)
        XCTAssertEqual(migrated.shortcut(for: .copyURL).key, "")
        XCTAssertNil(migrated.errorMessage)
    }

    func testOpenCommandBarCancelsInProgressAddressEdit() throws {
        let tab = Tab(urlString: "https://example.com/", title: "Example")
        try withApp(SessionSnapshot(windows: [WindowRecord(selectedTabID: tab.id, tabs: [tab])])) { app in
            let window = try XCTUnwrap(app.windows.first)
            window.addressDraft = "half-typed query"
            window.isEditingAddress = true
            window.addressError = "Invalid input"
            window.openCommandBar()
            XCTAssertTrue(window.commandBarPresented)
            XCTAssertEqual(window.addressDraft, tab.urlString)
            XCTAssertFalse(window.isEditingAddress)
            XCTAssertNil(window.addressError)
        }
    }

    func testPopupAfterQuitPreflightIsRejected() async throws {
        try await withTestApp(SessionSnapshot(windows: [WindowRecord()])) { app, _ in
            let window = try XCTUnwrap(app.windows.first)
            window.addTab(url: URL(string: "https://example.com")!)
            let opener = try XCTUnwrap(window.selectedPage)
            let accepted = await window.requestClosePages()
            XCTAssertTrue(accepted)
            let child = TestPage(tabID: UUID(), contextID: opener.contextID)
            XCTAssertEqual(opener.events.onCreatePage?(child), false)
            XCTAssertFalse(window.record.tabs.contains { $0.id == child.tabID })
            window.cancelClosePages()
            XCTAssertEqual(opener.events.onCreatePage?(child), true)
            XCTAssertTrue(window.record.tabs.contains { $0.id == child.tabID })
        }
    }

    func testPagePromptCompletionsDenyWhenOriginChanges() async throws {
        try await withTestApp(SessionSnapshot(windows: [WindowRecord()])) { app, _ in
            let window = try XCTUnwrap(app.windows.first)
            let origin = URL(string: "https://example.com")!
            window.addTab(url: origin)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            let nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            nativeWindow.isReleasedWhenClosed = false
            nativeWindow.contentView = page.nativeView
            nativeWindow.makeKeyAndOrderFront(nil)
            defer { nativeWindow.contentView = nil; nativeWindow.close() }

            let identity = PagePromptIdentity(tabID: page.tabID, contextID: page.contextID,
                windowID: window.id, documentID: "document", frameID: "frame",
                requestingOrigin: origin, topLevelOrigin: origin)

            var dialogs: [PageJavaScriptDialogResult] = []
            let dialog = PageJavaScriptDialogRequest(identity: identity,
                prompt: PageJavaScriptDialog(kind: .confirm, message: "Continue?", defaultText: nil, isReload: false)) {
                    dialogs.append($0)
                }
            page.events.onJavaScriptDialog?(dialog)
            try await finishStalePrompt(page: page, window: nativeWindow, origin: origin,
                                       isPending: { dialog.isPending }, accept: .alertFirstButtonReturn)
            XCTAssertEqual(dialogs.count, 1)
            if case .cancel = dialogs[0] {} else { XCTFail("Expected cancelled dialog") }

            var credentials: [PageHTTPAuthCredential?] = []
            let auth = PageHTTPAuthRequest(identity: identity,
                prompt: PageHTTPAuthChallenge(requestURL: origin, scheme: "basic", realm: nil,
                    isProxy: false, firstAttempt: true, primaryNavigation: true)) { credentials.append($0) }
            page.events.onHTTPAuthRequest?(auth)
            try await finishStalePrompt(page: page, window: nativeWindow, origin: origin,
                                       isPending: { auth.isPending }, accept: .alertFirstButtonReturn)
            XCTAssertEqual(credentials.count, 1)
            XCTAssertNil(credentials[0])

            var files: [[URL]?] = []
            let chooser = PageFileChooserRequest(identity: identity,
                prompt: PageFileChooser(mode: .open, title: "Upload", defaultFilename: nil,
                    acceptedTypes: [])) { files.append($0) }
            page.events.onFileChooserRequest?(chooser)
            try await finishStalePrompt(page: page, window: nativeWindow, origin: origin,
                                       isPending: { chooser.isPending }, accept: .OK)
            XCTAssertEqual(files, [nil])

            var external: [Bool] = []
            let protocolRequest = PageExternalProtocolRequest(identity: identity,
                prompt: PageExternalProtocolPrompt(targetURL: URL(string: "mailto:test@example.com")!,
                    userGesture: true, primaryMainFrame: true, fencedFrame: false)) {
                        external.append($0)
                    }
            page.events.onExternalProtocolRequest?(protocolRequest)
            try await finishStalePrompt(page: page, window: nativeWindow, origin: origin,
                                       isPending: { protocolRequest.isPending }, accept: .alertFirstButtonReturn)
            XCTAssertEqual(external, [false])

            var clientIdentity = PagePromptIdentity(tabID: page.tabID, contextID: page.contextID,
                windowID: window.id, documentID: "", frameID: "",
                requestingOrigin: origin, topLevelOrigin: origin)
            clientIdentity.visiblePageOrigin = origin
            let choice = PageClientCertificateChoice(id: UUID(),
                certificate: PageCertificateDetails(subject: "Fixture Client", issuer: "Fixture CA",
                    validFrom: nil, validUntil: nil), serialNumber: "01")
            var certificates: [UUID?] = []
            let client = PageClientCertificateRequest(identity: clientIdentity,
                prompt: PageClientCertificatePrompt(choices: [choice], choicesTruncated: false,
                    context: .page(pageID: "fixture-page"))) { certificates.append($0) }
            page.events.onClientCertificateRequest?(client)
            try await finishStalePrompt(page: page, window: nativeWindow, origin: origin,
                                       isPending: { client.isPending }, accept: .alertFirstButtonReturn)
            XCTAssertEqual(certificates, [nil])
        }
    }

    func testDesignPreferencesDefaultMigrateAndPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"version":5}"#.utf8).write(to: directory.appendingPathComponent("browser-preferences.json"))
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertEqual(preferences.theme, .legacy)
        XCTAssertEqual(preferences.themeTemplate, .legacy)
        XCTAssertEqual(preferences.windowStyle, .rounded)
        XCTAssertEqual(preferences.tabLoadingIndicator, .system)
        XCTAssertEqual(preferences.browserChromeFont, .system)
        XCTAssertTrue(preferences.setTheme(.retro))
        XCTAssertEqual(preferences.windowStyle, .flat)
        XCTAssertTrue(preferences.setWindowStyle(.veryRounded))
        XCTAssertEqual(preferences.theme, .retro)
        XCTAssertEqual(preferences.tabLoadingIndicator, .terminalSquares)
        XCTAssertEqual(preferences.browserChromeFont, .monospaced)
        XCTAssertTrue(preferences.setBrowserChromeFont(.rounded))
        XCTAssertEqual(preferences.theme, .custom)
        XCTAssertEqual(preferences.themeTemplate, .retro)
        XCTAssertFalse(preferences.experimentalLoginSharing)
        XCTAssertTrue(preferences.setExperimentalLoginSharing(true))

        let reloaded = BrowserPreferences(directory: directory)
        XCTAssertEqual(reloaded.theme, .custom)
        XCTAssertEqual(reloaded.themeTemplate, .retro)
        XCTAssertEqual(reloaded.windowStyle, .veryRounded)
        XCTAssertEqual(reloaded.tabLoadingIndicator, .terminalSquares)
        XCTAssertEqual(reloaded.browserChromeFont, .rounded)
        XCTAssertTrue(reloaded.experimentalLoginSharing)
        XCTAssertNil(reloaded.errorMessage)

        let fresh = BrowserPreferences(directory: directory.appendingPathComponent("fresh"))
        XCTAssertEqual(fresh.theme, .native)
        XCTAssertEqual(fresh.themeTemplate, .native)
        XCTAssertEqual(fresh.windowStyle, .veryRounded)
        XCTAssertTrue(fresh.setNewTabsNextToActive(true))
        XCTAssertEqual(BrowserPreferences(directory: directory.appendingPathComponent("fresh")).theme, .native)

        XCTAssertTrue(reloaded.setThemeAccentColor(NSColor(srgbRed: 1.2, green: -0.1, blue: 0.5, alpha: 1)))
        let accent = try XCTUnwrap(BrowserPreferences(directory: directory).themeAccentColor.usingColorSpace(.sRGB))
        XCTAssertEqual(accent.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(accent.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(accent.blueComponent, 128.0 / 255, accuracy: 0.001)
        XCTAssertTrue(reloaded.setTheme(.retro))
        XCTAssertEqual(reloaded.theme, .retro)
        XCTAssertEqual(reloaded.windowStyle, .flat)
        XCTAssertEqual(reloaded.browserChromeFont, .monospaced)
        XCTAssertTrue(reloaded.setTabLoadingIndicator(.system))
        XCTAssertEqual(reloaded.theme, .custom)
        XCTAssertEqual(reloaded.themeTemplate, .retro)
    }

    func testPresetAccentIgnoresOldDefaultButAcceptsExplicitOverride() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"version":7,"theme":"retro","themeAccentHex":"A8DC52"}"#.utf8)
            .write(to: directory.appendingPathComponent("browser-preferences.json"))
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertEqual(preferences.themeAccentColor, BrowserPreferences.color(hex: "FFFFFF"))
        XCTAssertTrue(preferences.setThemeAccentColor(BrowserPreferences.color(hex: "A8DC52")))
        XCTAssertEqual(preferences.theme, .custom)
        XCTAssertEqual(BrowserPreferences(directory: directory).themeAccentColor, BrowserPreferences.color(hex: "A8DC52"))
    }

    func testThemeMigrationAndInvalidRecordsPreserveOriginalSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("browser-preferences.json")
        try Data(#"{"version":6,"browserChromeFont":"serif","tabLoadingIndicator":"terminalSquares"}"#.utf8).write(to: file)
        let migrated = BrowserPreferences(directory: directory)
        XCTAssertEqual(migrated.theme, .custom)
        XCTAssertEqual(migrated.themeTemplate, .legacy)
        XCTAssertEqual(migrated.browserChromeFont, .serif)
        XCTAssertEqual(migrated.tabLoadingIndicator, .terminalSquares)
        for invalid in [
            #"{"version":7,"theme":"custom","themeTemplate":"custom"}"#,
            #"{"version":7,"theme":"retro","themeAccentHex":"GG0000"}"#,
            #"{"version":7,"windowStyle":"circular"}"#,
            #"{"version":7,"defaultEngine":""}"#
        ] {
            let original = Data(invalid.utf8)
            try original.write(to: file)
            let preferences = BrowserPreferences(directory: directory)
            XCTAssertNotNil(preferences.errorMessage)
            XCTAssertFalse(preferences.setTheme(.retro))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    private func finishStalePrompt(page: TestPage, window: NSWindow, origin: URL,
                                   isPending: @escaping () -> Bool,
                                   accept: NSApplication.ModalResponse) async throws {
        for _ in 0..<100 where window.attachedSheet == nil { await Task.yield() }
        let sheet = try XCTUnwrap(window.attachedSheet)
        page.state.urlString = "https://other.example/"
        window.endSheet(sheet, returnCode: accept)
        for _ in 0..<100 where isPending() { await Task.yield() }
        page.state.urlString = origin.absoluteString
    }

    private func withApp(_ snapshot: SessionSnapshot, body: (AppModel) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleTabCommands-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        store.save(snapshot) { XCTAssertNil($0) }
        store.flush()
        let app = AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
        defer { app.windows.forEach { $0.closePages() }; app.flush(); app.library.close() }
        try body(app)
    }

    private func withTestApp(_ snapshot: SessionSnapshot,
                             body: (AppModel, TestEngine) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleTabSelection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        store.save(snapshot) { XCTAssertNil($0) }
        store.flush()
        let engine = TestEngine(.webKit)
        let app = AppModel(store: store, engines: EngineRegistry([engine]))
        defer { app.windows.forEach { $0.closePages() }; app.flush(); app.library.close() }
        try await body(app, engine)
    }
}

@MainActor private final class TestPageDevToolsSession: PageDevToolsSession {
    let nativeView = NSView()
    private let delayedClose: Bool
    private(set) var isClosed = false
    var onClose: (() -> Void)?
    private(set) var closeCount = 0
    init(delayedClose: Bool = false, initiallyClosed: Bool = false) {
        self.delayedClose = delayedClose
        isClosed = initiallyClosed
    }
    func focus() {}
    func setVisible(_ visible: Bool) {}
    func close() -> Bool {
        guard !isClosed else { return false }
        closeCount += 1
        if !delayedClose { finishClose() }
        return true
    }
    func finishClose() {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
    }
}

@MainActor private final class TabSelectionDownload: EngineDownload {
    let id = UUID()
    let suggestedFilename = "fixture"
    var window: NSWindow?
    var onProgress: ((Double?) -> Void)?
    var onDestination: ((String, @escaping (URL?) -> Void) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private var cancellation: (() -> Void)?
    func start() {}
    func cancel(completion: @escaping () -> Void) { cancellation = completion }
    func detach() {}
    func fail() { onFailure?(NSError(domain: "CobbleTabSelection", code: 1)) }
    func finishCancellation() { cancellation?(); cancellation = nil }
}
