import CoreGraphics
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A table cell narrower than its own content's indent: a list's indent and the cell's padding
/// wider than the column the table gives it. A cell is laid out with TextKit 1, which applies a
/// paragraph's indents itself, so each glyph went on a line of its own past the column with no
/// used rect. The cell measured its first line alone, its row was that short, and once the row
/// was split across pages the lines below its foot were on no page: not drawn, not in Copy and
/// not read by VoiceOver (#569).
@MainActor final class TableNarrowCellTests: XCTestCase {
    private typealias H = BoxLayoutHarness

    /// #569's first reproduction, with the reader's own style sheet.
    static let listInPaddedCell = "<table><tr><td style='padding:0 20px'><ul><li>a wraps the again and.</li></ul></td><td>I below box box wraps.</td></tr></table><p>After.</p>"
    /// #377's section `cells-ua-s7227051-r51.html`, where the narrow cell is in a nested table.
    static let nestedListInPaddedCell = "<table><tr><td>x</td><th><table style='margin-left:40px;'><tr><td style='padding:0 20px;' dir='rtl'><ul style=\"list-style-type:'averyveryverylongstringmarkerthatiswiderthanmostlines ';list-style-position:outside;\"><li style=\"list-style-position:inside;\"><ul style=\"list-style-type:'';text-indent:-500px;\"><li>a wraps the again and.</li></ul></li></ul></td><td>I below box box wraps.</td></tr></table></th></tr></table><p>After.</p>"

    /// Every word of the cell is on some page: in its lines, in its Copy text and in what
    /// VoiceOver reads there, and each of the row's words exactly once across its continuations.
    func testTheReproductionsShowEveryWordOfTheNarrowCellOnSomePage() throws {
        for (label, body, size, font) in [
            ("list in a padded cell, 60 × 90 at 16 pt", Self.listInPaddedCell, CGSize(width: 60, height: 90), CGFloat(16)),
            ("list in a padded cell, 40 × 90 at 9 pt", Self.listInPaddedCell, CGSize(width: 40, height: 90), 9),
            ("#377's nested cell, 60 × 90 at 9 pt", Self.nestedListInPaddedCell, CGSize(width: 60, height: 90), 9),
        ] {
            let section = try H.build(body, css: "", fontSize: font)
            PageTextGeometryTests.assertVisiblePages(section, size: size, label: label)
            let paginator = ReaderPaginator(text: section.string, size: size)
            XCTAssertGreaterThan(paginator.allPages.flatMap(\.tableFragments).count, 1, "\(label): the row is split across pages")
            var copied: [String] = [], spoken: [String] = [], cells: [String] = []
            for page in paginator.allPages {
                let view = H.pageView(paginator, page: page)
                copied += Self.words(view.plainText(in: view.shownCharacters))
                spoken += Self.words(view.spokenText(in: view.shownCharacters))
                for entry in page.tableFragments {
                    cells += entry.attachment.spokenCells(size: size, viewportHeight: size.height).flatMap { Self.words($0.text) }
                }
            }
            for word in ["a", "wraps", "the", "again", "and.", "I", "below", "box", "wraps."] {
                XCTAssertTrue(copied.contains(word), "\(label): \"\(word)\" is in a page's Copy text")
                XCTAssertTrue(spoken.contains(word), "\(label): \"\(word)\" is in what VoiceOver reads on a page")
                XCTAssertTrue(cells.contains(word), "\(label): \"\(word)\" is in a continuation's cells")
            }
        }
    }

