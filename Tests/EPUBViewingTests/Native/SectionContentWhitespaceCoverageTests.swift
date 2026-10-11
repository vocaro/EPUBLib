import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

/// CSS Text 3 section 4 (white space processing) as the section builder applies it to a content
/// document's text, and what the text map says about the characters it removes.
final class SectionContentWhitespaceCoverageTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    private func rendered(_ body: String, rules: [H.Rule] = [], file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let text = try H.build(body, rules: rules)
        S.assertTextMapContracts(text, file: file, line: line)
        return text.string.string
    }

    // MARK: Collapsing

    func testCollapsibleSpacesCollapseAcrossInlineBoundaries() throws {
        XCTAssertEqual(try rendered("<p>a <b> b </b> c</p>"), "a b c")
        XCTAssertEqual(try rendered("<p> <span> </span> x <i></i> y</p>"), "x y")
        XCTAssertEqual(try rendered("<p>a<span> </span>b</p><p>a<span>  </span><span> </span>b</p>"), "a b\na b")
        XCTAssertEqual(try rendered("<p><b>a </b><i> b</i></p><p><b>a</b> <i>b</i></p><p><b>a</b><i>b</i></p>"), "a b\na b\nab")
        XCTAssertEqual(try rendered("<p><span><span><span> deep </span></span></span>.</p>"), "deep .")
    }

    func testACollapsedRunIsOneSpaceMappedToTheWholeRun() throws {
        let text = try H.build("<p>a \n\t b</p>")
        XCTAssertEqual(text.string.string, "a b")
        let node = try XCTUnwrap(S.textNode("a \n\t b", in: text))
        let space = try XCTUnwrap(text.map.spans.first { $0.location == 1 })
        XCTAssertEqual([space.offset, space.sourceLength, space.length], [1, 4, 1])
        XCTAssertFalse(space.isExact)
        // Every source position inside the run is its one rendered space; the run's end is the next character.
        for offset in 1..<5 { XCTAssertEqual(text.map.location(of: DOMPosition(node, offset)), 1, "offset \(offset)") }
        XCTAssertEqual(text.map.location(of: DOMPosition(node, 5)), 2)
        XCTAssertEqual(text.map.position(at: 1, in: text.document), DOMPosition(node, 1))
        XCTAssertEqual(text.map.endPosition(at: 2, in: text.document), DOMPosition(node, 5))
        S.assertTextMapContracts(text)
    }

    func testASingleSpaceBetweenWordsKeepsAParagraphInOneExactSpan() throws {
        let text = try H.build("<p>one two three four</p>")
        XCTAssertEqual(text.map.spans.count, 1)
        XCTAssertEqual(text.map.spans.first.map { [$0.location, $0.length, $0.offset, $0.sourceLength] }, [0, 18, 0, 18])
        XCTAssertEqual(text.map.spans.first?.isExact, true)
    }

    func testCarriageReturnsAndTabsCollapseLikeSpaces() throws {
        // CSS Text 3 section 4: "Carriage returns (U+000D) are treated identically to spaces"; `&#13;` puts one in the DOM.
        XCTAssertEqual(try rendered("<p>a&#13;\nb&#13;c&#9;d&#13;&#13;e</p>"), "a b c d e")
        XCTAssertEqual(try rendered("<p>&#13;a&#9;</p><p>&#9;&#13;</p><p>b</p>"), "a\nb")
    }

    func testWhitespaceOnlyBlocksMakeNoParagraphButANoBreakSpaceDoes() throws {
        XCTAssertEqual(try rendered("<p></p><p> </p><p>\n\t</p><div></div><div><span> </span></div><p>x</p>"), "x")
        XCTAssertEqual(try rendered("<p>a</p><p>&#160;</p><p>b</p>"), "a\n\u{A0}\nb")
        XCTAssertEqual(try rendered(" \n "), "")
    }

    func testNoBreakZeroWidthAndSoftHyphenCharactersArePreservedExactly() throws {
        let text = try H.build("<p>a&#160;&#160;b &#160; c&#8203;d&#173;e&#8239;f&#8288;g&#65279;h</p>")
        XCTAssertEqual(text.string.string, "a\u{A0}\u{A0}b \u{A0} c\u{200B}d\u{AD}e\u{202F}f\u{2060}g\u{FEFF}h")
        XCTAssertEqual(text.map.spans.count, 1)
        XCTAssertEqual(text.map.spans.first?.isExact, true)
        S.assertTextMapContracts(text)
    }

    func testIdeographicAndOtherUnicodeSpacesAreNotCollapsed() throws {
        // Only spaces, tabs and segment breaks are document white space (CSS Text 3 section 4).
        XCTAssertEqual(try rendered("<p>a\u{3000}\u{3000}b \u{3000} c</p>"), "a\u{3000}\u{3000}b \u{3000} c")
        XCTAssertEqual(try rendered("<p>a\u{2003}\u{2003}b\u{2009}\u{2009}c</p>"), "a\u{2003}\u{2003}b\u{2009}\u{2009}c")
    }

    func testHiddenContentAndEmptyElementsDoNotInterruptCollapsing() throws {
        XCTAssertEqual(try rendered("<p>a <span hidden=''>h</span> b</p><p>a<span hidden=''> </span>b</p>"), "a b\nab")
        XCTAssertEqual(try rendered("<p>a <script>x</script> b <a id='e'/> c</p>"), "a b c")
        XCTAssertEqual(try rendered("<p>a <aside epub:type='footnote' id='n'>note</aside> b</p>"), "a b")
    }

    func testSpacesAroundInlineImagesAreKeptOnce() throws {
        XCTAssertEqual(try rendered("<p>a <img src='picture.png' alt='I'/> <img src='picture.png' alt='J'/> b</p>"), "a [I] [J] b")
        XCTAssertEqual(try rendered("<p> <img src='picture.png' alt='I'/> </p><p>a<img src='picture.png' alt='J'/>b</p>"), "[I]\na[J]b")
        XCTAssertEqual(try rendered("<p><img src='picture.png' alt='I'/>\n<img src='picture.png' alt='J'/></p>\n"), "[I] [J]")
    }

    // MARK: Line breaks

    func testLineBreaksRemoveTheSpacesAroundThem() throws {
        XCTAssertEqual(try rendered("<p>a<br/> b</p><p>a <br/>b</p><p>a <br/> <br/> b</p>"), "a\u{2028}b\na\u{2028}b\na\u{2028}\u{2028}b")
        XCTAssertEqual(try rendered("<p>one\n<br/>\ntwo</p>"), "one\u{2028}two")
        XCTAssertEqual(try rendered("<p><br/>a</p><p><b>x<br/></b>y</p>"), "\u{2028}a\nx\u{2028}y")
    }

    func testLineBreaksBetweenBlocksMakeBlankLines() throws {
        // A `<br>` between blocks is a line of its own; one that ends the section makes no line.
        XCTAssertEqual(try rendered("<p>a</p>\n\n<br/>\n<p>b</p><br/><br/><p>c</p>"), "a\n\nb\n\u{2028}\nc")
        XCTAssertEqual(try rendered("<br/><p>x</p><br/>"), "\nx")
        XCTAssertEqual(try rendered("<div><br/><p>x</p></div><div><p>y</p><br/></div><p>z</p>"), "\nx\ny\n\nz")
        XCTAssertEqual(try rendered("<br/>"), "")
    }

    func testAGeneratedLineBreakHasNoSpanAndPositionsStepOverIt() throws {
        let text = try H.build("<p>one<br/>two</p>")
        XCTAssertEqual(text.string.string, "one\u{2028}two")
        XCTAssertTrue(S.isGenerated(3, in: text))
        let one = try XCTUnwrap(S.textNode("one", in: text)), two = try XCTUnwrap(S.textNode("two", in: text))
        XCTAssertEqual(text.map.position(at: 3, in: text.document), DOMPosition(two, 0))
        XCTAssertEqual(text.map.endPosition(at: 3, in: text.document), DOMPosition(one, 3))
        XCTAssertEqual(text.map.endPosition(at: 4, in: text.document), DOMPosition(one, 3))
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "one\ntwo")
    }

    // MARK: Preserved white space

    func testPreformattedTextKeepsInnerAndDropsOneTrailingNewline() throws {
        XCTAssertEqual(try rendered("<pre>x\n</pre><p>after</p>"), "x\nafter")
        XCTAssertEqual(try rendered("<pre>x\n\n</pre><p>after</p>"), "x\u{2028}\nafter")
        XCTAssertEqual(try rendered("<pre>a\n\n\nb</pre>"), "a\u{2028}\u{2028}\u{2028}b")
        XCTAssertEqual(try rendered("<pre>a\tb\t\tc  d </pre>"), "a\tb\t\tc  d ")
        // Only a newline right after the `pre` start tag is the markup's own.
        XCTAssertEqual(try rendered("<pre><code>\nline1\nline2\n</code></pre>"), "\u{2028}line1\u{2028}line2")
        XCTAssertEqual(try rendered("<pre><b>a</b>\n<i>b</i></pre>"), "a\u{2028}b")
    }

    func testPreformattedNewlinesMapOneToOne() throws {
        let text = try H.build("<pre>ab\ncd\n\nef</pre>")
        XCTAssertEqual(text.string.string, "ab\u{2028}cd\u{2028}\u{2028}ef")
        let node = try XCTUnwrap(S.textNode("ab\ncd\n\nef", in: text))
        for offset in 0...node.utf16Length {
            XCTAssertEqual(text.map.location(of: DOMPosition(node, offset)), offset, "offset \(offset)")
        }
        for location in 0..<text.string.length {
            XCTAssertEqual(text.map.position(at: location, in: text.document), DOMPosition(node, location), "location \(location)")
        }
        S.assertTextMapContracts(text)
    }

    func testACarriageReturnLineFeedPairInPreformattedTextIsOneBreak() throws {
        let text = try H.build("<pre>a&#13;\nb</pre>")
        XCTAssertEqual(text.string.string, "a\u{2028}b")
        S.assertTextMapContracts(text)
    }

    func testWhiteSpaceValuesFromTheBooksStylesheet() throws {
        let text = try S.styled("""
            <p class="wrap">a  b\n c </p><p class="line">  a  b \n c\n</p><p class="no">a  b\n c</p><p class="pre">a  b\n c</p>\
            <p style="white-space: pre-wrap">x  y</p><pre class="normal">p   q\n r</pre>
            """, css: ".wrap { white-space: pre-wrap } .line { white-space: pre-line } .no { white-space: nowrap } "
                + ".pre { white-space: pre } .normal { white-space: normal }")
        XCTAssertEqual(S.paragraphs(text), ["a  b\u{2028} c ", "a b\u{2028}c", "a b c", "a  b\u{2028} c", "x  y", "p q r"])
        S.assertTextMapContracts(text)
    }

    func testPreservedSpacesNextToCollapsibleOnesAreAllKept() throws {
        let pre: [H.Rule] = [(".pre", { $0.whiteSpace = .pre })]
        XCTAssertEqual(try rendered("<p>a<span class='pre'>  b  </span>c</p>", rules: pre), "a  b  c")
        // A collapsible space collapses only into another collapsible space (CSS Text 3 section 4.1.1).
        XCTAssertEqual(try rendered("<p>a <span class='pre'> b</span></p><p><span class='pre'>a </span> b</p>", rules: pre), "a  b\na  b")
        XCTAssertEqual(try rendered("<p> <span class='pre'> a </span> </p>", rules: pre), " a ")
    }

    func testPreLineKeepsNewlinesAndCollapsesSpacesAroundThem() throws {
        let rules: [H.Rule] = [(".l", { $0.whiteSpace = .preLine })]
        XCTAssertEqual(try rendered("<p class='l'>  a   b  \n\n  c  \n</p>", rules: rules), "a b\u{2028}\u{2028}c")
        XCTAssertEqual(try rendered("<p class='l'>a\n<b> b</b>\n</p>", rules: rules), "a\u{2028}b")
    }

    func testXMLSpacePreserveDoesNotPreserveSpacesInXHTML() throws {
        // `xml:space` has no rendering effect on HTML elements; only `white-space` does.
        XCTAssertEqual(try rendered("<p xml:space='preserve'>a   b\n c</p>"), "a b c")
    }

    func testSeparatorCharactersInTextNeverEndABuilderParagraph() throws {
        let text = try H.build("<p>a&#8232;b&#8233;c&#133;d</p><p>next</p>")
        XCTAssertEqual(S.paragraphs(text), ["a\u{2028}b\u{2028}c\u{2028}d", "next"])
        XCTAssertEqual((text.string.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)).length, 8)
        S.assertTextMapContracts(text)
    }

    func testWordBreakOpportunitiesAreGeneratedZeroWidthSpaces() throws {
        let text = try H.build("<p>long<wbr/>word</p><p><wbr/>start</p>")
        XCTAssertEqual(text.string.string, "long\u{200B}word\nstart")
        XCTAssertTrue(S.isGenerated(4, in: text))
        XCTAssertEqual(text.mappedText(in: 0..<9), "longword")
        S.assertTextMapContracts(text)
    }

    // MARK: Segment breaks

    func testSegmentBreaksBetweenWideCharactersVanishButNotAroundHangulOrLatin() throws {
        XCTAssertEqual(try rendered("<p>漢字\n<b>かな</b>\nabc\n漢</p>"), "漢字かな abc 漢")
        XCTAssertEqual(try rendered("<p>한국\n어</p>"), "한국 어")
        // A plain space is not a segment break: it stays.
        XCTAssertEqual(try rendered("<p>漢字 かな</p>"), "漢字 かな")
        XCTAssertEqual(try rendered("<p>𠀀\n𠀁</p>"), "𠀀𠀁")
    }

    func testARemovedSegmentBreakLeavesItsNeighboursMappedExactly() throws {
        let text = try H.build("<p>漢字\nかな</p>")
        XCTAssertEqual(text.string.string, "漢字かな")
        let node = try XCTUnwrap(S.textNode("漢字\nかな", in: text))
        XCTAssertEqual(text.map.location(of: DOMPosition(node, 2)), 2)
        XCTAssertEqual(text.map.location(of: DOMPosition(node, 3)), 2)
        XCTAssertEqual(text.map.position(at: 2, in: text.document), DOMPosition(node, 3))
        XCTAssertEqual(text.map.endPosition(at: 2, in: text.document), DOMPosition(node, 2))
        S.assertTextMapContracts(text)
    }

    // MARK: Anonymous blocks, CDATA and entities

    func testTextAndInlinesBesideBlocksFormParagraphsOfTheirOwn() throws {
        XCTAssertEqual(try rendered("text <b>directly</b> in body<p>para</p> tail text"), "text directly in body\npara\ntail text")
        XCTAssertEqual(try rendered("<div>a<p>b</p>c<p>d</p></div>"), "a\nb\nc\nd")
        XCTAssertEqual(try rendered("<div>a</div> <div>b</div>\n<div> </div><div>c</div>"), "a\nb\nc")
        XCTAssertEqual(try rendered("<p>a<div>b</div>c</p>"), "a\nb\nc")
    }

    func testCDATACommentsAndProcessingInstructionsLeaveOneTextNodeForTheMap() throws {
        let text = try H.build("<p>a<![CDATA[ b  <c> ]]>d<!-- x -->e<?page 12?>f</p>")
        XCTAssertEqual(text.string.string, "a b <c> def")
        let node = try XCTUnwrap(S.textNode("a b  <c> def", in: text))
        XCTAssertEqual(text.map.location(of: DOMPosition(node, 5)), 4) // "<"
        XCTAssertEqual(text.map.position(at: 9, in: text.document), DOMPosition(node, 10)) // "e"
        S.assertTextMapContracts(text)
    }

    func testNamedAndNumericCharacterReferencesAreTheirCharacters() throws {
        let text = try S.raw("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head>
            <body><p>caf&eacute;&nbsp;&mdash;&nbsp;na&#239;ve &amp;amp; &lt;b&gt; &#x1F600; &hellip;</p></body></html>
            """)
        XCTAssertEqual(text.string.string, "caf\u{E9}\u{A0}\u{2014}\u{A0}na\u{EF}ve &amp; <b> \u{1F600} \u{2026}")
        XCTAssertFalse(text.report.recoveredAsHTML)
        S.assertTextMapContracts(text)
    }

    // MARK: An independent model

    /// Random inline content under `white-space: normal`, compared with a model of CSS Text 3
    /// section 4.1 written without reference to the builder.
    func testCollapsingAgreesWithAnIndependentModelOnRandomContent() throws {
        let words = ["alpha", "b", "γάμμα", "x", "naïve", "e\u{301}", "😀", "1984", "o'neil", "\u{A0}", "—", "end."]
        let spaces = ["", "", " ", " ", "  ", "\n", " \t ", "\n  ", "\r\n", "\t"]
        var random = SectionContentRandom(state: 0x5EC7_C0DE)
        func inline(_ depth: Int, into model: inout SectionContentWhitespaceModel) -> String {
            var html = ""
            for _ in 0..<(1 + random.next(4)) {
                switch random.next(depth > 2 ? 4 : 12) {
                case 0, 1, 2, 3:
                    let text = random.pick(spaces) + random.pick(words) + random.pick(spaces)
                    html += text.replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\u{A0}", with: "&#160;")
                    model.append(.text(text))
                case 4: html += "<br/>"; model.append(.lineBreak)
                case 5: let space = random.pick(spaces); html += space.replacingOccurrences(of: "\r", with: "&#13;"); model.append(.text(space))
                case 6: html += "<img src='picture.png' alt='I'/>"; model.append(.atom("[I]"))
                case 7: html += "<span hidden=''> hidden text </span>"
                case 8: html += "<!-- comment -->"
                default:
                    let tag = random.pick(["span", "em", "b", "i", "a", "small", "code", "u"])
                    html += "<\(tag)>" + inline(depth + 1, into: &model) + "</\(tag)>"
                }
            }
            return html
        }
        func block(_ depth: Int, into model: inout SectionContentWhitespaceModel) -> String {
            var html = ""
            for _ in 0..<(1 + random.next(3)) {
                if depth < 3, random.chance(3) {
                    let tag = random.pick(["p", "div", "section", "blockquote", "h2"])
                    model.append(.boundary)
                    html += "<\(tag)>" + block(depth + 1, into: &model) + "</\(tag)>" + random.pick(["", "\n", "\n  "])
                    model.append(.boundary)
                } else { html += inline(0, into: &model) }
            }
            return html
        }
        var failures: [(body: String, expected: String, actual: String)] = []
        for _ in 0..<400 {
            var model = SectionContentWhitespaceModel()
            // A last node that is an image is its own case (see the text-map tests): end with white space, as most markup does.
            let body = block(0, into: &model) + "\n"
            let text = try H.build(body)
            if text.string.string != model.rendered { failures.append((body, model.rendered, text.string.string)) }
            let violations = S.mapViolations(text) + S.rangeViolations(text) + S.locationViolations(text) + S.stringViolations(text)
            XCTAssertEqual(violations, [], "in \(body)")
        }
        if let smallest = failures.min(by: { $0.body.utf8.count < $1.body.utf8.count }) {
            XCTFail("\(failures.count) of 400 documents differ from the model; the smallest is \(S.escape(smallest.body)): "
                + "expected \(S.escape(smallest.expected)), built \(S.escape(smallest.actual))")
        }
    }
}
