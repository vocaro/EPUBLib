import EPUBReading
import EPUBTestSupport
@testable import EPUBViewing
import MathMLLayout
import XCTest

/// Builds `<math>` elements through `MathContent` as a section build does, in a book whose
/// language and markup the test chooses.
enum MathHarness {
    struct Made {
        let string: NSAttributedString?
        let report: SectionReport
        var attachment: MathAttachment? {
            guard let string, string.length == 1 else { return nil }
            return string.attribute(.attachment, at: 0, effectiveRange: nil) as? MathAttachment
        }
    }

    /// The `math` elements of `body` and a context for them. `language` is the publication's
    /// `dc:language` (nil: it declares none); `root` is attributes for the `html` element.
    static func section(_ body: String, language: String? = "en", root: String = "", fontSize: CGFloat = 17,
                        dark: Bool = false) throws -> (formulas: [ContentNode], context: RichContentContext) {
        let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\" \(root)><body>\(body)</body></html>"
        var files = try Fixture.files()
        let package = String(decoding: try XCTUnwrap(files["OPS/book.opf"]), as: UTF8.self)
            .replacingOccurrences(of: "<dc:language>en</dc:language>", with: language.map { "<dc:language>\($0)</dc:language>" } ?? "")
        files["OPS/book.opf"] = Data(package.utf8)
        files["OPS/one.xhtml"] = Data(xhtml.utf8)
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        let document = try ContentDocument.parse(Data(xhtml.utf8), path: "OPS/one.xhtml")
        let context = RichContentContext(
            publication: publication, document: document, spineIndex: 0,
            typography: NativeTypography(fontSize: fontSize, isDark: dark), fonts: FontRegistry(publication: publication),
            style: { _, parent in parent }, renderContent: { element, _ in NSAttributedString(string: element.textContent) },
            resolve: { _ in nil }, report: SectionReportBox())
        let formulas = document.nodes.filter { $0.namespace == ContentNamespace.mathML && $0.name == "math" }
        return (formulas, context)
    }

    /// The first formula of `body` (whole `math` elements, in any markup around them).
    static func make(_ body: String, language: String? = "en", root: String = "", fontSize: CGFloat = 17) throws -> Made {
        let section = try section(body, language: language, root: root, fontSize: fontSize)
        let result = MathContent.make(try XCTUnwrap(section.formulas.first), style: ComputedStyle(fontSize: fontSize), context: section.context)
        return Made(string: result, report: section.context.report.report)
    }

    static func make(_ formula: MathFixtures.Formula, fontSize: CGFloat = 17) throws -> Made {
        try make("<p>\(formula.markup)</p>", fontSize: fontSize)
    }

    static func node(_ body: String, attributes: String = "") throws -> MathMLNode {
        try MathMLNode.parse(xml: Data(MathFixtures.math(body, attributes: attributes).utf8))
    }

    static func formula(_ body: String, attributes: String = "", fontSize: CGFloat = 17) throws -> MathFormula {
        try MathFormula(try node(body, attributes: attributes),
                        style: MathStyle(fontSize: fontSize, color: CGColor(gray: 0, alpha: 1), isDisplay: attributes.contains("block")))
    }

    /// The text of every token under `node`, in order, without the empty operands rows start with.
    static func tokens(_ node: MathMLNode) -> [String] {
        if ["mi", "mn", "mo", "mtext", "ms"].contains(node.name) {
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [text]
        }
        return node.children.flatMap(tokens)
    }
}

/// Where a wide formula may break into rows, and the rows each line width gives it.
final class MathBreakingTests: XCTestCase {
    private typealias F = MathFixtures

    private func kinds(_ body: String) throws -> [MathBreaks.Opportunity] {
        MathBreaks(try MathHarness.node(body)).opportunities
    }

