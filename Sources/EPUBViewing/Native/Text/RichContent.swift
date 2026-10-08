import EPUBCore
import EPUBReading
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Mutable report shared by the builder and the rich-content factory during one section build.
final class SectionReportBox {
    var report = SectionReport()
}

/// What a rich-content factory may use from the section being built. Valid only during the build.
struct RichContentContext {
    let publication: EPUBPublication
    let document: ContentDocument
    let spineIndex: Int
    let typography: NativeTypography
    let fonts: FontRegistry
    /// The computed style of an element, given its parent's computed style.
    let style: (_ element: ContentNode, _ parent: ComputedStyle) -> ComputedStyle
    /// Renders an element's children as the builder renders a block's content (inline
    /// formatting, nested blocks, links), for table cells and captions. The result has no
    /// trailing paragraph break, and its characters are not in the section's text map.
    let renderContent: (_ element: ContentNode, _ style: ComputedStyle) -> NSAttributedString
    /// Resolves a local reference (`src`, `href`, `xlink:href`, `data`) against the section to a
    /// decoded archive path. Anything outside the archive returns nil and counts as refused.
    let resolve: (_ reference: String) -> String?
    let report: SectionReportBox
}

/// Builds the attributed text for content the paragraph model cannot express directly: images,
/// SVG, tables, MathML and rules. Each method returns the text to insert at the element's place,
/// or nil to fall back to the element's own content. The builder maps every returned character
/// to the element as a unit. For block-level elements the builder gives the result its own
/// paragraph(s) and the element's margins; a result must not begin or end with a paragraph break.
protocol RichContentFactory: Sendable {
    /// `<img>`, `<image>` (SVG), and `<object>`/`<embed>` whose data is an image.
    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString?
    /// An `<svg>` element: an image it wraps, else the drawing itself when it can be shown.
    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString?
    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString?
    /// A `<math>` element (inline or `display="block"`).
    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString?
    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString
}

// SKELETON: placeholder content until the rich-content workstream lands.
struct PlaceholderRichContent: RichContentFactory {
    private func text(_ value: String, _ style: ComputedStyle, _ context: RichContentContext) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [.font: context.fonts.font(for: style),
                                                       .foregroundColor: ReaderPalette.text(dark: context.typography.isDark)])
    }
    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        text("[\(element.attribute("alt") ?? "image")]", style, context)
    }
    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        element.attribute("alttext").map { text($0, style, context) }
    }
    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        text("—", style, context)
    }
}
