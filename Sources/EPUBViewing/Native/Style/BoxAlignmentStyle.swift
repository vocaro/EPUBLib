import CoreGraphics
import Foundation

// The flex and grid subset: the properties the native layout reads to align a container's
// items (`ReaderAlignmentLayout`) or to recognise a layout it leaves in block flow.

extension ComputedStyle {
    enum FlexDirection: Equatable, Sendable {
        case row, rowReverse, column, columnReverse
        var isColumn: Bool { self == .column || self == .columnReverse }
        var isReversed: Bool { self == .rowReverse || self == .columnReverse }
    }

    /// `justify-content` and `align-content`.
    enum ContentAlignment: Equatable, Sendable {
        case normal, stretch, flexStart, flexEnd, start, end, left, right, center
        case spaceBetween, spaceAround, spaceEvenly
    }

    /// `align-items`, `justify-items` and, with `auto`, `align-self` and `justify-self`.
    enum ItemAlignment: Equatable, Sendable {
        case auto, normal, stretch, start, end, left, right, center, baseline
    }

    /// Container and item values of CSS Flexbox, Grid and Box Alignment. None is inherited.
    struct BoxAlignment: Equatable, Sendable {
        /// The container is a grid rather than a flex container (see `blockifiesChildren`).
        var isGrid = false
        /// `box-sizing: border-box`: `height` and `min-height` include padding and borders.
        var isBorderBox = false
        var direction: FlexDirection = .row
        var wraps = false
        var justifyContent: ContentAlignment = .normal
        var alignContent: ContentAlignment = .normal
        var alignItems: ItemAlignment = .normal
        var justifyItems: ItemAlignment = .normal
        var alignSelf: ItemAlignment = .auto
        var justifySelf: ItemAlignment = .auto
        var order = 0
        var grow: CGFloat = 0
        /// `row-gap`; `normal` is zero.
        var rowGap: Length = .zero
        /// Explicit column tracks of `grid-template-columns`; 0 for `none`.
        var gridColumns = 0
        /// Columns named by `grid-template-areas`; 0 for `none`.
        var gridAreaColumns = 0
        /// `grid-auto-flow: column`.
        var gridFlowsInColumns = false
        /// A grid item placed by `grid-row`, `grid-column` or `grid-area`.
        var hasGridPlacement = false
        /// `height`, `min-height` and `max-height` exactly, when they mix units: nil when the
        /// style's own `Length` is exact (one unit alone, or `auto`).
        var height: MixedLength? {
            get { exactHeights?.values.height }
            set { updateExactHeights { $0.height = newValue } }
        }
        var minHeight: MixedLength? {
            get { exactHeights?.values.minHeight }
            set { updateExactHeights { $0.minHeight = newValue } }
        }
        var maxHeight: MixedLength? {
            get { exactHeights?.values.maxHeight }
            set { updateExactHeights { $0.maxHeight = newValue } }
        }
        /// The three behind one reference, nil when none mixes units, as nearly none does: a
        /// computed style is copied on every nesting level of a table built on a small stack.
        private var exactHeights: ExactHeights?

        private mutating func updateExactHeights(_ change: (inout ExactHeights.Values) -> Void) {
            var values = exactHeights?.values ?? ExactHeights.Values()
            change(&values)
            exactHeights = values == ExactHeights.Values() ? nil : ExactHeights(values)
        }
    }

    /// `BoxAlignment`'s exact heights, shared between the copies of a style.
    final class ExactHeights: Equatable, Sendable {
        struct Values: Equatable, Sendable {
            var height: MixedLength?, minHeight: MixedLength?, maxHeight: MixedLength?
        }
        let values: Values
        init(_ values: Values) { self.values = values }
        static func == (lhs: ExactHeights, rhs: ExactHeights) -> Bool { lhs === rhs || lhs.values == rhs.values }
    }

