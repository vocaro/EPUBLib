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
        // AppKit tells a client of an attribute that the element has been given a value for,
        // and of one whose getter a subclass overrides, whatever the getter returns. So
        // nothing here overrides `accessibilitySelectedCells`: with that attribute VoiceOver
        // says "No selection" after a table's name, or reads its selected row twice.
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
                cell.imagePlaces += spoken.imageFrames.map { (row.location, $0) }
                cell.locations.append(row.location)
                continue
            }
            guard !spoken.text.isEmpty || !spoken.images.isEmpty || (spoken.starts && spoken.isBlank) else { continue }
            let cell = cellsByIndex[spoken.cell] ?? ReaderTableCellElement(table: self, cell: spoken.cell)
            cellsByIndex[spoken.cell] = cell
            cell.row = row
            cell.text = spoken.text
            cell.images = spoken.images
            cell.imagePlaces = spoken.imageFrames.map { (row.location, $0) }
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
    /// text areas or holds an image for each picture it shows: VoiceOver does not read a cell
    /// under itself, and reads a header cell by what each thing the cell holds is called, a
    /// text area by its value, a link by its title and an image by its label, looking no
    /// further in. Otherwise the words of its header cells, top or first one first, as static
    /// text: several header cells, one on another page, or one far off the screen.
    private func headerElement(_ cells: [Int], key: Int) -> NSAccessibilityElement {
        if cells.count == 1, let listed = listed(cells[0]), listed.holdsItsWords { return listed }
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
/// labelled with its words where it has none. A cell whose words are one link and nothing
/// else, a header cell among them, is pressed to follow it, and holds a link called by its
/// words with its text areas inside. A cell that shows pictures holds an image for each: in
/// place of its text areas where it shows nothing else, and after them where the pictures
/// stand among words.
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
    /// Where each of those pictures is drawn: the character of its row, and its box in that
    /// row's coordinates.
    var imagePlaces: [(location: Int, frame: CGRect)] = []
    /// The characters of the rows that hold lines of it here.
    var locations: [Int] = []
    /// Its box in its row's coordinates.
    var frameInRow = CGRect.zero
    /// The link the cell holds where its words are one link (`isLink`).
    private lazy var link = ReaderTableCellLinkElement(cell: self)
    /// The images the cell holds for the pictures it shows (`heldPictures`), kept for as long
    /// as the cell is: VoiceOver asks an element what it is after the read that gave it.
    private var pictures: [ReaderTableCellImageElement] = []

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
    /// that asked for it last, which is the cell of the table VoiceOver is in, or to that
    /// cell's link.
    var textViews: [TableCellTextView] {
        guard let interaction = table?.view?.tableInteraction else { return [] }
        let views = locations.flatMap { interaction.accessibilityCells(at: $0, cell: cell) }
        let holder: NSAccessibilityElement = isLink ? link : self
        for view in views { view.tableCellElement = holder }
        return views
    }

    /// Whether the cell holds what says its words, which is where VoiceOver reads a header
    /// cell's words from: its text areas, or an image for each picture it shows.
    var holdsItsWords: Bool { holdsPictures ? !images.isEmpty : !textViews.isEmpty }

    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityParent() -> Any? { onMain(self) { $0.row ?? $0.table } }
    override func accessibilityRowIndexRange() -> NSRange { onMain(self) { $0.rows } }
    override func accessibilityColumnIndexRange() -> NSRange { onMain(self) { $0.columns } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.held } }
    override func accessibilityVisibleChildren() -> [Any]? { onMain(self) { $0.held } }
    override func accessibilityLabel() -> String? { onMain(self) { $0.isLink || $0.holdsPictures ? nil : $0.unsaid } }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { onMain(self) { $0.actions } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }

    // AppKit lists a press among an element's actions where its class answers one, unless the
    // element says the selector is not allowed. A cell without a press leaves Control-Option-
    // Space to VoiceOver's own means, a click where the cell stands or the press of something
    // inside it: that followed the fixture's link in each session, and nothing says it must.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress) { return onMain(self) { $0.isLink } }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func accessibilityPerformPress() -> Bool { onMain(self) { $0.followLink() } }

    /// The cell's words, where no text view says them: off screen, and for a header cell
    /// given by name. They are the label of a cell that is not a link.
    var unsaid: String? { text.isEmpty || !textViews.isEmpty ? nil : text }

    /// What the cell holds: the text areas of its words and then an image for each picture
    /// among them, or the images alone where it shows nothing else, or the link its text
    /// areas are inside.
    private var held: [Any] {
        if isLink { return [link] }
        if holdsPictures { return heldPictures }
        let views = textViews
        return views.isEmpty ? [] : views + heldPictures
    }

    /// The cell's words are one link and nothing else, where a link goes somewhere: the cell
    /// is pressed to follow it, as a double tap follows it on iPhone and iPad. A cell with
    /// words beside its link, or with several links, has no press: which of them a press
    /// would mean is not the cell's to say, and each link is an action by its words.
    ///
    /// Such a cell holds a link, and the link its text areas, as a web view's cell does. That
    /// is what makes VoiceOver say that the cell is a link as it comes to it: it says what a
    /// cell holds, "Reopened 1978 hyperlink", and nothing of what the cell says it is
    /// (doc/voiceover-testing.md has what it did with a subrole, a role description, a link
    /// in place of the text areas and one beside them). A header cell that is one link holds
    /// one too, and the link's title is how VoiceOver still reads that header before each
    /// cell it heads (`linkTitle`).
    var isLink: Bool {
        guard let table, table.view?.canvas != nil else { return false }
        return table.table.cells[cell].isLink
    }

    /// What the link the cell holds is called: the cell's words, on screen and off it. Off
    /// screen they are all that says them. On screen the link's text areas say them too, and
    /// VoiceOver says them once as it comes to the cell, "Dogwood hyperlink", as it does of
    /// a link without a title. The title is for a header cell: before each cell it heads
    /// VoiceOver said nothing of a header cell whose link had none, "1912" where it says
    /// "Dogwood 1912", and the column's and the row's numbers at Control-Option-C and
    /// Control-Option-R (doc/voiceover-testing.md).
    var linkTitle: String? { text.isEmpty ? nil : text }

    /// The cell shows pictures and nothing else, or nothing at all, and is no link. It holds
    /// an image for each picture that says something, called by the picture's words, and no
    /// text area, as a web view's cell holds an image. VoiceOver says what a cell holds, a
    /// text area by its characters, and a picture's place among a text area's characters is
    /// the attachment's character: at the cell it said the column's header and that
    /// character, for a described picture as for any other. With the image it says "Sign
    /// Blue badge image", and "image cell" for a picture nobody describes. A cell of
    /// decoration alone holds nothing and is "empty cell", like a cell with nothing in it
    /// (doc/voiceover-testing.md has what was heard, and the other ways that were tried).
    var holdsPictures: Bool {
        guard let table, table.view != nil else { return false }
        let model = table.table.cells[cell]
        return model.isWordless && !model.isLink
    }

    /// The image of each picture the cell shows here that says something, in the order they
    /// stand. They are all a cell holds that shows pictures and nothing else. A cell that
    /// shows pictures among words holds them after its text areas. Its words are in a text
    /// area for VoiceOver to read by word, and a picture is nothing VoiceOver says of a text
    /// area at a cell: a transcript has "Crest Worn", the attachment's character and "daily"
    /// there. With the image after the text area it has those and then ", Blue crest image",
    /// the picture's words last wherever the picture stands among the cell's. That costs a
    /// step: such a cell is "cell 2 items", Control-Option-Shift-Down goes to its text area,
    /// and pressed again it goes into the words.
    private var heldPictures: [ReaderTableCellImageElement] {
        while pictures.count < images.count { pictures.append(ReaderTableCellImageElement(cell: self, index: pictures.count)) }
        return Array(pictures.prefix(images.count))
    }

    /// The picture the cell holds its image at `index` for. None once the cell holds no image:
    /// when the view shows other text, for a cell that is a link, and for a cell of words
    /// whose text areas are off screen, which is labelled with all its words.
    func picture(at index: Int) -> ReaderImageAttachment? {
        guard images.indices.contains(index), let table, table.view != nil, !isLink else { return nil }
        return holdsPictures || !textViews.isEmpty ? images[index] : nil
    }

    /// Shows the picture larger, as its Inspect Image action does. False without a reader to
    /// show it in, as in a note's popover.
    func inspect(_ image: ReaderImageAttachment) -> Bool {
        guard let canvas = table?.view?.canvas else { return false }
        canvas.inspectImage(image)
        return true
    }

    /// Where the cell's picture at `index` is drawn, on screen: where VoiceOver draws its
    /// cursor for the picture's image. The cell's own place where the picture has none.
    func screenFrame(ofImage index: Int) -> NSRect {
        guard let table, let view = table.view, imagePlaces.indices.contains(index),
              let rowFrame = table.frame(ofRowAt: imagePlaces[index].location) else { return screenFrame }
        let frame = imagePlaces[index].frame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        return NSAccessibility.screenRect(fromView: view, rect: view.isPageColumn ? frame.intersection(view.bounds) : frame)
    }

    /// Follows the cell's link, as its Follow Link action does: from the text view that shows
    /// the link. False for a cell off screen, which has none until it is brought there.
    func followLink() -> Bool {
        guard isLink, let interaction = table?.view?.tableInteraction else { return false }
        for location in locations {
            if let link = interaction.accessibilityActions(at: location, cell: cell).links.first { return link.perform() }
        }
        return false
    }

    /// What the cell can do itself: show each picture, select its words, follow each link.
    private var actions: [NSAccessibilityCustomAction]? {
        guard let view = table?.view else { return nil }
        var actions = images.map { image in
            NSAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") { [weak self] in
                self?.inspect(image) ?? false
            }
        }
        // Of what a cell offers for its words, selecting them alone is offered here. What a
        // selection is for is the cell's own text area's on a Mac, and VoiceOver's to reach
        // there; iPhone and iPad offer it on the cell, where the text views are hidden.
        var select: ReaderTableAction?
        var links: [NSAccessibilityCustomAction] = []
        for location in locations {
            guard let found = view.tableInteraction?.accessibilityActions(at: location, cell: cell) else { continue }
            if !found.selected { select = select ?? found.selection.first }
            links += found.links.map { link in NSAccessibilityCustomAction(name: "Follow Link: " + link.name) { link.perform() } }
        }
        if let select { actions.append(NSAccessibilityCustomAction(name: select.name) { select.perform() }) }
        actions += links
        return actions.isEmpty ? nil : actions
    }

    var screenFrame: NSRect {
        guard let table, let view = table.view, let location = locations.first, let rowFrame = table.frame(ofRowAt: location) else { return .zero }
        let frame = frameInRow.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        return NSAccessibility.screenRect(fromView: view, rect: view.isPageColumn ? frame.intersection(view.bounds) : frame)
    }
}

