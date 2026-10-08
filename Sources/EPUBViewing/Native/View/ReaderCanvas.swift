import CoreGraphics
import EPUBCore
import Foundation

/// A location in the rendered book: a UTF-16 offset into one section's string.
struct ReaderTextPosition: Hashable, Comparable, Sendable {
    var section: Int
    var offset: Int
    init(section: Int, offset: Int) { self.section = section; self.offset = offset }
    static func < (a: Self, b: Self) -> Bool { (a.section, a.offset) < (b.section, b.offset) }
}

/// A rendered range; `end` is exclusive. Selections and visible ranges may span sections in
/// continuous scroll; CFIs and highlights never do.
struct ReaderTextRange: Hashable, Sendable {
    var start: ReaderTextPosition
    var end: ReaderTextPosition
    init(start: ReaderTextPosition, end: ReaderTextPosition) { self.start = start; self.end = end }
    init(section: Int, _ range: Range<Int>) {
        start = .init(section: section, offset: range.lowerBound); end = .init(section: section, offset: range.upperBound)
    }
    var isEmpty: Bool { start == end }
}

/// The whole book as one string for continuous scroll: every section's string in spine order,
/// each followed by one paragraph break except the last.
struct ReaderBookText: @unchecked Sendable {
    let string: NSAttributedString
    /// `sectionStarts[i]` is section `i`'s first location in `string`.
    let sectionStarts: [Int]

    func location(of position: ReaderTextPosition) -> Int {
        min(string.length, sectionStarts[position.section] + position.offset)
    }
    func position(at location: Int) -> ReaderTextPosition {
        var low = 0, high = sectionStarts.count - 1
        while low < high { // last section starting at or before location
            let mid = (low + high + 1) / 2
            if sectionStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        let end = low + 1 < sectionStarts.count ? sectionStarts[low + 1] - 1 : string.length
        return ReaderTextPosition(section: low, offset: min(location, end) - sectionStarts[low])
    }
}

struct ReaderSelection: Equatable, Sendable {
    var range: ReaderTextRange
    var text: String
}

struct ReaderHighlight: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case search, annotation }
    var id: String
    /// Within one section.
    var range: ReaderTextRange
    var kind: Kind
}

struct ReaderCanvasConfiguration: Equatable, Sendable {
    var flow: EPUBReadingFlow = .paginated
    var isDark = false
    /// The spine's `page-progression-direction` is `rtl`: spreads read right to left and the
    /// visual page-turn directions (swipes, tap zones) are mirrored.
    var isRightToLeft = false
    /// A host-reserved vertical division (a fold or hinge), in the canvas's coordinates. In
    /// paginated flow the spread puts its gutter on it; text never crosses it.
    var division: CGRect?
    var selectionActionTitle: String?
    var selectionActionImage = "text.quote"
}

enum PageTurnResult: Equatable, Sendable {
    case turned
    /// Already at the book's first or last page.
    case atBoundary
    /// The adjacent section is not built yet; the canvas asked its delegate for it.
    case pending(section: Int)
}

@MainActor protocol ReaderCanvasDataSource: AnyObject {
    var sectionCount: Int { get }
    /// A section's rendered text, or nil while it is not built.
    func text(forSection index: Int) -> NSAttributedString?
    /// Nonlinear sections are reached by links and navigation; page turns step over them.
    func isLinear(section index: Int) -> Bool
    /// The whole book for continuous scroll, once every section is built.
    var bookText: ReaderBookText? { get }
}

@MainActor protocol ReaderCanvasDelegate: AnyObject {
    /// The visible range changed (page turn, scroll, resize, reload). `sectionProgress` is the
    /// fraction of the section before the visible start, 0–1.
    func canvas(_ canvas: any ReaderCanvas, didShow range: ReaderTextRange, sectionProgress: Double)
    func canvas(_ canvas: any ReaderCanvas, didChangeSelection selection: ReaderSelection?)
    /// The person chose the host's selection action from the selection menu.
    func canvasDidRequestSelectionAction(_ canvas: any ReaderCanvas)
    /// A link was activated. `rect` is the link's frame in canvas coordinates.
    func canvas(_ canvas: any ReaderCanvas, didActivate link: ReaderLink, at position: ReaderTextPosition, rect: CGRect)
    /// A page turn or scroll needs a section that is not built. When it is, the session shows
    /// its start (`forward`) or end.
    func canvas(_ canvas: any ReaderCanvas, needsSection index: Int, forward: Bool)
}

/// The TextKit 2 surface: continuous scroll in a real scroll view, or columns paginated from the
/// current section. Implemented by `ReaderCanvasView` on each platform.
@MainActor protocol ReaderCanvas: AnyObject {
    var delegate: (any ReaderCanvasDelegate)? { get set }
    var dataSource: (any ReaderCanvasDataSource)? { get set }
    /// Setting it relays out as needed and keeps the current position visible.
    var configuration: ReaderCanvasConfiguration { get set }
    /// Section text changed (rebuilt for a style) or the whole book became available.
    /// Keeps `position` (default: the current visible start) at the top of the view.
    func reloadContent(keeping position: ReaderTextPosition?)
    /// Brings `position` into view: its page in paginated flow, the top of the view in
    /// continuous scroll. `selecting` (one section) also selects that range natively.
    func show(_ position: ReaderTextPosition, selecting range: ReaderTextRange?)
    func turnPage(forward: Bool) -> PageTurnResult
    /// What is on screen; nil before the first layout.
    var visibleRange: ReaderTextRange? { get }
    var currentSelection: ReaderSelection? { get }
    func clearSelection()
    /// Replaces every drawn highlight.
    func setHighlights(_ highlights: [ReaderHighlight])
    /// Shows a note in place (a popover), anchored at `rect` in canvas coordinates.
    func presentNote(_ text: NSAttributedString, from rect: CGRect)
}
