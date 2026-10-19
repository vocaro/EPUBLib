#if os(macOS)
import AppKit
import EPUBCore
import XCTest
@testable import EPUBViewing

/// Where VoiceOver on Mac enters a page column: at its insertion point, which a read-only column
/// does not draw. A place shown (a link's target, a search result, a contents entry, a bookmark)
/// puts it at the start of the place's line, in the column that holds it; a page turn, a relayout
/// and the start or end of a section a turn reaches keep every column's first line (#383). What
/// VoiceOver does with it is heard only in a speech session (doc/testing.md#voiceover-testing).
@MainActor final class PageEntryAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        try await super.tearDown()
    }

    private static let numbered = CanvasText.body((0..<900).map { String(format: "word%04d", $0) }.joined(separator: " "))

    private struct Reader {
        let canvas: ReaderCanvasView
        let source: FakeCanvasSource
        let recorder: CanvasRecorder
        let window: NSWindow
    }

    /// A canvas at its first page, in a window that is never ordered in, so that a live VoiceOver
    /// session on this Mac hears nothing of it. 1100 points wide is a spread of two columns.
    private func reader(width: CGFloat, sections: [NSAttributedString?] = [numbered], shown: Bool = true) -> Reader {
        let canvas = ReaderCanvasView(frame: .zero), source = FakeCanvasSource(sections), recorder = CanvasRecorder()
        canvas.dataSource = source
        canvas.delegate = recorder
        let window = makeMacTestWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 500),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        if shown {
            window.contentView = canvas
            canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        return Reader(canvas: canvas, source: source, recorder: recorder, window: window)
    }

    /// A place in the middle of line `line` of column `slot` of the spread on screen.
    private func place(inColumn slot: Int, line: Int, of canvas: ReaderCanvasView) throws -> ReaderTextPosition {
        let column = try XCTUnwrap(canvas.textViews.indices.contains(slot) ? canvas.textViews[slot] : nil)
        let lines = column.pageAccessibilityLines
        XCTAssertGreaterThan(lines.count, line)
        let range = lines[line].range
        return ReaderTextPosition(section: try XCTUnwrap(column.placement.section),
                                  offset: column.placement.offset + range.location + range.length / 2)
    }

    private func assertFirstLines(_ canvas: ReaderCanvasView, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for (index, column) in canvas.textViews.enumerated() {
            XCTAssertEqual(column.selectedRange, NSRange(location: 0, length: 0), "\(label), column \(index)", file: file, line: line)
            XCTAssertEqual(column.accessibilityInsertionPointLineNumber(), 0, "\(label), column \(index)", file: file, line: line)
            XCTAssertEqual(column.entryLocation, 0, "\(label), column \(index)", file: file, line: line)
        }
    }

    func testAPlaceShownIsEnteredAtTheStartOfItsLineInTheColumnThatHoldsIt() throws {
        let reader = reader(width: 1100)
        let canvas = reader.canvas
        XCTAssertEqual(canvas.textViews.count, 2)
        assertFirstLines(canvas, "the book's first spread")
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let targets = [(try place(inColumn: 1, line: 5, of: canvas), 1, 5), (try place(inColumn: 0, line: 3, of: canvas), 0, 3)]
        let pageStart = ReaderTextPosition(section: 0, offset: canvas.textViews[1].placement.offset)
        for (target, slot, number) in targets {
            canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            assertFirstLines(canvas, "the place shown at the book's start")
            canvas.show(target, selecting: nil)
            let shown = try XCTUnwrap(canvas.entryLine(holding: target))
            XCTAssertTrue(shown.column === canvas.textViews[slot], "the place is in column \(slot)")
            XCTAssertEqual(shown.index, number)
            XCTAssertGreaterThan(shown.start, 0)
            for (index, column) in canvas.textViews.enumerated() {
                let start = index == slot ? shown.start : 0
                XCTAssertEqual(column.selectedRange, NSRange(location: start, length: 0), "column \(index)")
                XCTAssertEqual(column.accessibilitySelectedTextRange(), NSRange(location: start, length: 0), "column \(index)")
                XCTAssertEqual(column.accessibilityInsertionPointLineNumber(), index == slot ? number : 0, "column \(index)")
                XCTAssertEqual(column.entryLocation, start, "column \(index)")
            }
            // The rows of a page before, should VoiceOver be on one, stand where it enters.
            let frame = try XCTUnwrap(shown.column.lineFrame(containing: shown.start))
            let origin = shown.column.containerOrigin
            XCTAssertEqual(shown.column.departedRowFrame, frame.offsetBy(dx: origin.x, dy: origin.y))
        }
        // A place at the start of a column's page is on its first line.
        canvas.show(pageStart, selecting: nil)
        assertFirstLines(canvas, "a place at the start of a page")
        XCTAssertFalse(reader.window.isVisible)
    }

    /// VoiceOver stays in the column that has keyboard focus, so focus in another column of the
    /// spread goes to the place's column. Focus anywhere else is left where it is.
    func testKeyboardFocusInAnotherColumnGoesToThePlacesColumn() throws {
        let reader = reader(width: 1100)
        let canvas = reader.canvas, window = reader.window
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let right = try place(inColumn: 1, line: 5, of: canvas), left = try place(inColumn: 0, line: 4, of: canvas)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        let columns = canvas.textViews
        window.makeFirstResponder(columns[0])
        canvas.show(right, selecting: nil)
        XCTAssertTrue(window.firstResponder === columns[1], "focus went from the first column to the place's")
        canvas.show(left, selecting: nil)
        XCTAssertTrue(window.firstResponder === columns[0], "focus went from the second column to the place's")
        canvas.show(left, selecting: nil)
        XCTAssertTrue(window.firstResponder === columns[0], "focus in the place's column stays there")
        window.makeFirstResponder(nil)
        canvas.show(right, selecting: nil)
        XCTAssertTrue(window.firstResponder === window, "focus outside the columns is left where it is")
        window.makeFirstResponder(canvas)
        canvas.show(right, selecting: nil)
        XCTAssertTrue(window.firstResponder === canvas, "focus outside the columns is left where it is")
        // A page turn's show of a section's start moves no focus.
        window.makeFirstResponder(columns[1])
        canvas.show(left, selecting: nil, entry: .firstLine)
        XCTAssertTrue(window.firstResponder === columns[1])
        XCTAssertFalse(window.isVisible)
    }

    func testPageTurnsAndRelayoutsEnterAtTheFirstLine() async throws {
        let reader = reader(width: 1100)
        let canvas = reader.canvas
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let target = try place(inColumn: 1, line: 5, of: canvas)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)

        canvas.show(target, selecting: nil)
        XCTAssertGreaterThan(canvas.textViews[1].selectedRange.location, 0)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        assertFirstLines(canvas, "a turn on from the place")
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertNotNil(canvas.entryLine(holding: target), "back at the place's spread")
        assertFirstLines(canvas, "a turn back to the place's spread")

        canvas.show(target, selecting: nil)
        canvas.reloadContent(keeping: nil)
        XCTAssertNotNil(canvas.entryLine(holding: target), "the text built again keeps the place on screen")
        assertFirstLines(canvas, "the text built again")

        canvas.show(target, selecting: nil)
        let width = canvas.textViews[0].frame.width
        reader.window.setContentSize(CGSize(width: 1000, height: 500))
        reader.window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(10)
        while canvas.textViews[0].frame.width == width, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotEqual(canvas.textViews[0].frame.width, width, "the spread was laid out for the new width")
        XCTAssertNotNil(canvas.entryLine(holding: target), "a resize keeps the place on screen")
        assertFirstLines(canvas, "a resize")

        canvas.show(target, selecting: nil, entry: .firstLine)
        assertFirstLines(canvas, "a show for the page's first line")
        XCTAssertFalse(reader.window.isVisible)
    }

    /// A page turn that reaches another section shows its start or its end, which is no place
    /// the person was taken to, and a position with no character of its own is on no line.
    func testTheStartOrEndOfASectionAPageTurnReachesIsEnteredAtTheFirstLine() throws {
        let reader = reader(width: 1100, sections: [Self.numbered, Self.numbered, nil])
        let canvas = reader.canvas
        canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(canvas.visibleRange?.end, ReaderTextPosition(section: 0, offset: Self.numbered.length), "the first section's last spread")
        assertFirstLines(canvas, "a turn back into the section before")
        reader.window.makeFirstResponder(canvas.textViews.last)
        canvas.show(ReaderTextPosition(section: 0, offset: Self.numbered.length), selecting: nil)
        assertFirstLines(canvas, "a place at the section's end")
        XCTAssertTrue(reader.window.firstResponder === canvas.textViews.last, "no focus moves for a place on no line")
        // A section that is not built yet is the session's to show (`NativeSessionPageEntryTests`).
        canvas.show(ReaderTextPosition(section: 1, offset: Self.numbered.length - 1), selecting: nil)
        XCTAssertEqual(canvas.turnPage(forward: true), .pending(section: 2))
        XCTAssertEqual(reader.recorder.needed.last?.section, 2)
        XCTAssertFalse(reader.window.isVisible)
    }

    /// Nothing but VoiceOver reads a column's insertion point: a selection is a range with
    /// characters in it, and Copy, the selection carried across a relayout and the selection's
    /// continuation onto other pages take only that.
    func testNothingElseTakesTheInsertionPointForASelection() async throws {
        let reader = reader(width: 1100)
        let canvas = reader.canvas
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let target = try place(inColumn: 1, line: 5, of: canvas)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        canvas.show(target, selecting: nil)
        let column = canvas.textViews[1]
        XCTAssertGreaterThan(column.selectedRange.location, 0)
        XCTAssertNil(canvas.currentSelection)
        XCTAssertFalse(canvas.hasSelection)
        XCTAssertNil(canvas.selectionContinuation)
        XCTAssertNil(canvas.selectionText(for: column))
        XCTAssertEqual(column.accessibilitySelectedText(), "")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.epublib.tests.page-entry.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(column.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), "", "Copy takes nothing from an insertion point")
        try await Task.sleep(for: .milliseconds(300)) // Past the selection report's settling time.
        XCTAssertTrue(reader.recorder.selections.allSatisfy { $0 == nil }, "no selection was reported")

        canvas.reloadContent(keeping: nil)
        XCTAssertNil(canvas.currentSelection, "no selection is carried across a relayout")
        assertFirstLines(canvas, "the text built again")

        // A passage asked for is selected whole, in place of the place's line.
        let passage = ReaderTextRange(section: 0, target.offset..<(target.offset + 12))
        canvas.show(target, selecting: passage)
        XCTAssertEqual(canvas.currentSelection?.range, passage)
        XCTAssertEqual(column.selectedRange, NSRange(location: target.offset - column.placement.offset, length: 12))
        XCTAssertEqual(canvas.textViews[0].selectedRange, NSRange(location: 0, length: 0))
        XCTAssertFalse(reader.window.isVisible)
    }

    /// Continuous scroll rests a place at the top of the screen and keeps the insertion point on
    /// the first line there (`placeScrollInsertionPoint`). Nothing of it is kept for the pages a
    /// change of flow then shows.
    func testContinuousScrollAndAChangeOfFlowKeepTheirOwnEntry() throws {
        let reader = reader(width: 600)
        let canvas = reader.canvas
        XCTAssertEqual(canvas.textViews.count, 1)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let target = try place(inColumn: 0, line: 6, of: canvas)
        var configuration = canvas.configuration
        configuration.flow = .scrolled
        canvas.configuration = configuration
        reader.window.contentView?.layoutSubtreeIfNeeded()
        canvas.show(target, selecting: nil)
        let scroll = try XCTUnwrap(canvas.scrollTextView)
        let line = try XCTUnwrap(scroll.line(containing: target.offset))
        XCTAssertEqual(scroll.selectedRange, NSRange(location: line.range.location, length: 0),
                       "the place's line is the first on screen, where the insertion point is")
        configuration.flow = .paginated
        canvas.configuration = configuration
        reader.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(canvas.entryLine(holding: target))
        assertFirstLines(canvas, "pages after continuous scroll")
        XCTAssertFalse(reader.window.isVisible)
    }

    /// A place shown before the canvas has a size waits for the spread that shows it. A change of
    /// flow before then, a relayout of its own, leaves the first line.
    func testAPlaceShownBeforeTheFirstLayoutIsEnteredWhenItsSpreadIsInstalled() throws {
        let offset = (Self.numbered.string as NSString).range(of: "word0300").location + 3
        let target = ReaderTextPosition(section: 0, offset: offset)
        let waiting = reader(width: 1100, shown: false)
        waiting.canvas.show(target, selecting: nil)
        XCTAssertTrue(waiting.canvas.textViews.isEmpty)
        waiting.window.contentView = waiting.canvas
        waiting.window.contentView?.layoutSubtreeIfNeeded()
        let shown = try XCTUnwrap(waiting.canvas.entryLine(holding: target))
        XCTAssertGreaterThan(shown.start, 0)
        XCTAssertEqual(shown.column.selectedRange, NSRange(location: shown.start, length: 0))

        let changed = reader(width: 1100, shown: false)
        changed.canvas.show(target, selecting: nil)
        var configuration = changed.canvas.configuration
        configuration.flow = .scrolled
        changed.canvas.configuration = configuration
        configuration.flow = .paginated
        changed.canvas.configuration = configuration
        changed.window.contentView = changed.canvas
        changed.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(changed.canvas.entryLine(holding: target))
        assertFirstLines(changed.canvas, "pages after a change of flow")
        XCTAssertFalse(waiting.window.isVisible)
        XCTAssertFalse(changed.window.isVisible)
    }
}

