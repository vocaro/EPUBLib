import CoreGraphics
import CoreText
import Foundation

/// Bounds on untrusted input. A formula beyond them throws `MathLayoutError.limitExceeded`.
enum MathLimits {
    /// Element nesting. Layout recurses per level, so this also bounds stack use.
    static let depth = 64
    static let nodes = 20_000
    /// UTF-16 units of token text in one formula.
    static let textLength = 50_000
    /// Points, any dimension of the result.
    static let extent: CGFloat = 50_000
    /// Drawing items (glyph runs, rules, paths, nested boxes) in one formula.
    static let items = 100_000
}

/// The inherited state of layout at one element: MathML's `displaystyle`, `scriptlevel`,
/// `math-shift` (cramped), `mathvariant`, `mathcolor` and the font size they produce.
struct LayoutContext {
    var fontSize: CGFloat
    /// The size scriptlevel changes compute before the minimum applies.
    var unclampedSize: CGFloat
    /// `scriptminsize`: script level changes never shrink text below it.
    var minSize: CGFloat
    /// `scriptsizemultiplier`; nil uses the font's MATH percentages.
    var sizeMultiplier: CGFloat?
    var scriptLevel = 0
    var display: Bool
    /// TeX's cramped style: superscripts sit lower (under a bar or radical, in subscripts).
    var cramped = false
    var variant: MathVariant?
    var color: CGColor
}

/// What an embellished operator learns from where it sits: its form from its position in a
/// row, and the size to stretch to.
struct Embellishment {
    enum Stretch {
        /// Cover these extents around the baseline (fences, bars, vertical arrows).
        case vertical(ascent: CGFloat, descent: CGFloat)
        /// Cover this width (arrows, braces and wide accents in under- and overscripts).
        case horizontal(width: CGFloat)
    }
    var form: OperatorForm?
    var stretch: Stretch?
    static let none = Embellishment()
}

/// Lays out one formula. Not shared: each `MathLayout` makes its own, so it needs no locking.
///
/// The algorithms follow MathML Core (https://www.w3.org/TR/mathml-core/) and the OpenType MATH
/// specification, with TeX's rules (The TeXbook, appendix G) where those leave a choice.
final class LayoutEngine {
    let font: MathFont
    let constants: MathConstants
    private var nodeCount = 0
    private var textLength = 0

    init(fontName: String?) {
        font = MathFont.named(fontName)
        constants = font.constants
    }

    func layoutRoot(_ root: MathMLNode, style: MathStyle) throws -> MathBox {
        let size = min(max(style.fontSize, 1), 1000)
        let context = LayoutContext(fontSize: size, unclampedSize: size, minSize: min(size, max(8, size * 0.6)),
                                    display: style.isDisplay || root.attributes["display"] == "block",
                                    color: style.color)
        let laidOut = try layout(root, context, depth: 0)
        var box = MathBox(width: laidOut.width, ascent: laidOut.ascent, descent: laidOut.descent)
        // The root covers its ink, so a host that clips to the box (an attachment image) never
        // cuts an italic overhang or a glyph that leans past the left edge.
        let ink = laidOut.inkBounds ?? .zero
        let left = max(0, -ink.minX)
        box.add(laidOut, at: CGPoint(x: left, y: 0))
        box.width = max(0, laidOut.width + left, ink.maxX + left)
        box.ascent = max(0, laidOut.ascent, ink.maxY)
        box.descent = max(0, laidOut.descent, -ink.minY)
        guard [box.width, box.ascent, box.descent].allSatisfy({ $0.isFinite && $0 <= MathLimits.extent }),
              box.itemCount <= MathLimits.items else { throw MathLayoutError.limitExceeded }
        return box
    }

    // MARK: Context

    func value(_ constant: KeyPath<MathConstants, CGFloat>, _ context: LayoutContext) -> CGFloat {
        constants[keyPath: constant] * context.fontSize
    }

    func ctFont(_ context: LayoutContext) -> CTFont { font.font(size: context.fontSize, scriptLevel: context.scriptLevel) }

    func xHeight(_ context: LayoutContext) -> CGFloat {
        let height = CTFontGetXHeight(font.base) * context.fontSize
        return height > 0 ? height : context.fontSize / 2
    }

