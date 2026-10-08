import CoreText
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What an inline box contributes to its text beyond its own computed style.
struct InlineContext {
    var link: ReaderLink?
    /// The color the link element inherited. A book color that differs from it was set on the
    /// link or inside it, and wins over the palette's link color (as an `a:link` UA rule would).
    var linkBaseColor: ComputedStyle.Color?
    /// The nearest inline ancestor's background (block backgrounds are not drawn).
    var background: ComputedStyle.Color?
    /// Accumulated `vertical-align` shift, in points.
    var baselineOffset: CGFloat = 0
    /// BCP 47 language (`xml:lang`/`lang`, inherited).
    var language: String?
    /// `<q>` nesting, for alternating quotation marks.
    var quoteDepth = 0
}

/// Interns attribute dictionaries and paragraph styles for one build, and measures with CoreText
/// (thread-safe, unlike the platform string-drawing extensions).
final class InlineStyling {
    let fonts: FontRegistry
    let isDark: Bool
    private(set) var dictionaries: [CFDictionary] = []
    private var indices: [Key: Int] = [:]
    private var paragraphStyles: [ParagraphStyleKey: NSParagraphStyle] = [:]
    private var colors: [ComputedStyle.Color: PlatformColor] = [:]
    private var markerWidths: [MarkerKey: (font: PlatformFont, width: CGFloat)] = [:]
    private struct MarkerKey: Hashable { let font: ObjectIdentifier; let text: String }

    init(fonts: FontRegistry, isDark: Bool) { self.fonts = fonts; self.isDark = isDark }

    private enum ColorChoice: Hashable { case text, link, clear, book(ComputedStyle.Color) }
    private struct Key: Hashable {
        var font: ObjectIdentifier
        var color: ColorChoice
        var background: ComputedStyle.Color?
        var underline: Bool
        var strikethrough: Bool
        var decorationColor: ComputedStyle.Color?
        var baselineOffset: CGFloat
        var kern: CGFloat
        var oblique: Bool
        var embolden: Bool
        var language: String?
        var link: String?
    }

    static let languageKey = NSAttributedString.Key(kCTLanguageAttributeName as String)
    static let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