    func testRowsMayEndBeforeRelationsAndBinaryOperators() throws {
        // x = a + b − c: a break before the relation and before each binary operator.
        let found = try kinds(F.i("x") + F.o("=") + F.i("a") + F.o("+") + F.i("b") + F.o("-") + F.i("c"))
        XCTAssertEqual(found.map(\.kind), [.relation, .binary, .binary])
        XCTAssertEqual(found.map(\.path), [[1], [3], [5]])
        XCTAssertTrue(found.allSatisfy { $0.penalty == 0 && !$0.isForced })
        // A sign is no place to break: after a relation, an operator or an opening bracket, or first.
        XCTAssertEqual(try kinds(F.o("−") + F.i("a") + F.o("=") + F.o("−") + F.i("b") + F.o("×") + F.o("−") + F.i("c")).map(\.path), [[2], [5]])
        // Nothing breaks before an operator that ends its row, a slash, or invisible times.
        XCTAssertTrue(try kinds(F.i("a") + F.o("/") + F.i("b") + F.o("\u{2062}") + F.i("c") + F.o("+")).isEmpty)
        // A factorial or a prime ends an operand, so the sign after it is binary.
        XCTAssertEqual(try kinds(F.i("n") + F.o("!") + F.o("+") + F.i("m")).map(\.kind), [.binary])
        // A row may end after a separator.
        XCTAssertEqual(try kinds(F.i("a") + F.o(",") + F.i("b") + F.o(";") + F.i("c")).map(\.kind), [.separator, .separator])
    }

    func testFractionsRootsScriptsAndTablesStayWhole() throws {
        let inside = F.row(F.i("a"), F.o("+"), F.i("b"), F.o("="), F.i("c"))
        for whole in [F.frac(inside, F.i("d")), F.sqrt(inside), F.sup(F.i("x"), inside), F.table([[inside]]),
                      "<menclose notation=\"box\">\(inside)</menclose>", "<mpadded>\(inside)</mpadded>",
                      "<mfenced>\(inside)</mfenced>"] {
            XCTAssertTrue(try kinds(whole).isEmpty, whole)
        }
    }

    func testBreaksInsideBracketsCostMore() throws {
        // f = (a + b) + c, flat: the first plus is inside the brackets.
        let flat = try kinds(F.i("f") + F.o("=") + F.o("(") + F.i("a") + F.o("+") + F.i("b") + F.o(")") + F.o("+") + F.i("c"))
        XCTAssertEqual(flat.map(\.penalty), [0, 1, 0])
        // The same nested: the brackets' own row is inside them.
        let nested = try kinds(F.i("f") + F.o("=") + F.paren(F.row(F.i("a"), F.o("+"), F.i("b"))) + F.o("+") + F.i("c"))
        XCTAssertEqual(nested.map(\.penalty), [0, 1, 0])
        XCTAssertEqual(nested.map(\.path), [[1], [2, 1, 1], [3]])
        // A bracket with a power still closes, and vertical bars pair up.
        let scripted = try kinds(F.sup(F.o("("), F.n("1")) + F.i("a") + F.o("+") + F.i("b") + F.sup(F.o(")"), F.n("2")) + F.o("+") + F.i("c"))
        XCTAssertEqual(scripted.map(\.penalty), [1, 0])
        let bars = try kinds(F.o("|") + F.i("a") + F.o("+") + F.i("b") + F.o("|") + F.o("≤") + F.o("|") + F.i("a") + F.o("|") + F.o("+") + F.o("|") + F.i("b") + F.o("|"))
        XCTAssertEqual(bars.map(\.penalty), [1, 0, 0])
        XCTAssertEqual(bars.map(\.kind), [.binary, .relation, .binary])
    }

    func testBreaksReachThroughGroupsAndSemantics() throws {
        // As a converter writes it: mstyle, semantics with an annotation, then rows by precedence.
        let found = MathBreaks(try MathHarness.node(F.wrappedSeries.body)).opportunities
        XCTAssertEqual(found.filter { $0.kind == .relation }.count, 2)
        XCTAssertEqual(found.filter { $0.kind == .binary }.count, 9)
        XCTAssertTrue(found.allSatisfy { $0.path.starts(with: [0, 0, 0]) }, "math, mstyle, semantics, then the row")
        // The sum's own "k = 1" is in its limits: not a break.
        XCTAssertFalse(found.contains { $0.path.count > 4 })
    }