    func length(_ attribute: String?, _ context: LayoutContext, reference: CGFloat? = nil) -> CGFloat? {
        guard let attribute, let length = MathLength(attribute) else { return nil }
        return length.resolve(em: context.fontSize, ex: xHeight(context), reference: reference)
    }

    /// The size factor of a script level relative to level 0: the MATH table's percentages
    /// for levels 1 and 2, then 0.71 a level (MathML Core's `math-depth`).
    private func scale(_ level: Int, _ context: LayoutContext) -> CGFloat {
        if let multiplier = context.sizeMultiplier { return pow(multiplier, CGFloat(level)) }
        switch level {
        case ...0: return pow(0.71, CGFloat(level))
        case 1: return constants.scriptPercentScaleDown / 100
        default: return constants.scriptScriptPercentScaleDown / 100 * pow(0.71, CGFloat(level - 2))
        }
    }

    func setScriptLevel(_ context: inout LayoutContext, _ level: Int) {
        let level = min(max(level, -8), 16)
        guard level != context.scriptLevel else { return }
        context.unclampedSize *= scale(level, context) / scale(context.scriptLevel, context)
        context.fontSize = max(context.unclampedSize, min(context.fontSize, context.minSize))
        context.scriptLevel = level
    }

    /// Context for scripts, limits, fraction parts and radical indexes: not display style,
    /// `levels` script levels deeper.
    func scriptContext(_ context: LayoutContext, levels: Int = 1, cramped: Bool? = nil) -> LayoutContext {
        var result = context
        result.display = false
        if levels != 0 { setScriptLevel(&result, context.scriptLevel + levels) }
        if let cramped { result.cramped = cramped }
        return result
    }

