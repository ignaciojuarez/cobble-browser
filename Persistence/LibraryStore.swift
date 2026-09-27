import Foundation
import Observation
import SQLite3
import CryptoKit

struct LibraryEntry: Identifiable, Hashable, Sendable {
    var id: Int64
    var urlString: String
    var title: String
    var visitedAt: Date
    /// SQLite library bookmark; not a sidebar pin or favorite.
    var isBookmark: Bool
    var engineID: EngineID = .webKit
}

@MainActor @Observable
final class LibraryStore {
    private static let anchorsRegex = try! NSRegularExpression(pattern: #"(?is)<a\b([^>]*)>(.*?)</a\s*>"#)
    private static let hrefRegex = try! NSRegularExpression(pattern: #"(?is)(?:^|\s)href\s*=\s*(["'])(.*?)\1"#)
    private static let htmlEntityRegex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);"#)

    var lastError: String?
    @ObservationIgnored var mutationsAllowed: (() -> Bool)?
    @ObservationIgnored var onSyncHistoryDeletion: (([SyncItem]) throws -> Void)?
    private(set) var revision = 0
    // Methods stay on MainActor; only final destruction may close the FULLMUTEX handle elsewhere.
    @ObservationIgnored nonisolated(unsafe) private var database: OpaquePointer?
    private var initializationError: String?
    private enum Value { case text(String), number(Double), integer(Int64) }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil) {
        var initialized = false
        defer {
            if !initialized {
                initializationError = lastError
                if let database { sqlite3_close(database) }
                database = nil
            }
        }
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cobble", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { lastError = String(format: String(localized: "Could not create the library folder: %@"), error.localizedDescription); return }
        guard sqlite3_open_v2(directory.appendingPathComponent("library.sqlite").path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            reportError(); return
        }
        sqlite3_busy_timeout(database, 1500)
        guard let versionQuery = prepare("PRAGMA user_version", []) else { return }
        let version = sqlite3_step(versionQuery) == SQLITE_ROW ? sqlite3_column_int(versionQuery, 0) : -1
        sqlite3_finalize(versionQuery)
        guard (0...3).contains(version) else {
            lastError = String(localized: "The library uses an unreadable or newer format. The original database was preserved.")
            return
        }
        guard execute("PRAGMA journal_mode = WAL") else { return }
        guard execute("""
            CREATE TABLE IF NOT EXISTS entries (
                id INTEGER PRIMARY KEY,
                profile_id TEXT NOT NULL,
                url TEXT NOT NULL,
                title TEXT NOT NULL,
                visited_at REAL NOT NULL,
                in_history INTEGER NOT NULL DEFAULT 0,
                is_bookmark INTEGER NOT NULL DEFAULT 0,
                UNIQUE(profile_id, url)
            )
            """) else { return }
        if let columns = prepare("PRAGMA table_info(entries)", []) {
            var names = Set<String>()
            while sqlite3_step(columns) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(columns, 1))) }
            sqlite3_finalize(columns)
            let required = Set(["id", "profile_id", "url", "title", "visited_at", "in_history", "is_bookmark"])
            guard required.isSubset(of: names), version < 3 || names.contains("bookmark_title") else {
                lastError = String(localized: "The library uses an unreadable or newer format. The original database was preserved.")
                return
            }
            if !names.contains("engine_id") {
                guard execute("ALTER TABLE entries ADD COLUMN engine_id TEXT NOT NULL DEFAULT 'webkit'") else { return }
            }
        } else { return }
        if version < 3 {
            guard execute("BEGIN IMMEDIATE") else { return }
            guard execute("ALTER TABLE entries ADD COLUMN bookmark_title TEXT NOT NULL DEFAULT ''"),
                  execute("UPDATE entries SET bookmark_title = title WHERE is_bookmark = 1"),
                  execute("PRAGMA user_version = 3"), execute("COMMIT") else {
                _ = execute("ROLLBACK"); return
            }
        }
        guard execute("CREATE INDEX IF NOT EXISTS entries_profile_date ON entries(profile_id, visited_at DESC)"),
              execute("CREATE TABLE IF NOT EXISTS history_settings (profile_id TEXT PRIMARY KEY, retention_days INTEGER NOT NULL)") else { return }
        pruneHistory()
        initialized = lastError == nil

    }

    deinit { if let database { sqlite3_close(database) } }

    /// Tests that own a temporary directory must close SQLite before unlinking it.
    func close() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    func recordVisit(urlString: String, title: String, profileID: UUID, at date: Date = Date(), engineID: EngineID = .webKit) {
        guard beginMutation() else { return }
        lastError = initializationError
        pruneHistory(now: date)
        guard let url = Self.webURL(urlString) else { return }
        if execute("""
            INSERT INTO entries(profile_id, url, title, visited_at, in_history, engine_id)
            VALUES (?, ?, ?, ?, 1, ?)
            ON CONFLICT(profile_id, url) DO UPDATE SET
                title = CASE
                    WHEN entries.in_history = 1 AND excluded.visited_at < entries.visited_at THEN entries.title
                    WHEN excluded.title = '' THEN entries.title ELSE excluded.title END,
                visited_at = CASE
                    WHEN entries.in_history = 1 AND excluded.visited_at < entries.visited_at THEN entries.visited_at
                    ELSE excluded.visited_at END,
                in_history = 1,
                engine_id = CASE
                    WHEN entries.in_history = 1 AND excluded.visited_at < entries.visited_at THEN entries.engine_id
                    ELSE excluded.engine_id END
            """, [.text(profileID.uuidString), .text(url), .text(title), .number(date.timeIntervalSince1970), .text(engineID.rawValue)]) {
            revision += 1
        }
    }

    func bookmark(urlString: String, title: String, profileID: UUID) {
        guard beginMutation() else { return }
        lastError = initializationError
        guard let url = Self.webURL(urlString) else { return }
        if saveBookmark(urlString: url, title: title, profileID: profileID) { revision += 1 }
    }

    func updateHistoryTitle(urlString: String, title: String, profileID: UUID, engineID: EngineID, visitedAt: Date) {
        guard beginMutation() else { return }
        guard !title.isEmpty, let url = Self.webURL(urlString) else { return }
        if execute("UPDATE entries SET title = ? WHERE profile_id = ? AND url = ? AND engine_id = ? AND in_history = 1 AND visited_at = ? AND title != ?",
                   [.text(title), .text(profileID.uuidString), .text(url), .text(engineID.rawValue), .number(visitedAt.timeIntervalSince1970), .text(title)]),
           sqlite3_changes(database) > 0 { revision += 1 }
    }

    func search(_ query: String, profileID: UUID, bookmarksOnly: Bool = false, historyOnly: Bool = false) -> [LibraryEntry] {
        // Refreshing rows must not dismiss a failed write; the next mutation clears it.
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let displayTitle = historyOnly ? "title" : "CASE WHEN is_bookmark = 1 THEN bookmark_title ELSE title END"
        return entries("""
            SELECT id, url, \(displayTitle), visited_at, is_bookmark, engine_id FROM entries
            WHERE profile_id = ? AND \(bookmarksOnly ? "is_bookmark = 1" : (historyOnly ? "in_history = 1" : "(in_history = 1 OR is_bookmark = 1)"))
            AND ((in_history = 1 AND \(bookmarksOnly ? 0 : 1) AND title LIKE ? ESCAPE '\\')
                OR (is_bookmark = 1 AND \(historyOnly ? 0 : 1) AND bookmark_title LIKE ? ESCAPE '\\')
                OR url LIKE ? ESCAPE '\\')
            ORDER BY visited_at DESC, id DESC LIMIT 100
            """, [.text(profileID.uuidString), .text("%\(escaped)%"), .text("%\(escaped)%"), .text("%\(escaped)%")])
    }

    func syncItems(module: SyncModule, profileIDs: Set<UUID>) throws -> [SyncItem] {
        guard module == .bookmarks || module == .history else { return [] }
        lastError = initializationError
        guard let statement = prepare("SELECT profile_id, url, title, bookmark_title, visited_at, in_history, is_bookmark FROM entries WHERE \(module == .bookmarks ? "is_bookmark" : "in_history") = 1", []) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var result: [SyncItem] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let profileString = Self.text(statement, column: 0)
            if let profile = UUID(uuidString: profileString), profileIDs.contains(profile),
               Self.syncSafeURL(Self.text(statement, column: 1)) != nil {
                let url = Self.text(statement, column: 1)
                let title = Self.text(statement, column: module == .bookmarks ? 3 : 2)
                guard title.utf8.count <= 4096, !title.contains("\0") else {
                    throw SyncFailure.localWrite(String(localized: "A saved title is too long or invalid to sync. Edit it in the library and try again."))
                }
                var fields = ["profileID": profile.uuidString, "url": url, "title": title]
                if module == .history { fields["visitedAt"] = String(sqlite3_column_double(statement, 4)) }
                result.append(SyncItem(id: Self.syncID(profile: profile, url: url, module: module),
                                       module: module, kind: module == .bookmarks ? "bookmark" : "visit", fields: fields))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { reportError(); throw CocoaError(.fileReadUnknown) }
        return result
    }

    func applySyncItems(_ items: [SyncItem], module: SyncModule, profileIDs: Set<UUID>) throws {
        guard module == .bookmarks || module == .history, beginMutation() else { throw CocoaError(.fileWriteUnknown) }
        let now = Date().timeIntervalSince1970
        var validated: [(UUID, String, String, Double?)] = []
        var ids = Set<String>()
        for item in items {
            let fields = item.fields
            guard item.module == module, item.kind == (module == .bookmarks ? "bookmark" : "visit"),
                  let profile = fields["profileID"].flatMap(UUID.init(uuidString:)),
                  let rawURL = fields["url"], let url = Self.syncSafeURL(rawURL), url == rawURL,
                  let title = fields["title"], title.utf8.count <= 4096, !title.contains("\0"),
                  item.id == Self.syncID(profile: profile, url: url, module: module), ids.insert(item.id).inserted else {
                throw CocoaError(.coderReadCorrupt)
            }
            let date: Double?
            if module == .history {
                guard let visited = fields["visitedAt"].flatMap(Double.init), visited.isFinite,
                      visited >= 0, visited <= now + 86400 else { throw CocoaError(.coderReadCorrupt) }
                date = visited
            } else { date = nil }
            if profileIDs.contains(profile) { validated.append((profile, url, title, date)) }
        }
        let desired = validated.compactMap { profile, url, title, date -> SyncItem? in
            if let date {
                let retention = retentionDays(profileID: profile)
                if retention > 0 && date < now - Double(retention) * 86400 { return nil }
            }
            var fields = ["profileID": profile.uuidString, "url": url, "title": title]
            if let date { fields["visitedAt"] = String(date) }
            return SyncItem(id: Self.syncID(profile: profile, url: url, module: module), module: module,
                            kind: module == .bookmarks ? "bookmark" : "visit", fields: fields)
        }
        let current = try syncItems(module: module, profileIDs: profileIDs)
        if Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.fields) }) ==
            Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0.fields) }) { return }
        lastError = initializationError
        guard execute("BEGIN IMMEDIATE") else { throw CocoaError(.fileWriteUnknown) }
        var committed = false
        defer { if !committed { _ = execute("ROLLBACK") } }
        for profile in profileIDs {
            let titleColumn = module == .bookmarks ? "bookmark_title" : "title"
            guard let statement = prepare("SELECT id, url, \(titleColumn) FROM entries WHERE profile_id = ? AND \(module == .bookmarks ? "is_bookmark" : "in_history") = 1",
                                          [.text(profile.uuidString)]) else { throw CocoaError(.fileReadUnknown) }
            var clearIDs: [Int64] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                let url = Self.text(statement, column: 1), title = Self.text(statement, column: 2)
                if Self.syncSafeURL(url) != nil, title.utf8.count <= 4096, !title.contains("\0") {
                    clearIDs.append(sqlite3_column_int64(statement, 0))
                }
                status = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            guard status == SQLITE_DONE else { reportError(); throw CocoaError(.fileReadUnknown) }
            for id in clearIDs {
                if module == .bookmarks {
                    guard execute("UPDATE entries SET is_bookmark = 0, bookmark_title = '' WHERE id = ?", [.integer(id)]) else { throw CocoaError(.fileWriteUnknown) }
                } else {
                    guard execute("UPDATE entries SET in_history = 0, title = '', visited_at = 0 WHERE id = ?", [.integer(id)]) else { throw CocoaError(.fileWriteUnknown) }
                }
            }
        }
        for (profile, url, title, date) in validated {
            if module == .bookmarks {
                guard execute("""
                    INSERT INTO entries(profile_id, url, title, visited_at, is_bookmark, bookmark_title)
                    VALUES (?, ?, '', 0, 1, ?)
                    ON CONFLICT(profile_id, url) DO UPDATE SET is_bookmark = 1, bookmark_title = excluded.bookmark_title
                    """, [.text(profile.uuidString), .text(url), .text(title)]) else { throw CocoaError(.fileWriteUnknown) }
            } else if let date {
                let retention = retentionDays(profileID: profile)
                if retention > 0 && date < now - Double(retention) * 86400 { continue }
                guard execute("""
                    INSERT INTO entries(profile_id, url, title, visited_at, in_history)
                    VALUES (?, ?, ?, ?, 1)
                    ON CONFLICT(profile_id, url) DO UPDATE SET title = excluded.title,
                        visited_at = excluded.visited_at, in_history = 1
                    """, [.text(profile.uuidString), .text(url), .text(title), .number(date)]) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        guard execute("DELETE FROM entries WHERE in_history = 0 AND is_bookmark = 0"), execute("COMMIT") else {
            throw CocoaError(.fileWriteUnknown)
        }
        committed = true
        revision += 1
    }

    private static func syncID(profile: UUID, url: String, module: SyncModule) -> String {
        let data = Data((profile.uuidString + "\n" + url).utf8)
        return "\(module == .bookmarks ? "bookmark" : "visit"):\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())"
    }

    @discardableResult
    func removeProfile(_ profileID: UUID) -> Bool {
        lastError = initializationError
        guard execute("BEGIN IMMEDIATE") else { return false }
        guard execute("DELETE FROM entries WHERE profile_id = ?", [.text(profileID.uuidString)]),
              execute("DELETE FROM history_settings WHERE profile_id = ?", [.text(profileID.uuidString)]),
              execute("COMMIT") else {
            _ = execute("ROLLBACK")
            return false
        }
        revision += 1
        return true
    }

    func retentionDays(profileID: UUID) -> Int {
        guard let statement = prepare("SELECT retention_days FROM history_settings WHERE profile_id = ?", [.text(profileID.uuidString)]) else { return 90 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 90
    }

    func setRetentionDays(_ days: Int, profileID: UUID) {
        guard beginMutation() else { return }
        guard [0, 7, 30, 90, 365].contains(days) else { return }
        lastError = initializationError
        if execute("INSERT INTO history_settings VALUES (?, ?) ON CONFLICT(profile_id) DO UPDATE SET retention_days = excluded.retention_days",
                   [.text(profileID.uuidString), .integer(Int64(days))]) {
            let previousRevision = revision
            pruneHistory()
            if revision == previousRevision { revision += 1 }
        }
    }

    func pruneHistory(now: Date = Date()) {
        guard beginMutation() else { return }
        // Zero means keep until explicitly cleared. Bookmarks keep no expired visit timestamp.
        let condition = """
            in_history = 1 AND visited_at < ? - 86400 * COALESCE(
                (SELECT retention_days FROM history_settings WHERE profile_id = entries.profile_id), 90)
            AND COALESCE((SELECT retention_days FROM history_settings WHERE profile_id = entries.profile_id), 90) > 0
            """
        removeHistory(where: condition, values: [.number(now.timeIntervalSince1970)])
    }

    func clearHistory(profileID: UUID, since: Date = .distantPast) {
        guard beginMutation() else { return }
        lastError = initializationError
        let deleted = historyItems(where: "profile_id = ? AND in_history = 1 AND visited_at >= ?",
                                   values: [.text(profileID.uuidString), .number(since.timeIntervalSince1970)])
        removeHistory(where: "profile_id = ? AND in_history = 1 AND visited_at >= ?",
                      values: [.text(profileID.uuidString), .number(since.timeIntervalSince1970)],
                      beforeDelete: { if !deleted.isEmpty { try self.onSyncHistoryDeletion?(deleted) } })
    }

    func removeHistoryEntry(id: Int64, profileID: UUID) {
        guard beginMutation() else { return }
        lastError = initializationError
        let deleted = historyItems(where: "id = ? AND profile_id = ? AND in_history = 1",
                                   values: [.integer(id), .text(profileID.uuidString)])
        removeHistory(where: "id = ? AND profile_id = ?", values: [.integer(id), .text(profileID.uuidString)],
                      beforeDelete: { if !deleted.isEmpty { try self.onSyncHistoryDeletion?(deleted) } })
    }

    private func historyItems(where condition: String, values: [Value]) -> [SyncItem] {
        guard let statement = prepare("SELECT profile_id, url, title, visited_at FROM entries WHERE \(condition)", values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [SyncItem] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let profile = UUID(uuidString: Self.text(statement, column: 0)) {
                let url = Self.text(statement, column: 1)
                let title = Self.text(statement, column: 2)
                if Self.syncSafeURL(url) != nil {
                    result.append(SyncItem(id: Self.syncID(profile: profile, url: url, module: .history),
                                       module: .history, kind: "visit", fields: [
                                        "profileID": profile.uuidString, "url": url,
                                        "title": title.utf8.count <= 4096 && !title.contains("\0") ? title : "",
                                        "visitedAt": String(sqlite3_column_double(statement, 3))
                                       ]))
                }
            }
            status = sqlite3_step(statement)
        }
        if status != SQLITE_DONE { reportError() }
        return result
    }

    func removeBookmark(id: Int64, profileID: UUID) {
        guard beginMutation() else { return }
        lastError = initializationError
        guard execute("BEGIN IMMEDIATE") else { return }
        if execute("UPDATE entries SET is_bookmark = 0, bookmark_title = '' WHERE id = ? AND profile_id = ?", [.integer(id), .text(profileID.uuidString)]),
           execute("DELETE FROM entries WHERE id = ? AND profile_id = ? AND in_history = 0", [.integer(id), .text(profileID.uuidString)]),
           execute("COMMIT") { revision += 1 } else { _ = execute("ROLLBACK") }
    }

    private func removeHistory(where condition: String, values: [Value], beforeDelete: (() throws -> Void)? = nil) {
        let previousChanges = database.map { sqlite3_total_changes64($0) } ?? 0
        guard execute("BEGIN IMMEDIATE") else { return }
        do { try beforeDelete?() }
        catch { _ = execute("ROLLBACK"); lastError = error.localizedDescription; return }
        if execute("DELETE FROM entries WHERE is_bookmark = 0 AND (\(condition))", values),
           execute("UPDATE entries SET in_history = 0, visited_at = 0, title = '' WHERE \(condition)", values),
           execute("COMMIT") {
            let currentChanges = database.map { sqlite3_total_changes64($0) } ?? previousChanges
            if currentChanges > previousChanges { revision += 1 }
        } else { _ = execute("ROLLBACK") }
    }

    func exportBookmarks(profileID: UUID) throws -> String {
        lastError = initializationError
        let bookmarks = entries("""
            SELECT id, url, bookmark_title, visited_at, is_bookmark, engine_id FROM entries
            WHERE profile_id = ? AND is_bookmark = 1 ORDER BY id
            """, [.text(profileID.uuidString)])
        if let lastError { throw NSError(domain: "Cobble.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError]) }
        let lines = bookmarks.map { "<DT><A HREF=\"\(Self.escapeHTML($0.urlString))\">\(Self.escapeHTML($0.title))</A>" }
        return "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Cobble Bookmarks</TITLE>\n<H1>Cobble Bookmarks</H1>\n<DL><p>\n" + lines.joined(separator: "\n") + "\n</DL><p>\n"
    }

    struct ImportResult: Equatable {
        var imported = 0
        var skipped = 0
        var message: String {
            imported == 0 ? String(format: String(localized: "No supported HTTP or HTTPS bookmarks found. Skipped %@ links."), "\(skipped)") :
                String(format: String(localized: "Imported or updated %@ bookmarks. Skipped %@ unsupported links."), "\(imported)", "\(skipped)")
        }
    }

    /// A bounded HTML import, not a page renderer: accept quoted links and ignore markup/scripts.
    @discardableResult
    func importBookmarks(from html: String, profileID: UUID) -> ImportResult? {
        guard beginMutation() else { return nil }
        lastError = initializationError
        guard html.utf8.count <= 10_000_000 else { lastError = String(localized: "This bookmark file exceeds the 10 MB import limit."); return nil }
        let source = html as NSString
        var result = ImportResult()
        guard execute("BEGIN IMMEDIATE") else { return nil }
        for anchor in Self.anchorsRegex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let attributes = source.substring(with: anchor.range(at: 1))
            let attributeSource = attributes as NSString
            guard let match = Self.hrefRegex.firstMatch(in: attributes, range: NSRange(location: 0, length: attributeSource.length)),
                  let url = Self.webURL(Self.decodeHTML(attributeSource.substring(with: match.range(at: 2)))) else { result.skipped += 1; continue }
            let rawTitle = source.substring(with: anchor.range(at: 2)).replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            let title = Self.decodeHTML(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard saveBookmark(urlString: url, title: title.isEmpty ? url : title, profileID: profileID) else {
                _ = execute("ROLLBACK"); return nil
            }
            result.imported += 1
        }
        guard execute("COMMIT") else { _ = execute("ROLLBACK"); return nil }
        revision += 1
        return result
    }

    @discardableResult
    func editBookmark(id: Int64, profileID: UUID, urlString: String, title: String) -> Bool {
        guard beginMutation() else { return false }
        lastError = initializationError
        guard let url = Self.webURL(urlString) else { lastError = String(localized: "Enter a valid HTTP or HTTPS address without credentials."); return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("\0") else { lastError = String(localized: "Enter a bookmark title."); return false }
        guard execute("BEGIN IMMEDIATE") else { return false }
        var committed = false
        defer { if !committed { _ = execute("ROLLBACK") } }
        let originals = entries("SELECT id, url, bookmark_title, visited_at, is_bookmark, engine_id FROM entries WHERE id = ? AND profile_id = ? AND is_bookmark = 1",
                                [.integer(id), .text(profileID.uuidString)])
        guard lastError == nil, let original = originals.first else {
            if lastError == nil { lastError = String(localized: "This bookmark is no longer available.") }; return false
        }
        if original.urlString != url {
            let collisions = entries("SELECT id, url, bookmark_title, visited_at, is_bookmark, engine_id FROM entries WHERE profile_id = ? AND url = ? AND is_bookmark = 1",
                                     [.text(profileID.uuidString), .text(url)])
            guard lastError == nil else { return false }
            guard collisions.isEmpty else { lastError = String(localized: "A bookmark already uses this address. Edit that bookmark or choose another address."); return false }
            guard execute("UPDATE entries SET is_bookmark = 0, bookmark_title = '' WHERE id = ?", [.integer(id)]),
                  execute("DELETE FROM entries WHERE id = ? AND in_history = 0", [.integer(id)]) else { return false }
        }
        guard saveBookmark(urlString: url, title: title, profileID: profileID), execute("COMMIT") else { return false }
        committed = true
        revision += 1
        return true
    }

    private func saveBookmark(urlString: String, title: String, profileID: UUID) -> Bool {
        execute("""
            INSERT INTO entries(profile_id, url, title, visited_at, is_bookmark, bookmark_title)
            VALUES (?, ?, '', ?, 1, ?)
            ON CONFLICT(profile_id, url) DO UPDATE SET is_bookmark = 1,
                bookmark_title = CASE WHEN excluded.bookmark_title = '' THEN entries.bookmark_title ELSE excluded.bookmark_title END
            """, [.text(profileID.uuidString), .text(urlString), .number(Date().timeIntervalSince1970), .text(title)])
    }

    private func beginMutation() -> Bool {
        guard mutationsAllowed?() != false else {
            lastError = String(localized: "A profile is being deleted. Try again when cleanup finishes.")
            return false
        }
        return true
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        guard let database else { lastError = initializationError ?? String(localized: "The library database is unavailable."); return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            reportError(); return nil
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let string): status = sqlite3_bind_text(statement, index, string, Int32(string.utf8.count), Self.transient)
            case .number(let number): status = sqlite3_bind_double(statement, index, number)
            case .integer(let number): status = sqlite3_bind_int64(statement, index, number)
            }
            guard status == SQLITE_OK else { reportError(); sqlite3_finalize(statement); return nil }
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [Value] = []) -> Bool {
        guard let statement = prepare(sql, values) else { return false }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { reportError(); return false }
        return true
    }

    private func entries(_ sql: String, _ values: [Value]) -> [LibraryEntry] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var results: [LibraryEntry] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            results.append(LibraryEntry(id: sqlite3_column_int64(statement, 0),
                urlString: Self.text(statement, column: 1),
                title: Self.text(statement, column: 2),
                visitedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                isBookmark: sqlite3_column_int(statement, 4) != 0,
                engineID: EngineID(rawValue: Self.text(statement, column: 5))))
            status = sqlite3_step(statement)
        }
        if status != SQLITE_DONE { reportError() }
        return results
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private func reportError() {
        lastError = database.map { String(format: String(localized: "Library error: %@"), String(cString: sqlite3_errmsg($0))) } ?? String(localized: "The library database is unavailable.")
    }

    private static func webURL(_ raw: String) -> String? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              !host.contains(where: \.isWhitespace), parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url,
              let origin = AddressResolver.canonicalOrigin(url),
              let originParts = URLComponents(string: origin) else { return nil }
        parts.scheme = originParts.scheme
        parts.host = originParts.host
        parts.port = originParts.port
        return parts.url?.absoluteString
    }

    static func syncSafeURL(_ raw: String) -> String? {
        guard raw.utf8.count <= 8192, let url = webURL(raw),
              let parts = URLComponents(string: url) else { return nil }
        let sensitive = Set(["access_token", "id_token", "refresh_token", "oauth_token", "token",
                             "api_key", "apikey", "client_secret", "password", "secret", "session", "code"])
        guard !(parts.queryItems ?? []).contains(where: { sensitive.contains($0.name.lowercased()) }),
              !sensitive.contains(where: { parts.fragment?.lowercased().contains($0 + "=") == true }) else { return nil }
        return url
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func decodeHTML(_ value: String) -> String {
        let source = value as NSString
        var result = value
        for match in Self.htmlEntityRegex.matches(in: value, range: NSRange(location: 0, length: source.length)).reversed() {
            let entity = source.substring(with: match.range(at: 1))
            let decoded: String?
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x")
                decoded = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10).flatMap(UnicodeScalar.init).map(String.init)
            } else { decoded = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"][entity] }
            if let decoded, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: decoded) }
        }
        return result
    }
}
