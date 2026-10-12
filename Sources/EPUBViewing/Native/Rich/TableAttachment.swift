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
        return (constraints.minimumTableWidth * TableModel.minimumScale, constraints.maximumTableWidth)
    }

    /// The cells that start in this row, joined by tabs. The rows' own line breaks separate rows,
    /// and the caption is a paragraph of its own.
    override var textEquivalent: String {
        if let fragment, let layout = fragmentLayout {
            return fragment.cells.sorted { table.cells[$0.cell].column < table.cells[$1.cell].column }.map { entry in
                let lines = layout.cellText[entry.cell].lines
                let range = NSRange(location: lines[entry.lines.lowerBound].characters.location,
                                    length: lines[entry.lines.upperBound - 1].characters.upperBound - lines[entry.lines.lowerBound].characters.location)
                return layout.cellText[entry.cell].spokenText(in: range)
            }.joined(separator: "\t")
        }
        return table.rowCells[row].map { table.cells[$0] }.filter { $0.row == row }
            .sorted { $0.column < $1.column }.map(\.text).joined(separator: "\t")
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
                frame: frame, textOrigin: origin, width: content.width, scale: scale)
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

/// A table row where only widths are measured (`TableMeasure.maximumWidth`): as wide as the row
/// on any line and of no height, so no table is laid out to size it.
final class TableRowWidthAttachment: ReaderAttachment {
    override func layoutBounds(_ line: Line) -> CGRect {
        CGRect(x: 0, y: line.font?.descender ?? 0, width: TableRowAttachment.width(on: line), height: 0)
    }
}
