import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarDropKind: Equatable {
    case favorite
    case favoritesEnd
    case pin
    case pinGrid
    case pinsEnd
    case folderHeader(parentID: UUID?, depth: Int, collapsed: Bool)
    case folderChild(folderID: UUID)
    case folderEmpty(folderID: UUID)
    case newTab
    case tab

    var slot: SidebarDropSlot {
        switch self {
        case .favorite: return .favorite
        case .favoritesEnd: return .favoritesEnd
        case .pin, .pinGrid: return .pin
        case .pinsEnd: return .pinsEnd
        case .folderHeader: return .folderHeader
        case .folderChild: return .folderChild
        case .folderEmpty: return .folderEmpty
        case .newTab: return .newTab
        case .tab: return .tab
        }
    }
}

enum SidebarDropSlot: Hashable { case favorite, favoritesEnd, pin, pinsEnd, folderHeader, folderChild, folderEmpty, newTab, tab }

enum SidebarDropGroup: Equatable, Sendable {
    case favorites
    case rootPins
    case folder(UUID)
    case folders(parentID: UUID?)
    case tabs
}

enum SidebarDropTarget: Equatable, Sendable {
    case ontoFolder(UUID)
    case space(UUID)
    case spaceInsert(before: UUID?)
    case insert(before: UUID?, group: SidebarDropGroup, y: CGFloat, indent: Bool)

    var highlightedFolder: UUID? {
        if case .ontoFolder(let id) = self { return id }
        return nil
    }

    var spaceID: UUID? {
        if case .space(let id) = self { return id }
        return nil
    }

    var belongsToSpacePicker: Bool {
        switch self {
        case .space, .spaceInsert: true
        default: false
        }
    }
}

enum SidebarDropPayload: Equatable, Sendable {
    case saved(UUID)
    case tab(UUID)
    case folder(UUID)
    case space(UUID)

    var id: UUID {
        switch self {
        case .saved(let id), .tab(let id), .folder(let id), .space(let id): return id
        }
    }
}

struct SidebarDropRow: Equatable {
    var id: UUID
    var kind: SidebarDropKind
    var frame: CGRect
}

enum SidebarDrop {
    static let spaceName = "sidebar-drop"
    static let spacePickerSpacing: CGFloat = 2
    static let spacePickerInset: CGFloat = 6
    static let rootIndent: CGFloat = 9
    static let folderIndent: CGFloat = 25
    static let favoritesEndID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    static let pinsEndID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!
    static let pinPlaceholderID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FB")!
    static let newTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FD")!

    static func pinGridColumnCount(_ count: Int, fitting width: CGFloat? = nil, spacing: CGFloat = 8) -> Int {
        let balanced = switch count {
        case 2, 4: 2
        case 5, 6, 9: 3
        default: min(4, max(1, count))
        }
        guard let width else { return balanced }
        let capacity = min(4, max(1, Int((max(0, width) + spacing) / (46 + spacing))))
        return min(balanced, capacity)
    }

    static func parse(_ value: String) -> SidebarDropPayload? {
        if value.hasPrefix("saved:"), let id = UUID(uuidString: String(value.dropFirst(6))) { return .saved(id) }
        if value.hasPrefix("tab:"), let id = UUID(uuidString: String(value.dropFirst(4))) { return .tab(id) }
        if value.hasPrefix("folder:"), let id = UUID(uuidString: String(value.dropFirst(7))) { return .folder(id) }
        if value.hasPrefix("space:"), let id = UUID(uuidString: String(value.dropFirst(6))) { return .space(id) }
        return nil
    }

    static func allows(_ payload: SidebarDropPayload, _ target: SidebarDropTarget) -> Bool {
        switch payload {
        case .space:
            if case .spaceInsert = target { return true }
            return false
        case .saved, .tab:
            if case .spaceInsert = target { return false }
            if case .insert(_, .folders, _, _) = target { return false }
            return true
        case .folder(let id):
            switch target {
            case .space: return true
            case .ontoFolder(let folderID): return folderID != id
            case .insert(let before, .folders(let parent), _, _): return parent != id && before != id
            case .insert(_, .favorites, _, _), .insert(_, .rootPins, _, _),
                 .insert(_, .folder, _, _), .insert(_, .tabs, _, _), .spaceInsert: return false
            }
        }
    }

