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

/// What a move by block goes through ("Input and accessibility" in `doc/native-viewer.md`):
/// each paragraph, picture, list item, table and heading of the book once, and nothing that is
/// not read. On iPhone and iPad VoiceOver's Paragraphs rotor moves by them through the book, in
/// pages and in continuous scroll. API level only: no assistive technology is driven
/// (`doc/testing.md#voiceover-testing` has what VoiceOver said).
@MainActor final class BlockAccessibilityTests: XCTestCase {
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

    private static let css = H.reset + ".sr { position:absolute; left:-999em } img { width:32px; height:32px } td, th { padding:2px }"

    private func build(_ body: String) throws -> SectionText {
        try H.build(body, css: Self.css, files: ["p.png": RichFixture.image(width: 64, height: 64)])
    }

    /// What each block of `text` reads, without the white space at its ends; a rule is named.
    private func blocks(of text: NSAttributedString) -> [String] {
        text.readerBlocks().map { block in
            let words = text.readerPlainText(in: block.range, spoken: true).trimmingCharacters(in: .whitespacesAndNewlines)
            let isRule = text.attribute(.attachment, at: block.spoken, effectiveRange: nil) is ReaderRuleAttachment
            return words.isEmpty && isRule ? ReaderRuleAttachment.spokenName : words
        }
    }

    /// A heading, a paragraph of several lines with a link in it, a picture of its own, a list
    /// with a list inside it, a table of data with a caption, a paragraph with a break in it, a
    /// rule and a last paragraph.
    private static let kinds = """
        <h1>Opening title</h1><p>A first paragraph long enough to take more than one line of a narrow page column, \
        with a <a href="two.xhtml">link</a> inside it.</p><p><img src="p.png" alt="Blue square"/></p>\
        <ul><li>First item</li><li>Second item<ul><li>Inner item</li></ul></li></ul>\
        <table><caption>Tide times</caption><tr><th>Port</th><th>High</th></tr><tr><td>Dover</td><td>Noon</td></tr></table>\
        <p>Words with a break<br/>after it.</p><hr/><p>Last words.</p>
        """

    func testEachParagraphPictureListItemAndTableIsOneBlock() throws {
        let section = try build(Self.kinds)
        let found = blocks(of: section.string)
        XCTAssertEqual(found.count, 10, "\(found)")
        guard found.count == 10 else { return }
        XCTAssertEqual(found[0], "Opening title")
        XCTAssertEqual(found[1], "A first paragraph long enough to take more than one line of a narrow page column, with a link inside it.",
                       "a paragraph is one block however many lines it takes, with what is inside it")
        XCTAssertEqual(found[2], "Blue square", "a picture in a paragraph of its own")
        // Each item of a list, the list inside one too, with its marker.
        for (index, words) in [(3, "First item"), (4, "Second item"), (5, "Inner item")] {
            XCTAssertTrue(found[index].hasSuffix(words), "\(found[index]) is the item \(words)")
            XCTAssertNotEqual(found[index], words, "its marker is read with it")
        }
        XCTAssertEqual(found[6], "Tide times\nPort\tHigh\nDover\tNoon", "a table is one block, its caption and its rows")
        XCTAssertEqual(found[7], "Words with a break\u{2028}after it.", "a break inside a paragraph parts nothing")
        XCTAssertEqual(found[8], ReaderRuleAttachment.spokenName)
        XCTAssertEqual(found[9], "Last words.")
        // A block begins to be read where it begins.
        XCTAssertTrue(section.string.readerBlocks().allSatisfy { $0.spoken == $0.range.location })
    }

    func testAHeadingIsOneBlockWhereverItStands() throws {
        let section = try build("""
            <h1 class="sr">Parked title</h1><p>Shown opening words.</p>\
            <h2><span style="display:block">Two blocks</span><span style="display:block">of one heading</span></h2>\
            <p><span role="heading" aria-level="3">Run in.</span> The rest of its paragraph.</p>
            """)
        XCTAssertTrue(section.string.string.hasPrefix("\u{FFFC}Shown opening words.\n"),
                      "the hidden heading opens the line of the words after it: \(section.string.string.debugDescription)")
        XCTAssertEqual(blocks(of: section.string), ["Parked title", "Shown opening words.", "Two blocks\nof one heading", "Run in.",
                                                    "The rest of its paragraph."])
    }

