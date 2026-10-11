#if os(iOS)
import SwiftUI
import UIKit

/// A TextKit 2 `UITextView` over its own content storage: a page column (one fixed slice that
/// never scrolls) or the continuous-scroll view.
final class ReaderTextView: UITextView {
    let contentStorage: NSTextContentStorage
    let readerLayoutManager: NSTextLayoutManager
    let readerContainer: ReaderTextContainer
    let isPageColumn: Bool
    var placement = ReaderTextPlacement()
    var flowSourceText: NSAttributedString?
    var tableInteraction: ReaderTableInteraction?
    var containsTableRows = false
    weak var canvas: ReaderCanvasView?
    private var pageAccessibilityCache: [ReaderPageAccessibilityElement]?
    private var imageGestureDelegate: ReaderImageGestureDelegate?
    private var selectionGestureDelegate: ReaderSpreadSelectionGestureDelegate?

    init(pageColumn: Bool) {
        (contentStorage, readerLayoutManager, readerContainer) = Self.makeTextKitStack()
        isPageColumn = pageColumn
        super.init(frame: .zero, textContainer: readerContainer)
        isEditable = false
        isSelectable = true
        dataDetectorTypes = []
        linkTextAttributes = [:] // The builder colors links.
        backgroundColor = .clear
        let imageDelegate = ReaderImageGestureDelegate(view: self)
        imageGestureDelegate = imageDelegate
        let imageTap = UITapGestureRecognizer(target: imageDelegate, action: #selector(ReaderImageGestureDelegate.openImage(_:)))
        imageTap.numberOfTapsRequired = 2
        imageTap.delegate = imageDelegate
        addGestureRecognizer(imageTap)
        if pageColumn { selectionGestureDelegate = ReaderSpreadSelectionGestureDelegate.install(on: self) }
        textContainerInset = .zero
        textDragInteraction?.isEnabled = false
        if pageColumn {
            isScrollEnabled = false
            readerContainer.widthTracksTextView = false
            contentInsetAdjustmentBehavior = .never
            showsVerticalScrollIndicator = false
            clipsToBounds = true
        } else {
            readerContainer.widthTracksTextView = true
            alwaysBounceVertical = true
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text container's origin in this view's coordinates.
    var containerOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }

    // A page column shows its slice from the top, always: UIKit's selection autoscroll must not
    // reveal the clipped context line.
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = isPageColumn ? .zero : newValue }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(isPageColumn ? .zero : contentOffset, animated: animated)
    }

    /// Where Copy writes; the general pasteboard outside tests.
    var pasteboard = UIPasteboard.general

    // Copy carries the reader's text: attachments as their alt text, never U+FFFC.
    override func copy(_ sender: Any?) {
        let text = canvas?.selectionText(for: self) ?? plainText(in: selectedRange)
        guard !text.isEmpty else { return }
        pasteboard.string = text
    }

    // MARK: Keys and accessibility

    override var keyCommands: [UIKeyCommand]? {
        guard let canvas else { return super.keyCommands }
        let pageCommands = canvas.pageKeyCommands
        // Replace only explicitly bound native text commands. Removed bindings fall back to
        // the text view's ordinary selection/scroll handling.
        let native = (super.keyCommands ?? []).filter { command in
            !pageCommands.contains { $0.input == command.input && $0.modifierFlags == command.modifierFlags }
        }
        return pageCommands + native
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(pageTurnKeyCommand(_:)), let command = sender as? UIKeyCommand {
            guard let canvas else { return false }
            return Self.pageTurnDirection(input: command.input, flags: command.modifierFlags,
                                          controls: canvas.configuration.pageControls) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func pageTurnKeyCommand(_ command: UIKeyCommand) { canvas?.pageTurnKeyCommand(command) }

    static func pageTurnDirection(input: String?, flags: UIKeyModifierFlags,
                                  controls: EPUBPageControls = .init()) -> Bool? {
        guard let input, let key = EPUBPageKey(uiInput: input) else { return nil }
        return controls.direction(for: key, modifiers: EPUBPageKeyModifiers(uiFlags: flags))
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard isPageColumn, let canvas else { return super.accessibilityScroll(direction) }
        return canvas.accessibilityScroll(direction)
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let rect = bounds.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
            guard let range = visibleCharacterRange(in: rect) else { return super.accessibilityCustomActions }
            let actions = imageAttachments(in: range).map { image, _ in
                UIAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") {
                    [weak self] _ in
                    self?.canvas?.inspectImage(image)
                    return self?.canvas != nil
                }
            }
            let tableActions = (tableInteraction?.accessibilityActions() ?? []).map { action in
                UIAccessibilityCustomAction(name: action.name) { _ in action.perform() }
            }
            return (super.accessibilityCustomActions ?? []) + actions + tableActions
        }
        set { super.accessibilityCustomActions = newValue }
    }

