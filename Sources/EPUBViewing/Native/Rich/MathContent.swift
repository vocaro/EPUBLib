import CoreGraphics
import Foundation
import MathMLLayout
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Renders a `<math>` element for the rich-content factory: an attachment laid out by
/// `MathMLLayout`, else its `alttext` in italic (counted in `report.mathFallbacks`).
///
/// Layout happens here, during the section build, off the main thread; drawing waits until
/// the text view asks for the attachment's image. `display="block"` formulas lay out in
/// display style; the stylesheet and builder make them their own centred paragraph.
///
/// Glyph images come from the publication, with their alternatives retained for speech and
/// missing images. The reader retains its elementary-math and row-breaking policies.
enum MathContent {
    static func make(_ element: ContentNode, style: ComputedStyle, context: RichContentContext,
                     images: ReaderImageCache = .shared) -> NSAttributedString? {
        let dark = context.typography.isDark
        let alt = collapsed(element.attribute("alttext") ?? "")
        let textColor = style.color.map(platformColor) ?? ReaderPalette.text(dark: dark)
        let color = textColor.cgColor
        do {
            // Book colors apply in light appearance only, as for text.
            var conversion = MathConversion(keepsColors: !dark)
            let source = try conversion.convert(element, depth: 0)
            let glyphs = glyphImages(conversion.glyphs, style: style, context: context, cache: images)
            var isApproximated = glyphs.hasFallback
            let node = MathElementary.rewrite(source, isApproximated: &isApproximated)
            let display = element.attribute("display") == "block" || element.attribute("mode") == "display"
            let formula = try MathFormula(node, style: MathStyle(fontSize: style.fontSize, color: color,
                                                               isDisplay: display, imageProvider: glyphs.provider))
            if isApproximated { context.report.report.mathApproximations += 1 }
            if formula.isReduced(in: MathFormula.narrowColumn) { context.report.report.mathReductions += 1 }
            let font = context.fonts.font(for: style)
            let language = MathSpeech.contentLanguage(of: element, publication: context.publication)
            let reading = MathSpeech.reading(alttext: alt, formula: source, contentLanguage: language)
            let attachment = MathAttachment(formula: formula, reading: reading, font: font, style: style)
            let result = NSMutableAttributedString(attachment: attachment)
            result.addAttributes([.font: font], range: NSRange(location: 0, length: result.length))
            return result
        } catch {
            context.report.report.mathFallbacks += 1
            let text = alt.isEmpty ? collapsed(element.textContent) : alt
            guard !text.isEmpty else { return nil }
            var italic = style
            italic.isItalic = true
            return NSAttributedString(string: text, attributes: [.font: context.fonts.font(for: italic),
                                                                 .foregroundColor: textColor])
        }
    }

    /// Resolve during the section build: a retained provider must not retain the build's
    /// mutable context. Limit retained decoded pixels as well as the shared image cache.
    private static func glyphImages(_ glyphs: [MathMLNode], style: ComputedStyle, context: RichContentContext,
                                    cache: ReaderImageCache) -> (provider: MathImageProvider, hasFallback: Bool) {
        let factory = NativeRichContent(images: cache)
        var resolved: [String: MathImage] = [:]
        var attempted: Set<String> = []
        var bytes = 0
        var hasFallback = false
        for glyph in glyphs {
            guard let reference = glyph.attributes["src"], !reference.isEmpty else { hasFallback = true; continue }
            guard attempted.insert(reference).inserted else { continue }
            guard let path = context.resolve(reference) else { hasFallback = true; continue }
            // At most 1024 pixels on the long side, and 16 MiB of retained images per formula.
            guard bytes < 16 << 20,
                  let resource = factory.resolvedImage(at: path, style: style, context: context),
                  let image = cache.image(for: resource.source, maxPixelSize: 1024,
                                          inverted: style.invertsColors,
                                          lightBackdrop: context.typography.isDark,
                                          maximumDecodedPixelSize: 1024),
                  image.bytesPerRow * image.height <= (16 << 20) - bytes else {
                context.report.report.unreadableResources += 1
                hasFallback = true
                continue
            }
            bytes += image.bytesPerRow * image.height
            resolved[reference] = MathImage(image, logicalSize: resource.intrinsic)
        }
        let images = resolved
        return (.resolving { images[$0] }, hasFallback)
    }

