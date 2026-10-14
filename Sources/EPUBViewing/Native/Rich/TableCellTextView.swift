import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias TableNativeTextView = NSTextView
#else
typealias TableNativeTextView = UITextView
#endif

/// Native selection operates on the complete cell string, then clamps to the complete glyph
/// lines owned by this row slice. Copy/action consume the canvas's full semantic selection.
@MainActor final class TableCellTextView: TableNativeTextView {
    weak var canvas: ReaderCanvasView?
    let cellText: NSAttributedString
    let shownCharacters: NSRange
    private let cellManager: TableInteractionLayoutManager
    private let cellStorage: NSTextStorage
    private var textOffset = CGPoint.zero
    private var changingSelection = false
    var onSelection: ((NSRange) -> Void)?
    var onLink: ((URL, NSRange) -> Void)?
    var onCopy: (() -> String?)?
    var onAction: (() -> Void)?
    var onImage: ((ReaderImageAttachment) -> Void)?
    private var actionTitle: String?
    private var menuImage: ReaderImageAttachment?
    private var highlights: [(range: NSRange, color: PlatformColor)] = []
    private var highlightedCharacters: [NSRange] { highlights.map(\.range) }
    #if os(macOS)
    /// The accessibility element of each attachment VoiceOver is told of, by its location in
    /// the cell's text, kept for as long as the cell is.
    private var attachmentElements: [Int: NSAccessibilityElement] = [:]
    /// The accessibility elements of the cell's links (`ReaderTextLinks+AppKit.swift`).
    var linkElements = ReaderLinkElements()
    #endif
    #if os(iOS)
    private var spreadSelectionDelegate: ReaderSpreadSelectionGestureDelegate?
    var copyTextToPasteboard: (String) -> Void = { UIPasteboard.general.string = $0 }
    #endif

    init(text: NSAttributedString, width: CGFloat, characters: NSRange) {
        cellText = text; shownCharacters = characters
        cellStorage = NSTextStorage(attributedString: text)
        cellManager = TableInteractionLayoutManager()
        let container = ReaderTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        cellStorage.addLayoutManager(cellManager)
        cellManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true
        container.widthTracksTextView = false
        delegate = self
        #if os(macOS)
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false; isHorizontallyResizable = false
        importsGraphics = false
        clipsToBounds = true
        isAutomaticLinkDetectionEnabled = false
        setAccessibilityRole(.textArea)
        #else
        backgroundColor = .clear
        textContainerInset = .zero
        isScrollEnabled = true
        bounces = false
        panGestureRecognizer.isEnabled = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        dataDetectorTypes = []
        // A surface for touch only. VoiceOver reads a row, where it stands among its page's
        // lines, as its cells' words, and the row offers what its cells can do. A text view
        // that is merely no element still gives UIKit's own elements for its text: VoiceOver
        // took those before every line of a page column, and the rows repeated them.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        let inspection = UITapGestureRecognizer(target: self, action: #selector(inspectCellImage(_:)))
        inspection.numberOfTapsRequired = 2
        inspection.delegate = self
        addGestureRecognizer(inspection)
        spreadSelectionDelegate = ReaderSpreadSelectionGestureDelegate.install(on: self)
        #endif
        // The native view draws selection/links but leaves the original table ink untouched.
        let full = NSRange(location: 0, length: text.length)
        cellStorage.removeAttribute(.backgroundColor, range: full)
        cellStorage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: full)
        linkTextAttributes = [:]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var cellSelection: NSRange {
        get {
            #if os(macOS)
            return selectedRange()
            #else
            return selectedRange
            #endif
        }
        set {
            changingSelection = true
            #if os(macOS)
            setSelectedRange(newValue)
            #else
            selectedRange = newValue
            #endif
            updateInteractionInk()
            changingSelection = false
        }
    }

