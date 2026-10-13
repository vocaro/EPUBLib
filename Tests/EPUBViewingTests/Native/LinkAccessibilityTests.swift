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
                       [imageWord, "Jump with decoration", "Described jump", imageWord, "Words and a picture both"],
                       "never U+FFFC; a picture without words that is all its link holds is called by the system's word for one")
        XCTAssertEqual(children(of: view).map { $0.accessibilityTitle() ?? "" }, found.map { $0.element.accessibilityTitle() ?? "" })
        // A picture keeps its own element, so VoiceOver reading by word still says what it is.
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        let described = try XCTUnwrap(found.first { $0.element.accessibilityTitle() == "Described jump" })
        let image = try XCTUnwrap(rich.attribute(.accessibilityAttachment, at: described.range.location, effectiveRange: nil) as? NSAccessibilityElement)
        XCTAssertEqual(image.accessibilityRole(), .image)
        XCTAssertEqual(image.accessibilityLabel(), "Described jump")
        for (link, range) in found {
            let place = link.accessibilityFrame()
            XCTAssertGreaterThanOrEqual(place.width, 31, "\(link.accessibilityTitle() ?? "")")
            XCTAssertTrue(view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(place), "\(link.accessibilityTitle() ?? ""): \(place)")
            XCTAssertTrue(link.accessibilityPerformPress())
            XCTAssertEqual(host.recorder.links.last?.position, ReaderTextPosition(section: 0, offset: range.location))
        }
        XCTAssertEqual(host.recorder.links.map(\.link), ["a", "b", "c", "d", "e"].map { .internal(href: "OPS/\($0).xhtml") })
    }

    func testAHiddenLabelThatIsALinkHasItsWordsAndAPlace() throws {
        let (host, view) = try page("<p>Shown words.</p><p><a class=\"sr\" href=\"two.xhtml\">Skip to chapter two</a>End.</p>")
        XCTAssertEqual(view.accessibilityValue(), "Shown words.\n\u{FFFC}End.")
        let found = try links(in: view)
        XCTAssertEqual(found.map(\.range), [NSRange(location: 13, length: 1)])
        let link = try XCTUnwrap(found.first?.element)
        XCTAssertEqual(link.accessibilityTitle(), "Skip to chapter two")
        // The label takes no room. Without a place of some size VoiceOver cannot move to it.
        let place = link.accessibilityFrame()
        XCTAssertGreaterThanOrEqual(place.width, 1)
        XCTAssertGreaterThanOrEqual(place.height, 1)
        XCTAssertTrue(view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(place), "\(place) in \(view.accessibilityFrame())")
        XCTAssertEqual(place.midY, view.accessibilityFrame(for: NSRange(location: 14, length: 4)).midY, accuracy: 12, "in the line it stands in")
        XCTAssertTrue(link.accessibilityPerformPress())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        // Read by word it is still its words, as text.
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        let label = try XCTUnwrap(rich.attribute(.accessibilityAttachment, at: 13, effectiveRange: nil) as? NSAccessibilityElement)
        XCTAssertEqual(label.accessibilityRole(), .staticText)
        XCTAssertEqual(label.accessibilityValue() as? String, "Skip to chapter two")
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
