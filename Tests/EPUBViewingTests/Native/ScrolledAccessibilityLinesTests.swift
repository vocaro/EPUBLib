#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// Where VoiceOver starts reading in continuous scroll on iPhone and iPad (doc/native-viewer.md
/// "Continuous scroll"): it walks the scroll view's accessibility elements and takes the first
/// when it moves in from a control, so the reader lists the lines on screen, and those just
/// past them only while VoiceOver's cursor is in the text.
///
/// No assistive technology is driven here, and UIKit's accessibility is not loaded in a test
/// host. The tests read the elements through the container protocol VoiceOver uses and stand in
/// for a move of its cursor (`focus`, `move`) with what a simulator's VoiceOver was seen to do
/// on 2026-10-12: UIKit scrolls the line the cursor is going to, until the area the insets
/// leave holds its frame and then 40 points further; the line left is told so; a focus
/// notification names only the element left; the line reached is told so; a second
/// notification names it.
@MainActor final class ScrolledAccessibilityLinesTests: XCTestCase {
    private typealias Subject = (reader: SessionCoverageReader, canvas: ReaderCanvasView, view: ReaderTextView)
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
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

    /// A reader opened in pages, sent to the fourth chapter and switched to continuous scroll:
    /// the route a restored position takes.
    private func scrolledAtTheFourthChapter() async throws -> Subject {
        let reader = try SessionCoverageReader(try book())
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.navigate(href: reader.publication.spine[3].resource.href))
        try await reader.wait("the fourth chapter") { reader.section == 3 }
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 3, offset: 0))
        return (reader, canvas, try XCTUnwrap(canvas.scrollTextView))
    }

    private func elements(of view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> [UIAccessibilityElement] {
        try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement], "the scroll view lists no lines", file: file, line: line)
    }

    /// The characters on screen, by the reader's own account, in the scroll view's text.
    private func shown(_ subject: Subject, file: StaticString = #filePath, line: UInt = #line) throws -> NSRange {
        let range = try XCTUnwrap(subject.canvas.visibleRange, file: file, line: line)
        let book = try XCTUnwrap(subject.canvas.scrollBook, file: file, line: line)
        let start = book.location(of: range.start)
        return NSRange(location: start, length: book.location(of: range.end) - start)
    }

    /// The text of the line holding `location`, as the reader reads it.
    private func lineText(at location: Int, in view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        view.plainText(in: try XCTUnwrap(view.line(containing: location), file: file, line: line).range)
    }

    /// The area of the scroll view not under the bars, in its own coordinates.
    private func visibleArea(of subject: Subject) -> CGRect {
        subject.canvas.scrollVisibleContainerRect.offsetBy(dx: subject.view.containerOrigin.x, dy: subject.view.containerOrigin.y)
    }

    /// VoiceOver moving into the text would meet the first line on screen, and the list is the
    /// lines on screen: nothing above or below them, each where it is drawn.
    private func assertTheListIsTheLinesOnScreen(_ label: String, _ subject: Subject,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let (_, canvas, view) = subject
        let shown = try shown(subject, file: file, line: line)
        let listed = try elements(of: view, file: file, line: line)
        XCTAssertFalse(view.isAccessibilityElement, "\(label): the text view is a container of its lines", file: file, line: line)
        let first = try lineText(at: shown.location, in: view, file: file, line: line)
        XCTAssertEqual(listed.first?.accessibilityLabel, first,
                       "\(label): the first line on screen begins \"\(first.prefix(24))\" and VoiceOver would meet "
                        + "\"\((listed.first?.accessibilityLabel ?? "").prefix(24))\"", file: file, line: line)
        XCTAssertEqual(listed.last?.accessibilityLabel, try lineText(at: NSMaxRange(shown) - 1, in: view, file: file, line: line),
                       "\(label): the last line listed is the last on screen", file: file, line: line)
        XCTAssertEqual(listed.map { $0.accessibilityLabel ?? "" }.joined(), view.plainText(in: shown),
                       "\(label): every character on screen is listed once, in order", file: file, line: line)
        // By the scroll view's own geometry, not only the reader's range: each line is listed
        // by the part of it inside the area the bars leave.
        let area = visibleArea(of: subject).insetBy(dx: -1_000, dy: -0.01)
        for element in listed {
            let frame = element.accessibilityFrameInContainerSpace
            XCTAssertTrue(frame.height > 0 && area.contains(frame),
                          "\(label): \"\((element.accessibilityLabel ?? "").prefix(24))\" is listed at \(frame), outside \(area)",
                          file: file, line: line)
            XCTAssertTrue(element.accessibilityContainer as? ReaderTextView === view, label, file: file, line: line)
            XCTAssertTrue(element.accessibilityTraits.contains(.staticText), label, file: file, line: line)
        }
        // The container protocol agrees with the array.
        XCTAssertEqual(view.accessibilityElementCount(), listed.count, label, file: file, line: line)
        XCTAssertNil(view.accessibilityElement(at: listed.count), label, file: file, line: line)
        for (index, element) in listed.enumerated() {
            XCTAssertTrue(view.accessibilityElement(at: index) as? UIAccessibilityElement === element, label, file: file, line: line)
            XCTAssertEqual(view.index(ofAccessibilityElement: element), index, label, file: file, line: line)
        }
        XCTAssertNil(canvas.currentSelection, "\(label): nothing is selected", file: file, line: line)
        XCTAssertEqual(view.selectedRange.length, 0, "\(label): nothing is selected", file: file, line: line)
    }

    private func unlaidParagraphs(of view: ReaderTextView) -> Int {
        var count = 0
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.readerLayoutManager.documentRange.location, options: []) { fragment in
            if fragment.state != .layoutAvailable { count += 1 }
            return true
        }
        return count
    }

    func testVoiceOverMovingIntoTheTextMeetsTheFirstLineOnScreenWhereverTheReaderIsTaken() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let (reader, canvas, view) = subject
        // From pages in the middle of the book.
        let unlaid = unlaidParagraphs(of: view)
        XCTAssertGreaterThan(unlaid, 100, "most of the book is only estimated")
        XCTAssertEqual(try elements(of: view).first?.accessibilityLabel, "Chapter pass\n")
        try assertTheListIsTheLinesOnScreen("switched from pages", subject)
        XCTAssertEqual(unlaidParagraphs(of: view), unlaid, "listing the lines on screen lays out nothing else")
        // By the table of contents.
        try await reader.session.send(.navigate(href: reader.publication.spine[1].resource.href))
        try await reader.wait("the second chapter") { reader.section == 1 }
        XCTAssertEqual(try elements(of: view).first?.accessibilityLabel, "Chapter harbor\n")
        try assertTheListIsTheLinesOnScreen("chosen from the contents", subject)
        // Scroll Forward and Scroll Backward: a step ends in the middle of a paragraph, and the
        // first line listed is the one on screen, not its paragraph's first.
        let chapter = try XCTUnwrap(canvas.visibleRange)
        try await reader.session.send(.nextPage)
        try await reader.session.send(.nextPage)
        let stepped = try shown(subject)
        XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange).start, chapter.end)
        let text = try XCTUnwrap(view.contentStorage.textStorage).string as NSString
        XCTAssertLessThan(text.paragraphRange(for: NSRange(location: stepped.location, length: 0)).location, stepped.location,
                          "the steps must end inside a paragraph for this to tell its lines apart")
        try assertTheListIsTheLinesOnScreen("two steps forward", subject)
        try await reader.session.send(.previousPage)
        try assertTheListIsTheLinesOnScreen("a step back", subject)
        // The person's own scrolling, which the reader reports a moment later: the list does
        // not wait for the report.
        let before = canvas.visibleRange
        view.contentOffset.y += 2_000
        XCTAssertEqual(canvas.visibleRange, before, "not yet reported")
        let scrolled = try elements(of: view)
        try await reader.wait("the place scrolled to") { canvas.visibleRange != before }
        XCTAssertEqual(try elements(of: view).map(\.accessibilityLabel), scrolled.map(\.accessibilityLabel))
        try assertTheListIsTheLinesOnScreen("scrolled by hand", subject)
        // A new text size rebuilds the text under the same place.
        let place = try XCTUnwrap(canvas.visibleRange?.start)
        try await reader.session.send(.style(EPUBReaderStyle(fontSize: 23, flow: .scrolled)))
        try await reader.settle()
        XCTAssertEqual(canvas.visibleRange?.start.section, place.section)
        try assertTheListIsTheLinesOnScreen("at a larger text size", subject)
        // Paging lists a page's lines with its page actions; a scroll view's lines have none.
        XCTAssertTrue(try elements(of: view).allSatisfy { ($0.accessibilityCustomActions ?? []).isEmpty })
    }

    /// The area UIKit keeps the line under the cursor in: the view less its insets.
    private func cursorArea(of view: ReaderTextView) -> CGRect { view.bounds.inset(by: view.adjustedContentInset) }

    private func postFocus(_ information: [AnyHashable: Any]) {
        NotificationCenter.default.post(name: UIAccessibility.elementFocusedNotification, object: nil, userInfo: information)
    }

    /// The first half of a move of the cursor: UIKit scrolls `element` into view, and the
    /// element left is told and named.
    private func leave(_ previous: NSObject?, for element: NSObject, in view: ReaderTextView) {
        if let frame = (element as? UIAccessibilityElement)?.accessibilityFrameInContainerSpace {
            let area = cursorArea(of: view)
            if frame.minY < area.minY - 0.01 { view.contentOffset.y -= area.minY - frame.minY + 40 }
            else if frame.maxY > area.maxY + 0.01 { view.contentOffset.y += frame.maxY - area.maxY + 40 }
        }
        guard let previous else { return }
        previous.accessibilityElementDidLoseFocus()
        postFocus([UIAccessibility.unfocusedElementUserInfoKey: previous])
    }

    /// Puts the cursor on `element`, a line or a control, as VoiceOver does.
    private func focus(_ element: NSObject, from previous: NSObject?, in view: ReaderTextView) {
        leave(previous, for: element, in: view)
        element.accessibilityElementDidBecomeFocused()
        postFocus([UIAccessibility.focusedElementUserInfoKey: element])
    }

    /// Moves the cursor as VoiceOver's next and previous item do: to the neighbour in the list
    /// the container gives at that moment.
    private func move(from element: UIAccessibilityElement, forward: Bool, in view: ReaderTextView,
                      file: StaticString = #filePath, line: UInt = #line) throws -> UIAccessibilityElement? {
        let index = view.index(ofAccessibilityElement: element)
        XCTAssertNotEqual(index, NSNotFound, "the line under the cursor stays listed", file: file, line: line)
        guard let next = view.accessibilityElement(at: index + (forward ? 1 : -1)) as? UIAccessibilityElement else { return nil }
        focus(next, from: element, in: view)
        XCTAssertTrue(view.accessibilityElement(at: view.index(ofAccessibilityElement: next)) as? UIAccessibilityElement === next,
                      "the line the cursor came to is the element listed for it", file: file, line: line)
        return next
    }

    func testMovingIntoTheTextScrollsNothingThoughTheTopInsetCutsTheFirstLine() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let (_, canvas, view) = subject
        // Leave the first line on screen a third under the top inset, as a scroll step can.
        let top = try XCTUnwrap(view.line(containing: try shown(subject).location + 400))
        view.contentOffset.y = top.frame.minY + view.containerOrigin.y + top.frame.height / 3 - view.adjustedContentInset.top
        let before = canvas.visibleRange
        try await subject.reader.wait("the place scrolled to") { canvas.visibleRange != before }
        let first = try XCTUnwrap(try elements(of: view).first)
        XCTAssertEqual(first.accessibilityLabel, view.plainText(in: top.range), "the line the inset cuts is still the first on screen")
        XCTAssertLessThan(top.frame.minY + view.containerOrigin.y, cursorArea(of: view).minY - 5, "the inset must cut it for this to show anything")
        try assertTheListIsTheLinesOnScreen("with the first line cut", subject)
        // UIKit scrolls a line it finds outside the area; it must find this one inside.
        let offset = view.contentOffset
        focus(first, from: nil, in: view)
        XCTAssertEqual(view.contentOffset, offset, "moving into the text moved the reader")
        XCTAssertTrue(try elements(of: view).contains { $0 === first })
        XCTAssertEqual(canvas.visibleRange?.start, canvas.scrollBook?.position(at: top.range.location))
        XCTAssertNil(canvas.currentSelection)
    }

    func testVoiceOverReadsOnPastTheScreenInBothDirections() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let (_, canvas, view) = subject
        let opening = try shown(subject)
        let onScreen = try elements(of: view)
        var cursor = try XCTUnwrap(onScreen.first)
        focus(cursor, from: nil, in: view)
        // With the cursor in the text, two lines each side of the screen are listed too, and the
        // lines on screen are the same elements as before.
        let listed = try elements(of: view)
        XCTAssertEqual(listed.count, onScreen.count + 4)
        XCTAssertTrue(zip(listed.dropFirst(2), onScreen).allSatisfy { $0 === $1 }, "a line keeps its element while it is listed")
        XCTAssertEqual(listed.prefix(2).map { $0.accessibilityLabel ?? "" }.joined() + view.plainText(in: opening)
                        + listed.suffix(2).map { $0.accessibilityLabel ?? "" }.joined(),
                       listed.map { $0.accessibilityLabel ?? "" }.joined())
        XCTAssertEqual(listed[1].accessibilityLabel, try lineText(at: opening.location - 1, in: view))
        XCTAssertEqual(listed[listed.count - 2].accessibilityLabel, try lineText(at: NSMaxRange(opening), in: view))
        XCTAssertEqual(try shown(subject), opening, "listing them moves nothing")
        // The line left is told and named before the line reached is. Between the two the list
        // must not change: when it shrank to the screen there, VoiceOver stopped at a line it
        // had reached above the screen and would not move back from it.
        leave(cursor, for: listed[3], in: view)
        XCTAssertEqual(try elements(of: view).count, listed.count)
        XCTAssertTrue(zip(try elements(of: view), listed).allSatisfy { $0 === $1 })
        focus(listed[3], from: nil, in: view)
        cursor = listed[3]
        XCTAssertTrue(zip(try elements(of: view), listed).allSatisfy { $0 === $1 }, "a move down the screen changes nothing")

        // Forward through more than three screens: every line once, in order, each with a line
        // listed after it to go on to, and the view following.
        var read = listed[2...3].map { $0.accessibilityLabel ?? "" }.joined()
        for _ in 0..<(onScreen.count * 3 + 5) {
            cursor = try XCTUnwrap(try move(from: cursor, forward: true, in: view), "the text goes on past the screen")
            read += cursor.accessibilityLabel ?? ""
            XCTAssertTrue(cursorArea(of: view).insetBy(dx: -1_000, dy: -0.01).contains(cursor.accessibilityFrameInContainerSpace),
                          "\"\((cursor.accessibilityLabel ?? "").prefix(24))\" is not where the cursor can be seen")
        }
        XCTAssertEqual(read, view.plainText(in: NSRange(location: opening.location, length: (read as NSString).length)),
                       "reading on gives the book's text from the first line on screen, nothing skipped or repeated")
        try await subject.reader.wait("the place read to") { (try? self.shown(subject).location) ?? 0 > NSMaxRange(opening) }
        XCTAssertEqual(canvas.visibleRange?.start.section, 3)

        // And back, past the top of the screen it started on, from the line read last.
        let readEnd = opening.location + (read as NSString).length
        var back = cursor.accessibilityLabel ?? ""
        for _ in 0..<(onScreen.count * 4 + 5) {
            cursor = try XCTUnwrap(try move(from: cursor, forward: false, in: view), "the text goes back past the screen")
            back = (cursor.accessibilityLabel ?? "") + back
            XCTAssertTrue(cursorArea(of: view).insetBy(dx: -1_000, dy: -0.01).contains(cursor.accessibilityFrameInContainerSpace),
                          "\"\((cursor.accessibilityLabel ?? "").prefix(24))\" is not where the cursor can be seen")
        }
        let length = (back as NSString).length
        XCTAssertEqual(back, view.plainText(in: NSRange(location: readEnd - length, length: length)),
                       "reading back gives the same text, nothing skipped or repeated")
        XCTAssertLessThan(readEnd - length, opening.location, "back past the first line it entered at")

        // The cursor goes to a control: the list is the lines on screen again, first line first.
        let control = NSObject()
        focus(control, from: cursor, in: view)
        try await subject.reader.wait("the place read back to") {
            (try? self.shown(subject).location) == canvas.scrollVisibleCharacters()?.location
        }
        try assertTheListIsTheLinesOnScreen("after the cursor left", subject)
        // So it is when VoiceOver is switched off with its cursor in the text.
        let first = try XCTUnwrap(try elements(of: view).first)
        focus(first, from: control, in: view)
        XCTAssertEqual(try elements(of: view).count, view.accessibilityElementCount())
        XCTAssertFalse(try elements(of: view).first === first, "lines before the screen are listed again")
        NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        XCTAssertTrue(try elements(of: view).first === first)
        try assertTheListIsTheLinesOnScreen("after VoiceOver was switched off", subject)
    }

    func testAnElementKeptFromAnEarlierListStandsForItsLine() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let view = subject.view
        let kept = try elements(of: view)
        let offset = view.contentOffset
        view.contentOffset.y += 3_000
        XCTAssertFalse(try elements(of: view).contains { element in kept.contains { $0 === element } })
        XCTAssertEqual(view.index(ofAccessibilityElement: kept[0]), NSNotFound, "its line is no longer listed")
        view.contentOffset = offset
        let listed = try elements(of: view)
        XCTAssertEqual(listed.map(\.accessibilityLabel), kept.map(\.accessibilityLabel))
        XCTAssertFalse(listed[2] === kept[2])
        XCTAssertEqual(view.index(ofAccessibilityElement: kept[2]), 2)
        XCTAssertEqual(view.index(ofAccessibilityElement: NSObject()), NSNotFound)
    }

    func testANoteKeepsUIKitsOwnTextElements() {
        // A note's popover is a text view of its own, never scrolled by the reader: its text
        // starts at its first line, which is where UIKit's elements start.
        let note = ReaderNoteViewController(text: CanvasText.body("A note."), dark: false, width: 300)
        XCTAssertNil(note.textView.accessibilityElements as? [UIAccessibilityElement])
    }
}
#endif