    func configure(frame target: CGRect, scale: CGFloat, textOffset: CGPoint, actionTitle: String?) {
        self.textOffset = textOffset; self.actionTitle = actionTitle
        #if os(macOS)
        frame = target
        bounds = CGRect(origin: .zero, size: CGSize(width: target.width / scale, height: target.height / scale))
        #else
        transform = .identity
        bounds = CGRect(origin: .zero, size: CGSize(width: target.width / scale, height: target.height / scale))
        center = CGPoint(x: target.midX, y: target.midY)
        transform = CGAffineTransform(scaleX: scale, y: scale)
        setContentOffset(textOffset, animated: false)
        #endif
    }

    func setCellHighlights(_ runs: [(NSRange, PlatformColor)]) {
        highlights = runs.map { ($0.0, $0.1) }
        updateInteractionInk()
    }

    /// The selection as the cell paints it itself, where UIKit paints none. UIKit draws a text
    /// view's selection only while the view is first responder, which a touch in it makes it.
    /// A selection set in code, as an assistive technology's action and a located passage set
    /// it, was held, reported and copied, and nothing showed it.
    private var paintedSelection: NSRange? {
        #if os(iOS)
        let run = NSIntersectionRange(cellSelection, shownCharacters)
        return run.length > 0 && !isFirstResponder ? run : nil
        #else
        return nil
        #endif
    }

