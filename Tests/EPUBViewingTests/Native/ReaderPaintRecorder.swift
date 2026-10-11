import CoreGraphics
import Foundation
import ImageIO
import ObjectiveC
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the reader's views last actually painted.
///
/// AppKit and UIKit keep each view's drawing in a surface of its own and repaint it only after
/// an invalidation. `cacheDisplay(in:to:)`, `displayIgnoringOpacity(_:in:)` and
/// `CALayer.render(in:)` all draw afresh: they show what the reader would paint now, never a
/// surface nothing invalidated, which is what stays on screen. A TextKit 2 text view draws
/// every laid-out fragment in such a surface, a system view per fragment beneath it.
///
/// The recorder therefore copies each real `draw(_:)` the system makes of a view under `root`:
/// the same call, repeated into a bitmap that is kept for that view and updated only within
/// the rectangle the system redrew. `bitmap(background:)` composes those bitmaps as the views
/// are arranged, so its pixels are the retained ones. A view is invalidated here only for its
/// first recording: by `synchronize()`, which a test calls once at the start, and when its
/// class is first met after it drew.
///
/// The view classes are found in the hierarchy at run time; none is named. Their `draw(_:)`
/// stays wrapped for the life of the test process and only calls through when no recorder
/// is recording. On UIKit a render-server snapshot (`drawHierarchy(in:afterScreenUpdates:)`)
/// would read the same surfaces directly, but the simulator's test host has none to read.
@MainActor final class ReaderPaintRecorder {
    private final class Surface {
        weak var view: PlatformView?
        /// The part of the view's bounds the bitmap holds.
        let region: CGRect
        let context: CGContext
        init(view: PlatformView, region: CGRect, context: CGContext) {
            self.view = view; self.region = region; self.context = context
        }
    }

    private static weak var active: ReaderPaintRecorder?
    private static var seen: Set<ObjectIdentifier> = []
    /// The classes that draw themselves, whose `draw(_:)` is wrapped.
    private static var wrapped: Set<ObjectIdentifier> = []
    private static var drawing: Set<ObjectIdentifier> = []
    /// A whole-book scroll document is far larger than any bitmap worth keeping; such a view
    /// is recorded only where the system drew it.
    private static let maximumArea: CGFloat = 8_000_000
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let root: PlatformView
    private var surfaces: [ObjectIdentifier: Surface] = [:]
    /// The system's draws of views under `root` since the recorder began.
    private(set) var draws = 0

    init(root: PlatformView) {
        self.root = root
        Self.active = self
        instrumentHierarchy()
    }

    func stop() {
        if Self.active === self { Self.active = nil }
        surfaces.removeAll()
    }

    // MARK: Painting

    /// Runs the display pass the system already has pending: pending layout, then the
    /// transaction commit that draws invalidated views only.
    func flush() {
        #if os(macOS)
        root.window?.contentView?.layoutSubtreeIfNeeded()
        root.window?.displayIfNeeded()
        #else
        root.window?.layoutIfNeeded()
        #endif
        if instrumentHierarchy() {
            #if os(macOS)
            root.window?.displayIfNeeded()
            #endif
        }
        CATransaction.flush()
        surfaces = surfaces.filter { $0.value.view != nil }
    }

    /// Invalidates every drawing view under `root` and paints, so each has a recording. A baseline
    /// only: a check that follows it says nothing about what the reader invalidates itself.
    func synchronize() {
        flush()
        for view in Self.hierarchy(of: root) where Self.wrapped.contains(ObjectIdentifier(type(of: view))) {
            Self.invalidate(view)
        }
        flush()
    }

