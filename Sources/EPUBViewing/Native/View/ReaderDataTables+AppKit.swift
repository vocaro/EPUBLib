#if os(macOS)
import AppKit

/// A value handed across an isolation boundary that the compiler cannot check.
private struct Unchecked<T>: @unchecked Sendable { let value: T }

/// AppKit asks an accessibility element on the main thread. Neither the element nor what it
/// gives back (other elements, a cell's views) is `Sendable`, which `MainActor.assumeIsolated`
/// wants of both.
private func onMain<Element: AnyObject, T>(_ element: Element, _ body: @MainActor (Element) -> T) -> T {
    let element = Unchecked(value: element)
    return withoutActuallyEscaping(body) { body in
        let body = Unchecked(value: body)
        return MainActor.assumeIsolated { Unchecked(value: body.value(element.value)) }.value
    }
}

/// The tables of data in one text view, as an assistive technology on the Mac is given them
/// (doc/native-viewer.md, "Data tables"). A table is drawn as an attachment for each row, so a
/// row's character is all the text has to give a table at. Each row's character gives a table
/// element of its own: the whole table, named by that row's words and with that row selected,
/// which is where VoiceOver comes into it.
@MainActor final class ReaderDataTables {
    private weak var view: ReaderTextView?
    /// The table given at each row's character.
    private var tables: [Int: ReaderTableElement] = [:]
    /// The row characters of every table of data in the view's text, in order, by table.
    private var found: [ObjectIdentifier: [(location: Int, row: TableRowAttachment)]]?

    init(view: ReaderTextView) { self.view = view }

    /// The view has other text: its tables are other tables, and one a client still holds
    /// from the text before has nothing to say of this one.
    func reset() {
        for table in tables.values { table.detach() }
        tables.removeAll()
        found = nil
    }

    /// The rows of `table` the view shows: a page column's own page, or the whole book's.
    func rows(of table: TableModel) -> [(location: Int, row: TableRowAttachment)] {
        guard let view, let storage = view.contentStorage.textStorage else { return [] }
        if found == nil {
            var all: [ObjectIdentifier: [(Int, TableRowAttachment)]] = [:]
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
                guard let row = value as? TableRowAttachment, row.table.isData else { return }
                all[ObjectIdentifier(row.table), default: []].append((run.location, row))
            }
            found = all
        }
        let all = found?[ObjectIdentifier(table)] ?? []
        guard view.isPageColumn else { return all }
        let shown = view.shownCharacters
        return all.filter { NSLocationInRange($0.location, shown) }
    }

    /// The table that stands for the row at `location` among the text's characters.
    func element(at location: Int, of row: TableRowAttachment) -> ReaderTableElement? {
        guard let view else { return nil }
        if let kept = tables[location], kept.table === row.table { return kept }
        let table = ReaderTableElement(view: view, owner: self, table: row.table, entry: location)
        tables[location] = table
        return table
    }
}

/// A table of data where one of its rows stands in the text: `NSAccessibility`'s table, with
/// the rows the view shows of it, its columns, its cells, and a header for each column and row.
///
/// What VoiceOver does with it was heard, not read (doc/voiceover-testing.md). As it reads the
/// text it says the label and "table", and after them the whole table's contents unless the
/// table says which of its rows are selected. It comes into a table at its selected row, and
/// otherwise at the first row on screen. With selected cells among its attributes as well, it
/// says "No selection" of a table with none and reads a selected row's cells a second time.
@MainActor final class ReaderTableElement: NSAccessibilityElement {
    /// The view while it shows the text the table was given in.
    private(set) weak var view: ReaderTextView?
    /// The view, whatever it shows: what holds the table.
    private weak var host: ReaderTextView?
    private weak var owner: ReaderDataTables?
    let table: TableModel
    /// The character of the row the table stands at.
    let entry: Int
    private var rowsByLocation: [Int: ReaderTableRowElement] = [:]
    private var cellsByIndex: [Int: ReaderTableCellElement] = [:]
    private var headerNames: [Int: ReaderTableHeaderElement] = [:]
    private var columns: [ReaderTableColumnElement] = []
    /// The rows listed, for the text they were listed in.
    private var listedRows: (key: [CGFloat], rows: [ReaderTableRowElement])?
    /// The layout a page's cells were listed in.
    private var pageKey: [CGFloat]?

