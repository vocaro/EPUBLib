import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Flex and grid alignment for the bounded subset the native layout honours.
///
/// TextKit lays a section out as one column of paragraphs, so alignment is expressed in what a
/// paragraph has: space above and below it, and its indents. A container's free block-axis space
/// (its `height` or `min-height` less its content) becomes paragraph spacing around and between
/// its items; an item narrower than the container is indented from both sides to its place.
/// Characters, runs and every other attribute are untouched, so text offsets, CFIs, selection
/// and search are the same with and without a book's alignment rules.
///
/// Supported: column flex containers, one-column grids and a row flex container with one item
/// (`ReaderAlignmentContainer.Layout`). Everything else stays in block flow in reading order.
/// A viewport-relative height resolves against the reading viewport: one column's page in
/// paginated flow, the visible area in continuous scroll. A box is never taller than that
/// viewport, so a box that opens a page stays on it.
enum ReaderAlignmentLayout {
    /// Where an item sits along a horizontal axis. `start` is where block flow already puts it.
    enum Side: Sendable { case start, center, end }

    /// The longest paragraph measured for shrink-to-fit; longer ones fill their line.
    static let maximumMeasuredParagraph = 2_048
    /// The longest container laid out to find its height; longer ones exceed any page.
    static let maximumMeasuredContainer = 60_000

    static func side(_ value: ComputedStyle.ItemAlignment, rightToLeft: Bool) -> Side {
        switch value {
        case .center: .center
        case .end: .end
        case .left: rightToLeft ? .end : .start
        case .right: rightToLeft ? .start : .end
        case .auto, .normal, .stretch, .start, .baseline: .start
        }
    }

    /// A row's only item along the row.
    static func side(_ value: ComputedStyle.ContentAlignment, reversed: Bool, rightToLeft: Bool) -> Side {
        switch value {
        case .center, .spaceAround, .spaceEvenly: .center
        case .flexEnd: reversed ? .start : .end
        case .normal, .stretch, .flexStart, .spaceBetween: reversed ? .end : .start
        case .start: .start
        case .end: .end
        case .left: rightToLeft ? .end : .start
        case .right: rightToLeft ? .start : .end
        }
    }

    /// Tags a built section's paragraphs with their alignment context.
    static func tag(_ string: NSMutableAttributedString, paragraphs: [(start: Int, item: ReaderAlignmentItem?)]) {
        let length = string.length
        for (index, paragraph) in paragraphs.enumerated() {
            guard let item = paragraph.item, item.isEffective else { continue }
            let end = index + 1 < paragraphs.count ? paragraphs[index + 1].start : length
            guard end > paragraph.start else { continue }
            string.addAttribute(.readerAlignment, value: ReaderAlignmentParagraph(item: item),
                                range: NSRange(location: paragraph.start, length: end - paragraph.start))
        }
    }

    /// `text` with its aligned containers resolved for `viewport`; `text` itself when it has
    /// none. Always starts from source formatting, so repeated resolution never compounds.
    static func applying(to text: NSAttributedString, viewport: CGSize) -> NSAttributedString {
        guard text.length > 0, viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0,
              viewport.height > 0 else { return text }
        var entries: [Entry] = []
        text.enumerateAttribute(.readerAlignment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let paragraph = value as? ReaderAlignmentParagraph { entries.append(Entry(range: range, paragraph: paragraph)) }
        }
        guard !entries.isEmpty else { return text }
        var pass = Pass(source: text, viewport: viewport, entries: entries)
        return pass.run()
    }

    /// The space an aligned box keeps above its first line, when the paragraph starting at
    /// `location` is one, in resolved text: the alignment's own and the box's top padding.
    static func lead(in text: NSAttributedString, at location: Int) -> CGFloat {
        guard location >= 0, location < text.length,
              let value = text.attribute(.readerAlignmentLead, at: location, effectiveRange: nil) as? NSNumber else { return 0 }
        return CGFloat(value.doubleValue)
    }

