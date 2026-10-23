import Foundation

// Generated content: `::before` and `::after` with `content` (CSS 2 §12.1, CSS Generated
// Content 3 §2), `quotes` (§2.4) and the counters of CSS Lists 3 §4. The cascade computes an
// element's two boxes (`StyleResolver.generatedBoxes`); the writer generates their characters
// as it walks (`GeneratedContent.swift`).

extension ComputedStyle {
    /// One item of `content`.
    enum ContentItem: Equatable, Sendable {
        case string(String)
        /// `attr(name)`, until the cascade replaces it by the originating element's attribute.
        case attribute(String)
        case openQuote, closeQuote, noOpenQuote, noCloseQuote
        /// `counter(name, style)`.
        case counter(String, ListStyleType)
        /// `counters(name, separator, style)`.
        case counters(String, separator: String, ListStyleType)
        /// What the reader does not generate: an image (`url()`, `image-set()`, `cross-fade()`, a
        /// gradient), `leader()`, `target-counter()`, `target-counters()`, `target-text()`,
        /// `contents`, or an `attr()` with a type or a fallback. It is left out, and the section
        /// discloses it.
        case unsupported

        /// Whether the item can generate characters, whatever the counters and quotes are.
        var mayGenerateText: Bool {
            switch self {
            case .string(let value), .attribute(let value): !value.isEmpty
            case .noOpenQuote, .noCloseQuote: false
            default: true
            }
        }
    }

    /// `quotes`: the marks `open-quote` and `close-quote` generate, by nesting depth.
    enum Quotes: Equatable, Sendable {
        /// The content language's marks (`ContentSemantics.quotes`).
        case auto
        case none
        /// The last pair stands for every deeper level.
        case pairs([QuotePair])
    }

    struct QuotePair: Equatable, Sendable {
        let open: String
        let close: String
    }

    /// One counter of `counter-reset`, `counter-increment` or `counter-set`, with its value.
    struct CounterChange: Equatable, Sendable {
        /// Counter names are case-sensitive.
        let name: String
        let value: Int
    }
}

/// What `ComputedStyle.generatedContent` holds.
struct GeneratedContentProperties: Equatable, Sendable {
    var quotes: ComputedStyle.Quotes = .auto
    var content: [ComputedStyle.ContentItem]?
    var counterReset: [ComputedStyle.CounterChange] = []
    var counterIncrement: [ComputedStyle.CounterChange] = []
    var counterSet: [ComputedStyle.CounterChange] = []
    var boxes: GeneratedBoxes?
}

/// Generated content's properties, immutable: a style that changes one holds a new storage.
final class GeneratedContentStorage: Equatable, Sendable {
    let properties: GeneratedContentProperties
    init(_ properties: GeneratedContentProperties) { self.properties = properties }
    static func == (lhs: GeneratedContentStorage, rhs: GeneratedContentStorage) -> Bool {
        lhs === rhs || lhs.properties == rhs.properties
    }
}

extension ComputedStyle {
    /// `quotes`. Inherited.
    var quotes: Quotes {
        get { generatedContent?.properties.quotes ?? .auto }
        set { updateGeneratedContent { $0.quotes = newValue } }
    }
    /// `content`, which only a `::before` or an `::after` uses: nil for `normal` and `none`,
    /// which generate no box. Not inherited.
    var content: [ContentItem]? {
        get { generatedContent?.properties.content }
        set { updateGeneratedContent { $0.content = newValue } }
    }
    /// `counter-reset`, `counter-increment` and `counter-set`. Not inherited.
    var counterReset: [CounterChange] {
        get { generatedContent?.properties.counterReset ?? [] }
        set { updateGeneratedContent { $0.counterReset = newValue } }
    }
    var counterIncrement: [CounterChange] {
        get { generatedContent?.properties.counterIncrement ?? [] }
        set { updateGeneratedContent { $0.counterIncrement = newValue } }
    }
    var counterSet: [CounterChange] {
        get { generatedContent?.properties.counterSet ?? [] }
        set { updateGeneratedContent { $0.counterSet = newValue } }
    }
    /// The element's `::before` and `::after`, which the cascade sets (`StyleResolver`): nil when
    /// neither generates a box. Not inherited.
    var generated: GeneratedBoxes? {
        get { generatedContent?.properties.boxes }
        set { updateGeneratedContent { $0.boxes = newValue } }
    }

