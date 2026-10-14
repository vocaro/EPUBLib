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
class ReaderAttachment: NSTextAttachment, ReaderTextualAttachment {
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
        /// Stable first-line reservation for block attachments. TextKit's preliminary sizing
        /// callback can report position zero before applying the paragraph's leading indent.
        var leadingIndent: CGFloat = 0

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

        init(container: NSTextContainer?, fragment: CGRect, position: CGPoint, font: PlatformFont?, paragraphStyle: NSParagraphStyle? = nil,
             characterIndex: Int? = nil) {
            let size = ReaderTextContainer.available(in: container, lineWidth: fragment.width)
            let viewportWidth = (container as? ReaderTextContainer)?.viewportSize.width ?? 0
            // A custom text container clips the paragraph tail, but TextKit can still ask
            // attachments to size against an unclipped proposed rectangle. Apply that same
            // trailing edge before subtracting the native leading/glyph position.
            var width = size.width
            // Native attachment proposals can still span the viewport before TextKit asks
            // lineFragmentRect for the float/positioned/inline box's actual content column.
            // Resolve percentage image sizes against that column on both callback paths.
            if let column = (container as? ReaderTextContainer)?.attachmentColumn(at: characterIndex) {
                width = min(width, max(1, column.width))
            }
            if let style = paragraphStyle, viewportWidth > 0 {
                let trailing = style.tailIndent <= 0 ? viewportWidth + style.tailIndent : style.tailIndent
                width = min(width, max(1, trailing - fragment.minX))
            }
            self.init(width: width, position: max(0, position.x),
                      viewport: CGSize(width: viewportWidth > 0 ? viewportWidth : size.width, height: size.height),
                      font: font)
            leadingIndent = max(0, paragraphStyle?.firstLineHeadIndent ?? 0)
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

    /// What selections and copies get in place of the attachment character, and the words
    /// VoiceOver is given for it. Nothing by default: a rule has no words, and what VoiceOver
    /// says at one is the reader's own (`ReaderRuleAttachment.spokenName`).
    var textEquivalent: String { "" }
    /// The language `textEquivalent` is spoken in, when it is known to differ from the text around it.
    var textLanguage: String? { nil }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        let manager = textContainer?.textLayoutManager?.textContentManager
        let index = manager.map { $0.offset(from: $0.documentRange.location, to: location) }
        return layoutBounds(Line(container: textContainer, fragment: proposedLineFragment, position: position,
                          font: attributes[.font] as? PlatformFont, paragraphStyle: attributes[.paragraphStyle] as? NSParagraphStyle,
                          characterIndex: index))
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let text = (textContainer as? ReaderTextContainer)?.paragraphText
        let style = text.flatMap { charIndex < $0.length ? $0.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle : nil }
        return layoutBounds(Line(container: textContainer, fragment: lineFrag, position: position, font: nil, paragraphStyle: style,
                                 characterIndex: charIndex))
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

    /// What an assistive technology is told stands at a rule, where the platform has no word of
    /// its own for one. HTML makes `hr` a break between the paragraphs it parts and gives it
    /// the separator role. The reader says so in its own word, which is not the book's: a rule
    /// keeps an empty text equivalent, and selections, copies and search read nothing for it.
    static let spokenName = "Separator"

    #if os(macOS)
    /// Makes `element` what a rule is to an assistive technology on Mac: the reader's word, as
    /// text. AppKit has no role for a break in content. The one WebKit gives an `hr`, the
    /// splitter, is the bar of a split view to VoiceOver, which says "horizontal splitter
    /// collapsed on top" at it, and "horizontal separator" before the same state when the
    /// element has WebKit's role description.
    static func makeSeparator(_ element: NSAccessibilityElement) {
        element.setAccessibilityRole(.staticText)
        element.setAccessibilityValue(spokenName)
        element.setAccessibilityLabel(nil)
        element.setAccessibilityHelp(nil)
        element.setAccessibilityChildren(nil)
    }
    #endif

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