    init(view: ReaderTextView, owner: ReaderDataTables, table: TableModel, entry: Int) {
        self.view = view
        host = view
        self.owner = owner
        self.table = table
        self.entry = entry
        super.init()
        // AppKit tells a client of an attribute that the element has been given a value for.
        setAccessibilityRole(.table)
        setAccessibilityParent(view)
        setAccessibilityRows([])
        setAccessibilityVisibleRows([])
        setAccessibilitySelectedRows([])
        setAccessibilityColumns([])
        setAccessibilityVisibleColumns([])
        setAccessibilityVisibleCells([])
        setAccessibilityColumnHeaderUIElements([])
        setAccessibilityRowHeaderUIElements([])
        setAccessibilityRowCount(table.rows.count)
        setAccessibilityColumnCount(table.columnCount)
        setAccessibilityChildren([])
        columns = (0..<table.columnCount).map { ReaderTableColumnElement(table: self, column: $0) }
    }

    /// The view shows other text than the table was given in: the table has nothing in it,
    /// and is still the view's.
    func detach() {
        view = nil
        listedRows = nil
        pageKey = nil
    }

    // MARK: What the view shows of the table

    /// The row's frame in the view's coordinates, laid out if it was not.
    func frame(ofRowAt location: Int) -> CGRect? {
        guard let view, let range = view.textRange(for: NSRange(location: location, length: 1)) else { return nil }
        view.readerLayoutManager.ensureLayout(for: range)
        let origin = view.containerOrigin
        return view.segmentFrames(for: NSRange(location: location, length: 1)).first?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// What the cells listed depend on: the line a row is laid out on, and the page shown.
    private var layoutKey: [CGFloat] {
        guard let view else { return [] }
        return [frame(ofRowAt: entry)?.width ?? 0, view.readerContainer.viewportSize.height, CGFloat(view.shownCharacters.length)]
    }

    /// The rows the view shows, in order: a page's own, or in continuous scroll every row.
    var rowElements: [ReaderTableRowElement] {
        guard let view, let owner else { return [] }
        let key = [CGFloat(view.shownCharacters.length), CGFloat(view.textLength)]
        if let listedRows, listedRows.key == key { return listedRows.rows }
        let rows = owner.rows(of: table).map { location, row in
            rowsByLocation[location] ?? ReaderTableRowElement(table: self, location: location, row: row)
        }
        rowsByLocation = Dictionary(rows.map { ($0.location, $0) }) { first, _ in first }
        listedRows = (key, rows)
        return rows
    }

    /// The row the table stands at.
    private var entryRow: ReaderTableRowElement? { rowElements.first { $0.location == entry } }

    /// The cells read where `row` stands. A cell is read where it has something to say: where
    /// it starts, or in pages in the first row of the page that holds lines of it. A cell with
    /// nothing to say anywhere is read where it starts.
    func cells(of row: ReaderTableRowElement) -> [ReaderTableCellElement] {
        guard let view else { return [] }
        let key = layoutKey
        if view.isPageColumn {
            // A page's rows are few, and a cell from a row above is read once among them.
            if pageKey != key {
                var listed: [Int: ReaderTableCellElement] = [:]
                for element in rowElements { element.list(cells(shownBy: element, among: &listed), for: key) }
                pageKey = key
            }
        } else if row.listedFor != key {
            // In continuous scroll a cell says all its words where it starts.
            var listed: [Int: ReaderTableCellElement] = [:]
            row.list(cells(shownBy: row, among: &listed), for: key)
        }
        return row.listed
    }

    private func cells(shownBy row: ReaderTableRowElement, among listed: inout [Int: ReaderTableCellElement]) -> [ReaderTableCellElement] {
        // Every row of a table is laid out on a line of one width, and a long table's rows
        // are not all laid out to list one of them.
        guard let view, let width = frame(ofRowAt: entry)?.width ?? frame(ofRowAt: row.location)?.width else { return [] }
        var result: [ReaderTableCellElement] = []
        for spoken in row.row.spokenCells(size: CGSize(width: width, height: 0), viewportHeight: view.readerContainer.viewportSize.height) {
            if let cell = listed[spoken.cell] {
                cell.text = [cell.text, spoken.text].filter { !$0.isEmpty }.joined(separator: " ")
                cell.images += spoken.images
                cell.locations.append(row.location)
                continue
            }
            guard !spoken.text.isEmpty || !spoken.images.isEmpty || (spoken.starts && spoken.isBlank) else { continue }
            let cell = cellsByIndex[spoken.cell] ?? ReaderTableCellElement(table: self, cell: spoken.cell)
            cellsByIndex[spoken.cell] = cell
            cell.row = row
            cell.text = spoken.text
            cell.images = spoken.images
            cell.locations = [row.location]
            cell.frameInRow = spoken.frame
            listed[spoken.cell] = cell
            result.append(cell)
        }
        return result
    }

    /// The element of the cell at `index` of the table's cells, where the view shows it.
    func listed(_ index: Int) -> ReaderTableCellElement? {
        guard let view, table.cells.indices.contains(index) else { return nil }
        if view.isPageColumn {
            // On a page a cell is read in the first of its rows the page shows.
            for row in rowElements {
                if let cell = cells(of: row).first(where: { $0.cell == index }) { return cell }
            }
            return nil
        }
        guard let row = rowElements.first(where: { $0.row.row == table.cells[index].row }) else { return nil }
        return cells(of: row).first { $0.cell == index }
    }

    // MARK: Header cells
    //
    // The table gives a header for each column and for each row, and no cell names header
    // cells of its own. VoiceOver takes the table's header at a cell's column and at its
    // row, as it does in AppKit's own tables. Asked of the cell instead, it quit: its
    // `-[SCRCell columnHeaderDescription]` appends the first header's description to a
    // string without looking, and that description came back nil now and then, whatever
    // the header element was (macOS 27.0.1; doc/voiceover-testing.md has the reports).

    /// The header of each column, in column order. None where no column has a header cell.
    private var columnHeaders: [NSAccessibilityElement] {
        let heads = (0..<table.columnCount).map { table.columnHeaders($0) }
        guard view != nil, heads.contains(where: { !$0.isEmpty }) else { return [] }
        return heads.enumerated().map { headerElement($1, key: $0) }
    }

    /// The header of each row of the whole table, in row order: a page's table answers for
    /// its rows by their numbers in the whole table.
    private var rowHeaders: [NSAccessibilityElement] {
        let heads = table.rows.indices.map { table.rowHeaders($0) }
        guard view != nil, heads.contains(where: { !$0.isEmpty }) else { return [] }
        return heads.enumerated().map { headerElement($1, key: -1 - $0) }
    }

    /// What heads a column or a row. Its one header cell, where that is on screen with its
    /// text areas: VoiceOver reads a header cell by what it holds, and does not read a cell
    /// under itself. Otherwise the words of its header cells, top or first one first, as
    /// static text: several header cells, one on another page, or one far off the screen.
    private func headerElement(_ cells: [Int], key: Int) -> NSAccessibilityElement {
        if cells.count == 1, let listed = listed(cells[0]), listed.holdsText { return listed }
        let words = cells.map { table.cells[$0].text }.filter { !$0.isEmpty }.joined(separator: ", ")
        if let kept = headerNames[key], kept.words == words { return kept }
        let name = ReaderTableHeaderElement(table: self, words: words)
        headerNames[key] = name
        return name
    }

    func columnHeader(_ column: Int) -> NSAccessibilityElement? {
        let headers = columnHeaders
        return headers.indices.contains(column) ? headers[column] : nil
    }

    func cells(inColumn column: Int) -> [ReaderTableCellElement] {
        rowElements.flatMap { cells(of: $0) }.filter { NSLocationInRange(column, $0.columns) }
    }

    // MARK: NSAccessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityParent() -> Any? { onMain(self) { $0.host } }
    override func accessibilityLabel() -> String? { onMain(self) { $0.words } }
    override func accessibilityRows() -> [Any]? { onMain(self) { $0.rowElements } }
    override func accessibilityVisibleRows() -> [Any]? { onMain(self) { $0.visibleRows } }
    override func accessibilitySelectedRows() -> [Any]? { onMain(self) { $0.entryRow.map { [$0] } ?? [] } }
    override func accessibilityColumns() -> [Any]? { onMain(self) { $0.columns } }
    override func accessibilityVisibleColumns() -> [Any]? { onMain(self) { $0.columns } }
    override func accessibilityVisibleCells() -> [Any]? { onMain(self) { $0.visibleCells } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.rowElements + $0.columns } }
    override func accessibilityRowCount() -> Int { onMain(self) { $0.table.rows.count } }
    override func accessibilityColumnCount() -> Int { onMain(self) { $0.table.columnCount } }
    override func accessibilityColumnHeaderUIElements() -> [Any]? { onMain(self) { $0.columnHeaders } }
    override func accessibilityRowHeaderUIElements() -> [Any]? { onMain(self) { $0.rowHeaders } }
    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? { onMain(self) { $0.cell(column: column, row: row) } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }

    /// What the table is called where it stands: the words its row shows there. They are all
    /// VoiceOver says of the row as it reads the text by line or by word.
    private var words: String? {
        guard let row = entryRow else { return nil }
        let words = cells(of: row).map { $0.text }.filter { !$0.isEmpty }.joined(separator: ", ")
        return words.isEmpty ? nil : words
    }

    /// The rows on screen: a page's own, and in continuous scroll those in the visible part.
    private var visibleRows: [ReaderTableRowElement] {
        guard let view else { return [] }
        let rows = rowElements
        guard !view.isPageColumn else { return rows }
        let visible = view.visibleRect
        // The lines at the top and the bottom of the screen bound the rows there, so that a
        // long table's rows are not all laid out to find the few on screen.
        let first = view.characterOffset(at: CGPoint(x: visible.midX, y: visible.minY)) - 2
        let last = view.characterOffset(at: CGPoint(x: visible.midX, y: visible.maxY)) + 2
        return rows.filter { $0.location >= first && $0.location <= last }
            .filter { frame(ofRowAt: $0.location).map { !$0.intersection(visible).isEmpty } ?? false }
    }

    private var visibleCells: [ReaderTableCellElement] { visibleRows.flatMap { cells(of: $0) } }

    /// The cell that covers a slot of the grid, where the view shows it. A cell that spans
    /// answers for every slot it covers.
    func cell(column: Int, row: Int) -> ReaderTableCellElement? {
        guard table.rowCells.indices.contains(row) else { return nil }
        let cell = table.rowCells[row].first { table.cells[$0].column <= column && column < table.cells[$0].column + table.cells[$0].columnSpan }
        return cell.flatMap { listed($0) }
    }

