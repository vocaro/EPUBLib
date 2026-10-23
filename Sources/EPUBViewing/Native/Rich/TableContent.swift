import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Builds a `<table>`'s attributed text: its captions as paragraphs, then one attachment per
/// row, each in a paragraph of its own with no spacing, so paginated flow can break between any
/// two rows; rows a rowspan joins, and the header, keep with the next row (`.readerKeepWithNext`)
/// so they share a page when they fit. A table of one column is a layout box, not data: it returns nil, and the
/// builder flows its content as ordinary blocks (selectable, and paginated line by line), unless the flow would
/// read its parts in another order than they are shown in (`isWrittenInDisplayOrder`).
///
/// Nothing a grid holds is left out of it silently. Content written outside its rows and cells
/// takes the anonymous rows and cells of CSS 2.2 §17.2.1, and the cells the grid has no slot
/// for (past `TableModel.maximumColumns` or `maximumCells`) follow the rows as paragraphs,
/// counted for disclosure.
enum TableContent {
    /// The row attachments' font: tiny, so a row's line is exactly as tall as its attachment
    /// whatever line-height multiple the paragraph has.
    static var rowFont: PlatformFont { PlatformFont.systemFont(ofSize: 1) }

    static func make(_ table: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        guard let built = build(table, style: style, context: context) else { return nil }
        let model = built.model
        let output = NSMutableAttributedString()
        // CSS 2.2 §17.4: every caption is shown, above or below the rows as its own side says.
        var below = built.overflow
        for caption in built.captions {
            let captionStyle = context.style(caption, style)
            let atBottom = isBelow(caption, style: captionStyle)
            guard let text = self.caption(caption, style: captionStyle, atBottom: atBottom, context: context) else { continue }
            if atBottom { below.append(text); continue }
            output.append(text)
            output.append(NSAttributedString(string: "\n", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        paragraph.lineHeightMultiple = 1
        let separator: [NSAttributedString.Key: Any] = [.font: rowFont, .paragraphStyle: paragraph]
        for row in model.rows.indices {
            if row > 0 { output.append(NSAttributedString(string: "\n", attributes: separator)) }
            var attributes = separator
            if model.keepsWithNext[row] { attributes[.readerKeepWithNext] = true }
            output.append(NSAttributedString(attachment: TableRowAttachment(table: model, row: row), attributes: attributes))
        }
        for (index, text) in below.enumerated() {
            let ending = index == 0 ? separator : below[index - 1].attributes(at: below[index - 1].length - 1, effectiveRange: nil)
            output.append(NSAttributedString(string: "\n", attributes: ending))
            output.append(text)
        }
        if output.length > 0 {
            output.addAttribute(.readerTableModel, value: model, range: NSRange(location: 0, length: output.length))
        }
        return output
    }

    /// Whether a caption is shown below the rows, by its own `caption-side` or `align`.
    private static func isBelow(_ caption: ContentNode, style: ComputedStyle) -> Bool {
        style.captionSide == .bottom || caption.attribute("align")?.lowercased() == "bottom"
    }

    private static func caption(_ element: ContentNode, style: ComputedStyle, atBottom: Bool,
                                context: RichContentContext) -> NSAttributedString? {
        let text = NSMutableAttributedString(attributedString: context.renderContent(element, style))
        guard text.length > 0 else { return nil }
        let full = NSRange(location: 0, length: text.length)
        let alignment: NSTextAlignment = switch style.textAlign {
        case .start, .justify: .natural
        case .end: style.direction == .rtl ? .left : .right
        case .left: .left
        case .right: .right
        case .center: .center
        }
        var paragraphs: [NSRange] = []
        (text.string as NSString).enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, _, range, _ in
            paragraphs.append(range)
        }
        for (index, range) in paragraphs.enumerated() {
            let existing = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let paragraph = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            if existing == nil { paragraph.alignment = alignment }
            // A little air between the caption and the table, on the table's side.
            if !atBottom, index == paragraphs.count - 1 { paragraph.paragraphSpacing = max(paragraph.paragraphSpacing, style.fontSize * 0.3) }
            if atBottom, index == 0 { paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, style.fontSize * 0.3) }
            text.addAttribute(.paragraphStyle, value: paragraph, range: range)
            if !atBottom { text.addAttribute(.readerKeepWithNext, value: true, range: NSRange(location: range.location, length: 1)) }
        }
        return text
    }

    // MARK: The table model

    struct Built {
        let model: TableModel
        /// Every caption that is shown, in document order.
        let captions: [ContentNode]
        /// The content of the cells the grid has no slot for, in reading order.
        let overflow: [NSAttributedString]
    }

    /// A row or a cell as written, or the content written where one belongs. CSS 2.2 §17.2.1
    /// puts an anonymous row around what a table or a row group holds outside its rows, and an
    /// anonymous cell around what a row holds outside its cells. XHTML is parsed as XML, which
    /// repairs no tree, so such content arrives where it was written.
    private enum Part {
        case element(ContentNode)
        case anonymous([ContentNode])

        /// Where the part is written: its element's, or its first node's, document order.
        var order: Int {
            switch self {
            case .element(let node): node.order
            case .anonymous(let nodes): nodes[0].order
            }
        }
    }
    /// A cell waiting for its slot.
    private final class Cell {
        /// nil for an anonymous cell.
        let element: ContentNode?
        let style: ComputedStyle
        /// Rendered ahead of its placing where only content that shows makes a cell or a row.
        var content: NSAttributedString?
        init(element: ContentNode?, style: ComputedStyle, content: NSAttributedString?) {
            self.element = element; self.style = style; self.content = content
        }
    }
    private struct Placed {
        let cell: Cell
        let row: Int, column: Int, rowSpan: Int
        var columnSpan: Int
        /// Written with a span that runs past the columns the grid holds: the cell reaches the
        /// table's last column instead.
        var reaches = false
    }
    private final class Group {
        let element: ContentNode?
        let style: ComputedStyle
        var rows: [Part]
        let isHeader: Bool
        init(element: ContentNode?, style: ComputedStyle, rows: [Part], isHeader: Bool) {
            self.element = element; self.style = style; self.rows = rows; self.isHeader = isHeader
        }
    }
    private final class Row {
        let element: ContentNode?
        let style: ComputedStyle
        let cells: [Cell]?
        init(_ element: ContentNode?, _ style: ComputedStyle, _ cells: [Cell]?) {
            self.element = element; self.style = style; self.cells = cells
        }
    }
    private struct Arrangement {
        var placed: [Placed] = []
        var rows: [TableModel.Row] = []
        var rowElements: [(row: ContentNode?, group: ContentNode?)] = []
        var occupied: [[Bool]] = []
        /// Cells the grid has no slot for, in reading order.
        var leftOut: [Cell] = []
        /// Content outside the rows and cells was passed over.
        var skippedAnonymous = false
        /// The columns of the cells placed as written.
        var writtenColumns: Int { placed.lazy.filter { !$0.reaches }.map { $0.column + $0.columnSpan }.max() ?? 0 }
    }

    private static let tableParts: Set<String> = ["caption", "colgroup", "col", "thead", "tbody", "tfoot", "tr"]
    private static let rowParts: Set<String> = ["tr"]
    private static let cellParts: Set<String> = ["td", "th"]

    /// `nodes` as the elements named in `names` and the runs of other content between them.
    /// White space alone is not content (CSS 2.2 §17.2.1, the first step).
    private static func parts(_ nodes: [ContentNode], _ names: Set<String>) -> [Part] {
        var result: [Part] = [], run: [ContentNode] = []
        func close() {
            let isContent = run.contains { node in
                node.isElement || node.text.utf16.contains { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0x0C }
            }
            if isContent { result.append(.anonymous(run)) }
            run = []
        }
        for node in nodes {
            if node.isHTML, names.contains(node.name) {
                close()
                result.append(.element(node))
            } else { run.append(node) }
        }
        close()
        return result
    }

    /// The style of an anonymous table box: what a child inherits from the box it stands in,
    /// with no edges, size or background of its own.
    private static func anonymous(in parent: ComputedStyle) -> ComputedStyle {
        var style = parent
        style.generated = nil
        style.display = .tableCell
        style.float = .none
        style.clear = .none
        style.position = .static
        style.margin = .init(.zero)
        style.padding = .init(.zero)
        style.border = .init(ComputedStyle.Border())
        style.width = .auto; style.height = .auto
        style.minWidth = .auto; style.minHeight = .auto; style.maxWidth = .auto; style.maxHeight = .auto
        style.backgroundColor = nil
        style.verticalAlign = .baseline
        style.blockifiesChildren = false
        style.boxAlignment = ComputedStyle.BoxAlignment()
        return style
    }

    static func build(_ table: ContentNode, style: ComputedStyle, context: RichContentContext) -> Built? {
        Builder(table: table, style: style, context: context).build()
    }

    /// Keep construction state on the heap. In particular `ComputedStyle` is a large value:
    /// a monolithic builder and its captured local functions reserved their temporary copies
    /// for the whole recursive cell render, overflowing a detached task's 512 KB stack.
    private final class Builder {
        let table: ContentNode
        let style: ComputedStyle
        let context: RichContentContext
        var isDark: Bool { context.typography.isDark }
        var theme: ReaderTheme { context.typography.theme }
        var captions: [ContentNode] = []
        var columns: [ComputedStyle.Length] = []
        var head: Group?, bodies: [Group] = [], feet: [Group] = []
        var implicit: Group?
        var groups: [Group] = []
        var arrangement = Arrangement()
        var columnCount = 0
        var overflow: [NSAttributedString] = []
        var rendered: [NSAttributedString] = []
        /// The table, a row group or a row has a `::before` or `::after` that could show
        /// characters. A grid shows its cells' and captions' generated content, not theirs.
        var hidesGeneratedContent: Bool

        init(table: ContentNode, style: ComputedStyle, context: RichContentContext) {
            self.table = table; self.style = style; self.context = context
            hidesGeneratedContent = style.generated?.mayGenerateText == true
        }

        func visible(_ element: ContentNode, _ parent: ComputedStyle) -> ComputedStyle? {
            let computed = context.style(element, parent)
            return computed.display == .none ? nil : computed
        }
        private func collectGroups() {
            func closeImplicit() { if let group = implicit { bodies.append(group); implicit = nil } }
            for part in TableContent.parts(table.children, TableContent.tableParts) {
                // A row, or content outside every row, belongs to the body it is written in.
                guard case .element(let child) = part, child.name != "tr" else {
                    if implicit == nil { implicit = Group(element: nil, style: style, rows: [], isHeader: false) }
                    implicit?.rows.append(part)
                    continue
                }
                switch child.name {
                case "caption":
                    if visible(child, style) != nil { captions.append(child) }
                case "colgroup", "col":
                    guard let groupStyle = visible(child, style) else { continue }
                    let items = child.name == "col" ? [child] : child.elementChildren.filter { $0.isHTML("col") }
                    if items.isEmpty {
                        let span = min(1000, max(1, Int(child.attribute("span") ?? "") ?? 1))
                        columns += Array(repeating: groupStyle.width, count: span)
                    }
                    for col in items {
                        let colStyle = context.style(col, groupStyle)
                        let span = min(1000, max(1, Int(col.attribute("span") ?? "") ?? 1))
                        columns += Array(repeating: colStyle.width == .auto ? groupStyle.width : colStyle.width, count: span)
                    }
                case "thead", "tbody", "tfoot":
                    closeImplicit()
                    guard let groupStyle = visible(child, style) else { continue }
                    if groupStyle.generated?.mayGenerateText == true { hidesGeneratedContent = true }
                    let rows = TableContent.parts(child.children, TableContent.rowParts)
                    if child.name == "thead", head == nil { head = Group(element: child, style: groupStyle, rows: rows, isHeader: true) }
                    else if child.name == "tfoot" { feet.append(Group(element: child, style: groupStyle, rows: rows, isHeader: false)) }
                    else { bodies.append(Group(element: child, style: groupStyle, rows: rows, isHeader: false)) }
                default: break
                }
            }
            closeImplicit()
            groups = (head.map { [$0] } ?? []) + bodies + feet

        }

        /// Whether the parts that hold rows and the captions are written in the order they are
        /// shown in: the captions above the rows, the header group, the bodies, the footer
        /// groups, then the captions below (CSS 2.2 §17.2 and §17.4). HTML 4 had `tfoot` written
        /// before `tbody`.
        private var isWrittenInDisplayOrder: Bool {
            var above: [Int] = [], below: [Int] = []
            for caption in captions {
                if TableContent.isBelow(caption, style: context.style(caption, style)) { below.append(caption.order) }
                else { above.append(caption.order) }
            }
            let rows: [Int] = groups.filter { !$0.rows.isEmpty }.map { $0.element?.order ?? $0.rows[0].order }
            let orders = above + rows + below
            return zip(orders, orders.dropFirst()).allSatisfy { $0 < $1 }
        }

        /// A row's cells: those written, and with `anonymous` one around each run of other
        /// content that shows. `rendered` renders the written ones too.
        func cells(_ parts: [Part], in parent: ComputedStyle, anonymous: Bool, rendered: Bool, skipped: inout Bool) -> [Cell] {
            var cells: [Cell] = []
            for part in parts {
                switch part {
                case .element(let cell):
                    guard let entry = writtenCell(cell, parent: parent) else { continue }
                    if rendered { entry.content = render(entry) }
                    cells.append(entry)
                case .anonymous(let nodes):
                    guard anonymous else { skipped = true; continue }
                    let entry = Cell(element: nil, style: TableContent.anonymous(in: parent), content: nil)
                    entry.content = renderNodes(nodes, cell: entry)
                    if (entry.content?.length ?? 0) > 0 { cells.append(entry) }
                }
            }
            return cells
        }

        private func writtenCell(_ element: ContentNode, parent: ComputedStyle) -> Cell? {
            guard let style = visible(element, parent) else { return nil }
            return Cell(element: element, style: style, content: nil)
        }

        private func renderNodes(_ nodes: [ContentNode], cell: Cell) -> NSAttributedString {
            context.renderNodes(nodes, cell.style)
        }

        /// The slot grid: each cell takes the first free column of its row. Without `anonymous`
        /// it holds the rows and cells as written, and nothing is rendered.
        private func collectRows(_ group: Group, anonymous: Bool, skipped: inout Bool) -> [Row] {
            // The rows that are shown; an anonymous one brings its cells.
            var groupRows: [Row] = []
            for part in group.rows {
                switch part {
                case .element(let row):
                    guard let rowStyle = visible(row, group.style) else { continue }
                    if rowStyle.generated?.mayGenerateText == true { hidesGeneratedContent = true }
                    let rowCells = cells(TableContent.parts(row.children, TableContent.cellParts), in: rowStyle,
                                         anonymous: anonymous, rendered: false, skipped: &skipped)
                    groupRows.append(Row(row, rowStyle, rowCells))
                case .anonymous(let nodes):
                    guard anonymous else { skipped = true; continue }
                    // An anonymous row exists for the content that shows in it.
                    let rowCells = cells(TableContent.parts(nodes, TableContent.cellParts), in: group.style, anonymous: true, rendered: true,
                                         skipped: &skipped)
                    if rowCells.contains(where: { ($0.content?.length ?? 0) > 0 }) { groupRows.append(Row(nil, group.style, rowCells)) }
                }
            }
            return groupRows
        }

        func arrange(anonymous: Bool) -> Arrangement {
            var skipped = false
            let prepared = groups.map { ($0, collectRows($0, anonymous: anonymous, skipped: &skipped)) }
            var result = place(prepared)
            result.skippedAnonymous = skipped
            return result
        }

        private func place(_ prepared: [(Group, [Row])]) -> Arrangement {
            var result = Arrangement()
            // Past the cell bound no further row is laid out.
            var isFull = false
            for (group, groupRows) in prepared {
                let first = result.rows.count
                for (offset, row) in groupRows.enumerated() {
                    let rowCells = row.cells ?? []
                    guard !isFull else { result.leftOut += rowCells; continue }
                    let index = first + offset
                    while result.occupied.count <= index { result.occupied.append([]) }
                    result.rowElements.append((row.element, group.element))
                    let background = row.element.flatMap { row.style.backgroundColor ?? TableContent.color($0.attribute("bgcolor")) }
                    let height = row.element == nil ? nil : row.style.height.points
                    result.rows.append(TableModel.Row(background: isDark || row.style.isHidden ? nil : background?.cgColor, height: height ?? 0,
                                                      isHeader: group.isHeader))
                    var column = 0
                    var leavesOut = false
                    for (position, cell) in rowCells.enumerated() {
                        while column < result.occupied[index].count, result.occupied[index][column] { column += 1 }
                        var columnSpan = min(1000, max(1, Int(cell.element?.attribute("colspan") ?? "") ?? 1))
                        // `rowspan="0"` spans one row, as WebKit (and so the WebKit reader) treats it;
                        // books written for WebKit put it on every cell.
                        let requested = Int(cell.element?.attribute("rowspan") ?? "") ?? 1
                        var rowSpan = min(groupRows.count - offset, max(1, requested))
                        guard result.placed.count < TableModel.maximumCells else {
                            isFull = true
                            result.leftOut.append(cell)
                            continue
                        }
                        var reaches = false
                        if column + columnSpan > TableModel.maximumColumns {
                            // HTML keeps a cell whose span runs past the table's columns. The last
                            // cell of a row can reach the last column without moving another cell;
                            // any other has no slot, and neither has one that would then come
                            // before a cell written ahead of it.
                            guard column < TableModel.maximumColumns, position == rowCells.count - 1, !leavesOut else {
                                leavesOut = true
                                result.leftOut.append(cell)
                                continue
                            }
                            // It takes one slot here, so the rows below keep the cells they had.
                            (columnSpan, rowSpan, reaches) = (1, 1, true)
                        }
                        for r in index..<(index + rowSpan) {
                            while result.occupied.count <= r { result.occupied.append([]) }
                            if result.occupied[r].count < column + columnSpan {
                                result.occupied[r] += Array(repeating: false, count: column + columnSpan - result.occupied[r].count)
                            }
                            for c in column..<(column + columnSpan) { result.occupied[r][c] = true }
                        }
                        result.placed.append(Placed(cell: cell, row: index, column: column, rowSpan: rowSpan,
                                                    columnSpan: columnSpan, reaches: reaches))
                        column += columnSpan
                    }
                }
            }
            return result
        }

        func stroke(_ border: ComputedStyle.Border, color element: ComputedStyle.Color?) -> TableModel.Stroke? {
            guard border.isVisible else { return nil }
            let color = isDark ? theme.rule
                : (border.color ?? element)?.platformColor ?? theme.text
            return TableModel.Stroke(width: border.width, style: border.style, color: color.cgColor)
        }
        func strokes(_ style: ComputedStyle) -> TableModel.Borders {
            TableModel.Borders(top: stroke(style.border.top, color: style.color), right: stroke(style.border.right, color: style.color),
                               bottom: stroke(style.border.bottom, color: style.color), left: stroke(style.border.left, color: style.color))
        }
        private func render(_ cell: Cell) -> NSAttributedString {
            if let content = cell.content { return content }
            guard let element = cell.element else { return NSAttributedString() }
            return context.renderContent(element, cell.style)
        }

        private func makeCell(_ item: Placed, rows: [TableModel.Row], columnCount: Int, tableBorders: TableModel.Borders, collapse: Bool,
                              cellPadding: CGFloat?, hinted: Bool, defaultColor: PlatformColor, content: NSAttributedString) -> TableModel.Cell {
            // The table's `cellpadding` and `border` are hints for its `td` and `th` elements: an
            // anonymous cell has neither padding nor borders.
            let cellStyle = item.cell.style, element = item.cell.element
            var padding = TableContent.insets(cellStyle.padding)
            if element != nil, let cellPadding, max(padding.top, padding.right, padding.bottom, padding.left) <= 1 {
                padding = TableModel.Insets(top: cellPadding, right: cellPadding, bottom: cellPadding, left: cellPadding)
            }
            var borders = strokes(cellStyle)
            if element != nil, hinted, borders.widths == TableModel.Insets() {
                let line = TableModel.Stroke(width: 1, style: .solid, color: defaultColor.cgColor)
                borders = TableModel.Borders(top: line, right: line, bottom: line, left: line)
            }
            // A hidden cell keeps its room and draws neither its borders nor its background; its
            // content is hidden with it unless it sets `visibility: visible` again.
            if cellStyle.isHidden { borders = borders.hidden }
            // In the separated model a cell's borders are inside its slot; collapsed, half of
            // each line (the table's own on the outside edges) is.
            var chrome = padding
            let own = borders.widths
            if collapse {
                let outer = tableBorders.widths
                chrome.top += max(own.top, item.row == 0 ? outer.top : 0) / 2
                chrome.bottom += max(own.bottom, item.row + item.rowSpan == rows.count ? outer.bottom : 0) / 2
                chrome.left += max(own.left, item.column == 0 ? outer.left : 0) / 2
                chrome.right += max(own.right, item.column + item.columnSpan == columnCount ? outer.right : 0) / 2
            } else {
                chrome.top += own.top; chrome.bottom += own.bottom; chrome.left += own.left; chrome.right += own.right
            }
            let noWrap = !cellStyle.whiteSpace.wraps || element?.attribute("nowrap") != nil
            let maxContent = TableMeasure.maximumWidth(content)
            let minContent = noWrap ? maxContent : min(maxContent, TableMeasure.minimumWidth(content))
            return TableModel.Cell(
                row: item.row, column: item.column, rowSpan: item.rowSpan, columnSpan: item.columnSpan,
                content: content, text: TableMeasure.spokenText(content), isHeader: element?.isHTML("th") ?? false,
                scope: TableContent.scope(element),
                padding: padding, borders: borders, chrome: chrome,
                background: isDark || cellStyle.isHidden ? nil
                    : (cellStyle.backgroundColor ?? TableContent.color(element?.attribute("bgcolor")))?.cgColor,
                placement: TableContent.placement(cellStyle.verticalAlign),
                width: cellStyle.width, height: cellStyle.height.points ?? 0,
                minContent: minContent, maxContent: maxContent)
        }
        func build() -> Built? {
            collectGroups()
            // A table is a grid when the cells written in its rows take more than one column. Whatever
            // else it holds joins a grid and never makes one: the content of a table that flows as
            // text flows with it. Text flows in document order, so a table of one column is a grid
            // too when it is written in another order than it is shown in, a footer before its body.
            arrangement = arrange(anonymous: false)
            guard arrangement.writtenColumns > 1 || (arrangement.writtenColumns == 1 && !isWrittenInDisplayOrder) else { return nil }
            if hidesGeneratedContent { context.report.report.generatedContentOmitted = true }
            if arrangement.skippedAnonymous { arrangement = arrange(anonymous: true) }
            columnCount = arrangement.placed.map { $0.column + $0.columnSpan }.max() ?? 0
            for index in arrangement.placed.indices where arrangement.placed[index].reaches {
                let cell = arrangement.placed[index], taken = arrangement.occupied[cell.row]
                var end = cell.column + 1
                while end < columnCount, end >= taken.count || !taken[end] { end += 1 }
                arrangement.placed[index].columnSpan = end - cell.column
            }
            renderCells()
            return assemble()
        }

        /// The recursive phase holds no border/style measurement temporaries on the stack.
        private func renderCells() {
            if !arrangement.leftOut.isEmpty {
                context.report.report.unsupportedElements["table", default: 0] += 1
                for cell in arrangement.leftOut {
                    let content = render(cell)
                    if content.length > 0 { overflow.append(content) }
                }
            }
            rendered = arrangement.placed.map { render($0.cell) }
        }

        private func assemble() -> Built {
            let placed = arrangement.placed, rows = arrangement.rows, rowElements = arrangement.rowElements
            // Presentational hints: `border`, `cellspacing`, `cellpadding`, `align`, `bgcolor`.
            let borderAttribute = table.attribute("border").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 1 }
            let cellPadding = table.attribute("cellpadding").flatMap { ImageSizing.length($0, fontSize: style.fontSize)?.points }
            let defaultColor = isDark ? theme.rule : (style.color?.platformColor ?? theme.text)
            var tableBorders = strokes(style)
            let hinted = borderAttribute.map { $0 > 0 } ?? false
            if hinted, tableBorders.widths == TableModel.Insets() {
                let line = TableModel.Stroke(width: CGFloat(min(borderAttribute ?? 1, 16)), style: .solid,
                                             color: (isDark ? theme.rule : PlatformColor(white: 0.5, alpha: 1)).cgColor)
                tableBorders = TableModel.Borders(top: line, right: line, bottom: line, left: line)
            }
            // A hidden table draws no borders or background of its own; a row, a cell or content
            // in them that sets `visibility: visible` again is drawn.
            if style.isHidden { tableBorders = tableBorders.hidden }
            var spacing = style.borderSpacing
            if spacing == CGSize(width: 2, height: 2), let value = table.attribute("cellspacing").flatMap({ ImageSizing.length($0, fontSize: style.fontSize)?.points }) {
                spacing = CGSize(width: value, height: value)
            }
            let collapse = style.borderCollapse

            let cells = zip(placed, rendered).map { item, content in
                makeCell(item, rows: rows, columnCount: columnCount,
                         tableBorders: tableBorders, collapse: collapse, cellPadding: cellPadding,
                         hinted: hinted, defaultColor: defaultColor, content: content)
            }
            let alignment: TableModel.Alignment
            switch (style.margin.left, style.margin.right, table.attribute("align")?.lowercased()) {
            case (_, _, "center"?), (.auto, .auto, _): alignment = .center
            case (_, _, "right"?): alignment = style.direction == .rtl ? .start : .end
            case (_, _, "left"?): alignment = style.direction == .rtl ? .end : .start
            case (.auto, _, _): alignment = .end
            default: alignment = .start
            }
            let model = TableModel(
                cells: cells, rows: rows, columnCount: columnCount, columns: columns,
                width: style.width, collapse: collapse,
                spacing: spacing, borders: tableBorders,
                background: isDark || style.isHidden ? nil : (style.backgroundColor ?? TableContent.color(table.attribute("bgcolor")))?.cgColor,
                alignment: alignment, isRightToLeft: style.direction == .rtl,
                isData: TableContent.isData(table, hasHeaderOrFooter: head != nil || !feet.isEmpty, rows: rowElements.map(\.row),
                               cells: zip(placed, cells).map { ($0.cell.element, $0.row, $0.column, $1.borders) }))
            model.sourceOrder = table.order
            return Built(model: model, captions: captions, overflow: overflow)
        }
    }