    static func spaceInsert(ids: [UUID], widths: [UUID: CGFloat], excluding: UUID, x: CGFloat,
                            spacing: CGFloat = spacePickerSpacing) -> SidebarDropTarget {
        var minX: CGFloat = 0
        for id in ids {
            let width = widths[id] ?? 30
            if id != excluding, x < minX + width / 2 { return .spaceInsert(before: id) }
            minX += width + spacing
        }
        return .spaceInsert(before: nil)
    }

    static func spaceAt(ids: [UUID], widths: [UUID: CGFloat], x: CGFloat,
                        spacing: CGFloat = spacePickerSpacing) -> UUID? {
        var minX: CGFloat = 0
        for id in ids {
            let width = widths[id] ?? 30
            if x < minX + width + spacing / 2 { return id }
            minX += width + spacing
        }
        return ids.last
    }

    static func spacePickerOffset(for id: UUID, ids: [UUID], dragged: UUID, before: UUID?, gap: CGFloat) -> CGFloat {
        guard id != dragged, let source = ids.firstIndex(of: dragged), let index = ids.firstIndex(of: id) else { return 0 }
        let dest = before.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        if source < dest, index > source, index < dest { return -gap }
        if dest < source, index >= dest, index < source { return gap }
        return 0
    }

    static func hitTest(rows: [SidebarDropRow], x: CGFloat? = nil, y: CGFloat, payload: SidebarDropPayload? = nil) -> SidebarDropTarget? {
        if case .folder(let id) = payload { return folderHitTest(rows: rows, y: y, moving: id) }
        let sorted = rows.filter { $0.frame.height > 0.5 }.sorted { $0.frame.minY < $1.frame.minY }
        guard !sorted.isEmpty else { return nil }
        if let x, let target = pinGridTarget(rows: sorted, x: x, y: y, kind: .favorite, group: .favorites) { return target }
        if let x, let target = pinGridTarget(rows: sorted, x: x, y: y, kind: .pinGrid, group: .rootPins) { return target }
        for (index, row) in sorted.enumerated() {
            if row.frame.minY <= y, y < row.frame.maxY {
                if case .folderHeader = row.kind {
                    if y < row.frame.minY + min(10, row.frame.height / 3) {
                        return insert(before: row, at: index, in: sorted, pointerY: y)
                    }
                    return .ontoFolder(row.id)
                }
                if case .folderEmpty(let id) = row.kind { return .ontoFolder(id) }
            }
        }
        for (index, row) in sorted.enumerated() where y < row.frame.midY {
            return insert(before: row, at: index, in: sorted, pointerY: y)
        }
        return insertAfterLast(sorted)
    }

    private static func pinGridTarget(rows: [SidebarDropRow], x: CGFloat, y: CGFloat,
                                      kind: SidebarDropKind, group: SidebarDropGroup) -> SidebarDropTarget? {
        let pins = rows.filter { $0.kind == kind }.sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
        guard let first = pins.first, let last = pins.last else { return nil }
        let tileBounds = pins.map(\.frame).reduce(first.frame) { $0.union($1) }
        let bounds = rows.first { kind == .favorite && $0.kind == .favoritesEnd }?.frame
            ?? tileBounds.insetBy(dx: -8, dy: -8)
        guard bounds.contains(CGPoint(x: x, y: y)) else { return nil }
        if y >= tileBounds.maxY {
            return .insert(before: nil, group: group, y: tileBounds.maxY, indent: false)
        }
        let rowY = pins.map { $0.frame.minY }.min { abs($0 - y) < abs($1 - y) } ?? first.frame.minY
        let row = pins.filter { abs($0.frame.minY - rowY) < 1 }.sorted { $0.frame.minX < $1.frame.minX }
        for pin in row where x < pin.frame.midX {
            return .insert(before: pin.id, group: group, y: pin.frame.minY, indent: false)
        }
        if let next = pins.first(where: { $0.frame.minY > rowY }) {
            return .insert(before: next.id, group: group, y: next.frame.minY, indent: false)
        }
        return .insert(before: nil, group: group, y: last.frame.maxY, indent: false)
    }

