import CResvg
import CoreGraphics
import CryptoKit
import Foundation

/// One immutable static SVG tree, shared between size buckets. The bundled C API cannot open
/// any image/font files; it accepts only bounded raster bytes and host-provided SFNT fonts.
final class SVGRenderer: @unchecked Sendable {
    private let tree: OpaquePointer
    private let options: SVGRenderOptions
    let size: CGSize
    let fallbackText: String
    private let maximumRasterPixels: Int
    private let failureLock = NSLock()
    private var failed = false
    var hasFailedRendering: Bool { failureLock.withLock { failed } }

    init?(_ data: Data, fonts: [SVGFontData] = []) {
        guard !data.isEmpty, data.count <= SVGContent.maximumBytes,
              let document = try? ContentDocument.parse(data, path: "svg", limits: .init(bytes: SVGContent.maximumBytes, depth: SVGContent.maximumDepth, nodes: SVGContent.maximumNodes), asContent: false),
              SVGContent.isWithinRenderingLimits(document.root),
              SVGContent.preparedImagesAreBounded(document.root) else { return nil }
        let hasText = document.nodes.contains { $0.name == "text" }
        guard let options = SVGRenderOptions.get(fonts: hasText ? fonts : [], text: hasText) else { return nil }
        var parsed: OpaquePointer?
        let result = data.withUnsafeBytes {
            resvg_parse_tree_from_data($0.baseAddress!.assumingMemoryBound(to: CChar.self), UInt($0.count), options.pointer, &parsed)
        }
        guard result == 0, let parsed else { return nil }
        let dimensions = resvg_get_image_size(parsed)
        guard dimensions.width.isFinite, dimensions.height.isFinite, dimensions.width > 0, dimensions.height > 0,
              !resvg_is_image_empty(parsed) else { resvg_tree_destroy(parsed); return nil }
        tree = parsed
        self.options = options
        size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        fallbackText = SVGContent.fallbackText(document.root)
        let layers = SVGContent.isolatedLayers(document.root)
        maximumRasterPixels = layers == 0 ? 16 * 1024 * 1024 : (96 * 1024 * 1024) / (4 + 25 * 5 * layers)
        // A small raster catches parse-independent failures while section construction can
        // still substitute text and disclose the unsupported drawing. Larger draws remain
        // guarded independently: passing this raster is not a proof about another size.
        guard render(maxPixelSize: 64) != nil else { return nil }
    }

    deinit { resvg_tree_destroy(tree) }

    func render(maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, !hasFailedRendering else { return nil }
        let scale = min(CGFloat(min(maxPixelSize, ReaderImageSource.maximumSVGDimension)) / max(size.width, size.height),
                        sqrt(CGFloat(maximumRasterPixels) / (size.width * size.height)))
        let width = max(1, Int((size.width * scale).rounded(.down)))
        let height = max(1, Int((size.height * scale).rounded(.down)))
        guard width <= 16 * 1024 * 1024 / height else { return nil }
        var bytes = Data(count: width * height * 4)
        var transform = resvg_transform_identity()
        transform.a = Float(scale); transform.d = Float(scale)
        let rendered = bytes.withUnsafeMutableBytes {
            resvg_render_checked(tree, transform, UInt32(width), UInt32(height), $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        guard rendered else {
            failureLock.withLock { failed = true }
            return nil
        }
        guard let provider = CGDataProvider(data: bytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // tiny-skia produces premultiplied, top-to-bottom RGBA, which CGImage consumes directly.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// usvg retains an Arc to the immutable font database in every tree. Reusing read-only
/// options shares those font bytes, including across concurrent section builds.
private final class SVGRenderOptions: @unchecked Sendable {
    let pointer: OpaquePointer
    private let reservation: SVGFontReservation
    private static let lock = NSLock()
    /// A few recently used databases, kept for the next SVG with the same fonts.
    nonisolated(unsafe) private static var entries: [String: SVGRenderOptions] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    /// Every database a parsed tree or the cache still holds, by the same key. Weak, so this
    /// never extends a database's life or its reservation.
    nonisolated(unsafe) private static var live: [String: Live] = [:]
    private struct Live { weak var options: SVGRenderOptions? }
    private static let cachedDatabases = 4

    static func get(fonts: [SVGFontData], text: Bool) -> SVGRenderOptions? {
        var digest = SHA256()
        for font in fonts { digest.update(data: font.data) }
        let key = (text ? "text:" : "shapes:") + digest.finalize().map { String(format: "%02x", $0) }.joined()
        lock.lock(); defer { lock.unlock() }
        if let known = entries[key] { return known }
        // The cache forgets a database long before its trees do: a book's built sections hold
        // theirs while a relayout builds the same figures again. That database is the same
        // immutable bytes, already reserved. Share it; a second copy would be counted twice
        // and refused once the copies of what is still on screen fill the budget.
        if let shared = live[key]?.options {
            remember(shared, for: key)
            return shared
        }
        while entries.count >= cachedDatabases { entries.removeValue(forKey: order.removeFirst()) }
        var created = SVGRenderOptions(fonts: fonts, text: text)
        // Evict unused cached databases to make room. Databases held by live SVG trees
        // keep their reservation, so many family combinations cannot evade the budget.
        while created == nil, !order.isEmpty {
            entries.removeValue(forKey: order.removeFirst())
            created = SVGRenderOptions(fonts: fonts, text: text)
        }
        live = live.filter { $0.value.options != nil }
        guard let options = created else { return nil }
        live[key] = Live(options: options)
        remember(options, for: key)
        return options
    }

    /// Caches `options` as the most recent database. Called with the lock held.
    private static func remember(_ options: SVGRenderOptions, for key: String) {
        while entries.count >= cachedDatabases { entries.removeValue(forKey: order.removeFirst()) }
        entries[key] = options; order.append(key)
    }

    private init?(fonts: [SVGFontData], text: Bool) {
        let available = (text ? SVGFontData.defaults : []) + fonts
        var selected: [SVGFontData] = []
        var bytes = 0
        for font in available {
            guard font.data.count <= SVGFontData.maximumBytes, !SVGFontData.hasColorGlyphs(font.data) else { continue }
            guard font.data.count <= FontRegistry.maximumFontBytes - bytes else { break }
            selected.append(font); bytes += font.data.count
        }
        guard let reservation = SVGFontReservation(bytes: bytes), let pointer = resvg_options_create() else { return nil }
        self.pointer = pointer
        self.reservation = reservation
        "Times New Roman".withCString { resvg_options_set_font_family(pointer, $0) }
        "Times New Roman".withCString { resvg_options_set_serif_family(pointer, $0) }
        "Arial".withCString { resvg_options_set_sans_serif_family(pointer, $0) }
        "Courier New".withCString { resvg_options_set_monospace_family(pointer, $0) }
        for font in selected {
            font.data.withUnsafeBytes { resvg_options_load_font_data(pointer, $0.baseAddress!.assumingMemoryBound(to: CChar.self), UInt($0.count)) }
        }
    }

    deinit { resvg_options_destroy(pointer) }
}

/// Separate from the options-cache lock: eviction can destroy options while that lock is
/// held. A reservation follows the database's full lifetime, including retained SVG trees.
private final class SVGFontReservation: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var liveBytes = 0
    private let bytes: Int

    init?(bytes: Int) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard bytes <= FontRegistry.maximumFontBytes - Self.liveBytes else { return nil }
        self.bytes = bytes
        Self.liveBytes += bytes
    }

    deinit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.liveBytes -= bytes
    }
}
