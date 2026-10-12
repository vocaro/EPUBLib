import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing

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
}