    /// An opaque native selection/highlight background covers the original row ink. Redraw
    /// the original foreground only for those characters; all other glyphs stay transparent.
    private func updateInteractionInk() {
        let full = NSRange(location: 0, length: cellStorage.length)
        cellManager.drawnCharacterRanges = ([cellSelection] + highlightedCharacters)
            .map { NSIntersectionRange($0, shownCharacters) }.filter { $0.length > 0 }
        cellStorage.beginEditing()
        cellStorage.removeAttribute(.backgroundColor, range: full)
        for (range, color) in highlights {
            let run = NSIntersectionRange(range, shownCharacters)
            if run.length > 0 { cellStorage.addAttribute(.backgroundColor, value: color, range: run) }
        }
        #if os(iOS)
        // UIKit's own tint for selected text. It takes a highlight's place on the characters
        // they share, where UIKit's would lie over it.
        if let run = paintedSelection {
            cellStorage.addAttribute(.backgroundColor, value: tintColor.withAlphaComponent(0.2), range: run)
        }
        #endif
        cellStorage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: full)
        for range in [cellSelection] + highlightedCharacters {
            let run = NSIntersectionRange(range, shownCharacters)
            guard run.length > 0 else { continue }
            cellText.enumerateAttribute(.foregroundColor, in: run) { value, characters, _ in
                #if os(macOS)
                let fallback = NSColor.textColor
                #else
                let fallback = UIColor.label
                #endif
                cellStorage.addAttribute(.foregroundColor, value: value ?? fallback, range: characters)
            }
        }
        cellStorage.endEditing()
    }

    private func changedSelection() {
        guard !changingSelection else { return }
        let clamped = NSIntersectionRange(cellSelection, shownCharacters)
        if clamped != cellSelection { cellSelection = clamped }
        changingSelection = true
        updateInteractionInk()
        changingSelection = false
        onSelection?(clamped)
    }

    private func cellTextPoint(_ point: CGPoint) -> CGPoint {
        #if os(macOS)
        return CGPoint(x: point.x + textOffset.x, y: point.y + textOffset.y)
        #else
        // UIScrollView conversion and gesture locations already include bounds/contentOffset.
        return point
        #endif
    }

    func cellImage(at point: CGPoint) -> ReaderImageAttachment? {
        let target = cellTextPoint(point)
        guard let container = cellManager.textContainers.first else { return nil }
        let glyph = cellManager.glyphIndex(for: target, in: container)
        guard glyph < cellManager.numberOfGlyphs else { return nil }
        let index = cellManager.characterIndexForGlyph(at: glyph)
        guard NSLocationInRange(index, shownCharacters),
              cellManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(target) else { return nil }
        return cellText.attribute(.attachment, at: index, effectiveRange: nil) as? ReaderImageAttachment
    }

    func cellLink(at point: CGPoint) -> (url: URL, range: NSRange)? {
        let target = cellTextPoint(point)
        guard let container = cellManager.textContainers.first else { return nil }
        let glyph = cellManager.glyphIndex(for: target, in: container)
        guard glyph < cellManager.numberOfGlyphs,
              cellManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(target) else { return nil }
        let index = cellManager.characterIndexForGlyph(at: glyph)
        guard NSLocationInRange(index, shownCharacters) else { return nil }
        var range = NSRange(location: index, length: 1)
        let value = cellText.attribute(.link, at: index, effectiveRange: &range)
        guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)) else { return nil }
        return (url, range)
    }

    func cellCharacterOffset(at point: CGPoint) -> Int {
        guard let container = cellManager.textContainers.first else { return shownCharacters.location }
        var fraction: CGFloat = 0
        let index = cellManager.characterIndex(for: cellTextPoint(point), in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction)
        let bounded = min(max(index, shownCharacters.location), shownCharacters.upperBound)
        guard bounded < shownCharacters.upperBound else { return bounded }
        let composed = (cellText.string as NSString).rangeOfComposedCharacterSequence(at: bounded)
        return min(shownCharacters.upperBound, fraction > 0.5 ? composed.upperBound : composed.location)
    }

    private func unlinkedImage(at point: CGPoint) -> Bool {
        guard cellImage(at: point) != nil, cellSelection.length == 0,
              let container = cellManager.textContainers.first else { return false }
        let target = cellTextPoint(point)
        let glyph = cellManager.glyphIndex(for: target, in: container)
        guard glyph < cellManager.numberOfGlyphs else { return false }
        return cellText.attribute(.link, at: cellManager.characterIndexForGlyph(at: glyph), effectiveRange: nil) == nil
    }

    #if os(macOS)
    /// The cell of a table of data whose words the view holds, which is then what holds the
    /// view for an assistive technology.
    weak var tableCellElement: NSAccessibilityElement?
    override func accessibilityParent() -> Any? { tableCellElement ?? super.accessibilityParent() }
    /// The view goes when its row leaves the page or the screen. VoiceOver gives the keyboard
    /// focus to each text area it moves to, a cell's among them, and leaves it there when it
    /// comes back out to the row. A view that goes holding the focus leaves the window holding
    /// it, and VoiceOver, which follows the focus, went to the window's first control, "Open
    /// EPUB… button". The text that showed the cell takes the focus instead (#485).
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, let window, let holder = superview, window.firstResponder === self {
            window.makeFirstResponder(holder)
        }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override var isFlipped: Bool { true }
    override var textContainerOrigin: NSPoint { CGPoint(x: -textOffset.x, y: -textOffset.y) }
    override func accessibilityValue() -> String? { (cellText.string as NSString).substring(with: shownCharacters) }
    override func accessibilityNumberOfCharacters() -> Int { shownCharacters.length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: shownCharacters.length) }

    private func fullAccessibilityRange(_ range: NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= shownCharacters.length, range.length <= shownCharacters.length - range.location else { return nil }
        return NSRange(location: shownCharacters.location + range.location, length: range.length)
    }

    private func relativeAccessibilityRange(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else { return range }
        let lower = min(max(range.location, shownCharacters.location), shownCharacters.upperBound)
        let upper = min(max(range.upperBound, lower), shownCharacters.upperBound)
        return NSRange(location: lower - shownCharacters.location, length: upper - lower)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let full = fullAccessibilityRange(range) else { return nil }
        return (cellText.string as NSString).substring(with: full)
    }

    /// An attachment in a cell is to an assistive client what it is in the text around the
    /// table (`ReaderTextView.accessibilityAttributedString(for:)`): its character carries an
    /// element that is an image named by its words, the words of a hidden label as text, or the
    /// reader's word for a rule, and decoration carries none. The characters stay as they are.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let full = fullAccessibilityRange(range) else { return nil }
        let result = NSMutableAttributedString(attributedString:
            super.accessibilityAttributedString(for: full) ?? cellText.attributedSubstring(from: full))
        cellText.enumerateAttribute(.attachment, in: full) { value, characters, _ in
            guard let element = attachmentElement(for: value, at: characters) else { return }
            let relative = NSRange(location: characters.location - full.location, length: characters.length)
            result.addAttribute(.accessibilityAttachment, value: element, range: relative)
            // A formula's reading has its own voice: the book's language or the generator's.
            if let language = (value as? ReaderTextualAttachment)?.textLanguage {
                result.addAttribute(.accessibilityLanguage, value: language, range: relative)
            }
        }
        addAccessibilityLinks(accessibilityLinks(in: full), to: result, of: full)
        return result
    }

    /// AppKit lists a text view's links as its children and nothing else: the reader's own
    /// elements take their place, as in the text around the table.
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []).filter { $0 is NSView } + linkChildren()
    }

    /// The element of the attachment `value` at `range` of the cell's text, or none for what an
    /// assistive client passes over: decoration, and anything else that has no words.
    private func attachmentElement(for value: Any?, at range: NSRange) -> NSAccessibilityElement? {
        if value is ReaderRuleAttachment {
            let element = keptElement(at: range)
            ReaderRuleAttachment.makeSeparator(element)
            return element
        }
        if let image = value as? ReaderImageAttachment {
            guard !cellText.passesOver(image, at: range) else { return nil }
            let element = keptElement(at: range)
            element.setReaderAttachment(words: image.alt, isText: false)
            // VoiceOver reads the help of an element without a label as its name, in the line.
            element.setAccessibilityHelp(image.alt.isEmpty ? nil : ReaderImageInspection.accessibilityHelp)
            element.setAccessibilityCustomActions([inspectAction(image)])
            return element
        }
        guard let words = (value as? ReaderTextualAttachment)?.textEquivalent, !words.isEmpty else { return nil }
        let element = keptElement(at: range)
        // A table inside the cell is its cells' words: its rows have no text views of their own.
        element.setReaderAttachment(words: words, isText: value is SpokenLabelAttachment || value is TableRowAttachment)
        return element
    }

    /// The element kept for the attachment at `range`, where that stands in the cell. VoiceOver
    /// asks an element what it is after the read that gave it. An element made for one read
    /// was gone by then, and VoiceOver said nothing at a cell's attachment.
    private func keptElement(at range: NSRange) -> NSAccessibilityElement {
        let element = attachmentElements[range.location] ?? NSAccessibilityElement()
        attachmentElements[range.location] = element
        element.setAccessibilityParent(self)
        if let frame = cellFrame(of: range) { element.setAccessibilityFrameInParentSpace(frame) }
        return element
    }

    /// Where the characters of `range` are drawn, in the cell's own coordinates.
    private func cellFrame(of range: NSRange) -> CGRect? {
        guard let container = cellManager.textContainers.first else { return nil }
        let glyphs = cellManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return cellManager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func accessibilitySelectedText() -> String? { cellText.readerPlainText(in: NSIntersectionRange(cellSelection, shownCharacters)) }
    override func accessibilitySelectedTextRange() -> NSRange { relativeAccessibilityRange(cellSelection) }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let full = fullAccessibilityRange(range) else { return }
        cellSelection = full
        onSelection?(full)
    }
    override func accessibilitySelectedTextRanges() -> [NSValue]? { [NSValue(range: accessibilitySelectedTextRange())] }
    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        if let range = ranges?.first?.rangeValue { setAccessibilitySelectedTextRange(range) }
    }
    override func accessibilityRange(for index: Int) -> NSRange {
        guard index >= 0, index < shownCharacters.length else { return NSRange(location: NSNotFound, length: 0) }
        return relativeAccessibilityRange((cellText.string as NSString).rangeOfComposedCharacterSequence(at: shownCharacters.location + index))
    }
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard bounds.contains(local) else { return NSRange(location: NSNotFound, length: 0) }
        let index = cellCharacterOffset(at: local)
        return accessibilityRange(for: min(index - shownCharacters.location, max(0, shownCharacters.length - 1)))
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let full = fullAccessibilityRange(range), let frame = cellFrame(of: full) else { return .zero }
        return NSAccessibility.screenRect(fromView: self, rect: frame)
    }
    override func accessibilityRTF(for range: NSRange) -> Data? {
        guard let full = fullAccessibilityRange(range) else { return nil }
        return try? cellText.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    override func accessibilityStyleRange(for index: Int) -> NSRange {
        guard index >= 0, index < shownCharacters.length else { return NSRange(location: NSNotFound, length: 0) }
        var range = NSRange()
        _ = cellText.attributes(at: shownCharacters.location + index, effectiveRange: &range)
        return relativeAccessibilityRange(range)
    }
    private func accessibilityLines() -> [NSRange] {
        guard let container = cellManager.textContainers.first, shownCharacters.length > 0 else { return [] }
        cellManager.ensureLayout(for: container)
        let glyphs = cellManager.glyphRange(forCharacterRange: shownCharacters, actualCharacterRange: nil)
        var lines: [NSRange] = []
        cellManager.enumerateLineFragments(forGlyphRange: glyphs) { [cellManager] _, _, _, glyphs, _ in
            lines.append(self.relativeAccessibilityRange(cellManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
        }
        return lines
    }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        let lines = accessibilityLines()
        return lines.indices.contains(line) ? lines[line] : NSRange(location: NSNotFound, length: 0)
    }
    override func accessibilityLine(for index: Int) -> Int {
        let lines = accessibilityLines()
        // The insertion point after the cell's last character is on its last line, as in a page
        // column (`ReaderTextView.accessibilityLine(for:)`). VoiceOver leaves it there once it
        // has read the cell's last word, and without a line there its Read Line said nothing.
        // A cell's text never changes, so no offset past that one is the cell's.
        if index == shownCharacters.length, !lines.isEmpty { return lines.count - 1 }
        return lines.firstIndex { NSLocationInRange(index, $0) } ?? NSNotFound
    }
    override func accessibilityInsertionPointLineNumber() -> Int { accessibilityLine(for: accessibilitySelectedTextRange().location) }
    /// The images an assistive technology may inspect: all but the decoration it passes over.
    private func imageActions() -> [ReaderImageAttachment] {
        var images: [ReaderImageAttachment] = []
        cellText.enumerateAttribute(.attachment, in: shownCharacters) { value, _, _ in
            if let image = value as? ReaderImageAttachment, image.alternative != .decorative { images.append(image) }
        }
        return images
    }
    private func inspectAction(_ image: ReaderImageAttachment) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") {
            [weak self] in self?.onImage?(image); return self?.onImage != nil
        }
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { imageActions().map(inspectAction) }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return pboard.setString(onCopy?() ?? cellText.readerPlainText(in: cellSelection), forType: .string)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, unlinkedImage(at: point), let image = cellImage(at: point) { onImage?(image); return }
        if event.clickCount == 1, cellSelection.length == 0, let link = cellLink(at: point) {
            onLink?(link.url, link.range); return
        }
        if canvas?.handleSpreadSelectionMouseDown(event) == true { return }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        menuImage = cellImage(at: convert(event.locationInWindow, from: nil))
        if menuImage != nil {
            let inspect = NSMenuItem(title: "Inspect Image", action: #selector(inspectMenuImage(_:)), keyEquivalent: "")
            inspect.target = self; menu?.addItem(inspect)
        }
        if let actionTitle, cellSelection.length > 0 {
            let action = NSMenuItem(title: actionTitle, action: #selector(performCellAction(_:)), keyEquivalent: "")
            action.target = self; menu?.addItem(action)
        }
        return menu
    }
    @objc private func performCellAction(_ sender: Any?) { onAction?() }
    @objc private func inspectMenuImage(_ sender: Any?) { if let image = menuImage { onImage?(image) } }
    override func accessibilityLabel() -> String? { nil }
    #else
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = textOffset }
    }
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) { super.setContentOffset(textOffset, animated: false) }
    // UIKit paints the selection from the one to the other, and the cell outside them.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        updateInteractionInk()
        return became
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        updateInteractionInk()
        return resigned
    }
    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateInteractionInk()
    }
    override func copy(_ sender: Any?) { copyTextToPasteboard(onCopy?() ?? cellText.readerPlainText(in: cellSelection)) }
    @objc private func inspectCellImage(_ gesture: UITapGestureRecognizer) {
        if let image = cellImage(at: gesture.location(in: self)) { onImage?(image) }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(performCellAction(_:)) { return actionTitle != nil && cellSelection.length > 0 }
        return super.canPerformAction(action, withSender: sender)
    }
    @objc private func performCellAction(_ sender: Any?) { onAction?() }
    #endif
}

