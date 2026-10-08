import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// How a replaced element (image, SVG) is sized: its intrinsic size and the CSS lengths that
/// constrain it, with `width`/`height` attributes already applied as presentational hints.
struct ImageSizing: Equatable, Sendable {
    /// Intrinsic size in points (a CSS px is a point); zero when unknown.
    var intrinsic: CGSize
    var width: ComputedStyle.Length = .auto
    var height: ComputedStyle.Length = .auto
    var minWidth: ComputedStyle.Length = .auto
    var minHeight: ComputedStyle.Length = .auto
    var maxWidth: ComputedStyle.Length = .auto
    var maxHeight: ComputedStyle.Length = .auto

    /// The size the element is shown at on a line of `lineWidth` in `viewport`, never wider than
    /// the line nor taller than `heightLimit`, with the intrinsic aspect ratio kept (when CSS
    /// gives both dimensions the image fits inside them, as `object-fit: contain`). Percent
    /// widths are of the line and percent heights of the viewport, the only height a reading
    /// page has. Without any size the default is CSS's 300 × 150.
    func size(lineWidth: CGFloat, viewport: CGSize, heightLimit: CGFloat) -> CGSize {
        let ratio: CGFloat? = intrinsic.width > 0 && intrinsic.height > 0 ? intrinsic.width / intrinsic.height : nil
        let w = width.resolve(reference: lineWidth, viewport: viewport).map { max(0, $0) }
        let h = height.resolve(reference: viewport.height, viewport: viewport).map { max(0, $0) }
        var size: CGSize
        switch (w, h) {
        case let (w?, h?):
            size = ratio.map { ratio in w / h > ratio ? CGSize(width: h * ratio, height: h) : CGSize(width: w, height: w / ratio) }
                ?? CGSize(width: w, height: h)
        case let (w?, nil): size = CGSize(width: w, height: ratio.map { w / $0 } ?? (intrinsic.height > 0 ? intrinsic.height : w / 2))
        case let (nil, h?): size = CGSize(width: ratio.map { h * $0 } ?? (intrinsic.width > 0 ? intrinsic.width : h * 2), height: h)
        case (nil, nil): size = ratio != nil ? intrinsic : CGSize(width: 300, height: 150)
        }
        func scale(_ factor: CGFloat) {
            guard factor.isFinite, factor > 0 else { return }
            if ratio != nil { size = CGSize(width: size.width * factor, height: size.height * factor) }
        }
        if let minimum = minWidth.resolve(reference: lineWidth, viewport: viewport), size.width < minimum {
            if ratio != nil, size.width > 0 { scale(minimum / size.width) } else { size.width = minimum }
        }
        if let minimum = minHeight.resolve(reference: viewport.height, viewport: viewport), size.height < minimum {
            if ratio != nil, size.height > 0 { scale(minimum / size.height) } else { size.height = minimum }
        }
        let maxW = min(lineWidth, maxWidth.resolve(reference: lineWidth, viewport: viewport) ?? .infinity)
        let maxH = min(heightLimit, maxHeight.resolve(reference: viewport.height, viewport: viewport) ?? .infinity)
        if size.width > maxW { if ratio != nil { scale(maxW / size.width) } else { size.width = maxW } }
        if size.height > maxH { if ratio != nil { scale(maxH / size.height) } else { size.height = maxH } }
        return CGSize(width: max(1, size.width), height: max(1, size.height))
    }

    /// CSS sizes, with an element's `width`/`height` attributes as hints where CSS says `auto`.
    init(intrinsic: CGSize, style: ComputedStyle, widthHint: String? = nil, heightHint: String? = nil, fontSize: CGFloat? = nil) {
        self.intrinsic = intrinsic
        width = style.width == .auto ? Self.length(widthHint, fontSize: fontSize ?? style.fontSize) ?? .auto : style.width
        height = style.height == .auto ? Self.length(heightHint, fontSize: fontSize ?? style.fontSize) ?? .auto : style.height
        minWidth = style.minWidth; minHeight = style.minHeight
        maxWidth = style.maxWidth; maxHeight = style.maxHeight
    }

    init(intrinsic: CGSize) { self.intrinsic = intrinsic }

    /// An HTML or SVG length attribute: a number with an optional CSS unit or `%`.
    static func length(_ value: String?, fontSize: CGFloat) -> ComputedStyle.Length? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
        let number = value.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        guard let amount = Double(number), amount.isFinite, amount >= 0 else { return nil }
        let points = CGFloat(min(amount, 100_000))
        let factors: [String: CGFloat] = ["": 1, "px": 1, "pt": 4.0 / 3, "pc": 16, "in": 96, "cm": 96 / 2.54,
                                          "mm": 9.6 / 2.54, "em": fontSize, "rem": fontSize, "ex": fontSize / 2]
        let unit = value.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        if unit == "%" { return .percent(points) }
        if unit == "vw" { return .viewportWidth(points) }
        if unit == "vh" { return .viewportHeight(points) }
        return factors[unit].map { .points(points * $0) }
    }
}

