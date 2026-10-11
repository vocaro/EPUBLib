import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import MathMLLayout
import XCTest
@testable import EPUBViewing

/// MathML presentation coverage: namespace forms, display vs inline, the presentation elements
/// the engine lays out, token attributes, `semantics`, content-MathML fallback, elementary math
/// and long division, wide-formula breaking boundaries, math in document contexts, hostile input,
/// and named-entity decoding.
final class RichMediaMathCoverageTests: XCTestCase {
    private typealias F = MathFixtures

    private func made(_ body: String, attributes: String = "") throws -> MathHarness.Made {
        try MathHarness.make("<p>\(F.math(body, attributes: attributes))</p>")
    }

    // MARK: Namespaces and display

    func testNamespaceFormsAllLayOut() throws {
        let frac = F.frac(F.i("a"), F.i("b"))
        // Default xmlns on <math>.
        XCTAssertNotNil(try made(frac).attachment)
        // An `m:` prefix on every element.
        let prefixed = "<p><m:math xmlns:m=\"http://www.w3.org/1998/Math/MathML\"><m:mfrac><m:mi>a</m:mi><m:mi>b</m:mi></m:mfrac></m:math></p>"
        XCTAssertNotNil(try MathHarness.make(prefixed).attachment, "a prefixed MathML namespace lays out")
        // No namespace at all in an HTML-parsed document.
        let html = "<html><head><title>T</title></head><body><p><math><mfrac><mi>a</mi><mi>b</mi></mfrac></math></p></body></html>"
        let text = try RichMediaBook(section: html).build()
        XCTAssertEqual(text.richMediaFormulas.count, 1, "no-namespace MathML in HTML-parsed content still becomes a formula")
    }

    func testDisplayBlockIsACentredParagraphAndInlineKeepsItsLine() throws {
        func paragraph(_ attributes: String) throws -> (plain: String, alignment: NSTextAlignment?, height: CGFloat) {
            let text = try RichMediaBook(body: "<p>Before</p>\(F.math(F.frac(F.i("a"), F.i("b")), attributes: attributes))<p>After</p>").build()
            let location = try XCTUnwrap(text.richMediaAttachments.first).location
            let style = text.string.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            return (text.richMediaPlain, style?.alignment, text.richMediaFormulas.first.map { $0.layout.ascent + $0.layout.descent } ?? 0)
        }
        let block = try paragraph("display=\"block\"")
        XCTAssertEqual(block.plain, "Before\n\u{FFFC}\nAfter", "a display formula is its own paragraph")
        XCTAssertEqual(block.alignment, .center, "and is centred")
        let inline = try paragraph("")
        XCTAssertEqual(inline.plain, "Before\n\u{FFFC}\nAfter")
        XCTAssertEqual(inline.alignment, .natural, "an inline formula keeps the paragraph's alignment")
        XCTAssertGreaterThan(block.height, inline.height, "display style is larger than inline")
        // `mode="display"` is the legacy MathML 2 spelling and also uses display style.
        XCTAssertEqual(try paragraph("mode=\"display\"").height, block.height, accuracy: 0.01)
    }

    // MARK: Element coverage

