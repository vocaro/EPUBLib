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
    var flowSourceText: NSAttributedString?
    /// The text shown has boxes resolved against the viewport (`refreshFlowBoxLayout`), so a
    /// new viewport size lays all of it out anew.
    var layoutFollowsViewport = false
    var tableInteraction: ReaderTableInteraction?
    var containsTableRows = false
    weak var canvas: ReaderCanvasView?
    /// The accessibility element of each textual attachment, by its location.
    private var attachmentElements: [Int: NSAccessibilityElement] = [:]
    private var menuImage: ReaderImageAttachment?
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

    /// Asks for the text already on screen to be drawn again. The text view draws each laid-out
    /// fragment in a view of its own beneath it, which its own `needsDisplay` does not reach.
    func setRenderedTextNeedsDisplay() {
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidate)
        }
        subviews.forEach(invalidate)
    }

    // Copy (and services) carry the reader's text: attachments as their alt text, never U+FFFC.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return pboard.setString(canvas?.selectionText(for: self) ?? plainText(in: selectedRange), forType: .string)
    }

    // MARK: Keys, links and accessibility

    override func keyDown(with event: NSEvent) {
        guard let canvas, canvas.imageInspector == nil, let forward = Self.pageTurnDirection(for: event, controls: canvas.configuration.pageControls) else { return super.keyDown(with: event) }
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
        let point = convert(event.locationInWindow, from: nil)
        if let image = image(at: point) { canvas?.inspectImage(image) }
        else if link(at: point) == nil { super.quickLook(with: event) }
    }

    // A click in the canvas's edge zone turns the page; a drag from there still selects.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let image = image(at: point), link(at: point) == nil {
            if event.clickCount == 2 { canvas?.inspectImage(image); return }
            return super.mouseDown(with: event)
        }
        if let canvas, isPageColumn, link(at: point) == nil,
           canvas.handleSpreadSelectionMouseDown(event) { return }
        guard let canvas, isPageColumn, event.clickCount == 1,
              let forward = canvas.edgeTurn(at: canvas.convert(event.locationInWindow, from: nil)),
              let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture,
                                           inMode: .eventTracking, dequeue: false),
              next.type == .leftMouseUp else { return super.mouseDown(with: event) }
        _ = window?.nextEvent(matching: .leftMouseUp)
        canvas.turnPageFromInput(forward: forward)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menuImage = image(at: convert(event.locationInWindow, from: nil))
        if menuImage != nil {
            let item = NSMenuItem(title: "Inspect Image", action: #selector(inspectMenuImage), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func inspectMenuImage() {
        if let image = menuImage { canvas?.inspectImage(image) }
        menuImage = nil
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
    /// the attachment attribute VoiceOver reads in text. A hidden label is text, not an image.
    /// An image without words is an image element without a label, and one the book marks as
    /// decoration is left with nothing, for VoiceOver to pass over.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard !isPageColumn || validPageAccessibilityRange(range),
              let base = super.accessibilityAttributedString(for: range) else { return nil }
        let attachments = textualAttachments(in: range)
        let images = announcedImages(in: range)
        let rules = rules(in: range)
        guard !attachments.isEmpty || !images.isEmpty || !rules.isEmpty else { return base }
        let result = NSMutableAttributedString(attributedString: base)
        for run in rules {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length else { continue }
            result.addAttribute(.accessibilityAttachment, value: ruleElement(at: run), range: local)
        }
        for (attachment, text, run) in attachments {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length else { continue }
            let element = accessibilityElement(at: run, label: text, isText: attachment is SpokenLabelAttachment)
            if attachment is TableRowAttachment, let cells = tableInteraction?.accessibilityCells(at: run.location), !cells.isEmpty {
                element.setAccessibilityRole(.group)
                element.setAccessibilityLabel("Table row")
                element.setAccessibilityChildren(cells)
            }
            result.addAttribute(.accessibilityAttachment, value: element, range: local)
            // A formula's reading has its own voice: the book's language or the generator's.
            if let language = (attachment as? ReaderTextualAttachment)?.textLanguage {
                result.addAttribute(.accessibilityLanguage, value: language, range: local)
            }
        }
        var exposed = Set<NSRange>()
        for (image, run) in images where exposed.insert(run).inserted {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length else { continue }
            // The role says that it is an image, in VoiceOver's own language: no name is made up.
            let label = attachments.first { $0.range == run }?.text ?? image.alt
            let element = accessibilityElement(at: run, label: label)
            // VoiceOver reads the help of an element without a label as its name, in the line.
            element.setAccessibilityHelp(label.isEmpty ? nil : "Double-click or choose Inspect Image to enlarge.")
            let actions = images.filter { $0.range == run }.map { entry in
                NSAccessibilityCustomAction(name: entry.image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(entry.image.alt)") {
                    [weak self] in
                    self?.canvas?.inspectImage(entry.image)
                    return self?.canvas != nil
                }
            }
            element.setAccessibilityCustomActions(actions)
            result.addAttribute(.accessibilityAttachment, value: element, range: local)
        }
        return result
    }

    /// The character of each rule in `range`.
    private func rules(in range: NSRange) -> [NSRange] {
        guard let storage = contentStorage.textStorage else { return [] }
        var result: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length))) { value, run, _ in
            if value is ReaderRuleAttachment { result.append(run) }
        }
        return result
    }

    // Candidate A: AppKit's splitter role and nothing else.
    private func ruleElement(at range: NSRange) -> NSAccessibilityElement {
        let element = attachmentElements[range.location] ?? NSAccessibilityElement()
        attachmentElements[range.location] = element
        element.setAccessibilityRole(.splitter)
        element.setAccessibilityParent(self)
        let frame = segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
        if !frame.isNull {
            let origin = containerOrigin
            element.setAccessibilityFrameInParentSpace(frame.offsetBy(dx: origin.x, dy: origin.y))
        }
        return element
    }

    private func accessibilityElement(at range: NSRange, label: String, isText: Bool = false) -> NSAccessibilityElement {
        let element = attachmentElements[range.location] ?? NSAccessibilityElement()
        attachmentElements[range.location] = element
        if let cells = tableInteraction?.accessibilityCells(at: range.location), !cells.isEmpty {
            element.setAccessibilityRole(.group)
            element.setAccessibilityLabel("Table row")
            element.setAccessibilityChildren(cells)
        } else if isText {
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityValue(label)
            element.setAccessibilityLabel(nil)
            element.setAccessibilityChildren(nil)
        } else {
            element.setAccessibilityRole(.image)
            element.setAccessibilityLabel(label.isEmpty ? nil : label)
            element.setAccessibilityChildren(nil)
        }
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
        // Replacing NSTextStorage moves its native caret to the new storage's end, which
        // can be hidden paragraph context, or the end of the book. VoiceOver uses that
        // caret's line when entering a text view. Start newly installed text at its first
        // line; the canvas reapplies any intentional carried selection after all columns
        // have been installed, and keeps the scroll view's caret on screen
        // (`placeScrollInsertionPoint`).
        selectedRange = NSRange(location: 0, length: 0)
        if isPageColumn {
            // The page exposes a custom bounded AXValue. TextKit's storage replacement
            // posts selection/layout changes, but does not post a value change for it.
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private func validPageAccessibilityRange(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= shownCharacters.length
            && range.length <= shownCharacters.length - range.location
    }

    private func boundedPageAccessibilityRange(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else { return range }
        let lower = min(max(0, range.location), shownCharacters.length)
        let upper = min(max(lower, NSMaxRange(range)), shownCharacters.length)
        return NSRange(location: lower, length: upper - lower)
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        isPageColumn ? shownCharacters : super.accessibilityVisibleCharacterRange()
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard isPageColumn else { return super.accessibilityString(for: range) }
        return validPageAccessibilityRange(range) ? plainCharacters(in: range) : nil
    }

    override func accessibilityRTF(for range: NSRange) -> Data? {
        guard !isPageColumn || validPageAccessibilityRange(range) else { return nil }
        return super.accessibilityRTF(for: range)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard !isPageColumn || validPageAccessibilityRange(range) else { return .zero }
        return super.accessibilityFrame(for: range)
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        guard isPageColumn else { return super.accessibilityRange(for: index) }
        guard index >= 0, index < shownCharacters.length,
              let text = contentStorage.textStorage?.string as NSString? else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return boundedPageAccessibilityRange(text.rangeOfComposedCharacterSequence(at: index))
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard isPageColumn else { return super.accessibilityRange(for: point) }
        guard let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard bounds.contains(local) else { return NSRange(location: NSNotFound, length: 0) }
        return accessibilityRange(for: characterOffset(at: local))
    }

    override func accessibilityStyleRange(for index: Int) -> NSRange {
        guard isPageColumn else { return super.accessibilityStyleRange(for: index) }
        guard index >= 0, index < shownCharacters.length, let storage = contentStorage.textStorage else {
            return NSRange(location: NSNotFound, length: 0)
        }
        var range = NSRange()
        _ = storage.attributes(at: index, effectiveRange: &range)
        return boundedPageAccessibilityRange(range)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard isPageColumn else { return super.accessibilityRange(forLine: line) }
        let lines = pageAccessibilityLines
        return lines.indices.contains(line) ? lines[line].range : NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityLine(for index: Int) -> Int {
        guard isPageColumn else { return super.accessibilityLine(for: index) }
        // The insertion point after the page's last character is on its last line, and so is
        // an offset VoiceOver kept from a longer previous page. Without a line there, it
        // announces 9,223,372,036,854,775,808 visible lines or reads nothing on entering.
        let lines = pageAccessibilityLines
        guard index >= 0, !lines.isEmpty else { return NSNotFound }
        return lines.firstIndex { NSLocationInRange(index, $0.range) } ?? lines.count - 1
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        isPageColumn ? boundedPageAccessibilityRange(selectedRange) : super.accessibilitySelectedTextRange()
    }

    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        isPageColumn ? [NSValue(range: accessibilitySelectedTextRange())] : super.accessibilitySelectedTextRanges()
    }

    override func accessibilitySelectedText() -> String? {
        isPageColumn ? plainCharacters(in: accessibilitySelectedTextRange()) : super.accessibilitySelectedText()
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard isPageColumn else { return super.setAccessibilitySelectedTextRange(range) }
        // VoiceOver restores its own text cursor on entering a column, even from a longer
        // previous page: keep that caret on this page. A selection of hidden text is refused.
        if range.length == 0, range.location != NSNotFound {
            super.setAccessibilitySelectedTextRange(boundedPageAccessibilityRange(range))
        } else if validPageAccessibilityRange(range) {
            super.setAccessibilitySelectedTextRange(range)
        }
    }

    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        guard !isPageColumn || (ranges ?? []).allSatisfy({ validPageAccessibilityRange($0.rangeValue) }) else { return }
        super.setAccessibilitySelectedTextRanges(ranges)
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        guard isPageColumn else { return super.accessibilityInsertionPointLineNumber() }
        let index = min(accessibilitySelectedTextRange().location, max(0, shownCharacters.length - 1))
        return accessibilityLine(for: index)
    }

    override func accessibilityNumberOfCharacters() -> Int {
        isPageColumn ? min(placement.visibleLength, textLength) : super.accessibilityNumberOfCharacters()
    }
}
#endif
