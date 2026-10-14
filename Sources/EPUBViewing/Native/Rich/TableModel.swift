import CoreGraphics
import CoreText
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One `<table>` as the HTML table model places it: cells on the slot grid with their rendered
/// content and resolved box styles, and the groups of rows pagination keeps together when they
/// fit a page (rows a rowspan joins, and the header rows). Each row is drawn by an attachment of
/// its own, so a page can break between any two rows. Built once per section build; layouts per
/// line width are cached. Immutable apart from that locked cache.
final class TableModel: @unchecked Sendable {
    struct Insets: Equatable {
        var top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0
        var horizontal: CGFloat { left + right }
        var vertical: CGFloat { top + bottom }
    }
    struct Stroke {
        var width: CGFloat
        var style: ComputedStyle.BorderStyle
        var color: CGColor
    }
    struct Borders {
        var top: Stroke?, right: Stroke?, bottom: Stroke?, left: Stroke?
        var widths: Insets {
            Insets(top: top?.width ?? 0, right: right?.width ?? 0, bottom: bottom?.width ?? 0, left: left?.width ?? 0)
        }
    }
    enum Placement { case top, middle, bottom }
    enum Alignment { case start, center, end }
    /// A header cell's `scope`: what it is a header for.
    enum Scope { case automatic, row, column, rowGroup, columnGroup }

    struct Cell {
        var row: Int, column: Int, rowSpan: Int, columnSpan: Int
        var content: NSAttributedString
        /// What VoiceOver reads.
        var text: String
        var isHeader: Bool
        var scope: Scope = .automatic
        var padding: Insets
        var borders: Borders
        /// Padding plus the part of the borders inside the cell's slot.
        var chrome: Insets
        var background: CGColor?
        var placement: Placement
        /// CSS `width` (content box), or the `width` attribute.
        var width: ComputedStyle.Length
        /// CSS `height` or the `height` attribute: a minimum, content box.
        var height: CGFloat
        /// Min-content and max-content widths of `content`.
        var minContent: CGFloat
        var maxContent: CGFloat

        /// The cell's words are one link and nothing else: to an assistive technology the
        /// cell is that link, and following it is what the cell does.
        var isLink: Bool {
            var links = 0, linked = 0, words = 0
            content.enumerateAttribute(.link, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                let count = (content.string as NSString).substring(with: range).filter { !$0.isWhitespace }.count
                words += count
                if value != nil { links += 1; linked += count }
            }
            return links == 1 && linked == words && words > 0
        }

