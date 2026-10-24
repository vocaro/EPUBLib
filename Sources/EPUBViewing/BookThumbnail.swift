import CoreGraphics
import CoreText
import EPUBCore
import EPUBReading
import Foundation
import ImageIO
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A book's cover at the size Quick Look asks a thumbnail extension's `QLThumbnailProvider` for,
/// or, for a book with no cover that can be drawn, a title page made from its title and authors.
///
/// The book is opened on demand, so the cover is the one resource read besides the documents
/// that describe the book, and the cover is decoded downsampled, to at most the pixels the
/// thumbnail has: the memory a thumbnail takes is the archive's bytes, the cover's and the
/// thumbnail's own pixels (`doc/native-viewer.md`, "Quick Look").
public struct EPUBThumbnail: @unchecked Sendable {
    /// What a thumbnail shows.
    public enum Content: Equatable, Sendable {
        /// The book's cover image.
        case cover
        /// A page made of the book's title and authors.
        case titlePage
    }

    /// The most pixels a thumbnail has on its long side, whatever size and scale are asked for.
    public static let maximumPixelSize = 2_048

    public let content: Content
    /// The thumbnail's size in points: the largest within the size asked for in the cover's
    /// proportions, or a title page's 2:3. Give it to Quick Look as the reply's context size.
    public let size: CGSize
    /// The points per pixel the cover was decoded for.
    public let scale: CGFloat
    public let title: String
    public let authors: [String]
    /// The cover, decoded to no more pixels than `size` at `scale` holds; nil for a title page.
    public let image: CGImage?

    /// Opens the book at `url` on demand and draws its cover, or its title page, within
    /// `maximumSize` points at `scale` pixels a point. Call it off the main actor.
    public init(contentsOf url: URL, maximumSize: CGSize, scale: CGFloat = 1,
                limits: EPUBImportLimits = .quickLook) throws {
        let publication = try EPUBPublication.open(at: url, limits: limits, onDemand: true)
        self.init(publication: publication, maximumSize: maximumSize, scale: scale)
    }

    /// The thumbnail of a book already open. Of its resources only the cover is read.
    public init(publication: EPUBPublication, maximumSize: CGSize, scale: CGFloat = 1) {
        let bounds = CGSize(width: Self.finite(maximumSize.width), height: Self.finite(maximumSize.height))
        self.scale = min(max(scale.isFinite ? scale : 1, 1), 4)
        title = publication.metadata.title
        authors = publication.metadata.authors
        if let source = Self.coverSource(of: publication) {
            let fitted = Self.fit(source.pixelSize, in: bounds)
            let pixels = Int(min((max(fitted.width, fitted.height) * self.scale).rounded(.up), CGFloat(Self.maximumPixelSize)))
            if let decoded = source.decode(maxPixelSize: max(1, pixels)) {
                content = .cover
                size = Self.fit(CGSize(width: decoded.width, height: decoded.height), in: bounds)
                image = decoded
                return
            }
        }
        content = .titlePage
        size = Self.fit(CGSize(width: 2, height: 3), in: bounds)
        image = nil
    }

    /// Draws the thumbnail over the rectangle of `size` at the context's origin, in Core
    /// Graphics coordinates, whose origin is at the lower left: as the context
    /// `QLThumbnailReply(contextSize:drawing:)` gives its block. Returns true, for that block.
    @discardableResult
    public func draw(in context: CGContext) -> Bool {
        let rect = CGRect(origin: .zero, size: size)
        context.saveGState()
        defer { context.restoreGState() }
        if let image {
            context.interpolationQuality = .high
            context.draw(image, in: rect)
        } else {
            TitlePage(title: title, authors: authors).draw(in: context, rect: rect)
        }
        return true
    }

