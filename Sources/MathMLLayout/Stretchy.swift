import CoreGraphics
import CoreText

/// Stretchy and large operators: MATH table size variants and glyph assemblies (MathML Core
/// 3.3.1, OpenType MathVariants), with drawn shapes for fonts that have neither.
extension LayoutEngine {
    /// Spacing accents whose wide forms the MATH table keys on the combining character.
    private static let combiningEquivalents: [Unicode.Scalar: Unicode.Scalar] = [
        "^": "\u{0302}", "ˆ": "\u{0302}", "~": "\u{0303}", "˜": "\u{0303}", "ˇ": "\u{030C}", "˘": "\u{0306}",
        "¯": "\u{0305}", "‾": "\u{0305}", "_": "\u{0332}",
    ]

    /// A large operator in display style: the first variant at least `DisplayOperatorMinHeight`
    /// tall (and √2 times the text size, as MathML Core asks), else the largest.
    func displayOperator(_ glyph: CGGlyph, _ context: LayoutContext) -> MathBox? {
        guard let construction = font.table?.construction(glyph, vertical: true) else { return nil }
        let natural = glyphBox(glyph, context).height
        let minimum = max(value(\.displayOperatorMinHeight, context), natural * 2.squareRoot())
        let variant = construction.variants.first { font.points($0.advance, size: context.fontSize) >= minimum }
            ?? construction.variants.last
        return variant.map { glyphBox($0.glyph, context) }
    }

    /// An operator stretched to cover `ascent` and `descent`, centred on the math axis when
    /// symmetric. `minsize` and `maxsize` bound the size, relative to the natural size.
    func stretchVertically(_ node: MathMLNode, glyph: CGGlyph?, scalar: Unicode.Scalar?, natural: MathBox,
                           ascent: CGFloat, descent: CGFloat, symmetric: Bool, _ context: LayoutContext) -> MathBox? {
        let axis = value(\.axisHeight, context)
        var top = ascent, bottom = descent
        if symmetric {
            let half = max(ascent - axis, descent + axis)
            top = axis + half; bottom = half - axis
        }
        // TeX's \delimiterfactor and \delimitershortfall: a fence may fall a little short of
        // its content, so f(x) keeps ordinary parentheses.
        var target = max((top + bottom) * 0.901, top + bottom - context.fontSize / 2)
        if let minimum = length(node.attributes["minsize"], context, reference: natural.height) { target = max(target, minimum) }
        if let maximum = node.attributes["maxsize"], maximum.trimmingCharacters(in: .whitespaces) != "infinity",
           let limit = length(maximum, context, reference: natural.height) {
            target = min(target, limit)
        }
        target = min(target, 200 * context.fontSize)
        guard target > natural.height else { return nil }
        let center = (top - bottom) / 2
        if let glyph, let box = stretchedGlyph(glyph, vertical: true, size: target, context) {
            return centered(box, on: center)
        }
        guard let scalar, let box = drawnDelimiter(scalar, height: target, context) else { return nil }
        return centered(box, on: center)
    }

    /// An operator stretched to `width`: a variant or assembly of its own glyph or of the
    /// combining accent it stands for, else a drawn bar, arrow or brace.
    func stretchHorizontally(glyph: CGGlyph?, scalar: Unicode.Scalar?, natural: MathBox, width: CGFloat,
                             _ context: LayoutContext) -> MathBox? {
        let target = min(width, MathLimits.extent)
        guard target > natural.width else { return nil }
        var candidates: [CGGlyph] = glyph.map { [$0] } ?? []
        if let scalar, let combining = Self.combiningEquivalents[scalar], let alternate = font.glyph(for: combining) {
            candidates.append(alternate)
        }
        for candidate in candidates {
            guard font.table?.construction(candidate, vertical: false) != nil else { continue }
            guard var box = stretchedGlyph(candidate, vertical: false, size: target, context) else { continue }
            // Keep the natural glyph's height: accents are designed to sit where they are.
            if candidate != glyph, let ink = natural.inkBounds, let stretched = box.inkBounds {
                box = shifted(box, by: ink.minY - stretched.minY)
            }
            return box
        }
        guard let scalar else { return nil }
        return drawnHorizontal(scalar, width: target, natural: natural, context)
    }

