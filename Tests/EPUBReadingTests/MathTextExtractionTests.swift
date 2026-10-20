import CryptoKit
import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import Foundation
import XCTest

final class MathTextExtractionTests: XCTestCase {
    private func book(_ body: String) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml":
            "<html xmlns='http://www.w3.org/1999/xhtml'><head/><body>\(body)</body></html>"]))
    }
    private func math(_ content: String, attributes: String = "") -> String {
        "<math xmlns='http://www.w3.org/1998/Math/MathML' \(attributes)>\(content)</math>"
    }
    private func extract(_ content: String, attributes: String = "") throws -> String {
        try book(math(content, attributes: attributes)).textSection(at: 0).text
    }

    func testGlyphAlternativesInTokensAndRows() throws {
        for token in ["mi", "mn", "mo", "mtext", "ms"] {
            XCTAssertEqual(try extract("<\(token)>a<mglyph src='symbol.png' alt='  α &#xA; β  '/>b</\(token)>"),
                           #"math("aα βb")"#, token)
            XCTAssertEqual(try extract("<\(token)>a<mglyph src='symbol.png'/>b<mglyph alt=' '/></\(token)>"),
                           #"math("ab")"#, token)
        }
        XCTAssertEqual(try extract("<mrow><mi>x</mi><mglyph src='star.png' alt=' star '/><mi>y</mi></mrow>"),
                       #"math(row("x", "star", "y"))"#)
        XCTAssertEqual(try extract("<mglyph/><mi>x</mi><mglyph alt=' '/>"), #"math("x")"#)
        XCTAssertEqual(try extract("<mtext>the <mglyph alt='  star  '/> sign</mtext>"), #"math("the star sign")"#)
        XCTAssertEqual(try extract("<mglyph alt='star'/>", attributes: "alttext='whole formula'"), "whole formula")
        XCTAssertEqual(try extract("<mglyph alt='star'/>", attributes: "alttext='  '"), #"math("star")"#)
        XCTAssertEqual(try extract(#"<mglyph alt='&quot; \ )'/><mi>x</mi>"#), #"math("\" \\ )", "x")"#)
        // A foreign element with the same name retains its actual structure.
        XCTAssertEqual(try extract("<mglyph xmlns='urn:other' alt='foreign'/>"),
                       #"math(element("urn:other", "mglyph"; attributes(alt="foreign")))"#)
    }

    func testGlyphUTF8AnchorsAndOutputBudget() throws {
        let publication = try book("<p>Pré " + math("<mtext>a<mglyph id='glyph' alt='é★'/>b</mtext><mglyph id='row' alt='α'/>",
                                                           attributes: "id='formula'") + "</p><p id='later'>Next</p>")
        let section = try publication.textSection(at: 0)
        let expected = "Pré " + #"math("aé★b", "α")"# + "\nNext"
        XCTAssertEqual(section.text, expected)
        XCTAssertEqual(section.anchors["glyph"], EPUBTextMark(offset: ("Pré " + #"math("a"#).utf8.count, separator: 0))
        XCTAssertEqual(section.anchors["row"], EPUBTextMark(offset: ("Pré " + #"math("aé★b", "#).utf8.count, separator: 1))
        XCTAssertEqual(section.anchors["later"], EPUBTextMark(offset: expected.utf8.count - 4, separator: 1))
        var limits = EPUBTextExtractionLimits()
        limits.outputBytes = expected.utf8.count
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits).text, expected)
        limits.outputBytes -= 1
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
    }

    func testNestedFractionsPowersIndicesAndFencesHaveExplicitScope() throws {
        let text = try extract("""
        <mfrac><msubsup><mi>x</mi><mi>i</mi><mn>2</mn></msubsup>
          <mfrac><mi>a</mi><msup><mfenced><mrow><mi>b</mi><mo>+</mo><mi>c</mi></mrow></mfenced><mn>2</mn></msup></mfrac>
        </mfrac>
        """)
        XCTAssertEqual(text, #"math(frac(subsup("x", "i", "2"), frac("a", sup(fenced(close=")", open="(", separators=","; row("b", "+", "c")), "2"))))"#)
        XCTAssertEqual(try extract("<msub><mi>x</mi><mi>i</mi></msub><msup><mi>x</mi><mi>i</mi></msup>"), #"math(sub("x", "i"), sup("x", "i"))"#)
    }

    func testFenceDefaultsExplicitEmptiesAndAuthoredSeparatorsRemainDistinct() throws {
        XCTAssertEqual(try extract("<mfenced open='[' close=']' separators=';:'><mi>x</mi><mi>y</mi><mi>z</mi></mfenced>"),
            #"math(fenced(close="]", open="[", separators=";:"; "x", "y", "z"))"#)
        XCTAssertEqual(try extract("<mfenced open='' close='' separators=''><mi>x</mi><mi>y</mi></mfenced>"),
            #"math(fenced(close="", open="", separators=""; "x", "y"))"#)
        XCTAssertEqual(try extract("<msqrt><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow></msqrt><mroot><mi>x</mi><mn>3</mn></mroot>"),
            #"math(sqrt(row("a", "+", "b")), root("x", "3"))"#)
    }

    func testAuthoredAlternativesAppearOnceWithoutAnnotationOrCommentLeakage() throws {
        let content = "<mfrac id='fraction'><mi id='numerator'>WRONG</mi><mi>LEAK</mi></mfrac>"
        let section = try book("<p>Before " + math(content, attributes: "id='formula' alttext='  α² &#xA;+ β  '") + " after.</p>").textSection(at: 0)
        XCTAssertEqual(section.text, "Before α² + β after.")
        for id in ["formula", "fraction", "numerator"] {
            XCTAssertEqual(section.anchors[id], EPUBTextMark(offset: "Before ".utf8.count, separator: 1))
        }
        let latex = try extract(#"<semantics><mfrac><mi>x</mi><mi>y</mi></mfrac><annotation encoding='application/x-tex'>\frac{x}{y}</annotation><annotation encoding='text/plain'>Duplicate</annotation><annotation-xml encoding='application/xhtml+xml'><div xmlns='http://www.w3.org/1999/xhtml'><img alt='Leak'/></div></annotation-xml></semantics>"#)
        XCTAssertEqual(latex, #"\frac{x}{y}"#)
        XCTAssertEqual(try extract("<semantics><msup><mi>x</mi><mn>2</mn></msup><annotation encoding='unknown'>Do not append</annotation></semantics>"), #"math(sup("x", "2"))"#)
        XCTAssertEqual(try extract("<!-- <img alt='Commented image'/> --><script>Never run</script><style>Never use</style><mi>x</mi>"), #"math("x")"#)
        XCTAssertEqual(try extract("<mi>x</mi>", attributes: "alttext='   '"), #"math("x")"#)
    }

    func testNestedAlternativesCannotInjectStructuralDelimiters() throws {
        let section = try book(math(#"""
        <mfrac><semantics id='nested'><mi id='replaced'>x</mi>
        <annotation id='chosen' encoding='text/plain'>x, y) &quot; \ tail</annotation>
        <annotation id='ignored' encoding='unknown'>No duplicate</annotation></semantics>
        <mi alttext='z, a)'>z</mi></mfrac>
        """#)).textSection(at: 0)
        XCTAssertEqual(section.text, #"math(frac("x, y) \" \\ tail", "z, a)"))"#)
        for id in ["nested", "replaced", "chosen", "ignored"] {
            XCTAssertEqual(section.anchors[id], EPUBTextMark(offset: "math(frac(".utf8.count, separator: 0))
        }
    }

    func testCombiningMarksMakeMathAlternativesNonemptyAndRemainLiteral() throws {
        XCTAssertEqual(try extract("<mi>Ignored</mi>", attributes: "alttext='&#xA0;&#x301;'"), "\u{301}")
        XCTAssertEqual(try extract("<semantics><mi>Ignored</mi><annotation encoding='text/plain'> \u{093E}</annotation></semantics>"),
            "\u{093E}")
        XCTAssertEqual(try extract("<mi alttext=' \u{301}'>Ignored</mi><mi>x</mi>"), "math(\"\u{301}\", \"x\")")
        XCTAssertEqual(try extract("<mi>Ignored</mi>", attributes: "alttext='Signs: \u{093E} \u{093F}'"), "Signs: \u{093E} \u{093F}")
    }

    func testCombiningMarksAreSignificantMathChildrenAndSurviveTokenQuoting() throws {
        XCTAssertEqual(try extract(" \u{301}<mi>x</mi>"), "math(\"\u{301}\", \"x\")")
        XCTAssertEqual(try extract("<mi>x&#xA0;&#x301;.</mi><mtext> \u{093E}</mtext>"), "math(\"x \u{301}.\", \"\u{093E}\")")
        // The bare mark is a second presentation child, so the math wrapper must not replace
        // the whole formula with its sibling semantics alternative and discard that mark.
        XCTAssertEqual(try extract(" \u{301}<semantics><mi>y</mi><annotation encoding='text/plain'>Y</annotation></semantics>"),
            "math(\"\u{301}\", \"Y\")")
    }

    func testSiblingFormulaAndMalformedSemanticsDoNotLosePresentationContent() throws {
        XCTAssertEqual(try extract("<mi>x</mi><semantics><mi>y</mi><annotation encoding='text/plain'>Y, z)</annotation></semantics>"),
            #"math("x", "Y, z)")"#)
        XCTAssertEqual(try extract("<semantics><mi>x</mi><mi>y</mi><annotation encoding='unknown'>Ignored</annotation></semantics>"),
            #"math(semantics("x", "y"))"#)
        XCTAssertEqual(try extract("<semantics>bare text<mi>x</mi><annotation-xml><mi>Ignored</mi></annotation-xml></semantics>"),
            #"math(semantics("bare text", "x"))"#)
        XCTAssertEqual(try extract("<semantics><annotation encoding='unknown'>Ignored</annotation></semantics>"), #"math(semantics())"#)
    }

    func testMalformedArityAndPresentationChangingAttributesKeepGenericStructure() throws {
        XCTAssertEqual(try extract("<mfrac linethickness='0'><mi>n</mi><mi>k</mi></mfrac>"), #"math(mfrac(linethickness="0"; "n", "k"))"#)
        XCTAssertEqual(try extract("<msup><mi>x</mi></msup>"), #"math(msup("x"))"#)
        XCTAssertEqual(try extract("<frac><mi>x</mi><mi>y</mi></frac>"),
            #"math(element("http://www.w3.org/1998/Math/MathML", "frac"; attributes(); "x", "y"))"#)
        XCTAssertEqual(try extract("<apply><plus/><ci>x</ci><cn>2</cn></apply><unknown z='2' a='1'><mi>y</mi></unknown>"),
            #"math(apply(plus(), ci("x"), cn("2")), unknown(a="1", z="2"; "y"))"#)
    }

    func testGenericMetadataDoesNotOverwriteAuthoredAttributes() throws {
        XCTAssertEqual(try extract("<frac name='different' namespace='custom'><mi>x</mi></frac>"),
            #"math(element("http://www.w3.org/1998/Math/MathML", "frac"; attributes(name="different", namespace="custom"); "x"))"#)
        XCTAssertEqual(try extract("<foreign xmlns='urn:other' name='authored' namespace='value'/>"),
            #"math(element("urn:other", "foreign"; attributes(name="authored", namespace="value")))"#)
    }

    func testNamespaceAliasesForeignLookalikesAndInvisibleOperators() throws {
        let section = try book("""
        <m:math xmlns:m='http://www.w3.org/1998/Math/MathML'><m:msup><m:mi>x</m:mi><m:mn>2</m:mn></m:msup></m:math>
        <math xmlns='urn:unrelated' alttext='Not an alternative'><mi>foreign</mi></math>
        <math alttext='Also not an alternative'><mi>html</mi></math>
        """).textSection(at: 0)
        XCTAssertEqual(section.text, #"math(sup("x", "2")) foreign html"#)
        XCTAssertEqual(try extract("<mi>x</mi><mo>&#x2062;</mo><mi>y</mi><mo>&#x2061;</mo><mi>z</mi>"),
            #"math("x", "\u{2062}", "y", "\u{2061}", "z")"#)
        XCTAssertEqual(try extract(#"<mtext>A &quot;quoted&quot; \ value, (x)</mtext>"#), #"math("A \"quoted\" \\ value, (x)")"#)
        XCTAssertEqual(try extract("<foo xmlns='urn:foreign' alttext='No substitute'>text</foo>"),
            #"math(element("urn:foreign", "foo"; attributes(alttext="No substitute"); "text"))"#)
    }

    func testUTF8AnchorsHeadingsAndAdjacentInlineTextUseTheReturnedText() throws {
        let section = try book("<p>Préface</p><h2 id='heading'>A" + math("<mfrac id='fraction'><mi id='top'>α</mi><mi id='bottom'>β</mi></mfrac>", attributes: "id='math'") + "B</h2><p id='after'>Next</p>").textSection(at: 0)
        let heading = #"Amath(frac("α", "β"))B"#
        XCTAssertEqual(section.text, "Préface\n" + heading + "\nNext")
        XCTAssertEqual(section.anchors["heading"], EPUBTextMark(offset: "Préface\n".utf8.count, separator: 1))
        XCTAssertEqual(section.anchors["math"], EPUBTextMark(offset: "Préface\nA".utf8.count, separator: 0))
        XCTAssertEqual(section.anchors["fraction"], EPUBTextMark(offset: "Préface\nAmath(".utf8.count, separator: 0))
        XCTAssertEqual(section.anchors["top"], EPUBTextMark(offset: "Préface\nAmath(frac(".utf8.count, separator: 0))
        XCTAssertEqual(section.anchors["bottom"], EPUBTextMark(offset: #"Préface"#.utf8.count + "\nAmath(frac(\"α\", ".utf8.count, separator: 1))
        XCTAssertEqual(section.anchors["after"], EPUBTextMark(offset: ("Préface\n" + heading + "\n").utf8.count, separator: 1))
        XCTAssertEqual(section.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: "Préface\n".utf8.count, separator: 1), text: heading)])
    }

    func testBlockMathSeparatesProseWithoutInterpretingCSS() throws {
        let section = try book("Before" + math("<mi>x</mi>", attributes: "display='block'") + "After" + math("<mi>y</mi>", attributes: "alttext='Y' display='block'") + "End").textSection(at: 0)
        XCTAssertEqual(section.text, #"Before"# + "\n" + #"math(display="block"; "x")"# + "\nAfter\nY\nEnd")
    }

    func testGeneratedNotationAndAlternativesRespectAllExistingLimits() throws {
        let publication = try book(math("<mi>é</mi>"))
        var limits = EPUBTextExtractionLimits()
        limits.outputBytes = #"math("é")"#.utf8.count
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits).text, #"math("é")"#)
        limits.outputBytes -= 1
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
        let ignored = try book(math("<mrow><mi>Ignored</mi></mrow>", attributes: "alttext='x'"))
        limits = EPUBTextExtractionLimits(); limits.outputBytes = 1
        XCTAssertEqual(try ignored.textSection(at: 0, limits: limits).text, "x")
        limits.depth = 4
        XCTAssertThrowsError(try ignored.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("depth"))
        }
        limits = EPUBTextExtractionLimits(); limits.elementCount = 5
        XCTAssertThrowsError(try ignored.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("elementCount"))
        }
        limits = EPUBTextExtractionLimits(); limits.inputBytes = 10
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("inputBytes"))
        }
        let escaped = try book(math("<mi>&quot;&quot;&quot;</mi>"))
        limits = EPUBTextExtractionLimits(); limits.outputBytes = 11
        XCTAssertThrowsError(try escaped.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
    }

    func testUnsafeXMLAndCancellationAreNotConvertedToMathFallbacks() async throws {
        let xml = "<!DOCTYPE html [<!ENTITY math SYSTEM 'https://example.invalid/never-fetch'>]><html><body><math xmlns='http://www.w3.org/1998/Math/MathML'><mi>&math;</mi></math></body></html>"
        let unsafe = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xml]))
        XCTAssertThrowsError(try unsafe.textSection(at: 0)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent("OPS/one.xhtml"))
        }
        let publication = try book(math("<mi>x</mi>"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try publication.textSection(at: 0)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    func testOriginalNumericalMethodsArchive() throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBLIB_NUMERICAL_EPUB"] else {
            throw XCTSkip("Set EPUBLIB_NUMERICAL_EPUB to the original publisher EPUB for corpus validation")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(data.count, 35_066_752)
        XCTAssertEqual(sha256, "c2b792fb03b974eb8d7c2027ce7ba134940fb877fbc0fa214ab666b590e3507f")
        let publication = try EPUBPublication.open(data: data)
        let index = try XCTUnwrap(publication.spine.firstIndex { $0.resource.path == "OEBPS/08_9789176351734_Ch02_txt.xhtml" })
        let section = try publication.textSection(at: index)
        func equation(_ id: String) throws -> String {
            let offset = try XCTUnwrap(section.anchors[id]).offset
            let bytes = Array(section.text.utf8)
            let end = bytes[offset...].firstIndex(of: 10) ?? bytes.count
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }
        let quadratic = try equation("eq2.2"), laplace = try equation("eq2.3"), scoped = try equation("eq2.7")
        XCTAssertTrue(quadratic.contains(#"sup(row("x"), row("2"))"#))
        XCTAssertTrue(quadratic.contains(#"sup(row("y"), row("2"))"#))
        XCTAssertTrue(laplace.contains("frac(")); XCTAssertTrue(laplace.contains("fenced("))
        XCTAssertTrue(scoped.contains("fenced(")); XCTAssertTrue(scoped.contains("frac("))
        XCTAssertTrue(section.text.contains(quadratic + "\n(2.2)"))
        XCTAssertTrue(section.text.contains(laplace + "\n(2.3)"))
        XCTAssertTrue(section.text.contains(scoped + "\n(2.7)"))
        // Validate every original spine item without executing MathJax, JPEG comments or links.
        for spineIndex in publication.spine.indices { _ = try publication.textSection(at: spineIndex) }
        print("Validated original Numerical Methods EPUB: \(publication.spine.count) spine sections; eq2.2=\(quadratic); eq2.3=\(laplace); eq2.7=\(scoped)")
    }
}
