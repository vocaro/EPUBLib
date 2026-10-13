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

/// PROTOTYPE switches, read from the launch arguments, for hearing what VoiceOver does with each
/// shape before one is chosen. Removed with the choice.
enum ReaderDataTablePrototype {
    /// What stands at a row's character in the text: `group` (the row group every table has
    /// today), `rows` (the row, whose parent is the table), `table` (the table, at each of its
    /// rows) or `first` (the table at its first row and nothing at the others).
    static var shape: String { UserDefaults.standard.string(forKey: "ReaderMacTableShape") ?? "group" }
    /// What a cell holds: `area` (the cell's text views), `static` (one static text) or
    /// `label` (nothing, and the cell is labelled with its words).
    static var cellText: String { UserDefaults.standard.string(forKey: "ReaderMacTableCellText") ?? "area" }
    /// Whether a text view lists its tables among its children.
    static var listsTables: Bool { UserDefaults.standard.bool(forKey: "ReaderMacTableChildren") }
    /// Whether a row is labelled with its cells' words.
    static var labelsRows: Bool { UserDefaults.standard.bool(forKey: "ReaderMacTableRowLabel") }
    /// Whether the table at a row's character (`proxies`) says that row is selected.
    static var selects: Bool { UserDefaults.standard.bool(forKey: "ReaderMacTableSelects") }
    /// Whether the rows it says are visible begin at that row.
    static var visibleFromEntry: Bool { UserDefaults.standard.bool(forKey: "ReaderMacTableVisibleFromEntry") }
    /// Whether the table at a row's character (`proxies`) calls itself a table row.
    static var rowWord: Bool { UserDefaults.standard.bool(forKey: "ReaderMacTableRowWord") }
    /// Whether the one table (`table`) is labelled, with its first row's words.
    static var labelsTable: Bool { UserDefaults.standard.bool(forKey: "ReaderMacTableLabel") }
}

/// The tables of data in one text view, as an assistive technology on the Mac is given them:
/// a table element for each, with its rows, columns, cells and header cells.
@MainActor final class ReaderDataTables {
    private weak var view: ReaderTextView?
    private var tables: [ObjectIdentifier: ReaderTableElement] = [:]
    /// PROTOTYPE (`proxies`): a table for each row's character, entered at that row.
    private var proxies: [Int: ReaderTableElement] = [:]
    private var order: [ReaderTableElement] = []
    /// The row characters of every table of data in the view's text, in order, by table.
    private var found: [ObjectIdentifier: [(location: Int, row: TableRowAttachment)]]?

    init(view: ReaderTextView) { self.view = view }

    /// The view has other text: its tables are other tables.
    func reset() {
        tables.removeAll()
        proxies.removeAll()
        order.removeAll()
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

    func table(_ model: TableModel) -> ReaderTableElement? {
        guard let view else { return nil }
        if let kept = tables[ObjectIdentifier(model)] { return kept }
        let element = ReaderTableElement(view: view, owner: self, table: model)
        tables[ObjectIdentifier(model)] = element
        order.append(element)
        return element
    }

    /// The tables an assistive technology has been given so far, in the order it met them.
    var elements: [ReaderTableElement] { order.filter { !$0.rowElements.isEmpty } }

    /// What stands for the row at `location` among the text's characters.
    func element(at location: Int, of row: TableRowAttachment) -> NSAccessibilityElement? {
        if ReaderDataTablePrototype.shape == "proxies", let view {
            if let kept = proxies[location] { return kept }
            let proxy = ReaderDataTablePrototype.selects
                ? ReaderSelectingTableElement(view: view, owner: self, table: row.table, entry: location)
                : ReaderTableElement(view: view, owner: self, table: row.table, entry: location)
            proxies[location] = proxy
            return proxy
        }
        guard let table = table(row.table) else { return nil }
        switch ReaderDataTablePrototype.shape {
        case "table": return table
        case "first": return table.rowElements.first?.location == location ? table : nil
        default: return table.rowElements.first { $0.location == location }
        }
    }
}

/// A table of data: `NSAccessibility`'s table, with the rows the view shows of it.
@MainActor class ReaderTableElement: NSAccessibilityElement {
    private(set) weak var view: ReaderTextView?
    private weak var owner: ReaderDataTables?
    let table: TableModel
    /// PROTOTYPE (`proxies`): the character of the row this table stands at in the text.
    let entry: Int?
    private var rowsByLocation: [Int: ReaderTableRowElement] = [:]
    private var cellsByIndex: [Int: ReaderTableCellElement] = [:]
    private var unlistedHeaders: [Int: ReaderTableCellElement] = [:]
    private var columns: [ReaderTableColumnElement] = []
    /// The rows and cells listed, for the layout they were listed in.
    private var listing: (key: [CGFloat], rows: [ReaderTableRowElement], cells: [Int: ReaderTableCellElement])?

