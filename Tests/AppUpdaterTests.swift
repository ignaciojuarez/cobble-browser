import XCTest
@testable import Cobble

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testSignedFeedPrerequisitesAreEmbeddedInBuiltApp() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool, true)
    }

    func testOnlyOptedInFullReleasesUseUpdates() {
        let enabled: [String: Any] = ["CobbleUpdatesEnabled": true]
        XCTAssertTrue(AppUpdater.isEligible(info: enabled, environment: [:], fullRelease: true))
        XCTAssertFalse(AppUpdater.isEligible(info: enabled, environment: [:], fullRelease: false))
        XCTAssertFalse(AppUpdater.isEligible(info: [:], environment: [:], fullRelease: true))
        XCTAssertFalse(AppUpdater.isEligible(info: ["CobbleUpdatesEnabled": false], environment: [:], fullRelease: true))
        for environment in [["COBBLE_TESTING": "1"], ["COBBLE_DATA_DIRECTORY": "/tmp/cobble-fixture"]] {
            XCTAssertFalse(AppUpdater.isEligible(info: enabled, environment: environment, fullRelease: true))
        }
        let updater = AppUpdater()
        updater.start()
        updater.setAutomaticChecks(true)
        updater.checkForUpdates()
        XCTAssertFalse(updater.isEnabled)
        XCTAssertFalse(updater.canCheck)
        XCTAssertFalse(updater.automaticChecks)
        XCTAssertNil(updater.reminder)
    }
}
