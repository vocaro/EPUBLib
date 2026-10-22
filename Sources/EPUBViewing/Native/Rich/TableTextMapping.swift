import Foundation

/// Cell characters have their own stable UTF-16 coordinate space. The section offset still
/// identifies the native row attachment, while the DOM order identifies the same table after
/// a style rebuild or a row's pagination-time continuation.
struct ReaderTablePosition: Hashable, Sendable {
    var table: Int
    var cell: Int
    var offset: Int
    /// The same place in a table nested in the cell: that table, its cell and the offset in
    /// that cell's characters, and so on for a table nested deeper. `offset` is then where the
    /// nested table is in this cell's characters, as a section offset is for a table in the
    /// section, and the nested place tells which continuation of a nested row draws it. nil
    /// for a place in the cell's own text.
    var nested: ReaderTablePosition? {
        get { inner.first }
        set { inner = newValue.map { [$0] } ?? [] }
    }
    /// Where `nested` is kept: a value cannot hold one of its own type directly.
    private var inner: [ReaderTablePosition] = []

    init(table: Int, cell: Int, offset: Int, nested: ReaderTablePosition? = nil) {
        self.table = table; self.cell = cell; self.offset = offset
        self.nested = nested
    }

    /// Places in one row in reading order, by cell and offset, and then by their places in the
    /// table nested there. A place in no cell (nil) comes first.
    static func precedes(_ a: Self?, _ b: Self?) -> Bool {
        let left = (a?.cell ?? -1, a?.offset ?? -1), right = (b?.cell ?? -1, b?.offset ?? -1)
        guard left == right, a?.nested != nil || b?.nested != nil else { return left < right }
        return precedes(a?.nested, b?.nested)
    }
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

    /// The table nested in the cell whose source order is `table`, and the cell's characters
    /// from its first row to its last: where a place in it (`ReaderTablePosition.nested`) is
    /// among the cell's. The cell's map finds the table's unit with its source-ordered binary
    /// search, so no row of the cell is scanned. nil where the cell renders no such table.
    func nestedTable(_ table: Int) -> (model: TableModel, rows: NSRange)? {
        guard let unit = textMap?.map.unit(of: table), unit.location < content.length,
              let model = content.attribute(.readerTableModel, at: unit.location, effectiveRange: nil) as? TableModel,
              model.sourceOrder == table else { return nil }
        var first: Int?, last: Int?
        content.enumerateAttribute(.attachment, in: unit) { value, range, stop in
            guard (value as? TableRowAttachment)?.table === model else { return }
            first = range.location
            stop.pointee = true
        }
        content.enumerateAttribute(.attachment, in: unit, options: .reverse) { value, range, stop in
            guard (value as? TableRowAttachment)?.table === model else { return }
            last = range.upperBound
            stop.pointee = true
        }
        guard let first, let last else { return nil }
        return (model, NSRange(location: first, length: last - first))
    }

    /// The innermost cell holding the place `endpoint` names in this cell, and the place in
    /// it: the cell of the table nested here that `endpoint.nested` names, at any depth, or
    /// this cell for a place in its own text or in a nested table it does not render.
    func innermost(_ endpoint: ReaderTablePosition) -> (cell: TableModel.Cell, endpoint: ReaderTablePosition) {
        guard let nested = endpoint.nested, let table = nestedTable(nested.table)?.model,
              table.cells.indices.contains(nested.cell) else { return (self, endpoint) }
        return table.cells[nested.cell].innermost(nested)
    }
}

extension TextMap {
    /// The characters of the element whose document order is `node`, where it renders as a unit
    /// (a table in a cell), found with the same source-ordered binary search as a position.
    func unit(of node: Int) -> NSRange? {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].node <= node { low = middle + 1 } else { high = middle }
        }
        guard low > 0, spans[low - 1].node == node, spans[low - 1].isUnit else { return nil }
        return NSRange(location: spans[low - 1].location, length: spans[low - 1].length)
    }
}

