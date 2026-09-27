import Network
import WebKit
import XCTest
@testable import Cobble

@MainActor
final class WebKitExtensionTests: XCTestCase {
    func testOptionalPermissionRequiresConsentAndRevokesAcrossRestart() async throws {
        try await withDirectories { storage, source in
            try makeExtension(at: source)
            let manifestURL = source.appendingPathComponent("manifest.json")
            let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
                .replacingOccurrences(of: "\"permissions\": [\"storage\", \"nativeMessaging\"],",
                    with: "\"permissions\": [\"storage\", \"nativeMessaging\"], \"optional_permissions\": [\"tabs\"],")
            try Data(manifest.utf8).write(to: manifestURL)
            let engine = WebKitEngine(directory: storage, dataStoreOverride: .nonPersistent())
            let manager = try XCTUnwrap(engine.extensionManager as? WebKitExtensionManager)
            try await manager.install(from: source, profileID: Profile.defaultID)
            let item = try XCTUnwrap(manager.extensions(profileID: Profile.defaultID).first)
            let profile = Profile(id: Profile.defaultID, name: "Default", storeBinding: .legacyDefault)
            let contextID = BrowsingContextID(engineID: .webKit, profileID: profile.id, privateWindowID: nil)
            let context = try XCTUnwrap(try engine.makeContext(profile: profile, id: contextID,
                siteSettings: SiteSettingsStore(directory: storage)) as? WebKitContext)
            let page = try XCTUnwrap(try context.makePage(tabID: UUID(), windowID: UUID()) as? WebKitPage)
            try await page.prepare()
            let session = try XCTUnwrap(context.extensionSession as? WebKitExtensionSession)
            let native = try XCTUnwrap(session.controller.extensionContexts.first)
            XCTAssertTrue(native.webExtension.optionalPermissions.contains(.tabs))
            XCTAssertFalse(native.hasPermission(.tabs))
            await XCTAssertThrowsErrorAsync {
                try await manager.setAllowedOptionalPermissions([WKWebExtension.Permission.tabs.rawValue],
                    id: item.id, profileID: Profile.defaultID)
            }

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let container = BrowserPageContainer(frame: window.contentView?.bounds ?? .zero)
            window.contentView?.addSubview(container)
            container.mount(page)
            window.makeKeyAndOrderFront(nil)
            defer { window.close(); page.close() }

            let request = Task { await withCheckedContinuation { continuation in
                session.webExtensionController(session.controller, promptForPermissions: [.tabs], in: page,
                    for: native) { granted, _ in continuation.resume(returning: granted) }
            } }
            try await eventually("optional permission sheet") { !window.sheets.isEmpty }
            window.endSheet(try XCTUnwrap(window.sheets.first), returnCode: .alertFirstButtonReturn)
            let granted = await request.value
            XCTAssertEqual(granted, [.tabs])
            XCTAssertEqual(manager.extensions(profileID: Profile.defaultID).first?.allowedOptionalPermissions,
                [WKWebExtension.Permission.tabs.rawValue])

            let restored = WebKitExtensionManager(directory: storage)
            let restoredSession = restored.makeSession(id: contextID, dataStore: .nonPersistent())
            try await restoredSession.prepare()
            XCTAssertTrue(try XCTUnwrap(restoredSession.controller.extensionContexts.first).hasPermission(.tabs))

            var grants = native.grantedPermissions
            grants.removeValue(forKey: .tabs)
            native.grantedPermissions = grants
            try await eventually("extension permission removal persists") {
                manager.extensions(profileID: Profile.defaultID).first?.allowedOptionalPermissions == []
            }
            XCTAssertEqual(manager.extensions(profileID: Profile.defaultID).first?.allowedOptionalPermissions, [])
            XCTAssertFalse(try XCTUnwrap(session.controller.extensionContexts.first).hasPermission(.tabs))
            let revoked = WebKitExtensionManager(directory: storage)
            XCTAssertEqual(revoked.extensions(profileID: Profile.defaultID).first?.allowedOptionalPermissions, [])
            await context.close()
        }
    }

