import CoreGraphics
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The text container of every reader text view, including the paginator's measuring layout.
/// Attachments read `viewportSize` in `attachmentBounds(for:location:textContainer:…)`: an image
/// never exceeds one page, and `vw`/`vh` resolve against the reading viewport, not the screen.
final class ReaderTextContainer: NSTextContainer {
    /// Paginated: one column's width by the page's text height. Continuous scroll: the text
    /// column's width by the visible height. Zero until the view has a size.
    var viewportSize: CGSize = .zero
    var boxRegions: [ReaderBoxGeometry.Region] = []
    var boxOrigin: CGFloat = 0
    var boxSourceOffset = 0
    var boxPage: ReaderBoxPage?
    var boxOverride: CGRect?
    var boxColumn: CGRect?
    var proposalCorrection: ((Int) -> CGFloat)?
    var boxScope: UUID?
    var paragraphText: NSAttributedString? { didSet { indentClampCache = nil } }
    private var indentClampCache: (width: CGFloat, needed: Bool)?
    /// The space an aligned flex or grid box keeps above the text's first line
    /// (`.readerAlignmentLead`). TextKit drops the spacing before a document's first paragraph,
    /// so the layout manager restores this much as that fragment's top margin.
    var alignmentLead: CGFloat = 0
    /// Less than any line or box is tall, more than sums of their heights are out by.
    private static let edgeSlack: CGFloat = 0.01
    /// The planned paragraph whose lines are being placed, and how far the plan's coordinates
    /// are from this container's at its first line (`lineFragmentRect`).
    private var planned: (paragraph: Int, shift: CGFloat)?
    var hasNonlinearGeometry: Bool { boxPage != nil || !boxRegions.isEmpty }

    // The default becomes false merely because lineFragmentRect is overridden. Ordinary
    // sections remain rectangular and must retain TextKit's fast viewport/paragraph layout.
    override var isSimpleRectangularTextContainer: Bool {
        !hasNonlinearGeometry && !needsIndentClamping && boxOverride == nil && boxColumn == nil
            && exclusionPaths.isEmpty && maximumNumberOfLines == 0
    }

