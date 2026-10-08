import CoreGraphics
import Foundation

/// The longhand properties the cascade tracks: one per `ComputedStyle` field (borders per side).
/// Shorthands expand into these when parsed.
enum CSSProperty: Int, CaseIterable, Sendable {
    // Font properties first: other lengths resolve against the computed font size.
    case fontSize, fontFamily, fontWeight, fontStyle, fontVariantCaps, lineHeight, color
    case display, float, position
    case marginTop, marginRight, marginBottom, marginLeft
    case paddingTop, paddingRight, paddingBottom, paddingLeft
    case borderTopStyle, borderRightStyle, borderBottomStyle, borderLeftStyle
    case borderTopWidth, borderRightWidth, borderBottomWidth, borderLeftWidth
    case borderTopColor, borderRightColor, borderBottomColor, borderLeftColor
    case width, height, minWidth, minHeight, maxWidth, maxHeight
    case backgroundColor, verticalAlign, breakBefore, breakAfter, breakInside
    case textDecorationLine, textDecorationColor
    case textAlign, textIndent, whiteSpace, textTransform, letterSpacing, wordSpacing
    case direction, writingMode, listStyleType, listStylePosition, hyphens, visibility
    case borderCollapse, borderSpacing, captionSide

    static let count = allCases.count

    var isInherited: Bool {
        switch self {
        case .fontSize, .fontFamily, .fontWeight, .fontStyle, .fontVariantCaps, .lineHeight, .color,
             .textAlign, .textIndent, .whiteSpace, .textTransform, .letterSpacing, .wordSpacing,
             .direction, .writingMode, .listStyleType, .listStylePosition, .hyphens, .visibility,
             .borderCollapse, .borderSpacing, .captionSide:
            true
        default: false
        }
    }

    static let margins: [CSSProperty] = [.marginTop, .marginRight, .marginBottom, .marginLeft]
    static let paddings: [CSSProperty] = [.paddingTop, .paddingRight, .paddingBottom, .paddingLeft]
    static let borderStyles: [CSSProperty] = [.borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle]
    static let borderWidths: [CSSProperty] = [.borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth]
    static let borderColors: [CSSProperty] = [.borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor]
}

enum CSSUnit: UInt8, Sendable {
    case number, px, pt, pc, inch, cm, mm, q, em, rem, ex, ch, cap, ic, lh, rlh, percent, vw, vh, vmin, vmax

    init?(_ name: String) {
        switch name.lowercased() {
        case "px": self = .px
        case "pt": self = .pt
        case "pc": self = .pc
        case "in": self = .inch
        case "cm": self = .cm
        case "mm": self = .mm
        case "q": self = .q
        case "em": self = .em
        case "rem": self = .rem
        case "ex", "rex": self = .ex
        case "ch", "rch": self = .ch
        case "cap", "rcap": self = .cap
        case "ic", "ric": self = .ic
        case "lh": self = .lh
        case "rlh": self = .rlh
        case "vw", "svw", "lvw", "dvw", "vi", "svi", "lvi", "dvi", "cqw", "cqi": self = .vw
        case "vh", "svh", "lvh", "dvh", "vb", "svb", "lvb", "dvb", "cqh", "cqb": self = .vh
        case "vmin", "svmin", "lvmin", "dvmin", "cqmin": self = .vmin
        case "vmax", "svmax", "lvmax", "dvmax", "cqmax": self = .vmax
        default: return nil
        }
    }

    /// CSS pixels per unit, for absolute units.
    var pixels: Double? {
        switch self {
        case .px: 1
        case .pt: 4.0 / 3
        case .pc: 16
        case .inch: 96
        case .cm: 96 / 2.54
        case .mm: 96 / 25.4
        case .q: 96 / 101.6
        default: nil
        }
    }
}

/// A `calc()` expression tree.
indirect enum CSSCalc: Equatable, Sendable {
    /// `unit` is `.number` for a plain number.
    case value(Double, CSSUnit)
    case sum([CSSCalc])
    case product(CSSCalc, Double)
    case min([CSSCalc]), max([CSSCalc])
    case clamp(CSSCalc, CSSCalc, CSSCalc)
}

/// A specified length or percentage.
enum CSSLength: Equatable, Sendable {
    case value(Double, CSSUnit)
    case calc(CSSCalc)
    static let zero = CSSLength.value(0, .px)
}

/// A specified color. `system` colors (`CanvasText`, `Canvas`…) mean the reader's palette.
enum CSSColor: Equatable, Sendable {
    case rgba(ComputedStyle.Color)
    case currentColor
    case system
}

enum CSSFontSize: Equatable, Sendable {
    /// A keyword's factor of `medium`.
    case keyword(Double)
    case smaller, larger
    case length(CSSLength)
}

enum CSSFontWeight: Equatable, Sendable { case absolute(Int), bolder, lighter }
enum CSSLineHeight: Equatable, Sendable { case normal, number(Double), length(CSSLength) }

/// A specified value, already validated and typed for its property.
enum CSSValue: Equatable, Sendable {
    case inherit, initial, unset, revert
    case length(CSSLength)
    /// `auto` for lengths, `none` for `max-width`/`max-height`.
    case auto
    /// `blockifies`: a flex or grid container.
    case display(ComputedStyle.Display, blockifies: Bool)
    case float(ComputedStyle.Float)
    /// `font-style: italic`, small caps, `visibility: hidden`, `border-collapse: collapse` and
    /// out-of-flow positioning.
    case flag(Bool)
    case borderStyle(ComputedStyle.BorderStyle)
    case color(CSSColor)
    case verticalAlign(ComputedStyle.VerticalAlign)
    case breakValue(ComputedStyle.Break)
    case decoration(ComputedStyle.Decoration)
    case families([String])
    case fontSize(CSSFontSize)
    case fontWeight(CSSFontWeight)
    case lineHeight(CSSLineHeight)
    case textAlign(ComputedStyle.TextAlign)
    case whiteSpace(ComputedStyle.WhiteSpace)
    case textTransform(ComputedStyle.TextTransform)
    case direction(ComputedStyle.Direction)
    case writingMode(ComputedStyle.WritingMode)
    case listStyleType(ComputedStyle.ListStyleType)
    case listStylePosition(ComputedStyle.ListStylePosition)
    case hyphens(ComputedStyle.Hyphens)
    case spacing(CSSLength, CSSLength)

    var isGlobal: Bool {
        switch self {
        case .inherit, .initial, .unset, .revert: true
        default: false
        }
    }
}

struct CSSDeclaration: Equatable, Sendable {
    let property: CSSProperty
    let value: CSSValue
    let important: Bool
}

/// Validates declarations and expands shorthands into typed longhands. Unknown properties and
/// invalid values yield nil, so the declaration is ignored as CSS requires.
enum CSSPropertyParser {
    static let maximumFamilies = 16

