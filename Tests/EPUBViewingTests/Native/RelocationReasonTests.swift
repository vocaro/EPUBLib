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

/// #600: why each `.relocated` was sent (`EPUBReaderStatus.relocationReason`), set in the state
/// before the event, so that a host that saves the place as the person reads can tell a move
/// from a relayout without comparing locations. The reasons are the owner's (2026-10-23): a turn
/// of a page or a screen, the person's own scrolling, a place gone to, a place restored, and the
/// same place laid out again; and the place a book opens at, which the issue's host must not
/// save either.
@MainActor final class RelocationReasonTests: XCTestCase {
    private var readers: [SessionCoverageReader] = []
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    /// The state's reason as each `.relocated` was sent, in order.
    @MainActor private final class ReasonLog { var reasons: [EPUBRelocationReason?] = [] }

    /// Three chapters: a link in the first to a place many pages into the second, and two
    /// matches of "findword" far apart in the third.
    private static func book() throws -> Data {
        try SessionCoverageBook.epub([
            .init("one", "<h1>First Chapter</h1><p>Opening words, and <a href=\"two.xhtml#mid\">a link to the midpoint</a>.</p>"
                + SessionCoverageBook.filler(40), title: "First Chapter"),
            .init("two", "<h1>Second Chapter</h1>\(SessionCoverageBook.filler(70))"
                + "<p id=\"mid\">A marked midpoint paragraph sits here.</p>\(SessionCoverageBook.filler(70))", title: "Second Chapter"),
            .init("three", "<h1>Third Chapter</h1><p>Closing words hold a findword.</p>\(SessionCoverageBook.filler(80))"
                + "<p>And a second findword far below.</p>\(SessionCoverageBook.filler(20))", title: "Third Chapter"),
        ])
    }

    /// A mounted reader whose log has the reason the state gave as each relocation was sent.
    /// `onReady` runs inside the session's `.ready` callback, as a host's own code does.
    private func open(_ data: Data, onReady: (@MainActor (NativeSession) -> Void)? = nil) throws -> (SessionCoverageReader, ReasonLog) {
        let reader = try SessionCoverageReader(data, mounted: false)
        readers.append(reader)
        let log = ReasonLog(), state = reader.state, session = reader.session
        reader.onEvent = { event in
            if case .relocated = event { log.reasons.append(state.status.relocationReason) }
            if event == .ready { onReady?(session) }
        }
        reader.mount()
        return (reader, log)
    }

    /// Makes a move with `act`, waits for its relocation, for `done` and for the reader to settle,
    /// and a little longer for what may follow, as continuous scroll's report 150 ms after its
    /// view moves. The first relocation since gives `expected`, and each after it `.relayout`.
    /// `relocates` false allows none, for a change that may show the same range again.
    private func step(_ label: String, _ reader: SessionCoverageReader, _ log: ReasonLog, gives expected: EPUBRelocationReason,
                      relocates: Bool = true, file: StaticString = #filePath, line: UInt = #line,
                      _ act: () async throws -> Void, until done: () -> Bool = { true }) async throws {
        let start = log.reasons.count
        try await act()
        try await reader.wait(label, file: file, line: line) { (!relocates || log.reasons.count > start) && done() }
        try await reader.settle(file: file, line: line)
        try await Task.sleep(for: .milliseconds(400))
        try await reader.settle(file: file, line: line)
        let reasons = Array(log.reasons.dropFirst(start))
        XCTAssertEqual(reader.locations.count, log.reasons.count, "\(label): a reason for each relocation", file: file, line: line)
        if !reasons.isEmpty { XCTAssertEqual(reasons.first, expected, "\(label): \(reasons)", file: file, line: line) }
        XCTAssertTrue(reasons.dropFirst().allSatisfy { $0 == .relayout }, "\(label): \(reasons)", file: file, line: line)
        XCTAssertEqual(reader.state.status.relocationReason, log.reasons.last ?? nil, "\(label): the state keeps the latest",
                       file: file, line: line)
    }

