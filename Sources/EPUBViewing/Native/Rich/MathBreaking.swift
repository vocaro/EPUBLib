import CoreGraphics
import Foundation
import MathMLLayout
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Engine rows positioned in a formula's box. Display stacks centre on the font's actual
/// math axis; a single row keeps its baseline. Drawing uses the engine's retained row boxes.
struct MathArrangement: @unchecked Sendable {
    struct Row {
        let layout: MathLayout.Row
        let x: CGFloat
        /// Baseline measured down from the arrangement's top.
        let baseline: CGFloat
    }
    let rows: [Row]
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    var height: CGFloat { ascent + descent }

    init(_ layout: MathLayout) {
        width = layout.width
        let height = layout.ascent + layout.descent
        ascent = layout.rows.count > 1 ? height / 2 + layout.axisHeight : layout.ascent
        descent = height - ascent
        rows = layout.rows.map { Row(layout: $0, x: $0.origin.x, baseline: layout.ascent - $0.origin.y) }
    }

    /// One inline row. Non-final rows consume their remaining line width so TextKit puts the
    /// next row on the next text line. The final row leaves room for the sentence after it.
    init(row: MathLayout.Row?, width: CGFloat = 0, ascent: CGFloat? = nil, descent: CGFloat? = nil) {
        let rowAscent = ascent ?? row?.ascent ?? 0
        self.ascent = rowAscent
        self.descent = descent ?? row?.descent ?? 0
        rows = row.map { [Row(layout: $0, x: $0.origin.x, baseline: rowAscent)] } ?? []
        self.width = row.map { max(width, $0.origin.x + $0.width) } ?? width
    }

    func draw(in context: CGContext, origin: CGPoint) {
        for row in rows {
            row.layout.draw(in: context, baselineOrigin: CGPoint(x: origin.x + row.x, y: origin.y + height - row.baseline))
        }
    }
}

/// The engine owns break selection, operator spacing, indentation and structural wrapping.
/// The host scales only ink that remains wider than its column, and to fit a page's height.
final class MathFormula: @unchecked Sendable {
    static let minimumScale: CGFloat = 0.75
    static let narrowColumn: CGFloat = 320
    let node: MathMLNode
    let style: MathStyle
    let layout: MathLayout
    let natural: MathArrangement
    private let lock = NSLock()
    private var cache: [(width: CGFloat, layout: MathLayout)] = []

    init(_ node: MathMLNode, style: MathStyle) throws {
        self.node = node
        self.style = style
        layout = try MathLayout(node, style: style)
        natural = MathArrangement(layout)
    }

    static func scale(of arrangement: MathArrangement, in width: CGFloat) -> CGFloat {
        width > 0 && arrangement.width > width ? width / arrangement.width : 1
    }

    func arrangement(fitting width: CGFloat) -> MathArrangement {
        MathArrangement(boundedLayout(width: width))
    }

    func boundedLayout(width: CGFloat) -> MathLayout {
        guard width > 0, width.isFinite else { return layout }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache.first(where: { $0.width == width }) { return cached.layout }
        // Limit failures fall back to the already validated natural layout, uniformly scaled.
        let chosen = (try? MathLayout(node, style: style, maximumWidth: width)) ?? layout
        if cache.count >= 4 { cache.removeFirst() }
        cache.append((width, chosen))
        return chosen
    }

    func isReduced(in width: CGFloat) -> Bool {
        Self.scale(of: arrangement(fitting: width), in: width) < Self.minimumScale
    }

    var arrangements: [MathArrangement] {
        lock.lock(); defer { lock.unlock() }
        return [natural] + cache.map { MathArrangement($0.layout) }
    }
}

/// Stable source slots for inline rows. The engine's most finely broken layout bounds their
/// number. Unused slots take no space; changing a viewport never changes source offsets, CFIs
/// or selection ranges. Layout choices belong to the text container that measured them.
final class MathInlineRows: @unchecked Sendable {
    let formula: MathFormula
    let count: Int
    let ascent: CGFloat
    let descent: CGFloat
    private struct Choice {
        weak var container: NSTextContainer?
        let width: CGFloat
        let firstWidth: CGFloat
        let layout: MathLayout
    }
    private let lock = NSLock()
    private var choices: [Choice] = []
    private var serial = 0
    var revision: Int { lock.lock(); defer { lock.unlock() }; return serial }

