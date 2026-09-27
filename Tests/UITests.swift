import AppKit
import SwiftUI
import XCTest
@testable import Cobble

@MainActor
final class UITests: XCTestCase {
    func testGeneralSettingsToggleSavesAndRefreshes() async throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        for source in [nil, Data("not JSON".utf8)] {
            try await withWindow(preferencesData: source) { model, _, _ in
                model.app.settingsSection = .general
                let application = CobbleApp(model: model.app)
                let priorMenu = NSApp.mainMenu
                model.app.preferences.onChange = { application.buildMenus() }
                defer { model.app.preferences.onChange = nil; NSApp.mainMenu = priorMenu }
                let settings = NSHostingView(rootView: SettingsView(app: model.app))
                let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = settings
                window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(200))
                settings.layoutSubtreeIfNeeded()
                func switches(in view: NSView) -> [NSSwitch] {
                    (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
                }
                var control = try XCTUnwrap(switches(in: settings).first)
                XCTAssertEqual(control.state, .off)
                if source != nil {
                    XCTAssertFalse(control.isEnabled)
                    let resetButton = await accessibilityButton(String(localized: "Back Up and Reset Settings"), in: window, hosting: settings)
                    let reset = try XCTUnwrap(resetButton, (accessibilityTree(in: settings) + nativeButtonDescriptions(in: settings)).joined(separator: "\n"))
                    XCTAssertEqual(reset.accessibilityPerformPress?(), true)
                    try await Task.sleep(for: .milliseconds(200))
                    settings.layoutSubtreeIfNeeded()
                    control = try XCTUnwrap(switches(in: settings).first)
                }
                XCTAssertTrue(control.isEnabled)
                control.performClick(nil)
                try await Task.sleep(for: .milliseconds(200))
                settings.layoutSubtreeIfNeeded()
                XCTAssertTrue(model.app.preferences.experimentalLoginSharing, model.app.preferences.errorMessage ?? "")
                XCTAssertEqual(control.state, .on)
                XCTAssertTrue(BrowserPreferences(directory: model.app.store.directory).experimentalLoginSharing)
            }
        }
    }

    func testBrowserWindowDoesNotFocusAddressUntilRequested() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        let tab = Tab(urlString: "https://startup.example/", title: "Startup fixture")
        var record = WindowRecord()
        record.tabs = [tab]
        record.selectedTabID = tab.id
        let model = BrowserWindowModel(app: app, record: record)
        app.library.bookmark(urlString: model.addressDraft, title: "Startup fixture", profileID: model.record.profileID)
        let controller = BrowserWindowController(model: model, onClose: { _ in })
        let window = try XCTUnwrap(controller.window)
        defer {
            window.contentView = nil
            window.close()
            model.closePages()
            app.flush()
            app.library.close()
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertTrue(window.initialFirstResponder === window.contentView)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(model.isEditingAddress)
        XCTAssertTrue(model.addressSuggestions.isEmpty)
        XCTAssertNotEqual((window.firstResponder as? NSTextView)?.isFieldEditor, true)

        let work = Space(name: "Work")
        let pin = SavedItem(spaceID: work.id, title: "Dormant pin")
        app.spaces.append(work)
        app.savedItems.append(pin)
        model.record.tabs.append(Tab(spaceID: work.id, savedItemID: pin.id))
        model.selectSpace(work.id)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.selectedTab)
        XCTAssertFalse(model.isEditingAddress)
        XCTAssertNotEqual((window.firstResponder as? NSTextView)?.isFieldEditor, true)

        model.focusAddress()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.isEditingAddress)
        XCTAssertFalse(model.addressSuggestions.isEmpty)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertEqual(editor.selectedRange().length, model.addressDraft.utf16.count)
    }

    func testThemeNavigationHidesDisabledControls() async throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        try await withWindow(engine: TestEngine(.webKit)) { model, nativeWindow, hosting in
            let tab = Tab(urlString: "https://theme-fixture.example/", title: "Navigation fixture")
            model.record.tabs = [tab]
            model.select(tab.id)
            for _ in 0..<100 where model.selectedPage == nil { try await Task.sleep(for: .milliseconds(10)) }
            let page = try XCTUnwrap(model.selectedPage)
            var back = await accessibilityButton("Back", in: nativeWindow, hosting: hosting)
            XCTAssertNil(back)
            var forward = await accessibilityButton("Forward", in: nativeWindow, hosting: hosting)
            XCTAssertNil(forward)
            page.state.canGoBack = true
            back = await accessibilityButton("Back", in: nativeWindow, hosting: hosting)
            XCTAssertNotNil(back)
            page.state.canGoForward = true
            forward = await accessibilityButton("Forward", in: nativeWindow, hosting: hosting)
            XCTAssertNotNil(forward)
            XCTAssertTrue(model.app.preferences.setTheme(.legacy))
            page.state.canGoBack = false
            back = await accessibilityButton("Back", in: nativeWindow, hosting: hosting)
            XCTAssertNotNil(back)
        }
    }

    func testThemesRenderAtMinimumWindowSize() async throws {
        try await withWindow { model, nativeWindow, hosting in
            let selected = Tab(title: "Selected tab")
            model.record.tabs = [selected]
            model.select(selected.id)
            nativeWindow.setContentSize(NSSize(width: 800, height: 500))
            for preset in [BrowserThemePreset.native, .legacy, .retro] {
                XCTAssertTrue(model.app.preferences.setTheme(preset))
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    nativeWindow.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .milliseconds(100))
                    hosting.layoutSubtreeIfNeeded()
                    XCTAssertEqual(hosting.bounds.width, 800, accuracy: 0.5)
                    let close = try XCTUnwrap(sidebarButton(0, in: hosting))
                    let expectedInset: CGFloat = 16
                    XCTAssertEqual(close.convert(close.bounds, to: hosting).minX, expectedInset, accuracy: 0.5)
                    try capture(hosting, name: "Theme \(preset.rawValue) \(appearance.rawValue)",
                                outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("CobbleThemeReview"))
                }
            }
        }
    }

    func testScreenshotSaveSheetCancellationDuplicateAndWindowCloseDoNotWriteFiles() async throws {
        try await withWindow { model, nativeWindow, hosting in
            @MainActor func waitUntil(_ condition: @MainActor () -> Bool) async throws -> Bool {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                return condition()
            }
            let output = model.app.store.directory.appendingPathComponent("Screenshot outputs", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let tab = Tab(title: "Screenshot save fixture")
            model.record.tabs = [tab]
            model.select(tab.id)
            let attached = try await waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return model.selectedPage?.state.lifecycle == .ready && model.selectedPage?.nativeView.window === nativeWindow
            }
            XCTAssertTrue(attached)
            let page = try XCTUnwrap(model.selectedPage)
            page.webView.loadHTMLString("<title>Screenshot save fixture</title><body style='background:orange'>Local screenshot fixture</body>", baseURL: nil)
            let loaded = try await waitUntil { page.webView.title == "Screenshot save fixture" && !page.webView.isLoading }
            XCTAssertTrue(loaded)
            // Save destination controls are configuration-only APIs. Full export through the
            // native picker remains foreground validation; viewport pixels are tested separately.
            model.pageFileOperations.saveScreenshot()
            XCTAssertTrue(model.pageFileOperations.isSavingScreenshot)
            model.pageFileOperations.saveScreenshot()
            let presented = try await waitUntil { nativeWindow.attachedSheet != nil || !model.pageFileOperations.isSavingScreenshot }
            if nativeWindow.attachedSheet == nil, !NSApp.isActive, model.pageFileOperations.isSavingScreenshot, model.addressError == nil {
                throw XCTSkip("Native screenshot Save panel needs foreground validation; this hosted process is inactive. No successful save-panel receipt is claimed.")
            }
            XCTAssertTrue(presented)
            let firstPanel = try XCTUnwrap(nativeWindow.attachedSheet as? NSSavePanel, model.addressError ?? "Expected the real screenshot Save panel")
            XCTAssertFalse(model.canPerform(.screenshot))
            model.pageFileOperations.saveScreenshot()
            await Task.yield()
            XCTAssertTrue(nativeWindow.attachedSheet === firstPanel)
            XCTAssertEqual(nativeWindow.sheets.count, 1)
            firstPanel.cancel(nil)
            let cancelled = try await waitUntil { !model.pageFileOperations.isSavingScreenshot && nativeWindow.attachedSheet == nil }
            XCTAssertTrue(cancelled)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            XCTAssertNil(model.addressError)

            model.pageFileOperations.saveScreenshot()
            let represented = try await waitUntil { nativeWindow.attachedSheet != nil || !model.pageFileOperations.isSavingScreenshot }
            XCTAssertTrue(represented)
            _ = try XCTUnwrap(nativeWindow.attachedSheet as? NSSavePanel, model.addressError ?? "Expected a second explicit save operation")
            model.closePages()
            nativeWindow.close()
            let closed = try await waitUntil { !model.pageFileOperations.hasPendingOperations && nativeWindow.attachedSheet == nil }
            XCTAssertTrue(closed)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            XCTAssertFalse(model.canPerform(.screenshot))
        }
    }

    func testNestedFoldersExposeLevelsAndCollapseDescendants() async throws {
        try await withWindow(isPrivate: false) { model, nativeWindow, hosting in
            let root = Folder(name: "Projects")
            let child = Folder(parentID: root.id, name: "Research")
            let grandchild = Folder(parentID: child.id, name: "Notes")
            model.app.folders = [root, child, grandchild]
            model.app.savedItems = []
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            func folderLabel(_ name: String, _ depth: Int, _ state: String) -> String {
                String(format: String(localized: "%@, level %@, %@ folder"), name, String(depth),
                       state == "expanded" ? String(localized: "expanded") : String(localized: "collapsed"))
            }
            let rootLabel = folderLabel("Projects", 1, "expanded")
            let childLabel = folderLabel("Research", 2, "expanded")
            let grandchildLabel = folderLabel("Notes", 3, "expanded")
            let rootButton = await accessibilityButton(rootLabel, in: nativeWindow, hosting: hosting)
            let childButton = await accessibilityButton(childLabel, in: nativeWindow, hosting: hosting)
            let grandchildButton = await accessibilityButton(grandchildLabel, in: nativeWindow, hosting: hosting)
            XCTAssertNotNil(childButton)
            XCTAssertNotNil(grandchildButton)
            try await Task.sleep(for: .milliseconds(300))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            try capture(hosting, name: "Nested folders expanded")
            XCTAssertEqual(try XCTUnwrap(rootButton).accessibilityPerformPress?(), true)
            let collapsed = await accessibilityButton(folderLabel("Projects", 1, "collapsed"), in: nativeWindow, hosting: hosting)
            XCTAssertNotNil(collapsed)
            XCTAssertNil(accessibilityButton(childLabel, in: nativeWindow))
            XCTAssertNil(accessibilityButton(grandchildLabel, in: nativeWindow))
            XCTAssertEqual(try XCTUnwrap(collapsed).accessibilityPerformPress?(), true)
            let restored = await accessibilityButton(grandchildLabel, in: nativeWindow, hosting: hosting)
            XCTAssertNotNil(restored)
        }
    }

    func testSidebarResizeEdgeHitRegionDragLimitsAndDoubleClickReset() async throws {
        try await withWindow { model, nativeWindow, hosting in
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            func findHandle(_ view: NSView) -> SidebarResizeHandle.ResizeView? {
                if let handle = view as? SidebarResizeHandle.ResizeView { return handle }
                return view.subviews.lazy.compactMap(findHandle).first
            }
            let handle = try XCTUnwrap(findHandle(hosting))
            let frame = handle.convert(handle.bounds, to: hosting)
            XCTAssertEqual(frame.width, 32, accuracy: 0.5)
            XCTAssertEqual(frame.midX, 280, accuracy: 0.5)
            for delta in [-14.0, 14.0] {
                let point = NSPoint(x: frame.midX + delta, y: frame.midY)
                XCTAssertTrue(hosting.hitTest(hosting.convert(point, to: hosting.superview)) === handle,
                    "Both sides of the visible sidebar edge must receive native pointer events")
            }
            func event(_ type: NSEvent.EventType, x: Double, clicks: Int = 1) throws -> NSEvent {
                let point = hosting.convert(NSPoint(x: x, y: frame.midY), to: nil)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: nativeWindow.windowNumber, context: nil,
                    eventNumber: 0, clickCount: clicks, pressure: 1))
            }
            handle.mouseDown(with: try event(.leftMouseDown, x: 280))
            handle.mouseDragged(with: try event(.leftMouseDragged, x: 325))
            XCTAssertEqual(model.record.sidebarWidth, 325)
            handle.mouseDragged(with: try event(.leftMouseDragged, x: 1500))
            XCTAssertEqual(model.record.sidebarWidth, 440)
            handle.mouseDragged(with: try event(.leftMouseDragged, x: -500))
            XCTAssertEqual(model.record.sidebarWidth, 260)
            handle.mouseUp(with: try event(.leftMouseUp, x: 260))
            handle.mouseDown(with: try event(.leftMouseDown, x: 260, clicks: 2))
            handle.mouseDragged(with: try event(.leftMouseDragged, x: 400))
            XCTAssertNil(model.record.sidebarWidth, "Double click resets without starting another drag")
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(handle.width, 280)
            XCTAssertTrue(handle.accessibilityPerformIncrement())
            XCTAssertEqual(model.record.sidebarWidth, 300)
            XCTAssertTrue(handle.accessibilityPerformDecrement())
            XCTAssertEqual(model.record.sidebarWidth, 280)
            try capture(hosting, name: "Native sidebar edge after resize reset")
        }
    }

    func testSiteControlPopoverFitsLightDarkAndPrivateCaptureStates() async throws {
        for isPrivate in [false, true] {
            let engine = TestEngine(EngineID(rawValue: "site-controls-fixture"))
            engine.capabilities.supportsPopupPolicy = true
            try await withWindow(isPrivate: isPrivate, engine: engine) { model, _, _ in
                let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
                let previous = NSApp.accessibilityAttributeValue(enhanced)
                NSApp.accessibilitySetValue(true, forAttribute: enhanced)
                defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
                let tab = Tab(urlString: "https://camera-fixture.example.test/", title: "Site controls fixture", engineID: engine.id)
                model.record.tabs = [tab]
                model.select(tab.id)
                let page = try XCTUnwrap(model.selectedPage as? TestPage)
                page.capabilities = engine.capabilities
                page.capabilities.pageOperations = [.snapshot, .printPage]
                page.state.urlString = tab.urlString
                page.state.connection = .secure
                let leaf = PageCertificateDetails(subject: "camera-fixture.example.test", issuer: "Fixture CA",
                    validFrom: nil, validUntil: nil)
                page.connectionDetailsValue = PageConnectionDetails(url: tab.url!, connection: .secure,
                    certificate: leaf, certificateChain: [leaf], certificateChainTruncated: true,
                    certificateErrors: [], mixedContent: PageMixedContentDetails(displayed: false, ran: false,
                        containedForm: false, displayedWithCertificateErrors: false, ranWithCertificateErrors: false))
                page.state.connectionDetailsReady = true
                page.state.camera = .active
                page.state.microphone = .muted
                page.state.isDisplayCapturing = true
                for scheme in [ColorScheme.light, .dark] {
                    let panel = NSHostingView(rootView: AnyView(SiteControlPopover(window: model)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, scheme)))
                    panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    let panelWindow = NSWindow(contentRect: NSRect(x: 400, y: 100, width: 308,
                        height: panel.fittingSize.height),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    panelWindow.isReleasedWhenClosed = false
                    panelWindow.contentView = panel
                    panelWindow.orderFront(nil)
                    defer { panel.rootView = AnyView(EmptyView()); panelWindow.contentView = nil; panelWindow.close() }
                    var connectionTree = ""
                    for _ in 0..<20 {
                        await Task.yield()
                        panel.layoutSubtreeIfNeeded()
                        panel.displayIfNeeded()
                        connectionTree = accessibilityTree(in: panel).joined(separator: "\n")
                        if connectionTree.contains("Certificate Chain")
                            && connectionTree.contains("Some certificate details aren’t shown.") { break }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    XCTAssertTrue(connectionTree.contains("Certificate Chain"))
                    XCTAssertTrue(connectionTree.contains("Some certificate details aren’t shown."))
                    // The certificate task changes the intrinsic height after the window is first shown.
                    for _ in 0..<2 {
                        await Task.yield()
                        panel.layoutSubtreeIfNeeded()
                        panelWindow.setContentSize(NSSize(width: 308, height: panel.fittingSize.height))
                    }
                    let height = panel.fittingSize.height
                    XCTAssertGreaterThan(height, 180)
                    XCTAssertLessThan(height, 550)
                    try capture(panel, name: "Site controls \(isPrivate ? "private" : "normal") \(scheme == .dark ? "dark" : "light") active camera muted microphone")
                    for label in [BrowserCommand.sharePage.title, BrowserCommand.screenshot.title,
                                  BrowserCommand.copyURL.title,
                                  "Mute Camera", "Stop Camera", "Unmute Microphone", "Stop Microphone"] {
                        let candidate = await accessibilityButton(label, in: panelWindow, hosting: panel)
                        if candidate == nil {
                            let attachment = XCTAttachment(string: (nativeButtonDescriptions(in: panel) + accessibilityTree(in: panel)).joined(separator: "\n"))
                            attachment.name = "Missing site control \(label)"
                            attachment.lifetime = .keepAlways
                            add(attachment)
                        }
                        let button = try XCTUnwrap(candidate, "Missing site control: \(label)")
                        let buttonFrame = try XCTUnwrap(button.accessibilityFrame?())
                        let bounds = panelWindow.convertToScreen(panel.convert(panel.bounds, to: nil))
                        XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(buttonFrame), "\(label) must fit the popover")
                    }
                }
            }
        }
    }

    func testSiteControlPopoverOmitsUnsupportedEngineControls() async throws {
        let engine = TestEngine(EngineID(rawValue: "Limited Engine"))
        // An individual page can offer less than its engine (for example a document viewer).
        engine.capabilities.pageOperations = [.snapshot]
        engine.capabilities.supportsPopupPolicy = true
        try await withWindow(isPrivate: false, engine: engine) { model, _, _ in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            let tab = Tab(urlString: "https://limited.example.test/", title: "Limited fixture", engineID: engine.id)
            model.record.tabs = [tab]
            model.select(tab.id)
            let page = try XCTUnwrap(model.selectedPage as? TestPage)
            page.capabilities = EngineCapabilities()
            let panel = NSHostingView(rootView: AnyView(SiteControlPopover(window: model)))
            let panelWindow = NSWindow(contentRect: NSRect(x: 400, y: 100, width: 308, height: panel.fittingSize.height),
                styleMask: [.titled], backing: .buffered, defer: false)
            panelWindow.isReleasedWhenClosed = false
            panelWindow.contentView = panel
            panelWindow.orderFront(nil)
            defer { panel.rootView = AnyView(EmptyView()); panelWindow.contentView = nil; panelWindow.close() }
            await Task.yield()
            panel.layoutSubtreeIfNeeded()

            // Positive controls prevent an empty accessibility tree from passing the omissions.
            for label in [BrowserCommand.sharePage.title, BrowserCommand.copyURL.title] {
                let button = await accessibilityButton(label, in: panelWindow, hosting: panel)
                XCTAssertNotNil(button, "Supported action must remain available: \(label)")
            }
            let tree = accessibilityTree(in: panel).joined(separator: "\n")
            XCTAssertFalse(tree.contains("Camera"))
            XCTAssertFalse(tree.contains("Microphone"))
            XCTAssertFalse(tree.contains("Popups"))
            XCTAssertFalse(tree.contains("Unavailable"))
            let screenshot = await accessibilityButton(BrowserCommand.screenshot.title, in: panelWindow, hosting: panel)
            XCTAssertNil(screenshot)
        }
    }

    func testCombinedCaptureControlDisclosesRevocationBehavior() async throws {
        let engine = TestEngine(EngineID(rawValue: "combined-capture-fixture"))
        engine.capabilities.permissions = [.camera, .microphone]
        engine.capabilities.captureControls = [.stopAllUserMedia]
        try await withWindow(isPrivate: false, engine: engine) { model, _, _ in
            let tab = Tab(urlString: "https://camera-fixture.example.test/", title: "Capture fixture", engineID: engine.id)
            model.record.tabs = [tab]
            model.select(tab.id)
            let page = try XCTUnwrap(model.selectedPage as? TestPage)
            page.capabilities = engine.capabilities
            page.state.urlString = tab.urlString
            page.state.camera = .active
            page.state.microphone = .active
            let controls = SiteControlPopover(window: model)
            XCTAssertTrue(controls.showsCombinedCaptureControl)
            XCTAssertEqual(controls.combinedCaptureDisclosure,
                "Permission changes apply to the next request. Stop Camera and Microphone ends the current capture.")
        }
    }

    func testNativeMenusFollowKeyWindowSuppressSheetsAndDistinguishTabClosure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleCommandWindows-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(store: SessionStore(directory: directory), websiteDataStoreOverride: .nonPersistent())
        let delegate = CobbleApp(model: app)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        var nativeWindows: [NSWindow] = []
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.setActivationPolicy(previousPolicy)
            for window in nativeWindows {
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
                // Release SwiftUI's unowned model references before app teardown.
                window.contentView = nil
                window.close()
            }
            app.windows.forEach { $0.closePages() }
            app.flush()
            app.library.close()
            withExtendedLifetime(delegate) {}
        }
        await app.engines.engine(.webKit)?.contentBlocker?.waitUntilReady()
        let first = app.newWindow()
        let second = app.newWindow()
        for model in [first, second] {
            model.record.tabs = [Tab(title: "First local tab"), Tab(title: "Second local tab")]
            model.select(model.record.tabs[0].id)
            delegate.show(model)
            let nativeWindow = try XCTUnwrap(NSApp.windows.first {
                ($0.windowController as? BrowserWindowController)?.model === model
            })
            nativeWindows.append(nativeWindow)
        }
        delegate.buildMenus()
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func item(_ command: BrowserCommand, in menu: NSMenu) -> NSMenuItem? {
            for row in menu.items {
                if row.target === delegate && row.tag == command.rawValue + 1,
                   row.action == NSSelectorFromString("performBrowserCommand:") { return row }
                if let submenu = row.submenu, let found = item(command, in: submenu) { return found }
            }
            return nil
        }
        func perform(_ command: BrowserCommand) throws {
            let row = try XCTUnwrap(item(command, in: menu))
            let owner = try XCTUnwrap(row.menu)
            owner.update()
            XCTAssertTrue(row.isEnabled)
            owner.performActionForItem(at: owner.index(of: row))
        }
        func shortcut(_ command: BrowserCommand, window: NSWindow) throws -> NSEvent {
            let key = app.preferences.shortcut(for: command)
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: key.flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: key.key, charactersIgnoringModifiers: key.key, isARepeat: false, keyCode: 0))
        }
        func settle(_ condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard condition() else {
                XCTFail("Native window did not reach the expected state")
                throw EngineError.notReady("Native window did not reach the expected state")
            }
        }
        let firstWindow = nativeWindows[0]
        let secondWindow = nativeWindows[1]
        firstWindow.makeKeyAndOrderFront(nil)
        let activationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !NSApp.isActive, ContinuousClock.now < activationDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try XCTSkipUnless(NSApp.isActive, "Native key-window routing requires an active GUI session; this hosted process cannot activate. Run this test from Xcode with Cobble in the foreground.")
        try await settle { NSApp.keyWindow === firstWindow }
        try perform(.nextTab)
        XCTAssertEqual(first.record.selectedTabID, first.record.tabs[1].id)
        XCTAssertEqual(second.record.selectedTabID, second.record.tabs[0].id)
        let firstFocus = first.addressFocusRequest
        let secondFocus = second.addressFocusRequest
        secondWindow.makeKeyAndOrderFront(nil)
        try await settle { NSApp.keyWindow === secondWindow }
        XCTAssertTrue(menu.performKeyEquivalent(with: try shortcut(.address, window: secondWindow)))
        XCTAssertEqual(first.addressFocusRequest, firstFocus)
        XCTAssertNotEqual(second.addressFocusRequest, secondFocus)
        let repeatedFocus = second.addressFocusRequest
        XCTAssertTrue(menu.performKeyEquivalent(with: try shortcut(.address, window: secondWindow)))
        XCTAssertNotEqual(second.addressFocusRequest, repeatedFocus)

        let alert = PagePresenter.alert(title: "Local command fixture", message: "Window commands are suspended", buttons: ["OK"])
        alert.beginSheetModal(for: secondWindow, completionHandler: { _ in })
        try await settle { secondWindow.attachedSheet != nil }
        let selectedBeforeSheet = second.record.selectedTabID
        for command in [BrowserCommand.nextTab, .address, .closeTab, .closeWindow] {
            let row = try XCTUnwrap(item(command, in: menu))
            XCTAssertFalse(delegate.validateMenuItem(row), "\(command) must not target a browser behind a sheet")
        }
        _ = menu.performKeyEquivalent(with: try shortcut(.nextTab, window: secondWindow))
        XCTAssertEqual(second.record.selectedTabID, selectedBeforeSheet)
        secondWindow.endSheet(alert.window, returnCode: .cancel)
        try await settle { secondWindow.attachedSheet == nil }
        secondWindow.makeKeyAndOrderFront(nil)
        try await settle { NSApp.keyWindow === secondWindow }
        for remaining in [1, 0] {
            try perform(.closeTab)
            try await settle { second.record.tabs.count == remaining }
            XCTAssertTrue(secondWindow.isVisible)
            XCTAssertTrue(app.windows.contains { $0 === second })
        }
        XCTAssertNil(second.record.selectedTabID)
        XCTAssertEqual(first.record.tabs.count, 2)
        // Drop the closed window's graph before its model leaves app.windows.
        secondWindow.contentView = nil
        try perform(.closeWindow)
        try await settle { !secondWindow.isVisible && !app.windows.contains { $0 === second } }
        XCTAssertTrue(firstWindow.isVisible)
        XCTAssertTrue(app.windows.contains { $0 === first })
    }

    func testAddressSuggestionButtonNavigatesExistingTab() async throws {
        try await withWindow(isPrivate: false) { model, nativeWindow, hosting in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            let tab = Tab(title: "Current tab")
            model.record.tabs = [tab]
            model.select(tab.id)
            let rowBefore = await accessibilityButton("Favorite: Daily favorites, unloaded", in: nativeWindow, hosting: hosting)
            let sidebarRowBefore = try XCTUnwrap(rowBefore)
            let frameBefore = try XCTUnwrap(sidebarRowBefore.accessibilityFrame?())
            let destination = "http://127.0.0.1:9/address-completion"
            model.app.library.bookmark(urlString: destination, title: "Address completion fixture", profileID: model.record.profileID)
            model.focusAddress()
            await Task.yield()
            model.addressDraft = "Address completion fixture"
            let candidate = await accessibilityButton("Open Address completion fixture in current tab", in: nativeWindow, hosting: hosting)
            let button = try XCTUnwrap(candidate)
            let rowAfter = await accessibilityButton("Favorite: Daily favorites, unloaded", in: nativeWindow, hosting: hosting)
            let sidebarRowAfter = try XCTUnwrap(rowAfter)
            let frameAfter = try XCTUnwrap(sidebarRowAfter.accessibilityFrame?())
            XCTAssertEqual(frameBefore, frameAfter, "Address suggestions must overlay the sidebar without moving its rows")
            try capture(hosting, name: "Address suggestions overlay without sidebar movement")
            XCTAssertEqual(button.accessibilityPerformPress?(), true)
            XCTAssertEqual(model.record.tabs.map(\.id), [tab.id])
            XCTAssertEqual(model.addressDraft, destination)
            XCTAssertFalse(model.isEditingAddress)
        }
    }

    func testSidebarBackgroundDismissesAddressSuggestions() async throws {
        try await withWindow(isPrivate: false) { model, nativeWindow, hosting in
            let tab = Tab(title: "Current tab")
            model.record.tabs = [tab]
            model.select(tab.id)
            model.app.library.bookmark(urlString: "https://suggestion.example/", title: "Suggestion fixture",
                                       profileID: model.record.profileID)
            model.focusAddress()
            model.addressDraft = "Suggestion fixture"
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(model.isEditingAddress)
            XCTAssertFalse(model.addressSuggestions.isEmpty)

            let swipe = try XCTUnwrap(swipeView(in: hosting))
            XCTAssertEqual(swipe.window, nativeWindow)
            XCTAssertGreaterThan(swipe.bounds.width, 0)
            XCTAssertGreaterThan(swipe.bounds.height, 0)
            let point = swipe.convert(NSPoint(x: swipe.bounds.midX, y: swipe.bounds.midY), to: nil)
            let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated().map { index, type in
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 40 + index,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            }
            dispatchPointerSequence(events.compactMap({ $0 }))
            await Task.yield()
            XCTAssertFalse(model.isEditingAddress)
        }
    }

    func testSavedRowsExposeMediaControlsForPinsAndFavorites() async throws {
        try await withWindow(isPrivate: false) { model, nativeWindow, hosting in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced) as? Bool ?? false
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            await model.app.engines.engine(.webKit)?.contentBlocker?.waitUntilReady()
            for favorite in [false, true] {
                let item = SavedItem(spaceID: favorite ? nil : model.record.selectedSpaceID,
                                     title: favorite ? "Media Favorite" : "Media Pin")
                model.app.savedItems = [item]
                model.openSavedItem(item.id)
                let host = try XCTUnwrap(model.selectedPage)
                try host.setAudioMuted(true)
                let candidate = await accessibilityButton("Unmute \(item.title)", in: nativeWindow, hosting: hosting)
                let button = try XCTUnwrap(candidate, "Saved rows must expose their own media control")
                XCTAssertEqual(button.accessibilityPerformPress?(), true)
                XCTAssertFalse(host.state.isAudioMuted)
                model.closeTab(host.tabID)
            }
        }
    }

    func testMediaPermissionAnchorChipStaysInAddressChrome() async throws {
        try await withWindow(isPrivate: false) { model, nativeWindow, hosting in
            let tab = Tab(urlString: "https://anchor-fixture.example.test/", title: "Anchor fixture")
            model.record.tabs = [tab]
            model.select(tab.id)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while model.selectedPage == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            hosting.layoutSubtreeIfNeeded()
            let host = try XCTUnwrap(model.selectedPage)
            let anchor = try XCTUnwrap(SiteControlAnchorView.find(in: hosting, tabID: tab.id, contextID: host.contextID))
            let chip = anchor.convert(anchor.positioningRect, to: hosting)
            XCTAssertEqual(chip.width, 22, accuracy: 1)
            XCTAssertEqual(chip.height, 22, accuracy: 1)
            XCTAssertLessThan(chip.minY, 140, "Permission arrow must sit in address chrome, not the tab list")
            XCTAssertGreaterThan(chip.minX, 180)
            XCTAssertLessThan(chip.maxX, 290)
        }
    }

    func testCaptureBadgesShowBackgroundSavedTabsAndClearWhenUnloaded() async throws {
        try await withWindow(isPrivate: false) { model, nativeWindow, hosting in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            await model.app.engines.engine(.webKit)?.contentBlocker?.waitUntilReady()
            let favorite = SavedItem(title: "Favorite meeting")
            let pin = SavedItem(spaceID: model.record.selectedSpaceID, title: "Pinned meeting")
            model.app.savedItems = [favorite, pin]
            model.openSavedItem(favorite.id)
            let favoriteHost = try XCTUnwrap(model.selectedPage)
            model.openSavedItem(pin.id)
            let pinHost = try XCTUnwrap(model.selectedPage)
            let temporary = Tab(title: "Temporary meeting")
            model.record.tabs.append(temporary)
            model.select(temporary.id)
            let temporaryHost = try XCTUnwrap(model.selectedPage)
            let html = "<title>Temporary meeting</title><body>Local capture-state fixture</body>"
            temporaryHost.navigate(to: URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (temporaryHost.webView.title != "Temporary meeting" ||
                   [favoriteHost, pinHost, temporaryHost].contains { $0.webView.isLoading }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try capture(hosting, name: "Capture fixture before state injection")
            let before = await accessibilityButton("Temporary meeting", in: nativeWindow, hosting: hosting)
            let beforeButton = try XCTUnwrap(before)
            let beforeFrame = try XCTUnwrap(beforeButton.accessibilityFrame?())
            // Inject reported engine state only: this fixture never requests camera/TCC access.
            favoriteHost.state.camera = .active
            pinHost.state.microphone = .active
            temporaryHost.state.camera = .active
            temporaryHost.state.microphone = .active
            func accessibilityValue(_ object: AnyObject) throws -> String {
                let node = try XCTUnwrap(object as? NSObject)
                let selector = NSSelectorFromString("accessibilityValue")
                guard node.responds(to: selector) else {
                    XCTFail("Sidebar capture control must expose an accessibility value")
                    return ""
                }
                return node.perform(selector)?.takeUnretainedValue() as? String ?? ""
            }
            for (label, value) in [
                ("Favorite: Favorite meeting, loaded", "Camera in use"),
                ("Pinned tab: Pinned meeting, loaded", "Microphone in use"),
                ("Temporary meeting", "Camera in use, Microphone in use")
            ] {
                let candidate = await accessibilityButton(label, in: nativeWindow, hosting: hosting)
                let button = try XCTUnwrap(candidate)
                XCTAssertEqual(try accessibilityValue(button), value)
            }
            XCTAssertEqual(model.record.selectedTabID, temporary.id, "Saved-tab indicators must work in background tabs")
            let active = await accessibilityButton("Temporary meeting", in: nativeWindow, hosting: hosting)
            let activeButton = try XCTUnwrap(active)
            let activeFrame = try XCTUnwrap(activeButton.accessibilityFrame?())
            XCTAssertEqual(activeFrame.height, beforeFrame.height, accuracy: 0.5)
            XCTAssertEqual(activeFrame.width, beforeFrame.width, accuracy: 0.5)
            try capture(hosting, name: "Active camera and microphone badges in all sidebar rows")
            temporaryHost.state.camera = .muted
            temporaryHost.state.microphone = .muted
            let muted = await accessibilityButton("Temporary meeting", in: nativeWindow, hosting: hosting)
            let mutedButton = try XCTUnwrap(muted)
            XCTAssertEqual(try accessibilityValue(mutedButton), "Camera muted, Microphone muted")
            try capture(hosting, name: "Muted capture uses slashed glyphs without recording dot")
            model.unloadSavedItem(favorite.id)
            let unloaded = await accessibilityButton("Favorite: Favorite meeting, unloaded", in: nativeWindow, hosting: hosting)
            let unloadedButton = try XCTUnwrap(unloaded)
            XCTAssertTrue(try accessibilityValue(unloadedButton).isEmpty)
            XCTAssertEqual(model.captureState(for: favoriteHost.tabID).camera, .none)
            XCTAssertEqual(model.captureState(for: favoriteHost.tabID).microphone, .none)
            XCTAssertFalse(model.captureState(for: favoriteHost.tabID).display)
            temporaryHost.state.camera = .none
            temporaryHost.state.microphone = .none
            temporaryHost.state.isDisplayCapturing = true
            let stopped = await accessibilityButton("Temporary meeting", in: nativeWindow, hosting: hosting)
            let stoppedButton = try XCTUnwrap(stopped)
            XCTAssertEqual(try accessibilityValue(stoppedButton), "Screen in use")
            XCTAssertTrue(model.captureState(for: temporaryHost.tabID).display)
        }
    }

    func testNativeSheetCancellationCompletesExactlyOnce() async throws {
        try await withWindow { _, nativeWindow, _ in
            let presenter = PagePresenter(window: { nativeWindow })
            let alert = PagePresenter.alert(title: "Test dialog", message: "Cancelled by page closure", buttons: ["OK"])
            var responses: [NSApplication.ModalResponse] = []
            presenter.present(alert) { responses.append($0) }
            presenter.cancelAll()
            presenter.cancelAll()
            await Task.yield()
            XCTAssertEqual(responses, [.cancel])
        }
    }

    func testRestoredFrameClampsPartiallyOffscreenPosition() throws {
        let display = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        for saved in [WindowFrame(x: 1400, y: 100, width: 1200, height: 800),
                      WindowFrame(x: -40, y: -100, width: 1200, height: 800)] {
            let frame = try XCTUnwrap(BrowserWindowController.restoredFrame(saved, visibleFrames: [display]))
            XCTAssertTrue(display.contains(frame))
            XCTAssertEqual(frame.size, NSSize(width: 1200, height: 800))
        }
    }

    func testRestoredFrameFitsDisplaySmallerThanMinimumWindow() throws {
        let display = NSRect(x: 0, y: 0, width: 640, height: 480)
        let saved = WindowFrame(x: 10, y: 10, width: 1200, height: 800)
        let frame = try XCTUnwrap(BrowserWindowController.restoredFrame(saved, visibleFrames: [display]))
        XCTAssertEqual(frame, display)
    }

    func testDisconnectedDisplayCentersRestoredFrameOnPrimary() throws {
        let primary = NSRect(x: 0, y: 25, width: 1920, height: 1055)
        let saved = WindowFrame(x: 4000, y: 100, width: 1200, height: 800)
        let frame = try XCTUnwrap(BrowserWindowController.restoredFrame(saved, visibleFrames: [primary]))
        XCTAssertEqual(frame.midX, primary.midX)
        XCTAssertEqual(frame.midY, primary.midY)
        XCTAssertTrue(primary.contains(frame))
        XCTAssertNil(BrowserWindowController.restoredFrame(saved, visibleFrames: []))
    }

    func testRestorationKeepsMatchingSecondaryDisplay() throws {
        let primary = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let saved = WindowFrame(x: -1300, y: 100, width: 1200, height: 800)
        let frame = try XCTUnwrap(BrowserWindowController.restoredFrame(saved, visibleFrames: [primary, secondary]))
        XCTAssertEqual(frame, NSRect(x: -1300, y: 100, width: 1200, height: 800))
    }

    func testNativeControlsStayInSidebarAcrossLayoutChanges() async throws {
        try await withWindow { model, nativeWindow, hosting in
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            try capture(hosting, name: "Native browser chrome")
            XCTAssertNil(model.selectedTab)
            XCTAssertTrue(model.isPrivate)

            XCTAssertTrue(model.record.tabs.isEmpty)
            XCTAssertEqual(nativeWindow.titleVisibility, .hidden)
            let closeButton = try XCTUnwrap(sidebarButton(0, in: hosting))
            let buttonFrame = closeButton.convert(closeButton.bounds, to: hosting)
            XCTAssertLessThan(buttonFrame.maxX, 280)
            XCTAssertEqual(hosting.isFlipped ? buttonFrame.midY : hosting.bounds.height - buttonFrame.midY, 25, accuracy: 0.5)
            // AppKit reapplies its native titlebar layout after our initial SwiftUI layout.
            // The sidebar host must correct those later frame changes as well.
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let original = try XCTUnwrap(nativeWindow.standardWindowButton(kind))
                original.setFrameOrigin(NSPoint(x: 8, y: 18))
                let button = try XCTUnwrap(sidebarButton(index, in: hosting))
                XCTAssertFalse(button === original)
                XCTAssertTrue(button.target === nativeWindow)
                XCTAssertTrue(original.isHidden)
                let corrected = button.convert(button.bounds, to: hosting)
                XCTAssertEqual(hosting.isFlipped ? corrected.midY : hosting.bounds.height - corrected.midY, 25, accuracy: 0.5)
            }
            model.sidebarVisible = false
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertNil(sidebarButton(0, in: hosting))
            XCTAssertNil(closeButton.window)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                XCTAssertTrue(try XCTUnwrap(nativeWindow.standardWindowButton(kind)).isHidden)
            }
            XCTAssertFalse(visualEffectViews(in: hosting).contains { $0.blendingMode == .withinWindow })
            try capture(hosting, name: "Hidden sidebar")
            let collapsedWidth = hosting.bounds.width

            model.sidebarPeeked = true
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.bounds.width, collapsedWidth)
            XCTAssertFalse(model.sidebarVisible)
            XCTAssertTrue(model.sidebarPeeked)
            let overlayClose = try XCTUnwrap(sidebarButton(0, in: hosting))
            XCTAssertLessThan(overlayClose.convert(overlayClose.bounds, to: hosting).maxX, 280)
            XCTAssertTrue(visualEffectViews(in: hosting).contains { $0.blendingMode == .withinWindow })
            try capture(hosting, name: "Overlay sidebar")

            model.sidebarVisible = true
            nativeWindow.setContentSize(NSSize(width: 800, height: 500))
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertFalse(model.sidebarPeeked)
            let restoredClose = try XCTUnwrap(sidebarButton(0, in: hosting))
            XCTAssertNotNil(restoredClose.window)
            let restoredButton = restoredClose.convert(restoredClose.bounds, to: hosting)
            XCTAssertLessThan(restoredButton.maxX, 280)
            XCTAssertEqual(hosting.isFlipped ? restoredButton.midY : hosting.bounds.height - restoredButton.midY, 25, accuracy: 0.5)
            for index in 0..<3 {
                let button = try XCTUnwrap(sidebarButton(index, in: hosting))
                let rect = button.convert(button.bounds, to: hosting)
                XCTAssertEqual(rect.minX, 16 + CGFloat(index) * 22, accuracy: 0.5)
                XCTAssertEqual(hosting.isFlipped ? rect.midY : hosting.bounds.height - rect.midY, 25, accuracy: 0.5)
            }
            try capture(hosting, name: "Sidebar at minimum window size")
            nativeWindow.setContentSize(NSSize(width: 1100, height: 720))

            model.record.sidebarWidth = 360
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            try capture(hosting, name: "Resized sidebar")
            XCTAssertEqual(restoredClose.frame.size, restoredClose.bounds.size)
            XCTAssertFalse(nativeWindow.isOpaque)
            model.record.sidebarWidth = 260
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            try capture(hosting, name: "Minimum sidebar width")
            model.record.sidebarWidth = nil
        }
    }

    func testCommandOverlayRendersWithoutCreatingPage() async throws {
        try await withWindow { model, _, hosting in
            model.openCommandBar()
            model.commandQuery = "New Tab"
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            try capture(hosting, name: "Native command overlay")
            XCTAssertTrue(model.commandBarPresented)
            XCTAssertNil(model.selectedPage?.webView.url)
        }
    }

    func testKeyboardSidebarPeekDismissesOnPageMouseMovedWithoutEnteringSidebar() async throws {
        try await withWindow { model, nativeWindow, hosting in
            model.sidebarVisible = false
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            model.revealSidebarChrome()
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertFalse(model.sidebarVisible)
            XCTAssertTrue(model.sidebarPeeked)

            func mouseMoved(x: CGFloat, windowNumber: Int) throws -> NSEvent {
                let point = hosting.convert(NSPoint(x: x, y: hosting.bounds.midY), to: nil)
                return try XCTUnwrap(NSEvent.mouseEvent(
                    with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0))
            }

            NSApp.sendEvent(try mouseMoved(x: 500, windowNumber: nativeWindow.windowNumber))
            await Task.yield()
            XCTAssertFalse(model.sidebarPeeked, "Keyboard peek must hide when the pointer is already in the page")

            model.revealSidebarChrome()
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(model.sidebarPeeked)
            NSApp.sendEvent(try mouseMoved(x: 500, windowNumber: 0))
            await Task.yield()
            XCTAssertFalse(model.sidebarPeeked, "Menus and other windows must dismiss an open peek")
        }
    }

    func testCommandOverlayTakesFocusFromAddressField() async throws {
        try await withWindow { model, nativeWindow, hosting in
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            let address = try XCTUnwrap(textField(placeholder: "Search or enter address", in: hosting))
            XCTAssertTrue(nativeWindow.makeFirstResponder(address))

            model.openCommandBar()
            var commandField: NSTextField?
            for _ in 0..<3 {
                await Task.yield()
                hosting.layoutSubtreeIfNeeded()
                commandField = textField(labeled: "Search, URL, or open tab", in: hosting)
                if let commandField,
                   (nativeWindow.firstResponder as? NSTextView)?.delegate as? NSTextField === commandField { break }
            }

            let field = try XCTUnwrap(commandField)
            XCTAssertTrue((nativeWindow.firstResponder as? NSTextView)?.delegate as? NSTextField === field)
        }
    }

    func testCommandSuggestionUsesOwningWindowDispatcher() async throws {
        try await withWindow { model, nativeWindow, hosting in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            let tab = Tab(title: "Local command fixture")
            model.record.tabs = [tab]
            model.select(tab.id)
            var dispatched: [BrowserCommand] = []
            model.onCommand = { [weak model] command in
                dispatched.append(command)
                return model?.perform(command) ?? false
            }
            model.openCommandBar()
            model.commandQuery = "duplicate"
            let candidate = await accessibilityButton("Duplicate Tab", in: nativeWindow, hosting: hosting)
            let button = try XCTUnwrap(candidate)
            XCTAssertEqual(button.accessibilityPerformPress?(), true)
            XCTAssertEqual(dispatched, [.duplicateTab])
            XCTAssertEqual(model.record.tabs.count, 2)
            XCTAssertFalse(model.commandBarPresented)
        }
    }

    func testNewTabSuggestionsStayInCurrentSpaceAndDuplicateAddressOpensHere() async throws {
        try await withWindow { model, nativeWindow, hosting in
            let currentSpace = model.record.selectedSpaceID
            let otherSpace = try XCTUnwrap(model.spaces.last)
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9/same-page"))
            let elsewhere = Tab(spaceID: otherSpace.id, urlString: url.absoluteString, title: "Existing elsewhere")
            let here = Tab(spaceID: currentSpace, urlString: url.absoluteString, title: "Existing here")
            model.record.tabs = [elsewhere, here]
            model.openCommandBar()
            XCTAssertEqual(CommandOverlay(window: model).matchingTabs.map(\.id), [here.id])
            model.commandQuery = url.absoluteString
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(CommandOverlay(window: model).matchingTabs.map(\.id), [here.id])
            model.commandQuery = "Existing elsewhere"
            XCTAssertTrue(CommandOverlay(window: model).matchingTabs.isEmpty)
            model.commandQuery = url.absoluteString
            try await focusCommandField(in: hosting, window: nativeWindow)
            try sendKey(36, characters: "\r", to: nativeWindow)
            await Task.yield()
            XCTAssertEqual(model.record.selectedSpaceID, currentSpace)
            XCTAssertEqual(model.record.tabs.count, 3)
            let opened = try XCTUnwrap(model.selectedTab)
            XCTAssertEqual(opened.spaceID, currentSpace)
            XCTAssertEqual(opened.urlString, url.absoluteString)
            XCTAssertNotEqual(opened.id, here.id)
            XCTAssertNotEqual(opened.id, elsewhere.id)
            XCTAssertEqual(model.record.tabs.first { $0.id == elsewhere.id }?.spaceID, otherSpace.id)
            XCTAssertFalse(model.commandBarPresented)
        }
    }

    func testDeletedLibrarySuggestionCannotOpenFromItsStaleButton() async throws {
        try await withWindow(isPrivate: false) { model, nativeWindow, hosting in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            let profile = model.record.profileID
            model.app.library.bookmark(urlString: "http://127.0.0.1:9/stale-bookmark", title: "Stale bookmark fixture", profileID: profile)
            let entry = try XCTUnwrap(model.app.library.search("Stale bookmark fixture", profileID: profile).first)
            model.openCommandBar()
            model.commandQuery = "Stale bookmark fixture"
            let candidate = await accessibilityButton("Open Stale bookmark fixture in a new tab", in: nativeWindow, hosting: hosting)
            let button = try XCTUnwrap(candidate)
            let before = model.record
            model.app.library.removeBookmark(id: entry.id, profileID: profile)
            // Invoke the old rendered action before SwiftUI processes the library revision.
            _ = button.accessibilityPerformPress?()
            XCTAssertEqual(model.record, before)
            XCTAssertTrue(model.commandBarPresented)
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(model.app.library.search("Stale bookmark fixture", profileID: profile).isEmpty)
        }
    }

    func testStaleOpenTabSuggestionCannotSwitchBackToAnotherSpace() async throws {
        try await withWindow { model, nativeWindow, hosting in
            let original = model.record.selectedSpaceID
            let other = try XCTUnwrap(model.spaces.last)
            let url = "http://127.0.0.1:9/stale-tab"
            let tab = Tab(spaceID: original, urlString: url, title: "Original tab")
            model.record.tabs = [tab]
            model.openCommandBar()
            model.commandQuery = url
            try await focusCommandField(in: hosting, window: nativeWindow)
            // Highlight the open-tab result, then change the space before pressing Return.
            for _ in 0..<2 {
                try sendKey(125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), to: nativeWindow)
                await Task.yield()
            }
            model.selectSpace(other.id)
            await Task.yield()
            try sendKey(36, characters: "\r", to: nativeWindow)
            await Task.yield()
            XCTAssertFalse(model.commandBarPresented)
            XCTAssertEqual(model.record.selectedSpaceID, other.id)
            XCTAssertEqual(model.record.tabs.count, 2)
            XCTAssertNotEqual(model.record.selectedTabID, tab.id)
            XCTAssertEqual(model.selectedTab?.urlString, url)
        }
    }

    private func sendKey(_ code: UInt16, characters: String, to window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
    }

    func testSettingsWindowCannotBecomeMain() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        XCTAssertFalse(window.canBecomeMain)
    }

    func testChromiumPageFocusRoutesFindShortcutThroughCobble() async throws {
        let engine = TestEngine(EngineID(rawValue: "chromium"))
        try await withWindow(isPrivate: false, engine: engine) { model, nativeWindow, _ in
            let tab = Tab(urlString: "https://example.test/", engineID: engine.id)
            model.record.tabs = [tab]
            model.select(tab.id)
            let page = try XCTUnwrap(model.selectedPage as? TestPage)
            page.capabilities.pageOperations = [.find]
            let editor = NSTextView(frame: page.nativeView.bounds)
            page.nativeView.addSubview(editor)
            for _ in 0..<50 where page.nativeView.window == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(nativeWindow.makeFirstResponder(editor))
            model.onKeyEvent = { event in
                let shortcut = BrowserShortcut(event.charactersIgnoringModifiers ?? "", event.modifierFlags)
                guard shortcut == model.app.preferences.shortcut(for: .find) else { return false }
                return model.dispatch(.find)
            }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: nativeWindow.windowNumber,
                context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
            let controller = try XCTUnwrap(nativeWindow.windowController as? BrowserWindowController)
            XCTAssertTrue(controller.performChromiumBrowserShortcut(event))
            XCTAssertTrue(model.findPresented)
        }
    }

    func testChromiumQuitShortcutUsesExactNativeKeyEquivalent() throws {
        func event(_ flags: NSEvent.ModifierFlags, _ key: String, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
        }
        XCTAssertTrue(BrowserWindowController.isQuitShortcut(try event(.command, "q")))
        XCTAssertTrue(BrowserWindowController.isQuitShortcut(try event(.command, "Q")))
        XCTAssertFalse(BrowserWindowController.isQuitShortcut(try event([.command, .shift], "q")))
        XCTAssertFalse(BrowserWindowController.isQuitShortcut(try event(.command, "w")))
        XCTAssertFalse(BrowserWindowController.isQuitShortcut(try event(.command, "q", type: .keyUp)))
    }

    func testSettingsRenderWithoutNetwork() async throws {
        try await withWindow { model, _, _ in
            let settingsRenders = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COBBLE_RENDER_OUTPUT"]
                ?? URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(".context/settings-renders", isDirectory: true).path,
                isDirectory: true)
            let workProfile = Profile(name: "Work", storeBinding: .named(UUID()))
            model.app.profiles.append(workProfile)
            model.app.spaces.append(Space(profileID: workProfile.id, name: "Work"))
            let extensionSource = model.app.store.directory
                .appendingPathComponent("SettingsRenderExtension", isDirectory: true)
            try makeSettingsExtension(at: extensionSource)
            let extensionManager = try XCTUnwrap(
                model.app.engines.engine(.webKit)?.extensionManager)
            let profileID = model.app.profiles[0].id
            try await extensionManager.install(from: extensionSource, profileID: profileID)
            let installed = try XCTUnwrap(extensionManager.extensions(profileID: profileID).first)
            try await extensionManager.setAllowedOrigins(
                ["https://example.com/*"], id: installed.id, profileID: profileID)
            try await extensionManager.setPrivateBrowsingAllowed(
                true, id: installed.id, profileID: profileID)
            let configured = try XCTUnwrap(
                extensionManager.extensions(profileID: profileID).first)
            XCTAssertEqual(configured.allowedOrigins, ["https://example.com/*"])
            XCTAssertEqual(configured.deniedPermissions, ["Native messaging"])
            XCTAssertTrue(configured.allowsPrivateBrowsing)
            let blocker = try XCTUnwrap(model.app.engines.engine(.webKit)?.contentBlocker)
            let defaultSource = try XCTUnwrap(URL(string: "https://default.blocker.fixture/rules.json"))
            let workSource = try XCTUnwrap(URL(string: "https://work.blocker.fixture/rules.json"))
            await blocker.installBundledRules(profileID: profileID)
            await blocker.setUpdateSource(defaultSource, profileID: profileID)
            await blocker.installBundledRules(profileID: workProfile.id)
            await blocker.setUpdateSource(workSource, profileID: workProfile.id)

            let toolbarDelegate = CobbleApp()
            let toolbar = NSToolbar(identifier: "settings")
            toolbar.delegate = toolbarDelegate
            toolbar.displayMode = .iconAndLabel
            toolbar.sizeMode = .regular
            toolbar.allowsUserCustomization = false
            let settingsWindow = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .resizable], backing: .buffered,
                defer: false)
            XCTAssertFalse(settingsWindow.canBecomeMain)
            settingsWindow.title = "Cobble Settings"
            settingsWindow.titleVisibility = .hidden
            settingsWindow.toolbarStyle = .preference
            settingsWindow.toolbar = toolbar
            settingsWindow.minSize = NSSize(width: 760, height: 540)
            settingsWindow.isReleasedWhenClosed = false
            let settings = NSHostingView(rootView: SettingsView(app: model.app))
            settingsWindow.contentView = settings
            settingsWindow.orderFront(nil)
            let frame = try XCTUnwrap(settingsWindow.contentView?.superview)
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.contentView = nil
                settingsWindow.toolbar = nil
                settingsWindow.close()
                withExtendedLifetime(toolbarDelegate) {}
            }

            @MainActor func select(_ section: SettingsSection) {
                model.app.settingsSection = section
                toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(
                    "settings.\(section.rawValue)")
            }
            @MainActor func verifyToolbar(selected section: SettingsSection) throws {
                let visibleItems = toolbar.visibleItems
                let items = try XCTUnwrap(visibleItems).filter {
                    $0.itemIdentifier.rawValue.hasPrefix("settings.")
                }
                let labels = items.map { $0.label }
                let allHaveImages = items.allSatisfy { $0.image != nil }
                let displayMode = toolbar.displayMode
                let selectedItemIdentifier = toolbar.selectedItemIdentifier
                XCTAssertEqual(items.count, SettingsSection.toolbarSections.count)
                XCTAssertEqual(labels, SettingsSection.toolbarSections.map(\.title))
                XCTAssertTrue(allHaveImages)
                XCTAssertEqual(displayMode, .iconAndLabel)
                XCTAssertEqual(selectedItemIdentifier,
                    NSToolbarItem.Identifier("settings.\(section.rawValue)"))
            }

            select(.general)
            var minimumFrame = settingsWindow.frame
            minimumFrame.size.width = 760
            settingsWindow.setFrame(minimumFrame, display: true)
            XCTAssertEqual(settingsWindow.frame.width, 760)
            settingsWindow.appearance = NSAppearance(named: .darkAqua)
            await Task.yield()
            settingsWindow.displayIfNeeded()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "Native settings", outputDirectory: settingsRenders)
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            try capture(frame, name: "General settings dark", outputDirectory: settingsRenders)
            settingsWindow.appearance = NSAppearance(named: .aqua)
            await Task.yield()
            settingsWindow.displayIfNeeded()
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            try capture(frame, name: "General settings light", outputDirectory: settingsRenders)
            select(.design)
            await Task.yield()
            settings.layoutSubtreeIfNeeded()
            try verifyToolbar(selected: .design)
            try capture(settings, name: "Design settings", outputDirectory: settingsRenders)
            select(.shortcuts)
            await Task.yield()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "Keyboard and gesture settings", outputDirectory: settingsRenders)
            settingsWindow.appearance = NSAppearance(named: .darkAqua)
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            try capture(frame, name: "Shortcut settings dark", outputDirectory: settingsRenders)
            settingsWindow.appearance = NSAppearance(named: .aqua)
            await Task.yield()
            settingsWindow.displayIfNeeded()
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            try capture(frame, name: "Shortcut settings light", outputDirectory: settingsRenders)
            select(.history)
            await Task.yield()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "History controls", outputDirectory: settingsRenders)
            select(.permissions)
            await Task.yield()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "Profile-scoped permissions", outputDirectory: settingsRenders)
            select(.blockers)
            await Task.yield()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "Profile-scoped content blocking", outputDirectory: settingsRenders)
            let sourcePlaceholder = String(localized: "HTTPS JSON URL")
            let sourceField = try XCTUnwrap(textField(placeholder: sourcePlaceholder, in: settings))
            XCTAssertEqual(sourceField.stringValue, defaultSource.absoluteString)
            for expectedSource in [workSource, defaultSource] {
                model.app.profiles.swapAt(0, 1)
                for _ in 0..<20 {
                    await Task.yield()
                    settings.layoutSubtreeIfNeeded()
                    if textField(placeholder: sourcePlaceholder, in: settings)?.stringValue == expectedSource.absoluteString { break }
                }
                XCTAssertEqual(textField(placeholder: sourcePlaceholder, in: settings)?.stringValue, expectedSource.absoluteString)
            }
            select(.browsing)
            await Task.yield()
            settingsWindow.displayIfNeeded()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "Browsing settings 900x620", outputDirectory: settingsRenders)
            try verifyToolbar(selected: .browsing)
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            try capture(frame, name: "Browsing settings toolbar 900 wide", outputDirectory: settingsRenders)
            select(.extensions)
            try await Task.sleep(for: .milliseconds(300))
            settingsWindow.displayIfNeeded()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "Extensions settings 900x620", outputDirectory: settingsRenders)
            try verifyToolbar(selected: .extensions)
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            try capture(frame, name: "Extensions settings toolbar 900 wide", outputDirectory: settingsRenders)
            select(.profiles)
            await Task.yield()
            settingsWindow.displayIfNeeded()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "Profiles settings 900x620", outputDirectory: settingsRenders)
            try verifyToolbar(selected: .profiles)
            minimumFrame = settingsWindow.frame
            minimumFrame.size.width = 820
            settingsWindow.setFrame(minimumFrame, display: true)
            settingsWindow.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(300))
            settingsWindow.displayIfNeeded()
            settings.layoutSubtreeIfNeeded()
            try capture(settings, name: "Profiles settings 820x540", outputDirectory: settingsRenders)
            try verifyToolbar(selected: .profiles)
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            try capture(frame, name: "Profiles settings toolbar 820 wide", outputDirectory: settingsRenders)
            settingsWindow.appearance = NSAppearance(named: .aqua)
            await Task.yield()
            settingsWindow.displayIfNeeded()
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            try capture(frame, name: "Profiles settings toolbar 820 wide light", outputDirectory: settingsRenders)
            for (section, name) in [(SettingsSection.shortcuts, "Shortcuts"), (.browsing, "Browsing"), (.privacy, "Privacy")] {
                select(section)
                await Task.yield()
                settingsWindow.displayIfNeeded()
                frame.layoutSubtreeIfNeeded()
                frame.displayIfNeeded()
                try verifyToolbar(selected: section)
                try capture(frame, name: "\(name) settings toolbar 820 wide", outputDirectory: settingsRenders)
            }
        }
    }

    func testProfileDeletionSuppressesPendingPageToolCompletions() async throws {
        let engine = TestEngine(.webKit)
        try await withWindow(isPrivate: false, engine: engine) { model, _, _ in
            let profile = try XCTUnwrap(model.app.createProfile(name: "Work"))
            let space = try XCTUnwrap(model.app.spaces.first { $0.profileID == profile.id })
            model.record.profileID = profile.id
            model.record.selectedSpaceID = space.id
            model.app.windows = [model]
            model.addTab(url: URL(string: "https://page-tools.example")!)
            let page = try XCTUnwrap(model.selectedPage as? TestPage)
            page.capabilities.pageOperations = [.localFile, .savePage, .pageDOM]
            page.capabilities.requiresCloseConfirmation = true
            page.delayCloseRequest = true
            page.delayArchive = true
            page.delayDOM = true
            for _ in 0..<200 where page.nativeView.window == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(page.nativeView.window)

            let presenters = PagePresenter.readOnlyTextWindows.count
            model.pageFileOperations.savePage()
            model.pageFileOperations.viewCurrentDOM()
            for _ in 0..<200 where page.archiveContinuation == nil || page.domContinuation == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNotNil(page.archiveContinuation)
            XCTAssertNotNil(page.domContinuation)

            let deletion = Task { await model.app.deleteProfile(profile.id) }
            for _ in 0..<200 where !model.app.isDeletingProfile(profile.id) || page.closeRequest == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(model.app.isDeletingProfile(profile.id))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleProfileDeletion.html")
            try "fixture".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try await model.acceptLocalFile(file)
                XCTFail("Expected profile deletion to reject the local file")
            } catch {}

            page.finishArchive(.success(Data("archive".utf8)))
            page.finishDOM(.success("<html><body>Private fixture content</body></html>"))
            await Task.yield()
            XCTAssertNil(model.addressError)
            XCTAssertEqual(PagePresenter.readOnlyTextWindows.count, presenters)

            let nativeClose = try XCTUnwrap(page.events.onClose)
            page.state.lifecycle = .closed
            nativeClose()
            page.finishCloseRequest(accepted: true)
            let result = await deletion.value
            XCTAssertNil(result)
        }
    }

    func testSpaceSwipePreviewsThenSwitchesOnReleaseAndSettlesOrCancels() async throws {
        try await withWindow { model, _, hosting in
            await model.app.contentBlocker?.waitUntilReady()
            let work = try XCTUnwrap(model.spaces.last)
            let folder = Folder(spaceID: work.id, name: "Work folder")
            model.app.folders.append(folder)
            let pin = SavedItem(spaceID: work.id, folderID: folder.id, title: "Neighbor pin")
            model.app.savedItems.append(pin)
            let tab = Tab(spaceID: work.id, title: "Neighbor temporary tab")
            model.record.tabs.append(tab)
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            let swipe = try XCTUnwrap(swipeView(in: hosting))
            let original = model.record.selectedSpaceID
            swipe.progress(-41.5, -83)
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            try capture(hosting, name: "Below space swipe commit threshold with neighbor folder and tab")
            XCTAssertEqual(model.record.selectedSpaceID, original)
            XCTAssertNil(model.selectedPage)
            XCTAssertFalse(model.isSavedItemLoaded(pin.id))
            swipe.progress(-42, -84)
            XCTAssertEqual(model.record.selectedSpaceID, original)
            XCTAssertNil(model.selectedPage, "Destination page must stay dormant while fingers are down")
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            for _ in 0..<3 {
                swipe.progress(-41.5, -83)
                XCTAssertEqual(model.record.selectedSpaceID, original)
                swipe.progress(-42, -84)
                XCTAssertEqual(model.record.selectedSpaceID, original)
            }
            swipe.finish(true)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(model.record.selectedSpaceID, original)
            swipe.progress(-75, -150)
            await Task.yield()
            swipe.finish(false)
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(model.record.selectedSpaceID, work.id)
            XCTAssertEqual(model.record.selectedTabID, tab.id)
            let destinationHost = try XCTUnwrap(model.selectedPage)
            try await Task.sleep(for: .milliseconds(500))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertNotNil(destinationHost.webView.superview)
            try capture(hosting, name: "Completed space swipe")
            swipe.progress(75, 150)
            await Task.yield()
            swipe.finish(false)
            // A keyboard/click selection must invalidate the pending animation's commit.
            let other = Space(name: "Other")
            model.app.spaces.append(other)
            model.selectSpace(other.id)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(model.record.selectedSpaceID, other.id)
            swipe.progress(-75, -150)
            await Task.yield()
            swipe.finish(false)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(model.record.selectedSpaceID, other.id, "Swiping beyond the last space must stop")
            model.selectSpace(original)
            await Task.yield()
            swipe.progress(75, 150)
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            try capture(hosting, name: "Outward swipe at first space stays in place")
            swipe.finish(false)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(model.record.selectedSpaceID, original, "Swiping before the first space must stop")
        }
    }

    func testSpaceSwipeInvalidatesOnOverlaySelectionRemovalAndWindowDeactivation() async throws {
        try await withWindow { model, nativeWindow, hosting in
            let original = model.record.selectedSpaceID
            let work = try XCTUnwrap(model.spaces.last)
            let tab = Tab(spaceID: work.id, title: "External selection")
            model.record.tabs.append(tab)
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            let swipe = try XCTUnwrap(swipeView(in: hosting))
            for interruption in 0..<3 {
                model.selectSpace(original)
                await Task.yield()
                swipe.progress(-75, -150)
                XCTAssertEqual(model.record.selectedSpaceID, original)
                switch interruption {
                case 0: model.commandBarPresented = true
                case 1:
                    let other = Tab(spaceID: original, title: "Another tab")
                    model.record.tabs.append(other)
                    model.select(other.id)
                default:
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: nativeWindow)
                }
                await Task.yield()
                let selected = model.record.selectedTabID
                swipe.finish(true)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(model.record.selectedSpaceID, original)
                XCTAssertEqual(model.record.selectedTabID, selected, "Cancellation must not overwrite external input")
                model.commandBarPresented = false
            }
            model.selectSpace(original)
            await Task.yield()
            swipe.progress(-75, -150)
            model.app.windows.append(model)
            defer { model.app.windows.removeAll { $0 === model } }
            model.app.deleteSpace(work.id)
            await Task.yield()
            swipe.finish(true)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.record.selectedSpaceID, original)
            XCTAssertFalse(model.spaces.contains { $0.id == work.id })
        }
    }

    func testTabButtonHandlesPointerModifiersAndAccessibility() async throws {
        try XCTSkipUnless(NSApp.isActive,
            "Native pointer tracking requires an active GUI session; run this test from Xcode with Cobble in the foreground.")
        try await withWindow { model, nativeWindow, hosting in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            let first = Tab(title: "Press target")
            let second = Tab(title: "Other target")
            model.record.tabs = [first, second]
            model.select(second.id)
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.displayIfNeeded()
            let button = try XCTUnwrap(accessibilityButton("Press target", in: nativeWindow))
            let frame = try XCTUnwrap(button.accessibilityFrame?())
            let point = nativeWindow.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.1,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            dispatchPointerSequence([down, up])
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(model.record.selectedTabID, first.id)

            let otherButton = try XCTUnwrap(accessibilityButton("Other target", in: nativeWindow))
            let otherFrame = try XCTUnwrap(otherButton.accessibilityFrame?())
            let otherPoint = nativeWindow.convertPoint(fromScreen: NSPoint(x: otherFrame.midX, y: otherFrame.midY))
            let commandDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: otherPoint,
                modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
            let commandUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: otherPoint,
                modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime + 0.1,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 0))
            dispatchPointerSequence([commandDown, commandUp])
            await Task.yield()
            XCTAssertEqual(model.record.selectedTabID, second.id)
            XCTAssertEqual(Set(model.selectedTemporaryTabs.map(\.id)), Set([first.id, second.id]))

            let outside = NSPoint(x: -20, y: -20)
            let commandFirstDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 5, clickCount: 1, pressure: 1))
            let dragOutside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: outside,
                modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 6, clickCount: 1, pressure: 1))
            let dragBack = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: point,
                modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime + 0.1,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 7, clickCount: 1, pressure: 1))
            let commandFirstUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime + 0.15,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 8, clickCount: 1, pressure: 0))
            dispatchPointerSequence([commandFirstDown, dragOutside, dragBack, commandFirstUp])
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(model.record.selectedTabID, second.id)
            XCTAssertEqual(Set(model.selectedTemporaryTabs.map(\.id)), Set([second.id]), "One Command-click changes selection once, even after leaving and re-entering the row")

            let cancelledDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 9, clickCount: 1, pressure: 1))
            let cancelledDrag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: outside,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 10, clickCount: 1, pressure: 1))
            let cancelledUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: outside,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.1,
                windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 11, clickCount: 1, pressure: 0))
            dispatchPointerSequence([cancelledDown, cancelledDrag, cancelledUp])
            await Task.yield()
            XCTAssertEqual(model.record.selectedTabID, second.id, "Dragging outside cancels native button activation")
            let accessibleButton = try XCTUnwrap(accessibilityButton("Press target", in: nativeWindow))
            XCTAssertEqual(accessibleButton.accessibilityPerformPress?(), true)
            await Task.yield()
            XCTAssertEqual(model.record.selectedTabID, first.id)
            // macOS only focuses ordinary buttons when Full Keyboard Access is enabled.
            if NSApp.isFullKeyboardAccessEnabled {
                model.select(second.id)
                await Task.yield()
                hosting.layoutSubtreeIfNeeded()
                let keyboardButton = try XCTUnwrap(accessibilityButton("Press target", in: nativeWindow))
                keyboardButton.setAccessibilityFocused?(true)
                await Task.yield()
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: nativeWindow.windowNumber, context: nil, characters: " ",
                        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
                    dispatchApplicationEvent(event)
                    await Task.yield()
                }
                XCTAssertEqual(model.record.selectedTabID, first.id, "Space activates the focused native button")
            }
        }
    }

    func testSelectedSidebarItemsReopenAfterUnloadAndDataClearing() async throws {
        try XCTSkipUnless(NSApp.isActive,
            "Native pointer tracking requires an active GUI session; run this test from Xcode with Cobble in the foreground.")
        try await withWindow(isPrivate: false) { model, nativeWindow, hosting in
            await model.app.contentBlocker?.waitUntilReady()
            model.app.windows = [model]
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            for kind in ["Tab", "Pin", "Favorite"] {
                let url = "http://127.0.0.1:9/reopen"
                let item = SavedItem(spaceID: kind == "Favorite" ? nil : model.record.selectedSpaceID,
                                     urlString: url, title: "Reopen target")
                model.app.savedItems = kind == "Tab" ? [] : [item]
                let tab = Tab(spaceID: model.record.selectedSpaceID, urlString: url, title: item.title,
                              savedItemID: kind == "Tab" ? nil : item.id)
                model.record.tabs = [tab]
                model.select(tab.id)
                for clearData in [false, true] {
                    await Task.yield()
                    if clearData {
                        let error = await model.app.clearWebsiteData(profileID: model.record.profileID)
                        XCTAssertNil(error)
                    } else { model.discardSelected() }
                    XCTAssertNil(model.selectedPage)
                    let label = kind == "Tab" ? item.title
                        : "\(kind == "Favorite" ? "Favorite" : "Pinned tab"): \(item.title), unloaded"
                    let candidate = await accessibilityButton(label, in: nativeWindow, hosting: hosting)
                    guard let button = candidate else {
                        try capture(hosting, name: "Sidebar missing \(kind) after \(clearData ? "data clearing" : "unloading")")
                        XCTFail("Missing \(kind) action after \(clearData ? "clearing data" : "unloading"); accessibility tree:\n\(accessibilityTree(in: nativeWindow).joined(separator: "\n"))")
                        return
                    }
                    let initialFrame = try XCTUnwrap(button.accessibilityFrame?())
                    try await Task.sleep(for: .milliseconds(300))
                    hosting.layoutSubtreeIfNeeded()
                    hosting.displayIfNeeded()
                    let settledCandidate = await accessibilityButton(label, in: nativeWindow, hosting: hosting)
                    let settledButton = try XCTUnwrap(settledCandidate)
                    let frame = try XCTUnwrap(settledButton.accessibilityFrame?())
                    XCTAssertEqual(frame.midX, initialFrame.midX, accuracy: 0.5)
                    XCTAssertEqual(frame.midY, initialFrame.midY, accuracy: 0.5)
                    let point = nativeWindow.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
                    let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 20, clickCount: 1, pressure: 1))
                    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.1,
                        windowNumber: nativeWindow.windowNumber, context: nil, eventNumber: 21, clickCount: 1, pressure: 0))
                    let context = BrowsingContextID(engineID: tab.engineID, profileID: model.record.profileID, privateWindowID: nil)
                    model.app.suspendedContexts.insert(context)
                    dispatchPointerSequence([down, up])
                    try await Task.sleep(for: .milliseconds(200))
                    XCTAssertNil(model.selectedPage)
                    XCTAssertNil(model.record.tabs.first { $0.id == tab.id }?.isUnloaded,
                                 "\(kind) must select through its native button action")
                    model.app.suspendedContexts.remove(context)
                    model.activateSelected()
                    await Task.yield()
                    let reopened = try XCTUnwrap(model.selectedPage, "\(kind) must reopen after unloading")
                    XCTAssertEqual(settledButton.accessibilityPerformPress?(), true)
                    XCTAssertEqual(settledButton.accessibilityPerformPress?(), true)
                    XCTAssertTrue(model.selectedPage === reopened)
                }
                model.closeTab(tab.id)
            }
        }
    }

    // SwiftUI virtual nodes implement accessibility selectors without declaring protocol conformance.
    // Some native bridges return attributed text even for nominal string getters.
    private func accessibilityText(_ object: AnyObject, _ getter: String) -> String? {
        guard let node = object as? NSObject else { return nil }
        let selector = NSSelectorFromString(getter)
        guard node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() else { return nil }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }

    private func accessibilityButton(_ label: String, in element: Any) -> AnyObject? {
        let accessible = element as AnyObject
        if accessibilityText(accessible, "accessibilityRole") == NSAccessibility.Role.button.rawValue,
           accessibilityText(accessible, "accessibilityLabel") == label || accessibilityText(accessible, "accessibilityTitle") == label { return accessible }
        if let window = accessible as? NSWindow, let content = window.contentView,
           let button = accessibilityButton(label, in: content) { return button }
        if let view = accessible as? NSView,
           let button = view.subviews.lazy.compactMap({ self.accessibilityButton(label, in: $0) }).first { return button }
        let children = accessible.accessibilityChildren?() ?? []
        return children.lazy.compactMap { self.accessibilityButton(label, in: $0) }.first
    }

    private func accessibilityButton(_ label: String, in window: NSWindow, hosting: NSView) async -> AnyObject? {
        for _ in 0..<3 {
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if let button = accessibilityButton(label, in: window) { return button }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func dispatchApplicationEvent(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: true)
        guard let dispatched = NSApp.nextEvent(matching: .any,
                                                until: Date(timeIntervalSinceNow: 1),
                                                inMode: .default,
                                                dequeue: true) else {
            XCTFail("Could not dispatch native \(event.type) event")
            return
        }
        XCTAssertEqual(dispatched.type, event.type)
        XCTAssertEqual(dispatched.windowNumber, event.windowNumber)
        XCTAssertEqual(dispatched.eventNumber, event.eventNumber)
        NSApp.sendEvent(dispatched)
    }

    private func dispatchPointerSequence(_ events: [NSEvent]) {
        guard let first = events.first else { return }
        for event in events.dropFirst().reversed() { NSApp.postEvent(event, atStart: true) }
        dispatchApplicationEvent(first)
    }

    private func nativeButtonDescriptions(in view: NSView) -> [String] {
        let description = (view as? NSButton).map { button in
            "title=\(String(describing: accessibilityText(button, "title"))), label=\(String(describing: accessibilityText(button, "accessibilityLabel"))), accessibilityTitle=\(String(describing: accessibilityText(button, "accessibilityTitle"))), help=\(String(describing: accessibilityText(button, "accessibilityHelp")))"
        }
        return (description.map { [$0] } ?? []) + view.subviews.flatMap { nativeButtonDescriptions(in: $0) }
    }

    private func accessibilityTree(in root: Any) -> [String] {
        var visited = Set<ObjectIdentifier>()
        return accessibilityTree(root as AnyObject, depth: 0, visited: &visited)
    }

    private func accessibilityTree(_ element: AnyObject, depth: Int,
                                   visited: inout Set<ObjectIdentifier>) -> [String] {
        let identity = ObjectIdentifier(element)
        guard visited.insert(identity).inserted else { return [] }
        let indent = String(repeating: "  ", count: depth)
        let line = "\(indent)\(type(of: element)): role=\(String(describing: accessibilityText(element, "accessibilityRole"))), label=\(String(describing: accessibilityText(element, "accessibilityLabel"))), title=\(String(describing: accessibilityText(element, "accessibilityTitle"))), value=\(String(describing: accessibilityText(element, "accessibilityValue")))"
        let children = element.accessibilityChildren?() ?? []
        return [line] + children.flatMap { accessibilityTree($0 as AnyObject, depth: depth + 1, visited: &visited) }
    }

    private func focusCommandField(in hosting: NSView, window: NSWindow) async throws {
        var found = false
        for _ in 0..<3 {
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if let field = textField(labeled: "Search, URL, or open tab", in: hosting) {
                found = true
                guard window.makeFirstResponder(field) else { continue }
                await Task.yield()
                if (window.firstResponder as? NSTextView)?.isFieldEditor == true { return }
            }
        }
        XCTFail("Command field did not accept focus (found: \(found))")
    }

    private func textField(labeled label: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.accessibilityLabel() == label || field.placeholderString == "Search or enter a URL" { return field }
        return view.subviews.lazy.compactMap { self.textField(labeled: label, in: $0) }.first
    }

    private func textField(placeholder: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        return view.subviews.lazy.compactMap { self.textField(placeholder: placeholder, in: $0) }.first
    }

    private func swipeView(in view: NSView) -> SidebarSwipeView.SwipeView? {
        if let swipe = view as? SidebarSwipeView.SwipeView { return swipe }
        return view.subviews.lazy.compactMap { self.swipeView(in: $0) }.first
    }

    private func withWindow(isPrivate: Bool = true, engine: (any BrowserEngine)? = nil, preferencesData: Data? = nil,
                            body: @MainActor (BrowserWindowModel, NSWindow, NSHostingView<AnyView>) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleUITests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if let preferencesData {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try preferencesData.write(to: directory.appendingPathComponent("browser-preferences.json"))
        }
        let store = SessionStore(directory: directory)
        let app = engine.map { AppModel(store: store, engines: EngineRegistry([$0])) }
            ?? AppModel(store: store, websiteDataStoreOverride: .nonPersistent())
        let work = Space(name: "Work")
        app.spaces.append(work)
        let folder = Folder(name: "Research")
        app.folders.append(folder)
        // Saved links are labels only; no page is selected or loaded.
        app.savedItems = [
            SavedItem(title: "Daily favorites"),
            SavedItem(spaceID: Space.defaultID, title: "Reading list"),
            SavedItem(spaceID: Space.defaultID, folderID: folder.id, title: "WebKit notes")
        ]
        let model = BrowserWindowModel(app: app, record: WindowRecord(), isPrivate: isPrivate)
        let controller = BrowserWindowController(model: model, onClose: { _ in })
        let nativeWindow = try XCTUnwrap(controller.window)
        let hosting = NSHostingView(rootView: AnyView(BrowserView(window: model)))
        nativeWindow.contentView = hosting
        nativeWindow.setContentSize(NSSize(width: 1100, height: 720))
        nativeWindow.makeKeyAndOrderFront(nil)
        defer {
            // Remove the SwiftUI graph before releasing its unowned app-model reference.
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            nativeWindow.orderOut(nil)
            nativeWindow.contentView = nil
            nativeWindow.close()
            model.closePages()
            app.flush()
            app.library.close()
        }

        try await body(model, nativeWindow, hosting)
    }

    private func sidebarButton(_ index: Int, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == "sidebar.window.\(index)" { return button }
        return view.subviews.lazy.compactMap { self.sidebarButton(index, in: $0) }.first
    }

    private func visualEffectViews(in view: NSView) -> [NSVisualEffectView] {
        (view as? NSVisualEffectView).map { [$0] } ?? [] + view.subviews.flatMap { visualEffectViews(in: $0) }
    }

    private func makeSettingsExtension(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = """
        {
          "manifest_version": 3,
          "name": "Settings Render Fixture",
          "description": "Exercises Cobble's native extension settings controls.",
          "version": "2.4.1",
          "action": { "default_popup": "popup.html" },
          "permissions": ["storage", "nativeMessaging"],
          "host_permissions": ["https://example.com/*", "https://*.cobble.test/*"]
        }
        """
        try Data(manifest.utf8).write(to: url.appendingPathComponent("manifest.json"))
        try Data("<html><body>Settings fixture</body></html>".utf8)
            .write(to: url.appendingPathComponent("popup.html"))
    }

    private func capture(_ view: NSView, name: String, outputDirectory: URL? = nil) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let filename = name.replacingOccurrences(of: " ", with: "-").lowercased() + ".png"
            try png.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
        }
    }
}
