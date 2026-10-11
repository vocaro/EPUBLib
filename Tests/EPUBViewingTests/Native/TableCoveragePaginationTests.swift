import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tables in paginated flow: which rows share a page, continuations of oversized rows, and
/// finding the page of a precise cell position (`TableNavigation`).
@MainActor final class TableCoveragePaginationTests: XCTestCase {
    private let page = CGSize(width: 320, height: 300)

    private func filler(_ lines: Int) -> String { (0..<lines).map { "<p>Filler line \($0).</p>" }.joined() }

    /// The pages of `body` after `lines` lines of prose, and the page each row of its table is on.
    private func rows(after lines: Int, _ body: String) throws -> (pages: [ReaderPage], rowPages: [Int], table: TableModel, section: SectionText) {
        let section = try TableCoverage.section(filler(lines) + body + "<p>After the table.</p>", css: "p { margin: 0; }")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let paginator = ReaderPaginator(text: section.string, size: page)
        let pages = paginator.allPages
        let rowPages = try table.rows.indices.map { paginator.pageIndex(containing: try TableCoverage.offset(ofRow: $0, in: table)) }
        return (pages, rowPages, table, section)
    }

    // MARK: Keeping rows together

    /// "rows a rowspan joins, and the header, keep with the next row and share a page when they
    /// fit": however much prose comes first, the header is never the last thing on a page.
    func testTheHeaderSharesAPageWithTheFirstBodyRowWhereverTheTableStarts() throws {
        let body = "<table><thead><tr><th>Name</th><th>Value</th></tr></thead><tbody>"
            + (0..<6).map { "<tr><td>Row \($0)</td><td>\($0)</td></tr>" }.joined() + "</tbody></table>"
        var moved = 0, started = Set<Int>()
        for lines in 0..<30 {
            let (pages, rowPages, table, _) = try rows(after: lines, body)
            XCTAssertEqual(rowPages[0], rowPages[1], "after \(lines) lines the header is on page \(rowPages[0]) and the first row on page \(rowPages[1])")
            XCTAssertEqual(rowPages, rowPages.sorted(), "\(lines) lines")
            XCTAssertTrue(pages.allSatisfy { $0.height <= page.height + 0.5 }, "\(lines) lines")
            started.insert(rowPages[0])
            // The header opens a page that the prose before it did not fill: it was moved.
            if rowPages[0] > 0, pages[rowPages[0]].range.location == (try TableCoverage.offset(ofRow: 0, in: table)) { moved += 1 }
        }
        XCTAssertGreaterThan(started.count, 1, "the sweep crossed a page boundary")
        XCTAssertGreaterThan(moved, 0, "at some length the header had to move to stay with its row")
    }

    func testRowsJoinedByARowspanShareAPageWhereverTheTableStarts() throws {
        let body = "<table><tr><td>lead</td><td>in</td></tr><tr><td rowspan='3'>Joined</td><td>a</td></tr><tr><td>b</td></tr><tr><td>c</td></tr>"
            + (0..<4).map { "<tr><td>Row \($0)</td><td>\($0)</td></tr>" }.joined() + "</table>"
        var started = Set<Int>(), moved = 0
        for lines in 0..<30 {
            let (pages, rowPages, table, _) = try rows(after: lines, body)
            XCTAssertEqual(table.groups.first { $0.contains(1) }, 1..<4)
            XCTAssertEqual(Set(rowPages[1..<4]).count, 1, "after \(lines) lines the joined rows are on pages \(rowPages[1..<4])")
            XCTAssertTrue(pages.allSatisfy { $0.height <= page.height + 0.5 }, "\(lines) lines")
            started.insert(rowPages[1])
            if rowPages[1] > rowPages[0] { moved += 1 }
        }
        XCTAssertGreaterThan(started.count, 1)
        XCTAssertGreaterThan(moved, 0, "at some length the joined rows left the row before them behind")
    }

