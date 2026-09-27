import XCTest
@testable import Cobble

@MainActor
final class DownloadFolderTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDownloadFolderTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testFolderPreferenceRoundTripsAndClears() throws {
        let directory = try directory()
        let folder = directory.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertTrue(preferences.setDownloadFolder(folder))
        XCTAssertEqual(preferences.downloadFolderName, "Downloads")
        let reopened = BrowserPreferences(directory: directory)
        let resolved = try XCTUnwrap(reopened.beginDownloadFolder())
        XCTAssertEqual(resolved.standardizedFileURL, folder.standardizedFileURL)
        reopened.endDownloadFolder(resolved)
        XCTAssertTrue(reopened.setDownloadFolder(nil))
        XCTAssertNil(BrowserPreferences(directory: directory).downloadFolderName)
    }

    func testUnreadableFolderBookmarkFallsBackWithoutReplacingPreferences() throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("browser-preferences.json")
        let original = Data(#"{"version":3,"downloadFolderBookmark":"AA==","downloadFolderName":"Missing"}"#.utf8)
        try original.write(to: url)
        let preferences = BrowserPreferences(directory: directory)
        XCTAssertNil(preferences.beginDownloadFolder())
        XCTAssertNotNil(preferences.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testIncompleteFolderPreferenceIsPreservedAndNotShownAsConfigured() throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("browser-preferences.json")
        let original = Data(#"{"version":4,"downloadFolderName":"Downloads"}"#.utf8)
        try original.write(to: url)

        let preferences = BrowserPreferences(directory: directory)
        XCTAssertNil(preferences.downloadFolderName)
        XCTAssertNotNil(preferences.errorMessage)
        XCTAssertFalse(preferences.setDownloadFolder(nil))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOversizedFolderBookmarkIsPreserved() throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("browser-preferences.json")
        let bookmark = Data(repeating: 0, count: 1_048_577).base64EncodedString()
        let original = Data("{\"version\":4,\"downloadFolderBookmark\":\"\(bookmark)\",\"downloadFolderName\":\"Downloads\"}".utf8)
        try original.write(to: url)

        let preferences = BrowserPreferences(directory: directory)
        XCTAssertNil(preferences.downloadFolderName)
        XCTAssertNotNil(preferences.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
