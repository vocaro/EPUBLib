import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest

/// Opt-in recovery (`recoversMalformedMarkup: true`) over the kinds of broken markup that
/// converted and hand-edited books contain, compared with what the HTML Standard's parser
/// (and so a browser) makes of the same bytes.
final class ExtractionRecoveryCoverageTests: XCTestCase {
    private static let files: [String: Data] = (try? Fixture.files()) ?? [:]
    private let path = "OPS/one.xhtml"

    private func book(_ xml: String) throws -> EPUBPublication {
        var files = Self.files
        files[path] = Data(xml.utf8)
        return try EPUBPublication.open(data: Fixture.archive(files))
    }
    private func page(_ body: String, head: String = "<title>T</title>") -> String {
        "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head>\(head)</head><body>\(body)</body></html>"
    }
    /// Asserts the strict path refuses the document, then returns what recovery reads.
    private func recovered(_ xml: String, file: StaticString = #filePath, line: UInt = #line) throws -> EPUBTextSection {
        let publication = try book(xml)
        XCTAssertThrowsError(try publication.textSection(at: 0), file: file, line: line) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), file: file, line: line)
        }
        let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(section.recoveredAsHTML, file: file, line: line)
        return section
    }

    // MARK: Repairs that keep the text

    func testRecoveredUppercaseHTMLLowercasesElementAndAttributeNames() throws {
        let section = try recovered("<HTML><HEAD><TITLE>Up</TITLE></HEAD><BODY><H1 ID=top>Title</H1><P CLASS=x>Para<BR>line<P>next</BODY></HTML>")
        XCTAssertEqual(section.title, "Up")
        XCTAssertEqual(section.text, "Title\nPara\nline\nnext")
        XCTAssertEqual(section.anchors, ["top": EPUBTextMark(offset: 0, separator: 0)])
        XCTAssertEqual(section.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 0, separator: 0), text: "Title")])
    }

    // HTML Standard, attribute name state: a duplicate attribute is a parse error and the later one is dropped.
    func testRecoveryKeepsTheFirstOfDuplicateAttributes() throws {
        let section = try recovered(page("<p id='a' id='b'>x</p><p id='c' ID='d'>y</p>"))
        XCTAssertEqual(section.text, "x\ny")
        XCTAssertEqual(section.anchors, ["a": EPUBTextMark(offset: 0, separator: 0), "c": EPUBTextMark(offset: 2, separator: 1)])
    }

    func testRecoveryReadsUnquotedAttributeValuesAndAGreaterThanSignInText() throws {
        let section = try recovered(page("<p class=a id=b title=x>y>Text</p><p id=c lang=en-GB>next</p>"))
        XCTAssertEqual(section.text, "y>Text\nnext")
        XCTAssertEqual(section.anchors, ["b": EPUBTextMark(offset: 0, separator: 0), "c": EPUBTextMark(offset: 7, separator: 1)])
    }

    func testRecoveryKeepsMisnestedInlineTextInOrderWithoutLineBreaks() throws {
        let section = try recovered(page("<p><b>bold <i>both</b> italic</i> plain</p><p>un<em>clo<strong>sed</p><p>next</p>"))
        XCTAssertEqual(section.text, "bold both italic plain\nunclosed\nnext")
    }

    func testRecoveryKeepsBareAmpersandsAndDecodesTheReferencesHTMLKnows() throws {
        XCTAssertEqual(try recovered(page("<p>AT&T R&D 5 & 6 &c; done</p><p>Next</p>")).text, "AT&T R&D 5 & 6 &c; done\nNext")
        XCTAssertEqual(try recovered(page("<p>caf&eacute;</b> &mdash; &hellip; &rsquo; &#x1F600; &#233; &bogus; &apos; a&nbsp;b</p>")).text,
            "café — … ’ \u{1F600} é &bogus; ' a b")
    }

    // XHTML's empty-element syntax on non-void elements must not swallow what follows.
    func testRecoveryHonorsXMLEmptyElementSyntaxOnNonVoidElements() throws {
        let section = try recovered(page("<p>a</b><a id='x'/>Text <span id='pg' epub:type='pagebreak'/>more</p><div/>tail"))
        XCTAssertEqual(section.text, "aText more\ntail")
        XCTAssertEqual(section.semanticTypes, ["pagebreak"])
        XCTAssertEqual(section.anchors, ["x": EPUBTextMark(offset: 1, separator: 0), "pg": EPUBTextMark(offset: 6, separator: 1)])
    }

    func testARecoveredSectionMatchesItsWellFormedTwinInEveryField() throws {
        let rich = "<section epub:type='chapter' id='s'><h1 id='h'>Café <em>one</em></h1><p id='p'>A <a href='#n' epub:type='noteref' id='r'>1</a> b<br/>c "
            + "<img id='i' alt='pic \u{1F600}'/></p><ul><li id='l1'>x</li><li>y<ol><li>z</li></ol></li></ul><table><tr><th>H</th><td id='c'>D</td></tr></table>"
            + "<h2/><aside epub:type='footnote' id='n'><p>Note</p></aside><p id='end'>End</p></section>"
        let strict = try book(page(rich, head: "<title>Twin &amp; co</title>")).textSection(at: 0)
        XCTAssertEqual(strict.text, "Café one\nA 1 b\nc pic \u{1F600}\nx\ny\nz\nH\nD\nNote\nEnd")
        XCTAssertEqual(strict.anchors.count, 9)
        for (well, broken) in [("<p id='end'>End</p>", "<p id='end'>End</b></p>"), ("<br/>", "<br>"), ("<li>z</li>", "<li>z"),
                               ("<td id='c'>D</td>", "<td id=c>D")] {
            let twin = try recovered(page(rich.replacingOccurrences(of: well, with: broken), head: "<title>Twin &amp; co</title>"))
            XCTAssertEqual(twin.title, strict.title, broken)
            XCTAssertEqual(twin.text, strict.text, broken)
            XCTAssertEqual(twin.anchors, strict.anchors, broken)
            XCTAssertEqual(twin.headings, strict.headings, broken)
            XCTAssertEqual(twin.semanticTypes, strict.semanticTypes, broken)
            XCTAssertEqual(twin.resource, strict.resource, broken)
        }
    }

    func testRecoveryReadsFragmentsWithoutHTMLOrBodyTags() throws {
        let fragment = try recovered("<p>Hello<br>world</p><h1 id=h>Head</h1>")
        XCTAssertNil(fragment.title)
        XCTAssertEqual(fragment.text, "Hello\nworld\nHead")
        XCTAssertEqual(fragment.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 12, separator: 1), text: "Head")])
        XCTAssertEqual(try recovered("Just some text").text, "Just some text")
        XCTAssertEqual(try recovered("<body><p>Body only</b></p></body>").text, "Body only")
    }

    func testRecoveredTitleCDATAAndPrefixedMathKeepTheirStrictTreatment() throws {
        let section = try recovered(page("<p>x</b> <m:math xmlns:m='http://www.w3.org/1998/Math/MathML'><m:mi>y</m:mi></m:math></p>"
            + "<svg xmlns='http://www.w3.org/2000/svg'><title>ST</title> <text>L</text><style>bad</style></svg>",
            head: "<title><![CDATA[A <b> & C]]></title>"))
        XCTAssertEqual(section.title, "A <b> & C")
        XCTAssertEqual(section.text, #"x math("y")"# + "\nST L")
    }

    // MARK: Truncated input

    // HTML Standard, comment state at end of input: the unclosed comment takes the rest of the
    // input, as in a browser; nothing after it may surface as text.
    func testAnUnterminatedCommentHidesTheRestAsItDoesInHTML() throws {
        XCTAssertEqual(try recovered(page("<p>before</p><!-- never closed <p>after</p>")).text, "before")
    }

    func testAnUnterminatedTagAtTheEndOfInputKeepsTheTextBeforeIt() throws {
        XCTAssertEqual(try recovered("<html><head><title>T</title></head><body><p>before</p><p>after</p><div class=").text, "before\nafter")
        XCTAssertEqual(try recovered("<html><head><title>T</title></head><body><p>before</p><p>after").text, "before\nafter")
    }

    // MARK: Text the repair must not lose

    // HTML Standard, tag open state: "<" before anything but a letter, "!", "/" or "?" is an
    // invalid-first-character-of-tag-name parse error that emits the "<" as a character and
    // continues in the data state. Browsers show "p < 0.05"; an unescaped "<" is exactly why such
    // a file needs recovery.
    func testRecoveryKeepsProseAfterABareLessThanSign() throws {
        let section = try recovered(page("<p>The result p < 0.05 was significant.</p><p>Next</p>"))
        XCTAssertEqual(section.text, "The result p < 0.05 was significant.\nNext")
    }

    // HTML Standard, "after body" and "after after body" insertion modes: a start tag or text
    // there is a parse error that is reprocessed "in body", so the content stays in the document.
    func testRecoveryKeepsContentAfterAnEarlyBodyOrDocumentEndTag() throws {
        let section = try recovered("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>One</b></p></body></html><p>Two</p>")
        XCTAssertEqual(section.text, "One\nTwo")
    }

    // HTML Standard, "in body" insertion mode, U+0000: a parse error; the character is ignored.
    // doc/text-extraction.md: recovery "never yields partial text". Refusing the document would
    // also honour that; returning only what precedes the NUL does not.
    func testRecoveryDoesNotSilentlyTruncateAtANULCharacter() throws {
        let publication = try book(page("<p>before</b></p>\u{0}<p>after</p>"))
        guard let section = try? publication.textSection(at: 0, recoversMalformedMarkup: true) else { return }
        XCTAssertEqual(section.text, "before\nafter")
    }
}
