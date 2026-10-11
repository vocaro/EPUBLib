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

    // MARK: `<use>` multiplies a marker-bearing shape

    /// A 100-shape marker on a 400-vertex path (~80,000 instances per copy), defined once in
    /// `<defs>` and drawn through `<use>`. The renderer instantiates the marker afresh at every
    /// clone, so the bound must charge each use; counting the shape once let the cost escape.
    func testMarkerMultipliedByUseIsBounded() throws {
        let ns = Self.ns
        let marker = "<marker id='m' markerWidth='2' markerHeight='2'>" + String(repeating: "<rect width='1' height='1'/>", count: 100) + "</marker>"
        let group = "<g id='g'><path d='M0 0" + String(repeating: " L1 1", count: 399) + "' marker-mid='url(#m)'/></g>"
        func uses(_ count: Int) -> String {
            "<svg \(ns) width='200' height='50'><defs>\(marker)\(group)</defs>" + String(repeating: "<use xlink:href='#g'/>", count: count) + "</svg>"
        }
        XCTAssertTrue(renders(uses(1)), "one clone (~80,000 instances) renders")
        XCTAssertFalse(renders(uses(2)), "two clones (~160,000 instances) are refused")
        XCTAssertFalse(renders(uses(50)), "the reviewer's 50-use bomb is refused")
        // A use of a group that itself holds uses must multiply too.
        let nested = "<svg \(ns) width='200' height='50'><defs>\(marker)\(group)<g id='outer'>"
            + String(repeating: "<use xlink:href='#g'/>", count: 5) + "</g></defs>"
            + String(repeating: "<use xlink:href='#outer'/>", count: 5) + "</svg>"
        XCTAssertFalse(renders(nested), "5 x 5 nested uses (~2,000,000 instances) are refused")
    }

    // MARK: Markers applied through CSS the renderer honours

    /// The renderer accepts any whitespace and a comment between a marker property and its colon,
    /// the `marker` shorthand, and a stylesheet selector, in a `style` attribute or a `<style>`
    /// element. Each applies a 400-shape marker to a ~400-vertex path (well over the bound); the
    /// detection must match every spelling the renderer draws, not just `prop:` and `prop :`.
    func testMarkerThroughCSSWhitespaceAndStylesheetIsBounded() throws {
        let ns = Self.ns
        let marker = "<marker id='m' markerWidth='2' markerHeight='2'>" + String(repeating: "<rect width='1' height='1'/>", count: 400) + "</marker>"
        let d = "M0 0" + String(repeating: " L1 1", count: 399)
        for declaration in ["marker-mid\t:url(#m)", "marker-mid\n:url(#m)", "marker-mid  :url(#m)", "marker-mid/* c */:url(#m)", "marker:url(#m)"] {
            XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs>\(marker)</defs><path d='\(d)' style='\(declaration)'/></svg>"),
                           "style attribute '\(declaration.debugDescription)' is honoured and must be counted")
            XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs>\(marker)</defs><style>path{\(declaration)}</style><path d='\(d)'/></svg>"),
                           "stylesheet '\(declaration.debugDescription)' is honoured and must be counted")
        }
        // A stylesheet whose url the scan cannot read still charges the largest marker.
        XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs>\(marker)</defs><style>path{marker-mid:url(data:opaque)}</style><path d='\(d)'/></svg>"))
    }

    /// Proof the renderer honours a tab-before-colon marker in a stylesheet, so refusing the
    /// bomb above is refusing real cost, not a no-op: a small such marker actually paints.
    func testTabBeforeColonStylesheetMarkerActuallyDraws() throws {
        let svg = "<svg \(Self.ns) width='60' height='20'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='6' markerHeight='6' refX='3' refY='3'><rect width='6' height='6' fill='red'/></marker></defs><style>path{marker-mid\t:url(#m)}</style><path d='M10 10 L30 10 L50 10' fill='none'/></svg>"
        let source = try XCTUnwrap(ReaderImageSource.svg(Data(svg.utf8), path: "", key: "tab-marker"))
        let image = try XCTUnwrap(source.decode(maxPixelSize: 60))
        let pixel = RichMediaImages.rgba(image, x: 30, y: 10)
        XCTAssertEqual(pixel, [255, 0, 0, 255], "the marker paints at the mid vertex, so the renderer honoured the tab")
    }

    // MARK: Nested markers multiply

    /// A marker whose content path itself bears a marker amplifies as the product. The outer
    /// marker on a 400-vertex path, holding a 400-vertex path that bears a 100-shape marker,
    /// instantiates far over the bound and is refused; the first-order count alone missed it.
    func testNestedMarkerIsBounded() throws {
        let ns = Self.ns
        let inner = "<marker id='mi' markerWidth='2' markerHeight='2'>" + String(repeating: "<rect width='1' height='1'/>", count: 100) + "</marker>"
        let innerPath = "M0 0" + String(repeating: " L1 1", count: 399)
        let outer = "<marker id='mo' markerUnits='userSpaceOnUse' markerWidth='9' markerHeight='9'><path d='\(innerPath)' marker-mid='url(#mi)'/></marker>"
        let d = "M0 0" + String(repeating: " L1 1", count: 399)
        XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs>\(inner)\(outer)</defs><path d='\(d)' marker-mid='url(#mo)'/></svg>"),
                       "nested markers multiply and are refused")
    }

    // MARK: Real marker content must still render

    /// A stylesheet marker rule charges every shape, so the detection must not refuse an ordinary
    /// diagram: 100 short arrows with a CSS-applied arrowhead render, as does a long marker-less
    /// polyline, and a stylesheet with no marker rule does not trigger the charge.
    func testStylesheetMarkerDoesNotRefuseOrdinaryDiagrams() throws {
        let ns = Self.ns
        let arrow = "<marker id='a' markerWidth='10' markerHeight='10' refX='5' refY='5'><path d='M0 0 L10 5 L0 10 Z'/></marker>"
        let edges = String(repeating: "<line class='edge' x1='0' y1='0' x2='50' y2='50'/>", count: 100)
        XCTAssertTrue(renders("<svg \(ns) width='200' height='200'><defs>\(arrow)</defs><style>.edge{marker-end:url(#a)}</style>\(edges)</svg>"),
                      "a real diagram of arrowed edges with a CSS marker rule renders")
        let polyline = "<polyline points='" + (0..<4_000).map { "\($0) 1" }.joined(separator: " ") + "'/>"
        XCTAssertTrue(renders("<svg \(ns) width='200' height='200'>\(polyline)</svg>"), "a long marker-less polyline renders")
        let bigMarker = "<marker id='m' markerWidth='2' markerHeight='2'>" + String(repeating: "<rect width='1' height='1'/>", count: 400) + "</marker>"
        let path = "<path d='M0 0" + String(repeating: " L1 1", count: 399) + "'/>"
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs>\(bigMarker)</defs><style>path{fill:red}</style>\(path)</svg>"),
                      "a marker-less path under a marker-less stylesheet is not charged")
    }
}
