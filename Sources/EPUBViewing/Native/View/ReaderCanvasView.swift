import CoreGraphics
import EPUBCore
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The TextKit 2 reader surface on both platforms (doc/native-viewer.md, "Layout").
///
/// Paginated flow slices the current section into pages from one layout per column size
/// (`ReaderPaginator`) and shows a spread's slices in non-scrolling text views, one per column.
/// Each holds its own page's text; a source selection coordinates native ranges across columns,
/// while links and VoiceOver stay on the page, and its layout is small enough to be exact. Continuous scroll is one real scroll
/// view over the whole book once the data source has it, and over the current section until then.
///
/// This file holds the platform-neutral state and logic; `ReaderCanvasView+UIKit.swift` and
/// `ReaderCanvasView+AppKit.swift` supply the views, input, menus and popovers.
@MainActor final class ReaderCanvasView: PlatformView, ReaderCanvas {
    weak var delegate: (any ReaderCanvasDelegate)?
    weak var dataSource: (any ReaderCanvasDataSource)?
    var configuration = ReaderCanvasConfiguration() {
        didSet { if configuration != oldValue { configurationDidChange(from: oldValue) } }
    }
    private(set) var visibleRange: ReaderTextRange?
    private(set) var currentSelection: ReaderSelection?

    /// The position kept on screen across relayouts: the last one asked for, else the visible
    /// start after a page turn or scroll. Keeping the asked-for position rather than its page's
    /// start stops repeated resizes from drifting.
    private(set) var anchor: ReaderTextPosition?
    private var pendingSelection: ReaderTextRange?
    /// Intentional selection requests may span beyond a page or temporary section view.
    /// A carried native user selection must instead fit replacement scroll content in full.
    private var pendingSelectionPreservesFullRange = false
    private var highlights: [ReaderHighlight] = []
    private var reportedSelection: ReaderSelection?
    /// A source selection projected into every visible native text column. Its full text
    /// is used for Copy and host actions, including pages reached through continuation controls.
    private var programmaticSelection: (view: ReaderTextView, local: NSRange, selection: ReaderSelection,
                                       preservesFullRange: Bool, segments: [(view: ReaderTextView, local: NSRange)])?
    private var selectionReport: Task<Void, Never>?
    private var isApplyingSelection = false
    private weak var externalSelectionSource: AnyObject?
    private var selectionDragAnchor: ReaderTextPosition?
    private var selectionDragOverridesNative = false
    private(set) var selectionContinuation: ReaderSelectionContinuation?
    #if os(iOS)
    /// Tells an assistive technology of something the reader did at its asking, which it
    /// would not learn otherwise: that an item it holds has changed, to be read again with
    /// the actions it now offers. UIKit's own post, which a test takes in its place.
    var postToAccessibility: (UIAccessibility.Notification, Any?) -> Void = { UIAccessibility.post(notification: $0, argument: $1) }

