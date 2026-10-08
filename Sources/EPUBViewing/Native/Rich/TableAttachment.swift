import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One row of a table, drawn from `image(for:…)` like the reader's images. It fills the rest of
/// its line; its height is the row's slice of the table's layout at that width (cached per
/// width), at most the viewport's height, so nothing is taller than a page: a row taller still
/// is clipped. Every row is its own line, so paginated flow can break between any two rows;
/// `TableModel.keepsWithNext` asks it to keep rowspan groups and headers together when they fit.
///
/// Rows are drawn, not shown as views: TextKit 2 loads attachment views only on a later viewport
/// layout, which a reader page column never gets, and UIKit inserts them only on a later layout
/// pass. VoiceOver reads a row through its text equivalent. Cell text is not selectable.
final class TableRowAttachment: ReaderAttachment {
    let table: TableModel
    let row: Int

    init(table: TableModel, row: Int) {
        self.table = table; self.row = row
        super.init()
    }
    required init?(coder: NSCoder) { nil }

    static func viewportHeight(_ container: NSTextContainer?, width: CGFloat) -> CGFloat {
        ReaderTextContainer.available(in: container, lineWidth: width).height
    }

    func layout(width: CGFloat, viewportHeight: CGFloat) -> TableLayout {
        table.layout(available: width, viewportHeight: viewportHeight)
    }

    /// The row's height on a line `width` wide: its slice of the table, at most `viewportHeight`.
    func height(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(layout(width: width, viewportHeight: viewportHeight).height(ofRow: row), max(1, viewportHeight))
    }

    override func layoutBounds(_ line: Line) -> CGRect {
        let width = max(1, line.width - line.position)
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
        table.rowCells[row].map { table.cells[$0] }.filter { $0.row == row }
            .sorted { $0.column < $1.column }.map(\.text).joined(separator: "\t")
    }

    /// Draws the row into the current flipped graphics context, its origin at the row's
    /// top-left, clipped to `size`.
    func draw(in context: CGContext, size: CGSize, viewportHeight: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        table.draw(row: row, layout: layout(width: size.width, viewportHeight: viewportHeight), in: context)
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? {
        render(bounds.size, container: textContainer)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> PlatformImage? {
        render(imageBounds.size, container: textContainer)
    }

    private func render(_ size: CGSize, container: NSTextContainer?) -> PlatformImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let viewport = Self.viewportHeight(container, width: size.width)
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = currentDrawingScale()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { [self] context in
            draw(in: context.cgContext, size: size, viewportHeight: viewport)
        }
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