    /// The paragraphs of each aligned box around `location`, outermost first, in source or
    /// resolved text. A box here is a supported container with a `height` or `min-height`: one
    /// that composes its content in a space of its own. Its paragraphs are the consecutive ones
    /// tagged with it (`.readerAlignment`), so no attribute marks its extent, and it ends with
    /// its section: the break between two sections of a book carries no tag. A box longer than
    /// `maximumMeasuredContainer` exceeds any screen and is left out.
    static func boxes(in text: NSAttributedString, around location: Int) -> [NSRange] {
        guard location >= 0, text.length > 0 else { return [] }
        let limit = maximumMeasuredContainer
        /// The paragraph tagged at `index`, no further than the limit either way, and the boxes
        /// it is in.
        func tag(at index: Int) -> (boxes: [ReaderAlignmentContainer], range: NSRange)? {
            let lower = max(0, index - limit - 1), upper = min(text.length, index + limit + 1)
            var range = NSRange()
            guard let paragraph = text.attribute(.readerAlignment, at: index, longestEffectiveRange: &range,
                                                 in: NSRange(location: lower, length: upper - lower)) as? ReaderAlignmentParagraph
            else { return nil }
            var boxes: [ReaderAlignmentContainer] = []
            var item: ReaderAlignmentItem? = paragraph.item
            while let current = item {
                if current.container.layout != .block, current.container.hasHeight { boxes.append(current.container) }
                item = current.container.parentItem
            }
            return (boxes.reversed(), range)
        }
        // A section's end is on the break after its last paragraph, which only the paragraph's
        // start shows to be its own.
        let own = (text.string as NSString).paragraphRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        guard let first = tag(at: own.location) else { return [] }
        return first.boxes.compactMap { container in
            var box = first.range
            while box.length <= limit, box.location > 0, let previous = tag(at: box.location - 1),
                  previous.boxes.contains(where: { $0 === container }) { box = NSUnionRange(previous.range, box) }
            while box.length <= limit, box.upperBound < text.length, let next = tag(at: box.upperBound),
                  next.boxes.contains(where: { $0 === container }) { box = NSUnionRange(box, next.range) }
            return box.length <= limit ? box : nil
        }
    }

    private struct Entry {
        /// A whole paragraph, with its terminator.
        let range: NSRange
        let paragraph: ReaderAlignmentParagraph
    }

    /// One item's paragraphs, as entry indices.
    private struct Run {
        let item: ReaderAlignmentItem
        let first: Int
        var last: Int
    }

    /// A supported container's paragraphs.
    private struct Group {
        let container: ReaderAlignmentContainer
        /// Supported containers around this one.
        let level: Int
        let first: Int
        var last: Int
        var items: [Run]
    }

    private struct Pass {
        let source: NSAttributedString
        let viewport: CGSize
        let entries: [Entry]
        private var groups: [Group] = []
        /// Groups whose container is itself an item, by that item.
        private var nested: [ObjectIdentifier: Int] = [:]
        private var result: NSMutableAttributedString?
        /// Space put above an entry's paragraph and after it as a container's trailing space:
        /// both lie outside the lines of the containers that start or end there.
        private var leads: [Int: CGFloat] = [:]
        private var trails: [Int: CGFloat] = [:]
        private var measurements = 4_000

        init(source: NSAttributedString, viewport: CGSize, entries: [Entry]) {
            self.source = source; self.viewport = viewport; self.entries = entries
            var indices: [ObjectIdentifier: Int] = [:]
            for (index, entry) in entries.enumerated() {
                var chain: [ReaderAlignmentItem] = []
                var item: ReaderAlignmentItem? = entry.paragraph.item
                while let current = item {
                    if current.container.layout != .block { chain.append(current) }
                    item = current.container.parentItem
                }
                for (level, item) in chain.reversed().enumerated() {
                    let key = ObjectIdentifier(item.container)
                    if let group = indices[key] {
                        groups[group].last = index
                        if let last = groups[group].items.indices.last, groups[group].items[last].item === item {
                            groups[group].items[last].last = index
                        } else {
                            groups[group].items.append(Run(item: item, first: index, last: index))
                        }
                    } else {
                        indices[key] = groups.count
                        if let own = item.container.ownItem { nested[ObjectIdentifier(own)] = groups.count }
                        groups.append(Group(container: item.container, level: level, first: index, last: index,
                                            items: [Run(item: item, first: index, last: index)]))
                    }
                }
            }
        }

