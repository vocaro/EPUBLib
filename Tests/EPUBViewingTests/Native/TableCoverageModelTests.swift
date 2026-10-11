import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The table model against HTML §4.9.12 ("forming a table") and CSS 2.2 §17.2, built by the real
/// pipeline rather than a styled fixture.
final class TableCoverageModelTests: XCTestCase {
    private func grid(_ body: String, css: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> [[String]] {
        TableCoverage.grid(try TableCoverage.table(body, css: css, file: file, line: line))
    }

    private func plain(_ body: String, css: String = "") throws -> String {
        try TableCoverage.section(body, css: css).string.readerPlainText()
    }

    // MARK: Slots and spans

    func testSpanningCellsTakeTheirSlotsAndLaterCellsTheFirstFreeColumn() throws {
        let table = try TableCoverage.table("""
        <table><tr><td rowspan="2">A</td><td colspan="2">B</td><td>C</td></tr>
        <tr><td>D</td><td rowspan="2" colspan="2">E</td></tr>
        <tr><td colspan="2">F</td></tr><tr><td>G</td><td>H</td><td>I</td><td>J</td></tr></table>
        """)
        XCTAssertEqual(table.columnCount, 4)
        XCTAssertEqual(TableCoverage.grid(table), [["A@0/2", "B@1x2", "C@3"], ["D@1", "E@2x2/2"], ["F@0x2"], ["G@0", "H@1", "I@2", "J@3"]])
        // Rows 0-2 are chained by the two rowspans; the last row stands alone.
        XCTAssertEqual(table.groups, [0..<3, 3..<4])
        XCTAssertEqual(table.keepsWithNext, [true, true, false, false])
        // A spanning cell is listed in every row it covers, once in the cells.
        let spanning = try TableCoverage.cell("E", in: table)
        XCTAssertTrue(table.rowCells[1].contains(spanning) && table.rowCells[2].contains(spanning))
        XCTAssertFalse(table.rowCells[0].contains(spanning) || table.rowCells[3].contains(spanning))
        XCTAssertEqual(table.cells.filter { $0.text == "E" }.count, 1)
        let layout = table.layout(available: 400, viewportHeight: 600)
        let frame = layout.cellFrames[spanning]
        XCTAssertEqual(frame.minX, layout.cellFrames[try TableCoverage.cell("I", in: table)].minX, accuracy: 0.01)
        XCTAssertEqual(frame.maxX, layout.cellFrames[try TableCoverage.cell("J", in: table)].maxX, accuracy: 0.01)
        XCTAssertEqual(frame.minY, layout.cellFrames[try TableCoverage.cell("D", in: table)].minY, accuracy: 0.01)
        XCTAssertEqual(frame.maxY, layout.cellFrames[try TableCoverage.cell("F", in: table)].maxY, accuracy: 0.01)
    }

    /// HTML §4.9.11: `colspan` and `rowspan` are read with the rules for parsing non-negative
    /// integers (§2.3.4.2): leading ASCII whitespace is skipped and the digits are read up to
    /// the first character that is not one, so `" 2"`, `"2 "`, `"2px"` and `"2.9"` are all 2.
    func testSpanAttributesAreReadAsHTMLNonNegativeIntegers() throws {
        for value in [" 2", "2 ", "\t2\n", "2px", "2.9", "+2", "02"] {
            let columns = try TableCoverage.table("<table><tr><td colspan='\(value)'>A</td></tr><tr><td>B</td><td>C</td></tr></table>")
            XCTAssertEqual(TableCoverage.grid(columns).first, ["A@0x2"], "colspan=\(value.debugDescription)")
            let rows = try TableCoverage.table("<table><tr><td rowspan='\(value)'>A</td><td>B</td></tr><tr><td>C</td></tr></table>")
            XCTAssertEqual(TableCoverage.grid(rows), [["A@0/2", "B@1"], ["C@1"]], "rowspan=\(value.debugDescription)")
        }
    }

    /// HTML §4.9.11: a `colspan` that fails to parse or is zero is 1; so is a `rowspan` that
    /// fails to parse. Negative numbers fail to parse as non-negative integers.
    func testInvalidZeroAndNegativeSpansAreOne() throws {
        for value in ["0", "-2", "", "two", "%", "-", "+", "0x2", ".5"] {
            let columns = try TableCoverage.table("<table><tr><td colspan='\(value)'>A</td><td>X</td></tr><tr><td>B</td><td>C</td></tr></table>")
            XCTAssertEqual(TableCoverage.grid(columns), [["A@0", "X@1"], ["B@0", "C@1"]], "colspan=\(value.debugDescription)")
        }
        for value in ["-2", "", "two", "%", "-"] {
            let rows = try TableCoverage.table("<table><tr><td rowspan='\(value)'>A</td><td>X</td></tr><tr><td>B</td><td>C</td></tr></table>")
            XCTAssertEqual(TableCoverage.grid(rows), [["A@0", "X@1"], ["B@0", "C@1"]], "rowspan=\(value.debugDescription)")
        }
    }

    /// HTML §4.9.12 caps `colspan` at 1000, keeping the cell. The reader lays out fewer columns
    /// than that; a title row written with a large `colspan` to span "everything" still has to
    /// show its text.
    func testACellSpanningMoreColumnsThanTheReaderLaysOutKeepsItsText() throws {
        for span in [TableModel.maximumColumns + 1, 1000, 100_000] {
            let text = try plain("<table><tr><td colspan='\(span)'>Quarterly totals</td></tr><tr><td>North</td><td>South</td></tr></table>")
            XCTAssertTrue(text.contains("Quarterly totals"), "colspan=\(span) rendered \(text.debugDescription)")
            XCTAssertTrue(text.contains("North") && text.contains("South"), "colspan=\(span)")
        }
    }

    func testASpanUpToTheColumnBoundKeepsItsCellOverTheWholeTable() throws {
        let section = try TableCoverage.section("<table><tr><td colspan='\(TableModel.maximumColumns)'>Title</td></tr><tr><td>B</td><td>C</td></tr></table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(table.cells.map(\.text), ["Title", "B", "C"])
        XCTAssertGreaterThanOrEqual(table.cells[0].columnSpan, 2)
        XCTAssertNil(section.report.unsupportedElements["table"], "nothing was left out")
        let layout = table.layout(available: 320, viewportHeight: 600)
        XCTAssertTrue(layout.columnWidths.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertLessThanOrEqual(layout.cellFrames[0].minX, layout.cellFrames[1].minX + 0.01)
        XCTAssertGreaterThanOrEqual(layout.cellFrames[0].maxX, layout.cellFrames[2].maxX - 0.01)
    }

    /// CSS Tables 3 §3.3.2 (track merging): consecutive columns "spanned by the exact same set of
    /// cells" that no `col` declares "must be merged into one single track for the purpose of
    /// computing the layout", as browsers always did. So `colspan="100"` on a two-column table's
    /// title row (a common way to say "all columns") lays out like `colspan="3"`: at most one
    /// more border spacing than `colspan="2"`. Here every phantom column adds its own.
    func testColumnsNoCellStartsInAddNoWidth() throws {
        func width(_ span: Int) throws -> CGFloat {
            try TableCoverage.table("<table><tr><td colspan='\(span)'>T</td></tr><tr><td>North</td><td>South</td></tr></table>")
                .constraints.minimumTableWidth
        }
        let exact = try width(2)
        // The 2-point user-agent spacing, once, for the one merged track.
        XCTAssertEqual(try width(3), exact, accuracy: 2.01)
        XCTAssertEqual(try width(100), exact, accuracy: 2.01)
        XCTAssertEqual(try width(200), exact, accuracy: 2.01)
    }

    /// HTML §4.9.12 caps `rowspan` at 65534; a row group ends its cells' spans (the algorithm for
    /// ending a row group), as browsers render.
    func testAnEnormousRowspanEndsWithItsRowGroup() throws {
        for value in ["65534", "65535", "100000", "99999999999999999999999999"] {
            let table = try TableCoverage.table("""
            <table><tbody><tr><td rowspan="\(value)">A</td><td>B</td></tr><tr><td>C</td></tr></tbody>
            <tbody><tr><td>D</td><td>E</td></tr></tbody></table>
            """)
            XCTAssertEqual(table.rows.count, 3, "rowspan=\(value)")
            XCTAssertEqual(TableCoverage.grid(table).last, ["D@0", "E@1"], "rowspan=\(value): the next group starts afresh")
            XCTAssertEqual(table.cells.map(\.text).sorted(), ["A", "B", "C", "D", "E"], "rowspan=\(value)")
            XCTAssertLessThanOrEqual(table.cells[0].rowSpan, 2, "rowspan=\(value)")
        }
    }

    func testARowspanDoesNotCrossFromTheHeaderIntoTheBodyOrPastTheLastRow() throws {
        let table = try TableCoverage.table("""
        <table><thead><tr><th rowspan="3">H</th><th>I</th></tr></thead>
        <tbody><tr><td>a</td><td>b</td></tr><tr><td rowspan="5">c</td><td>d</td></tr></tbody></table>
        """)
        XCTAssertEqual(TableCoverage.grid(table), [["H@0", "I@1"], ["a@0", "b@1"], ["c@0", "d@1"]])
        XCTAssertEqual(table.groups, [0..<1, 1..<2, 2..<3])
    }

    /// HTML §4.9.12 step 13 assigns a cell its slots even where another cell already covers
    /// one (a table model error): both stay, overlapping.
    func testOverlappingSpansKeepBothCells() throws {
        let table = try TableCoverage.table("""
        <table><tr><td>A</td><td rowspan="2">B</td></tr><tr><td colspan="2">C</td><td>D</td></tr></table>
        """)
        XCTAssertEqual(TableCoverage.grid(table), [["A@0", "B@1/2"], ["C@0x2", "D@2"]])
        XCTAssertEqual(table.columnCount, 3)
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.cellFrames.count, 4)
        XCTAssertTrue(layout.cellFrames.allSatisfy { $0.width > 0 && $0.height > 0 })
        XCTAssertTrue(layout.cellFrames[try TableCoverage.cell("B", in: table)].intersects(layout.cellFrames[try TableCoverage.cell("C", in: table)]))
    }

    func testRowsShorterThanTheTableLeaveTheirLastSlotsEmpty() throws {
        let table = try TableCoverage.table("""
        <table><tr><td>A</td></tr><tr><td>B</td><td>C</td><td>D</td></tr><tr><td>E</td><td>F</td></tr></table>
        """)
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(TableCoverage.grid(table), [["A@0"], ["B@0", "C@1", "D@2"], ["E@0", "F@1"]])
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.cellFrames[0].width, layout.columnWidths[0], accuracy: 0.01, "a short row's cell does not stretch")
        XCTAssertEqual(layout.rowHeights.count, 3)
        let attachments = table.rows.indices.map { TableRowAttachment(table: table, row: $0) }
        XCTAssertEqual(attachments.map(\.textEquivalent), ["A", "B\tC\tD", "E\tF"])
    }

    /// HTML §4.9.12, processing rows: a `tr` with no cells still advances the current row.
    func testARowWithoutCellsKeepsItsPlace() throws {
        let section = try TableCoverage.section("""
        <table><tr><td>A</td><td>B</td></tr><tr></tr><tr><td>C</td><td>D</td></tr></table>
        """)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(TableCoverage.grid(table), [["A@0", "B@1"], [], ["C@0", "D@1"]])
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.rowHeights[1], 0)
        XCTAssertEqual(layout.fragments(ofRow: 1, maximumHeight: 599).count, 1)
        XCTAssertEqual(TableRowAttachment(table: table, row: 1).textEquivalent, "")
        XCTAssertEqual((0..<3).map(layout.height(ofRow:)).reduce(0, +), layout.size.height, accuracy: 0.01)
    }

