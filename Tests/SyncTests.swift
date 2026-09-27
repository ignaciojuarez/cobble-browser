import XCTest
import WebKit
@testable import Cobble

final class SyncTests: XCTestCase {
    private func item(_ title: String = "One") -> SyncItem {
        SyncItem(id: "saved.test", module: .organization, kind: "saved", fields: ["title": title, "rank": "0"])
    }
    func testConcurrentFieldsMergeAndOrderingIsDeterministic() throws {
        var a = SyncState(), b = SyncState()
        a.deviceID = "a"; b.deviceID = "b"
        try a.capture([item()], module: .organization, seed: true)
        try b.merge(XCTUnwrap(a.records["saved.test"]))
        b.baseline = a.baseline
        try a.capture([item("Renamed")], module: .organization)
        var moved = item(); moved.fields["rank"] = "4"
        try b.capture([moved], module: .organization)
        let left = try XCTUnwrap(a.records["saved.test"]), right = try XCTUnwrap(b.records["saved.test"])
        let merged = try left.merged(with: right)
        XCTAssertEqual(merged, try right.merged(with: left))
        XCTAssertEqual(merged.item?.fields["title"], "Renamed")
        XCTAssertEqual(merged.item?.fields["rank"], "4")
        XCTAssertEqual(merged, try merged.merged(with: merged))
    }
    func testDeleteWinsOfflineEditButObservedRecreationWorks() throws {
        var a = SyncState(), b = SyncState()
        a.deviceID = "a"; b.deviceID = "b"
        try a.capture([item()], module: .organization, seed: true)
        try b.merge(XCTUnwrap(a.records["saved.test"]))
        b.baseline = a.baseline
        try a.capture([], module: .organization)
        try b.capture([item("Offline")], module: .organization)
        try b.merge(XCTUnwrap(a.records["saved.test"]))
        XCTAssertNil(b.records["saved.test"]?.item)
        b.baseline = [:] // Application acknowledged the deletion.
        try b.capture([item("Recreated")], module: .organization)
        XCTAssertEqual(b.records["saved.test"]?.item?.fields["title"], "Recreated")
        try a.merge(XCTUnwrap(b.records["saved.test"]))
        XCTAssertEqual(a.records["saved.test"], b.records["saved.test"])
    }
    func testUnknownFieldsSurviveLocalEditsAndFutureVersionRefusesMerge() throws {
        var state = SyncState()
        try state.capture([item()], module: .organization, seed: true)
        state.records["saved.test"]?.fields["future"] = SyncField(value: "keep", stamp: SyncStamp(counter: 0, deviceID: "future"))
        try state.capture([item("Edited")], module: .organization)
        XCTAssertEqual(state.records["saved.test"]?.item?.fields["future"], "keep")
        var newer = try XCTUnwrap(state.records["saved.test"])
        newer.version = 2
        XCTAssertThrowsError(try state.merge(newer))
    }
    func testMergedRecordRejectsOversizedUnion() throws {
        let stamp = SyncStamp(counter: 1, deviceID: "a")
        let first = SyncRecord(id: "saved.test", module: .organization, kind: "saved",
                               fields: Dictionary(uniqueKeysWithValues: (0..<60).map {
                                   ("a\($0)", SyncField(value: "x", stamp: stamp))
                               }))
        let second = SyncRecord(id: "saved.test", module: .organization, kind: "saved",
                                fields: Dictionary(uniqueKeysWithValues: (0..<60).map {
                                    ("b\($0)", SyncField(value: "y", stamp: stamp))
                                }))
        XCTAssertNoThrow(try first.validated())
        XCTAssertNoThrow(try second.validated())
        XCTAssertThrowsError(try first.merged(with: second))
    }
    func testHistoryRetentionDoesNotPublishDeletion() throws {
        var state = SyncState()
        let history = SyncItem(id: "history.test", module: .history, kind: "history", fields: ["url": "https://example.com"])
        try state.capture([history], module: .history, seed: true)
        try state.capture([], module: .history)
        XCTAssertNotNil(state.records[history.id]?.item)
        try state.delete([history.id])
        XCTAssertNil(state.records[history.id]?.item)
    }
    func testFailedApplyDoesNotPublishPartialTabClosures() throws {
        var state = SyncState()
        let first = SyncItem(id: "tab.first", module: .openTabs, kind: "tab", fields: ["url": "https://one.example/"])
        let second = SyncItem(id: "tab.second", module: .openTabs, kind: "tab", fields: ["url": "https://two.example/"])
        try state.capture([first, second], module: .openTabs, seed: true)
        state.pending.removeAll()
        try state.capture([second], module: .openTabs, allowDeletions: false)
        XCTAssertNotNil(state.records[first.id]?.item)
        XCTAssertFalse(state.pending.contains(first.id))
    }
    func testUnavailableEngineDoesNotDeleteItsBlockerConfiguration() throws {
        var state = SyncState()
        let webKit = SyncItem(id: "blocker:web", module: .contentBlockers, kind: "configuration",
                              fields: ["engineID": "webkit"])
        let chromium = SyncItem(id: "blocker:chrome", module: .contentBlockers, kind: "configuration",
                                fields: ["engineID": "chromium"])
        try state.capture([webKit, chromium], module: .contentBlockers, seed: true)
        state.pending.removeAll()
        try state.capture([], module: .contentBlockers, retainAbsent: [chromium.id])
        XCTAssertNil(state.records[webKit.id]?.item)
        XCTAssertNotNil(state.records[chromium.id]?.item)
        XCTAssertEqual(state.baseline[chromium.id], chromium)
    }
    func testNewDeviceSeedsOnlyItemsMissingFromCloud() throws {
        var state = SyncState()
        let remote = SyncRecord(id: "saved.test", module: .organization, kind: "saved", fields: [
            "title": SyncField(value: "Remote", stamp: SyncStamp(counter: 10, deviceID: "remote"))])
        try state.merge(remote)
        try state.capture([item("Local")], module: .organization, seed: true)
        XCTAssertEqual(state.records["saved.test"]?.item?.fields["title"], "Remote")
        XCTAssertTrue(state.pending.isEmpty)
    }
    func testFailedCaptureLeavesJournalUnchanged() throws {
        var state = SyncState()
        let before = state
        let invalid = SyncItem(id: "saved.invalid", module: .organization, kind: "saved",
                               fields: ["title": String(repeating: "x", count: 100_001)])
        XCTAssertThrowsError(try state.capture([item(), invalid], module: .organization))
        XCTAssertEqual(state.counter, before.counter)
        XCTAssertEqual(state.records, before.records)
        XCTAssertEqual(state.baseline, before.baseline)
        XCTAssertEqual(state.pending, before.pending)
    }
    func testRejectedMergeDoesNotAdvanceLocalClock() throws {
        var state = SyncState()
        try state.capture([item()], module: .organization, seed: true)
        let previous = state.counter
        let conflicting = SyncRecord(id: "saved.test", module: .organization, kind: "folder",
                                     fields: ["name": SyncField(value: "Wrong kind", stamp: SyncStamp(counter: 100, deviceID: "remote"))])
        XCTAssertThrowsError(try state.merge(conflicting))
        XCTAssertEqual(state.counter, previous)
    }

