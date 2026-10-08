import Foundation

/// HTML's presentational attributes (HTML §15.3–15.4: `align`, `width`, `bgcolor`, `<font>`…)
/// as author-level declarations of zero specificity that precede every author rule. Each
/// attribute value is parsed as the value of one property only, so it can never inject other
/// declarations.
enum PresentationalHints {
    static func declarations(for element: ContentNode, facts: ElementFacts, document: ContentDocument) -> [CSSDeclaration] {
        guard !element.attributes.isEmpty else { return [] }
        if element.namespace == ContentNamespace.svg, element.name == "svg" {
            var result: [CSSDeclaration] = []
            for name in ["width", "height"] {
                if let value = element.attribute(name).flatMap(dimension) { add(&result, name, value) }
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
        if ["img", "table", "td", "th", "col", "colgroup", "hr", "iframe", "embed", "object", "video", "canvas", "pre"].contains(name),
           let width = attribute("width").flatMap(dimension) {
            add(&result, "width", width)
        }
        if ["img", "table", "td", "th", "tr", "iframe", "embed", "object", "video", "canvas"].contains(name),
           let height = attribute("height").flatMap(dimension) {
            add(&result, "height", height)
        }
        if ["body", "table", "thead", "tbody", "tfoot", "tr", "td", "th"].contains(name), let color = attribute("bgcolor").flatMap(legacyColor) {
            add(&result, "background-color", color)
        }
        if name == "body", let color = attribute("text").flatMap(legacyColor) { add(&result, "color", color) }
        if (name == "td" || name == "th"), element.attribute("nowrap") != nil { add(&result, "white-space", "nowrap") }

        switch name {
        case "font":
            if let color = attribute("color").flatMap(legacyColor) { add(&result, "color", color) }
            if let face = attribute("face") {
                let families = face.split(separator: ",").map { $0.filter { $0 != "\"" && $0 != "\\" && $0 != "'" } }
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(CSSPropertyParser.maximumFamilies)
                if !families.isEmpty { add(&result, "font-family", families.map { "\"\($0)\"" }.joined(separator: ", ")) }
            }
            if let size = attribute("size").flatMap(fontSizeKeyword) { add(&result, "font-size", size) }
        case "table":
            if let border = attribute("border") {
                let width = Int(border.prefix { $0.isNumber }) ?? 1
                if width > 0 { add(&result, "border", "\(min(width, 64))px outset") }
            }
            if let spacing = attribute("cellspacing").flatMap(dimension), !spacing.hasSuffix("%") { add(&result, "border-spacing", spacing) }
        case "td", "th":
            if let table = enclosingTable(element, facts: facts, document: document) {
                if let border = table.attribute("border"), (Int(border.prefix { $0.isNumber }) ?? 1) > 0 {
                    add(&result, "border", "1px inset")
                }
                if let padding = table.attribute("cellpadding").flatMap(dimension), !padding.hasSuffix("%") {
                    add(&result, "padding", padding)
                }
            }
        case "img":
            if let border = attribute("border").flatMap({ Int($0.prefix { $0.isNumber }) }), border > 0 {
                add(&result, "border", "\(min(border, 64))px solid")
            }
            if let space = attribute("hspace").flatMap(dimension) { add(&result, "margin-left", space); add(&result, "margin-right", space) }
            if let space = attribute("vspace").flatMap(dimension) { add(&result, "margin-top", space); add(&result, "margin-bottom", space) }
        default:
            break
        }
        return result
    }

    private static func add(_ result: inout [CSSDeclaration], _ name: String, _ value: String) {
        result += CSSPropertyParser.parse(name: name, text: value) ?? []
    }

    /// HTML's rules for parsing dimension values: digits with an optional fraction and `%`.
    static func dimension(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard let amount = Double(number), amount.isFinite, amount >= 0 else { return nil }
        let rest = trimmed.dropFirst(number.count)
        return rest.hasPrefix("%") ? "\(amount)%" : "\(amount)px"
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
