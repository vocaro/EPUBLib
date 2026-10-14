import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

#if os(iOS)
@MainActor @Observable private final class HostBars {
    var hidden = false
}

/// A host that runs the reader under its navigation bar and hides the bar, as a reading app
/// does on a tap.
private struct ReaderUnderABar: View {
    let session: any EPUBReaderSession
    let bars: HostBars
    var body: some View {
        NavigationStack {
            EPUBReaderView(session: session)
                .ignoresSafeArea()
                .navigationTitle("An Aligned Book")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(bars.hidden ? .hidden : .visible, for: .navigationBar)
        }
    }
}
#endif

/// The alignment fixture book through the public reader: navigation, location, search,
/// selection, highlights and restoring are the same in both flows as for any other book.
@MainActor final class BoxAlignmentSessionTests: XCTestCase {
    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAlignedSectionsKeepPositionsSelectionsAndHighlightsInBothFlows() async throws {
        let publication = try EPUBPublication.open(data: Fixture.alignment())
        var events: [EPUBReaderEvent] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) {
            events.append($0)
        } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("the whole book") { session.readerState?.status.lifecycle == .ready && session.book.isComplete }
        try await wait("the layout disclosure") {
            events.contains { if case .disclosure(let text) = $0 { return text.contains("flexible box or grid layouts") }; return false }
        }
        let epigraph = try XCTUnwrap(session.book.section(1))
        let quiet = (epigraph.string.string as NSString).range(of: "quiet line")
        var bookmarks: [EPUBReadingFlow: (position: String, selection: String)] = [:]
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            try await session.send(.style(EPUBReaderStyle(fontSize: 17, flow: flow)))
            try await wait("\(flow) book") { session.book.isComplete && session.readerState?.status.style.flow == flow }
            // By href: the section's start, which is the aligned box's.
            try await session.send(.navigate(href: "OPS/epigraph.xhtml"))
            try await wait("\(flow) epigraph") { session.visibleRange?.start == ReaderTextPosition(section: 1, offset: 0) }
            try await wait("\(flow) location") { session.readerState?.status.location?.href == "OPS/epigraph.xhtml" }
            let shown = try XCTUnwrap(session.readerState?.status.location)
            let position = try XCTUnwrap(shown.bookmark?.value)
            XCTAssertTrue(position.hasPrefix("epubcfi(/6/4!"), position)
            // The passage is found where it is in the document, and selected.
            let before = events.count
            try await session.send(.locate(text: "quiet line", highlight: true))
            try await wait("\(flow) selection") {
                events.dropFirst(before).contains { if case .selectionChanged(let value) = $0 { return value?.text == "quiet line" }; return false }
            }
            let selection = try XCTUnwrap(events.dropFirst(before).compactMap { event -> EPUBSelection? in
                if case .selectionChanged(let value) = event { return value }; return nil
            }.last)
            XCTAssertEqual(session.canvas?.currentSelection?.range, ReaderTextRange(section: 1, quiet.location..<quiet.upperBound))
            bookmarks[flow] = (position, try XCTUnwrap(selection.location.bookmark?.value))
            // The selection saved as a highlight draws at the same characters.
            try await session.send(.setHighlights([EPUBHighlight(id: "saved", location: selection.location)]))
            XCTAssertEqual(session.drawnHighlights.filter { $0.kind == .annotation }.map(\.range),
                           [ReaderTextRange(section: 1, quiet.location..<quiet.upperBound)])
            // Away and back by the saved position.
            try await session.send(.navigate(href: "OPS/chapter.xhtml"))
            try await wait("\(flow) chapter") { session.visibleRange?.start.section == 4 }
            try await session.send(.restore(shown))
            try await wait("\(flow) restored") { session.visibleRange?.start == ReaderTextPosition(section: 1, offset: 0) }
            // Page turns step through the aligned sections one at a time.
            try await session.send(.navigate(href: "OPS/titlepage.xhtml"))
            try await wait("\(flow) title") { session.visibleRange?.start == ReaderTextPosition(section: 0, offset: 0) }
            XCTAssertFalse(events.contains { if case .notice = $0 { return true }; return false }, "\(events)")
        }
        XCTAssertEqual(bookmarks[.paginated]?.position, bookmarks[.scrolled]?.position, "a position's CFI does not depend on the flow")
        XCTAssertEqual(bookmarks[.paginated]?.selection, bookmarks[.scrolled]?.selection)
    }

    /// Previous Page leaves the position at the end of the section turned back to. In the
    /// reader's own book text that is the break the book puts after the section, and changing
    /// to continuous scroll there must still show the one-page box whole.
    func testChangingToContinuousScrollOnAPageTurnedBackToShowsItsBoxAsComposed() async throws {
        let publication = try EPUBPublication.open(data: Fixture.alignment())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("the whole book") { session.readerState?.status.lifecycle == .ready && session.book.isComplete }
        try await session.send(.style(EPUBReaderStyle(fontSize: 17, flow: .paginated)))
        try await wait("pages") { session.book.isComplete && session.readerState?.status.style.flow == .paginated }
        // Back from the section after the dedication, over the dedication, to the epigraph.
        try await session.send(.navigate(href: "OPS/layouts.xhtml"))
        try await wait("the section after the dedication") { session.visibleRange?.start.section == 3 }
        for section in [2, 1] {
            try await session.send(.previousPage)
            try await wait("section \(section)") { session.visibleRange?.start.section == section }
        }
        let length = try XCTUnwrap(session.book.section(1)).string.length
        XCTAssertEqual(session.canvas?.anchor, ReaderTextPosition(section: 1, offset: length), "the section's end")
        try await session.send(.style(EPUBReaderStyle(fontSize: 17, flow: .scrolled)))
        try await wait("continuous scroll") { session.readerState?.status.style.flow == .scrolled && session.canvas?.scrollBook != nil }
        try await wait("the epigraph from its start") { session.visibleRange?.start == ReaderTextPosition(section: 1, offset: 0) }
        let canvas = try XCTUnwrap(session.canvas), view = try XCTUnwrap(canvas.scrollTextView), book = try XCTUnwrap(canvas.scrollBook)
        let start = book.location(of: ReaderTextPosition(section: 1, offset: 0))
        let lead = ReaderAlignmentLayout.lead(in: try XCTUnwrap(view.contentStorage.textStorage), at: start)
        XCTAssertGreaterThan(lead, 100, "the epigraph has space above its first line")
        let visible = canvas.scrollVisibleContainerRect
        let first = try XCTUnwrap(view.lineFrame(containing: start))
        let last = try XCTUnwrap(view.lineFrame(containing: book.location(of: ReaderTextPosition(section: 1, offset: length - 1))))
        XCTAssertEqual(first.minY - lead, visible.minY, accuracy: 1.5, "the box's top edge is at the top of the visible area")
        XCTAssertEqual((first.minY + last.maxY) / 2 - visible.minY, 0.49 * visible.height, accuracy: 2.5, "its lines are in the middle")
        XCTAssertEqual(session.readerState?.status.location?.href, "OPS/epigraph.xhtml")
    }

    /// A host that runs the reader under its bars changes the height of the reading area, and
    /// not the reader's size, when a bar comes or goes: the navigation bar of a
    /// `NavigationStack` on iOS, and on the Mac a window's toolbar over a full-size content
    /// view. There nothing lays the reader out for the bar (#162), and its next change of
    /// appearance does. The epigraph stood 81 points low on an iPhone while the bar was hidden,
    /// and on the Mac the reader showed and reported the dedication, then the chapter (#338).
    func testABarOverTheReaderKeepsTheEpigraphShownAndReportedInContinuousScroll() async throws {
        let publication = try EPUBPublication.open(data: Fixture.alignment())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        #if os(macOS)
        let window = makeMacTestWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.keepLightAppearance()
        window.contentView = NSHostingView(rootView: EPUBReaderView(session: session).ignoresSafeArea())
        window.setContentSize(CGSize(width: 500, height: 700))
        window.orderFront(nil)
        defer { session.close(); window.close(); window.contentView = nil }
        #else
        let bars = HostBars()
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.keepLightAppearance()
        window.rootViewController = UIHostingController(rootView: ReaderUnderABar(session: session, bars: bars))
        window.makeKeyAndVisible()
        defer { session.close(); window.isHidden = true; window.rootViewController = nil }
        #endif
        try await wait("the whole book") { session.readerState?.status.lifecycle == .ready && session.book.isComplete }
        var style = EPUBReaderStyle(fontSize: 17, appearance: .light, flow: .scrolled)
        try await session.send(.style(style))
        try await wait("continuous scroll") { session.book.isComplete && session.canvas?.scrollBook != nil }
        // The title page first, so that the text above the epigraph is laid out.
        try await session.send(.navigate(href: "OPS/titlepage.xhtml"))
        try await wait("the title page") { session.visibleRange?.start == ReaderTextPosition(section: 0, offset: 0) }
        let epigraph = ReaderTextPosition(section: 1, offset: 0)
        try await session.send(.navigate(href: "OPS/epigraph.xhtml"))
        try await wait("the epigraph") { session.visibleRange?.start == epigraph }
        let canvas = try XCTUnwrap(session.canvas)
        /// How far the epigraph's top edge is below the top of the visible area.
        func boxTop() throws -> CGFloat {
            let view = try XCTUnwrap(canvas.scrollTextView), location = try XCTUnwrap(canvas.scrollBook).location(of: epigraph)
            let line = try XCTUnwrap(view.lineFrame(containing: location))
            return view.anchorFrame(of: line, at: location).minY - canvas.scrollVisibleContainerRect.minY
        }
        XCTAssertEqual(try boxTop(), 0, accuracy: 1.5, "shown")
        XCTAssertGreaterThan(canvas.safeAreaInsets.top, 10, "the reader runs under the bar")
        let size = canvas.bounds.size
        for change in 1...4 {
            let before = canvas.scrollVisibleContainerRect.height
            #if os(macOS)
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "org.epublib.tests.alignment-session.\(UUID().uuidString)")
            } else { window.toolbar?.isVisible.toggle() }
            try await wait("the insets after change \(change)") { abs(canvas.scrollVisibleContainerRect.height - before) > 20 }
            style.appearance = style.appearance == .dark ? .light : .dark
            try await session.send(.style(style))
            try await wait("the appearance after change \(change)") {
                guard session.book.isComplete, let view = canvas.scrollTextView else { return false }
                return abs(view.readerContainer.viewportSize.height - canvas.scrollVisibleContainerRect.height) < 0.5
            }
            #else
            bars.hidden.toggle()
            try await wait("the bar after change \(change)") { abs(canvas.scrollVisibleContainerRect.height - before) > 20 }
            #endif
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(canvas.bounds.size, size, "the reader keeps its size, change \(change)")
            XCTAssertEqual(try boxTop(), 0, accuracy: 1.5, "the epigraph's top edge after \(change) change(s) of the bar")
            XCTAssertEqual(session.visibleRange?.start, epigraph, "after \(change) change(s)")
            XCTAssertEqual(session.readerState?.status.location?.href, "OPS/epigraph.xhtml", "after \(change) change(s)")
        }
    }
}