    /// Has an assistive technology say what nothing else would tell a listener, after
    /// whatever it is saying.
    func announce(_ words: String) {
        postToAccessibility(.announcement, NSAttributedString(string: words, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
    }

    /// Whether a keyboard is over the canvas's window, and the page area last laid out with
    /// none there and no animation under way: what pages keep while one is (`pageArea`).
    var keyboardIsUp = false
    var uncoveredPageArea: CGRect?
    #endif

    // Paginated flow.
    private(set) var spread: ReaderCanvasGeometry.Spread?
    private(set) var columns: [ReaderTextView] = []
    /// The spread on screen: its section and first page.
    private(set) var shownPage: (section: Int, page: Int)?
    /// A new spread (after a resize) waiting for its pagination; the old one stays on screen.
    private(set) var pendingSpread: ReaderCanvasGeometry.Spread?
    private var pendingPagination: Task<Void, Never>?
    /// Live resizes and rotations in progress, during which pagination waits.
    private var layoutDeferrals = 0

    private struct PaginatorKey: Hashable {
        var section: Int
        var width: CGFloat
        var height: CGFloat
    }
    private var paginators: [PaginatorKey: ReaderPaginator] = [:]
    private var paginatorUse: [PaginatorKey] = []
    private static let cachedPaginators = 8
    /// Characters of TextKit layout the cached paginators may hold together (about 60 bytes
    /// each); a finished pagination holds none.
    static let heldLayoutBudget = 1_000_000
    /// Pagination this far past what is known runs over several turns of the run loop.
    private static let quickPagination = 50_000

    /// The headings of one section's text. The text is not kept alive for them: a section
    /// built again has another text, and its headings are then found again.
    private final class SectionHeadings {
        weak var text: NSAttributedString?
        let headings: [(heading: ReaderHeading, range: NSRange)]
        init(text: NSAttributedString, headings: [(heading: ReaderHeading, range: NSRange)]) {
            self.text = text
            self.headings = headings
        }
    }
    private var sectionHeadings: [Int: SectionHeadings] = [:]
    /// The book's pages at the spread's column size (`layoutPage`).
    let pageCounter = ReaderPageCounter()

    // Continuous scroll.
    private(set) var scrollContainer: PlatformView?
    private(set) var scrollTextView: ReaderTextView?
    /// The whole book, when the scroll view shows it.
    private(set) var scrollBook: ReaderBookText?
    private var scrollGeometry: (bounds: CGRect, minX: CGFloat, width: CGFloat)?
    /// The person scrolled since the anchor was set, so the visible start replaces it.
    private var anchorFollowsScroll = false
    /// `showFound` is showing a place: in continuous scroll its line rests below the top.
    private var isShowingFound = false
    /// The place `showFound` rested below the top of continuous scroll, with the anchor it
    /// rested there under (`foundPlace`).
    private var found: (anchor: ReaderTextPosition, place: ReaderTextPosition)?
    /// The place found that the view still rests on: until the anchor changes or the person
    /// scrolls. An assistive technology goes to its line, not to the first line on screen,
    /// through a resize as well.
    private var foundPlace: ReaderTextPosition? {
        guard configuration.flow == .scrolled, !anchorFollowsScroll, let found, anchor == found.anchor else { return nil }
        return found.place
    }
    private var isScrollingProgrammatically = false
    private var scrollReportPending = false
    /// Where the first line on screen stood when the scroll view was last read: its location in
    /// the view's text, its top and the visible area's, in text container coordinates. AppKit's
    /// `settleScrollViewport` holds the line there. Forgotten whenever the reader lays the text
    /// out itself (new text, a new column width, boxes resolved for a new visible height): its
    /// lines then move by the reader's own doing, not by a layout behind the view.
    var scrollPlace: (location: Int, lineTop: CGFloat, visibleTop: CGFloat)?
    /// Whether the scroll view stands where it was last read, to within a point. AppKit aligns
    /// the offset to the pixel grid when the clip view gets its layer, at the scroll view's first
    /// display, which moves the view by less than that with no scroll by the person.
    var scrollViewStandsWhereRead: Bool {
        guard let place = scrollPlace else { return false }
        return abs(scrollVisibleContainerRect.minY - place.visibleTop) < 1
    }
    /// The line of hidden labels standing at the top with the first line on screen, where
    /// there is one (`scrollVisibleCharacters`): its location in the view's text. VoiceOver
    /// starts there, so the labels are heard before what they stand over.
    private var scrollEntry: Int?
    /// The view is being held to its text (`settleScrollViewport` on the Mac), which moves
    /// its offset and nothing on screen.
    var isHoldingScrollPlace = false
    #if os(macOS)
    /// Where the reader last put the scroll view's insertion point (`placeScrollInsertionPoint`).
    private var placedScrollInsertionPoint: Int?
    /// A place `show` was asked for in pages, until the spread that holds it is installed:
    /// VoiceOver enters the page there (`enterPage`). A page turn, a change of flow and a show
    /// in continuous scroll leave none, and a relayout only the place it still enters at
    /// (`placeStillEntered`).
    private var pageEntry: ReaderTextPosition?
    /// The place the page on screen was entered at (`enterPage`), which a relayout enters
    /// again while nothing has moved from it (`placeStillEntered`). A page turn, another show
    /// and a change of flow leave none.
    private var enteredPlace: ReaderTextPosition?
    /// Lays the canvas out when its safe area changes and its size does not (`platformSetUp`).
    var safeAreaObservation: NSKeyValueObservation?
    /// Posts what the canvas tells an assistive client itself: the layout change after a spread
    /// is installed, and after the reader moves the scroll view the insertion point's second
    /// notice and the layout change (`placeScrollInsertionPoint`). A test puts its own closure
    /// here to see what is posted, and by which element.
    var postAccessibilityNotification: @MainActor (Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]) -> Void = {
        NSAccessibility.post(element: $0, notification: $1, userInfo: $2.isEmpty ? nil : $2)
    }
    #else
    /// The offset a rest for a new visible height left the scroll view at, until UIKit reports
    /// the scrolling of that inset change (`scrollViewDidChangeAdjustedContentInset`).
    var restedScrollOffset: CGFloat?
    /// Posts what the canvas tells an assistive technology after a page turn and after a move
    /// of its own in continuous scroll, and the layout change the scroll bar's stand-in tells
    /// of after it is adjusted (`ReaderTextView`). A test puts its own closure here to see
    /// what is posted, and with which element.
    var postAccessibilityNotification: @MainActor (UIAccessibility.Notification, Any?) -> Void = {
        UIAccessibility.post(notification: $0, argument: $1)
    }
    /// A page shown now leaves an assistive technology's cursor to whoever asked for the page:
    /// VoiceOver's rotor, which takes the cursor to the item it is given
    /// (`showForAccessibilityRotor`), and its scroll, which sends the cursor once the page is
    /// announced (`accessibilityScroll`).
    var accessibilityCursorIsHeld = false
    /// The item VoiceOver's cursor was left on by a page turn VoiceOver made itself, until its
    /// cursor goes to another: no other item turns the page meanwhile
    /// (`accessibilityPageTurnColumn`).
    weak var accessibilityCursorAtTurn: NSObject?
    /// The item VoiceOver's cursor was on when a question about a link outside the book was
    /// asked, until the question is answered (`returnCursorAfterLinkQuestion`).
    weak var cursorBeforeLinkQuestion: NSObject?
    /// The item VoiceOver's cursor is to go back to after a cancelled question, while the first
    /// item VoiceOver comes to after it is awaited, and which wait that is.
    weak var cursorToReturnTo: NSObject?
    var cursorReturnWait = 0
    /// The item VoiceOver's cursor is on; nil while VoiceOver is off. A test puts its own here.
    var voiceOverCursor: @MainActor () -> NSObject? = {
        UIAccessibility.isVoiceOverRunning ? UIAccessibility.focusedElement(using: .notificationVoiceOver) as? NSObject : nil
    }
    #endif

    var wheelTurner = ReaderWheelPageTurner()
    var presentedNote: AnyObject?
    /// The question shown about a link outside the book (`askToOpen`), an alert, and what to
    /// call with its answer.
    var linkQuestion: (shown: AnyObject, answer: @MainActor (Bool) -> Void)?
    /// Where the note shown hangs from, for a link in it.
    var noteRect = CGRect.zero
    var imageInspector: ReaderImageInspector?
    /// Where and when the last touch or click on the canvas began, for edge taps.
    var pointerDown: (location: CGPoint, time: TimeInterval)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        platformSetUp()
        applyAppearance()
        pageCounter.canvas = self
        pageCounter.onCount = { [weak self] in
            guard let self else { return }
            self.delegate?.canvasDidChangeLayoutPage(self)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Every text view on screen.
    var textViews: [ReaderTextView] {
        if let scrollTextView { return [scrollTextView] }
        return columns.filter { !$0.isHidden }
    }

    // MARK: ReaderCanvas

    func reloadContent(keeping position: ReaderTextPosition?) {
        settleLayout()
        if configuration.flow != .scrolled || scrollTextView == nil || externalSelectionSource != nil { carrySelectionAcrossRelayout() }
        anchor = position ?? currentStart() ?? anchor
        anchorFollowsScroll = false
        // Paginators of rebuilt sections are replaced as they are next used (`paginator(for:)`).
        switch configuration.flow {
        case .paginated:
            shownPage = nil
            if spread == nil { layOutCanvas() } else { displayAnchor() }
        case .scrolled:
            guard scrollTextView != nil else { return layOutCanvas() }
            loadScrollContent()
            scrollToAnchor()
            updateVisibleRange(force: true)
        }
        applyPendingSelection()
        selectionMayHaveChanged()
    }

    func show(_ position: ReaderTextPosition, selecting range: ReaderTextRange?, entry: ReaderPageEntry = .position) {
        settleLayout()
        clearSelection()
        anchor = position
        anchorFollowsScroll = false
        pendingSelection = range.flatMap { $0.isEmpty ? nil : $0 }
        pendingSelectionPreservesFullRange = pendingSelection != nil
        #if os(macOS)
        // Continuous scroll rests the position at the top, where the insertion point already is,
        // or a place found below it, where `updateVisibleRange` puts it (`foundPlace`).
        pageEntry = entry == .position && configuration.flow == .paginated ? position : nil
        enteredPlace = nil
        #endif
        switch configuration.flow {
        case .paginated:
            if spread == nil { layOutCanvas() } else { displayAnchor() }
        case .scrolled:
            if scrollTextView == nil { layOutCanvas() } else { showInScroll() }
        }
        applyPendingSelection()
    }

    /// Brings a place found into view, as a search result: its page in paginated flow, as
    /// `show` does. In continuous scroll its line rests a third of the way down the view, not
    /// at the top, with the text before it above, and the line above the third is the anchor
    /// kept through resizes. At the top, a match was a line above the view on an iPhone after
    /// the search sheet closed, and it is where a toolbar's popover hangs (#49).
    func showFound(_ position: ReaderTextPosition) {
        isShowingFound = true
        defer { isShowingFound = false }
        show(position, selecting: nil)
    }

    func turnPage(forward: Bool) -> PageTurnResult {
        settleLayout()
        return switch configuration.flow {
        case .paginated: turnPaginatedPage(forward: forward)
        case .scrolled: turnScrolledPage(forward: forward)
        }
    }

    /// Uses the same section/viewport boundaries as a turn, without moving the reader.
    func canTurnPage(forward: Bool) -> Bool? {
        guard let dataSource, let range = visibleRange else { return nil }
        let section: Int
        switch configuration.flow {
        case .paginated:
            section = range.start.section
            if forward {
                guard let length = dataSource.text(forSection: section)?.length else { return nil }
                if range.end.offset < length { return true }
            } else if range.start.offset > 0 { return true }
        case .scrolled:
            guard let textView = scrollTextView else { return nil }
            if forward ? !isScrolledToEnd : !isScrolledToStart { return true }
            if scrollBook != nil { return false }
            guard let current = textView.placement.section else { return nil }
            section = current
        }
        let candidates = forward ? Array((section + 1)..<dataSource.sectionCount) : Array(0..<section)
        return candidates.contains { dataSource.isLinear(section: $0) }
    }

    func clearSelection() {
        pendingSelection = nil
        pendingSelectionPreservesFullRange = false
        isApplyingSelection = true
        for view in textViews {
            view.clearTableSelection()
            if view.selectedRange.length > 0 { view.selectedRange = NSRange(location: view.selectedRange.location, length: 0) }
        }
        isApplyingSelection = false
        programmaticSelection = nil
        externalSelectionSource = nil
        selectionDragAnchor = nil
        selectionDragOverridesNative = false
        currentSelection = nil
        updateSelectionContinuation()
        selectionReport?.cancel()
        if reportedSelection != nil {
            reportedSelection = nil
            delegate?.canvas(self, didChangeSelection: nil)
        }
    }

    func setHighlights(_ highlights: [ReaderHighlight]) {
        self.highlights = highlights
        applyHighlights()
    }

    // MARK: Layout

    /// Lays out for the current bounds and flow; cheap when nothing changed.
    func layOutCanvas() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        imageInspector?.frame = bounds
        switch configuration.flow {
        case .paginated: layOutPages()
        case .scrolled: layOutScroll()
        }
        for view in textViews { view.refreshTableInteractions() }
        updateSelectionContinuation()
        if let imageInspector {
            #if os(macOS)
            addSubview(imageInspector, positioned: .above, relativeTo: nil)
            for view in textViews { view.setAccessibilityHidden(true) }
            scrollContainer?.setAccessibilityHidden(true)
            #else
            bringSubviewToFront(imageInspector)
            #endif
        }
    }

    private func configurationDidChange(from old: ReaderCanvasConfiguration) {
        if old.pageControls != configuration.pageControls || old.flow != configuration.flow {
            pointerDown = nil
            wheelTurner = ReaderWheelPageTurner()
            updateInputHandlers()
        }
        if old.theme != configuration.theme {
            applyAppearance()
            applyHighlights()
        }
        guard old.flow != configuration.flow || old.division != configuration.division
                || old.isRightToLeft != configuration.isRightToLeft else {
            // New margins are a new column size, laid out as a resize is, keeping the position.
            if old.pageMargins != configuration.pageMargins { layOutCanvas() }
            return
        }
        guard old.flow != configuration.flow else { return layOutCanvas() }
        #if os(macOS)
        pageEntry = nil
        enteredPlace = nil
        #endif
        anchor = currentStart(in: old.flow) ?? anchor
        anchorFollowsScroll = false
        carrySelectionAcrossRelayout()
        // The text views go; keyboard focus and the complete selection must not go with them.
        #if os(iOS)
        // The canvas keeps a focus it holds itself (`takeKeyboardFocusIfFree`).
        let hadFocus = textViews.contains(where: \.isFirstResponder)
        #else
        let hadFocus = hasKeyboardFocus
        #endif
        tearDownPages()
        tearDownScroll()
        layOutCanvas()
        if hadFocus { focus(textViews.first) }
    }

    /// The position to keep: the anchor, or the visible start once the person has scrolled.
    private func currentStart(in flow: EPUBReadingFlow? = nil) -> ReaderTextPosition? {
        if (flow ?? configuration.flow) == .scrolled, anchorFollowsScroll, let start = scrollVisibleRange()?.start {
            return start
        }
        return anchor ?? visibleRange?.start
    }

    private func progress(of position: ReaderTextPosition) -> Double {
        let length = dataSource?.text(forSection: position.section)?.length ?? 0
        return length > 0 ? min(1, max(0, Double(position.offset) / Double(length))) : 0
    }

    /// Records what is on screen and tells the delegate: always after a requested change, and
    /// only when it differs after a passive one (scrolling, resizing).
    private func updateVisibleRange(force: Bool) {
        let range = configuration.flow == .scrolled ? scrollVisibleRange() : pagesVisibleRange()
        // Every move of the scroll view ends here, with the viewport laid out where it stands.
        if configuration.flow == .scrolled { refreshScrollTables() }
        guard let range else { return }
        let changed = range != visibleRange
        visibleRange = range
        #if os(macOS)
        if configuration.flow == .scrolled {
            let entry = scrollEntry.flatMap { location in scrollBook.map { $0.position(at: location) }
                ?? ReaderTextPosition(section: range.start.section, offset: location) }
            placeScrollInsertionPoint(at: foundPlace.flatMap(scrollLineStart) ?? entry ?? range.start, requested: force)
        }
        #else
        if force, configuration.flow == .scrolled { accessibilityCursorFollowsTheScrollView(to: foundPlace ?? anchor) }
        #endif
        if force || changed { delegate?.canvas(self, didShow: range, sectionProgress: progress(of: range.start)) }
    }

    // MARK: Paginated flow

    private func layOutPages() {
        let target = ReaderCanvasGeometry.spread(in: pageArea, division: configuration.division,
                                                 isRightToLeft: configuration.isRightToLeft, margins: configuration.pageMargins)
        guard let spread, shownPage != nil else {
            cancelPendingSpread()
            carrySelectionAcrossRelayout()
            self.spread = target
            displayAnchor()
            applyPendingSelection()
            return
        }
        if target == spread { return cancelPendingSpread() }
        if target != pendingSpread {
            cancelPendingSpread()
            pendingSpread = target
        }
        guard layoutDeferrals == 0, pendingPagination == nil else { return }
        if paginatesQuickly(target) { applyPendingSpread() } else { paginate(towards: target) }
    }

    /// Whether the anchor's page at `target`'s column size is known or close to what is.
    private func paginatesQuickly(_ target: ReaderCanvasGeometry.Spread) -> Bool {
        guard let anchor, let paginator = paginator(for: anchor.section, size: target.columnSize) else { return true }
        return paginator.covers(anchor.offset) || anchor.offset - paginator.paginatedLength <= Self.quickPagination
    }

    /// Paginates towards the anchor a few pages per turn of the run loop, keeping the old spread
    /// on screen and responsive, then shows `target`.
    private func paginate(towards target: ReaderCanvasGeometry.Spread) {
        pendingPagination = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.pendingSpread == target else { return }
                guard let anchor = self.anchor, let paginator = self.paginator(for: anchor.section, size: target.columnSize),
                      !paginator.advance(toward: anchor.offset, pages: 6) else { return self.applyPendingSpread() }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    private func applyPendingSpread() {
        guard let target = pendingSpread else { return }
        cancelPendingSpread()
        carrySelectionAcrossRelayout()
        spread = target
        displayAnchor()
        applyPendingSelection()
    }

    /// Keep the complete source range when typography reloads text or a flow/size change
    /// replaces its views, even if a paginated column can only show part of the selection.
    private func carrySelectionAcrossRelayout() {
        guard pendingSelection == nil else { return }
        let range: ReaderTextRange?
        if externalSelectionSource != nil {
            range = currentSelection?.range
        } else if let programmaticSelection,
           textViews.contains(where: { $0 === programmaticSelection.view }),
           programmaticSelection.segments.allSatisfy({ $0.view.selectedRange == $0.local }) {
            range = programmaticSelection.selection.range
        } else {
            range = textViews.lazy.compactMap { view in
                view.selectedRange.length > 0 ? self.selection(view.selectedRange, in: view)?.range : nil
            }.first
        }
        guard let range, !range.isEmpty else { return }
        pendingSelection = range
        pendingSelectionPreservesFullRange = true
    }

    private func cancelPendingSpread() {
        pendingPagination?.cancel()
        pendingPagination = nil
        pendingSpread = nil
    }

    /// Shows a waiting spread now, so a command acts on what its geometry shows.
    private func settleLayout() {
        if pendingSpread != nil { applyPendingSpread() }
    }

    /// While a live resize or rotation runs, the spread on screen stays and pagination waits.
    func beginDeferringLayout() {
        layoutDeferrals += 1
    }

    func endDeferringLayout() {
        layoutDeferrals = max(0, layoutDeferrals - 1)
        if layoutDeferrals == 0 { layOutCanvas() }
    }

    func deferLayout(for duration: TimeInterval) {
        beginDeferringLayout()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.endDeferringLayout()
        }
    }

    private func tearDownPages() {
        cancelPendingSpread()
        for column in columns {
            discard(column)
            column.removeFromSuperview()
        }
        columns.removeAll()
        spread = nil
        shownPage = nil
        pageCounter.stop()
    }

    /// A text view the canvas is done with. The platform frees views in its own time, so the
    /// text goes now, and with it every image, SVG renderer and font reservation it holds.
    private func discard(_ view: ReaderTextView) {
        view.canvas = nil
        view.delegate = nil
        empty(view)
    }

    /// Removes a text view's text and the viewport's hold on what it was showing.
    private func empty(_ view: ReaderTextView) {
        view.setContent(NSAttributedString())
        view.readerLayoutManager.textViewportLayoutController.layoutViewport()
    }

    /// A section's pagination at a column size (the spread's by default), cached by both.
    func paginator(for section: Int, size: CGSize? = nil) -> ReaderPaginator? {
        guard let size = size ?? spread?.columnSize, let text = dataSource?.text(forSection: section) else { return nil }
        let key = PaginatorKey(section: section, width: size.width, height: size.height)
        paginatorUse.removeAll { $0 == key }
        paginatorUse.append(key)
        if let cached = paginators[key], cached.sourceText === text { return cached }
        let paginator = ReaderPaginator(text: text, size: size)
        paginators[key] = paginator
        trimPaginators()
        return paginator
    }

    /// The cached pagination of a section's current text at a column size, if there is one;
    /// unlike `paginator(for:size:)` it makes none and leaves the cache's order alone.
    func cachedPaginator(for section: Int, size: CGSize) -> ReaderPaginator? {
        guard let text = dataSource?.text(forSection: section),
              let cached = paginators[PaginatorKey(section: section, width: size.width, height: size.height)],
              cached.sourceText === text else { return nil }
        return cached
    }

    /// The paginator of the spread on screen, never trimmed.
    private var shownPaginatorKey: PaginatorKey? {
        guard let shownPage, let size = spread?.columnSize else { return nil }
        return PaginatorKey(section: shownPage.section, width: size.width, height: size.height)
    }

    /// The text what is on screen is laid out from, as the data source gave it: a section's, or
    /// continuous scroll's whole book (`section` nil). nil while nothing is shown.
    var shownText: (section: Int?, text: NSAttributedString)? {
        if let scrollTextView {
            guard let text = scrollTextView.flowSourceText, text.length > 0 else { return nil }
            return (scrollTextView.placement.section, text)
        }
        guard let key = shownPaginatorKey, let paginator = paginators[key] else { return nil }
        return (key.section, paginator.sourceText)
    }

    /// Keeps the cache to a few paginators and their held layouts to `heldLayoutBudget`,
    /// dropping the least recently used.
    private func trimPaginators() {
        let kept = Set([shownPaginatorKey, paginatorUse.last].compactMap { $0 })
        while paginatorUse.count > Self.cachedPaginators, let victim = paginatorUse.first(where: { !kept.contains($0) }) {
            removePaginator(victim)
        }
        var held = paginators.values.reduce(0) { $0 + $1.heldLayoutLength }
        while held > Self.heldLayoutBudget,
              let victim = paginatorUse.first(where: { !kept.contains($0) && paginators[$0]?.holdsLayout == true }) {
            held -= paginators[victim]?.heldLayoutLength ?? 0
            removePaginator(victim)
        }
    }

    private func removePaginator(_ key: PaginatorKey) {
        paginators[key] = nil
        paginatorUse.removeAll { $0 == key }
    }

    /// Memory is short: keep only the pagination on screen.
    func trimCaches() {
        let kept = shownPaginatorKey
        for key in paginatorUse where key != kept { removePaginator(key) }
        pageCounter.trimCaches()
    }

    /// The reader is closed or this view is going away: nothing here is shown again, so the
    /// text and its paginations go now rather than with the views.
    func releaseContent() {
        cancelPendingSpread()
        pageCounter.stop()
        for view in columns + [scrollTextView].compactMap({ $0 }) { empty(view) }
        pageCounter.releaseLayoutResidue()
        scrollBook = nil
        paginators.removeAll()
        paginatorUse.removeAll()
        sectionHeadings.removeAll()
    }

    var cachedPaginatorCount: Int { paginators.count }
    var heldPaginatorLayout: Int { paginators.values.reduce(0) { $0 + $1.heldLayoutLength } }

    /// Shows the spread holding the anchor.
    private func displayAnchor() {
        guard let anchor, let spread, spread.columnSize.width > 0, let paginator = paginator(for: anchor.section)
        else { return }
        let page = paginator.pageIndex(containing: anchor)
        display(section: anchor.section, firstPage: page - page % spread.columns.count)
    }

    private func display(section: Int, firstPage: Int) {
        guard let spread, let paginator = paginator(for: section) else { return }
        let carriedSelection = programmaticSelection?.selection.range ?? (externalSelectionSource != nil ? currentSelection?.range : nil)
        let preservesFullRange = programmaticSelection?.preservesFullRange ?? false
        #if os(macOS)
        // Read before the columns' new text puts their insertion points at its start.
        if pageEntry == nil { pageEntry = placeStillEntered() }
        enteredPlace = nil
        #endif
        shownPage = (section, firstPage)
        while columns.count < spread.columns.count {
            let column = makeColumnView()
            column.canvas = self
            columns.append(column)
        }
        isApplyingSelection = true
        for (slot, column) in columns.enumerated() {
            guard slot < spread.columns.count, let page = paginator.page(at: firstPage + slot) else {
                column.isHidden = true
                column.placement = ReaderTextPlacement(section: section, offset: paginator.text.length)
                column.setContent(NSAttributedString())
                continue
            }
            let frame = spread.columns[slot]
            let top = frame.minY + page.topSpacing
            // A page with layout context is clipped right after its last line.
            let clips = page.layoutEnd > page.range.upperBound
            column.isHidden = false
            column.frame = CGRect(x: frame.minX, y: top, width: frame.width,
                                  height: clips ? page.height : max(page.height, frame.maxY - top))
            column.readerContainer.size = CGSize(width: frame.width, height: 0)
            column.readerContainer.viewportSize = spread.columnSize
            column.placement = ReaderTextPlacement(section: section, offset: page.range.location,
                                                   visibleLength: page.range.length)
            column.setContent(paginator.text(for: page))
            column.ensureFullLayout()
        }
        isApplyingSelection = false
        #if os(macOS)
        if let entry = pageEntry {
            pageEntry = nil
            enterPage(at: entry)
        }
        // VoiceOver keeps a column's previous text across a value change it did not witness
        // from inside that column; a layout change naming the columns makes it read the new
        // page. It also keeps a text cursor of its own in a column it has left, and on coming
        // back moves the insertion point there instead of entering at it, so it read on from
        // the line it had reached on the page before. It gives that cursor up when the change
        // is posted by the element that holds the columns, and keeps it when the window posts
        // the same change (#337).
        if let window {
            postAccessibilityNotification(NSAccessibility.unignoredAncestor(of: self) ?? window, .layoutChanged,
                                          [.uiElements: columns.filter { !$0.isHidden }])
        }
        #else
        accessibilityPageWasShown(at: anchor)
        #endif
        trimPaginators()
        // Counts at another column size are dropped before the delegate reads `layoutPage`.
        pageCounter.count(for: spread.columnSize)
        pageCounter.resume()
        applyHighlights()
        updateVisibleRange(force: true)
        if let carriedSelection, carriedSelection.start.tableCell != nil || carriedSelection.end.tableCell != nil
            || textViews.contains(where: { localRange(of: carriedSelection, in: $0) != nil }) {
            pendingSelection = carriedSelection
            pendingSelectionPreservesFullRange = preservesFullRange
            applyPendingSelection()
        }
        selectionMayHaveChanged()
        updateSelectionContinuation()
    }

    private func pagesVisibleRange() -> ReaderTextRange? {
        guard let shownPage else { return nil }
        let shown = columns.filter { !$0.isHidden }
        guard let first = shown.map(\.placement.offset).min(),
              let end = shown.map({ $0.placement.offset + $0.placement.visibleLength }).max() else { return nil }
        return ReaderTextRange(section: shownPage.section, first..<end)
    }

    private func turnPaginatedPage(forward: Bool) -> PageTurnResult {
        guard let shownPage, let spread, let paginator = paginator(for: shownPage.section) else { return .atBoundary }
        let count = spread.columns.count
        let target = forward ? shownPage.page + count : max(0, shownPage.page - count)
        if target != shownPage.page, let page = paginator.page(at: target) {
            anchor = ReaderTextPosition(section: shownPage.section, offset: page.range.location)
            #if os(macOS)
            enteredPlace = nil
            #endif
            display(section: shownPage.section, firstPage: target)
            return .turned
        }
        return turnSection(from: shownPage.section, forward: forward)
    }

    /// Moves to the start (`forward`) or end of the adjacent linear section.
    private func turnSection(from section: Int, forward: Bool) -> PageTurnResult {
        guard let dataSource else { return .atBoundary }
        let step = forward ? 1 : -1
        var next = section + step
        while next >= 0, next < dataSource.sectionCount, !dataSource.isLinear(section: next) { next += step }
        guard next >= 0, next < dataSource.sectionCount else { return .atBoundary }
        guard let text = dataSource.text(forSection: next), dataSource.canShow(section: next) else {
            delegate?.canvas(self, needsSection: next, forward: forward)
            return .pending(section: next)
        }
        show(ReaderTextPosition(section: next, offset: forward ? 0 : text.length), selecting: nil, entry: .firstLine)
        return .turned
    }

    // MARK: Continuous scroll

    private func layOutScroll() {
        let created = scrollTextView == nil
        if created {
            let (container, textView) = makeScrollView()
            textView.canvas = self
            scrollContainer = container
            scrollTextView = textView
        }
        // Capture the old source position before sizing the clip view: AppKit can reflow
        // the document immediately, making the old scroll Y refer to earlier characters.
        let retainedStart = !created && anchorFollowsScroll ? scrollVisibleRange()?.start : nil
        var area = pageArea
        withProgrammaticScroll { area = scrollColumnArea() }
        let column = ReaderCanvasGeometry.scrollColumn(
            in: CGRect(x: area.minX, y: bounds.minY, width: area.width, height: bounds.height),
            division: configuration.division, margins: configuration.pageMargins)
        defer { updateScrollViewport() }
        if let geometry = scrollGeometry, geometry.bounds == bounds, geometry.minX == column.minX,
           geometry.width == column.width { return }
        if let retainedStart { anchor = retainedStart }
        scrollGeometry = (bounds, column.minX, column.width)
        withProgrammaticScroll { applyScrollGeometry(columnMinX: column.minX, width: column.width) }
        updateScrollViewport(rest: false)
        if created { loadScrollContent() }
        scrollToAnchor()
        updateVisibleRange(force: created)
        if created { applyPendingSelection() }
    }

    /// Keeps the viewport attachments size against current, the visible height included (it
    /// changes with the safe area alone). Text already laid out keeps its size; a new column
    /// width relays everything out anyway. Boxes are resolved against it again, which lays all
    /// the text out anew where there are any: a box that takes its height from the visible area
    /// moves its first line by the change in the space above it while its top edge stays, and
    /// `settleScrollViewport` must not take that for a layout behind the view (#313). Every
    /// line below such a box moves with it, and until it is laid out again its place is an
    /// estimate, so the kept position is then rested again as after a resize: a bar shown or
    /// hidden over the reader changes the visible height and not the canvas's size (#338).
    /// Where there is no box, the Mac reads what is on screen again: AppKit moves the view for
    /// the bar's new inset inside the canvas's layout, a move of the reader's own, and where the
    /// view is as far down as it goes, by less than the inset changed, which brings an earlier
    /// line in at the top (#162). `rest` is false where the caller rests the position itself.
    /// True when it was rested.
    @discardableResult func updateScrollViewport(rest: Bool = true) -> Bool {
        guard let textView = scrollTextView, let geometry = scrollGeometry else { return false }
        let viewport = CGSize(width: geometry.width, height: max(0, scrollVisibleContainerRect.height))
        guard textView.readerContainer.viewportSize != viewport else { return false }
        // The visible start is read from the layout the new height is about to replace.
        let retainedStart = rest && anchorFollowsScroll && textView.layoutFollowsViewport ? scrollVisibleRange()?.start : nil
        textView.readerContainer.viewportSize = viewport
        guard textView.refreshFlowBoxLayout() else {
            #if os(macOS)
            if rest { updateVisibleRange(force: false) }
            #endif
            return false
        }
        scrollPlace = nil
        guard rest else { return false }
        if let retainedStart { anchor = retainedStart }
        scrollToAnchor()
        updateVisibleRange(force: false)
        return true
    }

    private func tearDownScroll() {
        let textView = scrollTextView
        scrollTextView = nil
        if let textView { discard(textView) }
        scrollContainer?.removeFromSuperview()
        scrollContainer = nil
        scrollBook = nil
        scrollGeometry = nil
    }

    /// Puts the whole book in the scroll view when the data source has it, else the anchor's section.
    private func loadScrollContent() {
        guard let textView = scrollTextView else { return }
        // Capture in the old placement before a section becomes the whole book (or vice versa).
        // A pending locate owns the selection; a native user edit supersedes a cached locate.
        let carried: ReaderTextRange?
        var carriedPreservesFullRange = false
        if pendingSelection == nil, textView.selectedRange.length > 0 {
            if let programmaticSelection, programmaticSelection.view === textView,
               programmaticSelection.local == textView.selectedRange {
                carried = programmaticSelection.selection.range
                carriedPreservesFullRange = programmaticSelection.preservesFullRange
            } else { carried = selection(textView.selectedRange, in: textView)?.range }
        } else { carried = nil }
        let content: (text: NSAttributedString, placement: ReaderTextPlacement)
        // A section the whole book leaves out (nonlinear) is shown on its own.
        if let book = dataSource?.bookText, anchor.map({ book.contains(section: $0.section) }) ?? true {
            scrollBook = book
            content = (book.string, ReaderTextPlacement(section: nil, offset: 0, visibleLength: book.string.length))
        } else if let anchor, let text = dataSource?.text(forSection: anchor.section) {
            scrollBook = nil
            content = (text, ReaderTextPlacement(section: anchor.section, offset: 0, visibleLength: text.length))
        } else {
            return
        }
        programmaticSelection = nil
        isApplyingSelection = true
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.placement = content.placement
        scrollPlace = nil
        withProgrammaticScroll { textView.setContent(content.text) }
        #if os(macOS)
        placedScrollInsertionPoint = textView.selectedRange.location // New text starts with its own.
        #endif
        isApplyingSelection = false
        // A carried native selection must fit the replacement section in full. Explicit locates
        // still keep their existing clipped-page semantics in `applyPendingSelection`.
        if let carried, carriedPreservesFullRange || scrollBook != nil ||
            (carried.start.section == content.placement.section && carried.end.section == content.placement.section) {
            pendingSelection = carried
            pendingSelectionPreservesFullRange = carriedPreservesFullRange
        }
        applyPendingSelection()
        if carried != nil, pendingSelection != nil { // Do not resurrect an unmappable old selection.
            pendingSelection = nil
            pendingSelectionPreservesFullRange = false
        }
        if textView.selectedRange.length == 0 {
            currentSelection = nil
            scheduleSelectionReport()
        }
        applyHighlights()
    }

    private func showInScroll() {
        guard let textView = scrollTextView, let anchor else { return }
        let bookHasAnchor = dataSource?.bookText?.contains(section: anchor.section) == true
        if let book = scrollBook, !book.contains(section: anchor.section) {
            loadScrollContent()
        } else if scrollBook == nil, bookHasAnchor || textView.placement.section != anchor.section {
            loadScrollContent()
        }
        scrollToAnchor()
        found = nil
        if isShowingFound {
            // `anchor` here is the place shown; resting moves the canvas's own.
            restAnchor(above: anchor)
            if let rested = self.anchor { found = (rested, anchor) }
        }
        updateVisibleRange(force: true)
    }

    /// Makes the line a third of the view above `found`, whose line `scrollToAnchor` has put at
    /// the top, the anchor and scrolls it to the top (`showFound`). What is between them is
    /// laid out in one run first, so the third is measured on the lines where they stand.
    /// The anchor stays in the found place's section, so that the location, its title and its
    /// page are that section's: a match in a section's first lines has the section's start at
    /// the top. Where the found line would then not be wholly on screen, it stays at the top.
    private func restAnchor(above found: ReaderTextPosition) {
        func restore() {
            anchor = found
            scrollToAnchor()
        }
        guard let textView = scrollTextView, found.tableCell == nil else { return }
        let location: Int
        if let book = scrollBook {
            location = book.location(of: found)
        } else if textView.placement.section == found.section {
            location = found.offset
        } else { return }
        guard location < textView.textLength, let first = textView.lineFrame(containing: location) else { return }
        let rise = scrollVisibleContainerRect.height / 3
        withProgrammaticScroll { scrollToContainerY(first.minY - rise) }
        let above = textView.lineBoundary(atContainerY: scrollVisibleContainerRect.minY, lineEnd: false)
        textView.ensureLayout(from: min(above, location), through: location)
        guard let line = textView.lineFrame(containing: location) else { return restore() }
        let sectionStart = scrollBook?.location(of: ReaderTextPosition(section: found.section, offset: 0)) ?? 0
        let top = max(sectionStart, textView.lineBoundary(atContainerY: max(0, line.minY - rise), lineEnd: false))
        guard top < location, let start = position(at: top, in: textView) else { return restore() }
        anchor = start
        scrollToAnchor()
        let visible = scrollVisibleContainerRect
        guard let shown = textView.lineFrame(containing: location),
              shown.minY >= visible.minY - 1, shown.maxY <= visible.maxY + 1 else { return restore() }
    }

    /// Scrolls the anchor to the top of the visible area (a section's end to the bottom).
    private func scrollToAnchor() {
        if !scrollToAnchorLine() {
            // TextKit 2 can lay the anchor's line out over other text after relayouts in quick
            // succession, and then reports the same wrong place however often it is asked. Text
            // loaded afresh starts its layout over.
            loadScrollContent()
            scrollToAnchorLine()
            selectionMayHaveChanged()
        }
        anchorFollowsScroll = false
    }

    /// Scrolls the line holding the anchor to the top, or the top edge of the aligned box
    /// around it when the box fits the visible area (`restLocation`); false when TextKit puts
    /// other text there, or refinement did not bring the target into the viewport.
    @discardableResult private func scrollToAnchorLine() -> Bool {
        guard let textView = scrollTextView, let anchor else { return true }
        var location: Int
        if let book = scrollBook {
            location = book.location(of: anchor)
        } else if textView.placement.section == anchor.section {
            location = anchor.offset
        } else { return true }
        if scrollBook == nil, location >= textView.textLength {
            withProgrammaticScroll { scrollToContainerY(.greatestFiniteMagnitude) }
            return true
        }
        // The anchor itself is kept, so the choice is made again at every size.
        if anchor.tableCell == nil {
            location = textView.restLocation(for: location, fitting: scrollVisibleContainerRect.height)
        }
        withProgrammaticScroll { scrollLineToTop(containing: location, in: textView) }
        if anchor.tableCell != nil, var cell = tableAnchorFrame(for: anchor) {
            withProgrammaticScroll {
                for _ in 0..<32 {
                    scrollToContainerY(cell.minY)
                    guard let updated = tableAnchorFrame(for: anchor) else { break }
                    cell = updated
                    if anchorFrameIsVisible(cell) { break }
                }
            }
            return anchorFrameIsVisible(cell)
        }
        guard let line = textView.lineFrame(containing: location) else { return true }
        return textView.fragment(atContainerY: line.midY, holds: location)
            && anchorFrameIsVisible(textView.anchorFrame(of: line, at: location))
    }

    /// A coherent offscreen fragment is insufficient: estimates can move its line during the
    /// last viewport pass. Success requires the actual line at the visible top, or visible at
    /// a document boundary where the scroll view cannot put it there.
    private func anchorFrameIsVisible(_ frame: CGRect) -> Bool {
        let visible = scrollVisibleContainerRect
        if abs(frame.minY - visible.minY) <= 1 { return true }
        let intersects = frame.maxY > visible.minY && frame.minY < visible.maxY
        return intersects && ((isScrolledToStart && frame.minY <= visible.minY)
            || (isScrolledToEnd && frame.maxY <= visible.maxY + 1))
    }

    /// Scrolls the line holding `location` to the top of the visible area, as far as the content
    /// allows. Far from what is laid out, TextKit 2 only estimates where the line is, and laying
    /// out the viewport there places text by an estimate of its own, which can be screens away;
    /// so each pass checks which line the visible top shows. From text before the line, laying
    /// out through it in one run places it exactly relative to what is shown; from text past
    /// it, the view climbs above it (TextKit 2 lays out forward only), twice as far each time it
    /// is still past.
    private func scrollLineToTop(containing location: Int, in textView: ReaderTextView) {
        guard var line = textView.line(containing: location) else { return }
        // The top of an aligned flex or grid box is above its first line (`anchorFrame`).
        func frame() -> CGRect { textView.anchorFrame(of: line.frame, at: location) }
        if textView.readerContainer.hasNonlinearGeometry {
            // Layout can refine its estimate after the viewport moves. Correct against the
            // target's own visual line; source offsets are not monotonic in Y around floats.
            for _ in 0..<32 {
                scrollToContainerY(frame().minY)
                guard let updated = textView.line(containing: location) else { break }
                line = updated
                if anchorFrameIsVisible(frame()) { break }
            }
            return
        }
        scrollToContainerY(frame().minY)
        // A line of hidden labels alone has no height: where the offset is rounded to a pixel
        // it is the first line at the top or just above it by chance. It is at the top when
        // the first line that shows anything is the one after it, so lines are compared by
        // that one, the target's too.
        let goal = textView.firstShownLine(from: location)
        var climb: CGFloat = 0
        for _ in 0..<32 {
            let visible = scrollVisibleContainerRect
            let shown = textView.firstShownLine(from: textView.lineBoundary(atContainerY: visible.minY, lineEnd: false))
            if let updated = textView.line(containing: location) { line = updated }
            if shown == textView.firstShownLine(from: line.range.location) && anchorFrameIsVisible(frame()) { break }
            if shown <= goal && isScrolledToEnd && anchorFrameIsVisible(frame()) { break }
            if shown <= goal {
                textView.ensureLayout(from: min(shown, location), through: max(shown, location))
                guard let laidOut = textView.line(containing: location) else { break }
                line = laidOut
                scrollToContainerY(frame().minY)
                climb = 0
            } else { // First the characters past the line at the shown text's density, and a screen.
                let end = textView.lineBoundary(atContainerY: visible.maxY, lineEnd: true)
                let charactersPerPoint = CGFloat(max(1, end - shown)) / max(1, visible.height)
                climb = climb > 0 ? 2 * climb : CGFloat(shown - goal) / charactersPerPoint + visible.height
                scrollToContainerY(visible.minY - climb)
            }
        }
    }

    #if os(macOS)
    /// Holds the text on screen in place (`settleScrollViewport`) before the scroll view's
    /// layout is read for what is on screen by anything but the reader's own read of it: the
    /// rows whose cells stand in the view, and what an assistive client is told is on screen
    /// and where. VoiceOver asks the text which line its insertion point is on, and AppKit
    /// counts the lines from the first, which lays out all the text above. A row shown below
    /// text that was only estimated then stands screens from where the view draws it, while
    /// the rows after it stand where they were drawn: read off that layout, the row was off
    /// screen, and its link was no child of the text. Not while the reader moves the view
    /// itself, which ends in its own read. True when the view moved.
    @discardableResult func holdScrollPlace(of view: ReaderTextView) -> Bool {
        guard view === scrollTextView, !isScrollingProgrammatically, !isHoldingScrollPlace else { return false }
        let top = scrollVisibleContainerRect.minY
        withProgrammaticScroll { settleScrollViewport() }
        return scrollVisibleContainerRect.minY != top
    }
    #endif

    private func withProgrammaticScroll(_ body: () -> Void) {
        let wasScrolling = isScrollingProgrammatically
        isScrollingProgrammatically = true
        body()
        isScrollingProgrammatically = wasScrolling
    }

    /// Gives the table rows now on screen in the scroll view their cells' text views, with the
    /// highlights and the selection that run through them. Done as the view moves, and again
    /// once the reader has read where the view stands (`updateVisibleRange`), which every move
    /// ends in. The platform tells of a move when the offset changes, before TextKit has laid
    /// the viewport out there, so the rows are then looked for in the layout of the place
    /// before. After a step of a page, or the reader's last correction on its way to a
    /// contents entry, the rows that layout had not reached had no cell to select in, follow
    /// a link in or offer an assistive technology until the person scrolled; where the
    /// correction was by more than a screen, as for a section a book opened at, none had (#472).
    func refreshScrollTables() {
        scrollTextView?.setTableHighlights(ReaderHighlight.drawingOrder(highlights))
        if let range = currentSelection?.range, range.start.tableCell != nil || range.end.tableCell != nil {
            _ = scrollTextView?.selectTableRange(range, reporting: false)
        }
    }

    /// The platform scroll view moved; reports the visible range at most every 150 ms. A move
    /// that leaves the view where it was last read is the platform's, and nobody scrolled; nor
    /// has anybody when the platform reports the reader's own scroll late (`byReader`).
    func scrollPositionDidChange(byReader: Bool = false) {
        // While the view is held to its text the rows on screen are the ones that were. The
        // layout of the place before has them off screen: their cells would be taken away
        // and made again, and with them the links an assistive client holds.
        if !isHoldingScrollPlace { refreshScrollTables() }
        guard !byReader, !isScrollingProgrammatically, !scrollViewStandsWhereRead else { return }
        anchorFollowsScroll = true
        #if os(macOS)
        // Record the new first line before an accessibility query can replace estimated
        // geometry above it. Waiting for the throttled report leaves a 150 ms gap (#266).
        withProgrammaticScroll {
            scrollTextView?.readerLayoutManager.textViewportLayoutController.layoutViewport()
            _ = scrollVisibleCharacters()
        }
        #endif
        guard !scrollReportPending else { return }
        scrollReportPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.scrollReportPending = false
            guard self.configuration.flow == .scrolled, self.scrollTextView != nil else { return }
            self.updateVisibleRange(force: false)
        }
    }

