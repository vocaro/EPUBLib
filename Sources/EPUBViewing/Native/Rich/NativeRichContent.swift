import EPUBCore
import EPUBReading
import Foundation
import StaticSVG
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
/// A table's result has several paragraphs (caption, then one per row) with their own
/// paragraph styles: no spacing between rows, and a 1 pt font so a row's line is exactly
/// its attachment's height. The builder should apply the table's margins to the first and last
/// paragraphs and keep the others' paragraph attributes.
struct NativeRichContent: RichContentFactory {
    let images: ReaderImageCache

    init(images: ReaderImageCache = .shared) { self.images = images }

    /// The most bytes an image in a `data:` URL may decode to: what the archive holds of one
    /// resource unless the host sets less, which bounds the document holding the URL as well.
    static let maximumDataURLBytes = EPUBImportLimits().resourceBytes

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
        // An empty `alt` marks decoration; an `<object>` or `<embed>` has no `alt` and is named by its title.
        var alternative = ImageAlternative(alt: element.attribute("alt"))
        if alternative == .missing, isObject || isEmbed { alternative = ImageAlternative(name: element.attribute("title")) }
        // What is shown when the image cannot be: its words, whatever the book says of its part.
        var alt = alternative.text
        // An `<object>` falls back to its own content, an image to its alt text.
        let fallback = { isObject ? nil : Self.altText(alt, style: style, context: context) }
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return fallback() }
        let found: (source: ReaderImageSource, intrinsic: CGSize, svg: SVGDocument?)?
        // The image's bytes where they are SVG, for its words and its disclosure if it is not drawn.
        let svgData: Data?, svgPath: String
        if let url = Self.imageDataURL(reference) {
            found = decodedImage(url, heldBy: element, style: style, context: context)
            svgData = Self.isSVG(url) ? url.body : nil
            svgPath = ""
        } else {
            guard let path = context.resolve(reference) else { return fallback() }
            found = resolvedImage(at: path, style: style, context: context)
            svgData = found == nil ? (try? context.publication.data(at: path)).flatMap { Self.isSVG($0, path: path, context: context) ? $0 : nil } : nil
            svgPath = path
        }
        guard let resolved = found else {
            if let svgData {
                context.report.report.unsupportedElements["svg", default: 0] += 1
                if alt.isEmpty, let document = try? ContentDocument.parse(svgData, path: svgPath, asContent: false),
                   let svg = SVGContent.document(document.root) {
                    alt = svg.fallbackText
                }
            } else { context.report.report.unreadableResources += 1 }
            return fallback()
        }
        let source = resolved.source
        var intrinsic = resolved.intrinsic
        if let svg = resolved.svg, alternative == .missing {
            alternative = ImageAlternative(name: svg.accessibleLabel)
        }
        if intrinsic.width <= 0 || intrinsic.height <= 0 { intrinsic = source.pixelSize }
        let sizing = ImageSizing(intrinsic: intrinsic, style: style, widthHint: element.attribute("width"),
                                 heightHint: element.attribute("height"))
        return attachment(ReaderImageAttachment(source: source, sizing: sizing, alternative: alternative, style: style,
                                                isDark: context.typography.isDark,
                                                isHiddenFromAssistiveTechnology: ContentSemantics.isHiddenFromAssistiveTechnology(element),
                                                cache: images),
                          style: style, context: context)
    }

    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        // Nothing to draw is no failure to draw: no picture, no words in its place and no notice
        // (#136).
        if SVGContent.drawsNothing(element) { return NSAttributedString() }
        // The content document's limits bound the element, so StaticSVG takes any it holds.
        guard let drawing = SVGContent.document(element) else {
            context.report.report.unsupportedElements["svg", default: 0] += 1
            return Self.altText("Illustration unavailable", style: style, context: context)
        }
        let title = drawing.accessibleLabel ?? ""
        // Prefer authored title/description, then drawing labels, when it cannot be shown.
        let nothing = { Self.altText(drawing.fallbackText, style: style, context: context) ?? NSAttributedString() }
        SVGContent.disclose(drawing, report: context.report)
        let widthHint = element.attribute("width"), heightHint = element.attribute("height")
        // A reference to a fragment of the drawing's own document names no file. Its `#` is
        // found as its byte: as a `Character`, one before a combining mark is another character.
        if let image = SVGContent.wrappedImage(element), let reference = SVGContent.href(image), reference.utf8.first != 0x23 { // #
            let found: (source: ReaderImageSource, intrinsic: CGSize, svg: SVGDocument?)?
            if let url = Self.imageDataURL(reference) {
                found = decodedImage(url, heldBy: image, style: style, context: context)
            } else {
                guard let path = context.resolve(reference) else { return nothing() }
                found = resolvedImage(at: path, style: style, context: context)
            }
            guard let resolved = found else {
                context.report.report.unreadableResources += 1
                return nothing()
            }
            let source = resolved.source
            let intrinsic = SVGContent.intrinsicSize(element, fontSize: style.fontSize, fallback: source.pixelSize)
            let sizing = ImageSizing(intrinsic: intrinsic, style: style, widthHint: widthHint, heightHint: heightHint)
            let placement = SVGContent.placement(of: image, in: element, source: source, fontSize: style.fontSize)
            let alternative = title.isEmpty ? ImageAlternative(alt: image.attribute("alt")) : .text(title)
            // The drawing is kept from assistive technology, or the image it shows where that
            // gives its words, its `alt`.
            let hidden = ContentSemantics.isHiddenFromAssistiveTechnology(element)
                || (title.isEmpty && ContentSemantics.isHiddenFromAssistiveTechnology(image))
            return attachment(ReaderImageAttachment(source: source, sizing: sizing, alternative: alternative, style: style,
                                                    contentRect: placement, isDark: context.typography.isDark,
                                                    isHiddenFromAssistiveTechnology: hidden, cache: images),
                              style: style, context: context)
        }
        let key = context.publication.id + "\u{0}" + context.document.path + "\u{0}\(element.order)"
        let fonts = context.fonts.svgFonts(families: drawing.fontFamilies)
        if fonts.strippedColorGlyphs { context.report.report.unsupportedElements[SVGDiagnostics.Kind.colorGlyphs.rawValue, default: 0] += 1 }
        guard let data = SVGContent.serialize(drawing, resolve: context.resolve, publication: context.publication,
                                             fontAliases: fonts.aliases, report: context.report),
              let source = ReaderImageSource.svg(data, path: "", key: key, fonts: fonts.fonts) else {
            context.report.report.unsupportedElements["svg", default: 0] += 1
            return nothing()
        }
        let intrinsic = SVGContent.intrinsicSize(element, fontSize: style.fontSize, fallback: source.pixelSize)
        let sizing = ImageSizing(intrinsic: intrinsic, style: style, widthHint: widthHint, heightHint: heightHint)
        return attachment(ReaderImageAttachment(source: source, sizing: sizing, alternative: ImageAlternative(name: title), style: style,
                                                isDark: context.typography.isDark,
                                                isHiddenFromAssistiveTechnology: ContentSemantics.isHiddenFromAssistiveTechnology(element),
                                                cache: images),
                          style: style, context: context)
    }

    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        TableContent.make(element, style: style, context: context)
    }

    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        MathContent.make(element, style: style, context: context, images: images)
    }

    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        attachment(ReaderRuleAttachment(style: style, theme: context.typography.theme,
                                        isHiddenFromAssistiveTechnology: ContentSemantics.isHiddenFromAssistiveTechnology(element)),
                   style: style, context: context)
    }

    // MARK: Helpers

    private func attachment(_ attachment: NSTextAttachment, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        NSAttributedString(attachment: attachment, attributes: [.font: context.fonts.font(for: style)])
    }

    /// Decode the first usable supported image in the designated manifest chain. A missing,
    /// remote, foreign, or corrupt hop does not prevent trying a later one. Failed attempts
    /// produce no image-loss disclosure when another resource supplies the image.
    func resolvedImage(at path: String, style: ComputedStyle, context: RichContentContext)
        -> (source: ReaderImageSource, intrinsic: CGSize, svg: SVGDocument?)? {
        let candidates: [String]
        if let original = context.publication.manifestResource(at: path) {
            candidates = NativeFallbacks.resources(for: original, in: context.publication)
                .filter(NativeFallbacks.isImage).map(\.path)
        } else { candidates = [path] }
        for candidate in candidates {
            guard !ResourceReference.isRemote(candidate), let data = try? context.publication.data(at: candidate) else { continue }
            if let image = decodedImage(data, path: candidate, isSVG: Self.isSVG(data, path: candidate, context: context),
                                        key: context.publication.id + "\u{0}" + candidate, style: style, context: context) {
                return image
            }
        }
        return nil
    }

    /// The image a document holds itself in a `data:` URL, as EPUB 3.3 §3.7 permits: nil where the
    /// reference is no `data:` URL, and where the URL's type, which stands for a manifest's, is
    /// not an image's. `resolve` counts such a `data:` URL unreadable (#134).
    private static func imageDataURL(_ reference: String) -> DataURL? {
        guard let url = DataURL(reference, maximumBytes: maximumDataURLBytes), url.mediaType.hasPrefix("image/") else { return nil }
        return url
    }

    private static func isSVG(_ url: DataURL) -> Bool {
        ImageType.mediaType(of: url.body) == nil && ImageType.isSVG(url.body, path: "", mediaType: url.mediaType)
    }

    /// The image in a `data:` URL, shown and bounded as one in the archive is. It has no path: it
    /// is known by the position of `element`, the element that holds the URL (an `<img>`, or the
    /// `<image>` an SVG wraps, #657).
    private func decodedImage(_ url: DataURL, heldBy element: ContentNode, style: ComputedStyle,
                              context: RichContentContext) -> (source: ReaderImageSource, intrinsic: CGSize, svg: SVGDocument?)? {
        let key = context.publication.id + "\u{0}" + context.document.path + "\u{0}\(element.order)"
        return decodedImage(url.body, path: "", isSVG: Self.isSVG(url), key: key, style: style, context: context)
    }

    /// An image's bytes as the reader draws them: SVG sanitized for the static renderer, or a
    /// bitmap ImageIO reads. An SVG that cannot be drawn leaves nothing in the report.
    private func decodedImage(_ data: Data, path: String, isSVG: Bool, key: String, style: ComputedStyle,
                              context: RichContentContext) -> (source: ReaderImageSource, intrinsic: CGSize, svg: SVGDocument?)? {
        if isSVG {
            let before = context.report.report
            guard let (source, root, svg) = svgDocument(data, path: path, key: key, context: context) else {
                context.report.report = before
                return nil
            }
            return (source, SVGContent.intrinsicSize(root, fontSize: style.fontSize, fallback: source.pixelSize), svg)
        }
        guard let source = ReaderImageSource.bitmap(data, path: path, key: key) else { return nil }
        return (source, source.pixelSize, nil)
    }

    /// An SVG resource as a sanitized document the static renderer can draw, and its root. One
    /// with no path, from a `data:` URL, has no base a reference in it resolves against, as the
    /// URL Standard parses none against a `data:` URL.
    private func svgDocument(_ data: Data, path: String, key: String,
                             context: RichContentContext) -> (ReaderImageSource, ContentNode, SVGDocument)? {
        guard let (root, svg) = SVGContent.document(data, path: path) else { return nil }
        SVGContent.disclose(svg, report: context.report)
        let resolve: (String) -> String? = { reference in
            guard !path.isEmpty else { return nil }
            guard let resolved = try? ResourceReference.resolve(reference, relativeTo: path) else {
                context.report.report.remoteResourcesRefused += 1
                return nil
            }
            let file = String(resolved.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
            return file.removingPercentEncoding ?? file
        }
        let fonts = context.fonts.svgFonts(families: svg.fontFamilies)
        if fonts.strippedColorGlyphs { context.report.report.unsupportedElements[SVGDiagnostics.Kind.colorGlyphs.rawValue, default: 0] += 1 }
        guard let serialized = SVGContent.serialize(svg, resolve: resolve, publication: context.publication,
                                                   fontAliases: fonts.aliases, report: context.report),
              let source = ReaderImageSource.svg(serialized, path: path, key: key, fonts: fonts.fonts) else { return nil }
        return (source, root, svg)
    }

    /// Bitmaps are known by their first bytes, so the manifest is only searched for the rest.
    private static func isSVG(_ data: Data, path: String, context: RichContentContext) -> Bool {
        guard ImageType.mediaType(of: data) == nil else { return false }
        return ImageType.isSVG(data, path: path, mediaType: context.publication.resources.first { $0.path == path }?.mediaType)
    }

    /// The words shown in place of an image that cannot be, in the image's style: a hidden
    /// image's keep its room and are not drawn either.
    private static func altText(_ alt: String, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        guard !alt.isEmpty else { return nil }
        return NSAttributedString(string: alt, attributes: [
            .font: context.fonts.font(for: style),
            .foregroundColor: style.isHidden ? PlatformColor.clear : context.typography.theme.secondaryText,
        ])
    }
}