    static func parse(name: String, value: [CSSComponent], important: Bool) -> [CSSDeclaration]? {
        let components = value.significant
        guard !components.isEmpty, !containsVariable(components) else { return nil }
        func all(_ properties: [CSSProperty], _ value: CSSValue) -> [CSSDeclaration] {
            properties.map { CSSDeclaration(property: $0, value: value, important: important) }
        }
        if components.count == 1, let keyword = components[0].ident, let global = globalKeyword(keyword) {
            guard let properties = longhands(of: name) else { return nil }
            return all(properties, global)
        }
        guard let pairs = parseValue(name: name, components) else { return nil }
        return pairs.map { CSSDeclaration(property: $0.0, value: $0.1, important: important) }
    }

    /// Parses a declaration from text (a presentational hint or a `@supports` test).
    static func parse(name: String, text: String) -> [CSSDeclaration]? {
        var truncated = false
        return parse(name: name, value: CSSParser.components(text, truncated: &truncated), important: false)
    }

    private static func containsVariable(_ components: [CSSComponent]) -> Bool {
        components.contains { component in
            switch component {
            case .function(let name, let arguments): name == "var" || name == "env" || name == "attr" || containsVariable(arguments)
            case .block(_, let contents): containsVariable(contents)
            default: false
            }
        }
    }

    private static func globalKeyword(_ keyword: String) -> CSSValue? {
        switch keyword {
        case "inherit": .inherit
        case "initial": .initial
        case "unset": .unset
        case "revert", "revert-layer": .revert
        default: nil
        }
    }

    // MARK: Property names

    private enum Side { case top, right, bottom, left }

    /// Logical sides map to physical ones for horizontal, left-to-right text.
    private static func sides(_ name: String) -> [Side]? {
        switch name {
        case "top", "block-start": [.top]
        case "right", "inline-end": [.right]
        case "bottom", "block-end": [.bottom]
        case "left", "inline-start": [.left]
        case "block": [.top, .bottom]
        case "inline": [.left, .right]
        default: nil
        }
    }

    private static func pick(_ properties: [CSSProperty], _ sides: [Side]) -> [CSSProperty] {
        sides.map { side in
            switch side {
            case .top: properties[0]
            case .right: properties[1]
            case .bottom: properties[2]
            case .left: properties[3]
            }
        }
    }

    /// The longhands a property name sets, for global keywords and `@supports`.
    static func longhands(of name: String) -> [CSSProperty]? {
        if let single = longhand(name) { return [single] }
        switch name {
        case "margin": return CSSProperty.margins
        case "padding": return CSSProperty.paddings
        case "border": return CSSProperty.borderStyles + CSSProperty.borderWidths + CSSProperty.borderColors
        case "border-width": return CSSProperty.borderWidths
        case "border-style": return CSSProperty.borderStyles
        case "border-color": return CSSProperty.borderColors
        case "font": return [.fontStyle, .fontVariantCaps, .fontWeight, .fontSize, .lineHeight, .fontFamily]
        case "list-style": return [.listStyleType, .listStylePosition]
        case "background": return [.backgroundColor]
        case "text-decoration", "-webkit-text-decoration": return [.textDecorationLine, .textDecorationColor]
        case "font-variant": return [.fontVariantCaps]
        case "all": return CSSProperty.allCases.filter { $0 != .direction }
        default: break
        }
        for prefix in ["margin-", "padding-"] where name.hasPrefix(prefix) {
            guard let sides = sides(String(name.dropFirst(prefix.count))) else { return nil }
            return pick(prefix == "margin-" ? CSSProperty.margins : CSSProperty.paddings, sides)
        }
        if name.hasPrefix("border-") {
            let rest = String(name.dropFirst(7))
            if let sides = sides(rest) {
                return pick(CSSProperty.borderStyles, sides) + pick(CSSProperty.borderWidths, sides) + pick(CSSProperty.borderColors, sides)
            }
            for (suffix, properties) in [("-width", CSSProperty.borderWidths), ("-style", CSSProperty.borderStyles),
                                         ("-color", CSSProperty.borderColors)] where rest.hasSuffix(suffix) {
                guard let sides = sides(String(rest.dropLast(suffix.count))) else { return nil }
                return pick(properties, sides)
            }
        }
        return nil
    }

    private static func longhand(_ name: String) -> CSSProperty? {
        switch name {
        case "font-size": .fontSize
        case "font-family": .fontFamily
        case "font-weight": .fontWeight
        case "font-style": .fontStyle
        case "font-variant-caps": .fontVariantCaps
        case "line-height": .lineHeight
        case "color": .color
        case "display": .display
        case "float": .float
        case "position": .position
        case "width", "inline-size": .width
        case "height", "block-size": .height
        case "min-width", "min-inline-size": .minWidth
        case "min-height", "min-block-size": .minHeight
        case "max-width", "max-inline-size": .maxWidth
        case "max-height", "max-block-size": .maxHeight
        case "background-color": .backgroundColor
        case "vertical-align": .verticalAlign
        case "break-before", "page-break-before", "-webkit-column-break-before": .breakBefore
        case "break-after", "page-break-after", "-webkit-column-break-after": .breakAfter
        case "break-inside", "page-break-inside", "-webkit-column-break-inside": .breakInside
        case "text-decoration-line", "-webkit-text-decoration-line": .textDecorationLine
        case "text-decoration-color", "-webkit-text-decoration-color": .textDecorationColor
        case "text-align": .textAlign
        case "text-indent": .textIndent
        case "white-space": .whiteSpace
        case "text-transform": .textTransform
        case "letter-spacing": .letterSpacing
        case "word-spacing": .wordSpacing
        case "direction": .direction
        case "writing-mode", "-epub-writing-mode", "-webkit-writing-mode": .writingMode
        case "list-style-type": .listStyleType
        case "list-style-position": .listStylePosition
        case "hyphens", "-webkit-hyphens", "-epub-hyphens", "-moz-hyphens", "-ms-hyphens", "adobe-hyphenate": .hyphens
        case "visibility": .visibility
        case "border-collapse": .borderCollapse
        case "border-spacing": .borderSpacing
        case "caption-side": .captionSide
        default: nil
        }
    }

    // MARK: Values

    private typealias Pairs = [(CSSProperty, CSSValue)]

