import Foundation

/// Cell characters have their own stable UTF-16 coordinate space. The section offset still
/// identifies the native row attachment, while the DOM order identifies the same table after
/// a style rebuild or a row's pagination-time continuation.
struct ReaderTablePosition: Hashable, Sendable {
    var table: Int
    var cell: Int
    var offset: Int
}

final class ReaderDetachedTextMap: NSObject, @unchecked Sendable {
    let map: TextMap
    let node: Int
    let subtreeEnd: Int
    init(map: TextMap, node: Int, subtreeEnd: Int) {
        self.map = map; self.node = node; self.subtreeEnd = subtreeEnd
    }
}

extension NSAttributedString.Key {
    static let readerTableModel = Self("org.epublib.tableModel")
    static let readerDetachedMap = Self("org.epublib.detachedTextMap")
}

extension TableModel.Cell {
    var textMap: ReaderDetachedTextMap? {
        content.length > 0 ? content.attribute(.readerDetachedMap, at: 0, effectiveRange: nil) as? ReaderDetachedTextMap : nil
    }
}

extension TableRowAttachment {
    /// The row's authored cell text for a body selection containing its attachment. Detached
    /// maps carry the same substitutions as the body map. Coarse rows flatten generated
    /// cell block/br separators to spaces; authored preformatted LF survives.
    var copyTextEquivalent: String {
        table.rowCells[row].map { table.cells[$0] }.filter { $0.row == row }.sorted { $0.column < $1.column }.map { cell in
            cell.textMap.map { $0.map.mappedText(in: 0..<cell.content.length, from: cell.content, generatedBreaks: " ") } ?? cell.text
        }.joined(separator: "\t")
    }
}

extension SectionText {
    func tables() -> [(offset: Int, row: TableRowAttachment)] {
        var result: [(Int, TableRowAttachment)] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let row = value as? TableRowAttachment { result.append((range.location, row)) }
        }
        return result
    }

    func tableCell(_ position: ReaderTextPosition) -> TableModel.Cell? {
        guard let endpoint = position.tableCell, position.offset >= 0, position.offset < string.length,
              let row = string.attribute(.attachment, at: position.offset, effectiveRange: nil) as? TableRowAttachment,
              row.table.sourceOrder == endpoint.table,
              row.table.cells.indices.contains(endpoint.cell) else { return nil }
        let table = row.table
        return table.cells[endpoint.cell]
    }

    func domPosition(_ position: ReaderTextPosition, isEnd: Bool = false) -> DOMPosition? {
        if let endpoint = position.tableCell, let cell = tableCell(position), let mapping = cell.textMap {
            return isEnd ? mapping.map.endPosition(at: endpoint.offset, in: document)
                : mapping.map.position(at: endpoint.offset, in: document)
        }
        return isEnd ? map.endPosition(at: position.offset, in: document) : map.position(at: position.offset, in: document)
    }

    /// Old bookmarks naming a table element still use the attachment unit. Only CFIs naming
    /// a cell or its descendants enter cell space.
    func renderedPosition(_ position: DOMPosition, isEnd: Bool = false) -> ReaderTextPosition {
        let coarse = map.location(of: position, isEnd: isEnd)
        // Ordinary body positions never scan table cells. Locate the enclosing unit with the
        // same source-ordered binary search the section's text map uses.
        var low = 0, high = map.spans.count
        while low < high {
            let middle = (low + high) / 2
            if map.spans[middle].node <= position.node.order { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return ReaderTextPosition(section: spineIndex, offset: coarse) }
        let span = map.spans[low - 1]
        guard span.isUnit, document.nodes[span.node].isHTML("table"),
              document.nodes[span.node].isAncestor(of: position.node) else {
            return ReaderTextPosition(section: spineIndex, offset: coarse)
        }
        guard span.location < string.length,
              let table = string.attribute(.readerTableModel, at: span.location, effectiveRange: nil) as? TableModel,
              let index = table.sourceCell(containing: position.node.order),
              let mapping = table.cells[index].textMap,
              let offset = table.sourceRowOffsets[table.cells[index].row] else {
            return ReaderTextPosition(section: spineIndex, offset: coarse)
        }
        return ReaderTextPosition(section: spineIndex, offset: offset,
            tableCell: ReaderTablePosition(table: table.sourceOrder, cell: index,
                offset: mapping.map.location(of: position, isEnd: isEnd)))
    }

    /// Actual cell characters rather than a row's spoken equivalent. This preserves exact
    /// partial words, Unicode and line breaks, while omitting generated list markers.
    func tablePassage(_ range: ReaderTextRange) -> String? {
        guard range.start.tableCell != nil || range.end.tableCell != nil else { return nil }
        let rows = tables()
        func table(for endpoint: ReaderTextPosition) -> TableModel? {
            guard let value = endpoint.tableCell else { return nil }
            return rows.first { $0.row.table.sourceOrder == value.table }?.row.table
        }
        func cellText(_ cell: TableModel.Cell, lower: Int, upper: Int) -> String {
            let lower = max(0, min(lower, cell.content.length)), upper = max(lower, min(upper, cell.content.length))
            guard let mapping = cell.textMap else {
                return cell.content.readerPlainText(in: NSRange(location: lower, length: upper - lower))
            }
            return mapping.map.mappedText(in: lower..<upper, from: cell.content)
        }
        if let first = range.start.tableCell, let last = range.end.tableCell,
           first.table == last.table, let model = table(for: range.start) {
            // Use the table's visual reading order, including a spanning cell only once.
            let lower = min(first.cell, last.cell), upper = max(first.cell, last.cell)
            guard model.cells.indices.contains(lower), model.cells.indices.contains(upper) else { return nil }
            return (lower...upper).map { index in
                cellText(model.cells[index], lower: index == first.cell ? first.offset : 0,
                    upper: index == last.cell ? last.offset : model.cells[index].content.length)
            }.joined(separator: "\t")
        }
        // Mixed body/cell endpoints keep the body's mapped passage and replace only the
        // endpoint table's row attachment equivalence with its precise cell portion.
        var lower = range.start.offset, upper = range.end.offset, prefix = "", suffix = ""
        if let endpoint = range.start.tableCell, let model = table(for: range.start), model.cells.indices.contains(endpoint.cell) {
            prefix = (endpoint.cell..<model.cells.count).map { index in
                cellText(model.cells[index], lower: index == endpoint.cell ? endpoint.offset : 0,
                         upper: model.cells[index].content.length)
            }.joined(separator: "\t")
            lower = (rows.filter { $0.row.table === model }.map(\.offset).max() ?? lower) + 1
        }
        if let endpoint = range.end.tableCell, let model = table(for: range.end), model.cells.indices.contains(endpoint.cell) {
            suffix = (0...endpoint.cell).map { index in
                cellText(model.cells[index], lower: 0,
                         upper: index == endpoint.cell ? endpoint.offset : model.cells[index].content.length)
            }.joined(separator: "\t")
            upper = rows.first { $0.row.table === model }?.offset ?? upper
        }
        let body = mappedText(in: lower..<max(lower, upper))
        return [prefix, body, suffix].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
