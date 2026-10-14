import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Column widths, shrinking, row slices and pagination of tables built by the real pipeline
/// (CSS 2.2 §17.5 and the Tables decision in `doc/native-viewer.md`).
final class TableCoverageLayoutTests: XCTestCase {
    private static let images = TableCoverage.images([20, 30, 50, 100, 150, 300])

    private func boxes(_ markup: String, css: String = "") throws -> TableModel {
        try TableCoverage.table(markup, css: TableCoverage.bare + css, files: Self.images)
    }

    /// A table with spans, blocks, a header and cells of very different heights.
    private static let varied = """
    <table border="1"><thead><tr><th>Item</th><th colspan="2">Description of the item</th></tr></thead>
    <tbody><tr><td rowspan="3">\((0..<70).map { "span\($0)" }.joined(separator: " "))</td><td>one</td><td>two</td></tr>
    <tr><td><p>First paragraph of several words.</p><p>Second paragraph.</p><ul><li>point a</li><li>point b</li></ul></td><td>three</td></tr>
    <tr><td colspan="2">\((0..<40).map { "wide\($0)" }.joined(separator: " "))</td></tr>
    <tr><td>last</td><td rowspan="2">\((0..<30).map { "tail\($0)" }.joined(separator: " "))</td><td>x</td></tr><tr><td>end</td><td>y</td></tr></tbody></table>
    """

    // MARK: Column widths

    /// CSS 2.2 §17.5.2.2: a fixed column takes its width, a percentage column its share of the
    /// table, and the table is as wide as both and the automatic columns' content need.
    func testFixedPercentageAndAutomaticColumnsShareTheTable() throws {
        let table = try boxes("<table><tr>\(TableCoverage.box(50, "width='80'"))\(TableCoverage.box(50, "width='25%'"))\(TableCoverage.box(100))</tr></table>")
        let layout = table.layout(available: 1000, viewportHeight: 600)
        XCTAssertEqual(layout.columnWidths, [80, 60, 100])
        XCTAssertEqual(layout.size.width, 240)
        XCTAssertEqual(layout.columnWidths[1] / layout.size.width, 0.25, accuracy: 0.001)
        // With less room than that, no column goes below its content and the line is filled.
        let tight = table.layout(available: 210, viewportHeight: 600)
        XCTAssertEqual(tight.scale, 1)
        XCTAssertEqual(tight.size.width, 210, accuracy: 0.01)
        for (width, minimum) in zip(tight.columnWidths, [50.0, 50, 100]) { XCTAssertGreaterThanOrEqual(width, minimum - 0.01) }
    }

    func testPercentagesOverAHundredNeverMakeANegativeOrOverwideColumn() throws {
        let table = try boxes("<table><tr>\(TableCoverage.box(50, "width='70%'"))\(TableCoverage.box(50, "width='70%'"))\(TableCoverage.box(50))\(TableCoverage.box(20, "width='0%'"))</tr></table>")
        for available: CGFloat in [170, 200, 400, 1000] {
            let layout = table.layout(available: available, viewportHeight: 600)
            XCTAssertEqual(layout.scale, 1, "\(available)")
            XCTAssertLessThanOrEqual(layout.size.width, available + 0.01, "\(available)")
            for (width, minimum) in zip(layout.columnWidths, [50.0, 50, 50, 20]) {
                XCTAssertTrue(width.isFinite, "\(available)")
                XCTAssertGreaterThanOrEqual(width, minimum - 0.01, "\(available)")
            }
            XCTAssertEqual(layout.columnWidths.reduce(0, +), layout.size.width, accuracy: 0.01, "\(available)")
        }
    }

    /// CSS 2.2 §17.5.2.2: the table's used width is the greater of its `width` and its minimum
    /// content width; here it is also never wider than its line.
    func testATablesOwnWidthInPointsPercentOrMoreThanTheLine() throws {
        let row = "<tr>\(TableCoverage.box(100))\(TableCoverage.box(50))</tr>"
        XCTAssertEqual(try boxes("<table width='400'>\(row)</table>").layout(available: 1000, viewportHeight: 600).size.width, 400, accuracy: 0.01)
        XCTAssertEqual(try boxes("<table>\(row)</table>", css: "table { width: 50%; }").layout(available: 1000, viewportHeight: 600).size.width, 500, accuracy: 0.01)
        XCTAssertEqual(try boxes("<table width='100%'>\(row)</table>").layout(available: 640, viewportHeight: 600).size.width, 640, accuracy: 0.01)
        XCTAssertEqual(try boxes("<table width='5000'>\(row)</table>").layout(available: 640, viewportHeight: 600).size.width, 640, accuracy: 0.01)
        XCTAssertEqual(try boxes("<table>\(row)</table>", css: "table { width: 150%; }").layout(available: 640, viewportHeight: 600).size.width, 640, accuracy: 0.01)
        XCTAssertEqual(try boxes("<table width='10'>\(row)</table>").layout(available: 640, viewportHeight: 600).size.width, 150, accuracy: 0.01,
                       "narrower than its content asks: the content's width")
        XCTAssertEqual(try boxes("<table>\(row)</table>", css: "table { width: auto; }").layout(available: 640, viewportHeight: 600).size.width, 150, accuracy: 0.01)
        // The extra width of a wider table goes to its columns in proportion to their content.
        let wide = try boxes("<table width='300'>\(row)</table>").layout(available: 640, viewportHeight: 600)
        XCTAssertEqual(wide.columnWidths[0], 200, accuracy: 0.01)
        XCTAssertEqual(wide.columnWidths[1], 100, accuracy: 0.01)
    }