    func testEverySliceKeepsItsGroupsAndNoRowLosesOrRepeatsAToken() throws {
        for fixture in F.wide {
            let node = try MathMLNode.parse(xml: Data(fixture.markup.utf8))
            let breaks = MathBreaks(node)
            var tokens: [String] = []
            let ends = Array(breaks.opportunities.indices).map(Optional.some) + [nil]
            var start: Int?
            for end in ends {
                let slice = breaks.slice(from: start, to: end)
                XCTAssertEqual(slice.name, "math")
                XCTAssertEqual(slice.attributes, node.attributes, "a row keeps the formula's own attributes")
                tokens += MathHarness.tokens(slice)
                XCTAssertNoThrow(try MathLayout(slice, style: MathStyle(fontSize: 17, color: CGColor(gray: 0, alpha: 1))), fixture.name)
                start = end
            }
            XCTAssertEqual(tokens, MathHarness.tokens(node), fixture.name)
        }
        // The groups around a nested break are kept on both sides of it.
        let breaks = MathBreaks(try MathHarness.node("<mstyle mathcolor=\"red\">" + F.row(F.i("a"), F.o("="), F.row(F.i("b"), F.o("+"), F.i("c"))) + "</mstyle>"))
        XCTAssertEqual(breaks.opportunities.map(\.path), [[0, 0, 1], [0, 0, 2, 1]])
        let last = breaks.slice(from: 1, to: nil)
        XCTAssertEqual(last.children.map(\.name), ["mstyle"])
        XCTAssertEqual(last.children[0].attributes["mathcolor"], "red")
        let inner = last.children[0].children[0].children[0]
        // The row starts with an empty operand, so its plus is spaced as a binary operator.
        XCTAssertEqual(inner.children.map(\.name), ["mi", "mo", "mi"])
        XCTAssertEqual(inner.children.map(\.text), ["", "+", "c"])
        let plain = try MathLayout(try MathHarness.node(F.o("+") + F.i("c")), style: MathStyle(fontSize: 17, color: CGColor(gray: 0, alpha: 1)))
        let spaced = try MathLayout(last, style: MathStyle(fontSize: 17, color: CGColor(gray: 0, alpha: 1)))
        XCTAssertGreaterThan(spaced.width, plain.width + 17 * 6 / 18, "medium spaces around a binary plus, none around a sign")
    }

    func testAuthorsLinebreaksAreHonoured() throws {
        // `newline` on an operator and on a space, at any width.
        let authored = try MathHarness.formula(F.authoredBreaks.body, attributes: "display=\"block\"")
        XCTAssertEqual(authored.breaks.opportunities.filter(\.isForced).count, 2)
        XCTAssertEqual(authored.natural.rows.count, 3)
        XCTAssertEqual(authored.arrangement(fitting: 2000).rows.count, 3)
        XCTAssertEqual(authored.arrangement(fitting: 0).rows.count, 3)
        XCTAssertGreaterThan(authored.layout.width, authored.natural.width, "the one-row layout is not what is shown")
        // Relations line up under the first one.
        XCTAssertEqual(authored.natural.rows[1].x, authored.natural.rows[2].x, accuracy: 0.01)
        XCTAssertGreaterThan(authored.natural.rows[1].x, 0)
        // `nobreak` removes a break, `goodbreak` adds one, `badbreak` is a last resort and
        // `linebreakstyle="after"` moves the break past the operator.
        let body = F.i("a") + "<mo linebreak=\"nobreak\">=</mo>" + F.i("b") + "<mo linebreak=\"goodbreak\">\u{2062}</mo>" + F.i("c")
            + "<mo linebreak=\"badbreak\">+</mo>" + F.i("d") + "<mo linebreakstyle=\"after\">+</mo>" + F.i("e")
        let found = try kinds(body)
        XCTAssertEqual(found.map(\.path), [[3], [5], [8]])
        XCTAssertEqual(found.map(\.kind), [.authored, .binary, .binary])
        XCTAssertEqual(found.map(\.penalty), [0, 1, 0])
    }

