import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One page of a section: a run of whole lines of the section's layout at one column size.
struct ReaderPage: Equatable {
    /// The section characters on the page. Pages cover the section in order; continuations
    /// of one table row repeat its source range and differ by `tableFragments`.
    var range: NSRange
    /// Where the characters the page's text view lays out end, past `range` when the page ends
    /// inside a paragraph; the view clips them. Line breaking looks ahead (hyphenation, pushing
    /// a lone last word down), so the page's last lines break as in the section only with what
    /// follows them: a few lines, or up to a line break. Justified text needs more, because
    /// CoreText justifies a paragraph of up to 8,192 characters as a whole and a longer one line
    /// by line: a short paragraph's rest up to the next line break that ends a line of text (its
    /// whole rest in a section with a box plan, or when no such break follows), and enough of a
    /// long one to stay long. The page is then measured in this exact display context before its
    /// boundary is committed.
    var layoutEnd: Int
    /// Space kept above the first line: its paragraph's spacing before, at the section's start
    /// or a forced break (CSS truncates margins only at unforced breaks).
    var topSpacing: CGFloat
    /// From the top of the first line to the bottom of the last.
    var height: CGFloat
    /// The page begins inside a paragraph, whose first-line indent and spacing must not repeat.
    var continuesParagraph: Bool
    /// Continued table rows use the same source character on several pages. The fragment
    /// distinguishes their visual/accessible content without inserting synthetic source text.
    var tableFragments: [ReaderTableFragment] = []
    /// The full section's visual top, independent of source order and repeated table offsets.
    var layoutTop: CGFloat = 0
    /// The spacing the section's layout itself has above the page's first line: its paragraph's
    /// spacing before, which TextKit lays out everywhere but at the section's start. The page's
    /// box geometry begins that far above `layoutTop`; `topSpacing` is where the column goes.
    var layoutSpacing: CGFloat = 0
    /// The source line lengths of the page's own layout, which can break differently from the
    /// released section layout. Nil for a page committed without a measurement: the one page
    /// of a section with no lines, a page whose clip can show no fitted glyph, or one whose
    /// first character cluster no layout shows. Every other page's own layout shows a line of
    /// its characters (#576).
    var measuredLineLengths: [Int]? = nil
    /// A page whose first line cannot fit its clip, or whose positioned content cannot, retains
    /// its source as native in-flow text, just as an oversized box does during section preflight.
    var usesFlowFallback = false
    /// The height that fallback fits each run to, as a share of its clip: below 1 when the
    /// line those runs make together was still taller than the clip.
    var fallbackScale: CGFloat = 1
}

extension NSAttributedString.Key {
    /// The height the typography fallback fits a page's runs to (`ReaderPaginator.text(for:)`),
    /// on a formula, which takes its size from the viewport rather than from its run's font.
    static let readerFallbackHeight = NSAttributedString.Key("org.epublib.fallbackHeight")
}

struct ReaderTableFragment: Equatable {
    let offset: Int
    let attachment: TableRowAttachment

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.offset == rhs.offset && lhs.attachment.table === rhs.attachment.table
            && lhs.attachment.row == rhs.attachment.row && lhs.attachment.fragment == rhs.attachment.fragment
    }
}

/// Slices one section into pages from a single TextKit 2 layout at one column size.
///
/// Layout is lazy and in order, so every position it reports is exact: opening a section lays
/// out only as far as the pages asked for, and the whole section only for its end or page count.
/// Box geometry preflights the source needed for wrapping/positioning, leaving the ordinary tail
/// lazy; supported box groups are kept within a page as one visual envelope. Each page is laid
/// out again as it is shown before its boundary is committed (`measuredDisplayPage`).
/// Once every page is known the layout is released (about 60 bytes per character), keeping only
/// the pages.
@MainActor final class ReaderPaginator {
    /// Lines past a page ending mid-paragraph that its view lays out (`ReaderPage.layoutEnd`).
    static let contextLines = 3
    /// The longest paragraph (UTF-16 units, with its terminator) CoreText justifies as a whole.
    static let wholeParagraphJustification = 8_192

    // TextKit rounds a fitted line/glyph box up to one point. Keep the existing one-point
    // drawing inset as well; a smaller clip cannot display fallback typography safely.
    private static let minimumFallbackLineHeight: CGFloat = 1
    private static let fallbackClipInset: CGFloat = 1
    /// How many smaller targets the fallback tries after its first when its line is too tall.
    private static let fallbackRefits = 8

    private func fallbackHeight(for page: ReaderPage) -> CGFloat? {
        let height = size.height - page.topSpacing - Self.fallbackClipInset
        return height >= Self.minimumFallbackLineHeight ? height : nil
    }

    /// Identity of the section attributes supplied by the data source, for pagination caching.
    let sourceText: NSAttributedString
    let text: NSAttributedString
    /// One column's width by the page's text height.
    let size: CGSize
    private let boxGeometry: ReaderBoxGeometry?
    private(set) var pages: [ReaderPage] = []
    private(set) var isComplete = false

