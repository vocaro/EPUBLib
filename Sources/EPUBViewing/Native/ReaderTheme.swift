import CoreGraphics
import EPUBCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The colours the reader draws with: a theme's (`EPUBReaderColors`) as Increase Contrast
/// leaves them, and those the reader derives from them for what the theme does not name.
///
/// Every derived colour keeps the text drawn on it, or beside it, readable: secondary text is
/// faded toward the background only as far as WCAG 2.2's 4.5:1 allows (7:1 with Increase
/// Contrast), and a highlight or a selection is drawn as strongly as it can be while the text
/// over it keeps 4.5:1, down to half its usual strength. Increase Contrast makes each of them
/// stronger by the same rule. A theme's own text below 4.5:1, which a custom theme may have, is
/// the reader's choice and is left as it is.
struct ReaderTheme: Hashable, Sendable {
    /// The theme's colours, Increase Contrast already applied.
    let colors: EPUBReaderColors
    /// Increase Contrast is on.
    let increasesContrast: Bool
    /// Secondary text: words in place of an image, and a section that could not be shown.
    let secondaryTextColor: EPUBReaderColor
    /// Horizontal rules and a dark theme's table borders.
    let ruleColor: EPUBReaderColor
    /// The selection's colour on the Mac, opaque: the link colour over the page.
    let selectionColor: EPUBReaderColor
    /// Search matches, host highlights and the current search result, in that order.
    private let fills: [Fill]
    private struct Fill: Hashable, Sendable { let color: EPUBReaderColor; let alpha: Double }
    /// A host highlight's fill in each style's color, and its mark's line (`EPUBHighlightStyle`).
    private let styleFills: [EPUBHighlightColor: Fill]
    private let styleMarks: [EPUBHighlightColor: EPUBReaderColor]

    /// The colours derive once, here: a page draws thousands of highlights.
    init(_ colors: EPUBReaderColors, increasesContrast: Bool = false) {
        let colors = increasesContrast ? colors.increasingContrast : colors
        self.colors = colors
        self.increasesContrast = increasesContrast
        secondaryTextColor = Self.fadedText(colors, increasesContrast: increasesContrast)
        ruleColor = Self.ruleColor(colors, increasesContrast: increasesContrast)
        selectionColor = colors.background.mixed(with: colors.link, by: Self.strength(
            colors.link, alpha: 0.3, over: colors.background, text: colors.text, increasesContrast: increasesContrast))
        var fills: [Fill] = []
        for kind in [ReaderHighlight.Kind.search, .annotation, .currentSearch] {
            let (color, alpha) = Self.baseFill(kind, dark: colors.isDark)
            // The current result is drawn over its own search highlight.
            let beneath = kind == .currentSearch ? colors.background.mixed(with: fills[0].color, by: fills[0].alpha) : colors.background
            fills.append(Fill(color: color, alpha: Self.strength(color, alpha: alpha, over: beneath, text: colors.text,
                                                                 increasesContrast: increasesContrast)))
        }
        self.fills = fills
        var styleFills: [EPUBHighlightColor: Fill] = [:], styleMarks: [EPUBHighlightColor: EPUBReaderColor] = [:]
        for style in EPUBHighlightColor.allCases {
            let (color, alpha) = Self.baseFill(style, dark: colors.isDark)
            let fill = Fill(color: color, alpha: Self.strength(color, alpha: alpha, over: colors.background, text: colors.text,
                                                               increasesContrast: increasesContrast))
            styleFills[style] = fill
            styleMarks[style] = Self.markColor(Self.baseMark(style, dark: colors.isDark), over: colors.background.mixed(with: fill.color, by: fill.alpha),
                                               text: colors.text, increasesContrast: increasesContrast)
        }
        self.styleFills = styleFills
        self.styleMarks = styleMarks
    }

    static let light = ReaderTheme(.light)
    static let dark = ReaderTheme(.dark)

    /// The background is dark (`EPUBReaderColors.isDark`): the book's colours give way to the
    /// theme's, `prefers-color-scheme: dark` applies and dark line art gets a white backdrop.
    var isDark: Bool { colors.isDark }

    /// The least contrast text keeps against what it is drawn on.
    static let minimumTextContrast = 4.5
    /// The least contrast a rule keeps with Increase Contrast on: WCAG 2.2's 3:1 for graphics
    /// (success criterion 1.4.11).
    static let minimumGraphicContrast = 3.0

    // MARK: Colours, as sRGB