    func testAColumnsWidthFromItsColElementHoldsWhateverItsCellsAsk() throws {
        let table = try boxes("""
        <table><colgroup><col width="120"/><col/></colgroup><tr>\(TableCoverage.box(50))\(TableCoverage.box(30))</tr><tr>\(TableCoverage.box(20))\(TableCoverage.box(100))</tr></table>
        """)
        let layout = table.layout(available: 1000, viewportHeight: 600)
        XCTAssertEqual(layout.columnWidths, [120, 100])
        // A fixed width smaller than the content gives way to the content.
        let small = try boxes("<table><col width='10'/><tr>\(TableCoverage.box(50))\(TableCoverage.box(30))</tr></table>")
        XCTAssertEqual(small.layout(available: 1000, viewportHeight: 600).columnWidths, [50, 30])
    }

    func testASpanningCellWiderThanItsColumnsGrowsThemAndANarrowerOneDoesNot() throws {
        let narrow = try boxes("<table><tr>\(TableCoverage.box(100))\(TableCoverage.box(50))</tr><tr>\(TableCoverage.box(30, "colspan='2'"))</tr></table>")
        XCTAssertEqual(narrow.layout(available: 1000, viewportHeight: 600).columnWidths, [100, 50])
        let wide = try boxes("<table><tr>\(TableCoverage.box(100))\(TableCoverage.box(50))</tr><tr>\(TableCoverage.box(300, "colspan='2'"))</tr></table>")
        let layout = wide.layout(available: 1000, viewportHeight: 600)
        XCTAssertEqual(layout.columnWidths.reduce(0, +), 300, accuracy: 0.01)
        XCTAssertEqual(layout.cellFrames[2].width, 300, accuracy: 0.01)
        // A span over columns of equal content shares its width equally.
        let equal = try boxes("<table><tr>\(TableCoverage.box(300, "colspan='3'"))</tr><tr>\(TableCoverage.box(20))\(TableCoverage.box(20))\(TableCoverage.box(20))</tr></table>")
        XCTAssertEqual(equal.layout(available: 1000, viewportHeight: 600).columnWidths, [100, 100, 100])
    }

    func testBorderSpacingInsideASpanCountsTowardsItsWidth() throws {
        let table = try TableCoverage.table("<table><tr>\(TableCoverage.box(100))\(TableCoverage.box(100))</tr><tr>\(TableCoverage.box(150, "colspan='2'"))</tr></table>",
                                            css: "table { border-spacing: 20px; } td { padding: 0; }", files: Self.images)
        let layout = table.layout(available: 1000, viewportHeight: 600)
        XCTAssertEqual(layout.columnWidths, [100, 100], "220 of room for a 150 cell: nothing grows")
        XCTAssertEqual(layout.cellFrames[2].width, 220, accuracy: 0.01, "the span covers the spacing between its columns")
        XCTAssertEqual(layout.cellFrames[2].minX, layout.cellFrames[0].minX, accuracy: 0.01)
        XCTAssertEqual(layout.cellFrames[2].maxX, layout.cellFrames[1].maxX, accuracy: 0.01)
    }

    // MARK: Too wide for the line

    /// "Tables too wide for the line shrink their text to 60%, then wrap by character."
    func testTheShrinkAndCharacterWrapThresholdsAtTheirBoundaries() throws {
        let table = try boxes("<table><tr>\(TableCoverage.box(300))\(TableCoverage.box(150))\(TableCoverage.box(50))</tr></table>")
        XCTAssertEqual(table.constraints.minimumTableWidth, 500)
        func layout(_ available: CGFloat) -> TableLayout { table.layout(available: available, viewportHeight: 600) }
        XCTAssertEqual(layout(501).scale, 1)
        XCTAssertEqual(layout(500).scale, 1, "exactly fitting does not shrink")
        XCTAssertEqual(layout(499).scale, 499.0 / 500, accuracy: 0.0001)
        XCTAssertEqual(layout(499).columnWidths, [300, 150, 50], "laid out at full size")
        XCTAssertEqual(layout(301).scale, 301.0 / 500, accuracy: 0.0001)
        XCTAssertEqual(layout(300).scale, TableModel.minimumScale, accuracy: 0.0001, "60% is the floor")
        XCTAssertEqual(layout(300).columnWidths, [300, 150, 50])
        let below = layout(299)
        XCTAssertEqual(below.scale, TableModel.minimumScale)
        XCTAssertEqual(below.columnWidths.reduce(0, +), 299 / TableModel.minimumScale, accuracy: 0.01, "past it the columns narrow")
        XCTAssertEqual(below.columnWidths[0] / below.columnWidths[1], 2, accuracy: 0.001, "all alike")
        XCTAssertEqual(below.columnWidths[1] / below.columnWidths[2], 3, accuracy: 0.001)
        for available: CGFloat in [501, 500, 499, 301, 300, 299, 120, 40] {
            let layout = layout(available)
            XCTAssertLessThanOrEqual(layout.size.width * layout.scale, available + 0.01, "\(available): never wider than the line")
        }
    }

