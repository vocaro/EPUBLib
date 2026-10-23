import CoreGraphics
import EPUBCore

/// A section the canvas shows as one fixed-layout page (`FixedLayoutPage`), and how it pairs
/// with the pages beside it in a spread.
struct ReaderFixedPage: Equatable, Sendable {
    /// The page's declared size, in CSS pixels; nil while its section is not built.
    var size: CGSize?
    /// The side of a spread its itemref puts it on.
    var side: EPUBPageSpread?
    /// When it may share a spread (`rendition:spread`).
    var spread: EPUBSpread
}

/// One spread of fixed-layout pages: the sections in its two slots in reading order, the first
/// slot the left one in a book read left to right and the right one in a book read right to
/// left. A page shown on its own stands across both.
struct ReaderFixedSpread: Equatable, Sendable {
    var first: Int?
    var second: Int?
    /// One page centered on the whole area rather than in its half: a center page, or one the
    /// spread setting keeps from sharing a spread at this size.
    var isAlone = false

    /// The sections shown, in reading order.
    var sections: [Int] { [first, second].compactMap { $0 } }

    /// How a book's fixed-layout pages pair into spreads, as foliate-js's `fixed-layout.js`
    /// paired them: from the first page of a run of linear pages, each page takes the next
    /// slot; a page that its itemref puts on the first slot's side begins a spread, one put on
    /// the second slot's side ends one, leaving the first slot empty when it would stand there,
    /// and a center page, or one that may not share a spread, stands alone. A section that flows
    /// ends a run, and a nonlinear page, reached by a link, is shown alone.
    struct Pairing {
        let count: Int
        /// The page a section is; nil for one that flows.
        let page: (Int) -> ReaderFixedPage?
        let isLinear: (Int) -> Bool
        /// Whether a page may share a spread at the canvas's size (`ReaderCanvasGeometry.showsFixedSpreads`).
        let pairs: (ReaderFixedPage) -> Bool
        let isRightToLeft: Bool

        /// The spread that shows `section`; nil when it is no page.
        func spread(containing section: Int) -> ReaderFixedSpread? {
            guard section >= 0, section < count, let page = page(section) else { return nil }
            guard isLinear(section), pairs(page) else { return ReaderFixedSpread(first: section, isAlone: true) }
            var start = section
            while let previous = linear(before: start), self.page(previous) != nil { start = previous }
            var next: Int? = start
            while let first = next, first <= section {
                let spread = self.spread(startingAt: first)
                if spread.sections.contains(section) { return spread }
                next = linear(after: spread.sections.max() ?? first)
            }
            return ReaderFixedSpread(first: section, isAlone: true)
        }

        private func spread(startingAt first: Int) -> ReaderFixedSpread {
            let leading: EPUBPageSpread = isRightToLeft ? .right : .left
            let trailing: EPUBPageSpread = isRightToLeft ? .left : .right
            guard let page = page(first), pairs(page), page.side != .center else { return ReaderFixedSpread(first: first, isAlone: true) }
            if page.side == trailing { return ReaderFixedSpread(first: nil, second: first) }
            if let next = linear(after: first), let partner = self.page(next), pairs(partner),
               partner.side != .center, partner.side != leading {
                return ReaderFixedSpread(first: first, second: next)
            }
            return ReaderFixedSpread(first: first, second: nil)
        }

        private func linear(before section: Int) -> Int? {
            stride(from: section - 1, through: 0, by: -1).first(where: isLinear)
        }

        private func linear(after section: Int) -> Int? {
            stride(from: section + 1, to: count, by: 1).first(where: isLinear)
        }
    }
}

