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

    /// Whether a declaration of `property` in a rule under this media applies in the reader's
    /// appearance. A property that only paints (`CSSProperty.followsAppearance`) follows the
    /// appearance; any other is resolved as in the light appearance, the one a reading system
    /// with no preference reports, so that a section's characters, what of them is hidden and
    /// their map to the document are the same in either appearance, as positions, search and
    /// highlights kept across a rebuild need (#130).
    func governs(_ property: CSSProperty, dark: Bool) -> Bool {
        contains(dark: dark && property.followsAppearance)
    }
}

/// Media Queries Level 4/5 evaluation for a reading system that never prints.
///
/// A query has three values (§3.1). A feature the reader does not know, a value its feature does
/// not take, a `min-` or `max-` prefix or a comparison on a feature that has no range, and
/// anything else in parentheses or a function that is neither a condition nor a feature
/// (`<general-enclosed>`) are unknown. `not` leaves unknown unknown, `and` and `or` combine it
/// as Kleene's logic does, and a query that comes to unknown matches nothing, as `not all` does
/// (§3.2). A query that does not parse is `not all` whatever surrounds it.
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

    /// True, false or unknown (§3.1).
    private enum Truth: Equatable {
        case yes, no, unknown

        init(_ value: Bool) { self = value ? .yes : .no }

        var negated: Truth {
            switch self {
            case .yes: .no
            case .no: .yes
            case .unknown: .unknown
            }
        }

        func and(_ other: Truth) -> Truth {
            self == .no || other == .no ? .no : self == .yes && other == .yes ? .yes : .unknown
        }

        func or(_ other: Truth) -> Truth {
            self == .yes || other == .yes ? .yes : self == .no && other == .no ? .no : .unknown
        }
    }

    /// A query matches only when it is true: unknown, like a query that does not parse, is
    /// `not all`.
    private static func evaluateList(_ components: [CSSComponent], dark: Bool) -> Bool {
        components.commaSeparated.contains { query($0, dark: dark) == .yes }
    }

    /// One media query; nil when malformed (which matches nothing).
    private static func query(_ components: [CSSComponent], dark: Bool) -> Truth? {
        guard !components.isEmpty else { return nil }
        var index = 0
        var negate = false
        if let first = components[0].ident {
            if first == "not" || first == "only" {
                negate = first == "not"
                index = 1
            }
            // `<media-type>` is never one of these words (§2.1).
            guard index < components.count, let type = components[index].ident,
                  !["and", "or", "not", "only", "layer"].contains(type) else {
                return condition(components, dark: dark)
            }
            index += 1
            var result = Truth(mediaType(type))
            if index < components.count {
                guard components[index].ident == "and", index + 1 < components.count,
                      let rest = condition(Array(components[(index + 1)...]), dark: dark, allowOr: false) else { return nil }
                result = result.and(rest)
            }
            return negate ? result.negated : result
        }
        return condition(components, dark: dark)
    }

    private static func mediaType(_ type: String) -> Bool { type == "all" || type == "screen" }

    /// `not <in-parens>`, or in-parens joined by `and` (or `or`).
    private static func condition(_ components: [CSSComponent], dark: Bool, allowOr: Bool = true) -> Truth? {
        guard let first = components.first else { return nil }
        if first.ident == "not" {
            guard components.count == 2, let value = inParens(components[1], dark: dark) else { return nil }
            return value.negated
        }
        guard var result = inParens(first, dark: dark) else { return nil }
        var index = 1
        var joiner: String?
        while index < components.count {
            guard let word = components[index].ident, word == "and" || (word == "or" && allowOr),
                  joiner == nil || joiner == word, index + 1 < components.count,
                  let value = inParens(components[index + 1], dark: dark) else { return nil }
            joiner = word
            result = word == "and" ? result.and(value) : result.or(value)
            index += 2
        }
        return result
    }

    /// A condition or a feature in parentheses; else `<general-enclosed>`, a function or
    /// parentheses around any value, which is unknown (§2.2, §3.1); nil for anything else.
    private static func inParens(_ component: CSSComponent, dark: Bool) -> Truth? {
        switch component {
        case .block(.openParen, let contents):
            guard isAnyValue(contents) else { return nil }
            return condition(contents.significant, dark: dark) ?? feature(contents, dark: dark)
        case .function(_, let contents):
            return isAnyValue(contents) ? .unknown : nil
        default:
            return nil
        }
    }

    /// CSS Syntax's `<any-value>`, which may be empty here: no bad string or URL, and no closing
    /// bracket but its block's own.
    private static func isAnyValue(_ components: [CSSComponent]) -> Bool {
        components.allSatisfy { component in
            switch component {
            case .token(.badString), .token(.badURL), .token(.closeParen), .token(.closeSquare), .token(.closeCurly): false
            case .token: true
            case .function(_, let contents), .block(_, let contents): isAnyValue(contents)
            }
        }
    }

    private enum Value { case number(Double), ident(String) }

    /// What a feature's value may be (§4–§12). The first five are range types, which take `min-`
    /// and `max-` and the range syntax; `boolean` (`<mq-boolean>`) and `keywords` are discrete.
    private enum Kind {
        /// In px; a number only when it is zero.
        case length
        /// CSS Values 4's `<ratio>`: one non-negative number, or two divided by `/`, compared as
        /// their quotient, so a degenerate `1/0` is infinite.
        case ratio
        /// In dppx; `infinite` is more than any.
        case resolution
        case integer
        /// `-webkit-device-pixel-ratio` and its kin, which take any number.
        case number
        /// The integer 0 or 1.
        case boolean
        case keywords(Set<String>)

        var isRange: Bool {
            switch self {
            case .length, .ratio, .resolution, .integer, .number: true
            case .boolean, .keywords: false
            }
        }
    }

    /// A feature this reader knows: what it takes, and its value here. Nil for any other name.
    private static func environment(_ name: String, dark: Bool) -> (kind: Kind, value: Value)? {
        #if os(iOS)
        let hover = "none", pointer = "coarse"
        #else
        let hover = "hover", pointer = "fine"
        #endif
        let reduce: Kind = .keywords(["no-preference", "reduce"])
        switch name {
        case "width", "device-width": return (.length, .number(viewport.width))
        case "height", "device-height": return (.length, .number(viewport.height))
        case "aspect-ratio", "device-aspect-ratio": return (.ratio, .number(viewport.width / viewport.height))
        case "resolution": return (.resolution, .number(2))
        case "-webkit-device-pixel-ratio", "device-pixel-ratio", "-moz-device-pixel-ratio": return (.number, .number(2))
        case "color": return (.integer, .number(8))
        case "color-index", "monochrome": return (.integer, .number(0))
        case "grid": return (.boolean, .number(0))
        case "orientation": return (.keywords(["portrait", "landscape"]), .ident("portrait"))
        case "prefers-color-scheme": return (.keywords(["light", "dark"]), .ident(dark ? "dark" : "light"))
        case "prefers-reduced-motion", "prefers-reduced-transparency", "prefers-reduced-data": return (reduce, .ident("no-preference"))
        case "prefers-contrast": return (.keywords(["no-preference", "less", "more", "custom"]), .ident("no-preference"))
        case "forced-colors": return (.keywords(["none", "active"]), .ident("none"))
        case "inverted-colors": return (.keywords(["none", "inverted"]), .ident("none"))
        case "scripting": return (.keywords(["none", "initial-only", "enabled"]), .ident("none"))
        case "hover", "any-hover": return (.keywords(["none", "hover"]), .ident(hover))
        case "pointer", "any-pointer": return (.keywords(["none", "coarse", "fine"]), .ident(pointer))
        case "update": return (.keywords(["none", "slow", "fast"]), .ident("fast"))
        case "color-gamut": return (.keywords(["srgb", "p3", "rec2020"]), .ident("p3"))
        case "dynamic-range", "video-dynamic-range": return (.keywords(["standard", "high"]), .ident("standard"))
        case "display-mode":
            return (.keywords(["fullscreen", "standalone", "minimal-ui", "browser", "picture-in-picture"]), .ident("browser"))
        case "overflow-block": return (.keywords(["none", "scroll", "paged"]), .ident("scroll"))
        case "overflow-inline": return (.keywords(["none", "scroll"]), .ident("scroll"))
        case "scan": return (.keywords(["interlace", "progressive"]), .ident("progressive"))
        default: return nil
        }
    }

    /// `components` as a value of `kind`; nil when the kind does not take it.
    private static func value(_ components: [CSSComponent], as kind: Kind) -> Value? {
        if case .ratio = kind {
            func part(_ component: CSSComponent) -> Double? {
                guard case .token(.number(let value, _, _)) = component, value >= 0 else { return nil }
                return value
            }
            if components.count == 1, let a = part(components[0]) { return .number(a) }
            guard components.count == 3, let a = part(components[0]), components[1].isDelim("/"),
                  let b = part(components[2]) else { return nil }
            return .number(a / b)
        }
        guard components.count == 1 else { return nil }
        let component = components[0]
        switch (kind, component) {
        case (.length, .token(.number(let value, _, _))) where value == 0:
            return .number(0)
        case (.length, .token(.dimension(let value, let unit, _, _))):
            switch unit.lowercased() {
            case "px": return .number(value)
            case "em", "rem": return .number(value * 16)
            case "pt": return .number(value * 4 / 3)
            case "pc": return .number(value * 16)
            case "in": return .number(value * 96)
            case "cm": return .number(value * 96 / 2.54)
            case "mm": return .number(value * 96 / 25.4)
            case "q": return .number(value * 96 / 101.6)
            default: return nil
            }
        case (.resolution, .token(.dimension(let value, let unit, _, _))) where value >= 0:
            switch unit.lowercased() {
            case "dppx", "x": return .number(value)
            case "dpi": return .number(value / 96)
            case "dpcm": return .number(value * 2.54 / 96)
            default: return nil
            }
        case (.resolution, _) where component.ident == "infinite":
            return .number(.infinity)
        case (.integer, .token(.number(let value, true, _))), (.number, .token(.number(let value, _, _))):
            return .number(value)
        case (.boolean, .token(.number(let value, true, _))) where value == 0 || value == 1:
            return .number(value)
        case (.keywords(let words), _):
            return component.ident.flatMap { words.contains($0) ? Value.ident($0) : nil }
        default:
            return nil
        }
    }

    /// Whether an environment value counts as true in a boolean context (`(color)`).
    private static func truthy(_ value: Value) -> Bool {
        switch value {
        case .number(let number): number != 0
        case .ident(let ident): !["none", "no-preference"].contains(ident)
        }
    }

    /// `actual` compared with a value its feature takes; `op` is `<`, `<=`, `>`, `>=` or `=`.
    private static func compare(_ name: String, _ actual: Value, _ op: String, _ given: Value) -> Bool {
        switch (actual, given) {
        case (.number(let a), .number(let b)):
            switch op {
            case "<": return a < b
            case "<=": return a <= b
            case ">": return a > b
            case ">=": return a >= b
            default: return abs(a - b) < 0.0001
            }
        case (.ident(let a), .ident(let b)):
            if name == "color-gamut" { return ["srgb", "p3"].contains(b) }
            return a == b
        default:
            return false
        }
    }

    /// A media feature (§2.4): unknown unless it names a feature this reader knows, in a form
    /// that feature's type takes, with a value it accepts.
    private static func feature(_ contents: [CSSComponent], dark: Bool) -> Truth {
        let components = contents.significant
        guard let first = components.first else { return .unknown }
        if components.count == 1, let name = first.ident {
            return environment(name, dark: dark).map { Truth(truthy($0.value)) } ?? .unknown
        }
        if let rawName = first.ident, components.count >= 3, components[1] == .token(.colon) {
            var name = rawName
            var op = "="
            // `min-` and `max-`, and WebKit's own prefixes on its pixel ratio (§2.4.2).
            for (prefix, comparison) in [("-webkit-min-", ">="), ("-webkit-max-", "<="), ("min-", ">="), ("max-", "<=")]
            where rawName.hasPrefix(prefix) {
                name = (prefix.hasPrefix("-webkit-") ? "-webkit-" : "") + rawName.dropFirst(prefix.count)
                op = comparison
                break
            }
            guard let known = environment(name, dark: dark), op == "=" || known.kind.isRange,
                  let given = value(Array(components[2...]), as: known.kind) else { return .unknown }
            return Truth(compare(name, known.value, op, given))
        }
        return range(contents, dark: dark)
    }

    /// Range syntax (§2.4.3): `(width >= 600px)`, `(400px < width <= 700px)`, for a range
    /// feature alone. `<=` and `>=` are two delimiters with no white space between them.
    private static func range(_ contents: [CSSComponent], dark: Bool) -> Truth {
        var parts: [[CSSComponent]] = [[]]
        var operators: [String] = []
        var index = 0
        while index < contents.count {
            let c = contents[index]
            if case .token(.delim(let d)) = c, "<>=".unicodeScalars.contains(d) {
                var op = String(d)
                if index + 1 < contents.count, contents[index + 1].isDelim("="), d != "=" { op += "="; index += 1 }
                operators.append(op); parts.append([])
            } else if !c.isWhitespace { parts[parts.count - 1].append(c) }
            index += 1
        }
        guard (1...2).contains(operators.count), parts.allSatisfy({ !$0.isEmpty }) else { return .unknown }
        // The feature `part` names, when it is a name alone and the feature has a range.
        func named(_ part: [CSSComponent]) -> (name: String, kind: Kind, actual: Value)? {
            guard part.count == 1, let name = part[0].ident, let known = environment(name, dark: dark),
                  known.kind.isRange else { return nil }
            return (name, known.kind, known.value)
        }
        // The feature compared with the value `part` gives, `part` written on the left when `flipped`.
        func test(_ feature: (name: String, kind: Kind, actual: Value), _ op: String, _ part: [CSSComponent],
                  flipped: Bool) -> Bool? {
            guard let given = value(part, as: feature.kind) else { return nil }
            let mirrored = flipped ? String(op.map { $0 == "<" ? ">" : $0 == ">" ? "<" : $0 }) : op
            return compare(feature.name, feature.actual, mirrored, given)
        }
        if operators.count == 2 {
            // `<mf-value> <mf-lt> <mf-name> <mf-lt> <mf-value>`, or both `>`.
            guard operators.allSatisfy({ $0 != "=" }), operators[0].first == operators[1].first, let feature = named(parts[1]),
                  let low = test(feature, operators[0], parts[0], flipped: true),
                  let high = test(feature, operators[1], parts[2], flipped: false) else { return .unknown }
            return Truth(low && high)
        }
        if let feature = named(parts[0]) {
            return test(feature, operators[0], parts[1], flipped: false).map(Truth.init) ?? .unknown
        }
        if let feature = named(parts[1]) {
            return test(feature, operators[0], parts[0], flipped: true).map(Truth.init) ?? .unknown
        }
        return .unknown
    }
}

/// `@supports` conditions (CSS Conditional Rules 3), evaluated once at parse time.
enum CSSSupports {
    static func evaluate(_ components: [CSSComponent], namespaces: CSSNamespaces) -> Bool {
        condition(components.significant, namespaces: namespaces) ?? false
    }

    /// A `<supports-condition>` over whitespace-free components; nil when it does not parse.
    static func condition(_ components: [CSSComponent], namespaces: CSSNamespaces) -> Bool? {
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
                let value = Array(contents.drop { $0 != .token(.colon) }.dropFirst()).trimmingWhitespace
                if case .token(.ident(let custom)) = inner[0], custom.hasPrefix("--") {
                    return CSSPropertyParser.parseCustom(name: custom, value: value, important: false) != nil
                }
                return CSSPropertyParser.parse(name: name, value: value, important: false) != nil
            }
            return condition(inner, namespaces: namespaces) ?? false
        case .function("selector", let arguments):
            let selectors = try? CSSSelectorParser(namespaces: namespaces).parseList(arguments)
            return selectors?.allSatisfy { $0.pseudoElement == nil || $0.pseudoElement == .before || $0.pseudoElement == .after } ?? false
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
