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
}