    @MainActor func testCoordinatorSyncsTwoClientsAndKeepsDeviceSettingsLocal() async throws {
        let server = MemorySyncServer()
        let first = makeApp(), second = makeApp()
        defer { cleanup(first); cleanup(second) }
        first.preferences.setDefaultEngine(EngineID(rawValue: "chromium"))
        let a = SyncCoordinator(app: first, provider: MemorySyncProvider(server: server))
        let b = SyncCoordinator(app: second, provider: MemorySyncProvider(server: server))
        first.spaces[0].name = "Work"
        a.setEnabled(true); await a.syncNow()
        b.setEnabled(true); await b.syncNow()
        XCTAssertNil(a.errorMessage); XCTAssertNil(b.errorMessage)
        XCTAssertEqual(second.spaces[0].name, "Work")
        XCTAssertEqual(second.preferences.defaultEngine, .webKit)
        let folder = Folder(name: "Research")
        first.folders.append(folder)
        await a.syncNow(); await b.syncNow()
        XCTAssertEqual(second.folders.map(\.id), [folder.id])
        first.folders.removeAll()
        await a.syncNow(); await b.syncNow()
        XCTAssertTrue(second.folders.isEmpty)
    }
    @MainActor func testAccountSwitchPausesBeforeTransferringLocalData() async throws {
        let server = MemorySyncServer(), app = makeApp()
        defer { cleanup(app) }
        let provider = MemorySyncProvider(server: server)
        let sync = SyncCoordinator(app: app, provider: provider)
        sync.setEnabled(true); await sync.syncNow()
        let writes = server.writes
        provider.account = "another-account"
        app.spaces[0].name = "Should stay local"
        await sync.syncNow()
        XCTAssertFalse(sync.enabled)
        XCTAssertNotNil(sync.errorMessage)
        XCTAssertEqual(server.writes, writes)
    }
    @MainActor func testDisabledCategoriesAreNeverFetched() async throws {
        let server = MemorySyncServer(), app = makeApp()
        defer { cleanup(app) }
        let sync = SyncCoordinator(app: app, provider: MemorySyncProvider(server: server))
        sync.setEnabled(true); await sync.syncNow()
        XCTAssertEqual(Set(server.fetched), [.organization, .bookmarks])
        sync.setModule(.organization, enabled: false)
        XCTAssertFalse(sync.modules.contains(.bookmarks))
        await sync.syncNow()
        XCTAssertTrue(app.profiles.contains { $0.id == Profile.defaultID })
    }
    @MainActor func testOrganizationKeepsLocalOnlyPinsAndRepairsConcurrentOrphans() async throws {
        let app = makeApp()
        defer { cleanup(app) }
        let localOnly = SavedItem(title: "Local draft")
        app.savedItems = [localOnly]
        var items = app.organizationSyncItems()
        let missingSpace = UUID(), folderID = UUID(), pinID = UUID()
        items.append(SyncItem(id: "folder.\(folderID)", module: .organization, kind: "folder", fields: [
            "uuid": folderID.uuidString, "spaceID": missingSpace.uuidString,
            "profileID": Profile.defaultID.uuidString, "parentID": "", "name": "Concurrent folder", "color": "blue", "rank": "0"]))
        items.append(SyncItem(id: "saved.\(pinID)", module: .organization, kind: "saved", fields: [
            "uuid": pinID.uuidString, "profileID": Profile.defaultID.uuidString,
            "spaceID": missingSpace.uuidString, "folderID": folderID.uuidString,
            "url": "https://example.com", "title": "Concurrent pin", "rank": "0"]))
        try await app.applySyncItems(items, module: .organization)
        XCTAssertTrue(app.savedItems.contains { $0.id == localOnly.id })
        XCTAssertEqual(app.savedItems.first { $0.id == pinID }?.spaceID, Space.defaultID)
        XCTAssertEqual(app.folders.first?.spaceID, Space.defaultID)
    }

