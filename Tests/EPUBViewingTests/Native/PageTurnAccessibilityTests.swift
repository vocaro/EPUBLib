#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// Where an assistive technology's cursor goes when the page it is on is turned, on iPhone and
/// iPad ("Input and accessibility" in `doc/native-viewer.md`). API level only: the cursor is
/// put on a line as UIKit tells the reader of it, and no assistive technology is driven.
/// `doc/voiceover-testing.md` has what VoiceOver then did on a device.
@MainActor final class PageTurnAccessibilityTests: XCTestCase {
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
        // And that kept element stands for the first line when the page does turn.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertTrue(try cursorSent() === held)
        XCTAssertTrue(try elements(of: view)[0] === held)
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
        // A position on the page the cursor is on turns nothing under it.
        canvas.show(ReaderTextPosition(section: 0, offset: (target + 1) * Self.lineLength), selecting: nil)
        XCTAssertTrue(posts.isEmpty)
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

        // Each page with no cursor in the text: its items are new, and nothing is posted.
        var fresh: [[Answers]] = []
        for section in 0..<pages {
            try await shown(section)
            fresh.append(try elements(of: view).map(answers))
            if section < pages - 1 { XCTAssertEqual(canvas.turnPage(forward: true), .turned) }
        }
        XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(fresh.map { $0[0].label?.trimmingCharacters(in: .newlines) }, [
            "Plain opening words.", "Left cell\tRight cell jump", "Square with words", "Lone jump", "Heading words",
            "Sum stated", "Separator", "Plain closing words."])
        let turns = ["Next Page", "Previous Page"]
        XCTAssertEqual(fresh.map { $0[0].actions }, [
            turns, turns + ["Select Table Text: Left cell", "Select Table Text: Right cell jump", "Follow Table Link: Right cell jump"],
            turns + ["Inspect Image: Square with words"], turns, turns, turns, turns, turns])
        XCTAssertEqual(fresh.map { $0[0].traits }, [
            .staticText, .staticText, [.staticText, .image], .link, [.staticText, .header], [.staticText, .image], [], .staticText])
        XCTAssertEqual(fresh.map { $0[0].headingLevel }, [nil, nil, nil, nil, 2, nil, nil, nil])
        XCTAssertNotNil(fresh[5][0].language, "a formula's reading has a language of its own")
        XCTAssertEqual(fresh.map { $0[0].language == nil }, [true, true, true, true, true, false, true, true])
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        try await shown(0)
        XCTAssertTrue(posts.isEmpty)

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

        // Each page with no cursor in the text: its items are new, and nothing is posted.
        var fresh: [[Answers]] = [], sections: [Int] = []
        while true {
            let section = try XCTUnwrap(canvas.visibleRange?.start.section)
            fresh.append(try items(of: view).map(answers))
            sections.append(section)
            if section == closing { break }
            try await page("unturned page \(fresh.count)") { XCTAssertNotEqual(canvas.turnPage(forward: true), .atBoundary) }
        }
        XCTAssertTrue(posts.isEmpty)
        let ledger = sections.indices.filter { sections[$0] == 4 }
        XCTAssertGreaterThan(ledger.count, 2, "the long table must take three pages for a turn from cell to cell inside it")
        XCTAssertEqual(sections.filter { $0 != 4 }, [0, 1, 2, 3, 5], "every other section is one page")
        // What each page opens with: lines, then a cell of each kind, the long table's pages, lines.
        let opens = fresh.map { $0[0] }
        XCTAssertEqual(opens.map { $0.rows != nil }, [false, true, true, true] + ledger.map { _ in true } + [false])
        XCTAssertEqual(opens.prefix(4).map(\.label), ["Plain opening words.\n", "Station", "Jump cell", nil])
        XCTAssertEqual(opens[4].label, "Entry")
        XCTAssertEqual(opens.last?.label, "Plain closing words.\n")
        let turns = ["Next Page", "Previous Page"]
        XCTAssertEqual(opens.prefix(5).map(\.actions), [
            turns, turns + ["Select Cell Text"], turns + ["Select Cell Text", "Follow Link: Jump cell"], turns + ["Inspect Image"],
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
        XCTAssertTrue(posts.isEmpty)

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
        XCTAssertEqual(cursor.accessibilityCustomActions?.map(\.name), turns, "a heading that was a link's cell a page ago offers the turns alone")
        XCTAssertFalse(cursor.accessibilityActivate(), "and follows nothing")
        XCTAssertEqual(canvas.visibleRange?.start.section, 6)
        XCTAssertTrue(posts.isEmpty)
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
        reader.window?.resize(to: CGSize(width: 1100, height: 520))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        canvas.postAccessibilityNotification = { [weak self] in self?.posts.append(($0, $1)) }
        canvas.show(ReaderTextPosition(section: 4, offset: 0), selecting: nil)
        try await reader.wait("the long table") { canvas.visibleRange?.start.section == 4 }
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
        XCTAssertEqual(cell.accessibilityFrame, UIAccessibility.convertToScreenCoordinates(cell.accessibilityFrameInContainerSpace, in: columns[0]),
                       "where it is on the screen is where the left-hand column shows it")
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
#endif
