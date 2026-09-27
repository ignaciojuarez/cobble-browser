import XCTest
import SQLite3
@testable import Cobble

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testFailedMigrationClosesLibraryAndPreservesOriginalRecords() throws {
        try withLibrary { store, directory in
            let profile = UUID()
            store.recordVisit(urlString: "https://preserved.example", title: "Original", profileID: profile)
            store.bookmark(urlString: "https://preserved.example", title: "Original", profileID: profile)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "ALTER TABLE entries DROP COLUMN bookmark_title; PRAGMA user_version = 2; CREATE TRIGGER reject_migration BEFORE UPDATE ON entries BEGIN SELECT RAISE(ABORT, 'migration fixture failure'); END", nil, nil, nil), SQLITE_OK)
            let unavailable = LibraryStore(directory: directory)
            let diagnostic = try XCTUnwrap(unavailable.lastError)
            XCTAssertTrue(diagnostic.contains("migration fixture failure"))
            unavailable.recordVisit(urlString: "https://must-not-write.example", title: "Must not write", profileID: profile)
            XCTAssertEqual(unavailable.lastError, diagnostic)
            XCTAssertThrowsError(try unavailable.exportBookmarks(profileID: profile))
            XCTAssertEqual(unavailable.lastError, diagnostic)
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT COUNT(*), title FROM entries", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 1)), "Original")
            sqlite3_finalize(statement)
            XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
            sqlite3_finalize(statement)
            XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_migration", nil, nil, nil), SQLITE_OK)
            let recovered = LibraryStore(directory: directory)
            XCTAssertNil(recovered.lastError)
            XCTAssertEqual(recovered.search("", profileID: profile, bookmarksOnly: true).map(\.title), ["Original"])
        }
    }

    func testCombinedSearchMatchesHistoryAndCustomBookmarkTitles() throws {
        try withLibrary { store, _ in
            let profile = UUID(), url = "https://search.example"
            store.recordVisit(urlString: url, title: "Quarterly Report", profileID: profile)
            store.bookmark(urlString: url, title: "Work", profileID: profile)
            XCTAssertEqual(store.search("Quarterly", profileID: profile).map(\.title), ["Work"])
            XCTAssertEqual(store.search("Work", profileID: profile).map(\.title), ["Work"])
            XCTAssertTrue(store.search("Quarterly", profileID: profile, bookmarksOnly: true).isEmpty)
            XCTAssertTrue(store.search("Work", profileID: profile, historyOnly: true).isEmpty)
            store.clearHistory(profileID: profile)
            XCTAssertTrue(store.search("Quarterly", profileID: profile).isEmpty)
            XCTAssertEqual(store.search("Work", profileID: profile).count, 1)
        }
    }

    func testRemovingHistoryOrBookmarkClearsOnlyItsStoredMetadata() throws {
        try withLibrary { store, directory in
            let profile = UUID(), url = "https://metadata.example"
            store.recordVisit(urlString: url, title: "Private visit title", profileID: profile)
            store.bookmark(urlString: url, title: "Custom bookmark", profileID: profile)
            let id = try XCTUnwrap(store.search("", profileID: profile).first?.id)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            store.clearHistory(profileID: profile)
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT title, bookmark_title FROM entries", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "")
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 1)), "Custom bookmark")
            sqlite3_finalize(statement)
            store.recordVisit(urlString: url, title: "New visit title", profileID: profile)
            store.removeBookmark(id: id, profileID: profile)
            XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT title, bookmark_title FROM entries", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "New visit title")
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 1)), "")
            sqlite3_finalize(statement)
        }
    }

    func testHistoryMetadataRejectsOlderPageVisit() throws {
        try withLibrary { store, _ in
            let profile = UUID(), url = "https://same-page.example"
            let oldVisit = Date().addingTimeInterval(-60), newVisit = Date()
            store.recordVisit(urlString: url, title: "Old page", profileID: profile, at: oldVisit)
            store.recordVisit(urlString: url, title: "New page", profileID: profile, at: newVisit)
            store.updateHistoryTitle(urlString: url, title: "Stale background title", profileID: profile, engineID: .webKit, visitedAt: oldVisit)
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).first?.title, "New page")
            store.updateHistoryTitle(urlString: url, title: "Current page title", profileID: profile, engineID: .webKit, visitedAt: newVisit)
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).first?.title, "Current page title")
        }
    }

    func testOlderVisitCannotRegressHistoryButFirstVisitReplacesBookmarkDate() throws {
        try withLibrary { store, _ in
            let profile = UUID(), url = "https://visit-order.example"
            let older = Date(timeIntervalSince1970: 1_000), newer = Date(timeIntervalSince1970: 2_000)
            store.recordVisit(urlString: url, title: "Newer", profileID: profile, at: newer, engineID: .webKit)
            store.recordVisit(urlString: url, title: "Older", profileID: profile, at: older, engineID: EngineID(rawValue: "other"))
            var visit = try XCTUnwrap(store.search("", profileID: profile, historyOnly: true).first)
            XCTAssertEqual(visit.title, "Newer")
            XCTAssertEqual(visit.visitedAt, newer)
            XCTAssertEqual(visit.engineID, .webKit)

            let bookmarkURL = "https://bookmark-first-visit.example"
            store.bookmark(urlString: bookmarkURL, title: "Bookmark", profileID: profile)
            store.recordVisit(urlString: bookmarkURL, title: "First visit", profileID: profile, at: older,
                              engineID: EngineID(rawValue: "other"))
            visit = try XCTUnwrap(store.search(bookmarkURL, profileID: profile, historyOnly: true).first)
            XCTAssertEqual(visit.title, "First visit")
            XCTAssertEqual(visit.visitedAt, older)
            XCTAssertEqual(visit.engineID, EngineID(rawValue: "other"))
        }
    }

    func testBookmarkEditingPreservesHistoryAndRejectsCollisionsOrForeignProfiles() throws {
        try withLibrary { store, _ in
            let profile = UUID(), url = "https://old.example", destination = "https://new.example"
            let visited = Date().addingTimeInterval(-60)
            store.recordVisit(urlString: url, title: "Old history", profileID: profile, at: visited)
            store.recordVisit(urlString: destination, title: "New history", profileID: profile, at: visited)
            store.bookmark(urlString: url, title: "My bookmark", profileID: profile)
            let id = try XCTUnwrap(store.search("", profileID: profile, bookmarksOnly: true).first?.id)
            XCTAssertFalse(store.editBookmark(id: id, profileID: UUID(), urlString: destination, title: "Foreign"))
            XCTAssertFalse(store.editBookmark(id: id, profileID: profile, urlString: "javascript:alert(1)", title: "Bad"))
            XCTAssertFalse(store.editBookmark(id: id, profileID: profile, urlString: "https://example.com:70000", title: "Bad port"))
            XCTAssertTrue(store.editBookmark(id: id, profileID: profile, urlString: destination, title: "Renamed"))
            XCTAssertEqual(store.search("", profileID: profile, bookmarksOnly: true).map(\.title), ["Renamed"])
            XCTAssertEqual(Set(store.search("", profileID: profile, historyOnly: true).map(\.title)), ["Old history", "New history"])
            XCTAssertTrue(store.search("", profileID: profile, historyOnly: true).allSatisfy { abs($0.visitedAt.timeIntervalSince(visited)) < 0.001 })
            store.recordVisit(urlString: destination, title: "Changed site title", profileID: profile)
            XCTAssertEqual(store.search("", profileID: profile, bookmarksOnly: true).map(\.title), ["Renamed"])
            store.bookmark(urlString: url, title: "Another", profileID: profile)
            let renamed = try XCTUnwrap(store.search("Renamed", profileID: profile, bookmarksOnly: true).first)
            XCTAssertFalse(store.editBookmark(id: renamed.id, profileID: profile, urlString: url, title: "Collision"))
            XCTAssertEqual(store.search("", profileID: profile, bookmarksOnly: true).count, 2)
        }
    }

    func testHistoryTitleUpdatesDoNotCreateVisitsChangeDatesOrRenameBookmarks() throws {
        try withLibrary { store, _ in
            let profile = UUID(), url = "https://title.example", visited = Date().addingTimeInterval(-60)
            store.recordVisit(urlString: url, title: "Loading", profileID: profile, at: visited)
            store.bookmark(urlString: url, title: "Custom title", profileID: profile)
            store.updateHistoryTitle(urlString: url, title: "Foreign", profileID: UUID(), engineID: .webKit, visitedAt: visited)
            store.updateHistoryTitle(urlString: url, title: "Other engine", profileID: profile, engineID: EngineID(rawValue: "other"), visitedAt: visited)
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).first?.title, "Loading")
            store.updateHistoryTitle(urlString: url, title: "Loaded", profileID: profile, engineID: .webKit, visitedAt: visited)
            store.updateHistoryTitle(urlString: url, title: "", profileID: profile, engineID: .webKit, visitedAt: visited)
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).first?.title, "Loaded")
            XCTAssertEqual(try XCTUnwrap(store.search("", profileID: profile, historyOnly: true).first).visitedAt.timeIntervalSince1970, visited.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(store.search("", profileID: profile, bookmarksOnly: true).first?.title, "Custom title")
            store.clearHistory(profileID: profile)
            store.updateHistoryTitle(urlString: url, title: "Late callback", profileID: profile, engineID: .webKit, visitedAt: visited)
            XCTAssertTrue(store.search("", profileID: profile, historyOnly: true).isEmpty)
        }
    }

    func testBookmarkImportReportsUnsupportedAndEmptyInputsAndRollsBackFailures() throws {
        try withLibrary { store, directory in
            let profile = UUID()
            let result = try XCTUnwrap(store.importBookmarks(from: "<a href='https://valid.example'>Valid</a><a href='javascript:bad'>Bad</a><a>No URL</a>", profileID: profile))
            XCTAssertEqual(result, .init(imported: 1, skipped: 2))
            XCTAssertEqual(store.importBookmarks(from: "<h1>No bookmarks</h1>", profileID: profile)?.imported, 0)
            XCTAssertEqual(store.importBookmarks(from: "<a href='file:///secret'>Local</a>", profileID: profile)?.skipped, 1)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_import BEFORE INSERT ON entries WHEN NEW.url = 'https://reject.example' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", nil, nil, nil), SQLITE_OK)
            XCTAssertNil(store.importBookmarks(from: "<a href='https://rollback.example'>Rollback</a><a href='https://reject.example'>Reject</a>", profileID: profile))
            XCTAssertNotNil(store.lastError)
            XCTAssertEqual(store.search("", profileID: profile, bookmarksOnly: true).map(\.urlString), ["https://valid.example"])
        }
    }

    func testFailedBookmarkExportPreservesExistingOutput() throws {
        try withLibrary { _, directory in
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
            sqlite3_close(database)
            let unavailable = LibraryStore(directory: directory)
            let output = directory.appendingPathComponent("bookmarks.html")
            let original = "Existing export"
            try original.write(to: output, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try unavailable.exportBookmarks(profileID: UUID()).write(to: output, atomically: true, encoding: .utf8))
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), original)
        }
    }

    func testVersionTwoLibraryPreservesBookmarkTitlesDuringMigration() throws {
        try withLibrary { store, directory in
            let profile = UUID(), url = "https://legacy.example"
            store.recordVisit(urlString: url, title: "Legacy title", profileID: profile)
            store.bookmark(urlString: url, title: "Legacy title", profileID: profile)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(database, "ALTER TABLE entries DROP COLUMN bookmark_title; PRAGMA user_version = 2", nil, nil, nil), SQLITE_OK)
            sqlite3_close(database)
            let migrated = LibraryStore(directory: directory)
            XCTAssertNil(migrated.lastError)
            XCTAssertEqual(migrated.search("", profileID: profile, bookmarksOnly: true).first?.title, "Legacy title")
            migrated.recordVisit(urlString: url, title: "New title", profileID: profile)
            XCTAssertEqual(migrated.search("", profileID: profile, bookmarksOnly: true).first?.title, "Legacy title")
            XCTAssertEqual(migrated.search("", profileID: profile, historyOnly: true).first?.title, "New title")
        }
    }

    func testMalformedCurrentSchemaIsRejectedBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleMalformedLibrary-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY, profile_id TEXT NOT NULL, url TEXT NOT NULL,
                title TEXT NOT NULL, visited_at REAL NOT NULL, in_history INTEGER NOT NULL DEFAULT 0,
                is_bookmark INTEGER NOT NULL DEFAULT 0, engine_id TEXT NOT NULL DEFAULT 'webkit',
                UNIQUE(profile_id, url));
            INSERT INTO entries(profile_id, url, title, visited_at, in_history) VALUES ('fixture', 'https://keep.example', 'Keep', 1, 1);
            PRAGMA user_version = 3;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = LibraryStore(directory: directory)
        XCTAssertNotNil(store.lastError)
        store.recordVisit(urlString: "https://must-not-write.example", title: "No", profileID: UUID())
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM entries", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testFailedRetentionWriteRemainsVisibleAfterRefreshAndCanBeRetried() throws {
        try withLibrary { store, directory in
            let profile = UUID()
            store.recordVisit(urlString: "https://example.com", title: "Page", profileID: profile)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
            store.setRetentionDays(7, profileID: profile)
            let error = try XCTUnwrap(store.lastError)
            XCTAssertEqual(store.retentionDays(profileID: profile), 90)
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).count, 1)
            XCTAssertEqual(store.lastError, error)
            XCTAssertEqual(sqlite3_exec(database, "ROLLBACK", nil, nil, nil), SQLITE_OK)
            store.setRetentionDays(7, profileID: profile)
            XCTAssertEqual(store.retentionDays(profileID: profile), 7)
            XCTAssertNil(store.lastError)
        }
    }

    func testRetentionAndTimeRangeClearingPreserveBookmarksAndProfiles() throws {
        try withLibrary { store, directory in
            let profile = UUID(), other = UUID()
            let now = Date()
            store.recordVisit(urlString: "https://old.example", title: "Old", profileID: profile, at: now.addingTimeInterval(-100 * 86400))
            store.bookmark(urlString: "https://old.example", title: "Keep bookmark", profileID: profile)
            store.recordVisit(urlString: "https://recent.example", title: "Recent", profileID: profile, at: now.addingTimeInterval(-7200))
            store.recordVisit(urlString: "https://latest.example", title: "Latest", profileID: profile, at: now)
            store.recordVisit(urlString: "https://other.example", title: "Other", profileID: other, at: now)
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).count, 2)
            XCTAssertEqual(store.search("", profileID: profile, bookmarksOnly: true).first?.visitedAt.timeIntervalSince1970, 0)
            store.clearHistory(profileID: profile, since: now.addingTimeInterval(-3600))
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).map(\.title), ["Recent"])
            XCTAssertEqual(store.search("", profileID: other).count, 1)
            store.setRetentionDays(7, profileID: profile)
            XCTAssertEqual(LibraryStore(directory: directory).retentionDays(profileID: profile), 7)
            XCTAssertNil(store.lastError)
        }
    }

    func testRemovingHistoryAndBookmarksAreIndependent() throws {
        try withLibrary { store, _ in
            let profile = UUID()
            store.recordVisit(urlString: "https://saved.example", title: "Page", profileID: profile)
            store.bookmark(urlString: "https://saved.example", title: "Saved", profileID: profile)
            let id = try XCTUnwrap(store.search("", profileID: profile).first?.id)
            store.removeHistoryEntry(id: id, profileID: UUID())
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).count, 1)
            store.removeHistoryEntry(id: id, profileID: profile)
            XCTAssertTrue(store.search("", profileID: profile, historyOnly: true).isEmpty)
            XCTAssertEqual(store.search("", profileID: profile, bookmarksOnly: true).count, 1)
            store.recordVisit(urlString: "https://saved.example", title: "Page", profileID: profile)
            store.removeBookmark(id: id, profileID: profile)
            XCTAssertTrue(store.search("", profileID: profile, bookmarksOnly: true).isEmpty)
            XCTAssertEqual(store.search("", profileID: profile, historyOnly: true).count, 1)
        }
    }

    private func withLibrary(body: (LibraryStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleLibraryTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        XCTAssertNil(store.lastError)
        defer { store.close() }
        try body(store, directory)
    }

    func testVisitsAreDeduplicatedAndProfilesAreIsolated() throws {
        try withLibrary { store, _ in
            let first = UUID(), second = UUID()
            store.recordVisit(urlString: "https://example.com", title: "Old title", profileID: first)
            let originalID = try XCTUnwrap(store.search("", profileID: first).first?.id)
            store.recordVisit(urlString: "https://example.com", title: "New title", profileID: first)
            store.recordVisit(urlString: "https://example.com", title: "Other profile", profileID: second)
            let firstResults = store.search("", profileID: first)
            XCTAssertEqual(firstResults.count, 1)
            XCTAssertEqual(firstResults[0].id, originalID)
            XCTAssertEqual(firstResults[0].title, "New title")
            XCTAssertEqual(store.search("", profileID: second).map(\.title), ["Other profile"])
            XCTAssertNil(store.lastError)
        }
    }

    func testFailedVisitDoesNotPublishARevisionAndTextBindingPreservesNulls() throws {
        try withLibrary { store, directory in
            let profile = UUID()
            store.recordVisit(urlString: "https://text.example", title: "Before\0After", profileID: profile)
            XCTAssertEqual(store.search("", profileID: profile).first?.title, "Before\0After")
            let revision = store.revision

            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_visit BEFORE INSERT ON entries BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", nil, nil, nil), SQLITE_OK)
            store.recordVisit(urlString: "https://reject.example", title: "Rejected", profileID: profile)
            XCTAssertEqual(store.revision, revision)
            XCTAssertNotNil(store.lastError)
        }
    }

    func testInvalidAndNonWebVisitsAreIgnored() throws {
        try withLibrary { store, _ in
            let profile = UUID()
            for url in ["about:blank", "file:///secret", "javascript:alert(1)", "data:text/plain,secret", "https://", "example.com", "https://user:pass@example.com", "https://example.com:0", "https://example.com:70000"] {
                store.recordVisit(urlString: url, title: "Ignore", profileID: profile)
                store.bookmark(urlString: url, title: "Ignore", profileID: profile)
            }
            XCTAssertTrue(store.search("", profileID: profile).isEmpty)
        }
    }

    func testLibraryURLsCanonicalizeHostCaseAndDefaultPorts() throws {
        try withLibrary { store, _ in
            let profile = UUID()
            store.recordVisit(urlString: "https://Example.com/a", title: "Cased", profileID: profile)
            store.recordVisit(urlString: "https://example.com/a", title: "Lower", profileID: profile)
            store.bookmark(urlString: "HTTPS://EXAMPLE.COM/a", title: "Bookmark", profileID: profile)
            let history = store.search("", profileID: profile, historyOnly: true)
            XCTAssertEqual(history.map(\.urlString), ["https://example.com/a"])
            XCTAssertEqual(history.map(\.title), ["Lower"])
            XCTAssertEqual(store.search("", profileID: profile, bookmarksOnly: true).map(\.urlString), ["https://example.com/a"])

            store.recordVisit(urlString: "https://example.com:443/b", title: "HTTPS default", profileID: profile)
            store.recordVisit(urlString: "https://example.com/b", title: "HTTPS", profileID: profile)
            store.recordVisit(urlString: "http://example.com:80/c", title: "HTTP default", profileID: profile)
            store.recordVisit(urlString: "http://example.com/c", title: "HTTP", profileID: profile)
            store.recordVisit(urlString: "https://example.com:8443/d", title: "Custom", profileID: profile)
            let urls = Set(store.search("", profileID: profile, historyOnly: true).map(\.urlString))
            XCTAssertEqual(urls, [
                "https://example.com/a", "https://example.com/b", "http://example.com/c", "https://example.com:8443/d"
            ])
        }
    }

    func testClearHistoryRetainsBookmarksAndOtherProfiles() throws {
        try withLibrary { store, _ in
            let first = UUID(), second = UUID()
            store.recordVisit(urlString: "https://visited.example", title: "History", profileID: first)
            store.recordVisit(urlString: "https://saved.example", title: "Saved", profileID: first)
            store.bookmark(urlString: "https://saved.example", title: "Bookmark", profileID: first)
            store.recordVisit(urlString: "https://other.example", title: "Other", profileID: second)
            store.clearHistory(profileID: first)
            let remaining = store.search("", profileID: first)
            XCTAssertEqual(remaining.map(\.title), ["Bookmark"])
            XCTAssertEqual(remaining.map(\.isBookmark), [true])
            XCTAssertEqual(store.search("", profileID: second).count, 1)
            XCTAssertEqual(store.search("", profileID: second).count, 1)
            XCTAssertNil(store.lastError)
        }
    }

    func testSearchTreatsSQLWildcardsAndQuotesLiterally() throws {
        try withLibrary { store, _ in
            let profile = UUID()
            store.recordVisit(urlString: "https://one.example", title: "100%_ready O'Reilly", profileID: profile)
            store.recordVisit(urlString: "https://two.example", title: "ordinary", profileID: profile)
            XCTAssertEqual(store.search("%_", profileID: profile).count, 1)
            XCTAssertEqual(store.search("O'Reilly", profileID: profile).count, 1)
            XCTAssertTrue(store.search("' OR 1=1 --", profileID: profile).isEmpty)
            XCTAssertNil(store.lastError)
        }
    }

    func testExportImportRoundTripEscapesMarkupAndDeduplicates() throws {
        try withLibrary { store, _ in
            let first = UUID(), second = UUID()
            let title = "A & B <script>quoted \"title\"</script>"
            let url = "https://example.com/?a=1&b=2"
            store.bookmark(urlString: url, title: title, profileID: first)
            let html = try store.exportBookmarks(profileID: first)
            XCTAssertTrue(html.contains("&lt;script&gt;"))
            XCTAssertTrue(html.contains("&amp;b=2"))
            store.importBookmarks(from: html, profileID: second)
            store.importBookmarks(from: html, profileID: second)
            let results = store.search("", profileID: second, bookmarksOnly: true)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[0].urlString, url)
            XCTAssertEqual(results[0].title, title)
            XCTAssertNil(store.lastError)
        }
    }

    func testImportSkipsInvalidLinksAndDecodesEntities() throws {
        try withLibrary { store, _ in
            let profile = UUID()
            store.importBookmarks(from: """
                <DL><DT><a href='https://valid.example'>Caf&#233; &amp; Tea</a>
                <DT><a HREF="javascript:alert(1)">Bad</a>
                <DT><a href="https://">Missing host</a>
                <DT><a href="file:///secret">Local</a>
                <DT><a href="https://valid.example">Updated &#x1F9A6;</a></DL>
                """, profileID: profile)
            let results = store.search("", profileID: profile)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[0].title, "Updated 🦦")
            XCTAssertTrue(results[0].isBookmark)
            XCTAssertNil(store.lastError)
        }
    }

    func testSearchLimitDoesNotTruncateBookmarkExport() throws {
        try withLibrary { store, _ in
            let profile = UUID(), importedProfile = UUID()
            let html = (0..<105).map { "<A HREF=\"https://example.com/\($0)\">Item \($0)</A>" }.joined()
            store.importBookmarks(from: html, profileID: profile)
            XCTAssertEqual(store.search("", profileID: profile).count, 100)
            let export = try store.exportBookmarks(profileID: profile)
            XCTAssertEqual(export.components(separatedBy: "<DT><A ").count - 1, 105)
            store.importBookmarks(from: export, profileID: importedProfile)
            XCTAssertEqual(try store.exportBookmarks(profileID: importedProfile).components(separatedBy: "<DT><A ").count - 1, 105)
            XCTAssertNil(store.lastError)
        }
    }

    func testLibrarySurvivesReopening() throws {
        try withLibrary { store, directory in
            let profile = UUID()
            store.bookmark(urlString: "https://saved.example", title: "Saved", profileID: profile)
            let reopened = LibraryStore(directory: directory)
            XCTAssertEqual(reopened.search("", profileID: profile).map(\.title), ["Saved"])
            XCTAssertNil(reopened.lastError)
        }
    }

    func testInitializationFailureIsVisible() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleLibraryFile-\(UUID())")
        try Data("file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = LibraryStore(directory: file)
        XCTAssertNotNil(store.lastError)
        store.recordVisit(urlString: "https://example.com", title: "Example", profileID: UUID())
        XCTAssertNotNil(store.lastError)
    }
}
