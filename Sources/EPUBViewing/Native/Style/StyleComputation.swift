import CoreGraphics
import Foundation

/// Bounds that keep a hostile book from breaking layout.
enum StyleLimits {
    static let fontSize: ClosedRange<CGFloat> = 4...400
    /// Margins, text indents and vertical offsets, in points.
    static let offset: ClosedRange<CGFloat> = -1000...1000
    /// Widths, heights and paddings, in points.
    static let extent: ClosedRange<CGFloat> = 0...10_000
    static let borderWidth: ClosedRange<CGFloat> = 0...64
    static let borderSpacing: ClosedRange<CGFloat> = 0...100
    static let lineHeightMultiple: ClosedRange<CGFloat> = 0...10
    /// Percentages and viewport units.
    static let percent: ClosedRange<CGFloat> = -100...100
    /// Lengths that mix symbolic and absolute parts are approximated against this containing
    /// block (the nominal viewport the media queries use).
    static let nominalViewport = CGSize(width: 600, height: 800)
}

extension StyleResolver {
    /// Resolves lengths: `em` against `em`, `rem` against the root's size, absolute units scaled
    /// by `scale`, and percentages against `percentBase` when given (else kept symbolic).
    struct LengthContext {
        var em: CGFloat
        var rem: CGFloat
        var scale: CGFloat = 1
        var percentBase: CGFloat?
        /// Font sizes resolve viewport units to points.
        var resolvesViewport = false
    }

    private struct Linear {
        var points: Double = 0, percent: Double = 0, vw: Double = 0, vh: Double = 0
        static func + (a: Linear, b: Linear) -> Linear {
            Linear(points: a.points + b.points, percent: a.percent + b.percent, vw: a.vw + b.vw, vh: a.vh + b.vh)
        }
        static func * (a: Linear, f: Double) -> Linear {
            Linear(points: a.points * f, percent: a.percent * f, vw: a.vw * f, vh: a.vh * f)
        }
        var approximation: Double {
            points + (percent + vw) * Double(StyleLimits.nominalViewport.width) / 100 + vh * Double(StyleLimits.nominalViewport.height) / 100
        }
    }

    private func linear(_ calc: CSSCalc, _ context: LengthContext) -> Linear {
        switch calc {
        case .value(let value, let unit): return linear(value, unit, context)
        case .sum(let terms): return terms.reduce(Linear()) { $0 + linear($1, context) }
        case .product(let node, let factor): return linear(node, context) * factor
        case .min(let nodes): return nodes.map { linear($0, context) }.min { $0.approximation < $1.approximation } ?? Linear()
        case .max(let nodes): return nodes.map { linear($0, context) }.max { $0.approximation < $1.approximation } ?? Linear()
        case .clamp(let low, let value, let high):
            let (l, v, h) = (linear(low, context), linear(value, context), linear(high, context))
            let upper = v.approximation < h.approximation ? v : h
            return l.approximation > upper.approximation ? l : upper
        }
    }

    private func linear(_ value: Double, _ unit: CSSUnit, _ context: LengthContext) -> Linear {
        let em = Double(context.em), rem = Double(context.rem)
        var result = Linear()
        switch unit {
        case .number: result.points = value
        case .em, .ic: result.points = value * em
        case .ex, .ch: result.points = value * em / 2
        case .cap: result.points = value * em * 0.7
        case .lh: result.points = value * em * 1.2
        case .rem: result.points = value * rem
        case .rlh: result.points = value * rem * 1.2
        case .percent:
            if let base = context.percentBase { result.points = value * Double(base) / 100 } else { result.percent = value }
        case .vw, .vmin: result.vw = value
        case .vh, .vmax: result.vh = value
        case .px, .pt, .pc, .inch, .cm, .mm, .q: result.points = value * unit.pixels! * Double(context.scale)
        }
        if context.resolvesViewport {
            result.points += (result.vw * Double(StyleLimits.nominalViewport.width) + result.vh * Double(StyleLimits.nominalViewport.height))
                / 100 * Double(context.scale)
            result.vw = 0; result.vh = 0
        }
        return result
    }

    private func linear(_ length: CSSLength, _ context: LengthContext) -> Linear {
        switch length {
        case .value(let value, let unit): linear(value, unit, context)
        case .calc(let node): linear(node, context)
        }
    }

