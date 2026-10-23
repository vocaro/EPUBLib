import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One source row of a table, or one of its pagination-time continuations. Continuations
/// retain the source attachment character; only their drawing and spoken text differ. Whole
/// rows in continuous scroll have their full height. Native cell interaction views use the
/// same line slices and glyph metrics, without changing the attachment's source character.
final class TableRowAttachment: ReaderAttachment {
    let table: TableModel
    let row: Int
    let fragment: TableRowFragment?
    private let fragmentLayout: TableLayout?
    #if os(iOS)
    /// The last image drawn, by size, scale and viewport height: UIKit asks on every display.
    private let lock = NSLock()
    private var cached: (key: [CGFloat], image: UIImage)?
    #endif

    init(table: TableModel, row: Int, fragment: TableRowFragment? = nil, layout: TableLayout? = nil) {
        self.table = table; self.row = row; self.fragment = fragment; fragmentLayout = layout
        super.init()
    }
    required init?(coder: NSCoder) { nil }

    static func viewportHeight(_ container: NSTextContainer?, width: CGFloat) -> CGFloat {
        ReaderTextContainer.available(in: container, lineWidth: width).height
    }

    func layout(width: CGFloat, viewportHeight: CGFloat) -> TableLayout {
        fragmentLayout ?? table.layout(available: width, viewportHeight: viewportHeight)
    }

    /// Full row height in scroll, or one continuation's measured height in paginated flow.
    func height(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let layout = layout(width: width, viewportHeight: viewportHeight)
        let slice = fragment ?? layout.fragments(ofRow: row, maximumHeight: .greatestFiniteMagnitude)[0]
        return slice.height * layout.scale * slice.fitScale
    }

    /// A row takes the rest of its line, whatever its table holds.
    static func width(on line: Line) -> CGFloat { max(1, line.width - max(line.position, line.leadingIndent)) }

    override func layoutBounds(_ line: Line) -> CGRect {
        let width = Self.width(on: line)
        return CGRect(x: 0, y: line.font?.descender ?? 0, width: width,
                      height: height(width: width, viewportHeight: line.viewport.height))
    }

    override func contentWidths() -> (min: CGFloat, max: CGFloat) {
        let constraints = table.constraints
        return (constraints.minimumTableWidth, constraints.maximumTableWidth)
    }

    /// The cells that start in this row, joined by tabs. The rows' own line breaks separate rows,
    /// and the caption is a paragraph of its own.
    override var textEquivalent: String { cellWords.joined(separator: "\t") }

    /// The words of each cell read where this row stands, in column order: the cells that
    /// start in a whole row, and each cell a continuation holds lines of, by those lines. A
    /// cell without words is there with none.
    var cellWords: [String] { spokenCellWords.map(\.words) }

    /// `cellWords`, each with the index of its cell in the table's cells.
    var spokenCellWords: [(cell: Int, words: String)] {
        if let fragment, let layout = fragmentLayout {
            return fragment.cells.sorted { table.cells[$0.cell].column < table.cells[$1.cell].column }.map { entry in
                return (entry.cell, layout.cellText[entry.cell].spokenText(inLines: entry.lines))
            }
        }
        return table.rowCells[row].filter { table.cells[$0].row == row }
            .sorted { table.cells[$0].column < table.cells[$1].column }.map { ($0, table.cells[$0].text) }
    }

    /// The languages of `textEquivalent`: each cell's words in the language most of the cell
    /// is in (`ReaderSpokenLanguages`).
    var spokenLanguages: ReaderSpokenLanguages {
        var parts: [(text: String, language: String?)] = []
        for (index, entry) in spokenCellWords.enumerated() {
            if index > 0 { parts.append(("\t", nil)) }
            parts.append((entry.words, table.cells[entry.cell].spokenLanguage))
        }
        return ReaderSpokenLanguages(parts)
    }

