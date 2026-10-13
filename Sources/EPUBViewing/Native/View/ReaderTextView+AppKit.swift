#if os(macOS)
import Accessibility
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
    /// The accessibility element of each attachment VoiceOver is told of, by its location.
    private var attachmentElements: [Int: NSAccessibilityElement] = [:]
    /// The accessibility elements of the text's links (`ReaderTextLinks+AppKit.swift`).
    var linkElements = ReaderLinkElements()
    /// The accessibility element of each heading, by the location of its first character.
    private var headingElements: [Int: ReaderHeadingAccessibilityElement] = [:]
    /// The element of the book's next heading after a column's page (`headingChildren`).
    private var followingHeadingElement: ReaderHeadingAccessibilityElement?
    /// The accessibility elements of the text's tables of data (`ReaderDataTables+AppKit.swift`).
    private(set) lazy var dataTables = ReaderDataTables(view: self)
    private var menuImage: ReaderImageAttachment?
    /// The headings of the text in the view, found once for each text it is given.
    private var headingCache: [(heading: ReaderHeading, range: NSRange)]?
    /// VoiceOver's Headings rotor for this text.
    private lazy var headingRotor = {
        let rotor = NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)
        // A page column gives the headings of other pages as tokens, and loads them.
        if isPageColumn { rotor.itemLoadingDelegate = self }
        return rotor
    }()
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

    /// The text view is ending a live resize, and a scroll of it now is nobody's (`viewDidEndLiveResize`).
    private(set) var isEndingLiveResize = false

    /// When a live resize ends, AppKit's text view scrolls itself: the paragraph under the top
    /// edge of the clip view goes to that edge, from its first line (`scrollToLocation:` the
    /// paragraph's start with no offset, macOS 27.0). That edge is above the first line on
    /// screen by the text's top margin, and by a toolbar over the reader. At the top of a book
    /// the title went 48 points above the screen, 114 under a toolbar, and anywhere else the
    /// text went back to the start of a paragraph, further at every resize.
    /// Continuous scroll keeps its place through a resize itself (`layOutScroll`), and
    /// AppKit tells a view that the resize has ended before it tells that view's subviews: by
    /// now the canvas has rested the kept position, and it puts the view back there.
    override func viewDidEndLiveResize() {
        guard !isPageColumn, let canvas, canvas.scrollTextView === self else { return super.viewDidEndLiveResize() }
        isEndingLiveResize = true
        defer { isEndingLiveResize = false }
        canvas.holdingScrollPlace { super.viewDidEndLiveResize() }
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
    /// A row of a table that holds data gets its table (`ReaderDataTables+AppKit.swift`), and
    /// a row of any other table a group that holds its cells' text areas.
    /// An image without words is an image element without a label, and one the book marks as
    /// decoration is left with nothing, for VoiceOver to pass over. A rule has no words, and
    /// its element carries the reader's word for one, for VoiceOver to say that a break is
    /// there. A heading's characters carry its level, shown or hidden.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard !isPageColumn || validPageAccessibilityRange(range),
              let base = super.accessibilityAttributedString(for: range) else { return nil }
        let tableRows = dataTableRows(in: range)
        let attachments = textualAttachments(in: range).filter { entry in !tableRows.contains { $0.range == entry.range } }
        let images = announcedImages(in: range)
        let rules = rules(in: range)
        let headings = contentStorage.textStorage?.readerHeadings(in: range) ?? []
        let links = accessibilityLinks(in: range)
        guard !attachments.isEmpty || !images.isEmpty || !rules.isEmpty || !headings.isEmpty || !links.isEmpty || !tableRows.isEmpty else { return base }
        let result = NSMutableAttributedString(attributedString: base)
        // A row of a table of data is given its table, named by the row's words.
        for (row, run) in tableRows {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length, let element = dataTables.element(at: run.location, of: row) else { continue }
            result.addAttribute(.accessibilityAttachment, value: element, range: local)
        }
        for (heading, run) in headings where heading.level > 0 {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length else { continue }
            result.addAttribute(.accessibilityHeadingLevel, value: heading.level, range: local)
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
            element.setAccessibilityHelp(label.isEmpty ? nil : ReaderImageInspection.accessibilityHelp)
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
        for run in rules {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length else { continue }
            let element = attachmentElement(at: run)
            ReaderRuleAttachment.makeSeparator(element)
            result.addAttribute(.accessibilityAttachment, value: element, range: local)
        }
        // After the rules: a rule that is all its link holds, or that opens one, is the link.
        addAccessibilityLinks(links, to: result, of: range)
        return result
    }

    /// The rows in `range` of tables that hold data, each with its character.
    private func dataTableRows(in range: NSRange) -> [(row: TableRowAttachment, range: NSRange)] {
        guard containsTableRows, let storage = contentStorage.textStorage else { return [] }
        var result: [(TableRowAttachment, NSRange)] = []
        storage.enumerateAttribute(.attachment, in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length))) { value, run, _ in
            if let row = value as? TableRowAttachment, row.table.isData { result.append((row, run)) }
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

    /// AppKit lists a text view's links as its children and nothing else: the reader's own
    /// elements take their place, with those of the table cells on screen among them, and its
    /// headings stand among them, each where it is in the text (`headingChildren`).
    override func accessibilityChildren() -> [Any]? {
        guard canvas != nil else { return super.accessibilityChildren() }
        let links = linkChildrenWithCells().map { (place: $0.place, element: $0.element as NSAccessibilityElement) }
        let headings = headingChildren().map { (place: $0.range.location, element: $0 as NSAccessibilityElement) }
        // A heading comes before a link that begins where it does, which is a link inside it.
        let own = (headings + links).enumerated().sorted { ($0.element.place, $0.offset) < ($1.element.place, $1.offset) }
        return (super.accessibilityChildren() ?? []).filter { $0 is NSView } + own.map(\.element.element)
    }

    private func accessibilityElement(at range: NSRange, label: String, isText: Bool = false) -> NSAccessibilityElement {
        let element = attachmentElement(at: range)
        if let cells = tableInteraction?.accessibilityCells(at: range.location), !cells.isEmpty {
            element.setAccessibilityRole(.group)
            element.setAccessibilityLabel("Table row")
            element.setAccessibilityChildren(cells)
        } else {
            element.setReaderAttachment(words: label, isText: isText)
        }
        return element
    }

    /// The element kept for the attachment at `range`, where that stands in the view.
    private func attachmentElement(at range: NSRange) -> NSAccessibilityElement {
        let element = attachmentElements[range.location] ?? NSAccessibilityElement()
        attachmentElements[range.location] = element
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
        linkElements = ReaderLinkElements()
        headingElements.removeAll()
        followingHeadingElement = nil
        dataTables.reset()
        headingCache = nil
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

    // MARK: Page actions

    // VoiceOver's Actions menu holds the actions of the item under its cursor. On a column and
    // at every line and word inside one, that item is the text area, so each text area offers
    // the page turn itself, named as the host's buttons are for the flow. It is a turn asked
    // for by name, as a line's is on iPhone and iPad: selected text does not hold it back, and
    // it fails at either end of the book. A view's named actions in SwiftUI reach no element of
    // the window. A note's text has no canvas and no page to turn. The turn is made before the
    // handler returns: made after it, VoiceOver settled on a line that was neither the one it
    // had been on nor the new first one.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let canvas else { return super.accessibilityCustomActions() }
        let flow = canvas.configuration.flow
        return (super.accessibilityCustomActions() ?? []) + [EPUBPageAction.next, .previous].map { action in
            NSAccessibilityCustomAction(name: action.label(in: flow)) { [weak self] in
                self?.canvas?.turnPageFromAccessibility(forward: action == .next) ?? false
            }
        }
    }

    // MARK: Headings

    // A text area has no headings of its own to an assistive client: the book's are given to
    // VoiceOver as its Headings rotor, which lists them by their words and level and moves to
    // the one chosen, and which its own move to the next heading goes by. The scroll view
    // gives the headings of its text, which is the whole book. A page column gives the whole
    // book's too, through the canvas: a heading on another page is one VoiceOver has the
    // reader load, which turns to its page (`ReaderCanvasView.headingRotorResult`).
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        super.accessibilityCustomRotors() + [headingRotor]
    }

    /// The headings an assistive client can reach in this view, in order, each with its text's
    /// characters and what the rotor's list calls it: its words and, where it has one, its
    /// level. VoiceOver reads the level it is given in the text to nobody (27.0.1), so the list
    /// is where a listener hears it. A hidden heading is the one character of its label.
    private var accessibilityHeadings: [(heading: ReaderHeading, range: NSRange, label: String)] {
        let all = headingCache ?? contentStorage.textStorage?.readerHeadings() ?? []
        headingCache = all
        let reach = isPageColumn ? shownCharacters : NSRange(location: 0, length: textLength)
        return all.compactMap { heading, range in
            let shown = NSIntersectionRange(range, reach)
            guard shown.length > 0 else { return nil }
            guard let label = Self.headingLabel(plainText(in: shown), level: heading.level) else { return nil }
            return (heading, shown, label)
        }
    }

    /// What the rotor's list calls a heading of these words: the words and, where it has one,
    /// its level. None for a heading without words.
    static func headingLabel(_ text: String, level: Int) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return level > 0 ? "\(words), heading level \(level)" : words
    }
}

