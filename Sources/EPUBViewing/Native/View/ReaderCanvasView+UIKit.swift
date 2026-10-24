#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

// UIKit views, input, menus and popovers for `ReaderCanvasView`.
extension ReaderCanvasView: UITextViewDelegate, UIGestureRecognizerDelegate {
    func platformSetUp() {
        clipsToBounds = true // A spread kept through a rotation never draws outside the canvas.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
        let pan = ReaderPagePanRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = ReaderEdgeTapRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        addGestureRecognizer(ReaderTouchObserver { [weak self] in
            // A touch finds the text where the reader has it.
            self?.endScrollStep()
            self?.takeKeyboardFocusIfFree()
        })
        let middle = ReaderMiddleTapRecognizer(target: self, action: #selector(middleTapped(_:)))
        middle.delegate = self
        middle.cancelsTouchesInView = false
        addGestureRecognizer(middle)
        updateInputHandlers()
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning(_:)),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    /// Disabled recognizers cannot compete with a host gesture, even before recognition. A swipe
    /// that a page turn's animation follows is a pan (`ReaderPagePanRecognizer`), and with no
    /// animation a swipe as before.
    func updateInputHandlers() {
        let swipes = configuration.flow == .paginated && configuration.pageControls.touchSwipesEnabled
        for recognizer in gestureRecognizers ?? [] {
            if recognizer is ReaderMiddleTapRecognizer {
                recognizer.isEnabled = configuration.togglesControls
            } else if recognizer is UISwipeGestureRecognizer {
                recognizer.isEnabled = swipes && pageMotion == nil
            } else if recognizer is ReaderPagePanRecognizer {
                recognizer.isEnabled = swipes && pageMotion != nil
            } else if recognizer is UITapGestureRecognizer {
                recognizer.isEnabled = configuration.flow == .paginated && configuration.pageControls.edgeTapsEnabled
            }
        }
        UIMenuSystem.main.setNeedsRebuild()
        if isFirstResponder { reloadInputViews() }
        for view in textViews where view.isFirstResponder { view.reloadInputViews() }
    }

    @objc private func memoryWarning(_ notification: Notification) { trimCaches() }

    /// A keyboard comes up over the window or goes. Its end frame is in the screen's space.
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let window, let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboard = window.convert(end, from: window.screen.coordinateSpace)
        let up = keyboard.height > 0 && keyboard.intersects(window.bounds)
        guard up != keyboardIsUp else { return }
        keyboardIsUp = up
        setNeedsLayout()
    }

    func applyAppearance() {
        let theme = configuration.theme
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        backgroundColor = theme.background
        scrollTextView?.backgroundColor = theme.background
        // UIKit draws a text view's selection, its handles and its caret, and a table cell's
        // selection, in the tint colour: the theme's links, which keep 4.5:1 on its page.
        tintColor = theme.link
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A rotation or bar animation keeps the spread on screen and paginates once it is over.
        let duration = UIView.inheritedAnimationDuration
        // A host makes room for a keyboard in an animation, which may come before the canvas is
        // told of the keyboard: what is laid out then is not the area to keep.
        let area = bounds.inset(by: safeAreaInsets)
        if !keyboardIsUp, duration == 0 || uncoveredPageArea?.width != area.width { uncoveredPageArea = area }
        if duration > 0, configuration.flow == .paginated, spread != nil { deferLayout(for: duration) }
        layOutCanvas()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// Paginated pages keep clear of the bars; continuous scroll runs under them. While a
    /// keyboard is up, pages keep the height they had without it, and the canvas cuts off what
    /// is below its bottom, as the keyboard covers it: a host made the reader shorter to make
    /// room for the keyboard, and the book was laid out again as the keyboard rose for a search
    /// and again as the search put it away, on an iPad one column becoming two and back (#49).
    /// Continuous scroll lays no text out again for a shorter view, and is made shorter.
    var pageArea: CGRect {
        let area = bounds.inset(by: safeAreaInsets)
        guard keyboardIsUp, configuration.flow == .paginated, let kept = uncoveredPageArea,
              kept.origin == area.origin, kept.width == area.width, kept.height > area.height else { return area }
        return kept
    }

    func makeColumnView() -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.delegate = self
        addSubview(view)
        return view
    }

    /// A column that draws a page a swipe brings in, which nothing reads or touches.
    func makePreviewColumn() -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    /// A picture of the page on screen as it is drawn: each shown column's, where it stands on
    /// the canvas. nil while nothing is shown. UIKit's snapshot of what is on screen, and where
    /// it gives none, as for a column not yet drawn there, the column's layers drawn into an
    /// image.
    func pageSnapshot() -> PlatformView? {
        let shown = columns.filter { !$0.isHidden }
        guard !shown.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        let picture = ReaderPageTransitionView(frame: bounds)
        for column in shown {
            let view = column.snapshotView(afterScreenUpdates: false) ?? drawnPicture(of: column)
            view.frame = column.frame
            picture.addSubview(view)
        }
        return picture
    }