    func testATopCaptionSharesAPageWithTheHeaderAndTheFirstRow() throws {
        let body = "<table><caption>Table 7. Yields by season</caption><thead><tr><th>Season</th><th>Yield</th></tr></thead><tbody>"
            + (0..<4).map { "<tr><td>Row \($0)</td><td>\($0)</td></tr>" }.joined() + "</tbody></table>"
        var started = Set<Int>()
        for lines in 0..<30 {
            let (pages, rowPages, _, section) = try rows(after: lines, body)
            let caption = (section.string.string as NSString).range(of: "Table 7.").location
            let captionPage = try XCTUnwrap(pages.firstIndex { NSLocationInRange(caption, $0.range) })
            XCTAssertEqual(captionPage, rowPages[0], "after \(lines) lines the caption is on page \(captionPage) and the header on \(rowPages[0])")
            XCTAssertEqual(rowPages[0], rowPages[1], "\(lines) lines")
            started.insert(captionPage)
        }
        XCTAssertGreaterThan(started.count, 1)
    }

    /// When the kept rows cannot share a page they break between rows instead.
    func testAHeaderGroupTallerThanAPageStillBreaksBetweenRowsAndEnds() throws {
        let tall = (0..<10).map { "line \($0)" }.joined(separator: "<br/>")
        let section = try TableCoverage.section("""
        <table><thead><tr><th>\(tall)</th><th>A</th></tr><tr><th>\(tall)</th><th>B</th></tr></thead>
        <tbody><tr><td>one</td><td>two</td></tr><tr><td>three</td><td>four</td></tr></tbody></table>
        """)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(table.groups.first, 0..<2)
        let layout = table.layout(available: page.width, viewportHeight: page.height)
        XCTAssertGreaterThan(layout.height(ofRow: 0) + layout.height(ofRow: 1), page.height)
        XCTAssertLessThanOrEqual(layout.height(ofRow: 0), page.height)
        let pages = ReaderPaginator(text: section.string, size: page).allPages
        XCTAssertEqual(pages.first?.range, NSRange(location: 0, length: 2), "the header rows part")
        let second = try XCTUnwrap(pages.first { NSLocationInRange(2, $0.range) })
        XCTAssertTrue(NSLocationInRange(4, second.range), "the second header row still keeps with the first body row")
        XCTAssertEqual(pages.last?.range.upperBound, section.string.length)
        XCTAssertEqual(pages.map(\.range.length).reduce(0, +), section.string.length)
        XCTAssertTrue(pages.allSatisfy { $0.height <= page.height + 0.5 })
    }

    /// CSS Fragmentation: `break-before: page` on a table starts it on a new page, and
    /// `break-inside: avoid` keeps its rows on one page when they fit one.
    func testCSSPageBreaksOnATableStartItOnANewPageAndKeepItWholeWhenItFits() throws {
        let css = "p { margin: 0; } .whole { page-break-inside: avoid; } .fresh { page-break-before: always; }"
        var moved = 0
        for lines in 0..<20 {
            let section = try TableCoverage.section(filler(lines) + """
            <table class="whole"><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr><tr><td>e</td><td>f</td></tr><tr><td>g</td><td>h</td></tr></table>
            <p>Between.</p><table class="fresh"><tr><td>x</td><td>y</td></tr></table>
            """, css: css)
            let tables = TableCoverage.tables(in: section.string)
            let paginator = ReaderPaginator(text: section.string, size: page)
            let pages = paginator.allPages
            let whole = try tables[0].rows.indices.map { paginator.pageIndex(containing: try TableCoverage.offset(ofRow: $0, in: tables[0])) }
            XCTAssertEqual(Set(whole).count, 1, "after \(lines) lines the table's rows are on pages \(whole)")
            if whole[0] > 0, pages[whole[0]].range.location == (try TableCoverage.offset(ofRow: 0, in: tables[0])) { moved += 1 }
            let fresh = try TableCoverage.offset(ofRow: 0, in: tables[1])
            XCTAssertEqual(pages[paginator.pageIndex(containing: fresh)].range.location, fresh, "\(lines) lines: the second table opens its page")
            XCTAssertGreaterThan(paginator.pageIndex(containing: fresh), paginator.pageIndex(containing: fresh - 2))
        }
        XCTAssertGreaterThan(moved, 0, "at some length the whole table had to move")
    }

