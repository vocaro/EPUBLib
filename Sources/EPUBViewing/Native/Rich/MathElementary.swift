import Foundation
import MathMLLayout

/// Elementary math (`mstack`, `mlongdiv` and their rows) as markup MathMLLayout can lay out.
///
/// The engine has no elementary-math layout, so a stack becomes an `mtable` with one column for
/// each digit: place values stay in their columns, carries sit small above their digits and a
/// line rules off the rows above it. A long division keeps its divisor and result around that
/// table. This is an approximation, counted in `SectionReport.mathApproximations`:
/// - an `msline` spans the whole stack whatever its `length`, `position` and overhangs;
/// - carries are a row above their digits whatever their `location`;
/// - `charalign`, `charspacing` and `mslinethickness` are not read;
/// - `longdivstyle` is `lefttop`, `left/\right`, `left)(right` or `:right=right`; the other six
///   styles are drawn as `lefttop`.
enum MathElementary {
    /// The elements of elementary math, all of which the engine refuses.
    static let elements: Set<String> = ["mstack", "mlongdiv", "msgroup", "msrow", "mscarries", "mscarry", "msline"]
    private static let maximumDepth = 64

    /// `node` with every well-formed stack and long division replaced by a table.
    static func rewrite(_ node: MathMLNode, isApproximated: inout Bool, depth: Int = 0) -> MathMLNode {
        guard depth < maximumDepth else { return node }
        if node.name == "mstack" || node.name == "mlongdiv", let table = table(for: node) {
            isApproximated = true
            return table
        }
        guard !node.children.isEmpty else { return node }
        var result = node
        result.children = node.children.map { rewrite($0, isApproximated: &isApproximated, depth: depth + 1) }
        return result
    }

    // MARK: Grid

    private enum Line {
        /// Cells left to right (nil: an empty column), and how many of them stand left of the
        /// column the stack aligns on.
        case cells([MathMLNode?], anchor: Int, shift: Int, isCarries: Bool, crossouts: [Int: String])
        case rule
    }

    private struct Stack {
        /// A stack wider or longer than this is not arithmetic anyone set by hand: it is left
        /// to the `alttext` fallback rather than built.
        static let maximumColumns = 128, maximumLines = 256

        var lines: [Line] = []
        let align: String
        let decimalPoint: Character
        var isTooLarge = false

        /// A row's cells, each digit of an `mn` in its own column, and the row's anchor.
        mutating func add(row children: [MathMLNode], shift: Int) {
            var cells: [MathMLNode?] = []
            var firstNumberEnd: Int?, decimal: Int?
            func walk(_ items: [MathMLNode], level: Int) {
                for item in items where cells.count <= Self.maximumColumns {
                    switch item.name {
                    case "mn":
                        let text = item.text.filter { !$0.isWhitespace }
                        for character in text.prefix(Self.maximumColumns + 1) {
                            if character == decimalPoint, decimal == nil { decimal = cells.count }
                            var digit = item
                            digit.text = String(character)
                            cells.append(digit)
                        }
                        if firstNumberEnd == nil, !text.isEmpty { firstNumberEnd = cells.count }
                    case "none": cells.append(nil)
                    case "mstyle" where level < 8: walk(item.children, level: level + 1)
                    default: cells.append(item)
                    }
                }
            }
            walk(children, level: 0)
            guard cells.count <= Self.maximumColumns, lines.count < Self.maximumLines else { isTooLarge = true; return }
            guard !cells.isEmpty else { return }
            let anchor: Int = switch align {
            case "left": 0
            case "right": cells.count
            case "center": cells.count / 2
            default: decimal ?? firstNumberEnd ?? cells.count
            }
            lines.append(.cells(cells, anchor: anchor, shift: shift, isCarries: false, crossouts: [:]))
        }

