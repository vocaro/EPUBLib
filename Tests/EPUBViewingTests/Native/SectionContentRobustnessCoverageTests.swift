import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// Books are untrusted: adversarial sizes and nesting must build in time proportional to their
/// size, without trapping, and anything withheld must be reported.
///
/// The time bounds are loose (other work shares the machine); what they catch is quadratic growth,
/// which at these sizes takes minutes.
final class SectionContentRobustnessCoverageTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    private static let bound: TimeInterval = 30

    private func timed(_ body: String, rules: [H.Rule] = [], rich: any RichContentFactory = PlaceholderRichContent(),
                       file: StaticString = #filePath, line: UInt = #line) throws -> SectionText {
        let document = try H.document(body)
        let start = Date()
        let text = H.build(document: document, rich: rich, rules: rules)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, Self.bound, "built in \(elapsed) s", file: file, line: line)
        XCTAssertFalse(text.report.withheld, file: file, line: line)
        XCTAssertEqual(text.map.length, text.string.length, file: file, line: line)
        return text
    }

    // MARK: Nesting

    func testInlineNestingToTheParsersLimitBuildsWithEveryCharacter() throws {
        // The parser admits 200 levels: html, body, p, then 190 inline elements and the text.
        let tags = ["span", "em", "b", "a", "q", "sup", "bdo", "code", "u", "ruby"]
        var open = "", close = ""
        for depth in 0..<190 {
            let tag = tags[depth % tags.count]
            open += "<\(tag) id='i\(depth)'\(tag == "a" ? " href='#i0'" : "")>w\(depth) "
            close = " c\(depth)</\(tag)>" + close
        }
        let text = try timed("<p>\(open)core\(close)</p>")
        let string = text.string.string
        for depth in [0, 1, 95, 189] {
            XCTAssertTrue(string.contains("w\(depth) "), "w\(depth)")
            XCTAssertTrue(string.contains(" c\(depth)"), "c\(depth)")
        }
        XCTAssertTrue(string.contains("core"))
        XCTAssertEqual(text.anchors.count, 190)
        XCTAssertEqual(S.mapViolations(text) + S.locationViolations(text) + S.stringViolations(text), [])
    }

    func testBlockNestingToTheParsersLimitBuildsWithBoundedIndents() throws {
        let tags = ["div", "blockquote", "section", "ul", "li", "ol", "li", "dl", "dd", "figure", "details", "article"]
        var open = "", close = ""
        for depth in 0..<190 {
            let tag = tags[depth % tags.count]
            open += "<\(tag)>"
            close = "</\(tag)>" + close
        }
        let text = try timed(open + "<p id='core'>core text</p>" + close + "<p>after</p>")
        XCTAssertTrue(text.string.string.contains("core text"))
        XCTAssertTrue(text.string.string.hasSuffix("after"))
        let style = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: "core text", in: text)))
        XCTAssertLessThanOrEqual(style.headIndent - style.tailIndent, 200.01, "nesting cannot squeeze the column away")
        XCTAssertGreaterThanOrEqual(style.firstLineHeadIndent, 0)
        XCTAssertEqual(S.mapViolations(text) + S.stringViolations(text), [])
    }

    func testNestingPastTheParsersLimitIsWithheldAndReported() throws {
        let body = String(repeating: "<div>", count: 400) + "deep" + String(repeating: "</div>", count: 400)
        let data = try Fixture.epub(overrides: ["OPS/one.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body>\(body)</body></html>"])
        let book = try EPUBPublication.open(data: data)
        let text = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 0, typography: NativeTypography(),
                                                            fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
        XCTAssertTrue(text.report.withheld)
        XCTAssertEqual(text.string.string, "This section could not be shown.")
        XCTAssertEqual(text.map.length, text.string.length)
        XCTAssertTrue(text.map.spans.isEmpty)
        XCTAssertNil(text.map.position(at: 3, in: text.document))
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "")
        XCTAssertTrue(text.anchors.isEmpty)
    }

    func testMoreNodesThanTheParserAdmitsIsWithheldAndReported() throws {
        let body = String(repeating: "<i/>", count: 260_000)
        let data = try Fixture.epub(overrides: ["OPS/one.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>\(body)</p></body></html>"])
        let book = try EPUBPublication.open(data: data)
        let start = Date()
        let text = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 0, typography: NativeTypography(),
                                                            fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound)
        XCTAssertTrue(text.report.withheld)
        XCTAssertEqual(text.string.string, "This section could not be shown.")
    }

    // MARK: Breadth

    func testTenThousandInlineSiblingsWithIds() throws {
        let body = (0..<10_000).map { "<span id='s\($0)'>w\($0)</span> " }.joined()
        let text = try timed("<p>\(body)</p>")
        XCTAssertEqual(text.anchors.count, 10_000)
        XCTAssertTrue(text.string.string.hasPrefix("w0 w1 w2 "))
        XCTAssertTrue(text.string.string.hasSuffix(" w9999"))
        XCTAssertEqual(text.anchors["s9999"], text.string.length - 5)
        XCTAssertEqual(S.mapViolations(text), [])
    }

    func testTenThousandBlockSiblingsOfEveryKind() throws {
        let kinds = ["<p>p\u{2060}</p>", "<h3>h</h3>", "<ul><li>l</li></ul>", "<blockquote>q</blockquote>", "<pre> c\n</pre>", "<hr/>", "<div><br/></div>",
                     "<dl><dt>t</dt><dd>d</dd></dl>", "<aside epub:type='footnote'>n</aside>", "<p hidden=''>x</p>"]
        let text = try timed((0..<10_000).map { kinds[$0 % kinds.count] }.joined())
        XCTAssertEqual(S.paragraphs(text).count, 9_000)
        XCTAssertEqual(S.stringViolations(text), [])
    }

    func testThousandsOfEmptyAnchorsBeforeAnyTextAndBetweenWords() throws {
        let anchors = (0..<20_000).map { "<a id='a\($0)'/>" }.joined()
        let between = (0..<5_000).map { "w\($0) <span id='b\($0)'/>" }.joined()
        let text = try timed("<div>\(anchors)</div><p>first \(between)last</p>")
        XCTAssertEqual(text.anchors.count, 25_000)
        XCTAssertEqual(text.anchors["a0"], 0)
        XCTAssertEqual(text.anchors["a19999"], 0)
        XCTAssertEqual(text.anchors["b4999"], H.location(of: "last", in: text))
    }

    func testThousandsOfLineBreaksAndSpacesInOneParagraph() throws {
        let text = try timed("<p>start" + String(repeating: "<br/>", count: 20_000) + "end" + String(repeating: " <b> </b>\n", count: 20_000) + "</p>")
        XCTAssertEqual(text.string.length, 5 + 20_000 + 3)
        XCTAssertTrue(text.string.string.hasSuffix("\u{2028}end"))
    }

    func testThousandsOfNotesAndReferences() throws {
        let references = (0..<3_000).map { "<p>Claim \($0)<a epub:type='noteref' href='#n\($0)'>\($0)</a>.</p>" }.joined()
        let notes = (0..<3_000).map { "<aside epub:type='footnote' id='n\($0)'><p>Note \($0) text.</p></aside>" }.joined()
        let text = try timed(references + notes)
        XCTAssertEqual(text.notes.count, 3_000)
        XCTAssertEqual(text.notes["n2999"]?.string, "Note 2999 text.")
        XCTAssertFalse(text.string.string.contains("Note 0 text."))
        XCTAssertEqual(S.paragraphs(text).count, 3_000)
    }

    func testThousandsOfListItemsAndNestedQuotes() throws {
        let items = (0..<5_000).map { "<li value='\($0 * 7)'><q>item <q>\($0)</q></q></li>" }.joined()
        let text = try timed("<ol>\(items)</ol>")
        let paragraphs = S.paragraphs(text)
        XCTAssertEqual(paragraphs.count, 5_000)
        XCTAssertEqual(paragraphs[4_999], "34993.\t“item ‘4999’”")
    }

    // MARK: Long text

    func testAMegabyteTextNodeIsOneParagraphWithFewSpans() throws {
        let words = (0..<200_000).map { "w\($0 % 977)" }.joined(separator: " ")
        XCTAssertGreaterThan(words.utf8.count, 800_000)
        let text = try timed("<p>\(words)</p>")
        XCTAssertEqual(text.string.string, words)
        XCTAssertEqual(text.map.spans.count, 1)
        let node = try XCTUnwrap(text.document.nodes.first(where: \.isText))
        XCTAssertEqual(text.map.location(of: DOMPosition(node, 700_000)), 700_000)
        XCTAssertEqual(text.map.position(at: 123_456, in: text.document), DOMPosition(node, 123_456))
    }

    func testAMegabyteOfCollapsibleWhitespaceAndTransformedText() throws {
        let rules: [H.Rule] = [(".u", { $0.textTransform = .uppercase }), (".c", { $0.textTransform = .capitalize }),
                               (".p", { $0.whiteSpace = .preWrap }), (".s", { $0.isSmallCaps = true; $0.wordSpacing = 2 })]
        let spaces = String(repeating: " \n\t", count: 300_000)
        let blank = try timed("<p>a\(spaces)b</p><p>\(spaces)</p><pre>\(spaces)</pre>")
        XCTAssertTrue(blank.string.string.hasPrefix("a b\n"))
        let words = (0..<60_000).map { "straße\($0 % 13)" }.joined(separator: " ")
        let transformed = try timed("<p class='u'>\(words)</p><p class='c'>\(words)</p><p class='p'>\(words)</p><p class='s'>\(words)</p>", rules: rules)
        let paragraphs = S.paragraphs(transformed)
        XCTAssertEqual(paragraphs.count, 4)
        XCTAssertTrue(paragraphs[0].hasPrefix("STRASSE0 STRASSE1 "))
        XCTAssertTrue(paragraphs[1].hasPrefix("Straße0 Straße1 "))
        XCTAssertEqual(paragraphs[2], words)
        XCTAssertEqual(S.mapViolations(transformed, sameCharacters: false), [])
    }

    func testALongRunOfAstralCharactersAndCombiningMarks() throws {
        let text = try timed("<p>" + String(repeating: "😀e\u{301}\u{302}\u{303}𝒳 ", count: 50_000) + "</p><p class='u'>"
                             + String(repeating: "\u{301}", count: 100_000) + "</p>", rules: [(".u", { $0.textTransform = .uppercase })])
        XCTAssertEqual(S.paragraphs(text).count, 2)
        XCTAssertEqual(S.mapViolations(text, sameCharacters: false), [])
    }

    // MARK: Hostile markup

    func testHostileRubyListAndTableMarkupDoesNotTrap() throws {
        let bodies = [
            "<rt>stray</rt><rp>x</rp><ruby><ruby><rt>a</rt></ruby><rt>b</rt></ruby><ruby/>",
            "<li><li><li>x</li></li></li><ol start='-0'><li value=''>a</li><li value=' '>b</li><li value='١'>c</li></ol>",
            "<tr><td>orphan cell</td></tr><td>cell</td><table><td>bare</td></table><table><tr/></table><table/>",
            "<br/><br/><wbr/><hr/><br/>", "<q><q><q></q></q></q>", "<a href='#'><a href='#'><a>nested</a></a></a>",
            "<pre>\n</pre><pre>\n\n</pre><pre></pre><p><br/></p>",
            "<epub:switch/><epub:switch><epub:default/></epub:switch><epub:case>stray</epub:case><epub:default>stray</epub:default>",
            "<aside epub:type='footnote' id='x'><aside epub:type='footnote' id='x'><a epub:type='noteref' href='#x'>x</a></aside></aside>",
            "<object><object><object>deep fallback</object></object></object><video><audio><canvas>c</canvas></audio></video>",
            "<summary>stray</summary><figcaption>stray</figcaption><dd>stray</dd><caption>stray</caption><option>stray</option>",
        ]
        for body in bodies {
            for rich in [BuilderRecordingRich(), BuilderRecordingRich(rendersTables: true)] {
                let text = try H.build(body, rich: rich)
                XCTAssertEqual(S.mapViolations(text) + S.rangeViolations(text) + S.locationViolations(text) + S.stringViolations(text), [], body)
            }
        }
    }

    func testTablesNestedPastTheRenderingLimitKeepTheirText() throws {
        // Each cell's content is rendered by a nested writer, at most eight deep; deeper cells become plain text.
        let depth = 14
        var body = "core <b>text</b>"
        for level in (0..<depth).reversed() { body = "<table><tr><td>cell\(level);</td><td>\(body)</td></tr></table>" }
        let text = try timed(body + "<p>after</p>", rich: SectionContentCellRich())
        let string = text.string.string
        // Past the limit a cell is its plain text, so every cell is still there once.
        for level in 0..<depth { XCTAssertEqual(string.components(separatedBy: "cell\(level);").count, 2, "cell\(level)") }
        XCTAssertEqual(string.components(separatedBy: "core text").count, 2)
        XCTAssertTrue(string.hasSuffix("\nafter"))
        XCTAssertEqual(S.mapViolations(text) + S.stringViolations(text), [])
    }

    func testNotesPastTheirBudgetAreCutAtACharacterBoundaryAndNotTrapped() throws {
        // All of a section's notes share 4 MiB of UTF-16; the cut must not split a surrogate pair.
        let long = String(repeating: "a", count: SectionBuildState.maximumNoteLength - 1) + "😀😀 tail"
        let text = try timed("<p>Text<a epub:type='noteref' href='#big'>1</a><a epub:type='noteref' href='#next'>2</a></p>"
                             + "<aside epub:type='footnote' id='big'>\(long)</aside><aside epub:type='footnote' id='next'>Next note.</aside>")
        let note = try XCTUnwrap(text.notes["big"])
        XCTAssertLessThanOrEqual(note.length, SectionBuildState.maximumNoteLength)
        XCTAssertGreaterThan(note.length, SectionBuildState.maximumNoteLength - 4)
        XCTAssertFalse(UTF16.isLeadSurrogate((note.string as NSString).character(at: note.length - 1)), "the note ends in half a character")
        XCTAssertEqual(text.string.string, "Text12")
    }

    func testARichFactoryThatReturnsOddTextDoesNotBreakTheParagraphs() throws {
        let text = try H.build("<p>a <img src='picture.png' alt=''/> b</p><img class='block' src='picture.png' alt=''/><p>c</p><hr/>",
                               rich: SectionContentOddRich(), rules: [(".block", { $0.display = .block })])
        XCTAssertFalse(text.string.string.hasSuffix("\n"))
        XCTAssertEqual(S.mapViolations(text) + S.locationViolations(text), [])
        XCTAssertTrue(text.string.string.contains("c"))
    }
}

/// Tables as their own rows' cells, each rendered by the builder, in one line.
private struct SectionContentCellRich: RichContentFactory {
    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        let result = NSMutableAttributedString()
        for row in element.elementChildren where row.isHTML("tr") {
            let rowStyle = context.style(row, style)
            for cell in row.elementChildren where cell.isHTML("td") {
                result.append(context.renderContent(cell, context.style(cell, rowStyle)))
                result.append(NSAttributedString(string: " "))
            }
        }
        return result
    }
    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        NSAttributedString(string: "—")
    }
}

/// A factory whose results begin and end with paragraph breaks, hold several paragraphs, or are empty.
private struct SectionContentOddRich: RichContentFactory {
    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        NSAttributedString(string: "\n\nfirst\nsecond\r\nthird\u{2029}\n")
    }
    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { NSAttributedString() }
    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { NSAttributedString(string: "\n") }
    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        NSAttributedString(string: "\n")
    }
}