    /// `TableLayout.make`: "Try a modest scale reduction before continuing tall rows across pages."
    func testARowALittleTallerThanThePageShrinksItsTableToFitRatherThanContinue() throws {
        let words = (0..<300).map { "word\($0)" }.joined(separator: " ")
        let table = try TableCoverage.table("<table><tr><td>\(words)</td><td>x</td></tr><tr><td>a</td><td>b</td></tr></table>", typography: .init(fontSize: 17))
        let size = CGSize(width: 390, height: 700)
        let unbounded = table.layout(available: size.width, viewportHeight: 100_000)
        XCTAssertEqual(unbounded.scale, 1)
        XCTAssertGreaterThan(unbounded.tallestRow, size.height)
        let fitted = table.layout(available: size.width, viewportHeight: size.height)
        XCTAssertLessThan(fitted.scale, 1)
        XCTAssertGreaterThanOrEqual(fitted.scale, TableModel.minimumScale)
        XCTAssertLessThanOrEqual(fitted.tallestRow, size.height)
        XCTAssertEqual(fitted.fragments(ofRow: 0, maximumHeight: size.height).count, 1, "one page, not a continuation")
        // The smaller text uses the line's whole width.
        XCTAssertEqual(fitted.lineWidth * fitted.scale, size.width, accuracy: 0.01)
        XCTAssertEqual(fitted.cellText[0].lines.map(\.characters.length).reduce(0, +), table.cells[0].content.length)
    }

    func testEveryRowOfALongTableIsOnExactlyOnePageInOrder() throws {
        let rows = (0..<120).map { "<tr><td>Row \($0)</td><td>Value \($0)<br/>second line</td></tr>" }.joined()
        let section = try TableCoverage.section("<table border='1'><thead><tr><th>Row</th><th>Value</th></tr></thead><tbody>\(rows)</tbody></table>")
        let paginator = ReaderPaginator(text: section.string, size: page)
        let pages = paginator.allPages
        XCTAssertGreaterThan(pages.count, 10)
        var next = 0
        for (index, page) in pages.enumerated() {
            XCTAssertEqual(page.range.location, next, "page \(index) starts where the last ended")
            XCTAssertEqual(page.range.location % 2, 0, "at a row")
            XCTAssertLessThanOrEqual(page.height, self.page.height + 0.5)
            XCTAssertEqual(page.tableFragments.map(\.offset), Array(stride(from: page.range.location, to: page.range.upperBound, by: 2)), "a fragment per row on the page")
            XCTAssertTrue(page.tableFragments.allSatisfy { $0.attachment.fragment?.fitScale == 1 })
            next = page.range.upperBound
        }
        XCTAssertEqual(pages.last?.range.upperBound, section.string.length)
        // The header is not repeated: it is a row like any other, on the first page only.
        XCTAssertEqual(pages.filter { $0.tableFragments.contains { $0.attachment.row == 0 } }.count, 1)
    }

    // MARK: Continuations

