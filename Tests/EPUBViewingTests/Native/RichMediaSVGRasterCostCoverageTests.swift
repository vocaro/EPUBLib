import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// The hostile cases only reach the pre-render screen. Timing is not an assertion (#62),
/// and a regression must never hand the original multi-second inputs to the decoder.
final class RichMediaSVGRasterCostCoverageTests: XCTestCase {
    private func parse(_ text: String) throws -> ContentDocument {
        try ContentDocument.parse(Data(text.utf8), path: "raster.svg", asContent: false)
    }
    private func svg(_ content: String) -> String {
        "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='60'>\(content)</svg>"
    }
    private func marker(_ content: String, vertices: Int = 100, attributes: String = "") -> String {
        svg("<defs><marker id='m' \(attributes)>\(content)</marker></defs><path d='M0 0" +
            String(repeating: "h1", count: vertices - 2) + "' marker-mid='url(#m)'/>")
    }
    private func accepts(_ text: String) throws -> Bool {
        let document = try parse(text)
        return SVGContent.isWithinRenderingLimits(document.root)
    }

    func testNestedViewportsPayForEveryExpandedRasterLayer() throws {
        let nested = "<svg width='400' height='60'><rect width='40000' height='6000'/></svg>"
        let document = try parse(svg(String(repeating: nested, count: 100)))
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(document.root))
        XCTAssertEqual(SVGContent.isolatedLayers(document.root), 100)
        let used = try parse(svg("<defs><g id='a'>\(nested)</g></defs>" + String(repeating: "<use href='#a'/>", count: 100)))
        XCTAssertGreaterThanOrEqual(SVGContent.isolatedLayers(used.root), 100)
        let symbols = try parse(svg("<defs><symbol id='s' viewBox='0 0 400 60'><rect width='40000' height='6000'/></symbol></defs>" +
            String(repeating: "<use href='#s' width='400' height='60'/>", count: 100)))
        XCTAssertGreaterThanOrEqual(SVGContent.isolatedLayers(symbols.root), 100,
            "a used symbol also creates a clipped viewport layer")
        // This is a harmless neighbour with the same layer count. The hostile geometry above
        // is checked without decoding; this one verifies the production resolution choice.
        let safe = svg(String(repeating: nested.replacingOccurrences(of: "40000", with: "400").replacingOccurrences(of: "6000", with: "60"), count: 100))
        let source = try XCTUnwrap(ReaderImageSource.svg(Data(safe.utf8), path: "", key: UUID().uuidString))
        let image = try XCTUnwrap(source.decode(maxPixelSize: 1024))
        XCTAssertLessThanOrEqual(image.width * image.height * (4 + 125 * 100), 96 * 1024 * 1024)
    }

    func testOversizedClippedMarkersAreRefusedAtEveryInstanceCount() throws {
        let content = "<rect width='40000' height='6000'/>"
        for vertices in [100, 33_331] {
            XCTAssertFalse(try accepts(marker(content, vertices: vertices)))
            XCTAssertFalse(try accepts(marker("<g opacity='.5'>\(content)</g>", vertices: vertices)))
        }
        XCTAssertFalse(try accepts(marker(content, attributes: "overflow='visible'")),
                       "visible content can still acquire an isolated layer inside the marker")
        XCTAssertTrue(try accepts(marker("<rect width='1' height='1'/>")))
    }

    func testMarkerTransformsStrokeAndStylesCannotHideOversizedContent() throws {
        for content in [
            "<rect width='1' height='1' transform='scale(100000)'/>",
            "<g transform='scale(100)'><g transform='scale(100)'><rect width='1' height='1'/></g></g>",
            "<path d='M0 0h1' stroke='black' stroke-width='100000'/>",
            "<path d='M0 0h1' style='stroke:black;stroke-width:1e5px'/>",
            "<rect width='1' height='1' style='transform:translate(100000,0)'/>",
            "<path d='M0 0l1 1l-1 1' stroke='black' stroke-width='1' stroke-miterlimit='100000'/>",
            "<path d='M0 0h1e5'/>",
            "<polyline points='0,0 1e5,0'/>"
        ] { XCTAssertFalse(try accepts(marker(content)), content) }
        XCTAssertFalse(try accepts(marker("<rect class='large' width='1' height='1'/>")
            .replacingOccurrences(of: "<defs>", with: "<style>.large { transform:scale(100000); }</style><defs>")))
        XCTAssertFalse(try accepts(marker("<path class='large' d='M0 0h1'/>")
            .replacingOccurrences(of: "<defs>", with: "<style>.large { stroke-width:100000; }</style><defs>")))
        XCTAssertTrue(try accepts(marker("<g transform='translate(1,1)'><path d='M0 0L3 3' transform='scale(.5)'/></g>")))
    }

    func testOrdinaryClippedArrowheadsKeepTheirRasterResolution() throws {
        let drawing = marker("<path d='M0 0L10 5L0 10Z'/>", attributes: "viewBox='0 0 10 10' markerWidth='8' markerHeight='8'")
        let document = try parse(drawing)
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(document.root))
        XCTAssertEqual(SVGContent.isolatedLayers(document.root), 0)
        let source = try XCTUnwrap(ReaderImageSource.svg(Data(drawing.utf8), path: "", key: UUID().uuidString))
        let image = try XCTUnwrap(source.decode(maxPixelSize: 1024))
        XCTAssertEqual(image.width, 1024)
    }

    func testMarkerFarOriginViewBoxCannotHideWideGeometry() throws {
        XCTAssertFalse(try accepts(marker("<rect width='100000' height='1'/>",
            attributes: "viewBox='100000 0 1 1' markerWidth='1' markerHeight='1'")))
        XCTAssertTrue(try accepts(marker("<rect x='100000' width='1' height='1'/>", vertices: 3,
            attributes: "viewBox='100000 0 1 1' markerWidth='1' markerHeight='1'")))
        XCTAssertTrue(try accepts(marker("<path d='M100000 0h1v1h-1Z'/>", vertices: 3,
            attributes: "viewBox='100000 0 1 1' markerWidth='1' markerHeight='1'")),
            "the path envelope includes authored points, without an artificial zero origin")
    }

    func testRepeatedLargeMarkerAreaIsBoundedWithoutChangingResolution() throws {
        let content = "<rect width='40' height='40'/>"
        let attributes = "markerWidth='40' markerHeight='40'"
        XCTAssertTrue(try accepts(marker(content, vertices: 100, attributes: attributes)))
        XCTAssertFalse(try accepts(marker(content, vertices: 33_331, attributes: attributes)),
            "a legal local viewport still pays for every potentially clipped raster instance")
    }

    func testMarkerHostViewportOverridesAndFontShorthandCannotBypassBounds() throws {
        let arrow = "<marker id='m'><rect width='1' height='1'/></marker>"
        let line = "<path d='M0 0h1' marker-end='url(#m)'/>"
        for name in ["svg", "symbol"] {
            let drawing = svg("<defs>\(arrow)<\(name) id='s' width='1' height='1' viewBox='0 0 1 1'>\(line)</\(name)></defs><use href='#s' width='100000' height='100000'/>")
            XCTAssertFalse(try accepts(drawing), "use overrides a \(name) viewport")
        }
        XCTAssertFalse(try accepts(svg("<defs>\(arrow)</defs><svg width='1em' height='1em' viewBox='0 0 1 1' font-size='100000'>\(line)</svg>")))
        for style in ["font:100000px sans-serif", "font:1e5px sans-serif"] {
            XCTAssertFalse(try accepts(marker("<rect width='1em' height='1em' style='\(style)'/>")))
            XCTAssertFalse(try accepts(marker("<rect class='large' width='1em' height='1em'/>")
                .replacingOccurrences(of: "<defs>", with: "<style>.large { \(style); }</style><defs>")))
        }
    }

    func testRefusedMarkerShowsFallbackAndSVGDisclosure() throws {
        // Small enough to be harmless even if the screen regresses.
        let drawing = marker("<rect width='100' height='100'/>", vertices: 3)
            .replacingOccurrences(of: "<defs>", with: "<title>Network path</title><defs>")
        let text = try RichMediaBook(body: "<p>\(drawing)</p>").build()
        XCTAssertTrue(text.richMediaImages.isEmpty)
        XCTAssertEqual(text.richMediaPlain, "Network path")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
        let archive = try RichMediaBook(body: "<p><img src='diagram.svg' alt='Network'/></p>",
            files: ["diagram.svg": Data(drawing.utf8)]).build()
        XCTAssertTrue(archive.richMediaImages.isEmpty)
        XCTAssertEqual(archive.richMediaPlain, "Network")
        XCTAssertEqual(archive.report.unsupportedElements["svg"], 1)
    }
}