    func testZIPInstallCopiesReloadsAndRejectsInvalidArchive() async throws {
        try await withDirectories { storage, source in
            try makeExtension(at: source)
            let archive = source.deletingLastPathComponent().appendingPathComponent("Fixture.zip")
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = source
            zip.arguments = ["-q", archive.path, "manifest.json", "content.js", "popup.html", "popup.js"]
            try zip.run()
            zip.waitUntilExit()
            XCTAssertEqual(zip.terminationStatus, 0)

            let manager = WebKitExtensionManager(directory: storage)
            try await manager.install(from: archive, profileID: Profile.defaultID)
            let item = try XCTUnwrap(manager.extensions(profileID: Profile.defaultID).first)
            XCTAssertEqual(item.name, "Cobble Fixture")
            XCTAssertEqual(item.sourceURL.pathExtension, "zip")
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceURL.path))
            try FileManager.default.removeItem(at: archive)

            let restored = WebKitExtensionManager(directory: storage)
            let contextID = BrowsingContextID(engineID: .webKit, profileID: Profile.defaultID, privateWindowID: nil)
            let session = restored.makeSession(id: contextID, dataStore: .nonPersistent())
            try await session.prepare()
            XCTAssertEqual(session.controller.extensionContexts.first?.webExtension.displayName, "Cobble Fixture")