/// An image shown in the text: `<img>`, SVG `<image>`, an image `<object>`/`<embed>`, or an
/// SVG drawn by the platform decoder. Sized when laid out, decoded only when drawn: TextKit 2
/// asks `image(for:…)` at display time on both platforms, and the bitmap comes downsampled to
/// the displayed size from the shared `ReaderImageCache`.
final class ReaderImageAttachment: ReaderAttachment {
    let source: ReaderImageSource
    let sizing: ImageSizing
    let alt: String
    /// Where the image is drawn inside the attachment, as fractions of it (an SVG `<image>`
    /// placed inside its viewBox); nil fills it.
    let contentRect: CGRect?
    let isBlock: Bool
    let verticalAlign: ComputedStyle.VerticalAlign
    let fontSize: CGFloat
    let cache: ReaderImageCache

    init(source: ReaderImageSource, sizing: ImageSizing, alt: String, style: ComputedStyle,
         contentRect: CGRect? = nil, cache: ReaderImageCache) {
        self.source = source; self.sizing = sizing; self.alt = alt; self.contentRect = contentRect
        isBlock = style.display.isBlockLevel
        verticalAlign = style.verticalAlign
        fontSize = style.fontSize
        self.cache = cache
        super.init()
    }
    required init?(coder: NSCoder) { nil }

    /// The decoded archive path the image came from (empty for inline SVG).
    var path: String { source.path }
    override var accessibilityText: String { alt }

    #if os(iOS)
    override var accessibilityLabel: String? {
        get { alt.isEmpty ? nil : alt }
        set {}
    }
    #endif

    /// The displayed size on `line`: at most the viewport's height, so it fits one page.
    func displaySize(_ line: Line) -> CGSize {
        sizing.size(lineWidth: line.available, viewport: line.viewport, heightLimit: line.viewport.height)
    }

    override func layoutBounds(_ line: Line) -> CGRect {
        let font = line.font ?? PlatformFont.systemFont(ofSize: fontSize)
        let size = displaySize(line)
        let lineHeight = font.ascender - font.descender
        guard !isBlock, size.height <= lineHeight * 2 else {
            // A large image sits in the descent, so its line is exactly as tall as the image and
            // a page-high image fits its page.
            return CGRect(x: 0, y: font.descender, width: size.width, height: size.height)
        }
        let y: CGFloat = switch verticalAlign {
        case .baseline: 0
        case .middle: font.xHeight / 2 - size.height / 2
        case .top, .textTop: font.ascender - size.height
        case .bottom, .textBottom: font.descender
        case .sub: -fontSize * 0.2
        case .super: fontSize * 0.4
        case .offset(let points): points
        }
        return CGRect(x: 0, y: y, width: size.width, height: size.height)
    }

    override func contentWidths() -> (min: CGFloat, max: CGFloat) {
        let natural = sizing.size(lineWidth: 100_000, viewport: CGSize(width: 1024, height: 100_000), heightLimit: 100_000).width
        // Percentage sizes make an image compressible: it shrinks with its table column.
        let compressible = [sizing.width, sizing.maxWidth].contains { if case .percent = $0 { true } else { false } }
        return (compressible ? min(natural, 16) : natural, natural)
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? {
        render(bounds.size)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> PlatformImage? {
        render(imageBounds.size)
    }

    /// Where the bitmap goes inside an attachment of `size`, top-left origin, aspect kept.
    func imageRect(in size: CGSize) -> CGRect {
        var box = CGRect(origin: .zero, size: size)
        if let unit = contentRect {
            box = CGRect(x: unit.minX * size.width, y: unit.minY * size.height,
                         width: unit.width * size.width, height: unit.height * size.height)
        }
        let aspect = source.pixelSize.width / source.pixelSize.height
        guard aspect.isFinite, aspect > 0, box.height > 0 else { return box }
        let fitted = box.width / box.height > aspect ? CGSize(width: box.height * aspect, height: box.height)
            : CGSize(width: box.width, height: box.width / aspect)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// Decodes for drawing `rect` at `scale` device pixels per point.
    func bitmap(for rect: CGRect, scale: CGFloat) -> CGImage? {
        let pixels = Int((max(rect.width, rect.height) * scale).rounded(.up))
        return cache.image(for: source, maxPixelSize: pixels)
    }

    private func render(_ size: CGSize) -> PlatformImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let rect = imageRect(in: size)
        #if os(iOS)
        let scale = currentDrawingScale()
        guard let bitmap = bitmap(for: rect, scale: scale) else { return nil }
        if rect == CGRect(origin: .zero, size: size) {
            return UIImage(cgImage: bitmap, scale: CGFloat(bitmap.width) / size.width, orientation: .up)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: bitmap).draw(in: rect)
        }
        #else
        // The handler runs when the image is drawn, at the destination's resolution.
        return NSImage(size: size, flipped: false) { [self] bounds in
            guard let context = NSGraphicsContext.current?.cgContext,
                  let bitmap = bitmap(for: rect, scale: currentDrawingScale()) else { return false }
            context.interpolationQuality = .high
            context.draw(bitmap, in: CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
            return true
        }
        #endif
    }
}
