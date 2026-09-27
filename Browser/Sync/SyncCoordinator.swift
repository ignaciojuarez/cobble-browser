import Foundation
import Observation

@MainActor @Observable
final class SyncCoordinator {
    private(set) var enabled = false
    private(set) var modules: Set<SyncModule> = [.organization, .bookmarks]
    private(set) var isSyncing = false
    private(set) var status = String(localized: "Sync is off")
    private(set) var errorMessage: String?
    private(set) var lastSync: Date?
    var deviceID: String { state.deviceID }
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let provider: any SyncProvider
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var state = SyncState()
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeRun: Task<Void, Never>?
    @ObservationIgnored private var runGeneration = -1
    @ObservationIgnored private var stopped = false

    init(app: AppModel, provider: any SyncProvider) {
        self.app = app
        self.provider = provider
        url = app.store.directory.appendingPathComponent("sync-state.json")
        do {
            guard app.store.allowsSaving else { throw SyncFailure.invalidRecord }
            if FileManager.default.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
                guard state.version == 1, !state.deviceID.isEmpty, state.deviceID.utf8.count <= 200,
                      state.counter >= 0, state.counter < Int64.max - 1,
                      state.pending.isSubset(of: Set(state.records.keys)),
                      state.baseline.allSatisfy({ $0.key == $0.value.id }) else {
                    throw SyncFailure.invalidRecord
                }
                for (id, record) in state.records {
                    guard id == record.id, record.counter <= state.counter else { throw SyncFailure.invalidRecord }
                    _ = try record.validated()
                }
            }
            enabled = state.enabled; modules = state.modules; lastSync = state.lastSync
        } catch {
            writable = false
            errorMessage = String(localized: "Sync data could not be read. The original file has been preserved.")
        }
        app.library.onSyncHistoryDeletion = { [weak self] items in
            if let self { try self.deleteHistory(items) }
        }
    }

    /// Started explicitly by the application, never by an isolated AppModel fixture.
    func start() {
        guard worker == nil else { return }
        stopped = false
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    func stop() {
        stopped = true
        worker?.cancel(); worker = nil
        activeRun?.cancel(); generation += 1
    }

    func setEnabled(_ value: Bool) {
        guard writable else { return }
        let previous = state
        activeRun?.cancel()
        generation += 1
        if value, state.accountChanged {
            var fresh = SyncState()
            fresh.deviceID = state.deviceID; fresh.modules = state.modules
            state = fresh
        }
        if !value { state.resuming.formUnion(state.initialized) }
        state.enabled = value
        do {
            try saveState()
            enabled = value
            errorMessage = nil
            status = value ? String(localized: "Ready to sync") : String(localized: "Sync is off")
            if value { Task { await syncNow() } }
        } catch { state = previous; errorMessage = error.localizedDescription }
    }
    func setModule(_ module: SyncModule, enabled value: Bool) {
        guard writable else { return }
        let previous = state
        activeRun?.cancel()
        generation += 1
        if value {
            state.modules.insert(module)
            if module.requiresOrganization { state.modules.insert(.organization) }
        } else {
            state.modules.remove(module)
            if module == .organization { state.modules = state.modules.filter { !$0.requiresOrganization } }
        }
        let changed = state.modules.symmetricDifference(previous.modules)
        for module in changed {
            // Keep the opt-out baseline so local edits can merge on rejoin, without publishing deletions.
            if state.initialized.contains(module) { state.resuming.insert(module) }
            state.cursors.removeValue(forKey: module)
        }
        do {
            try saveState(); modules = state.modules
            if enabled { Task { await syncNow() } }
        } catch { state = previous; errorMessage = error.localizedDescription }
    }

    private func saveState() throws {
        guard writable else { throw SyncFailure.localWrite(String(localized: "Sync storage is unavailable.")) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        }
        catch {
            // Never send a revision that cannot survive process restart.
            writable = false
            enabled = false
            throw SyncFailure.localWrite(error.localizedDescription)
        }
    }
    private func deleteHistory(_ items: [SyncItem]) throws {
        guard enabled, modules.contains(.history), writable else { return }
        let previous = state
        do { try state.delete(items.map(\.id)); try saveState() }
        catch {
            state = previous
            errorMessage = error.localizedDescription
            throw error
        }
    }
    private func capture(_ app: AppModel, module: SyncModule, seed: Bool = false,
                         allowDeletions: Bool = true) throws {
        var retained: Set<String> = []
        if module == .contentBlockers {
            let available = Set(app.engines.engines.compactMap { engine in
                engine.contentBlocker == nil ? nil : engine.id.rawValue
            })
            retained = Set(state.baseline.values.filter {
                $0.module == module && $0.fields["engineID"].map { !available.contains($0) } == true
            }.map(\.id))
        }
        try state.capture(app.syncItems(module: module), module: module, seed: seed,
                          allowDeletions: allowDeletions, retainAbsent: retained)
    }
    private func apply(_ records: [SyncRecord], module: SyncModule, to app: AppModel) async throws {
        if module == .contentBlockers {
            for record in records where record.isDeleted {
                guard record.kind == "configuration",
                      let rawProfile = record.fields["profileID"]?.value,
                      let profile = UUID(uuidString: rawProfile),
                      let engine = record.fields["engineID"]?.value,
                      record.id == "blocker:\(profile.uuidString):\(engine)" else {
                    throw SyncFailure.invalidRecord
                }
                if app.profiles.contains(where: { $0.id == profile }),
                   app.engines.engine(EngineID(rawValue: engine))?.contentBlocker?.hasRules(profileID: profile) == true {
                    throw SyncFailure.unavailable(String(localized: "Content blocker sync is paused because rules removed on another device are still installed on this Mac."))
                }
            }
        }
        try await app.applySyncItems(records.compactMap(\.item), module: module)
    }
    func captureLocalChanges() {
        guard enabled, writable, !isSyncing, let app else { return }
        do {
            for module in SyncModule.allCases where modules.contains(module) && state.initialized.contains(module) {
                try capture(app, module: module, allowDeletions: !state.resuming.contains(module))
            }
            try saveState()
        } catch { errorMessage = error.localizedDescription }
    }

    func syncNow() async {
        guard !stopped else { return }
        let requested = generation
        if let activeRun {
            await activeRun.value
            guard !stopped, enabled, generation == requested, runGeneration != requested else { return }
        }
        guard !stopped, enabled, writable else { return }
        let run = Task { [weak self] in
            guard let self else { return }
            await self.performSync()
        }
        activeRun = run
        runGeneration = requested
        await run.value
        if runGeneration == requested { activeRun = nil }
    }

    private func performSync() async {
        guard !stopped, enabled, writable, !isSyncing, let app,
              retryAfter.map({ $0 <= Date() }) ?? true else { return }
        isSyncing = true
        status = String(localized: "Syncing…")
        defer { isSyncing = false }
        let run = generation
        do {
            let account = try await provider.accountID()
            guard enabled, generation == run, !Task.isCancelled else { return }
            if let previous = state.accountID, previous != account {
                state.enabled = false; state.accountChanged = true
                try saveState(); enabled = false
                throw SyncFailure.unavailable(String(localized: "Your iCloud account changed. Sync is paused. Turning sync on again uploads local-only items and uses the new account’s cloud values for matching items."))
            }
            state.accountID = account
            try saveState()
            var failures: [String] = []
            var organizationReady = false
            for module in SyncModule.allCases where modules.contains(module) {
                if module.requiresOrganization && !organizationReady { continue }
                var applying = false
                do {
                    guard enabled, generation == run, !Task.isCancelled else { return }
                    let initialized = state.initialized.contains(module)
                    if initialized {
                        try capture(app, module: module, allowDeletions: !state.resuming.contains(module))
                        try saveState()
                    }
                    let batch = try await provider.fetchChanges(module: module, cursor: state.cursors[module], expectedAccountID: account)
                    guard enabled, generation == run, !Task.isCancelled else { return }
                    // Capture edits made while the request was in flight before merging remote fields.
                    if initialized { try capture(app, module: module, allowDeletions: !state.resuming.contains(module)) }
                    for record in batch.records {
                        guard record.module == module else { throw SyncFailure.invalidRecord }
                        try state.merge(record)
                    }
                    if !initialized { try capture(app, module: module, seed: true) }
                    try saveState()
                    let records = state.records.values.filter { $0.module == module }
                    applying = true
                    try await apply(records, module: module, to: app)
                    applying = false
                    guard enabled, generation == run, !Task.isCancelled else { return }
                    // Applying tabs/blockers can await user or engine work. Journal edits made during
                    // that wait; capture ignores fields already equal to the merged remote record.
                    try capture(app, module: module, allowDeletions: !state.resuming.contains(module))
                    state.initialized.insert(module)
                    state.resuming.remove(module)
                    state.cursors[module] = batch.cursor
                    try saveState()
                    let pending = state.pending.compactMap { state.records[$0] }.filter { $0.module == module }
                    if !pending.isEmpty {
                        guard try await provider.accountID() == account else {
                            throw SyncFailure.unavailable(String(localized: "The iCloud account changed during sync. Try again."))
                        }
                        guard enabled, generation == run, !Task.isCancelled else { return }
                        let saved = try await provider.save(pending, module: module, expectedAccountID: account)
                        guard enabled, generation == run, !Task.isCancelled else { return }
                        // New local edits must be journaled before acknowledging the uploaded revision.
                        try capture(app, module: module, allowDeletions: !state.resuming.contains(module))
                        for record in saved {
                            guard record.module == module else { throw SyncFailure.invalidRecord }
                            try state.merge(record)
                            if state.records[record.id] == record { state.pending.remove(record.id) }
                        }
                        try saveState()
                        applying = true
                        try await apply(state.records.values.filter { $0.module == module }, module: module, to: app)
                        applying = false
                        guard enabled, generation == run, !Task.isCancelled else { return }
                        try capture(app, module: module)
                        try saveState()
                    }
                    if module == .organization { organizationReady = true }
                } catch {
                    if let tabFailure = error as? TabSyncApplyFailure, module == .openTabs, writable,
                       state.accountID == account {
                        let previous = state
                        do {
                            for id in tabFailure.closedBySync { state.baseline.removeValue(forKey: id) }
                            if enabled, generation == run {
                                try capture(app, module: module, allowDeletions: true)
                            }
                            try saveState()
                        } catch {
                            state = previous
                            throw error
                        }
                    } else if applying, writable {
                        state.resuming.insert(module)
                        try saveState()
                    }
                    if Task.isCancelled || !enabled || generation != run || !writable { throw error }
                    failures.append("\(module.title): \(error.localizedDescription)")
                    if let retry = error as? SyncRetryFailure { retryAfter = retry.retryAfter; break }
                }
            }
            if !failures.isEmpty { throw SyncFailure.unavailable(failures.joined(separator: "\n")) }
            state.lastSync = Date(); try saveState()
            lastSync = state.lastSync; errorMessage = nil; retryAfter = nil
            status = state.pending.contains { state.records[$0].map { modules.contains($0.module) } ?? false }
                ? String(localized: "Changes waiting to sync") : String(localized: "Up to date")
        } catch {
            if Task.isCancelled || generation != run { return }
            if let retry = error as? SyncRetryFailure { retryAfter = retry.retryAfter }
            errorMessage = error.localizedDescription
            status = enabled ? String(localized: "Sync paused. Will retry automatically.") : String(localized: "Sync is off")
        }
    }
}
