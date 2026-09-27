import Foundation

@MainActor
extension AppModel {
    func contentBlockerSyncItems() throws -> [SyncItem] {
        var items: [SyncItem] = []
        for engine in engines.engines {
            guard let blocker = engine.contentBlocker else { continue }
            // An unreadable local store looks empty; publishing that as absence would delete cloud rules.
            if !blocker.canPersistRules {
                throw SyncFailure.localWrite(blocker.lastError ?? String(localized: "Content blocker settings cannot be read or saved."))
            }
            for profile in profiles where blocker.hasRules(profileID: profile.id) {
                let source = blocker.updateSource(profileID: profile.id)
                // Omitting a local-only configuration would look like a deletion to the sync journal.
                guard source.map(Self.safeBlockerSource) ?? blocker.usesBundledRules(profileID: profile.id) else {
                    throw SyncFailure.localWrite(String(localized: "Local content rules cannot be synced. Remove or replace them before syncing content blockers."))
                }
                var fields = ["profileID": profile.id.uuidString, "engineID": engine.id.rawValue,
                              "enabled": String(blocker.isEnabled(profileID: profile.id)),
                              "rulesKind": source == nil ? "bundled" : "source"]
                if let source {
                    fields["source"] = source.absoluteString
                }
                let exceptions = blocker.exceptions(profileID: profile.id)
                guard exceptions.allSatisfy({ URL(string: $0).flatMap(AddressResolver.canonicalOrigin) == $0 }) else {
                    throw SyncFailure.invalidRecord
                }
                fields["exceptions"] = exceptions.sorted().joined(separator: "\n")
                items.append(SyncItem(id: "blocker:\(profile.id.uuidString):\(engine.id.rawValue)",
                                      module: .contentBlockers, kind: "configuration", fields: fields))
            }
        }
        return items
    }

    func applyContentBlockerSyncItems(_ items: [SyncItem]) async throws {
        var seen = Set<String>()
        var valid: [(UUID, EngineID, Bool, String, URL?, [String])] = []
        for item in items {
            guard item.module == .contentBlockers else { throw SyncFailure.invalidRecord }
            guard item.kind == "configuration" else { continue }
            let fields = item.fields
            guard let profile = fields["profileID"].flatMap(UUID.init(uuidString:)),
                  let rawEngine = fields["engineID"], !rawEngine.isEmpty,
                  item.id == "blocker:\(profile.uuidString):\(rawEngine)", seen.insert(item.id).inserted,
                  let enabled = fields["enabled"].flatMap(Bool.init),
                  let rulesKind = fields["rulesKind"], ["bundled", "source"].contains(rulesKind),
                  let encoded = fields["exceptions"] else { throw SyncFailure.invalidRecord }
            let source = fields["source"].flatMap(URL.init(string:))
            guard (rulesKind == "bundled" && fields["source"] == nil) ||
                    (rulesKind == "source" && source.map(Self.safeBlockerSource) == true) else { throw SyncFailure.invalidRecord }
            let exceptions = encoded.isEmpty ? [] : encoded.components(separatedBy: "\n")
            guard exceptions.count <= 1000, Set(exceptions).count == exceptions.count,
                  exceptions.allSatisfy({ URL(string: $0).flatMap(AddressResolver.canonicalOrigin) == $0 }) else {
                throw SyncFailure.invalidRecord
            }
            if profiles.contains(where: { $0.id == profile }) {
                valid.append((profile, EngineID(rawValue: rawEngine), enabled, rulesKind, source, exceptions))
            }
        }
        for (profile, engineID, enabled, rulesKind, source, exceptions) in valid {
            try Task.checkCancellation()
            guard let blocker = engines.engine(engineID)?.contentBlocker else { continue }
            await blocker.waitUntilReady()
            try Task.checkCancellation()
            let hadRules = blocker.hasRules(profileID: profile)
            let originalEnabled = blocker.isEnabled(profileID: profile)
            let originalExceptions = Set(blocker.exceptions(profileID: profile))
            // A local subscription with a private URL must never be replaced by cloud state.
            if blocker.hasRules(profileID: profile),
               let localSource = blocker.updateSource(profileID: profile), !Self.safeBlockerSource(localSource) {
                throw SyncFailure.localWrite(String(localized: "A local content blocker source cannot be replaced by sync."))
            }
            if blocker.hasRules(profileID: profile), blocker.updateSource(profileID: profile) == nil,
               !blocker.usesBundledRules(profileID: profile) {
                throw SyncFailure.localWrite(String(localized: "Local custom content rules cannot be replaced by sync."))
            }
            if rulesKind == "bundled" && !blocker.usesBundledRules(profileID: profile) {
                await blocker.useBundledRules(profileID: profile)
                try Task.checkCancellation()
                guard blocker.usesBundledRules(profileID: profile) else {
                    throw EngineError.notReady(blocker.lastError ?? String(localized: "Could not install bundled content rules."))
                }
            }
            if let source, blocker.updateSource(profileID: profile) != source {
                try await blocker.installRules(from: source, profileID: profile)
                try Task.checkCancellation()
                guard blocker.updateSource(profileID: profile) == source else {
                    throw EngineError.notReady(blocker.lastError ?? String(localized: "Could not save content blocker source."))
                }
            }
            // Download/compilation yields to local controls. Do not overwrite a user's edit made then.
            if hadRules && (blocker.isEnabled(profileID: profile) != originalEnabled ||
                            Set(blocker.exceptions(profileID: profile)) != originalExceptions) {
                throw SyncFailure.unavailable(String(localized: "Content blocker settings changed locally during sync. Retrying."))
            }
            guard blocker.hasRules(profileID: profile) else {
                throw EngineError.notReady(String(localized: "Content rules are unavailable on this device."))
            }
            if blocker.isEnabled(profileID: profile) != enabled {
                await blocker.setEnabled(enabled, profileID: profile)
                try Task.checkCancellation()
                guard blocker.isEnabled(profileID: profile) == enabled else {
                    throw EngineError.notReady(blocker.lastError ?? String(localized: "Could not save content blocker state."))
                }
            }
            if hadRules && Set(blocker.exceptions(profileID: profile)) != originalExceptions {
                throw SyncFailure.unavailable(String(localized: "Content blocker exceptions changed locally during sync. Retrying."))
            }
            try await blocker.replaceExceptions(exceptions, profileID: profile)
        }
    }

    private static func safeBlockerSource(_ source: URL) -> Bool {
        guard let parts = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host?.isEmpty == false && parts.user == nil && parts.password == nil &&
            parts.query == nil && parts.fragment == nil && source.absoluteString.utf8.count <= 8192
    }
}