        mutating func run() -> NSAttributedString {
            // Widths from the outside in: an item's place decides the column of what it holds.
            for index in groups.indices.sorted(by: { groups[$0].level < groups[$1].level }) { alignAcross(groups[index]) }
            // Heights from the inside out: a container's content includes its items' own boxes.
            for index in groups.indices.sorted(by: { groups[$0].level > groups[$1].level }) { alignAlong(index) }
            // Never the source itself: a text view keeps what it last resolved, so text whose
            // alignment no longer moves anything (its content outgrew its box at a new size)
            // must still replace the spacing it was given before.
            guard let result else { return NSMutableAttributedString(attributedString: source) }
            for (index, lead) in leads where lead > 0.01 {
                // With the top padding and border of the boxes that start here: all of it is the
                // boxes' own, between their top edge and their first line.
                let edges = groups.reduce(CGFloat(0)) { $0 + ($1.first == index ? topEdge($1.container) : 0) }
                result.addAttribute(.readerAlignmentLead, value: NSNumber(value: Double(lead + edges)),
                                    range: NSRange(location: entries[index].range.location, length: 1))
            }
            return result
        }

        private func topEdge(_ container: ReaderAlignmentContainer) -> CGFloat {
            max(0, ReaderParagraphEdges.resolve(container.style.padding.top, reference: viewport.width, viewport: viewport))
                + ReaderParagraphEdges.border(container.style.border.top)
        }

        // MARK: Paragraph styles

        private var current: NSAttributedString { result ?? source }

        private func style(at location: Int) -> NSParagraphStyle {
            current.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle ?? .default
        }

        private mutating func update(_ range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
            let style = style(at: range.location).mutableCopy() as! NSMutableParagraphStyle
            change(style)
            if result == nil { result = NSMutableAttributedString(attributedString: source) }
            result?.addAttribute(.paragraphStyle, value: style, range: range)
        }

        /// A paragraph's line box, as insets from the column's edges.
        private func insets(_ index: Int) -> (left: CGFloat, right: CGFloat) {
            let style = style(at: entries[index].range.location)
            let head = max(0, min(style.headIndent, style.firstLineHeadIndent))
            let tail = style.tailIndent <= 0 ? -style.tailIndent : max(0, viewport.width - style.tailIndent)
            return style.baseWritingDirection == .rightToLeft ? (tail, head) : (head, tail)
        }

        private mutating func shift(_ index: Int, left: CGFloat, right: CGFloat) {
            update(entries[index].range) { style in
                let rtl = style.baseWritingDirection == .rightToLeft
                let head = rtl ? right : left, tail = rtl ? left : right
                style.headIndent += head
                style.firstLineHeadIndent += head
                style.tailIndent = style.tailIndent <= 0 ? style.tailIndent - tail : max(1, style.tailIndent - tail)
                if head != 0, !style.tabStops.isEmpty {
                    style.tabStops = style.tabStops.map {
                        NSTextTab(textAlignment: $0.alignment, location: $0.location + head, options: $0.options)
                    }
                }
            }
        }

        private func opensPage(_ location: Int) -> Bool {
            location == 0 || current.attribute(.readerPageBreakBefore, at: location, effectiveRange: nil) as? Bool == true
        }

        /// Space above an entry's paragraph. The builder keeps the gap between two paragraphs on
        /// the earlier one, and on the later one only at the text's start or a forced break.
        private mutating func addLead(_ index: Int, _ amount: CGFloat) {
            guard amount > 0 else { return }
            leads[index, default: 0] += amount
            let range = entries[index].range
            if opensPage(range.location) {
                update(range) { $0.paragraphSpacingBefore += amount }
                return
            }
            let previous = (source.string as NSString).paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            if current.attribute(.readerFlowBox, at: previous.location, effectiveRange: nil) != nil {
                // A float's or positioned box's formatting is rebuilt from its source when its
                // width resolves, so the space cannot rest on it.
                update(range) { $0.paragraphSpacingBefore += amount }
            } else {
                update(previous) { $0.paragraphSpacing += amount }
            }
        }