    private mutating func updateGeneratedContent(_ change: (inout GeneratedContentProperties) -> Void) {
        var properties = generatedContent?.properties ?? GeneratedContentProperties()
        change(&properties)
        generatedContent = properties == GeneratedContentProperties() ? nil : GeneratedContentStorage(properties)
    }
}

/// An element's `::before` and `::after`: each one's computed style, inheriting from the
/// element's, when its `content` generates a box (not `none` or `normal`) and its `display` is
/// not `none`. `attr()` is already the element's attribute.
final class GeneratedBoxes: Equatable, Sendable {
    let before: ComputedStyle?
    let after: ComputedStyle?

    init(before: ComputedStyle?, after: ComputedStyle?) { self.before = before; self.after = after }

    static func == (lhs: GeneratedBoxes, rhs: GeneratedBoxes) -> Bool {
        lhs === rhs || (lhs.before == rhs.before && lhs.after == rhs.after)
    }

    /// Whether either box can show characters (`ContentItem.mayGenerateText`): what a
    /// container that does not show them must disclose.
    var mayGenerateText: Bool {
        [before, after].contains { $0?.content?.contains(where: \.mayGenerateText) ?? false }
    }
}

extension CSSProperty {
    /// What decides the characters an element's `::before` and `::after` generate, and whether
    /// they generate a box at all. In a rule that applies in one appearance only
    /// (`prefers-color-scheme`), these on a `::before` or `::after`, and `generatedText` on an
    /// element, are resolved as in the light appearance (`CSSStyleSheet`), so a section has the
    /// same characters in light and dark.
    static let generatedText: Set<CSSProperty> = [.content, .quotes, .counterReset, .counterIncrement, .counterSet]
    static let generatedBox: Set<CSSProperty> = generatedText.union([
        .display, .textTransform, .whiteSpace, .fontVariantCaps, .position, .top, .left, .clip, .clipPath,
    ])
}

extension CSSPropertyParser {
    static let maximumContentItems = 64
    static let maximumCounterChanges = 32
    static let maximumQuotePairs = 16
    /// Counter values and changes, as list item values are bounded.
    static let counterRange = -1_000_000_000...1_000_000_000

    /// `content`: `normal`, `none`, or a list of strings, quotes, counters and `attr()`, with
    /// optional alternative text after `/`, which is not read (only what is shown is).
    static func content(_ c: [CSSComponent]) -> CSSValue? {
        if c.count == 1, let keyword = c[0].ident, keyword == "normal" || keyword == "none" { return .content(nil) }
        let parts = c.split(separator: .token(.delim("/")), maxSplits: 1, omittingEmptySubsequences: false)
        guard let shown = parts.first, !shown.isEmpty, shown.count <= maximumContentItems,
              parts.count == 1 || !parts[1].isEmpty else { return nil }
        var items: [ComputedStyle.ContentItem] = []
        for component in shown {
            switch component {
            case .token(.string(let value)): items.append(.string(value))
            case .token(.url): items.append(.unsupported)
            case .token(.ident):
                switch component.ident {
                case "open-quote": items.append(.openQuote)
                case "close-quote": items.append(.closeQuote)
                case "no-open-quote": items.append(.noOpenQuote)
                case "no-close-quote": items.append(.noCloseQuote)
                case "contents": items.append(.unsupported)
                default: return nil
                }
            case .function(let name, let arguments):
                switch name {
                case "attr":
                    let parts = arguments.significant
                    if parts.count == 1, case .token(.ident(let attribute)) = parts[0] { items.append(.attribute(attribute)) }
                    else if parts.first?.ident != nil { items.append(.unsupported) }
                    else { return nil }
                case "counter", "counters":
                    guard let item = counter(name, arguments) else { return nil }
                    items.append(item)
                case "leader", "target-counter", "target-counters", "target-text", "content", "string":
                    items.append(.unsupported)
                default:
                    // An image, read as a background's is (`isImage`): a function the reader
                    // does not know, such as a gradient prefixed for another engine, is none,
                    // and makes the declaration invalid.
                    guard isImage(component) else { return nil }
                    items.append(.unsupported)
                }
            default: return nil
            }
        }
        return .content(items)
    }