    /// Points, approximating any symbolic part against the nominal viewport.
    func points(_ length: CSSLength, _ context: LengthContext) -> CGFloat {
        let value = linear(length, context).approximation
        return value.isFinite ? CGFloat(value) : 0
    }

    /// A computed length, symbolic where its reference box is only known at layout.
    func computed(_ length: CSSLength, _ context: LengthContext, points range: ClosedRange<CGFloat>) -> ComputedStyle.Length {
        let value = linear(length, context)
        func clamp(_ x: Double, _ range: ClosedRange<CGFloat>) -> CGFloat { x.isFinite ? min(max(CGFloat(x), range.lowerBound), range.upperBound) : 0 }
        let width = Double(StyleLimits.nominalViewport.width) / 100, height = Double(StyleLimits.nominalViewport.height) / 100
        let percentRange = max(StyleLimits.percent.lowerBound, range.lowerBound)...StyleLimits.percent.upperBound
        switch (value.percent != 0, value.vw != 0, value.vh != 0) {
        case (false, false, false): return .points(clamp(value.points, range))
        case (true, false, false): return .percent(clamp(value.percent + value.points / width, percentRange))
        case (false, true, false): return .viewportWidth(clamp(value.vw + value.points / width, percentRange))
        case (false, false, true): return .viewportHeight(clamp(value.vh + value.points / height, percentRange))
        default: return .percent(clamp(value.approximation / width, percentRange))
        }
    }

    private func color(_ value: CSSColor, current: ComputedStyle.Color?) -> ComputedStyle.Color? {
        switch value {
        case .rgba(let color): color
        case .currentColor: current
        case .system: nil
        }
    }

    // MARK: Cascade to computed values

    func compute(winners: [CSSValue?], userAgent: [CSSValue?], parent: ComputedStyle, rem: CGFloat, isRoot: Bool) -> ComputedStyle {
        var style = ComputedStyle()
        // Inherited properties.
        style.fontFamilies = parent.fontFamilies; style.fontSize = parent.fontSize
        style.fontWeight = parent.fontWeight; style.isItalic = parent.isItalic
        style.isSmallCaps = parent.isSmallCaps; style.lineHeight = parent.lineHeight
        style.color = parent.color; style.textAlign = parent.textAlign; style.textIndent = parent.textIndent
        style.whiteSpace = parent.whiteSpace; style.textTransform = parent.textTransform
        style.letterSpacing = parent.letterSpacing; style.wordSpacing = parent.wordSpacing
        style.direction = parent.direction; style.writingMode = parent.writingMode
        style.listStyleType = parent.listStyleType; style.listStylePosition = parent.listStylePosition
        style.hyphens = parent.hyphens; style.isHidden = parent.isHidden
        style.borderCollapse = parent.borderCollapse; style.borderSpacing = parent.borderSpacing
        style.captionSide = parent.captionSide
        // `medium`, zeroed below unless a border style shows it.
        for side in Side.allCases { style[border: side].width = 3 }

        var ownDecoration: ComputedStyle.Decoration = []
        var decorationColor: CSSColor?

        for property in CSSProperty.allCases {
            guard var value = winners[property.rawValue] else { continue }
            if value == .revert { value = userAgent[property.rawValue] ?? .unset }
            if value == .revert || value == .unset { value = property.isInherited ? .inherit : .initial }
            switch property {
            case .textDecorationLine:
                switch value {
                case .decoration(let lines): ownDecoration = lines
                case .inherit: ownDecoration = parent.textDecoration
                default: ownDecoration = []
                }
                continue
            case .textDecorationColor:
                if case .color(let specified) = value { decorationColor = specified }
                continue
            default: break
            }
            switch value {
            case .inherit: copy(property, from: parent, to: &style)
            case .initial: copy(property, from: initialValues, to: &style, initial: true)
            default: apply(property, value, to: &style, parent: parent, rem: rem)
            }
        }

        if isRoot, !style.display.isBlockLevel, style.display != .none { style.display = .block }
        // Flex and grid items are blockified (CSS Display §2.7). Floats and out-of-flow boxes are
        // not: `float` and `isOutOfFlow` carry them, so the builder can keep a drop cap inline.
        if parent.blockifiesChildren, !style.isOutOfFlow {
            switch style.display {
            case .inline, .inlineBlock, .ruby, .rubyText, .tableRow, .tableCell, .tableRowGroup, .tableHeaderGroup,
                 .tableFooterGroup, .tableCaption, .tableColumn, .tableColumnGroup:
                style.display = .block
            case .block, .listItem, .table, .none:
                break
            }
        }
        for side in Side.allCases where !style[border: side].isVisible { style[border: side].width = 0 }

        // Decorations propagate to in-flow descendants, but not into atomic inlines or out-of-flow boxes.
        let propagates = style.display != .inlineBlock && style.float == .none && !style.isOutOfFlow
        let inherited: ComputedStyle.Decoration = propagates ? parent.textDecoration : []
        style.textDecoration = inherited.union(ownDecoration)
        if !ownDecoration.isEmpty {
            style.textDecorationColor = color(decorationColor ?? .currentColor, current: style.color)
        } else {
            style.textDecorationColor = inherited.isEmpty ? nil : parent.textDecorationColor
        }

        if typography.isDark {
            // The reader's palette applies; fully transparent text stays invisible.
            if style.color?.alpha != 0 { style.color = nil }
            style.backgroundColor = nil
            style.textDecorationColor = nil
            for side in Side.allCases { style[border: side].color = nil }
        } else if style.backgroundColor?.alpha == 0 {
            style.backgroundColor = nil
        }
        return style
    }