    private func drawnPicture(of column: ReaderTextView) -> UIView {
        let format = UIGraphicsImageRendererFormat(for: traitCollection)
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: column.bounds, format: format).image { context in
            column.layer.render(in: context.cgContext)
        }
        return UIImageView(image: image)
    }

    /// Puts what a page turn draws above the columns, and below what stands over the page: the
    /// selection's continuation and the image inspector.
    func addPageTransitionView(_ view: PlatformView) {
        view.frame = bounds
        if let top = subviews.last(where: { subview in columns.contains { $0 === subview } }) {
            insertSubview(view, aboveSubview: top)
        } else {
            addSubview(view)
        }
    }

    func makeScrollView() -> (PlatformView, ReaderTextView) {
        let view = ReaderTextView(pageColumn: false)
        view.delegate = self
        view.backgroundColor = configuration.theme.background
        view.readerContainer.widthTracksTextView = false // `applyScrollGeometry` sets the column width.
        view.contentInsetAdjustmentBehavior = .automatic
        view.contentInset = UIEdgeInsets(top: ReaderCanvasGeometry.verticalMargin, left: 0, bottom: 64, right: 0)
        view.topEdgeEffect.style = .soft
        view.bottomEdgeEffect.style = .soft
        view.frame = bounds
        addSubview(view)
        return (view, view)
    }

    /// Sizes the scroll view to the canvas and centres the text column with horizontal insets only.
    /// The column width is set on its own, and only when it changes: a container tracking the
    /// view's width would lay the whole text out at a passing width between the new frame and its
    /// insets, which TextKit 2 can follow with a wrong layout.
    func scrollColumnArea() -> CGRect { pageArea }

    func applyScrollGeometry(columnMinX: CGFloat, width: CGFloat) {
        guard let view = scrollTextView else { return }
        if view.readerContainer.size.width != width {
            view.readerContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        view.textContainerInset = UIEdgeInsets(top: 0, left: columnMinX - bounds.minX, bottom: 0,
                                               right: max(0, bounds.maxX - columnMinX - width))
        view.frame = bounds
        view.layoutIfNeeded()
    }

    /// The scroll view's visible text area in text container coordinates: below the top inset
    /// (the bar plus the 48-point margin, where a shown position rests) and above the bottom bar.
    var scrollVisibleContainerRect: CGRect {
        guard let view = scrollTextView else { return .zero }
        let insets = view.adjustedContentInset
        let bottom = insets.bottom - view.contentInset.bottom
        let top = view.contentOffset.y + insets.top
        return CGRect(x: 0, y: top - view.textContainerInset.top, width: view.readerContainer.size.width,
                      height: max(0, view.bounds.height - insets.top - bottom))
    }

    /// Scrolls so container `y` is at the top of the visible text area, within the content.
    func scrollToContainerY(_ y: CGFloat) {
        guard let view = scrollTextView else { return }
        view.layoutIfNeeded()
        let insets = view.adjustedContentInset
        let target = y + view.textContainerInset.top - insets.top
        view.contentOffset = CGPoint(x: view.contentOffset.x, y: min(max(-insets.top, target), maximumScrollOffset))
        view.readerLayoutManager.textViewportLayoutController.layoutViewport()
    }

    /// Stands the viewport's fragments where the scroll view draws them, before the screen is
    /// read. A layout of the whole text behind the view, which VoiceOver's read of every
    /// paragraph's frame makes, moves them to their exact places in the document, while UIKit
    /// goes on drawing them where the estimates had put them, in content as tall as it was.
    /// Laying the viewport out again moves them back under what is drawn and takes the height.
    func settleScrollViewport() {
        scrollTextView?.readerLayoutManager.textViewportLayoutController.layoutViewport()
    }

    private var maximumScrollOffset: CGFloat {
        guard let view = scrollTextView else { return 0 }
        let insets = view.adjustedContentInset
        return max(-insets.top, view.contentSize.height + insets.bottom - view.bounds.height)
    }

    var isScrolledToStart: Bool {
        guard let view = scrollTextView else { return true }
        return view.contentOffset.y <= -view.adjustedContentInset.top + 1
    }

    var isScrolledToEnd: Bool {
        guard let view = scrollTextView else { return true }
        return view.contentOffset.y >= maximumScrollOffset - 1
    }

    /// Gives keyboard focus to a text view, or the canvas.
    func focus(_ view: ReaderTextView?) {
        guard window != nil else { return }
        let responder: UIView = view ?? self
        if !responder.isFirstResponder { responder.becomeFirstResponder() }
    }

    var hasKeyboardFocus: Bool { isFirstResponder || textViews.contains(where: \.isFirstResponder) }

    /// A hardware keyboard's page keys reach the reader only through its responders, and UIKit
    /// gives nothing focus on its own: on an iPad with a keyboard no page key did anything until
    /// some text was selected (#681). The reader takes keyboard focus when it is shown and when it
    /// is touched, as a Mac's does when its window gives it none, but only while no other view in
    /// its window holds it: a search field keeps its focus and its keyboard.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        takeKeyboardFocusIfFree()
    }

    func takeKeyboardFocusIfFree() {
        guard let window, imageInspector == nil, !hasKeyboardFocus, !Self.holdsFocus(window) else { return }
        becomeFirstResponder()
    }

    private static func holdsFocus(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains(where: holdsFocus)
    }

    // MARK: Text view delegate

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let view = textView as? ReaderTextView else { return }
        textViewSelectionDidChange(view)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === scrollTextView else { return }
        let rested = restedScrollOffset.map { abs(scrollView.contentOffset.y - $0) < 1 } ?? false
        restedScrollOffset = nil
        scrollPositionDidChange(byReader: rested)
    }

    /// The safe area changed under the scroll view (bars shown or hidden). UIKit holds back its
    /// report of the scrolling an inset change brings until this returns, so a rest made here
    /// for the new height is reported as scrolling nobody asked for. Where that report finds
    /// the view as the rest left it, the person has not scrolled, and the position kept stays
    /// the one rested: the visible start is not to be read then, for UIKit has moved the view
    /// for the bar and the text under it is laid out again (#338).
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        guard scrollView === scrollTextView else { return }
        if updateScrollViewport() { restedScrollOffset = scrollView.contentOffset.y }
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        if case .textAttachment(let attachment) = textItem.content, let image = attachment as? ReaderImageAttachment {
            return UIAction(title: "Inspect Image", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) {
                [weak self] _ in self?.inspectImage(image)
            }
        }
        guard case .link(let url) = textItem.content, let view = textView as? ReaderTextView else { return nil }
        let range = textItem.range
        return UIAction { [weak self, weak view] _ in
            guard let self, let view else { return }
            self.activateLink(url, range: range, in: view)
        }
    }

    /// Images, including linked ones, can be inspected without opening a private link preview.
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        guard let view = textView as? ReaderTextView,
              let image = view.imageAttachments(in: textItem.range).first?.image else { return nil }
        let action = UIAction(title: "Inspect Image", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) {
            [weak self] _ in self?.inspectImage(image)
        }
        return UITextItem.MenuConfiguration(menu: UIMenu(children: [action]))
    }

    func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue],
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let title = configuration.selectionActionTitle else { return UIMenu(children: suggestedActions) }
        let action = UIAction(title: title, image: UIImage(systemName: configuration.selectionActionImage)) {
            [weak self] _ in self?.performSelectionAction()
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: [action])] + suggestedActions)
    }

    // MARK: Input

    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        guard imageInspector == nil, configuration.flow == .paginated, configuration.pageControls.touchSwipesEnabled, !hasSelection else { return }
        turnPageFromInput(forward: ReaderCanvasInput.swipeDirection(
            towardsLeft: recognizer.direction == .left, isRightToLeft: configuration.isRightToLeft))
    }

    /// A swipe that a page turn's animation follows (`beginPageDrag`): the page moves with the
    /// finger, and turns when it lets go past half the width or flicks on, and goes back
    /// otherwise. Where no drag could begin, a swipe that would turn turns as a swipe does.
    @objc private func panned(_ recognizer: ReaderPagePanRecognizer) {
        let offset = recognizer.translation(in: self).x
        switch recognizer.state {
        case .began:
            recognizer.followsPage = beginPageDrag()
            if recognizer.followsPage { dragPage(by: offset) }
        case .changed:
            if recognizer.followsPage { dragPage(by: offset) }
        case .ended:
            let turns = ReaderPageDrag.turns(offset: offset, velocity: recognizer.velocity(in: self).x, width: bounds.width)
            if recognizer.followsPage {
                endPageDrag(turns: turns, animated: true)
            } else if turns {
                turnPageFromInput(forward: ReaderPageDrag.forward(offset: offset, isRightToLeft: configuration.isRightToLeft))
            }
            recognizer.followsPage = false
        case .cancelled, .failed:
            if recognizer.followsPage { endPageDrag(turns: false, animated: true) }
            recognizer.followsPage = false
        default:
            break
        }
    }

    /// A tap within a configured physical edge zone turns the page, unless it lands on a
    /// link, text is selected, or the touch was a long press (a selection beginning). The press
    /// is timed by the touch's own timestamps, from when it went down to when it lifted.
    @objc private func tapped(_ recognizer: ReaderEdgeTapRecognizer) {
        edgeTap(at: recognizer.location(in: self), liftedAt: recognizer.liftTime)
    }

    /// The tap's own work, for a touch that lifted at `lift` at `location`: what an in-process
    /// test delivers, as UIKit makes no touch there (`ReaderEdgeTapRecognizer`).
    func edgeTap(at location: CGPoint, liftedAt lift: TimeInterval?) {
        guard let down = pointerDown, let lift, lift - down.time < 0.35, let forward = edgeTurn(at: location) else { return }
        turnPageFromInput(forward: forward)
    }

    /// A tap in the middle of the page shows or hides the host's controls (`togglesControls(at:)`),
    /// unless the touch was a long press, timed as an edge tap is.
    @objc private func middleTapped(_ recognizer: ReaderMiddleTapRecognizer) {
        guard let down = pointerDown, let lift = recognizer.liftTime, lift - down.time < 0.35,
              togglesControls(at: recognizer.location(in: self)) else { return }
        _ = toggleControls()
    }

    // Swipes never begin while text is selected, so dragging a selection handle never turns the
    // page; edge taps begin only in the zones, and a tap in the middle only away from them.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === self else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        // VoiceOver's double tap on a line reaches the reader as a touch at the line: under
        // VoiceOver the controls come and go by Magic Tap and the Show Controls button alone.
        if gestureRecognizer is ReaderMiddleTapRecognizer {
            return !UIAccessibility.isVoiceOverRunning && togglesControls(at: gestureRecognizer.location(in: self))
        }
        guard imageInspector == nil, configuration.flow == .paginated, !hasSelection, !isDraggingSelection else { return false }
        if gestureRecognizer is UISwipeGestureRecognizer { return configuration.pageControls.touchSwipesEnabled && !hasSelection }
        if let pan = gestureRecognizer as? ReaderPagePanRecognizer {
            // A page follows a swipe across it, not one up or down it.
            let velocity = pan.velocity(in: self)
            return configuration.pageControls.touchSwipesEnabled && pageMotion != nil && abs(velocity.x) > abs(velocity.y)
        }
        if gestureRecognizer is UITapGestureRecognizer { return edgeTurn(at: gestureRecognizer.location(in: self)) != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer.isEnabled else { return false }
        // A touch that stops continuous scroll moving is not a tap on the page.
        if gestureRecognizer is ReaderMiddleTapRecognizer, scrollTextView?.isDecelerating == true { return false }
        if gestureRecognizer is UITapGestureRecognizer { pointerDown = (touch.location(in: self), touch.timestamp) }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// A tap in the middle waits until it is not the first of the text's double tap, which
    /// selects a word: that double tap does not show or hide the controls.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is ReaderMiddleTapRecognizer && ((other as? UITapGestureRecognizer)?.numberOfTapsRequired ?? 1) > 1
    }

    /// A finger dragging continuous scroll reads on (`ReaderCanvasDelegate.canvasDidReadOn`).
    /// VoiceOver's own scrolling drags nothing.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === scrollTextView else { return }
        endScrollStep()
        delegate?.canvasDidReadOn(self)
    }

    /// VoiceOver's Magic Tap, a two-finger double tap, shows or hides the host's controls from
    /// wherever its cursor is in the reader. Its lines and text views pass it here.
    override func accessibilityPerformMagicTap() -> Bool { toggleControls() }

    /// The canvas takes keyboard focus for hardware keys only while nothing else in its window
    /// holds it (`takeKeyboardFocusIfFree`): taking it from a field would dismiss its keyboard.
    override var canBecomeFirstResponder: Bool { true }

    /// Bindings are read from the current configuration by both canvas and focused children.
    override var keyCommands: [UIKeyCommand]? { pageKeyCommands }

    var pageKeyCommands: [UIKeyCommand] {
        guard imageInspector == nil else { return [] }
        return configuration.pageControls.effectiveBindings.map { binding in
            let command = UIKeyCommand(input: binding.key.uiInput, modifierFlags: binding.modifiers.uiFlags,
                                       action: #selector(pageTurnKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(pageTurnKeyCommand(_:)), let command = sender as? UIKeyCommand {
            return ReaderTextView.pageAction(input: command.input, flags: command.modifierFlags,
                                             controls: configuration.pageControls) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func pageTurnKeyCommand(_ command: UIKeyCommand) {
        guard imageInspector == nil, let action = ReaderTextView.pageAction(input: command.input, flags: command.modifierFlags,
                                                                    controls: configuration.pageControls) else { return }
        performPageActionFromInput(action)
    }

    /// VoiceOver orders sibling containers by their frames, top first. A column starting below
    /// its neighbour, as a chapter opening does with its top spacing, or placed to its right in
    /// a right-to-left book, was read after the page that follows it. Columns are in source order.
    override var accessibilityElements: [Any]? {
        get {
            guard configuration.flow == .paginated, imageInspector == nil else { return super.accessibilityElements }
            return columns.filter { !$0.isHidden } + [selectionContinuation].compactMap { $0 }
        }
        set { super.accessibilityElements = newValue }
    }

    /// VoiceOver's three-finger swipes turn pages: towards the left or up reads forward (mirrored
    /// right to left), and the page is announced. The cursor is sent to the new page after
    /// the announcement: VoiceOver then says the page's number and the line, where for the
    /// two posted the other way round it said the line alone (iOS 27.0 simulator).
    ///
    /// VoiceOver reading on by itself (Read All) scrolls `.next` from the item that turns the
    /// page (`accessibilityPageTurnColumn`) once it has read it. The same announcement is
    /// posted then. UIKit asks for a page-scrolled notification after every scroll that
    /// succeeds, VoiceOver goes on reading from its handling of that notification
    /// (`-[VOTElementManager _handleScrollByPageNotification:]`), and it takes one whose words
    /// are those of the scroll before, or one with no words, for an end it has come to.
    /// Reading on, it plays its page sound for it and does not say the words, and it ignores
    /// the layout change (iOS 27.0 simulator).
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard canScrollForAccessibility else { return false }
        let forward: Bool
        switch direction {
        case .left: forward = !configuration.isRightToLeft
        case .right: forward = configuration.isRightToLeft
        case .up, .next: forward = true
        case .down, .previous: forward = false
        @unknown default: return false
        }
        accessibilityCursorIsHeld = true
        let result = turnPage(forward: forward)
        accessibilityCursorIsHeld = false
        guard result != .atBoundary else { return false }
        if let shownPage { postAccessibilityNotification(.pageScrolled, "Page \(shownPage.page + 1)") }
        accessibilityCursorAtTurn = accessibilityCursorFollowsThePage(to: visibleRange?.start) as? NSObject
        return true
    }

    /// Whether VoiceOver's scroll turns the page now: in pages, with no image inspected and
    /// no text selected or being selected.
    private var canScrollForAccessibility: Bool {
        imageInspector == nil && configuration.flow == .paginated && !hasSelection && !isDraggingSelection
    }

    /// The column whose last item turns the page for VoiceOver when it reads on by itself, two
    /// fingers swiped down or Read All: the last column shown, which is the page's last in
    /// one column and the right-hand page of a spread (the left-hand one in a book read right
    /// to left, `accessibilityElements`), so that a spread is read through before it turns.
    /// None where VoiceOver's scroll would turn nothing: on the book's last page, where reading
    /// stops at its last line, and while a selection holds the page.
    ///
    /// The item says so by `UIAccessibilityTraits.causesPageTurn`. VoiceOver, reading on, turns
    /// the page after every item that has it, so no other item has it: with it on every line it
    /// would turn the page after the first. And it scrolls `.next` from that item once it has
    /// read it, and where that fails a page to the right as well
    /// (`-[VOTElementManager _handleBookPageFlipAndContinue]`, iOS 27.0 simulator), which in a
    /// book read left to right is the page before: the last page has no such item.
    ///
    /// After that turn VoiceOver looks among the first ten items of the app for one that turns
    /// the page, and reads on from the first such item from the top of the screen
    /// (`-[VOTElementManager _startReadingBookForNewPage]` and `_handleReadFromTop:`). A new
    /// page's last line found there was read alone and turned the page again: with nothing
    /// above the reader and two lines a page, VoiceOver read the last line of each page and no
    /// other. So until VoiceOver's cursor leaves the item the turn left it on, no other item
    /// turns the page (`accessibilityCursorAtTurn`), and VoiceOver finds none and stops. The
    /// item itself does where it is the page's last, as on a page of one line, which VoiceOver
    /// then reads. VoiceOver takes an item's traits before its cursor comes to the item, so
    /// the trait cannot wait for the cursor to be on the last line instead (iOS 27.0
    /// simulator).
    ///
    /// What VoiceOver reads after the turn is its own and the host's: in the sample, whose
    /// controls stand above the reader, it read on from the top of the screen, the controls
    /// and then the page from its first line, and with no controls there it stopped after the
    /// turn (iOS 27.0 simulator, `doc/native-viewer.md`, "Input and accessibility").
    var accessibilityPageTurnColumn: ReaderTextView? {
        guard canScrollForAccessibility, canTurnPage(forward: true) == true else { return nil }
        return columns.last { !$0.isHidden }
    }

    /// Keeps an assistive technology's cursor in the text when the line it was on is no longer
    /// on the page shown. VoiceOver keeps its cursor on the element it was given, and a line
    /// of a page that has been turned is no element of the page shown: the cursor stayed drawn
    /// where the line had stood, and the next move went by that element, out of the text to
    /// whatever follows the reader, or to the middle of the new page (`index(ofAccessibilityElement:)`).
    /// So the element VoiceOver holds becomes the item that holds `position`, the position
    /// shown: the page's first line, or the first cell of a data table that opens it, after a
    /// page turn, and the line of a link's target after a link
    /// (`ReaderTextView.accessibilityCursorStands(for:)`). VoiceOver is told the layout
    /// changed and given that element. It reads the item, draws its cursor there and goes on
    /// from it, and its cursor has not changed item, so what was chosen in its rotor still
    /// stands: a second double tap turns the page again. Given a new element for that line it
    /// read the same and its rotor was back at its default (iPadOS 27.2), and so it is still
    /// from a data table's cell to another cell, where a new element is the one read with
    /// its row and column. A cursor that is not in the text, as on a host's page button, is
    /// left where it is, and so is one whose line is still on the page
    /// (`accessibilityPageWasShown`). The answer is the element the cursor is sent to.
    @discardableResult
    func accessibilityCursorFollowsThePage(to position: ReaderTextPosition?) -> Any? {
        guard !accessibilityCursorIsHeld, let left = columns.first(where: \.accessibilityCursorHasLeftThePage) else { return nil }
        let shown = columns.filter { !$0.isHidden }
        var line: Any?, found = false
        for view in shown where line == nil {
            if found { line = view.accessibilityLine(from: 0) }
            else if let position, let local = localRange(of: ReaderTextRange(section: position.section, position.offset..<(position.offset + 1)), in: view) {
                found = true
                line = view.accessibilityLine(from: local.location)
            }
        }
        line = line ?? shown.lazy.compactMap { $0.accessibilityLine(from: 0) }.first
        let cursor = left.accessibilityCursorStands(for: line)
        postAccessibilityNotification(.layoutChanged, cursor)
        return cursor
    }

    /// Tells an assistive technology that a page was shown, at `position`. A cursor whose line
    /// is no longer on the page goes to the page (`accessibilityCursorFollowsThePage`). Any
    /// other cursor stays where it is, on a control or on a line the page still has, and
    /// VoiceOver is told that the layout changed, with no element.
    ///
    /// VoiceOver keeps the items it was given each side of its cursor, two as a rule and as
    /// many as fifty at a move it makes while holding nothing, as after a menu closes.
    /// Nothing told it that a page had been shown under them by something it did not do: a
    /// page turned by a key on a keyboard or the host's own command, or the same page shown
    /// again when the host changes the appearance or the text is built again, whose lines
    /// are new items. An item it held and had not been on it tried as it came to it, found
    /// gone, and asked again. An item its cursor had been on it took without asking, read
    /// from what it had kept of it, and at the move after that it found the item gone and
    /// set its cursor on the item it had last touched (iOS 27.0 simulator). With its cursor
    /// back on a control after reading into a page that was then turned, it read the first
    /// line of the page before and was back on the control. With its cursor on a line of a
    /// page shown again, a move back and a move forward took it out of the text, to the
    /// control it had touched before it began to read. Told of the layout change it drops
    /// what it holds 0.8 s later, by its own log, says nothing and stays where it is, and
    /// its moves from there are through the items of the page shown.
    ///
    /// A page shown again has a new item for the line under the cursor as for every other,
    /// and VoiceOver then set its cursor on that one, where its rotor is at its default: an
    /// action chosen before took one more flick down. So the item it holds is first made
    /// the item of its line, or of its cell of a data table
    /// (`ReaderTextView.accessibilityCursorKeepsItsLine`). Its cursor is then on an item of
    /// the page already. It sets nothing, and what was chosen in its rotor still stands.
    ///
    /// Nothing is posted for a page VoiceOver asked for itself: by its rotor, which takes
    /// the cursor to the item it is given, and by its scroll, which is announced
    /// (`accessibilityCursorIsHeld`).
    func accessibilityPageWasShown(at position: ReaderTextPosition?) {
        guard !accessibilityCursorIsHeld else { return }
        guard !columns.contains(where: \.accessibilityCursorHasLeftThePage) else {
            accessibilityCursorFollowsThePage(to: position)
            return
        }
        for column in columns { column.accessibilityCursorKeepsItsLine() }
        postAccessibilityNotification(.layoutChanged, nil)
    }

    /// Shows `position` for VoiceOver's rotor, which takes the cursor to the item it is given.
    func showForAccessibilityRotor(_ position: ReaderTextPosition) {
        accessibilityCursorIsHeld = true
        defer { accessibilityCursorIsHeld = false }
        show(position, selecting: nil)
    }

    /// Tells an assistive technology that the reader has moved the scroll view itself: a
    /// scroll step, a position shown (from the contents, a search, a link or a bookmark), text
    /// built again. VoiceOver keeps the items it was given each side of its cursor, two as a
    /// rule and fifty at its first move after a menu closes, and asks again only when it has
    /// used them. Nothing tells it that the view has moved under it. On a device it asks
    /// again by itself once it has activated an item, so a step made by its own double tap
    /// on Scroll Forward was read from the right place. A move it did not make, by a key on a
    /// keyboard or the host's own command, left it with what it held (an iPad, iPadOS 27.2).
    /// With its cursor on a line it stayed on that line, and its next move read the line
    /// after it, where UIKit brought the reader back: the step was undone. With its cursor on
    /// a control after a menu it went through the controls into the lines of the screen
    /// before the step. A simulator's VoiceOver did the same after its own double tap as
    /// well, which reaches the reader there as a plain touch.
    ///
    /// A layout change has it drop what it holds and ask again: 0.8 s after it is told, by
    /// its own log in a simulator, if it has not moved in that time. With its cursor outside
    /// the text no element is named: the cursor stays where it is, and its next move into
    /// the text meets the first line now on screen. With its cursor on a line, the line that
    /// holds `position`, the position shown, is named: the cursor goes there and VoiceOver
    /// reads it, as it goes to the page shown in paging (`accessibilityCursorFollowsThePage`).
    /// Given no element then, a simulator's VoiceOver took whichever line was drawn where
    /// its cursor had stood.
    ///
    /// Nothing is posted while VoiceOver's rotor holds the cursor, which VoiceOver takes to
    /// the item the rotor gives it, nor for scrolling the reader does not do: a finger's,
    /// and UIKit's for VoiceOver's cursor, its three-finger scroll and its scroll bar.
    func accessibilityCursorFollowsTheScrollView(to position: ReaderTextPosition?) {
        guard !accessibilityCursorIsHeld, let view = scrollTextView else { return }
        var line: Any?
        if view.accessibilityCursorIsOnALine {
            let local = position.flatMap { localRange(of: ReaderTextRange(section: $0.section, $0.offset..<($0.offset + 1)), in: view) }
            // A position with no character of its own, as the end of the text, is not a line's.
            line = view.accessibilityLine(from: local?.location ?? scrollSpokenCharacters()?.location ?? 0)
        }
        postAccessibilityNotification(.layoutChanged, line)
    }

    // MARK: Notes

    /// A popover from the nearest view controller; nothing without one.
    func presentNote(_ text: NSAttributedString, theme: ReaderTheme, from rect: CGRect) {
        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var presenter = responder as? UIViewController, window != nil else { return }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        let controller = ReaderNoteViewController(text: text, theme: theme,
                                                  width: min(360, max(200, bounds.width - 32)))
        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            // The arrow and the edges the popover draws round the note, in the note's page colour.
            popover.backgroundColor = theme.background
            popover.sourceView = self
            popover.sourceRect = rect
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = controller
        }
        presenter.present(controller, animated: true)
        presentedNote = controller
        noteRect = rect
        controller.onLink = { [weak self] url in self?.activateNoteLink(url) }
    }

    // MARK: Links outside the book

    /// An alert from the view controller on top, the note's popover when one is shown, so it
    /// stands over the note and the note is still there after it. Open is its preferred action,
    /// which Return chooses on a keyboard, and Cancel its cancel action, which Escape chooses.
    ///
    /// The question and the address are the alert's title, on two lines, and it has no
    /// message. UIKit gives an alert's title and message an element each, and VoiceOver reads
    /// only the first as the alert comes up: with the address as the message it said "Open a
    /// link outside the book?" and the address only on the next swipe (iOS 27.2 simulator, #793).
    func askToOpen(_ question: ExternalLinkQuestion, from rect: CGRect, answer: @escaping @MainActor (Bool) -> Void) -> Bool {
        // A question asked over another goes back, when cancelled, where the first began.
        let cursor = linkQuestion == nil ? voiceOverCursor() : cursorBeforeLinkQuestion
        withdrawLinkQuestion()
        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var presenter = responder as? UIViewController, window != nil else { return false }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        let alert = UIAlertController(title: question.title + "\n" + question.message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ExternalLinkQuestion.cancel, style: .cancel) { [weak self, weak alert] _ in
            if let alert { self?.alertAnswered(false, to: alert) }
        })
        let open = UIAlertAction(title: ExternalLinkQuestion.open, style: .default) { [weak self, weak alert] _ in
            if let alert { self?.alertAnswered(true, to: alert) }
        }
        alert.addAction(open)
        alert.preferredAction = open
        linkQuestion = (alert, answer)
        cursorBeforeLinkQuestion = cursor
        presenter.present(alert, animated: true)
        return true
    }

    func withdrawLinkQuestion() {
        guard let question = linkQuestion else { return }
        linkQuestion = nil
        cursorBeforeLinkQuestion = nil
        if let alert = question.shown as? UIAlertController, alert.presentingViewController != nil {
            alert.dismiss(animated: false)
        }
        question.answer(false)
    }

    /// One of the alert's buttons was chosen, and the alert has gone. After Cancel, VoiceOver's
    /// cursor goes back to where it was; after Open, it is left to whatever was opened.
    func alertAnswered(_ open: Bool, to alert: AnyObject) {
        guard let question = linkQuestion, question.shown === alert else { return }
        let cursor = cursorBeforeLinkQuestion
        cursorBeforeLinkQuestion = nil
        answerLinkQuestion(open, to: alert)
        if !open, let cursor { returnCursorAfterLinkQuestion(to: cursor) }
    }

    /// Puts VoiceOver's cursor back on the item it was on when the question was asked: the link,
    /// a table's row, or a note's text. As the alert went, VoiceOver took the first item of the
    /// screen, the host's first control, though the link's element was still the one listed and
    /// the reader had posted nothing (iOS 27.2 simulator, iPhone and iPad, #793). The alert is
    /// presented by the view controller on top, in a SwiftUI host its hosting controller, and
    /// the cursor was not given back to an element of the reader inside it. Over a note, which
    /// UIKit presents, it came back to the note's text in one run on the iPhone and went to the
    /// popover's first item in the others, of which no notification told. So the item is named
    /// with the screen change as the answer comes, which took VoiceOver straight back to a link
    /// or a row, and the first item VoiceOver then comes to is checked once: the cursor is put
    /// back where it is anything else, or, with no item told of within a second, where the
    /// cursor is elsewhere then. Over a note the iPhone said the popover's first item and was
    /// back on the note's text a second later.
    func returnCursorAfterLinkQuestion(to cursor: NSObject) {
        guard isStillShown(cursor) else { return }
        stopAwaitingCursorReturn()
        cursorReturnWait += 1
        let wait = cursorReturnWait
        cursorToReturnTo = cursor
        NotificationCenter.default.addObserver(self, selector: #selector(cursorMovedAfterLinkQuestion(_:)),
                                               name: UIAccessibility.elementFocusedNotification, object: nil)
        postAccessibilityNotification(.screenChanged, cursor)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            // VoiceOver came to no item it told of, as to a popover's own first item.
            guard let self, self.cursorReturnWait == wait, let cursor = self.cursorToReturnTo else { return }
            self.stopAwaitingCursorReturn()
            if self.voiceOverCursor() !== cursor, self.isStillShown(cursor) { self.postAccessibilityNotification(.layoutChanged, cursor) }
        }
    }

    @objc func cursorMovedAfterLinkQuestion(_ notification: Notification) {
        // Each move posts two notifications, the first naming only the item left.
        guard let cursor = cursorToReturnTo,
              let focused = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] as AnyObject? else { return }
        stopAwaitingCursorReturn()
        if focused !== cursor, isStillShown(cursor) { postAccessibilityNotification(.layoutChanged, cursor) }
    }

    private func stopAwaitingCursorReturn() {
        cursorToReturnTo = nil
        NotificationCenter.default.removeObserver(self, name: UIAccessibility.elementFocusedNotification, object: nil)
    }

    /// Whether `item` is still on screen: a view in a window, or an element whose containers
    /// lead to one.
    private func isStillShown(_ item: NSObject) -> Bool {
        var node: Any? = item
        for _ in 0..<8 {
            guard let current = node else { return false }
            if let view = current as? UIView { return view.window != nil }
            guard let element = current as? UIAccessibilityElement else { return true }
            node = element.accessibilityContainer
        }
        return false
    }
}