    /// Where the table stands in the text: its row's place.
    private var screenFrame: NSRect {
        guard let view, let frame = frame(ofRowAt: entry) else { return .zero }
        return NSAccessibility.screenRect(fromView: view, rect: frame)
    }
}

/// A row of a table of data, where it stands in the view: a whole row, or in pages the part of
/// one a page shows.
@MainActor final class ReaderTableRowElement: NSAccessibilityElement {
    /// A client can keep the element after its table has gone, with the page it was on.
    private weak var table: ReaderTableElement?
    let location: Int
    let row: TableRowAttachment
    /// The cells read in the row, and the layout they were listed in.
    private(set) var listed: [ReaderTableCellElement] = []
    private(set) var listedFor: [CGFloat]?

    init(table: ReaderTableElement, location: Int, row: TableRowAttachment) {
        self.table = table
        self.location = location
        self.row = row
        super.init()
        setAccessibilityRole(.row)
        setAccessibilitySubrole(.tableRow)
        setAccessibilityParent(table)
        setAccessibilityIndex(row.row)
        setAccessibilityChildren([])
    }

    func list(_ cells: [ReaderTableCellElement], for key: [CGFloat]) {
        listed = cells
        listedFor = key
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .tableRow }
    override func accessibilityParent() -> Any? { onMain(self) { $0.table } }
    /// The row's number in the whole table, which a page of it keeps.
    override func accessibilityIndex() -> Int { onMain(self) { $0.row.row } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.table?.cells(of: $0) ?? [] } }
    override func accessibilityVisibleChildren() -> [Any]? { onMain(self) { $0.table?.cells(of: $0) ?? [] } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }

    private var screenFrame: NSRect {
        guard let table, let view = table.view, let frame = table.frame(ofRowAt: location) else { return .zero }
        return NSAccessibility.screenRect(fromView: view, rect: frame)
    }
}

/// A column of a table of data: the cells the view shows of it.
@MainActor final class ReaderTableColumnElement: NSAccessibilityElement {
    /// A client can keep the element after its table has gone, with the page it was on.
    private weak var table: ReaderTableElement?
    let column: Int

    init(table: ReaderTableElement, column: Int) {
        self.table = table
        self.column = column
        super.init()
        setAccessibilityRole(.column)
        setAccessibilityParent(table)
        setAccessibilityIndex(column)
        setAccessibilityChildren([])
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .column }
    override func accessibilityParent() -> Any? { onMain(self) { $0.table } }
    override func accessibilityIndex() -> Int { onMain(self) { $0.column } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.table?.cells(inColumn: $0.column) ?? [] } }
    override func accessibilityHeader() -> Any? { onMain(self) { $0.header } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }

    private var header: NSAccessibilityElement? { table?.columnHeader(column) }
    private var screenFrame: NSRect {
        let frame = (table?.cells(inColumn: column) ?? []).map { $0.screenFrame }.reduce(NSRect.null) { $0.union($1) }
        return frame.isNull ? .zero : frame
    }
}

