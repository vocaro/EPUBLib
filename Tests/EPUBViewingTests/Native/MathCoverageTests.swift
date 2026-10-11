import EPUBReading
import EPUBTestSupport
@testable import EPUBViewing
import MathMLLayout
import XCTest

/// The MathML the layout engine refuses, and what the reader shows in its place: an `mglyph`
/// as its alternative text, elementary math as a table of digit columns.
final class MathCoverageTests: XCTestCase {
    private typealias F = MathFixtures
    private let style = MathStyle(fontSize: 17, color: CGColor(gray: 0, alpha: 1))

    private func converted(_ body: String) throws -> (node: MathMLNode, glyphs: Int) {
        let section = try MathHarness.section("<p>\(F.math(body))</p>")
        var conversion = MathConversion(keepsColors: true)
        let node = try conversion.convert(try XCTUnwrap(section.formulas.first), depth: 0)
        return (node, conversion.replacedGlyphs)
    }

    /// The token text of each table row, cell by cell (nil: an empty cell).
    private func grid(_ table: MathMLNode) -> [[String?]] {
        table.children.map { row in row.children.map { cell in MathHarness.tokens(cell).first } }
    }

    private func table(_ body: String) throws -> MathMLNode {
        var approximated = false
        let node = MathElementary.rewrite(try MathHarness.node(body), isApproximated: &approximated)
        XCTAssertTrue(approximated)
        func find(_ node: MathMLNode) -> MathMLNode? { node.name == "mtable" ? node : node.children.lazy.compactMap(find).first }
        return try XCTUnwrap(find(node))
    }

    // MARK: What the engine covers

    /// The engine lays out every MathML 3 presentation element but `mglyph` and the seven of
    /// elementary math: those are the coverage gap, apart from any fallback policy.
    func testEngineRefusesOnlyGlyphsAndElementaryMath() {
        let arity = ["mfrac": 2, "mroot": 2, "msub": 2, "msup": 2, "msubsup": 3, "munder": 2, "mover": 2, "munderover": 3]
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
        XCTAssertEqual(refused, MathElementary.elements.union(["mglyph"]))
        let glyph = MathMLNode(name: "math", children: [MathMLNode(name: "mi", children: [MathMLNode(name: "mglyph")])])
        XCTAssertThrowsError(try MathLayout(glyph, style: style)) { XCTAssertEqual($0 as? MathLayoutError, .unsupported("mglyph")) }
    }

    // MARK: mglyph

