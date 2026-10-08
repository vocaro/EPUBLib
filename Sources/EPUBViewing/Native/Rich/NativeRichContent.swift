import EPUBCore
import EPUBReading
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The production rich-content factory: images, SVG, tables and rules become the reader's own
/// attachments, sized at layout from the `ReaderTextContainer` and decoded only when drawn;
/// MathML goes to `MathContent`. Colors follow `context.typography.isDark` (a section is
/// rebuilt when the appearance changes).
///
/// A table's result has several paragraphs (caption, then one per row unit) with their own
/// paragraph styles: no spacing between row units, and a 1 pt font so a row's line is exactly
/// its attachment's height. The builder should apply the table's margins to the first and last
/// paragraphs and keep the others' paragraph attributes.
struct NativeRichContent: RichContentFactory {
    let images: ReaderImageCache

    init(images: ReaderImageCache = .shared) { self.images = images }

    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        let isObject = element.isHTML("object"), isEmbed = element.isHTML("embed")
        let reference: String?
        if isObject || isEmbed {
            if let type = element.attribute("type")?.lowercased(), !type.hasPrefix("image/") { return nil }
            reference = element.attribute(isObject ? "data" : "src")
        } else if !element.isHTML {
            reference = SVGContent.href(element)
        } else {
            reference = element.attribute("src")
        }
        let alt = Self.normalized(element.attribute("alt") ?? (isObject || isEmbed ? element.attribute("title") : nil) ?? "")
        // An `<object>` falls back to its own content, an image to its alt text.
        let fallback = { isObject ? nil : Self.altText(alt, style: style, context: context) }
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty,
              let path = context.resolve(reference) else { return fallback() }
        guard let data = try? context.publication.data(at: path) else {
            context.report.report.unreadableResources += 1
            return fallback()
        }
        let key = context.publication.id + "\u{0}" + path
        let source: ReaderImageSource
        var intrinsic: CGSize
        if Self.isSVG(data, path: path, context: context) {
            guard let (svg, root) = svgDocument(data, path: path, key: key, context: context) else {
                context.report.report.unsupportedElements["svg", default: 0] += 1
                return fallback()
            }
            source = svg
            intrinsic = SVGContent.intrinsicSize(root, fontSize: style.fontSize, fallback: svg.pixelSize)
        } else {
            guard let bitmap = ReaderImageSource.bitmap(data, path: path, key: key) else {
                context.report.report.unreadableResources += 1
                return fallback()
            }
            source = bitmap
            intrinsic = bitmap.pixelSize
        }
        if intrinsic.width <= 0 || intrinsic.height <= 0 { intrinsic = source.pixelSize }
        let sizing = ImageSizing(intrinsic: intrinsic, style: style, widthHint: element.attribute("width"),
                                 heightHint: element.attribute("height"))
        return attachment(ReaderImageAttachment(source: source, sizing: sizing, alt: alt, style: style, cache: images),
                          style: style, context: context)
    }

    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        let title = SVGContent.title(element) ?? ""
        // Nothing at all rather than the drawing's text content, when it cannot be shown.
        let nothing = { Self.altText(title, style: style, context: context) ?? NSAttributedString() }
        let widthHint = element.attribute("width"), heightHint = element.attribute("height")
        if let image = SVGContent.wrappedImage(element), let reference = SVGContent.href(image), !reference.hasPrefix("#") {
            guard let path = context.resolve(reference) else { return nothing() }
            let key = context.publication.id + "\u{0}" + path
            guard let data = try? context.publication.data(at: path) else {
                context.report.report.unreadableResources += 1
                return nothing()
            }
            let source = Self.isSVG(data, path: path, context: context)
                ? svgDocument(data, path: path, key: key, context: context)?.0
                : ReaderImageSource.bitmap(data, path: path, key: key)
            guard let source else {
                context.report.report.unreadableResources += 1
                return nothing()
            }
            let intrinsic = SVGContent.intrinsicSize(element, fontSize: style.fontSize, fallback: source.pixelSize)
            let sizing = ImageSizing(intrinsic: intrinsic, style: style, widthHint: widthHint, heightHint: heightHint)
            let placement = SVGContent.placement(of: image, in: element, imageSize: source.pixelSize, fontSize: style.fontSize)
            let alt = title.isEmpty ? Self.normalized(image.attribute("alt") ?? "") : title
            return attachment(ReaderImageAttachment(source: source, sizing: sizing, alt: alt, style: style,
                                                    contentRect: placement, cache: images),
                              style: style, context: context)
        }
        let key = context.publication.id + "\u{0}" + context.document.path + "\u{0}\(element.order)"
        guard let data = SVGContent.serialize(element, resolve: context.resolve, publication: context.publication),
              let source = ReaderImageSource.svg(data, path: "", key: key) else {
            context.report.report.unsupportedElements["svg", default: 0] += 1
            return nothing()
        }
        let intrinsic = SVGContent.intrinsicSize(element, fontSize: style.fontSize, fallback: source.pixelSize)
        let sizing = ImageSizing(intrinsic: intrinsic, style: style, widthHint: widthHint, heightHint: heightHint)
        return attachment(ReaderImageAttachment(source: source, sizing: sizing, alt: title, style: style, cache: images),
                          style: style, context: context)
    }

    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        TableContent.make(element, style: style, context: context)
    }

    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        MathContent.make(element, style: style, context: context)
    }

    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        attachment(ReaderRuleAttachment(style: style, isDark: context.typography.isDark), style: style, context: context)
    }

    // MARK: Helpers

    private func attachment(_ attachment: NSTextAttachment, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        NSAttributedString(attachment: attachment, attributes: [.font: context.fonts.font(for: style)])
    }

    /// An SVG resource as a sanitized document the platform decoder can draw, and its root.
    private func svgDocument(_ data: Data, path: String, key: String,
                             context: RichContentContext) -> (ReaderImageSource, ContentNode)? {
        guard let document = try? ContentDocument.parse(data, path: path),
              SVGContent.isSVG(document.root, root: document.root), document.root.name == "svg" else { return nil }
        let resolve: (String) -> String? = { reference in
            guard let resolved = try? ResourceReference.resolve(reference, relativeTo: path) else {
                context.report.report.remoteResourcesRefused += 1
                return nil
            }
            let file = String(resolved.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
            return file.removingPercentEncoding ?? file
        }
        guard let serialized = SVGContent.serialize(document.root, resolve: resolve, publication: context.publication),
              let source = ReaderImageSource.svg(serialized, path: path, key: key) else { return nil }
        return (source, document.root)
    }

    /// Bitmaps are known by their first bytes, so the manifest is only searched for the rest.
    private static func isSVG(_ data: Data, path: String, context: RichContentContext) -> Bool {
        guard ImageType.mediaType(of: data) == nil else { return false }
        return ImageType.isSVG(data, path: path, mediaType: context.publication.resources.first { $0.path == path }?.mediaType)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func altText(_ alt: String, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        guard !alt.isEmpty else { return nil }
        return NSAttributedString(string: alt, attributes: [
            .font: context.fonts.font(for: style),
            .foregroundColor: ReaderPalette.secondaryText(dark: context.typography.isDark),
        ])
    }
}
