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

    /// The text of `range` (clamped).
    func string(in range: NSRange) -> String {
        guard let storage = contentStorage.textStorage else { return "" }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        return (storage.string as NSString).substring(with: clamped)
    }

    /// The visible characters' text (a page column's own page).
    var visibleString: String { string(in: NSRange(location: 0, length: min(placement.visibleLength, textLength))) }

    /// Replaces the drawn highlights. Rendering attributes only: the text is never changed.
    func setHighlights(_ highlights: [(range: NSRange, color: PlatformColor)]) {
        let layoutManager = readerLayoutManager
        layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
        for highlight in highlights {
            guard let range = textRange(for: highlight.range) else { continue }
            layoutManager.addRenderingAttribute(.backgroundColor, value: highlight.color, for: range)
        }
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
        let length = textLength
        guard length > 0 else { return nil }
        let target = max(0, min(offset, length - 1))
        guard let range = textRange(for: NSRange(location: target, length: 1)) else { return nil }
        readerLayoutManager.ensureLayout(for: range)
        guard let fragment = readerLayoutManager.textLayoutFragment(for: range.location) else { return nil }
        let local = target - self.offset(of: fragment.rangeInElement.location)
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        guard let line = lines.first(where: { NSLocationInRange(local, $0.characterRange) }) ?? lines.last
        else { return fragment.layoutFragmentFrame }
        let frame = fragment.layoutFragmentFrame
        return CGRect(x: frame.minX, y: frame.minY + line.typographicBounds.minY, width: frame.width,
                      height: line.typographicBounds.height)
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
