import EPUBCore
import Foundation

/// A parsed, bounded author stylesheet.
struct CSSStyleSheet: Sendable {
    static let empty = CSSStyleSheet()
    /// `@font-face` rules, sources resolved to archive paths.
    var fontFaces: [CSSFontFace] = []
    /// Style rules in source order, `@media` and `@supports` flattened.
    var rules: [CSSStyleRule] = []
    /// `@import`ed sheets as decoded archive paths, in order. Their rules precede this sheet's.
    var imports: [CSSImport] = []
    /// Remote references (`@import`, `@font-face` sources) that were dropped.
    var remoteReferences = 0
    /// A bound dropped part of the input.
    var truncated = false

    static let maximumRules = 20_000
    static let maximumConditionalNesting = 16
}

struct CSSStyleRule: Sendable {
    var selectors: [CSSComplexSelector]
    var declarations: [CSSDeclaration]
    /// Custom properties (`--name`), which `media` decides for each appearance as a whole
    /// (`CSSRuleIndex`).
    var custom: [CSSCustomDeclaration] = []
    var media: CSSMediaMask
}

struct CSSImport: Equatable, Sendable {
    let path: String
    let media: CSSMediaMask
}

struct CSSFontFace: Hashable, Sendable {
    /// Lowercased, unquoted.
    var family: String
    /// `font-weight` range the face covers.
    var weights: ClosedRange<Int> = 400...400
    var isItalic = false
    /// Decoded archive paths, in preference order. Remote sources are dropped (and counted).
    var sources: [String] = []
}

/// A reference found in a stylesheet or document, classified before anything is read.
enum StyleReference: Equatable {
    /// A decoded archive path.
    case local(String)
    /// Has a scheme or is network-path relative (`//host/…`): never fetched.
    case remote
    /// A `data:` URL, which this renderer does not decode for styles or fonts.
    case data
    /// Names no path an archive entry can have.
    case invalid

    init(_ reference: String, relativeTo base: String) {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { self = .invalid; return }
        if trimmed.lowercased().hasPrefix("data:") { self = .data; return }
        if trimmed.hasPrefix("//") || Self.hasScheme(trimmed) { self = .remote; return }
        // Queries and fragments (`font.eot?#iefix`) never name a different archive entry. Cut at
        // the byte, as `ResourceReference` reads: as a `Character`, a "?" or "#" before a
        // combining mark is another character.
        let path = String(decoding: trimmed.utf8.prefix { $0 != 0x3F && $0 != 0x23 }, as: UTF8.self) // ? #
        guard !path.isEmpty, let encoded = try? ResourceReference.resolve(path, relativeTo: base),
              let decoded = encoded.removingPercentEncoding else { self = .invalid; return }
        self = .local(decoded)
    }

    private static func hasScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":"), colon != value.startIndex else { return false }
        let scheme = value[..<colon]
        return scheme.first!.isASCII && scheme.first!.isLetter
            && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }
}

extension CSSStyleSheet {
    /// Parses a stylesheet whose relative references resolve against the archive path `path`.
    /// `media` applies to every rule (from a `media` attribute or an `@import` condition).
    static func parse(_ text: String, path: String, media: CSSMediaMask = .all) -> CSSStyleSheet {
        var builder = Builder(path: path)
        var truncated = false
        let components = CSSParser.components(text, truncated: &truncated)
        builder.sheet.truncated = truncated
        builder.interpret(CSSParser.rules(components, topLevel: true), media: media, topLevel: true, depth: 0)
        return builder.sheet
    }

    /// Parses a `style` attribute's declarations, those of custom properties apart.
    static func declarations(_ text: String) -> [CSSDeclaration] { block(text).declarations }

    /// Parses a `style` attribute's declarations.
    static func block(_ text: String) -> CSSDeclarationBlock {
        var truncated = false
        return CSSPropertyParser.block(CSSParser.declarations(CSSParser.components(text, truncated: &truncated)), isRuleValue: false)
    }

    private struct Builder {
        let path: String
        var sheet = CSSStyleSheet()
        var namespaces = CSSNamespaces()
        /// `@import` is honoured only before any other valid rule (CSS Cascade 4 §2: "Any @import
        /// rules must precede all other valid at-rules and style rules"). A rule the parser drops,
        /// an unknown at-rule or a style rule whose selector is invalid, leaves it set.
        var importsAllowed = true

        init(path: String) { self.path = path }