    init(view: ReaderTextView, owner: ReaderDataTables, table: TableModel, entry: Int? = nil) {
        self.view = view
        self.owner = owner
        self.table = table
        self.entry = entry
        super.init()
        // AppKit tells a client of the attributes an element has been given a value for.
        setAccessibilityRole(.table)
        setAccessibilityParent(view)
        setAccessibilityRows([])
        setAccessibilityVisibleRows([])
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

    // MARK: What the view shows of the table

    /// The row's frame in the view's coordinates, laid out if it was not.
    func frame(ofRowAt location: Int) -> CGRect? {
        guard let view, let range = view.textRange(for: NSRange(location: location, length: 1)) else { return nil }
        view.readerLayoutManager.ensureLayout(for: range)
        let origin = view.containerOrigin
        return view.segmentFrames(for: NSRange(location: location, length: 1)).first?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The rows the view shows, each with the cells read where it stands. A cell is read where
    /// it has something to say: where it starts, or in pages in the first row of the page that
    /// holds lines of it. A cell with nothing to say anywhere is read where it starts.
    private func list() -> (rows: [ReaderTableRowElement], cells: [Int: ReaderTableCellElement]) {
        guard let view, let owner else { return ([], [:]) }
        let key = [view.bounds.width, view.readerContainer.viewportSize.width, view.readerContainer.viewportSize.height,
                   CGFloat(view.shownCharacters.length)]
        if let listing, listing.key == key { return (listing.rows, listing.cells) }
        var rows: [ReaderTableRowElement] = [], cells: [Int: ReaderTableCellElement] = [:]
        for (location, row) in owner.rows(of: table) {
            let element = rowsByLocation[location] ?? ReaderTableRowElement(table: self, location: location, row: row)
            rowsByLocation[location] = element
            element.cells = []
            rows.append(element)
            guard let frame = frame(ofRowAt: location) else { continue }
            for spoken in row.spokenCells(size: frame.size, viewportHeight: view.readerContainer.viewportSize.height) {
                if let listed = cells[spoken.cell] {
                    listed.text = [listed.text, spoken.text].filter { !$0.isEmpty }.joined(separator: " ")
                    listed.images += spoken.images
                    listed.locations.append(location)
                    continue
                }
                guard !spoken.text.isEmpty || !spoken.images.isEmpty || (spoken.starts && spoken.isBlank) else { continue }
                let cell = cellsByIndex[spoken.cell] ?? ReaderTableCellElement(table: self, cell: spoken.cell)
                cellsByIndex[spoken.cell] = cell
                cell.row = element
                cell.text = spoken.text
                cell.images = spoken.images
                cell.locations = [location]
                cell.frameInRow = spoken.frame
                cells[spoken.cell] = cell
                element.cells.append(cell)
            }
        }
        listing = (key, rows, cells)
        return (rows, cells)
    }

    var rowElements: [ReaderTableRowElement] { list().rows }
    var listedCells: [Int: ReaderTableCellElement] { list().cells }

    /// The element of a header cell: the one listed, or for a header cell on another page its
    /// words alone, for VoiceOver to say and nowhere for its cursor to go.
    func header(_ cell: Int) -> ReaderTableCellElement? {
        if let listed = listedCells[cell] { return listed }
        if let kept = unlistedHeaders[cell] { return kept }
        guard table.cells.indices.contains(cell), !table.cells[cell].text.isEmpty else { return nil }
        let name = ReaderTableCellElement(table: self, cell: cell)
        name.text = table.cells[cell].text
        unlistedHeaders[cell] = name
        return name
    }

    /// The header cells of the columns `cell` stands in that are above it, and of its rows
    /// that are before it.
    func headers(of cell: Int) -> (columns: [ReaderTableCellElement], rows: [ReaderTableCellElement]) {
        let model = table.cells[cell]
        var above: [Int] = [], before: [Int] = []
        for column in model.column..<min(table.columnCount, model.column + model.columnSpan) {
            for header in table.columnHeaders(column) where header != cell && table.cells[header].row < model.row && !above.contains(header) {
                above.append(header)
            }
        }
        for row in model.row..<min(table.rows.count, model.row + model.rowSpan) {
            for header in table.rowHeaders(row) where header != cell && table.cells[header].column < model.column && !before.contains(header) {
                before.append(header)
            }
        }
        return (above.compactMap { header($0) }, before.compactMap { header($0) })
    }

    func cells(inColumn column: Int) -> [ReaderTableCellElement] {
        rowElements.flatMap { $0.cells }.filter { NSLocationInRange(column, $0.columns) }
    }

    // MARK: NSAccessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityParent() -> Any? { onMain(self) { $0.view } }
    override func accessibilityRows() -> [Any]? { onMain(self) { $0.rowElements } }
    override func accessibilityVisibleRows() -> [Any]? { onMain(self) { $0.visibleRows } }
    private var visibleRows: [ReaderTableRowElement] {
        guard let view else { return [] }
        let visible = view.visibleRect
        var rows = rowElements.filter { frame(ofRowAt: $0.location).map { !$0.intersection(visible).isEmpty } ?? false }
        if ReaderDataTablePrototype.visibleFromEntry, let entry { rows = rows.filter { $0.location >= entry } }
        return rows
    }
    override func accessibilityColumns() -> [Any]? { onMain(self) { $0.columns } }
    override func accessibilityVisibleColumns() -> [Any]? { onMain(self) { $0.columns } }
    override func accessibilityVisibleCells() -> [Any]? { onMain(self) { $0.visibleRows.flatMap { $0.cells } } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.rowElements + $0.columns } }
    override func accessibilityRowCount() -> Int { onMain(self) { $0.table.rows.count } }
    override func accessibilityColumnCount() -> Int { onMain(self) { $0.table.columnCount } }
    override func accessibilityColumnHeaderUIElements() -> [Any]? { onMain(self) { $0.columnHeaders } }
    override func accessibilityRowHeaderUIElements() -> [Any]? { onMain(self) { $0.rowHeaders } }
    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? { onMain(self) { $0.cell(column: column, row: row) } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }
    override func accessibilityLabel() -> String? { onMain(self) { $0.words } }
    override func accessibilityRoleDescription() -> String? {
        onMain(self) { $0.entry != nil && ReaderDataTablePrototype.rowWord ? "table row" : NSAccessibility.Role.table.description(with: nil) }
    }

    /// The row the table stands at in the text.
    fileprivate var selected: ReaderTableRowElement? {
        guard let entry else { return nil }
        return rowElements.first { $0.location == entry }
    }
    /// What the table is called: the words of the row it stands at.
    private var words: String? {
        let row = entry.flatMap { entry in rowElements.first { $0.location == entry } } ?? (ReaderDataTablePrototype.labelsTable ? rowElements.first : nil)
        return row.map { $0.cells.map { $0.text }.filter { !$0.isEmpty }.joined(separator: ", ") }
    }

    /// The cells that head a column, in column order and top first in each.
    private var columnHeaders: [ReaderTableCellElement] {
        var seen: [Int] = []
        for column in 0..<table.columnCount { for header in table.columnHeaders(column) where !seen.contains(header) { seen.append(header) } }
        return seen.compactMap { header($0) }
    }
    /// The cells that head a row, in row order.
    private var rowHeaders: [ReaderTableCellElement] {
        var seen: [Int] = []
        for row in table.rows.indices { for header in table.rowHeaders(row) where !seen.contains(header) { seen.append(header) } }
        return seen.compactMap { header($0) }
    }
    /// The cell that covers a slot of the grid, where the view shows it.
    func cell(column: Int, row: Int) -> ReaderTableCellElement? {
        guard table.rowCells.indices.contains(row) else { return nil }
        let cell = table.rowCells[row].first { table.cells[$0].column <= column && column < table.cells[$0].column + table.cells[$0].columnSpan }
        return cell.flatMap { listedCells[$0] }
    }
    private var screenFrame: NSRect {
        guard let view else { return .zero }
        let locations = entry.map { [$0] } ?? rowElements.map(\.location)
        let frame = locations.compactMap { frame(ofRowAt: $0) }.reduce(CGRect.null) { $0.union($1) }
        return frame.isNull ? .zero : NSAccessibility.screenRect(fromView: view, rect: frame)
    }
}

/// PROTOTYPE (`proxies` with a selection): a table that says the row it stands at is selected.
/// VoiceOver says "No selection" of any table that has the attribute, so a table that selects
/// nothing must not have it.
@MainActor final class ReaderSelectingTableElement: ReaderTableElement {
    override func accessibilitySelectedRows() -> [Any]? { onMain(self) { $0.selected.map { [$0] } ?? [] } }
}

/// A row of a table of data, where it stands in the view: a whole row, or in pages the part of
/// one a page shows.
@MainActor final class ReaderTableRowElement: NSAccessibilityElement {
    private unowned let table: ReaderTableElement
    let location: Int
    let row: TableRowAttachment
    var cells: [ReaderTableCellElement] = []

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

    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .tableRow }
    override func accessibilityParent() -> Any? { onMain(self) { $0.table } }
    override func accessibilityIndex() -> Int { onMain(self) { $0.row.row } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.listedCells } }
    override func accessibilityVisibleChildren() -> [Any]? { onMain(self) { $0.listedCells } }
    override func accessibilityLabel() -> String? { onMain(self) { $0.rowWords } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }

    /// The cells read in the row, as the view shows them now.
    var listedCells: [ReaderTableCellElement] {
        _ = table.rowElements
        return cells
    }
    private var rowWords: String? {
        guard ReaderDataTablePrototype.labelsRows else { return nil }
        return listedCells.map { $0.text }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private var screenFrame: NSRect {
        guard let view = table.view, let frame = table.frame(ofRowAt: location) else { return .zero }
        return NSAccessibility.screenRect(fromView: view, rect: frame)
    }
}

/// A column of a table of data: the cells the view shows of it.
@MainActor final class ReaderTableColumnElement: NSAccessibilityElement {
    private unowned let table: ReaderTableElement
    let column: Int

    init(table: ReaderTableElement, column: Int) {
        self.table = table
        self.column = column
        super.init()
        setAccessibilityRole(.column)
        setAccessibilityParent(table)
        setAccessibilityIndex(column)
        setAccessibilityChildren([])
        setAccessibilityRows([])
        setAccessibilityVisibleRows([])
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .column }
    override func accessibilityParent() -> Any? { onMain(self) { $0.table } }
    override func accessibilityIndex() -> Int { onMain(self) { $0.column } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.table.cells(inColumn: $0.column) } }
    override func accessibilityHeader() -> Any? { onMain(self) { $0.header } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }
    private var header: ReaderTableCellElement? { table.table.columnHeaders(column).first.flatMap { table.header($0) } }
    private var screenFrame: NSRect { table.cells(inColumn: column).map { $0.screenFrame }.reduce(NSRect.null) { $0.union($1) } }
}

