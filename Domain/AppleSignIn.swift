import Foundation

enum AppleSignIn {
    struct Request: Equatable, Sendable {
        let url: URL
        let clientID: String
        let redirectURI: URL
        let state: String?
    }

    static func request(from url: URL) -> Request? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "appleid.apple.com",
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil,
              url.path.lowercased() == "/auth/authorize",
              url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let clientID = singleValue("client_id", in: items), !clientID.isEmpty,
              let redirect = singleValue("redirect_uri", in: items),
              let redirectURI = URL(string: redirect),
              redirectURI.scheme?.lowercased() == "https",
              let host = redirectURI.host, !host.isEmpty,
              redirectURI.user == nil, redirectURI.password == nil, redirectURI.fragment == nil,
              AddressResolver.canonicalOrigin(redirectURI) != nil
        else { return nil }
        let states = items.filter { $0.name == "state" }
        guard states.count <= 1, states.isEmpty || states[0].value?.isEmpty == false else { return nil }
        // The WebKit handoff can return only a URL. Keep POST bodies and
        // opener-based web_message responses in their original Chromium context.
        // An omitted mode is not a promise of a URL callback.
        guard let mode = singleValue("response_mode", in: items),
              ["query", "fragment"].contains(mode) else { return nil }
        return Request(url: url, clientID: clientID, redirectURI: redirectURI, state: states.first?.value)
    }

    static func callback(from url: URL, for request: Request) -> URL? {
        guard url.scheme?.lowercased() == request.redirectURI.scheme?.lowercased(),
              url.host?.lowercased() == request.redirectURI.host?.lowercased(),
              url.port == request.redirectURI.port,
              url.user == nil, url.password == nil,
              url.path == request.redirectURI.path,
              containsRedirectQuery(url, from: request.redirectURI) else { return nil }
        let items = responseItems(url, excluding: request.redirectURI)
        guard request.state == nil || singleValue("state", in: items) == request.state,
              items.contains(where: { ["code", "id_token", "error"].contains($0.name) && $0.value?.isEmpty == false })
        else { return nil }
        return url
    }

    static func allowsNavigation(_ url: URL, for request: Request) -> Bool {
        if callback(from: url, for: request) != nil { return true }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        switch url.host?.lowercased() {
        case "appleid.apple.com", "idmsa.apple.com", "gsa.apple.com": return true
        default: return false
        }
    }

    private static func singleValue(_ name: String, in items: [URLQueryItem]) -> String? {
        let matches = items.filter { $0.name == name }
        return matches.count == 1 ? matches[0].value : nil
    }

    private static func containsRedirectQuery(_ callback: URL, from redirect: URL) -> Bool {
        let expected = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard actual.starts(with: expected) else { return false }
        return !actual.dropFirst(expected.count).contains { appended in
            expected.contains { $0.name == appended.name }
        }
    }

    private static func responseItems(_ url: URL, excluding redirect: URL) -> [URLQueryItem] {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirectCount = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems?.count ?? 0
        let fragment = URLComponents(string: "https://cobble.invalid?\(url.fragment ?? "")")?.queryItems ?? []
        return Array(query.dropFirst(redirectCount)) + fragment
    }
}
