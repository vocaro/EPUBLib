import EPUBCore
import Foundation
import StaticSVG
import XCTest
@testable import EPUBViewing

/// Fallback is acceptance evidence; hostile inputs are never rendered. Each drawing StaticSVG's
/// screens refuse is shown as its fallback text and disclosed. The screens' verdicts on the same
/// drawings are tested in StaticSVG's `SVGRenderingCostCoverageTests`.
final class RichMediaSVGRenderingCostCoverageTests: XCTestCase {
    private func svg(_ body: String) -> String {
        "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'>\(body)</svg>"
    }
    private func root(_ text: String) throws -> ContentNode {
        try ContentDocument.parse(Data(text.utf8), path: "svg", asContent: false).root
    }
    private func fallback(_ drawing: String) throws {
        XCTAssertFalse(try XCTUnwrap(SVGContent.document(try root(drawing))).isWithinRenderingLimits())
        let text = try RichMediaBook(body: drawing).build()
        XCTAssertTrue(text.richMediaImages.isEmpty)
        XCTAssertTrue(text.string.string.contains("Costly diagram"))
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }
    func testDescendantBacktrackingIsRefusedWithoutRendering() throws {
        let body = "<title>Costly diagram</title><style>zz * * * * * * * * rect{fill:red}</style>"
            + String(repeating: "<g>", count: 60) + "<rect/>" + String(repeating: "</g>", count: 60)
        try fallback(svg(body))
    }
    func testRulesTimesElementsIsRefusedWithoutRendering() throws {
        let rules = (0..<20_000).map { ".c\($0){fill:red}" }.joined()
        try fallback(svg("<title>Costly diagram</title><style>\(rules)</style>" + String(repeating: "<rect/>", count: 2_000)))
    }
    func testAllDeclarationsAndGroupsAndUseCopiesAreCharged() throws {
        let properties = ["opacity", "fill-opacity", "stroke-width", "stroke-opacity", "color", "visibility", "display", "font-size"]
        let declarations = properties.map { "\($0):x" }.joined(separator: ";")
        for element in ["rect", "g"] {
            let content = String(repeating: "<\(element)/>", count: 128)
            try fallback(svg("<title>Costly diagram</title><style>\(element){\(declarations)}</style><defs><g id='a'>\(content)</g><g id='b'>"
                + String(repeating: "<use href='#a'/>", count: 64) + "</g></defs>" + String(repeating: "<use href='#b'/>", count: 30)))
        }
    }
    func testIgnoredDeclarationsStillCostMatchingWork() throws {
        try fallback(svg("<title>Costly diagram</title><style>rect{" + String(repeating: "a:x;", count: 100_000)
            + "}</style>" + String(repeating: "<rect/>", count: 9_000)))
    }
    func testLongCompoundSelectorCostsWorkEvenWithoutCombinators() throws {
        try fallback(svg("<title>Costly diagram</title><style>" + String(repeating: ".c", count: 10_000)
            + "{fill:red}</style>" + String(repeating: "<rect class='c'/>", count: 1_000)))
    }
    func testTotalTextAtAndBeyondTheBoundAndThroughUse() throws {
        func drawing(_ count: Int) -> String {
            let first = String(repeating: "a", count: 20_000)
            let last = String(repeating: "a", count: count - 40_000)
            return svg("<title>Costly diagram</title><text>\(first)</text><text>\(first)</text><text>\(last)</text>")
        }
        // StaticSVG's bound on the characters of all text (SVGRenderingCostScreen.maximumTextCharacters).
        let bound = 50_000
        try fallback(drawing(bound + 1))
        let reused = svg("<title>Costly diagram</title><defs><text id='t'>" + String(repeating: "a", count: 10_000)
            + "</text></defs>" + String(repeating: "<use href='#t'/>", count: 5))
        try fallback(reused)
        let manyRuns = svg("<title>Costly diagram</title>" + String(repeating: "<text>" + String(repeating: "a", count: 5_000) + "</text>", count: 800))
        try fallback(manyRuns)
    }
    private func resource(_ name: String, units: String = "", references: Int, shapes: Int = 500, source: String = "mask") -> String {
        let body = String(repeating: "<rect width='1' height='1'/>", count: shapes)
        return svg("<title>Costly diagram</title><defs><\(name) id='r' \(units)>\(body)</\(name)></defs>"
            + String(repeating: "<rect width='2' height='2' \(source)='url(#r)'/>", count: references))
    }
    func testAllMaskAndClipUnitsPayPerReferenceAndOrdinaryReusePasses() throws {
        for (name, units, property) in [("mask", "", "mask"), ("clipPath", "clipPathUnits='objectBoundingBox'", "clip-path")] {
            try fallback(resource(name, units: units, references: 600, source: property))
        }
    }
    func testStylesheetAndInlineResourcesAndNestedMaskDoublingAreCharged() throws {
        let definition = "<mask id='r'>" + String(repeating: "<rect width='1' height='1'/>", count: 500) + "</mask>"
        for attr in ["style='mask:url(#r)'", "class='masked'"] {
            let sheet = attr.contains("class") ? "<style>.masked{mask:url(#r)}</style>" : ""
            try fallback(svg("<title>Costly diagram</title>\(sheet)<defs>\(definition)</defs>"
                + String(repeating: "<rect width='2' height='2' \(attr)/>", count: 600)))
        }
        var masks = "<mask id='m0'><rect width='1' height='1'/></mask>"
        for level in 1...18 {
            masks += "<mask id='m\(level)'><rect width='2' height='2' mask='url(#m\(level - 1))'/><rect width='2' height='2' mask='url(#m\(level - 1))'/></mask>"
        }
        try fallback(svg("<title>Costly diagram</title><defs>\(masks)</defs><rect width='2' height='2' mask='url(#m18)'/>"))
    }
    func testInvalidUserSpaceResourcesAreNotAssumedToBeCached() throws {
        for (tag, units, property) in [("mask", "maskUnits='userSpaceOnUse'", "mask"), ("clipPath", "", "clip-path")] {
            // A positive Double can underflow to zero in the renderer's f32 geometry. Even a
            // resource with a seemingly nonempty primitive is then retried rather than cached.
            let helper = "<rect width='1e-300' height='1'/>"
            var definitions = "<\(tag) id='r0' \(units)>\(helper)</\(tag)>"
            for level in 1...20 {
                definitions += "<\(tag) id='r\(level)' \(units)>\(helper)"
                    + String(repeating: "<rect width='2' height='2' \(property)='url(#r\(level - 1))'/>", count: 2) + "</\(tag)>"
            }
            try fallback(svg("<title>Costly diagram</title><defs>\(definitions)</defs><rect width='2' height='2' \(property)='url(#r20)'/>"))
        }
    }
    func testMaskReferencesMultiplyGradientAndDashCopiesToo() throws {
        let stops = String(repeating: "<stop stop-color='red'/>", count: 2_000)
        let shapes = String(repeating: "<rect width='1' height='1' fill='url(#g)'/>", count: 500)
        try fallback(svg("<title>Costly diagram</title><defs><linearGradient id='g'>\(stops)</linearGradient><mask id='m'>\(shapes)</mask></defs>"
            + String(repeating: "<rect width='2' height='2' mask='url(#m)'/>", count: 100)))
    }
    func testMarkerInheritedResourcesPayPerInstanceIncludingGradientCopies() throws {
        let content = String(repeating: "<rect width='1' height='1'/>", count: 5_000)
        let marker = "<marker id='m' mask='url(#r)'><rect width='1' height='1' mask='inherit'/></marker>"
        try fallback(svg("<title>Costly diagram</title><defs><mask id='r'>\(content)</mask>\(marker)</defs>"
            + String(repeating: "<rect width='2' height='2' marker-start='url(#m)'/>", count: 500)))
        // XML stays small here; the repeated resource's resolved gradient copies are the cost.
        let stops = String(repeating: "<stop stop-color='red'/>", count: 2_000)
        try fallback(svg("<title>Costly diagram</title><defs><linearGradient id='g'>\(stops)</linearGradient>"
            + "<mask id='r'><rect width='1' height='1' fill='url(#g)'/></mask>\(marker)</defs>"
            + String(repeating: "<rect width='2' height='2' marker-start='url(#m)'/>", count: 3_000)))
    }
    func testSelectorAttributeLookupAndValueScanningAreBoundedBeforeMatches() throws {
        let classes = (0..<5_000).map { ".c\($0){fill:red}" }.joined()
        try fallback(svg("<title>Costly diagram</title><style>\(classes)</style><rect class='" + String(repeating: "x", count: 100_000) + "'/>"))
        // The XML preflight permits 1,024 attributes per tag. Increase queries instead of exceeding that
        // bound, so this still reaches the SVG lookup-work screen before selector matching.
        let attrs = (0..<XMLSafety.attributesPerElement).map { "a\($0)='x'" }.joined(separator: " ")
        try fallback(svg("<title>Costly diagram</title><style>" + String(repeating: "[z]{fill:red}", count: 10_000) + "</style><rect \(attrs)/>"))
    }
}
