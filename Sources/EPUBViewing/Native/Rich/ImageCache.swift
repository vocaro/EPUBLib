import CoreGraphics
import Foundation
import ImageIO
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// An image resource as the section build found it: the bytes (shared with the publication,
/// never copied) and the header's pixel size. Nothing is decoded until the image is drawn.
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

    /// Bitmaps over this many pixels are refused as unreadable rather than decoded.
    static let maximumPixelCount = 64 * 1024 * 1024
    /// SVG is rasterized at most this many pixels on its long side.
    static let maximumSVGDimension = 4096

    private init(key: String, path: String, data: Data, format: Format, pixelSize: CGSize) {
        self.key = key; self.path = path; self.data = data; self.format = format; self.pixelSize = pixelSize
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

    /// An SVG document the platform image decoder can draw; nil when it cannot.
    static func svg(_ data: Data, path: String, key: String) -> ReaderImageSource? {
        guard let image = PlatformImage(data: data), image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { return nil }
        // The document's own width and height, which a book controls: kept to a size every
        // later computation (decode buckets, rasterizing) can represent.
        let long = max(image.size.width, image.size.height)
        let scale = min(1, CGFloat(maximumSVGDimension) / long)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard size.width >= 1 / 64, size.height >= 1 / 64 else { return nil }
        return ReaderImageSource(key: key, path: path, data: data, format: .svg, pixelSize: size)
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
        guard let image = PlatformImage(data: data) else { return nil }
        let long = max(pixelSize.width, pixelSize.height)
        let scale = CGFloat(min(maxPixelSize, Self.maximumSVGDimension)) / long
        let width = max(1, Int((pixelSize.width * scale).rounded())), height = max(1, Int((pixelSize.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        #if os(iOS)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: rect)
        UIGraphicsPopContext()
        #else
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.current = previous
        #endif
        return context.makeImage()
    }
}

/// Decoded, downsampled images shared by every section, bounded by a byte-cost budget and
/// evicted least recently used first. Thread-safe.
final class ReaderImageCache: @unchecked Sendable {
    static let shared = ReaderImageCache(budget: 96 * 1024 * 1024, observesMemoryPressure: true)

    private struct Key: Hashable { let source: String; let pixels: Int; let inverted: Bool }
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
    /// to twice that size is reused.
    func image(for source: ReaderImageSource, maxPixelSize: Int, inverted: Bool = false) -> CGImage? {
        let long = max(source.pixelSize.width, source.pixelSize.height)
        let available = long.isFinite ? max(1, Int(min(long, CGFloat(1 << 30)).rounded(.up))) : 1
        let pixels = source.format == .svg ? min(Self.bucket(maxPixelSize), ReaderImageSource.maximumSVGDimension)
            : min(Self.bucket(maxPixelSize), available)
        let key = Key(source: source.key, pixels: pixels, inverted: inverted)
        if let image = lock.withLock({ hit(key) }) { return image }
        guard let decoded = source.decode(maxPixelSize: pixels),
              let image = inverted ? Self.inverted(decoded) : decoded else { return nil }
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

    private func hit(_ key: Key) -> CGImage? {
        var found = entries[key] == nil ? nil : key
        if found == nil {
            found = entries.keys.filter {
                $0.source == key.source && $0.inverted == key.inverted && $0.pixels >= key.pixels && $0.pixels <= key.pixels * 2
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