    // UIKit's native text accessibility can traverse TextKit's hidden paragraph context even
    // with a shortened accessibilityValue. Expose only measured visible lines, splitting links
    // and attachments into independently actionable elements. Visual text and selection retain
    // the original TextKit 2 storage and all of its paragraph layout context.
    override var isAccessibilityElement: Bool {
        get { isPageColumn ? false : super.isAccessibilityElement }
        set { super.isAccessibilityElement = newValue }
    }

    override var accessibilityElements: [Any]? {
        get { isPageColumn ? pageAccessibilityElements : super.accessibilityElements }
        set { super.accessibilityElements = newValue }
    }

    override func accessibilityElementCount() -> Int {
        isPageColumn ? pageAccessibilityElements.count : super.accessibilityElementCount()
    }

    override func accessibilityElement(at index: Int) -> Any? {
        guard isPageColumn else { return super.accessibilityElement(at: index) }
        let elements = pageAccessibilityElements
        return elements.indices.contains(index) ? elements[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard isPageColumn else { return super.index(ofAccessibilityElement: element) }
        return pageAccessibilityElements.firstIndex { $0 === element as AnyObject } ?? NSNotFound
    }

    private var pageAccessibilityElements: [ReaderPageAccessibilityElement] {
        if let pageAccessibilityCache { return pageAccessibilityCache }
        guard let storage = contentStorage.textStorage else { return [] }
        var elements: [ReaderPageAccessibilityElement] = []
        for line in pageAccessibilityLines {
            // Layout flags (often stored on a paragraph's first UTF-16 unit), colors and
            // fonts do not define AX reading units. Keep each actual line intact except
            // where a link or attachment needs its own label and activation behavior.
            var runs: [(range: NSRange, url: URL?, attachment: NSTextAttachment?)] = []
            storage.enumerateAttributes(in: line.range) { attributes, range, _ in
                let url = attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:))
                let attachment = attributes[.attachment] as? NSTextAttachment
                if let previous = runs.last, NSMaxRange(previous.range) == range.location,
                   previous.url == url, previous.attachment === attachment {
                    runs[runs.count - 1].range.length += range.length
                } else { runs.append((range, url, attachment)) }
            }
            for (range, url, attachment) in runs {
                let element = ReaderPageAccessibilityElement(view: self, range: range, url: url)
                element.accessibilityLabel = plainText(in: range)
                var traits: UIAccessibilityTraits = url == nil ? .staticText : .link
                if attachment != nil {
                    traits.insert(.image)
                    if let image = attachment as? ReaderImageAttachment {
                        element.accessibilityLabel = image.alt.isEmpty ? "Book image" : image.alt
                    }
                    // A formula's reading has its own voice: the book's language or the generator's.
                    if let language = (attachment as? ReaderTextualAttachment)?.textLanguage {
                        element.accessibilityLanguage = language
                    }
                }
                element.accessibilityTraits = traits
                let frame = segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
                element.accessibilityFrameInContainerSpace = (frame.isNull ? line.frame : frame)
                    .offsetBy(dx: containerOrigin.x, dy: containerOrigin.y).intersection(bounds)
                elements.append(element)
            }
        }
        pageAccessibilityCache = elements
        return elements
    }

    // VoiceOver reads the page, not the clipped context after it, with attachments as their text.
    override var accessibilityValue: String? {
        get { isPageColumn ? visibleText : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }

    /// UIKit reads an attachment in text by its accessibility label: give each one that stands
    /// for text its text equivalent, unless it labels itself.
    func exposeTextualAttachments() {
        pageAccessibilityCache = nil
        for (attachment, text, _) in textualAttachments() where attachment.accessibilityLabel == nil {
            attachment.accessibilityLabel = text
        }
    }
}

