#if os(macOS)
import AppKit

// AppKit views, input, menus and popovers for `ReaderCanvasView`.
extension ReaderCanvasView: NSTextViewDelegate {
    func platformSetUp() {
        wantsLayer = true
        clipsToBounds = true // A spread kept through a live resize never draws outside the canvas.
        // AppKit does not mark a view as needing layout when its safe area changes and its size
        // does not, as when a toolbar is shown, hidden or made compact over a full-size content
        // view; a scroll view with automatic insets marks only itself. It does tell whoever
        // observes the view's `safeAreaInsets` (macOS 27.2), as UIKit calls
        // `safeAreaInsetsDidChange`. The pages keep clear of the new top at once, and in
        // continuous scroll the layout brings the scroll view's automatic insets with it, so
        // the text is laid out for the height that shows (#162).
        safeAreaObservation = observe(\.safeAreaInsets) { canvas, _ in
            MainActor.assumeIsolated { canvas.needsLayout = true }
        }
        ReaderMemoryPressure.start()
        NotificationCenter.default.addObserver(self, selector: #selector(memoryPressure(_:)),
                                               name: ReaderMemoryPressure.notification, object: nil)
    }

    func updateInputHandlers() {} // AppKit handlers read live configuration.

    @objc private func memoryPressure(_ notification: Notification) { trimCaches() }