extension ReaderTextView: @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
    /// The heading after or before where the search stands, and none past either end. VoiceOver
    /// stands on the characters under its cursor, or on the heading it was last given. To list
    /// the headings it asks for the one after an item that is nowhere, with no element, and
    /// then for the one after each it is given; with its cursor resting on the view it asks
    /// from the view's first character and none of it. From either the search begins with the
    /// first heading, or the last. Standing inside a heading, the one before is the heading
    /// before that one, as in a browser. A page column answers for the whole book, where a
    /// cursor at rest stands at the top of its page (`ReaderCanvasView.headingRotorResult`).
    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        if isPageColumn, let canvas { return canvas.headingRotorResult(for: searchParameters, askedOf: self) }
        var headings = accessibilityHeadings
        let filter = searchParameters.filterString
        if !filter.isEmpty { headings = headings.filter { $0.label.localizedCaseInsensitiveContains(filter) } }
        let forward = searchParameters.searchDirection == .next
        let found: (heading: ReaderHeading, range: NSRange, label: String)?
        if let current = searchParameters.currentItem, current.targetElement != nil,
           current.targetRange.location != NSNotFound, current.targetRange != NSRange(location: 0, length: 0) {
            let place = current.targetRange.location
            found = forward ? headings.first { $0.range.location > place } : headings.last { NSMaxRange($0.range) <= place }
        } else { found = forward ? headings.first : headings.last }
        guard let found else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = found.range
        result.customLabel = found.label
        return result
    }
}