extension ReaderCanvasGeometry {
    /// Where a fixed-layout spread's pages go in `page` (the canvas less its safe area): within
    /// the margins columns keep, each page of a pair as large as fits its half, the halves
    /// meeting at the middle or at a usable division, the left page against its half's right
    /// edge and the right page against its half's left edge, as a book's pages meet at its
    /// spine; a page alone as large as fits the whole area, centered, or on a division's wider
    /// side. Each page keeps its declared aspect and is centered vertically, and every frame is
    /// on whole points. `sizes` gives each shown section's declared size.
    static func fixedPageFrames(of spread: ReaderFixedSpread, sizes: [Int: CGSize], in page: CGRect, division: CGRect?,
                                isRightToLeft: Bool) -> [(section: Int, frame: CGRect)] {
        if spread.isAlone || fixedHalves(in: page, division: division) == nil {
            let area = fixedAloneArea(in: page, division: division)
            return spread.sections.compactMap { section in
                sizes[section].map { (section, fit($0, in: area, edge: nil)) }
            }
        }
        guard let halves = fixedHalves(in: page, division: division) else { return [] }
        let slots: [(section: Int?, half: CGRect, edge: CGRectEdge)] = isRightToLeft
            ? [(spread.first, halves.right, .minXEdge), (spread.second, halves.left, .maxXEdge)]
            : [(spread.first, halves.left, .maxXEdge), (spread.second, halves.right, .minXEdge)]
        return slots.compactMap { slot in
            guard let section = slot.section, let size = sizes[section] else { return nil }
            return (section, fit(size, in: slot.half, edge: slot.edge))
        }
    }

    /// Whether pages with this spread setting share a spread in `page`: never for `none`, always
    /// for `both`, and for `landscape` and `auto` in a landscape page or across a usable
    /// division. Never where a division leaves a side narrower than a readable column.
    static func showsFixedSpreads(_ setting: EPUBSpread, in page: CGRect, division: CGRect?) -> Bool {
        guard fixedHalves(in: page, division: division) != nil else { return false }
        switch setting {
        case .none: return false
        case .both: return true
        case .landscape, .auto: return page.width > page.height || usableDivision(division, in: page) != nil
        }
    }

    /// The area fixed-layout pages are fitted into: `page` within the outer and vertical margins.
    static func fixedArea(in page: CGRect) -> CGRect {
        let margin = outerMarginFraction * page.width
        return CGRect(x: page.minX + margin, y: page.minY + verticalMargin,
                      width: max(0, page.width - 2 * margin), height: max(0, page.height - 2 * verticalMargin))
    }

    /// The two halves of the fixed-layout area, parted at its middle or at a usable division;
    /// nil where the division leaves a side narrower than `minimumDivisionColumnWidth`.
    static func fixedHalves(in page: CGRect, division: CGRect?) -> (left: CGRect, right: CGRect)? {
        let area = fixedArea(in: page)
        if let division = usableDivision(division, in: page) {
            let left = CGRect(x: area.minX, y: area.minY, width: max(0, division.minX - area.minX), height: area.height)
            let right = CGRect(x: division.maxX, y: area.minY, width: max(0, area.maxX - division.maxX), height: area.height)
            return min(left.width, right.width) >= minimumDivisionColumnWidth ? (left, right) : nil
        }
        // Parted on a whole point, so that pages fitted against it meet there exactly.
        let middle = area.midX.rounded()
        return (CGRect(x: area.minX, y: area.minY, width: max(0, middle - area.minX), height: area.height),
                CGRect(x: middle, y: area.minY, width: max(0, area.maxX - middle), height: area.height))
    }

    /// Where a page shown alone goes: the whole fixed-layout area, or a usable division's wider
    /// side, as one column goes in continuous scroll.
    static func fixedAloneArea(in page: CGRect, division: CGRect?) -> CGRect {
        let area = fixedArea(in: page)
        guard let division = usableDivision(division, in: page) else { return area }
        let left = division.minX - area.minX, right = area.maxX - division.maxX
        return left >= right ? CGRect(x: area.minX, y: area.minY, width: max(0, left), height: area.height)
            : CGRect(x: division.maxX, y: area.minY, width: max(0, right), height: area.height)
    }

    /// `size` scaled to fit `area` with its aspect kept, on whole points, centered vertically and
    /// against `edge` (centered for nil).
    static func fit(_ size: CGSize, in area: CGRect, edge: CGRectEdge?) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else {
            return CGRect(x: area.midX.rounded(), y: area.midY.rounded(), width: 0, height: 0)
        }
        let scale = min(area.width / size.width, area.height / size.height)
        let width = max(1, (size.width * scale).rounded(.down)), height = max(1, (size.height * scale).rounded(.down))
        let x: CGFloat = switch edge {
        case .minXEdge: area.minX.rounded(.up)
        case .maxXEdge: (area.maxX - width).rounded(.down)
        default: (area.midX - width / 2).rounded()
        }
        return CGRect(x: x, y: (area.midY - height / 2).rounded(), width: width, height: height)
    }
}