    private struct Line {
        var range: NSRange
        var top: CGFloat
        var bottom: CGFloat
        var startsParagraph: Bool
        var endsParagraph: Bool
        var breaksBefore: Bool
        var keepsWithNext: Bool
        var spacingBefore: CGFloat
        /// The paragraph the line belongs to (its layout fragment).
        var paragraph: NSRange
        var isJustified: Bool
        var tableFragment: ReaderTableFragment? = nil
        /// Space flex or grid alignment put above the paragraph (`.readerAlignmentLead`).
        var alignmentLead: CGFloat = 0
    }

    /// The measuring layout, released once pagination completes.
    private var contentStorage: NSTextContentStorage?
    private var layoutManager: NSTextLayoutManager?
    private let characters: NSString
    private var lines: [Line] = []
    /// Where layout continues; nil once the section is laid out to its end.
    private var nextLocation: (any NSTextLocation)?
    /// The first line of the next page.
    private var nextLine = 0
    /// Writing directions of paragraphs continued across pages, by paragraph start.
    private var directions: [Int: NSWritingDirection?] = [:]

    init(text: NSAttributedString, size: CGSize) {
        sourceText = text
        let resolved = ReaderBoxLayout.resolve(text, viewport: size)
        let text = resolved.text
        boxGeometry = resolved.geometry
        self.text = text
        self.size = size
        characters = text.string as NSString
        guard text.length > 0 else {
            pages = [ReaderPage(range: NSRange(location: 0, length: 0), layoutEnd: 0, topSpacing: 0, height: 0,
                                continuesParagraph: false)]
            isComplete = true
            return
        }
        let storage = NSTextContentStorage()
        let layoutManager = ReaderBoxLayoutManager()
        storage.addTextLayoutManager(layoutManager)
        let container = ReaderTextContainer(size: CGSize(width: size.width, height: 0))
        container.lineFragmentPadding = 0
        container.viewportSize = size
        container.configureBoxes(in: text)
        // Pages carry an aligned box's lead as their top spacing, measured from the first line.
        container.alignmentLead = 0
        layoutManager.textContainer = container
        layoutManager.configureGeometry()
        container.deliverIndents(for: storage)
        storage.attributedString = text
        contentStorage = storage
        self.layoutManager = layoutManager
        nextLocation = storage.documentRange.location
    }

    /// The layout is still held (pagination is not complete).
    var holdsLayout: Bool { layoutManager != nil }

    /// Characters laid out so far whose layout is still held: what this paginator costs in memory.
    var heldLayoutLength: Int { holdsLayout ? (lines.last.map { NSMaxRange($0.range) } ?? 0) : 0 }

    /// How much of the section the known pages cover.
    var paginatedLength: Int { pages.last.map { NSMaxRange($0.range) } ?? 0 }

    /// Whether the page holding `offset` is already known.
    func covers(_ offset: Int) -> Bool {
        isComplete || pages.last.map { $0.range.upperBound > offset } == true
    }

    /// Paginates at most `budget` more pages towards the one holding `offset`; true once that
    /// page is known (or the section ends). Lets a caller spread a long pagination over turns
    /// of the run loop.
    func advance(toward offset: Int, pages budget: Int) -> Bool {
        var remaining = budget
        while !covers(offset) {
            guard remaining > 0 else { return false }
            guard layOutNextPage() else { return true }
            remaining -= 1
        }
        return true
    }

    /// The page at `index`, paginating as far as it; nil past the section's last page.
    func page(at index: Int) -> ReaderPage? {
        while pages.count <= index, layOutNextPage() {}
        return pages.indices.contains(index) ? pages[index] : nil
    }

