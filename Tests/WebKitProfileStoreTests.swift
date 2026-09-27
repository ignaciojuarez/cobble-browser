import XCTest
import WebKit
@testable import Cobble

@MainActor
final class WebKitProfileStoreTests: XCTestCase {
    func testWebsiteDataCategoriesRemoveOnlyRequestedCookiesAndRejectRecentSiteData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleProfileStoreTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = Profile(name: "Fixture", storeBinding: .named(UUID()))
        let engine = WebKitEngine(directory: directory, dataStoreOverride: .nonPersistent())
        let settings = SiteSettingsStore(directory: directory)
        let context = try XCTUnwrap(try engine.makeContext(profile: profile,
            id: BrowsingContextID(engineID: .webKit, profileID: profile.id, privateWindowID: nil),
            siteSettings: settings) as? WebKitContext)
        defer { Task { await context.close() } }
        let first = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "first.test", .path: "/", .name: "first", .value: "one"
        ]))
        let second = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "second.test", .path: "/", .name: "second", .value: "two"
        ]))
        await set(first, in: context.dataStore)
        await set(second, in: context.dataStore)

        try await context.removeWebsiteData(.init(categories: [.cache], scope: .profile(modifiedSince: nil)))
        var cookieNames = Set(await cookies(in: context.dataStore).map(\.name))
        XCTAssertEqual(cookieNames, ["first", "second"])

        let records = try await context.websiteData()
        let firstRecord = try XCTUnwrap(records.first { $0.displayName.contains("first.test") })
        try await context.removeWebsiteData(.init(categories: [.siteData], scope: .records([firstRecord.id])))
        cookieNames = Set(await cookies(in: context.dataStore).map(\.name))
        XCTAssertEqual(cookieNames, ["second"])

        do {
            try await context.removeWebsiteData(.init(categories: [.siteData],
                scope: .profile(modifiedSince: Date(timeIntervalSinceNow: -60))))
            XCTFail("Recent site-data removal must be rejected")
        } catch let error as EngineError {
            guard case .unsupported = error else { return XCTFail("Unexpected error: \(error)") }
        }
        cookieNames = Set(await cookies(in: context.dataStore).map(\.name))
        XCTAssertEqual(cookieNames, ["second"])

        try await context.removeWebsiteData(.init(categories: [.siteData], scope: .profile(modifiedSince: nil)))
        let remainingCookies = await cookies(in: context.dataStore)
        XCTAssertTrue(remainingCookies.isEmpty)

        await context.close()
        do {
            _ = try await context.websiteData()
            XCTFail("A closed context must not publish website data records.")
        } catch let error as EngineError {
            guard case .closed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testInjectedStoreStillRemovesProfileBlockerMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleProfileStoreTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = Profile(name: "Fixture", storeBinding: .named(UUID()))
        let engine = WebKitEngine(directory: directory, dataStoreOverride: .nonPersistent())
        await engine.blocker.importRules(json: #"[{"trigger":{"url-filter":"fixture"},"action":{"type":"block"}}]"#, profileID: profile.id)
        XCTAssertTrue(engine.blocker.isEnabled(profileID: profile.id))

        try await engine.removeProfile(profile)

        XCTAssertFalse(engine.blocker.isEnabled(profileID: profile.id))
    }

    func testNamedProfilesUseIndependentCookieStores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleProfileStoreTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Profile(name: "First", storeBinding: .named(UUID()))
        let second = Profile(name: "Second", storeBinding: .named(UUID()))
        let engine = WebKitEngine(directory: directory)
        let references = ContextReferences()
        do {
            try await verifyCookieIsolation(first: first, second: second, engine: engine, directory: directory, references: references)
        } catch {
            try? await engine.removeProfile(first)
            try? await engine.removeProfile(second)
            throw error
        }
        XCTAssertNil(references.first)
        XCTAssertNil(references.second)
        XCTAssertNil(references.firstStore)
        XCTAssertNil(references.secondStore)
        try await engine.removeProfile(first)
        try await engine.removeProfile(second)
    }

    private func verifyCookieIsolation(first: Profile, second: Profile, engine: WebKitEngine, directory: URL,
                                       references: ContextReferences) async throws {
        let settings = SiteSettingsStore(directory: directory)
        var firstContext: WebKitContext? = try XCTUnwrap(try engine.makeContext(profile: first,
            id: BrowsingContextID(engineID: .webKit, profileID: first.id, privateWindowID: nil), siteSettings: settings) as? WebKitContext)
        var secondContext: WebKitContext? = try XCTUnwrap(try engine.makeContext(profile: second,
            id: BrowsingContextID(engineID: .webKit, profileID: second.id, privateWindowID: nil), siteSettings: settings) as? WebKitContext)
        var firstStore: WKWebsiteDataStore? = firstContext?.dataStore
        var secondStore: WKWebsiteDataStore? = secondContext?.dataStore
        references.first = firstContext
        references.second = secondContext
        references.firstStore = firstStore
        references.secondStore = secondStore
        XCTAssertNotEqual(try XCTUnwrap(firstStore).identifier, try XCTUnwrap(secondStore).identifier)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "profile-isolation.cobble.test", .path: "/", .name: "identity", .value: "first", .secure: "TRUE"
        ]))
        await set(cookie, in: try XCTUnwrap(firstStore))
        let firstCookies = await cookies(in: try XCTUnwrap(firstStore))
        let secondCookies = await cookies(in: try XCTUnwrap(secondStore))
        XCTAssertTrue(firstCookies.contains { $0.name == cookie.name && $0.value == cookie.value })
        XCTAssertFalse(secondCookies.contains { $0.name == cookie.name })
        await firstContext?.close()
        await secondContext?.close()
        firstStore = nil
        secondStore = nil
        firstContext = nil
        secondContext = nil
    }

    private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func set(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }
}

@MainActor private final class ContextReferences {
    weak var first: WebKitContext?
    weak var second: WebKitContext?
    weak var firstStore: WKWebsiteDataStore?
    weak var secondStore: WKWebsiteDataStore?
}
