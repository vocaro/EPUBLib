import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Two renderer amplifications the byte, node, depth and expansion limits do not bound: one
/// `<text>` run, whose layout is super-linear in its length, and a `<marker>` the renderer
/// clones per path vertex. Each is bounded before the document reaches the renderer and, past
/// its bound, shows the fallback text with the same `svg` disclosure as the other limits
/// ([#170](https://github.com/vocaro/EPUBLib/issues/170)). Boundary cases assert counts and
/// the fallback, never a time or memory figure, which is machine-dependent (#62).
final class RichMediaSVGBoundsCoverageTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"

    /// Whether the inline SVG renders through the production renderer entry point.
    private func renders(_ svg: String) -> Bool {
        ReaderImageSource.svg(Data(svg.utf8), path: "", key: UUID().uuidString) != nil
    }

    private func image(_ body: String, files: [String: Data] = [:]) throws -> (ReaderImageAttachment?, SectionText) {
        let text = try RichMediaBook(body: body, files: files).build()
        return (text.richMediaImages.first, text)
    }

    // MARK: One text run (doc: 20,000 characters)

    func testSingleTextRunBoundaryRendersOrFallsBack() throws {
        let ns = Self.ns
        func text(_ characters: Int) -> String {
            "<svg \(ns) width='200' height='50'><text x='0' y='20'>\(String(repeating: "a", count: characters))</text></svg>"
        }
        XCTAssertTrue(renders(text(20_000)), "a 20,000-character run renders")
        XCTAssertFalse(renders(text(20_001)), "a run one character over the bound is refused")

        // Unpositioned tspans join into one run and are counted together.
        func tspans(_ characters: Int) -> String {
            let each = String(repeating: "a", count: characters / 10)
            return "<svg \(ns) width='200' height='50'><text x='0' y='20'>" + String(repeating: "<tspan>\(each)</tspan>", count: 10) + "</text></svg>"
        }
        XCTAssertTrue(renders(tspans(19_990)))
        XCTAssertFalse(renders(tspans(20_010)), "ten tspans totalling over 20,000 characters are one over-long run")

        // The bound is per run: many separate <text> elements stay linear and render.
        let many = "<svg \(ns) width='200' height='50'>" + String(repeating: "<text x='0' y='20'>\(String(repeating: "a", count: 1_000))</text>", count: 100) + "</svg>"
        XCTAssertTrue(renders(many), "100 short runs (100,000 characters total) render; the bound is on one run")
    }

    func testOverLongInlineTextRunShowsTitleFallbackAndDiscloses() throws {
        let run = String(repeating: "a", count: 20_001)
        let (attachment, text) = try image("<p><svg \(Self.ns) width='200' height='50'><title>Caption</title><text x='0' y='20'>\(run)</text></svg></p>")
        XCTAssertNil(attachment, "an over-long run is not rendered")
        XCTAssertEqual(text.richMediaPlain, "Caption", "its title stands in")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1, "and it is disclosed like the other limits")
    }

    func testOverLongArchiveTextRunShowsAltTextAndDiscloses() throws {
        let run = String(repeating: "a", count: 20_001)
        let svg = "<svg \(Self.ns) width='200' height='50'><text x='0' y='20'>\(run)</text></svg>"
        let (attachment, text) = try image("<p><img src='long.svg' alt='Diagram'/></p>", files: ["long.svg": Data(svg.utf8)])
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Diagram")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: Marker expansion (doc: 100,000 instances = shapes x vertices)

    /// A `<marker>` of `shapes` rectangles on a path whose `d` holds exactly `tokens` numeric
    /// tokens (one `M` pair plus line-to pairs), so the instance count is `shapes * tokens`.
    private func markerSVG(shapes: Int, tokens: Int, markup: (String) -> String = { "<path d='\($0)' marker-mid='url(#m)'/>" }) -> String {
        precondition(tokens % 2 == 0 && tokens >= 2)
        let content = String(repeating: "<rect width='1' height='1'/>", count: shapes)
        let path = "M0 0" + String(repeating: " L1 1", count: tokens / 2 - 1)
        return "<svg \(Self.ns) width='200' height='50'><defs><marker id='m' markerWidth='2' markerHeight='2'>\(content)</marker></defs>\(markup(path))</svg>"
    }

    func testMarkerInstanceBoundaryRendersOrFallsBack() throws {
        // 100 shapes x 1,000 tokens = 100,000 instances, exactly the bound.
        XCTAssertTrue(renders(markerSVG(shapes: 100, tokens: 1_000)), "100,000 marker instances render")
        XCTAssertFalse(renders(markerSVG(shapes: 100, tokens: 1_020)), "102,000 marker instances are refused")
        // The reviewer's probe: a 400-shape marker along ~800 path vertices.
        XCTAssertFalse(renders(markerSVG(shapes: 400, tokens: 1_600)), "the 400x800 marker bomb is refused")
    }

    func testMarkerCountedThroughInheritanceAndStyle() throws {
        let ns = Self.ns
        let content = String(repeating: "<rect width='1' height='1'/>", count: 100)
        let path = "M0 0" + String(repeating: " L1 1", count: 509) // 1,020 tokens
        // Inherited from an ancestor group: still counted.
        XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs><marker id='m'>\(content)</marker></defs><g marker-mid='url(#m)'><path d='\(path)'/></g></svg>"),
                       "a marker inherited from an ancestor amplifies the same way")
        // Declared through a style attribute.
        XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs><marker id='m'>\(content)</marker></defs><path d='\(path)' style='marker-mid:url(#m)'/></svg>"))
        // A path with the same vertices but no marker reference is unaffected.
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs><marker id='m'>\(content)</marker></defs><path d='\(path)'/></svg>"),
                      "a shape that references no marker instantiates none")
    }

    func testMarkerBombShowsFallbackAndDiscloses() throws {
        let bomb = markerSVG(shapes: 400, tokens: 1_600) { "<desc>Network path</desc><path d='\($0)' marker-mid='url(#m)' stroke='black'/>" }
        let (attachment, text) = try image("<p><img src='bomb.svg' alt='Flow'/></p>", files: ["bomb.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment, "a marker bomb is not rendered")
        XCTAssertEqual(text.richMediaPlain, "Flow")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }
}
