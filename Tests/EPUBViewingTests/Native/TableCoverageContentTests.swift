import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What cells hold and how the table's attributes and CSS reach them (HTML §15.3.8,
/// CSS 2.2 §17), through the book's real cascade.
final class TableCoverageContentTests: XCTestCase {
    private func alignment(_ cell: TableModel.Cell, at location: Int = 0) -> NSTextAlignment? {
        (cell.content.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.alignment
    }

    // MARK: Cell content

    func testBlockContentInACellKeepsItsParagraphsMarkersLineBreaksAndPreformattedSpaces() throws {
        let table = try TableCoverage.table("""
        <table><tr><td><p>One</p><p>Two</p><ul><li>item</li></ul><h3>Head</h3><pre>a  b</pre>x<br/>y</td><td>side</td></tr></table>
        """)
        let cell = table.cells[0]
        XCTAssertEqual(cell.content.string, "One\nTwo\n\u{2022}\titem\nHead\na  b\nx\u{2028}y")
        XCTAssertEqual(cell.text, "One Two \u{2022} item Head a b x y", "spoken with white space collapsed")
        // Each block is a line of its own once laid out, however wide the column.
        let layout = table.layout(available: 1000, viewportHeight: 2000)
        XCTAssertEqual(layout.cellText[0].lines.count, 7)
        XCTAssertEqual(layout.cellText[0].lines.map(\.characters.length).reduce(0, +), cell.content.length)
        XCTAssertGreaterThan(layout.rowHeights[0], layout.cellText[1].height * 6)
    }

    func testPrettyPrintedMarkupLeavesNoWhiteSpaceInOrBetweenCells() throws {
        let section = try TableCoverage.section("""
        <table>
          <caption>
            Spaced   caption
          </caption>
          <thead>
            <tr>
              <th>
                Alpha   beta
              </th>
              <th> <em> gamma </em> </th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>\tdelta\r\n</td>
              <td>
              </td>
            </tr>
          </tbody>
        </table>
        """)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(table.cells.map(\.content.string), ["Alpha beta", "gamma", "delta", ""])
        XCTAssertEqual(section.string.string, "Spaced caption\n\u{FFFC}\n\u{FFFC}")
        XCTAssertEqual(section.string.readerPlainText(), "Spaced caption\nAlpha beta\tgamma\ndelta\t")
    }

    func testEmptyCellsHaveNoTextAndANoBreakSpaceCellKeepsItsSpace() throws {
        let table = try TableCoverage.table("<table><tr><td>a</td><td/><td> </td><td>&#160;</td><td><span></span></td></tr></table>")
        XCTAssertEqual(table.cells.map(\.content.string), ["a", "", "", "\u{00A0}", ""])
        XCTAssertEqual(table.cells.map(\.text), ["a", "", "", "", ""])
        XCTAssertEqual(table.cells.map(\.minContent), [table.cells[0].minContent, 0, 0, 0, 0])
        XCTAssertNil(table.cells[1].textMap)
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.cellFrames.map(\.height), Array(repeating: layout.rowHeights[0], count: 5), "empty cells are as tall as their row")
        XCTAssertEqual(TableRowAttachment(table: table, row: 0).textEquivalent, "a\t\t\t\t")
    }

    func testImagesInCellsGiveTheirColumnsTheirWidthAndAreFoundWhereTheyAreDrawn() throws {
        let section = try TableCoverage.section("""
        <table><tr><td><img src="w100.png" alt="A wide picture"/></td><td><img src="w30.png" alt=""/></td><td>text</td></tr></table>
        """, css: TableCoverage.bare, files: TableCoverage.images([100, 30]))
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(table.cells[0].minContent, 100)
        XCTAssertEqual(table.cells[0].maxContent, 100)
        XCTAssertEqual(table.cells[1].minContent, 30)
        XCTAssertEqual(table.cells[0].text, "A wide picture", "an image reads as its alternative text")
        XCTAssertEqual(table.cells[1].text, "")
        let row = TableRowAttachment(table: table, row: 0)
        let layout = table.layout(available: 400, viewportHeight: 600)
        let size = CGSize(width: 400, height: row.height(width: 400, viewportHeight: 600))
        let images = row.images(size: size, viewportHeight: 600)
        XCTAssertEqual(images.map(\.image.alt), ["A wide picture", ""])
        XCTAssertEqual(images[0].frame.width, 100, accuracy: 0.5)
        XCTAssertEqual(images[1].frame.width, 30, accuracy: 0.5)
        for (index, image) in images.enumerated() {
            XCTAssertTrue(layout.frame(ofCell: index, inRow: 0).insetBy(dx: -0.5, dy: -0.5).contains(image.frame), "image \(index) is inside its cell")
            XCTAssertTrue(row.image(at: CGPoint(x: image.frame.midX, y: image.frame.midY), size: size, viewportHeight: 600) === image.image)
        }
        XCTAssertNil(row.image(at: CGPoint(x: layout.frame(ofCell: 2, inRow: 0).midX, y: size.height / 2), size: size, viewportHeight: 600),
                     "text is not an image")
    }