    /// The first and last characters in the visible area (not under the bars): from the first
    /// line mostly below its top through the last mostly above its bottom. A line the area
    /// shows less than half of is not on screen, so the line above a position resting a
    /// fraction of a point low (`anchorFrameIsVisible`) is not the visible start. Nor is a line
    /// of hidden labels alone, which has no height and is in the area whenever the line after
    /// it is at the top: a section holding nothing else would be the place reported for the
    /// start of the one after it.
    private func scrollVisibleRange() -> ReaderTextRange? {
        guard let textView = scrollTextView, let shown = scrollVisibleCharacters() else { return nil }
        if let book = scrollBook {
            return ReaderTextRange(start: book.position(at: shown.location), end: book.position(at: NSMaxRange(shown)))
        }
        guard let section = textView.placement.section else { return nil }
        return ReaderTextRange(section: section, shown.location..<NSMaxRange(shown))
    }

    /// The characters of the lines in the visible area (not under the bars), in the scroll
    /// view's own text.
    func scrollVisibleCharacters() -> NSRange? {
        guard let textView = scrollTextView, scrollBook != nil || textView.placement.section != nil else { return nil }
        // The layout is what the view draws only once the viewport has settled on it.
        withProgrammaticScroll { settleScrollViewport() }
        let rect = scrollVisibleContainerRect
        let start: Int, end: Int
        if textView.readerContainer.hasNonlinearGeometry {
            // A float or positioned box is beside or over lines later in the source: every
            // line counts by its own frame.
            guard let shown = textView.mostlyVisibleCharacterRange(in: rect) else { return nil }
            start = shown.location; end = NSMaxRange(shown)
        } else {
            start = textView.firstShownLine(from: textView.lineBoundary(atContainerY: rect.minY, lineEnd: false))
            end = max(start, textView.lastShownLine(upTo: textView.lineBoundary(atContainerY: rect.maxY, lineEnd: true)))
        }
        #if os(macOS)
        scrollPlace = textView.lineFrame(containing: start).map { (start, $0.minY, rect.minY) }
        #endif
        // VoiceOver must not pass over hidden labels that stand at the top with the first
        // line on screen: a hidden heading over a table.
        var entry = start
        while let labels = textView.hiddenLabelsAlone(at: entry - 1), let line = textView.lineFrame(containing: labels.location),
              line.maxY >= rect.minY - 1 {
            entry = labels.location
        }
        scrollEntry = entry == start ? nil : entry
        return NSRange(location: start, length: end - start)
    }