    @MainActor func testATableWithAnEmptyRowPaginatesToItsEnd() throws {
        let rows = (0..<40).map { $0 % 5 == 2 ? "<tr></tr>" : "<tr><td>Row \($0)</td><td>Value</td></tr>" }.joined()
        let section = try TableCoverage.section("<table>\(rows)</table>", css: "table { border-collapse: collapse; }")
        let pages = ReaderPaginator(text: section.string, size: CGSize(width: 300, height: 200)).allPages
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.last?.range.upperBound, section.string.length)
        XCTAssertEqual(pages.map(\.range.length).reduce(0, +), section.string.length, "every row is on exactly one page")
    }

    func testTablesWithoutCellsRenderOnlyTheirOtherContent() throws {
        XCTAssertEqual(try plain("<p>x</p><table></table><p>y</p>"), "x\ny")
        XCTAssertEqual(try plain("<p>x</p><table><tr></tr><tr/></table><p>y</p>"), "x\ny")
        XCTAssertEqual(try plain("<p>x</p><table><tbody></tbody><thead/><tfoot/></table><p>y</p>"), "x\ny")
        XCTAssertEqual(try plain("<p>x</p><table><caption>Only a caption</caption></table><p>y</p>"), "x\nOnly a caption\ny")
        XCTAssertEqual(try plain("<p>x</p><table><colgroup><col/><col/></colgroup></table><p>y</p>"), "x\ny")
    }

    // MARK: Row groups

    /// CSS 2.2 §17.2: the header group is "always displayed before all other rows and row groups"
    /// and the footer group after them, wherever they are written. HTML 4 required `tfoot` before
    /// `tbody`, so older books write it first.
    func testTheHeaderIsFirstAndTheFooterLastWhereverTheyAreWritten() throws {
        let table = try TableCoverage.table("""
        <table><tfoot><tr><td>F1</td><td>F2</td></tr></tfoot>
        <tbody><tr><td>a</td><td>b</td></tr></tbody><tr><td>loose1</td><td>loose2</td></tr>
        <tbody><tr><td>c</td><td>d</td></tr></tbody>
        <thead><tr><th>H1</th><th>H2</th></tr></thead></table>
        """)
        XCTAssertEqual(TableCoverage.grid(table), [["H1@0", "H2@1"], ["a@0", "b@1"], ["loose1@0", "loose2@1"], ["c@0", "d@1"], ["F1@0", "F2@1"]])
        XCTAssertEqual(table.rows.map(\.isHeader), [true, false, false, false, false])
        XCTAssertEqual(table.keepsWithNext, [true, false, false, false, false])
        // Cells are in rendering order, which is the order a selection across them reads.
        XCTAssertEqual(table.cells.map(\.text), ["H1", "H2", "a", "b", "loose1", "loose2", "c", "d", "F1", "F2"])
    }

    /// CSS 2.2 §17.2: only the first `table-header-group` is a header; "the others are treated as
    /// if they had 'display: table-row-group'".
    func testASecondHeaderGroupIsAnOrdinaryRowGroupInPlace() throws {
        let table = try TableCoverage.table("""
        <table><thead><tr><th>H1</th><th>H2</th></tr></thead><tbody><tr><td>a</td><td>b</td></tr></tbody>
        <thead><tr><th>I1</th><th>I2</th></tr></thead><tbody><tr><td>c</td><td>d</td></tr></tbody></table>
        """)
        XCTAssertEqual(table.cells.map(\.text), ["H1", "H2", "a", "b", "I1", "I2", "c", "d"])
        XCTAssertEqual(table.rows.map(\.isHeader), [true, false, false, false])
        XCTAssertTrue(table.cells[4].isHeader, "still a th")
    }

    func testAHeaderOfSeveralRowsKeepsTogetherAndWithTheFirstBodyRow() throws {
        let table = try TableCoverage.table("""
        <table><thead><tr><th>A</th><th>B</th></tr><tr><th>C</th><th>D</th></tr><tr><th>E</th><th>F</th></tr></thead>
        <tbody><tr><td>1</td><td>2</td></tr><tr><td>3</td><td>4</td></tr></tbody></table>
        """)
        XCTAssertEqual(table.groups, [0..<3, 3..<4, 4..<5])
        XCTAssertEqual(table.keepsWithNext, [true, true, true, false, false])
    }

    func testATableOfOnlyAHeaderIsATableWhoseLastRowKeepsWithNothing() throws {
        let table = try TableCoverage.table("<table><thead><tr><th>H1</th><th>H2</th></tr><tr><th>H3</th><th>H4</th></tr></thead></table>")
        XCTAssertEqual(table.rows.map(\.isHeader), [true, true])
        XCTAssertEqual(table.keepsWithNext, [true, false], "nothing follows the last row to keep it with")
    }

    func testHeaderCellsAreThElementsWhereverTheyStand() throws {
        let table = try TableCoverage.table("""
        <table><tr><th scope="col" id="h1">Name</th><th scope="col" abbr="Qty">Quantity</th></tr>
        <tr><th scope="row">Apples</th><td headers="h1">12</td></tr></table>
        """)
        XCTAssertEqual(table.cells.map(\.isHeader), [true, true, true, false])
        XCTAssertEqual(table.rows.map(\.isHeader), [false, false], "a row of th outside thead is not a header group")
        XCTAssertEqual(table.keepsWithNext, [false, false])
        let font = try XCTUnwrap(table.cells[2].content.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        #if os(macOS)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        #else
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #endif
    }

    // MARK: Hidden parts

    func testHiddenRowsCellsAndGroupsLeaveTheGrid() throws {
        let css = ".gone { display: none; }"
        XCTAssertEqual(try grid("<table><tr><td>A</td><td class='gone'>hidden</td><td>C</td></tr><tr><td>D</td><td>E</td></tr></table>", css: css),
                       [["A@0", "C@1"], ["D@0", "E@1"]])
        XCTAssertEqual(try grid("<table><tr><td>A</td><td>B</td></tr><tr class='gone'><td>x</td><td>y</td></tr><tr><td>C</td><td>D</td></tr></table>", css: css),
                       [["A@0", "B@1"], ["C@0", "D@1"]])
        XCTAssertEqual(try grid("<table><tbody class='gone'><tr><td>x</td><td>y</td></tr></tbody><tbody><tr><td>C</td><td>D</td></tr></tbody></table>", css: css),
                       [["C@0", "D@1"]])
        // A rowspan counts the rows that are shown.
        let spanning = try TableCoverage.table("""
        <table><tr><td rowspan="3">A</td><td>B</td></tr><tr class="gone"><td>x</td></tr><tr><td>C</td></tr><tr><td>D</td></tr></table>
        """, css: css)
        XCTAssertEqual(spanning.rows.count, 3)
        XCTAssertEqual(spanning.cells.map(\.text), ["A", "B", "C", "D"])
        XCTAssertEqual(try plain("<table><caption class='gone'>Hidden caption</caption><tr><td>A</td><td>B</td></tr></table>", css: css), "A\tB")
    }

    // MARK: Content outside the row and cell structure

    /// CSS 2.2 §17.2.1 (anonymous table objects): a `table-cell` whose parent is not a row gets an
    /// anonymous row, and other content in a table or row gets an anonymous row and cell. XHTML is
    /// parsed as XML, which performs no tree repair, so such markup reaches the renderer as
    /// written and browsers show its content.
    func testContentInATableOutsideItsRowsAndCellsIsStillShown() throws {
        let cellInTable = try plain("<table><tr><td>A</td><td>B</td></tr><td>Cell without a row</td></table>")
        XCTAssertTrue(cellInTable.contains("Cell without a row"), cellInTable.debugDescription)
        let cellInGroup = try plain("<table><tbody><tr><td>A</td><td>B</td></tr><td>Cell in a group</td></tbody></table>")
        XCTAssertTrue(cellInGroup.contains("Cell in a group"), cellInGroup.debugDescription)
        let blockInTable = try plain("<table><tr><td>A</td><td>B</td></tr><p>Paragraph in the table</p></table>")
        XCTAssertTrue(blockInTable.contains("Paragraph in the table"), blockInTable.debugDescription)
        let blockInRow = try plain("<table><tr><td>A</td><td>B</td><p>Paragraph in the row</p></tr></table>")
        XCTAssertTrue(blockInRow.contains("Paragraph in the row"), blockInRow.debugDescription)
    }

    func testAOneColumnTableKeepsContentOutsideItsRowsAndCells() throws {
        XCTAssertEqual(try plain("<table><tr><td>A</td></tr><td>Cell without a row</td></table>"), "A\nCell without a row")
        XCTAssertEqual(try plain("<table><tr><td>A</td></tr><p>Paragraph in the table</p></table>"), "A\nParagraph in the table")
    }

    // MARK: Captions

    /// CSS 2.2 §17.2: "All elements with 'display: table-caption' must be rendered", and §17.4
    /// places every caption box in the table wrapper.
    func testEveryCaptionIsShown() throws {
        let text = try plain("<table><caption>Table 4</caption><caption>Source: field notes</caption><tr><td>A</td><td>B</td></tr></table>")
        XCTAssertTrue(text.contains("Table 4"), text.debugDescription)
        XCTAssertTrue(text.contains("Source: field notes"), text.debugDescription)
    }

    func testACaptionAfterTheRowsIsStillAboveThem() throws {
        XCTAssertEqual(try plain("<table><tr><td>A</td><td>B</td></tr><caption>Written last</caption></table>"), "Written last\nA\tB")
    }

    func testAnEmptyCaptionAddsNoParagraph() throws {
        let section = try TableCoverage.section("<table><caption>  </caption><tr><td>A</td><td>B</td></tr></table>")
        XCTAssertEqual(section.string.string, "\u{FFFC}")
    }

    // MARK: Columns

    func testColumnWidthsComeFromColAndColgroupWithTheirSpans() throws {
        let table = try TableCoverage.table("""
        <table><colgroup><col span="2" width="40"/><col width="25%"/></colgroup><colgroup span="2" width="30"/><col style="width: 3em"/>
        <tr><td>a</td><td>b</td><td>c</td><td>d</td><td>e</td><td>f</td></tr></table>
        """)
        XCTAssertEqual(table.columns, [.points(40), .points(40), .percent(25), .points(30), .points(30), .points(48)])
        let widths = table.constraints
        XCTAssertEqual(widths.fixed, [40, 40, nil, 30, 30, 48])
        XCTAssertEqual(widths.percent, [nil, nil, 25, nil, nil, nil])
        let layout = table.layout(available: 1000, viewportHeight: 600)
        XCTAssertEqual(layout.columnWidths[0], 40, accuracy: 0.01)
        XCTAssertEqual(layout.columnWidths[1], 40, accuracy: 0.01)
        XCTAssertEqual(layout.columnWidths[3], 30, accuracy: 0.01)
        XCTAssertEqual(layout.columnWidths[5], 48, accuracy: 0.01)
    }

    func testAColInheritsItsGroupsWidthAndAnInvalidSpanIsOne() throws {
        let table = try TableCoverage.table("""
        <table><colgroup width="60"><col/><col width="20"/><col span="0"/><col span="-3"/><col span="x"/></colgroup>
        <tr><td>a</td><td>b</td><td>c</td><td>d</td><td>e</td></tr></table>
        """)
        XCTAssertEqual(table.columns, [.points(60), .points(20), .points(60), .points(60), .points(60)])
    }

    /// HTML §4.9.3: a `colgroup` or `col` `span` is at most 1000.
    func testAColumnSpanIsBoundedAndColumnsPastTheCellsAreIgnored() throws {
        let table = try TableCoverage.table("""
        <table><col span="100000" width="15"/><colgroup span="100000" width="20"/><tr><td>a</td><td>b</td><td>c</td></tr></table>
        """)
        XCTAssertEqual(table.columns.count, 2000)
        XCTAssertEqual(table.columnCount, 3, "columns come from the cells")
        XCTAssertEqual(table.constraints.fixed, [15, 15, 15])
        XCTAssertEqual(table.layout(available: 400, viewportHeight: 600).columnWidths.count, 3)
    }

    // MARK: Bounds

    func testCellsPastTheColumnBoundAreLeftOutAndDisclosed() throws {
        let cells = (0..<(TableModel.maximumColumns + 40)).map { "<td>c\($0)</td>" }.joined()
        let section = try TableCoverage.section("<table><tr>\(cells)</tr><tr><td>next</td><td>row</td></tr></table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(table.columnCount, TableModel.maximumColumns)
        XCTAssertEqual(table.cells.count, TableModel.maximumColumns + 2, "the rows after a long one are still read")
        XCTAssertEqual(section.report.unsupportedElements["table"], 1, "what was left out is disclosed")
        XCTAssertNotNil(NativeDisclosure.text(for: section.report))
        let layout = table.layout(available: 320, viewportHeight: 600)
        XCTAssertGreaterThanOrEqual(layout.scale, TableModel.minimumScale)
        XCTAssertTrue(layout.columnWidths.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    func testATableWithinTheBoundsDisclosesNothing() throws {
        let cells = (0..<TableModel.maximumColumns).map { "<td>c\($0)</td>" }.joined()
        let section = try TableCoverage.section("<table><tr>\(cells)</tr></table>")
        XCTAssertEqual(TableCoverage.tables(in: section.string).first?.cells.count, TableModel.maximumColumns)
        XCTAssertNil(section.report.unsupportedElements["table"])
    }

    func testCellsPastTheCellBoundAreDisclosedAndTheTextAfterTheTableIsKept() throws {
        let columns = 100, rows = TableModel.maximumCells / columns + 3
        let row = "<tr>" + String(repeating: "<td>x</td>", count: columns) + "</tr>"
        let section = try TableCoverage.section("<table>" + String(repeating: row, count: rows) + "</table><p>After the table</p>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(table.cells.count, TableModel.maximumCells)
        XCTAssertEqual(section.report.unsupportedElements["table"], 1)
        XCTAssertTrue(section.string.string.hasSuffix("After the table"))
        XCTAssertEqual(table.rowCells.count, table.rows.count)
    }

    // MARK: Where tables stand

    func testTablesInsideOtherBlocksAreStillTables() throws {
        let inner = "<table><tr><td>one</td><td>two</td></tr><tr><td>three</td><td>four</td></tr></table>"
        for (name, body, css) in [
            ("list item", "<ul><li>Item \(inner)</li></ul>", ""),
            ("blockquote", "<blockquote>\(inner)</blockquote>", ""),
            ("figure", "<figure>\(inner)<figcaption>Figure 1</figcaption></figure>", ""),
            ("float", "<div class='f'>\(inner)</div><p>Beside</p>", ".f { float: left; width: 50%; }"),
            ("flex column", "<div class='x'>\(inner)</div>", ".x { display: flex; flex-direction: column; }"),
            ("definition", "<dl><dt>Term</dt><dd>\(inner)</dd></dl>", ""),
            ("paragraph", "<p>Lead in \(inner) and on.</p>", ""),
            ("floated table", inner.replacingOccurrences(of: "<table>", with: "<table align='left'>") + "<p>Beside</p>", ""),
            ("section in a cell-less wrapper", "<section><div><div>\(inner)</div></div></section>", ""),
        ] {
            let section = try TableCoverage.section(body, css: css)
            let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first, name)
            XCTAssertEqual(TableCoverage.grid(table), [["one@0", "two@1"], ["three@0", "four@1"]], name)
            XCTAssertTrue(section.string.readerPlainText().contains("one\ttwo\nthree\tfour"), "\(name): \(section.string.readerPlainText().debugDescription)")
            BuilderHarness.assertMapRoundTrips(section)
        }
    }

    func testAdjacentTablesAreSeparateTablesWithTheirOwnRowsAndOrder() throws {
        let section = try TableCoverage.section("""
        <table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table><table><tr><td>a</td><td>b</td></tr></table>
        """)
        XCTAssertEqual(section.string.string, "\u{FFFC}\n\u{FFFC}\n\u{FFFC}")
        let tables = TableCoverage.tables(in: section.string)
        XCTAssertEqual(tables.count, 2)
        XCTAssertLessThan(tables[0].sourceOrder, tables[1].sourceOrder)
        XCTAssertEqual(tables[0].sourceRowOffsets, [0: 0, 1: 2])
        XCTAssertEqual(tables[1].sourceRowOffsets, [0: 4])
        XCTAssertEqual(section.tables().map { $0.row.table === tables[0] }, [true, true, false])
        XCTAssertEqual(section.map.spans.count, 2, "a unit each")
        XCTAssertEqual(section.map.spans.map(\.location), [0, 4])
        // A table is the section's whole content, first and last character alike.
        let alone = try TableCoverage.section("<table><tr><td>a</td><td>b</td></tr></table>")
        XCTAssertEqual(alone.string.string, "\u{FFFC}")
        XCTAssertEqual(alone.map.length, 1)
        BuilderHarness.assertMapRoundTrips(section)
        BuilderHarness.assertMapRoundTrips(alone)
    }

    func testATableInAFootnoteIsKeptInTheNotesContent() throws {
        let section = try TableCoverage.section("""
        <p>Text<a epub:type="noteref" href="#n">1</a>.</p>
        <aside id="n" epub:type="footnote"><p>See:</p><table><tr><td>one</td><td>two</td></tr><tr><td>three</td><td>four</td></tr></table></aside>
        """)
        XCTAssertTrue(TableCoverage.tables(in: section.string).isEmpty, "a footnote is not in the flow")
        let note = try XCTUnwrap(section.notes["n"])
        let table = try XCTUnwrap(TableCoverage.tables(in: note).first)
        XCTAssertEqual(TableCoverage.grid(table), [["one@0", "two@1"], ["three@0", "four@1"]])
        XCTAssertEqual(note.readerPlainText(), "See:\none\ttwo\nthree\tfour")
        XCTAssertGreaterThan(table.layout(available: 280, viewportHeight: 400).size.height, 0)
    }

    func testATableTwoLevelsInsideACellIsRowsInsideRows() throws {
        let table = try TableCoverage.table("""
        <table><tr><td>outer</td><td><table><tr><td>middle</td><td><table><tr><td>inner a</td><td>inner b</td></tr></table></td></tr></table></td></tr></table>
        """)
        XCTAssertEqual(table.cells.count, 2)
        let middle = try XCTUnwrap(TableCoverage.tables(in: table.cells[1].content).first)
        XCTAssertEqual(middle.cells.first?.text, "middle")
        let inner = try XCTUnwrap(TableCoverage.tables(in: middle.cells[1].content).first)
        XCTAssertEqual(inner.cells.map(\.text), ["inner a", "inner b"])
        XCTAssertEqual(table.cells[1].text, "middle inner a inner b", "what VoiceOver reads for the outer cell")
        // The outer column is at least as wide as the narrowest the tables inside it can be drawn.
        XCTAssertGreaterThanOrEqual(table.constraints.minimum[1], middle.constraints.minimumTableWidth * TableModel.minimumScale)
        XCTAssertGreaterThanOrEqual(middle.constraints.minimum[1], inner.constraints.minimumTableWidth * TableModel.minimumScale)
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertGreaterThan(layout.rowHeights[0], 0)
    }

    /// Rendering nests at most eight levels; past that a cell is shown as its plain text. The
    /// words of separate cells are still separate words.
    func testTablesNestedPastTheRenderingDepthKeepTheirCellsApart() throws {
        var markup = "<table><tr><td>leaf</td><td>twig</td></tr></table>"
        for level in 0..<10 { markup = "<table><tr><td>\(markup)</td><td>level\(level)</td></tr></table>" }
        let text = try plain(markup)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for word in ["leaf", "twig"] + (0..<10).map({ "level\($0)" }) {
            XCTAssertTrue(words.contains(word), "\(word) is not a word of \(text.debugDescription)")
        }
    }

    func testDeeplyNestedTablesBuildAndLayOutWithoutTrapping() throws {
        var markup = "<table><tr><td>leaf</td><td>twig</td></tr></table>"
        for level in 0..<40 { markup = "<table><tr><td>\(markup)</td><td>level\(level)</td></tr></table>" }
        let section = try TableCoverage.section(markup)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let layout = table.layout(available: 320, viewportHeight: 500)
        XCTAssertTrue(layout.size.width.isFinite && layout.size.height.isFinite)
        XCTAssertTrue(section.string.readerPlainText().contains("level39"))
    }

    // MARK: One column

    /// "One-column tables, which books use as callout boxes, flow as ordinary text."
    func testOneColumnShapesFlowAsOrdinaryMappedText() throws {
        for (name, body, expected) in [
            ("one cell", "<table><tr><td>Tip: file early.</td></tr></table>", "Tip: file early."),
            ("header row", "<table><thead><tr><th>Note</th></tr></thead><tbody><tr><td>Body one</td></tr><tr><td>Body two</td></tr></tbody></table>",
             "Note\nBody one\nBody two"),
            ("caption", "<table><caption>Box 1</caption><tr><td>Inside</td></tr></table>", "Box 1\nInside"),
            ("blocks", "<table><tr><td><h3>Heading</h3><p>First.</p><p>Second.</p></td></tr></table>", "Heading\nFirst.\nSecond."),
            ("hidden second cell", "<table><tr><td>Shown</td><td style='display: none'>Hidden</td></tr></table>", "Shown"),
            ("rowspan", "<table><tr><td rowspan='2'>Tall</td></tr><tr></tr><tr><td>Next</td></tr></table>", "Tall\nNext"),
        ] {
            let section = try TableCoverage.section("<p>Before</p>\(body)<p>After</p>")
            XCTAssertTrue(TableCoverage.tables(in: section.string).isEmpty, "\(name) is drawn as a table")
            XCTAssertEqual(section.string.readerPlainText(), "Before\n\(expected)\nAfter", name)
            XCTAssertFalse(section.string.string.contains("\u{FFFC}"), name)
            BuilderHarness.assertMapRoundTrips(section)
        }
    }

    func testAOneColumnTableHoldingAWiderTableDrawsOnlyTheInnerOne() throws {
        let section = try TableCoverage.section("""
        <table><tr><td>Callout</td></tr><tr><td><table><tr><td>a</td><td>b</td></tr></table></td></tr></table>
        """)
        let tables = TableCoverage.tables(in: section.string)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.cells.map(\.text), ["a", "b"])
        XCTAssertEqual(section.string.readerPlainText(), "Callout\na\tb")
    }

    /// CSS 2.2 §17.2: the footer group is displayed after all other rows. A callout written the
    /// HTML 4 way, `tfoot` before `tbody`, reads body first in a browser.
    func testAOneColumnTableWithItsFooterWrittenFirstReadsTheBodyFirst() throws {
        let text = try plain("<table><tfoot><tr><td>Source: survey</td></tr></tfoot><tbody><tr><td>Finding one</td></tr><tr><td>Finding two</td></tr></tbody></table>")
        XCTAssertEqual(text, "Finding one\nFinding two\nSource: survey")
    }

    func testEveryRowSpanningAllColumnsStillShowsItsText() throws {
        let section = try TableCoverage.section("<table><tr><td colspan='2'>Callout title</td></tr><tr><td colspan='2'>Callout body</td></tr></table>")
        XCTAssertEqual(section.string.readerPlainText(), "Callout title\nCallout body")
    }

    // MARK: Elements that are not HTML tables

    /// Whatever is drawn for CSS tables made of other elements, their cells stay in reading
    /// order and nothing is lost.
    func testCSSTableDisplayOnOtherElementsKeepsEveryCellInReadingOrder() throws {
        let css = ".t { display: table; } .r { display: table-row; } .c { display: table-cell; }"
        let section = try TableCoverage.section("""
        <div class="t"><div class="r"><div class="c">A</div><div class="c">B</div></div><div class="r"><div class="c">C</div><div class="c">D</div></div></div>
        """, css: css)
        XCTAssertEqual(section.string.readerPlainText().split(whereSeparator: \.isWhitespace).map(String.init), ["A", "B", "C", "D"])
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testATableInAnotherNamespaceIsNotAnHTMLTable() throws {
        let section = try TableCoverage.section("""
        <x:table xmlns:x="urn:example:other"><x:tr><x:td>A</x:td><x:td>B</x:td></x:tr></x:table>
        <h:table xmlns:h="http://www.w3.org/1999/xhtml"><h:tr><h:td>C</h:td><h:td>D</h:td></h:tr></h:table>
        """)
        let tables = TableCoverage.tables(in: section.string)
        XCTAssertEqual(tables.count, 1, "only the XHTML one, whatever its prefix")
        XCTAssertEqual(tables.first?.cells.map(\.text), ["C", "D"])
        XCTAssertTrue(section.string.readerPlainText().contains("A") && section.string.readerPlainText().contains("B"))
    }
}