    /// A picture without words or a rule that the book keeps from assistive technology says no
    /// more in a cell than decoration does: a row of such cells has nothing to say, and such a
    /// picture is none a cell offers to inspect.
    func testWhatTheBookKeepsFromAssistiveTechnologyGivesACellNothingToSay() throws {
        let section = try TableCoverage.section("""
        <table><tr><td><img src="w30.png" role="none"/></td><td><img src="w30.png" alt=""/></td></tr>\
        <tr><td><img src="w30.png" aria-hidden="true"/></td><td><hr role="presentation"/></td></tr>\
        <tr><td><img src="w30.png"/></td><td><hr/></td></tr></table>
        """, css: TableCoverage.bare, files: TableCoverage.images([30]))
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let rows = (0..<3).map { TableRowAttachment(table: table, row: $0) }
        XCTAssertEqual(rows.map(\.saysNothing), [true, true, false], "a picture nobody describes and a rule say something")
        let cells = rows.map { row in
            row.spokenCells(size: CGSize(width: 400, height: row.height(width: 400, viewportHeight: 600)), viewportHeight: 600)
        }
        XCTAssertEqual(cells.map { $0.map(\.isBlank) }.first, [true, true])
        XCTAssertEqual(cells.map { $0.map(\.isBlank) }[1][0], true)
        XCTAssertEqual(cells.map { $0.map(\.isBlank) }[2][0], false, "a picture nobody describes is something to say")
        XCTAssertEqual(cells.map { $0.map(\.images.count) }, [[0, 0], [0, 0], [1, 0]])
    }

    func testAnImageInAShrunkTableIsHitWhereItIsDrawnAtThatScale() throws {
        let table = try TableCoverage.table("<table><tr>\(TableCoverage.box(300))\(TableCoverage.box(100))</tr></table>",
                                            css: TableCoverage.bare, files: TableCoverage.images([300, 100]))
        let row = TableRowAttachment(table: table, row: 0)
        let layout = table.layout(available: 300, viewportHeight: 600)
        XCTAssertEqual(layout.scale, 0.75, accuracy: 0.001)
        let size = CGSize(width: 300, height: row.height(width: 300, viewportHeight: 600))
        let images = row.images(size: size, viewportHeight: 600)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(images[0].frame.width, 225, accuracy: 0.5)
        XCTAssertEqual(images[1].frame.minX, 225, accuracy: 0.5)
        XCTAssertEqual(images[1].frame.width, 75, accuracy: 0.5)
        XCTAssertTrue(row.image(at: CGPoint(x: 150, y: images[0].frame.midY), size: size, viewportHeight: 600) === images[0].image)
        XCTAssertTrue(row.image(at: CGPoint(x: 260, y: images[1].frame.midY), size: size, viewportHeight: 600) === images[1].image)
    }

    func testAFormulaInACellReadsItsAlternativeText() throws {
        let table = try TableCoverage.table("""
        <table><tr><td>Area</td><td><math xmlns="http://www.w3.org/1998/Math/MathML" alttext="pi r squared"><mi>π</mi><msup><mi>r</mi><mn>2</mn></msup></math></td></tr></table>
        """)
        XCTAssertEqual(table.cells[1].text, "pi r squared")
        XCTAssertEqual(table.cells[1].content.string, "\u{FFFC}")
        XCTAssertGreaterThan(table.cells[1].minContent, 0)
        XCTAssertLessThan(table.cells[1].maxContent, 200, "a formula is as wide as its symbols, not its line")
        XCTAssertEqual(TableRowAttachment(table: table, row: 0).textEquivalent, "Area\tpi r squared")
    }

    func testLinksInCellsCarryInternalNoteAndExternalTargets() throws {
        let section = try TableCoverage.section("""
        <table><tr><td><a href="#after">Jump</a></td><td><a epub:type="noteref" href="#note">1</a></td>
        <td><a href="https://example.com/page">Outside</a></td><td>plain</td></tr></table>
        <p id="after">After</p><aside id="note" epub:type="footnote"><p>The note.</p></aside>
        """)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        func link(_ index: Int) -> ReaderLink? {
            (table.cells[index].content.attribute(.link, at: 0, effectiveRange: nil) as? URL).flatMap(ReaderLink.init(url:))
        }
        XCTAssertEqual(link(0), .internal(href: "OPS/one.xhtml#after"))
        XCTAssertEqual(link(1), .note(href: "OPS/one.xhtml#note"))
        XCTAssertEqual(link(2), .external("https://example.com/page"))
        XCTAssertNil(link(3))
        XCTAssertNotNil(section.notes["note"], "a note referenced only from a cell is still captured")
        XCTAssertNotNil(section.anchors["after"])
    }

