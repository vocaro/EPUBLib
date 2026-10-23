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
    /// name as a plain attribute. An element that may not carry them has none
    /// (`allowsStructuralSemantics`).
    static func types(_ element: ContentNode) -> [Substring] {
        guard let value = element.attribute("type", namespace: ContentNamespace.ops) ?? element.attribute("epub:type"),
              allowsStructuralSemantics(element) else { return [] }
        return value.split(whereSeparator: \.isWhitespace)
    }

    /// Whether an element may carry structural semantics. EPUB 3.3 §6.1.3.1: `epub:type` "MUST
    /// NOT be used on the head element or metadata content" (`metadataContent`), and what the
    /// head holds is taken as in it, valid there or not; §6.2.3: in SVG it goes only on a
    /// renderable element (`renderableSVG`). A reading system "MUST ignore the terms" anywhere
    /// else (EPUB Reading Systems 3.3 §10). ARIA in HTML allows those HTML elements no role
    /// either, so a DPUB-ARIA role on one makes no note (`noteKind`).
    static func allowsStructuralSemantics(_ element: ContentNode) -> Bool {
        if element.isHTML, metadataContent.contains(element.name) { return false }
        if element.namespace == ContentNamespace.svg, !renderableSVG.contains(element.name) { return false }
        var node: ContentNode? = element
        while let current = node {
            if current.isHTML("head") { return false }
            node = current.parent
        }
        return true
    }

    /// HTML's metadata content (HTML 3.2.5.2.1), which may stand in the body too.
    private static let metadataContent: Set<String> = ["base", "link", "meta", "noscript", "script", "style", "template", "title"]

    /// SVG 2's renderable elements (its Rendering Model chapter defines them); `symbol` is one
    /// only as the root of a `use` element's shadow tree, which the reader does not build.
    private static let renderableSVG: Set<String> = [
        "a", "circle", "ellipse", "foreignObject", "g", "image", "line", "path", "polygon", "polyline", "rect", "svg",
        "switch", "text", "textPath", "tspan", "use",
    ]

    /// The note an element is (EPUB 3 `epub:type` or DPUB-ARIA `role`), or nil. `insideEndnotes`
    /// says whether an element has an endnotes container among its ancestors.
    static func noteKind(_ element: ContentNode,
                         insideEndnotes: (ContentNode) -> Bool = isInsideEndnotes) -> NoteKind? {
        guard element.isElement, element.attribute("role") != nil
            || element.attribute("type", namespace: ContentNamespace.ops) != nil
            || element.attribute("epub:type") != nil, allowsStructuralSemantics(element) else { return nil }
        let types = types(element), roles = roles(element)
        let typed = types.contains { noteTypes.contains(String($0)) }
        let footnoteRole = roles.contains("doc-footnote"), endnoteRole = roles.contains("doc-endnote")
        guard typed || footnoteRole || endnoteRole else { return nil }
        if types.contains("endnote") || endnoteRole || insideEndnotes(element) { return .endnote }
        if footnoteRole || (element.isHTML("aside") && types.contains { $0 == "footnote" || $0 == "note" || $0 == "rearnote" }) {
            return .footnote
        }
        return .other
    }

    static func isInsideEndnotes(_ element: ContentNode) -> Bool {
        var ancestor = element.parent
        while let node = ancestor {
            if isEndnotesContainer(node) { return true }
            ancestor = node.parent
        }
        return false
    }

    /// `epub:type` `endnotes` (or EPUB 3.0's `rearnotes`), or `role="doc-endnotes"`.
    static func isEndnotesContainer(_ element: ContentNode) -> Bool {
        guard element.attribute("role") != nil || element.attribute("type", namespace: ContentNamespace.ops) != nil
            || element.attribute("epub:type") != nil, allowsStructuralSemantics(element) else { return false }
        return types(element).contains { $0 == "endnotes" || $0 == "rearnotes" } || roles(element).contains("doc-endnotes")
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

    /// The level of the heading an element is to assistive technology, or nil: `h1` to `h6`,
    /// and any element with `role="heading"`. An `aria-level` from 1 to 6 replaces the level,
    /// and one past 6 leaves a heading with no level a platform can name (0). `role="heading"`
    /// without a level is level 2, as ARIA has it. A heading element whose role is
    /// `presentation` or `none` is laid out as a heading and is none to a listener.
    static func headingLevel(_ element: ContentNode) -> Int? {
        let native = isHeading(element) ? Int(element.name.dropFirst()) : nil
        guard element.isElement, native != nil || element.attribute("role") != nil else { return nil }
        let roles = roles(element)
        if native != nil, roles.contains(where: { $0 == "presentation" || $0 == "none" }) { return nil }
        guard native != nil || roles.contains("heading") else { return nil }
        guard let authored = element.attribute("aria-level").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              authored >= 1 else { return native ?? 2 }
        return authored <= 6 ? authored : 0
    }

    // MARK: Assistive technology

    /// Whether the book keeps `element`, an image or a rule, from assistive technology, as
    /// WAI-ARIA 1.2 and HTML-AAM map it: `aria-hidden="true"` on it or on an element round it,
    /// or a presentational role (`presentation` or `none`). It is drawn all the same, and
    /// what Copy and search take for it does not change. ARIA ignores a presentational role
    /// on an element that can take focus (`tabindex`) or that has a global ARIA attribute,
    /// such as `aria-label` or `aria-describedby`. `aria-hidden="false"` hides nothing.
    static func isHiddenFromAssistiveTechnology(_ element: ContentNode) -> Bool {
        isAriaHidden(element) || hasPresentationalRole(element)
    }

    /// Whether `aria-hidden="true"` on `element` or on an element round it keeps it, and all
    /// that is inside it, from assistive technology, and from nothing else (WAI-ARIA 1.2,
    /// HTML-AAM): its text is shown, copied and found, and VoiceOver is not given it.
    /// `aria-hidden="false"` inside such an element shows nothing to it again.
    static func isAriaHidden(_ element: ContentNode) -> Bool {
        var node: ContentNode? = element
        while let current = node {
            if hasAriaHidden(current) { return true }
            node = current.parent
        }
        return false
    }

    /// Whether `element` itself has `aria-hidden="true"`.
    static func hasAriaHidden(_ element: ContentNode) -> Bool {
        element.isElement && isTrue(element.attribute("aria-hidden"))
    }

    /// Whether `element` is presentational to assistive technology: its role is `presentation`
    /// or `none`, and it can take no focus and has no global ARIA attribute, either of which
    /// makes ARIA ignore that role. Its own semantics, an image's `alt` among them, are then
    /// not exposed.
    static func hasPresentationalRole(_ element: ContentNode) -> Bool {
        isPresentational(element) && !canTakeFocus(element) && !hasGlobalARIAAttribute(element)
    }

    /// Whether the role ARIA takes from `element`'s `role` attribute is `presentation` or
    /// `none`: the first token that names a role, a later one standing in for an earlier one
    /// that names none.
    static func isPresentational(_ element: ContentNode) -> Bool {
        for token in roles(element) {
            let role = token.lowercased()
            if role == "presentation" || role == "none" { return true }
            if ariaRoles.contains(role) || digitalPublishingRoles.contains(role) || graphicsRoles.contains(role) { return false }
        }
        return false
    }

    private static func isTrue(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    /// `tabindex` with an integer, as HTML parses one: the element can take focus.
    private static func canTakeFocus(_ element: ContentNode) -> Bool {
        guard var value = element.attribute("tabindex")?.trimmingCharacters(in: .whitespacesAndNewlines)[...] else { return false }
        if value.first == "-" || value.first == "+" { value = value.dropFirst() }
        return value.first?.isASCII == true && value.first?.isNumber == true
    }

    private static func hasGlobalARIAAttribute(_ element: ContentNode) -> Bool {
        element.attributes.contains { attribute in
            attribute.namespace.isEmpty && globalARIAAttributes.contains(attribute.name)
                && !attribute.value.allSatisfy(\.isWhitespace)
        }
    }

    /// The global states and properties of WAI-ARIA 1.2 (§6.4), those it deprecates as global
    /// among them.
    private static let globalARIAAttributes: Set<String> = [
        "aria-atomic", "aria-busy", "aria-controls", "aria-current", "aria-describedby", "aria-details", "aria-disabled",
        "aria-dropeffect", "aria-errormessage", "aria-flowto", "aria-grabbed", "aria-haspopup", "aria-hidden", "aria-invalid",
        "aria-keyshortcuts", "aria-label", "aria-labelledby", "aria-live", "aria-owns", "aria-relevant", "aria-roledescription",
    ]

    /// The roles of WAI-ARIA 1.2 that are not abstract, besides `presentation` and `none`. A
    /// `role` token that is none of these, of DPUB-ARIA (`doc-`) or of the Graphics module
    /// (`graphics-`), is passed for the next one.
    private static let ariaRoles: Set<String> = [
        "alert", "alertdialog", "application", "article", "banner", "blockquote", "button", "caption", "cell", "checkbox",
        "code", "columnheader", "combobox", "complementary", "contentinfo", "definition", "deletion", "dialog", "directory",
        "document", "emphasis", "feed", "figure", "form", "generic", "grid", "gridcell", "group", "heading", "img", "insertion",
        "link", "list", "listbox", "listitem", "log", "main", "marquee", "math", "menu", "menubar", "menuitem",
        "menuitemcheckbox", "menuitemradio", "meter", "navigation", "note", "option", "paragraph", "progressbar", "radio",
        "radiogroup", "region", "row", "rowgroup", "rowheader", "scrollbar", "search", "searchbox", "separator", "slider",
        "spinbutton", "status", "strong", "subscript", "superscript", "switch", "tab", "table", "tablist", "tabpanel", "term",
        "textbox", "time", "timer", "toolbar", "tooltip", "tree", "treegrid", "treeitem",
    ]

    /// DPUB-ARIA 1.1's roles, including deprecated ones for existing books. Unknown `doc-`
    /// tokens must not keep a later fallback role from taking effect.
    /// https://www.w3.org/TR/dpub-aria-1.1/#roles
    private static let digitalPublishingRoles: Set<String> = [
        "doc-abstract", "doc-acknowledgments", "doc-afterword", "doc-appendix", "doc-backlink", "doc-biblioentry",
        "doc-bibliography", "doc-biblioref", "doc-chapter", "doc-colophon", "doc-conclusion", "doc-cover", "doc-credit",
        "doc-credits", "doc-dedication", "doc-endnote", "doc-endnotes", "doc-epigraph", "doc-epilogue", "doc-errata",
        "doc-example", "doc-footnote", "doc-foreword", "doc-glossary", "doc-glossref", "doc-index", "doc-introduction",
        "doc-noteref", "doc-notice", "doc-pagebreak", "doc-pagefooter", "doc-pageheader", "doc-pagelist", "doc-part",
        "doc-preface", "doc-prologue", "doc-pullquote", "doc-qna", "doc-subtitle", "doc-tip", "doc-toc",
    ]

    /// The Graphics module 1.0's complete role vocabulary, rather than any `graphics-` token.
    /// https://www.w3.org/TR/graphics-aria-1.0/#roles
    private static let graphicsRoles: Set<String> = ["graphics-document", "graphics-object", "graphics-symbol"]

    static let rowGroups: Set<String> = ["thead", "tbody", "tfoot"]

    /// The elements a table is made of. `TableContent` lays a grid out from them by name.
    private static let tableParts: Set<String> = rowGroups.union(["caption", "colgroup", "col", "tr", "td", "th"])
    static func isTablePart(_ element: ContentNode) -> Bool { element.isHTML && tableParts.contains(element.name) }

    /// List containers, which reset the list-item counter.
    static let lists: Set<String> = ["ol", "ul", "menu", "dir"]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "avif"]

    // MARK: Quotation marks

    /// `<q>` marks by language, outer then inner: `quotes: auto` (CSS Generated Content 3
    /// §2.4.1), the marks typographically appropriate to the language, for which the
    /// specification points at CLDR. They are CLDR's delimiters for the language, its script and
    /// its region (`pt` and `pt-PT`, `zh-Hans` and `zh-Hant`), as the platform's locale data has
    /// them, and as Firefox's table, made from CLDR, has them too.
    /// `language` is the one the content declares; with none the marks are the English ones,
    /// whatever the package's `dc:language` (EPUB Reading Systems 3.3 §3.7).
    static func quotes(language: String?, depth: Int) -> (open: String, close: String) {
        let locale = Locale(identifier: language ?? "en")
        let marks = locale.language.languageCode.flatMap { platformDepartures[$0.identifier] }
            ?? QuotationMarks(open: locale.quotationBeginDelimiter ?? "“", close: locale.quotationEndDelimiter ?? "”",
                              innerOpen: locale.alternateQuotationBeginDelimiter ?? "‘",
                              innerClose: locale.alternateQuotationEndDelimiter ?? "’")
        return depth % 2 == 0 ? (marks.open, marks.close) : (marks.innerOpen, marks.innerClose)
    }

    private struct QuotationMarks {
        let open: String, close: String, innerOpen: String, innerClose: String
    }

    /// The languages whose marks in the platform's locale data are not CLDR's: it gives Arabic
    /// and Hebrew the typewriter marks `"` and `'`. These are CLDR's.
    private static let platformDepartures: [String: QuotationMarks] = [
        "ar": QuotationMarks(open: "”", close: "“", innerOpen: "’", innerClose: "‘"),
        "he": QuotationMarks(open: "”", close: "”", innerOpen: "’", innerClose: "’"),
    ]
}

/// CSS list markers (`list-style-type`) for a counter value.
enum ListMarker {
    /// The marker text, without the separating space; nil for `none`. A closed disclosure's
    /// triangle points towards the end of a line of `rightToLeft` text (CSS Counter Styles 3 §7.1).
    static func text(_ type: ComputedStyle.ListStyleType, value: Int, rightToLeft: Bool = false) -> String? {
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
        case .disclosureOpen: disclosureOpen
        case .disclosureClosed: rightToLeft ? disclosureClosedRightToLeft : disclosureClosed
        case .string(let string): string
        }
    }

    /// Whether the marker is followed by a space (CSS's counter and bullet suffixes); a string
    /// marker carries its own spacing.
    static func hasSuffix(_ type: ComputedStyle.ListStyleType) -> Bool {
        if case .string = type { return false }
        return true
    }

    /// The triangles of `disclosure-open` and `disclosure-closed`, one UTF-16 unit each, so that
    /// a summary's marker can show either state without its section's characters moving.
    static let disclosureOpen = "\u{25BE}"
    static let disclosureClosed = "\u{25B8}"
    static let disclosureClosedRightToLeft = "\u{25C2}"

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