    /// The cell keeps the glyph-wide column the reader's other text keeps: its list item's
    /// indent is cut back inside the column, so its lines hold more than a glyph each and none
    /// is drawn in the cell's padding at the column's trailing side, in either direction.
    func testANarrowCellDrawsItsLinesInsideItsColumn() throws {
        for direction in ["ltr", "rtl"] {
            let body = Self.listInPaddedCell.replacingOccurrences(of: "<td style='padding:0 20px'>", with: "<td style='padding:0 20px' dir='\(direction)'>")
            let section = try H.build(body, css: "", fontSize: 16)
            let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
            let row = TableRowAttachment(table: table, row: 0)
            // The whole row, as continuous scroll draws it, for the viewport its image assumes.
            let width: CGFloat = 60, viewport = TableRowAttachment.viewportHeight(nil, width: width)
            let layout = row.layout(width: width, viewportHeight: viewport)
            let style = try XCTUnwrap(table.cells[0].content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertGreaterThan(max(style.headIndent, style.firstLineHeadIndent) - min(0, style.tailIndent), layout.contentFrames[0].width,
                                 "\(direction): the list item's indents are wider than its cell's column")
            let lines = layout.cellText[0].lines
            XCTAssertLessThan(lines.count, table.cells[0].content.length / 2, "\(direction): lines of more than a glyph each: \(lines.map(\.characters))")
            let size = CGSize(width: width, height: row.height(width: width, viewportHeight: viewport))
            let image = try XCTUnwrap(row.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0))
            let pixels = try XCTUnwrap(RichImageTests.draw(image, size: size, scale: 1))
            let content = layout.contentFrames[0], frame = layout.cellFrames[0]
            func columns(_ minX: CGFloat, _ maxX: CGFloat) -> Range<Int> {
                Int(((layout.originX + minX) * layout.scale).rounded(.up))..<Int(((layout.originX + maxX) * layout.scale).rounded(.down))
            }
            XCTAssertGreaterThan(RichTableTests.ink(pixels, columns: columns(content.minX, content.maxX)), 0, "\(direction): the cell's words are drawn in its column")
            XCTAssertEqual(RichTableTests.ink(pixels, columns: columns(content.maxX + 1, frame.maxX)), 0, "\(direction): nothing is drawn in the cell's right padding")
            XCTAssertEqual(RichTableTests.ink(pixels, columns: columns(frame.minX, content.minX - 1)), 0, "\(direction): nothing is drawn in the cell's left padding")
        }
    }