    func testPresentationElementsLayOutWithoutFallback() throws {
        let bodies: [String: String] = [
            "mtable": "<mtable columnalign='left center' rowlines='solid'><mtr><mtd columnspan='2'><mi>a</mi></mtd></mtr><mtr><mtd><mi>b</mi></mtd><mtd><mi>c</mi></mtd></mtr></mtable>",
            "menclose": "<menclose notation='box updiagonalstrike'><mn>12</mn></menclose>",
            "mmultiscripts": "<mmultiscripts><mi>X</mi><mn>1</mn><mn>2</mn><mprescripts/><mn>4</mn><none/></mmultiscripts>",
            "munderover": "<munderover><mo>&#x2211;</mo><mrow><mi>i</mi><mo>=</mo><mn>0</mn></mrow><mi>n</mi></munderover>",
            "mroot": "<mroot><mrow><mn>1</mn><mo>+</mo><mi>x</mi></mrow><mn>3</mn></mroot>",
            "mpadded": "<mpadded width='+0.5em' voffset='-1ex'><mi>x</mi></mpadded>",
            "mphantom": "<mrow><mi>a</mi><mphantom><mi>b</mi></mphantom></mrow>",
            "mspace-neg": "<mrow><mi>a</mi><mspace width='-0.2em'/><mi>b</mi></mrow>",
            "maction": "<maction actiontype='toggle' selection='2'><mi>a</mi><mi>b</mi></maction>",
            "merror": "<merror><mtext>bad</mtext></merror>",
            "ms": "<ms lquote='&#xAB;' rquote='&#xBB;'>text</ms>",
            "stretchy": "<mrow><mo>(</mo><mfrac><mfrac><mi>a</mi><mi>b</mi></mfrac><mi>c</mi></mfrac><mo>)</mo></mrow>",
            "mfenced": "<mfenced open='[' close=')' separators=';,'><mi>a</mi><mi>b</mi><mi>c</mi></mfenced>",
        ]
        for (name, body) in bodies {
            let made = try made(body)
            let attachment = try XCTUnwrap(made.attachment, name)
            XCTAssertGreaterThan(attachment.layout.width, 0, "\(name) has width")
            XCTAssertEqual(made.report.mathFallbacks, 0, "\(name) lays out natively")
        }
    }

    func testTokenAttributesAndSemantics() throws {
        // Token attributes do not force a fallback.
        let tokens = try made("<mi mathvariant='double-struck'>R</mi><mn mathsize='150%' mathcolor='red' mathbackground='#ff0'>1</mn><mtext dir='rtl'>&#x5D0;&#x5D1;</mtext>")
        XCTAssertNotNil(tokens.attachment)
        XCTAssertEqual(tokens.report.mathFallbacks, 0)
        // semantics draws only the presentation child; annotations are dropped, so width matches the bare row.
        let bare = try made(F.row(F.frac(F.i("a"), F.i("b")), F.o("+"), F.n("1")))
        let wrapped = try made("<semantics>" + F.row(F.frac(F.i("a"), F.i("b")), F.o("+"), F.n("1"))
            + "<annotation encoding='application/x-tex'>\\frac{a}{b}+1</annotation>"
            + "<annotation-xml encoding='MathML-Content'><apply><plus/><ci>a</ci></apply></annotation-xml></semantics>")
        XCTAssertEqual(wrapped.attachment?.layout.width, bare.attachment?.layout.width, "annotations add nothing to the drawn width")
        XCTAssertEqual(wrapped.attachment?.label, bare.attachment?.label, "and nothing to the reading")
    }

    func testContentMathMLUnknownElementsAndEmptyMathFallBack() throws {
        // Content MathML with no presentation child: the alttext stands in.
        let content = try made("<apply><plus/><ci>x</ci><ci>y</ci></apply>", attributes: "alttext='x plus y'")
        XCTAssertEqual(content.string?.string, "x plus y")
        XCTAssertNil(content.attachment)
        XCTAssertEqual(content.report.mathFallbacks, 1)
        // An unknown element without alttext: its text content stands in.
        let unknown = try made("<mwidget><mn>12</mn></mwidget>")
        XCTAssertEqual(unknown.string?.string, "12")
        XCTAssertEqual(unknown.report.mathFallbacks, 1)
        // An empty elementary stack is nothing; an empty `<math/>` lays out as a zero-width attachment.
        XCTAssertNil(try made("<mstack/>").string)
        let empty = try made("")
        XCTAssertEqual(empty.attachment?.layout.width, 0)
    }

    // MARK: Elementary math