    private static func folderHitTest(rows: [SidebarDropRow], y: CGFloat, moving id: UUID) -> SidebarDropTarget? {
        let sorted = rows.filter { $0.frame.height > 0.5 }.sorted { $0.frame.minY < $1.frame.minY }
        guard !sorted.isEmpty else { return nil }
        for row in sorted where row.frame.minY <= y && y < row.frame.maxY {
            guard case .folderHeader(let parentID, _, _) = row.kind else { break }
            let edge = min(10, row.frame.height / 3)
            if y < row.frame.minY + edge {
                return .insert(before: row.id, group: .folders(parentID: parentID), y: row.frame.minY,
                               indent: parentID != nil)
            }
            if y >= row.frame.maxY - edge {
                return folderInsertion(parentID: parentID, after: row.id, moving: id, rows: sorted)
            }
            return .ontoFolder(row.id)
        }
        guard let raw = itemHitTest(rows: sorted, y: y) else { return nil }
        switch raw {
        case .ontoFolder(let id): return .ontoFolder(id)
        case .insert(_, .rootPins, _, _): return folderInsertion(parentID: nil, at: y, moving: id, rows: sorted)
        case .insert(_, .folder(let parent), _, _):
            return folderInsertion(parentID: parent, at: y, moving: id, rows: sorted)
        default: return nil
        }
    }

    private static func itemHitTest(rows: [SidebarDropRow], y: CGFloat) -> SidebarDropTarget? {
        let sorted = rows.filter { $0.frame.height > 0.5 }.sorted { $0.frame.minY < $1.frame.minY }
        guard !sorted.isEmpty else { return nil }
        for row in sorted where row.frame.minY <= y && y < row.frame.maxY {
            if case .folderHeader = row.kind { return .ontoFolder(row.id) }
            if case .folderEmpty(let id) = row.kind { return .ontoFolder(id) }
        }
        for (index, row) in sorted.enumerated() where y < row.frame.midY {
            return insert(before: row, at: index, in: sorted, pointerY: y)
        }
        return insertAfterLast(sorted)
    }

    private static func folderInsertion(parentID: UUID?, at y: CGFloat = .greatestFiniteMagnitude,
                                        after: UUID? = nil, moving id: UUID, rows: [SidebarDropRow]) -> SidebarDropTarget? {
        let siblings = rows.compactMap { row -> SidebarDropRow? in
            guard row.id != id, case .folderHeader(let parent, _, _) = row.kind, parent == parentID else { return nil }
            return row
        }
        let start = after.flatMap { id in siblings.firstIndex(where: { $0.id == id }).map { $0 + 1 } } ?? 0
        if let next = siblings.dropFirst(start).first(where: { $0.frame.midY > y || after != nil }) {
            return .insert(before: next.id, group: .folders(parentID: parentID), y: next.frame.minY,
                           indent: parentID != nil)
        }
        let boundary: CGFloat
        if let parentID,
           let parent = rows.first(where: { $0.id == parentID && $0.kind.slot == .folderHeader }),
           case .folderHeader(_, let depth, _) = parent.kind,
           let next = rows.first(where: { row in
               guard row.frame.minY > parent.frame.minY else { return false }
               if case .folderHeader(_, let candidateDepth, _) = row.kind { return candidateDepth <= depth }
               return row.kind.slot == .pinsEnd
           }) {
            boundary = next.frame.minY
        } else {
            boundary = rows.first(where: { $0.kind.slot == .pinsEnd })?.frame.minY
                ?? siblings.last?.frame.maxY ?? 0
        }
        return .insert(before: nil, group: .folders(parentID: parentID), y: boundary, indent: parentID != nil)
    }

