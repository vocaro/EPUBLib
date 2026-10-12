import Foundation

/// Tables written with content outside their rows and cells, each word of them a token that
/// says what a reader owes it: `v…` is shown exactly once, `h…` never (scripts, templates and
/// `display: none`), `c…` never (the content of `col` and `colgroup`, which CSS 2.2 §17.2.1
/// gives no box), and `n…` is a footnote's, kept out of the flow and in the section's notes.
enum TableStrayCorpus {
    struct Case {
        var name: String
        var body: String
        /// Not well-formed XML: read by the forgiving HTML parser.
        var recovered = false
    }

    /// Hands out the tokens of one case.
    struct Tokens {
        private var serial = 0
        mutating func next(_ kind: Character = "v") -> String {
            serial += 1
            return "\(kind)\(serial)"
        }
    }

    /// One kind of content that can stand where the table model has no place for it.
    struct Stray: Sendable {
        var name: String
        var make: @Sendable (inout Tokens) -> String
        /// Whether it is a cell, a caption or a column, which only some parents misplace.
        var isTablePart = false
    }

    static let strays: [Stray] = [
        Stray(name: "text") { " \($0.next()) " },
        Stray(name: "paragraph") { "<p>\($0.next())</p>" },
        Stray(name: "span") { " <span>\($0.next())</span> " },
        Stray(name: "blocks") { "<div><p>\($0.next())</p><p>\($0.next())</p></div>" },
        Stray(name: "inline mix") { " <b>\($0.next())</b> \($0.next()) " },
        Stray(name: "link") { let id = $0.next("i"); return " <a id=\"\(id)\" href=\"#after\">\($0.next())</a> " },
        Stray(name: "list") { "<ul><li>\($0.next())</li><li>\($0.next())</li></ul>" },
        Stray(name: "heading") { "<h3 id=\"\($0.next("i"))\">\($0.next())</h3>" },
        Stray(name: "nested table") { "<table><tr><td>\($0.next())</td><td>\($0.next())</td></tr></table>" },
        Stray(name: "nested callout") { "<table><tr><td>\($0.next())</td></tr></table>" },
        Stray(name: "form") { "<form action=\"#\"><p>\($0.next())</p><input type=\"text\" name=\"q\"/></form>" },
        Stray(name: "button") { " <button type=\"button\">\($0.next())</button> " },
        Stray(name: "hidden input") { _ in "<input type=\"hidden\" name=\"k\" value=\"x\"/>" },
        Stray(name: "script") { "<script type=\"text/javascript\">var \($0.next("h")) = 1;</script>" },
        Stray(name: "template") { "<template><p>\($0.next("h"))</p></template>" },
        Stray(name: "hidden paragraph") { "<p style=\"display: none\">\($0.next("h"))</p>" },
        Stray(name: "empty paragraph") { _ in "<p></p>" },
        Stray(name: "line break") { _ in "<br/>" },
        Stray(name: "rule") { _ in "<hr/>" },
        Stray(name: "whitespace") { _ in "\n    \t" },
        Stray(name: "comment") { "<!-- \($0.next("h")) -->" },
        Stray(name: "processing instruction") { "<?probe \($0.next("h"))?>" },
        Stray(name: "footnote") { "<aside epub:type=\"footnote\" id=\"\($0.next("i"))\"><p>\($0.next("n"))</p></aside>" },
        Stray(name: "foreign element") { "<x:note xmlns:x=\"urn:example:other\">\($0.next())</x:note>" },
        Stray(name: "preformatted") { "<pre>\($0.next())\n  \($0.next())</pre>" },
        Stray(name: "cell", make: { "<td>\($0.next())</td>" }, isTablePart: true),
        Stray(name: "header cell", make: { "<th id=\"\($0.next("i"))\">\($0.next())</th>" }, isTablePart: true),
        Stray(name: "two cells", make: { "<td>\($0.next())</td><td>\($0.next())</td>" }, isTablePart: true),
        Stray(name: "empty cell", make: { _ in "<td></td>" }, isTablePart: true),
        Stray(name: "spanning cell", make: { "<td colspan=\"2\" rowspan=\"2\">\($0.next())</td>" }, isTablePart: true),
        Stray(name: "caption", make: { "<caption>\($0.next())</caption>" }, isTablePart: true),
        Stray(name: "column with content", make: { "<col>\($0.next("c"))</col>" }, isTablePart: true),
        Stray(name: "column group with content",
              make: { "<colgroup>\($0.next("c"))<col/><p>\($0.next("c"))</p></colgroup>" }, isTablePart: true),
        Stray(name: "row", make: { "<tr><td>\($0.next())</td><td>\($0.next())</td></tr>" }, isTablePart: true),
        Stray(name: "row group", make: { "<tbody><tr><td>\($0.next())</td><td>\($0.next())</td></tr></tbody>" }, isTablePart: true),
    ]