/// The link that a cell holds whose words are one link and nothing else: all the cell holds,
/// with the cell's words for its title and the cell's text areas inside it while they are on
/// screen. It has the role of the reader's other links, which VoiceOver calls a hyperlink,
/// stands where the cell does, and is pressed as the cell is.
@MainActor final class ReaderTableCellLinkElement: NSAccessibilityElement {
    /// A client can keep the element after its cell has gone, with the page it was on.
    private weak var cell: ReaderTableCellElement?

    init(cell: ReaderTableCellElement) {
        self.cell = cell
        super.init()
        setAccessibilityRole(.link)
        setAccessibilitySubrole(.textLink)
        setAccessibilityParent(cell)
        setAccessibilityChildren([])
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .link }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .textLink }
    override func accessibilityParent() -> Any? { onMain(self) { $0.cell } }
    override func accessibilityTitle() -> String? { onMain(self) { $0.cell?.linkTitle } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.held } }
    override func accessibilityVisibleChildren() -> [Any]? { onMain(self) { $0.held } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.cell?.screenFrame ?? .zero } }
    override func accessibilityPerformPress() -> Bool { onMain(self) { $0.cell?.followLink() ?? false } }

    /// The cell's text areas, while the cell holds this link.
    private var held: [TableCellTextView] {
        guard let cell, cell.isLink else { return [] }
        return cell.textViews
    }
}

