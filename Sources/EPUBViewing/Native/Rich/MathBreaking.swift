import CoreGraphics
import Foundation
import MathMLLayout

/// Where a formula too wide for its line may continue on a new row.
///
/// The reader retains its original row-breaking policy. This finds the places
/// a row may end along the formula's own rows: the `math` element and the plain `mrow`,
/// `mstyle` and `semantics` groups nested in it. A row may end before a relation or a binary
/// operator, after a separator, and where the author's `linebreak` attribute says. Fractions,
/// roots, scripts, tables and every other element stay whole.
///
/// A visual row is the original tree cut down to the units between two breaks (`slice`), so the
/// engine lays it out with the attributes it inherits and each bracket stretches to its own row.
struct MathBreaks: Sendable {
    enum Kind: Sendable, Equatable {
        case relation, binary, separator
        /// `linebreak="goodbreak"` or `"newline"` on an operator or space the lists do not know.
        case authored
    }

    struct Opportunity: Sendable, Equatable {
        /// Child indices from the root to the unit a new row would start with.
        var path: [Int]
        var kind: Kind
        /// Unclosed opening brackets around the break, plus one for `linebreak="badbreak"`.
        /// Breaks at 0 are taken first.
        var penalty: Int
        /// `linebreak="newline"`: the row ends here whatever the width.
        var isForced = false
    }

    let root: MathMLNode
    /// In reading order.
    let opportunities: [Opportunity]

    /// More than this many breaks, or rows nested deeper, are not looked for: the rest of such a
    /// formula stays on its last row.
    static let maximumOpportunities = 512
    private static let maximumDepth = 32

    init(_ root: MathMLNode) {
        self.root = root
        var found: [Opportunity] = []
        Self.collect(root, path: [], penalty: 0, level: 0, into: &found)
        opportunities = found
    }

    // MARK: Operators

    private static let relations = Set("=≠<>≤≥≦≧≪≫≈≉≃≅≡≢∼∝∈∉∋⊂⊃⊆⊇≺≻≼≽⊢⊨≐≔≕←→↔⇐⇒⇔↦⟵⟶⟷⟸⟹⟺⇌".unicodeScalars)
    private static let binaries = Set("+−±∓×÷·⋅∗∘∙⊕⊖⊗⊙∪∩∧∨∖⋆*".unicodeScalars)
    private static let opening = Set("([{⟨⌈⌊⟦".unicodeScalars)
    private static let closing = Set(")]}⟩⌉⌋⟧".unicodeScalars)
    private static let bars = Set("|‖".unicodeScalars)
    /// Postfix operators and ellipses end an operand: a sign after one is binary.
    private static let postfixes = Set("!′″‴%°'…⋯".unicodeScalars)
    private static let invisible = Set("\u{2061}\u{2062}\u{2063}\u{2064}".unicodeScalars)
    private static let scripted: Set<String> = ["msub", "msup", "msubsup", "munder", "mover", "munderover", "mmultiscripts"]

    private enum Role { case operand, relation, binary, separator, open, close, bar, prefix, invisible }

    /// The `mo` at the core of an embellished operator: itself, the base of scripts and limits,
    /// or the only child of a group.
    private static func operatorCore(_ node: MathMLNode, level: Int = 0) -> MathMLNode? {
        guard level < maximumDepth else { return nil }
        if node.name == "mo" { return node }
        if scripted.contains(node.name) { return node.children.first.flatMap { operatorCore($0, level: level + 1) } }
        if node.name == "mrow" || node.name == "mstyle", node.children.count == 1 {
            return operatorCore(node.children[0], level: level + 1)
        }
        return nil
    }

    private static func role(of core: MathMLNode) -> Role {
        let text = core.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let attributes = core.attributes
        func flag(_ name: String) -> Bool { attributes[name]?.trimmingCharacters(in: .whitespaces).lowercased() == "true" }
        let form = attributes["form"]?.trimmingCharacters(in: .whitespaces).lowercased()
        if flag("separator") { return .separator }
        if flag("fence") { return form == "postfix" ? .close : form == "prefix" ? .open : .bar }
        guard text.unicodeScalars.count == 1, var scalar = text.unicodeScalars.first else {
            return text.isEmpty ? .invisible : .prefix
        }
        if scalar == "-" { scalar = "\u{2212}" }
        if invisible.contains(scalar) { return .invisible }
        if scalar == "," || scalar == ";" { return .separator }
        if opening.contains(scalar) { return .open }
        if closing.contains(scalar) { return .close }
        if bars.contains(scalar) { return .bar }
        if postfixes.contains(scalar) { return .operand }
        if form == "prefix" || form == "postfix" { return form == "prefix" ? .prefix : .operand }
        if relations.contains(scalar) { return .relation }
        if binaries.contains(scalar) { return .binary }
        return .prefix
    }

