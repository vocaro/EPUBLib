import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// How one section's matches become results: which render, what text they cover, the context
/// around them and the section marks that name them. No session or window is involved.
final class SearchResultBuilderTests: XCTestCase {
    private func matches(_ query: String, in text: SectionText) -> [TextSearch.Match] {
        TextSearch.matches(of: query, in: text.document, locale: "en")
    }

    private func batch(_ query: String, in text: SectionText, limit: Int = .max, firstIndex: Int = 0) throws -> SearchResultBuilder.Batch {
        let publication = BuilderHarness.publication
        let section = SearchResultBuilder.Section(
            text: text, publicationID: publication.id, engineID: "engine", bookmarkFormat: "format",
            spine: try SpineCFIs(publication: publication), progress: NativeProgress(publication: publication))
        return SearchResultBuilder.results(for: matches(query, in: text), in: section, firstIndex: firstIndex, limit: limit)
    }

    func testMatchedTextReadsTheSearchedNodesAsTheMatcherDid() throws {
        let document = try BuilderHarness.document(
            "<p>A word split across <b>bold</b>face, then   spaced\n\t out.</p><p>Soft&#xAD;hyphen <script>skipped()</script>after Café.</p>")
        func texts(_ query: String) -> [String] {
            TextSearch.matches(of: query, in: document, locale: "en").map { TextSearch.text(of: $0, in: document) }
        }
        XCTAssertEqual(texts("boldface"), ["boldface"], "across inline elements")
        XCTAssertEqual(texts("then spaced out"), ["then   spaced\n\t out"], "the book's own white space")
        XCTAssertEqual(texts("softhyphen after"), ["Soft\u{AD}hyphen after"], "script text is not part of it")
        XCTAssertEqual(texts("cafe"), ["Café"], "the book's own spelling, not the query's")
        XCTAssertEqual(SearchResultBuilder.listed("then   spaced\n\t out".unicodeScalars), "then spaced out")
        XCTAssertEqual(SearchResultBuilder.listed("Soft\u{AD}hyphen\u{2069} می\u{200C}خواهم 👨‍👩‍👧‍👦".unicodeScalars), "Softhyphen می\u{200C}خواهم 👨‍👩‍👧‍👦",
                       "layout controls go; joiners that shape text stay")
        let foreign = try BuilderHarness.document("<p>Elsewhere</p>")
        let match = try XCTUnwrap(TextSearch.matches(of: "split across", in: document, locale: "en").first)
        XCTAssertEqual(TextSearch.text(of: match, in: foreign), "", "a match is read in its own document")
    }

