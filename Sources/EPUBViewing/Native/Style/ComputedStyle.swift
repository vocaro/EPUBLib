import CoreGraphics

/// The CSS computed values the native renderer honours: the book CSS subset.
///
/// Lengths are resolved to points (`em`, `rem`, `ex`, `ch`, `px`, `pt`, `pc`, `in`, `cm`, `mm`,
/// font-size keywords) when the style is computed. Percentages and viewport units stay
/// symbolic because their reference box is only known at layout. A CSS `px` is one point.
/// Absolute font sizes are scaled by `typography.fontSize / 16`, so a book's own sizes keep their
/// proportions while the reader's size governs the whole book.
struct ComputedStyle: Equatable, Sendable {
    enum Display: Equatable, Sendable {
        case inline, block, listItem, inlineBlock, none
        case table, tableRowGroup, tableHeaderGroup, tableFooterGroup, tableRow, tableCell
        case tableCaption, tableColumn, tableColumnGroup
        case ruby, rubyText
        var isBlockLevel: Bool {
            switch self {
            case .inline, .inlineBlock, .none, .ruby, .rubyText: false
            default: true
            }
        }
    }
    enum TextAlign: Equatable, Sendable { case start, end, left, right, center, justify }
    enum WhiteSpace: Equatable, Sendable {
        case normal, nowrap, pre, preWrap, preLine, breakSpaces
        /// Whether runs of spaces and tabs are kept.
        var preservesSpaces: Bool { self == .pre || self == .preWrap || self == .breakSpaces }
        /// Whether line feeds are kept.
        var preservesNewlines: Bool { self != .normal && self != .nowrap }
        var wraps: Bool { self != .nowrap && self != .pre }
    }
    enum VerticalAlign: Equatable, Sendable {
        case baseline, sub, `super`, top, middle, bottom, textTop, textBottom
        /// Raise (positive) or lower by points.
        case offset(CGFloat)
    }
    enum TextTransform: Equatable, Sendable { case none, uppercase, lowercase, capitalize }
    enum Direction: Equatable, Sendable { case ltr, rtl }
    enum WritingMode: Equatable, Sendable { case horizontalTB, verticalRL, verticalLR }
    enum ListStyleType: Equatable, Sendable {
        case none, disc, circle, square, decimal, decimalLeadingZero
        case lowerAlpha, upperAlpha, lowerRoman, upperRoman, lowerGreek
        /// A `list-style-type: "…"` string marker.
        case string(String)
    }
    enum ListStylePosition: Equatable, Sendable { case inside, outside }
    enum Hyphens: Equatable, Sendable { case none, manual, auto }
    enum Break: Equatable, Sendable { case auto, avoid, page, column }
    enum Float: Equatable, Sendable { case none, left, right }
    enum CaptionSide: Equatable, Sendable { case top, bottom }
    enum LineHeight: Equatable, Sendable {
        case normal
        /// A unitless multiple of the element's font size.
        case multiple(CGFloat)
        case points(CGFloat)
    }
    enum Length: Equatable, Sendable {
        case points(CGFloat)
        /// 0–100 of the containing block's width (height for `height`/`max-height`).
        case percent(CGFloat)
        /// 0–100 of the reading viewport.
        case viewportWidth(CGFloat), viewportHeight(CGFloat)
        case auto
        static let zero = Length.points(0)
        /// Resolves against a reference length; `auto` resolves to nil.
        func resolve(reference: CGFloat, viewport: CGSize) -> CGFloat? {
            switch self {
            case .points(let value): value
            case .percent(let value): reference * value / 100
            case .viewportWidth(let value): viewport.width * value / 100
            case .viewportHeight(let value): viewport.height * value / 100
            case .auto: nil
            }
        }
    }
    struct Color: Equatable, Hashable, Sendable {
        var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
        init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
    }
    enum BorderStyle: Equatable, Sendable { case none, hidden, solid, dotted, dashed, double, groove, ridge, inset, outset }
    struct Border: Equatable, Sendable {
        var width: CGFloat = 0
        var style: BorderStyle = .none
        /// nil: the element's text color.
        var color: Color?
        var isVisible: Bool { width > 0 && style != .none && style != .hidden }
    }
    struct Edges<Value: Equatable & Sendable>: Equatable, Sendable {
        var top: Value, right: Value, bottom: Value, left: Value
        init(top: Value, right: Value, bottom: Value, left: Value) {
            self.top = top; self.right = right; self.bottom = bottom; self.left = left
        }
        init(_ all: Value) { self.init(top: all, right: all, bottom: all, left: all) }
    }
    struct Decoration: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let underline = Decoration(rawValue: 1)
        static let overline = Decoration(rawValue: 2)
        static let lineThrough = Decoration(rawValue: 4)
    }

    // Box and flow. Not inherited.
    var display: Display = .inline
    var float: Float = .none
    /// `position: absolute` or `fixed`: the box is out of flow and its offsets are not honoured.
    var isOutOfFlow = false
    /// A flex or grid container, which renders as a block; its in-flow children are blockified.
    var blockifiesChildren = false
    var margin = Edges<Length>(.zero)
    var padding = Edges<Length>(.zero)
    var border = Edges<Border>(Border())
    var width: Length = .auto
    var height: Length = .auto
    var minWidth: Length = .auto
    var minHeight: Length = .auto
    /// `.auto` means `none`.
    var maxWidth: Length = .auto
    var maxHeight: Length = .auto
    var backgroundColor: Color?
    var verticalAlign: VerticalAlign = .baseline
    var breakBefore: Break = .auto
    var breakAfter: Break = .auto
    var breakInside: Break = .auto
    /// `text-decoration-line` with CSS's propagation to descendants already applied.
    var textDecoration: Decoration = []
    var textDecorationColor: Color?

    // Text. Inherited.
    /// Lowercased, unquoted family names in preference order, generic families included
    /// (`serif`, `sans-serif`, `monospace`, `cursive`, `fantasy`, `system-ui`).
    var fontFamilies: [String] = []
    /// Points.
    var fontSize: CGFloat = 17
    /// 100–900.
    var fontWeight: Int = 400
    var isItalic = false
    var isSmallCaps = false
    var lineHeight: LineHeight = .normal
    /// nil: the reader's default text color. Always nil in dark appearance, except that fully
    /// transparent text (hidden labels over a figure) stays transparent.
    var color: Color?
    var textAlign: TextAlign = .start
    var textIndent: Length = .zero
    var whiteSpace: WhiteSpace = .normal
    var textTransform: TextTransform = .none
    /// Points; 0 is `normal`.
    var letterSpacing: CGFloat = 0
    var wordSpacing: CGFloat = 0
    var direction: Direction = .ltr
    var writingMode: WritingMode = .horizontalTB
    var listStyleType: ListStyleType = .disc
    var listStylePosition: ListStylePosition = .outside
    var hyphens: Hyphens = .manual
    var isHidden = false // visibility: hidden | collapse
    var borderCollapse = false
    /// Points, horizontal and vertical.
    var borderSpacing: CGSize = CGSize(width: 2, height: 2)
    var captionSide: CaptionSide = .top

    /// Resolved line height in points for this style's font size; nil for `normal`.
    var lineHeightPoints: CGFloat? {
        switch lineHeight {
        case .normal: nil
        case .multiple(let value): value * fontSize
        case .points(let value): value
        }
    }
}