/// A bounded slice of one visible line. VoiceOver's word/character navigation operates on
/// this label rather than the native text view's longer paragraph storage.
@MainActor private final class ReaderPageAccessibilityElement: UIAccessibilityElement {
    weak var view: ReaderTextView?
    let range: NSRange
    let url: URL?

    init(view: ReaderTextView, range: NSRange, url: URL?) {
        self.view = view
        self.range = range
        self.url = url
        super.init(accessibilityContainer: view)
        isAccessibilityElement = true
    }

    override func accessibilityActivate() -> Bool {
        guard let view, let canvas = view.canvas else { return false }
        if let url { canvas.activateLink(url, range: range, in: view); return true }
        if let image = view.imageAttachments(in: range).first?.image { canvas.inspectImage(image); return true }
        return false
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        view?.accessibilityScroll(direction) ?? false
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let view else { return nil }
            var actions = [true, false].map { forward in
                UIAccessibilityCustomAction(name: forward ? "Next Page" : "Previous Page") { [weak view] _ in
                    guard let canvas = view?.canvas else { return false }
                    canvas.turnPageFromInput(forward: forward)
                    return true
                }
            }
            actions += view.imageAttachments(in: range).map { image, _ in
                UIAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") { [weak view] _ in
                    guard let canvas = view?.canvas else { return false }
                    canvas.inspectImage(image)
                    return true
                }
            }
            if view.contentStorage.textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) is TableRowAttachment {
                actions += (view.tableInteraction?.accessibilityActions() ?? []).map { action in
                    UIAccessibilityCustomAction(name: action.name) { _ in action.perform() }
                }
            }
            return actions
        }
        set { super.accessibilityCustomActions = newValue }
    }
}

