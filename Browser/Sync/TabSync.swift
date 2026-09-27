import Foundation

struct TabSyncApplyFailure: LocalizedError {
    let closedBySync: Set<String>
    let reason: String
    var errorDescription: String? { reason }
}

extension Tab {
    /// Favicon and loaded state may change as pages render or selection changes during sync.
    func matchesSyncSnapshot(_ other: Tab) -> Bool {
        id == other.id && spaceID == other.spaceID && urlString == other.urlString &&
            title == other.title && titleOverride == other.titleOverride && savedItemID == other.savedItemID &&
            engineID == other.engineID && engineOverride == other.engineOverride &&
            localFileBookmark == other.localFileBookmark
    }
}

@MainActor
extension AppModel {
    func tabSyncItems() -> [SyncItem] {
        windows.filter { !$0.isPrivate && !$0.isClosed }.flatMap { window in
            window.record.tabs.enumerated().compactMap { rank, tab -> SyncItem? in
                guard tab.savedItemID == nil, tab.url != nil,
                      LibraryStore.syncSafeURL(tab.urlString) != nil else { return nil }
                return SyncItem(id: "tab.\(tab.id.uuidString.lowercased())", module: .openTabs, kind: "tab", fields: [
                    "uuid": tab.id.uuidString.lowercased(),
                    "profileID": window.record.profileID.uuidString.lowercased(),
                    "spaceID": tab.spaceID.uuidString.lowercased(),
                    "url": tab.urlString,
                    "title": tab.title,
                    "titleOverride": tab.titleOverride ?? "",
                    "rank": String(rank)
                ])
            }
        }
    }

