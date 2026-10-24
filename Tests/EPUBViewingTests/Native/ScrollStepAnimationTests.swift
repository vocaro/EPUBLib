import CoreGraphics
import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A page turn in continuous scroll where the host chose a page-turn animation (#622,
/// doc/native-viewer.md, "Input and accessibility"): its text scrolls from where it was drawn to
/// where the turn put it, which is the turn's as soon as it is made, and a canvas with no
/// animation lands in the same place at once.
@MainActor final class ScrollStepAnimationTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    /// Three sections of plain prose, a few screens each, scrolled as one book.
    private func host(_ animation: EPUBPageTurnAnimation, reducesMotion: Bool = false) async throws -> CanvasHost {
        let texts = (0..<3).map { section in
            CanvasText.body((0..<40).map {
                "Section \(section) paragraph \($0) of ordinary reading text that wraps across the column more than once for the test.\n"
            }.joined())
        }
        let source = FakeCanvasSource(texts)
        source.book = CanvasText.book(texts)
        var configuration = ReaderCanvasConfiguration(flow: .scrolled)
        configuration.pageTurnAnimation = animation
        configuration.reducesMotion = reducesMotion
        let host = CanvasHost(source, size: CGSize(width: 500, height: 700), configuration: configuration)
        hosts.append(host)
        host.canvas.voiceOverIsRunning = { false }
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        host.layOut()
        try await host.settle()
        return host
    }

    /// The top of the visible area as the text is drawn, in text container coordinates.
    private func top(_ host: CanvasHost) -> CGFloat { host.canvas.scrollVisibleContainerRect.minY }

    /// Waits for the step in motion to end, and gives each top of the visible area the text was
    /// drawn at on the way.
    private func follow(_ host: CanvasHost, file: StaticString = #filePath, line: UInt = #line) async throws -> [CGFloat] {
        var tops: [CGFloat] = []
        let deadline = Date().addingTimeInterval(3)
        while host.canvas.scrollStep != nil, Date() < deadline {
            tops.append(top(host))
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(host.canvas.scrollStep, "the step ends", file: file, line: line)
        return tops
    }

    /// Some frame on the way drew the text between where it started and where it ends. A display
    /// asleep draws none, and the step then ends where it would have, unseen.
    private func requireFramesOnTheWay(_ tops: [CGFloat], from: CGFloat, to target: CGFloat,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let between = tops.filter { $0 > min(from, target) + 1 && $0 < max(from, target) - 1 }
        #if os(macOS)
        if between.isEmpty, CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            throw XCTSkip("Unmeasured: the display is asleep, so no frame drew the step on its way")
        }
        #endif
        XCTAssertFalse(between.isEmpty, "the text was drawn on its way, \(tops)", file: file, line: line)
        let moving = zip(between, between.dropFirst()).allSatisfy { target > from ? $1 >= $0 : $1 <= $0 }
        XCTAssertTrue(moving, "always towards where it ends, \(between)", file: file, line: line)
    }

    /// The turn is taken, reported and kept as with no animation, at once; only the drawing
    /// follows, from where the text was to where it lands, and nothing more is told on the way
    /// or after. Both animations scroll, forward and back.
    func testATurnScrollsItsTextToWhereItLandsAndTellsThatAtOnce() async throws {
        for animation in [EPUBPageTurnAnimation.slide, .dissolve] {
            let instant = try await host(.none), animated = try await host(animation)
            XCTAssertEqual(top(animated), top(instant), accuracy: 0.5)
            for forward in [true, true, false] {
                let label = "\(animation), \(forward ? "forward" : "back")"
                let before = top(animated), reports = animated.recorder.shown.count
                XCTAssertEqual(instant.canvas.turnPage(forward: forward), .turned, label)
                XCTAssertNil(instant.canvas.scrollStep, "\(label): with no animation the text is there at once")
                XCTAssertEqual(animated.canvas.turnPage(forward: forward), .turned, label)
                XCTAssertEqual(animated.canvas.visibleRange, instant.canvas.visibleRange, "\(label): where it lands")
                XCTAssertEqual(animated.canvas.anchor, instant.canvas.anchor, label)
                XCTAssertEqual(animated.recorder.shown.count, reports + 1, "\(label): told once")
                XCTAssertEqual(animated.recorder.shown.last?.range, instant.canvas.visibleRange, "\(label): told at once")
                XCTAssertNotNil(animated.canvas.scrollStep, "\(label): its text is on its way")
                XCTAssertEqual(top(animated), before, accuracy: 1, "\(label): from where it was drawn")
                let tops = try await follow(animated)
                try requireFramesOnTheWay(tops, from: before, to: top(instant))
                XCTAssertEqual(top(animated), top(instant), accuracy: 0.5, "\(label): it ends where the turn put it")
                try await animated.settle()
                XCTAssertEqual(animated.recorder.shown.count, reports + 1, "\(label): nothing more is told")
                XCTAssertEqual(animated.canvas.visibleRange, instant.canvas.visibleRange, label)
                XCTAssertEqual(animated.canvas.anchor, instant.canvas.anchor, "\(label): nobody scrolled")
            }
        }
    }

    /// A turn made while a step is in motion is taken from where that one ends, so turns made
    /// quickly go as far as the same turns with no animation, and its text goes on from where
    /// it is drawn, with no jump, or from two screens before where it lands where it has
    /// fallen further behind than that.
    func testATurnMadeWhileAStepIsInMotionGoesOnFromWhereThatOneEnds() async throws {
        let instant = try await host(.none), animated = try await host(.slide)
        for forward in [true, false] {
            let label = forward ? "forward" : "back"
            let before = top(animated)
            for _ in 1...2 {
                XCTAssertEqual(instant.canvas.turnPage(forward: forward), .turned, label)
                XCTAssertEqual(animated.canvas.turnPage(forward: forward), .turned, label)
                XCTAssertEqual(animated.canvas.visibleRange, instant.canvas.visibleRange, "\(label): from the turn before's end")
            }
            XCTAssertEqual(top(animated), before, accuracy: 1, "\(label): the text has not moved yet")
            try await Task.sleep(for: .milliseconds(120))
            let drawn = top(animated)
            XCTAssertEqual(instant.canvas.turnPage(forward: forward), .turned, label)
            XCTAssertEqual(animated.canvas.turnPage(forward: forward), .turned, label)
            XCTAssertEqual(animated.canvas.visibleRange, instant.canvas.visibleRange, "\(label): a third turn on the way")
            let screens = 2 * animated.canvas.scrollVisibleContainerRect.height, landing = top(instant)
            XCTAssertEqual(top(animated), forward ? max(drawn, landing - screens) : min(drawn, landing + screens), accuracy: 1,
                           "\(label): goes on from where the text is drawn, at most two screens behind")
            let tops = try await follow(animated)
            try requireFramesOnTheWay([drawn] + tops, from: before, to: top(instant))
            XCTAssertEqual(top(animated), top(instant), accuracy: 0.5, "\(label): three turns' worth")
            XCTAssertEqual(animated.canvas.anchor, instant.canvas.anchor, label)
        }
    }

    /// With no animation the text steps at once, as it does under Reduce Motion, while VoiceOver
    /// is running, and for a turn an assistive technology asks for by name: VoiceOver's scroll,
    /// and on Mac its Scroll Forward and Scroll Backward.
    func testATurnStepsAtOnceUnderReduceMotionWhileVoiceOverRunsAndForAnAssistiveTechnology() async throws {
        let instant = try await host(.none)
        XCTAssertEqual(instant.canvas.turnPage(forward: true), .turned)
        let landed = top(instant), range = instant.canvas.visibleRange
        let reduced = try await host(.slide, reducesMotion: true)
        let voiceOver = try await host(.slide)
        voiceOver.canvas.voiceOverIsRunning = { true }
        let assistive = try await host(.dissolve)
        let turns: [(String, CanvasHost, () -> Bool)] = [
            ("Reduce Motion", reduced, { reduced.canvas.turnPage(forward: true) == .turned }),
            ("VoiceOver running", voiceOver, { voiceOver.canvas.turnPage(forward: true) == .turned }),
            ("an assistive technology's turn", assistive, { assistive.canvas.turnPageFromAccessibility(forward: true) }),
        ]
        for (label, host, turn) in turns {
            XCTAssertTrue(turn(), label)
            XCTAssertNil(host.canvas.scrollStep, "\(label): nothing in motion")
            XCTAssertEqual(top(host), landed, accuracy: 0.5, "\(label): the text is where the turn put it")
            XCTAssertEqual(host.canvas.visibleRange, range, label)
        }
        XCTAssertEqual(assistive.canvas.accessibilityTurns, 0, "a turn by name is over when it returns")
        XCTAssertEqual(assistive.canvas.turnPage(forward: true), .turned)
        XCTAssertNotNil(assistive.canvas.scrollStep, "the next turn asked for otherwise scrolls")
    }

    /// Anything else that moves the text first ends a step in motion where it would have ended:
    /// a position shown, a drag on iPhone and iPad or the wheel on Mac, scrolling the reader did
    /// not do, after which the place kept is read from the screen again, and a resize.
    func testAnythingElseThatMovesTheTextEndsAStepWhereItLands() async throws {
        let animated = try await host(.slide)
        let canvas = animated.canvas
        let view = try XCTUnwrap(canvas.scrollTextView)
        func turn() throws -> CGFloat {
            XCTAssertEqual(canvas.turnPage(forward: true), .turned)
            return try XCTUnwrap(canvas.scrollStep, "a step in motion").target
        }
        _ = try turn()
        let shown = ReaderTextPosition(section: 2, offset: 0)
        canvas.show(shown, selecting: nil)
        XCTAssertNil(canvas.scrollStep, "a position shown")
        XCTAssertEqual(canvas.visibleRange?.start, shown)

        var target = try turn()
        #if os(iOS)
        canvas.scrollViewWillBeginDragging(view)
        #else
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
        try XCTUnwrap(canvas.scrollContainer as? NSScrollView).scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        #endif
        XCTAssertNil(canvas.scrollStep, "a drag or the wheel")
        XCTAssertEqual(top(animated), target, accuracy: 0.5, "takes the text from where the step ends")

        target = try turn()
        let landed = try XCTUnwrap(canvas.visibleRange)
        #if os(iOS)
        view.contentOffset.y += 1
        #else
        let clip = try XCTUnwrap(canvas.scrollContainer as? NSScrollView).contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 1))
        #endif
        XCTAssertNil(canvas.scrollStep, "scrolling the reader did not do")
        XCTAssertEqual(top(animated), target, accuracy: 0.5)
        try await animated.settle()
        XCTAssertEqual(canvas.visibleRange, landed, "read again where the step ended")

        _ = try turn()
        let turned = try XCTUnwrap(canvas.anchor)
        animated.resize(to: CGSize(width: 500, height: 640))
        XCTAssertNil(canvas.scrollStep, "a resize")
        try await animated.settle()
        XCTAssertEqual(canvas.visibleRange?.start, turned, "the turn's place, kept through the resize")
    }
}