    func testAFormulaShrinksALittleBeforeItBreaks() throws {
        let formula = try MathHarness.formula(F.polynomial.body, attributes: "display=\"block\"")
        let natural = formula.natural.width
        XCTAssertEqual(formula.natural.rows.count, 1)
        // It fits, or shrinking keeps it at three quarters of the text's size or more: one row.
        for width in [natural + 1, natural, natural * 0.9, natural * MathFormula.minimumScale + 1] {
            XCTAssertEqual(formula.arrangement(fitting: width).rows.count, 1, "\(width)")
        }
        // Narrower than that it breaks, and its rows are full size.
        let rows = formula.arrangement(fitting: natural * 0.7)
        XCTAssertGreaterThan(rows.rows.count, 1)
        XCTAssertLessThanOrEqual(rows.width, natural * 0.7)
        XCTAssertTrue(formula.arrangement(fitting: natural * 0.7).rows.count == rows.rows.count, "cached")
    }

    func testRowsFillTheLineAndAlignOnTheFirstRelation() throws {
        let formula = try MathHarness.formula(F.polynomial.body, attributes: "display=\"block\"")
        let rows = formula.arrangement(fitting: 320)
        XCTAssertEqual(rows.rows.count, 3)
        XCTAssertEqual(rows.rows[0].x, 0)
        // Continuation rows start where the right side does: past "p(x) =".
        XCTAssertEqual(rows.rows[1].x, rows.rows[2].x)
        XCTAssertGreaterThan(rows.rows[1].x, 17 * 2)
        for row in rows.rows {
            XCTAssertLessThanOrEqual(row.x + row.layout.width, 320)
            XCTAssertGreaterThan(row.x + row.layout.width, 320 * 0.6, "each row is as full as its terms allow")
        }
        // Baselines step down by at least a line and a half, and rows never overlap.
        for (above, below) in zip(rows.rows, rows.rows.dropFirst()) {
            XCTAssertGreaterThanOrEqual(below.baseline - above.baseline, 1.5 * 17 - 0.01)
            XCTAssertGreaterThanOrEqual(below.baseline - below.layout.ascent, above.baseline + above.layout.descent + 0.4 * 17 - 0.01)
        }
        XCTAssertEqual(rows.height, rows.rows.last!.baseline + rows.rows.last!.layout.descent, accuracy: 0.01)
        // The stack centres on the math axis, as a table would.
        XCTAssertEqual(rows.ascent - rows.descent, 2 * 0.25 * 17, accuracy: 0.01)
        // A derivation ends its rows at relations rather than at the operator after one.
        let derivation = try MathHarness.formula(F.variance.body, attributes: "display=\"block\"").arrangement(fitting: 320)
        XCTAssertEqual(derivation.rows.count, 3)
        XCTAssertEqual(derivation.rows[1].x, derivation.rows[2].x, "each continuation begins with its relation, under the first")
    }

    func testBreaksInsideBracketsAreALastResort() throws {
        // (x + 1)(x + 1)(x + 1) is a little wider than a 28-point line: it shrinks a little
        // rather than break inside a bracket.
        let derivation = try MathHarness.formula(F.derivation.body, attributes: "display=\"block\"", fontSize: 28)
        let outside = derivation.arrangement(fitting: 300)
        XCTAssertEqual(outside.rows.count, 4)
        XCTAssertGreaterThanOrEqual(MathFormula.scale(of: outside, in: 300), MathFormula.minimumScale)
        // A sum wholly inside brackets has nowhere else to break.
        let sum = try MathHarness.formula(F.bracketedSum.body, attributes: "display=\"block\"")
        let inside = sum.arrangement(fitting: 320)
        XCTAssertGreaterThan(inside.rows.count, 2)
        XCTAssertLessThanOrEqual(inside.width, 320)
        XCTAssertGreaterThan(inside.rows[0].layout.width, 320 * 0.5, "the first row is not the left side alone")
    }

    func testAFormulaWithNoBreakShrinksToTheLine() throws {
        for fixture in [F.wideFraction, F.piecewise] {
            let formula = try MathHarness.formula(fixture.body, attributes: "display=\"block\"")
            let arrangement = formula.arrangement(fitting: 320)
            XCTAssertEqual(arrangement.rows.count, 1, "\(fixture.name): rows that gain nothing are not made")
            XCTAssertLessThan(MathFormula.scale(of: arrangement, in: 320), MathFormula.minimumScale)
            XCTAssertTrue(formula.isReduced(in: 320))
            XCTAssertFalse(formula.isReduced(in: 700))
        }
        // One unbreakable row sets the scale; the rows around it refill to its width.
        let words = try MathHarness.formula(F.wordEquation.body, attributes: "display=\"block\"", fontSize: 28)
        let rows = words.arrangement(fitting: 320)
        XCTAssertEqual(rows.rows.count, 2)
        XCTAssertGreaterThan(MathFormula.scale(of: rows, in: 320), MathFormula.scale(of: words.natural, in: 320) * 1.4)
    }

