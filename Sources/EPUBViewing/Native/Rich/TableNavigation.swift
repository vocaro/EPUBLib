import CoreGraphics
import Foundation

extension ReaderPaginator {
    /// Repeated row source offsets identify a table, while the cell's line ownership identifies
    /// the actual continuation containing a precise bookmark or located passage. A place in a
    /// nested table is on the continuation holding the nested row's continuation that draws it.
    func pageIndex(containing position: ReaderTextPosition) -> Int {
        let first = pageIndex(containing: position.offset)
        guard let endpoint = position.tableCell else { return first }
        var index = first
        while let page = page(at: index) {
            if page.tableFragments.contains(where: { $0.attachment.draws(endpoint, width: size.width, viewportHeight: size.height) }) {
                return index
            }
            if page.range.location > position.offset,
               !page.tableFragments.contains(where: { $0.attachment.table.sourceOrder == endpoint.table }) { break }
            index += 1
        }
        return first
    }
}

extension TableRowAttachment {
    /// Whether this row, or this continuation of it, draws the place `endpoint` names: the lines
    /// it holds of the place's cell take in its character, or the end of the cell's text. For a
    /// place in a nested table, one of those lines is the continuation of the nested row that
    /// draws it, at any depth (`lineFrame`).
    func draws(_ endpoint: ReaderTablePosition, width: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard table.sourceOrder == endpoint.table else { return false }
        if endpoint.nested != nil { return lineFrame(of: endpoint, width: width, viewportHeight: viewportHeight) != nil }
        let size = CGSize(width: width, height: height(width: width, viewportHeight: viewportHeight))
        return interactionCells(size: size, viewportHeight: viewportHeight).contains { cell in
            cell.cell == endpoint.cell && (NSLocationInRange(endpoint.offset, cell.characters)
                || (endpoint.offset == cell.text.length && endpoint.offset == cell.characters.upperBound))
        }
    }

    /// Where this row, or this continuation of it, draws the line holding the place `endpoint`
    /// names, in the row's coordinates as `draw` draws it: a line of the cell's own text, or for
    /// a place in a nested table, that table's line, at any depth. nil where it draws neither.
    func lineFrame(of endpoint: ReaderTablePosition, width: CGFloat, viewportHeight: CGFloat) -> CGRect? {
        guard table.sourceOrder == endpoint.table, table.cells.indices.contains(endpoint.cell) else { return nil }
        let layout = layout(width: width, viewportHeight: viewportHeight)
        let slice = fragment ?? layout.fragments(ofRow: row, maximumHeight: .greatestFiniteMagnitude)[0]
        guard let lines = slice.cells.first(where: { $0.cell == endpoint.cell })?.lines else { return nil }
        let text = layout.cellText[endpoint.cell]
        let place: CGRect
        if let nested = endpoint.nested {
            guard let found = text.line(drawing: nested, among: lines, viewportHeight: viewportHeight) else { return nil }
            place = found.place.offsetBy(dx: found.line.frame.minX, dy: found.line.frame.minY)
        } else {
            guard let line = lines.lazy.map({ text.lines[$0] }).first(where: { line in
                NSLocationInRange(endpoint.offset, line.characters)
                    || (endpoint.offset == text.interactionText.length && endpoint.offset == line.characters.upperBound)
            }) else { return nil }
            place = line.frame
        }
        let content = layout.contentFrames[endpoint.cell], scale = layout.scale * slice.fitScale
        return CGRect(x: (layout.originX + content.minX + place.minX) * scale, y: (content.minY + place.minY - slice.top) * scale,
                      width: place.width * scale, height: place.height * scale)
    }
}

extension TableCellLayout {
    /// The line among `indices` that draws the place `nested` names in a table nested in the
    /// cell, a continuation of that table's row, and where that row draws the place's own line
    /// (`TableRowAttachment.lineFrame`), in the line's coordinates.
    func line(drawing nested: ReaderTablePosition, among indices: Range<Int>, viewportHeight: CGFloat) -> (line: Line, place: CGRect)? {
        for index in indices {
            let line = lines[index]
            guard let row = line.nestedRow,
                  let place = row.lineFrame(of: nested, width: line.frame.width, viewportHeight: viewportHeight) else { continue }
            return (line, place)
        }
        return nil
    }
}

extension ReaderCanvasView {
    /// Text-container coordinates of a precise cell line in continuous scroll, or of a nested
    /// table's line for a place in one. The underlying attachment still owns table geometry; no
    /// offscreen native cell views need to be mounted.
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
                let viewportHeight = view.readerContainer.viewportSize.height
                let layout = row.layout(width: frame.width, viewportHeight: viewportHeight)
                let cell = layout.cellText[endpoint.cell]
                guard var line = cell.lines.first(where: { NSLocationInRange(endpoint.offset, $0.characters) }) ?? cell.lines.last else { return }
                var place = CGRect(origin: .zero, size: line.frame.size)
                if let nested = endpoint.nested,
                   let found = cell.line(drawing: nested, among: cell.lines.indices, viewportHeight: viewportHeight) {
                    line = found.line
                    place = found.place
                }
                let content = layout.contentFrames[endpoint.cell]
                result = CGRect(x: frame.minX + (layout.originX + content.minX + line.frame.minX + place.minX) * layout.scale,
                    y: frame.minY + (content.minY + line.frame.minY + place.minY - layout.rowTops[row.row]) * layout.scale,
                    width: place.width * layout.scale, height: place.height * layout.scale)
                stop.pointee = true
            }
            if let result { return result }
        }
        return nil
    }
}
