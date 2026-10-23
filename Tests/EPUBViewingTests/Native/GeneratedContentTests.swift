import CoreText
import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewingTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// `::before` and `::after` with `content` (CSS 2 §12.1, CSS Generated Content 3 §2), `quotes`
/// and counters (CSS Lists 3 §4), built through the whole pipeline, and what their characters
/// are to the text map, positions, CFIs, search and the passage text (#131).
final class GeneratedContentTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    // MARK: Strings and styles

    func testStringsAreStyledByThePseudoElementsOwnRulesAndInheritFromTheirElement() throws {
        let text = try S.styled("<p class='note'>Take care.</p>", css: """
            .note { font-style: italic }
            .note::before { content: 'Note: '; font-weight: bold }
            .note::after { content: " [end]" }
            """)
        XCTAssertEqual(text.string.string, "Note: Take care. [end]")
        XCTAssertTrue(S.traits("Note", in: text).contains(.traitBold))
        XCTAssertTrue(S.traits("Note", in: text).contains(.traitItalic), "inherited from its element")
        XCTAssertFalse(S.traits("Take", in: text).contains(.traitBold), "the element's own text keeps its own style")
        XCTAssertTrue(S.traits("[end]", in: text).contains(.traitItalic))
        XCTAssertFalse(S.traits("[end]", in: text).contains(.traitBold))
        XCTAssertFalse(text.report.generatedContentOmitted)
        S.assertTextMapContracts(text)
    }

    func testNoneNormalAndDisplayNoneGenerateNothing() throws {
        let text = try S.styled("<p class='a'>A</p><p class='b'>B</p><p class='c'>C</p><p class='d'>D</p><p class='e'>E</p>", css: """
            p::before { content: '> ' }
            .a::before { content: none } .b::before { content: normal } .c::before { display: none } .e::before { content: '' }
            p.d::after { color: red }
            """)
        XCTAssertEqual(S.paragraphs(text), ["A", "B", "C", "> D", "E"], "a rule without `content` generates nothing either")
    }

    func testListMarkersMadeWithBefore() throws {
        let text = try S.styled("<ul class='dash'><li>one</li><li>two</li></ul><ol><li>three</li></ol>", css: """
            ul.dash { list-style: none } ul.dash li::before { content: '– ' }
            """)
        XCTAssertEqual(S.paragraphs(text), ["– one", "– two", "1.\tthree"])
        XCTAssertTrue(S.isGenerated(H.location(of: "–", in: text), in: text))
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "one\ntwo\nthree")
        S.assertTextMapContracts(text)
    }

    func testWhiteSpaceCollapsesAcrossGeneratedText() throws {
        let text = try S.styled("""
            <p class='end'>Take care. </p><p class='pre'>x</p><p class='lead'>  y</p>
            """, css: """
            .end::after { content: '  [end]' } .pre::before { content: 'one\\A two\\A'; white-space: pre } .lead::before { content: '* ' }
            """)
        XCTAssertEqual(S.paragraphs(text), ["Take care. [end]", "one\u{2028}two\u{2028}x", "* y"])
        S.assertTextMapContracts(text)
    }

    func testBlockGeneratedContentIsAParagraphAndEmptyBoxesAddNothing() throws {
        let text = try S.styled("<h1>Title</h1><p class='clear'>Para</p><div class='rule'>After</div>", css: """
            h1::before { content: 'Part One'; display: block; font-size: 0.5em }
            .clear::after { content: ''; display: table; clear: both }
            .rule::after { content: ''; display: block; border-top: 1px solid }
            """)
        XCTAssertEqual(S.paragraphs(text), ["Part One", "Title", "Para", "After"])
        XCTAssertNotNil(text.string.attribute(.readerHeading, at: 0, effectiveRange: nil), "the heading's text begins with what it generates")
        S.assertTextMapContracts(text)
    }

    func testAttributesAndLinks() throws {
        let text = try S.styled("""
            <p><abbr title='HyperText Markup Language'>HTML</abbr> and <abbr>CSS</abbr>.</p><p><a href='#x' data-label='see'>link</a></p>
            """, css: "abbr::after { content: ' (' attr(title) ')' } a::before { content: attr(data-label) ': ' }")
        XCTAssertEqual(S.paragraphs(text), ["HTML (HyperText Markup Language) and CSS ().", "see: link"])
        XCTAssertNotNil(S.link("see", in: text), "a link's generated content is part of the link")
    }

    // MARK: Quotes

    func testQuotesFollowTheQuotesPropertyAndNest() throws {
        let text = try S.styled("""
            <blockquote><p class='q'>a <span class='q'>b <span class='q'>c</span></span></p></blockquote>\
            <p><q>d</q> <q class='plain'>e</q> <span class='n'>f</span></p>
            """, css: """
            blockquote { quotes: '«' '»' '‹' '›' } .q::before { content: open-quote } .q::after { content: close-quote }
            q.plain { quotes: none } .n::before { content: no-open-quote } .n::after { content: close-quote }
            """)
        XCTAssertEqual(S.paragraphs(text), ["«a ‹b ‹c››»", "“d” e f”"], "the last pair stands for deeper levels")
        S.assertTextMapContracts(text)
    }

    func testAResetStylesheetRemovesTheMarksOfQ() throws {
        // Eric Meyer's reset, which many books carry.
        let reset = try S.styled("<p>He said <q>hi</q>.</p>", css: "blockquote, q { quotes: none } q:before, q:after { content: ''; content: none; }")
        XCTAssertEqual(reset.string.string, "He said hi.")
        let quotes = try S.styled("<p>He said <q>hi</q>.</p>", css: "q { quotes: none }")
        XCTAssertEqual(quotes.string.string, "He said hi.")
        let replaced = try S.styled("<p>He said <q>hi</q>.</p>", css: "q::before { content: '<<' } q::after { content: '>>' }")
        XCTAssertEqual(replaced.string.string, "He said <<hi>>.")
    }

    // MARK: Counters

    func testCountersNumberHeadings() throws {
        let text = try S.styled("<h2>Alpha</h2><p class='s'>x</p><h2>Beta</h2><h2 class='skip'>Gamma</h2><p class='n'>y</p>", css: """
            body { counter-reset: chapter } h2 { counter-increment: chapter }
            h2::before { content: 'Chapter ' counter(chapter, upper-roman) '. ' } h2.skip { counter-increment: none }
            .s { counter-set: chapter 10 } .s::after { content: ' ' counter(chapter) } .n::after { content: ' ' counter(never) }
            """)
        XCTAssertEqual(S.paragraphs(text), ["Chapter I. Alpha", "x 10", "Chapter XI. Beta", "Chapter XI. Gamma", "y 0"])
    }

    func testCountersNestAndEndWithTheirScope() throws {
        let text = try S.styled("""
            <ol class='toc'><li>a<ol class='toc'><li>b</li><li>c</li></ol></li><li>d</li></ol>\
            <div><p class='r'>r</p><p class='i'>i</p></div><p class='i'>j</p>\
            <ol class='li' start='3'><li>k</li><li>l</li></ol>
            """, css: """
            ol.toc { counter-reset: item; list-style: none } ol.toc li { counter-increment: item }
            ol.toc li::before { content: counters(item, '.') ' ' }
            .r { counter-reset: x 5 } .i { counter-increment: x } .i::before { content: counter(x) ' ' }
            ol.li { list-style: none } ol.li li::before { content: counter(list-item, lower-alpha) ') ' }
            """)
        XCTAssertEqual(S.paragraphs(text), ["1 a", "1.1 b", "1.2 c", "2 d", "r", "6 i", "1 j", "c) k", "d) l"])
    }

    func testCountersInTableCellsAndRows() throws {
        let text = try S.styled("""
            <table><tr><td class='n'>a</td><td>b</td></tr><tr><td class='n'>c</td><td>d</td></tr></table>
            """, css: "table { counter-reset: row } tr { counter-increment: row } td.n::before { content: counter(row) '. ' }")
        let cells = try XCTUnwrap(text.tables().first?.row.table.cells.map(\.content.string))
        XCTAssertEqual(cells, ["1. a", "b", "2. c", "d"])
        XCTAssertFalse(text.report.generatedContentOmitted)
        let shown = try S.styled("<table><tr><td>a</td><td>b</td></tr></table>", css: "table::before { content: 'Table' }")
        XCTAssertTrue(shown.report.generatedContentOmitted, "a grid does not show the table's own")
    }

    func testFootnotesNumberedByCountersCountWhereTheyStand() throws {
        let text = try S.styled("""
            <p>One<a epub:type="noteref" href="#n1">*</a> two<a epub:type="noteref" href="#n2">*</a>.</p>\
            <aside epub:type="footnote" id="n1"><p>First.</p></aside><aside epub:type="footnote" id="n2"><p>Second.</p></aside>
            """, css: "aside { counter-increment: note } aside > p::before { content: counter(note) '. ' }")
        XCTAssertEqual(text.notes["n1"]?.string, "1. First.")
        XCTAssertEqual(text.notes["n2"]?.string, "2. Second.")
    }

    // MARK: The text map, positions and CFIs

    func testGeneratedCharactersHaveNoSpanAndPositionsNameTheBooksCharacters() throws {
        let css = ".note::before { content: 'Note: ' } .note::after { content: ' [end]' }"
        let text = try S.styled("<p id='p' class='note'>Take care.</p>", css: css)
        let plain = try S.styled("<p id='p' class='note'>Take care.</p>")
        XCTAssertEqual(text.string.string, "Note: Take care. [end]")
        for location in Array(0..<6) + Array(16..<22) { XCTAssertTrue(S.isGenerated(location, in: text), "\(location)") }
        XCTAssertEqual(text.anchors["p"], 0, "the element begins with its ::before")
        let node = try XCTUnwrap(S.textNode("Take care.", in: text))
        let start = try XCTUnwrap(text.map.position(at: 0, in: text.document))
        XCTAssertTrue(start.node === node && start.offset == 0, "generated text maps to the book's next character")
        XCTAssertEqual(text.map.location(of: DOMPosition(node, 0)), 6)
        // A selection that takes in generated text saves the book's characters, and comes back as them.
        let end = try XCTUnwrap(text.map.endPosition(at: 10, in: text.document))
        let cfi = EPUBCFI.localPath(from: start, to: end, in: text.document)
        let same = EPUBCFI.localPath(from: try XCTUnwrap(plain.map.position(at: 0, in: plain.document)),
                                     to: try XCTUnwrap(plain.map.endPosition(at: 4, in: plain.document)), in: plain.document)
        XCTAssertEqual(cfi, same, "the CFI is the one the same words have without generated content")
        let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: cfi, in: text.document))
        XCTAssertEqual(text.map.location(of: resolved.start), 6)
        XCTAssertEqual(text.map.location(of: resolved.end, isEnd: true), 10)
        // The passage a host is given and Copy are the book's own; VoiceOver reads what is drawn.
        XCTAssertEqual(text.mappedText(in: 0..<10), "Take")
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "Take care.")
        XCTAssertEqual(text.string.readerPlainText(in: NSRange(location: 0, length: 10), spoken: true), "Note: Take")
        XCTAssertEqual(text.string.readerPlainText(spoken: true), "Note: Take care. [end]")
        S.assertTextMapContracts(text)
    }

    func testSearchFindsTheBooksCharactersAndNotGeneratedOnes() throws {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(
            body: "<p class='note'>Take care.</p><p class='note'>Note well.</p>",
            css: ".note::before { content: 'Note: ' } .note::after { content: ' [end]' }"))
        let text = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0, typography: NativeTypography(fontSize: 16),
                                                            fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
        XCTAssertEqual(text.string.string, "Note: Take care. [end]\nNote: Note well. [end]")
        let spine = try SpineCFIs(publication: publication)
        let section = SearchResultBuilder.Section(text: text, publicationID: publication.id, engineID: "engine", bookmarkFormat: "format",
                                                  spine: spine, progress: NativeProgress(publication: publication))
        func batch(_ query: String) -> SearchResultBuilder.Batch {
            SearchResultBuilder.results(for: TextSearch.matches(of: query, in: text.document, locale: "en"), in: section, firstIndex: 0, limit: .max)
        }
        let note = batch("Note")
        XCTAssertEqual(note.results.map(\.matchedText), ["Note"], "the generated words are not the book's")
        XCTAssertEqual(note.ranges, [ReaderTextRange(section: 0, 29..<33)])
        XCTAssertEqual(note.results[0].contextBefore, "")
        XCTAssertEqual(note.results[0].contextAfter, " well.")
        XCTAssertTrue(batch("end").results.isEmpty)
        let care = batch("care")
        XCTAssertEqual(care.results.map(\.location.quote), ["care"])
        XCTAssertEqual(care.results[0].contextBefore, "Take ")
        let bookmark = try XCTUnwrap(care.results[0].location.bookmark)
        let target = try XCTUnwrap(spine.resolve(bookmark.value))
        let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: text.document))
        XCTAssertEqual(ReaderTextRange(start: text.renderedPosition(resolved.start), end: text.renderedPosition(resolved.end, isEnd: true)),
                       care.ranges[0])
    }

    // MARK: What is not drawn

    func testHiddenAndOffscreenGeneratedContent() throws {
        let text = try S.styled("<p class='h'>Hidden</p><p class='o'>Shown</p><p class='f'>Float</p>", css: """
            .h { visibility: hidden } .h::before { content: 'H: ' }
            .o::after { content: ' (new)'; position: absolute; left: -9999px }
            .f::before { content: '★'; float: left }
            """)
        XCTAssertEqual(S.paragraphs(text), ["H: Hidden", "Shown", "★Float"])
        XCTAssertNotNil(text.string.attribute(.readerHidden, at: 0, effectiveRange: nil), "hidden with its element")
        XCTAssertTrue(text.report.flowBoxesReflowed, "a floated box is written in line, and disclosed")
    }

    func testUnsupportedContentIsLeftOutAndDisclosed() throws {
        let text = try S.styled("<p class='i'>Icon</p><p class='l'><a href='#i'>Leader</a></p><p class='a'>Alt</p>", css: """
            .i::before { content: url(star.png) ' ' } .l a::after { content: leader('.') target-counter(attr(href), page) }
            .a::before { content: '★ ' / 'Star: ' }
            """)
        XCTAssertEqual(S.paragraphs(text), ["Icon", "Leader", "★ Alt"])
        XCTAssertTrue(text.report.generatedContentOmitted)
        XCTAssertTrue(NativeDisclosure.text(for: text.report)?.contains("adds before or after its content") == true)
        let supported = try S.styled("<p class='a'>Alt</p>", css: ".a::before { content: '★ ' / 'Star: ' }")
        XCTAssertFalse(supported.report.generatedContentOmitted, "alternative text is not shown, and leaves nothing out")
        XCTAssertNil(NativeDisclosure.text(for: supported.report))
    }

    /// An image in `content` is read as a background's is (`CSSPropertyParser.isImage`): one
    /// the reader does not know, such as a gradient prefixed for another engine, makes the
    /// declaration invalid, and the earlier one stays (CSS 2.2 §4.2; #643). One it knows is
    /// left out and disclosed.
    func testContentWithAFunctionTheReaderDoesNotKnowLeavesTheEarlierOne() throws {
        let invalid = ["-moz-linear-gradient(top, #fff, #000)", "-o-linear-gradient(top, #fff, #000)", "-ms-radial-gradient(red, blue)",
                       "bogus-gradient(red, blue)", "linear-gradient(top, #fff, #000)", "image(url(star.png))", "element(#a)", "paint(x)",
                       "bogus(1)", "'x' -moz-linear-gradient(top, #fff, #000)"]
        func styled(_ values: [String]) throws -> SectionText {
            try S.styled(values.indices.map { "<p class='e\($0)'>Text</p>" }.joined(),
                         css: values.enumerated().map { "p.e\($0.offset)::before { content: '> '; content: \($0.element) }" }.joined(separator: " "))
        }
        let kept = try styled(invalid)
        XCTAssertEqual(S.paragraphs(kept), Array(repeating: "> Text", count: invalid.count))
        XCTAssertFalse(kept.report.generatedContentOmitted, "nothing is left out")
        let valid = ["linear-gradient(red, blue)", "-webkit-linear-gradient(top, #fff, #000)", "url(star.png)", #"url("star.png") '* '"#,
                     #"-webkit-image-set(url(star.png) 1x)"#, "-webkit-cross-fade(url(a.png), url(b.png), 50%)"]
        let images = try styled(valid)
        XCTAssertEqual(S.paragraphs(images), ["Text", "Text", "Text", "* Text", "Text", "Text"])
        XCTAssertTrue(images.report.generatedContentOmitted, "the images are left out, and disclosed")
    }

    func testGeneratedTextIsBounded() throws {
        let long = String(repeating: "x", count: 2_000)
        let text = try S.styled(String(repeating: "<p>a</p>", count: 600), css: "p::before { content: '\(long)' }")
        XCTAssertLessThanOrEqual(text.string.length, GeneratedContentState.maximumLength + 2 * 600)
        XCTAssertTrue(text.report.generatedContentOmitted)
        XCTAssertTrue(text.string.string.hasSuffix("\na"), "the book's own text is all there")
    }

    // MARK: Appearance

    func testRulesForOneAppearanceDecideGeneratedCharactersAsInTheLightAppearance() throws {
        // What decides generated characters is resolved as in the light appearance (#130): a rule
        // for light sets it in both, and one for dark in neither. What paints follows the appearance.
        let body = "<p id='x' class='x'>Body</p><p>Other</p>"
        let css = """
            p::before { content: '> ' } p::after { content: ' #' counter(n) }
            @media (prefers-color-scheme: dark) {
                p::before { content: 'Dark: '; color: transparent } p { counter-increment: n 5; quotes: none }
                p.x::after { display: none } p::after { text-transform: uppercase }
            }
            @media (prefers-color-scheme: light) { p.x::before { content: 'Light: ' } p { counter-increment: n 2 } }
            """
        let light = try S.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: false))
        let dark = try S.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: true))
        XCTAssertEqual(light.string.string, "Light: Body #2\n> Other #4")
        XCTAssertEqual(dark.string.string, light.string.string)
        XCTAssertEqual(dark.map, light.map)
        XCTAssertEqual(dark.anchors, light.anchors)
        let paint = try [false, true].map { isDark in
            try StyleTestSupport.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: isDark))
                .style("x").generated?.before?.color?.alpha
        }
        XCTAssertEqual(paint, [nil, 0], "the dark rule's colour paints the dark appearance alone")
    }

    // MARK: Selectors

    func testOnlyBeforeAndAfterGenerateAndAStateNeverDoes() throws {
        let text = try S.styled("<p>a</p>", css: """
            p::before:hover { content: 'hover ' } p::first-line { color: red } p::marker { content: 'm' } p:after { content: '!' }
            @supports selector(p::before) { p::before { content: '1 ' } }
            @supports not selector(p::first-letter) { p::after { content: '?' } }
            """)
        XCTAssertEqual(text.string.string, "1 a?")
    }

    func testAPseudoElementWrittenAloneIsThatOfAnyElement() throws {
        // Selectors 4 §3.7: with its compound omitted, `::before` is `*::before`, as the resets
        // that write `*, ::before, ::after` rely on (#110).
        let text = try S.styled("<section><p>a</p></section>", css: """
            p::before { content: '> ' } @supports selector(::after) { p::after { content: ' <' } }
            ::before { font-weight: bold } section > :after { font-style: italic }
            """)
        XCTAssertEqual(text.string.string, "> a <")
        XCTAssertEqual(S.traits(">", in: text).intersection([.traitBold, .traitItalic]), .traitBold)
        XCTAssertEqual(S.traits("<", in: text).intersection([.traitBold, .traitItalic]), .traitItalic)
        XCTAssertEqual(S.traits("a", in: text).intersection([.traitBold, .traitItalic]), [], "nor do they style the element itself")
    }
}

