import XCTest
@testable import Cobble

final class BrowserEntitlementsTests: XCTestCase {
    func testUnsignedBuildLacksBrowserPasswordEntitlements() {
        XCTAssertFalse(BrowserEntitlements.hasPasskeys)
        XCTAssertFalse(BrowserEntitlements.has(BrowserEntitlements.passkeys))
    }
}