/// A note shown in place: its text in a TextKit 2 view. A link outside the book in it is
/// handed to `onLink`, and so asked about as one in the text is; a link inside the book does
/// nothing.
final class ReaderNoteViewController: UIViewController, UIPopoverPresentationControllerDelegate, UITextViewDelegate {
    let textView = ReaderTextView(pageColumn: false)
    /// Where a link the note's text activates goes: the canvas that shows the note.
    var onLink: ((URL) -> Void)?

    convenience init(text: NSAttributedString, dark: Bool, width: CGFloat) {
        self.init(text: text, theme: dark ? .dark : .light, width: width)
    }

    init(text: NSAttributedString, theme: ReaderTheme, width: CGFloat) {
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        textView.delegate = self
        textView.backgroundColor = theme.background
        textView.tintColor = theme.link
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.readerContainer.viewportSize = CGSize(width: width - 32, height: 400)
        textView.setContent(text)
        let fitted = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        preferredContentSize = CGSize(width: width, height: min(max(fitted.height, 44), 420))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = textView }

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    /// A tap on a link, and VoiceOver's or Full Keyboard Access's activation of UIKit's own
    /// element for it. Only a link outside the book has an action.
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, case .external? = ReaderLink(url: url) else { return nil }
        return UIAction { [weak self] _ in self?.onLink?(url) }
    }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? { nil }
}

/// The canvas's swipe when a page turn is animated, which the page follows: a pan, which
/// knows whether a drag of the page began with it.
final class ReaderPagePanRecognizer: UIPanGestureRecognizer {
    var followsPage = false
}

/// The canvas's edge-tap recognizer, which keeps when its touch lifted, as the touch gives it.
/// With when it went down (`pointerDown`) that times a press without reading a clock: the
/// system's uptime is an API whose use a host would have to declare to the App Store (#685).
class ReaderEdgeTapRecognizer: UITapGestureRecognizer {
    private(set) var liftTime: TimeInterval?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        liftTime = nil
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        liftTime = touches.first?.timestamp
        super.touchesEnded(touches, with: event)
    }
}

/// Sees each touch that begins in the canvas, on its text as well, and recognizes nothing: it
/// fails at once, so every other gesture, the text's own among them, goes on as before.
final class ReaderTouchObserver: UIGestureRecognizer {
    private let onTouch: @MainActor () -> Void

    init(onTouch: @escaping @MainActor () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }
}

/// The canvas's recognizer of a tap in the middle of the page, which shows or hides the host's
/// controls. It is timed as an edge tap is.
final class ReaderMiddleTapRecognizer: ReaderEdgeTapRecognizer {}
#endif
