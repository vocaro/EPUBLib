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