extension ReaderTextView: @MainActor NSAccessibilityElementLoading {
    /// VoiceOver moves to a heading the rotor gave while it was on another page: the reader
    /// turns to its page, and this is the column that then shows it.
    func accessibilityElement(withToken token: any NSAccessibilityLoadingToken) -> (any NSAccessibilityElementProtocol)? {
        canvas?.loadHeading(token)
    }

    /// The heading's characters in that column.
    func accessibilityRangeInTargetElement(withToken token: any NSAccessibilityLoadingToken) -> NSRange {
        canvas?.loadedHeadingRange(token) ?? NSRange(location: NSNotFound, length: 0)
    }
}

extension NSAttributedString.Key {
    /// The heading level of text an assistive client reads, 1 to 6: the Accessibility
    /// framework's own attribute, which AppKit has no name for.
    static let accessibilityHeadingLevel = NSAttributedString.Key(AttributeScopes.AccessibilityAttributes.HeadingLevelAttribute.name)
}

extension ReaderTextView {
    /// The headings among the text's children: each one with characters on screen and the
    /// next one after them, below the screen in continuous scroll and on a later page in
    /// paging. From a place in the text VoiceOver moves to the next heading by the rotor. With
    /// its cursor on a link, which is a child of the text and no place in it, it asks no rotor
    /// and looks through the text's children for a heading after the link, beginning again
    /// with the first past the last (macOS 27.0.1). So a heading has an element there, as a
    /// link has, and the one after the screen or the page is where that move goes from the
    /// last link there. VoiceOver takes an element for a place only when it is among the
    /// children of its text, so the book's next heading is a child before VoiceOver looks
    /// for it. In continuous scroll VoiceOver scrolls to it by the scroll bar, and in paging
    /// the reader turns to its page when VoiceOver focuses it (`showHeading`).
    func headingChildren() -> [ReaderHeadingAccessibilityElement] {
        let visible = accessibilityVisibleCharacterRange()
        var found: [ReaderHeadingAccessibilityElement] = []
        for (heading, range, _) in accessibilityHeadings {
            let below = range.location >= NSMaxRange(visible)
            guard below || NSIntersectionRange(range, visible).length > 0 else { continue }
            found.append(headingElement(heading, at: range))
            if below { break }
        }
        if isPageColumn, let following = followingHeading() { found.append(following) }
        return found
    }