    private static func parseValue(name: String, _ c: [CSSComponent]) -> Pairs? {
        if let property = longhand(name) {
            let value: CSSValue?
            switch name {
            case "page-break-before", "page-break-after", "-webkit-column-break-before", "-webkit-column-break-after":
                value = c.count == 1 ? legacyBreak(c[0].ident) : nil
            case "page-break-inside", "-webkit-column-break-inside":
                value = c.count == 1 ? breakInside(c[0].ident) : nil
            case "adobe-hyphenate":
                value = c.count == 1 ? adobeHyphenate(c[0].ident) : nil
            case "font-variant-caps":
                value = c.count == 1 ? c[0].ident.flatMap(smallCaps).map(CSSValue.flag) : nil
            default:
                value = parseLonghand(property, c)
            }
            return value.map { [(property, $0)] }
        }
        switch name {
        case "margin":
            return boxSides(c, CSSProperty.margins) { length($0, percent: true, negative: true, auto: true) }
        case "padding":
            return boxSides(c, CSSProperty.paddings) { length($0, percent: true, negative: false, auto: false) }
        case "border":
            return border(c, sides: [.top, .right, .bottom, .left])
        case "border-width":
            return boxSides(c, CSSProperty.borderWidths, borderWidth)
        case "border-style":
            return boxSides(c, CSSProperty.borderStyles) { $0.ident.flatMap(borderStyle).map(CSSValue.borderStyle) }
        case "border-color":
            return boxSides(c, CSSProperty.borderColors) { color($0).map(CSSValue.color) }
        case "font":
            return font(c)
        case "font-variant":
            return fontVariant(c)
        case "list-style":
            return listStyle(c)
        case "background":
            return background(c)
        case "text-decoration", "-webkit-text-decoration":
            return textDecoration(c)
        case "all":
            return nil // Only global keywords, handled before.
        default:
            break
        }
        for prefix in ["margin-", "padding-"] where name.hasPrefix(prefix) {
            guard let sides = sides(String(name.dropFirst(prefix.count))) else { return nil }
            let isMargin = prefix == "margin-"
            return perSide(c, pick(isMargin ? CSSProperty.margins : CSSProperty.paddings, sides)) {
                length($0, percent: true, negative: isMargin, auto: isMargin)
            }
        }
        if name.hasPrefix("border-") {
            let rest = String(name.dropFirst(7))
            if let sides = sides(rest) { return border(c, sides: sides) }
            for suffix in ["-width", "-style", "-color"] where rest.hasSuffix(suffix) {
                guard let sides = sides(String(rest.dropLast(suffix.count))) else { return nil }
                switch suffix {
                case "-width": return perSide(c, pick(CSSProperty.borderWidths, sides), borderWidth)
                case "-style": return perSide(c, pick(CSSProperty.borderStyles, sides)) { $0.ident.flatMap(borderStyle).map(CSSValue.borderStyle) }
                default: return perSide(c, pick(CSSProperty.borderColors, sides)) { color($0).map(CSSValue.color) }
                }
            }
        }
        return nil
    }

    private static func parseLonghand(_ property: CSSProperty, _ c: [CSSComponent]) -> CSSValue? {
        let single = c.count == 1 ? c[0] : nil
        let keyword = single?.ident
        switch property {
        case .fontSize: return single.flatMap(fontSize).map(CSSValue.fontSize)
        case .fontFamily: return families(c).map(CSSValue.families)
        case .fontWeight: return single.flatMap(fontWeight).map(CSSValue.fontWeight)
        case .fontStyle: return fontStyle(c).map(CSSValue.flag)
        case .fontVariantCaps: return keyword.flatMap(smallCaps).map(CSSValue.flag)
        case .lineHeight: return single.flatMap(lineHeight).map(CSSValue.lineHeight)
        case .color, .backgroundColor, .textDecorationColor,
             .borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor:
            return single.flatMap(color).map(CSSValue.color)
        case .display:
            guard let value = display(c) else { return nil }
            let keywords = Set(c.compactMap(\.ident))
            return .display(value, blockifies: !keywords.isDisjoint(with: Self.flexAndGrid))
        case .float:
            switch keyword {
            case "none": return .float(.none)
            case "left", "inline-start": return .float(.left)
            case "right", "inline-end": return .float(.right)
            default: return nil
            }
        case .position:
            switch keyword {
            case "static", "relative", "sticky", "-webkit-sticky": return .flag(false)
            case "absolute", "fixed": return .flag(true)
            default: return nil
            }
        case .marginTop, .marginRight, .marginBottom, .marginLeft:
            return single.flatMap { length($0, percent: true, negative: true, auto: true) }
        case .paddingTop, .paddingRight, .paddingBottom, .paddingLeft:
            return single.flatMap { length($0, percent: true, negative: false, auto: false) }
        case .borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle:
            return keyword.flatMap(borderStyle).map(CSSValue.borderStyle)
        case .borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth:
            return single.flatMap(borderWidth)
        case .width, .height, .minWidth, .minHeight:
            if let keyword, ["min-content", "max-content", "fit-content", "-webkit-fill-available", "stretch",
                             "-moz-available", "-webkit-min-content", "-webkit-max-content", "-moz-fit-content"].contains(keyword) {
                return .auto
            }
            return single.flatMap { length($0, percent: true, negative: false, auto: true) }
        case .maxWidth, .maxHeight:
            if keyword == "none" { return .auto }
            if let keyword, ["min-content", "max-content", "fit-content", "-webkit-fill-available", "stretch"].contains(keyword) {
                return .auto
            }
            return single.flatMap { length($0, percent: true, negative: false, auto: false) }
        case .verticalAlign:
            switch keyword {
            case "baseline": return .verticalAlign(.baseline)
            case "sub": return .verticalAlign(.sub)
            case "super": return .verticalAlign(.super)
            case "top": return .verticalAlign(.top)
            case "middle": return .verticalAlign(.middle)
            case "bottom": return .verticalAlign(.bottom)
            case "text-top": return .verticalAlign(.textTop)
            case "text-bottom": return .verticalAlign(.textBottom)
            default: return single.flatMap { length($0, percent: true, negative: true, auto: false) }
            }
        case .breakBefore, .breakAfter:
            switch keyword {
            case "auto", "region": return .breakValue(.auto)
            case "avoid", "avoid-page", "avoid-column", "avoid-region": return .breakValue(.avoid)
            case "page", "left", "right", "recto", "verso", "always", "all": return .breakValue(.page)
            case "column": return .breakValue(.column)
            default: return nil
            }
        case .breakInside: return breakInside(keyword)
        case .textDecorationLine: return decorationLine(c).map(CSSValue.decoration)
        case .textAlign:
            switch keyword {
            case "start", "auto", "-webkit-auto", "match-parent": return .textAlign(.start)
            case "end": return .textAlign(.end)
            case "left", "-webkit-left", "-moz-left": return .textAlign(.left)
            case "right", "-webkit-right", "-moz-right": return .textAlign(.right)
            case "center", "-webkit-center", "-moz-center": return .textAlign(.center)
            case "justify", "justify-all": return .textAlign(.justify)
            default: return nil
            }
        case .textIndent:
            let lengths = c.filter { !["hanging", "each-line"].contains($0.ident ?? "") }
            guard lengths.count == 1 else { return nil }
            return length(lengths[0], percent: true, negative: true, auto: false)
        case .whiteSpace: return whiteSpace(c).map(CSSValue.whiteSpace)
        case .textTransform:
            switch keyword {
            case "none", "full-width", "full-size-kana", "math-auto": return .textTransform(.none)
            case "uppercase": return .textTransform(.uppercase)
            case "lowercase": return .textTransform(.lowercase)
            case "capitalize": return .textTransform(.capitalize)
            default: return nil
            }
        case .letterSpacing, .wordSpacing:
            if keyword == "normal" { return .length(.zero) }
            return single.flatMap { length($0, percent: false, negative: true, auto: false) }
        case .direction:
            switch keyword {
            case "ltr": return .direction(.ltr)
            case "rtl": return .direction(.rtl)
            default: return nil
            }
        case .writingMode:
            switch keyword {
            case "horizontal-tb", "lr", "lr-tb", "rl", "rl-tb": return .writingMode(.horizontalTB)
            case "vertical-rl", "tb", "tb-rl", "sideways-rl": return .writingMode(.verticalRL)
            case "vertical-lr", "tb-lr", "sideways-lr": return .writingMode(.verticalLR)
            default: return nil
            }
        case .listStyleType: return single.flatMap(listStyleType).map(CSSValue.listStyleType)
        case .listStylePosition:
            switch keyword {
            case "inside": return .listStylePosition(.inside)
            case "outside": return .listStylePosition(.outside)
            default: return nil
            }
        case .hyphens:
            switch keyword {
            case "none": return .hyphens(.none)
            case "manual": return .hyphens(.manual)
            case "auto": return .hyphens(.auto)
            default: return nil
            }
        case .visibility:
            switch keyword {
            case "visible": return .flag(false)
            case "hidden", "collapse": return .flag(true)
            default: return nil
            }
        case .borderCollapse:
            switch keyword {
            case "collapse": return .flag(true)
            case "separate": return .flag(false)
            default: return nil
            }
        case .captionSide:
            switch keyword {
            case "bottom", "block-end": return .flag(true)
            case "top", "block-start": return .flag(false)
            default: return nil
            }
        case .borderSpacing:
            guard (1...2).contains(c.count) else { return nil }
            let values = c.compactMap { component -> CSSLength? in
                guard case .length(let l)? = length(component, percent: false, negative: false, auto: false) else { return nil }
                return l
            }
            guard values.count == c.count else { return nil }
            return .spacing(values[0], values[values.count - 1])
        }
    }