        /// The cell shows no words and nothing that is read as words: pictures and nothing
        /// else, or nothing at all. A formula, a rule, a hidden label and a table inside the
        /// cell are read, so a cell that holds one of them is not such a cell.
        var isWordless: Bool {
            var wordless = true
            content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, stop in
                if value is ReaderImageAttachment { return }
                guard value != nil || !(content.string as NSString).substring(with: range).allSatisfy(\.isWhitespace) else { return }
                wordless = false
                stop.pointee = true
            }
            return wordless
        }
    }
    struct Row {
        var background: CGColor?
        var height: CGFloat
        /// In `<thead>`.
        var isHeader: Bool
    }

    var sourceOrder: Int = -1
    /// Source section offsets assigned once when the section inserts the table.
    var sourceRowOffsets: [Int: Int] = [:]
    let cells: [Cell]
    let rows: [Row]
    let columnCount: Int
    /// Widths from `<col>`/`<colgroup>`, `.auto` where none.
    let columns: [ComputedStyle.Length]
    /// Rows kept on one page when they fit: rows a rowspan joins, and the header rows.
    let groups: [Range<Int>]
    /// Indices into `cells` of the cells in each row, spanning cells in every row they cover.
    let rowCells: [[Int]]
    /// Cell source intervals sorted once, for logarithmic search-result mapping.
    let sourceCells: [(node: Int, end: Int, cell: Int)]
    /// Whether pagination should keep each row on the page of the row after it: inside a
    /// group, and after a header row.
    let keepsWithNext: [Bool]
    let width: ComputedStyle.Length
    let collapse: Bool
    let spacing: CGSize
    let borders: Borders
    let background: CGColor?
    let alignment: Alignment
    let isRightToLeft: Bool
    /// The table holds data, and is not there to arrange content side by side
    /// (`TableContent.isData`): an assistive technology is given its cells, each with its row,
    /// its column and their header cells, where a table that is not is given its rows.
    let isData: Bool

    /// The scale a table wider than its line is drawn at, at least: below it, cells wrap by
    /// character instead.
    static let minimumScale: CGFloat = 0.6
    static let maximumColumns = 200
    static let maximumCells = 20_000

    private let lock = NSLock()
    private var cachedConstraints: TableLayout.Constraints?
    private var cachedHeaders: (columns: [[Int]], rows: [[Int]])?
    private var layouts: [LayoutKey: TableLayout] = [:]
    private var layoutOrder: [LayoutKey] = []
    struct LayoutKey: Hashable { let width: CGFloat; let height: CGFloat; let nested: Bool }
    private var layoutPasses = 0
    /// Actual layout passes, excluding cache hits, for deterministic cost qualification.
    var layoutPassCount: Int { lock.withLock { layoutPasses } }
    func recordLayoutPass() { lock.withLock { layoutPasses += 1 } }

    init(cells: [Cell], rows: [Row], columnCount: Int, columns: [ComputedStyle.Length], width: ComputedStyle.Length,
         collapse: Bool, spacing: CGSize, borders: Borders, background: CGColor?, alignment: Alignment, isRightToLeft: Bool,
         isData: Bool = false) {
        self.cells = cells; self.rows = rows; self.columnCount = columnCount; self.columns = columns
        self.width = width; self.collapse = collapse; self.spacing = collapse ? .zero : spacing
        self.borders = borders; self.background = background; self.alignment = alignment
        self.isRightToLeft = isRightToLeft
        self.isData = isData
        groups = Self.groups(rows: rows, cells: cells)
        var rowCells = [[Int]](repeating: [], count: rows.count)
        for (index, cell) in cells.enumerated() {
            for row in cell.row..<min(rows.count, cell.row + cell.rowSpan) { rowCells[row].append(index) }
        }
        self.rowCells = rowCells
        sourceCells = cells.enumerated().compactMap { index, cell in
            cell.textMap.map { (node: $0.node, end: $0.subtreeEnd, cell: index) }
        }.sorted { $0.node < $1.node }
        var keeps = rows.map(\.isHeader)
        for group in groups { for row in group.dropLast() { keeps[row] = true } }
        if !keeps.isEmpty { keeps[keeps.count - 1] = false }
        keepsWithNext = keeps
    }

    /// Consecutive rows a rowspan joins, and the header rows, form one group.
    static func groups(rows: [Row], cells: [Cell]) -> [Range<Int>] {
        guard !rows.isEmpty else { return [] }
        var reach = Array(rows.indices)
        for cell in cells { reach[cell.row] = max(reach[cell.row], min(rows.count - 1, cell.row + cell.rowSpan - 1)) }
        var groups: [Range<Int>] = []
        var start = 0
        while start < rows.count {
            var end = reach[start]
            var row = start
            while row <= end {
                end = max(end, reach[row])
                if rows[row].isHeader, row + 1 < rows.count, rows[row + 1].isHeader { end = max(end, row + 1) }
                row += 1
            }
            groups.append(start..<(end + 1))
            start = end + 1
        }
        return groups
    }

    /// The written cell containing this DOM node. Anonymous cells retain coarse mapping.
    func sourceCell(containing node: Int) -> Int? {
        var low = 0, high = sourceCells.count
        while low < high {
            let middle = (low + high) / 2
            if sourceCells[middle].node <= node { low = middle + 1 } else { high = middle }
        }
        guard low > 0, node <= sourceCells[low - 1].end else { return nil }
        return sourceCells[low - 1].cell
    }

    // MARK: Layout cache

    /// The layout for a line `available` wide in a viewport `viewportHeight` tall: the table
    /// drawn at most that wide, its text scaled down (to `minimumScale`) when its minimum width
    /// is wider, and further only when that makes a row fit the viewport. Nested tables
    /// wrap at their assigned width and inherit the outer table's scale.
    func layout(available: CGFloat, viewportHeight: CGFloat, nested: Bool = false) -> TableLayout {
        let key = LayoutKey(width: (max(1, available) * 4).rounded() / 4, height: max(1, viewportHeight).rounded(), nested: nested)
        if let layout = lock.withLock({ layouts[key] }) { return layout }
        let layout = TableLayout.make(self, available: key.width, viewportHeight: key.height, nested: nested)
        lock.withLock {
            if layouts[key] == nil { layoutOrder.append(key) }
            layouts[key] = layout
            while layoutOrder.count > 8 { layouts[layoutOrder.removeFirst()] = nil }
        }
        return layout
    }

    // MARK: Header cells

    /// The header cells of each column and of each row, as indices into `cells`, in reading
    /// order. HTML's rule for a `th` (the table model's "column header" and "row header"): its
    /// `scope` says which it is; without one it heads its columns when its rows hold header
    /// cells alone or it stands in `<thead>`, and otherwise its rows when its columns hold
    /// header cells alone. `scope="colgroup"` and `"rowgroup"` are read as column and row.
    private var headers: (columns: [[Int]], rows: [[Int]]) {
        if let headers = lock.withLock({ cachedHeaders }) { return headers }
        // Whether a data cell stands in each row and in each column.
        var dataInRow = [Bool](repeating: false, count: rows.count), dataInColumn = [Bool](repeating: false, count: columnCount)
        for cell in cells where !cell.isHeader {
            for row in cell.row..<min(rows.count, cell.row + cell.rowSpan) { dataInRow[row] = true }
            for column in cell.column..<min(columnCount, cell.column + cell.columnSpan) { dataInColumn[column] = true }
        }
        var columns = [[Int]](repeating: [], count: columnCount), rowHeaders = [[Int]](repeating: [], count: rows.count)
        for (index, cell) in cells.enumerated() where cell.isHeader {
            let ownRows = cell.row..<min(rows.count, cell.row + cell.rowSpan)
            let ownColumns = cell.column..<min(columnCount, cell.column + cell.columnSpan)
            let headsColumns: Bool, headsRows: Bool
            switch cell.scope {
            case .column, .columnGroup: (headsColumns, headsRows) = (true, false)
            case .row, .rowGroup: (headsColumns, headsRows) = (false, true)
            case .automatic:
                headsColumns = rows[cell.row].isHeader || !ownRows.contains { dataInRow[$0] }
                headsRows = !headsColumns && !ownColumns.contains { dataInColumn[$0] }
            }
            if headsColumns { for column in ownColumns { columns[column].append(index) } }
            if headsRows { for row in ownRows { rowHeaders[row].append(index) } }
        }
        for column in columns.indices { columns[column].sort { cells[$0].row < cells[$1].row } }
        for row in rowHeaders.indices { rowHeaders[row].sort { cells[$0].column < cells[$1].column } }
        lock.withLock { cachedHeaders = (columns, rowHeaders) }
        return (columns, rowHeaders)
    }

    /// The cells that head `column`, top first.
    func columnHeaders(_ column: Int) -> [Int] { headers.columns.indices.contains(column) ? headers.columns[column] : [] }

    /// The cells that head `row`, in column order.
    func rowHeaders(_ row: Int) -> [Int] { headers.rows.indices.contains(row) ? headers.rows[row] : [] }

    /// Column min/max widths: independent of the line, computed once.
    var constraints: TableLayout.Constraints {
        if let constraints = lock.withLock({ cachedConstraints }) { return constraints }
        let constraints = TableLayout.Constraints(self)
        lock.withLock { cachedConstraints = constraints }
        return constraints
    }
}