    func testWordsStayWholeUntilTheTableHasShrunkToSixtyPercent() throws {
        let table = try TableCoverage.table("<table><tr><td>extraordinary circumstances</td><td>unquestionably</td><td>incomprehensible notwithstanding</td></tr></table>")
        let minimum = table.constraints.minimumTableWidth
        func lines(_ layout: TableLayout) -> [[String]] {
            table.cells.indices.map { cell in
                layout.cellText[cell].lines.map { (table.cells[cell].content.string as NSString).substring(with: $0.characters) }
            }
        }
        let whole = [["extraordinary ", "circumstances"], ["unquestionably"], ["incomprehensible ", "notwithstanding"]]
        XCTAssertEqual(lines(table.layout(available: ceil(minimum), viewportHeight: 600)), whole)
        let smallest = table.layout(available: ceil(minimum * TableModel.minimumScale) + 1, viewportHeight: 600)
        XCTAssertEqual(smallest.scale, TableModel.minimumScale, accuracy: 0.01)
        XCTAssertEqual(lines(smallest), whole, "at 60% every word is still on one line")
        let narrow = (minimum * TableModel.minimumScale * 0.5).rounded(.down)
        let wrapped = table.layout(available: narrow, viewportHeight: 600)
        XCTAssertEqual(wrapped.scale, TableModel.minimumScale)
        for (cell, broken) in lines(wrapped).enumerated() {
            XCTAssertGreaterThan(broken.count, whole[cell].count, "narrower than that, the words of cell \(cell) break")
            XCTAssertEqual(broken.joined(), table.cells[cell].content.string, "losing no character")
        }
        XCTAssertLessThanOrEqual(wrapped.size.width * wrapped.scale, narrow + 0.01)
    }

    func testTablesOfTwoThirtyAndTwoHundredColumnsStayOnTheirLine() throws {
        for count in [2, 30, 200] {
            let cells = (0..<count).map { "<td>c\($0)</td>" }.joined()
            let table = try TableCoverage.table("<table><tr>\(cells)</tr><tr>\(cells)</tr></table>", css: "table { border-collapse: collapse; }")
            XCTAssertEqual(table.columnCount, count)
            for available: CGFloat in [320, 700, 1200] {
                let layout = table.layout(available: available, viewportHeight: 600)
                XCTAssertEqual(layout.columnWidths.count, count)
                XCTAssertGreaterThanOrEqual(layout.scale, TableModel.minimumScale, "\(count) columns in \(available)")
                XCTAssertLessThanOrEqual(layout.scale, 1)
                XCTAssertLessThanOrEqual(layout.size.width * layout.scale, available + 0.5, "\(count) columns in \(available)")
                XCTAssertTrue(layout.columnWidths.allSatisfy { $0 > 0 && $0.isFinite }, "\(count) columns in \(available)")
                for (cell, text) in layout.cellText.enumerated() {
                    XCTAssertEqual(text.lines.map(\.characters.length).reduce(0, +), table.cells[cell].content.length, "\(count) columns in \(available)")
                }
            }
        }
    }

    // MARK: Invariants

    func testEveryLayoutTilesItsRowsAndKeepsCellsAndContentInsideTheirBoxes() throws {
        for typography in [NativeTypography(fontSize: 12), NativeTypography(fontSize: 17), NativeTypography(fontSize: 34)] {
            let table = try TableCoverage.table(Self.varied, typography: typography)
            for available: CGFloat in [90, 200, 320, 414, 768, 1400] {
                let layout = table.layout(available: available, viewportHeight: 700)
                let context = "font \(typography.fontSize) width \(available)"
                XCTAssertGreaterThanOrEqual(layout.scale, TableModel.minimumScale, context)
                XCTAssertLessThanOrEqual(layout.size.width * layout.scale, available + 0.5, context)
                XCTAssertEqual(layout.rowTops.count, table.rows.count + 1, context)
                XCTAssertEqual(layout.rowTops.first, 0, context)
                XCTAssertEqual(layout.rowTops.last ?? 0, layout.size.height, accuracy: 0.01, context)
                XCTAssertEqual(layout.rowTops, layout.rowTops.sorted(), context)
                XCTAssertEqual(table.rows.indices.map(layout.height(ofRow:)).reduce(0, +), layout.size.height * layout.scale, accuracy: 0.05, context)
                let bounds = CGRect(origin: .zero, size: layout.size).insetBy(dx: -0.01, dy: -0.01)
                for (index, cell) in table.cells.enumerated() {
                    XCTAssertTrue(bounds.contains(layout.cellFrames[index]), "\(context): cell \(index) is outside the table")
                    XCTAssertGreaterThanOrEqual(layout.contentFrames[index].minX, layout.cellFrames[index].minX - 0.01, context)
                    XCTAssertLessThanOrEqual(layout.contentFrames[index].maxX, layout.cellFrames[index].maxX + 0.01, context)
                    XCTAssertGreaterThanOrEqual(layout.contentFrames[index].minY, layout.cellFrames[index].minY - 0.01, context)
                    XCTAssertLessThanOrEqual(layout.contentFrames[index].maxY, layout.cellFrames[index].maxY + 0.01, "\(context): cell \(index) overflows its box")
                    XCTAssertEqual(layout.cellText[index].lines.map(\.characters.length).reduce(0, +), cell.content.length, context)
                    // A cell starts in its first row's slice and ends in its last row's.
                    XCTAssertGreaterThanOrEqual(layout.cellFrames[index].minY, layout.rowTops[cell.row] - 0.01, context)
                    XCTAssertLessThan(layout.cellFrames[index].minY, layout.rowTops[cell.row + 1] + 0.01, context)
                    XCTAssertLessThanOrEqual(layout.cellFrames[index].maxY, layout.rowTops[cell.row + cell.rowSpan] + 0.01, context)
                }
                // Cells that start in the same row start at the same height.
                for row in table.rows.indices {
                    let tops = Set(table.cells.indices.filter { table.cells[$0].row == row }.map { (layout.cellFrames[$0].minY * 100).rounded() })
                    XCTAssertLessThanOrEqual(tops.count, 1, context)
                }
            }
        }
    }

