import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Foreground alpha does not suppress color emoji or attachment drawing in TextKit. The row
/// already painted those pixels, so native interaction paints only selected/highlighted ink.
final class TableInteractionLayoutManager: NSLayoutManager {
    var drawnCharacterRanges: [NSRange] = []
    /// Highlights of words in tables nested in the cell. This text holds a nested row as one
    /// attachment, whose glyph is all of the row, so the cell's layout paints them over the
    /// lines of it that are shown (`TableCellLayout.drawHighlight`).
    var nestedHighlights: [(highlight: TableNestedHighlight, paint: ReaderHighlightPaint)] = []
    var cellLayout: (cell: TableCellLayout, lines: Range<Int>)?

    override func drawGlyphs(forGlyphRange glyphRange: NSRange, at origin: CGPoint) {
        guard textStorage != nil else { return }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var visible: [NSRange] = []
        for drawnRange in drawnCharacterRanges {
            let range = NSIntersectionRange(drawnRange, characters)
            guard range.length > 0 else { continue }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let requested = NSIntersectionRange(glyphs, glyphRange)
            if requested.length > 0 { visible.append(requested) }
        }
        // Selection and highlight can overlap. Paint each glyph once, including attachments
        // whose authored alpha must not become darker from repeated overlay drawing.
        var merged: [NSRange] = []
        for range in visible.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= last.upperBound {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        for range in merged {
            super.drawGlyphs(forGlyphRange: range, at: origin)
            // Host highlights' marks, under the glyphs just drawn.
            drawHighlightMarks(in: characterRange(forGlyphRange: range, actualGlyphRange: nil), among: range, at: origin)
        }
        guard let cellLayout else { return }
        for entry in nestedHighlights where NSIntersectionRange(entry.highlight.rows, characters).length > 0 {
            cellLayout.cell.drawHighlight(run: NSRange(location: 0, length: 0), nested: [entry.highlight],
                                          paint: entry.paint, inLines: cellLayout.lines, at: origin)
        }
    }
}