    /// "Continuations retain original source offsets: several pages can report the same row range."
    func testContinuationsOfARowShareItsSourceRangeAndDifferByTheirLines() throws {
        let words = (0..<500).map { "word\($0)" }
        let section = try TableCoverage.section("<p>Before</p><table><tr><td>\(words.joined(separator: " "))</td><td>x</td></tr><tr><td>next</td><td>row</td></tr></table><p>After</p>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let offset = try TableCoverage.offset(ofRow: 0, in: table)
        let paginator = ReaderPaginator(text: section.string, size: page)
        let pages = paginator.allPages
        let continued = pages.filter { $0.tableFragments.contains { $0.offset == offset } }
        XCTAssertGreaterThan(continued.count, 3)
        XCTAssertEqual(Set(continued.dropFirst().dropLast().map(\.range)).count, 1, "the pages wholly inside the row report the same range")
        XCTAssertEqual(continued[1].range.location, offset, "the row's own character, on every one of them")
        XCTAssertLessThanOrEqual(continued[1].range.length, 2, "and at most the break after it")
        XCTAssertEqual(Set(continued.map { $0.tableFragments.first { $0.offset == offset }?.attachment.fragment?.top }).count, continued.count,
                       "and are told apart by their slice")
        XCTAssertNotEqual(continued[1], continued[2])
        // The section's own characters are untouched; each page's text draws its own slice.
        XCTAssertEqual(paginator.text.string, section.string.string)
        for page in continued {
            let text = paginator.text(for: page)
            let fragment = try XCTUnwrap(page.tableFragments.first { $0.offset == offset })
            XCTAssertTrue(text.attribute(.attachment, at: offset - page.range.location, effectiveRange: nil) as? TableRowAttachment === fragment.attachment)
        }
        // Read page by page, the row's words come once each and in order.
        let spoken = continued.compactMap { $0.tableFragments.first { $0.offset == offset }?.attachment.textEquivalent }
        XCTAssertEqual(spoken.joined(separator: " ").split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("word") }.map(String.init), words)
        XCTAssertEqual(spoken.filter { $0.contains("x") && !$0.contains("word") || $0.hasSuffix("\tx") }.count, 1, "the short cell is read once")
        // The plain offset finds the row's first page, whichever continuation is wanted.
        XCTAssertEqual(paginator.pageIndex(containing: offset), pages.firstIndex(of: continued[0]))
    }

