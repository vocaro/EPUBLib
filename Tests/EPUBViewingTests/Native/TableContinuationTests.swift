import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class TableContinuationTests: XCTestCase {
    @MainActor func testOversizedRowsAndRowspansKeepEveryGlyphAndAccessibleWordOnce() throws {
        let words = (0..<600).map { "word\($0)" }
        for spanning in [false, true] {
            for font in [16.0, 34.0, 60.0] {
                let fixture = try RichFixture("""
                <table id='t' border='1'><tr><td rowspan='\(spanning ? 3 : 1)'>\(words.joined(separator: " "))</td><td>First</td></tr>
                <tr><td>Second</td>\(spanning ? "" : "<td>Other</td>")</tr>
                <tr><td>Third</td>\(spanning ? "" : "<td>Last</td>")</tr></table>
                """, typography: NativeTypography(fontSize: font))
                let text = try XCTUnwrap(fixture.table("t"))
                let rows = RichFixture.attachments(in: text).compactMap { $0 as? TableRowAttachment }
                for width in [120.0, 240.0, 400.0] {
                    let size = CGSize(width: width, height: 400)
                    let layout = rows[0].layout(width: width, viewportHeight: size.height)
                    let fragments = rows.flatMap { layout.fragments(ofRow: $0.row, maximumHeight: size.height - 1) }
                    assertCompleteCells(rows[0].table, layout: layout, fragments: fragments)
                    let paginator = ReaderPaginator(text: text, size: size)
                    let pages = paginator.allPages
                    XCTAssertGreaterThan(pages.count, 1)
                    XCTAssertTrue(pages.allSatisfy { $0.height <= size.height + 0.5 })
                    let spoken = pages.flatMap(\.tableFragments).map { $0.attachment.textEquivalent }.joined(separator: " ")
                    XCTAssertEqual(spoken.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("word") }.map(String.init), words)
                    XCTAssertEqual(paginator.text.string, text.string, "Source offsets remain unchanged")
                    for page in pages {
                        XCTAssertEqual(paginator.text(for: page).length, page.range.length)
                        XCTAssertLessThanOrEqual(page.range.upperBound, text.length)
                    }
                    if pages.count > 1, pages[0].range == pages[1].range { XCTAssertNotEqual(pages[0], pages[1], "Two spread columns distinguish their fragments") }
                }
            }
        }
    }

    @MainActor func testFinalContinuationDrawsTheTailAndScrollRetainsTheFullRow() throws {
        let fixture = try RichFixture("<table id='t'><tr><td>\(Array(repeating: "words", count: 600).joined(separator: " "))</td><td>x</td></tr></table>")
        let text = try XCTUnwrap(fixture.table("t"))
        let row = try XCTUnwrap(RichFixture.attachments(in: text).first as? TableRowAttachment)
        let size = CGSize(width: 300, height: 400)
        XCTAssertGreaterThan(row.height(width: size.width, viewportHeight: size.height), size.height)
        let paginator = ReaderPaginator(text: text, size: size)
        let entries = paginator.allPages.flatMap(\.tableFragments)
        XCTAssertGreaterThan(entries.count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.offset == 0 })
        let last = try XCTUnwrap(entries.last?.attachment)
        let lastSize = CGSize(width: size.width, height: last.height(width: size.width, viewportHeight: size.height))
        let image = try XCTUnwrap(last.image(forBounds: CGRect(origin: .zero, size: lastSize), textContainer: nil, characterIndex: 0))
        let pixels = try XCTUnwrap(RichImageTests.draw(image, size: lastSize, scale: 1))
        XCTAssertGreaterThan(RichTableTests.ink(pixels, columns: 10..<120), 0)
    }

    func testCellTextHasNoFixedHeightCutoff() {
        let text = NSAttributedString(string: String(repeating: "x", count: 6000),
                                      attributes: [.font: PlatformFont.systemFont(ofSize: 400)])
        let layout = TableCellLayout(text, width: 50, viewportHeight: 400)
        XCTAssertGreaterThan(layout.height, 1_000_000)
        XCTAssertEqual(layout.lines.last?.characters.upperBound, text.length)
        XCTAssertEqual(layout.lines.map(\.characters.length).reduce(0, +), text.length)
    }

    @MainActor func testIndentedRowUsesItsMeasuredAttachmentWidth() throws {
        let fixture = try RichFixture("<table id='t'><tr><td>\(String(repeating: "words ", count: 600))</td><td>x</td></tr></table>")
        let text = NSMutableAttributedString(attributedString: try XCTUnwrap(fixture.table("t")))
        let style = NSMutableParagraphStyle()
        style.headIndent = 40; style.firstLineHeadIndent = 40; style.tailIndent = -20
        style.paragraphSpacingBefore = 50
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let paginator = ReaderPaginator(text: text, size: CGSize(width: 300, height: 400))
        let pages = paginator.allPages
        XCTAssertTrue(pages.allSatisfy { $0.height + $0.topSpacing <= 400.5 })
        let entry = try XCTUnwrap(pages.first?.tableFragments.first)
        let layout = entry.attachment.layout(width: 300, viewportHeight: 400)
        XCTAssertEqual(layout.lineWidth * layout.scale, 240, accuracy: 0.5)
    }

    @MainActor func testSearchAndCFIsKeepTheOriginalTableUnitMapping() throws {
        let fixture = try RichFixture("<p>Before</p><table id='t'><tr><td>\(String(repeating: "words ", count: 800))unique tail</td><td>x</td></tr></table><p>After</p>")
        let section = SectionBuilder.build(SectionBuildRequest(publication: fixture.publication, spineIndex: 0,
                                                               typography: fixture.typography, fonts: fixture.fonts, rich: fixture.factory))
        let match = try XCTUnwrap(TextSearch.matches(of: "unique tail", in: section.document, locale: nil).first)
        let start = section.map.location(of: match.start)
        let end = section.map.location(of: match.end, isEnd: true)
        let before = section.string.attributedSubstring(from: NSRange(location: start, length: end - start))
        XCTAssertTrue(before.readerPlainText().contains("unique tail"))
        let cfis = try SpineCFIs(publication: fixture.publication)
        let cfi = cfis.cfi(spineIndex: 0, start: match.start, end: match.end, in: section.document)
        let paginator = ReaderPaginator(text: section.string, size: CGSize(width: 300, height: 400))
        let fragments = paginator.allPages.flatMap(\.tableFragments)
        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertTrue(fragments.allSatisfy { $0.offset >= start && $0.offset < end }, "Original unit highlights cover every continuation")
        let resolved = try XCTUnwrap(cfis.resolve(cfi))
        let restored = try XCTUnwrap(EPUBCFI.resolve(localPath: resolved.localPath, in: section.document))
        XCTAssertEqual(section.map.location(of: restored.start), start)
        XCTAssertEqual(section.map.location(of: restored.end, isEnd: true), end)
        XCTAssertEqual(paginator.text.attributedSubstring(from: NSRange(location: start, length: end - start)).readerPlainText(), before.readerPlainText())
    }

    private func assertCompleteCells(_ table: TableModel, layout: TableLayout, fragments: [TableRowFragment],
                                     file: StaticString = #filePath, line: UInt = #line) {
        for (cell, content) in table.cells.enumerated() {
            let assigned = fragments.flatMap { $0.cells.filter { $0.cell == cell }.flatMap { Array($0.lines) } }
            XCTAssertEqual(assigned, Array(layout.cellText[cell].lines.indices), "Each glyph line belongs to one fragment", file: file, line: line)
            let reproduced = assigned.map { (content.content.string as NSString).substring(with: layout.cellText[cell].lines[$0].characters) }.joined()
            XCTAssertEqual(reproduced, content.content.string, file: file, line: line)
            for fragment in fragments {
                for entry in fragment.cells where entry.cell == cell {
                    for number in entry.lines {
                        let frame = layout.cellText[cell].lines[number].frame.offsetBy(dx: 0, dy: layout.contentFrames[cell].minY - fragment.top)
                        XCTAssertGreaterThanOrEqual(frame.minY, -0.01, file: file, line: line)
                        XCTAssertLessThanOrEqual(frame.maxY, fragment.height + 0.01, file: file, line: line)
                    }
                }
            }
        }
    }
}