    /// The row has nothing to say where it stands: its cells hold no words there, and nothing
    /// but decoration besides, as a row that spaces out a table used for layout does, or images
    /// and rules the book keeps from assistive technology. A link is something to follow
    /// whatever it holds, and any other rule or a formula something to say, so a row that
    /// holds one is not such a row.
    var saysNothing: Bool {
        guard cellWords.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) else { return false }
        if let fragment, let layout = fragmentLayout {
            return fragment.cells.allSatisfy { entry in
                guard let first = entry.lines.first, let last = entry.lines.last else { return true }
                let text = layout.cellText[entry.cell], start = text.lines[first].characters.location
                return Self.saysNothing(text.interactionText, in: NSRange(location: start, length: text.lines[last].characters.upperBound - start))
            }
        }
        return table.rowCells[row].map { table.cells[$0] }.filter { $0.row == row }
            .allSatisfy { Self.saysNothing($0.content, in: NSRange(location: 0, length: $0.content.length)) }
    }

    private static func saysNothing(_ content: NSAttributedString, in range: NSRange) -> Bool {
        var silent = true
        content.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.link] != nil { silent = false }
            else if let image = attributes[.attachment] as? ReaderImageAttachment { silent = image.isPassedOverByAssistiveTechnology }
            else if let rule = attributes[.attachment] as? ReaderRuleAttachment { silent = rule.isHiddenFromAssistiveTechnology }
            else if let row = attributes[.attachment] as? TableRowAttachment { silent = row.saysNothing }
            else if attributes[.attachment] != nil { silent = false }
            if !silent { stop.pointee = true }
        }
        return silent
    }

    /// A cell where this row stands, for an assistive technology that is given cells.
    struct SpokenCell {
        var cell: Int
        /// The words the cell shows here and has not said in a row above: all of them where
        /// it starts in a whole row, a continuation's own in pages.
        var text: String
        /// The pictures among them that say something: not the ones the book marks as decoration
        /// or keeps from assistive technology.
        var images: [ReaderImageAttachment]
        /// Where each of those pictures is drawn, in the row's coordinates.
        var imageFrames: [CGRect]
        /// The cell's box in the row's coordinates, as drawn, not cut to the row.
        var frame: CGRect
        /// The cell begins here: in this row, at its top.
        var starts: Bool
        /// The cell has nothing to say anywhere: no words, and no picture but decoration or ones
        /// the book keeps from assistive technology.
        var isBlank: Bool
    }

    /// The cells read where this row stands, in column order: those that start in it, and
    /// those from rows above with lines of their own in it. A whole row gives a cell all its
    /// words where it starts, like `textEquivalent`, and none where it goes on. A continuation
    /// gives each cell the words of the lines it holds.
    func spokenCells(size: CGSize, viewportHeight: CGFloat, refreshingAttachments: Bool = false) -> [SpokenCell] {
        let layout = layout(width: size.width, viewportHeight: viewportHeight)
        let slice = fragment ?? layout.fragments(ofRow: row, maximumHeight: .greatestFiniteMagnitude)[0]
        let scale = layout.scale * slice.fitScale
        let isTop = slice.top <= layout.rowTops[row] + 0.01
        var shown: [Int: Range<Int>] = [:]
        for entry in slice.cells { shown[entry.cell] = entry.lines }
        var members = Set(shown.keys)
        if isTop { members.formUnion(table.rowCells[row].filter { table.cells[$0].row == row }) }
        return members.sorted { (table.cells[$0].column, $0) < (table.cells[$1].column, $1) }.map { index in
            let box = layout.cellFrames[index], text = layout.cellText[index]
            let starts = isTop && table.cells[index].row == row
            var words = "", lines = 0..<0
            if fragment == nil {
                if starts {
                    words = refreshingAttachments ? TableMeasure.spokenText(table.cells[index].content) : table.cells[index].text
                    lines = 0..<text.lines.count
                }
            } else if let own = shown[index], !own.isEmpty {
                words = text.spokenText(inLines: own, refreshingAttachments: refreshingAttachments)
                lines = own
            }
            let isBlank = table.cells[index].text.isEmpty
                && text.images(in: 0..<text.lines.count).allSatisfy { $0.image.isPassedOverByAssistiveTechnology }
            let images = text.images(in: lines).filter { !$0.image.isPassedOverByAssistiveTechnology }
            let content = layout.contentFrames[index].origin
            return SpokenCell(cell: index, text: words, images: images.map(\.image),
                              imageFrames: images.map {
                                  CGRect(x: (layout.originX + content.x + $0.frame.minX) * scale, y: (content.y + $0.frame.minY - slice.top) * scale,
                                         width: $0.frame.width * scale, height: $0.frame.height * scale)
                              },
                              frame: CGRect(x: (layout.originX + box.minX) * scale, y: (box.minY - slice.top) * scale,
                                            width: box.width * scale, height: box.height * scale),
                              starts: starts, isBlank: isBlank)
        }
    }

    /// Draws the row into the current flipped graphics context, its origin at the row's
    /// top-left, clipped to `size`.
    func draw(in context: CGContext, size: CGSize, viewportHeight: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        let layout = layout(width: size.width, viewportHeight: viewportHeight)
        let slice = fragment ?? layout.fragments(ofRow: row, maximumHeight: .greatestFiniteMagnitude)[0]
        table.draw(row: row, layout: layout, fragment: slice, in: context)
    }

    /// Paints a highlight from `start` to `end`, places in this row's table (nil for its first
    /// cell's start and its last cell's end), on the words this row, or this continuation of
    /// it, draws, where `draw` draws them: none in a cell before the start's or after the
    /// end's, and in a table nested in a cell, its part on that table's own words, at any depth
    /// (`TableCellLayout.drawHighlight`).
    func drawHighlight(from start: ReaderTablePosition?, to end: ReaderTablePosition?, paint: ReaderHighlightPaint,
                       in context: CGContext, size: CGSize, viewportHeight: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        let layout = layout(width: size.width, viewportHeight: viewportHeight)
        let slice = fragment ?? layout.fragments(ofRow: row, maximumHeight: .greatestFiniteMagnitude)[0]
        context.scaleBy(x: layout.scale * slice.fitScale, y: layout.scale * slice.fitScale)
        context.translateBy(x: layout.originX, y: -slice.top)
        for entry in slice.cells {
            if let start, entry.cell < start.cell { continue }
            if let end, entry.cell > end.cell { continue }
            let cell = table.cells[entry.cell]
            let first = start?.cell == entry.cell ? start : nil, last = end?.cell == entry.cell ? end : nil
            let parts = cell.highlightParts(lower: first?.offset ?? 0, upper: last?.offset ?? cell.content.length, start: first, end: last)
            layout.cellText[entry.cell].drawHighlight(run: parts.run, nested: parts.nested, paint: paint,
                                                      inLines: entry.lines, at: layout.contentFrames[entry.cell].origin)
        }
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? {
        render(bounds.size, container: textContainer)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> PlatformImage? {
        render(imageBounds.size, container: textContainer)
    }

    /// Inspectable cell images, transformed exactly as the row/continuation is drawn.
    func images(size: CGSize, viewportHeight: CGFloat) -> [(image: ReaderImageAttachment, frame: CGRect)] {
        let layout = layout(width: size.width, viewportHeight: viewportHeight)
        let slice = fragment ?? layout.fragments(ofRow: row, maximumHeight: .greatestFiniteMagnitude)[0]
        let scale = layout.scale * slice.fitScale
        var result: [(ReaderImageAttachment, CGRect)] = []
        for entry in slice.cells {
            let origin = layout.contentFrames[entry.cell].origin
            for image in layout.cellText[entry.cell].images(in: entry.lines) {
                let frame = CGRect(x: (layout.originX + origin.x + image.frame.minX) * scale,
                    y: (origin.y + image.frame.minY - slice.top) * scale,
                    width: image.frame.width * scale, height: image.frame.height * scale)
                let visible = frame.intersection(CGRect(origin: .zero, size: size))
                if !visible.isNull, !visible.isEmpty { result.append((image.image, visible)) }
            }
        }
        return result
    }

    func image(at point: CGPoint, size: CGSize, viewportHeight: CGFloat) -> ReaderImageAttachment? {
        images(size: size, viewportHeight: viewportHeight).first { $0.frame.contains(point) }?.image
    }

    struct InteractionCell {
        var cell: Int
        var text: NSAttributedString
        var characters: NSRange
        /// Clipped viewport frame in row coordinates; origin identifies the full cell text's
        /// first glyph, before clipping to this complete-line continuation.
        var frame: CGRect
        var textOrigin: CGPoint
        var width: CGFloat
        var scale: CGFloat
        /// The layout that draws the cell, and the lines of it this continuation holds.
        var cellLayout: TableCellLayout
        var lines: Range<Int>
    }

    func interactionCells(size: CGSize, viewportHeight: CGFloat) -> [InteractionCell] {
        let layout = layout(width: size.width, viewportHeight: viewportHeight)
        let slice = fragment ?? layout.fragments(ofRow: row, maximumHeight: .greatestFiniteMagnitude)[0]
        let scale = layout.scale * slice.fitScale
        return slice.cells.compactMap { entry in
            let cell = layout.cellText[entry.cell], content = layout.contentFrames[entry.cell]
            guard let first = entry.lines.first, let last = entry.lines.last else { return nil }
            let top = cell.lines[first].frame.minY, bottom = cell.lines[last].frame.maxY
            let origin = CGPoint(x: (layout.originX + content.minX) * scale,
                y: (content.minY - slice.top) * scale)
            let full = CGRect(x: origin.x, y: origin.y + top * scale, width: content.width * scale,
                height: (bottom - top) * scale)
            let frame = full.intersection(CGRect(origin: .zero, size: size))
            guard !frame.isNull, !frame.isEmpty else { return nil }
            return InteractionCell(cell: entry.cell, text: cell.interactionText,
                characters: NSRange(location: cell.lines[first].characters.location,
                    length: cell.lines[last].characters.upperBound - cell.lines[first].characters.location),
                frame: frame, textOrigin: origin, width: content.width, scale: scale, cellLayout: cell, lines: entry.lines)
        }
    }

    private func render(_ size: CGSize, container: NSTextContainer?) -> PlatformImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let viewport = Self.viewportHeight(container, width: size.width)
        #if os(iOS)
        let scale = currentDrawingScale()
        let key = [size.width, size.height, scale, viewport]
        if let image = lock.withLock({ cached?.key == key ? cached?.image : nil }) { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { [self] context in
            draw(in: context.cgContext, size: size, viewportHeight: viewport)
        }
        lock.withLock { cached = (key, image) }
        return image
        #else
        // The handler runs when the image is drawn, at the destination's resolution.
        return NSImage(size: size, flipped: true) { [self] _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, size: size, viewportHeight: viewport)
            return true
        }
        #endif
    }
}