    func testElementaryVariantsLayOutAndAreApproximated() throws {
        for (name, body) in F.elementary {
            let made = try MathHarness.make("<p>Work: \(F.math(body))</p>")
            let attachment = try XCTUnwrap(made.attachment, name)
            XCTAssertGreaterThan(attachment.layout.width, 0, name)
            XCTAssertEqual(made.report.mathFallbacks, 0, name)
            XCTAssertEqual(made.report.mathApproximations, 1, "\(name) is disclosed as a simplified layout")
            XCTAssertFalse(attachment.label.isEmpty, name)
        }
    }

    func testLongDivisionStylesAndDegenerateStacks() throws {
        func parts(_ style: String) throws -> [String] {
            let body = "<mlongdiv longdivstyle=\"\(style)\"><mn>12</mn><mn>32</mn><mn>384</mn><msgroup position=\"1\"><mn>36</mn><msline/></msgroup><mn>24</mn></mlongdiv>"
            var approximated = false
            return MathElementary.rewrite(try MathHarness.node(body), isApproximated: &approximated).children[0].children.map(\.name)
        }
        // The four documented styles place the divisor/result around the table distinctly.
        XCTAssertEqual(try parts("lefttop"), ["mn", "mo", "mtable"])
        XCTAssertEqual(try parts("left/\\right"), ["mn", "mo", "mtable", "mo", "mn"])
        XCTAssertEqual(try parts("left)(right"), ["mn", "mo", "mtable", "mo", "mn"])
        XCTAssertEqual(try parts(":right=right"), ["mtable", "mo", "mn", "mo", "mn"])
        // The other six styles are drawn as lefttop.
        for style in ["stackedrightright", "mediumstackedrightright", "righttop", "stackedleftleft"] {
            XCTAssertEqual(try parts(style), ["mn", "mo", "mtable"], "\(style) draws as lefttop")
        }
        // Degenerate stacks never crash: some lay out empty, some fall back to alttext.
        for body in ["<mstack><msline/></mstack>", "<mstack><mscarries/></mstack>", "<mstack><none/></mstack>",
                     "<mlongdiv><mn>3</mn><mn>4</mn><msline/></mlongdiv>", "<mstack><mscarries><mn>1</mn></mscarries></mstack>",
                     "<mstack><mn>1</mn><msgroup position='9999999999999999999999' shift='-99'><mn>2</mn><mn>3</mn></msgroup></mstack>"] {
            let made = try made(body, attributes: "alttext='alt'")
            XCTAssertTrue(made.attachment != nil || made.string?.string == "alt", "\(body): lays out or falls back, never crashes")
        }
        // An oversized stack is left to the alttext.
        let huge = try made("<mstack><mn>\(String(repeating: "7", count: 5000))</mn></mstack>", attributes: "alttext='a large number'")
        XCTAssertEqual(huge.string?.string, "a large number")
        XCTAssertEqual(huge.report.mathFallbacks, 1)
    }

    func testElementaryMathIsReadRowByRow() throws {
        XCTAssertEqual(try made(F.addition).attachment?.label, "carry 1 1, 496, plus 28, line, 524")
        XCTAssertEqual(try made(F.germanDivision).attachment?.label, "long division of 384 by 12, result 32, working: 36, line, 24, 24, line, 0")
    }

    // MARK: Wide-formula breaking

    func testWideFormulaShrinksThenBreaksAtTheThreeQuarterBoundary() throws {
        let formula = try MathHarness.formula(F.polynomial.body, attributes: "display=\"block\"")
        let natural = formula.natural.width
        // At or above three quarters it stays one shrunken row; just below it breaks into rows at full size.
        XCTAssertEqual(formula.arrangement(fitting: natural * 0.76).rows.count, 1)
        XCTAssertEqual(formula.arrangement(fitting: natural * MathFormula.minimumScale).rows.count, 1, "exactly three quarters still shrinks")
        let broken = formula.arrangement(fitting: natural * 0.7499)
        XCTAssertGreaterThan(broken.rows.count, 1, "below three quarters it breaks")
        XCTAssertEqual(MathFormula.scale(of: broken, in: natural * 0.7499), 1, accuracy: 0.001, "broken rows are at full size")
    }