/// The session decides which of its shows is a place (#383): every navigation is, and a page
/// turn into a section that had to be built first is not.
@MainActor final class NativeSessionPageEntryTests: XCTestCase {
    func testEveryNavigationIsEnteredAtItsLineAndAPageTurnAtTheFirst() async throws {
        let reader = try SessionCoverageReader(SessionCoverageBook.chapters())
        defer { reader.close() }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)

        /// The place last shown is entered at the start of its line, in the column that holds it.
        func assertEntered(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let place = try XCTUnwrap(canvas.anchor, label, file: file, line: line)
            let shown = try XCTUnwrap(canvas.entryLine(holding: place), "\(label): not on screen", file: file, line: line)
            XCTAssertGreaterThan(shown.index, 0, "\(label): on a page's first line, which shows nothing", file: file, line: line)
            for (index, column) in canvas.textViews.enumerated() {
                let start = column === shown.column ? shown.start : 0
                XCTAssertEqual(column.selectedRange.location, start, "\(label), column \(index)", file: file, line: line)
            }
        }
        func assertFirstLines(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            for (index, column) in canvas.textViews.enumerated() {
                XCTAssertEqual(column.selectedRange, NSRange(location: 0, length: 0), "\(label), column \(index)", file: file, line: line)
            }
        }
        func leave() async throws {
            try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
            try await reader.wait("chapter one") { reader.section == 0 }
            assertFirstLines("chapter one's start")
        }

