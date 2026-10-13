#if os(macOS)
import AppKit

// Links for an assistive client on the Mac.
//
// AppKit gives a text view's links to an assistive client itself: an element for each, as the
// link attribute of the text's accessibility string and among the text's children. VoiceOver
// (macOS 27.0.1, with "When encountering a link/attachment" at Speak, its default) uses them
// in two ways. Find Next Link moves to the next of the children and says its title and
// "hyperlink", and Control-Option-Space presses the link under its cursor, or a link on the
// line its cursor is in. Reading by word, by line or in Read All it says a link's words and
// nothing of the link, in AppKit's own text views as here.
//
// AppKit's elements take their titles from the characters, so a link that is a picture or a
// hidden label is called U+FFFC, and one that takes no room has no size, and Find Next Link
// does not reach it. The reader gives elements of its own instead, each named by what the
// link says. Where a link has an attachment, that character's element is a link element too:
// VoiceOver announces an element given as a character's attachment as it reads, so there it
// says "hyperlink" and the name by word, by line and in Read All. It announces none at a
// character of words, so a link of words alone is still read as its words.
//
// A table cell is a text view of its own (`TableCellTextView`), which VoiceOver reads once it
// interacts with the cell's row and then with the cell. It gives its links the same way.

/// The accessibility elements of a text view's links, kept while its text is.
struct ReaderLinkElements {
    /// Each link's element, by the location of its first character.
    var links: [Int: ReaderLinkAccessibilityElement] = [:]
    /// The element of an attachment inside a longer link, by its location.
    var attachments: [Int: ReaderLinkAccessibilityElement] = [:]
    /// Each link's element as a child of the text the view stands in, by its location: a
    /// table cell's links are listed by its page as well.
    var listed: [Int: ReaderLinkAccessibilityElement] = [:]
}

/// A text view that gives an assistive client the reader's own elements for its links: a page
/// column, the continuous-scroll view, or a table cell.
@MainActor protocol ReaderLinkHost: NSView, Sendable {
    /// The text the links are in, or none where a link does nothing: a note's popover.
    var linkText: NSAttributedString? { get }
    /// The characters of it an assistive client is given.
    var linkCharacters: NSRange { get }
    /// The characters on screen, whose links Find Next Link moves through.
    var visibleLinkCharacters: NSRange { get }
    var linkElements: ReaderLinkElements { get set }
    /// The images of `range` that an assistive client is told of.
    func announcedImages(in range: NSRange?) -> [(image: ReaderImageAttachment, range: NSRange)]
    /// Where the characters of `range` are, in this view's coordinates. A hidden label has a
    /// place and no size.
    func linkBounds(_ range: NSRange) -> CGRect
    /// Follows the link at `range`. False where nothing takes it.
    func followLink(_ url: URL, at range: NSRange) -> Bool
    /// Enlarges a picture that stands in a link. False where nothing takes it.
    func inspectLinkedImage(_ image: ReaderImageAttachment) -> Bool
    /// VoiceOver has moved to the element of the link at `range`: the insertion point goes
    /// there, and the link is shown where none of it is on screen.
    func showLink(at range: NSRange)
    /// Whether the insertion point is on the link at `range`, where `showLink` puts it.
    func showsLink(at range: NSRange) -> Bool
}

