import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Profile: Identifiable, Hashable, Codable, Sendable {
    enum StoreBinding: Hashable, Codable, Sendable { case legacyDefault, named(UUID) }
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id: UUID = UUID()
    var name: String = "Default"
    var storeBinding: StoreBinding = .legacyDefault

    var displayedName: String { id == Self.defaultID && name == "Default" ? String(localized: "Default") : name }
}

struct Space: Identifiable, Hashable, Codable, Sendable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    var id: UUID = UUID()
    var profileID: UUID = Profile.defaultID
    var name: String = "Home"
    var icon: String? = nil
    /// `nil` preserves legacy default-space behavior; explicit values preserve generated versus renamed spaces.
    var isGeneratedDefault: Bool? = nil

    static func validatedIcon(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count == 1 else { return nil }
        return trimmed
    }

    var displayedName: String {
        (isGeneratedDefault ?? (id == Self.defaultID)) && name == "Home" ? String(localized: "Home") : name
    }
    var labeledName: String { icon.map { "\($0) \(displayedName)" } ?? displayedName }
}

enum FolderColor: String, CaseIterable, Codable, Sendable {
    case theme, blue, teal, green, yellow, orange, pink, purple, gray
}

struct Folder: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var spaceID: UUID = Space.defaultID
    var parentID: UUID? = nil
    var name: String = "Folder"
    var color: FolderColor = .theme

    enum CodingKeys: String, CodingKey { case id, spaceID, parentID, name, color }

    init(id: UUID = UUID(), spaceID: UUID = Space.defaultID, parentID: UUID? = nil,
         name: String = "Folder", color: FolderColor = .theme) {
        self.id = id; self.spaceID = spaceID; self.parentID = parentID; self.name = name; self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        spaceID = try c.decode(UUID.self, forKey: .spaceID)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        name = try c.decode(String.self, forKey: .name)
        color = (try? c.decode(FolderColor.self, forKey: .color)) ?? .theme
    }

    var labeledName: String { name }
}

struct CachedFavicon: Hashable, Codable, Sendable {
    var origin: String
    var png: Data

    func validated(for urlString: String) -> CachedFavicon? {
        guard let url = URL(string: urlString), AddressResolver.canonicalOrigin(url) == origin,
              png.count <= 16_384,
              let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...32).contains(width), (1...32).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return self
    }
}

/// Sidebar favorite (`spaceID == nil`) or space pin. Not a library bookmark.
struct SavedItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var profileID: UUID = Profile.defaultID
    var spaceID: UUID? = nil
    var folderID: UUID? = nil
    var urlString: String = ""
    var title: String = "Untitled"
    var favicon: CachedFavicon? = nil
    var url: URL? {
        guard let candidate = URL(string: urlString), AddressResolver.canonicalOrigin(candidate) != nil,
              case let .navigate(url) = AddressResolver.resolve(urlString) else { return nil }
        return url
    }
}

struct Tab: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var spaceID: UUID = Space.defaultID
    var urlString: String = ""
    var title: String = "New Tab"
    var titleOverride: String? = nil
    /// This window's live or unloaded instance of a `SavedItem`. Nil for ordinary tabs.
    var savedItemID: UUID? = nil
    var favicon: CachedFavicon? = nil
    var isUnloaded: Bool? = nil
    var engineID: EngineID = .webKit
    var engineOverride: EngineID? = nil
    /// Opaque security-scoped bookmark for an explicitly opened local file. Private-window records are never saved.
    var localFileBookmark: Data? = nil

    enum CodingKeys: String, CodingKey {
        case id, spaceID, urlString, title, titleOverride, savedItemID, favicon, isUnloaded, engineID, engineOverride, localFileBookmark
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        spaceID = try c.decode(UUID.self, forKey: .spaceID)
        urlString = try c.decode(String.self, forKey: .urlString)
        title = try c.decode(String.self, forKey: .title)
        titleOverride = try c.decodeIfPresent(String.self, forKey: .titleOverride)
        savedItemID = try c.decodeIfPresent(UUID.self, forKey: .savedItemID)
        favicon = try c.decodeIfPresent(CachedFavicon.self, forKey: .favicon)
        isUnloaded = try c.decodeIfPresent(Bool.self, forKey: .isUnloaded)
        engineID = try c.decodeIfPresent(EngineID.self, forKey: .engineID) ?? .webKit
        engineOverride = try c.decodeIfPresent(EngineID.self, forKey: .engineOverride)
        localFileBookmark = try c.decodeIfPresent(Data.self, forKey: .localFileBookmark)
    }
    init(id: UUID = UUID(), spaceID: UUID = Space.defaultID, urlString: String = "", title: String = "New Tab",
         titleOverride: String? = nil, savedItemID: UUID? = nil, favicon: CachedFavicon? = nil, isUnloaded: Bool? = nil,
         engineID: EngineID = .webKit, engineOverride: EngineID? = nil, localFileBookmark: Data? = nil) {
        self.id = id; self.spaceID = spaceID; self.urlString = urlString; self.title = title
        self.titleOverride = titleOverride; self.savedItemID = savedItemID; self.favicon = favicon
        self.isUnloaded = isUnloaded; self.engineID = engineID; self.engineOverride = engineOverride
        self.localFileBookmark = localFileBookmark
    }
    var displayedTitle: String {
        if let titleOverride, !titleOverride.isEmpty { return titleOverride }
        if title == "New Tab" && urlString.isEmpty { return String(localized: "New Tab") }
        if title == "Opening…" && urlString.isEmpty { return String(localized: "Opening…") }
        if title == "Loading…" && !urlString.isEmpty { return String(localized: "Loading…") }
        return title
    }
    var url: URL? {
        guard let candidate = URL(string: urlString), AddressResolver.canonicalOrigin(candidate) != nil,
              case let .navigate(url) = AddressResolver.resolve(urlString) else { return nil }
        return url
    }
}

