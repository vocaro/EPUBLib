#if os(macOS)
import AppKit
import EPUBCore
import EPUBReading
import XCTest
@testable import EPUBViewing

/// A table of data as an assistive technology is given it on the Mac, in pages and in
/// continuous scroll (doc/native-viewer.md, "Data tables"): at each row's character in the
/// text an `NSAccessibility` table, named by that row's words and with that row selected, that
/// holds the rows the view shows, the columns, the cells and the cells that head them. A table
/// that is not data stays a group for each row.
///
/// No assistive technology is driven here. The tests read the elements through AppKit's own
/// accessibility methods, which are what its bridge to a client calls. What VoiceOver says of
/// them, and that a client is given every attribute, is in doc/voiceover-testing.md.
@MainActor final class TableDataMacAccessibilityTests: XCTestCase {
    private typealias Subject = (reader: SessionCoverageReader, canvas: ReaderCanvasView, view: ReaderTextView)
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    /// A reader on the book's first section, in pages or in continuous scroll, and the text
    /// view that shows it, once the cells on screen have their text views.
    private func reader(_ publication: EPUBPublication, scrolled: Bool) async throws -> Subject {
        let reader = try SessionCoverageReader(publication: publication)
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 600, height: 700))
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

    /// The element the text gives at each attachment's character, in order: what VoiceOver
    /// announces there as it reads, and goes into.
    private func attachments(in view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws
        -> [(location: Int, element: NSAccessibilityElement)] {
        let range = view.isPageColumn ? view.shownCharacters : NSRange(location: 0, length: view.textLength)
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: range), file: file, line: line)
        var found: [(Int, NSAccessibilityElement)] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, run, _ in
            if let element = value as? NSAccessibilityElement { found.append((run.location + range.location, element)) }
        }
        return found
    }

    /// The tables the text gives, one at each row's character, in order.
    private func tables(in view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> [ReaderTableElement] {
        try attachments(in: view, file: file, line: line).compactMap { $0.element as? ReaderTableElement }
    }

    private func rows(of table: ReaderTableElement, file: StaticString = #filePath, line: UInt = #line) throws -> [ReaderTableRowElement] {
        try (table.accessibilityRows() ?? []).map { try XCTUnwrap($0 as? ReaderTableRowElement, "\($0) is not a row", file: file, line: line) }
    }

    private func cells(of row: ReaderTableRowElement, file: StaticString = #filePath, line: UInt = #line) throws -> [ReaderTableCellElement] {
        try (row.accessibilityChildren() ?? []).map { try XCTUnwrap($0 as? ReaderTableCellElement, "\($0) is not a cell", file: file, line: line) }
    }

    /// Every cell the table lists, row by row.
    private func cells(of table: ReaderTableElement, file: StaticString = #filePath, line: UInt = #line) throws -> [ReaderTableCellElement] {
        try rows(of: table, file: file, line: line).flatMap { try cells(of: $0, file: file, line: line) }
    }

    /// What a cell says: the words of the text areas it holds, or its label where it holds none.
    private func said(_ cell: ReaderTableCellElement) -> String {
        let views = (cell.accessibilityChildren() ?? []).compactMap { $0 as? TableCellTextView }
        guard !views.isEmpty else { return cell.accessibilityLabel() ?? "" }
        return views.map { $0.accessibilityValue() ?? "" }.joined(separator: " ")
    }

    private func said(_ cells: [Any]?) -> [String] { (cells ?? []).compactMap { $0 as? ReaderTableCellElement }.map(said) }

    /// What VoiceOver says of each header a table gives: a cell's words where the header is
    /// a cell on screen, and otherwise the value of the static text that stands for it.
    private func headed(_ headers: [Any]?) -> [String] {
        (headers ?? []).map { header in
            if let cell = header as? ReaderTableCellElement { return said(cell) }
            return (header as? ReaderTableHeaderElement)?.accessibilityValue() as? String ?? ""
        }
    }

    private func actions(_ cell: ReaderTableCellElement) -> [String] { (cell.accessibilityCustomActions() ?? []).map(\.name) }

    private func perform(_ name: String, on cell: ReaderTableCellElement, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(cell.accessibilityCustomActions()?.first { $0.name == name }, "no action \(name)", file: file, line: line)
        XCTAssertTrue(try XCTUnwrap(action.handler, file: file, line: line)(), name, file: file, line: line)
    }

    private static let stations = """
    <table><caption>Stations</caption><thead><tr><th>Station</th><th>Opened</th><th>Depth</th></tr></thead>
    <tbody><tr><th scope="row">Alder</th><td>1901</td><td>Twelve metres</td></tr>
    <tr><th scope="row">Birch</th><td>1934</td><td></td></tr>
    <tr><th scope="row">Cedar</th><td><a href="notes.xhtml">Reopened 1978</a></td><td>Forty metres down</td></tr>
    </tbody></table>
    """

    func testEachRowOfADataTableGivesTheTableNamedByThatRowAndEnteredAtIt() async throws {
        // The chapter goes on for some screens, so the link's target is not on screen with it.
        let book = try book("<p>Words before the table.</p>" + Self.stations + "<p>Words after the table.</p>" + SessionCoverageBook.filler(120))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (reader, canvas, view) = try await reader(book, scrolled: scrolled)
            let given = try attachments(in: view)
            let tables = try tables(in: view)
            XCTAssertEqual(tables.count, 4, "\(flow): a table at each row's character")
            XCTAssertEqual(given.count, 4, "\(flow): and nothing else of the table: the caption and the lines around it are text")
            XCTAssertEqual(Set(tables.map(ObjectIdentifier.init)).count, 4, "\(flow): each row's is an element of its own")
            // As VoiceOver reads the text it says a table's label and its role: the row's words.
            XCTAssertEqual(tables.map { $0.accessibilityLabel() }, ["Station, Opened, Depth", "Alder, 1901, Twelve metres", "Birch, 1934",
                                                                  "Cedar, Reopened 1978, Forty metres down"], flow)
            // Asked for one row's character, as a line or a word is, the text gives the same element.
            for (index, entry) in given.enumerated() {
                let one = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: entry.location, length: 1)))
                XCTAssertTrue(one.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil) as AnyObject === tables[index], "\(flow): row \(index)")
            }

            for (index, table) in tables.enumerated() {
                let place = "\(flow), the table at row \(index)"
                XCTAssertEqual(table.accessibilityRole(), .table, place)
                XCTAssertTrue(table.accessibilityParent() as AnyObject === view, place)
                XCTAssertEqual(table.accessibilityRowCount(), 4, place)
                XCTAssertEqual(table.accessibilityColumnCount(), 3, place)
                let rows = try rows(of: table)
                XCTAssertEqual(rows.count, 4, place)
                XCTAssertEqual(rows.map { $0.accessibilityIndex() }, [0, 1, 2, 3], place)
                XCTAssertTrue(rows.allSatisfy { $0.accessibilityRole() == .row && $0.accessibilitySubrole() == .tableRow }, place)
                XCTAssertTrue(rows.allSatisfy { $0.accessibilityParent() as AnyObject === table }, place)
                XCTAssertEqual(table.accessibilityVisibleRows()?.count, 4, "\(place): the table is on screen")
                // VoiceOver comes into a table at its selected row: the one it stands at.
                let selected = try XCTUnwrap(table.accessibilitySelectedRows() as? [ReaderTableRowElement], place)
                XCTAssertEqual(selected.count, 1, place)
                XCTAssertTrue(selected.first === rows[index], place)
                // Where the table stands is its row's place, between the lines around it.
                XCTAssertEqual(table.accessibilityFrame(), rows[index].accessibilityFrame(), place)
                XCTAssertFalse(table.accessibilityFrame().isEmpty, place)

                // Every cell once, in reading order, the empty one too: it has a place in the grid.
                let cells = try cells(of: table)
                XCTAssertEqual(cells.map(said), ["Station", "Opened", "Depth", "Alder", "1901", "Twelve metres",
                                                 "Birch", "1934", "", "Cedar", "Reopened 1978", "Forty metres down"], place)
                for (number, cell) in cells.enumerated() {
                    let label = "\(place): \(said(cell).isEmpty ? "the empty cell" : said(cell))"
                    XCTAssertEqual(cell.accessibilityRole(), .cell, label)
                    XCTAssertTrue(cell.accessibilityParent() as AnyObject === rows[number / 3], label)
                    XCTAssertEqual(cell.accessibilityRowIndexRange(), NSRange(location: number / 3, length: 1), label)
                    XCTAssertEqual(cell.accessibilityColumnIndexRange(), NSRange(location: number % 3, length: 1), label)
                    XCTAssertTrue(table.accessibilityCell(forColumn: number % 3, row: number / 3) as AnyObject === cell, label)
                    // A cell on screen holds the text areas of its words, which VoiceOver goes
                    // into to read by word, and they answer to it.
                    let views = (cell.accessibilityChildren() ?? []).compactMap { $0 as? TableCellTextView }
                    XCTAssertEqual(views.count, number == 8 ? 0 : 1, label)
                    XCTAssertNil(cell.accessibilityLabel(), "\(label): its text area says its words")
                    XCTAssertTrue(views.allSatisfy { $0.accessibilityParent() as AnyObject === cell }, label)
                    // A cell stands where it is drawn: inside its row, beside its neighbour.
                    let frame = cell.accessibilityFrame()
                    XCTAssertFalse(frame.isEmpty, label)
                    XCTAssertTrue(rows[number / 3].accessibilityFrame().insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(label): \(frame)")
                    if number % 3 > 0 { XCTAssertLessThanOrEqual(cells[number - 1].accessibilityFrame().maxX, frame.minX + 0.5, label) }
                    // Screen coordinates go up: a row is below the one before it.
                    if number >= 3 { XCTAssertGreaterThanOrEqual(cells[number - 3].accessibilityFrame().minY, frame.maxY - 0.5, label) }
                }
                XCTAssertNil(table.accessibilityCell(forColumn: 0, row: 4), place)
                XCTAssertNil(table.accessibilityCell(forColumn: 3, row: 0), place)

                // The table gives a header for each column and for each row, as HTML has them,
                // and VoiceOver takes the one at a cell's column and at its row. A header that
                // is one cell on screen is that cell, which VoiceOver does not read under
                // itself. No cell names header cells of its own: VoiceOver quit when one did.
                let headers = table.accessibilityColumnHeaderUIElements() ?? []
                XCTAssertEqual(headed(headers), ["Station", "Opened", "Depth"], place)
                XCTAssertTrue(headers.elementsEqual(cells.prefix(3)) { $0 as AnyObject === $1 }, place)
                let rowHeaders = table.accessibilityRowHeaderUIElements() ?? []
                XCTAssertEqual(headed(rowHeaders), ["", "Alder", "Birch", "Cedar"], "\(place): one for each row, and no words for the header row")
                XCTAssertTrue(rowHeaders.dropFirst().elementsEqual([cells[3], cells[6], cells[9]]) { $0 as AnyObject === $1 }, place)
                let unheaded = try XCTUnwrap(rowHeaders.first as? ReaderTableHeaderElement, place)
                XCTAssertNil(unheaded.accessibilityValue(), place)
                XCTAssertNil(unheaded.accessibilityLabel(), place)
                XCTAssertEqual(unheaded.accessibilityRole(), .cell, "\(place): not a text without words")
                XCTAssertTrue(unheaded.accessibilityParent() as AnyObject === table, place)
                XCTAssertTrue(cells.allSatisfy { $0.accessibilityColumnHeaderUIElements() == nil && $0.accessibilityRowHeaderUIElements() == nil }, place)

                let columns = try XCTUnwrap(table.accessibilityColumns() as? [ReaderTableColumnElement], place)
                XCTAssertEqual(columns.map { $0.accessibilityIndex() }, [0, 1, 2], place)
                XCTAssertTrue(columns.allSatisfy { $0.accessibilityRole() == .column && $0.accessibilityParent() as AnyObject === table }, place)
                XCTAssertEqual(said(columns[1].accessibilityChildren()), ["Opened", "1901", "1934", "Reopened 1978"], place)
                XCTAssertTrue(columns[1].accessibilityHeader() as AnyObject === cells[1], place)
                XCTAssertEqual((table.accessibilityChildren() ?? []).count, 7, "\(place): its rows and its columns")

                // A cell offers what it can do itself.
                XCTAssertEqual(actions(cells[4]), ["Select Cell Text"], place)
                XCTAssertEqual(actions(cells[8]), [], "\(place): an empty cell has no words to select")
                XCTAssertEqual(actions(cells[10]), ["Select Cell Text", "Follow Link: Reopened 1978"], place)
            }

            let cells = try cells(of: tables[2])
            try perform("Select Cell Text", on: cells[5])
            try await reader.wait("\(flow): the cell's words selected") { reader.session.selection?.text == "Twelve metres" }
            XCTAssertNotNil(reader.session.selection?.range.start.tableCell, flow)
            canvas.clearSelection()
            let linked = ReaderTextPosition(section: 1, offset: 0)
            XCTAssertFalse(reader.isVisible(linked), "\(flow): the link's target must be off screen for this to show anything")
            try perform("Follow Link: Reopened 1978", on: cells[10])
            try await reader.wait("\(flow): the linked chapter") { reader.isVisible(linked) }
        }
    }

    /// A table the book marks as layout, and one that nothing marks as data, are given row by
    /// row as before: a group for each row that holds its cells' text areas.
    func testATableThatIsNotDataStaysAGroupForEachRow() async throws {
        let layout = "<table role='presentation'><tr><th>Left side</th><td>Right side</td></tr><tr><th>Lower left</th><td>Lower right</td></tr></table>"
        let plain = "<table><tr><td>First cell</td><td>Second cell</td></tr><tr><td>Third cell</td><td>Fourth cell</td></tr></table>"
        let book = try book("<p>Words before.</p>" + layout + "<p>Words between.</p>" + plain + "<p>Words after.</p>")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let given = try attachments(in: view)
            XCTAssertEqual(given.count, 4, flow)
            XCTAssertTrue(try tables(in: view).isEmpty, flow)
            for (_, element) in given {
                XCTAssertEqual(element.accessibilityRole(), .group, flow)
                XCTAssertEqual(element.accessibilityLabel(), "Table row", flow)
                XCTAssertEqual((element.accessibilityChildren() ?? []).compactMap { ($0 as? TableCellTextView)?.accessibilityRole() }, [.textArea, .textArea], flow)
            }
            XCTAssertEqual(given.flatMap { ($0.element.accessibilityChildren() ?? []).compactMap { ($0 as? TableCellTextView)?.accessibilityValue() } },
                           ["Left side", "Right side", "Lower left", "Lower right", "First cell", "Second cell", "Third cell", "Fourth cell"], flow)
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
            let tables = try tables(in: view)
            // A row says the cells whose words it shows: one a row above spans into it is said
            // once, in the row its words are drawn in, which in continuous scroll is its first.
            let names = tables.map { $0.accessibilityLabel() ?? "" }
            if scrolled {
                XCTAssertEqual(names, ["Service, Hours", "Leaves, Arrives", "Express, Nine, Noon", "Stopper, Ten, Three", "Nothing on Sunday"], flow)
            }
            XCTAssertEqual(names.flatMap { $0.components(separatedBy: ", ") }.sorted(),
                           ["Arrives", "Express", "Hours", "Leaves", "Nine", "Noon", "Nothing on Sunday", "Service", "Stopper", "Ten", "Three"], flow)
            let table = try XCTUnwrap(tables.first, flow)
            let cells = try cells(of: table)
            XCTAssertEqual(cells.map(said), ["Service", "Hours", "Leaves", "Arrives", "Express", "Nine", "Noon", "Stopper", "Ten", "Three",
                                             "Nothing on Sunday"], flow)
            XCTAssertEqual(table.accessibilityRowCount(), 5, flow)
            XCTAssertEqual(table.accessibilityColumnCount(), 3, flow)
            func cell(_ words: String) throws -> ReaderTableCellElement { try XCTUnwrap(cells.first { said($0) == words }, "\(flow): no cell \(words)") }
            XCTAssertEqual(try cell("Service").accessibilityRowIndexRange(), NSRange(location: 0, length: 2), flow)
            XCTAssertEqual(try cell("Service").accessibilityColumnIndexRange(), NSRange(location: 0, length: 1), flow)
            XCTAssertEqual(try cell("Hours").accessibilityColumnIndexRange(), NSRange(location: 1, length: 2), flow)
            XCTAssertEqual(try cell("Stopper").accessibilityRowIndexRange(), NSRange(location: 3, length: 2), flow)
            XCTAssertEqual(try cell("Nothing on Sunday").accessibilityRowIndexRange(), NSRange(location: 4, length: 1), flow)
            XCTAssertEqual(try cell("Nothing on Sunday").accessibilityColumnIndexRange(), NSRange(location: 1, length: 2), flow)
            // Moving down a column, VoiceOver asks for the cell of the next row: the one that covers it.
            let slots: [[String]] = [["Service", "Hours", "Hours"], ["Service", "Leaves", "Arrives"], ["Express", "Nine", "Noon"],
                                     ["Stopper", "Ten", "Three"], ["Stopper", "Nothing on Sunday", "Nothing on Sunday"]]
            for (row, names) in slots.enumerated() {
                for (column, name) in names.enumerated() {
                    XCTAssertTrue(table.accessibilityCell(forColumn: column, row: row) as AnyObject === (try cell(name)),
                                  "\(flow): row \(row), column \(column) is \(name)")
                }
            }
            // A cell that spans rows is as tall as they are, and stands in each column it covers.
            XCTAssertGreaterThan(try cell("Service").accessibilityFrame().height, try cell("Hours").accessibilityFrame().height * 1.5, flow)
            let columns = try XCTUnwrap(table.accessibilityColumns() as? [ReaderTableColumnElement], flow)
            XCTAssertEqual(said(columns[2].accessibilityChildren()), ["Hours", "Arrives", "Noon", "Three", "Nothing on Sunday"], flow)

            // A column under two header cells has one header that says both, top first: a
            // static text of its own, in no row, with their words.
            let headers = table.accessibilityColumnHeaderUIElements() ?? []
            XCTAssertEqual(headed(headers), ["Service", "Hours, Leaves", "Hours, Arrives"], flow)
            XCTAssertTrue(headers.first as AnyObject === (try cell("Service")), flow)
            for header in headers.dropFirst() {
                let name = try XCTUnwrap(header as? ReaderTableHeaderElement, flow)
                XCTAssertEqual(name.accessibilityRole(), .staticText, flow)
                XCTAssertTrue(name.accessibilityParent() as AnyObject === table, flow)
                XCTAssertNil(name.accessibilityChildren(), flow)
            }
            XCTAssertTrue((table.accessibilityColumnHeaderUIElements() ?? []).elementsEqual(headers) { $0 as AnyObject === $1 as AnyObject }, "\(flow): the same elements each time")
            XCTAssertTrue(columns[2].accessibilityHeader() as AnyObject === headers[2] as AnyObject, flow)
            XCTAssertEqual((table.accessibilityRowHeaderUIElements() ?? []).count, 0, "\(flow): no cell here heads a row")
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

    /// A table that goes on to the next page is, on each page, the rows that page shows. A row
    /// keeps its number in the whole table, and a column is still headed by its header cell on
    /// a page that does not show the header row: a header cell is given by name.
    func testATableSplitAcrossPagesKeepsItsRowsNumbersAndItsHeaders() async throws {
        let book = try book("<p>Words before the ledger.</p>" + Self.ledger(rows: 60) + "<p>Words after the ledger.</p>")
        let (_, canvas, _) = try await reader(book, scrolled: false)
        var read: [String] = [], pages = 0, nextRow = 0
        repeat {
            let column = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
            let tables = try tables(in: column)
            guard let table = tables.first else { break }
            let rows = try rows(of: table)
            XCTAssertEqual(tables.count, rows.count, "page \(pages + 1): a table at each of the page's rows")
            XCTAssertEqual(table.accessibilityRowCount(), 61, "page \(pages + 1): the rows of the whole table")
            XCTAssertEqual(rows.map { $0.accessibilityIndex() }, Array(nextRow..<nextRow + rows.count), "page \(pages + 1) goes on from the row the page before ended at")
            XCTAssertEqual(table.accessibilityVisibleRows()?.count, rows.count, "page \(pages + 1)")
            let cells = try cells(of: table)
            read += cells.map(said)
            XCTAssertEqual(cells.count, rows.count * 3, "page \(pages + 1): whole rows")
            for (index, cell) in cells.enumerated() {
                XCTAssertEqual(cell.accessibilityRowIndexRange(), NSRange(location: nextRow + index / 3, length: 1), "page \(pages + 1)")
                XCTAssertEqual(cell.accessibilityColumnIndexRange(), NSRange(location: index % 3, length: 1), "page \(pages + 1)")
                XCTAssertTrue(table.accessibilityCell(forColumn: index % 3, row: nextRow + index / 3) as AnyObject === cell, "page \(pages + 1)")
            }
            // Each row's table is named by that row and enters at it, whatever the page.
            for (index, entered) in tables.enumerated() {
                XCTAssertEqual(entered.accessibilityLabel(), cells[index * 3..<index * 3 + 3].map(said).joined(separator: ", "), "page \(pages + 1)")
                XCTAssertEqual((entered.accessibilitySelectedRows() as? [ReaderTableRowElement])?.map { $0.accessibilityIndex() }, [nextRow + index], "page \(pages + 1)")
            }
            // A row of another page is not here to move to.
            if nextRow > 0 { XCTAssertNil(table.accessibilityCell(forColumn: 0, row: nextRow - 1), "page \(pages + 1)") }
            XCTAssertNil(table.accessibilityCell(forColumn: 0, row: nextRow + rows.count), "page \(pages + 1)")
            let headers = table.accessibilityColumnHeaderUIElements() ?? []
            XCTAssertEqual(headed(headers), ["Entry", "Item", "Sum"], "page \(pages + 1): a column's header by its words")
            XCTAssertEqual((table.accessibilityRowHeaderUIElements() ?? []).count, 0, "page \(pages + 1)")
            for header in headers {
                // The header row's own page gives its cells; any other a name for each.
                XCTAssertEqual(cells.contains { $0 === header as AnyObject }, nextRow == 0, "page \(pages + 1)")
                if nextRow > 0 {
                    let name = try XCTUnwrap(header as? ReaderTableHeaderElement, "page \(pages + 1)")
                    XCTAssertTrue(name.accessibilityParent() as AnyObject === table, "page \(pages + 1): in no row")
                }
            }
            nextRow += rows.count
            pages += 1
        } while pages < 40 && canvas.turnPage(forward: true) == .turned
        XCTAssertGreaterThan(pages, 1, "the table must be longer than a page for this to show anything")
        XCTAssertEqual(read, Self.ledgerWords(rows: 60), "every cell once, in order, across \(pages) pages")
    }

    /// A row taller than a page continues on the next: on each page the cell is the same cell
    /// of the table, saying the words its continuation shows there, so they are said once
    /// across the pages. A cell is listed on the page where it has something to say: the short
    /// cell beside the tall one is centred in the row, so its words stand some pages in.
    func testACellContinuedAcrossPagesSaysEachPagesOwnWords() async throws {
        let wording = (1...2_400).map { "w\($0)" }
        let book = try book("<table><tr><th>Clause</th><th>Wording</th></tr><tr><td>Label</td><td>" + wording.joined(separator: " ")
                            + "</td></tr></table>")
        let (_, canvas, _) = try await reader(book, scrolled: false)
        var read: [String] = [], others: [String] = [], named: [String] = [], pages = 0, labelPage: Int?
        repeat {
            let column = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
            // The table is all its chapter holds; the page after its last is the next chapter's.
            let tables = try tables(in: column)
            guard let table = tables.first else { break }
            XCTAssertEqual(table.accessibilityRowCount(), 2)
            for cell in try cells(of: table) {
                let words = said(cell).split(whereSeparator: \.isWhitespace).map(String.init)
                if cell.accessibilityRowIndexRange().location == 1, cell.accessibilityColumnIndexRange().location == 1 {
                    read += words
                } else { others += words }
                if words == ["Label"] { labelPage = pages }
                XCTAssertFalse(words.isEmpty, "page \(pages + 1): no cell without words")
                XCTAssertFalse(cell.accessibilityFrame().isEmpty, "page \(pages + 1)")
            }
            XCTAssertEqual(headed(table.accessibilityColumnHeaderUIElements()), ["Clause", "Wording"], "page \(pages + 1)")
            // What VoiceOver says of each row of the page as it reads: the words shown there.
            named += tables.flatMap { ($0.accessibilityLabel() ?? "").replacingOccurrences(of: ",", with: "").split(whereSeparator: \.isWhitespace).map(String.init) }
            pages += 1
        } while pages < 40 && canvas.turnPage(forward: true) == .turned
        XCTAssertGreaterThan(pages, 3, "the row must be some pages tall for this to show anything")
        XCTAssertEqual(read, wording, "every word of the tall cell once, in order, across \(pages) pages")
        XCTAssertEqual(others.sorted(), ["Clause", "Label", "Wording"], "the other cells once, each on the page its words are on")
        XCTAssertEqual(named.sorted(), (wording + ["Clause", "Label", "Wording"]).sorted(), "and the rows' names say every word once")
        let found = try XCTUnwrap(labelPage)
        XCTAssertTrue(found > 0 && found < pages - 1, "the short cell's words stand in the middle of the row, on page \(found + 1) of \(pages)")
    }

    /// In continuous scroll one text view holds the whole book: a table holds every row,
    /// says which are on screen, and a cell off screen is labelled with its words until its
    /// text areas are there.
    func testInContinuousScrollATableHoldsEveryRowAndACellOffScreenIsLabelled() async throws {
        let book = try book("<p>Words before the ledger.</p>" + Self.ledger(rows: 60) + "<p>Words after the ledger.</p>")
        let (reader, _, view) = try await reader(book, scrolled: true)
        let tables = try tables(in: view)
        XCTAssertEqual(tables.count, 61, "a table at every row's character")
        XCTAssertEqual(tables[40].accessibilityLabel(), "Entry 40, Item 40, Sum 40", "named by its row though the row is off screen")
        XCTAssertEqual((tables[40].accessibilitySelectedRows() as? [ReaderTableRowElement])?.map { $0.accessibilityIndex() }, [40])
        let table = tables[0]
        let rows = try rows(of: table)
        XCTAssertEqual(rows.map { $0.accessibilityIndex() }, Array(0...60))
        XCTAssertEqual(try cells(of: table).map(said), Self.ledgerWords(rows: 60), "every cell once, in order")
        let visible = try XCTUnwrap(table.accessibilityVisibleRows() as? [ReaderTableRowElement])
        XCTAssertTrue(visible.count > 3 && visible.count < 40, "\(visible.count) rows on screen")
        XCTAssertEqual(visible.map { $0.accessibilityIndex() }, Array(0..<visible.count), "from the top of the table")
        let screen = NSAccessibility.screenRect(fromView: view, rect: view.visibleRect)
        XCTAssertTrue(visible.allSatisfy { $0.accessibilityFrame().intersects(screen) })
        XCTAssertEqual(table.accessibilityVisibleCells()?.count, visible.count * 3)

        // A cell far below the screen has no text area yet: it is labelled, and has its place.
        let far = try XCTUnwrap(table.accessibilityCell(forColumn: 1, row: 55) as? ReaderTableCellElement)
        XCTAssertEqual((far.accessibilityChildren() ?? []).count, 0)
        XCTAssertEqual(far.accessibilityLabel(), "Item 55")
        let header = try cells(of: rows[0])
        XCTAssertTrue((table.accessibilityColumnHeaderUIElements() ?? []).elementsEqual(header) { $0 as AnyObject === $1 }, "the header row is on screen")
        XCTAssertFalse(far.accessibilityFrame().isEmpty)
        XCTAssertFalse(far.accessibilityFrame().intersects(screen), "below the screen")
        XCTAssertFalse(visible.contains { $0 === rows[55] })

        // Brought on screen, the same cell holds its text area and offers what that can do.
        let scrollView = try XCTUnwrap(view.enclosingScrollView)
        let place = try XCTUnwrap(table.frame(ofRowAt: rows[55].location))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: place.minY - 100))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await reader.wait("the far cell's text area") { (far.accessibilityChildren() ?? []).count == 1 }
        XCTAssertNil(far.accessibilityLabel())
        XCTAssertEqual(said(far), "Item 55")
        XCTAssertEqual(actions(far), ["Select Cell Text"])
        XCTAssertTrue((table.accessibilityVisibleRows() as? [ReaderTableRowElement] ?? []).contains { $0 === rows[55] })
        XCTAssertTrue(table.accessibilityCell(forColumn: 1, row: 55) as AnyObject === far, "the same element")
        // The header row is now far above the screen and its cells hold no text areas, which
        // is where VoiceOver reads a header cell's words: the columns are headed by name.
        try await reader.wait("the header row's text areas gone") { !header[1].holdsText }
        let named = table.accessibilityColumnHeaderUIElements() ?? []
        XCTAssertEqual(headed(named), ["Entry", "Item", "Sum"])
        XCTAssertTrue(named.allSatisfy { $0 is ReaderTableHeaderElement })
    }

    /// A page turn gives the column other text: its tables are other elements, and one a
    /// client kept from the page before says nothing of the new page.
    func testAnotherPageGivesOtherTables() async throws {
        let book = try book("<p>Words before the ledger.</p>" + Self.ledger(rows: 60) + "<p>Words after the ledger.</p>")
        let (_, canvas, view) = try await reader(book, scrolled: false)
        let first = try XCTUnwrap(try tables(in: view).first)
        XCTAssertEqual(first.accessibilityLabel(), "Entry, Item, Sum")
        let kept = try XCTUnwrap(try cells(of: first).first)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let column = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        let second = try XCTUnwrap(try tables(in: column).first)
        XCTAssertFalse(second === first)
        XCTAssertGreaterThan(try XCTUnwrap(try rows(of: second).first?.accessibilityIndex()), 0)
        XCTAssertEqual(first.accessibilityRows()?.count, 0)
        XCTAssertTrue(first.accessibilityParent() as AnyObject === view, "still the column's")
        XCTAssertNil(first.accessibilityLabel())
        XCTAssertEqual(first.accessibilitySelectedRows()?.count, 0)
        XCTAssertNil(first.accessibilityCell(forColumn: 0, row: 0))
        XCTAssertEqual(kept.accessibilityChildren()?.count, 0)
        XCTAssertEqual(kept.accessibilityFrame(), .zero)
    }
}
#endif
