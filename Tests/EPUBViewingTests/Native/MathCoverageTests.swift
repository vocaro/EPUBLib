import EPUBReading
import EPUBTestSupport
@testable import EPUBViewing
import MathMLLayout
import XCTest

/// Engine element coverage, preserved glyphs and the reader's elementary-table policy.
final class MathCoverageTests: XCTestCase {
    private typealias F = MathFixtures
    private let style = MathStyle(fontSize: 17, color: CGColor(gray: 0, alpha: 1))

    private func converted(_ body: String) throws -> (node: MathMLNode, glyphs: Int) {
        let section = try MathHarness.section("<p>\(F.math(body))</p>")
        var conversion = MathConversion(keepsColors: true)
        let node = try conversion.convert(try XCTUnwrap(section.formulas.first), depth: 0)
        return (node, conversion.glyphs.count)
    }

    // MARK: What the engine covers

    /// The upgraded engine covers glyphs and elementary math as well as the other elements.
    func testUpgradedEngineSupportsGlyphsAndElementaryMath() {
        let arity = ["mfrac": 2, "mroot": 2, "msub": 2, "msup": 2, "msubsup": 3, "munder": 2, "mover": 2, "munderover": 3, "mlongdiv": 3]
        let presentation = ["mi", "mn", "mo", "mtext", "ms", "mspace", "mglyph", "mrow", "mfrac", "msqrt", "mroot", "mstyle", "merror",
                            "mpadded", "mphantom", "mfenced", "menclose", "msub", "msup", "msubsup", "munder", "mover", "munderover",
                            "mmultiscripts", "mtable", "mlabeledtr", "mtr", "mtd", "maligngroup", "malignmark", "mstack", "mlongdiv",
                            "msgroup", "msrow", "mscarries", "mscarry", "msline", "maction", "semantics", "none", "mprescripts"]
        var refused: Set<String> = []
        for name in presentation {
            let children = (0..<(arity[name] ?? 1)).map { MathMLNode(name: "mn", text: "\($0)") }
            let node = MathMLNode(name: "math", children: [MathMLNode(name: name, children: children)])
            do { _ = try MathLayout(node, style: style) } catch { refused.insert(name) }
        }
        XCTAssertEqual(refused, [])
    }

    // MARK: mglyph

    func testGlyphKeepsItsImageAttributesAndPlaceInTokenText() throws {
        let token = try converted(F.glyphInToken)
        XCTAssertEqual(token.glyphs, 1)
        XCTAssertEqual(token.node.children.map(\.name), ["mi", "mo", "mi"])
        XCTAssertEqual(token.node.children[0].text, "\u{FFFC}")
        XCTAssertEqual(token.node.children[0].children.first?.attributes["src"], "braid.png")
        XCTAssertEqual(token.node.children[0].children.first?.attributes["alt"], "braid 23")
        // Between a token's own characters.
        XCTAssertEqual(try converted(F.glyphInText).node.children[0].text, "the \u{FFFC} sign")
        // Without an `alt` a box marks the place; outside a token (MathML 2) it is text.
        let bare = try converted(F.glyphWithoutAlt)
        XCTAssertEqual(bare.node.children.map(\.text), ["a", "\u{FFFC}", "b"])
        XCTAssertEqual(bare.node.children[1].name, "mo")
        let alone = try converted(F.glyphAlone).node.children[0]
        XCTAssertEqual(alone.children.map(\.name), ["mi", "mglyph"])
        XCTAssertEqual(alone.children[1].attributes["alt"], "star")
        // A formula without glyphs converts as before.
        XCTAssertEqual(try converted("<mi>x</mi>").glyphs, 0)
    }

