import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import UniformTypeIdentifiers
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// SVG illustrations: sizing, `preserveAspectRatio`, the single-image wrapper fast path,
/// accessible labels, disclosed omissions, the documented rendering limits, SVG content
/// documents as spine items, and robustness against adversarial drawings. What the renderer and
/// serializer do on their own is tested in StaticSVG (`SVGCoverageTests`).
final class RichMediaSVGCoverageTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"

    private func build(_ body: String, files: [String: Data] = [:]) throws -> SectionText {
        try RichMediaBook(body: body, files: files).build()
    }

    private func image(_ body: String, files: [String: Data] = [:]) throws -> (ReaderImageAttachment?, SectionText) {
        let text = try build(body, files: files)
        return (text.richMediaImages.first, text)
    }

    // MARK: Sizing

    func testIntrinsicSizeFromViewBoxWidthHeightOrNeither() throws {
        let ns = Self.ns
        // width/height present: that box, with the viewBox letterboxed inside.
        XCTAssertEqual(try image("<p><svg \(ns) width='100' height='50' viewBox='0 0 40 40'><rect width='40' height='40'/></svg></p>").0?.sizing.intrinsic,
                       CGSize(width: 100, height: 50))
        // viewBox only: its size is the intrinsic size.
        XCTAssertEqual(try image("<p><svg \(ns) viewBox='0 0 100 50'><rect width='100' height='50'/></svg></p>").0?.sizing.intrinsic,
                       CGSize(width: 100, height: 50))
        // width only, with a viewBox: height follows the viewBox ratio.
        XCTAssertEqual(try image("<p><svg \(ns) width='200' viewBox='0 0 100 50'><rect width='100' height='50'/></svg></p>").0?.sizing.intrinsic,
                       CGSize(width: 200, height: 100))
        // A percentage width is kept as a percentage; the viewBox gives the ratio.
        let percent = try XCTUnwrap(try image("<p><svg \(ns) width='50%' viewBox='0 0 100 50'><rect width='100' height='50'/></svg></p>").0)
        XCTAssertEqual(percent.sizing.width, .percent(50))
        XCTAssertEqual(percent.sizing.intrinsic, CGSize(width: 100, height: 50))
    }

    // MARK: The single-image wrapper fast path

    func testWrapperFastPathHrefXlinkPlacementAndNonFastPaths() throws {
        let cover = RichMediaImages.solid(width: 60, height: 80)
        let files = ["cover.jpg": cover, "my cover.jpg": cover]
        // href, xlink:href and a percent-encoded path all take the raster fast path.
        for reference in ["cover.jpg", "my%20cover.jpg"] {
            let (image, _) = try image("<div><svg \(Self.ns) width='100%' height='100%' viewBox='0 0 60 80'><image width='60' height='80' xlink:href='\(reference)'/></svg></div>", files: files)
            XCTAssertEqual(image?.source.format, .bitmap, "\(reference): a lone wrapped image keeps the raster fast path")
        }
        XCTAssertEqual(try image("<div><svg \(Self.ns) viewBox='0 0 60 80'><image width='60' height='80' href='cover.jpg'/></svg></div>", files: files).0?.source.format, .bitmap, "plain href works too")
        // A fragment reference names the drawing's own document, not a file read in its place,
        // whatever follows its `#`: "#" and a mark after it are one `Character`
        // (https://github.com/vocaro/EPUBLib/issues/641). The drawing goes to the renderer with
        // its image, which StaticSVG's serializer keeps as a fragment too, and the renderer has
        // no image to draw for it, so its title stands in.
        for reference in ["#cover", "#&#x301;cover"] {
            let (shown, text) = try image("<div><svg \(Self.ns) viewBox='0 0 60 80'><title>Cover</title><image width='60' height='80' href='\(reference)'/></svg></div>", files: files)
            XCTAssertNil(shown, reference)
            XCTAssertEqual(text.richMediaPlain, "Cover", reference)
            XCTAssertEqual(text.report.unreadableResources, 0, "\(reference): no file was read")
            XCTAssertEqual(text.report.unsupportedElements, ["svg": 1], "\(reference): the renderer was given the drawing, its image not left out")
        }
        // A wrapped image not filling its box carries a content rect in unit fractions.
        let half = try XCTUnwrap(try image("<p><svg \(Self.ns) width='200' height='100' viewBox='0 0 200 100'><image x='100' width='100' height='100' href='cover.jpg'/></svg></p>", files: files).0)
        let rect = try XCTUnwrap(half.contentRect)
        XCTAssertEqual(rect.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(rect.width, 0.5, accuracy: 0.001)
        // Two images, or an image plus text, are not the fast path: they go through the renderer.
        XCTAssertEqual(try image("<div><svg \(Self.ns) width='120' height='80' viewBox='0 0 120 80'><image width='60' height='80' href='cover.jpg'/><image x='60' width='60' height='80' href='cover.jpg'/></svg></div>", files: files).0?.source.format, .svg)
        XCTAssertEqual(try image("<div><svg \(Self.ns) width='120' height='80' viewBox='0 0 120 80'><image width='60' height='80' href='cover.jpg'/><text x='62' y='40'>Hi</text></svg></div>", files: files).0?.source.format, .svg)
    }

    func testWrapperWithAMissingImageFallsBackToItsLabel() throws {
        let (image, text) = try image("<div><svg \(Self.ns) width='100%' height='100%' viewBox='0 0 60 80'><title>Cover</title><image width='60' height='80' xlink:href='gone.jpg'/></svg></div>")
        XCTAssertNil(image)
        XCTAssertEqual(text.richMediaPlain, "Cover", "the SVG's title stands in for a missing wrapped image")
        XCTAssertEqual(text.report.unreadableResources, 1)
    }

    private func markedCover() throws -> Data {
        try XCTUnwrap(RichMediaImages.encode([RichMediaImages.cornerMarked(width: 600, height: 800)], as: .png))
    }

    private func draw(_ image: ReaderImageAttachment, size: CGSize) throws -> CGImage {
        let platform = try XCTUnwrap(image.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0))
        return try draw(platform, size: size)
    }

    private func draw(_ platform: PlatformImage, size: CGSize) throws -> CGImage {
        #if os(iOS)
        // UIImage.draw expects UIKit's top-left coordinate system. Pushing a raw,
        // unflipped CGContext reverses the result vertically; the attachment itself
        // returns an upright UIImage and uses this UIKit renderer for placed images.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            platform.draw(in: CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(drawn.cgImage)
        #else
        return try XCTUnwrap(RichImageTests.draw(platform, size: size, scale: 1))
        #endif
    }

    func testWrapperRasterHelperKeepsAnIndependentImageUpright() throws {
        // This image is made directly in Core Graphics, without SVG or an attachment:
        // its top-left quarter is red and all three other quarters are blue.
        let bitmap = RichMediaImages.cornerMarked(width: 40, height: 80)
        let size = CGSize(width: 40, height: 80)
        #if os(iOS)
        let platform = UIImage(cgImage: bitmap)
        #else
        let platform = NSImage(cgImage: bitmap, size: size)
        #endif
        let drawn = try draw(platform, size: size)
        let samples: [(Int, Int, [UInt8])] = [(5, 10, [255, 0, 0, 255]), (35, 10, [0, 0, 255, 255]),
                                             (5, 70, [0, 0, 255, 255]), (35, 70, [0, 0, 255, 255])]
        for (x, y, expected) in samples {
            XCTAssertEqual(RichMediaImages.rgba(bitmap, x: x, y: y), expected, "control image at (\(x), \(y))")
            XCTAssertEqual(RichMediaImages.rgba(drawn, x: x, y: y), expected, "platform drawing at (\(x), \(y))")
        }
    }

    func testPercentageWrapperShowsTheWholePictureInItsViewBox() throws {
        let cover = try markedCover()
        let wrapper = try XCTUnwrap(try image("<p><svg \(Self.ns) viewBox='0 0 300 400'><image width='100%' height='100%' href='cover.png'/></svg></p>", files: ["cover.png": cover]).0)
        XCTAssertEqual(wrapper.source.format, .bitmap)
        XCTAssertEqual(wrapper.sizing.intrinsic, CGSize(width: 300, height: 400))
        XCTAssertNil(wrapper.contentRect, "100% fills the viewBox even when the bitmap is twice its size")
        let size = CGSize(width: 300, height: 400)
        XCTAssertEqual(wrapper.imageRect(in: size), CGRect(origin: .zero, size: size))
        let bitmap = try draw(wrapper, size: size)
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 30, y: 40), [255, 0, 0, 255])
        for (x, y) in [(270, 40), (30, 360), (270, 360)] {
            XCTAssertEqual(RichMediaImages.rgba(bitmap, x: x, y: y), [0, 0, 255, 255], "the other three quarters remain visible")
        }
    }

    func testWrapperPercentagesResolveEachAxisAndAutoKeepsTheImageRatio() throws {
        let cover = try markedCover(), size = CGSize(width: 300, height: 400)
        let cases: [(String, CGRect)] = [
            ("width='50%' height='50%'", CGRect(x: 0, y: 0, width: 150, height: 200)),
            ("width='50%' height='200'", CGRect(x: 0, y: 0, width: 150, height: 200)),
            ("width='150' height='50%'", CGRect(x: 0, y: 0, width: 150, height: 200)),
            ("width='50%'", CGRect(x: 0, y: 0, width: 150, height: 200)),
            ("height='25%'", CGRect(x: 0, y: 0, width: 75, height: 100)),
            ("width='200%' height='200%'", CGRect(x: 0, y: 0, width: 600, height: 800)),
            ("x='50%' y='25%' width='50%' height='50%'", CGRect(x: 150, y: 100, width: 150, height: 200)),
            ("x='-25%' width='50%' height='50%'", CGRect(x: -75, y: 0, width: 150, height: 200))
        ]
        for (attributes, expected) in cases {
            let wrapper = try XCTUnwrap(try image("<p><svg \(Self.ns) viewBox='0 0 300 400'><image \(attributes) href='cover.png'/></svg></p>", files: ["cover.png": cover]).0)
            XCTAssertEqual(wrapper.source.format, .bitmap, attributes)
            XCTAssertEqual(wrapper.imageRect(in: size), expected, attributes)
        }
        let offset = try XCTUnwrap(try image("<p><svg \(Self.ns) viewBox='30 40 300 400'><image x='10%' y='10%' width='100%' height='100%' href='cover.png'/></svg></p>", files: ["cover.png": cover]).0)
        XCTAssertNil(offset.contentRect, "percentages use viewBox size, then its origin is subtracted")
        let half = try XCTUnwrap(try image("<p><svg \(Self.ns) viewBox='0 0 300 400'><image width='50%' height='50%' href='cover.png'/></svg></p>", files: ["cover.png": cover]).0)
        let bitmap = try draw(half, size: size)
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 15, y: 20), [255, 0, 0, 255])
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 135, y: 180), [0, 0, 255, 255])
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 200, y: 300)[3], 0)
    }

    func testPercentageWrapperMapsThroughTheOuterMeetViewport() throws {
        let wrapper = try XCTUnwrap(try image("<p><svg \(Self.ns) width='200' height='100' viewBox='0 0 100 100'><image width='100%' height='100%' href='cover.png'/></svg></p>", files: ["cover.png": try markedCover()]).0)
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(wrapper.contentRect, CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(wrapper.imageRect(in: size), CGRect(x: 62.5, y: 0, width: 75, height: 100))
        let bitmap = try draw(wrapper, size: size)
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 20, y: 50)[3], 0)
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 70, y: 10), [255, 0, 0, 255])
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 130, y: 90), [0, 0, 255, 255])
    }

    func testPercentageWrappersRetainTransformsAndNonDefaultAspectFits() throws {
        let cover = try markedCover()
        let cases: [(String, String, [(Int, Int, [UInt8])])] = [
            ("", "transform='translate(150 200)' width='50%' height='50%'", [(15, 20, [0, 0, 0, 0]), (165, 220, [255, 0, 0, 255]), (285, 380, [0, 0, 255, 255])]),
            ("", "width='100%' height='50%' preserveAspectRatio='none'", [(30, 20, [255, 0, 0, 255]), (270, 180, [0, 0, 255, 255]), (30, 300, [0, 0, 0, 0])]),
            ("", "width='100%' height='50%' preserveAspectRatio='xMidYMin slice'", [(30, 180, [255, 0, 0, 255]), (270, 180, [0, 0, 255, 255]), (30, 300, [0, 0, 0, 0])]),
            ("preserveAspectRatio='none'", "width='100%' height='100%'", [(30, 40, [255, 0, 0, 255]), (270, 360, [0, 0, 255, 255])])
        ]
        for (outer, inner, samples) in cases {
            let wrapper = try XCTUnwrap(try image("<p><svg \(Self.ns) \(outer) viewBox='0 0 300 400'><image \(inner) href='cover.png'/></svg></p>", files: ["cover.png": cover]).0)
            XCTAssertEqual(wrapper.source.format, .svg, inner)
            let bitmap = try draw(wrapper, size: CGSize(width: 300, height: 400))
            for (x, y, expected) in samples { XCTAssertEqual(RichMediaImages.rgba(bitmap, x: x, y: y), expected, "\(outer) \(inner): (\(x), \(y))") }
        }
        let nested = try XCTUnwrap(try image("<p><svg \(Self.ns) viewBox='0 0 300 400'><svg x='150' y='200' width='150' height='200' viewBox='0 0 300 400'><image width='100%' height='100%' href='cover.png'/></svg></svg></p>", files: ["cover.png": cover]).0)
        XCTAssertEqual(nested.source.format, .svg, "a nested SVG establishes its own percentage viewport")
        let bitmap = try draw(nested, size: CGSize(width: 300, height: 400))
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 30, y: 40)[3], 0)
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 165, y: 220), [255, 0, 0, 255])
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 285, y: 380), [0, 0, 255, 255])
    }

    func testOuterAspectRatioModesKeepPercentageImageGeometry() throws {
        let cover = try markedCover(), size = CGSize(width: 600, height: 400)
        let cases: [(String, [(Int, Int, [UInt8])])] = [
            ("none", [(60, 40, [255, 0, 0, 255]), (540, 360, [0, 0, 255, 255])]),
            ("xMidYMin slice", [(60, 360, [255, 0, 0, 255]), (540, 360, [0, 0, 255, 255])]),
            ("xMinYMid meet", [(30, 40, [255, 0, 0, 255]), (270, 360, [0, 0, 255, 255]), (540, 360, [0, 0, 0, 0])])
        ]
        for (fit, samples) in cases {
            let wrapper = try XCTUnwrap(try image("<p><svg \(Self.ns) width='600' height='400' viewBox='0 0 300 400' preserveAspectRatio='\(fit)'><image width='100%' height='100%' href='cover.png'/></svg></p>", files: ["cover.png": cover]).0)
            XCTAssertEqual(wrapper.source.format, .svg, fit)
            let bitmap = try draw(wrapper, size: size)
            for (x, y, expected) in samples { XCTAssertEqual(RichMediaImages.rgba(bitmap, x: x, y: y), expected, "\(fit): (\(x), \(y))") }
        }
    }

    // MARK: Drawing and labels

    func testAccessibleLabelFromTitleAndDescription() throws {
        let ns = Self.ns
        // A direct-child title names the SVG; first-title-wins with the description appended.
        XCTAssertEqual(try image("<p><svg \(ns) width='20' height='20'><title>Diagram</title><rect width='5' height='5'/></svg></p>").0?.alt, "Diagram")
        XCTAssertEqual(try image("<p><svg \(ns) width='20' height='20'><title>First</title><title>Second</title><desc> A  b </desc><rect width='5' height='5'/></svg></p>").0?.alt, "First. A b", "only the first title, whitespace collapsed, with the description")
        // Per SVG, only a direct-child title names the root: one nested in a group is ignored.
        XCTAssertEqual(try image("<p><svg \(ns) width='20' height='20'><g><title>Inner</title></g><rect width='5' height='5'/></svg></p>").0?.alt, "", "a title inside a child group is not the root's label")
        // No title: the fallback is the drawing's own text when it cannot be shown.
        let (undrawable, text) = try image("<p><svg \(ns) width='0' height='0'><text>Start</text></svg></p>")
        XCTAssertNil(undrawable)
        XCTAssertEqual(text.richMediaPlain, "Start")
    }

    // MARK: Disclosed omissions

    func testScriptAnimationForeignObjectAndFilterAreOmittedAndDisclosed() throws {
        let ns = Self.ns
        let (drawn, text) = try image("<p><svg \(ns) width='20' height='20'><script>1</script><rect width='20' height='20' fill='blue'><animate attributeName='x' from='0' to='5' dur='1s'/></rect><foreignObject width='10' height='10'><p xmlns='http://www.w3.org/1999/xhtml'>hi</p></foreignObject></svg></p>")
        let bitmap = try XCTUnwrap(drawn?.source.decode(maxPixelSize: 20))
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 10, y: 10), [0, 0, 255, 255], "the rest of the drawing still renders")
        XCTAssertEqual(text.report.unsupportedElements["svg:script"], 1)
        XCTAssertEqual(text.report.unsupportedElements["svg:animate"], 1)
        XCTAssertEqual(text.report.unsupportedElements["svg:foreignObject"], 1)
        // A filter effect is omitted; the filtered shape still draws.
        let filtered = try image("<p><svg \(ns) width='20' height='20'><desc>Blurred</desc><filter id='f'><feGaussianBlur stdDeviation='2'/></filter><rect width='20' height='20' filter='url(#f)'/></svg></p>")
        XCTAssertEqual(filtered.1.report.unsupportedElements["svg:filter"], 1)
        XCTAssertNotNil(filtered.0, "a filtered diagram is shown with the filter omitted")
        // A pattern fill cannot be approximated: the label stands in.
        let pattern = try image("<p><svg \(ns) width='10' height='10'><title>Pattern</title><defs><pattern id='p' patternUnits='userSpaceOnUse' width='1e9' height='1e9'><rect width='1e9' height='1e9'/></pattern></defs><rect width='10' height='10' fill='url(#p)'/></svg></p>")
        XCTAssertNil(pattern.0)
        XCTAssertEqual(pattern.1.richMediaPlain, "Pattern")
        XCTAssertEqual(pattern.1.report.unsupportedElements["svg:pattern"], 1)
    }

    // MARK: Rendering limits (doc: 4 MiB, 10,000 nodes, depth 64)

    /// An archive SVG past a limit shows its alt text. The renderer's own boundaries, at each
    /// limit, are StaticSVG's half of this test (`SVGCoverageTests`).
    func testRenderingLimitBoundariesShowFallbackText() throws {
        let ns = "xmlns='http://www.w3.org/2000/svg'"
        // Depth: nesting past the limit falls back.
        func nested(_ groups: Int) -> String { "<svg \(ns) width='10' height='10'>" + String(repeating: "<g>", count: groups) + "<rect width='5' height='5'/>" + String(repeating: "</g>", count: groups) + "</svg>" }
        XCTAssertNil(try image("<p><img src='deep.svg' alt='Deep'/></p>", files: ["deep.svg": Data(nested(70).utf8)]).0, "an over-deep archive SVG shows its alt text")
    }

    // MARK: SVG content document as a spine item

    func testSVGSpineItemRendersWithAPositionAndResolvableCFI() throws {
        let spine = "<svg \(Self.ns) width='200' height='100' viewBox='0 0 200 100'><title>Plate one</title><rect width='200' height='100' fill='green'/><text x='10' y='50' font-size='20'>Plate</text></svg>"
        let book = try RichMediaBook(section: spine, first: ("plate.svg", "image/svg+xml"))
        let text = book.build()
        XCTAssertEqual(text.richMediaImages.count, 1, "an SVG spine item renders as one image")
        XCTAssertEqual(text.richMediaImages.first?.source.format, .svg)
        XCTAssertFalse(text.report.withheld, "the section is not withheld")
        XCTAssertEqual(text.map.length, text.string.length, "the section has a text map")
        let position = try XCTUnwrap(text.map.position(at: 0, in: text.document), "the single character has a DOM position")
        let cfis = try SpineCFIs(publication: book.publication)
        let cfi = cfis.cfi(spineIndex: 0, start: position, end: position, in: text.document)
        XCTAssertTrue(EPUBCFI.isWellFormed(cfi), "a CFI into the SVG spine item is well-formed: \(cfi)")
        let resolved = try XCTUnwrap(cfis.resolve(cfi))
        XCTAssertEqual(resolved.spineIndex, 0)
        XCTAssertNotNil(EPUBCFI.resolve(localPath: resolved.localPath, in: text.document), "the CFI resolves back to a position")
    }

    // MARK: Malformed and entity SVG

    func testMalformedAndEntityDeclaringSVGFallBack() throws {
        // Not well-formed: it falls back to its alt text and is disclosed.
        let malformed = try image("<p><img src='bad.svg' alt='Chart'/></p>", files: ["bad.svg": Data("<svg \(Self.ns) width='30' height='10'><text>Label</text><rect></svg>".utf8)])
        XCTAssertNil(malformed.0)
        XCTAssertEqual(malformed.1.richMediaPlain, "Chart")
        XCTAssertEqual(malformed.1.report.unsupportedElements["svg"], 1)
        // An internal entity declaration is refused for safety (doc: "XMLSafety refuses entity declarations").
        let entity = "<?xml version='1.0'?>\n<!DOCTYPE svg [ <!ENTITY ns 'http://www.w3.org/2000/svg'> ]>\n<svg xmlns='&ns;' width='30' height='10'><rect width='30' height='10' fill='red'/></svg>"
        let entitySVG = try image("<p><img src='e.svg' alt='Entity'/></p>", files: ["e.svg": Data(entity.utf8)])
        XCTAssertNil(entitySVG.0, "an SVG with an internal entity declaration is refused")
        XCTAssertEqual(entitySVG.1.richMediaPlain, "Entity")
        // A plain SVG DOCTYPE without an internal subset is fine.
        let doctype = "<!DOCTYPE svg PUBLIC '-//W3C//DTD SVG 1.1//EN' 'http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd'>\n<svg xmlns='http://www.w3.org/2000/svg' width='30' height='10'><rect width='30' height='10' fill='red'/></svg>"
        XCTAssertNotNil(try image("<p><img src='d.svg' alt='D'/></p>", files: ["d.svg": Data(doctype.utf8)]).0, "a DOCTYPE without an internal subset renders")
    }

    func testSVGInObjectAndAsImg() throws {
        let drawing = "<svg xmlns='http://www.w3.org/2000/svg' width='30' height='10'><rect width='30' height='10' fill='red'/></svg>"
        let files = ["d.svg": Data(drawing.utf8)]
        XCTAssertEqual(try image("<p><img src='d.svg' alt='I'/></p>", files: files).0?.source.format, .svg)
        XCTAssertEqual(try image("<p><object data='d.svg' type='image/svg+xml'>Fallback</object></p>", files: files).0?.source.format, .svg)
    }

    // MARK: Images in data: URLs — EPUB 3.3 §3.7 (#657)

    private static func isRed(_ pixel: [UInt8]) -> Bool { pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60 && pixel[3] == 255 }

    /// A 30 × 10 drawing: an `<image>` with `image`'s attributes in its left third, blue in the rest.
    private static func drawing(_ image: String) -> String {
        "<svg \(ns) width='30' height='10'><image \(image) width='10' height='10'/><rect x='10' width='20' height='10' fill='blue'/></svg>"
    }

    /// That `attachment` is a drawing (`drawing(_:)`) whose left third is red where `image` is
    /// true and empty where it is false, and whose rest is blue.
    private func assertDraws(_ attachment: ReaderImageAttachment?, image: Bool, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(attachment?.source, message, file: file, line: line)
        XCTAssertEqual(source.format, .svg, message, file: file, line: line)
        let bitmap = try XCTUnwrap(source.decode(maxPixelSize: 30), message, file: file, line: line)
        let left = RichMediaImages.rgba(bitmap, x: 5, y: 5)
        XCTAssertTrue(image ? Self.isRed(left) : left[3] == 0, "\(message): \(left)", file: file, line: line)
        XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 20, y: 5), [0, 0, 255, 255], message, file: file, line: line)
    }

    /// An SVG `<image>` whose `href` is a `data:` URL draws its image, as a browser does: in a
    /// drawing in the document, in one from the archive, and in one inside another; named by
    /// `href` or `xlink:href`; a bitmap or a drawing; in the forms the data: URL processor reads.
    /// The URL is never resolved, so nothing is counted unreadable, or refused as remote.
    func testAnImageInADataURLIsDrawnInAnSVG() throws {
        let red = RichMediaImages.solid(width: 10, height: 10, red: 1, green: 0, blue: 0)
        let b64 = red.base64EncodedString()
        let square = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10' fill='red'/></svg>"
        let escaped = try XCTUnwrap(square.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        for reference in ["href='data:image/png;base64,\(b64)'", "xlink:href='data:image/png;base64,\(b64)'",
                          "href=' DATA:Image/PNG;Base64,\(b64.prefix(8))&#10;\(b64.dropFirst(8))'",
                          "href='data:image/png,\(red.map { String(format: "%%%02X", $0) }.joined())'",
                          "href='data:image/svg+xml,\(escaped)'",
                          "href='data:image/svg+xml;base64,\(Data(square.utf8).base64EncodedString())'"] {
            let message = String(reference.prefix(40))
            let files = ["d.svg": Data(Self.drawing(reference).utf8)]
            let inline = try image("<p>\(Self.drawing(reference))</p>")
            try assertDraws(inline.0, image: true, "inline, " + message)
            let archived = try image("<p><img src='d.svg' alt='Drawing'/></p>", files: files)
            try assertDraws(archived.0, image: true, "from the archive, " + message)
            // An empty rectangle keeps the outer drawing from being a single-image wrapper.
            let nested = try image("<p><svg \(Self.ns) width='30' height='10'><image href='d.svg' width='30' height='10'/><rect width='0' height='0'/></svg></p>", files: files)
            try assertDraws(nested.0, image: true, "inside a drawing, " + message)
            for text in [inline.1, archived.1, nested.1] {
                XCTAssertEqual(text.report.unsupportedElements, [:], message)
                XCTAssertEqual(text.report.unreadableResources, 0, message)
                XCTAssertEqual(text.report.remoteResourcesRefused, 0, message)
            }
        }
    }

    /// An SVG that is only an `<image>` in a `data:` URL shows that image, as one from the archive
    /// is shown: a bitmap as itself, a drawing drawn, and neither by its fallback text. Each is
    /// known in the image cache by the position of its `<image>`. One that is no usable image
    /// shows the SVG's label and is counted unreadable, as a wrapped archive image that is missing.
    func testAnSVGThatIsOnlyAnImageInADataURLShowsIt() throws {
        let red = RichMediaImages.solid(width: 60, height: 80, red: 1, green: 0, blue: 0).base64EncodedString()
        let blue = RichMediaImages.solid(width: 60, height: 80, red: 0, green: 0, blue: 1).base64EncodedString()
        let square = "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='80'><rect width='60' height='80' fill='red'/></svg>"
        let escaped = try XCTUnwrap(square.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        func wrapper(_ reference: String) -> String {
            "<div><svg \(Self.ns) viewBox='0 0 60 80'><title>Cover</title><image width='60' height='80' \(reference)/></svg></div>"
        }
        let text = try build(wrapper("href='data:image/png;base64,\(red)'") + wrapper("xlink:href='data:image/png;base64,\(blue)'")
                             + wrapper("href='data:image/svg+xml,\(escaped)'"))
        let images = text.richMediaImages
        XCTAssertEqual(images.map(\.source.format), [.bitmap, .bitmap, .svg])
        XCTAssertEqual(images.map(\.source.pixelSize), [CGSize(width: 60, height: 80), CGSize(width: 60, height: 80), CGSize(width: 60, height: 80)])
        XCTAssertEqual(images.map(\.path), ["", "", ""], "none has an archive path")
        XCTAssertEqual(images.map(\.alternative), [.text("Cover"), .text("Cover"), .text("Cover")])
        XCTAssertEqual(Set(images.map(\.source.key)).count, 3)
        let pixels = try images.map { RichMediaImages.rgba(try XCTUnwrap($0.source.decode(maxPixelSize: 80)), x: 30, y: 40) }
        if pixels.count == 3 {
            XCTAssertTrue(Self.isRed(pixels[0]), "\(pixels[0])")
            XCTAssertGreaterThan(pixels[1][2], pixels[1][0], "the second is blue")
            XCTAssertTrue(Self.isRed(pixels[2]), "\(pixels[2])")
        }
        XCTAssertFalse(text.richMediaPlain.contains("Cover"), "no fallback text is shown")
        XCTAssertEqual(text.report.unreadableResources, 0)
        XCTAssertEqual(text.report.unsupportedElements, [:])
        for reference in ["href='data:image/png;base64'", "href='data:text/plain;base64,\(red)'", "href='data:image/png;base64,AAAA'"] {
            let (image, text) = try image(wrapper(reference))
            XCTAssertNil(image, reference)
            XCTAssertEqual(text.richMediaPlain, "Cover", reference)
            XCTAssertEqual(text.report.unreadableResources, 1, reference)
            XCTAssertEqual(text.report.remoteResourcesRefused, 0, reference)
        }
    }

    /// An `<image>` whose `data:` URL is no usable image is left out of its drawing as an archive
    /// image that cannot be decoded is, and disclosed as one: a URL the processor cannot read, one
    /// whose type is not an image's, bytes no decoder reads, a bitmap with more pixels than one
    /// image may have, and a drawing that cannot be drawn. It is no resource from the internet,
    /// and is not counted as one refused.
    func testAnImageInADataURLThatIsNoUsableImageIsLeftOutOfItsDrawing() throws {
        let png = RichMediaImages.solid(width: 10, height: 10).base64EncodedString()
        let huge = RichMediaImages.headerOnlyPNG(width: 4097, height: 4097)
        // StaticSVG's bound on the pixels of a drawing's images together.
        XCTAssertGreaterThan(4097 * 4097, 16 * 1024 * 1024)
        for href in ["data:image/png;base64", "data:text/plain;base64,\(png)", "data:,\(png)", "data:image/png;base64,AAAA",
                     "data:image/png;base64,\(huge.base64EncodedString())", "data:image/svg+xml,%3Csvg%3E"] {
            let message = String(href.prefix(40))
            let inline = try image("<p>\(Self.drawing("href='\(href)'"))</p>")
            try assertDraws(inline.0, image: false, "inline, " + message)
            let archived = try image("<p><img src='d.svg' alt='Drawing'/></p>", files: ["d.svg": Data(Self.drawing("href='\(href)'").utf8)])
            try assertDraws(archived.0, image: false, "from the archive, " + message)
            for text in [inline.1, archived.1] {
                XCTAssertEqual(text.report.unsupportedElements, ["svg:image": 1], message)
                XCTAssertEqual(text.report.unreadableResources, 0, message)
                XCTAssertEqual(text.report.remoteResourcesRefused, 0, message)
            }
        }
    }

    /// Images in `data:` URLs are held to the bounds of archive images: the pixels a drawing's
    /// images have together, and the work its preparation may do, which counts a URL's bytes as
    /// it counts a file's and knows a URL given twice as it knows a path.
    ///
    /// A book's drawing. The serializer's work budget is StaticSVG's half of this test
    /// (`SVGCoverageTests`).
    func testImagesInDataURLsKeepTheBoundsOfArchiveImages() throws {
        // Each image is inlined at 2,048 pixels on its long side at most, and a drawing's images
        // have 16 Mi pixels together at most: the fifth of five such is left out.
        let large = RichMediaImages.solid(width: 2048, height: 2048, red: 1, green: 0, blue: 0).base64EncodedString()
        let five = (0..<5).map { "<image x='\($0 * 10)' width='10' height='10' href='data:image/png;base64,\(large)'/>" }.joined()
        let (drawing, text) = try image("<p><svg \(Self.ns) width='50' height='10'>\(five)</svg></p>")
        let bitmap = try XCTUnwrap(drawing?.source.decode(maxPixelSize: 50))
        XCTAssertEqual((0..<5).map { Self.isRed(RichMediaImages.rgba(bitmap, x: $0 * 10 + 5, y: 5)) }, [true, true, true, true, false])
        XCTAssertEqual(text.report.unsupportedElements, ["svg:image": 1])
    }

    /// The renderer is given the drawing as it is prepared: an image in a `data:` URL reaches it
    /// as the PNG its bytes decode to, so one of a type the renderer does not read itself is
    /// drawn, and the prepared drawing passes the second screening (`SVGRenderer`). The first
    /// screens the drawing as the book has it, `data:` images and all. A drawing in a `data:` URL
    /// has no base in the archive, inside a drawing as anywhere: a reference in it names no file,
    /// though there is one at that path.
    ///
    /// A book's drawing. What the serializer prepares for the renderer is StaticSVG's half of
    /// this test (`SVGCoverageTests`).
    func testAnImageInADataURLReachesTheRendererAsAPreparedPNGAndNoArchiveFile() throws {
        let red = RichMediaImages.bitmap(width: 10, height: 10) { context, rect in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(rect)
        }
        let bmp = try XCTUnwrap(RichMediaImages.encode([red], as: .bmp))
        let raw = Self.drawing("href='data:image/bmp;base64,\(bmp.base64EncodedString())'")
        try assertDraws(try image("<p>\(raw)</p>").0, image: true, "BMP")
        // The first screening reads a `data:` image's own size: one with no width or height that
        // spans the drawing many times over is refused before anything is prepared.
        let wide = RichMediaImages.solid(width: 100, height: 100).base64EncodedString()
        let (refused, refusal) = try image("<p><svg \(Self.ns) width='10' height='10'><title>Wide</title><image href='data:image/png;base64,\(wide)'/><rect width='0' height='0'/></svg></p>")
        XCTAssertNil(refused)
        XCTAssertEqual(refusal.richMediaPlain, "Wide")
        XCTAssertEqual(refusal.report.unsupportedElements, ["svg": 1])

        let inner = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><image href='pic.png' width='5' height='10'/>"
            + "<image href='/OPS/pic.png' width='5' height='10'/><rect x='5' width='5' height='10' fill='lime'/></svg>"
        let nested = Self.drawing("href='data:image/svg+xml,\(try XCTUnwrap(inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)))'")
        let pic = RichMediaImages.solid(width: 10, height: 10)
        for (body, files) in [("<p>\(nested)</p>", ["pic.png": pic]), ("<p><img src='d.svg' alt='D'/></p>", ["pic.png": pic, "d.svg": Data(nested.utf8)])] {
            let (drawing, text) = try image(body, files: files)
            let bitmap = try XCTUnwrap(drawing?.source.decode(maxPixelSize: 30), body)
            XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 2, y: 5)[3], 0, "\(body): the archive picture is not drawn")
            let lime = RichMediaImages.rgba(bitmap, x: 8, y: 5)
            XCTAssertTrue(lime[1] > 200 && lime[0] < 60 && lime[3] == 255, "\(body): the rest of the inner drawing is, \(lime)")
            XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 20, y: 5), [0, 0, 255, 255], body)
            XCTAssertEqual(text.report.unsupportedElements, ["svg:image": 2], body)
            XCTAssertEqual(text.report.unreadableResources, 0, body)
            XCTAssertEqual(text.report.remoteResourcesRefused, 0, body)
        }
    }

    // MARK: References and sizes the serializer writes as the renderer reads them

    private static func isLime(_ pixel: [UInt8]) -> Bool { pixel[0] < 60 && pixel[1] > 200 && pixel[2] < 60 && pixel[3] == 255 }

    /// A fragment whose `#` a combining mark follows names an element of the drawing, as the
    /// renderer reads it: a `<use>` draws the shape it names, and neither it nor an `<image>` is
    /// taken for a file, left out or disclosed ([#641](https://github.com/vocaro/EPUBLib/issues/641)).
    /// In the document and in a drawing from the archive. What the serializer writes is
    /// StaticSVG's half of this test (`SVGCoverageTests`).
    func testAFragmentAfterACombiningMarkIsDrawnAndNotDisclosed() throws {
        let drawing = "<svg \(Self.ns) width='10' height='10'><defs><rect id='&#x301;x' width='5' height='5' fill='red'/></defs>"
            + "<use href='#&#x301;x'/><image href='#&#x301;x' width='5' height='5'/></svg>"
        for (body, files) in [("<p>\(drawing)</p>", [String: Data]()), ("<p><img src='d.svg' alt='D'/></p>", ["d.svg": Data(drawing.utf8)])] {
            let (shown, text) = try image(body, files: files)
            let bitmap = try XCTUnwrap(shown?.source.decode(maxPixelSize: 10), body)
            XCTAssertTrue(Self.isRed(RichMediaImages.rgba(bitmap, x: 2, y: 2)), "\(body): the use draws the rectangle")
            XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 7, y: 7)[3], 0, body)
            XCTAssertEqual(text.report.unsupportedElements, [:], body)
            XCTAssertEqual(text.report.unreadableResources, 0, "\(body): no file was read")
        }
    }

    /// An `<image>` whose picture is a drawing from the archive, and that gives no `width` or
    /// `height`, is laid out at that drawing's own size, from its `width` and `height` or else its
    /// `viewBox`, as a browser lays it out (SVG 2 §12.2), and not at the size of the 2,048-pixel
    /// raster it is inlined as, which had the drawing that holds it refused
    /// ([#704](https://github.com/vocaro/EPUBLib/issues/704)). In the document and in a drawing
    /// from the archive; StaticSVG's half of this test, `data:` drawings among them, is
    /// `SVGCoverageTests`.
    func testAnArchiveDrawingInAnImageIsLaidOutAtItsOwnSize() throws {
        let square = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10' fill='lime'/></svg>"
        let strip = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 5'><rect width='10' height='5' fill='lime'/></svg>"
        // A point inside the drawing as given its own size, and one outside it inside the raster's.
        for (inner, inside, outside, given) in [(square, (5, 5), (15, 15), "width='10' height='10'"), (strip, (5, 2), (5, 8), "width='10' height='5'")] {
            for size in ["", given] {
                // An empty rectangle keeps the outer drawing from being a single-image wrapper.
                let outer = "<svg \(Self.ns) width='20' height='20'><title>Nested</title><image href='inner.svg' \(size)/><rect width='0' height='0'/></svg>"
                for (body, files) in [("<p>\(outer)</p>", ["inner.svg": Data(inner.utf8)]),
                                      ("<p><img src='outer.svg' alt='Nested'/></p>", ["inner.svg": Data(inner.utf8), "outer.svg": Data(outer.utf8)])] {
                    let name = "\(body.prefix(8)) \(inner == square ? "10 by 10" : "viewBox") \(size.isEmpty ? "with no size" : size)"
                    let (shown, text) = try image(body, files: files)
                    let bitmap = try XCTUnwrap(shown?.source.decode(maxPixelSize: 20), "\(name): drawn, not refused")
                    let pixel = RichMediaImages.rgba(bitmap, x: inside.0, y: inside.1)
                    XCTAssertTrue(Self.isLime(pixel), "\(name): \(pixel)")
                    XCTAssertEqual(RichMediaImages.rgba(bitmap, x: outside.0, y: outside.1)[3], 0, name)
                    XCTAssertEqual(text.report.unsupportedElements, [:], name)
                }
            }
        }
    }

    /// An `<image>` whose picture is a bitmap from the archive over 2,048 pixels on its long side,
    /// and that gives no `width` or `height`, is laid out at the bitmap's own size, as a browser
    /// lays it out, and not at the size of the 2,048-pixel raster it is inlined as. The image span
    /// bound charges that size, as it charges one the element gives: a canvas narrower than an
    /// eighth of it shows the drawing's fallback ([#862](https://github.com/vocaro/EPUBLib/issues/862)).
    /// StaticSVG's half of this test, turned and `data:` bitmaps among them, is `SVGCoverageTests`.
    func testALargeArchiveBitmapInAnImageIsLaidOutAtItsOwnSize() throws {
        let files = ["wide.png": RichMediaImages.solid(width: 3000, height: 1000, red: 0, green: 1, blue: 0)]
        // A 3,000-unit square drawn at 30 pixels: a point inside the bitmap's own size, one inside
        // it outside the raster's 2,048 by 683, and one outside both.
        for size in ["", "width='3000' height='1000'"] {
            let name = size.isEmpty ? "with no size" : size
            let (shown, text) = try image("<p><svg \(Self.ns) width='3000' height='3000'><image href='wide.png' \(size)/><rect width='0' height='0'/></svg></p>", files: files)
            let bitmap = try XCTUnwrap(shown?.source.decode(maxPixelSize: 30), name)
            XCTAssertTrue(Self.isLime(RichMediaImages.rgba(bitmap, x: 5, y: 3)), name)
            XCTAssertTrue(Self.isLime(RichMediaImages.rgba(bitmap, x: 25, y: 8)), "\(name): drawn past the raster's size")
            XCTAssertEqual(RichMediaImages.rgba(bitmap, x: 25, y: 15)[3], 0, name)
            XCTAssertEqual(text.report.unsupportedElements, [:], name)
        }
        for (width, drawn) in [(375, true), (374, false)] {
            let (shown, text) = try image("<p><svg \(Self.ns) width='\(width)' height='125'><title>Wide</title><image href='wide.png'/><rect width='0' height='0'/></svg></p>", files: files)
            XCTAssertEqual(shown != nil, drawn, "a canvas \(width) wide")
            XCTAssertEqual(text.richMediaPlain.contains("Wide"), !drawn, "a canvas \(width) wide")
            XCTAssertEqual(text.report.unsupportedElements, drawn ? [:] : ["svg": 1], "a canvas \(width) wide")
        }
    }

    // MARK: Degenerate geometry — a viewBox far from the size of what it holds

    private var pageLine: ReaderAttachment.Line { ReaderAttachment.Line(width: 400, viewport: CGSize(width: 400, height: 600), font: PlatformFont.systemFont(ofSize: 16)) }

    /// Lays `image` out on a 400-point line of a 600-point page and decodes it as a draw would:
    /// the attachment fits its line and page, a table measures it within the widest line there
    /// is, and its picture goes in a rectangle no further off than a placement may put it.
    private func assertDrawsWithinItsLine(_ image: ReaderImageAttachment, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = image.layoutBounds(pageLine)
        XCTAssertTrue((1...400).contains(bounds.width) && (1...600).contains(bounds.height), "\(message): laid out at \(bounds.size)", file: file, line: line)
        let widths = image.contentWidths()
        XCTAssertTrue((0...100_000).contains(widths.min) && (0...100_000).contains(widths.max), "\(message): measured at \(widths)", file: file, line: line)
        let rect = image.imageRect(in: bounds.size)
        let reach = SVGContent.maximumPlacement * 600
        XCTAssertTrue([rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy { abs($0) <= reach }, "\(message): drawn at \(rect)", file: file, line: line)
        XCTAssertNotNil(image.bitmap(for: rect, scale: 2), "\(message): decodes", file: file, line: line)
    }

    /// An `<svg>` wrapping one `<image>` in a `viewBox` far smaller than it (here `0 0 1e-20
    /// 1e-20` around a 10 × 5 image) places the image 1e21 boxes wide. The long side of that
    /// rectangle in pixels is past `Int.max`, and converting it trapped the process. A placement
    /// that leaves less than a pixel of the image in the box is not kept: the image fills its box.
    func testTinyViewBoxWrapperDrawsAtABoundedSize() throws {
        let png = RichMediaImages.solid(width: 40, height: 20)
        let body = "<p><svg \(Self.ns) viewBox='0 0 1e-20 1e-20'><image width='10' height='5' href='w.png'/></svg></p>"
        let image = try XCTUnwrap(try self.image(body, files: ["w.png": png]).0)
        let bounds = image.layoutBounds(ReaderAttachment.Line(width: 400, viewport: CGSize(width: 400, height: 600), font: PlatformFont.systemFont(ofSize: 16)))
        let rect = image.imageRect(in: bounds.size)
        let bitmap = try XCTUnwrap(image.bitmap(for: rect, scale: 2), "the image is decoded, not skipped")
        XCTAssertEqual([bitmap.width, bitmap.height], [40, 20], "decoded at no more than the source's own pixels")
        XCTAssertNil(image.contentRect, "a placement 1e21 boxes wide is not kept")
        XCTAssertTrue(CGRect(origin: .zero, size: bounds.size).contains(rect), "the whole image is drawn inside its attachment: \(rect) in \(bounds.size)")
        XCTAssertEqual(rect.width / rect.height, 2, accuracy: 0.001, "at its own proportions")
        // As TextKit draws it, in a box with a size of its own: the picture is painted across it.
        let sized = try XCTUnwrap(try self.image(body.replacingOccurrences(of: "viewBox", with: "width='200' height='100' viewBox"), files: ["w.png": png]).0)
        let size = sized.layoutBounds(pageLine).size
        XCTAssertEqual(size, CGSize(width: 200, height: 100))
        let platform = try XCTUnwrap(sized.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0))
        let drawn = try XCTUnwrap(RichImageTests.draw(platform, size: size, scale: 2))
        for (x, y) in [(4, 4), (200, 100), (395, 195)] {
            let pixel = RichMediaImages.rgba(drawn, x: x, y: y)
            XCTAssertTrue(pixel[3] == 255 && pixel[2] > pixel[0], "the image's blue at (\(x), \(y)): \(pixel)")
        }
    }

    func testWrapperPlacementIsKeptOnlyWhileItShowsThePictureNearItsBox() throws {
        let vector = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1'><rect width='1' height='1' fill='red'/></svg>"
        let files = ["w.png": RichMediaImages.solid(width: 40, height: 20), "unit.svg": Data(vector.utf8)]
        /// The placement of a 10 × 5 image of 40 × 20 pixels, unless `image` gives another.
        func placement(viewBox: String, image attributes: String = "width='10' height='5' href='w.png'") throws -> CGRect? {
            let image = try XCTUnwrap(try self.image("<p><svg \(Self.ns) viewBox='\(viewBox)'><image \(attributes)/></svg></p>", files: files).0, viewBox)
            XCTAssertEqual(image.source.format, attributes.contains(".svg") ? .svg : .bitmap, "\(viewBox): still the fast path")
            if image.source.format == .bitmap { assertDrawsWithinItsLine(image, viewBox) }
            return image.contentRect
        }
        // A magnified detail of the image is an ordinary placement, down to one pixel of it across the box.
        XCTAssertEqual(try placement(viewBox: "4 2 1 0.5"), CGRect(x: -4, y: -4, width: 10, height: 10))
        XCTAssertEqual(try placement(viewBox: "0 0 0.25 0.25"), CGRect(x: 0, y: 0, width: 40, height: 20), "one pixel across and down")
        XCTAssertNil(try placement(viewBox: "0 0 0.24 0.25"), "less than a pixel across")
        XCTAssertNil(try placement(viewBox: "0 0 0.25 0.24"), "less than a pixel down")
        for size in ["1e-3", "1e-9", "1e-18", "1e-20", "1e-300", "1e-310"] {
            XCTAssertNil(try placement(viewBox: "0 0 \(size) \(size)"), "a box \(size) across")
            XCTAssertNil(try placement(viewBox: "0 0 10 \(size)"), "a box \(size) high")
            XCTAssertNil(try placement(viewBox: "0 0 \(size) 5"), "a box \(size) wide")
        }
        // An image out of its box's sight is one too, as far as the largest length an attribute gives.
        let limit = SVGContent.maximumPlacement
        XCTAssertEqual(try placement(viewBox: "-999990 0 10 10"), CGRect(x: limit - 1, y: 0, width: 1, height: 0.5))
        XCTAssertNil(try placement(viewBox: "-1000000 0 10 10"), "an edge past the limit")
        XCTAssertNil(try placement(viewBox: "1e9 0 10 10"), "an image 1e8 boxes to the left")
        XCTAssertNil(try placement(viewBox: "0 -1e9 10 10"), "an image 1e8 boxes down")
        XCTAssertNil(try placement(viewBox: "-1.7e308 0 0.25 0.25"), "an offset that overflows to infinity")
        XCTAssertNil(try placement(viewBox: "-1e308 -1e308 1e-300 1e-300"), "an offset and a size that do")
        // A vector image has the pixels it is rasterized at, whatever its own size in points.
        XCTAssertEqual(try placement(viewBox: "0.25 0.25 0.5 0.5", image: "width='1' height='1' href='unit.svg'"), CGRect(x: -0.5, y: -0.5, width: 2, height: 2))
        let raster = ReaderImageSource.maximumSVGDimension
        XCTAssertEqual(try placement(viewBox: "0 0 1 1", image: "width='\(raster)' height='\(raster)' href='unit.svg'")?.width, CGFloat(raster))
        XCTAssertNil(try placement(viewBox: "0 0 1 1", image: "width='\(raster + 1)' height='\(raster)' href='unit.svg'"))
    }

    func testDegenerateViewBoxProportionsKeepTheAttachmentOnItsLine() throws {
        let files = ["w.png": RichMediaImages.solid(width: 40, height: 20)]
        let wrapped = "<image width='10' height='5' href='w.png'/>", drawn = "<rect width='10' height='5'/><circle r='3'/>"
        // A ratio that under- or overflows, with the one length it is applied to, and the box alone.
        for attributes in ["width='100' viewBox='0 0 1e-300 1e300'", "height='50' viewBox='0 0 1e300 1e-300'",
                           "width='100' viewBox='0 0 1e300 1e-300'", "height='50' viewBox='0 0 1e-300 1e300'",
                           "width='100000in' viewBox='0 0 1e-300 100'", "viewBox='0 0 1e300 1e-300'", "viewBox='0 0 1e-300 1e300'",
                           "viewBox='0 0 1e300 1e300'", "viewBox='0 0 1e-300 1e-300'"] {
            for (content, format) in [(wrapped, ReaderImageSource.Format.bitmap), (drawn, .svg)] {
                // A drawing may be refused by the renderer instead; only one that is shown is measured.
                guard let image = try self.image("<p><svg \(Self.ns) \(attributes)>\(content)</svg></p>", files: files).0 else {
                    XCTAssertEqual(format, .svg, "\(attributes): a wrapped image is always shown")
                    continue
                }
                XCTAssertEqual(image.source.format, format, attributes)
                XCTAssertTrue(image.sizing.intrinsic.width.isFinite && image.sizing.intrinsic.height.isFinite, "\(attributes): intrinsic size \(image.sizing.intrinsic)")
                assertDrawsWithinItsLine(image, "\(attributes) \(format)")
            }
        }
        // The ratio overflowing leaves the image's own proportions to size the box, or the renderer's.
        let thin = try XCTUnwrap(try image("<p><svg \(Self.ns) width='100' viewBox='0 0 1e-300 1e300'>\(wrapped)</svg></p>", files: files).0)
        XCTAssertEqual(thin.sizing.intrinsic, CGSize(width: 40, height: 20))
        XCTAssertEqual(thin.layoutBounds(pageLine).size, CGSize(width: 100, height: 50))
        let drawing = try XCTUnwrap(try image("<p><svg \(Self.ns) width='100' viewBox='0 0 1e-300 1e300'>\(drawn)</svg></p>").0, "the drawing is shown too")
        XCTAssertEqual(drawing.source.format, .svg)
        XCTAssertEqual(drawing.sizing.intrinsic, drawing.source.pixelSize)
        // A box as large as a number holds, whose own styles refuse to scale it, is still held to its line.
        let huge = try XCTUnwrap(try image("<p><svg \(Self.ns) viewBox='0 0 1e300 1e300' style='max-width:0;max-height:0'>\(wrapped)</svg></p>", files: files).0)
        assertDrawsWithinItsLine(huge, "max-width and max-height of zero")
    }

    func testImageSizeAndDecodeAreBoundedForAnyGeometry() throws {
        let viewport = CGSize(width: 400, height: 600)
        let values: [CGFloat] = [.nan, .infinity, .greatestFiniteMagnitude, 1e300, 100, 1e-300, .leastNonzeroMagnitude, 0, -1]
        var checked = 0
        for width in values {
            for height in values {
                for (w, h) in [(ComputedStyle.Length.auto, ComputedStyle.Length.auto), (.points(100), .auto), (.auto, .points(50)), (.points(100), .points(50))] {
                    for maximum in [ComputedStyle.Length.auto, .points(0)] {
                        var sizing = ImageSizing(intrinsic: CGSize(width: width, height: height))
                        sizing.width = w; sizing.height = h; sizing.minWidth = .points(10); sizing.maxWidth = maximum; sizing.maxHeight = maximum
                        let size = sizing.size(lineWidth: 400, viewport: viewport, heightLimit: 600)
                        XCTAssertTrue((1...400).contains(size.width) && (1...600).contains(size.height), "intrinsic \(width) × \(height), \(w) × \(h), max \(maximum): \(size)")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 81 * 8)
        // Ordinary sizes are the same as before: scaled to the line with their proportions kept.
        XCTAssertEqual(ImageSizing(intrinsic: CGSize(width: 800, height: 600)).size(lineWidth: 400, viewport: viewport, heightLimit: 600), CGSize(width: 400, height: 300))
        XCTAssertEqual(ImageSizing(intrinsic: CGSize(width: 40, height: 20)).size(lineWidth: 400, viewport: viewport, heightLimit: 600), CGSize(width: 40, height: 20))
        // A rectangle no bitmap can cover asks for the pixels the source has, or the smallest decode.
        let image = try XCTUnwrap(try self.image("<p><img src='w.png' alt=''/></p>", files: ["w.png": RichMediaImages.solid(width: 300, height: 150)]).0)
        for side in [1e19, 1e300] as [CGFloat] {
            XCTAssertEqual(image.bitmap(for: CGRect(x: 0, y: 0, width: side, height: 1), scale: 2)?.width, 300, "\(side) points across")
        }
        for side in [CGFloat.greatestFiniteMagnitude, .infinity, .nan] {
            let bitmap = try XCTUnwrap(image.bitmap(for: CGRect(x: 0, y: 0, width: side, height: side), scale: 2), "\(side) points across")
            XCTAssertLessThanOrEqual(bitmap.width, 300, "\(side) points across")
        }
        XCTAssertNotNil(image.bitmap(for: CGRect(x: 0, y: 0, width: 10, height: 10), scale: .infinity), "an infinite scale")
    }
}
