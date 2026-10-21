import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A shared chain of ordinary block edges. Percentages use each parent's content width,
/// rather than the eventual line width or the width used to build the immutable section.
final class ReaderParagraphEdges: @unchecked Sendable {
    let parent: ReaderParagraphEdges?
    let style: ComputedStyle
    let isDynamic: Bool

    init(style: ComputedStyle, parent: ReaderParagraphEdges?) {
        self.style = style; self.parent = parent
        isDynamic = parent?.isDynamic == true || [style.margin.left, style.margin.right,
            style.padding.left, style.padding.right, style.textIndent].contains(where: Self.dynamic)
            || (style.margin.left == .auto && style.margin.right == .auto
                && (Self.dynamic(style.width) || Self.dynamic(style.maxWidth)))
            || (style.requiresFlowBox && [style.width, style.minWidth, style.maxWidth].contains(where: Self.dynamic))
    }

    static func dynamic(_ length: ComputedStyle.Length) -> Bool {
        switch length {
        case .points, .auto: false
        default: true
        }
    }

    func geometry(viewport: CGSize) -> (left: CGFloat, right: CGFloat, content: CGFloat) {
        guard let parent else { return (0, 0, viewport.width) }
        let outer = parent.geometry(viewport: viewport)
        var left = Self.resolve(style.margin.left, reference: outer.content, viewport: viewport)
        var right = Self.resolve(style.margin.right, reference: outer.content, viewport: viewport)
        if style.margin.left == .auto, style.margin.right == .auto, !style.requiresFlowBox {
            let width: CGFloat? = switch (style.width, style.maxWidth) {
            case (.percent(let value), _), (.auto, .percent(let value)): value
            default: nil
            }
            if let width, width > 0, width < 100 { left = outer.content * (100 - width) / 200; right = left }
        }
        left += Self.resolve(style.padding.left, reference: outer.content, viewport: viewport) + Self.border(style.border.left)
        right += Self.resolve(style.padding.right, reference: outer.content, viewport: viewport) + Self.border(style.border.right)
        let available = max(1, outer.content - left - right)
        var content = available
        if style.requiresFlowBox {
            // The in-flow fallback applies these width constraints after ordinary edges.
            // Keep those offsets out of left/right here so that layout does not apply them
            // twice, but descendants' percentages must use the resulting content width.
            func dimension(_ length: ComputedStyle.Length) -> CGFloat? {
                guard let value = length.resolve(reference: available, viewport: viewport), value.isFinite else { return nil }
                return max(0, value)
            }
            content = dimension(style.width) ?? available
            if let maximum = dimension(style.maxWidth) { content = min(content, maximum) }
            if let minimum = dimension(style.minWidth) { content = max(content, minimum) }
            let readableWidth = min(viewport.width, max(viewport.width / 3, style.fontSize * 4))
            content = min(available, max(min(readableWidth, available), content))
        }
        return (outer.left + left, outer.right + right, content)
    }

    /// How far the lines of this block's paragraphs keep from the column's left and right edges
    /// at `viewport`: its content edges, which a float or sized inline box in the block is placed
    /// and sized against (CSS 2.2 10.1). Edges that depend on the viewport are resolved at its
    /// size (`ReaderParagraphSizing`), others as written (`SectionWriter`); where the two edges
    /// together pass the limit of that resolution, both are cut in proportion.
    func lineInsets(viewport: CGSize) -> (left: CGFloat, right: CGFloat) {
        let geometry = geometry(viewport: viewport)
        return Self.limit(left: geometry.left, right: geometry.right,
                          to: isDynamic ? viewport.width / 3 : Self.writtenIndentLimit)
    }

    /// The most a paragraph's two indents take together as written, at the nominal column.
    static let writtenIndentLimit: CGFloat = 200

    /// `left` and `right`, at least zero, cut in proportion where together they pass `limit`.
    static func limit(left: CGFloat, right: CGFloat, to limit: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let left = max(0, left), right = max(0, right)
        guard left + right > limit else { return (left, right) }
        let scale = limit / (left + right)
        return (left * scale, right * scale)
    }

    static func border(_ border: ComputedStyle.Border) -> CGFloat {
        border.isVisible && border.width.isFinite ? min(border.width, 100) : 0
    }

    static func resolve(_ length: ComputedStyle.Length, reference: CGFloat, viewport: CGSize) -> CGFloat {
        guard let value = length.resolve(reference: reference, viewport: viewport), value.isFinite else { return 0 }
        return min(max(value, -600), 600)
    }
}

