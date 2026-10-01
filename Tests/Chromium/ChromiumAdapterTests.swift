#if COBBLE_CHROMIUM_CLIENT
import XCTest
@testable import CobbleNativeClient
#if COBBLE_CHROMIUM_ABI15
import CobbleChromium
#endif

@MainActor final class ChromiumAdapterTests: XCTestCase {
    #if COBBLE_CHROMIUM_ABI17
    func testPopupDispositionPreservesBackgroundOpening() {
        XCTAssertFalse(ChromiumEngine.activatesPopup(.newBackgroundTab))
        for disposition: ChromiumPopupRequest.Disposition in [.newForegroundTab, .newWindow, .newPopup, .unknown] {
            XCTAssertTrue(ChromiumEngine.activatesPopup(disposition))
        }
    }
    #endif

    func testExtensionSiteGrantsRejectInvalidPorts() throws {
        XCTAssertEqual(try ChromiumExtensionManager.concreteOrigin("HTTPS://Example.com:443/*"),
                       "https://example.com:443/")
        XCTAssertThrowsError(try ChromiumExtensionManager.concreteOrigin("https://example.com:0/"))
        XCTAssertThrowsError(try ChromiumExtensionManager.concreteOrigin("https://example.com:70000/"))
    }

    func testExtensionSnapshotMigrationKeepsUnpackedAndStoreSourcesDistinct() throws {
        let profileID = UUID()
        let recordID = UUID()
        let chromiumID = String(repeating: "a", count: 32)
        var item: [String: Any] = [
            "id": recordID.uuidString, "profileID": profileID.uuidString,
            "chromiumID": chromiumID, "name": "Fixture", "version": "1",
            "hasAction": false, "isEnabled": true, "deniedPermissions": [],
            "requestedOrigins": [], "allowedOrigins": []
        ]
        func decode(version: Int, item: [String: Any]) throws -> ChromiumExtensionManager.Snapshot {
            let data = try JSONSerialization.data(withJSONObject: ["version": version, "records": [item]])
            return try JSONDecoder().decode(ChromiumExtensionManager.Snapshot.self, from: data)
        }

        item["sourcePath"] = "\(profileID.uuidString.lowercased())/\(recordID.uuidString.lowercased())"
        let old = try decode(version: 1, item: item)
        XCTAssertEqual(old.version, 1)
        XCTAssertNil(old.records[0].source)
        XCTAssertTrue(ChromiumExtensionManager.valid(old.records[0]))
        XCTAssertTrue(ChromiumExtensionManager.isVisible(old.records[0], profileID: profileID))

        item.removeValue(forKey: "sourcePath")
        item["source"] = "store"
        let store = try decode(version: 2, item: item)
        XCTAssertTrue(ChromiumExtensionManager.valid(store.records[0]))
        XCTAssertNil(store.records[0].sourcePath)
        let encoded = try JSONEncoder().encode(store)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sourcePath"))
        XCTAssertEqual(try JSONDecoder().decode(ChromiumExtensionManager.Snapshot.self, from: encoded).records,
                       store.records)
        #if COBBLE_CHROMIUM_ABI15
        XCTAssertTrue(ChromiumExtensionManager.isVisible(store.records[0], profileID: profileID))
        #else
        XCTAssertFalse(ChromiumExtensionManager.isVisible(store.records[0], profileID: profileID))
        #endif
    }

