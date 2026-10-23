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
    /// CSS Text 3's `tab-size`: a number of spaces, each as wide as the box's own with its
    /// letter and word spacing, or a length in points.
    enum TabSize: Equatable, Sendable { case spaces(CGFloat), points(CGFloat) }
    enum Direction: Hashable, Sendable { case ltr, rtl }
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
    enum Clear: Equatable, Sendable { case none, left, right, both }
    enum Position: Equatable, Sendable { case `static`, relative, absolute, fixed, sticky }
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
        /// 0–100 of the reading viewport: its width, its height, and the smaller and the larger
        /// of the two (`vmin`, `vmax`; CSS Values 3, 5.1.2).
        case viewportWidth(CGFloat), viewportHeight(CGFloat), viewportMin(CGFloat), viewportMax(CGFloat)
        case auto
        static let zero = Length.points(0)
        /// Resolves against a reference length; `auto` resolves to nil.
        func resolve(reference: CGFloat, viewport: CGSize) -> CGFloat? {
            switch self {
            case .points(let value): value
            case .percent(let value): reference * value / 100
            case .viewportWidth(let value): viewport.width * value / 100
            case .viewportHeight(let value): viewport.height * value / 100
            case .viewportMin(let value): min(viewport.width, viewport.height) * value / 100
            case .viewportMax(let value): max(viewport.width, viewport.height) * value / 100
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
    var clear: Clear = .none
    var position: Position = .static
    /// Compatibility for clients of the internal computed style that only distinguish flow.
    var isOutOfFlow: Bool {
        get { position == .absolute || position == .fixed }
        set {
            if newValue {
                if !isOutOfFlow { position = .absolute }
            } else if isOutOfFlow { position = .static }
        }
    }
    /// Insets resolve against the containing box at layout; `auto` leaves an edge unconstrained.
    var positionTop: Length = .auto
    var positionRight: Length = .auto
    var positionBottom: Length = .auto
    var positionLeft: Length = .auto
    /// Classified from the specified CSS lengths, never the reader's computed font size.
    var positionTopIsOffscreen = false
    var positionLeftIsOffscreen = false
    /// Common zero-area clipping techniques for visually hidden positioned labels.
    var clipsAllContent = false
    var clipsAllContentWithPath = false

    var requiresFlowBox: Bool {
        isOutOfFlow || float != .none || (display == .inlineBlock &&
            (width != .auto || height != .auto || minWidth != .auto || maxWidth != .auto || minHeight != .auto))
    }

    var isVisuallyHiddenPositionedBox: Bool {
        if clipsAllContent || clipsAllContentWithPath || isHidden { return true }
        // Rendering must never change its source characters when the reader changes typography,
        // so these flags come from the authored offsets and not from their computed lengths.
        return positionTopIsOffscreen || positionLeftIsOffscreen
    }
    /// Hidden from the page and kept for assistive technology: parked off screen or clipped to
    /// nothing, which a browser does not draw and does read. `visibility: hidden` hides from both.
    var isSpokenOnlyPositionedBox: Bool {
        !isHidden && (clipsAllContent || clipsAllContentWithPath || positionTopIsOffscreen || positionLeftIsOffscreen)
    }
    /// A flex or grid container, which renders as a block; its in-flow children are blockified.
    var blockifiesChildren = false
    /// The flex and grid values the native layout aligns items by (`ReaderAlignmentLayout`).
    var boxAlignment = BoxAlignment()
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
    /// `filter: invert(…)` of at least 50%: the element's image is drawn with its colors inverted
    /// (Standard Ebooks inverts black-on-transparent art in dark appearance this way).
    var invertsColors = false

    // Text. Inherited.
    /// Lowercased, unquoted family names in preference order, generic families included
    /// (`serif`, `sans-serif`, `monospace`, `cursive`, `fantasy`, `system-ui`).
    var fontFamilies: [String] = []
    /// Points.
    var fontSize: CGFloat = 17
    /// 100–900.
    var fontWeight: Int = 400
    /// The system's Bold Text is on: fonts are found for `usedFontWeight`, not `fontWeight`.
    /// Not a CSS property: the root takes it from the reader and every element inherits it, so
    /// no rule or `initial` resets it, and a weight is made heavier once, where it is drawn.
    var usesBoldText = false
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
    /// `tab-size`: how far apart a block's tab stops are (`InlineStyling.tabInterval`).
    var tabSize: TabSize = .spaces(8)
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

    /// Generated content's properties (`quotes`, `content`, the counters), the element's
    /// `::before` and `::after` and its `::first-letter` and `::first-line` rules, behind one
    /// reference, nil when all are their initial values (`GeneratedContentStyle.swift`). A computed style is copied on every nesting level of a
    /// table built on a small stack, so what most elements lack takes no room in it.
    var generatedContent: GeneratedContentStorage?
    /// Custom properties (`--name`), computed. Inherited: an element that declares none shares
    /// its parent's. nil when there are none (`CustomProperties.swift`).
    var customProperties: CSSCustomProperties?
    /// What the reader's text settings did to this style, nil when none is set
    /// (`ReaderTextSettings`).
    var textSettings: ReaderTextTrace?

    /// The weight fonts are found for: `fontWeight`, or with Bold Text 200 heavier, to at most
    /// 900, as iOS draws its own text a weight heavier (regular as semibold).
    var usedFontWeight: Int { usesBoldText ? min(fontWeight + 200, 900) : fontWeight }

    /// Resolved line height in points for this style's font size; nil for `normal`.
    var lineHeightPoints: CGFloat? {
        switch lineHeight {
        case .normal: nil
        case .multiple(let value): value * fontSize
        case .points(let value): value
        }
    }
}