    /// The characters VoiceOver is given as on screen in continuous scroll: those of
    /// `scrollVisibleCharacters`, from the hidden labels standing at the top with the first
    /// line where there are any.
    func scrollSpokenCharacters() -> NSRange? {
        guard let shown = scrollVisibleCharacters() else { return nil }
        guard let entry = scrollEntry, entry < shown.location else { return shown }
        return NSRange(location: entry, length: NSMaxRange(shown) - entry)
    }

    #if os(macOS)
    /// The start of the line VoiceOver is given that holds `position` in the scroll view: where
    /// it enters at a place found below the top (`showFound`), as it enters the line on screen.
    private func scrollLineStart(of position: ReaderTextPosition) -> ReaderTextPosition? {
        guard let textView = scrollTextView else { return nil }
        let location = scrollBook?.location(of: position) ?? position.offset
        guard location < textView.textLength else { return nil }
        let line = textView.accessibilityRange(forLine: textView.accessibilityLine(for: location))
        return self.position(at: line.location, in: textView)
    }

    /// Keeps the scroll view's insertion point on the first line on screen. VoiceOver enters a
    /// Mac text view at its insertion point, which a read-only view does not draw; new text
    /// starts with it at its first line. As a page turn does for a column, a move the reader
    /// makes itself (`requested`) puts it at the visible start, or at the start of a found
    /// place's line (`scrollLineStart`). After any other scrolling it
    /// follows only while it is where the reader last put it: one placed by a click, or by an
    /// assistive client that scrolls the view as it reads, stays there. A selection is never
    /// moved. A move the reader makes itself is for VoiceOver to come along with, wherever its
    /// cursor is, so the text view tells of the insertion point a second time and the window
    /// of a layout change. On iOS VoiceOver reads the text view's elements and enters at none:
    /// there the scroll view lists its lines on screen (`ReaderTextView`).
    private func placeScrollInsertionPoint(at start: ReaderTextPosition, requested: Bool) {
        guard let textView = scrollTextView else { return }
        if textView.selectedRange.length == 0, requested || textView.selectedRange.location == placedScrollInsertionPoint {
            let location = scrollBook?.location(of: start) ?? start.offset
            placedScrollInsertionPoint = location
            if textView.selectedRange.location != location {
                isApplyingSelection = true
                textView.selectedRange = NSRange(location: location, length: 0)
                isApplyingSelection = false
                // AppKit has told an assistive client of that move, once. VoiceOver, inside the
                // text and not yet moved in it, kept its cursor on its line for the one notice:
                // it said the word before the insertion point, and at the layout change below,
                // or without one at its next command, scrolled the view back to its line by
                // the scroll bar's value. The reader's step was undone, and the insertion
                // point, still the reader's, followed that scroll. Told a second time,
                // VoiceOver takes its cursor to the insertion point, as it does at the first
                // notice once it has moved by line. Moving the insertion point twice did the
                // same; moving it before the scroll, or posting the layout change from
                // another element, first or not at all, did not (macOS 27.0.1, #473).
                if requested { postAccessibilityNotification(textView, .selectedTextChanged, [:]) }
            }
        }
        // VoiceOver keeps its own cursor in a text area it has left, and on returning goes back
        // to it, scrolling the view there. A layout change naming the text view makes it enter
        // at the insertion point. The window posts it. For a spread's columns that is not
        // enough (`display`), and here it was heard to be: brought to the text by a focus
        // change, two lines down, out to Scroll Forward and back, VoiceOver entered at the new
        // first line (#373). Posted by the element that holds the text, it would also take a
        // VoiceOver cursor resting on that element into the text at every step.
        if requested, let window {
            postAccessibilityNotification(window, .layoutChanged, [.uiElements: [textView]])
        }
    }

