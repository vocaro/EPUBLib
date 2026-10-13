#if os(macOS)
import AppKit
import XCTest
@testable import EPUBViewing

/// A link in a Mac text view as an assistive client is given it (doc/native-viewer.md "Links
/// for VoiceOver on the Mac"): an element of the reader's own in the text's accessibility
/// string and among the text's children, named by its words, with a place and a press. API
/// level only: what VoiceOver says of it is recorded in doc/voiceover-testing.md.
@MainActor final class LinkAccessibilityTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private static let css = BoxLayoutHarness.reset + ".sr { position:absolute; left:-999em } img { width:32px; height:32px }"

    private func page(_ body: String, size: CGSize = CGSize(width: 420, height: 350)) throws -> (host: CanvasHost, view: ReaderTextView) {
        let section = try BoxLayoutHarness.build(body, css: Self.css, files: ["p.png": RichFixture.image(width: 64, height: 64)])
        return try page([section.string], size: size)
    }

    private func page(_ sections: [NSAttributedString], size: CGSize = CGSize(width: 420, height: 350)) throws -> (host: CanvasHost, view: ReaderTextView) {
        let host = CanvasHost(FakeCanvasSource(sections), size: size)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return (host, try XCTUnwrap(host.canvas.textViews.first))
    }

    /// The link elements of `range` in the text's accessibility string, each with its characters.
    private func links(in view: ReaderTextView, _ range: NSRange? = nil, file: StaticString = #filePath, line: UInt = #line) throws
        -> [(element: ReaderLinkAccessibilityElement, range: NSRange)] {
        let range = range ?? view.accessibilityVisibleCharacterRange()
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: range), file: file, line: line)
        XCTAssertEqual(rich.string, view.accessibilityString(for: range), "the characters are the text's own", file: file, line: line)
        var found: [(ReaderLinkAccessibilityElement, NSRange)] = []
        rich.enumerateAttribute(.accessibilityLink, in: NSRange(location: 0, length: rich.length)) { value, run, _ in
            guard let value else { return }
            guard let element = value as? ReaderLinkAccessibilityElement else {
                return XCTFail("a link AppKit made, which names an attachment by its character: \(value)", file: file, line: line)
            }
            found.append((element, NSRange(location: run.location + range.location, length: run.length)))
        }
        return found
    }

    private func children(of view: ReaderTextView) -> [ReaderLinkAccessibilityElement] {
        (view.accessibilityChildren() ?? []).compactMap { $0 as? ReaderLinkAccessibilityElement }
    }

    private var imageWord: String { NSAccessibility.Role.image.description(with: nil) ?? "" }

    func testALinkOfWordsIsOneElementWithItsWordsItsPlaceAndItsPress() throws {
        // The emphasis changes the font inside the link: one link all the same.
        let (host, view) = try page("<p>Before <a href=\"two.xhtml\">a link of <em>two</em> styles</a> after.</p><p>No link here.</p>")
        let text = try XCTUnwrap(view.accessibilityValue()) as NSString
        let words = text.range(of: "a link of two styles")
        let found = try links(in: view)
        XCTAssertEqual(found.map(\.range), [words])
        let link = try XCTUnwrap(found.first?.element)
        XCTAssertEqual(link.accessibilityRole(), .link)
        XCTAssertEqual(link.accessibilitySubrole(), .textLink, "the role AppKit gives a link in text, which VoiceOver calls a hyperlink")
        XCTAssertEqual(link.accessibilityTitle(), "a link of two styles")
        XCTAssertTrue(link.accessibilityParent() as AnyObject === view)
        XCTAssertNil(link.accessibilityURL(), "the target is in a scheme of the reader's own, which nothing can open")
        // Asked for a part of the link, as a line or a word is, the text gives the same element.
        let half = try links(in: view, NSRange(location: words.location + 4, length: 30))
        XCTAssertEqual(half.map(\.range), [NSRange(location: words.location + 4, length: words.length - 4)])
        XCTAssertTrue(half.first?.element === link)
        XCTAssertTrue(try links(in: view, text.range(of: "No link here.")).isEmpty)
        // Its words are read as words: VoiceOver would say an element given as their attachment
        // and then the words as well.
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            XCTAssertNil(value, "\(range)")
        }
        // Find Next Link moves through the text's children.
        XCTAssertEqual(children(of: view).map { ObjectIdentifier($0) }, [ObjectIdentifier(link)])
        // Its place is its words', where VoiceOver's cursor is drawn.
        let place = link.accessibilityFrame()
        XCTAssertEqual(place.minX, view.accessibilityFrame(for: words).minX, accuracy: 1)
        XCTAssertEqual(place.width, view.accessibilityFrame(for: words).width, accuracy: 1)
        XCTAssertEqual(place.midY, view.accessibilityFrame(for: words).midY, accuracy: 4)
        XCTAssertTrue(view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(place))
        // Control-Option-Space presses it.
        XCTAssertTrue(link.accessibilityPerformPress())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        XCTAssertEqual(host.recorder.links.last?.position, ReaderTextPosition(section: 0, offset: words.location))
    }

    /// The element given as the attachment of the character at `location`.
    private func attachment(at location: Int, in view: ReaderTextView) throws -> NSAccessibilityElement? {
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        return rich.attribute(.accessibilityAttachment, at: location, effectiveRange: nil) as? NSAccessibilityElement
    }

    func testALinkIsNamedByItsWordsAndItsPicturesWords() throws {
        let (host, view) = try page("""
            <p>Bare: <a href="a.xhtml"><img alt="" src="p.png"/></a></p>\
            <p><a href="b.xhtml"><img alt="" src="p.png"/> Jump with decoration</a></p>\
            <p><a href="c.xhtml"><img alt="Described jump" src="p.png"/></a></p>\
            <p>None: <a href="d.xhtml"><img src="p.png"/></a></p>\
            <p><a href="e.xhtml">Words and <img alt="a picture" src="p.png"/> both</a></p>
            """)
        let found = try links(in: view)
        XCTAssertFalse(imageWord.isEmpty)
        XCTAssertEqual(found.map { $0.element.accessibilityTitle() ?? "" },
                       [imageWord, "Jump with decoration", "Described jump, \(imageWord)", imageWord, "Words and a picture both"],
                       "never U+FFFC; a link that holds pictures and nothing else says that it is a picture, in the system's word")
        XCTAssertEqual(children(of: view).map { $0.accessibilityTitle() ?? "" }, found.map { $0.element.accessibilityTitle() ?? "" })
        for (link, range) in found {
            let place = link.accessibilityFrame()
            XCTAssertGreaterThanOrEqual(place.width, 31, "\(link.accessibilityTitle() ?? "")")
            XCTAssertTrue(view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(place), "\(link.accessibilityTitle() ?? ""): \(place)")
            XCTAssertTrue(link.accessibilityPerformPress())
            XCTAssertEqual(host.recorder.links.last?.position, ReaderTextPosition(section: 0, offset: range.location))
        }
        XCTAssertEqual(host.recorder.links.map(\.link), ["a", "b", "c", "d", "e"].map { .internal(href: "OPS/\($0).xhtml") })
    }

    /// VoiceOver announces an element given as a character's attachment as it reads, and none
    /// at a character of words: a link is announced at its attachments.
    func testAnAttachmentInALinkIsALinkWhereVoiceOverReadsIt() throws {
        let (host, view) = try page("""
            <p>Bare: <a href="a.xhtml"><img alt="" src="p.png"/></a></p>\
            <p><a href="b.xhtml"><img alt="" src="p.png"/> Jump with decoration</a></p>\
            <p><a href="c.xhtml"><img alt="Described jump" src="p.png"/></a></p>\
            <p><a href="e.xhtml">Words and <img alt="a picture" src="p.png"/> both <img alt="" src="p.png"/></a></p>\
            <p>Alone: <img alt="Unlinked" src="p.png"/></p>
            """)
        let found = try links(in: view)
        let text = try XCTUnwrap(view.accessibilityValue()) as NSString
        // A picture that is all its link holds is the link's own element.
        for index in [0, 2] {
            let element = try XCTUnwrap(attachment(at: found[index].range.location, in: view))
            XCTAssertTrue(element === found[index].element, "\(index)")
        }
        XCTAssertEqual(found[0].element.accessibilityCustomActions()?.map(\.name), ["Inspect Image"])
        XCTAssertEqual(found[2].element.accessibilityCustomActions()?.map(\.name), ["Inspect Image: Described jump"],
                       "a press follows the link, so inspecting the picture stays an action")
        XCTAssertTrue(try XCTUnwrap(found[2].element.accessibilityCustomActions()?.first).handler?() ?? false)
        XCTAssertNotNil(host.canvas.imageInspector)
        host.canvas.imageInspector?.close()
        // Decoration that opens a link of words says "hyperlink" before them, and no name.
        let opening = try XCTUnwrap(attachment(at: found[1].range.location, in: view) as? ReaderLinkAccessibilityElement)
        XCTAssertFalse(opening === found[1].element)
        XCTAssertEqual(opening.accessibilityRole(), .link)
        XCTAssertNil(opening.accessibilityTitle())
        XCTAssertEqual(opening.accessibilityCustomActions()?.count ?? 0, 0)
        XCTAssertTrue(opening.accessibilityPerformPress())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/b.xhtml"))
        XCTAssertNil(try attachment(at: text.range(of: "Jump with").location, in: view), "the words are read as words")
        // A picture among a link's words is a link by its own words, where it stands.
        let among = try XCTUnwrap(attachment(at: text.range(of: "Words and ").upperBound, in: view) as? ReaderLinkAccessibilityElement)
        XCTAssertEqual(among.accessibilityTitle(), "a picture, \(imageWord)")
        XCTAssertEqual(among.range, NSRange(location: text.range(of: "Words and ").upperBound, length: 1))
        XCTAssertTrue(among.accessibilityPerformPress())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/e.xhtml"))
        XCTAssertEqual(host.recorder.links.last?.position, ReaderTextPosition(section: 0, offset: among.range.location))
        // Decoration after the link's first character is passed over, as outside a link.
        XCTAssertNil(try attachment(at: NSMaxRange(found[3].range) - 1, in: view))
        // A picture outside a link is an image, as it was.
        let unlinked = try XCTUnwrap(attachment(at: text.range(of: "Alone: ").upperBound, in: view))
        XCTAssertEqual(unlinked.accessibilityRole(), .image)
        XCTAssertEqual(unlinked.accessibilityLabel(), "Unlinked")
    }

    func testAHiddenLabelThatIsALinkIsALinkWithItsWordsAndAPlace() throws {
        let (host, view) = try page("""
            <p>Shown words.</p><p><a class="sr" href="two.xhtml">Skip to chapter two</a>End.</p>\
            <p><a href="three.xhtml"><span class="sr">Go to</span> chapter three</a></p>
            """)
        XCTAssertEqual(view.accessibilityValue(), "Shown words.\n\u{FFFC}End.\n\u{FFFC}chapter three")
        let found = try links(in: view)
        XCTAssertEqual(found.map(\.range), [NSRange(location: 13, length: 1), NSRange(location: 19, length: 14)])
        XCTAssertEqual(found.map { $0.element.accessibilityTitle() ?? "" }, ["Skip to chapter two", "Go to chapter three"])
        let link = found[0].element
        // The label takes no room. Without a place of some size VoiceOver cannot move to it.
        let place = link.accessibilityFrame()
        XCTAssertGreaterThanOrEqual(place.width, 1)
        XCTAssertGreaterThanOrEqual(place.height, 1)
        XCTAssertTrue(view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(place), "\(place) in \(view.accessibilityFrame())")
        XCTAssertEqual(place.midY, view.accessibilityFrame(for: NSRange(location: 14, length: 4)).midY, accuracy: 12, "in the line it stands in")
        XCTAssertTrue(link.accessibilityPerformPress())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        // Read by word or by line it is announced as a link: the label's own element is the link's.
        XCTAssertTrue(try attachment(at: 13, in: view) === link)
        // A label that opens a longer link is a link by its own words there.
        let opening = try XCTUnwrap(attachment(at: 19, in: view) as? ReaderLinkAccessibilityElement)
        XCTAssertEqual(opening.accessibilityTitle(), "Go to")
        XCTAssertFalse(opening === found[1].element)
        XCTAssertTrue(opening.accessibilityPerformPress())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/three.xhtml"))
    }

    func testAFormulaInALinkIsALinkByItsReadingAndANotesPopoverKeepsAppKitsLinks() throws {
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Follow "))
        let formula = TextualTestAttachment()
        formula.textEquivalent = "E = mc²"
        formula.image = (CanvasText.attachment(size: CGSize(width: 40, height: 20))
            .attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
        formula.bounds = CGRect(x: 0, y: 0, width: 40, height: 20)
        text.append(NSAttributedString(attachment: formula))
        text.append(CanvasText.body(" now and read on."))
        text.addAttribute(.link, value: ReaderLink.internal(href: "OPS/two.xhtml").url, range: NSRange(location: 0, length: 12))
        let (_, view) = try page([text])
        let found = try links(in: view)
        XCTAssertEqual(found.map { $0.element.accessibilityTitle() ?? "" }, ["Follow E = mc² now"])
        let reading = try XCTUnwrap(attachment(at: 7, in: view) as? ReaderLinkAccessibilityElement)
        XCTAssertEqual(reading.accessibilityTitle(), "E = mc²", "no picture: a formula is its reading")
        // A text view with no canvas, as a note's popover has, follows no link: AppKit's own
        // elements stay, and the reader adds none.
        let note = BoxLayoutHarness.view(text, size: CGSize(width: 300, height: 200), pageColumn: false)
        XCTAssertFalse((note.accessibilityChildren() ?? []).contains { $0 is ReaderLinkAccessibilityElement })
        let rich = try XCTUnwrap(note.accessibilityAttributedString(for: NSRange(location: 0, length: 12)))
        XCTAssertNotNil(rich.attribute(.accessibilityLink, at: 0, effectiveRange: nil))
        XCTAssertFalse(rich.attribute(.accessibilityLink, at: 0, effectiveRange: nil) is ReaderLinkAccessibilityElement)
    }

    func testAPageColumnGivesItsOwnPagesLinksAndEndsOneAtThePagesEnd() throws {
        // A link that crosses the page's end and one in the context laid out after it.
        let prose = CanvasText.body(CanvasText.sentence(700, seed: 3))
        let length = try page([prose]).view.placement.visibleLength
        XCTAssertGreaterThan(prose.length, length + 60, "the page ends inside the paragraph")
        let text = NSMutableAttributedString(attributedString: prose)
        let url = ReaderLink.internal(href: "OPS/two.xhtml").url
        text.addAttribute(.link, value: url, range: NSRange(location: 20, length: 6))
        text.addAttribute(.link, value: ReaderLink.internal(href: "OPS/three.xhtml").url, range: NSRange(location: length - 8, length: 20))
        text.addAttribute(.link, value: url, range: NSRange(location: length + 40, length: 6))
        let (host, view) = try page([text])
        XCTAssertEqual(view.placement.visibleLength, length, "a link's attribute moves no line")
        var found = try links(in: view)
        XCTAssertEqual(found.map(\.range), [NSRange(location: 20, length: 6), NSRange(location: length - 8, length: 8)])
        XCTAssertEqual(found.last?.element.accessibilityTitle(),
                       (text.string as NSString).substring(with: NSRange(location: length - 8, length: 8)).trimmingCharacters(in: .whitespaces),
                       "the words on this page")
        XCTAssertEqual(children(of: view).map(\.range), found.map(\.range), "the link after the page is not listed")
        for (link, _) in found {
            XCTAssertTrue(view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(link.accessibilityFrame()))
        }
        let before = found.map(\.element)
        // The next page has the rest of the link, and the one that was context.
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        host.layOut()
        let next = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(next.placement.offset, length)
        found = try links(in: next)
        XCTAssertEqual(found.map(\.range), [NSRange(location: 0, length: 12), NSRange(location: 40, length: 6)])
        XCTAssertTrue(found.allSatisfy { link in !before.contains { $0 === link.element } }, "a new page's links are new elements")
        XCTAssertTrue(try XCTUnwrap(found.first?.element).accessibilityPerformPress())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/three.xhtml"))
        XCTAssertEqual(host.recorder.links.last?.position, ReaderTextPosition(section: 0, offset: length))
    }

    func testContinuousScrollListsTheLinksOnScreenAndGivesAnyLinkOfItsText() throws {
        let sections = (0..<3).map { CanvasText.section($0) }
        let source = FakeCanvasSource(sections)
        source.book = CanvasText.book(sections)
        let host = CanvasHost(source, size: CGSize(width: 500, height: 600), configuration: .init(flow: .scrolled))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        let text = try XCTUnwrap(view.contentStorage.textStorage)
        var all: [NSRange] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { all.append(range) }
        }
        XCTAssertEqual(all.count, 3, "each section's first paragraph ends in a link")
        // The first section's link is on screen with its paragraph; the others are not.
        let visible = view.accessibilityVisibleCharacterRange()
        XCTAssertTrue(NSLocationInRange(all[0].location, visible))
        XCTAssertFalse(NSLocationInRange(all[2].location, visible))
        XCTAssertEqual(children(of: view).map(\.range), all.filter { NSLocationInRange($0.location, visible) })
        // The text of the whole book is one text: a link far below is still an element there.
        let far = try links(in: view, all[2])
        XCTAssertEqual(far.map(\.range), [all[2]])
        XCTAssertEqual(far.first?.element.accessibilityTitle(), "a link")
        XCTAssertTrue(try XCTUnwrap(far.first?.element).accessibilityPerformPress())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml#target"))
        XCTAssertEqual(host.recorder.links.last?.position.section, 2)
    }
}
#endif