    /// MathML's attributes that every element may carry and its descendants inherit.
    func inherit(_ node: MathMLNode, _ outer: LayoutContext) -> LayoutContext {
        let attributes = node.attributes
        guard !attributes.isEmpty else { return outer }
        var context = outer
        if node.name == "mstyle" {
            if let multiplier = attributes["scriptsizemultiplier"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
               multiplier > 0.1, multiplier <= 10 {
                context.sizeMultiplier = CGFloat(multiplier)
            }
            if let minimum = length(attributes["scriptminsize"], context, reference: context.fontSize) {
                context.minSize = max(1, minimum)
            }
        }
        if let display = attributes.flag("displaystyle") { context.display = display }
        if let level = attributes["scriptlevel"]?.trimmingCharacters(in: .whitespaces), let number = Int(level) {
            setScriptLevel(&context, level.hasPrefix("+") || level.hasPrefix("-") ? context.scriptLevel + number : number)
        }
        if let size = attributes["mathsize"] ?? attributes["fontsize"] {
            let resolved: CGFloat? = switch size.trimmingCharacters(in: .whitespaces).lowercased() {
            case "small": context.fontSize / 1.2
            case "normal": context.fontSize
            case "big": context.fontSize * 1.2
            default: length(size, context, reference: context.fontSize)
            }
            if let resolved, resolved > 0 {
                context.fontSize = min(resolved, 1000); context.unclampedSize = context.fontSize
            }
        }
        if let color = (attributes["mathcolor"] ?? attributes["color"]).flatMap(MathColor.parse) { context.color = color }
        if let variant = attributes["mathvariant"].flatMap(MathVariant.init(attribute:)) {
            context.variant = variant
        } else if attributes["fontweight"] != nil || attributes["fontstyle"] != nil {
            let bold = attributes["fontweight"] == "bold", italic = attributes["fontstyle"] == "italic"
            context.variant = bold ? (italic ? .boldItalic : .bold) : (italic ? .italic : .normal)
        }
        return context
    }

    // MARK: Dispatch

    static let tokens: Set<String> = ["mi", "mn", "mo", "mtext", "ms"]
    /// Elements that draw nothing.
    private static let empty: Set<String> = ["none", "mprescripts", "annotation", "annotation-xml", "malignmark", "maligngroup"]

    func layout(_ node: MathMLNode, _ outer: LayoutContext, _ embellishment: Embellishment = .none,
                depth: Int) throws -> MathBox {
        guard depth < MathLimits.depth else { throw MathLayoutError.limitExceeded }
        nodeCount += 1
        guard nodeCount <= MathLimits.nodes else { throw MathLayoutError.limitExceeded }
        let context = inherit(node, outer)
        let children = node.children
        var box: MathBox
        switch node.name {
        case "math", "mrow", "mstyle", "mtd":
            box = try row(children, context, embellishment, depth: depth)
        case "mi", "mn", "mtext", "ms":
            box = try token(node, context)
        case "mo":
            box = try operatorBox(node, context, embellishment)
        case "mspace":
            box = MathBox(width: length(node.attributes["width"], context) ?? 0,
                          ascent: length(node.attributes["height"], context) ?? 0,
                          descent: length(node.attributes["depth"], context) ?? 0)
        case "mfrac":
            box = try fraction(node, context, embellishment, depth: depth)
        case "msqrt":
            let base = try row(children, context.with(cramped: true), depth: depth)
            box = radical(base: base, index: nil, context)
        case "mroot":
            try arity(node, 2)
            let base = try layout(children[0], context.with(cramped: true), depth: depth + 1)
            let index = try layout(children[1], scriptContext(context, levels: 2), depth: depth + 1)
            box = radical(base: base, index: index, context)
        case "msub", "msup", "msubsup", "mmultiscripts":
            box = try scripts(node, context, embellishment, depth: depth)
        case "munder", "mover", "munderover":
            box = try underOver(node, context, embellishment, depth: depth)
        case "mpadded":
            box = try padded(node, context, embellishment, depth: depth)
        case "mphantom":
            box = try row(children, context, embellishment, depth: depth)
            box.items = []
        case "menclose":
            box = try enclose(node, context, depth: depth)
        case "mtable":
            box = try table(node, context, depth: depth)
        case "mtr", "mlabeledtr":
            box = try table(MathMLNode(name: "mtable", children: [node]), context, depth: depth)
        case "mfenced":
            box = try row(fenced(node), context, embellishment, depth: depth)
        case "semantics":
            let shown = children.first { $0.name != "annotation" && $0.name != "annotation-xml" }
            box = try shown.map { try layout($0, context, embellishment, depth: depth + 1) } ?? .empty()
        case "maction":
            let selection = node.attributes["selection"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
            let shown = children.indices.contains(selection - 1) ? children[selection - 1] : children.first
            box = try shown.map { try layout($0, context, embellishment, depth: depth + 1) } ?? .empty()
        case "merror":
            box = try errorBox(node, context, depth: depth)
        case let name where Self.empty.contains(name):
            box = .empty()
        default:
            throw MathLayoutError.unsupported(node.name)
        }
        if let background = node.attributes["mathbackground"].flatMap(MathColor.parse) {
            box.items.insert(.rect(CGRect(x: 0, y: -box.descent, width: box.width, height: box.height), background), at: 0)
        }
        return box
    }

    func arity(_ node: MathMLNode, _ count: Int) throws {
        guard node.children.count == count else { throw MathLayoutError.invalidMarkup(node.name) }
    }

    // MARK: Embellished operators

    /// The core `mo` of an embellished operator (MathML Core 3.2.4), or nil.
    func embellishedCore(_ node: MathMLNode, depth: Int = 0) -> MathMLNode? {
        guard depth < MathLimits.depth else { return nil }
        switch node.name {
        case "mo": return node
        case "msub", "msup", "msubsup", "munder", "mover", "munderover", "mmultiscripts", "mfrac", "semantics":
            return node.children.first.flatMap { embellishedCore($0, depth: depth + 1) }
        case "maction":
            return node.children.first.flatMap { embellishedCore($0, depth: depth + 1) }
        case "mrow", "mstyle", "mphantom", "mpadded":
            let inFlow = node.children.filter { !isSpaceLike($0, depth: depth + 1) }
            return inFlow.count == 1 ? embellishedCore(inFlow[0], depth: depth + 1) : nil
        default: return nil
        }
    }

    /// Space-like elements (MathML Core 3.2.5) do not count when inferring an operator's form.
    func isSpaceLike(_ node: MathMLNode, depth: Int = 0) -> Bool {
        guard depth < MathLimits.depth else { return false }
        switch node.name {
        case "mtext", "mspace", "maligngroup", "malignmark": return true
        case "mrow", "mstyle", "mphantom", "mpadded": return node.children.allSatisfy { isSpaceLike($0, depth: depth + 1) }
        case "maction", "semantics": return node.children.first.map { isSpaceLike($0, depth: depth + 1) } ?? false
        default: return false
        }
    }

    /// An `mo`'s text as drawn: hyphen-minus and apostrophe become the minus sign and prime,
    /// as browsers draw them.
    func operatorText(_ node: MathMLNode) -> String {
        let text = Self.normalized(node.text)
        switch text {
        case "-": return "\u{2212}"
        case "'": return "\u{2032}"
        default: return text
        }
    }

    func operatorForm(_ node: MathMLNode, _ inferred: OperatorForm?) -> OperatorForm {
        switch node.attributes["form"]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "prefix": .prefix
        case "postfix": .postfix
        case "infix": .infix
        default: inferred ?? .infix
        }
    }

    func operatorFlags(_ core: MathMLNode, form: OperatorForm?) -> OperatorFlags {
        var flags = OperatorDictionary.entry(operatorText(core), form: operatorForm(core, form)).flags
        let attributes: [(String, OperatorFlags)] = [
            ("stretchy", .stretchy), ("symmetric", .symmetric), ("fence", .fence), ("separator", .separator),
            ("largeop", .largeop), ("movablelimits", .movablelimits), ("accent", .accent),
        ]
        for (name, flag) in attributes {
            if let value = core.attributes.flag(name) { if value { flags.insert(flag) } else { flags.remove(flag) } }
        }
        return flags
    }

    func properties(_ core: MathMLNode, form inferred: OperatorForm?, _ context: LayoutContext) -> OperatorProperties {
        let text = operatorText(core)
        let form = operatorForm(core, inferred)
        let entry = OperatorDictionary.entry(text, form: form)
        let flags = operatorFlags(core, form: inferred)
        // TeX drops binary and relation spacing in scripts; large operators keep theirs.
        let scale = context.scriptLevel > 0 && !flags.contains(.largeop) ? 0 : context.fontSize / 18
        let lspace = length(core.attributes["lspace"], context, reference: context.fontSize) ?? CGFloat(entry.lspace) * scale
        let rspace = length(core.attributes["rspace"], context, reference: context.fontSize) ?? CGFloat(entry.rspace) * scale
        let isBinary = entry.lspace == 4 && entry.rspace == 4
            && core.attributes["lspace"] == nil && core.attributes["rspace"] == nil
        return OperatorProperties(form: form, lspace: lspace, rspace: rspace, flags: flags,
                                  isHorizontal: OperatorDictionary.isHorizontal(text), isBinary: isBinary,
                                  dictionarySpacing: (entry.lspace, entry.rspace))
    }

    private func isStretchy(_ node: MathMLNode, form: OperatorForm?, horizontal: Bool) -> Bool {
        guard let core = embellishedCore(node) else { return false }
        return operatorFlags(core, form: form).contains(.stretchy)
            && OperatorDictionary.isHorizontal(operatorText(core)) == horizontal
    }

    func isHorizontallyStretchy(_ node: MathMLNode) -> Bool { isStretchy(node, form: nil, horizontal: true) }

    // MARK: Rows

    /// An `mrow` or inferred row: operators take their form from their position, vertical
    /// stretchy operators grow to cover the other children, and embellished operators get
    /// their spacing. A row whose only in-flow child is an embellished operator is one itself
    /// and passes `embellishment` down to it.
    func row(_ children: [MathMLNode], _ context: LayoutContext, _ embellishment: Embellishment = .none,
             depth: Int) throws -> MathBox {
        let inFlow = children.indices.filter { !isSpaceLike(children[$0]) }
        let core = inFlow.count == 1 && embellishedCore(children[inFlow[0]]) != nil ? inFlow[0] : nil
        var forms = [OperatorForm](repeating: .infix, count: children.count)
        if inFlow.count > 1 {
            forms[inFlow[0]] = .prefix
            forms[inFlow[inFlow.count - 1]] = .postfix
        }
        var boxes = [MathBox](repeating: .empty(), count: children.count)
        var deferred: [Int] = []
        for (index, child) in children.enumerated() {
            if index == core {
                boxes[index] = try layout(child, context, embellishment, depth: depth + 1)
            } else if isStretchy(child, form: forms[index], horizontal: false) {
                deferred.append(index)
            } else {
                boxes[index] = try layout(child, context, Embellishment(form: forms[index]), depth: depth + 1)
            }
        }
        if !deferred.isEmpty {
            let others = boxes.indices.filter { !deferred.contains($0) }
            let stretch: Embellishment.Stretch? = others.isEmpty ? nil
                : .vertical(ascent: others.map { boxes[$0].ascent }.max()!, descent: others.map { boxes[$0].descent }.max()!)
            for index in deferred {
                boxes[index] = try layout(children[index], context, Embellishment(form: forms[index], stretch: stretch),
                                          depth: depth + 1)
            }
        }
        // TeX's rule 5: a binary operator first, last, or after another operator or an opening
        // fence is unary and unspaced, as in "x = −3" or "(−3 + x)".
        var unary = Set<Int>()
        for (position, index) in inFlow.enumerated() where boxes[index].op?.isBinary == true && index != core {
            let follows = position > 0 ? boxes[inFlow[position - 1]].op.map(isOperatorLike) ?? false : true
            if follows || position == inFlow.count - 1 { unary.insert(index) }
        }
        var box = MathBox()
        var x: CGFloat = 0
        for (index, child) in boxes.enumerated() {
            var lspace = child.op?.lspace ?? 0, rspace = child.op?.rspace ?? 0
            // The enclosing row spaces an embellished row as a whole.
            if index == core || unary.contains(index) { lspace = 0; rspace = 0 }
            if children[index].name == "mo", operatorText(children[index]) == "\u{2061}", context.scriptLevel == 0,
               index > 0, index + 1 < children.count, !startsWithFence(children[index + 1]) {
                rspace = context.fontSize * 3 / 18 // A thin space after a function name, as TeX's \sin x.
            }
            x += lspace
            box.add(child, at: CGPoint(x: x, y: 0))
            x += child.width + rspace
            box.ascent = index == 0 ? child.ascent : max(box.ascent, child.ascent)
            box.descent = index == 0 ? child.descent : max(box.descent, child.descent)
        }
        box.width = x
        if boxes.count == 1 {
            box.italicCorrection = boxes[0].italicCorrection
            box.topAccentAttachment = boxes[0].topAccentAttachment
        }
        if let core { box.op = boxes[core].op }
        return box
    }

    /// Operators after which a binary operator is unary: TeX's Bin, Rel, Open, Punct and Op
    /// atoms. Ellipses, closing fences and postfix operators are ordinary.
    private func isOperatorLike(_ op: OperatorProperties) -> Bool {
        op.isBinary || op.dictionarySpacing.lspace >= 5 || op.has(.separator) || op.has(.largeop)
            || op.has(.movablelimits) || (op.has(.fence) && op.form == .prefix)
    }

    private func startsWithFence(_ node: MathMLNode) -> Bool {
        switch node.name {
        case "mfenced": return true
        case "mrow": return node.children.first.map(startsWithFence) ?? false
        case "mo": return operatorFlags(node, form: .prefix).contains(.fence)
        default: return false
        }
    }

    /// `mfenced` as the row it abbreviates (MathML 3, 3.3.8).
    private func fenced(_ node: MathMLNode) -> [MathMLNode] {
        let open = node.attributes["open"] ?? "(", close = node.attributes["close"] ?? ")"
        let separators = Array((node.attributes["separators"] ?? ",").filter { !$0.isWhitespace })
        var inner: [MathMLNode] = []
        for (index, child) in node.children.enumerated() {
            if index > 0, !separators.isEmpty {
                inner.append(MathMLNode(name: "mo", attributes: ["separator": "true"],
                                        text: String(separators[min(index - 1, separators.count - 1)])))
            }
            inner.append(child)
        }
        var row: [MathMLNode] = []
        if !open.isEmpty { row.append(MathMLNode(name: "mo", attributes: ["fence": "true", "form": "prefix"], text: open)) }
        row.append(contentsOf: inner.count == 1 ? inner : [MathMLNode(name: "mrow", children: inner)])
        if !close.isEmpty { row.append(MathMLNode(name: "mo", attributes: ["fence": "true", "form": "postfix"], text: close)) }
        return row
    }

    // MARK: Tokens

    /// Token text with runs of XML whitespace collapsed to one space, and trimmed unless
    /// `trimming` is off: `mtext` keeps an edge space as browsers do, so "if " stays apart
    /// from what follows.
    static func normalized(_ text: String, trimming: Bool = true) -> String {
        guard text.unicodeScalars.contains(where: isXMLSpace) else { return text }
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isXMLSpace(scalar) { pendingSpace = !trimming || !result.isEmpty; continue }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(scalar)
        }
        if pendingSpace { result.append(" ") }
        return String(result)
    }

