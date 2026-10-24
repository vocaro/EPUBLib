import Foundation

// `::first-letter` (CSS Pseudo-Elements 4 §2.2, CSS 2 §5.12.2). The cascade finds an element's
// rules for it (`StyleResolver`); the writer finds the letter as it walks and styles it with
// them (`SectionWriter.writesFirstLetter`), in line or as a float, from the characters the book
// has. `::first-line` rules are found the same way and disclosed instead: which characters
// the line holds depends on where the live column breaks it.

/// An element's `::first-letter` rules: the entries of the book's rules that match it. The
/// pseudo-element wraps its letter immediately, even when that is in an inline box inside the
/// element, and inherits from that box (CSS Pseudo-Elements 4 §2.2.3), so its style is computed
/// where the writer meets the letter (`style(inheritingFrom:)`), not with the element's.
final class FirstLetterRules: Equatable, @unchecked Sendable {
    let entries: [Int]
    /// Weak: a style can outlive the build that computed it, which leaves it no letter to style.
    private weak var resolver: StyleResolver?

    init(entries: [Int], resolver: StyleResolver) {
        self.entries = entries; self.resolver = resolver
    }

    /// The pseudo-element's computed style for a letter in a box of style `parent`.
    func style(inheritingFrom parent: ComputedStyle) -> ComputedStyle {
        resolver?.firstLetterStyle(entries, parent: parent) ?? parent
    }

    static func == (lhs: FirstLetterRules, rhs: FirstLetterRules) -> Bool {
        lhs === rhs || (lhs.entries == rhs.entries && lhs.resolver === rhs.resolver)
    }
}

extension CSSProperty {
    /// What applies to a `::first-letter`: the font properties, `color`, the background, text
    /// decoration, `text-transform`, letter and word spacing, `line-height`, `float`,
    /// `vertical-align` (with no float), margins, padding and borders (CSS 2 §5.12.2, CSS
    /// Pseudo-Elements 4 §2.2.4). Of the others an inherited one is the box's around the
    /// letter, and the rest are initial, `display: inline` among them.
    var appliesToFirstLetter: Bool {
        switch self {
        case .fontSize, .fontFamily, .fontWeight, .fontStyle, .fontVariantCaps, .lineHeight, .color,
             .float, .marginTop, .marginRight, .marginBottom, .marginLeft,
             .paddingTop, .paddingRight, .paddingBottom, .paddingLeft,
             .borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle,
             .borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth,
             .borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor,
             .backgroundColor, .verticalAlign, .textDecorationLine, .textDecorationColor,
             .textTransform, .letterSpacing, .wordSpacing:
            true
        default: false
        }
    }
}
