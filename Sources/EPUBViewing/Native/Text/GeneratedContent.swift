import Foundation

/// The counters and the quotation depth that generated content reads, as one section's walk
/// meets them in document order (CSS Lists 3 §4, CSS Generated Content 3 §2.4). The section's
/// writer and the writers it starts for table cells and captions share one state; a note's
/// rendering works on a copy (`SectionBuildState.captureNote`).
struct GeneratedContentState {
    /// UTF-16 units all of a section's generated content may hold: enough for any book, and a
    /// bound on what a hostile `*::before` can add.
    static let maximumLength = 1 << 20

    private struct Counter {
        var value: Int
        /// The element whose subtree the counter is in scope for: the parent of the element
        /// that instantiated it, or the originating element of a `::before` or `::after`. Its
        /// scope is that element's and its following siblings', and it ends with the owner.
        let owner: Int
    }

    /// Each name's counters, the innermost last.
    private var counters: [String: [Counter]] = [:]
    /// Every counter in scope by name, in the order they were instantiated, so that leaving an
    /// element ends the scopes it owned.
    private var instantiated: [(name: String, owner: Int)] = []
    /// Open quotes not yet closed.
    private(set) var quoteDepth = 0
    private(set) var remaining = GeneratedContentState.maximumLength
    /// A bound left generated characters out.
    private(set) var truncated = false
    /// Table rows and row groups whose counters have changed (`counts`).
    private var countedTableParts = Set<Int>()

    // MARK: Counters

    /// An element's or a pseudo-element's `counter-reset`, `counter-increment` and
    /// `counter-set`, in that order (CSS 2 §12.4). `owner` owns the counters it instantiates.
    /// `list-item` is the lists' own numbering, which these do not change.
    mutating func apply(_ style: ComputedStyle, owner: Int) {
        for change in style.counterReset where change.name != Self.listItem {
            instantiate(change.name, value: change.value, owner: owner)
        }
        for change in style.counterIncrement where change.name != Self.listItem {
            if counters[change.name]?.isEmpty ?? true { instantiate(change.name, value: 0, owner: owner) }
            update(change.name) { $0 + change.value }
        }
        for change in style.counterSet where change.name != Self.listItem {
            if counters[change.name]?.isEmpty ?? true { instantiate(change.name, value: change.value, owner: owner) }
            else { update(change.name) { _ in change.value } }
        }
    }

    /// CSS Lists 3's counter of list items.
    static let listItem = "list-item"

    /// Whether a table's row or row group has yet to change its counters: true once. Nothing
    /// walks them, so they count with their first cell.
    mutating func counts(_ part: ContentNode) -> Bool { countedTableParts.insert(part.order).inserted }

    /// Ends the scope of every counter owned by `element` or by an element inside it.
    mutating func leave(_ element: ContentNode) {
        while let last = instantiated.last, last.owner >= element.order, last.owner <= element.subtreeEnd {
            instantiated.removeLast()
            counters[last.name]?.removeLast()
            if counters[last.name]?.isEmpty == true { counters[last.name] = nil }
        }
    }

    /// A counter that one owner instantiates again replaces its earlier one, as a sibling's
    /// reset replaces a sibling's (CSS Lists 3 §4.5).
    private mutating func instantiate(_ name: String, value: Int, owner: Int) {
        let value = Self.clamp(value)
        if let last = counters[name]?.last, last.owner == owner {
            counters[name]![counters[name]!.count - 1].value = value
            return
        }
        counters[name, default: []].append(Counter(value: value, owner: owner))
        instantiated.append((name, owner))
    }

    private mutating func update(_ name: String, _ change: (Int) -> Int) {
        guard let last = counters[name]?.indices.last else { return }
        counters[name]![last].value = Self.clamp(change(counters[name]![last].value))
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, CSSPropertyParser.counterRange.lowerBound), CSSPropertyParser.counterRange.upperBound)
    }

    /// The values of a counter, outermost first. One that is not in scope is instantiated at 0
    /// for `owner` (CSS Lists 3 §4.5). `list-item` is the numbering of the lists around, the
    /// values their markers show: `listItems`.
    private mutating func values(_ name: String, owner: Int, listItems: [Int]) -> [Int] {
        if name == Self.listItem { return listItems.isEmpty ? [0] : listItems }
        if let stack = counters[name], !stack.isEmpty { return stack.map(\.value) }
        instantiate(name, value: 0, owner: owner)
        return [0]
    }

    // MARK: Text

    /// The characters a box with this `content` generates, evaluated in order: counters and
    /// quotes as they stand, the quotation depth changed by each quote. `language` is the one
    /// the content declares, for `quotes: auto`. Items the reader does not generate add nothing.
    mutating func text(of style: ComputedStyle, owner: Int, language: String?, listItems: [Int]) -> String {
        var text = ""
        for item in style.content ?? [] {
            switch item {
            case .string(let value), .attribute(let value): text += value
            case .openQuote:
                text += Self.marks(style.quotes, language: language, depth: quoteDepth).open
                quoteDepth += 1
            case .closeQuote:
                guard quoteDepth > 0 else { continue }
                quoteDepth -= 1
                text += Self.marks(style.quotes, language: language, depth: quoteDepth).close
            case .noOpenQuote: quoteDepth += 1
            case .noCloseQuote: quoteDepth = max(0, quoteDepth - 1)
            case .counter(let name, let type):
                text += ListMarker.representation(type, value: values(name, owner: owner, listItems: listItems).last ?? 0)
            case .counters(let name, let separator, let type):
                text += values(name, owner: owner, listItems: listItems)
                    .map { ListMarker.representation(type, value: $0) }.joined(separator: separator)
            case .unsupported: break
            }
            if text.utf16.count > remaining { break }
        }
        let length = text.utf16.count
        guard length > remaining else { remaining -= length; return text }
        truncated = true
        let units = Array(text.utf16.prefix(remaining))
        remaining = 0
        // Never half a surrogate pair.
        let kept = units.last.map(UTF16.isLeadSurrogate) == true ? units.dropLast() : units[...]
        return String(decoding: kept, as: UTF16.self)
    }

    /// The pair at `depth`: the first at depth 0 and, past the last pair, the last again (CSS 2.2
    /// §12.3.2), for the language's two pairs of `auto` as for a list the book gives.
    private static func marks(_ quotes: ComputedStyle.Quotes, language: String?, depth: Int) -> (open: String, close: String) {
        let pairs: [ComputedStyle.QuotePair] = switch quotes {
        case .auto: ContentSemantics.quotes(language: language)
        case .none: []
        case .pairs(let pairs): pairs
        }
        guard let last = pairs.indices.last else { return ("", "") }
        let pair = pairs[min(depth, last)]
        return (pair.open, pair.close)
    }
}
