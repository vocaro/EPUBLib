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

    /// The source envelope of the lines `rect` mostly shows: those whose middle it holds, top
    /// to bottom, and a line taller than `rect` that holds its middle. That leaves out a line
    /// showing less than half of itself at the top or bottom edge, as the first line mostly
    /// below the top is the first one on screen where TextKit places the lines
    /// (`ReaderTextView.lineBoundary`). A shown position rests within a point of the top, and
    /// the line above it ends where it starts, so that line can show a sliver; it is not on
    /// screen for that. When `rect`'s middle is in a gap and it mostly shows no line, every
    /// line it shows at all counts. A line that is not `seen` counts only when no other does:
    /// one that holds hidden labels alone has no height and shows nothing
    /// (`ReaderTextView.hiddenLabelsAlone`). Only the lines `rect` reaches are asked.
    static func sourceRange(mostlyWithin rect: CGRect, in lines: [Self], seen: (Self) -> Bool = { _ in true }) -> NSRange? {
        let reached = lines.filter { $0.range.length > 0 && !$0.frame.intersection(rect).isEmpty && seen($0) }
        let shown = reached.filter {
            (rect.minY <= $0.frame.midY && $0.frame.midY <= rect.maxY) || ($0.frame.minY <= rect.midY && rect.midY <= $0.frame.maxY)
        }
        return sourceRange(intersecting: rect, in: shown) ?? sourceRange(intersecting: rect, in: reached)
            ?? sourceRange(intersecting: rect, in: lines)
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
        container.deliverIndents(for: storage)
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
        // The outgoing text's box geometry is not the new text's: until `refreshFlowBoxLayout`
        // plans it, the new paragraphs are plain ones with their own indents.
        readerContainer.configureBoxes(in: NSAttributedString())
        contentStorage.textStorage?.setAttributedString(text)
        refreshFlowBoxLayout()
        exposeTextualAttachments()
    }

    /// Recomputes native box geometry without replacing characters or disturbing selection.
    /// True when the text's attributes were written again, which lays all of it out anew;
    /// `layoutFollowsViewport` keeps the answer.
    @discardableResult func refreshFlowBoxLayout() -> Bool {
        layoutFollowsViewport = false
        guard let storage = contentStorage.textStorage, let source = flowSourceText else { return false }
        let text: NSAttributedString
        if source.length > 0, source.attribute(.readerBoxPage, at: 0, effectiveRange: nil) != nil {
            text = source
        } else { text = ReaderBoxLayout.resolve(source, viewport: readerContainer.viewportSize).text }
        readerContainer.configureBoxes(in: text)
        (readerLayoutManager as? ReaderBoxLayoutManager)?.configureGeometry()
        // Ordinary sections already hold the source attributes. Avoid resetting every run
        // (and invalidating a whole book's native layout) when no box geometry changed them.
        if text === source, readerContainer.boxPage == nil { return false }
        layoutFollowsViewport = true
        if storage.string == text.string {
            storage.beginEditing()
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
        } else { storage.setAttributedString(text) }
        return true
    }

    /// Each attachment that stands for text (`ReaderTextualAttachment`), with its range.
    func textualAttachments(in range: NSRange? = nil) -> [(attachment: NSTextAttachment, text: String, range: NSRange)] {
        guard let storage = contentStorage.textStorage else { return [] }
        let full = NSRange(location: 0, length: storage.length)
        var result: [(NSTextAttachment, String, NSRange)] = []
        storage.enumerateAttribute(.attachment, in: range.map { NSIntersectionRange($0, full) } ?? full) { value, run, _ in
            if let math = value as? MathAttachment, math.inline != nil {
                // AX metadata is independent of the requested substring: one reading at
                // the formula's first slot in this view, including a continuation page.
                if run.location == max(0, run.location - math.row) {
                    result.append((math, math.label, NSRange(location: run.location, length: 1)))
                }
                return
            }
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

    /// What VoiceOver is given of `range` (clamped): `plainText(in:)`, without the words of an
    /// image the book keeps from assistive technology (`ReaderTextualAttachment.spokenEquivalent`).
    func spokenText(in range: NSRange) -> String {
        guard let storage = contentStorage.textStorage else { return "" }
        return storage.readerPlainText(in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length)), spoken: true)
    }

    /// The characters the reader sees: a page column's own page, without its clipped context.
    var shownCharacters: NSRange { NSRange(location: 0, length: min(placement.visibleLength, textLength)) }

    /// The text the reader sees, attachments read as their text equivalents.
    var visibleText: String { plainText(in: shownCharacters) }

    /// The measured lines belonging to this page. Paragraph continuation context remains in
    /// TextKit storage, but every exposed character range ends at the page boundary.
    var pageAccessibilityLines: [ReaderVisualLine] { measuredLines(in: shownCharacters) }

    /// The measured lines of `range` in source order, the first and last cut to it.
    func measuredLines(in range: NSRange) -> [ReaderVisualLine] {
        var result: [ReaderVisualLine] = []
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            guard let line = line(containing: cursor) else { break }
            let upper = min(NSMaxRange(range), NSMaxRange(line.range))
            guard upper > cursor else { break }
            result.append(ReaderVisualLine(frame: line.frame,
                range: NSRange(location: cursor, length: upper - cursor)))
            cursor = upper
        }
        return result
    }

    /// Replaces the drawn highlights, in order, each over those before it. Rendering attributes
    /// only: the text is never changed. TextKit draws the fill, and the reader's fragments the
    /// mark (`ReaderLayoutFragment`). A mark underlines the text's characters and not an
    /// attachment: under a picture, a formula or a table's row it would be a line under the
    /// whole of it, and a cell's text view draws the marks of its own words
    /// (`TableCellTextView`).
    func setHighlights(_ highlights: [(range: NSRange, paint: ReaderHighlightPaint)]) {
        let layoutManager = readerLayoutManager
        for key in [NSAttributedString.Key.backgroundColor, .readerHighlightMark, .readerHighlightMarkColor] {
            layoutManager.removeRenderingAttribute(key, for: layoutManager.documentRange)
        }
        for highlight in highlights {
            guard let range = textRange(for: highlight.range) else { continue }
            layoutManager.addRenderingAttribute(.backgroundColor, value: highlight.paint.fill, for: range)
            guard highlight.paint.replacesMarks else { continue }
            layoutManager.removeRenderingAttribute(.readerHighlightMark, for: range)
            layoutManager.removeRenderingAttribute(.readerHighlightMarkColor, for: range)
            guard let mark = highlight.paint.mark else { continue }
            for run in textRuns(in: highlight.range) {
                guard let range = textRange(for: run) else { continue }
                layoutManager.addRenderingAttribute(.readerHighlightMark, value: mark.style.rawValue, for: range)
                layoutManager.addRenderingAttribute(.readerHighlightMarkColor, value: mark.color, for: range)
            }
        }
        // A rendering attribute changes what a fragment draws, not its layout, and TextKit 2
        // repaints a laid-out fragment only for the latter: without this a cleared highlight
        // stays on the page, and one added in place is missing, until the text next reflows.
        setRenderedTextNeedsDisplay()
    }

    /// The parts of `range` that hold no attachment.
    private func textRuns(in range: NSRange) -> [NSRange] {
        guard let storage = contentStorage.textStorage else { return [] }
        var runs: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length))) { value, run, _ in
            guard value == nil else { return }
            if let last = runs.last, NSMaxRange(last) == run.location { runs[runs.count - 1].length += run.length } else { runs.append(run) }
        }
        return runs
    }

    /// Native TextKit insertion offset nearest a point, without invoking TextKit 1.
    func characterOffset(at point: CGPoint) -> Int {
        let local = CGPoint(x: point.x - containerOrigin.x, y: point.y - containerOrigin.y)
        guard let fragment = drawnFragment(at: local) else {
            return local.y <= 0 ? 0 : textLength
        }
        let start = offset(of: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let relative = CGPoint(x: local.x - frame.minX, y: local.y - frame.origin.y)
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
        guard let fragment = drawnFragment(at: location),
              let storage = contentStorage.textStorage else { return nil }
        let frame = fragment.layoutFragmentFrame
        let local = CGPoint(x: location.x - frame.minX, y: location.y - frame.origin.y)
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
            ? bounds.offsetBy(dx: frame.minX, dy: frame.origin.y)
            : CGRect(x: frame.minX, y: frame.origin.y + bounds.minY, width: frame.width, height: bounds.height)
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
        guard let fragment = drawnFragment(at: CGPoint(x: 0, y: y)) else { return false }
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
                lines.append(ReaderVisualLine(frame: line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.origin.y),
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

    /// The source envelope of the lines the viewport mostly shows
    /// (`ReaderVisualLine.sourceRange(mostlyWithin:in:)`): what is on screen to a reader.
    func mostlyVisibleCharacterRange(in rect: CGRect) -> NSRange? {
        ReaderVisualLine.sourceRange(mostlyWithin: rect, in: visualLines()) { hiddenLabelsAlone(at: $0.range.location) == nil }
    }

    /// The paragraph holding `location` when it holds hidden labels and nothing else
    /// (`SpokenLabelAttachment`): one line, which has no height and shows nothing. It is in the
    /// visible area whenever the line after it is at the top, and is not the first line on
    /// screen for that. Read from the text alone: nothing is laid out for it.
    func hiddenLabelsAlone(at location: Int) -> NSRange? {
        guard let storage = contentStorage.textStorage, location >= 0, location < storage.length else { return nil }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
        guard storage.attribute(.attachment, at: paragraph.location, effectiveRange: nil) is SpokenLabelAttachment else { return nil }
        var alone = true
        storage.enumerateAttribute(.attachment, in: paragraph) { value, run, stop in
            if value is SpokenLabelAttachment { return }
            if value != nil || text.rangeOfCharacter(from: CharacterSet.newlines.inverted, range: run).location != NSNotFound {
                alone = false; stop.pointee = true
            }
        }
        return alone ? paragraph : nil
    }

    /// `location` moved past the lines from it on that hold hidden labels alone.
    func firstShownLine(from location: Int) -> Int {
        var location = location
        while let labels = hiddenLabelsAlone(at: location) { location = NSMaxRange(labels) }
        return location
    }

    /// `location`, the end of a line, moved back before the lines ending there that hold hidden
    /// labels alone.
    func lastShownLine(upTo location: Int) -> Int {
        var location = location
        while let labels = hiddenLabelsAlone(at: location - 1) { location = labels.location }
        return location
    }

    /// The fragment the viewport last laid out at container `y`: the one the view draws there.
    /// Once the whole text has been laid out behind the view, as an assistive technology's read
    /// of every paragraph's frame does, TextKit 2 holds two fragments at one place: UIKit goes
    /// on drawing the viewport's where the earlier estimates put them, and every other one
    /// stands at its exact distance from the top. Asked for the fragment at a point, the layout
    /// manager can answer with the one that is not on screen, a chapter away.
    private func viewportFragment(atContainerY y: CGFloat) -> NSTextLayoutFragment? {
        // A range kept from text since replaced can reach past the end of what is here now.
        guard let range = readerLayoutManager.textViewportLayoutController.viewportRange,
              range.endLocation.compare(readerLayoutManager.documentRange.endLocation) != .orderedDescending else { return nil }
        var found: NSTextLayoutFragment?
        readerLayoutManager.enumerateTextLayoutFragments(from: range.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(range.endLocation) == .orderedAscending else { return false }
            let frame = fragment.layoutFragmentFrame
            if frame.minY <= y, y < frame.maxY { found = fragment }
            return found == nil
        }
        return found
    }

    /// Hit tests use the same fragments as the visible-range read. A completed offscreen
    /// layout can overlap a viewport fragment without replacing the text drawn there.
    func drawnFragment(at point: CGPoint) -> NSTextLayoutFragment? {
        if !readerContainer.hasNonlinearGeometry, let fragment = viewportFragment(atContainerY: point.y) {
            return fragment
        }
        return readerLayoutManager.textLayoutFragment(for: point)
    }

    /// The first character of the first line mostly below `y` (`lineEnd` false), or the end of
    /// the last line mostly above it (`lineEnd` true), in text container coordinates, among the
    /// lines already laid out: the viewport's own where it has any at `y`.
    func lineBoundary(atContainerY y: CGFloat, lineEnd: Bool) -> Int {
        if readerContainer.hasNonlinearGeometry {
            return ReaderVisualLine.boundary(at: y, lineEnd: lineEnd, in: visualLines(), length: textLength)
        }
        guard let fragment = drawnFragment(at: CGPoint(x: 0, y: max(0, y))) else {
            return y <= 0 ? 0 : textLength
        }
        let start = offset(of: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        if lineEnd {
            if let line = lines.last(where: { frame.origin.y + $0.typographicBounds.midY <= y }) {
                return start + line.characterRange.upperBound
            }
            return start
        }
        if let line = lines.first(where: { frame.origin.y + $0.typographicBounds.midY >= y }) {
            return start + line.characterRange.location
        }
        return offset(of: fragment.rangeInElement.endLocation)
    }
}
