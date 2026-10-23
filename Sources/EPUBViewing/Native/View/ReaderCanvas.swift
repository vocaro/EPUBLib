import CoreGraphics
import EPUBCore
import Foundation

/// A location in the rendered book: a UTF-16 offset into one section's string.
struct ReaderTextPosition: Hashable, Comparable, Sendable {
    var section: Int
    var offset: Int
    var tableCell: ReaderTablePosition?
    init(section: Int, offset: Int, tableCell: ReaderTablePosition? = nil) {
        self.section = section; self.offset = offset; self.tableCell = tableCell
    }
    static func < (a: Self, b: Self) -> Bool {
        if (a.section, a.offset) != (b.section, b.offset) { return (a.section, a.offset) < (b.section, b.offset) }
        return ReaderTablePosition.precedes(a.tableCell, b.tableCell)
    }
}

/// A rendered range; `end` is exclusive. Selections and visible ranges may span sections in
/// continuous scroll. Individual CFIs and drawn highlight segments stay within one document.
struct ReaderTextRange: Hashable, Sendable {
    var start: ReaderTextPosition
    var end: ReaderTextPosition
    init(start: ReaderTextPosition, end: ReaderTextPosition) { self.start = start; self.end = end }
    init(section: Int, _ range: Range<Int>) {
        start = .init(section: section, offset: range.lowerBound); end = .init(section: section, offset: range.upperBound)
    }
    /// The range holds no rendered character: its end is not after its start. Content that
    /// renders nothing maps to an empty range at its section's start or end, and to a reversed
    /// one between rendered text (`SearchResultBuilder.isRendered`). Neither is a passage to
    /// select, draw or list, wherever in its section that content sits.
    var isEmpty: Bool { !(start < end) }
}

/// A heading and where it is in the book: its section, and its characters in that section's
/// string.
struct ReaderBookHeading {
    var heading: ReaderHeading
    var section: Int
    var range: NSRange
    /// Where it begins.
    var position: ReaderTextPosition { ReaderTextPosition(section: section, offset: range.location) }
}

/// The whole book as one string for continuous scroll: every section's string in spine order,
/// each followed by one paragraph break except the last. Sections in `omitted` (nonlinear spine
/// items, which page turns step over too) are left out; the canvas shows one of them on its own
/// when it is navigated to.
struct ReaderBookText: @unchecked Sendable {
    let string: NSAttributedString
    /// `sectionStarts[i]` is section `i`'s first location in `string`; for an omitted section,
    /// the next included section's (or the string's end).
    let sectionStarts: [Int]
    let omitted: Set<Int>

    init(string: NSAttributedString, sectionStarts: [Int], omitted: Set<Int> = []) {
        self.string = string
        self.sectionStarts = sectionStarts
        self.omitted = omitted
    }

    func contains(section: Int) -> Bool { sectionStarts.indices.contains(section) && !omitted.contains(section) }

    /// A position's location; meaningful only for a section the book contains.
    func location(of position: ReaderTextPosition) -> Int {
        min(string.length, sectionStarts[position.section] + position.offset)
    }