    func testForcedBreaksApplyAtEveryWidthAndNoBreakUnitShrinksWhole() throws {
        let authored = try MathHarness.formula(F.authoredBreaks.body, attributes: "display=\"block\"")
        XCTAssertEqual(authored.natural.rows.count, 3, "two newline breaks make three rows with room to spare")
        XCTAssertEqual(authored.arrangement(fitting: 2000).rows.count, 3, "and at a very wide line")
        XCTAssertEqual(authored.arrangement(fitting: 0).rows.count, 3, "and unbounded")
        // A one-fraction formula has nowhere to break: it shrinks whole, below three quarters when it must.
        let fraction = try MathHarness.formula(F.wideFraction.body, attributes: "display=\"block\"")
        let narrow = fraction.arrangement(fitting: MathFormula.narrowColumn)
        XCTAssertEqual(narrow.rows.count, 1)
        XCTAssertLessThan(MathFormula.scale(of: narrow, in: MathFormula.narrowColumn), MathFormula.minimumScale)
        XCTAssertTrue(fraction.isReduced(in: MathFormula.narrowColumn))
    }

    func testContinuationRowsIndentTwoEmsWhenThereIsNoNearLeftRelation() throws {
        // A long sum with no leading relation near the left edge: continuation rows indent two ems.
        for fontSize in [CGFloat(17), 28] {
            let sum = (0..<30).map { "<msub><mi>a</mi><mn>\($0)</mn></msub>" }.joined(separator: "<mo>+</mo>")
            let rows = try MathHarness.formula(sum, attributes: "display=\"block\"", fontSize: fontSize).arrangement(fitting: 320)
            XCTAssertGreaterThan(rows.rows.count, 1, "\(fontSize)")
            let indent = min(2 * fontSize, 320 * 0.15)
            for row in rows.rows.dropFirst() {
                XCTAssertEqual(row.x, indent, accuracy: 0.5, "continuation rows indent two ems at \(fontSize)")
            }
            XCTAssertEqual(rows.rows[0].x, 0, "the first row starts at the left edge")
        }
    }

    // MARK: Math in document contexts

    func testFormulasInHeadingsCellsLinksListsAndFootnotes() throws {
        let m = F.math(F.frac(F.i("a"), F.i("b")))
        let body = "<h1>Head \(m)</h1><p>Para <a href='two.xhtml'>link \(m)</a></p><ul><li>Item \(m)</li></ul><table><tr><td>Cell \(m)</td><td>Other</td></tr></table><p>Ref<a epub:type='noteref' href='#n1'>1</a></p><aside epub:type='footnote' id='n1'><p>Note \(m)</p></aside>"
        let text = try RichMediaBook(body: body).build()
        // Heading, the link, and the list item carry a top-level formula.
        XCTAssertEqual(text.richMediaFormulas.count, 3, "formulas render in the heading, link and list contexts")
        let linked = try XCTUnwrap(text.richMediaAttachments.first { $0.attachment is MathAttachment && text.string.attribute(.link, at: $0.location, effectiveRange: nil) != nil })
        XCTAssertNotNil(text.string.attribute(.link, at: linked.location, effectiveRange: nil), "a formula inside a link keeps the link")
        // The 2-column table's cell formula is drawn inside the table's own attachment.
        XCTAssertTrue(text.richMediaAttachments.contains { $0.attachment is TableRowAttachment }, "the table cell's formula is inside the table attachment")
        // The footnote is hidden from the flow; its captured content keeps the formula.
        let note = try XCTUnwrap(text.notes["n1"])
        var noteHasFormula = false
        note.enumerateAttribute(.attachment, in: NSRange(location: 0, length: note.length)) { value, _, _ in if value is MathAttachment { noteHasFormula = true } }
        XCTAssertTrue(noteHasFormula, "the footnote's content keeps its formula")
    }