    private static func row(_ tokens: inout Tokens, columns: Int) -> String {
        "<tr>" + (0..<columns).map { _ in "<td>\(tokens.next())</td>" }.joined() + "</tr>"
    }

    private static func wrap(_ table: String) -> String { "<p id=\"before\">Before</p>\(table)<p id=\"after\">After</p>" }

    /// What makes a case's markup ill-formed XML without touching its table.
    private static func recovered(_ body: String) -> String { "<p>Unclosed<br></p>" + body }

    /// Every kind of stray content at the start, in the middle and at the end of a table, of
    /// each kind of row group and of a row, in a table of two columns and in one of one.
    static func systematic() -> [Case] {
        var cases: [Case] = []
        for columns in [2, 1] {
            for level in ["table", "tbody", "thead", "tfoot", "tr"] {
                for stray in strays {
                    for position in 0..<3 {
                        var tokens = Tokens()
                        var parts = ["", "", ""]
                        let first: String, second: String
                        if level == "tr" {
                            let cells = (0..<max(columns, 1)).map { _ in "<td>\(tokens.next())</td>" }
                            let split = columns == 1 ? [cells[0], ""] : [cells[0], cells[1]]
                            parts[position] = stray.make(&tokens)
                            first = "<tr>\(parts[0])\(split[0])\(parts[1])\(split[1])\(parts[2])</tr>"
                            second = row(&tokens, columns: columns)
                            cases.append(Case(name: "\(stray.name) in tr at \(position), \(columns) columns",
                                              body: wrap("<table>\(first)\(second)</table>")))
                        } else {
                            first = row(&tokens, columns: columns)
                            parts[position] = stray.make(&tokens)
                            second = row(&tokens, columns: columns)
                            let inner = "\(parts[0])\(first)\(parts[1])\(second)\(parts[2])"
                            let table = level == "table" ? "<table>\(inner)</table>" : "<table><\(level)>\(inner)</\(level)></table>"
                            cases.append(Case(name: "\(stray.name) in \(level) at \(position), \(columns) columns", body: wrap(table)))
                        }
                    }
                }
            }
        }
        // The same shapes as the forgiving HTML parser leaves them, for the middle position.
        cases += cases.filter { $0.name.contains(" at 1,") }.map {
            Case(name: $0.name + ", recovered", body: recovered($0.body), recovered: true)
        }
        return cases
    }