    func testGlyphShowsItsAlternativeTextWhereItStands() throws {
        let token = try converted(F.glyphInToken)
        XCTAssertEqual(token.glyphs, 1)
        XCTAssertEqual(token.node.children.map(\.name), ["mi", "mo", "mi"])
        XCTAssertEqual(token.node.children[0].text, "braid 23")
        XCTAssertTrue(token.node.children[0].children.isEmpty, "no mglyph is left for the engine to refuse")
        // Between a token's own characters.
        XCTAssertEqual(try converted(F.glyphInText).node.children[0].text, "the rune ansuz sign")
        // Without an `alt` a box marks the place; outside a token (MathML 2) it is text.
        let bare = try converted(F.glyphWithoutAlt)
        XCTAssertEqual(bare.node.children.map(\.text), ["a", MathConversion.missingGlyph, "b"])
        XCTAssertEqual(bare.node.children[1].name, "mo")
        let alone = try converted(F.glyphAlone).node.children[0]
        XCTAssertEqual(alone.children.map(\.name), ["mi", "mtext"])
        XCTAssertEqual(alone.children[1].text, "star")
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

    func testStacksKeepPlaceValuesInColumns() throws {
        // 496 + 28 = 524 with carries over the hundreds and tens.
        let addition = try table(F.addition)
        XCTAssertEqual(grid(addition), [["1", "1", nil], ["4", "9", "6"], ["+", "2", "8"], ["5", "2", "4"]])
        XCTAssertEqual(addition.attributes["rowlines"], "none none solid", "the line rules off the sum")
        XCTAssertEqual(addition.children[0].children[0].children[0].name, "mstyle", "carries are set small")
        XCTAssertEqual(addition.children[0].children[0].children[0].attributes["scriptlevel"], "+1")
        // Partial products move a place left each row.
        let multiplication = try table(F.multiplication)
        XCTAssertEqual(grid(multiplication), [
            [nil, nil, "1", "2", "3"], [nil, "×", "3", "2", "1"], [nil, nil, "1", "2", "3"], [nil, "2", "4", "6", nil],
            ["3", "6", "9", nil, nil], ["3", "9", "4", "8", "3"],
        ])
        XCTAssertEqual(multiplication.attributes["rowlines"], "none solid none none solid")
        // Decimals align on the point, which has a column of its own.
        XCTAssertEqual(grid(try table(F.decimals)), [["1", "2", ".", "5", nil], ["+", "3", ".", "2", "5"], ["1", "5", ".", "7", "5"]])
        // Borrows cross out the digits they change, and only those.
        let subtraction = try table(F.subtraction)
        XCTAssertEqual(grid(subtraction)[0], [nil, nil, nil, "2", "12", nil])
        XCTAssertEqual(subtraction.children[1].children.map { $0.children.first?.name }, [nil, "mn", "mn", "menclose", "menclose", "mn"])
        XCTAssertEqual(subtraction.children[1].children[3].children[0].attributes["notation"], "updiagonalstrike")
        XCTAssertEqual(subtraction.children[2].children.map { $0.children.first?.name }, ["mo", "mn", "mn", "mn", "mn", "mn"])
        // Other alignments.
        let left = try table("<mstack stackalign=\"left\"><mn>12</mn><mn>3</mn></mstack>")
        XCTAssertEqual(grid(left), [["1", "2"], ["3", nil]])
        let comma = try table("<mstack decimalpoint=\",\"><mn>1,5</mn><mn>20</mn></mstack>")
        XCTAssertEqual(grid(comma), [[nil, "1", ",", "5"], ["2", "0", nil, nil]])
    }

    func testLongDivisionKeepsItsParts() throws {
        var approximated = false
        // The default style: divisor, bracket, then the result ruled off over the dividend.
        let division = MathElementary.rewrite(try MathHarness.node(F.longDivision), isApproximated: &approximated).children[0]
        XCTAssertEqual(division.children.map(\.name), ["mn", "mo", "mtable"])
        XCTAssertEqual(division.children[0].text, "3")
        XCTAssertEqual(division.children[1].text, ")")
        let table = division.children[2]
        XCTAssertEqual(table.attributes["align"], "baseline 2", "the divisor stands on the dividend's line")
        XCTAssertTrue(table.attributes["rowlines"]?.hasPrefix("solid ") == true)
        let rows = grid(table)
        XCTAssertEqual(rows[0], [nil, "4", "3", "5", ".", "3"])
        XCTAssertEqual(rows[1], ["1", "3", "0", "6", nil, nil], "the result's digits stand over the dividend's")
        XCTAssertEqual(rows[2], ["1", "2", nil, nil, nil, nil])
        XCTAssertEqual(rows[3], [nil, "1", "0", nil, nil, nil], "each step of the working moves a place right")
        XCTAssertEqual(rows.last, [nil, nil, nil, nil, nil, "1"])
        // The German style reads along the dividend's line; a stacked style is drawn as the default.
        let german = MathElementary.rewrite(try MathHarness.node(F.germanDivision), isApproximated: &approximated).children[0]
        XCTAssertEqual(german.children.map(\.name), ["mtable", "mo", "mn", "mo", "mn"])
        XCTAssertEqual(german.children.dropFirst().map(\.text), [":", "12", "=", "32"])
        XCTAssertEqual(german.children[0].attributes["align"], "baseline 1")
        XCTAssertEqual(grid(german.children[0]), [["3", "8", "4"], ["3", "6", nil], [nil, "2", "4"], [nil, "2", "4"], [nil, nil, "0"]])
        let french = MathElementary.rewrite(try MathHarness.node(F.frenchDivision), isApproximated: &approximated).children[0]
        XCTAssertEqual(french.children.map(\.name), ["mn", "mo", "mtable"])
        // Not a division the reader can set: left for the alttext fallback.
        let short = try MathHarness.node("<mlongdiv><mn>3</mn><mn>12</mn></mlongdiv>")
        approximated = false
        XCTAssertEqual(MathElementary.rewrite(short, isApproximated: &approximated), short)
        XCTAssertFalse(approximated)
    }

    func testElementaryMathLaysOutAndIsDisclosed() throws {
        for (name, body) in F.elementary {
            let made = try MathHarness.make("<p>Work: \(F.math(body))</p>")
            let attachment = try XCTUnwrap(made.attachment, name)
            XCTAssertEqual(made.report.mathFallbacks, 0, name)
            XCTAssertEqual(made.report.mathApproximations, 1, name)
            XCTAssertEqual(made.report.mathReductions, 0, name)
            // A stack of rows, taller than a line of text, astride the baseline as a table sits.
            let bounds = attachment.bounds(lineWidth: 320, height: 0)
            XCTAssertGreaterThan(bounds.height, 17 * 1.5, name)
            XCTAssertLessThan(bounds.minY, 0, name)
            XCTAssertGreaterThan(bounds.maxY, 17 * 0.5, name)
            XCTAssertLessThanOrEqual(bounds.width, 320, name)
            XCTAssertFalse(attachment.label.isEmpty, name)
        }
        XCTAssertEqual(NativeDisclosure.text(for: try MathHarness.make("<p>\(F.math(F.addition))</p>").report),
                       "One formula is shown in a simplified layout.")
        // A stack inside a larger formula is set in place.
        let nested = try MathHarness.make("<p>\(F.math(F.i("s") + F.o("=") + F.addition))</p>")
        XCTAssertNotNil(nested.attachment)
        XCTAssertEqual(nested.report.mathApproximations, 1)
    }

    func testOversizedStacksAreLeftToTheFallback() throws {
        // More columns or rows than arithmetic set by hand has, or rows shifted out of reach.
        let digits = String(repeating: "7", count: 5000)
        let rows = String(repeating: "<mn>1</mn>", count: 400)
        for body in ["<mstack><mn>\(digits)</mn></mstack>", "<mstack>\(rows)</mstack>",
                     "<mstack><msgroup shift=\"64\">\(String(repeating: "<mn>1</mn>", count: 40))</msgroup></mstack>"] {
            let source = try MathHarness.node(body)
            var approximated = false
            XCTAssertEqual(MathElementary.rewrite(source, isApproximated: &approximated), source)
            XCTAssertFalse(approximated)
            let made = try MathHarness.make("<p>\(F.math(body, attributes: "alttext=\"a large sum\""))</p>")
            XCTAssertEqual(made.string?.string, "a large sum")
            XCTAssertEqual(made.report.mathFallbacks, 1)
        }
    }

    func testElementaryMathIsReadRowByRow() throws {
        func label(_ body: String, attributes: String = "") throws -> String? {
            try MathHarness.make("<p>\(F.math(body, attributes: attributes))</p>").attachment?.label
        }
        XCTAssertEqual(try label(F.addition), "carry 1 1, 496, plus 28, line, 524")
        XCTAssertEqual(try label(F.multiplication), "123, times 321, line, 123, 246, 369, line, 39483")
        XCTAssertEqual(try label(F.germanDivision), "long division of 384 by 12, result 32, working: 36, line, 24, 24, line, 0")
        XCTAssertEqual(try label(F.frenchDivision), "long division of 384 by 12, result 32")
        // The author's reading is preferred, as for any formula.
        XCTAssertEqual(try label(F.addition, attributes: "alttext=\"496 plus 28 is 524\""), "496 plus 28 is 524")
    }
}
