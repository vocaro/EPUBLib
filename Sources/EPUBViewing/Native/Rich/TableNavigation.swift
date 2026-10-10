import CoreGraphics
import Foundation

extension ReaderPaginator {
    /// Repeated row source offsets identify a table, while the cell's line ownership identifies
    /// the actual continuation containing a precise bookmark or located passage.
    func pageIndex(containing position: ReaderTextPosition) -> Int {
        let first = pageIndex(containing: position.offset)
        guard let endpoint = position.tableCell else { return first }
        var index = first
        while let page = page(at: index) {
            for entry in page.tableFragments where entry.attachment.table.sourceOrder == endpoint.table {
                let row = entry.attachment
                for cell in row.interactionCells(size: CGSize(width: size.width, height: row.height(width: size.width, viewportHeight: size.height)),
                                                viewportHeight: size.height) where cell.cell == endpoint.cell {
                    if NSLocationInRange(endpoint.offset, cell.characters)
                        || (endpoint.offset == cell.text.length && endpoint.offset == cell.characters.upperBound) { return index }
                }
            }
            if page.range.location > position.offset,
               !page.tableFragments.contains(where: { $0.attachment.table.sourceOrder == endpoint.table }) { break }
            index += 1
        }
        return first
    }
}

extension ReaderCanvasView {
    /// Text-container coordinates of a precise cell line in continuous scroll. The underlying
    /// attachment still owns table geometry; no offscreen native cell views need to be mounted.
    func tableAnchorFrame(for anchor: ReaderTextPosition) -> CGRect? {
        guard let endpoint = anchor.tableCell else { return nil }
        for view in textViews {
            guard let storage = view.contentStorage.textStorage else { continue }
            var result: CGRect?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard let row = value as? TableRowAttachment, row.table.sourceOrder == endpoint.table,
                      row.table.cells.indices.contains(endpoint.cell), row.row == row.table.cells[endpoint.cell].row,
                      position(at: range.location, in: view)?.section == anchor.section,
                      let frame = view.segmentFrames(for: range).first else { return }
                let layout = row.layout(width: frame.width, viewportHeight: view.readerContainer.viewportSize.height)
                let cell = layout.cellText[endpoint.cell]
                guard let line = cell.lines.first(where: { NSLocationInRange(endpoint.offset, $0.characters) }) ?? cell.lines.last else { return }
                let content = layout.contentFrames[endpoint.cell]
                result = CGRect(x: frame.minX + (layout.originX + content.minX + line.frame.minX) * layout.scale,
                    y: frame.minY + (content.minY + line.frame.minY - layout.rowTops[row.row]) * layout.scale,
                    width: line.frame.width * layout.scale, height: line.frame.height * layout.scale)
                stop.pointee = true
            }
            if let result { return result }
        }
        return nil
    }
}
