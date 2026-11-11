import Foundation
import Observation
import CryptoKit

enum SitePermission: String, Codable, CaseIterable, Sendable {
    case ask, allow, deny
}

enum SiteBrowserIdentity: String, Codable, CaseIterable, Sendable {
    case standard, androidPhone, androidTablet, iPhone, iPad

    var title: String {
        switch self {
        case .standard: String(localized: "Default")
        case .androidPhone: String(localized: "Android Phone")
        case .androidTablet: String(localized: "Android Tablet")
        case .iPhone: String(localized: "iPhone")
        case .iPad: String(localized: "iPad")
        }
    }

    var userAgent: String? {
        switch self {
        case .standard: nil
        case .androidPhone: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Mobile Safari/537.36"
        case .androidTablet: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
        case .iPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        case .iPad: "Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        }
    }
}

struct SiteSetting: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var profileID: UUID
    var origin: String
    var camera: SitePermission = .ask
    var microphone: SitePermission = .ask
    var popups: SitePermission = .ask
    var windowManagement: SitePermission = .ask
    /// `.ask` or `.deny`. Screen sharing grants are never saved, so `.allow` reads and saves as `.ask`.
    var screenSharing: SitePermission = .ask { didSet { if screenSharing == .allow { screenSharing = .ask } } }
    var engineID: EngineID = .webKit
    var zoom: Double?
    var browserIdentity: SiteBrowserIdentity = .standard
    enum CodingKeys: String, CodingKey {
        case id, profileID, origin, camera, microphone, popups, windowManagement, screenSharing, engineID, zoom, browserIdentity
    }
    init(id: UUID = UUID(), profileID: UUID, origin: String, camera: SitePermission = .ask,
         microphone: SitePermission = .ask, popups: SitePermission = .ask, engineID: EngineID = .webKit,
         zoom: Double? = nil, browserIdentity: SiteBrowserIdentity = .standard) {
        self.id = id; self.profileID = profileID; self.origin = origin; self.camera = camera
        self.microphone = microphone; self.popups = popups; self.engineID = engineID
        self.zoom = zoom
        self.browserIdentity = browserIdentity
    }
    subscript(kind: PermissionKind) -> SitePermission {
        get {
            switch kind {
            case .camera: camera
            case .microphone: microphone
            case .windowManagement: windowManagement
            case .screenSharing: screenSharing
            }
        }
        set {
            switch kind {
            case .camera: camera = newValue
            case .microphone: microphone = newValue
            case .windowManagement: windowManagement = newValue
            case .screenSharing: screenSharing = newValue
            }
        }
    }
    /// Any saved decision other than zoom and identity.
    var hasPermissions: Bool {
        camera != .ask || microphone != .ask || popups != .ask || windowManagement != .ask || screenSharing != .ask
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); profileID = try c.decode(UUID.self, forKey: .profileID)
        origin = try c.decode(String.self, forKey: .origin)
        camera = try c.decode(SitePermission.self, forKey: .camera)
        microphone = try c.decode(SitePermission.self, forKey: .microphone)
        popups = try c.decodeIfPresent(SitePermission.self, forKey: .popups) ?? .ask
        windowManagement = try c.decodeIfPresent(SitePermission.self, forKey: .windowManagement) ?? .ask
        let sharing = try c.decodeIfPresent(SitePermission.self, forKey: .screenSharing) ?? .ask
        screenSharing = sharing == .allow ? .ask : sharing
        engineID = try c.decodeIfPresent(EngineID.self, forKey: .engineID) ?? .webKit
        let decodedZoom = try c.decodeIfPresent(Double.self, forKey: .zoom)
        zoom = decodedZoom.flatMap { $0.isFinite && (0.5...3).contains($0) ? $0 : nil }
        browserIdentity = try c.decodeIfPresent(SiteBrowserIdentity.self, forKey: .browserIdentity) ?? .standard
    }
}

@MainActor @Observable
final class SiteSettingsStore {
    private(set) var entries: [SiteSetting] = []
    var lastError: String?
    @ObservationIgnored var mutationsAllowed: (() -> Bool)?
    @ObservationIgnored private let directory: URL
    private(set) var persistenceStatus: PersistenceStatus = .writable
    private var canSave: Bool { persistenceStatus.canSave }
    private struct Snapshot: Codable { var version = 3; var entries: [SiteSetting] }
    private var url: URL { directory.appendingPathComponent("site-settings.json") }

