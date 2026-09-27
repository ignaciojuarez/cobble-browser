import Foundation
import Darwin

enum AddressResolution: Equatable, Sendable {
    case navigate(URL), external(URL), blank, invalid(String)
}

enum AddressResolver {
    static func canonicalOrigin(_ url: URL) -> String? {
        guard let input = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = input.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = input.host?.lowercased(), !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              input.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        guard !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        if let port = input.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) {
            origin.port = port
        }
        return origin.url?.absoluteString
    }

    static func resolve(_ input: String, engines: [SearchEngine] = SearchEngine.builtIns,
                        defaultEngine: SearchEngine = .duckDuckGo) -> AddressResolution {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.lowercased() == "about:blank" { return .blank }
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .invalid(String(localized: "The address contains control characters."))
        }
        let local = raw.range(of: #"^(?:localhost|\d+\.\d+\.\d+\.\d+)(?=[:/?#]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil || raw.hasPrefix("[")
        let hostPort = raw.range(of: #"^(?:localhost|[^\s/:?#]+|\[[^\]]+\]):\d+(?:[/?#].*)?$"#, options: .regularExpression) != nil
        let explicitScheme = raw.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil && !hostPort
        if explicitScheme {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return .invalid(String(localized: "Invalid address.")) }
            if ["mailto", "tel"].contains(scheme) {
                return raw.count > scheme.count + 1 ? .external(url) : .invalid(String(localized: "The external address is empty."))
            }
            guard ["http", "https"].contains(scheme) else { return .invalid(String(localized: "This address scheme is not supported.")) }
            return webAddress(raw)
        }
        if !raw.contains(where: \.isWhitespace), local || raw.contains(".") || hostPort {
            return webAddress((local || (hostPort && !raw.contains(".")) ? "http://" : "https://") + raw)
        }
        guard let url = SearchEngine.searchURL(for: raw, engines: engines, defaultEngine: defaultEngine) else {
            return .invalid(String(localized: "Enter search terms after the bang."))
        }
        return .navigate(url)
    }

    private static func webAddress(_ raw: String) -> AddressResolution {
        guard let parts = URLComponents(string: raw), let host = parts.host, !host.isEmpty,
              !host.contains(where: \.isWhitespace), parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true, let url = parts.url else {
            return .invalid(String(localized: "Enter a valid web address without embedded credentials."))
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 && octets.allSatisfy({ $0.allSatisfy(\.isNumber) }),
           !octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return .invalid(String(localized: "Invalid IP address.")) }
        if host.hasPrefix("[") {
            var address = in6_addr()
            guard host.hasSuffix("]"), inet_pton(AF_INET6, String(host.dropFirst().dropLast()), &address) == 1 else {
                return .invalid(String(localized: "Invalid IPv6 address."))
            }
        }
        return .navigate(url)
    }
}