        let mid = try reader.anchor("mid", section: 2)
        try await reader.session.send(.navigate(href: "OPS/two.xhtml#mid"))
        try await reader.wait("a link's target") { reader.isVisible(mid) }
        try assertEntered("a link's target")
        try await reader.session.send(.nextPage)
        try await reader.wait("the next page") { !reader.isVisible(mid) }
        assertFirstLines("the next page")
        try await reader.session.send(.previousPage)
        try await reader.wait("the target's page again") { reader.isVisible(mid) }
        assertFirstLines("a turn back to the target's page")

        try await leave()
        try await reader.session.send(.search(text: "marked midpoint"))
        try await reader.wait("the search's first result") { reader.isVisible(mid) && reader.session.searchResults?.currentIndex == 0 }
        try assertEntered("a search's first result")
        try await leave()
        try await reader.session.send(.nextSearchResult)
        try await reader.wait("the next search result") { reader.isVisible(mid) }
        try assertEntered("a step to a search result")
        try await leave()
        let result = try XCTUnwrap(reader.session.searchResults?.results.first)
        try await reader.session.send(.showSearchResult(result))
        try await reader.wait("a search result chosen") { reader.isVisible(mid) }
        try assertEntered("a search result chosen from the list")

        try await leave()
        try await reader.session.send(.locate(text: "midpoint paragraph sits", highlight: false))
        try await reader.wait("a located passage") { reader.isVisible(mid) }
        try assertEntered("a located passage")
        try await leave()
        let count = reader.events.count
        try await reader.session.send(.locate(text: "midpoint paragraph sits", highlight: true))
        try await reader.wait("a highlighted passage") { reader.selections(since: count).last??.text == "midpoint paragraph sits" }
        let selected = try XCTUnwrap(canvas.textViews.first { $0.selectedRange.length > 0 })
        XCTAssertEqual(selected.plainText(in: selected.selectedRange), "midpoint paragraph sits", "the passage is selected, not the line's start")
        let bookmark = try XCTUnwrap(reader.selections(since: count).last??.location)

