import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tables built by the real pipeline (the book's CSS, the user-agent sheet and `NativeRichContent`),
/// read back as the slot grid the HTML table model describes.
enum TableCoverage {
    static func publication(_ body: String, css: String = "", files: [String: Data] = [:]) throws -> EPUBPublication {
        try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css), files: files)
    }

    static func section(_ body: String, css: String = "", files: [String: Data] = [:],
                        typography: NativeTypography = .init(fontSize: 16)) throws -> SectionText {
        section(of: try publication(body, css: css, files: files), typography: typography)
    }

    static func section(of publication: EPUBPublication, typography: NativeTypography = .init(fontSize: 16)) -> SectionText {
        SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0, typography: typography,
                                                 fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
    }

    /// The source offset of a table's row in its section.
    static func offset(ofRow row: Int, in table: TableModel, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try XCTUnwrap(table.sourceRowOffsets[row], "row \(row) has no source offset", file: file, line: line)
    }

    /// A position `offset` UTF-16 units into the cell reading `text`.
    static func position(in table: TableModel, cell text: String, offset: Int,
                         file: StaticString = #filePath, line: UInt = #line) throws -> ReaderTextPosition {
        let index = try cell(text, in: table, file: file, line: line)
        return ReaderTextPosition(section: 0, offset: try self.offset(ofRow: table.cells[index].row, in: table, file: file, line: line),
                                  tableCell: ReaderTablePosition(table: table.sourceOrder, cell: index, offset: offset))
    }

    /// The section's tables in document order (a nested table is inside its cell, not listed).
    static func tables(in text: NSAttributedString) -> [TableModel] {
        var found: [TableModel] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let row = value as? TableRowAttachment, !found.contains(where: { $0 === row.table }) { found.append(row.table) }
        }
        return found
    }

    static func table(_ body: String, css: String = "", files: [String: Data] = [:],
                      typography: NativeTypography = .init(fontSize: 16),
                      file: StaticString = #filePath, line: UInt = #line) throws -> TableModel {
        let section = try section(body, css: css, files: files, typography: typography)
        return try XCTUnwrap(tables(in: section.string).first, "the markup built no table", file: file, line: line)
    }

    /// Each row's cells that start in it, by column: `text@column` with `xN` for a column span
    /// and `/N` for a row span.
    static func grid(_ table: TableModel) -> [[String]] {
        table.rows.indices.map { row in
            table.cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map { cell in
                "\(cell.text)@\(cell.column)" + (cell.columnSpan > 1 ? "x\(cell.columnSpan)" : "") + (cell.rowSpan > 1 ? "/\(cell.rowSpan)" : "")
            }
        }
    }

    /// The cell whose spoken text is `text`.
    static func cell(_ text: String, in table: TableModel, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try XCTUnwrap(table.cells.firstIndex { $0.text == text }, "no cell reads \(text)", file: file, line: line)
    }

    /// A solid image `width` points wide, so a cell's min- and max-content widths are exact.
    static func images(_ widths: [Int], height: Int = 10) -> [String: Data] {
        widths.reduce(into: [:]) { $0["w\($1).png"] = RichFixture.image(width: $1, height: height) }
    }

    /// A cell holding only an image `width` wide.
    static func box(_ width: Int, _ attributes: String = "") -> String { "<td \(attributes)><img src='w\(width).png' alt=''/></td>" }

    /// Zero padding and spacing, so column widths are the images' own.
    static let bare = "table { border-spacing: 0; } td, th { padding: 0; }"
}
