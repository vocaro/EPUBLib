import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Relative lengths resolve each entry against every ancestor's font-size. Refused inputs are
/// screened only; capped renderer characterization lives in svg-font-size-probe.py (#443). The
/// screen's verdicts are tested in StaticSVG's `SVGFontSizeCostTests`; a drawing it refuses is
/// shown here as its fallback.
final class SVGFontSizeCostTests: XCTestCase {
    private let head = "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='200' height='100'>"
    private let path = "<path d='M0 0h50' stroke='black' stroke-dasharray='1em 1ex'/>"

    func testPaddedFontSizeUsesFallbackAndDisclosure() throws {
        let drawing = head + "<g font-size='\(String(repeating: " ", count: 100_000))12'>\(path)</g></svg>"
        let text = try RichMediaBook(body: "<p><img src='drawing.svg' alt='Chart'/></p>", files: ["drawing.svg": Data(drawing.utf8)]).build()
        XCTAssertTrue(text.richMediaImages.isEmpty)
        XCTAssertEqual(text.richMediaPlain, "Chart")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }
}