    /// Puts the insertion point at the start of the line that holds `position`, in the column
    /// that holds it, once the spread shown for it is installed (`ReaderPageEntry.position`).
    /// VoiceOver enters a column at its insertion point, and installing a page puts that at the
    /// page's first line (`ReaderTextView.exposeTextualAttachments`): after a link, a search
    /// result, a contents entry or a bookmark it started at the top of the page, and the
    /// listener read down the page to the place they went to (#383). The line is one that
    /// VoiceOver is given (`ReaderTextView.accessibilityRange(forLine:)`). A position with no
    /// character of its own, as a section's end, is on no line, and the page keeps its first.
    /// A relayout enters the place again while nothing has moved from it (`placeStillEntered`).
    ///
    /// VoiceOver stays in the column that has the keyboard focus (`focusFirstColumnAfterTurn`),
    /// so focus in another column of the spread goes to this one, and VoiceOver goes with it.
    /// Focus anywhere else, as on a host's list of search results, is left where it is.
    private func enterPage(at position: ReaderTextPosition) {
        guard let (column, local) = column(holding: position) else { return }
        let line = column.accessibilityLine(for: local)
        let range = line == NSNotFound ? NSRange(location: NSNotFound, length: 0) : column.accessibilityRange(forLine: line)
        let start = range.location == NSNotFound ? local : range.location
        column.entryLocation = start
        enteredPlace = position
        if column.selectedRange != NSRange(location: start, length: 0) {
            isApplyingSelection = true
            column.selectedRange = NSRange(location: start, length: 0)
            isApplyingSelection = false
        }
        if let responder = window?.firstResponder as? ReaderTextView, responder !== column,
           columns.contains(where: { $0 === responder }) {
            focus(column)
        }
    }

