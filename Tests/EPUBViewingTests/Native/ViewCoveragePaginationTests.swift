import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The page rules of doc/native-viewer.md "Layout", "Pages", over inputs the tidy fixtures leave
/// out: forced breaks and kept paragraphs together, sections that are empty of text, lines and
/// pages of extreme sizes, and the 8,192-character justification boundary.
@MainActor final class ViewCoveragePaginationTests: XCTestCase {
    private let size = CGSize(width: 320, height: 500)

    /// A page 300 wide that holds `lines` body lines and half of another.
    private func page(lines: CGFloat) -> CGSize { CGSize(width: 300, height: ViewCoverage.bodyLineHeight * (lines + 0.5)) }

    private func plain(_ text: String) -> NSAttributedString { CanvasText.body(text, style: CanvasText.bodyStyle(spacing: 0)) }

    private func paragraph(_ text: String, keep: Bool = false, breakBefore: Bool = false) -> NSAttributedString {
        ViewCoverage.marked(plain(text + "\n"), keep: keep, breakBefore: breakBefore)
    }

    // MARK: Forced breaks

    func testAForcedBreakOnTheFirstParagraphLeavesNoEmptyFirstPage() {
        let text = ViewCoverage.joined([CanvasText.heading("Chapter"), plain("\n"), ViewCoverage.rows("Line", 4)])
        let pages = ReaderPaginator(text: text, size: page(lines: 12)).allPages
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.range, NSRange(location: 0, length: text.length))
        XCTAssertEqual(pages.first?.topSpacing, 24, "the section's first paragraph keeps its spacing before")
        XCTAssertEqual(pages.first?.continuesParagraph, false)
        // The same when the break is all the section holds.
        let only = ReaderPaginator(text: paragraph("", breakBefore: true), size: size).allPages
        XCTAssertEqual(only.map(\.range), [NSRange(location: 0, length: 1)])
    }

    func testConsecutiveForcedBreaksEachStartAPage() {
        let text = ViewCoverage.joined([ViewCoverage.rows("Break", 5, breakBefore: true), ViewCoverage.rows("Tail", 2)])
        let pages = ReaderPaginator(text: text, size: page(lines: 10)).allPages
        ViewCoverage.assertPartition(pages, of: text)
        XCTAssertEqual(ViewCoverage.pageBoundaries(pages), [0, 8, 16, 24, 32], "one page for each \"Break n\" paragraph")
        XCTAssertEqual(pages.last?.range.length, 8 + 2 * 7, "the last break's page runs on into what follows")
    }

    func testAForcedBreakWinsOverKeepWithNext() {
        // The heading keeps with the next paragraph, which must start a page: the break is
        // honoured and the heading stays where it is, at the page's end or its last line.
        for leading in [3, 9] {
            let text = ViewCoverage.joined([ViewCoverage.rows("Line", leading), paragraph("Heading", keep: true),
                                            paragraph("Chapter", breakBefore: true), ViewCoverage.rows("Body", 3)])
            let chapter = leading * 7 + 8
            let pages = ReaderPaginator(text: text, size: page(lines: 10)).allPages
            ViewCoverage.assertPartition(pages, of: text)
            XCTAssertEqual(ViewCoverage.pageBoundaries(pages), [0, chapter], "\(leading) lines before the heading")
        }
    }

    // MARK: Keep with next

    func testAChainOfKeptHeadingsMovesToTheNextPageTogether() {
        // Eight lines, two headings and the body: the tenth line is the second heading, so both
        // headings open page two with the line they introduce.
        func pages(keep: Bool) -> [ReaderPage] {
            let text = ViewCoverage.joined([ViewCoverage.rows("Line", 8), paragraph("Part", keep: keep), paragraph("Chapter", keep: keep),
                                            ViewCoverage.rows("Body", 5)])
            let pages = ReaderPaginator(text: text, size: page(lines: 10)).allPages
            ViewCoverage.assertPartition(pages, of: text)
            return pages
        }
        XCTAssertEqual(ViewCoverage.pageBoundaries(pages(keep: false)), [0, 8 * 7 + 5 + 8], "unkept, both headings end page one")
        XCTAssertEqual(ViewCoverage.pageBoundaries(pages(keep: true)), [0, 8 * 7])
    }

    func testAKeptParagraphOfSeveralLinesMovesWhole() throws {
        let heading = "A heading that is long enough to wrap onto a second line"
        XCTAssertEqual(ViewCoverage.lines(of: plain(heading), width: 300).count, 2, "the fixture's heading takes two lines")
        func pages(keep: Bool) -> [ReaderPage] {
            let text = ViewCoverage.joined([ViewCoverage.rows("Line", 8), paragraph(heading, keep: keep), ViewCoverage.rows("Body", 5)])
            let pages = ReaderPaginator(text: text, size: page(lines: 10)).allPages
            ViewCoverage.assertPartition(pages, of: text)
            return pages
        }
        XCTAssertEqual(ViewCoverage.pageBoundaries(pages(keep: false)), [0, 8 * 7 + heading.utf16.count + 1])
        let kept = pages(keep: true)
        XCTAssertEqual(ViewCoverage.pageBoundaries(kept), [0, 8 * 7], "never split from its second line or from the body")
        XCTAssertEqual(kept[1].continuesParagraph, false)
    }

    func testKeptParagraphsThatOpenAPageStayOnIt() {
        // Both headings keep with an image that cannot share their page. They already open the
        // page, so there is nowhere to move them: "never past the page's first line".
        let size = page(lines: 10)
        let text = ViewCoverage.joined([paragraph("Part", keep: true), paragraph("Chapter", keep: true),
                                        CanvasText.attachment(size: CGSize(width: 100, height: size.height - 5)), plain("\n"),
                                        ViewCoverage.rows("Body", 3)])
        let pages = ReaderPaginator(text: text, size: size).allPages
        ViewCoverage.assertPartition(pages, of: text)
        XCTAssertEqual(pages.first?.range, NSRange(location: 0, length: 5 + 8))
        XCTAssertEqual(pages.dropFirst().first?.range.location, 13, "the image opens page two")
    }

    func testASectionOfKeptParagraphsEndsWithoutTheNextOne() {
        // Every paragraph keeps with the next and the last has none.
        let text = ViewCoverage.rows("Row", 25, keep: true)
        let pages = ReaderPaginator(text: text, size: page(lines: 10)).allPages
        ViewCoverage.assertPartition(pages, of: text)
        XCTAssertEqual(pages.map(\.range.length), [10 * 6, 10 * 7, 5 * 7], "pages fill: ten rows, ten rows, five rows")
    }

    // MARK: Sections without text

    func testSectionsHoldingOnlyWhitespaceAnImageOrABreakHaveOnePage() {
        let image = CanvasText.attachment(size: CGSize(width: 120, height: 80))
        let tall = CanvasText.attachment(size: CGSize(width: 120, height: 2_000))
        let sections: [(String, NSAttributedString)] = [
            ("a paragraph break", plain("\n")), ("blank paragraphs", plain(" \n\t\n\u{00A0}\n\n")), ("a space", plain(" ")),
            ("line separators", plain("\u{2028}\u{2028}")), ("a zero-width space", plain("\u{200B}")),
            ("an image", image), ("an image and its break", ViewCoverage.joined([image, plain("\n")])),
            ("an image taller than the page", tall), ("a forced break", paragraph("", breakBefore: true)),
            ("a kept blank", paragraph("", keep: true)),
        ]
        for (name, text) in sections {
            let paginator = ReaderPaginator(text: text, size: size)
            let pages = paginator.allPages
            XCTAssertEqual(pages.map(\.range), [NSRange(location: 0, length: text.length)], name)
            XCTAssertEqual(pages.first?.layoutEnd, text.length, name)
            XCTAssertEqual(paginator.pageIndex(containing: 0), 0, name)
            XCTAssertEqual(paginator.pageIndex(containing: text.length), 0, name)
            XCTAssertEqual(paginator.text(for: pages[0]).string, text.string, name)
            XCTAssertTrue(paginator.isComplete, name)
            XCTAssertFalse(paginator.holdsLayout, name)
        }
        XCTAssertGreaterThan(ReaderPaginator(text: tall, size: size).allPages[0].height, size.height)
    }

    func testBlankParagraphsFillPagesLikeAnyOtherLines() {
        let text = plain(String(repeating: "\n", count: 400))
        let size = page(lines: 10)
        let pages = ReaderPaginator(text: text, size: size).allPages
        ViewCoverage.assertPartition(pages, of: text)
        XCTAssertEqual(pages.map(\.range.length), Array(repeating: 10, count: 40))
        for page in pages { XCTAssertLessThanOrEqual(page.extent, size.height + 0.5) }
    }

    // MARK: Extreme sizes

    func testALineTallerThanAPageGetsAPageOfItsOwn() throws {
        let giant = CanvasText.body("T\n", style: CanvasText.bodyStyle(spacing: 0), size: 600)
        let text = ViewCoverage.joined([ViewCoverage.rows("Line", 3), giant, ViewCoverage.rows("After", 3)])
        let pages = ReaderPaginator(text: text, size: size).allPages
        ViewCoverage.assertPartition(pages, of: text)
        XCTAssertEqual(pages.map(\.range), [NSRange(location: 0, length: 21), NSRange(location: 21, length: 2), NSRange(location: 23, length: 24)])
        XCTAssertGreaterThan(pages[1].height, size.height)
    }

    func testPagesShorterThanALineHoldOneLineEach() {
        let text = CanvasText.section(0, chapters: 2, paragraphs: 2)
        for width in [46.5, 320] as [CGFloat] {
            let lines = ViewCoverage.lines(of: text, width: width)
            for height in [0, 1, ViewCoverage.bodyLineHeight / 2, ViewCoverage.bodyLineHeight] as [CGFloat] {
                let paginator = ReaderPaginator(text: text, size: CGSize(width: width, height: height))
                let pages = paginator.allPages
                XCTAssertEqual(pages.map(\.range), lines.map(\.range), "\(width) × \(height): a page for each line")
                XCTAssertEqual(paginator.pageIndex(containing: text.length), lines.count - 1)
            }
        }
    }

    func testAParagraphOf100000CharactersPagesLineByLine() {
        var words: [String] = []
        var length = 0
        while length < 100_000 {
            let sentence = CanvasText.sentence(20 + words.count % 13, seed: words.count)
            words.append(sentence)
            length += sentence.utf16.count + 1
        }
        let text = CanvasText.body(words.joined(separator: " "), style: CanvasText.bodyStyle(hyphenates: true, indent: 24))
        XCTAssertFalse(text.string.contains("\n"))
        let paginator = ReaderPaginator(text: text, size: size)
        let pages = paginator.allPages
        ViewCoverage.assertPartition(pages, of: text)
        ViewCoverage.assertPagesLayOutLikeTheSection(paginator)
        XCTAssertGreaterThan(pages.count, 80)
        for page in pages {
            XCTAssertLessThanOrEqual(page.extent, size.height + 0.5)
            XCTAssertLessThan(page.layoutEnd - NSMaxRange(page.range), 400, "a few lines of context, not the paragraph's rest")
        }
        XCTAssertEqual(pages.filter(\.continuesParagraph).count, pages.count - 1)
    }

    // MARK: Stability

    /// A section of every block the paginator treats specially.
    private func mixedSection() -> NSAttributedString {
        let justified = CanvasText.bodyStyle(alignment: .justified, hyphenates: true, indent: 24)
        let long = (0..<80).map { CanvasText.sentence(24 + $0 % 7, seed: $0) }.joined(separator: " ")
        return ViewCoverage.joined([
            CanvasText.heading("Mixed chapter one"), plain("\n"),
            CanvasText.body(CanvasText.sentence(90, seed: 1) + "\n"),
            CanvasText.heading("A kept heading", breakBefore: false), plain("\n"),
            CanvasText.attachment(size: CGSize(width: 180, height: 140)), plain("\n"),
            CanvasText.body(CanvasText.sentence(160, seed: 2) + "\n", style: justified),
            CanvasText.body((0..<40).map { "verse \($0) " + CanvasText.sentence($0 % 4, seed: $0) }.joined(separator: "\u{2028}") + "\n"),
            CanvasText.heading("Mixed chapter two"), plain("\n"),
            CanvasText.body(long + "\n", style: justified),
            ViewCoverage.rows("Row", 30, keep: true),
            CanvasText.body("The end, without a paragraph break."),
        ])
    }

    func testPaginatingAgainInStepsOrOutOfOrderGivesTheSamePages() {
        let text = mixedSection()
        XCTAssertGreaterThan(text.length, ReaderPaginator.wholeParagraphJustification + 3_000, "holds a paragraph justified line by line")
        for size in [size, CGSize(width: 431, height: 333)] {
            let once = ReaderPaginator(text: text, size: size).allPages
            ViewCoverage.assertPartition(once, of: text)
            XCTAssertEqual(ReaderPaginator(text: text, size: size).allPages, once, "twice")
            let stepped = ReaderPaginator(text: text, size: size)
            var steps = 0
            while !stepped.isComplete, steps < 10_000 {
                _ = stepped.advance(toward: text.length, pages: 1)
                steps += 1
                XCTAssertLessThanOrEqual(stepped.pages.count, steps, "at most one page a step")
            }
            XCTAssertEqual(stepped.pages, once, "a page at a time")
            let jumped = ReaderPaginator(text: text, size: size)
            for offset in [text.length / 2, text.length / 3, text.length, 0, text.length - 1] {
                let index = jumped.pageIndex(containing: offset)
                XCTAssertEqual(index, once.firstIndex { offset < NSMaxRange($0.range) } ?? once.count - 1, "\(offset)")
            }
            XCTAssertEqual(jumped.allPages, once, "after looking pages up out of order")
            let indexed = ReaderPaginator(text: text, size: size)
            for index in [once.count - 1, 3, 0, once.count / 2] { XCTAssertEqual(indexed.page(at: index), once[index]) }
            XCTAssertNil(indexed.page(at: once.count))
            XCTAssertNil(indexed.page(at: Int.max))
        }
    }

    func testEveryCharacterIsOnExactlyOnePageThatFitsAtEverySize() {
        let text = mixedSection()
        for width in [140, 237, 320, 431, 720] as [CGFloat] {
            let lineStarts = Set(ViewCoverage.lines(of: text, width: width).map(\.range.location))
            for height in [120, 333, 500, 904] as [CGFloat] {
                let paginator = ReaderPaginator(text: text, size: CGSize(width: width, height: height))
                let pages = paginator.allPages
                let label = "\(width) × \(height)"
                ViewCoverage.assertPartition(pages, of: text, label)
                ViewCoverage.assertPagesLayOutLikeTheSection(paginator, label)
                for page in pages {
                    let lines = lineStarts.filter { NSLocationInRange($0, page.range) }.count
                    if lines > 1 || page.measuredLineLengths.map({ $0.count > 1 }) == true {
                        XCTAssertLessThanOrEqual(page.extent, height + 0.5, "\(label) page at \(page.range.location)")
                    }
                    if page.measuredLineLengths == nil {
                        XCTAssertTrue(lineStarts.contains(page.range.location), "\(label): page at \(page.range.location) starts a line")
                    }
                    XCTAssertGreaterThanOrEqual(page.layoutEnd, NSMaxRange(page.range))
                    XCTAssertLessThanOrEqual(page.layoutEnd, text.length)
                }
            }
        }
    }

    func testPageLookupsAtPageBoundariesAndOutsideTheSection() {
        let text = CanvasText.section(6, chapters: 2, paragraphs: 6)
        let paginator = ReaderPaginator(text: text, size: size)
        XCTAssertFalse(paginator.covers(0), "nothing is paginated until asked")
        XCTAssertEqual(paginator.paginatedLength, 0)
        XCTAssertEqual(paginator.pageIndex(containing: 0), 0)
        XCTAssertEqual(paginator.pages.count, 1, "lazily: only the first page")
        XCTAssertTrue(paginator.covers(0))
        XCTAssertEqual(paginator.paginatedLength, NSMaxRange(paginator.pages[0].range))
        XCTAssertFalse(paginator.covers(paginator.paginatedLength), "a page's end belongs to the next page")
        XCTAssertTrue(paginator.advance(toward: paginator.paginatedLength, pages: 1))
        XCTAssertEqual(paginator.pages.count, 2)
        XCTAssertFalse(paginator.advance(toward: text.length, pages: 0), "no budget, no progress")
        XCTAssertEqual(paginator.pages.count, 2)
        let pages = paginator.allPages
        for (index, page) in pages.enumerated() {
            XCTAssertEqual(paginator.pageIndex(containing: page.range.location), index)
            XCTAssertEqual(paginator.pageIndex(containing: NSMaxRange(page.range) - 1), index)
        }
        XCTAssertEqual(paginator.pageIndex(containing: text.length), pages.count - 1, "the section's end is on its last page")
        XCTAssertEqual(paginator.pageIndex(containing: text.length + 10_000), pages.count - 1, "an offset from longer, replaced text")
        XCTAssertEqual(paginator.pageIndex(containing: -1), 0)
        XCTAssertTrue(paginator.covers(Int.max))
        XCTAssertTrue(paginator.advance(toward: Int.max, pages: 0), "complete: nothing left to do")
        XCTAssertTrue(paginator.sourceText === text)
    }

    // MARK: Spacing and context

    func testSpacingBeforeIsKeptAtTheStartAndAtForcedBreaksOnly() {
        func spaced(_ text: String, _ spacing: CGFloat, breakBefore: Bool = false) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.2
            style.paragraphSpacingBefore = spacing
            return ViewCoverage.marked(CanvasText.body(text + "\n", style: style), breakBefore: breakBefore)
        }
        let size = page(lines: 10)
        var parts = (0..<12).map { spaced("Paragraph \($0)", 30) }
        parts.append(spaced("Forced", 30, breakBefore: true))
        parts += (0..<12).map { spaced("Later \($0)", 30) }
        let pages = ReaderPaginator(text: ViewCoverage.joined(parts), size: size).allPages
        ViewCoverage.assertPartition(pages, of: ViewCoverage.joined(parts))
        let forced = 12 * 12 + 2 // "Paragraph n\n" is 12 or 13 characters.
        XCTAssertGreaterThan(pages.count, 4)
        XCTAssertEqual(pages.map(\.topSpacing), pages.map { $0.range.location == 0 || $0.range.location == forced ? 30 : 0 },
                       "margins are truncated at unforced breaks: \(pages.map(\.range))")
        XCTAssertTrue(pages.contains { $0.range.location == forced })
        for page in pages { XCTAssertLessThanOrEqual(page.extent, size.height + 0.5, "spacing counts against the page") }
        // At most half the page.
        XCTAssertEqual(ReaderPaginator(text: spaced("Far down", 4_000), size: size).allPages.first?.topSpacing, size.height / 2)
    }

    func testAPageEndingInsideAParagraphLaysOutAFewLinesMoreOrToALineBreak() {
        let prose = CanvasText.body((0..<6).map { CanvasText.sentence(120, seed: $0) }.joined(separator: "\n"))
        let verse = CanvasText.body((0..<200).map { "verse \($0)" }.joined(separator: "\u{2028}"))
        for text in [prose, verse] {
            let characters = text.string as NSString
            let lines = ViewCoverage.lines(of: text, width: size.width)
            let pages = ReaderPaginator(text: text, size: size).allPages
            XCTAssertGreaterThan(pages.count, 2)
            for page in pages {
                guard var index = lines.firstIndex(where: { NSMaxRange($0.range) == NSMaxRange(page.range) }) else {
                    XCTFail("page \(page.range) ends inside a line")
                    continue
                }
                // Up to three lines on, stopping after one that nothing later can change.
                var context = 0
                func ends(_ line: ViewCoverage.Line) -> Bool {
                    let last = characters.character(at: NSMaxRange(line.range) - 1)
                    return NSMaxRange(line.range) == text.length || last == 0x0A || last == 0x2028
                }
                while !ends(lines[index]), context < ReaderPaginator.contextLines {
                    index += 1
                    context += 1
                }
                XCTAssertEqual(page.layoutEnd, NSMaxRange(lines[index].range), "page \(page.range)")
            }
            XCTAssertEqual(pages.contains { $0.layoutEnd > NSMaxRange($0.range) }, text === prose)
        }
    }

    // MARK: Text

    func testPagesNeverSplitAComposedCharacterSequence() {
        let cluster = "👨‍👩‍👧‍👦 e\u{301}a\u{308}\u{323} 🇯🇵 क्षि 👍🏽 "
        let text = CanvasText.body(String(repeating: cluster, count: 500))
        let characters = text.string as NSString
        for width in [40, 97, 320] as [CGFloat] {
            let pages = ReaderPaginator(text: text, size: CGSize(width: width, height: 300)).allPages
            ViewCoverage.assertPartition(pages, of: text, "\(width)")
            for page in pages {
                for boundary in [page.range.location, page.layoutEnd] where boundary < text.length {
                    XCTAssertEqual(characters.rangeOfComposedCharacterSequence(at: boundary).location, boundary,
                                   "width \(width): \(boundary) is inside a character")
                }
            }
        }
    }

    func testParagraphAndLineSeparatorsOfEveryKindEndLines() {
        // U+2029, CR LF and CR are paragraph breaks to TextKit as much as LF is.
        for separator in ["\u{2029}", "\r\n", "\r"] {
            let text = plain((0..<60).map { "Paragraph \($0)" }.joined(separator: separator))
            let characters = text.string as NSString
            let pages = ReaderPaginator(text: text, size: page(lines: 10)).allPages
            ViewCoverage.assertPartition(pages, of: text, separator.debugDescription)
            for page in pages.dropFirst() {
                XCTAssertTrue(characters.substring(from: page.range.location).hasPrefix("Paragraph"),
                              "\(separator.debugDescription): page at \(page.range.location) starts a paragraph")
            }
            XCTAssertEqual(pages.count, 6, separator.debugDescription)
        }
    }

    func testAContinuedParagraphKeepsTheDirectionItsStartGaveIt() throws {
        let latin = (0..<40).map { CanvasText.sentence(30, seed: $0) }.joined(separator: " ")
        let hebrew = String(repeating: "שלום עולם הספר ממשיך כאן. ", count: 200)
        // A right-to-left paragraph whose later pages open with Latin words, and the reverse.
        for (opening, rest, expected) in [("שלום עולם: ", latin, NSWritingDirection.rightToLeft),
                                          ("Hello world: ", hebrew, .leftToRight)] {
            let text = CanvasText.body(opening + rest)
            let paginator = ReaderPaginator(text: text, size: size)
            let continued = paginator.allPages.filter(\.continuesParagraph)
            XCTAssertGreaterThan(continued.count, 2)
            for page in continued {
                let style = try XCTUnwrap(paginator.text(for: page).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                XCTAssertEqual(style.baseWritingDirection, expected, "page at \(page.range.location)")
                XCTAssertEqual(style.paragraphSpacingBefore, 0)
            }
            let first = try XCTUnwrap(paginator.text(for: paginator.allPages[0]).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(first.baseWritingDirection, .natural, "the paragraph's own first page is left as written")
        }
        // An explicit direction is the author's and stays.
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .leftToRight
        let explicit = CanvasText.body("שלום עולם: " + latin, style: style)
        let paginator = ReaderPaginator(text: explicit, size: size)
        for page in paginator.allPages.filter(\.continuesParagraph) {
            let shown = try XCTUnwrap(paginator.text(for: page).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(shown.baseWritingDirection, .leftToRight)
        }
    }

    func testWritingDirectionSkipsNeutralsDigitsAndIsolatedRuns() {
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "١٢٣ ٤٥٦ hello"), .leftToRight, "Arabic-Indic digits are not strong")
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "(«…» 42) ابجد"), .rightToLeft)
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "\u{200F}abc"), .rightToLeft, "a right-to-left mark")
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "\u{200E}שלום"), .leftToRight, "a left-to-right mark")
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "\u{2066}\u{2067}שלום\u{2069} אבג\u{2069} abc"), .leftToRight, "nested isolates")
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "\u{2069}\u{2069} אבג"), .rightToLeft, "unmatched isolate ends are ignored")
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "\u{1E900}\u{1E901}"), .rightToLeft, "Adlam, outside the BMP")
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "ﭏ"), .rightToLeft, "a Hebrew presentation form")
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "ܫܠܡܐ"), .rightToLeft, "Syriac")
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "漢字 שלום"), .leftToRight)
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "😀 \u{FFFC} שלום"), .rightToLeft, "emoji and attachments are neutral")
        XCTAssertNil(ReaderPaginator.writingDirection(of: ""))
        XCTAssertNil(ReaderPaginator.writingDirection(of: "\u{2067}abc"), "an isolate that never ends hides its text")
    }
}