    private func copy(_ property: CSSProperty, from source: ComputedStyle, to style: inout ComputedStyle, initial: Bool = false) {
        switch property {
        case .fontSize: style.fontSize = source.fontSize
        case .fontFamily: style.fontFamilies = source.fontFamilies
        case .fontWeight: style.fontWeight = source.fontWeight
        case .fontStyle: style.isItalic = source.isItalic
        case .fontVariantCaps: style.isSmallCaps = source.isSmallCaps
        case .lineHeight: style.lineHeight = source.lineHeight
        case .color: style.color = source.color
        case .display: style.display = source.display; style.blockifiesChildren = source.blockifiesChildren
        case .float: style.float = source.float
        case .position: style.isOutOfFlow = source.isOutOfFlow
        case .marginTop: style.margin.top = source.margin.top
        case .marginRight: style.margin.right = source.margin.right
        case .marginBottom: style.margin.bottom = source.margin.bottom
        case .marginLeft: style.margin.left = source.margin.left
        case .paddingTop: style.padding.top = source.padding.top
        case .paddingRight: style.padding.right = source.padding.right
        case .paddingBottom: style.padding.bottom = source.padding.bottom
        case .paddingLeft: style.padding.left = source.padding.left
        case .borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle:
            let side = Side(property)
            style[border: side].style = source[border: side].style
        case .borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth:
            let side = Side(property)
            // The initial width is `medium`.
            style[border: side].width = initial ? 3 : source[border: side].width
        case .borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor:
            let side = Side(property)
            style[border: side].color = source[border: side].color
        case .width: style.width = source.width
        case .height: style.height = source.height
        case .minWidth: style.minWidth = source.minWidth
        case .minHeight: style.minHeight = source.minHeight
        case .maxWidth: style.maxWidth = source.maxWidth
        case .maxHeight: style.maxHeight = source.maxHeight
        case .backgroundColor: style.backgroundColor = source.backgroundColor
        case .verticalAlign: style.verticalAlign = source.verticalAlign
        case .breakBefore: style.breakBefore = source.breakBefore
        case .breakAfter: style.breakAfter = source.breakAfter
        case .breakInside: style.breakInside = source.breakInside
        case .textDecorationLine, .textDecorationColor: break // Handled with propagation.
        case .textAlign: style.textAlign = source.textAlign
        case .textIndent: style.textIndent = source.textIndent
        case .whiteSpace: style.whiteSpace = source.whiteSpace
        case .textTransform: style.textTransform = source.textTransform
        case .letterSpacing: style.letterSpacing = source.letterSpacing
        case .wordSpacing: style.wordSpacing = source.wordSpacing
        case .direction: style.direction = source.direction
        case .writingMode: style.writingMode = source.writingMode
        case .listStyleType: style.listStyleType = source.listStyleType
        case .listStylePosition: style.listStylePosition = source.listStylePosition
        case .hyphens: style.hyphens = source.hyphens
        case .visibility: style.isHidden = source.isHidden
        case .borderCollapse: style.borderCollapse = source.borderCollapse
        case .borderSpacing: style.borderSpacing = source.borderSpacing
        case .captionSide: style.captionSide = source.captionSide
        }
    }