    private static func invalidate(_ view: PlatformView) {
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    /// Wraps the classes of the views now under `root`. A view of a class first met here drew
    /// before it could be recorded (a table's cells after a navigation), so it is asked to draw
    /// once more, for its first recording only.
    @discardableResult private func instrumentHierarchy() -> Bool {
        let views = Self.hierarchy(of: root)
        var late: Set<ObjectIdentifier> = []
        for view in views where Self.instrument(type(of: view)) { late.insert(ObjectIdentifier(type(of: view))) }
        for view in views where late.contains(ObjectIdentifier(type(of: view))) { Self.invalidate(view) }
        return !late.isEmpty
    }

    private static func hierarchy(of view: PlatformView) -> [PlatformView] {
        [view] + view.subviews.flatMap { hierarchy(of: $0) }
    }

    /// Wraps a view class's `draw(_:)`; true when it newly did. A class that draws nothing of
    /// its own is left alone: a view gets a surface only when its class overrides `draw(_:)`.
    private static func instrument(_ type: AnyClass) -> Bool {
        guard seen.insert(ObjectIdentifier(type)).inserted else { return false }
        let selector = #selector(PlatformView.draw(_:))
        guard let method = class_getInstanceMethod(type, selector),
              let base = class_getInstanceMethod(PlatformView.self, selector),
              method_getImplementation(method) != method_getImplementation(base) else { return false }
        typealias Draw = @convention(c) (AnyObject, Selector, CGRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Draw.self)
        let block: @convention(block) (AnyObject, CGRect) -> Void = { object, rect in
            MainActor.assumeIsolated {
                let id = ObjectIdentifier(object)
                // A subclass's wrapper around its superclass's records once, at the outside.
                guard let recorder = active, let view = object as? PlatformView, drawing.insert(id).inserted else {
                    return original(object, selector, rect)
                }
                defer { drawing.remove(id) }
                original(object, selector, rect)
                recorder.record(view, dirty: rect) { original(object, selector, $0) }
            }
        }
        class_replaceMethod(type, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        wrapped.insert(ObjectIdentifier(type))
        return true
    }

    private func record(_ view: PlatformView, dirty: CGRect, redraw: (CGRect) -> Void) {
        guard view === root || view.isDescendant(of: root) else { return }
        draws += 1
        let id = ObjectIdentifier(view), bounds = view.bounds
        let whole = bounds.width * bounds.height <= Self.maximumArea
        let region = (whole ? bounds : dirty.intersection(bounds)).integral
        guard region.width >= 1, region.height >= 1, region.width * region.height <= Self.maximumArea else {
            surfaces[id] = nil
            return
        }
        let surface: Surface
        if let existing = surfaces[id], existing.view === view, existing.region == region {
            surface = existing
        } else {
            guard let context = CGContext(data: nil, width: Int(region.width), height: Int(region.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: Self.colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            surface = Surface(view: view, region: region, context: context)
            surfaces[id] = surface
        }
        let context = surface.context
        context.saveGState()
        defer { context.restoreGState() }
        #if os(macOS)
        let flipped = view.isFlipped
        #else
        let flipped = true
        #endif
        if flipped {
            context.translateBy(x: 0, y: region.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.translateBy(x: -region.minX, y: -region.minY)
        // The system repaints only the rectangle it asked for; the rest of the surface stays.
        let painted = dirty.intersection(region)
        context.clip(to: painted)
        context.clear(painted)
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        redraw(dirty)
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPushContext(context)
        redraw(dirty)
        UIGraphicsPopContext()
        #endif
    }

    // MARK: Reading

    /// The reader as its views last painted it, over `background`.
    func bitmap(background: PlatformColor) -> ReaderPaintBitmap {
        let size = root.bounds.size
        return ReaderPaintBitmap(width: max(1, Int(size.width)), height: max(1, Int(size.height)), background: background) { context in
            // A fill keeps its exact color between pixels.
            context.interpolationQuality = .none
            compose(root, in: context)
        }
    }

    private func compose(_ view: PlatformView, in context: CGContext) {
        guard !view.isHidden else { return }
        if let surface = surfaces[ObjectIdentifier(view)], surface.view === view, let image = surface.context.makeImage() {
            let frame = rootRect(surface.region, of: view), clip = rootRect(visibleRect(of: view), of: view)
            if !clip.isEmpty, !frame.isEmpty {
                context.saveGState()
                context.clip(to: clip)
                // The image is upright; the context is flipped.
                context.translateBy(x: frame.minX, y: frame.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: frame.size))
                context.restoreGState()
            }
        }
        for subview in view.subviews { compose(subview, in: context) }
    }

    /// `rect` (the view's coordinates) in the root's, measured from the root's top-left corner.
    private func rootRect(_ rect: CGRect, of view: PlatformView) -> CGRect {
        var converted = view === root ? rect : view.convert(rect, to: root)
        #if os(macOS)
        if !root.isFlipped { converted.origin.y = root.bounds.maxY - converted.maxY }
        #endif
        return converted
    }

    /// The part of a view no ancestor clips, in its own coordinates.
    private func visibleRect(of view: PlatformView) -> CGRect {
        #if os(macOS)
        return view.visibleRect
        #else
        var rect = view.bounds
        var ancestor = view === root ? nil : view.superview
        while let current = ancestor {
            if current.clipsToBounds { rect = rect.intersection(current.convert(current.bounds, to: view)) }
            ancestor = current === root ? nil : current.superview
        }
        return rect
        #endif
    }
}

/// A picture of the reader: RGBA, top row first, one pixel per point, in sRGB.
@MainActor struct ReaderPaintBitmap {
    private(set) var pixels: [UInt8]
    let width: Int
    let height: Int
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `draw` paints over `background` in top-left coordinates, as views use.
    init(width: Int, height: Int, background: PlatformColor, draw: (CGContext) -> Void) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: Self.colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(Self.components(of: background).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            draw(context)
        }
    }

    private static func components(of color: PlatformColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, cgColor: CGColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(macOS)
        (color.usingColorSpace(.sRGB) ?? color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return (red, green, blue, alpha, CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!)
    }

    /// How many pixels are `color` drawn over `background`: a highlight's fill between its
    /// glyphs. Anti-aliased glyph edges and anything else differ and are not counted.
    /// `region` limits the count to part of the picture, in points from its top-left corner.
    func count(of color: PlatformColor, over background: PlatformColor, in region: CGRect? = nil, tolerance: Int = 2) -> Int {
        let top = Self.components(of: color), bottom = Self.components(of: background)
        func blend(_ a: CGFloat, _ b: CGFloat) -> Int { Int((255 * (a * top.alpha + b * (1 - top.alpha))).rounded()) }
        let target = (blend(top.red, bottom.red), blend(top.green, bottom.green), blend(top.blue, bottom.blue))
        return count(in: region) {
            abs($0 - target.0) <= tolerance && abs($1 - target.1) <= tolerance && abs($2 - target.2) <= tolerance
        }
    }

    /// How many pixels are far from `background`: glyph ink, which shows that the picture holds
    /// the page and not an empty surface.
    func ink(over background: PlatformColor) -> Int {
        let bottom = Self.components(of: background)
        let base = (Int(255 * bottom.red), Int(255 * bottom.green), Int(255 * bottom.blue))
        return count(in: nil) { abs($0 - base.0) > 128 && abs($1 - base.1) > 128 && abs($2 - base.2) > 128 }
    }

    private func count(in region: CGRect?, _ matches: (Int, Int, Int) -> Bool) -> Int {
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        let area = (region ?? whole).intersection(whole).integral
        guard !area.isEmpty else { return 0 }
        var count = 0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let index = (y * width + x) * 4
                if matches(Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])) { count += 1 }
            }
        }
        return count
    }

    /// Writes the picture as a PNG, for looking at a failure.
    func writePNG(to url: URL) {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: Self.colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
