import CoreGraphics
import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Continuous scroll in a real window (doc/native-viewer.md "Layout", "Continuous scroll"):
/// where a shown position rests, what a page turn scrolls by, and what resizes keep.
@MainActor final class ViewCoverageScrollTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private func scrolledHost(_ sections: [NSAttributedString], book: Bool = true, linear: [Bool]? = nil,
                              show position: ReaderTextPosition = ReaderTextPosition(section: 0, offset: 0),
                              size: CGSize = CGSize(width: 600, height: 700), division: CGRect? = nil) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        configuration.division = division
        let source = FakeCanvasSource(sections, linear: linear)
        if book { source.book = CanvasText.book(sections, omitting: Set((linear ?? []).indices.filter { linear?[$0] == false })) }
        let host = CanvasHost(source, size: size, configuration: configuration)
        hosts.append(host)
        host.canvas.show(position, selecting: nil)
        host.layOut()
        return host
    }

    /// Paragraphs of prose about `length` characters long, each beginning with its own label.
    private func prose(_ section: Int, length: Int) -> NSAttributedString {
        let text = NSMutableAttributedString()
        var paragraph = 0
        while text.length < length {
            let words = min(120, max(3, (length - text.length) / 6))
            text.append(CanvasText.body("S\(section)P\(paragraph) " + CanvasText.sentence(words, seed: section + paragraph) + "\n"))
            paragraph += 1
        }
        return text
    }

    /// The location in the scroll view's text of `position`.
    private func location(of position: ReaderTextPosition, in canvas: ReaderCanvasView) -> Int {
        canvas.scrollBook?.location(of: position) ?? position.offset
    }

    /// The line holding `position` is the first in the visible area, or is on screen where the
    /// text's end stops the view scrolling that far.
    private func assertRestsAtTheTop(_ position: ReaderTextPosition, in canvas: ReaderCanvasView, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(canvas.scrollTextView, file: file, line: line)
        let target = try XCTUnwrap(view.line(containing: location(of: position, in: canvas)), label, file: file, line: line)
        let visible = canvas.scrollVisibleContainerRect
        if canvas.isScrolledToEnd, abs(target.frame.minY - visible.minY) > 1 {
            XCTAssertGreaterThanOrEqual(target.frame.minY, visible.minY - 1, "\(label): on screen at the text's end", file: file, line: line)
            XCTAssertLessThanOrEqual(target.frame.maxY, visible.maxY + 1, "\(label): on screen at the text's end", file: file, line: line)
        } else {
            XCTAssertEqual(target.frame.minY, visible.minY, accuracy: 1, "\(label): the line's top is the visible top", file: file, line: line)
            let start = try XCTUnwrap(canvas.visibleRange?.start, file: file, line: line)
            XCTAssertEqual(location(of: start, in: canvas), target.range.location, "\(label): reported as the visible start", file: file, line: line)
        }
        let range = try XCTUnwrap(canvas.visibleRange, file: file, line: line)
        XCTAssertTrue(range.start <= position && position <= range.end, "\(label): \(position) in \(range)", file: file, line: line)
    }

    // MARK: Shown positions

    func testAShownPositionsLineRestsAtTheTopInABookOfVeryUnevenSections() throws {
        // Far from what is laid out TextKit 2 estimates, and sections of a few words between
        // sections of a hundred thousand make its estimates poor (#13).
        let lengths = [300, 90_000, 40, 12, 140_000, 2_500, 60_000, 25, 700, 110_000, 9_000, 30]
        let sections = lengths.enumerated().map { prose($0.offset, length: $0.element) }
        let host = scrolledHost(sections)
        let canvas = host.canvas
        XCTAssertNotNil(canvas.scrollBook)
        let jumps: [(Int, Int)] = [(9, 80_000), (1, 45_000), (11, 0), (4, 139_000), (2, 0), (9, 0), (0, 150), (6, 59_990), (3, 5),
                                   (10, 4_000), (4, 70_123), (7, 0), (1, 89_950), (11, 10), (5, 1_200), (0, 0)]
        for (section, offset) in jumps {
            let position = ReaderTextPosition(section: section, offset: min(offset, sections[section].length - 1))
            canvas.show(position, selecting: nil)
            try assertRestsAtTheTop(position, in: canvas, "jump to \(position)")
            XCTAssertEqual(host.recorder.shown.last?.range, canvas.visibleRange)
            XCTAssertEqual(canvas.anchor, position)
        }
    }

    func testAShownPositionsLineRestsAtTheTopAcrossFiguresNotYetLaidOut() throws {
        // Figures are a character each and hundreds of points tall: nothing an estimate allows for.
        let sections = [prose(0, length: 9_000), figures(1, count: 30, height: 400), prose(2, length: 6_000),
                        figures(3, count: 10, height: 150), prose(4, length: 20_000)]
        let host = scrolledHost(sections)
        let canvas = host.canvas
        // Past the figures, back over them, onto captions among them and onto a figure itself.
        let jumps: [(Int, Int)] = [(4, 10_000), (0, 3_000), (2, 3_000), (1, 200), (3, 50), (4, 19_000), (1, 0), (2, 0), (1, 435), (0, 8_990), (3, 0)]
        for (section, offset) in jumps {
            let position = ReaderTextPosition(section: section, offset: offset)
            canvas.show(position, selecting: nil)
            try assertRestsAtTheTop(position, in: canvas, "jump to \(position)")
            XCTAssertEqual(canvas.anchor, position)
        }
    }

    func testAShownPositionRestsAtTheTopOfTheSectionShownBeforeTheBookIsBuilt() throws {
        let sections = [prose(0, length: 20_000), prose(1, length: 30_000)]
        let host = scrolledHost(sections, book: false, show: ReaderTextPosition(section: 1, offset: 17_000))
        XCTAssertNil(host.canvas.scrollBook)
        try assertRestsAtTheTop(ReaderTextPosition(section: 1, offset: 17_000), in: host.canvas, "in the opening section")
        for position in [ReaderTextPosition(section: 0, offset: 19_500), ReaderTextPosition(section: 1, offset: 0),
                         ReaderTextPosition(section: 0, offset: 8_000), ReaderTextPosition(section: 1, offset: 29_999)] {
            host.canvas.show(position, selecting: nil)
            XCTAssertEqual(host.canvas.scrollTextView?.placement.section, position.section)
            try assertRestsAtTheTop(position, in: host.canvas, "\(position)")
        }
        // The whole book arrives: the same line stays at the top.
        let kept = ReaderTextPosition(section: 1, offset: 12_345)
        host.canvas.show(kept, selecting: nil)
        host.source.book = CanvasText.book(sections)
        host.canvas.reloadContent(keeping: nil)
        XCTAssertNotNil(host.canvas.scrollBook)
        try assertRestsAtTheTop(kept, in: host.canvas, "after the swap to the whole book")
    }

    func testTurningBackIntoASectionBeforeTheBookIsBuiltShowsItsEnd() throws {
        #if os(iOS)
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/165")
        #endif
        let sections = [prose(0, length: 12_000), prose(1, length: 12_000)]
        let host = scrolledHost(sections, book: false, show: ReaderTextPosition(section: 1, offset: 0))
        let canvas = host.canvas
        XCTAssertEqual(canvas.canTurnPage(forward: false), true)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        let range = try XCTUnwrap(canvas.visibleRange)
        XCTAssertEqual(range.end, ReaderTextPosition(section: 0, offset: sections[0].length), "the previous section's last lines")
        XCTAssertGreaterThan(range.start.offset, 8_000, "its end, not its start")
        XCTAssertTrue(canvas.isScrolledToEnd)
        XCTAssertEqual(canvas.scrollTextView?.placement.section, 0)
        XCTAssertEqual(host.recorder.shown.last?.range, range)
        // Forward again from the end crosses back to the next section's start.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
    }

    /// The same turn back into a section whose height nothing has measured yet: its figures stand
    /// far lower than TextKit 2 estimates before it lays them out.
    func testTurningBackIntoASectionOfFiguresBeforeTheBookIsBuiltShowsItsEnd() throws {
        let illustrated = ViewCoverage.joined([prose(0, length: 3_000), figures(0, count: 12, height: 400), prose(0, length: 3_000)])
        let host = scrolledHost([illustrated, prose(1, length: 6_000)], book: false, show: ReaderTextPosition(section: 1, offset: 0))
        let canvas = host.canvas
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(canvas.scrollTextView?.placement.section, 0)
        let range = try XCTUnwrap(canvas.visibleRange)
        XCTAssertEqual(range.end, ReaderTextPosition(section: 0, offset: illustrated.length),
                       "the previous section's last lines, not \(range) of its \(illustrated.length) characters")
    }

    // MARK: Page turns

    func testAPageTurnScrollsByOneViewportLessALine() throws {
        let host = scrolledHost([prose(0, length: 30_000), prose(1, length: 30_000)])
        let canvas = host.canvas
        let view = try XCTUnwrap(canvas.scrollTextView)
        let lineHeight = try XCTUnwrap(view.lineFrame(containing: 0)).height
        var tops: [CGFloat] = []
        for turn in 0..<5 {
            let before = canvas.scrollVisibleContainerRect, range = try XCTUnwrap(canvas.visibleRange)
            tops.append(before.minY)
            XCTAssertEqual(canvas.turnPage(forward: true), .turned)
            let after = canvas.scrollVisibleContainerRect, next = try XCTUnwrap(canvas.visibleRange)
            XCTAssertEqual(after.minY - before.minY, before.height - lineHeight, accuracy: 1, "turn \(turn)")
            XCTAssertGreaterThan(next.start, range.start)
            XCTAssertLessThan(next.start, range.end, "turn \(turn): the last line read is still on screen")
            XCTAssertEqual(canvas.anchor, next.start, "the visible start is the position kept")
            XCTAssertEqual(host.recorder.shown.last?.range, next)
        }
        for turn in (0..<5).reversed() {
            XCTAssertEqual(canvas.turnPage(forward: false), .turned)
            XCTAssertEqual(canvas.scrollVisibleContainerRect.minY, tops[turn], accuracy: 1, "back to where turn \(turn) left")
        }
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
        XCTAssertEqual(canvas.turnPage(forward: false), .atBoundary)
    }

    /// Reads the whole book by page turns one way: no line may be skipped between two turns.
    /// `everyTurnMoves` also asks each turn for a new first line; without it a turn may scroll
    /// less than a line, at the text's end.
    private func read(_ host: CanvasHost, forward: Bool, everyTurnMoves: Bool = true, _ label: String,
                      file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let canvas = host.canvas
        var turns = 0
        while turns < 2_000 {
            let before = try XCTUnwrap(canvas.visibleRange, file: file, line: line)
            let predicted = canvas.canTurnPage(forward: forward)
            let result = canvas.turnPage(forward: forward)
            XCTAssertEqual(predicted, result != .atBoundary, "\(label): canTurnPage at \(before)", file: file, line: line)
            guard result == .turned else { break }
            let after = try XCTUnwrap(canvas.visibleRange, file: file, line: line)
            if forward {
                if everyTurnMoves { XCTAssertGreaterThan(after.start, before.start, "\(label) turn \(turns): moved on", file: file, line: line) }
                XCTAssertGreaterThanOrEqual(after.start, before.start, "\(label) turn \(turns): went back", file: file, line: line)
                XCTAssertLessThanOrEqual(after.start, before.end, "\(label) turn \(turns): text skipped between \(before) and \(after)",
                                         file: file, line: line)
            } else {
                if everyTurnMoves { XCTAssertLessThan(after.start, before.start, "\(label) turn \(turns): moved back", file: file, line: line) }
                XCTAssertLessThanOrEqual(after.start, before.start, "\(label) turn \(turns): went on", file: file, line: line)
                XCTAssertGreaterThanOrEqual(after.end, before.start, "\(label) turn \(turns): text skipped between \(after) and \(before)",
                                            file: file, line: line)
            }
            turns += 1
        }
        XCTAssertLessThan(turns, 2_000, label, file: file, line: line)
        return turns
    }

    func testPageTurnsReadTheWholeBookWithoutSkippingALine() throws {
        let lengths = [2_000, 30, 14_000, 600, 9_000, 45, 6_000]
        let sections = lengths.enumerated().map { prose($0.offset, length: $0.element) }
        let host = scrolledHost(sections)
        let last = ReaderTextPosition(section: 6, offset: sections[6].length)
        let forward = try read(host, forward: true, "forward")
        XCTAssertGreaterThan(forward, 10)
        XCTAssertEqual(host.canvas.visibleRange?.end, last)
        XCTAssertTrue(host.canvas.isScrolledToEnd)
        let back = try read(host, forward: false, "back")
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
        XCTAssertGreaterThan(back, 10)
    }

    /// A section of `count` figures, each a book image 200 wide and `height` tall on a line of its
    /// own, with a caption.
    private func figures(_ section: Int, count: Int, height: CGFloat) -> NSAttributedString {
        // One image shown `count` times, as a book repeats an ornament or a publisher's mark.
        guard let image = try? ViewCoverage.readerImage(width: 200, height: Int(height), shownWidth: 200, alt: "Figure") else {
            XCTFail("no image fixture")
            return NSAttributedString()
        }
        return ViewCoverage.joined((0..<count).flatMap { figure in
            [ViewCoverage.imageText(image), CanvasText.body("\nS\(section) figure \(figure)\n")]
        })
    }

    func testPageTurnsReachTheEndsOfABookWhoseHeightTextKitMisjudges() throws {
        // Unlaid text is only estimated. A few characters that are tall figures stand far lower
        // than prose of that length would, and prose after them far higher.
        for order in [[0, 1, 2], [1, 0, 2], [0, 2, 1]] {
            let parts = [prose(0, length: 12_000), figures(1, count: 30, height: 400), prose(2, length: 6_000)]
            let sections = order.map { parts[$0] }
            let host = scrolledHost(sections)
            let canvas = host.canvas, label = "sections in order \(order)"
            let last = ReaderTextPosition(section: 2, offset: sections[2].length)
            let forward = try read(host, forward: true, everyTurnMoves: false, "\(label), forward")
            XCTAssertEqual(canvas.visibleRange?.end, last, "\(label): the last turn shows the book's last line")
            XCTAssertTrue(canvas.isScrolledToEnd, label)
            XCTAssertGreaterThan(forward, 20, "\(label): thirty figures of 400 points take more than twenty screens")
            let view = try XCTUnwrap(canvas.scrollTextView)
            let final = try XCTUnwrap(view.lineFrame(containing: view.textLength - 1))
            XCTAssertLessThanOrEqual(final.maxY, canvas.scrollVisibleContainerRect.maxY + 1, "\(label): the last line is on screen, not below it")
            XCTAssertGreaterThan(final.maxY, canvas.scrollVisibleContainerRect.minY, "\(label): and not scrolled away above")
            _ = try read(host, forward: false, everyTurnMoves: false, "\(label), back")
            XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0), label)
            XCTAssertTrue(canvas.isScrolledToStart, label)
            // And straight to the end from the start of a fresh layout.
            let fresh = scrolledHost(sections)
            fresh.canvas.show(ReaderTextPosition(section: 2, offset: sections[2].length - 1), selecting: nil)
            XCTAssertEqual(fresh.canvas.visibleRange?.end, last, "\(label): a jump to the last character shows the book's end")
        }
    }

    /// Once the book's last line is whole on screen, what is left to turn through is the margin
    /// below it: one turn at most, never another screen.
    func testAtMostOneTurnIsLeftOnceTheBooksLastLineIsOnScreen() throws {
        let sections = [prose(0, length: 12_000), figures(1, count: 30, height: 400), prose(2, length: 6_000)]
        let host = scrolledHost(sections)
        let canvas = host.canvas
        let view = try XCTUnwrap(canvas.scrollTextView)
        let last = ReaderTextPosition(section: 2, offset: sections[2].length)
        func showsTheEnd() throws -> Bool {
            guard canvas.visibleRange?.end == last else { return false }
            return try XCTUnwrap(view.lineFrame(containing: view.textLength - 1)).maxY <= canvas.scrollVisibleContainerRect.maxY + 0.5
        }
        var turns = 0
        while try !showsTheEnd(), turns < 200 {
            XCTAssertEqual(canvas.turnPage(forward: true), .turned, "turn \(turns)")
            turns += 1
        }
        XCTAssertTrue(try showsTheEnd(), "after \(turns) turns")
        let top = canvas.scrollVisibleContainerRect.minY
        if canvas.turnPage(forward: true) == .turned {
            XCTAssertLessThan(canvas.scrollVisibleContainerRect.minY - top, 2 * ReaderCanvasGeometry.verticalMargin, "only the margin was left")
            XCTAssertTrue(try showsTheEnd())
        }
        XCTAssertEqual(canvas.canTurnPage(forward: true), false)
        XCTAssertEqual(canvas.turnPage(forward: true), .atBoundary)
        XCTAssertTrue(canvas.isScrolledToEnd)
    }

    func testPageTurnsBackFromAFarJumpDoNotSkipText() throws {
        // Nothing between the book's start and the jump's target has been laid out, so every
        // turn back scrolls into text TextKit 2 has only estimated.
        let lengths = [3_000, 60_000, 800, 45_000, 20, 70_000]
        let sections = lengths.enumerated().map { prose($0.offset, length: $0.element) }
        let host = scrolledHost(sections)
        let target = ReaderTextPosition(section: 5, offset: 35_000)
        host.canvas.show(target, selecting: nil)
        try assertRestsAtTheTop(target, in: host.canvas, "the jump")
        _ = try read(host, forward: false, "back from the jump")
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0), "all the way to the book's start")
    }

    /// A reader reopened at a saved place, or sent to a chapter, has laid out nothing above it.
    /// "In continuous scroll a page turn scrolls by one viewport less a line": after a turn back
    /// the line that was first is the last on screen, whatever TextKit 2 had estimated for the
    /// two unlaid figures above. Otherwise what lies between is never shown.
    func testAPageTurnBackAfterAJumpPastFiguresKeepsTheLineThatWasFirstOnScreen() throws {
        let sections = [prose(0, length: 9_000), figures(1, count: 2, height: 400), prose(2, length: 6_000)]
        let host = scrolledHost(sections)
        let canvas = host.canvas
        let view = try XCTUnwrap(canvas.scrollTextView)
        let target = ReaderTextPosition(section: 2, offset: 3_000)
        canvas.show(target, selecting: nil)
        try assertRestsAtTheTop(target, in: canvas, "the jump")
        for turn in 0..<4 {
            let first = try XCTUnwrap(canvas.visibleRange?.start)
            XCTAssertEqual(canvas.turnPage(forward: false), .turned, "turn \(turn)")
            let line = try XCTUnwrap(view.line(containing: location(of: first, in: canvas))).frame
            let visible = canvas.scrollVisibleContainerRect
            XCTAssertGreaterThan(line.minY, visible.minY, "turn \(turn) moved back")
            if line.minY > visible.maxY + 1 {
                let shown = try XCTUnwrap(canvas.visibleRange)
                return XCTFail("turn \(turn) back from \(first) shows \(shown): the line that was first is "
                               + "\(Int(line.minY - visible.maxY)) points below the screen, and what lies between was skipped")
            }
        }
    }

    func testPageTurnsForwardAfterAJumpBackPastFiguresDoNotSkipText() throws {
        // Forward is the direction TextKit 2 lays out in: nothing is estimated on the way.
        let sections = [prose(0, length: 9_000), figures(1, count: 30, height: 400), prose(2, length: 6_000)]
        let host = scrolledHost(sections, show: ReaderTextPosition(section: 2, offset: 5_000))
        host.canvas.show(ReaderTextPosition(section: 0, offset: 7_000), selecting: nil)
        try assertRestsAtTheTop(ReaderTextPosition(section: 0, offset: 7_000), in: host.canvas, "the jump back")
        _ = try read(host, forward: true, everyTurnMoves: false, "forward from the jump")
        XCTAssertEqual(host.canvas.visibleRange?.end, ReaderTextPosition(section: 2, offset: sections[2].length))
    }

    func testABookShorterThanTheViewportHasNowhereToTurn() throws {
        let host = scrolledHost([CanvasText.body("A very short book."), CanvasText.body("Its second section.")])
        let canvas = host.canvas
        XCTAssertEqual(canvas.visibleRange, ReaderTextRange(start: ReaderTextPosition(section: 0, offset: 0),
                                                           end: ReaderTextPosition(section: 1, offset: 19)))
        for forward in [true, false] {
            XCTAssertEqual(canvas.canTurnPage(forward: forward), false)
            XCTAssertEqual(canvas.turnPage(forward: forward), .atBoundary)
        }
        canvas.show(ReaderTextPosition(section: 1, offset: 5), selecting: nil)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0), "nothing to scroll: the text stays put")
    }

    // MARK: Resizes

    /// The sizes a dual-screen phone's reader passes through as it closes and opens, and a few more.
    private let resizes = [CGSize(width: 779, height: 669), CGSize(width: 294, height: 678), CGSize(width: 382, height: 678),
                           CGSize(width: 466, height: 678), CGSize(width: 951, height: 669), CGSize(width: 1400, height: 900),
                           CGSize(width: 320, height: 480), CGSize(width: 867, height: 669)]

    func testResizesKeepTheShownPositionsLineAtTheTop() throws {
        let sections = [prose(0, length: 40_000), prose(1, length: 80_000), prose(2, length: 40_000)]
        let host = scrolledHost(sections, size: CGSize(width: 867, height: 669))
        let canvas = host.canvas
        let position = ReaderTextPosition(section: 1, offset: 41_234)
        canvas.show(position, selecting: nil)
        try assertRestsAtTheTop(position, in: canvas, "shown")
        for round in 0..<2 {
            for size in resizes {
                host.resize(to: size)
                try assertRestsAtTheTop(position, in: canvas, "round \(round) at \(size)")
                XCTAssertEqual(canvas.anchor, position, "round \(round) at \(size): no drift to the line's start")
                let width = try XCTUnwrap(canvas.scrollTextView).readerContainer.size.width
                XCTAssertEqual(width, min(720, size.width * 0.93), accuracy: 20, "the column follows the width, less a legacy scroller at most")
            }
        }
    }

    /// "A resize keeps the line holding the position (the last one shown, or the visible start
    /// once the person has scrolled) at the top, through any number of resizes." Nobody scrolls
    /// here; above the position are figures TextKit 2 has not laid out and misjudges.
    func testResizesBelowUnlaidFiguresKeepTheShownPositionsLineAtTheTop() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/164", options: .nonStrict())
        let sections = [prose(0, length: 20_000), figures(1, count: 12, height: 400), prose(2, length: 80_000), prose(3, length: 20_000)]
        let host = scrolledHost(sections, size: CGSize(width: 867, height: 669))
        let canvas = host.canvas
        let view = try XCTUnwrap(canvas.scrollTextView)
        let position = ReaderTextPosition(section: 2, offset: 41_234)
        canvas.show(position, selecting: nil)
        try assertRestsAtTheTop(position, in: canvas, "shown")
        for round in 0..<2 {
            for size in resizes {
                host.resize(to: size)
                let line = try XCTUnwrap(view.line(containing: location(of: position, in: canvas))).frame
                let top = canvas.scrollVisibleContainerRect.minY
                if abs(line.minY - top) > 1 || canvas.anchor != position {
                    return XCTFail("round \(round) at \(size): the line holding \(position) is \(Int(line.minY - top)) points below the top, "
                                   + "and the reader now keeps \(String(describing: canvas.anchor))")
                }
            }
        }
    }

    func testAResizeAfterThePersonScrolledKeepsTheVisibleStart() async throws {
        let host = scrolledHost([prose(0, length: 60_000)])
        let canvas = host.canvas
        let view = try XCTUnwrap(canvas.scrollTextView)
        let line = try XCTUnwrap(view.lineFrame(containing: 20_000))
        // The person scrolls (not through the canvas).
        #if os(macOS)
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: line.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #else
        view.contentOffset = CGPoint(x: 0, y: line.minY)
        #endif
        let deadline = Date().addingTimeInterval(20)
        while canvas.visibleRange?.start.offset == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let reading = try XCTUnwrap(canvas.visibleRange?.start)
        XCTAssertGreaterThan(reading.offset, 10_000)
        for size in [CGSize(width: 420, height: 700), CGSize(width: 900, height: 500), CGSize(width: 600, height: 700)] {
            host.resize(to: size)
            try assertRestsAtTheTop(reading, in: canvas, "\(size)")
        }
        // And a switch to pages shows the page holding it.
        canvas.configuration.flow = .paginated
        host.layOut()
        let page = try XCTUnwrap(canvas.visibleRange)
        XCTAssertTrue(page.start <= reading && reading < page.end, "\(page)")
    }

    #if os(macOS)
    /// AppKit aligns the scroll offset to the pixel grid when it first draws the scroll view,
    /// which moves the view a fraction of a point. Nobody scrolled: the reader still keeps the
    /// position it was shown, not the start of that position's line
    /// ([#302](https://github.com/vocaro/EPUBLib/issues/302)).
    func testTheScrollViewsFirstDisplayIsNotAScrollByThePerson() throws {
        let sections = [prose(0, length: 40_000), prose(1, length: 80_000), prose(2, length: 40_000)]
        let host = scrolledHost(sections, size: CGSize(width: 867, height: 669))
        let canvas = host.canvas
        let position = ReaderTextPosition(section: 1, offset: 41_234)
        canvas.show(position, selecting: nil)
        try assertRestsAtTheTop(position, in: canvas, "shown")
        let top = canvas.scrollVisibleContainerRect.minY
        host.window.displayIfNeeded()
        let moved = abs(canvas.scrollVisibleContainerRect.minY - top)
        try XCTSkipIf(moved == 0, "AppKit left the offset where the reader put it")
        XCTAssertLessThan(moved, 1, "the first display moves the view by less than a point")
        for size in resizes.prefix(4) {
            host.resize(to: size)
            try assertRestsAtTheTop(position, in: canvas, "\(size)")
            XCTAssertEqual(canvas.anchor, position, "\(size): no drift to the line's start")
        }
    }

    /// A scroll by the person counts however slowly it goes: one line, half a point at a time.
    func testAScrollOfHalfAPointAtATimeIsAScrollByThePerson() throws {
        let host = scrolledHost([prose(0, length: 60_000)])
        let canvas = host.canvas
        let view = try XCTUnwrap(canvas.scrollTextView)
        let position = ReaderTextPosition(section: 0, offset: 20_000)
        canvas.show(position, selecting: nil)
        host.window.displayIfNeeded()
        let first = try XCTUnwrap(view.line(containing: position.offset))
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
        for _ in 0..<Int((first.frame.height * 2).rounded(.up)) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + 0.5))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        host.resize(to: CGSize(width: 420, height: 700))
        let kept = try XCTUnwrap(canvas.anchor)
        XCTAssertEqual(kept.offset, NSMaxRange(first.range), "the line scrolled to is the place kept")
        try assertRestsAtTheTop(kept, in: canvas, "after the resize")
    }
    #endif

    // MARK: Column

    func testTheScrollColumnKeepsToTheWiderSideOfADivision() throws {
        for division in [CGRect(x: 180, y: 0, width: 40, height: 700), CGRect(x: 520, y: 0, width: 40, height: 700)] {
            let host = scrolledHost([prose(0, length: 20_000)], size: CGSize(width: 800, height: 700), division: division)
            let canvas = host.canvas
            let view = try XCTUnwrap(canvas.scrollTextView)
            let area = canvas.scrollColumnArea()
            let expected = ReaderCanvasGeometry.scrollColumn(in: CGRect(x: area.minX, y: 0, width: area.width, height: 700), division: division)
            XCTAssertEqual(view.readerContainer.size.width, expected.width, accuracy: 0.5)
            let column = view.convert(CGRect(x: view.containerOrigin.x, y: 0, width: view.readerContainer.size.width, height: 10), to: canvas)
            XCTAssertEqual(column.minX, expected.minX, accuracy: 0.5, "\(division)")
            XCTAssertFalse(column.intersects(division), "text never crosses the division")
            XCTAssertEqual(column.minX > division.maxX, division.minX < 400, "on the wider side")
            // Every line of the first screen is inside the column.
            for offset in stride(from: 0, to: 2_000, by: 150) {
                let line = try XCTUnwrap(view.line(containing: offset)).frame
                XCTAssertGreaterThanOrEqual(line.minX, -0.5)
                XCTAssertLessThanOrEqual(line.maxX, expected.width + 0.5)
            }
            // Folding flat again recentres the column and keeps the position.
            canvas.show(ReaderTextPosition(section: 0, offset: 9_000), selecting: nil)
            canvas.configuration.division = nil
            host.layOut()
            let flat = ReaderCanvasGeometry.scrollColumn(in: CGRect(x: area.minX, y: 0, width: area.width, height: 700), division: nil)
            XCTAssertEqual(view.readerContainer.size.width, flat.width, accuracy: 0.5)
            try assertRestsAtTheTop(ReaderTextPosition(section: 0, offset: 9_000), in: canvas, "unfolded")
        }
    }
}
