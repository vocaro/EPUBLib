import CoreGraphics
import EPUBCore
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// A host highlight's mark is drawn by the reader, in one pattern for each mark wherever the
// text is: the reader's TextKit 2 text views (`ReaderLayoutFragment`), a table cell's text
// view (`TableInteractionLayoutManager`) and a table nested in a cell (`TableCellLayout`).
// TextKit 2 draws no underline that a rendering attribute gives (macOS 27.0), and TextKit 1's
// thick, double, dotted and dashed underlines are not the same lines as one stroked here.

extension NSAttributedString.Key {
    /// A host highlight's mark over these characters: the `EPUBHighlightMark` raw value, as a
    /// rendering attribute of the reader's text views and an attribute of a cell's own text
    /// view's storage, which only the cell's highlights write.
    static let readerHighlightMark = Self("org.epublib.highlightMark")
    /// The mark's color, a `PlatformColor`.
    static let readerHighlightMarkColor = Self("org.epublib.highlightMarkColor")
}

extension EPUBHighlightMark {
    /// The width of a mark's line: a tenth of the text's size, and at least a point and a half,
    /// heavier than a font's own underline so that it is seen.
    private static func weight(fontSize: CGFloat) -> CGFloat { max(1.5, fontSize / 10) }
    private static func gap(fontSize: CGFloat) -> CGFloat { max(1, fontSize / 10) }

    /// Strokes the mark from `minX` to `maxX` under a baseline at `baseline`, for text of
    /// `fontSize` points: a solid line, two thinner lines, round dots or dashes, beginning a
    /// tenth of the text's size below the baseline. Each line's edges fall on the device's
    /// pixels, so it is drawn sharp and in its own color, at least a pixel high. Coordinates
    /// run down the page.
    func draw(color: CGColor, from minX: CGFloat, to maxX: CGFloat, baseline: CGFloat, fontSize: CGFloat, in context: CGContext) {
        guard maxX > minX else { return }
        let weight = Self.weight(fontSize: fontSize), top = baseline + Self.gap(fontSize: fontSize)
        let device = context.userSpaceToDeviceSpaceTransform
        let pixel = 1 / max(abs(device.d), 0.001)
        func snapped(_ y: CGFloat) -> CGFloat {
            let place = CGPoint(x: minX, y: y).applying(device)
            return CGPoint(x: place.x, y: place.y.rounded()).applying(device.inverted()).y
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color)
        /// A line whose top is at `y`, `height` high.
        func line(at y: CGFloat, height: CGFloat) {
            let upper = snapped(y)
            var lower = snapped(y + height)
            if abs(lower - upper) < pixel { lower = upper + pixel }
            context.setLineWidth(abs(lower - upper))
            context.move(to: CGPoint(x: minX, y: (upper + lower) / 2))
            context.addLine(to: CGPoint(x: maxX, y: (upper + lower) / 2))
            context.strokePath()
        }
        switch self {
        case .underline: line(at: top, height: weight)
        case .doubleUnderline:
            let thin = weight * 0.6
            line(at: top, height: thin)
            line(at: top + weight * 2 - thin, height: thin)
        case .dottedUnderline:
            let dot = weight * 1.3
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [0, dot * 2])
            line(at: top, height: dot)
        case .dashedUnderline:
            context.setLineDash(phase: 0, lengths: [weight * 3, weight * 2])
            line(at: top, height: weight)
        }
    }
}

