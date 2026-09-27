import Foundation

extension AppModel {
    func syncItems(module: SyncModule) throws -> [SyncItem] {
        let profileIDs = Set(profiles.filter { !isDeletingProfile($0.id) }.map(\.id))
        switch module {
        case .contentBlockers: return try contentBlockerSyncItems()
        case .organization: return organizationSyncItems()
        case .openTabs: return tabSyncItems()
        case .preferences: return preferences.syncItems()
        case .siteSettings: return siteSettings.syncItems(profileIDs: profileIDs)
        case .history, .bookmarks: return try library.syncItems(module: module, profileIDs: profileIDs)
        }
    }

    func applySyncItems(_ items: [SyncItem], module: SyncModule) async throws {
        guard !profiles.contains(where: { isDeletingProfile($0.id) }) else {
            throw SyncFailure.unavailable(String(localized: "Sync will resume after profile deletion finishes."))
        }
        let profileIDs = Set(profiles.map(\.id))
        switch module {
        case .contentBlockers: try await applyContentBlockerSyncItems(items)
        case .organization: try applyOrganizationSyncItems(items)
        case .openTabs: try await applySyncedTabs(items)
        case .preferences: try preferences.applySyncItems(items)
        case .siteSettings: try siteSettings.applySyncItems(items, profileIDs: profileIDs)
        case .history, .bookmarks: try library.applySyncItems(items, module: module, profileIDs: profileIDs)
        }
    }

    func organizationSyncItems() -> [SyncItem] {
        var result: [SyncItem] = []
        for (rank, profile) in profiles.enumerated() {
            result.append(SyncItem(id: "profile.\(profile.id)", module: .organization, kind: "profile",
                                   fields: ["uuid": profile.id.uuidString, "name": profile.name, "rank": String(rank)]))
        }
        for (rank, space) in spaces.enumerated() {
            result.append(SyncItem(id: "space.\(space.id)", module: .organization, kind: "space",
                                   fields: ["uuid": space.id.uuidString, "profileID": space.profileID.uuidString,
                                            "name": space.name, "icon": space.icon ?? "", "rank": String(rank),
                                            "generated": space.isGeneratedDefault == true ? "true" : "false"]))
        }
        for (rank, folder) in folders.enumerated() {
            result.append(SyncItem(id: "folder.\(folder.id)", module: .organization, kind: "folder",
                                   fields: ["uuid": folder.id.uuidString, "spaceID": folder.spaceID.uuidString,
                                            "parentID": folder.parentID?.uuidString ?? "", "name": folder.name,
                                            "profileID": spaces.first { $0.id == folder.spaceID }?.profileID.uuidString ?? "",
                                            "color": folder.color.rawValue, "rank": String(rank)]))
        }
        for (rank, item) in savedItems.enumerated() where item.url.map({ $0.user == nil && $0.password == nil }) == true {
            result.append(SyncItem(id: "saved.\(item.id)", module: .organization, kind: "saved",
                                   fields: ["uuid": item.id.uuidString, "profileID": item.profileID.uuidString,
                                            "spaceID": item.spaceID?.uuidString ?? "", "folderID": item.folderID?.uuidString ?? "",
                                            "url": item.urlString, "title": item.title, "rank": String(rank)]))
        }
        return result
    }

