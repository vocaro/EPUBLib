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

    func testRecoveryPreservesCombiningMarksInTextHeadingsAndAlternatives() throws {
        let section = try recovered(page("<h2 id='h'>Signs: \u{093E}</h2><p>acute:&nbsp;&#x301;</b>.</p>"
            + "<p><img id='image' alt=' \u{093F}'/></p><math alttext='&#xA0;&#x301;'><mi>Ignored</mi></math>",
            head: "<title>Title:&#xA0;&#x301;</title>"))
        XCTAssertEqual(section.title, "Title: \u{301}")
        XCTAssertEqual(section.text, "Signs: \u{093E}\nacute: \u{301}.\n\u{093F}\n\u{301}")
        XCTAssertEqual(section.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 0, separator: 0), text: "Signs: \u{093E}")])
        XCTAssertEqual(section.anchors["image"], EPUBTextMark(offset: "Signs: \u{093E}\nacute: \u{301}.\n".utf8.count, separator: 1))
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

    // The same state before a digit, punctuation, a space, another "<", a non-ASCII letter, an
    // underscore or a colon, in a heading and the title as in a paragraph. Every field matches
    // the document that escapes each sign.
    func testEveryLessThanSignThatOpensNoMarkupReadsLikeItsEscapedTwin() throws {
        let body = "<h1 id='h'>x &lt;= y and y >= z</h1><p id='p'>p &lt;.05, a&lt;3, 5 &lt;é, &lt;&lt; and &lt;<b id='b'>bold</b>> &lt; </p>"
            + "<p id='u'>a &lt;_&lt; b, &lt;:3 and &lt;_x id='no'>c&lt;:y>d</p><p id='n'>Next</p>"
        let strict = try book(page(body, head: "<title>a &lt; b &lt;_ c</title>")).textSection(at: 0)
        XCTAssertEqual(strict.text, "x <= y and y >= z\np <.05, a<3, 5 <é, << and <bold> <\na <_< b, <:3 and <_x id='no'>c<:y>d\nNext")
        let twin = try recovered(page(body.replacingOccurrences(of: "&lt;", with: "<"), head: "<title>a < b <_ c</title>"))
        XCTAssertEqual(twin.title, strict.title)
        XCTAssertEqual(twin.text, strict.text)
        XCTAssertEqual(twin.anchors, strict.anchors)
        XCTAssertEqual(twin.headings, strict.headings)
    }

    // A "<" inside an attribute value, a comment, script content or a processing instruction is
    // already where it belongs.
    func testALessThanSignInsideMarkupIsLeftAlone() throws {
        let section = try recovered(page("<p>a</b> <img alt='1 < 2'/><!-- c < d --><script>if (e < f) {}</script><?pi g < h ?> i</p>"
            + "<p>j <img alt='<_x> <:y>'/> k</p>"))
        XCTAssertEqual(section.text, "a 1 < 2 i\nj <_x> <:y> k")
    }

    // HTML Standard, tag open state: only an ASCII letter, "/", "!" or "?" goes on to a tag. To
    // libxml2 an underscore and a colon start a name too, and what looked like a tag in prose
    // opened an element and took its attributes (#198). The native reader reads these as text.
    func testALessThanSignBeforeAnUnderscoreOrAColonIsText() throws {
        let section = try recovered(page("<_ at the start</b><p>a <_< b and <:3</p><p>j <_x id='u'>k</_x> <:y id='v'>l</:y></p><div><em><:></em></div>"))
        XCTAssertEqual(section.text, "<_ at the start\na <_< b and <:3\nj <_x id='u'>k <:y id='v'>l\n<:>")
        XCTAssertEqual(section.anchors, [:], "what reads as a tag in prose gives no element its id")
        // The same sign as the last thing in the file but for the character after it.
        for (tail, text) in [("<_", "before\nafter\n<_"), ("<:", "before\nafter\n<:"), ("<_>", "before\nafter\n<_>")] {
            XCTAssertEqual(try recovered("<html><head><title>T</title></head><body><p>before</p><p>after</p>\(tail)").text, text, tail)
        }
    }

    // Nothing can follow a "<" that ends the input, so it stays the cut-off tag it may be.
    func testALessThanSignThatEndsTheInputIsATruncatedTag() throws {
        XCTAssertEqual(try recovered("<html><head><title>T</title></head><body><p>before</p><p>after</p><").text, "before\nafter")
    }

    // HTML Standard, "after body" and "after after body" insertion modes: a start tag or text
    // there is a parse error that is reprocessed "in body", so the content stays in the document.
    func testRecoveryKeepsContentAfterAnEarlyBodyOrDocumentEndTag() throws {
        let section = try recovered("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>One</b></p></body></html><p>Two</p>")
        XCTAssertEqual(section.text, "One\nTwo")
    }

    // The same between the two end tags, with its positions, for each spelling libxml2 reads as
    // one of them: it ends a tag name at the first byte that cannot be in one, as in </body"x>.
    func testRecoveryKeepsContentAfterABodyEndTagInAnySpelling() throws {
        for end in ["</body>", "</BODY >", "</body></HTML\n>", "</body class='x'>", "</body\"x>", "</html>"] {
            let section = try recovered("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>One</b></p>\(end)<p id='two'>Two</p>tail</html>")
            XCTAssertEqual(section.text, "One\nTwo\ntail", end)
            XCTAssertEqual(section.anchors, ["two": EPUBTextMark(offset: 4, separator: 1)], end)
        }
    }

    // HTML Standard, "in body" insertion mode: a second <html> or <body> start tag only adds
    // attributes to the first, a <head> start tag is ignored, and <title> is inserted where it
    // stands. Two documents in one file are one body; the first title names the section.
    func testASecondDocumentInTheFileIsReadIntoTheSameBody() throws {
        let section = try recovered("<html><head><title>A</title></head><body><p>One</p></body></html>\n"
            + "<?xml version='1.0'?><!DOCTYPE html><html lang='en'><head><title>B</title></head><body class='x'><h1 id='h'>Two</h1></body></html>")
        XCTAssertEqual(section.title, "A")
        XCTAssertEqual(section.text, "One\nB\nTwo")
        XCTAssertEqual(section.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 6, separator: 1), text: "Two")])
        XCTAssertEqual(section.anchors, ["h": EPUBTextMark(offset: 6, separator: 1)])
    }

    func testBodyEndTagsInCommentsScriptsCDATAAndAttributeValuesAreNotEndTags() throws {
        let section = try recovered(page("<p>a</b><!-- </body></html> --> <![CDATA[</body>]]> <img alt='</html>'/></p><script>'</body></html>'</script><p>b</p>"))
        XCTAssertEqual(section.text, "a </body> </html>\nb")
    }

    // libxml2 skips a "<?" or "</" that no name follows and reads on, and ends an end tag at its
    // first ">" even inside a quoted value, so it acts on a body end tag after any of these.
    func testRecoveryKeepsContentAfterABodyEndTagThatFollowsOtherBrokenMarkup() throws {
        for broken in ["<? </body>", "</3 </body>", "</div title='></body>'>"] {
            let lines = try recovered(page("<div><p>One</b></p>\(broken)<p>Two</p>")).text.split(separator: "\n")
            XCTAssertEqual(lines.first, "One", broken)
            XCTAssertEqual(lines.last, "Two", broken)
        }
    }

    // The tag's place is kept: HTML reads the text on either side of it as written, not as the
    // character reference its two halves would spell.
    func testTextOnEitherSideOfABodyEndTagDoesNotJoinIntoAReference() throws {
        XCTAssertEqual(try recovered(page("<p>A&nb</body>sp;B &l</html>t;i></p><p>C</p>")).text, "A&nbsp;B &lt;i>\nC")
    }

    // Content that used to fall outside the body is read under the same limits as the rest.
    func testContentAfterAnEarlyDocumentEndTagObeysTheLimits() throws {
        let publication = try book("<html><head><title>T</title></head><body><p>One</p></body></html><div><p>Two</p></div>")
        let cases: [(WritableKeyPath<EPUBTextExtractionLimits, Int>, Int, String)] = [
            (\.depth, 4, "depth"), (\.elementCount, 7, "elementCount"), (\.outputBytes, 7, "outputBytes")]
        for (key, passing, name) in cases {
            var limits = EPUBTextExtractionLimits()
            limits[keyPath: key] = passing
            XCTAssertEqual(try publication.textSection(at: 0, limits: limits, recoversMalformedMarkup: true).text, "One\nTwo", name)
            limits[keyPath: key] = passing - 1
            XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits, recoversMalformedMarkup: true), name) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded(name))
            }
        }
    }

    // MARK: A body end tag where the scan and libxml2 read differently (#235)

    // libxml2 reads `</scriptx>` inside a script as an end tag that closes nothing and stays in
    // the script; `<script / >` and `<script"q>` open one for it. The scan takes each for the end
    // of the script or for no script, so it meets `</body` as text while libxml2 is still in the
    // script. A body end tag with no ">" of its own runs to the next, the script's. Replacing it
    // whole took the script's end tag with it and the script took the rest of the section.
    func testABodyEndTagInsideAScriptDoesNotTakeTheScriptsEndTagWithIt() throws {
        XCTAssertEqual(try recovered(page("<p>x</b><script>y</scriptx> a </body </script></p><p>visible</p>")).text, "x\nvisible")
        XCTAssertEqual(try recovered(page("<p>x</b><script / >var s = \"</body\"</script></p><p>visible</p>")).text, "x\nvisible")
    }

    // The same in every spelling the review's matrix found it in: each element, each start tag
    // libxml2 reads as that element, a body or root end tag that never closes before the
    // element's own end tag, in a paragraph, in nested elements and on its own.
    func testNoSpellingOfAScriptOrStyleLosesTheTextAfterIt() throws {
        for element in ["script", "style"] {
            for start in ["<\(element)>", "<\(element) type='x'>", "<\(element) / >", "<\(element)\"q>", "<\(element.uppercased())>"] {
                for (content, end) in [("k</\(element)x> a </body ", "</\(element)>"), ("k</\(element)x> a </html ", "</\(element.uppercased())\n>"),
                                       ("var s = \"</body\"", "</\(element)>"), ("a </body x='", "</\(element) >")] {
                    for (open, close) in [("", ""), ("<p>", "</p>"), ("<div><span id='s'>", "</span></div>")] {
                        let body = "<p>before</b></p>\(open)pre \(start)\(content)\(end) post\(close)<p id='n'>next</p>"
                        let section = try recovered(page(body))
                        XCTAssertTrue(section.text.hasPrefix("before\npre"), body)
                        XCTAssertTrue(section.text.hasSuffix("\nnext"), "\(body) gave \(section.text.debugDescription)")
                        XCTAssertEqual(section.anchors["n"]?.offset, section.text.utf8.count - 4, body)
                    }
                }
            }
        }
    }

    // Directly after a script's start tag libxml2 reads an end tag as an end tag, so `</body>`
    // there closed the body and the paragraph after the script fell outside it.
    func testABodyEndTagAtTheStartOfAScriptOrStyleDoesNotCloseTheBody() throws {
        for raw in ["<script></body></script>", "<style></html></style>", "<script></BODY x></html\n></script>"] {
            XCTAssertEqual(try recovered(page("<p>One</b></p>\(raw)<p>Two</p>")).text, "One\nTwo", raw)
        }
    }

    // libxml2 leaves a script or style at an end tag that directly follows its start tag, so one
    // in the head that lacks its own end tag is closed by </head> and the body is read. The
    // scan does nothing to stop that. Made to run to the next script's end tag, as HTML has it,
    // the script would hold the body's start tag and the first paragraph would be gone.
    func testAHeadScriptOrStyleWithNoEndTagStillLeavesTheBodyRead() throws {
        XCTAssertEqual(try recovered(page("<p>One</b></p><script>var a;</script><p>Two</p>", head: "<title>T</title><script src='x.js'>")).text, "One\nTwo")
        XCTAssertEqual(try recovered(page("<p>One</b></p><style>p{}</style><p>Two</p>", head: "<title>T</title><style>")).text, "One\nTwo")
    }

    // `</html>` or `</body>` is not such an end tag. A head script or style that begins with one
    // and goes on with text runs to the end of the file, as it does in HTML, and the tree has no
    // body. libxml2 used to close the root at that `</html>` and, after a DOCTYPE, build the rest
    // in a second root, with the style sheet as its first paragraph.
    func testAHeadScriptOrStyleWithNoEndTagThatBeginsWithADocumentEndTagHasNoBody() throws {
        for head in ["<style></html>p { }", "<script></html>var a;", "<script></body>var a;"] {
            let publication = try book("<!DOCTYPE html>\n" + page("<p>One</b></p><p>Two</p>", head: "<title>T</title>\(head)"))
            XCTAssertThrowsError(try publication.textSection(at: 0, recoversMalformedMarkup: true), head) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), head)
            }
        }
        // Where `</head>` follows it directly, that closes the element and the body is read.
        XCTAssertEqual(try recovered(page("<p>One</b></p><p>Two</p>", head: "<title>T</title><style></html>")).text, "One\nTwo")
    }

    // The bytes of a body end tag reach the declaration check, as they did before the tag was
    // rewritten at all: a keyword inside one refuses the document.
    func testADeclarationKeywordInsideABodyEndTagIsRefused() throws {
        for end in ["</body <!ENTITY a \"b\">", "</html x='<!DOCTYPE html ['>", "</BODY <!attlist p q CDATA #IMPLIED>"] {
            let publication = try book(page("<p>x</b></p>\(end)<p>y</p>"))
            XCTAssertThrowsError(try publication.textSection(at: 0, recoversMalformedMarkup: true), end) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), end)
            }
        }
    }

    // MARK: What a "<" kept as text brings into view (#235)

    // HTML Standard, comment start state: ">" directly after "<!--" or "<!---" closes the comment
    // (abrupt-closing-of-empty-comment). libxml2 reads on to the next "-->". It used to discard
    // from a stray "<" through the next ">", which is this comment's own, and show what follows.
    func testAnAbruptlyClosedCommentAfterAKeptLessThanSignHidesNothing() throws {
        XCTAssertEqual(try recovered(page("<p>a</b> <<!--> b</p><p>c</p>")).text, "a < b\nc")
        XCTAssertEqual(try recovered(page("<p>a</b> < 3 <!---> b</p><p>c --> d</p>")).text, "a < 3 b\nc --> d")
        // Where no such sign precedes it, libxml2 hid the text to the next "-->" before as well.
        XCTAssertEqual(try recovered(page("<p>a</b> <!--> b</p><p>c --> d</p>")).text, "a d")
    }

    // With the comment closed, the scan reads what follows it, which it used to copy as comment.
    // A CDATA section or a quoted attribute value there that never ends refused a section that
    // was read before. The comment is then left as it is, for libxml2 to read to its "-->".
    func testAnAbruptlyClosedCommentBeforeAnUnterminatedSectionOrValueRefusesNothing() throws {
        XCTAssertEqual(try recovered(page("<p>a</b> < <!--> b <![CDATA[c</p><p>d</p>")).text, "a <")
        XCTAssertEqual(try recovered(page("<p>a</b> < <!---> b <p title='c</p><p>d</p>")).text, "a <")
        XCTAssertEqual(try recovered(page("<p>a</b> < <!--> b <![CDATA[c</p><p>d --> e</p>")).text, "a < e")
        // A CDATA section that ends is read, and one outside any comment is still refused.
        XCTAssertEqual(try recovered(page("<p>a</b> < <!--> b <![CDATA[c]]></p><p>d</p>")).text, "a < b c\nd")
        for body in ["<p>a</b> < b <![CDATA[c</p><p>d</p>", "<p>a</b> < b <p title='c</p><p>d</p>"] {
            XCTAssertThrowsError(try book(page(body)).textSection(at: 0, recoversMalformedMarkup: true), body) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), body)
            }
        }
    }

    // MARK: Self-closing html, head and body start tags, which reach libxml2 as written

    // libxml2 ignores a self-closing `<html/>`, `<head/>` or `<body/>` that is out of place and
    // then lets its "/>" close the element that is open. A repair of the tags was taken out of
    // the fix for #235: each form of it rewrote some tag that libxml2 reads differently from the
    // scan, and lost what both the commit before #226 and main returned. These hold the
    // sections it lost to that result. The tags still reach libxml2 as written; the walk reads
    // what libxml2 builds after them (#292, below).

    // A root start tag that has lost the closing quote of its last attribute runs to the "/>" of
    // the first empty element after it, so libxml2 reads `<html …/>`: it closes that root at once
    // and builds the head and the body in a root it implies. Renamed, the tag opened no root, the
    // title became prose and the body's own start tag was dropped with its id.
    func testARootTagThatHasLostAClosingQuoteKeepsItsTitleTextAndAnchors() throws {
        let document = "<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en><head><meta charset=\"utf-8\"/><title>T</title></head><body id=\"b\"><p>x</p></body></html>"
        for prolog in ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", "<!DOCTYPE html>\n", "<!-- c -->"] {
            let section = try recovered(prolog + document)
            XCTAssertEqual(section.title, "T", prolog)
            XCTAssertEqual(section.text, "x", prolog)
            XCTAssertEqual(section.anchors, ["b": EPUBTextMark(offset: 0, separator: 0)], prolog)
        }
        let chapter = try recovered("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en>
            <head>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
            <title>Chapter 1</title>
            <link rel="stylesheet" type="text/css" href="style.css"/>
            </head>
            <body id="ch1" epub:type="bodymatter">
            <h1 id="h">Chapter 1</h1>
            <p>It was a dark night.</p>
            </body>
            </html>
            """)
        XCTAssertEqual(chapter.title, "Chapter 1")
        XCTAssertEqual(chapter.text, "Chapter 1\nIt was a dark night.")
        XCTAssertEqual(chapter.anchors, ["ch1": EPUBTextMark(offset: 0, separator: 0), "h": EPUBTextMark(offset: 0, separator: 0)])
        XCTAssertEqual(chapter.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 0, separator: 0), text: "Chapter 1")])
        // The prefix was declared on the root that closed, so `epub:type` names no type here.
        XCTAssertEqual(chapter.semanticTypes, [])
    }

    // The same with the closing quote of the DOCTYPE's last identifier dropped as well. libxml2
    // reads that literal on to the root's first quote and passes over the rest of the root's
    // start tag, which the scan reads on to the "/>" of the first empty element. An end tag
    // written there closed the head before its title, or the root before the last paragraph.
    func testAChapterThatHasLostTwoClosingQuotesKeepsItsTitleAndItsLastParagraph() throws {
        let start = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en>\n"
        for head in ["<head><meta charset=\"utf-8\"/><title>T</title></head>", "<head><meta charset='utf-8'/><title>T</title></head>", "<head><title>T</title></head>"] {
            let section = try recovered("\(start)\(head)\n<body><p>x</p><img src=\"a.png\" alt=\"A\"/><p>z</p></body>\n</html>")
            XCTAssertEqual(section.title, "T", head)
            XCTAssertEqual(section.text, "x\nA\nz", head)
        }
    }

    // libxml2 reads an attribute name only from a letter, "_", ":" or ".", cuts it at 100 bytes,
    // and passes over anything else to the next white space or ">", quotes and all. The scan
    // reads a name and a quoted value, as HTML does, on to the "/>" of a later tag. For libxml2
    // the start tag ended at the first ">" and that "/>" is the later tag's: rewritten, it left
    // the `<script …/>` open over the rest of the section, or closed the head before its title.
    func testATagThatLibxml2EndsSoonerThanTheScanLeavesALaterEmptyElementAlone() throws {
        let root = "<html xmlns='http://www.w3.org/1999/xhtml'>", long = String(repeating: "a", count: 100)
        for body in ["<body \(long)1=\"x><p>x</p><script src=\"k.js\"/><p>y</p></body>", "<body><p>x</p><body \(long)-=\"x><script src=\"k.js\"/><p>y</p></body>",
                     "<body /x=\"a><p>x</p><script src=\"k.js\"/><p>y</p></body>", "<body 1=\"a><p>x</p><script src=\"k.js\"/><p>y</p></body>",
                     "<body><p>x</p><body /x=\"a><script src=\"k.js\"/><p>y</p></body>", "<body><p>x</p><head /x=\"a><script src=\"k.js\"/><p>y</p></body>",
                     "<body><p>x</p><html /x=\"a><script src=\"k.js\"/><p>y</p></body>"] {
            let section = try recovered("\(root)<head><title>T</title></head>\(body)</html>")
            XCTAssertEqual(section.title, "T", body)
            XCTAssertEqual(section.text, "x\ny", body)
        }
        for head in ["<head \(long)1=\"x>", "<head /x=\"a>"] {
            let section = try recovered("\(root)\(head)<meta charset=\"utf-8\"/><title>T</title></head><body id='b'><p>x</p></body></html>")
            XCTAssertEqual(section.title, "T", head)
            XCTAssertEqual(section.text, "x", head)
            XCTAssertEqual(section.anchors, ["b": EPUBTextMark(offset: 0, separator: 0)], head)
        }
        for prolog in ["<?xml version=\"1.0\"?>", ""] {
            let section = try recovered("\(prolog)<html xmlns=\"http://www.w3.org/1999/xhtml\" /x=\"a><head><title>T</title></head><body id='b'><p>x</p><img alt=\"i\"/><p>y</p></body></html>")
            XCTAssertEqual(section.title, "T", prolog)
            XCTAssertEqual(section.text, "x\ni\ny", prolog)
            XCTAssertEqual(section.anchors, ["b": EPUBTextMark(offset: 0, separator: 0)], prolog)
        }
    }

    // Where the scan reads such a tag and libxml2 reads no tag there at all: it is still inside
    // an earlier start tag whose quotes it pairs differently, in a script the scan has left or
    // never entered, or in a processing instruction. What was written for the tag was read as
    // something else, and the rest of the section or the title went with it.
    func testASelfClosingTagThatLibxml2DoesNotReadAsATagIsLeftAsWritten() throws {
        let earlier = try recovered(page("<p>x</p><p @k=\"v w=\"u> q \"<html/><h2 id=\"h7\">Head</h2><p id=\"last\">Last.</p>"))
        XCTAssertEqual(earlier.text, "x\nHead\nLast.")
        XCTAssertEqual(earlier.anchors, ["h7": EPUBTextMark(offset: 2, separator: 1), "last": EPUBTextMark(offset: 7, separator: 1)])
        XCTAssertEqual(try recovered(page("<p>x</p><p 1=\"a b=\"c> text \" <html d/><p>rest</p>")).text, "x\nrest")
        XCTAssertEqual(try recovered(page("<p>x</p>", head: "<meta 1=\"a b=\"c> \" <head d/><title>T</title>")).title, "T")
        for script in ["<script\"q>var a;", "<script>y</scriptx> a "] {
            XCTAssertEqual(try recovered(page("<p>x</p>\(script)<html a=\"</script>\"/><p>rest</p>")).text, "x\n\"/>\nrest", script)
        }
        for open in ["<?x ", "<!x "] {
            XCTAssertEqual(try recovered(page("<p>x &</p>", head: "\(open)<head a/><title>T</title>")).title, "T", open)
        }
    }

    // MARK: What libxml2 builds after an out-of-place self-closing tag (#292)

    // `<head/>` closes the paragraph and then the body; libxml2 builds the rest in the root. HTML
    // ignores the tag and reads on in the body.
    func testTheRestOfASectionAfterAnOutOfPlaceSelfClosingHeadIsRead() throws {
        XCTAssertEqual(try recovered(page("<p>One</b> < 3 <head/> more</p><p>Two</p>")).text, "One < 3\nmore\nTwo")
        XCTAssertEqual(try recovered(page("<p>a</b> <p>b <head/> c</p><div>d <body/> e</div><p>f</p>")).text, "a\nb\nc\nd e\nf")
    }

    // HTML Standard, "in body" insertion mode, a `body` start tag: its attributes go to the body,
    // which reads on. libxml2 builds a second body where an out-of-place `<body/>` has closed the
    // first; it goes on with the first, and its id and type are kept where it stands.
    func testASecondBodyGoesOnWithTheFirst() throws {
        XCTAssertEqual(try recovered(page("<p>before</b></p><body/><body/><p>next</p>")).text, "before\nnext")
        let section = try recovered(page("<p>before</b></p><body/><body id='b2' epub:type='x'/><p id='n'>next</p>"))
        XCTAssertEqual(section.text, "before\nnext")
        XCTAssertEqual(section.anchors, ["b2": EPUBTextMark(offset: 7, separator: 1), "n": EPUBTextMark(offset: 7, separator: 1)])
        XCTAssertEqual(section.semanticTypes, ["x"])
        XCTAssertEqual(try recovered(page("<p>One</b></p><body/><html/><body/><p>Two</p>")).text, "One\nTwo")
        // On the strict path a well-formed document with two bodies is still not a section.
        let twice = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>a</p></body><body><p>b</p></body></html>"
        XCTAssertThrowsError(try book(twice).textSection(at: 0, recoversMalformedMarkup: true)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path))
        }
    }

    // A `<` kept as text brings such a tag into view: before #226 everything from it to the next
    // ">" was discarded, the tag with it.
    func testWhatALessThanSignKeptAsTextBringsIntoViewKeepsTheTextAfterIt() throws {
        XCTAssertEqual(try recovered(page("<p>before</p><<body/><p>next</p>")).text, "before\n<\nnext")
        XCTAssertEqual(try recovered("<<head/>h").text, "<\nh")
    }

    // libxml2 closes the head at `<head/>` in place, or at `<html/>` or `<head/>` inside it, and
    // builds the title in the root; HTML builds it in the head.
    func testATitleLibxml2BuildsInTheRootBeforeTheBodyIsTheTitle() throws {
        for head in ["<html/><title>T2</title>", "<head/><title>T2</title>"] {
            XCTAssertEqual(try recovered(page("<p>x</b></p>", head: head)).title, "T2", head)
        }
        let section = try recovered("<html><head/><title>T</title><body><p>x</b></p></body></html>")
        XCTAssertEqual(section.title, "T")
        XCTAssertEqual(section.text, "x")
    }

    // Once the root it had open is closed, libxml2 opens another in it for what follows; its
    // head and body are the section's (#287).
    func testARootLibxml2OpensInsideTheFirstIsReadAsTheRoot() throws {
        for start in ["</p><html/>", "<html/>"] {
            let section = try recovered(start + "<head><title>T</title></head><body id='b'><p>x</b></p></body></html>")
            XCTAssertEqual(section.title, "T", start)
            XCTAssertEqual(section.text, "x", start)
            XCTAssertEqual(section.anchors, ["b": EPUBTextMark(offset: 0, separator: 0)], start)
        }
    }

    // HTML Standard, "in body" insertion mode, U+0000: a parse error; the character is ignored.
    // doc/text-extraction.md: recovery "never yields partial text". Refusing the document would
    // also honour that; returning only what precedes the NUL does not.
    func testRecoveryDoesNotSilentlyTruncateAtANULCharacter() throws {
        let publication = try book(page("<p>before</b></p>\u{0}<p>after</p>"))
        guard let section = try? publication.textSection(at: 0, recoversMalformedMarkup: true) else { return }
        XCTAssertEqual(section.text, "before\nafter")
    }

    // HTML Standard, tokenization: U+0000 in an attribute value, a comment or script data is
    // read as U+FFFD. libxml2 ends its input at the character wherever it falls, so a NUL in the
    // first attribute used to empty the section.
    func testRecoveryReadsPastANULCharacterWhereverItFalls() throws {
        let section = try recovered(page("<p id='a\u{0}b'>be\u{0}fore</b> <img alt='pi\u{0}c'/></p>\u{0}<!-- c\u{0} --><script>d\u{0}</script>"
            + "<p>after<![CDATA[ e\u{0}f]]></p>\u{0}", head: "<title>T\u{0}t</title>"))
        XCTAssertEqual(section.title, "Tt")
        XCTAssertEqual(section.text, "before pi\u{FFFD}c\nafter ef")
        XCTAssertEqual(section.anchors, ["a\u{FFFD}b": EPUBTextMark(offset: 0, separator: 0)])
    }

    // Dropping the character must not make markup of the bytes around it. HTML reads "<\0b>" as
    // text; "</\0body>" and "<!-\0-" are not the end tag and the comment opener they resemble,
    // either of which would hide the paragraph after them.
    func testDroppingANULCharacterNeverJoinsBytesIntoMarkup() throws {
        let lines = try recovered(page("<p>a <\u{0}b> c</b></p><p>d </\u{0}body> <!-\u{0}- e --></p><p>f</p>")).text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "a <b> c")
        XCTAssertEqual(lines.last, "f")
    }

    // One pass over the bytes: a section of nothing but these defects, twenty thousand times
    // over and well inside the input limit, is read whole.
    func testASectionOfNothingButTheseDefectsIsReadWhole() throws {
        let count = 20_000
        let section = try recovered(page(String(repeating: "a < b\u{0}</body></html>", count: count) + "<p>end</p>"))
        XCTAssertEqual(section.text, String(repeating: "a < b", count: count) + "\nend")
    }
}
