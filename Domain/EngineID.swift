import Foundation

struct EngineID: RawRepresentable, Hashable, Codable, Sendable {
    var rawValue: String
    static let webKit = EngineID(rawValue: "webkit")
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct EngineRule: Codable, Equatable, Sendable {
    var host: String
    var engineID: EngineID

    static func host(for url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// The host a website choice is saved for; `www.` is dropped so the rule also covers the bare domain.
    static func siteHost(for url: URL) -> String? {
        guard let host = host(for: url) else { return nil }
        return host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host
    }

    /// A rule covers its host and subdomains, never a lookalike such as `notfigma.com`.
    func covers(_ host: String) -> Bool {
        host == self.host || host.hasSuffix("." + self.host)
    }
}

struct BrowsingContextID: Hashable, Sendable {
    let engineID: EngineID
    let profileID: UUID
    let privateWindowID: UUID?
    var isPrivate: Bool { privateWindowID != nil }
}