    private static func isSpaceLike(_ node: MathMLNode, level: Int = 0) -> Bool {
        guard level < maximumDepth else { return false }
        switch node.name {
        case "mspace", "maligngroup", "malignmark", "annotation", "annotation-xml": return true
        case "mrow", "mstyle", "mphantom", "mpadded":
            return node.children.allSatisfy { isSpaceLike($0, level: level + 1) }
        default: return false
        }
    }

    /// A group whose children are a row of the formula.
    private static func isRow(_ node: MathMLNode) -> Bool { node.name == "mrow" || node.name == "mstyle" }

    private static func linebreak(_ node: MathMLNode) -> String? {
        node.attributes["linebreak"]?.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func collect(_ node: MathMLNode, path: [Int], penalty base: Int, level: Int, into result: inout [Opportunity]) {
        guard level < maximumDepth else { return }
        let children = node.children
        var depth = base, barOpen = false
        var previous = Role.prefix
        /// A break before `index`, after anything already found there.
        func add(_ index: Int, _ kind: Kind, penalty: Int, forced: Bool = false) {
            guard index > 0, index < children.count, result.count < maximumOpportunities else { return }
            let path = path + [index]
            if let last = result.last, last.path == path {
                result[result.count - 1].isForced = last.isForced || forced
                result[result.count - 1].penalty = min(last.penalty, penalty)
                return
            }
            result.append(Opportunity(path: path, kind: kind, penalty: penalty, isForced: forced))
        }
        for (index, child) in children.enumerated() {
            if isSpaceLike(child) {
                if child.name == "mspace", let authored = linebreak(child), authored == "newline" || authored == "goodbreak" {
                    // The row begins with what follows the space: a relation lines up as one.
                    var kind = Kind.authored
                    if let next = children[(index + 1)...].first(where: { !isSpaceLike($0) }).flatMap({ operatorCore($0) }) {
                        switch role(of: next) {
                        case .relation: kind = .relation
                        case .binary: kind = .binary
                        default: break
                        }
                    }
                    add(index, kind, penalty: depth, forced: authored == "newline")
                }
                continue
            }
            if previous == .separator { add(index, .separator, penalty: depth) }
            guard let core = operatorCore(child) else {
                if isRow(child) {
                    collect(child, path: path + [index], penalty: depth, level: level + 1, into: &result)
                } else if child.name == "semantics", let shown = child.children.first, isRow(shown) || shown.name == "semantics" {
                    collect(child, path: path + [index], penalty: depth, level: level + 1, into: &result)
                }
                previous = .operand
                continue
            }
            var role = Self.role(of: core)
            let authored = linebreak(core)
            let after = core.attributes["linebreakstyle"]?.trimmingCharacters(in: .whitespaces).lowercased() == "after"
            if role == .invisible {
                // An invisible times is a break only where the author says so.
                if authored == "newline" || authored == "goodbreak" {
                    add(after ? index + 1 : index, .authored, penalty: depth, forced: authored == "newline")
                }
                continue
            }
            if role == .bar { role = barOpen ? .close : .open; barOpen.toggle() }
            if role == .close { depth = max(base, depth - 1) }
            let follows = previous == .operand || previous == .close
            // A sign after another operator or an opening bracket is unary: nothing breaks there.
            let natural: Kind? = follows && index + 1 < children.count
                ? (role == .relation ? .relation : role == .binary ? .binary : nil) : nil
            let place = after ? index + 1 : index
            switch authored {
            case "newline": add(place, natural ?? .authored, penalty: depth, forced: true)
            case "nobreak": break
            case "goodbreak": add(place, natural ?? .authored, penalty: depth)
            case "badbreak": if let natural { add(place, natural, penalty: depth + 1) }
            default: if let natural { add(place, natural, penalty: depth) }
            }
            if role == .open { depth += 1 }
            previous = role
        }
    }

    // MARK: Rows

    /// The formula from the break at `from` (nil: its start) up to the break at `to` (nil: its
    /// end), keeping every group around those units.
    func slice(from: Int?, to: Int?) -> MathMLNode {
        Self.slice(root, from: from.map { opportunities[$0].path[...] }, to: to.map { opportunities[$0].path[...] })
    }

    private static func slice(_ node: MathMLNode, from: ArraySlice<Int>?, to: ArraySlice<Int>?) -> MathMLNode {
        let count = node.children.count
        let lower = min(from?.first ?? 0, count), upper = min(to?.first ?? count, count)
        var children: [MathMLNode] = []
        if lower <= upper {
            for index in lower...upper where index < count {
                let inner = index == lower ? from.flatMap { $0.count > 1 ? $0.dropFirst() : nil } : nil
                let outer = index == upper ? to.flatMap { $0.count > 1 ? $0.dropFirst() : nil } : nil
                // The end break is before this child, at this level.
                if index == upper, to != nil, outer == nil { break }
                children.append(inner == nil && outer == nil ? node.children[index]
                                : slice(node.children[index], from: inner, to: outer))
            }
        }
        // A row that starts with an operator starts with an empty operand, as amsmath's aligned
        // cells do, so the engine spaces "+ c" as a binary operator rather than a sign.
        if from?.count == 1, let core = children.first(where: { !isSpaceLike($0) }).flatMap({ operatorCore($0) }),
           [Role.relation, .binary].contains(role(of: core)) {
            children.insert(MathMLNode(name: "mi"), at: 0)
        }
        var result = node
        result.children = children
        return result
    }

    /// The unit a row starting at `opportunity` begins with.
    func unit(at opportunity: Int) -> MathMLNode? {
        var node = root
        for index in opportunities[opportunity].path {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }
}

/// A formula as it is drawn: one row, or several stacked rows when it was broken.
///
/// Rows are positioned in the arrangement's own box, `width` wide and `ascent + descent` high.
/// A single row keeps its own baseline; stacked rows centre on the math axis, as a table does.
struct MathArrangement: @unchecked Sendable {
    // Unchecked: `MathLayout` is immutable and thread-safe.
    struct Row {
        let layout: MathLayout
        /// The row's left edge.
        let x: CGFloat
        /// The row's baseline, below the arrangement's top.
        let baseline: CGFloat
    }
    let rows: [Row]
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    var height: CGFloat { ascent + descent }

    init(_ layout: MathLayout) {
        rows = [Row(layout: layout, x: 0, baseline: layout.ascent)]
        width = layout.width; ascent = layout.ascent; descent = layout.descent
    }

    /// Rows stacked top to bottom at their `x` offsets, for text of `fontSize`. Baselines are at
    /// least 1.5 em apart and tall rows keep 0.4 em clear, TeX's `\baselineskip` and `\lineskip`
    /// with the `\jot` its aligned displays add.
    init(stacking rows: [(layout: MathLayout, x: CGFloat)], fontSize: CGFloat) {
        var placed: [Row] = []
        var y: CGFloat = 0, right: CGFloat = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let previous = rows[index - 1].layout
                y += max(0.4 * fontSize, 1.5 * fontSize - previous.descent - row.layout.ascent)
            }
            y += row.layout.ascent
            placed.append(Row(layout: row.layout, x: row.x, baseline: y))
            y += row.layout.descent
            right = max(right, row.x + row.layout.width)
        }
        self.rows = placed
        width = right
        // The font's axis height is the engine's; a quarter em is STIX Two Math's to a hair.
        let axis = min(0.25 * fontSize, y / 2)
        ascent = y / 2 + axis
        descent = y / 2 - axis
    }