    func testGlyphFormulasLayOutAndAreDisclosed() throws {
        for body in [F.glyphInToken, F.glyphInText, F.glyphWithoutAlt, F.glyphAlone] {
            let made = try MathHarness.make("<p>\(F.math(body))</p>")
            let attachment = try XCTUnwrap(made.attachment, body)
            XCTAssertGreaterThan(attachment.layout.width, 0)
            XCTAssertEqual(made.report.mathFallbacks, 0, "the rest of the formula is still laid out")
            XCTAssertEqual(made.report.mathApproximations, 1, body)
            XCTAssertFalse(attachment.label.isEmpty)
        }
        // The glyph's name is drawn: the formula is wider with it than without.
        let named = try XCTUnwrap(MathHarness.make("<p>\(F.math(F.glyphInToken))</p>").attachment).layout.width
        let unnamed = try XCTUnwrap(MathHarness.make("<p>\(F.math("<mi></mi><mo>=</mo><mi>x</mi>"))</p>").attachment).layout.width
        XCTAssertGreaterThan(named, unnamed + 17 * 2)
        // It is read where it stands, and an author's alttext still wins.
        XCTAssertEqual(try MathHarness.make("<p>\(F.math(F.glyphInToken))</p>").attachment?.label, "braid 23 equals x")
        XCTAssertEqual(try MathHarness.make("<p>\(F.math(F.glyphInToken, attributes: "alttext=\"the braid is x\""))</p>").attachment?.label,
                       "the braid is x")
        XCTAssertEqual(NativeDisclosure.text(for: try MathHarness.make("<p>\(F.math(F.glyphAlone))</p>").report),
                       "One formula is shown in a simplified layout.")
    }

    // MARK: Elementary math

    func testElementaryMathUsesNativeLayoutsWithoutApproximation() throws {
        for (name, body) in F.elementary {
            let made = try MathHarness.make("<p>\(F.math(body, attributes: "display='block'"))</p>")
            let attachment = try XCTUnwrap(made.attachment, name)
            XCTAssertEqual(made.report.mathFallbacks, 0, name)
            XCTAssertEqual(made.report.mathApproximations, 0, name)
            XCTAssertEqual(attachment.formula.node, try MathHarness.node(body, attributes: "display='block'"), "the source's elementary attributes reach the engine")
            XCTAssertGreaterThan(attachment.layout.ascent + attachment.layout.descent, 17, name)
            XCTAssertFalse(attachment.label.isEmpty, name)
        }
        XCTAssertNil(NativeDisclosure.text(for: try MathHarness.make("<p>\(F.math(F.addition))</p>").report))
    }

    func testAllTenLongDivisionStylesReachTheNativeEngine() throws {
        let styles = ["lefttop", "stackedrightright", "mediumstackedrightright", "shortstackedrightright", "righttop",
                      "left/\\right", "left)(right", ":right=right", "stackedleftleft", "stackedleftlinetop"]
        var widths: Set<Int> = []
        for name in styles {
            let body = "<mlongdiv longdivstyle='\(name)'><mn>12</mn><mn>32</mn><mn>384</mn><mn>36</mn><msline length='2'/><mn>24</mn></mlongdiv>"
            let made = try MathHarness.make("<p>\(F.math(body))</p>")
            let attachment = try XCTUnwrap(made.attachment, name)
            XCTAssertEqual(made.report.mathApproximations, 0, name)
            XCTAssertEqual(made.report.mathFallbacks, 0, name)
            XCTAssertEqual(attachment.formula.node.children[0].attributes["longdivstyle"], name)
            widths.insert(Int(attachment.layout.width * 100))
        }
        XCTAssertGreaterThan(widths.count, 4, "the engine's division styles keep their distinct geometry")
    }

    func testElementaryAttributesChangeTheDrawing() throws {
        func signature(_ attributes: String, _ carry: String = "n", _ line: String = "length='1'") throws -> Data {
            let body = "<mstack \(attributes)><mscarries location='\(carry)'><mn>1</mn></mscarries><mn>123</mn><msline \(line)/><mn>456</mn></mstack>"
            let attachment = try XCTUnwrap(MathHarness.make("<p>\(F.math(body))</p>").attachment)
            let image = RichMediaImages.bitmap(width: 180, height: 180) { context, _ in
                attachment.layout.draw(in: context, baselineOrigin: CGPoint(x: 20, y: 90))
            }
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        let ordinary = try signature("")
        XCTAssertNotEqual(ordinary, try signature("", "s"), "carry location is honored")
        XCTAssertNotEqual(ordinary, try signature("", "n", "length='3'"), "finite rules keep their lengths")
        XCTAssertNotEqual(ordinary, try signature("charspacing='1em'"), "authored column spacing is honored")
        XCTAssertNotEqual(ordinary, try signature("", "n", "length='1' mslinethickness='3px'"), "authored rule thickness is honored")
    }

    func testElementarySpeechIncludesColumnsCarriesAndRuleExtent() throws {
        let made = try XCTUnwrap(MathHarness.make("<p>\(F.math(F.addition))</p>").attachment)
        XCTAssertTrue(made.label.contains("column"), made.label)
        XCTAssertTrue(made.label.contains("carr"), made.label)
        XCTAssertTrue(made.label.contains("line"), made.label)
        let authored = try MathHarness.make("<p>\(F.math(F.addition, attributes: "alttext='496 plus 28 is 524'"))</p>")
        XCTAssertEqual(authored.attachment?.label, "496 plus 28 is 524")
    }
}
