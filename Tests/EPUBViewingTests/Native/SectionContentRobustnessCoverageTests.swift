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

    func testNotesHoldingOnlyOtherNotesWalkTheirContentAFixedNumberOfTimes() throws {
        // A note with nothing of its own is rendered a second time with the notes nested in it, `wholeNoteDepth`
        // levels of them. 190 notes, each holding only the next, around 1,000 elements. The styles computed for those
        // elements count the times they are walked, the same on any machine, and the count grows neither with the
        // nesting nor with what else the document holds (cheap elements in front, which a bound that is a share of
        // the document would count).
        let open = (0..<190).map { "<aside epub:type='footnote' id='n\($0)'>" }.joined(), close = String(repeating: "</aside>", count: 190)
        let depth = SectionBuildState.wholeNoteDepth
        // Content that shows is walked for its own note and for each of the `depth` notes around it. Content that
        // shows nothing, beside an empty note, leaves its own note with nothing too, which walks it once more.
        let contents: [(inner: String, walks: Int, shown: Int)] = [
            (String(repeating: "<p class='w'>w</p>", count: 1_000), 1 + depth, depth + 1),
            (String(repeating: "<p class='w' hidden=''>h</p>", count: 1_000) + "<aside epub:type='footnote' id='e'/>", 2 + depth, 0),
        ]
        for (inner, walks, shown) in contents {
            for padding in [0, 10_000] {
                var styled = 0
                let document = try H.document("<p>Text" + String(repeating: "<i/>", count: padding) + "</p>" + open + inner + close)
                let text = H.build(document: document, rules: [(".w", { _ in styled += 1 })])
                XCTAssertEqual(styled, walks * 1_000, "\(padding) elements in front")
                XCTAssertEqual(text.string.string, "Text")
                XCTAssertEqual(Set(text.notes.keys).subtracting(["e"]), Set((0..<190).map { "n\($0)" }))
                // The innermost notes show the content; the ones further out stay empty.
                XCTAssertEqual((0..<190).filter { text.notes["n\($0)"]?.length != 0 }, Array((190 - shown)..<190), "\(padding) elements in front")
            }
        }
    }

    func testNotesHoldingOnlyOtherNotesTakeNothingFromTheNotesThemselves() throws {
        // What a note with nothing of its own repeats of the notes nested in it comes from a budget of its own. 190
        // such notes are captured before the note of 300,000 units they hold, which is still whole, and all are keys.
        let open = (0..<190).map { "<aside epub:type='footnote' id='n\($0)'>" }.joined(), close = String(repeating: "</aside>", count: 190)
        let chain = H.build(document: try H.document(open + "<p>" + String(repeating: "word ", count: 60_000) + "</p>" + close))
        XCTAssertEqual(chain.notes.count, 190)
        XCTAssertEqual((0..<190).filter { chain.notes["n\($0)"]?.length == 299_999 }, Array((189 - SectionBuildState.wholeNoteDepth)..<190))
        // Sixteen notes marked by two elements each, 200,000 units a note: more than one budget would hold of the
        // notes and of what their outer elements repeat of them together.
        let words = String(repeating: "word ", count: 40_000)
        let pairs = H.build(document: try H.document((0..<16).map {
            "<aside epub:type='footnote' id='a\($0)'><div role='doc-footnote' id='b\($0)'><p>\(words)</p></div></aside>"
        }.joined()))
        XCTAssertLessThan(SectionBuildState.maximumNoteLength, 32 * 199_999)
        XCTAssertEqual(pairs.notes.count, 32)
        XCTAssertEqual(pairs.notes.values.map(\.length), Array(repeating: 199_999, count: 32))
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

    /// An unescaped `<` in prose with an apostrophe after it once withheld the whole section.
    /// It is not well-formed, so the HTML parser reads it and the section says so.
    func testAStrayLessThanSignBeforeAnApostropheIsShownAndReported() throws {
        let data = try Fixture.epub(overrides: ["OPS/one.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>if x < y then it's done</p><p>next</p></body></html>"])
        let book = try EPUBPublication.open(data: data)
        let text = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 0, typography: NativeTypography(),
                                                            fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
        XCTAssertFalse(text.report.withheld)
        XCTAssertTrue(text.report.recoveredAsHTML)
        XCTAssertTrue(text.string.string.hasPrefix("if x"), text.string.string.debugDescription)
        XCTAssertTrue(text.string.string.hasSuffix("next"), text.string.string.debugDescription)
        XCTAssertEqual(text.map.length, text.string.length)
    }

    /// The rest of a sentence after an unescaped `<` is shown, and the reader's positions are
    /// those of what it shows: every character maps to its place in the document and back, a
    /// search finds the words after the sign where they are drawn, and an `id` after it is an
    /// anchor. The style sheet's own sign is still the style sheet's. It remains a section
    /// whose tree the HTML parser repaired, so it reports that it has no CFIs to give.
    func testTextAfterAStrayLessThanSignIsShownWhereItsPositionsSayItIs() throws {
        let data = try Fixture.epub(overrides: ["OPS/one.xhtml": """
        <html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title><style>p > em { font-style: normal } /* a < b */</style></head>\
        <body><p>if x < y then <em>done</em></p><p id='after'>p <.05 and 1 << 2</p></body></html>
        """])
        let book = try EPUBPublication.open(data: data)
        let text = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 0, typography: NativeTypography(),
                                                            fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
        XCTAssertFalse(text.report.withheld)
        XCTAssertTrue(text.report.recoveredAsHTML)
        XCTAssertTrue(text.report.cfiUnavailable)
        XCTAssertEqual(text.string.string, "if x < y then done\np <.05 and 1 << 2")
        XCTAssertEqual(S.mapViolations(text) + S.locationViolations(text) + S.stringViolations(text), [])
        XCTAssertEqual(text.document.nodes.first { $0.isHTML("style") }?.textContent, "p > em { font-style: normal } /* a < b */")
        XCTAssertFalse(S.traits("done", in: text).contains(.traitItalic), "the style sheet was read whole")

        let string = text.string.string as NSString
        let anchor = try XCTUnwrap(text.anchors["after"])
        XCTAssertEqual(string.substring(from: anchor), "p <.05 and 1 << 2")
        for query in ["y then done", "x < y", "1 << 2"] {
            let match = try XCTUnwrap(TextSearch.matches(of: query, in: text.document, locale: nil).first, query)
            let start = text.map.location(of: match.start), end = text.map.location(of: match.end, isEnd: true)
            XCTAssertEqual(string.substring(with: NSRange(location: start, length: end - start)), query)
            XCTAssertEqual(EPUBCFI.localPath(from: match.start, to: match.end, in: text.document), "", query)
        }
    }

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

    func testNamespaceInvalidColonNamesKeepReadableHTMLTextAndMapInvariants() throws {
        // XML 1.0's Name admits colons, but these names are not namespace-valid QNames.
        // #102 therefore reads them as HTML and refuses CFIs. HTML keeps a `<:` start as
        // literal text, while libxml2's recovery can leave `:` as the local name of `a::`.
        let css = #"* { color: red } \: { font-style: italic } p > :first-child { font-weight: bold } [\:] { color: green }"#
        let prose: [(body: String, text: String, colonNodes: Int)] = [
            ("<p>a<: id='q' class='k' style='color: blue' :='v'>b</:>c<:/>d<::>e</::></p>",
             "a<: id='q' class='k' style='color: blue' :='v'>bc<:/>d<::>e", 0),
            ("<p>a</p><:>b</:><p>c</p>", "a\n<:>b\nc", 0),
            ("<p>a</b><a:: id='q'>b</a::>c<a:::>d</a:::></p>", "abcd", 1),
        ]
        for (body, expected, colonNodes) in prose {
            let text = try S.styled(body, head: "<link rel='stylesheet' href='colon.css'/>", files: ["colon.css": Data(css.utf8)])
            XCTAssertEqual(text.string.string, expected, body)
            XCTAssertTrue(text.document.recoveredAsHTML, body)
            XCTAssertTrue(text.report.recoveredAsHTML, body)
            XCTAssertFalse(text.document.canResolveCFIs, body)
            XCTAssertTrue(text.report.cfiUnavailable, body)
            XCTAssertFalse(text.report.withheld, body)
            XCTAssertEqual(text.document.nodes.filter { $0.isElement && $0.name == ":" }.count, colonNodes, body)
            // An external sheet remains a stylesheet after HTML recovery. The escaped
            // type selector styles only the real `:` element left from `a::`, never the
            // literal `<:` markup in the other cases.
            XCTAssertEqual(S.traits("b", in: text).contains(.traitItalic), colonNodes > 0, body)
            XCTAssertFalse(S.traits("a", in: text).contains(.traitItalic), body)
            XCTAssertEqual(S.mapViolations(text) + S.rangeViolations(text) + S.locationViolations(text) + S.stringViolations(text), [], body)
            let match = try XCTUnwrap(TextSearch.matches(of: "b", in: text.document, locale: nil).first, body)
            XCTAssertEqual(EPUBCFI.localPath(from: match.start, to: match.end, in: text.document), "", body)
            XCTAssertNil(EPUBCFI.resolve(localPath: "/4/2/1:0", in: text.document), body)
        }
        // Tables, formulas and drawings receive the same literal signs in their DOM; their
        // rendered text and attachments must retain the map, range and location contracts.
        let rich: [(body: String, documentText: String, colonNodes: Int)] = [
            ("<table><:><tr><td>a</td></tr></:><tr><:>b</:></tr></table><ul><:>a</:><li>b</li></ul>", "<:>a<:>b<:>ab", 0),
            ("<p>a<math xmlns='http://www.w3.org/1998/Math/MathML'><mrow><:/><: id='m'><mi>x</mi></:></mrow></math>b</p>", "a<:/><: id='m'>xb", 0),
            ("<p>a<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><: id='s'><rect width='5' height='5'/></:><text>t</text></svg>b</p>", "a<: id='s'>tb", 0),
            ("<p>a</b><math><a::>x</a::></math>c</p>", "axc", 1),
        ]
        for (body, documentText, colonNodes) in rich {
            let text = try S.styled(body, head: "<link rel='stylesheet' href='colon.css'/>", files: ["colon.css": Data(css.utf8)])
            XCTAssertEqual(text.document.body?.textContent, documentText, body)
            XCTAssertTrue(text.document.recoveredAsHTML, body)
            XCTAssertTrue(text.report.recoveredAsHTML, body)
            XCTAssertFalse(text.document.canResolveCFIs, body)
            XCTAssertTrue(text.report.cfiUnavailable, body)
            XCTAssertFalse(text.report.withheld, body)
            XCTAssertEqual(text.document.nodes.filter { $0.isElement && $0.name == ":" }.count, colonNodes, body)
            XCTAssertEqual(S.mapViolations(text) + S.rangeViolations(text) + S.locationViolations(text) + S.stringViolations(text), [], body)
            XCTAssertNil(EPUBCFI.resolve(localPath: "/4/2/1:0", in: text.document), body)
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