/// A cell of a table of data, where the view shows it.
@MainActor final class ReaderTableCellElement: NSAccessibilityElement {
    private unowned let table: ReaderTableElement
    let cell: Int
    /// The row it is read in. None for a header cell on another page.
    weak var row: ReaderTableRowElement?
    /// The words it shows here.
    var text = ""
    /// The pictures among them that say something.
    var images: [ReaderImageAttachment] = []
    /// The characters of the rows that hold lines of it here.
    var locations: [Int] = []
    /// Its box in its row's coordinates.
    var frameInRow = CGRect.zero
    private lazy var words: NSAccessibilityElement = {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.staticText)
        element.setAccessibilityParent(self)
        return element
    }()

    init(table: ReaderTableElement, cell: Int) {
        self.table = table
        self.cell = cell
        super.init()
        let model = table.table.cells[cell]
        setAccessibilityRole(.cell)
        setAccessibilityRowIndexRange(NSRange(location: model.row, length: model.rowSpan))
        setAccessibilityColumnIndexRange(NSRange(location: model.column, length: model.columnSpan))
        setAccessibilityColumnHeaderUIElements([])
        setAccessibilityRowHeaderUIElements([])
        setAccessibilityChildren([])
    }

    /// The text views that hold the cell's words here, where they are on screen.
    private var textViews: [TableCellTextView] {
        guard let interaction = table.view?.tableInteraction else { return [] }
        return locations.flatMap { interaction.accessibilityCells(at: $0, cell: cell) }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityParent() -> Any? { onMain(self) { $0.row ?? $0.table } }
    override func accessibilityRowIndexRange() -> NSRange { onMain(self) { $0.rows } }
    override func accessibilityColumnIndexRange() -> NSRange { onMain(self) { $0.columns } }
    var rows: NSRange { NSRange(location: table.table.cells[cell].row, length: table.table.cells[cell].rowSpan) }
    var columns: NSRange { NSRange(location: table.table.cells[cell].column, length: table.table.cells[cell].columnSpan) }
    override func accessibilityColumnHeaderUIElements() -> [Any]? { onMain(self) { $0.table.headers(of: $0.cell).columns } }
    override func accessibilityRowHeaderUIElements() -> [Any]? { onMain(self) { $0.table.headers(of: $0.cell).rows } }
    override func accessibilityChildren() -> [Any]? { onMain(self) { $0.held } }
    override func accessibilityVisibleChildren() -> [Any]? { onMain(self) { $0.held } }
    override func accessibilityLabel() -> String? { onMain(self) { $0.label } }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { onMain(self) { $0.actions } }
    override func accessibilityFrame() -> NSRect { onMain(self) { $0.screenFrame } }

    /// What the cell holds for an assistive technology.
    private var held: [Any] {
        switch ReaderDataTablePrototype.cellText {
        case "label": return []
        case "static":
            guard !text.isEmpty else { return [] }
            words.setAccessibilityValue(text)
            return [words]
        default:
            let views = textViews
            for view in views { view.tableCellElement = self }
            return views
        }
    }
    private var label: String? {
        if ReaderDataTablePrototype.cellText == "label" || held.isEmpty { return text.isEmpty ? nil : text }
        return nil
    }
    private var actions: [NSAccessibilityCustomAction]? {
        guard let view = table.view else { return nil }
        var actions = images.map { image in
            NSAccessibilityCustomAction(name: image.alt.isEmpty ? "Inspect Image" : "Inspect Image: \(image.alt)") { [weak view] in
                guard let canvas = view?.canvas else { return false }
                canvas.inspectImage(image)
                return true
            }
        }
        var select: (@MainActor () -> Bool)?
        for location in locations {
            guard let found = view.tableInteraction?.accessibilityActions(at: location, cell: cell) else { continue }
            select = select ?? found.select
            actions += found.links.map { link in NSAccessibilityCustomAction(name: "Follow Link: " + link.name) { link.perform() } }
        }
        if let select { actions.insert(NSAccessibilityCustomAction(name: "Select Cell Text") { select() }, at: images.count) }
        return actions.isEmpty ? nil : actions
    }
    var screenFrame: NSRect {
        guard let view = table.view, let location = locations.first, let rowFrame = table.frame(ofRowAt: location) else { return .zero }
        let frame = frameInRow.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        return NSAccessibility.screenRect(fromView: view, rect: view.isPageColumn ? frame.intersection(view.bounds) : frame)
    }
}
#endif