    func testALongUnbreakableWordWrapsByCharacterWithoutLosingAny() throws {
        let word = String(repeating: "abcdefghij", count: 30)
        let table = try TableCoverage.table("<table><tr><td>\(word)</td><td>short</td></tr></table>")
        let layout = table.layout(available: 320, viewportHeight: 600)
        XCTAssertEqual(layout.scale, TableModel.minimumScale, "shrunk as far as it goes first")
        XCTAssertEqual(layout.size.width * layout.scale, 320, accuracy: 0.5)
        let lines = layout.cellText[0].lines
        XCTAssertGreaterThan(lines.count, 1, "then wrapped inside the word")
        XCTAssertEqual(lines.map { (word as NSString).substring(with: $0.characters) }.joined(), word)
    }

    func testRightToLeftAndMixedScriptCellsKeepTheirCharacters() throws {
        let hebrew = "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD}", arabic = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", cjk = "\u{6F22}\u{5B57}\u{304B}\u{306A}"
        let table = try TableCoverage.table("<table><tr><td>\(hebrew)</td><td dir='rtl'>\(arabic) abc</td><td>\(cjk)</td><td>e\u{301}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}</td></tr></table>")
        XCTAssertEqual(table.cells.map(\.content.string), [hebrew, "\(arabic) abc", cjk, "e\u{301}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"])
        XCTAssertTrue(table.cells.allSatisfy { $0.minContent > 0 && $0.maxContent >= $0.minContent })
        XCTAssertFalse(table.isRightToLeft, "a cell's direction is not the table's")
        // CJK breaks between characters: its narrowest is about one of them.
        XCTAssertLessThan(table.cells[2].minContent, table.cells[2].maxContent / 2)
    }

    // MARK: Alignment

    /// HTML §15.3.8: `align` on `tr`, row groups and cells maps to `text-align`, which cells
    /// inherit; `th` is centred and bold by default.
    func testTextAlignmentReachesCellsFromRowsGroupsAndTheirOwnAttributes() throws {
        let table = try TableCoverage.table("""
        <table><thead align="right"><tr><th>a</th><th align="left">b</th></tr></thead>
        <tbody><tr align="center"><td>c</td><td align="right">d</td></tr><tr><td>e</td><th>f</th></tr>
        <tr class="j"><td>g</td><td style="text-align: left">h</td></tr></tbody></table>
        """, css: ".j { text-align: justify; }")
        XCTAssertEqual(table.cells.map(\.text), ["a", "b", "c", "d", "e", "f", "g", "h"])
        XCTAssertEqual(alignment(table.cells[0]), .center, "th centres itself whatever its group says")
        XCTAssertEqual(alignment(table.cells[1]), .left)
        XCTAssertEqual(alignment(table.cells[2]), .center)
        XCTAssertEqual(alignment(table.cells[3]), .right)
        XCTAssertEqual(alignment(table.cells[4]), .natural)
        XCTAssertEqual(alignment(table.cells[5]), .center)
        XCTAssertEqual(alignment(table.cells[6]), .justified)
        XCTAssertEqual(alignment(table.cells[7]), .left)
    }

    func testVerticalAlignmentComesFromCellsAndRowsAndDefaultsToTheMiddle() throws {
        let table = try TableCoverage.table("""
        <table><tr><td>a</td><td valign="top">b</td><td valign="bottom">c</td><td style="vertical-align: bottom">d</td><td valign="baseline">e</td></tr>
        <tr valign="top"><td>f</td><td valign="middle">g</td></tr><tr class="low"><td>h</td><td>i</td></tr></table>
        """, css: ".low { vertical-align: bottom; }")
        XCTAssertEqual(table.cells.map(\.placement), [.middle, .top, .bottom, .bottom, .top, .top, .middle, .bottom, .bottom])
    }