    private func apply(_ property: CSSProperty, _ value: CSSValue, to style: inout ComputedStyle,
                       parent: ComputedStyle, rem: CGFloat) {
        let own = LengthContext(em: style.fontSize, rem: rem)
        switch (property, value) {
        case (.fontSize, .fontSize(let size)):
            style.fontSize = fontSize(size, parent: parent.fontSize, rem: rem)
        case (.fontFamily, .families(let families)):
            style.fontFamilies = families
        case (.fontWeight, .fontWeight(let weight)):
            style.fontWeight = switch weight {
            case .absolute(let value): min(max(value, 100), 900)
            case .bolder: parent.fontWeight < 350 ? 400 : parent.fontWeight < 550 ? 700 : 900
            case .lighter: parent.fontWeight < 100 ? parent.fontWeight : parent.fontWeight < 550 ? 100 : parent.fontWeight < 750 ? 400 : 700
            }
        case (.fontStyle, .flag(let italic)): style.isItalic = italic
        case (.fontVariantCaps, .flag(let smallCaps)): style.isSmallCaps = smallCaps
        case (.lineHeight, .lineHeight(let height)):
            switch height {
            case .normal: style.lineHeight = .normal
            case .number(let multiple):
                style.lineHeight = .multiple(min(max(CGFloat(multiple), StyleLimits.lineHeightMultiple.lowerBound), StyleLimits.lineHeightMultiple.upperBound))
            case .length(let length):
                // Absolute line heights scale with the reader's size, like font sizes, so lines never overlap.
                let context = LengthContext(em: style.fontSize, rem: rem, scale: typography.fontSize / 16,
                                            percentBase: style.fontSize, resolvesViewport: true)
                let maximum = style.fontSize * StyleLimits.lineHeightMultiple.upperBound
                style.lineHeight = .points(min(max(points(length, context), 0), maximum))
            }
        case (.color, .color(let specified)):
            style.color = color(specified, current: parent.color)
        case (.display, .display(let display, let blockifies)):
            style.display = display; style.blockifiesChildren = blockifies
        case (.float, .float(let float)): style.float = float
        case (.position, .flag(let outOfFlow)): style.isOutOfFlow = outOfFlow
        case (.marginTop, _), (.marginRight, _), (.marginBottom, _), (.marginLeft, _):
            let length: ComputedStyle.Length = if case .length(let l) = value { computed(l, own, points: StyleLimits.offset) } else { .auto }
            switch property {
            case .marginTop: style.margin.top = length
            case .marginRight: style.margin.right = length
            case .marginBottom: style.margin.bottom = length
            default: style.margin.left = length
            }
        case (.paddingTop, .length(let l)): style.padding.top = computed(l, own, points: StyleLimits.extent)
        case (.paddingRight, .length(let l)): style.padding.right = computed(l, own, points: StyleLimits.extent)
        case (.paddingBottom, .length(let l)): style.padding.bottom = computed(l, own, points: StyleLimits.extent)
        case (.paddingLeft, .length(let l)): style.padding.left = computed(l, own, points: StyleLimits.extent)
        case (.borderTopStyle, .borderStyle(let s)), (.borderRightStyle, .borderStyle(let s)),
             (.borderBottomStyle, .borderStyle(let s)), (.borderLeftStyle, .borderStyle(let s)):
            style[border: Side(property)].style = s
        case (.borderTopWidth, .length(let l)), (.borderRightWidth, .length(let l)),
             (.borderBottomWidth, .length(let l)), (.borderLeftWidth, .length(let l)):
            let width = points(l, own)
            style[border: Side(property)].width = min(max(width, StyleLimits.borderWidth.lowerBound), StyleLimits.borderWidth.upperBound)
        case (.borderTopColor, .color(let c)), (.borderRightColor, .color(let c)),
             (.borderBottomColor, .color(let c)), (.borderLeftColor, .color(let c)):
            // nil is currentColor: the builder uses the element's text color.
            style[border: Side(property)].color = c == .currentColor ? nil : color(c, current: style.color)
        case (.width, _), (.height, _), (.minWidth, _), (.minHeight, _), (.maxWidth, _), (.maxHeight, _):
            let length: ComputedStyle.Length = if case .length(let l) = value { computed(l, own, points: StyleLimits.extent) } else { .auto }
            switch property {
            case .width: style.width = length
            case .height: style.height = length
            case .minWidth: style.minWidth = length
            case .minHeight: style.minHeight = length
            case .maxWidth: style.maxWidth = length
            default: style.maxHeight = length
            }
        case (.backgroundColor, .color(let c)): style.backgroundColor = color(c, current: style.color)
        case (.verticalAlign, .verticalAlign(let align)): style.verticalAlign = align
        case (.verticalAlign, .length(let l)):
            let lineHeight = style.lineHeightPoints ?? style.fontSize * 1.2
            let context = LengthContext(em: style.fontSize, rem: rem, percentBase: lineHeight, resolvesViewport: true)
            style.verticalAlign = .offset(min(max(points(l, context), StyleLimits.offset.lowerBound), StyleLimits.offset.upperBound))
        case (.breakBefore, .breakValue(let b)): style.breakBefore = b
        case (.breakAfter, .breakValue(let b)): style.breakAfter = b
        case (.breakInside, .breakValue(let b)): style.breakInside = b
        case (.textAlign, .textAlign(let align)): style.textAlign = align
        case (.textIndent, .length(let l)): style.textIndent = computed(l, own, points: StyleLimits.offset)
        case (.whiteSpace, .whiteSpace(let w)): style.whiteSpace = w
        case (.textTransform, .textTransform(let t)): style.textTransform = t
        case (.letterSpacing, .length(let l)):
            style.letterSpacing = min(max(points(l, own), -style.fontSize), style.fontSize * 2)
        case (.wordSpacing, .length(let l)):
            style.wordSpacing = min(max(points(l, own), -style.fontSize), style.fontSize * 4)
        case (.direction, .direction(let d)): style.direction = d
        case (.writingMode, .writingMode(let w)): style.writingMode = w
        case (.listStyleType, .listStyleType(let t)): style.listStyleType = t
        case (.listStylePosition, .listStylePosition(let p)): style.listStylePosition = p
        case (.hyphens, .hyphens(let h)): style.hyphens = h
        case (.visibility, .flag(let hidden)): style.isHidden = hidden
        case (.borderCollapse, .flag(let collapse)): style.borderCollapse = collapse
        case (.captionSide, .flag(let bottom)): style.captionSide = bottom ? .bottom : .top
        case (.borderSpacing, .spacing(let h, let v)):
            func clamp(_ x: CGFloat) -> CGFloat { min(max(x, StyleLimits.borderSpacing.lowerBound), StyleLimits.borderSpacing.upperBound) }
            style.borderSpacing = CGSize(width: clamp(points(h, own)), height: clamp(points(v, own)))
        default:
            break
        }
    }

