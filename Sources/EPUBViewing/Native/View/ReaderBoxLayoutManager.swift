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
}

final class ReaderBoxLayoutManager: NSTextLayoutManager, NSTextLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = nil
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func configureGeometry() {
        delegate = (textContainer as? ReaderTextContainer)?.boxPage != nil ? self : nil
    }

    func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in element: NSTextElement) -> NSTextLayoutFragment {
        guard let container = textContainer as? ReaderTextContainer, let page = container.boxPage,
              let content = textContentManager else { return NSTextLayoutFragment(textElement: element, range: nil) }
        let offset = content.offset(from: content.documentRange.location, to: location)
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
            let shift = paragraph.flowStart - page.origin
            fragment.topAdjustment += shift
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
