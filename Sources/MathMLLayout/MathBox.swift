import CoreGraphics
import CoreText

/// A laid-out box: an advance `width` and its extents above (`ascent`) and below (`descent`)
/// the baseline, with what it draws relative to its baseline origin, y up. Extents follow the
/// ink of glyphs, so either may be negative (an accent floats above the baseline).
struct MathBox {
    var width: CGFloat = 0
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    /// How far an italic glyph's top leans past the advance; superscripts start after it.
    var italicCorrection: CGFloat = 0
    /// Where an accent over this box centres, from its left edge; nil is the middle.
    var topAccentAttachment: CGFloat?
    /// Set when the box is an embellished operator: the core `mo`'s resolved properties.
    var op: OperatorProperties?
    var items: [MathItem] = []

    var height: CGFloat { ascent + descent }

    static func empty(width: CGFloat = 0, ascent: CGFloat = 0, descent: CGFloat = 0) -> MathBox {
        MathBox(width: width, ascent: ascent, descent: descent)
    }

    /// Adds `box` with its baseline origin at `point`. Its extents are not merged: callers set
    /// their own metrics.
    mutating func add(_ box: MathBox, at point: CGPoint) {
        guard !box.items.isEmpty else { return }
        if point == .zero, box.items.count == 1, case .box = box.items[0] { items.append(box.items[0]); return }
        items.append(.box(box, at: point))
    }

    /// The union of everything drawn, relative to the baseline origin; nil when nothing is.
    var inkBounds: CGRect? {
        var result: CGRect?
        func merge(_ rect: CGRect) { result = result.map { $0.union(rect) } ?? rect }
        for item in items {
            switch item {
            case .glyphs(let run): if !run.ink.isNull { merge(run.ink) }
            case .rect(let rect, _): merge(rect)
            case .path(let path, let lineWidth, _, _):
                merge(path.boundingBoxOfPath.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
            case .box(let box, let point):
                if let ink = box.inkBounds { merge(ink.offsetBy(dx: point.x, dy: point.y)) }
            }
        }
        return result
    }

    var itemCount: Int {
        items.reduce(0) { count, item in
            if case .box(let box, _) = item { return count + 1 + box.itemCount }
            return count + 1
        }
    }

    func draw(in context: CGContext, at origin: CGPoint) {
        for item in items {
            switch item {
            case .glyphs(let run):
                context.setFillColor(run.color)
                let positions = run.positions.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                CTFontDrawGlyphs(run.font, run.glyphs, positions, run.glyphs.count, context)
            case .rect(let rect, let color):
                context.setFillColor(color)
                context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            case .path(let path, let lineWidth, let color, let fill):
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                context.addPath(path)
                if fill {
                    context.setFillColor(color)
                    context.fillPath()
                } else {
                    context.setStrokeColor(color)
                    context.setLineWidth(lineWidth)
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    context.strokePath()
                }
                context.restoreGState()
            case .box(let box, let point):
                box.draw(in: context, at: CGPoint(x: origin.x + point.x, y: origin.y + point.y))
            }
        }
    }
}

/// Glyphs of one font, positioned relative to a box's baseline origin.
struct GlyphRun {
    var font: CTFont
    var glyphs: [CGGlyph]
    var positions: [CGPoint]
    var color: CGColor
    /// Ink bounds relative to the same origin.
    var ink: CGRect
}

enum MathItem {
    case glyphs(GlyphRun)
    case rect(CGRect, CGColor)
    /// Stroked with `lineWidth`, or filled when the flag is set.
    case path(CGPath, lineWidth: CGFloat, color: CGColor, fill: Bool)
    case box(MathBox, at: CGPoint)
}
