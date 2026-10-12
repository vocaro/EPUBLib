import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// What the section builder records about flex and grid containers. Nothing here changes a
// section's characters: containers and items only tag paragraphs (`.readerAlignment`), and
// `ReaderAlignmentLayout` turns the tags into paragraph spacing and indents at the live column
// size. A section built with and without its alignment rules has the same text and text map.

/// An element's `height`, kept symbolic so a percentage resolves against its containing block
/// when the viewport is known. Elements with `height: auto` have none.
final class ReaderHeightScope: @unchecked Sendable {
    /// The initial containing block: the reading viewport.
    static let viewport = ReaderHeightScope(height: .viewportHeight(100), parent: nil)

    let height: ComputedStyle.Length
    let parent: ReaderHeightScope?

    init(height: ComputedStyle.Length, parent: ReaderHeightScope?) { self.height = height; self.parent = parent }

    /// A definite height in points, or nil (`auto`, or a percentage of an indefinite height).
    func resolve(viewport: CGSize) -> CGFloat? {
        var factor: CGFloat = 1
        var scope: ReaderHeightScope? = self
        while let current = scope {
            switch current.height {
            case .auto: return nil
            case .percent(let value): factor *= value / 100; scope = current.parent
            default:
                guard let value = current.height.resolve(reference: 0, viewport: viewport), value.isFinite else { return nil }
                return max(0, value * factor)
            }
        }
        return nil
    }
}

/// A flex or grid container the section builder met.
final class ReaderAlignmentContainer: @unchecked Sendable {
    enum Layout: Sendable {
        /// A column flex container or a one-column grid: items stack down the block axis.
        case stack
        /// A row flex container's only item.
        case single
        /// Anything else stays in block flow, in reading order.
        case block
    }

    static let maximumDepth = 4

    let style: ComputedStyle
    /// The item of an enclosing container that holds this one.
    let parentItem: ReaderAlignmentItem?
    /// This container as an item of the enclosing one, when it is its direct child.
    let ownItem: ReaderAlignmentItem?
    /// The containing block's height, for percentage heights.
    let containing: ReaderHeightScope?
    let depth: Int

    // Tallied while the builder walks the container; read once it has closed.
    fileprivate(set) var itemCount = 0
    fileprivate var anonymous: ReaderAlignmentItem?
    fileprivate var hasFlowBoxes = false
    fileprivate var hasReordering = false
    fileprivate var hasPlacement = false
    fileprivate var hasTooDeepNesting = false
    fileprivate var hasItemAlignment = false
    private(set) var layout = Layout.block
    /// The builder closed the container knowing it would lay out as blocks, or without a
    /// feature that changes where its items go.
    private(set) var isSimplified = false
    /// Whether layout has anything to do: a definite height, a gap or a cross-axis alignment.
    private(set) var hasEffect = false

    init(style: ComputedStyle, parentItem: ReaderAlignmentItem?, ownItem: ReaderAlignmentItem?,
         containing: ReaderHeightScope?) {
        self.style = style; self.parentItem = parentItem; self.ownItem = ownItem; self.containing = containing
        depth = (parentItem?.container.depth ?? 0) + 1
    }

    var isRightToLeft: Bool { style.direction == .rtl }
    /// The box has a height of its own to align within: a `height` or a `min-height`.
    var hasHeight: Bool { style.height != .auto || style.minHeight != .auto }

    fileprivate func anonymousItem() -> ReaderAlignmentItem {
        if let anonymous { return anonymous }
        let item = ReaderAlignmentItem(container: self, style: nil)
        anonymous = item
        return item
    }

