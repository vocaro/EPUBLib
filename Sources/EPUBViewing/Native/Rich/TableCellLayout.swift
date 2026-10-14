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
        /// A nested row can span several pages while retaining its one source character.
        var nestedRow: TableRowAttachment? = nil
    }
    let lines: [Line]
    let height: CGFloat
    let interactionText: NSAttributedString
    private let spokenTokens: [(range: NSRange, text: String, attachmentText: NSAttributedString?)]
    private let storage: NSTextStorage
    private let manager: NSLayoutManager
    private let lock = NSLock()
    private let viewportHeight: CGFloat

    init(_ text: NSAttributedString, width: CGFloat, viewportHeight: CGFloat) {
        self.viewportHeight = viewportHeight
        let flowed = ReaderFlowBoxLayout.applying(to: text,
            viewport: CGSize(width: max(1, width), height: max(1, viewportHeight)))
        let text = Self.nestedRows(in: flowed, width: width, viewportHeight: viewportHeight)
        interactionText = text
        let source = text.string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var tokens: [(NSRange, String, NSAttributedString?)] = [], start = 0
        for offset in 0...source.length {
            let isSpace = offset == source.length || UnicodeScalar(source.character(at: offset)).map { whitespace.contains($0) } == true
            if isSpace {
                if offset > start {
                    let range = NSRange(location: start, length: offset - start)
                    let token = text.attributedSubstring(from: range)
                    var holdsAttachment = false
                    token.enumerateAttribute(.attachment, in: NSRange(location: 0, length: token.length)) { value, _, stop in
                        if value is ReaderTextualAttachment { holdsAttachment = true; stop.pointee = true }
                    }
                    tokens.append((range, TableMeasure.spokenText(token), holdsAttachment ? token : nil))
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
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            if characters.location < text.length,
               let row = text.attribute(.attachment, at: characters.location, effectiveRange: nil) as? TableRowAttachment {
                let layout = row.layout(width: width, viewportHeight: viewportHeight)
                let font = text.attribute(.font, at: characters.location, effectiveRange: nil) as? PlatformFont
                let limit = max(1, viewportHeight - 2 * (font?.pointSize ?? 16))
                for slice in layout.fragments(ofRow: row.row, maximumHeight: limit) {
                    let frame = CGRect(x: rect.minX, y: rect.minY + (slice.top - layout.rowTops[row.row]) * layout.scale,
                        width: rect.width, height: slice.height * layout.scale)
                    measured.append(Line(characters: characters, glyphs: glyphs, frame: frame,
                        nestedRow: TableRowAttachment(table: row.table, row: row.row, fragment: slice, layout: layout)))
                }
            } else { measured.append(Line(characters: characters, glyphs: glyphs, frame: rect)) }
        }
        lines = measured
        height = ceil(manager.usedRect(for: container).maxY)
    }

    /// Freeze nested layouts at scale one before TextKit asks attachment bounds. Each level
    /// gets one pass per outer attempt, rather than starting its own page-fit retry tree.
    private static func nestedRows(in text: NSAttributedString, width: CGFloat, viewportHeight: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let row = value as? TableRowAttachment else { return }
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let leading = max(0, style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0)
            let trailing = max(0, -(style?.tailIndent ?? 0))
            let available = max(1, width - leading - trailing)
            let layout = row.table.layout(available: available, viewportHeight: viewportHeight, nested: true)
            let whole = layout.fragments(ofRow: row.row, maximumHeight: .greatestFiniteMagnitude)[0]
            result.addAttribute(.attachment, value: TableRowAttachment(table: row.table, row: row.row,
                fragment: whole, layout: layout), range: range)
        }
        return result
    }

    /// Read a nested continuation's own words rather than repeating its entire source row.
    func spokenText(inLines indices: Range<Int>, refreshingAttachments: Bool = false) -> String {
        var words: [String] = []
        for index in indices {
            let line = lines[index]
            if let row = line.nestedRow {
                if refreshingAttachments {
                    words.append(row.spokenCells(size: line.frame.size, viewportHeight: viewportHeight,
                        refreshingAttachments: true).map(\.text).joined(separator: "\t"))
                } else { words.append(row.textEquivalent) }
            }
            else { words.append(spokenText(in: line.characters, refreshingAttachments: refreshingAttachments)) }
        }
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Only the slice containing a word's first character speaks it. Complete words are
    /// cached once, so narrow character wrapping and huge unbroken words cost linear work.
    func spokenText(in range: NSRange, refreshingAttachments: Bool = false) -> String {
        func firstToken(at offset: Int) -> Int {
            var low = 0, high = spokenTokens.count
            while low < high {
                let middle = (low + high) / 2
                if spokenTokens[middle].range.location < offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        return spokenTokens[firstToken(at: range.location)..<firstToken(at: range.upperBound)]
            .map { token in
                if refreshingAttachments, let text = token.attachmentText { return TableMeasure.spokenText(text) }
                return token.text
            }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Image hit regions use the same glyph layout and complete-line ownership as drawing.
    func images(in indices: Range<Int>) -> [(image: ReaderImageAttachment, frame: CGRect)] {
        guard let first = indices.first, let last = indices.last,
              let container = manager.textContainers.first else { return [] }
        let characters = NSRange(location: lines[first].characters.location,
            length: lines[last].characters.upperBound - lines[first].characters.location)
        return lock.withLock {
            var result: [(ReaderImageAttachment, CGRect)] = []
            storage.enumerateAttribute(.attachment, in: characters) { value, range, _ in
                guard let image = value as? ReaderImageAttachment else { return }
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                result.append((image, manager.boundingRect(forGlyphRange: glyphs, in: container)))
            }
            return result
        }
    }

    func draw(_ indices: Range<Int>, at origin: CGPoint) {
        guard !indices.isEmpty else { return }
        lock.withLock {
            for index in indices {
                let line = lines[index]
                if let row = line.nestedRow {
                    #if os(iOS)
                    let context = UIGraphicsGetCurrentContext()
                    #else
                    let context = NSGraphicsContext.current?.cgContext
                    #endif
                    guard let context else { continue }
                    context.saveGState()
                    context.translateBy(x: origin.x + line.frame.minX, y: origin.y + line.frame.minY)
                    row.draw(in: context, size: line.frame.size, viewportHeight: viewportHeight)
                    context.restoreGState()
                } else {
                    manager.drawBackground(forGlyphRange: line.glyphs, at: origin)
                    manager.drawGlyphs(forGlyphRange: line.glyphs, at: origin)
                }
            }
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