    private static func insert(before row: SidebarDropRow, at index: Int, in sorted: [SidebarDropRow], pointerY: CGFloat) -> SidebarDropTarget {
        let y = row.frame.minY
        let previous = index > 0 ? sorted[index - 1] : nil
        if case .folderHeader(let parentID?, let depth, _) = row.kind {
            return .insert(before: row.id, group: .folder(parentID), y: y, indent: depth > 0)
        }
        if let folderID = nestedEndGap(previous: previous, next: row) {
            return .insert(before: nil, group: .folder(folderID), y: y, indent: true)
        }
        if let previous, isFavoritesEndGap(previous: previous, next: row, pointerY: pointerY) {
            return .insert(before: nil, group: .favorites, y: previous.frame.maxY, indent: false)
        }
        switch row.kind {
        case .favorite:
            return .insert(before: row.id, group: .favorites, y: y, indent: false)
        case .favoritesEnd:
            return .insert(before: nil, group: .favorites, y: y, indent: false)
        case .pin, .pinGrid:
            return .insert(before: row.id, group: .rootPins, y: y, indent: false)
        case .pinsEnd:
            return .insert(before: nil, group: .rootPins, y: y, indent: false)
        case .folderHeader(let parentID, let depth, _):
            return .insert(before: row.id, group: parentID.map(SidebarDropGroup.folder) ?? .rootPins,
                           y: y, indent: depth > 0)
        case .folderChild(let folderID):
            return .insert(before: row.id, group: .folder(folderID), y: y, indent: true)
        case .folderEmpty(let folderID):
            return .insert(before: nil, group: .folder(folderID), y: y, indent: true)
        case .newTab:
            let before = sorted.dropFirst(index + 1).first { $0.kind == .tab }?.id
            return .insert(before: before, group: .tabs, y: row.frame.maxY, indent: false)
        case .tab:
            return .insert(before: row.id, group: .tabs, y: y, indent: false)
        }
    }

    private static func insertAfterLast(_ sorted: [SidebarDropRow]) -> SidebarDropTarget {
        let last = sorted[sorted.count - 1]
        let y = last.frame.maxY
        switch last.kind {
        case .favorite, .favoritesEnd:
            return .insert(before: nil, group: .favorites, y: y, indent: false)
        case .pin, .pinGrid:
            return .insert(before: nil, group: .rootPins, y: y, indent: false)
        case .pinsEnd:
            return .insert(before: nil, group: .tabs, y: y, indent: false)
        case .folderHeader(let parentID, let depth, let collapsed):
            return collapsed
                ? .insert(before: nil, group: parentID.map(SidebarDropGroup.folder) ?? .rootPins, y: y, indent: depth > 0)
                : .insert(before: nil, group: .folder(last.id), y: y, indent: true)
        case .folderChild(let id), .folderEmpty(let id):
            return .insert(before: nil, group: .folder(id), y: y, indent: true)
        case .newTab, .tab:
            return .insert(before: nil, group: .tabs, y: y, indent: false)
        }
    }

    private static func nestedEndGap(previous: SidebarDropRow?, next: SidebarDropRow) -> UUID? {
        guard let previous else { return nil }
        switch next.kind { case .pin, .pinGrid, .pinsEnd, .folderHeader: break; default: return nil }
        switch previous.kind {
        case .folderChild(let id), .folderEmpty(let id): return id
        case .folderHeader(let parentID, _, let collapsed): return collapsed ? parentID : previous.id
        default: return nil
        }
    }

    private static func isFavoritesEndGap(previous: SidebarDropRow, next: SidebarDropRow, pointerY: CGFloat) -> Bool {
        guard previous.kind == .favorite else { return false }
        switch next.kind {
        case .favorite, .favoritesEnd: return false
        default: return pointerY < (previous.frame.maxY + next.frame.minY) / 2
        }
    }
}

@MainActor @Observable
final class SidebarDropSession {
    private struct RowKey: Hashable { var id: UUID; var slot: SidebarDropSlot }

