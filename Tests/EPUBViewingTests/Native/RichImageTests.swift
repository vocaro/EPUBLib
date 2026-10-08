import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class RichImageTests: XCTestCase {
    private let viewport = CGSize(width: 400, height: 600)

    private func size(_ sizing: ImageSizing, line: CGFloat = 400, viewport: CGSize? = nil) -> CGSize {
        let viewport = viewport ?? self.viewport
        return sizing.size(lineWidth: line, viewport: viewport, heightLimit: viewport.height)
    }

    // MARK: Sizing

    func testIntrinsicSizeIsOnePointPerPixel() {
        XCTAssertEqual(size(ImageSizing(intrinsic: CGSize(width: 200, height: 100))), CGSize(width: 200, height: 100))
        // No size at all: CSS's default replaced-element size.
        XCTAssertEqual(size(ImageSizing(intrinsic: .zero)), CGSize(width: 300, height: 150))
    }

    func testPercentWidthIsOfTheLineAndKeepsTheAspect() {
        var sizing = ImageSizing(intrinsic: CGSize(width: 800, height: 400))
        sizing.width = .percent(50)
        XCTAssertEqual(size(sizing), CGSize(width: 200, height: 100))
    }

    func testViewportUnitsAreOfTheReadingViewport() {
        var sizing = ImageSizing(intrinsic: CGSize(width: 100, height: 100))
        sizing.height = .viewportHeight(25)
        XCTAssertEqual(size(sizing), CGSize(width: 150, height: 150))
        sizing = ImageSizing(intrinsic: CGSize(width: 100, height: 50))
        sizing.width = .viewportWidth(50)
        XCTAssertEqual(size(sizing), CGSize(width: 200, height: 100))
    }

    func testMaximumsScaleDownWithTheAspectKept() {
        var sizing = ImageSizing(intrinsic: CGSize(width: 1024, height: 1024))
        sizing.maxWidth = .percent(100)
        XCTAssertEqual(size(sizing, line: 300), CGSize(width: 300, height: 300))
        sizing.maxHeight = .viewportHeight(70)
        XCTAssertEqual(size(sizing, viewport: CGSize(width: 400, height: 500)), CGSize(width: 350, height: 350))
        sizing = ImageSizing(intrinsic: CGSize(width: 100, height: 100))
        sizing.maxWidth = .points(40)
        XCTAssertEqual(size(sizing), CGSize(width: 40, height: 40))
    }

    func testAnImageNeverExceedsTheLineOrThePage() {
        XCTAssertEqual(size(ImageSizing(intrinsic: CGSize(width: 2000, height: 1000))), CGSize(width: 400, height: 200))
        XCTAssertEqual(size(ImageSizing(intrinsic: CGSize(width: 300, height: 2000))), CGSize(width: 90, height: 600))
        var sizing = ImageSizing(intrinsic: CGSize(width: 100, height: 100))
        sizing.width = .points(5000)
        XCTAssertEqual(size(sizing), CGSize(width: 400, height: 400))
    }

    func testBothDimensionsFitTheImageInsideThem() {
        var sizing = ImageSizing(intrinsic: CGSize(width: 400, height: 100))
        sizing.width = .points(200); sizing.height = .points(200)
        XCTAssertEqual(size(sizing), CGSize(width: 200, height: 50))
        // Percent heights resolve against the page, so a cover sized 100% × 100% fits it.
        sizing = ImageSizing(intrinsic: CGSize(width: 1068, height: 1562))
        sizing.width = .percent(100); sizing.height = .percent(100)
        let fitted = size(sizing)
        XCTAssertEqual(fitted.width, 400, accuracy: 0.01)
        XCTAssertEqual(fitted.height, 400 * 1562 / 1068, accuracy: 0.01)
    }

    func testAttributesAreHintsThatCSSOverrides() {
        let hinted = ImageSizing(intrinsic: CGSize(width: 64, height: 64), style: ComputedStyle(), widthHint: "55", heightHint: "55")
        XCTAssertEqual(size(hinted), CGSize(width: 55, height: 55))
        var style = ComputedStyle()
        style.width = .points(20)
        let css = ImageSizing(intrinsic: CGSize(width: 64, height: 64), style: style, widthHint: "55", heightHint: nil)
        XCTAssertEqual(size(css), CGSize(width: 20, height: 20))
        XCTAssertEqual(ImageSizing.length("50%", fontSize: 16), .percent(50))
        XCTAssertEqual(ImageSizing.length(" 2em ", fontSize: 16), .points(32))
        XCTAssertEqual(ImageSizing.length("1in", fontSize: 16), .points(96))
        XCTAssertEqual(ImageSizing.length("300px", fontSize: 16), .points(300))
        XCTAssertNil(ImageSizing.length("auto", fontSize: 16))
        XCTAssertNil(ImageSizing.length("-5", fontSize: 16))
    }

    // MARK: Bounds on a line

    private func attachment(_ fixture: RichFixture, _ id: String) throws -> ReaderImageAttachment {
        try XCTUnwrap(RichFixture.attachments(in: fixture.image(id)).first as? ReaderImageAttachment)
    }

    func testSmallInlineImagesSitOnTheBaseline() throws {
        let fixture = try RichFixture("<p>Text <img id='icon' src='icon.png' alt='icon'/> and <img id='mid' src='icon.png'/></p>",
                                      files: ["icon.png": RichFixture.image(width: 16, height: 16)])
        fixture.overrides["mid"] = { $0.verticalAlign = .middle }
        let font = PlatformFont.systemFont(ofSize: 16)
        let icon = try attachment(fixture, "icon")
        XCTAssertEqual(icon.layoutBounds(line(400, font: font)), CGRect(x: 0, y: 0, width: 16, height: 16))
        let mid = try attachment(fixture, "mid")
        XCTAssertEqual(mid.layoutBounds(line(400, font: font)).minY, font.xHeight / 2 - 8, accuracy: 0.001)
    }

    func testLargeAndBlockImagesFillTheirLineExactly() throws {
        let fixture = try RichFixture("<div><img id='big' src='big.png'/></div><img id='block' src='icon.png'/>",
                                      files: ["big.png": RichFixture.image(width: 800, height: 400),
                                              "icon.png": RichFixture.image(width: 16, height: 16)])
        fixture.overrides["block"] = { $0.display = .block }
        let font = PlatformFont.systemFont(ofSize: 16)
        let big = try attachment(fixture, "big")
        XCTAssertEqual(big.layoutBounds(line(400, font: font)), CGRect(x: 0, y: font.descender, width: 400, height: 200))
        XCTAssertEqual(try attachment(fixture, "block").layoutBounds(line(400, font: font)).minY, font.descender)
        // After a first-line indent the image takes the rest of the line rather than a new one.
        XCTAssertEqual(big.layoutBounds(line(400, font: font, position: 30)).width, 370)
        // After text, the whole line: TextKit moves it to a line of its own.
        XCTAssertEqual(big.layoutBounds(line(400, font: font, position: 200)).width, 400)
    }

    func testImagesFitOnePageOfTheReaderContainer() throws {
        let fixture = try RichFixture("<img id='tall' src='tall.png'/>", files: ["tall.png": RichFixture.image(width: 300, height: 3000)])
        let tall = try attachment(fixture, "tall")
        let container = ReaderTextContainer(size: CGSize(width: 400, height: 0))
        container.viewportSize = CGSize(width: 400, height: 500)
        let bounds = tall.attachmentBounds(for: container, proposedLineFragment: CGRect(x: 0, y: 0, width: 400, height: 20),
                                           glyphPosition: .zero, characterIndex: 0)
        XCTAssertEqual(bounds.size, CGSize(width: 50, height: 500))
    }

    // MARK: Resources

    func testImageAttachmentSharesThePublicationBytesAndReadsOnlyTheHeader() throws {
        let cache = ReaderImageCache(budget: 64 << 20)
        let fixture = try RichFixture("<img id='photo' src='images/photo.png' alt=' A  photo '/><img id='turned' src='turned.jpg'/>",
                                      files: ["images/photo.png": RichFixture.image(width: 800, height: 400),
                                              "turned.jpg": RichFixture.image(width: 200, height: 100, jpegOrientation: 6)],
                                      cache: cache)
        let photo = try attachment(fixture, "photo")
        XCTAssertEqual(photo.path, "OPS/images/photo.png")
        XCTAssertEqual(photo.alt, "A photo")
        XCTAssertEqual(try XCTUnwrap(fixture.image("photo")).readerPlainText(), "A photo")
        XCTAssertEqual(photo.source.pixelSize, CGSize(width: 800, height: 400))
        let original = try fixture.publication.data(at: "OPS/images/photo.png")
        XCTAssertEqual(photo.source.data.withUnsafeBytes { $0.baseAddress }, original.withUnsafeBytes { $0.baseAddress })
        // EXIF orientations 5–8 swap the displayed dimensions.
        XCTAssertEqual(try attachment(fixture, "turned").source.pixelSize, CGSize(width: 100, height: 200))
        XCTAssertEqual(cache.decodeCount, 0)
        XCTAssertEqual(fixture.report.report, SectionReport())
    }

    func testDecodingHappensWhenDrawnDownsampledAndCached() throws {
        let cache = ReaderImageCache(budget: 64 << 20)
        let fixture = try RichFixture("<img id='photo' src='photo.png'/>", files: ["photo.png": RichFixture.image(width: 1600, height: 800)],
                                      cache: cache)
        let photo = try attachment(fixture, "photo")
        let bounds = photo.layoutBounds(line(400))
        XCTAssertEqual(bounds.size, CGSize(width: 400, height: 200))
        XCTAssertEqual(cache.decodeCount, 0, "Nothing decodes while the section is built or laid out")
        let image = try XCTUnwrap(photo.image(forBounds: bounds, textContainer: nil, characterIndex: 0))
        let pixels = try XCTUnwrap(Self.draw(image, size: bounds.size, scale: 2))
        XCTAssertEqual(cache.decodeCount, 1)
        XCTAssertEqual(cache.count, 1)
        // The decode is the displayed size at the destination's scale, not the source's.
        XCTAssertLessThanOrEqual(cache.totalCost, 832 * 832 * 4)
        XCTAssertGreaterThan(Self.blue(pixels), 0.5, "The bitmap was drawn")
        _ = Self.draw(try XCTUnwrap(photo.image(forBounds: bounds, textContainer: nil, characterIndex: 0)), size: bounds.size, scale: 2)
        XCTAssertEqual(cache.decodeCount, 1, "Drawing again reuses the cached decode")
        let thumbnail = try XCTUnwrap(cache.image(for: photo.source, maxPixelSize: 100))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 128)
    }

    func testCacheEvictsLeastRecentlyUsedPastItsBudget() throws {
        let files = (0..<4).reduce(into: [String: Data]()) { $0["i\($1).png"] = RichFixture.image(width: 512, height: 512) }
        let fixture = try RichFixture((0..<4).map { "<img id='i\($0)' src='i\($0).png'/>" }.joined(), files: files)
        let sources = try (0..<4).map { try attachment(fixture, "i\($0)").source }
        let probe = ReaderImageCache(budget: 64 << 20)
        let cost = try XCTUnwrap(probe.image(for: sources[0], maxPixelSize: 256)).bytesPerRow * 256
        let cache = ReaderImageCache(budget: cost * 5 / 2)
        for source in sources.prefix(3) { _ = cache.image(for: source, maxPixelSize: 256) }
        XCTAssertEqual(cache.decodeCount, 3)
        XCTAssertEqual(cache.count, 2)
        XCTAssertLessThanOrEqual(cache.totalCost, cache.budget)
        _ = cache.image(for: sources[1], maxPixelSize: 256)
        XCTAssertEqual(cache.decodeCount, 3, "Still cached")
        _ = cache.image(for: sources[3], maxPixelSize: 256)
        _ = cache.image(for: sources[1], maxPixelSize: 256)
        XCTAssertEqual(cache.decodeCount, 4, "Using 1 kept it; 2 was the least recently used")
        _ = cache.image(for: sources[2], maxPixelSize: 256)
        XCTAssertEqual(cache.decodeCount, 5)
        // A cached larger decode serves a smaller request.
        _ = cache.image(for: sources[2], maxPixelSize: 200)
        XCTAssertEqual(cache.decodeCount, 5)
        cache.budget = cost
        XCTAssertLessThanOrEqual(cache.totalCost, cost)
        cache.removeAll()
        XCTAssertEqual(cache.totalCost, 0)
        // A decode larger than the whole budget is returned but not kept.
        let tiny = ReaderImageCache(budget: 10)
        XCTAssertNotNil(tiny.image(for: sources[0], maxPixelSize: 64))
        XCTAssertEqual(tiny.count, 0)
    }

    func testMissingUndecodableAndRemoteImagesShowTheirAltText() throws {
        let fixture = try RichFixture("""
        <img id='missing' src='nowhere.png' alt='Map of the region'/><img id='broken' src='broken.png' alt='Broken'/>
        <img id='remote' src='https://example.com/a.png' alt='Remote'/><img id='silent' src='nowhere.png' alt=''/>
        """, files: ["broken.png": Data("not an image".utf8)])
        let missing = try XCTUnwrap(fixture.image("missing"))
        XCTAssertEqual(missing.string, "Map of the region")
        XCTAssertTrue(RichFixture.attachments(in: missing).isEmpty)
        XCTAssertEqual(missing.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor,
                       ReaderPalette.secondaryText(dark: false))
        XCTAssertEqual(fixture.image("broken")?.string, "Broken")
        XCTAssertEqual(fixture.report.report.unreadableResources, 2)
        XCTAssertEqual(fixture.image("remote")?.string, "Remote")
        XCTAssertEqual(fixture.report.report.unreadableResources, 2, "A refused remote image is not unreadable")
        XCTAssertEqual(fixture.report.report.remoteResourcesRefused, 1)
        XCTAssertNil(fixture.image("silent"))
    }

    func testObjectsWithImageDataAreImagesElseTheirFallback() throws {
        let fixture = try RichFixture("""
        <object id='o' data='chart.png' type='image/png'>Chart</object><object id='v' data='clip.mp4' type='video/mp4'>Clip</object>
        <object id='gone' data='gone.png'>Gone</object><embed id='e' src='chart.png'/>
        """, files: ["chart.png": RichFixture.image(width: 40, height: 20)])
        XCTAssertNotNil(RichFixture.attachments(in: fixture.image("o")).first as? ReaderImageAttachment)
        XCTAssertNil(fixture.image("v"))
        XCTAssertNil(fixture.image("gone"))
        XCTAssertEqual(fixture.report.report.unreadableResources, 1)
        XCTAssertNotNil(RichFixture.attachments(in: fixture.image("e")).first as? ReaderImageAttachment)
    }

    // MARK: SVG

    func testSVGWrappingOneImageShowsThatImageFittedToThePage() throws {
        let fixture = try RichFixture("""
        <div><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" id="cover" height="100%" width="100%" \
        preserveAspectRatio="xMidYMid meet" version="1.1" viewBox="0 0 1068 1562"><title>Cover</title>
        <image width="1068" height="1562" xlink:href="cover.jpg"/></svg></div>
        <svg xmlns="http://www.w3.org/2000/svg" id="half" width="200" height="100" viewBox="0 0 200 100"><image x="100" width="100" height="100" href="cover.jpg"/></svg>
        """, files: ["cover.jpg": RichFixture.image(width: 534, height: 781)])
        let cover = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("cover")).first as? ReaderImageAttachment)
        XCTAssertEqual(cover.path, "OPS/cover.jpg")
        XCTAssertEqual(cover.alt, "Cover")
        XCTAssertEqual(cover.textEquivalent, "Cover")
        XCTAssertNil(cover.contentRect)
        let size = cover.displaySize(line(400))
        XCTAssertEqual(size.width, 400, accuracy: 0.01)
        XCTAssertEqual(size.height, 400 * 1562 / 1068, accuracy: 0.01)
        XCTAssertLessThanOrEqual(cover.displaySize(line(600)).height, 600)
        let half = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("half")).first as? ReaderImageAttachment)
        XCTAssertEqual(half.displaySize(line(400)), CGSize(width: 200, height: 100))
        let placed = try XCTUnwrap(half.contentRect)
        XCTAssertEqual(placed.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(placed.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(placed.height, 1, accuracy: 0.001)
        XCTAssertEqual(fixture.report.report, SectionReport())
    }

    func testOtherSVGUsesThePlatformDecoderWhereItCan() throws {
        let drawing = "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='60' viewBox='0 0 120 60'><rect width='120' height='60' fill='red'/></svg>"
        let fixture = try RichFixture("""
        \(drawing.replacingOccurrences(of: "<svg ", with: "<svg id='inline' "))<img id='file' src='diagram.svg' alt='Diagram'/>
        """, files: ["diagram.svg": Data(drawing.utf8)])
        let decodes = ReaderImageSource.svg(Data(drawing.utf8), path: "", key: "probe") != nil
        #if os(macOS)
        XCTAssertTrue(decodes, "NSImage decodes SVG on macOS 27")
        #endif
        if decodes {
            let inline = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("inline")).first as? ReaderImageAttachment)
            XCTAssertEqual(inline.source.format, .svg)
            XCTAssertEqual(inline.displaySize(line(400)), CGSize(width: 120, height: 60))
            let file = try XCTUnwrap(RichFixture.attachments(in: fixture.image("file")).first as? ReaderImageAttachment)
            XCTAssertEqual(file.path, "OPS/diagram.svg")
            XCTAssertEqual(file.displaySize(line(400)), CGSize(width: 120, height: 60))
            let rasterized = try XCTUnwrap(ReaderImageCache(budget: 1 << 20).image(for: file.source, maxPixelSize: 240))
            XCTAssertEqual(rasterized.width, 256, "Rasterized at the requested size, rounded up to 64 pixels")
            XCTAssertEqual(rasterized.height, 128)
            XCTAssertEqual(fixture.report.report, SectionReport())
        } else {
            XCTAssertEqual(fixture.svg("inline")?.length, 0)
            XCTAssertEqual(fixture.image("file")?.string, "Diagram")
            XCTAssertEqual(fixture.report.report.unsupportedElements["svg"], 2)
        }
    }

    func testUndrawableSVGShowsItsTitleAndIsDisclosed() throws {
        let fixture = try RichFixture("""
        <svg xmlns='http://www.w3.org/2000/svg' id='empty' width='0' height='0'><title>Flow chart</title><text>Start</text></svg>
        """)
        let result = try XCTUnwrap(fixture.svg("empty"))
        XCTAssertEqual(result.string, "Flow chart", "Its title, never the drawing's own text")
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg"], 1)
    }

    func testSerializedSVGReachesNothingOutsideTheDocument() throws {
        let fixture = try RichFixture("""
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" id="s" width="10" height="10" onload="alert(1)">
        <script>alert(1)</script><foreignObject><p xmlns="http://www.w3.org/1999/xhtml">html</p></foreignObject>
        <defs><linearGradient id="g"/></defs><rect fill="url(#g)" style="fill:url(https://example.com/x.svg#p)" width="5" height="5"/>
        <use xlink:href="#g"/><image href="https://example.com/a.png" width="1" height="1"/><image xlink:href="dot.png" width="1" height="1"/>
        <style>@import url(https://example.com/s.css);</style><text>a &lt; b</text></svg>
        """, files: ["dot.png": RichFixture.image(width: 1, height: 1)])
        let svg = fixture.element("s")
        let data = try XCTUnwrap(SVGContent.serialize(svg, resolve: fixture.context.resolve, publication: fixture.publication))
        let text = String(decoding: data, as: UTF8.self)
        for absent in ["script", "alert", "foreignObject", "html", "example.com", "onload", "@import"] {
            XCTAssertFalse(text.contains(absent), "\(absent) in \(text)")
        }
        XCTAssertTrue(text.contains("fill=\"url(#g)\""))
        XCTAssertTrue(text.contains("xlink:href=\"#g\""))
        XCTAssertTrue(text.contains("xlink:href=\"data:image/png;base64,"))
        XCTAssertTrue(text.contains("a &lt; b"))
        XCTAssertNotNil(try? ContentDocument.parse(data, path: "s.svg"), "Well-formed")
        XCTAssertNil(SVGContent.wrappedImage(svg), "It draws more than one image")
    }

    // MARK: Helpers

    /// Draws an attachment image into a bitmap at `scale`, as a text view would.
    static func draw(_ image: PlatformImage, size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        #if os(macOS)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.current = previous
        #else
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        #endif
        return context.makeImage()
    }

    /// The blue channel at the image's centre, 0–1.
    static func blue(_ image: CGImage) -> CGFloat {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return CGFloat(context.data!.assumingMemoryBound(to: UInt8.self)[2]) / 255
    }
}