    /// Draws into a context whose y axis points up, the box's bottom-left corner at `origin`.
    func draw(in context: CGContext, origin: CGPoint) {
        for row in rows {
            row.layout.draw(in: context, baselineOrigin: CGPoint(x: origin.x + row.x, y: origin.y + height - row.baseline))
        }
    }
}

/// A formula and the rows it takes at each line width.
///
/// The policy for a formula wider than its line, in order:
/// 1. It shrinks to fit while that keeps it at `minimumScale` of the text's size or more.
/// 2. Otherwise it breaks into rows at full size, each as full as the line allows, at breaks
///    outside brackets. A row with no such break in it (a product of bracketed factors) shrinks
///    the rows to fit, again no further than `minimumScale`.
/// 3. Otherwise breaks inside brackets are used too.
/// 4. Rows that still do not fit (a wide fraction, root or table has no break) shrink together
///    to the line, below `minimumScale` since they must: nothing is ever clipped.
/// A `linebreak="newline"` break applies at every width.
final class MathFormula: @unchecked Sendable {
    // Unchecked: immutable but for the cache, which the lock guards.

    /// The least scale a formula shrinks to while breaking it into rows can avoid it: three
    /// quarters of the text's size, which leaves 17-point text's first-level scripts at 9 points.
    static let minimumScale: CGFloat = 0.75
    /// The narrowest reading column formulas are checked against when a section is built:
    /// a small phone held upright.
    static let narrowColumn: CGFloat = 320
    /// Rows replace a shrunken single row when they are at least this much larger.
    private static let worthwhileGain: CGFloat = 1.1