        mutating func interpret(_ rules: [CSSRawRule], media: CSSMediaMask, topLevel: Bool, depth: Int) {
            for rule in rules {
                switch rule {
                case .qualified(let prelude, let block):
                    // Under media that never match nothing is imported, so the rule need not be read.
                    guard !media.isEmpty else { continue }
                    if styleRule(prelude, block, media: media) { importsAllowed = false }
                case .at(let name, let prelude, let block):
                    atRule(name, prelude, block, media: media, topLevel: topLevel, depth: depth)
                }
            }
        }

        /// Adds what applies of a style rule, and returns whether the rule is valid: whether its
        /// selector list is, whatever the rule then sets or matches.
        private mutating func styleRule(_ prelude: [CSSComponent], _ block: [CSSComponent], media: CSSMediaMask) -> Bool {
            guard sheet.rules.count < CSSStyleSheet.maximumRules else { sheet.truncated = true; return true }
            let selectors: [CSSComplexSelector]
            do { selectors = try CSSSelectorParser(namespaces: namespaces).parseList(prelude.trimmingWhitespace) }
            catch .tooComplex { sheet.truncated = true; return true }
            catch { return false }
            // Of the pseudo-elements only `::before` and `::after` are rendered.
            let matching = selectors.filter { $0.pseudoElement == nil || $0.pseudoElement == .before || $0.pseudoElement == .after }
            guard !matching.isEmpty else { return true }
            let parsed = CSSPropertyParser.block(CSSParser.declarations(block), isRuleValue: true)
            let declarations = parsed.declarations
            guard !parsed.isEmpty else { return true }
            guard media != .all else {
                sheet.rules.append(CSSStyleRule(selectors: matching, declarations: declarations, custom: parsed.custom, media: media))
                return true
            }
            // In a rule for one appearance, what decides generated characters
            // (`CSSProperty.generatedText`, `generatedBox`) is resolved as in the light
            // appearance: from a rule for light it applies in both, and from one for dark in
            // neither. So a section's characters are the same in light and dark, as for what
            // else such a rule sets that does not paint (#130). Its custom properties stay under
            // its media, and the rule index keeps each appearance's apart.
            for generated in [false, true] {
                let selectors = matching.filter { $0.hasPseudoElement == generated }
                guard !selectors.isEmpty else { continue }
                let decides = generated ? CSSProperty.generatedBox : CSSProperty.generatedText
                let follows = declarations.filter { !decides.contains($0.property) }
                let light = declarations.filter { decides.contains($0.property) }
                if !follows.isEmpty || !parsed.custom.isEmpty {
                    sheet.rules.append(CSSStyleRule(selectors: selectors, declarations: follows, custom: parsed.custom, media: media))
                }
                if media.contains(.light), !light.isEmpty {
                    sheet.rules.append(CSSStyleRule(selectors: selectors, declarations: light, media: .all))
                }
            }
            return true
        }

        /// At-rules other than `@charset`, `@import`, `@namespace` and `@layer` statements that are
        /// valid at the top level of a sheet, those Chromium keeps. Each takes a block: an unknown
        /// at-rule, or one of these written as a statement, is invalid.
        private static let blockAtRules: Set<String> = [
            "media", "supports", "layer", "font-face",
            "page", "keyframes", "-webkit-keyframes", "container", "counter-style", "font-feature-values",
            "font-palette-values", "property", "scope", "starting-style", "position-try", "view-transition", "function",
        ]

        private mutating func atRule(_ name: String, _ prelude: [CSSComponent], _ block: [CSSComponent]?,
                                     media: CSSMediaMask, topLevel: Bool, depth: Int) {
            switch name {
            case "charset":
                return
            case "import":
                guard topLevel, importsAllowed, block == nil else { return }
                importRule(prelude.significant, media: media)
                return
            case "namespace":
                guard topLevel, block == nil else { return }
                namespaceRule(prelude.significant)
                return
            case "layer" where block == nil:
                return
            default:
                break
            }
            guard let block else { return }
            if Self.blockAtRules.contains(name) { importsAllowed = false }
            guard depth < CSSStyleSheet.maximumConditionalNesting else { sheet.truncated = true; return }
            switch name {
            case "media":
                let mask = media.intersection(CSSMedia.mask(prelude))
                interpret(CSSParser.rules(block, topLevel: false), media: mask, topLevel: false, depth: depth + 1)
            case "supports":
                guard CSSSupports.evaluate(prelude, namespaces: namespaces) else { return }
                interpret(CSSParser.rules(block, topLevel: false), media: media, topLevel: false, depth: depth + 1)
            case "layer":
                // Cascade layers are flattened: layered rules cascade as unlayered ones.
                interpret(CSSParser.rules(block, topLevel: false), media: media, topLevel: false, depth: depth + 1)
            case "font-face":
                guard !media.isEmpty, let face = fontFace(block) else { return }
                sheet.fontFaces.append(face)
            default:
                // @page, @keyframes, @container, @counter-style…: not applicable to reflowed text.
                return
            }
        }

