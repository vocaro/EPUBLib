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
    /// Each word of the cell: its characters, what VoiceOver reads of it, and the word itself
    /// where a selection reads more of it, an attachment's words or text the book keeps from
    /// assistive technology.
    private let spokenTokens: [Token]
    private typealias Token = (range: NSRange, text: String, source: NSAttributedString?)
    private let storage: NSTextStorage
    private let manager: NSLayoutManager
    private let lock = NSLock()
    private let viewportHeight: CGFloat

    init(_ text: NSAttributedString, width: CGFloat, viewportHeight: CGFloat) {
        self.viewportHeight = viewportHeight
        let flowed = ReaderFlowBoxLayout.applying(to: text,
            viewport: CGSize(width: max(1, width), height: max(1, viewportHeight)))
        let text = Self.nestedRows(in: ReaderTextContainer.clampingExhaustedIndents(in: flowed, width: max(1, width)),
            width: width, viewportHeight: viewportHeight)
        interactionText = text
        let source = text.string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var tokens: [Token] = [], start = 0
        for offset in 0...source.length {
            let isSpace = offset == source.length || UnicodeScalar(source.character(at: offset)).map { whitespace.contains($0) } == true
            if isSpace {
                if offset > start {
                    let range = NSRange(location: start, length: offset - start)
                    let token = text.attributedSubstring(from: range)
                    var readsMore = false
                    token.enumerateAttributes(in: NSRange(location: 0, length: token.length)) { attributes, _, stop in
                        if attributes[.attachment] is ReaderTextualAttachment || attributes[.readerUnspoken] != nil {
                            readsMore = true; stop.pointee = true
                        }
                    }
                    tokens.append((range, TableMeasure.spokenText(token), readsMore ? token : nil))
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
        var measured: [Line] = [], bottom: CGFloat = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { [manager] rect, used, _, glyphs, _ in
            // A line TextKit sets no glyph on within the column has no used rect. It is still a
            // line of the cell, and a row cut at the cell's height left it on no page (#569).
            bottom = max(bottom, used.height > 0 ? used.maxY : rect.maxY)
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
        height = ceil(max(manager.usedRect(for: container).maxY, bottom))
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
                } else { words.append(row.spokenEquivalent) }
            }
            else { words.append(spokenText(in: line.characters, refreshingAttachments: refreshingAttachments)) }
        }
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `spokenText(inLines:)` as a selection reads it: with the words of attachments and the
    /// text that the book keeps from assistive technology (#551).
    func shownText(inLines indices: Range<Int>) -> String {
        var words: [String] = []
        for index in indices {
            let line = lines[index]
            if let row = line.nestedRow { words.append(row.textEquivalent); continue }
            words.append(tokens(in: line.characters).map { token in token.source.map { TableMeasure.text($0, spoken: false) } ?? token.text }
                .filter { !$0.isEmpty }.joined(separator: " "))
        }
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Only the slice containing a word's first character speaks it. Complete words are
    /// cached once, so narrow character wrapping and huge unbroken words cost linear work.
    func spokenText(in range: NSRange, refreshingAttachments: Bool = false) -> String {
        tokens(in: range).map { token in
            if refreshingAttachments, let text = token.source { return TableMeasure.spokenText(text) }
            return token.text
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The words whose first characters are in `range`.
    private func tokens(in range: NSRange) -> ArraySlice<Token> {
        func firstToken(at offset: Int) -> Int {
            var low = 0, high = spokenTokens.count
            while low < high {
                let middle = (low + high) / 2
                if spokenTokens[middle].range.location < offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        return spokenTokens[firstToken(at: range.location)..<firstToken(at: range.upperBound)]
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

    /// Paints a highlight on the lines `indices` where `draw` draws them: on `run`, characters
    /// of the cell's own text, a fill and then their glyphs again; on a nested row's
    /// continuation, all of the row where it is in `run`, and otherwise the part in `nested`
    /// whose rows hold it (`TableRowAttachment.drawHighlight`). The fill takes the place of
    /// what was painted beneath it, so a word shows the last highlight painted on it, as text
    /// shows its last highlight attribute. Only the lines holding the highlight's characters are
    /// visited, found by binary search, so a cell's many highlights cost what they cover.
    func drawHighlight(run: NSRange, nested: [TableNestedHighlight], color: CGColor, inLines indices: Range<Int>, at origin: CGPoint) {
        #if os(iOS)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #else
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #endif
        let held = ([run] + nested.map(\.rows)).filter { $0.length > 0 }
        guard let lower = held.map(\.location).min(), let upper = held.map(\.upperBound).max() else { return }
        lock.withLock {
            for index in lineIndices(holding: NSRange(location: lower, length: upper - lower), among: indices) {
                let line = lines[index]
                if let row = line.nestedRow {
                    let part: TableNestedHighlight? = NSLocationInRange(line.characters.location, run)
                        ? TableNestedHighlight(rows: run, start: nil, end: nil)
                        : nested.first { NSLocationInRange(line.characters.location, $0.rows) }
                    guard let part else { continue }
                    context.saveGState()
                    context.translateBy(x: origin.x + line.frame.minX, y: origin.y + line.frame.minY)
                    row.drawHighlight(from: part.start, to: part.end, color: color, in: context,
                                      size: line.frame.size, viewportHeight: viewportHeight)
                    context.restoreGState()
                    continue
                }
                let characters = NSIntersectionRange(run, line.characters)
                guard characters.length > 0, let container = manager.textContainers.first else { continue }
                let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                context.saveGState()
                context.setBlendMode(.copy)
                context.setFillColor(color)
                manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                in: container) { rect, _ in
                    context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
                }
                context.restoreGState()
                manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            }
        }
    }

    /// The lines among `indices` that hold any of `characters`. The lines are in the order of
    /// their characters, and a nested row's continuations share its one character.
    private func lineIndices(holding characters: NSRange, among indices: Range<Int>) -> Range<Int> {
        func first(where test: (Line) -> Bool) -> Int {
            var low = indices.lowerBound, high = indices.upperBound
            while low < high {
                let middle = (low + high) / 2
                if test(lines[middle]) { high = middle } else { low = middle + 1 }
            }
            return low
        }
        let lower = first { $0.characters.upperBound > characters.location }
        return lower..<max(lower, first { $0.characters.location >= characters.upperBound })
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
