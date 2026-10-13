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

    /// Where a move by heading goes when the page or the screen has no more: the book's next
    /// heading, through the chapters page turns reach.
    func testTheBooksNextHeadingIsFoundThroughTheChaptersPageTurnsReach() throws {
        let first = try H.build("<h1>First</h1><p>Words.</p><h2>Second</h2><p>More words.</p>", css: Self.css)
        let aside = try H.build("<h1>In a chapter page turns step over</h1><p>Aside.</p>", css: Self.css)
        let table = try H.build("<h1 class=\"sr\">Hidden over a table</h1><table><tr><td>One</td><td>Two</td></tr></table><p>After.</p>", css: Self.css)
        let last = try H.build("<p>No heading here.</p>", css: Self.css)
        let end = try H.build("<h3>The last</h3>", css: Self.css)
        let host = CanvasHost(FakeCanvasSource([first.string, aside.string, table.string, last.string, nil, end.string],
                                               linear: [true, false, true, true, true, true]), size: CGSize(width: 320, height: 560))
        hosts.append(host)
        func heading(_ section: Int, _ offset: Int, forward: Bool = true) -> ReaderTextPosition? {
            host.canvas.heading(from: ReaderTextPosition(section: section, offset: offset), forward: forward)
        }
        let second = H.range("Second", in: first).location
        XCTAssertEqual(table.string.string.first, "\u{FFFC}", "the third chapter opens with its hidden heading")
        // Within a chapter: the heading a position is inside is neither after nor before it.
        XCTAssertEqual(heading(0, 0), ReaderTextPosition(section: 0, offset: second))
        XCTAssertEqual(heading(0, 2), ReaderTextPosition(section: 0, offset: second))
        XCTAssertNil(heading(0, 2, forward: false))
        XCTAssertEqual(heading(0, 5, forward: false), ReaderTextPosition(section: 0, offset: 0), "from the end of the first heading")
        XCTAssertEqual(heading(0, second + 3, forward: false), ReaderTextPosition(section: 0, offset: 0))
        // On to the next chapter page turns reach, whose heading is hidden; the one between is passed over.
        XCTAssertEqual(heading(0, second), ReaderTextPosition(section: 2, offset: 0))
        XCTAssertEqual(heading(2, 0, forward: false), ReaderTextPosition(section: 0, offset: second))
        // A search that starts in the chapter passed over looks in it, and leaves it either way.
        XCTAssertEqual(heading(1, 5), ReaderTextPosition(section: 2, offset: 0))
        XCTAssertEqual(heading(1, aside.string.length, forward: false), ReaderTextPosition(section: 1, offset: 0))
        XCTAssertEqual(heading(1, 0, forward: false), ReaderTextPosition(section: 0, offset: second))
        // Through a chapter with no heading to one that is not built yet, which ends the search.
        XCTAssertNil(heading(2, 0))
        XCTAssertNil(heading(5, 0, forward: false), "and from past it")
        XCTAssertNil(heading(0, 0, forward: false), "none before the book's first")
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
        XCTAssertEqual(elements[0].accessibilityLabel, "A chapter title long enough to take two lines of the page",
                       "its words, without the break that ends its paragraph: VoiceOver says \"Heading\" straight after them")
        XCTAssertEqual(elements[1].accessibilityLabel, "Plain words follow it.\n", "a line that is no heading is read as before")
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
                    // A heading's label leaves out the break after it; nothing else is left out.
                    let labels: String = elements.map { $0.accessibilityLabel ?? "" }.joined()
                    let shown: String = view.visibleText
                    XCTAssertEqual(labels.filter { $0 != "\n" }, shown.filter { $0 != "\n" })
                    let headingCount: Int = elements.filter { $0.accessibilityTraits.contains(.header) }.count
                    let breaksRead: Int = labels.filter { $0 == "\n" }.count
                    let breaksShown: Int = shown.filter { $0 == "\n" }.count
                    XCTAssertEqual(breaksRead + headingCount, breaksShown, "every paragraph's break is in a line's label or follows a heading")
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
    /// the view's lines when nil), asked as VoiceOver asks when a finger flicks down or up:
    /// twice, from the same item, though the first answer may have turned the page that item
    /// was on (an iPhone 17 Pro simulator and an iPad Air, iOS 27, on 2026-10-12). When the two
    /// answers differ VoiceOver says "Heading not found".
    private func rotorHeading(from element: UIAccessibilityElement?, in view: ReaderTextView, forward: Bool,
                              file: StaticString = #filePath, line: UInt = #line) throws -> UIAccessibilityElement? {
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors?.first { $0.systemRotorType == .heading },
                                  "the lines' container gives VoiceOver its Headings rotor", file: file, line: line)
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = forward ? .next : .previous
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: element ?? view, targetRange: nil)
        let first = rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement
        let second = rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement
        XCTAssertTrue(first === second, "asked again from \(element.map(read) ?? "no line"): \(first.map(read) ?? "none"), then \(second.map(read) ?? "none")",
                      file: file, line: line)
        return first
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
        // The column gives every line of the page the rotor.
        XCTAssertEqual(view.accessibilityCustomRotors?.map(\.systemRotorType), [.heading])
        XCTAssertTrue(elements.allSatisfy { $0.accessibilityCustomRotors == nil })
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

    /// The VoiceOver fixture's own shape, in a real session: a chapter that ends with a heading,
    /// one that opens with a hidden heading above shown words, and one that opens with a hidden
    /// heading over a table, which is hidden labels alone on a line of no height.
    func testTheHeadingsRotorGoesFromChapterToChapterThroughHiddenHeadings() async throws {
        let parked = "style=\"position: absolute; left: -999em\""
        let reader = try SessionCoverageReader(try SessionCoverageBook.epub([
            SessionCoverageBook.Section("body", "<h1>Opening heading</h1>" + SessionCoverageBook.filler(60) + "<h2>Closing heading</h2><p>End.</p>", title: "Body"),
            SessionCoverageBook.Section("labels", "<h1 \(parked)>Parked title heading</h1><p \(parked)>By the parked author.</p><p>Shown opening words.</p>", title: "Labels"),
            SessionCoverageBook.Section("table", "<h1 \(parked)>Parked table heading</h1><table><tr><td>First cell</td><td>Second cell</td></tr></table>"
                + "<p>Shown words after the table.</p>" + SessionCoverageBook.filler(20), title: "Table")]))
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.wait("every chapter built") { reader.session.bookText != nil }
        let canvas = try XCTUnwrap(reader.session.canvas)
        func column() throws -> ReaderTextView { try XCTUnwrap(canvas.textViews.first) }
        var cursor = try XCTUnwrap(try XCTUnwrap(column().accessibilityElements as? [UIAccessibilityElement]).first)
        XCTAssertEqual(read(cursor), "heading 1 Opening heading")
        var heard: [String] = [], sections: [Int] = []
        while let next = try rotorHeading(from: cursor, in: try XCTUnwrap(cursor.accessibilityContainer as? ReaderTextView), forward: true) {
            heard.append(read(next))
            sections.append(try XCTUnwrap(try column().placement.section))
            XCTAssertTrue(try XCTUnwrap(next.accessibilityContainer as? ReaderTextView) === (try column()))
            XCTAssertFalse(next.accessibilityFrameInContainerSpace.isEmpty, read(next))
            cursor = next
            XCTAssertLessThan(heard.count, 10)
        }
        XCTAssertEqual(heard, ["heading 2 Closing heading", "heading 1 Parked title heading", "heading 1 Parked table heading"])
        XCTAssertEqual(sections, [0, 1, 2])
        var back: [String] = []
        while let previous = try rotorHeading(from: cursor, in: try XCTUnwrap(cursor.accessibilityContainer as? ReaderTextView), forward: false) {
            back.append(read(previous))
            cursor = previous
            XCTAssertLessThan(back.count, 10)
        }
        XCTAssertEqual(back, ["heading 1 Parked title heading", "heading 2 Closing heading", "heading 1 Opening heading"])
        XCTAssertEqual(try column().placement.section, 0)
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
        let opening = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        var cursor = try XCTUnwrap(opening.first)
        XCTAssertEqual(read(cursor), "heading 1 First Chapter")
        // The scroll view gives every line it lists the rotor, as a page column does.
        XCTAssertEqual(view.accessibilityCustomRotors?.map(\.systemRotorType), [.heading])
        XCTAssertTrue(opening.allSatisfy { $0.accessibilityCustomRotors == nil })
        // From a line that is no heading, many lines into the first chapter's opening screen.
        XCTAssertGreaterThan(opening.count, 3)
        XCTAssertTrue(try rotorHeading(from: opening[2], in: view, forward: false) === cursor, "the heading above it")
        // Each chapter's heading is many screens from the one before.
        var heard: [String] = [], sections: [Int] = []
        while let next = try rotorHeading(from: cursor, in: view, forward: true) {
            let area = canvas.scrollVisibleContainerRect.offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y).insetBy(dx: -1_000, dy: -1)
            XCTAssertTrue(area.contains(next.accessibilityFrameInContainerSpace), "\(read(next)) is on screen at \(next.accessibilityFrameInContainerSpace) in \(area)")
            XCTAssertNotEqual(view.index(ofAccessibilityElement: next), NSNotFound)
            // The lines around the place the cursor left are still listed before it.
            let top = try XCTUnwrap(view.line(containing: try XCTUnwrap(canvas.scrollSpokenCharacters()).location))
            XCTAssertEqual(view.plainText(in: top.range), (next.accessibilityLabel ?? "") + "\n", "at the top of the screen")
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

    // MARK: A page column's rotor and the rest of the book

    /// A heading as a page column's rotor gives it: what the list calls it, and its column and
    /// characters there when it begins on the page or spread. One on another page has a token
    /// and no column, and the rotor loads it when VoiceOver moves to it.
    private struct RotorHeading {
        var label: String
        var column: ReaderTextView?
        var range: NSRange
        var token: (any NSAccessibilityLoadingToken)?
        var item: NSAccessibilityCustomRotor.ItemResult
    }

    private func headingRotor(of view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> NSAccessibilityCustomRotor {
        try XCTUnwrap(view.accessibilityCustomRotors().first { $0.type == .heading }, "the column has a Headings rotor", file: file, line: line)
    }

    /// The heading `view`'s rotor gives after `item`, or before it.
    private func rotorHeading(of view: ReaderTextView, from item: NSAccessibilityCustomRotor.ItemResult?, forward: Bool = true,
                              filter: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> RotorHeading? {
        let rotor = try headingRotor(of: view, file: file, line: line)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.currentItem = item
        parameters.searchDirection = forward ? .next : .previous
        parameters.filterString = filter
        guard let result = try XCTUnwrap(rotor.itemSearchDelegate, file: file, line: line).rotor(rotor, resultFor: parameters) else { return nil }
        let column = result.targetElement as? ReaderTextView
        XCTAssertNotEqual(column == nil, result.itemLoadingToken == nil, "\(result.customLabel ?? "") is a column or a token, never both", file: file, line: line)
        return RotorHeading(label: result.customLabel ?? "", column: column, range: result.targetRange, token: result.itemLoadingToken, item: result)
    }

    /// The item VoiceOver asks from with its cursor on `range` of a column. At the first
    /// character and none of it, its cursor rests on the column with no place in it yet.
    private func place(_ range: NSRange, in view: ReaderTextView) -> NSAccessibilityCustomRotor.ItemResult {
        let item = NSAccessibilityCustomRotor.ItemResult(targetElement: view)
        item.targetRange = range
        return item
    }

    private static let resting = NSRange(location: 0, length: 0)

    /// The item VoiceOver asks from once it has been given `heading` (macOS 27.0.1): the
    /// column and characters of one on the page, and for one on another page its token and
    /// the range it came with, with no element and no label.
    private func given(_ heading: RotorHeading) -> NSAccessibilityCustomRotor.ItemResult {
        if let column = heading.column { return place(heading.range, in: column) }
        let item = NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: heading.token ?? ("" as NSString), customLabel: "")
        item.targetRange = heading.range
        return item
    }

    /// The rotor's list as VoiceOver was seen to build it when the rotor opens (macOS 27.0.1):
    /// it asks for the item after one that is nowhere, with no element and the first character
    /// and none of it, and then for the one after each item it is given.
    private func listedHeadings(by view: ReaderTextView, forward: Bool = true, filter: String = "",
                                file: StaticString = #filePath, line: UInt = #line) throws -> [RotorHeading] {
        // An item can only be made with an element or a token: this token names no place.
        let nowhere = NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: "nowhere" as NSString, customLabel: "")
        nowhere.targetRange = Self.resting
        XCTAssertNil(nowhere.targetElement, file: file, line: line)
        var next = try rotorHeading(of: view, from: nowhere, forward: forward, filter: filter, file: file, line: line)
        var found: [RotorHeading] = []
        while let heading = next, found.count < 200 {
            found.append(heading)
            next = try rotorHeading(of: view, from: given(heading), forward: forward, filter: filter, file: file, line: line)
        }
        // At each move along the list it asks once more from the last item.
        if forward, filter.isEmpty, let last = found.last {
            XCTAssertNil(try rotorHeading(of: view, from: given(last)), "none past the last", file: file, line: line)
        }
        return found
    }

    /// Where VoiceOver is put when it moves to a heading: the column and characters the rotor
    /// gave, or for a heading on another page what the rotor's loading delegate gives for its
    /// token, the element first and then its range.
    private func move(to heading: RotorHeading, givenBy view: ReaderTextView,
                      file: StaticString = #filePath, line: UInt = #line) throws -> (column: ReaderTextView, range: NSRange)? {
        if let column = heading.column { return (column, heading.range) }
        let loading = try XCTUnwrap(try headingRotor(of: view).itemLoadingDelegate, "the rotor loads the headings it gives as tokens", file: file, line: line)
        let token = try XCTUnwrap(heading.token, file: file, line: line)
        guard let element = loading.accessibilityElement(withToken: token) else { return nil }
        let column = try XCTUnwrap(element as? ReaderTextView, file: file, line: line)
        return (column, try XCTUnwrap(loading.accessibilityRangeInTargetElement?(withToken: token), file: file, line: line))
    }

    /// A book of five chapters: one of several pages with four headings, one that page turns
    /// step over, one that opens with a hidden heading over a table, one without a heading and
    /// one with two headings.
    private func book() throws -> (sections: [SectionText], linear: [Bool], labels: [String]) {
        let after = "<h1>The chapter after</h1><p>\(CanvasText.sentence(120, seed: 7))</p><h2>Its last heading</h2><p>End.</p>"
        return ([try chapter(), try H.build("<h1>In a chapter page turns step over</h1><p>Aside.</p>", css: Self.css),
                 try H.build("<h1 class=\"sr\">Hidden over a table</h1><table><tr><td>One</td><td>Two</td></tr></table><p>After.</p>", css: Self.css),
                 try H.build("<p>No heading here.</p>", css: Self.css), try H.build(after, css: Self.css)],
                [true, false, true, true, true],
                ["A chapter title long enough to take two lines of a narrow page column, heading level 1", "Second level, heading level 2",
                 "Third level on two lines, heading level 3", "Fourth level, heading level 4", "Hidden over a table, heading level 1",
                 "The chapter after, heading level 1", "Its last heading, heading level 2"])
    }

    /// The section and first character of the page each column shows.
    private func pages(of host: CanvasHost) -> [ReaderTextPosition] {
        host.canvas.textViews.map { ReaderTextPosition(section: $0.placement.section ?? -1, offset: $0.placement.offset) }
    }

    func testAPageColumnsRotorListsTheWholeBooksHeadingsFromAPageInTheMiddle() throws {
        let (sections, linear, labels) = try book()
        let host = CanvasHost(FakeCanvasSource(sections.map(\.string), linear: linear), size: CGSize(width: 320, height: 560))
        hosts.append(host)
        // The page of the first chapter's third heading: headings before it and after it in the
        // chapter, and more in the chapters after.
        let third = H.range("Third level", in: sections[0])
        host.canvas.show(ReaderTextPosition(section: 0, offset: third.location + 3), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let page = NSRange(location: view.placement.offset, length: view.placement.visibleLength)
        XCTAssertGreaterThan(page.location, 0, "a page in the middle of the chapter")
        XCTAssertLessThan(NSMaxRange(page), sections[0].string.length)
        let shown = host.recorder.shown.count, standing = pages(of: host)
        let listed = try listedHeadings(by: view)
        XCTAssertEqual(listed.map(\.label), labels, "the whole book's, but for the chapter page turns step over")
        XCTAssertEqual(try listedHeadings(by: view, forward: false).map(\.label), labels.reversed())
        // VoiceOver walks the whole list when its rotor opens: nothing is shown for it.
        XCTAssertEqual(host.recorder.shown.count, shown)
        XCTAssertEqual(pages(of: host), standing)
        // A heading that begins on the page is its column and its characters there, with its
        // level in the text; any other is a token, with no element to ask anything of.
        let starts = sections[0].string.readerHeadings().map(\.range.location)
        XCTAssertEqual(listed.prefix(4).map { $0.column != nil }, starts.map { NSLocationInRange($0, page) })
        XCTAssertTrue(listed[2].column === view, "the third heading is on this page")
        XCTAssertEqual(listed[2].range, NSRange(location: third.location - page.location, length: sections[0].string.readerHeadings()[2].range.length))
        XCTAssertEqual(try levels(in: view, listed[2].range), ["3 Third level\u{2028}on two lines"])
        XCTAssertTrue(listed.dropFirst(4).allSatisfy { $0.column == nil && $0.token != nil }, "none of another chapter's is on the page")
        XCTAssertEqual(Set(listed.compactMap { $0.token as? String }).count, listed.filter { $0.token != nil }.count, "each token names one heading")
        // A token comes with a range, which VoiceOver needs before it calls the row by its
        // label: the heading's characters in its own chapter. Its words are the label's.
        let everyHeading = sections.enumerated().flatMap { index, section in linear[index] ? section.string.readerHeadings().map(\.range) : [] }
        XCTAssertEqual(listed.filter { $0.token != nil }.map(\.range), zip(listed, everyHeading).filter { $0.0.token != nil }.map(\.1))
        XCTAssertTrue(listed.allSatisfy { $0.range.location != NSNotFound && $0.range.length > 0 && !$0.label.isEmpty })
        // With its cursor resting on the column, VoiceOver asks from the first character and
        // none of it: its move to the next heading, and the heading its rotor's list opens on.
        // That is the next heading from the top of this page, not the book's first.
        let onPage = try XCTUnwrap(starts.firstIndex { $0 >= page.location })
        XCTAssertGreaterThan(onPage, 0)
        let resting = try XCTUnwrap(try rotorHeading(of: view, from: place(Self.resting, in: view)))
        XCTAssertEqual(resting.label, labels[onPage], "the first heading on this page")
        XCTAssertTrue(resting.column === view)
        XCTAssertEqual(try rotorHeading(of: view, from: place(NSRange(location: NSNotFound, length: 0), in: view))?.label, labels[onPage])
        // Going back it stands after the page's last character.
        let ends = sections[0].string.readerHeadings().map { NSMaxRange($0.range) }
        XCTAssertEqual(try rotorHeading(of: view, from: place(Self.resting, in: view), forward: false)?.label,
                       labels[try XCTUnwrap(ends.lastIndex { $0 <= NSMaxRange(page) })])
        XCTAssertEqual(pages(of: host), standing)
        // What is typed in the rotor's list narrows the whole book's, by words or by level.
        XCTAssertEqual(try listedHeadings(by: view, filter: "LAST").map(\.label), [labels[6]])
        XCTAssertEqual(try listedHeadings(by: view, filter: "level 1").map(\.label), [labels[0], labels[4], labels[5]])
        XCTAssertEqual(try listedHeadings(by: view, filter: "no such words").count, 0)
        XCTAssertEqual(pages(of: host), standing)

        // Chosen from the list, a heading on another page is loaded: the reader turns to its
        // page, and VoiceOver is given the column that now shows it and its characters there.
        let last = try XCTUnwrap(try move(to: listed[6], givenBy: view))
        XCTAssertTrue(last.column === host.canvas.textViews.first)
        XCTAssertEqual(last.column.placement.section, 4)
        XCTAssertEqual(last.column.plainText(in: last.range), "Its last heading")
        XCTAssertEqual(try levels(in: last.column, last.range), ["2 Its last heading"])
        XCTAssertLessThanOrEqual(NSMaxRange(last.range), last.column.shownCharacters.length)
        XCTAssertEqual(host.recorder.shown.count, shown + 1, "one page turn")
        XCTAssertEqual(host.recorder.shown.last?.range.start.section, 4, "the reader reports the place it was taken to")
        // Loaded again, as a client may: the same answer, and nothing shown again.
        let again = try XCTUnwrap(try move(to: listed[6], givenBy: view))
        XCTAssertTrue(again.column === last.column)
        XCTAssertEqual(again.range, last.range)
        XCTAssertEqual(host.recorder.shown.count, shown + 1)
        // The list from there is the same list, with this chapter's headings on the page.
        let later = try listedHeadings(by: last.column)
        XCTAssertEqual(later.map(\.label), labels)
        XCTAssertEqual(later.map { $0.column != nil }, [false, false, false, false, false] + sections[4].string.readerHeadings().map {
            NSLocationInRange($0.range.location, NSRange(location: last.column.placement.offset, length: last.column.placement.visibleLength))
        })
        // Back to a hidden heading, which is the one character of its label, and to the book's first.
        let hidden = try XCTUnwrap(try move(to: later[4], givenBy: last.column))
        XCTAssertEqual(hidden.column.placement.section, 2)
        XCTAssertEqual(hidden.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(hidden.column.plainText(in: hidden.range), "Hidden over a table")
        XCTAssertEqual(try levels(in: hidden.column, hidden.range), ["1 Hidden over a table"])
        let first = try XCTUnwrap(try move(to: later[0], givenBy: hidden.column))
        XCTAssertEqual(pages(of: host), [ReaderTextPosition(section: 0, offset: 0)])
        XCTAssertEqual(first.range, sections[0].string.readerHeadings()[0].range)
    }

    func testAMoveByHeadingGoesOnPastThePageThroughTheBook() throws {
        let (sections, linear, labels) = try book()
        let host = CanvasHost(FakeCanvasSource(sections.map(\.string), linear: linear), size: CGSize(width: 320, height: 560))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.textViews.first)
        // VoiceOver's move to the next heading asks from the line under its cursor, and then
        // from the characters it was last given.
        var cursor = (column: view, range: try XCTUnwrap(view.pageAccessibilityLines.first).range)
        var heard: [String] = [], places: [ReaderTextPosition] = [], turned: [Bool] = []
        while let next = try rotorHeading(of: cursor.column, from: place(cursor.range, in: cursor.column)) {
            let before = pages(of: host)
            // Asked again before it moves, VoiceOver is given the same heading and nothing is shown.
            XCTAssertEqual(try rotorHeading(of: cursor.column, from: place(cursor.range, in: cursor.column))?.label, next.label)
            XCTAssertEqual(pages(of: host), before, "the search shows nothing")
            cursor = try XCTUnwrap(try move(to: next, givenBy: cursor.column), next.label)
            XCTAssertTrue(host.canvas.textViews.contains { $0 === cursor.column }, "\(next.label) is in a column on screen")
            XCTAssertLessThanOrEqual(NSMaxRange(cursor.range), cursor.column.shownCharacters.length)
            XCTAssertEqual(next.column == nil, pages(of: host) != before, "the page turns for a heading that was not on it, and only then")
            heard.append(next.label)
            places.append(try XCTUnwrap(host.canvas.position(at: cursor.range.location, in: cursor.column)))
            turned.append(next.column == nil)
            // From the token itself, as from the characters it was loaded at.
            XCTAssertEqual(try rotorHeading(of: cursor.column, from: given(next))?.label,
                           try rotorHeading(of: cursor.column, from: place(cursor.range, in: cursor.column))?.label)
            XCTAssertLessThan(heard.count, 20)
        }
        XCTAssertEqual(heard, Array(labels.dropFirst()), "each heading of the book after the first, and none past the last")
        XCTAssertEqual(places.map(\.section), [0, 0, 0, 2, 4, 4])
        XCTAssertEqual(places, places.sorted(), "onward through the book")
        XCTAssertTrue(turned[3] && turned[4], "a heading of another chapter is never on the page")
        XCTAssertEqual(host.recorder.shown.last?.range.start.section, 4)
        // And back, for a client that asks for the one before.
        var back: [String] = []
        while let previous = try rotorHeading(of: cursor.column, from: place(cursor.range, in: cursor.column), forward: false) {
            cursor = try XCTUnwrap(try move(to: previous, givenBy: cursor.column), previous.label)
            back.append(previous.label)
            XCTAssertLessThan(back.count, 20)
        }
        XCTAssertEqual(back, Array(labels.dropLast().reversed()))
        XCTAssertEqual(pages(of: host), [ReaderTextPosition(section: 0, offset: 0)])
        // From a line that is no heading, on the first page of the chapter that holds none.
        let starts = sections[0].string.readerHeadings().map(\.range.location)
        var page = NSRange(location: 0, length: 0), turns = 0
        repeat {
            XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
            page = NSRange(location: try XCTUnwrap(host.canvas.textViews.first).placement.offset,
                           length: try XCTUnwrap(host.canvas.textViews.first).placement.visibleLength)
            turns += 1
        } while turns < 50 && starts.contains { NSLocationInRange($0, page) }
        let middle = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(middle.placement.section, 0)
        XCTAssertTrue(try listedHeadings(by: middle).allSatisfy { $0.column == nil }, "this page holds no heading")
        let line = try XCTUnwrap(middle.pageAccessibilityLines.dropFirst(2).first).range
        let after = try XCTUnwrap(starts.firstIndex { $0 >= NSMaxRange(page) }), standing = pages(of: host)
        XCTAssertEqual(try rotorHeading(of: middle, from: place(line, in: middle))?.label, labels[after])
        XCTAssertEqual(try rotorHeading(of: middle, from: place(line, in: middle), forward: false)?.label, labels[after - 1])
        // And with the cursor resting on the column, which is how VoiceOver comes to a page
        // it has not read: the next heading of the book from here, on a later page, and
        // going back the last one before this page. Neither is the book's first or last.
        let onward = try XCTUnwrap(try rotorHeading(of: middle, from: place(Self.resting, in: middle)))
        XCTAssertEqual(onward.label, labels[after])
        XCTAssertNil(onward.column)
        XCTAssertEqual(try rotorHeading(of: middle, from: place(Self.resting, in: middle), forward: false)?.label, labels[after - 1])
        XCTAssertEqual(pages(of: host), standing)
        // VoiceOver has the element first and then its range: the request for a range shows nothing.
        let loading = try XCTUnwrap(try headingRotor(of: middle).itemLoadingDelegate)
        XCTAssertEqual(loading.accessibilityRangeInTargetElement?(withToken: try XCTUnwrap(onward.token)).location, NSNotFound)
        XCTAssertEqual(pages(of: host), standing)
        let arrived = try XCTUnwrap(try move(to: onward, givenBy: middle))
        XCTAssertEqual(host.canvas.position(at: arrived.range.location, in: arrived.column), ReaderTextPosition(section: 0, offset: starts[after]))
    }

    func testAPageColumnsRotorEndsAtAChapterThatIsNotBuiltYet() throws {
        let (sections, _, labels) = try book()
        let late = try H.build("<h1>Built late</h1><p>Words.</p>", css: Self.css)
        let end = try H.build("<h3>Past the gap</h3><p>Words.</p><h4>The book's last</h4>", css: Self.css)
        let source = FakeCanvasSource([sections[0].string, sections[4].string, nil, end.string])
        let host = CanvasHost(source, size: CGSize(width: 320, height: 560))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        host.layOut()
        let built = Array(labels.prefix(4)) + Array(labels.suffix(2)), past = ["Past the gap, heading level 3", "The book's last, heading level 4"]
        // The list holds the chapters built so far around the page, and ends at the first that is not.
        var view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(try listedHeadings(by: view).map(\.label), built)
        XCTAssertEqual(try listedHeadings(by: view, forward: false).map(\.label), built.reversed())
        // A move from the last heading before it finds none, and the reader stays.
        let last = try XCTUnwrap(try listedHeadings(by: view).last)
        let standing = pages(of: host)
        XCTAssertNil(try rotorHeading(of: view, from: given(last)))
        XCTAssertEqual(pages(of: host), standing)
        // Past it, the list is of the chapters built on that side.
        host.canvas.show(ReaderTextPosition(section: 3, offset: 0), selecting: nil)
        host.layOut()
        view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(try listedHeadings(by: view).map(\.label), past)
        XCTAssertEqual(try listedHeadings(by: view, forward: false).map(\.label), past.reversed())
        XCTAssertNil(try rotorHeading(of: view, from: place(NSRange(location: 0, length: 12), in: view), forward: false))
        // A token kept from before for a place that has no heading, or no chapter, loads nothing.
        let loading = try XCTUnwrap(try headingRotor(of: view).itemLoadingDelegate)
        for stale in ["2:0", "3:5", "9:0", "-1:0", "nowhere", "1"] {
            XCTAssertNil(loading.accessibilityElement(withToken: stale as NSString), stale)
            XCTAssertEqual(loading.accessibilityRangeInTargetElement?(withToken: stale as NSString).location, NSNotFound, stale)
        }
        XCTAssertEqual(pages(of: host), [ReaderTextPosition(section: 3, offset: 0)])
        // Once it is built the list is the whole book's, from either side.
        source.sections[2] = late.string
        let whole = built + ["Built late, heading level 1"] + past
        XCTAssertEqual(try listedHeadings(by: view).map(\.label), whole)
        let gap = try XCTUnwrap(try move(to: try listedHeadings(by: view)[6], givenBy: view))
        XCTAssertEqual(gap.column.placement.section, 2)
        XCTAssertEqual(gap.column.plainText(in: gap.range), "Built late")
        XCTAssertEqual(try listedHeadings(by: gap.column).map(\.label), whole)
        // Built again, as for a new text size, a chapter is another text: its headings are
        // found in that one, and a token for a place that is a heading no longer loads nothing.
        let moved = try XCTUnwrap(try listedHeadings(by: gap.column).last?.token)
        source.sections[3] = try H.build("<p>Words first.</p><h3>Past the gap, built again</h3>", css: Self.css).string
        XCTAssertEqual(try listedHeadings(by: gap.column).map(\.label), built + ["Built late, heading level 1", "Past the gap, built again, heading level 3"])
        XCTAssertNil(try XCTUnwrap(try headingRotor(of: gap.column).itemLoadingDelegate).accessibilityElement(withToken: moved))
        XCTAssertEqual(gap.column.placement.section, 2)
    }

    func testTheRotorOfAChapterPageTurnsStepOverListsItInItsPlace() throws {
        let (sections, linear, labels) = try book()
        let host = CanvasHost(FakeCanvasSource(sections.map(\.string), linear: linear), size: CGSize(width: 320, height: 560))
        hosts.append(host)
        // Reached by a link, the chapter is where the reader is: its heading is in the list
        // while it is on screen, between the chapters either side.
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let aside = "In a chapter page turns step over, heading level 1"
        let listed = try listedHeadings(by: view)
        XCTAssertEqual(listed.map(\.label), Array(labels.prefix(4)) + [aside] + Array(labels.suffix(3)))
        XCTAssertTrue(listed[4].column === view)
        XCTAssertEqual(try rotorHeading(of: view, from: place(listed[4].range, in: view))?.label, labels[4])
        XCTAssertEqual(try rotorHeading(of: view, from: place(listed[4].range, in: view), forward: false)?.label, labels[3])
        // Left for another chapter, it is passed over again.
        let next = try XCTUnwrap(try move(to: listed[5], givenBy: view))
        XCTAssertEqual(next.column.placement.section, 2)
        XCTAssertEqual(try listedHeadings(by: next.column).map(\.label), labels)
    }

    func testEitherColumnOfASpreadGivesTheBooksHeadingsEachInItsColumn() throws {
        // Each heading opens a page, so the first spread holds two and the second the other two.
        let css = Self.css + "h1 { break-before: page } "
        let section = try H.build((1...4).map { "<h1>Heading \($0)</h1><p>Words of part \($0).</p>" }.joined(), css: css)
        let after = try H.build("<h2>In the chapter after</h2><p>End.</p>", css: Self.css)
        let host = CanvasHost(FakeCanvasSource([section.string, after.string]), size: CGSize(width: 1100, height: 420))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let columns = host.canvas.textViews
        XCTAssertEqual(columns.count, 2, "a spread of two columns")
        let labels = (1...4).map { "Heading \($0), heading level 1" } + ["In the chapter after, heading level 2"]
        let starts = section.string.readerHeadings().map(\.range)
        for asked in columns {
            let listed = try listedHeadings(by: asked)
            XCTAssertEqual(listed.map(\.label), labels)
            // The spread's two are given in the column that shows each, whichever column is asked.
            XCTAssertTrue(listed[0].column === columns[0])
            XCTAssertTrue(listed[1].column === columns[1])
            XCTAssertEqual(listed[0].range, starts[0])
            XCTAssertEqual(listed[1].range, NSRange(location: 0, length: starts[1].length), "its characters in the right column's own text")
            XCTAssertEqual(try levels(in: columns[1], listed[1].range), ["1 Heading 2"])
            XCTAssertTrue(listed.dropFirst(2).allSatisfy { $0.column == nil && $0.token != nil })
            XCTAssertEqual(try listedHeadings(by: asked, forward: false).map(\.label), labels.reversed())
        }
        // With VoiceOver's cursor in the left column, the next heading is in the right one, and
        // from there the one before is back in the left: no page is turned for either.
        let standing = pages(of: host)
        let words = (columns[0].contentStorage.textStorage?.string as NSString?)?.range(of: "Words of part 1") ?? NSRange(location: NSNotFound, length: 0)
        let right = try XCTUnwrap(try rotorHeading(of: columns[0], from: place(words, in: columns[0])))
        XCTAssertTrue(right.column === columns[1])
        XCTAssertEqual(right.label, labels[1])
        let left = try XCTUnwrap(try rotorHeading(of: columns[1], from: place(right.range, in: columns[1]), forward: false))
        XCTAssertTrue(left.column === columns[0])
        XCTAssertEqual(left.label, labels[0])
        XCTAssertEqual(pages(of: host), standing)
        // A cursor resting on a column stands at the top of that column's page.
        XCTAssertEqual(try rotorHeading(of: columns[0], from: place(Self.resting, in: columns[0]))?.label, labels[0])
        XCTAssertEqual(try rotorHeading(of: columns[1], from: place(Self.resting, in: columns[1]))?.label, labels[1])
        XCTAssertEqual(try rotorHeading(of: columns[0], from: place(Self.resting, in: columns[0]), forward: false)?.label, labels[0])
        XCTAssertEqual(try rotorHeading(of: columns[1], from: place(Self.resting, in: columns[1]), forward: false)?.label, labels[1])
        // A cursor in the right column stands after everything in the left: the same range
        // means another place in the book there.
        XCTAssertEqual(try rotorHeading(of: columns[1], from: place(NSRange(location: 3, length: 4), in: columns[1]))?.label, labels[2])
        XCTAssertEqual(try rotorHeading(of: columns[0], from: place(NSRange(location: 3, length: 4), in: columns[0]))?.label, labels[1])
        // The fourth heading is in the right column of the next spread: the reader turns to
        // it, and VoiceOver is given that column.
        let listed = try listedHeadings(by: columns[0])
        let fourth = try XCTUnwrap(try move(to: listed[3], givenBy: columns[0]))
        XCTAssertEqual(pages(of: host), [ReaderTextPosition(section: 0, offset: starts[2].location), ReaderTextPosition(section: 0, offset: starts[3].location)])
        XCTAssertTrue(fourth.column === host.canvas.textViews[1])
        XCTAssertEqual(fourth.column.plainText(in: fourth.range), "Heading 4")
        let turned = try listedHeadings(by: fourth.column)
        XCTAssertEqual(turned.map(\.label), labels)
        XCTAssertEqual(turned.map { $0.column.flatMap { column in host.canvas.textViews.firstIndex { $0 === column } } }, [nil, nil, 0, 1, nil])
        // On to the next chapter, whose one page leaves the right column empty, and back.
        let last = try XCTUnwrap(try move(to: turned[4], givenBy: fourth.column))
        XCTAssertEqual(pages(of: host), [ReaderTextPosition(section: 1, offset: 0)])
        XCTAssertTrue(last.column === host.canvas.textViews[0])
        let back = try XCTUnwrap(try rotorHeading(of: last.column, from: place(last.range, in: last.column), forward: false))
        XCTAssertEqual(back.label, labels[3])
        XCTAssertNil(back.column, "it is on the spread before")
        XCTAssertTrue(try XCTUnwrap(try move(to: back, givenBy: last.column)).column === host.canvas.textViews[1])
    }

    func testAHeadingThatRunsOntoLaterPagesIsListedOnceWhereItBegins() throws {
        // A heading too long for a page: it begins on one and ends pages later.
        let words = (1...140).map { "Word\($0)" }.joined(separator: " ")
        let section = try H.build("<p>Opening words.</p><h1>\(words)</h1><p>\(CanvasText.sentence(60, seed: 4))</p><h2>The one after</h2><p>End.</p>",
                                  css: Self.css)
        let heading = section.string.readerHeadings()[0].range
        let host = host(section.string, size: CGSize(width: 320, height: 560))
        host.canvas.show(ReaderTextPosition(section: 0, offset: heading.location), selecting: nil)
        host.layOut()
        let first = try XCTUnwrap(host.canvas.textViews.first)
        let beginning = pages(of: host)
        let shownEnd = first.placement.offset + first.placement.visibleLength
        XCTAssertLessThan(shownEnd, NSMaxRange(heading), "the heading must run past its first page for this to show anything")
        // On the page where it begins it is the column and the part of it there, by all its words.
        let labels = ["\(words), heading level 1", "The one after, heading level 2"]
        let listed = try listedHeadings(by: first)
        XCTAssertEqual(listed.map(\.label), labels)
        XCTAssertTrue(listed[0].column === first)
        XCTAssertEqual(listed[0].range, NSRange(location: heading.location - first.placement.offset, length: shownEnd - heading.location))
        // On a page it runs onto it is the same one item, a token for where it begins.
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        let second = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertTrue(heading.location < second.placement.offset && second.placement.offset + second.placement.visibleLength < NSMaxRange(heading),
                      "this page holds the heading's middle and nothing else")
        let onward = try listedHeadings(by: second)
        XCTAssertEqual(onward.map(\.label), labels)
        XCTAssertTrue(onward.allSatisfy { $0.column == nil })
        // From this page the next heading is the one after it, and there is none before:
        // the heading a cursor is inside is neither.
        XCTAssertEqual(try rotorHeading(of: second, from: place(Self.resting, in: second))?.label, labels[1])
        XCTAssertEqual(try rotorHeading(of: second, from: place(NSRange(location: 4, length: 10), in: second))?.label, labels[1])
        XCTAssertNil(try rotorHeading(of: second, from: place(NSRange(location: 4, length: 10), in: second), forward: false))
        XCTAssertNil(try rotorHeading(of: second, from: place(Self.resting, in: second), forward: false))
        // Chosen from the list, it turns back to the page where it begins.
        let back = try XCTUnwrap(try move(to: onward[0], givenBy: second))
        XCTAssertEqual(pages(of: host), beginning)
        XCTAssertEqual(back.range, listed[0].range)
        XCTAssertEqual(try levels(in: back.column, back.range).count, 1)
    }

    func testATokenLoadsNothingOnceTheReaderHasLeftPaging() throws {
        let (sections, linear, _) = try book()
        let host = CanvasHost(FakeCanvasSource(sections.map(\.string), linear: linear), size: CGSize(width: 320, height: 560))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let column = try XCTUnwrap(host.canvas.textViews.first)
        let token = try XCTUnwrap(try XCTUnwrap(try listedHeadings(by: column).last).token)
        let loading = try XCTUnwrap(try headingRotor(of: column).itemLoadingDelegate)
        // The reader is changed to continuous scroll with the rotor's list still open.
        host.canvas.configuration.flow = .scrolled
        host.layOut()
        let scroll = try XCTUnwrap(host.canvas.scrollTextView)
        XCTAssertNil(loading.accessibilityElement(withToken: token), "the column is the canvas's no longer")
        XCTAssertEqual(loading.accessibilityRangeInTargetElement?(withToken: token).location, NSNotFound)
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0), "and the reader stays where it is")
        // The scroll view gives every heading as characters of its own text, and loads none.
        XCTAssertNil(try headingRotor(of: scroll).itemLoadingDelegate)
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

    /// The elements of the links with characters in `range` of the view's text, in order.
    private func links(in view: ReaderTextView, _ range: NSRange) throws -> [ReaderLinkAccessibilityElement] {
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: range))
        var found: [ReaderLinkAccessibilityElement] = []
        rich.enumerateAttribute(.accessibilityLink, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            if let link = value as? ReaderLinkAccessibilityElement { found.append(link) }
        }
        return found
    }

    /// The item VoiceOver asks from once when its rotor opens with its cursor on a link (macOS
    /// 27.0.1): the link's element, at the first character and none of it. AppKit hands the
    /// search whatever element the client names, and `NSAccessibilityElement` does not declare
    /// the protocol an item's initializer takes, hence the cast.
    private func resting(on link: ReaderLinkAccessibilityElement) -> NSAccessibilityCustomRotor.ItemResult {
        let item = NSAccessibilityCustomRotor.ItemResult(targetElement: unsafeBitCast(link, to: (any NSAccessibilityElementProtocol).self))
        item.targetRange = Self.resting
        return item
    }

    /// With its cursor on a link VoiceOver's rotor still has the text's Headings list: it asks
    /// the text for its rotors as well as the link, which has none. Having walked the list it
    /// asks once more, from the link's element. A link's element is no place in the text, and
    /// the search takes it as it takes a cursor resting on the column: at the top of the page.
    /// Answered with no item where headings were listed, VoiceOver opened the list with no
    /// row chosen and Return did nothing.
    func testAPageColumnsRotorAskedFromALinkStandsAtTheTopOfItsPage() throws {
        let before = try H.build("<h1>The chapter before</h1><p>Words.</p>", css: Self.css)
        let section = try H.build("""
            <h1>First title</h1><p>Words with <a href="two.xhtml">a link before</a> the rest.</p>\
            <h2>Second <a href="two.xhtml">linked</a> part</h2><p><a class="sr" href="three.xhtml">Hidden link</a>Words under it.</p>\
            <h3>Third part</h3><p>Last words and <a href="four.xhtml">a last link</a>.</p>
            """, css: Self.css)
        let after = try H.build("<h1>The chapter after</h1><p>End.</p>", css: Self.css)
        let host = CanvasHost(FakeCanvasSource([before.string, section.string, after.string]), size: CGSize(width: 320, height: 640))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(view.shownCharacters.length, section.string.length, "the whole chapter is on the page")
        XCTAssertEqual(try listedHeadings(by: view).map(\.label), [
            "The chapter before, heading level 1", "First title, heading level 1", "Second linked part, heading level 2",
            "Third part, heading level 3", "The chapter after, heading level 1"])
        let found = try links(in: view, view.shownCharacters)
        XCTAssertEqual(found.map { $0.accessibilityTitle() ?? "" }, ["a link before", "linked", "Hidden link", "a last link"])
        let shown = host.recorder.shown.count
        for link in found {
            let name = link.accessibilityTitle() ?? ""
            XCTAssertTrue(link.accessibilityCustomRotors().isEmpty, "the list is the text's, which VoiceOver asks too")
            let next = try XCTUnwrap(try rotorHeading(of: view, from: resting(on: link)), name)
            XCTAssertEqual(next.label, "First title, heading level 1", "\(name): the heading that opens the page, not the book's first")
            XCTAssertTrue(next.column === view, name)
            XCTAssertEqual(try rotorHeading(of: view, from: resting(on: link), forward: false)?.label, "Third part, heading level 3", name)
            // As from the column itself with VoiceOver's cursor at rest on it.
            XCTAssertEqual(next.label, try rotorHeading(of: view, from: place(Self.resting, in: view))?.label, name)
        }
        XCTAssertEqual(host.recorder.shown.count, shown, "nothing is shown for a question")
    }

    private func heading(of view: ReaderTextView, from link: ReaderLinkAccessibilityElement, forward: Bool) throws -> String? {
        let result = try rotorHeading(of: view, from: resting(on: link), forward: forward)
        XCTAssertTrue(result == nil || result?.column === view)
        return result?.label
    }

    /// Three chapters in continuous scroll, each some screens long: a link under the first
    /// heading, one deep in the second chapter before a heading of the second level, and one
    /// at the end of the book.
    private func scrolledChapters() throws -> (host: CanvasHost, view: ReaderTextView) {
        let filler = (0..<12).map { "<p>\(CanvasText.sentence(60, seed: $0))</p>" }.joined()
        let sections = try [
            "<h1>First chapter</h1><p>Opening words and <a href=\"two.xhtml\">a first link</a>.</p>\(filler)",
            "<h1>Second chapter</h1>\(filler)<p>Words with <a href=\"three.xhtml\">a second link</a> in them.</p><h2>A part of the second</h2>\(filler)",
            "<h1>Third chapter</h1>\(filler)<p>Closing words and <a href=\"one.xhtml\">a last link</a>.</p>",
        ].map { try H.build($0, css: Self.css).string }
        let source = FakeCanvasSource(sections)
        source.book = CanvasText.book(sections)
        let host = CanvasHost(source, size: CGSize(width: 500, height: 600), configuration: .init(flow: .scrolled))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return (host, try XCTUnwrap(host.canvas.scrollTextView))
    }

    /// The scroll view's text is the whole book, and an element that is no place in it is
    /// nowhere: the first heading, or the last. No heading follows the book's last link, and
    /// the answer from it is still an item.
    func testTheScrollViewsRotorAskedFromALinkBeginsTheList() throws {
        let (_, view) = try scrolledChapters()
        let headings = try rotorHeadings(of: view, listing: true).map(\.label)
        XCTAssertEqual(headings, ["First chapter, heading level 1", "Second chapter, heading level 1",
                                  "A part of the second, heading level 2", "Third chapter, heading level 1"])
        // Every link of the book has an element, on screen or screens below it: headings
        // stand before and after the first two, and none after the last.
        let found = try links(in: view, NSRange(location: 0, length: view.textLength))
        XCTAssertEqual(found.map { $0.accessibilityTitle() ?? "" }, ["a first link", "a second link", "a last link"])
        XCTAssertFalse(NSLocationInRange(found[1].range.location, view.accessibilityVisibleCharacterRange()), "the second link is below the screen")
        for link in found {
            XCTAssertEqual(try heading(of: view, from: link, forward: true), headings.first, link.accessibilityTitle() ?? "")
            XCTAssertEqual(try heading(of: view, from: link, forward: false), headings.last, link.accessibilityTitle() ?? "")
        }
    }

    /// What the text's children are to an assistive client, each by its role and name.
    private func children(of view: ReaderTextView) -> [String] {
        (view.accessibilityChildren() ?? []).compactMap { child in
            if let link = child as? ReaderLinkAccessibilityElement { return "link \(link.accessibilityTitle() ?? "")" }
            if let heading = child as? ReaderHeadingAccessibilityElement { return "heading \(heading.accessibilityLabel() ?? "")" }
            return nil
        }
    }

    private func headingChildren(of view: ReaderTextView) -> [ReaderHeadingAccessibilityElement] {
        (view.accessibilityChildren() ?? []).compactMap { $0 as? ReaderHeadingAccessibilityElement }
    }

    /// With its cursor on a link, VoiceOver's move to the next heading looks through the
    /// text's children in their order and asks no rotor (macOS 27.0.1): a page's headings
    /// stand there, each where it is in the text among the links.
    func testAPagesHeadingsAreAmongItsTextsChildrenWithItsLinks() throws {
        let (section, host, view) = try shownPage()
        XCTAssertEqual(children(of: view), [
            "heading A chapter title long enough to take two lines of the page", "heading Second linked part", "link linked",
            "heading Hidden third", "heading Deeper than six"], "in the order of the text, a heading before a link inside it")
        let headings = headingChildren(of: view)
        XCTAssertEqual(headings.map(\.range), section.string.readerHeadings().map(\.range))
        XCTAssertEqual(headings.map { $0.accessibilityValue() as? Int }, [1, 2, 3, nil], "the level VoiceOver says, and none where there is none to say")
        for heading in headings {
            let name = heading.accessibilityLabel() ?? ""
            XCTAssertEqual(heading.accessibilityRole(), .headingRole, name)
            XCTAssertTrue(heading.accessibilityParent() as AnyObject === view, name)
            let place = heading.accessibilityFrame()
            XCTAssertGreaterThanOrEqual(place.width, 1, name)
            XCTAssertGreaterThanOrEqual(place.height, 1, name)
            XCTAssertTrue(view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(place), "\(name): \(place) in \(view.accessibilityFrame()), words \(view.accessibilityFrame(for: heading.range))")
        }
        // Its place is its words': both lines of the first, and for the hidden one, which
        // takes no room, a point in the line it stands in.
        let title = headings[0].accessibilityFrame(), words = view.accessibilityFrame(for: headings[0].range)
        XCTAssertEqual(title.minY, words.minY, accuracy: 1)
        XCTAssertEqual(title.height, words.height, accuracy: 1)
        XCTAssertGreaterThan(title.height, 2 * view.accessibilityFrame(for: NSRange(location: 0, length: 5)).height - 1, "two lines")
        let under = (section.string.string as NSString).range(of: "Words under")
        XCTAssertEqual(headings[2].accessibilityFrame().midY, view.accessibilityFrame(for: under).midY, accuracy: 14)
        // The elements are kept while the text is: VoiceOver's cursor stays on the one it has.
        XCTAssertTrue(zip(headings, headingChildren(of: view)).allSatisfy { $0 === $1 })
        // A page gives its own headings, as it gives its own links, and after them the next
        // one of the book, which is on a later page.
        let chapter = try chapter()
        let pages = self.host(chapter.string, size: CGSize(width: 320, height: 560))
        let all = ["A chapter title long enough to take two lines of a narrow page column", "Second level", "Third level on two lines", "Fourth level"]
        var seen: [String] = [], turns = 0
        repeat {
            let column = try XCTUnwrap(pages.canvas.textViews.first)
            let headings = headingChildren(of: column)
            for heading in headings where heading.elsewhere == nil {
                XCTAssertLessThanOrEqual(NSMaxRange(heading.range), column.shownCharacters.length, heading.accessibilityLabel() ?? "")
                seen.append(heading.accessibilityLabel() ?? "")
            }
            let following = headings.filter { $0.elsewhere != nil }.map { $0.accessibilityLabel() ?? "" }
            XCTAssertEqual(following, seen.count < all.count ? [all[seen.count]] : [], "page \(turns): the next one after the page, and none after the last")
            XCTAssertTrue(headings.last?.elsewhere != nil || following.isEmpty, "it is the last of the children")
            turns += 1
        } while turns < 100 && pages.canvas.turnPage(forward: true) == .turned
        XCTAssertEqual(seen, all, "each on the page that shows it")
        // A text view with no canvas, as a note's popover has, keeps AppKit's children.
        let note = H.view(section.string, size: CGSize(width: 300, height: 400), pageColumn: false)
        XCTAssertFalse((note.accessibilityChildren() ?? []).contains { $0 is ReaderHeadingAccessibilityElement })
        _ = host
    }

    /// Two chapters in paging. The first opens with a heading and a link, goes on for pages,
    /// and ends on a page that holds two headings with a link between them; the second is a
    /// heading and a link after it, the last of the book.
    private func pagedBook() throws -> CanvasHost {
        let first = try H.build("""
            <h1>First title</h1><p>Opening words and <a href="two.xhtml">a first link</a>.</p><p>\(CanvasText.sentence(500, seed: 1))</p>\
            <h2>Second part</h2><p>Words with <a href="two.xhtml">a second link</a> in them.</p><h3>Third part</h3><p>Words under it.</p>
            """, css: Self.css + "h2 { break-before: page } ")
        let last = try H.build("<h1>Last title</h1><p>Closing words and <a href=\"one.xhtml\">a last link</a>.</p>", css: Self.css)
        let host = CanvasHost(FakeCanvasSource([first.string, last.string]), size: CGSize(width: 320, height: 560))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return host
    }

    private func column(_ host: CanvasHost, _ index: Int = 0) throws -> ReaderTextView {
        host.layOut()
        let columns = host.canvas.textViews
        return try XCTUnwrap(columns.indices.contains(index) ? columns[index] : nil)
    }

    /// From a link VoiceOver finds the next heading among the children of the link's text
    /// and nowhere else, and it takes an element for a place only when it is one of them. So
    /// a page's children end with the book's next heading, which is on a later page: an
    /// element at the foot of the column, called by the heading's words. VoiceOver focuses the
    /// element it moves to. The reader then turns to the heading's page, and that element is
    /// the heading's own there, with the insertion point on the heading.
    func testAPagesChildrenEndWithTheBooksNextHeadingAndFocusingItTurnsToItsPage() throws {
        let host = try pagedBook()
        var view = try column(host)
        XCTAssertEqual(children(of: view), ["heading First title", "link a first link", "heading Second part"])
        let second = try XCTUnwrap(headingChildren(of: view).last)
        let start = try XCTUnwrap((host.source.sections[0]?.string as NSString?)?.range(of: "Second part"))
        XCTAssertEqual(second.elsewhere, ReaderTextPosition(section: 0, offset: start.location))
        XCTAssertEqual(second.accessibilityRole(), .headingRole)
        XCTAssertEqual(second.accessibilityValue() as? Int, 2)
        XCTAssertTrue(second.accessibilityParent() as AnyObject === view)
        XCTAssertTrue(headingChildren(of: view).last === second, "kept while the page is")
        // Its characters are on no line of the page: it stands at the column's foot.
        let foot = second.accessibilityFrame(), page = view.accessibilityFrame()
        XCTAssertEqual(foot.minY, page.minY, accuracy: 1)
        XCTAssertEqual(foot.height, 1, accuracy: 0.5)
        XCTAssertEqual(foot.width, page.width, accuracy: 1)
        XCTAssertEqual(second.accessibilityFrameInParentSpace().maxY, view.bounds.maxY, accuracy: 1)
        // Losing the focus, and what an assistive client reads of it, turn nothing.
        var shown = host.recorder.shown.count
        second.setAccessibilityFocused(false)
        _ = second.accessibilityLabel()
        XCTAssertEqual(host.recorder.shown.count, shown)
        // VoiceOver moves to it.
        second.setAccessibilityFocused(true)
        XCTAssertEqual(host.recorder.shown.count, shown + 1, "the reader turned to its page")
        view = try column(host)
        XCTAssertEqual(children(of: view), ["heading Second part", "link a second link", "heading Third part", "heading Last title"])
        XCTAssertTrue(headingChildren(of: view).first === second, "the element VoiceOver is on is the heading's on the new page")
        XCTAssertNil(second.elsewhere)
        XCTAssertEqual(view.plainText(in: second.range), "Second part")
        XCTAssertTrue(second.accessibilityParent() as AnyObject === view)
        XCTAssertGreaterThan(second.accessibilityFrame().height, 2, "where its words are")
        XCTAssertTrue(view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(second.accessibilityFrame()))
        XCTAssertEqual(view.selectedRange, NSRange(location: second.range.location, length: 0), "reading on starts at the heading")
        // A heading on the page: the insertion point goes to it, and nothing turns.
        shown = host.recorder.shown.count
        let third = headingChildren(of: view)[1]
        third.setAccessibilityFocused(true)
        XCTAssertEqual(view.selectedRange, NSRange(location: third.range.location, length: 0))
        XCTAssertEqual(host.recorder.shown.count, shown)
        // The next chapter's, which is the book's last: nothing follows it.
        let last = headingChildren(of: view)[2]
        XCTAssertEqual(last.elsewhere, ReaderTextPosition(section: 1, offset: 0))
        XCTAssertEqual(last.accessibilityValue() as? Int, 1)
        last.setAccessibilityFocused(true)
        XCTAssertEqual(host.recorder.shown.count, shown + 1)
        view = try column(host)
        XCTAssertEqual(children(of: view), ["heading Last title", "link a last link"])
        XCTAssertTrue(headingChildren(of: view).first === last)
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
        // A page turned by anything else gives its own elements, and the one kept from the
        // page before is no child of it.
        XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
        view = try column(host)
        XCTAssertFalse(headingChildren(of: view).contains { $0 === last || $0 === second })
        XCTAssertEqual(headingChildren(of: view).last?.elsewhere, ReaderTextPosition(section: 1, offset: 0))
    }

    /// A chapter that is not built yet ends the list, as it ends the rotor's.
    func testAPageGivesNoNextHeadingWhileTheChapterThatHoldsItIsNotBuilt() throws {
        let section = try H.build("<h1>Title</h1><p>Words and <a href=\"two.xhtml\">a link</a>.</p>", css: Self.css)
        let after = try H.build("<h1>The chapter after</h1><p>End.</p>", css: Self.css)
        let source = FakeCanvasSource([section.string, nil])
        let host = CanvasHost(source, size: CGSize(width: 320, height: 560))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        XCTAssertEqual(children(of: try column(host)), ["heading Title", "link a link"])
        source.sections[1] = after.string
        XCTAssertEqual(children(of: try column(host)), ["heading Title", "link a link", "heading The chapter after"])
    }

    /// Each column of a spread gives the next heading after its own page. For the left column
    /// that can be one the right column shows: no page is turned for it, and the element
    /// VoiceOver moved to becomes the right column's own. A turn can put the heading in
    /// either column.
    func testEachColumnOfASpreadGivesTheNextHeadingAfterItsOwnPage() throws {
        // Each heading opens a page, so the first spread holds two and the second the other two.
        let body = (1...4).map { "<h1>Heading \($0)</h1><p>Words of part \($0) and <a href=\"two.xhtml\">link \($0)</a>.</p>" }.joined()
        let section = try H.build(body, css: Self.css + "h1 { break-before: page } ")
        let host = CanvasHost(FakeCanvasSource([section.string]), size: CGSize(width: 1100, height: 420))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        var left = try column(host, 0), right = try column(host, 1)
        XCTAssertEqual(children(of: left), ["heading Heading 1", "link link 1", "heading Heading 2"])
        XCTAssertEqual(children(of: right), ["heading Heading 2", "link link 2", "heading Heading 3"])
        var shown = host.recorder.shown.count
        let second = try XCTUnwrap(headingChildren(of: left).last)
        XCTAssertTrue(second.accessibilityParent() as AnyObject === left)
        XCTAssertFalse(second === headingChildren(of: right).first)
        second.setAccessibilityFocused(true)
        XCTAssertEqual(host.recorder.shown.count, shown, "the right column shows it")
        XCTAssertTrue(headingChildren(of: right).first === second, "the right column's own element now")
        XCTAssertTrue(second.accessibilityParent() as AnyObject === right)
        XCTAssertEqual(second.range.location, 0)
        XCTAssertTrue(right.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(second.accessibilityFrame()))
        XCTAssertEqual(right.selectedRange, NSRange(location: 0, length: 0))
        // The left column gives the same heading again, with another element.
        let again = try XCTUnwrap(headingChildren(of: left).last)
        XCTAssertEqual(again.accessibilityLabel(), "Heading 2")
        XCTAssertFalse(again === second)
        XCTAssertTrue(again.accessibilityParent() as AnyObject === left)
        // From the right column the next one is on the next spread, in its left column.
        let third = try XCTUnwrap(headingChildren(of: right).last)
        third.setAccessibilityFocused(true)
        XCTAssertEqual(host.recorder.shown.count, shown + 1)
        left = try column(host, 0)
        right = try column(host, 1)
        XCTAssertTrue(headingChildren(of: left).first === third)
        XCTAssertEqual(children(of: left), ["heading Heading 3", "link link 3", "heading Heading 4"])
        XCTAssertEqual(children(of: right), ["heading Heading 4", "link link 4"])

        // A heading on the fourth page of a chapter is in the right column of its spread.
        let odd = try H.build("<h1>Heading 1</h1><p>Words.</p><p class=\"turn\">Second page.</p><p class=\"turn\">Third page.</p><h1>Heading 2</h1><p>End.</p>",
                              css: Self.css + "h1, .turn { break-before: page } ")
        let other = CanvasHost(FakeCanvasSource([odd.string]), size: CGSize(width: 1100, height: 420))
        hosts.append(other)
        other.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        left = try column(other, 0)
        right = try column(other, 1)
        XCTAssertEqual(children(of: left), ["heading Heading 1", "heading Heading 2"])
        XCTAssertEqual(children(of: right), ["heading Heading 2"])
        shown = other.recorder.shown.count
        let far = try XCTUnwrap(headingChildren(of: left).last)
        far.setAccessibilityFocused(true)
        XCTAssertEqual(other.recorder.shown.count, shown + 1)
        left = try column(other, 0)
        right = try column(other, 1)
        XCTAssertTrue(left.plainText(in: left.shownCharacters).hasPrefix("Third page."))
        XCTAssertEqual(children(of: left), ["heading Heading 2"], "the third page has no heading of its own, and the next one is beside it")
        XCTAssertFalse(headingChildren(of: left).first === far)
        XCTAssertEqual(children(of: right), ["heading Heading 2"])
        XCTAssertTrue(headingChildren(of: right).first === far)
        XCTAssertTrue(far.accessibilityParent() as AnyObject === right)
        XCTAssertEqual(right.selectedRange, NSRange(location: far.range.location, length: 0))
    }

    /// In continuous scroll the next heading below the screen is a child already. VoiceOver's
    /// cursor is on the element it moves to and not in the text, and its next move by word or
    /// by line starts from the insertion point: the reader puts that on the heading, and
    /// shows one that is below the screen as it shows a link's target.
    func testFocusingAHeadingsElementInContinuousScrollPutsTheInsertionPointOnTheHeading() throws {
        let (host, view) = try scrolledChapters()
        let headings = headingChildren(of: view)
        XCTAssertEqual(headings.map { $0.accessibilityLabel() ?? "" }, ["First chapter", "Second chapter"])
        XCTAssertTrue(headings.allSatisfy { $0.elsewhere == nil }, "characters of the view's own text, on screen or below it")
        let visible = view.accessibilityVisibleCharacterRange()
        view.selectedRange = NSRange(location: 40, length: 5)
        var shown = host.recorder.shown.count
        headings[0].setAccessibilityFocused(true)
        XCTAssertEqual(view.selectedRange, NSRange(location: headings[0].range.location, length: 0))
        XCTAssertEqual(view.accessibilityVisibleCharacterRange(), visible, "one on screen is left where it is")
        XCTAssertEqual(host.recorder.shown.count, shown)
        shown = host.recorder.shown.count
        headings[1].setAccessibilityFocused(true)
        host.layOut()
        XCTAssertEqual(host.recorder.shown.count, shown + 1, "the reader showed it")
        XCTAssertEqual(view.selectedRange, NSRange(location: headings[1].range.location, length: 0))
        XCTAssertGreaterThan(NSIntersectionRange(headings[1].range, view.accessibilityVisibleCharacterRange()).length, 0, "on screen now")
        XCTAssertTrue(headingChildren(of: view).first === headings[1], "the same element")
        XCTAssertEqual(headingChildren(of: view).map { $0.accessibilityLabel() ?? "" }, ["Second chapter", "A part of the second"])
    }

    /// A text does not offer VoiceOver's search for elements (`AXUIElementsForSearchPredicate`),
    /// which would end the move by heading at the book's last heading in place of beginning
    /// again. A text area that offers it is asked for every kind of item VoiceOver looks for,
    /// and can answer with elements alone: its moves to the next change of font or of style
    /// left the text, where they find the place in a text that offers none, and a search for
    /// a kind nothing in the window has was asked without end (macOS 27.0.1). Nor do the
    /// elements offer it: one that does is asked in place of being looked at, with no start,
    /// and so is every child after it.
    @available(macOS, deprecated: 10.10)
    func testNeitherATextNorItsElementsOfferTheSearchForElements() throws {
        let host = try pagedBook()
        let view = try column(host)
        let search = NSAccessibility.ParameterizedAttribute.uiElementsForSearchPredicateParameterizedAttribute
        XCTAssertFalse(view.accessibilityParameterizedAttributeNames().contains(search))
        XCTAssertTrue(view.accessibilityParameterizedAttributeNames().contains(.stringForRange), "AppKit's own are there")
        let own = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        XCTAssertEqual(own.count, 3)
        for element in own { XCTAssertFalse(element.accessibilityParameterizedAttributeNames().contains(search)) }
        let (_, scroll) = try scrolledChapters()
        XCTAssertFalse(scroll.accessibilityParameterizedAttributeNames().contains(search))
    }

    /// The scroll view lists the links of the paragraphs on screen. Its headings are those on
    /// screen and the next one below, where a move by heading goes from the last link on screen.
    func testTheScrollViewsChildrenAreTheHeadingsOnScreenAndTheNextBelow() throws {
        let (host, view) = try scrolledChapters()
        let all = try rotorHeadings(of: view, listing: true)
        func expected() -> [NSRange] {
            let visible = view.accessibilityVisibleCharacterRange()
            let shown = all.map(\.range).filter { NSIntersectionRange($0, visible).length > 0 }
            return shown + (all.map(\.range).first { $0.location >= NSMaxRange(visible) }.map { [$0] } ?? [])
        }
        XCTAssertEqual(children(of: view), ["heading First chapter", "link a first link", "heading Second chapter"])
        XCTAssertEqual(headingChildren(of: view).map(\.range), expected())
        XCTAssertFalse(NSLocationInRange(all[1].range.location, view.accessibilityVisibleCharacterRange()), "the second is screens below")
        let below = headingChildren(of: view)[1]
        XCTAssertEqual(below.accessibilityValue() as? Int, 1)
        XCTAssertGreaterThan(below.accessibilityFrameInParentSpace().minY, view.visibleRect.maxY, "its place is where it stands, below the screen")
        // Scrolled to the second chapter: the same element for its heading, now on screen.
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        host.layOut()
        XCTAssertEqual(headingChildren(of: view).map(\.range), expected())
        XCTAssertTrue(headingChildren(of: view).first === below)
        XCTAssertEqual(headingChildren(of: view).map { $0.accessibilityLabel() ?? "" }, ["Second chapter", "A part of the second"])
        // At the end of the book nothing is below.
        host.canvas.show(ReaderTextPosition(section: 2, offset: 0), selecting: nil)
        host.layOut()
        XCTAssertEqual(headingChildren(of: view).map(\.range), expected())
        XCTAssertEqual(headingChildren(of: view).last?.accessibilityLabel(), "Third chapter")
    }
    #endif
}