    func testASpanningCellTallerThanItsRowsGrowsThemEqually() throws {
        let table = try boxes("""
        <table><tr><td rowspan="2"><img src="w20.png" alt=""/><br/><img src="w20.png" alt=""/><br/><img src="w20.png" alt=""/><br/><img src="w20.png" alt=""/><br/><img src="w20.png" alt=""/><br/><img src="w20.png" alt=""/></td>\(TableCoverage.box(50))</tr>
        <tr>\(TableCoverage.box(30))</tr></table>
        """)
        let layout = table.layout(available: 400, viewportHeight: 600)
        let tall = layout.cellText[0].height
        XCTAssertGreaterThan(tall, layout.cellText[1].height * 4)
        XCTAssertEqual(layout.rowHeights[0], layout.rowHeights[1], accuracy: 0.01)
        XCTAssertEqual(layout.rowHeights.reduce(0, +), tall, accuracy: 0.01, "the rows together are exactly as tall as the spanning cell")
        XCTAssertEqual(layout.cellFrames[0].height, tall, accuracy: 0.01)
        // A spanning cell shorter than its rows changes nothing.
        let short = try boxes("<table><tr>\(TableCoverage.box(20, "rowspan='2'"))\(TableCoverage.box(50))</tr><tr>\(TableCoverage.box(30))</tr></table>")
        let plain = try boxes("<table><tr>\(TableCoverage.box(20))\(TableCoverage.box(50))</tr><tr>\(TableCoverage.box(20))\(TableCoverage.box(30))</tr></table>")
        XCTAssertEqual(short.layout(available: 400, viewportHeight: 600).rowHeights, plain.layout(available: 400, viewportHeight: 600).rowHeights)
    }

    // MARK: Row slices

    /// "Oversized rows continue across pages using complete cell glyph lines; a line crossing a
    /// rowspan boundary is finished in its preceding row and never drawn twice."
    func testRowSlicesAtAnyPageHeightHoldEveryGlyphLineOnceWithinTheirHeight() throws {
        for typography in [NativeTypography(fontSize: 13), NativeTypography(fontSize: 24)] {
            let table = try TableCoverage.table(Self.varied, typography: typography)
            for available: CGFloat in [150, 320, 600] {
                for page: CGFloat in [35, 80, 150, 400, 2000] {
                    let layout = table.layout(available: available, viewportHeight: page)
                    let context = "font \(typography.fontSize) width \(available) page \(page)"
                    var assigned = [Int: [Int]]()
                    for row in table.rows.indices {
                        let slices = layout.fragments(ofRow: row, maximumHeight: page - 1)
                        XCTAssertFalse(slices.isEmpty, context)
                        XCTAssertEqual(slices.first?.top ?? -1, layout.rowTops[row], accuracy: 0.01, context)
                        XCTAssertEqual(slices.last?.bottom ?? -1, layout.rowTops[row + 1], accuracy: 0.01, context)
                        for (previous, next) in zip(slices, slices.dropFirst()) { XCTAssertEqual(next.top, previous.bottom, accuracy: 0.01, context) }
                        for slice in slices {
                            XCTAssertEqual(slice.row, row)
                            XCTAssertGreaterThan(slice.fitScale, 0, context)
                            XCTAssertLessThanOrEqual(slice.height * layout.scale * slice.fitScale, page - 1 + 0.01, "\(context): row \(row) slice taller than the page")
                            for entry in slice.cells {
                                XCTAssertFalse(entry.lines.isEmpty, context)
                                XCTAssertTrue(table.rowCells[row].contains(entry.cell), "\(context): row \(row) draws a cell that does not cover it")
                                assigned[entry.cell, default: []] += Array(entry.lines)
                                for number in entry.lines {
                                    let frame = layout.cellText[entry.cell].lines[number].frame.offsetBy(dx: 0, dy: layout.contentFrames[entry.cell].minY - slice.top)
                                    XCTAssertGreaterThanOrEqual(frame.minY, -0.01, "\(context): a line starts above its slice")
                                    XCTAssertLessThanOrEqual(frame.maxY, slice.height + 0.01, "\(context): a line ends below its slice")
                                }
                            }
                        }
                    }
                    for cell in table.cells.indices {
                        XCTAssertEqual(assigned[cell] ?? [], Array(layout.cellText[cell].lines.indices), "\(context): cell \(cell)")
                    }
                }
            }
        }
    }

