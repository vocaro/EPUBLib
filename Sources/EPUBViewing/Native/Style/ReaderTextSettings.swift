import CoreGraphics
import EPUBCore
import Foundation

/// The host's settings for book text (`EPUBReaderStyle.Typography`), as the style resolver
/// applies them: bounded, and without the page margins, which the canvas applies
/// (`ReaderCanvasConfiguration.pageMargins`). Part of `NativeTypography`, so a change rebuilds
/// the text, which keeps its characters and so every rendered location.
///
/// With `overrides` off the settings are a user style sheet (CSS Cascade 4 §6.2): normal
/// declarations of the user origin, between the user agent's and the book's, on the root
/// element and on `p`. The book's declarations win where it makes them, and what it leaves to
/// inheritance takes the reader's values. With `overrides` on, each value set is given to every
/// element whose text the settings reach, after the cascade (`override`).
///
/// Either way the settings leave alone what they must not change (`leavesAlone`): such an
/// element, and all it holds, is styled from the book's styles alone, as with no settings.
struct ReaderTextSettings: Hashable, Sendable {
    static let lineHeights: ClosedRange<CGFloat> = 0.5...5
    static let paragraphSpacings: ClosedRange<CGFloat> = 0...5
    static let letterSpacings: ClosedRange<CGFloat> = -0.25...1
    static let wordSpacings: ClosedRange<CGFloat> = -0.25...2

    /// A family as `ComputedStyle.fontFamilies` names it: lowercased, a generic or a family name.
    var fontFamily: String?
    /// A multiple of the font size.
    var lineHeight: CGFloat?
    /// Ems of a paragraph's font size.
    var paragraphSpacing: CGFloat?
    /// Ems of the element's font size.
    var letterSpacing: CGFloat?
    var wordSpacing: CGFloat?
    var justifies: Bool?
    var hyphenates: Bool?
    var overrides = false

    init() {}

    init(_ typography: EPUBReaderStyle.Typography) {
        func bounded(_ value: Double?, _ range: ClosedRange<CGFloat>) -> CGFloat? {
            guard let value, value.isFinite else { return nil }
            return min(max(CGFloat(value), range.lowerBound), range.upperBound)
        }
        switch typography.fontFamily {
        case nil: fontFamily = nil
        case .serif?: fontFamily = "serif"
        case .sansSerif?: fontFamily = "sans-serif"
        case .monospace?: fontFamily = "monospace"
        case .rounded?: fontFamily = "ui-rounded"
        case .named(let name)?:
            let family = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            fontFamily = family.isEmpty ? nil : family
        }
        lineHeight = bounded(typography.lineHeight, Self.lineHeights)
        paragraphSpacing = bounded(typography.paragraphSpacing, Self.paragraphSpacings)
        letterSpacing = bounded(typography.letterSpacing, Self.letterSpacings)
        wordSpacing = bounded(typography.wordSpacing, Self.wordSpacings)
        justifies = typography.alignment.map { $0 == .justified }
        hyphenates = typography.hyphenation
        overrides = typography.overridesBookStyles
    }

    /// Nothing set: the book's styles and the reader's defaults, computed as before.
    var isEmpty: Bool {
        fontFamily == nil && lineHeight == nil && paragraphSpacing == nil && letterSpacing == nil
            && wordSpacing == nil && justifies == nil && hyphenates == nil
    }

    /// The families an element set in `fontFamily` is given: that one, then those it had, so
    /// that a family that is not available leaves the element's own, and a character the family
    /// lacks is drawn in it (`FontRegistry`).
    func families(over families: [String]) -> [String] {
        guard let fontFamily else { return families }
        return Array(([fontFamily] + families.filter { $0 != fontFamily }).prefix(CSSPropertyParser.maximumFamilies))
    }

    // MARK: The user style sheet

    /// The user origin's normal declarations on the root element (`:root`), which the book's
    /// elements inherit where it declares nothing of its own.
    var rootDeclarations: [CSSDeclaration] {
        guard !overrides else { return [] }
        var declarations: [CSSDeclaration] = []
        func declare(_ property: CSSProperty, _ value: CSSValue) {
            declarations.append(CSSDeclaration(property: property, value: value, important: false))
        }
        // The reader's own family follows a named one, as the user agent's sheet gives `html`.
        if fontFamily != nil { declare(.fontFamily, .families(families(over: ["serif"]))) }
        if let lineHeight { declare(.lineHeight, .lineHeight(.number(Double(lineHeight)))) }
        if let letterSpacing { declare(.letterSpacing, .length(.value(Double(letterSpacing), .em))) }
        if let wordSpacing { declare(.wordSpacing, .length(.value(Double(wordSpacing), .em))) }
        if let justifies { declare(.textAlign, .textAlign(justifies ? .justify : .start)) }
        if let hyphenates { declare(.hyphens, .hyphens(hyphenates ? .auto : .manual)) }
        return declarations
    }

    /// The user origin's normal declarations on an HTML `p`, in place of the user agent's
    /// `margin-top: 1em; margin-bottom: 1em`.
    var paragraphDeclarations: [CSSDeclaration] {
        guard !overrides, let paragraphSpacing else { return [] }
        let length = CSSValue.length(.value(Double(paragraphSpacing), .em))
        return [CSSDeclaration(property: .marginTop, value: length, important: false),
                CSSDeclaration(property: .marginBottom, value: length, important: false)]
    }