    /// A length of several units, as `calc(98vh - 3em)` is. `ComputedStyle.Length` holds one
    /// unit, folding the others into it against the nominal viewport; a box's height is the one
    /// place the native layout needs the sum itself.
    struct MixedLength: Equatable, Sendable {
        var points: CGFloat
        /// 0–100 of the containing block's height.
        var percent: CGFloat
        /// 0–100 of the reading viewport: its width, its height, its smaller and its larger side.
        var viewportWidth: CGFloat
        var viewportHeight: CGFloat
        var viewportMin: CGFloat
        var viewportMax: CGFloat

        /// The points and the viewport units in `viewport`: all of the sum but `percent`, which
        /// needs the containing block.
        func resolve(viewport: CGSize) -> CGFloat {
            let smaller = min(viewport.width, viewport.height), larger = max(viewport.width, viewport.height)
            return points + (viewportWidth * viewport.width + viewportHeight * viewport.height
                             + viewportMin * smaller + viewportMax * larger) / 100
        }
    }
}

extension CSSPropertyParser {
    typealias AlignmentPairs = [(CSSProperty, CSSValue)]

    /// Longhands by name, vendor prefixes and the 2009 and 2012 flexbox drafts included.
    static func alignmentLonghand(_ name: String) -> CSSProperty? {
        switch name {
        case "box-sizing", "-webkit-box-sizing", "-moz-box-sizing": .boxSizing
        case "flex-direction", "-webkit-flex-direction", "-ms-flex-direction", "-webkit-box-orient", "-moz-box-orient": .flexDirection
        case "flex-wrap", "-webkit-flex-wrap", "-ms-flex-wrap": .flexWrap
        case "justify-content", "-webkit-justify-content", "-webkit-box-pack", "-moz-box-pack", "-ms-flex-pack": .justifyContent
        case "align-content", "-webkit-align-content", "-ms-flex-line-pack": .alignContent
        case "align-items", "-webkit-align-items", "-webkit-box-align", "-moz-box-align", "-ms-flex-align": .alignItems
        case "justify-items": .justifyItems
        case "align-self", "-webkit-align-self", "-ms-flex-item-align": .alignSelf
        case "justify-self": .justifySelf
        case "order", "-webkit-order", "-ms-flex-order": .order
        case "flex-grow", "-webkit-flex-grow", "-webkit-box-flex", "-moz-box-flex", "-ms-flex-positive": .flexGrow
        case "row-gap", "grid-row-gap": .rowGap
        case "grid-template-columns": .gridColumns
        case "grid-template-areas": .gridAreas
        case "grid-auto-flow": .gridAutoFlow
        case "grid-row", "grid-column", "grid-area", "grid-row-start", "grid-row-end", "grid-column-start",
             "grid-column-end": .gridPlacement
        default: nil
        }
    }

    /// The longhands an alignment shorthand sets, for global keywords and `@supports`.
    static func alignmentShorthandLonghands(_ name: String) -> [CSSProperty]? {
        switch name {
        case "flex-flow", "-webkit-flex-flow", "-ms-flex-flow": [.flexDirection, .flexWrap]
        case "flex", "-webkit-flex", "-ms-flex": [.flexGrow]
        case "place-content": [.alignContent, .justifyContent]
        case "place-items": [.alignItems, .justifyItems]
        case "place-self": [.alignSelf, .justifySelf]
        case "gap", "grid-gap": [.rowGap]
        case "grid-template", "grid": [.gridColumns, .gridAreas, .gridAutoFlow]
        default: nil
        }
    }