    func testAShortRowIsOneSliceOfItsFullHeightWhateverThePageHeight() throws {
        let table = try TableCoverage.table("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>")
        let layout = table.layout(available: 400, viewportHeight: 600)
        for maximum: CGFloat in [600, 100, layout.height(ofRow: 0), .greatestFiniteMagnitude] {
            let slices = layout.fragments(ofRow: 0, maximumHeight: maximum)
            XCTAssertEqual(slices.count, 1)
            XCTAssertEqual(slices[0].height * layout.scale, layout.height(ofRow: 0), accuracy: 0.01)
            XCTAssertEqual(slices[0].fitScale, 1)
            XCTAssertEqual(slices[0].cells.map(\.cell), [0, 1])
        }
    }

    func testDegeneratePageHeightsStillSliceARowToItsEnd() throws {
        let table = try TableCoverage.table("<table><tr><td>\((0..<40).map { "word\($0)" }.joined(separator: " "))</td><td>b</td></tr></table>")
        let layout = table.layout(available: 200, viewportHeight: 300)
        for maximum: CGFloat in [0, -50, 0.25, 1] {
            let slices = layout.fragments(ofRow: 0, maximumHeight: maximum)
            XCTAssertEqual(slices.last?.bottom ?? -1, layout.rowTops[1], accuracy: 0.01, "\(maximum)")
            XCTAssertLessThanOrEqual(slices.count, 4 * Int(layout.rowTops[1]), "\(maximum): slices advance")
            XCTAssertTrue(zip(slices, slices.dropFirst()).allSatisfy { $1.top > $0.top }, "\(maximum): slices advance")
            XCTAssertEqual(slices.flatMap { $0.cells.filter { $0.cell == 0 }.flatMap { Array($0.lines) } }, Array(layout.cellText[0].lines.indices), "\(maximum)")
        }
    }

    // MARK: Attachments

    /// "Continuous scroll retains full row heights."
    func testAWholeRowAttachmentIsItsFullHeightAndFillsItsLine() throws {
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let table = try TableCoverage.table("<table><tr><td>\(words)</td><td>x</td></tr><tr><td>a</td><td>b</td></tr></table>")
        let rows = table.rows.indices.map { TableRowAttachment(table: table, row: $0) }
        for width: CGFloat in [200, 400] {
            let layout = table.layout(available: width, viewportHeight: 150)
            XCTAssertGreaterThan(layout.height(ofRow: 0), 150, "a row taller than the viewport")
            for row in rows {
                XCTAssertEqual(row.height(width: width, viewportHeight: 150), layout.height(ofRow: row.row), accuracy: 0.01)
                let bounds = row.layoutBounds(line(width, viewport: CGSize(width: width, height: 150)))
                XCTAssertEqual(bounds.width, width)
                XCTAssertEqual(bounds.height, layout.height(ofRow: row.row), accuracy: 0.01)
            }
            XCTAssertEqual(rows.map { $0.height(width: width, viewportHeight: 150) }.reduce(0, +), layout.size.height * layout.scale, accuracy: 0.05)
        }
        // An indented line gives the row what is left of it.
        let indented = rows[0].layoutBounds(line(400, viewport: CGSize(width: 400, height: 150), position: 60))
        XCTAssertEqual(indented.width, 340)
        XCTAssertEqual(indented.height, table.layout(available: 340, viewportHeight: 150).height(ofRow: 0), accuracy: 0.01)
    }

    func testARowJoinedByARowspanIsNeverShorterThanItsSliceOfTheTable() throws {
        let table = try TableCoverage.table(Self.varied)
        for width: CGFloat in [200, 400] {
            let layout = table.layout(available: width, viewportHeight: 2000)
            for row in table.rows.indices {
                let height = TableRowAttachment(table: table, row: row).height(width: width, viewportHeight: 2000)
                XCTAssertGreaterThanOrEqual(height, layout.height(ofRow: row) - 0.01, "row \(row) at \(width)")
                XCTAssertLessThan(height, layout.height(ofRow: row) + 40, "row \(row) at \(width): at most a line more, to finish one")
            }
        }
    }

    func testARowAttachmentReportsTheTablesContentWidthsForATableAroundIt() throws {
        let table = try boxes("<table><tr>\(TableCoverage.box(100))\(TableCoverage.box(50))</tr></table>")
        let widths = TableRowAttachment(table: table, row: 0).contentWidths()
        XCTAssertEqual(widths.min, 150, accuracy: 0.01, "nested intrinsic widths do not compound scale reductions")
        XCTAssertEqual(widths.max, 150, accuracy: 0.01)
    }

