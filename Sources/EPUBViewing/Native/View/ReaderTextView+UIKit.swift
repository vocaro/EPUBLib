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
    weak var canvas: ReaderCanvasView?
    private var imageGestureDelegate: ReaderImageGestureDelegate?

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
        let text = plainText(in: selectedRange)
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
            return (super.accessibilityCustomActions ?? []) + actions
        }
        set { super.accessibilityCustomActions = newValue }
    }

    // VoiceOver reads the page, not the clipped context after it, with attachments as their text.
    override var accessibilityValue: String? {
        get { isPageColumn ? visibleText : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }

    /// UIKit reads an attachment in text by its accessibility label: give each one that stands
    /// for text its text equivalent, unless it labels itself.
    func exposeTextualAttachments() {
        for (attachment, text, _) in textualAttachments() where attachment.accessibilityLabel == nil {
            attachment.accessibilityLabel = text
        }
    }
}

@MainActor private final class ReaderImageGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var view: ReaderTextView?
    init(view: ReaderTextView) { self.view = view }
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        let point = recognizer.location(in: view)
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