    /// Ordinary paragraphs keep TextKit's fast rectangular path. An indent that consumes
    /// the column needs our delegate too: native layout can stop at that paragraph entirely.
    private var needsIndentClamping: Bool {
        guard size.width > 0, let text = layoutText else { return false }
        if let cached = indentClampCache, cached.width == size.width { return cached.needed }
        var needed = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let style = value as? NSParagraphStyle else { return }
            let tail = max(0, style.tailIndent <= 0 ? -style.tailIndent : self.size.width - style.tailIndent)
            if max(0, style.headIndent, style.firstLineHeadIndent) + tail >= self.size.width {
                needed = true; stop.pointee = true
            }
        }
        indentClampCache = (size.width, needed)
        return needed
    }

    /// Leave a visible place for a glyph when authored insets consume the entire column.
    /// A one-point width lets TextKit advance, but still clips nearly every glyph at its edge.
    private func minimumLineWidth(at index: Int, width: CGFloat) -> CGFloat {
        let font = layoutText.flatMap { text in
            index >= 0 && index < text.length ? text.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont : nil
        }
        return min(width, max(1, (font?.pointSize ?? 16) * 2))
    }

    private func visibleRect(_ rect: CGRect, within bounds: CGRect, at index: Int) -> CGRect {
        guard bounds.width > 0 else { return rect }
        let right = min(bounds.maxX, rect.maxX)
        let left = max(bounds.minX, rect.minX)
        if right > left { return CGRect(x: left, y: rect.minY, width: right - left, height: rect.height) }
        let width = minimumLineWidth(at: index, width: bounds.width)
        let x = min(max(bounds.minX, left), bounds.maxX - width)
        return CGRect(x: x, y: rect.minY, width: width, height: rect.height)
    }

    func configureBoxes(in text: NSAttributedString) {
        paragraphText = text
        boxPage = text.length > 0 ? text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage : nil
        boxRegions = boxPage?.geometry.regions ?? []
        boxOrigin = boxPage?.origin ?? 0
        boxSourceOffset = boxPage?.offset ?? 0
        planned = nil
        alignmentLead = ReaderAlignmentLayout.lead(in: text, at: 0)
    }

    /// Whether this container gives each line its paragraph's indents (`lineInsets`), which it
    /// does once it is its content storage's delegate: TextKit then sees paragraphs without any.
    private var deliversIndents: Bool {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate === self
    }

    private var layoutText: NSAttributedString? {
        if let paragraphText { return paragraphText }
        let storage = textLayoutManager?.textContentManager as? NSTextContentStorage
        return storage?.textStorage ?? storage?.attributedString
    }

    /// The paragraph style laid out at `index`, with the indents TextKit is not shown.
    private func paragraphStyle(at index: Int) -> NSParagraphStyle? {
        guard let text = layoutText, index >= 0, index < text.length else { return nil }
        return text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    /// What the line starting at `index` keeps clear at each side of a box `width` wide: its
    /// paragraph's first-line or head indent at the leading edge, its tail indent at the other.
    private func lineInsets(at index: Int, writingDirection: NSWritingDirection, width: CGFloat) -> (left: CGFloat, right: CGFloat) {
        guard let text = layoutText, let style = paragraphStyle(at: index) else { return (0, 0) }
        let opensParagraph = index == 0 || ReaderAlignmentLayout.isParagraphBreak((text.string as NSString).character(at: index - 1))
        let leading = max(0, opensParagraph ? style.firstLineHeadIndent : style.headIndent)
        let trailing = max(0, style.tailIndent <= 0 ? -style.tailIndent : width - style.tailIndent)
        var insets = writingDirection == .rightToLeft ? (left: trailing, right: leading) : (left: leading, right: trailing)
        if insets.left + insets.right >= width {
            let available = max(0, width - minimumLineWidth(at: index, width: width))
            insets.left = min(insets.left, available)
            insets.right = min(insets.right, available - insets.left)
        }
        return insets
    }

    override func lineFragmentRect(forProposedRect proposed: CGRect, at index: Int,
                                   writingDirection: NSWritingDirection, remaining: UnsafeMutablePointer<CGRect>?) -> CGRect {
        let correction = proposalCorrection?(boxPage?.geometry.paragraph(at: index + boxSourceOffset).map { $0.range.location - boxSourceOffset } ?? index) ?? 0
        let result = lineRect(forProposedRect: proposed.offsetBy(dx: 0, dy: -correction), at: index, writingDirection: writingDirection, remaining: remaining)
        if correction != 0, let remaining, remaining.pointee != .zero { remaining.pointee.origin.y += correction }
        return result.offsetBy(dx: 0, dy: correction)
    }

    private func lineRect(forProposedRect proposed: CGRect, at index: Int,
                          writingDirection: NSWritingDirection, remaining: UnsafeMutablePointer<CGRect>?) -> CGRect {
        // The entry point is only reached for a container that is not a plain rectangle.
        let delivers = deliversIndents && !isSimpleRectangularTextContainer
        let ownRegion = boxPage?.geometry.regions.first(where: { !$0.reserved && NSLocationInRange(index + boxSourceOffset, $0.range) })
        if let frame = boxOverride ?? ownRegion?.contentFrame ?? ownRegion?.frame {
            remaining?.pointee = .zero
            guard delivers else { return CGRect(x: frame.minX, y: proposed.minY, width: frame.width, height: proposed.height) }
            let insets = lineInsets(at: index, writingDirection: writingDirection, width: frame.width)
            let minX = frame.minX + insets.left
            return visibleRect(CGRect(x: minX, y: proposed.minY, width: max(1, frame.maxX - insets.right - minX), height: proposed.height), within: frame, at: index)
        }
        let column = boxColumn ?? boxPage?.geometry.paragraph(at: index + boxSourceOffset)?.column
        var proposal = proposed
        if delivers {
            // Once this entry point is overridden TextKit wraps a line within its paragraph's
            // indents but aligns and justifies it across the whole rectangle returned here, as
            // if it had none: a centred line sits half its indents too far along and a
            // right-aligned or justified one runs past the tail indent. So TextKit is given
            // paragraphs without indents (`textContentStorage(_:textParagraphWith:)`) and each
            // line's rectangle is the place its paragraph's indents leave it.
            let box = column ?? CGRect(x: 0, y: 0, width: size.width, height: 0)
            let insets = lineInsets(at: index, writingDirection: writingDirection, width: box.width)
            let maxX = min(proposal.maxX, min(size.width, box.maxX) - insets.right)
            proposal.origin.x = max(proposal.minX, box.minX + insets.left)
            proposal.size.width = max(1, maxX - proposal.minX)
        } else if let style = paragraphStyle(at: index) {
            // Without the delegate TextKit applies the indents itself; only the trailing edge
            // is narrowed here, as before.
            if writingDirection == .rightToLeft {
                let left = style.tailIndent <= 0 ? -style.tailIndent : size.width - style.tailIndent
                let right = proposal.maxX
                proposal.origin.x = max(proposal.minX, left)
                proposal.size.width = max(1, right - proposal.minX)
            } else {
                let right = style.tailIndent <= 0 ? size.width + style.tailIndent : style.tailIndent
                proposal.size.width = max(1, min(proposal.maxX, right) - proposal.minX)
            }
        }
        proposal = visibleRect(proposal, within: column ?? CGRect(x: 0, y: 0, width: size.width, height: 0), at: index)
        guard !boxRegions.isEmpty || column != nil else {
            return super.lineFragmentRect(forProposedRect: proposal, at: index, writingDirection: writingDirection, remaining: remaining)
        }
        let sourceIndex = index + boxSourceOffset
        // A box lays out in its own paragraph insets; exclusions apply to following flow text.
        if boxPage?.geometry.paragraph(at: sourceIndex)?.isBox == true {
            return super.lineFragmentRect(forProposedRect: proposal, at: index, writingDirection: writingDirection, remaining: remaining)
        }
        remaining?.pointee = .zero
        var rect = proposal
        rect = visibleRect(rect, within: CGRect(x: 0, y: 0, width: size.width, height: 0), at: index)
        if let column, !delivers {
            rect.origin.x = max(rect.minX, column.minX)
            rect.size.width = max(1, min(size.width, column.maxX) - rect.minX)
            rect = visibleRect(rect, within: column, at: index)
        }
        // The plan's regions are where it put them, and this container's lines are wherever
        // TextKit has got to. The two agree while everything above is laid out. In a long text
        // shown part way down, TextKit only estimates what is above, and a line can be screens
        // from where the plan has it: it would miss the boxes beside it and meet others that
        // are nowhere near. So a planned paragraph's lines are taken to the plan from where its
        // own first line was proposed, and text past the plan's end is below every box. The
        // paragraph this container opens with keeps the container's own origin: a page's is
        // its first line's place, wherever a box above the page pushed that line.
        var origin = boxOrigin
        if let page = boxPage {
            guard let paragraph = page.geometry.paragraph(at: sourceIndex) else { return rect }
            if index > 0, sourceIndex == paragraph.range.location {
                planned = (sourceIndex, paragraph.flowStart + paragraph.topAdjustment - proposed.minY - (proposalCorrection?(paragraph.range.location - boxSourceOffset) ?? 0))
            }
            if let planned, planned.paragraph == paragraph.range.location { origin = planned.shift }
        }
        while true {
            let global = rect.offsetBy(dx: 0, dy: origin)
            let scope = boxScope ?? boxPage?.geometry.paragraph(at: sourceIndex)?.scope
            // A line that starts where a box ends is clear of it, whatever the arithmetic that
            // brought the two edges together left between them.
            let reach = global.insetBy(dx: 0, dy: min(Self.edgeSlack, global.height / 4))
            let obstacles = boxRegions.filter {
                (($0.wrapsEarlierText && $0.scope == scope) || $0.range.upperBound <= sourceIndex) && $0.frame.intersects(reach)
            }
            guard !obstacles.isEmpty else { return rect }
            var intervals = [(rect.minX, rect.maxX)]
            for obstacle in obstacles {
                intervals = intervals.flatMap { left, right -> [(CGFloat, CGFloat)] in
                    if obstacle.frame.maxX <= left || obstacle.frame.minX >= right { return [(left, right)] }
                    var pieces: [(CGFloat, CGFloat)] = []
                    if obstacle.frame.minX > left { pieces.append((left, obstacle.frame.minX)) }
                    if obstacle.frame.maxX < right { pieces.append((obstacle.frame.maxX, right)) }
                    return pieces
                }
            }
            let readable = min(size.width / 3, 48)
            intervals = intervals.filter { $0.1 - $0.0 >= readable }
            if let interval = writingDirection == .rightToLeft ? intervals.last : intervals.first {
                if intervals.count > 1 {
                    let other = writingDirection == .rightToLeft ? intervals.first! : intervals.last!
                    remaining?.pointee = CGRect(x: other.0, y: rect.minY, width: other.1 - other.0, height: rect.height)
                }
                return CGRect(x: interval.0, y: rect.minY, width: interval.1 - interval.0, height: rect.height)
            }
            rect.origin.y = max(rect.minY + 1, (obstacles.map(\.frame.maxY).max() ?? global.maxY) - origin)
        }
    }

    /// Attaches the container to the content storage it lays out, so that it delivers paragraph
    /// indents itself wherever it has box geometry (`lineFragmentRect`).
    func deliverIndents(for storage: NSTextContentStorage) { storage.delegate = self }

    /// The attachment's containing content column, even when TextKit's preliminary proposal
    /// still spans the viewport. Measurement uses boxOverride; actual page layout uses the
    /// region containing this source character, retaining the original viewport for vw/vh.
    func attachmentColumn(at index: Int?) -> CGRect? {
        if let boxOverride { return boxOverride }
        guard let index, index >= 0 else { return boxColumn }
        let sourceIndex = index + boxSourceOffset
        if let region = boxPage?.geometry.regions.first(where: { !$0.reserved && NSLocationInRange(sourceIndex, $0.range) }) {
            return region.contentFrame ?? region.frame
        }
        return boxColumn ?? boxPage?.geometry.paragraph(at: sourceIndex)?.column
    }

    /// The size an attachment may use: the proposed line width, and the viewport height (or a
    /// generous default before layout knows it).
    static func available(in container: NSTextContainer?, lineWidth: CGFloat) -> CGSize {
        let viewport = (container as? ReaderTextContainer)?.viewportSize ?? .zero
        let width = lineWidth > 0 ? lineWidth : (viewport.width > 0 ? viewport.width : 600)
        return CGSize(width: width, height: viewport.height > 0 ? viewport.height : 800)
    }
}

