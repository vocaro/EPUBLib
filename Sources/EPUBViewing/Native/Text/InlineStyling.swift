import CoreText
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The two languages text is written in. A content document that declares no language is not
/// in the package's (EPUB Reading Systems 3.3 §3.7), so what the reader generates from language
/// follows `declared` alone. Typesetting has to choose glyphs for some language anyway, and
/// takes the package's as a hint.
struct InlineLanguage: Hashable {
    /// BCP 47 language the content declares (`xml:lang`/`lang`, inherited); nil when it declares
    /// none, or declares it unknown (`lang=""`). Quotation marks and case mapping follow it.
    var declared: String?
    /// The package's first `dc:language`, until the content declares a language of its own,
    /// the unknown one included.
    var hint: String?

    /// The language CoreText chooses glyphs for (`InlineStyling.languageKey`).
    var typesetting: String? { declared ?? hint }

    /// `xml:lang`/`lang` on an element: its language from here down, in place of the hint.
    mutating func declare(_ language: String) {
        declared = language.isEmpty ? nil : language
        hint = nil
    }

    /// The language an assistive technology is to choose a voice for from `tag`, which is
    /// `typesetting` or a language found the same way: nil for an empty tag, and for the tags
    /// for undetermined, uncoded, multiple and no linguistic content, which name no voice.
    static func spoken(_ tag: String) -> String? {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = tag.split(separator: "-").first.map { $0.lowercased() } ?? ""
        return primary.isEmpty || ["und", "mis", "mul", "zxx"].contains(primary) ? nil : tag
    }
}

extension NSAttributedString.Key {
    /// `true` on every character of text in the flow that `visibility: hidden` or `collapse`
    /// hides, generated text and the break that ends a hidden paragraph included. The text
    /// keeps its characters and so its room, drawn in a clear colour; what is read of it
    /// leaves them out (`NSAttributedString.readerPlainText(in:)`, `readerBlankingHidden`).
    static let readerHidden = NSAttributedString.Key("org.epublib.hidden")
    /// `true` on every character of shown text that the book keeps from assistive technology
    /// with `aria-hidden="true"` on its element or on one round it, generated text included.
    /// It is drawn, copied and found as any text is, and VoiceOver is not given it
    /// (`NSAttributedString.readerPlainText(in:spoken:)`, `readerBlankingHidden`). An image, a
    /// rule or a formula knows for itself that it is kept so.
    static let readerUnspoken = NSAttributedString.Key("org.epublib.unspoken")
}

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
    /// The content's language (`xml:lang`/`lang`, inherited) and the package's as a hint.
    var language = InlineLanguage()
    /// `aria-hidden="true"` on the element or on one round it: its text is `.readerUnspoken`.
    var isUnspoken = false
}

/// Interns attribute dictionaries and paragraph styles for one build, and measures with CoreText
/// (thread-safe, unlike the platform string-drawing extensions).
final class InlineStyling {
    let fonts: FontRegistry
    /// The colours text without a book colour of its own takes, and in a dark theme all text.
    let theme: ReaderTheme
    var isDark: Bool { theme.isDark }
    private(set) var dictionaries: [CFDictionary] = []
    private var indices: [Key: Int] = [:]
    private var paragraphStyles: [ParagraphStyleKey: NSParagraphStyle] = [:]
    private var colors: [ComputedStyle.Color: PlatformColor] = [:]
    private var markerWidths: [MarkerKey: (font: PlatformFont, width: CGFloat)] = [:]
    private struct MarkerKey: Hashable { let font: ObjectIdentifier; let text: String }

    init(fonts: FontRegistry, theme: ReaderTheme) { self.fonts = fonts; self.theme = theme }

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
        var unspoken: Bool
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
                      language: context.language.typesetting, link: link?.url.absoluteString,
                      unspoken: context.isUnspoken && !hidden)
        if let index = indices[key] { return index }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        switch key.color {
        case .text: attributes[.foregroundColor] = theme.text
        case .link: attributes[.foregroundColor] = theme.link
        case .clear:
            attributes[.foregroundColor] = PlatformColor.clear
            attributes[.readerHidden] = true
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
        if key.unspoken { attributes[.readerUnspoken] = true }
        let index = dictionaries.count
        dictionaries.append(attributes as NSDictionary as CFDictionary)
        indices[key] = index
        return index
    }

    /// Interns attributes taken from rich content, for generated text that continues it.
    func intern(_ attributes: [NSAttributedString.Key: Any]) -> Int {
        dictionaries.append(attributes as NSDictionary as CFDictionary)
        return dictionaries.count - 1
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

    /// The default tab interval of a paragraph set in `font`: CSS's initial `tab-size`, eight
    /// spaces.
    static func tabInterval(_ font: PlatformFont) -> CGFloat { tabInterval(8 * spaceAdvance(font)) }

    /// The default tab interval of a paragraph whose box has `style`, set in `font`: its
    /// `tab-size` (CSS Text 3 §4.2), a number of spaces each as wide as the box's own with its
    /// letter and word spacing, or a length.
    static func tabInterval(_ style: ComputedStyle, font: PlatformFont) -> CGFloat {
        switch style.tabSize {
        case .spaces(let count): tabInterval(count * (spaceAdvance(font) + style.letterSpacing + style.wordSpacing))
        case .points(let points): tabInterval(points)
        }
    }

    /// `interval` as a default tab interval: at least a point, whatever a font's space or a
    /// marker measures. No paragraph style the builder makes is without one. TextKit cannot
    /// place a tab that has neither a stop after it nor an interval: in a plain container it
    /// ends the paragraph at the tab, so the rest gets no line, and in a container with boxes
    /// it asks for the next line down without end.
    static func tabInterval(_ interval: CGFloat) -> CGFloat { interval.isFinite && interval >= 1 ? interval : 1 }
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
    /// The interval of the tabs no stop is ahead of (`InlineStyling.tabInterval`).
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
        style.defaultTabInterval = InlineStyling.tabInterval(tabInterval)
    }
}