    private static func scope(_ cell: ContentNode?) -> TableModel.Scope {
        guard let cell, cell.isHTML("th") else { return .automatic }
        switch cell.attribute("scope")?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "row"?: return .row
        case "col"?: return .column
        case "rowgroup"?: return .rowGroup
        case "colgroup"?: return .columnGroup
        default: return .automatic
        }
    }

    /// Whether a table holds data or arranges content, which HTML has no element to say. A
    /// `role` decides it. Without one this is WebKit's test (`AXTableHelpers`, as Safari and
    /// Apple Books apply it), on what this reader builds and draws: a table is data when it
    /// has a caption, a summary, a header or footer group, columns or `rules`; a row or cell
    /// role, or a cell that names its headers, its scope, an abbreviation or an axis; twenty
    /// rows or twenty cells in a row; a first row or first column of header cells alone; ten
    /// cells ruled above and below or on both sides, or half its cells so ruled or ruled on
    /// any one side. One thing is wider than WebKit's: any header cell makes a table data,
    /// since a row cannot say what a cell heads. One is narrower: WebKit also counts cells
    /// with a background of their own and rows of alternating backgrounds, which the dark
    /// appearance does not compute, and a table must be the same thing in either appearance.
    private static func isData(_ table: ContentNode, hasHeaderOrFooter: Bool, rows: [ContentNode?],
                               cells: [(element: ContentNode?, row: Int, column: Int, borders: TableModel.Borders)]) -> Bool {
        func role(_ node: ContentNode?) -> String? { node?.attribute("role")?.trimmingCharacters(in: .whitespaces).lowercased() }
        func has(_ node: ContentNode?, _ names: [String]) -> Bool {
            names.contains { !(node?.attribute($0)?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
        }
        switch role(table) {
        case "presentation"?, "none"?: return false
        case "table"?, "grid"?, "treegrid"?: return true
        default: break
        }
        if hasHeaderOrFooter || has(table, ["summary", "rules"]) { return true }
        if table.elementChildren.contains(where: { $0.isHTML && ["caption", "col", "colgroup"].contains($0.name) }) { return true }
        if rows.contains(where: { role($0) == "row" }) { return true }
        let widest = Dictionary(grouping: cells) { $0.row }.values.map { $0.count }.max() ?? 0
        if (rows.count >= 20 && widest >= 2) || (rows.count >= 2 && widest >= 20) { return true }
        let written = cells.filter { $0.element != nil }
        if written.contains(where: { cell in
            cell.element?.isHTML("th") == true || has(cell.element, ["headers", "abbr", "axis", "scope"])
                || ["cell", "gridcell", "columnheader", "rowheader"].contains(role(cell.element) ?? "")
        }) { return true }
        guard written.count > 1 else { return false }
        // Ruled as a grid. A cell counts once for each side, and once more when it is ruled on
        // two facing sides.
        let ruled = written.map { $0.borders }
        let facing = ruled.filter { ($0.top != nil && $0.bottom != nil) || ($0.left != nil && $0.right != nil) }.count
        let needed = written.count / 2
        if facing >= 10 || facing >= needed { return true }
        return [ruled.filter { $0.top != nil }, ruled.filter { $0.bottom != nil }, ruled.filter { $0.left != nil },
                ruled.filter { $0.right != nil }].contains { $0.count >= needed }
    }

    private static func insets(_ edges: ComputedStyle.Edges<ComputedStyle.Length>) -> TableModel.Insets {
        TableModel.Insets(top: edges.top.points ?? 0, right: edges.right.points ?? 0,
                          bottom: edges.bottom.points ?? 0, left: edges.left.points ?? 0)
    }

    /// Where a cell's content sits, from its computed `vertical-align`, which a `valign` reaches
    /// as a hint and a row and its group pass down (HTML §15.3.8). A baseline is placed at the top.
    private static func placement(_ align: ComputedStyle.VerticalAlign) -> TableModel.Placement {
        switch align {
        case .middle: return .middle
        case .bottom, .textBottom: return .bottom
        default: return .top
        }
    }

    /// An HTML `bgcolor`: `#rgb`, `#rrggbb`, or a basic color name.
    static func color(_ value: String?) -> ComputedStyle.Color? {
        guard var hex = value?.trimmingCharacters(in: .whitespaces).lowercased(), !hex.isEmpty else { return nil }
        let names = ["white": "ffffff", "black": "000000", "silver": "c0c0c0", "gray": "808080", "grey": "808080",
                     "red": "ff0000", "yellow": "ffff00", "green": "008000", "blue": "0000ff", "navy": "000080",
                     "aqua": "00ffff", "teal": "008080", "lime": "00ff00", "maroon": "800000", "olive": "808000",
                     "purple": "800080", "fuchsia": "ff00ff"]
        if let named = names[hex] { hex = named }
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return ComputedStyle.Color(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                                   blue: CGFloat(value & 0xFF) / 255)
    }
}

extension ComputedStyle.Length {
    /// The length in points when it is absolute.
    var points: CGFloat? { if case .points(let value) = self { value } else { nil } }
}
