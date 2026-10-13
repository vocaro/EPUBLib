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

/// The paginated canvas in a real window: spreads at a section's ends, page turns at the book's
/// ends, position keeping, the selection continuation controls and what the canvas releases.
@MainActor final class ViewCoverageCanvasTests: XCTestCase {
    private var hosts: [CanvasHost] = []
    private var sources: [FakeCanvasSource] = []
    #if os(macOS)
    private var windows: [NSWindow] = []
    #endif

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        #if os(macOS)
        for window in windows {
            window.close()
            window.contentView = nil
        }
        windows.removeAll()
        #endif
        sources.removeAll()
        try await super.tearDown()
    }

    private func host(_ sections: [NSAttributedString?], linear: [Bool]? = nil,
                      size: CGSize = CGSize(width: 600, height: 700),
                      configuration: ReaderCanvasConfiguration = .init(),
                      show position: ReaderTextPosition? = ReaderTextPosition(section: 0, offset: 0)) -> CanvasHost {
        let host = CanvasHost(FakeCanvasSource(sections, linear: linear), size: size, configuration: configuration)
        hosts.append(host)
        if let position { host.canvas.show(position, selecting: nil) }
        host.layOut()
        return host
    }

    private func sections(_ count: Int, paragraphs: Int = 8) -> [NSAttributedString?] {
        (0..<count).map { CanvasText.section($0, paragraphs: paragraphs) }
    }

    private func configuration(flow: EPUBReadingFlow = .paginated, rtl: Bool = false) -> ReaderCanvasConfiguration {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = flow
        configuration.isRightToLeft = rtl
        return configuration
    }

    /// Turns pages one way until the book's end, checking `canTurnPage` against each turn.
    /// Returns the sections shown, in order.
    private func walk(_ host: CanvasHost, forward: Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> [Int] {
        var seen = [host.canvas.visibleRange?.start.section ?? -1]
        var turns = 0
        while turns < 300 {
            let predicted = host.canvas.canTurnPage(forward: forward)
            let before = host.canvas.visibleRange
            let result = host.canvas.turnPage(forward: forward)
            XCTAssertEqual(predicted, result != .atBoundary, "\(label): canTurnPage before turn \(turns) at \(String(describing: before))",
                           file: file, line: line)
            guard result == .turned else {
                XCTAssertEqual(result, .atBoundary, label, file: file, line: line)
                XCTAssertEqual(host.canvas.visibleRange, before, "\(label): a turn at the book's end changes nothing", file: file, line: line)
                break
            }
            XCTAssertNotEqual(host.canvas.visibleRange, before, "\(label): turn \(turns) moved", file: file, line: line)
            if let section = host.canvas.visibleRange?.start.section, section != seen.last { seen.append(section) }
            turns += 1
        }
        XCTAssertLessThan(turns, 300, "\(label): the walk ends", file: file, line: line)
        return seen
    }

    // MARK: Sections' ends

    func testAnEmptySectionIsOneBlankPageBetweenItsNeighbours() throws {
        let all: [NSAttributedString?] = [CanvasText.section(0, chapters: 1, paragraphs: 2), NSAttributedString(),
                                         CanvasText.section(2, chapters: 1, paragraphs: 2)]
        let last = try XCTUnwrap(all[2]).length
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            for size in [CGSize(width: 600, height: 700), CGSize(width: 1100, height: 800)] {
                let label = "\(flow) \(size.width)"
                let host = host(all, size: size, configuration: configuration(flow: flow))
                XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0), label)
                XCTAssertEqual(walk(host, forward: true, label), [0, 1, 2], label)
                XCTAssertEqual(host.canvas.visibleRange?.end, ReaderTextPosition(section: 2, offset: last), label)
                XCTAssertEqual(walk(host, forward: false, label), [2, 1, 0], label)
                XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0), label)
                // On the blank page itself.
                host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
                XCTAssertEqual(host.canvas.visibleRange, ReaderTextRange(section: 1, 0..<0), label)
                XCTAssertEqual(host.recorder.shown.last?.range, ReaderTextRange(section: 1, 0..<0), label)
                XCTAssertEqual(host.recorder.shown.last?.progress, 0, label)
                XCTAssertEqual(host.canvas.canTurnPage(forward: true), true, label)
                XCTAssertEqual(host.canvas.canTurnPage(forward: false), true, label)
                XCTAssertTrue(host.canvas.textViews.allSatisfy { $0.visibleText.isEmpty }, label)
            }
        }
    }

    /// A section with an odd number of pages at `host`'s two-column size, and its pages.
    private func oddSection(_ index: Int, for host: CanvasHost) throws -> (text: NSAttributedString, pages: [ReaderPage]) {
        let size = try XCTUnwrap(host.canvas.spread?.columnSize)
        for paragraphs in 3..<40 {
            let text = CanvasText.section(index, chapters: 1, paragraphs: paragraphs)
            let pages = ReaderPaginator(text: text, size: size).allPages
            if pages.count >= 3, pages.count % 2 == 1 { return (text, pages) }
        }
        throw XCTSkip("no fixture with an odd page count at \(size)")
    }

    func testASectionNeverSharesItsLastSpreadWithTheNext() throws {
        for rtl in [false, true] {
            let host = host([CanvasText.body("Placeholder")], size: CGSize(width: 1100, height: 800), configuration: configuration(rtl: rtl))
            let canvas = host.canvas
            XCTAssertEqual(canvas.spread?.columns.count, 2)
            let (first, pages) = try oddSection(0, for: host)
            host.source.sections = [first, CanvasText.section(1, chapters: 1, paragraphs: 12)]
            host.source.linear = [true, true]
            canvas.reloadContent(keeping: ReaderTextPosition(section: 0, offset: 0))
            let lastPage = try XCTUnwrap(pages.last)
            for _ in 0..<(pages.count / 2) { XCTAssertEqual(canvas.turnPage(forward: true), .turned) }
            // The last spread: the odd page in the first column, the second column empty.
            func assertLastSpread(_ step: String) {
                XCTAssertEqual(canvas.visibleRange, ReaderTextRange(section: 0, lastPage.range.location..<first.length), "\(step), rtl \(rtl)")
                XCTAssertEqual(canvas.textViews.count, 1, step)
                XCTAssertEqual(canvas.columns.count, 2, step)
                XCTAssertFalse(canvas.columns[0].isHidden, step)
                XCTAssertEqual(canvas.columns[0].placement.offset, lastPage.range.location, step)
                XCTAssertEqual(canvas.columns[0].visibleText, (first.string as NSString).substring(with: lastPage.range), step)
                XCTAssertTrue(canvas.columns[1].isHidden, step)
                XCTAssertEqual(canvas.columns[1].textLength, 0, "\(step): no text of the next section, or of the page before")
                XCTAssertEqual(canvas.columns[0].frame.minX > canvas.bounds.midX, rtl, "\(step): the first slice's side")
            }
            assertLastSpread("turning forward")
            XCTAssertEqual(canvas.turnPage(forward: true), .turned)
            XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
            XCTAssertEqual(canvas.textViews.count, 2)
            XCTAssertEqual(canvas.textViews.map(\.placement.section), [1, 1])
            // Turning back into the section shows its end: the same last spread.
            XCTAssertEqual(canvas.turnPage(forward: false), .turned)
            assertLastSpread("turning back")
            XCTAssertEqual(canvas.turnPage(forward: false), .turned)
            XCTAssertEqual(canvas.visibleRange, ReaderTextRange(section: 0, pages[pages.count - 3].range.location..<lastPage.range.location))
            // And a position on the last page shows the same spread, not a spread starting there.
            canvas.show(ReaderTextPosition(section: 0, offset: first.length), selecting: nil)
            assertLastSpread("showing the section's end")
            canvas.show(ReaderTextPosition(section: 0, offset: pages[1].range.location + 5), selecting: nil)
            XCTAssertEqual(canvas.visibleRange?.start.offset, 0, "spreads keep to even pages")
        }
    }

    func testCanTurnPageAgreesWithEveryTurnAroundNonlinearAndUnbuiltSections() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            // Nonlinear sections at both ends and in the middle: none is ever turned into.
            let host = host(sections(5, paragraphs: 2), linear: [false, true, false, true, false], configuration: configuration(flow: flow),
                            show: ReaderTextPosition(section: 1, offset: 0))
            XCTAssertEqual(host.canvas.canTurnPage(forward: false), false, "\(flow): only a nonlinear section before the first page")
            XCTAssertEqual(host.canvas.turnPage(forward: false), .atBoundary)
            XCTAssertEqual(walk(host, forward: true, "\(flow)"), [1, 3])
            XCTAssertEqual(host.canvas.canTurnPage(forward: true), false, "\(flow): only a nonlinear section after the last page")
            XCTAssertEqual(walk(host, forward: false, "\(flow) back"), [3, 1])
            // A nonlinear section shown on its own is left by a turn either way.
            host.canvas.show(ReaderTextPosition(section: 2, offset: 0), selecting: nil)
            XCTAssertEqual(host.canvas.canTurnPage(forward: false), true)
            XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
            XCTAssertEqual(host.canvas.visibleRange?.start.section, 1, "\(flow)")
            // An unbuilt neighbour can be turned to, once it is built.
            let pending = self.host([CanvasText.section(0, chapters: 1, paragraphs: 1), nil], configuration: configuration(flow: flow))
            var result = pending.canvas.turnPage(forward: true)
            while result == .turned { result = pending.canvas.turnPage(forward: true) }
            XCTAssertEqual(result, .pending(section: 1), "\(flow)")
            XCTAssertEqual(pending.canvas.canTurnPage(forward: true), true, "\(flow)")
        }
        let unmounted = ReaderCanvasView(frame: .zero)
        XCTAssertNil(unmounted.canTurnPage(forward: true), "nothing is known before the first layout")
        XCTAssertEqual(unmounted.turnPage(forward: true), .atBoundary)
    }

    // MARK: Position keeping

    func testThePositionAskedForIsKeptExactlyThroughResizesAndFlowSwitches() throws {
        let host = host(sections(1, paragraphs: 30))
        let canvas = host.canvas
        let asked = ReaderTextPosition(section: 0, offset: 9_000)
        canvas.show(asked, selecting: nil)
        func assertShown(_ step: String) throws {
            let range = try XCTUnwrap(canvas.visibleRange)
            XCTAssertTrue(range.start <= asked && asked < range.end, "\(step): \(range)")
            XCTAssertEqual(canvas.anchor, asked, "\(step): the position asked for, not its page's start")
        }
        for round in 0..<3 {
            for size in [CGSize(width: 1100, height: 800), CGSize(width: 420, height: 800), CGSize(width: 600, height: 700),
                         CGSize(width: 337, height: 451)] {
                host.resize(to: size)
                try assertShown("round \(round) \(size)")
            }
            canvas.configuration.flow = .scrolled
            host.layOut()
            try assertShown("round \(round) scrolled")
            canvas.configuration.flow = .paginated
            host.layOut()
            try assertShown("round \(round) paginated")
        }
        // After a page turn the page's start is the position kept.
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let start = try XCTUnwrap(canvas.visibleRange?.start)
        XCTAssertEqual(canvas.anchor, start)
        for size in [CGSize(width: 1100, height: 800), CGSize(width: 600, height: 700), CGSize(width: 1100, height: 800)] {
            host.resize(to: size)
            XCTAssertEqual(canvas.anchor, start)
            let range = try XCTUnwrap(canvas.visibleRange)
            XCTAssertTrue(range.start <= start && start < range.end, "\(size): \(range)")
        }
    }

    func testAPositionAndPassageInAnUnbuiltSectionWaitForItsText() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let host = host([CanvasText.section(0, paragraphs: 4), nil], configuration: configuration(flow: flow))
            let before = try XCTUnwrap(host.canvas.visibleRange)
            let passage = ReaderTextRange(section: 1, 500..<540)
            host.canvas.show(passage.start, selecting: passage)
            XCTAssertEqual(host.canvas.visibleRange, before, "\(flow): nothing to show yet")
            XCTAssertNil(host.canvas.currentSelection)
            let built = CanvasText.section(1, paragraphs: 4)
            host.source.sections[1] = built
            host.canvas.reloadContent(keeping: nil)
            let range = try XCTUnwrap(host.canvas.visibleRange)
            XCTAssertEqual(range.start.section, 1, "\(flow)")
            XCTAssertTrue(range.start <= passage.start && passage.start < range.end, "\(flow): \(range)")
            XCTAssertEqual(host.canvas.currentSelection, ReaderSelection(range: passage,
                text: (built.string as NSString).substring(with: NSRange(location: 500, length: 40))), "\(flow)")
        }
    }

    // MARK: Selection

    private func continuationControls(_ canvas: ReaderCanvasView) -> (previous: PlatformView, next: PlatformView)? {
        guard let indicator = canvas.subviews.first(where: { $0 is ReaderSelectionContinuation }) else { return nil }
        func control(_ label: String) -> PlatformView? {
            indicator.subviews.first { view in
                #if os(macOS)
                (view as? NSButton)?.accessibilityLabel() == label
                #else
                (view as? UIButton)?.accessibilityLabel == label
                #endif
            }
        }
        guard let previous = control("Previous page of selected passage"), let next = control("Next page of selected passage") else { return nil }
        return (previous, next)
    }

    private func press(_ control: PlatformView) {
        #if os(macOS)
        (control as? NSButton)?.performClick(nil)
        #else
        // `sendActions(for:)` goes through `UIApplication.shared`, and the package's tests run without an application.
        guard let button = control as? UIButton else { return }
        for target in button.allTargets {
            for action in button.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                _ = (target as NSObject).perform(NSSelectorFromString(action))
            }
        }
        #endif
    }

    func testContinuationControlsFollowALocatedPassageToItsFirstAndLastPage() throws {
        let host = host(sections(1, paragraphs: 20))
        let canvas = host.canvas
        let text = try XCTUnwrap(host.source.sections[0])
        let pages = try XCTUnwrap(canvas.paginator(for: 0)).allPages
        XCTAssertGreaterThan(pages.count, 5)
        // From the end of the second page, across the third, into the fourth.
        let passage = ReaderTextRange(section: 0, (NSMaxRange(pages[1].range) - 40)..<(pages[3].range.location + 60))
        let expected = (text.string as NSString).substring(with: NSRange(location: passage.start.offset,
                                                                         length: passage.end.offset - passage.start.offset))
        XCTAssertNil(continuationControls(canvas), "no passage, no controls")
        canvas.show(passage.start, selecting: passage)
        func assertPage(_ index: Int, previous: Bool, next: Bool, _ step: String) throws {
            XCTAssertEqual(canvas.visibleRange?.start.offset, pages[index].range.location, step)
            XCTAssertEqual(canvas.currentSelection, ReaderSelection(range: passage, text: expected), step)
            let controls = try XCTUnwrap(continuationControls(canvas), step)
            XCTAssertEqual(controls.previous.isHidden, !previous, "\(step): Previous")
            XCTAssertEqual(controls.next.isHidden, !next, "\(step): Next")
            let column = try XCTUnwrap(canvas.textViews.first)
            XCTAssertEqual(canvas.selectionText(for: column), expected, "\(step): Copy takes the whole passage")
            XCTAssertEqual(column.selectedRange, canvas.localRange(of: passage, in: column), step)
        }
        try assertPage(1, previous: false, next: true, "the passage's first page")
        // Direct input does not turn while the passage is selected; its own controls do.
        canvas.turnPageFromInput(forward: true)
        try assertPage(1, previous: false, next: true, "after a key or swipe")
        press(try XCTUnwrap(continuationControls(canvas)).next)
        try assertPage(2, previous: true, next: true, "a page wholly inside the passage")
        press(try XCTUnwrap(continuationControls(canvas)).next)
        try assertPage(3, previous: true, next: false, "the passage's last page")
        press(try XCTUnwrap(continuationControls(canvas)).previous)
        try assertPage(2, previous: true, next: true, "back")
        press(try XCTUnwrap(continuationControls(canvas)).previous)
        try assertPage(1, previous: false, next: true, "back at its first page")
        canvas.clearSelection()
        XCTAssertNil(continuationControls(canvas))
        canvas.turnPageFromInput(forward: true)
        XCTAssertEqual(canvas.visibleRange?.start.offset, pages[2].range.location, "direct input turns again")
    }

    func testANativeSelectionInOneColumnReplacesTheOtherColumns() async throws {
        let host = host(sections(1, paragraphs: 20), size: CGSize(width: 1100, height: 800))
        let canvas = host.canvas
        let first = canvas.columns[0], second = canvas.columns[1]
        first.selectedRange = NSRange(location: 4, length: 10)
        canvas.textViewSelectionDidChange(first)
        XCTAssertEqual(canvas.currentSelection?.range, ReaderTextRange(section: 0, 4..<14))
        second.selectedRange = NSRange(location: 3, length: 5)
        canvas.textViewSelectionDidChange(second)
        XCTAssertEqual(first.selectedRange.length, 0, "one selection at a time across a spread")
        XCTAssertEqual(second.selectedRange, NSRange(location: 3, length: 5))
        let offset = second.placement.offset
        XCTAssertEqual(canvas.currentSelection?.range, ReaderTextRange(section: 0, (offset + 3)..<(offset + 8)))
        XCTAssertEqual(canvas.currentSelection?.text, second.plainText(in: NSRange(location: 3, length: 5)))
        XCTAssertNil(continuationControls(canvas), "a selection made on the page has nothing offscreen")
        let deadline = Date().addingTimeInterval(20)
        while host.recorder.selections.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(host.recorder.selections.map { $0?.range }, [ReaderTextRange(section: 0, (offset + 3)..<(offset + 8))],
                       "only the selection that settled is reported")
    }

    func testOnlyTheSelectionThatSettlesIsReported() async throws {
        let host = host(sections(1, paragraphs: 20))
        let canvas = host.canvas
        let column = try XCTUnwrap(canvas.textViews.first)
        // A drag passes through many selections; a selection made and dropped at once is none.
        for length in 1...12 {
            column.selectedRange = NSRange(location: 20, length: length)
            canvas.textViewSelectionDidChange(column)
        }
        XCTAssertEqual(canvas.currentSelection?.range, ReaderTextRange(section: 0, 20..<32), "known at once")
        XCTAssertTrue(host.recorder.selections.isEmpty, "reported only once it settles")
        let deadline = Date().addingTimeInterval(20)
        while host.recorder.selections.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(host.recorder.selections.map { $0?.range }, [ReaderTextRange(section: 0, 20..<32)])
        column.selectedRange = NSRange(location: 50, length: 5)
        canvas.textViewSelectionDidChange(column)
        column.selectedRange = NSRange(location: 20, length: 12)
        canvas.textViewSelectionDidChange(column)
        try await host.settle()
        XCTAssertEqual(host.recorder.selections.count, 1, "back at the reported selection: nothing new to say")
        column.selectedRange = NSRange(location: 60, length: 4)
        canvas.textViewSelectionDidChange(column)
        canvas.clearSelection()
        XCTAssertEqual(host.recorder.selections.map { $0?.range }, [ReaderTextRange(section: 0, 20..<32), nil], "cleared at once")
        try await host.settle()
        XCTAssertEqual(host.recorder.selections.count, 2, "the selection dropped before it settled is never reported")
    }

    #if os(macOS)
    /// A canvas filling a window whose title bar (and toolbar, when it has one) lies over its
    /// content view, as a host makes it with `ignoresSafeArea()`.
    private func underTitleBar(flow: EPUBReadingFlow) -> (canvas: ReaderCanvasView, window: NSWindow) {
        let window = makeMacTestWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = ReaderCanvasView(frame: .zero)
        let source = FakeCanvasSource(sections(1, paragraphs: 30))
        canvas.dataSource = source
        canvas.configuration = configuration(flow: flow)
        window.contentView = canvas
        window.orderFront(nil)
        canvas.layoutSubtreeIfNeeded()
        windows.append(window)
        sources.append(source)
        return (canvas, window)
    }

    func testPagesAndScrolledTextKeepClearOfATitleBarOverTheContent() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let (canvas, _) = underTitleBar(flow: flow)
            let inset = canvas.safeAreaInsets.top
            XCTAssertGreaterThan(inset, 10, "the title bar covers the top of the content view")
            XCTAssertEqual(canvas.bounds.size, CGSize(width: 900, height: 700), "which fills the window")
            let asked = ReaderTextPosition(section: 0, offset: 9_000)
            canvas.show(asked, selecting: nil)
            canvas.layoutSubtreeIfNeeded()
            switch flow {
            case .paginated:
                let page = CGRect(x: 0, y: inset, width: canvas.bounds.width, height: canvas.bounds.height - inset)
                XCTAssertEqual(canvas.pageArea, page)
                XCTAssertEqual(canvas.spread, ReaderCanvasGeometry.spread(in: page, division: nil, isRightToLeft: false))
                for column in canvas.textViews {
                    XCTAssertGreaterThanOrEqual(column.frame.minY, inset + 48 - 0.01, "48 points below the title bar")
                    XCTAssertLessThanOrEqual(column.frame.maxY, canvas.bounds.maxY - 48 + 0.5)
                }
                XCTAssertTrue(canvas.textViews.contains { abs($0.frame.minY - (inset + 48)) < 0.01 })
                // The tap zones are the canvas's whole height all the same.
                XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: 10, y: 2)), false)
            case .scrolled:
                let view = try XCTUnwrap(canvas.scrollTextView)
                let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
                XCTAssertEqual(scrollView.frame, canvas.bounds, "the text scrolls under the title bar")
                XCTAssertEqual(scrollView.contentInsets.top, inset, accuracy: 0.5)
                let line = try XCTUnwrap(view.line(containing: asked.offset))
                let top = view.convert(CGPoint(x: 0, y: line.frame.minY + view.containerOrigin.y), to: canvas).y
                XCTAssertEqual(top, inset + 48, accuracy: 1, "the shown position's line rests 48 points below the title bar")
                XCTAssertEqual(canvas.visibleRange?.start.offset, line.range.location)
            }
            let range = try XCTUnwrap(canvas.visibleRange)
            XCTAssertTrue(range.start <= asked && asked < range.end, "\(flow): \(range)")
        }
    }

    /// "A resize, rotation or bar change repaginates once it ends": a toolbar shown over the
    /// reader takes more of its top, and the pages must move out from under it.
    func testPagesMoveClearOfAToolbarShownOverThem() async throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/162")
        let (canvas, window) = underTitleBar(flow: .paginated)
        canvas.show(ReaderTextPosition(section: 0, offset: 9_000), selecting: nil)
        canvas.layoutSubtreeIfNeeded()
        let titleBar = canvas.safeAreaInsets.top
        XCTAssertEqual(try XCTUnwrap(canvas.textViews.first).frame.minY, titleBar + 48, accuracy: 0.01, "clear of the title bar to begin with")
        window.toolbar = NSToolbar(identifier: "org.epublib.tests.view-coverage.shown")
        let deadline = Date().addingTimeInterval(5)
        var bar = canvas.safeAreaInsets.top
        // What every display cycle does: lay out whatever asked for it.
        while Date() < deadline, bar <= titleBar || canvas.textViews.contains(where: { $0.frame.minY < bar + 48 - 0.01 }) {
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
            bar = canvas.safeAreaInsets.top
        }
        XCTAssertGreaterThan(bar, titleBar, "the toolbar covers more of the reader than the title bar did")
        XCTAssertEqual(canvas.bounds.size, CGSize(width: 900, height: 700), "whose size has not changed")
        XCTAssertEqual(canvas.pageArea.minY, bar)
        let top = try XCTUnwrap(canvas.textViews.map(\.frame.minY).min())
        XCTAssertGreaterThanOrEqual(top, bar + 48 - 0.01, "the pages still start \(top) points down: their first lines are under the \(bar)-point bar")
        let range = try XCTUnwrap(canvas.visibleRange)
        XCTAssertTrue(range.start.offset <= 9_000 && 9_000 < range.end.offset, "\(range)")
    }
    #endif

    func testDragPositionsOutsideTheTextResolveToTheNearestColumn() throws {
        for rtl in [false, true] {
            let host = host(sections(1, paragraphs: 20), size: CGSize(width: 1100, height: 800), configuration: configuration(rtl: rtl))
            let canvas = host.canvas, bounds = canvas.bounds
            let first = canvas.columns[0], second = canvas.columns[1]
            let boundary = second.placement.offset
            func offset(_ x: CGFloat, _ y: CGFloat) -> Int? { canvas.selectionPosition(at: CGPoint(x: x, y: y))?.offset }
            let end = try XCTUnwrap(canvas.visibleRange).end.offset
            // Below either column: the end of that column's page.
            XCTAssertEqual(offset(first.frame.midX, bounds.maxY - 2), boundary, "below the first slice, rtl \(rtl)")
            XCTAssertEqual(offset(second.frame.midX, bounds.maxY - 2), end, "below the second slice, rtl \(rtl)")
            // In the gutter the nearer column's edge decides; positions are in source order.
            let gutter = (first.frame.minX < second.frame.minX ? first.frame.maxX + 2 : first.frame.minX - 2)
            let inFirst = try XCTUnwrap(offset(gutter, first.frame.midY))
            XCTAssertTrue((0...boundary).contains(inFirst), "\(inFirst) is on the first slice")
            let nearSecond = (first.frame.minX < second.frame.minX ? second.frame.minX - 2 : second.frame.maxX + 2)
            let inSecond = try XCTUnwrap(offset(nearSecond, second.frame.midY))
            XCTAssertTrue((boundary...end).contains(inSecond), "\(inSecond) is on the second slice")
            XCTAssertNotNil(offset(-500, -500), "far outside: still the nearest column")
        }
        let blank = host([NSAttributedString()])
        XCTAssertNil(blank.canvas.selectionPosition(at: CGPoint(x: 300, y: 300)), "a blank page has no text to select")
    }

    // MARK: Columns on screen

    /// A section of headings, an image, justified and hard-broken paragraphs.
    private func variedSection(size: CGFloat) -> NSAttributedString {
        let justified = CanvasText.bodyStyle(alignment: .justified, hyphenates: true, indent: 24)
        return ViewCoverage.joined([
            CanvasText.heading("Varied chapter one"), CanvasText.body("\n", size: size),
            CanvasText.body(CanvasText.sentence(150, seed: 1) + "\n", size: size),
            CanvasText.heading("A heading inside", breakBefore: false), CanvasText.body("\n", size: size),
            CanvasText.attachment(size: CGSize(width: 160, height: 220)), CanvasText.body("\n", size: size),
            CanvasText.body(CanvasText.sentence(260, seed: 2) + "\n", style: justified, size: size),
            CanvasText.body((0..<60).map { "verse \($0) " + CanvasText.sentence($0 % 4, seed: $0) }.joined(separator: "\u{2028}") + "\n", size: size),
            CanvasText.heading("Varied chapter two"), CanvasText.body("\n", size: size),
            CanvasText.body(CanvasText.sentence(400, seed: 3), style: justified, size: size),
        ])
    }

    func testEveryColumnShowsWholeLinesOfItsPageInsideThePageArea() throws {
        for (size, fontSize) in [(CGSize(width: 600, height: 700), CGFloat(17)), (CGSize(width: 1100, height: 800), 23),
                                 (CGSize(width: 390, height: 520), 31)] {
            let text = variedSection(size: fontSize)
            let host = host([text], size: size)
            let canvas = host.canvas
            let spread = try XCTUnwrap(canvas.spread)
            var shown = "", spreads = 0
            repeat {
                let page = try XCTUnwrap(canvas.shownPage?.page)
                XCTAssertEqual(page % spread.columns.count, 0, "a spread starts on one of its own pages")
                for (slot, column) in canvas.columns.enumerated() where !column.isHidden {
                    let area = spread.columns[slot]
                    let label = "\(size.width) at \(fontSize) pt, page \(page + slot)"
                    let slice = try XCTUnwrap(canvas.paginator(for: 0)?.page(at: page + slot), label)
                    XCTAssertEqual(column.placement, ReaderTextPlacement(section: 0, offset: slice.range.location, visibleLength: slice.range.length), label)
                    XCTAssertEqual(column.frame.minX, area.minX, accuracy: 0.01, label)
                    XCTAssertEqual(column.frame.width, area.width, accuracy: 0.01, label)
                    XCTAssertEqual(column.frame.minY, area.minY + slice.topSpacing, accuracy: 0.01, "\(label): below its top spacing")
                    XCTAssertGreaterThanOrEqual(column.frame.minY, area.minY - 0.01, label)
                    let lines = column.pageAccessibilityLines
                    XCTAssertEqual(lines.first?.range.location, 0, label)
                    let last = try XCTUnwrap(column.line(containing: column.placement.visibleLength - 1), label)
                    XCTAssertEqual(NSMaxRange(last.range), column.placement.visibleLength, "\(label): the page ends with a whole line")
                    if lines.count > 1 {
                        XCTAssertLessThanOrEqual(column.frame.maxY, area.maxY + 0.5, "\(label): the column stays in its page area")
                    }
                    for line in lines {
                        XCTAssertGreaterThanOrEqual(line.frame.minY, -0.5, "\(label): line \(line.range) is cut at the top")
                        XCTAssertLessThanOrEqual(line.frame.maxY, column.frame.height + 0.5, "\(label): line \(line.range) is cut at the bottom")
                    }
                    // What the column lays out past its page is below its frame, out of sight.
                    if column.textLength > column.placement.visibleLength,
                       let hidden = column.lineFrame(containing: column.placement.visibleLength) {
                        XCTAssertGreaterThanOrEqual(hidden.minY, column.frame.height - 0.5, "\(label): the next page's first line shows")
                    }
                    shown += column.visibleText
                }
                spreads += 1
            } while canvas.turnPage(forward: true) == .turned && spreads < 200
            XCTAssertEqual(shown, text.readerPlainText(in: NSRange(location: 0, length: text.length)), "every character once, in order")
        }
    }

    func testFoldingUnfoldingAndMirroringTheReaderKeepsThePosition() throws {
        let host = host(sections(1, paragraphs: 30), size: CGSize(width: 900, height: 700))
        let canvas = host.canvas
        let asked = ReaderTextPosition(section: 0, offset: 9_000)
        canvas.show(asked, selecting: nil)
        func assertShown(columns: Int, _ step: String) throws {
            XCTAssertEqual(canvas.textViews.count, columns, step)
            XCTAssertEqual(canvas.spread, ReaderCanvasGeometry.spread(in: canvas.pageArea, division: canvas.configuration.division,
                                                                      isRightToLeft: canvas.configuration.isRightToLeft), step)
            let range = try XCTUnwrap(canvas.visibleRange)
            XCTAssertTrue(range.start <= asked && asked < range.end, "\(step): \(range)")
            XCTAssertEqual(canvas.anchor, asked, step)
            XCTAssertNil(canvas.pendingSpread, step)
        }
        try assertShown(columns: 2, "flat")
        canvas.configuration.division = CGRect(x: 430, y: 0, width: 40, height: 700)
        try assertShown(columns: 2, "folded at the centre")
        XCTAssertLessThanOrEqual(canvas.columns[0].frame.maxX, 430)
        XCTAssertGreaterThanOrEqual(canvas.columns[1].frame.minX, 470)
        canvas.configuration.division = CGRect(x: 700, y: 0, width: 40, height: 700)
        try assertShown(columns: 1, "folded near the right edge")
        XCTAssertLessThanOrEqual(try XCTUnwrap(canvas.textViews.first).frame.maxX, 700)
        canvas.configuration.isRightToLeft = true
        try assertShown(columns: 1, "mirrored")
        canvas.configuration.division = CGRect(x: 430, y: 0, width: 40, height: 700)
        try assertShown(columns: 2, "mirrored and folded at the centre")
        XCTAssertGreaterThanOrEqual(canvas.columns[0].frame.minX, 470, "the first slice is right of the fold")
        XCTAssertEqual(canvas.columns[1].placement.offset, canvas.columns[0].placement.offset + canvas.columns[0].placement.visibleLength)
        canvas.configuration.division = nil
        canvas.configuration.isRightToLeft = false
        try assertShown(columns: 2, "flat again")
    }

    func testDegenerateCanvasSizesNeitherTrapNorLoseThePosition() throws {
        let image = try ViewCoverage.readerImage(width: 600, height: 900, shownWidth: 300)
        let text = NSMutableAttributedString(attributedString: CanvasText.section(0, chapters: 1, paragraphs: 6))
        text.insert(ViewCoverage.imageText(image), at: 700)
        let asked = ReaderTextPosition(section: 0, offset: 1_200)
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let source = FakeCanvasSource([text])
            if flow == .scrolled { source.book = CanvasText.book([text]) }
            let host = ViewCoverageFrameHost(source, configuration: configuration(flow: flow))
            defer { host.close() }
            let canvas = host.canvas
            host.setFrame(CGRect(x: 0, y: 0, width: 600, height: 700))
            canvas.show(asked, selecting: nil)
            let settled = try XCTUnwrap(canvas.visibleRange, "\(flow)")
            // A pane collapsing to nothing and opening again passes through sizes like these.
            let sizes = [CGSize(width: 50, height: 50), CGSize(width: 600, height: 96), CGSize(width: 600, height: 20),
                         CGSize(width: 12, height: 700), CGSize(width: 1, height: 1), CGSize(width: 0, height: 0),
                         CGSize(width: 0, height: 700), CGSize(width: 2_000, height: 40), CGSize(width: 120, height: 97)]
            for size in sizes {
                host.setFrame(CGRect(origin: .zero, size: size))
                let label = "\(flow) at \(size)"
                XCTAssertEqual(canvas.anchor, asked, label)
                XCTAssertNil(canvas.pendingSpread, label)
                if flow == .paginated, size.width > 0, size.height > 0 {
                    XCTAssertEqual(canvas.spread, ReaderCanvasGeometry.spread(in: canvas.pageArea, division: nil, isRightToLeft: false), label)
                    let range = try XCTUnwrap(canvas.visibleRange, label)
                    XCTAssertTrue(range.start <= asked && asked < range.end, "\(label): \(range)")
                    for column in canvas.textViews {
                        XCTAssertFalse(column.frame.isNull || column.frame.isInfinite || column.frame.width.isNaN || column.frame.height.isNaN, label)
                        XCTAssertGreaterThanOrEqual(column.frame.height, 0, label)
                    }
                }
            }
            host.setFrame(CGRect(x: 0, y: 0, width: 600, height: 700))
            XCTAssertEqual(canvas.visibleRange, settled, "\(flow): back at its size, the reader shows what it showed")
            XCTAssertEqual(canvas.turnPage(forward: false), .turned, "\(flow)")
            XCTAssertLessThan(try XCTUnwrap(canvas.visibleRange?.start), settled.start, "\(flow)")
        }
    }

    // MARK: Release

    func testReleasingContentEmptiesEveryTextViewAndPagination() async throws {
        final class Tracked { weak var attachment: NSTextAttachment? }
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            var tracked: [Tracked] = []
            let source = FakeCanvasSource([])
            let host = CanvasHost(source, size: CGSize(width: 1100, height: 800), configuration: configuration(flow: flow))
            hosts.append(host)
            // In a pool of its own: nothing the test read may be what keeps an image alive.
            autoreleasepool {
                let built: [NSAttributedString] = (0..<3).map { index in
                    let text = NSMutableAttributedString(attributedString: CanvasText.section(index, chapters: 1, paragraphs: 12))
                    for position in [200, 2_000, 4_000] {
                        let image = CanvasText.attachment(size: CGSize(width: 120, height: 60))
                        let entry = Tracked()
                        entry.attachment = image.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
                        tracked.append(entry)
                        text.insert(image, at: position)
                    }
                    return text
                }
                source.sections = built
                source.linear = [true, true, true]
                if flow == .scrolled { source.book = CanvasText.book(built) }
                host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
                host.layOut()
                for _ in 0..<4 { XCTAssertEqual(host.canvas.turnPage(forward: true), .turned) }
                host.resize(to: CGSize(width: 600, height: 700))
                host.canvas.show(ReaderTextPosition(section: 2, offset: 100), selecting: nil)
                XCTAssertTrue(host.canvas.textViews.contains { $0.textLength > 0 })
            }
            XCTAssertEqual(tracked.filter { $0.attachment != nil }.count, 9, "\(flow)")
            // The session closes or the view is dismantled: it lets go of the canvas, which lets go of the text.
            autoreleasepool {
                host.canvas.delegate = nil
                host.canvas.dataSource = nil
                host.canvas.releaseContent()
                source.sections = []
                source.linear = []
                source.book = nil
            }
            XCTAssertEqual(host.canvas.cachedPaginatorCount, 0, "\(flow)")
            XCTAssertEqual(host.canvas.heldPaginatorLayout, 0, "\(flow)")
            XCTAssertNil(host.canvas.scrollBook, "\(flow)")
            XCTAssertNil(host.canvas.pendingSpread, "\(flow)")
            XCTAssertTrue(host.canvas.columns.allSatisfy { $0.textLength == 0 }, "\(flow): every column, hidden ones included")
            XCTAssertEqual(host.canvas.scrollTextView?.textLength ?? 0, 0, "\(flow)")
            let deadline = Date().addingTimeInterval(10)
            while tracked.contains(where: { $0.attachment != nil }), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(tracked.filter { $0.attachment != nil }.count, 0, "\(flow): released text's images are still alive")
        }
    }

    func testAMemoryWarningKeepsOnlyThePaginationOnScreen() throws {
        let host = host(sections(4, paragraphs: 6))
        let canvas = host.canvas
        for section in 0..<4 { canvas.show(ReaderTextPosition(section: section, offset: 300), selecting: nil) }
        host.resize(to: CGSize(width: 1100, height: 800))
        XCTAssertGreaterThanOrEqual(canvas.cachedPaginatorCount, 5)
        let shown = try XCTUnwrap(canvas.visibleRange)
        let kept = try XCTUnwrap(canvas.paginator(for: 3))
        #if os(macOS)
        NotificationCenter.default.post(name: ReaderMemoryPressure.notification, object: nil)
        #else
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        #endif
        XCTAssertEqual(canvas.cachedPaginatorCount, 1)
        XCTAssertTrue(canvas.paginator(for: 3) === kept, "the pagination on screen stays")
        XCTAssertEqual(canvas.visibleRange, shown)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned, "other sections paginate again when turned to")
        XCTAssertEqual(canvas.visibleRange?.end.section, 2)
    }

    // MARK: Deferred layout

    func testLayoutDeferredForADurationRepaginatesOnceWhenItIsOver() async throws {
        let host = host(sections(1, paragraphs: 30))
        let canvas = host.canvas
        canvas.show(ReaderTextPosition(section: 0, offset: 9_000), selecting: nil)
        let spread = canvas.spread, range = canvas.visibleRange
        let reports = host.recorder.shown.count
        canvas.deferLayout(for: 0.05) // A rotation or bar animation of this duration.
        host.resize(to: CGSize(width: 1100, height: 800))
        host.resize(to: CGSize(width: 1000, height: 780))
        XCTAssertEqual(canvas.spread, spread, "the old spread stays on screen")
        XCTAssertEqual(canvas.visibleRange, range)
        XCTAssertNotNil(canvas.pendingSpread)
        let deadline = Date().addingTimeInterval(20)
        while canvas.pendingSpread != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(canvas.pendingSpread)
        XCTAssertEqual(canvas.spread?.columns.count, 2)
        let after = try XCTUnwrap(canvas.visibleRange)
        XCTAssertTrue(after.start.offset <= 9_000 && 9_000 < after.end.offset, "\(after)")
        XCTAssertEqual(host.recorder.shown.count, reports + 1, "repaginated once, at the end")
    }

    #if os(macOS)
    func testALiveWindowResizeKeepsTheSpreadUntilItEnds() throws {
        let host = host(sections(1, paragraphs: 30))
        let canvas = host.canvas
        canvas.show(ReaderTextPosition(section: 0, offset: 9_000), selecting: nil)
        let spread = canvas.spread, range = canvas.visibleRange
        canvas.viewWillStartLiveResize()
        for width in stride(from: CGFloat(640), through: 1120, by: 80) {
            host.resize(to: CGSize(width: width, height: 800))
            XCTAssertEqual(canvas.spread, spread, "\(width)")
            XCTAssertEqual(canvas.visibleRange, range, "\(width)")
        }
        XCTAssertNotNil(canvas.pendingSpread)
        canvas.viewDidEndLiveResize()
        XCTAssertNil(canvas.pendingSpread)
        XCTAssertEqual(canvas.spread?.columns.count, 2)
        let after = try XCTUnwrap(canvas.visibleRange)
        XCTAssertTrue(after.start.offset <= 9_000 && 9_000 < after.end.offset, "\(after)")
        // A resize that ends where it began changes nothing.
        let settled = canvas.spread
        canvas.viewWillStartLiveResize()
        host.resize(to: CGSize(width: 700, height: 800))
        host.resize(to: CGSize(width: 1120, height: 800))
        XCTAssertNil(canvas.pendingSpread)
        canvas.viewDidEndLiveResize()
        XCTAssertEqual(canvas.spread, settled)
    }
    #endif
}
