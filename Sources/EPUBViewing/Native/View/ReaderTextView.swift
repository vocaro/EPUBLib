import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Where a reader text view's characters are in the book.
struct ReaderTextPlacement: Equatable {
    /// The section shown; nil when the view shows the whole book (`ReaderBookText`).
    var section: Int?
    /// The section offset of the view's first character: a page's start, or 0.
    var offset = 0
    /// How many of the view's characters the reader sees. Any after them are clipped layout
    /// context (`ReaderPage.layoutEnd`) and are never selected or reported.
    var visibleLength = 0
}

/// A source line's actual ink geometry, independent of its paragraph's flow height.
/// Floated, positioned and atomic inline text can share Y coordinates with later source lines.
struct ReaderVisualLine {
    var frame: CGRect
    var range: NSRange

    static func sourceRange(intersecting rect: CGRect, in lines: [Self]) -> NSRange? {
        guard !rect.isEmpty else { return nil }
        var lower: Int?, upper = 0
        for line in lines where line.range.length > 0 && !line.frame.intersection(rect).isEmpty {
            lower = min(lower ?? line.range.location, line.range.location)
            upper = max(upper, NSMaxRange(line.range))
        }
        return lower.map { NSRange(location: $0, length: upper - $0) }
    }

    /// Source extrema of the visual row nearest Y, rather than a hit at the column's left edge.
    static func boundary(at y: CGFloat, lineEnd: Bool, in lines: [Self], length: Int) -> Int {
        let candidates = lines.filter {
            $0.range.length > 0 && (lineEnd ? $0.frame.midY <= y : $0.frame.midY >= y)
        }
        let nearest: Self?
        if lineEnd { nearest = candidates.max { $0.frame.midY < $1.frame.midY } }
        else { nearest = candidates.min { $0.frame.midY < $1.frame.midY } }
        guard let nearest else { return lineEnd ? 0 : length }
        let row = candidates.filter { $0.frame.minY <= nearest.frame.midY && nearest.frame.midY < $0.frame.maxY }
        if lineEnd { return row.map { NSMaxRange($0.range) }.max() ?? NSMaxRange(nearest.range) }
        return row.map { $0.range.location }.min() ?? nearest.range.location
    }
}

