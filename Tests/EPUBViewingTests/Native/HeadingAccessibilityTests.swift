import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the text views give an assistive technology of a book's headings ("Accessibility" in
/// `doc/native-viewer.md`): on UIKit one element for a heading, with the header trait and its
/// level; on AppKit the level on the heading's characters and a Headings rotor over them. API
/// level only: no assistive technology is driven (`doc/voiceover-testing.md` has what
/// VoiceOver said).
@MainActor final class HeadingAccessibilityTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private var hosts: [CanvasHost] = []
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    private static let css = H.reset + ".sr { position:absolute; left:-999em } "

    /// A first heading that takes two lines of a narrow column, a heading with a link in it,
    /// a hidden heading, and one deeper than any level a platform has.
    private static let page = """
        <h1>A chapter title long enough to take two lines of the page</h1><p>Plain words follow it.</p>\
        <h2>Second <a href="two.xhtml">linked</a> part</h2><h3 class="sr">Hidden third</h3><p>Words under the hidden one.</p>\
        <h1 aria-level="9">Deeper than six</h1><p>Last words.</p>
        """

    private func host(_ text: NSAttributedString, size: CGSize) -> CanvasHost {
        let host = CanvasHost(FakeCanvasSource([text]), size: size)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return host
    }

    private func shownPage(size: CGSize = CGSize(width: 320, height: 640)) throws -> (section: SectionText, host: CanvasHost, view: ReaderTextView) {
        let section = try H.build(Self.page, css: Self.css)
        XCTAssertEqual(section.string.string, "A chapter title long enough to take two lines of the page\nPlain words follow it.\n"
            + "Second linked part\n\u{FFFC}Words under the hidden one.\nDeeper than six\nLast words.")
        let host = host(section.string, size: size)
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(view.shownCharacters.length, section.string.length, "the whole section is on the page")
        return (section, host, view)
    }

    /// A chapter of several pages: headings at four levels among long paragraphs.
    private func chapter() throws -> SectionText {
        try H.build("""
            <h1>A chapter title long enough to take two lines of a narrow page column</h1><p>\(CanvasText.sentence(150, seed: 1))</p>\
            <h2>Second level</h2><p>\(CanvasText.sentence(260, seed: 2))</p><h3>Third <em>level</em><br/>on two lines</h3>\
            <p>\(CanvasText.sentence(300, seed: 3))</p><h4>Fourth level</h4><p>\(CanvasText.sentence(200, seed: 4))</p>
            """, css: Self.css)
    }

    /// A book with a float or a positioned box has every paragraph's attributes written again
    /// when its boxes are placed (`ReaderBoxLayout.resolve`): the headings are still marked in
    /// the text the view lays out, on the same characters.
    func testAHeadingBesideAFloatIsStillMarkedInTheViewThatLaysItOut() throws {
        let section = try H.build("""
            <h1>Before the float</h1><div style="float:left; width:90px; height:120px">Floated box</div>\
            <h2>Beside the float</h2><p>\(H.prose)</p><h3 class="sr">Hidden beside it</h3><p>After.</p>
            """, css: Self.css)
        let view = H.view(section.string, size: CGSize(width: 360, height: 640))
        XCTAssertTrue(view.readerContainer.hasNonlinearGeometry, "the float must be placed for this to show anything")
        let built = section.string.readerHeadings(), shown = try XCTUnwrap(view.contentStorage.textStorage).readerHeadings()
        XCTAssertEqual(built.map { section.string.readerPlainText(in: $0.range) }, ["Before the float", "Beside the float", "Hidden beside it"])
        XCTAssertEqual(shown.map(\.range), built.map(\.range))
        XCTAssertEqual(shown.map(\.heading.level), [1, 2, 3])
        XCTAssertTrue(zip(shown, built).allSatisfy { $0.heading === $1.heading })
    }

    #if os(iOS)
    /// What VoiceOver is given of an element: "heading" and its level where it is one, "link"
    /// where it is one, and its words.
    private func read(_ element: UIAccessibilityElement) -> String {
        var parts: [String] = []
        if element.accessibilityTraits.contains(.header) {
            let label = element.accessibilityAttributedLabel
            let level = (label?.length ?? 0) > 0 ? label?.attribute(.accessibilityTextHeadingLevel, at: 0, effectiveRange: nil) as? Int : nil
            parts.append("heading \(level.map(String.init) ?? "without a level")")
        }
        if element.accessibilityTraits.contains(.link) { parts.append("link") }
        if element.accessibilityTraits.contains(.image) { parts.append("image") }
        parts.append((element.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.joined(separator: " ")
    }

    func testAHeadingIsOneElementWithTheHeaderTraitAndItsLevel() throws {
        let (section, host, view) = try shownPage()
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map(read), [
            "heading 1 A chapter title long enough to take two lines of the page", "Plain words follow it.",
            "heading 2 Second", "heading 2 link linked", "heading 2 part", "heading 3 Hidden third",
            "Words under the hidden one.", "heading 0 Deeper than six", "Last words."])
        XCTAssertTrue(elements.allSatisfy { $0.accessibilityTraits.contains(.staticText) || $0.accessibilityTraits.contains(.link) })
        // The first heading takes two lines and is one element over both.
        let title = section.string.readerHeadings()[0].range
        let lines = view.pageAccessibilityLines.filter { NSIntersectionRange($0.range, title).length > 0 }
        XCTAssertGreaterThanOrEqual(lines.count, 2, "the heading must wrap for this to show anything")
        let frame = elements[0].accessibilityFrameInContainerSpace
        let both = lines.reduce(CGRect.null) { $0.union($1.frame) }.offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y)
        XCTAssertEqual(frame.minY, both.minY, accuracy: 1)
        XCTAssertEqual(frame.maxY, both.maxY, accuracy: 1)
        XCTAssertGreaterThan(frame.height, lines[0].frame.height * 1.5)
        // The label VoiceOver speaks and the one it takes the level from are the same words.
        XCTAssertEqual(elements[0].accessibilityAttributedLabel?.string, elements[0].accessibilityLabel)
        XCTAssertEqual(elements[0].accessibilityLabel, "A chapter title long enough to take two lines of the page\n",
                       "with the break that ends its paragraph, as a line has it")
        // The container protocol agrees, and each element is where its text is.
        XCTAssertEqual(view.accessibilityElementCount(), elements.count)
        for (index, element) in elements.enumerated() {
            XCTAssertEqual(view.index(ofAccessibilityElement: element), index)
            XCTAssertFalse(element.accessibilityFrameInContainerSpace.isEmpty, read(element))
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(element.accessibilityFrameInContainerSpace), read(element))
        }
        // A link in a heading is still followed, and a heading has its page's actions.
        XCTAssertTrue(elements[3].accessibilityActivate())
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        XCTAssertEqual(elements[0].accessibilityCustomActions?.map(\.name), ["Next Page", "Previous Page"])
        // The same elements while the page stands.
        XCTAssertTrue(zip(elements, try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])).allSatisfy { $0 === $1 })
    }

    func testAPageGivesThePartOfAHeadingItShows() throws {
        let section = try H.build(Self.page, css: Self.css)
        let view = H.view(section.string, size: CGSize(width: 320, height: 640))
        let title = section.string.readerHeadings()[0].range
        // A page that ends inside the heading's first line, as one cut by its column's foot.
        view.placement.visibleLength = 12
        view.exposeTextualAttachments()
        let cut = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(cut.map(read), ["heading 1 A chapter ti"])
        // And the page after it, which begins with the rest: clipped context follows the page's end.
        let rest = NSRange(location: 12, length: section.string.length - 12)
        let next = H.view(section.string.attributedSubstring(from: rest), size: CGSize(width: 320, height: 640))
        next.placement = ReaderTextPlacement(section: 0, offset: 12, visibleLength: NSMaxRange(title) + 1 - 12)
        next.exposeTextualAttachments()
        XCTAssertEqual(try XCTUnwrap(next.accessibilityElements as? [UIAccessibilityElement]).map(read),
                       ["heading 1 tle long enough to take two lines of the page"])
    }

    func testEveryCharacterIsStillReadOnceAcrossThePagesOfAChapterWithHeadings() throws {
        let section = try chapter()
        for size in [CGSize(width: 320, height: 560), CGSize(width: 1100, height: 420)] {
            let host = host(section.string, size: size)
            var spoken = "", headings: [String] = [], turns = 0
            repeat {
                for view in host.canvas.textViews where !view.isHidden {
                    let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
                    XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" }.joined(), view.visibleText)
                    spoken += view.visibleText
                    headings += elements.filter { $0.accessibilityTraits.contains(.header) }.map(read)
                }
                turns += 1
            } while turns < 100 && host.canvas.turnPage(forward: true) == .turned
            XCTAssertEqual(spoken, section.string.string, "every character on its own page, once, at \(size)")
            XCTAssertEqual(headings, ["heading 1 A chapter title long enough to take two lines of a narrow page column",
                                      "heading 2 Second level", "heading 3 Third level\u{2028}on two lines", "heading 4 Fourth level"],
                           "each heading once, whole, at \(size)")
        }
    }

    // MARK: The Headings rotor

    /// The item the view's Headings rotor gives with VoiceOver's cursor on `element` (on none of
    /// the view's lines when nil), as VoiceOver asks when a finger flicks down or up.
    private func rotorHeading(from element: UIAccessibilityElement?, in view: ReaderTextView, forward: Bool) throws -> UIAccessibilityElement? {
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors?.first { $0.systemRotorType == .heading }, "the view gives VoiceOver its Headings rotor")
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = forward ? .next : .previous
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: element ?? view, targetRange: nil)
        return rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement
    }

    func testTheHeadingsRotorMovesAmongThePagesHeadingsOneStopForEach() throws {
        let (_, _, view) = try shownPage()
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        // The title, the second heading's first words, the hidden one, the deepest.
        let stops = [elements[0], elements[2], elements[5], elements[7]]
        for (index, stop) in stops.enumerated() {
            let next = try rotorHeading(from: stop, in: view, forward: true)
            XCTAssertTrue(next === (index + 1 < stops.count ? stops[index + 1] : nil), "after \(read(stop)): \(next.map(read) ?? "none")")
            let previous = try rotorHeading(from: stop, in: view, forward: false)
            XCTAssertTrue(previous === (index > 0 ? stops[index - 1] : nil), "before \(read(stop)): \(previous.map(read) ?? "none")")
        }
        // From a line that is no heading, and from inside a heading: its link, its last words.
        XCTAssertTrue(try rotorHeading(from: elements[1], in: view, forward: true) === elements[2])
        XCTAssertTrue(try rotorHeading(from: elements[1], in: view, forward: false) === elements[0])
        for inside in [elements[3], elements[4]] {
            XCTAssertTrue(try rotorHeading(from: inside, in: view, forward: true) === elements[5], "the next heading, not the rest of this one")
            XCTAssertTrue(try rotorHeading(from: inside, in: view, forward: false) === elements[0], "the one before, not its own first words")
        }
        // With the cursor on none of the lines: from before the first, or after the last.
        XCTAssertTrue(try rotorHeading(from: nil, in: view, forward: true) === elements[0])
        XCTAssertTrue(try rotorHeading(from: nil, in: view, forward: false) === elements[7])
        XCTAssertTrue(zip(elements, try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])).allSatisfy { $0 === $1 },
                      "a page that holds the heading asked for is not shown again")
    }

    func testTheHeadingsRotorTurnsToThePageOfTheBooksNextHeading() throws {
        let section = try chapter()
        let second = try H.build("<h1>The chapter after</h1><p>\(CanvasText.sentence(120, seed: 7))</p><h2>Its last heading</h2><p>End.</p>", css: Self.css)
        let source = FakeCanvasSource([section.string, second.string])
        let host = CanvasHost(source, size: CGSize(width: 320, height: 560))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        func column() throws -> ReaderTextView { try XCTUnwrap(host.canvas.textViews.first) }
        var cursor = try XCTUnwrap(try XCTUnwrap(column().accessibilityElements as? [UIAccessibilityElement]).first)
        XCTAssertEqual(read(cursor), "heading 1 A chapter title long enough to take two lines of a narrow page column")
        // Forward through the book: each move shows the page that holds the heading it gives.
        var heard: [String] = [], places: [ReaderTextPosition] = []
        while let next = try rotorHeading(from: cursor, in: try XCTUnwrap(cursor.accessibilityContainer as? ReaderTextView), forward: true) {
            let view = try XCTUnwrap(next.accessibilityContainer as? ReaderTextView)
            XCTAssertTrue(try column() === view, "\(read(next)) is on the page now shown")
            XCTAssertNotEqual(view.index(ofAccessibilityElement: next), NSNotFound)
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(next.accessibilityFrameInContainerSpace), read(next))
            heard.append(read(next))
            places.append(ReaderTextPosition(section: try XCTUnwrap(view.placement.section), offset: view.placement.offset))
            cursor = next
            XCTAssertLessThan(heard.count, 20)
        }
        XCTAssertEqual(heard, ["heading 2 Second level", "heading 3 Third level\u{2028}on two lines", "heading 4 Fourth level",
                               "heading 1 The chapter after", "heading 2 Its last heading"])
        XCTAssertEqual(places.map(\.section), [0, 0, 0, 1, 1])
        XCTAssertTrue(zip(places, places.dropFirst()).allSatisfy { $0.section < $1.section || $0.offset <= $1.offset }, "onward through the book")
        XCTAssertGreaterThan(places[0].offset, 0, "the second heading is on a later page than the first")
        XCTAssertEqual(host.recorder.shown.last?.range.start.section, 1, "the reader reports the place it was taken to")
        // And back to the first page of the first chapter.
        var back: [String] = []
        while let previous = try rotorHeading(from: cursor, in: try XCTUnwrap(cursor.accessibilityContainer as? ReaderTextView), forward: false) {
            back.append(read(previous))
            cursor = previous
            XCTAssertLessThan(back.count, 20)
        }
        XCTAssertEqual(back, ["heading 1 The chapter after", "heading 4 Fourth level", "heading 3 Third level\u{2028}on two lines",
                              "heading 2 Second level", "heading 1 A chapter title long enough to take two lines of a narrow page column"])
        XCTAssertEqual(try column().placement.section, 0)
        XCTAssertEqual(try column().placement.offset, 0)
    }

    func testTheHeadingsRotorFindsNoneInAChapterThatIsNotBuiltYet() throws {
        let section = try H.build("<h1>Only heading</h1><p>Words.</p>", css: Self.css)
        let host = CanvasHost(FakeCanvasSource([section.string, nil]), size: CGSize(width: 320, height: 560))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let first = try XCTUnwrap(try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement]).first)
        XCTAssertNil(try rotorHeading(from: first, in: view, forward: true))
        XCTAssertEqual(view.placement.section, 0, "and the reader stays where it is")
        XCTAssertTrue(try rotorHeading(from: nil, in: view, forward: true) === first)
    }

    func testTheHeadingsRotorScrollsToTheBooksNextHeadingInContinuousScroll() async throws {
        let reader = try SessionCoverageReader(try SessionCoverageBook.chapters())
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas), view = try XCTUnwrap(canvas.scrollTextView)
        var cursor = try XCTUnwrap(try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement]).first)
        XCTAssertEqual(read(cursor), "heading 1 First Chapter")
        // Each chapter's heading is many screens from the one before.
        var heard: [String] = [], sections: [Int] = []
        while let next = try rotorHeading(from: cursor, in: view, forward: true) {
            let area = canvas.scrollVisibleContainerRect.offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y).insetBy(dx: -1_000, dy: -1)
            XCTAssertTrue(area.contains(next.accessibilityFrameInContainerSpace), "\(read(next)) is on screen at \(next.accessibilityFrameInContainerSpace) in \(area)")
            XCTAssertNotEqual(view.index(ofAccessibilityElement: next), NSNotFound)
            // The lines around the place the cursor left are still listed before it.
            let top = try XCTUnwrap(view.line(containing: try XCTUnwrap(canvas.scrollSpokenCharacters()).location))
            XCTAssertEqual(view.plainText(in: top.range), next.accessibilityLabel, "at the top of the screen")
            heard.append(read(next))
            sections.append(try XCTUnwrap(canvas.visibleRange).start.section)
            // VoiceOver's cursor goes to what it is given.
            next.accessibilityElementDidBecomeFocused()
            cursor = next
            XCTAssertLessThan(heard.count, 10)
        }
        XCTAssertEqual(heard, ["heading 1 Second Chapter", "heading 1 Third Chapter"])
        XCTAssertEqual(sections, [2, 3])
        let previous = try XCTUnwrap(try rotorHeading(from: cursor, in: view, forward: false))
        XCTAssertEqual(read(previous), "heading 1 Second Chapter")
        XCTAssertEqual(canvas.visibleRange?.start.section, 2)
        // A note's popover keeps UIKit's own elements and rotors.
        let note = ReaderNoteViewController(text: CanvasText.body("A note."), dark: false, width: 300)
        XCTAssertNil(note.textView.accessibilityCustomRotors)
    }
    #else
    /// The levels VoiceOver is given in the rich text of `range`, each with the words it is on.
    private func levels(in view: ReaderTextView, _ range: NSRange) throws -> [String] {
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: range))
        XCTAssertEqual(rich.length, range.length)
        var found: [String] = []
        rich.enumerateAttribute(.accessibilityHeadingLevel, in: NSRange(location: 0, length: rich.length)) { value, run, _ in
            guard let level = value as? Int else { return }
            found.append("\(level) \(view.plainText(in: NSRange(location: range.location + run.location, length: run.length)))")
        }
        return found
    }

    /// Every heading the view's Headings rotor gives, asked from nowhere and then from each
    /// result on. `listing` begins as VoiceOver was seen to when it lists a rotor's items
    /// (macOS 27.0.1): from an item with no element, at the first character and none of it.
    private func rotorHeadings(of view: ReaderTextView, forward: Bool = true, filter: String = "",
                               listing: Bool = false) throws -> [(label: String, range: NSRange)] {
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors().first { $0.type == .heading }, "the text view has a Headings rotor")
        let delegate = try XCTUnwrap(rotor.itemSearchDelegate)
        var found: [(String, NSRange)] = []
        var current = listing ? NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: "nowhere" as NSString, customLabel: "") : nil
        current?.targetRange = NSRange(location: 0, length: 0)
        XCTAssertNil(current?.targetElement)
        for _ in 0..<200 {
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.currentItem = current
            parameters.searchDirection = forward ? .next : .previous
            parameters.filterString = filter
            guard let result = delegate.rotor(rotor, resultFor: parameters) else { break }
            XCTAssertTrue(result.targetElement === view)
            found.append((result.customLabel ?? "", result.targetRange))
            current = result
        }
        return found
    }

    /// The heading the rotor gives from a place in the text.
    private func heading(of view: ReaderTextView, from range: NSRange, forward: Bool) throws -> String? {
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors().first { $0.type == .heading })
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        let current = NSAccessibilityCustomRotor.ItemResult(targetElement: view)
        current.targetRange = range
        parameters.currentItem = current
        parameters.searchDirection = forward ? .next : .previous
        return try XCTUnwrap(rotor.itemSearchDelegate).rotor(rotor, resultFor: parameters)?.customLabel
    }

    func testAHeadingsCharactersCarryItsLevelInThePagesRichText() throws {
        let (section, _, view) = try shownPage()
        XCTAssertEqual(try levels(in: view, view.shownCharacters), [
            "1 A chapter title long enough to take two lines of the page", "2 Second linked part", "3 Hidden third"],
            "ordinary text carries none, and neither does a heading with no level a listener could be told")
        XCTAssertEqual(view.accessibilityValue(), section.string.string, "the characters as they are")
        // Asked for part of a heading, as VoiceOver asks line by line and word by word.
        let title = section.string.readerHeadings()[0].range
        XCTAssertEqual(try levels(in: view, NSRange(location: 10, length: 5)), ["1 title"])
        XCTAssertEqual(try levels(in: view, NSRange(location: NSMaxRange(title), length: 10)), [], "the break and the words after it")
        // The hidden heading is still text where it stands, now with its level.
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        let label = (section.string.string as NSString).range(of: "\u{FFFC}").location
        let element = try XCTUnwrap(rich.attribute(.accessibilityAttachment, at: label, effectiveRange: nil) as? NSAccessibilityElement)
        XCTAssertEqual(element.accessibilityRole(), .staticText)
        XCTAssertEqual(element.accessibilityValue() as? String, "Hidden third")
        XCTAssertEqual(rich.attribute(.accessibilityHeadingLevel, at: label, effectiveRange: nil) as? Int, 3)
    }

    func testTheHeadingsRotorGivesThePagesHeadingsInOrderEitherWay() throws {
        let (section, _, view) = try shownPage()
        let expected = section.string.readerHeadings().map(\.range)
        let labels = ["A chapter title long enough to take two lines of the page, heading level 1", "Second linked part, heading level 2",
                      "Hidden third, heading level 3", "Deeper than six"]
        let forward = try rotorHeadings(of: view)
        XCTAssertEqual(forward.map(\.label), labels, "by its words and level: the hidden one, and the one with no level too")
        XCTAssertEqual(forward.map(\.range), expected, "each at its own characters")
        XCTAssertEqual(try rotorHeadings(of: view, forward: false).map(\.label), labels.reversed())
        // As VoiceOver lists them: the heading that opens the text is the first, not passed over.
        XCTAssertEqual(try rotorHeadings(of: view, listing: true).map(\.label), labels)
        XCTAssertEqual(try rotorHeadings(of: view, forward: false, listing: true).map(\.label), labels.reversed())
        // From a place in the text, as when VoiceOver's cursor is on a word.
        let text = section.string.string as NSString
        let plain = text.range(of: "Plain words"), inside = text.range(of: "linked")
        XCTAssertEqual(try heading(of: view, from: plain, forward: true), labels[1])
        XCTAssertEqual(try heading(of: view, from: plain, forward: false), labels[0])
        XCTAssertEqual(try heading(of: view, from: inside, forward: true), labels[2], "from inside a heading, the next one")
        XCTAssertEqual(try heading(of: view, from: inside, forward: false), labels[0], "and the one before it, not itself")
        // With its cursor on the heading that opens the text, VoiceOver asks from that
        // heading's line; the first character and none of it is how it says nowhere.
        XCTAssertEqual(try heading(of: view, from: expected[0], forward: true), labels[1])
        XCTAssertEqual(try heading(of: view, from: NSRange(location: 0, length: 27), forward: true), labels[1])
        XCTAssertNil(try heading(of: view, from: expected[0], forward: false), "none before the first")
        XCTAssertEqual(try heading(of: view, from: NSRange(location: 0, length: 0), forward: true), labels[0])
        XCTAssertEqual(try heading(of: view, from: NSRange(location: NSNotFound, length: 0), forward: true), labels[0])
        XCTAssertEqual(try heading(of: view, from: NSRange(location: NSNotFound, length: 0), forward: false), labels[3])
        XCTAssertNil(try heading(of: view, from: text.range(of: "Last words"), forward: true), "none past the last")
        // What is typed in the rotor's list narrows it, by words or by level.
        XCTAssertEqual(try rotorHeadings(of: view, filter: "SECOND", listing: true).map(\.label), [labels[1]])
        XCTAssertEqual(try rotorHeadings(of: view, filter: "level 3", listing: true).map(\.label), [labels[2]])
        XCTAssertEqual(try rotorHeadings(of: view, filter: "no such words", listing: true).count, 0)
        // A page without headings has none to give.
        let prose = host(CanvasText.body(CanvasText.sentence(80, seed: 9)), size: CGSize(width: 320, height: 640))
        XCTAssertEqual(try rotorHeadings(of: try XCTUnwrap(prose.canvas.textViews.first)).count, 0)
    }

    func testAPageColumnsRotorStopsAtItsPage() throws {
        let section = try chapter()
        let all = ["A chapter title long enough to take two lines of a narrow page column, heading level 1", "Second level, heading level 2",
                   "Third level on two lines, heading level 3", "Fourth level, heading level 4"]
        let host = host(section.string, size: CGSize(width: 320, height: 560))
        var seen: [String] = [], turns = 0
        repeat {
            let view = try XCTUnwrap(host.canvas.textViews.first)
            let found = try rotorHeadings(of: view, listing: true)
            for heading in found {
                XCTAssertLessThanOrEqual(NSMaxRange(heading.range), view.shownCharacters.length, "\(heading.label) is on the page that gives it")
                XCTAssertEqual(try levels(in: view, heading.range).count, 1)
            }
            seen += found.map(\.label)
            turns += 1
        } while turns < 100 && host.canvas.turnPage(forward: true) == .turned
        XCTAssertGreaterThan(turns, 4, "several pages")
        XCTAssertEqual(seen, all, "each heading on the page that shows it, and nowhere else")
    }

    func testTheScrollViewsRotorGivesTheWholeBooksHeadings() async throws {
        let reader = try SessionCoverageReader(try SessionCoverageBook.chapters())
        readers.append(reader)
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas), view = try XCTUnwrap(canvas.scrollTextView)
        let found = try rotorHeadings(of: view, listing: true)
        XCTAssertEqual(found.map(\.label), ["First Chapter, heading level 1", "Second Chapter, heading level 1", "Third Chapter, heading level 1"])
        let book = try XCTUnwrap(canvas.scrollBook)
        XCTAssertEqual(found.map { book.position(at: $0.range.location).section }, [0, 2, 3], "each in its own chapter, screens apart")
        for heading in found { XCTAssertEqual(try levels(in: view, heading.range), ["1 \(view.plainText(in: heading.range))"]) }
        XCTAssertEqual(try rotorHeadings(of: view, forward: false).map(\.range), found.map(\.range).reversed())
    }
    #endif
}
