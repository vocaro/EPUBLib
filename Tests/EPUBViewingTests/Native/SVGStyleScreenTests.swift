import Foundation
import XCTest
@testable import EPUBViewing

/// A drawing with nested styles is shown as its fallback. The style screen itself is tested in
/// StaticSVG's `SVGStyleScreenTests`.
final class SVGStyleScreenTests: XCTestCase {
    func testNestedStylesUseFallbackWithoutRendering() throws {
        let drawing = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'>"
            + "<title>Nested stylesheet diagram</title><style><style>rect{fill:red}</style></style><rect/></svg>"
        let content = try RichMediaBook(body: drawing).build()
        XCTAssertTrue(content.richMediaImages.isEmpty)
        XCTAssertTrue(content.string.string.contains("Nested stylesheet diagram"))
        XCTAssertEqual(content.report.unsupportedElements["svg"], 1)
    }
}