    private static func isXMLSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    private func countText(_ text: String) throws {
        textLength += text.utf16.count
        guard textLength <= MathLimits.textLength else { throw MathLayoutError.limitExceeded }
    }

    /// `mi`, `mn`, `mtext` and `ms`. A single-character `mi` is italic unless a `mathvariant`
    /// says otherwise, and its width includes its italic correction (TeX's rule 17).
    private func token(_ node: MathMLNode, _ context: LayoutContext) throws -> MathBox {
        if node.children.contains(where: { $0.name == "mglyph" }) { throw MathLayoutError.unsupported("mglyph") }
        var text = Self.normalized(node.text, trimming: node.name != "mtext" && node.name != "ms")
        if node.name == "ms" {
            text = (node.attributes["lquote"] ?? "\"") + text + (node.attributes["rquote"] ?? "\"")
        }
        try countText(text)
        var variant = context.variant
        if node.name == "mi", variant == nil, text.unicodeScalars.count == 1 { variant = .italic }
        if let variant { text = variant.apply(to: text) }
        var box = textBox(text, context)
        if let glyph = singleGlyph(box), let table = font.table {
            let size = context.fontSize
            if node.name == "mi", let correction = table.italicsCorrection(glyph) {
                box.italicCorrection = max(0, font.points(correction, size: size))
                box.width += box.italicCorrection
            }
            box.topAccentAttachment = table.topAccentAttachment(glyph).map { font.points($0, size: size) }
        }
        return box
    }