    func applySyncedTabs(_ items: [SyncItem]) async throws {
        struct Desired {
            var tab: Tab
            var profileID: UUID
            var rank: Int
        }
        var desired: [UUID: Desired] = [:]
        var seenIDs = Set<UUID>()
        var ignoredIDs = Set<UUID>()
        for item in items {
            guard item.module == .openTabs, item.kind == "tab",
                  let rawID = item.fields["uuid"], let id = UUID(uuidString: rawID),
                  item.id == "tab.\(id.uuidString.lowercased())",
                  let rawProfile = item.fields["profileID"], let profileID = UUID(uuidString: rawProfile),
                  let rawSpace = item.fields["spaceID"], let requestedSpaceID = UUID(uuidString: rawSpace),
                  let rawURL = item.fields["url"], let url = Tab(urlString: rawURL).url,
                  let title = item.fields["title"], let rawRank = item.fields["rank"],
                  let rank = Int(rawRank), rank >= 0, seenIDs.insert(id).inserted else {
                throw SyncFailure.invalidRecord
            }
            // Older clients may have uploaded a token URL. Keep it local without closing a matching tab.
            guard LibraryStore.syncSafeURL(rawURL) != nil else { ignoredIDs.insert(id); continue }
            // Organization may have deleted a profile or space before its older tab record arrives.
            guard profiles.contains(where: { $0.id == profileID }) else { continue }
            guard let spaceID = spaces.first(where: { $0.id == requestedSpaceID && $0.profileID == profileID })?.id
                ?? spaces.first(where: { $0.profileID == profileID })?.id else { throw SyncFailure.invalidRecord }
            let localOverride = windows.filter { !$0.isPrivate && $0.record.profileID == profileID }
                .compactMap { $0.record.tabs.first { $0.id == id }?.engineOverride }.first
            desired[id] = Desired(tab: Tab(id: id, spaceID: spaceID, urlString: rawURL,
                                           title: title, titleOverride: item.fields["titleOverride"].flatMap { $0.isEmpty ? nil : $0 }, isUnloaded: true,
                                           engineID: localOverride ?? preferences.engine(for: url), engineOverride: localOverride),
                                  profileID: profileID, rank: rank)
        }

        // A remote record may be older than a local navigation to a URL that must stay local.
        // Keep those tabs out of every apply phase, including metadata and ordering.
        let localOnlyIDs = Set(windows.filter { !$0.isClosed }.flatMap { window in
            window.record.tabs.compactMap { tab -> UUID? in
                guard window.isPrivate || tab.savedItemID != nil || tab.url == nil
                    || LibraryStore.syncSafeURL(tab.urlString) == nil else { return nil }
                return tab.id
            }
        })
        desired = desired.filter { !localOnlyIDs.contains($0.key) }

        // Snapshot candidates before awaiting a page. Tabs opened during a close request belong to a later sync pass.
        let candidates: [(BrowserWindowModel, Tab)] = windows
            .filter { !$0.isPrivate && !$0.isClosed }
            .flatMap { window in
                window.record.tabs.compactMap { tab in
                    guard tab.savedItemID == nil, !ignoredIDs.contains(tab.id), !localOnlyIDs.contains(tab.id), tab.url != nil,
                          LibraryStore.syncSafeURL(tab.urlString) != nil else { return nil }
                    return (window, tab)
                }
            }
        guard Set(candidates.map { $0.1.id }).count == candidates.count else { throw SyncFailure.invalidRecord }
        var replacementWindows: [UUID: BrowserWindowModel] = [:]
        var selectedReplacements = Set<UUID>()
        var closedBySync = Set<UUID>()
        do {
        for (window, original) in candidates {
            try Task.checkCancellation()
            let id = original.id
            guard let tab = window.record.tabs.first(where: { $0.id == id }) else { continue }
            if tab.savedItemID != nil { continue }
            guard tab.matchesSyncSnapshot(original) else {
                throw SyncFailure.localWrite(String(localized: "A tab changed while syncing. Sync will try again later."))
            }
            let remote = desired[tab.id]
            let needsClose = remote == nil || remote?.profileID != window.record.profileID
                || remote?.tab.urlString != tab.urlString
            if needsClose {
                if remote?.profileID == window.record.profileID {
                    replacementWindows[id] = window
                    if window.record.selectedTabID == id { selectedReplacements.insert(id) }
                }
                let closed = await window.closeTabForSync(tab.id)
                guard closed else {
                    throw SyncFailure.localWrite(String(localized: "A page kept its tab open. Sync will try again later."))
                }
                closedBySync.insert(id)
            }
        }

        // A different tab may change while a close request awaits its page. Retry instead of
        // overwriting that edit with the older remote title, space, or ordering.
        for (window, original) in candidates {
            let current = window.record.tabs.first { $0.id == original.id }
            if current.map({ !$0.matchesSyncSnapshot(original) }) ?? !closedBySync.contains(original.id) {
                throw SyncFailure.localWrite(String(localized: "A tab changed while syncing. Sync will try again later."))
            }
        }

        try Task.checkCancellation()

        let present = Set(windows.filter { !$0.isPrivate && !$0.isClosed }
            .flatMap { $0.record.tabs.map(\.id) })
        for (id, remote) in desired where !present.contains(id) {
            guard let window = replacementWindows[id]
                ?? windows.first(where: { !$0.isPrivate && !$0.isClosed &&
                $0.record.profileID == remote.profileID && $0.record.selectedSpaceID == remote.tab.spaceID })
                ?? windows.first(where: { !$0.isPrivate && !$0.isClosed && $0.record.profileID == remote.profileID })
                ?? newWindow(profileID: remote.profileID) else {
                throw SyncFailure.localWrite(String(localized: "Could not open a window for synced tabs."))
            }
            window.record.tabs.append(remote.tab)
            if selectedReplacements.contains(id) {
                window.record.selectedSpaceID = remote.tab.spaceID
                window.record.selectedTabID = id
            }
        }
        for window in windows where !window.isPrivate && !window.isClosed {
            for index in window.record.tabs.indices {
                let id = window.record.tabs[index].id
                guard let remote = desired[id], window.record.tabs[index].savedItemID == nil else { continue }
                window.record.tabs[index].spaceID = remote.tab.spaceID
                if window.record.selectedTabID == id {
                    window.record.selectedSpaceID = remote.tab.spaceID
                }
                window.record.tabs[index].title = remote.tab.title
                window.record.tabs[index].titleOverride = remote.tab.titleOverride
            }
            let positions = window.record.tabs.indices.filter { desired[window.record.tabs[$0].id] != nil
                && window.record.tabs[$0].savedItemID == nil }
            let ordered = positions.map { window.record.tabs[$0] }.sorted {
                let a = desired[$0.id]!, b = desired[$1.id]!
                if a.tab.spaceID != b.tab.spaceID { return a.tab.spaceID.uuidString < b.tab.spaceID.uuidString }
                return a.rank == b.rank ? $0.id.uuidString < $1.id.uuidString : a.rank < b.rank
            }
            for (index, tab) in zip(positions, ordered) { window.record.tabs[index] = tab }
        }
        if let error = await flushAndWait() { throw SyncFailure.localWrite(error) }
        } catch {
            throw TabSyncApplyFailure(closedBySync: Set(closedBySync.map { "tab.\($0.uuidString.lowercased())" }),
                                      reason: error.localizedDescription)
        }
    }
}