/// CSS adjoining-margin collapse with symbolic operands, retained only for resize-sensitive
/// paragraphs. Vertical percentage margins and padding also refer to the containing width.
struct ReaderParagraphGap: Sendable {
    struct Operand: Sendable {
        let length: ComputedStyle.Length
        let containing: ReaderParagraphEdges?
        let border: CGFloat
        let seals: Bool
        /// Seals with nothing between: the margins either side do not adjoin (`separate()`).
        var isBoundary = false
    }
    var operands: [Operand] = []
    var isDynamic: Bool { operands.contains { ReaderParagraphEdges.dynamic($0.length) || $0.containing?.isDynamic == true } }
    mutating func add(_ length: ComputedStyle.Length, containing: ReaderParagraphEdges?) {
        guard length != .zero && length != .auto else { return }
        operands.append(Operand(length: length, containing: containing, border: 0, seals: false))
    }
    mutating func seal(_ length: ComputedStyle.Length, border: CGFloat, containing: ReaderParagraphEdges?) {
        if length != .zero || border > 0 {
            operands.append(Operand(length: length, containing: containing, border: border, seals: true))
        }
    }
    /// The margins so far are fixed, as padding fixes them, with no padding: a flex or grid
    /// item's margins collapse with nothing (`ReaderAlignmentFrame.isItem`).
    mutating func separate() {
        guard operands.last?.isBoundary != true else { return }
        operands.append(Operand(length: .zero, containing: nil, border: 0, seals: true, isBoundary: true))
    }
    func resolve(viewport: CGSize) -> CGFloat {
        var fixed: CGFloat = 0, positive: CGFloat = 0, negative: CGFloat = 0
        for operand in operands {
            let reference = operand.containing?.geometry(viewport: viewport).content ?? viewport.width
            let value = ReaderParagraphEdges.resolve(operand.length, reference: reference, viewport: viewport) + operand.border
            if operand.seals {
                if value > 0 || operand.isBoundary { fixed += positive + negative + max(0, value); positive = 0; negative = 0 }
            } else if value > 0 { positive = max(positive, value) } else { negative = min(negative, value) }
        }
        return min(600, max(0, fixed + positive + negative))
    }
}

/// Original formatting plus authored dimensions. Resolution changes attributes alone and
/// always starts from the source, so resizing never compounds insets or changes DOM offsets.
final class ReaderParagraphSizing: NSObject, @unchecked Sendable {
    let base: NSParagraphStyle
    let edges: ReaderParagraphEdges
    let firstLine: Bool
    let markerWidth: CGFloat?
    let before: ReaderParagraphGap?
    let after: ReaderParagraphGap?
    let nominalLeft: CGFloat
    let nominalRight: CGFloat
    let nominalIndent: CGFloat

    init(base: NSParagraphStyle, edges: ReaderParagraphEdges, firstLine: Bool, markerWidth: CGFloat?,
         before: ReaderParagraphGap?, after: ReaderParagraphGap?, nominalLeft: CGFloat,
         nominalRight: CGFloat, nominalIndent: CGFloat) {
        self.base = base; self.edges = edges; self.firstLine = firstLine; self.markerWidth = markerWidth
        self.before = before; self.after = after; self.nominalLeft = nominalLeft
        self.nominalRight = nominalRight; self.nominalIndent = nominalIndent
    }

    func resolve(viewport: CGSize) -> NSParagraphStyle {
        let style = base.mutableCopy() as! NSMutableParagraphStyle
        let rtl = style.baseWritingDirection == .rightToLeft
        let (left, right) = edges.lineInsets(viewport: viewport)
        let (oldLeft, oldRight) = ReaderParagraphEdges.limit(left: nominalLeft, right: nominalRight,
                                                             to: ReaderParagraphEdges.writtenIndentLimit)
        let oldHead = rtl ? oldRight : oldLeft, head = rtl ? right : left
        let tail = rtl ? left : right, oldTail = rtl ? oldLeft : oldRight
        style.headIndent += head - oldHead
        if style.tailIndent <= 0 { style.tailIndent -= tail - oldTail }
        let indent = firstLine ? ReaderParagraphEdges.resolve(edges.style.textIndent,
            reference: edges.parent?.geometry(viewport: viewport).content ?? viewport.width, viewport: viewport) : 0
        style.firstLineHeadIndent += max(0, head + indent) - max(0, oldHead + (firstLine ? nominalIndent : 0))
        if let width = markerWidth {
            style.headIndent = max(head, width)
            style.firstLineHeadIndent = max(0, head - width)
            style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent, options: [:])]
        }
        if let before { style.paragraphSpacingBefore = before.resolve(viewport: viewport) }
        if let after { style.paragraphSpacing = after.resolve(viewport: viewport) }
        return style
    }
}

extension NSAttributedString.Key {
    static let readerParagraphSizing = NSAttributedString.Key("org.epublib.paragraphSizing")
}

enum ReaderParagraphSizingLayout {
    static func applying(to text: NSAttributedString, viewport: CGSize) -> NSAttributedString {
        guard text.length > 0, viewport.width.isFinite, viewport.width > 0 else { return text }
        var changes: [(NSRange, NSParagraphStyle)] = []
        text.enumerateAttribute(.readerParagraphSizing, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let sizing = value as? ReaderParagraphSizing { changes.append((range, sizing.resolve(viewport: viewport))) }
        }
        guard !changes.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for (range, style) in changes { result.addAttribute(.paragraphStyle, value: style, range: range) }
        return result
    }
}