    /// Text shaped by CoreText with the math font; characters it lacks come from the
    /// system's fallback fonts.
    func textBox(_ text: String, _ context: LayoutContext) -> MathBox {
        guard !text.isEmpty else { return .empty() }
        let attributes = [kCTFontAttributeName: ctFont(context)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
        var box = MathBox(width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        var ink: CGRect?
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = runAttributes[kCTFontAttributeName] as! CTFont
            var rects = [CGRect](repeating: .zero, count: count)
            CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, glyphs, &rects, count)
            var runInk: CGRect?
            for (rect, position) in zip(rects, positions) where !rect.isEmpty {
                let placed = rect.offsetBy(dx: position.x, dy: position.y)
                runInk = runInk.map { $0.union(placed) } ?? placed
            }
            if let runInk { ink = ink.map { $0.union(runInk) } ?? runInk }
            box.items.append(.glyphs(GlyphRun(font: runFont, glyphs: glyphs, positions: positions,
                                              color: context.color, ink: runInk ?? .null)))
        }
        box.ascent = ink?.maxY ?? 0
        box.descent = ink.map { -$0.minY } ?? 0
        return box
    }

    /// The glyph when `box` is exactly one glyph of the math font.
    func singleGlyph(_ box: MathBox) -> CGGlyph? {
        guard box.items.count == 1, case .glyphs(let run) = box.items[0], run.glyphs.count == 1,
              CTFontCopyPostScriptName(run.font) == CTFontCopyPostScriptName(font.base) else { return nil }
        return run.glyphs[0]
    }

