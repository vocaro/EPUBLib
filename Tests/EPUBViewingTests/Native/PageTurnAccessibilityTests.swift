#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// Where an assistive technology's cursor goes when the page it is on is turned, on iPhone and
/// iPad ("Input and accessibility" in `doc/native-viewer.md`). API level only: the cursor is
/// put on a line as UIKit tells the reader of it, and no assistive technology is driven.
/// `doc/testing.md#voiceover-testing` has what VoiceOver then did on a device.
@MainActor class PageTurnAccessibilityTests: XCTestCase {
    /// How every page here turns; `SlidingPageTurnAccessibilityTests` runs them all again with a
    /// slide (#688).
    class var pageTurnAnimation: EPUBPageTurnAnimation { .none }

    private var hosts: [CanvasHost] = []
    private var readers: [SessionCoverageReader] = []
    private var posts: [(notification: UIAccessibility.Notification, argument: Any?)] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        for reader in readers { reader.close() }
        readers.removeAll()
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

    private func host(_ sections: [NSAttributedString], size: CGSize = CGSize(width: 420, height: 350),
                      linear: [Bool]? = nil) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.pageTurnAnimation = Self.pageTurnAnimation
        let host = CanvasHost(FakeCanvasSource(sections, linear: linear), size: size, configuration: configuration)
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