    /// The place the page on screen was entered at, while the page stands as the reader left
    /// it: every column's insertion point where the reader put it, nothing selected, and
    /// keyboard focus in no column but the place's. A relayout (a resize, a text size, the text
    /// built again, a division) installs the spread that holds the place, since it is still
    /// the anchor, and VoiceOver enters there again rather than at the page's first line. A
    /// host that restores a place at opening, while its window settles or its text is built
    /// for its style, keeps it. Continuous scroll keeps its insertion point by the same rule
    /// (`placeScrollInsertionPoint`). A click, VoiceOver's moves by line, which move the
    /// insertion point, a selection, or focus taken to the column beside ends it, and a
    /// relayout after that enters at the first line, as after a page turn. A move of
    /// VoiceOver's own cursor that changes neither the insertion point nor focus goes unseen.
    private func placeStillEntered() -> ReaderTextPosition? {
        guard let place = enteredPlace, let (column, _) = column(holding: place), currentSelection == nil,
              textViews.allSatisfy({ $0.selectedRange == NSRange(location: $0.entryLocation, length: 0) }) else { return nil }
        if let responder = window?.firstResponder as? ReaderTextView, responder !== column,
           columns.contains(where: { $0 === responder }) { return nil }
        return place
    }

    /// The shown column that holds `position`'s character, and where in its text.
    private func column(holding position: ReaderTextPosition) -> (ReaderTextView, Int)? {
        let place = ReaderTextRange(section: position.section, position.offset..<(position.offset + 1))
        return columns.lazy.filter({ !$0.isHidden })
            .compactMap({ view in self.localRange(of: place, in: view).map { (view, $0.location) } }).first
    }
    #endif

    private func turnScrolledPage(forward: Bool) -> PageTurnResult {
        guard let textView = scrollTextView else { return .atBoundary }
        // The step is taken from the text on screen, wherever a layout since has put it.
        withProgrammaticScroll { settleScrollViewport() }
        guard forward ? isScrolledToEnd : isScrolledToStart else {
            let visible = scrollVisibleContainerRect
            let start = textView.lineBoundary(atContainerY: visible.minY, lineEnd: false)
            let firstLine = textView.lineFrame(containing: start)
            let line = firstLine?.height ?? 20
            let below = (firstLine?.minY ?? visible.minY) - visible.minY
            let proposedStep = max(line, visible.height - line)
            // The first mostly visible line can be a tall picture well below the top.
            // Keep at least half of that line on screen when going back; a full fixed
            // step can otherwise put even its top below the new screen (#161).
            let step = forward ? proposedStep
                : min(proposedStep, max(1, visible.height - below - min(line, visible.height) / 2))
            withProgrammaticScroll {
                scrollToContainerY(visible.minY + (forward ? step : -step))
                if !forward {
                    // Figures above a jumped-to position may still be estimated. Refine the
                    // newly visible text through the old first line, then move that line
                    // one step down the screen, retaining any partial line at the top.
                    // A fixed container Y alone can skip screens of text (#161).
                    for _ in 0..<32 {
                        let top = textView.lineBoundary(atContainerY: scrollVisibleContainerRect.minY, lineEnd: false)
                        textView.ensureLayout(from: min(top, start), through: max(top, start))
                        guard let previous = textView.lineFrame(containing: start) else { break }
                        let target = previous.minY - step - below
                        scrollToContainerY(target)
                        guard let refined = textView.lineFrame(containing: start) else { break }
                        if abs(refined.minY - scrollVisibleContainerRect.minY - step - below) <= 1 || isScrolledToStart { break }
                    }
                }
            }
            anchor = scrollVisibleRange()?.start ?? anchor
            anchorFollowsScroll = false
            updateVisibleRange(force: true)
            return .turned
        }
        guard scrollBook == nil, let section = textView.placement.section else { return .atBoundary }
        return turnSection(from: section, forward: forward)
    }