    var rows: [SidebarDropRow] = []
    var spaceWidths: [UUID: CGFloat] = [:]
    var favoritesActivationMaxY: CGFloat?
    var target: SidebarDropTarget? { didSet { updateDragFeedback() } }
    var payload: SidebarDropPayload? { didSet { updateDragFeedback() } }
    private(set) var emptyFavoritesExpanded = false
    private(set) var generation = 0
    private var mouseMonitor: Any?
    private var hidesChrome = false
    private var ghostID: UUID?
    private var ghostWindow: NSPanel?
    private var ghostTimer: Timer?
    private var ghostResize: DispatchWorkItem?
    private let ghostState = SidebarGhostState()
    private var hapticTarget: SidebarDropTarget?
    private var rowRegistrations: [RowKey: UUID] = [:]

    var draggedID: UUID? { hidesChrome ? nil : payload?.id ?? ghostID }

    var acceptedTarget: SidebarDropTarget? {
        guard let target else { return nil }
        if let payload {
            guard SidebarDrop.allows(payload, target) else { return nil }
            if case .folder(let id) = payload {
                if case .ontoFolder(let folderID) = target, isDescendant(folderID, of: id) { return nil }
                if case .insert(_, .folders(let parentID), _, _) = target,
                   let parentID, isDescendant(parentID, of: id) { return nil }
            }
        }
        return target
    }

    var visibleTarget: SidebarDropTarget? { hidesChrome ? nil : acceptedTarget }

    func expandEmptyFavoritesIfNeeded() {
        guard !rows.contains(where: { $0.kind == .favorite }) else { return }
        switch payload {
        case .saved, .tab: emptyFavoritesExpanded = true
        case .folder, .space, nil: break
        }
    }

    func emptyFavoritesTarget(at y: CGFloat) -> SidebarDropTarget? {
        guard let payload else { return nil }
        switch payload {
        case .saved, .tab: break
        case .folder, .space: return nil
        }
        guard !rows.contains(where: { $0.kind == .favorite }),
              let end = rows.first(where: { $0.kind == .favoritesEnd }),
              let maxY = favoritesActivationMaxY,
              y >= end.frame.minY, y <= maxY else { return nil }
        emptyFavoritesExpanded = true
        return .insert(before: nil, group: .favorites, y: end.frame.minY, indent: false)
    }