    // A live resize keeps the spread on screen and paginates once, at its end.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        beginDeferringLayout()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        endDeferringLayout()
    }

    func applyAppearance() {
        let theme = configuration.theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        layer?.backgroundColor = theme.background.cgColor
        (scrollContainer as? NSScrollView)?.backgroundColor = theme.background
        for view in textViews { view.selectedTextAttributes = Self.selectedTextAttributes(theme) }
    }

    /// The theme's selection behind selected text, whose own colours stay: AppKit's would draw
    /// the system's selection colour, and its selected text colour over the theme's.
    static func selectedTextAttributes(_ theme: ReaderTheme) -> [NSAttributedString.Key: Any] {
        [.backgroundColor: theme.selection]
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layOutCanvas()
    }

    /// Paginated pages keep clear of a full-size content view's toolbar.
    var pageArea: CGRect { safeAreaRect }

    func makeColumnView() -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.delegate = self
        view.selectedTextAttributes = Self.selectedTextAttributes(configuration.theme)
        addSubview(view)
        return view
    }

    /// A column that draws a page a swipe brings in, which nothing reads or touches.
    func makePreviewColumn() -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        return view
    }

    /// A picture of the page on screen as it is drawn: each shown column's, where it stands on
    /// the canvas, drawn again into a bitmap of the window's scale. nil while nothing is shown.
    func pageSnapshot() -> PlatformView? {
        let shown = columns.filter { !$0.isHidden }
        guard !shown.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        let picture = ReaderPageTransitionView(frame: bounds)
        for column in shown {
            guard let bitmap = column.bitmapImageRepForCachingDisplay(in: column.bounds) else { return nil }
            column.cacheDisplay(in: column.bounds, to: bitmap)
            let image = NSImage(size: column.bounds.size)
            image.addRepresentation(bitmap)
            let view = NSImageView(frame: column.frame)
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            view.setAccessibilityElement(false)
            picture.addSubview(view)
        }
        return picture
    }

    /// Puts what a page turn draws above the columns, and below what stands over the page: the
    /// selection's continuation and the image inspector.
    func addPageTransitionView(_ view: PlatformView) {
        view.frame = bounds
        let top = subviews.last { subview in columns.contains { $0 === subview } }
        addSubview(view, positioned: .above, relativeTo: top)
    }

    func makeScrollView() -> (PlatformView, ReaderTextView) {
        let scrollView = ReaderScrollView(frame: bounds)
        scrollView.canvas = self
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = configuration.theme.background
        scrollView.automaticallyAdjustsContentInsets = true
        let textView = ReaderTextView(pageColumn: false)
        textView.delegate = self
        textView.selectedTextAttributes = Self.selectedTextAttributes(configuration.theme)
        textView.frame = CGRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewportDidChange(_:)),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
        return (scrollView, textView)
    }

    @objc private func scrollBoundsDidChange(_ notification: Notification) {
        guard (notification.object as? NSClipView)?.documentView === scrollTextView else { return }
        // Nobody scrolled when the text view moved itself, or was put back (`holdingScrollPlace`).
        scrollPositionDidChange(byReader: scrollTextView?.isEndingLiveResize == true)
    }

    @objc private func scrollViewportDidChange(_ notification: Notification) {
        // A legacy scroller can appear after the document is loaded, or the person can
        // change their system scroller preference without resizing the reader window.
        if (notification.object as? NSClipView)?.documentView === scrollTextView { needsLayout = true }
    }

    private var scrollView: NSScrollView? { scrollContainer as? NSScrollView }

    /// A legacy scroller occupies document width. Derive the wrapping column from the clip
    /// view's actual horizontal extent, retaining the reader's safe area inside that extent.
    func scrollColumnArea() -> CGRect {
        guard let scrollView else { return pageArea }
        scrollView.frame = bounds
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.convert(scrollView.contentView.frame, to: self)
        let area = pageArea
        let left = max(area.minX, clip.minX)
        return CGRect(x: left, y: area.minY, width: max(0, min(area.maxX, clip.maxX) - left), height: area.height)
    }

    /// Sizes the scroll view to the canvas and places the text column, which a division can move
    /// off centre (`ReaderTextView.columnMinX`).
    func applyScrollGeometry(columnMinX: CGFloat, width: CGFloat) {
        guard let scrollView, let textView = scrollTextView else { return }
        scrollView.frame = bounds
        textView.frame.size.width = scrollView.contentSize.width
        textView.columnMinX = textView.convert(CGPoint(x: columnMinX, y: bounds.minY), from: self).x
        if textView.readerContainer.size.width != width {
            textView.readerContainer.size = CGSize(width: width, height: 0)
            scrollPlace = nil // Every line moves with the wrapping.
        }
        textView.invalidateTextContainerOrigin()
        scrollView.layoutSubtreeIfNeeded()
    }

    /// The scroll view's visible text area in text container coordinates: below the toolbar and
    /// the text view's top margin (where a shown position rests), above the bottom inset.
    var scrollVisibleContainerRect: CGRect {
        guard let scrollView, let textView = scrollTextView else { return .zero }
        let insets = scrollView.contentInsets
        let clip = scrollView.contentView.bounds
        let origin = textView.textContainerOrigin
        let top = clip.minY + insets.top + ReaderCanvasGeometry.verticalMargin
        return CGRect(x: 0, y: top - origin.y, width: textView.readerContainer.size.width,
                      height: max(0, clip.height - insets.top - insets.bottom - ReaderCanvasGeometry.verticalMargin))
    }

    /// Scrolls so container `y` is at the top of the visible text area, within the document.
    func scrollToContainerY(_ y: CGFloat) {
        guard let scrollView, let textView = scrollTextView else { return }
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let target = y + textView.textContainerOrigin.y - insets.top - ReaderCanvasGeometry.verticalMargin
        // Where the reader places the lines itself (box geometry), TextKit 2 gives the text it has
        // not laid out no height, and the document ends at the last line laid out: a page turn
        // stopped there, short by a different amount each time (#369). So the screen a target
        // below that opens is laid out first, and for a section's end the rest of the text.
        if textView.readerContainer.hasNonlinearGeometry, target > maximumScrollOffset {
            let visible = scrollVisibleContainerRect
            textView.readerLayoutManager.ensureLayout(for: CGRect(x: 0, y: y, width: visible.width, height: visible.height))
        }
        // TextKit 2 grows the document as it lays out; make room for what was just laid out.
        let used = textView.readerLayoutManager.usageBoundsForTextContainer.maxY + 2 * textView.textContainerInset.height
        if textView.frame.height < used { textView.setFrameSize(NSSize(width: textView.frame.width, height: ceil(used))) }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(-insets.top, target), maximumScrollOffset)))
        scrollView.reflectScrolledClipView(clip)
        textView.readerLayoutManager.textViewportLayoutController.layoutViewport()
    }

    /// Keeps the text on screen in place, before the screen is read or stepped from. AppKit
    /// draws the viewport from the layout as it stands. Once the text above has been laid out
    /// behind the view, which an assistive technology asking where a far range is does, the
    /// estimates that placed the visible lines are gone, and the next scroll would draw whatever
    /// the finished layout has at the old offset, a chapter away. While the view has not moved
    /// since it was last read, this scrolls it by as much as the first line on screen has moved:
    /// the line goes back as far below the top of the visible area as it stood. Straight after
    /// the layout that moved it, the document can still be as tall as it was, which stops the
    /// scroll short of a line near its end. The viewport laid out where the scroll stopped
    /// gives the document its height, and the next pass has room. The rows on screen keep
    /// their cells throughout (`scrollPositionDidChange`), which then go where the rows stand.
    func settleScrollViewport() {
        guard let place = scrollPlace, scrollViewStandsWhereRead, let textView = scrollTextView,
              var line = textView.lineFrame(containing: place.location), abs(line.minY - place.lineTop) > 0.5 else { return }
        let below = place.lineTop - place.visibleTop
        isHoldingScrollPlace = true
        for _ in 0..<8 {
            let stood = scrollVisibleContainerRect.minY
            scrollToContainerY(line.minY - below)
            guard let moved = textView.lineFrame(containing: place.location) else { break }
            line = moved
            if abs(line.minY - below - scrollVisibleContainerRect.minY) <= 0.5 || abs(scrollVisibleContainerRect.minY - stood) < 0.5 { break }
        }
        isHoldingScrollPlace = false
        scrollPlace = (place.location, line.minY, scrollVisibleContainerRect.minY)
        refreshScrollTables()
    }

    /// Runs `scroll`, in which AppKit moves the scroll view by itself, and puts the view back
    /// where it stood: at the offset it had, and then with its first line where that line was,
    /// should the layout AppKit's scroll made have moved it. The view is as it was before
    /// anything is drawn, and the position the reader keeps is the one it kept before.
    func holdingScrollPlace(through scroll: () -> Void) {
        guard scrollVisibleCharacters() != nil, let place = scrollPlace else { return scroll() }
        scroll()
        scrollToContainerY(place.visibleTop)
        settleScrollViewport()
    }

    private var maximumScrollOffset: CGFloat {
        guard let scrollView, let textView = scrollTextView else { return 0 }
        let insets = scrollView.contentInsets
        return max(-insets.top, textView.frame.height + insets.bottom - scrollView.contentView.bounds.height)
    }

    var isScrolledToStart: Bool {
        guard let scrollView else { return true }
        return scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top + 1
    }

    var isScrolledToEnd: Bool {
        guard let scrollView else { return true }
        return scrollView.contentView.bounds.minY >= maximumScrollOffset - 1
    }

    /// Gives keyboard focus to a text view, or the canvas.
    func focus(_ view: ReaderTextView?) {
        guard let window else { return }
        let responder: NSView = view ?? self
        if window.firstResponder !== responder { window.makeFirstResponder(responder) }
    }

    var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Brings keyboard focus to the first column of the spread after a page turn made from
    /// another one. VoiceOver stays in the column it is in when the spread turns: after a key
    /// or a page action in the second column it was on the first line of the new second
    /// column, and the new first column was passed over. VoiceOver follows keyboard focus, and
    /// reads the first column from its first word. Focus anywhere else is left alone.
    func focusFirstColumnAfterTurn() {
        guard let first = textViews.first, let responder = window?.firstResponder as? ReaderTextView,
              responder !== first, columns.contains(where: { $0 === responder }) else { return }
        focus(first)
    }

    /// The page column that has keyboard focus, itself or in a table cell's text area it holds.
    var focusedColumn: ReaderTextView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return columns.first { responder === $0 || responder.isDescendant(of: $0) }
    }

    /// Keeps keyboard focus in the reader when the spread just installed hides `column`, which
    /// had it (`focusedColumn`): a relayout to fewer columns, as a window narrowed from two
    /// columns to one, or a turn to a spread of one page. AppKit takes the focus from a view it
    /// hides, and the window had it then, so VoiceOver, which stays in the column that has the
    /// focus, had no column to stay in (#599). The first column shown takes it, as after a
    /// turn (`focusFirstColumnAfterTurn`), and a place entered takes it on to its own column
    /// (`enterPage`). Focus that was anywhere else is left where it is.
    func keepFocus(from column: ReaderTextView?) {
        guard let column, column.isHidden else { return }
        focus(textViews.first)
    }

    // MARK: Text view delegate

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = notification.object as? ReaderTextView else { return }
        textViewSelectionDidChange(view)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let view = textView as? ReaderTextView,
              let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }),
              let storage = view.contentStorage.textStorage, charIndex < storage.length else { return true }
        var range = NSRange(location: charIndex, length: 1)
        _ = storage.attribute(.link, at: charIndex, longestEffectiveRange: &range,
                              in: NSRange(location: 0, length: storage.length))
        activateLink(url, range: range, in: view)
        return true
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let title = configuration.selectionActionTitle, view.selectedRange.length > 0 else { return menu }
        let item = NSMenuItem(title: title, action: #selector(selectionActionChosen(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: configuration.selectionActionImage, accessibilityDescription: nil)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc func selectionActionChosen(_ sender: Any?) {
        performSelectionAction()
    }

    // MARK: Headings for VoiceOver

    /// What a page column's Headings rotor answers: the heading of the book after or before
    /// where the search stands (`headingSearchPosition`), and none past either end
    /// (`bookHeading`). A heading that begins on the page or spread is given as its column
    /// and its characters there. Any other is given as a token for its place in the book,
    /// which the reader turns to only when VoiceOver moves to it (`loadHeading`): the search
    /// itself shows nothing, since VoiceOver walks the whole list when its rotor opens.
    ///
    /// A token's result also carries a range, the heading's characters in its section.
    /// VoiceOver asks nothing of it, and takes the heading's place from the loading delegate
    /// once it has the column. But it calls the heading by its label in the rotor's list only
    /// when the result has a range: without one it showed the label and read the row out as
    /// the column's own text, "text" and the page's words, for every such row (macOS 27.0.1).
    func headingRotorResult(for parameters: NSAccessibilityCustomRotor.SearchParameters,
                            askedOf column: ReaderTextView) -> NSAccessibilityCustomRotor.ItemResult? {
        let forward = parameters.searchDirection == .next
        let filter = parameters.filterString
        var from = headingSearchPosition(of: parameters.currentItem, askedOf: column, forward: forward)
        while let found = bookHeading(from: from, forward: forward) {
            from = found.position
            guard let text = dataSource?.text(forSection: found.section),
                  let label = ReaderTextView.headingLabel(text.readerPlainText(in: found.range, spoken: true), level: found.heading.level),
                  filter.isEmpty || label.localizedCaseInsensitiveContains(filter) else { continue }
            let shown = shownHeading(found)
            let result = shown.map { NSAccessibilityCustomRotor.ItemResult(targetElement: $0.view) }
                ?? NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: Self.headingToken(found.position), customLabel: label)
            result.targetRange = shown?.range ?? found.range
            result.customLabel = label
            return result
        }
        return nil
    }

    /// Where a search from `item` stands in the book, and nil from nowhere. VoiceOver asks
    /// from one of four items (macOS 27.0.1):
    /// - No element and no token, at the first character and none of it. That is nowhere, and
    ///   is how it begins its walk of the rotor's list, which then goes on from each item it
    ///   is given: the list is the whole book's.
    /// - A token, with no element: a heading it was given on another page.
    /// - A column and characters: a heading it was given on the page, or its cursor's line.
    /// - A column, at the first character and none of it: its cursor resting on the column
    ///   with no place in it yet, as after a page turn. The search then stands at the page's
    ///   edge, before its first character or going back after its last, so that a heading
    ///   which opens the page is the next one. VoiceOver opens the rotor's list on that
    ///   answer. Taken for nowhere it was the book's first heading, and a move to the next
    ///   heading from a page in the middle of a book went back to the book's start.
    private func headingSearchPosition(of item: NSAccessibilityCustomRotor.ItemResult?, askedOf column: ReaderTextView,
                                       forward: Bool) -> ReaderTextPosition? {
        guard let item else { return nil }
        if let token = item.itemLoadingToken, let position = Self.headingPosition(of: token) { return position }
        guard item.targetElement != nil else { return nil }
        let view = (item.targetElement as? ReaderTextView).flatMap { $0.canvas === self ? $0 : nil } ?? column
        let range = item.targetRange
        if range.location == NSNotFound || range == NSRange(location: 0, length: 0) {
            guard let edge = position(at: forward ? 0 : view.shownCharacters.length, in: view) else { return nil }
            return forward ? ReaderTextPosition(section: edge.section, offset: edge.offset - 1) : edge
        }
        return position(at: range.location, in: view)
    }

    /// The column that shows where `heading` begins, and its characters there.
    private func shownHeading(_ heading: ReaderBookHeading) -> (view: ReaderTextView, range: NSRange)? {
        let whole = ReaderTextRange(section: heading.section, heading.range.location..<NSMaxRange(heading.range))
        for view in textViews where view.isPageColumn {
            if let local = localRange(of: whole, in: view), view.placement.offset + local.location == heading.range.location { return (view, local) }
        }
        return nil
    }

    /// The heading `token` names, when one still begins there.
    private func heading(for token: any NSAccessibilityLoadingToken) -> ReaderBookHeading? {
        Self.headingPosition(of: token).flatMap(heading(at:))
    }

    /// The heading that begins at `position`, when one still does, in a section a page turn
    /// would show as it is built; for one it would not, its build is asked for (`bookHeading`).
    private func heading(at position: ReaderTextPosition) -> ReaderBookHeading? {
        if dataSource?.canShow(section: position.section) == false {
            delegate?.canvas(self, wantsSection: position.section)
            return nil
        }
        guard let found = headings(inSection: position.section)?.first(where: { $0.range.location == position.offset }) else { return nil }
        return ReaderBookHeading(heading: found.heading, section: position.section, range: found.range)
    }

    /// VoiceOver moves to a heading it was given as a token: the reader turns to the
    /// heading's page, and this is the column that then shows it. VoiceOver asks when the
    /// heading is chosen from the rotor's list or reached by its move to the next heading,
    /// and not while it lists the rotor's items.
    func loadHeading(_ token: any NSAccessibilityLoadingToken) -> ReaderTextView? {
        guard let heading = heading(for: token) else { return nil }
        // VoiceOver takes its cursor to the heading's characters itself (`loadedHeadingRange`).
        if shownHeading(heading) == nil { show(heading.position, selecting: nil, entry: .firstLine) }
        return shownHeading(heading)?.view
    }

    /// The characters of the heading `token` names in the column that shows it. VoiceOver
    /// asks straight after it has had the column, so nothing is shown for this.
    func loadedHeadingRange(_ token: any NSAccessibilityLoadingToken) -> NSRange? {
        heading(for: token).flatMap(shownHeading)?.range
    }

    /// The book's next heading after the page `column` shows, with its words: the one a
    /// column gives last among its children, for VoiceOver to find from a link on the page
    /// (`ReaderTextView.headingChildren`). One that begins on the page is the column's own,
    /// and a heading without words is passed over, as in the rotor. None past the book's last
    /// heading, and none where a chapter is not built yet (`bookHeading`).
    func headingAfterPage(of column: ReaderTextView) -> (heading: ReaderBookHeading, words: String)? {
        guard column.isPageColumn, column.shownCharacters.length > 0,
              var from = position(at: column.shownCharacters.length - 1, in: column) else { return nil }
        while let found = bookHeading(from: from, forward: true) {
            from = found.position
            guard let text = dataSource?.text(forSection: found.section) else { return nil }
            let words = text.readerPlainText(in: found.range, spoken: true).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !words.isEmpty { return (found, words) }
        }
        return nil
    }

    /// VoiceOver has moved to the element of the heading that begins at `position`, which a
    /// column gave as the next one after its page: the reader turns to the heading's page,
    /// unless a column shows it already, and this is the column that shows it and the
    /// heading's characters there.
    func showHeading(at position: ReaderTextPosition) -> (view: ReaderTextView, range: NSRange)? {
        guard let heading = heading(at: position) else { return nil }
        // The column puts its own insertion point on the heading, and VoiceOver's cursor is on
        // the heading's element, which keyboard focus moved for the page would take it from.
        if shownHeading(heading) == nil { show(heading.position, selecting: nil, entry: .firstLine) }
        return shownHeading(heading)
    }

    /// A heading's place in the book as VoiceOver keeps it for a heading on another page.
    static func headingToken(_ position: ReaderTextPosition) -> any NSAccessibilityLoadingToken {
        "\(position.section):\(position.offset)" as NSString
    }

    static func headingPosition(of token: any NSAccessibilityLoadingToken) -> ReaderTextPosition? {
        guard let parts = (token as? String)?.split(separator: ":"), parts.count == 2,
              let section = Int(parts[0]), let offset = Int(parts[1]) else { return nil }
        return ReaderTextPosition(section: section, offset: offset)
    }

    // MARK: Host highlights for VoiceOver

    /// What a text view's Highlights rotor answers: the host highlight after or before where
    /// the search stands, and none past either end (`highlightStop`), each called by its style
    /// and its words (`highlightLabel`). One whose first character a text view shows is given
    /// as that view and its characters there; any other as a token for its place in the book,
    /// which the reader shows only when VoiceOver moves to it (`loadHighlight`), as for a
    /// heading on another page (`headingRotorResult`): VoiceOver walks the whole list when its
    /// rotor opens. The search stands where the heading search would
    /// (`headingSearchPosition`), at a place and not over a range: a highlight that begins
    /// later in the line VoiceOver is on is the next one.
    func highlightRotorResult(for parameters: NSAccessibilityCustomRotor.SearchParameters,
                              askedOf view: ReaderTextView) -> NSAccessibilityCustomRotor.ItemResult? {
        let forward = parameters.searchDirection == .next
        let filter = parameters.filterString
        var from = highlightSearchPosition(of: parameters.currentItem, askedOf: view, forward: forward).map { ReaderTextRange(start: $0, end: $0) }
        while let found = highlightStop(from: from, forward: forward) {
            from = ReaderTextRange(start: found.range.start, end: found.range.start)
            let label = highlightLabel(found)
            guard filter.isEmpty || label.localizedCaseInsensitiveContains(filter) else { continue }
            let shown = shownHighlight(found)
            let result = shown.map { NSAccessibilityCustomRotor.ItemResult(targetElement: $0.view) }
                ?? NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: Self.highlightToken(found.range.start), customLabel: label)
            // A token's result has a range too, its characters in its section: without one the
            // list read a heading's row as the column's own text (`headingRotorResult`).
            result.targetRange = shown?.range ?? NSRange(location: found.range.start.offset, length: max(1, found.range.end.offset - found.range.start.offset))
            result.customLabel = label
            return result
        }
        return nil
    }

    /// Where a search of the highlights from `item` stands, as a heading search does: nowhere
    /// without one, at a token's place, at the edge of a page that VoiceOver's cursor rests on,
    /// or at the first character of the range it gives. The scroll view at rest stands at the
    /// top of the screen, or after its end going back.
    private func highlightSearchPosition(of item: NSAccessibilityCustomRotor.ItemResult?, askedOf column: ReaderTextView,
                                         forward: Bool) -> ReaderTextPosition? {
        guard let item else { return nil }
        if let token = item.itemLoadingToken { return Self.highlightPosition(of: token) ?? Self.headingPosition(of: token) }
        guard item.targetElement != nil else { return nil }
        let view = (item.targetElement as? ReaderTextView).flatMap { $0.canvas === self ? $0 : nil } ?? column
        let range = item.targetRange
        if range.location == NSNotFound || range == NSRange(location: 0, length: 0) {
            if view === scrollTextView, let visibleRange {
                return forward ? ReaderTextPosition(section: visibleRange.start.section, offset: visibleRange.start.offset - 1) : visibleRange.end
            }
            guard let edge = position(at: forward ? 0 : view.shownCharacters.length, in: view) else { return nil }
            return forward ? ReaderTextPosition(section: edge.section, offset: edge.offset - 1) : edge
        }
        return position(at: range.location, in: view)
    }

    /// The text view that shows where `highlight` begins, and its characters there, cut to
    /// what the view shows: a page's column, or the scroll view once it holds the section.
    private func shownHighlight(_ highlight: ReaderHighlight) -> (view: ReaderTextView, range: NSRange)? {
        let start = highlight.range.start
        let first = ReaderTextRange(section: start.section, start.offset..<(start.offset + 1))
        for view in textViews {
            guard let character = localRange(of: first, in: view) else { continue }
            return (view, localRange(of: highlight.range, in: view) ?? character)
        }
        return nil
    }

    /// The highlight that begins at `position`, when one still does.
    private func highlight(beginningAt position: ReaderTextPosition) -> ReaderHighlight? {
        var before = position
        before.offset -= 1
        guard let found = highlightStop(from: ReaderTextRange(start: before, end: before), forward: true),
              found.range.start.section == position.section, found.range.start.offset == position.offset else { return nil }
        return found
    }

    /// VoiceOver moves to a highlight it was given as a token: the reader turns to the page
    /// that shows its start, unless a text view shows it, and this is that text view.
    func loadHighlight(_ token: any NSAccessibilityLoadingToken) -> ReaderTextView? {
        guard let position = Self.highlightPosition(of: token), let found = highlight(beginningAt: position) else { return nil }
        if shownHighlight(found) == nil { show(position, selecting: nil, entry: .firstLine) }
        return shownHighlight(found)?.view
    }

    /// The highlight's characters in the text view that shows it.
    func loadedHighlightRange(_ token: any NSAccessibilityLoadingToken) -> NSRange? {
        guard let position = Self.highlightPosition(of: token), let found = highlight(beginningAt: position) else { return nil }
        return shownHighlight(found)?.range
    }

    /// A highlight's place in the book as VoiceOver keeps it, apart from a heading's.
    static func highlightToken(_ position: ReaderTextPosition) -> any NSAccessibilityLoadingToken {
        "highlight:\(position.section):\(position.offset)" as NSString
    }

    static func highlightPosition(of token: any NSAccessibilityLoadingToken) -> ReaderTextPosition? {
        guard let parts = (token as? String)?.split(separator: ":"), parts.count == 3, parts[0] == "highlight",
              let section = Int(parts[1]), let offset = Int(parts[2]) else { return nil }
        return ReaderTextPosition(section: section, offset: offset)
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        guard let action = ReaderTextView.pageAction(for: event, controls: configuration.pageControls) else { return super.keyDown(with: event) }
        performPageActionFromInput(action)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handlePageKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    func handlePageKeyEquivalent(_ event: NSEvent) -> Bool {
        guard imageInspector == nil, hasKeyboardFocus,
              let action = ReaderTextView.pageAction(for: event, controls: configuration.pageControls)
        else { return false }
        performPageActionFromInput(action)
        return true
    }

    /// Native body and table-cell surfaces share the same source-based spread drag. Native
    /// clicks, word selection, links and edit menus remain with the originating text surface.
    func handleSpreadSelectionMouseDown(_ event: NSEvent) -> Bool {
        guard imageInspector == nil, configuration.flow == .paginated,
              columns.filter({ !$0.isHidden }).count > 1, event.clickCount == 1,
              let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture,
                                           inMode: .eventTracking, dequeue: false), next.type == .leftMouseDragged,
              let start = selectionPosition(at: convert(event.locationInWindow, from: nil)) else { return false }
        beginSelectionDrag(at: start)
        while let drag = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture,
                                           inMode: .eventTracking, dequeue: true) {
            if let end = selectionPosition(at: convert(drag.locationInWindow, from: nil)) {
                extendSelectionDrag(to: end)
            }
            if drag.type == .leftMouseUp { break }
        }
        endSelectionDrag()
        return true
    }

    // A click in a configured physical edge zone turns the page (`edgeTurn(at:)`); the
    // column text views handle clicks on themselves the same way.
    override func mouseDown(with event: NSEvent) {
        pointerDown = (convert(event.locationInWindow, from: nil), event.timestamp)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { pointerDown = nil }
        guard let down = pointerDown, hypot(point.x - down.location.x, point.y - down.location.y) < 4,
              let forward = edgeTurn(at: point) else { return super.mouseUp(with: event) }
        turnPageFromInput(forward: forward)
    }

    /// In paginated flow a trackpad gesture or wheel tick turns a page; the columns do not scroll.
    /// A trackpad's swipe across the page is followed by the page where the turn is animated
    /// (`followSwipe`).
    override func scrollWheel(with event: NSEvent) {
        guard imageInspector == nil, configuration.flow == .paginated, configuration.pageControls.wheelEnabled else { return super.scrollWheel(with: event) }
        if followSwipe(event) { return }
        // Line-based mouse wheels report lines; count them in points as WebKit did.
        func points(_ delta: CGFloat) -> CGFloat {
            event.hasPreciseScrollingDeltas ? delta : ReaderWheelPageTurner.points(lines: delta)
        }
        let phase: ReaderWheelPageTurner.Phase =
            if !event.momentumPhase.isEmpty { .momentum }
            else if event.phase.contains(.began) || event.phase.contains(.mayBegin) { .began }
            else if event.phase.contains(.changed) { .changed }
            else if !event.phase.isEmpty { .ended }
            else { .none }
        guard let forward = wheelTurner.direction(deltaX: -points(event.scrollingDeltaX),
                                                  deltaY: -points(event.scrollingDeltaY), phase: phase,
                                                  isRightToLeft: configuration.isRightToLeft,
                                                  at: event.timestamp) else { return }
        turnPageFromInput(forward: forward)
    }

    /// Has the page follow a trackpad's swipe across it, as a page turn's animation does a
    /// finger's on iPhone and iPad (`beginPageDrag`), where the person lets a swipe go between
    /// pages (`NSEvent.isSwipeTrackingFromScrollEventsEnabled`, System Settings' "Swipe between
    /// pages"). AppKit then tracks the swipe, moves the page with the fingers and, once they lift,
    /// on to its turn or back (`followPageSwipe`). The first horizontal event of a gesture starts
    /// it, and the page is drawn following it from AppKit's first step. A gesture up or down the
    /// page, a wheel's, and one with no swipe between pages turn the page once it has moved, as
    /// before. False where the event is not such a swipe's.
    private func followSwipe(_ event: NSEvent) -> Bool {
        guard canBeginPageDrag, NSEvent.isSwipeTrackingFromScrollEventsEnabled, event.momentumPhase.isEmpty,
              event.phase.contains(.began) || event.phase.contains(.changed), !wheelTurner.gestureHasTurned,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
        wheelTurner.takeGesture()
        // An amount above zero moves the page to the right, which brings in the page before in a
        // book read left to right and the next in one read right to left.
        let rightward = canTurnPage(forward: configuration.isRightToLeft) == true
        let leftward = canTurnPage(forward: !configuration.isRightToLeft) == true
        var drag: ReaderPageTransition?
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: leftward ? -1 : 0, max: rightward ? 1 : 0) { [weak self] amount, _, complete, stop in
            MainActor.assumeIsolated {
                guard let self else { stop.pointee = true; return }
                if drag == nil {
                    guard self.beginPageDrag() else { stop.pointee = true; return }
                    drag = self.pageTransition
                }
                // A turn or another drag meanwhile has ended this one.
                guard self.pageTransition === drag, self.followPageSwipe(amount: amount, complete: complete) else {
                    stop.pointee = true
                    return
                }
            }
        }
        return true
    }

    /// One step of a trackpad's swipe that the page follows: AppKit's `amount` of the width, from
    /// -1 to 1, above zero to the right. Once `complete` the page turns where AppKit took it all
    /// the way, and otherwise stands where it began. False once the drag has ended otherwise, as
    /// by a key's turn meanwhile, for AppKit to stop tracking.
    @discardableResult func followPageSwipe(amount: CGFloat, complete: Bool) -> Bool {
        guard let transition = pageTransition, transition.isDrag, !transition.isSettling else { return false }
        dragPage(by: amount * bounds.width)
        if complete { endPageDrag(turns: abs(amount) >= 0.5, animated: false) }
        return true
    }

    // MARK: Notes

    func presentNote(_ text: NSAttributedString, theme: ReaderTheme, from rect: CGRect) {
        guard window != nil else { return }
        (presentedNote as? NSPopover)?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let controller = ReaderNoteViewController(
            text: text, theme: theme, width: min(360, max(200, bounds.width - 32)))
        controller.onLink = { [weak self] url in self?.activateNoteLink(url) }
        popover.contentViewController = controller
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        presentedNote = popover
        noteRect = rect
    }

    // MARK: Links outside the book

    /// A sheet on the reader's window. Open is its first button, the sheet's default button,
    /// which Return chooses while the sheet is the key window, and Cancel its second, whose key
    /// equivalent is Escape. A note's popover is closed first: it is a window of its own, which
    /// would stand over the sheet.
    func askToOpen(_ question: ExternalLinkQuestion, from rect: CGRect, answer: @escaping @MainActor (Bool) -> Void) -> Bool {
        withdrawLinkQuestion()
        guard let window else { return false }
        (presentedNote as? NSPopover)?.close()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: ExternalLinkQuestion.open)
        alert.addButton(withTitle: ExternalLinkQuestion.cancel)
        linkQuestion = (alert, answer)
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            if let alert { self?.answerLinkQuestion(response == .alertFirstButtonReturn, to: alert) }
        }
        return true
    }

    func withdrawLinkQuestion() {
        guard let question = linkQuestion else { return }
        linkQuestion = nil
        if let alert = question.shown as? NSAlert, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        }
        question.answer(false)
    }
}