    #if COBBLE_CHROMIUM_ABI15
    func testOnlyManageableStoreExtensionsAreAdopted() throws {
        let id = String(repeating: "a", count: 32)
        func extensionItem(source: String, manageable: Bool, id: String = id) throws -> ChromiumExtension {
            let json: [String: Any] = ["id": id, "name": "Fixture", "version": "1",
                "enabled": true, "hasAction": false, "path": "/tmp/fixture",
                "requestedOrigins": [], "allowedOrigins": [], "deniedPermissions": [],
                "source": source, "userManageable": manageable, "disableReasons": 0]
            return try JSONDecoder().decode(ChromiumExtension.self,
                from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertTrue(ChromiumExtensionManager.canAdoptStore(try extensionItem(source: "store", manageable: true)))
        XCTAssertFalse(ChromiumExtensionManager.canAdoptStore(try extensionItem(source: "store", manageable: false)))
        XCTAssertFalse(ChromiumExtensionManager.canAdoptStore(try extensionItem(source: "policy", manageable: true)))
        XCTAssertFalse(ChromiumExtensionManager.canAdoptStore(try extensionItem(source: "other", manageable: true)))
        XCTAssertFalse(ChromiumExtensionManager.canAdoptStore(try extensionItem(source: "store", manageable: true, id: "bad")))
    }
    #endif

    #if COBBLE_CHROMIUM_ABI10
    func testLocalReloadAuthorizationRequiresTheExactFile() {
        let file = URL(fileURLWithPath: "/tmp/Cobble-local-reload.html")
        XCTAssertTrue(ChromiumPage.isAuthorizedLocalFile(file, authorizedURL: file))
        XCTAssertFalse(ChromiumPage.isAuthorizedLocalFile(file,
            authorizedURL: URL(fileURLWithPath: "/tmp/other.html")))
        XCTAssertFalse(ChromiumPage.isAuthorizedLocalFile(URL(string: "https://example.com"), authorizedURL: file))
        XCTAssertFalse(ChromiumPage.isAuthorizedLocalFile(file, authorizedURL: nil))
    }
    #endif

    func testPrivateContextsOmitWebsiteDataRemoval() {
        XCTAssertFalse(ChromiumContext.capabilities(isPrivate: false).websiteDataRemoval.isEmpty)
        XCTAssertTrue(ChromiumContext.capabilities(isPrivate: true).websiteDataRemoval.isEmpty)
    }

    func testLoginSharingRequiresNewSDKAndNormalContext() {
        XCTAssertFalse(ChromiumContext.capabilities(isPrivate: true).supportsCookieTransfer)
        #if COBBLE_CHROMIUM_ABI14
        XCTAssertTrue(ChromiumContext.capabilities(isPrivate: false).supportsCookieTransfer)
        #else
        XCTAssertFalse(ChromiumContext.capabilities(isPrivate: false).supportsCookieTransfer)
        #endif
    }

    func testBrowserIdentityCapabilityAndPresetMapping() {
        XCTAssertTrue(WebKitEngine.supported.supportsBrowserIdentity)
        #if COBBLE_CHROMIUM_ABI16
        XCTAssertTrue(ChromiumContext.capabilities(isPrivate: false).supportsBrowserIdentity)
        XCTAssertTrue(ChromiumContext.capabilities(isPrivate: true).supportsBrowserIdentity)
        XCTAssertEqual(SiteBrowserIdentity.allCases.map(\.chromiumIdentity),
                       [.standard, .androidPhone, .androidTablet, .iPhone, .iPad])
        #else
        XCTAssertFalse(ChromiumContext.capabilities(isPrivate: false).supportsBrowserIdentity)
        #endif
    }

    func testCacheCutoffIsAdvertisedOnlyForNormalContextsWhenSupported() {
        let normal = ChromiumContext.capabilities(isPrivate: false)
        let privateContext = ChromiumContext.capabilities(isPrivate: true)
        #if COBBLE_CHROMIUM_ABI13
        XCTAssertTrue(normal.supportsWebsiteDataRemoval(categories: [.cache], scope: .profileSince))
        #else
        XCTAssertFalse(normal.supportsWebsiteDataRemoval(categories: [.cache], scope: .profileSince))
        #endif
        XCTAssertFalse(privateContext.supportsWebsiteDataRemoval(categories: [.cache], scope: .profileSince))
        XCTAssertFalse(privateContext.supportsWebsiteDataRemoval(categories: [.siteData], scope: .profileSince))
    }
}
#endif