    func testCharactersAndLabelsDoNotDependOnTypographyOrColumn() throws {
        let body = "<p>\(F.math(F.polynomial.body, attributes: "display=\"block\""))</p><p>\(F.math(F.frac(F.i("a"), F.i("b")), attributes: "alttext='a over b'"))</p>"
        let book = try RichMediaBook(body: body)
        let small = book.build(fontSize: 12), large = book.build(fontSize: 30, dark: true)
        XCTAssertEqual(small.richMediaPlain, large.richMediaPlain, "the section's characters do not depend on the font size or appearance")
        XCTAssertEqual(small.map.length, large.map.length, "nor does its text map")
        XCTAssertEqual(small.richMediaFormulas.map(\.label), large.richMediaFormulas.map(\.label), "nor the spoken readings")
    }

    // MARK: Hostile input

    func testDeepNestingAndLongRowsStayBounded() throws {
        // 100-deep roots exceed the engine's conversion depth and fall back to alttext.
        let deep = String(repeating: "<msqrt>", count: 100) + "<mi>x</mi>" + String(repeating: "</msqrt>", count: 100)
        XCTAssertEqual(try made(deep, attributes: "alttext='deep'").string?.string, "deep")
        // 2,000 tokens lay out, break into rows and stay within the column.
        let long = (0..<1000).map { "<mi>x</mi><mo>\($0 % 7 == 0 ? "=" : "+")</mo>" }.joined() + "<mn>1</mn>"
        let formula = try MathHarness.formula(long, attributes: "display=\"block\"")
        let arrangement = formula.arrangement(fitting: 320)
        XCTAssertLessThanOrEqual(arrangement.width * MathFormula.scale(of: arrangement, in: 320), 320.5)
        XCTAssertLessThanOrEqual(formula.breaks.opportunities.count, MathBreaks.maximumOpportunities)
        // A 60x60 table lays out and is bounded to the column.
        let table = try made("<mtable>" + String(repeating: "<mtr>" + String(repeating: "<mtd><mn>1</mn></mtd>", count: 60) + "</mtr>", count: 60) + "</mtable>")
        let bounds = try XCTUnwrap(table.attachment).bounds(lineWidth: 320, height: 500)
        XCTAssertLessThanOrEqual(bounds.width, 320.5)
        XCTAssertLessThanOrEqual(bounds.height, 500.5)
    }

    // MARK: Named entities — MathML 3 / the MathML DTD's entity set

    /// MathML commonly uses named entities such as `&InvisibleTimes;` and `&PlusMinus;`
    /// (MathML 3 Appendix; the MathML DTD). The native viewer documents that "Named HTML
    /// entities become numeric references before an XML parse", but the conversion uses
    /// libxml2's HTML4 entity table, which lacks the MathML-only names. In a document with the
    /// XHTML+MathML DOCTYPE (the usual way such entities are authored) the undeclared entities
    /// are dropped, so `a &InvisibleTimes; b &PlusMinus; c` renders and is spoken as "a b c" —
    /// the plus-minus operator is lost. (Without a DOCTYPE the same entities instead leak as the
    /// literal text "&PlusMinus;" and the whole section loses CFI support.)
    func testNamedMathMLEntitiesAreDecoded() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/100")
        let doc = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN\" \"http://www.w3.org/Math/DTD/mathml2/xhtml-math11-f.dtd\">\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><p>\(F.math("<mi>a</mi><mo>&InvisibleTimes;</mo><mi>b</mi><mo>&PlusMinus;</mo><mi>c</mi>"))</p></body></html>"
        let text = try RichMediaBook(section: doc).build()
        let formula = try XCTUnwrap(text.richMediaFormulas.first)
        let tokens = MathHarness.tokens(formula.formula.node)
        XCTAssertTrue(tokens.contains("\u{B1}"), "the plus-minus operator must be decoded to ± and kept, not dropped: \(tokens)")
        XCTAssertFalse(formula.label.contains("&"), "and nothing must leak into the spoken reading: \(formula.label)")
    }
}
