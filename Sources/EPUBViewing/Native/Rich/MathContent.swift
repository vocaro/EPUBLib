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
enum MathContent {
    private static let tokens: Set<String> = ["mi", "mn", "mo", "mtext", "ms"]
    private static let colorAttributes: Set<String> = ["mathcolor", "mathbackground", "color", "background"]

    static func make(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        let dark = context.typography.isDark
        let alt = collapsed(element.attribute("alttext") ?? "")
        let textColor = style.color.map(platformColor) ?? ReaderPalette.text(dark: dark)
        let color = textColor.cgColor
        do {
            // Book colors apply in light appearance only, as for text.
            let node = try convert(element, keepsColors: !dark, depth: 0)
            let display = element.attribute("display") == "block" || element.attribute("mode") == "display"
            let layout = try MathLayout(node, style: MathStyle(fontSize: style.fontSize, color: color, isDisplay: display))
            let font = context.fonts.font(for: style)
            let attachment = MathAttachment(layout: layout, label: alt.isEmpty ? node.accessibilityDescription : alt,
                                            clearance: MathAttachment.clearance(for: layout, font: font, style: style))
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

    /// The MathML subtree as the engine's tree. Elements in another namespace keep a prefixed
    /// name, which the engine reports as unsupported. Annotations are dropped unread.
    static func convert(_ element: ContentNode, keepsColors: Bool, depth: Int) throws -> MathMLNode {
        guard depth < 200 else { throw MathLayoutError.limitExceeded }
        let isMathML = element.namespace == ContentNamespace.mathML || element.namespace.isEmpty
        let name = isMathML ? element.name : "foreign:\(element.name)"
        var attributes: [String: String] = [:]
        for attribute in element.attributes where attribute.namespace.isEmpty {
            if !keepsColors, colorAttributes.contains(attribute.name) { continue }
            attributes[attribute.name] = attribute.value
        }
        if isMathML, tokens.contains(name) {
            return MathMLNode(name: name, attributes: attributes, children: element.elementChildren.map { MathMLNode(name: $0.name) },
                              text: element.textContent)
        }
        if isMathML, name == "annotation" || name == "annotation-xml" { return MathMLNode(name: name, attributes: attributes) }
        return MathMLNode(name: name, attributes: attributes,
                          children: try element.elementChildren.map { try convert($0, keepsColors: keepsColors, depth: depth + 1) })
    }

    private static func platformColor(_ color: ComputedStyle.Color) -> PlatformColor {
        #if os(iOS)
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        #elseif os(macOS)
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        #endif
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A laid-out formula in the text. Its bounds put the formula's baseline on the line's, and it
/// shrinks to fit a line narrower, or a page shorter, than itself. It draws once per size and
/// screen scale, when the text view first asks for its image.
///
/// A formula's box is its ink, and TextKit makes a line exactly tall enough for it, so a tall
/// formula would touch the lines around it: a denominator meets the numerator of a fraction on
/// the next line. The bounds therefore add clear space on a side where the formula comes close
/// to the neighbouring lines' content, as TeX's `\lineskip` does; formulas that stay within
/// the text's own line leave the line spacing alone.
final class MathAttachment: NSTextAttachment {
    let layout: MathLayout
    /// What assistive technologies read: the `alttext`, else a spoken reading of the markup.
    let label: String
    /// Clear space above and below the formula, in the formula's unscaled points.
    let clearance: (top: CGFloat, bottom: CGFloat)
    private let lock = NSLock()
    private var cached: (size: CGSize, scale: CGFloat, image: PlatformImage)?

    /// The formula's height with its clearance, unscaled.
    private var paddedHeight: CGFloat { layout.ascent + layout.descent + clearance.top + clearance.bottom }

    /// Clearance for a formula set in `font` on lines `style.lineHeight` apart. TextKit puts a
    /// line's extra height above its text, so the previous line's descenders end at the top of
    /// the line and the next line's text starts below that line's leading. A side gets 0.15 em
    /// when the formula would come closer than that to such content.
    static func clearance(for layout: MathLayout, font: PlatformFont, style: ComputedStyle) -> (top: CGFloat, bottom: CGFloat) {
        let ascent = CTFontGetAscent(font as CTFont), descent = CTFontGetDescent(font as CTFont)
        let natural = InlineStyling.naturalLineHeight(font)
        let lineHeight = max(style.lineHeightPoints ?? natural, natural)
        let leading = lineHeight - ascent - descent
        let space = style.fontSize * 0.15
        return (layout.ascent + space > ascent + leading ? space : 0,
                layout.descent + space > descent + leading ? space : 0)
    }

    init(layout: MathLayout, label: String, clearance: (top: CGFloat, bottom: CGFloat) = (0, 0)) {
        self.layout = layout
        self.label = label
        self.clearance = clearance
        super.init(data: nil, ofType: nil)
        // What string drawing and the attachment cell use when they do not ask for bounds.
        bounds = bounds(lineWidth: 0, height: 0)
        #if os(macOS)
        // AppKit's TextKit 2 text view draws this image, at each destination's resolution. It
        // never asks for `image(for:…)` unless `viewProvider(for:)` is overridden, which would
        // stop it drawing the image; string drawing (table cells) uses the image too.
        let image = NSImage(size: bounds.size, flipped: false) { [clearance] rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            Self.draw(layout, clearance: clearance, in: context, size: rect.size)
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
    #endif

    #if os(iOS)
    /// No view: the formula draws from `image(for:…)`.
    override func viewProvider(for parentView: PlatformView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? { nil }
    #endif

    /// The formula and its clearance, scaled uniformly to fit `lineWidth` and `height` (a
    /// zero leaves that dimension unbounded); the origin is the bottom edge's offset below the
    /// baseline.
    func bounds(lineWidth: CGFloat, height: CGFloat) -> CGRect {
        var scale: CGFloat = 1
        if lineWidth > 0, layout.width > lineWidth { scale = lineWidth / layout.width }
        if height > 0, paddedHeight * scale > height { scale = height / paddedHeight }
        return CGRect(x: 0, y: -(layout.descent + clearance.bottom) * scale, width: layout.width * scale,
                      height: paddedHeight * scale)
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
        let image = Self.render(layout, clearance: clearance, size: size, scale: scale)
        cached = (size, scale, image)
        return image
    }

    /// Draws the formula filling `size`, which has the bounds' proportions, y up.
    private static func draw(_ layout: MathLayout, clearance: (top: CGFloat, bottom: CGFloat), in context: CGContext,
                             size: CGSize) {
        let factor = size.width / layout.width
        context.scaleBy(x: factor, y: factor)
        layout.draw(in: context, baselineOrigin: CGPoint(x: 0, y: clearance.bottom + layout.descent))
    }

    #if os(iOS)
    private static var displayScale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : 3
    }

    private static func render(_ layout: MathLayout, clearance: (top: CGFloat, bottom: CGFloat), size: CGSize,
                               scale: CGFloat) -> PlatformImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            draw(layout, clearance: clearance, in: context, size: size)
        }
    }
    #elseif os(macOS)
    /// AppKit draws a drawing-handler image at each destination's own resolution.
    private static var displayScale: CGFloat { 1 }

    private static func render(_ layout: MathLayout, clearance: (top: CGFloat, bottom: CGFloat), size: CGSize,
                               scale: CGFloat) -> PlatformImage {
        NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(layout, clearance: clearance, in: context, size: size)
            return true
        }
    }
    #endif
}

extension MathAttachment: ReaderTextualAttachment {
    var textEquivalent: String { label }
}