    /// One glyph of the math font at the context's size. A zero-advance glyph (a combining
    /// accent) is moved so its ink starts at the origin and its width is its ink's.
    func glyphBox(_ glyph: CGGlyph, _ context: LayoutContext) -> MathBox {
        let ctFont = font.font(size: context.fontSize)
        var glyph = glyph
        var rect = CGRect.zero, advance = CGSize.zero
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, &rect, 1)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        let italic = font.table?.italicsCorrection(glyph).map { max(0, font.points($0, size: context.fontSize)) } ?? 0
        let shift = advance.width <= 0 && !rect.isEmpty ? -rect.minX : 0
        var box = MathBox(width: advance.width <= 0 ? rect.width : advance.width + italic,
                          ascent: rect.isEmpty ? 0 : rect.maxY, descent: rect.isEmpty ? 0 : -rect.minY)
        box.italicCorrection = italic
        box.topAccentAttachment = font.table?.topAccentAttachment(glyph).map { font.points($0, size: context.fontSize) + shift }
        box.items = [.glyphs(GlyphRun(font: ctFont, glyphs: [glyph], positions: [CGPoint(x: shift, y: 0)],
                                      color: context.color, ink: rect.isEmpty ? .null : rect.offsetBy(dx: shift, dy: 0)))]
        return box
    }

    // MARK: Operators

    private static let invisible: Set<String> = ["\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}", ""]

    /// An `mo`: dictionary properties, the display size of large operators, and stretching.
    private func operatorBox(_ node: MathMLNode, _ context: LayoutContext, _ embellishment: Embellishment) throws -> MathBox {
        if node.children.contains(where: { $0.name == "mglyph" }) { throw MathLayoutError.unsupported("mglyph") }
        var text = operatorText(node)
        try countText(text)
        let properties = properties(node, form: embellishment.form, context)
        guard !Self.invisible.contains(text) else {
            var box = MathBox.empty()
            box.op = properties
            return box
        }
        if let variant = context.variant { text = variant.apply(to: text) }
        var box = textBox(text, context)
        let scalar = text.unicodeScalars.count == 1 ? text.unicodeScalars.first : nil
        let glyph = singleGlyph(box)
        if let glyph {
            box = glyphBox(glyph, context)
            if properties.has(.largeop), context.display { box = displayOperator(glyph, context) ?? box }
        }
        if properties.has(.stretchy), let stretch = embellishment.stretch {
            switch stretch {
            case .vertical(let ascent, let descent) where !properties.isHorizontal:
                box = stretchVertically(node, glyph: glyph, scalar: scalar, natural: box, ascent: ascent, descent: descent,
                                        symmetric: properties.has(.symmetric), context) ?? box
            case .horizontal(let width) where properties.isHorizontal:
                box = stretchHorizontally(glyph: glyph, scalar: scalar, natural: box, width: width, context) ?? box
            default: break
            }
        }
        if properties.has(.largeop) { box = centered(box, on: value(\.axisHeight, context)) }
        box.op = properties
        return box
    }

    /// `box` moved vertically so its ink's middle is at `center`.
    func centered(_ box: MathBox, on center: CGFloat) -> MathBox {
        shifted(box, by: center - (box.ascent - box.descent) / 2)
    }

    func shifted(_ box: MathBox, by dy: CGFloat) -> MathBox {
        guard dy != 0 else { return box }
        var result = MathBox(width: box.width, ascent: box.ascent + dy, descent: box.descent - dy)
        result.italicCorrection = box.italicCorrection
        result.topAccentAttachment = box.topAccentAttachment
        result.op = box.op
        result.add(box, at: CGPoint(x: 0, y: dy))
        return result
    }
}