    static func alignmentShorthand(_ name: String, _ c: [CSSComponent]) -> AlignmentPairs? {
        switch name {
        case "flex-flow", "-webkit-flex-flow", "-ms-flex-flow":
            guard (1...2).contains(c.count) else { return nil }
            var direction: ComputedStyle.FlexDirection?, wraps: Bool?
            for component in c {
                guard let keyword = component.ident else { return nil }
                if direction == nil, let value = flexDirection(keyword) { direction = value }
                else if wraps == nil, let value = flexWrap(keyword) { wraps = value }
                else { return nil }
            }
            return [(.flexDirection, .flexDirection(direction ?? .row)), (.flexWrap, .flag(wraps ?? false))]
        case "flex", "-webkit-flex", "-ms-flex":
            return flexGrow(shorthand: c).map { [(.flexGrow, .number($0))] }
        case "place-content": return place(c, .alignContent, .justifyContent)
        case "place-items": return place(c, .alignItems, .justifyItems)
        case "place-self": return place(c, .alignSelf, .justifySelf)
        case "gap", "grid-gap":
            guard (1...2).contains(c.count), c.allSatisfy({ gap($0) != nil }) else { return nil }
            return gap(c[0]).map { [(.rowGap, $0)] }
        case "grid-template", "grid":
            return gridTemplate(c)
        default:
            return nil
        }
    }

    static func alignmentValue(_ property: CSSProperty, _ c: [CSSComponent]) -> CSSValue? {
        let keyword = c.count == 1 ? c[0].ident : nil
        switch property {
        case .boxSizing:
            switch keyword {
            case "border-box": return .flag(true)
            case "content-box": return .flag(false)
            default: return nil
            }
        case .flexDirection: return keyword.flatMap(flexDirection).map(CSSValue.flexDirection)
        case .flexWrap: return keyword.flatMap(flexWrap).map(CSSValue.flag)
        case .justifyContent, .alignContent:
            return alignmentKeyword(c, for: property).flatMap(contentAlignment).map(CSSValue.contentAlignment)
        case .alignItems, .justifyItems:
            // `justify-items: legacy`, alone or with `left`, `right` or `center`, behaves as
            // `normal` without the `<center>`-like inheritance.
            if property == .justifyItems, c.contains(where: { $0.ident == "legacy" }) {
                let others = c.filter { $0.ident != "legacy" }
                guard c.count - others.count == 1, others.count <= 1,
                      others.allSatisfy({ ["left", "right", "center"].contains($0.ident ?? "") }) else { return nil }
                return .itemAlignment(.normal)
            }
            return alignmentKeyword(c, for: property).flatMap { itemAlignment($0, auto: false) }.map(CSSValue.itemAlignment)
        case .alignSelf, .justifySelf:
            return alignmentKeyword(c, for: property).flatMap { itemAlignment($0, auto: true) }.map(CSSValue.itemAlignment)
        case .order:
            guard c.count == 1 else { return nil }
            if let value = calcInteger(c[0]) { return .integer(min(max(value, -1_000_000), 1_000_000)) }
            guard case .token(.number(let value, _, _)) = c[0], value == value.rounded(), abs(value) <= 1_000_000 else { return nil }
            return .integer(Int(value))
        case .flexGrow:
            guard c.count == 1 else { return nil }
            if let value = calcNumber(c[0]) { return .number(min(max(value, 0), 1_000_000)) }
            guard case .token(.number(let value, _, _)) = c[0], value >= 0 else { return nil }
            return .number(min(value, 1_000_000))
        case .rowGap: return c.count == 1 ? gap(c[0]) : nil
        case .gridColumns:
            if c.count == 1, c[0].ident == "none" { return .integer(0) }
            return gridTrackCount(c).map(CSSValue.integer)
        case .gridAreas:
            if c.count == 1, c[0].ident == "none" { return .integer(0) }
            var columns = 0
            for component in c {
                guard case .token(.string(let row)) = component else { return nil }
                columns = max(columns, row.split(whereSeparator: \.isWhitespace).count)
            }
            return .integer(min(columns, maximumGridColumns))
        case .gridAutoFlow:
            let keywords = c.compactMap(\.ident)
            guard keywords.count == c.count, (1...2).contains(keywords.count),
                  keywords.allSatisfy({ ["row", "column", "dense"].contains($0) }) else { return nil }
            return .flag(keywords.contains("column"))
        case .gridPlacement:
            // Any line, span or named area places the item; only `auto` leaves it to the flow.
            return .flag(!c.allSatisfy { $0.ident == "auto" || $0.isDelim("/") })
        default:
            return nil
        }
    }