    /// The element kept for a heading of this text, named and placed anew each time it is
    /// asked for.
    private func headingElement(_ heading: ReaderHeading, at range: NSRange) -> ReaderHeadingAccessibilityElement {
        let element = headingElements[range.location] ?? ReaderHeadingAccessibilityElement()
        headingElements[range.location] = element
        element.view = self
        element.range = range
        element.elsewhere = nil
        element.setAccessibilityParent(self)
        element.setAccessibilityLabel(plainText(in: range).split(whereSeparator: \.isWhitespace).joined(separator: " "))
        // VoiceOver says the level it finds as the element's value: "heading level 2".
        element.setAccessibilityValue(heading.level > 0 ? heading.level : nil)
        return element
    }

    /// The element of the book's next heading after this column's page, the last of the
    /// column's children: called by the heading's words, with its level, and standing at the
    /// foot of the column, since its characters are on no line of the page. None after the
    /// book's last heading, and none while the chapter that holds the next one is not built.
    private func followingHeading() -> ReaderHeadingAccessibilityElement? {
        guard let next = canvas?.headingAfterPage(of: self) else { return nil }
        let element = followingHeadingElement ?? ReaderHeadingAccessibilityElement()
        followingHeadingElement = element
        element.view = self
        element.range = NSRange(location: NSNotFound, length: 0)
        element.elsewhere = next.heading.position
        element.setAccessibilityParent(self)
        element.setAccessibilityLabel(next.words)
        element.setAccessibilityValue(next.heading.heading.level > 0 ? next.heading.heading.level : nil)
        return element
    }

