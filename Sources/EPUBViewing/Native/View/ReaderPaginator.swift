import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One page of a section: a run of whole lines of the section's layout at one column size.
struct ReaderPage: Equatable {
    /// The section characters on the page. A section's pages are contiguous and cover it.
    var range: NSRange
    /// Where the characters the page's text view lays out end, past `range` when the page ends
    /// inside a paragraph; the view clips them. Line breaking looks ahead (hyphenation, pushing
    /// a lone last word down), so the page's last lines break as in the section only with what
    /// follows them: a few lines, or up to a line break. Justified text needs more, because
    /// CoreText justifies a paragraph of up to 8,192 characters as a whole and a longer one line
    /// by line: a short paragraph's whole rest, or enough of a long one to stay long.
    var layoutEnd: Int
    /// Characters of filler the page's view lays out after `layoutEnd` (never shown), so a long
    /// justified paragraph's tail is still justified as long.
    var filler = 0
    /// Space kept above the first line: its paragraph's spacing before, at the section's start
    /// or a forced break (CSS truncates margins only at unforced breaks).
    var topSpacing: CGFloat
    /// From the top of the first line to the bottom of the last.
    var height: CGFloat
    /// The page begins inside a paragraph, whose first-line indent and spacing must not repeat.
    var continuesParagraph: Bool
}

/// Slices one section into pages from a single TextKit 2 layout at one column size.
///
/// Layout is lazy and in order, so every position it reports is exact: opening a section lays
/// out only as far as the pages asked for, and the whole section only for its end or page count.
/// Once every page is known the layout is released (about 60 bytes per character), keeping only
/// the pages.
@MainActor final class ReaderPaginator {
    /// Lines past a page ending mid-paragraph that its view lays out (`ReaderPage.layoutEnd`).
    static let contextLines = 3
    /// The longest paragraph (UTF-16 units, with its terminator) CoreText justifies as a whole.
    static let wholeParagraphJustification = 8_192

    let text: NSAttributedString
    /// One column's width by the page's text height.
    let size: CGSize
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
        let layoutManager = NSTextLayoutManager()
        storage.addTextLayoutManager(layoutManager)
        let container = ReaderTextContainer(size: CGSize(width: size.width, height: 0))
        container.lineFragmentPadding = 0
        container.viewportSize = size
        layoutManager.textContainer = container
        storage.attributedString = text
        contentStorage = storage
        self.layoutManager = layoutManager
        nextLocation = storage.documentRange.location
    }

    /// The layout is still held (pagination is not complete).
    var holdsLayout: Bool { layoutManager != nil }

    /// Characters laid out so far whose layout is still held: what this paginator costs in memory.
    var heldLayoutLength: Int { holdsLayout ? (lines.last.map { NSMaxRange($0.range) } ?? 0) : 0 }

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
        guard (page.continuesParagraph || page.filler > 0), range.length > 0 else { return text.attributedSubstring(from: range) }
        let slice = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        if page.filler > 0 {
            // Inside the paragraph, before any terminator: a line break and unseen characters.
            let end = slice.string.utf16.last == 0x0A ? slice.length - 1 : slice.length
            let attributes = slice.attributes(at: max(0, end - 1), effectiveRange: nil)
            slice.insert(NSAttributedString(string: "\u{2028}" + String(repeating: "x ", count: page.filler / 2 + 1),
                                            attributes: attributes), at: end)
        }
        guard page.continuesParagraph else { return slice }
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
        let topSpacing = keepsSpacing ? min(max(0, first.spacingBefore), size.height / 2) : 0
        let available = size.height - topSpacing
        var end = firstIndex + 1
        while layOutLines(through: end) {
            let line = lines[end]
            if line.breaksBefore || line.bottom - first.top > available + 0.5 { break }
            end += 1
        }
        if end < lines.count, !lines[end].breaksBefore { // An unforced break: keep headings with what follows.
            var cut = end
            while lines[cut - 1].keepsWithNext, lines[cut - 1].endsParagraph {
                var start = cut - 1
                while !lines[start].startsParagraph { start -= 1 }
                // Moved only when it opens the next page with the line it introduces; a block
                // that cannot would be stranded there alone.
                guard start > firstIndex, lines[end].bottom - lines[start].top <= size.height + 0.5 else { break }
                cut = start
            }
            end = cut
        }
        let last = lines[end - 1]
        let (layoutEnd, filler) = context(after: last, at: end - 1, pageStart: first.range.location)
        pages.append(ReaderPage(
            range: NSRange(location: first.range.location, length: last.range.upperBound - first.range.location),
            layoutEnd: layoutEnd, filler: filler, topSpacing: topSpacing, height: last.bottom - first.top,
            continuesParagraph: !first.startsParagraph))
        nextLine = end
        if !layOutLines(through: end) { finish() }
        return true
    }

    /// The layout context after a page's last line (`ReaderPage.layoutEnd`, `filler`).
    private func context(after last: Line, at index: Int, pageStart: Int) -> (end: Int, filler: Int) {
        let paragraph = last.paragraph
        let limit = Self.wholeParagraphJustification
        if last.isJustified, paragraph.length > limit {
            // The page's part of a long paragraph stays longer than the limit, as the whole is.
            let start = max(paragraph.location, pageStart)
            let end = last.endsParagraph ? last.range.upperBound
                : min(NSMaxRange(paragraph), max(start + limit + 1, lineEnd(after: index, lines: Self.contextLines)))
            let laidOut = last.endsParagraph || end == NSMaxRange(paragraph) ? NSMaxRange(paragraph) - start : end - start
            return (end, max(0, limit + 1 - laidOut))
        }
        guard !last.endsParagraph else { return (last.range.upperBound, 0) }
        // A short justified paragraph is justified as a whole: its whole rest.
        if last.isJustified { return (NSMaxRange(paragraph), 0) }
        var end = last.range.upperBound
        var context = index
        while !lines[context].endsParagraph, !endsWithLineBreak(lines[context]),
              context - index < Self.contextLines, layOutLines(through: context + 1) {
            context += 1
            end = lines[context].range.upperBound
        }
        return (end, 0)
    }

    /// The end of the line `count` lines after line `index`, within its paragraph.
    private func lineEnd(after index: Int, lines count: Int) -> Int {
        var context = index
        while !lines[context].endsParagraph, context - index < count, layOutLines(through: context + 1) { context += 1 }
        return lines[context].range.upperBound
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
            lines.append(Line(
                range: NSRange(location: start + line.characterRange.location, length: line.characterRange.length),
                top: frame.minY + bounds.minY, bottom: frame.minY + bounds.maxY,
                startsParagraph: index == 0, endsParagraph: index == fragmentLines.count - 1,
                breaksBefore: index == 0 && attributes[.readerPageBreakBefore] as? Bool == true,
                keepsWithNext: attributes[.readerKeepWithNext] as? Bool == true,
                spacingBefore: style?.paragraphSpacingBefore ?? 0,
                paragraph: paragraph, isJustified: style?.alignment == .justified))
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
