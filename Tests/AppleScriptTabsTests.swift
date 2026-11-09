import AppKit
import OSAKit
import XCTest
@testable import Cobble

@MainActor final class AppleScriptTabsTests: XCTestCase {
    private func withApp(engines ids: [EngineID] = [.webKit],
                         _ body: (AppModel, TestEngine) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleScriptTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engines = ids.map { TestEngine($0) }
        let engine = engines[0]
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry(engines))
        CobbleScriptTabs.app = app
        defer {
            CobbleScriptTabs.app = nil
            app.windows.forEach { $0.closePages() }
            app.flush()
            app.library.close()
            try? FileManager.default.removeItem(at: directory)
        }
        do { try await body(app, engine) }
        catch {
            app.windows.forEach { $0.closePages() }
            await app.engines.shutdown()
            throw error
        }
        await app.engines.shutdown()
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out", file: file, line: line)
    }

    private nonisolated func code(_ string: String) -> UInt32 { string.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func assertThrows<T>(_ expected: CobbleScriptTabs.Error, _ body: () async throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? CobbleScriptTabs.Error, expected, file: file, line: line) }
    }

    private func sendCommand(_ id: AEEventID, directParameter: String? = nil, windowID: String? = nil,
                             activating: Bool? = nil) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: 0x4362626C, eventID: id,
                                           targetDescriptor: .currentProcess(),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if let directParameter { event.setParam(NSAppleEventDescriptor(string: directParameter), forKeyword: keyDirectObject) }
        if let windowID { event.setParam(NSAppleEventDescriptor(string: windowID), forKeyword: 0x4362576E) }
        if let activating { event.setParam(NSAppleEventDescriptor(boolean: activating), forKeyword: code("CbAc")) }
        return try event.sendEvent(options: .waitForReply, timeout: 2)
    }

    func testCommandsCoerceArgumentsAndReturnStablePublicRecords() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            let args = ["windowID": window.id.uuidString]
            let opened = try CobbleScriptTabs.openTab(directParameter: "https://example.com/path", arguments: args)
            let tabID = try XCTUnwrap(opened["id"] as? String)
            XCTAssertEqual(opened["url"] as? String, "https://example.com/path")
            XCTAssertEqual(UUID(uuidString: tabID), window.selectedTab?.id)

            let tabs = try CobbleScriptTabs.listTabs(arguments: args)
            XCTAssertEqual(tabs.count, 1)
            XCTAssertEqual(tabs[0]["id"] as? String, tabID)
            XCTAssertEqual(tabs[0]["selected"] as? Bool, true)

            _ = try CobbleScriptTabs.closeTab(directParameter: tabID, arguments: args)
            XCTAssertTrue(window.record.tabs.isEmpty)
            XCTAssertThrowsError(try CobbleScriptTabs.openTab(directParameter: URL(fileURLWithPath: "/private/secret").absoluteString, arguments: args))
            XCTAssertThrowsError(try CobbleScriptTabs.openTab(directParameter: "https://user:password@example.com", arguments: args))
        }
    }

    func testBundledDictionaryCreatesNativeCommands() async throws {
        try await withApp { app, _ in
            XCTAssertNotNil(Bundle.main.url(forResource: "Cobble", withExtension: "sdef"))
            let registry = NSScriptSuiteRegistry.shared()
            registry.loadSuites(from: Bundle.main)
            let description = try XCTUnwrap(registry.commandDescription(withAppleEventClass: 0x4362626C, andAppleEventCode: 0x4F546162))
            let command = description.createCommandInstance()
            XCTAssertTrue(command is CobbleOpenTabCommand)
            command.directParameter = "https://example.com/native-command"
            command.arguments = ["windowID": app.windows[0].id.uuidString]
            let result = try XCTUnwrap(command.performDefaultImplementation() as? NSDictionary)
            XCTAssertEqual(command.scriptErrorNumber, 0)
            XCTAssertEqual(result["url"] as? String, "https://example.com/native-command")
            XCTAssertEqual(result["id"] as? String, app.windows[0].selectedTab?.id.uuidString)
            let invalid = description.createCommandInstance()
            invalid.directParameter = "file:///private/fixture"
            invalid.arguments = command.arguments
            XCTAssertNil(invalid.performDefaultImplementation())
            XCTAssertNotEqual(invalid.scriptErrorNumber, 0)

            let commands: [(String, AnyClass)] = [
                ("LUrl", CobbleLoadURLCommand.self), ("GBck", CobbleGoBackCommand.self),
                ("GFwd", CobbleGoForwardCommand.self), ("RTab", CobbleReloadTabCommand.self),
                ("RdTx", CobbleReadTabCommand.self), ("CpTb", CobbleCaptureTabCommand.self),
                ("Wait", CobbleWaitForTabCommand.self), ("Outl", CobbleOutlineTabCommand.self),
                ("Actn", CobblePerformActionCommand.self), ("RAct", CobbleReadActivityCommand.self)
            ]
            for (name, expected) in commands {
                let description = try XCTUnwrap(registry.commandDescription(withAppleEventClass: 0x4362626C,
                                                                            andAppleEventCode: self.code(name)), name)
                XCTAssertTrue(type(of: description.createCommandInstance()) == expected, name)
            }
        }
    }

    func testAppleEventsReportAwarenessAndOpenBackgroundTabs() async throws {
        try await withApp { app, _ in
            let registry = NSScriptSuiteRegistry.shared()
            registry.loadSuites(from: Bundle.main)
            let window = app.windows[0]
            let first = try self.sendCommand(0x4F546162, directParameter: "https://example.com/front")
            let firstID = try XCTUnwrap(first.paramDescriptor(forKeyword: keyDirectObject)?.forKeyword(0x49442020)?.stringValue)
            let background = try self.sendCommand(0x4F546162, directParameter: "https://example.com/back", activating: false)
            let record = try XCTUnwrap(background.paramDescriptor(forKeyword: keyDirectObject))
            XCTAssertEqual(record.forKeyword(0x4362536C)?.booleanValue, false)
            XCTAssertEqual(record.forKeyword(self.code("CbLd"))?.booleanValue, true)
            XCTAssertEqual(record.forKeyword(self.code("CbEn"))?.stringValue, "webkit")
            XCTAssertEqual(window.selectedTab?.id.uuidString, firstID)

            let windows = try self.sendCommand(0x4C57696E)
            let windowRecord = try XCTUnwrap(windows.paramDescriptor(forKeyword: keyDirectObject)?.atIndex(1))
            XCTAssertEqual(windowRecord.forKeyword(self.code("CbSt"))?.stringValue, firstID)
            XCTAssertEqual(windowRecord.forKeyword(self.code("CbBz"))?.booleanValue, false)
            XCTAssertNotNil(windowRecord.forKeyword(self.code("pisf")))
        }
    }

    func testOpenSelectAndCloseFindTabsWithoutWindowIDs() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            let first = try CobbleScriptTabs.openTab(directParameter: "https://example.com/first", arguments: nil)
            let firstID = try XCTUnwrap(first["id"] as? String)
            XCTAssertEqual(first["loaded"] as? Bool, true)
            XCTAssertEqual(first["saved"] as? Bool, false)
            XCTAssertEqual(first["spaceID"] as? String, window.record.selectedSpaceID.uuidString)
            let second = try CobbleScriptTabs.openTab(directParameter: "https://example.com/second", arguments: ["activate": false])
            let secondID = try XCTUnwrap(second["id"] as? String)
            XCTAssertEqual(second["selected"] as? Bool, false)
            XCTAssertEqual(window.selectedTab?.id.uuidString, firstID)
            XCTAssertNotNil(window.pageState(try XCTUnwrap(UUID(uuidString: secondID))), "Background tabs load")

            let windows = try CobbleScriptTabs.listWindows()
            XCTAssertEqual(windows[0]["selectedTabID"] as? String, firstID)
            XCTAssertEqual(windows[0]["busy"] as? Bool, false)

            _ = try CobbleScriptTabs.selectTab(directParameter: secondID, arguments: nil)
            XCTAssertEqual(window.selectedTab?.id.uuidString, secondID)
            _ = try CobbleScriptTabs.closeTab(directParameter: firstID, arguments: nil)
            XCTAssertEqual(window.record.tabs.map(\.id.uuidString), [secondID])
            await self.assertThrows(.invalidTab) { try CobbleScriptTabs.selectTab(directParameter: UUID().uuidString, arguments: nil) }
            await self.assertThrows(.invalidWindow) {
                try CobbleScriptTabs.listTabs(arguments: ["windowID": UUID().uuidString])
            }
        }
    }

    func testNavigationReusesLivePagesAndRefusesUnsafeTargets() async throws {
        try await withApp(engines: [.webKit, .chromium]) { app, _ in
            let window = app.windows[0]
            let opened = try CobbleScriptTabs.openTab(directParameter: "https://example.com/start", arguments: nil)
            let tabID = try XCTUnwrap(opened["id"] as? String)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)

            _ = try CobbleScriptTabs.loadURL(directParameter: "https://example.com/next", arguments: ["tabID": tabID])
            XCTAssertEqual(page.loadedURLs.last?.absoluteString, "https://example.com/next")
            await self.assertThrows(.invalidURL) {
                try CobbleScriptTabs.loadURL(directParameter: "file:///etc/hosts", arguments: ["tabID": tabID])
            }
            XCTAssertTrue(app.preferences.setEngineRule(for: try XCTUnwrap(URL(string: "https://chromium.example/")), engineID: .chromium))
            await self.assertThrows(.otherEngine) {
                try CobbleScriptTabs.loadURL(directParameter: "https://chromium.example/", arguments: ["tabID": tabID])
            }

            await self.assertThrows(.noHistory) { try CobbleScriptTabs.go(directParameter: tabID, arguments: nil, back: true) }
            page.state.canGoBack = true
            _ = try CobbleScriptTabs.go(directParameter: tabID, arguments: nil, back: true)
            _ = try CobbleScriptTabs.reloadTab(directParameter: tabID, arguments: nil)
            XCTAssertEqual(page.navigationCommands, ["back", "reload"])

            page.state.hasPendingPrompt = true
            await self.assertThrows(.busy) { try CobbleScriptTabs.reloadTab(directParameter: tabID, arguments: nil) }
            page.state.hasPendingPrompt = false

            let unloaded = Tab(urlString: "https://example.com/unloaded", title: "Unloaded")
            window.record.tabs.append(unloaded)
            await self.assertThrows(.notLoaded) {
                try CobbleScriptTabs.reloadTab(directParameter: unloaded.id.uuidString, arguments: nil)
            }
            XCTAssertEqual(page.navigationCommands, ["back", "reload"])
        }
    }

    func testPageReadingNeedsOptInAndExcludesPrivateAndNonWebPages() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            let opened = try CobbleScriptTabs.openTab(directParameter: "https://example.com/article", arguments: nil)
            let tabID = try XCTUnwrap(opened["id"] as? String)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.renderedTextValue = "Hello world"
            page.snapshotImage = NSImage(size: NSSize(width: 3_200, height: 1_600), flipped: false) { rect in
                NSColor.systemRed.setFill(); rect.fill(); return true
            }

            await self.assertThrows(.pageAccessOff) { try await CobbleScriptTabs.readTab(directParameter: tabID, arguments: nil) }
            await self.assertThrows(.pageAccessOff) { try await CobbleScriptTabs.captureTab(directParameter: tabID, arguments: nil) }
            XCTAssertTrue(app.preferences.setAutomationPageAccess(true))

            let content = try await CobbleScriptTabs.readTab(directParameter: tabID, arguments: ["maxLength": 5])
            XCTAssertEqual(content["text"] as? String, "Hello")
            XCTAssertEqual(content["truncated"] as? Bool, true)
            XCTAssertEqual(content["url"] as? String, "https://example.com/article")
            let image = try await CobbleScriptTabs.captureTab(directParameter: tabID, arguments: nil)
            XCTAssertEqual(image["width"] as? Int, 1_600)
            XCTAssertEqual(image["height"] as? Int, 800)
            let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(image["pngData"] as? String)))
            XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))

            // WebKit keeps characters such as [ ] raw; Foundation would encode them, which must not look like a change.
            page.state.urlString = "https://example.com/items?filter[status]=open|new"
            let raw = try await CobbleScriptTabs.readTab(directParameter: tabID, arguments: nil)
            XCTAssertEqual(raw["text"] as? String, "Hello world")
            page.state.urlString = "https://example.com/article"

            page.onRenderedText = { page.state.urlString = "https://example.com/elsewhere" }
            await self.assertThrows(.pageChanged) { try await CobbleScriptTabs.readTab(directParameter: tabID, arguments: nil) }
            page.onRenderedText = { _ = app.preferences.setAutomationPageAccess(false) }
            page.state.urlString = "https://example.com/article"
            await self.assertThrows(.pageChanged) { try await CobbleScriptTabs.readTab(directParameter: tabID, arguments: nil) }
            page.onRenderedText = nil
            XCTAssertTrue(app.preferences.setAutomationPageAccess(true))

            page.state.urlString = "file:///Users/secret/report.html"
            await self.assertThrows(.invalidTab) { try await CobbleScriptTabs.readTab(directParameter: tabID, arguments: nil) }

            let privateWindow = app.newWindow(isPrivate: true, url: URL(string: "https://example.com/private"))
            let privateTab = try XCTUnwrap(privateWindow.selectedTab)
            await self.assertThrows(.invalidTab) {
                try await CobbleScriptTabs.readTab(directParameter: privateTab.id.uuidString, arguments: nil)
            }
            await self.assertThrows(.invalidWindow) {
                try await CobbleScriptTabs.readTab(directParameter: privateTab.id.uuidString,
                                                   arguments: ["windowID": privateWindow.id.uuidString])
            }
        }
    }

    func testAgentTabsOpenInTheirOwnSpaceWhileExistingTabsStayUsable() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            let userSpace = window.record.selectedSpaceID
            let user = try CobbleScriptTabs.openTab(directParameter: "https://example.com/mine", arguments: nil)
            let userID = try XCTUnwrap(user["id"] as? String)
            XCTAssertEqual(try CobbleScriptTabs.listWindows()[0]["agentSpaceID"] as? String, "", "Created only when used")

            let agent = try CobbleScriptTabs.openTab(directParameter: "https://example.com/agent",
                                                     arguments: ["agentSpace": true, "activate": false])
            let agentSpace = AppModel.agentSpaceID(for: window.record.profileID)
            let agentID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(agent["id"] as? String)))
            XCTAssertEqual(agent["spaceID"] as? String, agentSpace.uuidString)
            XCTAssertEqual(agent["spaceName"] as? String, String(localized: "Agents"))
            XCTAssertEqual(window.record.selectedSpaceID, userSpace, "The user's space stays in front")
            XCTAssertEqual(window.selectedTab?.id.uuidString, userID)
            XCTAssertNotNil(window.pageState(agentID), "Background agent tabs load")
            _ = try CobbleScriptTabs.openTab(directParameter: "https://example.com/again", arguments: ["agentSpace": true, "activate": false])
            XCTAssertEqual(app.spaces.filter { $0.id == agentSpace }.count, 1)
            XCTAssertEqual(try CobbleScriptTabs.listWindows()[0]["agentSpaceID"] as? String, agentSpace.uuidString)
            XCTAssertFalse(app.canUndoOrganization, "Automation does not add to the user's undo history")

            // A tab the user points at is usable wherever it lives.
            _ = try CobbleScriptTabs.reloadTab(directParameter: userID, arguments: nil)
            XCTAssertTrue(window.automatedTabIDs.contains(agentID))
            XCTAssertTrue(window.automatedTabIDs.contains(try XCTUnwrap(UUID(uuidString: userID))))

            app.deleteSpace(agentSpace)
            _ = try CobbleScriptTabs.openTab(directParameter: "https://example.com/third", arguments: ["agentSpace": true, "activate": false])
            XCTAssertTrue(app.spaces.contains { $0.id == agentSpace }, "A deleted Agents space returns on next use")
            // Undoing an earlier change does not delete it: it was never part of the user's history.
            app.deleteSpace(agentSpace)
            app.updateSpace(id: userSpace, name: "Renamed", icon: nil)
            _ = try CobbleScriptTabs.openTab(directParameter: "https://example.com/fourth", arguments: ["agentSpace": true, "activate": false])
            app.undoOrganization()
            XCTAssertTrue(app.spaces.contains { $0.id == agentSpace }, "Undo keeps the Agents space")
            XCTAssertTrue(window.record.tabs.filter { $0.urlString == "https://example.com/fourth" }.allSatisfy { $0.spaceID == agentSpace })

            app.stopAutomation()
            XCTAssertTrue(window.automatedTabIDs.isEmpty)
            XCTAssertFalse(app.preferences.automationTabAccess)
            await self.assertThrows(.automationOff) { try CobbleScriptTabs.listWindows() }
            await self.assertThrows(.automationOff) { try CobbleScriptTabs.selectTab(directParameter: userID, arguments: nil) }
            XCTAssertTrue(app.preferences.setAutomationTabAccess(true))
            XCTAssertNoThrow(try CobbleScriptTabs.listWindows())
        }
    }

    func testPageActionsNeedControlAndPrivateSitesStayPrivate() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            let opened = try CobbleScriptTabs.openTab(directParameter: "https://mail.bank.example/inbox?id=7", arguments: nil)
            let tabID = try XCTUnwrap(opened["id"] as? String)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.state.urlString = "https://mail.bank.example/inbox?id=7"
            let click = ["tabID": tabID, "ref": "e1"]

            await self.assertThrows(.pageAccessOff) { try await CobbleScriptTabs.outlineTab(directParameter: tabID, arguments: nil) }
            XCTAssertTrue(app.preferences.setAutomationPageAccess(true))
            let outline = try await CobbleScriptTabs.outlineTab(directParameter: tabID, arguments: nil)
            XCTAssertEqual(outline["text"] as? String, "button \"Go\" [ref=e1]")
            let activity = try await CobbleScriptTabs.readActivity(directParameter: tabID, arguments: nil)
            XCTAssertEqual(activity["truncated"] as? Bool, false)
            await self.assertThrows(.pageControlOff) { try await CobbleScriptTabs.performAction(directParameter: "click", arguments: click) }

            XCTAssertTrue(app.preferences.setAutomationPageControl(true))
            let done = try await CobbleScriptTabs.performAction(directParameter: "Click", arguments: click)
            XCTAssertEqual(done, "Did click")
            _ = try await CobbleScriptTabs.performAction(directParameter: "fill",
                arguments: ["tabID": tabID, "ref": "e2", "value": "hello", "submit": true])
            _ = try await CobbleScriptTabs.performAction(directParameter: "scroll", arguments: ["tabID": tabID, "value": "down"])
            XCTAssertEqual(page.performedActions, [PageAction(kind: .click, ref: "e1"),
                                                   PageAction(kind: .fill, ref: "e2", value: "hello", submit: true),
                                                   PageAction(kind: .scroll, value: "down")])
            await self.assertThrows(.invalidAction) { try await CobbleScriptTabs.performAction(directParameter: "drag", arguments: click) }
            await self.assertThrows(.invalidAction) {
                try await CobbleScriptTabs.performAction(directParameter: "click", arguments: ["tabID": tabID])
            }

            // Page control depends on page access, which depends on the master switch.
            XCTAssertTrue(app.preferences.setAutomationPageAccess(false))
            XCTAssertFalse(app.preferences.automationPageControl)
            XCTAssertTrue(app.preferences.setAutomationPageAccess(true))
            XCTAssertTrue(app.preferences.automationPageControl)

            XCTAssertTrue(app.preferences.setAutomationExcluded(try XCTUnwrap(URL(string: "https://www.bank.example/login")), excluded: true))
            XCTAssertEqual(app.preferences.automationExcludedHosts, ["bank.example"])
            for bad in ["http://[::1]:3000", "https://www.www.example.com"] {
                XCTAssertFalse(app.preferences.setAutomationExcluded(try XCTUnwrap(URL(string: bad)), excluded: true), bad)
            }
            XCTAssertEqual(app.preferences.automationExcludedHosts, ["bank.example"])
            XCTAssertFalse(app.preferences.automationExcludes(try XCTUnwrap(URL(string: "https://notbank.example/"))))
            await self.assertThrows(.excludedSite) { try await CobbleScriptTabs.readTab(directParameter: tabID, arguments: nil) }
            await self.assertThrows(.excludedSite) { try await CobbleScriptTabs.outlineTab(directParameter: tabID, arguments: nil) }
            await self.assertThrows(.excludedSite) { try await CobbleScriptTabs.performAction(directParameter: "click", arguments: click) }
            let listed = try XCTUnwrap(try CobbleScriptTabs.listTabs(arguments: nil).first { $0["id"] as? String == tabID })
            XCTAssertEqual(listed["url"] as? String, "https://mail.bank.example")
            XCTAssertEqual(listed["title"] as? String, "")
            XCTAssertEqual(listed["excluded"] as? Bool, true)
            XCTAssertEqual(page.performedActions.count, 3)

            let reloaded = BrowserPreferences(directory: app.store.directory)
            XCTAssertEqual(reloaded.automationExcludedHosts, ["bank.example"])
            XCTAssertTrue(reloaded.automationPageControl)
        }
    }

    func testWaitReturnsWhenLoadingFinishesAndTimesOut() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            let opened = try CobbleScriptTabs.openTab(directParameter: "https://example.com/slow", arguments: nil)
            let tabID = try XCTUnwrap(opened["id"] as? String)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.state.isLoading = true
            let waiting = Task { @MainActor in
                try await CobbleScriptTabs.waitForTab(directParameter: tabID, arguments: nil)["loading"] as? Bool
            }
            try await Task.sleep(for: .milliseconds(250))
            page.state.isLoading = false
            let loading = try await waiting.value
            XCTAssertEqual(loading, false)

            page.state.isLoading = true
            await self.assertThrows(.timedOut) { try await CobbleScriptTabs.waitForTab(directParameter: tabID, arguments: ["timeout": 1]) }
            page.state.isLoading = false

            let unloaded = Tab(urlString: "https://example.com/unloaded", title: "Unloaded")
            window.record.tabs.append(unloaded)
            await self.assertThrows(.notLoaded) {
                try await CobbleScriptTabs.waitForTab(directParameter: unloaded.id.uuidString, arguments: nil)
            }
        }
    }

    func testAppleScriptTerminologyCompilesWithoutKeywordClashes() throws {
        NSScriptSuiteRegistry.shared().loadSuites(from: Bundle.main)
        let script = OSAScript(source: """
            tell current application
                set windowList to list windows
                list tabs in window "W"
                open tab "https://example.com" in window "W" without activating
                select tab "T"
                load url "https://example.com/next" in tab "T"
                go back "T"
                go forward "T" in window "W"
                reload tab "T"
                read tab "T" max length 10
                capture tab "T"
                open tab "https://example.com" with agent space without activating
                wait for tab "T" timeout 5
                outline tab "T" max length 100
                perform page action "fill" in tab "T" targeting "e1" input "hi" with submitting
                perform page action "scroll" in tab "T" input "down"
                read activity "T" max length 100
                close tab "T"
            end tell
            """, language: try XCTUnwrap(OSALanguage(forName: "AppleScript")))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
        XCTAssertFalse(script.source.contains("«event"), script.source)
    }

    func testWindowTitleFollowsSelectedTabButNotPrivateWindows() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            XCTAssertEqual(window.windowTitle, "Cobble")
            _ = try CobbleScriptTabs.openTab(directParameter: "https://example.com/", arguments: nil)
            let title = try XCTUnwrap(window.selectedTab?.displayedTitle)
            XCTAssertEqual(window.windowTitle, title)
            let controller = BrowserWindowController(model: window, onClose: { _ in })
            defer { controller.window?.contentView = nil; controller.window?.close() }
            XCTAssertEqual(controller.window?.title, title)
            window.renameTab(try XCTUnwrap(window.selectedTab?.id), title: "Renamed")
            try await self.eventually { controller.window?.title == "Renamed" }

            let privateWindow = app.newWindow(isPrivate: true, url: URL(string: "https://example.com/secret"))
            XCTAssertEqual(privateWindow.windowTitle, String(localized: "Cobble — Private"))
        }
    }

    func testSelfTargetedAppleEventCoercesTypedRecordsAndErrors() async throws {
        try await withApp { app, _ in
            let registry = NSScriptSuiteRegistry.shared()
            registry.loadSuites(from: Bundle.main)

            let windows = try self.sendCommand(0x4C57696E)
            let windowList = try XCTUnwrap(windows.paramDescriptor(forKeyword: keyDirectObject))
            XCTAssertEqual(windowList.descriptorType, typeAEList)
            let windowRecord = try XCTUnwrap(windowList.atIndex(1))
            XCTAssertTrue(windowRecord.isRecordDescriptor)
            XCTAssertEqual(windowRecord.forKeyword(0x49442020)?.stringValue, app.windows[0].id.uuidString)

            let reply = try self.sendCommand(0x4F546162, directParameter: "https://example.com/apple-event",
                                             windowID: app.windows[0].id.uuidString)
            let tabRecord = try XCTUnwrap(reply.paramDescriptor(forKeyword: keyDirectObject))
            XCTAssertTrue(tabRecord.isRecordDescriptor)
            XCTAssertEqual(tabRecord.forKeyword(0x7055524C)?.stringValue, "https://example.com/apple-event")
            XCTAssertEqual(tabRecord.forKeyword(0x4362536C)?.booleanValue, true)

            let page = try XCTUnwrap(app.windows[0].selectedPage as? TestPage)
            page.state.hasPendingPrompt = true
            let busy = try self.sendCommand(0x4F546162, directParameter: "https://example.com/busy",
                                            windowID: app.windows[0].id.uuidString)
            XCTAssertEqual(busy.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value,
                           Int32(NSReceiversCantHandleCommandScriptError))
            page.state.hasPendingPrompt = false

            let invalid = try self.sendCommand(0x4F546162, directParameter: "file:///private/fixture",
                                               windowID: app.windows[0].id.uuidString)
            XCTAssertEqual(invalid.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, Int32(NSArgumentsWrongScriptError))
        }
    }

    func testListsExcludePrivateAndRedactNonWebTabs() async throws {
        try await withApp { app, _ in
            let normal = app.windows[0]
            normal.record.tabs.append(Tab(urlString: "file:///Users/secret/report.pdf", title: "/Users/secret/report.pdf"))
            let privateWindow = app.newWindow(isPrivate: true)

            let windows = try CobbleScriptTabs.listWindows()
            XCTAssertEqual(windows.count, 1)
            XCTAssertEqual(windows[0]["id"] as? String, normal.id.uuidString)
            XCTAssertFalse(windows.contains { $0["id"] as? String == privateWindow.id.uuidString })

            let tab = try XCTUnwrap(try CobbleScriptTabs.listTabs(arguments: ["windowID": normal.id.uuidString]).first)
            XCTAssertEqual(tab["url"] as? String, "")
            XCTAssertEqual(tab["title"] as? String, "")
            XCTAssertThrowsError(try CobbleScriptTabs.listTabs(arguments: ["windowID": privateWindow.id.uuidString]))
        }
    }

    func testRejectsDeletingProfilesAndPromptingClose() async throws {
        try await withApp { app, _ in
            let profile = try XCTUnwrap(app.createProfile(name: "Work"))
            let window = try XCTUnwrap(app.newWindow(profileID: profile.id))
            let args = ["windowID": window.id.uuidString]
            let opened = try CobbleScriptTabs.openTab(directParameter: "https://example.com", arguments: args)
            let tabID = try XCTUnwrap(opened["id"] as? String)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.capabilities.requiresCloseConfirmation = true
            XCTAssertThrowsError(try CobbleScriptTabs.closeTab(directParameter: tabID, arguments: args))

            page.delayCloseRequest = true
            let deletion = Task { await app.deleteProfile(profile.id) }
            try await eventually { app.isDeletingProfile(profile.id) && page.closeRequest != nil }
            XCTAssertThrowsError(try CobbleScriptTabs.listTabs(arguments: args))
            XCTAssertThrowsError(try CobbleScriptTabs.openTab(directParameter: "https://example.com/new", arguments: args))
            page.state.lifecycle = .closed
            page.events.onClose?()
            page.finishCloseRequest(accepted: true)
            let deletionError = await deletion.value
            XCTAssertNil(deletionError)
        }
    }

    func testMutationsRejectPromptsTerminationAndSelectedBatchClose() async throws {
        try await withApp { app, _ in
            let window = app.windows[0]
            let args = ["windowID": window.id.uuidString]
            let first = try CobbleScriptTabs.openTab(directParameter: "https://example.com/first", arguments: args)
            let firstID = try XCTUnwrap(first["id"] as? String)
            let second = try CobbleScriptTabs.openTab(directParameter: "https://example.com/second", arguments: args)
            let secondID = try XCTUnwrap(second["id"] as? String)
            window.select(UUID(uuidString: firstID)!)
            let page = try XCTUnwrap(window.selectedPage as? TestPage)
            page.state.hasPendingPrompt = true

            XCTAssertThrowsError(try CobbleScriptTabs.openTab(directParameter: "https://example.com/blocked", arguments: args))
            XCTAssertThrowsError(try CobbleScriptTabs.selectTab(directParameter: secondID, arguments: args))
            XCTAssertThrowsError(try CobbleScriptTabs.closeTab(directParameter: secondID, arguments: args))
            XCTAssertEqual(window.selectedTab?.id.uuidString, firstID)
            XCTAssertEqual(window.record.tabs.count, 2)
            page.state.hasPendingPrompt = false

            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            let termination = Task { await window.requestClosePages() }
            try await self.eventually { page.closeRequest != nil }
            XCTAssertThrowsError(try CobbleScriptTabs.openTab(directParameter: "https://example.com/termination", arguments: args))
            XCTAssertThrowsError(try CobbleScriptTabs.selectTab(directParameter: secondID, arguments: args))
            page.finishCloseRequest(accepted: false)
            let terminationResult = await termination.value
            XCTAssertFalse(terminationResult)

            window.selectTemporaryTab(UUID(uuidString: secondID)!, modifiers: [.command])
            window.closeSelectedTemporaryTabs()
            try await self.eventually { page.closeRequest != nil }
            XCTAssertThrowsError(try CobbleScriptTabs.closeTab(directParameter: secondID, arguments: args))
            page.finishCloseRequest(accepted: false)
        }
    }
}