/// Observes native selection gestures simultaneously and takes over only when their endpoint
/// crosses into the other column. Long press starts a selection; pan extends a native handle.
@MainActor final class ReaderSpreadSelectionGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var view: UIView?
    private weak var activeGesture: UIGestureRecognizer?
    private var crossesSurface = false
    init(view: UIView) { self.view = view }

    static func install(on view: UIView) -> ReaderSpreadSelectionGestureDelegate {
        let delegate = ReaderSpreadSelectionGestureDelegate(view: view)
        let drag = UIPanGestureRecognizer(target: delegate, action: #selector(Self.drag(_:)))
        drag.delegate = delegate
        drag.maximumNumberOfTouches = 1
        drag.cancelsTouchesInView = false
        view.addGestureRecognizer(drag)
        let press = UILongPressGestureRecognizer(target: delegate, action: #selector(Self.drag(_:)))
        press.minimumPressDuration = 0.45
        press.delegate = delegate
        press.cancelsTouchesInView = false
        view.addGestureRecognizer(press)
        return delegate
    }

    private var canvas: ReaderCanvasView? {
        (view as? ReaderTextView)?.canvas ?? (view as? TableCellTextView)?.canvas
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view, let canvas, canvas.imageInspector == nil,
              canvas.columns.filter({ !$0.isHidden }).count > 1 else { return false }
        let point = recognizer.location(in: view)
        let selected: NSRange
        if let body = view as? ReaderTextView {
            guard body.tableInteraction?.selectionPosition(at: point) == nil else { return false }
            guard body.link(at: point) == nil, body.image(at: point) == nil else { return false }
            selected = body.selectedRange
        } else if let cell = view as? TableCellTextView {
            guard cell.cellLink(at: point) == nil, cell.cellImage(at: point) == nil else { return false }
            selected = cell.cellSelection
        } else { return false }
        return recognizer is UILongPressGestureRecognizer || selected.length > 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    @objc func drag(_ recognizer: UIGestureRecognizer) {
        guard let view, let canvas else { return }
        let point = recognizer.location(in: canvas)
        switch recognizer.state {
        case .began:
            guard activeGesture == nil, let position = canvas.selectionPosition(at: point) else { return }
            activeGesture = recognizer
            crossesSurface = false
            var anchor = position
            if recognizer is UIPanGestureRecognizer, let selection = canvas.currentSelection {
                func distance(to endpoint: ReaderTextPosition) -> Int {
                    if let cell = position.tableCell, let target = endpoint.tableCell,
                       cell.table == target.table, cell.cell == target.cell {
                        return abs(cell.offset - target.offset)
                    }
                    if position.offset == endpoint.offset, position.tableCell != endpoint.tableCell { return Int.max }
                    return abs(position.offset - endpoint.offset)
                }
                anchor = distance(to: selection.range.start) < distance(to: selection.range.end)
                    ? selection.range.end : selection.range.start
            }
            canvas.beginSelectionDrag(at: anchor)
        case .changed:
            guard activeGesture === recognizer, let end = canvas.selectionPosition(at: point) else { return }
            if !view.convert(view.bounds, to: canvas).contains(point) { crossesSurface = true }
            if crossesSurface { canvas.extendSelectionDrag(to: end) }
        case .ended, .cancelled, .failed:
            guard activeGesture === recognizer else { return }
            if crossesSurface, let end = canvas.selectionPosition(at: point) { canvas.extendSelectionDrag(to: end) }
            canvas.endSelectionDrag()
            activeGesture = nil
        default: break
        }
    }
}

@MainActor private final class ReaderImageGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var view: ReaderTextView?
    init(view: ReaderTextView) { self.view = view }
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        let point = recognizer.location(in: view)
        guard view.tableInteraction?.selectionPosition(at: point) == nil else { return false }
        return view.image(at: point) != nil && view.link(at: point) == nil && view.selectedRange.length == 0
    }
    @objc func openImage(_ recognizer: UITapGestureRecognizer) {
        guard let view, let image = view.image(at: recognizer.location(in: view)) else { return }
        view.canvas?.inspectImage(image)
    }
}

extension EPUBPageKey {
    var uiInput: String {
        switch self {
        case .leftArrow: UIKeyCommand.inputLeftArrow
        case .rightArrow: UIKeyCommand.inputRightArrow
        case .upArrow: UIKeyCommand.inputUpArrow
        case .downArrow: UIKeyCommand.inputDownArrow
        case .pageUp: UIKeyCommand.inputPageUp
        case .pageDown: UIKeyCommand.inputPageDown
        case .home: UIKeyCommand.inputHome
        case .end: UIKeyCommand.inputEnd
        case .space: " "
        case .character(let character): String(character)
        }
    }
    init?(uiInput: String) {
        switch uiInput {
        case UIKeyCommand.inputLeftArrow: self = .leftArrow
        case UIKeyCommand.inputRightArrow: self = .rightArrow
        case UIKeyCommand.inputUpArrow: self = .upArrow
        case UIKeyCommand.inputDownArrow: self = .downArrow
        case UIKeyCommand.inputPageUp: self = .pageUp
        case UIKeyCommand.inputPageDown: self = .pageDown
        case UIKeyCommand.inputHome: self = .home
        case UIKeyCommand.inputEnd: self = .end
        case " ": self = .space
        default:
            guard uiInput.count == 1, let character = uiInput.first else { return nil }
            self = .character(character)
        }
    }
}

extension EPUBPageKeyModifiers {
    init(uiFlags flags: UIKeyModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.alternate) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
    var uiFlags: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.alternate) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
#endif
