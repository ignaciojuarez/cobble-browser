import XCTest
@testable import Cobble

@MainActor
final class SiteSettingsTests: XCTestCase {
    func testZoomSyncPreservesLocalBrowserIdentity() throws {
        try withDirectory { directory in
            let store = SiteSettingsStore(directory: directory)
            let profile = Profile.defaultID
            let origin = URL(string: "https://identity.example")!
            XCTAssertTrue(store.setBrowserIdentity(.iPad, for: origin, profileID: profile))
            store.setZoom(1.5, origin: origin, profileID: profile)
            try store.applySyncItems([], profileIDs: [profile])
            XCTAssertNil(store.setting(origin: origin, profileID: profile).zoom)
            XCTAssertEqual(store.browserIdentity(for: origin, profileID: profile), .iPad)
            XCTAssertEqual(SiteSettingsStore(directory: directory).browserIdentity(for: origin, profileID: profile), .iPad)
        }
    }

    func testPopupPolicyAllowsScriptsOnlyForNormalRememberedAllow() {
        XCTAssertFalse(SiteSettingsStore.allowsPopup(setting: .ask, isPrivate: false, userGesture: false))
        XCTAssertTrue(SiteSettingsStore.allowsPopup(setting: .ask, isPrivate: false, userGesture: true))
        XCTAssertTrue(SiteSettingsStore.allowsPopup(setting: .allow, isPrivate: false, userGesture: false))
        XCTAssertFalse(SiteSettingsStore.allowsPopup(setting: .deny, isPrivate: false, userGesture: false))
        XCTAssertTrue(SiteSettingsStore.allowsPopup(setting: .deny, isPrivate: false, userGesture: true))
        XCTAssertFalse(SiteSettingsStore.allowsPopup(setting: .allow, isPrivate: true, userGesture: false))
        XCTAssertTrue(SiteSettingsStore.allowsPopup(setting: .deny, isPrivate: true, userGesture: true))
    }

