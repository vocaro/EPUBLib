import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Builds a `<table>`'s attributed text: its caption as a paragraph, then one attachment per
/// row unit, each in a paragraph of its own with no spacing, so paginated flow can break
/// between rows. A table of one column is a layout box, not data: it returns nil, and the
/// builder flows its content as ordinary blocks (selectable, and paginated line by line).
enum TableContent {
    /// The row attachments' font: tiny, so a row's line is exactly as tall as its attachment
    /// whatever line-height multiple the paragraph has.
    static var rowFont: PlatformFont { PlatformFont.systemFont(ofSize: 1) }

    static func make(_ table: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        guard let (model, caption) = build(table, style: style, context: context) else { return nil }
        let output = NSMutableAttributedString()
        var captionText: NSAttributedString?
        var captionAtBottom = false
        if let caption {
            let captionStyle = context.style(caption, style)
            captionAtBottom = captionStyle.captionSide == .bottom || caption.attribute("align")?.lowercased() == "bottom"
            captionText = self.caption(caption, style: captionStyle, atBottom: captionAtBottom, context: context)
        }
        if let captionText, !captionAtBottom {
            output.append(captionText)
            output.append(NSAttributedString(string: "\n", attributes: captionText.attributes(at: captionText.length - 1, effectiveRange: nil)))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        paragraph.lineHeightMultiple = 1
        let separator: [NSAttributedString.Key: Any] = [.font: rowFont, .paragraphStyle: paragraph]
        for (index, unit) in model.units.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: separator)) }
            var attributes = separator
            if model.rows[unit.lowerBound].isHeader { attributes[.readerKeepWithNext] = true }
            output.append(NSAttributedString(attachment: TableRowsAttachment(table: model, unit: index), attributes: attributes))
        }
        if let captionText, captionAtBottom {
            output.append(NSAttributedString(string: "\n", attributes: separator))
            output.append(captionText)
        }
        return output
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

    private struct Placed {
        let element: ContentNode
        let style: ComputedStyle
        let row: Int, column: Int, rowSpan: Int, columnSpan: Int
    }
    private struct Group {
        let element: ContentNode?
        let style: ComputedStyle
        var rows: [ContentNode]
        let isHeader: Bool
    }

    static func build(_ table: ContentNode, style: ComputedStyle, context: RichContentContext) -> (TableModel, ContentNode?)? {
        let isDark = context.typography.isDark
        var caption: ContentNode?
        var columns: [ComputedStyle.Length] = []
        var head: Group?, bodies: [Group] = [], feet: [Group] = []
        var implicit: Group?
        func visible(_ element: ContentNode, _ parent: ComputedStyle) -> ComputedStyle? {
            let computed = context.style(element, parent)
            return computed.display == .none ? nil : computed
        }
        func closeImplicit() { if let group = implicit { bodies.append(group); implicit = nil } }
        for child in table.elementChildren where child.isHTML {
            switch child.name {
            case "caption" where caption == nil:
                if visible(child, style) != nil { caption = child }
            case "colgroup", "col":
                guard let groupStyle = visible(child, style) else { continue }
                let items = child.name == "col" ? [child] : child.elementChildren.filter { $0.isHTML("col") }
                if items.isEmpty {
                    let span = min(1000, max(1, Int(child.attribute("span") ?? "") ?? 1))
                    columns += Array(repeating: length(groupStyle.width, hint: child.attribute("width"), style: groupStyle), count: span)
                }
                for col in items {
                    let colStyle = context.style(col, groupStyle)
                    let span = min(1000, max(1, Int(col.attribute("span") ?? "") ?? 1))
                    var width = length(colStyle.width, hint: col.attribute("width"), style: colStyle)
                    if width == .auto { width = length(groupStyle.width, hint: child.attribute("width"), style: groupStyle) }
                    columns += Array(repeating: width, count: span)
                }
            case "thead", "tbody", "tfoot":
                closeImplicit()
                guard let groupStyle = visible(child, style) else { continue }
                let rows = child.elementChildren.filter { $0.isHTML("tr") }
                if child.name == "thead", head == nil { head = Group(element: child, style: groupStyle, rows: rows, isHeader: true) }
                else if child.name == "tfoot" { feet.append(Group(element: child, style: groupStyle, rows: rows, isHeader: false)) }
                else { bodies.append(Group(element: child, style: groupStyle, rows: rows, isHeader: false)) }
            case "tr":
                if implicit == nil { implicit = Group(element: nil, style: style, rows: [], isHeader: false) }
                implicit?.rows.append(child)
            default: break
            }
        }
        closeImplicit()
        let groups = (head.map { [$0] } ?? []) + bodies + feet

        // The slot grid: each cell takes the first free column of its row.
        var occupied: [[Bool]] = []
        var placed: [Placed] = []
        var rows: [TableModel.Row] = []
        var truncated = false
        var rowElements: [(row: ContentNode, group: ContentNode?)] = []
        groupLoop: for group in groups {
            let first = rows.count
            let groupRows = group.rows.compactMap { row in visible(row, group.style).map { (row, $0) } }
            for (offset, (row, rowStyle)) in groupRows.enumerated() {
                let index = first + offset
                while occupied.count <= index { occupied.append([]) }
                rowElements.append((row, group.element))
                rows.append(TableModel.Row(background: isDark ? nil : (rowStyle.backgroundColor ?? color(row.attribute("bgcolor")))?.cgColor,
                                           height: length(rowStyle.height, hint: row.attribute("height"), style: rowStyle).points ?? 0,
                                           isHeader: group.isHeader))
                var column = 0
                for cell in row.elementChildren where cell.isHTML("td") || cell.isHTML("th") {
                    guard let cellStyle = visible(cell, rowStyle) else { continue }
                    while column < occupied[index].count, occupied[index][column] { column += 1 }
                    let columnSpan = min(1000, max(1, Int(cell.attribute("colspan") ?? "") ?? 1))
                    // `rowspan="0"` spans one row, as WebKit (and so the WebKit reader) treats it;
                    // books written for WebKit put it on every cell.
                    let requested = Int(cell.attribute("rowspan") ?? "") ?? 1
                    let rowSpan = min(groupRows.count - offset, max(1, requested))
                    guard column + columnSpan <= TableModel.maximumColumns, placed.count < TableModel.maximumCells else {
                        truncated = true
                        if placed.count >= TableModel.maximumCells { break groupLoop }
                        continue
                    }
                    for r in index..<(index + rowSpan) {
                        while occupied.count <= r { occupied.append([]) }
                        if occupied[r].count < column + columnSpan {
                            occupied[r] += Array(repeating: false, count: column + columnSpan - occupied[r].count)
                        }
                        for c in column..<(column + columnSpan) { occupied[r][c] = true }
                    }
                    placed.append(Placed(element: cell, style: cellStyle, row: index, column: column,
                                         rowSpan: rowSpan, columnSpan: columnSpan))
                    column += columnSpan
                }
            }
        }
        let columnCount = max(occupied.map(\.count).max() ?? 0, 0)
        if truncated { context.report.report.unsupportedElements["table", default: 0] += 1 }
        guard columnCount > 1, !placed.isEmpty else { return nil }

        // Presentational hints: `border`, `cellspacing`, `cellpadding`, `align`, `bgcolor`.
        let borderAttribute = table.attribute("border").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 1 }
        let cellPadding = table.attribute("cellpadding").flatMap { ImageSizing.length($0, fontSize: style.fontSize)?.points }
        let defaultColor = isDark ? ReaderPalette.rule(dark: true) : (style.color?.platformColor ?? ReaderPalette.text(dark: false))
        func stroke(_ border: ComputedStyle.Border, color element: ComputedStyle.Color?) -> TableModel.Stroke? {
            guard border.isVisible else { return nil }
            let color = isDark ? ReaderPalette.rule(dark: true)
                : (border.color ?? element)?.platformColor ?? ReaderPalette.text(dark: false)
            return TableModel.Stroke(width: border.width, style: border.style, color: color.cgColor)
        }
        func strokes(_ style: ComputedStyle) -> TableModel.Borders {
            TableModel.Borders(top: stroke(style.border.top, color: style.color), right: stroke(style.border.right, color: style.color),
                               bottom: stroke(style.border.bottom, color: style.color), left: stroke(style.border.left, color: style.color))
        }
        var tableBorders = strokes(style)
        let hinted = borderAttribute.map { $0 > 0 } ?? false
        if hinted, tableBorders.widths == TableModel.Insets() {
            let line = TableModel.Stroke(width: CGFloat(min(borderAttribute ?? 1, 16)), style: .solid,
                                         color: (isDark ? ReaderPalette.rule(dark: true) : PlatformColor(white: 0.5, alpha: 1)).cgColor)
            tableBorders = TableModel.Borders(top: line, right: line, bottom: line, left: line)
        }
        var spacing = style.borderSpacing
        if spacing == CGSize(width: 2, height: 2), let value = table.attribute("cellspacing").flatMap({ ImageSizing.length($0, fontSize: style.fontSize)?.points }) {
            spacing = CGSize(width: value, height: value)
        }
        let collapse = style.borderCollapse

        var cells: [TableModel.Cell] = []
        cells.reserveCapacity(placed.count)
        for item in placed {
            let cellStyle = item.style
            var padding = insets(cellStyle.padding)
            if let cellPadding, max(padding.top, padding.right, padding.bottom, padding.left) <= 1 {
                padding = TableModel.Insets(top: cellPadding, right: cellPadding, bottom: cellPadding, left: cellPadding)
            }
            var borders = strokes(cellStyle)
            if hinted, borders.widths == TableModel.Insets() {
                let line = TableModel.Stroke(width: 1, style: .solid, color: defaultColor.cgColor)
                borders = TableModel.Borders(top: line, right: line, bottom: line, left: line)
            }
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
            let rowContext = rowElements[item.row]
            let content = drawable(context.renderContent(item.element, cellStyle))
            let noWrap = !cellStyle.whiteSpace.wraps || item.element.attribute("nowrap") != nil
            let maxContent = TableMeasure.maximumWidth(content)
            let minContent = noWrap ? maxContent : min(maxContent, TableMeasure.minimumWidth(content))
            let valign = item.element.attribute("valign") ?? rowContext.row.attribute("valign") ?? rowContext.group?.attribute("valign")
            cells.append(TableModel.Cell(
                row: item.row, column: item.column, rowSpan: item.rowSpan, columnSpan: item.columnSpan,
                content: content, text: TableMeasure.spokenText(content), isHeader: item.element.isHTML("th"),
                padding: padding, borders: borders, chrome: chrome,
                background: isDark ? nil : (cellStyle.backgroundColor ?? color(item.element.attribute("bgcolor")))?.cgColor,
                placement: placement(cellStyle.verticalAlign, hint: valign),
                width: length(cellStyle.width, hint: item.element.attribute("width"), style: cellStyle),
                height: length(cellStyle.height, hint: item.element.attribute("height"), style: cellStyle).points ?? 0,
                minContent: minContent, maxContent: maxContent))
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
            width: length(style.width, hint: table.attribute("width"), style: style), collapse: collapse,
            spacing: spacing, borders: tableBorders,
            background: isDark ? nil : (style.backgroundColor ?? color(table.attribute("bgcolor")))?.cgColor,
            alignment: alignment, isRightToLeft: style.direction == .rtl)
        return (model, caption)
    }

    /// Cell content as string drawing can draw it: nested tables as images.
    private static func drawable(_ content: NSAttributedString) -> NSAttributedString {
        var nested: [(NSRange, TableRowsAttachment)] = []
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if let rows = value as? TableRowsAttachment, !(rows is TableRowsImageAttachment) { nested.append((range, rows)) }
        }
        guard !nested.isEmpty else { return content }
        let copy = NSMutableAttributedString(attributedString: content)
        for (range, rows) in nested {
            copy.addAttribute(.attachment, value: TableRowsImageAttachment(table: rows.table, unit: rows.unit), range: range)
        }
        return copy
    }

    private static func length(_ css: ComputedStyle.Length, hint: String?, style: ComputedStyle) -> ComputedStyle.Length {
        css == .auto ? ImageSizing.length(hint, fontSize: style.fontSize) ?? .auto : css
    }

    private static func insets(_ edges: ComputedStyle.Edges<ComputedStyle.Length>) -> TableModel.Insets {
        TableModel.Insets(top: edges.top.points ?? 0, right: edges.right.points ?? 0,
                          bottom: edges.bottom.points ?? 0, left: edges.left.points ?? 0)
    }

    private static func placement(_ align: ComputedStyle.VerticalAlign, hint: String?) -> TableModel.Placement {
        switch align {
        case .middle: return .middle
        case .bottom, .textBottom: return .bottom
        case .baseline:
            switch hint?.lowercased() {
            case "middle"?, "center"?: return .middle
            case "bottom"?: return .bottom
            default: return .top
            }
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