    /// Every move a person or a host makes, and every relayout, in pages and in continuous scroll.
    private func checkReasons(in flow: EPUBReadingFlow) async throws {
        let (reader, log) = try open(Self.book())
        let session = reader.session
        let spine = reader.publication.spine
        try await reader.settle()
        // A host's first style comes after `.ready`, so a book opens in pages.
        XCTAssertEqual(log.reasons.first, .opening, "the first relocation: \(log.reasons)")
        XCTAssertTrue(log.reasons.dropFirst().allSatisfy { $0 == .relayout }, "after opening: \(log.reasons)")
        let other: EPUBReadingFlow = flow == .paginated ? .scrolled : .paginated
        if flow == .scrolled {
            try await step("continuous scroll", reader, log, gives: .relayout) {
                try await session.send(.style(.init(flow: .scrolled)))
            } until: { session.canvas?.scrollTextView != nil }
        }

        // Turns: the host's, and the reader's own page keys.
        var shown = session.visibleRange
        try await step("next page", reader, log, gives: .turn) {
            try await session.send(.nextPage)
        } until: { session.visibleRange != shown }
        shown = session.visibleRange
        try await step("a page key", reader, log, gives: .turn) {
            _ = try XCTUnwrap(session.canvas).turnPageFromInput(forward: true)
        } until: { session.visibleRange != shown }
        shown = session.visibleRange
        try await step("previous page", reader, log, gives: .turn) {
            try await session.send(.previousPage)
        } until: { session.visibleRange != shown }

        // Places gone to.
        try await step("navigate", reader, log, gives: .navigation) {
            try await session.send(.navigate(href: spine[1].resource.href))
        } until: { reader.section == 1 }
        let mid = try reader.anchor("mid", section: 1)
        try await step("a link", reader, log, gives: .navigation) {
            await session.activateLink(.internal(href: spine[1].resource.href + "#mid"), from: .zero)?.value
        } until: { reader.isVisible(mid) }
        let saved = try XCTUnwrap(reader.locations.last)
        try await step("the book's end, from a key", reader, log, gives: .navigation) {
            try XCTUnwrap(session.canvas).performPageActionFromInput(.bookEnd)
        } until: { reader.state.status.canGoNext == false }
        try await step("a progression", reader, log, gives: .navigation) {
            try await session.send(.goToProgression(0.5))
        }
        try await step("the book's start", reader, log, gives: .navigation) {
            try await session.send(.goToStart)
        } until: { reader.section == 0 }
        try await step("a search", reader, log, gives: .navigation) {
            try await session.send(.search(text: "findword"))
        } until: { reader.section == 2 }
        shown = session.visibleRange
        try await step("the next search result", reader, log, gives: .navigation) {
            try await session.send(.nextSearchResult)
        } until: { session.visibleRange != shown }
        try await session.send(.clearSearch)
        try await step("a passage located", reader, log, gives: .navigation) {
            try await session.send(.locate(text: "Opening words", highlight: false))
        } until: { reader.section == 0 }

        // A place restored.
        try await step("restore", reader, log, gives: .restore) {
            try await session.send(.restore(saved))
        } until: { reader.isVisible(mid) }

        // The same place, laid out again.
        try await step("a text size", reader, log, gives: .relayout) {
            try await session.send(.style(.init(fontSize: 24, flow: flow)))
        } until: { session.book.isComplete }
        // Narrower than the reader's widest column on any device, so the lines break anew.
        try await step("a window size", reader, log, gives: .relayout) {
            try XCTUnwrap(reader.window).resize(to: CGSize(width: 480, height: 640))
        }
        try await step("an appearance", reader, log, gives: .relayout, relocates: false) {
            try await session.send(.style(.init(fontSize: 24, appearance: .sepia, flow: flow)))
        } until: { session.book.isComplete }

        if flow == .scrolled {
            // The person's own scrolling.
            let canvas = try XCTUnwrap(session.canvas)
            let view = try XCTUnwrap(canvas.scrollTextView)
            let start = try XCTUnwrap(session.visibleRange)
            let top = canvas.scrollVisibleContainerRect.minY + 2 * canvas.scrollVisibleContainerRect.height
            try await step("the person's scrolling", reader, log, gives: .scroll) {
                #if os(macOS)
                let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                #else
                view.contentOffset = CGPoint(x: 0, y: top)
                #endif
            } until: { session.visibleRange != start }
        }
        try await step("the other flow", reader, log, gives: .relayout) {
            try await session.send(.style(.init(fontSize: 24, appearance: .sepia, flow: other)))
        } until: { (session.canvas?.scrollTextView != nil) == (other == .scrolled) }
    }