    let node: MathMLNode
    let style: MathStyle
    /// The whole formula on one row.
    let layout: MathLayout
    let breaks: MathBreaks
    /// The formula with room to spare: one row, or the rows its `newline` breaks make.
    let natural: MathArrangement
    private let lock = NSLock()
    private var cache: [(width: CGFloat, arrangement: MathArrangement)] = []

    init(_ node: MathMLNode, style: MathStyle) throws {
        self.node = node
        self.style = style
        layout = try MathLayout(node, style: style)
        breaks = MathBreaks(node)
        var natural = MathArrangement(layout)
        if breaks.opportunities.contains(where: \.isForced),
           let rows = Self.rows(breaks, style: style, width: .greatestFiniteMagnitude) {
            natural = rows
        }
        self.natural = natural
    }

    /// The scale that fits `arrangement` in a line `width` wide.
    static func scale(of arrangement: MathArrangement, in width: CGFloat) -> CGFloat {
        width > 0 && arrangement.width > width ? width / arrangement.width : 1
    }

    /// The rows for a line `width` wide (zero: unbounded), by the policy above.
    func arrangement(fitting width: CGFloat) -> MathArrangement {
        guard width > 0, natural.width * Self.minimumScale > width, breaks.opportunities.contains(where: { !$0.isForced }) else {
            return natural
        }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache.first(where: { abs($0.width - width) < 0.5 }) { return cached.arrangement }
        var chosen = natural
        var best: MathArrangement?
        for insideBrackets in [false, true] {
            guard var rows = Self.rows(breaks, style: style, width: width, insideBrackets: insideBrackets) else { continue }
            // A row with no break in it sets the scale for them all: the others refill to its
            // width rather than stay as short as full size needed them.
            if rows.width > width,
               let refilled = Self.rows(breaks, style: style, width: rows.width, insideBrackets: insideBrackets),
               refilled.width <= rows.width + 0.5 {
                rows = refilled
            }
            if best.map({ rows.width < $0.width }) ?? true { best = rows }
            if Self.scale(of: rows, in: width) >= Self.minimumScale { break }
        }
        // Rows that gain almost nothing (the formula is one wide table after "f(n) =") are
        // not worth their break.
        if let best, Self.scale(of: best, in: width) >= min(1, Self.scale(of: natural, in: width) * Self.worthwhileGain) {
            chosen = best
        }
        if cache.count >= 3 { cache.removeFirst() }
        cache.append((width, chosen))
        return chosen
    }

    /// Whether a line `width` wide shows the formula below `minimumScale` even broken into rows.
    func isReduced(in width: CGFloat) -> Bool {
        Self.scale(of: arrangement(fitting: width), in: width) < Self.minimumScale
    }

    /// Every arrangement made so far, the natural one first.
    var arrangements: [MathArrangement] {
        lock.lock(); defer { lock.unlock() }
        return [natural] + cache.map(\.arrangement)
    }

