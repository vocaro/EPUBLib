import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest

final class RecoveryTextPreservationTests: XCTestCase {
    private func book(_ xml: String) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xml]))
    }
    private func page(_ body: String, title: String = "T") -> String {
        "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>\(title)</title></head><body>\(body)</body></html>"
    }
    private func recovered(_ xml: String) throws -> EPUBTextSection {
        let publication = try book(xml)
        XCTAssertThrowsError(try publication.textSection(at: 0))
        let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(section.recoveredAsHTML)
        return section
    }

    func testStrictXMLKeepsTextElementsHeadingsAndMarksAfterTheBody() throws {
        let xml = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>One</p></body>"
            + "<h2 id='heading'>Two <img id='image' alt='α'/></h2>tail<span id='last'>!</span></html>"
        let publication = try book(xml)
        let section = try publication.textSection(at: 0)
        XCTAssertFalse(section.recoveredAsHTML)
        XCTAssertEqual(section.text, "One\nTwo α\ntail!")
        XCTAssertEqual(section.anchors, ["heading": EPUBTextMark(offset: 4, separator: 1),
            "image": EPUBTextMark(offset: 8, separator: 1), "last": EPUBTextMark(offset: 15, separator: 0)])
        XCTAssertEqual(section.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 4, separator: 1), text: "Two α")])
        var limits = EPUBTextExtractionLimits()
        limits.outputBytes = section.text.utf8.count
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits).text, section.text)
        limits.outputBytes -= 1
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
    }

    func testStrictTrailingContentKeepsSuppressionAndStructuralBounds() throws {
        let xml = "<html xmlns='http://www.w3.org/1999/xhtml'><head/><body><p>One</p></body>"
            + "<script id='hidden'>No</script><style>No</style><template>No</template><div><p id='two'>Two</p></div></html>"
        let publication = try book(xml)
        let section = try publication.textSection(at: 0)
        XCTAssertEqual(section.text, "One\nTwo")
        XCTAssertEqual(section.anchors, ["two": EPUBTextMark(offset: 4, separator: 1)])
        for (key, value, name) in [(\EPUBTextExtractionLimits.depth, 2, "depth"), (\.elementCount, 8, "elementCount")] {
            var limits = EPUBTextExtractionLimits(); limits[keyPath: key] = value
            XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded(name))
            }
        }
    }

    func testBangCommentEndsBeforeStraySignsCDATAAndNullRepair() throws {
        let section = try recovered(page("<!-- n --!><p id='p'>p < 0.05 c</p><!-- ignored -->"
            + "<!-- n --!><p id='c'><![CDATA[a < b & c]]>\u{0} done</p>"))
        XCTAssertEqual(section.text, "p < 0.05 c\na < b & c done")
        XCTAssertEqual(section.anchors["p"], EPUBTextMark(offset: 0, separator: 0))
        XCTAssertEqual(section.anchors["c"], EPUBTextMark(offset: 11, separator: 1))
        XCTAssertEqual(try recovered(page("<!-- literal <img alt='Leak'/> <![CDATA[no]]> --!><p>Visible</p>")).text, "Visible")
    }

    func testInvalidNumericReferencesSurviveBodyTitleImageAndMathAlternatives() throws {
        let literal = "&# &#x &#X &#; &#x; &#-1; &#xg; &bogus; &bogus"
        let section = try recovered(page("<h2 id='h'>\(literal)</h2><p><img id='image' alt='x &# y'/></p>"
            + "<math xmlns='http://www.w3.org/1998/Math/MathML' alttext='math &#x tail'><mi>Ignored</mi></math>"
            + "<p><math xmlns='http://www.w3.org/1998/Math/MathML'><semantics><mi>Ignored</mi>"
            + "<annotation encoding='text/plain'>annotation &#; tail</annotation></semantics></math></p>", title: "Title &# tail"))
        XCTAssertEqual(section.title, "Title &# tail")
        XCTAssertEqual(section.text, literal + "\nx &# y\nmath &#x tail\nannotation &#; tail")
        XCTAssertEqual(section.headings.map(\.text), [literal])
        XCTAssertEqual(section.anchors["image"], EPUBTextMark(offset: (literal + "\n").utf8.count, separator: 1))
        XCTAssertEqual(try recovered(page("<p>&#</p><p>&#x</p><p>&#;</p>")).text, "&#\n&#x\n&#;")
        let generated = try recovered(page("<math xmlns='http://www.w3.org/1998/Math/MathML'>"
            + "<unknown value='x &# y'><mi>&#;</mi></unknown></math>"))
        XCTAssertEqual(generated.text, "math(unknown(value=\"x &# y\"; \"&#;\"))")
    }

    func testInvalidReferencesRespectOutputLimitsAndDoNotDecodeCDATA() throws {
        let xml = page("<p id='p'>x &# y</p><p><![CDATA[&# &amp; &#65; <tag>]]></p>")
        let publication = try book(xml)
        let expected = "x &# y\n&# &amp; &#65; <tag>"
        var limits = EPUBTextExtractionLimits(); limits.outputBytes = expected.utf8.count
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits, recoversMalformedMarkup: true).text, expected)
        limits.outputBytes -= 1
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits, recoversMalformedMarkup: true)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
        XCTAssertEqual(try recovered(page("<p>&#65; &#x41; &#65 &#x41 &amp; &bogus;</p>")).text, "A A A A & &bogus;")
    }

    func testRecoveryReferenceRepairCannotHideDeclarationsOrLeakSuppressedText() throws {
        XCTAssertEqual(try recovered(page("<p>before &# tail</p><!-- &# ignored --!>"
            + "<script>const x = '&#';</script><style>p::after { content:'&#x' }</style>"
            + "<template>Hidden &#;</template><p>after</p>")).text, "before &# tail\nafter")
        for body in ["<p>&# <!ENTITY a 'b'></p>", "<!-- &# <!ENTITY a 'b'> --!><p>after</p>", "<img alt='&# <!ENTITY a b>'/>"] {
            XCTAssertThrowsError(try book(page(body)).textSection(at: 0, recoversMalformedMarkup: true)) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent("OPS/one.xhtml"))
            }
        }
    }

    func testUnknownAndSemicolonlessNamedReferencesDoNotTruncateTextOrAttributes() throws {
        let literal = "&amp &copy &bogus &bogus;"
        let section = try recovered(page("<p>\(literal)</b> tail</p><p><img alt='\(literal) tail'/></p>", title: literal + " tail"))
        XCTAssertEqual(section.text, literal + " tail\n" + literal + " tail")
        XCTAssertEqual(section.title, literal + " tail")
    }

    func testBangCommentEndingCannotHideAttributeBoundsOrDeclarations() throws {
        let attributes = (0..<1023).map { " a\($0)=''" }.joined()
        let passing = page("<!-- n --!><p id='p'\(attributes)>x &# tail</p>")
        XCTAssertEqual(try recovered(passing).text, "x &# tail")
        let overflowing = passing.replacingOccurrences(of: "id='p'", with: "id='p' extra=''")
        XCTAssertThrowsError(try book(overflowing).textSection(at: 0, recoversMalformedMarkup: true)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("attributesPerElement"))
        }
        XCTAssertThrowsError(try book(page("<!-- n --!><!ENTITY a 'b'><p>after</p>")).textSection(at: 0, recoversMalformedMarkup: true)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent("OPS/one.xhtml"))
        }
    }

    func testNumericReferencesCannotImpersonateRecoveryPlaceholders() throws {
        let common = (UInt32(0xFDD0)...0xFDEF).map { "&#x\(String($0, radix: 16));" }.joined()
        let expectedCommon = (UInt32(0xFDD0)...0xFDEF).map { String(Unicode.Scalar($0)!) }.joined()
        let privateUse = [0xE000, 0xE001, 0xE002].map { String(Unicode.Scalar($0)!) }.joined(separator: " ")
        let section = try recovered(page("<p>\(common)</p><p id='p'>&#xE000; &#57345; &#xe002; x &# y</p>"
            + "<p><img alt='&#xE000; &# tail'/></p>"))
        XCTAssertEqual(section.text, expectedCommon + "\n" + privateUse + " x &# y\n" + String(Unicode.Scalar(0xE000)!) + " &# tail")
        XCTAssertEqual(section.anchors["p"], EPUBTextMark(offset: expectedCommon.utf8.count + 1, separator: 1))
    }
}