    private static func legacyBreak(_ keyword: String?) -> CSSValue? {
        switch keyword {
        case "auto": .breakValue(.auto)
        case "always", "left", "right", "recto", "verso": .breakValue(.page)
        case "avoid": .breakValue(.avoid)
        default: nil
        }
    }

    private static func breakInside(_ keyword: String?) -> CSSValue? {
        switch keyword {
        case "auto": .breakValue(.auto)
        case "avoid", "avoid-page", "avoid-column", "avoid-region": .breakValue(.avoid)
        default: nil
        }
    }

    private static func adobeHyphenate(_ keyword: String?) -> CSSValue? {
        switch keyword {
        case "none": .hyphens(.none)
        case "auto": .hyphens(.auto)
        case "explicit": .hyphens(.manual)
        default: nil
        }
    }

    // MARK: Lengths and numbers

    static func length(_ component: CSSComponent, percent: Bool, negative: Bool, auto: Bool) -> CSSValue? {
        switch component {
        case .token(.ident(let value)) where auto && value.lowercased() == "auto": return .auto
        case .token(.number(let value, _, _)) where value == 0: return .length(.zero)
        case .token(.dimension(let value, let unit, _, _)):
            guard let unit = CSSUnit(unit), negative || value >= 0 else { return nil }
            return .length(.value(value, unit))
        case .token(.percentage(let value)):
            guard percent, negative || value >= 0 else { return nil }
            return .length(.value(value, .percent))
        case .function(let name, _) where ["calc", "-webkit-calc", "-moz-calc", "min", "max", "clamp"].contains(name):
            guard let node = calc(component, depth: 0), node.isLength(allowPercent: percent) else { return nil }
            return .length(.calc(node.tree))
        default: return nil
        }
    }

    private static func borderWidth(_ component: CSSComponent) -> CSSValue? {
        switch component.ident {
        case "thin": .length(.value(1, .px))
        case "medium": .length(.value(3, .px))
        case "thick": .length(.value(5, .px))
        default: length(component, percent: false, negative: false, auto: false)
        }
    }

    /// A `calc()` subtree and its type: a number, or a length that may include a percentage.
    private struct CalcNode {
        var tree: CSSCalc
        var hasPercent: Bool
        var isNumber: Bool
        func isLength(allowPercent: Bool) -> Bool { !isNumber && (allowPercent || !hasPercent) }
    }

    private static func calc(_ component: CSSComponent, depth: Int) -> CalcNode? {
        guard depth < 8 else { return nil }
        switch component {
        case .token(.number(let value, _, _)): return CalcNode(tree: .value(value, .number), hasPercent: false, isNumber: true)
        case .token(.dimension(let value, let unit, _, _)):
            guard let unit = CSSUnit(unit) else { return nil }
            return CalcNode(tree: .value(value, unit), hasPercent: false, isNumber: false)
        case .token(.percentage(let value)): return CalcNode(tree: .value(value, .percent), hasPercent: true, isNumber: false)
        case .block(.openParen, let contents): return sum(contents.significant, depth: depth + 1)
        case .function(let name, let arguments):
            switch name {
            case "calc", "-webkit-calc", "-moz-calc": return sum(arguments.significant, depth: depth + 1)
            case "min", "max", "clamp":
                let parts = arguments.commaSeparated
                guard !parts.isEmpty, parts.count <= 16 else { return nil }
                let nodes = parts.map { sum($0, depth: depth + 1) }
                guard nodes.allSatisfy({ $0 != nil }) else { return nil }
                let values = nodes.map { $0! }
                guard Set(values.map(\.isNumber)).count == 1 else { return nil }
                let percent = values.contains { $0.hasPercent }
                let trees = values.map(\.tree)
                switch name {
                case "min": return CalcNode(tree: .min(trees), hasPercent: percent, isNumber: values[0].isNumber)
                case "max": return CalcNode(tree: .max(trees), hasPercent: percent, isNumber: values[0].isNumber)
                default:
                    guard trees.count == 3 else { return nil }
                    return CalcNode(tree: .clamp(trees[0], trees[1], trees[2]), hasPercent: percent, isNumber: values[0].isNumber)
                }
            default: return nil
            }
        default: return nil
        }
    }