    /// Fills rows greedily: each ends at the furthest break that keeps it within `width`, among
    /// breaks outside brackets and, with `insideBrackets`, among the others when those leave a
    /// row nearly empty or too wide. A row with no break to end it at overflows. nil when a row
    /// cannot be laid out.
    private static func rows(_ breaks: MathBreaks, style: MathStyle, width: CGFloat, insideBrackets: Bool = true) -> MathArrangement? {
        let all = breaks.opportunities
        var layouts: [[Int]: MathLayout] = [:]
        func layout(from: Int?, to: Int?) -> MathLayout? {
            let key = [from ?? -1, to ?? -1]
            if let known = layouts[key] { return known }
            let made = try? MathLayout(breaks.slice(from: from, to: to), style: style)
            layouts[key] = made
            return made
        }
        // Continuation rows line up on the first relation when it is in the line's first quarter:
        // relations under it and other rows after it. Otherwise they indent two ems.
        var anchor: (relation: CGFloat, operand: CGFloat)?
        let indent = min(2 * style.fontSize, width * 0.15)
        func offset(_ start: Int) -> CGFloat {
            guard let anchor else { return indent }
            return all[start].kind == .relation ? anchor.relation : anchor.operand
        }
        var rows: [(layout: MathLayout, x: CGFloat)] = []
        var start: Int?
        while true {
            let x = start.map(offset) ?? 0
            let limit = width - x
            let lower = (start ?? -1) + 1
            // The row ends at the next forced break at the latest.
            let forced = all[lower...].firstIndex(where: \.isForced)
            let candidates = (lower..<(forced ?? all.count)).filter { insideBrackets || all[$0].penalty == 0 }
            func fits(_ end: Int?) -> Bool { layout(from: start, to: end).map { $0.width <= limit } ?? false }
            // The furthest candidate the row fits up to, as a position in `candidates`: found by
            // doubling steps and then halving, so a row costs layouts of about its own length
            // and never one of everything after it.
            var fitting = -1, beyond = candidates.count, step = 1, probe = 0
            while probe < candidates.count {
                guard fits(candidates[probe]) else { beyond = probe; break }
                fitting = probe
                probe += step
                step *= 2
            }
            var low = fitting + 1, high = beyond - 1
            while low <= high {
                let middle = (low + high) / 2
                if fits(candidates[middle]) { fitting = middle; low = middle + 1 } else { high = middle - 1 }
            }
            var end: Int? = forced
            if !candidates.isEmpty, fitting < candidates.count - 1 || !fits(forced) {
                func fill(_ candidate: Int) -> CGFloat { (layout(from: start, to: candidate)?.width ?? 0) / max(limit, 1) }
                let furthest = fitting >= 0 ? candidates[fitting] : nil
                var chosen = furthest.flatMap { reach in candidates.last { $0 <= reach && all[$0].penalty == 0 } }
                // A break outside brackets that leaves the row nearly empty ("S" alone before
                // "= (a + b + …)") gives way to the furthest break of any kind.
                if chosen.map({ fill($0) < 0.25 }) ?? true { chosen = furthest }
                // A relation is a better place to end than the operator after it, as TeX's
                // penalties have it, unless the row would be left less than two-fifths full.
                if let ending = chosen, all[ending].kind != .relation,
                   let relation = candidates.last(where: { $0 < ending && all[$0].kind == .relation && all[$0].penalty == 0 }),
                   fill(relation) >= 0.4 {
                    chosen = relation
                }
                end = chosen ?? candidates[0]
            }
            guard let row = layout(from: start, to: end) else { return nil }
            // A row too wide for the space after its indent moves left as far as it needs.
            rows.append((row, min(x, max(0, width - row.width))))
            if rows.count == 1, anchor == nil, width.isFinite {
                let firstEnd = end ?? all.count
                if let relation = all.firstIndex(where: { $0.kind == .relation && $0.penalty == 0 }), relation < firstEnd,
                   let prefix = layout(from: nil, to: relation), prefix.width <= width * 0.25,
                   let unit = breaks.unit(at: relation) {
                    var lead = breaks.root
                    lead.children = [MathMLNode(name: "mi"), unit]
                    let advance = (try? MathLayout(lead, style: style))?.width ?? 0
                    if prefix.width + advance <= width * 0.35 { anchor = (prefix.width, prefix.width + advance) }
                }
            }
            guard let next = end else { break }
            start = next
        }
        return rows.count == 1 ? MathArrangement(rows[0].layout) : MathArrangement(stacking: rows, fontSize: style.fontSize)
    }
}
