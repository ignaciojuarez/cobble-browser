import AppKit
import Observation

enum BrowserThemePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case native, legacy, retro, custom
    var id: Self { self }

    var defaultFont: BrowserChromeFont { configuration.font }
    var loadingIndicator: TabLoadingIndicatorStyle { configuration.loadingIndicator }
    var defaultAccentHex: String { configuration.accentHex ?? "FFFFFF" }
}

enum TabLoadingIndicatorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case terminalSquares
    var id: Self { self }
}

enum BrowserChromeFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case rounded
    case serif
    case monospaced
    var id: Self { self }
}

@MainActor @Observable
final class BrowserPreferences {
    private struct Record: Codable {
        var version = 7
        var shortcuts: [String: BrowserShortcut] = [:]
        var defaultEngine: EngineID?
        var engineRules: [EngineRule]?
        var experimentalLoginSharing: Bool?
        var newTabsNextToActive: Bool?
        var cycleAllRecentTabs: Bool?
        var webInspectorEnabled: Bool?
        var searchEngines: [SearchEngine]?
        var defaultSearchEngineID: String?
        var downloadFolderBookmark: Data?
        var downloadFolderName: String?
        var tabLoadingIndicator: TabLoadingIndicatorStyle?
        var browserChromeFont: BrowserChromeFont?
        var theme: BrowserThemePreset? = .native
        var themeTemplate: BrowserThemePreset?
        var themeAccentHex: String?
        var windowStyle: BrowserWindowStyle?

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 7
            shortcuts = try container.decodeIfPresent([String: BrowserShortcut].self, forKey: .shortcuts) ?? [:]
            defaultEngine = try container.decodeIfPresent(EngineID.self, forKey: .defaultEngine)
            engineRules = try container.decodeIfPresent([EngineRule].self, forKey: .engineRules)
            experimentalLoginSharing = try container.decodeIfPresent(Bool.self, forKey: .experimentalLoginSharing)
            newTabsNextToActive = try container.decodeIfPresent(Bool.self, forKey: .newTabsNextToActive)
            cycleAllRecentTabs = try container.decodeIfPresent(Bool.self, forKey: .cycleAllRecentTabs)
            webInspectorEnabled = try container.decodeIfPresent(Bool.self, forKey: .webInspectorEnabled)
            searchEngines = try container.decodeIfPresent([SearchEngine].self, forKey: .searchEngines)
            defaultSearchEngineID = try container.decodeIfPresent(String.self, forKey: .defaultSearchEngineID)
            downloadFolderBookmark = try container.decodeIfPresent(Data.self, forKey: .downloadFolderBookmark)
            downloadFolderName = try container.decodeIfPresent(String.self, forKey: .downloadFolderName)
            tabLoadingIndicator = try container.decodeIfPresent(TabLoadingIndicatorStyle.self, forKey: .tabLoadingIndicator)
            browserChromeFont = try container.decodeIfPresent(BrowserChromeFont.self, forKey: .browserChromeFont)
            theme = try container.decodeIfPresent(BrowserThemePreset.self, forKey: .theme)
            themeTemplate = try container.decodeIfPresent(BrowserThemePreset.self, forKey: .themeTemplate)
            themeAccentHex = try container.decodeIfPresent(String.self, forKey: .themeAccentHex)
            windowStyle = try container.decodeIfPresent(BrowserWindowStyle.self, forKey: .windowStyle)
        }
    }
    private static let maximumDownloadFolderBookmarkSize = 1_048_576
    private var record = Record()
    private let url: URL
    private(set) var persistenceStatus: PersistenceStatus = .writable
    var readError: String? { persistenceStatus.readError }
    var errorMessage: String?
    @ObservationIgnored var onChange: (() -> Void)?
    init(directory: URL) {
        url = directory.appendingPathComponent("browser-preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            var loaded = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
            guard (1...7).contains(loaded.version),
                  loaded.defaultEngine?.rawValue.isEmpty != true,
                  Self.validDownloadFolder(bookmark: loaded.downloadFolderBookmark, name: loaded.downloadFolderName) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if loaded.theme == nil {
                loaded.theme = loaded.browserChromeFont != nil || loaded.tabLoadingIndicator != nil ? .custom : .legacy
                loaded.themeTemplate = .legacy
            }
            guard loaded.themeTemplate != .custom,
                  loaded.themeAccentHex.map(Self.validColorHex) ?? true else { throw CocoaError(.fileReadCorruptFile) }
            for command in BrowserCommand.allCases {
                if let shortcut = loaded.shortcuts[command.id] {
                    guard shortcut.isValid else { throw CocoaError(.fileReadCorruptFile) }
                }
            }
            record = loaded
            record.version = 7
            var hosts = Set<String>()
            for rule in record.engineRules ?? [] {
                guard !rule.engineID.rawValue.isEmpty,
                      let url = URL(string: "https://" + rule.host), EngineRule.host(for: url) == rule.host,
                      url.path.isEmpty, url.port == nil, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil, hosts.insert(rule.host).inserted else { throw CocoaError(.fileReadCorruptFile) }
            }
            let searchEngines = SearchEngine.builtIns + (record.searchEngines ?? [])
            guard (record.searchEngines ?? []).allSatisfy(\.isValid),
                  Set(searchEngines.map(\.id)).count == searchEngines.count,
                  Set(searchEngines.map(\.bang)).count == searchEngines.count else { throw CocoaError(.fileReadCorruptFile) }
            if let id = record.defaultSearchEngineID,
               !searchEngines.contains(where: { $0.id == id }) { throw CocoaError(.fileReadCorruptFile) }
            // A preserved custom binding wins over a newly introduced default.
            for command in BrowserCommand.allCases where record.shortcuts[command.id] == nil {
                if record.shortcuts.values.contains(command.defaultShortcut), !command.defaultShortcut.key.isEmpty {
                    record.shortcuts[command.id] = BrowserShortcut("")
                }
            }
            for command in BrowserCommand.allCases {
                guard conflict(for: shortcut(for: command), excluding: command) == nil else { throw CocoaError(.fileReadCorruptFile) }
            }
        } catch {
            record = Record()
            persistenceStatus = .readOnly(String(format: String(localized: "Could not read browser settings. Original file preserved; defaults are active. %@"), error.localizedDescription))
            errorMessage = readError
        }
    }
    var defaultEngine: EngineID { record.defaultEngine ?? .webKit }
    var experimentalLoginSharing: Bool { record.experimentalLoginSharing ?? false }
    var downloadFolderName: String? {
        Self.validDownloadFolder(bookmark: record.downloadFolderBookmark, name: record.downloadFolderName) ? record.downloadFolderName : nil
    }
    @discardableResult func setDownloadFolder(_ folder: URL?) -> Bool {
        var next = record
        guard let folder else {
            next.downloadFolderBookmark = nil; next.downloadFolderName = nil
            return save(next)
        }
        guard folder.isFileURL,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            errorMessage = String(localized: "Choose a folder for downloads."); return false
        }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        do {
            next.downloadFolderBookmark = try folder.bookmarkData(options: .withSecurityScope)
            next.downloadFolderName = folder.path == "/" ? "/" : folder.lastPathComponent
            guard Self.validDownloadFolder(bookmark: next.downloadFolderBookmark, name: next.downloadFolderName) else {
                throw CocoaError(.fileWriteFileExists)
            }
            return save(next)
        } catch {
            errorMessage = String(format: String(localized: "Could not save the download folder: %@"), error.localizedDescription)
            return false
        }
    }
    /// The caller owns the returned security scope until its native panel closes.
    func beginDownloadFolder() -> URL? {
        guard Self.validDownloadFolder(bookmark: record.downloadFolderBookmark, name: record.downloadFolderName),
              let bookmark = record.downloadFolderBookmark else { return nil }
        do {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale, let freshBookmark = try? folder.bookmarkData(options: .withSecurityScope) {
                var next = record
                next.downloadFolderBookmark = freshBookmark
                _ = save(next)
            }
            guard folder.isFileURL,
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileNoSuchFile) }
            return folder
        } catch {
            errorMessage = String(localized: "The selected download folder is unavailable. Choose it again in Settings.")
            return nil
        }
    }
    func endDownloadFolder(_ folder: URL) { folder.stopAccessingSecurityScopedResource() }

    private static func validDownloadFolder(bookmark: Data?, name: String?) -> Bool {
        switch (bookmark, name) {
        case (nil, nil): true
        case let (.some(bookmark), .some(name)):
            !bookmark.isEmpty && bookmark.count <= maximumDownloadFolderBookmarkSize &&
                !name.isEmpty && name.utf8.count <= 255 &&
                (name == "/" || (!name.contains("/") && !name.contains("\\")))
        default: false
        }
    }
    var newTabsNextToActive: Bool { record.newTabsNextToActive ?? false }
    var cycleAllRecentTabs: Bool { record.cycleAllRecentTabs ?? false }
    var webInspectorEnabled: Bool { record.webInspectorEnabled ?? false }
    var tabLoadingIndicator: TabLoadingIndicatorStyle { record.tabLoadingIndicator ?? themeTemplate.loadingIndicator }
    var browserChromeFont: BrowserChromeFont { record.browserChromeFont ?? themeTemplate.defaultFont }
    var theme: BrowserThemePreset { record.theme ?? .native }
    var themeTemplate: BrowserThemePreset {
        let candidate = theme == .custom ? record.themeTemplate ?? .legacy : theme
        return candidate == .custom ? .legacy : candidate
    }
    var windowStyle: BrowserWindowStyle { record.windowStyle ?? themeTemplate.configuration.defaultWindowStyle ?? .rounded }
    var themeAccentColor: NSColor { Self.color(hex: theme == .custom ? record.themeAccentHex ?? themeTemplate.defaultAccentHex : themeTemplate.defaultAccentHex) }
    @discardableResult func setNewTabsNextToActive(_ enabled: Bool) -> Bool {
        var next = record; next.newTabsNextToActive = enabled; return save(next)
    }
    @discardableResult func setCycleAllRecentTabs(_ enabled: Bool) -> Bool {
        var next = record; next.cycleAllRecentTabs = enabled; return save(next)
    }
    @discardableResult func setWebInspectorEnabled(_ enabled: Bool) -> Bool {
        var next = record; next.webInspectorEnabled = enabled; return save(next)
    }
    @discardableResult func setTabLoadingIndicator(_ style: TabLoadingIndicatorStyle) -> Bool {
        guard style != tabLoadingIndicator else { return true }
        var next = record; next.tabLoadingIndicator = style; markCustom(&next); return save(next)
    }
    @discardableResult func setBrowserChromeFont(_ font: BrowserChromeFont) -> Bool {
        guard font != browserChromeFont else { return true }
        var next = record; next.browserChromeFont = font; markCustom(&next); return save(next)
    }
    @discardableResult func setTheme(_ theme: BrowserThemePreset) -> Bool {
        guard theme != .custom else { return false }
        var next = record
        next.theme = theme
        next.themeTemplate = theme
        next.browserChromeFont = theme.defaultFont
        next.tabLoadingIndicator = theme.loadingIndicator
        next.themeAccentHex = theme.defaultAccentHex
        next.windowStyle = theme.configuration.defaultWindowStyle ?? windowStyle
        return save(next)
    }
    @discardableResult func setWindowStyle(_ style: BrowserWindowStyle) -> Bool {
        guard style != windowStyle else { return true }
        var next = record; next.windowStyle = style; return save(next)
    }
    @discardableResult func setThemeAccentColor(_ color: NSColor) -> Bool {
        guard let hex = Self.hex(color) else { return false }
        guard hex != (theme == .custom ? record.themeAccentHex ?? themeTemplate.defaultAccentHex : themeTemplate.defaultAccentHex) else { return true }
        var next = record; next.themeAccentHex = hex; markCustom(&next); return save(next)
    }
    var engineRules: [EngineRule] { record.engineRules ?? [] }
    var searchEngines: [SearchEngine] { SearchEngine.builtIns + (record.searchEngines ?? []) }
    var defaultSearchEngine: SearchEngine {
        searchEngines.first { $0.id == record.defaultSearchEngineID } ?? .duckDuckGo
    }
    func bangSuggestions(for input: String) -> [SearchEngine] {
        SearchEngine.bangSuggestions(for: input, engines: searchEngines)
    }
    @discardableResult func setDefaultSearchEngine(_ id: String) -> Bool {
        guard searchEngines.contains(where: { $0.id == id }) else { errorMessage = String(localized: "Choose an available search engine."); return false }
        var next = record; next.defaultSearchEngineID = id; return save(next)
    }
    @discardableResult func addSearchEngine(name: String, template: String, bang: String) -> Bool {
        guard let engine = SearchEngine(id: UUID().uuidString.lowercased(), name: name, template: template, bang: bang) else {
            errorMessage = String(localized: "Use an HTTP or HTTPS template with one {searchTerms} placeholder and a short bang."); return false
        }
        var next = record
        guard !(SearchEngine.builtIns + (next.searchEngines ?? [])).contains(where: { $0.bang == engine.bang }) else {
            errorMessage = String(localized: "That bang is already in use."); return false
        }
        next.searchEngines = (next.searchEngines ?? []) + [engine]
        return save(next)
    }
    @discardableResult func updateSearchEngine(id: String, name: String, template: String, bang: String) -> Bool {
        guard let index = (record.searchEngines ?? []).firstIndex(where: { $0.id == id }),
              let engine = SearchEngine(id: id, name: name, template: template, bang: bang) else {
            errorMessage = String(localized: "Use an HTTP or HTTPS template with one {searchTerms} placeholder and a short bang."); return false
        }
        var next = record
        let others = SearchEngine.builtIns + (next.searchEngines ?? []).enumerated().compactMap { $0.offset == index ? nil : $0.element }
        guard !others.contains(where: { $0.bang == engine.bang }) else { errorMessage = String(localized: "That bang is already in use."); return false }
        next.searchEngines?[index] = engine
        return save(next)
    }
    @discardableResult func removeSearchEngine(_ id: String) -> Bool {
        guard let index = (record.searchEngines ?? []).firstIndex(where: { $0.id == id }) else { return false }
        var next = record; next.searchEngines?.remove(at: index)
        if next.defaultSearchEngineID == id { next.defaultSearchEngineID = SearchEngine.duckDuckGo.id }
        return save(next)
    }
    func engine(for url: URL, override: EngineID? = nil) -> EngineID {
        override ?? engineRules.first(where: { $0.host == EngineRule.host(for: url) })?.engineID ?? defaultEngine
    }
    @discardableResult func setDefaultEngine(_ id: EngineID) -> Bool {
        guard !id.rawValue.isEmpty else { errorMessage = String(localized: "Choose an available browser engine."); return false }
        var next = record; next.defaultEngine = id; return save(next)
    }
    @discardableResult func setExperimentalLoginSharing(_ enabled: Bool) -> Bool {
        var next = record; next.experimentalLoginSharing = enabled; return save(next)
    }
    @discardableResult func setEngineRule(for url: URL, engineID: EngineID?) -> Bool {
        guard let host = EngineRule.host(for: url) else { errorMessage = String(localized: "Engine rules require an HTTP or HTTPS host."); return false }
        guard engineID?.rawValue.isEmpty != true else { errorMessage = String(localized: "Choose an available browser engine."); return false }
        var next = record
        var rules = engineRules.filter { $0.host != host }
        if let engineID { rules.append(EngineRule(host: host, engineID: engineID)) }
        next.engineRules = rules.sorted { $0.host < $1.host }
        return save(next)
    }
    func shortcut(for command: BrowserCommand) -> BrowserShortcut { record.shortcuts[command.id] ?? command.defaultShortcut }
    func conflict(for shortcut: BrowserShortcut, excluding command: BrowserCommand) -> String? {
        guard !shortcut.key.isEmpty else { return nil }
        // Keep responder-chain editing and macOS application commands intact.
        let native: [(String, BrowserShortcut)] = [
            ("Quit", .init("q")), ("Hide", .init("h")), ("Minimize", .init("m")),
            ("Undo", .init("z")), ("Redo", .init("z", [.command, .shift])),
            ("Cut", .init("x")), ("Copy", .init("c")), ("Paste", .init("v")), ("Select All", .init("a")),
            ("Switch Apps", .init("\t")), ("Switch Apps", .init("\t", [.command, .shift])),
            ("Spotlight", .init(" ")), ("Input Source", .init(" ", .control)),
            ("Screenshot", .init("3", [.command, .shift])), ("Screenshot", .init("4", [.command, .shift])),
            ("Screenshot", .init("5", [.command, .shift])), ("Lock Screen", .init("q", [.command, .control])),
            ("Switch Windows", .init("`")), ("Full Screen", .init("f", [.command, .control])),
            ("Space 1", .init("1", .command)), ("Space 2", .init("2", .command)), ("Space 3", .init("3", .command)),
            ("Space 4", .init("4", .command)), ("Space 5", .init("5", .command)), ("Space 6", .init("6", .command)),
            ("Space 7", .init("7", .command)), ("Space 8", .init("8", .command)), ("Space 9", .init("9", .command))]
        if let match = native.first(where: { $0.1 == shortcut }) { return NSLocalizedString(match.0, comment: "Reserved macOS shortcut") }
        return BrowserCommand.allCases.first { $0 != command && self.shortcut(for: $0) == shortcut }?.title
    }
    @discardableResult func set(_ shortcut: BrowserShortcut, for command: BrowserCommand) -> Bool {
        guard shortcut.isValid else { errorMessage = String(localized: "Use Command or Control with a key."); return false }
        if let conflict = conflict(for: shortcut, excluding: command) {
            errorMessage = String(format: String(localized: "Already used by %@. Change that shortcut first."), conflict); return false
        }
        var next = record; next.shortcuts[command.id] = shortcut
        return save(next)
    }
    func resetShortcuts() { var next = record; next.shortcuts = [:]; save(next) }
    /// Explicit recovery only: never replace unreadable settings before preserving their bytes.
    @discardableResult func resetUnreadableSettings() -> URL? {
        guard readError != nil else { return nil }
        do {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("browser-preferences-backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: backup)
            let defaults = Record()
            try PersistenceFile.save(defaults, to: url)
            record = defaults; persistenceStatus = .writable; errorMessage = nil; onChange?()
            return backup
        } catch {
            errorMessage = String(format: String(localized: "Could not reset browser settings: %@"), error.localizedDescription)
            return nil
        }
    }

    func syncItems() -> [SyncItem] {
        let customEngines = (record.searchEngines ?? []).filter { Self.safeSearchTemplate($0.template) }
        let syncedDefault = (SearchEngine.builtIns + customEngines).contains(where: { $0.id == defaultSearchEngine.id })
            ? defaultSearchEngine.id : SearchEngine.duckDuckGo.id
        var items = [SyncItem(id: "preferences", module: .preferences, kind: "settings", fields: [
            "defaultSearchEngineID": syncedDefault,
            "newTabsNextToActive": String(newTabsNextToActive),
            "cycleAllRecentTabs": String(cycleAllRecentTabs)
        ])]
        items += customEngines.map { engine in
            SyncItem(id: "search:\(engine.id)", module: .preferences, kind: "searchEngine", fields: [
                "id": engine.id, "name": engine.name, "template": engine.template, "bang": engine.bang
            ])
        }
        items += record.shortcuts.filter { id, _ in BrowserCommand.allCases.contains(where: { $0.id == id }) }.map { id, shortcut in
            let flags = shortcut.flags
            return SyncItem(id: "shortcut:\(id)", module: .preferences, kind: "shortcut", fields: [
                "command": id, "key": shortcut.key,
                "modifiers": [flags.contains(.command) ? "command" : nil,
                              flags.contains(.control) ? "control" : nil,
                              flags.contains(.option) ? "option" : nil,
                              flags.contains(.shift) ? "shift" : nil].compactMap { $0 }.joined(separator: ",")
            ])
        }
        return items
    }

    func applySyncItems(_ items: [SyncItem]) throws {
        guard readError == nil else { throw CocoaError(.fileReadCorruptFile) }
        var next = record
        var customEngines: [SearchEngine] = []
        var shortcuts: [String: BrowserShortcut] = [:]
        var settings: SyncItem?
        var ids = Set<String>()
        for item in items {
            guard item.module == .preferences, ids.insert(item.id).inserted else { throw CocoaError(.coderReadCorrupt) }
            switch item.kind {
            case "settings":
                guard item.id == "preferences", settings == nil else { throw CocoaError(.coderReadCorrupt) }
                settings = item
            case "searchEngine":
                let fields = item.fields
                guard let id = fields["id"], item.id == "search:\(id)",
                      let name = fields["name"], let template = fields["template"], let bang = fields["bang"],
                      let engine = SearchEngine(id: id, name: name, template: template, bang: bang),
                      Self.safeSearchTemplate(template),
                      !SearchEngine.builtIns.contains(where: { $0.id == id }) else { throw CocoaError(.coderReadCorrupt) }
                customEngines.append(engine)
            case "shortcut":
                let fields = item.fields
                guard let id = fields["command"], item.id == "shortcut:\(id)",
                      let key = fields["key"], let encoded = fields["modifiers"] else { throw CocoaError(.coderReadCorrupt) }
                guard BrowserCommand.allCases.contains(where: { $0.id == id }) else { continue }
                var flags: NSEvent.ModifierFlags = []
                for modifier in encoded.split(separator: ",") {
                    switch modifier {
                    case "command": flags.insert(.command)
                    case "control": flags.insert(.control)
                    case "option": flags.insert(.option)
                    case "shift": flags.insert(.shift)
                    default: throw CocoaError(.coderReadCorrupt)
                    }
                }
                let shortcut = BrowserShortcut(key, flags)
                guard shortcut.key == key, shortcut.isValid else { throw CocoaError(.coderReadCorrupt) }
                shortcuts[id] = shortcut
            default: throw CocoaError(.coderReadCorrupt)
            }
        }
        guard let fields = settings?.fields,
              let defaultID = fields["defaultSearchEngineID"],
              let nextToActive = fields["newTabsNextToActive"].flatMap(Bool.init),
              let cycle = fields["cycleAllRecentTabs"].flatMap(Bool.init),
              Set(customEngines.map(\.id)).count == customEngines.count else { throw CocoaError(.coderReadCorrupt) }
        let localOnlyEngines = (record.searchEngines ?? []).filter { !Self.safeSearchTemplate($0.template) }
        let engines = SearchEngine.builtIns + customEngines + localOnlyEngines
        guard Set(engines.map(\.bang)).count == engines.count,
              Set(engines.map(\.id)).count == engines.count,
              engines.contains(where: { $0.id == defaultID }) else { throw CocoaError(.coderReadCorrupt) }
        next.searchEngines = customEngines + localOnlyEngines
        next.defaultSearchEngineID = localOnlyEngines.contains(where: { $0.id == record.defaultSearchEngineID })
            ? record.defaultSearchEngineID : defaultID
        next.newTabsNextToActive = nextToActive
        next.cycleAllRecentTabs = cycle
        next.shortcuts = record.shortcuts.filter { id, _ in !BrowserCommand.allCases.contains(where: { $0.id == id }) }
        next.shortcuts.merge(shortcuts) { _, remote in remote }
        for command in BrowserCommand.allCases where next.shortcuts[command.id] == nil {
            if next.shortcuts.values.contains(command.defaultShortcut), !command.defaultShortcut.key.isEmpty {
                next.shortcuts[command.id] = BrowserShortcut("")
            }
        }
        let previous = record
        record = next
        let validShortcuts = BrowserCommand.allCases.allSatisfy { conflict(for: shortcut(for: $0), excluding: $0) == nil }
        record = previous
        guard validShortcuts else {
            throw CocoaError(.coderReadCorrupt)
        }
        if next.searchEngines == record.searchEngines && next.defaultSearchEngineID == record.defaultSearchEngineID &&
            next.newTabsNextToActive == record.newTabsNextToActive &&
            next.cycleAllRecentTabs == record.cycleAllRecentTabs && next.shortcuts == record.shortcuts { return }
        guard save(next) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func safeSearchTemplate(_ template: String) -> Bool {
        guard template.utf8.count <= 8192,
              let parts = URLComponents(string: template.replacingOccurrences(of: SearchEngine.placeholder, with: "query")) else { return false }
        let sensitive = Set(["access_token", "id_token", "refresh_token", "oauth_token", "token",
                             "api_key", "apikey", "client_secret", "password", "secret", "session", "code"])
        return !(parts.queryItems ?? []).contains { sensitive.contains($0.name.lowercased()) } &&
            !sensitive.contains { parts.fragment?.lowercased().contains($0 + "=") == true }
    }

    @discardableResult private func save(_ next: Record) -> Bool {
        guard readError == nil else {
            errorMessage = readError
            return false
        }
        do {
            try PersistenceFile.save(next, to: url)
            record = next; errorMessage = nil; onChange?(); return true
        } catch { errorMessage = String(format: String(localized: "Could not save settings: %@"), error.localizedDescription); return false }
    }

    private func markCustom(_ next: inout Record) {
        if theme != .custom { next.themeTemplate = themeTemplate }
        next.theme = .custom
    }

    private static func validColorHex(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func color(hex: String) -> NSColor {
        guard validColorHex(hex), let value = Int(hex, radix: 16) else { return .white }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        let components = [converted.redComponent, converted.greenComponent, converted.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        return components.map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }
}
