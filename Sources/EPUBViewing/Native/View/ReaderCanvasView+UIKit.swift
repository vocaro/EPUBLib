#if os(iOS)
import UIKit

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
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        updateInputHandlers()
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning(_:)),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    /// Disabled recognizers cannot compete with a host gesture, even before recognition.
    func updateInputHandlers() {
        for recognizer in gestureRecognizers ?? [] {
            if recognizer is UISwipeGestureRecognizer {
                recognizer.isEnabled = configuration.flow == .paginated && configuration.pageControls.touchSwipesEnabled
            } else if recognizer is UITapGestureRecognizer {
                recognizer.isEnabled = configuration.flow == .paginated && configuration.pageControls.edgeTapsEnabled
            }
        }
        UIMenuSystem.main.setNeedsRebuild()
        if isFirstResponder { reloadInputViews() }
        for view in textViews where view.isFirstResponder { view.reloadInputViews() }
    }

    @objc private func memoryWarning(_ notification: Notification) { trimCaches() }

    func applyAppearance() {
        let dark = configuration.isDark
        overrideUserInterfaceStyle = dark ? .dark : .light
        backgroundColor = ReaderPalette.background(dark: dark)
        scrollTextView?.backgroundColor = ReaderPalette.background(dark: dark)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A rotation or bar animation keeps the spread on screen and paginates once it is over.
        let duration = UIView.inheritedAnimationDuration
        if duration > 0, configuration.flow == .paginated, spread != nil { deferLayout(for: duration) }
        layOutCanvas()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// Paginated pages keep clear of the bars; continuous scroll runs under them.
    var pageArea: CGRect { bounds.inset(by: safeAreaInsets) }

    func makeColumnView() -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.delegate = self
        addSubview(view)
        return view
    }

    func makeScrollView() -> (PlatformView, ReaderTextView) {
        let view = ReaderTextView(pageColumn: false)
        view.delegate = self
        view.backgroundColor = ReaderPalette.background(dark: configuration.isDark)
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

    /// A tap within a configured physical edge zone turns the page, unless it lands on a
    /// link, text is selected, or the touch was a long press (a selection beginning).
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let down = pointerDown, ProcessInfo.processInfo.systemUptime - down.time < 0.35,
              let forward = edgeTurn(at: recognizer.location(in: self)) else { return }
        turnPageFromInput(forward: forward)
    }

    // Swipes never begin while text is selected, so dragging a selection handle never turns the
    // page; edge taps begin only in the zones.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === self else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard imageInspector == nil, configuration.flow == .paginated, !hasSelection, !isDraggingSelection else { return false }
        if gestureRecognizer is UISwipeGestureRecognizer { return configuration.pageControls.touchSwipesEnabled && !hasSelection }
        if gestureRecognizer is UITapGestureRecognizer { return edgeTurn(at: gestureRecognizer.location(in: self)) != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer.isEnabled else { return false }
        if gestureRecognizer is UITapGestureRecognizer { pointerDown = (touch.location(in: self), touch.timestamp) }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// The host may focus the canvas for hardware keys; it never takes focus on its own, which
    /// would dismiss a keyboard elsewhere in the window.
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
            return ReaderTextView.pageTurnDirection(input: command.input, flags: command.modifierFlags,
                                                    controls: configuration.pageControls) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func pageTurnKeyCommand(_ command: UIKeyCommand) {
        guard imageInspector == nil, let forward = ReaderTextView.pageTurnDirection(input: command.input, flags: command.modifierFlags,
                                                             controls: configuration.pageControls) else { return }
        turnPageFromInput(forward: forward)
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
    /// the announcement, so that if one phrase cuts the other short it is the page's number
    /// that is lost and not a line of the book.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard imageInspector == nil, configuration.flow == .paginated, !hasSelection, !isDraggingSelection else { return false }
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
        accessibilityCursorFollowsThePage(to: visibleRange?.start)
        return true
    }

    /// Sends an assistive technology's cursor to the page now shown, when the line it was on
    /// is no longer there. VoiceOver keeps its cursor on the element it was given, and a line
    /// of a page that has been turned is no element of the page shown: the cursor stayed drawn
    /// where the line had stood, and the next move went by that element, out of the text to
    /// whatever follows the reader, or to the middle of the new page (`index(ofAccessibilityElement:)`).
    /// So VoiceOver is told the layout changed and given the line that holds `position`, the
    /// position shown: the page's first line after a page turn, and the line of a link's
    /// target after a link. It reads that line and goes on from it. A cursor that is not in
    /// the text, as on a host's page button, is left where it is, and so is one whose line is
    /// still on the page.
    func accessibilityCursorFollowsThePage(to position: ReaderTextPosition?) {
        guard !accessibilityCursorIsHeld, columns.contains(where: \.accessibilityCursorHasLeftThePage) else { return }
        let shown = columns.filter { !$0.isHidden }
        var line: Any?, found = false
        for view in shown where line == nil {
            if found { line = view.accessibilityLine(from: 0) }
            else if let position, let local = localRange(of: ReaderTextRange(section: position.section, position.offset..<(position.offset + 1)), in: view) {
                found = true
                line = view.accessibilityLine(from: local.location)
            }
        }
        postAccessibilityNotification(.layoutChanged, line ?? shown.lazy.compactMap { $0.accessibilityLine(from: 0) }.first)
    }

    /// Shows `position` for VoiceOver's rotor, which takes the cursor to the item it is given.
    func showForAccessibilityRotor(_ position: ReaderTextPosition) {
        accessibilityCursorIsHeld = true
        defer { accessibilityCursorIsHeld = false }
        show(position, selecting: nil)
    }

    // MARK: Notes

    /// A popover from the nearest view controller; nothing without one.
    func presentNote(_ text: NSAttributedString, from rect: CGRect) {
        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var presenter = responder as? UIViewController, window != nil else { return }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        let controller = ReaderNoteViewController(text: text, dark: configuration.isDark,
                                                  width: min(360, max(200, bounds.width - 32)))
        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = rect
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = controller
        }
        presenter.present(controller, animated: true)
        presentedNote = controller
    }
}

/// A note shown in place: its text in a TextKit 2 view whose links do nothing.
final class ReaderNoteViewController: UIViewController, UIPopoverPresentationControllerDelegate, UITextViewDelegate {
    let textView = ReaderTextView(pageColumn: false)

    init(text: NSAttributedString, dark: Bool, width: CGFloat) {
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = dark ? .dark : .light
        textView.delegate = self
        textView.backgroundColor = ReaderPalette.background(dark: dark)
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

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? { nil }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? { nil }
}
#endif
