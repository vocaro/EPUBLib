import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class RichTableTests: XCTestCase {
    /// Images of known widths make min- and max-content exact.
    private static let images: [String: Data] = [30, 50, 100, 150, 300].reduce(into: [:]) {
        $0["w\($1).png"] = RichFixture.image(width: $1, height: 10)
    }

    private func fixture(_ body: String, typography: NativeTypography = .init(fontSize: 16)) throws -> RichFixture {
        let fixture = try RichFixture(body, files: Self.images, typography: typography)
        for id in ["t", "p", "w", "f", "g", "c", "d", "r", "n"] { fixture.overrides[id] = { $0.borderSpacing = .zero } }
        return fixture
    }

    private func rows(_ fixture: RichFixture, _ id: String) throws -> [TableRowsAttachment] {
        let rows = RichFixture.attachments(in: fixture.table(id)).compactMap { $0 as? TableRowsAttachment }
        XCTAssertFalse(rows.isEmpty)
        return rows
    }

    private func cell(_ width: Int) -> String { "<td><img src='w\(width).png'/></td>" }

    // MARK: Column widths

    func testColumnWidthsHonourSpansAndContent() throws {
        let fixture = try fixture("""
        <table id="t"><tr>\(cell(100))\(cell(50))\(cell(30))</tr><tr><td colspan="2"><img src="w300.png"/></td>\(cell(30))</tr></table>
        """)
        let table = try rows(fixture, "t")[0].table
        XCTAssertEqual(table.columnCount, 3)
        // The spanning cell's 300 is spread over its columns in proportion to their widths.
        XCTAssertEqual(table.constraints.minimum, [200, 100, 30])
        XCTAssertEqual(table.constraints.maximum, [200, 100, 30])
        let wide = table.layout(available: 1000, viewportHeight: 600)
        XCTAssertEqual(wide.columnWidths, [200, 100, 30])
        XCTAssertEqual(wide.size.width, 330)
        XCTAssertEqual(wide.scale, 1)
        XCTAssertEqual(wide.cellFrames[3], CGRect(x: 0, y: wide.rowHeights[0], width: 300, height: wide.rowHeights[1]))
    }

    func testPercentFixedAndSpecifiedWidths() throws {
        let fixture = try fixture("""
        <table id="p"><tr><td width="50%"><img src="w50.png"/></td>\(cell(150))</tr></table>
        <table id="f"><tr><td width="80"><img src="w50.png"/></td>\(cell(50))</tr></table>
        <table id="w" width="400"><tr>\(cell(100))\(cell(50))</tr></table>
        """)
        // A 50% column gets half of the width the other column's content asks for.
        XCTAssertEqual(try rows(fixture, "p")[0].table.layout(available: 1000, viewportHeight: 600).columnWidths, [150, 150])
        XCTAssertEqual(try rows(fixture, "f")[0].table.layout(available: 1000, viewportHeight: 600).columnWidths, [80, 50])
        let specified = try rows(fixture, "w")[0].table.layout(available: 1000, viewportHeight: 600).columnWidths
        XCTAssertEqual(specified[0], 400 * 2 / 3, accuracy: 0.01)
        XCTAssertEqual(specified[1], 400 / 3, accuracy: 0.01)
        // Never wider than the line, even when asked to be.
        XCTAssertEqual(try rows(fixture, "w")[0].table.layout(available: 300, viewportHeight: 600).size.width, 300, accuracy: 0.01)
    }

    func testTablesWiderThanTheLineShrinkTheirTextThenWrapByCharacter() throws {
        let fixture = try fixture("<table id='t'><tr>\(cell(100))\(cell(50))\(cell(30))</tr><tr><td colspan='2'><img src='w300.png'/></td>\(cell(30))</tr></table>")
        let attachment = try rows(fixture, "t")[0]
        let table = attachment.table
        let full = table.layout(available: 1000, viewportHeight: 600)
        let shrunk = table.layout(available: 200, viewportHeight: 600)
        XCTAssertEqual(shrunk.scale, 200 / 330, accuracy: 0.001)
        XCTAssertEqual(shrunk.columnWidths, [200, 100, 30], "Laid out at full width, drawn smaller")
        XCTAssertEqual(shrunk.height(ofUnit: 0), full.height(ofUnit: 0) * shrunk.scale, accuracy: 0.01)
        XCTAssertEqual(shrunk.size.width * shrunk.scale, 200, accuracy: 0.01)
        let narrowest = table.layout(available: 150, viewportHeight: 600)
        XCTAssertEqual(narrowest.scale, TableModel.minimumScale)
        XCTAssertEqual(narrowest.columnWidths.reduce(0, +), 150 / TableModel.minimumScale, accuracy: 0.01)
        XCTAssertEqual(narrowest.columnWidths[0] / narrowest.columnWidths[1], 2, accuracy: 0.001)
        // The attachment fills its line and is as tall as its unit.
        let bounds = attachment.layoutBounds(line(200))
        XCTAssertEqual(bounds.width, 200)
        XCTAssertEqual(bounds.height, shrunk.height(ofUnit: 0), accuracy: 0.01)
    }

    func testARowUnitTallerThanThePageShrinksTheTable() throws {
        let fixture = try fixture("<table id='t'><tr><td>A cell</td><td>Another</td></tr></table>")
        let table = try rows(fixture, "t")[0].table
        XCTAssertEqual(table.layout(available: 400, viewportHeight: 600).scale, 1)
        let short = table.layout(available: 400, viewportHeight: 5)
        XCTAssertLessThan(short.scale, 1)
        XCTAssertGreaterThanOrEqual(short.scale, TableModel.minimumScale)
    }

    func testMinimumContentIsTheWidestWord() throws {
        let font = PlatformFont.systemFont(ofSize: 16)
        let text = NSAttributedString(string: "a tremendously long-winded cell", attributes: [.font: font])
        let widest = NSAttributedString(string: "tremendously", attributes: [.font: font]).size().width
        XCTAssertEqual(TableMeasure.minimumWidth(text), ceil(widest), accuracy: 1)
        XCTAssertEqual(TableMeasure.maximumWidth(text), ceil(text.size().width), accuracy: 1)
        XCTAssertEqual(TableMeasure.minimumWidth(NSAttributedString()), 0)
    }

    // MARK: Structure

    func testRowUnitsKeepRowspansAndHeadersTogether() throws {
        let fixture = try fixture("""
        <table id="g"><thead><tr><th>H1</th><th>H2</th></tr><tr><th>h1</th><th>h2</th></tr></thead>
        <tfoot><tr><td>F1</td><td>F2</td></tr></tfoot>
        <tbody><tr><td rowspan="2">a</td><td>b</td></tr><tr><td>c</td></tr><tr><td>d</td><td>e</td></tr>
        <tr><td>f</td><td rowspan="2">g</td></tr><tr><td>h</td></tr><tr><td rowspan="0">i</td><td rowspan="9">j</td></tr></tbody></table>
        """)
        let text = try XCTUnwrap(fixture.table("g"))
        let rows = RichFixture.attachments(in: text).compactMap { $0 as? TableRowsAttachment }
        let table = try XCTUnwrap(rows.first?.table)
        XCTAssertEqual(table.units, [0..<2, 2..<4, 4..<5, 5..<7, 7..<8, 8..<9])
        XCTAssertEqual(rows.map(\.unit), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(table.cells.last?.text, "F2", "The footer goes last")
        XCTAssertEqual(table.cells.first { $0.text == "i" }?.rowSpan, 1, "rowspan=0 is one row, as in WebKit")
        XCTAssertEqual(table.cells.first { $0.text == "j" }?.rowSpan, 1, "A rowspan ends with its row group")
        // One paragraph per unit, no spacing between, the header kept with what follows.
        XCTAssertEqual(text.string, Array(repeating: "\u{FFFC}", count: 6).joined(separator: "\n"))
        XCTAssertEqual(text.attribute(.readerKeepWithNext, at: 0, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(text.attribute(.readerKeepWithNext, at: 2, effectiveRange: nil))
        // Selections and copies get the cells: tabs between cells, line breaks between rows.
        XCTAssertEqual(text.readerPlainText(), "H1\tH2\nh1\th2\na\tb\nc\nd\te\nf\tg\nh\ni\tj\nF1\tF2")
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.paragraphSpacing, 0)
        XCTAssertEqual(paragraph.paragraphSpacingBefore, 0)
        // Units stack without gaps.
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual((0..<6).map(layout.height(ofUnit:)).reduce(0, +), layout.size.height, accuracy: 0.01)
        XCTAssertEqual(rows[2].accessibilityCells(size: CGSize(width: 400, height: layout.height(ofUnit: 2)), viewportHeight: 600).map(\.text),
                       ["d", "e"])
        let header = rows[0].accessibilityCells(size: CGSize(width: 400, height: layout.height(ofUnit: 0)), viewportHeight: 600)
        XCTAssertEqual(header.map(\.text), ["H1", "H2", "h1", "h2"])
        XCTAssertTrue(header.allSatisfy(\.isHeader))
        XCTAssertEqual(header[2].frame.minY, layout.rowHeights[0], accuracy: 0.01)
    }

    func testCaptionsAreParagraphsOnTheirSide() throws {
        let fixture = try fixture("""
        <table id="c"><caption>Table 2.5 Distribution of Cases</caption><tr><td>a</td><td>b</td></tr></table>
        <table id="b"><caption id="bc">Below</caption><tr><td>a</td><td>b</td></tr></table>
        <table id="d"><caption align="bottom">Also below</caption><tr><td>a</td><td>b</td></tr></table>
        """)
        fixture.overrides["bc"] = { $0.captionSide = .bottom }
        let top = try XCTUnwrap(fixture.table("c"))
        XCTAssertEqual(top.string, "Table 2.5 Distribution of Cases\n\u{FFFC}")
        XCTAssertEqual(top.attribute(.readerKeepWithNext, at: 0, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(top.readerPlainText(), "Table 2.5 Distribution of Cases\na\tb")
        let style = try XCTUnwrap(top.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .center)
        XCTAssertGreaterThan(style.paragraphSpacing, 0)
        XCTAssertEqual(try XCTUnwrap(fixture.table("b")).string, "\u{FFFC}\nBelow")
        XCTAssertEqual(try XCTUnwrap(fixture.table("d")).string, "\u{FFFC}\nAlso below")
    }

    func testOneColumnTablesFlowAsText() throws {
        let fixture = try fixture("<table id='n'><tr><td>Tip: file early.</td></tr><tr><td>More</td></tr></table>")
        XCTAssertNil(fixture.table("n"))
    }

    func testPresentationalHintsAndCollapsedBorders() throws {
        let fixture = try fixture("""
        <table id="b" border="1" cellpadding="4" cellspacing="0" bgcolor="#ffeecc"><tr><td>\(String("a"))</td><td bgcolor="red">b</td></tr></table>
        <table id="c"><tr><td id="x">a</td><td>b</td></tr></table>
        """)
        let hinted = try rows(fixture, "b")[0].table
        XCTAssertEqual(hinted.spacing, .zero)
        XCTAssertEqual(hinted.borders.widths, TableModel.Insets(top: 1, right: 1, bottom: 1, left: 1))
        XCTAssertEqual(hinted.cells[0].padding, TableModel.Insets(top: 4, right: 4, bottom: 4, left: 4))
        XCTAssertEqual(hinted.cells[0].borders.widths, TableModel.Insets(top: 1, right: 1, bottom: 1, left: 1))
        XCTAssertEqual(hinted.cells[0].chrome.horizontal, 10)
        XCTAssertNotNil(hinted.background)
        XCTAssertNotNil(hinted.cells[1].background)
        fixture.overrides["c"] = {
            $0.borderCollapse = true
            $0.border = .init(ComputedStyle.Border(width: 2, style: .solid))
        }
        fixture.overrides["x"] = {
            $0.border = .init(ComputedStyle.Border(width: 4, style: .solid))
            $0.padding = .init(.points(3))
        }
        let collapsed = try rows(fixture, "c")[0].table
        XCTAssertTrue(collapsed.collapse)
        // Half of each shared line is inside the cell: its own 4 on every side.
        XCTAssertEqual(collapsed.cells[0].chrome, TableModel.Insets(top: 5, right: 5, bottom: 5, left: 5))
        // The second cell has no border: only the table's outer lines.
        XCTAssertEqual(collapsed.cells[1].chrome, TableModel.Insets(top: 1, right: 1, bottom: 1, left: 0))
    }

    func testDarkAppearanceDropsBookBackgroundsAndUsesTheReaderRuleColor() throws {
        let fixture = try fixture("<table id='b' border='1' bgcolor='#ffeecc'><tr><td bgcolor='red'>a</td><td>b</td></tr></table>",
                                  typography: NativeTypography(fontSize: 16, isDark: true))
        let table = try rows(fixture, "b")[0].table
        XCTAssertNil(table.background)
        XCTAssertNil(table.cells[0].background)
        XCTAssertEqual(table.cells[0].borders.top?.color, ReaderPalette.rule(dark: true).cgColor)
    }

    func testRightToLeftAndCentredTables() throws {
        let fixture = try fixture("""
        <table id="r"><tr>\(cell(100))\(cell(50))</tr></table><table id="c" align="center"><tr>\(cell(100))\(cell(50))</tr></table>
        """)
        fixture.overrides["r"] = { $0.direction = .rtl; $0.borderSpacing = .zero }
        let rtl = try rows(fixture, "r")[0].table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(rtl.cellFrames[0].maxX, 150, "The first column is on the right")
        XCTAssertEqual(rtl.originX, 250, "And the table starts at the line's right edge")
        let centred = try rows(fixture, "c")[0].table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(centred.originX, 125)
        XCTAssertEqual(centred.frame(ofCell: 0, inUnit: 0).minX, 125)
    }

    func testNestedTablesAreDrawnAsImagesInsideCells() throws {
        let fixture = try fixture("""
        <table id="t"><tr><td><table id="n2"><tr><td>x</td><td>y</td></tr></table></td><td>z</td></tr></table>
        """)
        let outer = try rows(fixture, "t")[0].table
        let nested = RichFixture.attachments(in: outer.cells[0].content)
        XCTAssertEqual(nested.count, 1)
        XCTAssertTrue(nested[0] is TableRowsImageAttachment)
        XCTAssertGreaterThan(outer.constraints.minimum[0], 0)
    }

    // MARK: Rules

    func testRulesAreAThinCentredLineInTheReaderColor() throws {
        let fixture = try RichFixture("<hr id='plain'/><hr id='short'/><hr id='left'/>")
        fixture.overrides["short"] = { $0.width = .percent(65) }
        fixture.overrides["left"] = { $0.width = .points(100); $0.margin.left = .points(0); $0.margin.right = .auto }
        func rule(_ id: String, dark: Bool = false) throws -> ReaderRuleAttachment {
            let element = fixture.element(id)
            let text = fixture.factory.horizontalRule(element, style: fixture.style(of: element), context: fixture.context)
            XCTAssertEqual(text.length, 1)
            XCTAssertEqual(text.readerPlainText(), "")
            return try XCTUnwrap(RichFixture.attachments(in: text).first as? ReaderRuleAttachment)
        }
        let font = PlatformFont.systemFont(ofSize: 16)
        let plain = try rule("plain")
        let bounds = plain.layoutBounds(line(400, font: font))
        XCTAssertEqual(bounds, CGRect(x: 0, y: font.descender, width: 400, height: font.ascender - font.descender))
        XCTAssertEqual(plain.ruleRect(in: bounds.size).width, 400)
        XCTAssertEqual(plain.ruleRect(in: bounds.size).height, 1)
        XCTAssertEqual(plain.color, ReaderPalette.rule(dark: false))
        let short = try rule("short").ruleRect(in: bounds.size)
        XCTAssertEqual(short.width, 260, accuracy: 0.01)
        XCTAssertEqual(short.midX, 200, accuracy: 0.01)
        XCTAssertEqual(try rule("left").ruleRect(in: bounds.size).minX, 0)
        let dark = try RichFixture("<hr id='r'/>", typography: NativeTypography(fontSize: 16, isDark: true))
        let element = dark.element("r")
        let darkRule = try XCTUnwrap(RichFixture.attachments(in: dark.factory.horizontalRule(element, style: dark.style(of: element),
                                                                                             context: dark.context)).first as? ReaderRuleAttachment)
        XCTAssertEqual(darkRule.color, ReaderPalette.rule(dark: true))
    }
}
