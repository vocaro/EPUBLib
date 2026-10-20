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
            guard let string, string.length > 0 else { return nil }
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
            renderNodes: { nodes, _ in NSAttributedString(string: nodes.map(\.textContent).joined()) },
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

/// Width-aware engine layout as integrated into the reader, including structures that the
/// former tree slicer could not wrap.
final class MathBreakingTests: XCTestCase {
    private typealias F = MathFixtures

    func testFormulasWrapAtFullSizeRatherThanShrinkBeforeBreaking() throws {
        let formula = try MathHarness.formula(F.polynomial.body, attributes: "display='block'")
        XCTAssertEqual(formula.natural.rows.count, 1)
        for width in [formula.layout.width * 0.9, 320, 220] {
            let rows = formula.arrangement(fitting: width)
            XCTAssertGreaterThan(rows.rows.count, 1)
            XCTAssertLessThanOrEqual(rows.width, width + 0.01)
            XCTAssertEqual(MathFormula.scale(of: rows, in: width), 1)
            for (above, below) in zip(rows.rows, rows.rows.dropFirst()) {
                XCTAssertGreaterThan(below.baseline - below.layout.ascent, above.baseline + above.layout.descent)
            }
            XCTAssertEqual(rows.ascent - rows.descent, 2 * formula.layout.axisHeight, accuracy: 0.01)
        }
    }

    func testFractionsRadicalsEnclosuresFencesAndTableCellsWrap() throws {
        let sum = (0..<20).map { _ in F.i("x") }.joined(separator: F.o("+"))
        let cases = [F.frac(F.row(sum), F.n("2")), F.sqrt(sum), "<menclose notation='box'>\(sum)</menclose>",
                     "<mfenced>\(sum)</mfenced>", F.table([[F.t("a long phrase whose words must wrap inside this table cell")]])]
        for body in cases {
            let formula = try MathHarness.formula(body, attributes: "display='block'")
            let narrow = formula.arrangement(fitting: 110)
            XCTAssertLessThan(narrow.width, formula.natural.width, body)
            XCTAssertLessThanOrEqual(narrow.width, 110.1, body)
            XCTAssertGreaterThan(narrow.height, formula.natural.height, body)
            XCTAssertFalse(formula.isReduced(in: 110), body)
        }
    }

    func testAuthoredBreaksAndIndentationAreHonored() throws {
        let body = "<mi>a</mi><mo linebreak='newline' indentalign='left' indentshift='2em'>=</mo><mi>b</mi>"
        let formula = try MathHarness.formula(body, attributes: "display='block'")
        for width in [CGFloat(0), 100, 1000] {
            let arrangement = formula.arrangement(fitting: width)
            XCTAssertEqual(arrangement.rows.count, 2)
            XCTAssertEqual(arrangement.rows[1].x, 34, accuracy: 0.01)
        }
        let unbroken = try MathHarness.formula("<mi>a</mi><mo linebreak='nobreak'>+</mo><mi>b</mi>")
        XCTAssertEqual(unbroken.arrangement(fitting: 5).rows.count, 1)
    }

    func testAtomicContentStillScalesUniformlyAndIsDisclosed() throws {
        let body = F.n(String(repeating: "1", count: 100))
        let made = try MathHarness.make("<p>\(F.math(body, attributes: "display='block'"))</p>")
        let attachment = try XCTUnwrap(made.attachment)
        let arrangement = attachment.formula.arrangement(fitting: 320)
        XCTAssertEqual(arrangement.rows.count, 1)
        XCTAssertTrue(attachment.formula.isReduced(in: 320))
        XCTAssertEqual(made.report.mathReductions, 1)
        XCTAssertEqual(attachment.bounds(lineWidth: 320, height: 0).width, 320, accuracy: 0.01)
    }

    func testWideFixtureSurveyAtNormalAndLargeTextSizes() throws {
        for fontSize in [CGFloat(17), 28] {
            for fixture in F.wide {
                let made = try MathHarness.make(fixture, fontSize: fontSize)
                let attachment = try XCTUnwrap(made.attachment, fixture.name)
                let rows = attachment.formula.arrangement(fitting: 320)
                let scale = MathFormula.scale(of: rows, in: 320)
                XCTAssertLessThanOrEqual(rows.width * scale, 320.01, fixture.name)
                XCTAssertGreaterThan(rows.height, 0, fixture.name)
                XCTAssertEqual(made.report.mathFallbacks, 0, fixture.name)
                XCTAssertEqual(made.report.mathReductions, scale < MathFormula.minimumScale ? 1 : 0, fixture.name)
                print("MATH25 survey \(fixture.name) font=\(fontSize) rows=\(rows.rows.count) scale=\(scale)")
            }
        }
    }

    func testHostileFormulasRemainBounded() throws {
        let terms = String(repeating: F.i("x") + F.o("+"), count: 1500) + F.n("1")
        let formula = try MathHarness.formula(terms)
        let arrangement = formula.arrangement(fitting: 320)
        XCTAssertLessThanOrEqual(arrangement.width * MathFormula.scale(of: arrangement, in: 320), 320.01)
        let deep = String(repeating: "<mrow>", count: 100) + F.i("a") + String(repeating: "</mrow>", count: 100)
        XCTAssertThrowsError(try MathHarness.formula(deep))
    }
}
