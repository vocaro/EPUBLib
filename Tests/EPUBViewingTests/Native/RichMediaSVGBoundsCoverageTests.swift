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

    /// The marker-instance verdict and the steps the bounded walk spent, straight from the
    /// pre-render check. Used where calling the renderer would be expensive or where a test
    /// asserts the walk stays near-linear.
    private func markerCheck(_ svg: String) -> (withinLimits: Bool, steps: Int) {
        guard let document = try? ContentDocument.parse(
            Data(svg.utf8), path: "svg",
            limits: .init(bytes: SVGContent.maximumBytes, depth: SVGContent.maximumDepth, nodes: SVGContent.maximumNodes),
            asContent: false) else { return (false, 0) }
        return SVGContent.markerInstanceCheck(document.root)
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

    // MARK: Marker expansion (doc: 100,000 instances = shapes x vertices x marker draws)

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

    // MARK: `<use>` multiplies a marker-bearing shape (evasion: multiplication)

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

    // MARK: Markers applied through CSS the renderer honours (evasion: CSS whitespace)

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
        // A marker url the renderer cannot resolve to an element reference draws nothing: it
        // requires `url(#id)` (svgtypes `FuncIRI`), so `url(data:opaque)` is not a bomb and renders.
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs>\(marker)</defs><style>path{marker-mid:url(data:opaque)}</style><path d='\(d)'/></svg>"))
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs>\(marker)</defs><path d='\(d)' marker-mid='url(#missing)'/></svg>"),
                      "a reference to no existing marker instantiates nothing")
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

    // MARK: Markers inside a `<mask>` (evasion: masks)

    /// The renderer re-draws a mask's content, markers included, once per element that references
    /// the mask, which the drawn-tree walk does not multiply. A marker-bearing shape inside a mask
    /// is therefore refused outright, whether the shape is there directly, reached through `<use>`,
    /// or applied a marker through CSS. A mask with no marker-bearing shape is unaffected.
    func testMarkerInsideMaskIsRefused() throws {
        let ns = Self.ns
        let marker = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2'>" + String(repeating: "<rect width='1' height='1'/>", count: 100) + "</marker>"
        let path = "M0 0" + String(repeating: " L1 1", count: 399)
        // Directly inside the mask, referenced by one shape (the reviewer's e1b channel).
        XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs>\(marker)<mask id='k'><path d='\(path)' marker-mid='url(#m)'/></mask></defs><rect width='9' height='9' mask='url(#k)'/></svg>"),
                       "a marker-bearing shape in a mask is refused; the renderer re-draws it per reference")
        // Reached through <use> from inside the mask.
        XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs>\(marker)<g id='g'><path d='\(path)' marker-mid='url(#m)'/></g><mask id='k'><use xlink:href='#g'/></mask></defs><rect width='9' height='9' mask='url(#k)'/></svg>"),
                       "a marker reached through <use> inside a mask is refused too")
        // Applied through a stylesheet to a shape inside the mask.
        XCTAssertFalse(renders("<svg \(ns) width='200' height='50'><defs>\(marker)<mask id='k'><path class='e' d='\(path)'/></mask></defs><style>.e{marker-mid:url(#m)}</style><rect width='9' height='9' mask='url(#k)'/></svg>"))
        // Inherited from the mask element's own ancestor (the renderer resolves marker-* up the
        // static tree, not from the referencing element).
        XCTAssertFalse(markerCheck("<svg \(ns) width='200' height='50'><defs>\(marker)<g marker-mid='url(#m)'><mask id='k'><path d='\(path)'/></mask></g></defs><rect width='9' height='9' mask='url(#k)'/></svg>").withinLimits,
                       "a marker inherited onto mask content from the mask's ancestor is refused")
        // A mask without a marker-bearing shape renders.
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs>\(marker)<mask id='k'><rect width='9' height='9' fill='white'/></mask></defs><rect width='9' height='9' mask='url(#k)' fill='black'/></svg>"),
                      "a mask with no marker is unaffected")
    }

    // MARK: Markers inside a `<clipPath>` are not drawn

    /// The renderer never instantiates a marker on a shape inside a `<clipPath>` (`marker::is_valid`
    /// rejects it), so a clip path is not an amplification channel and must not be refused.
    func testMarkerInsideClipPathRenders() throws {
        let ns = Self.ns
        let marker = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2'>" + String(repeating: "<rect width='1' height='1'/>", count: 400) + "</marker>"
        let path = "M0 0" + String(repeating: " L1 1", count: 399)
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs>\(marker)<clipPath id='k'><path d='\(path)' marker-mid='url(#m)'/></clipPath></defs><rect width='200' height='50' clip-path='url(#k)'/></svg>"),
                      "markers inside a clipPath are not drawn, so the clip path renders")
    }

    // MARK: A cyclic marker chain cannot make the check explode (evasion: exponential time)

    /// A chain of markers each referencing the next twice, with a back-edge closing the cycle, made
    /// the previous check take time exponential in its depth. The renderer draws nothing from it
    /// (the linking paths are empty, so no vertex instantiates a marker); the check must agree and
    /// stay near-linear. The verdict and the step counter are asserted, never wall-clock time, and
    /// the depth is small enough that even an exponential regression would finish in seconds.
    func testCyclicMarkerChainDoesNotExplode() throws {
        let ns = Self.ns
        func chain(_ depth: Int) -> String {
            var markers = ""
            for index in 0..<depth {
                let next = (index + 1) % depth // the last marker points back to the first
                markers += "<marker id='c\(index)' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2'>"
                    + "<path d='' marker-mid='url(#c\(next))'/><path d='' marker-mid='url(#c\(next))'/></marker>"
            }
            return "<svg \(ns) width='50' height='20'><defs>\(markers)</defs><path d='M0 0 L1 1' marker-mid='url(#c0)'/></svg>"
        }
        let result = markerCheck(chain(18))
        XCTAssertTrue(result.withinLimits, "the empty-path chain draws nothing and is within limits")
        XCTAssertLessThan(result.steps, 10_000, "the walk is near-linear in the node count, not exponential in the chain depth")
        XCTAssertTrue(renders(chain(18)), "and it renders")
    }

    // MARK: A stylesheet marker rule is charged only to the shapes it can match (evasion: over-refusal)

    /// A `marker-end` rule on a class attaches one arrowhead per connector, not one per vertex, and
    /// its selector is evaluated so unrelated high-vertex paths are not charged. This mirrors an
    /// ordinary flow or map diagram that the previous check refused.
    func testStylesheetSelectorChargesOnlyMatchingShapes() throws {
        let ns = Self.ns
        let arrow = "<marker id='arr' markerWidth='10' markerHeight='10' refX='5' refY='5' orient='auto'><path d='M0 0 L10 5 L0 10 Z'/><path d='M0 2 L6 5'/><path d='M0 8 L6 5'/></marker>"
        let edges = String(repeating: "<path class='edge' d='M0 0 C10 10 20 0 30 10'/>", count: 300)
        let outlines = String(repeating: "<path class='outline' d='M0 0" + String(repeating: " L1 1", count: 3_999) + "'/>", count: 5)
        XCTAssertTrue(renders("<svg \(ns) width='800' height='600'><defs>\(arrow)</defs><style>.edge{marker-end:url(#arr)}</style>\(edges)\(outlines)</svg>"),
                      "300 CSS-arrowed connectors plus five 4,000-vertex outline paths render; marker-end is per shape and the outlines are not matched")
        // A universal selector matches the high-vertex outline too, so it is charged and refused.
        let big = "<marker id='m' markerWidth='2' markerHeight='2'>" + String(repeating: "<rect width='1' height='1'/>", count: 200) + "</marker>"
        XCTAssertFalse(renders("<svg \(ns) width='800' height='600'><defs>\(big)</defs><style>*{marker-mid:url(#m)}</style><path d='M0 0" + String(repeating: " L1 1", count: 3_999) + "'/></svg>"),
                       "a universal marker-mid rule matches the long path and is charged over the bound")
        // A stylesheet with no marker property triggers no charge.
        XCTAssertTrue(renders("<svg \(ns) width='200' height='200'><style>path{fill:red}</style><path d='M0 0" + String(repeating: " L1 1", count: 3_999) + "'/></svg>"),
                      "a marker-less stylesheet is not charged")
    }

    // MARK: Geometry the renderer flattens by radius (new channel: arcs and curved primitives)

    /// The renderer flattens an elliptical-arc path command, and a `circle`/`ellipse`/rounded
    /// `rect`, into a radius-dependent number of segments, each a `marker-mid` vertex — so a few
    /// tokens can become thousands of instances. A marker-mid path with an arc is refused (its
    /// segment count cannot be bounded from the text); a small curved primitive is bounded by its
    /// radius and renders, while a large-radius one is refused.
    func testArcAndCurvedMarkerGeometryIsBounded() throws {
        let ns = Self.ns
        let marker = "<marker id='m' markerWidth='2' markerHeight='2'>" + String(repeating: "<rect width='1' height='1'/>", count: 100) + "</marker>"
        // A path of a few arc commands: tiny text, but thousands of flattened marker vertices.
        let arcs = "M0 0" + String(repeating: "a100000 100000 0 1 1 1 0", count: 40)
        XCTAssertFalse(markerCheck("<svg \(ns) width='200' height='50'><defs>\(marker)</defs><path d='\(arcs)' marker-mid='url(#m)'/></svg>").withinLimits,
                       "a marker-mid path with elliptical arcs is refused")
        // A small circle flattens to a handful of segments and renders.
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs>\(marker)</defs><circle cx='10' cy='10' r='6' marker-mid='url(#m)'/></svg>"),
                      "a small-radius circle with a marker is bounded by its radius and renders")
        // An extreme-radius circle flattens to more segments than the bound and is refused (its
        // stored coordinates would also be extreme; see #186).
        XCTAssertFalse(markerCheck("<svg \(ns) width='200' height='50'><defs>\(marker)</defs><circle cx='0' cy='0' r='1e40' marker-mid='url(#m)'/></svg>").withinLimits,
                       "an extreme-radius circle flattens to too many marker vertices and is refused")
    }

    // MARK: A marker whose single node is point-heavy (new channel: marker-content volume)

    /// The renderer re-stores a marker's flattened geometry at every instance, so one marker node
    /// holding thousands of points costs as much as thousands of small nodes. The count charges a
    /// node's points, so a point-heavy marker on a high-vertex host is refused, while the same
    /// marker on a low-vertex host, and a small marker on the high-vertex host, render.
    func testPointHeavyMarkerContentIsBounded() throws {
        let ns = Self.ns
        let heavy = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2'><path d='M0 0" + String(repeating: "h1", count: 10_000) + "'/></marker>"
        let hostHigh = "M0 0" + String(repeating: " L1 1", count: 9_999) // ~10,000 marker-mid vertices
        XCTAssertFalse(markerCheck("<svg \(ns) width='200' height='50'><defs>\(heavy)</defs><path d='\(hostHigh)' marker-mid='url(#m)'/></svg>").withinLimits,
                       "a 10,000-point marker node on a 10,000-vertex host is refused")
        let hostLow = "M0 0 L1 1 L2 2" // two marker-mid vertices
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs>\(heavy)</defs><path d='\(hostLow)' marker-mid='url(#m)'/></svg>"),
                      "the same point-heavy marker on a low-vertex host renders")
        let small = "<marker id='m' markerUnits='userSpaceOnUse' markerWidth='2' markerHeight='2'><rect width='1' height='1'/></marker>"
        XCTAssertTrue(renders("<svg \(ns) width='200' height='50'><defs>\(small)</defs><path d='\(hostHigh)' marker-mid='url(#m)'/></svg>"),
                      "a small marker on the high-vertex host renders")
    }
}