    func testARowReadsTheCellsThatStartInItInColumnOrderAndASliceItsOwnLines() throws {
        let table = try TableCoverage.table("""
        <table><tr><td rowspan="2">\((0..<400).map { "left\($0)" }.joined(separator: " "))</td><td>top</td></tr><tr><td>bottom</td></tr></table>
        """)
        let rows = table.rows.indices.map { TableRowAttachment(table: table, row: $0) }
        XCTAssertTrue(rows[0].textEquivalent.hasPrefix("left0 left1"))
        XCTAssertTrue(rows[0].textEquivalent.hasSuffix("left399\ttop"))
        XCTAssertEqual(rows[1].textEquivalent, "bottom", "a spanning cell is read once, in its first row")
        // Sliced, each continuation reads the lines it draws; together they read the cell once.
        let layout = table.layout(available: 200, viewportHeight: 120)
        var spoken: [String] = []
        for row in table.rows.indices {
            for slice in layout.fragments(ofRow: row, maximumHeight: 119) {
                spoken.append(TableRowAttachment(table: table, row: row, fragment: slice, layout: layout).textEquivalent)
            }
        }
        XCTAssertGreaterThan(spoken.count, 3)
        let words = spoken.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(words.filter { $0.hasPrefix("left") }, (0..<400).map { "left\($0)" })
        XCTAssertEqual(words.filter { $0 == "top" || $0 == "bottom" }, ["top", "bottom"])
    }

    // MARK: The layout cache

    /// "Cell TextKit layouts and glyph metadata are retained for drawing in the table's bounded
    /// layout cache."
    func testTheLayoutCacheReturnsTheSameLayoutAndIsBounded() throws {
        let table = try TableCoverage.table(Self.varied)
        let first = table.layout(available: 300, viewportHeight: 500)
        XCTAssertTrue(table.layout(available: 300, viewportHeight: 500).cellText[0] === first.cellText[0], "retained")
        XCTAssertTrue(table.layout(available: 300.1, viewportHeight: 500.2).cellText[0] === first.cellText[0], "sizes within a quarter point share a layout")
        XCTAssertFalse(table.layout(available: 300, viewportHeight: 400).cellText[0] === first.cellText[0], "the page height is part of the key")
        for width in 0..<8 { _ = table.layout(available: 310 + CGFloat(width) * 10, viewportHeight: 500) }
        let again = table.layout(available: 300, viewportHeight: 500)
        XCTAssertFalse(again.cellText[0] === first.cellText[0], "the oldest of more than eight layouts was released")
        // A layout made again is the same layout.
        XCTAssertEqual(again.columnWidths, first.columnWidths)
        XCTAssertEqual(again.rowHeights, first.rowHeights)
        XCTAssertEqual(again.cellFrames, first.cellFrames)
        XCTAssertEqual(again.contentFrames, first.contentFrames)
        XCTAssertEqual(again.cellText.map { $0.lines.map(\.characters) }, first.cellText.map { $0.lines.map(\.characters) })
    }

    func testDegenerateLineWidthsAndPageHeightsLayOutWithoutTrapping() throws {
        let table = try TableCoverage.table(Self.varied)
        for (width, height): (CGFloat, CGFloat) in [(0, 0), (-10, -10), (0.3, 600), (1, 1), (400, 0), (1_000_000, 1_000_000)] {
            let layout = table.layout(available: width, viewportHeight: height)
            XCTAssertTrue(layout.size.width.isFinite && layout.size.height.isFinite, "\(width)x\(height)")
            XCTAssertTrue(layout.columnWidths.allSatisfy { $0.isFinite && $0 >= 0 }, "\(width)x\(height)")
            XCTAssertGreaterThanOrEqual(layout.scale, TableModel.minimumScale)
            XCTAssertFalse(layout.fragments(ofRow: 1, maximumHeight: max(1, height)).isEmpty)
        }
    }

    /// "A section's characters depend only on its document, never on typography": a rebuild for
    /// another size has the same rows and cell characters, laid out afresh.
    func testARebuildAtAnotherFontSizeHasTheSameCharactersAndALargerLayout() throws {
        let small = try TableCoverage.section("<p>Before</p>\(Self.varied)<p>After</p>", typography: .init(fontSize: 14))
        let large = try TableCoverage.section("<p>Before</p>\(Self.varied)<p>After</p>", typography: .init(fontSize: 28))
        XCTAssertEqual(small.string.string, large.string.string)
        XCTAssertEqual(small.map, large.map)
        let before = try XCTUnwrap(TableCoverage.tables(in: small.string).first), after = try XCTUnwrap(TableCoverage.tables(in: large.string).first)
        XCTAssertEqual(before.cells.map(\.content.string), after.cells.map(\.content.string))
        XCTAssertEqual(before.cells.map { $0.textMap?.map }, after.cells.map { $0.textMap?.map })
        XCTAssertEqual(before.sourceOrder, after.sourceOrder)
        XCTAssertEqual(before.sourceRowOffsets, after.sourceRowOffsets)
        XCTAssertEqual(TableCoverage.grid(before), TableCoverage.grid(after))
        XCTAssertGreaterThan(after.layout(available: 2000, viewportHeight: 4000).size.height, before.layout(available: 2000, viewportHeight: 4000).size.height)
        XCTAssertGreaterThan(after.constraints.minimumTableWidth, before.constraints.minimumTableWidth)
    }

