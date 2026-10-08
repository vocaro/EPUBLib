import CoreGraphics

/// Column geometry for both flows, after foliate-js's paginator defaults (doc/native-viewer.md,
/// "Layout"). Pure functions of the page rectangle, so they never depend on device idiom,
/// orientation or screen.
enum ReaderCanvasGeometry {
    static let outerMarginFraction: CGFloat = 0.035
    static let maximumColumnWidth: CGFloat = 720
    /// foliate's `g / (1 − g)` with g = 7%: its gap is a share of a container already narrowed
    /// by the outer margins, so the gap between columns reads as wide as the margins.
    static let gapFraction: CGFloat = 0.07 / 0.93
    static let verticalMargin: CGFloat = 48

    /// A paginated spread: one column per page slice shown, all the same size.
    struct Spread: Equatable {
        /// Column frames in reading order: the first slice's column first, which is the rightmost
        /// one in a right-to-left book.
        var columns: [CGRect]
        var columnSize: CGSize { columns.first?.size ?? .zero }
    }

    /// The columns for `page` (the canvas less its safe area). With a usable `division` the
    /// spread always has two columns and its gutter is the division plus half a gap each side.
    static func spread(in page: CGRect, division: CGRect?, isRightToLeft: Bool) -> Spread {
        let top = page.minY + verticalMargin
        let height = max(0, page.height - 2 * verticalMargin)
        let margin = outerMarginFraction * page.width
        let gap = gapFraction * contentWidth(page.width, columns: 2)
        var columns: [CGRect]
        if let division = usableDivision(division, in: page) {
            let left = division.minX - gap / 2 - (page.minX + margin)
            let right = page.maxX - margin - (division.maxX + gap / 2)
            let width = max(0, min(maximumColumnWidth, left, right))
            columns = [CGRect(x: division.minX - gap / 2 - width, y: top, width: width, height: height),
                       CGRect(x: division.maxX + gap / 2, y: top, width: width, height: height)]
        } else if columnCount(for: page.size) == 2 {
            let area = contentWidth(page.width, columns: 2)
            let width = (area - gap) / 2
            let minX = page.midX - area / 2
            columns = [CGRect(x: minX, y: top, width: width, height: height),
                       CGRect(x: minX + width + gap, y: top, width: width, height: height)]
        } else {
            let width = contentWidth(page.width, columns: 1)
            columns = [CGRect(x: page.midX - width / 2, y: top, width: width, height: height)]
        }
        if isRightToLeft { columns.reverse() }
        return Spread(columns: columns)
    }

    /// Two columns on a landscape page whose content width (93% of its width) exceeds one column.
    static func columnCount(for size: CGSize) -> Int {
        size.width > size.height && size.width * (1 - 2 * outerMarginFraction) > maximumColumnWidth ? 2 : 1
    }

    /// The continuous-scroll column within `bounds`' horizontal extent: at most 720 wide and
    /// centred, or centred on the wider side of a division.
    static func scrollColumn(in bounds: CGRect, division: CGRect?) -> (minX: CGFloat, width: CGFloat) {
        let margin = outerMarginFraction * bounds.width
        var minX = bounds.minX + margin, maxX = bounds.maxX - margin
        if let division = usableDivision(division, in: bounds) {
            let gap = gapFraction * contentWidth(bounds.width, columns: 2)
            if division.minX - bounds.minX >= bounds.maxX - division.maxX {
                maxX = division.minX - gap / 2
            } else {
                minX = division.maxX + gap / 2
            }
        }
        let width = max(0, min(maximumColumnWidth, maxX - minX))
        return ((minX + maxX - width) / 2, width)
    }

    /// The width the columns and gaps may use: 93% of the page, capped where the columns reach
    /// their maximum width (the content area is then centred).
    private static func contentWidth(_ width: CGFloat, columns: Int) -> CGFloat {
        let count = CGFloat(columns)
        let cap = count * maximumColumnWidth / (1 - (count - 1) * gapFraction)
        return max(0, min(width * (1 - 2 * outerMarginFraction), cap))
    }

    /// A division that splits the page into two non-empty sides; nil otherwise.
    private static func usableDivision(_ division: CGRect?, in page: CGRect) -> CGRect? {
        guard let division, !division.isNull, division.minX > page.minX, division.maxX < page.maxX
        else { return nil }
        return division
    }
}
