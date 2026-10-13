#if os(iOS)
import UIKit
import XCTest
@testable import EPUBViewing

/// Where an assistive technology's cursor goes when the page it is on is turned, on iPhone and
/// iPad ("Input and accessibility" in `doc/native-viewer.md`). API level only: the cursor is
/// put on a line as UIKit tells the reader of it, and no assistive technology is driven.
/// `doc/voiceover-testing.md` has what VoiceOver then did on a device.
@MainActor final class PageTurnAccessibilityTests: XCTestCase {
    private var hosts: [CanvasHost] = []
    private var posts: [(notification: UIAccessibility.Notification, argument: Any?)] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        posts.removeAll()
        try await super.tearDown()
    }

    private static let lineLength = 22

    /// Numbered lines, each a paragraph of its own and all of one length: a line of one page
    /// has the characters of the same line of the next, counted from each page's first.
    private static func lines(_ count: Int, heading: Int? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: CanvasText.body(
            (1...count).map { String(format: "Line %03d of the book.", $0) }.joined(separator: "\n")))
        if let heading {
            text.addAttribute(.readerHeading, value: ReaderHeading(level: 2),
                              range: NSRange(location: (heading - 1) * lineLength, length: lineLength - 1))
        }
        return text
    }

    private func host(_ sections: [NSAttributedString], size: CGSize = CGSize(width: 420, height: 350)) -> CanvasHost {
        let host = CanvasHost(FakeCanvasSource(sections), size: size)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        host.canvas.postAccessibilityNotification = { [weak self] in self?.posts.append(($0, $1)) }
        return host
    }

    private func elements(of view: ReaderTextView) throws -> [UIAccessibilityElement] {
        try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
    }

    /// The number of the line an element reads.
    private func number(_ element: Any?) -> Int? {
        guard let label = (element as? UIAccessibilityElement)?.accessibilityLabel, label.hasPrefix("Line ") else { return nil }
        return Int(label.dropFirst(5).prefix(3))
    }

    /// Puts the cursor on `element`, a line or a control, as VoiceOver does: the element left
    /// is told and named, then the one come to.
    private func focus(_ element: NSObject, from previous: NSObject? = nil) {
        let center = NotificationCenter.default
        if let previous {
            previous.accessibilityElementDidLoseFocus()
            center.post(name: UIAccessibility.elementFocusedNotification, object: nil,
                        userInfo: [UIAccessibility.unfocusedElementUserInfoKey: previous])
        }
        element.accessibilityElementDidBecomeFocused()
        center.post(name: UIAccessibility.elementFocusedNotification, object: nil,
                    userInfo: [UIAccessibility.focusedElementUserInfoKey: element])
    }

    private func perform(_ name: String, on element: UIAccessibilityElement, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(element.accessibilityCustomActions?.first { $0.name == name }, file: file, line: line)
        _ = try XCTUnwrap(action.actionHandler, file: file, line: line)(action)
    }

    /// The one thing posted since the last call: a layout change, and the element given with it.
    private func cursorSent(file: StaticString = #filePath, line: UInt = #line) throws -> UIAccessibilityElement {
        defer { posts.removeAll() }
        XCTAssertEqual(posts.map(\.notification), [.layoutChanged], file: file, line: line)
        return try XCTUnwrap(posts.first?.argument as? UIAccessibilityElement, file: file, line: line)
    }

    func testALinesPageActionSendsTheCursorToTheFirstLineOfThePageTurnedTo() throws {
        let canvas = host([Self.lines(60)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let first = try elements(of: view)
        XCTAssertGreaterThan(first.count, 4)
        XCTAssertEqual(first.map(number), Array(1...first.count))
        focus(first[3])
        XCTAssertTrue(posts.isEmpty)
        try perform("Next Page", on: first[3])
        var sent = try cursorSent()
        let second = try elements(of: view)
        XCTAssertTrue(sent === second[0], "the first line of the page now shown")
        XCTAssertEqual(number(sent), first.count + 1, "the line after the last of the page before")
        // VoiceOver takes the cursor there, and its next item is the page's second line.
        focus(sent, from: first[3])
        XCTAssertEqual(number(view.accessibilityElement(at: view.index(ofAccessibilityElement: sent) + 1)), first.count + 2)
        // From further down that page, and back: the page before is read from its top too.
        focus(second[2], from: sent)
        try perform("Previous Page", on: second[2])
        sent = try cursorSent()
        XCTAssertTrue(sent === (try elements(of: view))[0])
        XCTAssertEqual(number(sent), 1)
        // At the first page nothing turns, the line is still there and nothing is posted.
        focus(sent, from: second[2])
        try perform("Previous Page", on: sent)
        XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(view.index(ofAccessibilityElement: sent), 0)
    }

    func testAnElementOfThePageBeforeStandsForNoLineOfThePageTurnedTo() throws {
        let canvas = host([Self.lines(60)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let kept = try elements(of: view)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let next = try elements(of: view)
        XCTAssertEqual(next.count, kept.count, "the two pages hold as many lines, of the same characters counted from each page's first")
        for element in kept {
            XCTAssertEqual(view.index(ofAccessibilityElement: element), NSNotFound, "line \(number(element) ?? 0) is on the page before")
        }
        // Its page shown again, a kept element stands for its line there, which has a new element.
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        let again = try elements(of: view)
        XCTAssertEqual(again.map(number), kept.map(number))
        for (index, element) in kept.enumerated() {
            XCTAssertFalse(again[index] === element)
            XCTAssertEqual(view.index(ofAccessibilityElement: element), index)
        }
        XCTAssertEqual(view.index(ofAccessibilityElement: next[0]), NSNotFound)
    }

    func testACursorThatIsOnNoLineOfThePageIsLeftWhereItIs() throws {
        let canvas = host([Self.lines(120)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        // VoiceOver is not running, or its cursor has never been in the text.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertTrue(posts.isEmpty)
        // It left the text for a control, as for the host's page button.
        let line = try XCTUnwrap(try elements(of: view).first)
        let button = NSObject()
        focus(line)
        focus(button, from: line)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertTrue(posts.isEmpty, "a cursor on a control stays on it")
        // VoiceOver was switched off with its cursor on a line.
        focus(try XCTUnwrap(try elements(of: view).first), from: button)
        NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertTrue(posts.isEmpty)
        // A page shown again as it was keeps the cursor's line, and the cursor with it.
        let held = try elements(of: view)[1]
        focus(held)
        canvas.reloadContent(keeping: nil)
        XCTAssertTrue(posts.isEmpty, "the line is still on the page")
        XCTAssertEqual(view.index(ofAccessibilityElement: held), 1)
        // And the cursor is followed from that kept element when the page does turn.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertTrue(try cursorSent() === (try elements(of: view))[0])
    }

    func testVoiceOversScrollAnnouncesThePageAndThenSendsTheCursorToItsFirstLine() throws {
        let canvas = host([Self.lines(40)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        var line = try elements(of: view)[2]
        focus(line)
        // VoiceOver asks the element under its cursor, which passes the scroll to the canvas.
        XCTAssertTrue(line.accessibilityScroll(.next))
        XCTAssertEqual(posts.map(\.notification), [.pageScrolled, .layoutChanged], "the page's number first, and the line after it")
        XCTAssertEqual(posts.first?.argument as? String, "Page 2")
        XCTAssertTrue(posts.last?.argument as? UIAccessibilityElement === (try elements(of: view))[0])
        // With the cursor elsewhere the page is announced and nothing else is said.
        let previous = line
        line = try XCTUnwrap(posts.last?.argument as? UIAccessibilityElement)
        posts.removeAll()
        focus(line, from: previous)
        focus(NSObject(), from: line)
        XCTAssertTrue(canvas.accessibilityScroll(.previous))
        XCTAssertEqual(posts.map(\.notification), [.pageScrolled])
        XCTAssertEqual(posts.first?.argument as? String, "Page 1")
        posts.removeAll()
        // A scroll that turns nothing posts nothing.
        focus(try elements(of: view)[0])
        XCTAssertFalse(canvas.accessibilityScroll(.previous))
        XCTAssertTrue(posts.isEmpty)
    }

    func testAPositionShownSendsTheCursorToTheLineThatHoldsIt() throws {
        let canvas = host([Self.lines(120)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let first = try elements(of: view)
        let count = first.count
        // As after a link VoiceOver followed from a line: the host shows the link's target,
        // in the middle of a later page.
        let target = 2 * count + count / 2 + 1
        focus(first[1])
        canvas.show(ReaderTextPosition(section: 0, offset: (target - 1) * Self.lineLength + 5), selecting: nil)
        var sent = try cursorSent()
        XCTAssertEqual(number(sent), target, "the line of the position shown, not the first of its page")
        XCTAssertGreaterThan(view.index(ofAccessibilityElement: sent), 0)
        XCTAssertTrue(try elements(of: view).contains { $0 === sent })
        // A position on the page the cursor is on turns nothing under it.
        focus(sent, from: first[1])
        canvas.show(ReaderTextPosition(section: 0, offset: (target + 1) * Self.lineLength), selecting: nil)
        XCTAssertTrue(posts.isEmpty)
        // The end of the text holds no line: the page that ends there is read from its top.
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        sent = try cursorSent()
        focus(sent)
        canvas.show(ReaderTextPosition(section: 0, offset: 120 * Self.lineLength - 1), selecting: nil)
        sent = try cursorSent()
        XCTAssertTrue(sent === (try elements(of: view))[0])
        XCTAssertEqual(number(try elements(of: view).last), 120)
    }

    func testTheCursorGoesToTheFirstLineOfASpreadAndIntoTheNextChapter() throws {
        let canvas = host([Self.lines(100), Self.lines(30)], size: CGSize(width: 1100, height: 420)).canvas
        XCTAssertEqual(canvas.textViews.count, 2)
        // From a line of the right-hand page to the left-hand page of the next spread.
        var right = try elements(of: canvas.textViews[1])
        focus(right[1])
        try perform("Next Page", on: right[1])
        var sent = try cursorSent()
        XCTAssertTrue(sent === (try elements(of: canvas.textViews[0]))[0])
        XCTAssertEqual(number(sent), try XCTUnwrap(number(right.last)) + 1)
        // On through the chapter to its last spread, and from there into the next chapter.
        var previous: NSObject = right[1]
        for _ in 0..<40 where canvas.visibleRange?.start.section == 0 {
            focus(sent, from: previous)
            previous = sent
            try perform("Next Page", on: sent)
            sent = try cursorSent()
            XCTAssertTrue(sent === (try elements(of: canvas.textViews[0]))[0])
        }
        XCTAssertEqual(canvas.visibleRange?.start.section, 1)
        XCTAssertEqual(number(sent), 1, "the next chapter's first line")
        // Back into the chapter before: its last spread, read from the top of its left-hand page.
        focus(sent, from: previous)
        try perform("Previous Page", on: sent)
        sent = try cursorSent()
        XCTAssertEqual(canvas.visibleRange?.start.section, 0)
        XCTAssertTrue(sent === (try elements(of: canvas.textViews[0]))[0])
        right = try elements(of: try XCTUnwrap(canvas.textViews.last))
        XCTAssertEqual(number(right.last), 100, "the chapter's last line is on that spread")
    }

    func testAMoveByHeadingTakesTheCursorItselfAndNothingIsPosted() throws {
        let canvas = host([Self.lines(120, heading: 70)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let line = try elements(of: view)[1]
        focus(line)
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors?.first { $0.systemRotorType == .heading })
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = .next
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: line, targetRange: nil)
        // VoiceOver asks twice for one move, and goes to the item it is given.
        let found = try XCTUnwrap(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement)
        XCTAssertTrue(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement === found)
        XCTAssertEqual(number(found), 70)
        XCTAssertTrue(found.accessibilityTraits.contains(.header))
        XCTAssertGreaterThan(canvas.visibleRange?.start.offset ?? 0, 0, "the heading's page was turned to")
        XCTAssertNotEqual(view.index(ofAccessibilityElement: found), NSNotFound)
        XCTAssertTrue(posts.isEmpty, "the rotor's item is where the cursor goes")
        // From there the cursor is followed again.
        focus(found, from: line)
        try perform("Next Page", on: found)
        XCTAssertTrue(try cursorSent() === (try elements(of: view))[0])
    }
}
#endif
