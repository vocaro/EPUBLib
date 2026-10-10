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
        for range in merged { super.drawGlyphs(forGlyphRange: range, at: origin) }
    }
}
