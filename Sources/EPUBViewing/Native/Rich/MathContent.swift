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
            let attachment = MathAttachment(layout: layout, label: alt.isEmpty ? node.accessibilityDescription : alt)
            let result = NSMutableAttributedString(attachment: attachment)
            result.addAttributes([.font: context.fonts.font(for: style)], range: NSRange(location: 0, length: result.length))
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
/// shrinks to fit a line narrower than itself. It draws once per size and screen scale, when
/// the text view first asks for its image.
final class MathAttachment: NSTextAttachment {
    let layout: MathLayout
    /// What assistive technologies read: the `alttext`, else a spoken reading of the markup.
    let label: String
    private let lock = NSLock()
    private var cached: (size: CGSize, scale: CGFloat, image: PlatformImage)?

    init(layout: MathLayout, label: String) {
        self.layout = layout
        self.label = label
        super.init(data: nil, ofType: nil)
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

    #if os(macOS)
    private var isLabelled = false

    /// NSTextView exposes an attachment to accessibility through its cell, which AppKit makes
    /// on first use (on the main thread). The cell gets the label and the image role there;
    /// drawing still comes from `image(for:…)`, and the view stays on TextKit 2.
    override var attachmentCell: (any NSTextAttachmentCellProtocol)? {
        get {
            let cell = super.attachmentCell
            if !isLabelled, Thread.isMainThread, let cell = cell as? NSCell {
                isLabelled = true
                let label = label
                MainActor.assumeIsolated {
                    cell.setAccessibilityLabel(label)
                    cell.setAccessibilityRole(.image)
                }
            }
            return cell
        }
        set { super.attachmentCell = newValue }
    }
    #endif

    /// The formula's size scaled to fit `lineWidth`, origin at its descent below the baseline.
    func bounds(lineWidth: CGFloat) -> CGRect {
        let scale = layout.width > lineWidth && lineWidth > 0 ? lineWidth / layout.width : 1
        return CGRect(x: 0, y: -layout.descent * scale, width: layout.width * scale,
                      height: (layout.ascent + layout.descent) * scale)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        bounds(lineWidth: ReaderTextContainer.available(in: textContainer, lineWidth: proposedLineFragment.width).width)
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? {
        image(size: bounds.size)
    }

    /// The formula drawn to fill `size`, cached for the last size and scale asked for.
    func image(size: CGSize) -> PlatformImage? {
        guard size.width > 0, size.height > 0, layout.width > 0 else { return nil }
        let scale = Self.displayScale
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.size == size, cached.scale == scale { return cached.image }
        let image = Self.render(layout, size: size, scale: scale)
        cached = (size, scale, image)
        return image
    }

    private static func draw(_ layout: MathLayout, in context: CGContext, size: CGSize) {
        let factor = size.width / layout.width
        context.scaleBy(x: factor, y: factor)
        layout.draw(in: context, baselineOrigin: CGPoint(x: 0, y: layout.descent))
    }

    #if os(iOS)
    private static var displayScale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : 3
    }

    private static func render(_ layout: MathLayout, size: CGSize, scale: CGFloat) -> PlatformImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            draw(layout, in: context, size: size)
        }
    }
    #elseif os(macOS)
    /// AppKit draws a drawing-handler image at each destination's own resolution.
    private static var displayScale: CGFloat { 1 }

    private static func render(_ layout: MathLayout, size: CGSize, scale: CGFloat) -> PlatformImage {
        NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(layout, in: context, size: size)
            return true
        }
    }
    #endif
}