    /// The policy over every wide fixture, at the default size and a large one, in a phone's column.
    func testWideFixturesKeepAReadableSizeInANarrowColumn() throws {
        let column = MathFormula.narrowColumn
        for fontSize in [CGFloat(17), 28] {
            var shrunkenBefore = 0, reduced: [String] = []
            for fixture in F.wide {
                let made = try MathHarness.make(fixture, fontSize: fontSize)
                let attachment = try XCTUnwrap(made.attachment, fixture.name)
                XCTAssertEqual(made.report.mathFallbacks, 0)
                let bounds = attachment.bounds(lineWidth: column, height: 0)
                XCTAssertLessThanOrEqual(bounds.width, column + 0.01, "\(fixture.name) at \(fontSize): never wider than its line")
                XCTAssertGreaterThan(bounds.height, 0)
                let arrangement = attachment.formula.arrangement(fitting: column)
                let scale = bounds.width / arrangement.width
                // Scaling one row to the line, as before, would leave this many unreadably small.
                if column / attachment.layout.width < MathFormula.minimumScale { shrunkenBefore += 1 }
                if scale < MathFormula.minimumScale - 0.001 { reduced.append(fixture.name) }
                if fixture.breaks {
                    XCTAssertGreaterThanOrEqual(scale, MathFormula.minimumScale - 0.001, "\(fixture.name) at \(fontSize)")
                }
                // A formula that rows cannot keep readable is still shown whole, and disclosed.
                XCTAssertEqual(made.report.mathReductions, scale < MathFormula.minimumScale - 0.001 ? 1 : 0, "\(fixture.name) at \(fontSize)")
                // No row is lost: the rows hold every token of the formula.
                XCTAssertGreaterThanOrEqual(arrangement.rows.count, attachment.formula.natural.rows.count)
            }
            XCTAssertGreaterThanOrEqual(shrunkenBefore, 10, "at \(fontSize) most of the wide fixtures were unreadable as one row")
            XCTAssertLessThanOrEqual(reduced.count, F.wide.filter { !$0.breaks }.count, "\(reduced) at \(fontSize)")
            XCTAssertTrue(reduced.contains(F.wideFraction.name) && reduced.contains(F.piecewise.name), "\(reduced)")
        }
        // With a wide column nothing changes: every fixture is one row at full size, but the
        // author's own breaks.
        for fixture in F.wide where fixture.name != F.authoredBreaks.name {
            let attachment = try XCTUnwrap(MathHarness.make(fixture).attachment)
            let bounds = attachment.bounds(lineWidth: 1200, height: 0)
            XCTAssertEqual(bounds.width, attachment.layout.width, accuracy: 0.001, fixture.name)
            XCTAssertEqual(attachment.formula.arrangement(fitting: 1200).rows.count, 1, fixture.name)
        }
    }

    func testHostileFormulasStayBounded() throws {
        // Far more breaks than are looked for: the formula still lays out and fits its line.
        let terms = String(repeating: F.i("x") + F.o("+"), count: 1500) + F.n("1")
        let formula = try MathHarness.formula(terms)
        XCTAssertEqual(formula.breaks.opportunities.count, MathBreaks.maximumOpportunities)
        let arrangement = formula.arrangement(fitting: 320)
        XCTAssertLessThanOrEqual(arrangement.width * MathFormula.scale(of: arrangement, in: 320), 320.01)
        // Rows nested deeper than the engine lays out are refused by it, not walked here.
        let deep = String(repeating: "<mrow>", count: 100) + F.i("a") + F.o("+") + F.i("b") + String(repeating: "</mrow>", count: 100)
        XCTAssertThrowsError(try MathHarness.formula(deep))
    }
}