    private static let maximumGridColumns = 64

    /// The keyword a Box Alignment 3 value comes to (5.1, 6.1 and 6.2): a single keyword, a
    /// position after `safe` or `unsafe` (which only choose what overflowing content does), or a
    /// baseline with `first` or `last` in either order. `left` and `right` are positions along
    /// the inline axis, valid for the `justify-` properties alone, and `justify-content` has no
    /// baseline: for those the value is invalid and an earlier declaration stands. Whether the
    /// keyword is one of the property's own is left to its mapping.
    private static func alignmentKeyword(_ c: [CSSComponent], for property: CSSProperty) -> String? {
        let words = c.compactMap(\.ident)
        guard words.count == c.count else { return nil }
        let keyword: String
        switch words.count {
        case 1:
            keyword = words[0]
        case 2 where Set(words) == ["first", "baseline"] || Set(words) == ["last", "baseline"]:
            keyword = "baseline"
        case 2 where ["safe", "unsafe"].contains(words[0])
            && ["center", "start", "end", "self-start", "self-end", "flex-start", "flex-end", "left", "right"].contains(words[1]):
            keyword = words[1]
        default:
            return nil
        }
        let isInline = property == .justifyContent || property == .justifyItems || property == .justifySelf
        if !isInline, keyword == "left" || keyword == "right" { return nil }
        if property == .justifyContent, keyword == "baseline" { return nil }
        return keyword
    }

    /// `place-content`, `place-items` and `place-self`: the `align-` value, then the `justify-`
    /// one, which is the first again when left out (Box Alignment 3, 5.3, 6.3 and 6.4), or
    /// `start` for a baseline `justify-content` does not take. Either value can be two words,
    /// so each place the second could begin is tried.
    private static func place(_ c: [CSSComponent], _ align: CSSProperty, _ justify: CSSProperty) -> AlignmentPairs? {
        guard (1...4).contains(c.count) else { return nil }
        for split in 1...c.count {
            let first = Array(c[..<split]), rest = Array(c[split...])
            guard let alignValue = alignmentValue(align, first) else { continue }
            let justifyValue = rest.isEmpty
                ? alignmentValue(justify, first) ?? (justify == .justifyContent ? .contentAlignment(.start) : nil)
                : alignmentValue(justify, rest)
            if let justifyValue { return [(align, alignValue), (justify, justifyValue)] }
        }
        return nil
    }

    private static func flexDirection(_ keyword: String) -> ComputedStyle.FlexDirection? {
        switch keyword {
        case "row", "horizontal", "inline-axis": .row
        case "row-reverse": .rowReverse
        case "column", "vertical", "block-axis": .column
        case "column-reverse": .columnReverse
        default: nil
        }
    }

    private static func flexWrap(_ keyword: String) -> Bool? {
        switch keyword {
        case "nowrap": false
        case "wrap", "wrap-reverse": true
        default: nil
        }
    }

    /// With `-webkit-box-pack` and `-ms-flex-pack`'s `justify` and `distribute`.
    private static func contentAlignment(_ keyword: String) -> ComputedStyle.ContentAlignment? {
        switch keyword {
        case "normal": .normal
        case "stretch": .stretch
        case "flex-start": .flexStart
        case "flex-end": .flexEnd
        case "start", "baseline": .start
        case "end": .end
        case "left": .left
        case "right": .right
        case "center": .center
        case "space-between", "justify": .spaceBetween
        case "space-around", "distribute": .spaceAround
        case "space-evenly": .spaceEvenly
        default: nil
        }
    }