    /// The page showing `offset`; the last page for the section's end.
    func pageIndex(containing offset: Int) -> Int {
        while pages.last.map({ $0.range.upperBound <= offset }) ?? true, layOutNextPage() {}
        var low = 0, high = pages.count - 1
        while low < high { // first page ending after offset
            let mid = (low + high) / 2
            if pages[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Every page, paginating the whole section.
    var allPages: [ReaderPage] {
        while layOutNextPage() {}
        return pages
    }

    /// The text a page's view lays out: its characters plus any layout context, with a
    /// paragraph continued from the previous page restyled so it does not start afresh.
    func text(for page: ReaderPage) -> NSAttributedString {
        let range = NSRange(location: page.range.location, length: page.layoutEnd - page.range.location)
        let slice = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        // Widths are already resolved by the measuring layout; do not reset continuation styles
        // when the displayed text view receives this page.
        slice.removeAttribute(.readerFlowBox, range: NSRange(location: 0, length: slice.length))
        slice.removeAttribute(.readerParagraphSizing, range: NSRange(location: 0, length: slice.length))
        // Alignment is resolved too, and a page's own top spacing carries an aligned box's lead.
        slice.removeAttribute(.readerAlignment, range: NSRange(location: 0, length: slice.length))
        slice.removeAttribute(.readerAlignmentLead, range: NSRange(location: 0, length: slice.length))
        if let geometry = boxGeometry, !page.usesFlowFallback, slice.length > 0 {
            slice.addAttribute(.readerBoxPage, value: ReaderBoxPage(geometry: geometry,
                offset: page.range.location, origin: page.layoutTop - page.layoutSpacing,
                beginsTableContinuation: page.tableFragments.first.map { entry in
                    guard entry.offset == page.range.location, let fragment = entry.attachment.fragment else { return false }
                    let layout = entry.attachment.layout(width: size.width, viewportHeight: size.height)
                    return fragment.top > layout.rowTops[entry.attachment.row] + 0.5
                } ?? false), range: NSRange(location: 0, length: slice.length))
        }
        for entry in page.tableFragments where entry.offset >= range.location && entry.offset < range.upperBound {
            slice.addAttribute(.attachment, value: entry.attachment,
                               range: NSRange(location: entry.offset - page.range.location, length: 1))
        }
        if boxGeometry == nil {
            // A section preflight can reject every box. Its already-resolved ordinary styles
            // must not be replanned through leftover scoped-flow metadata on each page.
            slice.removeAttribute(.readerParagraphFlow, range: NSRange(location: 0, length: slice.length))
        }
        if page.usesFlowFallback, let clipHeight = fallbackHeight(for: page) {
            let height = max(Self.minimumFallbackLineHeight, clipHeight * page.fallbackScale)
            let full = NSRange(location: 0, length: slice.length)
            slice.removeAttribute(.readerBoxPage, range: full)
            // Resolved indents/fonts and all source/semantic attributes remain. Relative-flow
            // metadata must not cause the view to reconstruct the rejected box plan.
            slice.removeAttribute(.readerParagraphFlow, range: full)
            slice.enumerateAttributes(in: full) { attributes, run, _ in
                var natural: CGFloat = 0
                // A baseline shift must not leave fitted fallback glyphs offscreen.
                slice.removeAttribute(.baselineOffset, range: run)
                if let font = attributes[.font] as? PlatformFont {
                    natural = InlineStyling.naturalLineHeight(font)
                    if natural > height {
                        let points = font.pointSize * height / natural
                        #if os(iOS)
                        let fitted = UIFont(descriptor: font.fontDescriptor, size: points)
                        #else
                        let fitted = NSFont(descriptor: font.fontDescriptor, size: points) ?? font
                        #endif
                        slice.addAttribute(.font, value: fitted, range: run)
                        natural = InlineStyling.naturalLineHeight(fitted)
                    }
                }
                if let row = attributes[.attachment] as? TableRowAttachment {
                    let layout = row.layout(width: size.width, viewportHeight: size.height)
                    let fragment = row.fragment ?? layout.fragments(ofRow: row.row, maximumHeight: .greatestFiniteMagnitude)[0]
                    let actualHeight = fragment.height * layout.scale * fragment.fitScale
                    if actualHeight > height {
                        let fitted = TableRowFragment(row: fragment.row, top: fragment.top, bottom: fragment.bottom,
                            height: fragment.height, fitScale: fragment.fitScale * height / actualHeight, cells: fragment.cells)
                        slice.addAttribute(.attachment, value: TableRowAttachment(table: row.table, row: row.row,
                            fragment: fitted, layout: layout), range: run)
                    }
                } else if attributes[.attachment] is MathAttachment {
                    // A formula takes its size from the viewport, not from its run's font.
                    slice.addAttribute(.readerFallbackHeight, value: NSNumber(value: Double(height)), range: run)
                } else if let image = attributes[.attachment] as? ReaderImageAttachment {
                    let drawn = image.sizing.size(lineWidth: size.width, viewport: size, heightLimit: size.height)
                    if drawn.height > height {
                        let ratio = height / drawn.height
                        var sizing = ImageSizing(intrinsic: image.sizing.intrinsic)
                        sizing.width = .points(drawn.width * ratio); sizing.height = .points(height)
                        var style = ComputedStyle()
                        style.display = image.isBlock ? .block : .inline
                        style.verticalAlign = image.verticalAlign
                        style.fontSize = min(image.fontSize, (slice.attribute(.font, at: run.location, effectiveRange: nil) as? PlatformFont)?.pointSize ?? image.fontSize)
                        style.invertsColors = image.invertsColors
                        style.isHidden = image.isHidden
                        slice.addAttribute(.attachment, value: ReaderImageAttachment(source: image.source, sizing: sizing,
                            alternative: image.alternative, style: style, contentRect: image.contentRect,
                            isDark: image.isDark, isHiddenFromAssistiveTechnology: image.isHiddenFromAssistiveTechnology,
                            language: image.language, cache: image.cache), range: run)
                    }
                }
                if let original = attributes[.paragraphStyle] as? NSParagraphStyle {
                    let style = original.mutableCopy() as! NSMutableParagraphStyle
                    style.minimumLineHeight = min(max(0, style.minimumLineHeight), height)
                    style.maximumLineHeight = min(max(0, style.maximumLineHeight), height)
                    if natural > 0, style.lineHeightMultiple > 0 {
                        style.lineHeightMultiple = min(style.lineHeightMultiple, height / natural)
                    }
                    style.lineSpacing = min(max(0, style.lineSpacing), max(0, height - natural))
                    style.paragraphSpacingBefore = min(max(0, style.paragraphSpacingBefore), height / 2)
                    style.paragraphSpacing = min(max(0, style.paragraphSpacing), height / 2)
                    // A tab with neither a stop after it nor an interval is set on no line
                    // (`InlineStyling.tabInterval`). The section's layout can still have set one
                    // that the page's own layout, starting a line later, cannot.
                    if !(style.defaultTabInterval >= 1) {
                        let font = slice.attribute(.font, at: run.location, effectiveRange: nil) as? PlatformFont
                        style.defaultTabInterval = font.map { InlineStyling.tabInterval($0) } ?? InlineStyling.tabInterval(height)
                    }
                    slice.addAttribute(.paragraphStyle, value: style, range: run)
                }
            }
        }
        guard page.continuesParagraph, range.length > 0 else { return slice }
        let paragraph = (slice.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let original = slice.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle ?? .default
        let style = original.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = style.headIndent
        style.paragraphSpacingBefore = 0
        if style.baseWritingDirection == .natural, let direction = paragraphDirection(before: page.range.location) {
            style.baseWritingDirection = direction
        }
        slice.addAttribute(.paragraphStyle, value: style, range: paragraph)
        return slice
    }

    /// The direction of the paragraph holding `location`, from its first strong character
    /// before `location` (the first few thousand characters suffice).
    private func paragraphDirection(before location: Int) -> NSWritingDirection? {
        let start = characters.paragraphRange(for: NSRange(location: location, length: 0)).location
        if let known = directions[start] { return known }
        let prefix = NSRange(location: start, length: min(location - start, 4_096))
        let direction = Self.writingDirection(of: characters.substring(with: prefix))
        directions[start] = direction
        return direction
    }

    // MARK: Slicing

    /// Adds the next page; false once the section is fully paginated.
    private func layOutNextPage() -> Bool {
        guard !isComplete else { return false }
        guard layOutLines(through: nextLine) else {
            finish()
            guard pages.isEmpty else { return false }
            // Text without line fragments still gets the one page that covers it.
            pages = [ReaderPage(range: NSRange(location: 0, length: text.length), layoutEnd: text.length,
                                topSpacing: 0, height: 0, continuesParagraph: false)]
            return true
        }
        let firstIndex = nextLine
        let first = lines[firstIndex]
        let keepsSpacing = first.startsParagraph && (firstIndex == 0 || first.breaksBefore)
        // An aligned box's lead is its own content area, not a margin: it is kept in full, and
        // at an unforced break too, where the margins above the box are truncated.
        let lead = first.startsParagraph ? min(first.alignmentLead, size.height) : 0
        let topSpacing = keepsSpacing ? min(max(0, first.spacingBefore - lead), size.height / 2) + lead : lead
        let available = size.height - topSpacing
        var end = firstIndex
        var pageTop = first.top, pageBottom = first.bottom
        while layOutLines(through: end) {
            let line = lines[end]
            var unitEnd = end + 1
            var unitBounds = CGRect.null
            if let group = boxGeometry?.group(containing: line.range.location) {
                unitBounds = boxGeometry?.bounds(of: group) ?? .null
                while layOutLines(through: unitEnd), lines[unitEnd].range.location < group.upperBound {
                    if lines[unitEnd].tableFragment?.offset == lines[unitEnd - 1].tableFragment?.offset,
                       lines[unitEnd].tableFragment != nil { break }
                    unitEnd += 1
                }
            }
            let unit = lines[end..<unitEnd]
            let top = min(pageTop, unit.map(\.top).min() ?? line.top, unitBounds.isNull ? line.top : unitBounds.minY)
            let bottom = max(pageBottom, unit.map(\.bottom).max() ?? line.bottom, unitBounds.isNull ? line.bottom : unitBounds.maxY)
            if end > firstIndex && (line.breaksBefore || bottom - top > available + 0.5
                || (line.tableFragment != nil && lines[end - 1].tableFragment?.offset == line.tableFragment?.offset)) { break }
            pageTop = top; pageBottom = bottom
            end = unitEnd
            if bottom - top > available + 0.5 { break }
        }
        if end < lines.count, !lines[end].breaksBefore { // An unforced break: keep headings with what follows.
            // The whole run of kept blocks ending here moves to the next page, or none of it
            // does: only when it opens that page together with the line it introduces. A run
            // longer than a page (a `break-inside: avoid` box) breaks where it must instead of
            // leaving one block per page.
            var start = end
            while start > firstIndex, lines[start - 1].keepsWithNext, lines[start - 1].endsParagraph {
                var paragraphStart = start - 1
                while !lines[paragraphStart].startsParagraph { paragraphStart -= 1 }
                start = paragraphStart
            }
            // A heading may share a visual group with an earlier float. Backtracking must
            // move that whole group, never leave the float on a different page from its prose.
            if start < end, let group = boxGeometry?.group(containing: lines[start].range.location) {
                while start > firstIndex, lines[start - 1].range.upperBound > group.location { start -= 1 }
                if lines[start].range.location > group.location { start = firstIndex }
            }
            if start > firstIndex, start < end, lines[end].bottom - lines[start].top <= size.height + 0.5 { end = start }
        }
        let last = lines[end - 1]
        if end > firstIndex {
            // A kept heading may have changed end above; recompute the chosen visual envelope.
            pageTop = lines[firstIndex..<end].map(\.top).min() ?? first.top
            pageBottom = lines[firstIndex..<end].map(\.bottom).max() ?? last.bottom
            for group in boxGeometry?.groups ?? [] where group.location >= first.range.location && group.upperBound <= last.range.upperBound {
                let bounds = boxGeometry?.bounds(of: group) ?? .null
                if !bounds.isNull { pageTop = min(pageTop, bounds.minY); pageBottom = max(pageBottom, bounds.maxY) }
            }
        }
        let layoutEnd = context(after: last, at: end - 1, pageStart: first.range.location)
        var page = ReaderPage(
            range: NSRange(location: first.range.location, length: last.range.upperBound - first.range.location),
            layoutEnd: layoutEnd, topSpacing: topSpacing, height: pageBottom - pageTop,
            continuesParagraph: !first.startsParagraph,
            tableFragments: lines[firstIndex..<end].compactMap(\.tableFragment), layoutTop: pageTop,
            layoutSpacing: first.startsParagraph && first.range.location > 0 ? max(0, first.spacingBefore) : 0)
        // The page's own layout of its slice can break differently from the section's: box
        // margins, a justified paragraph, a paragraph it continues, a line of glyphs from a
        // fallback font, the end of manufactured table continuations. Measure that exact
        // bounded context before committing a clip or advancing its characters. Keep
        // layoutEnd fixed so changing the visible range cannot itself change the final line
        // breaks.
        let originalEnd = page.range.upperBound
        page = measuredDisplayPage(page)
        while end > firstIndex, lines[end - 1].range.upperBound > page.range.upperBound { end -= 1 }
        while layOutLines(through: end), lines[end].range.location >= originalEnd,
              lines[end].range.upperBound <= page.range.upperBound { end += 1 }
        // A frozen row ending the displayed page has fixed glyph metrics. Following
        // rows or prose do not supply layout context for it, and belong to the next page.
        // Ordinary paragraph and box context keeps its original measured extent.
        if boxGeometry == nil, end > firstIndex, lines[end - 1].tableFragment != nil {
            page.layoutEnd = page.range.upperBound
        }
        if layOutLines(through: end), lines[end].tableFragment == nil,
           lines[end].range.location < page.range.upperBound {
            // The next column starts at the displayed layout's line boundary, which can
            // lie inside a line of the section layout. Never repeat that line's prefix.
            lines[end].range.length = lines[end].range.upperBound - page.range.upperBound
            lines[end].range.location = page.range.upperBound
            lines[end].startsParagraph = false
        }
        assertCommittable(page, first: first, at: firstIndex, advancing: end > firstIndex)
        pages.append(page)
        nextLine = end
        if !layOutLines(through: end) { finish() }
        return true
    }

    /// What every committed page keeps, checked in debug builds (#576). It starts where the
    /// last page ended: after characters the section's layout set on no line (text TextKit
    /// could not place, #288), or on the row whose continuation it holds. It advances. And its
    /// own layout shows a line of its characters, unless its clip can show no glyph or no
    /// layout shows its first character cluster (`shortened`).
    private func assertCommittable(_ page: ReaderPage, first: Line, at index: Int, advancing: Bool) {
        let previous = pages.last?.range.upperBound ?? 0
        let continuesRow = first.tableFragment != nil && pages.last.map { NSLocationInRange(page.range.location, $0.range) } == true
        assert(page.range.location == previous || continuesRow
               || page.range.location > previous && (index == 0 || lines[index - 1].range.upperBound <= previous),
               "The page at \(page.range.location) starts where the page before it ends, at \(previous)")
        assert(page.range.length > 0 && (page.range.upperBound > previous || advancing),
               "The page at \(page.range.location) advances")
        assert(fallbackHeight(for: page) == nil
               || page.measuredLineLengths.map { !$0.isEmpty && $0.reduce(0, +) <= page.range.length } == true
               || shown(start(of: page, length: characters.rangeOfComposedCharacterSequence(at: page.range.location).length)) == nil,
               "The page \(page.range)'s own layout shows a line of its characters, or no layout shows its first")
    }

    /// A displayed page, including its existing lookahead, without preceding section text.
    /// Overflow carries to the next page. A positioned line outside the clip, a first line too
    /// tall to fit, or a slice whose own layout sets none of its characters on a line uses
    /// native in-flow text with bounded typography for this slice. When that does not show the
    /// first line either, the page keeps as much of that line as it can show and the rest
    /// carries forward. So no page is committed whose own layout shows no line of its
    /// characters, unless its clip can show no glyph at all or no layout can show its first
    /// character (#576).
    private func measuredDisplayPage(_ page: ReaderPage) -> ReaderPage {
        let shown = layOutAsShown(page)
        if case .fits(let measured) = shown { return measured }
        // An impossibly small viewport still advances one original source line. Do not
        // change its font or partition while claiming that a fitted glyph is visible.
        guard fallbackHeight(for: page) != nil else { return page }
        if let fitted = fallback(for: page) { return fitted }
        var line = page.range.length
        if case .overflows(let first?) = shown { line = min(line, first.end) }
        return shortened(page, line: line)
    }

    /// The page as native in-flow text with bounded typography (`ReaderPage.usesFlowFallback`),
    /// or nil when no height it tries shows the page's first line within the clip.
    private func fallback(for page: ReaderPage) -> ReaderPage? {
        guard let clipHeight = fallbackHeight(for: page) else { return nil }
        var fallback = page
        fallback.usesFlowFallback = true
        fallback.fallbackScale = 1
        for _ in 0...Self.fallbackRefits {
            let shown = layOutAsShown(fallback)
            if case .fits(let measured) = shown { return measured }
            guard case .overflows(let line?) = shown else { return nil }
            // Each run fits the target on its own, but the line they make together is still
            // taller than the clip: a small run's line height applied to a large run's font,
            // text on one line with a row or an image. Lower the target by the line's
            // overshoot, or in proportion if that is lower, and lay the slice out again.
            let clip = size.height - page.topSpacing
            let target = clipHeight * fallback.fallbackScale
            let next = min(target * clip / max(line.bottom - min(line.top, 0), clip + 1),
                           target - max(line.bottom - clip, -line.top, 0) - 1)
            guard next >= Self.minimumFallbackLineHeight, next < target else { return nil }
            fallback.fallbackScale = next / clipHeight
        }
        return nil
    }

    /// The page laid out alone as it is shown, as planned or else as the fallback; nil when
    /// neither shows its first line within the clip.
    private func shown(_ page: ReaderPage) -> ReaderPage? {
        if case .fits(let measured) = layOutAsShown(page) { return measured }
        return fallback(for: page)
    }

    /// The first `length` characters of `page`, laid out without context.
    private func start(of page: ReaderPage, length: Int) -> ReaderPage {
        var part = page
        part.range.length = length
        part.layoutEnd = page.range.location + length
        part.tableFragments = page.tableFragments.filter { NSLocationInRange($0.offset, part.range) }
        return part
    }

    /// The page cut to the longest start of its first line (which ends `line` characters into
    /// the page) that shows laid out alone; the rest of the line carries to the next page, as
    /// a line below the clip does. Only a page whose first line shows neither as planned nor as
    /// the fallback comes here, and no content the reader makes is known to, since the
    /// fallback fits every run, row, image, formula and tab. A first character cluster that no
    /// layout shows, which only content made outside the reader is known to have, is committed
    /// as planned with the white space after it on its line, so that pagination advances.
    private func shortened(_ page: ReaderPage, line: Int) -> ReaderPage {
        // A page never divides a character cluster.
        var ends: [Int] = []
        var end = page.range.location
        let lineEnd = page.range.location + max(1, min(line, page.range.length))
        while end < lineEnd {
            end = min(NSMaxRange(characters.rangeOfComposedCharacterSequence(at: end)), page.range.upperBound)
            ends.append(end - page.range.location)
        }
        var low = 0, high = ends.count - 1
        var longest: ReaderPage?
        while low <= high {
            let middle = (low + high) / 2
            if let shown = shown(start(of: page, length: ends[middle])) { longest = shown; low = middle + 1 } else { high = middle - 1 }
        }
        if let longest { return longest }
        end = page.range.location + ends[0]
        while end < lineEnd, UnicodeScalar(characters.character(at: end)).map(CharacterSet.whitespacesAndNewlines.contains) == true { end += 1 }
        return start(of: page, length: end - page.range.location)
    }

    /// How a page's slice lays out as it is shown.
    private enum ShownLayout {
        /// The lines that fit the clip, as the page to commit.
        case fits(ReaderPage)
        /// A line outside the clip that cannot carry to the next page: the first line, whose
        /// top, bottom and end in the slice are given, or a positioned line above the column.
        case overflows(firstLine: (top: CGFloat, bottom: CGFloat, end: Int)?)
        /// No line of the page's characters: the page's own layout set none of them on a line,
        /// as where its container refuses TextKit the first line (`ReaderTextContainer.askLimit`).
        case empty
    }

    /// Lays out the page's slice alone, as its column will.
    private func layOutAsShown(_ page: ReaderPage) -> ShownLayout {
        let storage = NSTextContentStorage()
        let manager = ReaderBoxLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = ReaderTextContainer(size: CGSize(width: size.width, height: 0))
        container.lineFragmentPadding = 0
        container.viewportSize = size
        let pageText = text(for: page)
        container.configureBoxes(in: pageText)
        manager.textContainer = container
        manager.configureGeometry()
        container.deliverIndents(for: storage)
        storage.attributedString = pageText
        // A page is a bounded slice. Finish that slice before inspecting its frames: later
        // fragment requests can replace estimates used by earlier box-margin fragments.
        let positionsLines = boxGeometry != nil || page.usesFlowFallback || !page.tableFragments.isEmpty
            || page.height > size.height - page.topSpacing + 0.5
        if positionsLines { manager.ensureLayout(for: storage.documentRange) }
        var visibleEnd = 0
        var overflow: (top: CGFloat, bottom: CGFloat, end: Int)??
        var visibleBottom: CGFloat = 0
        var lineLengths: [Int] = []
        var lineBottoms: [CGFloat] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
                guard range.location < page.range.length else { return false }
                let originY = boxGeometry == nil && !page.usesFlowFallback
                    ? fragment.layoutFragmentFrame.minY : fragment.layoutFragmentFrame.origin.y
                let bottom = originY + line.typographicBounds.maxY
                let top = originY + line.typographicBounds.minY
                // Every page's first line must fit. Committed taller than the clip, its
                // characters would be on no visible line, and a table row laid out beside
                // them would lose its continuation pages.
                if (positionsLines && top < -0.5) || (visibleEnd == 0 && bottom > size.height - page.topSpacing + 0.5) {
                    // The fallback's later lines carry forward like any page's.
                    if visibleEnd == 0 || !page.usesFlowFallback { overflow = .some(visibleEnd == 0 ? (top, bottom, range.upperBound) : nil) }
                    return false
                }
                if visibleEnd > 0, bottom > size.height - page.topSpacing + 0.5 { return false }
                visibleEnd = range.upperBound
                lineLengths.append(visibleEnd - range.location)
                visibleBottom = max(visibleBottom, bottom)
                lineBottoms.append(visibleBottom)
                if visibleEnd >= page.range.length { return false }
            }
            return true
        }
        if let overflow { return .overflows(firstLine: overflow) }
        guard visibleEnd > 0 else { return .empty }
        // A tail's changed line count must not strand a heading or cut a visual box group
        // that the section paginator already kept together.
        var boundary = page.range.location + visibleEnd
        if !page.usesFlowFallback, let group = boxGeometry?.group(containing: max(page.range.location, boundary - 1)),
           boundary < group.upperBound, group.location > page.range.location {
            while lineLengths.count > 1, page.range.location + visibleEnd > group.location {
                visibleEnd -= lineLengths.removeLast()
                lineBottoms.removeLast()
            }
            boundary = page.range.location + visibleEnd
        }
        while boundary < page.range.upperBound, boundary > page.range.location {
            let paragraph = characters.paragraphRange(for: NSRange(location: boundary - 1, length: 0))
            guard paragraph.upperBound == boundary, paragraph.location > page.range.location,
                  text.attribute(.readerKeepWithNext, at: paragraph.location, effectiveRange: nil) as? Bool == true else { break }
            while lineLengths.count > 1, page.range.location + visibleEnd > paragraph.location {
                visibleEnd -= lineLengths.removeLast()
                lineBottoms.removeLast()
            }
            boundary = page.range.location + visibleEnd
        }
        visibleBottom = lineBottoms.last ?? visibleBottom
        var measured = page
        measured.range.length = visibleEnd
        measured.height = boxGeometry != nil && visibleEnd >= page.range.length
            ? max(visibleBottom, min(page.height, size.height - page.topSpacing)) : visibleBottom
        measured.measuredLineLengths = lineLengths
        measured.tableFragments = page.tableFragments.filter { NSLocationInRange($0.offset, measured.range) }
        return .fits(measured)
    }

    /// The layout context after a page's last line (`ReaderPage.layoutEnd`).
    private func context(after last: Line, at index: Int, pageStart: Int) -> Int {
        let paragraph = last.paragraph
        let limit = Self.wholeParagraphJustification
        if last.isJustified, paragraph.length > limit {
            // Keep a long paragraph's algorithm while enough source follows. Its short
            // continuation tail instead receives an exact, bounded page measurement.
            let start = max(paragraph.location, pageStart)
            return last.endsParagraph ? last.range.upperBound
                : min(NSMaxRange(paragraph), max(start + limit + 1, lineEnd(after: index, lines: Self.contextLines)))
        }
        guard !last.endsParagraph else { return last.range.upperBound }
        // A short justified paragraph is justified as a whole, but not across a line break:
        // CoreText sets the lines before a U+2028 (`<br>`) the same whatever follows it. Its
        // rest up to the first break that ends a line of text, or its whole rest. A box plan
        // can place those lines by what follows the break, so a planned section keeps it all.
        if last.isJustified {
            guard boxGeometry == nil else { return NSMaxRange(paragraph) }
            return textLineBreakEnd(from: last.range.upperBound - 1, in: paragraph) ?? NSMaxRange(paragraph)
        }
        var end = last.range.upperBound
        var context = index
        while !lines[context].endsParagraph, !endsWithLineBreak(lines[context]),
              context - index < Self.contextLines, layOutLines(through: context + 1) {
            context += 1
            end = lines[context].range.upperBound
        }
        return end
    }

    /// The end of the line `count` lines after line `index`, within its paragraph.
    private func lineEnd(after index: Int, lines count: Int) -> Int {
        var context = index
        while !lines[context].endsParagraph, context - index < count, layOutLines(through: context + 1) { context += 1 }
        return lines[context].range.upperBound
    }

    /// The end of the first line separator at or after `location` in `paragraph` that ends a line
    /// of text. One that ends a blank line is passed over: laid out last, a lone separator takes
    /// another position, and sometimes another height, than it has with text after it.
    private func textLineBreakEnd(from location: Int, in paragraph: NSRange) -> Int? {
        var search = NSRange(location: location, length: NSMaxRange(paragraph) - location)
        while search.length > 0 {
            let found = characters.range(of: "\u{2028}", options: .literal, range: search)
            guard found.location != NSNotFound else { return nil }
            let previous = found.location > paragraph.location ? characters.character(at: found.location - 1) : 0x2028
            if previous != 0x2028 && previous != 0x0A { return NSMaxRange(found) }
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(paragraph) - NSMaxRange(found))
        }
        return nil
    }

    /// A line ending in a line separator (`<br>`): nothing after it changes how it breaks.
    private func endsWithLineBreak(_ line: Line) -> Bool {
        line.range.length > 0 && characters.character(at: NSMaxRange(line.range) - 1) == 0x2028
    }

    /// Every page is known: release the layout.
    private func finish() {
        isComplete = true
        nextLocation = nil
        lines = []
        if let layoutManager { contentStorage?.removeTextLayoutManager(layoutManager) }
        layoutManager = nil
        contentStorage = nil
    }

    /// Lays out paragraphs until line `index` exists; false when the section ends first.
    private func layOutLines(through index: Int) -> Bool {
        while lines.count <= index, let location = nextLocation { layOutParagraphs(from: location, count: 16) }
        return index < lines.count
    }

    private func layOutParagraphs(from location: any NSTextLocation, count: Int) {
        guard let layoutManager, let contentStorage else { nextLocation = nil; return }
        var remaining = count
        var next: (any NSTextLocation)?
        layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            append(fragment, in: contentStorage)
            next = fragment.rangeInElement.endLocation
            remaining -= 1
            return remaining > 0
        }
        let end = contentStorage.documentRange.endLocation
        if let next, next.compare(location) == .orderedDescending, next.compare(end) == .orderedAscending {
            nextLocation = next
        } else {
            nextLocation = nil
        }
    }

