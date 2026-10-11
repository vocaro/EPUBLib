import CoreGraphics
import XCTest
@testable import EPUBViewing

/// Generated tables: whatever spans and groups a book writes, the model is the slot grid of
/// HTML §4.9.12 as browsers render it (the header first, the footer last, row spans ending with
/// their group, `rowspan="0"` one row), and every layout of it holds together.
final class TableCoverageRandomTests: XCTestCase {
    /// SplitMix64: the same tables on every run and platform.
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    private struct Written {
        var name: String, colspan: String?, rowspan: String?
    }
    private struct Group {
        var tag: String?
        var rows: [[Written]]
    }

    /// Spans as books write them, valid or not; nil leaves the attribute out.
    private static let spans: [String?] = [nil, nil, nil, nil, "1", "2", "2", "3", "4", "0", "-1", "", "x", "07", "+2"]

    private func value(_ span: String?) -> Int { max(1, span.flatMap { Int($0) } ?? 1) }

    private func generate(_ generator: inout Generator) -> [Group] {
        var groups: [Group] = []
        var serial = 0
        let tags: [String?] = generator.chance(40) ? [nil] : ["tfoot", "tbody", "thead", "tbody", nil, "tbody"].filter { _ in generator.chance(60) }
        for tag in tags.isEmpty ? [nil] : tags {
            var rows: [[Written]] = []
            for _ in 0..<(1 + generator.below(4)) {
                var row: [Written] = []
                for _ in 0..<(generator.chance(8) ? 0 : 1 + generator.below(4)) {
                    row.append(Written(name: "c\(serial)", colspan: Self.spans[generator.below(Self.spans.count)], rowspan: Self.spans[generator.below(Self.spans.count)]))
                    serial += 1
                }
                rows.append(row)
            }
            groups.append(Group(tag: tag, rows: rows))
        }
        return groups
    }

    private func markup(_ groups: [Group]) -> String {
        var text = "<table>"
        for group in groups {
            if let tag = group.tag { text += "<\(tag)>" }
            for row in group.rows {
                text += "<tr>" + row.map { cell in
                    "<td" + (cell.colspan.map { " colspan='\($0)'" } ?? "") + (cell.rowspan.map { " rowspan='\($0)'" } ?? "") + ">\(cell.name)</td>"
                }.joined() + "</tr>"
            }
            if let tag = group.tag { text += "</\(tag)>" }
        }
        return text + "</table>"
    }

    private struct Placed: Equatable {
        var name: String, row: Int, column: Int, rowSpan: Int, columnSpan: Int
    }

    /// A grid as CSS Tables 3 §3.3.2 lays it out: consecutive columns covered by exactly the same
    /// cells count as one, so it reads the same whether or not the model keeps them apart.
    private func merged(_ cells: [Placed], rows: Int) -> (grid: [[String]], tracks: Int) {
        let width = cells.map { $0.column + $0.columnSpan }.max() ?? 0
        var covering = [[Int]](repeating: [], count: width)
        for (index, cell) in cells.enumerated() { for column in cell.column..<(cell.column + cell.columnSpan) { covering[column].append(index) } }
        var track = [Int](repeating: 0, count: width + 1)
        for column in 0..<width { track[column + 1] = track[column] + (column > 0 && covering[column] == covering[column - 1] ? 0 : 1) }
        let grid = (0..<rows).map { row in
            cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map { cell in
                let first = track[cell.column + 1] - 1, across = track[cell.column + cell.columnSpan] - first
                return "\(cell.name)@\(first)" + (across > 1 ? "x\(across)" : "") + (cell.rowSpan > 1 ? "/\(cell.rowSpan)" : "")
            }
        }
        return (grid, track[width])
    }

    /// The grid by the table model's rules, written out independently of the reader's builder.
    private func expected(_ groups: [Group]) -> (cells: [Placed], rows: Int, columns: Int) {
        // The first thead leads and every tfoot trails; the rest stay where they are written.
        var ordered: [Group] = [], feet: [Group] = [], head: Group?
        for group in groups {
            if group.tag == "thead", head == nil { head = group }
            else if group.tag == "tfoot" { feet.append(group) }
            else { ordered.append(group) }
        }
        ordered = (head.map { [$0] } ?? []) + ordered + feet
        var taken: [[Bool]] = [], cells: [Placed] = [], rows = 0, columns = 0
        for group in ordered {
            let first = rows
            for (offset, row) in group.rows.enumerated() {
                let index = first + offset
                while taken.count <= index { taken.append([]) }
                var column = 0
                for cell in row {
                    while column < taken[index].count, taken[index][column] { column += 1 }
                    let across = value(cell.colspan), down = min(group.rows.count - offset, value(cell.rowspan))
                    for r in index..<(index + down) {
                        while taken.count <= r { taken.append([]) }
                        while taken[r].count < column + across { taken[r].append(false) }
                        for c in column..<(column + across) { taken[r][c] = true }
                    }
                    cells.append(Placed(name: cell.name, row: index, column: column, rowSpan: down, columnSpan: across))
                    column += across
                    columns = max(columns, column)
                }
                rows += 1
            }
        }
        return (cells, rows, columns)
    }