    // MARK: Drawing

    private func pixels(_ row: TableRowAttachment, width: CGFloat) throws -> (image: CGImage, size: CGSize) {
        let size = CGSize(width: width, height: row.height(width: width, viewportHeight: 600))
        let image = try XCTUnwrap(row.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0))
        return (try XCTUnwrap(RichImageTests.draw(image, size: size, scale: 1)), size)
    }

    /// CSS 2.2 §17.5.1: the cell's background is in front of its row's, which is in front of the
    /// table's; the table's shows in the border spacing.
    func testBackgroundsAreDrawnTableThenRowThenCell() throws {
        let section = try TableCoverage.section("""
        <table bgcolor="#0000ff" cellspacing="20" cellpadding="20"><tr bgcolor="#00ff00"><td bgcolor="#ff0000">a</td><td>b</td></tr></table>
        """)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let layout = table.layout(available: 400, viewportHeight: 600)
        let (image, size) = try pixels(TableRowAttachment(table: table, row: 0), width: 400)
        let middle = Int(size.height / 2) // Sampled on the row's centre line, in the padding: clear of the text.
        XCTAssertEqual(Array(RichImageTests.rgba(image, x: Int(layout.cellFrames[0].minX) + 5, y: middle).prefix(3)), [255, 0, 0], "the cell's own colour")
        XCTAssertEqual(Array(RichImageTests.rgba(image, x: Int(layout.cellFrames[1].minX) + 5, y: middle).prefix(3)), [0, 255, 0], "its row's colour")
        XCTAssertEqual(Array(RichImageTests.rgba(image, x: Int(layout.cellFrames[0].maxX) + 10, y: middle).prefix(3)), [0, 0, 255], "the table's between cells")
        XCTAssertEqual(RichImageTests.rgba(image, x: Int(layout.size.width) + 10, y: middle)[3], 0, "nothing past the table")
        // Dark appearance draws none of them.
        let dark = try TableCoverage.table("""
        <table bgcolor="#0000ff" cellspacing="20" cellpadding="20"><tr bgcolor="#00ff00"><td bgcolor="#ff0000">a</td><td>b</td></tr></table>
        """, typography: NativeTypography(fontSize: 16, isDark: true))
        let (darkImage, darkSize) = try pixels(TableRowAttachment(table: dark, row: 0), width: 400)
        for x in [Int(layout.cellFrames[0].minX) + 5, Int(layout.cellFrames[1].minX) + 5, Int(layout.cellFrames[0].maxX) + 10] {
            XCTAssertEqual(RichImageTests.rgba(darkImage, x: x, y: Int(darkSize.height / 2))[3], 0)
        }
    }

    /// "a spanning cell is drawn in each row it covers".
    func testASpanningCellsBackgroundIsDrawnInEveryRowItCovers() throws {
        let table = try TableCoverage.table("""
        <table cellspacing="0" cellpadding="20"><tr><td rowspan="3" bgcolor="#ff0000">tall</td><td>a</td></tr><tr><td>b</td></tr><tr><td>c</td></tr>
        <tr><td>d</td><td>e</td></tr></table>
        """)
        let layout = table.layout(available: 300, viewportHeight: 600)
        let x = Int(layout.cellFrames[0].minX) + 5
        for row in 0..<3 {
            let (image, size) = try pixels(TableRowAttachment(table: table, row: row), width: 300)
            XCTAssertEqual(Array(RichImageTests.rgba(image, x: x, y: Int(size.height / 2)).prefix(3)), [255, 0, 0], "row \(row)")
        }
        let (image, size) = try pixels(TableRowAttachment(table: table, row: 3), width: 300)
        XCTAssertEqual(RichImageTests.rgba(image, x: x, y: Int(size.height / 2))[3], 0, "the row after the span")
    }

    /// A row is drawn taller than its slice of the table to finish a spanning cell's line that
    /// crosses into the next row. The table does not stop there: its border and the spanning
    /// cell's background run on to the next row, as the cell's box does (CSS 2.2 §17.5.1).
    func testARowExtendedToFinishASpanningCellsLineKeepsItsBorderAndBackgroundToItsEnd() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/141")
        let table = try TableCoverage.table("""
        <table border="1" cellpadding="4"><tr><td rowspan="2" bgcolor="#ff0000">line one<br/>line two<br/>line three</td><td>a</td></tr>
        <tr><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>
        """)
        let layout = table.layout(available: 300, viewportHeight: 600)
        let row = TableRowAttachment(table: table, row: 0)
        let (image, size) = try pixels(row, width: 300)
        XCTAssertGreaterThan(size.height, layout.height(ofRow: 0) + 5, "the middle line crosses into the second row and is finished in the first")
        // In the cell's padding, between its border and its text.
        let x = Int(layout.cellFrames[0].minX + table.cells[0].borders.widths.left) + 1
        XCTAssertLessThan(CGFloat(x) + 1, layout.contentFrames[0].minX)
        // Clear of the cell's own top edge (its border and the spacing above it) at either end.
        let margin = Int(layout.cellFrames[0].minY + table.cells[0].borders.widths.top) + 3
        var bare: [Int] = [], open: [Int] = []
        for y in margin..<(image.height - margin) {
            if RichImageTests.rgba(image, x: x, y: y) != [255, 0, 0, 255] { bare.append(y) }
            if RichImageTests.rgba(image, x: 0, y: y)[3] < 128 { open.append(y) }
        }
        XCTAssertEqual(bare, [], "pixel rows of the \(image.height) where the spanning cell has no background")
        XCTAssertEqual(open, [], "pixel rows of the \(image.height) where the table has no left border")
    }

    /// CSS 2.2 §17.6.2.1: where collapsed borders meet, the wider one is drawn.
    func testTheWiderOfTwoCollapsedBordersIsTheOneDrawn() throws {
        let table = try TableCoverage.table("<table><tr><td class='thick'>a</td><td class='thin'>b</td></tr></table>",
                                            css: "table { border-collapse: collapse; } td { padding: 20px; } .thick { border: 8px solid #ff0000; } .thin { border: 2px solid #0000ff; }")
        let layout = table.layout(available: 300, viewportHeight: 600)
        let (image, size) = try pixels(TableRowAttachment(table: table, row: 0), width: 300)
        let shared = Int(layout.cellFrames[0].maxX)
        XCTAssertEqual(Array(RichImageTests.rgba(image, x: shared, y: Int(size.height / 2)).prefix(3)), [255, 0, 0])
        XCTAssertEqual(Array(RichImageTests.rgba(image, x: shared - 3, y: Int(size.height / 2)).prefix(3)), [255, 0, 0])
        // The thin cell's own outer edge is its own: blue, whatever the edge pixel's coverage on this platform.
        let edge = RichImageTests.rgba(image, x: Int(layout.cellFrames[1].maxX) - 1, y: Int(size.height / 2))
        XCTAssertTrue(edge[0] < 32 && edge[1] < 32 && edge[2] > 192, "\(edge)")
    }

    func testEveryRowOfAVariedTableDrawsInBothDirectionsAndBorderModels() throws {
        for css in ["", "table { border-collapse: collapse; } td { border: 1px dashed; } th { border: 2px dotted; }"] {
            for direction in ["ltr", "rtl"] {
                let table = try TableCoverage.table(Self.varied.replacingOccurrences(of: "<table ", with: "<table dir='\(direction)' "), css: css)
                for row in table.rows.indices {
                    let (image, _) = try pixels(TableRowAttachment(table: table, row: row), width: 320)
                    XCTAssertGreaterThan(RichTableTests.ink(image, columns: 0..<320), 0, "\(direction) row \(row) drew nothing")
                }
            }
        }
    }

    // MARK: Size

    func testAFiveThousandRowTableBuildsLaysOutAndSlicesEveryRow() throws {
        let rows = (0..<5000).map { "<tr><td>Row \($0)</td><td>Value \($0)</td></tr>" }.joined()
        let section = try TableCoverage.section("<table>\(rows)</table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(table.rows.count, 5000)
        XCTAssertEqual(table.cells.count, 10_000)
        XCTAssertEqual(section.string.length, 9_999, "a character per row and a break between rows")
        XCTAssertEqual(table.sourceRowOffsets.count, 5000)
        XCTAssertEqual(table.sourceRowOffsets[4999], 9_998)
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.rowTops.count, 5001)
        XCTAssertEqual(layout.fragments(ofRow: 4999, maximumHeight: 599).count, 1)
        XCTAssertEqual(TableRowAttachment(table: table, row: 4999).textEquivalent, "Row 4999\tValue 4999")
    }

    func testAQuarterMegabyteCellLaysOutAndSlicesWithoutLosingItsEnd() throws {
        let words = 21_000
        let table = try TableCoverage.table("<table><tr><td>" + (0..<words).map { "w\($0)" }.joined(separator: " ") + " end</td><td>x</td></tr></table>")
        XCTAssertGreaterThan(table.cells[0].content.length, 130_000)
        let layout = table.layout(available: 400, viewportHeight: 600)
        let lines = layout.cellText[0].lines
        XCTAssertEqual(lines.last?.characters.upperBound, table.cells[0].content.length)
        let slices = layout.fragments(ofRow: 0, maximumHeight: 599)
        XCTAssertGreaterThan(slices.count, 10)
        XCTAssertEqual(slices.flatMap { $0.cells.filter { $0.cell == 0 }.flatMap { Array($0.lines) } }.count, lines.count)
        let last = TableRowAttachment(table: table, row: 0, fragment: slices[slices.count - 1], layout: layout)
        XCTAssertTrue(last.textEquivalent.hasSuffix("end"))
    }
}