    @MainActor func testConcurrentFolderCycleIsBrokenDeterministically() async throws {
        let app = makeApp()
        defer { cleanup(app) }
        let first = UUID(), second = UUID()
        app.folders = [Folder(id: first, parentID: second), Folder(id: second, parentID: first)]
        let items = app.organizationSyncItems()
        try await app.applySyncItems(items, module: .organization)
        let smallest = [first, second].min { $0.uuidString < $1.uuidString }!
        XCTAssertNil(app.folders.first { $0.id == smallest }?.parentID)
        XCTAssertEqual(app.folders.count, 2)
    }

    @MainActor func testOfflineOutboxSurvivesRestartAndRetries() async throws {
        let server = MemorySyncServer(), app = makeApp()
        defer { cleanup(app) }
        let provider = MemorySyncProvider(server: server)
        let sync = SyncCoordinator(app: app, provider: provider)
        sync.setEnabled(true); await sync.syncNow()
        app.spaces[0].name = "Offline work"
        provider.failSaves = true
        await sync.syncNow()
        XCTAssertNotNil(sync.errorMessage)
        let journal = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf:
            app.store.directory.appendingPathComponent("sync-state.json")))
        XCTAssertFalse(journal.pending.isEmpty)
        provider.failSaves = false
        let restarted = SyncCoordinator(app: app, provider: provider)
        await restarted.syncNow()
        XCTAssertNil(restarted.errorMessage)
        XCTAssertEqual(server.records["space.\(Space.defaultID)"]?.item?.fields["name"], "Offline work")
    }

    @MainActor func testJournalWriteFailureStopsUploads() async throws {
        let server = MemorySyncServer(), app = makeApp()
        defer { cleanup(app) }
        let sync = SyncCoordinator(app: app, provider: MemorySyncProvider(server: server))
        sync.setEnabled(true); await sync.syncNow()
        let writes = server.writes
        let journal = app.store.directory.appendingPathComponent("sync-state.json")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        app.spaces[0].name = "Unjournaled edit"
        await sync.syncNow()
        XCTAssertFalse(sync.enabled)
        XCTAssertNotNil(sync.errorMessage)
        XCTAssertEqual(server.writes, writes)
    }

    @MainActor func testStopBlocksQueuedSync() async throws {
        let server = MemorySyncServer(), app = makeApp()
        defer { cleanup(app) }
        let sync = SyncCoordinator(app: app, provider: MemorySyncProvider(server: server))
        sync.setEnabled(true); await sync.syncNow()
        let writes = server.writes
        app.spaces[0].name = "After stop"
        let queued = Task { await sync.syncNow() }
        sync.stop()
        await queued.value
        XCTAssertEqual(server.writes, writes)
    }

    @MainActor func testFailedTabApplyKeepsConcurrentUserClosureDeleted() async throws {
        let server = MemorySyncServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        defer { cleanup(app) }
        let window = app.windows[0]
        window.addTab(url: URL(string: "https://user.example/")!)
        let userTab = try XCTUnwrap(window.selectedTab)
        window.addTab(url: URL(string: "https://remote.example/")!)
        let remoteTab = try XCTUnwrap(window.selectedTab)
        let page = try XCTUnwrap(window.selectedPage as? TestPage)
        let sync = SyncCoordinator(app: app, provider: MemorySyncProvider(server: server))
        sync.setModule(.openTabs, enabled: true)
        sync.setEnabled(true); await sync.syncNow()
        let remoteID = "tab.\(remoteTab.id.uuidString.lowercased())"
        let userID = "tab.\(userTab.id.uuidString.lowercased())"
        var removed = try XCTUnwrap(server.records[remoteID])
        removed.tombstone = SyncStamp(counter: 100, deviceID: "remote")
        server.records[remoteID] = removed
        page.capabilities.requiresCloseConfirmation = true
        page.delayCloseRequest = true
        let applying = Task { await sync.syncNow() }
        for _ in 0..<200 where page.closeRequest == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(page.closeRequest)
        window.closeTab(userTab.id)
        page.finishCloseRequest(accepted: false)
        await applying.value
        let journal = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf:
            app.store.directory.appendingPathComponent("sync-state.json")))
        XCTAssertTrue(journal.records[userID]?.isDeleted == true)
        XCTAssertTrue(journal.pending.contains(userID))
        page.delayCloseRequest = false
        page.closeRequestResult = true
        await sync.syncNow()
        XCTAssertFalse(window.record.tabs.contains { $0.id == userTab.id })
        XCTAssertTrue(server.records[userID]?.isDeleted == true)
    }

    @MainActor func testRemoteBlockerDeletionPausesWhenRulesRemainInstalled() async throws {
        let server = MemorySyncServer(), app = makeApp()
        defer { cleanup(app) }
        let blocker = try XCTUnwrap(app.engines.engine(.webKit)?.contentBlocker)
        await blocker.useBundledRules(profileID: Profile.defaultID)
        XCTAssertTrue(blocker.hasRules(profileID: Profile.defaultID))
        let stamp = SyncStamp(counter: 1, deviceID: "remote")
        let id = "blocker:\(Profile.defaultID.uuidString):webkit"
        server.records[id] = SyncRecord(id: id, module: .contentBlockers, kind: "configuration",
                                        fields: ["profileID": SyncField(value: Profile.defaultID.uuidString, stamp: stamp),
                                                 "engineID": SyncField(value: "webkit", stamp: stamp)],
                                        tombstone: SyncStamp(counter: 2, deviceID: "remote"))
        let sync = SyncCoordinator(app: app, provider: MemorySyncProvider(server: server))
        sync.setModule(.contentBlockers, enabled: true)
        sync.setEnabled(true); await sync.syncNow()
        XCTAssertTrue(blocker.hasRules(profileID: Profile.defaultID))
        XCTAssertNotNil(sync.errorMessage)
        XCTAssertTrue(server.records[id]?.isDeleted == true)
        let journal = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf:
            app.store.directory.appendingPathComponent("sync-state.json")))
        XCTAssertFalse(journal.initialized.contains(.contentBlockers))
    }

    func testPostApplyCaptureJournalsNewLocalItemWithoutEchoingRemoteEdits() throws {
        var state = SyncState()
        try state.capture([item()], module: .organization, seed: true)
        state.pending.removeAll()
        var remote = try XCTUnwrap(state.records["saved.test"])
        remote.fields["title"] = SyncField(value: "Remote change", stamp: SyncStamp(counter: 50, deviceID: "remote"))
        try state.merge(remote)
        var added = item("Opened while applying")
        added.id = "saved.new"
        try state.capture([item("Remote change"), added], module: .organization)
        XCTAssertEqual(state.pending, ["saved.new"])
        XCTAssertEqual(state.records["saved.test"], remote)
        XCTAssertEqual(state.records["saved.new"]?.item?.fields["title"], "Opened while applying")
    }

    @MainActor func testRejoiningMergesOfflineEditsWithoutDeletingCloudItems() async throws {
        let server = MemorySyncServer(), app = makeApp()
        defer { cleanup(app) }
        let sync = SyncCoordinator(app: app, provider: MemorySyncProvider(server: server))
        let folder = Folder(name: "Keep in cloud")
        app.folders = [folder]
        sync.setEnabled(true); await sync.syncNow()
        sync.setModule(.organization, enabled: false)
        app.spaces[0].name = "Edited while off"
        app.folders.removeAll()
        sync.setModule(.organization, enabled: true)
        await sync.syncNow()
        XCTAssertNil(sync.errorMessage)
        XCTAssertEqual(app.spaces[0].name, "Edited while off")
        XCTAssertEqual(app.folders.map(\.id), [folder.id])
        XCTAssertEqual(server.records["space.\(Space.defaultID)"]?.item?.fields["name"], "Edited while off")
    }

    @MainActor private func makeApp() -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return AppModel(store: SessionStore(directory: directory),
                        engines: EngineRegistry([WebKitEngine(directory: directory, dataStoreOverride: .nonPersistent())]))
    }
    @MainActor private func cleanup(_ app: AppModel) {
        app.sync.stop(); app.windows.forEach { $0.closePages() }; app.library.close()
        try? FileManager.default.removeItem(at: app.store.directory)
    }
}

@MainActor private final class MemorySyncServer {
    var records: [String: SyncRecord] = [:]
    var fetched: [SyncModule] = []
    var writes = 0
}
@MainActor private final class MemorySyncProvider: SyncProvider {
    let name = "Memory"
    var account = "test-account"
    var failSaves = false
    let server: MemorySyncServer
    init(server: MemorySyncServer) { self.server = server }
    func accountID() async throws -> String { account }
    func fetchChanges(module: SyncModule, cursor: Data?, expectedAccountID: String) async throws -> SyncBatch {
        guard account == expectedAccountID else { throw SyncFailure.invalidRecord }
        server.fetched.append(module)
        return SyncBatch(records: server.records.values.filter { $0.module == module }, cursor: nil)
    }
    func save(_ records: [SyncRecord], module: SyncModule, expectedAccountID: String) async throws -> [SyncRecord] {
        guard account == expectedAccountID else { throw SyncFailure.invalidRecord }
        if failSaves { throw SyncFailure.unavailable("Offline") }
        server.writes += records.count
        return try records.map { record in
            let merged = try server.records[record.id].map { try $0.merged(with: record) } ?? record
            server.records[record.id] = merged
            return merged
        }
    }
}
