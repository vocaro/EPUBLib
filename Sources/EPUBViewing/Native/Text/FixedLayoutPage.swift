import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A pre-paginated spine item that is one image or one drawing, shown as a page at its declared
/// size ([#5](https://github.com/vocaro/EPUBLib/issues/5)): an XHTML document whose body shows
/// one raster image or one SVG, an SVG document, or a raster image in the spine. The section is
/// built as any other, and is a page when what it shows is that image's one attachment character
/// and nothing else. Its text is then that character alone, drawn as large as its line and the
/// reading viewport let it be with its aspect kept: a page column the size of the page fitted
/// into the spread (`ReaderCanvasGeometry.fixedPageFrames`), or the scroll's column in continuous
/// scroll. Any other pre-paginated section reflows, with the fixed-layout disclosure.
struct FixedLayoutPage: Equatable, Sendable {
    /// The page's size in CSS pixels: the width and height of the XHTML document's viewport
    /// `meta`, the SVG document's `viewBox`, or the raster image's pixels. A dimension the
    /// document does not declare is the image's, scaled to the one it does.
    let size: CGSize

    /// The page a built pre-paginated section is, and the text it is drawn from; nil when the
    /// section shows anything but one image or drawing, or shows it hidden.
    static func make(from string: NSAttributedString, document: ContentDocument) -> (page: FixedLayoutPage, string: NSAttributedString)? {
        guard string.length == 1, string.attribute(.readerHidden, at: 0, effectiveRange: nil) == nil,
              let image = string.attribute(.attachment, at: 0, effectiveRange: nil) as? ReaderImageAttachment,
              !image.isHidden, let size = declaredSize(of: document, image: image) else { return nil }
        let page = FixedLayoutPage(size: size)
        return (page, page.text(for: image, attributes: string.attributes(at: 0, effectiveRange: nil)))
    }

    /// The image as this page: one character, a block in a paragraph with no spacing and
    /// centered, as wide as its line and as tall as the reading viewport at the most.
    /// `attributes` are those of the image's character in the flow.
    func text(for image: ReaderImageAttachment, attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var sizing = ImageSizing(intrinsic: size)
        sizing.width = .percent(100)
        sizing.height = .viewportHeight(100)
        var style = ComputedStyle(fontSize: image.fontSize)
        style.display = .block
        style.invertsColors = image.invertsColors
        let page = ReaderImageAttachment(source: image.source, sizing: sizing, alternative: image.alternative, style: style,
                                         contentRect: image.contentRect, isDark: image.isDark,
                                         isHiddenFromAssistiveTechnology: image.isHiddenFromAssistiveTechnology,
                                         language: image.language, cache: image.cache)
        var attributes = attributes
        // The image's own box, its paragraph's spacing and indents and the box plan around it
        // were for a flow that a page does not have.
        for key in Self.flowKeys { attributes[key] = nil }
        let font = attributes[.font] as? PlatformFont ?? PlatformFont.systemFont(ofSize: image.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.defaultTabInterval = InlineStyling.tabInterval(font)
        attributes[.font] = font
        attributes[.paragraphStyle] = paragraph
        attributes[.attachment] = page
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }

    /// What the flow put on the image's character that a page leaves out.
    private static let flowKeys: [NSAttributedString.Key] = [
        .paragraphStyle, .baselineOffset, .kern, .readerParagraphSizing, .readerAlignment, .readerAlignmentLead,
        .readerPageBreakBefore, .readerKeepWithNext, .readerFlowBox, .readerParagraphFlow, .readerBoxPage, .readerClear,
    ]

    /// The size the document declares for its page, else the image's own.
    private static func declaredSize(of document: ContentDocument, image: ReaderImageAttachment) -> CGSize? {
        let natural = [image.sizing.intrinsic, image.source.pixelSize].first { $0.width > 0 && $0.height > 0 }
        let declared: (width: CGFloat?, height: CGFloat?)
        switch document.origin {
        case .syntheticRaster:
            declared = (nil, nil)
        case .authored where document.root.isElement && document.root.name == "svg" && !document.root.isHTML:
            // EPUB 3.3 has an SVG page's viewBox give its size.
            let box = SVGContent.viewBox(document.root)?.size
            declared = (box?.width, box?.height)
        case .authored:
            declared = viewport(of: document)
        }
        let size: CGSize?
        switch (declared.width, declared.height, natural) {
        case let (width?, height?, _): size = CGSize(width: width, height: height)
        case let (width?, nil, natural?): size = CGSize(width: width, height: width * natural.height / natural.width)
        case let (nil, height?, natural?): size = CGSize(width: height * natural.width / natural.height, height: height)
        default: size = natural
        }
        guard let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// The width and height an XHTML document's viewport `meta` declares, in CSS pixels: the
    /// first `meta` named `viewport` in its head, read as the W3C's reading-system tests have a
    /// reading system read it (`viewport(content:)`).
    static func viewport(of document: ContentDocument) -> (width: CGFloat?, height: CGFloat?) {
        guard let meta = document.head?.elementChildren.first(where: {
            $0.isHTML("meta") && $0.attribute("name")?.trimmingCharacters(in: .whitespaces).lowercased() == "viewport"
        }) else { return (nil, nil) }
        return viewport(content: meta.attribute("content") ?? "")
    }

    /// `width` and `height` from a viewport `meta`'s `content`: the first of each, whatever else
    /// it holds and whether commas, semicolons or white space separate its properties; a unit
    /// after a number is ignored, the number being pixels; `device-width`, `device-height` and
    /// anything that is not a positive number declare nothing. The W3C's `lay-fxl-xhtml-icb_*`
    /// tests hold a reading system to each.
    static func viewport(content: String) -> (width: CGFloat?, height: CGFloat?) {
        let properties = content.replacingOccurrences(of: #"[,;]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*=\s*"#, with: "=", options: .regularExpression)
        var width: CGFloat??, height: CGFloat??
        for property in properties.split(whereSeparator: \.isWhitespace) {
            let parts = property.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].lowercased(), value = pixels(String(parts[1]))
            if name == "width", width == nil { width = .some(value) }
            if name == "height", height == nil { height = .some(value) }
        }
        return (width ?? nil, height ?? nil)
    }

    /// The number a viewport value begins with, read as pixels; nil when it begins with none
    /// or that number is not positive and finite.
    private static func pixels(_ value: String) -> CGFloat? {
        let number = value.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard let amount = Double(number), amount.isFinite, amount > 0 else { return nil }
        return CGFloat(min(amount, 100_000))
    }
}
