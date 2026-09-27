import Foundation
import Observation
import WebKit

@MainActor @Observable
final class WebKitContentBlocker: EngineContentBlocker {
    let formatName = "WebKit JSON"
    // Original Cobble rules: no third-party list or license is bundled.
    static let bundledRules = #"""
    [
      {"trigger":{"url-filter":"^https?://([^/?#@]+@)?([^/?#@:.]+\\.)*doubleclick\\.net(:[0-9]+)?([/?#].*)?$","load-type":["third-party"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://([^/?#@]+@)?([^/?#@:.]+\\.)*googlesyndication\\.com(:[0-9]+)?([/?#].*)?$","load-type":["third-party"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://([^/?#@]+@)?([^/?#@:.]+\\.)*google-analytics\\.com(:[0-9]+)?([/?#].*)?$","load-type":["third-party"]},"action":{"type":"block"}}
    ]
    """#
    private static let maximumRulesSize = 1_000_000
    func canLoad(profileID: UUID) -> Bool { !isEnabled(profileID: profileID) || rules(for: profileID) != nil }
    var lastError: String?
    private(set) var revision = 0
    private(set) var isReady = true
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var profileMutationAllowed: ((UUID) -> Bool)?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let compiler: WKContentRuleListStore?
    @ObservationIgnored private var configurations: [UUID: Configuration] = [:]
    @ObservationIgnored private var compiled: [UUID: WKContentRuleList] = [:]
    @ObservationIgnored private var operations: [UUID: UUID] = [:]
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    private struct Configuration: Codable {
        var profileID: UUID
        var json: String
        var enabled: Bool
        var exceptions: [String]
        var identifier: String
        var source: Source?
    }
    private struct Source: Codable, Equatable {
        var url: String
        var lastUpdated: Date?
    }
    private struct Snapshot: Codable { var version = 2; var configurations: [Configuration] }
    private var url: URL { directory.appendingPathComponent("content-blockers.json") }
    var canPersistRules: Bool { canSave }

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cobble", isDirectory: true)
        self.directory = directory
        let cache = directory.appendingPathComponent("ContentRuleLists", isDirectory: true)
        do { try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true) }
        catch { compiler = nil; canSave = false; lastError = String(format: String(localized: "Could not create the content blocker cache: %@"), error.localizedDescription); return }
        compiler = WKContentRuleListStore(url: cache)
        guard compiler != nil else { canSave = false; lastError = String(localized: "The content blocker compiler is unavailable."); return }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        catch { canSave = false; lastError = String(format: String(localized: "Content blocker settings could not be read. Saving is disabled: %@"), error.localizedDescription); return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard (1...2).contains(snapshot.version) else { throw CocoaError(.coderReadCorrupt) }
            for configuration in snapshot.configurations {
                guard configurations[configuration.profileID] == nil, configuration.json.utf8.count <= Self.maximumRulesSize,
                      !configuration.identifier.isEmpty,
                      configuration.source.map({ Self.validUpdateSource(URL(string: $0.url)) }) ?? true,
                      configuration.exceptions.allSatisfy({ value in
                          URL(string: value).flatMap(AddressResolver.canonicalOrigin) == value
                      }) else { throw CocoaError(.coderReadCorrupt) }
                _ = try Self.encodedRules(configuration)
                configurations[configuration.profileID] = configuration
            }
            isReady = false
            restoreTask = Task { [weak self] in
                guard let self else { return }
                await restore()
                isReady = true
                changed()
            }
        } catch {
            configurations = [:]
            canSave = false
            let preserved = directory.appendingPathComponent("content-blockers.corrupt-\(UUID()).json")
            do {
                try data.write(to: preserved, options: .atomic)
                lastError = String(localized: "Content blocker settings are unreadable or use an unsupported format. The original was preserved; saving is disabled.")
            } catch { lastError = String(localized: "Content blocker settings are unreadable. The original is untouched; saving is disabled.") }
        }
    }

    func isEnabled(profileID: UUID) -> Bool {
        _ = revision
        return configurations[profileID]?.enabled ?? false
    }

    func waitUntilReady() async { await restoreTask?.value }

    func hasRules(profileID: UUID) -> Bool {
        _ = revision
        return configurations[profileID] != nil
    }

    func usesBundledRules(profileID: UUID) -> Bool {
        configurations[profileID]?.json == Self.bundledRules && configurations[profileID]?.source == nil
    }

    func useBundledRules(profileID: UUID) async {
        if hasRules(profileID: profileID) { await importRules(json: Self.bundledRules, profileID: profileID) }
        else { await installBundledRules(profileID: profileID) }
    }

    func exceptions(profileID: UUID) -> [String] {
        _ = revision
        return configurations[profileID]?.exceptions ?? []
    }

    func rules(for profileID: UUID) -> WKContentRuleList? {
        _ = revision
        return isEnabled(profileID: profileID) ? compiled[profileID] : nil
    }

    func importRules(json: String, profileID: UUID) async {
        guard beginMutation(profileID) else { return }
        guard canSave else { return }
        guard json.utf8.count <= Self.maximumRulesSize else { lastError = String(localized: "Content blocker files must be no larger than 1 MB."); return }
        let previous = configurations[profileID]
        let configuration = Configuration(profileID: profileID, json: json, enabled: previous?.enabled ?? true,
                                          exceptions: previous?.exceptions ?? [], identifier: "", source: nil)
        await compileAndCommit(configuration)
    }

    func installBundledRules(profileID: UUID) async {
        guard beginMutation(profileID), canSave else { return }
        guard configurations[profileID] == nil else {
            lastError = String(localized: "This profile already has rules. Import a replacement to change them.")
            return
        }
        await compileAndCommit(Configuration(profileID: profileID, json: Self.bundledRules, enabled: true,
                                           exceptions: [], identifier: "", source: nil))
    }

    func ensureBundledRules(profileID: UUID) async {
        guard configurations[profileID] == nil else { return }
        await installBundledRules(profileID: profileID)
    }

    func updateSource(profileID: UUID) -> URL? {
        _ = revision
        return configurations[profileID].flatMap { URL(string: $0.source?.url ?? "") }
    }

    func setUpdateSource(_ source: URL?, profileID: UUID) async {
        guard beginMutation(profileID), canSave, var configuration = configurations[profileID] else {
            lastError = String(localized: "Install or import rules before choosing an update source.")
            return
        }
        guard source == nil || Self.validUpdateSource(source) else {
            lastError = String(localized: "Update sources must be HTTPS addresses without credentials or fragments.")
            return
        }
        configuration.source = source.map { Source(url: $0.absoluteString, lastUpdated: nil) }
        operations[profileID] = UUID()
        guard persist(configuration) else { return }
        configurations[profileID] = configuration
        lastError = nil
        changed()
    }

    func updateRules(profileID: UUID) async {
        guard beginMutation(profileID), canSave, let configuration = configurations[profileID], let source = configuration.source,
              let url = URL(string: source.url) else {
            lastError = String(localized: "Choose an HTTPS update source first.")
            return
        }
        let operation = UUID()
        operations[profileID] = operation
        do {
            let json = try await Self.downloadRules(from: url)
            guard !Task.isCancelled else { return }
            guard beginMutation(profileID), operations[profileID] == operation,
                  configurations[profileID]?.source == source else { return }
            var next = configuration
            next.json = json
            next.source?.lastUpdated = Date()
            await compileAndCommit(next)
        } catch {
            lastError = String(format: String(localized: "Could not update rules. Existing rules are unchanged: %@"), error.localizedDescription)
        }
    }

    func installRules(from source: URL, profileID: UUID) async throws {
        guard beginMutation(profileID), canSave, Self.validUpdateSource(source) else {
            throw EngineError.notReady(String(localized: "Update sources must be HTTPS addresses without credentials or fragments."))
        }
        let operation = UUID()
        operations[profileID] = operation
        defer { if operations[profileID] == operation { operations.removeValue(forKey: profileID) } }
        let json = try await Self.downloadRules(from: source)
        try Task.checkCancellation()
        guard beginMutation(profileID), canSave, operations[profileID] == operation else { throw EngineError.closed }
        var next = configurations[profileID] ?? Configuration(profileID: profileID, json: json,
            enabled: true, exceptions: [], identifier: "", source: nil)
        next.json = json
        next.source = Source(url: source.absoluteString, lastUpdated: Date())
        await compileAndCommit(next)
        guard configurations[profileID]?.source?.url == source.absoluteString,
              configurations[profileID]?.json == json, lastError == nil else {
            throw EngineError.notReady(lastError ?? String(localized: "Could not install content rules from the update source."))
        }
    }

    func setEnabled(_ enabled: Bool, profileID: UUID) async {
        guard beginMutation(profileID) else { return }
        guard canSave, var configuration = configurations[profileID] else { return }
        // Finish startup restoration before changing enabled state, so re-enabling has a live list.
        await restoreTask?.value
        guard !Task.isCancelled else { return }
        guard beginMutation(profileID) else { return }
        guard let current = configurations[profileID] else { return }
        configuration = current
        configuration.enabled = enabled
        if enabled && compiled[profileID] == nil { await compileAndCommit(configuration); return }
        operations[profileID] = UUID()
        guard persist(configuration) else { return }
        configurations[profileID] = configuration
        lastError = nil
        changed()
    }

    func setException(origin: URL, enabled: Bool, profileID: UUID) async {
        guard beginMutation(profileID) else { return }
        guard canSave, var configuration = configurations[profileID] else { return }
        guard let origin = AddressResolver.canonicalOrigin(origin) else {
            lastError = String(localized: "Content blocker exceptions require an HTTP or HTTPS origin."); return
        }
        configuration.exceptions.removeAll { $0 == origin }
        if enabled { configuration.exceptions.append(origin) }
        configuration.exceptions.sort()
        await compileAndCommit(configuration)
    }

    func replaceExceptions(_ origins: [String], profileID: UUID) async throws {
        guard beginMutation(profileID), canSave, var configuration = configurations[profileID] else {
            throw EngineError.notReady(lastError ?? String(localized: "Content rules are unavailable."))
        }
        guard origins.count <= 1000, Set(origins).count == origins.count,
              origins.allSatisfy({ URL(string: $0).flatMap(AddressResolver.canonicalOrigin) == $0 }) else {
            throw EngineError.notReady(String(localized: "Invalid content blocker exception."))
        }
        let desired = origins.sorted()
        guard configuration.exceptions != desired else { return }
        configuration.exceptions = desired
        await compileAndCommit(configuration)
        guard configurations[profileID]?.exceptions == desired, lastError == nil else {
            throw EngineError.notReady(lastError ?? String(localized: "Could not save content blocker exceptions."))
        }
    }

    func removeProfile(_ profileID: UUID) async throws {
        guard canSave else { throw EngineError.notReady(lastError ?? String(localized: "Content blocker changes are disabled.")) }
        await restoreTask?.value
        guard let configuration = configurations[profileID] else { return }
        operations[profileID] = UUID()
        if !configuration.identifier.isEmpty { try await compiler?.removeContentRuleList(forIdentifier: configuration.identifier) }
        var next = configurations
        next.removeValue(forKey: profileID)
        do {
            let records = next.values.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
            try JSONEncoder().encode(Snapshot(configurations: records)).write(to: url, options: .atomic)
        } catch {
            lastError = String(format: String(localized: "Content blocker settings could not be saved: %@"), error.localizedDescription)
            throw error
        }
        configurations = next
        compiled.removeValue(forKey: profileID)
        lastError = nil
        changed()
    }

    /// Exposed internally for deterministic checks of the exact origin boundary.
    static func exceptionPatterns(origin: String) -> [String] {
        let prefix = "^" + NSRegularExpression.escapedPattern(for: origin)
        // WebKit's rule compiler does not support regex alternation.
        return [prefix + "[/?#]", prefix + "$"]
    }

    private static func validUpdateSource(_ source: URL?) -> Bool {
        guard let source, source.absoluteString.utf8.count <= 2_048,
              source.scheme?.lowercased() == "https", source.host?.isEmpty == false,
              source.user == nil, source.password == nil, source.fragment == nil else { return false }
        return true
    }

    static func downloadRules(from source: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
        try await downloadContentRules(from: source, configuration: configuration)
    }

    private static func encodedRules(_ configuration: Configuration) throws -> String {
        let data = Data(configuration.json.utf8)
        guard var rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        if !configuration.exceptions.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "if-top-url": configuration.exceptions.flatMap { exceptionPatterns(origin: $0) }],
                "action": ["type": "ignore-previous-rules"]
            ])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
    }

    private func compileAndCommit(_ proposed: Configuration) async {
        guard let compiler else { lastError = String(localized: "The content blocker compiler is unavailable."); return }
        let encoded: String
        do { encoded = try Self.encodedRules(proposed) }
        catch { lastError = String(localized: "The content blocker file must contain a WebKit JSON rule array."); return }
        let operation = UUID()
        operations[proposed.profileID] = operation
        var next = proposed
        next.identifier = "Cobble-\(proposed.profileID)-\(operation)"
        let list: WKContentRuleList
        do {
            guard let result = try await compiler.compileContentRuleList(forIdentifier: next.identifier, encodedContentRuleList: encoded) else {
                throw CocoaError(.coderReadCorrupt)
            }
            list = result
        } catch {
            if operations[proposed.profileID] == operation { lastError = String(format: String(localized: "Content blocker compilation failed: %@"), error.localizedDescription) }
            return
        }
        guard !Task.isCancelled, operations[proposed.profileID] == operation, canSave, beginMutation(proposed.profileID) else {
            try? await compiler.removeContentRuleList(forIdentifier: next.identifier); return
        }
        let oldIdentifier = configurations[proposed.profileID]?.identifier
        guard persist(next) else { try? await compiler.removeContentRuleList(forIdentifier: next.identifier); return }
        configurations[proposed.profileID] = next
        compiled[proposed.profileID] = list
        lastError = nil
        changed()
        if let oldIdentifier, oldIdentifier != next.identifier { try? await compiler.removeContentRuleList(forIdentifier: oldIdentifier) }
    }

    private func persist(_ configuration: Configuration) -> Bool {
        var next = configurations
        next[configuration.profileID] = configuration
        do {
            let records = next.values.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
            try JSONEncoder().encode(Snapshot(configurations: records)).write(to: url, options: .atomic)
            return true
        } catch { lastError = String(format: String(localized: "Content blocker settings could not be saved: %@"), error.localizedDescription); return false }
    }

    private func restore() async {
        guard let compiler else { return }
        let saved = Array(configurations.values)
        for configuration in saved {
            guard operations[configuration.profileID] == nil else { continue }
            let operation = UUID()
            operations[configuration.profileID] = operation
            if let list = try? await compiler.contentRuleList(forIdentifier: configuration.identifier) {
                guard operations[configuration.profileID] == operation else { continue }
                compiled[configuration.profileID] = list
                changed()
            } else {
                guard operations[configuration.profileID] == operation else { continue }
                await compileAndCommit(configuration)
            }
        }
    }

    private func changed() { revision += 1; onChange?() }

    private func beginMutation(_ profileID: UUID) -> Bool {
        guard profileMutationAllowed?(profileID) != false else {
            lastError = String(localized: "This profile is being deleted. Try again when cleanup finishes.")
            return false
        }
        return true
    }
}
