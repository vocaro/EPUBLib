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
    weak var canvas: ReaderCanvasView?

    init(pageColumn: Bool) {
        (contentStorage, readerLayoutManager, readerContainer) = Self.makeTextKitStack()
        isPageColumn = pageColumn
        super.init(frame: .zero, textContainer: readerContainer)
        isEditable = false
        isSelectable = true
        dataDetectorTypes = []
        linkTextAttributes = [:] // The builder colors links.
        backgroundColor = .clear
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

    // Copy carries the reader's text: attachments as their alt text, never U+FFFC.
    override func copy(_ sender: Any?) {
        let text = plainText(in: selectedRange)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    // MARK: Keys and accessibility

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let canvas, let forward = presses.lazy.compactMap({ Self.pageTurnDirection(for: $0) }).first else {
            return super.pressesBegan(presses, with: event)
        }
        canvas.turnPageFromInput(forward: forward)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard canvas == nil || !presses.contains(where: { Self.pageTurnDirection(for: $0) != nil }) else { return }
        super.pressesEnded(presses, with: event)
    }

    /// The page-turn direction of a hardware key press, through `ReaderEPUBPageTurnKey`.
    static func pageTurnDirection(for press: UIPress) -> Bool? {
        guard let key = press.key else { return nil }
        let equivalent: KeyEquivalent
        switch key.keyCode {
        case .keyboardLeftArrow: equivalent = .leftArrow
        case .keyboardRightArrow: equivalent = .rightArrow
        case .keyboardPageUp: equivalent = .pageUp
        case .keyboardPageDown: equivalent = .pageDown
        case .keyboardSpacebar: equivalent = .space
        default: return nil
        }
        let flags = key.modifierFlags
        return ReaderCanvasInput.direction(for: equivalent, shift: flags.contains(.shift),
                                           otherModifiers: !flags.isDisjoint(with: [.command, .alternate, .control]))
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard isPageColumn, let canvas else { return super.accessibilityScroll(direction) }
        return canvas.accessibilityScroll(direction)
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
#endif
