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
    /// Column min/max-content widths including cell padding and borders, and specified widths.
    struct Constraints {
        var minimum: [CGFloat]
        var maximum: [CGFloat]
        var fixed: [CGFloat?]
        var percent: [CGFloat?]
        /// Width outside the columns: the table's borders and border spacing.
        var outside: CGFloat
        var minimumTableWidth: CGFloat { minimum.reduce(0, +) + outside }
        var maximumTableWidth: CGFloat { maximum.reduce(0, +) + outside }

        init(_ table: TableModel) {
            let count = table.columnCount
            minimum = Array(repeating: 0, count: count); maximum = minimum
            fixed = Array(repeating: nil, count: count); percent = fixed
            let gap = table.spacing.width
            let edges = table.borders.widths
            outside = table.collapse ? edges.horizontal / 2 : edges.horizontal + gap * CGFloat(count + 1)
            for (index, length) in table.columns.enumerated() where index < count {
                switch length {
                case .points(let value): fixed[index] = value
                case .percent(let value): percent[index] = value
                default: break
                }
            }
            for cell in table.cells where cell.columnSpan == 1 {
                let column = cell.column
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
            for cell in table.cells.filter({ $0.columnSpan > 1 }).sorted(by: { $0.columnSpan < $1.columnSpan }) {
                let range = cell.column..<min(count, cell.column + cell.columnSpan)
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

        /// Column widths for `available` points of line, at most that wide in total.
        func widths(available: CGFloat, tableWidth: ComputedStyle.Length) -> [CGFloat] {
            let count = minimum.count
            let room = max(0, available - outside)
            let sumMin = minimum.reduce(0, +), sumMax = maximum.reduce(0, +)
            guard sumMin <= room else {
                // Narrower than its content allows: every column shrinks alike and cells wrap
                // by character.
                return minimum.map { sumMin > 0 ? $0 * room / sumMin : room / CGFloat(count) }
            }
            var target: CGFloat
            if let specified = tableWidth.resolve(reference: available, viewport: CGSize(width: available, height: available)) {
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
    /// The line width the table was laid out for, before scaling (the line's width / scale).
    var lineWidth: CGFloat
    var size: CGSize
    var originX: CGFloat
    var columnWidths: [CGFloat]
    var rowHeights: [CGFloat]
    /// Border boxes, in table coordinates.
    var cellFrames: [CGRect]
    /// Where each cell's content is drawn.
    var contentFrames: [CGRect]
    /// Each unit's top; the last element is the table's height.
    var unitTops: [CGFloat]

    /// A unit's height on the line, scaled.
    func height(ofUnit unit: Int) -> CGFloat { (unitTops[unit + 1] - unitTops[unit]) * scale }
    var tallestUnit: CGFloat { (0..<(unitTops.count - 1)).map(height(ofUnit:)).max() ?? 0 }

    static func make(_ table: TableModel, available: CGFloat, viewportHeight: CGFloat) -> TableLayout {
        let constraints = table.constraints
        var scale = constraints.minimumTableWidth > available
            ? max(TableModel.minimumScale, available / constraints.minimumTableWidth) : 1
        var layout = make(table, constraints: constraints, width: available / scale, scale: scale)
        // A unit taller than the page would be cut: shrink the table until it fits, within limits.
        var attempts = 0
        while layout.tallestUnit > viewportHeight, scale > TableModel.minimumScale + 0.001, attempts < 6 {
            scale = max(TableModel.minimumScale, scale * 0.85)
            layout = make(table, constraints: constraints, width: available / scale, scale: scale)
            attempts += 1
        }
        return layout
    }

    private static func make(_ table: TableModel, constraints: Constraints, width: CGFloat, scale: CGFloat) -> TableLayout {
        let columns = constraints.widths(available: width, tableWidth: table.width)
        let gap = table.spacing
        let edges = table.borders.widths
        func spanWidth(_ cell: TableModel.Cell) -> CGFloat {
            let range = cell.column..<min(columns.count, cell.column + cell.columnSpan)
            return range.reduce(0) { $0 + columns[$1] } + gap.width * CGFloat(max(0, range.count - 1))
        }
        let contentHeights = table.cells.map { cell in
            TableMeasure.height(cell.content, width: max(1, spanWidth(cell) - cell.chrome.horizontal))
        }
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
            var frame = CGRect(x: columnX[cell.column], y: rowY[cell.row], width: spanWidth(cell),
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
        for unit in table.units.dropFirst() { tops.append(rowY[unit.lowerBound] - gap.height) }
        tops.append(size.height)
        let originX: CGFloat = switch (table.alignment, table.isRightToLeft) {
        case (.center, _): max(0, (width - size.width) / 2)
        case (.end, false), (.start, true): max(0, width - size.width)
        default: 0
        }
        return TableLayout(scale: scale, lineWidth: width, size: size, originX: originX, columnWidths: columns,
                           rowHeights: rows, cellFrames: frames, contentFrames: contents, unitTops: tops)
    }

    /// A cell's frame in a unit attachment's coordinates (top-left origin).
    func frame(ofCell index: Int, inUnit unit: Int) -> CGRect {
        let frame = cellFrames[index]
        return CGRect(x: (originX + frame.minX) * scale, y: (frame.minY - unitTops[unit]) * scale,
                      width: frame.width * scale, height: frame.height * scale)
    }
}

extension TableModel {
    /// Draws one unit into the current graphics context (top-left origin, flipped, as a view
    /// draws), whose origin is the unit's top-left on its line. Cell text goes through string
    /// drawing, so it needs the platform's current context to be this one.
    func draw(unit: Int, layout: TableLayout, in context: CGContext) {
        guard unit < units.count else { return }
        let top = layout.unitTops[unit], bottom = layout.unitTops[unit + 1]
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: layout.scale, y: layout.scale)
        context.translateBy(x: layout.originX, y: -top)
        let slice = CGRect(x: 0, y: top, width: layout.size.width, height: bottom - top)
        context.clip(to: slice.insetBy(dx: -1, dy: 0))
        let tableRect = CGRect(origin: .zero, size: layout.size)
        if let background {
            context.setFillColor(background)
            context.fill(tableRect)
        }
        let indices = unitCells[unit]
        for row in units[unit] {
            guard let color = rows[row].background else { continue }
            context.setFillColor(color)
            for index in indices where cells[index].row == row { context.fill(layout.cellFrames[index]) }
        }
        for index in indices {
            guard let color = cells[index].background else { continue }
            context.setFillColor(color)
            context.fill(layout.cellFrames[index])
        }
        for index in indices where cells[index].content.length > 0 {
            let frame = layout.contentFrames[index]
            cells[index].content.draw(with: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + 1),
                                      options: [.usesLineFragmentOrigin], context: nil)
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
    }
}
