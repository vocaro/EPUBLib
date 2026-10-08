import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// SKELETON: a minimal stand-in so the builder and views can run before the CSS engine lands.
// The style workstream replaces this file's internals (and adds a real parser, cascade and
// user-agent stylesheet) without changing the API below.

/// A parsed, bounded author stylesheet.
struct CSSStyleSheet: Sendable {
    static let empty = CSSStyleSheet()
    /// `@font-face` rules, sources resolved to archive paths.
    var fontFaces: [CSSFontFace] = []
}

struct CSSFontFace: Equatable, Sendable {
    /// Lowercased, unquoted.
    var family: String
    /// `font-weight` range the face covers.
    var weights: ClosedRange<Int> = 400...400
    var isItalic = false
    /// Decoded archive paths, in preference order. Remote sources are dropped (and counted).
    var sources: [String] = []
}

enum SectionStyles {
    /// The author stylesheets of a content document in cascade order: `<link rel="stylesheet">`
    /// to archive resources and `<style>` elements, with `@import` followed within the archive and
    /// bounded. Remote references are counted into `report` and never fetched.
    static func load(for document: ContentDocument, publication: EPUBPublication,
                     report: inout SectionReport) -> [CSSStyleSheet] {
        []
    }
}

/// Computes styles for one content document: user-agent defaults, then author sheets in order,
/// then `style` attributes, honouring `!important`, specificity and inheritance.
final class StyleResolver: @unchecked Sendable {
    let typography: NativeTypography
    let document: ContentDocument

    init(document: ContentDocument, stylesheets: [CSSStyleSheet], typography: NativeTypography) {
        self.document = document; self.typography = typography
    }

    /// What the root element inherits: the reader's own defaults.
    var initialStyle: ComputedStyle {
        var style = ComputedStyle()
        style.fontSize = typography.fontSize
        style.fontFamilies = ["serif"]
        style.lineHeight = .multiple(1.4)
        style.hyphens = .auto
        return style
    }

    /// The computed style of `element`, given its parent's computed style.
    func style(for element: ContentNode, parent: ComputedStyle) -> ComputedStyle {
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
        style.textDecoration = parent.textDecoration
        guard element.isHTML else {
            if element.namespace == ContentNamespace.mathML, element.name == "math" {
                style.display = element.attribute("display") == "block" ? .block : .inline
            }
            if element.namespace == ContentNamespace.svg, element.name == "svg" { style.display = .inline }
            return style
        }
        let em = parent.fontSize
        switch element.name {
        case "head", "script", "style", "title", "meta", "link", "template", "rp", "noscript": style.display = .none
        case "html", "body", "div", "section", "article", "main", "header", "footer", "nav", "aside",
             "address", "figure", "figcaption", "details", "summary", "hgroup", "center", "fieldset":
            style.display = .block
            if element.name == "figure" { style.margin = .init(top: .points(em), right: .points(40), bottom: .points(em), left: .points(40)) }
            if element.name == "center" { style.textAlign = .center }
        case "p", "dl", "pre":
            style.display = .block
            style.margin.top = .points(em); style.margin.bottom = .points(em)
            if element.name == "pre" { style.whiteSpace = .pre; style.fontFamilies = ["monospace"] }
        case "blockquote":
            style.display = .block
            style.margin = .init(top: .points(em), right: .points(40), bottom: .points(em), left: .points(40))
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let scale: [String: (CGFloat, CGFloat)] = ["h1": (2, 0.67), "h2": (1.5, 0.83), "h3": (1.17, 1),
                                                         "h4": (1, 1.33), "h5": (0.83, 1.67), "h6": (0.67, 2.33)]
            let (size, margin) = scale[element.name]!
            style.display = .block; style.fontWeight = 700; style.fontSize = em * size
            style.margin.top = .points(style.fontSize * margin); style.margin.bottom = .points(style.fontSize * margin)
        case "ul", "ol", "menu", "dir":
            style.display = .block
            style.margin.top = .points(em); style.margin.bottom = .points(em); style.padding.left = .points(40)
            style.listStyleType = element.name == "ol" ? .decimal : .disc
        case "li": style.display = .listItem
        case "dt": style.display = .block
        case "dd": style.display = .block; style.margin.left = .points(40)
        case "hr": style.display = .block; style.margin.top = .points(em / 2); style.margin.bottom = .points(em / 2)
        case "em", "i", "cite", "var", "dfn": style.isItalic = true
        case "strong", "b", "th": style.fontWeight = 700
        case "code", "kbd", "samp", "tt": style.fontFamilies = ["monospace"]
        case "u", "ins": style.textDecoration.insert(.underline)
        case "s", "strike", "del": style.textDecoration.insert(.lineThrough)
        case "small": style.fontSize = em * 0.83
        case "big": style.fontSize = em * 1.2
        case "sup": style.verticalAlign = .super; style.fontSize = em * 0.83
        case "sub": style.verticalAlign = .sub; style.fontSize = em * 0.83
        case "table": style.display = .table
        case "thead": style.display = .tableHeaderGroup
        case "tbody": style.display = .tableRowGroup
        case "tfoot": style.display = .tableFooterGroup
        case "tr": style.display = .tableRow
        case "td": style.display = .tableCell
        case "caption": style.display = .tableCaption; style.textAlign = .center
        case "col": style.display = .tableColumn
        case "colgroup": style.display = .tableColumnGroup
        case "ruby": style.display = .ruby
        case "rt": style.display = .rubyText
        default: break
        }
        if element.name == "th" { style.display = .tableCell; style.textAlign = .center }
        if let dir = element.attribute("dir")?.lowercased() { style.direction = dir == "rtl" ? .rtl : .ltr }
        if element.attribute("hidden") != nil { style.display = .none }
        return style
    }
}

