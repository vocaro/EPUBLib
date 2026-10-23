import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing

/// "Cell selections, located passages and saved highlights use exact DOM-based character
/// ranges, including Unicode and inline markup. … Existing bookmarks naming a whole table still
/// resolve to that table; new cell ranges identify the selected characters."
final class TableCoverageTextMappingTests: XCTestCase {
    /// A caption, a header, inline markup, entities, a decomposed accent, an astral character,
    /// blocks, a list, a spanning cell and a nested table.
    private static let body = """
    <p id="before">Before table.</p>
    <table id="table"><caption id="cap">Sales by region</caption>
    <thead><tr><th>Region</th><th>Notes &amp; totals</th></tr></thead>
    <tbody><tr><td id="c1">Cafe\u{301} <b>bold</b> \u{1F600} end</td><td id="c2">x &lt; y<br/>second line</td></tr>
    <tr><td id="c3"><p>First para.</p><p>Second para.</p></td><td id="c4"><ul><li>one</li><li>two</li></ul></td></tr>
    <tr><td id="c5" colspan="2">Alpha</td></tr><tr><td id="c6">Beta</td><td id="c7"><table><tr><td id="n1">inner one</td><td>inner two</td></tr></table></td></tr></tbody></table>
    <p id="after">After table.</p>
    """

    private func fixture(_ body: String = TableCoverageTextMappingTests.body) throws -> (publication: EPUBPublication, section: SectionText, table: TableModel) {
        let publication = try TableCoverage.publication(body)
        let section = TableCoverage.section(of: publication)
        return (publication, section, try XCTUnwrap(TableCoverage.tables(in: section.string).first))
    }

    private func range(of quote: String, in section: SectionText, occurrence: Int = 0,
                       file: StaticString = #filePath, line: UInt = #line) throws -> (match: TextSearch.Match, range: ReaderTextRange) {
        let matches = TextSearch.matches(of: TextSearch.normalizeQuote(quote), in: section.document, locale: nil)
        XCTAssertGreaterThan(matches.count, occurrence, "\(quote) was not found", file: file, line: line)
        let match = try XCTUnwrap(matches.dropFirst(occurrence).first, file: file, line: line)
        return (match, SearchResultBuilder.renderedRange(of: match, in: section))
    }

    func testTheSectionHoldsOneCharacterPerRowAndTheRowsKnowTheirOffsets() throws {
        let (_, section, table) = try fixture()
        XCTAssertEqual(section.string.string, "Before table.\nSales by region\n\u{FFFC}\n\u{FFFC}\n\u{FFFC}\n\u{FFFC}\n\u{FFFC}\nAfter table.")
        XCTAssertEqual(table.sourceRowOffsets, [0: 30, 1: 32, 2: 34, 3: 36, 4: 38])
        XCTAssertEqual(section.tables().map(\.offset), [30, 32, 34, 36, 38])
        XCTAssertEqual(section.tables().map(\.row.row), [0, 1, 2, 3, 4])
        XCTAssertEqual(table.sourceOrder, section.document.element(id: "table")?.order)
        // Ids inside the table anchor at the table: its unit's first character.
        for id in ["table", "cap", "c1", "c5", "n1"] { XCTAssertEqual(section.anchors[id], 14, id) }
        XCTAssertEqual(section.anchors["after"], 40)
        BuilderHarness.assertMapRoundTrips(section)
    }

    /// An id inside a table anchors inside that table: no later than the row holding it.
    func testAnIdInsideALongTableAnchorsWithinTheTableAtOrBeforeItsRow() throws {
        let rows = (0..<300).map { "<tr id='r\($0)'><td id='c\($0)'>Row \($0)</td><td>Value</td></tr>" }.joined()
        let (_, section, table) = try fixture("<p>Before</p><table id='t'>\(rows)</table><p id='after'>After</p>")
        let start = try XCTUnwrap(section.anchors["t"])
        XCTAssertEqual(start, try TableCoverage.offset(ofRow: 0, in: table))
        for row in [0, 1, 150, 299] {
            for id in ["r\(row)", "c\(row)"] {
                let anchor = try XCTUnwrap(section.anchors[id], id)
                XCTAssertGreaterThanOrEqual(anchor, start, id)
                XCTAssertLessThanOrEqual(anchor, try TableCoverage.offset(ofRow: row, in: table), id)
            }
        }
        XCTAssertEqual(section.anchors["after"], try TableCoverage.offset(ofRow: 299, in: table) + 2)
    }

