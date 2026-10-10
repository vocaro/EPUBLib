#if os(macOS)
import AppKit
import SwiftUI

/// A TextKit 2 `NSTextView` over its own content storage: a page column (one fixed slice that
/// never scrolls) or the continuous-scroll view's document.
final class ReaderTextView: NSTextView {
    let contentStorage: NSTextContentStorage
    let readerLayoutManager: NSTextLayoutManager
    let readerContainer: ReaderTextContainer
    let isPageColumn: Bool
    var placement = ReaderTextPlacement()
    weak var canvas: ReaderCanvasView?
    /// The accessibility element of each textual attachment, by its location.
    private var attachmentElements: [Int: NSAccessibilityElement] = [:]
    /// The text column's left edge in continuous scroll, where a division can move it off centre.
    var columnMinX: CGFloat = 0

    init(pageColumn: Bool) {
        (contentStorage, readerLayoutManager, readerContainer) = Self.makeTextKitStack()
        isPageColumn = pageColumn
        super.init(frame: .zero, textContainer: readerContainer)
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        isAutomaticLinkDetectionEnabled = false
        isIncrementalSearchingEnabled = false
        usesFindBar = false
        linkTextAttributes = [.cursor: NSCursor.pointingHand] // The builder colors links.
        readerContainer.widthTracksTextView = false
        if pageColumn {
            isVerticallyResizable = false
            isHorizontallyResizable = false
            clipsToBounds = true
            textContainerInset = .zero
        } else {
            isVerticallyResizable = true
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            minSize = .zero
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textContainerInset = NSSize(width: 0, height: ReaderCanvasGeometry.verticalMargin)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return isPageColumn ? origin : NSPoint(x: columnMinX, y: origin.y)
    }

    /// The text container's origin in this view's coordinates.
    var containerOrigin: CGPoint { textContainerOrigin }

    // Copy (and services) carry the reader's text: attachments as their alt text, never U+FFFC.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return pboard.setString(plainText(in: selectedRange), forType: .string)
    }

    // MARK: Keys, links and accessibility

    override func keyDown(with event: NSEvent) {
        guard let canvas, let forward = Self.pageTurnDirection(for: event, controls: canvas.configuration.pageControls) else { return super.keyDown(with: event) }
        canvas.turnPageFromInput(forward: forward)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let canvas, canvas.handlePageKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    static func pageTurnDirection(for event: NSEvent, controls: EPUBPageControls = .init()) -> Bool? {
        let key: EPUBPageKey
        switch event.keyCode {
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 116: key = .pageUp
        case 121: key = .pageDown
        case 115: key = .home
        case 119: key = .end
        case 49: key = .space
        default:
            guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
                  let character = characters.first else { return nil }
            key = .character(character)
        }
        var modifiers: EPUBPageKeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return controls.direction(for: key, modifiers: modifiers)
    }

    // A link is activated, never dragged out as a URL or previewed (its scheme is private).
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        link(at: convert(event.locationInWindow, from: nil)) != nil
            ? false : super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    override func quickLook(with event: NSEvent) {
        if link(at: convert(event.locationInWindow, from: nil)) == nil { super.quickLook(with: event) }
    }

    // A click in the canvas's edge zone turns the page; a drag from there still selects.
    override func mouseDown(with event: NSEvent) {
        guard let canvas, isPageColumn, event.clickCount == 1,
              let forward = canvas.edgeTurn(at: canvas.convert(event.locationInWindow, from: nil)),
              let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture,
                                           inMode: .eventTracking, dequeue: false),
              next.type == .leftMouseUp else { return super.mouseDown(with: event) }
        _ = window?.nextEvent(matching: .leftMouseUp)
        canvas.turnPageFromInput(forward: forward)
    }

    // VoiceOver reads the page, not the clipped context after it. The characters stay as they
    // are (attachments as U+FFFC) so every accessibility range matches the text.
    override func accessibilityValue() -> String? {
        isPageColumn ? plainCharacters(in: shownCharacters) : super.accessibilityValue()
    }

    private func plainCharacters(in range: NSRange) -> String {
        guard let storage = contentStorage.textStorage else { return "" }
        return (storage.string as NSString).substring(with: NSIntersectionRange(range, NSRange(location: 0, length: storage.length)))
    }

    /// A TextKit 2 text view exposes nothing for an attachment drawn from its image, so each one
    /// that stands for text gets an image element labelled with its text equivalent, through
    /// the attachment attribute VoiceOver reads in text.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let base = super.accessibilityAttributedString(for: range) else { return nil }
        let attachments = textualAttachments(in: range)
        guard !attachments.isEmpty else { return base }
        let result = NSMutableAttributedString(attributedString: base)
        for (_, text, run) in attachments {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length else { continue }
            result.addAttribute(.accessibilityAttachment, value: accessibilityElement(at: run, label: text), range: local)
        }
        return result
    }

    private func accessibilityElement(at range: NSRange, label: String) -> NSAccessibilityElement {
        let element = attachmentElements[range.location] ?? NSAccessibilityElement()
        attachmentElements[range.location] = element
        element.setAccessibilityRole(.image)
        element.setAccessibilityLabel(label)
        element.setAccessibilityParent(self)
        let frame = segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
        if !frame.isNull {
            let origin = containerOrigin
            element.setAccessibilityFrameInParentSpace(frame.offsetBy(dx: origin.x, dy: origin.y))
        }
        return element
    }

    func exposeTextualAttachments() {
        attachmentElements.removeAll()
    }

    override func accessibilityNumberOfCharacters() -> Int {
        isPageColumn ? min(placement.visibleLength, textLength) : super.accessibilityNumberOfCharacters()
    }
}
#endif