/// Resolves computed font properties to platform fonts, including the book's `@font-face`
/// fonts (decoded from the archive, IDPF/Adobe obfuscation already removed by `EPUBReading`).
/// Thread-safe: sections build concurrently.
final class FontRegistry: @unchecked Sendable {
    private let publication: EPUBPublication
    private let lock = NSLock()
    private var cache: [FontKey: PlatformFont] = [:]
    private struct FontKey: Hashable { let families: [String]; let size: CGFloat; let weight: Int; let italic: Bool; let smallCaps: Bool }

    init(publication: EPUBPublication) { self.publication = publication }

    /// Registers a section's `@font-face` rules. Faces already registered are ignored.
    func register(_ faces: [CSSFontFace], report: inout SectionReport) {}

    func font(for style: ComputedStyle) -> PlatformFont {
        let key = FontKey(families: style.fontFamilies, size: style.fontSize, weight: style.fontWeight,
                          italic: style.isItalic, smallCaps: style.isSmallCaps)
        lock.lock(); defer { lock.unlock() }
        if let font = cache[key] { return font }
        let font = Self.systemFont(families: style.fontFamilies, size: style.fontSize,
                                   weight: style.fontWeight, italic: style.isItalic)
        cache[key] = font
        return font
    }

    static func systemFont(families: [String], size: CGFloat, weight: Int, italic: Bool) -> PlatformFont {
        let monospace = families.first { ["monospace", "courier", "courier new", "menlo", "monaco"].contains($0) } != nil
        let sans = families.first == "sans-serif" || families.first == "system-ui"
        #if os(iOS)
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight >= 600 ? .bold : .regular).fontDescriptor
        if monospace { descriptor = descriptor.withDesign(.monospaced) ?? descriptor }
        else if !sans { descriptor = descriptor.withDesign(.serif) ?? descriptor }
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor }
        return UIFont(descriptor: descriptor, size: size)
        #else
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight >= 600 ? .bold : .regular).fontDescriptor
        if monospace { descriptor = descriptor.withDesign(.monospaced) ?? descriptor }
        else if !sans { descriptor = descriptor.withDesign(.serif) ?? descriptor }
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        #endif
    }
}