        private mutating func addSpace(after index: Int, _ amount: CGFloat, trailing: Bool = false) {
            guard amount > 0 else { return }
            if trailing { trails[index, default: 0] += amount }
            update(entries[index].range) { $0.paragraphSpacing += amount }
        }

        // MARK: Across the line

        private func side(of item: ReaderAlignmentItem, in container: ReaderAlignmentContainer) -> Side {
            let rtl = container.isRightToLeft
            let alignment = container.style.boxAlignment
            guard let style = item.style else { return container.containerSide }
            // Auto margins take an item's free space before any alignment does.
            switch (style.margin.left == .auto, style.margin.right == .auto) {
            case (true, true):
                // The builder already centres a block of percentage width between auto margins.
                switch (style.width, style.maxWidth) {
                case (.percent, _), (.auto, .percent): return .start
                default: return .center
                }
            case (true, false): return rtl ? .start : .end
            case (false, true): return rtl ? .end : .start
            default: break
            }
            switch container.layout {
            case .stack:
                let own = alignment.isGrid ? style.boxAlignment.justifySelf : style.boxAlignment.alignSelf
                return own == .auto ? container.containerSide : ReaderAlignmentLayout.side(own, rightToLeft: rtl)
            case .single:
                return style.boxAlignment.grow > 0 ? .start : container.containerSide
            case .block:
                return .start
            }
        }

        /// Shrinks each aligned item to its content and puts it at its side of the container.
        private mutating func alignAcross(_ group: Group) {
            let container = group.container
            let sides = group.items.map { side(of: $0.item, in: container) }
            guard sides.contains(where: { $0 != .start }) else { return }
            // The container's content box: the tightest column holding all of its paragraphs.
            var left = CGFloat.greatestFiniteMagnitude, right = CGFloat.greatestFiniteMagnitude
            for index in group.first...group.last {
                let inset = insets(index)
                left = min(left, inset.left); right = min(right, inset.right)
            }
            let available = viewport.width - left - right
            guard available > 1 else { return }
            for (run, side) in zip(group.items, sides) where side != .start {
                guard let outer = outerWidth(of: run, left: left, right: right, available: available) else { continue }
                let free = available - outer
                guard free > 0.5 else { continue }
                let atRight = (side == .end) != container.isRightToLeft
                let shifts: (left: CGFloat, right: CGFloat) = side == .center ? (free / 2, free / 2) : atRight ? (free, 0) : (0, free)
                for index in run.first...run.last { shift(index, left: shifts.left, right: shifts.right) }
            }
        }

        /// An item's fit-content width with its own margins, border and padding; nil when its
        /// content fills the line whatever its width.
        private mutating func outerWidth(of run: Run, left: CGFloat, right: CGFloat, available: CGFloat) -> CGFloat? {
            var need: CGFloat = 0, leading = CGFloat.greatestFiniteMagnitude, trailing = CGFloat.greatestFiniteMagnitude
            var isNatural = true
            for index in run.first...run.last {
                let inset = insets(index)
                let before = inset.left - left, after = inset.right - right
                leading = min(leading, before); trailing = min(trailing, after)
                if isNatural, let width = naturalWidth(index) { need = max(need, before + width + after) } else { isNatural = false }
            }
            let edges = leading + trailing
            func resolve(_ length: ComputedStyle.Length?) -> CGFloat? {
                guard let value = length?.resolve(reference: available, viewport: viewport), value.isFinite else { return nil }
                return max(0, value)
            }
            var inner: CGFloat
            if let width = resolve(run.item.style?.width) {
                inner = width
            } else if isNatural {
                // A point of slack: TextKit and string drawing round a line's width differently.
                inner = need - edges + 1
            } else {
                return nil
            }
            if let maximum = resolve(run.item.style?.maxWidth) { inner = min(inner, maximum) }
            if let minimum = resolve(run.item.style?.minWidth) { inner = max(inner, minimum) }
            return min(available, max(1, inner) + edges)
        }