    /// The smallest variant at least `size` long, else an assembly of exactly `size`, else
    /// the largest variant; nil when the font has no construction for the glyph.
    func stretchedGlyph(_ glyph: CGGlyph, vertical: Bool, size: CGFloat, _ context: LayoutContext) -> MathBox? {
        guard let table = font.table, let construction = table.construction(glyph, vertical: vertical) else { return nil }
        if let variant = construction.variants.first(where: { font.points($0.advance, size: context.fontSize) >= size }) {
            return glyphBox(variant.glyph, context)
        }
        if let assembly = assemble(construction, vertical: vertical, size: size, context) { return assembly }
        return construction.variants.last.map { glyphBox($0.glyph, context) }
    }

    /// Parts laid end to end with extenders repeated as needed, overlapping uniformly between
    /// the font's minimum connector overlap and what the connectors allow.
    private func assemble(_ construction: GlyphConstruction, vertical: Bool, size: CGFloat,
                          _ context: LayoutContext) -> MathBox? {
        let parts = construction.parts
        guard !parts.isEmpty, let table = font.table else { return nil }
        let scale = context.fontSize / font.unitsPerEm
        let minimumOverlap = table.minConnectorOverlap * scale
        let fixed = parts.filter { !$0.isExtender }, extenders = parts.filter(\.isExtender)
        let fixedLength = fixed.reduce(0) { $0 + $1.fullAdvance } * scale
        let extenderLength = extenders.reduce(0) { $0 + $1.fullAdvance } * scale
        func longest(_ repeats: Int) -> CGFloat {
            let count = fixed.count + repeats * extenders.count
            return fixedLength + CGFloat(repeats) * extenderLength - CGFloat(max(count - 1, 0)) * minimumOverlap
        }
        var repeats = 0
        if !extenders.isEmpty, extenderLength - CGFloat(extenders.count) * minimumOverlap > 0 {
            while longest(repeats) < size, repeats < 200 { repeats += 1 }
        }
        var sequence: [GlyphConstruction.Part] = []
        for part in parts {
            sequence.append(contentsOf: repeatElement(part, count: part.isExtender ? repeats : 1))
        }
        guard !sequence.isEmpty else { return nil }
        let total = sequence.reduce(0) { $0 + $1.fullAdvance } * scale
        var overlap = minimumOverlap
        if sequence.count > 1 {
            var allowed = CGFloat.greatestFiniteMagnitude
            for index in 1..<sequence.count {
                allowed = min(allowed, min(sequence[index - 1].endConnector, sequence[index].startConnector) * scale)
            }
            overlap = min(max((total - size) / CGFloat(sequence.count - 1), minimumOverlap), max(allowed, minimumOverlap))
        }
        let ctFont = font.font(size: context.fontSize)
        var glyphs: [CGGlyph] = [], positions: [CGPoint] = []
        var ink: CGRect?
        var offset: CGFloat = 0, width: CGFloat = 0
        for (index, part) in sequence.enumerated() {
            if index > 0 { offset -= overlap }
            var glyph = part.glyph
            var rect = CGRect.zero, advance = CGSize.zero
            CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, &rect, 1)
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
            // Vertical parts stack by their ink; horizontal parts by their origins.
            let position = vertical ? CGPoint(x: 0, y: offset - (rect.isEmpty ? 0 : rect.minY)) : CGPoint(x: offset, y: 0)
            glyphs.append(glyph); positions.append(position)
            if !rect.isEmpty {
                let placed = rect.offsetBy(dx: position.x, dy: position.y)
                ink = ink.map { $0.union(placed) } ?? placed
            }
            width = max(width, advance.width)
            offset += part.fullAdvance * scale
        }
        let bounds = ink ?? .zero
        var box = MathBox(width: vertical ? width : offset, ascent: bounds.maxY, descent: -bounds.minY)
        box.italicCorrection = max(0, construction.assemblyItalicsCorrection * scale)
        box.items = [.glyphs(GlyphRun(font: ctFont, glyphs: glyphs, positions: positions, color: context.color,
                                      ink: ink ?? .null))]
        return box
    }

    // MARK: Drawn shapes

    func strokeWidth(_ context: LayoutContext) -> CGFloat {
        max(value(\.fractionRuleThickness, context) * 1.2, 0.5)
    }

    /// A fence, bar, angle bracket or radical sign drawn `height` tall, its ink from the
    /// baseline up; nil for other characters.
    func drawnDelimiter(_ scalar: Unicode.Scalar, height: CGFloat, _ context: LayoutContext) -> MathBox? {
        let em = context.fontSize, stroke = strokeWidth(context)
        let pad = em * 0.06
        var width = em * 0.33
        let top = height - stroke / 2, bottom = stroke / 2, middle = height / 2
        let path = CGMutablePath()
        func x(_ fraction: CGFloat, mirrored: Bool) -> CGFloat {
            pad + stroke / 2 + (mirrored ? 1 - fraction : fraction) * (width - stroke)
        }
        switch scalar {
        case "(", ")":
            let m = scalar == ")"
            path.move(to: CGPoint(x: x(1, mirrored: m), y: top))
            path.addQuadCurve(to: CGPoint(x: x(1, mirrored: m), y: bottom), control: CGPoint(x: x(-1, mirrored: m), y: middle))
        case "[", "]", "⌈", "⌉", "⌊", "⌋":
            let m = "]⌉⌋".unicodeScalars.contains(scalar)
            let hasTop = "[]⌈⌉".unicodeScalars.contains(scalar), hasBottom = "[]⌊⌋".unicodeScalars.contains(scalar)
            path.move(to: CGPoint(x: x(hasTop ? 1 : 0, mirrored: m), y: top))
            if hasTop { path.addLine(to: CGPoint(x: x(0, mirrored: m), y: top)) }
            path.addLine(to: CGPoint(x: x(0, mirrored: m), y: bottom))
            if hasBottom { path.addLine(to: CGPoint(x: x(1, mirrored: m), y: bottom)) }
        case "{", "}":
            let m = scalar == "}"
            let curl = min(height * 0.12, em * 0.3)
            path.move(to: CGPoint(x: x(1, mirrored: m), y: top))
            path.addQuadCurve(to: CGPoint(x: x(0.5, mirrored: m), y: top - curl), control: CGPoint(x: x(0.5, mirrored: m), y: top))
            path.addLine(to: CGPoint(x: x(0.5, mirrored: m), y: middle + curl))
            path.addQuadCurve(to: CGPoint(x: x(0, mirrored: m), y: middle), control: CGPoint(x: x(0.5, mirrored: m), y: middle))
            path.addQuadCurve(to: CGPoint(x: x(0.5, mirrored: m), y: middle - curl), control: CGPoint(x: x(0.5, mirrored: m), y: middle))
            path.addLine(to: CGPoint(x: x(0.5, mirrored: m), y: bottom + curl))
            path.addQuadCurve(to: CGPoint(x: x(1, mirrored: m), y: bottom), control: CGPoint(x: x(0.5, mirrored: m), y: bottom))
        case "⟨", "⟩", "〈", "〉":
            let m = scalar == "⟩" || scalar == "〉"
            path.move(to: CGPoint(x: x(1, mirrored: m), y: top))
            path.addLine(to: CGPoint(x: x(0, mirrored: m), y: middle))
            path.addLine(to: CGPoint(x: x(1, mirrored: m), y: bottom))
        case "|", "∣", "‖", "∥":
            let double = scalar == "‖" || scalar == "∥"
            width = double ? em * 0.25 : stroke
            for fraction in double ? [0.0, 1.0] : [0.0] {
                path.move(to: CGPoint(x: x(fraction, mirrored: false), y: top))
                path.addLine(to: CGPoint(x: x(fraction, mirrored: false), y: bottom))
            }
        case "√":
            width = em * 0.55 + min(height, em * 4) * 0.08
            path.move(to: CGPoint(x: pad, y: height * 0.45))
            path.addLine(to: CGPoint(x: pad + width * 0.2, y: height * 0.55))
            path.addLine(to: CGPoint(x: pad + width * 0.45, y: bottom))
            path.addLine(to: CGPoint(x: pad + width, y: top))
            var box = MathBox(width: pad + width, ascent: height, descent: 0)
            box.items = [.path(path, lineWidth: stroke, color: context.color, fill: false)]
            return box
        default:
            return nil
        }
        var box = MathBox(width: width + 2 * pad, ascent: height, descent: 0)
        box.items = [.path(path, lineWidth: stroke, color: context.color, fill: false)]
        return box
    }

    /// A bar, arrow or brace drawn `width` long at the natural glyph's height.
    private func drawnHorizontal(_ scalar: Unicode.Scalar, width: CGFloat, natural: MathBox,
                                 _ context: LayoutContext) -> MathBox? {
        let em = context.fontSize, stroke = strokeWidth(context)
        let ink = natural.inkBounds ?? CGRect(x: 0, y: value(\.axisHeight, context), width: 0, height: 0)
        let middle = ink.midY
        let path = CGMutablePath()
        var ascent = middle + stroke, descent = -middle + stroke
        switch scalar {
        case "‾", "¯", "_", "\u{0305}", "\u{0332}":
            var box = MathBox(width: width, ascent: middle + stroke / 2, descent: -middle + stroke / 2)
            box.items = [.rect(CGRect(x: 0, y: middle - stroke / 2, width: width, height: stroke), context.color)]
            return box
        case "→", "←", "↔", "⟶", "⟵", "⟷", "\u{20D7}", "\u{20D6}", "\u{20E1}":
            let head = em * 0.25
            path.move(to: CGPoint(x: stroke, y: middle))
            path.addLine(to: CGPoint(x: width - stroke, y: middle))
            if "→↔⟶⟷\u{20D7}\u{20E1}".unicodeScalars.contains(scalar) {
                path.move(to: CGPoint(x: width - stroke - head, y: middle + head * 0.6))
                path.addLine(to: CGPoint(x: width - stroke, y: middle))
                path.addLine(to: CGPoint(x: width - stroke - head, y: middle - head * 0.6))
            }
            if "←↔⟵⟷\u{20D6}\u{20E1}".unicodeScalars.contains(scalar) {
                path.move(to: CGPoint(x: stroke + head, y: middle + head * 0.6))
                path.addLine(to: CGPoint(x: stroke, y: middle))
                path.addLine(to: CGPoint(x: stroke + head, y: middle - head * 0.6))
            }
            ascent = middle + head * 0.6 + stroke; descent = -middle + head * 0.6 + stroke
        case "⏞", "⏟":
            let up: CGFloat = scalar == "⏞" ? 1 : -1
            let depth = min(em * 0.3, width * 0.2) * up
            let base = scalar == "⏞" ? ink.minY : ink.maxY
            let curl = min(width * 0.1, em * 0.3)
            path.move(to: CGPoint(x: stroke, y: base))
            path.addQuadCurve(to: CGPoint(x: stroke + curl, y: base + depth / 2), control: CGPoint(x: stroke, y: base + depth / 2))
            path.addLine(to: CGPoint(x: width / 2 - curl, y: base + depth / 2))
            path.addQuadCurve(to: CGPoint(x: width / 2, y: base + depth), control: CGPoint(x: width / 2, y: base + depth / 2))
            path.addQuadCurve(to: CGPoint(x: width / 2 + curl, y: base + depth / 2), control: CGPoint(x: width / 2, y: base + depth / 2))
            path.addLine(to: CGPoint(x: width - stroke - curl, y: base + depth / 2))
            path.addQuadCurve(to: CGPoint(x: width - stroke, y: base), control: CGPoint(x: width - stroke, y: base + depth / 2))
            ascent = max(base, base + depth) + stroke; descent = -min(base, base + depth) + stroke
        default:
            return nil
        }
        var box = MathBox(width: width, ascent: ascent, descent: descent)
        box.items = [.path(path, lineWidth: stroke, color: context.color, fill: false)]
        return box
    }
}