#if os(macOS)
// A cell's links for an assistive client are the reader's own elements, as a column's are:
// each named by what it says, never by an attachment's character, with a place and a press.
// Their ranges are the cell's whole text's; the cell gives its characters from the first one
// it shows, and the accessibility string is asked for the same way.
extension TableCellTextView: ReaderLinkHost {
    var linkText: NSAttributedString? { cellText }
    var linkCharacters: NSRange { shownCharacters }
    var visibleLinkCharacters: NSRange { shownCharacters }

    /// The cell's pictures that an assistive client is told of: all but the decoration it
    /// passes over. Decoration that is all its link holds is the link, and stays.
    func announcedImages(in range: NSRange?) -> [(image: ReaderImageAttachment, range: NSRange)] {
        var images: [(ReaderImageAttachment, NSRange)] = []
        cellText.enumerateAttribute(.attachment, in: NSIntersectionRange(range ?? shownCharacters, shownCharacters)) { value, run, _ in
            if let image = value as? ReaderImageAttachment, !cellText.passesOver(image, at: run) { images.append((image, run)) }
        }
        return images
    }

    func linkBounds(_ range: NSRange) -> CGRect {
        cellFrame(of: NSIntersectionRange(range, shownCharacters)) ?? .zero
    }

    func followLink(_ url: URL, at range: NSRange) -> Bool {
        onLink?(url, range)
        return onLink != nil
    }

