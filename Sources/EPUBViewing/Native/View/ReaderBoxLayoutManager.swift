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
    override var topMargin: CGFloat { super.topMargin + topAdjustment }
    override var bottomMargin: CGFloat { super.bottomMargin + bottomAdjustment }

    /// The most a frame may end above its container's top by, in points, and be taken to end
    /// at it. It corrects no margin: it tells apart two things that lie far to either side of
    /// it in the sections generated to measure them, on macOS and on iOS.
    ///
    /// - What rounding leaves when a box's margins take back its height: about half an ulp of
    ///   how far down its section the page starts. That is 1e-12 or less within ten thousand
    ///   points of a section's top and 2e-10 a million points down.
    /// - How far a page's first box was pushed down from where the page's text flows from,
    ///   which a style sheet's lengths decide: a tenth of a point at the least, and mostly
    ///   tens of points. TextKit lays a one-line fragment out correctly from up there, and
    ///   does not once the frame before it is held at the top, so such a frame stays as it is
    ///   (https://github.com/vocaro/EPUBLib/issues/242).
    ///
    /// Rounding reaches this limit only on a page some ten billion points down its section,
    /// which is then laid out as it would be without the limit. A box pushed down by less than
    /// it is held at the top, and what follows stands that much lower, less than a millionth
    /// of a point.
    static let roundingLimit: CGFloat = 1e-6

    /// TextKit starts the next fragment where this frame ends, and cannot lay out a fragment
    /// that starts above the top of a container with boxes in it: every line after its first
    /// goes to the container's top, one over another. A box ends where it starts because its
    /// bottom margin takes back its lines' height, but TextKit reads the margins before it
    /// lays the lines out and adds them to the height in the container's coordinates, so the
    /// sum comes to nothing only within rounding: a box that opens a page or a section could
    /// end a few 1e-14 above the top. A frame that ends less than `roundingLimit` above the top
    /// ends at it; one that ends further above it is left as it is.
    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        let end = frame.origin.y + frame.size.height
        if end < 0, end > -Self.roundingLimit { frame.size.height = -frame.origin.y }
        return frame
    }
}

final class ReaderBoxLayoutManager: NSTextLayoutManager, NSTextLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = nil
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func configureGeometry() {
        let container = textContainer as? ReaderTextContainer
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
        }
        return fragment
    }

    override func textLayoutFragment(for position: CGPoint) -> NSTextLayoutFragment? {
        guard let container = textContainer as? ReaderTextContainer, let page = container.boxPage,
              let content = textContentManager else { return super.textLayoutFragment(for: position) }
        let global = position.offsetBy(dx: 0, dy: page.origin)
        for region in page.geometry.regions where region.frame.contains(global) {
            let offset = max(0, region.range.location - page.offset)
            guard offset < content.offset(from: content.documentRange.location, to: content.documentRange.endLocation),
                  let location = content.location(content.documentRange.location, offsetBy: offset) else { continue }
            var found: NSTextLayoutFragment?
            enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location) + page.offset
                guard start < region.range.upperBound else { return false }
                let frame = fragment.layoutFragmentFrame
                if fragment.textLineFragments.contains(where: { $0.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY).contains(position) }) {
                    found = fragment; return false
                }
                return true
            }
            if let found { return found }
        }
        return super.textLayoutFragment(for: position)
    }

    override func lineFragmentRange(for point: CGPoint, inContainerAt location: any NSTextLocation) -> NSTextRange? {
        guard (textContainer as? ReaderTextContainer)?.hasNonlinearGeometry == true else {
            return super.lineFragmentRange(for: point, inContainerAt: location)
        }
        guard let fragment = textLayoutFragment(for: point), let content = textContentManager else { return nil }
        let frame = fragment.layoutFragmentFrame
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        let line = lines.first { $0.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY).contains(point) }
            ?? lines.min { abs(frame.minY + $0.typographicBounds.midY - point.y) < abs(frame.minY + $1.typographicBounds.midY - point.y) }
        guard let line, let start = content.location(fragment.rangeInElement.location, offsetBy: line.characterRange.location),
              let end = content.location(start, offsetBy: line.characterRange.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
