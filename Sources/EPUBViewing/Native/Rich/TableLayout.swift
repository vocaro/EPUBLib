import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A table laid out for one line width, an approximation of CSS 2.1 automatic table layout:
/// column min/max widths from the cells (spanning cells spread over their columns), specified
/// widths, then the line's width distributed between them. Coordinates are the table's own,
/// before `scale`; `originX` places the table in its line.
struct TableLayout {
    /// Column min/max-content widths including cell padding and borders, and specified widths,
    /// one for each column track.
    struct Constraints {
        /// The track each of the table's columns is laid out in. CSS Tables 3 §3.3.2 (track
        /// merging): a column spanned by exactly the cells that span the one before it, and
        /// declared by no `col` or `colgroup`, shares that column's track, so the columns a
        /// `colspan` runs past with no cell starting in them add no width or spacing.
        var track: [Int]
        var minimum: [CGFloat]
        var maximum: [CGFloat]
        var fixed: [CGFloat?]
        var percent: [CGFloat?]
        /// Width outside the columns: the table's borders and border spacing.
        var outside: CGFloat
        var minimumTableWidth: CGFloat { minimum.reduce(0, +) + outside }
        var maximumTableWidth: CGFloat { maximum.reduce(0, +) + outside }

        /// The tracks a cell spans.
        func tracks(of cell: TableModel.Cell) -> Range<Int> {
            track[cell.column]..<(track[min(track.count, cell.column + cell.columnSpan) - 1] + 1)
        }

        init(_ table: TableModel) {
            // A track starts where a cell starts or ends, and at every column a `col` declares.
            var boundary = [Bool](repeating: false, count: table.columnCount)
            for cell in table.cells {
                for edge in [cell.column, cell.column + cell.columnSpan] where edge < boundary.count { boundary[edge] = true }
            }
            track = []
            for column in 0..<table.columnCount {
                let starts = column == 0 || boundary[column] || column < table.columns.count
                track.append((track.last ?? -1) + (starts ? 1 : 0))
            }
            let count = (track.last ?? -1) + 1
            minimum = Array(repeating: 0, count: count); maximum = minimum
            fixed = Array(repeating: nil, count: count); percent = fixed
            let gap = table.spacing.width
            let edges = table.borders.widths
            outside = table.collapse ? edges.horizontal / 2 : edges.horizontal + gap * CGFloat(count + 1)
            for (index, length) in table.columns.enumerated() where index < track.count {
                switch length {
                case .points(let value): fixed[track[index]] = value
                case .percent(let value): percent[track[index]] = value
                default: break
                }
            }
            for cell in table.cells where tracks(of: cell).count == 1 {
                let column = track[cell.column]
                minimum[column] = max(minimum[column], cell.minContent + cell.chrome.horizontal)
                maximum[column] = max(maximum[column], cell.maxContent + cell.chrome.horizontal)
                switch cell.width {
                case .points(let value): fixed[column] = max(fixed[column] ?? 0, value + cell.chrome.horizontal)
                case .percent(let value): percent[column] = max(percent[column] ?? 0, value)
                default: break
                }
            }
            for column in 0..<count {
                if let width = fixed[column] { maximum[column] = max(minimum[column], width) }
                maximum[column] = max(maximum[column], minimum[column])
            }
            for cell in table.cells.filter({ tracks(of: $0).count > 1 }).sorted(by: { tracks(of: $0).count < tracks(of: $1).count }) {
                let range = tracks(of: cell)
                let gaps = gap * CGFloat(range.count - 1)
                let weights = range.map { maximum[$0] }
                Self.spread(cell.minContent + cell.chrome.horizontal - gaps, over: range, in: &minimum, weights: weights)
                Self.spread(cell.maxContent + cell.chrome.horizontal - gaps, over: range, in: &maximum, weights: weights)
                for column in range { maximum[column] = max(maximum[column], minimum[column]) }
            }
        }

