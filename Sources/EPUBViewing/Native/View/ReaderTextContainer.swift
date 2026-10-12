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
    var boxScope: UUID?
    var paragraphText: NSAttributedString?
    /// The space an aligned flex or grid box keeps above the text's first line
    /// (`.readerAlignmentLead`). TextKit drops the spacing before a document's first paragraph,
    /// so the layout manager restores this much as that fragment's top margin.
    var alignmentLead: CGFloat = 0
    var hasNonlinearGeometry: Bool { boxPage != nil || !boxRegions.isEmpty }

    // The default becomes false merely because lineFragmentRect is overridden. Ordinary
    // sections remain rectangular and must retain TextKit's fast viewport/paragraph layout.
    override var isSimpleRectangularTextContainer: Bool {
        !hasNonlinearGeometry && boxOverride == nil && boxColumn == nil
            && exclusionPaths.isEmpty && maximumNumberOfLines == 0
    }

    func configureBoxes(in text: NSAttributedString) {
        paragraphText = text
        boxPage = text.length > 0 ? text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage : nil
        boxRegions = boxPage?.geometry.regions ?? []
        boxOrigin = boxPage?.origin ?? 0
        boxSourceOffset = boxPage?.offset ?? 0
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
        return writingDirection == .rightToLeft ? (trailing, leading) : (leading, trailing)
    }

    override func lineFragmentRect(forProposedRect proposed: CGRect, at index: Int,
                                   writingDirection: NSWritingDirection, remaining: UnsafeMutablePointer<CGRect>?) -> CGRect {
        // The entry point is only reached for a container that is not a plain rectangle.
        let delivers = deliversIndents && !isSimpleRectangularTextContainer
        let ownRegion = boxPage?.geometry.regions.first(where: { !$0.reserved && NSLocationInRange(index + boxSourceOffset, $0.range) })
        if let frame = boxOverride ?? ownRegion?.contentFrame ?? ownRegion?.frame {
            remaining?.pointee = .zero
            guard delivers else { return CGRect(x: frame.minX, y: proposed.minY, width: frame.width, height: proposed.height) }
            let insets = lineInsets(at: index, writingDirection: writingDirection, width: frame.width)
            let minX = frame.minX + insets.left
            return CGRect(x: minX, y: proposed.minY, width: max(1, frame.maxX - insets.right - minX), height: proposed.height)
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
        rect.size.width = max(0, min(rect.maxX, size.width) - rect.minX)
        if let column, !delivers {
            rect.origin.x = max(rect.minX, column.minX)
            rect.size.width = max(1, min(size.width, column.maxX) - rect.minX)
        }
        while true {
            let global = rect.offsetBy(dx: 0, dy: boxOrigin)
            let scope = boxScope ?? boxPage?.geometry.paragraph(at: sourceIndex)?.scope
            let obstacles = boxRegions.filter {
                (($0.wrapsEarlierText && $0.scope == scope) || $0.range.upperBound <= sourceIndex) && $0.frame.intersects(global)
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
            rect.origin.y = max(rect.minY + 1, (obstacles.map(\.frame.maxY).max() ?? global.maxY) - boxOrigin)
        }
    }

    /// Attaches the container to the content storage it lays out, so that it delivers paragraph
    /// indents itself wherever it has box geometry (`lineFragmentRect`).
    func deliverIndents(for storage: NSTextContentStorage) { storage.delegate = self }

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
        if origin != 0, !style.tabStops.isEmpty {
            flat.tabStops = style.tabStops.map {
                NSTextTab(textAlignment: $0.alignment, location: max(0, $0.location - origin), options: $0.options)
            }
        }
        let paragraph = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        paragraph.addAttribute(.paragraphStyle, value: flat, range: NSRange(location: 0, length: paragraph.length))
        return NSTextParagraph(attributedString: paragraph)
    }
}