    /// The MathML subtree as the engine's tree, for callers that need no account of what was
    /// replaced on the way.
    static func convert(_ element: ContentNode, keepsColors: Bool, depth: Int) throws -> MathMLNode {
        var conversion = MathConversion(keepsColors: keepsColors)
        return try conversion.convert(element, depth: depth)
    }

    private static func platformColor(_ color: ComputedStyle.Color) -> PlatformColor {
        #if os(iOS)
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        #elseif os(macOS)
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        #endif
    }

    fileprivate static func collapsed(_ text: String) -> String {
        text.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace })
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }
}

/// The MathML subtree as the engine's tree. Elements in another namespace keep a prefixed
/// name, which the engine reports as unsupported. Annotations are dropped unread.
///
/// Token glyphs keep their attributes and mark their position with U+FFFC, as the engine
/// expects. Their images are supplied separately; `alt` remains available for fallback/speech.
struct MathConversion {
    private static let tokens: Set<String> = ["mi", "mn", "mo", "mtext", "ms"]
    private static let colorAttributes: Set<String> = ["mathcolor", "mathbackground", "color", "background"]
    let keepsColors: Bool
    private(set) var glyphs: [MathMLNode] = []

    init(keepsColors: Bool) { self.keepsColors = keepsColors }

    mutating func convert(_ element: ContentNode, depth: Int) throws -> MathMLNode {
        guard depth < 200 else { throw MathLayoutError.limitExceeded }
        let isMathML = Self.isMathML(element)
        let name = isMathML ? element.name : "foreign:\(element.name)"
        var attributes: [String: String] = [:]
        for attribute in element.attributes where attribute.namespace.isEmpty {
            if !keepsColors, Self.colorAttributes.contains(attribute.name) { continue }
            attributes[attribute.name] = attribute.value
        }
        if isMathML, name == "mglyph" {
            if let alt = attributes["alt"] { attributes["alt"] = MathContent.collapsed(alt) }
            if let src = attributes["src"] { attributes["src"] = src.trimmingCharacters(in: .whitespacesAndNewlines) }
            let glyph = MathMLNode(name: name, attributes: attributes)
            glyphs.append(glyph)
            return glyph
        }
        if isMathML, Self.tokens.contains(name) {
            var text = ""
            var children: [MathMLNode] = []
            for child in element.children {
                if child.isText {
                    text += child.text
                } else if Self.isMathML(child), child.name == "mglyph" {
                    text += "\u{FFFC}"
                    children.append(try convert(child, depth: depth + 1))
                } else if child.isElement {
                    children.append(MathMLNode(name: child.name))
                    text += child.textContent
                }
            }
            return MathMLNode(name: name, attributes: attributes, children: children, text: text)
        }
        if isMathML, name == "annotation" || name == "annotation-xml" { return MathMLNode(name: name, attributes: attributes) }
        var children: [MathMLNode] = []
        for child in element.elementChildren { children.append(try convert(child, depth: depth + 1)) }
        return MathMLNode(name: name, attributes: attributes, children: children)
    }

    private static func isMathML(_ node: ContentNode) -> Bool {
        node.isElement && (node.namespace == ContentNamespace.mathML || node.namespace.isEmpty)
    }
}

/// How a formula's arrangements are padded and drawn. Sendable, so the image AppKit draws
/// from can hold it.
///
/// A formula's box is its ink, and TextKit makes a line exactly tall enough for it, so a tall
/// formula would touch the lines around it: a denominator meets the numerator of a fraction on
/// the next line. Its bounds therefore add clear space on a side where the formula comes close
/// to the neighbouring lines' content, as TeX's `\lineskip` does; formulas that stay within
/// the text's own line leave the line spacing alone.
struct MathRendering: Sendable {
    let formula: MathFormula
    /// The surrounding text's ascent, descent and leading, and the clear space a side gets.
    let ascent: CGFloat, descent: CGFloat, leading: CGFloat, space: CGFloat