extension TableRowAttachment {
    /// The row's authored cell text for a body selection containing its attachment. Detached
    /// maps carry the same substitutions as the body map. Coarse rows flatten generated
    /// cell block/br separators to spaces; authored preformatted LF survives.
    var copyTextEquivalent: String {
        table.rowCells[row].map { table.cells[$0] }.filter { $0.row == row }.sorted { $0.column < $1.column }.map { cell in
            if let mapping = cell.textMap {
                return mapping.map.mappedText(in: 0..<cell.content.length, from: cell.content, generatedBreaks: " ")
            }
            // A custom cell without a DOM map still copies its attachment alternatives,
            // which may differ from the words VoiceOver is given in `cell.text`.
            return cell.content.readerCopyPlainText().split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    /// A place in a table nested in a cell is in the map of the innermost cell holding it.
    func domPosition(_ position: ReaderTextPosition, isEnd: Bool = false) -> DOMPosition? {
        if let endpoint = position.tableCell, let found = tableCell(position)?.innermost(endpoint),
           let mapping = found.cell.textMap {
            return isEnd ? mapping.map.endPosition(at: found.endpoint.offset, in: document)
                : mapping.map.position(at: found.endpoint.offset, in: document)
        }
        return isEnd ? map.endPosition(at: position.offset, in: document) : map.position(at: position.offset, in: document)
    }

    /// The DOM range of a rendered range within this section, each end in the map it lies in
    /// (`domPosition`), running forwards as `TextMap.domRange` makes one: a range holding only
    /// generated text runs from the text before it to the text after it. A position when the
    /// range is empty.
    func domRange(_ range: ReaderTextRange) -> (start: DOMPosition, end: DOMPosition)? {
        guard range.start.tableCell != nil || range.end.tableCell != nil else {
            return map.domRange(range.start.offset..<max(range.start.offset, range.end.offset), in: document)
        }
        guard let start = domPosition(range.start) else { return nil }
        guard range.end.tableCell != nil || range.end.offset > range.start.offset else { return (start, start) }
        guard let end = domPosition(range.end, isEnd: true) else { return nil }
        return end < start ? (end, start) : (start, end)
    }

    /// Old bookmarks naming a table element still use the attachment unit. Only CFIs naming
    /// a cell or its descendants enter cell space, and those naming a cell of a table nested
    /// in it enter that cell's too, at any depth (`ReaderTablePosition.nested`).
    func renderedPosition(_ position: DOMPosition, isEnd: Bool = false) -> ReaderTextPosition {
        guard let found = Self.cell(holding: position, map: map, string: string, document: document),
              let offset = found.table.sourceRowOffsets[found.table.cells[found.cell].row] else {
            return ReaderTextPosition(section: spineIndex, offset: map.location(of: position, isEnd: isEnd))
        }
        return ReaderTextPosition(section: spineIndex, offset: offset,
            tableCell: tablePosition(position, isEnd: isEnd, in: found))
    }

    /// `position` as a place in the cell `found`, and in each table nested there that holds it.
    private func tablePosition(_ position: DOMPosition, isEnd: Bool,
                               in found: (table: TableModel, cell: Int, map: TextMap)) -> ReaderTablePosition {
        var result = ReaderTablePosition(table: found.table.sourceOrder, cell: found.cell,
                                         offset: found.map.location(of: position, isEnd: isEnd))
        if let inner = Self.cell(holding: position, map: found.map, string: found.table.cells[found.cell].content,
                                 document: document) {
            result.nested = tablePosition(position, isEnd: isEnd, in: inner)
        }
        return result
    }

    /// The written cell holding `position` of a table that `string`, mapped by `map`, renders
    /// as a unit, with the cell's own map. Ordinary positions never scan table cells: the
    /// enclosing unit is found with the same source-ordered binary search the map uses.
    private static func cell(holding position: DOMPosition, map: TextMap, string: NSAttributedString,
                             document: ContentDocument) -> (table: TableModel, cell: Int, map: TextMap)? {
        var low = 0, high = map.spans.count
        while low < high {
            let middle = (low + high) / 2
            if map.spans[middle].node <= position.node.order { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let span = map.spans[low - 1]
        guard span.isUnit, document.nodes[span.node].isHTML("table"),
              document.nodes[span.node].isAncestor(of: position.node),
              span.location < string.length,
              let table = string.attribute(.readerTableModel, at: span.location, effectiveRange: nil) as? TableModel,
              let index = table.sourceCell(containing: position.node.order),
              let mapping = table.cells[index].textMap else { return nil }
        return (table, index, mapping.map)
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
        if let first = range.start.tableCell, let last = range.end.tableCell,
           first.table == last.table, let model = table(for: range.start) {
            // Use the table's visual reading order, including a spanning cell only once.
            let lower = min(first.cell, last.cell), upper = max(first.cell, last.cell)
            guard model.cells.indices.contains(lower), model.cells.indices.contains(upper) else { return nil }
            return (lower...upper).map { index in
                Self.passage(of: model.cells[index], from: index == first.cell ? first : nil, to: index == last.cell ? last : nil)
            }.joined(separator: "\t")
        }
        // Mixed body/cell endpoints keep the body's mapped passage and replace only the
        // endpoint table's row attachment equivalence with its precise cell portion. The body
        // runs from just after the table's last row, or up to its first, so it holds the
        // section's own separator between the table and what is beside it: the parts join
        // with nothing more, as `mappedText` reads the same range without cell endpoints.
        var lower = range.start.offset, upper = range.end.offset, prefix = "", suffix = ""
        if let endpoint = range.start.tableCell, let model = table(for: range.start), model.cells.indices.contains(endpoint.cell) {
            prefix = Self.passage(in: model, from: endpoint, to: nil)
            lower = (rows.filter { $0.row.table === model }.map(\.offset).max() ?? lower) + 1
        }
        if let endpoint = range.end.tableCell, let model = table(for: range.end), model.cells.indices.contains(endpoint.cell) {
            suffix = Self.passage(in: model, from: nil, to: endpoint)
            upper = rows.first { $0.row.table === model }?.offset ?? upper
        }
        return prefix + mappedText(in: lower..<max(lower, upper)) + suffix
    }

    /// The cells of `table` from `start` to `end`, places in it (nil for its first cell's start
    /// and its last cell's end), tab-separated in reading order as a row reads.
    private static func passage(in table: TableModel, from start: ReaderTablePosition?, to end: ReaderTablePosition?) -> String {
        let lower = start?.cell ?? 0, upper = end?.cell ?? table.cells.count - 1
        guard table.cells.indices.contains(lower), table.cells.indices.contains(upper), lower <= upper else { return "" }
        return (lower...upper).map { index in
            passage(of: table.cells[index], from: index == lower ? start : nil, to: index == upper ? end : nil)
        }.joined(separator: "\t")
    }

    /// A cell's characters from `start` to `end`, places in it (nil for its text's start and
    /// end). Where a place is in a table nested in the cell, the passage reads that table's
    /// cells from or up to it, at any depth, and the cell's own text from after the table's
    /// rows or up to them, with its separator from what is beside the table.
    private static func passage(of cell: TableModel.Cell, from start: ReaderTablePosition?, to end: ReaderTablePosition?) -> String {
        var lower = start?.offset ?? 0, upper = end?.offset ?? cell.content.length, prefix = "", suffix = ""
        if let inside = start?.nested, let nested = cell.nestedTable(inside.table) {
            if let last = end?.nested, last.table == inside.table { return passage(in: nested.model, from: inside, to: last) }
            prefix = passage(in: nested.model, from: inside, to: nil)
            lower = nested.rows.upperBound
        }
        if let inside = end?.nested, let nested = cell.nestedTable(inside.table) {
            suffix = passage(in: nested.model, from: nil, to: inside)
            upper = nested.rows.location
        }
        lower = max(0, min(lower, cell.content.length)); upper = max(lower, min(upper, cell.content.length))
        guard let mapping = cell.textMap else {
            return prefix + cell.content.readerCopyPlainText(in: NSRange(location: lower, length: upper - lower)) + suffix
        }
        return prefix + mapping.map.mappedText(in: lower..<upper, from: cell.content) + suffix
    }
}
