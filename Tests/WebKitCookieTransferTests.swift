import ObjectiveC
import WebKit
import XCTest
@testable import Cobble

@MainActor final class WebKitCookieTransferTests: XCTestCase {
    private let url = URL(string: "https://sub.example.test/account")!

    func testCookieTransferPreservesScopeAndMetadataAndReplacesAllPaths() async throws {
        let source = try makeContext()
        let destination = try makeContext()
        let expiry = Date(timeIntervalSinceNow: 86_400)
        let hostOnly = try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "host=value; Path=/account; Secure; HttpOnly; SameSite=Strict"
        ], for: url).first)
        let domain = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.test", .path: "/", .name: "domain", .value: "shared",
            .expires: expiry, .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: "none"
        ]))
        await set(hostOnly, in: source.dataStore)
        await set(domain, in: source.dataStore)
        await set(try cookie(name: "session", domain: "sub.example.test", path: "/"), in: source.dataStore)
        await set(try cookie(name: "other", domain: "other.test", path: "/"), in: source.dataStore)

        let snapshot = try await source.exportCookies(for: url)
        XCTAssertEqual(snapshot.skipped, 0)
        XCTAssertEqual(snapshot.cookies.count, 3)
        let exportedHost = try XCTUnwrap(snapshot.cookies.first { $0.name == "host" })
        XCTAssertEqual(exportedHost.domain, "sub.example.test")
        XCTAssertEqual(exportedHost.path, "/account")
        XCTAssertTrue(exportedHost.secure)
        XCTAssertTrue(exportedHost.httpOnly)
        XCTAssertEqual(exportedHost.sameSite, .strict)
        let exportedDomain = try XCTUnwrap(snapshot.cookies.first { $0.name == "domain" })
        XCTAssertEqual(exportedDomain.domain, ".example.test")
        XCTAssertEqual(try XCTUnwrap(exportedDomain.expires), expiry.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(exportedDomain.sameSite, .lax)
        let exportedSession = try XCTUnwrap(snapshot.cookies.first { $0.name == "session" })
        XCTAssertNil(exportedSession.expires)
        XCTAssertEqual(exportedSession.sameSite, .lax)

        await set(try cookie(name: "stale", domain: "sub.example.test", path: "/old"), in: destination.dataStore)
        await set(try cookie(name: "other", domain: "other.test", path: "/"), in: destination.dataStore)
        let rejected = try await destination.replaceCookies(snapshot.cookies, for: url)
        XCTAssertEqual(rejected, 0)
        let replaced = try await destination.exportCookies(for: url)
        XCTAssertEqual(Set(replaced.cookies.map(\.name)), ["host", "domain", "session"])
        XCTAssertFalse(replaced.cookies.contains { $0.name == "stale" })
        let afterReplacement = await cookies(in: destination.dataStore)
        XCTAssertTrue(afterReplacement.contains { $0.name == "other" })

        let logoutRejected = try await destination.replaceCookies([], for: url)
        XCTAssertEqual(logoutRejected, 0)
        let afterLogout = try await destination.exportCookies(for: url)
        XCTAssertTrue(afterLogout.cookies.isEmpty)
        let allAfterLogout = await cookies(in: destination.dataStore)
        XCTAssertTrue(allAfterLogout.contains { $0.name == "other" })
    }

    func testForeignCookieExpiryPrecisionRoundTrips() async throws {
        let context = try makeContext()
        let cookie = EngineCookie(name: "foreign", value: "fixture", domain: ".example.test", path: "/",
                                  expires: floor(Date().timeIntervalSince1970) + 86400.123456,
                                  secure: true, httpOnly: true, sameSite: .lax)
        let rejected = try await context.replaceCookies([cookie], for: url)
        let stored = try await context.exportCookies(for: url)
        var expected = cookie
        expected.expires = cookie.expires.map { floor($0) }
        XCTAssertEqual(stored.cookies, [expected])
        XCTAssertEqual(rejected, 0)
    }

    func testInvalidBatchDoesNotMutateDestination() async throws {
        let context = try makeContext()
        await set(try cookie(name: "existing", domain: "sub.example.test", path: "/"), in: context.dataStore)
        let invalid = EngineCookie(name: "bad", value: "value", domain: "sub.example.test", path: "/",
                                   expires: nil, secure: false, httpOnly: true, sameSite: .none)

        do {
            _ = try await context.replaceCookies([invalid], for: url)
            XCTFail("SameSite=None without Secure must fail before deletion")
        } catch {}

        let afterFailure = try await context.exportCookies(for: url)
        XCTAssertEqual(afterFailure.cookies.map(\.name), ["existing"])

        var expired = afterFailure.cookies[0]
        expired.expires = 1
        let rejected = try await context.replaceCookies([expired], for: url)
        XCTAssertEqual(rejected, 1)
        let afterRejection = try await context.exportCookies(for: url)
        XCTAssertEqual(afterRejection.cookies.map(\.name), ["existing"])
    }

    func testAmbiguousSameSitePoliciesNarrowToLax() async throws {
        let context = try makeContext()
        let records = [
            EngineCookie(name: "none", value: "value", domain: "sub.example.test", path: "/",
                         expires: nil, secure: true, httpOnly: true, sameSite: .none),
            EngineCookie(name: "unspecified", value: "value", domain: "sub.example.test", path: "/",
                         expires: nil, secure: true, httpOnly: true, sameSite: .unspecified)
        ]

        let rejected = try await context.replaceCookies(records, for: url)
        XCTAssertEqual(rejected, 0)
        let exported = try await context.exportCookies(for: url)
        XCTAssertEqual(Set(exported.cookies.map(\.sameSite)), [.lax])
    }

    func testPartitionedCookiesAreSkippedAndNeverDeleted() async throws {
        let context = try makeContext()
        let ordinary = try cookie(name: "ordinary", domain: "sub.example.test", path: "/")
        let partitioned = try makePartitionedCookie(from: try cookie(name: "partitioned", domain: "sub.example.test", path: "/"))
        XCTAssertFalse(try WebKitCookiePartition.isPartitioned(ordinary))
        XCTAssertTrue(try WebKitCookiePartition.isPartitioned(partitioned))
        await set(ordinary, in: context.dataStore)
        await set(partitioned, in: context.dataStore)

        let snapshot = try await context.exportCookies(for: url)
        XCTAssertEqual(snapshot.cookies.map(\.name), ["ordinary"])
        XCTAssertEqual(snapshot.partitioned, 1)
        XCTAssertEqual(snapshot.skipped, 1, "The coordinator distinguishes known partitions from unsupported omissions")

        let rejected = try await context.replaceCookies([], for: url)
        XCTAssertEqual(rejected, 0)
        let remaining = await cookies(in: context.dataStore)
        XCTAssertEqual(remaining.map(\.name), ["partitioned"])
        XCTAssertTrue(try WebKitCookiePartition.isPartitioned(try XCTUnwrap(remaining.first)))
    }

    func testPrivateContextRejectsCookieTransfer() async throws {
        let context = try makeContext(isPrivate: true)
        XCTAssertFalse(context.capabilities.supportsCookieTransfer)
        do {
            _ = try await context.exportCookies(for: url)
            XCTFail("Private cookie transfer must be unavailable")
        } catch let error as EngineError {
            guard case .unsupported = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private func makeContext(isPrivate: Bool = false) throws -> WebKitContext {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleCookieTransferTests-\(UUID())")
        let profile = Profile(name: "Fixture", storeBinding: .named(UUID()))
        let engine = WebKitEngine(directory: directory, dataStoreOverride: .nonPersistent())
        return try XCTUnwrap(try engine.makeContext(profile: profile,
            id: BrowsingContextID(engineID: .webKit, profileID: profile.id,
                                  privateWindowID: isPrivate ? UUID() : nil),
            siteSettings: SiteSettingsStore(directory: directory)) as? WebKitContext)
    }

    private func cookie(name: String, domain: String, path: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: path, .name: name, .value: "value"]))
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

    private func makePartitionedCookie(from cookie: HTTPCookie) throws -> HTTPCookie {
        var properties = try XCTUnwrap(cookie.properties)
        properties[HTTPCookiePropertyKey("StoragePartition")] = "fixture.test"
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}
