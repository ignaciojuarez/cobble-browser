import Foundation
import ObjectiveC
import WebKit

@MainActor extension WebKitContext {
    func exportCookies(for url: URL) async throws -> CookieTransferSnapshot {
        guard !closed else { throw EngineError.closed }
        guard !id.isPrivate else { throw EngineError.unsupported(String(localized: "login sharing in private windows")) }
        let host = try EngineCookie.host(for: url)
        var result: [EngineCookie] = []
        var skipped = 0
        var partitioned = 0
        let stored = await allCookies()
        try checkActive()
        for cookie in stored where EngineCookie.matches(domain: cookie.domain, host: host) {
            if try WebKitCookiePartition.isPartitioned(cookie) {
                skipped += 1; partitioned += 1
                continue
            }
            guard let converted = try? EngineCookie(cookie),
                  (try? converted.validate(for: url)) != nil else {
                skipped += 1
                continue
            }
            result.append(converted)
        }
        try checkActive()
        return CookieTransferSnapshot(cookies: result, skipped: skipped, partitioned: partitioned)
    }

    func replaceCookies(_ cookies: [EngineCookie], for url: URL) async throws -> Int {
        guard !closed else { throw EngineError.closed }
        guard !id.isPrivate else { throw EngineError.unsupported(String(localized: "login sharing in private windows")) }
        let host = try EngineCookie.host(for: url)
        try cookies.forEach { try $0.validate(for: url) }
        let normalized = cookies.map(\.normalizedForWebKit)
        let identities = normalized.map(EngineCookie.Identity.init)
        let identitySet = Set(identities)
        guard identitySet.count == identities.count else {
            throw EngineError.notReady(String(localized: "A cookie could not be safely shared. Sign in again in this engine."))
        }
        let now = Date().timeIntervalSince1970
        let expired = normalized.filter { $0.expires.map { $0 <= now } ?? false }.count
        guard expired == 0 else { return expired }
        let replacements = try normalized.map { cookie -> HTTPCookie in
            guard let result = cookie.httpCookie else {
                throw EngineError.notReady(String(localized: "A cookie could not be safely shared. Sign in again in this engine."))
            }
            return result
        }

        let existing = await allCookies()
        try checkActive()
        var deletions: [HTTPCookie] = []
        for cookie in existing where EngineCookie.matches(domain: cookie.domain, host: host) {
            guard try !WebKitCookiePartition.isPartitioned(cookie) else { continue }
            guard (try? EngineCookie(cookie).validate(for: url)) != nil else {
                throw EngineError.notReady(String(localized: "WebKit has a cookie that cannot be safely shared. Sign in again in this engine."))
            }
            if !identitySet.contains(.init(cookie)) { deletions.append(cookie) }
        }
        for cookie in replacements {
            try checkActive()
            await set(cookie)
        }
        try checkActive()

        let expected = Dictionary(uniqueKeysWithValues: normalized.map { (EngineCookie.Identity($0), $0) })
        let afterWrites = try await transferableCookies(host: host, url: url)
        let rejected = expected.values.filter { afterWrites[$0.identity] != $0 }.count
        guard rejected == 0 else { return rejected }

        for cookie in deletions {
            try checkActive()
            await delete(cookie)
        }
        try checkActive()
        let final = try await transferableCookies(host: host, url: url)
        guard final == expected else {
            throw EngineError.notReady(String(localized: "WebKit did not remove the previous cookies. Sign out again in this engine."))
        }
        return 0
    }

    private func transferableCookies(host: String, url: URL) async throws -> [EngineCookie.Identity: EngineCookie] {
        var actual: [EngineCookie.Identity: EngineCookie] = [:]
        let storedAfterWrite = await allCookies()
        try checkActive()
        for cookie in storedAfterWrite where EngineCookie.matches(domain: cookie.domain, host: host) {
            guard try !WebKitCookiePartition.isPartitioned(cookie) else { continue }
            let converted = try EngineCookie(cookie)
            try converted.validate(for: url)
            guard actual.updateValue(converted, forKey: .init(converted)) == nil else {
                throw EngineError.notReady(String(localized: "WebKit could not verify the shared cookies. Sign in again in this engine."))
            }
        }
        return actual
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func set(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
        }
    }

    private func checkActive() throws {
        if Task.isCancelled { throw CancellationError() }
        if closed { throw EngineError.closed }
    }
}

private extension EngineCookie {
    struct Identity: Hashable {
        let name: String
        let domain: String
        let path: String
        init(_ cookie: EngineCookie) {
            name = cookie.name; domain = cookie.domain; path = cookie.path
        }
        init(_ cookie: HTTPCookie) {
            name = cookie.name; domain = cookie.domain.lowercased(); path = cookie.path
        }
    }

    init(_ cookie: HTTPCookie) throws {
        let sameSite: SameSite
        switch cookie.sameSitePolicy?.rawValue.lowercased() {
        case nil, "none": sameSite = .lax
        case "lax": sameSite = .lax
        case "strict": sameSite = .strict
        default: throw EngineError.notReady(String(localized: "WebKit has an unsupported SameSite cookie."))
        }
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain.lowercased(), path: cookie.path,
                  expires: cookie.isSessionOnly ? nil : cookie.expiresDate?.timeIntervalSince1970, secure: cookie.isSecure,
                  httpOnly: cookie.isHTTPOnly, sameSite: sameSite)
    }

    /// WKHTTPCookieStore exposes persisted Unspecified and None as the same
    /// `none` value. Normalize both to Lax, which only narrows cross-site use.
    var normalizedForWebKit: EngineCookie {
        var result = self
        // WebKit stores cookie expiry at whole-second precision. Never extend it.
        if let expires { result.expires = floor(expires) }
        if sameSite == .none || sameSite == .unspecified { result.sameSite = .lax }
        return result
    }

    var identity: Identity { Identity(self) }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if sameSite != .unspecified { properties[.sameSitePolicy] = sameSite.rawValue }
        return HTTPCookie(properties: properties)
    }
}

/// Foundation has no public partition-key API. The deployed NSHTTPCookie getter
/// is checked completely before use; absence or a changed ABI aborts transfer.
enum WebKitCookiePartition {
    private static let selector = NSSelectorFromString("_storagePartition")

    static func isPartitioned(_ cookie: HTTPCookie) throws -> Bool {
        guard cookie.responds(to: selector),
              let method = class_getInstanceMethod(type(of: cookie), selector),
              method_getNumberOfArguments(method) == 2,
              encoding(method_copyReturnType(method)) == "@",
              encoding(method_copyArgumentType(method, 0)) == "@",
              encoding(method_copyArgumentType(method, 1)) == ":" else {
            throw CookieTransferError.partitionMetadataUnavailable
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(cookie, selector) != nil
    }

    private static func encoding(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