        /// Grows `values[range]` to total at least `target`, in proportion to `weights` (equally
        /// when they are all zero).
        static func spread(_ target: CGFloat, over range: Range<Int>, in values: inout [CGFloat], weights: [CGFloat]) {
            let current = range.reduce(0) { $0 + values[$1] }
            guard target > current, !range.isEmpty else { return }
            let total = weights.reduce(0, +)
            for (offset, column) in range.enumerated() {
                values[column] += (target - current) * (total > 0 ? weights[offset] / total : 1 / CGFloat(range.count))
            }
        }

        /// Column widths for `available` points of line, at most that wide in total. The table's
        /// own width in viewport units is of the line's width and the page's `viewportHeight`.
        func widths(available: CGFloat, tableWidth: ComputedStyle.Length, viewportHeight: CGFloat) -> [CGFloat] {
            let count = minimum.count
            let room = max(0, available - outside)
            let sumMin = minimum.reduce(0, +), sumMax = maximum.reduce(0, +)
            guard sumMin <= room else {
                // Narrower than its content allows: every column shrinks alike and cells wrap
                // by character.
                return minimum.map { sumMin > 0 ? $0 * room / sumMin : room / CGFloat(count) }
            }
            var target: CGFloat
            if let specified = tableWidth.resolve(reference: available, viewport: CGSize(width: available, height: viewportHeight)) {
                target = max(sumMin, min(room, specified - outside))
            } else {
                var wanted = sumMax
                let percentTotal = percent.compactMap { $0 }.reduce(0, +)
                for column in 0..<count { if let share = percent[column], share > 0 { wanted = max(wanted, maximum[column] * 100 / share) } }
                if percentTotal > 0, percentTotal < 100 {
                    let others = (0..<count).filter { percent[$0] == nil }.reduce(0) { $0 + maximum[$1] }
                    wanted = max(wanted, others * 100 / (100 - percentTotal))
                }
                target = max(sumMin, min(room, wanted))
            }
            var widths = minimum
            var remaining = target - sumMin
            func grow(_ column: Int, to goal: CGFloat) {
                let add = min(remaining, max(0, goal - widths[column]))
                widths[column] += add
                remaining -= add
            }
            for column in 0..<count { if let share = percent[column] { grow(column, to: target * share / 100) } }
            for column in 0..<count where percent[column] == nil && fixed[column] != nil { grow(column, to: maximum[column]) }
            let automatic = (0..<count).filter { percent[$0] == nil && fixed[$0] == nil }
            let demand = automatic.reduce(0) { $0 + max(0, maximum[$1] - widths[$1]) }
            if demand > 0, remaining > 0 {
                let share = min(1, remaining / demand)
                for column in automatic {
                    let add = max(0, maximum[column] - widths[column]) * share
                    widths[column] += add
                    remaining -= add
                }
            }
            if remaining > 0.01 {
                // Wider than the content wants (a specified width): automatic columns take the
                // rest in proportion to their max-content width, else every column does.
                let pool = automatic.isEmpty ? Array(0..<count) : automatic
                let weights = pool.map { automatic.isEmpty ? widths[$0] : maximum[$0] }
                let total = weights.reduce(0, +)
                for (offset, column) in pool.enumerated() {
                    widths[column] += remaining * (total > 0 ? weights[offset] / total : 1 / CGFloat(pool.count))
                }
            }
            return widths
        }
    }

    var scale: CGFloat
    var cellText: [TableCellLayout]
    struct OwnedLine { let cell: Int, line: Int; let top: CGFloat, bottom: CGFloat }
    var rowLines: [[OwnedLine]]
    /// The line width the table was laid out for, before scaling (the line's width / scale).
    var lineWidth: CGFloat
    var size: CGSize
    var originX: CGFloat
    /// The width of each column track (`Constraints.track`).
    var columnWidths: [CGFloat]
    var rowHeights: [CGFloat]
    /// Border boxes, in table coordinates.
    var cellFrames: [CGRect]
    /// Where each cell's content is drawn.
    var contentFrames: [CGRect]
    /// Where each row's slice of the table starts (its border box less the spacing above it;
    /// the first at the table's top); the last element is the table's height.
    var rowTops: [CGFloat]