    func testGeneratedTablesAreTheSlotGridAndLayOutAtAnyWidth() throws {
        var generator = Generator(state: 0x7AB1E5)
        var tables = 0, spanning = 0
        for round in 0..<250 {
            let groups = generate(&generator)
            let source = markup(groups)
            let (cells, rows, columns) = expected(groups)
            let section = try TableCoverage.section(source)
            let wanted = merged(cells, rows: rows)
            guard columns > 1 else {
                XCTAssertTrue(TableCoverage.tables(in: section.string).isEmpty, "round \(round): \(source)")
                XCTAssertFalse(section.string.string.contains("\u{FFFC}"))
                continue
            }
            // Cells that all span the same columns make one column once merged: a table or a
            // callout, either way with every cell's text.
            guard wanted.tracks > 1 else {
                let words = section.string.readerPlainText().split(whereSeparator: \.isWhitespace).map(String.init)
                XCTAssertEqual(words, cells.map(\.name), "round \(round): \(source)")
                continue
            }
            let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first, "round \(round): \(source)")
            XCTAssertEqual(table.rows.count, rows, "round \(round): \(source)")
            let built = table.cells.map { Placed(name: $0.text, row: $0.row, column: $0.column, rowSpan: $0.rowSpan, columnSpan: $0.columnSpan) }
            XCTAssertEqual(merged(built, rows: rows).grid, wanted.grid, "round \(round): \(source)")
            XCTAssertLessThanOrEqual(table.columnCount, columns, "round \(round): \(source)")
            tables += 1
            if table.cells.contains(where: { $0.rowSpan > 1 && $0.columnSpan > 1 }) { spanning += 1 }
            // The derived structure agrees with the cells.
            XCTAssertEqual(table.rowCells.count, table.rows.count)
            for (index, cell) in table.cells.enumerated() {
                XCTAssertLessThanOrEqual(cell.column + cell.columnSpan, table.columnCount)
                XCTAssertLessThanOrEqual(cell.row + cell.rowSpan, table.rows.count)
                for row in table.rows.indices { XCTAssertEqual(table.rowCells[row].contains(index), (cell.row..<(cell.row + cell.rowSpan)).contains(row)) }
                if cell.rowSpan > 1 { XCTAssertTrue(table.groups.contains { $0.contains(cell.row) && $0.contains(cell.row + cell.rowSpan - 1) }, "round \(round)") }
            }
            XCTAssertEqual(table.groups.flatMap { Array($0) }, Array(table.rows.indices), "the groups partition the rows")
            XCTAssertEqual(table.keepsWithNext.last, false)
            XCTAssertEqual(section.string.string, Array(repeating: "\u{FFFC}", count: table.rows.count).joined(separator: "\n"))
            // And lays out, slices and reads at a narrow and a wide line.
            for available: CGFloat in [70, 500] {
                let layout = table.layout(available: available, viewportHeight: 120)
                XCTAssertGreaterThanOrEqual(layout.scale, TableModel.minimumScale)
                XCTAssertTrue(layout.size.width.isFinite && layout.size.height.isFinite && layout.columnWidths.allSatisfy { $0.isFinite && $0 >= 0 }, "round \(round)")
                XCTAssertLessThanOrEqual(layout.size.width * layout.scale, available + 0.5, "round \(round) at \(available): \(source)")
                var lines = [Int: Int]()
                for row in table.rows.indices {
                    let slices = layout.fragments(ofRow: row, maximumHeight: 119)
                    XCTAssertEqual(slices.last?.bottom ?? -1, layout.rowTops[row + 1], accuracy: 0.01, "round \(round)")
                    for slice in slices {
                        for entry in slice.cells { lines[entry.cell, default: 0] += entry.lines.count }
                        _ = TableRowAttachment(table: table, row: row, fragment: slice, layout: layout).textEquivalent
                    }
                }
                for cell in table.cells.indices { XCTAssertEqual(lines[cell] ?? 0, layout.cellText[cell].lines.count, "round \(round) cell \(cell) at \(available)") }
            }
            let read = table.rows.indices.map { TableRowAttachment(table: table, row: $0).textEquivalent }.joined(separator: "\n")
            XCTAssertEqual(read.split(whereSeparator: \.isWhitespace).map(String.init), table.cells.map(\.text), "every cell is read once, in order")
        }
        XCTAssertGreaterThan(tables, 150)
        XCTAssertGreaterThan(spanning, 10, "the sample holds cells spanning both ways")
    }
}
