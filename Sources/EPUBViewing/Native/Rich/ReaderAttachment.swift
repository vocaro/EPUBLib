import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Base of the reader's own attachments (images, SVG, table rows, rules).
///
/// TextKit sizes an attachment each time it lays out the line holding it, so these size
/// themselves from the proposed line and the `ReaderTextContainer` viewport instead of a fixed
/// `bounds`. TextKit 2 text views call the TextKit 2 entry points; string drawing (table cells)
/// may call either generation, so both lead to `layoutBounds(_:)`. Instances are immutable after
/// the section build apart from internally locked caches, so layout may run on any thread.
class ReaderAttachment: NSTextAttachment {
    /// The line an attachment is being laid out on.
    struct Line {
        /// The proposed line fragment's width.
        var width: CGFloat
        /// The attachment's offset from the start of the line fragment.
        var position: CGFloat
        /// The reading viewport (`ReaderTextContainer.viewportSize`), or defaults before layout.
        var viewport: CGSize
        /// The attachment character's font, when known.
        var font: PlatformFont?

        /// The width the attachment may use. At the start of a line the rest of the line, so a
        /// first-line or block indent never pushes it onto a line of its own; after text the
        /// whole line, so TextKit moves it to the next line as a browser would.
        var available: CGFloat {
            let rest = width - position
            return position <= width * 0.15 ? max(1, rest) : max(1, width)
        }

        init(width: CGFloat, position: CGFloat = 0, viewport: CGSize, font: PlatformFont? = nil) {
            self.width = width; self.position = position; self.viewport = viewport; self.font = font
        }

        init(container: NSTextContainer?, fragment: CGRect, position: CGPoint, font: PlatformFont?) {
            let size = ReaderTextContainer.available(in: container, lineWidth: fragment.width)
            let viewportWidth = (container as? ReaderTextContainer)?.viewportSize.width ?? 0
            self.init(width: size.width, position: max(0, position.x),
                      viewport: CGSize(width: viewportWidth > 0 ? viewportWidth : size.width, height: size.height),
                      font: font)
        }
    }

    init() { super.init(data: nil, ofType: nil) }
    required init?(coder: NSCoder) { nil }

    /// The attachment's bounds on `line`. The origin's y is the offset of the bottom edge from
    /// the baseline.
    func layoutBounds(_ line: Line) -> CGRect { .zero }

    /// CSS min-content and max-content widths, for table column widths.
    func contentWidths() -> (min: CGFloat, max: CGFloat) {
        let width = layoutBounds(Line(width: 100_000, viewport: CGSize(width: 100_000, height: 100_000))).width
        return (width, width)
    }

    /// What VoiceOver reads for the attachment inside a table cell.
    var accessibilityText: String { "" }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        layoutBounds(Line(container: textContainer, fragment: proposedLineFragment, position: position,
                          font: attributes[.font] as? PlatformFont))
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        layoutBounds(Line(container: textContainer, fragment: lineFrag, position: position, font: nil))
    }

    /// No view: the attachment is drawn from `image(for:…)`. AppKit's TextKit 2 text view only
    /// asks an attachment for that image when its class overrides this method; otherwise it
    /// draws the legacy attachment cell, which shows nothing here.
    override func viewProvider(for parentView: PlatformView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? { nil }
}

/// The current graphics context's device scale, for decoding bitmaps at the resolution they
/// are drawn at. 2 when there is no context.
func currentDrawingScale() -> CGFloat {
    #if os(iOS)
    let context = UIGraphicsGetCurrentContext()
    #else
    let context = NSGraphicsContext.current?.cgContext
    #endif
    guard let transform = context?.userSpaceToDeviceSpaceTransform else { return 2 }
    let scale = hypot(transform.a, transform.b)
    return scale.isFinite && scale > 0 ? min(scale, 4) : 2
}

extension ComputedStyle.Color {
    var platformColor: PlatformColor { PlatformColor(red: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// `<hr>`: a thin line centred in a line of its own, in the reader's rule color.
final class ReaderRuleAttachment: ReaderAttachment {
    let width: ComputedStyle.Length
    let thickness: CGFloat
    let alignment: Alignment
    let color: PlatformColor
    let fontSize: CGFloat

    enum Alignment: Sendable { case leading, center, trailing }

    init(style: ComputedStyle, isDark: Bool) {
        width = style.width
        let border = style.border.top
        thickness = border.isVisible ? min(max(border.width, 1), 8) : 1
        // A rule is centred unless only one side's margin is `auto`, as CSS places a block box.
        switch (style.margin.left, style.margin.right) {
        case (.auto, .auto): alignment = .center
        case (.auto, _): alignment = .trailing
        case (_, .auto): alignment = .leading
        default: alignment = .center
        }
        color = ReaderPalette.rule(dark: isDark)
        fontSize = style.fontSize
        super.init()
    }
    required init?(coder: NSCoder) { nil }

    override func layoutBounds(_ line: Line) -> CGRect {
        let font = line.font ?? PlatformFont.systemFont(ofSize: fontSize)
        // A text line's height with the bottom in the descent, so the rule line is as tall as text.
        return CGRect(x: 0, y: font.descender, width: line.available,
                      height: max(thickness, font.ascender - font.descender))
    }

    override func contentWidths() -> (min: CGFloat, max: CGFloat) { (0, 0) }

    /// The rule's rect inside an attachment of `size` (top-left origin).
    func ruleRect(in size: CGSize) -> CGRect {
        let length = min(size.width, width.resolve(reference: size.width, viewport: size) ?? size.width)
        let x: CGFloat = switch alignment {
        case .leading: 0
        case .center: (size.width - length) / 2
        case .trailing: size.width - length
        }
        return CGRect(x: x, y: ((size.height - thickness) / 2).rounded(), width: length, height: thickness)
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> PlatformImage? {
        render(bounds.size)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> PlatformImage? {
        render(imageBounds.size)
    }

    private func render(_ size: CGSize) -> PlatformImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let rect = ruleRect(in: size)
        #if os(iOS)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(rect)
        }
        #else
        return NSImage(size: size, flipped: true) { [color] _ in
            color.setFill()
            rect.fill()
            return true
        }
        #endif
    }
}
