import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// SVG illustrations: sizing, `preserveAspectRatio`, the single-image wrapper fast path,
/// accessible labels, disclosed omissions, the documented rendering limits, SVG content
/// documents as spine items, and robustness against adversarial drawings.
final class RichMediaSVGCoverageTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"

    private func build(_ body: String, files: [String: Data] = [:]) throws -> SectionText {
        try RichMediaBook(body: body, files: files).build()
    }

    private func image(_ body: String, files: [String: Data] = [:]) throws -> (ReaderImageAttachment?, SectionText) {
        let text = try build(body, files: files)
        return (text.richMediaImages.first, text)
    }

    private func source(_ svg: String) -> ReaderImageSource? {
        ReaderImageSource.svg(Data(svg.utf8), path: "", key: UUID().uuidString)
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

    func testPreserveAspectRatioMeetSliceAndNone() throws {
        // A 40x40 viewBox in a 160x80 box, split red (top) / blue (bottom).
        func render(_ par: String) throws -> [String] {
            let svg = "<svg \(Self.ns) width='160' height='80' viewBox='0 0 40 40' preserveAspectRatio='\(par)'><rect width='40' height='20' fill='red'/><rect y='20' width='40' height='20' fill='blue'/></svg>"
            let image = try XCTUnwrap(source(svg)?.decode(maxPixelSize: 160))
            return [(10, 10), (80, 10), (150, 10), (10, 70), (80, 70), (150, 70)].map {
                let p = RichMediaImages.rgba(image, x: $0.0, y: $0.1)
                return p[3] == 0 ? "-" : p[0] > 128 ? "R" : p[2] > 128 ? "B" : "?"
            }
        }
        // meet letterboxes: centred, transparent sides, red over blue.
        XCTAssertEqual(try render("xMidYMid meet"), ["-", "R", "-", "-", "B", "-"])
        XCTAssertEqual(try render("xMinYMid meet"), ["R", "-", "-", "B", "-", "-"], "xMin pins the drawing to the left")
        // slice fills the box, cropping; none stretches to fill.
        XCTAssertEqual(try render("xMidYMid slice"), ["R", "R", "R", "B", "B", "B"])
        XCTAssertEqual(try render("none"), ["R", "R", "R", "B", "B", "B"], "none stretches to fill the whole box")
        XCTAssertEqual(try render("xMidYMin slice"), ["R", "R", "R", "R", "R", "R"], "YMin keeps the top band, which is all red")
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

    // MARK: Drawing and labels

    func testInlineSVGDrawsPathsTextAndTransforms() throws {
        let svg = "<svg \(Self.ns) width='120' height='60' viewBox='0 0 120 60'><rect width='120' height='60' fill='white'/><circle cx='30' cy='30' r='20' fill='blue'/><g transform='translate(60 0)'><rect width='40' height='40' fill='red'/></g><text x='4' y='55' font-family='Arial' font-size='16'>Lbl</text></svg>"
        let image = try XCTUnwrap(source(svg)?.decode(maxPixelSize: 120))
        XCTAssertEqual(RichMediaImages.rgba(image, x: 30, y: 30), [0, 0, 255, 255], "the circle paints blue")
        XCTAssertEqual(RichMediaImages.rgba(image, x: 70, y: 10), [255, 0, 0, 255], "the translated rect paints red")
        var ink = 0
        for y in 44..<58 { for x in 2..<40 where RichMediaImages.rgba(image, x: x, y: y)[0] < 100 { ink += 1 } }
        XCTAssertGreaterThan(ink, 20, "the text glyphs are actually painted")
    }

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

    func testRenderingLimitBoundariesShowFallbackText() throws {
        let ns = "xmlns='http://www.w3.org/2000/svg'"
        // Depth: nesting that stays under the limit renders; past it falls back.
        func nested(_ groups: Int) -> String { "<svg \(ns) width='10' height='10'>" + String(repeating: "<g>", count: groups) + "<rect width='5' height='5'/>" + String(repeating: "</g>", count: groups) + "</svg>" }
        XCTAssertNotNil(source(nested(62)), "62 nested groups render")
        XCTAssertNil(source(nested(63)), "a drawing nested past the depth limit is refused")
        XCTAssertNil(try image("<p><img src='deep.svg' alt='Deep'/></p>", files: ["deep.svg": Data(nested(70).utf8)]).0, "an over-deep archive SVG shows its alt text")
        // Node count: 9,999 shapes render; 10,000 are refused.
        func rects(_ count: Int) -> String { "<svg \(ns) width='10' height='10'>" + String(repeating: "<rect width='1' height='1'/>", count: count) + "</svg>" }
        XCTAssertNotNil(source(rects(9_999)))
        XCTAssertNil(source(rects(10_000)))
        // Serialized bytes: a drawing just over 4 MiB is refused.
        func big(_ bytes: Int) -> String { "<svg \(ns) width='10' height='10'><path d='M0 0 \(String(repeating: "L9 9 ", count: bytes / 5))' stroke='black'/></svg>" }
        XCTAssertNotNil(source(big(4_000_000)))
        XCTAssertNil(source(big(4_300_000)))
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

    // MARK: Robustness

    func testAdversarialSVGStaysBoundedAndNeverTraps() throws {
        let ns = "xmlns='http://www.w3.org/2000/svg'"
        // Self-referential clip/mask and a use of an ancestor must not loop forever.
        XCTAssertNotNil(source("<svg \(ns) width='10' height='10'><clipPath id='c' clip-path='url(#c)'><rect width='5' height='5'/></clipPath><rect width='10' height='10' clip-path='url(#c)'/></svg>"))
        XCTAssertNil(source("<svg \(ns) width='10' height='10'><g id='g'><rect width='5' height='5'/><use href='#g'/></g></svg>"), "a use of an enclosing group is a cycle and is refused")
        // Degenerate geometry is accepted or rejected, never a trap.
        _ = source("<svg \(ns) width='10' height='10'><rect width='5' height='5' transform='scale(1e300)'/></svg>")
        _ = source("<svg \(ns) width='10' height='10' viewBox='0 0 NaN inf'><rect width='5' height='5'/></svg>")
        XCTAssertNil(source("<svg \(ns) width='-10' height='-10'><rect width='5' height='5'/></svg>"), "a negative size is refused")
        XCTAssertNil(source("<svg \(ns) width='1e-9' height='1e-9'><rect width='5' height='5'/></svg>"), "a sub-point size is refused")
        // A huge declared width is clamped to the raster ceiling, not honoured.
        if let huge = source("<svg \(ns) width='100000' height='1'><rect width='5' height='5'/></svg>") {
            XCTAssertLessThanOrEqual(max(huge.pixelSize.width, huge.pixelSize.height), CGFloat(ReaderImageSource.maximumSVGDimension))
        }
        // An embedded raster over 4 megapixels is refused before rendering.
        let bomb = RichMediaImages.solid(width: 2100, height: 2100).base64EncodedString()
        XCTAssertNil(source("<svg \(ns) width='10' height='10'><image href='data:image/png;base64,\(bomb)' width='10' height='10'/></svg>"))
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
