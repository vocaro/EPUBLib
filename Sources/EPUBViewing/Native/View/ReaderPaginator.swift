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
    /// Where the characters the page's text view lays out end: past `range` to the paragraph's
    /// end when the page ends inside a paragraph. Line breaking looks ahead (hyphenation,
    /// justification, and pushing words down so a paragraph's last line is not a lone word), so
    /// the page's last lines break as they do in the section only with the rest of their
    /// paragraph after them. The view clips that context.
    var layoutEnd: Int
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
@MainActor final class ReaderPaginator {
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
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let characters: NSString
    private var lines: [Line] = []
    /// Where layout continues; nil once the section is laid out to its end.
    private var nextLocation: (any NSTextLocation)?
    /// The first line of the next page.
    private var nextLine = 0

    init(text: NSAttributedString, size: CGSize) {
        self.text = text
        self.size = size
        characters = text.string as NSString
        contentStorage.addTextLayoutManager(layoutManager)
        let container = ReaderTextContainer(size: CGSize(width: size.width, height: 0))
        container.lineFragmentPadding = 0
        container.viewportSize = size
        layoutManager.textContainer = container
        contentStorage.attributedString = text
        if text.length > 0 {
            nextLocation = contentStorage.documentRange.location
        } else {
            pages = [ReaderPage(range: NSRange(location: 0, length: 0), layoutEnd: 0, topSpacing: 0, height: 0,
                                continuesParagraph: false)]
            isComplete = true
        }
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
        guard page.continuesParagraph, range.length > 0 else { return text.attributedSubstring(from: range) }
        let slice = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        let paragraph = (slice.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let original = slice.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle ?? .default
        let style = original.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = style.headIndent
        style.paragraphSpacingBefore = 0
        if style.baseWritingDirection == .natural {
            let start = characters.paragraphRange(for: NSRange(location: page.range.location, length: 0)).location
            let before = NSRange(location: start, length: page.range.location - start)
            if let direction = Self.writingDirection(of: characters.substring(with: before)) {
                style.baseWritingDirection = direction
            }
        }
        slice.addAttribute(.paragraphStyle, value: style, range: paragraph)
        return slice
    }

    // MARK: Slicing

    /// Adds the next page; false once the section is fully paginated.
    private func layOutNextPage() -> Bool {
        guard !isComplete else { return false }
        guard layOutLines(through: nextLine) else {
            isComplete = true
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
                guard start > firstIndex else { break }
                cut = start
            }
            end = cut
        }
        let last = lines[end - 1]
        let layoutEnd = last.endsParagraph ? last.range.upperBound
            : NSMaxRange(characters.paragraphRange(for: NSRange(location: last.range.upperBound - 1, length: 1)))
        pages.append(ReaderPage(
            range: NSRange(location: first.range.location, length: last.range.upperBound - first.range.location),
            layoutEnd: layoutEnd, topSpacing: topSpacing, height: last.bottom - first.top,
            continuesParagraph: !first.startsParagraph))
        nextLine = end
        if !layOutLines(through: end) { isComplete = true }
        return true
    }

    /// Lays out paragraphs until line `index` exists; false when the section ends first.
    private func layOutLines(through index: Int) -> Bool {
        while lines.count <= index, let location = nextLocation { layOutParagraphs(from: location, count: 16) }
        return index < lines.count
    }

    private func layOutParagraphs(from location: any NSTextLocation, count: Int) {
        var remaining = count
        var next: (any NSTextLocation)?
        layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            append(fragment)
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

    private func append(_ fragment: NSTextLayoutFragment) {
        let start = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
        guard start < text.length else { return }
        let attributes = text.attributes(at: start, effectiveRange: nil)
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        let frame = fragment.layoutFragmentFrame
        let fragmentLines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        for (index, line) in fragmentLines.enumerated() {
            let bounds = line.typographicBounds
            lines.append(Line(
                range: NSRange(location: start + line.characterRange.location, length: line.characterRange.length),
                top: frame.minY + bounds.minY, bottom: frame.minY + bounds.maxY,
                startsParagraph: index == 0, endsParagraph: index == fragmentLines.count - 1,
                breaksBefore: index == 0 && attributes[.readerPageBreakBefore] as? Bool == true,
                keepsWithNext: attributes[.readerKeepWithNext] as? Bool == true,
                spacingBefore: style?.paragraphSpacingBefore ?? 0))
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