    /// Decides the layout once every item is known.
    fileprivate func close() {
        let alignment = style.boxAlignment
        if alignment.isGrid {
            let columns = max(alignment.gridColumns, alignment.gridAreaColumns)
            if columns > 1 || hasPlacement || (alignment.gridFlowsInColumns && itemCount > 1) {
                layout = .block; isSimplified = true
            } else {
                layout = .stack
            }
        } else if alignment.direction.isColumn {
            if alignment.direction.isReversed, itemCount > 1 {
                layout = .block; isSimplified = true
            } else {
                layout = .stack
                // A wrapping column breaks into further columns when it overflows its height.
                if alignment.wraps, style.height != .auto || style.maxHeight != .auto { isSimplified = true }
            }
        } else if itemCount > 1 {
            layout = .block; isSimplified = true
        } else {
            layout = .single
        }
        if hasReordering, itemCount > 1 { isSimplified = true }
        if hasTooDeepNesting { isSimplified = true }
        guard layout != .block else { return }
        let hasGap = layout == .stack && itemCount > 1 && alignment.rowGap != .zero
        hasEffect = hasHeight || hasGap || hasItemAlignment || containerSide != .start
        // Floats and positioned boxes have their own geometry, which alignment cannot measure.
        if hasFlowBoxes {
            if hasEffect { isSimplified = true }
            layout = .block; hasEffect = false
        }
    }

    /// Where the container itself puts an item across the line: `start` leaves it filling it.
    var containerSide: ReaderAlignmentLayout.Side {
        let alignment = style.boxAlignment
        switch layout {
        case .stack:
            return ReaderAlignmentLayout.side(alignment.isGrid ? alignment.justifyItems : alignment.alignItems,
                                              rightToLeft: isRightToLeft)
        case .single:
            return ReaderAlignmentLayout.side(alignment.justifyContent, reversed: alignment.direction.isReversed,
                                              rightToLeft: isRightToLeft)
        case .block:
            return .start
        }
    }
}

/// One item of a container: a child box, or a run of text directly inside the container.
final class ReaderAlignmentItem: @unchecked Sendable {
    let container: ReaderAlignmentContainer
    /// nil for an anonymous item.
    let style: ComputedStyle?
    private var hasContent = false

    init(container: ReaderAlignmentContainer, style: ComputedStyle?) { self.container = container; self.style = style }

    /// The item rendered a paragraph: only such items count, as an empty box takes no room.
    fileprivate func noteContent() {
        guard !hasContent else { return }
        hasContent = true
        container.itemCount += 1
        if let style {
            if style.boxAlignment.order != 0 { container.hasReordering = true }
            if style.boxAlignment.hasGridPlacement { container.hasPlacement = true }
            if style.margin.left == .auto || style.margin.right == .auto || style.boxAlignment.alignSelf != .auto
                || style.boxAlignment.justifySelf != .auto { container.hasItemAlignment = true }
        }
        container.parentItem?.noteContent()
    }

    /// This item or the one around it that is `container`'s, nil when it is not inside it.
    func inside(_ container: ReaderAlignmentContainer) -> ReaderAlignmentItem? {
        var item: ReaderAlignmentItem? = self
        while let current = item {
            if current.container === container { return current }
            item = current.container.parentItem
        }
        return nil
    }

    /// Whether any container around the item has something for layout to do.
    var isEffective: Bool {
        var item: ReaderAlignmentItem? = self
        while let current = item {
            if current.container.layout != .block, current.container.hasEffect { return true }
            item = current.container.parentItem
        }
        return false
    }
}

/// A block frame's place among flex and grid containers, kept with its paragraph formatting.
struct ReaderAlignmentFrame {
    /// The item this frame's paragraphs belong to.
    private var item: ReaderAlignmentItem?
    /// The frame is a container: its children and bare text are items.
    private var container: ReaderAlignmentContainer?
    private var heights: ReaderHeightScope?
    private var isEnabled = false
    /// Inside a float, positioned box or sized inline-block, which lays out by its own geometry.
    private var isInFlowBox = false