    func testEveryMappedCellCharacterNamesItsDOMPositionAndComesBackToItself() throws {
        let (_, section, table) = try fixture()
        var checked = 0
        for (index, cell) in table.cells.enumerated() {
            guard let mapping = cell.textMap else { continue }
            let rowOffset = try TableCoverage.offset(ofRow: cell.row, in: table)
            for span in mapping.map.spans where span.isExact {
                let node = section.document.nodes[span.node]
                for step in 0..<span.length {
                    let position = ReaderTextPosition(section: 0, offset: rowOffset,
                                                      tableCell: ReaderTablePosition(table: table.sourceOrder, cell: index, offset: span.location + step))
                    let start = try XCTUnwrap(section.domPosition(position))
                    XCTAssertTrue(start.node === node, "cell \(index) character \(span.location + step)")
                    XCTAssertEqual(start.offset, span.offset + step, "cell \(index) character \(span.location + step)")
                    XCTAssertEqual(section.renderedPosition(start), position, "cell \(index) character \(span.location + step)")
                    // A range ending after this character ends in the same text node, one unit on.
                    var after = position
                    after.tableCell?.offset += 1
                    let end = try XCTUnwrap(section.domPosition(after, isEnd: true))
                    XCTAssertTrue(end.node === node)
                    XCTAssertEqual(end.offset, span.offset + step + 1)
                    XCTAssertEqual(section.renderedPosition(end, isEnd: true), after, "cell \(index) character \(span.location + step) as an end")
                    // The source character is the rendered one.
                    XCTAssertEqual((node.text as NSString).character(at: span.offset + step), (cell.content.string as NSString).character(at: span.location + step))
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 90)
    }

    func testAMatchInACellIsExactlyItsCharactersThroughMarkupEntitiesAndUnicode() throws {
        let (_, section, table) = try fixture()
        let first = try TableCoverage.cell("Cafe\u{301} bold \u{1F600} end", in: table)
        for (quote, lower, upper) in [("Cafe\u{301}", 0, 5), ("e\u{301} bold", 3, 10), ("bold \u{1F600}", 6, 13), ("\u{1F600} end", 11, 17), ("d \u{1F600} e", 9, 15)] {
            let found = try range(of: quote, in: section).range
            XCTAssertEqual(found.start.tableCell, ReaderTablePosition(table: table.sourceOrder, cell: first, offset: lower), quote)
            XCTAssertEqual(found.end.tableCell, ReaderTablePosition(table: table.sourceOrder, cell: first, offset: upper), quote)
            XCTAssertEqual(found.start.offset, 32, quote)
            XCTAssertEqual(found.end.offset, 32, quote)
            XCTAssertEqual(section.tablePassage(found), quote, quote)
            XCTAssertTrue(SearchResultBuilder.isRendered(found), quote)
        }
        let entity = try range(of: "x < y", in: section).range
        XCTAssertEqual(entity.start.tableCell?.cell, try TableCoverage.cell("x < y second line", in: table))
        XCTAssertEqual(section.tablePassage(entity), "x < y")
        let header = try range(of: "Notes & totals", in: section).range
        XCTAssertEqual(header.start.offset, 30)
        XCTAssertEqual(section.tablePassage(header), "Notes & totals")
        // A list's generated marker is not the book's text: positions skip it, passages omit it.
        let item = try range(of: "two", in: section, occurrence: 0).range
        let list = try TableCoverage.cell("\u{2022} one \u{2022} two", in: table)
        XCTAssertEqual(item.start.tableCell, ReaderTablePosition(table: table.sourceOrder, cell: list, offset: 8))
        XCTAssertEqual(section.tablePassage(item), "two")
        let whole = ReaderTextRange(start: try TableCoverage.position(in: table, cell: "\u{2022} one \u{2022} two", offset: 0),
                                    end: try TableCoverage.position(in: table, cell: "\u{2022} one \u{2022} two", offset: 11))
        XCTAssertEqual(section.tablePassage(whole), "one\ntwo")
    }

    /// foliate-js search, which this ports, reads a document's text nodes as one string, so a
    /// quote can run from the end of one cell into the next. Both cells are then named.
    func testAMatchRunningFromOneCellIntoTheNextNamesBothCellsInOrder() throws {
        let (_, section, table) = try fixture()
        let found = try range(of: "AlphaBeta", in: section).range
        let alpha = try TableCoverage.cell("Alpha", in: table), beta = try TableCoverage.cell("Beta", in: table)
        XCTAssertEqual(found.start, ReaderTextPosition(section: 0, offset: 36, tableCell: ReaderTablePosition(table: table.sourceOrder, cell: alpha, offset: 0)))
        XCTAssertEqual(found.end, ReaderTextPosition(section: 0, offset: 38, tableCell: ReaderTablePosition(table: table.sourceOrder, cell: beta, offset: 4)))
        XCTAssertTrue(SearchResultBuilder.isRendered(found))
        XCTAssertEqual(section.tablePassage(found), "Alpha\tBeta", "cells of a passage are tab-separated, as a row reads")
        XCTAssertLessThan(found.start, found.end)
    }

    func testCellRangesRoundTripThroughTheirCFIs() throws {
        let (publication, section, _) = try fixture()
        let spine = try SpineCFIs(publication: publication)
        for quote in ["Region", "Cafe\u{301}", "bold \u{1F600}", "x < y", "Second para", "one", "Alpha", "AlphaBeta", "Beta"] {
            let (match, rendered) = try range(of: quote, in: section, occurrence: quote == "Region" ? 1 : 0)
            XCTAssertNotNil(rendered.start.tableCell, quote)
            let cfi = spine.cfi(spineIndex: 0, start: match.start, end: match.end, in: section.document)
            XCTAssertTrue(cfi.hasPrefix("epubcfi("), "\(quote): \(cfi)")
            let target = try XCTUnwrap(spine.resolve(cfi), quote)
            XCTAssertEqual(target.spineIndex, 0)
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: section.document), quote)
            let restored = ReaderTextRange(start: section.renderedPosition(resolved.start), end: section.renderedPosition(resolved.end, isEnd: true))
            XCTAssertEqual(restored, rendered, quote)
            XCTAssertEqual(section.tablePassage(restored), section.tablePassage(rendered), quote)
        }
    }

