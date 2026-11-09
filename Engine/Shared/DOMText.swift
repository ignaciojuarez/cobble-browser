import Foundation

/// Readable text from serialized HTML, for engines without an isolated-world `innerText`. It cannot see CSS,
/// so text hidden only by stylesheets is included. Form values, scripts and frames are not.
enum DOMText {
    private static let skipped: Set<String> = ["head", "script", "style", "noscript", "template", "svg", "iframe", "frame",
                                               "object", "embed", "canvas", "textarea", "select", "input", "datalist"]
    private static let blocks: Set<String> = ["address", "article", "aside", "blockquote", "br", "dd", "details", "div", "dl",
                                              "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
                                              "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
                                              "summary", "table", "tr", "ul"]

    static func text(fromHTML html: String, limit: Int) -> (text: String, truncated: Bool) {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]),
              let root = document.rootElement() else { return ("", false) }
        let body = root.elements(forName: "body").first ?? root
        var lines: [String] = []
        var line = ""
        func flush() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
            line = ""
        }
        func walk(_ node: XMLNode) {
            for child in node.children ?? [] {
                if child.kind == .text {
                    let words = (child.stringValue ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    guard !words.isEmpty else {
                        if !line.isEmpty, !line.hasSuffix(" "), !line.hasSuffix("\t") { line += " " }
                        continue
                    }
                    if let first = child.stringValue?.first, first.isWhitespace, !line.isEmpty,
                       !line.hasSuffix(" "), !line.hasSuffix("\t") { line += " " }
                    line += words
                    if let last = child.stringValue?.last, last.isWhitespace { line += " " }
                    continue
                }
                guard child.kind == .element, let element = child as? XMLElement else { continue }
                let tag = element.name?.lowercased() ?? ""
                if skipped.contains(tag) || element.attribute(forName: "hidden") != nil
                    || element.attribute(forName: "aria-hidden")?.stringValue == "true" { continue }
                let style = (element.attribute(forName: "style")?.stringValue ?? "").lowercased().replacingOccurrences(of: " ", with: "")
                if style.contains("display:none") || style.contains("visibility:hidden") { continue }
                let block = blocks.contains(tag)
                if block { flush() }
                walk(element)
                if tag == "td" || tag == "th" {
                    while line.hasSuffix(" ") { line.removeLast() }
                    line += "\t"
                } else if block { flush() }
            }
        }
        walk(body)
        flush()
        let text = lines.joined(separator: "\n")
        let units = text.utf16
        guard units.count > limit else { return (text, false) }
        return (String(decoding: Array(units.prefix(max(0, limit))), as: UTF16.self), true)
    }
}
