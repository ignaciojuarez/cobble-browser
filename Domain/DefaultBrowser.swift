import AppKit
import UniformTypeIdentifiers

enum DefaultBrowser {
    static let urlSchemes = ["http", "https"]

    enum Incoming: Equatable, Sendable {
        case web(URL)
        case localHTML(URL)
    }

    /// Launch Services treats http and https as the default-browser pair.
    /// https can fail after a successful http claim on some macOS versions; that
    /// is not a failed default-browser registration.
    static func setDefault(
        applicationURL: URL,
        using setter: @escaping (URL, String, @escaping (Error?) -> Void) -> Void = { url, scheme, done in
            NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: scheme) { error in
                done(error)
            }
        },
        completion: @escaping (Error?) -> Void
    ) {
        setter(applicationURL, "http") { error in
            if let error {
                completion(error)
                return
            }
            setter(applicationURL, "https") { _ in completion(nil) }
        }
    }

    static func incoming(_ url: URL) -> Incoming? {
        switch url.scheme?.lowercased() {
        case "http", "https": return .web(url)
        case "file": return isHTMLDocument(url) ? .localHTML(url) : nil
        default: return nil
        }
    }

    static func isHTMLDocument(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["html", "htm", "shtml", "xhtml"].contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .html) { return true }
        if let xhtml = UTType("public.xhtml"), type.conforms(to: xhtml) { return true }
        return false
    }
}
