import CoreGraphics
import CoreText
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One `<table>` as the HTML table model places it: cells on the slot grid with their rendered
/// content and resolved box styles, and the row units pagination may break between (rows
/// joined by a rowspan, and the header rows, stay in one unit). Built once per section build;
/// layouts per line width are cached. Immutable apart from that locked cache.
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

    struct Cell {
        var row: Int, column: Int, rowSpan: Int, columnSpan: Int
        var content: NSAttributedString
        /// What VoiceOver reads.
        var text: String
        var isHeader: Bool
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
    }
    struct Row {
        var background: CGColor?
        var height: CGFloat
        /// In `<thead>`.
        var isHeader: Bool
    }

    let cells: [Cell]
    let rows: [Row]
    let columnCount: Int
    /// Widths from `<col>`/`<colgroup>`, `.auto` where none.
    let columns: [ComputedStyle.Length]
    /// Row ranges, one per attachment.
    let units: [Range<Int>]
    /// Indices into `cells` of each unit's cells.
    let unitCells: [[Int]]
    let width: ComputedStyle.Length
    let collapse: Bool
    let spacing: CGSize
    let borders: Borders
    let background: CGColor?
    let alignment: Alignment
    let isRightToLeft: Bool

    /// The scale a table wider than its line is drawn at, at least: below it, cells wrap by
    /// character instead.
    static let minimumScale: CGFloat = 0.6
    static let maximumColumns = 200
    static let maximumCells = 20_000

    private let lock = NSLock()
    private var cachedConstraints: TableLayout.Constraints?
    private var layouts: [LayoutKey: TableLayout] = [:]
    private var layoutOrder: [LayoutKey] = []
    struct LayoutKey: Hashable { let width: CGFloat; let height: CGFloat }

    init(cells: [Cell], rows: [Row], columnCount: Int, columns: [ComputedStyle.Length], width: ComputedStyle.Length,
         collapse: Bool, spacing: CGSize, borders: Borders, background: CGColor?, alignment: Alignment, isRightToLeft: Bool) {
        self.cells = cells; self.rows = rows; self.columnCount = columnCount; self.columns = columns
        self.width = width; self.collapse = collapse; self.spacing = collapse ? .zero : spacing
        self.borders = borders; self.background = background; self.alignment = alignment
        self.isRightToLeft = isRightToLeft
        units = Self.units(rows: rows, cells: cells)
        var unitOfRow = [Int](repeating: 0, count: rows.count)
        for (index, unit) in units.enumerated() { for row in unit { unitOfRow[row] = index } }
        var unitCells = [[Int]](repeating: [], count: units.count)
        for (index, cell) in cells.enumerated() { unitCells[unitOfRow[cell.row]].append(index) }
        self.unitCells = unitCells
    }

    /// Consecutive rows a rowspan joins, and the header rows, form one unit.
    static func units(rows: [Row], cells: [Cell]) -> [Range<Int>] {
        guard !rows.isEmpty else { return [] }
        var reach = Array(rows.indices)
        for cell in cells { reach[cell.row] = max(reach[cell.row], min(rows.count - 1, cell.row + cell.rowSpan - 1)) }
        var units: [Range<Int>] = []
        var start = 0
        while start < rows.count {
            var end = reach[start]
            var row = start
            while row <= end {
                end = max(end, reach[row])
                if rows[row].isHeader, row + 1 < rows.count, rows[row + 1].isHeader { end = max(end, row + 1) }
                row += 1
            }
            units.append(start..<(end + 1))
            start = end + 1
        }
        return units
    }

    // MARK: Layout cache

    /// The layout for a line `available` wide in a viewport `viewportHeight` tall: the table
    /// drawn at most that wide, its text scaled down (to `minimumScale`) when its minimum width
    /// is wider, and further when a unit would be taller than the viewport.
    func layout(available: CGFloat, viewportHeight: CGFloat) -> TableLayout {
        let key = LayoutKey(width: (max(1, available) * 4).rounded() / 4, height: max(1, viewportHeight).rounded())
        if let layout = lock.withLock({ layouts[key] }) { return layout }
        let layout = TableLayout.make(self, available: key.width, viewportHeight: key.height)
        lock.withLock {
            if layouts[key] == nil { layoutOrder.append(key) }
            layouts[key] = layout
            while layoutOrder.count > 8 { layouts[layoutOrder.removeFirst()] = nil }
        }
        return layout
    }

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
    /// Max-content: the widest paragraph unwrapped, as string drawing lays it out.
    static func maximumWidth(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let rect = text.boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin], context: nil)
        return ceil(rect.width)
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

    /// The height of `text` wrapped to `width`.
    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let rect = text.boundingRect(with: CGSize(width: max(1, width), height: 1_000_000), options: [.usesLineFragmentOrigin], context: nil)
        return ceil(rect.height)
    }

    /// The text VoiceOver reads (and copies get) for cell content: attachments by their text
    /// equivalent, whitespace collapsed.
    static func spokenText(_ text: NSAttributedString) -> String {
        var spoken = ""
        let string = text.string as NSString
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? ReaderTextualAttachment { spoken += " \(attachment.textEquivalent) " }
            else if value != nil { spoken += " " }
            else { spoken += string.substring(with: range) }
        }
        return spoken.split(whereSeparator: { $0.isWhitespace || $0 == "\u{FFFC}" }).joined(separator: " ")
    }
}