    /// Validate the whole graph before committing. Native stores are never transported or deleted here.
    private func applyOrganizationSyncItems(_ items: [SyncItem]) throws {
        func uuid(_ item: SyncItem, _ key: String) throws -> UUID {
            guard let value = item.fields[key], let id = UUID(uuidString: value) else { throw SyncFailure.invalidRecord }
            return id
        }
        func optionalID(_ item: SyncItem, _ key: String) throws -> UUID? {
            guard let value = item.fields[key], !value.isEmpty else { return nil }
            guard let id = UUID(uuidString: value) else { throw SyncFailure.invalidRecord }; return id
        }
        func name(_ item: SyncItem, _ key: String = "name") throws -> String {
            guard let name = item.fields[key], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 16_384 else { throw SyncFailure.invalidRecord }; return name
        }
        let sorted = items.sorted {
            let left = Int($0.fields["rank"] ?? "") ?? 0, right = Int($1.fields["rank"] ?? "") ?? 0
            return left == right ? $0.id < $1.id : left < right
        }
        var nextProfiles: [Profile] = [], nextSpaces: [Space] = [], nextFolders: [Folder] = [], nextSaved: [SavedItem] = []
        var folderProfiles: [UUID: UUID] = [:]
        var ids = Set<String>()
        for item in sorted {
            guard item.module == .organization, ids.insert(item.id).inserted else { throw SyncFailure.invalidRecord }
            let id = try uuid(item, "uuid")
            guard item.id == "\(item.kind).\(id)" else { throw SyncFailure.invalidRecord }
            switch item.kind {
            case "profile":
                let binding = profiles.first { $0.id == id }?.storeBinding ?? (id == Profile.defaultID ? .legacyDefault : .named(id))
                nextProfiles.append(Profile(id: id, name: try name(item), storeBinding: binding))
            case "space":
                nextSpaces.append(Space(id: id, profileID: try uuid(item, "profileID"), name: try name(item),
                                        icon: Space.validatedIcon(item.fields["icon"]), isGeneratedDefault: item.fields["generated"] == "true"))
            case "folder":
                guard let color = FolderColor(rawValue: item.fields["color"] ?? "") else { throw SyncFailure.invalidRecord }
                folderProfiles[id] = try uuid(item, "profileID")
                nextFolders.append(Folder(id: id, spaceID: try uuid(item, "spaceID"), parentID: try optionalID(item, "parentID"),
                                          name: try name(item), color: color))
            case "saved":
                let oldIcon = savedItems.first { $0.id == id }?.favicon
                let saved = SavedItem(id: id, profileID: try uuid(item, "profileID"), spaceID: try optionalID(item, "spaceID"),
                                      folderID: try optionalID(item, "folderID"), urlString: try name(item, "url"),
                                      title: try name(item, "title"), favicon: oldIcon)
                guard let url = saved.url, url.user == nil, url.password == nil else { throw SyncFailure.invalidRecord }
                nextSaved.append(saved)
            default: throw SyncFailure.invalidRecord
            }
        }
        guard let defaultIndex = nextProfiles.firstIndex(where: { $0.id == Profile.defaultID }) else { throw SyncFailure.invalidRecord }
        let defaultProfile = nextProfiles.remove(at: defaultIndex); nextProfiles.insert(defaultProfile, at: 0)
        let profileIDs = Set(nextProfiles.map(\.id))
        nextSpaces.removeAll { !profileIDs.contains($0.profileID) }
        for profile in nextProfiles where !nextSpaces.contains(where: { $0.profileID == profile.id }) {
            // Concurrent deletion of each device's last space needs the same recovery home everywhere.
            nextSpaces.append(Space(id: profile.id == Profile.defaultID ? Space.defaultID : profile.id,
                                    profileID: profile.id, isGeneratedDefault: true))
        }
        guard Set(nextSpaces.map(\.id)).count == nextSpaces.count else { throw SyncFailure.invalidRecord }
        let spaceIDs = Set(nextSpaces.map(\.id))
        // A concurrent child insertion must survive deletion of its parent. Repair only the local
        // projection; keep the original cloud fields so an older client never rewrites unknown data.
        nextFolders = nextFolders.compactMap { original in
            var folder = original
            guard let profile = folderProfiles[folder.id] else { return nil }
            if !nextSpaces.contains(where: { $0.id == folder.spaceID && $0.profileID == profile }) {
                guard let home = nextSpaces.first(where: { $0.profileID == profile }) else { return nil }
                folder.spaceID = home.id; folder.parentID = nil
            }
            return folder
        }
        let folderIDs = Set(nextFolders.map(\.id))
        for index in nextFolders.indices {
            if let parent = nextFolders[index].parentID,
               !nextFolders.contains(where: { $0.id == parent && $0.spaceID == nextFolders[index].spaceID }) {
                nextFolders[index].parentID = nil
            }
        }
        // Break cycles caused by concurrent moves at a deterministic edge.
        for start in nextFolders.map(\.id).sorted(by: { $0.uuidString < $1.uuidString }) {
            var chain: [UUID] = [], cursor: UUID? = start
            while let id = cursor, let folder = nextFolders.first(where: { $0.id == id }) {
                if let cycle = chain.firstIndex(of: id) {
                    let cut = chain[cycle...].min { $0.uuidString < $1.uuidString }!
                    nextFolders[nextFolders.firstIndex { $0.id == cut }!].parentID = nil
                    break
                }
                chain.append(id); cursor = folder.parentID
            }
        }
        // A local pin may have become ineligible for sync after it was previously shared.
        // Its old cloud record still has the same ID; never replace its local destination.
        let localOnly = savedItems.filter { $0.url == nil || $0.url?.user != nil || $0.url?.password != nil }
        guard localOnly.allSatisfy({ profileIDs.contains($0.profileID) }) else {
            throw SyncFailure.unavailable(String(localized: "A profile removed on another device still has local saved items. Move or delete them before syncing."))
        }
        let localOnlyIDs = Set(localOnly.map(\.id))
        nextSaved.removeAll { localOnlyIDs.contains($0.id) }
        nextSaved += localOnly
        nextSaved = nextSaved.compactMap { original in
            guard profileIDs.contains(original.profileID) else { return nil }
            var item = original
            if let space = item.spaceID,
               !nextSpaces.contains(where: { $0.id == space && $0.profileID == item.profileID }) {
                item.spaceID = nextSpaces.first { $0.profileID == item.profileID }?.id
            }
            if let folder = item.folderID, !nextFolders.contains(where: { $0.id == folder && $0.spaceID == item.spaceID }) {
                item.folderID = nil
            }
            return item
        }
        guard nextSpaces.allSatisfy({ profileIDs.contains($0.profileID) }),
              nextFolders.allSatisfy({ spaceIDs.contains($0.spaceID) && ($0.parentID.map { folderIDs.contains($0) } ?? true) }),
              profileIDs.allSatisfy({ id in nextSpaces.contains { $0.profileID == id } }),
              nextSaved.allSatisfy({ item in
                  profileIDs.contains(item.profileID) && (item.spaceID.map { spaceID in
                      nextSpaces.contains { $0.id == spaceID && $0.profileID == item.profileID }
                  } ?? true) && (item.folderID.map { folderID in nextFolders.contains { $0.id == folderID && $0.spaceID == item.spaceID } } ?? true)
              }) else { throw SyncFailure.invalidRecord }
        for folder in nextFolders {
            var visited: Set<UUID> = [folder.id], parent = folder.parentID
            while let id = parent {
                guard visited.insert(id).inserted, let ancestor = nextFolders.first(where: { $0.id == id }),
                      ancestor.spaceID == folder.spaceID else { throw SyncFailure.invalidRecord }
                parent = ancestor.parentID
            }
        }
        // A remote deletion must never silently close a profile with live/private pages or discard its cookies.
        guard windows.allSatisfy({ profileIDs.contains($0.record.profileID) }) else {
            throw SyncFailure.unavailable(String(localized: "A profile was removed on another device. Close its windows to finish syncing. Website data will remain on this Mac."))
        }
        guard profiles != nextProfiles || spaces != nextSpaces || folders != nextFolders || savedItems != nextSaved else { return }
        var next = snapshot
        next.profiles = nextProfiles; next.spaces = nextSpaces; next.folders = nextFolders; next.savedItems = nextSaved
        func repair(_ record: inout WindowRecord) {
            let profileID = record.profileID
            let fallback = nextSpaces.first { $0.profileID == profileID }!.id
            if !nextSpaces.contains(where: { $0.id == record.selectedSpaceID && $0.profileID == profileID }) {
                record.selectedSpaceID = fallback
            }
            for index in record.tabs.indices {
                if !nextSpaces.contains(where: { $0.id == record.tabs[index].spaceID && $0.profileID == profileID }) {
                    record.tabs[index].spaceID = fallback
                }
                if let id = record.tabs[index].savedItemID {
                    guard let saved = nextSaved.first(where: { $0.id == id && $0.profileID == profileID }) else {
                        record.tabs[index].savedItemID = nil
                        continue
                    }
                    if let spaceID = saved.spaceID {
                        record.tabs[index].spaceID = spaceID
                        if record.selectedTabID == record.tabs[index].id { record.selectedSpaceID = spaceID }
                    }
                }
            }
            record.collapsedFolderIDs.removeAll { !folderIDs.contains($0) }
        }
        for index in next.windows.indices { repair(&next.windows[index]) }
        if let error = store.saveSynchronously(next) { throw SyncFailure.localWrite(error) }
        profiles = nextProfiles; spaces = nextSpaces; folders = nextFolders; savedItems = nextSaved
        for record in next.windows { windows.first { $0.id == record.id }?.record = record }
        for window in windows where window.isPrivate {
            var record = window.record
            repair(&record)
            window.record = record
        }
        clearOrganizationUndoAfterSync()
    }
}