extension LayoutContext {
    func with(cramped: Bool) -> LayoutContext {
        var context = self
        context.cramped = cramped
        return context
    }
}

/// MathML colors: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` and the HTML 4 color keywords.
enum MathColor {
    private static let names: [String: UInt32] = [
        "black": 0x000000, "silver": 0xC0C0C0, "gray": 0x808080, "grey": 0x808080, "white": 0xFFFFFF,
        "maroon": 0x800000, "red": 0xFF0000, "purple": 0x800080, "fuchsia": 0xFF00FF, "magenta": 0xFF00FF,
        "green": 0x008000, "lime": 0x00FF00, "olive": 0x808000, "yellow": 0xFFFF00, "navy": 0x000080,
        "blue": 0x0000FF, "teal": 0x008080, "aqua": 0x00FFFF, "cyan": 0x00FFFF, "orange": 0xFFA500,
    ]

    static func parse(_ value: String) -> CGColor? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "transparent" { return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0) }
        if let rgb = names[text] { return color(rgb << 8 | 0xFF) }
        guard text.hasPrefix("#"), let number = UInt32(text.dropFirst(), radix: 16) else { return nil }
        switch text.count - 1 {
        case 3, 4:
            let digits = text.count - 1
            var expanded: UInt32 = 0
            for index in 0..<digits {
                let nibble = number >> (4 * UInt32(digits - 1 - index)) & 0xF
                expanded = expanded << 8 | nibble << 4 | nibble
            }
            return color(digits == 3 ? expanded << 8 | 0xFF : expanded)
        case 6: return color(number << 8 | 0xFF)
        case 8: return color(number)
        default: return nil
        }
    }

    private static func color(_ rgba: UInt32) -> CGColor {
        func channel(_ shift: UInt32) -> CGFloat { CGFloat(rgba >> shift & 0xFF) / 255 }
        return CGColor(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
}
