import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewingTestSupport
import XCTest
@testable import EPUBViewing

@MainActor final class NativeSessionHTMLCFITests: XCTestCase {
    private func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for HTML CFI session") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testOldHTMLRangeRestoresHighlightsAndSelectionKeepsItsCFI() async throws {
        let fixture = HTMLCFIFixtures.fixtures[0]
        let vector = try XCTUnwrap(HTMLCFITests.vectors.documents.first { $0.name == fixture.name })
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/two.xhtml": fixture.markup]))
        var events: [EPUBReaderEvent] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { events.append($0) } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { events.contains(.ready) }
        let value = EPUBCFI.joinIndirections("epubcfi(/6/4)", vector.cfi)
        let old = EPUBLocation(publicationID: publication.id, quote: vector.quote, bookmark: EPUBEngineBookmark(
            engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat, value: value))
        try await session.send(.restore(old))
        try await wait { session.visibleRange?.start.section == 1 }
        try await session.send(.setHighlights([EPUBHighlight(id: "old-range", location: old)]))
        try await wait { session.drawnHighlights.contains { $0.id == "old-range" } }
        let range = try XCTUnwrap(session.drawnHighlights.first { $0.id == "old-range" }?.range)
        let section = try XCTUnwrap(session.book.section(1))
        XCTAssertEqual(section.string.attributedSubstring(from: NSRange(location: range.start.offset, length: range.end.offset - range.start.offset)).string, vector.quote)
        try await session.send(.locate(text: vector.quote, highlight: true))
        try await wait { session.selection?.text == vector.quote }
        let selected = try XCTUnwrap(events.compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let selection) = event { return selection }; return nil
        }.last)
        XCTAssertEqual(selected.location.bookmark?.value, value)
        XCTAssertEqual(selected.location.quote, vector.quote)
        XCTAssertFalse(events.contains { if case .notice = $0 { return true }; return false })
    }

    func testUnqualifiedHTMLRefusesRestoreAndHostHighlightButStillSelectsReadableText() async throws {
        let fixture = try XCTUnwrap(HTMLCFIFixtures.fixtures.first { $0.name == "table-foster-parenting" })
        let vector = try XCTUnwrap(HTMLCFITests.vectors.documents.first { $0.name == fixture.name })
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/two.xhtml": fixture.markup]))
        var events: [EPUBReaderEvent] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { events.append($0) } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { events.contains(.ready) }
        let value = EPUBCFI.joinIndirections("epubcfi(/6/4)", vector.cfi)
        // An unquoted old bookmark must be rejected, rather than trusting coincident indices.
        let old = EPUBLocation(publicationID: publication.id, bookmark: EPUBEngineBookmark(
            engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat, value: value))
        try await session.send(.restore(old))
        XCTAssertEqual(session.visibleRange?.start.section, 0)
        XCTAssertTrue(events.contains(.notice("the saved position could not be found in this book")))
        var bare = old
        bare.bookmark?.value = "epubcfi(/6/4)"
        try await session.send(.restore(bare))
        XCTAssertEqual(session.visibleRange?.start.section, 0, "bare section bookmarks use the same fail-closed contract")
        try await session.send(.setHighlights([EPUBHighlight(id: "ambiguous", location: old)]))
        try await wait { events.contains(.notice("a highlight's passage could not be found in this book: ambiguous")) }
        XCTAssertFalse(session.drawnHighlights.contains { $0.id == "ambiguous" })
        let first = EPUBEngineBookmark(engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat,
                                       value: "epubcfi(/6/2!/4/4,/1:0,/1:7)")
        let mixed = EPUBLocation(publicationID: publication.id, bookmark: first, rangeBookmarks: [first, try XCTUnwrap(old.bookmark)])
        try await session.send(.setHighlights([EPUBHighlight(id: "mixed", location: mixed)]))
        try await wait { events.contains(.notice("a highlight's passage could not be found in this book: mixed")) }
        XCTAssertFalse(session.drawnHighlights.contains { $0.id == "mixed" }, "reject the complete highlight, including the valid first segment")
        try await session.send(.restore(mixed))
        XCTAssertEqual(session.visibleRange?.start.section, 0)
        try await session.send(.locate(text: vector.quote, highlight: true))
        try await wait { session.selection?.text == vector.quote }
        let selected = try XCTUnwrap(events.compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let selection) = event { return selection }; return nil
        }.last)
        XCTAssertNil(selected.location.bookmark)
        XCTAssertNil(selected.location.rangeBookmarks)
        XCTAssertEqual(selected.location.quote, vector.quote)
        XCTAssertTrue(events.contains { event in
            if case .disclosure(let text) = event { return text.contains("original text positions cannot be matched safely") }
            return false
        })
        let section = try XCTUnwrap(session.book.section(1))
        let cross = ReaderTextRange(start: ReaderTextPosition(section: 0, offset: 0),
                                    end: ReaderTextPosition(section: 1, offset: section.string.length))
        session.canvas(try XCTUnwrap(session.canvas), didChangeSelection: ReaderSelection(range: cross, text: ""))
        let crossSelected = try XCTUnwrap(events.compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let selection) = event { return selection }; return nil
        }.last)
        XCTAssertNil(crossSelected.location.bookmark, "do not silently issue the valid first section's CFI")
        XCTAssertNil(crossSelected.location.rangeBookmarks)
    }

    /// A bookmark the session issues inside elements whose IDs hold a TAB and a line separator
    /// is one it restores and highlights (#105). It once asserted both IDs, the second nesting
    /// one `epubcfi(` inside another, and `restore` refused it as `incompatibleLocation`.
    func testABookmarkInsideElementsWithUnassertableIDsRestores() async throws {
        let markup = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body>"
            + "<section id='line&#x2028;separator'><p id='tab&#9;bed'>Before the tabbed passage after.</p></section></body></html>"
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/two.xhtml": markup]))
        var events: [EPUBReaderEvent] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { events.append($0) } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { events.contains(.ready) }
        try await session.send(.locate(text: "tabbed passage", highlight: true))
        try await wait { session.selection?.text == "tabbed passage" }
        let selected = try XCTUnwrap(events.compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let selection) = event { return selection }; return nil
        }.last)
        XCTAssertEqual(selected.location.bookmark?.value, "epubcfi(/6/4!/4/2/2,/1:11,/1:25)")
        try await session.send(.restore(selected.location))
        XCTAssertEqual(session.visibleRange?.start.section, 1)
        try await session.send(.setHighlights([EPUBHighlight(id: "tabbed", location: selected.location)]))
        try await wait { session.drawnHighlights.contains { $0.id == "tabbed" } }
        let range = try XCTUnwrap(session.drawnHighlights.first { $0.id == "tabbed" }?.range)
        let section = try XCTUnwrap(session.book.section(1))
        XCTAssertEqual(section.string.attributedSubstring(from: NSRange(location: range.start.offset, length: range.end.offset - range.start.offset)).string,
                       "tabbed passage")
        XCTAssertFalse(events.contains { if case .notice = $0 { return true }; return false })
    }
}
