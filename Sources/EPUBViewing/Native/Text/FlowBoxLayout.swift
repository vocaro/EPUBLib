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
    /// A sized inline box's place on its line; nil for a float or a positioned box.
    let inline: ReaderInlineBox?

    init(style: ComputedStyle, containing: ReaderBoxScope? = nil, replaced: Bool = false, inline: ReaderInlineBox? = nil) {
        self.style = style; self.containing = containing; self.replaced = replaced; self.inline = inline
        width = style.width; minimum = style.minWidth; maximum = style.maxWidth
        side = style.float
        centers = style.float == .none && style.margin.left == .auto && style.margin.right == .auto
        direction = style.direction
    }
}

/// Where a sized inline box was written on its block's line. Each box is a paragraph of its
/// own in the text, so the line it shares with the text and the boxes around it exists only
/// here: the visual plan sets a run of them side by side and wraps the run like words.
final class ReaderInlineBox: @unchecked Sendable {
    /// The block whose line the box is on. That block's own paragraphs carry the same object
    /// (`.readerParagraphFlow`), which is how text before and after the box is told from the
    /// next block's.
    let block: ReaderParagraphFlow
    /// The block sets its lines from the right.
    let rightToLeft: Bool
    /// Text or another box precedes it on the line, with no forced break between.
    let continuesLine: Bool
    /// What it keeps from the text or box before it: a collapsed white space, or nothing.
    let leadingSpace: CGFloat
    /// The block's `text-indent`, when the box opens the block's first line.
    let firstLineIndent: CGFloat
    /// What the text or box after it keeps from it. Written once, when the white space is met.
    var trailingSpace: CGFloat = 0

    init(block: ReaderParagraphFlow, rightToLeft: Bool, continuesLine: Bool, leadingSpace: CGFloat, firstLineIndent: CGFloat) {
        self.block = block; self.rightToLeft = rightToLeft; self.continuesLine = continuesLine
        self.leadingSpace = leadingSpace; self.firstLineIndent = firstLineIndent
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
    /// A `ComputedStyle.Clear` on the first character of a line that starts below the earlier
    /// floats of the sides it names: of a paragraph opening blocks that set `clear` (with the
    /// box it begins and the flow after it), or of the line after a `br` that sets it.
    static let readerClear = NSAttributedString.Key("org.epublib.clear")
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

    /// What a box paragraph's own formatting keeps clear at each side of the column, before
    /// any width constraint narrows it: its content may run from the one to the other.
    static func insets(of base: NSParagraphStyle, viewport: CGSize) -> (left: CGFloat, right: CGFloat) {
        let rtl = base.baseWritingDirection == .rightToLeft
        var left = max(0, rtl ? -base.tailIndent : base.headIndent)
        var right = max(0, rtl ? base.headIndent : -base.tailIndent)
        // Deep author indentation cannot leave a phone column without a readable text area.
        let edgeLimit = viewport.width * 2 / 3
        if left + right > edgeLimit {
            let scale = edgeLimit / (left + right)
            left *= scale; right *= scale
        }
        return (left, right)
    }

    /// The same for the box paragraph at `location` of `text`, at its live size.
    static func insets(at location: Int, in text: NSAttributedString, viewport: CGSize) -> (left: CGFloat, right: CGFloat)? {
        guard let box = text.attribute(.readerFlowBox, at: location, effectiveRange: nil) as? ReaderFlowBoxParagraph else { return nil }
        let base = (text.attribute(.readerParagraphSizing, at: location, effectiveRange: nil) as? ReaderParagraphSizing)
            .map { $0.resolve(viewport: viewport) } ?? box.base
        return insets(of: base, viewport: viewport)
    }

    static func apply(to text: NSMutableAttributedString, viewport: CGSize) {
        guard viewport.width.isFinite, viewport.width > 0, text.length > 0 else { return }
        var changes: [(NSRange, NSParagraphStyle)] = []
        text.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let box = value as? ReaderFlowBoxParagraph else { return }
            let base = (text.attribute(.readerParagraphSizing, at: range.location, effectiveRange: nil) as? ReaderParagraphSizing)
                .map { $0.resolve(viewport: viewport) } ?? box.base
            let style = base.mutableCopy() as! NSMutableParagraphStyle
            let rtl = style.baseWritingDirection == .rightToLeft
            var (left, right) = insets(of: base, viewport: viewport)
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
