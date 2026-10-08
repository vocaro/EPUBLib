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

    // MARK: Keys, links and accessibility

    override func keyDown(with event: NSEvent) {
        guard let canvas, let forward = Self.pageTurnDirection(for: event) else { return super.keyDown(with: event) }
        canvas.turnPageFromInput(forward: forward)
    }

    /// The page-turn direction of a key event, through `ReaderEPUBPageTurnKey`.
    static func pageTurnDirection(for event: NSEvent) -> Bool? {
        guard ReaderEPUBPageTurnKey.command(forKeyCode: event.keyCode, hasShift: false) != nil else { return nil }
        let key: KeyEquivalent = switch event.keyCode {
        case 123: .leftArrow
        case 124: .rightArrow
        case 116: .pageUp
        case 121: .pageDown
        default: .space
        }
        let flags = event.modifierFlags
        return ReaderCanvasInput.direction(for: key, shift: flags.contains(.shift),
                                           otherModifiers: !flags.isDisjoint(with: [.command, .option, .control]))
    }

    // A link is activated, never dragged out as a URL or previewed (its scheme is private).
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        isOverLink(event) ? false : super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    override func quickLook(with event: NSEvent) {
        if !isOverLink(event) { super.quickLook(with: event) }
    }

    private func isOverLink(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let origin = containerOrigin
        guard let fragment = readerLayoutManager.textLayoutFragment(
            for: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) else { return false }
        let local = CGPoint(x: point.x - origin.x - fragment.layoutFragmentFrame.minX,
                            y: point.y - origin.y - fragment.layoutFragmentFrame.minY)
        let start = offset(of: fragment.rangeInElement.location)
        for line in fragment.textLineFragments where line.typographicBounds.contains(local) {
            let index = start + line.characterIndex(for: CGPoint(x: local.x - line.typographicBounds.minX,
                                                                  y: local.y - line.typographicBounds.minY))
            return index < textLength && contentStorage.textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
        }
        return false
    }

    // VoiceOver reads the page, not the clipped context line after it.
    override func accessibilityValue() -> String? {
        isPageColumn ? visibleString : super.accessibilityValue()
    }

    override func accessibilityNumberOfCharacters() -> Int {
        isPageColumn ? min(placement.visibleLength, textLength) : super.accessibilityNumberOfCharacters()
    }
}
#endif