/// CoreText justifies a paragraph of up to 8,192 characters as a whole and a longer one line by
/// line, so a page's own text must stay on the side of that boundary its paragraph is on.
@MainActor final class ViewCoverageJustificationTests: XCTestCase {
    /// A justified, hyphenated paragraph of exactly `length` UTF-16 units, its break included.
    private func paragraph(length: Int, terminated: Bool = true, seed: Int = 0) -> NSAttributedString {
        var body = ""
        var index = seed
        while body.utf16.count < length { body += CanvasText.sentence(18 + index % 11, seed: index) + " "; index += 1 }
        let count = terminated ? length - 1 : length
        var characters = Array(body.utf16.prefix(count - 1))
        characters.append(0x2E)
        let string = String(utf16CodeUnits: characters, count: characters.count) + (terminated ? "\n" : "")
        XCTAssertEqual(string.utf16.count, length)
        return CanvasText.body(string, style: CanvasText.bodyStyle(alignment: .justified, hyphenates: true, indent: 24))
    }

    func testJustifiedParagraphsAroundTheWholeParagraphLimitLayOutLikeTheSection() {
        XCTAssertEqual(ReaderPaginator.wholeParagraphJustification, 8_192)
        for length in [8_190, 8_191, 8_192, 8_193, 8_194, 8_200] {
            for width in [237, 320, 431] as [CGFloat] {
                let text = ViewCoverage.joined([paragraph(length: length, seed: length % 7),
                                                CanvasText.body("A following paragraph. " + CanvasText.sentence(60, seed: 3))])
                let paginator = ReaderPaginator(text: text, size: CGSize(width: width, height: 500))
                let label = "a paragraph of \(length) at width \(width)"
                ViewCoverage.assertPartition(paginator.allPages, of: text, label)
                ViewCoverage.assertPagesLayOutLikeTheSection(paginator, label)
                XCTAssertGreaterThan(paginator.allPages.filter(\.continuesParagraph).count, 3, label)
            }
        }
    }