/// A note shown in place: its text in a TextKit 2 view. A link outside the book in it is
/// handed to `onLink`, and so asked about as one in the text is; a link inside the book does
/// nothing.
final class ReaderNoteViewController: NSViewController, NSTextViewDelegate {
    let textView = ReaderTextView(pageColumn: false)
    /// Where a link the note's text activates goes: the canvas that shows the note.
    var onLink: ((URL) -> Void)?
    private let theme: ReaderTheme
    private let width: CGFloat

    convenience init(text: NSAttributedString, dark: Bool, width: CGFloat) {
        self.init(text: text, theme: dark ? .dark : .light, width: width)
    }

    init(text: NSAttributedString, theme: ReaderTheme, width: CGFloat) {
        self.theme = theme
        self.width = width
        super.init(nibName: nil, bundle: nil)
        textView.delegate = self
        textView.selectedTextAttributes = ReaderCanvasView.selectedTextAttributes(theme)
        textView.textContainerInset = NSSize(width: 0, height: 16)
        textView.columnMinX = 16
        textView.readerContainer.size = CGSize(width: width - 32, height: 0)
        textView.readerContainer.viewportSize = CGSize(width: width - 32, height: 400)
        textView.setContent(text)
        textView.ensureFullLayout()
        let height = textView.readerLayoutManager.usageBoundsForTextContainer.height + 32
        preferredContentSize = CGSize(width: width, height: min(max(height, 44), 420))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: preferredContentSize))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // The note on the page's colour. The popover's arrow is AppKit's own.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        textView.frame = CGRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = textView
        view = scrollView
    }

    /// A click on a link, and VoiceOver's press of AppKit's own element for it.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }) { onLink?(url) }
        return true
    }
}
#endif

#if os(macOS)
/// Repairs geometry replaced by an accessibility read before AppKit uses the old offset
/// for the first wheel or trackpad event. Bounds notifications then record each new place.
final class ReaderScrollView: NSScrollView {
    weak var canvas: ReaderCanvasView?

    override func scrollWheel(with event: NSEvent) {
        // The wheel moves the text on from where the reader has it.
        canvas?.endScrollStep()
        if let view = canvas?.scrollTextView { canvas?.holdScrollPlace(of: view) }
        super.scrollWheel(with: event)
        // The person's wheel or trackpad reads on, and its momentum is the same gesture.
        if let canvas, event.momentumPhase.isEmpty, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            canvas.delegate?.canvasDidReadOn(canvas)
        }
    }
}

/// Tells reader canvases when the system is short of memory, so they trim their caches.
@MainActor enum ReaderMemoryPressure {
    static let notification = Notification.Name("org.epublib.reader.memoryPressure")
    private static var source: (any DispatchSourceMemoryPressure)?

    static func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { NotificationCenter.default.post(name: notification, object: nil) }
        source.resume()
        self.source = source
    }
}
#endif
