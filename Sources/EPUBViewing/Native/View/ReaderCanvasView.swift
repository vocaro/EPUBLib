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
/// Each holds only its own page's text, so selection, links and VoiceOver are native and stay on
/// the page, and its layout is small enough to be exact. Continuous scroll is one real scroll
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
    private var highlights: [ReaderHighlight] = []
    private var reportedSelection: ReaderSelection?
    /// The selection `show(_:selecting:)` made, which may run past the page it is selected on:
    /// reported as given while the text view still holds it.
    private var programmaticSelection: (view: ReaderTextView, local: NSRange, selection: ReaderSelection)?
    private var selectionReport: Task<Void, Never>?
    private var isApplyingSelection = false

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

    // Continuous scroll.
    private(set) var scrollContainer: PlatformView?
    private(set) var scrollTextView: ReaderTextView?
    /// The whole book, when the scroll view shows it.
    private(set) var scrollBook: ReaderBookText?
    private var scrollGeometry: (bounds: CGRect, minX: CGFloat, width: CGFloat)?
    /// The person scrolled since the anchor was set, so the visible start replaces it.
    private var anchorFollowsScroll = false
    private var isScrollingProgrammatically = false
    private var scrollReportPending = false

    var wheelTurner = ReaderWheelPageTurner()
    var presentedNote: AnyObject?
    /// Where and when the last touch or click on the canvas began, for edge taps.
    var pointerDown: (location: CGPoint, time: TimeInterval)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        platformSetUp()
        applyAppearance()
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
        selectionMayHaveChanged()
    }

    func show(_ position: ReaderTextPosition, selecting range: ReaderTextRange?) {
        settleLayout()
        anchor = position
        anchorFollowsScroll = false
        pendingSelection = range.flatMap { $0.isEmpty ? nil : $0 }
        switch configuration.flow {
        case .paginated:
            if spread == nil { layOutCanvas() } else { displayAnchor() }
        case .scrolled:
            if scrollTextView == nil { layOutCanvas() } else { showInScroll() }
        }
        applyPendingSelection()
    }

    func turnPage(forward: Bool) -> PageTurnResult {
        settleLayout()
        return switch configuration.flow {
        case .paginated: turnPaginatedPage(forward: forward)
        case .scrolled: turnScrolledPage(forward: forward)
        }
    }

    func clearSelection() {
        pendingSelection = nil
        isApplyingSelection = true
        for view in textViews where view.selectedRange.length > 0 {
            view.selectedRange = NSRange(location: view.selectedRange.location, length: 0)
        }
        isApplyingSelection = false
        programmaticSelection = nil
        currentSelection = nil
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
        switch configuration.flow {
        case .paginated: layOutPages()
        case .scrolled: layOutScroll()
        }
    }

    private func configurationDidChange(from old: ReaderCanvasConfiguration) {
        if old.isDark != configuration.isDark {
            applyAppearance()
            applyHighlights()
        }
        guard old.flow != configuration.flow || old.division != configuration.division
                || old.isRightToLeft != configuration.isRightToLeft else { return }
        guard old.flow != configuration.flow else { return layOutCanvas() }
        anchor = currentStart(in: old.flow) ?? anchor
        anchorFollowsScroll = false
        pendingSelection = nil
        // The text views go; keyboard focus must not go with them.
        let hadFocus = hasKeyboardFocus
        tearDownPages()
        tearDownScroll()
        selectionMayHaveChanged()
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
        guard let range else { return }
        let changed = range != visibleRange
        visibleRange = range
        if force || changed { delegate?.canvas(self, didShow: range, sectionProgress: progress(of: range.start)) }
    }

    // MARK: Paginated flow

    private func layOutPages() {
        let target = ReaderCanvasGeometry.spread(in: pageArea, division: configuration.division,
                                                 isRightToLeft: configuration.isRightToLeft)
        guard let spread, shownPage != nil else {
            cancelPendingSpread()
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
        spread = target
        displayAnchor()
        applyPendingSelection()
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
        for column in columns { column.removeFromSuperview() }
        columns.removeAll()
        spread = nil
        shownPage = nil
    }

    /// A section's pagination at a column size (the spread's by default), cached by both.
    func paginator(for section: Int, size: CGSize? = nil) -> ReaderPaginator? {
        guard let size = size ?? spread?.columnSize, let text = dataSource?.text(forSection: section) else { return nil }
        let key = PaginatorKey(section: section, width: size.width, height: size.height)
        paginatorUse.removeAll { $0 == key }
        paginatorUse.append(key)
        if let cached = paginators[key], cached.text === text { return cached }
        let paginator = ReaderPaginator(text: text, size: size)
        paginators[key] = paginator
        trimPaginators()
        return paginator
    }

    /// The paginator of the spread on screen, never trimmed.
    private var shownPaginatorKey: PaginatorKey? {
        guard let shownPage, let size = spread?.columnSize else { return nil }
        return PaginatorKey(section: shownPage.section, width: size.width, height: size.height)
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
    }

    var cachedPaginatorCount: Int { paginators.count }
    var heldPaginatorLayout: Int { paginators.values.reduce(0) { $0 + $1.heldLayoutLength } }

    /// Shows the spread holding the anchor.
    private func displayAnchor() {
        guard let anchor, let spread, spread.columnSize.width > 0, let paginator = paginator(for: anchor.section)
        else { return }
        let page = paginator.pageIndex(containing: anchor.offset)
        display(section: anchor.section, firstPage: page - page % spread.columns.count)
    }

    private func display(section: Int, firstPage: Int) {
        guard let spread, let paginator = paginator(for: section) else { return }
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
            let clips = page.layoutEnd > page.range.upperBound || page.filler > 0
            column.isHidden = false
            column.frame = CGRect(x: frame.minX, y: top, width: frame.width,
                                  height: clips ? page.height : max(page.height, frame.maxY - top))
            column.readerContainer.size = CGSize(width: frame.width, height: 0)
            column.readerContainer.viewportSize = spread.columnSize
            column.placement = ReaderTextPlacement(section: section, offset: page.range.location,
                                                   visibleLength: page.range.length)
            column.setContent(paginator.text(for: page))
            column.ensureFullLayout()
            // Should the page's own layout run longer than the section's (a long justified
            // paragraph's tail mid-page), show all of it rather than clip a line.
            if clips, page.range.length > 0, let last = column.lineFrame(containing: page.range.length - 1),
               last.maxY > column.frame.height + 0.5 {
                column.frame.size.height = min(last.maxY, frame.maxY - top)
            }
        }
        isApplyingSelection = false
        trimPaginators()
        applyHighlights()
        updateVisibleRange(force: true)
        selectionMayHaveChanged()
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
        guard let text = dataSource.text(forSection: next) else {
            delegate?.canvas(self, needsSection: next, forward: forward)
            return .pending(section: next)
        }
        show(ReaderTextPosition(section: next, offset: forward ? 0 : text.length), selecting: nil)
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
        let area = pageArea
        let column = ReaderCanvasGeometry.scrollColumn(
            in: CGRect(x: area.minX, y: bounds.minY, width: area.width, height: bounds.height),
            division: configuration.division)
        defer { updateScrollViewport() }
        if let geometry = scrollGeometry, geometry.bounds == bounds, geometry.minX == column.minX,
           geometry.width == column.width { return }
        if !created, anchorFollowsScroll, let start = scrollVisibleRange()?.start { anchor = start }
        scrollGeometry = (bounds, column.minX, column.width)
        withProgrammaticScroll { applyScrollGeometry(columnMinX: column.minX, width: column.width) }
        updateScrollViewport()
        if created { loadScrollContent() }
        scrollToAnchor()
        updateVisibleRange(force: created)
        if created { applyPendingSelection() }
    }

    /// Keeps the viewport attachments size against current, the visible height included (it
    /// changes with the safe area alone). Text already laid out keeps its size; a new column
    /// width relays everything out anyway.
    private func updateScrollViewport() {
        guard let textView = scrollTextView, let geometry = scrollGeometry else { return }
        let viewport = CGSize(width: geometry.width, height: max(0, scrollVisibleContainerRect.height))
        if textView.readerContainer.viewportSize != viewport { textView.readerContainer.viewportSize = viewport }
    }

    private func tearDownScroll() {
        scrollContainer?.removeFromSuperview()
        scrollContainer = nil
        scrollTextView = nil
        scrollBook = nil
        scrollGeometry = nil
    }

    /// Puts the whole book in the scroll view when the data source has it, else the anchor's section.
    private func loadScrollContent() {
        guard let textView = scrollTextView else { return }
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
        isApplyingSelection = true
        textView.placement = content.placement
        withProgrammaticScroll { textView.setContent(content.text) }
        isApplyingSelection = false
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
        updateVisibleRange(force: true)
    }

    /// Scrolls the anchor to the top of the visible area (a section's end to the bottom).
    private func scrollToAnchor() {
        guard let textView = scrollTextView, let anchor else { return }
        let location: Int
        if let book = scrollBook {
            location = book.location(of: anchor)
        } else if textView.placement.section == anchor.section {
            location = anchor.offset
        } else { return }
        withProgrammaticScroll {
            if scrollBook == nil, location >= textView.textLength {
                return scrollToContainerY(.greatestFiniteMagnitude)
            }
            // Laying out the viewport replaces estimated positions above it, which can move the
            // line; follow it until it stays put.
            var previous: CGFloat?
            for _ in 0..<4 {
                guard let line = textView.lineFrame(containing: location) else { break }
                if let previous, abs(previous - line.minY) < 0.5 { break }
                scrollToContainerY(line.minY)
                previous = line.minY
            }
        }
        anchorFollowsScroll = false
    }

    private func withProgrammaticScroll(_ body: () -> Void) {
        let wasScrolling = isScrollingProgrammatically
        isScrollingProgrammatically = true
        body()
        isScrollingProgrammatically = wasScrolling
    }

    /// The platform scroll view moved; reports the visible range at most every 150 ms.
    func scrollPositionDidChange() {
        guard !isScrollingProgrammatically else { return }
        anchorFollowsScroll = true
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

    /// The first and last characters in the visible area (not under the bars).
    private func scrollVisibleRange() -> ReaderTextRange? {
        guard let textView = scrollTextView, scrollBook != nil || textView.placement.section != nil else { return nil }
        let rect = scrollVisibleContainerRect
        let start = textView.lineBoundary(atContainerY: rect.minY, lineEnd: false)
        let end = max(start, textView.lineBoundary(atContainerY: rect.maxY, lineEnd: true))
        if let book = scrollBook {
            return ReaderTextRange(start: book.position(at: start), end: book.position(at: end))
        }
        guard let section = textView.placement.section else { return nil }
        return ReaderTextRange(section: section, start..<end)
    }

    private func turnScrolledPage(forward: Bool) -> PageTurnResult {
        guard let textView = scrollTextView else { return .atBoundary }
        guard forward ? isScrolledToEnd : isScrolledToStart else {
            let visible = scrollVisibleContainerRect
            let start = textView.lineBoundary(atContainerY: visible.minY, lineEnd: false)
            let line = textView.lineFrame(containing: start)?.height ?? 20
            let step = max(line, visible.height - line)
            withProgrammaticScroll { scrollToContainerY(visible.minY + (forward ? step : -step)) }
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
        guard let range = pendingSelection,
              let view = textViews.first(where: { localRange(of: range, in: $0) != nil }),
              let local = localRange(of: range, in: view) else { return }
        pendingSelection = nil
        isApplyingSelection = true
        for other in textViews where other !== view { other.selectedRange = NSRange(location: 0, length: 0) }
        focus(view)
        view.selectedRange = local
        isApplyingSelection = false
        let selection = ReaderSelection(range: range, text: text(of: range) ?? view.plainText(in: local))
        programmaticSelection = (view, local, selection)
        currentSelection = selection
        scheduleSelectionReport()
    }

    /// A text view's selection changed, by the person or with new text.
    func textViewSelectionDidChange(_ view: ReaderTextView) {
        guard !isApplyingSelection else { return }
        isApplyingSelection = true
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
        if let programmatic = programmaticSelection {
            if textViews.contains(where: { $0 === programmatic.view }), programmatic.view.selectedRange == programmatic.local {
                return
            }
            programmaticSelection = nil
        }
        let selected = textViews.lazy.compactMap { view in
            view.selectedRange.length > 0 ? self.selection(view.selectedRange, in: view) : nil
        }.first
        guard selected != currentSelection else { return }
        currentSelection = selected
        scheduleSelectionReport()
    }

    private func selection(_ range: NSRange, in view: ReaderTextView) -> ReaderSelection? {
        guard let start = position(at: range.location, in: view),
              let end = position(at: NSMaxRange(range), in: view) else { return nil }
        return ReaderSelection(range: ReaderTextRange(start: start, end: end), text: view.plainText(in: range))
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

    /// The text of a range within one section; nil across sections.
    private func text(of range: ReaderTextRange) -> String? {
        guard range.start.section == range.end.section,
              let text = dataSource?.text(forSection: range.start.section) else { return nil }
        return text.readerPlainText(in: NSIntersectionRange(
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

    /// A non-empty `range` in a text view's own characters, clipped to what the view shows;
    /// nil when they do not meet.
    func localRange(of range: ReaderTextRange, in view: ReaderTextView) -> NSRange? {
        if view === scrollTextView, let book = scrollBook {
            guard book.contains(section: range.start.section), book.contains(section: range.end.section) else { return nil }
            let start = book.location(of: range.start), end = book.location(of: range.end)
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
        guard let section = view.placement.section, range.start.section <= section, range.end.section >= section
        else { return nil }
        let start = range.start.section == section ? range.start.offset : 0
        let end = range.end.section == section ? range.end.offset : Int.max
        let lower = max(start, view.placement.offset)
        let upper = min(end, view.placement.offset + view.placement.visibleLength)
        return upper > lower ? NSRange(location: lower - view.placement.offset, length: upper - lower) : nil
    }

    private func applyHighlights() {
        let dark = configuration.isDark
        // Search matches draw over host highlights.
        let ordered = highlights.filter { $0.kind == .annotation } + highlights.filter { $0.kind == .search }
        for view in textViews {
            view.setHighlights(ordered.compactMap { highlight in
                guard let range = localRange(of: highlight.range, in: view) else { return nil }
                let color = highlight.kind == .search ? ReaderPalette.searchHighlight(dark: dark)
                    : ReaderPalette.annotationHighlight(dark: dark)
                return (range, color)
            })
        }
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
        _ = turnPage(forward: forward)
    }

    /// Text is selected in a text view on screen.
    var hasSelection: Bool { textViews.contains { $0.selectedRange.length > 0 } }

    /// The width of the paginated tap zones at the left and right edges.
    static let edgeZoneWidth: CGFloat = 56

    /// The page turn a tap or click at `point` (canvas coordinates) makes: within 56 points of
    /// the left or right edge in paginated flow (the left one goes back, mirrored right to
    /// left), unless it is on a link or text is selected, where the text view's own tap belongs.
    func edgeTurn(at point: CGPoint) -> Bool? {
        guard configuration.flow == .paginated, bounds.contains(point), !hasSelection else { return nil }
        let left = point.x < bounds.minX + Self.edgeZoneWidth, right = point.x > bounds.maxX - Self.edgeZoneWidth
        guard left || right else { return nil }
        if let view = columns.first(where: { !$0.isHidden && $0.frame.contains(point) }),
           view.link(at: convert(point, to: view)) != nil { return nil }
        return right != configuration.isRightToLeft
    }
}
