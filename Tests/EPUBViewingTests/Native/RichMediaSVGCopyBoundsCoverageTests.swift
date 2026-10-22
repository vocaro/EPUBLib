import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import StaticSVG
import XCTest
@testable import EPUBViewing

/// A drawing past the bound on what the renderer copies or re-reads once per painted shape
/// ([#252](https://github.com/vocaro/EPUBLib/issues/252)) shows its fallback text with the same
/// `svg` disclosure as the other limits, whether it is an `<img>` or inline. The bound is
/// StaticSVG's, and its `SVGCopyBoundsCoverageTests` assert the counts, the steps and the verdict
/// for each rule, these drawings among them; here each bomb is screened through
/// `SVGContent.document` as the section builder screens it, then built into a book. An input that
/// is refused is never rendered.
final class RichMediaSVGCopyBoundsCoverageTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"

    private func svg(_ defs: String, _ body: String, root: String = "width='200' height='50'", pre: String = "") -> String {
        "<svg \(Self.ns) \(root)>\(pre)<defs>\(defs)</defs>\(body)</svg>"
    }

    /// A gradient of `stops` stops: the renderer copies that many for each shape it paints.
    private func gradient(_ id: String = "g", stops: Int, _ attributes: String = "") -> String {
        "<linearGradient id='\(id)' \(attributes)>" + String(repeating: "<stop stop-color='red'/>", count: stops) + "</linearGradient>"
    }

    private func parsed(_ svg: String) -> ContentNode? {
        try? ContentDocument.parse(
            Data(svg.utf8), path: "svg",
            limits: .init(bytes: SVGLimits.renderer.bytes, depth: SVGLimits.renderer.depth, nodes: SVGLimits.renderer.nodes),
            asContent: false).root
    }

    /// The whole pre-render check, on the tree StaticSVG is given.
    private func isWithinLimits(_ svg: String) -> Bool {
        parsed(svg).flatMap { SVGContent.document($0) }?.isWithinRenderingLimits() ?? false
    }

    private func image(_ body: String, files: [String: Data] = [:]) throws -> (ReaderImageAttachment?, SectionText) {
        let text = try RichMediaBook(body: body, files: files).build()
        return (text.richMediaImages.first, text)
    }

    // MARK: Rule 1: gradient stops per painted shape

    func testStopBombShowsFallbackAndDiscloses() throws {
        // 5,000 stops copied for each of 2,000 rects: ten million copies, hundreds of megabytes.
        let bomb = svg(gradient(stops: 5_000), "<desc>Heat map</desc>" + String(repeating: "<rect width='1' height='1' fill='url(#g)'/>", count: 2_000))
        XCTAssertFalse(isWithinLimits(bomb))
        let (attachment, text) = try image("<p><img src='bomb.svg' alt='Chart'/></p>", files: ["bomb.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment, "a stop bomb is not rendered")
        XCTAssertEqual(text.richMediaPlain, "Chart")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1, "and it is disclosed like the other limits")

        let (inline, inlineText) = try image("<p>\(bomb)</p>")
        XCTAssertNil(inline)
        XCTAssertEqual(inlineText.richMediaPlain, "Heat map", "inline, its description stands in")
        XCTAssertEqual(inlineText.report.unsupportedElements["svg"], 1)
    }

    // MARK: Rule 2: dash-array entries per stroked shape

    func testDashBombShowsFallbackAndDiscloses() throws {
        // A 50,000-entry dash array (100,000 bytes) inherited by 3,000 paths.
        let dash = String(repeating: "1 ", count: 50_000)
        let bomb = "<svg \(Self.ns) width='200' height='50'><title>Grid</title><g stroke='black' stroke-dasharray='\(dash)'>" + String(repeating: "<path d='M0 0h1'/>", count: 3_000) + "</g></svg>"
        XCTAssertFalse(isWithinLimits(bomb))
        let (attachment, text) = try image("<p>\(bomb)</p>")
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Grid")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: Rule 3: a long inherited fill or stroke re-parsed per shape

    func testPaddedInheritedPaintBombShowsFallbackAndDiscloses() throws {
        // A one-megabyte fill on a group, inherited by 6,000 shapes drawn through `<use>`.
        let pad = String(repeating: " ", count: 1_000_000)
        let bomb = "<svg \(Self.ns) width='200' height='50'><desc>Diagram</desc><defs><g id='u'>" + String(repeating: "<rect width='1' height='1'/>", count: 10) + "</g></defs><g fill='\(pad)red'>" + String(repeating: "<use xlink:href='#u'/>", count: 600) + "</g></svg>"
        XCTAssertFalse(isWithinLimits(bomb), "6,000 shapes re-parsing a megabyte fill")
        let (attachment, text) = try image("<p>\(bomb)</p>")
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Diagram")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: Rule 5: text copies per span

    func testTextStopBombShowsFallbackAndDiscloses() throws {
        // A 1,000-stop gradient painting the fill, stroke and three decorations of a 2,000-character
        // positioned run: sixteen million copies.
        let run = String(repeating: "a", count: 2_000)
        let xs = String(repeating: "0 ", count: 2_000)
        let bomb = svg(gradient(stops: 1_000), "<text x='\(xs)' y='10' font-size='4' fill='url(#g)' stroke='url(#g)' text-decoration='underline overline line-through'>\(run)</text>")
        XCTAssertFalse(isWithinLimits(bomb))
        let (attachment, text) = try image("<p><img src='t.svg' alt='Banner'/></p>", files: ["t.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Banner")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: Rule 5: font-variation-settings copied per span

    func testVariationSettingsBombShowsFallbackAndDiscloses() throws {
        // Five thousand axes on each of 2,000 per-character spans: the renderer allocates gigabytes.
        let axes = String(repeating: "\"wght\" 700,", count: 5_000)
        let run = String(repeating: "a", count: 2_000)
        let xs = String(repeating: "0 ", count: 2_000)
        let bomb = svg("", "<text x='\(xs)' y='10' font-size='4' font-variation-settings='\(axes)'>\(run)</text>")
        // StaticSVG's `testVariationSettingsBombIsRefused` asserts the copy verdict on this drawing.
        XCTAssertFalse(isWithinLimits(bomb))
        let (attachment, text) = try image("<p><img src='v.svg' alt='Weighted'/></p>", files: ["v.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment, "a variation bomb is not rendered")
        XCTAssertEqual(text.richMediaPlain, "Weighted")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: Rule 5: the decoration dash

    func testDecoratedDashBombShowsFallbackAndDiscloses() throws {
        // 2,000 dash entries on a 2,000-character run: within the bound undecorated, past it decorated.
        let dash = String(repeating: "1 ", count: 2_000)
        let run = String(repeating: "a", count: 2_000)
        let xs = String(repeating: "0 ", count: 2_000)
        func drawing(_ decoration: String) -> String {
            svg("", "<text x='\(xs)' y='10' font-size='4' stroke='black' stroke-dasharray='\(dash)'\(decoration)>\(run)</text>")
        }
        // StaticSVG's `testDecoratedDashBombIsRefused` asserts the copy verdict on this drawing and
        // on its undecorated neighbour.
        let bomb = drawing(" text-decoration='underline overline line-through'")
        XCTAssertFalse(isWithinLimits(bomb))
        let (attachment, text) = try image("<p><img src='d.svg' alt='Dashed'/></p>", files: ["d.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Dashed")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }
}