// Platform-neutral TextKit 2 work on either platform's `ReaderTextView`. Nothing here touches
// `layoutManager`, which would drop the view to TextKit 1.
extension ReaderTextView {
    static func makeTextKitStack() -> (NSTextContentStorage, NSTextLayoutManager, ReaderTextContainer) {
        let storage = NSTextContentStorage()
        let layoutManager = ReaderBoxLayoutManager()
        storage.addTextLayoutManager(layoutManager)
        let container = ReaderTextContainer(size: CGSize(width: 0, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        return (storage, layoutManager, container)
    }

    var textLength: Int { contentStorage.textStorage?.length ?? 0 }

    func setContent(_ text: NSAttributedString) {
        containsTableRows = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value is TableRowAttachment { containsTableRows = true; stop.pointee = true }
        }
        flowSourceText = text
        // After a resize TextKit 2 keeps layout fragments of text it has not laid out again, and
        // replacing the characters leaves them behind with the attachments they measured. Drop
        // the outgoing layout first, so a rebuilt book's old images are released with its text.
        readerLayoutManager.invalidateLayout(for: readerLayoutManager.documentRange)
        contentStorage.textStorage?.setAttributedString(text)
        refreshFlowBoxLayout()
        exposeTextualAttachments()
    }

    /// Recomputes native box geometry without replacing characters or disturbing selection.
    func refreshFlowBoxLayout() {
        guard let storage = contentStorage.textStorage, let source = flowSourceText else { return }
        let text: NSAttributedString
        if source.length > 0, source.attribute(.readerBoxPage, at: 0, effectiveRange: nil) != nil {
            text = source
        } else { text = ReaderBoxLayout.resolve(source, viewport: readerContainer.viewportSize).text }
        readerContainer.configureBoxes(in: text)
        (readerLayoutManager as? ReaderBoxLayoutManager)?.configureGeometry()
        // Ordinary sections already hold the source attributes. Avoid resetting every run
        // (and invalidating a whole book's native layout) when no box geometry changed them.
        if text === source, readerContainer.boxPage == nil { return }
        if storage.string == text.string {
            storage.beginEditing()
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
        } else { storage.setAttributedString(text) }
    }

    /// Each attachment that stands for text (`ReaderTextualAttachment`), with its range.
    func textualAttachments(in range: NSRange? = nil) -> [(attachment: NSTextAttachment, text: String, range: NSRange)] {
        guard let storage = contentStorage.textStorage else { return [] }
        let full = NSRange(location: 0, length: storage.length)
        var result: [(NSTextAttachment, String, NSRange)] = []
        storage.enumerateAttribute(.attachment, in: range.map { NSIntersectionRange($0, full) } ?? full) { value, run, _ in
            guard let attachment = value as? NSTextAttachment,
                  let text = (attachment as? ReaderTextualAttachment)?.textEquivalent, !text.isEmpty else { return }
            result.append((attachment, text, run))
        }
        return result
    }

    /// Lays out every line, so a page column has exact positions (no estimates).
    func ensureFullLayout() {
        readerLayoutManager.ensureLayout(for: readerLayoutManager.documentRange)
        refreshTableInteractions()
    }

    func textRange(for range: NSRange) -> NSTextRange? {
        let start = contentStorage.documentRange.location
        guard let lower = contentStorage.location(start, offsetBy: range.location),
              let upper = contentStorage.location(lower, offsetBy: range.length) else { return nil }
        return NSTextRange(location: lower, end: upper)
    }

    func offset(of location: any NSTextLocation) -> Int {
        contentStorage.offset(from: contentStorage.documentRange.location, to: location)
    }

    /// The reader's text of `range` (clamped): attachments read as their text equivalents
    /// (`ReaderTextualAttachment`), never U+FFFC. Selections, Copy and VoiceOver use it.
    func plainText(in range: NSRange) -> String {
        guard let storage = contentStorage.textStorage else { return "" }
        return storage.readerPlainText(in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length)))
    }

    /// The characters the reader sees: a page column's own page, without its clipped context.
    var shownCharacters: NSRange { NSRange(location: 0, length: min(placement.visibleLength, textLength)) }

    /// The text the reader sees, attachments read as their text equivalents.
    var visibleText: String { plainText(in: shownCharacters) }

    /// The measured lines belonging to this page. Paragraph continuation context remains in
    /// TextKit storage, but every exposed character range ends at the page boundary.
    var pageAccessibilityLines: [ReaderVisualLine] {
        var result: [ReaderVisualLine] = []
        var cursor = 0
        while cursor < shownCharacters.length {
            guard let line = line(containing: cursor) else { break }
            let upper = min(shownCharacters.length, NSMaxRange(line.range))
            guard upper > cursor else { break }
            result.append(ReaderVisualLine(frame: line.frame,
                range: NSRange(location: cursor, length: upper - cursor)))
            cursor = upper
        }
        return result
    }

    /// Replaces the drawn highlights. Rendering attributes only: the text is never changed.
    func setHighlights(_ highlights: [(range: NSRange, color: PlatformColor)]) {
        let layoutManager = readerLayoutManager
        layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
        for highlight in highlights {
            guard let range = textRange(for: highlight.range) else { continue }
            layoutManager.addRenderingAttribute(.backgroundColor, value: highlight.color, for: range)
        }
    }

    /// Native TextKit insertion offset nearest a point, without invoking TextKit 1.
    func characterOffset(at point: CGPoint) -> Int {
        let local = CGPoint(x: point.x - containerOrigin.x, y: point.y - containerOrigin.y)
        guard let fragment = readerLayoutManager.textLayoutFragment(for: local) else {
            return local.y <= 0 ? 0 : textLength
        }
        let start = offset(of: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let relative = CGPoint(x: local.x - frame.minX, y: local.y - frame.minY)
        guard let line = fragment.textLineFragments.min(by: {
            abs($0.typographicBounds.midY - relative.y) < abs($1.typographicBounds.midY - relative.y)
        }) else { return start }
        let bounds = line.typographicBounds
        return min(textLength, max(0, start + line.characterIndex(for:
            CGPoint(x: relative.x - bounds.minX, y: relative.y - bounds.minY))))
    }

    /// The link under `point` (this view's coordinates), if any.
    func link(at point: CGPoint) -> URL? {
        let origin = containerOrigin
        let location = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = readerLayoutManager.textLayoutFragment(for: location),
              let storage = contentStorage.textStorage else { return nil }
        let frame = fragment.layoutFragmentFrame
        let local = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(local) }) else { return nil }
        let bounds = line.typographicBounds
        let index = offset(of: fragment.rangeInElement.location)
            + line.characterIndex(for: CGPoint(x: local.x - bounds.minX, y: local.y - bounds.minY))
        guard index >= 0, index < storage.length else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        return value as? URL ?? (value as? String).flatMap { URL(string: $0) }
    }

    /// The frames of `range`'s laid-out text segments, in text container coordinates.
    func segmentFrames(for range: NSRange) -> [CGRect] {
        guard let textRange = textRange(for: range) else { return [] }
        var frames: [CGRect] = []
        readerLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            frames.append(frame)
            return true
        }
        return frames
    }

    /// The frame of the line holding `offset` (the last line for the end), in text container
    /// coordinates, laying it out if needed.
    func lineFrame(containing offset: Int) -> CGRect? {
        line(containing: offset)?.frame
    }

    /// The frame (text container coordinates) and characters of the line holding `offset` (the
    /// last line for the end), laying it out if needed.
    func line(containing offset: Int) -> (frame: CGRect, range: NSRange)? {
        let length = textLength
        guard length > 0 else { return nil }
        let target = max(0, min(offset, length - 1))
        guard let range = textRange(for: NSRange(location: target, length: 1)) else { return nil }
        readerLayoutManager.ensureLayout(for: range)
        guard let fragment = readerLayoutManager.textLayoutFragment(for: range.location) else { return nil }
        let start = self.offset(of: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        guard let line = lines.first(where: { NSLocationInRange(target - start, $0.characterRange) }) ?? lines.last else {
            let end = self.offset(of: fragment.rangeInElement.endLocation)
            return (frame, NSRange(location: start, length: end - start))
        }
        let bounds = line.typographicBounds
        let lineFrame = readerContainer.hasNonlinearGeometry
            ? bounds.offsetBy(dx: frame.minX, dy: frame.minY)
            : CGRect(x: frame.minX, y: frame.minY + bounds.minY, width: frame.width, height: bounds.height)
        return (lineFrame, NSRange(location: start + line.characterRange.location, length: line.characterRange.length))
    }

    /// Lays out the characters from `lower` through `upper` (clamped) in one run, so their lines
    /// are placed exactly relative to each other.
    func ensureLayout(from lower: Int, through upper: Int) {
        let length = textLength
        guard length > 0 else { return }
        let start = max(0, min(lower, length - 1)), end = max(start, min(upper, length - 1))
        guard let range = textRange(for: NSRange(location: start, length: end - start + 1)) else { return }
        readerLayoutManager.ensureLayout(for: range)
    }

    /// Whether the fragment laid out at container `y` holds `offset` (the last character for the
    /// end); TextKit 2 can lay one fragment out over another.
    func fragment(atContainerY y: CGFloat, holds offset: Int) -> Bool {
        if readerContainer.hasNonlinearGeometry {
            // A float at x=0 can legitimately share this Y with the target body fragment.
            guard let line = line(containing: offset) else { return false }
            return line.frame.minY <= y && y < line.frame.maxY
        }
        guard let fragment = readerLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return false }
        let target = max(0, min(offset, textLength - 1))
        let range = fragment.rangeInElement
        return self.offset(of: range.location) <= target && target < self.offset(of: range.endLocation)
    }

    /// All already-laid-out visual lines, without forcing offscreen book content to lay out.
    /// Enumerating source order is intentional: floating lines can visually overlap later text.
    private func visualLines() -> [ReaderVisualLine] {
        var lines: [ReaderVisualLine] = []
        readerLayoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location, options: []) { fragment in
            guard fragment.state == .layoutAvailable else { return true }
            let start = offset(of: fragment.rangeInElement.location)
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                lines.append(ReaderVisualLine(frame: line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY),
                    range: NSRange(location: start + line.characterRange.location, length: line.characterRange.length)))
            }
            return true
        }
        return lines
    }

    /// The source envelope of all lines actually intersecting the viewport. A single point
    /// cannot identify both a float and adjacent body text at the same height.
    func visibleCharacterRange(in rect: CGRect) -> NSRange? {
        ReaderVisualLine.sourceRange(intersecting: rect, in: visualLines())
    }

    /// The first character of the first line mostly below `y` (`lineEnd` false), or the end of
    /// the last line mostly above it (`lineEnd` true), in text container coordinates, among the
    /// lines already laid out.
    func lineBoundary(atContainerY y: CGFloat, lineEnd: Bool) -> Int {
        if readerContainer.hasNonlinearGeometry {
            return ReaderVisualLine.boundary(at: y, lineEnd: lineEnd, in: visualLines(), length: textLength)
        }
        let layoutManager = readerLayoutManager
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else {
            return y <= 0 ? 0 : textLength
        }
        let start = offset(of: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        if lineEnd {
            if let line = lines.last(where: { frame.minY + $0.typographicBounds.midY <= y }) {
                return start + line.characterRange.upperBound
            }
            return start
        }
        if let line = lines.first(where: { frame.minY + $0.typographicBounds.midY >= y }) {
            return start + line.characterRange.location
        }
        return offset(of: fragment.rangeInElement.endLocation)
    }
}
