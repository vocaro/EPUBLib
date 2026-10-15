import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// TextKit's ordinary fragments and selection geometry, with margins implementing the planned
/// flow advances. A float has zero flow height but retains all of its native glyph lines.
final class ReaderBoxLayoutFragment: NSTextLayoutFragment {
    var topAdjustment: CGFloat = 0
    var bottomAdjustment: CGFloat = 0
    var repairsPageFlow = false
    var previousHeldBack: (() -> CGFloat)?
    var heldBack: CGFloat {
        let frame = super.layoutFragmentFrame
        return max(0, -(frame.origin.y + frame.size.height))
    }
    override var topMargin: CGFloat { super.topMargin + topAdjustment - (previousHeldBack?() ?? 0) }
    override var bottomMargin: CGFloat { super.bottomMargin + bottomAdjustment }

    /// Unplanned fragments keep the established rounding-only correction. A planned page
    /// can have a real negative end after its first box's visual displacement is truncated.
    static let roundingLimit: CGFloat = 1e-6

    /// TextKit starts the next fragment at this end and stacks its lines if the end is above
    /// the container. Hold the flow at zero without moving this fragment's glyphs. The next
    /// planned fragment returns precisely the distance held back through its top margin.
    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        let end = frame.origin.y + frame.size.height
        if end < 0, repairsPageFlow || end > -Self.roundingLimit { frame.size.height = -frame.origin.y }
        return frame
    }
}

final class ReaderBoxLayoutManager: NSTextLayoutManager, NSTextLayoutManagerDelegate {
    var repairsPageFlow = true
    private var pageFragments: [Int: ReaderBoxLayoutFragment] = [:]

    override init() {
        super.init()
        delegate = nil
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func configureGeometry() {
        let container = textContainer as? ReaderTextContainer
        pageFragments.removeAll()
        container?.proposalCorrection = { [weak self] index in
            guard self?.repairsPageFlow == true, let fragment = self?.pageFragments[index] else { return 0 }
            // TextKit proposes a fragment's first line before adding its top margin. At
            // the page start, exclusions must see where that margin actually puts it.
            return -(index == 0 ? fragment.topAdjustment : 0)
        }
        delegate = container?.boxPage != nil || (container?.alignmentLead ?? 0) > 0 ? self : nil
    }

    func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in element: NSTextElement) -> NSTextLayoutFragment {
        guard let container = textContainer as? ReaderTextContainer,
              let content = textContentManager else { return NSTextLayoutFragment(textElement: element, range: nil) }
        let offset = content.offset(from: content.documentRange.location, to: location)
        guard let page = container.boxPage else {
            // An aligned box opening the text: its lead above the first line.
            guard offset == 0, container.alignmentLead > 0 else { return NSTextLayoutFragment(textElement: element, range: nil) }
            let fragment = ReaderBoxLayoutFragment(textElement: element, range: nil)
            fragment.topAdjustment = container.alignmentLead
            return fragment
        }
        guard let paragraph = page.geometry.paragraph(at: offset + page.offset) else {
            return NSTextLayoutFragment(textElement: element, range: nil)
        }
        let fragment = ReaderBoxLayoutFragment(textElement: element, range: nil)
        fragment.topAdjustment = paragraph.topAdjustment
        fragment.bottomAdjustment = paragraph.bottomAdjustment
        fragment.repairsPageFlow = repairsPageFlow
        if repairsPageFlow, offset > 0, let before = page.geometry.paragraph(at: offset + page.offset - 1) {
            let previousOffset = max(0, before.range.location - page.offset)
            fragment.previousHeldBack = { [weak self] in self?.pageFragments[previousOffset]?.heldBack ?? 0 }
        }
        pageFragments[offset] = fragment
        // A page's first paragraph starts at its visual origin, rather than the full section's
        // flow cursor. Preserve the total advance while removing only that leading displacement.
        if offset == 0, page.offset > paragraph.range.location || page.beginsTableContinuation {
            fragment.topAdjustment = 0
            fragment.bottomAdjustment = 0
        } else if offset == 0 {
            // The fragment starts as far below the page's top as in the section, never above
            // it. Where a box as wide as the column pushed the first line down inside its
            // fragment, the page's origin is that line's top: the box lies above the page and
            // pushes nothing here, so there is no distance to take back. TextKit would apply a
            // negative margin on a document's first fragment twice, to it and to its lines,
            // and even a rounding residual below zero moves every line of the page up with it.
            let shift = paragraph.flowStart - page.origin
            fragment.topAdjustment = max(0, fragment.topAdjustment + shift)
            // A positioned first box can stand above the flow cursor (bottom positioning).
            // Its glyphs start at the page top, but the following paragraph still begins at
            // that cursor, so keep the positive remainder in its advance.
            let displacement = paragraph.topAdjustment + paragraph.spacingAbove
            if repairsPageFlow, paragraph.isBox, displacement < 0, shift > 0 {
                fragment.bottomAdjustment += min(shift, -displacement)
            }
        }
        return fragment
    }

