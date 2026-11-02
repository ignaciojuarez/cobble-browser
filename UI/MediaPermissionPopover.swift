import AppKit
import SwiftUI

struct SiteActionButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.08)), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

struct SiteControlAnchor: NSViewRepresentable {
    var tabID: UUID?
    var contextID: BrowsingContextID?
    var isEnabled: Bool
    var isCurrent: (UUID, BrowsingContextID) -> Bool
    func makeNSView(context: Context) -> SiteControlAnchorView { SiteControlAnchorView() }
    func updateNSView(_ view: SiteControlAnchorView, context: Context) {
        if view.tabID != tabID || view.contextID != contextID || view.isEnabled != isEnabled { view.presentation?.finish(allowed: false, remember: false) }
        view.tabID = tabID; view.contextID = contextID; view.isEnabled = isEnabled; view.isCurrent = isCurrent
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SiteControlAnchorView, context: Context) -> CGSize? {
        CGSize(width: 22, height: 22)
    }
    static func dismantleNSView(_ view: SiteControlAnchorView, coordinator: ()) { view.presentation?.finish(allowed: false, remember: false) }
}

@MainActor final class SiteControlAnchorView: NSView {
    var tabID: UUID?
    var contextID: BrowsingContextID?
    var isEnabled = false
    var isCurrent: (UUID, BrowsingContextID) -> Bool = { _, _ in false }
    weak var presentation: MediaPermissionPopover?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    // SwiftUI can still stretch the representable; NSPopover arrows to the center of
    // that rect. Pin to a 22×22 chip at the visual top so the prompt stays on the shield.
    var positioningRect: NSRect {
        let side = min(22 as CGFloat, bounds.width, bounds.height)
        guard side > 0 else { return .zero }
        if window != nil {
            let inWindow = convert(bounds, to: nil)
            return convert(NSRect(x: inWindow.minX, y: inWindow.maxY - side, width: side, height: side), from: nil)
        }
        let y = isFlipped ? bounds.minY : bounds.maxY - side
        return NSRect(x: bounds.minX, y: y, width: side, height: side)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { presentation?.finish(allowed: false, remember: false) }
        super.viewWillMove(toWindow: newWindow)
    }
    func isEligible(tabID: UUID, contextID: BrowsingContextID) -> Bool {
        isEnabled && self.tabID == tabID && self.contextID == contextID && isCurrent(tabID, contextID)
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty && window?.isVisible == true && window?.isMiniaturized == false
    }
    static func find(in view: NSView?, tabID: UUID, contextID: BrowsingContextID) -> SiteControlAnchorView? {
        guard let view else { return nil }
        if let anchor = view as? SiteControlAnchorView, anchor.isEligible(tabID: tabID, contextID: contextID) { return anchor }
        return view.subviews.lazy.compactMap { find(in: $0, tabID: tabID, contextID: contextID) }.first
    }
}

/// Allowing is remembered for the site whenever the request can be remembered.
struct MediaPermissionContent: View {
    let origin: String
    let device: String
    let symbol: String
    let embeddedIn: String?
    let canRemember: Bool
    let finish: (Bool, Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 34, height: 34).background(.tint.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: String(localized: "Allow %@ to use your %@?"), URL(string: origin)?.host ?? origin, device))
                        .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(origin).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let embeddedIn {
                        Text(String(format: String(localized: "Embedded in %@. This request only."), embeddedIn))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if !canRemember {
                        Text("This request only.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Not Now") { finish(false, false) }.buttonStyle(SiteActionButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Allow") { finish(true, canRemember) }.buttonStyle(SiteActionButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 300)
    }
}

@MainActor final class MediaPermissionPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private weak var anchor: SiteControlAnchorView?
    private weak var owner: NSWindow?
    private let tabID: UUID
    private let contextID: BrowsingContextID
    private let isCurrent: () -> Bool
    private var completion: ((Bool, Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    init(anchor: SiteControlAnchorView, tabID: UUID, contextID: BrowsingContextID,
         origin: String, device: String, symbol: String, embeddedIn: String?, canRemember: Bool,
         isCurrent: @escaping () -> Bool, completion: @escaping (Bool, Bool) -> Void) {
        self.anchor = anchor; owner = anchor.window; self.tabID = tabID; self.contextID = contextID
        self.isCurrent = isCurrent; self.completion = completion
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: MediaPermissionContent(origin: origin,
            device: device, symbol: symbol, embeddedIn: embeddedIn, canRemember: canRemember) { [weak self] allowed, remember in
                self?.finish(allowed: allowed, remember: remember)
            })
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }
    private var eligible: Bool {
        guard let owner, let anchor, owner.attachedSheet == nil, NSApp.isActive, isCurrent(),
              anchor.isEligible(tabID: tabID, contextID: contextID) else { return false }
        return owner.isKeyWindow || popover.contentViewController?.view.window?.isKeyWindow == true
    }
    func show() {
        guard let anchor, eligible else { finish(allowed: false, remember: false); return }
        anchor.presentation?.finish(allowed: false, remember: false)
        guard eligible else { finish(allowed: false, remember: false); return }
        anchor.presentation = self
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    guard let self, !self.eligible else { return }
                    self.finish(allowed: false, remember: false)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                guard let self, !self.eligible else { return }
                self.finish(allowed: false, remember: false)
            }
        })
        popover.show(relativeTo: anchor.positioningRect, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        if !popover.isShown { finish(allowed: false, remember: false) }
    }
    func finish(allowed: Bool, remember: Bool) {
        guard let completion else { return }
        let granted = allowed && anchor?.isEligible(tabID: tabID, contextID: contextID) == true && isCurrent()
        self.completion = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if anchor?.presentation === self { anchor?.presentation = nil }
        popover.close()
        completion(granted, granted && remember)
    }
    func popoverDidClose(_ notification: Notification) { finish(allowed: false, remember: false) }
}
