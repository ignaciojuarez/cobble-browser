import AppKit
import UniformTypeIdentifiers

enum DefaultBrowser {
    enum Incoming: Equatable, Sendable {
        case web(URL)
        case localHTML(URL)
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