    // MARK: Over the book's styles

    /// Gives the computed `style` of an element the settings reach every value set, over the
    /// book's: a family ahead of its own, line height and spacing in its own ems, hyphenation,
    /// and ragged or justified lines where the book's are ragged or justified. A centred line,
    /// or one set to the end side, stays so. `isParagraph`: an HTML `p`, which takes the
    /// paragraph spacing as its top and bottom margins.
    func override(_ style: inout ComputedStyle, isParagraph: Bool) {
        style.fontFamilies = families(over: style.fontFamilies)
        if let lineHeight { style.lineHeight = .multiple(lineHeight) }
        if let letterSpacing { style.letterSpacing = letterSpacing * style.fontSize }
        if let wordSpacing { style.wordSpacing = wordSpacing * style.fontSize }
        if let hyphenates { style.hyphens = hyphenates ? .auto : .manual }
        if let justifies {
            let startSide: ComputedStyle.TextAlign = style.direction == .rtl ? .right : .left
            if style.textAlign == .start || style.textAlign == .justify || style.textAlign == startSide {
                style.textAlign = justifies ? .justify : .start
            }
        }
        if isParagraph, let paragraphSpacing {
            style.margin.top = .points(paragraphSpacing * style.fontSize)
            style.margin.bottom = .points(paragraphSpacing * style.fontSize)
        }
    }

    // MARK: What the settings leave alone

    /// Whether the settings leave an element, and everything it holds, as the book styles it:
    /// preformatted text, whose spaces and columns are the book's (`pre`, `listing`, `plaintext`,
    /// `xmp`, or an element that keeps white space where its parent does not); code (`code`,
    /// `kbd`, `samp`, `tt`); a table; MathML and SVG, which lay themselves out; and a box the
    /// book sizes or places, whose text is set to fit it: a float, an absolutely positioned box,
    /// or one with a height or maximum height other than a percentage. `style` and `parent` are
    /// the element's and its parent's styles as the book alone gives them. The root and the body
    /// are never left alone, so a book's own styles there cannot turn the settings off: one that
    /// keeps white space throughout, as a plain text made a book can, is still set.
    static func leavesAlone(_ element: ContentNode, style: ComputedStyle, parent: ComputedStyle,
                            document: ContentDocument) -> Bool {
        guard element !== document.root, !element.isHTML("body") else { return false }
        if element.namespace == ContentNamespace.mathML || element.namespace == ContentNamespace.svg { return true }
        if element.isHTML, leftAloneElements.contains(element.name) { return true }
        if style.whiteSpace.preservesSpaces, !parent.whiteSpace.preservesSpaces { return true }
        if style.display == .table { return true }
        if style.float != .none || style.isOutOfFlow { return true }
        return isDefinite(style.height) || isDefinite(style.maxHeight)
    }

    private static let leftAloneElements: Set<String> = ["pre", "listing", "plaintext", "xmp", "code", "kbd", "samp", "tt", "table"]

    private static func isDefinite(_ length: ComputedStyle.Length) -> Bool {
        switch length {
        case .auto, .percent: false
        case .points, .viewportWidth, .viewportHeight, .viewportMin, .viewportMax: true
        }
    }
}

/// What the reader's text settings did to an element's computed style
/// (`ComputedStyle.textSettings`), so that what it holds can be styled from the book's styles
/// alone where the settings leave it alone. nil when no setting is set.
final class ReaderTextTrace: Equatable, Sendable {
    /// The inherited values the settings can change, as the book alone gives them to the
    /// element. nil for `leftAlone`, whose style is the book's already.
    let book: BookText?

    /// The style of an element the settings leave alone, or of one inside it.
    static let leftAlone = ReaderTextTrace(book: nil)

    init(book: BookText?) { self.book = book }

    static func == (lhs: ReaderTextTrace, rhs: ReaderTextTrace) -> Bool { lhs === rhs || lhs.book == rhs.book }

    /// The inherited properties the settings set.
    struct BookText: Equatable, Sendable {
        var fontFamilies: [String]
        var lineHeight: ComputedStyle.LineHeight
        var letterSpacing: CGFloat
        var wordSpacing: CGFloat
        var hyphens: ComputedStyle.Hyphens
        var textAlign: ComputedStyle.TextAlign

        init(_ style: ComputedStyle) {
            fontFamilies = style.fontFamilies; lineHeight = style.lineHeight
            letterSpacing = style.letterSpacing; wordSpacing = style.wordSpacing
            hyphens = style.hyphens; textAlign = style.textAlign
        }

        /// `style` with these values in place of its own: the parent the book's styles alone
        /// would give an element.
        func applied(to style: ComputedStyle) -> ComputedStyle {
            var style = style
            style.fontFamilies = fontFamilies; style.lineHeight = lineHeight
            style.letterSpacing = letterSpacing; style.wordSpacing = wordSpacing
            style.hyphens = hyphens; style.textAlign = textAlign
            style.textSettings = nil
            return style
        }
    }
}

extension NativeTypography {
    init(fontSize: CGFloat = 17, isDark: Bool = false, text: ReaderTextSettings) {
        self.init(fontSize: fontSize, isDark: isDark)
        self.text = text
    }
}
