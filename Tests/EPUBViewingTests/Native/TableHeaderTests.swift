import XCTest
@testable import EPUBViewing

/// What a table's markup says of it to someone who cannot see its grid (doc/native-viewer.md,
/// "Tables"): which cells head a column or a row, by HTML's rule for a `th` (§4.9.12.2, "a
/// column header" and "a row header"), and whether the table is data at all.
final class TableHeaderTests: XCTestCase {
    private func texts(_ cells: [Int], in table: TableModel) -> [String] { cells.map { table.cells[$0].text } }

    private func columnHeaders(_ table: TableModel) -> [[String]] { (0..<table.columnCount).map { texts(table.columnHeaders($0), in: table) } }

    private func rowHeaders(_ table: TableModel) -> [[String]] { table.rows.indices.map { texts(table.rowHeaders($0), in: table) } }

    func testAHeaderRowHeadsItsColumnsAndAHeaderColumnItsRows() throws {
        let table = try TableCoverage.table("""
        <table><thead><tr><th>Station</th><th>Opened</th><th>Depth</th></tr></thead>
        <tbody><tr><th scope="row">Alder</th><td>1901</td><td>Twelve</td></tr>
        <tr><th scope="row">Birch</th><td>1934</td><td></td></tr></tbody></table>
        """)
        XCTAssertEqual(columnHeaders(table), [["Station"], ["Opened"], ["Depth"]])
        XCTAssertEqual(rowHeaders(table), [[], ["Alder"], ["Birch"]])
        // Past the grid there is nothing, and no trap.
        XCTAssertEqual(table.columnHeaders(3), [])
        XCTAssertEqual(table.rowHeaders(-1), [])
    }

    /// Without `scope` and without `<thead>`: a `th` heads its columns when its row holds header
    /// cells alone, and otherwise its row when its column holds header cells alone.
    func testAHeaderCellWithoutScopeGoesByWhatItsRowAndColumnHold() throws {
        let table = try TableCoverage.table("""
        <table><tr><th>Corner</th><th>North</th><th>South</th></tr>
        <tr><th>Day</th><td>One</td><td>Two</td></tr>
        <tr><th>Night</th><td>Three</td><th>Stray</th></tr></table>
        """)
        XCTAssertEqual(columnHeaders(table), [["Corner"], ["North"], ["South"]], "the first row is header cells alone")
        XCTAssertEqual(rowHeaders(table), [[], ["Day"], ["Night"]],
                       "the first column is header cells alone; a header cell among data in its row and its column heads neither")
    }

    func testScopeDecidesWhateverStandsAroundTheCell() throws {
        let table = try TableCoverage.table("""
        <table><tr><td>Plain</td><th scope="col">Price</th><th scope="colgroup">Stock</th></tr>
        <tr><th scope="row">Pears</th><td>Four</td><td>Nine</td></tr>
        <tr><th scope="rowgroup">Plums</th><td>Six</td><td>None</td></tr></table>
        """)
        XCTAssertEqual(columnHeaders(table), [[], ["Price"], ["Stock"]])
        XCTAssertEqual(rowHeaders(table), [[], ["Pears"], ["Plums"]])
        XCTAssertEqual(table.cells[try TableCoverage.cell("Price", in: table)].scope, .column)
        XCTAssertEqual(table.cells[try TableCoverage.cell("Plain", in: table)].scope, .automatic, "a data cell has no scope")
    }

    /// A header cell that spans heads every column or row it covers, and a column under two
    /// header rows has both, the upper first.
    func testSpanningHeaderCellsHeadEveryColumnAndRowTheyCover() throws {
        let table = try TableCoverage.table("""
        <table><tr><th rowspan="2">Service</th><th colspan="2">Hours</th></tr>
        <tr><th>Leaves</th><th>Arrives</th></tr>
        <tr><th rowspan="2" scope="row">Stopper</th><td>Ten</td><td>Three</td></tr>
        <tr><td colspan="2">Nothing on Sunday</td></tr></table>
        """)
        XCTAssertEqual(columnHeaders(table), [["Service"], ["Hours", "Leaves"], ["Hours", "Arrives"]])
        XCTAssertEqual(rowHeaders(table), [[], [], ["Stopper"], ["Stopper"]])
    }

    // MARK: Data or layout

    private func isData(_ markup: String, css: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        try TableCoverage.table(markup, css: css, file: file, line: line).isData
    }

    private let rows = "<tr><td>One</td><td>Two</td></tr><tr><td>Three</td><td>Four</td></tr>"

