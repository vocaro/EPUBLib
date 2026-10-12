import CoreGraphics
import Foundation

extension ReaderTextView {
    /// The frame continuous scroll rests a shown position by: its line, or, when the position
    /// starts an aligned flex or grid box, from the box's top edge through its first line.
    ///
    /// A box's free space is laid out as paragraph spacing above its first line, so resting the
    /// line itself at the top of the visible area would scroll half of the box away and show
    /// its content at the top, not where the book put it.
    func anchorFrame(of line: CGRect, at location: Int) -> CGRect {
        guard let storage = contentStorage.textStorage else { return line }
        let lead = ReaderAlignmentLayout.lead(in: storage, at: location)
        guard lead > 0 else { return line }
        return CGRect(x: line.minX, y: max(0, line.minY - lead), width: line.width, height: line.maxY - max(0, line.minY - lead))
    }

    /// The location continuous scroll rests a shown position by: `location`, or, when it is
    /// inside an aligned box no taller than `height`, the start of the largest such box.
    ///
    /// The box is then on screen whole, as it was composed, whichever of its lines the position
    /// is on: a page turned back to leaves the position at its section's end, the last line of
    /// a one-page dedication. A taller box keeps the position's own line, which its top edge
    /// could put off screen.
    func restLocation(for location: Int, fitting height: CGFloat) -> Int {
        guard height > 0, let storage = contentStorage.textStorage else { return location }
        return ReaderAlignmentLayout.boxes(in: storage, around: location).first { fits($0, in: height) }?.location ?? location
    }

    /// Whether a box's paragraphs, from its top edge to the bottom of its last line, are no
    /// taller than `height`. Lays out from the box's start and stops at the first line past
    /// `height`, so a box of any length costs a screen of layout at most.
    private func fits(_ box: NSRange, in height: CGFloat) -> Bool {
        guard let start = textRange(for: NSRange(location: box.location, length: 0))?.location else { return false }
        var top: CGFloat?, isWithin = true
        readerLayoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            guard offset(of: fragment.rangeInElement.location) < box.upperBound else { return false }
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                let bounds = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                let edge = top ?? anchorFrame(of: bounds, at: box.location).minY
                top = edge
                // A point over is a rounding of a box exactly the visible area's height.
                if bounds.maxY - edge > height + 1 { isWithin = false }
            }
            return isWithin
        }
        return isWithin && top != nil
    }
}
