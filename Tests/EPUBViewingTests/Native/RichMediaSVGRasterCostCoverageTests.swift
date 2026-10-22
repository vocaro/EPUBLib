import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// The hostile cases only reach the pre-render screen. Timing is not an assertion (#62),
/// and a regression must never hand the original multi-second inputs to the decoder.
///
/// The screen and the renderer are StaticSVG's, and so are their tests of these drawings
/// (`SVGRasterCostCoverageTests`). Here is the section a reader shows a refused one in.
final class RichMediaSVGRasterCostCoverageTests: XCTestCase {
    private func svg(_ content: String) -> String {
        "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='60'>\(content)</svg>"
    }
    private func marker(_ content: String, vertices: Int = 100, attributes: String = "") -> String {
        svg("<defs><marker id='m' \(attributes)>\(content)</marker></defs><path d='M0 0" +
            String(repeating: "h1", count: vertices - 2) + "' marker-mid='url(#m)'/>")
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
