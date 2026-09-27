import AppKit
import SwiftUI
import XCTest
@testable import Cobble

@MainActor final class PagePresenterTests: XCTestCase {
    func testMediaPermissionRequestResolvesExactlyOnce() {
        var decisions: [SitePermission] = []
        let request = PageMediaPermissionRequest(tabID: UUID(),
            contextID: .init(engineID: .webKit, profileID: Profile.defaultID, privateWindowID: nil),
            windowID: UUID(), documentID: "document", frameID: "frame", kinds: [.camera],
            requestingOrigin: URL(string: "https://camera.example")!,
            embeddingOrigin: URL(string: "https://camera.example")!) { decisions.append($0) }
        XCTAssertTrue(request.isPending)
        request.resolve(.allow)
        request.resolve(.deny)
        XCTAssertFalse(request.isPending)
        XCTAssertEqual(decisions, [.allow])
    }

    func testGenericPagePromptResolvesExactlyOnce() {
        let identity = PagePromptIdentity(tabID: UUID(),
            contextID: .init(engineID: .webKit, profileID: Profile.defaultID, privateWindowID: nil),
            windowID: UUID(), documentID: "document", frameID: "frame",
            requestingOrigin: URL(string: "https://dialog.example")!,
            topLevelOrigin: URL(string: "https://dialog.example")!)
        var results: [PageJavaScriptDialogResult] = []
        let request = PageJavaScriptDialogRequest(identity: identity,
            prompt: PageJavaScriptDialog(kind: .confirm, message: "Continue?", defaultText: nil, isReload: false)) {
                results.append($0)
            }
        request.resolve(.accept(nil))
        request.resolve(.cancel)
        XCTAssertFalse(request.isPending)
        XCTAssertEqual(results.count, 1)
    }