    private func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var current: UUID? = id
        var visited = Set<UUID>()
        while let candidate = current, visited.insert(candidate).inserted {
            if candidate == ancestor { return true }
            guard let row = rows.first(where: { $0.id == candidate }),
                  case .folderHeader(let parentID, _, _) = row.kind else { return false }
            current = parentID
        }
        return false
    }

    func upsert(_ row: SidebarDropRow, registration: UUID? = nil) {
        let key = RowKey(id: row.id, slot: row.kind.slot)
        if let registration { rowRegistrations[key] = registration }
        if let i = rows.firstIndex(where: { $0.id == row.id && $0.kind.slot == row.kind.slot }) {
            if rows[i] != row { rows[i] = row }
        } else {
            rows.append(row)
        }
    }

    func remove(id: UUID, slot: SidebarDropSlot, registration: UUID? = nil) {
        let key = RowKey(id: id, slot: slot)
        if let registration, rowRegistrations[key] != registration { return }
        guard rows.contains(where: { $0.id == id && $0.kind.slot == slot }) else { return }
        rowRegistrations[key] = nil
        rows.removeAll { $0.id == id && $0.kind.slot == slot }
    }

    func resetSpaceRows() {
        rows.removeAll { $0.kind != .favorite && $0.kind != .favoritesEnd }
        rowRegistrations = rowRegistrations.filter { $0.key.slot == .favorite || $0.key.slot == .favoritesEnd }
    }

    func armEndMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDragged]) { [weak self] event in
            if event.type == .leftMouseDragged {
                self?.followCursor()
                return event
            }
            self?.finishPreview()
            return event
        }
    }

    private func finishPreview() {
        tearDownGhost()
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard self?.generation == generation else { return }
            self?.clear()
        }
    }

    func setPayload(_ payload: SidebarDropPayload, generation: Int) {
        guard generation == self.generation, !hidesChrome else { return }
        self.payload = payload
    }

    func ghostPreview(payload: SidebarDropPayload, title: String, icon: NSImage?, empty: Bool = false,
                      onStart: (() -> Void)? = nil) -> some View {
        SidebarDragGhostView(title: title, icon: icon, empty: empty)
            .opacity(0.01)
            .background(DragGhostAnchor(session: self, id: payload.id, payload: payload,
                                        title: title, icon: icon, empty: empty, onStart: onStart))
    }

    func spaceChipGhost(id: UUID, title: String, selected: Bool) -> some View {
        SpacePickerChip(title: title, selected: selected, highlighted: true)
            .opacity(0.01)
            .background(DragGhostAnchor(session: self, id: id, payload: .space(id), title: title, selected: selected, chip: true))
    }

    func showGhost(id: UUID, payload: SidebarDropPayload? = nil, title: String, icon: NSImage?, empty: Bool,
                   environment: EnvironmentValues, onStart: (() -> Void)? = nil) {
        if self.payload == nil { onStart?() }
        if let payload { setPayload(payload, generation: generation) }
        ghostState.pinDrop = pinDrop
        let host = NSHostingView(rootView: SidebarMorphingGhostView(title: title, icon: icon, empty: empty, state: ghostState).environment(\.self, environment))
        presentGhost(id: id, size: NSSize(width: pinDrop ? 58 : 220, height: 46), host: host)
    }

    private var pinDrop: Bool {
        guard case .insert(_, let group, _, _) = visibleTarget else { return false }
        return group == .favorites
    }

    private func updateGhostAppearance() {
        let pin = pinDrop
        guard ghostState.pinDrop != pin else { return }
        ghostResize?.cancel()
        if !pin { resizeGhost(width: 220) }
        ghostState.pinDrop = pin
        guard pin else { return }
        let work = DispatchWorkItem { [weak self] in
            guard self?.ghostState.pinDrop == true else { return }
            self?.resizeGhost(width: 58)
        }
        ghostResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func resizeGhost(width: CGFloat) {
        guard let panel = ghostWindow else { return }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: width, height: 46)), display: true)
        followCursor()
    }

    private func updateDragFeedback() {
        updateGhostAppearance()
        let next = visibleTarget
        guard next != hapticTarget else { return }
        hapticTarget = next
        guard NSEvent.pressedMouseButtons & 1 != 0, case .insert = next else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func showChipGhost(id: UUID, payload: SidebarDropPayload? = nil, title: String, selected: Bool, environment: EnvironmentValues) {
        if let payload { setPayload(payload, generation: generation) }
        let side = environment.browserTheme.configuration.controls.space.side
        let width = spaceWidths[id] ?? side
        presentGhost(id: id, size: NSSize(width: width, height: side), host: NSHostingView(rootView: SpacePickerChip(title: title, selected: selected, highlighted: true).environment(\.self, environment)))
    }

    private func presentGhost(id: UUID, size: NSSize, host: NSView) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        armEndMonitor()
        ghostID = id
        host.frame = NSRect(origin: .zero, size: size)
        let panel = ghostWindow ?? makeGhostPanel(size: size)
        panel.setContentSize(size)
        panel.contentView = host
        ghostWindow = panel
        followCursor()
        startFollowingCursor()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hideChrome() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { hidesChrome = true }
        tearDownGhost()
    }

    func clear() {
        generation += 1
        hidesChrome = false
        emptyFavoritesExpanded = false
        target = nil
        payload = nil
        tearDownGhost()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    isolated deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        ghostTimer?.invalidate()
        ghostWindow?.orderOut(nil)
    }

    private func makeGhostPanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) + 1)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    func followCursor() {
        // The drop callback may arrive after mouse-up; only it (or the end monitor) clears the target.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { finishPreview(); return }
        guard let ghostWindow else { return }
        let mouse = NSEvent.mouseLocation
        ghostWindow.setFrameOrigin(NSPoint(x: mouse.x + 10, y: mouse.y - ghostWindow.frame.height + 8))
    }

    private func startFollowingCursor() {
        guard ghostTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ghostTimer = timer
    }

    private func tearDownGhost() {
        ghostTimer?.invalidate()
        ghostTimer = nil
        ghostResize?.cancel()
        ghostResize = nil
        ghostID = nil
        ghostState.pinDrop = false
        ghostWindow?.alphaValue = 0
        ghostWindow?.orderOut(nil)
        ghostWindow = nil
    }
}