    func testAJustifiedParagraphEndingTheSectionAroundTheLimitLaysOutLikeTheSection() {
        // The section's last paragraph has no break after it to count.
        for length in [8_191, 8_192, 8_193] {
            let text = paragraph(length: length, terminated: false, seed: 2)
            let paginator = ReaderPaginator(text: text, size: CGSize(width: 320, height: 500))
            ViewCoverage.assertPartition(paginator.allPages, of: text, "\(length)")
            ViewCoverage.assertPagesLayOutLikeTheSection(paginator, "a final paragraph of \(length)")
        }
    }

    func testAHeadingAfterALongJustifiedParagraphIsNeverStrandedByItsMeasuredTail() {
        let style = CanvasText.bodyStyle(alignment: .justified, hyphenates: true, indent: 24)
        let long = (0..<70).map { CanvasText.sentence(30 + $0 % 9, seed: $0) }.joined(separator: " ")
        let text = NSMutableAttributedString(attributedString: CanvasText.body(long + "\n", style: style))
        XCTAssertGreaterThan(text.length, ReaderPaginator.wholeParagraphJustification)
        let headingStart = text.length
        text.append(ViewCoverage.marked(CanvasText.body("Following heading\n"), keep: true))
        let headingEnd = text.length
        text.append(CanvasText.body(CanvasText.sentence(100, seed: 11)))
        var measured = 0
        for width in [237, 320, 431] as [CGFloat] {
            for height in stride(from: CGFloat(380), through: 520, by: 7) {
                let pages = ReaderPaginator(text: text, size: CGSize(width: width, height: height)).allPages
                let label = "\(width) × \(height)"
                ViewCoverage.assertPartition(pages, of: text, label)
                measured += pages.filter { $0.measuredLineLengths != nil }.count
                if let orphan = pages.first(where: { NSMaxRange($0.range) == headingEnd }) {
                    XCTFail("\(label): the heading at \(headingStart) ends the page at \(orphan.range.location) without its body")
                }
                for page in pages where page.measuredLineLengths != nil {
                    XCTAssertEqual(page.measuredLineLengths?.reduce(0, +), page.range.length, label)
                    XCTAssertLessThanOrEqual(page.extent, height + 0.5, label)
                }
            }
        }
        XCTAssertGreaterThan(measured, 0, "the sweep includes measured tail pages")
    }
}
