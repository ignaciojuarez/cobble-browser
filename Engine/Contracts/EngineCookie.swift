import Foundation

/// Only unpartitioned cookies whose scope both adapters can preserve.
/// Secrets are transient: never include this record in persistence or diagnostics.
struct EngineCookie: Codable, Equatable, Sendable {
    enum SameSite: String, Codable, Sendable { case unspecified, none, lax, strict }
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Double?
    var secure: Bool
    var httpOnly: Bool
    var sameSite: SameSite

    static func host(for url: URL) throws -> String {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              !host.hasSuffix(".") else {
            throw EngineError.unsupported(String(localized: "login sharing for this address"))
        }
        return host
    }

    func matches(host: String) -> Bool {
        Self.matches(domain: domain, host: host)
    }

    static func matches(domain: String, host: String) -> Bool {
        let domain = domain.lowercased()
        if domain.hasPrefix(".") {
            return host == String(domain.dropFirst()) || host.hasSuffix(domain)
        }
        return host == domain
    }

    func validate(for url: URL) throws {
        let host = try Self.host(for: url)
        let separators = "()<>@,;:\\\"/[]?={} \t"
        guard !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !name.contains(where: { separators.contains($0) }),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              name.utf8.count + value.utf8.count <= 4096,
              !domain.isEmpty, domain == domain.lowercased(), matches(host: host),
              !domain.contains(where: { "/:;\r\n\t ".contains($0) }),
              path.hasPrefix("/"), !path.contains(where: { ";\r\n".contains($0) }),
              expires.map({ $0.isFinite && $0 >= 0 }) ?? true,
              sameSite != .none || secure,
              !name.hasPrefix("__Secure-") || secure,
              !name.hasPrefix("__Host-") || (secure && !domain.hasPrefix(".") && path == "/") else {
            throw EngineError.notReady(String(localized: "A cookie could not be safely shared. Sign in again in this engine."))
        }
    }
}

struct CookieTransferSnapshot: Sendable {
    var cookies: [EngineCookie]
    var skipped: Int = 0
    /// Subset of skipped cookies positively identified as partitioned.
    var partitioned: Int = 0
}

enum CookieTransferError: Error {
    case partitionMetadataUnavailable
}