    func testALinesPageActionHasTheElementUnderTheCursorStandForTheFirstLineOfThePageTurnedTo() throws {
        let canvas = host([Self.lines(90)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let first = try elements(of: view)
        XCTAssertGreaterThan(first.count, 4)
        XCTAssertEqual(first.map(number), Array(1...first.count))
        let top = first[0].accessibilityFrameInContainerSpace
        let cursor = first[3]
        XCTAssertGreaterThan(cursor.accessibilityFrameInContainerSpace.minY, top.maxY - 1)
        focus(cursor)
        XCTAssertTrue(posts.isEmpty)
        try perform("Next Page", on: cursor)
        // VoiceOver is given the element it holds, which is the first line of the page shown:
        // its cursor is on the same item, and what it chose in the rotor there still stands.
        XCTAssertTrue(try cursorSent() === cursor)
        let second = try elements(of: view).map(number)
        XCTAssertTrue(try elements(of: view)[0] === cursor, "it has the first line's place in the list")
        XCTAssertEqual(second, Array((first.count + 1)...(first.count + second.count)), "and every line is listed once")
        XCTAssertEqual(cursor.accessibilityFrameInContainerSpace.origin, top.origin, "it is where the page's first line is")
        XCTAssertEqual(cursor.accessibilityFrameInContainerSpace.height, top.height)
        XCTAssertEqual(view.index(ofAccessibilityElement: cursor), 0)
        XCTAssertEqual(number(view.accessibilityElement(at: 1)), first.count + 2, "its next item is the page's second line")
        for element in first where element !== cursor {
            XCTAssertEqual(view.index(ofAccessibilityElement: element), NSNotFound, "line \(number(element) ?? 0) is on the page before")
        }
        // Performed again with the cursor where it is: VoiceOver has gone to no other item.
        try perform("Next Page", on: cursor)
        XCTAssertTrue(try cursorSent() === cursor)
        let third = try elements(of: view)
        XCTAssertTrue(third[0] === cursor)
        XCTAssertEqual(number(cursor), first.count + second.count + 1)
        // From further down that page, and back: the page before is read from its top too.
        let lower = third[2]
        focus(lower, from: cursor)
        try perform("Previous Page", on: lower)
        XCTAssertTrue(try cursorSent() === lower)
        XCTAssertEqual(number(lower), first.count + 1)
        XCTAssertEqual(try elements(of: view).map(number), second)
        XCTAssertEqual(view.index(ofAccessibilityElement: cursor), NSNotFound, "the element the cursor left is a line of the page turned from")
        try perform("Previous Page", on: lower)
        XCTAssertTrue(try cursorSent() === lower)
        XCTAssertEqual(number(lower), 1)
        // At the first page nothing turns, the line is still there and nothing is posted.
        try perform("Previous Page", on: lower)
        XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(view.index(ofAccessibilityElement: lower), 0)
    }

    /// How often VoiceOver was told since the last call that a page was shown, with its cursor
    /// sent nowhere: layout changes with no element, and nothing else posted.
    private func toldOfAPage(file: StaticString = #filePath, line: UInt = #line) -> Int {
        defer { posts.removeAll() }
        XCTAssertTrue(posts.allSatisfy { $0.notification == .layoutChanged && $0.argument == nil },
                      "\(posts.map { ($0.notification.rawValue, ($0.argument as? NSObject)?.accessibilityLabel ?? "no element") })", file: file, line: line)
        return posts.count
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
        // VoiceOver is not running, or its cursor has never been in the text: no element is
        // named, so the cursor is sent nowhere.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(toldOfAPage(), 1)
        // It left the text for a control, as for the host's page button.
        let line = try XCTUnwrap(try elements(of: view).first)
        let button = NSObject()
        focus(line)
        focus(button, from: line)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(toldOfAPage(), 1, "a cursor on a control stays on it")
        // VoiceOver was switched off with its cursor on a line.
        focus(try XCTUnwrap(try elements(of: view).first), from: button)
        NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(toldOfAPage(), 1)
        // A page shown again as it was keeps the cursor's line, and the cursor with it: no
        // element is named.
        let held = try elements(of: view)[1]
        focus(held)
        canvas.reloadContent(keeping: nil)
        XCTAssertEqual(toldOfAPage(), 1, "the line is still on the page")
        XCTAssertEqual(view.index(ofAccessibilityElement: held), 1)
        // And that kept element stands for the first line when the page does turn.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertTrue(try cursorSent() === held)
        XCTAssertTrue(try elements(of: view)[0] === held)
    }

    /// VoiceOver keeps the items it was given each side of its cursor, a page's lines among
    /// them, and goes to one it has been on without asking when a page is shown by something
    /// it did not do (`doc/testing.md`, "Harness pitfalls and current results"). A
    /// layout change has it ask again.
    func testAPageShownUnderACursorThatHasNotLeftItTellsOfALayoutChangeWithNoElement() throws {
        let canvas = host([Self.lines(120, heading: 70)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let count = try elements(of: view).count
        // The cursor went from a line to a control, as VoiceOver's does at a touch on the
        // host's page button, and holds the lines it was given.
        let line = try elements(of: view)[2]
        let button = NSObject()
        focus(line)
        focus(button, from: line)
        // A page turned by a key or the host's command: told once, and no element named.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(toldOfAPage(), 1, "the page turned to")
        XCTAssertEqual(number(try elements(of: view).first), count + 1)
        XCTAssertEqual(view.index(ofAccessibilityElement: line), NSNotFound, "the line it held is on no page shown")
        // So for every page the reader shows by itself: a position, from the contents, a search
        // or a bookmark, and the page shown again when its text is built again.
        canvas.show(ReaderTextPosition(section: 0, offset: 3 * count * Self.lineLength), selecting: nil)
        XCTAssertEqual(toldOfAPage(), 1, "a position shown")
        canvas.reloadContent(keeping: nil)
        XCTAssertEqual(toldOfAPage(), 1, "the page shown again")
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(toldOfAPage(), 1, "the page before")
        // A turn that shows nothing tells of nothing.
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        posts.removeAll()
        XCTAssertEqual(canvas.turnPage(forward: false), .atBoundary)
        XCTAssertTrue(posts.isEmpty)
        // A page VoiceOver asked for is its own to follow: the rotor's, where it goes to the
        // item it is given, and its scroll, which is announced.
        canvas.showForAccessibilityRotor(ReaderTextPosition(section: 0, offset: 69 * Self.lineLength))
        XCTAssertGreaterThan(canvas.visibleRange?.start.offset ?? 0, 0)
        XCTAssertTrue(posts.isEmpty, "the rotor's page")
        XCTAssertTrue(canvas.accessibilityScroll(.next))
        XCTAssertEqual(posts.map(\.notification), [.pageScrolled], "VoiceOver's scroll")
        posts.removeAll()
        // With the cursor on a line the page still has, the page shown again is told of the
        // same way: the lines around the cursor's are new items. The cursor keeps its line.
        let held = try elements(of: view)[1]
        focus(held, from: button)
        canvas.reloadContent(keeping: nil)
        XCTAssertEqual(toldOfAPage(), 1, "the line is still on the page")
        XCTAssertFalse(view.accessibilityCursorHasLeftThePage)
        XCTAssertEqual(view.index(ofAccessibilityElement: held), 1)
        // A line turned away has the cursor sent to the page, and nothing else is posted.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertTrue(try cursorSent() === held, "one layout change, and it names the element under the cursor")
    }

    /// The same page shown again under a cursor that is on one of its lines, as when the host
    /// changes the appearance or the text is built again. VoiceOver is told of a layout change
    /// with no element, and takes the item listed where its cursor is: given a new one for the
    /// line it sets its cursor there, and its rotor is back at its default
    /// (`doc/testing.md`, "Harness pitfalls and current results"). So the element
    /// it holds is listed as the item of its line, with all that a new one for the line
    /// answers, and every other line has a new item.
    func testTheElementUnderTheCursorIsTheItemOfItsLineWhenItsPageIsShownAgain() throws {
        let canvas = host([Self.lines(120, heading: 3)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        var listed = try elements(of: view)
        let fresh = listed.map(answers)
        XCTAssertGreaterThan(listed.count, 4)
        // The cursor on the page's third line, a heading.
        let held = listed[2]
        XCTAssertEqual(fresh[2].headingLevel, 2)
        focus(held)
        for round in ["shown again", "and again"] {
            canvas.reloadContent(keeping: nil)
            XCTAssertEqual(toldOfAPage(), 1, "\(round): told once, and no element named")
            let again = try elements(of: view)
            XCTAssertEqual(again.map(answers), fresh, "\(round): every line once and in order, each what a new item for it is")
            for (index, element) in again.enumerated() where index != 2 {
                XCTAssertFalse(listed.contains { $0 === element }, "\(round): line \(index + 1) has a new item")
            }
            XCTAssertTrue(again[2] === held, "\(round): the element under the cursor is the item of its line")
            XCTAssertEqual(view.index(ofAccessibilityElement: held), 2, round)
            XCTAssertTrue(view.accessibilityElement(at: 2) as? UIAccessibilityElement === held, round)
            XCTAssertTrue(held.accessibilityContainer as? ReaderTextView === view, round)
            XCTAssertFalse(view.accessibilityCursorHasLeftThePage, round)
            for element in listed where element !== held {
                XCTAssertFalse(again.contains { $0 === element }, "\(round): an item of the page as it was is listed no more")
            }
            listed = again
        }
        // A position shown on the page the cursor is on is that page shown again.
        canvas.show(ReaderTextPosition(section: 0, offset: Self.lineLength), selecting: nil)
        XCTAssertEqual(toldOfAPage(), 1)
        XCTAssertTrue(try elements(of: view)[2] === held, "a position on the same page")
        // The element is still the one that goes with the page when its line is turned away,
        // by the host and by its own action, and it keeps nothing of the heading it was.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertTrue(try cursorSent() === held)
        XCTAssertTrue(try elements(of: view)[0] === held, "the first line of the page turned to")
        XCTAssertEqual(number(held), listed.count + 1)
        XCTAssertNil(answers(held).headingLevel)
        try perform("Previous Page", on: held)
        XCTAssertTrue(try cursorSent() === held)
        XCTAssertEqual(try elements(of: view).map(answers), fresh, "the first page again, from its first line")
        // With the cursor on a control, every line of a page shown again has a new item: the
        // element it left is kept for no line.
        focus(NSObject(), from: held)
        canvas.reloadContent(keeping: nil)
        XCTAssertEqual(toldOfAPage(), 1, "a cursor on a control")
        XCTAssertFalse(try elements(of: view).contains { $0 === held }, "the element the cursor left")
        XCTAssertEqual(try elements(of: view).map(answers), fresh)
    }

    /// On an iPad's spread the cursor's element keeps its line in the column it is in, and the
    /// other column's lines are new items.
    func testTheElementUnderTheCursorKeepsItsLineInItsColumnOfASpreadShownAgain() throws {
        let canvas = host([Self.lines(100)], size: CGSize(width: 1100, height: 420)).canvas
        XCTAssertEqual(canvas.textViews.count, 2)
        let left = try elements(of: canvas.textViews[0]), right = try elements(of: canvas.textViews[1])
        let fresh = (left + right).map(answers)
        let held = right[1]
        focus(held)
        canvas.reloadContent(keeping: nil)
        XCTAssertEqual(toldOfAPage(), 1)
        let again = try canvas.textViews.flatMap { try self.elements(of: $0) }
        XCTAssertEqual(again.map(answers), fresh)
        XCTAssertTrue(try elements(of: canvas.textViews[1])[1] === held, "the second line of the right-hand page")
        XCTAssertEqual(again.filter { item in (left + right).contains { $0 === item } }.count, 1, "and every other line has a new item")
        for column in canvas.textViews { XCTAssertFalse(column.accessibilityCursorHasLeftThePage) }
    }

    func testVoiceOversScrollAnnouncesThePageAndThenSendsTheCursorToItsFirstLine() throws {
        let canvas = host([Self.lines(40)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let line = try elements(of: view)[2]
        focus(line)
        // VoiceOver asks the element under its cursor, which passes the scroll to the canvas.
        XCTAssertTrue(line.accessibilityScroll(.next))
        XCTAssertEqual(posts.map(\.notification), [.pageScrolled, .layoutChanged], "the page's number first, and the line after it")
        XCTAssertEqual(posts.first?.argument as? String, "Page 2")
        XCTAssertTrue(posts.last?.argument as? UIAccessibilityElement === line, "the element under the cursor")
        XCTAssertTrue(try elements(of: view)[0] === line, "which is the page's first line")
        // With the cursor elsewhere the page is announced and nothing else is said.
        posts.removeAll()
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

    // MARK: VoiceOver reading on by itself

    /// Whether VoiceOver, reading on by itself, turns the page once it has read `element`.
    private func turnsThePage(_ element: UIAccessibilityElement) -> Bool {
        element.accessibilityTraits.contains(.causesPageTurn)
    }

    /// VoiceOver reading on by itself (two fingers swiped down, Read All) turns the page after
    /// every item that has `causesPageTurn`, by scrolling `.next` from it once it has read it
    /// (`ReaderCanvasView.accessibilityPageTurnColumn`). So the page's last line alone has it,
    /// and says and offers all it did besides.
    func testThePagesLastLineAloneTurnsThePageForVoiceOverReadingOn() throws {
        let plain = try elements(of: try XCTUnwrap(host([Self.lines(90)]).canvas.textViews.first))
        let count = plain.count
        XCTAssertGreaterThan(count, 4)
        XCTAssertEqual(plain.map(turnsThePage), Array(repeating: false, count: count - 1) + [true])
        // The same lines with a heading for that last line: a heading still, read and offered as before.
        let canvas = host([Self.lines(90, heading: count)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let listed = try elements(of: view)
        XCTAssertEqual(listed.count, count)
        let last = try XCTUnwrap(listed.last)
        XCTAssertEqual(number(last), count)
        XCTAssertEqual(last.accessibilityTraits, [.staticText, .header, .causesPageTurn])
        XCTAssertEqual(answers(last).headingLevel, 2)
        XCTAssertEqual((last.accessibilityCustomActions ?? []).map(\.name), ["Next Page", "Previous Page", "Select Line"])
        for element in listed.dropLast() { XCTAssertEqual(element.accessibilityTraits, .staticText, "line \(number(element) ?? 0)") }
        // VoiceOver's cursor is on the line it is reading, and once it has read it VoiceOver
        // scrolls from it: the page turns and is announced, and the cursor's item is the next
        // page's first line, from which VoiceOver reads on.
        focus(last, from: listed[count - 2])
        XCTAssertTrue(last.accessibilityScroll(.next))
        XCTAssertEqual(posts.map(\.notification), [.pageScrolled, .layoutChanged])
        XCTAssertEqual(posts.first?.argument as? String, "Page 2")
        XCTAssertTrue(posts.last?.argument as? UIAccessibilityElement === last)
        posts.removeAll()
        let next = try elements(of: view)
        XCTAssertTrue(next[0] === last, "the next page's first line, the item under the cursor")
        XCTAssertEqual(number(last), count + 1)
        XCTAssertEqual(last.accessibilityTraits, .staticText, "a line of words that turns nothing")
        // No item turns the page while VoiceOver's cursor is where its turn left it, and once
        // the cursor has moved on the new page's last line does.
        XCTAssertFalse(next.contains(where: turnsThePage))
        focus(next[1], from: last)
        XCTAssertEqual(next.map(turnsThePage), Array(repeating: false, count: next.count - 1) + [true])
        XCTAssertEqual(number(next.last), count + next.count)
    }

    /// After a turn VoiceOver made itself, reading on, it looks among the first ten items of
    /// the app for one that turns the page and reads on from the first such item from the top
    /// of the screen. A new page's last line with the trait there was read alone, and the page
    /// turned again, until VoiceOver's cursor moved: in a host with nothing above the reader it
    /// read the last line of each page of two and no other (iOS 27.0 simulator). So no item
    /// turns the page until the cursor leaves the item the turn left it on, for another line or
    /// for something outside the text, but that item itself where it is the page's last.
    func testNoOtherItemTurnsThePageUntilTheCursorMovesFromWhereVoiceOversTurnLeftIt() throws {
        let count = try elements(of: try XCTUnwrap(host([Self.lines(90)]).canvas.textViews.first)).count
        // A first page of a chapter, a second of one line, and a chapter after it.
        let canvas = host([Self.lines(count + 1), Self.lines(4 * count)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        var listed = try elements(of: view)
        XCTAssertEqual(listed.count, count)
        var last = try XCTUnwrap(listed.last)
        focus(last, from: listed[count - 2])
        XCTAssertTrue(last.accessibilityScroll(.next))
        posts.removeAll()
        // The page's one line is the item under the cursor, and the page's last: it turns the page.
        listed = try elements(of: view)
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(listed[0] === last)
        XCTAssertEqual(number(last), count + 1)
        XCTAssertTrue(turnsThePage(last))
        XCTAssertTrue(last.accessibilityScroll(.next))
        posts.removeAll()
        // The next chapter's first page: the cursor's item is its first line, and nothing turns
        // the page until the cursor goes to a control and back into the text.
        listed = try elements(of: view)
        XCTAssertEqual(canvas.visibleRange?.start.section, 1)
        XCTAssertTrue(listed[0] === last)
        XCTAssertFalse(listed.contains(where: turnsThePage))
        let control = UIAccessibilityElement(accessibilityContainer: canvas)
        control.accessibilityLabel = "Next Page"
        focus(control, from: last)
        XCTAssertEqual(listed.map(turnsThePage), Array(repeating: false, count: listed.count - 1) + [true])
        // A three-finger scroll from a line is a turn VoiceOver made itself as well, and a move
        // to another line of the new page ends what it holds back.
        last = try XCTUnwrap(listed.last)
        focus(last, from: control)
        XCTAssertTrue(listed[0].accessibilityScroll(.next))
        posts.removeAll()
        listed = try elements(of: view)
        XCTAssertTrue(listed[0] === last)
        XCTAssertFalse(listed.contains(where: turnsThePage))
        focus(listed[1], from: last)
        XCTAssertEqual(listed.map(turnsThePage), Array(repeating: false, count: listed.count - 1) + [true])
        // A page the reader turns by other means holds nothing back.
        focus(control, from: listed[1])
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        posts.removeAll()
        listed = try elements(of: view)
        XCTAssertEqual(listed.map(turnsThePage), Array(repeating: false, count: listed.count - 1) + [true])
    }

    /// The scroll VoiceOver makes from that item fails on the book's last page, and where it
    /// fails VoiceOver scrolls a page to the right as well, which is the page before: no item
    /// of the last page turns the page, so VoiceOver stops at its last line. A chapter the book
    /// leaves out of its reading order is not turned to, and a page whose text is selected is
    /// not turned by VoiceOver's scroll.
    func testNoItemOfTheBooksLastPageOrOfAPageWithSelectedTextTurnsThePage() throws {
        let canvas = host([Self.lines(40), Self.lines(5)], linear: [true, false]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        XCTAssertTrue(try XCTUnwrap(try elements(of: view).last).accessibilityTraits.contains(.causesPageTurn))
        // Selected text holds the page, and VoiceOver's scroll with it.
        view.selectedRange = NSRange(location: 0, length: 4)
        XCTAssertTrue(canvas.hasSelection)
        XCTAssertFalse(try elements(of: view).contains(where: turnsThePage))
        XCTAssertFalse(canvas.accessibilityScroll(.next))
        canvas.clearSelection()
        XCTAssertTrue(try XCTUnwrap(try elements(of: view).last).accessibilityTraits.contains(.causesPageTurn))
        // The book's last page in its reading order: the chapter's last.
        while canvas.canTurnPage(forward: true) == true { XCTAssertEqual(canvas.turnPage(forward: true), .turned) }
        XCTAssertEqual(canvas.visibleRange?.start.section, 0)
        let listed = try elements(of: view)
        XCTAssertEqual(number(listed.last), 40)
        XCTAssertFalse(listed.contains(where: turnsThePage))
        let last = try XCTUnwrap(listed.last)
        focus(last)
        posts.removeAll()
        XCTAssertFalse(last.accessibilityScroll(.next))
        XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(number(try elements(of: view).last), 40)
        XCTAssertTrue(try elements(of: view).last === last)
    }

    /// Read on as VoiceOver does it, item after item with its cursor on each, and from an item
    /// that turns the page a scroll `.next` once it has read it: every line of the book once
    /// and in order, through each chapter's end, and no turn after the last. In one column and
    /// in a spread, where the left-hand page is read through before the spread turns.
    func testReadingOnByItselfReadsEveryLineOnceThroughPagesAndSpreadsAndStopsAtTheEnd() throws {
        for size in [CGSize(width: 420, height: 350), CGSize(width: 1100, height: 420)] {
            let canvas = host([Self.lines(100), Self.lines(30)], size: size).canvas
            let spread = canvas.textViews.count == 2
            XCTAssertEqual(spread, size.width > 1000)
            var read: [String] = [], cursor: UIAccessibilityElement?, turns = 0
            while turns < 80 {
                let section = try XCTUnwrap(canvas.visibleRange?.start.section)
                let columns = try canvas.textViews.map { try elements(of: $0) }
                let items = columns.flatMap { $0 }
                if let cursor { XCTAssertTrue(items.first === cursor, "\(size) turn \(turns): read on from the page's first line") }
                for item in items {
                    if item !== cursor { focus(item, from: cursor) }
                    cursor = item
                    read.append("\(section):\(number(item) ?? 0)")
                }
                XCTAssertFalse(columns.dropLast().joined().contains(where: turnsThePage), "\(size) turn \(turns): no turn from the left-hand page")
                let turning = items.filter(turnsThePage)
                guard let last = items.last, canvas.canTurnPage(forward: true) == true else {
                    XCTAssertTrue(turning.isEmpty, "\(size): the book's last page turns nothing")
                    posts.removeAll()
                    XCTAssertFalse(items.last?.accessibilityScroll(.next) ?? true)
                    XCTAssertTrue(posts.isEmpty)
                    break
                }
                XCTAssertTrue(turning.count == 1 && turning[0] === last, "\(size) turn \(turns): the last item of the last column alone")
                XCTAssertTrue(last.accessibilityScroll(.next), "\(size) turn \(turns)")
                XCTAssertEqual(posts.map(\.notification), [.pageScrolled, .layoutChanged], "\(size) turn \(turns)")
                XCTAssertTrue(posts.last?.argument as? UIAccessibilityElement === last, "\(size) turn \(turns)")
                posts.removeAll()
                turns += 1
            }
            XCTAssertEqual(read, (1...100).map { "0:\($0)" } + (1...30).map { "1:\($0)" }, "\(size)")
            XCTAssertGreaterThan(turns, spread ? 2 : 5, "\(size)")
        }
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
        let sent = try cursorSent()
        XCTAssertTrue(sent === first[1], "the element under the cursor")
        XCTAssertEqual(number(sent), target, "the line of the position shown, not the first of its page")
        let place = view.index(ofAccessibilityElement: sent)
        XCTAssertGreaterThan(place, 0)
        XCTAssertTrue(try elements(of: view)[place] === sent)
        XCTAssertEqual(try elements(of: view).map(number), Array((2 * count + 1)...(3 * count)), "every line of that page once, in order")
        // A position on the page the cursor is on turns nothing under it, and names no element.
        canvas.show(ReaderTextPosition(section: 0, offset: (target + 1) * Self.lineLength), selecting: nil)
        XCTAssertEqual(toldOfAPage(), 1)
        // The end of the text holds no line: the page that ends there is read from its top.
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        XCTAssertTrue(try cursorSent() === sent)
        XCTAssertEqual(number(sent), 1)
        canvas.show(ReaderTextPosition(section: 0, offset: 120 * Self.lineLength - 1), selecting: nil)
        XCTAssertTrue(try cursorSent() === sent)
        XCTAssertTrue(try elements(of: view)[0] === sent)
        XCTAssertEqual(number(try elements(of: view).last), 120)
    }

    func testTheCursorGoesToTheFirstLineOfASpreadAndIntoTheNextChapter() throws {
        let canvas = host([Self.lines(100), Self.lines(30)], size: CGSize(width: 1100, height: 420)).canvas
        XCTAssertEqual(canvas.textViews.count, 2)
        // From a line of the right-hand page to the left-hand page of the next spread: the
        // element under the cursor is a line of that page then, and no longer one of the right.
        var right = try elements(of: canvas.textViews[1])
        let cursor = right[1]
        let last = try XCTUnwrap(number(right.last))
        focus(cursor)
        try perform("Next Page", on: cursor)
        XCTAssertTrue(try cursorSent() === cursor)
        XCTAssertTrue(cursor.accessibilityContainer as? ReaderTextView === canvas.textViews[0])
        XCTAssertTrue(try elements(of: canvas.textViews[0])[0] === cursor)
        XCTAssertEqual(number(cursor), last + 1)
        right = try elements(of: canvas.textViews[1])
        XCTAssertFalse(right.contains { $0 === cursor })
        XCTAssertEqual(number(right.first), try XCTUnwrap(number(try elements(of: canvas.textViews[0]).last)) + 1)
        XCTAssertEqual(canvas.textViews[1].index(ofAccessibilityElement: cursor), NSNotFound)
        // On through the chapter to its last spread, and from there into the next chapter.
        for _ in 0..<40 where canvas.visibleRange?.start.section == 0 {
            try perform("Next Page", on: cursor)
            XCTAssertTrue(try cursorSent() === cursor)
            XCTAssertTrue(try elements(of: canvas.textViews[0])[0] === cursor)
        }
        XCTAssertEqual(canvas.visibleRange?.start.section, 1)
        XCTAssertEqual(number(cursor), 1, "the next chapter's first line")
        // Back into the chapter before: its last spread, read from the top of its left-hand page.
        try perform("Previous Page", on: cursor)
        XCTAssertTrue(try cursorSent() === cursor)
        XCTAssertEqual(canvas.visibleRange?.start.section, 0)
        XCTAssertTrue(try elements(of: canvas.textViews[0])[0] === cursor)
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
        // From there the element the cursor went to is the one that follows the page.
        focus(found, from: line)
        try perform("Next Page", on: found)
        XCTAssertTrue(try cursorSent() === found)
        XCTAssertTrue(try elements(of: view)[0] === found)
        XCTAssertFalse(found.accessibilityTraits.contains(.header), "the first line of the page after the heading's is no heading")
    }

    /// A move by block that turns the page does as a move by heading does: VoiceOver's cursor
    /// goes to the item the rotor gives, and nothing is posted (#711).
    func testAMoveByBlockTakesTheCursorItselfAndNothingIsPosted() throws {
        let canvas = host([Self.lines(120)]).canvas
        let view = try XCTUnwrap(canvas.textViews.first)
        let shown = try elements(of: view)
        let last = try XCTUnwrap(shown.last)
        focus(last)
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors?.first { $0.name == "Paragraphs" })
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = .next
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: last, targetRange: nil)
        // Each line is a paragraph: the next is the first line of the page after.
        let found = try XCTUnwrap(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement)
        XCTAssertTrue(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement === found)
        XCTAssertEqual(number(found), shown.count + 1)
        XCTAssertTrue(try elements(of: view).first === found, "the page after was turned to")
        XCTAssertTrue(posts.isEmpty, "the rotor's item is where the cursor goes")
        // From there the element the cursor went to is the one that follows the page.
        focus(found, from: last)
        try perform("Next Page", on: found)
        XCTAssertTrue(try cursorSent() === found)
        XCTAssertTrue(try elements(of: view)[0] === found)
        // And back by block, to the page before: the last line of the page the cursor came from.
        let top = try elements(of: view)[0]
        predicate.searchDirection = .previous
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: top, targetRange: nil)
        let back = try XCTUnwrap(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement)
        XCTAssertTrue(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement === back)
        XCTAssertEqual(number(back), 2 * shown.count)
        XCTAssertTrue(posts.isEmpty)
    }

    // MARK: What the element answers and offers on the page turned to

    private static let square = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"#07c\"/></svg>"

    /// A book whose every section is one page that opens with another kind of item: words, a
    /// table row with a link in a cell, a picture, a link, a heading, a formula and a rule.
    private static func kinds() throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("opening", "<p>Plain opening words.</p><p>A second opening line.</p>"),
            SessionCoverageBook.Section("row", "<table><tr><td>Left cell</td><td><a href=\"notes.xhtml\">Right cell jump</a></td></tr></table><p>Words under the table.</p>"),
            SessionCoverageBook.Section("picture", "<p><img src=\"square.svg\" alt=\"Square with words\"/> begins its page.</p>"),
            SessionCoverageBook.Section("link", "<p><a href=\"notes.xhtml\">Lone jump</a> words after.</p>"),
            SessionCoverageBook.Section("heading", "<h2>Heading words</h2><p>Words under the heading.</p>"),
            SessionCoverageBook.Section("formula", "<p><math xmlns=\"http://www.w3.org/1998/Math/MathML\" alttext=\"Sum stated\"><mi>x</mi><mo>+</mo><mn>2</mn></math></p><p>Words under the formula.</p>"),
            SessionCoverageBook.Section("rule", "<hr/><p>Words under the rule.</p>"),
            SessionCoverageBook.Section("closing", "<p>Plain closing words.</p>"),
            SessionCoverageBook.Section("notes", "<h1>Notes</h1><p>The linked note.</p>")],
            manifest: "<item id=\"square\" href=\"square.svg\" media-type=\"image/svg+xml\"/>", files: ["OPS/square.svg": square]))
    }

    /// What an element answers an assistive technology that asks about it. A cell of a table
    /// of data also answers where it stands in the table, and its table which cells head it.
    private struct Answers: Equatable {
        var label: String?
        var headingLevel: Int?
        var traits: UIAccessibilityTraits
        var language: String?
        var frame: CGRect
        var screenFrame: CGRect
        var actions: [String]
        var rows: NSRange?
        var columns: NSRange?
        var headers: [String]?
    }

    private func answers(_ element: UIAccessibilityElement) -> Answers {
        let label = element.accessibilityAttributedLabel
        let level = (label?.length ?? 0) > 0 ? label?.attribute(.accessibilityTextHeadingLevel, at: 0, effectiveRange: nil) as? Int : nil
        let cell = element as? UIAccessibilityContainerDataTableCell
        let rows = cell?.accessibilityRowRange(), columns = cell?.accessibilityColumnRange()
        var headers: [String]?
        if let table = element.accessibilityContainer as? UIAccessibilityContainerDataTable, let rows, let columns {
            headers = ((table.accessibilityHeaderElements?(forRow: rows.location) ?? []) + (table.accessibilityHeaderElements?(forColumn: columns.location) ?? []))
                .map { ($0 as? UIAccessibilityElement)?.accessibilityLabel ?? "" }
        }
        return Answers(label: element.accessibilityLabel, headingLevel: level, traits: element.accessibilityTraits,
                       language: element.accessibilityLanguage, frame: element.accessibilityFrameInContainerSpace,
                       screenFrame: element.accessibilityFrame, actions: (element.accessibilityCustomActions ?? []).map(\.name),
                       rows: rows, columns: columns, headers: headers)
    }

    /// One element is taken through every page of the book and back, by its own page actions
    /// and with VoiceOver's cursor never told of another item. On each page it must be what a
    /// new element for that page's first line is, in every answer, and nothing of the lines it
    /// stood for before: a row's actions on a picture, a link's address on a heading, a
    /// heading's level on a formula.
    func testTheElementUnderTheCursorIsTheFirstItemOfEachPageInEveryAnswerAndKeepsNothingOfTheLast() async throws {
        let reader = try SessionCoverageReader(publication: try Self.kinds())
        readers.append(reader)
        reader.window?.pageControls.pageTurnAnimation = Self.pageTurnAnimation
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        canvas.postAccessibilityNotification = { [weak self] in self?.posts.append(($0, $1)) }
        let pages = 8
        func shown(_ section: Int) async throws {
            try await reader.wait("section \(section)") { canvas.visibleRange?.start.section == section }
            if section == 1 { try await reader.wait("the cells' text views") { view.tableInteraction?.cells.isEmpty == false } }
        }

        // Each page with no cursor in the text: its items are new, and no element is named.
        var fresh: [[Answers]] = []
        for section in 0..<pages {
            try await shown(section)
            fresh.append(try elements(of: view).map(answers))
            if section < pages - 1 { XCTAssertEqual(canvas.turnPage(forward: true), .turned) }
        }
        XCTAssertGreaterThanOrEqual(toldOfAPage(), pages - 1)
        XCTAssertEqual(fresh.map { $0[0].label?.trimmingCharacters(in: .newlines) }, [
            "Plain opening words.", "Left cell\tRight cell jump", "Square with words", "Lone jump", "Heading words",
            "Sum stated", "Separator", "Plain closing words."])
        let turns = ["Next Page", "Previous Page"], line = turns + ["Select Line"]
        XCTAssertEqual(fresh.map { $0[0].actions }, [
            line, turns + ["Select Table Text: Left cell", "Select Table Text: Right cell jump", "Follow Table Link: Right cell jump"],
            turns + ["Inspect Image: Square with words", "Select Line"], line, line, line, turns, line])
        // The closing page's one line is its last too, and turns the page to the notes for
        // VoiceOver reading on by itself.
        XCTAssertEqual(fresh.map { $0[0].traits }, [
            .staticText, .staticText, [.staticText, .image], .link, [.staticText, .header], [.staticText, .image], [],
            [.staticText, .causesPageTurn]])
        XCTAssertEqual(fresh.map { $0[0].headingLevel }, [nil, nil, nil, nil, 2, nil, nil, nil])
        XCTAssertNotNil(fresh[5][0].language, "a formula's reading has a language of its own")
        // Words are in the book's language (#65), and so are a picture's (#548); the reader's
        // word for a rule is in none.
        XCTAssertEqual(fresh.map { $0[0].language }, ["en", "en", "en", "en", "en", "en", nil, "en"])
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        try await shown(0)
        XCTAssertGreaterThanOrEqual(toldOfAPage(), 1)

        // The cursor on the first page's second line, and that element through the book.
        let cursor = try elements(of: view)[1]
        XCTAssertEqual(answers(cursor), fresh[0][1])
        focus(cursor)
        for section in Array(1..<pages) + Array((0..<(pages - 1)).reversed()) {
            let forward = canvas.visibleRange?.start.section == section - 1
            try perform(forward ? "Next Page" : "Previous Page", on: cursor)
            try await shown(section)
            XCTAssertTrue(try cursorSent() === cursor, "section \(section)")
            let listed = try elements(of: view)
            XCTAssertTrue(listed[0] === cursor, "section \(section)")
            XCTAssertEqual(listed.map(answers), fresh[section], "section \(section)")
            // What activating it does is the line's too.
            switch section {
            case 1:
                XCTAssertFalse(cursor.accessibilityActivate(), "a row opens nothing")
                let select = try XCTUnwrap(cursor.accessibilityCustomActions?.first { $0.name == "Select Table Text: Left cell" })
                XCTAssertTrue(try XCTUnwrap(select.actionHandler)(select))
                try await reader.wait("the cell's words selected") { reader.session.selection?.text == "Left cell" }
                canvas.clearSelection()
            case 2:
                XCTAssertNil(canvas.imageInspector)
                XCTAssertTrue(cursor.accessibilityActivate(), "a picture is inspected")
                XCTAssertNotNil(canvas.imageInspector)
                canvas.imageInspector?.close()
            case 3: break // A link is followed, below: that leaves the page.
            default:
                XCTAssertFalse(cursor.accessibilityActivate(), "section \(section) opens nothing and goes nowhere")
                XCTAssertNil(canvas.imageInspector)
                XCTAssertEqual(canvas.visibleRange?.start.section, section)
            }
        }
        XCTAssertTrue(posts.isEmpty)

        // On the link's page the element is the link, and activating it follows the link. The
        // page that shows is turned under the cursor like any other, and the element is then
        // the line of the link's target.
        for section in 1...3 {
            try perform("Next Page", on: cursor)
            try await shown(section)
        }
        posts.removeAll()
        XCTAssertEqual(answers(cursor), fresh[3][0])
        XCTAssertTrue(cursor.accessibilityActivate())
        try await shown(8)
        XCTAssertTrue(try cursorSent() === cursor)
        XCTAssertEqual(cursor.accessibilityLabel?.trimmingCharacters(in: .newlines), "Notes")
        XCTAssertEqual(cursor.accessibilityTraits, [.staticText, .header])
        XCTAssertFalse(cursor.accessibilityActivate(), "a heading that was a link a page ago follows nothing")
        XCTAssertEqual(canvas.visibleRange?.start.section, 8)
        XCTAssertTrue(posts.isEmpty)
    }

    // MARK: A data table's cell

    /// A book whose pages open with each kind of cell, between pages of lines: a header cell
    /// of plain words, a cell that is one link, a cell of a picture without words, and the
    /// cells of a table longer than a page.
    private static func cells() throws -> EPUBPublication {
        let rows = (1...60).map { String(format: "<tr><td>Entry %02d</td><td>Sum %02d</td></tr>", $0, $0) }.joined()
        return try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("opening", "<p>Plain opening words.</p><p>A second opening line.</p>"),
            SessionCoverageBook.Section("stations", "<table><tr><th>Station</th><th>Opened</th></tr><tr><td>Alder</td><td>1901</td></tr></table><p>Words under the stations.</p>"),
            SessionCoverageBook.Section("jumps", "<table><tr><th><a href=\"notes.xhtml\">Jump cell</a></th><th>Beside the jump</th></tr></table>"),
            SessionCoverageBook.Section("pictures", "<table><tr><th><img src=\"square.svg\"/></th><th>Beside the picture</th></tr></table>"),
            SessionCoverageBook.Section("ledger", "<table><thead><tr><th>Entry</th><th>Sum</th></tr></thead><tbody>\(rows)</tbody></table><p>Words under the ledger.</p>"),
            SessionCoverageBook.Section("closing", "<p>Plain closing words.</p><p>A second closing line.</p>"),
            SessionCoverageBook.Section("notes", "<h1>Notes</h1><p>The linked note.</p>")],
            manifest: "<item id=\"square\" href=\"square.svg\" media-type=\"image/svg+xml\"/>", files: ["OPS/square.svg": square]))
    }

    /// What a page gives an assistive technology, in reading order: each line, and each cell
    /// of a table of data where the table's element stands.
    private func items(of view: ReaderTextView) throws -> [UIAccessibilityElement] {
        try elements(of: view).flatMap { element -> [UIAccessibilityElement] in
            guard element is UIAccessibilityContainerDataTable else { return [element] }
            return try XCTUnwrap(element.accessibilityElements as? [UIAccessibilityElement])
        }
    }

    /// Whether `element` is a cell of a data table to one who asks it, as UIKit does, for the
    /// protocol of one and for the two things the protocol has a cell answer.
    private func answersAsCell(_ element: UIAccessibilityElement) -> [Bool] {
        [element.conforms(to: UIAccessibilityContainerDataTableCell.self),
         element.responds(to: #selector(UIAccessibilityContainerDataTableCell.accessibilityRowRange)),
         element.responds(to: #selector(UIAccessibilityContainerDataTableCell.accessibilityColumnRange))]
    }

    /// A line and a data table's cell are one kind of element, so the element under the cursor
    /// follows the page into a table and out of one, and VoiceOver's rotor stays on the page
    /// action chosen: a line's element becomes the cell that opens the page turned to, and a
    /// cell's the line. From a cell to a cell VoiceOver is given the new cell's own element,
    /// since it says a cell's row and column of an item its cursor comes to. The cursor is
    /// taken through the book and back by the page actions of the element it is on. On each
    /// page that element must be what a new element for the page's first item is, in every
    /// answer and nothing of the item before: a cell in the list of the table that page shows
    /// and nowhere in the view's, with that cell's row, column, header cells and actions, or
    /// a line in the view's list that is no cell to whoever asks.
    func testTheElementUnderTheCursorIsALineOnOnePageAndACellOfADataTableOnAnother() async throws {
        let reader = try SessionCoverageReader(publication: try Self.cells())
        readers.append(reader)
        reader.window?.pageControls.pageTurnAnimation = Self.pageTurnAnimation
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        canvas.postAccessibilityNotification = { [weak self] in self?.posts.append(($0, $1)) }
        let closing = 5
        /// Waits for the page that `turn` shows.
        func page(_ label: String, after turn: () throws -> Void) async throws {
            let from = canvas.visibleRange?.start
            try turn()
            try await reader.wait("another page, \(label)") { canvas.visibleRange?.start != from }
        }

        // Each page with no cursor in the text: its items are new, and no element is named.
        var fresh: [[Answers]] = [], sections: [Int] = []
        while true {
            let section = try XCTUnwrap(canvas.visibleRange?.start.section)
            fresh.append(try items(of: view).map(answers))
            sections.append(section)
            if section == closing { break }
            try await page("unturned page \(fresh.count)") { XCTAssertNotEqual(canvas.turnPage(forward: true), .atBoundary) }
        }
        XCTAssertGreaterThanOrEqual(toldOfAPage(), fresh.count - 1)
        let ledger = sections.indices.filter { sections[$0] == 4 }
        XCTAssertGreaterThan(ledger.count, 2, "the long table must take three pages for a turn from cell to cell inside it")
        XCTAssertEqual(sections.filter { $0 != 4 }, [0, 1, 2, 3, 5], "every other section is one page")
        // Each page's last item turns the page for VoiceOver reading on by itself, and no other
        // item: a cell of the long table where the table goes on over the page's end.
        for (place, page) in fresh.enumerated() {
            XCTAssertEqual(page.map { $0.traits.contains(.causesPageTurn) }, page.indices.map { $0 == page.count - 1 }, "page \(place)")
        }
        XCTAssertTrue(ledger.dropLast().allSatisfy { fresh[$0].last?.rows != nil }, "a page inside the long table ends with a cell")
        // What each page opens with: lines, then a cell of each kind, the long table's pages, lines.
        let opens = fresh.map { $0[0] }
        XCTAssertEqual(opens.map { $0.rows != nil }, [false, true, true, true] + ledger.map { _ in true } + [false])
        XCTAssertEqual(opens.prefix(4).map(\.label), ["Plain opening words.\n", "Station", "Jump cell", nil])
        XCTAssertEqual(opens[4].label, "Entry")
        XCTAssertEqual(opens.last?.label, "Plain closing words.\n")
        let turns = ["Next Page", "Previous Page"]
        XCTAssertEqual(opens.prefix(5).map(\.actions), [
            turns + ["Select Line"], turns + ["Select Cell Text"], turns + ["Select Cell Text", "Follow Link: Jump cell"], turns + ["Inspect Image"],
            turns + ["Select Cell Text"]])
        XCTAssertEqual(opens.prefix(4).map(\.traits), [.staticText, .staticText, .link, [.staticText, .image]])
        for (index, place) in ledger.enumerated().dropFirst() {
            XCTAssertEqual(opens[place].columns, NSRange(location: 0, length: 1), "page \(place)")
            XCTAssertGreaterThan(try XCTUnwrap(opens[place].rows).location, try XCTUnwrap(opens[ledger[index - 1]].rows).location,
                                 "page \(place) goes on below the rows of the page before")
            XCTAssertEqual(opens[place].headers, ["Entry"], "page \(place): the column's header by name, from a row that is not on it")
            XCTAssertTrue(opens[place].label?.hasPrefix("Entry ") == true, "page \(place)")
        }
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        try await reader.wait("the first page") { canvas.visibleRange?.start.section == 0 }
        XCTAssertGreaterThanOrEqual(toldOfAPage(), 1)

        // The cursor on the first page's second line. From there each page is turned by the
        // action of the element the cursor is on, and the cursor follows as VoiceOver's does:
        // it stays on the element it is given back, and goes to one it is given anew.
        var cursor = try elements(of: view)[1], place = 0, stood = 0, given = 0
        XCTAssertEqual(answers(cursor), fresh[0][1])
        XCTAssertEqual(answersAsCell(cursor), [false, false, false], "a line is no cell")
        focus(cursor)
        func turn(to next: Int) async throws {
            let left = answers(cursor), wasCell = left.rows != nil, isCell = opens[next].rows != nil
            try await page("page \(next)") { try perform(next > place ? "Next Page" : "Previous Page", on: cursor) }
            place = next
            let sent = try cursorSent()
            let listed = try items(of: view)
            XCTAssertTrue(listed[0] === sent, "page \(place): VoiceOver is given the page's first item")
            XCTAssertEqual(listed.map(answers), fresh[place], "page \(place)")
            if wasCell && isCell {
                XCTAssertFalse(sent === cursor, "page \(place): from a cell to a cell, the new cell's own element")
                XCTAssertFalse(listed.contains { $0 === cursor }, "page \(place)")
                XCTAssertEqual(answers(cursor).label, left.label, "page \(place): the cell left is what it was")
                XCTAssertEqual(answers(cursor).rows, left.rows, "page \(place)")
                XCTAssertEqual(answersAsCell(cursor), [true, true, true], "page \(place)")
                focus(sent, from: cursor)
                cursor = sent
                given += 1
            } else {
                XCTAssertTrue(sent === cursor, "page \(place): the element under the cursor, which was \(wasCell ? "a cell" : "a line")")
                stood += 1
            }
            XCTAssertFalse(view.accessibilityCursorHasLeftThePage, "page \(place)")
            XCTAssertEqual(answersAsCell(cursor), [isCell, isCell, isCell], "page \(place)")
            XCTAssertEqual(cursor is UIAccessibilityContainerDataTableCell, isCell, "page \(place)")
            guard isCell else {
                XCTAssertTrue(cursor.accessibilityContainer as? ReaderTextView === view, "page \(place)")
                XCTAssertEqual(view.index(ofAccessibilityElement: cursor), 0, "page \(place)")
                return
            }
            let table = try XCTUnwrap(try elements(of: view).first as? UIAccessibilityElement & UIAccessibilityContainerDataTable, "page \(place)")
            XCTAssertTrue(cursor.accessibilityContainer as? UIAccessibilityElement === table, "page \(place): it is in the table shown")
            XCTAssertEqual(table.index(ofAccessibilityElement: cursor), 0, "page \(place)")
            XCTAssertTrue(table.accessibilityElement(at: 0) as? UIAccessibilityElement === cursor, "page \(place)")
            XCTAssertEqual(view.index(ofAccessibilityElement: cursor), NSNotFound, "page \(place): a cell is in its table's list")
            let rows = try XCTUnwrap(opens[place].rows), columns = try XCTUnwrap(opens[place].columns)
            XCTAssertTrue(table.accessibilityDataTableCellElement(forRow: rows.location, column: columns.location) as? UIAccessibilityElement === cursor,
                          "page \(place): the table finds it by its row and column")
            XCTAssertEqual(table.accessibilityElements?.count, fresh[place].filter { $0.rows != nil }.count, "page \(place): every cell once")
            // What its actions do is the cell's too: of plain cells, each selects its own words.
            switch sections[place] {
            case 2: break // A cell that is a link is followed, below: that leaves the page.
            case 3:
                XCTAssertNil(canvas.imageInspector)
                XCTAssertTrue(cursor.accessibilityActivate(), "a cell of one picture is inspected")
                XCTAssertNotNil(canvas.imageInspector)
                canvas.imageInspector?.close()
            default:
                XCTAssertFalse(cursor.accessibilityActivate(), "page \(place): a cell of plain words opens nothing")
                let select = try XCTUnwrap(cursor.accessibilityCustomActions?.first { $0.name == "Select Cell Text" }, "page \(place)")
                XCTAssertTrue(try XCTUnwrap(select.actionHandler)(select), "page \(place)")
                let words = try XCTUnwrap(opens[place].label)
                try await reader.wait("page \(place): the words of \(words) selected") { reader.session.selection?.text == words }
                canvas.clearSelection()
            }
        }
        for next in Array(1..<fresh.count) + Array((0..<(fresh.count - 1)).reversed()) { try await turn(to: next) }
        XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(answers(cursor), fresh[0][0], "back on the first page it is the first line")
        // Into the first table and out of the last, each way: four times the element went with
        // the page, a line that became a cell or a cell that became a line.
        XCTAssertEqual(stood, 4)
        XCTAssertEqual(given, 2 * (fresh.count - 3), "and from cell to cell it was given anew")

        // The cell that is a link is two turns from the first page, the second from a cell,
        // and activating it follows the link. The page that shows is turned under the cursor
        // like any other, and the element, a cell until then, is the line of the link's
        // target, and no cell.
        for next in 1...2 { try await turn(to: next) }
        posts.removeAll()
        XCTAssertEqual(answers(cursor), fresh[2][0])
        try await page("the link's target") { XCTAssertTrue(cursor.accessibilityActivate()) }
        XCTAssertEqual(canvas.visibleRange?.start.section, 6)
        XCTAssertTrue(try cursorSent() === cursor)
        XCTAssertEqual(cursor.accessibilityLabel?.trimmingCharacters(in: .newlines), "Notes")
        XCTAssertEqual(cursor.accessibilityTraits, [.staticText, .header])
        XCTAssertEqual(answersAsCell(cursor), [false, false, false])
        XCTAssertEqual(cursor.accessibilityCustomActions?.map(\.name), turns + ["Select Line"],
                       "a heading that was a link's cell a page ago offers what a line offers alone")
        XCTAssertFalse(cursor.accessibilityActivate(), "and follows nothing")
        XCTAssertEqual(canvas.visibleRange?.start.section, 6)
        XCTAssertTrue(posts.isEmpty)
    }

    /// The same page shown again under a cursor that is in a data table's cell: the host makes
    /// the reader dark, every section is built again and the table is a new one. The cell
    /// keeps its element as a line does, and its table's element is kept with it, for the
    /// table as it was built again: with a new element for the table VoiceOver said the kept
    /// cell's header cells and no longer its row or column (`doc/testing.md#voiceover-testing`,
    /// "Harness pitfalls and current results"). VoiceOver's cursor comes to no other item
    /// there, so it says nothing, and what it chose in its rotor stands. Across a turn a cell
    /// that becomes another cell is given that cell's own element, whose row and column
    /// VoiceOver is to say
    /// (`testTheElementUnderTheCursorIsALineOnOnePageAndACellOfADataTableOnAnother`).
    func testACellUnderTheCursorIsTheItemOfItsCellWhenItsPageIsShownAgain() async throws {
        let reader = try SessionCoverageReader(publication: try Self.cells())
        readers.append(reader)
        reader.window?.pageControls.pageTurnAnimation = Self.pageTurnAnimation
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        try await reader.wait("the stations") { canvas.visibleRange?.start.section == 1 }
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.isEmpty == false }
        canvas.postAccessibilityNotification = { [weak self] in self?.posts.append(($0, $1)) }
        let before = try items(of: view)
        let fresh = before.map(answers)
        XCTAssertEqual(fresh.map(\.label), ["Station", "Opened", "Alder", "1901", "Words under the stations."])
        let was = try XCTUnwrap(try elements(of: view).first)
        let cell = before[3]
        focus(cell)

        let dark = reader.state.status.effectiveAppearance != .dark
        try await reader.session.send(.style(EPUBReaderStyle(isDark: dark)))
        try await reader.wait("the page shown again") { !self.posts.isEmpty }
        try await reader.settle()
        try await reader.wait("the cells' text views again") { view.tableInteraction?.cells.isEmpty == false }
        XCTAssertGreaterThanOrEqual(toldOfAPage(), 1, "told of the page, and no element named")
        let after = try items(of: view)
        XCTAssertEqual(after.map(answers), fresh, "every item once and in order, each what a new one for it is")
        XCTAssertTrue(after[3] === cell, "the element under the cursor is the item of its cell")
        for (index, item) in after.enumerated() where index != 3 {
            XCTAssertFalse(before.contains { $0 === item }, "item \(index + 1) is a new one")
        }
        let table = try XCTUnwrap(try elements(of: view).first as? UIAccessibilityElement & UIAccessibilityContainerDataTable)
        XCTAssertTrue(table === was, "its table's element is kept with it")
        XCTAssertEqual(try elements(of: view).filter { $0 is UIAccessibilityContainerDataTable }.count, 1, "and is the one table listed")
        XCTAssertTrue(cell.accessibilityContainer as? UIAccessibilityElement === table)
        for item in after.dropLast() { XCTAssertTrue(item.accessibilityContainer as? UIAccessibilityElement === table, "every cell is in its list") }
        // It answers for the table as it was built again: a column's header cell is the one listed now.
        let header = table.accessibilityHeaderElements?(forColumn: 1)?.first as? UIAccessibilityElement
        XCTAssertTrue(header === after[1], "the header cell of the page shown again")
        XCTAssertFalse(header === before[1])
        XCTAssertEqual(table.accessibilityRowCount(), 2)
        XCTAssertEqual(table.accessibilityFrameInContainerSpace, after.dropLast().reduce(CGRect.null) { $0.union($1.accessibilityFrameInContainerSpace) })
        XCTAssertEqual(table.index(ofAccessibilityElement: cell), 3)
        XCTAssertTrue(table.accessibilityElement(at: 3) as? UIAccessibilityElement === cell)
        XCTAssertTrue(table.accessibilityDataTableCellElement(forRow: 1, column: 1) as? UIAccessibilityElement === cell,
                      "the table finds it by its row and column")
        XCTAssertEqual(view.index(ofAccessibilityElement: cell), NSNotFound, "a cell is in its table's list and not the view's")
        XCTAssertEqual(answersAsCell(cell), [true, true, true])
        XCTAssertFalse(view.accessibilityCursorHasLeftThePage)
        // Its page turned, the element is the line that opens the page before, as it was.
        let from = canvas.visibleRange?.start
        try perform("Previous Page", on: cell)
        try await reader.wait("the page before") { canvas.visibleRange?.start != from }
        XCTAssertTrue(try cursorSent() === cell)
        XCTAssertEqual(cell.accessibilityLabel, "Plain opening words.\n")
        XCTAssertEqual(answersAsCell(cell), [false, false, false])
    }

    /// On an iPad's spread the element goes with the page into the other column. A cell of
    /// the right-hand page that ends the long table becomes the first line of the next
    /// chapter, in the left-hand column, and from that line Previous Page makes it the first
    /// cell of the spread before: it answers for its place on the screen through the column
    /// it is in now. From a cell to the first cell of the next spread VoiceOver is given that
    /// cell's own element.
    func testACellAndALineStandForEachOtherAcrossASpread() async throws {
        let reader = try SessionCoverageReader(publication: try Self.cells())
        readers.append(reader)
        reader.window?.pageControls.pageTurnAnimation = Self.pageTurnAnimation
        reader.window?.resize(to: CGSize(width: 1100, height: 520))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        canvas.postAccessibilityNotification = { [weak self] in self?.posts.append(($0, $1)) }
        canvas.show(ReaderTextPosition(section: 4, offset: 0), selecting: nil)
        try await reader.wait("the long table") { canvas.visibleRange?.start.section == 4 }
        XCTAssertGreaterThanOrEqual(toldOfAPage(), 1, "shown with no cursor in the text")
        let columns = canvas.textViews.filter { !$0.isHidden }
        XCTAssertEqual(columns.count, 2)
        func spread(_ label: String, after turn: () throws -> Void) async throws {
            let from = canvas.visibleRange?.start
            try turn()
            try await reader.wait(label) { canvas.visibleRange?.start != from }
        }
        func rows(_ element: UIAccessibilityElement) -> Int? { (element as? UIAccessibilityContainerDataTableCell)?.accessibilityRowRange().location }

        // From a cell of the right-hand page to the first cell of the next spread: a new element.
        var cursor = try XCTUnwrap(try items(of: columns[1]).dropFirst(3).first)
        XCTAssertEqual(answersAsCell(cursor), [true, true, true], "the right-hand page holds rows of the table")
        let before = try XCTUnwrap(rows(cursor))
        focus(cursor)
        try await spread("the next spread") { try perform("Next Page", on: cursor) }
        var sent = try cursorSent()
        XCTAssertFalse(sent === cursor)
        XCTAssertTrue(try items(of: columns[0])[0] === sent, "the first cell of the left-hand page")
        XCTAssertGreaterThan(try XCTUnwrap(rows(sent)), before)
        focus(sent, from: cursor)
        cursor = sent

        // On to the spread that ends the table, and from a cell of its last page into the next chapter.
        func shown() throws -> [UIAccessibilityElement] { try columns.filter { !$0.isHidden }.flatMap { try self.items(of: $0) } }
        var spreads = 0
        while try !shown().contains(where: { $0.accessibilityLabel?.hasPrefix("Words under the ledger.") == true }), spreads < 40 {
            try await spread("a later spread") { try perform("Next Page", on: cursor) }
            sent = try cursorSent()
            XCTAssertFalse(sent === cursor, "from cell to cell")
            focus(sent, from: cursor)
            cursor = sent
            spreads += 1
        }
        let cell = try XCTUnwrap(try shown().last { self.answersAsCell($0) == [true, true, true] }, "the table's last cell")
        XCTAssertEqual(cell.accessibilityLabel, "Sum 60")
        focus(cell, from: cursor)
        try await spread("the next chapter") { try perform("Next Page", on: cell) }
        XCTAssertEqual(canvas.visibleRange?.start.section, 5)
        XCTAssertTrue(try cursorSent() === cell, "the element under the cursor")
        XCTAssertTrue(try elements(of: columns[0])[0] === cell, "which is the left-hand page's first line")
        XCTAssertTrue(cell.accessibilityContainer as? ReaderTextView === columns[0])
        XCTAssertEqual(cell.accessibilityLabel, "Plain closing words.\n")
        XCTAssertEqual(answersAsCell(cell), [false, false, false])
        // A line's place on the screen is UIKit's to work out, from its place in its column.
        XCTAssertTrue(columns[0].bounds.insetBy(dx: -0.5, dy: -0.5).contains(cell.accessibilityFrameInContainerSpace))
        for column in columns { XCTAssertFalse(column.accessibilityCursorHasLeftThePage) }

        // Back: the line becomes the first cell of the spread before, in the left-hand column's table.
        try await spread("the table's last spread") { try perform("Previous Page", on: cell) }
        XCTAssertEqual(canvas.visibleRange?.start.section, 4)
        XCTAssertTrue(try cursorSent() === cell)
        let left = try items(of: columns[0])
        XCTAssertTrue(left[0] === cell, "the first cell of the left-hand page")
        XCTAssertEqual(answersAsCell(cell), [true, true, true])
        XCTAssertTrue(cell.accessibilityLabel?.hasPrefix("Entry ") == true)
        let table = try XCTUnwrap(try elements(of: columns[0]).first as? UIAccessibilityElement & UIAccessibilityContainerDataTable)
        XCTAssertTrue(cell.accessibilityContainer as? UIAccessibilityElement === table)
        XCTAssertTrue(table.accessibilityDataTableCellElement(forRow: try XCTUnwrap(rows(cell)), column: 0) as? UIAccessibilityElement === cell)
        XCTAssertEqual(cell.accessibilityFrame, UIAccessibility.convertToScreenCoordinates(cell.accessibilityFrameInContainerSpace, in: columns[0]),
                       "a cell's place on the screen is its column's, whatever holds it")
        XCTAssertTrue(columns[0].bounds.insetBy(dx: -0.5, dy: -0.5).contains(cell.accessibilityFrameInContainerSpace))
        XCTAssertTrue(table.accessibilityElement(at: 1) as? UIAccessibilityElement === left[1], "its neighbour is the cell beside it")
        XCTAssertTrue(left[1].accessibilityLabel?.hasPrefix("Sum ") == true)
        for column in columns { XCTAssertFalse(column.accessibilityCursorHasLeftThePage) }
    }
}

/// Every test above again with each page turn sliding: what VoiceOver is told after a turn, and
/// where its cursor goes, are what they are with none (#688).
@MainActor final class SlidingPageTurnAccessibilityTests: PageTurnAccessibilityTests {
    override class var pageTurnAnimation: EPUBPageTurnAnimation { .slide }
}
#endif