        /// A paragraph's unwrapped width from the edge of its line box.
        private mutating func naturalWidth(_ index: Int) -> CGFloat? {
            guard measurements > 0 else { return nil }
            measurements -= 1
            let entry = entries[index], text = current
            guard let natural = entry.paragraph.natural({ ReaderAlignmentLayout.measure(text, paragraph: entry.range) }) else { return nil }
            let style = style(at: entry.range.location)
            let edge = min(style.headIndent, style.firstLineHeadIndent)
            let start = natural.hasLineBreaks ? max(style.headIndent, style.firstLineHeadIndent) : style.firstLineHeadIndent
            return start - edge + natural.width
        }

        // MARK: Down the page

        /// The container's content-box height when its `height` or `min-height` is definite.
        private func targetHeight(_ container: ReaderAlignmentContainer) -> CGFloat? {
            let style = container.style, exact = style.boxAlignment
            func definite(_ length: ComputedStyle.Length, _ mixed: ComputedStyle.MixedLength?) -> CGFloat? {
                if let mixed {
                    // `calc(98vh - 3em)`: the sum itself, not its one-unit approximation.
                    var value = mixed.points + mixed.viewportWidth * viewport.width / 100 + mixed.viewportHeight * viewport.height / 100
                    if mixed.percent != 0 {
                        guard let outer = container.containing?.resolve(viewport: viewport) else { return nil }
                        value += mixed.percent * outer / 100
                    }
                    return value.isFinite ? max(0, value) : nil
                }
                switch length {
                case .auto: return nil
                case .percent(let value): return container.containing?.resolve(viewport: viewport).map { $0 * value / 100 }
                default:
                    guard let value = length.resolve(reference: 0, viewport: viewport), value.isFinite else { return nil }
                    return max(0, value)
                }
            }
            let height = definite(style.height, exact.height), minimum = definite(style.minHeight, exact.minHeight)
            guard height != nil || minimum != nil else { return nil }
            var target = height ?? 0
            if height != nil, let maximum = definite(style.maxHeight, exact.maxHeight) { target = min(target, maximum) }
            if let minimum { target = max(target, minimum) }
            let edges = ReaderParagraphEdges.resolve(style.padding.top, reference: viewport.width, viewport: viewport)
                + ReaderParagraphEdges.resolve(style.padding.bottom, reference: viewport.width, viewport: viewport)
                + ReaderParagraphEdges.border(style.border.top) + ReaderParagraphEdges.border(style.border.bottom)
            if style.boxAlignment.isBorderBox { target -= edges }
            // One viewport at most: a page in paginated flow.
            target = min(target, viewport.height - edges)
            return target > 0 ? target : nil
        }

        /// From the first line's top to the last line's bottom at the live width; nil once the
        /// content is taller than `limit`, which leaves nothing to distribute.
        private func contentHeight(_ group: Group, limit: CGFloat) -> CGFloat? {
            let start = entries[group.first].range.location
            let range = NSRange(location: start, length: entries[group.last].range.upperBound - start)
            guard range.length <= ReaderAlignmentLayout.maximumMeasuredContainer else { return nil }
            let measured = NSMutableAttributedString(attributedString: current.attributedSubstring(from: range))
            // A break after the last line would add that paragraph's spacing below it.
            while measured.length > 0, ReaderAlignmentLayout.isParagraphBreak((measured.string as NSString).character(at: measured.length - 1)) {
                measured.deleteCharacters(in: NSRange(location: measured.length - 1, length: 1))
            }
            guard measured.length > 0 else { return 0 }
            let storage = NSTextContentStorage()
            let manager = NSTextLayoutManager()
            storage.addTextLayoutManager(manager)
            let container = ReaderTextContainer(size: CGSize(width: viewport.width, height: 0))
            container.lineFragmentPadding = 0
            container.viewportSize = viewport
            container.paragraphText = measured
            manager.textContainer = container
            storage.attributedString = measured
            var top: CGFloat?, bottom: CGFloat = 0, exceeds = false
            manager.enumerateTextLayoutFragments(from: storage.documentRange.location, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame
                for line in fragment.textLineFragments where line.characterRange.length > 0 {
                    let bounds = line.typographicBounds
                    if top == nil { top = frame.minY + bounds.minY }
                    bottom = max(bottom, frame.minY + bounds.maxY)
                }
                if bottom - (top ?? 0) > limit + 0.5 { exceeds = true }
                return !exceeds
            }
            return exceeds ? nil : max(0, bottom - (top ?? 0))
        }

