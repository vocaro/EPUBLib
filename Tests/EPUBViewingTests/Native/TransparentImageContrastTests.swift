import CoreGraphics
import EPUBCore
import EPUBReading
import ImageIO
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class TransparentImageContrastTests: XCTestCase {
    /// A transparent educational diagram: black connections, gray nodes, a colored key.
    private func graph(opaque: Bool = false, whiteInk: Bool = false) -> Data {
        let context = CGContext(data: nil, width: 160, height: 80, bitsPerComponent: 8, bytesPerRow: 640,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if opaque {
            context.setFillColor(CGColor(red: 0.8, green: 0.7, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
        }
        context.setFillColor(CGColor(gray: whiteInk ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 36, width: 100, height: 8))
        if !whiteInk {
            context.setFillColor(CGColor(gray: 0.6, alpha: 1))
            context.fillEllipse(in: CGRect(x: 10, y: 25, width: 30, height: 30))
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 120, y: 30, width: 20, height: 20))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func attachment(_ fixture: RichFixture) throws -> ReaderImageAttachment {
        try XCTUnwrap(RichFixture.attachments(in: fixture.image("graph")).first as? ReaderImageAttachment)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = pixels(image), index = (y * image.width + x) * 4
        return Array(data[index..<(index + 4)])
    }

    private func bitmap(_ attachment: ReaderImageAttachment) throws -> CGImage {
        try XCTUnwrap(attachment.bitmap(for: CGRect(x: 0, y: 0, width: 160, height: 80), scale: 1))
    }

    func testDarkGraphGetsLightBackdropWithoutChangingOpaqueStrokesOrSource() throws {
        let data = graph(), cache = ReaderImageCache(budget: 1 << 20)
        let light = try RichFixture("<img id='graph' src='graph.png' alt='Graph connections'/>", files: ["graph.png": data], cache: cache)
        let dark = try RichFixture("<img id='graph' src='graph.png' alt='Graph connections'/>", files: ["graph.png": data],
                                   typography: .init(isDark: true), cache: cache)
        let original = try attachment(light), readable = try attachment(dark)
        let lightPixels = try bitmap(original), darkPixels = try bitmap(readable)
        XCTAssertEqual(rgba(lightPixels, x: 150, y: 40), [0, 0, 0, 0])
        XCTAssertEqual(rgba(darkPixels, x: 150, y: 40), [255, 255, 255, 255])
        XCTAssertEqual(rgba(darkPixels, x: 70, y: 40), rgba(lightPixels, x: 70, y: 40), "Black connections keep their original colors")
        XCTAssertEqual(rgba(darkPixels, x: 130, y: 40), rgba(lightPixels, x: 130, y: 40), "Colored keys keep their original semantics")
        XCTAssertEqual(readable.source.data, data)
        XCTAssertEqual(try dark.publication.data(at: readable.path), data)
        XCTAssertEqual(readable.alt, original.alt)
        let plain = try XCTUnwrap(cache.image(for: readable.source, maxPixelSize: 160))
        XCTAssertEqual(rgba(plain, x: 150, y: 40)[3], 0, "Original cache rendition is still transparent after a dark draw")
        let before = cache.decodeCount
        _ = try bitmap(readable)
        XCTAssertEqual(cache.decodeCount, before, "The backdrop scan and compositing are cached with the display rendition")
    }

    func testOpaquePhotographsAndTransparentLightArtworkKeepTheirPixels() throws {
        for data in [graph(opaque: true), graph(whiteInk: true)] {
            let fixture = try RichFixture("<img id='graph' src='graph.png'/>", files: ["graph.png": data], typography: .init(isDark: true))
            let image = try attachment(fixture)
            let plain = try XCTUnwrap(image.cache.image(for: image.source, maxPixelSize: 160))
            XCTAssertEqual(pixels(try bitmap(image)), pixels(plain))
        }
    }

    func testExplicitAuthorInversionKeepsTransparencyInDarkMode() throws {
        let fixture = try RichFixture("<img id='graph' src='graph.png'/>", files: ["graph.png": graph()], typography: .init(isDark: true))
        fixture.overrides["graph"] = { $0.invertsColors = true }
        let image = try attachment(fixture), drawn = try bitmap(image)
        XCTAssertEqual(rgba(drawn, x: 70, y: 40), [255, 255, 255, 255])
        XCTAssertEqual(rgba(drawn, x: 150, y: 40)[3], 0, "Honor the author's existing dark-mode treatment")
    }

    func testStrictDecodeLimitDoesNotReuseLargerCachedRendition() throws {
        let source = try XCTUnwrap(ReaderImageSource.bitmap(graph(), path: "graph.png", key: "strict-limit"))
        let cache = ReaderImageCache(budget: 1 << 20)
        let large = try XCTUnwrap(cache.image(for: source, maxPixelSize: 160, lightBackdrop: true))
        XCTAssertEqual(large.width, 160)
        XCTAssertEqual(cache.image(for: source, maxPixelSize: 80, lightBackdrop: true)?.width, 160,
                       "Ordinary drawing can reuse an existing larger decode")
        let bounded = try XCTUnwrap(cache.image(for: source, maxPixelSize: 80, lightBackdrop: true, maximumDecodedPixelSize: 80))
        XCTAssertLessThanOrEqual(max(bounded.width, bounded.height), 80,
                                 "Inspector's explicit memory bound constrains both decode bucketing and cache reuse")
    }

    func testRemoteReferencesStillRefuseResourcesRatherThanDecodeThem() throws {
        let cache = ReaderImageCache(budget: 1 << 20)
        let fixture = try RichFixture("<img id='graph' src='https://example.com/graph.png' alt='Graph'/>",
                                      typography: .init(isDark: true), cache: cache)
        XCTAssertTrue(RichFixture.attachments(in: fixture.image("graph")).isEmpty)
        XCTAssertEqual(fixture.report.report.remoteResourcesRefused, 1)
        XCTAssertEqual(cache.decodeCount, 0)
    }

    private func draw(_ image: PlatformImage, size: CGSize, darkCanvas: Bool = false) throws -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if darkCanvas {
            context.setFillColor(ReaderPalette.background(dark: true).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
        #if os(macOS)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.current = previous
        #else
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        #endif
        return try XCTUnwrap(context.makeImage())
    }

    private func whitePixels(_ image: CGImage) -> Int {
        let data = pixels(image)
        return stride(from: 0, to: data.count, by: 4).filter {
            data[$0] > 245 && data[$0 + 1] > 245 && data[$0 + 2] > 245 && data[$0 + 3] > 245
        }.count
    }

    func testLegacyTableDrawingUsesTheSameDarkImageBackdrop() throws {
        let fixture = try RichFixture("<table id='t'><tr><th>Graph</th><th>Key</th></tr><tr><td><img id='graph' src='graph.png'/></td><td>Connections</td></tr></table>",
                                      files: ["graph.png": graph()], typography: .init(isDark: true))
        let rows = RichFixture.attachments(in: fixture.table("t")).compactMap { $0 as? TableRowAttachment }
        let row = try XCTUnwrap(rows.last)
        let bounds = row.layoutBounds(line(300)), image = try XCTUnwrap(row.image(forBounds: bounds, textContainer: nil, characterIndex: 0))
        XCTAssertGreaterThan(whitePixels(try draw(image, size: bounds.size)), 5000, "Image backdrop survives the table's TextKit 1 draw path")
    }

    func testNativeCanvasDrawsGraphBackdropInBothReadingFlows() async throws {
        let fixture = try RichFixture("<img id='graph' src='graph.png'/>", files: ["graph.png": graph()], typography: .init(isDark: true))
        let text = try XCTUnwrap(fixture.image("graph"))
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = flow; configuration.isDark = true
            let source = FakeCanvasSource([text])
            if flow == .scrolled { source.book = CanvasText.book([text]) }
            let host = CanvasHost(source, size: CGSize(width: 400, height: 300), configuration: configuration)
            defer { host.close() }
            host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut()
            try await host.settle(100)
            let image: CGImage
            #if os(macOS)
            let bitmap = try XCTUnwrap(host.canvas.bitmapImageRepForCachingDisplay(in: host.canvas.bounds))
            host.canvas.cacheDisplay(in: host.canvas.bounds, to: bitmap)
            image = try XCTUnwrap(bitmap.cgImage)
            #else
            func display(_ layer: CALayer) { layer.displayIfNeeded(); layer.sublayers?.forEach(display) }
            display(host.canvas.layer)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            image = try XCTUnwrap(UIGraphicsImageRenderer(bounds: host.canvas.bounds, format: format).image {
                host.canvas.layer.render(in: $0.cgContext)
            }.cgImage)
            #endif
            XCTAssertGreaterThan(whitePixels(image), 5000, "Graph's contrast backdrop is actually drawn in \(flow)")
        }
    }

    func testExactReportedTextbookGraphWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBLIB_CONTRAST_REPRODUCER"] else {
            throw XCTSkip("Set EPUBLIB_CONTRAST_REPRODUCER to the original #34 EPUB to verify the exact reported asset")
        }
        let publication = try EPUBPublication.open(at: URL(fileURLWithPath: path))
        let data = try publication.data(at: "EPUB/assets/image230-1.png")
        let source = try XCTUnwrap(ReaderImageSource.bitmap(data, path: "EPUB/assets/image230-1.png", key: publication.id))
        XCTAssertEqual(source.pixelSize, CGSize(width: 2448, height: 1076))
        let cache = ReaderImageCache(budget: 16 << 20)
        let original = try XCTUnwrap(cache.image(for: source, maxPixelSize: 800))
        let readable = try XCTUnwrap(cache.image(for: source, maxPixelSize: 800, lightBackdrop: true))
        XCTAssertGreaterThan(whitePixels(readable), whitePixels(original) + 10_000)
        XCTAssertEqual(source.data, data)
        let before = pixels(original), after = pixels(readable)
        for index in stride(from: 0, to: before.count, by: 4) where before[index + 3] == 255 {
            XCTAssertEqual(Array(before[index..<(index + 4)]), Array(after[index..<(index + 4)]), "Opaque graph ink preserves its source color")
        }
        for dark in [false, true] {
            let attachment = ReaderImageAttachment(source: source, sizing: ImageSizing(intrinsic: source.pixelSize),
                alternative: .text("Reported graph"), style: ComputedStyle(), isDark: dark, cache: cache)
            let size = CGSize(width: 795, height: 349)
            let platform = try XCTUnwrap(attachment.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0))
            let drawn = try draw(platform, size: size, darkCanvas: true)
            let output = URL(fileURLWithPath: "/private/tmp/epublib-graph-\(dark ? "readable" : "original")-on-dark.png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, drawn, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
}