    /// The thumbnail as an image of `size` at `scale`, no more than `maximumPixelSize` pixels
    /// on its long side.
    public func makeImage() -> CGImage? {
        let factor = min(scale, CGFloat(Self.maximumPixelSize) / max(size.width, size.height, 1))
        let width = max(1, Int((size.width * factor).rounded())), height = max(1, Int((size.height * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        draw(in: context)
        return context.makeImage()
    }

    /// The cover's image as the reader would draw it: the cover resource or, when that is no
    /// image the reader can read, the first in its manifest fallback chain that is. An SVG
    /// cover is sanitized for the static renderer as an SVG in the book's text is, and reads
    /// no resource but the images it holds.
    static func coverSource(of publication: EPUBPublication) -> ReaderImageSource? {
        guard let cover = publication.cover else { return nil }
        for resource in publication.fallbackChain(for: cover) where NativeFallbacks.isImage(resource) {
            guard !ResourceReference.isRemote(resource.path), let data = try? publication.data(for: resource) else { continue }
            let key = publication.id + "\u{0}" + resource.path
            if ImageType.mediaType(of: data) == nil, ImageType.isSVG(data, path: resource.path, mediaType: resource.mediaType) {
                guard let (_, svg) = SVGContent.document(data, path: resource.path),
                      let serialized = SVGContent.serialize(svg, resolve: { reference in
                          guard let resolved = try? ResourceReference.resolve(reference, relativeTo: resource.path) else { return nil }
                          let file = String(resolved.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                          return file.removingPercentEncoding ?? file
                      }, publication: publication),
                      let source = ReaderImageSource.svg(serialized, path: resource.path, key: key) else { continue }
                return source
            }
            if let source = ReaderImageSource.bitmap(data, path: resource.path, key: key) { return source }
        }
        return nil
    }

    /// The largest size of `size`'s proportions within `bounds`, at least a point each way.
    static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let factor = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: max(1, size.width * factor), height: max(1, size.height * factor))
    }

    private static func finite(_ value: CGFloat) -> CGFloat {
        value.isFinite && value >= 1 ? min(value, CGFloat(maximumPixelSize)) : 1
    }
}

/// A plain title page: the title and the authors, centered on paper with a ruled border.
struct TitlePage {
    let title: String
    let authors: [String]

    static let paper = CGColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 1)
    static let rule = CGColor(srgbRed: 0.55, green: 0.5, blue: 0.42, alpha: 1)
    static let ink = CGColor(srgbRed: 0.16, green: 0.14, blue: 0.12, alpha: 1)
    static let secondaryInk = CGColor(srgbRed: 0.36, green: 0.33, blue: 0.29, alpha: 1)

    func draw(in context: CGContext, rect: CGRect) {
        context.setFillColor(Self.paper)
        context.fill(rect)
        let unit = min(rect.width, rect.height)
        context.setStrokeColor(Self.rule)
        context.setLineWidth(max(0.5, unit * 0.012))
        context.stroke(rect.insetBy(dx: unit * 0.06, dy: unit * 0.06))
        let textRect = rect.insetBy(dx: unit * 0.13, dy: unit * 0.13)
        guard textRect.width > 1, textRect.height > 1 else { return }
        // The largest type the words fit at, a step at a time, down to a size that still
        // reads; at the smallest, lines that do not fit are left off.
        var fontSize = rect.height * 0.1
        let smallest = max(1, rect.height * 0.025)
        var text = attributed(fontSize: fontSize)
        var framesetter = CTFramesetterCreateWithAttributedString(text)
        while fontSize > smallest {
            let fitting = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                       CGSize(width: textRect.width, height: .greatestFiniteMagnitude), nil)
            if fitting.height <= textRect.height { break }
            fontSize = max(smallest, fontSize * 0.88)
            text = attributed(fontSize: fontSize)
            framesetter = CTFramesetterCreateWithAttributedString(text)
        }
        let fitting = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                   CGSize(width: textRect.width, height: textRect.height), nil)
        // Centered on the page: the frame is as tall as its lines, in the middle of the space.
        let height = min(textRect.height, fitting.height.rounded(.up))
        let frameRect = CGRect(x: textRect.minX, y: textRect.midY - height / 2, width: textRect.width, height: height)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }

    private func attributed(fontSize: CGFloat) -> CFAttributedString {
        let shownTitle = title.isEmpty ? "Untitled" : title
        let text = NSMutableAttributedString(string: shownTitle, attributes: attributes(size: fontSize, weight: 600, color: Self.ink))
        // Each author on a line of their own, the first set apart from the title.
        for (index, author) in authors.enumerated() {
            let style = attributes(size: fontSize * 0.6, weight: 400, color: Self.secondaryInk,
                                   spacingBefore: index == 0 ? fontSize * 0.8 : 0)
            text.append(NSAttributedString(string: "\n" + author, attributes: style))
        }
        return text
    }

    private func attributes(size: CGFloat, weight: Int, color: CGColor, spacingBefore: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let font = FontRegistry.systemFont(families: ["serif"], size: size, weight: weight, italic: false) as CTFont
        var alignment = CTTextAlignment.center
        var spacing = spacingBefore
        let paragraph = withUnsafeBytes(of: &alignment) { alignmentBytes in
            withUnsafeBytes(of: &spacing) { spacingBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size, value: spacingBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
    }
}
