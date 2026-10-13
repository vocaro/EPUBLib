import EPUBCore
import EPUBReading
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A table's cells in continuous scroll after the reader has moved the scroll view itself: to
/// the section a book opens at, a contents entry, a link's target, a step of a page, and for a
/// new size. Each row on screen then has a text view on each of its cells, where the row is
/// drawn, with the highlights and the selection that run through it, and nobody has scrolled
/// (doc/native-viewer.md, "Tables").
///
/// The scroll view tells of a move before TextKit has laid the text out at the new place, and
/// the rows were looked for then alone: where the layout still had them. The reader's last
/// correction of such a move is by less than a screen in these books, so the rows the layout
/// had not reached were the lowest on screen, and the table here is taller than the screen so
/// that there are some. Where the correction is by more than a screen no row has a text
/// view, which an iPad showed with the VoiceOver sample book (#472).
@MainActor final class TableScrolledCellTests: XCTestCase {
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    private static let rows = 120

    /// Chapters of prose, each with a paragraph of a thousand words and a small table, whose
    /// heights TextKit can only guess until they are laid out; then a chapter that opens
    /// with a table of data taller than any screen here; then more prose. Built once: a book
    /// built again is another book to the reader, which draws no highlight made in the first.
    private static let book = Result { try makeBook() }

    private static func makeBook() throws -> Data {
        let long = "<p>" + (1...1000).map { "word\($0)" }.joined(separator: " ") + "</p>"
        let small = "<table><tr><td>One side</td><td>Other side</td></tr></table>"
        var sections = [SessionCoverageBook.Section("opening", "<h1>Opening</h1>" + SessionCoverageBook.filler(30), title: "Opening")]
        sections += (0..<5).map {
            SessionCoverageBook.Section("prose\($0)", "<h1>Prose \($0)</h1>" + long + small + SessionCoverageBook.filler(12 + 3 * $0),
                                        title: "Prose \($0)")
        }
        let table = "<table><tr><th>Station</th><th>Opened</th><th>Depth</th></tr>"
            + (1...rows).map { "<tr><td id=\"station\($0)\">Station \($0)</td><td>Year \(1900 + $0)</td><td>\($0) metres</td></tr>" }.joined()
            + "</table>"
        sections.append(SessionCoverageBook.Section("tables", "<h1>Tables</h1><p>Words before the table.</p>" + table
            + "<p id=\"after\">Words after the table.</p>" + SessionCoverageBook.filler(40), title: "Tables"))
        sections.append(SessionCoverageBook.Section("closing", "<h1>Closing</h1>" + SessionCoverageBook.filler(40), title: "Closing"))
        return try SessionCoverageBook.epub(sections)
    }

    private static let tables = 6

    private func open(_ size: CGSize, settled: Bool = true) async throws -> SessionCoverageReader {
        let reader = try SessionCoverageReader(publication: EPUBPublication.open(data: Self.book.get()))
        readers.append(reader)
        reader.window?.resize(to: size)
        guard settled else {
            try await reader.wait("a ready reader") { reader.session.isReady }
            return reader
        }
        try await reader.settle()
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await rest(reader)
        return reader
    }

    /// The whole book is in the scroll view and the reader has said where it stands. Nothing
    /// here scrolls, lays out or looks for rows.
    private func rest(_ reader: SessionCoverageReader) async throws {
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        try await Task.sleep(for: .milliseconds(300))
    }

    /// The frame of each text view the reader has mounted on a cell.
    private func mounted(_ view: ReaderTextView) -> [ReaderTableInteraction.Key: CGRect] {
        (view.tableInteraction?.cells ?? [:]).mapValues(\.frame)
    }