    /// Shapes written out one by one.
    static func special() -> [Case] {
        let pair = "<tr><td>v1</td><td>v2</td></tr>"
        let next = "<tr><td>v3</td><td>v4</td></tr>"
        let shapes: [(String, String)] = [
            // Fully supported tables: nothing here may change.
            ("supported: rows", "<table>\(pair)\(next)</table>"),
            ("supported: groups", "<table><thead>\(pair)</thead><tbody>\(next)</tbody><tfoot><tr><td>v5</td><td>v6</td></tr></tfoot></table>"),
            ("supported: caption and columns", "<table><caption>v5</caption><colgroup><col width=\"40\"/><col/></colgroup>\(pair)\(next)</table>"),
            ("supported: pretty printed", "<table>\n  <caption>v5</caption>\n  <colgroup>\n    <col/>\n    <col/>\n  </colgroup>\n  <thead>\n    \(pair)\n  </thead>\n  <tbody>\n    <tr>\n      <td>v3</td>\n      <td>v4</td>\n    </tr>\n  </tbody>\n</table>"),
            ("supported: comments between rows", "<table><!-- h9 -->\(pair)<!-- h8 --><?probe h7?>\(next)<!-- h6 --></table>"),
            ("supported: spans", "<table><tr><td rowspan=\"2\">v1</td><td colspan=\"2\">v2</td></tr><tr><td>v3</td><td>v4</td></tr></table>"),
            ("supported: nested table in a cell", "<table><tr><td>v1</td><td><table><tr><td>v2</td><td>v3</td></tr></table></td></tr></table>"),
            ("supported: ids", "<table id=\"i1\"><tr id=\"i2\"><td id=\"i3\">v1</td><td>v2</td></tr><tr><td>v3</td><td id=\"i4\">v4</td></tr></table>"),
            ("supported: caption at the bottom", "<table><caption style=\"caption-side: bottom\">v5</caption>\(pair)</table>"),
            ("supported: blocks in cells", "<table><tr><td><p>v1</p><p>v2</p></td><td><ul><li>v3</li></ul></td></tr></table>"),
            ("supported: one column", "<table><tr><td>v1</td></tr><tr><td>v2</td></tr></table>"),
            ("supported: one column with a caption", "<table><caption>v3</caption><tr><td>v1</td></tr><tr><td>v2</td></tr></table>"),
            ("supported: empty row and cells", "<table><tr><td>v1</td><td></td></tr><tr></tr><tr><td/><td>v2</td></tr></table>"),
            ("supported: hidden parts", "<table><tr><td>v1</td><td style=\"display: none\">h5</td><td>v2</td></tr><tr style=\"display: none\"><td>h6</td><td>h7</td></tr>\(next)</table>"),
            ("supported: footnote in a cell", "<table><tr><td>v1<aside epub:type=\"footnote\" id=\"i9\">n5</aside></td><td>v2</td></tr></table>"),
            // Captions.
            ("two captions", "<table><caption>v5</caption><caption>v6</caption>\(pair)</table>"),
            ("three captions around the rows", "<table><caption>v5</caption>\(pair)<caption>v6</caption>\(next)<caption>v7</caption></table>"),
            ("a top and a bottom caption", "<table><caption>v5</caption><caption style=\"caption-side: bottom\">v6</caption>\(pair)</table>"),
            ("a bottom and a top caption", "<table><caption align=\"bottom\">v5</caption><caption>v6</caption>\(pair)</table>"),
            ("two bottom captions", "<table>\(pair)<caption style=\"caption-side: bottom\">v5</caption><caption style=\"caption-side: bottom\">v6</caption></table>"),
            ("an empty caption before a written one", "<table><caption> </caption><caption>v5</caption>\(pair)</table>"),
            ("a hidden caption before a written one", "<table><caption style=\"display: none\">h6</caption><caption>v5</caption>\(pair)</table>"),
            ("a caption after the rows", "<table>\(pair)<caption>v5</caption></table>"),
            ("a caption in a row group", "<table><tbody><caption>v5</caption>\(pair)</tbody></table>"),
            ("a caption in a row", "<table><tr><caption>v5</caption><td>v1</td><td>v2</td></tr></table>"),
            ("a caption in a cell", "<table><tr><td><caption>v5</caption>v1</td><td>v2</td></tr></table>"),
            ("two captions on one column", "<table><caption>v5</caption><caption>v6</caption><tr><td>v1</td></tr></table>"),
            ("captions with blocks and ids", "<table><caption id=\"i1\"><p>v5</p><p>v6</p></caption><caption id=\"i2\">v7 <b>v8</b></caption>\(pair)</table>"),
            // Columns.
            ("content in a column", "<table><col>c5</col><col><p>c6</p></col>\(pair)</table>"),
            ("content in a column group", "<table><colgroup>c5<col>c6</col><td>c7</td><p>c8</p></colgroup>\(pair)</table>"),
            ("a column group after the rows", "<table>\(pair)<colgroup><col width=\"30\"/><col width=\"60\"/></colgroup></table>"),
            ("a column in a row", "<table><tr><col>c5</col><td>v1</td><td>v2</td></tr></table>"),
            ("a column in a row group", "<table><tbody><col>c5</col>\(pair)</tbody></table>"),
            // Rows, groups and cells out of place.
            ("only cells in a table", "<table><td>v1</td><td>v2</td><td>v3</td></table>"),
            ("only cells in a row group", "<table><tbody><td>v1</td><td>v2</td></tbody></table>"),
            ("one cell in a table", "<table><td>v1</td></table>"),
            ("cells with an empty one between", "<table><td>v1</td><td/><td>v2</td></table>"),
            ("cells around a row", "<table><td>v1</td><td>v2</td>\(next)<td>v5</td><td>v6</td></table>"),
            ("cells and text around rows in every group",
             "<table>v5<thead>v6\(pair)<td>v7</td></thead>v8<tbody><td>v9</td>\(next)v10</tbody><tfoot><p>v11</p><tr><td>v12</td><td>v13</td></tr></tfoot>v14</table>"),
            ("rows outside groups between groups", "<table><tfoot><tr><td>v7</td><td>v8</td></tr></tfoot><tbody>\(pair)</tbody>\(next)<thead><tr><th>v5</th><th>v6</th></tr></thead></table>"),
            ("a row in a row", "<table><tr><td>v1</td><tr><td>v2</td><td>v3</td></tr></tr>\(next.replacingOccurrences(of: "v3", with: "v5"))</table>"),
            ("a row group in a row group", "<table><tbody>\(pair)<tbody>\(next)</tbody></tbody></table>"),
            ("a row group in a row", "<table><tr><td>v1</td><tbody><tr><td>v2</td><td>v3</td></tr></tbody></tr></table>"),
            ("a header group in a body", "<table><tbody>\(pair)<thead>\(next)</thead></tbody></table>"),
            ("a cell in a cell", "<table><tr><td>v1<td>v2</td></td><td>v3</td></tr></table>"),
            ("a row in a cell", "<table><tr><td>v1<tr><td>v2</td><td>v3</td></tr></td><td>v4</td></tr></table>"),
            ("a table in a table", "<table>\(pair)<table>\(next)</table></table>"),
            ("a table in a row", "<table><tr><td>v1</td><table>\(next)</table><td>v2</td></tr></table>"),
            ("a table in a row group", "<table><tbody>\(pair)<table>\(next)</table></tbody></table>"),
            ("rows in a division in a table", "<table><div>\(pair)\(next)</div></table>"),
            ("rows in a form in a table", "<table><form action=\"#\">\(pair)\(next)</form></table>"),
            // Tables that hold nothing the model places.
            ("only text", "<table>v1 v2</table>"),
            ("only a paragraph", "<table><p>v1</p></table>"),
            ("only text in a row", "<table><tr>v1</tr></table>"),
            ("only text in a row group", "<table><tbody>v1</tbody></table>"),
            ("a caption and text", "<table><caption>v1</caption>v2</table>"),
            ("only paragraphs in rows", "<table><tr><p>v1</p></tr><tr><p>v2</p></tr></table>"),
            ("text and a cell in each row", "<table><tr>v1<td>v2</td></tr><tr><td>v3</td>v4</tr></table>"),
            ("only hidden content", "<table><script>var h1;</script><p style=\"display: none\">h2</p></table>"),
            // Stray content among spans.
            ("text after a row span", "<table><tr><td rowspan=\"3\">v1</td><td>v2</td></tr>v3<tr><td>v4</td></tr></table>"),
            ("a paragraph in a row under a row span", "<table><tr><td rowspan=\"2\">v1</td><td>v2</td></tr><tr><p>v3</p><td>v4</td></tr></table>"),
            ("stray cells with spans", "<table><td colspan=\"2\">v1</td><td rowspan=\"2\">v2</td>\(next)</table>"),
            // Past the bounds.
            ("a span one past the bound", "<table><tr><td colspan=\"201\">v5</td></tr>\(pair)</table>"),
            ("a span of a thousand", "<table>\(pair)<tr><td colspan=\"1000\">v5</td></tr></table>"),
            ("a span of a hundred thousand", "<table><tr><td colspan=\"100000\">v5</td></tr>\(pair)</table>"),
            ("a span crossing the bound", "<table><tr><td colspan=\"150\">v1</td><td colspan=\"150\">v2</td><td>v3</td></tr><tr><td>v4</td><td>v5</td></tr></table>"),
            ("two spans past the bound", "<table><tr><td colspan=\"500\">v1</td><td colspan=\"500\">v2</td></tr><tr><td>v3</td><td>v4</td></tr></table>"),
            ("a span past the bound alone", "<table><tr><td colspan=\"300\">v1</td></tr></table>"),
            ("a span past the bound with stray text", "<table>v6<tr><td colspan=\"300\">v5</td></tr>\(pair)</table>"),
        ]
        var cases = shapes.map { Case(name: $0.0, body: wrap($0.1)) }
        cases += shapes.filter { !$0.0.hasPrefix("a span") && !$0.0.hasPrefix("two spans") }
            .map { Case(name: $0.0 + ", recovered", body: recovered(wrap($0.1)), recovered: true) }
        // More cells than the grid has columns for.
        var tokens = Tokens()
        let wide = "<tr>" + (0..<230).map { _ in "<td>\(tokens.next())</td>" }.joined() + "</tr>"
        cases.append(Case(name: "a row past the column bound", body: wrap("<table>\(wide)<tr><td>\(tokens.next())</td><td>\(tokens.next())</td></tr></table>")))
        return cases
    }