struct WindowFrame: Hashable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct WindowRecord: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var profileID: UUID = Profile.defaultID
    var selectedSpaceID: UUID = Space.defaultID
    var selectedTabID: UUID? = nil
    var tabs: [Tab] = []
    var collapsedFolderIDs: [UUID] = []
    var sidebarVisible: Bool = true
    var sidebarWidth: Double? = nil
    var frame: WindowFrame? = nil
}

struct PendingProfileDeletion: Equatable, Codable, Sendable {
    let profileID: UUID
    var requiredEngineIDs: [EngineID]
}

struct ProfileEngineUsage: Equatable, Codable, Sendable {
    let profileID: UUID
    var engineIDs: [EngineID]
}

struct SessionSnapshot: Codable, Sendable {
    static let currentVersion = 10
    var version: Int = currentVersion
    var profiles: [Profile] = [Profile(id: Profile.defaultID)]
    var spaces: [Space] = [Space(id: Space.defaultID, isGeneratedDefault: true)]
    var folders: [Folder] = []
    var savedItems: [SavedItem] = []
    var windows: [WindowRecord] = []
    /// A crash-safe tombstone written before engine data removal begins.
    var pendingProfileDeletions: [PendingProfileDeletion]?
    /// Engines that may own data for a profile. Written before first use.
    var profileEngineUsage: [ProfileEngineUsage]?

    init(version: Int = currentVersion, profiles: [Profile] = [Profile(id: Profile.defaultID)],
         spaces: [Space] = [Space(id: Space.defaultID, isGeneratedDefault: true)], folders: [Folder] = [],
         savedItems: [SavedItem] = [], windows: [WindowRecord]? = nil,
         pendingProfileDeletions: [PendingProfileDeletion] = [], profileEngineUsage: [ProfileEngineUsage] = []) {
        self.version = version
        self.profiles = profiles
        self.spaces = spaces
        self.folders = folders
        self.savedItems = savedItems
        self.windows = windows ?? [WindowRecord()]
        self.pendingProfileDeletions = pendingProfileDeletions.isEmpty ? nil : pendingProfileDeletions
        self.profileEngineUsage = profileEngineUsage.isEmpty ? nil : profileEngineUsage
    }