    /// A row's slice of the table on the line, scaled.
    func height(ofRow row: Int) -> CGFloat { (rowTops[row + 1] - rowTops[row]) * scale }
    var tallestRow: CGFloat { (0..<(rowTops.count - 1)).map(height(ofRow:)).max() ?? 0 }

    static func make(_ table: TableModel, available: CGFloat, viewportHeight: CGFloat, nested: Bool = false) -> TableLayout {
        let constraints = table.constraints
        var scale: CGFloat = !nested && constraints.minimumTableWidth > available
            ? max(TableModel.minimumScale, available / constraints.minimumTableWidth) : 1
        var layout = make(table, constraints: constraints, width: available / scale, scale: scale, viewportHeight: viewportHeight / scale)
        let original = layout
        // Only the outer table fits a page. Keep a reduction only when it fits; otherwise
        // continue at the initial readable size instead of shrinking for no benefit.
        var attempts = 0
        while !nested, layout.tallestRow > viewportHeight, scale > TableModel.minimumScale + 0.001, attempts < 6 {
            scale = max(TableModel.minimumScale, scale * 0.85)
            layout = make(table, constraints: constraints, width: available / scale, scale: scale, viewportHeight: viewportHeight / scale)
            attempts += 1
        }
        return layout.tallestRow <= viewportHeight ? layout : original
    }

    private static func make(_ table: TableModel, constraints: Constraints, width: CGFloat, scale: CGFloat, viewportHeight: CGFloat) -> TableLayout {
        table.recordLayoutPass()
        let columns = constraints.widths(available: width, tableWidth: table.width, viewportHeight: viewportHeight)
        let gap = table.spacing
        let edges = table.borders.widths
        func spanWidth(_ cell: TableModel.Cell) -> CGFloat {
            let range = constraints.tracks(of: cell)
            return range.reduce(0) { $0 + columns[$1] } + gap.width * CGFloat(max(0, range.count - 1))
        }
        let cellText = table.cells.map { cell in
            TableCellLayout(cell.content, width: max(1, spanWidth(cell) - cell.chrome.horizontal),
                            viewportHeight: viewportHeight)
        }
        let contentHeights = cellText.map(\.height)
        var rows = table.rows.map(\.height)
        for (index, cell) in table.cells.enumerated() where cell.rowSpan == 1 {
            rows[cell.row] = max(rows[cell.row], contentHeights[index] + cell.chrome.vertical, cell.height + cell.chrome.vertical)
        }
        for (index, cell) in table.cells.enumerated().filter({ $0.element.rowSpan > 1 }).sorted(by: { $0.element.rowSpan < $1.element.rowSpan }) {
            let range = cell.row..<min(rows.count, cell.row + cell.rowSpan)
            let needed = max(contentHeights[index], cell.height) + cell.chrome.vertical
            let have = range.reduce(0) { $0 + rows[$1] } + gap.height * CGFloat(range.count - 1)
            if needed > have { for row in range { rows[row] += (needed - have) / CGFloat(range.count) } }
        }
        let x0 = table.collapse ? edges.left / 2 : edges.left + gap.width
        let y0 = table.collapse ? edges.top / 2 : edges.top + gap.height
        var columnX: [CGFloat] = [], x = x0
        for column in columns { columnX.append(x); x += column + gap.width }
        var rowY: [CGFloat] = [], y = y0
        for row in rows { rowY.append(y); y += row + gap.height }
        let size = CGSize(width: columns.reduce(0, +) + constraints.outside,
                          height: rows.reduce(0, +) + (table.collapse ? edges.vertical / 2 : edges.vertical + gap.height * CGFloat(rows.count + 1)))
        var frames: [CGRect] = [], contents: [CGRect] = []
        for (index, cell) in table.cells.enumerated() {
            let range = cell.row..<min(rows.count, cell.row + cell.rowSpan)
            var frame = CGRect(x: columnX[constraints.track[cell.column]], y: rowY[cell.row], width: spanWidth(cell),
                               height: range.reduce(0) { $0 + rows[$1] } + gap.height * CGFloat(range.count - 1))
            if table.isRightToLeft { frame.origin.x = size.width - frame.maxX }
            frames.append(frame)
            let inner = CGRect(x: frame.minX + cell.chrome.left, y: frame.minY + cell.chrome.top,
                               width: max(1, frame.width - cell.chrome.horizontal), height: max(0, frame.height - cell.chrome.vertical))
            let height = contentHeights[index]
            let top: CGFloat = switch cell.placement {
            case .top: inner.minY
            case .middle: inner.minY + max(0, inner.height - height) / 2
            case .bottom: inner.maxY - height
            }
            contents.append(CGRect(x: inner.minX, y: top, width: inner.width, height: height))
        }
        var tops: [CGFloat] = [0]
        for row in rowY.dropFirst() { tops.append(row - gap.height) }
        tops.append(size.height)
        let originX: CGFloat = switch (table.alignment, table.isRightToLeft) {
        case (.center, _): max(0, (width - size.width) / 2)
        case (.end, false), (.start, true): max(0, width - size.width)
        default: 0
        }
        var rowLines = [[OwnedLine]](repeating: [], count: rows.count)
        for (cell, text) in cellText.enumerated() {
            for (line, metadata) in text.lines.enumerated() {
                let top = contents[cell].minY + metadata.frame.minY
                var low = 0, high = rows.count - 1
                while low < high {
                    let middle = (low + high + 1) / 2
                    if tops[middle] - 0.01 <= top { low = middle } else { high = middle - 1 }
                }
                rowLines[low].append(OwnedLine(cell: cell, line: line, top: top, bottom: contents[cell].minY + metadata.frame.maxY))
            }
        }
        for row in rowLines.indices { rowLines[row].sort { $0.top < $1.top } }
        return TableLayout(scale: scale, cellText: cellText, rowLines: rowLines, lineWidth: width, size: size, originX: originX, columnWidths: columns,
                           rowHeights: rows, cellFrames: frames, contentFrames: contents, rowTops: tops)
    }