    /// The text faded toward the page, as far as 4.5:1 allows (7:1 with Increase Contrast).
    private static func fadedText(_ colors: EPUBReaderColors, increasesContrast: Bool) -> EPUBReaderColor {
        let floor = increasesContrast ? EPUBReaderColors.enhancedContrast : minimumTextContrast
        var fraction = increasesContrast ? 0.2 : 0.38
        var color = colors.text.mixed(with: colors.background, by: fraction)
        while fraction > 0, color.contrastRatio(to: colors.background) < floor {
            fraction = max(0, fraction - 1.0 / 128)
            color = colors.text.mixed(with: colors.background, by: fraction)
        }
        return color
    }

    /// A quarter of the way from the page to the text; with Increase Contrast, half the way,
    /// and further if that is still short of 3:1.
    private static func ruleColor(_ colors: EPUBReaderColors, increasesContrast: Bool) -> EPUBReaderColor {
        guard increasesContrast else { return colors.background.mixed(with: colors.text, by: 0.25) }
        var fraction = 0.5
        var color = colors.background.mixed(with: colors.text, by: fraction)
        while fraction < 1, color.contrastRatio(to: colors.background) < minimumGraphicContrast {
            fraction = min(1, fraction + 1.0 / 64)
            color = colors.background.mixed(with: colors.text, by: fraction)
        }
        return color
    }

    /// A highlight's colour and opacity, drawn over the page (a current search result over its
    /// own search highlight). The hues are yellow and orange, deeper on a dark background.
    func highlightFill(_ kind: ReaderHighlight.Kind) -> (color: EPUBReaderColor, alpha: Double) {
        let fill = switch kind {
        case .search: fills[0]
        case .annotation: fills[1]
        case .currentSearch: fills[2]
        }
        return (fill.color, fill.alpha)
    }

    private static func baseFill(_ kind: ReaderHighlight.Kind, dark: Bool) -> (EPUBReaderColor, Double) {
        switch (kind, dark) {
        case (.search, false): (EPUBReaderColor(red: 1, green: 0.83, blue: 0.2), 0.45)
        case (.search, true): (EPUBReaderColor(red: 0.55, green: 0.42, blue: 0), 0.6)
        // A host highlight with no style is drawn in the default one, yellow.
        case (.annotation, _): baseFill(EPUBHighlightColor.yellow, dark: dark)
        case (.currentSearch, false): (EPUBReaderColor(red: 1, green: 0.58, blue: 0.1), 0.7)
        case (.currentSearch, true): (EPUBReaderColor(red: 0.85, green: 0.35, blue: 0), 0.7)
        }
    }

    /// A host highlight's color and its usual opacity for each style: a pale shade on a light
    /// background and a deep one on a dark background, drawn as strongly as the text over it
    /// keeps 4.5:1 (`strength`). Over Light's and Dark's own page and text the text keeps at
    /// least 14:1 and 8:1 (`HighlightStyleTests`). Yellow is the fill every host highlight had
    /// before styles.
    private static func baseFill(_ color: EPUBHighlightColor, dark: Bool) -> (EPUBReaderColor, Double) {
        switch (color, dark) {
        case (.yellow, false): (EPUBReaderColor(red: 1, green: 0.9, blue: 0.3), 0.55)
        case (.green, false): (EPUBReaderColor(red: 0.35, green: 0.85, blue: 0.4), 0.45)
        case (.blue, false): (EPUBReaderColor(red: 0.35, green: 0.65, blue: 1), 0.4)
        case (.pink, false): (EPUBReaderColor(red: 1, green: 0.45, blue: 0.65), 0.4)
        case (.purple, false): (EPUBReaderColor(red: 0.7, green: 0.5, blue: 1), 0.4)
        case (.yellow, true): (EPUBReaderColor(red: 0.9, green: 0.75, blue: 0.1), 0.35)
        case (.green, true): (EPUBReaderColor(red: 0.2, green: 0.7, blue: 0.3), 0.4)
        case (.blue, true): (EPUBReaderColor(red: 0.25, green: 0.5, blue: 1), 0.45)
        case (.pink, true): (EPUBReaderColor(red: 0.95, green: 0.3, blue: 0.55), 0.4)
        case (.purple, true): (EPUBReaderColor(red: 0.6, green: 0.4, blue: 1), 0.45)
        }
    }

    /// The shade a style's mark is drawn in: a dark one of its color on a light background and a
    /// light one on a dark background.
    private static func baseMark(_ color: EPUBHighlightColor, dark: Bool) -> EPUBReaderColor {
        switch (color, dark) {
        case (.yellow, false): EPUBReaderColor(red: 0.55, green: 0.42, blue: 0)
        case (.green, false): EPUBReaderColor(red: 0.1, green: 0.45, blue: 0.15)
        case (.blue, false): EPUBReaderColor(red: 0.1, green: 0.33, blue: 0.75)
        case (.pink, false): EPUBReaderColor(red: 0.7, green: 0.1, blue: 0.38)
        case (.purple, false): EPUBReaderColor(red: 0.42, green: 0.2, blue: 0.72)
        case (.yellow, true): EPUBReaderColor(red: 1, green: 0.85, blue: 0.35)
        case (.green, true): EPUBReaderColor(red: 0.5, green: 0.9, blue: 0.55)
        case (.blue, true): EPUBReaderColor(red: 0.6, green: 0.78, blue: 1)
        case (.pink, true): EPUBReaderColor(red: 1, green: 0.62, blue: 0.78)
        case (.purple, true): EPUBReaderColor(red: 0.8, green: 0.68, blue: 1)
        }
    }