    /// Absolute sizes and keywords scale by `typography.fontSize / 16`; relative sizes follow the parent.
    private func fontSize(_ size: CSSFontSize, parent: CGFloat, rem: CGFloat) -> CGFloat {
        let value: CGFloat = switch size {
        case .keyword(let factor): typography.fontSize * CGFloat(factor)
        case .smaller: parent / 1.2
        case .larger: parent * 1.2
        case .length(let length):
            points(length, LengthContext(em: parent, rem: rem, scale: typography.fontSize / 16, percentBase: parent, resolvesViewport: true))
        }
        return min(max(value, StyleLimits.fontSize.lowerBound), StyleLimits.fontSize.upperBound)
    }

    enum Side: CaseIterable {
        case top, right, bottom, left
        init(_ property: CSSProperty) {
            switch property {
            case .borderTopStyle, .borderTopWidth, .borderTopColor: self = .top
            case .borderRightStyle, .borderRightWidth, .borderRightColor: self = .right
            case .borderBottomStyle, .borderBottomWidth, .borderBottomColor: self = .bottom
            default: self = .left
            }
        }
    }
}

extension ComputedStyle {
    subscript(border side: StyleResolver.Side) -> Border {
        get {
            switch side {
            case .top: border.top
            case .right: border.right
            case .bottom: border.bottom
            case .left: border.left
            }
        }
        set {
            switch side {
            case .top: border.top = newValue
            case .right: border.right = newValue
            case .bottom: border.bottom = newValue
            case .left: border.left = newValue
            }
        }
    }
}