    func position(at location: Int) -> ReaderTextPosition {
        var low = 0, high = sectionStarts.count - 1
        while low < high { // last section starting at or before location
            let mid = (low + high + 1) / 2
            if sectionStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        while low > 0, omitted.contains(low) { low -= 1 } // Trailing omitted sections start at the end.
        let next = sectionStarts.indices.dropFirst(low + 1).first { !omitted.contains($0) }
        let end = next.map { sectionStarts[$0] - 1 } ?? string.length
        return ReaderTextPosition(section: low, offset: max(0, min(location, end) - sectionStarts[low]))
    }
}

struct ReaderSelection: Equatable, Sendable {
    var range: ReaderTextRange
    var text: String
}

struct ReaderHighlight: Hashable, Sendable {
    /// `currentSearch` is the search result last shown, drawn over its own `search` highlight.
    enum Kind: Hashable, Sendable { case search, annotation, currentSearch }
    var id: String
    /// Within one section.
    var range: ReaderTextRange
    var kind: Kind
}

extension ReaderHighlight {
    /// Drawing order: host highlights, search matches over them, the current match on top.
    static func drawingOrder(_ highlights: [ReaderHighlight]) -> [ReaderHighlight] {
        highlights.filter { $0.kind == .annotation } + highlights.filter { $0.kind == .search }
            + highlights.filter { $0.kind == .currentSearch }
    }
}

struct ReaderCanvasConfiguration: Equatable, Sendable {
    var pageControls = EPUBPageControls()
    var flow: EPUBReadingFlow = .paginated
    var isDark = false
    /// The spine's `page-progression-direction` is `rtl`: spreads read right to left and the
    /// visual page-turn directions (swipes, tap zones) are mirrored.
    var isRightToLeft = false
    /// A host-reserved vertical division (a fold or hinge), in the canvas's coordinates. In
    /// paginated flow the spread puts its gutter on it; text never crosses it.
    var division: CGRect?
    /// The outer margins as a multiple of the reader's own (`ReaderCanvasGeometry`), 0–4.
    var pageMargins: CGFloat = 1
    var selectionActionTitle: String?
    var selectionActionImage = "text.quote"
}

enum PageTurnResult: Equatable, Sendable {
    case turned
    /// Already at the book's first or last page.
    case atBoundary
    /// The adjacent section is not built yet, or not to be shown as it is built
    /// (`ReaderCanvasDataSource.canShow`); the canvas asked its delegate for it.
    case pending(section: Int)
}

/// Where VoiceOver on Mac enters a page that `ReaderCanvas.show` installs. It enters a column
/// at its insertion point, which a read-only column does not draw (`ReaderTextView`).
enum ReaderPageEntry: Equatable, Sendable {
    /// At the start of the line that holds the position shown, in the column that holds it: a
    /// place the person is taken to, as a link's target, a search result, a contents entry, a
    /// bookmark or the place a book opens at. A relayout enters there again until something
    /// moves the insertion point or focus from it.
    case position
    /// At the page's first line, as after every page turn and every other relayout: the start
    /// or end of a section a page turn reaches.
    case firstLine
}

@MainActor protocol ReaderCanvasDataSource: AnyObject {
    var sectionCount: Int { get }
    /// A section's rendered text, or nil while it is not built.
    func text(forSection index: Int) -> NSAttributedString?
    /// Full semantic passage, including precise cell coordinates and offscreen continuations.
    func selectionText(in range: ReaderTextRange) -> String?
    /// Nonlinear sections are reached by links and navigation; page turns step over them. In a
    /// book with no linear section every section answers true, so page turns read it through.
    func isLinear(section index: Int) -> Bool
    /// The whole book for continuous scroll, once every section is built.
    var bookText: ReaderBookText? { get }
    /// Whether a page turn may show a section's text as it is: false for one that must be built
    /// again first, which the canvas then asks for (`needsSection`), keeping the page it shows.
    func canShow(section index: Int) -> Bool
}

extension ReaderCanvasDataSource {
    func selectionText(in range: ReaderTextRange) -> String? { nil }
    func canShow(section index: Int) -> Bool { true }
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
    /// A search that shows what it finds, as VoiceOver's move by heading, stopped at a section
    /// that must be built again before it is shown (`ReaderCanvasDataSource.canShow`): build it
    /// now, showing nothing, so that the next search finds what it holds.
    func canvas(_ canvas: any ReaderCanvas, wantsSection index: Int)
}

extension ReaderCanvasDelegate {
    func canvas(_ canvas: any ReaderCanvas, wantsSection index: Int) {}
}

/// The TextKit 2 surface: continuous scroll in a real scroll view, or columns paginated from the
/// current section. Implemented by `ReaderCanvasView` on each platform.
@MainActor protocol ReaderCanvas: AnyObject {
    var delegate: (any ReaderCanvasDelegate)? { get set }
    var dataSource: (any ReaderCanvasDataSource)? { get set }
    /// Setting it relays out as needed and keeps the current position visible.
    var configuration: ReaderCanvasConfiguration { get set }
    /// Section text changed (rebuilt for a style) or the whole book became available.
    /// Keeps `position` at the top of the view. The default is the position the canvas is
    /// keeping: the last one shown, else the visible start after a page turn or scroll (so
    /// repeated rebuilds and resizes do not drift towards page starts).
    func reloadContent(keeping position: ReaderTextPosition?)
    /// Brings `position` into view: its page in paginated flow, the top of the view in
    /// continuous scroll. `selecting` (one section) also selects that range natively and is
    /// reported through `canvas(_:didChangeSelection:)` with exactly that range once it settles,
    /// even where the native selection stops at the page's end. Before the canvas has a size or
    /// the section's text, both wait for the first layout or `reloadContent`. `entry` says
    /// where VoiceOver on Mac enters the page shown.
    func show(_ position: ReaderTextPosition, selecting range: ReaderTextRange?, entry: ReaderPageEntry)
    /// Paginated: the next or previous spread, crossing into the adjacent linear section at a
    /// section's end. Continuous scroll: one viewport less a line, crossing sections only while
    /// the whole book is not built. Reports `canvas(_:didShow:sectionProgress:)` when it turns.
    func turnPage(forward: Bool) -> PageTurnResult
    /// What is on screen; nil before the first layout.
    var visibleRange: ReaderTextRange? { get }
    var currentSelection: ReaderSelection? { get }
    func clearSelection()
    /// Replaces every drawn highlight.
    func setHighlights(_ highlights: [ReaderHighlight])
    /// Shows a note in place (a popover), anchored at `rect` in canvas coordinates, in the
    /// appearance its text was built for (`dark`), which a rebuild can reach before the page.
    func presentNote(_ text: NSAttributedString, dark: Bool, from rect: CGRect)
    /// Asks the reader whether to open a link outside the book: an alert on iPhone and iPad,
    /// over a note's popover when one is shown, and a sheet on the window on Mac. `answer` is
    /// called once, true for Open; a question asked while another is shown answers that one no.
    /// False, with nothing asked, when there is no window to ask in.
    func askToOpen(_ question: ExternalLinkQuestion, from rect: CGRect, answer: @escaping @MainActor (Bool) -> Void) -> Bool
    /// Takes a question still shown away, answered no.
    func withdrawLinkQuestion()
}