extension ReaderLinkHost {
    /// Each link that has characters in `range`, whole: a link ends where its target changes
    /// and where the characters given do, at a page's end or a cell's last line on the page.
    func accessibilityLinks(in range: NSRange) -> [(url: URL, range: NSRange)] {
        guard let text = linkText else { return [] }
        let exposed = NSIntersectionRange(linkCharacters, NSRange(location: 0, length: text.length))
        var result: [(URL, NSRange)] = []
        text.enumerateAttribute(.link, in: NSIntersectionRange(range, exposed)) { value, run, _ in
            guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)) else { return }
            var whole = run
            _ = text.attribute(.link, at: run.location, longestEffectiveRange: &whole, in: exposed)
            result.append((url, whole))
        }
        return result
    }

    /// The first link that begins at `location` or after it, whole, and none past the last.
    func accessibilityLink(after location: Int) -> (url: URL, range: NSRange)? {
        guard let text = linkText else { return nil }
        let exposed = NSIntersectionRange(linkCharacters, NSRange(location: 0, length: text.length))
        guard location < NSMaxRange(exposed) else { return nil }
        let rest = NSRange(location: max(location, exposed.location), length: NSMaxRange(exposed) - max(location, exposed.location))
        var found: (URL, NSRange)?
        text.enumerateAttribute(.link, in: rest) { value, run, stop in
            guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)) else { return }
            var whole = run
            _ = text.attribute(.link, at: run.location, longestEffectiveRange: &whole, in: exposed)
            // One that began before `location` is not after it.
            guard whole.location >= location else { return }
            found = (url, whole)
            stop.pointee = true
        }
        return found
    }

    /// Gives `result`, the accessibility string of `range`, the reader's element for each link
    /// in place of AppKit's, and for each attachment in a link an element that is a link.
    func addAccessibilityLinks(_ links: [(url: URL, range: NSRange)], to result: NSMutableAttributedString, of range: NSRange) {
        guard let text = linkText else { return }
        func local(_ part: NSRange) -> NSRange? {
            let part = NSIntersectionRange(part, range)
            let local = NSRange(location: part.location - range.location, length: part.length)
            return part.length > 0 && NSMaxRange(local) <= result.length ? local : nil
        }
        for (url, whole) in links {
            guard let part = local(whole) else { continue }
            result.addAttribute(.accessibilityLink, value: linkElement(for: url, at: whole), range: part)
            text.enumerateAttribute(.attachment, in: NSIntersectionRange(whole, range)) { value, run, _ in
                // A table row is a group of its cells, whatever link it stands in.
                guard value != nil, !(value is TableRowAttachment), let part = local(run),
                      let element = linkElement(forAttachmentAt: run, of: url, at: whole) else { return }
                result.addAttribute(.accessibilityAttachment, value: element, range: part)
            }
        }
    }

    /// The element of the link at `range`, named and placed anew each time it is asked for.
    func linkElement(for url: URL, at range: NSRange) -> ReaderLinkAccessibilityElement {
        let element = linkElements.links[range.location] ?? ReaderLinkAccessibilityElement()
        linkElements.links[range.location] = element
        configure(element, url: url, range: range, title: linkTitle(range))
        return element
    }

    /// The link element that stands for the attachment at `run`, inside the link at `whole`,
    /// where VoiceOver reading the text is told of the link. An attachment that is all its
    /// link holds is the link's own element. One that says nothing, decoration passed over,
    /// has an element without a name when it opens a link of words, so that VoiceOver says
    /// "hyperlink" before them, and none elsewhere.
    private func linkElement(forAttachmentAt run: NSRange, of url: URL, at whole: NSRange) -> ReaderLinkAccessibilityElement? {
        if run == whole { return linkElement(for: url, at: whole) }
        let title = linkTitle(run)
        guard !title.isEmpty || (run.location == whole.location && hasWords(whole)) else { return nil }
        let element = linkElements.attachments[run.location] ?? ReaderLinkAccessibilityElement()
        linkElements.attachments[run.location] = element
        configure(element, url: url, range: run, title: title)
        return element
    }

    /// Whether `range` has characters of its own to read, beside its attachments.
    private func hasWords(_ range: NSRange) -> Bool {
        guard let text = linkText else { return false }
        var found = false
        text.enumerateAttribute(.attachment, in: NSIntersectionRange(range, NSRange(location: 0, length: text.length))) { value, run, stop in
            if value == nil, !(text.string as NSString).substring(with: run).allSatisfy(\.isWhitespace) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func configure(_ element: ReaderLinkAccessibilityElement, url: URL, range: NSRange, title: String) {
        element.view = self
        element.url = url
        element.range = range
        element.setAccessibilityParent(element.listing ?? self)
        element.setAccessibilityTitle(title.isEmpty ? nil : title)
        // A picture in a link is followed, not enlarged, by a press: inspection stays an action.
        element.setAccessibilityCustomActions(announcedImages(in: range).map { image, _ in
            NSAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") { [weak self] in
                self?.inspectLinkedImage(image) ?? false
            }
        })
    }

    /// What a link, or an attachment in one, is called: its words, with the text of each
    /// attachment in its place and decoration left out. One that holds pictures and nothing
    /// else is said to be a picture, in the system's own word for one, after any words the
    /// pictures have: an element that is a link cannot be an image as well.
    func linkTitle(_ range: NSRange) -> String {
        guard let text = linkText else { return "" }
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        let words = text.readerPlainText(in: range).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !announcedImages(in: range).isEmpty else { return words }
        var picturesOnly = true
        text.enumerateAttribute(.attachment, in: range) { value, run, stop in
            if value is ReaderImageAttachment { return }
            if value != nil || !(text.string as NSString).substring(with: run).allSatisfy(\.isWhitespace) {
                picturesOnly = false
                stop.pointee = true
            }
        }
        guard picturesOnly, let picture = NSAccessibility.Role.image.description(with: nil) else { return words }
        return words.isEmpty ? picture : "\(words), \(picture)"
    }

    /// The links on screen, which VoiceOver's Find Next Link moves through, in place of
    /// AppKit's own.
    func linkChildren() -> [ReaderLinkAccessibilityElement] {
        accessibilityLinks(in: visibleLinkCharacters).map { linkElement(for: $0.url, at: $0.range) }
    }

    /// The links on screen once more, as children of `listing`, the text this view stands in
    /// at `place`. From a link VoiceOver's Find Next Link goes on through the children of the
    /// link's own parent, so a link that a page lists has to be a child of the page to be one
    /// of its links: an element of its own there, with the same name, place and press.
    func linkChildren(listedIn listing: any ReaderLinkHost, at place: Int) -> [ReaderLinkAccessibilityElement] {
        accessibilityLinks(in: visibleLinkCharacters).map { url, range in
            let element = linkElements.listed[range.location] ?? ReaderLinkAccessibilityElement()
            linkElements.listed[range.location] = element
            element.listing = listing
            element.listedPlace = place
            configure(element, url: url, range: range, title: linkTitle(range))
            return element
        }
    }

    /// Where the characters of a link or a heading are, in this view's coordinates: at least
    /// a point, so that a hidden label, which takes no room, still has a place for VoiceOver's
    /// cursor, and no wider than the view, which a whole line's trailing space can be.
    func linkFrame(_ range: NSRange) -> CGRect {
        var frame = linkBounds(range)
        frame.size = CGSize(width: max(frame.width, 1), height: max(frame.height, 1))
        let inside = frame.intersection(bounds)
        return inside.isEmpty ? frame : inside
    }
}

