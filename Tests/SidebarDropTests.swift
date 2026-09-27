import XCTest
@testable import Cobble

@MainActor final class SidebarDropTests: XCTestCase {
    private let pin = UUID()
    private let folder = UUID()
    private let child1 = UUID()
    private let child2 = UUID()
    private let tab = UUID()
    private let otherFolder = UUID()

    func testClosedFolderHeaderNestsAndGapBelowStaysAtRoot() {
        let rows = [
            row(pin, .pin, 0),
            row(folder, .folderHeader(parentID: nil, depth: 0, collapsed: true), 40),
            row(tab, .tab, 80),
        ]
        XCTAssertEqual(SidebarDrop.hitTest(rows: rows, y: 55), .ontoFolder(folder))
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 75), before: tab, group: .tabs, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 20), before: folder, group: .rootPins, indent: false)
    }

    func testOpenFolderHeaderNestsAndEndGapInsertsInside() {
        let rows = [
            row(pin, .pin, 0),
            row(folder, .folderHeader(parentID: nil, depth: 0, collapsed: false), 40),
            row(child1, .folderChild(folderID: folder), 80),
            row(child2, .folderChild(folderID: folder), 120),
            row(SidebarDrop.pinsEndID, .pinsEnd, 155),
            row(tab, .tab, 190),
        ]
        XCTAssertEqual(SidebarDrop.hitTest(rows: rows, y: 55), .ontoFolder(folder))
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 145), before: nil, group: .folder(folder), indent: true)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 20), before: folder, group: .rootPins, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 75), before: child1, group: .folder(folder), indent: true)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 160), before: nil, group: .folder(folder), indent: true)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 175), before: tab, group: .tabs, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 210), before: nil, group: .tabs, indent: false)
    }

    func testGapAboveFolderInsertsAtRoot() {
        let rows = [
            row(folder, .folderHeader(parentID: nil, depth: 0, collapsed: false), 40),
            row(child1, .folderChild(folderID: folder), 80),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 10), before: folder, group: .rootPins, indent: false)
    }

    func testTabSlotsAreNotOntoFolder() {
        let rows = [
            row(folder, .folderHeader(parentID: nil, depth: 0, collapsed: true), 0),
            row(tab, .tab, 40),
        ]
        if case .ontoFolder = SidebarDrop.hitTest(rows: rows, y: 45) {
            XCTFail("tab section must not nest into a closed folder")
        }
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 45), before: tab, group: .tabs, indent: false)
    }

    func testEmptyFolderPlaceholderNests() {
        let rows = [
            row(folder, .folderHeader(parentID: nil, depth: 0, collapsed: false), 0),
            row(folder, .folderEmpty(folderID: folder), 40),
            row(SidebarDrop.pinsEndID, .pinsEnd, 80),
            row(tab, .tab, 120),
        ]
        XCTAssertEqual(SidebarDrop.hitTest(rows: rows, y: 50), .ontoFolder(folder))
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 70), before: nil, group: .folder(folder), indent: true)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 100), before: tab, group: .tabs, indent: false)
    }

    func testClosedFolderThenAnotherFolderDoesNotNestBelow() {
        let rows = [
            row(folder, .folderHeader(parentID: nil, depth: 0, collapsed: true), 0),
            row(otherFolder, .folderHeader(parentID: nil, depth: 0, collapsed: true), 40),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 35), before: otherFolder, group: .rootPins, indent: false)
        XCTAssertEqual(SidebarDrop.hitTest(rows: rows, y: 50), .ontoFolder(otherFolder))
    }

    func testGapAfterLastFavoriteInsertsAtEnd() {
        let favA = UUID()
        let favB = UUID()
        let rows = [
            row(favA, .favorite, 0),
            row(favB, .favorite, 40),
            row(SidebarDrop.favoritesEndID, .favoritesEnd, 80),
            row(pin, .pin, 120),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 45), before: favB, group: .favorites, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 75), before: nil, group: .favorites, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 90), before: nil, group: .favorites, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 125), before: pin, group: .rootPins, indent: false)
    }

    func testGapAfterLastFavoriteWithoutSentinelInsertsAtEnd() {
        let favA = UUID()
        let favB = UUID()
        let rows = [
            row(favA, .favorite, 0),
            row(favB, .favorite, 40),
            row(pin, .pin, 120),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 75), before: nil, group: .favorites, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 110), before: pin, group: .rootPins, indent: false)
    }

    func testEmptyFavoritesSectionAcceptsDropAboveSpace() {
        let rows = [
            row(SidebarDrop.favoritesEndID, .favoritesEnd, 0),
            row(pin, .pin, 40),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 10), before: nil, group: .favorites, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 50), before: pin, group: .rootPins, indent: false)
    }

    func testPinGridUsesColumnAwareInsertion() {
        let first = UUID(), second = UUID(), third = UUID()
        let rows = [
            SidebarDropRow(id: first, kind: .pinGrid, frame: CGRect(x: 0, y: 0, width: 70, height: 70)),
            SidebarDropRow(id: second, kind: .pinGrid, frame: CGRect(x: 76, y: 0, width: 70, height: 70)),
            SidebarDropRow(id: third, kind: .pinGrid, frame: CGRect(x: 0, y: 76, width: 70, height: 70)),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, x: 100, y: 20), before: second, group: .rootPins, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, x: 145, y: 20), before: third, group: .rootPins, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, x: 70, y: 110), before: nil, group: .rootPins, indent: false)
    }

    func testGlobalPinGridInsertsIntoFavorites() {
        let first = UUID(), second = UUID()
        let rows = [
            SidebarDropRow(id: SidebarDrop.favoritesEndID, kind: .favoritesEnd,
                           frame: CGRect(x: 0, y: 0, width: 146, height: 128)),
            SidebarDropRow(id: first, kind: .favorite, frame: CGRect(x: 0, y: 0, width: 70, height: 70)),
            SidebarDropRow(id: second, kind: .favorite, frame: CGRect(x: 76, y: 0, width: 70, height: 70)),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, x: 100, y: 20), before: second, group: .favorites, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, x: 70, y: 110), before: nil, group: .favorites, indent: false)
    }

    func testPinGridBalancesUpToFourColumns() {
        XCTAssertEqual((0...12).map { SidebarDrop.pinGridColumnCount($0) }, [1, 1, 2, 3, 2, 3, 3, 4, 4, 3, 4, 4, 4])
        XCTAssertEqual(SidebarDrop.pinGridColumnCount(8, fitting: 207), 3)
        XCTAssertEqual(SidebarDrop.pinGridColumnCount(8, fitting: 208), 4)
    }

    func testSpaceDividerSplitsPinsFromTabs() {
        let rows = [
            row(pin, .pin, 0),
            row(SidebarDrop.pinsEndID, .pinsEnd, 40),
            row(SidebarDrop.newTabID, .newTab, 80),
            row(tab, .tab, 120),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 20), before: nil, group: .rootPins, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 50), before: nil, group: .rootPins, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 60), before: tab, group: .tabs, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 90), before: tab, group: .tabs, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 140), before: nil, group: .tabs, indent: false)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 1_000), before: nil, group: .tabs, indent: false)
        assertInsert(
            SidebarDrop.hitTest(rows: [row(pin, .pin, 0), row(SidebarDrop.pinsEndID, .pinsEnd, 40)], y: 60),
            before: nil, group: .tabs, indent: false
        )
        for y in [60, 90] as [CGFloat] {
            guard case .insert(_, .tabs, let line, _) = SidebarDrop.hitTest(rows: rows, y: y) else {
                return XCTFail("expected tab insert at \(y)")
            }
            XCTAssertGreaterThanOrEqual(line, 110)
        }
    }

    func testEmptyTempSectionInsertsBelowNewTab() {
        let rows = [
            row(pin, .pin, 0),
            row(SidebarDrop.pinsEndID, .pinsEnd, 40),
            row(SidebarDrop.newTabID, .newTab, 80),
        ]
        guard case .insert(let before, .tabs, let y, false) = SidebarDrop.hitTest(rows: rows, y: 90) else {
            return XCTFail("expected tab insert below New Tab")
        }
        XCTAssertNil(before)
        XCTAssertEqual(y, 110)
    }

    func testSavedPayloadCanInsertAmongTabs() {
        let target = SidebarDropTarget.insert(before: tab, group: .tabs, y: 10, indent: false)
        XCTAssertTrue(SidebarDrop.allows(.saved(pin), target))
        XCTAssertTrue(SidebarDrop.allows(.tab(tab), target))
        XCTAssertTrue(SidebarDrop.allows(.saved(pin), .ontoFolder(folder)))
        XCTAssertTrue(SidebarDrop.allows(.saved(pin), .space(otherFolder)))
        XCTAssertTrue(SidebarDrop.allows(.tab(tab), .space(otherFolder)))
        XCTAssertTrue(SidebarDrop.allows(.folder(folder), .space(otherFolder)))
        XCTAssertTrue(SidebarDrop.allows(.folder(folder), .ontoFolder(otherFolder)))
        XCTAssertFalse(SidebarDrop.allows(.folder(folder), .ontoFolder(folder)))
        XCTAssertFalse(SidebarDrop.allows(.folder(folder), target))
        XCTAssertFalse(SidebarDrop.allows(.folder(folder), .insert(before: otherFolder, group: .rootPins, y: 0, indent: false)))
        XCTAssertTrue(SidebarDrop.allows(.folder(folder),
            .insert(before: otherFolder, group: .folders(parentID: nil), y: 0, indent: false)))
    }

    func testFolderDropOnAnotherFolderKeepsNestedTarget() {
        let session = SidebarDropSession()
        session.upsert(row(otherFolder, .folderHeader(parentID: nil, depth: 0, collapsed: true), 40))
        session.setPayload(.folder(folder), generation: session.generation)
        session.target = .ontoFolder(otherFolder)
        XCTAssertEqual(session.visibleTarget, .ontoFolder(otherFolder))
    }

    func testFolderDropOnDescendantDoesNotHighlight() {
        let root = UUID(), child = UUID(), grandchild = UUID()
        let session = SidebarDropSession()
        session.upsert(row(root, .folderHeader(parentID: nil, depth: 0, collapsed: false), 0))
        session.upsert(row(child, .folderHeader(parentID: root, depth: 1, collapsed: false), 40))
        session.upsert(row(grandchild, .folderHeader(parentID: child, depth: 2, collapsed: true), 80))
        session.setPayload(.folder(root), generation: session.generation)
        session.target = .ontoFolder(grandchild)
        XCTAssertNil(session.visibleTarget)
        XCTAssertNil(session.acceptedTarget)
        session.target = .insert(before: nil, group: .folders(parentID: grandchild), y: 100, indent: true)
        XCTAssertNil(session.visibleTarget)
        XCTAssertNil(session.acceptedTarget)
    }

    func testOpenEmptyFolderEndGapNestsWithoutPlaceholder() {
        let rows = [
            row(folder, .folderHeader(parentID: nil, depth: 0, collapsed: false), 0),
            row(SidebarDrop.pinsEndID, .pinsEnd, 40),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 35), before: nil, group: .folder(folder), indent: true)
    }

    func testNestedSiblingGapsKeepTheCommonParent() {
        let root = UUID()
        let childA = UUID()
        let childB = UUID()
        let siblingRoot = UUID()
        let rows = [
            row(root, .folderHeader(parentID: nil, depth: 0, collapsed: false), 0),
            row(childA, .folderHeader(parentID: root, depth: 1, collapsed: true), 40),
            row(childB, .folderHeader(parentID: root, depth: 1, collapsed: true), 80),
            row(siblingRoot, .folderHeader(parentID: nil, depth: 0, collapsed: true), 120),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 75), before: childB, group: .folder(root), indent: true)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 115), before: nil, group: .folder(root), indent: true)
        XCTAssertTrue(SidebarDrop.allows(.saved(pin), SidebarDrop.hitTest(rows: rows, y: 75)!))
        let folderTarget = SidebarDrop.hitTest(rows: rows, y: 75, payload: .folder(childA))
        assertInsert(folderTarget, before: childB, group: .folders(parentID: root), indent: true)
        XCTAssertTrue(SidebarDrop.allows(.folder(childA), folderTarget!))
    }

    func testFolderDragUsesFolderSiblingBoundariesInsteadOfPinRows() {
        let first = UUID(), second = UUID()
        let rows = [
            row(pin, .pin, 0),
            row(first, .folderHeader(parentID: nil, depth: 0, collapsed: true), 40),
            row(second, .folderHeader(parentID: nil, depth: 0, collapsed: true), 80),
            row(SidebarDrop.pinsEndID, .pinsEnd, 120),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 15, payload: .folder(second)),
                     before: first, group: .folders(parentID: nil), indent: false)
        XCTAssertEqual(SidebarDrop.hitTest(rows: rows, y: 55, payload: .folder(second)), .ontoFolder(first))
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 68, payload: .folder(second)),
                     before: nil, group: .folders(parentID: nil), indent: false)
    }

    func testItemAtTopOfFolderStaysInPinGroupWithAlignedIndicator() {
        let rows = [
            row(pin, .pin, 0),
            row(folder, .folderHeader(parentID: nil, depth: 0, collapsed: true), 40),
            row(SidebarDrop.pinsEndID, .pinsEnd, 80),
        ]
        guard case .insert(let before, .rootPins, let y, false) =
                SidebarDrop.hitTest(rows: rows, y: 42, payload: .saved(pin)) else {
            return XCTFail("expected a root-pin insertion above the folder")
        }
        XCTAssertEqual(before, folder)
        XCTAssertEqual(y, 40)
    }

    func testNestedHeaderTargetsItsParentBeforeTheSubtree() {
        let root = UUID()
        let child = UUID()
        let pin = UUID()
        let rows = [
            row(root, .folderHeader(parentID: nil, depth: 0, collapsed: false), 0),
            row(pin, .folderChild(folderID: root), 40),
            row(child, .folderHeader(parentID: root, depth: 1, collapsed: false), 80),
            row(SidebarDrop.pinsEndID, .pinsEnd, 120),
        ]
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 75), before: child, group: .folder(root), indent: true)
        assertInsert(SidebarDrop.hitTest(rows: rows, y: 115), before: nil, group: .folder(child), indent: true)
    }

    func testParsePayloadPrefixes() {
        XCTAssertEqual(SidebarDrop.parse("saved:\(pin.uuidString)"), .saved(pin))
        XCTAssertEqual(SidebarDrop.parse("tab:\(tab.uuidString)"), .tab(tab))
        XCTAssertEqual(SidebarDrop.parse("folder:\(folder.uuidString)"), .folder(folder))
        XCTAssertEqual(SidebarDrop.parse("space:\(folder.uuidString)"), .space(folder))
    }

    func testSpacePickerInsertAndOffsetOpenAGap() {
        let a = UUID(), b = UUID(), c = UUID()
        let ids = [a, b, c]
        let widths: [UUID: CGFloat] = [a: 40, b: 40, c: 80]
        XCTAssertEqual(SidebarDrop.spaceInsert(ids: ids, widths: widths, excluding: b, x: 10), .spaceInsert(before: a))
        XCTAssertEqual(SidebarDrop.spaceInsert(ids: ids, widths: widths, excluding: b, x: 70), .spaceInsert(before: c))
        XCTAssertEqual(SidebarDrop.spaceInsert(ids: ids, widths: widths, excluding: b, x: 140), .spaceInsert(before: nil))
        XCTAssertEqual(SidebarDrop.spaceAt(ids: ids, widths: widths, x: 50), b)
        XCTAssertEqual(SidebarDrop.spaceAt(ids: ids, widths: widths, x: 40, spacing: -1), b)
        XCTAssertEqual(SidebarDrop.spaceAt(ids: ids, widths: widths, x: 200), c)
        XCTAssertEqual(SidebarDrop.spacePickerOffset(for: c, ids: ids, dragged: b, before: nil, gap: 45), -45)
        XCTAssertEqual(SidebarDrop.spacePickerOffset(for: a, ids: ids, dragged: c, before: a, gap: 85), 85)
        XCTAssertEqual(SidebarDrop.spacePickerOffset(for: c, ids: ids, dragged: b, before: c, gap: 45), 0)
        XCTAssertFalse(SidebarDrop.allows(.space(a), .space(b)))
        XCTAssertTrue(SidebarDrop.allows(.space(a), .spaceInsert(before: b)))
        XCTAssertFalse(SidebarDrop.allows(.tab(tab), .spaceInsert(before: a)))
        XCTAssertFalse(SidebarDrop.allows(.space(a), .insert(before: tab, group: .tabs, y: 0, indent: false)))
    }

    func testStalePayloadDoesNotStickAfterClear() {
        let session = SidebarDropSession()
        let generation = session.generation
        session.clear()
        session.setPayload(.tab(tab), generation: generation)
        XCTAssertNil(session.payload)
        XCTAssertNil(session.draggedID)
        XCTAssertNil(session.visibleTarget)
    }

    func testMouseUpHidesDragChromeBeforePayloadClears() {
        let session = SidebarDropSession()
        session.setPayload(.tab(tab), generation: session.generation)
        session.target = .ontoFolder(folder)
        XCTAssertEqual(session.draggedID, tab)
        XCTAssertNotNil(session.visibleTarget)
        session.hideChrome()
        XCTAssertNil(session.draggedID)
        XCTAssertNil(session.visibleTarget)
        XCTAssertEqual(session.acceptedTarget, .ontoFolder(folder))
        XCTAssertEqual(session.payload, .tab(tab))
        session.setPayload(.saved(pin), generation: session.generation)
        XCTAssertEqual(session.payload, .tab(tab))
        session.showGhost(id: pin, title: "Pin", icon: nil, empty: false, environment: .init())
        XCTAssertNil(session.draggedID)
    }

    func testPreviewTimerKeepsDropTargetAfterMouseRelease() async throws {
        let session = SidebarDropSession()
        session.setPayload(.tab(tab), generation: session.generation)
        session.target = .insert(before: nil, group: .tabs, y: 40, indent: false)
        session.followCursor()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.payload, .tab(tab))
        XCTAssertNotNil(session.acceptedTarget)
    }

    func testDragPreviewProvidesPayloadBeforeProviderLoads() {
        let session = SidebarDropSession()
        session.showGhost(id: tab, payload: .tab(tab), title: "Tab", icon: nil, empty: false, environment: .init())
        XCTAssertEqual(session.payload, .tab(tab))
        XCTAssertEqual(session.draggedID, tab)
    }

    func testSpaceChangeKeepsGlobalPinDropFrames() {
        let session = SidebarDropSession()
        let favorite = UUID()
        session.rows = [
            row(favorite, .favorite, 0),
            row(SidebarDrop.favoritesEndID, .favoritesEnd, 40),
            row(pin, .pin, 80),
            row(tab, .tab, 120),
        ]
        session.resetSpaceRows()
        XCTAssertEqual(session.rows.map(\.kind), [.favorite, .favoritesEnd])
    }

    func testOldViewCannotRemoveReplacementDropFrame() {
        let session = SidebarDropSession()
        let old = UUID(), replacement = UUID()
        session.upsert(row(tab, .tab, 10), registration: old)
        session.upsert(row(tab, .tab, 20), registration: replacement)
        session.remove(id: tab, slot: .tab, registration: old)
        XCTAssertEqual(session.rows.first?.frame.minY, 20)
        session.remove(id: tab, slot: .tab, registration: replacement)
        XCTAssertTrue(session.rows.isEmpty)
    }

    func testEmptyFavoritesExpandOnlyInsideActivationAreaAndStayExpanded() {
        let session = SidebarDropSession()
        session.upsert(SidebarDropRow(id: SidebarDrop.favoritesEndID, kind: .favoritesEnd,
                                      frame: CGRect(x: 0, y: 20, width: 200, height: 0)))
        session.favoritesActivationMaxY = 60
        session.setPayload(.tab(tab), generation: session.generation)

        XCTAssertNil(session.emptyFavoritesTarget(at: 100))
        XCTAssertFalse(session.emptyFavoritesExpanded)
        assertInsert(session.emptyFavoritesTarget(at: 40), before: nil, group: .favorites, indent: false)
        XCTAssertTrue(session.emptyFavoritesExpanded)
        XCTAssertNil(session.emptyFavoritesTarget(at: 100))
        XCTAssertTrue(session.emptyFavoritesExpanded)
    }

    private func row(_ id: UUID, _ kind: SidebarDropKind, _ y: CGFloat) -> SidebarDropRow {
        SidebarDropRow(id: id, kind: kind, frame: CGRect(x: 0, y: y, width: 200, height: 30))
    }

    private func assertInsert(_ target: SidebarDropTarget?, before: UUID?, group: SidebarDropGroup, indent: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard case .insert(let gotBefore, let gotGroup, _, let gotIndent) = target else {
            return XCTFail("expected insert, got \(String(describing: target))", file: file, line: line)
        }
        XCTAssertEqual(gotBefore, before, file: file, line: line)
        XCTAssertEqual(gotGroup, group, file: file, line: line)
        XCTAssertEqual(gotIndent, indent, file: file, line: line)
    }
}