    private static func itemAlignment(_ keyword: String, auto: Bool) -> ComputedStyle.ItemAlignment? {
        switch keyword {
        case "auto": auto ? .auto : nil
        case "normal": .normal
        case "stretch": .stretch
        case "flex-start", "start", "self-start": .start
        case "flex-end", "end", "self-end": .end
        case "left": .left
        case "right": .right
        case "center": .center
        case "baseline": .baseline
        default: nil
        }
    }

    private static func gap(_ component: CSSComponent) -> CSSValue? {
        component.ident == "normal" ? .length(.zero) : length(component, percent: true, negative: false, auto: false)
    }

    /// `flex`: `none`, `auto`, or a grow factor optionally followed by a shrink factor and a basis.
    /// A lone basis grows by one, as CSS expands it.
    private static func flexGrow(shorthand c: [CSSComponent]) -> Double? {
        guard (1...3).contains(c.count) else { return nil }
        if c.count == 1, let keyword = c[0].ident {
            switch keyword {
            case "none": return 0
            case "auto": return 1
            default: break
            }
        }
        var numbers: [Double] = [], hasBasis = false
        for component in c {
            if case .token(.number(let value, _, _)) = component, value >= 0, numbers.count < 2 {
                // A third unitless zero is the basis.
                numbers.append(value)
            } else if numbers.count < 2, let value = calcNumber(component) {
                numbers.append(max(value, 0))
            } else if !hasBasis, component.ident.map({ ["auto", "content", "min-content", "max-content", "fit-content"].contains($0) }) == true
                        || length(component, percent: true, negative: false, auto: false) != nil {
                hasBasis = true
            } else {
                return nil
            }
        }
        return min(numbers.first ?? 1, 1_000_000)
    }

    /// Explicit tracks in a track list: every size, `minmax()` and `fit-content()` is one, and
    /// `repeat(n, …)` is n of its own (an automatic repetition counts as several).
    private static func gridTrackCount(_ c: [CSSComponent]) -> Int? {
        guard !c.isEmpty else { return nil }
        var count = 0
        for component in c {
            switch component {
            case .block: continue // Line names.
            case .function(let name, let arguments):
                guard name == "repeat" else { count += 1; continue }
                let parts = arguments.commaSeparated
                guard parts.count == 2, let inner = gridTrackCount(parts[1]) else { return nil }
                if parts[0].count == 1, case .token(.number(let times, _, _)) = parts[0][0], times >= 1 {
                    count += Int(min(times, Double(maximumGridColumns))) * max(inner, 1)
                } else if parts[0].count == 1, let times = calcInteger(parts[0][0]) {
                    count += min(max(times, 1), maximumGridColumns) * max(inner, 1)
                } else if parts[0].count == 1, ["auto-fill", "auto-fit"].contains(parts[0][0].ident ?? "") {
                    count += 2 * max(inner, 1)
                } else {
                    return nil
                }
            case .token(.ident(let word)):
                // `subgrid` and `masonry` take their tracks from elsewhere.
                if ["subgrid", "masonry"].contains(word.lowercased()) { continue }
                count += 1
            case .token(.dimension), .token(.percentage):
                count += 1
            case .token(.number(let value, _, _)) where value == 0:
                count += 1
            default:
                return nil
            }
            if count >= maximumGridColumns { return maximumGridColumns }
        }
        return count
    }