private struct DragGhostAnchor: NSViewRepresentable {
    var session: SidebarDropSession
    var id: UUID
    var payload: SidebarDropPayload?
    var title: String
    var icon: NSImage?
    var empty = false
    var selected = false
    var chip = false
    var onStart: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        if chip {
            session.showChipGhost(id: id, payload: payload, title: title, selected: selected, environment: context.environment)
        } else {
            session.showGhost(id: id, payload: payload, title: title, icon: icon,
                              empty: empty, environment: context.environment, onStart: onStart)
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SidebarDropDelegate: DropDelegate {
    let session: SidebarDropSession
    var forcedTarget: SidebarDropTarget? = nil
    var spaceIDs: [UUID] = []
    var spaceSpacing: CGFloat = SidebarDrop.spacePickerSpacing
    let commit: @MainActor @Sendable (SidebarDropPayload, SidebarDropTarget) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText, .plainText, .text])
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        if !spaceIDs.isEmpty, session.target == nil { return DropProposal(operation: .forbidden) }
        if let payload = session.payload, let target = session.target, !SidebarDrop.allows(payload, target) {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard session.target?.belongsToSpacePicker == !spaceIDs.isEmpty else { return }
        session.target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = session.acceptedTarget
        let payload = session.payload
        session.hideChrome()
        session.clear()
        guard let target else { return false }
        guard let payload else {
            return load(info) { payload in
                guard SidebarDrop.allows(payload, target) else { return }
                _ = commit(payload, target)
            }
        }
        return commit(payload, target)
    }

    private func update(_ info: DropInfo) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        session.armEndMonitor()
        if session.payload == nil { load(info) }
        if !spaceIDs.isEmpty {
            session.target = spacePickerTarget(at: info.location.x)
        } else if let forcedTarget {
            if case .insert(_, .favorites, _, _) = forcedTarget { session.expandEmptyFavoritesIfNeeded() }
            session.target = forcedTarget
        } else {
            session.target = session.emptyFavoritesTarget(at: info.location.y) ?? SidebarDrop.hitTest(
                rows: session.rows, x: info.location.x, y: info.location.y, payload: session.payload
            )
        }
        session.followCursor()
    }

    private func spacePickerTarget(at x: CGFloat) -> SidebarDropTarget? {
        let x = x - SidebarDrop.spacePickerInset - spaceSpacing
        if let dragged = session.draggedID, spaceIDs.contains(dragged) {
            return SidebarDrop.spaceInsert(ids: spaceIDs, widths: session.spaceWidths, excluding: dragged, x: x,
                                           spacing: spaceSpacing)
        }
        return SidebarDrop.spaceAt(ids: spaceIDs, widths: session.spaceWidths, x: x,
                                   spacing: spaceSpacing).map(SidebarDropTarget.space)
    }

    @discardableResult
    private func load(_ info: DropInfo, completion: (@MainActor @Sendable (SidebarDropPayload) -> Void)? = nil) -> Bool {
        guard let provider = info.itemProviders(for: [.utf8PlainText, .plainText, .text]).first else { return false }
        let session = session
        let generation = session.generation
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                let payload = (object as? NSString).flatMap { SidebarDrop.parse(($0 as String).trimmingCharacters(in: .whitespacesAndNewlines)) }
                DispatchQueue.main.async {
                    if let payload {
                        if let completion { completion(payload) }
                        else { session.setPayload(payload, generation: generation) }
                    }
                }
            }
            return true
        }
        let identifier = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
            ? UTType.utf8PlainText.identifier : UTType.plainText.identifier
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
            let raw: String?
            if let data = item as? Data { raw = String(data: data, encoding: .utf8) }
            else if let string = item as? String { raw = string }
            else if let string = item as? NSString { raw = string as String }
            else { raw = nil }
            let payload = raw.flatMap { SidebarDrop.parse($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            DispatchQueue.main.async {
                if let payload {
                    if let completion { completion(payload) }
                    else { session.setPayload(payload, generation: generation) }
                }
            }
        }
        return true
    }
}

