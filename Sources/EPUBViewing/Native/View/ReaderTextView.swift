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

// Platform-neutral TextKit 2 work on either platform's `ReaderTextView`. Nothing here touches
// `layoutManager`, which would drop the view to TextKit 1.
extension ReaderTextView {
    static func makeTextKitStack() -> (NSTextContentStorage, NSTextLayoutManager, ReaderTextContainer) {
        let storage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        storage.addTextLayoutManager(layoutManager)
        let container = ReaderTextContainer(size: CGSize(width: 0, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        return (storage, layoutManager, container)
    }

    var textLength: Int { contentStorage.textStorage?.length ?? 0 }

    func setContent(_ text: NSAttributedString) {
        contentStorage.textStorage?.setAttributedString(text)
        exposeTextualAttachments()
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

    /// Replaces the drawn highlights. Rendering attributes only: the text is never changed.
    func setHighlights(_ highlights: [(range: NSRange, color: PlatformColor)]) {
        let layoutManager = readerLayoutManager
        layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
        for highlight in highlights {
            guard let range = textRange(for: highlight.range) else { continue }
            layoutManager.addRenderingAttribute(.backgroundColor, value: highlight.color, for: range)
        }
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
        return (CGRect(x: frame.minX, y: frame.minY + line.typographicBounds.minY, width: frame.width,
                       height: line.typographicBounds.height),
                NSRange(location: start + line.characterRange.location, length: line.characterRange.length))
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
        guard let fragment = readerLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return false }
        let target = max(0, min(offset, textLength - 1))
        let range = fragment.rangeInElement
        return self.offset(of: range.location) <= target && target < self.offset(of: range.endLocation)
    }

    /// The first character of the first line mostly below `y` (`lineEnd` false), or the end of
    /// the last line mostly above it (`lineEnd` true), in text container coordinates, among the
    /// lines already laid out.
    func lineBoundary(atContainerY y: CGFloat, lineEnd: Bool) -> Int {
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