    /// The interned attribute dictionary for text in `style` under `context`; `wordSpacing` for
    /// its spaces, which `word-spacing` widens.
    func attributes(_ style: ComputedStyle, _ context: InlineContext, wordSpacing: Bool = false) -> Int {
        let font = fonts.font(for: style)
        let hidden = style.isHidden
        let link = hidden ? nil : context.link
        let color: ColorChoice
        if hidden { color = .clear }
        else if isDark { color = link == nil ? .text : .link }
        else if link != nil {
            color = style.color.flatMap { $0 != context.linkBaseColor ? ColorChoice.book($0) : nil } ?? .link
        } else { color = style.color.map(ColorChoice.book) ?? .text }
        let decorate = !hidden && !isDark
        let key = Key(font: ObjectIdentifier(font), color: color,
                      background: decorate ? context.background.flatMap { $0.alpha > 0 ? $0 : nil } : nil,
                      underline: !hidden && style.textDecoration.contains(.underline),
                      strikethrough: !hidden && style.textDecoration.contains(.lineThrough),
                      decorationColor: decorate ? style.textDecorationColor : nil,
                      baselineOffset: context.baselineOffset,
                      kern: style.letterSpacing + (wordSpacing ? style.wordSpacing : 0),
                      oblique: fonts.needsSyntheticItalic(for: style),
                      embolden: fonts.needsSyntheticBold(for: style),
                      language: context.language, link: link?.url.absoluteString)
        if let index = indices[key] { return index }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        switch key.color {
        case .text: attributes[.foregroundColor] = ReaderPalette.text(dark: isDark)
        case .link: attributes[.foregroundColor] = ReaderPalette.link(dark: isDark)
        case .clear: attributes[.foregroundColor] = PlatformColor.clear
        case .book(let value): attributes[.foregroundColor] = platformColor(value)
        }
        if let background = key.background { attributes[.backgroundColor] = platformColor(background) }
        if key.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let color = key.decorationColor { attributes[.underlineColor] = platformColor(color) }
        }
        if key.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            if let color = key.decorationColor { attributes[.strikethroughColor] = platformColor(color) }
        }
        if key.baselineOffset != 0 { attributes[.baselineOffset] = key.baselineOffset }
        if key.kern != 0 { attributes[.kern] = key.kern }
        if key.oblique { attributes[.obliqueness] = 0.2 }
        // A negative stroke width fills and strokes the glyphs: a face the family lacks, emboldened.
        if key.embolden { attributes[.strokeWidth] = -3.0 }
        if let language = key.language { attributes[Self.languageKey] = language }
        if let link { attributes[.link] = link.url }
        let index = dictionaries.count
        dictionaries.append(attributes as NSDictionary as CFDictionary)
        indices[key] = index
        return index
    }

    func platformColor(_ color: ComputedStyle.Color) -> PlatformColor {
        if let cached = colors[color] { return cached }
        #if os(macOS)
        let value = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        #else
        let value = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        #endif
        colors[color] = value
        return value
    }

    func paragraphStyle(_ key: ParagraphStyleKey) -> NSParagraphStyle {
        if let cached = paragraphStyles[key] { return cached }
        let style = NSMutableParagraphStyle()
        key.apply(to: style)
        paragraphStyles[key] = style
        return style
    }

    // MARK: Measuring

    /// A list marker's width in its item's font (cached: lists repeat their markers).
    func markerWidth(_ text: String, style: ComputedStyle) -> CGFloat {
        let font = fonts.font(for: style)
        let key = MarkerKey(font: ObjectIdentifier(font), text: text)
        if let cached = markerWidths[key] { return cached.width }
        let width = Self.width(of: text, font: font)
        markerWidths[key] = (font, width)
        return width
    }

    /// Typographic width of a string set in `font`.
    static func width(of string: String, font: PlatformFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: font]) as CFAttributedString)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The font's default line height (ascent + descent + leading), what `lineHeightMultiple`
    /// multiplies.
    static func naturalLineHeight(_ font: PlatformFont) -> CGFloat {
        let font = font as CTFont
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    /// Advance of U+0020, the unit of CSS `tab-size`.
    static func spaceAdvance(_ font: PlatformFont) -> CGFloat {
        let font = font as CTFont
        var character: UniChar = 0x20
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return CTFontGetSize(font) / 4 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }
}

/// Every value a builder paragraph style sets, so identical paragraphs share one style object.
struct ParagraphStyleKey: Hashable {
    var alignment: NSTextAlignment = .natural
    var direction: NSWritingDirection = .natural
    var firstLineHeadIndent: CGFloat = 0
    var headIndent: CGFloat = 0
    /// Distance from the trailing edge, positive (stored negated in the style).
    var tailInset: CGFloat = 0
    var spacingBefore: CGFloat = 0
    var spacingAfter: CGFloat = 0
    var lineHeightMultiple: CGFloat = 0
    var minimumLineHeight: CGFloat = 0
    var maximumLineHeight: CGFloat = 0
    var hyphenate = false
    var characterWrap = false
    /// A list marker's tab stop.
    var tabStop: CGFloat?
    /// `tab-size` in points; 0 keeps the default interval.
    var tabInterval: CGFloat = 0

    func apply(to style: NSMutableParagraphStyle) {
        style.alignment = alignment
        style.baseWritingDirection = direction
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        style.tailIndent = -tailInset
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineHeightMultiple = lineHeightMultiple
        style.minimumLineHeight = minimumLineHeight
        style.maximumLineHeight = maximumLineHeight
        style.hyphenationFactor = hyphenate ? 1 : 0
        style.lineBreakMode = characterWrap ? .byCharWrapping : .byWordWrapping
        style.tabStops = tabStop.map { [NSTextTab(textAlignment: .natural, location: $0)] } ?? []
        if tabInterval > 0 { style.defaultTabInterval = tabInterval }
    }
}
