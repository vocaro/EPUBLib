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
    private var selectionReport: Task<Void, Never>?
    private var isApplyingSelection = false

    // Paginated flow.
    private(set) var spread: ReaderCanvasGeometry.Spread?
    private(set) var columns: [ReaderTextView] = []
    /// The spread on screen: its section and first page.
    private(set) var shownPage: (section: Int, page: Int)?
    private var paginators: [Int: ReaderPaginator] = [:]
    private var paginatorUse: [Int] = []
    private static let cachedPaginators = 4

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
        anchor = position ?? currentStart() ?? anchor
        anchorFollowsScroll = false
        paginators.removeAll()
        paginatorUse.removeAll()
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
        switch configuration.flow {
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
        if old.flow != configuration.flow {
            anchor = currentStart(in: old.flow) ?? anchor
            anchorFollowsScroll = false
            pendingSelection = nil
            tearDownPages()
            tearDownScroll()
            selectionMayHaveChanged()
        }
        layOutCanvas()
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
        let spread = ReaderCanvasGeometry.spread(in: pageArea, division: configuration.division,
                                                 isRightToLeft: configuration.isRightToLeft)
        guard spread != self.spread || shownPage == nil else { return }
        self.spread = spread
        displayAnchor()
        applyPendingSelection()
    }

    private func tearDownPages() {
        for column in columns { column.removeFromSuperview() }
        columns.removeAll()
        spread = nil
        shownPage = nil
    }

    /// The section's pagination at the current column size, cached for the last few sections.
    func paginator(for section: Int) -> ReaderPaginator? {
        guard let spread, let text = dataSource?.text(forSection: section) else { return nil }
        paginatorUse.removeAll { $0 == section }
        paginatorUse.append(section)
        if let cached = paginators[section], cached.text === text, cached.size == spread.columnSize { return cached }
        let paginator = ReaderPaginator(text: text, size: spread.columnSize)
        paginators[section] = paginator
        while paginatorUse.count > Self.cachedPaginators { paginators[paginatorUse.removeFirst()] = nil }
        return paginator
    }

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
            let height = page.layoutEnd > page.range.upperBound ? page.height : max(page.height, frame.maxY - top)
            column.isHidden = false
            column.frame = CGRect(x: frame.minX, y: top, width: frame.width, height: height)
            column.readerContainer.size = CGSize(width: frame.width, height: 0)
            column.readerContainer.viewportSize = spread.columnSize
            column.placement = ReaderTextPlacement(section: section, offset: page.range.location,
                                                   visibleLength: page.range.length)
            column.setContent(paginator.text(for: page))
            column.ensureFullLayout()
        }
        isApplyingSelection = false
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
        if let geometry = scrollGeometry, geometry.bounds == bounds, geometry.minX == column.minX,
           geometry.width == column.width { return }
        if !created, anchorFollowsScroll, let start = scrollVisibleRange()?.start { anchor = start }
        scrollGeometry = (bounds, column.minX, column.width)
        withProgrammaticScroll { applyScrollGeometry(columnMinX: column.minX, width: column.width) }
        if created { loadScrollContent() }
        scrollToAnchor()
        updateVisibleRange(force: created)
        if created { applyPendingSelection() }
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
        if let book = dataSource?.bookText {
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
        if scrollBook == nil, dataSource?.bookText != nil || textView.placement.section != anchor.section {
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
        currentSelection = ReaderSelection(range: range, text: text(of: range) ?? view.string(in: local))
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
        return ReaderSelection(range: ReaderTextRange(start: start, end: end), text: view.string(in: range))
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
        let bounded = NSIntersectionRange(NSRange(location: range.start.offset, length: range.end.offset - range.start.offset),
                                          NSRange(location: 0, length: text.length))
        return (text.string as NSString).substring(with: bounded)
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

    /// A page-turn key, swipe or wheel tick.
    func turnPageFromInput(forward: Bool) {
        _ = turnPage(forward: forward)
    }
}