    /// Holds the scroll view to a text view on every cell of every row the screen shows,
    /// inside the row as it is drawn, and to finding nothing different when it looks again.
    /// What the reader mounted is taken first, before anything here asks the layout a thing.
    /// Returns the words of the cells on screen.
    @discardableResult
    private func assertTheRowsOnScreenHaveTheirCells(_ reader: SessionCoverageReader, after move: String, atLeast: Int = 8,
                                                     file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let canvas = try XCTUnwrap(reader.session.canvas, file: file, line: line)
        let view = try XCTUnwrap(canvas.scrollTextView, file: file, line: line)
        let cells = view.tableInteraction?.cells ?? [:]
        let found = mounted(view)
        XCTAssertEqual(reader.session.visibleRange?.start.section, Self.tables, "\(move): the chapter of the table", file: file, line: line)
        let shown = try XCTUnwrap(canvas.scrollVisibleCharacters(), file: file, line: line)
        let storage = try XCTUnwrap(view.contentStorage.textStorage, file: file, line: line)
        var rows = 0, words: [String] = []
        storage.enumerateAttribute(.attachment, in: shown) { value, run, _ in
            guard value is TableRowAttachment, let drawn = view.segmentFrames(for: run).first else { return }
            rows += 1
            let row = drawn.offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y).insetBy(dx: -1, dy: -1)
            let own = cells.filter { $0.key.location == run.location }
            XCTAssertEqual(own.count, 3, "\(move): a text view on each cell of the row at \(run.location), \(Int(row.minY)) in a view at \(Int(view.bounds.minY))",
                           file: file, line: line)
            for cell in own.values {
                words.append(cell.cellText.string)
                XCTAssertTrue(row.contains(cell.frame), "\(move): \(cell.cellText.string) at \(cell.frame) is in its row as drawn, \(row)",
                              file: file, line: line)
            }
        }
        XCTAssertGreaterThanOrEqual(rows, atLeast, "\(move): rows of the table on screen", file: file, line: line)
        view.refreshTableInteractions()
        let again = mounted(view)
        XCTAssertEqual(Set(found.keys), Set(again.keys), "\(move): looking again finds the same cells", file: file, line: line)
        // To within a point: AppKit aligns the scroll view's offset to the pixel grid.
        let moved = found.filter { key, frame in
            again[key].map { abs($0.minX - frame.minX) > 1 || abs($0.minY - frame.minY) > 1 || abs($0.width - frame.width) > 1 || abs($0.height - frame.height) > 1 } ?? false
        }
        XCTAssertEqual(moved.count, 0, "\(move): looking again finds the cells where they were: \(moved.prefix(2))", file: file, line: line)
        #if os(iOS)
        guard rows > 0 else { return words }
        // What a cell's text view is for to an assistive technology: without it the cell's
        // item offered no action, and VoiceOver's rotor had no Actions for it.
        typealias Cell = UIAccessibilityElement & UIAccessibilityContainerDataTableCell
        let listed = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement], file: file, line: line)
        let table = try XCTUnwrap(listed.first { $0 is UIAccessibilityContainerDataTable }, "\(move): the table of data", file: file, line: line)
        let items = (table.accessibilityElements ?? []).compactMap { $0 as? Cell }.filter { words.contains($0.accessibilityLabel ?? "") }
        XCTAssertEqual(items.count, words.count, "\(move): an item for each cell on screen", file: file, line: line)
        for item in items {
            let first = item.accessibilityCustomActions?.first?.name
            XCTAssertTrue(first == "Select Cell Text" || first == "Deselect Cell Text",
                          "\(move): \(item.accessibilityLabel ?? "") offers its action, and has \(first ?? "none")", file: file, line: line)
        }
        #endif
        return words
    }

    private static let sizes = [CGSize(width: 402, height: 874), CGSize(width: 1024, height: 1366)]

    /// A book opened in continuous scroll at a chapter, as a host does that sets the flow and
    /// the place as soon as the reader is ready: the chapter is shown alone, and then in the
    /// whole book once every chapter is built.
    func testATableInTheChapterABookOpensAtHasItsCells() async throws {
        for size in Self.sizes {
            let reader = try await open(size, settled: false)
            try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
            try await reader.session.send(.navigate(href: "OPS/tables.xhtml"))
            try await rest(reader)
            let words = try assertTheRowsOnScreenHaveTheirCells(reader, after: "opened at the chapter, \(Int(size.width)) wide")
            XCTAssertTrue(words.contains("Station 1"))
        }
    }

    /// A contents entry and a link's target are the same move: the reader shows a place. Each
    /// is made in a reader that has looked at nothing else, since looking for a check lays
    /// text out past the screen.
    func testATableTheReaderGoesToHasItsCells() async throws {
        for size in Self.sizes {
            let wide = "\(Int(size.width)) wide"
            var reader = try await open(size)
            try await reader.session.send(.navigate(href: "OPS/tables.xhtml"))
            try await rest(reader)
            var words = try assertTheRowsOnScreenHaveTheirCells(reader, after: "a contents entry, \(wide)")
            XCTAssertTrue(words.contains("Station 1"))

            reader = try await open(size)
            try await reader.session.send(.navigate(href: "OPS/tables.xhtml#station30"))
            try await rest(reader)
            words = try assertTheRowsOnScreenHaveTheirCells(reader, after: "a link to a cell, \(wide)")
            XCTAssertTrue(words.contains("Station 30"))

            // From the far end of the book, where the reader climbs to the place from below.
            reader = try await open(size)
            try await reader.session.send(.navigate(href: "OPS/closing.xhtml"))
            try await rest(reader)
            try await reader.session.send(.navigate(href: "OPS/tables.xhtml#station60"))
            try await rest(reader)
            words = try assertTheRowsOnScreenHaveTheirCells(reader, after: "a link to a cell from after it, \(wide)")
            XCTAssertTrue(words.contains("Station 60"))
            try await reader.session.send(.navigate(href: "OPS/tables.xhtml#after"))
            try await rest(reader)
            try assertTheRowsOnScreenHaveTheirCells(reader, after: "a link to the line after the table, \(wide)", atLeast: 0)
        }
    }

    /// A step of a page in continuous scroll, forward through the table and back.
    func testATableReachedByAStepOfAPageHasItsCells() async throws {
        for size in Self.sizes {
            let reader = try await open(size)
            try await reader.session.send(.navigate(href: "OPS/tables.xhtml"))
            try await rest(reader)
            for step in 1...2 {
                try await reader.session.send(.nextPage)
                try await rest(reader)
                try assertTheRowsOnScreenHaveTheirCells(reader, after: "step \(step) forward, \(Int(size.width)) wide")
            }
            try await reader.session.send(.previousPage)
            try await rest(reader)
            try assertTheRowsOnScreenHaveTheirCells(reader, after: "a step back, \(Int(size.width)) wide")
        }
    }

    /// A scroll that is not the reader's own and goes a screen at once, to rows never laid
    /// out, as the platform's does for an assistive technology or a drag of the scroll bar.
    /// The reader reads where the view stands a moment after it, and looks for the rows then.
    func testATableThePlatformScrollsToHasItsCells() async throws {
        for size in Self.sizes {
            let reader = try await open(size)
            try await reader.session.send(.navigate(href: "OPS/tables.xhtml"))
            try await rest(reader)
            let view = try XCTUnwrap(reader.session.canvas?.scrollTextView)
            #if os(macOS)
            let scrollView = try XCTUnwrap(view.enclosingScrollView), clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + clip.bounds.height - 60))
            scrollView.reflectScrolledClipView(clip)
            #else
            view.contentOffset.y += view.bounds.height - 60
            #endif
            try await rest(reader)
            let words = try assertTheRowsOnScreenHaveTheirCells(reader, after: "a scroll of the platform's, \(Int(size.width)) wide")
            XCTAssertFalse(words.contains("Station 1"), "the view moved: \(words.prefix(6))")
        }
    }

    private func resize(_ reader: SessionCoverageReader, to size: CGSize) async throws {
        reader.window?.resize(to: size)
        let deadline = Date().addingTimeInterval(5)
        while reader.session.canvas?.bounds.width != size.width, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await rest(reader)
    }

    /// A new size lays the text out anew and the reader rests its place again.
    func testATableKeepsItsCellsThroughANewSize() async throws {
        let reader = try await open(CGSize(width: 402, height: 874))
        try await reader.session.send(.navigate(href: "OPS/tables.xhtml#station12"))
        try await rest(reader)
        try assertTheRowsOnScreenHaveTheirCells(reader, after: "a link, upright")
        for size in [CGSize(width: 874, height: 402), CGSize(width: 402, height: 874), CGSize(width: 640, height: 700)] {
            try await resize(reader, to: size)
            // Lying down, a screen of that height shows few rows.
            try assertTheRowsOnScreenHaveTheirCells(reader, after: "a new size, \(Int(size.width)) wide", atLeast: size.height > 500 ? 8 : 1)
        }
    }

    private func cell(_ words: String, in reader: SessionCoverageReader) -> TableCellTextView? {
        reader.session.canvas?.scrollTextView?.tableInteraction?.cells.values.first { $0.cellText.string == words }
    }

    /// Whether the cell's text view holds a highlight behind its first character.
    private func highlighted(_ cell: TableCellTextView) -> Bool {
        #if os(macOS)
        let storage = cell.textStorage
        #else
        let storage: NSTextStorage? = cell.textStorage
        #endif
        return storage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil
    }

    /// A highlight in a cell and a selection in another are on the cells' text views after a
    /// move of the reader's own: a new size, which lays the text out anew under both; a
    /// contents entry, to rows that have never been laid out and a highlight set beforehand;
    /// and a step of a page back, which leaves the selected row the last on screen.
    func testCellsTheReaderGoesToHaveTheirHighlightAndSelection() async throws {
        var reader = try await open(CGSize(width: 402, height: 874))
        try await reader.session.send(.locate(text: "Year 1915", highlight: true))
        try await reader.wait("the host told of the selection") { (reader.selections().last ?? nil)?.text == "Year 1915" }
        let highlight = EPUBHighlight(id: "cell", location: try XCTUnwrap(reader.selections().last ?? nil).location)
        try await reader.session.send(.setHighlights([highlight]))
        try await reader.session.send(.locate(text: "Station 12", highlight: true))
        try await reader.wait("the second cell selected") { reader.session.selection?.text == "Station 12" }
        try await rest(reader)
        let selected = NSRange(location: 0, length: 10)
        XCTAssertEqual(try XCTUnwrap(cell("Station 12", in: reader)).cellSelection, selected)
        XCTAssertTrue(highlighted(try XCTUnwrap(cell("Year 1915", in: reader))))

        try await resize(reader, to: CGSize(width: 640, height: 700))
        var words = try assertTheRowsOnScreenHaveTheirCells(reader, after: "a new size")
        XCTAssertTrue(words.contains("Station 12") && words.contains("Year 1915"), "both rows are on screen: \(words)")
        XCTAssertEqual(reader.session.selection?.text, "Station 12")
        XCTAssertEqual(try XCTUnwrap(cell("Station 12", in: reader)).cellSelection, selected, "the selection is on its cell")
        XCTAssertTrue(highlighted(try XCTUnwrap(cell("Year 1915", in: reader))), "the highlight is on its cell")
        XCTAssertFalse(highlighted(try XCTUnwrap(cell("Year 1916", in: reader))))

        reader = try await open(CGSize(width: 402, height: 874))
        try await reader.session.send(.setHighlights([highlight]))
        XCTAssertEqual(reader.notices(), [], "the second reader takes the first one's highlight")
        try await reader.session.send(.navigate(href: "OPS/tables.xhtml"))
        try await rest(reader)
        words = try assertTheRowsOnScreenHaveTheirCells(reader, after: "a contents entry to rows with a highlight")
        XCTAssertTrue(words.contains("Year 1915"), "the highlighted row is on screen: \(words)")
        XCTAssertTrue(highlighted(try XCTUnwrap(cell("Year 1915", in: reader))), "the highlight is on a cell the reader went to")
        XCTAssertFalse(highlighted(try XCTUnwrap(cell("Year 1916", in: reader))))

        reader = try await open(CGSize(width: 402, height: 874))
        try await reader.session.send(.locate(text: "Station 70", highlight: true))
        try await reader.wait("the cell selected") { reader.session.selection?.text == "Station 70" }
        try await rest(reader)
        try await reader.session.send(.previousPage)
        try await rest(reader)
        words = try assertTheRowsOnScreenHaveTheirCells(reader, after: "a step back from a selected cell")
        XCTAssertTrue(words.contains("Station 70"), "the selected row is on screen: \(words)")
        XCTAssertEqual(reader.session.selection?.text, "Station 70")
        XCTAssertEqual(try XCTUnwrap(cell("Station 70", in: reader)).cellSelection, selected, "the selection is on a cell the reader stepped to")
    }
}
