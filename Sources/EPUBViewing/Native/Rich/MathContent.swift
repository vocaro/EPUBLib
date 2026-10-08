import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// SKELETON: the math workstream replaces this with the MathMLLayout-backed attachment.
/// Renders a `<math>` element for the rich-content factory: an attachment laid out by
/// `MathMLLayout`, else its `alttext` (counted in `report.mathFallbacks`).
enum MathContent {
    static func make(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        guard let alt = element.attribute("alttext"), !alt.isEmpty else { return nil }
        context.report.report.mathFallbacks += 1
        return NSAttributedString(string: alt, attributes: [.font: context.fonts.font(for: style)])
    }
}
