import AppKit
import UniformTypeIdentifiers

/// A page or download owns this presenter; every pending native completion is resolved once.
@MainActor final class PagePresenter {
    private final class CertificateChoiceView: NSView {
        let choices: [PageClientCertificateChoice]
        private let popup = NSPopUpButton()
        private let issuer = NSTextField(labelWithString: "")
        private let expiry = NSTextField(labelWithString: "")
        private let serial = NSTextField(labelWithString: "")
        private let dateFormatter = DateFormatter()

        init(choices: [PageClientCertificateChoice]) {
            self.choices = choices
            super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 88))
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .none
            popup.frame = NSRect(x: 0, y: 62, width: 420, height: 26)
            popup.setAccessibilityLabel(String(localized: "Client certificate"))
            for (index, field) in [issuer, expiry, serial].enumerated() {
                field.frame = NSRect(x: 2, y: 36 - index * 18, width: 416, height: 18)
                field.lineBreakMode = .byTruncatingTail
                addSubview(field)
            }
            for choice in choices {
                let subject = choice.certificate.subject.count > 72
                    ? "\(choice.certificate.subject.prefix(72))…" : choice.certificate.subject
                let serial = choice.serialNumber.map { " — …\($0.suffix(16))" } ?? ""
                popup.menu?.addItem(NSMenuItem(title: "\(subject)\(serial)",
                                                action: nil, keyEquivalent: ""))
            }
            popup.target = self
            popup.action = #selector(selectionChanged)
            addSubview(popup)
            selectionChanged()
        }

        required init?(coder: NSCoder) { nil }
        var selectedID: UUID? {
            choices.indices.contains(popup.indexOfSelectedItem)
                ? choices[popup.indexOfSelectedItem].id : nil
        }

        @objc private func selectionChanged() {
            guard choices.indices.contains(popup.indexOfSelectedItem) else {
                issuer.stringValue = ""; expiry.stringValue = ""; serial.stringValue = ""; return
            }
            let choice = choices[popup.indexOfSelectedItem]
            let expiration = choice.certificate.validUntil.map(dateFormatter.string)
                ?? String(localized: "unknown expiration")
            issuer.stringValue = "\(String(localized: "Issuer")): \(choice.certificate.issuer)"
            expiry.stringValue = "\(String(localized: "Expires")): \(expiration)"
            serial.stringValue = "\(String(localized: "Serial number")): \(choice.serialNumber ?? String(localized: "Unknown"))"
            let tooltip = "\(choice.certificate.subject)\n\(issuer.stringValue)\n\(expiry.stringValue)\n\(serial.stringValue)"
            issuer.toolTip = tooltip; expiry.toolTip = tooltip; serial.toolTip = tooltip
        }
    }
    @MainActor private final class TextWindowController: NSWindowController, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { PagePresenter.textWindows.removeAll { $0 === self } }
    }
    private static var textWindows: [TextWindowController] = []
    static var readOnlyTextWindows: [NSWindow] { textWindows.compactMap(\.window) }
    private let window: () -> NSWindow?
    private let pendingChanged: (Bool) -> Void
    private var cancellations: [UUID: () -> Void] = [:] {
        didSet { pendingChanged(!cancellations.isEmpty) }
    }
    init(window: @escaping () -> NSWindow?, pendingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.window = window
        self.pendingChanged = pendingChanged
    }

    static func alert(title: String, message: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }
    static func formRepostAlert(origin: String) -> NSAlert {
        alert(title: String(localized: "Resubmit form data?"),
              message: "\(origin)\n\n\(String(localized: "Reloading this content will resubmit form data."))",
              buttons: [String(localized: "Resubmit"), String(localized: "Cancel")])
    }
    func chooseClientCertificate(id: UUID, origin: String,
                                 choices: [PageClientCertificateChoice], truncated: Bool,
                                 completion: @escaping (UUID?) -> Void) {
        guard window() != nil, !choices.isEmpty else { completion(nil); return }
        let message = truncated
            ? "\(origin)\n\n\(String(localized: "Some available certificates could not be listed."))"
            : origin
        let alert = Self.alert(title: String(localized: "Choose a client certificate"),
                               message: message,
                               buttons: [String(localized: "Use Certificate"), String(localized: "Cancel")])
        let choicesControl = CertificateChoiceView(choices: choices)
        alert.accessoryView = choicesControl
        present(alert, id: id) { response in
            completion(response == .alertFirstButtonReturn ? choicesControl.selectedID : nil)
        }
    }
    @discardableResult static func showReadOnlyText(title: String, text: String) -> NSWindow {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = scroll
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        let controller = TextWindowController(window: window)
        window.delegate = controller
        textWindows.append(controller)
        controller.showWindow(nil)
        return window
    }
    func present(_ alert: NSAlert, id: UUID = UUID(), completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = window() else { completion(.cancel); return }
        cancellations[id] = {
            window.endSheet(alert.window, returnCode: .cancel)
            completion(.cancel)
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard self?.cancellations.removeValue(forKey: id) != nil else { return }
            completion(response)
        }
    }
    func chooseFiles(id: UUID = UUID(), multiple: Bool, directories: Bool, files: Bool = true,
                     acceptedTypes: [String] = [],
                     title: String? = nil, defaultFilename: String? = nil,
                     completion: @escaping ([URL]?) -> Void) {
        guard let window = window() else { completion(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple; panel.canChooseDirectories = directories; panel.canChooseFiles = files
        if let title, !title.isEmpty { panel.title = title }
        if let defaultFilename, !defaultFilename.isEmpty { panel.nameFieldStringValue = defaultFilename }
        let types = Self.contentTypes(acceptedTypes)
        if !types.isEmpty { panel.allowedContentTypes = types }
        cancellations[id] = { window.endSheet(panel, returnCode: .cancel); completion(nil) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard self?.cancellations.removeValue(forKey: id) != nil else { return }
            let urls = response == .OK ? panel.urls : nil
            // AppKit invokes this callback before fully detaching NSOpenPanel.
            // Resume the renderer after the host window is no longer sheet-occluded.
            DispatchQueue.main.async { completion(urls) }
        }
    }
    func chooseSaveFile(id: UUID = UUID(), acceptedTypes: [String] = [],
                        title: String? = nil, defaultFilename: String? = nil,
                        completion: @escaping (URL?) -> Void) {
        guard let window = window() else { completion(nil); return }
        let panel = NSSavePanel()
        if let title, !title.isEmpty { panel.title = title }
        if let defaultFilename, !defaultFilename.isEmpty { panel.nameFieldStringValue = defaultFilename }
        let types = Self.contentTypes(acceptedTypes)
        if !types.isEmpty { panel.allowedContentTypes = types }
        cancellations[id] = { window.endSheet(panel, returnCode: .cancel); completion(nil) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard self?.cancellations.removeValue(forKey: id) != nil else { return }
            let url = response == .OK ? panel.url : nil
            DispatchQueue.main.async { completion(url) }
        }
    }
    private static func contentTypes(_ values: [String]) -> [UTType] {
        values.compactMap { value in
            if value.hasPrefix(".") { return UTType(filenameExtension: String(value.dropFirst())) }
            if value.contains("/") && !value.hasSuffix("/*") { return UTType(mimeType: value) }
            return nil
        }
    }
    func requestMedia(id: UUID = UUID(), kinds: Set<PermissionKind>, origin: URL?, topLevelOrigin: String?, sameOrigin: Bool,
                      tabID: UUID, contextID: BrowsingContextID, store: SiteSettingsStore?,
                      isCurrent: @escaping () -> Bool, completion: @escaping (SitePermission) -> Void) {
        guard !kinds.isEmpty, isCurrent(), let origin,
              let originName = AddressResolver.canonicalOrigin(origin) else { completion(.deny); return }
        let setting = contextID.isPrivate ? nil : store?.setting(origin: origin, profileID: contextID.profileID, engineID: contextID.engineID)
        let decision = SiteSettingsStore.mediaDecision(kinds: kinds, setting: setting, isPrivate: contextID.isPrivate, sameOrigin: sameOrigin)
        guard decision == .ask else { completion(decision); return }
        guard let window = window(), NSApp.isActive, window.isKeyWindow, window.attachedSheet == nil,
              let anchor = SiteControlAnchorView.find(in: window.contentView, tabID: tabID, contextID: contextID),
              anchor.isEligible(tabID: tabID, contextID: contextID) else { completion(.deny); return }
        let device = kinds.count == 2 ? String(localized: "camera and microphone") : (kinds.contains(.camera) ? String(localized: "camera") : String(localized: "microphone"))
        let canRemember = !contextID.isPrivate && store != nil && sameOrigin
        let presentation = MediaPermissionPopover(anchor: anchor, tabID: tabID, contextID: contextID,
            origin: originName, device: device, symbol: kinds.contains(.camera) ? "camera.fill" : "mic.fill",
            embeddedIn: sameOrigin ? nil : (topLevelOrigin ?? String(localized: "an unidentified page")), canRemember: canRemember,
            isCurrent: isCurrent) { [weak self] allowed, remember in
            guard self?.cancellations.removeValue(forKey: id) != nil else { return }
            completion(Self.resolveMediaPermission(allowed: allowed && isCurrent(), remember: remember,
                canRemember: canRemember, kinds: kinds, origin: origin, contextID: contextID,
                sameOrigin: sameOrigin, store: store))
        }
        cancellations[id] = {
            presentation.finish(allowed: false, remember: false)
            completion(.deny)
        }
        presentation.show()
    }
    static func resolveMediaPermission(allowed: Bool, remember: Bool, canRemember: Bool,
                                       kinds: Set<PermissionKind>, origin: URL, contextID: BrowsingContextID,
                                       sameOrigin: Bool, store: SiteSettingsStore?) -> SitePermission {
        let currentSetting = contextID.isPrivate ? nil : store?.setting(origin: origin,
            profileID: contextID.profileID, engineID: contextID.engineID)
        guard SiteSettingsStore.mediaDecision(kinds: kinds, setting: currentSetting,
            isPrivate: contextID.isPrivate, sameOrigin: sameOrigin) != .deny else { return .deny }
        guard allowed else { return .deny }
        if canRemember, remember, let store {
            var saved = store.setting(origin: origin, profileID: contextID.profileID, engineID: contextID.engineID)
            if kinds.contains(.camera) { saved.camera = .allow }
            if kinds.contains(.microphone) { saved.microphone = .allow }
            store.update(saved)
        }
        return .allow
    }
    func cancel(_ id: UUID) {
        guard let cancel = cancellations.removeValue(forKey: id) else { return }
        cancel()
    }
    func cancelAll() {
        let pending = Array(cancellations.values)
        cancellations.removeAll()
        pending.forEach { $0() }
    }
}
