#if os(macOS)
import AppKit
import EPUBCore
import EPUBReading
import XCTest
@testable import EPUBViewing

/// Where VoiceOver starts reading in continuous scroll on the Mac (doc/native-viewer.md
/// "Continuous scroll"): it enters a text view at its insertion point, so the reader keeps that
/// on the first line on screen.
///
/// No assistive technology is driven here. The tests read the insertion point as VoiceOver does,
/// through the text view's accessibility protocol, and move it as VoiceOver and a click do.
/// VoiceOver on iOS reads the text view's elements and has no insertion point to enter at
/// (`ScrolledAccessibilityLinesTests`).
@MainActor final class ScrolledAccessibilityEntryTests: XCTestCase {
    private typealias Subject = (reader: SessionCoverageReader, canvas: ReaderCanvasView)
    private var readers: [SessionCoverageReader] = []
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    /// Six chapters of labelled paragraphs ("d07" is the fourth chapter's seventh), some forty
    /// screens in all.
    private func book() throws -> Data {
        let chapters = [("front", 24), ("harbor", 28), ("market", 56), ("pass", 56), ("river", 50), ("summit", 31)]
        return try SessionCoverageBook.epub(chapters.enumerated().map { index, chapter in
            let letter = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(index)))
            var body = "<h1>Chapter \(chapter.0)</h1>"
            for paragraph in 1...chapter.1 {
                let label = "\(letter)" + (paragraph < 10 ? "0" : "") + "\(paragraph)"
                body += "<p>\(label) " + CanvasText.sentence(48 + (paragraph * 5 + index) % 9, seed: paragraph + index) + "</p>"
            }
            return SessionCoverageBook.Section(chapter.0, body, title: "Chapter \(chapter.0)")
        })
    }

    /// A reader opened in pages, as every reader is, with the whole book built.
    private func opened() async throws -> Subject {
        let reader = try SessionCoverageReader(try book())
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 600, height: 700))
        try await reader.settle()
        return (reader, try XCTUnwrap(reader.session.canvas))
    }

    private func scroll(_ subject: Subject) async throws -> ReaderTextView {
        try await subject.reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await subject.reader.wait("the whole book in the scroll view") { subject.canvas.scrollBook != nil }
        try await subject.reader.settle()
        return try XCTUnwrap(subject.canvas.scrollTextView)
    }

    /// Waits for the canvas to report where `move` left the scroll view.
    private func reported(after move: () -> Void, _ subject: Subject, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try XCTUnwrap(subject.canvas.visibleRange, file: file, line: line)
        move()
        try await subject.reader.wait("the place scrolled to", file: file, line: line) { subject.canvas.visibleRange != before }
    }

    /// Scrolls as a trackpad or a scroller does: the scroll view moves, not through the canvas.
    private func scrollByHand(_ distance: CGFloat, _ subject: Subject, file: StaticString = #filePath, line: UInt = #line) async throws {
        let scrollView = try XCTUnwrap(subject.canvas.scrollContainer as? NSScrollView, file: file, line: line)
        try await reported(after: {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + distance))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }, subject, file: file, line: line)
    }

    /// The text of the line VoiceOver enters at: the insertion point's, read as VoiceOver reads it.
    private func entryLine(of view: ReaderTextView) -> String {
        let line = view.accessibilityRange(forLine: view.accessibilityInsertionPointLineNumber())
        return (view.accessibilityString(for: line) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The start of the accessibility line holding `location`, where VoiceOver's line commands
    /// put the insertion point.
    private func lineStart(at location: Int, in view: ReaderTextView) -> Int {
        view.accessibilityRange(forLine: view.accessibilityLine(for: location)).location
    }

    /// VoiceOver would enter at the first line on screen: the insertion point is the visible
    /// start, nothing is selected, and its line is inside the scroll view.
    private func assertEntryIsTheFirstLineOnScreen(_ label: String, _ canvas: ReaderCanvasView,
                                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(canvas.scrollTextView, file: file, line: line)
        let shown = try XCTUnwrap(canvas.visibleRange, file: file, line: line)
        let start = canvas.scrollBook?.location(of: shown.start) ?? shown.start.offset
        let text = try XCTUnwrap(view.contentStorage.textStorage, file: file, line: line).string as NSString
        let first = text.substring(with: text.lineRange(for: NSRange(location: start, length: 0))).prefix(24)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: start, length: 0),
                       "\(label): the first line on screen begins \"\(first)\" and VoiceOver would enter at \"\(entryLine(of: view).prefix(24))\"",
                       file: file, line: line)
        XCTAssertEqual(view.accessibilitySelectedTextRanges()?.map(\.rangeValue), [NSRange(location: start, length: 0)], label, file: file, line: line)
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), view.accessibilityLine(for: start), label, file: file, line: line)
        XCTAssertNil(canvas.currentSelection, "\(label): nothing is selected", file: file, line: line)
        // On screen by the scroll view's own account, not only the reader's.
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView, file: file, line: line)
        let frame = try XCTUnwrap(view.lineFrame(containing: view.selectedRange.location), file: file, line: line)
            .offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y)
        XCTAssertTrue(scrollView.documentVisibleRect.contains(frame), "\(label): the line is inside the scroll view", file: file, line: line)
        XCTAssertTrue(view.accessibilityVisibleCharacterRange().contains(start), label, file: file, line: line)
    }

    func testVoiceOverWouldEnterAtTheFirstLineOnScreenWhereverTheReaderIsTaken() async throws {
        let subject = try await opened()
        let (reader, canvas) = subject
        // From pages in the middle of the book, the route a restored position takes.
        try await reader.session.send(.navigate(href: reader.publication.spine[3].resource.href))
        try await reader.wait("the fourth chapter") { reader.section == 3 }
        let view = try await scroll(subject)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 3, offset: 0))
        XCTAssertEqual(entryLine(of: view), "Chapter pass")
        try assertEntryIsTheFirstLineOnScreen("switched from pages", canvas)
        // By the table of contents.
        try await reader.session.send(.navigate(href: reader.publication.spine[1].resource.href))
        try await reader.wait("the second chapter") { reader.section == 1 }
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
        XCTAssertEqual(entryLine(of: view), "Chapter harbor")
        try assertEntryIsTheFirstLineOnScreen("chosen from the contents", canvas)
        // Scroll Forward and Scroll Backward, and the page keys.
        let chapter = try XCTUnwrap(canvas.visibleRange)
        try await reader.session.send(.nextPage)
        XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange).start, chapter.start)
        try assertEntryIsTheFirstLineOnScreen("a step forward", canvas)
        try await reader.session.send(.previousPage)
        XCTAssertEqual(canvas.visibleRange?.start, chapter.start)
        try assertEntryIsTheFirstLineOnScreen("a step back", canvas)
        // The person's own scrolling.
        try await scrollByHand(2_000, subject)
        try assertEntryIsTheFirstLineOnScreen("scrolled by hand", canvas)
        try await scrollByHand(-900, subject)
        try assertEntryIsTheFirstLineOnScreen("scrolled back by hand", canvas)
        // A new text size rebuilds the text under the same place.
        let place = try XCTUnwrap(canvas.visibleRange?.start)
        try await reader.session.send(.style(EPUBReaderStyle(fontSize: 23, flow: .scrolled)))
        try await reader.wait("the larger text") { reader.session.book.isComplete && reader.session.book.typography.fontSize == 23 }
        try await reader.settle()
        XCTAssertTrue(reader.isVisible(place), "the line that was first is still on screen")
        try assertEntryIsTheFirstLineOnScreen("at a larger text size", canvas)
    }

    /// What the canvas itself tells an assistive client while `body` runs, in order: the
    /// notification, the element that posts it and the elements it names. The notice AppKit
    /// posts when a text view's selection changes is not among them.
    private func posted(by canvas: ReaderCanvasView, during body: () async throws -> Void) async rethrows
        -> [(notification: NSAccessibility.Notification, element: AnyObject, named: [AnyObject])] {
        var posted: [(notification: NSAccessibility.Notification, element: AnyObject, named: [AnyObject])] = []
        let post = canvas.postAccessibilityNotification
        canvas.postAccessibilityNotification = { element, notification, userInfo in
            posted.append((notification, element as AnyObject, userInfo[.uiElements] as? [AnyObject] ?? []))
        }
        // The closure holds what was posted, the window among it, for as long as it is the canvas's.
        defer { canvas.postAccessibilityNotification = post }
        try await body()
        return posted
    }

    /// VoiceOver, back in a text it had left, enters at the insertion point only if it is told
    /// the text view changed (doc/native-viewer.md "Continuous scroll"). A move the reader makes
    /// itself posts that from the window, naming the scroll text view. What VoiceOver does with
    /// it is heard only in a speech session.
    func testAMoveTheReaderMakesPostsALayoutChangeNamingTheScrollTextView() async throws {
        let subject = try await opened()
        let (reader, canvas) = subject
        let view = try await scroll(subject)
        for (label, command) in [("a step forward", EPUBReaderCommand.nextPage), ("a step back", .previousPage)] {
            let changes = try await posted(by: canvas) { try await reader.session.send(command) }.filter { $0.notification == .layoutChanged }
            XCTAssertEqual(changes.count, 1, "\(label) posts a layout change")
            for change in changes {
                XCTAssertTrue(change.element === canvas.window, "\(label): posted by \(change.element)")
                XCTAssertEqual(change.named.map(ObjectIdentifier.init), [ObjectIdentifier(view)], label)
            }
        }
    }

    /// VoiceOver, inside the text and not yet moved in it, keeps its cursor on its line when the
    /// insertion point moves under one notice, and then scrolls the view back to that line: a
    /// scroll step made straight after entering was undone
    /// (doc/testing.md "Continuous scroll"). So after a move the reader makes itself
    /// the text view tells of the insertion point a second time, before the window's layout
    /// change, whatever made the move. What VoiceOver does with it is heard only in a speech
    /// session.
    func testAMoveTheReaderMakesTellsOfTheInsertionPointASecondTimeBeforeTheLayoutChange() async throws {
        let subject = try await opened()
        let (reader, canvas) = subject
        let view = try await scroll(subject)
        func assertToldTwice(_ label: String, _ move: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async throws {
            let before = view.selectedRange
            let told = try await posted(by: canvas, during: move)
            XCTAssertNotEqual(view.selectedRange, before, "\(label) moves the insertion point", file: file, line: line)
            try assertEntryIsTheFirstLineOnScreen(label, canvas, file: file, line: line)
            XCTAssertEqual(told.map(\.notification), [.selectedTextChanged, .layoutChanged], label, file: file, line: line)
            XCTAssertTrue(told.first?.element === view, "\(label): the text view tells of its insertion point", file: file, line: line)
            XCTAssertEqual(told.first?.named.count, 0, label, file: file, line: line)
            XCTAssertTrue(told.last?.element === canvas.window, "\(label): the window tells of the layout", file: file, line: line)
        }
        // The page keys, the text area's own actions and the host's buttons all step this way.
        try await assertToldTwice("a step forward") { try await reader.session.send(.nextPage) }
        try await assertToldTwice("a second step") { XCTAssertTrue(canvas.turnPageFromAccessibility(forward: true)) }
        try await assertToldTwice("a step by a page key") { canvas.turnPageFromInput(forward: true) }
        try await assertToldTwice("a step back") { try await reader.session.send(.previousPage) }
        // A place the reader is sent to.
        try await assertToldTwice("a chapter chosen from the contents") {
            try await reader.session.send(.navigate(href: reader.publication.spine[2].resource.href))
            try await reader.wait("the third chapter") { reader.section == 2 }
        }
        // Sent to where it already is, the insertion point does not move: nothing to tell twice.
        let again = try await posted(by: canvas) {
            try await reader.session.send(.navigate(href: reader.publication.spine[2].resource.href))
        }
        XCTAssertEqual(again.map(\.notification), [.layoutChanged], "the same chapter again")
        // The insertion point follows a scroll by hand, which is no move of the reader's: AppKit's
        // one notice is all there is, as before.
        let followed = view.selectedRange
        let byHand = try await posted(by: canvas) { try await scrollByHand(1_500, subject) }
        XCTAssertNotEqual(view.selectedRange, followed, "the insertion point follows a scroll by hand")
        try assertEntryIsTheFirstLineOnScreen("scrolled by hand", canvas)
        // On a busy Mac a move of the reader's own has landed in this wait, as in the tests
        // below (#352). Such a move brings its layout change: a notice of the insertion point
        // with none after it would be the scroll's own.
        let alone = byHand.indices.filter { byHand[$0].notification == .selectedTextChanged
            && !(byHand.indices.contains($0 + 1) && byHand[$0 + 1].notification == .layoutChanged) }
        XCTAssertTrue(alone.isEmpty, "a scroll by hand posts \(byHand.map(\.notification.rawValue))")
        // An insertion point an assistive client placed is the reader's again after its own step.
        view.setAccessibilitySelectedTextRange(NSRange(location: lineStart(at: view.selectedRange.location + 400, in: view), length: 0))
        try await assertToldTwice("a step from a line VoiceOver had moved to") { try await reader.session.send(.nextPage) }
        // A selection is never moved, so there is no move to tell of.
        let selected = NSRange(location: view.selectedRange.location, length: 12)
        view.setSelectedRange(selected)
        let withSelection = try await posted(by: canvas) { try await reader.session.send(.nextPage) }
        XCTAssertEqual(view.selectedRange, selected)
        XCTAssertEqual(withSelection.map(\.notification), [.layoutChanged], "a step with text selected")
    }

    func testVoiceOverWouldEnterAtTheBooksFirstLineWhenItOpensThere() async throws {
        let subject = try await opened()
        let view = try await scroll(subject)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(entryLine(of: view), "Chapter front")
        try assertEntryIsTheFirstLineOnScreen("opened at the start", subject.canvas)
    }

    /// VoiceOver moves the insertion point as it reads, and the text view scrolls to keep it in
    /// sight. That insertion point is VoiceOver's: the reader must not take it back to the top of
    /// the screen at every line, nor when the view is scrolled past it without it.
    func testAnInsertionPointAnAssistiveClientPlacedStaysWhereItIsWhileTheViewScrolls() async throws {
        let subject = try await opened()
        let (reader, canvas) = subject
        let view = try await scroll(subject)
        let book = try XCTUnwrap(canvas.scrollBook)
        // A line command moves to a line below the screen, and AppKit scrolls it into sight.
        let below = lineStart(at: 9_000, in: view)
        try await reported(after: { view.setAccessibilitySelectedTextRange(NSRange(location: below, length: 0)) }, subject)
        let shown = try XCTUnwrap(canvas.visibleRange)
        XCTAssertGreaterThan(shown.start, ReaderTextPosition(section: 0, offset: 0), "the view followed the insertion point")
        XCTAssertTrue(reader.isVisible(book.position(at: below)), "to where it is")
        XCTAssertGreaterThan(below, book.location(of: shown.start), "which is not the first line on screen")
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: below, length: 0), "and it stays the client's")
        // The view is scrolled on without it, by a client's own scrolling or by hand.
        try await reported(after: { view.setAccessibilityVisibleCharacterRange(NSRange(location: 30_000, length: 500)) }, subject)
        XCTAssertFalse(reader.isVisible(book.position(at: below)))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: below, length: 0), "off screen, still the client's")
        try await scrollByHand(1_500, subject)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: below, length: 0))
        // A move the reader makes itself takes VoiceOver with it, as a page turn does.
        try await reader.session.send(.nextPage)
        try assertEntryIsTheFirstLineOnScreen("a step forward", canvas)
        try await scrollByHand(1_500, subject)
        try assertEntryIsTheFirstLineOnScreen("the reader's own again, scrolled by hand", canvas)
    }

    /// A click, a scroll and a Shift-click select everything between: the click's place holds.
    func testAnInsertionPointAClickPlacedStaysThroughScrollingByHand() async throws {
        let subject = try await opened()
        let (reader, canvas) = subject
        let view = try await scroll(subject)
        let clicked = lineStart(at: 400, in: view) + 3
        view.setSelectedRange(NSRange(location: clicked, length: 0))
        try await scrollByHand(2_000, subject)
        XCTAssertEqual(view.selectedRange, NSRange(location: clicked, length: 0))
        XCTAssertNil(canvas.currentSelection)
        try await reader.session.send(.navigate(href: reader.publication.spine[4].resource.href))
        try await reader.wait("the fifth chapter") { reader.section == 4 }
        try assertEntryIsTheFirstLineOnScreen("chosen from the contents", canvas)
    }

    func testASelectionStaysWhereItIsThroughEveryMove() async throws {
        let subject = try await opened()
        let (reader, canvas) = subject
        let view = try await scroll(subject)
        let book = try XCTUnwrap(canvas.scrollBook)
        let selected = NSRange(location: lineStart(at: 400, in: view), length: 30)
        view.setSelectedRange(selected)
        let selection = ReaderTextRange(start: book.position(at: selected.location), end: book.position(at: NSMaxRange(selected)))
        XCTAssertEqual(canvas.currentSelection?.range, selection)
        try await reader.session.send(.nextPage)
        XCTAssertEqual(view.selectedRange, selected, "after a step forward")
        try await scrollByHand(2_000, subject)
        XCTAssertEqual(view.selectedRange, selected, "after scrolling by hand")
        XCTAssertEqual(view.accessibilitySelectedTextRange(), selected, "and VoiceOver is told of it")
        XCTAssertEqual(canvas.currentSelection?.range, selection)
        XCTAssertFalse(reader.isVisible(selection.start))
    }

    /// Until the whole book is built, and for a section it leaves out, the scroll view holds one
    /// section, and its positions are that section's own.
    func testVoiceOverWouldEnterAtTheFirstLineOnScreenOfASectionShownAlone() async throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        let host = CanvasHost(FakeCanvasSource([CanvasText.section(0), CanvasText.section(1, chapters: 3)]), configuration: configuration)
        hosts.append(host)
        let canvas = host.canvas
        canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        host.layOut()
        XCTAssertNil(canvas.scrollBook)
        let view = try XCTUnwrap(canvas.scrollTextView)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
        let text = try XCTUnwrap(host.source.sections[1]).string as NSString
        let chapter = text.range(of: "Section 1 chapter 2").location
        canvas.show(ReaderTextPosition(section: 1, offset: chapter), selecting: nil)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: chapter))
        XCTAssertEqual(entryLine(of: view), "Section 1 chapter 2")
        try assertEntryIsTheFirstLineOnScreen("a chapter of the section", canvas)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        try assertEntryIsTheFirstLineOnScreen("a step back", canvas)
    }

    /// A note's popover is the same kind of text view, and opens at its first line.
    func testVoiceOverWouldEnterANoteAtItsFirstLine() throws {
        let note = ReaderNoteViewController(text: CanvasText.body("A first line of the note.\nA second.\nA last line."), dark: false, width: 320)
        XCTAssertEqual(note.textView.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(note.textView.accessibilityInsertionPointLineNumber(), 0)
        XCTAssertEqual(entryLine(of: note.textView), "A first line of the note.")
    }
}
#endif
