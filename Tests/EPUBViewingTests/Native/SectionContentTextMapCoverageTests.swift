import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing

/// `TextMap` and `SectionText.mappedText` over everything the builder adds, removes or replaces:
/// rendered range to DOM range and back, at every boundary.
final class SectionContentTextMapCoverageTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    /// Short documents, one per kind of span boundary, so every pair of locations is checked.
    private static let documents: [(name: String, body: String)] = [
        ("words", "<p>one two</p>"),
        ("collapsed", "<p> a  \n b\t</p><p>c   d</p>"),
        ("inline", "<p>a<b>b</b><i> c </i>d</p>"),
        ("breaks", "<p>a<br/>b<br/><br/>c</p>"),
        ("astral", "<p>😀 a\u{301}  b𝒳</p>"),
        ("list", "<ol><li>a</li><li><p>b</p></li><li></li></ol><p>c</p>"),
        ("quotes", "<p>x <q>y <q>z</q></q>.</p>"),
        ("isolates", "<p>a <bdo dir='rtl'>b</bdo> <span dir='rtl'>c</span></p>"),
        ("images", "<p>a <img src='picture.png' alt='I'/> b</p><img src='picture.png' alt='J'/><p>c</p>"),
        ("rule", "<p>a</p><hr/><p>b</p>"),
        ("hidden", "<p>a <span hidden=''>h</span> b</p><div hidden=''>x</div><p>c</p>"),
        ("notes", "<p>a<a epub:type='noteref' href='#n'>1</a></p><aside epub:type='footnote' id='n'>note</aside><p>b</p>"),
        ("pre", "<pre>\n a\n\n\tb\n</pre><p>c</p>"),
        ("ruby", "<p>前<ruby>漢<rt>kan</rt>字<rt>ji</rt></ruby>後</p>"),
        ("wbr", "<p>ab<wbr/>cd</p>"),
        ("table", "<table><tr><td>a</td><td>b <b>c</b></td></tr><tr><td/><td>d</td></tr></table><p>e</p>"),
        ("callout", "<table><tr><td><p>a</p><p>b</p></td></tr></table>"),
        ("cjk", "<p>漢字\nかな\nab</p>"),
        ("blank", "<p>a</p><p><br/></p><p>&#160;</p><p>b</p>"),
        ("dl", "<dl><dt>t</dt><dd>d</dd></dl>"),
        ("media", "<p>a<video>fallback</video>b<object data='x.bin'>obj</object></p>"),
        ("switch", "<p>a<epub:switch><epub:case required-namespace='urn:x'>c</epub:case><epub:default>d</epub:default></epub:switch>b</p>"),
    ]

    func testEveryRenderedRangeBecomesADOMRangeAndBack() throws {
        for (name, body) in Self.documents {
            let text = try H.build(body)
            XCTAssertEqual(S.mapViolations(text), [], "\(name): \(S.escape(text.string.string))")
            XCTAssertEqual(S.rangeViolations(text), [], "\(name): \(S.escape(text.string.string))")
        }
    }

    func testLocationsFollowDocumentOrderForEveryDOMPosition() throws {
        for (name, body) in Self.documents {
            let text = try H.build(body)
            XCTAssertEqual(S.locationViolations(text), [], "\(name): \(S.escape(text.string.string))")
            XCTAssertEqual(S.stringViolations(text), [], "\(name): \(S.escape(text.string.string))")
        }
    }

    func testTransformedAndUnitContentKeepsTheSameContracts() throws {
        let rules: [H.Rule] = [(".u", { $0.textTransform = .uppercase }), (".c", { $0.textTransform = .capitalize }),
                               (".w", { $0.wordSpacing = 3 }), (".f", { $0.float = .left }), (".h", { $0.isHidden = true })]
        let bodies = ["<p>a <span class='u'>straße ß</span> b</p>", "<p class='c'>one <b>two</b> three</p>", "<p class='w'>a b  c</p>",
                      "<p><span class='f'>D</span>rop cap</p>", "<p>a <span class='h'>b</span> c</p>",
                      "<p>a <math xmlns='http://www.w3.org/1998/Math/MathML'><mi>x</mi></math> b <svg xmlns='http://www.w3.org/2000/svg'><g/></svg></p>",
                      "<table><caption>cap</caption><tr><td>a</td><td>b</td></tr></table><p>after</p>"]
        for body in bodies {
            for rich in [BuilderRecordingRich(), BuilderRecordingRich(rendersTables: true)] {
                let text = try H.build(body, rich: rich, rules: rules)
                S.assertTextMapContracts(text, sameCharacters: false)
            }
        }
    }

    // MARK: UTF-16 offsets

    func testOffsetsAreUTF16UnitsThroughAstralAndCombiningCharacters() throws {
        let text = try H.build("<p>😀a\u{301}𝒳  e\u{301}\u{302}</p>")
        XCTAssertEqual(text.string.string, "😀a\u{301}𝒳 e\u{301}\u{302}")
        let node = try XCTUnwrap(text.document.nodes.first(where: \.isText))
        XCTAssertEqual(node.utf16Length, 11)
        // Before the run of two spaces rendered and source offsets agree, even inside a surrogate pair.
        for offset in 0...6 {
            XCTAssertEqual(text.map.location(of: DOMPosition(node, offset)), offset, "offset \(offset)")
            XCTAssertEqual(text.map.position(at: offset, in: text.document), DOMPosition(node, offset), "location \(offset)")
        }
        // After it they differ by the one space removed.
        for offset in 8...11 { XCTAssertEqual(text.map.location(of: DOMPosition(node, offset)), offset - 1, "offset \(offset)") }
        XCTAssertEqual(text.map.position(at: 9, in: text.document), DOMPosition(node, 10))
        XCTAssertEqual(text.map.endPosition(at: 10, in: text.document), DOMPosition(node, 11))
    }

    // MARK: Positions without a rendered character

    func testPositionsInTextThatIsNotRenderedAreTheNextRenderedCharacter() throws {
        let text = try H.build("""
            <p>a<span hidden="">hid</span><script>scr</script>b</p> \n <aside epub:type="footnote" id="n">note</aside>\
            <p><ruby>c<rt>rt</rt></ruby>d</p><p>   </p><p>e</p>
            """)
        XCTAssertEqual(text.string.string, "ab\ncd\ne")
        func locations(_ content: String) throws -> (start: Int, end: Int) {
            let node = try XCTUnwrap(S.textNode(content, in: text), content)
            return (text.map.location(of: DOMPosition(node, 1)), text.map.location(of: DOMPosition(node, 1), isEnd: true))
        }
        // As a range's start: the next rendered character. As its end: the end of the last one before.
        XCTAssertEqual(try locations("hid").start, 1); XCTAssertEqual(try locations("hid").end, 1)
        XCTAssertEqual(try locations("scr").start, 1); XCTAssertEqual(try locations("scr").end, 1)
        XCTAssertEqual(try locations("note").start, 3); XCTAssertEqual(try locations("note").end, 2)
        XCTAssertEqual(try locations("rt").start, 4); XCTAssertEqual(try locations("rt").end, 4)
        XCTAssertEqual(try locations("   ").start, 6); XCTAssertEqual(try locations("   ").end, 5)
        // Element positions: an element's start is its first rendered character.
        XCTAssertEqual(text.map.location(of: DOMPosition(text.document.root, 0)), 0)
        XCTAssertEqual(text.map.location(of: DOMPosition(try XCTUnwrap(text.document.element(id: "n")), 0)), 3)
    }

    func testARangesEndStaysInTheNodeItCovers() throws {
        let text = try H.build("<p>one</p><p>two <img src='picture.png' alt='I'/></p><p>three</p>")
        XCTAssertEqual(text.string.string, "one\ntwo [I]\nthree")
        let one = try XCTUnwrap(S.textNode("one", in: text)), three = try XCTUnwrap(S.textNode("three", in: text))
        // Ending before or on the paragraph break: the first paragraph's end, not the second's start.
        XCTAssertEqual(text.map.endPosition(at: 3, in: text.document), DOMPosition(one, 3))
        XCTAssertEqual(text.map.endPosition(at: 4, in: text.document), DOMPosition(one, 3))
        XCTAssertEqual(text.map.position(at: 3, in: text.document)?.node.text, "two ")
        // Ending after an image: after its element, so the range includes it.
        let end = try XCTUnwrap(text.map.endPosition(at: 11, in: text.document))
        XCTAssertTrue(end.node === three.parent || end.node === three, "ends at \(end.node.name)\(end.node.text)")
        XCTAssertEqual(text.map.location(of: end, isEnd: true), 11)
        // The text's end is the end of the last node.
        XCTAssertEqual(text.map.endPosition(at: text.string.length, in: text.document), DOMPosition(three, 5))
        XCTAssertEqual(text.map.endPosition(at: 999, in: text.document), DOMPosition(three, 5))
        XCTAssertEqual(text.map.position(at: -5, in: text.document), DOMPosition(one, 0))
    }

    func testARangeEndingWithTheDocumentsLastImageIncludesIt() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/129")
        // Markup with nothing after its last image, not even white space (a minified cover or figure page).
        // "A range ending with an image, table or formula includes it" (`TextMap.endPosition`).
        let text = try H.build("<p>See <img src='picture.png' alt='I'/></p>")
        XCTAssertEqual(text.string.string, "See [I]")
        XCTAssertTrue(text.document.nodes.last?.isHTML("img") == true)
        let end = try XCTUnwrap(text.map.endPosition(at: 7, in: text.document))
        XCTAssertEqual(text.map.location(of: end, isEnd: true), 7, "the range's end came back before the image")
    }

    func testARangeOfOnlyGeneratedTextIsNeverAnInvertedDOMRange() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/129")
        // A selection can hold nothing but a list marker, a quotation mark or a paragraph break. Its DOM range
        // (`position(at:)` to `endPosition(at:)`, as the session makes a CFI) must still run forwards.
        let text = try H.build("<p>A</p><ol><li>B</li></ol><p>He said <q>hi</q>.</p>")
        XCTAssertEqual(text.string.string, "A\n1.\tB\nHe said “hi”.")
        for range in [2..<4, 2..<3, 1..<2, 1..<5, 15..<16] {
            let start = try XCTUnwrap(text.map.position(at: range.lowerBound, in: text.document))
            let end = try XCTUnwrap(text.map.endPosition(at: range.upperBound, in: text.document))
            let selected = (text.string.string as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
            XCTAssertFalse(end < start, "\"\(S.escape(selected))\" at \(range) runs from node \(start.node.order):\(start.offset) "
                + "back to node \(end.node.order):\(end.offset)")
        }
    }

    // MARK: Passage text

    func testPassageTextIsTheBooksOwnCharactersWithBreaksBetweenBlocks() throws {
        let text = try H.build("""
            <h1>Title</h1><ol><li>one <q>quoted</q></li><li>two<br/>lines</li></ol>\
            <p>An <img src="picture.png" alt="image"/> and a <bdi>name</bdi>, long<wbr/>word.</p><hr/><p>end</p>
            """)
        XCTAssertEqual(text.string.string,
                       "Title\n1.\tone “quoted”\n2.\ttwo\u{2028}lines\nAn [image] and a \u{2068}name\u{2069}, long\u{200B}word.\n—\nend")
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "Title\none quoted\ntwo\nlines\nAn [image] and a name, longword.\n—\nend")
        // Part of a span, and bounds outside the text.
        XCTAssertEqual(text.mappedText(in: 2..<12), "tle\none")
        XCTAssertEqual(text.mappedText(in: -10..<3), "Tit")
        XCTAssertEqual(text.mappedText(in: (text.string.length - 3)..<(text.string.length + 50)), "end")
        XCTAssertEqual(text.mappedText(in: 4..<4), "")
        // Only generated text: nothing of the book's.
        XCTAssertEqual(text.mappedText(in: 6..<9), "")
    }

    func testPreformattedLineBreaksComeBackAsLineFeedsInThePassageText() throws {
        // Copy and `EPUBSelection.text` are the passage text, "the book's own characters". A listing's line
        // breaks are U+000A in the book (and in any browser's copy), not the U+2028 the reader lays them out with.
        let text = try H.build("<pre>let a = 1\n  b()\n</pre>")
        XCTAssertEqual(text.string.string, "let a = 1\u{2028}  b()")
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length).trimmingCharacters(in: .newlines), "let a = 1\n  b()")
    }

    func testAFloatedDropCapStaysInItsWordInThePassageText() throws {
        // The passage text is what a selection reports and what a host later asks the reader to locate.
        // WebKit, like foliate before, puts no break around a float: the word is "Drop".
        let text = try S.styled("<p><span class='cap'>D</span>rop caps open the chapter.</p><p>Next paragraph.</p>",
                                css: ".cap { float: left; font-size: 3em; line-height: 1 }")
        XCTAssertTrue(text.string.string.hasPrefix("D\nrop"), "the float retains its layout paragraph")
        let passage = text.mappedText(in: 0..<(H.location(of: "Next", in: text) - 1))
        XCTAssertEqual(passage, "Drop caps open the chapter.")
        XCTAssertEqual(TextSearch.matches(of: TextSearch.normalizeQuote(passage), in: text.document, locale: "en").count, 1,
                       "the reader cannot find the passage it reported")
    }

    func testThePassageTextOfAnyWholeParagraphCanBeLocatedAgain() throws {
        let text = try S.styled("""
            <p>Plain words in a paragraph.</p><p>With <em>inline</em> markup and a <a href="two.xhtml">link</a>.</p>\
            <p>Collapsed   spaces\n and\ttabs.</p><p>A <span class="up">shouted</span> word.</p>
            """, css: ".up { text-transform: uppercase }")
        let string = text.string.string as NSString
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let passage = text.mappedText(in: paragraph.location..<NSMaxRange(paragraph))
            let quote = TextSearch.normalizeQuote(passage)
            XCTAssertEqual(TextSearch.matches(of: quote, in: text.document, locale: "en").count, 1, quote)
            location = NSMaxRange(paragraph)
        }
    }

    // MARK: Empty and withheld sections

    func testAnEmptySectionHasAnEmptyMapThatAnswersEveryQuestion() throws {
        for body in ["", " \n ", "<div hidden=''>x</div>", "<p></p><br/>", "<aside epub:type='footnote' id='n'>note</aside>"] {
            let text = try H.build(body)
            XCTAssertEqual(text.string.length, 0, body)
            XCTAssertEqual(text.map.length, 0, body)
            XCTAssertTrue(text.map.spans.isEmpty, body)
            XCTAssertNil(text.map.position(at: 0, in: text.document), body)
            XCTAssertNil(text.map.endPosition(at: 5, in: text.document), body)
            for node in text.document.nodes {
                XCTAssertEqual(text.map.location(of: DOMPosition(node, 0)), 0, body)
                XCTAssertEqual(text.map.location(of: DOMPosition(node, 0), isEnd: true), 0, body)
            }
            XCTAssertEqual(text.mappedText(in: 0..<10), "", body)
            XCTAssertFalse(text.report.withheld)
        }
    }

    func testASectionOfOnlyGeneratedTextMapsNothing() throws {
        let text = try H.build("<ol><li></li><li> </li></ol>")
        XCTAssertEqual(text.string.string, "1.\t\n2.\t")
        XCTAssertTrue(text.map.spans.isEmpty)
        XCTAssertEqual(text.map.length, 7)
        XCTAssertNil(text.map.position(at: 3, in: text.document))
        XCTAssertEqual(text.mappedText(in: 0..<7), "\n")
        XCTAssertEqual(text.map.location(of: DOMPosition(text.document.root, 0)), 7)
    }

    func testInlineFlowBoxParagraphsKeepAuthoredSpacesButRealBlocksKeepBreaks() throws {
        for css in [".box { float: left }", ".box { position: absolute; top: 1px }",
                    ".box { display: inline-block; width: 40px }"] {
            for (body, expected) in [("<p>Before<span class='box'>callout</span>after.</p>", "Beforecalloutafter."),
                                     ("<p>Before <span class='box'>callout</span> after.</p>", "Before callout after."),
                                     ("<p><span class='box'>First</span> word.</p><p>Next.</p>", "First word.\nNext.")] {
                let text = try S.styled(body, css: css)
                XCTAssertTrue(text.string.string.contains("\n"), "flow boxes keep their layout paragraphs")
                XCTAssertEqual(text.mappedText(in: 0..<text.string.length), expected, css + body)
                let quote = TextSearch.normalizeQuote(expected.components(separatedBy: "\n")[0])
                XCTAssertEqual(TextSearch.matches(of: quote, in: text.document, locale: "en").count, 1, css + body)
                S.assertTextMapContracts(text)
            }
            let block = try S.styled("<p>Before</p><div class='box'>block</div><p>After</p>", css: css)
            XCTAssertEqual(block.mappedText(in: 0..<block.string.length), "Before\nblock\nAfter", css)
        }
    }

    func testLayoutOnlySeparatorsAndAuthoredPreBreaksHavePrecisePartialCopyText() throws {
        let text = try S.styled("<p>A<span class='box'>B</span>C</p><pre>one\n  two</pre><p>End</p>",
                                css: ".box { display: inline-block; width: 20px }")
        let b = H.location(of: "B", in: text)
        XCTAssertEqual(text.mappedText(in: (b - 1)..<b), "")
        XCTAssertEqual(text.mappedText(in: b..<(b + 1)), "B")
        XCTAssertEqual(text.mappedText(in: (b + 1)..<(b + 2)), "")
        XCTAssertEqual(text.mappedText(in: 0..<(H.location(of: "one", in: text) - 1)), "ABC")
        let separator = H.location(of: "one", in: text) - 1
        XCTAssertEqual(text.mappedText(in: separator..<(separator + 1)), "\n")
        let line = H.location(of: "one", in: text) + 3
        XCTAssertEqual(text.mappedText(in: line..<(line + 1)), "\n")
        XCTAssertEqual(text.mappedText(in: (line - 1)..<(line + 3)), "e\n  ")
        XCTAssertEqual(text.mappedText(in: (text.string.length + 5)..<(text.string.length + 9)), "")
        let start = try XCTUnwrap(text.map.position(at: 0, in: text.document))
        let end = try XCTUnwrap(text.map.endPosition(at: H.location(of: "C", in: text) + 1, in: text.document))
        let cfi = EPUBCFI.localPath(from: start, to: end, in: text.document)
        let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: cfi, in: text.document))
        XCTAssertEqual(resolved.start, start); XCTAssertEqual(resolved.end, end)
        XCTAssertEqual(text.mappedText(in: text.map.location(of: resolved.start)..<text.map.location(of: resolved.end, isEnd: true)), "ABC")
    }

    func testDetachedTableCopyUsesAuthoredCaseAndLineBreaks() throws {
        let text = try S.styled("<table><tr><td><pre>code\n  next</pre></td><td style='text-transform: uppercase'>straße</td></tr></table>")
        let row = try XCTUnwrap(text.tables().first)
        let cell = row.row.table.cells[1]
        XCTAssertEqual(cell.content.string, "STRASSE")
        XCTAssertEqual(text.mappedText(in: row.offset..<(row.offset + 1)), "code\n  next\tstraße")
        let start = ReaderTextPosition(section: 0, offset: row.offset,
            tableCell: ReaderTablePosition(table: row.row.table.sourceOrder, cell: 1, offset: 4))
        let end = ReaderTextPosition(section: 0, offset: row.offset,
            tableCell: ReaderTablePosition(table: row.row.table.sourceOrder, cell: 1, offset: 6))
        XCTAssertEqual(text.tablePassage(ReaderTextRange(start: start, end: end)), "ß")
        let position = try XCTUnwrap(text.domPosition(start))
        let endPosition = try XCTUnwrap(text.domPosition(end, isEnd: true))
        XCTAssertEqual([position.offset, endPosition.offset], [4, 5])
    }
}
