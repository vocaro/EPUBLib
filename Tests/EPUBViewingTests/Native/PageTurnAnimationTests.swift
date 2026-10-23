import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import QuartzCore
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A page turn's animation in paginated flow (doc/native-viewer.md, "Input and accessibility",
/// #688): what moves, which way, for which turns, and what stays as it is with no animation.
/// The columns hold the page turned to as soon as it is turned; only what is drawn over them
/// moves. What VoiceOver reads after a turn is held by the accessibility tests run again with a
/// slide (`SlidingPageTurnAccessibilityTests` and the Mac's), and heard in the simulator lane
/// (doc/testing.md, "Page turn animation").
@MainActor final class PageTurnAnimationTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private func host(_ sections: [NSAttributedString?] = [CanvasText.section(0, paragraphs: 30)],
                      animation: EPUBPageTurnAnimation = .slide, reducesMotion: Bool = false, rtl: Bool = false,
                      size: CGSize = CGSize(width: 600, height: 700)) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.pageTurnAnimation = animation
        configuration.reducesMotion = reducesMotion
        configuration.isRightToLeft = rtl
        let host = CanvasHost(FakeCanvasSource(sections), size: size, configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return host
    }

    private func overlays(in canvas: ReaderCanvasView) -> [ReaderPageTransitionView] {
        canvas.subviews.compactMap { $0 as? ReaderPageTransitionView }
    }

    private func layer(of view: PlatformView) -> CALayer? { view.layer }

    private func turnAnimation(of view: PlatformView) -> CABasicAnimation? {
        layer(of: view)?.animation(forKey: ReaderPageTransition.animationKey) as? CABasicAnimation
    }

    private func opacity(of view: PlatformView) -> CGFloat {
        #if os(macOS)
        view.alphaValue
        #else
        view.alpha
        #endif
    }

    /// The side the page turned to comes in from, +1 the right and -1 the left, and how far, as
    /// the transition animates the canvas's columns; nil where they do not slide.
    private func slideIn(of canvas: ReaderCanvasView, file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat? {
        let columns = canvas.textViews
        XCTAssertFalse(columns.isEmpty, file: file, line: line)
        let offsets = try columns.map { column -> CGFloat? in
            let animation = try XCTUnwrap(turnAnimation(of: column), "a column is drawn coming in", file: file, line: line)
            guard animation.keyPath == "position" else { return nil }
            XCTAssertTrue(animation.isAdditive, file: file, line: line)
            XCTAssertEqual(animation.toValue as? CGPoint, .zero, "it ends where it stands", file: file, line: line)
            let from = try XCTUnwrap(animation.fromValue as? CGPoint, file: file, line: line)
            XCTAssertEqual(from.y, 0, file: file, line: line)
            return from.x
        }
        XCTAssertEqual(Set(offsets.map { $0 ?? .nan }).count, 1, "every column comes in together", file: file, line: line)
        return offsets.first ?? nil
    }

    // MARK: The animation chosen

    func testReduceMotionTurnsASlideIntoADissolveAndLeavesTheOthers() {
        XCTAssertNil(ReaderPageMotion(.none, reducesMotion: false))
        XCTAssertNil(ReaderPageMotion(.none, reducesMotion: true))
        XCTAssertEqual(ReaderPageMotion(.slide, reducesMotion: false), .slide)
        XCTAssertEqual(ReaderPageMotion(.slide, reducesMotion: true), .dissolve)
        XCTAssertEqual(ReaderPageMotion(.dissolve, reducesMotion: false), .dissolve)
        XCTAssertEqual(ReaderPageMotion(.dissolve, reducesMotion: true), .dissolve)
        XCTAssertEqual(ReaderCanvasConfiguration().pageTurnAnimation, .none, "none is the default")
    }

    func testWithNoAnimationOnePageReplacesTheOtherAtOnce() throws {
        let canvas = host(animation: .none).canvas
        XCTAssertNil(canvas.pageMotion)
        let first = try XCTUnwrap(canvas.visibleRange)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(canvas.visibleRange?.start, first.end)
        XCTAssertNil(canvas.pageTransition)
        XCTAssertTrue(overlays(in: canvas).isEmpty)
        for column in canvas.textViews { XCTAssertNil(turnAnimation(of: column)) }
        XCTAssertFalse(canvas.beginPageDrag(), "no swipe is followed")
    }

    /// Continuous scroll has no page to slide or dissolve, and no swipe to follow: a turn
    /// scrolls its text there instead (`ScrollStepAnimationTests`, #622).
    func testContinuousScrollTurnsNoPageAndScrollsItsTextInstead() throws {
        let host = host()
        let canvas = host.canvas
        canvas.voiceOverIsRunning = { false }
        canvas.configuration.flow = .scrolled
        host.layOut()
        XCTAssertNil(canvas.pageMotion)
        let first = try XCTUnwrap(canvas.visibleRange)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertNotEqual(canvas.visibleRange, first)
        XCTAssertNil(canvas.pageTransition)
        XCTAssertNotNil(canvas.scrollStep, "its text scrolls there")
        XCTAssertFalse(canvas.beginPageDrag())
    }

    // MARK: A turn made at once

    /// The page turned to is the canvas's as soon as the turn returns: reported, in the columns
    /// and where they stand. Only a picture of the page that was shown goes, the way the book
    /// reads, and the columns are drawn coming in from the other side.
    func testASlideShowsThePageTurnedToAtOnceAndDrawsItComingInFromTheSideTheBookReadsTowards() throws {
        for rtl in [false, true] {
            for forward in [true, false] {
                let label = "rtl \(rtl), forward \(forward)"
                let host = host(rtl: rtl)
                let canvas = host.canvas
                if !forward {
                    XCTAssertEqual(canvas.turnPage(forward: true), .turned)
                    canvas.endPageTransition()
                }
                let before = try XCTUnwrap(canvas.visibleRange)
                let shownBefore = canvas.textViews.map(\.visibleText)
                let frames = canvas.textViews.map(\.frame)
                let reports = host.recorder.shown.count
                let expected = try framesTurned(forward: forward, rtl: rtl)
                XCTAssertEqual(canvas.turnPage(forward: forward), .turned, label)
                let after = try XCTUnwrap(canvas.visibleRange)
                XCTAssertEqual(forward ? after.start : after.end, forward ? before.end : before.start, label)
                XCTAssertEqual(host.recorder.shown.count, reports + 1, "\(label): told once, at once")
                XCTAssertEqual(host.recorder.shown.last?.range, after, label)
                XCTAssertNotEqual(canvas.textViews.map(\.visibleText), shownBefore, "\(label): the columns hold the new page")
                XCTAssertEqual(canvas.textViews.map(\.frame), expected, "\(label): where they stand with no animation")
                let transition = try XCTUnwrap(canvas.pageTransition, label)
                XCTAssertEqual(transition.motion, .slide)
                XCTAssertFalse(transition.isDrag)
                // Forward in a book read left to right, the next page comes in from the right and the
                // page shown goes off to the left; the other way round back, and right to left.
                let side: CGFloat = forward != rtl ? 1 : -1
                let width = canvas.bounds.width
                XCTAssertEqual(try slideIn(of: canvas), side * width, label)
                XCTAssertEqual(transition.outgoing.frame.origin.x, -side * width, "\(label): it ends off the canvas")
                let going = try XCTUnwrap(turnAnimation(of: transition.outgoing))
                XCTAssertEqual(going.fromValue as? CGPoint, CGPoint(x: side * width, y: 0), "\(label): it starts where the page stood")
                XCTAssertEqual(transition.outgoing.subviews.count, shownBefore.count, "\(label): a picture of each column")
                for (picture, frame) in zip(transition.outgoing.subviews.map(\.frame), frames) {
                    XCTAssertEqual(picture.minX, frame.minX, accuracy: 0.5, "\(label): where the column stood")
                    XCTAssertEqual(picture.minY, frame.minY, accuracy: 0.5)
                    XCTAssertEqual(picture.width, frame.width, accuracy: 0.5)
                    XCTAssertEqual(picture.height, frame.height, accuracy: 0.5)
                }
                // It is drawn over the columns and under nothing else, and it ends with its animation.
                let overlay = try XCTUnwrap(overlays(in: canvas).first)
                XCTAssertEqual(overlays(in: canvas).count, 1)
                let index = try XCTUnwrap(canvas.subviews.firstIndex { $0 === overlay })
                for column in canvas.textViews {
                    XCTAssertLessThan(try XCTUnwrap(canvas.subviews.firstIndex { $0 === column }), index, label)
                }
            }
        }
    }

    /// Where the columns stand after the same turn with no animation.
    private func framesTurned(forward: Bool, rtl: Bool) throws -> [CGRect] {
        let canvas = host(animation: .none, rtl: rtl).canvas
        if !forward { XCTAssertEqual(canvas.turnPage(forward: true), .turned) }
        XCTAssertEqual(canvas.turnPage(forward: forward), .turned)
        return canvas.textViews.map(\.frame)
    }

    func testATurnInMotionEndsWithItsAnimationAndLeavesTheColumnsAsTheyStand() async throws {
        let host = host()
        let canvas = host.canvas
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let transition = try XCTUnwrap(canvas.pageTransition)
        let deadline = TestDeadline(seconds: 5)
        while canvas.pageTransition != nil, try !deadline.hasPassed() { try await host.settle(50) }
        XCTAssertNil(canvas.pageTransition, "it ends once its animation is over")
        XCTAssertTrue(transition.isEnded)
        XCTAssertTrue(overlays(in: canvas).isEmpty)
        for column in canvas.textViews {
            XCTAssertNil(turnAnimation(of: column))
            XCTAssertEqual(opacity(of: column), 1)
        }
    }

    func testATurnMadeWhileAnotherIsInMotionEndsThatOne() throws {
        let canvas = host().canvas
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let first = try XCTUnwrap(canvas.pageTransition)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let second = try XCTUnwrap(canvas.pageTransition)
        XCTAssertTrue(first.isEnded)
        XCTAssertFalse(first === second)
        XCTAssertEqual(overlays(in: canvas).count, 1, "one picture going at a time")
        // So does a relayout, and anything else that shows a page.
        canvas.reloadContent(keeping: nil)
        XCTAssertTrue(second.isEnded)
        XCTAssertNil(canvas.pageTransition)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let third = try XCTUnwrap(canvas.pageTransition)
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        XCTAssertTrue(third.isEnded)
        XCTAssertTrue(overlays(in: canvas).isEmpty)
        // And a change of the animation chosen.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let fourth = try XCTUnwrap(canvas.pageTransition)
        canvas.configuration.pageTurnAnimation = .dissolve
        XCTAssertTrue(fourth.isEnded)
    }

    func testATurnThatTurnsNothingDrawsNothing() throws {
        let canvas = host([CanvasText.body(CanvasText.sentence(20, seed: 1))]).canvas
        XCTAssertEqual(canvas.turnPage(forward: false), .atBoundary)
        XCTAssertEqual(canvas.turnPage(forward: true), .atBoundary)
        XCTAssertNil(canvas.pageTransition)
        XCTAssertTrue(overlays(in: canvas).isEmpty)
    }

    /// A turn into the next section, and one that waits for that section to be built, which the
    /// session finishes once it is (`showTurned`): both slide as any other.
    func testATurnIntoAnotherSectionSlidesAsAnyOtherAndSoDoesOneThatWaitedForItsBuild() throws {
        let sections = [CanvasText.section(0, chapters: 1, paragraphs: 3), CanvasText.section(1, paragraphs: 10)]
        let host = host([sections[0], nil])
        let canvas = host.canvas
        canvas.show(ReaderTextPosition(section: 0, offset: sections[0].length), selecting: nil)
        XCTAssertEqual(canvas.turnPage(forward: true), .pending(section: 1))
        XCTAssertNil(canvas.pageTransition, "nothing is shown yet")
        XCTAssertEqual(host.recorder.needed.last?.section, 1)
        host.source.sections[1] = sections[1]
        canvas.showTurned(ReaderTextPosition(section: 1, offset: 0), forward: true)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
        XCTAssertNotNil(canvas.pageTransition)
        XCTAssertEqual(try slideIn(of: canvas), canvas.bounds.width)
        // Back into the section before, already built: its last page comes in from the left.
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(canvas.visibleRange?.end, ReaderTextPosition(section: 0, offset: sections[0].length))
        XCTAssertEqual(try slideIn(of: canvas), -canvas.bounds.width)
    }

    func testASpreadOfTwoColumnsSlidesAsOnePage() throws {
        let canvas = host(size: CGSize(width: 1_200, height: 700)).canvas
        XCTAssertEqual(canvas.textViews.count, 2)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(try slideIn(of: canvas), canvas.bounds.width)
        let transition = try XCTUnwrap(canvas.pageTransition)
        XCTAssertEqual(transition.outgoing.subviews.count, 2)
    }

    // MARK: Reduce Motion and the dissolve

    /// With Reduce Motion on a slide does not slide: the page shown fades out over the page turned
    /// to, which fades in where it stands. A dissolve chosen does the same.
    func testUnderReduceMotionATurnDissolvesAndNothingMoves() throws {
        for (animation, reduces) in [(EPUBPageTurnAnimation.slide, true), (.dissolve, false), (.dissolve, true)] {
            for rtl in [false, true] {
                let label = "\(animation), Reduce Motion \(reduces), rtl \(rtl)"
                let canvas = host(animation: animation, reducesMotion: reduces, rtl: rtl).canvas
                for forward in [true, false] {
                    XCTAssertEqual(canvas.turnPage(forward: forward), .turned, label)
                    let transition = try XCTUnwrap(canvas.pageTransition, label)
                    XCTAssertEqual(transition.motion, .dissolve, label)
                    XCTAssertNil(try slideIn(of: canvas), "\(label): the columns do not move")
                    for column in canvas.textViews {
                        let animation = try XCTUnwrap(turnAnimation(of: column))
                        XCTAssertEqual(animation.keyPath, "opacity", label)
                        XCTAssertEqual(animation.fromValue as? Float, 0)
                        XCTAssertEqual(animation.toValue as? Float, 1)
                        XCTAssertEqual(opacity(of: column), 1, "\(label): it ends drawn whole")
                    }
                    XCTAssertEqual(transition.outgoing.frame.origin.x, 0, "\(label): the picture stays where the page stood")
                    let going = try XCTUnwrap(turnAnimation(of: transition.outgoing))
                    XCTAssertEqual(going.keyPath, "opacity", label)
                    XCTAssertEqual(going.fromValue as? Float, 1)
                    XCTAssertEqual(going.toValue as? Float, 0)
                }
            }
        }
    }

    func testTurningReduceMotionOnOrOffChangesTheNextTurn() throws {
        let canvas = host().canvas
        XCTAssertEqual(canvas.pageMotion, .slide)
        canvas.configuration.reducesMotion = true
        XCTAssertEqual(canvas.pageMotion, .dissolve)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(canvas.pageTransition?.motion, .dissolve)
        canvas.configuration.reducesMotion = false
        XCTAssertNil(canvas.pageTransition, "the turn in motion ends")
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(canvas.pageTransition?.motion, .slide)
    }

    // MARK: A turn a swipe follows

    /// A swipe moves the page with it and brings in the page it turns to, drawn by columns of its
    /// own as the turn would show it, and turns nothing until it lets go past its turn.
    func testASwipeBringsInThePageItTurnsToAndTurnsNothingUntilItLetsGo() throws {
        for rtl in [false, true] {
            let host = host(rtl: rtl)
            let canvas = host.canvas
            let width = canvas.bounds.width
            let first = try XCTUnwrap(canvas.visibleRange)
            let reports = host.recorder.shown.count
            // Towards the left reads on, and towards the right in a book read right to left.
            let onward: CGFloat = rtl ? 1 : -1
            XCTAssertTrue(canvas.beginPageDrag())
            canvas.dragPage(by: onward * 0.3 * width)
            let transition = try XCTUnwrap(canvas.pageTransition)
            XCTAssertTrue(transition.isDrag)
            XCTAssertEqual(transition.dragForward, true, "rtl \(rtl)")
            XCTAssertEqual(canvas.visibleRange, first, "rtl \(rtl): nothing is turned yet")
            XCTAssertEqual(host.recorder.shown.count, reports)
            XCTAssertEqual(transition.outgoing.frame.origin.x, onward * 0.3 * width, accuracy: 0.001, "the page moves with the swipe")
            let preview = transition.preview
            XCTAssertEqual(preview.count, 1)
            let incoming = try XCTUnwrap(preview.first?.superview)
            XCTAssertEqual(incoming.frame.origin.x, -onward * 0.7 * width, accuracy: 0.001, "the page it brings in stands beside it")
            XCTAssertFalse(incoming.isHidden)
            let previewFrame = try XCTUnwrap(preview.first?.frame)
            XCTAssertEqual(preview.first?.placement.offset, first.end.offset, "the next page")
            let previewText = preview.map(\.visibleText)
            XCTAssertNotEqual(previewText, canvas.textViews.map(\.visibleText))
            // Let go past half the width, it turns to that page, which the columns then show as the
            // preview did, and goes the rest of the way in.
            canvas.dragPage(by: onward * 0.6 * width)
            let turns = ReaderPageDrag.turns(offset: onward * 0.6 * width, velocity: 0, width: width)
            XCTAssertEqual(canvas.endPageDrag(turns: turns, animated: true), .turned)
            XCTAssertEqual(canvas.visibleRange?.start, first.end, "rtl \(rtl)")
            XCTAssertEqual(canvas.textViews.map(\.visibleText), previewText, "the page brought in is the page turned to")
            XCTAssertEqual(canvas.textViews.first?.frame, previewFrame, "laid out where the canvas shows it")
            XCTAssertEqual(host.recorder.shown.count, reports + 1, "told once, as the swipe lets go")
            XCTAssertTrue(transition.isSettling)
            XCTAssertEqual(incoming.frame.origin.x, 0, "it ends where the columns stand")
            XCTAssertEqual(transition.outgoing.frame.origin.x, onward * width)
            canvas.endPageTransition()
            XCTAssertTrue(preview.allSatisfy { $0.superview == nil && $0.textLength == 0 }, "the preview's columns are let go")
            XCTAssertTrue(overlays(in: canvas).isEmpty)
        }
    }

    func testASwipeLetGoShortOfItsTurnPutsThePageBackAndTurnsNothing() throws {
        let host = host()
        let canvas = host.canvas
        let width = canvas.bounds.width
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        canvas.endPageTransition()
        let shown = try XCTUnwrap(canvas.visibleRange)
        let text = canvas.textViews.map(\.visibleText)
        let reports = host.recorder.shown.count
        for (offset, velocity) in [(-0.4 * width, 0.0), (0.45 * width, 0), (-0.8 * width, 400), (0.7 * width, -500)] as [(CGFloat, CGFloat)] {
            XCTAssertTrue(canvas.beginPageDrag())
            canvas.dragPage(by: offset / 2)
            canvas.dragPage(by: offset)
            let transition = try XCTUnwrap(canvas.pageTransition)
            XCTAssertFalse(transition.preview.isEmpty, "a page lies each way")
            let turns = ReaderPageDrag.turns(offset: offset, velocity: velocity, width: width)
            XCTAssertFalse(turns, "\(offset) at \(velocity)")
            XCTAssertNil(canvas.endPageDrag(turns: turns, animated: true))
            XCTAssertEqual(canvas.visibleRange, shown, "the page goes back")
            XCTAssertEqual(canvas.textViews.map(\.visibleText), text)
            XCTAssertEqual(host.recorder.shown.count, reports, "nothing is told")
            XCTAssertEqual(transition.outgoing.frame.origin.x, 0, "it ends where it began")
            canvas.endPageTransition()
        }
    }

    func testASwipeThatChangesDirectionBringsInThePageOnItsOtherSide() throws {
        let canvas = host().canvas
        let width = canvas.bounds.width
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        canvas.endPageTransition()
        let next = try XCTUnwrap(canvas.visibleRange?.end)
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: -0.2 * width)
        let transition = try XCTUnwrap(canvas.pageTransition)
        XCTAssertEqual(transition.dragForward, true)
        let forwardPreview = transition.preview
        XCTAssertEqual(forwardPreview.first?.placement.offset, next.offset)
        canvas.dragPage(by: 0.3 * width)
        XCTAssertEqual(transition.dragForward, false)
        XCTAssertEqual(transition.preview.first?.placement.offset, 0, "the first page, on the left")
        XCTAssertTrue(forwardPreview.allSatisfy { $0.superview == nil && $0.textLength == 0 }, "the other is let go")
        XCTAssertEqual(try XCTUnwrap(transition.preview.first?.superview).frame.origin.x, 0.3 * width - width, accuracy: 0.001)
        XCTAssertEqual(canvas.endPageDrag(turns: true, animated: false), .turned)
        XCTAssertEqual(canvas.visibleRange?.start.offset, 0)
        XCTAssertNil(canvas.pageTransition, "let go with no animation, it has ended")
    }

    /// At an end of the book a swipe gives less and less and puts the page back; into a section
    /// not built it does the same, and the turn it asked for slides in once the section is.
    func testASwipeTowardsNoPageGivesLessAndPutsItBack() throws {
        let sections = [CanvasText.section(0, chapters: 1, paragraphs: 3), CanvasText.section(1, paragraphs: 10)]
        let host = host([sections[0], nil])
        let canvas = host.canvas
        let width = canvas.bounds.width
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: 0.5 * width)
        let transition = try XCTUnwrap(canvas.pageTransition)
        XCTAssertTrue(transition.preview.isEmpty, "the book's first page has none before it")
        let resisted = transition.outgoing.frame.origin.x
        XCTAssertGreaterThan(resisted, 0)
        XCTAssertLessThan(resisted, 0.25 * width)
        canvas.dragPage(by: 0.9 * width)
        XCTAssertGreaterThan(transition.outgoing.frame.origin.x, resisted)
        XCTAssertLessThan(transition.outgoing.frame.origin.x, 0.35 * width)
        XCTAssertEqual(canvas.endPageDrag(turns: true, animated: false), .atBoundary)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
        // Towards a section not yet built: the page stays, and the section is asked for.
        canvas.show(ReaderTextPosition(section: 0, offset: sections[0].length), selecting: nil)
        let last = try XCTUnwrap(canvas.visibleRange)
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: -0.7 * width)
        XCTAssertTrue(try XCTUnwrap(canvas.pageTransition).preview.isEmpty)
        XCTAssertEqual(canvas.endPageDrag(turns: true, animated: false), .pending(section: 1))
        XCTAssertEqual(canvas.visibleRange, last)
        XCTAssertNil(canvas.pageTransition)
        XCTAssertEqual(host.recorder.needed.last?.section, 1)
        host.source.sections[1] = sections[1]
        canvas.showTurned(ReaderTextPosition(section: 1, offset: 0), forward: true)
        XCTAssertEqual(try slideIn(of: canvas), width)
    }

    func testASwipeIntoTheNextSectionBringsInItsFirstPage() throws {
        let sections = [CanvasText.section(0, chapters: 1, paragraphs: 3), CanvasText.section(1, paragraphs: 10)]
        let host = host(sections)
        let canvas = host.canvas
        canvas.show(ReaderTextPosition(section: 0, offset: sections[0].length), selecting: nil)
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: -100)
        let preview = try XCTUnwrap(canvas.pageTransition?.preview.first)
        XCTAssertEqual(preview.placement.section, 1)
        XCTAssertEqual(preview.placement.offset, 0)
        let text = preview.visibleText
        XCTAssertEqual(canvas.endPageDrag(turns: true, animated: false), .turned)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
        XCTAssertEqual(canvas.textViews.first?.visibleText, text)
    }

    func testADissolvingSwipeFadesTheOnePageIntoTheOtherAndMovesNothing() throws {
        let canvas = host(reducesMotion: true).canvas
        let width = canvas.bounds.width
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: -0.25 * width)
        let transition = try XCTUnwrap(canvas.pageTransition)
        XCTAssertEqual(transition.motion, .dissolve)
        let incoming = try XCTUnwrap(transition.preview.first?.superview)
        XCTAssertEqual(transition.outgoing.frame.origin.x, 0)
        XCTAssertEqual(incoming.frame.origin.x, 0)
        XCTAssertEqual(opacity(of: transition.outgoing), 0.75, accuracy: 0.001)
        XCTAssertEqual(opacity(of: incoming), 0.25, accuracy: 0.001)
        XCTAssertNil(canvas.endPageDrag(turns: false, animated: true))
        XCTAssertEqual(opacity(of: transition.outgoing), 1)
        XCTAssertEqual(opacity(of: incoming), 0)
    }

    /// A selection begun during a swipe holds the page, as it holds back a swipe that has not
    /// begun, and with text selected no swipe begins.
    func testASelectionHoldsThePageBackFromASwipe() throws {
        let canvas = host().canvas
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: -100)
        canvas.beginSelectionDrag(at: ReaderTextPosition(section: 0, offset: 10))
        canvas.dragPage(by: -400)
        let transition = try XCTUnwrap(canvas.pageTransition)
        XCTAssertTrue(transition.isSettling, "the page goes back")
        XCTAssertNil(canvas.endPageDrag(turns: true, animated: true))
        XCTAssertEqual(canvas.visibleRange?.start.offset, 0)
        canvas.endSelectionDrag()
        canvas.endPageTransition()
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: ReaderTextRange(section: 0, 4..<20))
        XCTAssertTrue(canvas.hasSelection)
        XCTAssertFalse(canvas.beginPageDrag())
    }

    func testWhetherASwipeLetGoTurnsThePage() {
        let width: CGFloat = 400
        for (offset, velocity, turns) in [
            (-201.0, 0.0, true), (-199, 0, false), (201, 0, true), (0, 900, false),
            (-30, -300, true), (30, 300, true), (-30, -299, false),
            (-350, 300, false), (350, -300, false), (-350, 200, true),
        ] as [(CGFloat, CGFloat, Bool)] {
            XCTAssertEqual(ReaderPageDrag.turns(offset: offset, velocity: velocity, width: width), turns, "\(offset) at \(velocity)")
        }
        XCTAssertTrue(ReaderPageDrag.forward(offset: -1, isRightToLeft: false))
        XCTAssertFalse(ReaderPageDrag.forward(offset: 1, isRightToLeft: false))
        XCTAssertFalse(ReaderPageDrag.forward(offset: -1, isRightToLeft: true))
        XCTAssertTrue(ReaderPageDrag.forward(offset: 1, isRightToLeft: true))
        var last: CGFloat = 0
        for offset in stride(from: CGFloat(20), through: 2_000, by: 20) {
            let given = ReaderPageDrag.resisted(offset, width: width)
            XCTAssertGreaterThan(given, last, "it gives more the further it goes")
            XCTAssertLessThan(given, offset, "and never as far")
            XCTAssertEqual(ReaderPageDrag.resisted(-offset, width: width), -given)
            last = given
        }
        XCTAssertLessThan(last, width)
    }

    // MARK: Selection, highlights and what is told

    /// A turn with text selected, which the host's command and VoiceOver's actions make, and a
    /// page with a search match on it: what is selected, what is painted and what the delegate
    /// is told are those with no animation.
    func testASlideKeepsTheSelectionTheHighlightsAndWhatIsToldAsTheyAreWithNone() throws {
        struct Outcome: Equatable {
            var shown: [ReaderTextRange]
            var selection: ReaderSelection?
            var selected: [NSRange]
            var painted: [[NSRange]]
            var selections: [ReaderSelection?]
        }
        func painted(_ view: ReaderTextView) -> [NSRange] {
            var ranges: [NSRange] = []
            let manager = view.readerLayoutManager
            manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attributes, range in
                if attributes[.backgroundColor] != nil {
                    let start = view.offset(of: range.location), end = view.offset(of: range.endLocation)
                    ranges.append(NSRange(location: start, length: end - start))
                }
                return true
            }
            return ranges
        }
        func outcome(_ animation: EPUBPageTurnAnimation) throws -> Outcome {
            let host = host(animation: animation)
            let canvas = host.canvas
            let page = try XCTUnwrap(canvas.visibleRange)
            // A passage across the page's end, and matches on both pages.
            let passage = ReaderTextRange(section: 0, (page.end.offset - 40)..<(page.end.offset + 40))
            canvas.show(page.start, selecting: passage)
            canvas.setHighlights([
                ReaderHighlight(id: "this", range: ReaderTextRange(section: 0, 30..<38), kind: .search),
                ReaderHighlight(id: "next", range: ReaderTextRange(section: 0, (page.end.offset + 60)..<(page.end.offset + 70)), kind: .currentSearch),
            ])
            let reports = host.recorder.shown.count
            XCTAssertEqual(canvas.turnPage(forward: true), .turned)
            XCTAssertEqual(canvas.pageTransition != nil, animation != .none)
            XCTAssertEqual(canvas.turnPage(forward: false), .turned)
            XCTAssertEqual(canvas.turnPage(forward: true), .turned)
            return Outcome(shown: host.recorder.shown.dropFirst(reports).map(\.range), selection: canvas.currentSelection,
                           selected: canvas.textViews.map(\.selectedRange), painted: canvas.textViews.map(painted),
                           selections: host.recorder.selections)
        }
        let none = try outcome(.none)
        XCTAssertNotNil(none.selection)
        XCTAssertFalse(none.painted.joined().isEmpty)
        XCTAssertEqual(try outcome(.slide), none)
        XCTAssertEqual(try outcome(.dissolve), none)
    }

    /// The pages a swipe brings in are painted with the highlights the turn shows them with.
    func testThePageASwipeBringsInIsPaintedWithItsHighlights() throws {
        let canvas = host().canvas
        let page = try XCTUnwrap(canvas.visibleRange)
        canvas.setHighlights([ReaderHighlight(id: "next", range: ReaderTextRange(section: 0, (page.end.offset + 60)..<(page.end.offset + 70)),
                                              kind: .search)])
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: -200)
        let preview = try XCTUnwrap(canvas.pageTransition?.preview.first)
        var found: [Int] = []
        let manager = preview.readerLayoutManager
        manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attributes, range in
            if attributes[.backgroundColor] != nil { found.append(preview.offset(of: range.location)) }
            return true
        }
        XCTAssertEqual(found, [60])
    }

    /// The picture of the page that goes is the page as it was drawn: its words are in it.
    func testThePictureOfThePageThatGoesHoldsItsWords() throws {
        let canvas = host().canvas
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let picture = try XCTUnwrap(canvas.pageTransition?.outgoing.subviews.first)
        #if os(macOS)
        let image = try XCTUnwrap((picture as? NSImageView)?.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #else
        // UIKit's own snapshot of what is on screen cannot be read back; a column not yet drawn
        // on screen, as in a test, is drawn into an image.
        guard let image = (picture as? UIImageView)?.image?.cgImage else {
            throw XCTSkip("UIKit gave a snapshot of its own, which a test cannot read")
        }
        #endif
        let width = image.width, height = image.height
        XCTAssertGreaterThan(width, 0)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        var inked = 0
        for index in stride(from: 0, to: pixels.count, by: 4 * 3) where pixels[index + 3] > 128 {
            if Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) < 3 * 128 { inked += 1 }
        }
        XCTAssertGreaterThan(inked, 100, "the page's text is drawn in it")
    }

    // MARK: Nothing for an assistive technology

    func testWhatATurnDrawsIsNothingAnAssistiveTechnologyReadsOrATouchReaches() throws {
        let canvas = host().canvas
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: -100)
        let transition = try XCTUnwrap(canvas.pageTransition)
        let overlay = transition.overlay
        let preview = try XCTUnwrap(transition.preview.first)
        #if os(iOS)
        XCTAssertFalse(overlay.isAccessibilityElement)
        XCTAssertTrue(overlay.accessibilityElementsHidden)
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertTrue(preview.accessibilityElementsHidden)
        let elements = try XCTUnwrap(canvas.accessibilityElements as? [NSObject])
        XCTAssertTrue(elements.allSatisfy { element in canvas.textViews.contains { $0 === element } }, "the columns alone")
        XCTAssertNil(canvas.hitTest(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), with: nil) as? ReaderPageTransitionView)
        #else
        XCTAssertFalse(overlay.isAccessibilityElement())
        XCTAssertTrue(overlay.isAccessibilityHidden())
        XCTAssertNil(overlay.accessibilityChildren())
        XCTAssertFalse(preview.isAccessibilityElement())
        XCTAssertNil(overlay.hitTest(CGPoint(x: 100, y: 100)))
        // Walking the canvas's tree as an assistive client does meets the columns and nothing of the turn's.
        var reached: [NSObject] = []
        func children(_ element: Any) -> [Any] {
            if let view = element as? NSView { return view.accessibilityChildren() ?? [] }
            return (element as? NSAccessibilityElement)?.accessibilityChildren() ?? []
        }
        func walk(_ element: Any) {
            for child in NSAccessibility.unignoredChildren(from: children(element)) {
                guard let object = child as? NSObject else { continue }
                reached.append(object)
                walk(object)
            }
        }
        walk(canvas)
        XCTAssertFalse(reached.contains { $0 === overlay || $0 === preview || $0 === transition.outgoing })
        XCTAssertTrue(canvas.textViews.allSatisfy { column in reached.contains { $0 === column } })
        #endif
        XCTAssertNil(canvas.endPageDrag(turns: false, animated: false))
    }

    // MARK: A mounted reader

    /// The modifier reaches a mounted reader and changes it live, with no reload and no
    /// relocation, and the host's command then turns the page as before, with its animation.
    func testTheModifierReachesAMountedReaderLive() async throws {
        let reader = try SessionCoverageReader(Fixture.epub())
        defer { reader.close() }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        XCTAssertEqual(canvas.configuration.pageTurnAnimation, .none)
        XCTAssertFalse(canvas.configuration.reducesMotion)
        let views = canvas.textViews, range = canvas.visibleRange, relocated = reader.locations.count
        reader.window?.pageControls.pageTurnAnimation = .slide
        try await reader.wait("the slide") { canvas.configuration.pageTurnAnimation == .slide }
        XCTAssertEqual(canvas.pageMotion, .slide)
        XCTAssertEqual(canvas.visibleRange, range)
        XCTAssertEqual(reader.locations.count, relocated)
        XCTAssertEqual(canvas.textViews.count, views.count)
        XCTAssertTrue(zip(canvas.textViews, views).allSatisfy { $0 === $1 })
        reader.session.reducesMotion = true
        XCTAssertEqual(canvas.pageMotion, .dissolve, "Reduce Motion, as the session is told of it")
        reader.session.reducesMotion = false
        try await reader.session.send(.nextPage)
        try await reader.wait("the next page") { canvas.visibleRange != range && reader.locations.count > relocated }
        reader.window?.pageControls.pageTurnAnimation = .none
        try await reader.wait("no animation") { canvas.configuration.pageTurnAnimation == .none }
        XCTAssertNil(canvas.pageMotion)
    }

    // MARK: Every kind of turn

    #if os(iOS)
    /// A tap at an edge, a key, VoiceOver's scroll and a line's page action all slide.
    func testEveryKindOfTurnSlidesOnIPhoneAndIPad() throws {
        for rtl in [false, true] {
            let host = host(rtl: rtl)
            let canvas = host.canvas
            let width = canvas.bounds.width
            func turned(_ kind: String, forward: Bool, file: StaticString = #filePath, line: UInt = #line, _ turn: () throws -> Void) throws {
                let before = try XCTUnwrap(canvas.visibleRange, file: file, line: line)
                canvas.endPageTransition()
                try turn()
                XCTAssertNotEqual(canvas.visibleRange, before, "\(kind) turned, rtl \(rtl)", file: file, line: line)
                XCTAssertEqual(try slideIn(of: canvas, file: file, line: line), (forward != rtl ? 1 : -1) * width,
                               "\(kind), rtl \(rtl)", file: file, line: line)
            }
            // The edge the book reads towards.
            let edge = CGPoint(x: rtl ? canvas.bounds.minX + 10 : canvas.bounds.maxX - 10, y: canvas.bounds.midY)
            try turned("an edge tap", forward: true) {
                canvas.pointerDown = (edge, 1)
                canvas.edgeTap(at: edge, liftedAt: 1.1)
            }
            try turned("a key", forward: true) {
                canvas.pageTurnKeyCommand(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [],
                                                       action: #selector(ReaderCanvasView.pageTurnKeyCommand(_:))))
            }
            try turned("a key back", forward: false) {
                canvas.pageTurnKeyCommand(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [],
                                                       action: #selector(ReaderCanvasView.pageTurnKeyCommand(_:))))
            }
            try turned("VoiceOver's scroll", forward: true) { XCTAssertTrue(canvas.accessibilityScroll(.next)) }
            try turned("VoiceOver's scroll back", forward: false) { XCTAssertTrue(canvas.accessibilityScroll(.previous)) }
            let line = try XCTUnwrap((canvas.textViews.first?.accessibilityElements as? [UIAccessibilityElement])?.first)
            try turned("a line's Next Page", forward: true) {
                let action = try XCTUnwrap(line.accessibilityCustomActions?.first { $0.name == "Next Page" })
                XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action))
            }
            try turned("the host's command", forward: false) { XCTAssertEqual(canvas.turnPage(forward: false), .turned) }
        }
    }

    /// A swipe is followed where a turn is animated and is a swipe as before where none is.
    func testTheCanvasFollowsASwipeWithAPanWhereATurnIsAnimated() {
        let canvas = host(animation: .none).canvas
        func enabled() -> (swipes: [Bool], pans: [Bool]) {
            let recognizers = canvas.gestureRecognizers ?? []
            return (recognizers.filter { $0 is UISwipeGestureRecognizer }.map(\.isEnabled),
                    recognizers.filter { $0 is ReaderPagePanRecognizer }.map(\.isEnabled))
        }
        XCTAssertEqual(enabled().swipes, [true, true])
        XCTAssertEqual(enabled().pans, [false])
        canvas.configuration.pageTurnAnimation = .slide
        XCTAssertEqual(enabled().swipes, [false, false])
        XCTAssertEqual(enabled().pans, [true])
        canvas.configuration.reducesMotion = true
        XCTAssertEqual(enabled().pans, [true], "a dissolve follows it too")
        canvas.configuration.pageControls.touchSwipesEnabled = false
        XCTAssertEqual(enabled().swipes, [false, false])
        XCTAssertEqual(enabled().pans, [false])
        canvas.configuration.pageControls.touchSwipesEnabled = true
        canvas.configuration.flow = .scrolled
        XCTAssertEqual(enabled().swipes, [false, false])
        XCTAssertEqual(enabled().pans, [false])
    }
    #else
    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in host: CanvasHost) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: host.window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, host: CanvasHost) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func wheel(lines: Double) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines < 0 ? -1 : 1,
                                          wheel2: 0, wheel3: 0))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: lines)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    /// A click at an edge, a key, the wheel, a text area's page action and the host's command
    /// all slide.
    func testEveryKindOfTurnSlidesOnMac() throws {
        for rtl in [false, true] {
            let host = host(rtl: rtl)
            let canvas = host.canvas
            let width = canvas.bounds.width
            func turned(_ kind: String, forward: Bool, file: StaticString = #filePath, line: UInt = #line, _ turn: () throws -> Void) throws {
                let before = try XCTUnwrap(canvas.visibleRange, file: file, line: line)
                canvas.endPageTransition()
                canvas.wheelTurner = ReaderWheelPageTurner()
                try turn()
                XCTAssertNotEqual(canvas.visibleRange, before, "\(kind) turned, rtl \(rtl)", file: file, line: line)
                XCTAssertEqual(try slideIn(of: canvas, file: file, line: line), (forward != rtl ? 1 : -1) * width,
                               "\(kind), rtl \(rtl)", file: file, line: line)
            }
            let edge = CGPoint(x: rtl ? canvas.bounds.minX + 5 : canvas.bounds.maxX - 5, y: canvas.bounds.midY)
            try turned("an edge click", forward: true) {
                canvas.mouseDown(with: mouse(.leftMouseDown, at: edge, in: canvas, host: host))
                canvas.mouseUp(with: mouse(.leftMouseUp, at: edge, in: canvas, host: host))
            }
            try turned("a key", forward: true) {
                try XCTUnwrap(canvas.textViews.first).keyDown(with: key(124, "\u{F703}", [.function, .numericPad], in: host))
            }
            try turned("a key back", forward: false) { canvas.keyDown(with: key(123, "\u{F702}", [.function, .numericPad], in: host)) }
            try turned("the wheel", forward: true) { canvas.scrollWheel(with: try wheel(lines: -1)) }
            try turned("the wheel back", forward: false) { canvas.scrollWheel(with: try wheel(lines: 1)) }
            try turned("VoiceOver's Next Page", forward: true) {
                let column = try XCTUnwrap(canvas.textViews.first)
                let action = try XCTUnwrap(column.accessibilityCustomActions()?.first { $0.name == "Next Page" })
                XCTAssertTrue(try XCTUnwrap(action.handler)())
            }
            try turned("the host's command", forward: false) { XCTAssertEqual(canvas.turnPage(forward: false), .turned) }
        }
    }

    /// A trackpad's swipe, as AppKit tracks it: the page follows its amount and turns when AppKit
    /// takes it all the way, and goes back when AppKit takes it back.
    func testATrackpadSwipeIsFollowedAndTurnsOnlyWhenAppKitTakesItAllTheWay() throws {
        for rtl in [false, true] {
            let host = host(rtl: rtl)
            let canvas = host.canvas
            let width = canvas.bounds.width
            XCTAssertEqual(canvas.turnPage(forward: true), .turned)
            canvas.endPageTransition()
            let shown = try XCTUnwrap(canvas.visibleRange)
            // Taken back: nothing turns.
            XCTAssertTrue(canvas.beginPageDrag())
            for amount in [-0.1, -0.3, -0.2] as [CGFloat] { XCTAssertTrue(canvas.followPageSwipe(amount: amount, complete: false)) }
            let transition = try XCTUnwrap(canvas.pageTransition)
            XCTAssertEqual(transition.dragForward, !rtl)
            XCTAssertEqual(transition.outgoing.frame.origin.x, -0.2 * width, accuracy: 0.001)
            XCTAssertTrue(canvas.followPageSwipe(amount: 0, complete: true))
            XCTAssertEqual(canvas.visibleRange, shown, "rtl \(rtl)")
            XCTAssertNil(canvas.pageTransition)
            XCTAssertFalse(canvas.followPageSwipe(amount: -0.5, complete: false), "AppKit is told to stop")
            // Taken all the way to the right: the page before in a book read left to right.
            XCTAssertTrue(canvas.beginPageDrag())
            for amount in [0.2, 0.6, 0.9] as [CGFloat] { canvas.followPageSwipe(amount: amount, complete: false) }
            let preview = try XCTUnwrap(canvas.pageTransition?.preview.map(\.visibleText))
            canvas.followPageSwipe(amount: 1, complete: true)
            XCTAssertEqual(rtl ? canvas.visibleRange?.start : canvas.visibleRange?.end, rtl ? shown.end : shown.start, "rtl \(rtl)")
            XCTAssertEqual(canvas.textViews.map(\.visibleText), preview)
            XCTAssertNil(canvas.pageTransition)
            XCTAssertTrue(overlays(in: canvas).isEmpty)
        }
    }

    /// A turn made by a key while a swipe is tracked ends the swipe, and AppKit is told to stop.
    func testATurnMadeWhileATrackpadSwipeIsFollowedEndsTheSwipe() throws {
        let host = host()
        let canvas = host.canvas
        XCTAssertTrue(canvas.beginPageDrag())
        XCTAssertTrue(canvas.followPageSwipe(amount: -0.3, complete: false))
        let drag = try XCTUnwrap(canvas.pageTransition)
        canvas.keyDown(with: key(124, "\u{F703}", [.function, .numericPad], in: host))
        XCTAssertTrue(drag.isEnded)
        XCTAssertFalse(try XCTUnwrap(canvas.pageTransition).isDrag, "the key's own turn slides")
        XCTAssertFalse(canvas.followPageSwipe(amount: -0.6, complete: false))
    }

    #endif
}