    /// "VoiceOver reads each continuation's words, completing a word once if character wrapping
    /// splits it between pages."
    func testAWordSplitBetweenPagesByCharacterWrappingIsReadOnceWhole() throws {
        let long = (0..<30).map { "unbreakable\($0)" + String(repeating: "x", count: 150) }
        let section = try TableCoverage.section("<table><tr><td>\(long.joined(separator: " "))</td><td>y</td></tr></table>", typography: .init(fontSize: 28))
        let size = CGSize(width: 220, height: 180)
        let pages = ReaderPaginator(text: section.string, size: size).allPages
        XCTAssertGreaterThan(pages.count, long.count / 2, "the words run over many pages")
        let spoken = pages.flatMap(\.tableFragments).map(\.attachment.textEquivalent)
        let words = spoken.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.hasPrefix("unbreakable") }
        XCTAssertEqual(words, long, "each word whole, once, on the page where it starts")
        XCTAssertTrue(spoken.contains { !$0.contains("unbreakable") }, "a page inside a word does not repeat it")
    }

    // MARK: Finding the page of a cell position

    func testAPreciseCellPositionIsOnThePageOfTheContinuationThatDrawsIt() throws {
        let words = (0..<500).map { "word\($0)" }
        let section = try TableCoverage.section("<p>Before</p><table><tr><td>\(words.joined(separator: " "))</td><td>side</td></tr><tr><td>next</td><td>row</td></tr></table><p>After</p>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let offset = try TableCoverage.offset(ofRow: 0, in: table)
        let paginator = ReaderPaginator(text: section.string, size: page)
        let pages = paginator.allPages
        let content = table.cells[0].content.string as NSString
        var found: [Int] = []
        for word in stride(from: 0, to: 500, by: 23) {
            let location = content.range(of: "word\(word) ").location
            let position = ReaderTextPosition(section: 0, offset: offset, tableCell: ReaderTablePosition(table: table.sourceOrder, cell: 0, offset: location))
            let index = paginator.pageIndex(containing: position)
            let fragment = try XCTUnwrap(pages[index].tableFragments.first { $0.offset == offset }, "word\(word)")
            XCTAssertTrue(fragment.attachment.textEquivalent.split(whereSeparator: \.isWhitespace).contains("word\(word)"),
                          "page \(index) does not read word\(word)")
            found.append(index)
        }
        XCTAssertEqual(found, found.sorted(), "later characters are never on earlier pages")
        XCTAssertGreaterThan(Set(found).count, 3)
        // The end of the cell's text is on its last continuation.
        let end = ReaderTextPosition(section: 0, offset: offset, tableCell: ReaderTablePosition(table: table.sourceOrder, cell: 0, offset: content.length))
        XCTAssertEqual(paginator.pageIndex(containing: end), pages.lastIndex { $0.tableFragments.contains { $0.offset == offset } })
        // The short cell beside it is centred in the row: on whichever page draws it.
        let side = paginator.pageIndex(containing: try TableCoverage.position(in: table, cell: "side", offset: 2))
        XCTAssertTrue(pages[side].tableFragments.contains { $0.offset == offset && $0.attachment.textEquivalent.hasSuffix("side") })
        XCTAssertEqual(pages.filter { $0.tableFragments.contains { $0.offset == offset && $0.attachment.textEquivalent.hasSuffix("side") } }.count, 1)
        let next = try TableCoverage.position(in: table, cell: "next", offset: 1)
        XCTAssertEqual(paginator.pageIndex(containing: next), paginator.pageIndex(containing: try TableCoverage.offset(ofRow: 1, in: table)))
    }

    func testACellPositionThatNamesNothingDrawnFallsBackToItsRowsFirstPage() throws {
        let words = (0..<300).map { "word\($0)" }.joined(separator: " ")
        let section = try TableCoverage.section("<p>Before</p><table><tr><td>\(words)</td><td>side</td></tr></table><p>After</p>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let offset = try TableCoverage.offset(ofRow: 0, in: table)
        let paginator = ReaderPaginator(text: section.string, size: page)
        let first = paginator.pageIndex(containing: offset)
        func index(table id: Int, cell: Int, at characters: Int) -> Int {
            paginator.pageIndex(containing: ReaderTextPosition(section: 0, offset: offset, tableCell: ReaderTablePosition(table: id, cell: cell, offset: characters)))
        }
        XCTAssertEqual(index(table: table.sourceOrder + 7, cell: 0, at: 900), first, "another table")
        XCTAssertEqual(index(table: table.sourceOrder, cell: 44, at: 0), first, "no such cell")
        XCTAssertEqual(index(table: table.sourceOrder, cell: 0, at: 1_000_000), first, "past the cell's text")
        XCTAssertEqual(index(table: table.sourceOrder, cell: 0, at: -5), first)
        XCTAssertEqual(paginator.pageIndex(containing: ReaderTextPosition(section: 0, offset: 3)), paginator.pageIndex(containing: 3), "prose is found by its offset")
        XCTAssertEqual(paginator.pageIndex(containing: ReaderTextPosition(section: 0, offset: section.string.length - 1)), paginator.allPages.count - 1)
    }

    /// A spanning cell's later lines are drawn by the rows below its first: a position in them
    /// is on the page of the row that draws them, though it names the cell's first row.
    func testAPositionLateInASpanningCellIsOnThePageOfTheRowThatDrawsItsLine() throws {
        let words = (0..<260).map { "span\($0)" }
        let rows = (1..<40).map { "<tr><td>row \($0)</td></tr>" }.joined()
        let section = try TableCoverage.section("<table border='1'><tr><td rowspan='40'>\(words.joined(separator: " "))</td><td>row 0</td></tr>\(rows)</table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let paginator = ReaderPaginator(text: section.string, size: page)
        let pages = paginator.allPages
        XCTAssertGreaterThan(pages.count, 2)
        let content = table.cells[0].content.string as NSString
        var found: [Int] = []
        for word in [0, 60, 130, 200, 259] {
            let location = content.range(of: "span\(word)").location
            let index = paginator.pageIndex(containing: ReaderTextPosition(section: 0, offset: 0,
                tableCell: ReaderTablePosition(table: table.sourceOrder, cell: 0, offset: location)))
            let spoken = pages[index].tableFragments.map(\.attachment.textEquivalent).joined(separator: " ")
            XCTAssertTrue(spoken.split(whereSeparator: \.isWhitespace).contains("span\(word)"), "page \(index) does not read span\(word)")
            found.append(index)
        }
        XCTAssertGreaterThan(found.last ?? 0, found.first ?? 0, "the cell's end is not on the page of its start")
        XCTAssertGreaterThan(found.last ?? 0, paginator.pageIndex(containing: 0), "nor on the page its first row is on")
        XCTAssertEqual(found, found.sorted())
    }

    // MARK: Interaction geometry

    /// "Visible cells have native text interaction surfaces aligned to their drawn glyphs":
    /// each surface covers exactly the lines its row slice draws, where it draws them.
    func testInteractionCellsCoverTheLinesTheirSliceDrawsAtItsScale() throws {
        let words = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let table = try TableCoverage.table("<table border='1' cellpadding='6'><tr><td>\(words)</td><td>side</td></tr><tr><td>next</td><td>row</td></tr></table>")
        for width: CGFloat in [150, 320] {
            let layout = table.layout(available: width, viewportHeight: page.height)
            var covered = IndexSet()
            let slices = layout.fragments(ofRow: 0, maximumHeight: page.height - 1)
            XCTAssertGreaterThan(slices.count, 1)
            for slice in slices {
                let row = TableRowAttachment(table: table, row: 0, fragment: slice, layout: layout)
                let size = CGSize(width: width, height: row.height(width: width, viewportHeight: page.height))
                let cells = row.interactionCells(size: size, viewportHeight: page.height)
                XCTAssertEqual(cells.map(\.cell), slice.cells.map(\.cell))
                for cell in cells {
                    let scale = layout.scale * slice.fitScale
                    XCTAssertEqual(cell.scale, scale)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.01, dy: -0.01).contains(cell.frame), "inside its row")
                    XCTAssertEqual(cell.width, layout.contentFrames[cell.cell].width)
                    XCTAssertEqual(cell.frame.width, layout.contentFrames[cell.cell].width * scale, accuracy: 0.01)
                    XCTAssertEqual(cell.frame.minX, (layout.originX + layout.contentFrames[cell.cell].minX) * scale, accuracy: 0.01)
                    let lines = try XCTUnwrap(slice.cells.first { $0.cell == cell.cell }).lines
                    let text = layout.cellText[cell.cell]
                    XCTAssertEqual(cell.characters.location, text.lines[lines.lowerBound].characters.location)
                    XCTAssertEqual(cell.characters.upperBound, text.lines[lines.upperBound - 1].characters.upperBound)
                    // The first shown line's top is where the row draws it.
                    let drawn = (layout.contentFrames[cell.cell].minY + text.lines[lines.lowerBound].frame.minY - slice.top) * scale
                    XCTAssertEqual(cell.frame.minY, drawn, accuracy: 0.01)
                    XCTAssertEqual(cell.frame.minY - cell.textOrigin.y, text.lines[lines.lowerBound].frame.minY * scale, accuracy: 0.01)
                    XCTAssertTrue(cell.text === text.interactionText)
                    if cell.cell == 0 { covered.insert(integersIn: cell.characters.location..<cell.characters.upperBound) }
                }
            }
            XCTAssertEqual(covered, IndexSet(integersIn: 0..<table.cells[0].content.length), "the slices' surfaces cover the cell's text once over")
        }
    }

    func testAWholeRowsInteractionCellsAreItsNonEmptyCells() throws {
        let table = try TableCoverage.table("<table><tr><td>one</td><td></td><td>three</td></tr></table>")
        let row = TableRowAttachment(table: table, row: 0)
        let size = CGSize(width: 320, height: row.height(width: 320, viewportHeight: 600))
        let cells = row.interactionCells(size: size, viewportHeight: 600)
        XCTAssertEqual(cells.map(\.cell), [0, 2], "an empty cell has no text to select")
        XCTAssertEqual(cells.map { $0.text.string }, ["one", "three"])
        XCTAssertEqual(cells.map(\.characters), [NSRange(location: 0, length: 3), NSRange(location: 0, length: 5)])
        XCTAssertTrue(row.interactionCells(size: .zero, viewportHeight: 600).isEmpty)
    }
}