    /// The text TextKit 1 lays out for a cell leaves at least a glyph-wide column in every
    /// paragraph, with its tab stops inside it, keeping the left indent first as the reader's
    /// TextKit 2 text does (`ReaderTextContainer.lineInsets`): the head indent left to right, the
    /// tail indent right to left. Paragraphs whose indents leave room are as they were.
    func testExhaustedIndentsLeaveAGlyphWideColumn() {
        let font = PlatformFont.systemFont(ofSize: 10)
        func paragraph(first: CGFloat, head: CGFloat, tail: CGFloat, direction: NSWritingDirection = .natural,
                       stops: [CGFloat] = []) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = first; style.headIndent = head; style.tailIndent = tail
            style.baseWritingDirection = direction
            style.tabStops = stops.map { NSTextTab(textAlignment: .natural, location: $0) }
            style.defaultTabInterval = 36
            return NSAttributedString(string: "Words\twrap.\n", attributes: [.font: font, .paragraphStyle: style])
        }
        func style(_ text: NSAttributedString) -> NSParagraphStyle { text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle }
        let roomy = paragraph(first: 10, head: 20, tail: -5, stops: [80])
        XCTAssertTrue(ReaderTextContainer.clampingExhaustedIndents(in: roomy, width: 100) === roomy, "a paragraph with room is not copied")
        for direction in [NSWritingDirection.natural, .leftToRight, .rightToLeft] {
            for (width, first, head, tail) in [(CGFloat(25), CGFloat(0), CGFloat(32), CGFloat(0)), (60, 500, 0, 0), (60, 40, 40, -40),
                                               (60, 0, 10, -600), (12, 32, 32, 0), (1, 32, 32, -8)] {
                let source = paragraph(first: first, head: head, tail: tail, direction: direction, stops: [32, 400])
                let clamped = style(ReaderTextContainer.clampingExhaustedIndents(in: source, width: width))
                let available = width - min(width, 20)
                let label = "\(width) wide, indents \(first), \(head), \(tail), direction \(direction.rawValue)"
                XCTAssertLessThanOrEqual(max(clamped.firstLineHeadIndent, clamped.headIndent) - clamped.tailIndent, available + 0.001, label)
                XCTAssertGreaterThanOrEqual(clamped.firstLineHeadIndent, 0, label)
                XCTAssertGreaterThanOrEqual(clamped.headIndent, 0, label)
                XCTAssertLessThanOrEqual(clamped.tailIndent, 0, label)
                if direction == .rightToLeft {
                    XCTAssertEqual(-clamped.tailIndent, min(-tail, available), accuracy: 0.001, "\(label): the tail indent, on the left, is kept first")
                } else {
                    XCTAssertEqual(clamped.headIndent, min(head, available), accuracy: 0.001, "\(label): the head indent, on the left, is kept first")
                    XCTAssertEqual(clamped.firstLineHeadIndent, min(first, available), accuracy: 0.001, label)
                }
                XCTAssertTrue(clamped.tabStops.allSatisfy { $0.location <= max(1, available) + 0.001 }, label)
                XCTAssertLessThanOrEqual(clamped.defaultTabInterval, max(1, available) + 0.001, label)
            }
        }
    }

    // MARK: Generated narrow tables

    private static let vocabulary = ["a", "wraps", "the", "again", "and.", "I", "below", "box", "Disproportionately",
                                     "of", "column", "returns.", "one.", "beside", "x", "wider"]
    private static let markers = ["disc", "decimal", "'averyveryverylongstringmarkerthatiswiderthanmostlines '", "'→ '", "lower-roman", "''"]

    private static func words(_ random: inout SectionContentRandom) -> String {
        (0..<(1 + random.next(6))).map { _ in random.pick(vocabulary) }.joined(separator: " ")
    }

    private static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// A list, as books write them in narrow columns: a marker of any width inside or outside,
    /// an item's own text indent, and lists inside lists.
    private static func list(_ random: inout SectionContentRandom, depth: Int) -> String {
        let tag = random.pick(["ul", "ol"])
        var style = "list-style-type:\(random.pick(markers));list-style-position:\(random.pick(["inside", "outside"]))"
        if random.chance(2) { style += ";text-indent:\(random.pick([-500, -40, 24, 300]))px" }
        if random.chance(3) { style += ";padding-left:\(random.pick([0, 60, 200]))px" }
        var html = "<\(tag) style=\"\(style)\">"
        for _ in 0..<(1 + random.next(2)) {
            html += "<li>" + words(&random) + (depth < 2 && random.chance(3) ? list(&random, depth: depth + 1) : "") + "</li>"
        }
        return html + "</\(tag)>"
    }

    private static func content(_ random: inout SectionContentRandom, depth: Int) -> String {
        switch random.next(depth == 0 ? 6 : 5) {
        case 0: return words(&random)
        case 1, 2: return list(&random, depth: 0)
        case 3: return "<p style='text-indent:\(random.pick([-500, -40, 60, 300]))px'>\(words(&random))</p>"
        case 4: return "<div style='margin-left:\(random.pick([30, 80, 200]))px'>\(random.chance(2) ? list(&random, depth: 1) : words(&random))</div>"
        default: return table(&random, depth: depth + 1)
        }
    }

    /// A table of two or three columns whose cells hold lists, padding and indents, nested or not.
    static func table(_ random: inout SectionContentRandom, depth: Int = 0) -> String {
        var html = "<table"
        if depth > 0, random.chance(2) { html += " style='margin-left:\(random.pick([10, 40]))px'" }
        if random.chance(4) { html += " dir='rtl'" }
        html += ">"
        // A table of one column is a layout box, and its content flows as blocks.
        let columns = 2 + random.next(2)
        for _ in 0..<(1 + random.next(2)) {
            html += "<tr>"
            for _ in 0..<columns {
                let tag = random.chance(4) ? "th" : "td"
                var style = "padding:0 \(random.pick([0, 4, 20, 40]))px"
                if random.chance(3) { style += ";text-indent:\(random.pick([-500, -40, 60, 300]))px" }
                html += "<\(tag) style=\"\(style)\"" + (random.chance(4) ? " dir='rtl'" : "") + ">" + content(&random, depth: depth) + "</\(tag)>"
            }
            html += "</tr>"
        }
        return html + "</table>"
    }

    /// Each cell of `layout` is as tall as its last line reaches, and each of its lines is in
    /// exactly one slice of its rows when they are cut at `maximumHeight`. The same holds for
    /// every table nested in a cell, whose rows the cell holds as lines of its own.
    private func assertEveryLineOnce(_ layout: TableLayout, of table: TableModel, maximumHeight: CGFloat, _ label: String) {
        var nested: [ObjectIdentifier: (layout: TableLayout, table: TableModel, slices: [TableRowFragment])] = [:]
        for (index, cell) in layout.cellText.enumerated() {
            let model = table.cells[index]
            let rowBottom = layout.rowTops[min(table.rows.count, model.row + model.rowSpan)]
            for (number, line) in cell.lines.enumerated() {
                XCTAssertLessThan(line.frame.minY, max(0.01, cell.height), "\(label): cell \(index) line \(number) starts below the cell's height \(cell.height)")
                XCTAssertLessThan(layout.contentFrames[index].minY + line.frame.minY, rowBottom,
                                  "\(label): cell \(index) line \(number) starts below its last row")
                if let row = line.nestedRow, let slice = row.fragment {
                    let inner = row.layout(width: 1, viewportHeight: 1)
                    nested[ObjectIdentifier(row.table), default: (inner, row.table, [])].slices.append(slice)
                }
            }
        }
        var owners = [Int: [Int]]()
        for row in table.rows.indices {
            for slice in layout.fragments(ofRow: row, maximumHeight: maximumHeight) {
                for entry in slice.cells { owners[entry.cell, default: []] += Array(entry.lines) }
            }
        }
        for (index, cell) in layout.cellText.enumerated() {
            XCTAssertEqual(owners[index] ?? [], Array(cell.lines.indices), "\(label): every line of cell \(index) is in exactly one slice")
        }
        for (_, entry) in nested {
            var shown = [Int: [Int]]()
            for slice in entry.slices { for cell in slice.cells { shown[cell.cell, default: []] += Array(cell.lines) } }
            for (index, cell) in entry.layout.cellText.enumerated() {
                XCTAssertEqual(shown[index]?.sorted() ?? [], Array(cell.lines.indices), "\(label): every line of nested cell \(index) is in exactly one of its slices")
            }
            assertEveryLineOnce(entry.layout, of: entry.table, maximumHeight: .greatestFiniteMagnitude, "\(label), nested")
        }
    }

    /// Generated narrow tables at small widths and page heights: every cell is as tall as its
    /// last line, and every line of it is in exactly one continuation.
    func testGeneratedNarrowTablesKeepEveryCellLineInOneContinuation() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["TABLE_NARROW_SECTIONS"] ?? "") ?? 24
        var random = SectionContentRandom(state: UInt64(environment["TABLE_NARROW_SEED"] ?? "") ?? 569)
        for index in 0..<count {
            let markup = Self.table(&random)
            for font: CGFloat in [9, 16] {
                let table = try TableCoverage.table(markup, typography: NativeTypography(fontSize: font))
                for width: CGFloat in [24, 40, 60, 120] {
                    for page: CGFloat in [24, 90, 240] {
                        let layout = table.layout(available: width, viewportHeight: page)
                        autoreleasepool {
                            assertEveryLineOnce(layout, of: table, maximumHeight: max(1, page - 2 * font),
                                                "narrow table \(index) at \(width) × \(page), \(font) pt: \(markup)")
                        }
                    }
                }
            }
        }
    }

    /// The same tables, paginated: every character of the section on a visible line and every
    /// word of each row exactly once across its continuations.
    func testGeneratedNarrowTablesShowEveryWordOnSomePage() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["TABLE_NARROW_SECTIONS"] ?? "") ?? 24
        var random = SectionContentRandom(state: UInt64(environment["TABLE_NARROW_SEED"] ?? "") ?? 569)
        let viewports = [CGSize(width: 24, height: 24), CGSize(width: 40, height: 90), CGSize(width: 60, height: 90),
                         CGSize(width: 90, height: 135), CGSize(width: 180, height: 240)]
        for index in 0..<count {
            let markup = Self.table(&random)
            let size = viewports[index % viewports.count], font: CGFloat = index % 2 == 0 ? 9 : 16
            let section = try H.build(markup + "<p>After.</p>", css: "", fontSize: font)
            autoreleasepool {
                PageTextGeometryTests.assertVisiblePages(section, size: size,
                    label: "narrow table \(index) at \(size.width) × \(size.height), \(font) pt: \(markup)")
            }
        }
    }
}