    func testATableIsDataWhenItsMarkupSaysSo() throws {
        XCTAssertFalse(try isData("<table>\(rows)</table>"), "rows of plain cells, unruled, arrange content")
        XCTAssertTrue(try isData("<table><caption>Named</caption>\(rows)</table>"))
        XCTAssertTrue(try isData("<table><caption style='display: none'>Named</caption>\(rows)</table>"), "a caption nobody is shown still says so")
        XCTAssertTrue(try isData("<table><thead>\(rows)</thead><tbody>\(rows)</tbody></table>"))
        XCTAssertTrue(try isData("<table><tbody>\(rows)</tbody><tfoot>\(rows)</tfoot></table>"))
        XCTAssertFalse(try isData("<table><tbody>\(rows)</tbody></table>"), "a body alone is what every table has")
        XCTAssertTrue(try isData("<table><col/><col/>\(rows)</table>"))
        XCTAssertTrue(try isData("<table><colgroup span='2'/>\(rows)</table>"))
        XCTAssertTrue(try isData("<table summary='Sums'>\(rows)</table>"))
        XCTAssertFalse(try isData("<table summary=' '>\(rows)</table>"), "an empty summary says nothing")
        XCTAssertTrue(try isData("<table rules='rows'>\(rows)</table>"))
        for attribute in ["headers='a'", "scope='row'", "abbr='One'", "axis='count'", "role='gridcell'"] {
            XCTAssertTrue(try isData("<table><tr><td \(attribute)>One</td><td>Two</td></tr></table>"), attribute)
        }
        XCTAssertTrue(try isData("<table><tr role='row'><td>One</td><td>Two</td></tr></table>"))
        XCTAssertTrue(try isData("<table><tr><td>One</td><td>Two</td></tr><tr><td>Three</td><th>Four</th></tr></table>"),
                      "a header cell anywhere: wider than WebKit, which wants a first row or column of them")
    }

    func testARoleDecidesWhateverTheTableHolds() throws {
        let marked = "<caption>Named</caption><thead><tr><th>One</th><th>Two</th></tr></thead>\(rows)"
        XCTAssertFalse(try isData("<table role='presentation'>\(marked)</table>"))
        XCTAssertFalse(try isData("<table role=' None '>\(marked)</table>"))
        for role in ["table", "grid", "treegrid"] { XCTAssertTrue(try isData("<table role='\(role)'>\(rows)</table>"), role) }
        XCTAssertFalse(try isData("<table role='list'>\(rows)</table>"), "another role says nothing of data, and the rows have none")
    }

    func testATableOfTwentyRowsOrTwentyCellsInARowIsData() throws {
        func table(rows: Int, cells: Int) -> String {
            "<table>" + String(repeating: "<tr>" + String(repeating: "<td>x</td>", count: cells) + "</tr>", count: rows) + "</table>"
        }
        XCTAssertFalse(try isData(table(rows: 19, cells: 2)))
        XCTAssertTrue(try isData(table(rows: 20, cells: 2)))
        XCTAssertFalse(try isData(table(rows: 2, cells: 19)))
        XCTAssertTrue(try isData(table(rows: 2, cells: 20)))
        // One cell across twenty columns is one cell.
        XCTAssertFalse(try isData("<table><tr><td>a</td><td colspan='19'>b</td></tr><tr><td>c</td><td colspan='19'>d</td></tr></table>"))
    }

    /// Ruled as a grid: half the cells with a rule on two facing sides, or on any one side. The
    /// table's `border` attribute rules every cell. A rule around the table alone does not.
    func testATableRuledAsAGridIsData() throws {
        XCTAssertTrue(try isData("<table>\(rows)</table>", css: "td { border: 1px solid black; }"))
        XCTAssertTrue(try isData("<table>\(rows)</table>", css: "td { border-bottom: 1px solid black; }"), "one side of every cell")
        XCTAssertTrue(try isData("<table border='1'>\(rows)</table>"))
        XCTAssertFalse(try isData("<table>\(rows)</table>", css: "table { border: 1px solid black; }"), "a frame is not a grid")
        XCTAssertFalse(try isData("<table>\(rows)</table>", css: "td { border: 1px none black; }"), "a rule that is not drawn")
        let one = "<table><tr><td class='ruled'>a</td><td>b</td><td>c</td></tr><tr><td>d</td><td>e</td><td>f</td></tr></table>"
        XCTAssertFalse(try isData(one, css: ".ruled { border: 1px solid black; }"), "one cell of six")
        let half = "<table><tr><td class='ruled'>a</td><td class='ruled'>b</td><td class='ruled'>c</td></tr><tr><td>d</td><td>e</td><td>f</td></tr></table>"
        XCTAssertTrue(try isData(half, css: ".ruled { border-top: 1px solid black; }"), "three cells of six")
        // The same in the dark appearance, where the rules are drawn in another colour.
        let dark = try TableCoverage.table("<table>\(rows)</table>", css: "td { border: 1px solid black; }",
                                           typography: NativeTypography(fontSize: 16, isDark: true))
        XCTAssertTrue(dark.isData)
    }

    /// WebKit also calls a table data for cells with a background of their own or rows of
    /// alternating backgrounds. The reader does not: the dark appearance computes no
    /// backgrounds, and a table is the same thing to a listener in either appearance.
    func testBackgroundsDoNotMakeATableDataInEitherAppearance() throws {
        let striped = "<table>" + ["even", "odd", "even", "odd", "even"].map { "<tr class='\($0)'><td>a</td><td>b</td></tr>" }.joined() + "</table>"
        let css = ".odd { background: #eee; } .even { background: #fff; } td { background: #ddd; }"
        for isDark in [false, true] {
            let table = try TableCoverage.table(striped, css: css, typography: NativeTypography(fontSize: 16, isDark: isDark))
            XCTAssertFalse(table.isData, isDark ? "dark" : "light")
        }
    }
}
