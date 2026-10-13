import EPUBCore
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#endif

/// The page actions the Mac's text areas offer VoiceOver, read through AppKit's own
/// `accessibilityCustomActions()`: what its Actions menu lists for the item under its cursor.
@MainActor final class PageActionAccessibilityTests: XCTestCase {
    func testAPageActionIsNamedForItsFlow() {
        XCTAssertEqual([EPUBPageAction.next, .previous].map { $0.label(in: .paginated) }, ["Next Page", "Previous Page"])
        XCTAssertEqual([EPUBPageAction.next, .previous].map { $0.label(in: .scrolled) }, ["Scroll Forward", "Scroll Backward"])
    }

    #if os(macOS)
    private var hosts: [CanvasHost] = []
    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private func host(size: CGSize = CGSize(width: 600, height: 700), flow: EPUBReadingFlow = .paginated,
                      controls: EPUBPageControls = .init()) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = flow
        configuration.pageControls = controls
        let host = CanvasHost(FakeCanvasSource([CanvasText.section(0, paragraphs: 30)]), size: size, configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return host
    }

    private func names(_ view: ReaderTextView) -> [String] { (view.accessibilityCustomActions() ?? []).map(\.name) }

    /// Performs the action a text area offers under `name`, as VoiceOver's Actions menu does.
    private func perform(_ name: String, on view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let action = try XCTUnwrap(view.accessibilityCustomActions()?.first { $0.name == name }, "no action \(name)", file: file, line: line)
        return try XCTUnwrap(action.handler, file: file, line: line)()
    }