        /// Carries: one column a child, ending at the column the stack aligns on, small. A
        /// crossout is asked of the digit below each carry.
        mutating func add(carries node: MathMLNode, shift: Int) {
            var cells: [MathMLNode?] = []
            var crossouts: [Int: String] = [:]
            let shared = node.attributes["crossout"]
            guard node.children.count <= Self.maximumColumns, lines.count < Self.maximumLines else { isTooLarge = true; return }
            for child in node.children {
                var content: MathMLNode? = child
                var crossout = shared
                if child.name == "mscarry" {
                    crossout = child.attributes["crossout"] ?? shared
                    content = child.children.count == 1 ? child.children[0] : MathMLNode(name: "mrow", children: child.children)
                    if child.children.isEmpty || child.children.allSatisfy({ $0.name == "none" }) { content = nil }
                } else if child.name == "none" { content = nil }
                if let crossout = crossout?.trimmingCharacters(in: .whitespaces).lowercased(), !crossout.isEmpty, crossout != "none" {
                    crossouts[cells.count] = crossout
                }
                cells.append(content.map { MathMLNode(name: "mstyle", attributes: ["scriptlevel": "+1"], children: [$0]) })
            }
            guard !cells.isEmpty else { return }
            let anchor = align == "left" ? 0 : align == "center" ? cells.count / 2 : cells.count
            lines.append(.cells(cells, anchor: anchor, shift: shift, isCarries: true, crossouts: crossouts))
        }

        mutating func add(_ children: [MathMLNode], shift: Int, level: Int) {
            for child in children where !isTooLarge {
                let own = Self.integer(child.attributes["position"])
                switch child.name {
                case "msrow": add(row: child.children, shift: shift + own)
                case "mscarries": add(carries: child, shift: shift + own)
                case "msline":
                    if lines.count < Self.maximumLines { lines.append(.rule) } else { isTooLarge = true }
                case "msgroup" where level < 16:
                    // Each row of a group moves `shift` columns further than the one before.
                    let step = Self.integer(child.attributes["shift"])
                    for (index, item) in child.children.enumerated() {
                        add([item], shift: shift + own + index * step, level: level + 1)
                    }
                default: add(row: [child], shift: shift)
                }
            }
        }

        private static func integer(_ value: String?) -> Int {
            let number = value.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            return min(max(number, -64), 64)
        }

        /// The rows as an `mtable` with `extra` attributes. nil when there is nothing to show or
        /// too much.
        func table(attributes extra: [String: String] = [:]) -> MathMLNode? {
            guard !isTooLarge else { return nil }
            // A row's first column, counted from the column the stack aligns on; a positive
            // shift moves the row toward the higher place values.
            var starts: [Int] = [], minimum = Int.max, maximum = Int.min
            for line in lines {
                guard case .cells(let cells, let anchor, let shift, _, _) = line else { starts.append(0); continue }
                let start = -anchor - shift
                starts.append(start)
                minimum = min(minimum, start); maximum = max(maximum, start + cells.count)
            }
            guard minimum < maximum, maximum - minimum <= 2 * Self.maximumColumns else { return nil }
            let columns = maximum - minimum
            var grid: [[MathMLNode?]] = []
            var rules: [String] = []
            /// Crossouts a carries row asks of the row after it, by column.
            var pending: [Int: String] = [:]
            for (index, line) in lines.enumerated() {
                switch line {
                case .rule:
                    // A rule is drawn in the gap after a row: one that leads, or follows another
                    // rule, gets an empty row to follow.
                    if grid.isEmpty || rules.count == grid.count { grid.append([MathMLNode?](repeating: nil, count: columns)) }
                    if rules.count < grid.count - 1 { rules += [String](repeating: "none", count: grid.count - 1 - rules.count) }
                    rules.append("solid")
                case .cells(let cells, _, _, let isCarries, let crossouts):
                    var row = [MathMLNode?](repeating: nil, count: columns)
                    let offset = starts[index] - minimum
                    for (column, cell) in cells.enumerated() { row[offset + column] = cell }
                    if isCarries {
                        pending = [:]
                        for (column, notation) in crossouts { pending[offset + column] = notation }
                    } else {
                        for (column, notation) in pending {
                            if let cell = row[column] { row[column] = MathMLNode(name: "menclose", attributes: ["notation": notation], children: [cell]) }
                        }
                        pending = [:]
                    }
                    grid.append(row)
                }
            }
            guard !grid.isEmpty else { return nil }
            // A rule after the last row needs a row below it to make its gap.
            if rules.count == grid.count { grid.append([MathMLNode?](repeating: nil, count: columns)) }
            var attributes = ["columnspacing": "0.15em", "rowspacing": "0.35em", "columnalign": "center"]
            if rules.contains("solid") {
                attributes["rowlines"] = (rules + [String](repeating: "none", count: max(0, grid.count - 1 - rules.count))).joined(separator: " ")
            }
            attributes.merge(extra) { _, new in new }
            let rows = grid.map { row in
                MathMLNode(name: "mtr", children: row.map { MathMLNode(name: "mtd", children: $0.map { [$0] } ?? []) })
            }
            return MathMLNode(name: "mtable", attributes: attributes, children: rows)
        }
    }