    init?(formula: MathFormula) {
        // Short inline formulas remain atomic. A long formula, or an authored multi-row one,
        // can flow over paragraph lines. Bound placeholder storage for untrusted formulas.
        guard formula.layout.width > MathFormula.narrowColumn * MathFormula.minimumScale || formula.layout.rows.count > 1,
              let finest = try? MathLayout(formula.node, style: formula.style, maximumWidth: 0),
              finest.rows.count > 1, finest.rows.count <= 256 else { return nil }
        // Paragraph lines use TextKit's leading. Keep explicitly authored math leading
        // inside one width-aware attachment, where the engine's vertical origins apply.
        var pending = [formula.node]
        while let node = pending.popLast() {
            guard node.attributes["lineleading"] == nil else { return nil }
            pending.append(contentsOf: node.children)
        }
        let ascent = formula.layout.rows.map(\.ascent).max() ?? 0
        let descent = formula.layout.rows.map(\.descent).max() ?? 0
        // TextKit caches an attachment's vertical image metrics from its initial proposal.
        // All slots keep the tallest source row's metrics, including dormant slots. A
        // structure that grows vertically when its interior wraps stays one attachment.
        guard finest.rows.allSatisfy({ $0.ascent <= ascent + 0.01 && $0.descent <= descent + 0.01 }) else { return nil }
        self.formula = formula
        self.ascent = ascent
        self.descent = descent
        count = finest.rows.count
    }

    func arrangement(row index: Int, width: CGFloat, position: CGFloat, container: NSTextContainer?) -> MathArrangement {
        guard width > 0, let container else {
            return arrangement(row: index < formula.layout.rows.count ? formula.layout.rows[index] : nil)
        }
        lock.lock(); defer { lock.unlock() }
        let layout: MathLayout
        let firstWidth: CGFloat
        if index == 0 {
            firstWidth = max(0, width - position)
            if let found = choices.lastIndex(where: { $0.container === container && $0.width == width && $0.firstWidth == firstWidth }) {
                if found != choices.count - 1 { serial &+= 1 }
                let choice = choices.remove(at: found)
                choices.append(choice)
                layout = choice.layout
            } else {
                layout = (try? MathLayout(formula.node, style: formula.style, maximumWidth: width,
                                           firstRowMaximumWidth: firstWidth)) ?? formula.layout
                if choices.count >= 12 { choices.removeFirst() }
                choices.append(Choice(container: container, width: width, firstWidth: firstWidth, layout: layout))
                serial &+= 1
            }
        } else if let choice = choices.last(where: { $0.container === container && $0.width == width })
                    ?? choices.last(where: { $0.width == width }) {
            // A page can begin at a continuation slot. Its measuring layout has already
            // selected the same rows at this width, including the original first-line budget.
            layout = choice.layout
            firstWidth = choice.firstWidth
            if choice.container !== container {
                if choices.count >= 12 { choices.removeFirst() }
                choices.append(Choice(container: container, width: width, firstWidth: firstWidth, layout: layout))
                serial &+= 1
            }
        } else {
            layout = formula.boundedLayout(width: width)
            firstWidth = width
            if choices.count >= 12 { choices.removeFirst() }
            choices.append(Choice(container: container, width: width, firstWidth: firstWidth, layout: layout))
            serial &+= 1
        }
        guard index < layout.rows.count else { return arrangement(row: nil) }
        // If a constrained attempt cannot fit the reserved slots, retain the formula whole.
        guard layout.rows.count <= count else { return index == 0 ? MathArrangement(layout) : arrangement(row: nil) }
        let budget = index == 0 ? firstWidth : width
        let row = layout.rows[index]
        return arrangement(row: row, width: index < layout.rows.count - 1 ? budget : 0)
    }

    private func arrangement(row: MathLayout.Row?, width: CGFloat = 0) -> MathArrangement {
        MathArrangement(row: row, width: row == nil ? 0.0001 : width, ascent: ascent, descent: descent)
    }

    func arrangements(row index: Int, container: NSTextContainer? = nil) -> [MathArrangement] {
        lock.lock(); defer { lock.unlock() }
        var result: [MathArrangement] = []
        for choice in choices.reversed() where index < choice.layout.rows.count && (container == nil || choice.container === container) {
            if choice.layout.rows.count > count {
                result.append(index == 0 ? MathArrangement(choice.layout) : arrangement(row: nil))
            } else {
                let budget = index == 0 ? choice.firstWidth : choice.width
                result.append(arrangement(row: choice.layout.rows[index], width: index < choice.layout.rows.count - 1 ? budget : 0))
            }
        }
        result.append(arrangement(row: index < formula.layout.rows.count ? formula.layout.rows[index] : nil))
        return result
    }
}