        private func margin(_ length: ComputedStyle.Length?) -> CGFloat {
            guard let length else { return 0 }
            return max(0, ReaderParagraphEdges.resolve(length, reference: viewport.width, viewport: viewport))
        }

        /// Adds a container's gaps, then shares out the block-axis space its content leaves.
        private mutating func alignAlong(_ index: Int) {
            let group = groups[index], container = group.container
            if container.layout == .stack, group.items.count > 1,
               let gap = container.style.boxAlignment.rowGap.resolve(reference: 0, viewport: viewport), gap.isFinite, gap > 0 {
                for run in group.items.dropLast() { addSpace(after: run.last, min(gap, viewport.height)) }
            }
            guard let target = targetHeight(container), let lines = contentHeight(group, limit: target) else { return }
            // Space nested containers put outside their lines, and the outer items' own margins,
            // are part of this container's content.
            let content = lines + (leads[group.first] ?? 0) + (trails[group.last] ?? 0)
                + margin(group.items.first?.item.style?.margin.top) + margin(group.items.last?.item.style?.margin.bottom)
            var free = target - content
            let location = entries[group.first].range.location
            if opensPage(location) {
                // What is already above the box (margins and padding) must leave it room on the page.
                let above = max(0, style(at: location).paragraphSpacingBefore - (leads[group.first] ?? 0))
                free = min(free, viewport.height - above - content)
            }
            guard free > 0.5 else { return }
            distribute(free, in: index, depth: 0)
        }

        private mutating func distribute(_ free: CGFloat, in index: Int, depth: Int) {
            let group = groups[index], container = group.container, alignment = container.style.boxAlignment
            let count = group.items.count
            guard count > 0 else { return }
            var before = [CGFloat](repeating: 0, count: count), after = before, within = before
            func itemStyle(_ item: Int) -> ComputedStyle? { group.items[item].item.style }
            func hasAutoMargin(_ item: Int) -> (top: Bool, bottom: Bool) {
                (itemStyle(item)?.margin.top == .auto, itemStyle(item)?.margin.bottom == .auto)
            }
            /// Space an item has to itself: its auto margins take it, else its own alignment.
            func place(_ item: Int, _ space: CGFloat) {
                let own = itemStyle(item)?.boxAlignment.alignSelf ?? .auto
                switch hasAutoMargin(item) {
                case (true, true): before[item] += space / 2; after[item] += space / 2
                case (true, false): before[item] += space
                case (false, true): after[item] += space
                default:
                    switch own == .auto ? alignment.alignItems : own {
                    case .center: before[item] += space / 2; after[item] += space / 2
                    case .end: before[item] += space
                    case .auto, .normal, .stretch: within[item] += space
                    case .start, .left, .right, .baseline: after[item] += space
                    }
                }
            }
            /// Space shared between the items as packed lines or tracks.
            func pack(_ value: ComputedStyle.ContentAlignment, reversed: Bool, _ space: CGFloat) {
                switch value {
                case .center: before[0] += space / 2; after[count - 1] += space / 2
                case .end: before[0] += space
                case .flexEnd: if reversed { after[count - 1] += space } else { before[0] += space }
                case .normal, .stretch, .flexStart: if reversed { before[0] += space } else { after[count - 1] += space }
                case .start, .left, .right: after[count - 1] += space
                case .spaceBetween:
                    if count > 1 { for item in 0..<(count - 1) { after[item] += space / CGFloat(count - 1) } }
                    else if reversed { before[0] += space } else { after[0] += space }
                case .spaceAround:
                    for item in 0..<count { before[item] += space / CGFloat(2 * count); after[item] += space / CGFloat(2 * count) }
                case .spaceEvenly:
                    before[0] += space / CGFloat(count + 1)
                    for item in 0..<count { after[item] += space / CGFloat(count + 1) }
                }
            }
            switch container.layout {
            case .block:
                return
            case .single:
                place(0, free)
            case .stack where alignment.isGrid:
                // Auto rows stretch to share the space; packed rows leave it around them.
                if alignment.alignContent == .normal || alignment.alignContent == .stretch {
                    for item in 0..<count { place(item, free / CGFloat(count)) }
                } else {
                    pack(alignment.alignContent, reversed: false, free)
                }
            case .stack:
                var remaining = free
                let grows = (0..<count).map { max(0, itemStyle($0)?.boxAlignment.grow ?? 0) }
                let growth = grows.reduce(0, +)
                if growth > 0 {
                    let used = growth >= 1 ? remaining : remaining * growth
                    for item in 0..<count { within[item] += used * grows[item] / growth }
                    remaining -= used
                }
                let margins = (0..<count).map(hasAutoMargin)
                let autos = margins.reduce(0) { $0 + ($1.top ? 1 : 0) + ($1.bottom ? 1 : 0) }
                if remaining > 0.01, autos > 0 {
                    for item in 0..<count {
                        if margins[item].top { before[item] += remaining / CGFloat(autos) }
                        if margins[item].bottom { after[item] += remaining / CGFloat(autos) }
                    }
                    remaining = 0
                }
                if remaining > 0.01 { pack(alignment.justifyContent, reversed: alignment.direction.isReversed, remaining) }
            }
            for item in 0..<count where within[item] > 0 {
                // A stretched or grown item that is itself a container aligns inside its new
                // height; any other keeps its content at its top.
                let run = group.items[item]
                if depth < ReaderAlignmentContainer.maximumDepth, let inner = nested[ObjectIdentifier(run.item)],
                   groups[inner].first == run.first, groups[inner].last == run.last {
                    distribute(within[item], in: inner, depth: depth + 1)
                } else {
                    after[item] += within[item]
                }
            }
            addLead(group.first, before[0])
            for item in 0..<(count - 1) { addSpace(after: group.items[item].last, after[item] + before[item + 1]) }
            addSpace(after: group.last, after[count - 1], trailing: true)
        }
    }