    private func pageDown(in host: CanvasHost) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0,
                         windowNumber: host.window.windowNumber, context: nil, characters: "\u{F72D}",
                         charactersIgnoringModifiers: "\u{F72D}", isARepeat: false, keyCode: 121)!
    }

    func testAPageColumnOffersNextPageAndPreviousPageAndTurnsThePage() throws {
        let host = host()
        let canvas = host.canvas, view = try XCTUnwrap(canvas.textViews.first)
        XCTAssertTrue(view.isPageColumn)
        XCTAssertEqual(names(view), ["Next Page", "Previous Page"])
        let first = try XCTUnwrap(canvas.visibleRange)
        XCTAssertFalse(try perform("Previous Page", on: view), "the book's first page has none before it")
        XCTAssertEqual(canvas.visibleRange, first)
        XCTAssertTrue(try perform("Next Page", on: view))
        let second = try XCTUnwrap(canvas.visibleRange)
        XCTAssertEqual(second.start, first.end, "the next page starts where the first one ended")
        XCTAssertEqual(view.placement.offset, first.end.offset, "the same text area holds the next page")
        XCTAssertEqual(names(view), ["Next Page", "Previous Page"])
        XCTAssertTrue(try perform("Previous Page", on: view))
        XCTAssertEqual(canvas.visibleRange, first)
    }

    func testEachColumnOfASpreadOffersThePairAndTurnsTheSpread() throws {
        let host = host(size: CGSize(width: 1100, height: 420))
        let canvas = host.canvas
        XCTAssertEqual(canvas.textViews.count, 2)
        for view in canvas.textViews { XCTAssertEqual(names(view), ["Next Page", "Previous Page"]) }
        let first = try XCTUnwrap(canvas.visibleRange)
        XCTAssertTrue(try perform("Next Page", on: canvas.textViews[1]))
        XCTAssertEqual(canvas.visibleRange?.start, first.end, "from the right column the spread turns, not one page")
        XCTAssertEqual(canvas.textViews[0].placement.offset, first.end.offset)
        XCTAssertTrue(try perform("Previous Page", on: canvas.textViews[0]))
        XCTAssertEqual(canvas.visibleRange, first)
    }

    func testATurnFromTheSecondColumnBringsKeyboardFocusToTheFirst() throws {
        let host = host(size: CGSize(width: 1100, height: 420))
        let canvas = host.canvas, window = host.window
        let first = canvas.textViews[0], second = canvas.textViews[1]
        // The book's first spread has none before it: nothing turns, and focus stays.
        XCTAssertTrue(window.makeFirstResponder(second))
        XCTAssertFalse(try perform("Previous Page", on: second))
        XCTAssertTrue(window.firstResponder === second)
        // VoiceOver follows keyboard focus, and would pass over the new first column otherwise.
        XCTAssertTrue(try perform("Next Page", on: second))
        XCTAssertTrue(canvas.textViews[0] === first, "a spread's columns are the same text areas on every page")
        XCTAssertTrue(window.firstResponder === first)
        XCTAssertTrue(window.makeFirstResponder(second))
        second.keyDown(with: pageDown(in: host))
        XCTAssertTrue(window.firstResponder === first, "a page key turns as the action does")
        // From the first column focus is where it should be already.
        XCTAssertTrue(try perform("Previous Page", on: first))
        XCTAssertTrue(window.firstResponder === first)
        // Focus outside the columns is the host's or the canvas's own, and is left alone.
        XCTAssertTrue(window.makeFirstResponder(canvas))
        XCTAssertTrue(try perform("Next Page", on: second))
        XCTAssertTrue(window.firstResponder === canvas)
    }

    func testContinuousScrollOffersScrollForwardAndScrollBackwardAndScrollsAStep() throws {
        let host = host(flow: .scrolled)
        let canvas = host.canvas, view = try XCTUnwrap(canvas.scrollTextView)
        XCTAssertFalse(view.isPageColumn)
        XCTAssertEqual(names(view), ["Scroll Forward", "Scroll Backward"])
        let first = try XCTUnwrap(canvas.visibleRange)
        XCTAssertFalse(try perform("Scroll Backward", on: view), "the book starts here")
        XCTAssertEqual(canvas.visibleRange, first)
        XCTAssertTrue(try perform("Scroll Forward", on: view))
        let second = try XCTUnwrap(canvas.visibleRange)
        XCTAssertGreaterThan(second.start, first.start)
        XCTAssertLessThan(second.start, first.end, "a step keeps the last line that was on screen")
        XCTAssertTrue(try perform("Scroll Backward", on: view))
        XCTAssertEqual(canvas.visibleRange?.start, first.start)
    }

    func testAnActionGoesAsFarAsAPageKeyDoes() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let byKey = host(flow: flow), byAction = host(flow: flow)
            XCTAssertEqual(byKey.canvas.visibleRange, byAction.canvas.visibleRange)
            for step in 1...3 {
                try XCTUnwrap(byKey.canvas.textViews.first).keyDown(with: pageDown(in: byKey))
                XCTAssertTrue(try perform(EPUBPageAction.next.label(in: flow), on: try XCTUnwrap(byAction.canvas.textViews.first)))
                XCTAssertEqual(byAction.canvas.visibleRange, byKey.canvas.visibleRange, "\(flow), step \(step)")
            }
            XCTAssertGreaterThan(try XCTUnwrap(byAction.canvas.visibleRange?.start), ReaderTextPosition(section: 0, offset: 0))
        }
    }

    func testTheNamesFollowAChangeOfFlowWithTheReaderOpen() throws {
        let host = host()
        let canvas = host.canvas
        XCTAssertEqual(names(try XCTUnwrap(canvas.textViews.first)), ["Next Page", "Previous Page"])
        canvas.configuration.flow = .scrolled
        host.layOut()
        let scroll = try XCTUnwrap(canvas.scrollTextView)
        XCTAssertEqual(canvas.textViews.count, 1)
        XCTAssertEqual(names(scroll), ["Scroll Forward", "Scroll Backward"])
        let first = try XCTUnwrap(canvas.visibleRange)
        XCTAssertTrue(try perform("Scroll Forward", on: scroll))
        XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange?.start), first.start)
        canvas.configuration.flow = .paginated
        host.layOut()
        XCTAssertNil(canvas.scrollTextView)
        let column = try XCTUnwrap(canvas.textViews.first)
        XCTAssertEqual(names(column), ["Next Page", "Previous Page"])
        let page = try XCTUnwrap(canvas.visibleRange)
        XCTAssertTrue(try perform("Next Page", on: column))
        XCTAssertEqual(canvas.visibleRange?.start, page.end)
    }

    func testTheActionsTurnThePageWhereTheHostTookTheKeysAway() throws {
        let host = host(controls: .hostOnly)
        let canvas = host.canvas, view = try XCTUnwrap(canvas.textViews.first)
        let first = try XCTUnwrap(canvas.visibleRange)
        view.keyDown(with: pageDown(in: host))
        XCTAssertEqual(canvas.visibleRange, first, "no key turns the page under host-only controls")
        XCTAssertEqual(names(view), ["Next Page", "Previous Page"])
        XCTAssertTrue(try perform("Next Page", on: view))
        XCTAssertEqual(canvas.visibleRange?.start, first.end)
    }

    func testSelectedTextDoesNotHoldAnActionBackAsItDoesAPageKey() throws {
        let host = host()
        let canvas = host.canvas, view = try XCTUnwrap(canvas.textViews.first)
        let first = try XCTUnwrap(canvas.visibleRange)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(canvas.hasSelection)
        view.keyDown(with: pageDown(in: host))
        XCTAssertEqual(canvas.visibleRange, first, "a key could be meant for the selection")
        XCTAssertTrue(try perform("Next Page", on: view), "a turn asked for by name is not")
        XCTAssertEqual(canvas.visibleRange?.start, first.end)
    }

    func testANotesTextOffersNoPageAction() {
        let note = ReaderNoteViewController(text: CanvasText.body("A note."), dark: false, width: 300)
        XCTAssertEqual(names(note.textView), [])
    }
    #endif
}