    /// Where the element of a heading on a later page stands in this column.
    var followingHeadingFrame: CGRect { CGRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1) }

    /// VoiceOver has moved to the element of a heading of this text, at `range`, or of the
    /// book's next heading after its page, at `elsewhere` in the book.
    ///
    /// A heading the text does not show is shown, and the insertion point goes to it.
    /// VoiceOver's cursor is on the element and not in the text, and its next move by word or
    /// by line starts from the insertion point, which was wherever it had last read, or the
    /// first line on screen. In continuous scroll that is a heading with no character on
    /// screen, which the reader shows as it shows a link's target: VoiceOver would scroll to
    /// the element by the scroll bar, which the reader takes for any other scroll.
    ///
    /// A heading with any of it on the page or on screen is left as it is. Told that the
    /// insertion point of the text it is in has moved, VoiceOver says the word before the new
    /// place, and says it over the heading's level and words, which it has only begun (macOS
    /// 27.0.1). After the reader has shown a place it tells VoiceOver that the layout changed,
    /// and VoiceOver then says the item under its cursor again, so there the heading follows
    /// that word. Nothing found moves VoiceOver's place in a text without the word
    /// (`showLink`), so from a heading left as it is reading on starts where VoiceOver last
    /// read.
    ///
    /// For a heading on a later page the reader turns to that page, as it does when
    /// VoiceOver loads a heading the rotor gave (`ReaderCanvasView.loadHeading`). The element
    /// VoiceOver is on becomes the heading's own in the column that then shows it, among that
    /// column's children with its place there: an element that left the children would leave
    /// VoiceOver's cursor on the column. The insertion point of that column goes to the
    /// heading, also where the column stood beside the one VoiceOver is in and nothing
    /// turned: VoiceOver says no word for another text's insertion point.
    func showHeading(at range: NSRange, elsewhere: ReaderTextPosition?) {
        guard let canvas else { return }
        if let elsewhere {
            guard let element = followingHeadingElement, element.elsewhere == elsewhere,
                  let shown = canvas.showHeading(at: elsewhere) else { return }
            followingHeadingElement = nil
            shown.view.headingElements[shown.range.location] = element
            guard shown.view.headingChildren().contains(where: { $0 === element }) else { return }
            shown.view.placeInsertionPoint(at: shown.range.location)
        } else if !isPageColumn, range.location != NSNotFound, range.location <= textLength,
                  NSIntersectionRange(range, accessibilityVisibleCharacterRange()).length == 0,
                  let position = canvas.position(at: range.location, in: self) {
            canvas.show(position, selecting: nil)
            placeInsertionPoint(at: range.location)
        }
    }

    private func placeInsertionPoint(at location: Int) {
        let place = NSRange(location: location, length: 0)
        if selectedRange != place { selectedRange = place }
    }
}

/// A heading in a reader text view as VoiceOver finds it from another element of the text: a
/// child of the text with AppKit's role for a heading, called by the heading's words, with
/// its level. From a place in the text VoiceOver goes by the heading's characters, which
/// carry the level too, and by the Headings rotor.
final class ReaderHeadingAccessibilityElement: NSAccessibilityElement {
    weak var view: ReaderTextView?
    var range = NSRange(location: 0, length: 0)
    /// Where the heading begins in the book, while it is the next one after its column's
    /// page and none of that page's characters.
    var elsewhere: ReaderTextPosition?

    override init() {
        super.init()
        setAccessibilityRole(.headingRole)
    }

    // AppKit asks on the main thread. The place is found when asked for, as a link's is.
    override func accessibilityFrameInParentSpace() -> NSRect {
        guard let view else { return .zero }
        let range = range, following = elsewhere != nil
        return MainActor.assumeIsolated { following ? view.followingHeadingFrame : view.linkFrame(range) }
    }

    override func accessibilityFrame() -> NSRect {
        guard let view else { return .zero }
        let range = range, following = elsewhere != nil
        return MainActor.assumeIsolated {
            NSAccessibility.screenRect(fromView: view, rect: following ? view.followingHeadingFrame : view.linkFrame(range))
        }
    }

    // VoiceOver focuses the element it moves to while its cursor and the keyboard focus go
    // together (cursor tracking, which is on until a listener turns it off), and that is all
    // it tells the reader of the move. It focuses an element that says whether it has the
    // focus and takes it: one that only took it was never given it (macOS 27.0.1).
    override func isAccessibilityFocused() -> Bool { super.isAccessibilityFocused() }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        guard focused, let view else { return }
        let range = range, elsewhere = elsewhere
        MainActor.assumeIsolated { view.showHeading(at: range, elsewhere: elsewhere) }
    }
}
#endif