    static func isParagraphBreak(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x0D || unit == 0x2029 }

    /// A paragraph's max-content width from its first line's start, unwrapped, as string
    /// drawing lays it out without indents. nil for a paragraph holding attachments (they size
    /// themselves against the line) or too long to be narrower than a line.
    static func measure(_ text: NSAttributedString, paragraph range: NSRange) -> ReaderAlignmentParagraph.Natural? {
        let characters = text.string as NSString
        var length = range.length
        while length > 0, isParagraphBreak(characters.character(at: range.location + length - 1)) { length -= 1 }
        guard length > 0 else { return .init(width: 0, hasLineBreaks: false) }
        guard length <= maximumMeasuredParagraph else { return nil }
        let body = NSRange(location: range.location, length: length)
        var hasAttachment = false
        text.enumerateAttribute(.attachment, in: body) { value, _, stop in
            if value != nil { hasAttachment = true; stop.pointee = true }
        }
        guard !hasAttachment else { return nil }
        let line = NSMutableAttributedString(attributedString: text.attributedSubstring(from: body))
        let original = line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle ?? .default
        let style = original.mutableCopy() as! NSMutableParagraphStyle
        // Tab stops (a list marker's) are measured from the first line's start.
        let origin = original.firstLineHeadIndent
        style.firstLineHeadIndent = 0; style.headIndent = 0; style.tailIndent = 0
        style.paragraphSpacing = 0; style.paragraphSpacingBefore = 0
        style.tabStops = original.tabStops.map {
            NSTextTab(textAlignment: $0.alignment, location: max(0, $0.location - origin), options: $0.options)
        }
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        let bounds = line.boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin], context: nil)
        guard bounds.width.isFinite else { return nil }
        let hasLineBreaks = characters.range(of: "\u{2028}", options: [], range: body).location != NSNotFound
        return .init(width: bounds.width, hasLineBreaks: hasLineBreaks)
    }
}
