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
    /// The elements of the table rows a page column showed before its text was last replaced,
    /// kept among its children until the text is replaced again (`exposeTextualAttachments`).
    private(set) var departedRows: [NSAccessibilityElement] = []
    /// Where VoiceOver enters the page a column shows: its first line, or the start of the line
    /// of a place shown (`ReaderCanvasView.enterPage`). The insertion point starts there, and
    /// the rows of the page before stand there (`departedRowFrame`). While every column's
    /// insertion point is still at it, a relayout enters the place again
    /// (`ReaderCanvasView.placeStillEntered`).
    var entryLocation = 0
    private var menuImage: ReaderImageAttachment?
    /// The headings of the text in the view, found once for each text it is given.
    private var headingCache: [(heading: ReaderHeading, range: NSRange)]?
    /// The characters of the table rows that have nothing to say, found once for each text.
    private var silentRowCache: [Int]?
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

    /// In continuous scroll, holds the text on screen in place before something is read off
    /// the layout as being on screen (`ReaderCanvasView.holdScrollPlace`). True when the view
    /// moved.
    @discardableResult func holdScrollPlace() -> Bool { canvas?.holdScrollPlace(of: self) ?? false }

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

    /// `unshifted` gives the characters the event's key types with no modifier, in the keyboard
    /// layout in use (`bindingCharacter(for:unshifted:)`).
    static func pageTurnDirection(for event: NSEvent, controls: EPUBPageControls = .init(),
                                  unshifted: (NSEvent) -> String? = { $0.characters(byApplyingModifiers: []) }) -> Bool? {
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
            guard let character = bindingCharacter(for: event, unshifted: unshifted) else { return nil }
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

    /// The letter or digit a key names for a character binding, whose modifiers, Shift among
    /// them, are matched apart. It is the character the key types, in the layout's own letters
    /// and with Shift's effect (`charactersIgnoringModifiers`): Shift-N is "N", and on a French
    /// keyboard Shift-& is "1". Where that is no letter or digit and Shift is held, it is the
    /// character the key types without Shift: Shift-1 on a US keyboard types "!" and names "1"
    /// (#163). No keyboard layout that comes with macOS 27 has a key whose characters with and
    /// without Shift are two different letters or digits, so the two never compete
    /// (`ViewCoveragePageInputTests.testNoKeyOfAMacLayoutTypesTwoLettersOrDigitsWithAndWithoutShift`).
    static func bindingCharacter(for event: NSEvent, unshifted: (NSEvent) -> String?) -> Character? {
        func letterOrDigit(_ characters: String?) -> Character? {
            guard let characters, characters.count == 1, let character = characters.first,
                  EPUBPageKey.character(character).normalized != nil else { return nil }
            return character
        }
        if let typed = letterOrDigit(event.charactersIgnoringModifiers) { return typed }
        return event.modifierFlags.contains(.shift) ? letterOrDigit(unshifted(event)) : nil
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
    // are (attachments as U+FFFC) so every accessibility range matches the text. A table row
    // that has nothing to say is a space, and so is the break after it, and the same for a rule
    // the book keeps from assistive technology (`silentRows`) or a character that
    // `visibility: hidden` hides (`blankingHiddenText`).
    override func accessibilityValue() -> String? {
        guard !isPageColumn else { return plainCharacters(in: shownCharacters) }
        return super.accessibilityValue().map { passingOverSilentRows(blankingHiddenText($0, from: 0), from: 0) }
    }

    private func plainCharacters(in range: NSRange) -> String {
        guard let storage = contentStorage.textStorage else { return "" }
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        return passingOverSilentRows(blankingHiddenText((storage.string as NSString).substring(with: bounded), from: bounded.location),
                                     from: bounded.location)
    }

    // MARK: Hidden text

    /// `characters`, which begin at `location` of the text, with each character that
    /// `visibility: hidden` hides in the flow given as a space, but the breaks that end its
    /// lines (`NSAttributedString.readerBlankingHidden`). A browser keeps the room such text
    /// takes and gives an assistive client none of it. AppKit reads a text view's characters
    /// one for one with every range it asks for, the lines' and the frames' included, so they
    /// stay as many: VoiceOver says nothing for a space, and passes over the room as it does
    /// over the space between words. Shown text that `aria-hidden` keeps from assistive
    /// technology is given the same way, and copied as it is.
    private func blankingHiddenText(_ characters: String, from location: Int) -> String {
        contentStorage.textStorage?.readerBlankingHidden(characters, from: location) ?? characters
    }

    /// Whether every character of `range` but its breaks is one that `visibility: hidden` hides,
    /// or that `aria-hidden` keeps from assistive technology.
    private func holdsHiddenTextAlone(_ range: NSRange) -> Bool {
        guard let storage = contentStorage.textStorage, range.length > 0 else { return false }
        let hidden = storage.readerHiddenCharacters(in: range).reduce(0) { $0 + $1.length }
        guard hidden > 0 else { return false }
        let text = storage.string as NSString
        let breaks = (range.location..<NSMaxRange(range)).filter { NSAttributedString.isReaderBreak(text.character(at: $0)) }.count
        return hidden + breaks >= range.length
    }

    // MARK: Table rows that have nothing to say

    /// Where the table rows that have nothing to say stand in the view's text, in order
    /// (`TableRowAttachment.saysNothing`): rows of empty cells and of decoration alone, which
    /// space out a table used for layout. VoiceOver is given nothing to stop on there, as
    /// iPhone and iPad list no element for such a row. A rule the book keeps from assistive
    /// technology, outside a link, is one character on a line of its own as such a row is,
    /// and is passed over the same way, where iPhone and iPad give it no stop, and so is a
    /// rule that `visibility: hidden` hides, which has no link. It takes four
    /// things, and what VoiceOver does without each was heard
    /// (doc/testing.md#voiceover-testing, the entry of 2026-10-13 on rows that have nothing
    /// to say):
    ///
    /// - The text gives no element at the row's character. With a group there VoiceOver said
    ///   "text text group" of two cells of decoration, and with a table of data's table a
    ///   bare "table".
    /// - The character is given as a space. At an attachment's character with no element, or
    ///   with one that says nothing, VoiceOver stops and says nothing as it moves by word.
    /// - The row's line is part of the line after it (`passingOverSilentRows`). A line of
    ///   its own is one VoiceOver stops on in silence as it moves by line, whatever the
    ///   line holds. Part of the line before, it kept VoiceOver out of the row of words
    ///   there: VoiceOver goes into what stands where a line it has read ends.
    /// - The break after the row is given as a space too. VoiceOver says of a line what
    ///   comes before the line's first break, which was the row and so nothing, and with
    ///   Read All it said a phrase with nothing in it for the paragraph the row was.
    private var silentRows: [Int] {
        if let silentRowCache { return silentRowCache }
        var found: [Int] = []
        if let storage = contentStorage.textStorage {
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
                if let row = value as? TableRowAttachment, row.saysNothing { found.append(run.location) }
                else if let rule = value as? ReaderRuleAttachment, rule.isPassedOverByAssistiveTechnology,
                        storage.attribute(.link, at: run.location, effectiveRange: nil) == nil { found.append(run.location) }
            }
        }
        silentRowCache = found
        return found
    }

    /// How many of those rows stand before `index`, which is the first of them at or after it.
    private func silentRowCount(before index: Int) -> Int {
        let rows = silentRows
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle] < index { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func isSilentRow(at location: Int) -> Bool {
        let rows = silentRows, index = silentRowCount(before: location)
        return index < rows.count && rows[index] == location
    }

    private func silentRows(in range: NSRange) -> ArraySlice<Int> {
        silentRows[silentRowCount(before: range.location)..<silentRowCount(before: NSMaxRange(range))]
    }

    /// The places in `range` that are given as spaces: the character of each row that has
    /// nothing to say, and the break after it.
    private func silentRowCharacters(in range: NSRange) -> [Int] {
        guard !silentRows.isEmpty, range.location != NSNotFound, range.length > 0,
              let text = contentStorage.textStorage?.string as NSString? else { return [] }
        // A range can begin at a row's break.
        let from = max(0, range.location - 1)
        return silentRows(in: NSRange(location: from, length: NSMaxRange(range) - from)).flatMap { row in
            [row, row + 1].filter { NSLocationInRange($0, range) && ($0 == row || ($0 < text.length && text.character(at: $0) == 0x0A)) }
        }
    }

    /// `characters`, which begin at `location` of the text, with those spaces: one for one,
    /// so that every range still matches the text.
    private func passingOverSilentRows(_ characters: String, from location: Int) -> String {
        guard !silentRows.isEmpty else { return characters }
        let result = NSMutableString(string: characters)
        for place in silentRowCharacters(in: NSRange(location: location, length: result.length)) {
            result.replaceCharacters(in: NSRange(location: place - location, length: 1), with: " ")
        }
        return result as String
    }

    /// The lines an assistive client is given, where `lines` are the text's own: the line of
    /// a row that has nothing to say is part of the line after it. Such rows with no line
    /// after them, at the end of a page or of the book, are one line.
    private func passingOverSilentRows(_ lines: [NSRange]) -> [NSRange] {
        guard !silentRows.isEmpty else { return lines }
        var result: [NSRange] = [], held: NSRange?
        for line in lines {
            if isSilentRow(at: line.location) { held = held.map { NSUnionRange($0, line) } ?? line }
            else { result.append(held.map { NSUnionRange($0, line) } ?? line); held = nil }
        }
        return result + (held.map { [$0] } ?? [])
    }

    /// The same for continuous scroll, where the lines are AppKit's and are numbered through
    /// the whole book: the line an assistive client numbers `line`.
    private func scrollAccessibilityRange(forLine line: Int) -> NSRange {
        // AppKit's number for a line is greater by the rows with nothing to say before it,
        // and how many those are is known only at a place in the text. Each such row and the
        // line after it have one number, so the first line found with it begins the line.
        var own = line, range = super.accessibilityRange(forLine: own)
        while range.location != NSNotFound, range.length > 0 {
            let given = own - silentRowCount(before: range.location)
            if given >= line { break }
            own += line - given
            range = super.accessibilityRange(forLine: own)
        }
        guard range.location != NSNotFound, range.length > 0 else { return range }
        // While the last of AppKit's lines taken is such a row's, the line after it is part
        // of this one.
        var last = range
        while isSilentRow(at: last.location) {
            own += 1
            let following = super.accessibilityRange(forLine: own)
            guard following.location == NSMaxRange(range), following.length > 0 else { break }
            range.length += following.length
            last = following
        }
        return range
    }

    /// The number an assistive client has for the line AppKit numbers `line`, which holds
    /// the character or the insertion point at `index`.
    private func scrollAccessibilityLine(_ line: Int, at index: Int) -> Int {
        guard line != NSNotFound, !silentRows.isEmpty else { return line }
        // One fewer for each row with nothing to say before the line. A row that holds
        // `index` itself, at its character or its break, is part of the line, not before it.
        var before = silentRowCount(before: index + 1)
        if before > 0, index - silentRows[before - 1] <= 1 { before -= 1 }
        return max(0, line - before)
    }

    /// A TextKit 2 text view exposes nothing for an attachment drawn from its image, so each one
    /// that stands for text gets an image element labelled with its text equivalent, through
    /// the attachment attribute VoiceOver reads in text. A hidden label is text, not an image.
    /// A row of a table that holds data gets its table (`ReaderDataTables+AppKit.swift`), and
    /// a row of any other table a group that holds its cells' text areas. A row that has
    /// nothing to say gets nothing, and its character and its break are spaces (`silentRows`).
    /// An image without words is an image element without a label, and one the book marks as
    /// decoration is left with nothing, for VoiceOver to pass over, as is an image, a rule or a
    /// formula the book keeps from assistive technology, whatever words it has, and anything
    /// `visibility: hidden` hides, whose character is a space. A rule has no words,
    /// and its element carries the reader's word for one, for VoiceOver to say that a break is
    /// there. A heading's characters carry its level, shown or a hidden label, unless
    /// `visibility: hidden` hides all of its words, or `aria-hidden` keeps them all from
    /// assistive technology: those characters are spaces, as every character either leaves out
    /// is (`blankingHiddenText`).
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard !isPageColumn || validPageAccessibilityRange(range),
              let base = super.accessibilityAttributedString(for: range) else { return nil }
        let silent = silentRows(in: range), spaces = silentRowCharacters(in: range)
        let hidden = contentStorage.textStorage?.readerHiddenCharacters(in: range) ?? []
        let tableRows = dataTableRows(in: range).filter { !silent.contains($0.range.location) }
        // What each is given is its spoken words, which an image the book keeps from
        // assistive technology has none of.
        let attachments = textualAttachments(in: range).compactMap { entry -> (attachment: NSTextAttachment, text: String, range: NSRange)? in
            guard !silent.contains(entry.range.location), !tableRows.contains(where: { $0.range == entry.range }),
                  let words = (entry.attachment as? ReaderTextualAttachment)?.spokenEquivalent, !words.isEmpty else { return nil }
            return (entry.attachment, words, entry.range)
        }
        // Inline formula slots retain source offsets while rows reflow. Expose one image
        // reading for the selected part; the remaining placeholders are silent spaces.
        var mathSpaces: [Int] = []
        contentStorage.textStorage?.enumerateAttribute(.attachment, in: range) { value, run, _ in
            guard let math = value as? MathAttachment, math.inline != nil else { return }
            if run.location != max(0, run.location - math.row) { mathSpaces.append(run.location) }
        }
        let images = announcedImages(in: range)
        let rules = rules(in: range)
        let headings = contentStorage.textStorage?.readerHeadings(in: range) ?? []
        let links = accessibilityLinks(in: range)
        guard !attachments.isEmpty || !images.isEmpty || !rules.isEmpty || !headings.isEmpty || !links.isEmpty || !tableRows.isEmpty
                || !spaces.isEmpty || !mathSpaces.isEmpty || !hidden.isEmpty else { return base }
        let result = NSMutableAttributedString(attributedString: base)
        for place in spaces + mathSpaces where place - range.location < result.length {
            let local = NSRange(location: place - range.location, length: 1)
            result.replaceCharacters(in: local, with: " ")
            result.removeAttribute(.attachment, range: local)
        }
        for run in hidden where NSMaxRange(run) - range.location <= result.length {
            result.replaceCharacters(in: NSRange(location: run.location - range.location, length: run.length),
                                     with: String(repeating: " ", count: run.length))
        }
        // A row of a table of data is given its table, named by the row's words.
        for (row, run) in tableRows {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length, let element = dataTables.element(at: run.location, of: row) else { continue }
            result.addAttribute(.accessibilityAttachment, value: element, range: local)
        }
        for (heading, run) in headings where heading.level > 0 {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length, !holdsHiddenTextAlone(run) else { continue }
            result.addAttribute(.accessibilityHeadingLevel, value: heading.level, range: local)
        }
        for (attachment, text, run) in attachments {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length else { continue }
            let element = accessibilityElement(at: run, label: text, isText: attachment is SpokenLabelAttachment)
            result.addAttribute(.accessibilityAttachment, value: element, range: local)
            // A formula's reading has its own voice: the book's language or the generator's.
            if let language = (attachment as? ReaderTextualAttachment)?.textLanguage {
                result.addAttribute(.accessibilityLanguage, value: language, range: local)
            }
        }
        // A row of a table of data stays its table, whose cells show their own pictures.
        var exposed = Set(tableRows.map(\.range))
        for (image, run) in images where exposed.insert(run).inserted {
            let local = NSRange(location: run.location - range.location, length: run.length)
            guard NSMaxRange(local) <= result.length else { continue }
            // The role says that it is an image, in VoiceOver's own language: no name is made up.
            let label = image.source.hasFailedSVGRendering ? image.spokenAlt
                : (attachments.first { $0.range == run }?.text ?? image.spokenAlt)
            let element = accessibilityElement(at: run, label: label)
            // VoiceOver reads the help of an element without a label as its name, in the line.
            // A row's group has a label when its cells have words, which is not when the
            // row has a text equivalent: that of a row of two pictures is the tab between them.
            let isNamed = element is ReaderTableRowGroupElement ? !tableRowLabel(at: run.location).isEmpty : !label.isEmpty
            element.setAccessibilityHelp(isNamed ? ReaderImageInspection.accessibilityHelp : nil)
            let actions = images.filter { $0.range == run }.map { entry in
                NSAccessibilityCustomAction(name: entry.image.spokenAlt.isEmpty ? "Inspect Image" : "Inspect Image: \(entry.image.spokenAlt)") {
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

    /// The character of each rule in `range` that VoiceOver is told of: not one the book keeps
    /// from assistive technology, unless it is all its link holds.
    private func rules(in range: NSRange) -> [NSRange] {
        guard let storage = contentStorage.textStorage else { return [] }
        var result: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length))) { value, run, _ in
            if let rule = value as? ReaderRuleAttachment, !storage.passesOver(rule, at: run) { result.append(run) }
        }
        return result
    }

    /// AppKit lists a text view's links as its children and nothing else: the reader's own
    /// elements take their place, with those of the table cells on screen among them, and its
    /// headings stand among them, each where it is in the text (`headingChildren`). The rows of
    /// a page before come last (`departedRows`).
    override func accessibilityChildren() -> [Any]? {
        guard canvas != nil else { return super.accessibilityChildren() }
        holdScrollPlace()
        let links = linkChildrenWithCells().map { (place: $0.place, element: $0.element as NSAccessibilityElement) }
        let headings = headingChildren().map { (place: $0.range.location, element: $0 as NSAccessibilityElement) }
        // A heading comes before a link that begins where it does, which is a link inside it.
        let own = (headings + links).enumerated().sorted { ($0.element.place, $0.offset) < ($1.element.place, $1.offset) }
        return (super.accessibilityChildren() ?? []).filter { $0 is NSView } + own.map(\.element.element) + departedRows
    }

    /// Where the rows of a page before stand once the column shows another: at the line the
    /// page is entered at (`entryLocation`), its first unless a place was shown on it, which is
    /// where VoiceOver's next move by line or by word goes from one of them. In this view's
    /// coordinates.
    var departedRowFrame: CGRect {
        let origin = containerOrigin
        let line = lineFrame(containing: entryLocation) ?? CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        return line.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func accessibilityElement(at range: NSRange, label: String, isText: Bool = false) -> NSAccessibilityElement {
        let element = attachmentElement(at: range)
        // A row's group says what it is called and what it holds when it is asked.
        if !(element is ReaderTableRowGroupElement) { element.setReaderAttachment(words: label, isText: isText) }
        return element
    }

    /// The element kept for the attachment at `range`, where that stands in the view: a group
    /// for a row of a table, which here is one that is not data.
    private func attachmentElement(at range: NSRange) -> NSAccessibilityElement {
        let element = attachmentElements[range.location]
            ?? (tableRow(at: range.location) == nil ? NSAccessibilityElement() : ReaderTableRowGroupElement(view: self, location: range.location))
        attachmentElements[range.location] = element
        element.setAccessibilityParent(self)
        let frame = segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
        if !frame.isNull {
            let origin = containerOrigin
            element.setAccessibilityFrameInParentSpace(frame.offsetBy(dx: origin.x, dy: origin.y))
        }
        return element
    }

    /// The table row whose character stands at `location`, if one does.
    private func tableRow(at location: Int) -> TableRowAttachment? {
        guard let storage = contentStorage.textStorage, location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? TableRowAttachment
    }

    /// What the group of the row at `location` is called: the words of its cells in column
    /// order, as a table of data is called by its row's (`ReaderTableElement`), so that
    /// VoiceOver says them as it reads the text and not only inside the row. A row that
    /// shows pictures and no words has none to be called by, and is called nothing:
    /// VoiceOver then says what the group holds, "text image text image group", in its
    /// own words and the listener's language, as it says its own word for a picture
    /// nobody describes. No name is made up for either.
    func tableRowLabel(at location: Int) -> String {
        (tableRow(at: location)?.cellWords ?? []).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func exposeTextualAttachments() {
        // A client can keep a row's group after the text it was given in has gone.
        let groups = attachmentElements.values.compactMap { $0 as? ReaderTableRowGroupElement }
        for row in groups { row.view = nil }
        attachmentElements.removeAll()
        silentRowCache = nil
        linkElements = ReaderLinkElements()
        headingElements.removeAll()
        followingHeadingElement = nil
        let tables = dataTables.reset()
        // VoiceOver keeps its cursor on an element only while the element is among the children
        // of the text it is in, and it is on a row's element once it has gone into the row and
        // come back out. A row's element of a page turned under it was no longer a child:
        // VoiceOver went to the text area, out of the text, and needed a step in to read on.
        // Kept among the children, saying nothing and standing at the new page's first line,
        // such an element keeps VoiceOver in the text, and its next move by line or by word
        // reads the new page from its top, as after a turn made from a line (#485). Notices
        // did not do it: a layout change naming the column, posted by the element, by the
        // column or later, and the insertion point told of again left VoiceOver where it went.
        departedRows = isPageColumn ? groups + tables : []
        headingCache = nil
        // Replacing NSTextStorage moves its native caret to the new storage's end, which
        // can be hidden paragraph context, or the end of the book. VoiceOver uses that
        // caret's line when entering a text view. Start newly installed text at its first
        // line; the canvas reapplies any intentional carried selection after all columns
        // have been installed, and keeps the scroll view's caret on screen
        // (`placeScrollInsertionPoint`), and after a place is shown puts it on the place's
        // line (`enterPage`).
        entryLocation = 0
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
        guard isPageColumn else {
            return super.accessibilityString(for: range).map {
                passingOverSilentRows(blankingHiddenText($0, from: range.location), from: range.location)
            }
        }
        return validPageAccessibilityRange(range) ? plainCharacters(in: range) : nil
    }

    override func accessibilityRTF(for range: NSRange) -> Data? {
        guard !isPageColumn || validPageAccessibilityRange(range) else { return nil }
        // The rich text of a range that holds hidden characters has spaces in their place.
        guard let storage = contentStorage.textStorage, !storage.readerHiddenCharacters(in: range).isEmpty else {
            return super.accessibilityRTF(for: range)
        }
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: bounded))
        for run in storage.readerHiddenCharacters(in: bounded) {
            text.replaceCharacters(in: NSRange(location: run.location - bounded.location, length: run.length),
                                   with: String(repeating: " ", count: run.length))
        }
        return text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard !isPageColumn || validPageAccessibilityRange(range) else { return .zero }
        holdScrollPlace()
        let frame = super.accessibilityFrame(for: range)
        // AppKit lays the range out to answer. In continuous scroll that can be what moves
        // the text under the view, and the answer is then for where the view stood.
        return holdScrollPlace() ? super.accessibilityFrame(for: range) : frame
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
        guard isPageColumn else {
            return silentRows.isEmpty || line < 0 ? super.accessibilityRange(forLine: line) : scrollAccessibilityRange(forLine: line)
        }
        let lines = passingOverSilentRows(pageAccessibilityLines.map(\.range))
        return lines.indices.contains(line) ? lines[line] : NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityLine(for index: Int) -> Int {
        guard isPageColumn else { return scrollAccessibilityLine(super.accessibilityLine(for: index), at: index) }
        // The insertion point after the page's last character is on its last line, and so is
        // an offset VoiceOver kept from a longer previous page. Without a line there, it
        // announces 9,223,372,036,854,775,808 visible lines or reads nothing on entering.
        let lines = passingOverSilentRows(pageAccessibilityLines.map(\.range))
        guard index >= 0, !lines.isEmpty else { return NSNotFound }
        return lines.firstIndex { NSLocationInRange(index, $0) } ?? lines.count - 1
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        isPageColumn ? boundedPageAccessibilityRange(selectedRange) : super.accessibilitySelectedTextRange()
    }

    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        isPageColumn ? [NSValue(range: accessibilitySelectedTextRange())] : super.accessibilitySelectedTextRanges()
    }

    override func accessibilitySelectedText() -> String? {
        guard !isPageColumn else { return plainCharacters(in: accessibilitySelectedTextRange()) }
        let range = super.accessibilitySelectedTextRange()
        return super.accessibilitySelectedText().map { range.location == NSNotFound ? $0 : blankingHiddenText($0, from: range.location) }
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
        guard isPageColumn else {
            return scrollAccessibilityLine(super.accessibilityInsertionPointLineNumber(), at: selectedRange.location)
        }
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
            guard let label = Self.headingLabel(spokenText(in: shown), level: heading.level) else { return nil }
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
        element.setAccessibilityLabel(spokenText(in: range).split(whereSeparator: \.isWhitespace).joined(separator: " "))
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

/// A row of a table that is not data, where it stands in the text (doc/native-viewer.md, "Data
/// tables", "On Mac"): a group called by its cells' words, which VoiceOver says as it reads
/// the text, that holds the text areas of the cells on screen, which VoiceOver goes into.
///
/// It answers for both when it is asked. In continuous scroll VoiceOver is given a row
/// beyond the screen before the view shows it, and keeps what it was given: a row made from
/// what was on screen then was an image called by its words, with nothing in it to go into
/// once it was shown.
///
/// Once the view shows other text the row has departed: it says nothing, holds nothing and
/// stands at the first line of the page shown, where VoiceOver goes on from it
/// (`ReaderTextView.departedRows`).
final class ReaderTableRowGroupElement: NSAccessibilityElement {
    /// The view, while it shows the text the row was given in.
    weak var view: ReaderTextView?
    /// The view, whatever it shows: what holds the row.
    private weak var host: ReaderTextView?
    let location: Int

    init(view: ReaderTextView, location: Int) {
        self.view = view
        host = view
        self.location = location
        super.init()
        // AppKit tells a client of an attribute the element has been given a value for.
        setAccessibilityRole(.group)
        setAccessibilityChildren([])
    }

    /// A departed row is an empty static text, which VoiceOver calls "text", as it calls the
    /// text area it is in. As an empty group it said "group" each time a page turned under it.
    override func accessibilityRole() -> NSAccessibility.Role? { view == nil ? .staticText : .group }

    override func accessibilityFrame() -> NSRect {
        guard view == nil, let host else { return super.accessibilityFrame() }
        return MainActor.assumeIsolated { NSAccessibility.screenRect(fromView: host, rect: host.departedRowFrame) }
    }

    // AppKit asks on the main thread. A row without words has no label, and not an empty one.
    override func accessibilityLabel() -> String? {
        guard let view else { return nil }
        let location = location
        let label = MainActor.assumeIsolated { view.tableRowLabel(at: location) }
        return label.isEmpty ? nil : label
    }

    override func accessibilityChildren() -> [Any]? {
        guard let view else { return [] }
        let location = location
        let cells: [TableCellTextView] = MainActor.assumeIsolated { view.tableInteraction?.accessibilityCells(at: location) ?? [] }
        return cells
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
