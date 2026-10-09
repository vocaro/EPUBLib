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
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning(_:)),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
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
        if scrollView === scrollTextView { scrollPositionDidChange() }
    }

    /// The safe area changed under the scroll view (bars shown or hidden).
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        if scrollView === scrollTextView { updateScrollViewport() }
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, let view = textView as? ReaderTextView else { return nil }
        let range = textItem.range
        return UIAction { [weak self, weak view] _ in
            guard let self, let view else { return }
            self.activateLink(url, range: range, in: view)
        }
    }

    /// No link previews or link menus: links use a private scheme and are never opened.
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? { nil }

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
        guard configuration.flow == .paginated else { return }
        turnPageFromInput(forward: ReaderCanvasInput.swipeDirection(
            towardsLeft: recognizer.direction == .left, isRightToLeft: configuration.isRightToLeft))
    }

    /// A tap within 56 points of the left or right edge turns the page, unless it lands on a
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
        guard configuration.flow == .paginated else { return false }
        if gestureRecognizer is UISwipeGestureRecognizer { return !hasSelection }
        if gestureRecognizer is UITapGestureRecognizer { return edgeTurn(at: gestureRecognizer.location(in: self)) != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer { pointerDown = (touch.location(in: self), touch.timestamp) }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// The host may focus the canvas for hardware keys; it never takes focus on its own, which
    /// would dismiss a keyboard elsewhere in the window.
    override var canBecomeFirstResponder: Bool { true }

    /// Page-turn keys for the canvas and its text views. They take priority over the text
    /// views' own arrow-key handling; Shift-arrow, Command, Option and Control chords stay theirs.
    override var keyCommands: [UIKeyCommand]? {
        let keys: [(String, UIKeyModifierFlags)] = [
            (UIKeyCommand.inputLeftArrow, []), (UIKeyCommand.inputRightArrow, []), (UIKeyCommand.inputPageUp, []),
            (UIKeyCommand.inputPageDown, []), (" ", []), (" ", .shift)]
        return keys.map { input, flags in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(pageTurnKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc func pageTurnKeyCommand(_ command: UIKeyCommand) {
        guard let forward = ReaderTextView.pageTurnDirection(input: command.input, flags: command.modifierFlags) else { return }
        turnPageFromInput(forward: forward)
    }

    /// VoiceOver's three-finger swipes turn pages: towards the left or up reads forward (mirrored
    /// right to left), and the page is announced.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard configuration.flow == .paginated else { return false }
        let forward: Bool
        switch direction {
        case .left: forward = !configuration.isRightToLeft
        case .right: forward = configuration.isRightToLeft
        case .up, .next: forward = true
        case .down, .previous: forward = false
        @unknown default: return false
        }
        guard turnPage(forward: forward) != .atBoundary else { return false }
        if let shownPage {
            UIAccessibility.post(notification: .pageScrolled, argument: "Page \(shownPage.page + 1)")
        }
        return true
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
