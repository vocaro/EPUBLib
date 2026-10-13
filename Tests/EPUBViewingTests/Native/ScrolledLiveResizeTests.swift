#if os(macOS)
import AppKit
import EPUBCore
import EPUBReading
import XCTest
@testable import EPUBViewing

/// What a live resize of its window leaves on screen in continuous scroll on the Mac
/// (doc/native-viewer.md "Continuous scroll"). AppKit's text view scrolls itself when a live
/// resize ends, and the reader puts the view back (`ReaderTextView.viewDidEndLiveResize`).
///
/// The window is resized as AppKit resizes one live: `setFrame(_:display:animate:)` tells
/// every view that a live resize starts, takes the window through the sizes between, and tells
/// every view that the resize has ended, as a drag of the window's edge does. No mouse is
/// driven, and each test checks that its window went through a live resize.
@MainActor final class ScrolledLiveResizeTests: XCTestCase {
    private var hosts: [CanvasHost] = []
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    /// Counts the live resizes its window goes through.
    private final class LiveResizeWitness: NSView {
        var started = 0, ended = 0
        override func viewWillStartLiveResize() { super.viewWillStartLiveResize(); started += 1 }
        override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); ended += 1 }
    }

    /// Takes `window` through one live resize to a content area of `size`.
    private func liveResize(_ window: NSWindow, to size: CGSize, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(window.contentView, file: file, line: line)
        let witness = LiveResizeWitness(frame: .zero)
        content.addSubview(witness)
        defer { witness.removeFromSuperview() }
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = window.frame.origin
        window.setFrame(frame, display: true, animate: true)
        content.layoutSubtreeIfNeeded()
        try XCTSkipIf(witness.started == 0, "AppKit resized the window to \(size) without a live resize", file: file, line: line)
        XCTAssertEqual([witness.started, witness.ended], [1, 1], "the window went through one live resize to \(size)", file: file, line: line)
        XCTAssertEqual(content.frame.size, size, file: file, line: line)
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

    /// A book of three sections in continuous scroll, at its top, under scroll bars of one kind
    /// (a change of kind lays the text out again, which is not what is tested here).
    private func scrolledHost(_ bars: CanvasScrollBars = .overlay, underBars: Bool = false) throws -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        let sections = [prose(0, length: 40_000), prose(1, length: 80_000), prose(2, length: 40_000)]
        let source = FakeCanvasSource(sections)
        source.book = CanvasText.book(sections)
        let host = CanvasHost(source, configuration: configuration, underBars: underBars)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        try host.setScrollBars(bars)
        return host
    }

    /// Where the text stands on screen: the line at the top of the visible area, and how far
    /// that line's top is below the area's. Not the scroll offset, which is a distance through
    /// the whole text: TextKit 2 estimates the height of what it has not laid out, and the
    /// offset of a line that has not moved on screen changes whenever it estimates again.
    private func place(_ canvas: ReaderCanvasView, file: StaticString = #filePath, line: UInt = #line) throws
        -> (first: NSRange, below: CGFloat) {
        let view = try XCTUnwrap(canvas.scrollTextView, file: file, line: line)
        let top = canvas.scrollVisibleContainerRect.minY
        let start = view.firstShownLine(from: view.lineBoundary(atContainerY: top, lineEnd: false))
        let first = try XCTUnwrap(view.line(containing: start), file: file, line: line)
        return (first.range, first.frame.minY - top)
    }

    private func location(of position: ReaderTextPosition, in canvas: ReaderCanvasView) -> Int {
        canvas.scrollBook?.location(of: position) ?? position.offset
    }

    /// The line holding `position` is the first on screen, at the top of the visible area, the
    /// reader reports it as the visible start, and VoiceOver would enter at it.
    private func assertFirstOnScreen(_ position: ReaderTextPosition, _ canvas: ReaderCanvasView, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(canvas.scrollTextView, file: file, line: line)
        let target = location(of: position, in: canvas)
        let kept = try XCTUnwrap(view.line(containing: target), label, file: file, line: line)
        let stands = try place(canvas, file: file, line: line)
        let text = try XCTUnwrap(view.contentStorage.textStorage, file: file, line: line).string as NSString
        func words(_ range: NSRange) -> String { text.substring(with: NSRange(location: range.location, length: min(24, range.length))) }
        XCTAssertEqual(stands.first, kept.range, "\(label): the first line on screen begins \"\(words(stands.first))\", and the line that "
                       + "was there, \"\(words(kept.range))\", is \(Int(kept.frame.minY - canvas.scrollVisibleContainerRect.minY)) points below the top",
                       file: file, line: line)
        XCTAssertEqual(stands.below, 0, accuracy: 1, "\(label): the line's top is the visible top", file: file, line: line)
        XCTAssertEqual(canvas.visibleRange.map { location(of: $0.start, in: canvas) }, kept.range.location, "\(label): reported as the visible start",
                       file: file, line: line)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: kept.range.location, length: 0),
                       "\(label): VoiceOver would enter at the line", file: file, line: line)
    }

    private let sizes = [CGSize(width: 500, height: 700), CGSize(width: 500, height: 560), CGSize(width: 640, height: 700)]

    /// The fault as it was first seen: a reader at the top of its book, resized, stood 48 points
    /// down with the title above the screen, and VoiceOver entered at the second line.
    func testALiveResizeAtTheTopOfTheBookLeavesItsFirstLineAtTheTop() async throws {
        for (bars, underBars) in [(CanvasScrollBars.overlay, false), (.legacy, false), (.overlay, true)] {
            let host = try scrolledHost(bars, underBars: underBars)
            let canvas = host.canvas, start = ReaderTextPosition(section: 0, offset: 0)
            if underBars { try await host.setBar(shown: true) }
            try await host.settle()
            let label = "\(bars)\(underBars ? " under a toolbar" : "")"
            try assertFirstOnScreen(start, canvas, "\(label), opened")
            XCTAssertTrue(canvas.isScrolledToStart, label)
            for size in sizes {
                try liveResize(host.window, to: size)
                try assertFirstOnScreen(start, canvas, "\(label), resized to \(size)")
                XCTAssertTrue(canvas.isScrolledToStart, "\(label), resized to \(size): the view is at the top of the book")
                try await host.settle()
                try assertFirstOnScreen(start, canvas, "\(label), a moment after the resize to \(size)")
                XCTAssertEqual(canvas.anchor, start, "\(label), \(size): the reader keeps the book's start")
            }
        }
    }

    /// Away from the top the text went back to the start of a paragraph at every resize.
    func testALiveResizeInTheMiddleOfTheBookKeepsTheShownPositionsLineAtTheTop() async throws {
        for bars in CanvasScrollBars.allCases {
            let host = try scrolledHost(bars)
            let canvas = host.canvas, position = ReaderTextPosition(section: 1, offset: 41_234)
            canvas.show(position, selecting: nil)
            try await host.settle()
            try assertFirstOnScreen(position, canvas, "\(bars), shown")
            for size in sizes {
                try liveResize(host.window, to: size)
                try assertFirstOnScreen(position, canvas, "\(bars), resized to \(size)")
                try await host.settle()
                try assertFirstOnScreen(position, canvas, "\(bars), a moment after the resize to \(size)")
                XCTAssertEqual(canvas.anchor, position, "\(bars), \(size): no drift to another line")
            }
        }
    }

    /// Scrolls as a trackpad or a scroller does, and waits for the reader to report the place.
    private func scrollByHand(to offset: CGFloat, _ host: CanvasHost) async throws -> ReaderTextPosition {
        let scrollView = try XCTUnwrap(host.canvas.scrollContainer as? NSScrollView)
        let before = host.canvas.visibleRange
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let deadline = Date().addingTimeInterval(20)
        while host.canvas.visibleRange == before, Date() < deadline { try await host.settle(20) }
        return try XCTUnwrap(host.canvas.visibleRange?.start)
    }

    /// "A resize keeps the line holding the position (the last one shown, or the visible start
    /// once the person has scrolled) at the top."
    func testALiveResizeAfterThePersonScrolledKeepsTheVisibleStart() async throws {
        let host = try scrolledHost()
        let canvas = host.canvas
        let reading = try await scrollByHand(to: 9_010, host)
        XCTAssertGreaterThan(reading.offset, 10_000)
        for size in sizes {
            try liveResize(host.window, to: size)
            try assertFirstOnScreen(reading, canvas, "resized to \(size)")
            try await host.settle()
            try assertFirstOnScreen(reading, canvas, "a moment after the resize to \(size)")
        }
    }

    /// A reader in a pane that keeps its size is told of its window's live resize all the same.
    /// Nothing is laid out, so nothing may move: the text stays where the person scrolled it
    /// to, with a line cut by the top edge, and the reader goes on keeping what is on screen.
    func testALiveResizeThatLeavesTheReadersSizeAloneMovesNothing() async throws {
        let host = try scrolledHost()
        let canvas = host.canvas
        let pane = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
        host.window.contentView = pane
        canvas.autoresizingMask = []
        canvas.frame = pane.bounds
        pane.addSubview(canvas)
        host.layOut()
        let reading = try await scrollByHand(to: 9_010, host)
        let before = try place(canvas)
        XCTAssertGreaterThan(abs(before.below), 2, "the first line is not at the top edge: it stands \(before.below) points from it")
        for size in [CGSize(width: 720, height: 760), CGSize(width: 600, height: 700)] {
            try liveResize(host.window, to: size)
            XCTAssertEqual(canvas.frame.size, CGSize(width: 600, height: 700))
            for label in ["resized to \(size)", "a moment after the resize to \(size)"] {
                let after = try place(canvas)
                XCTAssertEqual(after.first, before.first, "\(label): the same line is first on screen")
                XCTAssertEqual(after.below, before.below, accuracy: 0.5, "\(label): and it has not moved")
                XCTAssertEqual(canvas.visibleRange?.start, reading, label)
                try await host.settle()
            }
        }
        // The reader still keeps what the person scrolled to, and not the position shown before.
        canvas.frame.size = CGSize(width: 480, height: 700)
        host.layOut()
        try assertFirstOnScreen(reading, canvas, "the pane made narrower")
    }

    /// The public reader, in the window a host gives it: VoiceOver enters a Mac text view at its
    /// insertion point, which followed the text view's own scroll to the second line.
    func testVoiceOverWouldEnterAtTheBooksFirstLineAfterALiveResize() async throws {
        let reader = try SessionCoverageReader(try SessionCoverageBook.chapters())
        readers.append(reader)
        let canvas = try XCTUnwrap(reader.session.canvas)
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { canvas.scrollBook != nil }
        try await reader.settle()
        let view = try XCTUnwrap(canvas.scrollTextView)
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
        func entryLine() -> String {
            let line = view.accessibilityRange(forLine: view.accessibilityInsertionPointLineNumber())
            return (view.accessibilityString(for: line) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(entryLine(), "First Chapter")
        for size in sizes {
            try liveResize(try XCTUnwrap(reader.window).window, to: size)
            for label in ["resized to \(size)", "a moment after the resize to \(size)"] {
                XCTAssertEqual(scrollView.contentView.bounds.minY, -scrollView.contentInsets.top, accuracy: 0.5, "\(label): the view is at the top of the book")
                XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0), label)
                XCTAssertEqual(entryLine(), "First Chapter", label)
                XCTAssertEqual(reader.session.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0), label)
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
#endif
