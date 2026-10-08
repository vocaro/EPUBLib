import CoreGraphics
import CoreText
import Foundation

/// Layout of the structural elements: fractions, radicals, scripts, limits, padding,
/// enclosures, tables and errors. Rules follow MathML Core 3.3–3.6 with OpenType MATH constants.
extension LayoutEngine {
    // MARK: Fractions

    func fraction(_ node: MathMLNode, _ context: LayoutContext, _ embellishment: Embellishment,
                  depth: Int) throws -> MathBox {
        try arity(node, 2)
        let inner = scriptContext(context, levels: context.display ? 0 : 1)
        let numerator = try layout(node.children[0], inner, embellishment, depth: depth + 1)
        let denominator = try layout(node.children[1], inner.with(cramped: true), depth: depth + 1)
        let standard = value(\.fractionRuleThickness, context)
        let thickness: CGFloat = switch node.attributes["linethickness"]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil: standard
        case "thin": standard / 2
        case "medium": standard
        case "thick": standard * 2
        case let attribute?: min(max(length(attribute, context, reference: standard) ?? standard, 0), context.fontSize)
        }
        if node.attributes.flag("bevelled") == true {
            return bevelled(numerator, denominator, context)
        }
        let display = context.display
        let axis = value(\.axisHeight, context)
        var numeratorShift: CGFloat, denominatorShift: CGFloat
        if thickness > 0 {
            let numeratorGap = display ? value(\.fractionNumDisplayStyleGapMin, context) : value(\.fractionNumeratorGapMin, context)
            let denominatorGap = display ? value(\.fractionDenomDisplayStyleGapMin, context) : value(\.fractionDenominatorGapMin, context)
            numeratorShift = max(display ? value(\.fractionNumeratorDisplayStyleShiftUp, context) : value(\.fractionNumeratorShiftUp, context),
                                 axis + thickness / 2 + numeratorGap + numerator.descent)
            denominatorShift = max(display ? value(\.fractionDenominatorDisplayStyleShiftDown, context)
                                       : value(\.fractionDenominatorShiftDown, context),
                                   denominator.ascent + denominatorGap - axis + thickness / 2)
        } else {
            numeratorShift = display ? value(\.stackTopDisplayStyleShiftUp, context) : value(\.stackTopShiftUp, context)
            denominatorShift = display ? value(\.stackBottomDisplayStyleShiftDown, context) : value(\.stackBottomShiftDown, context)
            let minimum = display ? value(\.stackDisplayStyleGapMin, context) : value(\.stackGapMin, context)
            let gap = (numeratorShift - numerator.descent) - (denominator.ascent - denominatorShift)
            if gap < minimum {
                numeratorShift += (minimum - gap) / 2
                denominatorShift += (minimum - gap) / 2
            }
        }
        // A little room each side, like TeX's null delimiters, so adjacent bars stay apart.
        let pad = context.fontSize * 0.08
        let width = max(numerator.width, denominator.width)
        func offset(_ part: MathBox, _ attribute: String) -> CGFloat {
            switch node.attributes[attribute]?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "left": 0
            case "right": width - part.width
            default: (width - part.width) / 2
            }
        }
        var box = MathBox(width: width + 2 * pad)
        if thickness > 0 {
            box.items.append(.rect(CGRect(x: pad, y: axis - thickness / 2, width: width, height: thickness), context.color))
        }
        box.add(numerator, at: CGPoint(x: pad + offset(numerator, "numalign"), y: numeratorShift))
        box.add(denominator, at: CGPoint(x: pad + offset(denominator, "denomalign"), y: -denominatorShift))
        box.ascent = max(numeratorShift + numerator.ascent, thickness > 0 ? axis + thickness / 2 : 0)
        box.descent = max(denominatorShift + denominator.descent, thickness > 0 ? thickness / 2 - axis : 0)
        box.op = numerator.op
        return box
    }

    /// `bevelled="true"`: numerator raised, denominator lowered, either side of a slash.
    private func bevelled(_ numerator: MathBox, _ denominator: MathBox, _ context: LayoutContext) -> MathBox {
        let axis = value(\.axisHeight, context)
        let horizontalGap = value(\.skewedFractionHorizontalGap, context)
        let verticalGap = value(\.skewedFractionVerticalGap, context)
        let numeratorShift = axis + verticalGap / 2 + max(numerator.descent, 0)
        let denominatorShift = max(denominator.ascent, 0) - axis + verticalGap / 2
        var slash = textBox("/", context)
        let height = numeratorShift + numerator.ascent + denominatorShift + denominator.descent
        if let glyph = singleGlyph(slash), let stretched = stretchedGlyph(glyph, vertical: true, size: height, context) {
            slash = stretched
        }
        slash = centered(slash, on: (numeratorShift + numerator.ascent - denominatorShift - denominator.descent) / 2)
        var box = MathBox()
        box.add(numerator, at: CGPoint(x: 0, y: numeratorShift))
        let slashX = numerator.width + horizontalGap / 2 - slash.width / 2
        box.add(slash, at: CGPoint(x: slashX, y: 0))
        let denominatorX = max(numerator.width + horizontalGap, slashX + slash.width)
        box.add(denominator, at: CGPoint(x: denominatorX, y: -denominatorShift))
        box.width = denominatorX + denominator.width
        box.ascent = max(numeratorShift + numerator.ascent, slash.ascent)
        box.descent = max(denominatorShift + denominator.descent, slash.descent)
        return box
    }

    // MARK: Radicals

    /// `msqrt` and `mroot`: the radical sign stretched to cover the base and the gap above it,
    /// with the overbar joining its top (MathML Core 3.3.3).
    func radical(base: MathBox, index: MathBox?, _ context: LayoutContext) -> MathBox {
        let thickness = value(\.radicalRuleThickness, context)
        let gap = context.display ? value(\.radicalDisplayStyleVerticalGap, context) : value(\.radicalVerticalGap, context)
        let target = base.ascent + base.descent + gap + thickness
        var sign: MathBox
        let natural = textBox("√", context)
        if let glyph = singleGlyph(natural), font.table != nil {
            sign = stretchedGlyph(glyph, vertical: true, size: target, context) ?? glyphBox(glyph, context)
        } else {
            sign = drawnDelimiter("√", height: target, context) ?? natural
        }
        // Extra height in the sign is shared between the gap and the depth below the base.
        let clearance = gap + max(0, sign.height - target) / 2
        let top = base.ascent + clearance + thickness
        let signShift = top - sign.ascent
        var x: CGFloat = 0
        var box = MathBox()
        var ascent = top + value(\.radicalExtraAscender, context)
        var descent = max(base.descent, sign.descent - signShift)
        if let index {
            let before = value(\.radicalKernBeforeDegree, context), after = value(\.radicalKernAfterDegree, context)
            let raise = constants.radicalDegreeBottomRaisePercent / 100
            let indexShift = signShift - sign.descent + raise * sign.height + index.descent
            x = max(before + index.width + after, 0)
            box.add(index, at: CGPoint(x: max(x - after - index.width, 0), y: indexShift))
            ascent = max(ascent, indexShift + index.ascent)
            descent = max(descent, index.descent - indexShift)
        }
        box.add(sign, at: CGPoint(x: x, y: signShift))
        x += sign.width
        box.items.append(.rect(CGRect(x: x, y: top - thickness, width: base.width, height: thickness), context.color))
        box.add(base, at: CGPoint(x: x, y: 0))
        box.width = x + base.width
        box.ascent = ascent
        box.descent = descent
        return box
    }

    // MARK: Scripts

    /// `msub`, `msup`, `msubsup` and `mmultiscripts`.
    func scripts(_ node: MathMLNode, _ context: LayoutContext, _ embellishment: Embellishment,
                 depth: Int) throws -> MathBox {
        let children = node.children
        switch node.name {
        case "msub", "msup": try arity(node, 2)
        case "msubsup": try arity(node, 3)
        default: guard !children.isEmpty else { throw MathLayoutError.invalidMarkup(node.name) }
        }
        let base = try layout(children[0], context, embellishment, depth: depth + 1)
        let subscriptContext = scriptContext(context, cramped: true), superscriptContext = scriptContext(context)
        func script(_ child: MathMLNode, lower: Bool) throws -> MathBox? {
            guard child.name != "none" else { return nil }
            return try layout(child, lower ? subscriptContext : superscriptContext, depth: depth + 1)
        }
        var post: [(MathBox?, MathBox?)] = [], pre: [(MathBox?, MathBox?)] = []
        switch node.name {
        case "msub": post = try [(script(children[1], lower: true), nil)]
        case "msup": post = try [(nil, script(children[1], lower: false))]
        case "msubsup": post = try [(script(children[1], lower: true), script(children[2], lower: false))]
        default:
            var isPre = false
            var pending: [MathMLNode] = []
            for child in children.dropFirst() {
                if child.name == "mprescripts" { isPre = true; pending = []; continue }
                pending.append(child)
                if pending.count == 2 {
                    let pair = try (script(pending[0], lower: true), script(pending[1], lower: false))
                    if isPre { pre.append(pair) } else { post.append(pair) }
                    pending = []
                }
            }
            if !pending.isEmpty { throw MathLayoutError.invalidMarkup(node.name) }
        }
        return attachScripts(base, post: post, pre: pre, context)
    }

    /// Places sub- and superscript pairs after (and before) a base. Shifts follow MathML Core
    /// 3.4.3, which is TeX's rule 18 in OpenType terms. A base's width includes its italic
    /// correction, so subscripts tuck under by that much and superscripts do not.
    func attachScripts(_ base: MathBox, post: [(MathBox?, MathBox?)], pre: [(MathBox?, MathBox?)],
                       _ context: LayoutContext) -> MathBox {
        let pairs = post + pre
        let subscripts = pairs.compactMap(\.0), superscripts = pairs.compactMap(\.1)
        var subShift: CGFloat = 0, superShift: CGFloat = 0
        if !subscripts.isEmpty {
            subShift = max(value(\.subscriptShiftDown, context), base.descent + value(\.subscriptBaselineDropMin, context),
                           subscripts.map { $0.ascent - value(\.subscriptTopMax, context) }.max()!)
        }
        if !superscripts.isEmpty {
            superShift = max(context.cramped ? value(\.superscriptShiftUpCramped, context) : value(\.superscriptShiftUp, context),
                             base.ascent - value(\.superscriptBaselineDropMax, context),
                             superscripts.map { $0.descent + value(\.superscriptBottomMin, context) }.max()!)
        }
        let minimumGap = value(\.subSuperscriptGapMin, context)
        for case (let sub?, let sup?) in pairs {
            let gap = (superShift - sup.descent) - (sub.ascent - subShift)
            guard gap < minimumGap else { continue }
            subShift += minimumGap - gap
            let lift = value(\.superscriptBottomMaxWithSubscript, context) - (superShift - sup.descent)
            if lift > 0 { superShift += lift; subShift -= lift }
        }
        let space = value(\.spaceAfterScript, context)
        var box = MathBox()
        var x: CGFloat = 0
        var ascent = base.ascent, descent = base.descent
        func place(_ sub: MathBox?, _ sup: MathBox?, subX: CGFloat, supX: CGFloat) {
            if let sub {
                box.add(sub, at: CGPoint(x: subX, y: -subShift))
                descent = max(descent, subShift + sub.descent); ascent = max(ascent, sub.ascent - subShift)
            }
            if let sup {
                box.add(sup, at: CGPoint(x: supX, y: superShift))
                ascent = max(ascent, superShift + sup.ascent); descent = max(descent, sup.descent - superShift)
            }
        }
        for (sub, sup) in pre {
            let width = max(sub?.width ?? 0, sup?.width ?? 0)
            place(sub, sup, subX: x + width - (sub?.width ?? 0), supX: x + width - (sup?.width ?? 0))
            x += width + space
        }
        box.add(base, at: CGPoint(x: x, y: 0))
        x += base.width
        for (index, (sub, sup)) in post.enumerated() {
            let subX = x - (index == 0 ? base.italicCorrection : 0)
            place(sub, sup, subX: subX, supX: x)
            x = max(x, subX + (sub?.width ?? 0), x + (sup?.width ?? 0)) + space
        }
        box.width = x
        box.ascent = ascent
        box.descent = descent
        box.op = base.op
        return box
    }

    // MARK: Under and over

    /// `munder`, `mover` and `munderover`: limits on large operators in display style (as
    /// scripts in text style when `movablelimits`), accents, and stretchy arrows and braces
    /// sized to the widest child (MathML Core 3.4.4).
    func underOver(_ node: MathMLNode, _ context: LayoutContext, _ embellishment: Embellishment,
                   depth: Int) throws -> MathBox {
        try arity(node, node.name == "munderover" ? 3 : 2)
        let children = node.children
        let baseNode = children[0]
        let underNode = node.name == "mover" ? nil : children[1]
        let overNode = node.name == "munder" ? nil : children[node.name == "mover" ? 1 : 2]
        let coreFlags = embellishedCore(baseNode).map { operatorFlags($0, form: embellishment.form) } ?? []
        if coreFlags.contains(.movablelimits), !context.display {
            let base = try layout(baseNode, context, embellishment, depth: depth + 1)
            let sub = try underNode.map { try layout($0, scriptContext(context, cramped: true), depth: depth + 1) }
            let sup = try overNode.map { try layout($0, scriptContext(context), depth: depth + 1) }
            return attachScripts(base, post: [(sub, sup)], pre: [], context)
        }
        func isAccent(_ script: MathMLNode?, _ attribute: String) -> Bool {
            guard let script else { return false }
            return node.attributes.flag(attribute)
                ?? embellishedCore(script).map { operatorFlags($0, form: nil).contains(.accent) } ?? false
        }
        let accent = isAccent(overNode, "accent"), accentUnder = isAccent(underNode, "accentunder")
        let baseContext = accent ? context.with(cramped: true) : context
        let overContext = scriptContext(context, levels: accent ? 0 : 1)
        let underContext = scriptContext(context, levels: accentUnder ? 0 : 1, cramped: true)

        // Non-stretchy children first; horizontal stretchy ones then cover the widest.
        let nodes: [MathMLNode?] = [baseNode, underNode, overNode]
        let contexts = [baseContext, underContext, overContext]
        var boxes: [MathBox?] = [nil, nil, nil]
        let stretchy = nodes.map { $0.map(isHorizontallyStretchy) ?? false }
        for index in 0..<3 where !stretchy[index] {
            guard let child = nodes[index] else { continue }
            boxes[index] = try layout(child, contexts[index], index == 0 ? embellishment : .none, depth: depth + 1)
        }
        let widest = boxes.compactMap { $0?.width }.max()
        for index in 0..<3 where stretchy[index] {
            guard let child = nodes[index] else { continue }
            var stretch = Embellishment(form: index == 0 ? embellishment.form : nil)
            stretch.stretch = widest.map { .horizontal(width: $0) } ?? (index == 0 ? embellishment.stretch : nil)
            boxes[index] = try layout(child, contexts[index], stretch, depth: depth + 1)
        }
        let base = boxes[0]!
        let isLimits = coreFlags.contains(.largeop)
        let rule = value(\.fractionRuleThickness, context)
        var ascent = base.ascent, descent = base.descent
        var overY: CGFloat = 0, underY: CGFloat = 0
        if let over = boxes[2] {
            if isLimits {
                overY = base.ascent + max(value(\.upperLimitBaselineRiseMin, context), value(\.upperLimitGapMin, context) + over.descent)
            } else if accent {
                overY = max(0, base.ascent - value(\.accentBaseHeight, context), base.ascent + rule + over.descent)
            } else {
                let gap = stretchy[2] ? value(\.stretchStackGapBelowMin, context) : value(\.overbarVerticalGap, context)
                overY = base.ascent + gap + over.descent
            }
            ascent = max(ascent, overY + over.ascent + (accent || isLimits ? 0 : value(\.overbarExtraAscender, context)))
            descent = max(descent, over.descent - overY)
        }
        if let under = boxes[1] {
            if isLimits {
                underY = -(base.descent + max(value(\.lowerLimitBaselineDropMin, context), value(\.lowerLimitGapMin, context) + under.ascent))
            } else if accentUnder {
                underY = min(0, -(base.descent + rule / 2 + under.ascent))
            } else {
                let gap = stretchy[1] ? value(\.stretchStackGapAboveMin, context) : value(\.underbarVerticalGap, context)
                underY = -(base.descent + gap + under.ascent)
            }
            descent = max(descent, under.descent - underY + (accentUnder || isLimits ? 0 : value(\.underbarExtraDescender, context)))
            ascent = max(ascent, under.ascent + underY)
        }
        // Centre everything; limits of a slanted integral lean with it, and an accent sits on
        // the base glyph's accent attachment point.
        let width = boxes.compactMap { $0?.width }.max() ?? 0
        let italic = isLimits ? base.italicCorrection : 0
        let baseX = (width - base.width) / 2
        var overX = boxes[2].map { (width - $0.width) / 2 + italic / 2 } ?? 0
        let underX = boxes[1].map { (width - $0.width) / 2 - italic / 2 } ?? 0
        if accent, let over = boxes[2] {
            overX = baseX + (base.topAccentAttachment ?? base.width / 2) - (over.topAccentAttachment ?? over.width / 2)
        }
        let minX = min(baseX, boxes[2] == nil ? baseX : overX, boxes[1] == nil ? baseX : underX)
        var box = MathBox()
        box.add(base, at: CGPoint(x: baseX - minX, y: 0))
        if let under = boxes[1] { box.add(under, at: CGPoint(x: underX - minX, y: underY)) }
        if let over = boxes[2] { box.add(over, at: CGPoint(x: overX - minX, y: overY)) }
        box.width = max(baseX + base.width, boxes[2].map { overX + $0.width } ?? 0, boxes[1].map { underX + $0.width } ?? 0) - minX
        box.ascent = ascent
        box.descent = descent
        box.op = base.op
        if boxes[1] == nil, !isLimits { box.italicCorrection = base.italicCorrection }
        return box
    }

    // MARK: Padding

    /// `mpadded` with MathML 3's relative values and pseudo-units (`+0.5width`).
    func padded(_ node: MathMLNode, _ context: LayoutContext, _ embellishment: Embellishment,
                depth: Int) throws -> MathBox {
        let content = try row(node.children, context, embellishment, depth: depth)
        let dimensions = (width: content.width, height: content.ascent, depth: content.descent)
        func resolve(_ name: String, _ current: CGFloat, reference: CGFloat) -> CGFloat {
            guard let attribute = node.attributes[name], let length = MathLength(attribute),
                  let value = length.resolve(em: context.fontSize, ex: xHeight(context), reference: reference,
                                             content: dimensions) else { return current }
            return length.isRelative ? current + value : value
        }
        var box = MathBox(width: resolve("width", content.width, reference: content.width),
                          ascent: resolve("height", content.ascent, reference: content.ascent),
                          descent: resolve("depth", content.descent, reference: content.descent))
        box.add(content, at: CGPoint(x: resolve("lspace", 0, reference: content.width),
                                     y: resolve("voffset", 0, reference: content.ascent)))
        box.op = content.op
        return box
    }

    // MARK: Enclosures

    /// `menclose` notations: box, roundedbox, circle, the four sides, strikes, longdiv,
    /// actuarial and madruwb. Unknown notations are ignored, as MathML Core asks.
    func enclose(_ node: MathMLNode, _ context: LayoutContext, depth: Int) throws -> MathBox {
        let content = try row(node.children, context, depth: depth)
        let notations = Set((node.attributes["notation"] ?? "longdiv").split(whereSeparator: \.isWhitespace).map(String.init))
        if notations == ["radical"] { return radical(base: content, index: nil, context) }
        let stroke = value(\.overbarRuleThickness, context)
        let em = context.fontSize
        let framed: Set<String> = ["box", "roundedbox", "circle", "left", "right", "top", "bottom", "longdiv",
                                   "actuarial", "madruwb", "radical"]
        let pad = notations.isDisjoint(with: framed) ? 0 : max(stroke * 3, em * 0.12)
        var left = pad, right = pad, top = pad, bottom = pad
        if notations.contains("longdiv") { left += em * 0.3 }
        if notations.contains("radical") { left += em * 0.6 }
        if notations.contains("circle") {
            // An ellipse through the padded box's corners.
            let width = content.width + 2 * pad, height = content.height + 2 * pad
            let dx = width * (2.squareRoot() - 1) / 2, dy = height * (2.squareRoot() - 1) / 2
            left += dx; right += dx; top += dy; bottom += dy
        }
        let width = left + content.width + right
        let ascent = content.ascent + top, descent = content.descent + bottom
        var box = MathBox(width: width, ascent: ascent, descent: descent)
        box.add(content, at: CGPoint(x: left, y: 0))
        let inner = CGRect(x: stroke / 2, y: -descent + stroke / 2, width: width - stroke, height: ascent + descent - stroke)
        let path = CGMutablePath()
        func line(_ from: CGPoint, _ to: CGPoint) { path.move(to: from); path.addLine(to: to) }
        for notation in notations.sorted() {
            switch notation {
            case "box": path.addRect(inner)
            case "roundedbox":
                let radius = min(em * 0.3, inner.width / 2, inner.height / 2)
                path.addRoundedRect(in: inner, cornerWidth: radius, cornerHeight: radius)
            case "circle": path.addEllipse(in: inner)
            case "left": line(CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.minX, y: inner.maxY))
            case "right", "actuarial", "madruwb":
                line(CGPoint(x: inner.maxX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.maxY))
                if notation == "actuarial" { line(CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)) }
                if notation == "madruwb" { line(CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY)) }
            case "top": line(CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY))
            case "bottom": line(CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY))
            case "horizontalstrike":
                let y = (content.ascent - content.descent) / 2
                line(CGPoint(x: inner.minX, y: y), CGPoint(x: inner.maxX, y: y))
            case "verticalstrike": line(CGPoint(x: inner.midX, y: inner.minY), CGPoint(x: inner.midX, y: inner.maxY))
            case "updiagonalstrike", "updiagonalarrow":
                line(CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.maxY))
                if notation == "updiagonalarrow" {
                    let head = em * 0.25, angle = atan2(inner.height, inner.width)
                    for turn in [CGFloat.pi * 0.85, -CGFloat.pi * 0.85] {
                        line(CGPoint(x: inner.maxX, y: inner.maxY),
                             CGPoint(x: inner.maxX + head * cos(angle + turn), y: inner.maxY + head * sin(angle + turn)))
                    }
                }
            case "downdiagonalstrike": line(CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.minY))
            case "longdiv":
                line(CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY))
                path.move(to: CGPoint(x: inner.minX, y: inner.maxY))
                path.addQuadCurve(to: CGPoint(x: inner.minX, y: inner.minY),
                                  control: CGPoint(x: inner.minX + em * 0.35, y: inner.midY))
            case "radical":
                if let sign = drawnDelimiter("√", height: inner.height, context) {
                    box.add(sign, at: CGPoint(x: inner.minX, y: inner.minY))
                    line(CGPoint(x: inner.minX + sign.width, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY))
                }
            default: break
            }
        }
        if !path.isEmpty { box.items.append(.path(path, lineWidth: stroke, color: context.color, fill: false)) }
        return box
    }

    /// `merror`: its content in a red frame.
    func errorBox(_ node: MathMLNode, _ context: LayoutContext, depth: Int) throws -> MathBox {
        let content = try row(node.children, context, depth: depth)
        let stroke = max(value(\.overbarRuleThickness, context), 0.5), pad = context.fontSize * 0.1
        var box = MathBox(width: content.width + 2 * pad, ascent: content.ascent + pad, descent: content.descent + pad)
        box.add(content, at: CGPoint(x: pad, y: 0))
        let frame = CGRect(x: stroke / 2, y: -box.descent + stroke / 2, width: box.width - stroke, height: box.height - stroke)
        box.items.append(.path(CGPath(rect: frame, transform: nil), lineWidth: stroke,
                               color: CGColor(srgbRed: 0.85, green: 0, blue: 0, alpha: 1), fill: false))
        return box
    }

    // MARK: Tables

    /// `mtable`: a grid of baseline-aligned rows with `columnalign`, `rowspacing`,
    /// `columnspacing`, lines and frame, centred on the math axis by default. `mlabeledtr`
    /// labels form a column at the side. Spanning cells occupy one cell.
    func table(_ node: MathMLNode, _ context: LayoutContext, depth: Int) throws -> MathBox {
        guard depth + 2 < MathLimits.depth else { throw MathLayoutError.limitExceeded }
        let cellContext = scriptContext(context, levels: 0)
        let attributes = node.attributes
        func list(_ name: String, in attributes: [String: String]) -> [String] {
            (attributes[name] ?? "").split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        }
        func pick(_ values: [String], _ index: Int) -> String? { values.isEmpty ? nil : values[min(index, values.count - 1)] }
        var cells: [[(box: MathBox, align: String?)]] = []
        var labels: [MathBox?] = []
        for rowNode in node.children {
            let rowContext: LayoutContext
            var cellNodes: [MathMLNode]
            var label: MathMLNode?
            switch rowNode.name {
            case "mtr", "mlabeledtr":
                rowContext = inherit(rowNode, cellContext)
                cellNodes = rowNode.children
                if rowNode.name == "mlabeledtr", !cellNodes.isEmpty { label = cellNodes.removeFirst() }
            default:
                rowContext = cellContext
                cellNodes = [rowNode]
            }
            let rowAlign = list("columnalign", in: rowNode.attributes)
            var row: [(MathBox, String?)] = []
            for (index, cell) in cellNodes.enumerated() {
                let box = try layout(cell, rowContext, depth: depth + 2)
                let align = cell.attributes["columnalign"]?.trimmingCharacters(in: .whitespaces).lowercased()
                    ?? pick(rowAlign, index)
                row.append((box, align))
            }
            cells.append(row)
            labels.append(try label.map { try layout($0, rowContext, depth: depth + 2) })
        }
        let columns = cells.map(\.count).max() ?? 0
        var widths = [CGFloat](repeating: 0, count: columns)
        var ascents = [CGFloat](repeating: 0, count: cells.count), descents = ascents
        for (rowIndex, row) in cells.enumerated() {
            for (column, cell) in row.enumerated() {
                widths[column] = max(widths[column], cell.box.width)
                ascents[rowIndex] = max(ascents[rowIndex], cell.box.ascent)
                descents[rowIndex] = max(descents[rowIndex], cell.box.descent)
            }
            if let label = labels[rowIndex] {
                ascents[rowIndex] = max(ascents[rowIndex], label.ascent)
                descents[rowIndex] = max(descents[rowIndex], label.descent)
            }
        }
        let ex = xHeight(context), em = context.fontSize
        func spacing(_ name: String, _ standard: CGFloat, count: Int) -> [CGFloat] {
            let values = list(name, in: attributes)
            return (0..<max(count, 0)).map { index in
                pick(values, index).flatMap { length($0, context, reference: em) }.map { max($0, 0) } ?? standard
            }
        }
        let rowGaps = spacing("rowspacing", ex, count: cells.count - 1)
        let columnGaps = spacing("columnspacing", 0.8 * em, count: columns - 1)
        let rowLines = list("rowlines", in: attributes), columnLines = list("columnlines", in: attributes)
        let frame = attributes["frame"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "none"
        let framing = list("framespacing", in: attributes)
        let frameX = frame == "none" ? 0 : (pick(framing, 0).flatMap { length($0, context) } ?? 0.4 * em)
        let frameY = frame == "none" ? 0 : (pick(framing, 1).flatMap { length($0, context) } ?? 0.5 * ex)
        let tableAlign = list("columnalign", in: attributes)

        let gridWidth = widths.reduce(0, +) + columnGaps.reduce(0, +)
        let height = ascents.reduce(0, +) + descents.reduce(0, +) + rowGaps.reduce(0, +) + 2 * frameY
        // `align`: axis (default), center or baseline, top, bottom, optionally naming a row
        // whose baseline takes that place.
        let alignParts = list("align", in: attributes)
        var top: CGFloat
        var baselines: [CGFloat] = []
        var y = frameY
        for index in cells.indices {
            baselines.append(y + ascents[index])
            y += ascents[index] + descents[index] + (index < rowGaps.count ? rowGaps[index] : 0)
        }
        let axis = value(\.axisHeight, context)
        let alignment = alignParts.first ?? "axis"
        if alignParts.count > 1, let number = Int(alignParts[1]), number != 0, !cells.isEmpty {
            let row = number > 0 ? min(number, cells.count) - 1 : max(cells.count + number, 0)
            let reference: CGFloat = switch alignment {
            case "top": baselines[row] - ascents[row]
            case "bottom": baselines[row] + descents[row]
            case "center": baselines[row] + (descents[row] - ascents[row]) / 2
            default: baselines[row]
            }
            top = reference + (alignment == "axis" ? axis : 0)
        } else {
            top = switch alignment {
            case "top": 0
            case "bottom": height
            case "center", "baseline": height / 2
            default: height / 2 + axis
            }
        }
        var box = MathBox()
        let labelGap = length(attributes["minlabelspacing"], context, reference: em) ?? 0.8 * em
        let labelWidth = labels.compactMap { $0?.width }.max().map { $0 + labelGap } ?? 0
        let labelsLeft = attributes["side"]?.lowercased().hasPrefix("left") == true
        let gridX = labelsLeft ? labelWidth : 0
        for (rowIndex, row) in cells.enumerated() {
            let baseline = top - baselines[rowIndex]
            var x = gridX + frameX
            for (column, cell) in row.enumerated() {
                let align = cell.align ?? pick(tableAlign, column) ?? "center"
                let offset: CGFloat = switch align {
                case "left": 0
                case "right": widths[column] - cell.box.width
                default: (widths[column] - cell.box.width) / 2
                }
                box.add(cell.box, at: CGPoint(x: x + offset, y: baseline))
                x += widths[column] + (column < columnGaps.count ? columnGaps[column] : 0)
            }
            if let label = labels[rowIndex] {
                let labelX = labelsLeft ? 0 : gridX + gridWidth + 2 * frameX + labelGap
                box.add(label, at: CGPoint(x: labelX, y: baseline))
            }
        }
        // Lines, half-way through the gaps.
        let stroke = value(\.fractionRuleThickness, context)
        let solid = CGMutablePath(), dashed = CGMutablePath()
        let gridLeft = gridX, gridRight = gridX + gridWidth + 2 * frameX
        var lineY = top - frameY
        for index in rowGaps.indices {
            lineY -= ascents[index] + descents[index] + rowGaps[index] / 2
            if let style = pick(rowLines, index), style != "none" {
                let path = style == "dashed" ? dashed : solid
                path.move(to: CGPoint(x: gridLeft, y: lineY)); path.addLine(to: CGPoint(x: gridRight, y: lineY))
            }
            lineY -= rowGaps[index] / 2
        }
        var lineX = gridX + frameX
        for index in columnGaps.indices {
            lineX += widths[index] + columnGaps[index] / 2
            if let style = pick(columnLines, index), style != "none" {
                let path = style == "dashed" ? dashed : solid
                path.move(to: CGPoint(x: lineX, y: top)); path.addLine(to: CGPoint(x: lineX, y: top - height))
            }
            lineX += columnGaps[index] / 2
        }
        if frame != "none" {
            let rect = CGRect(x: gridLeft + stroke / 2, y: top - height + stroke / 2, width: gridRight - gridLeft - stroke,
                              height: height - stroke)
            (frame == "dashed" ? dashed : solid).addRect(rect)
        }
        if !solid.isEmpty { box.items.append(.path(solid, lineWidth: stroke, color: context.color, fill: false)) }
        if !dashed.isEmpty {
            box.items.append(.path(dashed.copy(dashingWithPhase: 0, lengths: [stroke * 4, stroke * 3]),
                                   lineWidth: stroke, color: context.color, fill: false))
        }
        box.width = gridWidth + 2 * frameX + labelWidth
        box.ascent = top
        box.descent = height - top
        return box
    }
}