extension NSLayoutManager {
    /// Strokes `mark` under the words of `characters` that are among `glyphs`, one line
    /// fragment at a time, at each fragment's baseline, for a TextKit 1 layout drawn at
    /// `origin`. An attachment is not underlined, nor the break that ends a line.
    func drawHighlightMark(_ mark: EPUBHighlightMark, color: CGColor, under characters: NSRange, among glyphs: NSRange,
                           at origin: CGPoint, in context: CGContext) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let text = storage.string as NSString
        var words: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSIntersectionRange(characters, NSRange(location: 0, length: storage.length))) { value, run, _ in
            if value == nil { words.append(run) }
        }
        for var word in words {
            while word.length > 0, let scalar = UnicodeScalar(text.character(at: NSMaxRange(word) - 1)),
                  CharacterSet.newlines.contains(scalar) { word.length -= 1 }
            let wordGlyphs = NSIntersectionRange(glyphRange(forCharacterRange: word, actualCharacterRange: nil), glyphs)
            guard wordGlyphs.length > 0 else { continue }
            enumerateLineFragments(forGlyphRange: wordGlyphs) { fragment, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, wordGlyphs)
                guard part.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                let character = self.characterIndexForGlyph(at: part.location)
                let size = (storage.attribute(.font, at: character, effectiveRange: nil) as? PlatformFont)?.pointSize ?? 17
                mark.draw(color: color, from: origin.x + bounds.minX, to: origin.x + bounds.maxX,
                          baseline: origin.y + baseline, fontSize: size, in: context)
            }
        }
    }

    /// Strokes the marks the storage's `readerHighlightMark` attributes give over `characters`,
    /// among `glyphs`, at `origin`: a cell's own text view, after its highlighted glyphs.
    func drawHighlightMarks(in characters: NSRange, among glyphs: NSRange, at origin: CGPoint) {
        #if os(iOS)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #else
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #endif
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.readerHighlightMark, in: NSIntersectionRange(characters, NSRange(location: 0, length: storage.length))) { value, run, _ in
            guard let raw = value as? String, let mark = EPUBHighlightMark(rawValue: raw),
                  let color = storage.attribute(.readerHighlightMarkColor, at: run.location, effectiveRange: nil) as? PlatformColor else { return }
            drawHighlightMark(mark, color: color.cgColor, under: run, among: glyphs, at: origin, in: context)
        }
    }
}

/// The fragment every paragraph of a reader text view is laid out in: TextKit's own, which
/// after its text draws the marks of the host highlights over that text, from the rendering
/// attributes `ReaderTextView.setHighlights` gives (`readerHighlightMark`). It changes no
/// layout. Each line's part of a mark is stroked under that line's baseline, from the first
/// marked character to the last, at the text's size there.
class ReaderLayoutFragment: NSTextLayoutFragment {
    /// TextKit draws a fragment within these bounds: a mark under the last line's descent
    /// is to be drawn as well.
    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height + 4)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        drawHighlightMarks(at: point, in: context)
    }

    private func drawHighlightMarks(at point: CGPoint, in context: CGContext) {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let elementStart = textElement?.elementRange?.location else { return }
        let origin = content.documentRange.location
        func offset(_ location: any NSTextLocation) -> Int { content.offset(from: origin, to: location) }
        let first = offset(rangeInElement.location), end = offset(rangeInElement.endLocation)
        var marks: [(range: NSRange, mark: EPUBHighlightMark, color: PlatformColor)] = []
        manager.enumerateRenderingAttributes(from: rangeInElement.location, reverse: false) { _, attributes, range in
            let lower = max(first, offset(range.location)), upper = min(end, offset(range.endLocation))
            guard lower < end else { return false }
            if upper > lower, let raw = attributes[.readerHighlightMark] as? String, let mark = EPUBHighlightMark(rawValue: raw),
               let color = attributes[.readerHighlightMarkColor] as? PlatformColor {
                marks.append((NSRange(location: lower, length: upper - lower), mark, color))
            }
            return true
        }
        guard !marks.isEmpty else { return }
        let base = offset(elementStart)
        for line in textLineFragments where line.characterRange.length > 0 {
            let text = line.attributedString.string as NSString
            let lineStart = base + line.characterRange.location, lineEnd = lineStart + line.characterRange.length
            let bounds = line.typographicBounds
            for entry in marks {
                let lower = max(entry.range.location, lineStart)
                var upper = min(NSMaxRange(entry.range), lineEnd)
                while upper > lower, let scalar = UnicodeScalar(text.character(at: upper - 1 - base)),
                      CharacterSet.newlines.contains(scalar) { upper -= 1 }
                guard upper > lower else { continue }
                let start = line.locationForCharacter(at: lower - base).x, finish = line.locationForCharacter(at: upper - base).x
                let size = (line.attributedString.attribute(.font, at: lower - base, effectiveRange: nil) as? PlatformFont)?.pointSize ?? 17
                entry.mark.draw(color: entry.color.cgColor, from: point.x + bounds.minX + min(start, finish),
                                to: point.x + bounds.minX + max(start, finish),
                                baseline: point.y + bounds.minY + line.glyphOrigin.y, fontSize: size, in: context)
            }
        }
    }
}
