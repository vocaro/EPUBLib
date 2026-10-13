#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// Where VoiceOver starts reading in continuous scroll on iPhone and iPad, and how far it can
/// read on (doc/native-viewer.md "Continuous scroll"): it walks the scroll view's accessibility
/// elements and takes the first when it moves in from a control, so the reader lists the lines
/// on screen and the fifty after them, and fifty each way while VoiceOver's cursor is in the
/// text.
///
/// No assistive technology is driven here, and UIKit's accessibility is not loaded in a test
/// host. The tests read the elements through the container protocol VoiceOver uses and stand in
/// for it with what a simulator's VoiceOver was seen to do on 2026-10-12. For a move of its
/// cursor (`focus`, `move`): UIKit scrolls the line the cursor is going to, until the area the
/// insets leave holds its frame and then 40 points further; the line left is told so; a focus
/// notification names only the element left; the line reached is told so; a second
/// notification names it. For the items it asks UIKit for (`items`): those after or before the
/// one its cursor is on, as the container lists them at that moment, two as a rule and fifty at
/// its first move after a menu closes, which it then moves through without asking again. For a
/// move to the scroll view's own scroll bar (`bringScrollBarIntoView`): UIKit brings the bar
/// into view as it would a line, before VoiceOver asks for anything more.
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

    /// The lines the scroll view lists. Its own scroll bar, a view, is listed after them while
    /// VoiceOver's cursor is going to it or on it.
    private func elements(of view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> [UIAccessibilityElement] {
        let listed = try XCTUnwrap(view.accessibilityElements, "the scroll view lists no lines", file: file, line: line)
        XCTAssertTrue(listed.dropLast().allSatisfy { $0 is UIAccessibilityElement }, "only the last item listed can be the bar", file: file, line: line)
        return listed.compactMap { $0 as? UIAccessibilityElement }
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

    /// The labels of `elements` one after another, as the text they are read from has them: a
    /// heading's label is its words, and the break that ends its paragraph follows them.
    private func text(of elements: some Sequence<UIAccessibilityElement>) -> String {
        elements.map { ($0.accessibilityLabel ?? "") + ($0.accessibilityTraits.contains(.header) ? "\n" : "") }.joined()
    }

    /// The area of the scroll view not under the bars, in its own coordinates.
    private func visibleArea(of subject: Subject) -> CGRect {
        subject.canvas.scrollVisibleContainerRect.offsetBy(dx: subject.view.containerOrigin.x, dy: subject.view.containerOrigin.y)
    }

    /// How many lines the reader lists past the screen: the items VoiceOver asks for at once.
    private let past = 50

    /// The lines on screen among `listed`, which starts with them.
    private func onScreen(_ listed: [UIAccessibilityElement], _ subject: Subject,
                          file: StaticString = #filePath, line: UInt = #line) throws -> [UIAccessibilityElement] {
        let shownText = subject.view.plainText(in: try shown(subject, file: file, line: line))
        for count in 1...max(1, listed.count) {
            let lines = Array(listed.prefix(count))
            if text(of: lines) == shownText { return lines }
        }
        XCTFail("the list does not start with the lines on screen", file: file, line: line)
        return []
    }

    /// VoiceOver moving into the text would meet the first line on screen: the list is the
    /// lines on screen, each where it is drawn, then the fifty after them and nothing else.
    private func assertTheListIsTheScreenAndTheLinesAfterIt(_ label: String, _ subject: Subject,
                                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let (_, canvas, view) = subject
        let shown = try shown(subject, file: file, line: line)
        let listed = try elements(of: view, file: file, line: line)
        XCTAssertFalse(view.isAccessibilityElement, "\(label): the text view is a container of its lines", file: file, line: line)
        let first = try lineText(at: shown.location, in: view, file: file, line: line)
        XCTAssertEqual(text(of: listed.prefix(1)), first,
                       "\(label): the first line on screen begins \"\(first.prefix(24))\" and VoiceOver would meet "
                        + "\"\((listed.first?.accessibilityLabel ?? "").prefix(24))\"", file: file, line: line)
        let screen = try onScreen(listed, subject, file: file, line: line)
        XCTAssertEqual(text(of: screen.suffix(1)), try lineText(at: NSMaxRange(shown) - 1, in: view, file: file, line: line),
                       "\(label): the last of them is the last line on screen", file: file, line: line)
        // By the scroll view's own geometry, not only the reader's range: each line on screen is
        // listed by the part of it inside the area the bars leave.
        let area = visibleArea(of: subject).insetBy(dx: -1_000, dy: -0.01)
        for element in screen {
            let frame = element.accessibilityFrameInContainerSpace
            XCTAssertTrue(frame.height > 0 && area.contains(frame),
                          "\(label): \"\((element.accessibilityLabel ?? "").prefix(24))\" is listed at \(frame), outside \(area)",
                          file: file, line: line)
        }
        // The lines after the screen follow in the book's order, each below the one before.
        var after: [String] = [], end = NSMaxRange(shown)
        while after.count < past, end < view.textLength, let next = view.line(containing: end) {
            after.append(view.plainText(in: next.range))
            end = NSMaxRange(next.range)
        }
        XCTAssertEqual(text(of: listed.dropFirst(screen.count)), after.joined(),
                       "\(label): the \(after.count) lines after the screen are listed after it, and no more", file: file, line: line)
        XCTAssertEqual(text(of: listed), view.plainText(in: NSRange(location: shown.location, length: end - shown.location)),
                       "\(label): every character from the first line on screen is listed once, in order", file: file, line: line)
        for (above, below) in zip(listed, listed.dropFirst()) {
            XCTAssertLessThanOrEqual(above.accessibilityFrameInContainerSpace.minY, below.accessibilityFrameInContainerSpace.minY,
                                     "\(label): \"\((below.accessibilityLabel ?? "").prefix(24))\" is listed above the line before it",
                                     file: file, line: line)
        }
        for element in listed {
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
        XCTAssertEqual(try elements(of: view).first?.accessibilityLabel, "Chapter pass", "a heading is read as its words")
        try assertTheListIsTheScreenAndTheLinesAfterIt("switched from pages", subject)
        XCTAssertGreaterThan(unlaidParagraphs(of: view), unlaid - 20, "listing them lays out the fifty lines after the screen and no more")
        // By the table of contents.
        try await reader.session.send(.navigate(href: reader.publication.spine[1].resource.href))
        try await reader.wait("the second chapter") { reader.section == 1 }
        XCTAssertEqual(try elements(of: view).first?.accessibilityLabel, "Chapter harbor", "a heading is read as its words")
        try assertTheListIsTheScreenAndTheLinesAfterIt("chosen from the contents", subject)
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
        try assertTheListIsTheScreenAndTheLinesAfterIt("two steps forward", subject)
        try await reader.session.send(.previousPage)
        try assertTheListIsTheScreenAndTheLinesAfterIt("a step back", subject)
        // The person's own scrolling, which the reader reports a moment later: the list does
        // not wait for the report.
        let before = canvas.visibleRange
        view.contentOffset.y += 2_000
        XCTAssertEqual(canvas.visibleRange, before, "not yet reported")
        let scrolled = try elements(of: view)
        try await reader.wait("the place scrolled to") { canvas.visibleRange != before }
        XCTAssertEqual(try elements(of: view).map(\.accessibilityLabel), scrolled.map(\.accessibilityLabel))
        try assertTheListIsTheScreenAndTheLinesAfterIt("scrolled by hand", subject)
        // A new text size rebuilds the text under the same place.
        let place = try XCTUnwrap(canvas.visibleRange?.start)
        try await reader.session.send(.style(EPUBReaderStyle(fontSize: 23, flow: .scrolled)))
        try await reader.settle()
        XCTAssertEqual(canvas.visibleRange?.start.section, place.section)
        try assertTheListIsTheScreenAndTheLinesAfterIt("at a larger text size", subject)
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
        // Where the line is drawn in the view, read afresh each time: measuring the lines
        // listed past the screen can change TextKit's estimate of the text above, and the
        // line's place in the content and the view's offset then move together.
        func drawnTop() throws -> CGFloat {
            try XCTUnwrap(view.line(containing: top.range.location)).frame.minY + view.containerOrigin.y - view.contentOffset.y
        }
        XCTAssertLessThan(try drawnTop(), view.adjustedContentInset.top - 5, "the inset must cut it for this to show anything")
        try assertTheListIsTheScreenAndTheLinesAfterIt("with the first line cut", subject)
        // UIKit scrolls a line it finds outside the area; it must find this one inside.
        let drawn = try drawnTop()
        focus(first, from: nil, in: view)
        XCTAssertEqual(try drawnTop(), drawn, accuracy: 0.01, "moving into the text moved the reader")
        XCTAssertTrue(try elements(of: view).contains { $0 === first })
        XCTAssertEqual(canvas.visibleRange?.start, canvas.scrollBook?.position(at: top.range.location))
        XCTAssertNil(canvas.currentSelection)
    }

    func testVoiceOverReadsOnPastTheScreenInBothDirections() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let (_, canvas, view) = subject
        let opening = try shown(subject)
        let before = try elements(of: view)
        let screen = try onScreen(before, subject).count
        var cursor = try XCTUnwrap(before.first)
        focus(cursor, from: nil, in: view)
        // With the cursor in the text, the fifty lines before the screen are listed too, and the
        // lines listed already are the same elements as before.
        let listed = try elements(of: view)
        XCTAssertEqual(listed.count, before.count + past)
        XCTAssertEqual(before.count, screen + past)
        XCTAssertTrue(zip(listed.dropFirst(past), before).allSatisfy { $0 === $1 }, "a line keeps its element while it is listed")
        XCTAssertEqual(text(of: listed.prefix(past)) + view.plainText(in: opening) + text(of: listed.suffix(past)), text(of: listed))
        XCTAssertEqual(listed[past - 1].accessibilityLabel, try lineText(at: opening.location - 1, in: view))
        XCTAssertEqual(listed[past + screen].accessibilityLabel, try lineText(at: NSMaxRange(opening), in: view))
        XCTAssertEqual(try shown(subject), opening, "listing them moves nothing")
        // The line left is told and named before the line reached is. Between the two the list
        // must not change: when it shrank to the screen there, VoiceOver stopped at a line it
        // had reached above the screen and would not move back from it.
        leave(cursor, for: listed[past + 1], in: view)
        XCTAssertEqual(try elements(of: view).count, listed.count)
        XCTAssertTrue(zip(try elements(of: view), listed).allSatisfy { $0 === $1 })
        focus(listed[past + 1], from: nil, in: view)
        cursor = listed[past + 1]
        XCTAssertTrue(zip(try elements(of: view), listed).allSatisfy { $0 === $1 }, "a move down the screen changes nothing")

        // Forward through more than three screens: every line once, in order, each with a line
        // listed after it to go on to, and the view following.
        var read = text(of: listed[past...(past + 1)])
        for _ in 0..<(screen * 3 + 5) {
            cursor = try XCTUnwrap(try move(from: cursor, forward: true, in: view), "the text goes on past the screen")
            read += text(of: [cursor])
            XCTAssertTrue(cursorArea(of: view).insetBy(dx: -1_000, dy: -0.01).contains(cursor.accessibilityFrameInContainerSpace),
                          "\"\((cursor.accessibilityLabel ?? "").prefix(24))\" is not where the cursor can be seen")
        }
        XCTAssertEqual(read, view.plainText(in: NSRange(location: opening.location, length: (read as NSString).length)),
                       "reading on gives the book's text from the first line on screen, nothing skipped or repeated")
        try await subject.reader.wait("the place read to") { (try? self.shown(subject).location) ?? 0 > NSMaxRange(opening) }
        XCTAssertEqual(canvas.visibleRange?.start.section, 3)

        // And back, past the top of the screen it started on, from the line read last.
        let readEnd = opening.location + (read as NSString).length
        var back = text(of: [cursor])
        for _ in 0..<(screen * 4 + 5) {
            cursor = try XCTUnwrap(try move(from: cursor, forward: false, in: view), "the text goes back past the screen")
            back = text(of: [cursor]) + back
            XCTAssertTrue(cursorArea(of: view).insetBy(dx: -1_000, dy: -0.01).contains(cursor.accessibilityFrameInContainerSpace),
                          "\"\((cursor.accessibilityLabel ?? "").prefix(24))\" is not where the cursor can be seen")
        }
        let length = (back as NSString).length
        XCTAssertEqual(back, view.plainText(in: NSRange(location: readEnd - length, length: length)),
                       "reading back gives the same text, nothing skipped or repeated")
        XCTAssertLessThan(readEnd - length, opening.location, "back past the first line it entered at")

        // The cursor goes to a control: the list starts at the first line on screen again.
        let control = NSObject()
        focus(control, from: cursor, in: view)
        try await subject.reader.wait("the place read back to") {
            (try? self.shown(subject).location) == canvas.scrollVisibleCharacters()?.location
        }
        try assertTheListIsTheScreenAndTheLinesAfterIt("after the cursor left", subject)
        // So it is when VoiceOver is switched off with its cursor in the text.
        let first = try XCTUnwrap(try elements(of: view).first)
        focus(first, from: control, in: view)
        XCTAssertEqual(try elements(of: view).count, view.accessibilityElementCount())
        XCTAssertFalse(try elements(of: view).first === first, "lines before the screen are listed again")
        NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        XCTAssertTrue(try elements(of: view).first === first)
        try assertTheListIsTheScreenAndTheLinesAfterIt("after VoiceOver was switched off", subject)
    }

    func testAnElementKeptFromAnEarlierListStandsForItsLine() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let view = subject.view
        let kept = try elements(of: view)
        let offset = view.contentOffset
        view.contentOffset.y += 6_000
        XCTAssertFalse(try elements(of: view).contains { element in kept.contains { $0 === element } })
        XCTAssertEqual(view.index(ofAccessibilityElement: kept[0]), NSNotFound, "its line is no longer listed")
        view.contentOffset = offset
        let listed = try elements(of: view)
        XCTAssertEqual(listed.map(\.accessibilityLabel), kept.map(\.accessibilityLabel))
        XCTAssertFalse(listed[2] === kept[2])
        XCTAssertEqual(view.index(ofAccessibilityElement: kept[2]), 2)
        XCTAssertEqual(view.index(ofAccessibilityElement: NSObject()), NSNotFound)
    }

    /// A hidden heading over a table that opens a chapter is a line of hidden labels alone. It
    /// has no height, so with the table at the top it is not the first line on screen, and
    /// VoiceOver moving into the text still meets it first, at a place inside the reading area,
    /// so nothing scrolls as it comes in.
    func testHiddenLabelsStandingAtTheTopAreListedBeforeTheFirstLineOnScreen() async throws {
        let prose = (1...40).map { "<p>p\($0) " + CanvasText.sentence(50, seed: $0) + "</p>" }.joined()
        let table = "<table><tr><td>First cell</td><td>Second cell</td></tr><tr><td>Third cell</td><td>Fourth cell</td></tr></table>"
        let reader = try SessionCoverageReader(try SessionCoverageBook.epub([
            SessionCoverageBook.Section("front", "<h1>Front</h1>" + prose, title: "Front"),
            SessionCoverageBook.Section("tables", "<h1 style='position: absolute; left: -999em'>Hidden table heading</h1>" + table + prose,
                                        title: "Tables")]))
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.navigate(href: reader.publication.spine[1].resource.href))
        try await reader.wait("the second chapter") { reader.section == 1 }
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas), view = try XCTUnwrap(canvas.scrollTextView)
        let book = try XCTUnwrap(canvas.scrollBook)
        let labels = try XCTUnwrap(view.hiddenLabelsAlone(at: book.location(of: ReaderTextPosition(section: 1, offset: 0))),
                                   "the chapter opens with a line of hidden labels alone")
        XCTAssertEqual(canvas.visibleRange?.start, book.position(at: NSMaxRange(labels)), "the table's first row is the first line on screen")
        let listed = try elements(of: view)
        let first = try XCTUnwrap(listed.first)
        XCTAssertEqual(first.accessibilityLabel, "Hidden table heading")
        XCTAssertFalse(first.accessibilityTraits.contains(.image), "words, not a picture")
        XCTAssertTrue(first.accessibilityTraits.contains(.header), "a heading, though the page shows none of it")
        XCTAssertTrue(listed.dropFirst().first?.accessibilityLabel?.contains("First cell") ?? false,
                      "then the row: \(listed.dropFirst().first?.accessibilityLabel ?? "nothing")")
        let area = canvas.scrollVisibleContainerRect.offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y)
        XCTAssertTrue(area.insetBy(dx: -0.01, dy: -0.01).contains(first.accessibilityFrameInContainerSpace),
                      "\(first.accessibilityFrameInContainerSpace) in \(area)")
    }

    /// The items UIKit hands VoiceOver when it asks for the `count` after `element`, or before
    /// it: the scroll view's elements in order from that one, as listed at that moment. From a
    /// control outside the text (`nil`) they start at the list's near end.
    private func items(_ count: Int, after element: UIAccessibilityElement?, forward: Bool = true, in view: ReaderTextView,
                       file: StaticString = #filePath, line: UInt = #line) -> [UIAccessibilityElement] {
        let listed = view.accessibilityElementCount()
        var index = forward ? 0 : listed - 1
        if let element {
            let own = view.index(ofAccessibilityElement: element)
            XCTAssertNotEqual(own, NSNotFound, "the line VoiceOver asks from is still listed", file: file, line: line)
            index = own + (forward ? 1 : -1)
        }
        var items: [UIAccessibilityElement] = []
        while items.count < count, index >= 0, index < listed, let item = view.accessibilityElement(at: index) as? UIAccessibilityElement {
            items.append(item)
            index += forward ? 1 : -1
        }
        return items
    }

    /// Straight after a menu closes VoiceOver has nothing noted. At its first move it asks for
    /// the fifty items after its cursor and moves through those without asking again, so they
    /// must be the book's lines, as many as it asks for: given the lines on screen alone it read
    /// to the last of them and went on to the scroll bar (#339).
    func testVoiceOverGivenFiftyItemsAtOnceReadsOnPastTheScreen() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let (_, canvas, view) = subject
        let opening = try shown(subject)
        let screen = try onScreen(try elements(of: view), subject).count
        // Its cursor is on Contents. Four of the fifty are the controls between that and the text.
        let control = NSObject()
        focus(control, from: nil, in: view)
        let given = items(46, after: nil, in: view)
        XCTAssertEqual(given.count, 46, "VoiceOver asked for 46 lines and the screen holds \(screen)")
        XCTAssertEqual(text(of: given.prefix(1)), try lineText(at: opening.location, in: view), "it comes in at the first line on screen")
        XCTAssertEqual(try shown(subject), opening, "listing them moves nothing")
        // It moves through them: each is still the element listed for its line when the cursor
        // comes to it, and UIKit has scrolled it into view.
        var previous: NSObject = control, read = ""
        for item in given {
            focus(item, from: previous, in: view)
            XCTAssertTrue(view.accessibilityElement(at: view.index(ofAccessibilityElement: item)) as? UIAccessibilityElement === item,
                          "\"\((item.accessibilityLabel ?? "").prefix(24))\" is no longer the element listed for its line")
            XCTAssertTrue(cursorArea(of: view).insetBy(dx: -1_000, dy: -0.01).contains(item.accessibilityFrameInContainerSpace),
                          "\"\((item.accessibilityLabel ?? "").prefix(24))\" is not where the cursor can be seen")
            read += text(of: [item])
            previous = item
        }
        var end = opening.location + (read as NSString).length
        XCTAssertEqual(read, view.plainText(in: NSRange(location: opening.location, length: end - opening.location)),
                       "the book's text from the first line on screen, nothing skipped or repeated")
        try await subject.reader.wait("the place read to") { (try? self.shown(subject).location) ?? 0 > opening.location }
        XCTAssertEqual(canvas.visibleRange?.start.section, 3)
        // Having used them it asks from the last. Were its cursor to come back to a line after
        // a menu, that would again be for fifty, in either direction.
        let last = try XCTUnwrap(given.last)
        let more = items(past, after: last, in: view)
        XCTAssertEqual(more.count, past, "fifty lines follow the cursor's")
        let following = text(of: more)
        XCTAssertEqual(following, view.plainText(in: NSRange(location: end, length: (following as NSString).length)))
        let back = items(past, after: last, forward: false, in: view)
        XCTAssertEqual(back.count, past, "and fifty come before it")
        XCTAssertTrue(zip(back, given.dropLast().reversed()).allSatisfy { $0 === $1 }, "those it has read are the same elements")
        let preceding = text(of: back.reversed())
        end -= (text(of: [last]) as NSString).length
        XCTAssertEqual(preceding, view.plainText(in: NSRange(location: end - (preceding as NSString).length, length: (preceding as NSString).length)))
        XCTAssertLessThan(end - (preceding as NSString).length, opening.location, "back past the line it came in at")
        XCTAssertNil(canvas.currentSelection)
    }

    /// Moving back into the text from below, VoiceOver takes the last line listed. While its
    /// cursor is on one of the scroll view's bars or on something below the reading area, that
    /// is the last line on screen: the lines after the screen are not listed, nor any before it.
    func testVoiceOverMovingBackIntoTheTextFromBelowMeetsTheLastLineOnScreen() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let view = subject.view
        try await subject.reader.session.send(.nextPage)
        let opening = try shown(subject)
        let ahead = try elements(of: view)
        let unlaid = unlaidParagraphs(of: view)
        let area = UIAccessibility.convertToScreenCoordinates(visibleArea(of: subject), in: view)
        func item(at y: CGFloat) -> NSObject { PlacedItem(frame: CGRect(x: area.minX, y: y, width: 120, height: 30)) }
        // The scroll bar is a view of the scroll view's own, and UIKit lists it after the lines.
        let bar = UIView(frame: CGRect(x: view.bounds.maxX - 6, y: view.bounds.midY, width: 3, height: 40))
        view.addSubview(bar)
        defer { bar.removeFromSuperview() }
        for (name, below) in [("a control below the reader", item(at: area.maxY + 8)), ("the scroll bar", bar)] {
            focus(below, from: nil, in: view)
            let listed = try elements(of: view)
            XCTAssertEqual(text(of: listed), view.plainText(in: opening), "\(name): the lines on screen and no others")
            XCTAssertEqual(listed.last?.accessibilityLabel, try lineText(at: NSMaxRange(opening) - 1, in: view),
                           "\(name): VoiceOver would meet the last line on screen")
            XCTAssertTrue(zip(listed, ahead).allSatisfy { $0 === $1 }, "\(name): the lines on screen keep their elements")
            XCTAssertEqual(view.accessibilityElementCount(), listed.count, name)
            XCTAssertEqual(try shown(subject), opening, "\(name): listing them moves nothing")
            XCTAssertEqual(unlaidParagraphs(of: view), unlaid, "\(name): and lays out nothing")
            // It asks for two before the control, takes the scroll bar and the last line on
            // screen, and from that line for the one before it.
            let last = try XCTUnwrap(items(1, after: nil, forward: false, in: view).first)
            XCTAssertTrue(last === listed.last, name)
            XCTAssertTrue(items(1, after: last, forward: false, in: view).first === listed.dropLast().last, name)
            // A control above the reading area, or one beside it, comes before the text.
            focus(item(at: area.minY - 60), from: below, in: view)
            try assertTheListIsTheScreenAndTheLinesAfterIt("\(name), then a control above", subject)
            focus(below, from: nil, in: view)
            focus(item(at: area.midY), from: below, in: view)
            try assertTheListIsTheScreenAndTheLinesAfterIt("\(name), then a control beside the text", subject)
        }
        // The cursor comes to the last line on screen, which UIKit brings clear of the bottom
        // inset: fifty lines each side of the screen are listed, and the lines VoiceOver was
        // given, those that were on screen, are the same elements.
        focus(bar, from: nil, in: view)
        let given = try elements(of: view)
        let last = try XCTUnwrap(given.last)
        focus(last, from: bar, in: view)
        let listed = try elements(of: view), now = try XCTUnwrap(subject.canvas.scrollVisibleCharacters())
        XCTAssertTrue(listed[view.index(ofAccessibilityElement: last)] === last)
        XCTAssertEqual(listed[past].accessibilityLabel, try lineText(at: now.location, in: view), "fifty lines are listed before the screen")
        XCTAssertEqual(listed[listed.count - past - 1].accessibilityLabel, try lineText(at: NSMaxRange(now) - 1, in: view), "and fifty after it")
        XCTAssertTrue(given.allSatisfy { line in listed.contains { $0 === line } })
    }

    /// What UIKit does when VoiceOver's cursor is about to go to the scroll view's own scroll
    /// bar: it brings the bar into view as it would a line. The bar is as tall as the view, so
    /// the top inset cuts it, and the view goes back by that inset and 40 points more, as far
    /// as it has the room.
    private func bringScrollBarIntoView(_ view: ReaderTextView) {
        let top = view.adjustedContentInset.top
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: max(-top, view.contentOffset.y - top - 40)), animated: false)
    }

    /// Away from the top of the book the view goes back under VoiceOver as it moves from a
    /// control below the reader to the scroll bar, after it was given the last line on screen
    /// and before it asks for the line before that one. The line stays listed through that
    /// move, with the lines between it and the screen, so VoiceOver reads back up the screen a
    /// line at a time and on above it. No longer listed, the line led to the control before
    /// the text (#367).
    func testVoiceOverReadsBackUpTheScreenFromBelowThoughTheViewGoesBackForTheScrollBar() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let (reader, canvas, view) = subject
        try await reader.session.send(.nextPage)
        try await reader.session.send(.nextPage)
        let opening = try shown(subject)
        let screen = try onScreen(try elements(of: view), subject).count
        let area = UIAccessibility.convertToScreenCoordinates(visibleArea(of: subject), in: view)
        let footer = PlacedItem(frame: CGRect(x: area.minX, y: area.maxY + 8, width: 120, height: 30))
        let bar = UIView(frame: CGRect(x: view.bounds.maxX - 6, y: view.bounds.midY, width: 3, height: 40))
        view.addSubview(bar)
        defer { bar.removeFromSuperview() }
        func labels(_ elements: [UIAccessibilityElement]) -> String { elements.map { $0.accessibilityLabel ?? "" }.joined() }
        /// The lines on screen at this moment: the reader reports a move of UIKit's a moment later.
        func onScreenNow() throws -> NSRange { try XCTUnwrap(canvas.scrollVisibleCharacters()) }

        // Its cursor lands on the control. It asks for the two items before it and is given
        // the scroll bar and the last line on screen.
        focus(footer, from: nil, in: view)
        let last = try XCTUnwrap(view.line(containing: NSMaxRange(opening) - 1)).range
        let given = try XCTUnwrap(items(1, after: nil, forward: false, in: view).first)
        XCTAssertEqual(given.accessibilityLabel, view.plainText(in: last))
        // It moves to the bar. UIKit brings the bar into view first, and the line VoiceOver
        // holds is then below the screen.
        let offset = view.contentOffset.y
        bringScrollBarIntoView(view)
        XCTAssertEqual(offset - view.contentOffset.y, view.adjustedContentInset.top + 40, accuracy: 0.01, "the view must have the room to go back")
        let back = try onScreenNow()
        XCTAssertLessThan(NSMaxRange(back), last.location, "the line VoiceOver holds must be below the screen for this to show anything")
        // Then it asks for the item before that line, and only then is its cursor on the bar.
        let above = try XCTUnwrap(items(1, after: given, forward: false, in: view).first, "a line comes before the one VoiceOver holds")
        XCTAssertEqual(above.accessibilityLabel, try lineText(at: last.location - 1, in: view), "the line above it")
        focus(bar, from: footer, in: view)
        var listed = try elements(of: view)
        XCTAssertTrue(listed.last === given, "the line VoiceOver holds is the last listed, and the same element")
        XCTAssertEqual(labels(listed), view.plainText(in: NSRange(location: back.location, length: NSMaxRange(last) - back.location)),
                       "the lines on screen and those down to the line VoiceOver holds, each once and in order")
        XCTAssertEqual(view.accessibilityElementCount(), listed.count)
        XCTAssertEqual(try onScreenNow(), back, "listing them moves nothing")
        XCTAssertNil(canvas.currentSelection)
        // It moves to the line it holds. UIKit brings that line clear of the bottom inset, it
        // asks for the item before the furthest it holds, and then its cursor is in the text.
        leave(bar, for: given, in: view)
        XCTAssertTrue(cursorArea(of: view).insetBy(dx: -1_000, dy: -0.01).contains(given.accessibilityFrameInContainerSpace))
        let third = try XCTUnwrap(items(1, after: above, forward: false, in: view).first, "the line above is on screen and listed")
        focus(given, from: nil, in: view)
        listed = try elements(of: view)
        let own = view.index(ofAccessibilityElement: given)
        XCTAssertTrue(listed[own] === given && listed[own - 1] === above && listed[own - 2] === third,
                      "the lines VoiceOver was given are the elements listed once its cursor is in the text")
        // On up the screen and past its top: every line once, in order.
        var cursor = given, read = given.accessibilityLabel ?? ""
        for _ in 0..<(screen + 6) {
            cursor = try XCTUnwrap(try move(from: cursor, forward: false, in: view), "the text goes back past the screen")
            read = (cursor.accessibilityLabel ?? "") + read
        }
        let length = (read as NSString).length
        XCTAssertEqual(read, view.plainText(in: NSRange(location: NSMaxRange(last) - length, length: length)),
                       "reading back gives the book's text up from the last line that was on screen, nothing skipped or repeated")
        XCTAssertLessThan(NSMaxRange(last) - length, opening.location, "back past the first line that was on screen")

        // Letting go. With the cursor below the text again, a step of the reader's own takes
        // the view further than UIKit's move for the bar does: the list is the lines on screen
        // alone, and VoiceOver would meet the last of them.
        focus(footer, from: cursor, in: view)
        _ = items(1, after: nil, forward: false, in: view)
        try await reader.session.send(.previousPage)
        XCTAssertEqual(labels(try elements(of: view)), view.plainText(in: try onScreenNow()), "after a step back, the lines on screen and no others")
        try await reader.session.send(.nextPage)
        try await reader.session.send(.nextPage)
        XCTAssertEqual(labels(try elements(of: view)), view.plainText(in: try onScreenNow()), "after steps forward, the lines on screen and no others")
        // The cursor goes to the bar, the control is touched again and the cursor goes to the
        // bar a second time. The view goes back each time, and VoiceOver asks nothing new the
        // second time: it holds the bar, the line it was given first and the line before that.
        // UIKit looks that line up before bringing it into view, so it is still listed.
        let held = try XCTUnwrap(items(1, after: nil, forward: false, in: view).first)
        let end = NSMaxRange(try onScreenNow())
        bringScrollBarIntoView(view)
        let before = try XCTUnwrap(items(1, after: held, forward: false, in: view).first, "a line comes before the one VoiceOver holds")
        focus(bar, from: footer, in: view)
        focus(footer, from: bar, in: view)
        bringScrollBarIntoView(view)
        focus(bar, from: footer, in: view)
        listed = try elements(of: view)
        XCTAssertNotEqual(view.index(ofAccessibilityElement: held), NSNotFound, "the line VoiceOver holds is listed after a second move for the bar")
        XCTAssertTrue(listed.last === held && listed.dropLast().last === before)
        let twice = try onScreenNow()
        XCTAssertEqual(labels(listed), view.plainText(in: NSRange(location: twice.location, length: end - twice.location)),
                       "after two moves for the bar, the lines on screen and those down to the line VoiceOver holds")
        // A control before the text: VoiceOver moving into the text meets the first line on
        // screen, and the lines it held below the screen are listed as any others after it.
        focus(PlacedItem(frame: CGRect(x: area.minX, y: area.minY - 60, width: 120, height: 30)), from: bar, in: view)
        try await reader.wait("the place the bar left the view at") { (try? self.shown(subject)) == canvas.scrollVisibleCharacters() }
        try assertTheListIsTheScreenAndTheLinesAfterIt("after the cursor left for a control above", subject)
    }

    /// Reading forward past the book's last line VoiceOver is given the scroll view's own scroll
    /// bar, and asks UIKit for the items each side of the bar. UIKit keeps a scroll view's bar
    /// among its supplementary headers and held it to stand before the first line: the item
    /// after it was the first line listed, so VoiceOver read down the screen a second time, and
    /// the item before it was the control before the text. A bar hidden from assistive
    /// technology is no header. UIKit then asks the scroll view for the bar's place among its
    /// lines, which is one past the last. So the bar is hidden from the moment UIKit asks for
    /// its place, as VoiceOver's cursor is about to go to it, until the cursor is elsewhere,
    /// and the line the cursor left stays listed though the view goes back for the bar (#342).
    func testTheScrollBarStandsAfterTheBooksLastLineAndThatLineStaysListed() async throws {
        let subject = try await scrolledAtTheFourthChapter()
        let (reader, canvas, view) = subject
        canvas.show(try XCTUnwrap(canvas.scrollBook?.position(at: view.textLength - 1)), selecting: nil)
        for _ in 0..<4 where !canvas.isScrolledToEnd { try await reader.session.send(.nextPage) }
        try await reader.settle()
        XCTAssertTrue(canvas.isScrolledToEnd, "the reader must be at the end of the book")
        let area = UIAccessibility.convertToScreenCoordinates(visibleArea(of: subject), in: view)
        let footer = PlacedItem(frame: CGRect(x: area.minX, y: area.maxY + 8, width: 120, height: 30))
        let bar = UIView(frame: CGRect(x: view.bounds.maxX - 6, y: view.bounds.midY, width: 3, height: 40))
        view.addSubview(bar)
        defer { bar.removeFromSuperview() }
        func labels(_ elements: [UIAccessibilityElement]) -> String { elements.map { $0.accessibilityLabel ?? "" }.joined() }
        func onScreenNow() throws -> NSRange { try XCTUnwrap(canvas.scrollVisibleCharacters()) }
        /// The item UIKit gives after the bar or before it: the scroll view's element beside
        /// the place the scroll view gives the bar, and none where the text ends there.
        func item(besideTheBar forward: Bool) -> UIAccessibilityElement? {
            let place = view.index(ofAccessibilityElement: bar)
            guard place != NSNotFound else {
                XCTFail("the scroll view has no place for its own bar")
                return nil
            }
            return view.accessibilityElement(at: place + (forward ? 1 : -1)) as? UIAccessibilityElement
        }

        // Its cursor is on the book's last line, and no line follows: UIKit gives the bar.
        let last = try XCTUnwrap(try elements(of: view).last)
        let lastLine = try XCTUnwrap(view.line(containing: view.textLength - 1)).range
        XCTAssertEqual(last.accessibilityLabel, view.plainText(in: lastLine))
        focus(last, from: nil, in: view)
        XCTAssertTrue(try elements(of: view).last === last)
        XCTAssertNil(try move(from: last, forward: true, in: view), "the book ends at this line")
        // UIKit asks for the bar's place as the cursor is about to go to it. From then the bar
        // is no header of the scroll view's, and is listed after the last line.
        XCTAssertFalse(bar.accessibilityElementsHidden)
        let lines = view.accessibilityElementCount()
        XCTAssertEqual(view.index(ofAccessibilityElement: bar), lines, "the bar stands after the last line listed")
        XCTAssertTrue(bar.accessibilityElementsHidden, "UIKit must not take the bar for a header while VoiceOver asks from it")
        XCTAssertEqual(view.accessibilityElementCount(), lines + 1, "UIKit goes by a place only where the view lists an element there")
        XCTAssertTrue(view.accessibilityElement(at: lines) as? UIView === bar)
        XCTAssertTrue(view.accessibilityElements?.last as? UIView === bar)
        // It brings the bar into view, and the line the cursor is leaving is below the screen.
        let offset = view.contentOffset.y
        bringScrollBarIntoView(view)
        XCTAssertEqual(offset - view.contentOffset.y, view.adjustedContentInset.top + 40, accuracy: 0.01)
        XCTAssertLessThanOrEqual(NSMaxRange(try onScreenNow()), lastLine.location, "the last line must be below the screen for this to show anything")
        // VoiceOver asks for the item after the bar before its cursor is there.
        XCTAssertNil(item(besideTheBar: true), "what follows the bar is what follows the reader, not a line")
        focus(bar, from: last, in: view)
        var listed = try elements(of: view)
        XCTAssertTrue(listed.last === last, "the line the cursor left is still listed, and the same element")
        XCTAssertEqual(labels(listed), view.plainText(in: NSRange(location: try onScreenNow().location, length: view.textLength - (try onScreenNow().location))),
                       "the lines on screen and those down to the book's last, each once and in order")
        XCTAssertNil(item(besideTheBar: true))
        XCTAssertTrue(item(besideTheBar: false) === last, "the item before the bar is the book's last line")
        XCTAssertNil(canvas.currentSelection)
        // On to the control below the reader: the bar can be found again.
        focus(footer, from: bar, in: view)
        XCTAssertFalse(bar.accessibilityElementsHidden, "the bar is VoiceOver's to find once its cursor has left it")
        XCTAssertTrue(try elements(of: view).last === last)
        XCTAssertEqual(view.accessibilityElementCount(), try elements(of: view).count, "and only the lines are listed")
        XCTAssertTrue(view.accessibilityElements?.last as? UIAccessibilityElement === last)
        // And back to the bar, for which the view goes back a second time.
        XCTAssertEqual(view.index(ofAccessibilityElement: bar), try elements(of: view).count)
        XCTAssertTrue(bar.accessibilityElementsHidden)
        bringScrollBarIntoView(view)
        focus(bar, from: footer, in: view)
        XCTAssertTrue(item(besideTheBar: false) === last, "after two moves for the bar the item before it is still the book's last line")
        // Back to that line, which UIKit brings into view, and on up the text in order.
        leave(bar, for: last, in: view)
        focus(last, from: nil, in: view)
        XCTAssertFalse(bar.accessibilityElementsHidden)
        var cursor = last, read = last.accessibilityLabel ?? ""
        for _ in 0..<8 {
            cursor = try XCTUnwrap(try move(from: cursor, forward: false, in: view), "the text goes back from its last line")
            read = (cursor.accessibilityLabel ?? "") + read
        }
        XCTAssertEqual(read, view.plainText(in: NSRange(location: view.textLength - (read as NSString).length, length: (read as NSString).length)),
                       "reading back gives the book's last lines, nothing skipped or repeated")

        // Letting go. The cursor goes forward to the bar again and the reader is then taken
        // further back than UIKit's move for the bar: the lines on screen and no others.
        focus(last, from: cursor, in: view)
        _ = view.index(ofAccessibilityElement: bar)
        bringScrollBarIntoView(view)
        focus(bar, from: last, in: view)
        XCTAssertTrue(try elements(of: view).last === last)
        try await reader.session.send(.previousPage)
        listed = try elements(of: view)
        XCTAssertEqual(labels(listed), view.plainText(in: try onScreenNow()), "after a step back, the lines on screen and no others")
        XCTAssertEqual(view.index(ofAccessibilityElement: bar), listed.count, "the bar still stands after the last line listed")
        // A line in the middle of the screen left for the control below by a touch: the list
        // ends at the last line on screen, not at the line the cursor was on.
        let middle = listed[listed.count / 2]
        focus(middle, from: bar, in: view)
        focus(footer, from: middle, in: view)
        XCTAssertEqual(labels(try elements(of: view)), view.plainText(in: try onScreenNow()), "from a line on screen, the lines on screen and no others")
        // Only the scroll view's own bars have a place: not a view outside it, and not a view
        // inside it that something else has hidden, which stays hidden.
        XCTAssertEqual(view.index(ofAccessibilityElement: UIView()), NSNotFound)
        let covered = UIView(frame: CGRect(x: 0, y: view.bounds.midY, width: 20, height: 20))
        covered.accessibilityElementsHidden = true
        view.addSubview(covered)
        defer { covered.removeFromSuperview() }
        XCTAssertEqual(view.index(ofAccessibilityElement: covered), NSNotFound)
        focus(footer, from: nil, in: view)
        XCTAssertTrue(covered.accessibilityElementsHidden)
    }

    /// Listing lines past the screen measures them, which replaces TextKit's estimates of
    /// them and can change its estimate of everything not yet laid out. The text on screen
    /// stays where it is drawn through that, in a book whose paragraphs differ widely in
    /// length, where the estimates are furthest out.
    func testListingLinesPastTheScreenLeavesTheTextOnScreenWhereItIs() async throws {
        let lengths = [3, 180, 9, 420, 25, 6, 260, 14, 90, 4, 330, 40]
        let reader = try SessionCoverageReader(try SessionCoverageBook.epub((0..<6).map { chapter in
            var body = "<h1>Chapter \(chapter)</h1>"
            for paragraph in 0..<60 {
                body += "<p>v\(chapter)x\(paragraph) " + CanvasText.sentence(lengths[(paragraph * 7 + chapter) % lengths.count], seed: paragraph + chapter) + "</p>"
            }
            return SessionCoverageBook.Section("c\(chapter)", body, title: "Chapter \(chapter)")
        }))
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.navigate(href: reader.publication.spine[3].resource.href))
        try await reader.wait("the fourth chapter") { reader.section == 3 }
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas), view = try XCTUnwrap(canvas.scrollTextView)
        XCTAssertGreaterThan(unlaidParagraphs(of: view), 200, "most of the book is only estimated")
        /// The first line on screen and how far down the view its top is drawn.
        func place() throws -> (first: Int, top: CGFloat) {
            let shown = try XCTUnwrap(canvas.scrollVisibleCharacters())
            let line = try XCTUnwrap(view.line(containing: shown.location))
            return (shown.location, line.frame.minY + view.containerOrigin.y - view.contentOffset.y)
        }
        // At the start of a chapter shown from pages, and after a jump over text never laid
        // out: in both the text above the screen is only estimated.
        for jump in [0, 5_000] as [CGFloat] {
            if jump > 0 {
                let reported = canvas.visibleRange
                view.contentOffset.y += jump
                try await reader.wait("the place jumped to") { canvas.visibleRange != reported }
                focus(NSObject(), from: nil, in: view)
            }
            let before = try place()
            // With the cursor on a control: the fifty lines after the screen.
            let listed = try elements(of: view)
            var now = try place()
            XCTAssertEqual(now.first, before.first, "listing the lines after the screen changed the first line on screen")
            XCTAssertEqual(now.top, before.top, accuracy: 0.5, "listing the lines after the screen moved the text")
            // With the cursor on the first line: the fifty before the screen as well.
            let unlaid = unlaidParagraphs(of: view)
            focus(try XCTUnwrap(listed.first), from: nil, in: view)
            XCTAssertEqual(try elements(of: view).count, listed.count + past)
            XCTAssertLessThan(unlaidParagraphs(of: view), unlaid, "the lines before the screen must not have been laid out for this to show anything")
            now = try place()
            XCTAssertEqual(now.first, before.first, "listing the lines before the screen changed the first line on screen")
            XCTAssertEqual(now.top, before.top, accuracy: 0.5, "listing the lines before the screen moved the text")
            try await reader.settle()
            now = try place()
            XCTAssertEqual(now.first, before.first, "the first line on screen changed once the reader had settled")
            XCTAssertEqual(now.top, before.top, accuracy: 0.5, "the text moved once the reader had settled")
        }
    }

    /// A heading is one element however many lines it takes, and the same element whichever of
    /// its lines are on screen. With its first line scrolled above the top it is still listed
    /// whole, by the part of it in the reading area, so VoiceOver coming to it moves nothing;
    /// and when the lines before the screen are listed too, it is not listed a second time.
    func testAHeadingHalfAboveTheScreenIsOneElementAndStaysThatElement() async throws {
        let title = "A chapter heading that is long enough to take three lines of a narrow screen at this text size"
        let prose = (1...40).map { "<p>p\($0) " + CanvasText.sentence(50, seed: $0) + "</p>" }.joined()
        let reader = try SessionCoverageReader(try SessionCoverageBook.epub([
            SessionCoverageBook.Section("front", "<h1>Front</h1>" + prose, title: "Front"),
            SessionCoverageBook.Section("long", "<h1>\(title)</h1>" + prose, title: "Long")]))
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.navigate(href: reader.publication.spine[1].resource.href))
        try await reader.wait("the second chapter") { reader.section == 1 }
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas), view = try XCTUnwrap(canvas.scrollTextView)
        let subject: Subject = (reader, canvas, view)
        let start = try XCTUnwrap(canvas.scrollBook).location(of: ReaderTextPosition(section: 1, offset: 0))
        // The heading's words and the break that ends its paragraph.
        let heading = NSRange(location: start, length: (title as NSString).length + 1)
        let lines = view.measuredLines(in: heading)
        XCTAssertGreaterThanOrEqual(lines.count, 2, "the heading must wrap for this to show anything")

        // Whole on screen at the chapter's start: one element over all its lines.
        let whole = try XCTUnwrap(try elements(of: view).first)
        XCTAssertEqual(whole.accessibilityLabel, title)
        XCTAssertTrue(whole.accessibilityTraits.contains(.header))
        XCTAssertEqual(whole.accessibilityAttributedLabel?.attribute(.accessibilityTextHeadingLevel, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertGreaterThan(whole.accessibilityFrameInContainerSpace.height, lines[0].frame.height * 1.5)
        XCTAssertFalse(try onScreen(try elements(of: view), subject).isEmpty,
                       "every character on screen is listed once, the heading's among them, before the lines after the screen")

        // Its first line above the top of the screen.
        view.contentOffset.y = lines[1].frame.minY + view.containerOrigin.y - view.adjustedContentInset.top
        let before = canvas.visibleRange
        try await reader.wait("the place scrolled to") { canvas.visibleRange != before }
        XCTAssertEqual(try shown(subject).location, lines[1].range.location, "the heading's second line is the first on screen")
        let listed = try elements(of: view)
        let cut = try XCTUnwrap(listed.first)
        XCTAssertTrue(cut === whole, "the same element as when all of it showed")
        XCTAssertEqual(cut.accessibilityLabel, title, "read whole, from its first word")
        let area = visibleArea(of: subject).insetBy(dx: -1_000, dy: -0.01)
        XCTAssertTrue(cut.accessibilityFrameInContainerSpace.height > 0 && area.contains(cut.accessibilityFrameInContainerSpace),
                      "listed at \(cut.accessibilityFrameInContainerSpace), outside \(area)")
        XCTAssertEqual(listed.dropFirst().first?.accessibilityLabel, try lineText(at: NSMaxRange(heading), in: view), "then the line under it")
        XCTAssertEqual(listed.filter { $0.accessibilityTraits.contains(.header) }.count, 1)

        // VoiceOver's cursor comes to it: nothing scrolls, the lines before the screen are
        // listed before it, and it is still one element, the same one.
        let offset = view.contentOffset
        focus(cut, from: nil, in: view)
        XCTAssertEqual(view.contentOffset, offset, "moving onto the heading moved the reader")
        let grown = try elements(of: view)
        XCTAssertEqual(grown.filter { $0.accessibilityTraits.contains(.header) }.count, 1, "the heading is listed once")
        let index = view.index(ofAccessibilityElement: cut)
        XCTAssertTrue(index != NSNotFound && grown[index] === cut)
        XCTAssertGreaterThan(index, 0, "the end of the chapter before is listed before it")
        let earlier = view.plainText(in: NSRange(location: 0, length: start))
        for line in grown.prefix(index) {
            XCTAssertTrue(earlier.contains(line.accessibilityLabel ?? "\u{0}"), "\(line.accessibilityLabel ?? "") is a line of the chapter before")
        }
        // On to the line under it and back: one stop each way.
        let under = try XCTUnwrap(try move(from: cut, forward: true, in: view))
        XCTAssertEqual(under.accessibilityLabel, try lineText(at: NSMaxRange(heading), in: view))
        XCTAssertTrue(try XCTUnwrap(try move(from: under, forward: false, in: view)) === cut)
    }

    /// A book that opens on pictures it marks as decoration, each a screen high: a cover and a
    /// frontispiece with `alt=""`. VoiceOver passes decoration over, but a screen of nothing
    /// else would leave it no line to come in at or to scroll from, so there it is listed, as
    /// an image without a name, and stays listed while the cursor is on it.
    func testAScreenOfDecorationAloneIsListedUntilThereAreWordsToRead() async throws {
        let picture = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"300\" height=\"3000\"><rect width=\"300\" height=\"3000\" fill=\"#246\"/></svg>"
        let prose = (1...30).map { "<p>p\($0) " + CanvasText.sentence(50, seed: $0) + "</p>" }.joined()
        let reader = try SessionCoverageReader(try SessionCoverageBook.epub([
            SessionCoverageBook.Section("cover", "<p><img alt=\"\" src=\"cover.svg\"/></p><p><img alt=\"\" src=\"cover.svg\"/></p>" + prose,
                                        title: "Cover")],
            manifest: "<item id=\"cover\" href=\"cover.svg\" media-type=\"image/svg+xml\"/>", files: ["OPS/cover.svg": picture]))
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas), view = try XCTUnwrap(canvas.scrollTextView)
        let images = view.imageAttachments()
        XCTAssertEqual(images.map(\.image.alternative), [.decorative, .decorative])
        let onScreen = try shown((reader, canvas, view))
        XCTAssertLessThan(NSMaxRange(onScreen), try XCTUnwrap((view.contentStorage.textStorage?.string as NSString?)?.range(of: "p1 ").location),
                          "the screen holds pictures and no words")

        // Moving in from a control, VoiceOver meets the picture on screen, though the lines
        // after the screen are listed and are words: the decoration among those has no element.
        var listed = try elements(of: view)
        let first = try XCTUnwrap(listed.first, "a screen of decoration alone still lists something")
        XCTAssertTrue(first.accessibilityTraits.contains(.image) && first.accessibilityLabel == nil, "as an image without a name")
        XCTAssertFalse(first.accessibilityFrameInContainerSpace.isEmpty)
        XCTAssertTrue(visibleArea(of: (reader, canvas, view)).insetBy(dx: -1_000, dy: -0.01).contains(first.accessibilityFrameInContainerSpace),
                      "and where it is on screen: \(first.accessibilityFrameInContainerSpace)")
        XCTAssertTrue(listed.dropFirst().first?.accessibilityLabel?.hasPrefix("p1 ") ?? false,
                      "then the first words: \(listed.dropFirst().first?.accessibilityLabel ?? "nil")")
        XCTAssertFalse(listed.dropFirst().contains { $0.accessibilityTraits.contains(.image) }, "no picture is listed among the lines after the screen")

        // With the cursor on it the lines after the screen are listed too. It stays, the
        // decoration after it has no element now that there are words, and the next move goes
        // to the words.
        focus(first, from: nil, in: view)
        listed = try elements(of: view)
        XCTAssertTrue(listed.first === first, "the picture under the cursor keeps its element")
        XCTAssertEqual(listed.filter { $0.accessibilityTraits.contains(.image) }.count, 1, "and it is the only picture listed")
        let next = try XCTUnwrap(try move(from: first, forward: true, in: view))
        XCTAssertTrue(next.accessibilityLabel?.hasPrefix("p1 ") ?? false, "then the first words: \(next.accessibilityLabel ?? "nil")")
        XCTAssertTrue(next.accessibilityTraits.contains(.staticText))

        // Once the cursor is in the words, decoration is passed over in both directions.
        listed = try elements(of: view)
        XCTAssertFalse(listed.contains { $0.accessibilityTraits.contains(.image) }, "no picture is listed beside words")
        XCTAssertTrue(listed.first === next, "nothing readable stands before the first words")
    }

    /// A rule between two scenes on screen: a line of its own that VoiceOver stops on between
    /// the paragraphs it parts, named by the reader and not an image. Moving on from the line
    /// before it and back from the line after it both come to it.
    func testARuleOnScreenIsAStopBetweenTheLinesItParts() async throws {
        let prose = (1...40).map { "<p>p\($0) " + CanvasText.sentence(50, seed: $0) + "</p>" }.joined()
        let reader = try SessionCoverageReader(try SessionCoverageBook.epub([
            SessionCoverageBook.Section("scenes", "<p>First scene ends.</p><hr/><p>Second scene starts.</p>" + prose, title: "Scenes")]))
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas), view = try XCTUnwrap(canvas.scrollTextView)
        let subject: Subject = (reader, canvas, view)

        var listed = try elements(of: view)
        XCTAssertEqual(listed.prefix(3).map { $0.accessibilityLabel ?? "" }, ["First scene ends.\n", "Separator", "Second scene starts.\n"])
        XCTAssertTrue(listed.count > 3 && (listed[3].accessibilityLabel ?? "").hasPrefix("p1 "), "then the prose: \(listed.count) listed")
        let rule = listed[1]
        XCTAssertEqual(rule.accessibilityTraits, [], "not an image and not words of the book")
        XCTAssertFalse(listed.contains { $0.accessibilityTraits.contains(.image) })
        let frame = rule.accessibilityFrameInContainerSpace
        XCTAssertTrue(frame.height > 0 && visibleArea(of: subject).insetBy(dx: -1_000, dy: -0.01).contains(frame), "\(frame)")
        XCTAssertGreaterThan(frame.minY, listed[0].accessibilityFrameInContainerSpace.midY)
        XCTAssertLessThan(frame.maxY, listed[2].accessibilityFrameInContainerSpace.midY)
        XCTAssertTrue((rule.accessibilityCustomActions ?? []).isEmpty, "continuous scroll scrolls natively")
        XCTAssertFalse(rule.accessibilityActivate(), "a rule opens nothing")

        // The cursor comes to it from either side, and it keeps its element while it is there.
        let offset = view.contentOffset
        focus(listed[0], from: nil, in: view)
        let reached = try XCTUnwrap(try move(from: listed[0], forward: true, in: view))
        XCTAssertEqual(reached.accessibilityLabel, "Separator")
        XCTAssertTrue(reached === rule)
        let after = try XCTUnwrap(try move(from: reached, forward: true, in: view))
        XCTAssertEqual(after.accessibilityLabel, "Second scene starts.\n")
        let back = try XCTUnwrap(try move(from: after, forward: false, in: view))
        XCTAssertTrue(back === rule, "moving back stops on the rule too")
        XCTAssertEqual(view.contentOffset, offset, "nothing scrolled: the rule is on screen")
        listed = try elements(of: view)
        XCTAssertEqual(listed.filter { $0.accessibilityLabel == "Separator" }.count, 1)
    }

    /// What VoiceOver is given for a line. UIKit hands it the line's own actions and then those
    /// of everything that holds the line, up to the window: its text view, the canvas and the
    /// views above them.
    private func offered(on element: UIAccessibilityElement) -> [String] {
        var names = (element.accessibilityCustomActions ?? []).map(\.name)
        var holder = element.accessibilityContainer as? NSObject
        while let object = holder {
            names += (object.accessibilityCustomActions ?? []).map(\.name)
            holder = (object as? UIView)?.superview
        }
        return names
    }

    /// On 2026-10-12 a simulator's VoiceOver said "Actions available" after every line of
    /// continuous scroll. With a link and a picture in the book its rotor offered, on a plain
    /// line, "Verification link", four more links, "Inspect Image: Blue verification square",
    /// "Previous Page" and "Next Page"; on a plain line of a page, "Next Page", "Previous
    /// Page", the picture, and "Previous Page" and "Next Page" again. None was the line's.
    /// The text view gave UIKit's actions for the links of its text and the
    /// reader's for its pictures and tables, and the canvas had the two the reader's SwiftUI
    /// surface named. This holds the lines and the text view to their own. SwiftUI gives a
    /// view no action in a test host, where no assistive technology runs, so what the surface
    /// names is not seen here: VoiceOver sessions hold that (doc/voiceover-testing.md).
    func testALineIsOfferedWhatIsInItAndNothingOfWhatHoldsIt() async throws {
        let picture = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"60\"><rect width=\"60\" height=\"60\" fill=\"#246\"/></svg>"
        let prose = (1...30).map { "<p>p\($0) " + CanvasText.sentence(50, seed: $0) + "</p>" }.joined()
        let body = "<h1>Actions</h1><p>Plain words before.</p><p>A <a href=\"#end\">jump</a> in a line.</p>"
            + "<p><img alt=\"Blue square\" src=\"square.svg\"/></p>"
            + "<table><tr><td>First cell</td><td>Second cell</td></tr></table>" + prose + "<p id=\"end\">The end.</p>"
        let reader = try SessionCoverageReader(try SessionCoverageBook.epub(
            [SessionCoverageBook.Section("actions", body, title: "Actions")],
            manifest: "<item id=\"square\" href=\"square.svg\" media-type=\"image/svg+xml\"/>", files: ["OPS/square.svg": picture]))
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)

        func assertEachLineIsOfferedItsOwn(_ label: String, in view: ReaderTextView, pageActions: [String],
                                           file: StaticString = #filePath, line: UInt = #line) throws {
            let listed = try elements(of: view, file: file, line: line)
            var pictures = 0, rows = 0, links = 0
            for element in listed {
                let text = element.accessibilityLabel ?? ""
                let own = (element.accessibilityCustomActions ?? []).map(\.name)
                XCTAssertEqual(Array(own.prefix(pageActions.count)), pageActions, "\(label): \"\(text)\"", file: file, line: line)
                let rest = Array(own.dropFirst(pageActions.count))
                if text == "Blue square" {
                    pictures += 1
                    XCTAssertEqual(rest, ["Inspect Image: Blue square"], "\(label): the picture is inspected from its own line", file: file, line: line)
                } else if text.contains("First cell") {
                    rows += 1
                    XCTAssertTrue(rest.contains { $0.hasPrefix("Select Table Text: First cell") },
                                  "\(label): a row keeps its cells' actions: \(rest)", file: file, line: line)
                    XCTAssertTrue(rest.allSatisfy { $0.contains("Table") }, "\(label): \(rest)", file: file, line: line)
                } else {
                    if element.accessibilityTraits.contains(.link) { links += 1 }
                    XCTAssertEqual(rest, [], "\(label): \"\(text)\" has nothing in it to act on", file: file, line: line)
                }
                XCTAssertEqual(offered(on: element), own, "\(label): \"\(text)\" is offered what something that holds it offers",
                               file: file, line: line)
            }
            XCTAssertEqual([pictures, rows, links], [1, 1, 1], "\(label): the picture, the table and the link are listed: "
                            + "\(listed.map { $0.accessibilityLabel ?? "" })", file: file, line: line)
            XCTAssertNil(view.accessibilityCustomActions, "\(label): a view that lists its lines offers nothing for each of them to repeat",
                         file: file, line: line)
        }

        // Pages: every line turns the page, and offers that once.
        let pageActions = ["Next Page", "Previous Page"]
        try assertEachLineIsOfferedItsOwn("in pages", in: try XCTUnwrap(canvas.textViews.first), pageActions: pageActions)

        // Continuous scroll has no page to turn: a plain line is offered nothing at all, and
        // VoiceOver has no "Actions available" to say after it.
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { canvas.scrollBook != nil }
        try await reader.settle()
        let view = try XCTUnwrap(canvas.scrollTextView)
        try assertEachLineIsOfferedItsOwn("in continuous scroll", in: view, pageActions: [])
        let plain = try XCTUnwrap(try elements(of: view).first { $0.accessibilityLabel == "Plain words before.\n" })
        XCTAssertEqual(offered(on: plain), [])
        let link = try XCTUnwrap(try elements(of: view).first { $0.accessibilityTraits.contains(.link) })
        XCTAssertEqual(link.accessibilityLabel, "jump")
        XCTAssertEqual(offered(on: link), [], "a link is followed by activating it")
        // With VoiceOver's cursor in the text, when lines past the screen are listed as well.
        focus(plain, from: nil, in: view)
        try assertEachLineIsOfferedItsOwn("with the cursor in the text", in: view, pageActions: [])

        // A change back to pages gives the lines their page actions again.
        try await reader.session.send(.style(EPUBReaderStyle(flow: .paginated)))
        try await reader.wait("pages again") { canvas.scrollBook == nil }
        try await reader.settle()
        try assertEachLineIsOfferedItsOwn("in pages again", in: try XCTUnwrap(canvas.textViews.first), pageActions: pageActions)
    }

    func testANoteKeepsUIKitsOwnTextElements() {
        // A note's popover is a text view of its own, never scrolled by the reader: its text
        // starts at its first line, which is where UIKit's elements start.
        let note = ReaderNoteViewController(text: CanvasText.body("A note."), dark: false, width: 300)
        XCTAssertNil(note.textView.accessibilityElements as? [UIAccessibilityElement])
    }
}

/// Something outside the text that VoiceOver's cursor can be on, known by where it is on screen.
private final class PlacedItem: NSObject {
    private let frame: CGRect
    init(frame: CGRect) { self.frame = frame }
    override var accessibilityFrame: CGRect {
        get { frame }
        set {}
    }
}
#endif
