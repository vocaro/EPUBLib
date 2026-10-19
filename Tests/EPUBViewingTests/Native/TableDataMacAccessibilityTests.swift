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
/// that is not data is a group for each row, called by that row's words.
///
/// No assistive technology is driven here. The tests read the elements through AppKit's own
/// accessibility methods, which are what its bridge to a client calls. What VoiceOver says of
/// them, and that a client is given every attribute, is in doc/testing.md#voiceover-testing.
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

    /// The link a cell holds, where its words are one link and nothing else.
    private func link(of cell: ReaderTableCellElement) -> ReaderTableCellLinkElement? {
        (cell.accessibilityChildren() ?? []).lazy.compactMap { $0 as? ReaderTableCellLinkElement }.first
    }

    /// The text areas of a cell's words: what it holds, or what the link it holds does.
    private func textAreas(of cell: ReaderTableCellElement) -> [TableCellTextView] {
        ((link(of: cell)?.accessibilityChildren() ?? cell.accessibilityChildren()) ?? []).compactMap { $0 as? TableCellTextView }
    }

    /// The image a cell holds for each picture it shows.
    private func images(of cell: ReaderTableCellElement) -> [ReaderTableCellImageElement] {
        (cell.accessibilityChildren() ?? []).compactMap { $0 as? ReaderTableCellImageElement }
    }

    /// What a cell says: the words of its text areas and then what its images are called, or
    /// where it has neither its label, or the title of the link it holds.
    private func said(_ cell: ReaderTableCellElement) -> String {
        let views = textAreas(of: cell), pictures = images(of: cell)
        guard !views.isEmpty || !pictures.isEmpty else { return cell.accessibilityLabel() ?? link(of: cell)?.accessibilityTitle() ?? "" }
        return (views.map { $0.accessibilityValue() ?? "" } + pictures.map { $0.accessibilityLabel() ?? "" }).joined(separator: " ")
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
                    // into to read by word, and they answer to it. The cell that is one link
                    // holds that link, and the link its text area.
                    let views = textAreas(of: cell)
                    XCTAssertEqual(views.count, number == 8 ? 0 : 1, label)
                    XCTAssertNil(cell.accessibilityLabel(), "\(label): its text area says its words")
                    let holder: AnyObject = number == 10 ? try XCTUnwrap(link(of: cell), label) : cell
                    XCTAssertEqual(link(of: cell) != nil, number == 10, label)
                    XCTAssertTrue(views.allSatisfy { $0.accessibilityParent() as AnyObject === holder }, label)
                    XCTAssertEqual(cell.isAccessibilitySelectorAllowed(Self.press), number == 10, "\(label): pressed where it is one link")
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

    private static let press = #selector(NSAccessibilityElement.accessibilityPerformPress)

    private static let branches = """
    <table><thead><tr><th>Branch</th><th>Opened</th><th>Notes</th></tr></thead><tbody>
    <tr><th scope="row">Cedar</th><td><a href="notes.xhtml">Reopened <em>1978</em></a></td><td>See <a href="notes.xhtml">the note</a></td></tr>
    <tr><th scope="row"><a href="notes.xhtml">Dogwood</a></th><td><a href="notes.xhtml">First</a> <a href="notes.xhtml#second">Second</a></td><td></td></tr>
    </tbody></table>
    """

    /// A cell whose words are one link and nothing else is pressed to follow it, which is what
    /// VoiceOver asks of the item under its cursor at Control-Option-Space. A cell with words
    /// beside its link, with two links or with none has no press: its links are actions by
    /// their words.
    ///
    /// Such a cell holds a link, and the link its text areas, which is what makes VoiceOver
    /// say "hyperlink" as it comes to the cell (doc/testing.md). The link is called
    /// by the cell's words as well, which VoiceOver says once. A header cell that is one link
    /// is such a cell (`testAHeaderCellThatIsOneLinkHoldsALinkAndStillHeads`).
    func testACellThatIsOneLinkIsPressedToFollowItAndHoldsThatLink() async throws {
        let book = try book("<p>Words before the table.</p>" + Self.branches + "<p>Words after the table.</p>" + SessionCoverageBook.filler(120))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (reader, _, view) = try await reader(book, scrolled: scrolled)
            let table = try XCTUnwrap(try tables(in: view).last, flow)
            let cells = try cells(of: table)
            XCTAssertEqual(cells.map(said), ["Branch", "Opened", "Notes", "Cedar", "Reopened 1978", "See the note", "Dogwood", "First Second", ""], flow)
            XCTAssertEqual(cells.map { $0.isAccessibilitySelectorAllowed(Self.press) }, [false, false, false, false, true, false, true, false, false],
                           "\(flow): the cells that are one link, however its words are styled, and no other")
            XCTAssertTrue(cells.allSatisfy { $0.accessibilityRole() == .cell }, "\(flow): a cell that is pressed is still a cell of its row")
            XCTAssertEqual(actions(cells[4]), ["Select Cell Text", "Follow Link: Reopened 1978"], "\(flow): the link is an action by its words as well")
            XCTAssertEqual(actions(cells[5]), ["Select Cell Text", "Follow Link: the note"], flow)
            XCTAssertEqual(actions(cells[6]), ["Select Cell Text", "Follow Link: Dogwood"], flow)
            XCTAssertEqual(actions(cells[7]), ["Select Cell Text", "Follow Link: First", "Follow Link: Second"], flow)

            // The link is all the cell holds, with the cell's text area inside it, where the
            // cell stands. Its title is the cell's words, which its text area says as well.
            XCTAssertEqual(cells.map { link(of: $0) != nil }, [false, false, false, false, true, false, true, false, false],
                           "\(flow): the cells that are pressed, the header cell among them")
            let link = try XCTUnwrap(link(of: cells[4]), flow)
            XCTAssertEqual(cells[4].accessibilityChildren()?.count, 1, flow)
            XCTAssertTrue(cells[4].accessibilityVisibleChildren()?.first as AnyObject === link, flow)
            XCTAssertEqual(link.accessibilityRole(), .link, flow)
            XCTAssertEqual(link.accessibilitySubrole(), .textLink, "\(flow): the role of the reader's links in text, which VoiceOver calls a hyperlink")
            XCTAssertTrue(link.accessibilityParent() as AnyObject === cells[4], flow)
            XCTAssertEqual(link.accessibilityTitle(), "Reopened 1978", flow)
            XCTAssertNil(cells[4].accessibilityLabel(), flow)
            XCTAssertEqual(link.accessibilityFrame(), cells[4].accessibilityFrame(), flow)
            let inside = try XCTUnwrap(link.accessibilityChildren() as? [TableCellTextView], flow)
            XCTAssertEqual(inside.map { $0.accessibilityValue() }, ["Reopened 1978"], flow)
            XCTAssertTrue(inside.first?.accessibilityParent() as AnyObject === link, flow)
            XCTAssertEqual(link.accessibilityVisibleChildren()?.count, 1, flow)

            let linked = ReaderTextPosition(section: 1, offset: 0)
            XCTAssertFalse(reader.isVisible(linked), "\(flow): the link's target must be off screen for this to show anything")
            for index in cells.indices where index != 4 && index != 6 {
                XCTAssertFalse(cells[index].accessibilityPerformPress(), "\(flow): \(said(cells[index])) is not pressed")
            }
            XCTAssertFalse(reader.isVisible(linked), "\(flow): and a press of one follows nothing")
            XCTAssertTrue(cells[4].accessibilityPerformPress(), flow)
            try await reader.wait("\(flow): the linked chapter") { reader.isVisible(linked) }
        }
        // The link a cell holds is pressed as the cell is.
        let (reader, _, view) = try await reader(book, scrolled: false)
        let cells = try cells(of: try XCTUnwrap(try tables(in: view).last))
        let linked = ReaderTextPosition(section: 1, offset: 0)
        XCTAssertFalse(reader.isVisible(linked))
        XCTAssertTrue(try XCTUnwrap(link(of: cells[4])).accessibilityPerformPress())
        try await reader.wait("the linked chapter from the cell's link") { reader.isVisible(linked) }
    }

    private static let routes = """
    <table><thead><tr><th>Route</th><th><a href="notes.xhtml">Built</a></th><th>Length</th></tr></thead><tbody>
    <tr><th scope="row"><a href="notes.xhtml">Dogwood</a></th><td>1912</td><td>Nine miles</td></tr>
    <tr><th scope="row"><a href="notes.xhtml">Elm</a></th><td>1947</td><td>Four miles</td></tr>
    <tr><th scope="row">Fir</th><td><a href="notes.xhtml">Relaid 1960</a></td><td>Six miles</td></tr>
    </tbody></table>
    """

    /// A header cell whose words are one link is a link cell like any other: pressed to follow
    /// it, and holding a link with its text area inside, so that VoiceOver says "Dogwood
    /// hyperlink" as it comes to it. It is still what heads its row or its column, the cell
    /// itself, which VoiceOver does not read under itself.
    ///
    /// Before each cell a header cell heads, VoiceOver reads it by what each thing it holds is
    /// called, and looks no further in: a text area's value, and a link's title. So the link
    /// is called by the cell's words. Held without a title, it left VoiceOver saying "1912"
    /// where it says "Dogwood 1912", and the column's and the row's numbers for their headers
    /// (doc/testing.md#voiceover-testing).
    func testAHeaderCellThatIsOneLinkHoldsALinkAndStillHeads() async throws {
        let book = try book("<p>Words before the routes.</p>" + Self.routes + "<p>Words after the routes.</p>" + SessionCoverageBook.filler(120))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (reader, _, view) = try await reader(book, scrolled: scrolled)
            let table = try XCTUnwrap(try tables(in: view).first, flow)
            let cells = try cells(of: table)
            let words = ["Route", "Built", "Length", "Dogwood", "1912", "Nine miles", "Elm", "1947", "Four miles", "Fir", "Relaid 1960", "Six miles"]
            XCTAssertEqual(cells.map(said), words, flow)
            let links = [1, 3, 6, 10]
            XCTAssertEqual(cells.indices.filter { link(of: cells[$0]) != nil }, links, "\(flow): two rows' header cells, a column's, and a cell under it")
            XCTAssertEqual(cells.indices.filter { cells[$0].isAccessibilitySelectorAllowed(Self.press) }, links, flow)
            XCTAssertTrue(cells.allSatisfy { $0.accessibilityRole() == .cell }, flow)
            for index in links {
                let label = "\(flow): \(words[index])"
                let link = try XCTUnwrap(link(of: cells[index]), label)
                XCTAssertEqual(cells[index].accessibilityChildren()?.count, 1, "\(label): the link is all the cell holds")
                XCTAssertNil(cells[index].accessibilityLabel(), label)
                XCTAssertEqual(link.accessibilityRole(), .link, label)
                XCTAssertEqual(link.accessibilitySubrole(), .textLink, label)
                XCTAssertEqual(link.accessibilityTitle(), words[index], "\(label): what VoiceOver reads a header cell by")
                let inside = try XCTUnwrap(link.accessibilityChildren() as? [TableCellTextView], label)
                XCTAssertEqual(inside.map { $0.accessibilityValue() }, [words[index]], label)
                XCTAssertTrue(inside.first?.accessibilityParent() as AnyObject === link, label)
                XCTAssertEqual(actions(cells[index]), ["Select Cell Text", "Follow Link: \(words[index])"], label)
            }
            // The header of a column and of a row is its header cell itself, link or not.
            let headers = table.accessibilityColumnHeaderUIElements() ?? []
            XCTAssertEqual(headed(headers), ["Route", "Built", "Length"], flow)
            XCTAssertTrue(headers.elementsEqual(cells.prefix(3)) { $0 as AnyObject === $1 }, flow)
            let rowHeaders = table.accessibilityRowHeaderUIElements() ?? []
            XCTAssertEqual(headed(rowHeaders), ["", "Dogwood", "Elm", "Fir"], flow)
            XCTAssertTrue(rowHeaders.dropFirst().elementsEqual([cells[3], cells[6], cells[9]]) { $0 as AnyObject === $1 }, flow)
            let columns = try XCTUnwrap(table.accessibilityColumns() as? [ReaderTableColumnElement], flow)
            XCTAssertTrue(columns[1].accessibilityHeader() as AnyObject === cells[1], flow)
            XCTAssertTrue(cells.allSatisfy { $0.accessibilityColumnHeaderUIElements() == nil && $0.accessibilityRowHeaderUIElements() == nil }, flow)

            // A header cell is pressed to follow its link: a row's in pages, the column's in
            // continuous scroll.
            let linked = ReaderTextPosition(section: 1, offset: 0)
            XCTAssertFalse(reader.isVisible(linked), "\(flow): the link's target must be off screen for this to show anything")
            XCTAssertTrue(cells[scrolled ? 1 : 6].accessibilityPerformPress(), flow)
            try await reader.wait("\(flow): the linked chapter") { reader.isVisible(linked) }
        }
    }

    /// A cell's press follows its link from the text view that shows the link. In continuous
    /// scroll a cell far off the screen has none: it says it is pressed, since that is what it
    /// is, and its press does nothing until it is brought on screen, where VoiceOver's cursor
    /// brings it. Until then the link it holds has the cell's words for its title and nothing
    /// inside, so that VoiceOver says the same of a link cell on the screen and off it. A
    /// header cell that is a link heads its column by name while it is off screen, as any
    /// header cell does. A cell kept from text the view no longer shows has no press and
    /// holds nothing.
    func testACellThatIsOneLinkOffScreenHoldsALinkTitledWithItsWords() async throws {
        let entries = (1...60).map { String(format: "<tr><td>Entry %02d</td><td><a href=\"notes.xhtml\">Note %02d</a></td></tr>", $0, $0) }.joined()
        let book = try book("<p>Words before the ledger.</p><table><thead><tr><th>Entry</th><th><a href=\"notes.xhtml\">Note</a></th></tr></thead><tbody>"
                            + entries + "</tbody></table><p>Words after the ledger.</p>")
        let (reader, _, view) = try await reader(book, scrolled: true)
        let table = try XCTUnwrap(try tables(in: view).first)
        let far = try XCTUnwrap(table.accessibilityCell(forColumn: 1, row: 55) as? ReaderTableCellElement)
        let link = try XCTUnwrap(link(of: far))
        XCTAssertEqual(link.accessibilityTitle(), "Note 55", "off screen: the link says the cell's words")
        XCTAssertEqual(link.accessibilityChildren()?.count, 0, "and holds no text area")
        XCTAssertNil(far.accessibilityLabel(), "the cell is not labelled with them as well")
        XCTAssertEqual(said(far), "Note 55")
        XCTAssertEqual(actions(far), [], "its actions come from its text area")
        XCTAssertTrue(far.isAccessibilitySelectorAllowed(Self.press))
        let linked = ReaderTextPosition(section: 1, offset: 0)
        XCTAssertFalse(far.accessibilityPerformPress(), "nothing shows the link to follow it from")
        XCTAssertFalse(link.accessibilityPerformPress())
        XCTAssertFalse(reader.isVisible(linked))
        let heading = try XCTUnwrap(table.accessibilityCell(forColumn: 1, row: 0) as? ReaderTableCellElement)
        XCTAssertTrue(table.accessibilityColumnHeaderUIElements()?.last as AnyObject === heading, "the header cell is on screen, and heads its column itself")
        XCTAssertEqual(textAreas(of: heading).count, 1)

        let scrollView = try XCTUnwrap(view.enclosingScrollView)
        let place = try XCTUnwrap(table.frame(ofRowAt: try rows(of: table)[55].location))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: place.minY - 100))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await reader.wait("the far cell's text area") { self.textAreas(of: far).count == 1 }
        XCTAssertTrue(self.link(of: far) === link, "the same link")
        XCTAssertEqual(link.accessibilityTitle(), "Note 55", "on screen it is called the same, and its text area says the words too")
        XCTAssertEqual(said(far), "Note 55")
        XCTAssertEqual(actions(far), ["Select Cell Text", "Follow Link: Note 55"])
        // The header row is now far above the screen: the header cell that is a link holds a
        // link with nothing inside, and its column is headed by name.
        try await reader.wait("the header cell's text area gone") { !heading.holdsItsWords }
        XCTAssertEqual(self.link(of: heading)?.accessibilityTitle(), "Note")
        XCTAssertEqual(self.link(of: heading)?.accessibilityChildren()?.count, 0)
        let named = table.accessibilityColumnHeaderUIElements() ?? []
        XCTAssertEqual(headed(named), ["Entry", "Note"])
        XCTAssertTrue(named.allSatisfy { $0 is ReaderTableHeaderElement })
        XCTAssertFalse(reader.isVisible(linked), "the link's target must be off screen for this to show anything")
        XCTAssertTrue(far.accessibilityPerformPress())
        try await reader.wait("the linked chapter") { reader.isVisible(linked) }

        // In pages the linked chapter is other text in the column: the cell is of a table
        // that has gone. It is pressed for nothing, and neither it nor its link holds anything.
        let (paged, _, column) = try await self.reader(book, scrolled: false)
        let kept = try XCTUnwrap(try XCTUnwrap(try tables(in: column).first).accessibilityCell(forColumn: 1, row: 1) as? ReaderTableCellElement)
        let keptLink = try XCTUnwrap(self.link(of: kept))
        XCTAssertEqual(said(kept), "Note 01")
        XCTAssertTrue(kept.isAccessibilitySelectorAllowed(Self.press))
        XCTAssertTrue(kept.accessibilityPerformPress())
        try await paged.wait("the linked chapter in pages") { paged.isVisible(linked) }
        XCTAssertFalse(kept.isAccessibilitySelectorAllowed(Self.press), "the page that held the cell has gone")
        XCTAssertFalse(kept.accessibilityPerformPress())
        XCTAssertFalse(keptLink.accessibilityPerformPress())
        XCTAssertEqual(kept.accessibilityChildren()?.count, 0)
        XCTAssertEqual(keptLink.accessibilityChildren()?.count, 0)
        XCTAssertEqual(keptLink.accessibilityFrame(), .zero)
    }

    private static let pictured = """
    <table><thead><tr><th>Mark</th><th>Meaning</th></tr></thead><tbody>
    <tr><td><img src="square.svg" alt="Blue square"/></td><td><img src="square.svg"/></td></tr>
    <tr><td>Worn <img src="square.svg" alt="Blue crest"/> daily</td><td><img src="square.svg" alt=""/></td></tr>
    <tr><th scope="row"><img src="square.svg" alt="Blue shield"/></th>
    <td><img src="square.svg" alt=""/> <img src="square.svg" alt="Blue ring"/> <img src="square.svg" alt="Blue star"/></td></tr>
    <tr><td><a href="notes.xhtml"><img src="square.svg" alt="Blue gate"/></a></td><td><hr/></td></tr>
    </tbody></table>
    """

    private func picturedBook(_ body: String) throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", body, title: "Tables"),
            SessionCoverageBook.Section("notes", "<h1>Notes</h1><p>The linked note.</p>", title: "Notes")],
            manifest: "<item id=\"square\" href=\"square.svg\" media-type=\"image/svg+xml\"/>", files: ["OPS/square.svg": Self.square]))
    }

    /// A cell that shows pictures and nothing else holds an image for each of them, called by
    /// the picture's words, in place of its text area. VoiceOver says what a cell holds, a
    /// text area by its characters, and a picture's is the attachment's character: it said
    /// the column's header and that character at such a cell, for a described picture as for
    /// any other, where it now says "Blue badge image" (doc/testing.md). A picture
    /// nobody describes is an image without a name, which VoiceOver says in its own word, and
    /// decoration is no image: a cell of decoration alone holds nothing, as an empty one
    /// does. A cell that shows a picture among words holds its text area, where VoiceOver
    /// reads by word, and then the picture's image, which VoiceOver says after the words. A
    /// cell that is a link holds its link, whatever the link shows, and a rule is no picture.
    func testACellThatShowsPicturesHoldsAnImageForEach() async throws {
        let book = try picturedBook("<p>Words before the table.</p>" + Self.pictured + "<p>Words after the table.</p>" + SessionCoverageBook.filler(120))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, canvas, view) = try await reader(book, scrolled: scrolled)
            let tables = try tables(in: view)
            XCTAssertEqual(tables.map { $0.accessibilityLabel() },
                           ["Mark, Meaning", "Blue square", "Worn Blue crest daily", "Blue shield, Blue ring Blue star", "Blue gate"],
                           "\(flow): a row is still called by its cells' words, a picture's among them")
            let table = try XCTUnwrap(tables.first, flow)
            let cells = try cells(of: table)
            XCTAssertEqual(cells.count, 10, flow)
            XCTAssertEqual(cells.map { images(of: $0).map { $0.accessibilityLabel() } },
                           [[], [], ["Blue square"], [nil], ["Blue crest"], [], ["Blue shield"], ["Blue ring", "Blue star"], [], []],
                           "\(flow): an image for each picture that says something, and none for a link's or for decoration")
            XCTAssertEqual(cells.map { textAreas(of: $0).map { $0.accessibilityValue() ?? "" } },
                           [["Mark"], ["Meaning"], [], [], ["Worn \u{FFFC} daily"], [], [], [], ["\u{FFFC}"], ["\u{FFFC}"]],
                           "\(flow): a text area for words, for a picture among them, for a link and for a rule, and none where a cell shows pictures alone")
            XCTAssertEqual(cells.map { $0.accessibilityChildren()?.count }, [1, 1, 1, 1, 2, 0, 1, 2, 1, 1], "\(flow): a cell of decoration alone holds nothing")
            XCTAssertTrue(cells[4].accessibilityChildren()?.first is TableCellTextView, "\(flow): a picture among words comes after the words' text area")
            XCTAssertTrue(textAreas(of: cells[4]).first?.accessibilityParent() as AnyObject === cells[4], flow)
            XCTAssertEqual(link(of: cells[8]) != nil, true, "\(flow): the cell that is a link holds its link, though the link is a picture")
            XCTAssertTrue(cells.allSatisfy { $0.accessibilityLabel() == nil }, "\(flow): no cell is called by its words as well")
            XCTAssertEqual(cells.map(said), ["Mark", "Meaning", "Blue square", "", "Worn \u{FFFC} daily Blue crest", "", "Blue shield", "Blue ring Blue star",
                                             "\u{FFFC}", "\u{FFFC}"], flow)

            for (number, cell) in cells.enumerated() {
                for (order, image) in images(of: cell).enumerated() {
                    let label = "\(flow), cell \(number), image \(order)"
                    XCTAssertEqual(image.accessibilityRole(), .image, label)
                    XCTAssertTrue(image.accessibilityParent() as AnyObject === cell, label)
                    XCTAssertEqual(image.accessibilityChildren()?.count ?? 0, 0, label)
                    // VoiceOver read an image's help into the cell's phrase each time it came to the cell.
                    XCTAssertNil(image.accessibilityHelp(), label)
                    XCTAssertTrue((cell.accessibilityVisibleChildren() ?? []).compactMap { $0 as? ReaderTableCellImageElement }[order] === image, label)
                    // It stands where its picture is drawn, inside its cell: the picture's 32
                    // points across, and down the line the picture stands on.
                    let frame = image.accessibilityFrame()
                    XCTAssertEqual(frame.width, 32, accuracy: 0.5, label)
                    XCTAssertGreaterThanOrEqual(frame.height, 31.5, label)
                    XCTAssertTrue(cell.accessibilityFrame().insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(label): \(frame) in \(cell.accessibilityFrame())")
                }
                // Asked again, a cell gives the images it gave: VoiceOver asks an element what it is after the read that gave it.
                XCTAssertTrue(images(of: cell).elementsEqual(images(of: cell)) { $0 === $1 }, "\(flow), cell \(number)")
            }
            let pair = images(of: cells[7])
            XCTAssertLessThanOrEqual(pair[0].accessibilityFrame().maxX, pair[1].accessibilityFrame().minX + 0.5, "\(flow): each of two pictures in its own place")

            // A picture is shown larger from its image as from its cell, and its cell offers
            // what it offered: a described picture's words are still there to select.
            XCTAssertEqual(cells.map(actions), [["Select Cell Text"], ["Select Cell Text"], ["Inspect Image: Blue square", "Select Cell Text"], ["Inspect Image"],
                                                ["Inspect Image: Blue crest", "Select Cell Text"], [], ["Inspect Image: Blue shield", "Select Cell Text"],
                                                ["Inspect Image: Blue ring", "Inspect Image: Blue star", "Select Cell Text"],
                                                ["Inspect Image: Blue gate", "Select Cell Text", "Follow Link: Blue gate"], []], flow)
            XCTAssertEqual([cells[2], cells[3], cells[4], cells[7]].flatMap { images(of: $0) }.map { ($0.accessibilityCustomActions() ?? []).map(\.name) },
                           [["Inspect Image: Blue square"], ["Inspect Image"], ["Inspect Image: Blue crest"], ["Inspect Image: Blue ring"],
                            ["Inspect Image: Blue star"]], flow)
            for image in images(of: cells[3]) + images(of: cells[4]) + [pair[1]] {
                XCTAssertNil(canvas.imageInspector, flow)
                let action = try XCTUnwrap(image.accessibilityCustomActions()?.first, flow)
                XCTAssertTrue(try XCTUnwrap(action.handler, flow)(), "\(flow): \(action.name)")
                XCTAssertNotNil(canvas.imageInspector, "\(flow): \(action.name)")
                canvas.imageInspector?.close()
            }
            for (cell, name) in [(cells[2], "Inspect Image: Blue square"), (cells[4], "Inspect Image: Blue crest"), (cells[7], "Inspect Image: Blue star")] {
                XCTAssertNil(canvas.imageInspector, flow)
                try perform(name, on: cell)
                XCTAssertNotNil(canvas.imageInspector, "\(flow): \(name) from its cell")
                canvas.imageInspector?.close()
            }

            // A header cell that is a picture is still what heads its row: VoiceOver reads a
            // header cell by what the things it holds are called, and does not read a cell
            // under itself.
            let rowHeaders = table.accessibilityRowHeaderUIElements() ?? []
            XCTAssertEqual(headed(rowHeaders), ["", "", "", "Blue shield", ""], flow)
            XCTAssertTrue(rowHeaders[3] as AnyObject === cells[6], flow)
        }
    }

    /// An image needs no text area, so a cell far off the screen in continuous scroll that
    /// shows a picture and nothing else holds the image it holds on screen: VoiceOver is given
    /// the same of it wherever the view is. A cell of words there is labelled with them, a
    /// picture's among them, and holds nothing until its text area is on screen. A cell kept
    /// from text the view no longer shows holds nothing, and an image kept from it is called
    /// nothing.
    func testACellThatShowsAPictureOffScreenHoldsItsImage() async throws {
        let entries = (1...60).map {
            String(format: "<tr><td>Entry %02d</td><td><img src=\"square.svg\" alt=\"Mark %02d\"/></td><td>Kept <img src=\"square.svg\" alt=\"Seal %02d\"/></td></tr>", $0, $0, $0)
        }.joined()
        let book = try picturedBook("<p>Words before the ledger.</p><table><thead><tr><th>Entry</th><th>Mark</th><th>Seal</th></tr></thead><tbody>" + entries
                                    + "</tbody></table><p>Words after the ledger.</p>")
        let (_, _, view) = try await reader(book, scrolled: true)
        let table = try XCTUnwrap(try tables(in: view).first)
        let far = try XCTUnwrap(table.accessibilityCell(forColumn: 1, row: 55) as? ReaderTableCellElement)
        let beside = try XCTUnwrap(table.accessibilityCell(forColumn: 0, row: 55) as? ReaderTableCellElement)
        XCTAssertEqual(beside.accessibilityLabel(), "Entry 55", "off screen a cell of words is labelled with them")
        XCTAssertEqual(beside.accessibilityChildren()?.count, 0)
        let among = try XCTUnwrap(table.accessibilityCell(forColumn: 2, row: 55) as? ReaderTableCellElement)
        XCTAssertEqual(among.accessibilityLabel(), "Kept Seal 55", "and so is one with a picture among its words, the picture's too")
        XCTAssertEqual(among.accessibilityChildren()?.count, 0, "with no image to say them twice")
        let image = try XCTUnwrap(images(of: far).first)
        XCTAssertEqual(far.accessibilityChildren()?.count, 1)
        XCTAssertEqual(image.accessibilityLabel(), "Mark 55")
        XCTAssertNil(far.accessibilityLabel(), "the cell is not labelled with them as well")
        XCTAssertEqual(actions(far), ["Inspect Image: Mark 55"], "selecting its words takes its text area")
        XCTAssertFalse(image.accessibilityFrame().isEmpty)
        XCTAssertTrue(far.accessibilityFrame().insetBy(dx: -0.5, dy: -0.5).contains(image.accessibilityFrame()))

        let scrollView = try XCTUnwrap(view.enclosingScrollView)
        let place = try XCTUnwrap(table.frame(ofRowAt: try rows(of: table)[55].location))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: place.minY - 100))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await readers[0].wait("the far cell's actions") { self.actions(far) == ["Inspect Image: Mark 55", "Select Cell Text"] }
        XCTAssertTrue(images(of: far).first === image, "on screen it is the same image")
        XCTAssertEqual(far.accessibilityChildren()?.count, 1, "and no text area beside it")
        XCTAssertNil(far.accessibilityLabel())
        XCTAssertEqual(said(among), "Kept \u{FFFC} Seal 55", "on screen the cell of words holds its text area, and then its picture's image")
        XCTAssertNil(among.accessibilityLabel())

        // In pages another chapter is other text in the column: the cell is of a table that has gone.
        let (paged, _, column) = try await reader(book, scrolled: false)
        let kept = try XCTUnwrap(try XCTUnwrap(try tables(in: column).first).accessibilityCell(forColumn: 1, row: 1) as? ReaderTableCellElement)
        let keptImage = try XCTUnwrap(images(of: kept).first)
        XCTAssertEqual(keptImage.accessibilityLabel(), "Mark 01")
        let linked = ReaderTextPosition(section: 1, offset: 0)
        try await paged.session.send(.navigate(href: "OPS/notes.xhtml"))
        try await paged.wait("the other chapter in pages") { paged.isVisible(linked) }
        XCTAssertEqual(kept.accessibilityChildren()?.count, 0)
        XCTAssertNil(keptImage.accessibilityLabel())
        XCTAssertNil(keptImage.accessibilityCustomActions())
        XCTAssertEqual(keptImage.accessibilityFrame(), .zero)
    }

    /// What the text areas a row's group holds say, in order.
    private func held(_ element: NSAccessibilityElement) -> [String] {
        (element.accessibilityChildren() ?? []).compactMap { ($0 as? TableCellTextView)?.accessibilityValue() }
    }

    /// A table the book marks as layout, and one that nothing marks as data, are given row by
    /// row: a group for each row that holds its cells' text areas. VoiceOver says the group's
    /// label and "group" as it reads the text, so a row is called by its cells' words, as a
    /// row of a table of data is. Called "Table row", every row said that and none of its words.
    func testATableThatIsNotDataIsAGroupForEachRowCalledByItsWords() async throws {
        let layout = "<table role='presentation'><tr><th>Left side</th><td>Right side</td></tr><tr><th>Lower left</th><td>Lower right</td></tr></table>"
        let plain = "<table><tr><td>First cell</td><td>Second cell</td></tr><tr><td>Third cell</td><td>Fourth cell</td></tr></table>"
        let book = try book("<p>Words before.</p>" + layout + "<p>Words between.</p>" + plain + "<p>Words after.</p>")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let given = try attachments(in: view)
            XCTAssertEqual(given.count, 4, flow)
            XCTAssertTrue(try tables(in: view).isEmpty, flow)
            XCTAssertEqual(given.map { $0.element.accessibilityLabel() },
                           ["Left side, Right side", "Lower left, Lower right", "First cell, Second cell", "Third cell, Fourth cell"], flow)
            for (location, element) in given {
                XCTAssertEqual(element.accessibilityRole(), .group, flow)
                XCTAssertTrue(element.accessibilityParent() as AnyObject === view, flow)
                XCTAssertFalse(element.accessibilityFrameInParentSpace().isEmpty, flow)
                XCTAssertEqual((element.accessibilityChildren() ?? []).compactMap { ($0 as? TableCellTextView)?.accessibilityRole() }, [.textArea, .textArea], flow)
                // What it is called is what going into it reads, cell by cell.
                XCTAssertEqual(element.accessibilityLabel(), held(element).joined(separator: ", "), flow)
                // Asked for one row's character, as a line or a word is, the text gives the same element.
                let one = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: location, length: 1)))
                XCTAssertTrue(one.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil) as AnyObject === element, flow)
            }
            XCTAssertEqual(given.flatMap { held($0.element) },
                           ["Left side", "Right side", "Lower left", "Lower right", "First cell", "Second cell", "Third cell", "Fourth cell"], flow)
        }
    }

    private static let square = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"#07c\"/></svg>"

    /// A row is called by the words its cells have. A cell without any is left out, with no
    /// pause said for it; a picture's description is among its cell's words; and a row that
    /// shows pictures nobody describes has no words to be called by, and is called nothing,
    /// for VoiceOver to say what the group holds in its own words. Such a row has no help
    /// either, which VoiceOver would read in a missing name's place. A row of a table of
    /// data that shows a picture is still its table.
    func testARowIsCalledByTheWordsItsCellsHave() async throws {
        let rows = "<tr><td>Alone</td><td></td><td>After a gap</td></tr>"
            + "<tr><td><img src='square.svg' alt='Blue square'/></td><td>Beside it</td><td>Decoration <img src='square.svg' alt=''/> passed</td></tr>"
            + "<tr><td><img src='square.svg'/></td><td></td><td><img src='square.svg'/></td></tr>"
        let data = "<table><tr><th>Mark</th><th>Meaning</th></tr><tr><td><img src='square.svg' alt='Blue square'/></td><td>Open</td></tr></table>"
        let book = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", "<p>Words before.</p><table role='presentation'>" + rows + "</table><p>Words between.</p>" + data, title: "Tables")],
            manifest: "<item id=\"square\" href=\"square.svg\" media-type=\"image/svg+xml\"/>", files: ["OPS/square.svg": Self.square]))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let given = try attachments(in: view)
            XCTAssertEqual(given.count, 5, flow)
            XCTAssertEqual(given.prefix(3).map { $0.element.accessibilityLabel() },
                           ["Alone, After a gap", "Blue square, Beside it, Decoration passed", nil], flow)
            XCTAssertTrue(given.prefix(3).allSatisfy { $0.element.accessibilityRole() == .group }, flow)
            XCTAssertEqual(given.prefix(3).map { $0.element.accessibilityHelp() },
                           [nil, ReaderImageInspection.accessibilityHelp, nil], flow)
            // A row's pictures are shown from the row, whatever it is called.
            XCTAssertEqual(given.prefix(3).map { ($0.element.accessibilityCustomActions() ?? []).map(\.name) },
                           [[], ["Inspect Image: Blue square"], ["Inspect Image", "Inspect Image"]], flow)
            XCTAssertEqual(try tables(in: view).map { $0.accessibilityLabel() }, ["Mark, Meaning", "Blue square, Open"], flow)
        }
    }

    /// The rows that space out a table used for layout: two cells that hold nothing, two that
    /// hold decoration alone, and one cell that holds nothing across both columns.
    private static let gaps = ["<tr><td></td><td></td></tr>",
                               "<tr><td><img src='square.svg' alt=''/></td><td><img src='square.svg' alt=''/></td></tr>",
                               "<tr><td colspan='2'></td></tr>"]

    /// Rows of two cells of words, with one of those rows after each but the last.
    private static func gapped(_ rows: [(String, String)]) -> String {
        let worded = rows.map { "<tr><td>\($0.0)</td><td>\($0.1)</td></tr>" }
        return worded[0] + zip(gaps, worded.dropFirst()).map { $0 + $1 }.joined()
    }

    private func pictured(_ body: String) throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([SessionCoverageBook.Section("tables", body, title: "Tables")],
            manifest: "<item id=\"square\" href=\"square.svg\" media-type=\"image/svg+xml\"/>", files: ["OPS/square.svg": Self.square]))
    }

    /// The characters a client reads the view's text by, and where each table row stands in them.
    private func text(of view: ReaderTextView) throws -> (shown: NSRange, rows: [Int]) {
        let shown = view.isPageColumn ? view.shownCharacters : NSRange(location: 0, length: view.textLength)
        var rows: [Int] = []
        try XCTUnwrap(view.contentStorage.textStorage).enumerateAttribute(.attachment, in: shown) { value, run, _ in
            if value is TableRowAttachment { rows.append(run.location) }
        }
        return (shown, rows)
    }

    /// The lines an assistive client is given, from the first to the last the text has.
    private func lines(of view: ReaderTextView, in shown: NSRange) -> [NSRange] {
        var lines: [NSRange] = []
        while lines.count < 200, lines.last.map(NSMaxRange) ?? 0 < NSMaxRange(shown) {
            let range = view.accessibilityRange(forLine: lines.count)
            guard range.location != NSNotFound, range.length > 0 else { break }
            lines.append(range)
        }
        return lines
    }

    /// A row that has nothing to say, of cells that hold nothing or decoration alone, is
    /// nothing for VoiceOver to stop on, in a table marked as layout and in a table of data:
    /// the text gives no element at its character, gives the character and the break after it
    /// as spaces, and gives its line as part of the line after. VoiceOver stopped in silence
    /// at a character with no element, said "text text group" of a group of decoration and
    /// "table" of a table without a name, stops on any line of its own, and says of a line
    /// what comes before its first break. The rows each side are a line apart, the row of
    /// words ends its line, where VoiceOver goes into it, and inside a table of data the row
    /// is still a row.
    func testARowWithNothingToSayIsNothingToStopOn() async throws {
        let layout = "<table role='presentation'>"
            + Self.gapped([("Upper near", "Upper far"), ("Middle near", "Middle far"), ("Lower near", "Lower far"), ("Last near", "Last far")]) + "</table>"
        let data = "<table><tr><th>Tree</th><th>Tally</th></tr>" + Self.gapped([("Oak", "Nine"), ("Elm", "Four"), ("Ash", "Six"), ("Yew", "Two")]) + "</table>"
        let book = try pictured("<p>Words before.</p>" + layout + "<p>Words between.</p>" + data + "<p>Words after.</p>")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let (shown, rows) = try text(of: view)
            XCTAssertEqual(rows.count, 15, flow)
            let silent = [1, 3, 5, 9, 11, 13].map { rows[$0] }, worded = rows.filter { !silent.contains($0) }

            let given = try attachments(in: view)
            XCTAssertEqual(given.map(\.location), worded, flow)
            XCTAssertEqual(given.map { $0.element.accessibilityLabel() },
                           ["Upper near, Upper far", "Middle near, Middle far", "Lower near, Lower far", "Last near, Last far",
                            "Tree, Tally", "Oak, Nine", "Elm, Four", "Ash, Six", "Yew, Two"], flow)
            XCTAssertEqual(given.map { $0.element.accessibilityRole() }, Array(repeating: .group, count: 4) + Array(repeating: .table, count: 5), flow)

            // A space for a character, so that every range matches the text, and the break
            // after every other row as it was.
            let rich = try XCTUnwrap(view.accessibilityAttributedString(for: shown))
            let read = [try XCTUnwrap(view.accessibilityValue()), try XCTUnwrap(view.accessibilityString(for: shown)), rich.string]
            for characters in read.map({ $0 as NSString }) {
                XCTAssertEqual(characters.length, shown.length, flow)
                XCTAssertEqual(rows.map { characters.character(at: $0 - shown.location) }, rows.map { silent.contains($0) ? 0x20 : 0xFFFC }, flow)
                XCTAssertEqual(rows.map { characters.character(at: $0 + 1 - shown.location) }, rows.map { silent.contains($0) ? 0x20 : 0x0A }, flow)
            }
            for place in silent {
                XCTAssertNil(rich.attribute(.accessibilityAttachment, at: place - shown.location, effectiveRange: nil), flow)
                XCTAssertNil(rich.attribute(.attachment, at: place - shown.location, effectiveRange: nil), flow)
                // Asked for the row's own character or its break, as for a word, the text gives the same.
                for part in [NSRange(location: place, length: 1), NSRange(location: place + 1, length: 1)] {
                    let one = try XCTUnwrap(view.accessibilityAttributedString(for: part))
                    XCTAssertEqual(one.string, " ", flow)
                    XCTAssertNil(one.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil), flow)
                    XCTAssertEqual(view.accessibilityString(for: part), " ", flow)
                }
                XCTAssertEqual(view.accessibilityString(for: NSRange(location: place - 1, length: 4)), "\n  \u{FFFC}", flow)
            }

            // The lines are the text's own but for these rows', which no line begins with.
            let lines = lines(of: view, in: shown)
            XCTAssertEqual(lines.count, 12, "\(flow): \(lines)")
            XCTAssertEqual(lines.first?.location, shown.location, flow)
            XCTAssertEqual(lines.last.map(NSMaxRange), NSMaxRange(shown), flow)
            XCTAssertTrue(zip(lines, lines.dropFirst()).allSatisfy { NSMaxRange($0) == $1.location }, "\(flow): \(lines)")
            XCTAssertEqual(worded.map { view.accessibilityLine(for: $0) }, [1, 2, 3, 4, 6, 7, 8, 9, 10], flow)
            for (index, place) in rows.enumerated() where silent.contains(place) {
                let line = view.accessibilityLine(for: rows[index + 1])
                XCTAssertEqual(view.accessibilityRange(forLine: line), NSRange(location: place, length: 4), flow)
                XCTAssertEqual([place, place + 1].map { view.accessibilityLine(for: $0) }, [line, line], flow)
                XCTAssertEqual(view.accessibilityLine(for: rows[index - 1]), line - 1, flow)
                // VoiceOver leaves the insertion point where it has read to.
                view.selectedRange = NSRange(location: place + 1, length: 0)
                XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), line, flow)
            }
            view.selectedRange = NSRange(location: 0, length: 0)

            // Entered at another row, the table of data has every row, and these rows' cells,
            // which say nothing: VoiceOver calls each an empty cell.
            let table = try XCTUnwrap(given[5].element as? ReaderTableElement, flow)
            XCTAssertEqual(table.accessibilityRowCount(), 8, flow)
            XCTAssertEqual(try self.rows(of: table).map { try cells(of: $0).map(said) },
                           [["Tree", "Tally"], ["Oak", "Nine"], ["", ""], ["Elm", "Four"], ["", ""], ["Ash", "Six"], [""], ["Yew", "Two"]], flow)
        }
    }

    /// What a row has to hold to be passed over is nothing, spaces or decoration, in a table
    /// of its own inside a cell as well. A picture nobody describes is one VoiceOver calls an
    /// image, a link is followed whatever it holds, and a rule says that a break is there:
    /// a row that holds one keeps its character and its line, and is what it was. That is a
    /// group wherever the row shows a picture to describe. A row whose one cell with anything
    /// in it holds a link or a rule and no words is a group in continuous scroll and has no
    /// element on a page, where a row is given by the cells with lines on that page.
    func testARowThatHoldsAPictureALinkOrARuleIsNotPassedOver() async throws {
        let rows = ["<td>First words</td><td></td>",
                    "<td>&#160;</td><td> </td>",
                    "<td><img src='square.svg'/></td><td></td>",
                    "<td><a href='tables.xhtml'><img src='square.svg' alt=''/></a></td><td></td>",
                    "<td><hr/></td><td></td>",
                    "<td><table><tr><td><img src='square.svg' alt=''/></td></tr></table></td><td></td>",
                    "<td><table><tr><td><img src='square.svg'/></td></tr></table></td><td></td>",
                    "<td>Last words</td><td></td>"]
        let book = try pictured("<p>Words before.</p><table role='presentation'>" + rows.map { "<tr>\($0)</tr>" }.joined() + "</table><p>Words after.</p>")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let (shown, places) = try text(of: view)
            XCTAssertEqual(places.count, 8, flow)
            let given = try attachments(in: view)
            XCTAssertEqual(given.map(\.location), (scrolled ? [0, 2, 3, 4, 6, 7] : [0, 2, 6, 7]).map { places[$0] }, flow)
            XCTAssertTrue(given.allSatisfy { $0.element.accessibilityRole() == .group }, flow)
            XCTAssertEqual(given.map { $0.element.accessibilityLabel() }, ["First words"] + Array(repeating: nil, count: given.count - 2) + ["Last words"], flow)
            let value = try XCTUnwrap(view.accessibilityValue()) as NSString
            XCTAssertEqual(places.map { value.character(at: $0 - shown.location) }, [0xFFFC, 0x20, 0xFFFC, 0xFFFC, 0xFFFC, 0x20, 0xFFFC, 0xFFFC], flow)
            XCTAssertEqual(places.map { view.accessibilityLine(for: $0) }, [1, 2, 2, 3, 4, 5, 5, 6], flow)
        }
    }

    /// Such rows are part of the line after them however many they are, so those that open a
    /// text are part of its first line. Those that end one have no line after them and are
    /// one line of spaces together, as a text of such rows alone is.
    func testRowsWithNothingToSayThatEndTheTextAreOneLine() async throws {
        let silent = "<tr><td><img src='square.svg' alt=''/></td><td></td></tr>", worded = "<tr><td>Left words</td><td>Right words</td></tr>"
        let ending = try pictured("<table role='presentation'>" + silent + silent + worded + silent + worded + silent + silent + "</table>")
        let alone = try pictured("<table role='presentation'>" + silent + silent + silent + "</table>")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            var (_, _, view) = try await reader(ending, scrolled: scrolled)
            var (shown, places) = try text(of: view)
            XCTAssertEqual(places.count, 7, flow)
            XCTAssertEqual(try attachments(in: view).map(\.location), [places[2], places[4]], flow)
            XCTAssertEqual(lines(of: view, in: shown), [NSRange(location: 0, length: places[3]), NSRange(location: places[3], length: places[5] - places[3]),
                                                        NSRange(location: places[5], length: shown.length - places[5])], flow)
            XCTAssertEqual(places.map { view.accessibilityLine(for: $0) }, [0, 0, 0, 1, 1, 2, 2], flow)
            XCTAssertEqual(view.accessibilityLine(for: NSMaxRange(shown) - 1), 2, flow)
            XCTAssertEqual(view.accessibilityRange(forLine: 3).length, 0, flow)
            XCTAssertEqual(view.accessibilityString(for: NSRange(location: places[5], length: shown.length - places[5]))?.allSatisfy { $0 == " " }, true, flow)

            (_, _, view) = try await reader(alone, scrolled: scrolled)
            (shown, places) = try text(of: view)
            XCTAssertEqual(places.count, 3, flow)
            XCTAssertTrue(try attachments(in: view).isEmpty, flow)
            XCTAssertEqual(lines(of: view, in: shown), [shown], flow)
            XCTAssertEqual((0..<shown.length).map { view.accessibilityLine(for: $0) }, Array(repeating: 0, count: shown.length), flow)
            XCTAssertEqual(view.accessibilityRange(forLine: 1).length, 0, flow)
            XCTAssertEqual(view.accessibilityValue()?.allSatisfy { $0 == " " }, true, flow)
        }
    }

    /// Through a long table with such rows one, two and three together, every character is on
    /// the line the text gives for it, the lines follow one another through the whole text,
    /// and each ends with something to say: in continuous scroll the lines are AppKit's,
    /// numbered through the book, and each number is less by the rows passed over before it.
    func testLinesAreNumberedPastRowsWithNothingToSayThroughALongTable() async throws {
        let silent = "<tr><td></td><td><img src='square.svg' alt=''/></td></tr>"
        let rows = (1...60).map { "<tr><td>Left \($0)</td><td>Right \($0)</td></tr>" + String(repeating: silent, count: $0 % 4) }.joined()
        let book = try pictured("<p>Words before, with enough of them after these to run on to a second line of the text at this width and at this size.</p>"
            + "<table role='presentation'>" + rows + "</table><p>Words after.</p>")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let (shown, places) = try text(of: view)
            let value = try XCTUnwrap(view.accessibilityValue()) as NSString
            let passed = places.filter { value.character(at: $0 - shown.location) == 0x20 }
            XCTAssertEqual(places.map { value.character(at: $0 + 1 - shown.location) }, places.map { passed.contains($0) ? 0x20 : 0x0A }, flow)
            XCTAssertEqual(places.count - passed.count, try attachments(in: view).count, flow)
            XCTAssertGreaterThan(passed.count, scrolled ? 80 : 5, flow)
            let lines = lines(of: view, in: shown)
            XCTAssertEqual(lines.first?.location, shown.location, flow)
            XCTAssertEqual(lines.last.map(NSMaxRange), NSMaxRange(shown), flow)
            XCTAssertTrue(zip(lines, lines.dropFirst()).allSatisfy { NSMaxRange($0) == $1.location }, flow)
            // The two lines of words before, a line for each row that says something, and
            // the words after, which the table's first page does not reach: it ends with
            // rows passed over, which are a line together.
            let ending = places.last.map(passed.contains) == true
            XCTAssertEqual(lines.count, 2 + (places.count - passed.count) + (scrolled || ending ? 1 : 0), flow)
            // A row passed over is nowhere but at the front of a line, before the row or
            // the words that follow it.
            for line in lines.dropLast(ending ? 1 : 0) {
                let held = places.filter { NSLocationInRange($0, line) }
                XCTAssertFalse(held.last.map(passed.contains) == true && line != lines.last, "\(flow): \(line)")
                XCTAssertLessThanOrEqual(held.filter { !passed.contains($0) }.count, 1, "\(flow): \(line)")
            }
            for (number, line) in lines.enumerated() {
                XCTAssertEqual(Set((line.location..<NSMaxRange(line)).map { view.accessibilityLine(for: $0) }), [number], "\(flow), line \(number)")
            }
        }
    }

    /// In continuous scroll VoiceOver is given a row beyond the screen before the view shows
    /// it, and keeps the element it was given. That row is the same group, called by its
    /// words, with nothing in it yet: once its cells' text areas are there it holds them,
    /// for VoiceOver to go into. Made from what was on screen when it was asked for, it was
    /// an image called by its words, and stayed one.
    func testInContinuousScrollARowOffScreenIsTheSameGroupAndHoldsItsCellsOnceShown() async throws {
        let rows = (1...60).map { "<tr><td>Left \($0)</td><td>Right \($0)</td></tr>" }.joined()
        let book = try book("<p>Words before.</p><table role='presentation'>" + rows + "</table><p>Words after.</p>")
        let (reader, _, view) = try await reader(book, scrolled: true)
        let given = try attachments(in: view)
        XCTAssertEqual(given.map { $0.element.accessibilityLabel() }, (1...60).map { "Left \($0), Right \($0)" })
        XCTAssertTrue(given.allSatisfy { $0.element.accessibilityRole() == .group })
        XCTAssertEqual(held(given[0].element), ["Left 1", "Right 1"], "the first row is on screen")
        let far = given[54]
        XCTAssertEqual((far.element.accessibilityChildren() ?? []).count, 0, "the fifty-fifth is not")

        let range = try XCTUnwrap(view.textRange(for: NSRange(location: far.location, length: 1)))
        view.readerLayoutManager.ensureLayout(for: range)
        let place = try XCTUnwrap(view.segmentFrames(for: NSRange(location: far.location, length: 1)).first)
        let scrollView = try XCTUnwrap(view.enclosingScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: place.minY + view.containerOrigin.y - 100))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await reader.wait("the far row's text areas") { self.held(far.element) == ["Left 55", "Right 55"] }
        XCTAssertEqual(far.element.accessibilityLabel(), "Left 55, Right 55")
        XCTAssertTrue(try attachments(in: view)[54].element === far.element, "the text gives the element VoiceOver was given before")
        // The first row is far above the screen now, and holds nothing.
        try await reader.wait("the first row's text areas gone") { (given[0].element.accessibilityChildren() ?? []).isEmpty }
        XCTAssertEqual(given[0].element.accessibilityLabel(), "Left 1, Right 1")
        XCTAssertEqual(given[0].element.accessibilityRole(), .group)
    }

    /// A row taller than a page continues on the next, and on each page its group is called by
    /// the words that page shows: across the pages every word is said once.
    func testARowContinuedAcrossPagesIsCalledByEachPagesOwnWords() async throws {
        let wording = (1...1_600).map { "w\($0)" }
        let book = try book("<table role='presentation'><tr><td>Label</td><td>" + wording.joined(separator: " ") + "</td></tr></table>")
        let (_, canvas, _) = try await reader(book, scrolled: false)
        var named: [String] = [], pages = 0
        repeat {
            let column = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
            // The table is all its chapter holds; the page after its last is the next chapter's.
            let given = try attachments(in: column)
            guard !given.isEmpty else { break }
            XCTAssertTrue(given.allSatisfy { $0.element.accessibilityRole() == .group }, "page \(pages + 1)")
            named += given.flatMap { ($0.element.accessibilityLabel() ?? "").replacingOccurrences(of: ",", with: "").split(whereSeparator: \.isWhitespace).map(String.init) }
            pages += 1
        } while pages < 40 && canvas.turnPage(forward: true) == .turned
        XCTAssertGreaterThan(pages, 2, "the row must be some pages tall for this to show anything")
        XCTAssertEqual(named.sorted(), (wording + ["Label"]).sorted(), "every word of the row once across \(pages) pages")
    }

    /// A page turn gives the column other text: a row's group that a client kept from the
    /// page before says nothing of the new page, whose rows are other elements. It has
    /// departed, and is an empty static text (`testThePageBeforesRowElementsStayTheColumnsChildrenAfterATurn`).
    func testAnotherPageGivesOtherRowGroups() async throws {
        let rows = (1...60).map { "<tr><td>Left \($0)</td><td>Right \($0)</td></tr>" }.joined()
        let book = try book("<p>Words before.</p><table role='presentation'>" + rows + "</table><p>Words after.</p>")
        let (_, canvas, view) = try await reader(book, scrolled: false)
        let first = try XCTUnwrap(try attachments(in: view).first)
        XCTAssertEqual(first.element.accessibilityLabel(), "Left 1, Right 1")
        XCTAssertEqual(held(first.element), ["Left 1", "Right 1"])
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let column = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        let second = try XCTUnwrap(try attachments(in: column).first)
        XCTAssertFalse(second.element === first.element)
        XCTAssertNotEqual(second.element.accessibilityLabel(), "Left 1, Right 1")
        XCTAssertNil(first.element.accessibilityLabel())
        XCTAssertEqual((first.element.accessibilityChildren() ?? []).count, 0)
        XCTAssertEqual(second.element.accessibilityRole(), .group)
        XCTAssertEqual(first.element.accessibilityRole(), .staticText)
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
        try await reader.wait("the header row's text areas gone") { !header[1].holdsItsWords }
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
        XCTAssertEqual(first.accessibilityColumnHeaderUIElements()?.count, 0)
        XCTAssertNil(first.accessibilityCell(forColumn: 0, row: 0))
        XCTAssertEqual(kept.accessibilityChildren()?.count, 0)
        XCTAssertEqual(kept.accessibilityFrame(), .zero)
    }

    // MARK: A page turned under a row's element (#485)

    /// A table of each kind, longer than a page, for the page turns below.
    private static let longTables = [
        "<p>Words before.</p><table role='presentation'>"
            + (1...60).map { "<tr><td>Left \($0)</td><td>Right \($0)</td></tr>" }.joined() + "</table><p>Words after.</p>",
        "<p>Words before the ledger.</p>" + ledger(rows: 60) + "<p>Words after the ledger.</p>",
    ]

    /// The ways a page is turned from where VoiceOver is: the host's own turn, as its Next Page
    /// button makes, the text area's Next Page action, and a page key wherever the keyboard
    /// focus is in the reader.
    private func turns(_ canvas: ReaderCanvasView, _ window: NSWindow) -> [(name: String, turn: () throws -> Void)] {
        [("the host's turn", { XCTAssertEqual(canvas.turnPage(forward: true), .turned) }),
         ("the text area's action", {
            let column = try XCTUnwrap(canvas.textViews.first)
            let action = try XCTUnwrap(column.accessibilityCustomActions()?.first { $0.name == "Next Page" })
            XCTAssertTrue(try XCTUnwrap(action.handler)())
         }),
         ("a page key", {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: "\u{F72D}",
                                                     charactersIgnoringModifiers: "\u{F72D}", isARepeat: false, keyCode: 121))
            XCTAssertTrue(window.performKeyEquivalent(with: key), "the reader takes a page key from where the focus is")
         })]
    }

    /// VoiceOver keeps its cursor on an element only while the element is among the children
    /// of the text it is in, and once it has gone into a row and come back out its cursor is
    /// on the row's element. After a page turn the elements of the page before stay among the
    /// column's children, so that VoiceOver stays in the text and reads the new page from its
    /// first line. Each says nothing and holds nothing, as an empty static text at that line,
    /// and the next page's turn takes them away. What VoiceOver did with each shape is in
    /// doc/testing.md#tables-on-mac.
    func testThePageBeforesRowElementsStayTheColumnsChildrenAfterATurn() async throws {
        for body in Self.longTables {
            let (reader, canvas, view) = try await reader(try book(body), scrolled: false)
            let window = try XCTUnwrap(view.window)
            var before = try attachments(in: view).map(\.element)
            XCTAssertGreaterThan(before.count, 1, body)
            XCTAssertFalse((view.accessibilityChildren() ?? []).contains { ($0 as AnyObject) is ReaderTableRowGroupElement || ($0 as AnyObject) is ReaderTableElement },
                           "a page's own rows are given in its text, not among its children")
            for (name, turn) in turns(canvas, window) {
                try turn()
                try await reader.settle()
                let column = try XCTUnwrap(canvas.textViews.first)
                XCTAssertTrue(column === view, "a page column holds every page")
                let children = (column.accessibilityChildren() ?? []).map { $0 as AnyObject }
                let now = try attachments(in: column).map(\.element)
                XCTAssertFalse(now.contains { element in before.contains { $0 === element } }, "\(name): the new page's rows are other elements")
                let firstLine = column.accessibilityFrame(for: column.accessibilityRange(forLine: 0))
                for element in before {
                    XCTAssertTrue(children.contains { $0 === element }, "\(name): \(element) is among the column's children")
                    XCTAssertTrue(element.accessibilityParent() as AnyObject === column, name)
                    XCTAssertEqual(element.accessibilityRole(), .staticText, name)
                    XCTAssertNil(element.accessibilityLabel(), name)
                    XCTAssertEqual(element.accessibilityChildren()?.count ?? 0, 0, name)
                    let frame = element.accessibilityFrame()
                    XCTAssertFalse(frame.isEmpty, name)
                    XCTAssertEqual(frame.midY, firstLine.midY, accuracy: 1, "\(name): it stands at the new page's first line")
                    if let table = element as? ReaderTableElement {
                        XCTAssertEqual(table.accessibilityRowCount(), 0, name)
                        XCTAssertEqual(table.accessibilityColumnCount(), 0, name)
                        XCTAssertEqual(table.accessibilityColumns()?.count, 0, name)
                        XCTAssertEqual(table.accessibilityRows()?.count, 0, name)
                        // A client is not told of a table's attributes, but for the cell at a
                        // slot of the grid, which AppKit does not ask about.
                        for selector in [#selector(NSAccessibilityElement.accessibilityRows), #selector(NSAccessibilityElement.accessibilityRowCount),
                                         #selector(NSAccessibilityElement.accessibilityColumnCount), #selector(NSAccessibilityElement.accessibilityColumnHeaderUIElements)] {
                            XCTAssertFalse(table.isAccessibilitySelectorAllowed(selector), "\(name): \(selector)")
                        }
                    }
                }
                // The new page's own rows are still what its text gives.
                for element in now {
                    XCTAssertFalse(children.contains { $0 === element }, name)
                    XCTAssertNotEqual(element.accessibilityRole(), .staticText, name)
                    if let table = element as? ReaderTableElement {
                        XCTAssertTrue(table.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.accessibilityRows)), name)
                    }
                }
                // Those of two pages back are gone.
                XCTAssertEqual(children.filter { $0 is ReaderTableRowGroupElement || $0 is ReaderTableElement }.count, before.count, name)
                before = now
            }
        }
    }

    /// In continuous scroll the text is the whole book, and nothing is kept from text before.
    func testContinuousScrollKeepsNoRowElementsOfTextBefore() async throws {
        let (_, canvas, view) = try await reader(try book(Self.longTables[1]), scrolled: true)
        XCTAssertGreaterThan(try tables(in: view).count, 1)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        canvas.reloadContent(keeping: canvas.visibleRange?.start)
        XCTAssertTrue(view.departedRows.isEmpty)
        XCTAssertFalse((view.accessibilityChildren() ?? []).contains { ($0 as AnyObject) is ReaderTableElement })
    }

    /// VoiceOver gives the keyboard focus to each text area it moves to, a cell's among them,
    /// and leaves it there when it comes back out to the row. A page turn takes the page's
    /// cells away, and the column that showed the cell takes the focus. The window had it,
    /// and VoiceOver, which follows the focus, went to the window's first control.
    func testKeyboardFocusInACellsTextAreaStaysInTheColumnAfterATurn() async throws {
        for body in Self.longTables {
            let (reader, canvas, view) = try await reader(try book(body), scrolled: false)
            let window = try XCTUnwrap(view.window)
            for (name, turn) in turns(canvas, window) {
                try await reader.wait("the cells' text views") { view.tableInteraction?.cells.isEmpty == false }
                let cell = try XCTUnwrap(view.tableInteraction?.accessibilityCellsInOrder.first?.cell)
                XCTAssertTrue(window.makeFirstResponder(cell), name)
                XCTAssertTrue(window.firstResponder === cell, name)
                try turn()
                XCTAssertNil(cell.superview, "\(name): the cell's text area went with its page")
                XCTAssertTrue(window.firstResponder === view, "\(name): \(String(describing: window.firstResponder)) has the focus")
            }
            // Focus elsewhere is left where it is.
            XCTAssertTrue(window.makeFirstResponder(canvas))
            XCTAssertEqual(canvas.turnPage(forward: false), .turned)
            XCTAssertTrue(window.firstResponder === canvas)
        }
    }
}
#endif