/// Generated words in a session: drawn and selected with the book's, and left out of what Copy,
/// the host's selection and a saved quote take (#131, with the authored passages of #128).
@MainActor final class GeneratedContentSessionTests: XCTestCase {
    private func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testCopyAndTheHostsSelectionTakeTheBooksCharacters() async throws {
        let chapter = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Generated</title><style>
            .note::before { content: 'Note: ' } .note::after { content: ' [end]' }
            </style></head><body><p class="note">Take care.</p><p>After.</p></body></html>
            """
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter]))
        var events: [EPUBReaderEvent] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) {
            events.append($0)
        } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("ready and built") { session.isReady && session.book.isComplete }
        let text = try XCTUnwrap(session.book.section(0))
        XCTAssertTrue(text.string.string.hasPrefix("Note: Take care. [end]\nAfter."))
        // A selection over the whole paragraph, generated words included.
        let range = ReaderTextRange(section: 0, 0..<22)
        let canvas = try XCTUnwrap(session.canvas)
        canvas.show(range.start, selecting: nil)
        let view = try XCTUnwrap(canvas.textViews.first { canvas.localRange(of: range, in: $0) != nil })
        view.selectedRange = try XCTUnwrap(canvas.localRange(of: range, in: view))
        XCTAssertEqual(canvas.selectionText(for: view), "Take care.")
        #if os(macOS)
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), "Take care.")
        pasteboard.releaseGlobally()
        #else
        view.pasteboard = UIPasteboard.withUniqueName()
        view.copy(nil)
        XCTAssertEqual(view.pasteboard.string, "Take care.")
        #endif
        try await session.send(.locate(text: "Take care.", highlight: true))
        try await wait("located") { session.selection?.text == "Take care." }
        let selection = try XCTUnwrap(events.compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        XCTAssertEqual(selection.location.quote, "Take care.")
        XCTAssertEqual(session.selection?.range, ReaderTextRange(section: 0, 6..<16), "the book's characters, not the generated ones")
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false })
    }
}