    /// `counter(name, style?)` and `counters(name, separator, style?)`.
    private static func counter(_ function: String, _ arguments: [CSSComponent]) -> ComputedStyle.ContentItem? {
        let parts = arguments.commaSeparated
        guard let first = parts.first, first.count == 1, case .token(.ident(let name)) = first[0],
              isCounterName(name) else { return nil }
        var rest = parts.dropFirst()
        var separator: String?
        if function == "counters" {
            guard let next = rest.first, next.count == 1, case .token(.string(let value)) = next[0] else { return nil }
            separator = value
            rest = rest.dropFirst()
        }
        var style = ComputedStyle.ListStyleType.decimal
        if let next = rest.first {
            guard rest.count == 1, next.count == 1, next[0].ident != nil, let type = listStyleType(next[0]) else { return nil }
            style = type
        }
        if let separator { return .counters(name, separator: separator, style) }
        return .counter(name, style)
    }

    /// A counter's name: any identifier but `none` and the CSS-wide keywords.
    private static func isCounterName(_ name: String) -> Bool {
        !["none", "inherit", "initial", "unset", "default", "revert", "revert-layer"].contains(name.lowercased())
    }

    /// `quotes`: `auto`, `none`, or pairs of strings. `match-parent` is taken as `auto`.
    static func quotes(_ c: [CSSComponent]) -> CSSValue? {
        if c.count == 1 {
            switch c[0].ident {
            case "auto", "match-parent": return .quotes(.auto)
            case "none": return .quotes(.none)
            default: break
            }
        }
        guard !c.isEmpty, c.count % 2 == 0, c.count <= 2 * maximumQuotePairs else { return nil }
        var pairs: [ComputedStyle.QuotePair] = []
        for index in stride(from: 0, to: c.count, by: 2) {
            guard case .token(.string(let open)) = c[index], case .token(.string(let close)) = c[index + 1] else { return nil }
            pairs.append(ComputedStyle.QuotePair(open: open, close: close))
        }
        return .quotes(.pairs(pairs))
    }

    /// `counter-reset`, `counter-increment` and `counter-set`: `none`, or names each with an
    /// optional integer, `value` when it has none.
    static func counterChanges(_ c: [CSSComponent], value defaultValue: Int) -> CSSValue? {
        if c.count == 1, c[0].ident == "none" { return .counterChanges([]) }
        var changes: [ComputedStyle.CounterChange] = []
        var index = 0
        while index < c.count {
            guard case .token(.ident(let name)) = c[index], isCounterName(name) else { return nil }
            index += 1
            var value = defaultValue
            if index < c.count, case .token(.number(let number, true, _)) = c[index] {
                value = Int(min(max(number, Double(counterRange.lowerBound)), Double(counterRange.upperBound)))
                index += 1
            } else if index < c.count, let number = calcInteger(c[index]) {
                value = min(max(number, counterRange.lowerBound), counterRange.upperBound)
                index += 1
            }
            changes.append(ComputedStyle.CounterChange(name: name, value: value))
        }
        guard !changes.isEmpty, changes.count <= maximumCounterChanges else { return nil }
        return .counterChanges(changes)
    }
}

extension ListMarker {
    /// A counter's value in a counter style, as `counter()` writes it: without the suffix a
    /// list marker has. Nothing for `none`.
    static func representation(_ type: ComputedStyle.ListStyleType, value: Int) -> String {
        switch type {
        case .none: return ""
        case .disc, .circle, .square, .string: return text(type, value: value) ?? ""
        default:
            let marker = text(type, value: value) ?? ""
            return marker.hasSuffix(".") ? String(marker.dropLast()) : marker
        }
    }
}
