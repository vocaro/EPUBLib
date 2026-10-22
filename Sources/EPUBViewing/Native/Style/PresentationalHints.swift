import Foundation

/// HTML's presentational attributes (HTML §15.3–15.5: `align`, `width`, `bgcolor`, `<font>`…)
/// as author-level declarations of zero specificity that precede every author rule. Each
/// attribute value is parsed as the value of one property only, so it can never inject other
/// declarations.
enum PresentationalHints {
    static func declarations(for element: ContentNode, facts: ElementFacts, document: ContentDocument) -> [CSSDeclaration] {
        guard !element.attributes.isEmpty else { return [] }
        if element.namespace == ContentNamespace.svg, element.name == "svg" {
            var result: [CSSDeclaration] = []
            for name in ["width", "height"] {
                if let value = element.attribute(name) {
                    // SVG dimensions are CSS lengths, not HTML dimension attributes. A bare
                    // SVG number is in user units (px here); keep a unit for the CSS parser.
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    let number = Double(trimmed)
                    if let number, number.isFinite, number >= 0 { add(&result, name, "\(number)px") }
                    else { add(&result, name, trimmed, substitutes: true) }
                }
            }
            return result
        }
        guard element.isHTML else { return [] }
        var result: [CSSDeclaration] = []
        let name = element.name
        let attribute = { (local: String) in element.attribute(local)?.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let align = attribute("align")?.lowercased() {
            switch name {
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "caption", "legend", "thead", "tbody", "tfoot", "tr", "td", "th":
                let value = align == "middle" ? "center" : align
                if ["left", "right", "center", "justify"].contains(value) { add(&result, "text-align", value) }
            case "table":
                if align == "left" || align == "right" { add(&result, "float", align) }
                if align == "center" { add(&result, "margin-left", "auto"); add(&result, "margin-right", "auto") }
            case "img", "object", "embed", "iframe", "input", "video", "canvas":
                switch align {
                case "left", "right": add(&result, "float", align)
                case "top": add(&result, "vertical-align", "top")
                case "middle", "absmiddle", "center": add(&result, "vertical-align", "middle")
                case "bottom", "baseline", "absbottom": add(&result, "vertical-align", "baseline")
                case "texttop": add(&result, "vertical-align", "text-top")
                default: break
                }
            case "hr":
                if align == "left" { add(&result, "margin-right", "auto"); add(&result, "margin-left", "0") }
                if align == "right" { add(&result, "margin-left", "auto"); add(&result, "margin-right", "0") }
                if align == "center" { add(&result, "margin-left", "auto"); add(&result, "margin-right", "auto") }
            default: break
            }
        }
        if let valign = attribute("valign")?.lowercased(), ["td", "th", "tr", "thead", "tbody", "tfoot", "col", "colgroup"].contains(name),
           ["top", "middle", "bottom", "baseline"].contains(valign) {
            add(&result, "vertical-align", valign)
        }
        // The elements whose `width` and `height` map to the dimension properties (HTML §15.3.8,
        // §15.4.3, §15.5.13). A table's width and a cell's width and height ignore zero, so
        // `<td width="0">` is `auto`; `pre` has none, as its width was a count of characters.
        if ["img", "table", "td", "th", "col", "colgroup", "hr", "iframe", "embed", "object", "video", "canvas", "marquee"].contains(name),
           let width = element.attribute("width").flatMap({ dimension($0, ignoringZero: ["table", "td", "th"].contains(name)) }) {
            add(&result, "width", width)
        }
        if ["img", "table", "td", "th", "tr", "thead", "tbody", "tfoot", "iframe", "embed", "object", "video", "canvas", "marquee"].contains(name),
           let height = element.attribute("height").flatMap({ dimension($0, ignoringZero: name == "td" || name == "th") }) {
            add(&result, "height", height)
        }
        if ["embed", "img", "object", "marquee"].contains(name) {
            if let space = element.attribute("hspace").flatMap({ dimension($0) }) { add(&result, "margin-left", space); add(&result, "margin-right", space) }
            if let space = element.attribute("vspace").flatMap({ dimension($0) }) { add(&result, "margin-top", space); add(&result, "margin-bottom", space) }
        }
        if ["body", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "marquee"].contains(name), let color = attribute("bgcolor").flatMap(legacyColor) {
            add(&result, "background-color", color)
        }
        if name == "body", let color = attribute("text").flatMap(legacyColor) { add(&result, "color", color) }
        if (name == "td" || name == "th"), element.attribute("nowrap") != nil { add(&result, "white-space", "nowrap") }

        switch name {
        case "font":
            if let color = attribute("color").flatMap(legacyColor) { add(&result, "color", color) }
            if let face = attribute("face") {
                // By scalar: as a `Character`, a comma, quote or backslash with a combining mark
                // after it is another character, and the quote would stay in the name it is put in.
                let families = face.unicodeScalars.split(separator: ",")
                    .map { String(String.UnicodeScalarView($0.filter { $0 != "\"" && $0 != "\\" && $0 != "'" })) }
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(CSSPropertyParser.maximumFamilies)
                if !families.isEmpty { add(&result, "font-family", families.map { "\"\($0)\"" }.joined(separator: ", ")) }
            }
            if let size = attribute("size").flatMap(fontSizeKeyword) { add(&result, "font-size", size) }
        case "table":
            if let border = attribute("border") {
                let width = Int(border.prefix { $0.isNumber }) ?? 1
                if width > 0 { add(&result, "border", "\(min(width, 64))px outset") }
            }
            if let spacing = attribute("cellspacing").flatMap({ dimension($0) }), !spacing.hasSuffix("%") { add(&result, "border-spacing", spacing) }
        case "td", "th":
            if let table = enclosingTable(element, facts: facts, document: document) {
                if let border = table.attribute("border"), (Int(border.prefix { $0.isNumber }) ?? 1) > 0 {
                    add(&result, "border", "1px inset")
                }
                if let padding = table.attribute("cellpadding").flatMap({ dimension($0) }), !padding.hasSuffix("%") {
                    add(&result, "padding", padding)
                }
            }
        case "img":
            if let border = attribute("border").flatMap({ Int($0.prefix { $0.isNumber }) }), border > 0 {
                add(&result, "border", "\(min(border, 64))px solid")
            }
        case "br":
            // HTML §15.3.4: `br[clear=left i]`, `[clear=right i]`, `[clear=all i]` and
            // `[clear=both i]`. A selector matches the whole value, so nothing is trimmed.
            switch element.attribute("clear")?.lowercased() {
            case "left"?: add(&result, "clear", "left")
            case "right"?: add(&result, "clear", "right")
            case "all"?, "both"?: add(&result, "clear", "both")
            default: break
            }
        default:
            break
        }
        return result
    }

    /// An SVG presentation attribute is a CSS value and `substitutes` its `var()`s, as the
    /// properties it maps to do (WPT css/css-variables/variable-presentation-attribute.html); an
    /// HTML attribute is read by HTML's own rules, which have none.
    private static func add(_ result: inout [CSSDeclaration], _ name: String, _ value: String, substitutes: Bool = false) {
        guard let declarations = CSSPropertyParser.parse(name: name, text: value, isRuleValue: false) else { return }
        if !substitutes, declarations.contains(where: { if case .pending = $0.value { true } else { false } }) { return }
        result += declarations
    }

    /// HTML's rules for parsing dimension values: after ASCII white space, at least one digit,
    /// then a `.` and any digits after it, then `%` for a percentage. What follows is ignored,
    /// and a value that does not start with a digit is none. `ignoringZero` is HTML's rules for
    /// parsing nonzero dimension values, which take `0`, `0.0` and `0%` for none too.
    static func dimension(_ value: String, ignoringZero: Bool = false) -> String? {
        let isDigit = { (byte: UInt8) in (0x30...0x39).contains(byte) }
        let start = value.utf8.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0C || $0 == 0x0D }
        var rest = start.drop(while: isDigit)
        guard rest.startIndex > start.startIndex else { return nil }
        if rest.first == UInt8(ascii: ".") { rest = rest.dropFirst().drop(while: isDigit) }
        // The digits read as one decimal number, so that it is the nearest `Double` to them.
        let number = String(Substring(start[..<rest.startIndex]))
        guard let amount = Double(number.hasSuffix(".") ? String(number.dropLast()) : number), amount.isFinite,
              !(ignoringZero && amount == 0) else { return nil }
        return rest.first == UInt8(ascii: "%") ? "\(amount)%" : "\(amount)px"
    }

    /// A legacy color attribute: a CSS color, or bare hex digits as old HTML wrote them.
    static func legacyColor(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        if [3, 6].contains(trimmed.count), trimmed.unicodeScalars.allSatisfy({ CSSTokenizer.hexValue($0) != nil }) {
            return "#" + trimmed
        }
        return trimmed
    }

    private static func fontSizeKeyword(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let relative = trimmed.first == "+" || trimmed.first == "-"
        guard let parsed = Int(trimmed.drop { $0 == "+" }) else { return nil }
        let number = min(max(parsed, -7), 7)
        let size = min(max(relative ? 3 + number : number, 1), 7)
        return ["x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large"][size - 1]
    }

    private static func enclosingTable(_ element: ContentNode, facts: ElementFacts, document: ContentDocument) -> ContentNode? {
        var current = Int(facts.parents[element.order])
        var steps = 0
        while current >= 0, steps < 4 {
            let node = document.nodes[current]
            if node.isHTML("table") { return node }
            current = Int(facts.parents[current]); steps += 1
        }
        return nil
    }
}