extension ReaderTextContainer: NSTextContentStorageDelegate {
    /// A paragraph as TextKit lays it out in a container with box geometry: without the head,
    /// first-line and tail indents that `lineFragmentRect` gives each of its lines. The stored
    /// text keeps them. Tab stops are measured from a line's start, which the first-line indent
    /// has now moved, so they move back by it.
    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard !isSimpleRectangularTextContainer, range.length > 0,
              let text = textContentStorage.textStorage ?? textContentStorage.attributedString, range.upperBound <= text.length,
              let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              style.headIndent != 0 || style.firstLineHeadIndent != 0 || style.tailIndent != 0 else { return nil }
        let flat = style.mutableCopy() as! NSMutableParagraphStyle
        let origin = max(0, style.firstLineHeadIndent)
        flat.headIndent = 0; flat.firstLineHeadIndent = 0; flat.tailIndent = 0
        if !style.tabStops.isEmpty {
            let trailing = max(0, style.tailIndent <= 0 ? -style.tailIndent : size.width - style.tailIndent)
            let consumed = max(0, style.headIndent, style.firstLineHeadIndent) + trailing >= size.width
            let lastStop = max(1, size.width - minimumLineWidth(at: range.location, width: size.width))
            flat.tabStops = style.tabStops.map {
                let location = max(0, $0.location - origin)
                return NSTextTab(textAlignment: $0.alignment, location: consumed ? min(location, lastStop) : location, options: $0.options)
            }
            if consumed { flat.defaultTabInterval = min(flat.defaultTabInterval, lastStop) }
        }
        let paragraph = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        paragraph.addAttribute(.paragraphStyle, value: flat, range: NSRange(location: 0, length: paragraph.length))
        return NSTextParagraph(attributedString: paragraph)
    }
}
