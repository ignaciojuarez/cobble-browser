import XCTest
@testable import Cobble

final class BrowserEntitlementsTests: XCTestCase {
    func testUnsignedBuildLacksBrowserPasswordEntitlements() {
        XCTAssertFalse(BrowserEntitlements.hasWebBrowser)
        XCTAssertFalse(BrowserEntitlements.hasPasskeys)
        XCTAssertFalse(BrowserEntitlements.has("com.apple.developer.web-browser"))
    }
}
