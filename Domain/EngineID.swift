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
}

struct BrowsingContextID: Hashable, Sendable {
    let engineID: EngineID
    let profileID: UUID
    let privateWindowID: UUID?
    var isPrivate: Bool { privateWindowID != nil }
}