    func inspectLinkedImage(_ image: ReaderImageAttachment) -> Bool {
        onImage?(image)
        return onImage != nil
    }
}

extension TableCellTextView: NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) { changedSelection() }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) {
            var range = NSRange(location: charIndex, length: 1)
            _ = cellText.attribute(.link, at: charIndex, effectiveRange: &range)
            onLink?(url, range)
        }
        return true
    }
}
#else
extension TableCellTextView: UITextViewDelegate, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        unlinkedImage(at: touch.location(in: self))
    }
    func textViewDidChangeSelection(_ textView: UITextView) { changedSelection() }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction { onLink?(URL, characterRange) }
        return false
    }
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        if case .link(let url) = textItem.content {
            return UIAction { [weak self] _ in self?.onLink?(url, textItem.range) }
        }
        if let image = image(in: textItem.range) {
            return UIAction(title: "Inspect Image") { [weak self] _ in self?.onImage?(image) }
        }
        return nil
    }
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        guard let image = image(in: textItem.range) else { return nil }
        return UITextItem.MenuConfiguration(menu: UIMenu(children: [UIAction(title: "Inspect Image") { [weak self] _ in self?.onImage?(image) }]))
    }
    private func image(in range: NSRange) -> ReaderImageAttachment? {
        var result: ReaderImageAttachment?
        cellText.enumerateAttribute(.attachment, in: NSIntersectionRange(range, shownCharacters)) { value, _, stop in
            if let image = value as? ReaderImageAttachment { result = image; stop.pointee = true }
        }
        return result
    }
    func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions = suggestedActions
        if let actionTitle, cellSelection.length > 0 { actions.append(UIAction(title: actionTitle) { [weak self] _ in self?.onAction?() }) }
        return UIMenu(children: actions)
    }
}
#endif