extension ReaderTextView: ReaderLinkHost {
    var linkText: NSAttributedString? { canvas == nil ? nil : contentStorage.textStorage }

    /// A page column's own page, or all the text.
    var linkCharacters: NSRange { isPageColumn ? shownCharacters : NSRange(location: 0, length: textLength) }

    var visibleLinkCharacters: NSRange { accessibilityVisibleCharacterRange() }

    func linkBounds(_ range: NSRange) -> CGRect {
        var frame = segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
        if frame.isNull { frame = lineFrame(containing: range.location) ?? .zero }
        let origin = containerOrigin
        return frame.offsetBy(dx: origin.x, dy: origin.y)
    }

    func followLink(_ url: URL, at range: NSRange) -> Bool {
        guard let canvas else { return false }
        canvas.activateLink(url, range: range, in: self)
        return true
    }

    func inspectLinkedImage(_ image: ReaderImageAttachment) -> Bool {
        canvas?.inspectImage(image)
        return canvas != nil
    }

    /// The links Find Next Link moves through from this text, each with its place in the
    /// text: its own on screen and, where a table row stands, those of the row's cells. A row
    /// is one character of this text, so a cell's links are no links of its characters:
    /// without these children VoiceOver finds no link from the page that the cell has.
    ///
    /// In continuous scroll the book's next link after the screen is one more. VoiceOver takes
    /// an element for a place only when it is among the children of its text, and from the
    /// last link on screen Find Next Link began again with the first: the link below was
    /// reached by reading or scrolling to it. The element is the link's own, kept by its
    /// place in the text, so it is the same one when the link is on screen.
    func linkChildrenWithCells() -> [(place: Int, element: ReaderLinkAccessibilityElement)] {
        var found = linkChildren().map { (place: $0.range.location, element: $0) }
        for (location, cell) in tableInteraction?.accessibilityCellsInOrder ?? [] {
            found += cell.linkChildren(listedIn: self, at: location).map { (place: location, element: $0) }
        }
        if !isPageColumn, let next = accessibilityLink(after: NSMaxRange(visibleLinkCharacters)) {
            found.append((next.range.location, linkElement(for: next.url, at: next.range)))
        }
        return found
    }