    /// Whole lines whose top belongs to this row. Lines crossing its bottom finish in this
    /// row's attachment; the next row never draws or reads them a second time.
    func fragments(ofRow row: Int, maximumHeight: CGFloat) -> [TableRowFragment] {
        let top = rowTops[row], bottom = rowTops[row + 1]
        let limit = max(1, maximumHeight / scale)
        let owned = rowLines[row]
        // Leave room to finish any line whose top falls just before the cut. A short row
        // retains its original height; only a tall row is subdivided.
        let overflow = max(0, (owned.map(\.bottom).max() ?? bottom) - bottom)
        if bottom - top + overflow <= limit + 0.01 {
            return [fragment(row: row, top: top, bottom: bottom, lines: owned, limit: limit)]
        }
        var result: [TableRowFragment] = []
        var cursor = top, firstLine = 0
        while cursor < bottom - 0.01 {
            var end = min(bottom, cursor + limit)
            var lastLine = firstLine
            while lastLine < owned.count, owned[lastLine].top < end - 0.01 { lastLine += 1 }
            let crossing = owned[firstLine..<lastLine].filter { $0.bottom > cursor + limit + 0.01 }
            if let first = crossing.map(\.top).min(), first > cursor + 0.01 {
                end = first
                while lastLine > firstLine, owned[lastLine - 1].top >= end - 0.01 { lastLine -= 1 }
            }
            result.append(fragment(row: row, top: cursor, bottom: end,
                                   lines: Array(owned[firstLine..<lastLine]), limit: limit))
            firstLine = lastLine
            cursor = end
        }
        return result
    }

    private func fragment(row: Int, top: CGFloat, bottom: CGFloat,
                          lines: [OwnedLine], limit: CGFloat) -> TableRowFragment {
        var cells: [TableRowFragment.CellLines] = []
        let grouped = Dictionary(grouping: lines, by: \.cell)
        for cell in grouped.keys.sorted() {
            let indices = grouped[cell]!.map(\.line)
            if let first = indices.min(), let last = indices.max() { cells.append(.init(cell: cell, lines: first..<(last + 1))) }
        }
        let height = max(bottom, lines.map(\.bottom).max() ?? bottom) - top
        return TableRowFragment(row: row, top: top, bottom: bottom,
                                height: height, fitScale: min(1, limit / max(1, height)), cells: cells)
    }

