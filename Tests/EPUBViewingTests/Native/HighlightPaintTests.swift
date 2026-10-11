import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

/// Search and host highlights as the mounted reader actually paints them
/// ([#51](https://github.com/vocaro/EPUBLib/issues/51)): a highlight that was drawn must leave
/// the page when it is cleared, and one that is added must appear, without a reflow.
///
/// `drawnHighlights` and the rendering attributes say what the reader was asked to draw. These
/// tests read the pixels its views last painted (`ReaderPaintRecorder`), which is what stays on
/// screen: TextKit 2 keeps each laid-out fragment's drawing until something invalidates it.
@MainActor final class HighlightPaintTests: XCTestCase {
    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private final class Events {
        var all: [EPUBReaderEvent] = []
        var lastSelection: EPUBSelection? {
            all.compactMap { event -> EPUBSelection? in
                if case .selectionChanged(let value) = event { return value }
                return nil
            }.last
        }
    }

    /// A mounted reader and the recording of what it paints.
    @MainActor private struct Reader {
        let session: NativeSession
        let events: Events
        let window: ReaderTestWindow
        let canvas: ReaderCanvasView
        let recorder: ReaderPaintRecorder
        let dark: Bool
        var background: PlatformColor { ReaderPalette.background(dark: dark) }
        var painted: ReaderPaintBitmap { recorder.bitmap(background: background) }
        var searchPixels: Int { painted.count(of: ReaderPalette.searchHighlight(dark: dark), over: background) }
        var annotationPixels: Int { painted.count(of: ReaderPalette.annotationHighlight(dark: dark), over: background) }
        var inkPixels: Int { painted.ink(over: background) }