struct SpacePickerChip: View {
    var title: String
    var selected: Bool
    var highlighted: Bool
    @Environment(\.browserTheme) private var theme

    var body: some View {
        Group {
            if theme.configuration.spacePreview.showsIcon(selected: selected) {
                Text(title).lineLimit(1)
            } else {
                Circle().fill(.white).frame(width: theme.configuration.spacePreview.dotSize,
                                            height: theme.configuration.spacePreview.dotSize)
            }
        }
        .opacity(selected ? 1 : theme.configuration.spacePreview.inactiveOpacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sidebarItemControl(tint: theme.primary, role: .space, highlighted: highlighted)
    }
}

struct SidebarDragGhostView: View {
    var title: String
    var icon: NSImage?
    var empty: Bool
    @Environment(\.browserTheme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
            } else {
                Image(systemName: empty ? "circle.dotted" : "globe").font(.system(size: 16))
                    .foregroundStyle(.secondary).frame(width: 16)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(width: 220, alignment: .leading)
        .background(theme.selectedTab, in: RoundedRectangle(cornerRadius: theme.controlCornerRadius))
    }
}

@MainActor @Observable
final class SidebarGhostState {
    var pinDrop = false
}

struct SidebarMorphingGhostView: View {
    var title: String
    var icon: NSImage?
    var empty: Bool
    @Bindable var state: SidebarGhostState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.browserTheme) private var theme

    var body: some View {
        let pin = state.pinDrop
        ZStack(alignment: .leading) {
            ZStack {
                HStack(spacing: 9) {
                    ghostIcon(size: 16)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(9)
                .opacity(pin ? 0 : 1)
                .scaleEffect(pin ? 0.86 : 1, anchor: .leading)

                ghostIcon(size: 14)
                    .opacity(pin ? 1 : 0)
                    .scaleEffect(pin ? 1 : 0.55)
            }
            .frame(width: pin ? 58 : 220, height: pin ? 46 : 36)
            .background(pin ? theme.pin : theme.selectedTab,
                        in: RoundedRectangle(cornerRadius: theme.controlCornerRadius))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: pin)
        }
        .frame(width: 220, height: 46, alignment: .leading)
    }

    @ViewBuilder
    private func ghostIcon(size: CGFloat) -> some View {
        if let icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size) }
        else { Image(systemName: empty ? "circle.dotted" : "globe").font(.system(size: size)).foregroundStyle(.secondary).frame(width: size, height: size) }
    }
}

struct SidebarDropIndicator: View {
    var indent: Bool

    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.primary).frame(width: 6, height: 6)
            Capsule().fill(Color.primary).frame(height: 2)
        }
        .padding(.leading, indent ? SidebarDrop.folderIndent : SidebarDrop.rootIndent)
        .padding(.trailing, 9)
        .offset(y: -4)
        .allowsHitTesting(false)
    }
}

private struct SidebarDropFrameModifier: ViewModifier {
    var row: SidebarDropRow?
    var session: SidebarDropSession
    @State private var registration = UUID()

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDrop.spaceName)) } action: { frame in
            guard var row else { return }
            row.frame = frame
            session.upsert(row, registration: registration)
        }
        .onDisappear {
            guard let row else { return }
            session.remove(id: row.id, slot: row.kind.slot, registration: registration)
        }
    }
}

extension View {
    func sidebarDropFrame(_ row: SidebarDropRow?, session: SidebarDropSession) -> some View {
        modifier(SidebarDropFrameModifier(row: row, session: session))
    }

    func sidebarDropTarget(session: SidebarDropSession,
                           commit: @escaping @MainActor @Sendable (SidebarDropPayload, SidebarDropTarget) -> Bool) -> some View {
        coordinateSpace(.named(SidebarDrop.spaceName))
            .onDrop(of: [.utf8PlainText, .plainText], delegate: SidebarDropDelegate(session: session, commit: commit))
            .overlay(alignment: .topLeading) {
                if case .insert(_, let group, let y, let indent) = session.visibleTarget,
                   group != .favorites {
                    SidebarDropIndicator(indent: indent).offset(y: y)
                }
            }
    }
}