    func testEachMoveAndRelayoutGivesItsReasonInPages() async throws {
        try await checkReasons(in: .paginated)
    }

    func testEachMoveAndRelayoutGivesItsReasonInContinuousScroll() async throws {
        try await checkReasons(in: .scrolled)
    }

    /// The issue's host restores the saved place as soon as the reader is ready. What it is then
    /// told is the opening, where the opening was shown before the restore came, then the
    /// restore, and after it nothing but relayouts: never a move, in either flow.
    func testARestoreAtReadyIsReportedAsARestoreAfterTheOpening() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            // A place to restore, saved by a first reader.
            let (first, _) = try open(Self.book())
            try await first.settle()
            try await first.session.send(.style(.init(flow: flow)))
            try await first.session.send(.navigate(href: first.publication.spine[1].resource.href + "#mid"))
            let mid = try first.anchor("mid", section: 1)
            try await first.wait("\(flow): the place to save") { first.isVisible(mid) }
            try await first.settle()
            let saved = try XCTUnwrap(first.locations.last)
            first.close()

            let (reader, log) = try open(Self.book()) { session in
                Task { @MainActor in
                    try? await session.send(.style(.init(flow: flow)))
                    try? await session.send(.restore(saved))
                }
            }
            try await reader.wait("\(flow): the restored place") { reader.isVisible(mid) && log.reasons.contains(.restore) }
            try await reader.settle()
            try await Task.sleep(for: .milliseconds(400))
            try await reader.settle()
            let moves = log.reasons.filter { $0 != .relayout }
            XCTAssertTrue(moves == [.restore] || moves == [.opening, .restore], "\(flow): \(log.reasons)")
            XCTAssertEqual(reader.locations.count, log.reasons.count, "\(flow): a reason for each relocation")
            XCTAssertTrue(reader.isVisible(mid), "\(flow)")
            reader.close()
        }
    }

    // MARK: The canvas

    private func host(flow: EPUBReadingFlow, size: CGSize = CGSize(width: 600, height: 700)) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = flow
        let sections = (0..<3).map { CanvasText.section($0, paragraphs: 30) }
        let host = CanvasHost(FakeCanvasSource(sections), size: size, configuration: configuration)
        if flow == .scrolled { host.source.book = CanvasText.book(sections) }
        hosts.append(host)
        return host
    }

    /// A place shown before the canvas has a size, as in a window not yet laid out or hidden, is
    /// reported with its reason once it is laid out, and what is laid out after it as a relayout.
    func testAPlaceShownBeforeTheCanvasHasASizeGivesItsReasonWhenItIsShown() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let host = host(flow: flow, size: .zero)
            let canvas = host.canvas
            canvas.show(ReaderTextPosition(section: 1, offset: 400), selecting: nil, reason: .restore)
            XCTAssertTrue(host.recorder.shown.isEmpty, "\(flow): nothing is shown without a size")
            host.resize(to: CGSize(width: 600, height: 700))
            XCTAssertEqual(host.recorder.reasons.first, .restore, "\(flow): \(host.recorder.reasons)")
            let shown = host.recorder.reasons.count
            host.resize(to: CGSize(width: 480, height: 640))
            XCTAssertGreaterThan(host.recorder.reasons.count, shown, "\(flow): a new size shows another range")
            XCTAssertTrue(host.recorder.reasons.dropFirst(shown).allSatisfy { $0 == .relayout }, "\(flow): \(host.recorder.reasons)")
        }
    }

    /// A turn reports a turn. One that turns nothing, at the book's start, leaves no reason
    /// behind for the relayout after it.
    func testATurnGivesTurnAndOneThatTurnsNothingLeavesNoReason() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let host = host(flow: flow)
            let canvas = host.canvas
            canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil, reason: .opening)
            host.layOut()
            XCTAssertEqual(host.recorder.reasons.last, .opening, "\(flow)")
            XCTAssertEqual(canvas.turnPage(forward: false), .atBoundary, "\(flow)")
            var count = host.recorder.reasons.count
            canvas.reloadContent(keeping: nil)
            XCTAssertEqual(Array(host.recorder.reasons.dropFirst(count)), [.relayout], "\(flow): a reload after a turn that turned nothing")
            count = host.recorder.reasons.count
            XCTAssertEqual(canvas.turnPage(forward: true), .turned, "\(flow)")
            XCTAssertEqual(Array(host.recorder.reasons.dropFirst(count)), [.turn], "\(flow)")
            count = host.recorder.reasons.count
            canvas.reloadContent(keeping: nil)
            XCTAssertEqual(Array(host.recorder.reasons.dropFirst(count)), [.relayout], "\(flow): a reload after a turn")
        }
    }

    /// A turn into a section not built asks for it for a turn, and a key's go to the book's end
    /// for a place gone to; each is shown, once it is built, with that reason.
    func testAMoveThatWaitsForItsSectionGivesItsReasonWhenShown() async throws {
        let host = host(flow: .paginated)
        let canvas = host.canvas
        let last = host.source.sections[2]
        host.source.sections[2] = nil
        canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil, reason: .navigation)
        host.layOut()
        canvas.performPageActionFromInput(.bookEnd)
        XCTAssertEqual(host.recorder.needed.last?.section, 2)
        XCTAssertEqual(host.recorder.neededReasons.last, .navigation)
        while canvas.turnPage(forward: true) == .turned {}
        XCTAssertEqual(host.recorder.needed.last?.section, 2)
        XCTAssertEqual(host.recorder.neededReasons.last, .turn)
        host.source.sections[2] = last
        let count = host.recorder.reasons.count
        canvas.showTurned(ReaderTextPosition(section: 2, offset: 0), forward: true, reason: .turn)
        XCTAssertEqual(Array(host.recorder.reasons.dropFirst(count)), [.turn])
        canvas.showTurned(ReaderTextPosition(section: 2, offset: try XCTUnwrap(last).length), forward: true, reason: .navigation)
        XCTAssertEqual(host.recorder.reasons.last, .navigation)
    }

    /// The person's scrolling is reported as a scroll, and so is a relayout that comes before
    /// that scroll is reported, which shows it. A scroll that shows no other range leaves no
    /// reason behind for a relayout after it.
    func testTheScrollingARelayoutShowsIsTheReason() async throws {
        let host = host(flow: .scrolled)
        let canvas = host.canvas
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil, reason: .opening)
        host.layOut()
        let view = try XCTUnwrap(canvas.scrollTextView)
        func scroll(by distance: CGFloat) throws {
            #if os(macOS)
            let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + distance))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            #else
            view.contentOffset = CGPoint(x: 0, y: view.contentOffset.y + distance)
            #endif
        }
        var count = host.recorder.reasons.count
        try scroll(by: 1_500)
        try await host.settle()
        XCTAssertEqual(Array(host.recorder.reasons.dropFirst(count)), [.scroll], "a scroll, reported 150 ms on")

        count = host.recorder.reasons.count
        try scroll(by: 1_500)
        // Before that report: a relayout shows the scrolled range.
        canvas.reloadContent(keeping: nil)
        XCTAssertEqual(Array(host.recorder.reasons.dropFirst(count)), [.scroll], "a relayout that shows a scroll not reported")
        try await host.settle()
        XCTAssertTrue(host.recorder.reasons.dropFirst(count + 1).allSatisfy { $0 == .relayout }, "\(host.recorder.reasons)")

        // A scroll of two points, which seldom shows another line.
        count = host.recorder.reasons.count
        try scroll(by: 2)
        try await host.settle()
        canvas.reloadContent(keeping: nil)
        XCTAssertEqual(Array(host.recorder.reasons.dropFirst(count)).last, .relayout, "a relayout after a scroll that showed nothing new")
    }
}