    /// `grid-template` and `grid`, read only for how many columns they make: the track list
    /// after the slash and the widest row of area names.
    private static func gridTemplate(_ c: [CSSComponent]) -> AlignmentPairs? {
        if c.count == 1, c[0].ident == "none" {
            return [(.gridColumns, .integer(0)), (.gridAreas, .integer(0)), (.gridAutoFlow, .flag(false))]
        }
        let parts = c.split(omittingEmptySubsequences: false) { $0.isDelim("/") }.map(Array.init)
        guard (1...2).contains(parts.count) else { return nil }
        var areas = 0
        for component in parts[0] {
            if case .token(.string(let row)) = component { areas = max(areas, row.split(whereSeparator: \.isWhitespace).count) }
        }
        var columns = 0, flowsInColumns = false
        if parts.count == 2 {
            let list = parts[1].filter { component in
                // `grid: <rows> / auto-flow <columns>` flows its items into columns.
                guard component.ident == "auto-flow" || component.ident == "dense" else { return true }
                if component.ident == "auto-flow" { flowsInColumns = true }
                return false
            }
            if !(list.count == 1 && list[0].ident == "none") { columns = list.isEmpty ? 0 : gridTrackCount(list) ?? 2 }
        }
        return [(.gridColumns, .integer(columns)), (.gridAreas, .integer(min(areas, maximumGridColumns))),
                (.gridAutoFlow, .flag(flowsInColumns))]
    }
}

extension ComputedStyle.BoxAlignment {
    /// Copies one property's computed value (`inherit` and `initial`).
    mutating func copy(_ property: CSSProperty, from source: Self) {
        switch property {
        case .boxSizing: isBorderBox = source.isBorderBox
        case .flexDirection: direction = source.direction
        case .flexWrap: wraps = source.wraps
        case .justifyContent: justifyContent = source.justifyContent
        case .alignContent: alignContent = source.alignContent
        case .alignItems: alignItems = source.alignItems
        case .justifyItems: justifyItems = source.justifyItems
        case .alignSelf: alignSelf = source.alignSelf
        case .justifySelf: justifySelf = source.justifySelf
        case .order: order = source.order
        case .flexGrow: grow = source.grow
        case .rowGap: rowGap = source.rowGap
        case .gridColumns: gridColumns = source.gridColumns
        case .gridAreas: gridAreaColumns = source.gridAreaColumns
        case .gridAutoFlow: gridFlowsInColumns = source.gridFlowsInColumns
        case .gridPlacement: hasGridPlacement = source.hasGridPlacement
        case .height: height = source.height
        case .minHeight: minHeight = source.minHeight
        case .maxHeight: maxHeight = source.maxHeight
        default: break
        }
    }

    /// Records a height property's exact value beside its `Length`.
    mutating func setMixed(_ property: CSSProperty, _ value: ComputedStyle.MixedLength?) {
        switch property {
        case .height: height = value
        case .minHeight: minHeight = value
        case .maxHeight: maxHeight = value
        default: break
        }
    }

    /// Applies a specified value; `length` computes a gap.
    mutating func apply(_ property: CSSProperty, _ value: CSSValue, length: (CSSLength) -> ComputedStyle.Length) {
        switch (property, value) {
        case (.boxSizing, .flag(let borderBox)): isBorderBox = borderBox
        case (.flexDirection, .flexDirection(let value)): direction = value
        case (.flexWrap, .flag(let value)): wraps = value
        case (.justifyContent, .contentAlignment(let value)): justifyContent = value
        case (.alignContent, .contentAlignment(let value)): alignContent = value
        case (.alignItems, .itemAlignment(let value)): alignItems = value
        case (.justifyItems, .itemAlignment(let value)): justifyItems = value
        case (.alignSelf, .itemAlignment(let value)): alignSelf = value
        case (.justifySelf, .itemAlignment(let value)): justifySelf = value
        case (.order, .integer(let value)): order = value
        case (.flexGrow, .number(let value)): grow = CGFloat(value)
        case (.rowGap, .length(let value)): rowGap = length(value)
        case (.gridColumns, .integer(let value)): gridColumns = value
        case (.gridAreas, .integer(let value)): gridAreaColumns = value
        case (.gridAutoFlow, .flag(let value)): gridFlowsInColumns = value
        case (.gridPlacement, .flag(let value)): hasGridPlacement = value
        default: break
        }
    }
}