    /// HTML §15.3.8: `thead, tbody, tfoot, table > tr { vertical-align: middle }` and
    /// `tr, td, th { vertical-align: inherit }`, so a row group's alignment (its `valign`, a hint in the same section,
    /// or CSS) reaches its cells through the rows.
    func testVerticalAlignmentOnARowGroupReachesItsCells() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/142")
        let hinted = try TableCoverage.table("""
        <table><tbody valign="top"><tr><td>a<br/>b<br/>c</td><td>d</td></tr></tbody><tbody valign="bottom"><tr><td>e<br/>f</td><td>g</td></tr></tbody></table>
        """)
        XCTAssertEqual(hinted.cells.map(\.placement), [.top, .top, .bottom, .bottom])
        let styled = try TableCoverage.table("<table><tbody><tr><td>a<br/>b<br/>c</td><td>d</td></tr></tbody></table>",
                                             css: "tbody { vertical-align: top; }")
        XCTAssertEqual(styled.cells.map(\.placement), [.top, .top])
    }

    func testCellContentIsPlacedAtTheTopMiddleOrBottomOfItsCell() throws {
        let table = try TableCoverage.table("""
        <table><tr><td>1<br/>2<br/>3<br/>4</td><td valign="top">t</td><td valign="middle">m</td><td valign="bottom">b</td></tr></table>
        """)
        let layout = table.layout(available: 400, viewportHeight: 600)
        func inner(_ index: Int) -> CGRect {
            let chrome = table.cells[index].chrome, frame = layout.cellFrames[index]
            return CGRect(x: frame.minX + chrome.left, y: frame.minY + chrome.top,
                          width: frame.width - chrome.horizontal, height: frame.height - chrome.vertical)
        }
        XCTAssertEqual(layout.contentFrames[1].minY, inner(1).minY, accuracy: 0.01)
        XCTAssertEqual(layout.contentFrames[2].midY, inner(2).midY, accuracy: 0.51)
        XCTAssertEqual(layout.contentFrames[3].maxY, inner(3).maxY, accuracy: 0.01)
        XCTAssertGreaterThan(layout.contentFrames[3].minY, layout.contentFrames[2].minY)
        XCTAssertGreaterThan(layout.contentFrames[2].minY, layout.contentFrames[1].minY)
        for index in table.cells.indices { XCTAssertTrue(inner(index).insetBy(dx: -0.01, dy: -0.01).contains(layout.contentFrames[index])) }
    }

    // MARK: Presentational attributes and the box

    /// HTML §15.3.8: `border` draws the table's border and a 1px border on every cell,
    /// `cellpadding` pads cells and `cellspacing` separates them.
    func testBorderCellpaddingAndCellspacingAttributes() throws {
        let table = try TableCoverage.table("<table border='3' cellpadding='5' cellspacing='7'><tr><td>a</td><td>b</td></tr></table>")
        XCTAssertEqual(table.borders.widths, TableModel.Insets(top: 3, right: 3, bottom: 3, left: 3))
        XCTAssertEqual(table.spacing, CGSize(width: 7, height: 7))
        XCTAssertEqual(table.cells[0].padding, TableModel.Insets(top: 5, right: 5, bottom: 5, left: 5))
        XCTAssertEqual(table.cells[0].borders.widths, TableModel.Insets(top: 1, right: 1, bottom: 1, left: 1))
        XCTAssertEqual(table.cells[0].chrome, TableModel.Insets(top: 6, right: 6, bottom: 6, left: 6))
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.cellFrames[0].minX, 10, "the table's border, then the spacing")
        XCTAssertEqual(layout.cellFrames[1].minX - layout.cellFrames[0].maxX, 7)
        XCTAssertEqual(layout.size.width - layout.cellFrames[1].maxX, 10)
        XCTAssertEqual(layout.contentFrames[0].minX - layout.cellFrames[0].minX, 6)
        XCTAssertEqual(layout.size.width, layout.columnWidths.reduce(0, +) + 3 * 7 + 2 * 3)
    }

    /// HTML §15.3.8: a `border` attribute that is not a number is 1; `border="0"` draws nothing.
    func testAnEmptyBorderAttributeIsOneAndZeroIsNone() throws {
        for value in ["", "border", "yes"] {
            let table = try TableCoverage.table("<table border='\(value)'><tr><td>a</td><td>b</td></tr></table>")
            XCTAssertEqual(table.borders.widths, TableModel.Insets(top: 1, right: 1, bottom: 1, left: 1), "border=\(value.debugDescription)")
            XCTAssertEqual(table.cells[0].borders.widths, TableModel.Insets(top: 1, right: 1, bottom: 1, left: 1), "border=\(value.debugDescription)")
        }
        let none = try TableCoverage.table("<table border='0'><tr><td>a</td><td>b</td></tr></table>")
        XCTAssertEqual(none.borders.widths, TableModel.Insets())
        XCTAssertEqual(none.cells[0].borders.widths, TableModel.Insets())
        let plain = try TableCoverage.table("<table><tr><td>a</td><td>b</td></tr></table>")
        XCTAssertEqual(plain.borders.widths, TableModel.Insets())
        XCTAssertEqual(plain.spacing, CGSize(width: 2, height: 2), "the user-agent spacing")
        XCTAssertEqual(plain.cells[0].padding, TableModel.Insets(top: 1, right: 1, bottom: 1, left: 1), "the user-agent padding")
    }

    /// CSS 2.2 §17.6.2: collapsed borders are centred on the grid lines, half inside each cell,
    /// there is no spacing, and the wider of a cell's and the table's border wins at the edge.
    func testCollapsedBordersAreSharedHalfInsideEachCell() throws {
        let table = try TableCoverage.table("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>",
                                            css: "table { border-collapse: collapse; border: 6px solid; border-spacing: 9px; } td { border: 2px dashed; padding: 3px; }")
        XCTAssertTrue(table.collapse)
        XCTAssertEqual(table.spacing, .zero, "border-spacing does not apply")
        XCTAssertEqual(table.cells[0].chrome, TableModel.Insets(top: 6, right: 4, bottom: 4, left: 6), "padding plus half the winning line")
        XCTAssertEqual(table.cells[3].chrome, TableModel.Insets(top: 4, right: 6, bottom: 6, left: 4))
        XCTAssertEqual(table.cells[0].borders.top?.style, .dashed)
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.cellFrames[1].minX, layout.cellFrames[0].maxX, accuracy: 0.01, "cells abut")
        XCTAssertEqual(layout.cellFrames[2].minY, layout.cellFrames[0].maxY, accuracy: 0.01)
        XCTAssertEqual(layout.cellFrames[0].minX, 3, accuracy: 0.01, "half the table's border is outside the first cell")
        XCTAssertEqual(layout.size.width, layout.columnWidths.reduce(0, +) + 6, accuracy: 0.01)
        XCTAssertEqual(layout.size.height, layout.rowHeights.reduce(0, +) + 6, accuracy: 0.01)
    }

    func testBorderSpacingSeparatesCellsHorizontallyAndVertically() throws {
        let table = try TableCoverage.table("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>",
                                            css: "table { border-spacing: 10px 4px; border: 1px solid; } td { border: 2px solid; padding: 0; }")
        XCTAssertEqual(table.spacing, CGSize(width: 10, height: 4))
        XCTAssertEqual(table.cells[0].chrome, TableModel.Insets(top: 2, right: 2, bottom: 2, left: 2), "a separated cell's whole border is its own")
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.cellFrames[0].origin, CGPoint(x: 11, y: 5))
        XCTAssertEqual(layout.cellFrames[1].minX - layout.cellFrames[0].maxX, 10, accuracy: 0.01)
        XCTAssertEqual(layout.cellFrames[2].minY - layout.cellFrames[0].maxY, 4, accuracy: 0.01)
        XCTAssertEqual(layout.size.width, layout.columnWidths.reduce(0, +) + 3 * 10 + 2, accuracy: 0.01)
        XCTAssertEqual(layout.size.height, layout.rowHeights.reduce(0, +) + 3 * 4 + 2, accuracy: 0.01)
        // Row slices tile the table: each after the first starts at the spacing above its cells.
        XCTAssertEqual(layout.rowTops, [0, layout.cellFrames[2].minY - 4, layout.size.height])
    }

    /// CSS 2.2 §17.5.3: a row is as tall as its tallest cell needs, and `height` on a row or a
    /// cell is a minimum.
    func testRowAndCellHeightsAreMinimumsNeverCutoffs() throws {
        let table = try TableCoverage.table("""
        <table><tr height="40"><td height="60">a</td><td>b</td></tr><tr style="height: 30px"><td>c</td><td>d</td></tr>
        <tr height="5"><td height="5">e<br/>f<br/>g</td><td>h</td></tr></table>
        """, css: TableCoverage.bare)
        XCTAssertEqual(table.rows.map(\.height), [40, 30, 5])
        XCTAssertEqual(table.cells[0].height, 60)
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(layout.rowHeights[0], 60)
        XCTAssertEqual(layout.rowHeights[1], 30)
        XCTAssertEqual(layout.rowHeights[2], layout.cellText[4].height, "content taller than the asked height is not cut")
        XCTAssertGreaterThan(layout.rowHeights[2], 40)
    }

    func testBackgroundsComeFromAttributesAndCSSOnTheTableItsRowsAndCells() throws {
        let table = try TableCoverage.table("""
        <table bgcolor="#ffeecc"><tr bgcolor="lime"><td bgcolor="ff0000">a</td><td>b</td></tr>
        <tr class="stripe"><td>c</td><td class="mark">d</td></tr></table>
        """, css: ".stripe { background-color: #eeeeee; } .mark { background: rgb(0, 0, 255); }")
        func rgb(_ color: CGColor?) -> [CGFloat]? { color?.components.map { Array($0.prefix(3)) } }
        XCTAssertEqual(rgb(table.background), [1, 0xEE / 255.0, 0xCC / 255.0])
        XCTAssertEqual(rgb(table.rows[0].background), [0, 1, 0])
        XCTAssertEqual(rgb(table.cells[0].background), [1, 0, 0])
        XCTAssertNil(table.cells[1].background, "a cell shows its row through; it has no colour of its own")
        XCTAssertEqual(rgb(table.rows[1].background), [0xEE / 255.0, 0xEE / 255.0, 0xEE / 255.0])
        XCTAssertEqual(rgb(table.cells[3].background), [0, 0, 1])
    }

    func testLegacyColorAttributesAreHexWithOrWithoutAHashOrABasicName() {
        func rgb(_ value: String?) -> [CGFloat]? { TableContent.color(value).map { [$0.red, $0.green, $0.blue] } }
        XCTAssertEqual(rgb("#ff0000"), [1, 0, 0])
        XCTAssertEqual(rgb("00FF00"), [0, 1, 0])
        XCTAssertEqual(rgb("#00f"), [0, 0, 1])
        XCTAssertEqual(rgb("  Navy "), [0, 0, 128 / 255.0])
        XCTAssertEqual(rgb("grey"), rgb("gray"))
        XCTAssertNil(rgb(nil))
        XCTAssertNil(rgb(""))
        XCTAssertNil(rgb("#12345"))
        XCTAssertNil(rgb("#gggggg"))
        XCTAssertNil(rgb("transparent"))
        XCTAssertNil(rgb("#ff00001"))
    }

    func testDarkAppearanceDropsBookBackgroundsAndDrawsEveryLineInTheRuleColour() throws {
        let body = "<p>Prose</p><table border='2' bgcolor='#ffeecc'><tr bgcolor='yellow'><td bgcolor='red'>a</td><td class='b'>b</td></tr></table>"
        let css = ".b { border: 3px dotted green; background: white; color: navy; }"
        let dark = try TableCoverage.section(body, css: css, typography: NativeTypography(fontSize: 16, isDark: true))
        let light = try TableCoverage.section(body, css: css)
        let table = try XCTUnwrap(TableCoverage.tables(in: dark.string).first), lit = try XCTUnwrap(TableCoverage.tables(in: light.string).first)
        XCTAssertNil(table.background)
        XCTAssertTrue(table.rows.allSatisfy { $0.background == nil })
        XCTAssertTrue(table.cells.allSatisfy { $0.background == nil })
        let rule = ReaderPalette.rule(dark: true).cgColor
        for borders in [table.borders] + table.cells.map(\.borders) {
            for stroke in [borders.top, borders.right, borders.bottom, borders.left] { XCTAssertEqual(stroke?.color, rule) }
        }
        XCTAssertEqual(table.cells[1].borders.top?.style, .dotted, "the line's style and width are the book's")
        XCTAssertEqual(table.cells[1].borders.widths, lit.cells[1].borders.widths)
        XCTAssertNotNil(lit.background)
        XCTAssertNotNil(lit.cells[0].background)
        // Geometry and characters do not depend on the appearance.
        XCTAssertEqual(dark.string.string, light.string.string)
        XCTAssertEqual(table.layout(available: 400, viewportHeight: 600).cellFrames, lit.layout(available: 400, viewportHeight: 600).cellFrames)
        // Plain cell text takes the same ink as the prose around the table.
        let prose = dark.string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor
        let cell = table.cells[0].content.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor
        XCTAssertNotNil(prose)
        XCTAssertEqual(cell, prose)
    }

    func testNowrapCellsAreAsNarrowAsTheirWholeText() throws {
        let table = try TableCoverage.table("""
        <table><tr><td nowrap="nowrap">one two three</td><td style="white-space: nowrap">four five</td><td>six seven</td></tr></table>
        """)
        XCTAssertEqual(table.cells[0].minContent, table.cells[0].maxContent)
        XCTAssertEqual(table.cells[1].minContent, table.cells[1].maxContent)
        XCTAssertLessThan(table.cells[2].minContent, table.cells[2].maxContent)
    }

    // MARK: Direction and placement on the line

    /// CSS 2.2 §17.5: in a right-to-left table "columns are laid out from right to left".
    func testARightToLeftTableRunsItsColumnsFromTheRightEdge() throws {
        let table = try TableCoverage.table("<table dir='rtl'><tr><td>first</td><td>second</td><td>third</td></tr><tr><td colspan='2'>wide</td><td>last</td></tr></table>")
        XCTAssertTrue(table.isRightToLeft)
        XCTAssertEqual(table.cells.map(\.column), [0, 1, 2, 0, 2], "the grid is logical")
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertGreaterThan(layout.cellFrames[0].minX, layout.cellFrames[1].maxX - 0.01)
        XCTAssertGreaterThan(layout.cellFrames[1].minX, layout.cellFrames[2].maxX - 0.01)
        XCTAssertEqual(layout.cellFrames[3].maxX, layout.cellFrames[0].maxX, accuracy: 0.01, "a span starts at its first column's right edge")
        XCTAssertEqual(layout.cellFrames[3].minX, layout.cellFrames[1].minX, accuracy: 0.01)
        XCTAssertEqual(layout.originX + layout.size.width, 400, accuracy: 0.01, "and the table sits at the line's right")
        XCTAssertEqual(TableRowAttachment(table: table, row: 0).textEquivalent, "first\tsecond\tthird", "read in logical order")
    }

    func testATableIsPlacedOnItsLineByAlignAndAutoMargins() throws {
        func table(_ attributes: String, css: String = "") throws -> (TableModel.Alignment, CGFloat, CGFloat) {
            let table = try TableCoverage.table("<table \(attributes)><tr><td>a</td><td>b</td></tr></table>", css: css)
            let layout = table.layout(available: 400, viewportHeight: 600)
            return (table.alignment, layout.originX, layout.size.width)
        }
        var (alignment, origin, width) = try table("")
        XCTAssertEqual(alignment, .start); XCTAssertEqual(origin, 0)
        (alignment, origin, width) = try table("align='center'")
        XCTAssertEqual(alignment, .center); XCTAssertEqual(origin, (400 - width) / 2, accuracy: 0.01)
        (alignment, origin, width) = try table("align='CENTER'")
        XCTAssertEqual(alignment, .center)
        (alignment, origin, width) = try table("align='right'")
        XCTAssertEqual(alignment, .end); XCTAssertEqual(origin, 400 - width, accuracy: 0.01)
        (alignment, origin, width) = try table("", css: "table { margin: 0 auto; }")
        XCTAssertEqual(alignment, .center); XCTAssertEqual(origin, (400 - width) / 2, accuracy: 0.01)
        (alignment, origin, width) = try table("", css: "table { margin-left: auto; }")
        XCTAssertEqual(alignment, .end); XCTAssertEqual(origin, 400 - width, accuracy: 0.01)
        (alignment, origin, width) = try table("dir='rtl' align='left'")
        XCTAssertEqual(origin, 0, accuracy: 0.01, "left is left in a right-to-left table too")
        (alignment, origin, width) = try table("dir='rtl' align='right'")
        XCTAssertEqual(origin, 400 - width, accuracy: 0.01)
    }

    // MARK: Captions

    /// CSS 2.2 §17.4.1: `caption-side` is inherited, so it works on the table too; HTML §15.3.8
    /// maps `align="bottom"` to it.
    func testCaptionSideFromTheCaptionTheTableOrTheAlignAttribute() throws {
        let rows = "<tr><td>a</td><td>b</td></tr>"
        XCTAssertEqual(try TableCoverage.section("<table><caption>Cap</caption>\(rows)</table>").string.string, "Cap\n\u{FFFC}")
        XCTAssertEqual(try TableCoverage.section("<table><caption>Cap</caption>\(rows)</table>", css: "caption { caption-side: bottom; }").string.string, "\u{FFFC}\nCap")
        XCTAssertEqual(try TableCoverage.section("<table><caption>Cap</caption>\(rows)</table>", css: "table { caption-side: bottom; }").string.string, "\u{FFFC}\nCap")
        XCTAssertEqual(try TableCoverage.section("<table><caption align='BOTTOM'>Cap</caption>\(rows)</table>").string.string, "\u{FFFC}\nCap")
        XCTAssertEqual(try TableCoverage.section("<table><caption align='top'>Cap</caption>\(rows)</table>", css: "table { caption-side: bottom; } caption { caption-side: top; }").string.string,
                       "Cap\n\u{FFFC}")
    }

    func testACaptionOfSeveralParagraphsKeepsEachAndStaysWithItsTable() throws {
        let section = try TableCoverage.section("""
        <table><caption><p>Table 3</p><p>Rainfall by month</p></caption><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>
        """)
        XCTAssertEqual(section.string.string, "Table 3\nRainfall by month\n\u{FFFC}\n\u{FFFC}")
        XCTAssertEqual(section.string.attribute(.readerKeepWithNext, at: 0, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(section.string.attribute(.readerKeepWithNext, at: 8, effectiveRange: nil) as? Bool, true, "the last caption line keeps with the first row")
        XCTAssertNil(section.string.attribute(.readerKeepWithNext, at: 26, effectiveRange: nil), "a first body row keeps with nothing")
    }

    func testACaptionIsCentredUnlessTheBookAlignsIt() throws {
        func alignment(_ css: String, attributes: String = "") throws -> NSTextAlignment? {
            let section = try TableCoverage.section("<table \(attributes)><caption>Cap</caption><tr><td>a</td><td>b</td></tr></table>", css: css)
            return (section.string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        XCTAssertEqual(try alignment(""), .center)
        XCTAssertEqual(try alignment("caption { text-align: left; }"), .left)
        XCTAssertEqual(try alignment("caption { text-align: right; }"), .right)
        XCTAssertEqual(try alignment("caption { text-align: end; }"), .right)
        XCTAssertEqual(try alignment("caption { text-align: end; }", attributes: "dir='rtl'"), .left)
    }

    // MARK: What a column asks for

    /// CSS 2.2 §17.5.2.2: a cell's maximum width is its content "without breaking lines other than
    /// where explicit line breaks occur". For a cell holding a table that is the inner table's
    /// own preferred width (`ReaderAttachment.contentWidths().max`), and a horizontal rule asks
    /// for none, so prose beside either gets the room they do not need.
    func testACellHoldingATableOrARuleAsksForItsContentsWidthNotTheWholeLine() throws {
        let prose = "The quick brown fox jumps over the lazy dog while seven wizards quietly hex an amber jukebox near the old mill."
        let table = try TableCoverage.table("<table><tr><td>\(prose)</td><td><table><tr><td>a</td><td>b</td></tr></table></td></tr></table>")
        let inner = try XCTUnwrap(TableCoverage.tables(in: table.cells[1].content).first)
        let needed = inner.constraints.maximumTableWidth + table.cells[1].chrome.horizontal
        XCTAssertEqual(table.constraints.maximum[1], needed, accuracy: 1)
        let layout = table.layout(available: 500, viewportHeight: 600)
        XCTAssertEqual(layout.columnWidths[1], needed, accuracy: 1, "the inner table's column")
        XCTAssertGreaterThan(layout.columnWidths[0], 400, "the prose takes the rest")

        let ruled = try TableCoverage.table("<table><tr><td>Total<hr/>42</td><td>\(prose)</td></tr></table>")
        XCTAssertLessThan(ruled.constraints.maximum[0], 100, "about as wide as its widest word")
        let ruledLayout = ruled.layout(available: 300, viewportHeight: 600)
        XCTAssertLessThan(ruledLayout.columnWidths[0], 100)
        XCTAssertGreaterThan(ruledLayout.columnWidths[1], 190)
    }

    // MARK: Measuring a cell that holds a table

    /// An embedded table contributes its own max-content width, including when its row is
    /// indented, surrounded by prose, or itself holds another table.
    func testACellHoldingATableAsksForItsIntrinsicWidth() throws {
        let inner = "<table><tr><td>alpha</td><td>beta gamma</td></tr><tr><td>c</td><td>d</td></tr></table>"
        for content in [
            inner, "lead in \(inner) and out", "<p>A paragraph first.</p>\(inner)<p>And one after.</p>", "<blockquote>\(inner)</blockquote>",
            "<blockquote>\(inner)</blockquote>\(inner)", "<ul><li>\(inner)</li><li>item</li></ul>", "<div dir='rtl'>\(inner)</div>",
            "<div style='margin: 0 10% 0 3em'>\(inner)</div>",
            "<table><caption>Cap</caption><tr><td>\(inner)</td><td><blockquote>\(inner)</blockquote></td></tr></table>",
        ] {
            let table = try TableCoverage.table("<table><tr><td>\(content)</td><td>x</td></tr></table>")
            let cell = table.cells[0].content
            XCTAssertFalse(TableCoverage.tables(in: cell).isEmpty, content)
            let nested = TableCoverage.tables(in: cell)
            let preferred = nested.map { $0.constraints.maximumTableWidth }.max() ?? 0
            XCTAssertGreaterThanOrEqual(table.cells[0].maxContent, ceil(preferred), content)
            XCTAssertLessThan(table.cells[0].maxContent, 1_000, "A nested row contributes its preferred width, not the 100,000-point measuring line: \(content)")
            XCTAssertEqual(TableMeasure.maximumWidth(cell), table.cells[0].maxContent, content)
        }
    }

    /// String drawing leaves out the lines below the box it measures in, 100,000 points tall.
    /// While a row was measured at the height of its table laid out, a table tall enough put
    /// itself, or what followed it in the cell, out of the cell's width. A row measured without
    /// a height never does: what a cell asks for does not depend on how tall its tables are.
    func testWhatACellAsksForDoesNotDependOnTheHeightOfATableInIt() throws {
        func asked(paragraphs: Int) throws -> CGFloat {
            let tall = String(repeating: "<p style='font-size: 20em'>a</p>", count: paragraphs)
            let table = try TableCoverage.table("<table><tr><td><p>lead</p><table><tr><td>\(tall)</td><td>b</td></tr></table></td><td>x</td></tr></table>")
            let inner = try XCTUnwrap(TableCoverage.tables(in: table.cells[0].content).first)
            // As string drawing sized it: on a line 100,000 points wide and a page of 800.
            let height = TableRowAttachment(table: inner, row: 0).height(width: 100_000, viewportHeight: 800)
            XCTAssertEqual(height > 100_000, paragraphs > 1, "\(paragraphs) paragraphs are \(height) points")
            return table.cells[0].maxContent
        }
        XCTAssertEqual(try asked(paragraphs: 600), try asked(paragraphs: 1))
    }

    /// CPU seconds of this thread: unlike a wall clock, unaffected by other work on the machine.
    private func threadSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    /// Measuring a cell must not lay out the tables in it. Laying one out lays out every table
    /// inside it again, at five scales when a row is taller than a page, so while string drawing
    /// sized the rows themselves a long cell cost about four times as much to build for each
    /// table around it: 400 short paragraphs took 0.1 s of CPU under one table, 4 s under four
    /// and 49 s under six on the machine these tests were written on, and now take 0.05 s under
    /// any number. Tables are grids eight deep, and content written outside a table's cells is
    /// a cell too.
    func testBuildingALongCellCostsNoMoreForEachTableAroundIt() throws {
        let long = String(repeating: "<p>v1 v2</p>", count: 400)
        for (name, innermost) in [("a cell", "<table><tr><td>w</td><td>\(long)</td></tr></table>"),
                                  ("content outside the cells", "<table><tr><td>w</td><td>x</td></tr>\(long)</table>")] {
            func seconds(under depth: Int) throws -> Double {
                var markup = innermost
                for level in 0..<depth { markup = "<table><tr><td>\(markup)</td><td>x\(level)</td></tr></table>" }
                let publication = try TableCoverage.publication(markup)
                return try (0..<3).map { _ in
                    let start = threadSeconds()
                    let section = TableCoverage.section(of: publication)
                    let elapsed = threadSeconds() - start
                    // A fallback to flowing text would cost nothing and prove nothing: every
                    // level is a grid, and the innermost holds the long cell.
                    var table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
                    for _ in 0..<depth { table = try XCTUnwrap(TableCoverage.tables(in: table.cells[0].content).first) }
                    XCTAssertEqual(table.cells.map(\.content.length).max(), 400 * 6 - 1, name)
                    return elapsed
                }.min() ?? 0
            }
            let shallow = try seconds(under: 1), deep = try seconds(under: 4)
            // The three tables added hold one more word each, so the work is the same. Laying
            // the tables out made it 47 times as much.
            XCTAssertLessThan(deep, 4 * shallow, "\(name) under one table took \(shallow) s of CPU and under four \(deep) s")
        }
    }
}
