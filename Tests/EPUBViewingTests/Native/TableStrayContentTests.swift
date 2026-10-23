import CoreGraphics
import EPUBCore
import EPUBReading
import XCTest
@testable import EPUBViewing

/// Nothing a table holds is dropped. XHTML is parsed as XML, which repairs no tree, so content
/// written outside a table's rows and cells arrives where it was written; CSS 2.2 §17.2.1 gives
/// it anonymous rows and cells, and §17.4 shows every caption. What the grid has no slot for
/// (a cell past its 200 columns or 20,000 cells) follows the table and is disclosed.
final class TableStrayContentTests: XCTestCase {
    private func plain(_ body: String, css: String = "") throws -> String {
        try TableCoverage.section(body, css: css).string.readerPlainText()
    }

    private func grid(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws -> [[String]] {
        TableCoverage.grid(try TableCoverage.table(body, file: file, line: line))
    }

    private static let token = try! NSRegularExpression(pattern: "[vhcn][0-9]+")

    private func tokens(in text: String) -> [String] {
        Self.token.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map { (text as NSString).substring(with: $0.range) }
    }

    // MARK: Every shape at once

    /// Some 2,100 tables: each kind of content at the start, in the middle and at the end of a
    /// table, of each row group and of a row, on two columns and on one, the same as the
    /// forgiving HTML parser leaves them, shapes written out one by one, and 600 mixed at random.
    /// Each word is shown once, hidden words never, and what is shown maps back to its source.
    /// (`testRowsPastTheCellBoundFollowTheTableInOrder` has the table past the cell bound.)
    func testEveryWordWrittenInATableIsShownExactlyOnce() throws {
        var grids = 0, locatedInCells = 0
        for item in TableStrayCorpus.all() {
            let section = try TableCoverage.section(item.body)
            XCTAssertEqual(section.report.recoveredAsHTML, item.recovered, item.name)
            let shown = tokens(in: section.string.readerPlainText()).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            var written: Set<String> = []
            for node in section.document.nodes where node.isText { written.formUnion(tokens(in: node.text)) }
            let notes = section.notes.values.map { $0.readerPlainText() }.joined(separator: " ")
            for word in written.sorted() {
                switch word.first {
                case "v": XCTAssertEqual(shown[word], 1, "\(word) in \(item.name): \(item.body)")
                case "n":
                    XCTAssertNil(shown[word], "\(word) in \(item.name): a footnote is not in the flow")
                    XCTAssertTrue(tokens(in: notes).contains(word), "\(word) in \(item.name): the note is kept")
                // HTML's `col` is void, so the recovered tree holds what was written in it as the
                // table's own text; in XML it is the column's content, which has no box.
                case "c" where item.recovered: break
                default: XCTAssertNil(shown[word], "\(word) in \(item.name): \(item.body)")
                }
            }
            XCTAssertEqual(Set(shown.keys).subtracting(written), [], item.name)
            BuilderHarness.assertMapRoundTrips(section)
            // A word in a cell, written as one or not, is found at its characters and maps back.
            // The grids say which words those are: the ones among a cell's own characters. (A
            // word of a table nested in the cell is that table's row, a unit of the cell.)
            let models = TableCoverage.tables(in: section.string)
            grids += models.isEmpty ? 0 : 1
            let inCells = Set(models.flatMap(\.cells).flatMap { tokens(in: $0.content.string) })
            for node in section.document.nodes where node.isText {
                let text = node.text as NSString
                for match in Self.token.matches(in: node.text, range: NSRange(location: 0, length: text.length)) {
                    let word = text.substring(with: match.range)
                    guard word.hasPrefix("v"), inCells.contains(word) else { continue }
                    let source = DOMPosition(node, match.range.location)
                    let position = section.renderedPosition(source)
                    guard let endpoint = position.tableCell, let cell = section.tableCell(position) else {
                        XCTFail("\(word) in \(item.name) is in a cell and is not located in one: \(item.body)")
                        continue
                    }
                    let content = cell.content.string as NSString
                    guard endpoint.offset + match.range.length <= content.length else {
                        XCTFail("\(word) in \(item.name) is located past the end of its cell: \(item.body)")
                        continue
                    }
                    XCTAssertEqual(content.substring(with: NSRange(location: endpoint.offset, length: match.range.length)), word, item.name)
                    XCTAssertEqual(section.domPosition(position), source, item.name)
                    locatedInCells += 1
                }
            }
        }
        // Exact, so that words no longer in any cell are told from words in a cell not located.
        XCTAssertEqual(grids, 1_408)
        XCTAssertEqual(locatedInCells, 10_199)
    }

    // MARK: Anonymous rows and cells

    /// CSS 2.2 §17.2.1: what a table holds that is not a row, a row group, a column or a caption
    /// gets an anonymous row around it and its like neighbours, and in that row what is not a
    /// cell gets an anonymous cell.
    func testContentBetweenRowsTakesAnAnonymousRowWhereItIsWritten() throws {
        let section = try TableCoverage.section("""
        <table><tr><td>A</td><td>B</td></tr>Loose text<p>Paragraph</p><td>Cell</td><tr><td>C</td><td>D</td></tr></table>
        """)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(TableCoverage.grid(table), [["A@0", "B@1"], ["Loose text Paragraph@0", "Cell@1"], ["C@0", "D@1"]])
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(section.string.string, "\u{FFFC}\n\u{FFFC}\n\u{FFFC}")
        XCTAssertEqual(section.string.readerPlainText(), "A\tB\nLoose text Paragraph\tCell\nC\tD")
        XCTAssertEqual(table.sourceRowOffsets, [0: 0, 1: 2, 2: 4])
        XCTAssertNil(section.report.unsupportedElements["table"])
        XCTAssertGreaterThan(table.layout(available: 320, viewportHeight: 500).rowHeights[1], 0)
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testContentBetweenCellsTakesAnAnonymousCellWhereItIsWritten() throws {
        XCTAssertEqual(try grid("<table><tr><td>A</td><p>X</p><td>B</td>tail</tr><tr><td>C</td><td>D</td></tr></table>"),
                       [["A@0", "X@1", "B@2", "tail@3"], ["C@0", "D@1"]])
        XCTAssertEqual(try grid("<table><tr>lead <i>in</i><td>A</td><td>B</td></tr></table>"), [["lead in@0", "A@1", "B@2"]])
        // A row span from above still takes its slot first.
        XCTAssertEqual(try grid("<table><tr><td rowspan='2'>A</td><td>B</td></tr><tr><p>X</p><td>C</td></tr></table>"),
                       [["A@0/2", "B@1"], ["X@1", "C@2"]])
    }

    func testCellsWrittenOutsideARowMakeARowOfTheirOwn() throws {
        XCTAssertEqual(try grid("<table><tr><td>A</td><td>B</td></tr><td>C</td><th>D</th><td>E</td></table>"),
                       [["A@0", "B@1"], ["C@0", "D@1", "E@2"]])
        XCTAssertEqual(try grid("<table><td>A</td><td/><td>B</td><tr><td>C</td><td>D</td></tr></table>"),
                       [["A@0", "@1", "B@2"], ["C@0", "D@1"]], "an empty cell keeps its column")
        let spanning = try TableCoverage.table("<table><tr><td>A</td><td>B</td></tr><th colspan='2'>Total</th></table>")
        XCTAssertEqual(TableCoverage.grid(spanning), [["A@0", "B@1"], ["Total@0x2"]])
        XCTAssertTrue(spanning.cells[try TableCoverage.cell("Total", in: spanning)].isHeader)
    }

    /// The row a group's stray content makes is one of that group's rows: the header's stay with
    /// the header, which is shown first wherever it is written.
    func testContentInARowGroupIsARowOfThatGroup() throws {
        let table = try TableCoverage.table("""
        <table>Before the groups<tfoot>Source: survey<tr><td>f1</td><td>f2</td></tr></tfoot>
        <tbody><tr><td>a</td><td>b</td></tr><td>loose</td></tbody>
        <thead><tr><th>H1</th><th>H2</th></tr><p>Units: mm</p></thead></table>
        """)
        XCTAssertEqual(TableCoverage.grid(table), [["H1@0", "H2@1"], ["Units: mm@0"], ["Before the groups@0"], ["a@0", "b@1"], ["loose@0"],
                                                   ["Source: survey@0"], ["f1@0", "f2@1"]])
        XCTAssertEqual(table.rows.map(\.isHeader), [true, true, false, false, false, false, false])
        XCTAssertEqual(table.keepsWithNext, [true, true, false, false, false, false, false])
    }

    /// The first step of §17.2.1 removes white space between table parts, and a box that is not
    /// generated asks for no row: such a table is the table it was.
    func testWhiteSpaceCommentsAndWhatIsNotShownMakeNoRowOrCell() throws {
        let clean = try TableCoverage.section("<table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table>")
        let noisy = try TableCoverage.section("""
        <table>
          <!-- a comment --><?pi data?><script>var s = 1;</script>
          <tr>
            <td>A</td> <template><p>t</p></template> <td>B</td>
          </tr><p style="display: none">gone</p><p></p> <input type="hidden" name="k"/><span> </span>
          <tr><td>C</td><td>D</td><col>x</col></tr>
        </table>
        """)
        XCTAssertEqual(noisy.string.string, clean.string.string)
        XCTAssertEqual(noisy.string.readerPlainText(), "A\tB\nC\tD")
        let table = try XCTUnwrap(TableCoverage.tables(in: noisy.string).first)
        XCTAssertEqual(TableCoverage.grid(table), [["A@0", "B@1"], ["C@0", "D@1"]])
        XCTAssertEqual(table.cells.count, 4)
        XCTAssertNil(noisy.report.unsupportedElements["table"])
    }

    /// `cellpadding` and `border` are hints for the table's `td` and `th` elements, and the
    /// user-agent sheet pads those: an anonymous cell is not one.
    func testAnAnonymousCellHasNoPaddingBordersOrBackgroundOfItsOwn() throws {
        let table = try TableCoverage.table("""
        <table border="1" cellpadding="8"><tr style="background: yellow; height: 40px"><td>A</td><td>B</td>loose</tr>
        <tbody style="background: silver">stray</tbody></table>
        """)
        XCTAssertEqual(table.cells.map(\.text), ["A", "B", "loose", "stray"])
        let written = table.cells[try TableCoverage.cell("A", in: table)]
        XCTAssertEqual(written.padding, TableModel.Insets(top: 8, right: 8, bottom: 8, left: 8))
        XCTAssertEqual(written.borders.widths, TableModel.Insets(top: 1, right: 1, bottom: 1, left: 1))
        for text in ["loose", "stray"] {
            let cell = table.cells[try TableCoverage.cell(text, in: table)]
            XCTAssertEqual(cell.padding, TableModel.Insets(), text)
            XCTAssertEqual(cell.borders.widths, TableModel.Insets(), text)
            XCTAssertNil(cell.background, text)
            XCTAssertFalse(cell.isHeader, text)
        }
        XCTAssertEqual(table.rows.map { $0.background != nil }, [true, false], "an anonymous row has no box of its own")
        XCTAssertEqual(table.rows.map(\.height), [40, 0])
    }

    func testATableWrittenOutsideTheCellsIsDrawnInItsAnonymousCell() throws {
        let table = try TableCoverage.table("""
        <table><tr><td>A</td><td>B</td></tr><table><tr><td>in one</td><td>in two</td></tr></table></table>
        """)
        XCTAssertEqual(table.cells.map(\.text), ["A", "B", "in one in two"])
        let anonymous = table.cells[try TableCoverage.cell("in one in two", in: table)]
        let inner = try XCTUnwrap(TableCoverage.tables(in: anonymous.content).first)
        XCTAssertEqual(TableCoverage.grid(inner), [["in one@0", "in two@1"]])
    }

    /// Content in an anonymous cell is as exact as a cell's: found, selected and saved by its
    /// characters.
    func testContentOutsideTheCellsIsLocatedByItsCharacters() throws {
        let publication = try TableCoverage.publication("""
        <p>Before table.</p><table id="t"><tr><td>A</td><td>B</td></tr><p id="stray">Stray <b>bold</b> words</p>
        <tr><td>C</td><td>D</td>tail <i id="it">end</i></tr></table><p id="after">After.</p>
        """)
        let section = TableCoverage.section(of: publication)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(TableCoverage.grid(table), [["A@0", "B@1"], ["Stray bold words@0"], ["C@0", "D@1", "tail end@2"]])
        func found(_ quote: String) throws -> ReaderTextRange {
            let match = try XCTUnwrap(TextSearch.matches(of: TextSearch.normalizeQuote(quote), in: section.document, locale: nil).first, quote)
            return SearchResultBuilder.renderedRange(of: match, in: section)
        }
        let stray = try TableCoverage.cell("Stray bold words", in: table)
        let bold = try found("bold words")
        XCTAssertEqual(bold.start.tableCell, ReaderTablePosition(table: table.sourceOrder, cell: stray, offset: 6))
        XCTAssertEqual(bold.end.tableCell, ReaderTablePosition(table: table.sourceOrder, cell: stray, offset: 16))
        XCTAssertEqual(bold.start.offset, try TableCoverage.offset(ofRow: 1, in: table))
        XCTAssertEqual(section.tablePassage(bold), "bold words")
        XCTAssertTrue(SearchResultBuilder.isRendered(bold))
        let context = SearchResultBuilder.context(of: bold, in: section)
        XCTAssertEqual(context.before, "Stray ")
        XCTAssertEqual(context.after, "")
        let tail = try found("tail end")
        XCTAssertEqual(tail.start.tableCell?.cell, try TableCoverage.cell("tail end", in: table))
        XCTAssertEqual(tail.start.offset, try TableCoverage.offset(ofRow: 2, in: table))
        XCTAssertEqual(section.tablePassage(tail), "tail end")
        // Every character of the anonymous cells names its text node and comes back.
        var checked = 0
        for (index, cell) in table.cells.enumerated() where ["Stray bold words", "tail end"].contains(cell.text) {
            let mapping = try XCTUnwrap(cell.textMap)
            for span in mapping.map.spans where span.isExact {
                for step in 0..<span.length {
                    let position = ReaderTextPosition(section: 0, offset: try TableCoverage.offset(ofRow: cell.row, in: table),
                                                      tableCell: ReaderTablePosition(table: table.sourceOrder, cell: index, offset: span.location + step))
                    let source = try XCTUnwrap(section.domPosition(position))
                    XCTAssertTrue(source.node === section.document.nodes[span.node])
                    XCTAssertEqual(source.offset, span.offset + step)
                    XCTAssertEqual(section.renderedPosition(source), position)
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, "Stray bold words".count + "tail end".count)
        // Ids inside the table anchor at it, stray or not.
        let start = try XCTUnwrap(section.anchors["t"])
        XCTAssertEqual(section.anchors["stray"], start)
        XCTAssertEqual(section.anchors["it"], start)
        XCTAssertEqual(section.anchors["after"], try TableCoverage.offset(ofRow: 2, in: table) + 2)
        BuilderHarness.assertMapRoundTrips(section)
    }

    /// Whether a table is a grid is decided by the cells written in its rows. What else it holds
    /// joins a grid and never makes one, so a callout box stays text with all its content.
    func testATableThatFlowsAsTextFlowsWithItsOtherContent() throws {
        for (body, expected) in [
            ("<table><tr><td>Tip</td><p>Aside</p></tr><tr><td>More</td></tr></table>", "Tip\nAside\nMore"),
            ("<table><td>One</td><td>Two</td></table>", "One\nTwo"),
            ("<table><tr><td>Tip</td></tr><td>One</td><td>Two</td></table>", "Tip\nOne\nTwo"),
            ("<table>Only text</table>", "Only text"),
        ] {
            let section = try TableCoverage.section("<p>Before</p>\(body)<p>After</p>")
            XCTAssertTrue(TableCoverage.tables(in: section.string).isEmpty, body)
            XCTAssertEqual(section.string.readerPlainText(), "Before\n\(expected)\nAfter", body)
            BuilderHarness.assertMapRoundTrips(section)
        }
    }

    /// §17.2.1: a column's children, and a column group's that are not columns, have no box.
    func testWhatIsWrittenInAColumnIsNotShown() throws {
        XCTAssertEqual(try plain("<table><col>in a column</col><colgroup>in a group<col/><p>too</p></colgroup><tr><td>A</td><td>B</td></tr></table>"), "A\tB")
        XCTAssertEqual(try plain("<table><tr><td>A</td><td>B</td><col>in a row</col></tr></table>"), "A\tB")
    }

    /// Past the eight levels tables are drawn at, a cell is written with the tables in it
    /// flowing as text; content outside the cells is too, without what is never rendered.
    func testContentOutsideTheCellsOfADeeplyNestedTableKeepsItsWords() throws {
        var markup = "<table><tr><td>leaf</td><td>twig</td></tr></table>"
        for level in 0..<10 {
            markup = "<table><tr><td>\(markup)</td><td>level\(level)</td></tr><p>stray\(level) <script>var secret\(level);</script>tail\(level)</p></table>"
        }
        let text = try plain(markup)
        for level in 0..<10 {
            XCTAssertTrue(text.contains("stray\(level)") && text.contains("tail\(level)"), "level \(level) of \(text.debugDescription)")
        }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for level in 0..<10 {
            XCTAssertTrue(words.contains("stray\(level)") && words.contains("tail\(level)"), "level \(level) of \(text.debugDescription)")
            XCTAssertFalse(text.contains("secret\(level)"), "level \(level) of \(text.debugDescription)")
        }
    }

    /// That text leaves out what the reader leaves out within the eight levels: an element
    /// that has no box, with all it holds, and a footnote, which stays in the notes.
    func testContentOutsideTheCellsOfADeeplyNestedTableLeavesOutWhatIsNotShown() throws {
        let table = """
        <table><tr><td>w1</td><td>w2</td></tr><p style="display: none">h3</p><aside epub:type="footnote" id="note">n4</aside>\
        <p>w5 <span hidden="hidden">h6 <b style="display: inline">h7</b></span> w8</p><noscript>w9</noscript>\
        <div>w10 <aside epub:type="footnote" id="inner"><p>n11</p></aside><template>h12</template></div></table>
        """
        for depth in [2, 8] {
            var markup = table
            for _ in 0..<depth { markup = "<table><tr><td>\(markup)</td><td>x</td></tr></table>" }
            let section = try TableCoverage.section(markup, css: "noscript { display: none }")
            let words = section.string.readerPlainText().split(whereSeparator: \.isWhitespace).map(String.init)
            XCTAssertEqual(words.filter { $0 != "x" }, ["w1", "w2", "w5", "w8", "w9", "w10"], "inside \(depth) tables")
            XCTAssertEqual(section.notes["note"]?.string, "n4", "inside \(depth) tables")
            XCTAssertEqual(section.notes["inner"]?.string, "n11", "inside \(depth) tables")
        }
    }

    // MARK: Captions

    /// CSS 2.2 §17.4: each caption is placed by its own `caption-side`, in document order.
    func testCaptionsKeepTheirOrderAboveAndBelowTheRows() throws {
        let section = try TableCoverage.section("""
        <table><caption>One</caption><tr><td>A</td><td>B</td></tr><caption style="caption-side: bottom">Below one</caption>
        <caption>Two</caption><caption align="bottom">Below two</caption></table>
        """)
        XCTAssertEqual(section.string.string, "One\nTwo\n\u{FFFC}\nBelow one\nBelow two")
        XCTAssertEqual(section.map.spans.count, 1, "the table is one unit, its captions with it")
        XCTAssertEqual(TableCoverage.tables(in: section.string).first?.sourceRowOffsets, [0: 8])
        BuilderHarness.assertMapRoundTrips(section)
        XCTAssertEqual(try plain("<table><caption> </caption><caption>Written</caption><tr><td>A</td><td>B</td></tr></table>"), "Written\nA\tB")
        XCTAssertEqual(try plain("<table><caption style='display: none'>Hidden</caption><caption>Shown</caption><tr><td>A</td><td>B</td></tr></table>"), "Shown\nA\tB")
        XCTAssertEqual(try plain("<table><tr><td>A</td><td>B</td></tr><caption><p>First.</p><p>Second.</p></caption><caption>Last</caption></table>"),
                       "First.\nSecond.\nLast\nA\tB")
    }

    /// A caption is the table's own child. One written in a row group or a row is content
    /// outside the rows or cells, in an anonymous cell.
    func testACaptionWrittenInsideARowGroupOrARowIsContentInPlace() throws {
        XCTAssertEqual(try grid("<table><tbody><tr><td>A</td><td>B</td></tr><caption>In the body</caption></tbody></table>"),
                       [["A@0", "B@1"], ["In the body@0"]])
        XCTAssertEqual(try grid("<table><tr><td>A</td><td>B</td><caption>In the row</caption></tr></table>"),
                       [["A@0", "B@1", "In the row@2"]])
    }

    // MARK: Spans and cells the grid cannot hold

    /// HTML §4.9.11 keeps a cell whose `colspan` is larger than the table (and clamps it at
    /// 1000). The reader lays out 200 columns; a title or a "rest of the row" cell written with
    /// a larger span reaches the table's last column.
    func testASpanWrittenPastTheColumnBoundReachesTheLastColumn() throws {
        for span in [TableModel.maximumColumns + 1, 1000, 100_000] {
            let section = try TableCoverage.section("""
            <table><tr><td colspan="\(span)">Quarterly totals</td></tr><tr><td>North</td><td>South</td></tr>
            <tr><th>Name</th><th colspan="\(span)" rowspan="2">Values</th></tr><tr><td>a</td><td>b</td><td>c</td></tr>
            <tr><td rowspan="2">Side</td><td>x</td><td>y</td></tr><tr><td colspan="\(span)">Wide</td></tr></table>
            """)
            let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
            XCTAssertEqual(TableCoverage.grid(table), [["Quarterly totals@0x3"], ["North@0", "South@1"], ["Name@0", "Values@1x2"],
                                                       ["a@0", "b@1", "c@2"], ["Side@0/2", "x@1", "y@2"], ["Wide@1x2"]], "colspan=\(span)")
            XCTAssertEqual(table.columnCount, 3, "colspan=\(span)")
            XCTAssertNil(section.report.unsupportedElements["table"], "nothing was left out")
            let layout = table.layout(available: 320, viewportHeight: 600)
            XCTAssertEqual(layout.cellFrames[0].minX, layout.cellFrames[try TableCoverage.cell("a", in: table)].minX, accuracy: 0.01)
            XCTAssertEqual(layout.cellFrames[0].maxX, layout.cellFrames[try TableCoverage.cell("c", in: table)].maxX, accuracy: 0.01)
        }
    }

    /// A cell whose span runs past the bound with another cell after it has no slot that would
    /// not move that cell: its content follows the table, and the reader says it gave up.
    func testACellTheGridHasNoSlotForFollowsTheTableAndIsDisclosed() throws {
        let section = try TableCoverage.section("""
        <p>Before</p><table><tr><td colspan="300">Wide <b>one</b></td><td>Next</td><td colspan="300">Wide two</td></tr>
        <tr><td>A</td><td>B</td></tr><caption style="caption-side: bottom">Below</caption></table><p id="after">After</p>
        """)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(TableCoverage.grid(table), [["Next@0"], ["A@0", "B@1"]], "the cells that had a slot keep it")
        XCTAssertEqual(section.string.string, "Before\n\u{FFFC}\n\u{FFFC}\nWide one\nWide two\nBelow\nAfter")
        XCTAssertEqual(section.report.unsupportedElements["table"], 1)
        XCTAssertEqual(NativeDisclosure.text(for: section.report), "Part of one table is shown after it, out of place.")
        XCTAssertEqual(section.anchors["after"], section.string.length - 5)
        BuilderHarness.assertMapRoundTrips(section)
    }

    /// A cell the grid has no slot for that shows nothing puts nothing after the table, and so
    /// there is nothing to disclose: a cell that is empty, holds white space alone or only what is
    /// not shown, empty cells past the 200th column, and empty rows past the 20,000th cell (#272).
    func testACellLeftOutThatShowsNothingIsNotDisclosed() throws {
        for cell in ["<td colspan=\"300\"></td>", "<td colspan=\"300\"> \n </td>", "<td colspan=\"300\"><span style=\"display: none\">gone</span></td>"] {
            let section = try TableCoverage.section("<table><tr>\(cell)<td>a</td><td>b</td></tr></table>")
            let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first, cell)
            XCTAssertEqual(TableCoverage.grid(table), [["a@0", "b@1"]], cell)
            XCTAssertEqual(section.string.string, "\u{FFFC}", cell)
            XCTAssertEqual(section.string.readerPlainText(), "a\tb", cell)
            XCTAssertNil(section.report.unsupportedElements["table"], cell)
            XCTAssertNil(NativeDisclosure.text(for: section.report), cell)
        }
        let cells = (0..<(TableModel.maximumColumns + 40)).map { $0 < TableModel.maximumColumns ? "<td>c\($0)</td>" : "<td></td>" }.joined()
        let wide = try TableCoverage.section("<table><tr>\(cells)</tr></table><p>After the table</p>")
        XCTAssertEqual(TableCoverage.tables(in: wide.string).first?.cells.count, TableModel.maximumColumns)
        XCTAssertEqual(wide.string.string, "\u{FFFC}\nAfter the table")
        XCTAssertNil(wide.report.unsupportedElements["table"], "empty cells past the column bound")
        let columns = 100, rows = TableModel.maximumCells / columns + 3
        let markup = (0..<rows).map { row in "<tr>" + String(repeating: row < rows - 3 ? "<td>x</td>" : "<td/>", count: columns) + "</tr>" }.joined()
        let long = try TableCoverage.section("<table>\(markup)</table><p>After the table</p>")
        XCTAssertEqual(TableCoverage.tables(in: long.string).first?.cells.count, TableModel.maximumCells)
        XCTAssertTrue(long.string.string.hasSuffix("\u{FFFC}\nAfter the table"))
        XCTAssertNil(long.report.unsupportedElements["table"], "empty rows past the cell bound")
    }

    func testCellsPastTheColumnBoundFollowTheTable() throws {
        let count = TableModel.maximumColumns + 40
        let cells = (0..<count).map { "<td>c\($0)</td>" }.joined()
        let section = try TableCoverage.section("<table><tr>\(cells)</tr><tr><td>next</td><td>row</td></tr></table><p>After the table</p>")
        let first = (0..<TableModel.maximumColumns).map { "c\($0)" }.joined(separator: "\t")
        let rest = (TableModel.maximumColumns..<count).map { "c\($0)" }.joined(separator: "\n")
        XCTAssertEqual(section.string.readerPlainText(), "\(first)\nnext\trow\n\(rest)\nAfter the table")
        XCTAssertEqual(section.report.unsupportedElements["table"], 1)
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testRowsPastTheCellBoundFollowTheTableInOrder() throws {
        let columns = 100, rows = TableModel.maximumCells / columns + 3
        let markup = (0..<rows).map { row in
            "<tr>" + (0..<columns).map { "<td>\(row < rows - 3 ? "x" : "r\(row)c\($0)")</td>" }.joined() + "</tr>"
        }.joined()
        let section = try TableCoverage.section("<table>\(markup)</table><p>After the table</p>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        XCTAssertEqual(table.cells.count, TableModel.maximumCells)
        let expected = ((rows - 3)..<rows).flatMap { row in (0..<columns).map { "r\(row)c\($0)" } }
        let lines = section.string.readerPlainText().split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.suffix(expected.count + 1)), expected + ["After the table"])
        XCTAssertEqual(section.report.unsupportedElements["table"], 1)
    }

    /// A table that flows as text shows every cell, so it has nothing to disclose.
    func testATableThatFlowsAsTextDisclosesNothing() throws {
        let section = try TableCoverage.section("<table><tr><td colspan='300'>Title</td></tr><tr><td>Body</td></tr></table>")
        XCTAssertTrue(TableCoverage.tables(in: section.string).isEmpty)
        XCTAssertEqual(section.string.readerPlainText(), "Title\nBody")
        XCTAssertNil(section.report.unsupportedElements["table"])
    }
}