    func testOnlyRenderedOccurrencesBecomeResultsInDocumentOrder() throws {
        let text = try BuilderHarness.build("""
        <h1 id="top">Heading with pin</h1><p class="gone">A hidden pin.</p><p>First pin, second PIN.</p>\
        <p class="gone">Another hidden pin</p><p>Third pín closes.</p><p class="gone">A trailing hidden pin</p>
        """, rules: [(".gone", { $0.display = .none })])
        let hidden = matches("hidden pin", in: text).map { SearchResultBuilder.renderedRange(of: $0, in: text) }
        XCTAssertEqual(hidden.count, 3)
        XCTAssertTrue(hidden.allSatisfy { !SearchResultBuilder.isRendered($0) },
                      "hidden text maps to an empty or reversed range wherever it sits: \(hidden)")

        let found = try batch("pin", in: text, firstIndex: 40)
        XCTAssertEqual(found.results.map(\.matchedText), ["pin", "pin", "PIN", "pín"])
        XCTAssertEqual(found.results.map(\.index), [40, 41, 42, 43])
        XCTAssertEqual(found.ranges.map(\.start), found.ranges.map(\.start).sorted())
        XCTAssertFalse(found.hasMore)
        for (result, range) in zip(found.results, found.ranges) {
            XCTAssertTrue(SearchResultBuilder.isRendered(range))
            XCTAssertEqual(text.mappedText(in: range.start.offset..<range.end.offset), result.matchedText)
            XCTAssertEqual(result.location.quote, result.matchedText)
            XCTAssertEqual(result.spineIndex, 0)
            XCTAssertEqual(result.location.href, text.href)
            // The bookmark is the occurrence itself.
            let bookmark = try XCTUnwrap(result.location.bookmark)
            XCTAssertEqual(bookmark.engineID, "engine")
            XCTAssertEqual(bookmark.format, "format")
            let spine = try SpineCFIs(publication: BuilderHarness.publication)
            let target = try XCTUnwrap(spine.resolve(bookmark.value))
            XCTAssertEqual(target.spineIndex, 0)
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: text.document))
            XCTAssertEqual(ReaderTextRange(start: text.renderedPosition(resolved.start), end: text.renderedPosition(resolved.end, isEnd: true)), range)
        }
        XCTAssertEqual(found.results.map(\.contextBefore), ["Heading with ", "First ", "First pin, second ", "Third "])
        XCTAssertEqual(found.results.map(\.contextAfter), ["", ", second PIN.", ".", " closes."])

        let bounded = try batch("pin", in: text, limit: 2)
        XCTAssertEqual(bounded.results.map(\.matchedText), ["pin", "pin"])
        XCTAssertTrue(bounded.hasMore, "a later rendered occurrence was left out")
        let exact = try batch("pin", in: text, limit: 4)
        XCTAssertEqual(exact.results.count, 4)
        XCTAssertFalse(exact.hasMore, "only hidden occurrences follow the last listed one")
    }

    func testContextStaysInItsParagraphAndIsCutAtWholeWords() throws {
        let long = (1...40).map { "word\($0)" }.joined(separator: " ")
        let text = try BuilderHarness.build("""
        <p>Earlier paragraph.</p><p>\(long) TARGET \(long)</p><ul><li>Listed TARGET item</li></ul>\
        <table><tr><td>Plain</td><td>In a cell the TARGET sits</td></tr></table><p>👨‍👩‍👧‍👦TARGET👨‍👩‍👧‍👦</p><p>Line one<br/>TARGET line two</p>
        """, rich: NativeRichContent())
        let found = try batch("TARGET", in: text)
        XCTAssertEqual(found.results.count, 5)

        let prose = found.results[0]
        XCTAssertTrue(prose.contextBefore.hasSuffix("word39 word40 "), prose.contextBefore)
        XCTAssertTrue(prose.contextBefore.hasPrefix("word"), "the partial word at the cut is dropped: \(prose.contextBefore)")
        XCTAssertLessThanOrEqual(prose.contextBefore.utf16.count, SearchResultBuilder.contextBefore)
        XCTAssertFalse(prose.contextBefore.contains("Earlier"))
        XCTAssertTrue(prose.contextAfter.hasPrefix(" word1 word2 "), prose.contextAfter)
        XCTAssertLessThanOrEqual(prose.contextAfter.utf16.count, SearchResultBuilder.contextAfter)
        XCTAssertTrue(long.components(separatedBy: " ").contains(String(prose.contextAfter.split(separator: " ").last ?? "")),
                      "the context ends on a whole word: \(prose.contextAfter)")

        XCTAssertEqual(found.results[1].contextBefore, "Listed ", "the generated list marker is not the book's text")
        XCTAssertEqual(found.results[1].contextAfter, " item")
        XCTAssertNotNil(found.ranges[2].start.tableCell, "the occurrence is read in its table cell")
        XCTAssertEqual(found.results[2].contextBefore, "In a cell the ")
        XCTAssertEqual(found.results[2].contextAfter, " sits")
        XCTAssertEqual(found.results[3].contextBefore, "👨‍👩‍👧‍👦", "a composed character is never split")
        XCTAssertEqual(found.results[3].contextAfter, "👨‍👩‍👧‍👦")
        XCTAssertEqual(found.results[4].contextBefore, "", "a line break bounds the context")
        XCTAssertEqual(found.results[4].contextAfter, " line two")
    }

    func testTrimmingCollapsesWhiteSpaceAndKeepsTheJoiningSpace() {
        func before(_ raw: String, cut: Bool = false) -> String { SearchResultBuilder.trimmed(raw, before: true, isCut: cut) }
        func after(_ raw: String, cut: Bool = false) -> String { SearchResultBuilder.trimmed(raw, before: false, isCut: cut) }
        XCTAssertEqual(before("  Spaced \t out\u{00A0}text  "), "Spaced out text ")
        XCTAssertEqual(after("  spaced \t out  "), " spaced out")
        XCTAssertEqual(before("soft\u{00AD}hyphen\u{200B} "), "softhyphen ", "format characters are dropped")
        XCTAssertEqual(before("first\nsecond line "), "second line ")
        XCTAssertEqual(after(" tail\u{2028}next"), " tail")
        XCTAssertEqual(before("rtial kept words ", cut: true), "kept words ")
        XCTAssertEqual(after(" kept words parti", cut: true), " kept words")
        XCTAssertEqual(before("onlyword", cut: true), "onlyword", "a single cut word is better than nothing")
        XCTAssertEqual(after(" onlyword", cut: true), " onlyword")
        XCTAssertEqual(before("cut\nwhole line ", cut: true), "whole line ", "a line's start is not a cut")
        XCTAssertEqual(before(""), "")
        XCTAssertEqual(after("   "), "")
    }

    /// A section of ten thousand paragraphs, each an occurrence: the most one search lists.
    /// Results are built off the main actor; this records the cost with a loose bound.
    func testTenThousandResultsBuildQuickly() throws {
        let paragraph = "<p>It was the best of times, it was the worst of times, it was the age of <em>foolishness</em>.</p>\n"
        let text = try BuilderHarness.build(String(repeating: paragraph, count: 10_000))
        let found = matches("the age of foolishness", in: text)
        XCTAssertEqual(found.count, 10_000)
        var built = SearchResultBuilder.Batch()
        let elapsed = try ContinuousClock().measure { built = try batch("the age of foolishness", in: text) }
        XCTAssertEqual(built.results.count, 10_000)
        XCTAssertEqual(built.results.last?.index, 9_999)
        XCTAssertEqual(built.results.last?.contextAfter, ".")
        print("10,000 search results: \(elapsed)")
        #if DEBUG
        XCTAssertLessThan(elapsed, .seconds(5))
        #else
        XCTAssertLessThan(elapsed, .seconds(1))
        #endif
        // The cached child indices write the CFIs the uncached walk does.
        let spine = try SpineCFIs(publication: BuilderHarness.publication)
        for index in stride(from: 0, to: found.count, by: 997) + [found.count - 1] {
            XCTAssertEqual(built.results[index].location.bookmark?.value,
                           spine.cfi(spineIndex: 0, start: found[index].start, end: found[index].end, in: text.document))
        }
    }

    func testSectionMarksAnswerAsTheTitleAndPageLookupsDo() throws {
        let progress = NativeProgress(publication: try EPUBPublication.open(data: Fixture.pageList()))
        let anchors = [0: ["page-i": 1_000], 1: ["page-1": 0, "page-2": 2_000, "page-3": 4_000, "page-4": 4_010], 2: ["page-5": 2_000]]
        for section in 0...2 {
            let marks = progress.marks(inSection: section, anchors: anchors[section] ?? [:])
            for offset in [0, 1, 999, 1_000, 1_001, 1_999, 2_000, 2_001, 3_999, 4_000, 4_005, 4_010, 4_011, 9_000] {
                let position = ReaderTextPosition(section: section, offset: offset)
                let lookup = { (index: Int, fragment: String) in anchors[index]?[fragment] }
                XCTAssertEqual(marks.title(at: offset), progress.title(at: position, anchor: lookup), "title at \(section):\(offset)")
                XCTAssertEqual(marks.page(at: offset),
                               progress.pages(in: ReaderTextRange(start: position, end: position), isShown: { _ in true }, anchor: lookup).page,
                               "page at \(section):\(offset)")
            }
        }
        // Entries within one section, in navigation order.
        let nested = NativeProgress(publication: try EPUBPublication.open(data: NativeSearchResultsTests.book()))
        let marks = nested.marks(inSection: 0, anchors: ["start": 0, "later": 500])
        XCTAssertEqual([0, 499, 500, 900].map { marks.title(at: $0) }, ["First Chapter", "First Chapter", "Later Part", "Later Part"])
        XCTAssertEqual([0, 499, 500].map { marks.page(at: $0)?.label }, ["1", "1", "2"])
        XCTAssertEqual(nested.marks(inSection: 2, anchors: [:]).title(at: 0), "Third Chapter")
        XCTAssertEqual(nested.marks(inSection: 1, anchors: [:]).page(at: 10)?.label, "2", "the page in effect carries over")
    }
}
