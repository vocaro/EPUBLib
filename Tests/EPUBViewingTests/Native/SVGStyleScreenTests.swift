import Foundation
import XCTest
@testable import EPUBViewing

final class SVGStyleScreenTests: XCTestCase {
    private func root(_ body: String) throws -> ContentNode {
        let drawing = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'>\(body)</svg>"
        return try ContentDocument.parse(Data(drawing.utf8), path: "svg", asContent: false).root
    }

    func testNestedStylesAreRefusedWithConstantWorkBeforeReadingTheirCSS() throws {
        for depth in [2, 6, 60] {
            for repeats in [1, 30_000] {
                let sheet = String(repeating: "rect{fill:red}", count: repeats)
                let svg = try root(String(repeating: "<style>", count: depth) + sheet
                    + String(repeating: "</style>", count: depth) + "<rect/>")
                let verdict = SVGStyleScreen.verdict(svg)
                XCTAssertFalse(verdict.withinLimits)
                XCTAssertEqual(verdict.visitedNodes, 3, "root and two styles; their text is never visited")
                XCTAssertFalse(SVGContent.isWithinRenderingLimits(svg))
                XCTAssertTrue(SVGContent.fontFamilies(svg).isEmpty)
                XCTAssertTrue(SVGContent.unsupportedConstructs(svg).isEmpty)
            }
        }
    }

    func testNestingThroughOtherElementsIsRefusedAndSiblingStylesPass() throws {
        let nested = try root("<style>rect{fill:red}<g><style>rect{fill:blue}</style></g></style><rect/>")
        XCTAssertFalse(SVGStyleScreen.verdict(nested).withinLimits)
        XCTAssertFalse(SVGContent.isWithinRenderingLimits(nested))
        let siblings = try root("<style>rect{font-family:Diagram;fill:red}</style><g><style>rect{stroke:blue}</style></g><rect/>")
        XCTAssertTrue(SVGStyleScreen.verdict(siblings).withinLimits)
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(siblings))
        XCTAssertEqual(SVGContent.fontFamilies(siblings), ["diagram"])
    }

    func testOneStyleStillConcatenatesOrdinaryDescendantText() throws {
        let svg = try root("<style>rect{font-family:<g>Diagram</g>;fill:red}</style><rect/>")
        XCTAssertTrue(SVGStyleScreen.verdict(svg).withinLimits)
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(svg))
        XCTAssertEqual(SVGContent.fontFamilies(svg), ["diagram"])
    }

    func testStyleScreenHonorsSourceStructureLimits() throws {
        let maximumNodes = SVGContent.maximumNodes
        let passing = SVGStyleScreen.verdict(try root(String(repeating: "<rect/>", count: maximumNodes - 1)))
        XCTAssertTrue(passing.withinLimits)
        XCTAssertEqual(passing.visitedNodes, maximumNodes)
        let refused = SVGStyleScreen.verdict(try root(String(repeating: "<rect/>", count: maximumNodes)))
        XCTAssertFalse(refused.withinLimits)
        XCTAssertEqual(refused.visitedNodes, maximumNodes)
        for depth in [SVGContent.maximumDepth, SVGContent.maximumDepth + 1] {
            let svg = try root(String(repeating: "<g>", count: depth) + String(repeating: "</g>", count: depth))
            let result = SVGStyleScreen.verdict(svg)
            XCTAssertEqual(result.withinLimits, depth == SVGContent.maximumDepth)
            XCTAssertEqual(result.visitedNodes, SVGContent.maximumDepth + 1)
        }
    }

    func testNestedStylesUseFallbackWithoutRendering() throws {
        let drawing = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'>"
            + "<title>Nested stylesheet diagram</title><style><style>rect{fill:red}</style></style><rect/></svg>"
        let content = try RichMediaBook(body: drawing).build()
        XCTAssertTrue(content.richMediaImages.isEmpty)
        XCTAssertTrue(content.string.string.contains("Nested stylesheet diagram"))
        XCTAssertEqual(content.report.unsupportedElements["svg"], 1)
    }
}