        /// Lets the system paint what it has scheduled until `condition` holds. Nothing is
        /// invalidated here: a surface the reader left alone stays as it was.
        func paint(timeout: TimeInterval, until condition: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                recorder.flush()
                if condition() { return true }
                guard Date() < deadline else { return false }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// AppKit's text checking visits a text view about a second after its text is set and
        /// redraws its fragments as it annotates them. Landing after a change under test, that
        /// would repaint a surface the reader had failed to invalidate, so these readers go
        /// unchecked. A flow keeps its text views across navigation; a table's cells are new.
        /// Called only before a change under test, never between it and its check.
        func stopTextChecking() {
            #if os(macOS)
            func visit(_ view: NSView) {
                (view as? NSTextView)?.enabledTextCheckingTypes = 0
                view.subviews.forEach(visit)
            }
            visit(canvas)
            #endif
        }

        /// Waits until the system has painted everything it had pending, so that a later
        /// repaint can only come from what the test does next.
        func quiesce() async throws {
            stopTextChecking()
            var draws = -1, rounds = 0
            while draws != recorder.draws, rounds < 30 {
                draws = recorder.draws
                rounds += 1
                for _ in 0..<15 {
                    recorder.flush()
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            XCTAssertEqual(draws, recorder.draws, "the reader never stopped painting")
        }

        /// The text views and what they show: a repaint must not come from new text views, a
        /// page turn or a scroll.
        var placement: [String] {
            canvas.textViews.map { "\(ObjectIdentifier($0)) \($0.placement.offset) \($0.textLength)" }
                + [String(describing: session.visibleRange)]
        }

        func close() {
            recorder.stop()
            session.close()
            window.close()
        }
    }

    /// A mounted reader showing its opening page, every view recorded once.
    private func open(_ data: Data, flow: EPUBReadingFlow, size: CGSize? = nil, dark: Bool = false) async throws -> Reader {
        let publication = try EPUBPublication.open(data: data)
        let events = Events()
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) {
            events.all.append($0)
        } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        if let size { window.resize(to: size) }
        try await wait("the reader") { session.isReady && session.book.isComplete && session.lastLocation != nil }
        try await session.send(.style(.init(appearance: dark ? .dark : .light, flow: flow)))
        try await wait("the styled book") {
            session.book.isComplete && session.book.typography.isDark == dark && session.canvas?.configuration.flow == flow
                && !(session.canvas?.textViews.isEmpty ?? true)
        }
        let canvas = try XCTUnwrap(session.canvas)
        let recorder = ReaderPaintRecorder(root: canvas)
        let reader = Reader(session: session, events: events, window: window, canvas: canvas, recorder: recorder, dark: dark)
        reader.stopTextChecking()
        recorder.synchronize()
        let painted = try await reader.paint(timeout: 10) { reader.inkPixels > 0 }
        XCTAssertTrue(painted, "the opening page was never painted")
        try await reader.quiesce()
        return reader
    }

    private func chapter(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Second Chapter</title></head><body>\(body)</body></html>"
    }

    /// A second chapter whose every paragraph holds the searched word, so each column of a
    /// spread and each screen of continuous scroll shows a match. Nothing in the book is yellow.
    private var kernels: String {
        chapter("<h1>Second Chapter</h1>" + (1...60).map {
            "<p>Paragraph \($0) says popcorn kernels burst in the pan while the reader turns its pages.</p>"
        }.joined())
    }

    /// With `EPUBLIB_PAINT_DIR` set, keeps each step's picture there and prints its counts, for
    /// looking at a failure.
    private func keep(_ reader: Reader, _ label: String) {
        guard let directory = ProcessInfo.processInfo.environment["EPUBLIB_PAINT_DIR"] else { return }
        print("PAINT \(label): ink=\(reader.inkPixels) search=\(reader.searchPixels) annotation=\(reader.annotationPixels)")
        reader.painted.writePNG(to: URL(fileURLWithPath: directory).appendingPathComponent("\(label).png"))
    }

    // MARK: Toolbar search

    private func exerciseToolbarSearch(flow: EPUBReadingFlow, size: CGSize? = nil, columns: Int, dark: Bool = false) async throws {
        let reader = try await open(Fixture.epub(overrides: ["OPS/two.xhtml": kernels]), flow: flow, size: size, dark: dark)
        defer { reader.close() }
        let label = "\(flow) \(Int(reader.canvas.bounds.width))x\(Int(reader.canvas.bounds.height))\(dark ? " dark" : "")"
        XCTAssertEqual(reader.canvas.textViews.count, columns, label)
        keep(reader, "\(label) open")
        XCTAssertEqual(reader.searchPixels, 0, "\(label): the book has no highlight-coloured pixels of its own")

        // The toolbar's own path: the field's text, Return, then Clear Search.
        let controls = EPUBReaderControls(publication: reader.session.publication, session: reader.session)
        controls.searchText = "kernels"
        controls.submitSearch()
        await controls.waitForCommands()
        XCTAssertEqual(reader.session.readerState?.status.search, .completed(query: "kernels", hasMatches: true), label)
        let found = try await reader.paint(timeout: 10) { reader.searchPixels > 0 }
        XCTAssertTrue(found, "\(label): the submitted search painted no match")
        try await reader.quiesce()
        let searched = reader.searchPixels
        XCTAssertGreaterThan(searched, 0, label)
        XCTAssertEqual(reader.canvas.textViews.count, columns, label)
        if columns == 2 { // A match in each column of the spread.
            let half = CGRect(x: 0, y: 0, width: reader.canvas.bounds.midX, height: reader.canvas.bounds.height)
            let left = reader.painted.count(of: ReaderPalette.searchHighlight(dark: dark), over: reader.background, in: half)
            XCTAssertGreaterThan(left, 0, label)
            XCTAssertGreaterThan(searched - left, 0, label)
        }
        keep(reader, "\(label) found")

        let shown = reader.placement
        controls.clearSearch()
        await controls.waitForCommands()
        XCTAssertEqual(controls.searchText, "", label)
        XCTAssertEqual(reader.session.readerState?.status.search, .idle, label)
        XCTAssertTrue(reader.session.drawnHighlights.isEmpty, label)
        let cleared = try await reader.paint(timeout: 5) { reader.searchPixels == 0 }
        keep(reader, "\(label) cleared")
        XCTAssertTrue(cleared, "\(label): \(reader.searchPixels) of \(searched) highlight pixels stayed painted after Clear Search")
        XCTAssertGreaterThan(reader.inkPixels, 0, "\(label): the page itself stays painted")
        XCTAssertEqual(reader.placement, shown, "\(label): Clear Search repaints in place, without a reflow")
    }

    func testClearSearchRepaintsAPaginatedPage() async throws {
        #if os(macOS)
        try await exerciseToolbarSearch(flow: .paginated, size: CGSize(width: 600, height: 700), columns: 1)
        #else
        try await exerciseToolbarSearch(flow: .paginated, size: CGSize(width: 390, height: 844), columns: 1)
        #endif
    }

    func testClearSearchRepaintsBothColumnsOfASpread() async throws {
        try await exerciseToolbarSearch(flow: .paginated, size: CGSize(width: 1100, height: 700), columns: 2)
    }

    func testClearSearchRepaintsContinuousScroll() async throws {
        try await exerciseToolbarSearch(flow: .scrolled, columns: 1)
    }

    func testClearSearchRepaintsInDarkAppearance() async throws {
        try await exerciseToolbarSearch(flow: .paginated, columns: 1, dark: true)
    }

    // MARK: Highlights added and removed in place

    /// A highlight-only search and a host highlight change what a page shows without moving
    /// it, so nothing else repaints the text.
    private func exerciseHighlightsInPlace(flow: EPUBReadingFlow) async throws {
        let reader = try await open(Fixture.epub(), flow: flow)
        defer { reader.close() }
        let session = reader.session
        XCTAssertEqual(reader.searchPixels, 0, "\(flow)")
        XCTAssertEqual(reader.annotationPixels, 0, "\(flow)")
        let shown = reader.placement

        try await session.send(.searchHighlight(text: "ordinary reading"))
        XCTAssertEqual(reader.placement, shown, "\(flow): a highlight-only search does not move the page")
        let found = try await reader.paint(timeout: 5) { reader.searchPixels > 0 }
        keep(reader, "\(flow) highlight-only")
        XCTAssertTrue(found, "\(flow): matches on the page shown were not painted")
        try await reader.quiesce()
        try await session.send(.clearSearch)
        let cleared = try await reader.paint(timeout: 5) { reader.searchPixels == 0 }
        XCTAssertTrue(cleared, "\(flow): \(reader.searchPixels) highlight pixels stayed painted after clearSearch")

        // A host highlight over the opening sentence, from the CFI its selection reports.
        try await session.send(.locate(text: "Opening words are visible.", highlight: true))
        try await wait("the selection") { session.selection != nil && reader.events.lastSelection != nil }
        let passage = try XCTUnwrap(session.selection?.range)
        let location = try XCTUnwrap(reader.events.lastSelection?.location)
        reader.canvas.clearSelection()
        try await reader.quiesce()
        XCTAssertEqual(reader.annotationPixels, 0, "\(flow)")
        let placed = reader.placement
        try await session.send(.setHighlights([EPUBHighlight(id: "note", location: location)]))
        XCTAssertEqual(session.drawnHighlights.map(\.range), [passage], "\(flow)")
        let annotated = try await reader.paint(timeout: 5) { reader.annotationPixels > 0 }
        keep(reader, "\(flow) annotation")
        XCTAssertTrue(annotated, "\(flow): the host highlight was not painted")
        try await reader.quiesce()
        try await session.send(.setHighlights([]))
        let removed = try await reader.paint(timeout: 5) { reader.annotationPixels == 0 }
        XCTAssertTrue(removed, "\(flow): \(reader.annotationPixels) highlight pixels stayed painted after setHighlights([])")
        XCTAssertGreaterThan(reader.inkPixels, 0, "\(flow)")
        XCTAssertEqual(reader.placement, placed, "\(flow): highlights repaint in place")
    }

    func testHighlightsAppearAndDisappearInPlaceWhenPaginated() async throws {
        try await exerciseHighlightsInPlace(flow: .paginated)
    }

    func testHighlightsAppearAndDisappearInPlaceWhenScrolled() async throws {
        try await exerciseHighlightsInPlace(flow: .scrolled)
    }

    // MARK: Table cells

    /// Cell text is drawn by the table's own text views, over the row's ink.
    func testClearSearchRepaintsTableCells() async throws {
        let table = chapter("""
        <h1>Second Chapter</h1><p>Plain words before the table.</p>
        <table><tr><td>Popcorn kernels here</td><td>Nothing to find</td></tr>
        <tr><td>Plain cell</td><td>More kernels in this cell</td></tr></table>
        <p>Plain words after the table.</p>
        """)
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try await open(Fixture.epub(overrides: ["OPS/two.xhtml": table]), flow: flow)
            defer { reader.close() }
            XCTAssertEqual(reader.searchPixels, 0, "\(flow)")
            let controls = EPUBReaderControls(publication: reader.session.publication, session: reader.session)
            controls.searchText = "kernels"
            controls.submitSearch()
            await controls.waitForCommands()
            XCTAssertEqual(reader.session.drawnHighlights.filter { $0.range.start.tableCell != nil }.count, 2, "\(flow)")
            let found = try await reader.paint(timeout: 10) { reader.searchPixels > 0 }
            keep(reader, "\(flow) table found")
            XCTAssertTrue(found, "\(flow): the cell matches were not painted")
            try await reader.quiesce()
            controls.clearSearch()
            await controls.waitForCommands()
            let cleared = try await reader.paint(timeout: 5) { reader.searchPixels == 0 }
            XCTAssertTrue(cleared, "\(flow): \(reader.searchPixels) highlight pixels stayed painted in table cells")
            XCTAssertGreaterThan(reader.inkPixels, 0, "\(flow)")
        }
    }
}