    /// For a formula set in `font` on lines `style.lineHeight` apart. TextKit puts a line's
    /// extra height above its text, so the previous line's descenders end at the top of the
    /// line and the next line's text starts below that line's leading.
    init(formula: MathFormula, font: PlatformFont, style: ComputedStyle) {
        self.formula = formula
        ascent = CTFontGetAscent(font as CTFont)
        descent = CTFontGetDescent(font as CTFont)
        let natural = InlineStyling.naturalLineHeight(font)
        leading = max(style.lineHeightPoints ?? natural, natural) - ascent - descent
        space = style.fontSize * 0.15
    }

    /// Clear space above and below `arrangement`, in its unscaled points: 0.15 em on a side
    /// where it would come closer than that to the neighbouring line's content.
    func clearance(of arrangement: MathArrangement) -> (top: CGFloat, bottom: CGFloat) {
        (arrangement.ascent + space > ascent + leading ? space : 0,
         arrangement.descent + space > descent + leading ? space : 0)
    }

    /// The arrangement with its clearance, scaled uniformly to fit `lineWidth` and `height` (a
    /// zero leaves that dimension unbounded); the origin is the bottom edge's offset below the
    /// baseline.
    func bounds(lineWidth: CGFloat, height: CGFloat) -> CGRect {
        let arrangement = formula.arrangement(fitting: lineWidth)
        let clearance = clearance(of: arrangement)
        let padded = arrangement.height + clearance.top + clearance.bottom
        var scale = MathFormula.scale(of: arrangement, in: lineWidth)
        if height > 0, padded * scale > height { scale = height / padded }
        return CGRect(x: 0, y: -(arrangement.descent + clearance.bottom) * scale, width: arrangement.width * scale,
                      height: padded * scale)
    }

    /// Draws the formula filling `size`, y up. Of the arrangements made so far it draws the one
    /// whose bounds have the proportions of `shape`, the size it is shown at: bounds are asked
    /// for at layout and the image later, and each arrangement's are shaped differently.
    func draw(in context: CGContext, size: CGSize, shape: CGSize) {
        guard shape.width > 0, shape.height > 0 else { return }
        let wanted = log(shape.width / shape.height)
        var best: (arrangement: MathArrangement, padded: CGFloat, bottom: CGFloat, distance: CGFloat)?
        for arrangement in formula.arrangements where arrangement.width > 0 {
            let clearance = clearance(of: arrangement)
            let padded = arrangement.height + clearance.top + clearance.bottom
            guard padded > 0 else { continue }
            let distance = abs(log(arrangement.width / padded) - wanted)
            if best.map({ distance < $0.distance }) ?? true { best = (arrangement, padded, clearance.bottom, distance) }
        }
        guard let best else { return }
        context.scaleBy(x: size.width / best.arrangement.width, y: size.height / best.padded)
        best.arrangement.draw(in: context, origin: CGPoint(x: 0, y: best.bottom))
    }
}

/// A laid-out formula in the text. Its bounds put the formula's baseline on the line's, and it
/// shrinks, then breaks into rows, to fit a line narrower than itself (`MathFormula`), and
/// shrinks to fit a page shorter than itself. It draws once per size and screen scale, when the
/// text view first asks for its image.
final class MathAttachment: NSTextAttachment {
    let formula: MathFormula
    /// The engine's unbounded layout, including any authored line breaks.
    var layout: MathLayout { formula.layout }
    /// What assistive technologies read: the `alttext`, else a spoken reading of the markup.
    let label: String
    /// The BCP 47 language `label` is in: the content's for an `alttext`, the generator's for
    /// a generated reading. nil when the content declares none.
    let language: String?
    /// Whether `label` is the author's `alttext`.
    let isLabelAuthored: Bool
    /// Clear space above and below the formula with room to spare, in its unscaled points.
    let clearance: (top: CGFloat, bottom: CGFloat)
    private let rendering: MathRendering
    private let lock = NSLock()
    private var cached: (size: CGSize, scale: CGFloat, image: PlatformImage)?

