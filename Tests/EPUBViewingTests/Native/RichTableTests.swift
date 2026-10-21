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

    private func rows(_ fixture: RichFixture, _ id: String) throws -> [TableRowAttachment] {
        let rows = RichFixture.attachments(in: fixture.table(id)).compactMap { $0 as? TableRowAttachment }
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
        XCTAssertEqual(shrunk.height(ofRow: 0), full.height(ofRow: 0) * shrunk.scale, accuracy: 0.01)
        XCTAssertEqual(shrunk.size.width * shrunk.scale, 200, accuracy: 0.01)
        let narrowest = table.layout(available: 150, viewportHeight: 600)
        XCTAssertEqual(narrowest.scale, TableModel.minimumScale)
        XCTAssertEqual(narrowest.columnWidths.reduce(0, +), 150 / TableModel.minimumScale, accuracy: 0.01)
        XCTAssertEqual(narrowest.columnWidths[0] / narrowest.columnWidths[1], 2, accuracy: 0.001)
        // The attachment fills its line and is as tall as its row.
        let bounds = attachment.layoutBounds(line(200))
        XCTAssertEqual(bounds.width, 200)
        XCTAssertEqual(bounds.height, shrunk.height(ofRow: 0), accuracy: 0.01)
    }

    func testASingleLineTallerThanThePageHasACompleteScaledContinuation() throws {
        let fixture = try fixture("<table id='t'><tr><td>A cell</td><td>Another</td></tr></table>")
        let row = try rows(fixture, "t")[0]
        let table = row.table
        let ordinary = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual(ordinary.scale, 1)
        let short = table.layout(available: 400, viewportHeight: 5)
        XCTAssertEqual(short.scale, ordinary.scale, "a futile page-fit reduction leaves the table at its required width scale")
        XCTAssertTrue(short.cellText.allSatisfy { text in
            text.lines.contains { $0.frame.height * TableModel.minimumScale > 5 }
        }, "the complete glyph lines cannot fit at any allowed table scale")
        XCTAssertGreaterThanOrEqual(short.scale, TableModel.minimumScale)
        XCTAssertGreaterThan(short.height(ofRow: 0), 5, "Still taller than the page at the smallest scale")
        XCTAssertGreaterThan(row.height(width: 400, viewportHeight: 5), 5, "Scroll never clips the row")
        let slices = short.fragments(ofRow: 0, maximumHeight: 5)
        XCTAssertTrue(slices.allSatisfy { $0.height * short.scale * $0.fitScale <= 5.01 })
        XCTAssertTrue(slices.contains { $0.fitScale < 1 }, "One glyph line taller than a page is fitted as a whole")
        for (cell, text) in short.cellText.enumerated() {
            let assigned = slices.flatMap { slice in
                slice.cells.filter { $0.cell == cell }.flatMap { Array($0.lines) }
            }
            XCTAssertEqual(assigned, Array(text.lines.indices), "every complete glyph line belongs to exactly one continuation")
        }
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
        let rows = RichFixture.attachments(in: text).compactMap { $0 as? TableRowAttachment }
        let table = try XCTUnwrap(rows.first?.table)
        XCTAssertEqual(table.groups, [0..<2, 2..<4, 4..<5, 5..<7, 7..<8, 8..<9])
        XCTAssertEqual(rows.map(\.row), Array(0..<9), "An attachment per row")
        XCTAssertEqual(table.keepsWithNext, [true, true, true, false, false, true, false, false, false],
                       "Rows a rowspan joins, and the header, keep with the next")
        XCTAssertEqual(table.cells.last?.text, "F2", "The footer goes last")
        XCTAssertEqual(table.cells.first { $0.text == "i" }?.rowSpan, 1, "rowspan=0 is one row, as in WebKit")
        XCTAssertEqual(table.cells.first { $0.text == "j" }?.rowSpan, 1, "A rowspan ends with its row group")
        // One paragraph per row, no spacing between.
        XCTAssertEqual(text.string, Array(repeating: "\u{FFFC}", count: 9).joined(separator: "\n"))
        for (row, keeps) in table.keepsWithNext.enumerated() {
            XCTAssertEqual(text.attribute(.readerKeepWithNext, at: row * 2, effectiveRange: nil) as? Bool, keeps ? true : nil)
        }
        // Selections and copies get the cells: tabs between cells, line breaks between rows.
        XCTAssertEqual(text.readerPlainText(), "H1\tH2\nh1\th2\na\tb\nc\nd\te\nf\tg\nh\ni\tj\nF1\tF2")
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.paragraphSpacing, 0)
        XCTAssertEqual(paragraph.paragraphSpacingBefore, 0)
        // Rows stack without gaps; a spanning cell is drawn in each row it covers.
        let layout = table.layout(available: 400, viewportHeight: 600)
        XCTAssertEqual((0..<9).map(layout.height(ofRow:)).reduce(0, +), layout.size.height, accuracy: 0.01)
        XCTAssertEqual(rows[4].textEquivalent, "d\te")
        XCTAssertEqual(rows[3].textEquivalent, "c", "A spanning cell reads in its first row")
        let spanning = try XCTUnwrap(table.cells.firstIndex { $0.text == "a" })
        XCTAssertTrue(table.rowCells[3].contains(spanning))
        XCTAssertEqual(layout.frame(ofCell: spanning, inRow: 3).minY, -layout.height(ofRow: 2), accuracy: 0.01)
        XCTAssertTrue(table.cells.filter { $0.row < 2 }.allSatisfy(\.isHeader))
    }

    @MainActor func testARowspanOverEveryRowStillBreaksBetweenRows() throws {
        let count = 300
        let markup = (0..<count).map { row in
            "<tr>\(row == 0 ? "<td rowspan='\(count)'>Spanning every row</td>" : "")<td>Row \(row)</td></tr>"
        }.joined()
        let fixture = try fixture("<table id='t' border='1'>\(markup)</table>")
        let text = try XCTUnwrap(fixture.table("t"))
        let rows = RichFixture.attachments(in: text).compactMap { $0 as? TableRowAttachment }
        XCTAssertEqual(rows.count, count, "Every row is its own attachment, rowspan or not")
        let table = rows[0].table
        XCTAssertEqual(table.groups, [0..<count])
        let size = CGSize(width: 400, height: 600)
        let layout = table.layout(available: size.width, viewportHeight: size.height)
        XCTAssertEqual(layout.scale, 1, "Each row fits a page, so nothing shrinks")
        XCTAssertGreaterThan(layout.size.height, size.height * 5)
        // The group is kept together only as far as a page holds; pages break between rows.
        let pages = ReaderPaginator(text: text, size: size).allPages
        XCTAssertGreaterThan(pages.count, 5)
        for page in pages {
            XCTAssertLessThanOrEqual(page.height, size.height + 0.5)
            XCTAssertEqual(page.range.location % 2, 0, "Starts at a row")
        }
        // A row far from the spanning cell's start still draws its part: the cell's borders.
        let middle = rows[count / 2]
        let rowSize = CGSize(width: size.width, height: middle.height(width: size.width, viewportHeight: size.height))
        let image = try XCTUnwrap(middle.image(forBounds: CGRect(origin: .zero, size: rowSize), textContainer: nil, characterIndex: 0))
        let pixels = try XCTUnwrap(RichImageTests.draw(image, size: rowSize, scale: 1))
        XCTAssertGreaterThan(Self.ink(pixels, columns: 0..<12), 0, "The spanning cell's left border")
    }

    @MainActor func testARowTallerThanAPageContinuesAcrossPages() throws {
        let long = Array(repeating: "words", count: 600).joined(separator: " ")
        let fixture = try fixture("<table id='t'><tr><td>\(long)</td><td>x</td></tr><tr><td>a</td><td>b</td></tr></table>")
        let text = try XCTUnwrap(fixture.table("t"))
        let rows = RichFixture.attachments(in: text).compactMap { $0 as? TableRowAttachment }
        let size = CGSize(width: 300, height: 400)
        XCTAssertGreaterThan(rows[0].height(width: size.width, viewportHeight: size.height), size.height)
        let paginator = ReaderPaginator(text: text, size: size)
        let pages = paginator.allPages
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(paginator.text.string, text.string)
        XCTAssertEqual(paginator.pageIndex(containing: 0), 0)
        for page in pages { XCTAssertEqual(paginator.text(for: page).length, page.range.length) }
        XCTAssertTrue(pages.allSatisfy { $0.height <= size.height + 0.5 })
    }

    /// Dark pixels in a range of an image's pixel columns.
    static func ink(_ image: CGImage, columns: Range<Int>) -> Int {
        let width = image.width, height = image.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in 0..<height {
            for x in columns where x < width {
                let index = (y * width + x) * 4
                if pixels[index + 3] > 128, pixels[index] < 160 { count += 1 }
            }
        }
        return count
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
        <table id="b" border="1" cellpadding="4" cellspacing="0" bgcolor="#ffeecc"><tr><td>a</td><td bgcolor="red">b</td></tr></table>
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
        XCTAssertEqual(centred.frame(ofCell: 0, inRow: 0).minX, 125)
    }

    func testNestedTablesAreRowsInsideCells() throws {
        let fixture = try fixture("""
        <table id="t"><tr><td><table id="n2"><tr><td>x</td><td>y</td></tr></table></td><td>z</td></tr></table>
        """)
        let outer = try rows(fixture, "t")[0].table
        let nested = RichFixture.attachments(in: outer.cells[0].content)
        XCTAssertEqual(nested.count, 1)
        XCTAssertTrue(nested[0] is TableRowAttachment)
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
        // Viewport units are of the reading viewport, not of the rule's own line.
        let viewportFixture = try RichFixture("<hr id='min'/><hr id='max'/><hr id='tall'/>")
        viewportFixture.overrides["min"] = { $0.width = .viewportMin(50) }
        viewportFixture.overrides["max"] = { $0.width = .viewportMax(50) }
        viewportFixture.overrides["tall"] = { $0.width = .viewportHeight(50) }
        func viewportRule(_ id: String) throws -> ReaderRuleAttachment {
            let element = viewportFixture.element(id)
            let text = viewportFixture.factory.horizontalRule(element, style: viewportFixture.style(of: element), context: viewportFixture.context)
            return try XCTUnwrap(RichFixture.attachments(in: text).first as? ReaderRuleAttachment)
        }
        let landscape = CGSize(width: 700, height: 400)
        XCTAssertEqual(try viewportRule("min").ruleRect(in: bounds.size, viewport: landscape).width, 200, accuracy: 0.01)
        XCTAssertEqual(try viewportRule("max").ruleRect(in: bounds.size, viewport: landscape).width, 350, accuracy: 0.01)
        XCTAssertEqual(try viewportRule("tall").ruleRect(in: bounds.size, viewport: landscape).width, 200, accuracy: 0.01)
        XCTAssertEqual(try viewportRule("max").ruleRect(in: bounds.size, viewport: CGSize(width: 300, height: 1000)).width, 400,
                       accuracy: 0.01, "never wider than its line")
        // Drawn, it takes the viewport from its text container: 200 points centred on a 600-point line.
        let container = ReaderTextContainer(size: CGSize(width: 600, height: 0))
        container.viewportSize = landscape
        let drawSize = CGSize(width: 600, height: 20)
        func alpha(_ container: NSTextContainer?, x: Int) throws -> UInt8 {
            let image = try XCTUnwrap(viewportRule("min").image(forBounds: CGRect(origin: .zero, size: drawSize), textContainer: container,
                                                                characterIndex: 0))
            return RichImageTests.rgba(try XCTUnwrap(RichImageTests.draw(image, size: drawSize, scale: 1)), x: x, y: 10)[3]
        }
        XCTAssertGreaterThan(try alpha(container, x: 210), 0)
        XCTAssertEqual(try alpha(container, x: 190), 0)
        XCTAssertEqual(try alpha(nil, x: 210), 0, "with no viewport, of its own 600 × 20 bounds: 10 points")
        let dark = try RichFixture("<hr id='r'/>", typography: NativeTypography(fontSize: 16, isDark: true))
        let element = dark.element("r")
        let darkRule = try XCTUnwrap(RichFixture.attachments(in: dark.factory.horizontalRule(element, style: dark.style(of: element),
                                                                                             context: dark.context)).first as? ReaderRuleAttachment)
        XCTAssertEqual(darkRule.color, ReaderPalette.rule(dark: true))
    }
}