/// Measures attributed text for table layout.
enum TableMeasure {
    /// Max-content: the widest unwrapped line, including every paragraph in the cell.
    ///
    /// AppKit string drawing revisits the whole string when it sizes an attachment, making
    /// a string of attachment paragraphs quadratic. Measure paragraphs separately and give
    /// drawing fixed intrinsic widths: neither a table layout nor a viewport-wide rule belongs
    /// in intrinsic measurement. An unlimited height includes even lines below 100,000 points.
    static func maximumWidth(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let full = NSRange(location: 0, length: text.length)
        var widest: CGFloat = 0
        (text.string as NSString).enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, _, range, _ in
            let measured = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
            let paragraphRange = NSRange(location: 0, length: measured.length)
            var replacements: [(NSRange, Any)] = []
            measured.enumerateAttribute(.attachment, in: paragraphRange) { value, attachmentRange, _ in
                guard let reader = value as? ReaderAttachment else { return }
                replacements.append((attachmentRange, WidthAttachment(width: reader.contentWidths().max)))
            }
            for (range, attachment) in replacements { measured.addAttribute(.attachment, value: attachment, range: range) }
            var paragraphs: [(NSRange, NSParagraphStyle)] = []
            measured.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, styleRange, _ in
                guard let style = value as? NSParagraphStyle, style.alignment == .justified else { return }
                let neutral = style.mutableCopy() as! NSMutableParagraphStyle
                neutral.alignment = .left
                paragraphs.append((styleRange, neutral))
            }
            for (range, style) in paragraphs { measured.addAttribute(.paragraphStyle, value: style, range: range) }
            let string = measured.string as NSString
            var firstLine = true
            string.enumerateSubstrings(in: paragraphRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                let isFirstLine = firstLine
                firstLine = false
                guard lineRange.length > 0 else { return }
                let line = NSMutableAttributedString(attributedString: measured.attributedSubstring(from: lineRange))
                if !isFirstLine, let style = line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    let continuation = style.mutableCopy() as! NSMutableParagraphStyle
                    continuation.firstLineHeadIndent = style.headIndent
                    line.addAttribute(.paragraphStyle, value: continuation, range: NSRange(location: 0, length: line.length))
                }
                // Exclude the separator: string drawing of a paragraph with its trailing
                // newline drops its leading reservation from the reported width.
                let rect = line.boundingRect(with: CGSize(width: 100_000, height: 0),
                                             options: [.usesLineFragmentOrigin], context: nil)
                widest = max(widest, rect.width)
            }
        }
        return ceil(widest)
    }

    /// A fixed intrinsic width, with no table layout or viewport-dependent sizing callback.
    private final class WidthAttachment: ReaderAttachment {
        let width: CGFloat
        init(width: CGFloat) { self.width = width; super.init() }
        required init?(coder: NSCoder) { nil }
        override func layoutBounds(_ line: Line) -> CGRect { CGRect(x: 0, y: 0, width: width, height: 0) }
    }

    /// Min-content: the widest unit between line-break opportunities (UAX #14, as CoreText
    /// finds them), or the widest attachment. Ignores `nowrap`; callers handle it.
    static func minimumWidth(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        var widest: CGFloat = 0
        let measured = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            widest = max(widest, minimumWidth(of: attachment, attributes: text.attributes(at: range.location, effectiveRange: nil)))
            measured.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        let string = measured.string as NSString
        string.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            let paragraph = measured.attributedSubstring(from: range)
            let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let indent = max(style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0)
            let typesetter = CTTypesetterCreateWithAttributedString(paragraph as CFAttributedString)
            let source = paragraph.string as CFString
            let tokenizer = CFStringTokenizerCreate(nil, source, CFRange(location: 0, length: range.length),
                                                    kCFStringTokenizerUnitLineBreak, nil)
            var token = CFStringTokenizerAdvanceToNextToken(tokenizer)
            while token.rawValue != 0 {
                let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let line = CTTypesetterCreateLine(typesetter, tokenRange)
                let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
                widest = max(widest, CGFloat(width) + indent)
                token = CFStringTokenizerAdvanceToNextToken(tokenizer)
            }
        }
        return ceil(widest)
    }

    /// An attachment's min-content width: the reader's own know theirs; any other is
    /// measured as string drawing sizes it.
    static func minimumWidth(of attachment: NSTextAttachment, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        if let reader = attachment as? ReaderAttachment { return reader.contentWidths().min }
        return maximumWidth(NSAttributedString(attachment: attachment, attributes: attributes))
    }

    /// The text VoiceOver reads (and copies get) for cell content: attachments by their text
    /// equivalent, whitespace collapsed, and nothing of what `visibility: hidden` hides
    /// (`NSAttributedString.readerHiddenText(_:)`), which parts the words around it.
    static func spokenText(_ text: NSAttributedString) -> String {
        var spoken = ""
        let string = text.string as NSString
        text.enumerateAttribute(.readerHidden, in: NSRange(location: 0, length: text.length)) { hidden, part, _ in
            if hidden != nil { spoken += " "; return }
            text.enumerateAttribute(.attachment, in: part) { value, range, _ in
                if let attachment = value as? ReaderTextualAttachment { spoken += " \(attachment.textEquivalent) " }
                else if value != nil { spoken += " " }
                else { spoken += string.substring(with: range) }
            }
        }
        return spoken.split(whereSeparator: { $0.isWhitespace || $0 == "\u{FFFC}" }).joined(separator: " ")
    }
}