    init(formula: MathFormula, reading: MathSpeech.Reading, font: PlatformFont, style: ComputedStyle) {
        self.formula = formula
        label = reading.text
        language = reading.language
        isLabelAuthored = reading.isAuthored
        let rendering = MathRendering(formula: formula, font: font, style: style)
        self.rendering = rendering
        clearance = rendering.clearance(of: formula.natural)
        super.init(data: nil, ofType: nil)
        // What string drawing and the attachment cell use when they do not ask for bounds.
        bounds = rendering.bounds(lineWidth: 0, height: 0)
        #if os(macOS)
        // AppKit's TextKit 2 text view draws this image, at each destination's resolution. It
        // never asks for `image(for:…)` unless `viewProvider(for:)` is overridden, which would
        // stop it drawing the image; string drawing (table cells) uses the image too. The
        // handler's rectangle is the image's own size whatever the bounds it is drawn into, so
        // the context's transform tells it the proportions of those bounds.
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let transform = context.ctm
            let across = hypot(transform.a, transform.b), up = hypot(transform.c, transform.d)
            let shape = across > 0 && up > 0 ? CGSize(width: rect.width * across, height: rect.height * up) : rect.size
            rendering.draw(in: context, size: rect.size, shape: shape)
            return true
        }
        image.accessibilityDescription = label
        self.image = image
        #endif
    }

    required init?(coder: NSCoder) { nil }

    #if os(iOS)
    /// UITextView reads an attachment's accessibility label in place of its character. The
    /// attachment is made off the main thread, so the label is a getter, not a stored value.
    override var accessibilityLabel: String? {
        get { label }
        set {}
    }

    /// The voice for the label: the book's language for an `alttext`, the generator's otherwise.
    override var accessibilityLanguage: String? {
        get { language }
        set {}
    }
    #endif

    #if os(iOS)
    /// No view: the formula draws from `image(for:…)`.
    override func viewProvider(for parentView: PlatformView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? { nil }
    #endif

    /// The formula and its clearance for a line `lineWidth` wide, scaled to fit it and `height`
    /// (a zero leaves that dimension unbounded); the origin is the bottom edge's offset below the
    /// baseline.
    func bounds(lineWidth: CGFloat, height: CGFloat) -> CGRect {
        rendering.bounds(lineWidth: lineWidth, height: height)
    }

    private func bounds(container: NSTextContainer?, lineWidth: CGFloat) -> CGRect {
        let available = ReaderTextContainer.available(in: container, lineWidth: lineWidth)
        return bounds(lineWidth: available.width, height: available.height)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        bounds(container: textContainer, lineWidth: proposedLineFragment.width)
    }

    /// String drawing (a formula in a table cell) may lay out with TextKit 1.
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        bounds(container: textContainer, lineWidth: lineFrag.width)
    }

    #if os(iOS)
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? {
        image(size: bounds.size)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> PlatformImage? {
        image(size: imageBounds.size)
    }
    #endif

    /// The formula drawn to fill `size`, cached for the last size and scale asked for.
    func image(size: CGSize) -> PlatformImage? {
        guard size.width > 0, size.height > 0, layout.width > 0 else { return nil }
        let scale = Self.displayScale
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.size == size, cached.scale == scale { return cached.image }
        let image = Self.render(rendering, size: size, scale: scale)
        cached = (size, scale, image)
        return image
    }

    #if os(iOS)
    private static var displayScale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : 3
    }

    private static func render(_ rendering: MathRendering, size: CGSize, scale: CGFloat) -> PlatformImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            rendering.draw(in: context, size: size, shape: size)
        }
    }
    #elseif os(macOS)
    /// AppKit draws a drawing-handler image at each destination's own resolution.
    private static var displayScale: CGFloat { 1 }

    private static func render(_ rendering: MathRendering, size: CGSize, scale: CGFloat) -> PlatformImage {
        NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            rendering.draw(in: context, size: size, shape: size)
            return true
        }
    }
    #endif
}

extension MathAttachment: ReaderTextualAttachment {
    var textEquivalent: String { label }
    var textLanguage: String? { language }
}