        private mutating func importRule(_ components: [CSSComponent], media: CSSMediaMask) {
            guard let first = components.first, let href = Self.url(first) else { return }
            var rest = Array(components.dropFirst())
            switch rest.first {
            case .token(.ident(let word))? where word.lowercased() == "layer": rest.removeFirst()
            case .function("layer", _)?: rest.removeFirst()
            default: break
            }
            if let supports = rest.first, case .function("supports", let arguments) = supports {
                rest.removeFirst()
                let condition: [CSSComponent] = arguments.significant.first.map { first in
                    if case .block = first { return arguments }
                    return [.block(.openParen, arguments)]
                } ?? []
                guard CSSSupports.evaluate(condition, namespaces: namespaces) else { return }
            }
            let mask = media.intersection(CSSMedia.mask(rest))
            guard !mask.isEmpty else { return }
            switch StyleReference(href, relativeTo: path) {
            case .local(let target): sheet.imports.append(CSSImport(path: target, media: mask))
            case .remote: sheet.remoteReferences += 1
            case .data, .invalid: break
            }
        }

        private mutating func namespaceRule(_ components: [CSSComponent]) {
            switch components.count {
            case 1:
                if let uri = Self.url(components[0]) { namespaces.defaultNamespace = uri }
            case 2:
                guard let prefix = components[0].ident, let uri = Self.url(components[1]) else { return }
                if case .token(.ident(let original)) = components[0] { namespaces.prefixes[original] = uri }
                namespaces.prefixes[prefix] = uri
            default:
                return
            }
        }

        static func url(_ component: CSSComponent) -> String? {
            switch component {
            case .token(.url(let value)), .token(.string(let value)): return value
            case .function("url", let arguments), .function("src", let arguments):
                guard case .token(.string(let value))? = arguments.significant.first else { return nil }
                return value
            default: return nil
            }
        }

        /// Formats CoreText can load; others (EOT, SVG fonts) are skipped.
        private static let fontFormats: Set<String> = ["truetype", "opentype", "woff", "woff2", "truetype-aat",
                                                       "collection", "ttf", "otf", "woff-variations",
                                                       "woff2-variations", "opentype-variations", "truetype-variations"]

        private mutating func fontFace(_ block: [CSSComponent]) -> CSSFontFace? {
            var family: String?, sources: [String] = []
            var weights = 400...400, italic = false
            for declaration in CSSParser.declarations(block) {
                let value = declaration.value.significant
                switch declaration.name {
                case "font-family":
                    family = CSSPropertyParser.families(value)?.first
                case "src":
                    for part in value.split(separator: .token(.comma)) {
                        guard let first = part.first, let href = Self.url(first) else { continue }
                        let formats = part.compactMap { component -> [String]? in
                            guard case .function("format", let arguments) = component else { return nil }
                            return arguments.significant.compactMap {
                                switch $0 {
                                case .token(.string(let v)), .token(.ident(let v)): v.lowercased()
                                default: nil
                                }
                            }
                        }.flatMap { $0 }
                        if !formats.isEmpty, !formats.contains(where: Self.fontFormats.contains) { continue }
                        switch StyleReference(href, relativeTo: path) {
                        case .local(let target): if !sources.contains(target) { sources.append(target) }
                        case .remote: sheet.remoteReferences += 1
                        case .data, .invalid: break
                        }
                    }
                case "font-weight":
                    let numbers = value.compactMap { component -> Int? in
                        switch component {
                        case .token(.ident(let v)): ["normal": 400, "bold": 700][v.lowercased()]
                        default: CSSPropertyParser.absoluteWeight(component)
                        }
                    }
                    if numbers.count == value.count, let low = numbers.first {
                        let high = numbers.last!
                        weights = min(low, high)...max(low, high)
                    }
                case "font-style":
                    italic = ["italic", "oblique"].contains(value.first?.ident ?? "")
                default:
                    break
                }
            }
            guard let family, !sources.isEmpty else { return nil }
            return CSSFontFace(family: family, weights: weights, isItalic: italic, sources: sources)
        }
    }
}
