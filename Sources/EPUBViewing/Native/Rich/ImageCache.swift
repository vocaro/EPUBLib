import CoreGraphics
import Foundation
import ImageIO
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// An image resource as the section build found it: the bytes (shared with the publication,
/// never copied) and the header's pixel size. Bitmaps decode when drawn; SVG parses and
/// checks a small raster when built, then rasterizes requested sizes when drawn.
final class ReaderImageSource: @unchecked Sendable {
    enum Format: Sendable { case bitmap, svg }

    /// Identifies the resource across sections and rebuilds: the publication and archive path,
    /// or the inline SVG's document position.
    let key: String
    /// The decoded archive path; empty for inline SVG.
    let path: String
    let data: Data
    let format: Format
    /// Pixels (bitmap) or points (SVG), with EXIF orientation applied.
    let pixelSize: CGSize
    private let svgRenderer: SVGRenderer?
    /// A later-size SVG render failed; attachments retain their words as a visible fallback.
    var hasFailedSVGRendering: Bool { svgRenderer?.hasFailedRendering ?? false }

    /// Bitmaps over this many pixels are refused as unreadable rather than decoded.
    static let maximumPixelCount = 64 * 1024 * 1024
    /// SVG is rasterized at most this many pixels on its long side.
    static let maximumSVGDimension = 4096

    private init(key: String, path: String, data: Data, format: Format, pixelSize: CGSize, svgRenderer: SVGRenderer? = nil) {
        self.key = key; self.path = path; self.data = data; self.format = format; self.pixelSize = pixelSize
        self.svgRenderer = svgRenderer
    }

    /// Reads a bitmap's header (`CGImageSourceCopyPropertiesAtIndex`); nil when ImageIO cannot
    /// read it or it is implausibly large.
    static func bitmap(_ data: Data, path: String, key: String) -> ReaderImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maximumPixelCount / height else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return ReaderImageSource(key: key, path: path, data: data, format: .bitmap, pixelSize: size)
    }

    /// A bounded static SVG, parsed by the same renderer on every platform.
    static func svg(_ data: Data, path: String, key: String, fonts: [SVGFontData] = []) -> ReaderImageSource? {
        guard let renderer = SVGRenderer(data, fonts: fonts) else { return nil }
        // The document's own width and height, which a book controls: kept to a size every
        // later computation (decode buckets, rasterizing) can represent.
        let long = max(renderer.size.width, renderer.size.height)
        let scale = min(1, CGFloat(maximumSVGDimension) / long)
        let size = CGSize(width: renderer.size.width * scale, height: renderer.size.height * scale)
        guard size.width >= 1 / 64, size.height >= 1 / 64 else { return nil }
        return ReaderImageSource(key: key, path: path, data: data, format: .svg, pixelSize: size, svgRenderer: renderer)
    }

    /// Decodes at most `maxPixelSize` pixels on the long side: a downsampled thumbnail with the
    /// orientation applied, or the SVG rasterized at that size.
    func decode(maxPixelSize: Int) -> CGImage? {
        switch format {
        case .bitmap:
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
        case .svg:
            return rasterizeSVG(maxPixelSize: maxPixelSize)
        }
    }

    private func rasterizeSVG(maxPixelSize: Int) -> CGImage? {
        svgRenderer?.render(maxPixelSize: maxPixelSize)
    }
}

/// Decoded, downsampled images shared by every section, bounded by a byte-cost budget and
/// evicted least recently used first. Thread-safe.
final class ReaderImageCache: @unchecked Sendable {
    static let shared = ReaderImageCache(budget: 96 * 1024 * 1024, observesMemoryPressure: true)

    private struct Key: Hashable { let source: String; let pixels: Int; let inverted: Bool; let lightBackdrop: Bool }
    private struct Entry { let image: CGImage; let cost: Int; var used: Int }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock = 0
    private var limit: Int
    private var cost = 0
    private var decodes = 0
    private var pressure: (any DispatchSourceMemoryPressure)?