    /// Outside a section (table cells, notes): nothing is aligned.
    static let none = ReaderAlignmentFrame()
    /// A section's column.
    static var root: ReaderAlignmentFrame {
        var frame = ReaderAlignmentFrame()
        frame.isEnabled = true
        frame.heights = .viewport
        return frame
    }

    private init() {}

    /// A block box inside `parent`.
    init(style: ComputedStyle, parent: ReaderAlignmentFrame) {
        guard parent.isEnabled else { return }
        isEnabled = true
        heights = style.height == .auto ? nil : ReaderHeightScope(height: style.height, parent: parent.heights)
        guard !parent.isInFlowBox else {
            isInFlowBox = true
            item = parent.item
            return
        }
        guard !style.requiresFlowBox else {
            // A float or positioned box takes no part, and neither it nor the containers around
            // it lay out as block flow, which is all alignment can measure.
            isInFlowBox = true
            item = parent.container?.parentItem ?? parent.item
            var enclosing = parent.container ?? parent.item?.container
            while let current = enclosing { current.hasFlowBoxes = true; enclosing = current.parentItem?.container }
            return
        }
        var ownItem: ReaderAlignmentItem?
        if let outer = parent.container {
            ownItem = ReaderAlignmentItem(container: outer, style: style)
            outer.anonymous = nil
            item = ownItem
        } else {
            item = parent.item
        }
        guard style.blockifiesChildren else { return }
        if (item?.container.depth ?? 0) < ReaderAlignmentContainer.maximumDepth {
            container = ReaderAlignmentContainer(style: style, parentItem: item, ownItem: ownItem, containing: parent.heights)
        } else {
            item?.container.hasTooDeepNesting = true
        }
    }

    /// The item of a paragraph opened in this frame.
    func paragraphItem() -> ReaderAlignmentItem? {
        let item = container?.anonymousItem() ?? item
        item?.noteContent()
        return item
    }

    /// The containers around a paragraph in this frame, innermost first. A paragraph that takes
    /// no room (a hidden label's own line) is no item of them, and finds by these the item it
    /// lies beside (`ReaderAlignmentItem.inside(_:)`).
    var containers: [ReaderAlignmentContainer] {
        var result: [ReaderAlignmentContainer] = []
        var current = container ?? item?.container
        while let found = current { result.append(found); current = found.parentItem?.container }
        return result
    }

    /// The frame's box has closed; true when its container is shown without its layout.
    func close() -> Bool {
        guard let container else { return false }
        container.close()
        return container.isSimplified
    }
}

/// A paragraph's alignment context, the value of `.readerAlignment`. Each paragraph has its own.
final class ReaderAlignmentParagraph: NSObject, @unchecked Sendable {
    let item: ReaderAlignmentItem
    private let lock = NSLock()
    private var measured: Natural??

    /// A paragraph's unwrapped width, from its first line's start.
    struct Natural { let width: CGFloat; let hasLineBreaks: Bool }

    init(item: ReaderAlignmentItem) { self.item = item }

    /// The paragraph's max-content width, measured once; nil when it holds attachments or is too
    /// long to be narrower than a line, and so fills the line.
    func natural(_ measure: () -> Natural?) -> Natural? {
        lock.withLock {
            if let measured { return measured }
            let value = measure()
            measured = .some(value)
            return value
        }
    }
}

extension NSAttributedString.Key {
    /// A `ReaderAlignmentParagraph` on each paragraph inside a flex or grid container that the
    /// native layout aligns. Resolved text keeps it, which is how continuous scroll finds the
    /// box around a position (`ReaderAlignmentLayout.boxes`); a page's text does not carry it.
    static let readerAlignment = NSAttributedString.Key("org.epublib.alignment")
    /// On the first character of an aligned box's first paragraph, in resolved text: the points
    /// between the box's top edge and that line (alignment's space and the box's top padding and
    /// border). That space is the box's own, so a page or a shown position starting there keeps it.
    static let readerAlignmentLead = NSAttributedString.Key("org.epublib.alignmentLead")
}
