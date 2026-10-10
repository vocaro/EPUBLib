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
    }

    override func lineFragmentRect(forProposedRect proposed: CGRect, at index: Int,
                                   writingDirection: NSWritingDirection, remaining: UnsafeMutablePointer<CGRect>?) -> CGRect {
        let ownRegion = boxPage?.geometry.regions.first(where: { !$0.reserved && NSLocationInRange(index + boxSourceOffset, $0.range) })
        if let frame = boxOverride ?? ownRegion?.contentFrame ?? ownRegion?.frame {
            remaining?.pointee = .zero
            return CGRect(x: frame.minX, y: proposed.minY, width: frame.width, height: proposed.height)
        }
        // Overriding this entry point disables TextKit's built-in tail-indent clipping, even
        // when forwarding to super. Restore the logical trailing edge for ordinary paragraphs.
        var proposal = proposed
        if let storage = paragraphText ?? (textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage,
           index < storage.length, let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle {
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
        let column = boxColumn ?? boxPage?.geometry.paragraph(at: index + boxSourceOffset)?.column
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
        if let column {
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

    /// The size an attachment may use: the proposed line width, and the viewport height (or a
    /// generous default before layout knows it).
    static func available(in container: NSTextContainer?, lineWidth: CGFloat) -> CGSize {
        let viewport = (container as? ReaderTextContainer)?.viewportSize ?? .zero
        let width = lineWidth > 0 ? lineWidth : (viewport.width > 0 ? viewport.width : 600)
        return CGSize(width: width, height: viewport.height > 0 ? viewport.height : 800)
    }
}