    /// VoiceOver's cursor is on the link's element and not in the text, and its next move by
    /// word or by line starts from the insertion point, which was wherever it had last read,
    /// or the first line on screen. So the insertion point goes to the link. In continuous
    /// scroll a link with nothing on screen is shown first, as the reader shows a link's
    /// target: VoiceOver would scroll to the element by the scroll bar, which the reader
    /// takes for any other scroll.
    func showLink(at range: NSRange) {
        guard let canvas, range.location != NSNotFound, range.location <= textLength else { return }
        if !isPageColumn, !linkFrame(range).intersects(visibleRect), let position = canvas.position(at: range.location, in: self) {
            canvas.show(position, selecting: nil)
        }
        let place = NSRange(location: range.location, length: 0)
        if selectedRange != place { selectedRange = place }
    }

    func showsLink(at range: NSRange) -> Bool {
        selectedRange == NSRange(location: range.location, length: 0)
    }
}

/// A link in a reader text view as VoiceOver meets it: a child of the text that Find Next Link
/// moves to, the link of its characters in the text's accessibility string, and, where it is
/// an attachment's element, what VoiceOver announces as it reads. Control-Option-Space
/// presses it. It has AppKit's role for a link in text, which VoiceOver calls a hyperlink.
final class ReaderLinkAccessibilityElement: NSAccessibilityElement {
    /// The text view whose link it is.
    weak var view: (any ReaderLinkHost)?
    /// The view it is a child of, where that is not `view`: the page a table cell stands in.
    weak var listing: (any ReaderLinkHost)?
    /// Where the cell's row stands in that page's text: a row is one character of it.
    var listedPlace = 0
    /// The link's target in the reader's own scheme. Not given to assistive clients: nothing
    /// can open it.
    var url: URL?
    var range = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        setAccessibilityRole(.link)
        setAccessibilitySubrole(.textLink)
    }

    // AppKit asks on the main thread. The place is found when asked for: the view scrolls and
    // its lines move under an element that is kept.
    override func accessibilityFrameInParentSpace() -> NSRect {
        guard let view else { return .zero }
        let range = range, listing = listing
        return MainActor.assumeIsolated {
            let frame = view.linkFrame(range)
            return listing.map { $0.convert(frame, from: view) } ?? frame
        }
    }

    override func accessibilityFrame() -> NSRect {
        guard let view else { return .zero }
        let range = range
        return MainActor.assumeIsolated { NSAccessibility.screenRect(fromView: view, rect: view.linkFrame(range)) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let view, let url else { return false }
        let range = range
        return MainActor.assumeIsolated { view.followLink(url, at: range) }
    }

    // VoiceOver focuses the element it moves to while its cursor and the keyboard focus go
    // together (cursor tracking, which is on until a listener turns it off), and that is all
    // it tells the reader of the move. It focuses an element that says whether it has the
    // focus and takes it (macOS 27.0.1). A link has the focus while the insertion point is on
    // it, which is where taking the focus puts it, so the answer holds once VoiceOver has
    // read on and when it comes back. A cell's link that its page lists is on the page at the
    // cell's row, one character of the page's text.
    override func isAccessibilityFocused() -> Bool {
        guard let view else { return false }
        let range = range, listing = listing, row = NSRange(location: listedPlace, length: 1)
        return MainActor.assumeIsolated { listing?.showsLink(at: row) ?? view.showsLink(at: range) }
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard focused, let view else { return }
        let range = range, listing = listing, row = NSRange(location: listedPlace, length: 1)
        MainActor.assumeIsolated {
            if let listing { listing.showLink(at: row) } else { view.showLink(at: range) }
        }
    }
}
#endif