    private static func sum(_ components: [CSSComponent], depth: Int) -> CalcNode? {
        guard !components.isEmpty, components.count <= 64 else { return nil }
        var terms: [CalcNode] = []
        var index = 0
        var sign = 1.0
        while index < components.count {
            var end = index
            while end < components.count, !(components[end].isDelim("+") || components[end].isDelim("-")) { end += 1 }
            guard var term = product(Array(components[index..<end]), depth: depth) else { return nil }
            if sign < 0 { term.tree = .product(term.tree, -1) }
            terms.append(term)
            guard end < components.count else { break }
            sign = components[end].isDelim("-") ? -1 : 1
            index = end + 1
            guard index < components.count else { return nil }
        }
        guard Set(terms.map(\.isNumber)).count == 1 else { return nil }
        if terms.count == 1 { return terms[0] }
        return CalcNode(tree: .sum(terms.map(\.tree)), hasPercent: terms.contains { $0.hasPercent }, isNumber: terms[0].isNumber)
    }

    private static func product(_ components: [CSSComponent], depth: Int) -> CalcNode? {
        guard let first = components.first, var result = calc(first, depth: depth) else { return nil }
        var index = 1
        while index < components.count {
            let op = components[index]
            guard op.isDelim("*") || op.isDelim("/"), index + 1 < components.count,
                  let operand = calc(components[index + 1], depth: depth) else { return nil }
            if op.isDelim("/") {
                guard operand.isNumber, case .value(let divisor, .number) = operand.tree, divisor != 0 else { return nil }
                result.tree = .product(result.tree, 1 / divisor)
            } else if operand.isNumber, case .value(let factor, .number) = operand.tree {
                result.tree = .product(result.tree, factor)
            } else if result.isNumber, case .value(let factor, .number) = result.tree {
                result = CalcNode(tree: .product(operand.tree, factor), hasPercent: operand.hasPercent, isNumber: operand.isNumber)
            } else {
                return nil
            }
            index += 2
        }
        return result
    }

    // MARK: Fonts

    private static func fontSize(_ component: CSSComponent) -> CSSFontSize? {
        if let keyword = component.ident {
            switch keyword {
            // WebKit's and Blink's sizes for a 16px `medium` (9, 10, 13, 16, 18, 24, 32, 48px), which
            // books were made against, rather than CSS Fonts' scaling factors.
            case "xx-small": return .keyword(9.0 / 16)
            case "x-small": return .keyword(10.0 / 16)
            case "small": return .keyword(13.0 / 16)
            case "medium": return .keyword(1)
            case "large": return .keyword(18.0 / 16)
            case "x-large": return .keyword(24.0 / 16)
            case "xx-large": return .keyword(2)
            case "xxx-large", "-webkit-xxx-large": return .keyword(3)
            case "smaller": return .smaller
            case "larger": return .larger
            default: return nil
            }
        }
        guard case .length(let length)? = self.length(component, percent: true, negative: false, auto: false) else { return nil }
        return .length(length)
    }

    private static func fontWeight(_ component: CSSComponent) -> CSSFontWeight? {
        switch component {
        case .token(.ident(let value)):
            switch value.lowercased() {
            case "normal": return .absolute(400)
            case "bold": return .absolute(700)
            case "bolder": return .bolder
            case "lighter": return .lighter
            default: return nil
            }
        case .token(.number(let value, _, _)):
            guard value >= 1, value <= 1000 else { return nil }
            return .absolute(Int(value.rounded()))
        default: return nil
        }
    }

    private static func fontStyle(_ c: [CSSComponent]) -> Bool? {
        switch c.first?.ident {
        case "normal" where c.count == 1: false
        case "italic" where c.count == 1: true
        case "oblique" where c.count <= 2: true
        default: nil
        }
    }

    private static func smallCaps(_ keyword: String) -> Bool? {
        switch keyword {
        case "normal", "unicase", "titling-caps": false
        case "small-caps", "all-small-caps", "petite-caps", "all-petite-caps": true
        default: nil
        }
    }

    private static func lineHeight(_ component: CSSComponent) -> CSSLineHeight? {
        if component.ident == "normal" { return .normal }
        if case .token(.number(let value, _, _)) = component { return value >= 0 ? .number(value) : nil }
        if case .function = component, let node = calc(component, depth: 0), node.isNumber {
            if case .value(let value, .number) = node.tree { return .number(value) }
            return nil
        }
        guard case .length(let length)? = self.length(component, percent: true, negative: false, auto: false) else { return nil }
        return .length(length)
    }

    static let genericFamilies: Set<String> = ["serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui",
                                               "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded", "math",
                                               "emoji", "fangsong", "-apple-system", "blinkmacsystemfont"]

    /// Lowercased, unquoted family names.
    static func families(_ c: [CSSComponent]) -> [String]? {
        var result: [String] = []
        for part in c.split(separator: .token(.comma), omittingEmptySubsequences: false) {
            guard let first = part.first else { return nil }
            if part.count == 1, case .token(.string(let value)) = first {
                let name = value.trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty { result.append(String(name.prefix(128))) }
                continue
            }
            var words: [String] = []
            for component in part {
                guard case .token(.ident(let word)) = component else { return nil }
                words.append(word.lowercased())
            }
            if words.count == 1, globalKeyword(words[0]) != nil || words[0] == "default" { return nil }
            result.append(String(words.joined(separator: " ").prefix(128)))
        }
        guard !result.isEmpty else { return nil }
        return Array(result.prefix(maximumFamilies))
    }

    private static func font(_ c: [CSSComponent]) -> Pairs? {
        if c.count == 1, let keyword = c[0].ident,
           ["caption", "icon", "menu", "message-box", "small-caption", "status-bar", "-apple-system-body",
            "-apple-system-headline", "-apple-system-short-body"].contains(keyword) {
            return [(.fontStyle, .flag(false)), (.fontVariantCaps, .flag(false)), (.fontWeight, .fontWeight(.absolute(400))),
                    (.fontSize, .fontSize(.keyword(1))), (.lineHeight, .lineHeight(.normal)), (.fontFamily, .families(["system-ui"]))]
        }
        var italic = false, smallCapsValue = false, weight = CSSFontWeight.absolute(400)
        var index = 0
        var prefixCount = 0
        // Style, variant, weight and stretch, in any order, before the size.
        while index < c.count, prefixCount < 4 {
            let component = c[index]
            if let keyword = component.ident {
                if keyword == "normal" { index += 1; prefixCount += 1; continue }
                if keyword == "italic" || keyword == "oblique" { italic = true; index += 1; prefixCount += 1; continue }
                if keyword == "small-caps" { smallCapsValue = true; index += 1; prefixCount += 1; continue }
                if ["bold", "bolder", "lighter"].contains(keyword), let value = fontWeight(component) {
                    weight = value; index += 1; prefixCount += 1; continue
                }
                if ["ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "semi-expanded", "expanded",
                    "extra-expanded", "ultra-expanded"].contains(keyword) { index += 1; prefixCount += 1; continue }
                break
            }
            if case .token(.number(let value, _, _)) = component, value >= 1, value <= 1000 {
                weight = .absolute(Int(value.rounded())); index += 1; prefixCount += 1; continue
            }
            break
        }
        guard index < c.count, let size = fontSize(c[index]) else { return nil }
        index += 1
        var height = CSSLineHeight.normal
        if index < c.count, c[index].isDelim("/") {
            guard index + 1 < c.count, let value = lineHeight(c[index + 1]) else { return nil }
            height = value
            index += 2
        }
        guard index < c.count, let list = families(Array(c[index...])) else { return nil }
        return [(.fontStyle, .flag(italic)), (.fontVariantCaps, .flag(smallCapsValue)), (.fontWeight, .fontWeight(weight)),
                (.fontSize, .fontSize(size)), (.lineHeight, .lineHeight(height)), (.fontFamily, .families(list))]
    }

