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

    /// Which rules a sheet's top level still takes, in order (CSS Cascade 5 §2, CSS Namespaces
    /// §3, as Chromium's parser decides them): `@import` before any valid rule but `@charset` and
    /// the `@layer` statements that precede the first import, then `@namespace`, then the rest.
    /// A rule that is not valid, and so is dropped, moves nothing: an unknown at-rule, one written
    /// in the wrong place or with a prelude its grammar does not take, a style rule whose selector
    /// is invalid.
    private enum Section: Comparable {
        /// Nothing but `@charset` and `@layer` statements yet.
        case start
        case imports
        case namespaces
        case rules
    }

    private struct Builder {
        let path: String
        var sheet = CSSStyleSheet()
        var namespaces = CSSNamespaces()
        var section = Section.start

        init(path: String) { self.path = path }

        mutating func interpret(_ rules: [CSSRawRule], media: CSSMediaMask, topLevel: Bool, depth: Int) {
            for rule in rules {
                switch rule {
                case .qualified(let prelude, let block):
                    // Under media that never match nothing is imported, so the rule need not be read.
                    guard !media.isEmpty else { continue }
                    if styleRule(prelude, block, media: media), topLevel { section = .rules }
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
            // Of the pseudo-elements `::before`, `::after` and `::first-letter` are rendered, and a
            // `::first-line` that matches is disclosed (`CSSRuleIndex`).
            let matching = selectors.filter { $0.pseudoElement != .other }
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
        /// valid at the top level of a sheet, those Chromium keeps. Each takes a block and a
        /// prelude its grammar allows (`CSSAtRulePrelude`): an unknown at-rule, or one of these
        /// written as a statement or with another prelude, is invalid.
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
                guard topLevel, section <= .imports, block == nil, importRule(prelude.significant, media: media) else { return }
                section = .imports
                return
            case "namespace":
                guard topLevel, section <= .namespaces, block == nil, namespaceRule(prelude.significant) else { return }
                section = .namespaces
                return
            case "layer" where block == nil:
                // Layers are flattened, so a statement declares nothing to keep. Before the first
                // `@import` it leaves the imports open; after one it ends them and the namespaces.
                guard topLevel, CSSAtRulePrelude.layerNameCount(prelude) != nil, section != .start else { return }
                section = .rules
                return
            default:
                break
            }
            guard let block, Self.blockAtRules.contains(name), CSSAtRulePrelude.isValid(name, prelude, namespaces: namespaces) else { return }
            if topLevel { section = .rules }
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

        /// Adds what applies of an `@import`, and returns whether the rule is valid: whether it
        /// names a sheet and its `supports()` condition, if any, parses, whatever its conditions
        /// then match.
        private mutating func importRule(_ components: [CSSComponent], media: CSSMediaMask) -> Bool {
            guard let first = components.first, let href = Self.url(first) else { return false }
            var rest = Array(components.dropFirst())
            switch rest.first {
            case .token(.ident(let word))? where word.lowercased() == "layer": rest.removeFirst()
            // A `layer()` that names no one layer is left to the media query list, where it is
            // unknown, as Chromium reads it.
            case .function("layer", let arguments)? where CSSAtRulePrelude.layerNameCount(arguments) == 1: rest.removeFirst()
            default: break
            }
            if let supports = rest.first, case .function("supports", let arguments) = supports {
                rest.removeFirst()
                let condition: [CSSComponent] = arguments.significant.first.map { first in
                    if case .block = first { return arguments }
                    return [.block(.openParen, arguments)]
                } ?? []
                guard let supported = CSSSupports.condition(condition.significant, namespaces: namespaces) else { return false }
                guard supported else { return true }
            }
            let mask = media.intersection(CSSMedia.mask(rest))
            guard !mask.isEmpty else { return true }
            switch StyleReference(href, relativeTo: path) {
            case .local(let target): sheet.imports.append(CSSImport(path: target, media: mask))
            case .remote: sheet.remoteReferences += 1
            case .data, .invalid: break
            }
            return true
        }

        /// Declares a namespace, and returns whether the rule is valid.
        private mutating func namespaceRule(_ components: [CSSComponent]) -> Bool {
            switch components.count {
            case 1:
                guard let uri = Self.url(components[0]) else { return false }
                namespaces.defaultNamespace = uri
            case 2:
                guard let prefix = components[0].ident, let uri = Self.url(components[1]) else { return false }
                if case .token(.ident(let original)) = components[0] { namespaces.prefixes[original] = uri }
                namespaces.prefixes[prefix] = uri
            default:
                return false
            }
            return true
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

        /// A `src` descriptor's sources: the archive paths in preference order and the count of
        /// remote ones. nil when it has no source the reader could use, in a format CoreText
        /// loads: CSS Fonts 4 §4.3 makes a `src` with no supported source invalid, and a
        /// `local()` face is not one here.
        private func sourceList(_ value: [CSSComponent]) -> (paths: [String], remote: Int)? {
            var paths: [String] = [], remote = 0, supported = false
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
                supported = true
                switch StyleReference(href, relativeTo: path) {
                case .local(let target): if !paths.contains(target) { paths.append(target) }
                case .remote: remote += 1
                case .data, .invalid: break
                }
            }
            return supported ? (paths, remote) : nil
        }

        private mutating func fontFace(_ block: [CSSComponent]) -> CSSFontFace? {
            var family: String?, sources: (paths: [String], remote: Int) = ([], 0)
            var weights = 400...400, italic = false
            for declaration in CSSParser.declarations(block) {
                let value = declaration.value.significant
                switch declaration.name {
                case "font-family":
                    family = CSSPropertyParser.families(value)?.first
                case "src":
                    // As for any descriptor, a later valid `src` replaces an earlier one, which
                    // the two-`src` pattern for old Internet Explorer relies on.
                    if let list = sourceList(value) { sources = list }
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
            // Only the `src` that stands is fetched by a browser, so only its remote sources count.
            sheet.remoteReferences += sources.remote
            guard let family, !sources.paths.isEmpty else { return nil }
            return CSSFontFace(family: family, weights: weights, isItalic: italic, sources: sources.paths)
        }
    }
}

/// Whether a block at-rule's prelude is one its grammar takes, as Chromium decides it. A rule
/// whose prelude is not is dropped with all it holds, and ends no `@import` section.
private enum CSSAtRulePrelude {
    static func isValid(_ name: String, _ prelude: [CSSComponent], namespaces: CSSNamespaces) -> Bool {
        let significant = prelude.significant
        switch name {
        case "media":
            // A query list that does not parse is `not all`, and the rule stays (Media Queries 4 §3.2).
            return true
        case "supports":
            return CSSSupports.condition(significant, namespaces: namespaces) != nil
        case "layer":
            return significant.isEmpty || layerNameCount(prelude) == 1
        case "font-face", "starting-style", "view-transition":
            return significant.isEmpty
        case "keyframes", "-webkit-keyframes":
            // `<keyframes-name>` (CSS Animations 1 §3).
            guard significant.count == 1 else { return false }
            switch significant[0] {
            case .token(.ident(let name)): return isCustomIdent(name, excluding: ["none"])
            case .token(.string(let name)): return !name.isEmpty
            default: return false
            }
        case "counter-style":
            // A `<counter-style-name>` that does not name a style a sheet may not redefine
            // (CSS Counter Styles 3 §3).
            guard significant.count == 1, case .token(.ident(let name)) = significant[0] else { return false }
            return isCustomIdent(name, excluding: ["none", "decimal", "disc", "square", "circle", "disclosure-open", "disclosure-closed"])
        case "property", "font-palette-values", "position-try":
            guard significant.count == 1, case .token(.ident(let name)) = significant[0] else { return false }
            return isDashedIdent(name)
        case "font-feature-values":
            return isFamilyNameList(significant)
        case "page":
            return isPageSelectorList(prelude)
        case "container":
            return isContainerQuery(significant)
        case "scope":
            return isScopePrelude(significant, namespaces: namespaces)
        case "function":
            return isFunctionPrelude(significant)
        default:
            return false
        }
    }

    /// The number of names in a `<layer-name>#` (CSS Cascade 5 §6.4.2), each its idents joined
    /// by `.` with nothing between and none a CSS-wide keyword; nil when it is not one.
    static func layerNameCount(_ components: [CSSComponent]) -> Int? {
        var count = 0
        for part in components.split(separator: .token(.comma), omittingEmptySubsequences: false) {
            let name = Array(part).trimmingWhitespace
            guard name.count % 2 == 1 else { return nil }
            for (offset, component) in name.enumerated() {
                if offset % 2 == 1 {
                    guard component.isDelim(".") else { return nil }
                } else {
                    guard case .token(.ident(let segment)) = component, !cssWideKeywords.contains(segment.lowercased()) else { return nil }
                }
            }
            count += 1
        }
        return count
    }

    private static let cssWideKeywords: Set<String> = ["initial", "inherit", "unset", "revert", "revert-layer"]

    /// A `<custom-ident>` (CSS Values 4 §4.2), and none of `excluded`, all compared ASCII
    /// case-insensitively.
    private static func isCustomIdent(_ name: String, excluding excluded: Set<String> = []) -> Bool {
        let lower = name.lowercased()
        return !cssWideKeywords.contains(lower) && lower != "default" && !excluded.contains(lower)
    }

    /// A `<dashed-ident>` other than `--` alone.
    private static func isDashedIdent(_ name: String) -> Bool { name.hasPrefix("--") && name.count > 2 }

    /// `<family-name>#`: strings, or idents, where a family of one is no generic family.
    private static func isFamilyNameList(_ components: [CSSComponent]) -> Bool {
        let generic: Set<String> = ["serif", "sans-serif", "cursive", "fantasy", "monospace", "system-ui", "math", "emoji", "fangsong",
                                    "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded"]
        let families = components.split(separator: .token(.comma), omittingEmptySubsequences: false)
        return families.allSatisfy { family in
            if family.count == 1, case .token(.string(let name)) = family.first! { return !name.isEmpty }
            let words = family.compactMap { component -> String? in
                if case .token(.ident(let word)) = component { return word }
                return nil
            }
            guard !words.isEmpty, words.count == family.count else { return false }
            return words.count > 1 || isCustomIdent(words[0], excluding: generic)
        }
    }

    /// `<page-selector-list>` (CSS Paged Media 3 §3.1), with the page pseudo-classes Chromium
    /// knows, or nothing.
    private static func isPageSelectorList(_ prelude: [CSSComponent]) -> Bool {
        guard !prelude.significant.isEmpty else { return true }
        return prelude.split(separator: .token(.comma), omittingEmptySubsequences: false).allSatisfy { part in
            var selector = Array(part).trimmingWhitespace[...]
            guard !selector.isEmpty else { return false }
            if case .token(.ident)? = selector.first { selector = selector.dropFirst() }
            while let colon = selector.first {
                guard colon == .token(.colon), selector.count >= 2,
                      let pseudo = selector[selector.startIndex + 1].ident, ["first", "left", "right"].contains(pseudo) else { return false }
                selector = selector.dropFirst(2)
            }
            return true
        }
    }

    /// `[ <container-name> ]? <container-condition>` (CSS Conditional 5 §6.2). A query in
    /// parentheses or a function stands for itself: what it asks is never evaluated here.
    private static func isContainerQuery(_ components: [CSSComponent]) -> Bool {
        var condition = components[...]
        if case .token(.ident(let name))? = condition.first, isCustomIdent(name, excluding: ["none", "not", "and", "or"]) {
            condition = condition.dropFirst()
        }
        func inParens(_ component: CSSComponent) -> Bool {
            switch component {
            case .block(.openParen, _), .function: true
            default: false
            }
        }
        guard let first = condition.first else { return false }
        if first.ident == "not" { return condition.count == 2 && inParens(condition[condition.startIndex + 1]) }
        guard inParens(first) else { return false }
        var joiner: String?
        var index = condition.startIndex + 1
        while index < condition.endIndex {
            guard let word = condition[index].ident, word == "and" || word == "or", joiner == nil || joiner == word,
                  index + 1 < condition.endIndex, inParens(condition[index + 1]) else { return false }
            joiner = word
            index += 2
        }
        return true
    }

    /// `[ ( <scope-start> ) ]? [ to ( <scope-end> ) ]?` (CSS Cascade 6 §2.5.1), each a selector
    /// list without a pseudo-element.
    private static func isScopePrelude(_ components: [CSSComponent], namespaces: CSSNamespaces) -> Bool {
        func isBoundary(_ component: CSSComponent) -> Bool {
            guard case .block(.openParen, let contents) = component,
                  let selectors = try? CSSSelectorParser(namespaces: namespaces).parseList(contents.trimmingWhitespace) else { return false }
            return selectors.allSatisfy { $0.pseudoElement == nil }
        }
        var rest = components[...]
        if let first = rest.first, first.ident != "to" {
            guard isBoundary(first) else { return false }
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return true }
        return rest.count == 2 && rest.first?.ident == "to" && isBoundary(rest[rest.startIndex + 1])
    }

    /// `<function-token> <function-parameter>#? ) [ returns <css-type> ]?` (CSS Mixins 1 §2.1),
    /// with a `<dashed-function>` name and each parameter a `<custom-property-name>` first.
    private static func isFunctionPrelude(_ components: [CSSComponent]) -> Bool {
        guard case .function(let name, let parameters)? = components.first, isDashedIdent(name) else { return false }
        if !parameters.significant.isEmpty {
            guard parameters.commaSeparated.allSatisfy({ parameter in
                guard case .token(.ident(let name))? = parameter.first else { return false }
                return isDashedIdent(name)
            }) else { return false }
        }
        let rest = components.dropFirst()
        return rest.isEmpty || (rest.first?.ident == "returns" && rest.count >= 2)
    }
}
