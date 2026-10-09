#if os(macOS)
import AppKit

// AppKit views, input, menus and popovers for `ReaderCanvasView`.
extension ReaderCanvasView: NSTextViewDelegate {
    func platformSetUp() {
        wantsLayer = true
        clipsToBounds = true // A spread kept through a live resize never draws outside the canvas.
        ReaderMemoryPressure.start()
        NotificationCenter.default.addObserver(self, selector: #selector(memoryPressure(_:)),
                                               name: ReaderMemoryPressure.notification, object: nil)
    }

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
        let dark = configuration.isDark
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        layer?.backgroundColor = ReaderPalette.background(dark: dark).cgColor
        (scrollContainer as? NSScrollView)?.backgroundColor = ReaderPalette.background(dark: dark)
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
        addSubview(view)
        return view
    }

    func makeScrollView() -> (PlatformView, ReaderTextView) {
        let scrollView = NSScrollView(frame: bounds)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ReaderPalette.background(dark: configuration.isDark)
        scrollView.automaticallyAdjustsContentInsets = true
        let textView = ReaderTextView(pageColumn: false)
        textView.delegate = self
        textView.frame = CGRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
        return (scrollView, textView)
    }

    @objc private func scrollBoundsDidChange(_ notification: Notification) {
        if (notification.object as? NSClipView)?.documentView === scrollTextView { scrollPositionDidChange() }
    }

    private var scrollView: NSScrollView? { scrollContainer as? NSScrollView }

    /// Sizes the scroll view to the canvas and places the text column, which a division can move
    /// off centre (`ReaderTextView.columnMinX`).
    func applyScrollGeometry(columnMinX: CGFloat, width: CGFloat) {
        guard let scrollView, let textView = scrollTextView else { return }
        scrollView.frame = bounds
        textView.frame.size.width = scrollView.contentSize.width
        textView.columnMinX = columnMinX - bounds.minX
        if textView.readerContainer.size.width != width {
            textView.readerContainer.size = CGSize(width: width, height: 0)
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
        // TextKit 2 grows the document as it lays out; make room for what was just laid out.
        let used = textView.readerLayoutManager.usageBoundsForTextContainer.maxY + 2 * textView.textContainerInset.height
        if textView.frame.height < used { textView.setFrameSize(NSSize(width: textView.frame.width, height: ceil(used))) }
        let target = y + textView.textContainerOrigin.y - insets.top - ReaderCanvasGeometry.verticalMargin
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(-insets.top, target), maximumScrollOffset)))
        scrollView.reflectScrolledClipView(clip)
        textView.readerLayoutManager.textViewportLayoutController.layoutViewport()
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

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        guard let forward = ReaderTextView.pageTurnDirection(for: event) else { return super.keyDown(with: event) }
        turnPageFromInput(forward: forward)
    }

    // A click within 56 points of the left or right edge turns the page (`edgeTurn(at:)`); the
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
    override func scrollWheel(with event: NSEvent) {
        guard configuration.flow == .paginated else { return super.scrollWheel(with: event) }
        // Line-based mouse wheels report lines; scale them to points as WebKit did.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let phase: ReaderWheelPageTurner.Phase =
            if !event.momentumPhase.isEmpty { .momentum }
            else if event.phase.contains(.began) || event.phase.contains(.mayBegin) { .began }
            else if event.phase.contains(.changed) { .changed }
            else if !event.phase.isEmpty { .ended }
            else { .none }
        guard let forward = wheelTurner.direction(deltaX: -event.scrollingDeltaX * scale,
                                                  deltaY: -event.scrollingDeltaY * scale, phase: phase,
                                                  isRightToLeft: configuration.isRightToLeft,
                                                  at: event.timestamp) else { return }
        turnPageFromInput(forward: forward)
    }

    // MARK: Notes

    func presentNote(_ text: NSAttributedString, from rect: CGRect) {
        guard window != nil else { return }
        (presentedNote as? NSPopover)?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: configuration.isDark ? .darkAqua : .aqua)
        popover.contentViewController = ReaderNoteViewController(
            text: text, dark: configuration.isDark, width: min(360, max(200, bounds.width - 32)))
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        presentedNote = popover
    }
}

/// A note shown in place: its text in a TextKit 2 view whose links do nothing.
final class ReaderNoteViewController: NSViewController, NSTextViewDelegate {
    let textView = ReaderTextView(pageColumn: false)
    private let dark: Bool
    private let width: CGFloat

    init(text: NSAttributedString, dark: Bool, width: CGFloat) {
        self.dark = dark
        self.width = width
        super.init(nibName: nil, bundle: nil)
        textView.delegate = self
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
        scrollView.drawsBackground = false
        textView.frame = CGRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = textView
        view = scrollView
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }
}
#endif

#if os(macOS)
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