    func testFormRepostAlertUsesAppOwnedCopy() {
        let alert = PagePresenter.formRepostAlert(origin: "https://frame.example")
        XCTAssertEqual(alert.messageText, "Resubmit form data?")
        XCTAssertEqual(alert.informativeText,
                       "https://frame.example\n\nReloading this content will resubmit form data.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Resubmit", "Cancel"])
    }

    func testSaveChooserWithoutOwningWindowCancelsExactlyOnce() {
        let presenter = PagePresenter(window: { nil })
        var results: [URL?] = []
        presenter.chooseSaveFile(defaultFilename: "page.html") { results.append($0) }
        presenter.cancelAll()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
    }

    func testClientCertificateChooserWithoutOwningWindowCancelsWithoutSelecting() {
        let choice = PageClientCertificateChoice(id: UUID(),
            certificate: PageCertificateDetails(subject: "Fixture Client", issuer: "Fixture CA",
                validFrom: nil, validUntil: nil), serialNumber: "01")
        let presenter = PagePresenter(window: { nil })
        var results: [UUID?] = []
        presenter.chooseClientCertificate(id: UUID(), origin: "https://mutual-tls.example",
                                          choices: [choice], truncated: false) {
            results.append($0)
        }
        presenter.cancelAll()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
    }

    func testClientCertificateChooserLabelsChoicesAndReturnsSelectedIdentity() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let first = PageClientCertificateChoice(id: UUID(),
            certificate: PageCertificateDetails(subject: String(repeating: "Long subject ", count: 20),
                issuer: "Fixture Intermediate", validFrom: nil,
                validUntil: Date(timeIntervalSince1970: 2_000_000_000)), serialNumber: "0011223344556677")
        let second = PageClientCertificateChoice(id: UUID(),
            certificate: PageCertificateDetails(subject: String(repeating: "Long subject ", count: 20),
                issuer: "Fixture Root", validFrom: nil, validUntil: nil),
            serialNumber: "0011223344556677")
        let presenter = PagePresenter(window: { window })
        var results: [UUID?] = []
        presenter.chooseClientCertificate(id: UUID(), origin: "https://mutual-tls.example",
                                          choices: [first, second], truncated: true) {
            results.append($0)
        }
        for _ in 0..<100 where window.attachedSheet == nil { await Task.yield() }
        let sheet = try XCTUnwrap(window.attachedSheet)
        func popup(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton { return popup }
            return view.subviews.lazy.compactMap(popup(in:)).first
        }
        let choices = try XCTUnwrap(sheet.contentView.flatMap(popup(in:)))
        XCTAssertEqual(choices.accessibilityLabel(), "Client certificate")
        XCTAssertEqual(choices.numberOfItems, 2)
        XCTAssertTrue(choices.itemTitles[0].hasSuffix("…0011223344556677"))
        XCTAssertEqual(choices.itemTitles[0], choices.itemTitles[1])
        choices.selectItem(at: 1)
        choices.sendAction(choices.action, to: choices.target)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        for _ in 0..<100 where results.isEmpty { await Task.yield() }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0], second.id)
    }

    func testReadOnlyTextViewerRetainsScrollablePlainTextUntilClose() throws {
        let window = PagePresenter.showReadOnlyText(title: "DOM fixture", text: "<b>current DOM</b>")
        defer { window.close() }
        XCTAssertTrue(PagePresenter.readOnlyTextWindows.contains { $0 === window })
        XCTAssertTrue(window.isVisible)
        let scroll = try XCTUnwrap(window.contentView as? NSScrollView)
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(textView.string, "<b>current DOM</b>")
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertTrue(scroll.hasVerticalScroller)
        window.close()
        XCTAssertFalse(PagePresenter.readOnlyTextWindows.contains { $0 === window })
    }

    func testMediaPermissionContentRendersInLightAndDarkWithoutForegroundHost() throws {
        for (name, scheme) in [("Light", ColorScheme.light), ("Dark", ColorScheme.dark)] {
            var completions = 0
            let content = MediaPermissionContent(origin: "https://meet.example", device: "camera and microphone",
                symbol: "camera.fill", embeddedIn: nil, canRemember: true) { _, _ in completions += 1 }
                .environment(\.colorScheme, scheme)
                .fixedSize()
            let hosting = NSHostingView(rootView: content)
            hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            hosting.setFrameSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Media Permission Content — \(name) (render only)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(completions, 0)
        }
    }

    func testRememberedGrantDoesNotRequireForegroundPresentation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePermissionPresenter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteSettingsStore(directory: directory)
        let origin = URL(string: "https://camera.example")!
        store.update(SiteSetting(profileID: Profile.defaultID, origin: origin.absoluteString, camera: .allow, zoom: 1.5))
        let before = store.entries
        let presenter = PagePresenter(window: { nil })
        var decisions: [SitePermission] = []
        presenter.requestMedia(kinds: [.camera], origin: origin, topLevelOrigin: origin.absoluteString,
            sameOrigin: true, tabID: UUID(), contextID: .init(engineID: .webKit, profileID: Profile.defaultID, privateWindowID: nil),
            store: store, isCurrent: { true }) { decisions.append($0) }
        presenter.cancelAll(); presenter.cancelAll()
        XCTAssertEqual(decisions, [.allow])
        XCTAssertEqual(store.entries, before)
    }

    func testEmbeddedRememberedGrantStillRequiresForegroundPresentation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePermissionPresenter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteSettingsStore(directory: directory)
        let origin = URL(string: "https://camera.example")!
        store.update(SiteSetting(profileID: Profile.defaultID, origin: origin.absoluteString, camera: .allow))
        let presenter = PagePresenter(window: { nil })
        var decisions: [SitePermission] = []
        presenter.requestMedia(kinds: [.camera], origin: origin, topLevelOrigin: "https://embedder.example",
            sameOrigin: false, tabID: UUID(), contextID: .init(engineID: .webKit, profileID: Profile.defaultID, privateWindowID: nil),
            store: store, isCurrent: { true }) { decisions.append($0) }
        XCTAssertEqual(decisions, [.deny])
    }

    func testPendingMediaResolutionCannotOverwriteNewDeny() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePermissionPresenter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SiteSettingsStore(directory: directory)
        let origin = URL(string: "https://camera.example")!
        let context = BrowsingContextID(engineID: .webKit, profileID: Profile.defaultID, privateWindowID: nil)
        XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.camera],
            setting: store.setting(origin: origin, profileID: Profile.defaultID),
            isPrivate: false, sameOrigin: true), .ask)
        XCTAssertTrue(store.update(SiteSetting(profileID: Profile.defaultID,
            origin: origin.absoluteString, camera: .deny)))
        let decision = PagePresenter.resolveMediaPermission(allowed: true, remember: true,
            canRemember: true, kinds: [.camera], origin: origin, contextID: context,
            sameOrigin: true, store: store)
        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(store.setting(origin: origin, profileID: Profile.defaultID).camera, .deny)
    }

    func testStretchedAnchorPositionsPopoverOnTopLeadingChip() {
        let stretched = SiteControlAnchorView(frame: NSRect(x: 40, y: 80, width: 22, height: 400))
        XCTAssertFalse(stretched.isFlipped)
        XCTAssertEqual(stretched.positioningRect, NSRect(x: 0, y: 378, width: 22, height: 22))
        let compact = SiteControlAnchorView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        XCTAssertEqual(compact.positioningRect, compact.bounds)
    }

    func testPopoverCompletionIsOnceAndInvalidAnchorCannotGrantOrRemember() {
        let anchor = SiteControlAnchorView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        let id = UUID(), context = BrowsingContextID(engineID: .webKit, profileID: Profile.defaultID, privateWindowID: nil)
        anchor.tabID = id; anchor.contextID = context; anchor.isEnabled = true; anchor.isCurrent = { _, _ in true }
        var decisions: [(Bool, Bool)] = []
        let popover = MediaPermissionPopover(anchor: anchor, tabID: id, contextID: context,
            origin: "https://camera.example", device: "camera", symbol: "camera.fill", embeddedIn: nil,
            canRemember: true, isCurrent: { true }) { decisions.append(($0, $1)) }
        popover.finish(allowed: true, remember: true)
        popover.finish(allowed: false, remember: false)
        popover.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.0, false)
        XCTAssertEqual(decisions.first?.1, false)
    }

    func testAnchorInvalidationCancelsPendingPopoverOnce() {
        let anchor = SiteControlAnchorView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        let context = BrowsingContextID(engineID: .webKit, profileID: Profile.defaultID, privateWindowID: UUID())
        var completions = 0
        let popover = MediaPermissionPopover(anchor: anchor, tabID: UUID(), contextID: context,
            origin: "https://microphone.example", device: "microphone", symbol: "mic.fill", embeddedIn: "https://top.example",
            canRemember: false, isCurrent: { false }) { allowed, remember in
                XCTAssertFalse(allowed); XCTAssertFalse(remember); completions += 1
            }
        anchor.presentation = popover
        SiteControlAnchor.dismantleNSView(anchor, coordinator: ())
        SiteControlAnchor.dismantleNSView(anchor, coordinator: ())
        XCTAssertEqual(completions, 1)
        XCTAssertNil(anchor.presentation)
    }
}