    func testRememberedMediaPermissionsRespectPrivateAndEmbeddedContexts() {
        var setting = SiteSetting(profileID: Profile.defaultID, origin: "https://cobble.test", camera: .allow, microphone: .ask)
        XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.camera], setting: setting, isPrivate: false, sameOrigin: true), .allow)
        XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.camera, .microphone], setting: setting, isPrivate: false, sameOrigin: true), .ask)
        XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.camera], setting: setting, isPrivate: false, sameOrigin: false), .ask)
        setting.microphone = .deny
        XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.camera, .microphone], setting: setting, isPrivate: false, sameOrigin: true), .deny)
        XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.microphone], setting: setting, isPrivate: false, sameOrigin: false), .deny)
        XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.microphone], setting: setting, isPrivate: true, sameOrigin: true), .ask)
        XCTAssertEqual(SiteSettingsStore.mediaDecision(kinds: [.camera], setting: setting, isPrivate: true, sameOrigin: true), .ask)
    }

    private func withDirectory(body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSiteSettingsTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testCanonicalOriginsKeepSecurityBoundaries() {
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "HTTPS://EXAMPLE.COM:443/path?q=1#fragment")!), "https://example.com")
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "http://example.com:80/path")!), "http://example.com")
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "https://example.com:8443/path")!), "https://example.com:8443")
        XCTAssertEqual(AddressResolver.canonicalOrigin(URL(string: "http://[::1]:8080/path")!), "http://[::1]:8080")
        XCTAssertNil(AddressResolver.canonicalOrigin(URL(string: "file:///tmp/a")!))
        XCTAssertNil(AddressResolver.canonicalOrigin(URL(string: "https://example.com:70000")!))
    }

    func testZoomRoundTripsAndPermissionForgettingPreservesItWithoutSummaryNoise() throws {
        try withDirectory { directory in
            let store = SiteSettingsStore(directory: directory)
            let profile = UUID(), origin = URL(string: "https://example.com/path")!
            XCTAssertTrue(store.update(SiteSetting(profileID: profile, origin: origin.absoluteString, camera: .allow, microphone: .deny, popups: .allow)))
            store.setZoom(1.5, origin: origin, profileID: profile)
            let saved = SiteSettingsStore(directory: directory).setting(origin: origin, profileID: profile)
            XCTAssertEqual(saved.zoom, 1.5)
            XCTAssertEqual(saved.camera, .allow)
            XCTAssertEqual(saved.microphone, .deny)
            XCTAssertEqual(saved.popups, .allow)
            for (url, id, engine) in [("https://example.com", UUID(), EngineID.webKit),
                                      ("http://example.com", profile, .webKit), ("https://example.com:8443", profile, .webKit),
                                      ("https://sub.example.com", profile, .webKit), ("https://example.com", profile, EngineID(rawValue: "other"))] {
                XCTAssertNil(store.setting(origin: URL(string: url)!, profileID: id, engineID: engine).zoom)
            }
            XCTAssertTrue(store.forget(origin: saved.origin, profileID: profile))
            let forgotten = store.setting(origin: origin, profileID: profile)
            XCTAssertEqual(forgotten.zoom, 1.5)
            XCTAssertEqual(forgotten.camera, .ask)
            XCTAssertEqual(forgotten.microphone, .ask)
            XCTAssertEqual(forgotten.popups, .ask)
            XCTAssertTrue(store.summaries(profileID: profile, engines: []).isEmpty)
            store.remove(id: saved.id)
            store.clear(profileID: profile)
            XCTAssertEqual(store.setting(origin: origin, profileID: profile).zoom, 1.5)
            var changed = store.setting(origin: origin, profileID: profile)
            changed.camera = .allow
            store.update(changed)
            store.setZoom(nil, origin: origin, profileID: profile)
            XCTAssertNil(store.setting(origin: origin, profileID: profile).zoom)
            XCTAssertEqual(store.setting(origin: origin, profileID: profile).camera, .allow)
        }
    }

    func testBrowserIdentitySharesOriginAcrossEnginesWithoutChangingPermissionsOrZoom() throws {
        try withDirectory { directory in
            let profile = UUID(), otherProfile = UUID()
            let origin = URL(string: "https://example.com/path")!
            let store = SiteSettingsStore(directory: directory)
            XCTAssertTrue(store.update(SiteSetting(profileID: profile, origin: origin.absoluteString,
                                                   camera: .allow, zoom: 1.5)))
            XCTAssertTrue(store.update(SiteSetting(profileID: profile, origin: origin.absoluteString,
                                                   microphone: .deny, engineID: EngineID(rawValue: "chromium"))))
            XCTAssertTrue(store.setBrowserIdentity(.iPhone, for: origin, profileID: profile))
            let reopened = SiteSettingsStore(directory: directory)
            XCTAssertEqual(reopened.browserIdentity(for: URL(string: "https://example.com/other")!, profileID: profile), .iPhone)
            XCTAssertEqual(reopened.summaries(profileID: profile, engines: []).first?.browserIdentity, .iPhone)
            XCTAssertTrue(reopened.setBrowserIdentity(.androidPhone, for: URL(string: "https://identity-only.example")!, profileID: profile))
            XCTAssertFalse(reopened.summaries(profileID: profile, engines: []).contains { $0.origin == "https://identity-only.example" })
            XCTAssertTrue(reopened.summaries(profileID: profile, engines: [], includeIdentity: true).contains { $0.origin == "https://identity-only.example" })
            XCTAssertEqual(reopened.setting(origin: origin, profileID: profile).camera, .allow)
            XCTAssertEqual(reopened.setting(origin: origin, profileID: profile).zoom, 1.5)
            XCTAssertEqual(reopened.setting(origin: origin, profileID: profile, engineID: EngineID(rawValue: "chromium")).microphone, .deny)
            XCTAssertEqual(reopened.browserIdentity(for: origin, profileID: otherProfile), .standard)
            XCTAssertEqual(reopened.browserIdentity(for: URL(string: "http://example.com")!, profileID: profile), .standard)
            XCTAssertFalse(reopened.setBrowserIdentity(.iPad, for: URL(string: "file:///tmp/test")!, profileID: profile))
            XCTAssertTrue(reopened.forget(origin: "https://example.com", profileID: profile))
            XCTAssertEqual(reopened.browserIdentity(for: origin, profileID: profile), .iPhone)
            XCTAssertEqual(reopened.setting(origin: origin, profileID: profile).camera, .ask)
            XCTAssertTrue(reopened.setBrowserIdentity(.standard, for: origin, profileID: profile))
            XCTAssertEqual(reopened.browserIdentity(for: origin, profileID: profile), .standard)
            XCTAssertEqual(reopened.setting(origin: origin, profileID: profile).zoom, 1.5)
            XCTAssertTrue(reopened.forget(origin: "https://identity-only.example", profileID: profile))
            XCTAssertEqual(reopened.browserIdentity(for: URL(string: "https://identity-only.example")!, profileID: profile), .androidPhone)
            XCTAssertTrue(reopened.setBrowserIdentity(.standard, for: URL(string: "https://identity-only.example")!, profileID: profile))
            XCTAssertFalse(reopened.entries.contains { $0.origin == "https://identity-only.example" })
        }
    }

    func testZoomValidationAndLegacyDecodePreserveOtherSettings() throws {
        try withDirectory { directory in
            let store = SiteSettingsStore(directory: directory), origin = URL(string: "https://example.com")!, profile = UUID()
            store.setZoom(2, origin: origin, profileID: profile)
            for invalid in [0.49, 3.01, Double.infinity, Double.nan] {
                store.setZoom(invalid, origin: origin, profileID: profile)
                XCTAssertEqual(store.setting(origin: origin, profileID: profile).zoom, 2)
                XCTAssertNotNil(store.lastError)
                XCTAssertTrue(store.persistenceStatus.canSave)
            }
            let legacy = SiteSetting(profileID: profile, origin: origin.absoluteString, camera: .allow)
            let data = try JSONEncoder().encode(legacy)
            XCTAssertNil(try JSONDecoder().decode(SiteSetting.self, from: data).zoom)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json["zoom"] = 99
            let repaired = try JSONDecoder().decode(SiteSetting.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(repaired.zoom)
            XCTAssertEqual(repaired.camera, .allow)
        }
    }

    func testDefaultLookupIsConservativeAndDoesNotWrite() throws {
        try withDirectory { directory in
            let store = SiteSettingsStore(directory: directory)
            let setting = store.setting(origin: URL(string: "https://example.com/path")!, profileID: UUID())
            XCTAssertEqual(setting.origin, "https://example.com")
            XCTAssertEqual(setting.camera, .ask)
            XCTAssertEqual(setting.microphone, .ask)
            XCTAssertEqual(setting.popups, .ask)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testPopupPreferenceRoundTripsWithoutRevivingLegacyAllowPopups() throws {
        try withDirectory { directory in
            let profile = UUID()
            let store = SiteSettingsStore(directory: directory)
            var setting = store.setting(origin: URL(string: "https://example.com")!, profileID: profile)
            setting.popups = .allow
            XCTAssertTrue(store.update(setting))
            let loaded = SiteSettingsStore(directory: directory).setting(origin: URL(string: "https://example.com")!, profileID: profile)
            XCTAssertEqual(loaded.popups, .allow)
        }
    }

    func testLegacyAllowPopupsKeyIsIgnored() throws {
        try withDirectory { directory in
            let profile = UUID(), id = UUID()
            let json = """
            {"version":2,"entries":[{"id":"\(id.uuidString)","profileID":"\(profile.uuidString)","origin":"https://example.com","camera":"allow","microphone":"ask","allowPopups":true,"engineID":"webkit"}]}
            """
            try Data(json.utf8).write(to: directory.appendingPathComponent("site-settings.json"))
            let store = SiteSettingsStore(directory: directory)
            XCTAssertNil(store.lastError)
            XCTAssertEqual(store.entries.count, 1)
            XCTAssertEqual(store.entries[0].camera, .allow)
            XCTAssertEqual(store.entries[0].popups, .ask)
            XCTAssertEqual(store.entries[0].browserIdentity, .standard)
        }
    }

    func testUpdateNormalizesOriginPreservesIdentityAndRoundTrips() throws {
        try withDirectory { directory in
            let profile = UUID()
            let store = SiteSettingsStore(directory: directory)
            var first = store.setting(origin: URL(string: "https://example.com/one")!, profileID: profile)
            first.camera = .allow
            store.update(first)
            var duplicate = SiteSetting(profileID: profile, origin: "HTTPS://EXAMPLE.COM:443/two", camera: .deny, microphone: .allow)
            duplicate.id = UUID()
            store.update(duplicate)
            XCTAssertEqual(store.entries.count, 1)
            XCTAssertEqual(store.entries[0].id, first.id)
            let reopened = SiteSettingsStore(directory: directory)
            let loaded = reopened.setting(origin: URL(string: "https://example.com/three")!, profileID: profile)
            XCTAssertEqual(loaded.id, first.id)
            XCTAssertEqual(loaded.camera, .deny)
            XCTAssertEqual(loaded.microphone, .allow)
            XCTAssertEqual(loaded.popups, .ask)
            XCTAssertNil(reopened.lastError)
        }
    }

    func testProfilesSchemesAndPortsRemainIsolated() throws {
        try withDirectory { directory in
            let first = UUID(), second = UUID()
            let store = SiteSettingsStore(directory: directory)
            store.update(SiteSetting(profileID: first, origin: "https://example.com", camera: .allow))
            for (origin, profile) in [("https://example.com", second), ("http://example.com", first), ("https://example.com:8443", first), ("https://sub.example.com", first)] {
                XCTAssertEqual(store.setting(origin: URL(string: origin)!, profileID: profile).camera, .ask)
            }
        }
    }

    func testRemoveAndClearRestorePromptDefaultsWithoutAffectingOtherProfiles() throws {
        try withDirectory { directory in
            let first = UUID(), second = UUID()
            let store = SiteSettingsStore(directory: directory)
            let item = SiteSetting(profileID: first, origin: "https://one.example", camera: .allow)
            store.update(item)
            store.update(SiteSetting(profileID: first, origin: "https://two.example", microphone: .deny))
            store.update(SiteSetting(profileID: second, origin: "https://one.example", camera: .deny))
            store.remove(id: item.id)
            XCTAssertEqual(store.setting(origin: URL(string: item.origin)!, profileID: first).camera, .ask)
            store.clear(profileID: first)
            XCTAssertEqual(store.entries.count, 1)
            XCTAssertEqual(store.entries[0].profileID, second)
            XCTAssertEqual(store.entries[0].camera, .deny)
            XCTAssertEqual(SiteSettingsStore(directory: directory).entries.count, 1)
        }
    }

    func testCorruptInputIsPreservedAndDisablesAllWrites() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("site-settings.json")
            let corrupt = Data("{broken permissions".utf8)
            try corrupt.write(to: source)
            let store = SiteSettingsStore(directory: directory)
            XCTAssertNotNil(store.lastError)
            XCTAssertFalse(store.persistenceStatus.canSave)
            XCTAssertTrue(store.entries.isEmpty)
            let setting = SiteSetting(profileID: UUID(), origin: "https://example.com", camera: .allow)
            XCTAssertFalse(store.update(setting))
            XCTAssertFalse(store.forget(origin: setting.origin, profileID: setting.profileID))
            store.remove(id: setting.id)
            store.clear(profileID: setting.profileID)
            XCTAssertEqual(try Data(contentsOf: source), corrupt)
            XCTAssertTrue(store.entries.isEmpty)
            let copies = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".corrupt-") }
            XCTAssertEqual(copies.count, 1)
            XCTAssertEqual(try Data(contentsOf: copies[0]), corrupt)
        }
    }

    func testFutureFormatCannotBeOverwritten() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("site-settings.json")
            let future = Data("{\"version\":999,\"entries\":[]}".utf8)
            try future.write(to: source)
            let store = SiteSettingsStore(directory: directory)
            XCTAssertNotNil(store.lastError)
            XCTAssertFalse(store.persistenceStatus.canSave)
            let setting = SiteSetting(profileID: UUID(), origin: "https://example.com", camera: .allow)
            XCTAssertFalse(store.update(setting))
            XCTAssertFalse(store.forget(origin: setting.origin, profileID: setting.profileID))
            XCTAssertEqual(try Data(contentsOf: source), future)
            XCTAssertTrue(store.entries.isEmpty)
        }
    }

    func testInvalidOriginIsNotPersisted() throws {
        try withDirectory { directory in
            let store = SiteSettingsStore(directory: directory)
            XCTAssertFalse(store.update(SiteSetting(profileID: UUID(), origin: "javascript:alert(1)", camera: .allow)))
            XCTAssertNotNil(store.lastError)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testEmptyEngineIdentifierIsRejectedButUnknownEngineIsPreserved() throws {
        try withDirectory { directory in
            let store = SiteSettingsStore(directory: directory)
            XCTAssertFalse(store.update(SiteSetting(profileID: UUID(), origin: "https://example.com",
                                                     engineID: EngineID(rawValue: ""))))
            let unknown = SiteSetting(profileID: UUID(), origin: "https://example.com",
                                      engineID: EngineID(rawValue: "future.engine"))
            XCTAssertTrue(store.update(unknown))
            XCTAssertEqual(SiteSettingsStore(directory: directory).entries.first?.engineID.rawValue, "future.engine")

            let invalid = """
                {"version":2,"entries":[{"id":"\(UUID().uuidString)","profileID":"\(UUID().uuidString)","origin":"https://example.com","camera":"ask","microphone":"ask","engineID":""}]}
                """
            try Data(invalid.utf8).write(to: directory.appendingPathComponent("site-settings.json"))
            let rejected = SiteSettingsStore(directory: directory)
            XCTAssertTrue(rejected.entries.isEmpty)
            XCTAssertNotNil(rejected.lastError)
        }
    }
}
