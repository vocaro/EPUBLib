import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Authored constraints for a CSS float, positioned callout or sized inline box.
/// The native visual plan consumes these; oversized or complex boxes use the in-flow widths.
struct ReaderFlowBoxConstraint: Sendable {
    let id = UUID()
    let style: ComputedStyle
    let containing: ReaderBoxScope?
    let replaced: Bool
    let width: ComputedStyle.Length
    let minimum: ComputedStyle.Length
    let maximum: ComputedStyle.Length
    let side: ComputedStyle.Float
    let centers: Bool
    let direction: ComputedStyle.Direction

    init(style: ComputedStyle, containing: ReaderBoxScope? = nil, replaced: Bool = false) {
        self.style = style; self.containing = containing; self.replaced = replaced
        width = style.width; minimum = style.minWidth; maximum = style.maxWidth
        side = style.float
        centers = style.float == .none && style.margin.left == .auto && style.margin.right == .auto
        direction = style.direction
    }
}

final class ReaderBoxScope: @unchecked Sendable {
    let id = UUID()
    let style: ComputedStyle
    let sectionRoot: UUID
    let parent: ReaderBoxScope?
    let left: CGFloat
    let right: CGFloat
    init(style: ComputedStyle, left: CGFloat = 0, right: CGFloat = 0, parent: ReaderBoxScope? = nil) {
        self.style = style; self.left = left; self.right = right
        self.parent = parent
        self.sectionRoot = parent?.sectionRoot ?? id
    }
}

final class ReaderParagraphFlow: NSObject, @unchecked Sendable {
    let style: ComputedStyle
    let scope: ReaderBoxScope
    init(style: ComputedStyle, scope: ReaderBoxScope) { self.style = style; self.scope = scope }
}

/// The original paragraph formatting is retained so scroll resizing never compounds insets.
final class ReaderFlowBoxParagraph: NSObject, @unchecked Sendable {
    let constraints: [ReaderFlowBoxConstraint]
    let base: NSParagraphStyle
    init(constraints: [ReaderFlowBoxConstraint], base: NSParagraphStyle) {
        self.constraints = constraints; self.base = base
    }
}

extension NSAttributedString.Key {
    static let readerFlowBox = NSAttributedString.Key("org.epublib.flowBox")
    static let readerParagraphFlow = NSAttributedString.Key("org.epublib.paragraphFlow")
    static let readerBoxPage = NSAttributedString.Key("org.epublib.boxPage")
}

/// Reversible width resolution, also used by the ordinary-text continuation fallback.
enum ReaderFlowBoxLayout {
    static func applying(to text: NSAttributedString, viewport: CGSize) -> NSAttributedString {
        guard text.length > 0 else { return text }
        var found = false
        text.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        guard found else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        apply(to: result, viewport: viewport)
        return result
    }

    static func apply(to text: NSMutableAttributedString, viewport: CGSize) {
        guard viewport.width.isFinite, viewport.width > 0, text.length > 0 else { return }
        var changes: [(NSRange, NSParagraphStyle)] = []
        text.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let box = value as? ReaderFlowBoxParagraph else { return }
            let style = box.base.mutableCopy() as! NSMutableParagraphStyle
            let rtl = style.baseWritingDirection == .rightToLeft
            var left = max(0, rtl ? -style.tailIndent : style.headIndent)
            var right = max(0, rtl ? style.headIndent : -style.tailIndent)
            // Deep author indentation cannot leave a phone column without a readable text area.
            let edgeLimit = viewport.width * 2 / 3
            if left + right > edgeLimit {
                let scale = edgeLimit / (left + right)
                left *= scale; right *= scale
            }
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
            let readableWidth = min(viewport.width, max(viewport.width / 3, (font?.pointSize ?? 16) * 4))
            for constraint in box.constraints {
                if constraint.replaced { continue }
                let available = max(1, viewport.width - left - right)
                func resolve(_ length: ComputedStyle.Length) -> CGFloat? {
                    guard let value = length.resolve(reference: available, viewport: viewport), value.isFinite else { return nil }
                    return max(0, value)
                }
                var width = resolve(constraint.width) ?? available
                if let maximum = resolve(constraint.maximum) { width = min(width, maximum) }
                if let minimum = resolve(constraint.minimum) { width = max(width, minimum) }
                width = min(available, max(min(readableWidth, available), width))
                let remainder = available - width
                if constraint.centers {
                    left += remainder / 2; right += remainder / 2
                } else if constraint.side == .right || (constraint.side == .none && constraint.direction == .rtl) {
                    left += remainder
                } else { right += remainder }
            }
            let originalHead = style.headIndent
            style.headIndent = rtl ? right : left
            style.tailIndent = -(rtl ? left : right)
            style.firstLineHeadIndent = max(style.headIndent, style.headIndent + style.firstLineHeadIndent - originalHead)
            changes.append((range, style))
        }
        text.beginEditing()
        for (range, style) in changes { text.addAttribute(.paragraphStyle, value: style, range: range) }
        text.endEditing()
    }
}
