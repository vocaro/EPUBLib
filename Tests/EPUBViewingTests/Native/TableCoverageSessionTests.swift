import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tables through the public commands of a mounted session: bookmarks, highlights and selections
/// that name a whole table, a cell range, or both a cell and the prose around the table.
@MainActor final class TableCoverageSessionTests: XCTestCase {
    private func chapter(_ body: String) -> String {
        "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head><title>Tables</title></head><body>\(body)</body></html>"
    }

    private let table = """
    <table id='table' border='1'><caption>Harvest</caption><tr><th>Crop</th><th>Tonnes</th></tr>
    <tr><td>Barley</td><td>Forty <em>two</em></td></tr><tr><td>Oats</td><td>Seven</td></tr></table>
    """

    private func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func open(_ body: String) throws -> (session: NativeSession, window: ReaderTestWindow, events: () -> [EPUBReaderEvent], publication: EPUBPublication) {
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter(body)]))
        var events: [EPUBReaderEvent] = []
        let session = try NativeSession(publication: publication, action: nil, rich: NativeRichContent()) { events.append($0) }
        return (session, ReaderTestWindow(session: session), { events }, publication)
    }

    private func bookmark(_ cfi: String) -> EPUBEngineBookmark {
        EPUBEngineBookmark(engineID: EPUBReader.identifier, format: EPUBReader.bookmarkFormat, value: cfi)
    }

    /// "Existing bookmarks naming a whole table still resolve to that table".
    func testABookmarkNamingTheWholeTableRestoresToTheTableWithoutANotice() async throws {
        let filler = (0..<70).map { "<p>Paragraph \($0) of the prose before the table, long enough to wrap onto a second line of the page.</p>" }.joined()
        let (session, window, events, publication) = try open(filler + table + "<p>After the table.</p>")
        defer { session.close(); window.close() }
        try await wait("ready") { session.isReady && session.book.section(0) != nil && session.visibleRange != nil }
        let section = try XCTUnwrap(session.book.section(0))
        let model = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let unit = try XCTUnwrap(section.anchors["table"])
        let last = try TableCoverage.offset(ofRow: 2, in: model)
        XCTAssertFalse(NSLocationInRange(unit, NSRange(location: session.visibleRange?.start.offset ?? 0, length: 200)), "the table is not on the opening page")
        // As an attachment-granular bookmark named it: the table element.
        let element = try XCTUnwrap(section.document.element(id: "table"))
        let start = try XCTUnwrap(section.map.position(at: last, in: section.document))
        XCTAssertTrue(start.node === element)
        let cfi = try SpineCFIs(publication: publication).cfi(spineIndex: 0, start: start, end: start, in: section.document)
        let before = events().count
        try await session.send(.restore(EPUBLocation(publicationID: publication.id, bookmark: bookmark(cfi))))
        try await wait("the table's page") {
            guard let visible = session.visibleRange, visible.start.section == 0 else { return false }
            return visible.start.offset <= unit && unit < visible.end.offset
        }
        XCTAssertNil(session.canvas?.anchor?.tableCell, "a whole-table bookmark names no cell")
        XCTAssertFalse(events().dropFirst(before).contains { if case .notice = $0 { return true }; return false }, "it resolved")
    }

    /// "new cell ranges identify the selected characters": a highlight saved on a cell range is
    /// drawn on those characters, and one saved on the whole table on the table.
    func testHighlightsOnACellRangeAndOnTheWholeTableAreBothDrawnWhereTheyWereSaved() async throws {
        let (session, window, _, publication) = try open("<p>Before the table.</p>" + table + "<p>After the table.</p>")
        defer { session.close(); window.close() }
        try await wait("ready") { session.isReady && session.book.section(0) != nil }
        let section = try XCTUnwrap(session.book.section(0))
        let model = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let spine = try SpineCFIs(publication: publication)
        // "ty two": from the cell's own text into its emphasis.
        let match = try XCTUnwrap(TextSearch.matches(of: "ty two", in: section.document, locale: nil).first)
        let cell = spine.cfi(spineIndex: 0, start: match.start, end: match.end, in: section.document)
        let element = try XCTUnwrap(section.document.element(id: "table"))
        let after = try XCTUnwrap(section.map.endPosition(at: try TableCoverage.offset(ofRow: 2, in: model) + 1, in: section.document))
        let whole = spine.cfi(spineIndex: 0, start: DOMPosition(element, 0), end: after, in: section.document)
        try await session.send(.setHighlights([
            EPUBHighlight(id: "cell", location: EPUBLocation(publicationID: publication.id, bookmark: bookmark(cell))),
            EPUBHighlight(id: "table", location: EPUBLocation(publicationID: publication.id, bookmark: bookmark(whole))),
        ]))
        try await wait("both highlights") { session.drawnHighlights.count == 2 }
        let drawnCell = try XCTUnwrap(session.drawnHighlights.first { $0.id == "cell" }?.range)
        XCTAssertEqual(drawnCell.start, try TableCoverage.position(in: model, cell: "Forty two", offset: 3))
        XCTAssertEqual(drawnCell.end, try TableCoverage.position(in: model, cell: "Forty two", offset: 9))
        XCTAssertEqual(section.tablePassage(drawnCell), "ty two")
        let drawnTable = try XCTUnwrap(session.drawnHighlights.first { $0.id == "table" }?.range)
        XCTAssertNil(drawnTable.start.tableCell)
        XCTAssertNil(drawnTable.end.tableCell)
        XCTAssertEqual(drawnTable.start.offset, section.anchors["table"])
        XCTAssertEqual(drawnTable.end.offset, try TableCoverage.offset(ofRow: 2, in: model) + 1, "to the end of its last row")
    }

    /// A selection from inside a cell to the prose after the table reads the rest of the table,
    /// then the prose, and its bookmark resolves to the same range.
    func testASelectionFromACellIntoTheProseAfterTheTableKeepsBothEndsExactly() async throws {
        let (session, window, events, publication) = try open("<p>Before the table.</p>" + table + "<p id='after'>After the table.</p>")
        defer { session.close(); window.close() }
        try await wait("ready") { session.isReady && session.canvas?.textViews.first?.tableInteraction?.cells.count ?? 0 > 0 }
        let canvas = try XCTUnwrap(session.canvas), section = try XCTUnwrap(session.book.section(0))
        let model = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let after = try XCTUnwrap(section.anchors["after"])
        let range = ReaderTextRange(start: try TableCoverage.position(in: model, cell: "Barley", offset: 3),
                                    end: ReaderTextPosition(section: 0, offset: after + 5))
        canvas.show(range.start, selecting: range)
        try await wait("the selection") { session.selection?.range == range }
        let text = try XCTUnwrap(session.selection?.text)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { !$0.isEmpty }, ["ley\tForty two\tOats\tSeven", "After"])
        let selected = try XCTUnwrap(events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        let bookmark = try XCTUnwrap(selected.location.bookmark)
        let target = try XCTUnwrap(SpineCFIs(publication: publication).resolve(bookmark.value))
        let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: section.document))
        XCTAssertEqual(resolved.start.node.text, "Barley")
        XCTAssertEqual(resolved.start.offset, 3)
        XCTAssertEqual(resolved.end.node.text, "After the table.")
        XCTAssertEqual(resolved.end.offset, 5)
        XCTAssertEqual(ReaderTextRange(start: section.renderedPosition(resolved.start), end: section.renderedPosition(resolved.end, isEnd: true)), range)
        // On its surfaces, the cells from the start on are selected and the ones before it are not.
        let cells = try XCTUnwrap(canvas.textViews.first?.tableInteraction).cells.values
        XCTAssertEqual(cells.first { $0.cellText.string == "Barley" }?.cellSelection, NSRange(location: 3, length: 3))
        XCTAssertEqual(cells.first { $0.cellText.string == "Seven" }?.cellSelection, NSRange(location: 0, length: 5))
        XCTAssertEqual(cells.first { $0.cellText.string == "Crop" }?.cellSelection.length, 0)
    }

    func testLocatingTextInACellSelectsItsCharactersNotTheWholeTable() async throws {
        let (session, window, _, _) = try open("<p>Before the table.</p>" + table + "<p>After the table.</p>")
        defer { session.close(); window.close() }
        try await wait("ready") { session.isReady && session.book.section(0) != nil }
        let section = try XCTUnwrap(session.book.section(0))
        let model = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        try await session.send(.locate(text: "Forty two", highlight: true))
        try await wait("the located passage") { session.selection?.text == "Forty two" }
        XCTAssertEqual(session.selection?.range.start, try TableCoverage.position(in: model, cell: "Forty two", offset: 0))
        XCTAssertEqual(session.selection?.range.end, try TableCoverage.position(in: model, cell: "Forty two", offset: 9))
        // A quote running from the caption into the header is not a cell range: it is the table.
        try await session.send(.locate(text: "HarvestCrop", highlight: true))
        try await wait("the table") { session.selection?.range.start.tableCell == nil && session.selection?.range.start.offset == section.anchors["table"] }
        XCTAssertFalse(session.selection?.range.isEmpty ?? true)
    }
}
