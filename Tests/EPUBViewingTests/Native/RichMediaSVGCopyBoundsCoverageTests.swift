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
/// fallback text with the same `svg` disclosure as the other limits. A stylesheet's declarations are
/// the exception, charged only in part (`testStylesheetValuesAreChargedPerShape`, #282). Every case
/// asserts a verdict, a count or the step counter, never a time or a memory figure, which is
/// machine-dependent (#62). An input that is refused is given to the check alone, never rendered.
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

    /// A stylesheet declaration the renderer applies is copied onto every element a rule matches, so
    /// each shape is charged the longest such declaration's value, and the largest gradient a
    /// stylesheet paints with is taken to reach every shape, since the selectors are not evaluated.
    /// The renderer stores only the declaration's value (not `property:value`), only for a known
    /// presentation property, and only from an ordinary rule — never an at-rule.
    ///
    /// This charge is a partial bound, and the test is not proof of a full one. It keeps a single
    /// very long value from being copied onto thousands of shapes for free. It does not bound what
    /// many declarations cost, or what a rule costs on the groups and `<use>` elements it matches,
    /// which is left to [#282](https://github.com/vocaro/EPUBLib/issues/282).
    func testStylesheetValuesAreChargedPerShape() throws {
        // Only the value the renderer stores (`red`, 3 bytes) is charged, not the whole `fill:red`.
        XCTAssertEqual(verdict(svg("", "<rect width='1' height='1'/>", pre: "<style>rect{fill:red}</style>")).copies, 3)
        // The limit of the charge, pinned as a limit (#282): the renderer stores every presentation
        // declaration of a matched rule on the element, three strings here, and the screen charges
        // one value, the longest. A rule of several declarations of equal length is charged the same
        // as a rule of one, so what many declarations cost the renderer is not bounded by this charge.
        XCTAssertEqual(verdict(svg("", "<rect width='1' height='1'/>", pre: "<style>rect{fill:red;stroke:red;color:red}</style>")).copies, 3,
                       "three declarations are charged as one: a partial bound, not what the renderer stores")
        // A stylesheet paint `url(#g)` could paint any shape by fill or stroke: both are charged.
        let sheet = verdict(svg(gradient(stops: 2), "<rect width='20' height='20'/>", pre: "<style>rect{fill:url(#g)}</style>"))
        XCTAssertEqual(sheet.copies, 2 + 2 + 7, "two stops for fill and for stroke, and the value `url(#g)`")
        XCTAssertTrue(renders(svg(gradient(stops: 2), "<rect width='20' height='20'/>", pre: "<style>rect{fill:url(#g)}</style>")),
                      "a two-stop gradient from a stylesheet on one rect renders")
        // A declaration of a property the renderer does not apply is not stored on an element, so it
        // is not charged; neither is a selector, however long.
        XCTAssertEqual(verdict(svg("", "<rect width='1' height='1'/>",
                                   pre: "<style>rect{--custom:" + String(repeating: "z", count: 20_000) + "}</style>")).copies, 0,
                       "an unknown property the renderer drops is not charged")
        XCTAssertEqual(verdict(svg("", "<rect width='1' height='1'/>",
                                   pre: "<style>" + String(repeating: "z", count: 20_000) + " rect{fill:red}</style>")).copies, 3,
                       "a long selector is not a value the renderer copies")

        // A stylesheet with a long presentation declaration copied onto thousands of shapes is refused.
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

    // MARK: Rule 5: font-variation-settings copied per span

    /// `font-variation-settings` is parsed into a `Vec` the renderer stores for every span and clones
    /// again for every glyph, the worst per-span copy, which the first version of this bound charged
    /// nothing. Each `<text>` is charged its characters times its variation-settings bytes over 8.
    func testVariationSettingsAreChargedPerSpan() throws {
        func copies(_ body: String) -> Int { verdict(svg("", body)).copies }
        // Ten bytes of settings on a three-character run: ten over eight, once per character.
        XCTAssertEqual(copies("<text x='0' y='10' font-variation-settings='\"wght\" 700'>abc</text>"), 3)
        XCTAssertEqual(copies("<g font-variation-settings='\"wght\" 700'><text x='0' y='10'>abc</text></g>"), 3, "inherited")
        XCTAssertEqual(copies("<text x='0' y='10' style='font-variation-settings:&quot;wght&quot; 700'>abc</text>"), 3, "from a style attribute")
        XCTAssertEqual(copies("<text x='0' y='10'>abc</text>"), 0, "no settings, nothing to copy")

        // A short variable-font caption renders; thousands of axes on a long run do not.
        XCTAssertTrue(renders(svg("", "<text x='0' y='20' font-size='10' font-variation-settings='&quot;wght&quot; 700,&quot;wdth&quot; 85'>Figure 1</text>")),
                      "two axes on a short label is nothing")
    }

    func testVariationSettingsBombShowsFallbackAndDiscloses() throws {
        // Five thousand axes on each of 2,000 per-character spans: the renderer allocates gigabytes.
        let axes = String(repeating: "\"wght\" 700,", count: 5_000)
        let run = String(repeating: "a", count: 2_000)
        let xs = String(repeating: "0 ", count: 2_000)
        let bomb = svg("", "<text x='\(xs)' y='10' font-size='4' font-variation-settings='\(axes)'>\(run)</text>")
        let result = verdict(bomb)
        XCTAssertFalse(result.withinLimits, "the variation-settings bytes over eight, per character, exceed the bound")
        XCTAssertGreaterThan(result.copies, SVGContent.maximumSharedCopies)
        XCTAssertFalse(isWithinLimits(bomb))
        let (attachment, text) = try image("<p><img src='v.svg' alt='Weighted'/></p>", files: ["v.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment, "a variation bomb is not rendered")
        XCTAssertEqual(text.richMediaPlain, "Weighted")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: Rule 5: the decoration dash

    /// The renderer clones a text span's dash array into the span's own stroke and into each text
    /// decoration it draws, so a decorated run copies the dash four times, an undecorated one once.
    func testDecoratedTextDashIsChargedFourfold() throws {
        func copies(_ body: String) -> Int { verdict(svg("", body)).copies }
        let dash = "stroke='black' stroke-dasharray='1 1 1 1'" // seven bytes of dash array
        XCTAssertEqual(copies("<text x='0' y='10' \(dash)>ab</text>"), 2 * 7, "undecorated: one copy per character")
        XCTAssertEqual(copies("<text x='0' y='10' \(dash) text-decoration='underline overline line-through'>ab</text>"), 2 * 4 * 7,
                       "the span's stroke and three decoration strokes: four copies per character")
        XCTAssertEqual(copies("<g text-decoration='underline'><text x='0' y='10' \(dash)>ab</text></g>"), 2 * 4 * 7,
                       "a decoration inherited from an ancestor counts")
    }

    func testDecoratedDashBombShowsFallbackAndDiscloses() throws {
        // 2,000 dash entries on a 2,000-character run: within the bound undecorated, past it decorated.
        let dash = String(repeating: "1 ", count: 2_000)
        let run = String(repeating: "a", count: 2_000)
        let xs = String(repeating: "0 ", count: 2_000)
        func drawing(_ decoration: String) -> String {
            svg("", "<text x='\(xs)' y='10' font-size='4' stroke='black' stroke-dasharray='\(dash)'\(decoration)>\(run)</text>")
        }
        XCTAssertTrue(verdict(drawing("")).withinLimits, "undecorated, one dash copy per character, within the bound")
        let bomb = drawing(" text-decoration='underline overline line-through'")
        XCTAssertFalse(verdict(bomb).withinLimits, "decorated, four dash copies per character, past it")
        XCTAssertFalse(isWithinLimits(bomb))
        let (attachment, text) = try image("<p><img src='d.svg' alt='Dashed'/></p>", files: ["d.svg": Data(bomb.utf8)])
        XCTAssertNil(attachment)
        XCTAssertEqual(text.richMediaPlain, "Dashed")
        XCTAssertEqual(text.report.unsupportedElements["svg"], 1)
    }

    // MARK: An embedded font in a stylesheet is not charged against a drawing

    /// A `@font-face` holds its font bytes in a `src: url(data:…)` declaration the renderer never
    /// copies onto any drawn element (simplecss skips at-rules), and which `serialize` strips before
    /// rendering. Charging it per shape refused ordinary Illustrator, Inkscape, Figma and chart
    /// output that carries an embedded font; it must not.
    func testEmbeddedFontInStylesheetIsNotChargedPerShape() throws {
        // A 15 KB font (20 KB of base64) in a `@font-face`, used by 40 labels of about 500 characters.
        // Charged per character it would be ten million copies; it is not charged at all.
        let blob = Data(repeating: 0, count: 15_000).base64EncodedString()
        let style = "<style>@font-face{font-family:'E';src:url(data:font/woff2;base64,\(blob))} text{font-family:'E'}</style>"
        let labels = (0..<40).map { "<text x='4' y='\(12 + $0 * 9)' font-size='7'>Item label \($0)</text>" }.joined()
        let drawing = "<svg \(Self.ns) width='300' height='420'>\(style)\(labels)</svg>"
        let result = verdict(drawing)
        XCTAssertEqual(result.copies, 0, "the embedded font's bytes reach no element and are not charged")
        XCTAssertTrue(isWithinLimits(drawing), "an ordinary drawing with an embedded font is not refused")
        XCTAssertTrue(renders(drawing), "and it renders, with the font stripped as on main")

        // A stylesheet that paints with a real presentation declaration of the same size is refused:
        // that value the renderer does copy onto every matched element.
        let bomb = "<svg \(Self.ns) width='300' height='420'><style>text{stroke-width:\(String(repeating: "0", count: 20_000))1}</style>"
            + (0..<400).map { "<text x='4' y='\($0)' font-size='7'>Label \($0)</text>" }.joined() + "</svg>"
        XCTAssertFalse(verdict(bomb).withinLimits, "a 20 KB presentation value copied onto hundreds of runs is past the bound")
        XCTAssertFalse(isWithinLimits(bomb))
    }

    /// The screen on the original tree and the screen on the serialized bytes agree: a stylesheet
    /// `serialize` strips whole (its `url(data:…)` leaves the document) is not counted on either side,
    /// so neither screening refuses the drawing for bytes the renderer never sees.
    func testStrippedStylesheetIsNotChargedOnEitherScreening() throws {
        let blob = Data(repeating: 0, count: 15_000).base64EncodedString()
        let drawing = "<svg \(Self.ns) width='300' height='420'><style>@font-face{font-family:'E';src:url(data:font/woff2;base64,\(blob))} text{font-family:'E'}</style>"
            + (0..<40).map { "<text x='4' y='\($0 * 9 + 12)' font-size='7'>Item label \($0)</text>" }.joined() + "</svg>"
        XCTAssertEqual(verdict(drawing).copies, 0)
        guard let root = parsed(drawing),
              let serialized = SVGContent.serialize(root, resolve: { _ in nil }, publication: try EPUBPublication.open(data: Fixture.epub())),
              let reparsed = try? ContentDocument.parse(serialized, path: "svg", limits: .init(bytes: SVGContent.maximumBytes, depth: SVGContent.maximumDepth, nodes: SVGContent.maximumNodes), asContent: false).root else {
            return XCTFail("the embedded-font drawing should serialize")
        }
        XCTAssertFalse(serialized.contains("@font-face".data(using: .utf8)!), "serialize strips the stylesheet")
        XCTAssertEqual(SVGContent.copyVerdict(reparsed).copies, 0, "the serialized bytes hold no stylesheet to charge")
        XCTAssertTrue(SVGContent.isWithinRenderingLimits(reparsed), "and the second screening agrees with the first")
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
    /// one, so a small one is given here. The leaf is gradient-filled, so there is something to
    /// charge and the walk runs rather than returning early.
    func testTheWalkStopsAtItsStepBudget() throws {
        XCTAssertEqual(SVGContent.markerStepBudget, 4 * (SVGContent.maximumExpandedBytes / 32))
        var definitions = gradient(stops: 2) + "<g id='t0'><rect width='1' height='1' fill='url(#g)'/></g>"
        for level in 1...9 {
            definitions += "<g id='t\(level)'><use xlink:href='#t\(level - 1)'/><use xlink:href='#t\(level - 1)'/></g>"
        }
        let tree = svg(definitions, "<use xlink:href='#t9'/>")
        XCTAssertTrue(verdict(tree).withinLimits)
        XCTAssertFalse(verdict(tree, stepBudget: 100).withinLimits, "the walk refuses when the budget runs out")
        XCTAssertEqual(verdict(tree, stepBudget: 100).steps, 101, "and stops there")
    }

    /// A drawing that copies nothing per shape — no gradient, dash, stylesheet, text or re-parsed
    /// value — is not walked at all, however large its `<use>` expansion, so the screen's own cost
    /// stays near the cheaper limits' instead of a second walk of the whole expansion.
    func testNothingChargeableIsNotWalked() throws {
        var definitions = "<g id='t0'><rect width='1' height='1'/></g>"
        for level in 1...9 {
            definitions += "<g id='t\(level)'><use xlink:href='#t\(level - 1)'/><use xlink:href='#t\(level - 1)'/></g>"
        }
        let result = verdict(svg(definitions, "<use xlink:href='#t9'/>"))
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.copies, 0)
        XCTAssertEqual(result.steps, 0, "the walk did not run")
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

    // MARK: The stop lookup

    /// `levels` ids in a chain: each is the id of `shared` gradients that have no stops and name the
    /// next id by `href`, and the last of them names `g<levels>`, which `tail` may define. `rects`
    /// rects are filled with the first.
    private func chain(_ levels: Int, shared: Int = 1, tail: String = "", rects: Int = 1) -> String {
        let links = (0..<levels).map { String(repeating: "<linearGradient id='g\($0)' href='#g\($0 + 1)'/>", count: shared) }.joined()
        return svg(links + tail, String(repeating: "<rect width='1' height='1' fill='url(#g0)'/>", count: rects))
    }

    /// A gradient with no stops takes them through its `href`. The lookup once went from such a
    /// gradient to every gradient that had the id it named, and from each of those to every gradient
    /// with the next id: the work doubled with each link of a chain whose ids two gradients share,
    /// so screening a file of 1.6 KB took ten seconds and one of 3 KB did not finish. Each gradient is
    /// now read once, for one step, and the steps are asserted.
    ///
    /// What would stop such a lookup here, were it to come back, is the first assertion of this
    /// test, where the test ends (`continueAfterFailure`): ten ids, two gradients to each, under a
    /// budget of 1,000 steps. A lookup that takes a step for each gradient it reads, and reads them
    /// over again, is stopped there by the budget: it spends the 1,000 at once and the drawing is
    /// refused. The lookup that was removed took no step, and no budget stops that one. What does
    /// is that this chain is short: it reads it in some four thousand calls, and counts 2 steps
    /// where there are 22. Either fails in milliseconds, and the longer chains are then not
    /// screened, as they must not be. From a chain of forty ids the lookup that takes no step
    /// would not return, and the one that takes them would go on to the whole screen
    /// (`isWithinLimits`), whose budget is the real one, a million steps, which took it nearly
    /// three minutes in one of these tests. The two tests after this one screen shared ids too,
    /// and begin the same way.
    func testGradientsThatShareIdsAreEachReadOnce() throws {
        continueAfterFailure = false
        XCTAssertEqual(verdict(chain(10, shared: 2), stepBudget: 1_000).steps, 22, "each gradient read once, for one step")
        for (levels, shared) in [(20, 2), (12, 3), (40, 2), (64, 4)] {
            let drawing = chain(levels, shared: shared)
            let result = verdict(drawing, stepBudget: 1_000)
            XCTAssertTrue(result.withinLimits, "\(levels) ids, each shared by \(shared) gradients")
            XCTAssertEqual(result.copies, 0, "no gradient holds a stop")
            XCTAssertEqual(result.steps, levels * shared + 2, "one step for each gradient, then the root and the rect")
            XCTAssertTrue(isWithinLimits(drawing), "the whole screen passes it, as it did before the copies were counted")
        }
        // The lookup spends from the walk's budget, and stops when that is gone.
        let stopped = verdict(chain(40, shared: 2), stepBudget: 50)
        XCTAssertFalse(stopped.withinLimits, "the lookup refuses when the budget runs out")
        XCTAssertEqual(stopped.steps, 51, "and stops there")
    }

    /// Gradients that share an id and name that same id lead to each other without end. The reference
    /// screen (#229) refuses the drawing first, but the lookup ends on its own: an id that several
    /// gradients share is not followed. One gradient that names itself is a loop of one.
    func testGradientsThatNameTheIdTheyShareEndTheLookup() throws {
        // A lookup that followed every gradient with a shared id fails this first, in milliseconds,
        // and the test ends there, as `testGradientsThatShareIdsAreEachReadOnce` says: one that took
        // no step would not return from the two gradients below.
        continueAfterFailure = false
        XCTAssertEqual(verdict(chain(10, shared: 2), stepBudget: 1_000).steps, 22, "each gradient read once, for one step")
        let rect = "<rect width='1' height='1' fill='url(#a)'/>"
        var result = verdict(svg(String(repeating: "<linearGradient id='a' href='#a'/>", count: 2), rect), stepBudget: 1_000)
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.copies, 0, "neither gradient holds a stop, and no other does")
        XCTAssertEqual(result.steps, 2 + 2, "one step for each gradient, then the root and the rect")

        result = verdict(svg("<linearGradient id='a' href='#a'/>", rect), stepBudget: 1_000)
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.copies, 0)
        XCTAssertEqual(result.steps, 1 + 2, "a gradient that names itself is read once")
    }

    /// Where a chain meets an id that several gradients share, the renderer takes the last element
    /// that has the id: it goes on from that one when it is a gradient, and finds no stops and paints
    /// nothing when it is not. Which is last is not worked out, so the gradient is charged the most
    /// stops any gradient in the SVG has, which is never less: a chain of shared ids cannot hide the
    /// stops it ends in.
    func testAnHrefToASharedIdIsChargedTheLargestGradient() throws {
        // A lookup that followed every gradient with a shared id fails this first, in milliseconds,
        // and the test ends there, as `testGradientsThatShareIdsAreEachReadOnce` says: one that took
        // no step would not return from the chain of forty ids below.
        continueAfterFailure = false
        XCTAssertEqual(verdict(chain(10, shared: 2), stepBudget: 1_000).steps, 22, "each gradient read once, for one step")
        // Forty ids, two gradients to each, and where the chain ends a gradient of 2,048 stops: the
        // renderer paints every rect with those.
        func drawing(_ rects: Int) -> String { chain(40, shared: 2, tail: gradient("g40", stops: 2_048), rects: rects) }
        var result = verdict(drawing(4_096), stepBudget: 10_000)
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.copies, 8 * 1024 * 1024, "each rect is charged the 2,048 stops the chain ends in")
        XCTAssertEqual(result.steps, 80 + 1 + 4_096, "one step for each gradient without stops, then the root and the rects")
        result = verdict(drawing(4_097), stepBudget: 10_000)
        XCTAssertFalse(result.withinLimits, "one shape more is past the bound")
        XCTAssertEqual(result.copies, 8 * 1024 * 1024 + 2_048)
        XCTAssertFalse(isWithinLimits(drawing(4_097)))

        // The most any gradient has, whether or not the gradients that share the id lead to it.
        func copies(_ defs: String, fill: String) -> Int { verdict(svg(defs, "<rect width='1' height='1' fill='url(#\(fill))'/>")).copies }
        let shared = "<linearGradient id='h' href='#a'/>" + gradient("a", stops: 2) + gradient("a", stops: 3) + gradient("big", stops: 5)
        XCTAssertEqual(copies(shared, fill: "h"), 5, "an href to an id two gradients share: the largest gradient in the SVG")
        XCTAssertEqual(copies(shared, fill: "a"), 3, "a fill that names the shared id: the most of the gradients that have it, as before")
        // An id shared with an element that is no gradient names one gradient, and is followed to it:
        // were the other element the last, the renderer would find no stops and paint nothing.
        let mixed = "<linearGradient id='h' href='#a'/><rect id='a' width='1' height='1'/>" + gradient("a", stops: 3) + gradient("big", stops: 5)
        XCTAssertEqual(copies(mixed, fill: "h"), 3)
    }

    /// A chain in which each id is one gradient's is followed link by link to the first gradient that
    /// has stops, and charged exactly those, as it was before. It is followed at any length, as the
    /// renderer follows it: the lookup once gave up 64 links along and charged nothing.
    func testAnHrefChainOfUniqueIdsIsChargedTheStopsItLeadsTo() throws {
        let rect = "<rect width='1' height='1' fill='url(#g0)'/>"
        var result = verdict(chain(20, tail: gradient("g20", stops: 3)), stepBudget: 1_000)
        XCTAssertEqual(result.copies, 3, "twenty links to a gradient of three stops")
        XCTAssertEqual(result.steps, 20 + 2, "one step for each gradient without stops, then the root and the rect")
        XCTAssertEqual(verdict(svg("<linearGradient id='g0' href='#g1'/>" + gradient("g1", stops: 2, "href='#g2'") + gradient("g2", stops: 5), rect)).copies, 2,
                       "the first gradient on the chain that has stops, not the largest")
        XCTAssertEqual(verdict(chain(20), stepBudget: 1_000).copies, 0, "a chain that ends at an id no gradient has leads to no stops")
        XCTAssertEqual(verdict(svg("<linearGradient id='g0' href='#g1'/><rect id='g1' width='1' height='1'/>" + gradient("big", stops: 5), rect)).copies, 0,
                       "nor does one that ends at an element that is no gradient")

        // Fifty gradients that each lead into the chain do not each read it again.
        let joined = (0..<50).map { "<linearGradient id='f\($0)' href='#g0'/>" }.joined()
        result = verdict(chain(20, tail: gradient("g20", stops: 3) + joined), stepBudget: 1_000)
        XCTAssertEqual(result.copies, 3)
        XCTAssertEqual(result.steps, 50 + 20 + 2, "the chain is read once, and each gradient that joins it once")

        // A chain longer than the depth limit is charged what it leads to.
        result = verdict(chain(100, tail: gradient("g100", stops: 3)), stepBudget: 1_000)
        XCTAssertEqual(result.copies, 3, "a hundred links to a gradient of three stops")
        XCTAssertEqual(result.steps, 100 + 2)
        let bomb = chain(100, tail: gradient("g100", stops: 2_048), rects: 4_097)
        XCTAssertFalse(verdict(bomb).withinLimits, "2,048 stops copied for each of 4,097 rects, a hundred links away")
        XCTAssertFalse(isWithinLimits(bomb))
    }

    // MARK: The CSS the check reads

    /// The check reads a stylesheet and a `style` attribute several times, once for each thing it
    /// looks for, and charges every reading to the step budget: a step for every 64 bytes read,
    /// counted over all the readings together. The steps of ordinary CSS are pinned here, reading
    /// by reading, so that a reading added or made twice shows as a count.
    func testEveryReadingOfCSSIsCharged() throws {
        XCTAssertEqual(SVGContent.cssBytesPerStep, 64)
        let rect = "<rect width='1' height='1'/>"
        // A hundred rules: 1,400 bytes, 800 of them in the rules' bodies.
        let sheet = String(repeating: "rect{fill:red}", count: 100)
        var result = verdict(svg("", rect, pre: "<style>\(sheet)</style>"))
        XCTAssertEqual(result.copies, 3)
        XCTAssertEqual(result.steps, 2 + (1_400 + 1_400 + 800) / 64,
                       "the root and the rect; the sheet read to tell whether it is kept, and for its rules, and each rule's body for its declarations")
        result = verdict(svg(gradient(stops: 2), rect, pre: "<style>\(sheet)</style>"))
        XCTAssertEqual(result.steps, 2 + (1_400 + 1_400 + 800 + 1_400) / 64, "and once more for its paints where there is a gradient to paint with")
        result = verdict(svg("", rect, pre: "<style>\(sheet)@import 'x';</style>"))
        XCTAssertEqual(result.copies, 0)
        XCTAssertEqual(result.steps, 1_412 / 64, "a sheet that is stripped whole is read to tell that, and no more; with nothing to charge, nothing is walked")

        // A `style` attribute of 900 bytes: read first for bounded font-size values, then for a
        // decoration, for its paints and whether it declares a dash array, and for its values.
        let style = String(repeating: "fill:red;", count: 100)
        result = verdict(svg("", "<rect width='1' height='1' style='\(style)'/>"))
        XCTAssertEqual(result.steps, 2 + 4 * 900 / 64)
        // And a fifth time for its longest declaration where it declares one: 1,900 bytes.
        let dashed = String(repeating: "stroke-dasharray:1;", count: 100)
        result = verdict(svg("", "<path d='M0 0h1' style='\(dashed)'/>"))
        XCTAssertEqual(result.copies, 18, "the longest declaration, `stroke-dasharray:1`")
        XCTAssertEqual(result.steps, 2 + 5 * 1_900 / 64)

        // The text of a `<style>` inside a `<style>` is the text of both, and is read for both.
        result = verdict(svg("", rect, pre: "<style><style>\(sheet)</style></style>"))
        XCTAssertEqual(result.copies, 3)
        XCTAssertEqual(result.steps, 2 + 2 * (1_400 + 1_400 + 800) / 64)

        // The readings spend from the walk's budget, and stop when that is gone.
        result = verdict(svg("", rect, pre: "<style>\(sheet)</style>"), stepBudget: 10)
        XCTAssertFalse(result.withinLimits, "the reading refuses when the budget runs out")
        XCTAssertEqual(result.steps, 1_400 / 64, "at the first reading: no other is made, and nothing is walked")
        result = verdict(svg("", "<rect width='1' height='1' style='\(style)'/>"), stepBudget: 10)
        XCTAssertFalse(result.withinLimits)
        XCTAssertEqual(result.steps, 900 / 64, "the font-size reading runs before the copy walk")
    }

    /// A `style` attribute's longest declaration bounds every dash array the attribute declares.
    /// It was once found again for each declaration whose name ends in `dasharray`, so the screen
    /// read the attribute once for each: 4,000 of them, 40 KB, took it five seconds, and 20,000
    /// two minutes. It is now found once, in a reading that is charged, and the charge is what the
    /// steps asserted here pin: five readings of the attribute, whatever it declares.
    ///
    /// The scan as it was, made for each declaration and charged for none, fails on that count,
    /// four readings where five are asserted. It takes no step, so no budget stops it: it fails
    /// when it has run, in seconds here. A reading for each declaration that is charged fails
    /// under the budget of 4,000 given here, which it spends many times over (2,000 readings of
    /// 20,000 bytes are 625,000 steps), so that the drawing is refused; the whole screen
    /// (`isWithinLimits`) has the real budget, a million steps, under which most of those
    /// readings are still made, in seconds too. A second reading that is not charged, added
    /// beside the charged one, is not caught: the steps are the same with it, and this test
    /// passes, only more slowly. No time is asserted here (#62).
    func testAStyleAttributeIsReadOnceForItsDashArrays() throws {
        for (declaration, longest) in [("dasharray:", nil), ("stroke-dasharray:1 2;", 20)] as [(String, Int?)] {
            for count in [500, 1_000, 2_000] {
                let style = String(repeating: declaration, count: count)
                let bytes = style.utf8.count
                let drawing = svg("", "<path d='M0 0h1' style='\(style)'/>")
                let result = verdict(drawing, stepBudget: 4_000)
                XCTAssertTrue(result.withinLimits, "\(count) of `\(declaration)`")
                XCTAssertEqual(result.copies, longest ?? bytes, "the path's dash array is bounded by the longest declaration, as it was")
                XCTAssertEqual(result.steps, 2 + 5 * bytes / 64, "the root and the path, and five readings of the \(bytes) bytes whatever they declare")
                XCTAssertTrue(isWithinLimits(drawing), "the whole screen passes it, as it did before the copies were counted")
            }
        }
        let style = String(repeating: "dasharray:", count: 1_000)
        let stopped = verdict(svg("", "<path d='M0 0h1' style='\(style)'/>"), stepBudget: 100)
        XCTAssertFalse(stopped.withinLimits, "the reading refuses when the budget runs out")
        XCTAssertEqual(stopped.steps, style.utf8.count / 64, "at the font-size reading before the walk")
    }

    /// A declaration can open a comment where the scan for the end of its rule read a string. In
    /// `a{";fill:/*"}` the rule ends at its `}`, and to the scan of its declarations `fill` opens a
    /// comment that nothing closes: the value is charged as far as the comment runs, to the end of
    /// the sheet. Every rule of a sheet can open one, and each once read the rest of the sheet to
    /// find the end: 4,000 rules, 32 KB, took the screen two seconds, and 22,000 most of a minute.
    /// The end is now found once and kept. What each rule is charged is as it was; the steps are
    /// asserted, under a budget that a reading for each rule would spend many times over.
    func testACommentOpenedInEveryRuleIsReadToItsEndOnce() throws {
        let rect = "<rect width='5' height='5'/>"
        for rules in [500, 1_000, 2_000] {
            // Thirteen bytes a rule, ten of them its body; the first rule's `/*` is nine bytes in.
            let sheet = String(repeating: "a{\";fill:/*\"}", count: rules)
            let bytes = sheet.utf8.count
            let drawing = svg("", rect, pre: "<style>\(sheet)</style>")
            var result = verdict(drawing, stepBudget: 4_000)
            XCTAssertTrue(result.withinLimits, "\(rules) rules")
            XCTAssertEqual(result.copies, bytes - 9, "the first rule's `fill`, from its `/*` to the end of the sheet, as it was")
            XCTAssertEqual(result.steps, 2 + (2 * bytes + 10 * rules + bytes - 12) / 64,
                           "the root and the rect; the sheet read twice, each body once, and the first rule's comment to the end of the sheet")
            XCTAssertTrue(isWithinLimits(drawing), "the whole screen passes it, as it did before the copies were counted")

            // A value that runs to the end of the sheet ends before the sheet's trailing white
            // space, which each rule once read back over: that too is found once.
            result = verdict(svg("", rect, pre: "<style>\(sheet)\(String(repeating: " ", count: 4_000))</style>"), stepBudget: 4_000)
            XCTAssertTrue(result.withinLimits)
            XCTAssertEqual(result.copies, bytes - 9, "the white space that ends the sheet is no part of the value")
            XCTAssertEqual(result.steps, 2 + (2 * (bytes + 4_000) + 10 * rules + bytes + 4_000 - 12 + 4_000) / 64,
                           "the white space is read with the sheet, by the comment, and once more to find where it begins")

            // A comment opened where a declaration would begin declares nothing, and ends the same way.
            let bare = String(repeating: "a{\";/*\"}", count: rules)
            result = verdict(svg("", rect, pre: "<style>\(bare)</style>"), stepBudget: 4_000)
            XCTAssertTrue(result.withinLimits)
            XCTAssertEqual(result.copies, 0)
            XCTAssertEqual(result.steps, (2 * bare.utf8.count + 5 * rules + bare.utf8.count - 7) / 64, "nothing to charge, so nothing is walked")
        }

        // A comment that a later `*/` closes ends there, for every rule that opens one before it.
        let closed = String(repeating: "a{\";fill:/*\"}", count: 100) + "*/rect{fill:red}"
        var result = verdict(svg("", rect, pre: "<style>\(closed)</style>"), stepBudget: 1_000)
        XCTAssertEqual(result.copies, 1_302 - 9, "from the first rule's `/*` to the `*/` that closes it")
        XCTAssertEqual(result.steps, 2 + (2 * 1_316 + 100 * 10 + 8 + 1_300 - 11) / 64)

        // A string is read to its end in the same way. In `a{x/*;fill:"*/}` the rule scan reads a
        // comment, and to the scan of its declarations `fill` opens a string, which ends at the
        // quote in the next rule, sixteen bytes on; the last rule's runs to the end of the sheet.
        let strings = String(repeating: "a{x/*;fill:\"*/}", count: 100)
        result = verdict(svg("", rect, pre: "<style>\(strings)</style>"), stepBudget: 1_000)
        XCTAssertEqual(result.copies, 16)
        XCTAssertEqual(result.steps, 2 + (2 * 1_500 + 100 * 12 + 99 * 14 + 3) / 64, "each string read once, fourteen bytes to the next quote")

        let stopped = verdict(svg("", rect, pre: "<style>\(String(repeating: "a{\";fill:/*\"}", count: 1_000))</style>"), stepBudget: 100)
        XCTAssertFalse(stopped.withinLimits, "the reading refuses when the budget runs out")
        XCTAssertEqual(stopped.steps, 13_000 / 64, "at the first reading")
    }

    /// What an element's attributes and `style` declare is read once and kept, however often a
    /// `<use>` draws the element. The readings of a `style` are charged, so the steps show it: a
    /// styled group drawn 64 times takes the steps of five readings of its `style`, where a
    /// screen that kept nothing would repeat four at each of the 64 visits, 5,376 steps for
    /// them, and be refused under the budget given here.
    func testAStyledGroupDrawnThroughUseIsReadOnce() throws {
        // 1,344 bytes of `style`, 21 steps a reading: for a decoration, for the paints and whether
        // a dash array is declared, for the longest declaration, and for the values; with one
        // additional font-size reading before the walk.
        let style = String(repeating: "stroke-dasharray:1 2;", count: 64)
        let drawing = svg("<g id='u' style='\(style)'><rect width='1' height='1'/></g>",
                          String(repeating: "<use xlink:href='#u'/>", count: 64))
        let result = verdict(drawing, stepBudget: 1_000)
        XCTAssertTrue(result.withinLimits)
        XCTAssertEqual(result.copies, 64 * 20, "each rect drawn is charged the group's longest declaration, `stroke-dasharray:1 2`")
        XCTAssertEqual(result.steps, 1 + 64 * 4 + 5 * 1_344 / 64,
                       "the root; for each use the use, the reference it follows, the group and the rect; and the five readings, made once")
    }

    /// The walk of a `<use>` tree takes a step for each element it visits and each reference it
    /// follows, 510 here, and nothing charges a name's bytes: an element whose name is 20,000
    /// bytes long adds no step and no copy to what one named `a` takes. That is all this pins.
    ///
    /// The screen also keeps what each element is to the walk (a shape, a text, a `<use>`, or
    /// not drawn), so that a name is read once for its element and not once for each time a
    /// `<use>` draws it. No count shows that. Reading a name is not charged, so a screen that
    /// read it at every visit would take the same steps and count the same copies, and would
    /// pass this test and every other here: only a time tells the two apart, and none is
    /// asserted (#62).
    func testALongElementNameAddsNoStepToTheWalkOfAUseTree() throws {
        func tree(_ name: String) -> String {
            var definitions = "<g id='t0' fill='red'><\(name)/><rect width='1' height='1'/></g>"
            for level in 1...6 {
                definitions += "<g id='t\(level)'><use xlink:href='#t\(level - 1)'/><use xlink:href='#t\(level - 1)'/></g>"
            }
            return svg(definitions, "<use xlink:href='#t6'/>")
        }
        let short = verdict(tree("a"))
        let long = verdict(tree(String(repeating: "a", count: 20_000)))
        XCTAssertTrue(long.withinLimits)
        XCTAssertEqual(long.copies, short.copies)
        XCTAssertEqual(long.steps, short.steps, "the steps are the walk's, whatever the names are")
        // The root; 127 uses, each visited and followed; the 127 groups they lead to; and in each
        // of the 64 groups at the leaves, the named element and a rect.
        XCTAssertEqual(long.steps, 1 + 127 * 2 + 127 + 64 * 2)
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