    // MARK: Selection

    /// Selects the range `show(_:selecting:)` asked for, once its text is on screen.
    private func applyPendingSelection() {
        guard let range = pendingSelection else { return }
        if range.start.tableCell != nil || range.end.tableCell != nil {
            isApplyingSelection = true
            var selectedTables = [ReaderTableInteraction]()
            var segments = [(view: ReaderTextView, local: NSRange)]()
            for view in textViews {
                let local = localRange(of: range, in: view)
                view.selectedRange = local ?? NSRange(location: 0, length: 0)
                if let local { segments.append((view, local)) }
                if view.selectTableRange(range, reporting: false), let interaction = view.tableInteraction {
                    selectedTables.append(interaction)
                }
            }
            isApplyingSelection = false
            guard let first = selectedTables.first, let owner = first.owner else { return }
            let fullText = dataSource?.selectionText(in: range) ?? currentSelection.flatMap { $0.range == range ? $0.text : nil }
            let selection = ReaderSelection(range: range, text: fullText ?? selectedTables.map { $0.selectedText() }.joined(separator: "\t"))
            let primary = segments.first ?? (owner, NSRange(location: 0, length: 0))
            programmaticSelection = (primary.0, primary.1, selection, pendingSelectionPreservesFullRange, segments)
            externalSelectionSource = first
            currentSelection = selection
            pendingSelection = nil
            pendingSelectionPreservesFullRange = false
            updateSelectionContinuation()
            scheduleSelectionReport()
            return
        }
        let segments = textViews.compactMap { view -> (view: ReaderTextView, local: NSRange)? in
            localRange(of: range, in: view).map { (view, $0) }
        }
        guard let first = segments.first else { return }
        let preservesFullRange = pendingSelectionPreservesFullRange
        pendingSelection = nil
        pendingSelectionPreservesFullRange = false
        isApplyingSelection = true
        for view in textViews {
            view.selectedRange = segments.first { $0.view === view }?.local ?? NSRange(location: 0, length: 0)
        }
        focus(first.view)
        isApplyingSelection = false
        let selection = ReaderSelection(range: range, text: text(of: range) ?? first.view.plainText(in: first.local))
        programmaticSelection = (first.view, first.local, selection, preservesFullRange, segments)
        externalSelectionSource = nil
        currentSelection = selection
        updateSelectionContinuation()
        scheduleSelectionReport()
    }

    /// Full passage text for native Copy, including the other spread column and continuation pages.
    func selectionText(for source: AnyObject) -> String? {
        if externalSelectionSource === source { return currentSelection?.text }
        if source is ReaderTableInteraction, externalSelectionSource != nil,
           textViews.contains(where: { $0.tableInteraction === source }) { return currentSelection?.text }
        guard let view = source as? ReaderTextView, textViews.contains(where: { $0 === view }) else { return nil }
        if let programmaticSelection,
           programmaticSelection.segments.contains(where: { $0.view === view && view.selectedRange == $0.local }) {
            return programmaticSelection.selection.text
        }
        // Native Copy may arrive before the debounced selection report. Resolve its current
        // source range now so case substitutions and layout separators never leak into Copy.
        guard view.selectedRange.length > 0 else { return nil }
        return selection(view.selectedRange, in: view)?.text
    }

    /// Selection in a native table-cell surface uses its precise cell source range.
    func setExternalSelection(_ selection: ReaderSelection?, source: AnyObject) {
        guard !isApplyingSelection else { return }
        if selection == nil, externalSelectionSource !== source { return }
        isApplyingSelection = true
        for view in textViews {
            if view.tableInteraction !== source { view.clearTableSelection() }
            if view.selectedRange.length > 0 { view.selectedRange = NSRange(location: view.selectedRange.location, length: 0) }
        }
        isApplyingSelection = false
        pendingSelection = nil
        programmaticSelection = nil
        externalSelectionSource = selection == nil ? nil : source
        currentSelection = selection.map { ReaderSelection(range: $0.range, text: text(of: $0.range) ?? $0.text) }
        updateSelectionContinuation()
        scheduleSelectionReport()
    }

    /// Source insertion position nearest a drag point; physical columns map in source order,
    /// including right-to-left spreads. The gutter chooses the closest column edge.
    func selectionPosition(at point: CGPoint) -> ReaderTextPosition? {
        let candidates = columns.filter { !$0.isHidden && $0.placement.visibleLength > 0 }
        guard let view = candidates.min(by: { a, b in
            func distance(_ frame: CGRect) -> CGFloat {
                let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
                let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
                return dx * dx + dy * dy
            }
            return distance(a.frame) < distance(b.frame)
        }) else { return nil }
        let local = convert(point, to: view)
        if let cell = view.tableInteraction?.selectionPosition(at: local) { return cell }
        let index = view.characterOffset(at: local)
        return position(at: min(view.placement.visibleLength, max(0, index)), in: view)
    }

    func beginSelectionDrag(at position: ReaderTextPosition) {
        selectionDragAnchor = position
        selectionDragOverridesNative = false
    }

    func extendSelectionDrag(to position: ReaderTextPosition) {
        guard let anchor = selectionDragAnchor, anchor.section == position.section else { return }
        let range = ReaderTextRange(start: min(anchor, position), end: max(anchor, position))
        guard !range.isEmpty else { return }
        selectionDragOverridesNative = true
        pendingSelection = range
        pendingSelectionPreservesFullRange = true
        applyPendingSelection()
    }

    func endSelectionDrag() { selectionDragAnchor = nil; selectionDragOverridesNative = false }

    var isDraggingSelection: Bool { selectionDragAnchor != nil }

    private func updateSelectionContinuation() {
        guard configuration.flow == .paginated, let selection = programmaticSelection?.selection,
              let visibleRange else {
            selectionContinuation?.removeFromSuperview()
            selectionContinuation = nil
            return
        }
        func continues(_ endpoint: ReaderTextPosition, forward: Bool) -> Bool {
            if let target = endpoint.tableCell {
                let visible = textViews.compactMap { $0.tableInteraction?.visibleCharacters(for: endpoint) }
                if !visible.isEmpty {
                    return forward ? visible.map(NSMaxRange).max()! < target.offset
                        : visible.map(\.location).min()! > target.offset
                }
            }
            return forward ? endpoint > visibleRange.end : endpoint < visibleRange.start
        }
        let previous = continues(selection.range.start, forward: false)
        let next = continues(selection.range.end, forward: true)
        guard previous || next else {
            selectionContinuation?.removeFromSuperview()
            selectionContinuation = nil
            return
        }
        let indicator = selectionContinuation ?? ReaderSelectionContinuation(canvas: self)
        selectionContinuation = indicator
        indicator.configure(previous: previous, next: next, theme: configuration.theme)
        indicator.frame = CGRect(x: pageArea.minX + 12, y: pageArea.maxY - 44, width: max(0, pageArea.width - 24), height: 44)
        if indicator.superview == nil { addSubview(indicator) }
        #if os(macOS)
        addSubview(indicator, positioned: .above, relativeTo: nil)
        #else
        bringSubviewToFront(indicator)
        #endif
    }

    /// A text view's selection changed, by the person or with new text.
    func textViewSelectionDidChange(_ view: ReaderTextView) {
        guard !isApplyingSelection else { return }
        // Native delegate notifications may be delivered after a coordinated update or drag
        // completes. An unchanged segment is still part of the same source selection.
        if let programmaticSelection,
           programmaticSelection.segments.contains(where: { $0.view === view }),
           programmaticSelection.segments.allSatisfy({ $0.view.selectedRange == $0.local }) { return }
        if selectionDragOverridesNative, let programmaticSelection {
            isApplyingSelection = true
            for segment in programmaticSelection.segments { segment.view.selectedRange = segment.local }
            isApplyingSelection = false
            return
        }
        externalSelectionSource = nil
        isApplyingSelection = true
        for other in textViews { other.clearTableSelection() }
        if view.isPageColumn, NSMaxRange(view.selectedRange) > view.placement.visibleLength {
            view.selectedRange = NSIntersectionRange(view.selectedRange,
                                                     NSRange(location: 0, length: view.placement.visibleLength))
        }
        if view.selectedRange.length > 0 { // One selection at a time across a spread.
            for other in textViews where other !== view && other.selectedRange.length > 0 {
                other.selectedRange = NSRange(location: other.selectedRange.location, length: 0)
            }
        }
        isApplyingSelection = false
        selectionMayHaveChanged()
    }

    /// Recomputes the selection from the text views; it is reported once it settles.
    private func selectionMayHaveChanged() {
        if externalSelectionSource != nil, currentSelection != nil { return }
        if let programmatic = programmaticSelection {
            if !programmatic.segments.isEmpty, programmatic.segments.allSatisfy({ segment in
                textViews.contains(where: { $0 === segment.view }) && segment.view.selectedRange == segment.local
            }) {
                return
            }
            programmaticSelection = nil
        }
        let selected = textViews.lazy.compactMap { view in
            view.selectedRange.length > 0 ? self.selection(view.selectedRange, in: view) : nil
        }.first
        guard selected != currentSelection else { return }
        currentSelection = selected
        updateSelectionContinuation()
        scheduleSelectionReport()
    }

    private func selection(_ range: NSRange, in view: ReaderTextView) -> ReaderSelection? {
        guard let start = position(at: range.location, in: view),
              let end = position(at: NSMaxRange(range), in: view) else { return nil }
        let sourceRange = ReaderTextRange(start: start, end: end)
        return ReaderSelection(range: sourceRange, text: text(of: sourceRange) ?? view.plainText(in: range))
    }