    /// A mark's line over `fill`: its shade, moved toward the text only as far as it needs to
    /// keep WCAG 2.2's 3:1 for a graphic that carries meaning (success criterion 1.4.11). With
    /// Increase Contrast it is half the way to the text, and further if that is short of 4.5:1.
    private static func markColor(_ shade: EPUBReaderColor, over fill: EPUBReaderColor, text: EPUBReaderColor,
                                  increasesContrast: Bool) -> EPUBReaderColor {
        let floor = increasesContrast ? minimumTextContrast : minimumGraphicContrast
        var fraction = increasesContrast ? 0.5 : 0
        var color = shade.mixed(with: text, by: fraction)
        while fraction < 1, color.contrastRatio(to: fill) < floor {
            fraction = min(1, fraction + 1.0 / 64)
            color = shade.mixed(with: text, by: fraction)
        }
        return color
    }

    /// A host highlight's fill and opacity in a style of `color`, drawn over the page.
    func highlightFill(_ color: EPUBHighlightColor) -> (color: EPUBReaderColor, alpha: Double) {
        let fill = styleFills[color]!
        return (fill.color, fill.alpha)
    }

    /// The line a mark of a style of `color` is drawn in, opaque.
    func markColor(_ color: EPUBHighlightColor) -> EPUBReaderColor { styleMarks[color]! }

    /// `fill` drawn over `beneath`.
    func composite(_ fill: (color: EPUBReaderColor, alpha: Double), over beneath: EPUBReaderColor) -> EPUBReaderColor {
        beneath.mixed(with: fill.color, by: fill.alpha)
    }

    /// The opacity a fill of usual opacity `alpha` is drawn with over `beneath`: `alpha`, or with
    /// Increase Contrast half the way from it to opaque, in either case only as far as `text`
    /// over it keeps 4.5:1. It is never less than half `alpha`, nor with Increase Contrast less
    /// than without.
    private static func strength(_ color: EPUBReaderColor, alpha: Double, over beneath: EPUBReaderColor,
                                 text: EPUBReaderColor, increasesContrast: Bool) -> Double {
        func fitted(_ desired: Double, floor: Double) -> Double {
            var strength = desired
            while strength > floor, text.contrastRatio(to: beneath.mixed(with: color, by: strength)) < minimumTextContrast {
                strength = max(floor, strength - 1.0 / 256)
            }
            return strength
        }
        let usual = fitted(alpha, floor: alpha / 2)
        return increasesContrast ? fitted(alpha + (1 - alpha) / 2, floor: usual) : usual
    }

    // MARK: Platform colours

    var background: PlatformColor { PlatformColor(colors.background) }
    var text: PlatformColor { PlatformColor(colors.text) }
    var link: PlatformColor { PlatformColor(colors.link) }
    var secondaryText: PlatformColor { PlatformColor(secondaryTextColor) }
    var rule: PlatformColor { PlatformColor(ruleColor) }
    var selection: PlatformColor { PlatformColor(selectionColor) }
    func highlight(_ kind: ReaderHighlight.Kind) -> PlatformColor {
        let fill = highlightFill(kind)
        return PlatformColor(fill.color, alpha: fill.alpha)
    }
    func highlight(_ color: EPUBHighlightColor) -> PlatformColor {
        let fill = highlightFill(color)
        return PlatformColor(fill.color, alpha: fill.alpha)
    }
    func mark(_ color: EPUBHighlightColor) -> PlatformColor { PlatformColor(markColor(color)) }

    /// What `highlight` draws: a search match its fill, and a host highlight its style's fill
    /// and mark, the default style where it has none.
    func paint(_ highlight: ReaderHighlight) -> ReaderHighlightPaint {
        guard highlight.kind == .annotation else { return ReaderHighlightPaint(fill: self.highlight(highlight.kind)) }
        let style = highlight.style ?? EPUBHighlightStyle()
        return ReaderHighlightPaint(fill: self.highlight(style.color), replacesMarks: true,
                                    mark: style.mark.map { ($0, mark(style.color)) })
    }
}

extension PlatformColor {
    convenience init(_ color: EPUBReaderColor, alpha: Double = 1) {
        self.init(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: CGFloat(alpha))
    }
}