    private static func stack(for node: MathMLNode) -> Stack {
        let align = node.attributes["stackalign"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "decimalpoint"
        let point = node.attributes["decimalpoint"]?.trimmingCharacters(in: .whitespaces).first ?? "."
        return Stack(align: align, decimalPoint: point)
    }

    private static func table(for node: MathMLNode) -> MathMLNode? {
        var stack = stack(for: node)
        guard node.name == "mlongdiv" else {
            stack.add(node.children, shift: 0, level: 0)
            return stack.table()
        }
        // A long division: its divisor, its result, then the dividend and the working.
        guard node.children.count >= 3 else { return nil }
        let divisor = node.children[0], result = node.children[1]
        func sign(_ text: String) -> MathMLNode { MathMLNode(name: "mo", attributes: ["stretchy": "false"], text: text) }
        let style = node.attributes["longdivstyle"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "lefttop"
        let beside: (before: [MathMLNode], after: [MathMLNode])? = switch style {
        case "left/\\right": ([divisor, sign("/")], [sign("\\"), result])
        case "left)(right": ([divisor, sign(")")], [sign("("), result])
        case ":right=right": ([], [sign(":"), divisor, sign("="), result])
        default: nil
        }
        if let beside {
            stack.add(Array(node.children.dropFirst(2)), shift: 0, level: 0)
            guard let table = stack.table(attributes: ["align": "baseline 1"]) else { return nil }
            return MathMLNode(name: "mrow", children: beside.before + [table] + beside.after)
        }
        // The result stands over the dividend, ruled off from it; the divisor on the dividend's line.
        stack.add([result], shift: 0, level: 0)
        if stack.lines.isEmpty { stack.lines.append(.cells([nil], anchor: 1, shift: 0, isCarries: false, crossouts: [:])) }
        guard stack.lines.count == 1 else { return nil }
        stack.lines.append(.rule)
        stack.add(Array(node.children.dropFirst(2)), shift: 0, level: 0)
        guard stack.lines.count > 2, let table = stack.table(attributes: ["align": "baseline 2"]) else { return nil }
        return MathMLNode(name: "mrow", children: [divisor, sign(")"), table])
    }

    // MARK: Speech

    /// `node` with each stack and long division replaced by its rows in reading order, for a
    /// spoken reading: rows apart, a rule named, a division introduced by its parts.
    static func spoken(_ node: MathMLNode, depth: Int = 0) -> MathMLNode {
        guard depth < maximumDepth else { return node }
        func word(_ text: String) -> MathMLNode { MathMLNode(name: "mtext", text: text) }
        func rows(_ children: [MathMLNode], level: Int) -> [MathMLNode] {
            var result: [MathMLNode] = []
            for child in children {
                if !result.isEmpty { result.append(word(",")) }
                switch child.name {
                case "msline": result.append(word("line"))
                case "msgroup" where level < 16: result += rows(child.children, level: level + 1)
                case "mscarries": result += [word("carry")] + child.children.filter { $0.name != "none" }
                default: result.append(child)
                }
            }
            return result
        }
        switch node.name {
        case "mstack":
            return MathMLNode(name: "mrow", children: rows(node.children, level: 0))
        case "mlongdiv" where node.children.count >= 3:
            let working = Array(node.children.dropFirst(3))
            return MathMLNode(name: "mrow", children: [word("long division of"), node.children[2], word("by"), node.children[0],
                                                       word(", result"), node.children[1]]
                              + (working.isEmpty ? [] : [word(", working:")] + rows(working, level: 0)))
        default:
            guard !node.children.isEmpty else { return node }
            var result = node
            result.children = node.children.map { spoken($0, depth: depth + 1) }
            return result
        }
    }
}
