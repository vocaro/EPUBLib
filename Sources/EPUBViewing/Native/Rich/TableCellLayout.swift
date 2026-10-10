import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A cell's measured lines and its drawing use the same TextKit layout. Keeping their glyph
/// ranges lets a continuation draw whole lines, even where a rowspan's row boundary crosses
/// a line. Each instance is private to a table layout and serializes access to TextKit.
final class TableCellLayout: @unchecked Sendable {
    struct Line {
        let characters: NSRange
        let glyphs: NSRange
        let frame: CGRect
    }
    let lines: [Line]
    let height: CGFloat
    private let spokenTokens: [(range: NSRange, text: String)]
    private let storage: NSTextStorage
    private let manager: NSLayoutManager
    private let lock = NSLock()

    init(_ text: NSAttributedString, width: CGFloat, viewportHeight: CGFloat) {
        let source = text.string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var tokens: [(NSRange, String)] = [], start = 0
        for offset in 0...source.length {
            let isSpace = offset == source.length || UnicodeScalar(source.character(at: offset)).map { whitespace.contains($0) } == true
            if isSpace {
                if offset > start {
                    let range = NSRange(location: start, length: offset - start)
                    tokens.append((range, TableMeasure.spokenText(text.attributedSubstring(from: range))))
                }
                start = offset + 1
            }
        }
        spokenTokens = tokens
        storage = NSTextStorage(attributedString: text)
        manager = NSLayoutManager()
        let container = ReaderTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.viewportSize = CGSize(width: max(1, width), height: max(1, viewportHeight))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var measured: [Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { [manager] rect, _, _, glyphs, _ in
            measured.append(Line(characters: manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
                                 glyphs: glyphs, frame: rect))
        }
        lines = measured
        height = ceil(manager.usedRect(for: container).maxY)
    }

    /// Only the slice containing a word's first character speaks it. Complete words are
    /// cached once, so narrow character wrapping and huge unbroken words cost linear work.
    func spokenText(in range: NSRange) -> String {
        func firstToken(at offset: Int) -> Int {
            var low = 0, high = spokenTokens.count
            while low < high {
                let middle = (low + high) / 2
                if spokenTokens[middle].range.location < offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        return spokenTokens[firstToken(at: range.location)..<firstToken(at: range.upperBound)]
            .map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func draw(_ indices: Range<Int>, at origin: CGPoint) {
        guard let first = indices.first, let last = indices.last else { return }
        let glyphs = NSRange(location: lines[first].glyphs.location,
                             length: lines[last].glyphs.upperBound - lines[first].glyphs.location)
        lock.withLock {
            manager.drawBackground(forGlyphRange: glyphs, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
    }
}

/// A vertical portion of a row, plus the complete cell lines assigned to it. `height` can be
/// slightly taller than its geometric slice to finish a line crossing a row boundary.
struct TableRowFragment: Equatable {
    struct CellLines: Equatable {
        let cell: Int
        let lines: Range<Int>
    }
    let row: Int
    let top: CGFloat
    let bottom: CGFloat
    let height: CGFloat
    /// Only used when a single complete glyph line cannot fit even at the table minimum scale.
    let fitScale: CGFloat
    let cells: [CellLines]
}