    private static let variantKeywords: Set<String> = [
        "common-ligatures", "no-common-ligatures", "discretionary-ligatures", "no-discretionary-ligatures",
        "historical-ligatures", "no-historical-ligatures", "contextual", "no-contextual", "lining-nums",
        "oldstyle-nums", "proportional-nums", "tabular-nums", "diagonal-fractions", "stacked-fractions", "ordinal",
        "slashed-zero", "jis78", "jis83", "jis90", "jis04", "simplified", "traditional", "full-width",
        "proportional-width", "ruby", "sub", "super", "text", "emoji", "unicode", "historical-forms"]

    private static func fontVariant(_ c: [CSSComponent]) -> Pairs? {
        var caps = false
        for component in c {
            guard let keyword = component.ident else {
                if case .function = component { continue } // stylistic(), swash()…
                return nil
            }
            if (keyword == "normal" || keyword == "none") && c.count == 1 { continue }
            if let value = smallCaps(keyword) { caps = value; continue }
            guard variantKeywords.contains(keyword) else { return nil }
        }
        return [(.fontVariantCaps, .flag(caps))]
    }

    // MARK: Other shorthands

    /// One value per side for a single side, or one or two for a pair of logical sides.
    private static func perSide(_ c: [CSSComponent], _ properties: [CSSProperty],
                                _ parse: (CSSComponent) -> CSSValue?) -> Pairs? {
        guard (1...properties.count).contains(c.count) else { return nil }
        let values = c.compactMap(parse)
        guard values.count == c.count else { return nil }
        return properties.enumerated().map { ($0.element, values[min($0.offset, values.count - 1)]) }
    }

    private static func boxSides(_ c: [CSSComponent], _ properties: [CSSProperty],
                                 _ parse: (CSSComponent) -> CSSValue?) -> Pairs? {
        guard (1...4).contains(c.count) else { return nil }
        let values = c.map(parse)
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        let v = values.map { $0! }
        let (top, right, bottom, left): (CSSValue, CSSValue, CSSValue, CSSValue) = switch v.count {
        case 1: (v[0], v[0], v[0], v[0])
        case 2: (v[0], v[1], v[0], v[1])
        case 3: (v[0], v[1], v[2], v[1])
        default: (v[0], v[1], v[2], v[3])
        }
        return [(properties[0], top), (properties[1], right), (properties[2], bottom), (properties[3], left)]
    }

    private static func border(_ c: [CSSComponent], sides: [Side]) -> Pairs? {
        guard (1...3).contains(c.count) else { return nil }
        var width: CSSValue?, style: CSSValue?, colorValue: CSSValue?
        for component in c {
            if style == nil, let keyword = component.ident, let value = borderStyle(keyword) { style = .borderStyle(value) }
            else if width == nil, let value = borderWidth(component) { width = value }
            else if colorValue == nil, let value = color(component) { colorValue = .color(value) }
            else { return nil }
        }
        let resolvedWidth = width ?? .length(.value(3, .px))
        let resolvedStyle = style ?? .borderStyle(.none)
        let resolvedColor = colorValue ?? .color(.currentColor)
        return pick(CSSProperty.borderWidths, sides).map { ($0, resolvedWidth) }
            + pick(CSSProperty.borderStyles, sides).map { ($0, resolvedStyle) }
            + pick(CSSProperty.borderColors, sides).map { ($0, resolvedColor) }
    }

    private static func borderStyle(_ keyword: String) -> ComputedStyle.BorderStyle? {
        switch keyword {
        case "none": ComputedStyle.BorderStyle.none
        case "hidden": .hidden
        case "solid": .solid
        case "dotted": .dotted
        case "dashed": .dashed
        case "double": .double
        case "groove": .groove
        case "ridge": .ridge
        case "inset": .inset
        case "outset": .outset
        default: nil
        }
    }

    private static func listStyle(_ c: [CSSComponent]) -> Pairs? {
        guard (1...3).contains(c.count) else { return nil }
        var type: ComputedStyle.ListStyleType?, position: ComputedStyle.ListStylePosition?
        var image = false, nones = 0
        for component in c {
            switch component.ident {
            case "none": nones += 1
            case "inside" where position == nil: position = .inside
            case "outside" where position == nil: position = .outside
            default:
                if case .token(.url) = component, !image { image = true; continue }
                if case .function(let name, _) = component, !image, name.hasSuffix("gradient") || name == "url" || name == "image" {
                    image = true; continue
                }
                guard type == nil, let value = listStyleType(component) else { return nil }
                type = value
            }
        }
        // `none` sets whichever of type and image is otherwise unset.
        if nones > 0 {
            guard nones <= (type == nil ? 1 : 0) + (image ? 0 : 1) else { return nil }
            if type == nil { type = ComputedStyle.ListStyleType.none }
        }
        return [(.listStyleType, .listStyleType(type ?? .disc)), (.listStylePosition, .listStylePosition(position ?? .outside))]
    }

    private static func listStyleType(_ component: CSSComponent) -> ComputedStyle.ListStyleType? {
        if case .token(.string(let value)) = component { return .string(value) }
        guard let keyword = component.ident else { return nil }
        switch keyword {
        case "none": return ComputedStyle.ListStyleType.none
        case "disc": return .disc
        case "circle": return .circle
        case "square": return .square
        case "decimal": return .decimal
        case "decimal-leading-zero": return .decimalLeadingZero
        case "lower-alpha", "lower-latin": return .lowerAlpha
        case "upper-alpha", "upper-latin": return .upperAlpha
        case "lower-roman": return .lowerRoman
        case "upper-roman": return .upperRoman
        case "lower-greek": return .lowerGreek
        case "inherit", "initial", "unset", "default", "revert": return nil
        // Unknown counter styles fall back to decimal (CSS Counter Styles §3.1).
        default: return .decimal
        }
    }

