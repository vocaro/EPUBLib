import Foundation

/// Which reader appearances a rule applies in. Styles are layout-independent, so the only
/// environment a media query can observe is the appearance; everything else is evaluated once
/// against a nominal 600 × 800 px screen.
struct CSSMediaMask: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let light = CSSMediaMask(rawValue: 1)
    static let dark = CSSMediaMask(rawValue: 2)
    static let all: CSSMediaMask = [.light, .dark]

    func contains(dark: Bool) -> Bool { contains(dark ? .dark : .light) }
}

/// Media Queries Level 4/5 evaluation for a reading system that never prints.
enum CSSMedia {
    static let viewport = (width: 600.0, height: 800.0)

    /// A media query list from a `media` attribute.
    static func mask(_ text: String) -> CSSMediaMask {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .all }
        var truncated = false
        return mask(CSSParser.components(String(trimmed.prefix(4096)), truncated: &truncated))
    }

    /// A media query list; an empty list matches everything.
    static func mask(_ components: [CSSComponent]) -> CSSMediaMask {
        guard !components.significant.isEmpty else { return .all }
        var mask: CSSMediaMask = []
        if evaluateList(components, dark: false) { mask.insert(.light) }
        if evaluateList(components, dark: true) { mask.insert(.dark) }
        return mask
    }

    private static func evaluateList(_ components: [CSSComponent], dark: Bool) -> Bool {
        components.commaSeparated.contains { query($0, dark: dark) ?? false }
    }

    /// One media query; nil when malformed (which matches nothing).
    private static func query(_ components: [CSSComponent], dark: Bool) -> Bool? {
        guard !components.isEmpty else { return nil }
        var index = 0
        var negate = false
        if let first = components[0].ident {
            if first == "not" || first == "only" {
                negate = first == "not"
                index = 1
            }
            guard index < components.count, let type = components[index].ident,
                  !["and", "or", "not", "only"].contains(type) else {
                return condition(components, dark: dark)
            }
            index += 1
            var result = mediaType(type)
            if index < components.count {
                guard components[index].ident == "and", index + 1 < components.count,
                      let rest = condition(Array(components[(index + 1)...]), dark: dark, allowOr: false) else { return nil }
                result = result && rest
            }
            return negate ? !result : result
        }
        return condition(components, dark: dark)
    }

    private static func mediaType(_ type: String) -> Bool { type == "all" || type == "screen" }

    /// `not <in-parens>`, or in-parens joined by `and` (or `or`).
    private static func condition(_ components: [CSSComponent], dark: Bool, allowOr: Bool = true) -> Bool? {
        guard let first = components.first else { return nil }
        if first.ident == "not" {
            guard components.count == 2, let value = inParens(components[1], dark: dark) else { return nil }
            return !value
        }
        guard var result = inParens(first, dark: dark) else { return nil }
        var index = 1
        var joiner: String?
        while index < components.count {
            guard let word = components[index].ident, word == "and" || (word == "or" && allowOr),
                  joiner == nil || joiner == word, index + 1 < components.count,
                  let value = inParens(components[index + 1], dark: dark) else { return nil }
            joiner = word
            result = word == "and" ? result && value : result || value
            index += 2
        }
        return result
    }

    private static func inParens(_ component: CSSComponent, dark: Bool) -> Bool? {
        guard case .block(.openParen, let contents) = component else {
            if case .function = component { return false } // general-enclosed: unknown
            return nil
        }
        let inner = contents.significant
        if let first = inner.first, case .block(.openParen, _) = first { return condition(inner, dark: dark) }
        if inner.first?.ident == "not" { return condition(inner, dark: dark) }
        return feature(inner, dark: dark) ?? false
    }

    private enum Value { case number(Double), ident(String) }

    private static func value(_ components: ArraySlice<CSSComponent>) -> Value? {
        let components = Array(components)
        if components.count == 3, case .token(.number(let a, _, _)) = components[0], components[1].isDelim("/"),
           case .token(.number(let b, _, _)) = components[2], b != 0 {
            return .number(a / b)
        }
        guard components.count == 1 else { return nil }
        switch components[0] {
        case .token(.number(let value, _, _)): return .number(value)
        case .token(.ident(let value)): return .ident(value.lowercased())
        case .token(.dimension(let value, let unit, _, _)):
            switch unit.lowercased() {
            case "px": return .number(value)
            case "em", "rem": return .number(value * 16)
            case "pt": return .number(value * 4 / 3)
            case "pc": return .number(value * 16)
            case "in": return .number(value * 96)
            case "cm": return .number(value * 96 / 2.54)
            case "mm": return .number(value * 96 / 25.4)
            case "q": return .number(value * 96 / 101.6)
            case "dppx", "x": return .number(value)
            case "dpi": return .number(value / 96)
            case "dpcm": return .number(value * 2.54 / 96)
            default: return nil
            }
        default: return nil
        }
    }

    private static func environment(_ name: String, dark: Bool) -> Value? {
        #if os(iOS)
        let hover = "none", pointer = "coarse"
        #else
        let hover = "hover", pointer = "fine"
        #endif
        switch name {
        case "width", "device-width": return .number(viewport.width)
        case "height", "device-height": return .number(viewport.height)
        case "aspect-ratio", "device-aspect-ratio": return .number(viewport.width / viewport.height)
        case "orientation": return .ident("portrait")
        case "resolution", "-webkit-device-pixel-ratio", "device-pixel-ratio", "-moz-device-pixel-ratio": return .number(2)
        case "color": return .number(8)
        case "color-index", "monochrome", "grid": return .number(0)
        case "prefers-color-scheme": return .ident(dark ? "dark" : "light")
        case "prefers-reduced-motion", "prefers-contrast", "prefers-reduced-transparency", "prefers-reduced-data":
            return .ident("no-preference")
        case "forced-colors", "inverted-colors", "scripting": return .ident("none")
        case "hover", "any-hover": return .ident(hover)
        case "pointer", "any-pointer": return .ident(pointer)
        case "update": return .ident("fast")
        case "color-gamut": return .ident("p3")
        case "dynamic-range", "video-dynamic-range": return .ident("standard")
        case "display-mode": return .ident("browser")
        case "overflow-block", "overflow-inline": return .ident("scroll")
        case "scan": return .ident("progressive")
        default: return nil
        }
    }

    /// Whether an environment value counts as true in a boolean context (`(color)`).
    private static func truthy(_ value: Value) -> Bool {
        switch value {
        case .number(let number): number != 0
        case .ident(let ident): !["none", "no-preference"].contains(ident)
        }
    }

    private static func compare(_ name: String, _ given: Value, dark: Bool) -> Bool {
        guard let actual = environment(name, dark: dark) else { return false }
        switch (actual, given) {
        case (.number(let a), .number(let b)): return abs(a - b) < 0.0001
        case (.ident(let a), .ident(let b)):
            if name == "color-gamut" { return ["srgb", "p3"].contains(b) }
            return a == b
        default: return false
        }
    }

    private static func feature(_ components: [CSSComponent], dark: Bool) -> Bool? {
        guard let first = components.first else { return nil }
        if components.count == 1, let name = first.ident {
            return environment(name, dark: dark).map(truthy)
        }
        if let rawName = first.ident, components.count >= 3, components[1] == .token(.colon) {
            guard let given = value(components[2...]) else { return nil }
            for (prefix, comparison) in [("min-", ">="), ("max-", "<=")] where rawName.hasPrefix(prefix) {
                let name = String(rawName.dropFirst(prefix.count))
                guard case .number(let b) = given, let actual = environment(name, dark: dark),
                      case .number(let a) = actual else { return nil }
                return comparison == ">=" ? a >= b : a <= b
            }
            if rawName.hasPrefix("-webkit-min-") || rawName.hasPrefix("min--moz-") || rawName.hasPrefix("-webkit-max-") {
                guard case .number(let b) = given else { return nil }
                return rawName.contains("min") ? 2 >= b : 2 <= b
            }
            return compare(rawName, given, dark: dark)
        }
        return range(components, dark: dark)
    }

    /// Range syntax: `(width >= 600px)`, `(400px < width <= 700px)`.
    private static func range(_ components: [CSSComponent], dark: Bool) -> Bool? {
        var parts: [[CSSComponent]] = [[]]
        var operators: [String] = []
        var index = 0
        while index < components.count {
            let c = components[index]
            if case .token(.delim(let d)) = c, "<>=".unicodeScalars.contains(d) {
                var op = String(d)
                if index + 1 < components.count, components[index + 1].isDelim("="), d != "=" { op += "="; index += 1 }
                operators.append(op); parts.append([])
            } else { parts[parts.count - 1].append(c) }
            index += 1
        }
        guard (1...2).contains(operators.count), parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        func test(_ a: Double, _ op: String, _ b: Double) -> Bool {
            switch op {
            case "<": a < b
            case "<=": a <= b
            case ">": a > b
            case ">=": a >= b
            default: abs(a - b) < 0.0001
            }
        }
        func number(_ part: [CSSComponent]) -> Double? {
            if case .number(let n)? = value(part[...]) { return n }
            if part.count == 1, let name = part[0].ident, case .number(let n)? = environment(name, dark: dark) { return n }
            return nil
        }
        let values = parts.map(number)
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        for (i, op) in operators.enumerated() where !test(values[i]!, op, values[i + 1]!) { return false }
        return true
    }
}