            let invalid = source.deletingLastPathComponent().appendingPathComponent("Invalid.zip")
            try Data("not an archive".utf8).write(to: invalid)
            await XCTAssertThrowsErrorAsync { try await manager.install(from: invalid, profileID: Profile.defaultID) }
            let theme = """
            {"manifest_version": 3, "name": "Unwanted Theme", "version": "1.0",
             "theme": {"colors": {"frame": [255, 0, 0]}}}
            """
            try Data(theme.utf8).write(to: source.appendingPathComponent("manifest.json"))
            await XCTAssertThrowsErrorAsync { try await manager.install(from: source, profileID: Profile.defaultID) }
            XCTAssertEqual(manager.extensions(profileID: Profile.defaultID).count, 1)
        }
    }

    func testInstallCopiesPersistsAndRestrictsDeclaredOriginsByProfile() async throws {
        try await withDirectories { storage, source in
            try makeExtension(at: source)
            let manager = WebKitExtensionManager(directory: storage)
            try await manager.install(from: source, profileID: Profile.defaultID)

            var item = try XCTUnwrap(manager.extensions(profileID: Profile.defaultID).first)
            XCTAssertEqual(item.name, "Cobble Fixture")
            XCTAssertEqual(item.version, "1.2")
            XCTAssertTrue(item.hasAction)
            XCTAssertEqual(item.deniedPermissions, ["Native messaging"])
            XCTAssertTrue(item.isEnabled)
            XCTAssertFalse(item.allowsPrivateBrowsing)
            XCTAssertEqual(item.allowedOrigins, [])
            XCTAssertEqual(Set(item.requestedOrigins), ["https://example.com/*", "https://*.cobble.test/*"])
            XCTAssertNotEqual(item.sourceURL, source)
            XCTAssertTrue(item.sourceURL.path.hasPrefix(storage.appendingPathComponent("Extensions").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceURL.appendingPathComponent("manifest.json").path))
            XCTAssertTrue(manager.extensions(profileID: UUID()).isEmpty)

            try await manager.setAllowedOrigins(["https://example.com/*"], id: item.id, profileID: Profile.defaultID)
            item = try XCTUnwrap(manager.extensions(profileID: Profile.defaultID).first)
            XCTAssertEqual(item.allowedOrigins, ["https://example.com/*"])
            await XCTAssertThrowsErrorAsync {
                try await manager.setAllowedOrigins(["<all_urls>"], id: item.id, profileID: Profile.defaultID)
            }
            XCTAssertEqual(manager.extensions(profileID: Profile.defaultID).first?.allowedOrigins,
                           ["https://example.com/*"])

            let restored = WebKitExtensionManager(directory: storage)
            let restoredItem = try XCTUnwrap(restored.extensions(profileID: Profile.defaultID).first)
            XCTAssertEqual(restoredItem.id, item.id)
            XCTAssertEqual(restoredItem.allowedOrigins, ["https://example.com/*"])
        }
    }

    func testPageControllersKeepProfileAndPrivateExtensionDataSeparate() async throws {
        try await withDirectories { storage, source in
            let server = try LocalHTTPServer()
            defer { server.stop() }
            let allowedPattern = "http://127.0.0.1/*"
            let allowedURL = try await server.url(path: "allowed")
            let deniedURL = try await server.url(path: "denied")
            let (probe, response) = try await URLSession.shared.data(from: allowedURL)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: probe, as: UTF8.self).contains("Loopback extension fixture"))
            try makeExtension(at: source, allowedOrigin: allowedPattern)
            let engine = WebKitEngine(directory: storage, dataStoreOverride: .nonPersistent())
            let manager = try XCTUnwrap(engine.extensionManager as? WebKitExtensionManager)
            try await manager.install(from: source, profileID: Profile.defaultID)
            let item = try XCTUnwrap(manager.extensions(profileID: Profile.defaultID).first)
            try await manager.setAllowedOrigins([allowedPattern], id: item.id, profileID: Profile.defaultID)

            let settings = SiteSettingsStore(directory: storage)
            let profile = Profile(id: Profile.defaultID, name: "Default", storeBinding: .legacyDefault)
            let normalID = BrowsingContextID(engineID: .webKit, profileID: profile.id, privateWindowID: nil)
            let privateID = BrowsingContextID(engineID: .webKit, profileID: profile.id, privateWindowID: UUID())
            let normal = try XCTUnwrap(try engine.makeContext(profile: profile, id: normalID, siteSettings: settings) as? WebKitContext)
            let privateContext = try XCTUnwrap(try engine.makeContext(profile: profile, id: privateID, siteSettings: settings) as? WebKitContext)
            let normalPage = try XCTUnwrap(try normal.makePage(tabID: UUID(), windowID: UUID()) as? WebKitPage)
            let privatePage = try XCTUnwrap(try privateContext.makePage(tabID: UUID(), windowID: UUID()) as? WebKitPage)
            try await normalPage.prepare()
            try await privatePage.prepare()

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let firstContainer = BrowserPageContainer(frame: window.contentView?.bounds ?? .zero)
            let secondContainer = BrowserPageContainer(frame: window.contentView?.bounds ?? .zero)
            window.contentView?.addSubview(firstContainer)
            window.contentView?.addSubview(secondContainer)
            firstContainer.mount(normalPage)

            let normalSession = try XCTUnwrap(normal.extensionSession as? WebKitExtensionSession)
            let privateSession = try XCTUnwrap(privateContext.extensionSession as? WebKitExtensionSession)
            XCTAssertTrue(normalPage.webView.configuration.webExtensionController === normalSession.controller)
            XCTAssertTrue(privatePage.webView.configuration.webExtensionController === privateSession.controller)
            XCTAssertFalse(normalSession.controller.configuration.isPersistent,
                "A nonpersistent page store must never create persistent extension storage")
            XCTAssertFalse(privateSession.controller.configuration.isPersistent)
            XCTAssertFalse(normalPage.webView.configuration.userContentController === privatePage.webView.configuration.userContentController)
            XCTAssertEqual(normalSession.controller.extensionContexts.count, 1)
            XCTAssertEqual(privateSession.controller.extensionContexts.count, 0)

            let native = try XCTUnwrap(normalSession.controller.extensionContexts.first)
            XCTAssertTrue(native.errors.isEmpty,
                "The extension fixture must be valid before runtime behavior is tested: \(native.errors.map { errorDescription($0) })")
            XCTAssertEqual(Set(native.currentPermissionMatchPatterns.map(\.string)), [allowedPattern])
            XCTAssertEqual(Set(native.deniedPermissionMatchPatterns.keys.map(\.string)), ["https://*.cobble.test/*"])
            XCTAssertEqual(native.permissionStatus(for: .nativeMessaging), .deniedExplicitly)
            XCTAssertFalse(normalPage.shouldGrantPermissionsOnUserGesture(for: native))
            XCTAssertFalse(normalPage.shouldBypassPermissions(for: native))
            XCTAssertTrue(native.hasInjectedContent)
            XCTAssertTrue(native.hasInjectedContent(for: allowedURL))
            XCTAssertTrue(native.hasAccess(to: allowedURL, in: normalPage))
            let muteError: Error? = await withCheckedContinuation { continuation in
                normalPage.setMuted(true, for: native) { continuation.resume(returning: $0) }
            }
            XCTAssertNil(muteError)
            XCTAssertTrue(normalPage.state.isAudioMuted)
            XCTAssertTrue(WebKitAudioMute.isMuted(normalPage.webView))
            XCTAssertTrue(normalPage.isMuted(for: native))
            let foreign = WKWebExtensionContext(for: native.webExtension)
            XCTAssertFalse(normalPage.isMuted(for: foreign))
            XCTAssertFalse(normalPage.isPlayingAudio(for: foreign))
            let foreignError: Error? = await withCheckedContinuation { continuation in
                normalPage.setMuted(false, for: foreign) { continuation.resume(returning: $0) }
            }
            XCTAssertNotNil(foreignError)
            XCTAssertTrue(normalPage.state.isAudioMuted)
            XCTAssertTrue(WebKitAudioMute.isMuted(normalPage.webView))
            let unmuteError: Error? = await withCheckedContinuation { continuation in
                normalPage.setMuted(false, for: native) { continuation.resume(returning: $0) }
            }
            XCTAssertNil(unmuteError)
            XCTAssertFalse(normalPage.state.isAudioMuted)
            XCTAssertFalse(WebKitAudioMute.isMuted(normalPage.webView))
            XCTAssertFalse(normalPage.isMuted(for: native))
            do {
                let capturePage = try XCTUnwrap(try normal.makePage(tabID: UUID(), windowID: UUID()) as? WebKitPage)
                defer { capturePage.close() }
                try await capturePage.prepare()
                _ = capturePage.webView
                capturePage.setCapture(.microphone, .muted)
                let camera = capturePage.webView.cameraCaptureState
                let microphone = capturePage.webView.microphoneCaptureState
                let pageCamera = capturePage.state.camera
                let pageMicrophone = capturePage.state.microphone
                let captureError: Error? = await withCheckedContinuation { continuation in
                    capturePage.setMuted(true, for: native) { continuation.resume(returning: $0) }
                }
                switch captureError as? EngineError {
                case .notReady?: break
                default: XCTFail("Extension audio mute must report the capture safety error")
                }
                XCTAssertFalse(capturePage.state.isAudioMuted)
                XCTAssertFalse(WebKitAudioMute.isMuted(capturePage.webView))
                XCTAssertEqual(capturePage.webView.cameraCaptureState, camera)
                XCTAssertEqual(capturePage.webView.microphoneCaptureState, microphone)
                XCTAssertEqual(capturePage.state.camera, pageCamera)
                XCTAssertEqual(capturePage.state.microphone, pageMicrophone)
            }
            normalPage.webView.load(URLRequest(url: allowedURL))
            try await eventually("content script injection on a granted HTTP origin", details:
                "url=\(normalPage.webView.url?.absoluteString ?? "nil"), "
                + "pageError=\(normalPage.state.errorMessage ?? "nil"), "
                + "injected=\(native.hasInjectedContent(for: allowedURL)), "
                + "access=\(native.hasAccess(to: allowedURL, in: normalPage)), "
                + "privateDataAccess=\(native.hasAccessToPrivateData), "
                + "extensionErrors=\(native.errors.map { errorDescription($0) })") {
                try await normalPage.webView.evaluateJavaScript(
                    "document.documentElement.dataset.cobbleFixture === 'loaded'") as? Bool == true
            }
            let extensionWindow = try XCTUnwrap(normalSession.window(for: normalPage))
            XCTAssertTrue(extensionWindow.activePage === normalPage)
            secondContainer.mount(normalPage)
            firstContainer.unmount()
            XCTAssertTrue(extensionWindow.activePage === normalPage,
                "A stale container must not deactivate a page after it is reparented")
            secondContainer.unmount()
            XCTAssertTrue(extensionWindow.activePage === normalPage,
                "Detaching a retained tab's view must not clear the logical browser selection")
            XCTAssertEqual(extensionWindow.tabs(for: native).count, 1,
                "A detached retained tab must keep its logical browser window")
            secondContainer.mount(normalPage)
            XCTAssertTrue(extensionWindow.activePage === normalPage)
            let action = try XCTUnwrap(native.action(for: normalPage))
            XCTAssertTrue(action.presentsPopup)
            window.makeKeyAndOrderFront(nil)
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.makeKeyAndOrderFront(nil)
            defer { settingsWindow.close() }
            for _ in 0..<3 {
                try await manager.performAction(id: item.id, profileID: Profile.defaultID, on: normalPage)
                try await eventually("extension action popup presentation") {
                    normalSession.presentedPopupCount == 1
                }
                let popupWebView = try XCTUnwrap(normalSession.presentedPopupWebView)
                let popupWindow = try XCTUnwrap(popupWebView.window)
                XCTAssertTrue(popupWindow.isVisible)
                XCTAssertGreaterThanOrEqual(popupWindow.frame.minX, window.frame.minX)
                XCTAssertTrue(settingsWindow.isVisible)
                XCTAssertFalse(settingsWindow.isKeyWindow)
                try await eventually("extension popup script and isolated storage") {
                    try await popupWebView.evaluateJavaScript(
                        "document.body.dataset.popup === 'loaded' && localStorage.fixture === 'saved'") as? Bool == true
                }
                normalSession.closePopups(for: native)
                try await eventually("extension action popup closure") {
                    normalSession.presentedPopupCount == 0
                }
            }

            try await manager.setAllowedOrigins([], id: item.id, profileID: Profile.defaultID)
            let deniedPage = try XCTUnwrap(try normal.makePage(tabID: UUID(), windowID: UUID()) as? WebKitPage)
            try await deniedPage.prepare()
            deniedPage.webView.load(URLRequest(url: deniedURL))
            try await eventually("denied-origin page load") {
                try await deniedPage.webView.evaluateJavaScript("document.readyState === 'complete'") as? Bool == true
            }
            try await Task.sleep(for: .milliseconds(200))
            let deniedValue = try await deniedPage.webView.evaluateJavaScript(
                "document.documentElement.dataset.cobbleFixture || ''") as? String
            XCTAssertEqual(deniedValue, "")

            try await manager.setPrivateBrowsingAllowed(true, id: item.id, profileID: Profile.defaultID)
            XCTAssertEqual(privateSession.controller.extensionContexts.count, 1)
            XCTAssertTrue(privateSession.controller.extensionContexts.first?.hasAccessToPrivateData == true)
            try await manager.setEnabled(false, id: item.id, profileID: Profile.defaultID)
            XCTAssertEqual(normalSession.controller.extensionContexts.count, 0)
            XCTAssertEqual(privateSession.controller.extensionContexts.count, 0)
            try await manager.setEnabled(true, id: item.id, profileID: Profile.defaultID)
            XCTAssertEqual(normalSession.controller.extensionContexts.count, 1)
            XCTAssertEqual(privateSession.controller.extensionContexts.count, 1)
            try await manager.setEnabled(false, id: item.id, profileID: Profile.defaultID)
            try await manager.remove(id: item.id, profileID: Profile.defaultID)
            XCTAssertTrue(manager.extensions(profileID: Profile.defaultID).isEmpty)
            XCTAssertEqual(normalSession.controller.extensionContexts.count, 0)
            XCTAssertEqual(privateSession.controller.extensionContexts.count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.sourceURL.path))
            normalPage.close()
            privatePage.close()
            deniedPage.close()
            window.close()
            await normal.close()
            await privateContext.close()
            XCTAssertNil(normalSession.controller.delegate)
            XCTAssertNil(privateSession.controller.delegate)
            try await Task.sleep(for: .milliseconds(300))
            let sentinel = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
            try await sentinel.prepare()
            sentinel.close()
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    func testClosedPageWebViewForExtensionDoesNotReincarnate() async throws {
        try await withDirectories { storage, source in
            try makeExtension(at: source)
            let engine = WebKitEngine(directory: storage, dataStoreOverride: .nonPersistent())
            let manager = try XCTUnwrap(engine.extensionManager as? WebKitExtensionManager)
            try await manager.install(from: source, profileID: Profile.defaultID)
            let settings = SiteSettingsStore(directory: storage)
            let profile = Profile(id: Profile.defaultID, name: "Default", storeBinding: .legacyDefault)
            let contextID = BrowsingContextID(engineID: .webKit, profileID: profile.id, privateWindowID: nil)
            let context = try XCTUnwrap(try engine.makeContext(profile: profile, id: contextID, siteSettings: settings) as? WebKitContext)
            let page = try XCTUnwrap(try context.makePage(tabID: UUID(), windowID: UUID()) as? WebKitPage)
            try await page.prepare()
            _ = page.webView
            let session = try XCTUnwrap(context.extensionSession as? WebKitExtensionSession)
            let native = try XCTUnwrap(session.controller.extensionContexts.first)
            XCTAssertTrue(page.webView(for: native) === page.storedWebViewForExtensions)
            XCTAssertNotNil(page.storedWebViewForExtensions)
            page.close()
            XCTAssertNil(page.webView(for: native))
            XCTAssertNil(page.storedWebViewForExtensions)
            XCTAssertFalse(page.nativeView is WKWebView)
            await context.close()
        }
    }

    func testInstallRejectsSymlinksAndCorruptStateRemainsUntouched() async throws {
        try await withDirectories { storage, source in
            try makeExtension(at: source)
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked.js"),
                withDestinationURL: source.appendingPathComponent("content.js"))
            let manager = WebKitExtensionManager(directory: storage)
            await XCTAssertThrowsErrorAsync { try await manager.install(from: source, profileID: Profile.defaultID) }
            XCTAssertTrue(manager.extensions(profileID: Profile.defaultID).isEmpty)

            let snapshot = storage.appendingPathComponent("extensions.json")
            let corrupt = Data("{\"version\":99,\"records\":[]}".utf8)
            try corrupt.write(to: snapshot)
            let disabled = WebKitExtensionManager(directory: storage)
            XCTAssertNotNil(disabled.lastError)
            await XCTAssertThrowsErrorAsync { try await disabled.install(from: source, profileID: Profile.defaultID) }
            XCTAssertEqual(try Data(contentsOf: snapshot), corrupt)
        }
    }

    func testPersistentControllerIdentifiersAreStableAndStorageScoped() {
        let profileID = UUID()
        let first = WebKitExtensionManager.controllerIdentifier(profileID: profileID, namespace: "/tmp/cobble-a")
        XCTAssertEqual(first,
            WebKitExtensionManager.controllerIdentifier(profileID: profileID, namespace: "/tmp/cobble-a"))
        XCTAssertNotEqual(first,
            WebKitExtensionManager.controllerIdentifier(profileID: profileID, namespace: "/tmp/cobble-b"))
        XCTAssertNotEqual(first,
            WebKitExtensionManager.controllerIdentifier(profileID: UUID(), namespace: "/tmp/cobble-a"))
    }

    func testAppBundleFindsEmbeddedExtensionAcrossCanonicalizedTemporaryPath() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("CobbleExtensionPath-\(UUID()).app")
        let appex = app.appendingPathComponent("Contents/PlugIns/Fixture.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }

        XCTAssertEqual(try WebKitExtensionManager.appExtensionPath(in: app),
                       "Contents/PlugIns/Fixture.appex")
    }

    private func withDirectories(_ body: (URL, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleExtensionTests-\(UUID())")
        let storage = base.appendingPathComponent("Storage", isDirectory: true)
        let source = base.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await body(storage, source)
    }

    private func makeExtension(at url: URL, allowedOrigin: String = "https://example.com/*") throws {
        let manifest = """
        {
          "manifest_version": 3,
          "name": "Cobble Fixture",
          "description": "Tests Cobble's WebExtension integration.",
          "version": "1.2",
          "action": { "default_popup": "popup.html" },
          "permissions": ["storage", "nativeMessaging"],
          "host_permissions": ["\(allowedOrigin)", "https://*.cobble.test/*"],
          "content_scripts": [{
            "matches": ["\(allowedOrigin)"],
            "js": ["content.js"]
          }]
        }
        """
        try Data(manifest.utf8).write(to: url.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.cobbleFixture = 'loaded';".utf8)
            .write(to: url.appendingPathComponent("content.js"))
        try Data("<html><body data-popup='loaded'>Popup<script src='popup.js'></script></body></html>".utf8)
            .write(to: url.appendingPathComponent("popup.html"))
        try Data("localStorage.fixture = 'saved';".utf8)
            .write(to: url.appendingPathComponent("popup.js"))
    }

    private func eventually(_ phase: String, details: @autoclosure () -> String = "",
                            timeout: Duration = .seconds(5),
                            _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?
        repeat {
            do {
                if try await condition() { return }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(50))
        } while clock.now < deadline
        let context = details()
        let error = lastError.map { " Last error: \(errorDescription($0))." } ?? ""
        throw EngineError.notReady("Timed out waiting for \(phase). \(context)\(error)")
    }

    private func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }
}

private final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Cobble.WebKitExtensionTests.HTTP")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
                let body = "<html><body>Loopback extension fixture</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), contentContext: .defaultMessage,
                    isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func url(path: String) async throws -> URL {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            switch listener.state {
            case .ready:
                guard let port = listener.port, port != .any,
                      let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(path)") else { break }
                return url
            case .failed(let error):
                throw error
            case .cancelled:
                throw EngineError.notReady("The loopback extension fixture was cancelled.")
            default:
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw EngineError.notReady("Timed out starting the loopback extension fixture.")
    }

    func stop() { listener.cancel() }

    deinit { listener.cancel() }
}

@MainActor private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
