#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// A table of data as VoiceOver is given it on iPhone and iPad, in pages and in continuous
/// scroll (doc/native-viewer.md, "Tables"): one element for the table where its rows stand
/// among the lines, a data table to UIKit, holding an element for each cell with the row and
/// the column it stands in, and naming the cells that head them. `TableReadingOrderTests` has
/// the table that is not data, which is given row by row.
///
/// No assistive technology is driven here. The tests read the elements through the protocols
/// VoiceOver uses (`UIAccessibilityContainerDataTable` and the container protocol), and for
/// continuous scroll stand in for a move of its cursor as `ScrolledAccessibilityLinesTests`
/// does. What VoiceOver says of these elements is in doc/voiceover-testing.md.
@MainActor final class TableDataAccessibilityTests: XCTestCase {
    private typealias Subject = (reader: SessionCoverageReader, canvas: ReaderCanvasView, view: ReaderTextView)
    private typealias Table = UIAccessibilityElement & UIAccessibilityContainerDataTable
    private typealias Cell = UIAccessibilityElement & UIAccessibilityContainerDataTableCell
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    /// A reader on the book's first section, in pages or in continuous scroll, and the text
    /// view that lists its lines, once the cells on screen have their text views.
    private func reader(_ publication: EPUBPublication, scrolled: Bool) async throws -> Subject {
        let reader = try SessionCoverageReader(publication: publication)
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        if scrolled {
            try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
            try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
            try await reader.settle()
        }
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(scrolled ? canvas.scrollTextView : canvas.textViews.first { !$0.isHidden })
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.isEmpty == false }
        return (reader, canvas, view)
    }

    private func book(_ body: String) throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", body, title: "Tables"),
            SessionCoverageBook.Section("notes", "<h1>Notes</h1><p>The linked note.</p>", title: "Notes")]))
    }

    private func listed(_ view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> [UIAccessibilityElement] {
        XCTAssertFalse(view.isAccessibilityElement, "the text view is a container of its lines", file: file, line: line)
        return try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement], "the text view lists no lines", file: file, line: line)
    }

    /// The tables among what `view` lists.
    private func tables(in view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> [Table] {
        try listed(view, file: file, line: line).compactMap { $0 as? Table }
    }

    private func cells(of table: Table, file: StaticString = #filePath, line: UInt = #line) throws -> [Cell] {
        let elements = try XCTUnwrap(table.accessibilityElements, "the table lists no cells", file: file, line: line)
        return try elements.map { try XCTUnwrap($0 as? Cell, "\($0) is not a cell", file: file, line: line) }
    }

    /// An element's words, without the break that ends its paragraph.
    private func words(_ element: UIAccessibilityElement) -> String {
        (element.accessibilityLabel ?? "").trimmingCharacters(in: .newlines)
    }

    private func actions(_ element: UIAccessibilityElement) -> [String] { (element.accessibilityCustomActions ?? []).map(\.name) }

    private func perform(_ name: String, on element: UIAccessibilityElement, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(element.accessibilityCustomActions?.first { $0.name == name }, "no action \(name)", file: file, line: line)
        XCTAssertTrue(try XCTUnwrap(action.actionHandler, file: file, line: line)(action), name, file: file, line: line)
    }

    private func labels(_ headers: [UIAccessibilityContainerDataTableCell]?) -> [String] {
        (headers ?? []).map { ($0 as? UIAccessibilityElement)?.accessibilityLabel ?? "" }
    }

    private static let stations = """
    <table><caption>Stations</caption><thead><tr><th>Station</th><th>Opened</th><th>Depth</th></tr></thead>
    <tbody><tr><th scope="row">Alder</th><td>1901</td><td>Twelve metres</td></tr>
    <tr><th scope="row">Birch</th><td>1934</td><td></td></tr>
    <tr><th scope="row">Cedar</th><td><a href="notes.xhtml">Reopened 1978</a></td><td>Forty <a href="notes.xhtml">metres</a> down</td></tr>
    </tbody></table>
    """

    func testADataTableIsGivenCellByCellInsideAnElementForTheTable() async throws {
        // The chapter goes on for some screens, so the link's target is not on screen with it.
        let book = try book("<p>Words before the table.</p>" + Self.stations + "<p>Words after the table.</p>" + SessionCoverageBook.filler(120))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (reader, canvas, view) = try await reader(book, scrolled: scrolled)
            let all = try listed(view)
            XCTAssertEqual(all.prefix(2).map(words), ["Words before the table.", "Stations"], "\(flow): the caption is a line before its table")
            XCTAssertEqual(words(all[3]), "Words after the table.", "\(flow): one element for the table between the lines around it")
            XCTAssertEqual(view.accessibilityElementCount(), all.count, flow)
            let table = try XCTUnwrap(all[2] as? Table, "\(flow): \(all[2]) is not a data table")
            XCTAssertEqual(try tables(in: view).count, 1, flow)
            XCTAssertFalse(table.isAccessibilityElement, "\(flow): a table is no stop, its cells are")
            XCTAssertEqual(table.accessibilityContainerType, .dataTable, flow)
            XCTAssertTrue(table.accessibilityContainer as? ReaderTextView === view, flow)
            XCTAssertEqual(view.index(ofAccessibilityElement: table), 2, flow)
            XCTAssertTrue(view.accessibilityElement(at: 2) as? UIAccessibilityElement === table, flow)
            XCTAssertEqual(table.accessibilityRowCount(), 4, flow)
            XCTAssertEqual(table.accessibilityColumnCount(), 3, flow)

            // Every cell once, in reading order, the empty one too: it has a place in the grid.
            let cells = try cells(of: table)
            XCTAssertEqual(cells.map { $0.accessibilityLabel }, ["Station", "Opened", "Depth", "Alder", "1901", "Twelve metres",
                                                                "Birch", "1934", nil, "Cedar", "Reopened 1978", "Forty metres down"], flow)
            XCTAssertFalse(all.dropFirst(3).contains { words($0).contains("metres") }, "\(flow): nothing of the table is listed again")
            XCTAssertEqual(table.accessibilityElementCount(), 12, flow)
            XCTAssertNil(table.accessibilityElement(at: 12), flow)
            for (index, cell) in cells.enumerated() {
                let label = "\(flow): \(cell.accessibilityLabel ?? "the empty cell")"
                XCTAssertTrue(cell.isAccessibilityElement, label)
                XCTAssertTrue(cell.accessibilityContainer as? UIAccessibilityElement === table, label)
                XCTAssertEqual(cell.accessibilityRowRange(), NSRange(location: index / 3, length: 1), label)
                XCTAssertEqual(cell.accessibilityColumnRange(), NSRange(location: index % 3, length: 1), label)
                XCTAssertTrue(table.accessibilityDataTableCellElement(forRow: index / 3, column: index % 3) === cell, label)
                XCTAssertEqual(table.index(ofAccessibilityElement: cell), index, label)
                XCTAssertTrue(table.accessibilityElement(at: index) as? UIAccessibilityElement === cell, label)
                XCTAssertEqual(view.index(ofAccessibilityElement: cell), NSNotFound, "\(label) is the table's, not the text view's")
                XCTAssertFalse(cell.accessibilityTraits.contains(.image), label)
                XCTAssertEqual(cell.accessibilityTraits.contains(.link), index == 10, "\(label): a cell that is one link and nothing else is a link")
                XCTAssertEqual(cell.accessibilityTraits.contains(.staticText), index != 10, label)
            }
            XCTAssertNil(table.accessibilityDataTableCellElement(forRow: 4, column: 0), flow)
            XCTAssertNil(table.accessibilityDataTableCellElement(forRow: 0, column: 3), flow)

            // A cell stands where it is drawn: beside its neighbour in the row, below the row
            // above, inside the table's element, which stands between the lines around it.
            let frames = cells.map(\.accessibilityFrameInContainerSpace)
            for (index, frame) in frames.enumerated() {
                XCTAssertFalse(frame.isEmpty, "\(flow): cell \(index) at \(frame)")
                XCTAssertTrue(table.accessibilityFrameInContainerSpace.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(flow): cell \(index)")
                if index % 3 > 0 { XCTAssertLessThanOrEqual(frames[index - 1].maxX, frame.minX + 0.5, "\(flow): cell \(index) follows the one before it") }
                if index >= 3 { XCTAssertLessThanOrEqual(frames[index - 3].maxY, frame.minY + 0.5, "\(flow): cell \(index) is below the one above it") }
            }
            XCTAssertLessThanOrEqual(all[1].accessibilityFrameInContainerSpace.maxY, table.accessibilityFrameInContainerSpace.minY + 0.5, flow)
            XCTAssertLessThanOrEqual(table.accessibilityFrameInContainerSpace.maxY, all[3].accessibilityFrameInContainerSpace.minY + 0.5, flow)
            // On screen, by the view's own geometry: the container is no view, and a frame
            // taken as one in its space would be wrong.
            XCTAssertEqual(cells[4].accessibilityFrame, UIAccessibility.convertToScreenCoordinates(frames[4], in: view), flow)

            // The cells that head a column and a row are the cells listed for them.
            for column in 0..<3 {
                let headers = table.accessibilityHeaderElements?(forColumn: column) ?? []
                XCTAssertEqual(headers.count, 1, flow)
                XCTAssertTrue(headers.first === cells[column], "\(flow): column \(column)")
            }
            XCTAssertNil(table.accessibilityHeaderElements?(forRow: 0), "\(flow): the header row has no header of its own")
            for row in 1..<4 { XCTAssertTrue(table.accessibilityHeaderElements?(forRow: row)?.first === cells[row * 3], "\(flow): row \(row)") }

            // A cell offers what it can do itself, and a page's cells also turn the page.
            let turns = scrolled ? [] : ["Next Page", "Previous Page"]
            XCTAssertEqual(actions(cells[4]), turns + ["Select Cell Text"], flow)
            XCTAssertEqual(actions(cells[8]), turns, "\(flow): an empty cell has no words to select")
            XCTAssertEqual(actions(cells[10]), turns + ["Select Cell Text", "Follow Link: Reopened 1978"], flow)
            XCTAssertEqual(actions(cells[11]), turns + ["Select Cell Text", "Follow Link: metres"], flow)
            XCTAssertEqual(actions(all[0]), turns, "\(flow): a line beside the table repeats none of it")
            XCTAssertEqual((view.accessibilityCustomActions ?? []).map(\.name), [], "\(flow): nothing for every element to repeat")
            for inside in view.subviews where Bundle(for: type(of: inside)) == Bundle(for: ReaderTextView.self) {
                XCTAssertTrue(inside.accessibilityElementsHidden, "\(flow): \(type(of: inside)) is for touch")
            }

            try perform("Select Cell Text", on: cells[5])
            try await reader.wait("\(flow): the cell's words selected") { reader.session.selection?.text == "Twelve metres" }
            XCTAssertNotNil(reader.session.selection?.range.start.tableCell, flow)
            canvas.clearSelection()
            // A double tap does nothing on words, and follows the link of a cell that has one.
            XCTAssertFalse(cells[4].accessibilityActivate(), flow)
            XCTAssertFalse(cells[8].accessibilityActivate(), flow)
            let linked = ReaderTextPosition(section: 1, offset: 0)
            XCTAssertFalse(reader.isVisible(linked), "\(flow): the link's target must be off screen for this to show anything")
            XCTAssertTrue(cells[10].accessibilityActivate(), flow)
            try await reader.wait("\(flow): the linked chapter") { reader.isVisible(linked) }
        }
    }

    /// The rotor's action does what a double tap does when a cell holds one link among words.
    func testACellsLinkIsFollowedByItsActionAndByADoubleTap() async throws {
        let book = try book(Self.stations + SessionCoverageBook.filler(120))
        let linked = ReaderTextPosition(section: 1, offset: 0)
        for byAction in [true, false] {
            let (reader, _, view) = try await reader(book, scrolled: false)
            let cell = try XCTUnwrap(try cells(of: try XCTUnwrap(try tables(in: view).first)).last)
            XCTAssertEqual(cell.accessibilityLabel, "Forty metres down")
            XCTAssertFalse(reader.isVisible(linked))
            if byAction { try perform("Follow Link: metres", on: cell) } else { XCTAssertTrue(cell.accessibilityActivate()) }
            try await reader.wait("the linked chapter") { reader.isVisible(linked) }
        }
    }

    /// A table the book marks as layout is given row by row whatever its cells are, and so is
    /// one that nothing marks as data (`TableReadingOrderTests`).
    func testATableMarkedAsLayoutIsGivenRowByRow() async throws {
        let layout = "<table role='presentation'><tr><th>Left side</th><td>Right side</td></tr><tr><th>Lower left</th><td>Lower right</td></tr></table>"
        let book = try book("<p>Words before.</p>" + layout + "<p>Words after.</p>")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let all = try listed(view)
            XCTAssertEqual(all.prefix(4).map(words), ["Words before.", "Left side\tRight side", "Lower left\tLower right", "Words after."], flow)
            XCTAssertTrue(try tables(in: view).isEmpty, flow)
            XCTAssertTrue(all.allSatisfy { $0.isAccessibilityElement && $0.accessibilityContainer as? ReaderTextView === view }, flow)
        }
    }

    private static let services = """
    <table><tr><th rowspan="2">Service</th><th colspan="2">Hours</th></tr><tr><th>Leaves</th><th>Arrives</th></tr>
    <tr><td>Express</td><td>Nine</td><td>Noon</td></tr>
    <tr><td rowspan="2">Stopper</td><td>Ten</td><td>Three</td></tr><tr><td colspan="2">Nothing on Sunday</td></tr></table>
    """

    /// A cell that spans rows or columns is one element, read where it starts, that says
    /// which rows and columns it covers and answers for every slot of them.
    func testACellThatSpansIsOneElementForEverySlotItCovers() async throws {
        let book = try book("<p>Words before the table.</p>" + Self.services + "<p>Words after the table.</p>")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let table = try XCTUnwrap(try tables(in: view).first, flow)
            let cells = try cells(of: table)
            XCTAssertEqual(cells.map { $0.accessibilityLabel }, ["Service", "Hours", "Leaves", "Arrives", "Express", "Nine", "Noon",
                                                                "Stopper", "Ten", "Three", "Nothing on Sunday"], flow)
            XCTAssertEqual(table.accessibilityRowCount(), 5, flow)
            XCTAssertEqual(table.accessibilityColumnCount(), 3, flow)
            func cell(_ label: String) throws -> Cell { try XCTUnwrap(cells.first { $0.accessibilityLabel == label }, "\(flow): no cell \(label)") }
            XCTAssertEqual(try cell("Service").accessibilityRowRange(), NSRange(location: 0, length: 2), flow)
            XCTAssertEqual(try cell("Service").accessibilityColumnRange(), NSRange(location: 0, length: 1), flow)
            XCTAssertEqual(try cell("Hours").accessibilityColumnRange(), NSRange(location: 1, length: 2), flow)
            XCTAssertEqual(try cell("Stopper").accessibilityRowRange(), NSRange(location: 3, length: 2), flow)
            XCTAssertEqual(try cell("Nothing on Sunday").accessibilityRowRange(), NSRange(location: 4, length: 1), flow)
            XCTAssertEqual(try cell("Nothing on Sunday").accessibilityColumnRange(), NSRange(location: 1, length: 2), flow)
            // Moving down a column, VoiceOver asks for the cell of the next row: the one that covers it.
            let slots: [[String]] = [["Service", "Hours", "Hours"], ["Service", "Leaves", "Arrives"], ["Express", "Nine", "Noon"],
                                     ["Stopper", "Ten", "Three"], ["Stopper", "Nothing on Sunday", "Nothing on Sunday"]]
            for (row, names) in slots.enumerated() {
                for (column, name) in names.enumerated() {
                    XCTAssertTrue(table.accessibilityDataTableCellElement(forRow: row, column: column) === (try cell(name)),
                                  "\(flow): row \(row), column \(column) is \(name)")
                }
            }
            // A cell that spans rows is as tall as they are.
            XCTAssertGreaterThan(try cell("Service").accessibilityFrameInContainerSpace.height,
                                 try cell("Hours").accessibilityFrameInContainerSpace.height * 1.5, flow)

            // UIKit asks for a column's header cells, and VoiceOver says them before the cell
            // it comes to, all but that cell. A cell is headed by what stands above it: asked
            // for after "Hours", the second column's are not "Leaves", which stands below it.
            func columnHeaders(asking name: String, column: Int) throws -> [String] {
                _ = try cell(name).accessibilityColumnRange()
                return labels(table.accessibilityHeaderElements?(forColumn: column))
            }
            XCTAssertEqual(try columnHeaders(asking: "Hours", column: 1), ["Hours"], flow)
            XCTAssertEqual(try columnHeaders(asking: "Hours", column: 2), ["Hours"], flow)
            XCTAssertEqual(try columnHeaders(asking: "Leaves", column: 1), ["Hours", "Leaves"], flow)
            XCTAssertEqual(try columnHeaders(asking: "Nine", column: 1), ["Hours", "Leaves"], flow)
            XCTAssertEqual(try columnHeaders(asking: "Noon", column: 2), ["Hours", "Arrives"], flow)
            XCTAssertEqual(try columnHeaders(asking: "Nothing on Sunday", column: 1), ["Hours", "Leaves"], flow)
            XCTAssertEqual(try columnHeaders(asking: "Service", column: 0), ["Service"], flow)
            // Asked of a column the cell is not in, the answer is the column's own.
            XCTAssertEqual(try columnHeaders(asking: "Service", column: 2), ["Hours", "Arrives"], flow)
            XCTAssertNil(table.accessibilityHeaderElements?(forRow: 3), "\(flow): no cell here heads a row")
        }
    }

    /// The numbered rows of a long table: "Entry 07", "Item 07", "Sum 07".
    private static func ledger(rows: Int) -> String {
        "<table><thead><tr><th>Entry</th><th>Item</th><th>Sum</th></tr></thead><tbody>"
            + (1...rows).map { String(format: "<tr><td>Entry %02d</td><td>Item %02d</td><td>Sum %02d</td></tr>", $0, $0, $0) }.joined()
            + "</tbody></table>"
    }

    private static func ledgerWords(rows: Int) -> [String] {
        ["Entry", "Item", "Sum"] + (1...rows).flatMap { [String(format: "Entry %02d", $0), String(format: "Item %02d", $0), String(format: "Sum %02d", $0)] }
    }

    /// A table that goes on to the next page is, on each page, the cells that page shows. A
    /// cell keeps its row's number in the whole table, and a column is still headed by its
    /// header cell on a page that does not show the header row: the cell is named there and
    /// is nowhere to go.
    func testATableSplitAcrossPagesKeepsItsRowsNumbersAndItsHeaders() async throws {
        let book = try book("<p>Words before the ledger.</p>" + Self.ledger(rows: 60) + "<p>Words after the ledger.</p>")
        let (_, canvas, view) = try await reader(book, scrolled: false)
        var read: [String] = [], pages = 0, nextRow = 0
        repeat {
            let column = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
            XCTAssertTrue(column === view, "one column, reused for each page")
            guard let table = try tables(in: column).first else { break }
            XCTAssertEqual(try tables(in: column).count, 1, "page \(pages + 1)")
            let cells = try cells(of: table)
            read += cells.map { $0.accessibilityLabel ?? "" }
            XCTAssertEqual(table.accessibilityRowCount(), 61, "page \(pages + 1): the rows of the whole table")
            XCTAssertEqual(cells.first?.accessibilityRowRange().location, nextRow, "page \(pages + 1) goes on from the row the page before ended at")
            XCTAssertEqual(cells.count % 3, 0, "page \(pages + 1): whole rows")
            for (index, cell) in cells.enumerated() {
                XCTAssertEqual(cell.accessibilityRowRange(), NSRange(location: nextRow + index / 3, length: 1), "page \(pages + 1)")
                XCTAssertEqual(cell.accessibilityColumnRange(), NSRange(location: index % 3, length: 1), "page \(pages + 1)")
                XCTAssertTrue(table.accessibilityDataTableCellElement(forRow: nextRow + index / 3, column: index % 3) === cell, "page \(pages + 1)")
                XCTAssertTrue(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(cell.accessibilityFrameInContainerSpace), "page \(pages + 1): \(cell.accessibilityLabel ?? "")")
            }
            // A row of another page is not here to move to.
            if nextRow > 0 { XCTAssertNil(table.accessibilityDataTableCellElement(forRow: nextRow - 1, column: 0), "page \(pages + 1)") }
            XCTAssertNil(table.accessibilityDataTableCellElement(forRow: nextRow + cells.count / 3, column: 0), "page \(pages + 1)")
            for (column, name) in ["Entry", "Item", "Sum"].enumerated() {
                let headers = table.accessibilityHeaderElements?(forColumn: column) ?? []
                XCTAssertEqual(labels(headers), [name], "page \(pages + 1): the column's header by name")
                XCTAssertEqual(cells.contains { $0 === headers.first }, nextRow == 0, "page \(pages + 1): listed only where its row is")
                XCTAssertEqual(headers.first?.accessibilityRowRange(), NSRange(location: 0, length: 1), "page \(pages + 1)")
            }
            nextRow += cells.count / 3
            pages += 1
        } while pages < 40 && canvas.turnPage(forward: true) == .turned
        XCTAssertGreaterThan(pages, 1, "the table must be longer than a page for this to show anything")
        XCTAssertEqual(read, Self.ledgerWords(rows: 60), "every cell once, in order, across \(pages) pages")
    }

    /// A row taller than a page continues on the next: on each page the cell is the same cell
    /// of the table, reading the words its continuation shows there, so they are read once
    /// across the pages. A cell that has said all its words is not listed again.
    func testACellContinuedAcrossPagesReadsEachPagesOwnWords() async throws {
        let said = (1...700).map { "w\($0)" }
        let book = try book("<table><tr><th>Clause</th><th>Wording</th></tr><tr><td>Label</td><td>" + said.joined(separator: " ")
                            + "</td></tr></table>")
        let (_, canvas, view) = try await reader(book, scrolled: false)
        var read: [String] = [], others: [String] = [], pages = 0
        repeat {
            let table = try XCTUnwrap(try tables(in: view).first, "page \(pages + 1)")
            XCTAssertEqual(try listed(view).count, 1, "page \(pages + 1): the table and nothing else")
            XCTAssertEqual(table.accessibilityRowCount(), 2)
            for cell in try cells(of: table) {
                let words = (cell.accessibilityLabel ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
                if cell.accessibilityRowRange().location == 1, cell.accessibilityColumnRange().location == 1 { read += words } else { others += words }
                XCTAssertFalse(words.isEmpty, "page \(pages + 1): no stop without words")
                XCTAssertTrue(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(cell.accessibilityFrameInContainerSpace), "page \(pages + 1)")
            }
            XCTAssertEqual(labels(table.accessibilityHeaderElements?(forColumn: 1)), ["Wording"], "page \(pages + 1)")
            pages += 1
        } while pages < 40 && canvas.turnPage(forward: true) == .turned
        XCTAssertGreaterThan(pages, 1, "the row must be taller than a page for this to show anything")
        XCTAssertEqual(read, said, "every word of the tall cell once, in order, across \(pages) pages")
        XCTAssertEqual(others, ["Clause", "Wording", "Label"], "the other cells once, on the page they are on")
    }

    /// A cell of pictures without words is an image, as a picture in a line is, and a cell of
    /// decoration alone says nothing, like an empty one. Each keeps its place in the grid.
    func testACellOfPicturesIsAnImageAndACellOfDecorationSaysNothing() async throws {
        let body = "<table><tr><th>Kind</th><th>Picture</th></tr>"
            + "<tr><td>Undescribed</td><td><img src='w40.png'/></td></tr>"
            + "<tr><td>Decoration</td>" + TableCoverage.box(30) + "</tr>"
            + "<tr><td>Described</td><td><img src='w40.png' alt='A drawn map'/></td></tr></table>"
        let book = try TableCoverage.publication(body, files: TableCoverage.images([40, 30], height: 20))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let cells = try cells(of: try XCTUnwrap(try tables(in: view).first, flow))
            XCTAssertEqual(cells.map { $0.accessibilityLabel }, ["Kind", "Picture", "Undescribed", nil, "Decoration", nil, "Described", "A drawn map"], flow)
            XCTAssertEqual(cells.map { $0.accessibilityTraits.contains(.image) }, [false, false, false, true, false, false, false, false],
                           "\(flow): a picture with words is read by its words")
            let turns = scrolled ? [] : ["Next Page", "Previous Page"]
            XCTAssertEqual(actions(cells[3]), turns + ["Inspect Image"], flow)
            XCTAssertEqual(actions(cells[5]), turns, "\(flow): decoration is not offered for inspection")
            XCTAssertEqual(actions(cells[7]), turns + ["Inspect Image: A drawn map", "Select Cell Text"], flow)
        }
    }

    // MARK: Continuous scroll

    /// The area UIKit keeps the element under the cursor in: the view less its insets.
    private func cursorArea(of view: ReaderTextView) -> CGRect { view.bounds.inset(by: view.adjustedContentInset) }

    /// Puts the cursor on `element` as VoiceOver does: UIKit scrolls it into view, the element
    /// left is told and named, the element reached is told and named
    /// (`ScrolledAccessibilityLinesTests`).
    private func focus(_ element: UIAccessibilityElement, from previous: UIAccessibilityElement?, in view: ReaderTextView) {
        let frame = element.accessibilityFrameInContainerSpace, area = cursorArea(of: view)
        if frame.minY < area.minY - 0.01 { view.contentOffset.y -= area.minY - frame.minY + 40 }
        else if frame.maxY > area.maxY + 0.01 { view.contentOffset.y += min(frame.maxY - area.maxY, frame.minY - area.minY) + 40 }
        if let previous {
            previous.accessibilityElementDidLoseFocus()
            NotificationCenter.default.post(name: UIAccessibility.elementFocusedNotification, object: nil,
                                            userInfo: [UIAccessibility.unfocusedElementUserInfoKey: previous])
        }
        element.accessibilityElementDidBecomeFocused()
        NotificationCenter.default.post(name: UIAccessibility.elementFocusedNotification, object: nil,
                                        userInfo: [UIAccessibility.focusedElementUserInfoKey: element])
    }

    /// The stop after or before `element`, found as UIKit finds it: the neighbour in the
    /// element's container, and at the container's end the neighbour of the container, going
    /// into a table at its first or last cell.
    private func neighbour(of element: UIAccessibilityElement, forward: Bool, in view: ReaderTextView,
                           file: StaticString = #filePath, line: UInt = #line) throws -> UIAccessibilityElement? {
        var current: UIAccessibilityElement = element
        while true {
            let container = try XCTUnwrap(current.accessibilityContainer as? NSObject, file: file, line: line)
            let index = container.index(ofAccessibilityElement: current)
            XCTAssertNotEqual(index, NSNotFound, "\(current.accessibilityLabel ?? "the table") is no longer listed", file: file, line: line)
            if let next = container.accessibilityElement(at: index + (forward ? 1 : -1)) as? UIAccessibilityElement {
                guard !next.isAccessibilityElement else { return next }
                let count = next.accessibilityElementCount()
                return next.accessibilityElement(at: forward ? 0 : count - 1) as? UIAccessibilityElement
            }
            guard container !== view, let table = container as? UIAccessibilityElement else { return nil }
            current = table
        }
    }

    /// VoiceOver reading on through a table longer than the screen, forward and back: the
    /// rows listed change under its cursor, the table keeps its element and each cell its
    /// own, and every cell is met once and in order.
    func testVoiceOverReadsOnThroughATableLongerThanTheScreenInBothDirections() async throws {
        let rows = 70
        let book = try book("<p>Words before the ledger.</p>" + Self.ledger(rows: rows) + "<p>Words after the ledger.</p>"
                            + SessionCoverageBook.filler(60))
        let (_, canvas, view) = try await reader(book, scrolled: true)
        let onScreen = try cells(of: try XCTUnwrap(try tables(in: view).first))
        XCTAssertLessThan(onScreen.count, (rows + 1) * 3, "the table must be longer than the screen for this to show anything")
        XCTAssertEqual(try XCTUnwrap(try tables(in: view).first).accessibilityRowCount(), rows + 1)

        // Into the text at its first line, and on.
        var cursor = try XCTUnwrap(try listed(view).first)
        XCTAssertEqual(words(cursor), "Words before the ledger.")
        focus(cursor, from: nil, in: view)
        var table: (Table)?
        var read: [String] = []
        let expected = Self.ledgerWords(rows: rows)
        for step in 0..<(expected.count + 1) {
            let next = try XCTUnwrap(try neighbour(of: cursor, forward: true, in: view), "step \(step): the text goes on")
            focus(next, from: cursor, in: view)
            cursor = next
            guard step < expected.count else { break }
            let cell = try XCTUnwrap(cursor as? Cell, "step \(step): \(words(cursor)) is not a cell")
            read.append(cell.accessibilityLabel ?? "")
            XCTAssertEqual(cell.accessibilityRowRange().location, step / 3, "step \(step)")
            XCTAssertEqual(cell.accessibilityColumnRange().location, step % 3, "step \(step)")
            // The cell the cursor came to is the one listed for it, in the table listed.
            let listedTable = try XCTUnwrap(try tables(in: view).first, "step \(step)")
            XCTAssertEqual(try tables(in: view).count, 1, "step \(step): one element for the table, whatever part of it is listed")
            if let table { XCTAssertTrue(table === listedTable, "step \(step): the table keeps its element while the cursor is in it") }
            table = listedTable
            XCTAssertTrue(cell.accessibilityContainer as? UIAccessibilityElement === listedTable, "step \(step)")
            XCTAssertTrue(listedTable.accessibilityDataTableCellElement(forRow: step / 3, column: step % 3) === cell, "step \(step)")
            XCTAssertTrue(cursorArea(of: view).insetBy(dx: -1_000, dy: -0.01).contains(cell.accessibilityFrameInContainerSpace),
                          "step \(step): \(read.last ?? "") is not where the cursor can be seen")
            // The row below is listed to move down the column to, until the table ends.
            if step / 3 < rows {
                XCTAssertNotNil(listedTable.accessibilityDataTableCellElement(forRow: step / 3 + 1, column: step % 3), "step \(step): the row below")
            }
            // And the column's header cell is named, on screen or not.
            XCTAssertEqual(labels(listedTable.accessibilityHeaderElements?(forColumn: step % 3)), [expected[step % 3]], "step \(step)")
        }
        XCTAssertEqual(read, expected, "every cell once, in order")
        XCTAssertEqual(words(cursor), "Words after the ledger.", "then the line after the table")
        try await readers[0].wait("the place read to") { canvas.visibleRange?.start != ReaderTextPosition(section: 0, offset: 0) }

        // And back, to the line before the table.
        var back: [String] = []
        for step in 0..<(expected.count + 1) {
            let next = try XCTUnwrap(try neighbour(of: cursor, forward: false, in: view), "step \(step) back: the text goes back")
            focus(next, from: cursor, in: view)
            cursor = next
            guard step < expected.count else { break }
            back.append(cursor.accessibilityLabel ?? "")
            XCTAssertEqual(try tables(in: view).count, 1, "step \(step) back")
            XCTAssertTrue(cursorArea(of: view).insetBy(dx: -1_000, dy: -0.01).contains(cursor.accessibilityFrameInContainerSpace),
                          "step \(step) back: \(back.last ?? "") is not where the cursor can be seen")
        }
        XCTAssertEqual(back, expected.reversed(), "every cell once, in reverse")
        XCTAssertEqual(words(cursor), "Words before the ledger.")

        // Down a column, as the rotor's Rows moves: the cell of the next row, row after row.
        var cell = try XCTUnwrap(try neighbour(of: try XCTUnwrap(try neighbour(of: cursor, forward: true, in: view)), forward: true, in: view) as? Cell)
        XCTAssertEqual(cell.accessibilityLabel, "Item")
        focus(cell, from: cursor, in: view)
        for row in 1...rows {
            let container = try XCTUnwrap(cell.accessibilityContainer as? Table, "row \(row)")
            let below = try XCTUnwrap(container.accessibilityDataTableCellElement(forRow: row, column: 1) as? Cell, "row \(row) is not listed to move down to")
            focus(below, from: cell, in: view)
            cell = below
            XCTAssertEqual(cell.accessibilityLabel, String(format: "Item %02d", row))
        }
        XCTAssertNil((cell.accessibilityContainer as? Table)?.accessibilityDataTableCellElement(forRow: rows + 1, column: 1), "the table ends")
    }

    /// The cursor resting in a table that the person then scrolls away from: the rows around
    /// the cursor stay listed apart from those on screen, each run in an element of its own,
    /// and the cursor's cell stays where VoiceOver left it.
    func testACursorRestingInATableKeepsItsRowsListedWhenThePersonScrollsAway() async throws {
        let rows = 120
        let book = try book(Self.ledger(rows: rows) + "<p>Words after the ledger.</p>")
        let (_, _, view) = try await reader(book, scrolled: true)
        let cell = try XCTUnwrap(try cells(of: try XCTUnwrap(try tables(in: view).first)).first { $0.accessibilityLabel == "Item 03" })
        focus(cell, from: nil, in: view)
        let table = try XCTUnwrap(cell.accessibilityContainer as? Table)
        view.contentOffset.y += 2_400
        let listed = try tables(in: view)
        XCTAssertEqual(listed.count, 2, "the rows around the cursor, and the rows on screen")
        XCTAssertTrue(listed[0] === table, "the cursor's table keeps its element")
        XCTAssertTrue(try cells(of: listed[0]).contains { $0 === cell }, "and its cell")
        XCTAssertFalse(try cells(of: listed[1]).contains { $0.accessibilityRowRange().location < 10 })
        XCTAssertEqual(listed[0].index(ofAccessibilityElement: cell), try XCTUnwrap(try cells(of: listed[0]).firstIndex { $0 === cell }))
        XCTAssertEqual(listed[1].index(ofAccessibilityElement: cell), NSNotFound)
        XCTAssertEqual(view.index(ofAccessibilityElement: listed[1]), 1)
    }
}

#endif