    init(directory: URL) {
        self.directory = directory
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        catch {
            persistenceStatus = .readOnly(String(format: String(localized: "Site settings could not be read: %@. Saving is disabled."), error.localizedDescription))
            lastError = persistenceStatus.readError
            return
        }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard (1...3).contains(snapshot.version) else { throw CocoaError(.coderReadCorrupt) }
            var ids = Set<UUID>()
            var keys = Set<String>()
            for var setting in snapshot.entries {
                guard !setting.engineID.rawValue.isEmpty,
                      let parsed = URL(string: setting.origin), let origin = AddressResolver.canonicalOrigin(parsed) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                setting.origin = origin
                let key = setting.engineID.rawValue + " " + setting.profileID.uuidString + " " + origin
                guard ids.insert(setting.id).inserted, keys.insert(key).inserted else { throw CocoaError(.coderReadCorrupt) }
                entries.append(setting)
            }
        } catch {
            entries = []
            do {
                try PersistenceFile.preserve(data, in: self.directory, prefix: "site-settings.corrupt")
                persistenceStatus = .readOnly(String(localized: "Site settings are unreadable or use an unsupported format. The original was preserved; saving is disabled."))
            } catch {
                persistenceStatus = .readOnly(String(localized: "Site settings are unreadable and a backup could not be created. The original is untouched; saving is disabled."))
            }
            lastError = persistenceStatus.readError
        }
    }

    func setting(origin: URL, profileID: UUID, engineID: EngineID = .webKit) -> SiteSetting {
        let key = AddressResolver.canonicalOrigin(origin) ?? ""
        return entries.first { $0.profileID == profileID && $0.engineID == engineID && $0.origin == key }
            ?? SiteSetting(profileID: profileID, origin: key, engineID: engineID)
    }

    func browserIdentity(for origin: URL, profileID: UUID) -> SiteBrowserIdentity {
        setting(origin: origin, profileID: profileID).browserIdentity
    }

    @discardableResult
    func setBrowserIdentity(_ identity: SiteBrowserIdentity, for origin: URL, profileID: UUID) -> Bool {
        guard beginMutation(), canSave else { return false }
        guard AddressResolver.canonicalOrigin(origin) != nil else {
            lastError = String(localized: "Site rules require a valid HTTP or HTTPS origin.")
            return false
        }
        var entry = setting(origin: origin, profileID: profileID)
        guard entry.browserIdentity != identity else { lastError = nil; return true }
        entry.browserIdentity = identity
        if identity == .standard && !entry.hasPermissions && entry.zoom == nil {
            return save(entries.filter { $0.id != entry.id })
        }
        return update(entry)
    }

    @discardableResult
    func update(_ setting: SiteSetting) -> Bool {
        guard beginMutation(), canSave else { return false }
        guard !setting.engineID.rawValue.isEmpty else {
            lastError = String(localized: "Choose an available browser engine."); return false
        }
        guard setting.zoom.map({ $0.isFinite && (0.5...3).contains($0) }) ?? true else {
            lastError = String(localized: "Site zoom must be between 50% and 300%."); return false
        }
        guard let parsed = URL(string: setting.origin), let origin = AddressResolver.canonicalOrigin(parsed) else {
            lastError = String(localized: "Site settings require a valid HTTP or HTTPS origin."); return false
        }
        var next = entries
        var normalized = setting
        normalized.origin = origin
        if let index = next.firstIndex(where: { $0.profileID == setting.profileID && $0.engineID == setting.engineID && $0.origin == origin }) {
            normalized.id = next[index].id
            next[index] = normalized
        } else {
            if next.contains(where: { $0.id == normalized.id }) { normalized.id = UUID() }
            next.append(normalized)
        }
        return save(next)
    }

    func setZoom(_ zoom: Double?, origin: URL, profileID: UUID, engineID: EngineID = .webKit) {
        guard beginMutation() else { return }
        var next = setting(origin: origin, profileID: profileID, engineID: engineID)
        let value = zoom == 1 ? nil : zoom
        guard next.zoom != value else { return }
        next.zoom = value
        if value == nil && !next.hasPermissions && next.browserIdentity == .standard {
            if canSave { save(entries.filter { $0.id != next.id }) }
        } else {
            update(next)
        }
    }

    func syncItems(profileIDs: Set<UUID>) -> [SyncItem] {
        entries.compactMap { entry in
            guard profileIDs.contains(entry.profileID), let zoom = entry.zoom else { return nil }
            return SyncItem(id: Self.syncID(profile: entry.profileID, engine: entry.engineID, origin: entry.origin),
                            module: .siteSettings, kind: "zoom", fields: [
                                "profileID": entry.profileID.uuidString, "engineID": entry.engineID.rawValue,
                                "origin": entry.origin, "zoom": String(zoom)
                            ])
        }
    }

    func applySyncItems(_ items: [SyncItem], profileIDs: Set<UUID>) throws {
        guard beginMutation(), canSave else { throw CocoaError(.fileWriteUnknown) }
        var desired: [String: (UUID, EngineID, String, Double)] = [:]
        var seen = Set<String>()
        for item in items {
            let fields = item.fields
            guard item.module == .siteSettings, item.kind == "zoom",
                  let profile = fields["profileID"].flatMap(UUID.init(uuidString:)),
                  let rawEngine = fields["engineID"], !rawEngine.isEmpty,
                  let rawOrigin = fields["origin"], let url = URL(string: rawOrigin),
                  let origin = AddressResolver.canonicalOrigin(url), origin == rawOrigin,
                  let zoom = fields["zoom"].flatMap(Double.init), zoom.isFinite, (0.5...3).contains(zoom) else {
                throw CocoaError(.coderReadCorrupt)
            }
            let id = Self.syncID(profile: profile, engine: EngineID(rawValue: rawEngine), origin: origin)
            guard item.id == id, seen.insert(id).inserted else { throw CocoaError(.coderReadCorrupt) }
            if profileIDs.contains(profile) { desired[id] = (profile, EngineID(rawValue: rawEngine), origin, zoom) }
        }
        var next = entries.compactMap { entry -> SiteSetting? in
            guard profileIDs.contains(entry.profileID) else { return entry }
            let id = Self.syncID(profile: entry.profileID, engine: entry.engineID, origin: entry.origin)
            var changed = entry
            changed.zoom = desired.removeValue(forKey: id)?.3
            return changed.zoom == nil && !changed.hasPermissions && changed.browserIdentity == .standard ? nil : changed
        }
        for (_, value) in desired {
            next.append(SiteSetting(profileID: value.0, origin: value.2, engineID: value.1, zoom: value.3))
        }
        if Set(next) == Set(entries) { return }
        guard save(next) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func syncID(profile: UUID, engine: EngineID, origin: String) -> String {
        let data = Data((profile.uuidString + "\n" + engine.rawValue + "\n" + origin).utf8)
        return "zoom:" + SHA256.hash(data: data).hexString
    }

    func remove(id: UUID) {
        guard beginMutation() else { return }
        forgetPermissions { $0.id == id }
    }

    func clear(profileID: UUID) {
        guard beginMutation() else { return }
        forgetPermissions { $0.profileID == profileID }
    }

    @discardableResult
    func removeProfile(_ profileID: UUID) -> Bool {
        guard canSave else { return false }
        return save(entries.filter { $0.profileID != profileID })
    }

    static func mediaDecision(kinds: Set<PermissionKind>, setting: SiteSetting?, isPrivate: Bool, sameOrigin: Bool) -> SitePermission {
        guard !isPrivate, let setting else { return .ask }
        let values = kinds.map { setting[$0] }
        if values.contains(.deny) { return .deny }
        return sameOrigin && !values.isEmpty && values.allSatisfy { $0 == .allow } ? .allow : .ask
    }

    static func allowsPopup(setting: SitePermission, isPrivate: Bool, userGesture: Bool) -> Bool {
        let effective = isPrivate ? SitePermission.ask : setting
        return effective == .allow || userGesture
    }

    struct Summary: Identifiable {
        let origin: String
        /// nil when engines disagree; absent kinds no engine supports.
        let permissions: [PermissionKind: SitePermission?]
        let browserIdentity: SiteBrowserIdentity
        /// Outer nil: no engine has a pop-up policy. Inner nil: engines disagree.
        let popups: SitePermission??
        var id: String { origin }
        var camera: SitePermission? { permissions[.camera] ?? nil }
        var microphone: SitePermission? { permissions[.microphone] ?? nil }
    }
    func summaries(profileID: UUID, engines: [any BrowserEngine], includeIdentity: Bool = false) -> [Summary] {
        let origins = Set(entries.filter {
            $0.profileID == profileID && ($0.hasPermissions || (includeIdentity && $0.browserIdentity != .standard))
        }.map(\.origin))
        return origins.sorted().compactMap { origin in
            guard let url = URL(string: origin) else { return nil }
            @MainActor func value(supported: (any BrowserEngine) -> Bool, _ read: (SiteSetting) -> SitePermission) -> SitePermission? {
                var values = engines.filter(supported).map { read(setting(origin: url, profileID: profileID, engineID: $0.id)) }
                values += entries.filter { entry in entry.profileID == profileID && entry.origin == origin && !engines.contains(where: { engine in engine.id == entry.engineID }) }.map(read)
                return Set(values).count == 1 ? values.first : nil
            }
            var permissions: [PermissionKind: SitePermission?] = [:]
            for kind in [PermissionKind.camera, .microphone, .windowManagement, .screenSharing]
            where engines.contains(where: { $0.capabilities.permissions.contains(kind) }) {
                permissions[kind] = value(supported: { $0.capabilities.permissions.contains(kind) }) { $0[kind] }
            }
            let popups: SitePermission?? = engines.contains(where: { $0.capabilities.supportsPopupPolicy })
                ? .some(value(supported: { $0.capabilities.supportsPopupPolicy }) { $0.popups }) : nil
            return Summary(origin: origin, permissions: permissions,
                           browserIdentity: browserIdentity(for: url, profileID: profileID), popups: popups)
        }
    }
    @discardableResult
    func update(origin: String, profileID: UUID, _ kind: PermissionKind, _ value: SitePermission,
                engines: [any BrowserEngine]) -> Bool {
        update(origin: origin, profileID: profileID,
               engines: engines.filter { $0.capabilities.permissions.contains(kind) }) { $0[kind] = value }
    }
    /// Pages read the pop-up decision when a pop-up opens, so no reload is needed.
    @discardableResult
    func updatePopups(origin: String, profileID: UUID, _ value: SitePermission, engines: [any BrowserEngine]) -> Bool {
        update(origin: origin, profileID: profileID,
               engines: engines.filter { $0.capabilities.supportsPopupPolicy }) { $0.popups = value }
    }
    private func update(origin: String, profileID: UUID, engines: [any BrowserEngine],
                        change: (inout SiteSetting) -> Void) -> Bool {
        guard beginMutation(), canSave, let url = URL(string: origin),
              let normalized = AddressResolver.canonicalOrigin(url) else { return false }
        var next = entries
        for engine in engines {
            var entry = setting(origin: url, profileID: profileID, engineID: engine.id)
            change(&entry)
            next.removeAll { $0.profileID == profileID && $0.origin == normalized && $0.engineID == engine.id }
            next.append(entry)
        }
        return save(next)
    }
    @discardableResult
    func forget(origin: String, profileID: UUID) -> Bool {
        guard beginMutation() else { return false }
        return forgetPermissions { $0.profileID == profileID && $0.origin == origin }
    }

    @discardableResult
    private func forgetPermissions(where matches: (SiteSetting) -> Bool) -> Bool {
        guard canSave else { return false }
        return save(entries.compactMap { entry in
            guard matches(entry) else { return entry }
            guard entry.zoom != nil || entry.browserIdentity != .standard else { return nil }
            var next = entry
            next.camera = .ask; next.microphone = .ask; next.popups = .ask
            next.windowManagement = .ask; next.screenSharing = .ask
            return next
        })
    }

    @discardableResult
    private func save(_ next: [SiteSetting]) -> Bool {
        do {
            try PersistenceFile.save(Snapshot(entries: next), to: url)
            entries = next
            lastError = nil
            return true
        } catch { lastError = String(format: String(localized: "Site settings could not be saved: %@"), error.localizedDescription) }
        return false
    }

    private func beginMutation() -> Bool {
        guard mutationsAllowed?() != false else {
            lastError = String(localized: "A profile is being deleted. Try again when cleanup finishes.")
            return false
        }
        return true
    }
}
