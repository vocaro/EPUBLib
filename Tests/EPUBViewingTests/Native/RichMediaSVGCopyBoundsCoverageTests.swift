import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// A third class of renderer amplification the byte, node, depth and expansion limits do not bound:
/// values the renderer copies or re-reads once per painted shape. A gradient's stops are copied into
/// a fresh paint server for every shape it paints, a dash array is stored for every stroked shape,
/// and a long inherited `fill`/`stroke` is re-parsed for every shape that inherits it, so a file of a
/// few hundred kilobytes can make the renderer allocate hundreds of megabytes to gigabytes or parse
/// for most of a minute ([#252](https://github.com/vocaro/EPUBLib/issues/252)).
///
/// `SVGContent.copyVerdict` counts these as the marker bound counts markers: each shape is charged
/// the most that it or any ancestor, through every `<use>` that draws it, could ask for, so the
/// count never falls below what the renderer does, and a drawing past `maximumSharedCopies` shows its
/// fallback text with the same `svg` disclosure as the other limits. Every case asserts a verdict, a
/// count or the step counter, never a time or a memory figure, which is machine-dependent (#62). An
/// input that is refused is given to the check alone, never rendered.
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
            limits: .init(bytes: SVGContent.maximumBytes, depth: SVGContent.maximumDepth, nodes: SVGContent.maximumNodes),
            asContent: false).root
    }

    /// The copy verdict alone, with the copies counted and the steps the walk took: for an input
    /// that would cost the renderer much, and wherever a count is asserted.
    private func verdict(_ svg: String, stepBudget: Int = SVGContent.markerStepBudget) -> SVGContent.CopyVerdict {
        guard let root = parsed(svg) else { return (false, -1, -1) }
        return SVGContent.copyVerdict(root, stepBudget: stepBudget)
    }

    private func isWithinLimits(_ svg: String) -> Bool {
        parsed(svg).map { SVGContent.isWithinRenderingLimits($0) } ?? false
    }

    private func renders(_ svg: String) -> Bool {
        ReaderImageSource.svg(Data(svg.utf8), path: "", key: UUID().uuidString) != nil
    }

    private func image(_ body: String, files: [String: Data] = [:]) throws -> (ReaderImageAttachment?, SectionText) {
        let text = try RichMediaBook(body: body, files: files).build()
        return (text.richMediaImages.first, text)
    }

    // MARK: Rule 1: gradient stops per painted shape

    /// Each shape is charged the stops of the gradient its fill names and those its stroke names,
    /// however the gradient is reached.
    func testStopsAreChargedPerPaintedShape() throws {
        func copies(_ body: String, defs: String = "", stops: Int = 3) -> Int {
            verdict(svg(gradient(stops: stops) + defs, body)).copies
        }
        XCTAssertEqual(copies("<rect width='1' height='1' fill='url(#g)'/>"), 3, "a gradient fill copies its stops")
        XCTAssertEqual(copies("<rect width='1' height='1' fill='url(#g)' stroke='url(#g)'/>"), 6, "fill and stroke each")
        XCTAssertEqual(copies("<rect width='1' height='1' stroke='url(#g)'/>"), 3, "stroke alone")
        XCTAssertEqual(copies("<g fill='url(#g)'><g><rect width='1' height='1'/></g></g>"), 3, "inherited from an ancestor")
        XCTAssertEqual(copies("<rect width='1' height='1' style='fill:url(#g)'/>"), 6,
                       "a style paint names fill or stroke indistinguishably, so both are charged")
        XCTAssertEqual(copies("<rect width='1' height='1' fill='red'/>"), 0, "a plain colour copies nothing")
        XCTAssertEqual(copies("<rect width='1' height='1'/>"), 0, "and the default fill nothing")

        // Through a gradient `href` chain, the stops of the first gradient that holds them.
        XCTAssertEqual(copies("<rect width='1' height='1' fill='url(#h)'/>", defs: "<linearGradient id='h' href='#g'/>"), 3)
        XCTAssertEqual(copies("<rect width='1' height='1' fill='url(#h)'/>",
                              defs: "<linearGradient id='h' href='#i'/><linearGradient id='i' href='#g'/>"), 3, "two links")
        // A radial gradient copies its stops the same way.
        XCTAssertEqual(verdict(svg("<radialGradient id='g'><stop/><stop/><stop/><stop/></radialGradient>",
                                   "<rect width='1' height='1' fill='url(#g)'/>")).copies, 4)

        // Through `<use>`: the shape is painted once for each copy, each copy copying the stops.
        let use = svg(gradient(stops: 3) + "<g id='u'><rect width='1' height='1' fill='url(#g)'/></g>",
                      String(repeating: "<use xlink:href='#u'/>", count: 5))
        XCTAssertEqual(verdict(use).copies, 15, "five copies of one gradient-filled rect")
        XCTAssertEqual(verdict(svg(gradient(stops: 3) + "<g id='u'><rect width='1' height='1'/></g>",
                                   "<g fill='url(#g)'>" + String(repeating: "<use xlink:href='#u'/>", count: 5) + "</g>")).copies, 15,
                       "inherited where the use draws it")

        // A handful of stops painting thousands of shapes is an ordinary drawing and renders.
        XCTAssertTrue(renders(svg(gradient(stops: 4), "<g fill='url(#g)'>" + String(repeating: "<rect width='1' height='1'/>", count: 3_000) + "</g>")),
                      "4 stops on 3,000 shapes is 12,000 copies")
    }

    /// The stops counted are exactly what the renderer copies: a gradient painting shapes past the
    /// bound is refused, its neighbour one shape fewer renders.
    func testStopsAtTheBound() throws {
        XCTAssertEqual(SVGContent.maximumSharedCopies, 8 * 1024 * 1024)
        // 2,048 stops copied for each of 4,096 rects is exactly the bound.
        func drawing(_ rects: Int) -> String {
            svg(gradient(stops: 2_048), String(repeating: "<rect width='1' height='1' fill='url(#g)'/>", count: rects))
        }
        var result = verdict(drawing(4_096))
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.copies, 8 * 1024 * 1024)
        result = verdict(drawing(4_097))
        XCTAssertFalse(result.withinLimits, "one shape more is past it")
        XCTAssertEqual(result.copies, 8 * 1024 * 1024 + 2_048)
        XCTAssertFalse(isWithinLimits(drawing(4_097)))
    }

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

    /// A gradient inside a `<mask>` is copied once per shape the mask draws, which the renderer draws
    /// once per element that uses the mask. The content is charged once here (the per-reference
    /// multiplication is #220); a gradient written directly on the mask's shapes is still counted.
    func testStopsInAMaskAreCharged() throws {
        let masked = "<rect width='9' height='9' mask='url(#k)'/>"
        let bomb = svg(gradient(stops: 5_000) + "<mask id='k'>" + String(repeating: "<rect width='1' height='1' fill='url(#g)'/>", count: 2_000) + "</mask>", masked)
        XCTAssertFalse(verdict(bomb).withinLimits, "a stop bomb in a mask, used once")
        XCTAssertFalse(isWithinLimits(bomb))
        // A mask with a handful of gradient-painted shapes is as it was.
        let plain = svg(gradient(stops: 4) + "<mask id='k'><rect width='9' height='9' fill='url(#g)'/></mask>", masked)
        XCTAssertEqual(verdict(plain).copies, 4, "the one masked shape's stops, counted once")
        XCTAssertTrue(renders(plain))
    }

    // MARK: Rule 2: dash-array entries per stroked shape

    /// Each stroked shape is charged its dash-array bytes, an upper bound on its entries, whether its
    /// own or inherited, in an attribute or a `style` declaration.
    func testDashIsChargedPerStrokedShape() throws {
        func copies(_ body: String) -> Int { verdict(svg("", body)).copies }
        XCTAssertEqual(copies("<path d='M0 0h1' stroke='black' stroke-dasharray='1 1 1 1'/>"), 7, "seven bytes of dash array")
        XCTAssertEqual(copies("<g stroke-dasharray='1 1 1 1'><path d='M0 0h1'/></g>"), 7, "inherited from a group")
        XCTAssertEqual(copies("<path d='M0 0h1' style='stroke:black;stroke-dasharray:1 1 1 1'/>"), 24,
                       "in a style attribute, the style's longest declaration bounds it")
        XCTAssertEqual(copies("<path d='M0 0h1'/>"), 0, "no dash, nothing to copy")

        // An ordinary dashed stroke on a large chart renders.
        XCTAssertTrue(renders(svg("", "<g stroke='black' stroke-dasharray='4 2'>" + String(repeating: "<path d='M0 0h9'/>", count: 3_000) + "</g>")),
                      "a 3-byte dash on 3,000 strokes is 9,000 copies")
    }

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

    /// A long `fill`/`stroke` attribute is re-parsed for every shape that has or inherits it, charged
    /// as its bytes over 64. A value in a `style` attribute or a stylesheet the renderer has already
    /// tokenized is not charged here.
    func testLongInheritedPaintIsChargedPerShape() throws {
        func copies(_ body: String) -> Int { verdict(svg("", body)).copies }
        let pad = String(repeating: " ", count: 640)
        XCTAssertEqual(copies("<rect width='1' height='1' fill='\(pad)red'/>"), 10, "643 bytes of fill, re-parsed: 10")
        XCTAssertEqual(copies("<g fill='\(pad)red'><rect width='1' height='1'/></g>"), 10, "inherited")
        XCTAssertEqual(copies("<rect width='1' height='1' fill='\(pad)red' stroke='\(pad)blue'/>"), 20, "fill and stroke both re-parsed")
        XCTAssertEqual(copies("<rect width='1' height='1' style='fill:\(pad)red'/>"), 0, "a style value is tokenized, not re-parsed in full")
        XCTAssertEqual(copies("<rect width='1' height='1' fill='red'/>"), 0, "a short value is nothing")
    }

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

    // MARK: Rule 4: a stylesheet value copied onto every matched element

    /// A stylesheet's longest declaration is copied onto every element a rule matches, and the
    /// largest gradient a stylesheet paints with is taken to reach every shape, since the selectors
    /// are not evaluated.
    func testStylesheetValuesAreChargedPerShape() throws {
        // The longest declaration (here `fill:red`, 8 bytes) is charged to each shape.
        XCTAssertEqual(verdict(svg("", "<rect width='1' height='1'/>", pre: "<style>rect{fill:red}</style>")).copies, 8)
        // A stylesheet paint `url(#g)` could paint any shape by fill or stroke: both are charged.
        let sheet = verdict(svg(gradient(stops: 2), "<rect width='20' height='20'/>", pre: "<style>rect{fill:url(#g)}</style>"))
        XCTAssertEqual(sheet.copies, 2 + 2 + 12, "two stops for fill and for stroke, and the declaration's 12 bytes")
        XCTAssertTrue(renders(svg(gradient(stops: 2), "<rect width='20' height='20'/>", pre: "<style>rect{fill:url(#g)}</style>")),
                      "a two-stop gradient from a stylesheet on one rect renders")

        // A stylesheet with a long declaration copied onto thousands of shapes is refused.
        let long = "<style>rect{font-family:" + String(repeating: "z", count: 20_000) + "}</style>"
        let bomb = svg("", String(repeating: "<rect width='1' height='1'/>", count: 9_000), pre: long)
        XCTAssertFalse(verdict(bomb).withinLimits)
        XCTAssertFalse(isWithinLimits(bomb))
    }

    // MARK: Rule 5: text copies per span

    /// A `<text>` run has at most one span per character, and each span copies its fill, stroke,
    /// three text decorations and font family. A run is charged its characters times those copies.
    func testTextIsChargedPerSpan() throws {
        func copies(_ body: String, defs: String = "") -> Int { verdict(svg(defs, body)).copies }
        XCTAssertEqual(copies("<text x='0' y='10' fill='url(#g)'>abc</text>", defs: gradient(stops: 3)), 36,
                       "three characters, four fill-and-stroke pairs, three stops")
        XCTAssertEqual(copies("<text x='0' y='10'>abc</text>"), 0, "plain text copies nothing")
        let family = String(repeating: "z", count: 100)
        XCTAssertEqual(copies("<text x='0' y='10' font-family='\(family)'>abc</text>"), 300, "the family is copied per span")

        // A gradient-filled label of ordinary length renders.
        XCTAssertTrue(renders(svg(gradient(stops: 6), "<text x='0' y='20' font-size='10' fill='url(#g)'>Figure 1</text>")))
    }

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

    // MARK: The walk

    /// The walk follows `<use>` as the expansion count does and charges one step for each element it
    /// visits and each reference it follows, so a test can assert it instead of timing the check.
    func testTheWalkFollowsUseAndIsCharged() throws {
        let drawing = svg(gradient(stops: 3) + "<g id='box'><rect width='1' height='1' fill='url(#g)'/></g>",
                          String(repeating: "<use xlink:href='#box'/>", count: 3))
        let result = verdict(drawing)
        XCTAssertEqual(result.copies, 9, "each use draws the rect, and copies the stops, again")
        XCTAssertEqual(result.steps, 1 + 3 * 4, "the root, then for each use: the use, the reference it follows, the group and the rect")
    }

    /// The walk stops at its step budget. An SVG within the expansion bound cannot reach the real
    /// one, so a small one is given here.
    func testTheWalkStopsAtItsStepBudget() throws {
        XCTAssertEqual(SVGContent.markerStepBudget, 4 * (SVGContent.maximumExpandedBytes / 32))
        var definitions = "<g id='t0'><rect width='1' height='1'/></g>"
        for level in 1...9 {
            definitions += "<g id='t\(level)'><use xlink:href='#t\(level - 1)'/><use xlink:href='#t\(level - 1)'/></g>"
        }
        let tree = svg(definitions, "<use xlink:href='#t9'/>")
        XCTAssertTrue(verdict(tree).withinLimits)
        XCTAssertFalse(verdict(tree, stepBudget: 100).withinLimits, "the walk refuses when the budget runs out")
        XCTAssertEqual(verdict(tree, stepBudget: 100).steps, 101, "and stops there")
    }

    /// A gradient `href` chain that loops back on itself terminates in the stop lookup, whatever the
    /// reference screen (#229) does with it: the fill resolves to no stops, and the walk is short.
    func testAGradientHrefLoopTerminates() throws {
        let loop = svg("<linearGradient id='g' href='#h'/><linearGradient id='h' href='#g'/>",
                       "<rect width='1' height='1' fill='url(#g)'/>")
        let result = verdict(loop)
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.copies, 0, "neither gradient holds a stop")
        XCTAssertLessThan(result.steps, 10)
    }

    // MARK: Ordinary drawings are unaffected

    /// A path's long `d`, a `points` list, a `transform`, an embedded `data:` image and a long but
    /// normal `font-family` are a shape's own values, not copied per shape, and do not trip the bound.
    func testOrdinaryLongValuesDoNotTripTheBound() throws {
        XCTAssertEqual(verdict(svg("", "<path d='M0 0" + String(repeating: "h1", count: 50_000) + "' stroke='black'/>")).copies, 0,
                       "a long path is its own geometry")
        XCTAssertEqual(verdict(svg("", "<polyline points='" + String(repeating: "1 1 ", count: 20_000) + "' stroke='black'/>")).copies, 0)
        XCTAssertEqual(verdict(svg("", "<g transform='" + String(repeating: "translate(1)", count: 5_000) + "'><rect width='1' height='1'/></g>")).copies, 0,
                       "a transform is read once per group, not per shape")
        XCTAssertTrue(renders("<svg \(Self.ns) width='20' height='20'><image width='20' height='20' xlink:href='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMCAQDJ/3LoAAAAAElFTkSuQmCC'/></svg>"),
                      "an embedded data image is unaffected")
        XCTAssertTrue(renders(svg("", "<text x='0' y='20' font-size='10' font-family='Helvetica Neue, Arial, sans-serif'>Caption</text>")),
                      "a normal font-family list on a short label")
    }
}