/// A picture a cell of a table of data shows: an image called by the picture's words, or by
/// nothing where nobody describes it, which VoiceOver says in its own word. It stands where
/// the picture is drawn, holds nothing, and offers the picture's Inspect Image as the cell
/// does. It has no help. The image VoiceOver is given at a picture's character in text has
/// the sentence about Inspect Image for its help, and VoiceOver read that into the cell's
/// phrase each time it came to the cell: "Sign Blue badge image Double-click or choose
/// Inspect Image to enlarge."
@MainActor final class ReaderTableCellImageElement: NSAccessibilityElement {
    /// A client can keep the element after its cell has gone, with the page it was on.
    private weak var cell: ReaderTableCellElement?
    /// Which of the pictures its cell shows.
    let index: Int

    init(cell: ReaderTableCellElement, index: Int) {
        self.cell = cell
        self.index = index
        super.init()
        setAccessibilityRole(.image)
        setAccessibilityParent(cell)
        setAccessibilityChildren([])
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityParent() -> Any? { onMain(self) { $0.cell } }
    override func accessibilityLabel() -> String? { onMain(self) { $0.words } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.cell?.screenFrame(ofImage: $0.index) ?? .zero } }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { onMain(self) { $0.actions } }

    /// The picture, while its cell shows it and holds this image for it.
    private var image: ReaderImageAttachment? { cell?.picture(at: index) }

    private var words: String? {
        guard let alt = image?.alt, !alt.isEmpty else { return nil }
        return alt
    }

    private var actions: [NSAccessibilityCustomAction]? {
        guard let image else { return nil }
        return [NSAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") { [weak cell] in
            cell?.inspect(image) ?? false
        }]
    }
}
#endif
