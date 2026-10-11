import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// `SearchResultBuilder` on occurrences the existing fixtures do not hold: at the document's
/// edges, across blocks and attachments, in formulas and header cells, beside clusters the
/// context window would split, in several sections, and under page-list and contents marks.
final class PositionSearchResultCoverageTests: XCTestCase {
    private func section(_ text: SectionText, publication: EPUBPublication = BuilderHarness.publication) throws -> SearchResultBuilder.Section {
        SearchResultBuilder.Section(text: text, publicationID: publication.id, engineID: "engine", bookmarkFormat: "format",
                                    spine: try SpineCFIs(publication: publication), progress: NativeProgress(publication: publication))
    }

    private func batch(_ query: String, in text: SectionText, publication: EPUBPublication = BuilderHarness.publication,
                       firstIndex: Int = 0, limit: Int = .max) throws -> SearchResultBuilder.Batch {
        let matches = TextSearch.matches(of: TextSearch.normalizeQuote(query), in: text.document, locale: "en")
        return SearchResultBuilder.results(for: matches, in: try section(text, publication: publication), firstIndex: firstIndex, limit: limit)
    }

    /// Each listed result's bookmark is its own occurrence: resolved again, it is the range the
    /// result is drawn and shown at.
    private func assertBookmarksRestoreTheirOccurrences(_ batch: SearchResultBuilder.Batch, in text: SectionText,
                                                        publication: EPUBPublication = BuilderHarness.publication,
                                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let spine = try SpineCFIs(publication: publication)
        XCTAssertEqual(batch.results.count, batch.ranges.count, file: file, line: line)
        for (result, range) in zip(batch.results, batch.ranges) {
            let bookmark = try XCTUnwrap(result.location.bookmark, file: file, line: line)
            XCTAssertTrue(EPUBCFI.isWellFormed(bookmark.value), bookmark.value, file: file, line: line)
            let target = try XCTUnwrap(spine.resolve(bookmark.value), bookmark.value, file: file, line: line)
            XCTAssertEqual(target.spineIndex, text.spineIndex, bookmark.value, file: file, line: line)
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: text.document), bookmark.value, file: file, line: line)
            XCTAssertEqual(ReaderTextRange(start: text.renderedPosition(resolved.start), end: text.renderedPosition(resolved.end, isEnd: true)), range,
                           bookmark.value, file: file, line: line)
            XCTAssertEqual(result.location.quote, result.matchedText, file: file, line: line)
            XCTAssertEqual(result.spineIndex, text.spineIndex, file: file, line: line)
            XCTAssertEqual(result.location.href, text.href, file: file, line: line)
            XCTAssertTrue(SearchResultBuilder.isRendered(range), file: file, line: line)
        }
    }

    func testOccurrencesAtTheSectionsEdgesHaveNothingBeyondThem() throws {
        let text = try BuilderHarness.build("<p>TARGET at the start and at the end TARGET</p>")
        let found = try batch("TARGET", in: text)
        XCTAssertEqual(found.results.map(\.contextBefore), ["", "TARGET at the start and at the end "])
        XCTAssertEqual(found.results.map(\.contextAfter), [" at the start and at the end TARGET", ""])
        XCTAssertEqual(found.results.map(\.location.bookmark?.value), ["epubcfi(/6/2!/4/2,/1:0,/1:6)", "epubcfi(/6/2!/4/2,/1:35,/1:41)"])
        XCTAssertEqual(found.ranges.map { [$0.start.offset, $0.end.offset] }, [[0, 6], [35, 41]])
        try assertBookmarksRestoreTheirOccurrences(found, in: text)

        let alone = try BuilderHarness.build("<p>TARGET</p>")
        let only = try batch("target", in: alone)
        XCTAssertEqual(only.results.map(\.matchedText), ["TARGET"], "the book's spelling, not the query's")
        XCTAssertEqual([only.results.first?.contextBefore, only.results.first?.contextAfter], ["", ""])
        XCTAssertEqual(only.results.first?.index, 0)
        XCTAssertFalse(only.hasMore)
        XCTAssertEqual(try batch("absent", in: alone).results.count, 0)
        XCTAssertEqual(SearchResultBuilder.results(for: [], in: try section(alone), firstIndex: 5, limit: 3).results.count, 0)
        XCTAssertEqual(try batch("target", in: alone, limit: 0).results.count, 0)
        XCTAssertTrue(try batch("target", in: alone, limit: 0).hasMore, "a rendered occurrence was left out")
    }

    func testAnOccurrenceRunsAcrossInlineElementsImagesAndParagraphs() throws {
        let text = try BuilderHarness.build("<p>A word <b>bro</b><i>ken</i> up.</p><p>It ends out.</p><p>Next begins, foo<img src=\"missing.png\" alt=\"ALT\"/>bar.</p>",
                                            rich: NativeRichContent())
        let inline = try batch("broken", in: text)
        XCTAssertEqual(inline.results.map(\.matchedText), ["broken"])
        XCTAssertEqual([inline.results.first?.contextBefore, inline.results.first?.contextAfter], ["A word ", " up."])
        XCTAssertEqual(inline.results.first?.location.bookmark?.value, "epubcfi(/6/2!/4/2,/2/1:0,/4/1:3)")
        try assertBookmarksRestoreTheirOccurrences(inline, in: text)

        // foliate joins text nodes, so this occurrence spans two paragraphs; its context is
        // each end's own paragraph.
        let blocks = try batch("out.Next", in: text)
        XCTAssertEqual(blocks.results.map(\.matchedText), ["out.Next"])
        XCTAssertEqual([blocks.results.first?.contextBefore, blocks.results.first?.contextAfter], ["It ends ", " begins, fooALTbar."])
        XCTAssertEqual(blocks.results.first?.location.bookmark?.value, "epubcfi(/6/2!/4,/4/1:8,/6/1:4)")
        try assertBookmarksRestoreTheirOccurrences(blocks, in: text)

        // The image between the two halves is inside the drawn range; the matched text is the
        // searched characters.
        let image = try batch("foobar", in: text)
        XCTAssertEqual(image.results.map(\.matchedText), ["foobar"])
        XCTAssertEqual([image.results.first?.contextBefore, image.results.first?.contextAfter], ["Next begins, ", "."])
        let range = try XCTUnwrap(image.ranges.first)
        XCTAssertEqual(text.mappedText(in: range.start.offset..<range.end.offset), "fooALTbar")
        try assertBookmarksRestoreTheirOccurrences(image, in: text)
    }

    func testImagesAndFormulasReadAsTheirDescriptionsInContext() throws {
        let text = try BuilderHarness.build("""
        <p>Before <img src="missing.png" alt="Diagram of flow"/> TARGET after <img src="gone.png" alt="Lost"/> end.</p>\
        <p>Formula <math xmlns="http://www.w3.org/1998/Math/MathML" alttext="x squared"><msup><mi>x</mi><mn>2</mn></msup></math> then TARGET again.</p>
        """, rich: NativeRichContent())
        let found = try batch("TARGET", in: text)
        XCTAssertEqual(found.results.map(\.contextBefore), ["Before Diagram of flow ", "Formula x squared then "])
        XCTAssertEqual(found.results.map(\.contextAfter), [" after Lost end.", " again."])
        try assertBookmarksRestoreTheirOccurrences(found, in: text)

        // Text inside a formula is searched like any other; its occurrence is the formula.
        let inside = try batch("x", in: text)
        XCTAssertEqual(inside.results.map(\.matchedText), ["x"])
        XCTAssertEqual(inside.results.first?.contextBefore, "Formula ")
        XCTAssertEqual(inside.results.first?.contextAfter, " then TARGET again.")
        XCTAssertEqual(inside.results.first?.location.bookmark?.value, "epubcfi(/6/2!/4/4/2/2/2,/1:0,/1:1)")
        let range = try XCTUnwrap(inside.ranges.first)
        XCTAssertEqual(range.end.offset - range.start.offset, 1, "the formula's one attachment character")
        XCTAssertNotNil(text.string.attribute(.attachment, at: range.start.offset, effectiveRange: nil))
        try assertBookmarksRestoreTheirOccurrences(inside, in: text)
        // An image's description is shown but is not searched text.
        XCTAssertEqual(try batch("Diagram", in: text).results.count, 0)
    }

    func testOccurrencesInHeaderAndBodyCellsReadTheirOwnCell() throws {
        let text = try BuilderHarness.build("""
        <table><thead><tr><th>Head TARGET</th><th>Other head</th></tr></thead>\
        <tbody><tr><td>second row</td><td>TARGET two <b>bold</b></td></tr><tr><td colspan="2">a wide TARGET cell</td></tr></tbody></table><p>after TARGET</p>
        """, rich: NativeRichContent())
        let found = try batch("TARGET", in: text)
        XCTAssertEqual(found.results.map(\.contextBefore), ["Head ", "", "a wide ", "after "])
        XCTAssertEqual(found.results.map(\.contextAfter), ["", " two bold", " cell", ""])
        XCTAssertEqual(found.ranges.map { $0.start.tableCell != nil }, [true, true, true, false])
        XCTAssertEqual(found.ranges.map(\.start), found.ranges.map(\.start).sorted(), "document order")
        XCTAssertEqual(found.results.map(\.index), [0, 1, 2, 3])
        try assertBookmarksRestoreTheirOccurrences(found, in: text)
    }

    /// "Never splitting a composed character": the window is cut on a cluster boundary even
    /// when the cluster straddles the 48 or 96 units read on each side.
    func testTheContextWindowNeverSplitsAClusterItStraddles() throws {
        let acute = "e\u{301}", umlaut = "o\u{308}", french = "🇫🇷", japanese = "🇯🇵", family = "👨‍👩‍👧‍👦"
        let cases: [(String, String, String, String, String)] = [
            ("combining marks", String(repeating: acute, count: 40) + "x", "y" + String(repeating: umlaut, count: 80),
             String(repeating: acute, count: 23) + "x", "y" + String(repeating: umlaut, count: 47)),
            ("flags", String(repeating: french, count: 20) + "x", "y" + String(repeating: japanese, count: 40),
             String(repeating: french, count: 11) + "x", "y" + String(repeating: japanese, count: 23)),
            ("joined emoji", String(repeating: family, count: 8) + "x", "y" + String(repeating: family, count: 12),
             String(repeating: family, count: 4) + "x", "y" + String(repeating: family, count: 8)),
            ("surrogate pairs", String(repeating: "𝒜", count: 40) + "x", "y" + String(repeating: "𝒷", count: 80),
             String(repeating: "𝒜", count: 23) + "x", "y" + String(repeating: "𝒷", count: 47)),
        ]
        for (label, before, after, expectedBefore, expectedAfter) in cases {
            let text = try BuilderHarness.build("<p>\(before)TARGET\(after)</p>")
            let result = try XCTUnwrap(try batch("TARGET", in: text).results.first, label)
            XCTAssertEqual(result.contextBefore, expectedBefore, label)
            XCTAssertEqual(result.contextAfter, expectedAfter, label)
            XCTAssertLessThanOrEqual(result.contextBefore.utf16.count, SearchResultBuilder.contextBefore, label)
            XCTAssertLessThanOrEqual(result.contextAfter.utf16.count, SearchResultBuilder.contextAfter, label)
        }
    }

    func testLineBreaksBoundTheContextAndInvisibleCharactersLeaveIt() throws {
        let text = try BuilderHarness.build("""
        <pre>line one\nTARGET line two\nline three</pre><p>one<br/>two TARGET three<br/>four</p>\
        <p>A hy&#xAD;phen&#xAD;ated TAR&#xAD;GET with&#xA0;hard&#x2003;spaces   and\n runs.</p><p dir="rtl">שלום עולם TARGET וגם עוד</p>
        """)
        let found = try batch("TARGET", in: text)
        XCTAssertEqual(found.results.map(\.matchedText), ["TARGET", "TARGET", "TARGET", "TARGET"], "a soft hyphen inside the occurrence is not listed")
        XCTAssertEqual(found.results.map(\.contextBefore), ["", "two ", "A hyphenated ", "שלום עולם "])
        XCTAssertEqual(found.results.map(\.contextAfter), [" line two", " three", " with hard spaces and runs.", " וגם עוד"])
        try assertBookmarksRestoreTheirOccurrences(found, in: text)
        let spaced = try batch("with hard spaces", in: text)
        XCTAssertEqual(spaced.results.map(\.matchedText), ["with hard spaces"], "every kind of space is listed as a space")
        XCTAssertEqual(spaced.results.first?.location.quote, "with hard spaces")
    }

    func testOnlyOccurrencesThatRenderAreListed() throws {
        let text = try BuilderHarness.build("""
        <p>Shown TARGET</p><template><p>TARGET in a template</p></template><p hidden="hidden">TARGET hidden by attribute</p>\
        <p class="gone">TARGET undisplayed</p><p>vis<span class="gone">ible TARGET hid</span>den</p><script>var TARGET;</script><p>Last TARGET</p>
        """, rules: [(".gone", { $0.display = .none })])
        XCTAssertEqual(TextSearch.matches(of: "TARGET", in: text.document, locale: "en").count, 6, "the matcher reads every text node outside scripts")
        let found = try batch("TARGET", in: text, firstIndex: 7)
        XCTAssertEqual(found.results.map(\.contextBefore), ["Shown ", "Last "])
        XCTAssertEqual(found.results.map(\.index), [7, 8], "numbered without gaps for what was skipped")
        XCTAssertFalse(found.hasMore)
        try assertBookmarksRestoreTheirOccurrences(found, in: text)
        let limited = try batch("TARGET", in: text, limit: 1)
        XCTAssertEqual(limited.results.count, 1)
        XCTAssertTrue(limited.hasMore, "hidden occurrences between do not hide the last rendered one")
    }

    /// The same words in two spine items: each result names its own item, and its bookmark
    /// carries that item's package step.
    func testTheSameTextInSeveralSectionsListsEachInItsOwnSection() throws {
        let body = "<h1 id=\"start\">Heading</h1><p>The repeated passage appears here.</p><p>And the repeated passage again.</p>"
        let publication = BuilderHarness.publication
        var all: [EPUBSearchResult] = [], ranges: [ReaderTextRange] = []
        for index in publication.spine.indices {
            let text = BuilderHarness.build(document: try BuilderHarness.document(body), spineIndex: index)
            let found = try batch("repeated passage", in: text, firstIndex: all.count)
            try assertBookmarksRestoreTheirOccurrences(found, in: text)
            all += found.results
            ranges += found.ranges
        }
        XCTAssertEqual(all.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(all.map(\.spineIndex), [0, 0, 1, 1], "spine order, then document order")
        XCTAssertEqual(all.map(\.location.href), ["OPS/one.xhtml", "OPS/one.xhtml", "OPS/two.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(all.map(\.location.bookmark?.value), ["epubcfi(/6/2!/4/4,/1:4,/1:20)", "epubcfi(/6/2!/4/6,/1:8,/1:24)",
                                                             "epubcfi(/6/4!/4/4,/1:4,/1:20)", "epubcfi(/6/4!/4/6,/1:8,/1:24)"])
        XCTAssertEqual(all.map(\.sectionTitle), ["First Chapter", "First Chapter", "Second Chapter", "Second Chapter"])
        XCTAssertEqual(ranges.map(\.start.section), [0, 0, 1, 1])
        XCTAssertEqual(ranges.map(\.start), ranges.map(\.start).sorted())
        let progressions = all.compactMap(\.location.progression)
        XCTAssertEqual(progressions.count, 4)
        XCTAssertEqual(progressions, progressions.sorted(), "progression grows through the book")
        XCTAssertTrue(progressions.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(Set(all.map(\.location.publicationID)), [publication.id])
        for (earlier, later) in zip(all, all.dropFirst()) {
            XCTAssertEqual(EPUBCFI.compare(try XCTUnwrap(earlier.location.bookmark?.value), try XCTUnwrap(later.location.bookmark?.value)), -1,
                           "bookmarks sort in result order")
        }
    }

    /// A result names the contents entry and the print page in effect where it starts.
    func testResultsCarryTheContentsTitleAndThePageInEffect() throws {
        let publication = try EPUBPublication.open(data: Fixture.pageList())
        func built(_ index: Int) throws -> SectionText {
            let resource = publication.spine[index].resource
            let document = try ContentDocument.parse(publication.data(for: resource), path: resource.path)
            return BuilderHarness.build(document: document, spineIndex: index, publication: publication)
        }
        let chapter = try built(1)
        func pages(_ query: String, in text: SectionText) throws -> [String?] {
            try batch(query, in: text, publication: publication).results.map { $0.location.page?.label }
        }
        XCTAssertEqual(try pages("Page one ends", in: chapter), ["1"])
        XCTAssertEqual(try pages("page two begins", in: chapter), ["2"])
        XCTAssertEqual(try pages("Two ends.", in: chapter), ["2"])
        XCTAssertEqual(try pages("Three.", in: chapter), ["3"])
        XCTAssertEqual(try pages("Four.", in: chapter), ["4"])
        let crossing = try XCTUnwrap(try batch("break and page two", in: chapter, publication: publication).results.first)
        XCTAssertEqual(crossing.location.page?.label, "1", "the page where the occurrence starts")
        XCTAssertEqual(crossing.location.pages?.map(\.label), ["1"])
        XCTAssertEqual(crossing.sectionTitle, "Chapter 1")
        XCTAssertEqual(crossing.location.title, "Chapter 1")
        try assertBookmarksRestoreTheirOccurrences(try batch("page two begins", in: chapter, publication: publication), in: chapter, publication: publication)

        // The next chapter opens without a marker: the page in effect carries over.
        let next = try built(2)
        XCTAssertEqual(try pages("Chapter 2", in: next), ["4"])
        XCTAssertEqual(try pages("page five begins", in: next), ["5"])
        XCTAssertEqual(try batch("Chapter 2", in: next, publication: publication).results.first?.sectionTitle, "Chapter 2")
        // The preface starts before the book's first page.
        let front = try built(0)
        XCTAssertEqual(try pages("Preface", in: front), [nil, "i"], "the heading, then the words after the marker for page i")
        XCTAssertEqual(try pages("the preface's own page", in: front), ["i"])
        XCTAssertEqual(try batch("Preface", in: front, publication: publication).results.first?.location.pages, nil)
    }

    /// doc/native-viewer.md: "Sections requiring unqualified HTML tree repair do not emit
    /// bookmarks", while "text search remain[s] available".
    func testSectionsWithoutCFIsListResultsWithoutBookmarks() throws {
        let document = try ContentDocument.parse(Data("<html><head><title>Old markup</title></head><body><p>Readable TARGET<br>still here<p>and TARGET again".utf8),
                                                 path: "OPS/one.xhtml")
        XCTAssertFalse(document.canResolveCFIs)
        let text = BuilderHarness.build(document: document)
        XCTAssertTrue(text.report.cfiUnavailable)
        let found = try batch("TARGET", in: text)
        XCTAssertEqual(found.results.map(\.matchedText), ["TARGET", "TARGET"])
        XCTAssertEqual(found.results.map(\.contextBefore), ["Readable ", "and "])
        XCTAssertEqual(found.results.map(\.contextAfter), ["", " again"])
        XCTAssertEqual(found.results.map(\.location.bookmark), [nil, nil])
        XCTAssertEqual(found.results.map(\.location.quote), ["TARGET", "TARGET"])
        XCTAssertEqual(found.results.map(\.location.href), ["OPS/one.xhtml", "OPS/one.xhtml"])
        XCTAssertTrue(found.ranges.allSatisfy(SearchResultBuilder.isRendered))
    }
}