    private func scheduleSelectionReport() {
        selectionReport?.cancel()
        selectionReport = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.currentSelection != self.reportedSelection else { return }
            self.reportedSelection = self.currentSelection
            self.delegate?.canvas(self, didChangeSelection: self.currentSelection)
        }
    }

    /// The authored passage supplied by the session, including detached cells and section
    /// continuations. A simple data source without a semantic map still copies authored
    /// attachment words, including detached table cell maps.
    private func text(of range: ReaderTextRange) -> String? {
        if let passage = dataSource?.selectionText(in: range) { return passage }
        // A row offset is not a cell character offset. Without a semantic cell mapper the
        // rendered section cannot answer this range; retain the cell surface's own text.
        guard range.start.tableCell == nil, range.end.tableCell == nil,
              range.start.section == range.end.section,
              let text = dataSource?.text(forSection: range.start.section) else { return nil }
        return text.readerCopyPlainText(in: NSIntersectionRange(
            NSRange(location: range.start.offset, length: range.end.offset - range.start.offset),
            NSRange(location: 0, length: text.length)))
    }

    /// The person chose the host's selection action from the selection menu. The selection is
    /// reported first if it has not settled yet, so the host acts on what is selected.
    func performSelectionAction() {
        if currentSelection != reportedSelection {
            selectionReport?.cancel()
            reportedSelection = currentSelection
            delegate?.canvas(self, didChangeSelection: currentSelection)
        }
        delegate?.canvasDidRequestSelectionAction(self)
    }

    // MARK: Ranges, highlights, links

    /// The book position of one of a text view's characters.
    func position(at location: Int, in view: ReaderTextView) -> ReaderTextPosition? {
        if view === scrollTextView, let book = scrollBook { return book.position(at: location) }
        guard let section = view.placement.section else { return nil }
        return ReaderTextPosition(section: section, offset: view.placement.offset + location)
    }

    /// Where the heading of the book after `position` begins, or the one before it: where an
    /// assistive technology's move by heading goes when the page or the screen has no more
    /// (`bookHeading`).
    func heading(from position: ReaderTextPosition, forward: Bool) -> ReaderTextPosition? {
        bookHeading(from: position, forward: forward)?.position
    }

    /// The heading of the book after `position`, or the one before it. A heading is after a
    /// position it begins after and before one it ends at or before, so the heading a position
    /// is inside is neither. A section that page turns step over is passed over unless the
    /// search starts in it or it is the one on screen, and a section not built yet ends the
    /// search, as does one a page turn would wait to have built again (`canShow`), whose build
    /// is then asked for (`wantsSection`): the move that finds a heading shows it at once. From
    /// no position the search takes in every
    /// heading it can reach from the section on screen, and begins before the first of them, or
    /// after the last: the whole book once it is built, and until then the sections built so far
    /// around the reader.
    func bookHeading(from position: ReaderTextPosition?, forward: Bool) -> ReaderBookHeading? {
        guard let dataSource, dataSource.sectionCount > 0 else { return nil }
        let shown = visibleRange?.start.section
        func searched(_ section: Int) -> Bool { section == position?.section || section == shown || dataSource.isLinear(section: section) }
        func built(_ section: Int) -> Bool { dataSource.text(forSection: section) != nil && dataSource.canShow(section: section) }
        var section: Int
        if let position { section = position.section } else {
            // Back from the section on screen, against the search, through the sections built.
            section = min(max(0, shown ?? 0), dataSource.sectionCount - 1)
            let back = forward ? -1 : 1
            while section + back >= 0, section + back < dataSource.sectionCount,
                  !searched(section + back) || built(section + back) { section += back }
        }
        while section >= 0, section < dataSource.sectionCount {
            if searched(section) {
                guard built(section), let headings = headings(inSection: section) else {
                    if dataSource.text(forSection: section) != nil { delegate?.canvas(self, wantsSection: section) }
                    return nil
                }
                let found: (heading: ReaderHeading, range: NSRange)?
                if let position {
                    found = forward ? headings.first { section > position.section || $0.range.location > position.offset }
                        : headings.last { section < position.section || NSMaxRange($0.range) <= position.offset }
                } else { found = forward ? headings.first : headings.last }
                if let found { return ReaderBookHeading(heading: found.heading, section: section, range: found.range) }
            }
            section += forward ? 1 : -1
        }
        return nil
    }

    /// A section's headings, found once for each text the data source gives for it; nil while
    /// the section is not built.
    func headings(inSection section: Int) -> [(heading: ReaderHeading, range: NSRange)]? {
        guard let dataSource, section >= 0, section < dataSource.sectionCount,
              let text = dataSource.text(forSection: section) else { return nil }
        if let known = sectionHeadings[section], known.text === text { return known.headings }
        let found = SectionHeadings(text: text, headings: text.readerHeadings())
        sectionHeadings[section] = found
        return found.headings
    }

    /// A non-empty `range` in a text view's own characters, clipped to what the view shows;
    /// nil when they do not meet.
    func localRange(of range: ReaderTextRange, in view: ReaderTextView) -> NSRange? {
        if view === scrollTextView, let book = scrollBook {
            guard book.contains(section: range.start.section), book.contains(section: range.end.section) else { return nil }
            var lower = range.start
            if lower.tableCell != nil { lower.offset += 1; lower.tableCell = nil }
            let start = book.location(of: lower), end = book.location(of: range.end)
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
        guard let section = view.placement.section, range.start.section <= section, range.end.section >= section
        else { return nil }
        let start = range.start.section == section ? range.start.offset + (range.start.tableCell == nil ? 0 : 1) : 0
        let end = range.end.section == section ? range.end.offset : Int.max
        let lower = max(start, view.placement.offset)
        let upper = min(end, view.placement.offset + view.placement.visibleLength)
        return upper > lower ? NSRange(location: lower - view.placement.offset, length: upper - lower) : nil
    }

    private func applyHighlights() {
        let theme = configuration.theme
        // Search matches draw over host highlights, the current match over both.
        let ordered = ReaderHighlight.drawingOrder(highlights)
        for view in textViews {
            view.setTableHighlights(ordered)
            view.setHighlights(ordered.compactMap { highlight in
                guard let range = localRange(of: highlight.range, in: view) else { return nil }
                let color = theme.highlight(highlight.kind)
                return (range, color)
            })
        }
    }

    func activateExternalLink(_ url: URL, position: ReaderTextPosition, rect: CGRect) {
        guard let link = ReaderLink(url: url) else { return }
        delegate?.canvas(self, didActivate: link, at: position, rect: rect)
    }

    /// A link in a note's popover was activated. One outside the book goes to the session as
    /// one in the text does, from where the note hangs; one inside the book does nothing there.
    func activateNoteLink(_ url: URL) {
        guard case .external? = ReaderLink(url: url) else { return }
        activateExternalLink(url, position: visibleRange?.start ?? ReaderTextPosition(section: 0, offset: 0), rect: noteRect)
    }

    /// The question about a link outside the book was answered, by one of its buttons: true for
    /// Open. Nothing when `shown` is not the question shown, which was withdrawn or replaced.
    func answerLinkQuestion(_ open: Bool, to shown: AnyObject) {
        guard let question = linkQuestion, question.shown === shown else { return }
        linkQuestion = nil
        question.answer(open)
    }

    /// A link in a text view was activated: decode it and report where it is. Nothing is opened.
    func activateLink(_ url: URL, range: NSRange, in view: ReaderTextView) {
        guard let link = ReaderLink(url: url), let position = position(at: range.location, in: view) else { return }
        let origin = view.containerOrigin
        let frame = view.segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
        let rect = frame.isNull ? view.bounds : frame.offsetBy(dx: origin.x, dy: origin.y)
        delegate?.canvas(self, didActivate: link, at: position, rect: view.convert(rect, to: self))
    }

    /// A page-turn key, swipe, wheel tick or edge tap.
    func turnPageFromInput(forward: Bool) {
        guard imageInspector == nil, !hasSelection, !isDraggingSelection else { return }
        if turnPage(forward: forward) != .atBoundary { pageDidTurnFromTheText() }
    }

    /// A page turn an assistive technology asks for by name, as a host's command is: nothing
    /// in it could be meant for a selection, so selected text does not hold it back. False at
    /// either end of the book.
    func turnPageFromAccessibility(forward: Bool) -> Bool {
        guard imageInspector == nil, turnPage(forward: forward) != .atBoundary else { return false }
        pageDidTurnFromTheText()
        return true
    }

    /// A page turned by something done in the text, where keyboard focus and VoiceOver may be.
    private func pageDidTurnFromTheText() {
        #if os(macOS)
        focusFirstColumnAfterTurn()
        #endif
    }

    /// Text is selected in a text view on screen.
    var hasSelection: Bool { currentSelection != nil || textViews.contains { $0.selectedRange.length > 0 } }

    /// The page turn a tap or click at `point` (canvas coordinates) makes: within a configured
    /// physical edge zone in paginated flow (the left one goes back, mirrored right to
    /// left), unless it is on a link or text is selected, where the text view's own tap belongs.
    func edgeTurn(at point: CGPoint) -> Bool? {
        guard imageInspector == nil, configuration.flow == .paginated, configuration.pageControls.edgeTapsEnabled, bounds.contains(point), !hasSelection else { return nil }
        if let division = ReaderCanvasGeometry.usableDivision(configuration.division, in: bounds),
           point.x >= division.minX, point.x <= division.maxX { return nil }
        func width(_ value: CGFloat) -> CGFloat { value.isFinite ? min(bounds.width, max(0, value)) : 0 }
        let left = point.x < bounds.minX + width(configuration.pageControls.leftTapWidth)
        let right = point.x > bounds.maxX - width(configuration.pageControls.rightTapWidth)
        guard left || right else { return nil }
        if let view = columns.first(where: { !$0.isHidden && $0.frame.contains(point) }),
           (view.link(at: convert(point, to: view)) != nil || view.image(at: convert(point, to: view)) != nil) { return nil }
        return right != configuration.isRightToLeft
    }
}