    /// A cell's frame in a row attachment's coordinates (top-left origin).
    func frame(ofCell index: Int, inRow row: Int) -> CGRect {
        let frame = cellFrames[index]
        return CGRect(x: (originX + frame.minX) * scale, y: (frame.minY - rowTops[row]) * scale,
                      width: frame.width * scale, height: frame.height * scale)
    }
}

extension TableModel {
    /// Draws one row's slice of the table into the current graphics context (top-left origin,
    /// flipped, as a view draws), whose origin is the slice's top-left on its line. Decoration is
    /// clipped to the fragment; cell glyphs are drawn as complete lines belonging to this
    /// continuation, using the same layout that measured them.
    ///
    /// A fragment taller than its slice finishes a line that crosses the slice's foot. The
    /// table's decoration and that of the row's own cells go on through that band, as their
    /// boxes do: a spanning cell keeps its background, and the table its border, to the line's
    /// foot. The next row's cells are not drawn there; they are drawn in the next row (#141).
    func draw(row: Int, layout: TableLayout, fragment: TableRowFragment, in context: CGContext) {
        guard row < rows.count else { return }
        let top = fragment.top
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: layout.scale * fragment.fitScale, y: layout.scale * fragment.fitScale)
        context.translateBy(x: layout.originX, y: -top)
        let slice = CGRect(x: 0, y: top, width: layout.size.width, height: fragment.height)
        context.saveGState()
        context.clip(to: slice.insetBy(dx: -1, dy: 0))
        let tableRect = CGRect(origin: .zero, size: layout.size)
        if let background {
            context.setFillColor(background)
            context.fill(tableRect)
        }
        let indices = rowCells[row]
        for index in indices {
            guard let color = rows[cells[index].row].background else { continue }
            context.setFillColor(color)
            context.fill(layout.cellFrames[index])
        }
        for index in indices {
            guard let color = cells[index].background else { continue }
            context.setFillColor(color)
            context.fill(layout.cellFrames[index])
        }
        var edges: [(TableModel.Stroke, CGPoint, CGPoint)] = []
        func add(_ borders: TableModel.Borders, around rect: CGRect, inside: Bool) {
            func inset(_ stroke: TableModel.Stroke?) -> CGFloat { inside ? (stroke?.width ?? 0) / 2 : 0 }
            if let stroke = borders.top {
                let y = rect.minY + inset(stroke)
                edges.append((stroke, CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)))
            }
            if let stroke = borders.bottom {
                let y = rect.maxY - inset(stroke)
                edges.append((stroke, CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)))
            }
            if let stroke = borders.left {
                let x = rect.minX + inset(stroke)
                edges.append((stroke, CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)))
            }
            if let stroke = borders.right {
                let x = rect.maxX - inset(stroke)
                edges.append((stroke, CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)))
            }
        }
        let outer = borders.widths
        add(borders, around: collapse ? CGRect(x: outer.left / 2, y: outer.top / 2, width: layout.size.width - outer.horizontal / 2,
                                                height: layout.size.height - outer.vertical / 2) : tableRect,
            inside: !collapse)
        for index in indices { add(cells[index].borders, around: layout.cellFrames[index], inside: !collapse) }
        // Collapsed borders share their lines: the widest is drawn last, so it wins.
        for (stroke, start, end) in edges.sorted(by: { $0.0.width < $1.0.width }) {
            context.setStrokeColor(stroke.color)
            context.setLineWidth(stroke.width)
            switch stroke.style {
            case .dashed: context.setLineDash(phase: 0, lengths: [stroke.width * 3, stroke.width * 2])
            case .dotted: context.setLineDash(phase: 0, lengths: [stroke.width, stroke.width])
            default: context.setLineDash(phase: 0, lengths: [])
            }
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
        context.restoreGState()
        // Text is drawn separately from the geometric row slice. A line crossing a row
        // boundary is completed here, including its descenders, and excluded from the next.
        for entry in fragment.cells {
            let frame = layout.contentFrames[entry.cell]
            layout.cellText[entry.cell].draw(entry.lines, at: frame.origin)
        }
    }
}