    static func decode(_ data: Data) throws -> SessionSnapshot {
        struct Version: Decodable { let version: Int? }
        struct Legacy: Decodable {
            struct LegacyTab: Decodable { let id: UUID; let urlString: String; let title: String }
            let tabs: [LegacyTab]
            let selectedTabID: UUID?
        }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Version.self, from: data).version
        guard let version else {
            let legacy = try decoder.decode(Legacy.self, from: data)
            let tabs = legacy.tabs.map { Tab(id: $0.id, urlString: $0.urlString, title: $0.title) }
            return SessionSnapshot(windows: [WindowRecord(selectedTabID: legacy.selectedTabID, tabs: tabs)]).validated()
        }
        guard (1...currentVersion).contains(version) else { throw CocoaError(.coderReadCorrupt) }
        var snapshot = try decoder.decode(SessionSnapshot.self, from: data)
        if version < 7 {
            let legacyEngines = [EngineID.webKit, EngineID(rawValue: "chromium")]
            snapshot.profileEngineUsage = snapshot.profiles.compactMap { profile in
                guard profile.id != Profile.defaultID, case .named = profile.storeBinding else { return nil }
                let saved = snapshot.windows.filter { $0.profileID == profile.id }.flatMap { $0.tabs.map(\.engineID) }
                return ProfileEngineUsage(profileID: profile.id,
                    engineIDs: Array(Set(legacyEngines + saved)).sorted { $0.rawValue < $1.rawValue })
            }
        }
        if version < 8 {
            for i in snapshot.savedItems.indices where snapshot.savedItems[i].folderID == nil {
                snapshot.savedItems[i].spaceID = nil
            }
        }
        snapshot.version = currentVersion
        return snapshot.validated()
    }

    func withoutLocalFileBookmarks() -> SessionSnapshot {
        var result = self
        for window in result.windows.indices {
            for tab in result.windows[window].tabs.indices { result.windows[window].tabs[tab].localFileBookmark = nil }
        }
        return result
    }

    /// Keep ordered records. Ambiguous references to duplicate IDs identify the first record.
    func validated() -> SessionSnapshot {
        var result = self
        func unique<T: Identifiable>(_ records: inout [T], id: WritableKeyPath<T, UUID>) where T.ID == UUID {
            var seen = Set<UUID>()
            for i in records.indices {
                if !seen.insert(records[i][keyPath: id]).inserted { records[i][keyPath: id] = UUID() }
            }
        }
        unique(&result.profiles, id: \.id)
        if let defaultIndex = result.profiles.firstIndex(where: { $0.id == Profile.defaultID }) {
            let defaultProfile = result.profiles.remove(at: defaultIndex)
            result.profiles.insert(defaultProfile, at: 0)
        } else {
            result.profiles.insert(Profile(id: Profile.defaultID), at: 0)
        }
        result.profiles[0].storeBinding = .legacyDefault
        var bindings: Set<Profile.StoreBinding> = [.legacyDefault]
        for i in result.profiles.indices.dropFirst() {
            if !bindings.insert(result.profiles[i].storeBinding).inserted {
                repeat { result.profiles[i].storeBinding = .named(UUID()) }
                while bindings.contains(result.profiles[i].storeBinding)
            }
            bindings.insert(result.profiles[i].storeBinding)
        }
        let profileIDs = Set(result.profiles.map(\.id))
        result.profileEngineUsage = result.profileEngineUsage.map { records in
            var enginesByProfile: [UUID: Set<EngineID>] = [:]
            for record in records where profileIDs.contains(record.profileID) {
                enginesByProfile[record.profileID, default: []].formUnion(record.engineIDs)
            }
            return enginesByProfile.map { id, engineIDs in
                ProfileEngineUsage(profileID: id,
                    engineIDs: engineIDs.sorted { $0.rawValue < $1.rawValue })
            }.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
        }.flatMap { $0.isEmpty ? nil : $0 }
        result.pendingProfileDeletions = result.pendingProfileDeletions.map { deletions in
            var enginesByProfile: [UUID: Set<EngineID>] = [:]
            for deletion in deletions {
                guard deletion.profileID != Profile.defaultID,
                      let profile = result.profiles.first(where: { $0.id == deletion.profileID }),
                      case .named = profile.storeBinding else { continue }
                enginesByProfile[deletion.profileID, default: []].formUnion(deletion.requiredEngineIDs)
            }
            return enginesByProfile.map { id, engineIDs in
                PendingProfileDeletion(profileID: id,
                    requiredEngineIDs: engineIDs.sorted { $0.rawValue < $1.rawValue })
            }.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
        }.flatMap { $0.isEmpty ? nil : $0 }
        unique(&result.spaces, id: \.id)
        for i in result.spaces.indices {
            if !profileIDs.contains(result.spaces[i].profileID) { result.spaces[i].profileID = result.profiles[0].id }
            result.spaces[i].icon = Space.validatedIcon(result.spaces[i].icon)
        }
        for profile in result.profiles where !result.spaces.contains(where: { $0.profileID == profile.id }) {
            result.spaces.append(Space(profileID: profile.id, isGeneratedDefault: true))
        }
        let spacesByID = Dictionary(uniqueKeysWithValues: result.spaces.map { ($0.id, $0) })
        unique(&result.folders, id: \.id)
        for i in result.folders.indices {
            if spacesByID[result.folders[i].spaceID] == nil { result.folders[i].spaceID = result.spaces[0].id }
        }
        var parents = Dictionary(uniqueKeysWithValues: result.folders.map { ($0.id, $0.parentID) })
        for folder in result.folders {
            guard let parentID = folder.parentID,
                  let parent = result.folders.first(where: { $0.id == parentID }),
                  parent.spaceID == folder.spaceID, parentID != folder.id else {
                parents[folder.id] = nil
                continue
            }
        }
        for folder in result.folders {
            var path: [UUID] = []
            var cursor = folder.id
            while let parentID = parents[cursor] ?? nil {
                if let cycle = path.firstIndex(of: parentID) {
                    path[cycle...].forEach { parents[$0] = nil }
                    break
                }
                path.append(cursor)
                cursor = parentID
            }
        }
        for i in result.folders.indices { result.folders[i].parentID = parents[result.folders[i].id] ?? nil }
        let foldersByID = Dictionary(uniqueKeysWithValues: result.folders.map { ($0.id, $0) })
        unique(&result.savedItems, id: \.id)
        result.savedItems.removeAll { URL(string: $0.urlString)?.isFileURL == true }
        for i in result.savedItems.indices {
            result.savedItems[i].favicon = result.savedItems[i].favicon?.validated(for: result.savedItems[i].urlString)
            if let spaceID = result.savedItems[i].spaceID, let space = spacesByID[spaceID] {
                result.savedItems[i].profileID = space.profileID
            } else {
                result.savedItems[i].spaceID = nil
                if !profileIDs.contains(result.savedItems[i].profileID) { result.savedItems[i].profileID = result.profiles[0].id }
            }
            if let folderID = result.savedItems[i].folderID,
               foldersByID[folderID] == nil || foldersByID[folderID]?.spaceID != result.savedItems[i].spaceID {
                result.savedItems[i].folderID = nil
            }
        }
        let savedByID = Dictionary(uniqueKeysWithValues: result.savedItems.map { ($0.id, $0) })
        unique(&result.windows, id: \.id)
        var tabIDs = Set<UUID>()
        for i in result.windows.indices {
            if !profileIDs.contains(result.windows[i].profileID) { result.windows[i].profileID = result.profiles[0].id }
            let profileID = result.windows[i].profileID
            let firstSpace = result.spaces.first { $0.profileID == profileID }!.id
            if spacesByID[result.windows[i].selectedSpaceID]?.profileID != profileID { result.windows[i].selectedSpaceID = firstSpace }
            var savedInstances = Set<UUID>()
            for j in result.windows[i].tabs.indices {
                if result.windows[i].tabs[j].engineID.rawValue.isEmpty { result.windows[i].tabs[j].engineID = .webKit }
                if result.windows[i].tabs[j].engineOverride?.rawValue.isEmpty == true { result.windows[i].tabs[j].engineOverride = nil }
                result.windows[i].tabs[j].favicon = result.windows[i].tabs[j].favicon?.validated(for: result.windows[i].tabs[j].urlString)
                if result.windows[i].tabs[j].titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    result.windows[i].tabs[j].titleOverride = nil
                }
                if URL(string: result.windows[i].tabs[j].urlString)?.isFileURL != true
                    || !(1...131_072).contains(result.windows[i].tabs[j].localFileBookmark?.count ?? 0) {
                    result.windows[i].tabs[j].localFileBookmark = nil
                }
                if !tabIDs.insert(result.windows[i].tabs[j].id).inserted { result.windows[i].tabs[j].id = UUID() }
                if spacesByID[result.windows[i].tabs[j].spaceID]?.profileID != profileID { result.windows[i].tabs[j].spaceID = firstSpace }
                if let savedID = result.windows[i].tabs[j].savedItemID {
                    if let item = savedByID[savedID], item.profileID == profileID {
                        if let spaceID = item.spaceID { result.windows[i].tabs[j].spaceID = spaceID }
                        if !savedInstances.insert(savedID).inserted { result.windows[i].tabs[j].savedItemID = nil }
                    } else { result.windows[i].tabs[j].savedItemID = nil }
                }
            }
            result.windows[i].tabs.removeAll {
                $0.savedItemID == nil && $0.titleOverride == nil && $0.title == "New Tab"
                    && ($0.urlString.isEmpty || $0.urlString == "about:blank")
            }
            let selected = result.windows[i].tabs.first { $0.id == result.windows[i].selectedTabID }
            let selectedItem = selected?.savedItemID.flatMap { savedByID[$0] }
            if let pinSpace = selectedItem?.spaceID { result.windows[i].selectedSpaceID = pinSpace }
            let selectedSpace = result.windows[i].selectedSpaceID
            let selectedFavorite = selectedItem != nil && selectedItem?.spaceID == nil
            if result.windows[i].selectedTabID != nil && !selectedFavorite && selected?.spaceID != selectedSpace {
                if let next = result.windows[i].tabs.first(where: { $0.spaceID == selectedSpace }) {
                    result.windows[i].selectedTabID = next.id
                } else {
                    result.windows[i].selectedTabID = nil
                }
            }
            var collapsed = Set<UUID>()
            result.windows[i].collapsedFolderIDs = result.windows[i].collapsedFolderIDs.filter {
                guard let folder = foldersByID[$0], spacesByID[folder.spaceID]?.profileID == profileID else { return false }
                return collapsed.insert($0).inserted
            }
            if let frame = result.windows[i].frame,
               ![frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite) || frame.width < 1 || frame.height < 1 {
                result.windows[i].frame = nil
            }
        }
        return result
    }
}
