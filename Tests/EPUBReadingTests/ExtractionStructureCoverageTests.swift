import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest

/// Block, inline and whitespace structure of extracted text, and the positions reported for it,
/// against doc/text-extraction.md ("Contract" and "Positions").
final class ExtractionStructureCoverageTests: XCTestCase {
    private func document(_ xml: String) throws -> EPUBTextSection {
        try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xml])).textSection(at: 0)
    }
    private func section(_ body: String, head: String = "<title>T</title>") throws -> EPUBTextSection {
        try document("<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'>"
            + "<head>\(head)</head><body>\(body)</body></html>")
    }
    /// A body read by the recovery parser: the markup given must not be well-formed XML.
    private func recovered(_ body: String) throws -> EPUBTextSection {
        let extracted = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml":
            "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body>\(body)</body></html>"]))
            .textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(extracted.recoveredAsHTML)
        return extracted
    }
    private func mark(_ offset: Int, _ separator: Int) -> EPUBTextMark { EPUBTextMark(offset: offset, separator: separator) }

    // MARK: Blocks and inline content

    func testNestedListsDefinitionListsAndTablesSeparateEveryItem() throws {
        XCTAssertEqual(try section("<ul><li>One<ul><li>Sub</li></ul></li><li>Two</li></ul><ol><li>Three</li></ol>"
            + "<dl><dt>Term</dt><dd>Meaning</dd></dl>").text, "One\nSub\nTwo\nThree\nTerm\nMeaning")
        XCTAssertEqual(try section("<table><caption>Cap</caption><thead><tr><th>H1</th><th>H2</th></tr></thead>"
            + "<tbody><tr><td>A</td><td>B</td></tr></tbody><tfoot><tr><td>F</td></tr></tfoot></table>After").text,
            "Cap\nH1\nH2\nA\nB\nF\nAfter")
    }

    func testQuotesFiguresAndSectioningElementsAreBlocksAroundBareText() throws {
        XCTAssertEqual(try section("<header>Top</header><main><article><section><blockquote>Quote</blockquote>"
            + "<figure><img alt='Pic'/><figcaption>Caption</figcaption></figure><address>Addr</address><aside>Side</aside>"
            + "</section></article></main><nav>Nav</nav><footer>Foot</footer>").text,
            "Top\nQuote\nPic\nCaption\nAddr\nSide\nNav\nFoot")
        XCTAssertEqual(try section("a<div>b</div>c<p>d</p>e<pre>f</pre>g").text, "a\nb\nc\nd\ne\nf\ng")
    }

    // HTML Standard, Rendering ("Flow content", "The fieldset and legend elements", "The details
    // and summary elements"): details, summary, fieldset, legend and center (with dialog, form,
    // hgroup, menu, dir, search, listing, plaintext, xmp) are `display: block`, as in this
    // package's own reader (UserAgentStyleSheet.swift). Their text must not run into what follows.
    func testDisclosureFormAndLegacyBlockElementsDoNotRunTheirTextTogether() throws {
        XCTAssertEqual(try section("<details><summary>Answer</summary>Forty-two</details>").text, "Answer\nForty-two")
        XCTAssertEqual(try section("<fieldset><legend>Question 1</legend>Pick one</fieldset>").text, "Question 1\nPick one")
        XCTAssertEqual(try section("<center>Title</center>Text").text, "Title\nText")
        XCTAssertEqual(try section("a<dialog open='open'>b</dialog>c<dir>d</dir>e<form>f</form>g<hgroup>h</hgroup>i"
            + "<listing>j</listing>k<menu>l</menu>m<plaintext>n</plaintext>o<search>p</search>q<xmp>r</xmp>s").text,
            "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq\nr\ns")
        // The same in a recovered tree; the unclosed `<br>` is not well-formed XML.
        XCTAssertEqual(try recovered("<details><summary>Answer</summary>Forty-two<br></details>"
            + "<fieldset><legend>Question 1</legend>Pick one</fieldset><center>Title</center>Text").text,
            "Answer\nForty-two\nQuestion 1\nPick one\nTitle\nText")
    }

    // HTML Standard, Rendering ("The select element"): option and optgroup are `display: block`.
    func testTheOptionsOfASelectDoNotRunTheirTextTogether() throws {
        XCTAssertEqual(try section("<p>Pick <select><option>One</option><option>Two</option></select> now</p>").text,
            "Pick\nOne\nTwo\nnow")
        XCTAssertEqual(try section("<select><optgroup label='Odd'><option>One</option><option>Three</option></optgroup>"
            + "<optgroup label='Even'><option>Two</option></optgroup></select>After").text, "One\nThree\nTwo\nAfter")
        // Options whose end tags are left out, as HTML allows, are read by the recovery parser.
        XCTAssertEqual(try recovered("<p>Pick <select><option>One<option>Two</select> now</p>").text, "Pick\nOne\nTwo\nnow")
    }

    // The contract is structural, not the visible text: what HTML does not display is kept.
    func testTheTextOfHiddenElementsClosedDetailsAndDialogsIsIncluded() throws {
        XCTAssertEqual(try section("<p hidden='hidden'>Hidden</p><details><summary>Shown</summary>Folded</details>"
            + "<dialog>Shut</dialog>").text, "Hidden\nShown\nFolded\nShut")
    }

    // An anchor on inline text after such an element marks that text past the newline.
    func testAnInlineAnchorAfterASummaryCountsTheNewlineBeforeIt() throws {
        let extracted = try section("<details><summary id='s'>Answer</summary><span id='t'>Forty-two</span></details>")
        XCTAssertEqual(extracted.anchors["s"], mark(0, 0))
        XCTAssertEqual(extracted.anchors["t"], mark(7, 1))
    }

    func testInlineElementsCommentsAndProcessingInstructionsNeverSplitWords() throws {
        let text = try section("<p>H<sub>2</sub>O, E=mc<sup>2</sup>, <a href='#x'>li</a>nk, <span><b><i><u>ne</u></i></b></span>sted, "
            + "un<wbr/>broken, co<!-- c -->mm<?pi x?>ent, <code>co</code><kbd>de</kbd><abbr>ab</abbr><q>q</q><cite>c</cite>"
            + "<mark>m</mark><small>s</small><time>t</time></p>").text
        XCTAssertEqual(text, "H2O, E=mc2, link, nested, unbroken, comment, codeabqcmst")
    }

    func testRepeatedLineBreaksAndRulesGiveOneNewlineAndNeverLeadOrTrail() throws {
        XCTAssertEqual(try section("<br/><p>a<br/><br/>b</p><hr/><hr/><p>c</p><br/>").text, "a\nb\nc")
        XCTAssertEqual(try section("<hr/><br/><hr/>").text, "")
    }

    // MARK: Whitespace

    func testPrettyPrintedMarkupCollapsesIndentationTabsAndLineEndings() throws {
        let text = try section("\n\t<div>\r\n\t\t<p>\n\t\t\tIndented\n\t\t\ttext\r\n\t\t</p>\n\t\t<p>\tSecond\t</p>\r\n\t</div>\n").text
        XCTAssertEqual(text, "Indented text\nSecond")
    }

    func testWhitespaceAtInlineAndBlockBoundariesCollapsesToOneSeparator() throws {
        XCTAssertEqual(try section("<p> a <b> b </b> c<i> d</i>e <span> </span> f</p><div>g <p> h </p> i</div>").text,
            "a b c de f\ng\nh\ni")
        XCTAssertEqual(try section("<p>a<![CDATA[  ]]>b<![CDATA[]]>c</p>").text, "a bc")
    }

    // The contract normalizes all whitespace; no element or attribute opts out.
    func testPreformattedTextAndXMLSpacePreserveAreNormalizedLikeProse() throws {
        XCTAssertEqual(try section("<pre>line 1\n  line 2\n\tline 3</pre><p xml:space='preserve'>a   b\n c</p>").text,
            "line 1 line 2 line 3\na b c")
    }

    func testNoBreakAndWideSpacesNormalizeWhileZeroWidthCharactersSurvive() throws {
        let text = try section("<p>a&#xA0;&#xA0;b &#xA0; c</p><p>\u{3000}全角\u{3000}空白\u{3000}</p><p>x\u{2028}y\u{2029}z\u{2003}w</p>"
            + "<p>a\u{200B}b\u{AD}c\u{2060}d\u{200D}e\u{200C}f</p>").text
        XCTAssertEqual(text, "a b c\n全角 空白\nx y z w\na\u{200B}b\u{AD}c\u{2060}d\u{200D}e\u{200C}f")
    }

    // doc/architecture.md: the reader "preserves literal and numeric-reference U+FEFF word joiners".
    func testWordJoinersSurviveInTitlesAlternativesAndAtTheEdgesOfText() throws {
        let extracted = try section("<p>\u{FEFF}start <img alt='a\u{FEFF}b'/> end\u{FEFF}</p><p>&#xFEFF;</p>",
            head: "<title>\u{FEFF}Ti&#xFEFF;tle</title>")
        XCTAssertEqual(extracted.title, "\u{FEFF}Ti\u{FEFF}tle")
        XCTAssertEqual(extracted.text, "\u{FEFF}start a\u{FEFF}b end\u{FEFF}\n\u{FEFF}")
    }

    // Unicode shows an isolated combining mark on a space or no-break space (The Unicode Standard,
    // 7.9 "Combining Marks"), and grammars list dependent vowel signs separated by spaces. Each
    // mark is body character data, not whitespace.
    func testCombiningSignsThatFollowASpaceAreNotDroppedAsWhitespace() throws {
        let signs = try section("<p>Signs: \u{093E} \u{093F} \u{0940}</p>").text
        for sign in ["\u{093E}", "\u{093F}", "\u{0940}"] as [Unicode.Scalar] {
            XCTAssertTrue(signs.unicodeScalars.contains(sign), String(format: "U+%04X is missing from ", sign.value) + signs.debugDescription)
        }
        XCTAssertEqual(signs, "Signs: \u{093E} \u{093F} \u{0940}")
        let acute = try section("<p>acute:&#xA0;&#x301;.</p>").text
        XCTAssertTrue(acute.unicodeScalars.contains("\u{301}"), "U+0301 is missing from \(acute.debugDescription)")
        XCTAssertEqual(acute, "acute: \u{301}.")
    }

    func testCombiningSignsInTitlesHeadingsAndImageAlternativesHaveUTF8Marks() throws {
        let heading = "Signs: \u{093E} \u{093F}"
        let extracted = try section("<h2 id='h'>Signs: \u{093E}<img id='image' alt='&#xA0;&#x93F;'/></h2><p id='after'>Next</p>",
            head: "<title>Title:&#xA0;&#x301;</title>")
        XCTAssertEqual(extracted.title, "Title: \u{301}")
        XCTAssertEqual(extracted.text, heading + "\nNext")
        XCTAssertEqual(extracted.headings, [EPUBTextHeading(mark: mark(0, 0), text: heading)])
        XCTAssertEqual(extracted.anchors, ["h": mark(0, 0), "image": mark("Signs: \u{093E} ".utf8.count, 1),
            "after": mark((heading + "\n").utf8.count, 1)])

        // A combining mark alone is a nonempty alternative; leading whitespace is still trimmed.
        let isolated = try section("<h2> <img alt=' \u{301}'/><br/> \u{093E}</h2>")
        XCTAssertEqual(isolated.text, "\u{301}\n\u{093E}")
        XCTAssertEqual(isolated.headings.map(\.text), ["\u{301} \u{093E}"])
    }

    func testCombiningSignsNormalizeAcrossTextNodesAndCountTowardOutputLimits() throws {
        let body = "<p> \u{093E} a&#xA0;<span id='accent'>&#x301;</span><b id='after'>b</b> </p>"
        let extracted = try section(body)
        let expected = "\u{093E} a \u{301}b"
        XCTAssertEqual(extracted.text, expected)
        XCTAssertEqual(extracted.anchors, ["accent": mark("\u{093E} a ".utf8.count, 1),
            "after": mark("\u{093E} a \u{301}".utf8.count, 0)])

        let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml":
            "<html><head/><body>\(body)</body></html>"]))
        var limits = EPUBTextExtractionLimits()
        limits.outputBytes = expected.utf8.count
        XCTAssertEqual(try book.textSection(at: 0, limits: limits).text, expected)
        limits.outputBytes -= 1
        XCTAssertThrowsError(try book.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
    }

    // MARK: Included and excluded content

    func testHiddenNoscriptAndStyledAwayContentIsRetainedBecauseNoCSSOrScriptIsEvaluated() throws {
        XCTAssertEqual(try section("<noscript><p>No script</p></noscript><p hidden='hidden'>Hid</p><p aria-hidden='true'>Aria</p>"
            + "<p style='display:none'>None</p>").text, "No script\nHid\nAria\nNone")
    }

    func testRubyAnnotationsStayInlineInDocumentOrder() throws {
        XCTAssertEqual(try section("<p><ruby>漢<rp>(</rp><rt>kan</rt><rp>)</rp></ruby>字</p>").text, "漢(kan)字")
    }

    func testEmbeddedSVGTitleDescriptionAndLabelsAreTextButNeverTheSectionTitle() throws {
        let extracted = try section("<p>Lead</p><svg xmlns='http://www.w3.org/2000/svg'>\n<title>Chart</title>\n<desc>Sales</desc>\n"
            + "<text id='lbl'>One</text>\n<text>Two</text>\n</svg>", head: "")
        XCTAssertNil(extracted.title)
        XCTAssertEqual(extracted.text, "Lead\nChart Sales One Two")
        XCTAssertEqual(extracted.anchors["lbl"], mark("Lead\nChart Sales ".utf8.count, 1))
    }

    // MARK: Semantic types

    func testSemanticTypesOnBodyNoterefsPagebreaksAndFootnotesAreReportedAsWritten() throws {
        let extracted = try document("<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops' epub:type='x-root'>"
            + "<head><title>T</title></head><body id='b' epub:type='frontmatter  titlepage'>"
            + "<p>One <span epub:type='pagebreak' id='p1' title='1'/>two<a epub:type='noteref  Noteref\n noteref' href='#n1'>1</a></p>"
            + "<aside epub:type='footnote' id='n1'><p>Note</p></aside></body></html>")
        // Tokens are reported as written (no case folding); the root element is outside the body.
        XCTAssertEqual(extracted.semanticTypes, ["frontmatter", "titlepage", "pagebreak", "noteref", "Noteref", "footnote"])
        XCTAssertEqual(extracted.text, "One two1\nNote")
        XCTAssertEqual(extracted.anchors, ["b": mark(0, 0), "p1": mark(4, 1), "n1": mark(9, 1)])
    }

    func testPlainTypeAttributesAreNotSemanticTypes() throws {
        let extracted = try section("<ol type='1'><li><input type='checkbox'/> <a type='text/html' href='x'>y</a></li></ol>"
            + "<p epub:type='real' type='plain'>x</p>")
        XCTAssertEqual(extracted.semanticTypes, ["real"])
    }

    func testWhitespaceSplittingDoesNotDropCombiningScalarsFromSemanticTokens() throws {
        let extracted = try section("<p epub:type='chapter \u{301} custom'>Text</p>")
        XCTAssertEqual(extracted.semanticTypes, ["chapter", "\u{301}", "custom"])
    }

    // MARK: Anchors

    func testAnchorOffsetsCountUTF8BytesAcrossAstralScalarsAndCombiningMarks() throws {
        let extracted = try section("<p>\u{1F600}<span id='a'>x</span> e<i id='acc'>&#x301;</i><b id='c'>z</b></p>"
            + "<h2 id='h'>\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} fam</h2><p id='end'/>")
        XCTAssertEqual(extracted.text, "\u{1F600}x e\u{301}z\n\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} fam")
        XCTAssertEqual(extracted.anchors, ["a": mark(4, 0), "acc": mark(7, 0), "c": mark(9, 0), "h": mark(11, 1), "end": mark(33, 0)])
        let utf8 = Array(extracted.text.utf8)
        XCTAssertEqual(utf8.count, 33)
        XCTAssertNotEqual(extracted.text.utf16.count, utf8.count) // Offsets are UTF-8 bytes, not UTF-16 units.
        XCTAssertEqual(String(decoding: utf8[11...], as: UTF8.self), "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} fam")
        XCTAssertEqual(extracted.headings, [EPUBTextHeading(mark: mark(11, 1), text: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} fam")])
    }

    func testTheFirstOccurrenceOfADuplicateIDWinsAndEmptyIDsAreIgnored() throws {
        let extracted = try section("<p id='a'>One</p><p id='a'>Two</p><p id=''>Three</p><span id='e'/><span id='f'></span>")
        XCTAssertEqual(extracted.text, "One\nTwo\nThree")
        XCTAssertEqual(extracted.anchors, ["a": mark(0, 0), "e": mark(13, 0), "f": mark(13, 0)])
    }

    // IDs compare code unit for code unit, as `getElementById` compares them: `caf&#xE9;` and
    // `cafe&#x301;` are two IDs, though `String` compares them equal.
    func testCanonicallyEquivalentIDsAreTwoAnchors() throws {
        let extracted = try section("<p id='caf&#xE9;'>One</p><p id='cafe&#x301;'>Two</p>")
        XCTAssertEqual(extracted.text, "One\nTwo")
        XCTAssertEqual(extracted.anchors.count, 2)
        XCTAssertEqual(extracted.anchors["caf\u{E9}"], mark(0, 0))
        XCTAssertEqual(extracted.anchors["cafe\u{301}"], mark(4, 1))
        XCTAssertNil(extracted.anchors["cafe"])
    }

    func testIDsOnBodyLineBreaksRulesAndEmptyElementsMarkTheNextText() throws {
        let extracted = try document("<html xmlns='http://www.w3.org/1999/xhtml'><head/><body id='b'><p>a<br id='br'/>b</p>"
            + "<hr id='hr'/><a id='empty'/><p>c</p></body></html>")
        XCTAssertEqual(extracted.text, "a\nb\nc")
        XCTAssertEqual(extracted.anchors, ["b": mark(0, 0), "br": mark(2, 1), "hr": mark(4, 1), "empty": mark(4, 1)])
    }

    func testNestedAndForeignNamespaceElementsReportTheirOwnAnchors() throws {
        let extracted = try section("<p><a id='o'>out <a id='i'>in</a> er</a></p>"
            + "<svg xmlns='http://www.w3.org/2000/svg'><text id='lbl'>Label</text></svg>")
        XCTAssertEqual(extracted.text, "out in er\nLabel")
        XCTAssertEqual(extracted.anchors, ["o": mark(0, 0), "i": mark(4, 1), "lbl": mark(10, 1)])
    }

    // MARK: Headings

    func testHeadingsOfEveryLevelAreReportedInDocumentOrderWithNormalizedText() throws {
        let extracted = try section("<h1>One</h1><section><h2> Two <em>and</em>\n\thalf </h2><h3>Three<br/>lines</h3></section>"
            + "<h4>Caf&#233; &amp; co</h4><h5><a href='#x'>Five</a></h5><h6>Six</h6>"
            + "<p class='h1' role='heading' aria-level='1'>Not a heading</p><h7>Nor this</h7>")
        XCTAssertEqual(extracted.text, "One\nTwo and half\nThree\nlines\nCafé & co\nFive\nSix\nNot a heading\nNor this")
        XCTAssertEqual(extracted.headings.map(\.text), ["One", "Two and half", "Three lines", "Café & co", "Five", "Six"])
        let utf8 = Array(extracted.text.utf8)
        for heading in extracted.headings {
            let first = try XCTUnwrap(heading.text.split(separator: " ").first)
            XCTAssertTrue(utf8[heading.mark.offset...].starts(with: first.utf8), heading.text)
            XCTAssertEqual(heading.mark.separator, heading.mark.offset == 0 ? 0 : 1, heading.text)
            if heading.mark.offset > 0 { XCTAssertEqual(utf8[heading.mark.offset - 1], 0x0A, heading.text) }
        }
    }

    func testEmptyHeadingsHaveEmptyTextAndMarkTheFollowingCharacterOrTheEnd() throws {
        let extracted = try section("<h1></h1><h2> </h2><p>Next</p><h3><img alt='Logo'/></h3><h4/>")
        XCTAssertEqual(extracted.text, "Next\nLogo")
        XCTAssertEqual(extracted.headings, [
            EPUBTextHeading(mark: mark(0, 0), text: ""), EPUBTextHeading(mark: mark(0, 0), text: ""),
            EPUBTextHeading(mark: mark(5, 1), text: "Logo"), EPUBTextHeading(mark: mark(9, 0), text: ""),
        ])
    }

    func testPrefixedXHTMLHeadingsCountAndForeignNamespaceLookalikesDoNot() throws {
        let extracted = try section("<h:h2 xmlns:h='http://www.w3.org/1999/xhtml'>Prefixed</h:h2>"
            + "<svg xmlns='http://www.w3.org/2000/svg'><h1>Foreign</h1></svg><hgroup><h1>Main</h1><p>Sub</p></hgroup>")
        XCTAssertEqual(extracted.headings.map(\.text), ["Prefixed", "Main"])
        XCTAssertEqual(extracted.text, "Prefixed\nForeign\nMain\nSub")
    }
}