    private func append(_ fragment: NSTextLayoutFragment, in contentStorage: NSTextContentStorage) {
        let start = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
        guard start < text.length else { return }
        let attributes = text.attributes(at: start, effectiveRange: nil)
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        let frame = fragment.layoutFragmentFrame
        let fragmentLines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        let paragraph = NSRange(location: start, length: contentStorage.offset(from: fragment.rangeInElement.location,
                                                                              to: fragment.rangeInElement.endLocation))
        for (index, line) in fragmentLines.enumerated() {
            let bounds = line.typographicBounds
            let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
            // Keep the established section flow envelope for page anchoring. A signed
            // box frame can reserve leading space that the displayed page already honors.
            // Exact page measurement and interaction geometry use actual glyph origins.
            let originY = frame.minY
            let top = originY + bounds.minY
            if let row = text.attribute(.attachment, at: range.location, effectiveRange: nil) as? TableRowAttachment {
                let layout = row.layout(width: max(1, bounds.width), viewportHeight: size.height)
                let firstSpacing = start == 0 || attributes[.readerPageBreakBefore] as? Bool == true
                    ? min(max(0, style?.paragraphSpacingBefore ?? 0), size.height / 2) : 0
                let slices = layout.fragments(ofRow: row.row, maximumHeight: max(1, size.height - firstSpacing - 1))
                var y = top
                for (index, slice) in slices.enumerated() {
                    let attachment = TableRowAttachment(table: row.table, row: row.row, fragment: slice, layout: layout)
                    let height = slice.height * layout.scale * slice.fitScale
                    lines.append(Line(range: range, top: y, bottom: y + height,
                                      startsParagraph: true, endsParagraph: true,
                                      breaksBefore: index == 0 && attributes[.readerPageBreakBefore] as? Bool == true,
                                      keepsWithNext: index == slices.count - 1 && attributes[.readerKeepWithNext] as? Bool == true,
                                      spacingBefore: index == 0 ? style?.paragraphSpacingBefore ?? 0 : 0,
                                      paragraph: paragraph, isJustified: false,
                                      tableFragment: ReaderTableFragment(offset: range.location, attachment: attachment)))
                    y += height
                }
            } else {
                lines.append(Line(range: range,
                                  top: top, bottom: originY + bounds.maxY,
                                  startsParagraph: index == 0, endsParagraph: index == fragmentLines.count - 1,
                                  breaksBefore: index == 0 && attributes[.readerPageBreakBefore] as? Bool == true,
                                  keepsWithNext: attributes[.readerKeepWithNext] as? Bool == true,
                                  spacingBefore: style?.paragraphSpacingBefore ?? 0,
                                  paragraph: paragraph, isJustified: style?.alignment == .justified,
                                  alignmentLead: index == 0 ? ReaderAlignmentLayout.lead(in: text, at: start) : 0))
            }
        }
    }

    /// The direction a paragraph's first strong character gives it (Unicode bidi P2), skipping
    /// isolates. Used when a page starts mid-paragraph, where the slice's own first strong
    /// character might disagree.
    static func writingDirection(of text: String) -> NSWritingDirection? {
        var isolates = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2066...0x2068: isolates += 1
            case 0x2069: isolates = max(0, isolates - 1)
            case _ where isolates > 0: continue
            case 0x200F: return .rightToLeft
            case 0x200E: return .leftToRight
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                if scalar.properties.isAlphabetic { return .rightToLeft }
            default:
                if scalar.properties.isAlphabetic { return .leftToRight }
            }
        }
        return nil
    }
}