        try await leave()
        try await reader.session.send(.restore(bookmark))
        try await reader.wait("a bookmark") { reader.isVisible(mid) }
        try assertEntered("a bookmark")

        // A page turn that had to wait for its section shows the section's end or start.
        try await leave()
        reader.session.canvas(canvas, needsSection: 2, forward: false)
        try await reader.wait("chapter two's end") { reader.session.visibleRange?.end.section == 2 && reader.section == 2 }
        XCTAssertEqual(canvas.anchor?.offset, reader.session.book.section(2)?.string.length)
        assertFirstLines("a turn back into a section built for it")
        reader.session.canvas(canvas, needsSection: 3, forward: true)
        try await reader.wait("chapter three's start") { reader.section == 3 }
        assertFirstLines("a turn on into a section built for it")
    }
}

extension ReaderCanvasView {
    /// The column that shows `position`, and which of its lines (as VoiceOver is given them)
    /// holds it and where that line begins. nil when no column shows it.
    func entryLine(holding position: ReaderTextPosition) -> (column: ReaderTextView, index: Int, start: Int)? {
        for column in textViews where column.placement.section == position.section {
            let local = position.offset - column.placement.offset
            guard local >= 0, local < column.placement.visibleLength else { continue }
            let lines = column.pageAccessibilityLines
            guard let index = lines.firstIndex(where: { NSLocationInRange(local, $0.range) }) else { return nil }
            return (column, index, lines[index].range.location)
        }
        return nil
    }
}
#endif