    /// SplitMix64: the same tables on every run and platform.
    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    /// Tables mixing rows, groups, captions, columns and stray content at random.
    static func random(seed: UInt64, count: Int) -> [Case] {
        var generator = Generator(state: seed)
        let loose = strays.filter { !$0.isTablePart }
        func cell(_ tokens: inout Tokens) -> String {
            let tag = generator.chance(15) ? "th" : "td"
            var attributes = ""
            if generator.chance(10) { attributes += " colspan=\"\(2 + generator.below(2))\"" }
            if generator.chance(10) { attributes += " rowspan=\"2\"" }
            let content: String
            switch generator.below(12) {
            case 0: content = "<p>\(tokens.next())</p><p>\(tokens.next())</p>"
            case 1: content = "<table><tr><td>\(tokens.next())</td><td>\(tokens.next())</td></tr></table>"
            case 2: content = ""
            default: content = tokens.next()
            }
            return "<\(tag)\(attributes)>\(content)</\(tag)>"
        }
        func stray(_ tokens: inout Tokens, among kinds: [Stray]) -> String {
            kinds[generator.below(kinds.count)].make(&tokens)
        }
        func row(_ tokens: inout Tokens, columns: Int, strayChance: Int) -> String {
            var text = "<tr>"
            let cells = columns == 1 ? 1 : (generator.chance(8) ? 0 : 1 + generator.below(4))
            for _ in 0..<cells {
                if generator.chance(strayChance) { text += stray(&tokens, among: loose) }
                text += cell(&tokens)
            }
            if generator.chance(strayChance) { text += stray(&tokens, among: loose) }
            return text + "</tr>"
        }
        func rows(_ tokens: inout Tokens, columns: Int, strayChance: Int) -> String {
            var text = ""
            for _ in 0..<(1 + generator.below(3)) {
                if generator.chance(strayChance) { text += stray(&tokens, among: strays) }
                text += row(&tokens, columns: columns, strayChance: strayChance)
            }
            if generator.chance(strayChance) { text += stray(&tokens, among: strays) }
            return text
        }
        var cases: [Case] = []
        for index in 0..<count {
            var tokens = Tokens()
            let columns = generator.chance(20) ? 1 : 2
            // A third of the tables are written properly: the model's own shapes.
            let strayChance = index % 3 == 0 ? 0 : 10 + generator.below(30)
            var table = "<table>"
            if generator.chance(30) { table += "<caption>\(tokens.next())</caption>" }
            if strayChance > 0, generator.chance(15) { table += "<caption>\(tokens.next())</caption>" }
            if generator.chance(20) { table += "<colgroup><col/><col width=\"40\"/></colgroup>" }
            for _ in 0..<(1 + generator.below(4)) {
                if generator.chance(strayChance) { table += stray(&tokens, among: strays) }
                switch generator.below(6) {
                case 0: table += "<thead>\(rows(&tokens, columns: columns, strayChance: strayChance))</thead>"
                case 1: table += "<tfoot>\(rows(&tokens, columns: columns, strayChance: strayChance))</tfoot>"
                case 2, 3: table += "<tbody>\(rows(&tokens, columns: columns, strayChance: strayChance))</tbody>"
                default: table += row(&tokens, columns: columns, strayChance: strayChance)
                }
            }
            if generator.chance(strayChance) { table += stray(&tokens, among: strays) }
            table += "</table>"
            let recover = index % 5 == 4
            cases.append(Case(name: "random \(index)", body: recover ? recovered(wrap(table)) : wrap(table), recovered: recover))
        }
        return cases
    }

    static func all() -> [Case] { systematic() + special() + random(seed: 139, count: 600) }
}
