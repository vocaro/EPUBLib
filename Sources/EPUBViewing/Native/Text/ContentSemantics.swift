import Foundation

/// What the builder reads from markup beyond computed style: notes, list markers, quotation
/// marks and element categories.
enum ContentSemantics {
    // MARK: Notes

    enum NoteKind: Equatable {
        /// Hidden from the flow, shown only in place of its noteref.
        case footnote
        /// Stays in the flow and is also shown in place.
        case endnote
        /// A note element that is neither: rendered in place and captured.
        case other
    }

    private static let noteTypes: Set<String> = ["footnote", "endnote", "rearnote", "note"]

    static func roles(_ element: ContentNode) -> [Substring] {
        (element.attribute("role") ?? "").split(whereSeparator: \.isWhitespace)
    }

    /// `epub:type` tokens, also from markup read by the HTML parser, which keeps the prefixed
    /// name as a plain attribute.
    static func types(_ element: ContentNode) -> [Substring] {
        (element.attribute("type", namespace: ContentNamespace.ops) ?? element.attribute("epub:type") ?? "")
            .split(whereSeparator: \.isWhitespace)
    }

    /// The note an element is (EPUB 3 `epub:type` or DPUB-ARIA `role`), or nil.
    static func noteKind(_ element: ContentNode) -> NoteKind? {
        guard element.isElement, element.attribute("role") != nil
            || element.attribute("type", namespace: ContentNamespace.ops) != nil
            || element.attribute("epub:type") != nil else { return nil }
        let types = types(element), roles = roles(element)
        let typed = types.contains { noteTypes.contains(String($0)) }
        let footnoteRole = roles.contains("doc-footnote"), endnoteRole = roles.contains("doc-endnote")
        guard typed || footnoteRole || endnoteRole else { return nil }
        if types.contains("endnote") || endnoteRole || isInsideEndnotes(element) { return .endnote }
        if footnoteRole || (element.isHTML("aside") && types.contains { $0 == "footnote" || $0 == "note" || $0 == "rearnote" }) {
            return .footnote
        }
        return .other
    }

    private static func isInsideEndnotes(_ element: ContentNode) -> Bool {
        var ancestor = element.parent
        while let node = ancestor {
            if types(node).contains(where: { $0 == "endnotes" || $0 == "rearnotes" })
                || roles(node).contains("doc-endnotes") { return true }
            ancestor = node.parent
        }
        return false
    }

    static func isNoteReference(_ element: ContentNode) -> Bool {
        types(element).contains("noteref") || roles(element).contains("doc-noteref")
    }

    static func isBacklink(_ element: ContentNode) -> Bool {
        types(element).contains("backlink") || roles(element).contains("doc-backlink")
    }

    // MARK: Elements

    /// HTML elements whose content is never text: skipped whatever their computed style says.
    static let neverRendered: Set<String> = [
        "head", "script", "style", "template", "title", "meta", "link", "base", "param", "source", "track",
        "datalist", "area", "noembed", "noframes",
    ]

    /// Elements shown only through their fallback content, counted for disclosure.
    static let fallbackOnly: Set<String> = ["video", "audio", "iframe", "canvas", "frame", "frameset", "applet"]

    /// Form controls: nothing to read but a button's label.
    static let formControls: Set<String> = ["input", "select", "textarea", "button", "form", "keygen"]

    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    static func isHeading(_ element: ContentNode) -> Bool { element.isHTML && headings.contains(element.name) }

    static let rowGroups: Set<String> = ["thead", "tbody", "tfoot"]

    /// List containers, which reset the list-item counter.
    static let lists: Set<String> = ["ol", "ul", "menu", "dir"]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "avif"]

    // MARK: Quotation marks

    /// `<q>` marks by language, outer then inner, as the CSS `quotes: auto` tables give them.
    static func quotes(language: String?, depth: Int) -> (open: String, close: String) {
        let tag = language?.lowercased() ?? "en"
        let primary = tag.split(separator: "-").first.map(String.init) ?? tag
        let pairs: [(String, String)]
        switch primary {
        case "fr": pairs = [("«\u{202F}", "\u{202F}»"), ("“", "”")]
        case "de", "cs", "sk", "sl", "lt", "et", "is", "bg": pairs = [("„", "“"), ("‚", "‘")]
        case "pl", "hu", "ro", "hr": pairs = [("„", "”"), ("«", "»")]
        case "ru", "uk", "be", "es", "it", "pt", "ca", "el", "tr", "ar", "fa", "hy", "ka", "nb", "nn", "no":
            pairs = [("«", "»"), ("“", "”")]
        case "sv", "fi": pairs = [("”", "”"), ("’", "’")]
        case "da": pairs = [("»", "«"), ("›", "‹")]
        case "ja": pairs = [("「", "」"), ("『", "』")]
        case "zh" where tag.contains("tw") || tag.contains("hk") || tag.contains("hant"): pairs = [("「", "」"), ("『", "』")]
        default: pairs = [("“", "”"), ("‘", "’")]
        }
        return pairs[depth % 2]
    }
}

/// CSS list markers (`list-style-type`) for a counter value.
enum ListMarker {
    /// The marker text, without the separating space; nil for `none`.
    static func text(_ type: ComputedStyle.ListStyleType, value: Int) -> String? {
        switch type {
        case .none: nil
        case .disc: "•"
        case .circle: "◦"
        case .square: "▪"
        case .decimal: "\(value)."
        case .decimalLeadingZero: (value < 0 ? "-" : "") + (abs(value) < 10 ? "0" : "") + "\(abs(value))."
        case .lowerAlpha: (alphabetic(value, letters: latin) ?? "\(value)") + "."
        case .upperAlpha: (alphabetic(value, letters: latin)?.uppercased() ?? "\(value)") + "."
        case .lowerRoman: (roman(value) ?? "\(value)") + "."
        case .upperRoman: (roman(value)?.uppercased() ?? "\(value)") + "."
        case .lowerGreek: (alphabetic(value, letters: greek) ?? "\(value)") + "."
        case .string(let string): string
        }
    }

    /// Whether the marker is followed by a space (CSS's counter and bullet suffixes); a string
    /// marker carries its own spacing.
    static func hasSuffix(_ type: ComputedStyle.ListStyleType) -> Bool {
        if case .string = type { return false }
        return true
    }

    private static let latin = Array("abcdefghijklmnopqrstuvwxyz")
    private static let greek = Array("αβγδεζηθικλμνξοπρστυφχψω")

    /// CSS's alphabetic system: a, b, … z, aa, ab, … Values below 1 fall back to decimal.
    private static func alphabetic(_ value: Int, letters: [Character]) -> String? {
        guard value >= 1 else { return nil }
        var value = value, result: [Character] = []
        while value > 0 {
            value -= 1
            result.append(letters[value % letters.count])
            value /= letters.count
        }
        return String(result.reversed())
    }

    /// Lowercase roman numerals for 1–3999; nil (decimal) outside that range.
    private static func roman(_ value: Int) -> String? {
        guard (1...3999).contains(value) else { return nil }
        let numerals: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                         (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var value = value, result = ""
        for (amount, numeral) in numerals {
            while value >= amount { result += numeral; value -= amount }
        }
        return result
    }
}
