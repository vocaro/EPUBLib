import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Two renderer amplifications the byte, node, depth and expansion limits do not bound: one
/// `<text>` run, whose layout is super-linear in its length, and a `<marker>`, whose content the
/// renderer converts again at every vertex it is drawn at. Each is bounded before the document
/// reaches the renderer and, past its bound, shows the fallback text with the same `svg`
/// disclosure as the other limits ([#170](https://github.com/vocaro/EPUBLib/issues/170)).
///
/// Markers are not modelled: they are counted in the forms a diagram uses and refused in any
/// other, by the seven rules of `SVGContent.markerVerdict`, each of which has a test here with an
/// input it refuses and a neighbour within limits. Every case asserts a verdict, a count or the
/// step counter, never a time or a memory figure, which is machine-dependent (#62). An input that
/// is refused is small enough to be harmless should a regression let it through to the renderer,
/// or is given to the check alone.
final class RichMediaSVGBoundsCoverageTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"

    /// An SVG whose root has few enough attributes to add nothing to the size of a marker in it.
    private func svg(_ defs: String, _ body: String, root: String = "width='200' height='50'") -> String {
        "<svg \(Self.ns) \(root)><defs>\(defs)</defs>\(body)</svg>"
    }

    /// A marker of `rects` rectangles: its size is `rects`, each element counting one.
    private func marker(_ id: String = "m", rects: Int = 1, _ attributes: String = "") -> String {
        "<marker id='\(id)' \(attributes)>" + String(repeating: "<rect width='1' height='1'/>", count: rects) + "</marker>"
    }

    /// A path whose data holds exactly `vertices` numbers, which is what the check counts it as.
    private func path(vertices: Int, _ attributes: String = "") -> String {
        precondition(vertices >= 2)
        return "<path d='M0 0" + String(repeating: "h1", count: vertices - 2) + "' \(attributes)/>"
    }

    private func parsed(_ svg: String) -> ContentNode? {
        try? ContentDocument.parse(
            Data(svg.utf8), path: "svg",
            limits: .init(bytes: SVGContent.maximumBytes, depth: SVGContent.maximumDepth, nodes: SVGContent.maximumNodes),
            asContent: false).root
    }

    /// The marker verdict alone, with the instances counted and the steps the walk took: for an
    /// input that would cost the renderer much, and wherever a count is asserted.
    private func verdict(_ svg: String, stepBudget: Int = SVGContent.markerStepBudget) -> SVGContent.MarkerVerdict {
        guard let root = parsed(svg) else { return (false, -1, -1) }
        return SVGContent.markerVerdict(root, stepBudget: stepBudget)
    }

    /// The whole pre-render check, without the renderer.
    private func isWithinLimits(_ svg: String) -> Bool {
        parsed(svg).map { SVGContent.isWithinRenderingLimits($0) } ?? false
    }

    /// Whether the SVG renders through the production renderer entry point.
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

    /// A `<tref>` renders the text of the element it names, whatever that element is, and the
    /// renderer shapes it as part of the run: text the 20,000-character count never sees. SVG 2
    /// removed `<tref>`, so an SVG that holds one is refused wherever it stands. The targets here
    /// are a few characters, so the renderer would make nothing of them.
    func testTrefIsRefusedWhereverItStands() throws {
        let ns = Self.ns
        func drawing(_ text: String, defs: String = "<g id='t'>label</g>") -> String {
            "<svg \(ns) width='200' height='50'><defs>\(defs)</defs>\(text)</svg>"
        }
        XCTAssertTrue(renders(drawing("<text y='20'><tspan>label</tspan></text>")), "a tspan is an ordinary run")
        XCTAssertFalse(renders(drawing("<text y='20'><tref xlink:href='#t'/></text>")), "a tref to a group")
        XCTAssertFalse(renders(drawing("<text y='20'><tref href='#t'/></text>")), "by either attribute")
        XCTAssertFalse(renders(drawing("<text y='20'><tspan><tref xlink:href='#t'/></tspan></text>")), "nested in a tspan")
        XCTAssertFalse(renders(drawing("<text y='20'>a</text>", defs: "<text id='u'><tref xlink:href='#t'/></text><g id='t'>label</g>")),
                       "in a definition nothing draws")
        XCTAssertFalse(renders(drawing("<text y='20'><tref xlink:href='#top'/></text>").replacingOccurrences(of: "<svg ", with: "<svg id='top' ")),
                       "naming the root, whose text is the whole document's")

        let (attachment, text) = try image("<p><svg \(ns) width='200' height='50'><title>Legend</title><defs><g id='t'>label</g></defs><text y='20'><tref xlink:href='#t'/></text></svg></p>")
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Legend", "the fallback stands in")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: Rule 7: the count (doc: 100,000)

    /// The sum over the shapes drawn: for each, its vertices times the size of its `marker-mid`
    /// marker, the sizes of its `marker-start` and `marker-end` markers, and one for each of the
    /// three it draws with.
    func testMarkerCountAtTheBound() throws {
        let bound = SVGContent.maximumMarkerInstances
        XCTAssertEqual(bound, 100_000)
        // One rectangle at 99,999 vertices, and one more for the property: exactly the bound.
        var result = verdict(svg(marker(), path(vertices: 99_999, "marker-mid='url(#m)'")))
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.instances, bound)
        result = verdict(svg(marker(), path(vertices: 100_000, "marker-mid='url(#m)'")))
        XCTAssertFalse(result.withinLimits, "one vertex more is past it")
        XCTAssertEqual(result.instances, bound + 1)

        // A marker of 100 elements counts 100 at each vertex.
        result = verdict(svg(marker(rects: 100), path(vertices: 999, "marker-mid='url(#m)'")))
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.instances, 99_901)
        XCTAssertFalse(verdict(svg(marker(rects: 100), path(vertices: 1_000, "marker-mid='url(#m)'"))).withinLimits)
        // The reviewer's probe on the issue: a 400-shape marker along 800 vertices.
        XCTAssertFalse(verdict(svg(marker(rects: 400), path(vertices: 800, "marker-mid='url(#m)'"))).withinLimits)

        // Start and end markers are drawn once each, however many vertices the shape has.
        result = verdict(svg(marker(rects: 3), path(vertices: 500, "marker-start='url(#m)' marker-end='url(#m)'")))
        XCTAssertEqual(result.instances, 8, "(3 + 1) for each end")
        XCTAssertTrue(result.withinLimits)
        // A shape that names no marker draws none, and a marker nothing names costs nothing.
        result = verdict(svg(marker(rects: 400), path(vertices: 800)))
        XCTAssertEqual(result.instances, 0)
        XCTAssertTrue(result.withinLimits)

        // What is within the bound renders.
        XCTAssertTrue(renders(svg(marker(rects: 100), path(vertices: 100, "marker-mid='url(#m)' stroke='black'"))),
                      "10,001 marker instances render")
        XCTAssertFalse(renders(svg(marker(rects: 100), path(vertices: 1_000, "marker-mid='url(#m)' stroke='black'"))),
                       "100,001 are refused before the renderer")
    }

    func testMarkerBombShowsFallbackAndDiscloses() throws {
        let bomb = "<svg \(Self.ns) width='200' height='50'><desc>Network path</desc><defs>\(marker(rects: 100))</defs>\(path(vertices: 1_002, "marker-mid='url(#m)' stroke='black'"))</svg>"
        let (attachment, text) = try image("<p><img src='bomb.svg' alt='Flow'/></p>", files: ["bomb.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment, "a marker bomb is not rendered")
        XCTAssertEqual(text.richMediaPlain, "Flow")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)

        let (inline, inlineText) = try image("<p>\(bomb)</p>")
        XCTAssertNil(inline)
        XCTAssertEqual(inlineText.richMediaPlain, "Network path", "inline, its description stands in")
        XCTAssertEqual(inlineText.report.unsupportedElements["svg"], 1)
    }

    /// The walk follows `<use>` as the expansion count does, to whichever element the renderer
    /// resolves the reference to, and charges one step for each element it visits and each
    /// reference it follows.
    func testMarkersAreCountedAtEveryUseAndTheWalkIsCharged() throws {
        let shape = "<g id='g'>" + path(vertices: 10, "marker-mid='url(#m)'") + "</g>"
        func uses(_ count: Int, _ reference: String = "xlink:href='#g'") -> String {
            svg(marker(rects: 100) + shape, String(repeating: "<use \(reference)/>", count: count))
        }
        let result = verdict(uses(3))
        XCTAssertEqual(result.instances, 3 * 1_001, "each use draws the shape, and its markers, again")
        XCTAssertEqual(result.steps, 1 + 3 * 4, "the root, then for each use: the use, the reference, the group and the path")
        XCTAssertTrue(verdict(uses(99)).withinLimits)
        XCTAssertFalse(verdict(uses(100)).withinLimits, "100 uses of 1,001 instances are past the bound")
        XCTAssertFalse(isWithinLimits(uses(100)))

        // Uses of a group of uses multiply.
        let nested = svg(marker(rects: 100) + shape + "<g id='outer'>" + String(repeating: "<use xlink:href='#g'/>", count: 10) + "</g>",
                         String(repeating: "<use xlink:href='#outer'/>", count: 10))
        XCTAssertFalse(verdict(nested).withinLimits, "10 x 10 uses")

        // An unprefixed `href` takes precedence over `xlink:href`, as in the renderer.
        XCTAssertEqual(verdict(uses(2, "href='#g' xlink:href='#none'")).instances, 2_002)
        XCTAssertEqual(verdict(uses(2, "xlink:href='#none' href='#g'")).instances, 2_002)
        XCTAssertEqual(verdict(uses(2, "href='#none' xlink:href='#g'")).instances, 0)
        // The renderer skips white space before the `#` and reads the id up to the first space.
        XCTAssertEqual(verdict(uses(2, "href=' #g '")).instances, 2_002)
        XCTAssertEqual(verdict(uses(2, "href='#g&#10;'")).instances, 0, "a line feed is part of the id, and no element has it")

        // The renderer takes an id from the first attribute named `id` in any namespace, and an id
        // may end in white space other than a space. Each such target is followed.
        for (id, reference) in [("xlink:id='g'", "href='#g'"), ("xml:id='g'", "href='#g'"), ("f:id='g'", "href='#g'"),
                                ("id='g&#160;'", "href='#g&#160;'"), ("id='g&#9;'", "href='#g&#9;'")] {
            let document = svg(marker(rects: 100) + shape.replacingOccurrences(of: "id='g'", with: id),
                               String(repeating: "<use \(reference)/>", count: 2), root: "width='9' height='9' xmlns:f='urn:f'")
            XCTAssertEqual(verdict(document).instances, 2_002, "\(id) named by \(reference)")
        }
        // Of two elements with one id, whichever the renderer picks is counted.
        let twins = svg(marker(rects: 100) + "<g id='g'/>" + shape, String(repeating: "<use href='#g'/>", count: 2))
        XCTAssertEqual(verdict(twins).instances, 2_002)
        XCTAssertEqual(verdict(twins).steps, 1 + 2 * 6)
    }

    /// The walk stops at its step budget. An SVG within the expansion bound cannot reach the real
    /// one, so a small one is given here: 1,023 uses and groups over a tree of depth ten.
    func testTheWalkStopsAtItsStepBudget() throws {
        XCTAssertEqual(SVGContent.markerStepBudget, 4 * (SVGContent.maximumExpandedBytes / 32))
        var definitions = marker() + "<g id='t0'><path d='M0 0h1' marker-end='url(#m)'/></g>"
        for level in 1...9 {
            definitions += "<g id='t\(level)'><use href='#t\(level - 1)'/><use href='#t\(level - 1)'/></g>"
        }
        let tree = svg(definitions, "<use href='#t9'/>")
        let whole = verdict(tree)
        XCTAssertTrue(whole.withinLimits)
        XCTAssertEqual(whole.instances, 512 * 2, "512 leaves, each an end marker and its group")
        XCTAssertEqual(whole.steps, 3_582, "the root, the use and its reference, and 3,579 in the tree")
        let stopped = verdict(tree, stepBudget: 1_000)
        XCTAssertFalse(stopped.withinLimits, "the walk refuses when the budget runs out")
        XCTAssertEqual(stopped.steps, 1_001, "and stops there")
        XCTAssertTrue(verdict(tree, stepBudget: 3_582).withinLimits)
        XCTAssertFalse(verdict(tree, stepBudget: 3_581).withinLimits)

        // A reference that leads back to itself ends at the depth limit, not in a loop.
        let loop = verdict(svg(marker() + "<g id='a'><use href='#a'/><use href='#a'/></g>", "<use href='#a' marker-end='url(#m)'/>"))
        XCTAssertFalse(loop.withinLimits)
        XCTAssertLessThan(loop.steps, 200)
    }

    /// The limits are read from the tree this module parses, and the renderer parses the bytes for
    /// itself. Bytes this module could only read by recovering them as HTML — here, UTF-8 that
    /// declares itself UTF-16, a declaration the renderer ignores — give a tree in which a prefixed
    /// name such as `xlink:href` is not the name the renderer sees, so nothing counted in it bounds
    /// what the renderer would draw. Such an SVG is refused.
    func testAnSVGRecoveredAsHTMLIsRefused() throws {
        let drawing = svg(marker(rects: 2) + "<g id='g'>\(path(vertices: 4, "marker-mid='url(#m)' stroke='black'"))</g>", "<use xlink:href='#g'/><use xlink:href='#g'/>")
        XCTAssertTrue(renders(drawing))
        XCTAssertEqual(verdict(drawing).instances, 18)
        let misdeclared = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + drawing
        XCTAssertEqual(parsed(misdeclared)?.name, "html", "recovered as HTML")
        XCTAssertFalse(isWithinLimits(misdeclared))
        XCTAssertFalse(renders(misdeclared))
        XCTAssertFalse(renders("<?xml version=\"1.0\" encoding=\"UTF-16\"?><svg \(Self.ns) width='9' height='9'><rect width='9' height='9'/></svg>"),
                       "with or without a marker")
    }

    // MARK: Rule 1: stylesheets

    /// A stylesheet that names an element with `url(#…)` could give a marker to any shape, or a
    /// mask, a clip path or a paint server to a marker's content, by selectors this check does not
    /// evaluate. With a `<marker>` in the SVG, such a stylesheet is refused, however the reference
    /// is spelled and whichever `<style>` holds it.
    func testAStylesheetThatNamesAnElementIsRefused() throws {
        func drawing(_ sheet: String, _ hostAttributes: String = "class='e'") -> String {
            svg(marker(rects: 2), "\(sheet)<path d='M0 0h9h9' stroke='black' \(hostAttributes)/>")
        }
        for css in [".e{marker-end:url(#m)}", ".e{marker : url( #m )}", ".e{MARKER-MID:URL(#m)}", ".e{marker-mid:url('#m')}",
                    ".e{marker-mid/**/:/**/url(\"#m\")}", "@charset \"utf-8\"; path{marker-mid:url(#m)}",
                    "path{x:\"/*\";marker-mid:url(#m);y:\"*/\"}", "rect{fill:url(#g)}", "rect{mask:url(#k)}", "g>rect{clip-path:url(#c)}"] {
            XCTAssertFalse(verdict(drawing("<style>\(css)</style>")).withinLimits, css)
        }
        XCTAssertFalse(verdict(drawing("<style type='text/css'><![CDATA[.e{marker-end:url(#m)}]]></style>")).withinLimits)
        XCTAssertFalse(verdict(drawing("<h:style xmlns:h='http://www.w3.org/1999/xhtml'>.e{marker-end:url(#m)}</h:style>")).withinLimits,
                       "the renderer reads a style element of any namespace")
        XCTAssertFalse(verdict(drawing("<foreignObject><style>.e{marker-end:url(#m)}</style></foreignObject>")).withinLimits,
                       "wherever it stands")
        XCTAssertFalse(renders(drawing("<style>.e{marker-end:url(#m)}</style>")))

        // A stylesheet that names no element is no bar, whatever else it says of markers.
        for css in [".marker{fill:#333;stroke:#333}.marker.cross{stroke:#333}", ".e:hover{stroke:red}", ".e{marker:none;marker-end:inherit}",
                    "path[marker-end]{stroke-width:2}", "@font-face{font-family:F;src:url(data:font/woff2;base64,AAAA)}"] {
            let result = verdict(drawing("<style>\(css)</style>", "class='e' marker-end='url(#m)'"))
            XCTAssertTrue(result.withinLimits, css)
            XCTAssertEqual(result.instances, 3, css)
        }
        XCTAssertTrue(renders(drawing("<style>.marker{fill:#333}.e{stroke:red}</style>", "class='e' marker-end='url(#m)'")))
        // Nor is one that does, in an SVG with no marker to instantiate.
        XCTAssertTrue(renders("<svg \(Self.ns) width='20' height='20'><defs><linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><style>rect{fill:url(#g)}</style><rect width='20' height='20'/></svg>"))
    }

    // MARK: Rule 2: how a marker reaches a shape

    /// A shape's markers come from the attributes and `style` declarations of the shape and its
    /// ancestors, through each `<use>` that draws it.
    func testMarkersReachAShapeByAttributeStyleAndInheritance() throws {
        let host = path(vertices: 10)
        func count(_ body: String, defs: String = "", root: String = "width='200' height='50'") -> Int {
            verdict(svg(marker(rects: 3) + defs, body, root: root)).instances
        }
        XCTAssertEqual(count(path(vertices: 10, "marker-mid='url(#m)'")), 31, "ten vertices of three, and one")
        XCTAssertEqual(count("<g marker-mid='url(#m)'><g>\(host)</g></g>"), 31, "inherited from an ancestor")
        XCTAssertEqual(count(path(vertices: 10, "style='fill:none;marker-mid:url(#m);stroke:#000'")), 31, "in a style attribute")
        XCTAssertEqual(count(path(vertices: 10, "style='marker:url(#m)'")), 39, "the shorthand sets all three")
        XCTAssertEqual(count(path(vertices: 10, "style='marker-start:url(#m);marker-end:url(#m)'")), 8)
        XCTAssertEqual(count("<svg marker-end='url(#m)'><a><switch>\(host)</switch></a></svg>"), 4, "through the elements that draw their children")

        // Through `<use>`: the shape inherits where it is drawn, not where it is defined.
        XCTAssertEqual(count("<g marker-end='url(#m)'><use xlink:href='#p'/><use xlink:href='#p'/></g>", defs: "<g id='p'>\(host)</g>"), 8)
        XCTAssertEqual(count("<use xlink:href='#p' marker-end='url(#m)'/>", defs: "<symbol id='p'>\(host)</symbol>"), 4, "from the use itself, into a symbol")
        XCTAssertEqual(count("<use xlink:href='#p'/>", defs: "<g marker-end='url(#m)'><g id='p'>\(host)</g></g>"), 0,
                       "what stands above the definition is not above the drawn copy")
        XCTAssertEqual(count("", defs: "<g marker-end='url(#m)'>\(host)</g>"), 0, "a definition nothing draws")

        // Every spelling the renderer honours is read.
        XCTAssertEqual(count(path(vertices: 10, "xlink:marker-mid='url(#m)'")), 31, "the renderer takes the attribute in the XLink namespace")
        XCTAssertEqual(count(path(vertices: 10, "xml:marker-mid='url(#m)'")), 31)
        XCTAssertEqual(count(path(vertices: 10, "f:style='marker-mid:url(#m)'"), root: "width='9' height='9' xmlns:f='urn:f'"), 31,
                       "and a style attribute in any")
        for style in ["marker-mid : url(#m)", "marker-mid&#10;:&#9;url(#m)", "*marker-mid:url(#m)", "fill:red !importantmarker-mid:url(#m)",
                      "x:&quot;/*&quot;;marker-mid:url(#m);y:&quot;*/&quot;", "marker-mid:url(#m) !important", ";;marker-mid:url(#m);"] {
            XCTAssertEqual(count(path(vertices: 10, "style=\"\(style)\"")), 31, style)
        }
    }

    /// The renderer honours a marker property after `!important` with no separator, and in the XLink
    /// namespace: proof that reading those spellings counts real instances. Each paints a red marker
    /// at the middle vertex.
    func testTheRendererDrawsTheSpellingsTheCheckReads() throws {
        for attributes in ["style='fill:none !importantmarker-mid:url(#m)'", "fill='none' xlink:marker-mid='url(#m)'"] {
            let drawing = "<svg \(Self.ns) width='60' height='20'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='6' markerHeight='6' refX='3' refY='3'><rect width='6' height='6' fill='red'/></marker></defs><path d='M10 10 L30 10 L50 10' \(attributes)/></svg>"
            XCTAssertGreaterThan(verdict(drawing).instances, 0, attributes)
            let source = try XCTUnwrap(ReaderImageSource.svg(Data(drawing.utf8), path: "", key: UUID().uuidString), attributes)
            let image = try XCTUnwrap(source.decode(maxPixelSize: 60))
            XCTAssertEqual(RichMediaImages.rgba(image, x: 30, y: 10), [255, 0, 0, 255], attributes)
        }
    }

    /// One declaration never lowers what another asks for: a shape is charged the largest marker
    /// that it or any ancestor names. A declaration the renderer ignores, or one that only looks
    /// like an override, cannot hide the one it honours.
    func testADeclarationNeverLowersTheCharge() throws {
        let markers = marker("big", rects: 50) + marker("tiny")
        func count(_ attributes: String) -> Int {
            verdict(svg(markers, "<g marker-mid='url(#big)'>\(path(vertices: 10, attributes))</g>", root: "width='9' height='9' xmlns:f='urn:f'")).instances
        }
        XCTAssertEqual(count(""), 501)
        for attributes in ["marker-mid='url(#tiny)'", "marker-mid='none'", "marker-mid='inherit'", "marker-mid='bogus'",
                           "marker='url(#tiny)'", "style='MARKER-MID:url(#tiny)'", "f:marker-mid='url(#tiny)'",
                           "style='marker-mid:url(#tiny);marker-mid:none'"] {
            XCTAssertEqual(count(attributes), attributes == "marker='url(#tiny)'" ? 505 : 501, attributes)
        }
    }

    /// A value in the plain form `url(#id)`, or quoted as a browser writes a style, names the
    /// marker with that id. Any other value that begins `url(` and can name an element is charged
    /// the largest marker in the SVG, and a value that names none is charged nothing.
    func testWhatAMarkerValueNames() throws {
        let markers = marker("a") + marker("b", rects: 5)
        func count(_ value: String) -> Int {
            verdict(svg(markers, "<line x2='9' marker-end=\"\(value)\"/>")).instances
        }
        XCTAssertEqual(count("url(#a)"), 2)
        XCTAssertEqual(count("url(#b)"), 6)
        XCTAssertEqual(count("  url(#a)"), 2, "white space before it")
        XCTAssertEqual(count("url('#a')"), 2, "quoted")
        XCTAssertEqual(count("url(&quot;#a&quot;)"), 2, "as a browser serializes a style")
        for value in ["url( '#a' )", "url('#a)", "url('#a&quot;)", "url(' #a')", "url( #a )", "url(#a&#9;)", "url(#a", "/**/url(#a)", "url('#a)b')",
                      "url('#a&#160;')"] {
            XCTAssertEqual(count(value), 6, "\(value) is charged the largest")
        }
        XCTAssertEqual(count("url(#a&#160;)"), 0, "unquoted, a no-break space is part of the id, and no marker has it")
        for value in ["none", "inherit", "url(#nothing)", "url(other.svg#a)", "url(data:x)", "a", ""] {
            XCTAssertEqual(count(value), 0, "\(value) names no marker")
        }
        // An id two markers share is charged the larger, and an id in another namespace is an id.
        XCTAssertEqual(verdict(svg(marker("d") + marker("d", rects: 4), "<line x2='9' marker-end='url(#d)'/>")).instances, 5)
        XCTAssertEqual(verdict(svg(marker("d", rects: 4) + marker("d"), "<line x2='9' marker-end='url(#d)'/>")).instances, 5)
        XCTAssertEqual(verdict(svg("<marker xml:id='x'><rect width='1' height='1'/><rect width='1' height='1'/></marker>", "<line x2='9' marker-end='url(#x)'/>")).instances, 3)
        XCTAssertEqual(verdict(svg("<marker id='箭头'><rect width='1' height='1'/></marker>", "<line x2='9' marker-end='url(#箭头)'/>")).instances, 2)
    }

    // MARK: Rule 3: a marker's content bears no marker

    /// The renderer resolves a marker property for a marker's content from the content, the
    /// `<marker>` and every element the marker stands in, and instantiates what it finds at every
    /// vertex of every instance. No such element may name a marker, so nothing is nested.
    func testAMarkerThatCouldBearAMarkerIsRefused() throws {
        let inner = "<path d='M0 0h1h1'/>"
        let host = "<path d='M0 0h1h1' marker-mid='url(#out)'/>"
        func nested(_ outer: String) -> SVGContent.MarkerVerdict { verdict(svg(marker(rects: 2) + outer, host)) }
        XCTAssertTrue(nested("<marker id='out'>\(inner)</marker>").withinLimits, "a marker of a plain path")
        XCTAssertEqual(nested("<marker id='out'>\(inner)</marker>").instances, 5, "four vertices of one, and one")
        for outer in ["<marker id='out' marker-mid='url(#m)'>\(inner)</marker>",
                      "<marker id='out' style='marker:url(#m)'>\(inner)</marker>",
                      "<marker id='out' xlink:marker-mid='url(#m)'>\(inner)</marker>",
                      "<g marker-mid='url(#m)'><marker id='out'>\(inner)</marker></g>",
                      "<g style='marker-end : url( #m )'><g><marker id='out'>\(inner)</marker></g></g>",
                      "<marker id='out'><path d='M0 0h1h1' marker-mid='url(#m)'/></marker>",
                      "<marker id='out'><g style='marker-mid:url(#m)'>\(inner)</g></marker>",
                      "<marker id='out' marker-mid='url(#out)'>\(inner)</marker>"] {
            XCTAssertFalse(nested(outer).withinLimits, outer)
            XCTAssertFalse(isWithinLimits(svg(marker(rects: 2) + outer, host)), outer)
        }
        XCTAssertFalse(verdict(svg(marker(rects: 2) + "<marker id='out'>\(inner)</marker>", host, root: "width='9' height='9' marker-end='url(#m)'")).withinLimits,
                       "named on the root, which every marker stands in")

        // What names no marker is no bar: Inkscape writes `marker-start:none` in its own markers.
        for outer in ["<marker id='out'><path d='M0 0h1h1' style='fill-rule:evenodd;marker-start:none;marker-end:none'/></marker>",
                      "<marker id='out' marker-mid='none'>\(inner)</marker>",
                      "<g marker-mid='url(#nothing)'><marker id='out'>\(inner)</marker></g>"] {
            XCTAssertTrue(nested(outer).withinLimits, outer)
        }
        XCTAssertTrue(renders(svg(marker(rects: 2) + "<marker id='out'><path d='M0 0h1h1' style='marker-start:none'/></marker>", host)))

        // Nor may they name a paint server: the content would inherit it, and the renderer copies
        // a gradient's stops for every shape painted with it.
        let gradient = "<linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>"
        XCTAssertFalse(nested(gradient + "<g fill='url(#g)'><marker id='out'>\(inner)</marker></g>").withinLimits)
        XCTAssertFalse(nested(gradient + "<marker id='out' style='stroke:url(#g)'>\(inner)</marker>").withinLimits)
        XCTAssertTrue(nested(gradient + "<g fill='red' stroke='#00f'><marker id='out'>\(inner)</marker></g>").withinLimits)
    }

    // MARK: Rule 4: what a marker holds

    /// A `<marker>` holds shapes, groups of them and descriptions, and nothing that reaches outside
    /// it: each of those is something the renderer would instantiate, or convert, per instance.
    func testAMarkerHoldsOnlyPlainShapes() throws {
        let extras = "<g id='r'><rect width='1' height='1'/></g><linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>"
            + "<clipPath id='c'><rect width='1' height='1'/></clipPath><mask id='k'><rect width='1' height='1'/></mask>"
        func holding(_ content: String) -> SVGContent.MarkerVerdict {
            verdict(svg(extras + "<marker id='m'>\(content)</marker>", "<line x2='9' marker-end='url(#m)'/>"))
        }
        let plain = holding("<title>Arrow</title><desc>An arrowhead</desc><g><path d='M0 0L4 2L0 4z'/><circle cx='2' cy='2' r='2'/><ellipse rx='1' ry='2'/>"
            + "<line x2='4'/><polyline points='0,0 4,2'/><polygon points='0,0 4,2 0,4'/><rect width='4' height='4'/></g>")
        XCTAssertTrue(plain.withinLimits)
        XCTAssertEqual(plain.instances, 11, "ten elements, and one")

        for content in ["<use xlink:href='#r'/>", "<image width='1' height='1' xlink:href='data:image/png;base64,AAAA'/>", "<text>a</text>",
                        "<svg><rect width='1' height='1'/></svg>", "<symbol><rect width='1' height='1'/></symbol>", "<switch><rect width='1' height='1'/></switch>",
                        "<a><rect width='1' height='1'/></a>", "<mask><rect width='1' height='1'/></mask>", "<clipPath><rect width='1' height='1'/></clipPath>",
                        "<marker><rect width='1' height='1'/></marker>", "<style>rect{fill:red}</style>", "<g><g><use xlink:href='#r'/></g></g>",
                        "<desc><b>bold</b></desc>", "<unknown/>"] {
            XCTAssertFalse(holding(content).withinLimits, content)
        }
        for attributes in ["fill='url(#g)'", "stroke='url(#g)'", "style='fill:url(#g)'", "clip-path='url(#c)'", "mask='url(#k)'",
                           "style='mask : URL( \"#k\" )'", "xlink:fill='url(#g)'", "xlink:href='#r'", "href='#r'", "xlink:filter='blur(1)'",
                           "style='fill:red !importantfilter:blur(1)'"] {
            XCTAssertFalse(holding("<rect width='1' height='1' \(attributes)/>").withinLimits, attributes)
            XCTAssertFalse(holding("<g \(attributes)><rect width='1' height='1'/></g>").withinLimits, "on a group: \(attributes)")
        }
        for attributes in ["fill='red'", "fill='context-stroke' stroke='currentColor'", "style='fill:#f00;stroke-width:1'", "opacity='0.5'"] {
            XCTAssertTrue(holding("<rect width='1' height='1' \(attributes)/>").withinLimits, attributes)
        }
    }

    /// A marker's size is what one instance costs the renderer, which converts the marker's content
    /// afresh for each: one for each element in it, and one more for every 32 vertices of a shape
    /// and every 64 bytes of the attributes an element has or inherits.
    func testAMarkerCountsItsElementsVerticesAndAttributeBytes() throws {
        // On a line with `marker-end`, the count is the marker's size and one.
        func size(_ defs: String, root: String = "width='200' height='50'", sheet: String = "") -> Int {
            verdict(svg(defs, sheet + "<line x2='9' marker-end='url(#m)'/>", root: root)).instances - 1
        }
        func pad(_ bytes: Int) -> String { "data-pad='" + String(repeating: "x", count: bytes) + "'" }
        XCTAssertEqual(size(marker(rects: 7)), 7)
        XCTAssertEqual(size("<marker id='m'/>"), 1, "an empty marker still costs an instance")
        XCTAssertEqual(size("<marker id='m'><g><g><rect width='1' height='1'/></g></g></marker>"), 3, "groups count")

        // The root (16 bytes), the marker (3) and the rectangle (13) leave 32 before the next 64.
        XCTAssertEqual(size("<marker id='m'><rect width='1' height='1' \(pad(23))/></marker>"), 1, "63 bytes")
        XCTAssertEqual(size("<marker id='m'><rect width='1' height='1' \(pad(24))/></marker>"), 2, "64 bytes")
        XCTAssertEqual(size("<marker id='m'><rect width='1' height='1' \(pad(6_400 - 40))/></marker>"), 101)
        XCTAssertEqual(size("<marker id='m'><g \(pad(24))><rect width='1' height='1'/><rect width='1' height='1'/></g></marker>"), 5,
                       "a group's attributes are read again for each shape that inherits them: 1 for the group, 2 for each rectangle")
        XCTAssertEqual(size("<g \(pad(24))><marker id='m'><rect width='1' height='1'/></marker></g>"), 2, "and so are those of what the marker stands in")
        XCTAssertEqual(size("<marker id='m' \(pad(53))><rect width='1' height='1'/></marker>"), 3, "the marker's own count for it and for its content")
        XCTAssertEqual(size(marker(rects: 2), root: "width='200' height='50' \(pad(24))"), 4)

        // A circle of great radius is flattened into many segments: one more for every 32.
        XCTAssertEqual(size("<marker id='m'><circle r='5'/></marker>"), 1, "12 segments at most")
        XCTAssertEqual(size("<marker id='m'><circle r='1e12'/></marker>"), 5, "158 segments at most")
        // Path data is counted by its bytes: 64 bytes of it hold at most 32 numbers.
        XCTAssertEqual(size("<marker id='m'><path d='M0 0\(String(repeating: "h1", count: 3_200))'/></marker>"), 201,
                       "6,405 bytes of attribute, with the 19 above it: 100; 3,202 numbers: 100")

        // A stylesheet's dash array may reach every element, so each counts its bytes.
        let sheet = "<style>line{stroke-dasharray:\(String(repeating: "1 ", count: 60))}</style>"
        XCTAssertEqual(size(marker(rects: 2), sheet: sheet), 2 * 3 + 2, "137 bytes: two more for each rectangle, and two for the line that bears the marker")
    }

    // MARK: Rule 5: masks and clip paths

    /// The renderer draws a mask's content, markers and all, again for every element that uses the
    /// mask. A shape in a mask that bears a marker is refused, however it comes to be there.
    func testAMarkerBearingShapeInAMaskIsRefused() throws {
        let shape = "<path d='M0 0h1h1' marker-mid='url(#m)'/>"
        let masked = "<rect width='9' height='9' mask='url(#k)'/>"
        for definitions in ["<mask id='k'>\(shape)</mask>",
                            "<mask id='k'><g><g>\(shape)</g></g></mask>",
                            "<g id='p'>\(shape)</g><mask id='k'><use xlink:href='#p'/></mask>",
                            "<g marker-end='url(#m)'><mask id='k'><path d='M0 0h1h1'/></mask></g>",
                            "<mask id='k' style='marker:url(#m)'><path d='M0 0h1h1'/></mask>",
                            "<mask id='k'><path d='M0 0h1h1' xlink:marker-mid='url(#m)'/></mask>",
                            "<path id='p' d='M0 0h1h1'/><mask id='k'><g marker-start='url(#m)'><use xlink:href='#p'/></g></mask>"] {
            XCTAssertFalse(verdict(svg(marker(rects: 2) + definitions, masked)).withinLimits, definitions)
            XCTAssertFalse(renders(svg(marker(rects: 2) + definitions, masked)), definitions)
        }
        XCTAssertFalse(verdict(svg(marker(rects: 2), "<mask id='k'>\(shape)</mask>")).withinLimits, "whether or not anything uses the mask")

        // A mask with no such shape is as it was, and so is a marker on the element that is masked.
        let plain = "<mask id='k'><rect width='9' height='9' fill='white'/></mask>"
        XCTAssertTrue(renders(svg(marker(rects: 2) + plain, masked + path(vertices: 10, "marker-mid='url(#m)' stroke='black'"))))
        let onMasked = verdict(svg(marker(rects: 2) + plain, "<g marker-end='url(#m)'><path d='M0 0h9h9' mask='url(#k)' stroke='black'/></g>"))
        XCTAssertTrue(onMasked.withinLimits, "the mask's content does not inherit from the element that uses it")
        XCTAssertEqual(onMasked.instances, 3)
    }

    /// The renderer draws no marker on a shape inside a `<clipPath>`, reached directly or through
    /// `<use>`, so a clip path is no bar and counts nothing. The same shape used from outside the
    /// clip path is drawn with its markers, and counted.
    func testAClipPathDrawsNoMarkers() throws {
        let clipped = "<rect width='200' height='50' clip-path='url(#c)'/>"
        let big = marker(rects: 400)
        let shape = path(vertices: 800, "marker-mid='url(#m)'")
        for definitions in ["<clipPath id='c'>\(shape)</clipPath>",
                            "<clipPath id='c'><use xlink:href='#p'/></clipPath>" + shape.replacingOccurrences(of: "<path ", with: "<path id='p' "),
                            "<clipPath id='c' marker-mid='url(#m)'>\(path(vertices: 800))</clipPath>"] {
            let result = verdict(svg(big + definitions, clipped))
            XCTAssertTrue(result.withinLimits, definitions)
            XCTAssertEqual(result.instances, 0, definitions)
        }
        XCTAssertTrue(renders(svg(marker(rects: 4) + "<clipPath id='c'>\(path(vertices: 8, "marker-mid='url(#m)'"))</clipPath>", clipped)))
        let usedOutside = svg(big + "<clipPath id='c'>\(shape.replacingOccurrences(of: "<path ", with: "<path id='p' "))</clipPath>", clipped + "<use xlink:href='#p'/>")
        XCTAssertFalse(verdict(usedOutside).withinLimits, "used from outside, the shape is drawn with its 320,000 instances")
    }

    // MARK: Rule 6: vertices

    /// A `marker-mid` is drawn at every vertex, so the count needs an upper bound on them. Path
    /// data and points give at most one for each number, and one more for each close.
    func testVerticesAreCountedFromPathDataAndPoints() throws {
        func count(_ shape: String) -> Int { verdict(svg(marker(), shape)).instances - 1 }
        XCTAssertEqual(count("<path d='M0 0L1 1L2 2' marker-mid='url(#m)'/>"), 6)
        XCTAssertEqual(count("<path d='M0,0C1,1,2,2,3,3S5,5,6,6' marker-mid='url(#m)'/>"), 12)
        XCTAssertEqual(count("<path d='M0 0zh1zh1' marker-mid='url(#m)'/>"), 6, "after a close the renderer starts a subpath: a vertex with no number")
        XCTAssertEqual(count("<path d='M-1.5-2.5l.5.5.5.5' marker-mid='url(#m)'/>"), 6, "a run of digits and dots holds as many numbers as it has dots")
        XCTAssertEqual(count("<polyline points='1e1.1 1e1.1' marker-mid='url(#m)'/>"), 4, "an exponent ends at a dot")
        XCTAssertEqual(count("<polyline points='0,0 1,1 2,2 3,3' marker-mid='url(#m)'/>"), 8)
        XCTAssertEqual(count("<polygon points='0,0 1,1 2,2' marker-mid='url(#m)'/>"), 6)
        XCTAssertEqual(count("<line x1='0' y1='0' x2='9' y2='9' marker-mid='url(#m)'/>"), 2)
        XCTAssertEqual(count("<rect width='9' height='9' marker-mid='url(#m)'/>"), 5)
        // The renderer reads geometry in the XLink and XML namespaces too.
        XCTAssertEqual(count("<path xlink:d='M0 0L1 1L2 2' marker-mid='url(#m)'/>"), 6)
        XCTAssertEqual(count("<path xml:d='M0 0L1 1' d='M0 0' marker-mid='url(#m)'/>"), 6, "every attribute of the name is counted")
        XCTAssertEqual(count("<polyline xlink:points='0,0 1,1' marker-mid='url(#m)'/>"), 4)
    }

    /// A `circle`, an `ellipse` and a rounded `rect` are flattened into segments whose number
    /// grows with the radius, and a path's elliptical arc into a number its text does not bound.
    func testCurvedGeometryIsBoundedByItsRadiusOrRefused() throws {
        func result(_ shape: String) -> SVGContent.MarkerVerdict { verdict(svg(marker(), shape)) }
        XCTAssertEqual(result("<circle cx='10' cy='10' r='6' marker-mid='url(#m)'/>").instances, 13, "12 segments at most, and one")
        XCTAssertEqual(result("<ellipse rx='3' ry='1e12' marker-mid='url(#m)'/>").instances, 159, "by the greater radius")
        XCTAssertEqual(result("<rect width='9' height='9' rx='2' marker-mid='url(#m)'/>").instances, 18)
        XCTAssertEqual(result("<circle xlink:r='1e12' r='1' marker-mid='url(#m)'/>").instances, 159, "in any namespace")
        XCTAssertTrue(renders(svg(marker(), "<circle cx='10' cy='10' r='6' marker-mid='url(#m)' stroke='black'/>")))
        for shape in ["<circle r='1e40' marker-mid='url(#m)'/>", "<circle r='6px' marker-mid='url(#m)'/>", "<ellipse rx='50%' ry='2' marker-mid='url(#m)'/>",
                      "<rect width='9' height='9' ry='1em' marker-mid='url(#m)'/>", "<circle xlink:r='1e40' r='1' marker-mid='url(#m)'/>",
                      "<path d='M0 0a5 5 0 0 1 9 0' marker-mid='url(#m)'/>", "<path d='M0 0A5 5 0 0 1 9 0' style='marker:url(#m)'/>"] {
            XCTAssertFalse(result(shape).withinLimits, shape)
        }
        // A start or an end marker is drawn once whatever the geometry.
        for shape in ["<path d='M0 0a5 5 0 0 1 9 0' marker-end='url(#m)'/>", "<circle r='6px' marker-start='url(#m)'/>", "<circle r='1e40' marker-end='url(#m)'/>"] {
            XCTAssertTrue(result(shape).withinLimits, shape)
            XCTAssertEqual(result(shape).instances, 2, shape)
        }
        XCTAssertTrue(renders(svg(marker(), "<path d='M5 25a20 20 0 0 1 40 0' fill='none' stroke='black' marker-end='url(#m)'/>")))

        // Inside a marker the same holds for what each instance stores.
        func holding(_ content: String) -> SVGContent.MarkerVerdict { verdict(svg("<marker id='m'>\(content)</marker>", "<line x2='9' marker-end='url(#m)'/>")) }
        XCTAssertTrue(holding("<circle cx='5' cy='5' r='5'/>").withinLimits)
        for content in ["<path d='M0 0a1e30 1e30 0 1 1 1 0'/>", "<circle r='1e40'/>", "<circle r='2mm'/>", "<rect width='1' height='1' rx='10%'/>"] {
            XCTAssertFalse(holding(content).withinLimits, content)
        }
    }

    // MARK: What a marker costs on the shape that bears it

    /// The renderer copies the shape's dash array for every marker instance it draws on it, so 64
    /// bytes of dash array count one more for each.
    func testADashArrayOnTheShapeIsCountedForEachInstance() throws {
        let dash = String(repeating: "1 ", count: 32) // 64 bytes
        func count(_ body: String) -> Int { verdict(svg(marker(), body)).instances }
        XCTAssertEqual(count(path(vertices: 10, "marker-mid='url(#m)' stroke-dasharray='4 2'")), 11, "an ordinary dash array adds nothing")
        XCTAssertEqual(count(path(vertices: 10, "marker-mid='url(#m)' stroke-dasharray='\(dash)'")), 21)
        XCTAssertEqual(count(path(vertices: 10, "marker-mid='url(#m)' style='stroke:red;stroke-dasharray:\(dash);fill:none'")), 21)
        XCTAssertEqual(count("<g stroke-dasharray='\(dash)\(dash)'>\(path(vertices: 10, "marker-mid='url(#m)'"))</g>"), 31, "inherited")
        XCTAssertEqual(count(path(vertices: 10, "marker-end='url(#m)' xlink:stroke-dasharray='\(dash)'")), 3)
        XCTAssertEqual(count(path(vertices: 10, "stroke-dasharray='\(dash)'")), 0, "with no marker there is nothing to count")
    }

    /// A marker painted with `context-fill` or `context-stroke` takes the paint of the shape it is
    /// drawn on, and the renderer copies a paint server's stops for every such instance. With such
    /// a marker in the SVG, a shape painted by a paint server bears no marker.
    func testAContextPaintedMarkerOnAPaintServerShapeIsRefused() throws {
        let gradient = "<linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>"
        let context = "<marker id='m'><path d='M0 0L4 2L0 4z' style='fill:context-stroke'/></marker>"
        func result(_ markerDefinition: String, _ body: String) -> SVGContent.MarkerVerdict { verdict(svg(gradient + markerDefinition, body)) }
        XCTAssertTrue(result(context, "<path d='M0 0h9' stroke='black' marker-end='url(#m)'/>").withinLimits, "Inkscape's own arrowheads, on a plain stroke")
        XCTAssertTrue(renders(svg(gradient + context, "<path d='M0 5h9' stroke='black' marker-end='url(#m)'/>")))
        for body in ["<path d='M0 0h9' stroke='url(#g)' marker-end='url(#m)'/>",
                     "<path d='M0 0h9' style='fill:url(#g)' marker-end='url(#m)'/>",
                     "<g stroke=' url(#g) red'><path d='M0 0h9' marker-end='url(#m)'/></g>",
                     "<path d='M0 0h9' style='fill:none !importantstroke:url(#g)' marker-end='url(#m)'/>"] {
            XCTAssertFalse(result(context, body).withinLimits, body)
        }
        // A marker with its own paint is no such cost, and a shape with no marker is as it was.
        XCTAssertTrue(result(marker(), "<path d='M0 0h9' stroke='url(#g)' marker-end='url(#m)'/>").withinLimits)
        XCTAssertTrue(result(context, "<rect width='9' height='9' fill='url(#g)'/><path d='M0 0h9' stroke='black' marker-end='url(#m)'/>").withinLimits)
    }

    // MARK: What real tools emit

    /// Arrowheads and data-point markers as Inkscape, Mermaid, D3, OmniGraffle and the MDN reference
    /// write them: every one is within limits by a wide margin, and renders.
    func testMarkersAsRealToolsWriteThemRender() throws {
        for (name, drawing, most) in [("Inkscape 0.92", Self.inkscape092, 200), ("Inkscape 1.x", Self.inkscape1, 200),
                                      ("Mermaid flowchart", Self.mermaidFlowchart, 200), ("Mermaid sequence diagram", Self.mermaidSequence, 50),
                                      ("D3 force layout", Self.d3Force, 50), ("MDN reference", Self.mdnReference, 100),
                                      ("OmniGraffle", Self.omniGraffle, 50)] {
            let result = verdict(drawing)
            XCTAssertTrue(result.withinLimits, name)
            XCTAssertGreaterThan(result.instances, 0, "\(name): its markers are counted")
            XCTAssertLessThan(result.instances, most, name)
            XCTAssertTrue(isWithinLimits(drawing), name)
            XCTAssertTrue(renders(drawing), name)
        }
    }

    /// A line chart with a marker at every data point: three series of 1,000 points, as a polyline
    /// and as a path, with a circle, a square and a triangle.
    func testALineChartWithAMarkerAtEveryPointRenders() throws {
        func points(_ series: Int) -> [(Int, Int)] { (0..<1_000).map { ($0 * 2, 100 + series * 60 + ($0 * 37 + series * 11) % 50) } }
        let dots = "<marker id='p0' viewBox='0 0 6 6' refX='3' refY='3' markerWidth='4' markerHeight='4'><circle cx='3' cy='3' r='2.5' fill='steelblue' stroke='white' stroke-width='0.5'/></marker>"
            + "<marker id='p1' viewBox='0 0 6 6' refX='3' refY='3' markerWidth='4' markerHeight='4'><rect x='0.5' y='0.5' width='5' height='5' fill='tomato'/></marker>"
            + "<marker id='p2' viewBox='0 0 6 6' refX='3' refY='3' markerWidth='4' markerHeight='4'><path d='M3,0 L6,6 L0,6 Z' fill='seagreen'/></marker>"
        let polyline = "<polyline points='\(points(0).map { "\($0.0),\($0.1)" }.joined(separator: " "))' fill='none' stroke='steelblue' marker-start='url(#p0)' marker-mid='url(#p0)' marker-end='url(#p0)'/>"
        let path = "<path d='M\(points(1).map { "\($0.0),\($0.1)" }.joined(separator: "L"))' fill='none' stroke='tomato' marker-start='url(#p1)' marker-mid='url(#p1)' marker-end='url(#p1)'/>"
        let third = "<polyline points='\(points(2).map { "\($0.0),\($0.1)" }.joined(separator: " "))' fill='none' stroke='seagreen' style='marker:url(#p2)'/>"
        let chart = "<svg \(Self.ns) viewBox='0 0 2000 320' width='800' height='128'><defs>\(dots)</defs>\(polyline)\(path)\(third)</svg>"
        let result = verdict(chart)
        XCTAssertTrue(result.withinLimits)
        // Each point counts twice, as two numbers. The circle, with 138 bytes of attributes on it, its marker
        // and the root, has a size of three; the square and the triangle, with under 128, of two.
        XCTAssertEqual(result.instances, (2_000 * 3 + 1 + 4 + 4) + 2 * (2_000 * 2 + 1 + 3 + 3))
        XCTAssertTrue(renders(chart))
    }

    // MARK: The reproducers of three reviews

    /// Each way a review found to make the renderer instantiate more than was counted, or to make
    /// the count itself slow, reduced: a 400-rectangle marker at 800 vertices where the count is
    /// what refuses, and a few shapes where a rule does. The check alone is run.
    func testEveryReproducerOfTheReviewsIsRefused() throws {
        let big = marker("big", rects: 400), tiny = marker("tiny")
        let long = "M0 0" + String(repeating: " L1 1", count: 399)
        func host(_ attributes: String) -> String { "<path d='\(long)' \(attributes)/>" }
        let inner = marker("in", rects: 100)
        let reproducers: [(String, String)] = [
            // Round 1
            ("use multiplies a marker-bearing shape", svg(marker(rects: 100) + "<g id='g'>\(host("marker-mid='url(#m)'"))</g>", String(repeating: "<use xlink:href='#g'/>", count: 50))),
            ("a tab before the colon", svg(big, host("style='marker-mid&#9;:url(#big)'"))),
            ("a newline before the colon, in a stylesheet", svg(big, "<style>path{marker-mid\n:url(#big)}</style>" + host(""))),
            ("a comment before the colon", svg(big, host("style='marker-mid/* c */:url(#big)'"))),
            ("the shorthand", svg(big, host("style='marker:url(#big)'"))),
            ("a nested marker", svg(inner + "<marker id='out'><path d='\(long)' marker-mid='url(#in)'/></marker>", host("marker-mid='url(#out)'"))),
            // Round 2
            ("a marker-bearing shape in a mask", svg(big + "<mask id='k'>\(host("marker-mid='url(#big)'"))</mask>", "<rect width='9' height='9' mask='url(#k)'/>")),
            ("reached through use in a mask", svg(big + "<g id='g'>\(host("marker-mid='url(#big)'"))</g><mask id='k'><use xlink:href='#g'/></mask>", "<rect width='9' height='9' mask='url(#k)'/>")),
            ("a symbol", svg(big + "<symbol id='s'>\(host("marker-mid='url(#big)'"))</symbol>", "<use xlink:href='#s'/>")),
            ("a nested svg", svg(big, "<svg>\(host("marker-mid='url(#big)'"))</svg>")),
            ("inherited at the use", svg(big + "<g id='g'>\(host(""))</g>", "<g marker-mid='url(#big)'><use xlink:href='#g'/></g>")),
            ("a use inside a marker", svg("<g id='g'>" + String(repeating: "<rect width='1' height='1'/>", count: 400) + "</g><marker id='m'><use xlink:href='#g'/></marker>", host("marker-mid='url(#m)'"))),
            ("a chain of markers that closes on itself", svg((0..<18).map { "<marker id='c\($0)'><path d='' marker-mid='url(#c\(($0 + 1) % 18))'/><path d='' marker-mid='url(#c\(($0 + 1) % 18))'/></marker>" }.joined(), "<path d='M0 0 L1 1' marker-mid='url(#c0)'/>")),
            ("a stylesheet rule for a class", svg(marker("arr", rects: 3), "<style>.edge{marker-end:url(#arr)}</style><path class='edge' d='M0 0h9'/>")),
            // Round 3
            ("a marker property on the marker", svg(inner + "<marker id='out' marker-mid='url(#in)'><path d='\(long)'/></marker>", host("marker-mid='url(#out)'"))),
            ("on an ancestor of the marker", svg(inner + "<g marker-mid='url(#in)'><marker id='out'><path d='\(long)'/></marker></g>", host("marker-mid='url(#out)'"))),
            ("three levels of markers", svg(marker("a") + "<marker id='b' marker-mid='url(#a)'><path d='\(long)'/></marker><marker id='c' marker-mid='url(#b)'><path d='\(long)'/></marker>", host("marker-mid='url(#c)'"))),
            ("a rule of 2,000 selectors", svg(big, "<style>" + (0..<2_000).map { ".c\($0)" }.joined(separator: ",") + "{marker-mid:url(#big)}</style>" + host("class='c7'"))),
            ("a marker attribute that overrides nothing", svg(big + tiny, "<g marker-mid='url(#big)'>\(host("marker='url(#tiny)'"))</g>")),
            ("a rule that matches nothing", svg(big + tiny, "<style>path:hover{marker-mid:url(#tiny)}</style><g marker-mid='url(#big)'>\(host(""))</g>")),
            ("an upper-case style property", svg(big + tiny, "<g marker-mid='url(#big)'>\(host("style='MARKER-MID:url(#tiny)'"))</g>")),
            ("a stylesheet type in another case", svg(big + tiny, "<style type='text/CSS'>path{marker-mid:url(#tiny)}</style><g marker-mid='url(#big)'>\(host(""))</g>")),
            ("an attribute selector", svg(big + tiny, "<style>path[nope]{marker-mid:url(#tiny)}</style><g marker-mid='url(#big)'>\(host(""))</g>")),
            ("an at-rule before the rule", svg(big, "<style>@charset \"utf-8\"; path{marker-mid:url(#big)}</style>" + host(""))),
            ("a comment opened in a string", svg(big, host("style='x:\"/*\";marker-mid:url(#big);y:\"*/\"'"))),
            ("a class in the XLink namespace", svg(big, "<style>.hot{marker-mid:url(#big)}</style>" + host("xlink:class='hot'"))),
            ("an id in the XLink namespace", svg(big, "<style>#hot{marker-mid:url(#big)}</style>" + host("xlink:id='hot'"))),
            ("a carriage return in the reference", svg(big, host("marker-mid='url(#big&#13;)'"))),
            ("a quote in the id", svg(big.replacingOccurrences(of: "id='big'", with: "id='a&quot;b'"), host("marker-mid='url(#a&quot;b)'"))),
            ("a newline in the id", svg(big.replacingOccurrences(of: "id='big'", with: "id='a&#10;b'"), host("marker-mid='url(#a&#10;b)'"))),
            ("a close before each vertex", svg(marker(rects: 100), "<path d='M0 0\(String(repeating: "zh1", count: 500))' marker-mid='url(#m)'/>")),
            ("an image in a marker", svg("<marker id='m'><image width='2' height='2' xlink:href='data:image/png;base64,AAAA'/></marker>", host("marker-mid='url(#m)'"))),
            ("a mask named in a marker", svg("<mask id='k'>\(String(repeating: "<rect width='1' height='1'/>", count: 400))</mask><marker id='m'><rect width='1' height='1' mask='url(#k)'/></marker>", host("marker-mid='url(#m)'"))),
            ("a clip path named in a marker", svg("<clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath><marker id='m'><rect width='1' height='1' clip-path='url(#c)'/></marker>", host("marker-mid='url(#m)'"))),
            ("a gradient named in a marker", svg("<linearGradient id='g'><stop/><stop offset='1'/></linearGradient><marker id='m'><rect width='1' height='1' fill='url(#g)'/></marker>", host("marker-mid='url(#m)'"))),
            ("text in a marker", svg("<marker id='m'><text>lorem ipsum</text></marker>", host("marker-mid='url(#m)'"))),
            ("an arc of great radius in a marker", svg("<marker id='m'><path d='M0 0a1e30 1e30 0 1 1 1 0'/></marker>", "<path d='M0 0h1h1' marker-mid='url(#m)'/>")),
            ("a dual href that hides the target", svg(marker(rects: 100) + "<g id='g'>\(host("marker-mid='url(#m)'"))</g><g id='e'/>", String(repeating: "<use href='#g' xlink:href='#e'/>", count: 2))),
            ("a tref to a group", "<svg \(Self.ns)><defs><g id='t'>lorem</g></defs><text><tref xlink:href='#t'/></text></svg>"),
            ("a tref through use", "<svg \(Self.ns)><defs><g id='t'>lorem</g><text id='u'><tref xlink:href='#t'/></text></defs><use xlink:href='#u'/></svg>"),
        ]
        for (name, drawing) in reproducers {
            XCTAssertFalse(isWithinLimits(drawing), name)
            XCTAssertLessThan(verdict(drawing).steps, 1_000, "\(name): refused without a long walk")
        }
        // The walk a stylesheet of many selectors took is gone: a stylesheet is read once.
        XCTAssertEqual(verdict(reproducers[17].1).steps, 0)

        // Neighbours the reviews confirmed harmless stay within limits.
        XCTAssertTrue(isWithinLimits(svg(big + "<clipPath id='c'>\(host("marker-mid='url(#big)'"))</clipPath>", "<rect width='9' height='9' clip-path='url(#c)'/>")), "markers in a clip path are not drawn")
        XCTAssertTrue(isWithinLimits(svg(marker(), "<path d='M0 0\(String(repeating: "a1e30 1e30 0 1 1 1 0", count: 20))' marker-end='url(#m)'/>")), "an end marker on an arc")
        XCTAssertTrue(isWithinLimits(svg(marker("arr", rects: 3), String(repeating: "<path class='edge' d='M0 0 C10 10 20 0 30 10' marker-end='url(#arr)'/>", count: 300))), "300 connectors with an arrowhead each")
    }

    // MARK: Fixtures

    private static let inkscape092 = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <svg xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:cc="http://creativecommons.org/ns#" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:svg="http://www.w3.org/2000/svg" xmlns="http://www.w3.org/2000/svg" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="210mm" height="148mm" viewBox="0 0 210 148" version="1.1" id="svg8" inkscape:version="0.92.4 (5da689c313, 2019-01-14)" sodipodi:docname="arrows.svg">
      <defs id="defs2">
        <marker inkscape:stockid="Arrow2Lend" orient="auto" refY="0.0" refX="0.0" id="Arrow2Lend" style="overflow:visible;" inkscape:isstock="true">
          <path id="path4537" style="fill-rule:evenodd;stroke-width:0.625;stroke-linejoin:round;stroke:#000000;stroke-opacity:1;fill:#000000;fill-opacity:1" d="M 8.7185878,4.0337352 L -2.2072895,0.016013256 L 8.7185884,-4.0017078 C 6.9730900,-1.6296469 6.9831476,1.6157441 8.7185878,4.0337352 z " transform="scale(1.1) rotate(180) translate(1,0)" />
        </marker>
        <marker inkscape:stockid="Arrow1Lstart" orient="auto" refY="0.0" refX="0.0" id="Arrow1Lstart" style="overflow:visible" inkscape:isstock="true">
          <path id="path4516" d="M 0.0,0.0 L 5.0,-5.0 L -12.5,0.0 L 5.0,5.0 L 0.0,0.0 z " style="fill-rule:evenodd;stroke:#000000;stroke-width:1pt;stroke-opacity:1;fill:#000000;fill-opacity:1" transform="scale(0.8) translate(12.5,0)" />
        </marker>
        <marker inkscape:stockid="TriangleOutL" orient="auto" refY="0.0" refX="0.0" id="TriangleOutL" style="overflow:visible" inkscape:isstock="true">
          <path id="path4649" d="M 5.77,0.0 L -2.88,5.0 L -2.88,-5.0 L 5.77,0.0 z " style="fill-rule:evenodd;stroke:#000000;stroke-width:1pt;stroke-opacity:1;fill:#000000;fill-opacity:1;marker-start:none" transform="scale(0.8)" />
        </marker>
        <marker inkscape:stockid="DotM" orient="auto" refY="0.0" refX="0.0" id="DotM" style="overflow:visible" inkscape:isstock="true">
          <path id="path4585" d="M -2.5,-1.0 C -2.5,1.7600000 -4.7400000,4.0 -7.5,4.0 C -10.260000,4.0 -12.5,1.7600000 -12.5,-1.0 C -12.5,-3.7600000 -10.260000,-6.0 -7.5,-6.0 C -4.7400000,-6.0 -2.5,-3.7600000 -2.5,-1.0 z " style="fill-rule:evenodd;stroke:#000000;stroke-width:1pt;stroke-opacity:1;fill:#000000;fill-opacity:1;marker-start:none;marker-end:none" transform="scale(0.4) translate(7.4, 1)" />
        </marker>
        <linearGradient id="linearGradient900" inkscape:collect="always"><stop style="stop-color:#ff0000;stop-opacity:1" offset="0" id="stop896" /><stop style="stop-color:#0000ff;stop-opacity:1" offset="1" id="stop898" /></linearGradient>
      </defs>
      <sodipodi:namedview id="base" pagecolor="#ffffff" bordercolor="#666666" inkscape:document-units="mm" inkscape:current-layer="layer1" showgrid="false" />
      <metadata id="metadata5"><rdf:RDF><cc:Work rdf:about=""><dc:format>image/svg+xml</dc:format><dc:type rdf:resource="http://purl.org/dc/dcmitype/StillImage" /></cc:Work></rdf:RDF></metadata>
      <g inkscape:label="Layer 1" inkscape:groupmode="layer" id="layer1" style="display:inline">
        <rect style="opacity:1;fill:url(#linearGradient900);fill-opacity:1;stroke:#000000;stroke-width:0.5;marker:none" id="rect10" width="50" height="30" x="20" y="20" ry="3" />
        <rect style="opacity:1;fill:#ffcc00;fill-opacity:1;stroke:#000000;stroke-width:0.5;stroke-miterlimit:4;stroke-dasharray:none;stroke-opacity:1;marker:none" id="rect12" width="50" height="30" x="130" y="80" />
        <path style="fill:none;stroke:#000000;stroke-width:0.26458332px;stroke-linecap:butt;stroke-linejoin:miter;stroke-opacity:1;marker-end:url(#Arrow2Lend)" d="M 70,35 C 100,35 100,95 130,95" id="path20" inkscape:connector-curvature="0" sodipodi:nodetypes="cc" />
        <path style="fill:none;stroke:#000000;stroke-width:0.5;stroke-linecap:butt;stroke-linejoin:miter;stroke-miterlimit:4;stroke-dasharray:2, 1;stroke-dashoffset:0;stroke-opacity:1;marker-start:url(#Arrow1Lstart);marker-mid:url(#DotM);marker-end:url(#TriangleOutL)" d="M 20,120 60,110 100,125 140,112 190,130" id="path22" inkscape:connector-curvature="0" />
        <path sodipodi:type="arc" style="fill:none;stroke:#0000ff;stroke-width:0.5;marker-end:url(#TriangleOutL)" id="path24" sodipodi:cx="100" sodipodi:cy="60" sodipodi:rx="20" sodipodi:ry="20" sodipodi:start="0" sodipodi:end="4.7" d="M 120,60 A 20,20 0 1 1 99.75,40" sodipodi:open="true" />
      </g>
    </svg>
    """

    private static let inkscape1 = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <svg width="160mm" height="90mm" viewBox="0 0 160 90" version="1.1" id="svg1" inkscape:version="1.3.2 (091e20e, 2023-11-25)" sodipodi:docname="flow.svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg">
      <sodipodi:namedview id="namedview1" pagecolor="#ffffff" bordercolor="#000000" borderopacity="0.25" inkscape:document-units="mm" />
      <defs id="defs1">
        <marker style="overflow:visible" id="ArrowWide" refX="0" refY="0" orient="auto-start-reverse" inkscape:stockid="Wide arrow" markerWidth="1" markerHeight="1" viewBox="0 0 1 1" inkscape:isstock="true" inkscape:collect="always" preserveAspectRatio="xMidYMid">
          <path style="fill:none;stroke:context-stroke;stroke-width:1;stroke-linecap:butt" d="M 3,-3 0,0 3,3" transform="rotate(180,0.125,0)" sodipodi:nodetypes="ccc" id="path1" />
        </marker>
        <marker style="overflow:visible" id="Triangle" refX="0" refY="0" orient="auto-start-reverse" inkscape:stockid="Triangle arrow" markerWidth="1" markerHeight="1" viewBox="0 0 1 1" inkscape:isstock="true" inkscape:collect="always" preserveAspectRatio="xMidYMid">
          <path transform="scale(0.5)" style="fill:context-stroke;fill-rule:evenodd;stroke:context-stroke;stroke-width:1pt" d="M 5.77,0 -2.88,5 V -5 Z" id="path135" />
        </marker>
        <marker style="overflow:visible" id="Dot" refX="0" refY="0" orient="auto" inkscape:stockid="Dot" markerWidth="1" markerHeight="1" viewBox="0 0 1 1" inkscape:isstock="true" inkscape:collect="always" preserveAspectRatio="xMidYMid">
          <path transform="scale(0.5)" style="fill:context-stroke;fill-rule:evenodd;stroke:none" d="M 5,0 C 5,2.76 2.76,5 0,5 -2.76,5 -5,2.76 -5,0 c 0,-2.76 2.3,-5 5,-5 2.76,0 5,2.24 5,5 z" sodipodi:nodetypes="sssss" id="path17" />
        </marker>
        <linearGradient id="linearGradient3"><stop style="stop-color:#f6d32d;stop-opacity:1;" offset="0" id="stop3" /><stop style="stop-color:#e66100;stop-opacity:1;" offset="1" id="stop4" /></linearGradient>
        <linearGradient xlink:href="#linearGradient3" id="linearGradient4" x1="10" y1="25" x2="60" y2="25" gradientUnits="userSpaceOnUse" />
      </defs>
      <g inkscape:label="Layer 1" inkscape:groupmode="layer" id="layer1">
        <rect style="fill:url(#linearGradient4);stroke:#1a5fb4;stroke-width:0.8;stroke-linecap:round;stroke-linejoin:round" id="rect1" width="50" height="30" x="10" y="10" ry="4" />
        <ellipse style="fill:#99c1f1;stroke:#1a5fb4;stroke-width:0.8" id="ellipse1" cx="125" cy="60" rx="25" ry="15" />
        <path style="fill:none;stroke:#241f31;stroke-width:0.8;stroke-linecap:round;stroke-dasharray:none;marker-end:url(#Triangle)" d="M 60,25 C 90,25 90,60 100,60" id="path2" sodipodi:nodetypes="cc" />
        <path style="fill:none;stroke:#c01c28;stroke-width:0.6;stroke-dasharray:2.4, 1.2;stroke-dashoffset:0;marker-start:url(#Dot);marker-mid:url(#Dot);marker-end:url(#ArrowWide)" d="M 15,75 35,65 55,78 75,62 95,80" id="path3" />
      </g>
    </svg>
    """

    private static let mermaidFlowchart = """
    <svg id="mermaid-1700000000000" width="100%" xmlns="http://www.w3.org/2000/svg" class="flowchart" style="max-width: 262.4px;" viewBox="0 0 262.4 174" role="graphics-document document" aria-roledescription="flowchart-v2"><style>#mermaid-1700000000000{font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:16px;fill:#333;}@keyframes edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}#mermaid-1700000000000 .edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear infinite;stroke-linecap:round;}#mermaid-1700000000000 .error-icon{fill:#552222;}#mermaid-1700000000000 .edge-thickness-normal{stroke-width:1px;}#mermaid-1700000000000 .edge-pattern-dashed{stroke-dasharray:3;}#mermaid-1700000000000 .edge-pattern-dotted{stroke-dasharray:2;}#mermaid-1700000000000 .marker{fill:#333333;stroke:#333333;}#mermaid-1700000000000 .marker.cross{stroke:#333333;}#mermaid-1700000000000 svg{font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:16px;}#mermaid-1700000000000 p{margin:0;}#mermaid-1700000000000 .label{font-family:"trebuchet ms",verdana,arial,sans-serif;color:#333;}#mermaid-1700000000000 .node rect,#mermaid-1700000000000 .node circle,#mermaid-1700000000000 .node ellipse,#mermaid-1700000000000 .node polygon,#mermaid-1700000000000 .node path{fill:#ECECFF;stroke:#9370DB;stroke-width:1px;}#mermaid-1700000000000 .arrowheadPath{fill:#333333;}#mermaid-1700000000000 .edgePath .path{stroke:#333333;stroke-width:2.0px;}#mermaid-1700000000000 .flowchart-link{stroke:#333333;fill:none;}#mermaid-1700000000000 .edgeLabel{background-color:rgba(232,232,232, 0.8);text-align:center;}#mermaid-1700000000000 :root{--mermaid-font-family:"trebuchet ms",verdana,arial,sans-serif;}</style><g><marker id="mermaid-1700000000000_flowchart-v2-pointEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" class="arrowMarkerPath" style="stroke-width: 1; stroke-dasharray: 1, 0;"/></marker><marker id="mermaid-1700000000000_flowchart-v2-pointStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="4.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 5 L 10 10 L 10 0 z" class="arrowMarkerPath" style="stroke-width: 1; stroke-dasharray: 1, 0;"/></marker><marker id="mermaid-1700000000000_flowchart-v2-circleEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="11" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1; stroke-dasharray: 1, 0;"/></marker><marker id="mermaid-1700000000000_flowchart-v2-crossEnd" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="12" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2; stroke-dasharray: 1, 0;"/></marker><g class="root"><g class="clusters"/><g class="edgePaths"><path d="M129.5,62L129.5,66.167C129.5,70.333,129.5,78.667,129.5,86.333C129.5,94,129.5,101,129.5,104.5L129.5,108" id="L_A_B_0" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=";" data-edge="true" data-et="edge" data-id="L_A_B_0" data-points="W3sieCI6MTI5LjUsInkiOjYyfV0=" marker-end="url(#mermaid-1700000000000_flowchart-v2-pointEnd)"/><path d="M60,62L60,108" id="L_A_C_0" class="edge-thickness-normal edge-pattern-dotted flowchart-link" style="stroke-dasharray: 2;" data-edge="true" marker-start="url(#mermaid-1700000000000_flowchart-v2-pointStart)" marker-end="url(#mermaid-1700000000000_flowchart-v2-circleEnd)"/></g><g class="edgeLabels"><g class="edgeLabel"><g class="label" data-id="L_A_B_0" transform="translate(0, 0)"><foreignObject width="0" height="0"><div xmlns="http://www.w3.org/1999/xhtml" class="labelBkg" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g></g><g class="nodes"><g class="node default" id="flowchart-A-0" transform="translate(129.5, 35)"><rect class="basic label-container" style="" x="-37.5" y="-27" width="75" height="54"/></g></g></g></g></svg>
    """

    private static let mermaidSequence = """
    <svg aria-roledescription="sequence" role="graphics-document document" viewBox="-50 -10 450 259" style="max-width: 450px;" xmlns="http://www.w3.org/2000/svg" width="100%" id="mermaid-2"><g><rect class="actor actor-bottom" ry="3" rx="3" name="Bob" height="65" width="150" stroke="#666" fill="#eaeaea" y="173" x="200"/></g><g><line name="Alice" stroke="#999" stroke-width="0.5px" class="actor-line 200" y2="173" x2="75" y1="65" x1="75" id="actor0"/></g><style>#mermaid-2{font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:16px;fill:#333;}#mermaid-2 .marker{fill:#333333;stroke:#333333;}#mermaid-2 .marker.cross{stroke:#333333;}#mermaid-2 #arrowhead path{fill:#333;stroke:#333;}#mermaid-2 .sequenceNumber{fill:white;}#mermaid-2 #sequencenumber{fill:#333;}#mermaid-2 #crosshead path{fill:#333;stroke:#333;}#mermaid-2 .messageLine0{stroke-width:1.5;stroke-dasharray:none;stroke:#333;}#mermaid-2 .messageLine1{stroke-width:1.5;stroke-dasharray:2,2;stroke:#333;}</style><g/><defs><symbol height="24" width="24" id="computer"><path d="M2 2v13h20v-13h-20zm18 11h-16v-9h16v9zm-10.228 6l.466-1h3.524l.467 1h-4.457zm14.228 3h-24l2-6h2.104l-1.33 4h18.45l-1.297-4h2.073l2 6zm-5-10h-14v-7h14v7z" transform="scale(.5)"/></symbol></defs><defs><marker orient="auto-start-reverse" markerHeight="12" markerWidth="12" markerUnits="userSpaceOnUse" refY="5" refX="7.9" id="arrowhead"><path d="M -1 0 L 10 5 L 0 10 z"/></marker></defs><defs><marker refY="4.5" refX="4" orient="auto" markerHeight="8" markerWidth="15" id="crosshead"><path style="stroke-dasharray: 0, 0;" d="M 1,2 L 6,7 M 6,2 L 1,7" stroke-width="1pt" stroke="#000000" fill="none"/></marker></defs><defs><marker orient="auto" markerHeight="28" markerWidth="20" refY="7" refX="15.5" id="filled-head"><path d="M 18,7 L9,13 L14,7 L9,1 Z"/></marker></defs><defs><marker orient="auto" markerHeight="40" markerWidth="60" refY="15" refX="15" id="sequencenumber"><circle r="6" cy="15" cx="15"/></marker></defs><line style="fill: none;" marker-start="url(#sequencenumber)" marker-end="url(#arrowhead)" stroke="none" stroke-width="2" class="messageLine0" y2="109" x2="271" y1="109" x1="76"/><line style="stroke-dasharray: 3, 3; fill: none;" marker-end="url(#arrowhead)" stroke="none" stroke-width="2" class="messageLine1" y2="153" x2="79" y1="153" x1="274"/></svg>
    """

    private static let d3Force = """
    <svg xmlns="http://www.w3.org/2000/svg" width="960" height="500"><style>.link { fill: none; stroke: #666; stroke-width: 1.5px; } #licensing { fill: green; } .link.licensing { stroke: green; } .link.resolved { stroke-dasharray: 0,2 1; } circle { fill: #ccc; stroke: #333; stroke-width: 1.5px; }</style><defs><marker id="suit" viewBox="0 -5 10 10" refX="15" refY="-1.5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0,-5L10,0L0,5"></path></marker><marker id="licensing" viewBox="0 -5 10 10" refX="15" refY="-1.5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0,-5L10,0L0,5"></path></marker><marker id="resolved" viewBox="0 -5 10 10" refX="15" refY="-1.5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0,-5L10,0L0,5"></path></marker></defs><g><path class="link suit" marker-end="url(#suit)" d="M474,238A111,111 0 0,1 365,216"></path><path class="link licensing" marker-end="url(#licensing)" d="M365,216A150,150 0 0,1 250,300"></path><path class="link resolved" marker-end="url(#resolved)" d="M250,300A90,90 0 0,1 474,238"></path></g><g><circle r="6" transform="translate(474,238)"></circle><circle r="6" transform="translate(365,216)"></circle></g></svg>
    """

    private static let mdnReference = """
    <svg viewBox="0 0 300 100" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <!-- A marker to be used as an arrowhead -->
        <marker id="arrow" viewBox="0 0 10 10" refX="5" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 0 L 10 5 L 0 10 z" />
        </marker>
        <!-- simple dot marker definition -->
        <marker id="dot" viewBox="0 0 10 10" refX="5" refY="5" markerWidth="5" markerHeight="5">
          <circle cx="5" cy="5" r="5" fill="red" />
        </marker>
      </defs>
      <!-- Coordinate axes with an arrowhead in both directions -->
      <polyline points="10,10 10,90 90,90" fill="none" stroke="black" marker-start="url(#arrow)" marker-end="url(#arrow)" />
      <!-- Data line with polymarkers -->
      <polyline points="15,80 29,50 43,60 57,30 71,40 85,15" fill="none" stroke="grey" marker-start="url(#dot)" marker-mid="url(#dot)" marker-end="url(#dot)" />
      <line x1="120" y1="50" x2="280" y2="50" stroke="black" stroke-width="2" marker-end="url(#arrow)"/>
    </svg>
    """

    private static let omniGraffle = """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xl="http://www.w3.org/1999/xlink" xmlns:dc="http://purl.org/dc/elements/1.1/" version="1.1" viewBox="50 60 400 200" width="400" height="200">
      <defs>
        <marker orient="auto" overflow="visible" markerUnits="strokeWidth" id="FilledArrow_Marker" stroke-linejoin="miter" stroke-miterlimit="10" viewBox="-1 -4 10 8" markerWidth="10" markerHeight="8" color="black"><g><path d="M 8 0 L 0 -3 L 0 3 Z" fill="currentColor" stroke="currentColor" stroke-width="1"/></g></marker>
        <marker orient="auto" overflow="visible" markerUnits="strokeWidth" id="FilledBall_Marker" stroke-linejoin="miter" stroke-miterlimit="10" viewBox="-9 -4 10 8" markerWidth="10" markerHeight="8" color="black"><g><circle cx="-3.9999985" cy="0" r="3.9999975" fill="currentColor" stroke="currentColor" stroke-width="1"/></g></marker>
      </defs>
      <metadata> Produced by OmniGraffle 7.18 <dc:date>2021-01-01 00:00:00 +0000</dc:date></metadata>
      <g id="Canvas_1" stroke-opacity="1" stroke-dasharray="none" fill="none" stroke="none" fill-opacity="1"><title>Canvas 1</title><g id="Canvas_1_Layer_1"><title>Layer 1</title>
        <g id="Graphic_2"><rect x="72" y="90" width="108" height="54" fill="white"/><rect x="72" y="90" width="108" height="54" stroke="black" stroke-linecap="round" stroke-linejoin="round" stroke-width="1"/></g>
        <g id="Line_4"><line x1="180" y1="117" x2="314.1" y2="117" marker-end="url(#FilledArrow_Marker)" marker-start="url(#FilledBall_Marker)" stroke="black" stroke-linecap="round" stroke-linejoin="round" stroke-width="1"/></g>
      </g></g>
    </svg>
    """
}
