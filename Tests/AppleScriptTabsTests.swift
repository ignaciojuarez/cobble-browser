import AppKit
import XCTest
@testable import Cobble

@MainActor final class AppleScriptTabsTests: XCTestCase {
    private func withApp(_ body: (AppModel, TestEngine) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleScriptTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = TestEngine(.webKit)
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([engine]))
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

    private func sendCommand(_ id: AEEventID, directParameter: String? = nil, windowID: String? = nil) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: 0x4362626C, eventID: id,
                                           targetDescriptor: .currentProcess(),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if let directParameter { event.setParam(NSAppleEventDescriptor(string: directParameter), forKeyword: keyDirectObject) }
        if let windowID { event.setParam(NSAppleEventDescriptor(string: windowID), forKeyword: 0x4362576E) }
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
