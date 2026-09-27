import Foundation

struct SearchEngine: Codable, Equatable, Identifiable, Sendable {
    static let placeholder = "{searchTerms}"

    var id: String
    var name: String
    var template: String
    /// Stored without the leading exclamation point.
    var bang: String

    static let duckDuckGo = SearchEngine(id: "duckduckgo", name: "DuckDuckGo",
                                         template: "https://duckduckgo.com/?q={searchTerms}", bang: "d")!
    static let google = SearchEngine(id: "google", name: "Google",
                                     template: "https://www.google.com/search?q={searchTerms}", bang: "g")!
    static let brave = SearchEngine(id: "brave", name: "Brave Search",
                                    template: "https://search.brave.com/search?q={searchTerms}", bang: "brave")!
    static let bing = SearchEngine(id: "bing", name: "Bing",
                                   template: "https://www.bing.com/search?q={searchTerms}", bang: "b")!
    static let kagi = SearchEngine(id: "kagi", name: "Kagi",
                                   template: "https://kagi.com/search?q={searchTerms}", bang: "k")!
    static let builtIns = [duckDuckGo, google, brave, bing, kagi]

    init?(id: String, name: String, template: String, bang: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bang = Self.normalizedBang(bang)
        guard Self.validID(id), Self.validName(name), Self.validTemplate(template), let bang else { return nil }
        self.id = id
        self.name = name
        self.template = template
        self.bang = bang
    }

    var isValid: Bool {
        Self.validID(id) && Self.validName(name) && Self.validTemplate(template) && Self.normalizedBang(bang) == bang
    }

    func searchURL(for query: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: Self.placeholder, with: escaped))
    }

    static func normalizedBang(_ value: String) -> String? {
        let bang = value.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "!" }).lowercased()
        guard (1...32).contains(bang.count), bang.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return bang
    }

    static func bangSuggestions(for input: String, engines: [SearchEngine]) -> [SearchEngine] {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix("!"), !input.dropFirst().contains(where: \.isWhitespace) else { return [] }
        let prefix = input.dropFirst().lowercased()
        return engines.filter { $0.bang.hasPrefix(prefix) }.prefix(6).map { $0 }
    }

    static func searchURL(for input: String, engines: [SearchEngine], defaultEngine: SearchEngine) -> URL? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if let token = parts.first, token.hasPrefix("!"),
           let bang = normalizedBang(String(token)), let engine = engines.first(where: { $0.bang == bang }) {
            guard parts.count == 2, !String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return engine.searchURL(for: String(parts[1]))
        }
        return defaultEngine.searchURL(for: input)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validName(_ name: String) -> Bool {
        (1...64).contains(name.count) && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validTemplate(_ template: String) -> Bool {
        guard let scheme = template.range(of: "://") else { return false }
        let authorityStart = scheme.upperBound
        let authorityEnd = template[authorityStart...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? template.endIndex
        guard template.components(separatedBy: placeholder).count == 2,
              !template.contains(where: { $0.isWhitespace }),
              !template[..<scheme.lowerBound].contains(placeholder),
              !template[authorityStart..<authorityEnd].contains(placeholder),
              let url = URL(string: template.replacingOccurrences(of: placeholder, with: "query")),
              let urlScheme = url.scheme?.lowercased(), ["http", "https"].contains(urlScheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        return true
    }
}
