import CoreGraphics
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing

final class SVGGeometryCostScreenTests: XCTestCase {
    private func root(_ body: String, viewport: String = "width='100' height='100'") throws -> ContentNode {
        try ContentDocument.parse(Data("<svg xmlns='http://www.w3.org/2000/svg' \(viewport)>\(body)</svg>".utf8), path: "svg", asContent: false).root
    }

    // Hostile inputs go only to preflight. A regression cannot start the expensive renderer.
    func testHugeStrokedArcAndFarTextPathAreRefusedBeforeRenderer() throws {
        XCTAssertFalse(SVGContent.isWithinRenderingLimits(try root("<path d='M-2e13 0 A9.4e16 3.9 0 1 0 0 8.9e16 Q0 -8.9e16 0 1.5e16Z' stroke='black'/>")))
        XCTAssertFalse(SVGContent.isWithinRenderingLimits(try root("<defs><path id='p' d='M1e20 1e20 L2e20 1e20'/></defs><text><textPath href='#p'>Label</textPath></text>")))
        XCTAssertFalse(SVGContent.isWithinRenderingLimits(try root("<defs><path id='p' d='M1 1 L2 1' transform='scale(1e20)'/></defs><text><textPath href='#p'>Label</textPath></text>")))
        XCTAssertFalse(SVGContent.isWithinRenderingLimits(try root("<defs><rect id='p' width='1e20' height='1'/></defs><text><textPath href='#p'>Label</textPath></text>")))
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(try root("<defs><path id='p' d='M1 1 L80 1' transform='translate(1 1)'/></defs><text><textPath href='#p'>Label</textPath></text>")))
        XCTAssertNil(SVGGeometryCostScreen.pathBounds("M0 0 A1 .000000000001 0 0 1 100 100"), "Endpoint correction can enlarge a small authored radius")
        XCTAssertNil(SVGGeometryCostScreen.pathBounds("M0 0" + String(repeating: "a1000 1000 0 0 1 1 1", count: 1000)), "Arc conversion work is charged for the whole path")
    }

    func testRelativeCoordinatesAreAccumulatedAndOrdinaryArcsRemainSupported() {
        XCTAssertNil(SVGGeometryCostScreen.pathBounds("M9999999 0 h2"))
        XCTAssertNotNil(SVGGeometryCostScreen.pathBounds("M10 10a5 5 0 0110 0z"), "Compact adjacent arc flags are valid")
        XCTAssertNotNil(SVGGeometryCostScreen.pathBounds("M0 0 C10 20 30 40 50 60 s10 20 30 40 Q20 20 10 10 t1 1z"))
    }

    func testImageSpanBoundIncludesPercentUnitsTransformsAndUse() throws {
        for body in ["<image width='5390%' height='100' href='image.png'/>",
                     "<g transform='scale(54)'><image width='100' height='100' href='image.png'/></g>",
                     "<image style='transform:scale(54)' width='100' height='100' href='image.png'/>",
                     "<image transform='scale(.001)' style='transform:scale(1000)' width='100' height='100' href='image.png'/>",
                     "<defs><image id='p' width='100' height='100' href='image.png'/></defs><use href='#p' transform='scale(54)'/>",
                     "<defs><symbol id='p' viewBox='0 0 .01 .01'><image width='1' height='1' href='image.png'/></symbol></defs><use href='#p' width='100' height='100'/>",
                     "<defs><svg id='p' width='100' height='100'><image width='100' height='100' href='image.png'/></svg></defs><use href='#p' width='10000' height='10000'/>",
                     "<defs><symbol id='p' width='100' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMidYMid slice'><image width='1' height='100' href='image.png'/></symbol></defs><use href='#p' width='10000' height='100'/>",
                     "<image style='font:100000px sans-serif' width='1em' height='1em' href='image.png'/>",
                     "<style>g{font:100000px sans-serif}</style><g><image width='1em' height='1em' href='image.png'/></g>",
                     "<svg width='10000' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMidYMid slice'><image width='1' height='100' href='image.png'/></svg>",
                     "<svg width='10000' height='10000' viewBox='0 0 100 100'><image width='100' height='100' href='image.png'/></svg>"] {
            XCTAssertFalse(SVGContent.isWithinRenderingLimits(try root(body)), body)
        }
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(try root("<image width='800%' height='100' href='image.png'/>")))
        XCTAssertFalse(SVGContent.isWithinRenderingLimits(try root("<image width='800.1%' height='100' href='image.png'/>")))
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(try root("<g transform='translate(20 10) rotate(10)'><image width='20' height='20' href='image.png'/></g>")))
    }

    func testOrdinaryArcDrawingRendersAfterScreening() throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><path d='M10 50 A40 30 0 0 1 90 50' fill='none' stroke='black'/></svg>"
        let source = try XCTUnwrap(ReaderImageSource.svg(Data(svg.utf8), path: "", key: "ordinary-arc"))
        XCTAssertNotNil(source.decode(maxPixelSize: 100))
    }
}