/// The header of a column or of a row where it is not one cell on screen: the words of its
/// header cells as static text, for VoiceOver to say, in no row and nowhere for its cursor to
/// go. VoiceOver said the words of a static text with a value, of a button with a title and
/// of a cell that held a static text, and not those of a cell with a title or a label. A
/// column or a row that nothing heads has an element without words, where VoiceOver says the
/// column's or the row's number instead.
@MainActor final class ReaderTableHeaderElement: NSAccessibilityElement {
    private weak var table: ReaderTableElement?
    let words: String

    init(table: ReaderTableElement, words: String) {
        self.table = table
        self.words = words
        super.init()
        setAccessibilityRole(words.isEmpty ? .cell : .staticText)
        setAccessibilityParent(table)
        if !words.isEmpty { setAccessibilityValue(words) }
    }

    override func accessibilityParent() -> Any? { onMain(self) { $0.table } }
}

/// A cell of a table of data, where the view shows it. It holds the text areas of its words
/// while they are on screen, so that VoiceOver can go into it and read by word, and is
/// labelled with its words where it has none.
@MainActor final class ReaderTableCellElement: NSAccessibilityElement {
    /// A client can keep the element after its table has gone, with the page it was on.
    private weak var table: ReaderTableElement?
    let cell: Int
    /// The row it is read in. None for a header cell given by name (`ReaderTableElement.header`).
    weak var row: ReaderTableRowElement?
    /// The words it shows here.
    var text = ""
    /// The pictures among them that say something.
    var images: [ReaderImageAttachment] = []
    /// The characters of the rows that hold lines of it here.
    var locations: [Int] = []
    /// Its box in its row's coordinates.
    var frameInRow = CGRect.zero

    init(table: ReaderTableElement, cell: Int) {
        self.table = table
        self.cell = cell
        let model = table.table.cells[cell]
        rows = NSRange(location: model.row, length: model.rowSpan)
        columns = NSRange(location: model.column, length: model.columnSpan)
        super.init()
        setAccessibilityRole(.cell)
        setAccessibilityRowIndexRange(rows)
        setAccessibilityColumnIndexRange(columns)
        setAccessibilityChildren([])
    }

    /// The rows and the columns the cell covers, counted in the whole table.
    let rows: NSRange
    let columns: NSRange

    /// The text views that hold the cell's words here, where they are on screen. Every table
    /// that stands at a row of this one holds the same views: a view answers to the cell
    /// that asked for it last, which is the cell of the table VoiceOver is in.
    private var textViews: [TableCellTextView] {
        guard let interaction = table?.view?.tableInteraction else { return [] }
        let views = locations.flatMap { interaction.accessibilityCells(at: $0, cell: cell) }
        for view in views { view.tableCellElement = self }
        return views
    }

    /// Whether the cell's words are in text areas it holds, which is where VoiceOver reads a
    /// header cell's words from.
    var holdsText: Bool { !textViews.isEmpty }

    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityParent() -> Any? { onMain(self) { $0.row ?? $0.table } }
    override func accessibilityRowIndexRange() -> NSRange { onMain(self) { $0.rows } }
    override func accessibilityColumnIndexRange() -> NSRange { onMain(self) { $0.columns } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.textViews } }
    override func accessibilityVisibleChildren() -> [Any]? { onMain(self) { $0.textViews } }
    override func accessibilityLabel() -> String? { onMain(self) { $0.label } }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { onMain(self) { $0.actions } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }

    /// The cell's words, where no text view says them: off screen, and for a header cell
    /// given by name.
    private var label: String? { text.isEmpty || !textViews.isEmpty ? nil : text }

    /// What the cell can do itself: show each picture, select its words, follow each link.
    private var actions: [NSAccessibilityCustomAction]? {
        guard let view = table?.view else { return nil }
        var actions = images.map { image in
            NSAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") { [weak view] in
                guard let canvas = view?.canvas else { return false }
                canvas.inspectImage(image)
                return true
            }
        }
        var select: (@MainActor () -> Bool)?
        var links: [NSAccessibilityCustomAction] = []
        for location in locations {
            guard let found = view.tableInteraction?.accessibilityActions(at: location, cell: cell) else { continue }
            select = select ?? found.select
            links += found.links.map { link in NSAccessibilityCustomAction(name: "Follow Link: " + link.name) { link.perform() } }
        }
        if let select { actions.append(NSAccessibilityCustomAction(name: "Select Cell Text") { select() }) }
        actions += links
        return actions.isEmpty ? nil : actions
    }

    var screenFrame: NSRect {
        guard let table, let view = table.view, let location = locations.first, let rowFrame = table.frame(ofRowAt: location) else { return .zero }
        let frame = frameInRow.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        return NSAccessibility.screenRect(fromView: view, rect: view.isPageColumn ? frame.intersection(view.bounds) : frame)
    }
}
#endif