    /// Only the color of the final layer is honoured; images, positions and the rest are ignored.
    private static func background(_ c: [CSSComponent]) -> Pairs? {
        let layers = c.split(separator: .token(.comma), omittingEmptySubsequences: false)
        guard let last = layers.last else { return nil }
        var found: CSSColor?
        for component in last {
            if let value = color(component) {
                guard found == nil else { return nil }
                found = value
            }
        }
        return [(.backgroundColor, .color(found ?? .rgba(ComputedStyle.Color(red: 0, green: 0, blue: 0, alpha: 0))))]
    }

    private static func decorationLine(_ c: [CSSComponent]) -> ComputedStyle.Decoration? {
        var result: ComputedStyle.Decoration = []
        for component in c {
            switch component.ident {
            case "none" where c.count == 1: return []
            case "underline": result.insert(.underline)
            case "overline": result.insert(.overline)
            case "line-through": result.insert(.lineThrough)
            case "blink", "spelling-error", "grammar-error": continue
            default: return nil
            }
        }
        return result
    }

    private static func textDecoration(_ c: [CSSComponent]) -> Pairs? {
        var lines: ComputedStyle.Decoration?
        var colorValue: CSSColor?
        var styleSeen = false, thicknessSeen = false
        var lineComponents: [CSSComponent] = []
        for component in c {
            if let keyword = component.ident {
                if ["none", "underline", "overline", "line-through", "blink"].contains(keyword) { lineComponents.append(component); continue }
                if !styleSeen, ["solid", "double", "dotted", "dashed", "wavy"].contains(keyword) { styleSeen = true; continue }
                if !thicknessSeen, keyword == "auto" || keyword == "from-font" { thicknessSeen = true; continue }
            }
            if colorValue == nil, let value = color(component) { colorValue = value; continue }
            if !thicknessSeen, length(component, percent: true, negative: false, auto: false) != nil { thicknessSeen = true; continue }
            return nil
        }
        if !lineComponents.isEmpty {
            guard let value = decorationLine(lineComponents) else { return nil }
            lines = value
        }
        return [(.textDecorationLine, .decoration(lines ?? [])), (.textDecorationColor, .color(colorValue ?? .currentColor))]
    }

    private static let flexAndGrid: Set<String> = ["flex", "grid", "inline-flex", "inline-grid", "-webkit-box", "-webkit-flex",
                                                   "-ms-flexbox", "-moz-box", "-ms-grid", "-webkit-inline-box",
                                                   "-webkit-inline-flex", "-ms-inline-flexbox", "-moz-inline-box", "masonry"]

    private static func display(_ c: [CSSComponent]) -> ComputedStyle.Display? {
        let keywords = c.compactMap(\.ident)
        guard keywords.count == c.count, (1...3).contains(keywords.count) else { return nil }
        if keywords.count > 1 {
            let set = Set(keywords)
            if set.contains("list-item") { return .listItem }
            if set.contains("inline") { return set.contains("flow-root") || set.contains("flex") || set.contains("grid") ? .inlineBlock : .inline }
            if set.contains("block") { return set.contains("ruby") ? .ruby : .block }
            if set.contains("table") { return .table }
            return nil
        }
        switch keywords[0] {
        case "none": return ComputedStyle.Display.none
        case "inline", "contents", "ruby-base", "ruby-base-container", "ruby-text-container", "-webkit-inline": return .inline
        case "block", "flow-root", "flex", "grid", "-webkit-box", "-webkit-flex", "-ms-flexbox", "-moz-box", "-ms-grid",
             "run-in", "flow", "masonry": return .block
        case "list-item": return .listItem
        case "inline-block", "inline-flex", "inline-grid", "-webkit-inline-box", "-webkit-inline-flex",
             "-ms-inline-flexbox", "-moz-inline-box", "-moz-inline-stack", "inline-list-item": return .inlineBlock
        case "table", "inline-table": return .table
        case "table-row-group": return .tableRowGroup
        case "table-header-group": return .tableHeaderGroup
        case "table-footer-group": return .tableFooterGroup
        case "table-row": return .tableRow
        case "table-cell": return .tableCell
        case "table-caption": return .tableCaption
        case "table-column": return .tableColumn
        case "table-column-group": return .tableColumnGroup
        case "ruby": return .ruby
        case "ruby-text": return .rubyText
        default: return nil
        }
    }

    private static func whiteSpace(_ c: [CSSComponent]) -> ComputedStyle.WhiteSpace? {
        let keywords = c.compactMap(\.ident)
        guard keywords.count == c.count else { return nil }
        switch keywords.joined(separator: " ") {
        case "normal", "collapse", "collapse wrap", "wrap": return .normal
        case "nowrap", "collapse nowrap", "nowrap collapse", "-webkit-nowrap": return .nowrap
        case "pre", "preserve nowrap", "nowrap preserve": return .pre
        case "pre-wrap", "-moz-pre-wrap", "-o-pre-wrap", "-pre-wrap", "preserve", "preserve wrap": return .preWrap
        case "pre-line", "preserve-breaks", "preserve-breaks wrap": return .preLine
        case "break-spaces", "preserve-spaces": return .breakSpaces
        default: return nil
        }
    }

    // MARK: Colors

    static func color(_ component: CSSComponent) -> CSSColor? {
        switch component {
        case .token(.hash(let value, _)):
            return hexColor(value).map(CSSColor.rgba)
        case .token(.ident(let value)):
            let name = value.lowercased()
            if name == "currentcolor" { return .currentColor }
            if name == "transparent" { return .rgba(ComputedStyle.Color(red: 0, green: 0, blue: 0, alpha: 0)) }
            if systemColors.contains(name) { return .system }
            guard let hex = namedColors[name] else { return nil }
            return .rgba(rgb(hex))
        case .function(let name, let arguments):
            switch name {
            case "rgb", "rgba": return rgbFunction(arguments).map(CSSColor.rgba)
            case "hsl", "hsla": return hslFunction(arguments).map(CSSColor.rgba)
            case "hwb": return hwbFunction(arguments).map(CSSColor.rgba)
            default: return nil
            }
        default: return nil
        }
    }

    /// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, and HTML's legacy bare hex in presentational attributes.
    static func hexColor(_ value: String) -> ComputedStyle.Color? {
        let digits = value.unicodeScalars.compactMap(CSSTokenizer.hexValue)
        guard digits.count == value.unicodeScalars.count else { return nil }
        func channel(_ high: UInt32, _ low: UInt32) -> CGFloat { CGFloat(high * 16 + low) / 255 }
        switch digits.count {
        case 3, 4:
            return ComputedStyle.Color(red: channel(digits[0], digits[0]), green: channel(digits[1], digits[1]),
                                       blue: channel(digits[2], digits[2]), alpha: digits.count == 4 ? channel(digits[3], digits[3]) : 1)
        case 6, 8:
            return ComputedStyle.Color(red: channel(digits[0], digits[1]), green: channel(digits[2], digits[3]),
                                       blue: channel(digits[4], digits[5]), alpha: digits.count == 8 ? channel(digits[6], digits[7]) : 1)
        default: return nil
        }
    }