    init(budget: Int, observesMemoryPressure: Bool = false) {
        limit = max(0, budget)
        guard observesMemoryPressure else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.trim(to: event.contains(.critical) ? 0 : self.budget / 2)
        }
        source.resume()
        pressure = source
    }

    deinit { pressure?.cancel() }

    /// Bytes of decoded pixels the cache may hold. Lowering it evicts at once.
    var budget: Int {
        get { lock.withLock { limit } }
        set {
            lock.withLock { limit = max(0, newValue) }
            trim(to: newValue)
        }
    }
    var totalCost: Int { lock.withLock { cost } }
    var count: Int { lock.withLock { entries.count } }
    /// Decodes performed so far.
    var decodeCount: Int { lock.withLock { decodes } }

    func removeAll() { trim(to: 0) }

    /// The image decoded to at least `maxPixelSize` on its long side (rounded up, and never more
    /// than the source has), its colors `inverted` if asked (cached apart). A cached decode up
    /// to twice that size is reused. A strict `maximumDecodedPixelSize` bounds both bucketing
    /// and cache reuse for the inspector's memory budget; `lightBackdrop` is display-only.
    func image(for source: ReaderImageSource, maxPixelSize: Int, inverted: Bool = false,
               lightBackdrop: Bool = false, maximumDecodedPixelSize: Int? = nil) -> CGImage? {
        // Once a tree has failed, even an earlier successful size must give its fallback.
        guard !source.hasFailedSVGRendering else { return nil }
        let long = max(source.pixelSize.width, source.pixelSize.height)
        let available = long.isFinite ? max(1, Int(min(long, CGFloat(1 << 30)).rounded(.up))) : 1
        let bucket = maximumDecodedPixelSize.map { min(Self.bucket(maxPixelSize), max(1, $0)) } ?? Self.bucket(maxPixelSize)
        let pixels = source.format == .svg ? min(bucket, ReaderImageSource.maximumSVGDimension)
            : min(bucket, available)
        // An explicit author inversion supplies its own dark-appearance treatment.
        let backdrop = lightBackdrop && !inverted
        let key = Key(source: source.key, pixels: pixels, inverted: inverted, lightBackdrop: backdrop)
        if let image = lock.withLock({ hit(key, maximumDecodedPixelSize: maximumDecodedPixelSize) }) {
            return source.hasFailedSVGRendering ? nil : image
        }
        guard let decoded = source.decode(maxPixelSize: pixels),
              let image = inverted ? Self.inverted(decoded) : (backdrop ? Self.addingLightBackdrop(decoded) : decoded) else { return nil }
        guard !source.hasFailedSVGRendering else { return nil }
        let entry = Entry(image: image, cost: image.bytesPerRow * image.height, used: 0)
        lock.withLock {
            decodes += 1
            guard entry.cost <= limit else { return }
            if let old = entries[key] { cost -= old.cost }
            clock += 1
            entries[key] = Entry(image: image, cost: entry.cost, used: clock)
            cost += entry.cost
            evict(to: limit)
        }
        return image
    }

    private static func bucket(_ pixels: Int) -> Int { (max(1, pixels) + 63) / 64 * 64 }

    /// Preserve the source colors, placing transparent dark artwork on white so its black
    /// strokes remain readable on the reader's dark canvas. Opaque images and transparent
    /// light artwork keep their original pixels. This only changes a display rendition;
    /// publication bytes and ordinary cached decodes remain untouched.
    static func addingLightBackdrop(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return image }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var transparent = false, darkInk = false
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Int(pixels[index + 3])
            if alpha < 255 { transparent = true }
            // Ignore nearly transparent antialiasing. Channels are premultiplied: compare
            // the weighted sRGB luminance with alpha rather than unpremultiplying pixels.
            if alpha >= 32 {
                let luminance = 54 * Int(pixels[index]) + 183 * Int(pixels[index + 1]) + 19 * Int(pixels[index + 2])
                if luminance < alpha * 96 { darkInk = true }
            }
            if transparent && darkInk { break }
        }
        guard transparent && darkInk else { return image }
        context.setBlendMode(.destinationOver)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        return context.makeImage()
    }

    /// CSS `filter: invert(100%)` in sRGB: each color channel inverted, alpha kept.
    static func inverted(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // Premultiplied, a channel c of alpha a inverts to a − c.
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = pixels[index + 3]
            pixels[index] = alpha &- min(pixels[index], alpha)
            pixels[index + 1] = alpha &- min(pixels[index + 1], alpha)
            pixels[index + 2] = alpha &- min(pixels[index + 2], alpha)
        }
        return context.makeImage()
    }

    private func hit(_ key: Key, maximumDecodedPixelSize: Int?) -> CGImage? {
        func fits(_ candidate: Key) -> Bool {
            guard let limit = maximumDecodedPixelSize, let image = entries[candidate]?.image else { return true }
            return max(image.width, image.height) <= max(1, limit)
        }
        var found = entries[key] == nil || !fits(key) ? nil : key
        if found == nil {
            found = entries.keys.filter {
                $0.source == key.source && $0.inverted == key.inverted && $0.lightBackdrop == key.lightBackdrop
                    && $0.pixels >= key.pixels && $0.pixels <= key.pixels * 2 && fits($0)
            }
                .min { $0.pixels < $1.pixels }
        }
        guard let found, var entry = entries[found] else { return nil }
        clock += 1
        entry.used = clock
        entries[found] = entry
        return entry.image
    }

    private func trim(to budget: Int) { lock.withLock { evict(to: budget) } }

    private func evict(to budget: Int) {
        while cost > budget, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            cost -= oldest.value.cost
            entries[oldest.key] = nil
        }
    }
}
