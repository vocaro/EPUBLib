import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Source-order text with a separate visual plan. Boxes never become opaque text attachments:
/// native character selection, links, rendering attributes and DOM offsets stay intact.
final class ReaderBoxGeometry: NSObject {
    struct Region {
        var range: NSRange
        var frame: CGRect
        var side: ComputedStyle.Float
        var reserved = false
        var wrapsEarlierText = false
        var scope: UUID? = nil
        /// Glyph column inside the float's margins and padding.
        var contentFrame: CGRect? = nil
    }
    struct Paragraph {
        var range: NSRange
        var topAdjustment: CGFloat = 0
        var bottomAdjustment: CGFloat = 0
        var flowStart: CGFloat
        var flowEnd: CGFloat
        var lines: [(range: NSRange, frame: CGRect)]
        var isBox = false
        var column: CGRect? = nil
        var scope: UUID? = nil
    }
    var paragraphs: [Paragraph] = []
    var regions: [Region] = []
    /// Indivisible source ranges through the last line wrapping beside a box.
    var groups: [NSRange] = []
    private var groupBounds: [NSRange: CGRect] = [:]

    func group(containing offset: Int) -> NSRange? {
        var low = 0, high = groups.count
        while low < high {
            let mid = (low + high) / 2
            if groups[mid].upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low < groups.count && NSLocationInRange(offset, groups[low]) ? groups[low] : nil
    }

    func bounds(of group: NSRange) -> CGRect {
        if let cached = groupBounds[group] { return cached }
        var bounds = lineBounds(of: group)
        for region in regions where NSIntersectionRange(region.range, group).length > 0 { bounds = bounds.union(region.frame) }
        return bounds
    }

    private func lineBounds(of group: NSRange) -> CGRect {
        var bounds = CGRect.null
        var paragraphIndex = firstParagraph(endingAfter: group.location)
        while paragraphIndex < paragraphs.count, paragraphs[paragraphIndex].range.location < group.upperBound {
            let lines = paragraphs[paragraphIndex].lines
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid].range.upperBound <= group.location { low = mid + 1 } else { high = mid }
            }
            while low < lines.count, lines[low].range.location < group.upperBound {
                if NSIntersectionRange(lines[low].range, group).length > 0 { bounds = bounds.union(lines[low].frame) }
                low += 1
            }
            paragraphIndex += 1
        }
        return bounds
    }

    private func firstParagraph(endingAfter offset: Int) -> Int {
        var low = 0, high = paragraphs.count
        while low < high {
            let mid = (low + high) / 2
            if paragraphs[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func paragraph(at offset: Int) -> Paragraph? {
        let index = firstParagraph(endingAfter: offset)
        return index < paragraphs.count ? paragraphs[index] : nil
    }

    /// Build once; page construction repeatedly asks for the same indivisible groups.
    func formGroups() {
        groups.removeAll(keepingCapacity: true)
        groupBounds.removeAll(keepingCapacity: true)
        guard regions.contains(where: { !$0.reserved }) else { return }
        let index = GroupLineIndex(paragraphs.flatMap(\.lines))
        let candidates = regions.filter { !$0.reserved }.map { region -> NSRange in
            guard let wrapped = index.range(overlapping: region.frame) else { return region.range }
            return NSUnionRange(region.range, wrapped)
        }.sorted { $0.location < $1.location }
        for candidate in candidates {
            if let last = groups.last, last.upperBound >= candidate.location {
                groups[groups.count - 1] = NSUnionRange(last, candidate)
            } else { groups.append(candidate) }
        }
        for group in groups { groupBounds[group] = lineBounds(of: group) }
        // Reserved inline prefixes also affect visual bounds. Assign each region directly to
        // its intersecting groups instead of rescanning every region for every page.
        for region in regions {
            var low = 0, high = groups.count
            while low < high {
                let mid = (low + high) / 2
                if groups[mid].upperBound <= region.range.location { low = mid + 1 } else { high = mid }
            }
            while low < groups.count, groups[low].location < region.range.upperBound {
                if NSIntersectionRange(groups[low], region.range).length > 0 {
                    groupBounds[groups[low]] = (groupBounds[groups[low]] ?? .null).union(region.frame)
                }
                low += 1
            }
        }
    }

    /// Visual lines can run backwards in source order around positioned boxes. A spatial
    /// interval index avoids walking the entire section for each box while preserving that order.
    private struct GroupLineIndex {
        struct Node {
            var minimumEnd: CGFloat = .greatestFiniteMagnitude
            var maximumEnd: CGFloat = -.greatestFiniteMagnitude
            var source: NSRange = NSRange(location: 0, length: 0)
        }
        let lines: [(range: NSRange, frame: CGRect)]
        var nodes: [Node]

        init(_ lines: [(range: NSRange, frame: CGRect)]) {
            self.lines = lines.sorted { $0.frame.minY < $1.frame.minY }
            nodes = Array(repeating: Node(), count: max(1, lines.count * 4))
            if !lines.isEmpty { build(node: 0, start: 0, end: lines.count) }
        }

        private mutating func build(node: Int, start: Int, end: Int) {
            if end - start == 1 {
                nodes[node] = Node(minimumEnd: lines[start].frame.maxY,
                                   maximumEnd: lines[start].frame.maxY, source: lines[start].range)
                return
            }
            let middle = (start + end) / 2, left = node * 2 + 1, right = left + 1
            build(node: left, start: start, end: middle)
            build(node: right, start: middle, end: end)
            nodes[node] = Node(minimumEnd: min(nodes[left].minimumEnd, nodes[right].minimumEnd),
                               maximumEnd: max(nodes[left].maximumEnd, nodes[right].maximumEnd),
                               source: NSUnionRange(nodes[left].source, nodes[right].source))
        }

        func range(overlapping frame: CGRect) -> NSRange? {
            guard !lines.isEmpty else { return nil }
            return range(overlapping: frame, node: 0, start: 0, end: lines.count)
        }

        private func range(overlapping frame: CGRect, node: Int, start: Int, end: Int) -> NSRange? {
            guard nodes[node].maximumEnd > frame.minY, lines[start].frame.minY < frame.maxY else { return nil }
            if nodes[node].minimumEnd > frame.minY, lines[end - 1].frame.minY < frame.maxY { return nodes[node].source }
            guard end - start > 1 else { return nil }
            let middle = (start + end) / 2
            let left = range(overlapping: frame, node: node * 2 + 1, start: start, end: middle)
            let right = range(overlapping: frame, node: node * 2 + 2, start: middle, end: end)
            if let left, let right { return NSUnionRange(left, right) }
            return left ?? right
        }
    }
}

final class ReaderBoxPage: NSObject {
    let geometry: ReaderBoxGeometry
    let offset: Int
    let origin: CGFloat
    let beginsTableContinuation: Bool
    init(geometry: ReaderBoxGeometry, offset: Int = 0, origin: CGFloat = 0, beginsTableContinuation: Bool = false) {
        self.geometry = geometry; self.offset = offset; self.origin = origin
        self.beginsTableContinuation = beginsTableContinuation
    }
}

enum ReaderBoxLayout {
    struct Result { let text: NSAttributedString; let geometry: ReaderBoxGeometry? }

    static func resolve(_ source: NSAttributedString, viewport: CGSize) -> Result {
        let sized = ReaderParagraphSizingLayout.applying(to: source, viewport: viewport)
        return resolve(ReaderAlignmentLayout.applying(to: sized, viewport: viewport), viewport: viewport,
                       disabled: [], pass: 0, anticipated: [])
    }

    private static func resolve(_ source: NSAttributedString, viewport: CGSize, disabled: Set<UUID>, pass: Int,
                                anticipated: [ReaderBoxGeometry.Region]) -> Result {
        guard source.length > 0 else { return Result(text: source, geometry: nil) }
        var hasBoxes = false
        source.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: source.length)) { value, _, stop in
            if value != nil { hasBoxes = true; stop.pointee = true }
        }
        if !hasBoxes {
            source.enumerateAttribute(.readerParagraphFlow, in: NSRange(location: 0, length: source.length)) { value, _, stop in
                if (value as? ReaderParagraphFlow)?.scope.style.position == .relative { hasBoxes = true; stop.pointee = true }
            }
        }
        guard hasBoxes else { return Result(text: source, geometry: nil) }
        let text = NSMutableAttributedString(attributedString: ReaderFlowBoxLayout.applying(to: source, viewport: viewport))
        guard viewport.width > 0, viewport.height > 0 else { return Result(text: text, geometry: nil) }
        let plan = ReaderBoxGeometry()
        let characters = text.string as NSString
        var ranges: [NSRange] = []
        var offset = 0
        while offset < text.length {
            let range = characters.paragraphRange(for: NSRange(location: offset, length: 0))
            ranges.append(range); offset = range.upperBound
        }
        var cursor: CGFloat = 0
        var scopeOrigins: [UUID: CGFloat] = [:]
        var sectionOrigins: [UUID: CGFloat] = [:]
        let disabledRanges = disabledBoxRanges(text, disabled: disabled)
        var lastConstraint = 0
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, run, _ in
            if attributes[.readerFlowBox] != nil
                || (attributes[.readerParagraphFlow] as? ReaderParagraphFlow)?.scope.style.position == .relative {
                lastConstraint = max(lastConstraint, run.upperBound)
            }
        }
        var index = 0
        func scopeFrame(_ scope: ReaderBoxScope?) -> CGRect {
            guard let scope else { return CGRect(origin: .zero, size: viewport) }
            var left = max(0, min(scope.left, viewport.width / 3))
            let right = max(0, min(scope.right, viewport.width / 3))
            let available = max(1, viewport.width - left - right)
            var width = scope.style.width.resolve(reference: available, viewport: viewport) ?? available
            if let minimum = scope.style.minWidth.resolve(reference: available, viewport: viewport) { width = max(width, minimum) }
            if let maximum = scope.style.maxWidth.resolve(reference: available, viewport: viewport) { width = min(width, maximum) }
            width = min(available, max(1, width))
            if scope.style.margin.left == .auto && scope.style.margin.right == .auto { left += (available - width) / 2 }
            if scope.style.position == .relative {
                left += scope.style.positionLeft.resolve(reference: available, viewport: viewport)
                    ?? -(scope.style.positionRight.resolve(reference: available, viewport: viewport) ?? 0)
            }
            left = min(max(0, left), viewport.width - width)
            return CGRect(x: left, y: 0, width: width, height: viewport.height)
        }
        while index < ranges.count {
            let range = ranges[index]
            let flow = text.attribute(.readerParagraphFlow, at: range.location, effectiveRange: nil) as? ReaderParagraphFlow
            let beforeScope = cursor
            if let root = flow?.scope.sectionRoot, sectionOrigins[root] == nil { sectionOrigins[root] = cursor }
            func enterScope(_ scope: ReaderBoxScope) {
                guard scopeOrigins[scope.id] == nil else { return }
                if let parent = scope.parent { enterScope(parent) }
                if scope.style.position == .relative {
                    let top = scope.style.positionTop.resolve(reference: viewport.height, viewport: viewport)
                        ?? -(scope.style.positionBottom.resolve(reference: viewport.height, viewport: viewport) ?? 0)
                    cursor += max(0, top)
                }
                scopeOrigins[scope.id] = cursor
            }
            if let scope = flow?.scope { enterScope(scope) }
            let box = (text.attribute(.readerFlowBox, at: range.location, effectiveRange: nil) as? ReaderFlowBoxParagraph)?.constraints.first
            if let box {
                var end = index + 1
                while end < ranges.count,
                      (text.attribute(.readerFlowBox, at: ranges[end].location, effectiveRange: nil) as? ReaderFlowBoxParagraph)?.constraints.first?.id == box.id { end += 1 }
                let boxRange = NSRange(location: range.location, length: ranges[end - 1].upperBound - range.location)
                let originalBox = text.attributedSubstring(from: boxRange)
                let style = box.style
                // Table cells and nested complex formatting retain their existing no-loss flow.
                let nested = (text.attribute(.readerFlowBox, at: range.location, effectiveRange: nil) as? ReaderFlowBoxParagraph)?.constraints.count ?? 0
                let isInline = style.display == .inlineBlock && style.float == .none && !style.isOutOfFlow
                if !disabled.contains(box.id), nested == 1, style.float != .none || style.isOutOfFlow || isInline {
                    var x: CGFloat
                    var width: CGFloat
                    var edgeLeft: CGFloat = 0, edgeRight: CGFloat = 0
                    let paragraphStyle = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
                    let rtl = paragraphStyle.baseWritingDirection == .rightToLeft
                    x = max(0, rtl ? -paragraphStyle.tailIndent : paragraphStyle.headIndent)
                    width = max(1, viewport.width - x - max(0, rtl ? paragraphStyle.headIndent : -paragraphStyle.tailIndent))
                    let containing = scopeFrame(box.containing)
                    if style.float != .none || !box.replaced && !style.isOutOfFlow {
                        func edge(_ value: ComputedStyle.Length) -> CGFloat {
                            max(0, min(containing.width / 3, value.resolve(reference: containing.width, viewport: viewport) ?? 0))
                        }
                        if style.float != .none {
                            edgeLeft = edge(style.margin.left) + edge(style.padding.left) + (style.border.left.isVisible ? style.border.left.width : 0)
                            edgeRight = edge(style.margin.right) + edge(style.padding.right) + (style.border.right.isVisible ? style.border.right.width : 0)
                        }
                        let available = max(1, containing.width - edgeLeft - edgeRight)
                        if !box.replaced {
                            width = style.width.resolve(reference: containing.width, viewport: viewport)
                                ?? min(available, max(1, TableMeasure.maximumWidth(text.attributedSubstring(from: boxRange))))
                            if let minimum = style.minWidth.resolve(reference: containing.width, viewport: viewport) { width = max(width, minimum) }
                            if let maximum = style.maxWidth.resolve(reference: containing.width, viewport: viewport) { width = min(width, maximum) }
                            width = min(available, max(1, width))
                        }
                        if style.float == .right { x = containing.maxX - edgeRight - width }
                        else if style.float == .left { x = containing.minX + edgeLeft }
                    }
                    if box.replaced, boxRange.length > 0,
                       let image = text.attribute(.attachment, at: boxRange.location, effectiveRange: nil) as? ReaderImageAttachment {
                        let size = image.sizing.size(lineWidth: max(1, containing.width - edgeLeft - edgeRight), viewport: viewport, heightLimit: viewport.height)
                        width = size.width
                        x = style.float == .right ? containing.maxX - edgeRight - width : containing.minX + edgeLeft
                        var sizing = ImageSizing(intrinsic: image.sizing.intrinsic)
                        sizing.width = .points(size.width); sizing.height = .points(size.height)
                        var imageStyle = style; imageStyle.display = .block
                        let resolved = ReaderImageAttachment(source: image.source, sizing: sizing, alt: image.alt,
                            style: imageStyle, contentRect: image.contentRect, isDark: image.isDark, cache: image.cache)
                        text.addAttribute(.attachment, value: resolved, range: NSRange(location: boxRange.location, length: 1))
                    }
                    func resolve(_ value: ComputedStyle.Length, _ reference: CGFloat) -> CGFloat? {
                        value.resolve(reference: reference, viewport: viewport).flatMap { $0.isFinite ? $0 : nil }
                    }
                    if style.isOutOfFlow {
                        let containing = style.position == .fixed ? CGRect(origin: .zero, size: viewport) : scopeFrame(box.containing)
                        width = resolve(style.width, containing.width) ?? min(width, containing.width)
                        if let minimum = resolve(style.minWidth, containing.width) { width = max(width, minimum) }
                        if let maximum = resolve(style.maxWidth, containing.width) { width = min(width, maximum) }
                        width = min(containing.width, max(1, width))
                        if let left = resolve(style.positionLeft, containing.width) { x = containing.minX + left }
                        else if let right = resolve(style.positionRight, containing.width) { x = containing.maxX - right - width }
                        else if style.margin.left == .auto && style.margin.right == .auto { x = containing.minX + (containing.width - width) / 2 }
                        else { x = containing.minX }
                        if style.width == .auto, let left = resolve(style.positionLeft, containing.width),
                           let right = resolve(style.positionRight, containing.width) { width = containing.width - left - right }
                    }
                    x = min(max(0, x), max(0, viewport.width - width))
                    width = min(viewport.width - x, max(1, width))
                    setEdges(text, range: boxRange, x: x, width: width, viewport: viewport)
                    var measured = measure(text.attributedSubstring(from: boxRange), viewport: viewport, boxFrame: CGRect(x: x, y: 0, width: width, height: viewport.height))
                    let minimum = max(resolve(style.height, viewport.height) ?? 0, resolve(style.minHeight, viewport.height) ?? 0)
                    let height = max(measured.height, minimum)
                    // Oversized text remains pageable ordinary text; no clipping or opaque raster fallback.
                    if height <= viewport.height - 1 {
                        var y = cursor
                        if style.isOutOfFlow {
                            let origin = style.position == .fixed ? box.containing.flatMap { sectionOrigins[$0.sectionRoot] } ?? 0
                                : box.containing.flatMap { scopeOrigins[$0.id] } ?? 0
                            let referenceHeight = style.position == .fixed ? viewport.height
                                : box.containing.flatMap { resolve($0.style.height, viewport.height) } ?? viewport.height
                            if let top = resolve(style.positionTop, referenceHeight) { y = origin + top }
                            else if let bottom = resolve(style.positionBottom, referenceHeight) { y = origin + referenceHeight - bottom - height }
                            y = max(0, y)
                        } else if isInline, let previous = plan.paragraphs.last?.lines.last {
                            let inlineX = previous.frame.maxX + 4
                            if inlineX + width <= viewport.width {
                                x = inlineX; y = previous.frame.minY
                                setEdges(text, range: boxRange, x: x, width: width, viewport: viewport)
                                measured = measure(text.attributedSubstring(from: boxRange), viewport: viewport, boxFrame: CGRect(x: x, y: 0, width: width, height: viewport.height))
                            }
                        }
                        // Rectangular floats/callouts avoid one another and existing content.
                        var frame = CGRect(x: max(0, x - edgeLeft), y: y,
                            width: min(viewport.width, width + edgeLeft + edgeRight), height: height)
                        // Native line bounds can extend fractionally beyond a box's advance
                        // width. Reserve those bounds for surrounding prose, while retaining the
                        // authored content column so the box does not rewrap at its exclusion width.
                        let ink = measured.paragraphs.flatMap(\.lines).reduce(CGRect.null) { $0.union($1.frame) }
                        if !ink.isNull {
                            let left = min(frame.minX, ink.minX), right = max(frame.maxX, ink.maxX)
                            frame.origin.x = left
                            frame.size.width = right - left
                        }
                        let hasVerticalInset = style.positionTop != .auto || style.positionBottom != .auto
                        let obstacles = style.isOutOfFlow ? (hasVerticalInset ? plan.regions.filter(\.wrapsEarlierText) : plan.regions)
                            : plan.regions + anticipated.filter { candidate in
                                !plan.regions.contains(where: { $0.range == candidate.range })
                            }
                        while let collision = obstacles.first(where: { $0.frame.intersects(frame) }) {
                            frame.origin.y = collision.frame.maxY
                        }
                        // Negative top margins move glyphs but TextKit clamps their flow advance
                        // to zero. Keep that displacement on every paragraph, and cancel only the
                        // measured height plus any positive displacement on the last fragment.
                        let delta = frame.minY - beforeScope
                        let firstRecord = plan.paragraphs.count
                        for entry in measured.paragraphs {
                            let localRange = NSRange(location: boxRange.location + entry.range.location, length: entry.range.length)
                            plan.paragraphs.append(ReaderBoxGeometry.Paragraph(range: localRange,
                                topAdjustment: delta < 0 || entry.range.location == 0 ? delta : 0,
                                flowStart: beforeScope + entry.flowStart + (entry.range.location == 0 ? 0 : max(0, delta)),
                                flowEnd: beforeScope + entry.flowEnd + max(0, delta),
                                lines: entry.lines.map { (NSRange(location: boxRange.location + $0.range.location, length: $0.range.length),
                                    $0.frame.offsetBy(dx: 0, dy: beforeScope + delta)) }, isBox: true))
                        }
                        if firstRecord < plan.paragraphs.count {
                            let last = plan.paragraphs.count - 1
                            let returnedCursor = cursor
                            plan.paragraphs[last].bottomAdjustment = returnedCursor - (beforeScope + measured.height + max(0, delta))
                            plan.paragraphs[last].flowEnd = returnedCursor
                            cursor = returnedCursor
                            if isInline, let prefix = plan.paragraphs.prefix(firstRecord).last?.lines.last,
                               prefix.frame.minY == frame.minY {
                                plan.regions.append(.init(range: prefix.range,
                                    frame: CGRect(x: 0, y: prefix.frame.minY, width: x, height: prefix.frame.height),
                                    side: .none, reserved: true))
                            }
                            plan.regions.append(.init(range: boxRange, frame: frame, side: style.float,
                                wrapsEarlierText: style.isOutOfFlow && (style.positionTop != .auto || style.positionBottom != .auto),
                                scope: box.containing?.id,
                                contentFrame: CGRect(x: x, y: frame.minY, width: width, height: height)))
                            index = end
                            continue
                        }
                    }
                }
                // An attempted box may have replaced widths/images. Restore the resolved
                // in-flow styles before its ordinary continuation fallback (including tables).
                originalBox.enumerateAttributes(in: NSRange(location: 0, length: originalBox.length)) { attributes, run, _ in
                    text.setAttributes(attributes, range: NSRange(location: boxRange.location + run.location, length: run.length))
                }
            }
            let clear = flow?.style.clear ?? .none
            let floor = plan.regions.filter { region in
                region.side != .none && (clear == .both || (clear == .left && region.side == .left) || (clear == .right && region.side == .right))
            }.map(\.frame.maxY).max() ?? cursor
            let table = text.attribute(.attachment, at: range.location, effectiveRange: nil) is TableRowAttachment
            let tableFloor = table ? plan.regions.map(\.frame.maxY).max() ?? cursor : cursor
            let start = max(cursor, floor, tableFloor)
            let column = box.map { scopeFrame($0.containing) } ?? flow.map { scopeFrame($0.scope) }
            let scoped = column.map { $0.minX > 0 || $0.width < viewport.width } ?? false
            if scoped { setEdges(text, range: range, x: column!.minX, width: column!.width, viewport: viewport) }
            // After the last box/relative column, ordinary prose no longer needs a visual
            // preflight once it clears the exclusions. Leave that tail to TextKit's lazy layout.
            let ordinaryTail = range.location >= lastConstraint && !scoped && flow?.scope.style.position != .relative
            let lastBoxBottom = plan.regions.map(\.frame.maxY).max() ?? 0
            if ordinaryTail && start >= lastBoxBottom { break }
            var measurementRange = ordinaryTail && range.length > 8_194
                ? NSRange(location: range.location, length: 8_194) : range
            let predicted = anticipated.filter { candidate in
                candidate.wrapsEarlierText && !plan.regions.contains(where: { $0.range == candidate.range })
                    && !disabledRanges.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 })
                    && candidate.scope == flow?.scope.id
            }
            var measured = measure(text.attributedSubstring(from: measurementRange), viewport: viewport,
                                   regions: plan.regions + predicted, origin: start, sourceOffset: range.location,
                                   column: scoped ? column : nil, scope: flow?.scope.id)
            // Extremely wide columns can fit the initial prefix into too few rows. Extend
            // until it clears the last exclusion before leaving the remaining source lazy.
            while measurementRange.length < range.length, start + measured.height < lastBoxBottom {
                measurementRange.length = min(range.length, measurementRange.length * 2)
                measured = measure(text.attributedSubstring(from: measurementRange), viewport: viewport,
                    regions: plan.regions + predicted, origin: start, sourceOffset: range.location,
                    column: scoped ? column : nil, scope: flow?.scope.id)
            }
            let entry = measured.paragraphs.first
            let lines = entry?.lines.map { (NSRange(location: range.location + $0.range.location, length: $0.range.length),
                                           $0.frame.offsetBy(dx: 0, dy: start)) } ?? []
            plan.paragraphs.append(.init(range: range, topAdjustment: start - beforeScope, flowStart: beforeScope,
                                        flowEnd: start + measured.height, lines: lines, column: scoped ? column : nil, scope: flow?.scope.id))
            cursor = start + measured.height
            if measurementRange.length < range.length { break }
            index += 1
        }
        // A trailing box still contributes to document height, even without following prose.
        if let last = plan.paragraphs.indices.last, let bottom = plan.regions.map(\.frame.maxY).max(), bottom > cursor {
            plan.paragraphs[last].bottomAdjustment += bottom - cursor
            plan.paragraphs[last].flowEnd = bottom
        }
        plan.formGroups()
        let oversized = plan.groups.filter { group in
            let keepsSpacing = group.location == 0 || text.attribute(.readerPageBreakBefore, at: group.location, effectiveRange: nil) as? Bool == true
            let spacing = keepsSpacing ? min(max(0, (text.attribute(.paragraphStyle, at: group.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0), viewport.height / 2) : 0
            return plan.bounds(of: group).height + spacing > viewport.height - 0.5
        }
        if !oversized.isEmpty {
            var suppressed = disabled
            text.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let box = (value as? ReaderFlowBoxParagraph)?.constraints.first else { return }
                if pass >= 3 || oversized.contains(where: { NSIntersectionRange($0, range).length > 0 }) { suppressed.insert(box.id) }
            }
            if suppressed != disabled { return resolve(source, viewport: viewport, disabled: suppressed, pass: pass + 1, anticipated: []) }
        }
        let positioned = plan.regions.filter(\.wrapsEarlierText)
        let changed = positioned.count != anticipated.count
            || zip(positioned, anticipated).contains { $0.frame != $1.frame || $0.range != $1.range }
        if !positioned.isEmpty, changed {
            if pass < 3 {
                return resolve(source, viewport: viewport, disabled: disabled, pass: pass + 1, anticipated: positioned)
            }
            // Cyclic author geometry must not publish exclusions measured against stale frames.
            // Keep its characters pageable in reading order if the bounded positioning passes
            // cannot settle, just as for an oversized visual group.
            var suppressed = disabled
            text.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let box = (value as? ReaderFlowBoxParagraph)?.constraints.first else { return }
                if positioned.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { suppressed.insert(box.id) }
            }
            if suppressed != disabled {
                return resolve(source, viewport: viewport, disabled: suppressed, pass: pass + 1, anticipated: [])
            }
        }
        if plan.regions.isEmpty && !plan.paragraphs.contains(where: { $0.column != nil || $0.topAdjustment != 0 }) {
            return Result(text: text, geometry: nil)
        }
        text.addAttribute(.readerBoxPage, value: ReaderBoxPage(geometry: plan), range: NSRange(location: 0, length: text.length))
        return Result(text: text, geometry: plan)
    }

    private static func disabledBoxRanges(_ text: NSAttributedString, disabled: Set<UUID>) -> [NSRange] {
        guard !disabled.isEmpty else { return [] }
        var ranges: [NSRange] = []
        text.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let box = (value as? ReaderFlowBoxParagraph)?.constraints.first, disabled.contains(box.id) { ranges.append(range) }
        }
        return ranges
    }

    private static func setEdges(_ text: NSMutableAttributedString, range: NSRange, x: CGFloat, width: CGFloat, viewport: CGSize) {
        var changes: [(NSRange, NSParagraphStyle)] = []
        text.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            let style = (value as? NSParagraphStyle ?? .default).mutableCopy() as! NSMutableParagraphStyle
            let indent = style.firstLineHeadIndent - style.headIndent
            style.headIndent = 0
            style.tailIndent = 0
            style.firstLineHeadIndent = max(0, indent)
            changes.append((run, style))
        }
        for (run, style) in changes { text.addAttribute(.paragraphStyle, value: style, range: run) }
    }

    private static func measure(_ text: NSAttributedString, viewport: CGSize,
                                regions: [ReaderBoxGeometry.Region] = [], origin: CGFloat = 0, sourceOffset: Int = 0,
                                boxFrame: CGRect? = nil, column: CGRect? = nil, scope: UUID? = nil)
        -> (height: CGFloat, paragraphs: [ReaderBoxGeometry.Paragraph]) {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = ReaderTextContainer(size: CGSize(width: viewport.width, height: 0))
        container.lineFragmentPadding = 0; container.viewportSize = viewport
        container.boxRegions = regions; container.boxOrigin = origin; container.boxSourceOffset = sourceOffset
        container.boxOverride = boxFrame
        container.boxColumn = column
        container.boxScope = scope
        let measured = NSMutableAttributedString(attributedString: text)
        let hasTerminator = measured.length > 1 && (measured.string as NSString).character(at: measured.length - 1) == 0x0A
        if hasTerminator { measured.deleteCharacters(in: NSRange(location: measured.length - 1, length: 1)) }
        container.paragraphText = measured
        manager.textContainer = container; storage.attributedString = measured
        var height: CGFloat = 0
        var paragraphs: [ReaderBoxGeometry.Paragraph] = []
        manager.enumerateTextLayoutFragments(from: storage.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            var end = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.endLocation)
            guard start < measured.length else { return false }
            let frame = fragment.layoutFragmentFrame
            var lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }.map { line in
                let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
                var bounds = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                // A constrained line's typographic width is capped at the requested column,
                // while native selection segments can retain the full fractional advance.
                // Reserve that advance around boxes as well as their typographic glyph bounds.
                if boxFrame != nil, let lower = storage.location(storage.documentRange.location, offsetBy: range.location),
                   let upper = storage.location(lower, offsetBy: range.length),
                   let textRange = NSTextRange(location: lower, end: upper) {
                    manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
                        let left = min(bounds.minX, segment.minX), right = max(bounds.maxX, segment.maxX)
                        bounds.origin.x = left
                        bounds.size.width = right - left
                        return true
                    }
                }
                return (range, bounds)
            }
            if hasTerminator && end == measured.length {
                end += 1
                if let last = lines.indices.last { lines[last].0.length += 1 }
            }
            paragraphs.append(.init(range: NSRange(location: start, length: end - start), flowStart: frame.minY,
                                    flowEnd: frame.maxY, lines: lines))
            height = max(height, frame.maxY, lines.map(\.1.maxY).max() ?? 0)
            return true
        }
        if hasTerminator, let last = paragraphs.indices.last {
            let spacing = (text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? 0
            height += spacing
            paragraphs[last].flowEnd += spacing
        }
        return (height, paragraphs)
    }
}
