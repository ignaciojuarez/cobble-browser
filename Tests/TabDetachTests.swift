import AppKit
import XCTest
import WebKit
@testable import Cobble

@MainActor final class TabDetachTests: XCTestCase {
    private let secondEngine = EngineID(rawValue: "detach.secondary")
    private let url = URL(string: "https://example.com/live")!

    private func withApp(native: Bool = false, _ body: (AppModel, [TestEngine]) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDetachTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engines = [TestEngine(.webKit), TestEngine(secondEngine)]
        let store = SessionStore(directory: directory)
        let app = native ? AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
            : AppModel(store: store, engines: EngineRegistry(engines))
        do { try await body(app, engines) }
        catch {
            app.windows.forEach { $0.closePages() }
            await app.engines.shutdown()
            app.flush()
            app.library.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        app.windows.forEach { $0.closePages() }
        await app.engines.shutdown()
        app.flush()
        app.library.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out", file: file, line: line)
        throw EngineError.notReady("Timed out")
    }

    func testDetachMovesOneLivePageWithoutReloadAndRebindsCallbacks() async throws {
        try await withApp { app, _ in
            let source = app.windows[0]
            source.addTab(url: self.url)
            let page = try XCTUnwrap(source.selectedPage as? TestPage)
            page.capabilities.pageOperations.insert(.detach)
            let nativeView = page.nativeView
            let sourceContainer = BrowserPageContainer()
            sourceContainer.mount(page)
            source.pinTab(page.tabID)
            page.events.onVisit?(page.tabID, self.url.absoluteString, "Original history title")
            let savedID = try XCTUnwrap(source.selectedTab?.savedItemID)
            var opened: BrowserWindowModel?
            app.onOpenWindow = { opened = $0 }
            page.onMoveToWindow = { windowID in
                XCTAssertEqual(opened?.id, windowID, "The destination window must be registered before moving its native page")
            }

            XCTAssertTrue(source.perform(.detachTab))
            let destination = try XCTUnwrap(opened)

            XCTAssertTrue(destination.selectedPage === page)
            XCTAssertTrue(try XCTUnwrap(destination.selectedPage).nativeView === nativeView)
            let destinationContainer = BrowserPageContainer()
            destinationContainer.mount(try XCTUnwrap(destination.selectedPage))
            XCTAssertTrue(nativeView.superview === destinationContainer)
            sourceContainer.unmount()
            XCTAssertTrue(nativeView.superview === destinationContainer,
                          "Late dismantling of the old SwiftUI host must not detach the moved native view")
            XCTAssertEqual(page.movedWindowIDs, [destination.id])
            XCTAssertEqual(page.loadedURLs, [self.url])
            XCTAssertEqual(destination.selectedTab?.id, page.tabID)
            XCTAssertEqual(destination.selectedTab?.savedItemID, savedID)
            XCTAssertNotNil(app.savedItems.first { $0.id == savedID })
            XCTAssertTrue(source.record.tabs.isEmpty)
            XCTAssertNil(source.selectedTab)

            let changedURL = "https://example.com/after-detach"
            page.events.onChange?(page.tabID, changedURL, "Moved page")
            XCTAssertEqual(destination.selectedTab?.urlString, changedURL)
            XCTAssertEqual(destination.selectedTab?.title, "Moved page")
            XCTAssertTrue(source.record.tabs.isEmpty)
            page.events.onChange?(page.tabID, self.url.absoluteString, "Updated history title")
            XCTAssertEqual(app.library.search("Updated history title", profileID: Profile.defaultID, historyOnly: true).first?.title, "Updated history title")
        }
    }

    func testNativeDetachPreservesUnsavedDOMAndViewIdentity() async throws {
        let server = try LocalHTTPFixture { _ in
            .init(headers: ["Content-Type": "text/html"], body: "<title>Detach fixture</title><input id='draft'><script>window.fixtureToken = 'original'</script>")
        }
        try await server.start()
        defer { server.stop() }
        try await withApp(native: true) { app, _ in
            let source = app.windows[0]
            source.addTab(url: server.url("/detach"))
            let page = try XCTUnwrap(source.selectedPage as? WebKitPage)
            try await self.eventually { page.state.lifecycle == .ready }
            let view = page.webView
            let sourceContainer = BrowserPageContainer()
            let sourceWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            sourceWindow.isReleasedWhenClosed = false
            sourceWindow.contentView = sourceContainer
            defer { sourceWindow.close() }
            sourceContainer.mount(page)
            let session = try XCTUnwrap(page.context?.extensionSession as? WebKitExtensionSession)
            let oldExtensionWindow = try XCTUnwrap(session.window(for: page))
            XCTAssertTrue(oldExtensionWindow.activePage === page)
            try await self.eventually { view.title == "Detach fixture" && !view.isLoading && source.canDetachSelectedTab }
            _ = try await view.evaluateJavaScript("document.getElementById('draft').value = 'unsaved text'; window.fixtureToken = 'retained';")

            let requestCount = server.requests.filter { $0.path == "/detach" }.count
            let destination = try XCTUnwrap(app.detachSelectedTab(from: source))
            let destinationContainer = BrowserPageContainer()
            let destinationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            destinationWindow.isReleasedWhenClosed = false
            destinationWindow.contentView = destinationContainer
            defer { destinationWindow.close() }
            destinationContainer.mount(try XCTUnwrap(destination.selectedPage))
            let newExtensionWindow = try XCTUnwrap(session.window(for: page))
            XCTAssertFalse(oldExtensionWindow === newExtensionWindow)
            XCTAssertNil(oldExtensionWindow.activePage)
            XCTAssertTrue(newExtensionWindow.activePage === page)
            XCTAssertTrue(destination.selectedPage === page)
            XCTAssertTrue(page.webView === view)
            XCTAssertTrue(view.superview === destinationContainer)
            let memory = try await view.evaluateJavaScript("[document.getElementById('draft').value, window.fixtureToken]") as? [String]
            XCTAssertEqual(memory, ["unsaved text", "retained"])
            XCTAssertEqual(server.requests.filter { $0.path == "/detach" }.count, requestCount)
            XCTAssertTrue(source.record.tabs.isEmpty)
            _ = try await view.evaluateJavaScript("document.title = 'After native detach'")
            try await self.eventually { destination.selectedTab?.title == "After native detach" }
            XCTAssertNil(source.selectedTab)
            page.close()
            XCTAssertNil(oldExtensionWindow.activePage)
            XCTAssertNil(newExtensionWindow.activePage)
        }
    }

    func testClosingBeforeDestinationMountRetiresOldExtensionWindow() async throws {
        try await withApp(native: true) { app, _ in
            let resources = app.store.directory.appendingPathComponent("extension-fixture")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try #"{"manifest_version":3,"name":"Detach fixture","version":"1"}"#.write(to: resources.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            let webExtension = try await WKWebExtension(resourceBaseURL: resources)
            let extensionContext = WKWebExtensionContext(for: webExtension)
            let source = app.windows[0]
            let tab = Tab(spaceID: source.record.selectedSpaceID)
            source.record.tabs = [tab]
            source.select(tab.id)
            let page = try XCTUnwrap(source.selectedPage as? WebKitPage)
            try await self.eventually { page.state.lifecycle == .ready }
            let container = BrowserPageContainer()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = container
            defer { window.close() }
            container.mount(page)
            let session = try XCTUnwrap(page.context?.extensionSession as? WebKitExtensionSession)
            let adapter = try XCTUnwrap(session.window(for: page))
            XCTAssertEqual(session.webExtensionController(session.controller, openWindowsFor: extensionContext).count, 1)
            try await self.eventually { source.canDetachSelectedTab }
            let destination = try XCTUnwrap(app.detachSelectedTab(from: source))
            XCTAssertNil(adapter.activePage)
            destination.closePages()
            XCTAssertTrue(session.webExtensionController(session.controller, openWindowsFor: extensionContext).isEmpty)
            XCTAssertNil(adapter.activePage)
        }
    }

    func testDetachWaitsForPendingDOMRead() async throws {
        try await withApp { app, _ in
            let source = app.windows[0]
            source.addTab(url: self.url)
            let page = try XCTUnwrap(source.selectedPage as? TestPage)
            page.capabilities.pageOperations.insert(.detach)
            page.delayDOM = true
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page.nativeView
            defer { window.close() }
            source.pageFileOperations.viewCurrentDOM()
            XCTAssertTrue(source.pageFileOperations.isReadingDOM)
            XCTAssertFalse(source.perform(.detachTab))
            try await self.eventually { page.domContinuation != nil }
            page.finishDOM(.failure(EngineError.notReady("Fixture read failure")))
            try await self.eventually { !source.pageFileOperations.isReadingDOM }
            XCTAssertNotNil(source.addressError)
            XCTAssertTrue(source.canDetachSelectedTab)
        }
    }

    func testDetachRejectsQueuedSelectedTabClose() async throws {
        try await withApp { app, _ in
            let source = app.windows[0]
            source.addTab(url: self.url)
            let page = try XCTUnwrap(source.selectedPage as? TestPage)
            page.capabilities.pageOperations.insert(.detach)
            source.closeSelectedTemporaryTabs()
            // The batch owns its selection before its asynchronous close task starts.
            XCTAssertFalse(source.perform(.detachTab))
            XCTAssertTrue(source.selectedPage === page)
            try await self.eventually { source.record.tabs.isEmpty }
        }
    }

    func testDetachRejectsPrivateUnsupportedAndPendingPageActions() async throws {
        try await withApp { app, engines in
            let source = app.windows[0]
            source.addTab(url: self.url)
            let page = try XCTUnwrap(source.selectedPage as? TestPage)

            XCTAssertFalse(source.perform(.detachTab))
            XCTAssertTrue(source.selectedPage === page)

            page.capabilities.pageOperations.insert(.detach)
            source.isEditingAddress = true
            source.addressDraft = "unsubmitted draft"
            XCTAssertFalse(source.perform(.detachTab))
            XCTAssertEqual(source.addressDraft, "unsubmitted draft")
            source.isEditingAddress = false
            source.findPresented = true
            XCTAssertFalse(source.perform(.detachTab))
            source.findPresented = false
            page.state.isLoading = true
            XCTAssertFalse(source.perform(.detachTab))
            page.state.isLoading = false
            page.state.hasPendingPrompt = true
            XCTAssertFalse(source.perform(.detachTab))
            page.state.hasPendingPrompt = false

            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            source.closeTab(page.tabID)
            try await self.eventually { page.closeRequest != nil }
            XCTAssertFalse(source.perform(.detachTab))
            page.finishCloseRequest(accepted: false)
            try await self.eventually { page.closeRequest == nil }

            source.confirmEngineSwitch = { _ in true }
            engines[1].delayPreparation = true
            source.setEngine(self.secondEngine, for: page.tabID)
            try await self.eventually { engines[1].contexts.first?.pages.first?.preparation != nil }
            XCTAssertFalse(source.perform(.detachTab))
            engines[1].contexts.first?.pages.first?.finishPreparation()
            try await self.eventually { source.selectedPage?.contextID.engineID == self.secondEngine }

            let privateWindow = try XCTUnwrap(app.newWindow(isPrivate: true, profileID: Profile.defaultID))
            privateWindow.addTab(url: self.url)
            let privatePage = try XCTUnwrap(privateWindow.selectedPage as? TestPage)
            privatePage.capabilities.pageOperations.insert(.detach)
            XCTAssertFalse(privateWindow.perform(.detachTab))
        }
    }

    func testDetachRejectsDeletingAndClosedProfiles() async throws {
        try await withApp { app, _ in
            let profile = try XCTUnwrap(app.createProfile(name: "Detach fixture"))
            let window = try XCTUnwrap(app.newWindow(profileID: profile.id))
            window.addTab(url: self.url)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.pageOperations.insert(.detach)
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true

            let deletion = Task { await app.deleteProfile(profile.id) }
            try await self.eventually { app.isDeletingProfile(profile.id) && page.closeRequest != nil }
            XCTAssertFalse(window.perform(.detachTab))
            page.state.lifecycle = .closed
            page.events.onClose?()
            page.finishCloseRequest(accepted: true)
            let result = await deletion.value
            XCTAssertNil(result)

            let normal = app.windows[0]
            normal.addTab(url: self.url)
            let normalPage = try XCTUnwrap(normal.selectedPage as? TestPage)
            normalPage.capabilities.pageOperations.insert(.detach)
            normal.closePages()
            XCTAssertFalse(normal.perform(.detachTab))
        }
    }
}