/// `@supports` conditions (CSS Conditional Rules 3), evaluated once at parse time.
enum CSSSupports {
    static func evaluate(_ components: [CSSComponent], namespaces: CSSNamespaces) -> Bool {
        condition(components.significant, namespaces: namespaces) ?? false
    }

    private static func condition(_ components: [CSSComponent], namespaces: CSSNamespaces) -> Bool? {
        guard let first = components.first else { return nil }
        if first.ident == "not" {
            guard components.count == 2 else { return nil }
            return inParens(components[1], namespaces: namespaces).map(!)
        }
        guard var result = inParens(first, namespaces: namespaces) else { return nil }
        var index = 1
        var joiner: String?
        while index < components.count {
            guard let word = components[index].ident, word == "and" || word == "or", joiner == nil || joiner == word,
                  index + 1 < components.count, let value = inParens(components[index + 1], namespaces: namespaces) else { return nil }
            joiner = word
            result = word == "and" ? result && value : result || value
            index += 2
        }
        return result
    }

    private static func inParens(_ component: CSSComponent, namespaces: CSSNamespaces) -> Bool? {
        switch component {
        case .block(.openParen, let contents):
            let inner = contents.significant
            if let name = inner.first?.ident, inner.count >= 2, inner[1] == .token(.colon) {
                let value = Array(contents.drop { $0 != .token(.colon) }.dropFirst())
                return CSSPropertyParser.parse(name: name, value: value.trimmingWhitespace, important: false) != nil
            }
            return condition(inner, namespaces: namespaces) ?? false
        case .function("selector", let arguments):
            let selectors = try? CSSSelectorParser(namespaces: namespaces).parseList(arguments)
            return selectors?.allSatisfy { !$0.hasPseudoElement } ?? false
        case .function:
            return false
        default:
            return nil
        }
    }
}

extension Array where Element == CSSComponent {
    var trimmingWhitespace: [CSSComponent] {
        var slice = self[...]
        while slice.first?.isWhitespace == true { slice.removeFirst() }
        while slice.last?.isWhitespace == true { slice.removeLast() }
        return Array(slice)
    }
}