    /// A bookmark saved before cells had positions names the table element.
    func testACFINamingTheWholeTableResolvesToTheTableNotACell() throws {
        let (publication, section, table) = try fixture()
        let spine = try SpineCFIs(publication: publication)
        let element = try XCTUnwrap(section.document.element(id: "table"))
        // What a row's character maps to, as the old attachment-granular bookmarks were made.
        let unit = try XCTUnwrap(section.map.position(at: try TableCoverage.offset(ofRow: 2, in: table), in: section.document))
        XCTAssertTrue(unit.node === element)
        let unitEnd = try XCTUnwrap(section.map.endPosition(at: 39, in: section.document))
        XCTAssertGreaterThan(unitEnd.node.order, element.subtreeEnd, "the end of a range holding the table is past its subtree")
        let cfi = spine.cfi(spineIndex: 0, start: unit, end: unitEnd, in: section.document)
        let target = try XCTUnwrap(spine.resolve(cfi))
        let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: section.document))
        let start = section.renderedPosition(resolved.start), end = section.renderedPosition(resolved.end, isEnd: true)
        XCTAssertNil(start.tableCell)
        XCTAssertNil(end.tableCell)
        XCTAssertEqual(start.offset, 14, "the table's first character")
        XCTAssertEqual(end.offset, 39, "after its last row")
        XCTAssertNil(section.tablePassage(ReaderTextRange(start: start, end: end)), "no cell is named, so the ordinary passage is read")
        XCTAssertEqual(section.mappedText(in: start.offset..<end.offset).components(separatedBy: "\n").count, 6, "caption and five rows")
        // Positions on the table element or its caption, groups and rows name no cell either.
        XCTAssertEqual(section.renderedPosition(DOMPosition(element, 0)), ReaderTextPosition(section: 0, offset: 14))
        for node in section.document.nodes[element.order...element.subtreeEnd] where node.isElement && ["thead", "tbody", "tr", "caption"].contains(node.name) {
            guard node.parent === element || node.parent?.parent === element else { continue }
            let position = section.renderedPosition(DOMPosition(node, 0))
            XCTAssertNil(position.tableCell, node.name)
            XCTAssertTrue((14..<39).contains(position.offset), "\(node.name) is at \(position.offset)")
        }
    }

    /// Text in a table inside a cell is that inner table within its outer cell, and a place in
    /// the inner table's cell too, which tells the continuation that draws it (#544).
    func testTextInATableInsideACellIsThatInnerTableWithinItsOuterCell() throws {
        let (_, section, table) = try fixture()
        let outer = try TableCoverage.cell("inner one inner two", in: table)
        let inner = try XCTUnwrap(TableCoverage.tables(in: table.cells[outer].content).first)
        let cell = try TableCoverage.cell("inner one", in: inner)
        let found = try range(of: "inner one", in: section).range
        XCTAssertEqual(found.start.tableCell, ReaderTablePosition(table: table.sourceOrder, cell: outer, offset: 0,
            nested: ReaderTablePosition(table: inner.sourceOrder, cell: cell, offset: 0)))
        XCTAssertEqual(found.end.tableCell, ReaderTablePosition(table: table.sourceOrder, cell: outer, offset: 1,
            nested: ReaderTablePosition(table: inner.sourceOrder, cell: cell, offset: 9)), "the inner table is one character of its cell")
        XCTAssertEqual(inner.sourceOrder, section.document.element(id: "n1")?.parent?.parent?.order)
        XCTAssertEqual(section.tablePassage(found), "inner one", "the inner cell's words, not the inner table's (#718)")
        let back = try XCTUnwrap(section.domPosition(found.start))
        XCTAssertTrue(back.node.parent === section.document.element(id: "n1"), "the inner cell's text, not the inner table")
        XCTAssertEqual(back.offset, 0)
    }

    /// A match in a table nested in a cell, at any depth, is read where it is: its passage and
    /// its search context are the inner cell's words, and the DOM range it maps back to is the
    /// match's own, so a CFI made from it is the match's CFI and restores to it. Each read the
    /// outer cell's characters, where the nested table is one unit: the passage was the nested
    /// table's text, the context the outer cell's around it, and the range the nested table
    /// element (#718). The shapes are #715's: #544's two, two tables deep, and the narrow cells
    /// of #569 and #377, the first of them in no nested table.
    @MainActor func testAMatchInANestedTableIsReadAndMappedBackInItsOwnCell() throws {
        let words = ["Opening"] + (0..<60).map { "body\($0) words" } + ["Needle"]
        let tallRow = "<tr><td>" + words.map { "<p>\($0)</p>" }.joined() + "</td><td>y</td></tr>"
        let manyRows = words.map { "<tr><td>\($0)</td><td>y</td></tr>" }.joined()
        func nested(_ rows: String) -> String { "<table><tr><td><table>\(rows)</table></td><td>x</td></tr></table>" }
        let cases: [(label: String, body: String, font: CGFloat, quote: String, before: String, after: String, depth: Int)] = [
            ("a single tall inner row", nested(tallRow), 16, "y30 wo", "bod", "rds", 1),
            ("many inner rows", nested(manyRows), 16, "y30 wo", "bod", "rds", 1),
            ("a tall row two tables deep", "<table><tr><td>\(nested(tallRow))</td><td>w</td></tr></table>", 16, "y30 wo", "bod", "rds", 2),
            ("many rows two tables deep", "<table><tr><td>\(nested(manyRows))</td><td>w</td></tr></table>", 16, "y30 wo", "bod", "rds", 2),
            ("a list in a padded cell", TableNarrowCellTests.listInPaddedCell, 16, "the again", "a wraps ", " and.", 0),
            ("#377's nested cell", TableNarrowCellTests.nestedListInPaddedCell, 9, "the again", "a wraps ", " and.", 1),
        ]
        /// How many tables deep a place is nested in its cell.
        func depth(_ cell: ReaderTablePosition?) -> Int { cell?.nested.map { depth($0) + 1 } ?? 0 }
        for (label, body, font, quote, before, after, nesting) in cases {
            let publication = try TableCoverage.publication(body)
            let section = TableCoverage.section(of: publication, typography: .init(fontSize: font))
            let spine = try SpineCFIs(publication: publication)
            let matches = TextSearch.matches(of: TextSearch.normalizeQuote(quote), in: section.document, locale: nil)
            XCTAssertEqual(matches.count, 1, "\(label): \(quote)")
            let match = try XCTUnwrap(matches.first, label)
            let range = SearchResultBuilder.renderedRange(of: match, in: section)
            XCTAssertEqual(depth(range.start.tableCell), nesting, "\(label): the match is in the innermost table's cell")
            XCTAssertEqual(depth(range.end.tableCell), nesting, "\(label): and so is its end")
            XCTAssertEqual(section.tablePassage(range), quote, "\(label): the passage is the match's words")
            let context = SearchResultBuilder.context(of: range, in: section)
            // A cell's context before a list item's words also reads the item's generated
            // marker, which is no part of this (#735).
            XCTAssertTrue(context.before.hasSuffix(before), "\(label): the context before is the inner cell's, not \(context.before)")
            XCTAssertEqual(context.after, after, "\(label): and so is the context after")
            let dom = try XCTUnwrap(section.domRange(range), label)
            XCTAssertTrue(dom.start.node === match.start.node, "\(label): the range starts in the match's text node")
            XCTAssertEqual(dom.start.offset, match.start.offset, label)
            XCTAssertTrue(dom.end.node === match.end.node, "\(label): and ends in it")
            XCTAssertEqual(dom.end.offset, match.end.offset, label)
            let cfi = spine.cfi(spineIndex: 0, start: dom.start, end: dom.end, in: section.document)
            XCTAssertEqual(cfi, spine.cfi(spineIndex: 0, start: match.start, end: match.end, in: section.document),
                           "\(label): a CFI made from the rendered match is the match's own")
            let target = try XCTUnwrap(spine.resolve(cfi), label)
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: section.document), label)
            let restored = ReaderTextRange(start: section.renderedPosition(resolved.start), end: section.renderedPosition(resolved.end, isEnd: true))
            XCTAssertEqual(restored, range, "\(label): the CFI restores to the match")
        }
    }

    /// A caption is part of its table's unit: a match in one is not a cell position, and it
    /// still maps to rendered characters.
    func testAMatchInACaptionIsRenderedAndNamesNoCell() throws {
        let (_, section, _) = try fixture()
        let found = try range(of: "Sales by", in: section).range
        XCTAssertNil(found.start.tableCell)
        XCTAssertNil(found.end.tableCell)
        XCTAssertTrue(SearchResultBuilder.isRendered(found))
        XCTAssertEqual(found.start.offset, 14)
        XCTAssertTrue(section.mappedText(in: found.start.offset..<found.end.offset).hasPrefix("Sales by"))
    }

    func testAPassageFromProseIntoACellReadsTheProseThenTheCellsUpToItsEnd() throws {
        let (_, section, table) = try fixture()
        let start = ReaderTextPosition(section: 0, offset: 7)
        let end = try TableCoverage.position(in: table, cell: "Cafe\u{301} bold \u{1F600} end", offset: 5)
        let passage = try XCTUnwrap(section.tablePassage(ReaderTextRange(start: start, end: end)))
        let lines = passage.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["table.", "Sales by region", "Region\tNotes & totals\tCafe\u{301}"])
    }

    func testAPassageFromACellIntoProseReadsTheRestOfTheTableThenTheProse() throws {
        let (_, section, table) = try fixture()
        let start = try TableCoverage.position(in: table, cell: "Alpha", offset: 2)
        let end = ReaderTextPosition(section: 0, offset: 45)
        let passage = try XCTUnwrap(section.tablePassage(ReaderTextRange(start: start, end: end)))
        let lines = passage.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["pha\tBeta\tinner one\tinner two", "After"])
    }

    /// Blocks of a passage are a line break apart, as everywhere else a selection is read
    /// (`mappedText`): one between the prose and the table, not two.
    func testAPassageBetweenProseAndACellHasOneLineBreakBetweenItsBlocks() throws {
        let (_, section, table) = try fixture("<p>Before table.</p><table><tr><td>Alpha</td><td>Beta</td></tr></table><p>After table.</p>")
        XCTAssertEqual(section.string.string, "Before table.\n\u{FFFC}\nAfter table.")
        XCTAssertEqual(section.mappedText(in: 7..<21), "table.\nAlpha\tBeta\nAfter", "the same selection without cell endpoints")
        let into = ReaderTextRange(start: ReaderTextPosition(section: 0, offset: 7), end: try TableCoverage.position(in: table, cell: "Beta", offset: 2))
        XCTAssertEqual(section.tablePassage(into), "table.\nAlpha\tBe")
        let out = ReaderTextRange(start: try TableCoverage.position(in: table, cell: "Alpha", offset: 3), end: ReaderTextPosition(section: 0, offset: 21))
        XCTAssertEqual(section.tablePassage(out), "ha\tBeta\nAfter")
    }

    /// The same from a table into another, past a caption below the first and one above the
    /// second: the prose and the captions read as they do without cell endpoints, with the
    /// section's own breaks around them. A passage starting where the table does has none.
    func testAPassageAcrossTablesAndTheirCaptionsHasOneLineBreakBetweenItsBlocks() throws {
        let (_, section, _) = try fixture("""
        <table><tr><td>one</td><td>two</td></tr><caption style="caption-side: bottom">Below</caption></table><p>Between.</p>\
        <table><caption>Above</caption><tr><td>three</td><td>four</td></tr></table>
        """)
        let tables = TableCoverage.tables(in: section.string)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(section.string.string, "\u{FFFC}\nBelow\nBetween.\nAbove\n\u{FFFC}")
        let across = ReaderTextRange(start: try TableCoverage.position(in: tables[0], cell: "two", offset: 1),
                                     end: try TableCoverage.position(in: tables[1], cell: "three", offset: 2))
        XCTAssertEqual(section.tablePassage(across), "wo\nBelow\nBetween.\nAbove\nth")
        let atTable = ReaderTextRange(start: ReaderTextPosition(section: 0, offset: try TableCoverage.offset(ofRow: 0, in: tables[1])),
                                      end: try TableCoverage.position(in: tables[1], cell: "four", offset: 2))
        XCTAssertEqual(section.tablePassage(atTable), "three\tfo")
        let fromCaption = ReaderTextRange(start: ReaderTextPosition(section: 0, offset: 17), end: atTable.end)
        XCTAssertEqual(section.tablePassage(fromCaption), "Above\nthree\tfo")
    }

    /// A table of one column written footer first is a grid (`TableContent`), so its footer is
    /// read, located and selected after its body, as a wider table's is.
    func testAOneColumnTableWrittenFooterFirstIsReadAndLocatedBodyFirst() throws {
        let (_, section, table) = try fixture("""
        <p>Before</p><table><tfoot><tr><td>Source: survey</td></tr></tfoot><tbody><tr><td>Finding one</td></tr><tr><td>Finding two</td></tr></tbody></table>
        """)
        XCTAssertEqual(section.string.readerPlainText(), "Before\nFinding one\nFinding two\nSource: survey")
        let range = ReaderTextRange(start: try TableCoverage.position(in: table, cell: "Finding two", offset: 8),
                                    end: try TableCoverage.position(in: table, cell: "Source: survey", offset: 6))
        XCTAssertLessThan(range.start, range.end, "the footer is after the body it is drawn below")
        XCTAssertEqual(section.tablePassage(range), "two\tSource")
        let into = ReaderTextRange(start: ReaderTextPosition(section: 0, offset: 3), end: try TableCoverage.position(in: table, cell: "Finding one", offset: 7))
        XCTAssertEqual(section.tablePassage(into), "ore\nFinding")
        let found = try self.range(of: "Source", in: section).range
        XCTAssertEqual(found.start, try TableCoverage.position(in: table, cell: "Source: survey", offset: 0))
        XCTAssertEqual(found.start.offset, try TableCoverage.offset(ofRow: 2, in: table))
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testAPassageFromOneTableIntoAnotherReadsBothAndWhatLiesBetween() throws {
        let (_, section, _) = try fixture("""
        <table><tr><td>one</td><td>two</td></tr><tr><td>three</td><td>four</td></tr></table><p>Between the tables.</p>
        <table><caption>Second</caption><tr><td>five</td><td>six</td></tr><tr><td>seven</td><td>eight</td></tr></table>
        """)
        let tables = TableCoverage.tables(in: section.string)
        XCTAssertEqual(tables.count, 2)
        let start = try TableCoverage.position(in: tables[0], cell: "two", offset: 1)
        let end = try TableCoverage.position(in: tables[1], cell: "seven", offset: 3)
        XCTAssertLessThan(start, end)
        let passage = try XCTUnwrap(section.tablePassage(ReaderTextRange(start: start, end: end)))
        XCTAssertEqual(passage.components(separatedBy: "\n").filter { !$0.isEmpty }, ["wo\tthree\tfour", "Between the tables.", "Second", "five\tsix\tsev"])
    }

    func testCellsOfAPassageAreInRenderingOrderWhenTheFooterIsWrittenFirst() throws {
        let (_, section, table) = try fixture("""
        <table><tfoot><tr><td>Total</td><td>30</td></tr></tfoot><tbody><tr><td>Apples</td><td>10</td></tr><tr><td>Pears</td><td>20</td></tr></tbody></table>
        """)
        XCTAssertEqual(section.string.readerPlainText(), "Apples\t10\nPears\t20\nTotal\t30")
        let range = ReaderTextRange(start: try TableCoverage.position(in: table, cell: "Pears", offset: 0),
                                    end: try TableCoverage.position(in: table, cell: "Total", offset: 5))
        XCTAssertLessThan(range.start, range.end, "the footer is after the body it is drawn below")
        XCTAssertEqual(section.tablePassage(range), "Pears\t20\tTotal")
        // A match in the footer still names the footer's cell and row.
        let total = try self.range(of: "Total", in: section).range
        XCTAssertEqual(total.start, try TableCoverage.position(in: table, cell: "Total", offset: 0))
        XCTAssertEqual(total.start.offset, try TableCoverage.offset(ofRow: 2, in: table))
    }

    func testASpanningCellIsReadOnceWhereItStarts() throws {
        let (_, section, table) = try fixture("""
        <table><tr><td rowspan="2">Tall</td><td>a</td><td>b</td></tr><tr><td colspan="2">Wide</td></tr><tr><td>c</td><td>d</td><td>e</td></tr></table>
        """)
        XCTAssertEqual(table.cells.map(\.text), ["Tall", "a", "b", "Wide", "c", "d", "e"])
        let range = ReaderTextRange(start: try TableCoverage.position(in: table, cell: "Tall", offset: 0),
                                    end: try TableCoverage.position(in: table, cell: "e", offset: 1))
        XCTAssertEqual(section.tablePassage(range), "Tall\ta\tb\tWide\tc\td\te")
        let wide = try self.range(of: "Wide", in: section).range
        XCTAssertEqual(wide.start.offset, try TableCoverage.offset(ofRow: 1, in: table), "a cell's position is on the row it starts in")
        let tall = try self.range(of: "Tall", in: section).range
        XCTAssertEqual(tall.start.offset, try TableCoverage.offset(ofRow: 0, in: table))
    }

    func testPositionsThatNameNoCellOfTheSectionAreRefusedAndFallBackToTheRow() throws {
        let (_, section, table) = try fixture()
        let good = try TableCoverage.position(in: table, cell: "Alpha", offset: 2)
        XCTAssertEqual(section.tableCell(good)?.text, "Alpha")
        func cell(_ offset: Int, table id: Int, cell: Int, at characters: Int = 0) -> ReaderTextPosition {
            ReaderTextPosition(section: 0, offset: offset, tableCell: ReaderTablePosition(table: id, cell: cell, offset: characters))
        }
        XCTAssertNil(section.tableCell(ReaderTextPosition(section: 0, offset: 36)), "no cell named")
        XCTAssertNil(section.tableCell(cell(36, table: table.sourceOrder + 1, cell: 0)), "another table")
        XCTAssertNil(section.tableCell(cell(36, table: table.sourceOrder, cell: table.cells.count)), "past the last cell")
        XCTAssertNil(section.tableCell(cell(36, table: table.sourceOrder, cell: -1)))
        XCTAssertNil(section.tableCell(cell(3, table: table.sourceOrder, cell: 0)), "prose is not a row")
        XCTAssertNil(section.tableCell(cell(31, table: table.sourceOrder, cell: 0)), "the break between rows is not a row")
        XCTAssertNil(section.tableCell(cell(-1, table: table.sourceOrder, cell: 0)))
        XCTAssertNil(section.tableCell(cell(section.string.length, table: table.sourceOrder, cell: 0)))
        XCTAssertNil(section.tableCell(cell(Int.max, table: table.sourceOrder, cell: 0)))
        // A refused position reads as its row's character: the table.
        let stale = cell(36, table: table.sourceOrder + 1, cell: 0, at: 3)
        XCTAssertTrue(section.domPosition(stale)?.node === section.document.element(id: "table"))
        // An offset past the cell's text is its end, not a trap.
        let past = cell(36, table: table.sourceOrder, cell: try TableCoverage.cell("Alpha", in: table), at: 500)
        XCTAssertEqual(section.domPosition(past, isEnd: true)?.offset, 5)
        XCTAssertEqual(section.tablePassage(ReaderTextRange(start: good, end: past)), "pha")
        XCTAssertNil(section.tablePassage(ReaderTextRange(section: 0, 0..<40)), "no cell endpoint: the ordinary passage is used")
        XCTAssertNil(section.tablePassage(ReaderTextRange(start: good, end: cell(36, table: table.sourceOrder, cell: 99))), "a cell that is not there")
    }

    func testAnEmptyCellHasNoMapAndAPositionInItIsItsRow() throws {
        let (_, section, table) = try fixture("<p>Before</p><table><tr><td id='empty'/><td>full</td></tr></table>")
        XCTAssertNil(table.cells[0].textMap)
        let element = try XCTUnwrap(section.document.element(id: "empty"))
        let position = section.renderedPosition(DOMPosition(element, 0))
        XCTAssertNil(position.tableCell)
        XCTAssertEqual(position.offset, try TableCoverage.offset(ofRow: 0, in: table))
        let range = ReaderTextRange(start: ReaderTextPosition(section: 0, offset: 7, tableCell: ReaderTablePosition(table: table.sourceOrder, cell: 0, offset: 0)),
                                    end: try TableCoverage.position(in: table, cell: "full", offset: 2))
        XCTAssertEqual(section.tablePassage(range), "\tfu")
    }

    func testSearchContextAroundACellMatchIsThatCellsText() throws {
        let (_, section, _) = try fixture()
        let found = try range(of: "bold", in: section).range
        let context = SearchResultBuilder.context(of: found, in: section)
        XCTAssertEqual(context.before, "Cafe\u{301} ")
        XCTAssertEqual(context.after, " \u{1F600} end")
        let second = try range(of: "second line", in: section).range
        XCTAssertEqual(SearchResultBuilder.context(of: second, in: section).before, "", "a line break in the cell bounds the context")
    }

    func testEveryDocumentPositionInsideATableResolvesWithoutTrapping() throws {
        let (_, section, table) = try fixture()
        let element = try XCTUnwrap(section.document.element(id: "table"))
        var cells = 0
        for node in section.document.nodes[element.order...element.subtreeEnd] {
            for offset in node.isText ? Array(0...node.utf16Length) : [0] {
                for isEnd in [false, true] {
                    let position = section.renderedPosition(DOMPosition(node, offset), isEnd: isEnd)
                    XCTAssertGreaterThanOrEqual(position.offset, 14)
                    XCTAssertLessThanOrEqual(position.offset, 39)
                    if let cell = position.tableCell {
                        cells += 1
                        XCTAssertEqual(cell.table, table.sourceOrder)
                        XCTAssertTrue(table.cells.indices.contains(cell.cell))
                        XCTAssertTrue((0...table.cells[cell.cell].content.length).contains(cell.offset))
                        XCTAssertEqual(position.offset, try TableCoverage.offset(ofRow: table.cells[cell.cell].row, in: table))
                        XCTAssertNotNil(section.tableCell(position))
                    }
                }
            }
        }
        XCTAssertGreaterThan(cells, 150)
    }

    /// A search maps every match of a section to where it is drawn (up to 10,000 of them, on
    /// the main actor for the highlights). In a long table a match costs the same however long
    /// the table is: four times the rows and matches is about four times the work, not sixteen.
    /// Timed in thread CPU time as a ratio of best-of-several runs, with slack, so a busy machine does not decide it.
    func testMappingEveryMatchInALongTableGrowsInStepWithItsRows() throws {
        func seconds(rows: Int, runs: Int) throws -> TimeInterval {
            let markup = (0..<rows).map { "<tr><td>Row \($0)</td><td>Value \($0)</td></tr>" }.joined()
            let (_, section, _) = try fixture("<table>\(markup)</table>")
            let matches = TextSearch.matches(of: "Row", in: section.document, locale: nil)
            XCTAssertEqual(matches.count, rows)
            var best = TimeInterval.infinity
            for _ in 0..<runs {
                let start = TestCPUClock.seconds()
                var cells = 0
                for match in matches where SearchResultBuilder.renderedRange(of: match, in: section).start.tableCell != nil { cells += 1 }
                best = min(best, TestCPUClock.seconds() - start)
                XCTAssertEqual(cells, rows)
            }
            return best
        }
        let small = try seconds(rows: 400, runs: 3), large = try seconds(rows: 1600, runs: 2)
        XCTAssertLessThan(large, small * 8 + 0.1,
                          "1,600 rows took \(String(format: "%.3f", large)) s, \(String(format: "%.1f", large / small)) times the \(String(format: "%.3f", small)) s of 400 rows")
    }
}