    override func textLayoutFragment(for position: CGPoint) -> NSTextLayoutFragment? {
        guard let container = textContainer as? ReaderTextContainer, let page = container.boxPage,
              let content = textContentManager else { return super.textLayoutFragment(for: position) }
        let global = position.offsetBy(dx: 0, dy: planOrigin(near: position, page: page, content: content))
        for region in page.geometry.regions where region.frame.contains(global) {
            let offset = max(0, region.range.location - page.offset)
            guard offset < content.offset(from: content.documentRange.location, to: content.documentRange.endLocation),
                  let location = content.location(content.documentRange.location, offsetBy: offset) else { continue }
            var found: NSTextLayoutFragment?
            enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location) + page.offset
                guard start < region.range.upperBound else { return false }
                let frame = fragment.layoutFragmentFrame
                if fragment.textLineFragments.contains(where: { $0.typographicBounds.offsetBy(dx: frame.minX, dy: frame.origin.y).contains(position) }) {
                    found = fragment; return false
                }
                return true
            }
            if let found { return found }
        }
        return super.textLayoutFragment(for: position)
    }

    /// How far the plan's coordinates are from the container's around `position`: the page's
    /// origin while everything above is laid out. In a long text shown part way down TextKit
    /// only estimates what is above, so it is read off the fragment laid out there: where the
    /// plan has that paragraph's first line against where the line is.
    private func planOrigin(near position: CGPoint, page: ReaderBoxPage, content: NSTextContentManager) -> CGFloat {
        guard let fragment = super.textLayoutFragment(for: position),
              let line = fragment.textLineFragments.first(where: { $0.characterRange.length > 0 }) else { return page.origin }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location) + page.offset
        guard let paragraph = page.geometry.paragraph(at: start), paragraph.range.location == start,
              let planned = paragraph.lines.first else { return page.origin }
        return planned.frame.origin.y - (fragment.layoutFragmentFrame.origin.y + line.typographicBounds.minY)
    }

    override func lineFragmentRange(for point: CGPoint, inContainerAt location: any NSTextLocation) -> NSTextRange? {
        guard (textContainer as? ReaderTextContainer)?.hasNonlinearGeometry == true else {
            return super.lineFragmentRange(for: point, inContainerAt: location)
        }
        guard let fragment = textLayoutFragment(for: point), let content = textContentManager else { return nil }
        let frame = fragment.layoutFragmentFrame
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        let line = lines.first { $0.typographicBounds.offsetBy(dx: frame.minX, dy: frame.origin.y).contains(point) }
            ?? lines.min { abs(frame.origin.y + $0.typographicBounds.midY - point.y) < abs(frame.origin.y + $1.typographicBounds.midY - point.y) }
        guard let line, let start = content.location(fragment.rangeInElement.location, offsetBy: line.characterRange.location),
              let end = content.location(start, offsetBy: line.characterRange.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
