import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

/// Verdicts and fallback are acceptance evidence; hostile inputs are never rendered.
final class RichMediaSVGRenderingCostCoverageTests: XCTestCase {
    private func svg(_ body: String) -> String {
        "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'>\(body)</svg>"
    }
    private func root(_ text: String) throws -> ContentNode {
        try ContentDocument.parse(Data(text.utf8), path: "svg", asContent: false).root
    }
    private func verdict(_ text: String) throws -> SVGRenderingCostScreen.Verdict {
        SVGRenderingCostScreen.verdict(try root(text))
    }
    private func fallback(_ drawing: String) throws {
        XCTAssertFalse(SVGContent.isWithinRenderingLimits(try root(drawing)))
        let text = try RichMediaBook(body: drawing).build()
        XCTAssertTrue(text.richMediaImages.isEmpty)
        XCTAssertTrue(text.string.string.contains("Costly diagram"))
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }
    func testDescendantBacktrackingIsRefusedWithoutRendering() throws {
        let body = "<title>Costly diagram</title><style>zz * * * * * * * * rect{fill:red}</style>"
            + String(repeating: "<g>", count: 60) + "<rect/>" + String(repeating: "</g>", count: 60)
        let drawing = svg(body)
        XCTAssertGreaterThan(try verdict(drawing).stylesheetWork, SVGRenderingCostScreen.maximumStylesheetWork)
        try fallback(drawing)
    }
    func testRulesTimesElementsIsRefusedWithoutRendering() throws {
        let rules = (0..<20_000).map { ".c\($0){fill:red}" }.joined()
        let drawing = svg("<title>Costly diagram</title><style>\(rules)</style>" + String(repeating: "<rect/>", count: 2_000))
        XCTAssertFalse(try verdict(drawing).withinLimits)
        try fallback(drawing)
    }
    func testAllDeclarationsAndGroupsAndUseCopiesAreCharged() throws {
        let properties = ["opacity", "fill-opacity", "stroke-width", "stroke-opacity", "color", "visibility", "display", "font-size"]
        let declarations = properties.map { "\($0):x" }.joined(separator: ";")
        for element in ["rect", "g"] {
            let content = String(repeating: "<\(element)/>", count: 128)
            let drawing = svg("<title>Costly diagram</title><style>\(element){\(declarations)}</style><defs><g id='a'>\(content)</g><g id='b'>"
                + String(repeating: "<use href='#a'/>", count: 64) + "</g></defs>" + String(repeating: "<use href='#b'/>", count: 30))
            let result = try verdict(drawing)
            XCTAssertFalse(result.withinLimits)
            XCTAssertGreaterThan(result.stylesheetCopies, 0)
            XCTAssertTrue(result.stylesheetWork > SVGRenderingCostScreen.maximumStylesheetWork
                || result.stylesheetCopies > SVGRenderingCostScreen.maximumStylesheetCopies)
            try fallback(drawing)
        }
    }
    func testSelectorListsChargeClonedDeclarationBlocks() throws {
        let selectors = (0..<5_000).map { ".c\($0)" }.joined(separator: ",")
        let drawing = svg("<style>\(selectors){fill:" + String(repeating: "x", count: 4_000) + "}</style><rect/>")
        XCTAssertGreaterThan(try verdict(drawing).stylesheetCopies, SVGRenderingCostScreen.maximumStylesheetCopies)
    }
    func testScreenRefusesSelectorDeclarationProductBeforeExpandingReferenceLists() throws {
        let selectors = Array(repeating: ".c", count: 20_000).joined(separator: ",")
        let declarations = String(repeating: "mask:url(#r);", count: 20_000)
        let drawing = svg("<style>\(selectors){\(declarations)}</style><rect class='c'/>")
        XCTAssertFalse(try verdict(drawing).withinLimits)
    }
    func testIgnoredDeclarationsStillCostMatchingWork() throws {
        let drawing = svg("<title>Costly diagram</title><style>rect{" + String(repeating: "a:x;", count: 100_000)
            + "}</style>" + String(repeating: "<rect/>", count: 9_000))
        XCTAssertGreaterThan(try verdict(drawing).stylesheetWork, SVGRenderingCostScreen.maximumStylesheetWork)
        try fallback(drawing)
    }
    func testLongCompoundSelectorCostsWorkEvenWithoutCombinators() throws {
        let drawing = svg("<title>Costly diagram</title><style>" + String(repeating: ".c", count: 10_000)
            + "{fill:red}</style>" + String(repeating: "<rect class='c'/>", count: 1_000))
        XCTAssertGreaterThan(try verdict(drawing).stylesheetWork, SVGRenderingCostScreen.maximumStylesheetWork)
        try fallback(drawing)
    }
    func testTotalTextAtAndBeyondTheBoundAndThroughUse() throws {
        func drawing(_ count: Int) -> String {
            let first = String(repeating: "a", count: 20_000)
            let last = String(repeating: "a", count: count - 40_000)
            return svg("<title>Costly diagram</title><text>\(first)</text><text>\(first)</text><text>\(last)</text>")
        }
        let bound = SVGRenderingCostScreen.maximumTextCharacters
        XCTAssertEqual(try verdict(drawing(bound)).textCharacters, bound)
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(try root(drawing(bound))))
        try fallback(drawing(bound + 1))
        let reused = svg("<title>Costly diagram</title><defs><text id='t'>" + String(repeating: "a", count: 10_000)
            + "</text></defs>" + String(repeating: "<use href='#t'/>", count: 5))
        try fallback(reused)
        // Rust's text shaping reads Unicode scalar values (str::chars), not grapheme clusters
        // or UTF-8 bytes. A combining sequence has two scalars; a non-BMP character has one.
        let unicode = svg("<text>" + String(repeating: "a\u{301}😀", count: 10_000) + "</text>")
        XCTAssertEqual(try verdict(unicode).textCharacters, 30_000)
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
            XCTAssertTrue(SVGContent.isWithinRenderingLimits(try root(resource(name, units: units, references: 100, source: property))))
            try fallback(resource(name, units: units, references: 600, source: property))
        }
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(try root(resource("mask", units: "maskUnits='userSpaceOnUse'", references: 100))))
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(try root(resource("clipPath", references: 100, source: "clip-path"))))
    }
    func testResourceExpansionHasAnExactByteBoundary() throws {
        let base = try verdict(resource("mask", references: 0, shapes: 10)).expandedBytes
        let one = try verdict(resource("mask", references: 1, shapes: 10)).expandedBytes
        let increment = one - base
        let count = (SVGContent.maximumExpandedBytes - base) / increment
        let passing = resource("mask", references: count, shapes: 10)
        let refused = resource("mask", references: count + 1, shapes: 10)
        XCTAssertTrue(try verdict(passing).withinLimits)
        XCTAssertEqual(try verdict(passing).expandedBytes, base + count * increment)
        XCTAssertFalse(try verdict(refused).withinLimits)
        // These boundary documents exceed the separate 10k source-node limit; the budget's verdict
        // is tested directly, while the small multiplied input above checks pipeline fallback.
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
        let drawing = svg("<title>Costly diagram</title><defs><linearGradient id='g'>\(stops)</linearGradient><mask id='m'>\(shapes)</mask></defs>"
            + String(repeating: "<rect width='2' height='2' mask='url(#m)'/>", count: 100))
        XCTAssertTrue(try verdict(drawing).withinLimits, "source expansion alone cannot bound gradient copies")
        try fallback(drawing)
    }
    func testSelectorAttributeLookupAndValueScanningAreBoundedBeforeMatches() throws {
        let classes = (0..<5_000).map { ".c\($0){fill:red}" }.joined()
        let longClass = svg("<title>Costly diagram</title><style>\(classes)</style><rect class='" + String(repeating: "x", count: 1_000_000) + "'/>")
        XCTAssertGreaterThan(try verdict(longClass).stylesheetWork, SVGRenderingCostScreen.maximumStylesheetWork)
        try fallback(longClass)
        let attrs = (0..<50_000).map { "a\($0)='x'" }.joined(separator: " ")
        let missingAttribute = svg("<title>Costly diagram</title><style>" + String(repeating: "[z]{fill:red}", count: 5_000) + "</style><rect \(attrs)/>")
        XCTAssertGreaterThan(try verdict(missingAttribute).stylesheetWork, SVGRenderingCostScreen.maximumStylesheetWork)
        try fallback(missingAttribute)
        let tinyRules = svg("<style>" + String(repeating: "a{}", count: 100_000) + "</style><rect/>")
        XCTAssertFalse(try verdict(tinyRules).withinLimits, "materialization stops after the 10,001st selector")
    }
    func testOrdinaryDiagramStylesRemainWithinAllLimits() throws {
        // Fifty rules of five declarations over a few thousand elements, with class, id,
        // descendant, child and adjacent-sibling selectors used by diagram exporters.
        let rules = (0..<50).map { ".diagram .c\($0){fill:red;stroke:black;stroke-width:1;opacity:1;font-size:12}" }.joined()
        let shapes = (0..<3_000).map { "<rect class='c\($0 % 50)' width='1' height='1'/>" }.joined()
        let drawing = svg("<style>\(rules)g>rect+rect{fill:blue}</style><g class='diagram'>\(shapes)</g>")
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(try root(drawing)))
        XCTAssertNotNil(ReaderImageSource.svg(Data(drawing.utf8), path: "", key: UUID().uuidString))
        XCTAssertTrue(try verdict(svg("<style>@font-face{font-family:Diagram;src:url(data:font/ttf;base64,AAAA)}rect{fill:red}</style><rect/>")).withinLimits)
    }
}