    private static func rgb(_ hex: UInt32) -> ComputedStyle.Color {
        ComputedStyle.Color(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255)
    }

    /// Color function arguments, legacy comma or modern space syntax, with an optional alpha.
    private static func colorArguments(_ arguments: [CSSComponent]) -> (channels: [CSSComponent], alpha: CSSComponent?)? {
        let significant = arguments.significant
        if significant.contains(.token(.comma)) {
            let parts = arguments.commaSeparated
            guard parts.allSatisfy({ $0.count == 1 }), parts.count == 3 || parts.count == 4 else { return nil }
            return (parts.prefix(3).map { $0[0] }, parts.count == 4 ? parts[3][0] : nil)
        }
        if let slash = significant.firstIndex(where: { $0.isDelim("/") }) {
            guard slash == 3, significant.count == 5 else { return nil }
            return (Array(significant[0..<3]), significant[4])
        }
        guard significant.count == 3 else { return nil }
        return (significant, nil)
    }

    private static func alphaValue(_ component: CSSComponent?) -> CGFloat? {
        guard let component else { return 1 }
        switch component {
        case .token(.number(let value, _, _)): return CGFloat(min(max(value, 0), 1))
        case .token(.percentage(let value)): return CGFloat(min(max(value / 100, 0), 1))
        case .token(.ident("none")): return 0
        default: return nil
        }
    }

    private static func rgbFunction(_ arguments: [CSSComponent]) -> ComputedStyle.Color? {
        guard let (channels, alphaComponent) = colorArguments(arguments), let alpha = alphaValue(alphaComponent) else { return nil }
        var values: [CGFloat] = []
        for channel in channels {
            switch channel {
            case .token(.number(let value, _, _)): values.append(CGFloat(min(max(value, 0), 255) / 255))
            case .token(.percentage(let value)): values.append(CGFloat(min(max(value, 0), 100) / 100))
            case .token(.ident(let value)) where value.lowercased() == "none": values.append(0)
            default: return nil
            }
        }
        return ComputedStyle.Color(red: values[0], green: values[1], blue: values[2], alpha: alpha)
    }

    private static func hue(_ component: CSSComponent) -> Double? {
        switch component {
        case .token(.number(let value, _, _)): return value
        case .token(.dimension(let value, let unit, _, _)):
            switch unit.lowercased() {
            case "deg": return value
            case "rad": return value * 180 / .pi
            case "grad": return value * 0.9
            case "turn": return value * 360
            default: return nil
            }
        case .token(.ident(let value)) where value.lowercased() == "none": return 0
        default: return nil
        }
    }

    private static func fraction(_ component: CSSComponent) -> Double? {
        switch component {
        case .token(.percentage(let value)): min(max(value / 100, 0), 1)
        case .token(.number(let value, _, _)): min(max(value / 100, 0), 1)
        case .token(.ident(let value)) where value.lowercased() == "none": 0
        default: nil
        }
    }

    private static func hslFunction(_ arguments: [CSSComponent]) -> ComputedStyle.Color? {
        guard let (channels, alphaComponent) = colorArguments(arguments), let alpha = alphaValue(alphaComponent),
              let h = hue(channels[0]), let s = fraction(channels[1]), let l = fraction(channels[2]) else { return nil }
        let (r, g, b) = hslToRGB(h, s, l)
        return ComputedStyle.Color(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func hslToRGB(_ hue: Double, _ s: Double, _ l: Double) -> (CGFloat, CGFloat, CGFloat) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        func f(_ n: Double) -> CGFloat {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            let a = s * min(l, 1 - l)
            return CGFloat(l - a * max(-1, min(k - 3, 9 - k, 1)))
        }
        return (f(0), f(8), f(4))
    }

    private static func hwbFunction(_ arguments: [CSSComponent]) -> ComputedStyle.Color? {
        guard let (channels, alphaComponent) = colorArguments(arguments), let alpha = alphaValue(alphaComponent),
              let h = hue(channels[0]), let white = fraction(channels[1]), let black = fraction(channels[2]) else { return nil }
        if white + black >= 1 {
            let gray = white / (white + black)
            return ComputedStyle.Color(red: gray, green: gray, blue: gray, alpha: alpha)
        }
        let (r, g, b) = hslToRGB(h, 1, 0.5)
        let scale = 1 - white - black
        return ComputedStyle.Color(red: r * scale + white, green: g * scale + white, blue: b * scale + white, alpha: alpha)
    }

    private static let systemColors: Set<String> = [
        "canvas", "canvastext", "linktext", "visitedtext", "activetext", "buttonface", "buttontext", "buttonborder",
        "field", "fieldtext", "highlight", "highlighttext", "selecteditem", "selecteditemtext", "mark", "marktext",
        "graytext", "accentcolor", "accentcolortext", "windowtext", "window", "-webkit-link", "-webkit-text",
        "-apple-system-label"]

    static let namedColors: [String: UInt32] = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4, "azure": 0xF0FFFF,
        "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000, "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF,
        "blueviolet": 0x8A2BE2, "brown": 0xA52A2A, "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00,
        "chocolate": 0xD2691E, "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
        "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B, "darkgray": 0xA9A9A9,
        "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B, "darkmagenta": 0x8B008B,
        "darkolivegreen": 0x556B2F, "darkorange": 0xFF8C00, "darkorchid": 0x9932CC, "darkred": 0x8B0000,
        "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F, "darkslateblue": 0x483D8B, "darkslategray": 0x2F4F4F,
        "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3, "deeppink": 0xFF1493,
        "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969, "dodgerblue": 0x1E90FF,
        "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22, "fuchsia": 0xFF00FF,
        "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF, "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080,
        "green": 0x008000, "greenyellow": 0xADFF2F, "grey": 0x808080, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4,
        "indianred": 0xCD5C5C, "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA,
        "lavenderblush": 0xFFF0F5, "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6,
        "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3,
        "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A,
        "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
        "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32,
        "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA,
        "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3, "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371,
        "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC,
        "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1,
        "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6, "olive": 0x808000,
        "olivedrab": 0x6B8E23, "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6,
        "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE, "palevioletred": 0xDB7093,
        "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F, "pink": 0xFFC0CB, "plum": 0xDDA0DD,
        "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xFF0000,
        "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1, "saddlebrown": 0x8B4513, "salmon": 0xFA8072,
        "sandybrown": 0xF4A460, "seagreen": 0x2E8B57, "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0,
        "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA,
        "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8,
        "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3, "white": 0xFFFFFF,
        "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00, "yellowgreen": 0x9ACD32,
    ]
}