    func testWhatNothingReadsIsNoBlock() throws {
        let section = try build("""
            <p>Before.</p><p><img src="p.png" alt=""/></p><p style="visibility:hidden">Hidden words.</p>\
            <p aria-hidden="true">Kept words.</p><p><img src="p.png" alt="Kept picture" aria-hidden="true"/></p><hr role="presentation"/>\
            <table role="presentation"><tr><td></td><td></td></tr></table>\
            <table role="presentation"><tr><td>Upper near</td><td>Upper far</td></tr><tr><td></td><td></td></tr>\
            <tr><td>Lower near</td><td>Lower far</td></tr></table><p>After.</p>
            """)
        let text = section.string.string
        XCTAssertTrue(text.contains("Hidden words.") && text.contains("Kept words."), text.debugDescription)
        var images = 0, rules = 0
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if value is ReaderImageAttachment { images += 1 }
            if value is ReaderRuleAttachment { rules += 1 }
        }
        XCTAssertEqual(images, 2, "both pictures are in the text")
        XCTAssertEqual(rules, 1, "and the rule")
        // Decoration, hidden words, kept words, a kept picture and rule, a row with nothing to say.
        XCTAssertEqual(blocks(of: section.string), ["Before.", "Upper near\tUpper far\n\t\nLower near\tLower far", "After."])
    }

    func testABoxInALineOfTheSourcePartsNoBlock() throws {
        let section = try build("""
            <p>Before the box <span style="display:inline-block; width:90px">boxed words</span> after the box.</p><p>Next.</p>
            """)
        let text = section.string.string
        XCTAssertTrue(text.contains("\nboxed words"), "the box has a paragraph of its own: \(text.debugDescription)")
        let found = section.string.readerBlocks()
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.range.location, 0)
        XCTAssertEqual(section.string.readerPlainText(in: try XCTUnwrap(found.last).range), "Next.")
        // The break itself is the text's own: nothing else of it changed.
        let breaks = (text as NSString).range(of: "\nboxed")
        XCTAssertNotNil(section.string.attribute(.readerLayoutBreak, at: breaks.location, effectiveRange: nil))
        XCTAssertNil(section.string.attribute(.readerLayoutBreak, at: (text as NSString).range(of: "\nNext").location, effectiveRange: nil),
                     "a paragraph's own break is no such break")
    }

    /// Where a move by block goes when the page or the screen has no more: the book's next
    /// block, through the chapters page turns reach.
    func testTheBooksNextBlockIsFoundThroughTheChaptersPageTurnsReach() throws {
        let first = try build("<p>One.</p><p>Two words.</p>")
        let aside = try build("<p>In a chapter page turns step over.</p>")
        let silent = try build("<p style=\"visibility:hidden\">Hidden.</p><p><img src=\"p.png\" alt=\"\"/></p>")
        let last = try build("<p>Last.</p>")
        let end = try build("<p>The end.</p>")
        let host = CanvasHost(FakeCanvasSource([first.string, aside.string, silent.string, last.string, nil, end.string],
                                               linear: [true, false, true, true, true, true]), size: CGSize(width: 320, height: 560))
        hosts.append(host)
        func block(_ section: Int, _ range: Range<Int>, forward: Bool = true) -> ReaderTextPosition? {
            host.canvas.bookBlock(from: ReaderTextRange(section: section, range), forward: forward)?.position
        }
        let two = H.range("Two words.", in: first).location
        // Within a chapter: forward from the end of what the cursor is on, back from its start.
        XCTAssertEqual(block(0, 0..<2), ReaderTextPosition(section: 0, offset: two))
        XCTAssertEqual(block(0, 0..<4), ReaderTextPosition(section: 0, offset: two), "from all of the first")
        XCTAssertEqual(block(0, two + 4..<two + 10, forward: false), ReaderTextPosition(section: 0, offset: two),
                       "from inside a block, back to where it begins")
        XCTAssertEqual(block(0, two..<two + 3, forward: false), ReaderTextPosition(section: 0, offset: 0), "and from there to the one before")
        XCTAssertNil(block(0, 0..<2, forward: false), "none before the book's first")
        // On past the chapter page turns step over and the one with nothing to read.
        XCTAssertEqual(block(0, two..<two + 3), ReaderTextPosition(section: 3, offset: 0))
        XCTAssertEqual(block(3, 0..<2, forward: false), ReaderTextPosition(section: 0, offset: two))
        // A search that starts in the chapter passed over looks in it, and leaves it either way.
        XCTAssertEqual(block(1, 0..<2, forward: false), ReaderTextPosition(section: 0, offset: two))
        XCTAssertEqual(block(1, 0..<2), ReaderTextPosition(section: 3, offset: 0))
        XCTAssertEqual(block(1, 4..<6, forward: false), ReaderTextPosition(section: 1, offset: 0))
        // A chapter that is not built yet ends the search.
        XCTAssertNil(block(3, 0..<2))
        XCTAssertNil(block(5, 0..<2, forward: false), "and from past it")
        // From no item: before the first of the chapters built around the one on screen, or after the last.
        XCTAssertEqual(host.canvas.bookBlock(from: nil, forward: true)?.position, ReaderTextPosition(section: 0, offset: 0))
        XCTAssertEqual(host.canvas.bookBlock(from: nil, forward: false)?.position, ReaderTextPosition(section: 3, offset: 0))
    }

    #if os(iOS)
    private func page(_ sections: [NSAttributedString?], size: CGSize) throws -> (host: CanvasHost, view: ReaderTextView) {
        let host = CanvasHost(FakeCanvasSource(sections), size: size)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return (host, try XCTUnwrap(host.canvas.textViews.first))
    }

    /// What a view gives VoiceOver, in reading order: each line, and each cell of a table of
    /// data where the table's element stands.
    private func items(of view: ReaderTextView) throws -> [UIAccessibilityElement] {
        try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement]).flatMap { element -> [UIAccessibilityElement] in
            guard element is UIAccessibilityContainerDataTable else { return [element] }
            return try XCTUnwrap(element.accessibilityElements as? [UIAccessibilityElement])
        }
    }

    private func words(_ element: UIAccessibilityElement?) -> String {
        (element?.accessibilityLabel ?? "none").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text view an element is listed by: its container, or its table's.
    private func view(of element: UIAccessibilityElement, file: StaticString = #filePath, line: UInt = #line) throws -> ReaderTextView {
        var container = element.accessibilityContainer
        while let inner = container as? UIAccessibilityElement { container = inner.accessibilityContainer }
        return try XCTUnwrap(container as? ReaderTextView, file: file, line: line)
    }

    /// The first words a block's first element reads: up to twelve characters from where it
    /// begins to be read.
    private func opening(_ block: ReaderTextBlock, in text: NSAttributedString) -> String {
        let length = min(12, NSMaxRange(block.range) - block.spoken)
        return text.readerPlainText(in: NSRange(location: block.spoken, length: length)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The item the view's Paragraphs rotor gives with VoiceOver's cursor on `element` (on none
    /// of the view's lines when nil), asked as VoiceOver asks when a finger flicks down or up:
    /// twice, from the same item, though the first answer may have turned the page that item
    /// was on (`HeadingAccessibilityTests.rotorHeading`).
    private func rotorBlock(from element: UIAccessibilityElement?, in view: ReaderTextView, forward: Bool,
                            file: StaticString = #filePath, line: UInt = #line) throws -> UIAccessibilityElement? {
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors?.first { $0.name == "Paragraphs" },
                                  "the lines' container gives VoiceOver a Paragraphs rotor", file: file, line: line)
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = forward ? .next : .previous
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: element ?? view, targetRange: nil)
        let first = rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement
        let second = rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement
        XCTAssertTrue(first === second, "asked again from \(words(element)): \(words(first)), then \(words(second))", file: file, line: line)
        return first
    }

    /// Each item the rotor gives from `start` on, until it gives none, with the view it is in.
    private func rotorBlocks(from start: UIAccessibilityElement?, in view: ReaderTextView, forward: Bool,
                             file: StaticString = #filePath, line: UInt = #line) throws -> [UIAccessibilityElement] {
        var found: [UIAccessibilityElement] = [], cursor = start, container = view
        while let next = try rotorBlock(from: cursor, in: container, forward: forward, file: file, line: line) {
            found.append(next)
            cursor = next
            container = try self.view(of: next, file: file, line: line)
            guard found.count < 60 else { XCTFail("the rotor goes on", file: file, line: line); break }
        }
        return found
    }

    func testTheParagraphsRotorMovesAmongThePagesBlocks() throws {
        let section = try build(Self.kinds)
        let (_, view) = try page([section.string], size: CGSize(width: 320, height: 1_400))
        XCTAssertEqual(view.shownCharacters.length, section.string.length, "the whole section is on the page")
        let listed = try items(of: view)
        func item(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> UIAccessibilityElement {
            try XCTUnwrap(listed.first { words($0).contains(text) }, "\(text) is listed", file: file, line: line)
        }
        let stops = try ["Opening title", "A first paragraph", "Blue square", "First item", "Second item", "Inner item", "Tide times",
                         "Words with a break", ReaderRuleAttachment.spokenName, "Last words."].map { try item($0) }
        // Forward from none of the lines through every block, and back from the last.
        XCTAssertEqual(try rotorBlocks(from: nil, in: view, forward: true).map(words), stops.map(words))
        XCTAssertEqual(try rotorBlocks(from: stops.last, in: view, forward: false).map(words), stops.dropLast().reversed().map(words))
        XCTAssertTrue(try rotorBlock(from: nil, in: view, forward: false) === stops.last)
        // From each item that follows a block's first, inside it: forward to the next block,
        // back to where its own begins. The paragraph's later lines and its link, the
        // table's cells, the line after the break.
        let paragraph = try XCTUnwrap(listed.firstIndex { $0 === stops[1] }), picture = try XCTUnwrap(listed.firstIndex { $0 === stops[2] })
        let caption = try XCTUnwrap(listed.firstIndex { $0 === stops[6] }), broken = try XCTUnwrap(listed.firstIndex { $0 === stops[7] })
        XCTAssertGreaterThan(picture - paragraph, 2, "lines and a link")
        for (inside, own, next) in [((paragraph + 1)..<picture, 1, 2), ((caption + 1)..<broken, 6, 7), ((broken + 1)..<(broken + 2), 7, 8)] {
            for index in inside {
                XCTAssertTrue(try rotorBlock(from: listed[index], in: view, forward: true) === stops[next], "on from \(words(listed[index]))")
                XCTAssertTrue(try rotorBlock(from: listed[index], in: view, forward: false) === stops[own], "back from \(words(listed[index]))")
            }
        }
        XCTAssertEqual(words(listed[broken + 1]), "after it.")
        XCTAssertTrue(listed[(caption + 1)..<broken].contains { words($0) == "Dover" }, "the table's cells are listed in it")
        XCTAssertTrue(zip(listed, try items(of: view)).allSatisfy { $0 === $1 }, "a page that holds the block asked for is not shown again")
        // The column gives every line of the page the rotor, after Headings.
        XCTAssertEqual(view.accessibilityCustomRotors?.map(\.systemRotorType), [.heading, .none])
        XCTAssertEqual(view.accessibilityCustomRotors?.last?.name, "Paragraphs")
        XCTAssertTrue(listed.allSatisfy { $0.accessibilityCustomRotors == nil })
    }

    func testTheParagraphsRotorTurnsToThePageOfTheNextBlock() throws {
        let first = try build("<h1>Chapter title</h1><p>\(CanvasText.sentence(150, seed: 1))</p><p>\(CanvasText.sentence(260, seed: 2))</p>"
            + "<p>Short one.</p><p>\(CanvasText.sentence(300, seed: 3))</p>")
        let second = try build("<h1>The chapter after</h1><p>\(CanvasText.sentence(120, seed: 7))</p><p>End.</p>")
        let (host, _) = try page([first.string, second.string], size: CGSize(width: 320, height: 560))
        let canvas = host.canvas
        func column() throws -> ReaderTextView { try XCTUnwrap(canvas.textViews.first) }
        // What each block's first element begins with, in the book's order.
        let expected = [first, second].flatMap { section in section.string.readerBlocks().map { opening($0, in: section.string) } }
        XCTAssertEqual(expected.count, 8)
        let title = try XCTUnwrap(try items(of: try column()).first)
        XCTAssertEqual(words(title), "Chapter title")
        // Forward through the book: each move shows the page that holds the block it gives.
        var cursor = title, places: [ReaderTextPosition] = [], heard: [String] = []
        while let next = try rotorBlock(from: cursor, in: try XCTUnwrap(cursor.accessibilityContainer as? ReaderTextView), forward: true) {
            let view = try XCTUnwrap(next.accessibilityContainer as? ReaderTextView)
            XCTAssertTrue(try column() === view, "\(words(next)) is on the page now shown")
            XCTAssertNotEqual(view.index(ofAccessibilityElement: next), NSNotFound)
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(next.accessibilityFrameInContainerSpace), words(next))
            heard.append(words(next))
            places.append(ReaderTextPosition(section: try XCTUnwrap(view.placement.section), offset: view.placement.offset))
            cursor = next
            XCTAssertLessThan(heard.count, 20)
        }
        XCTAssertEqual(heard.count, expected.count - 1)
        XCTAssertTrue(zip(heard, expected.dropFirst()).allSatisfy { $0.hasPrefix($1) }, "\(heard) begin \(expected.dropFirst())")
        XCTAssertEqual(places.map(\.section), [0, 0, 0, 0, 1, 1, 1])
        XCTAssertTrue(zip(places, places.dropFirst()).allSatisfy { $0 <= $1 }, "onward through the book")
        XCTAssertGreaterThanOrEqual(Set(places).count, 3, "the moves turn pages")
        XCTAssertEqual(host.recorder.shown.last?.range.start.section, 1, "the reader reports the place it was taken to")
        // And back to the first page of the first chapter.
        var back: [String] = []
        while let previous = try rotorBlock(from: cursor, in: try XCTUnwrap(cursor.accessibilityContainer as? ReaderTextView), forward: false) {
            back.append(words(previous))
            cursor = previous
            XCTAssertLessThan(back.count, 20)
        }
        XCTAssertEqual(back, Array(heard.dropLast().reversed()) + ["Chapter title"])
        XCTAssertEqual(try column().placement.offset, 0)
        XCTAssertEqual(try column().placement.section, 0)
        // From the first line of a page that a paragraph runs onto from the page before: back
        // to the page where it begins, and on to the block after it.
        let blocks = first.string.readerBlocks()
        var runOn: (block: Int, offset: Int)?
        while runOn == nil, canvas.turnPage(forward: true) == .turned, try column().placement.section == 0 {
            let offset = try column().placement.offset
            if let index = blocks.firstIndex(where: { $0.range.location < offset && offset < NSMaxRange($0.range) }) { runOn = (index, offset) }
        }
        let (index, offset) = try XCTUnwrap(runOn, "a paragraph runs over a page")
        XCTAssertLessThan(index + 1, blocks.count)
        let top = try XCTUnwrap(try items(of: try column()).first)
        let start = try XCTUnwrap(try rotorBlock(from: top, in: try column(), forward: false))
        XCTAssertLessThan(try column().placement.offset, offset, "the page before")
        XCTAssertTrue(words(start).hasPrefix(opening(blocks[index], in: first.string)), words(start))
        canvas.show(ReaderTextPosition(section: 0, offset: offset), selecting: nil)
        host.layOut()
        XCTAssertEqual(try column().placement.offset, offset)
        let after = try XCTUnwrap(try rotorBlock(from: try XCTUnwrap(try items(of: try column()).first), in: try column(), forward: true))
        XCTAssertTrue(words(after).hasPrefix(opening(blocks[index + 1], in: first.string)), words(after))
    }

    func testTheParagraphsRotorScrollsThroughTheBookInContinuousScroll() async throws {
        let long = (1...200).map { "Long sentence \($0) of the one paragraph." }.joined(separator: " ")
        let reader = try SessionCoverageReader(try SessionCoverageBook.epub([
            SessionCoverageBook.Section("one", "<h1>First part</h1><p>Opening words.</p><p>\(long)</p><p>After the long one.</p>", title: "First part"),
            SessionCoverageBook.Section("two", "<h1>Second part</h1><p>Closing words.</p>", title: "Second part")]))
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas), view = try XCTUnwrap(canvas.scrollTextView)
        XCTAssertEqual(view.accessibilityCustomRotors?.map(\.systemRotorType), [.heading, .none], "the scroll view gives its lines both rotors")
        var cursor = try XCTUnwrap(try items(of: view).first)
        XCTAssertEqual(words(cursor), "First part")
        func onScreen(_ element: UIAccessibilityElement) -> Bool {
            let area = canvas.scrollVisibleContainerRect.offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y).insetBy(dx: -1_000, dy: -1)
            return area.contains(element.accessibilityFrameInContainerSpace)
        }
        // Each move gives the block's first line, listed; one past the lines listed scrolls to it.
        func move(forward: Bool) throws -> (element: UIAccessibilityElement, scrolled: Bool)? {
            let before = canvas.visibleRange
            guard let next = try rotorBlock(from: cursor, in: view, forward: forward) else { return nil }
            XCTAssertNotEqual(view.index(ofAccessibilityElement: next), NSNotFound, words(next))
            let scrolled = canvas.visibleRange != before
            if scrolled { XCTAssertTrue(onScreen(next), "\(words(next)) is on screen at \(next.accessibilityFrameInContainerSpace)") }
            // VoiceOver's cursor goes to what it is given.
            next.accessibilityElementDidBecomeFocused()
            cursor = next
            return (next, scrolled)
        }
        var heard: [String] = [], scrolls: [String] = []
        while let moved = try move(forward: true) {
            heard.append(words(moved.element))
            if moved.scrolled { scrolls.append(words(moved.element)) }
            XCTAssertLessThan(heard.count, 10)
        }
        XCTAssertEqual(heard.count, 5)
        XCTAssertEqual(heard.first, "Opening words.")
        XCTAssertTrue(heard.count > 1 && heard[1].hasPrefix("Long sentence 1 of"), "\(heard)")
        XCTAssertEqual(Array(heard.dropFirst(2)), ["After the long one.", "Second part", "Closing words."])
        XCTAssertTrue(scrolls.contains("After the long one."), "the long paragraph is more than the lines listed past the screen")
        var back: [String] = [], scrolledBack: [String] = []
        while let moved = try move(forward: false) {
            back.append(words(moved.element))
            if moved.scrolled { scrolledBack.append(words(moved.element)) }
            XCTAssertLessThan(back.count, 10)
        }
        XCTAssertEqual(back, Array(heard.dropLast().reversed()) + ["First part"])
        XCTAssertTrue(scrolledBack.contains { $0.hasPrefix("Long sentence 1 of") }, "back to where the long paragraph begins: \(scrolledBack)")
        XCTAssertEqual(canvas.visibleRange?.start.section, 0)
    }
    #endif
}
