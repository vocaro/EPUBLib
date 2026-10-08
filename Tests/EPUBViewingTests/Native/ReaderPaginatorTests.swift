import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pages are slices of one TextKit 2 layout at line boundaries.
@MainActor final class ReaderPaginatorTests: XCTestCase {
    private let size = CGSize(width: 320, height: 500)

    /// Every line of `text` laid out independently at `width`: (range, top, bottom).
    private func lines(of text: NSAttributedString, width: CGFloat) -> [(range: NSRange, top: CGFloat, bottom: CGFloat)] {
        let storage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        storage.addTextLayoutManager(layoutManager)
        let container = ReaderTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        storage.attributedString = text
        var result: [(NSRange, CGFloat, CGFloat)] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                result.append((NSRange(location: start + line.characterRange.location, length: line.characterRange.length),
                               fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
                               fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY))
            }
            return true
        }
        return result
    }

    func testPagesCoverTheSectionWithoutGapsOrOverlaps() {
        let text = CanvasText.section(0, chapters: 3, paragraphs: 10)
        let pages = ReaderPaginator(text: text, size: size).allPages
        XCTAssertGreaterThan(pages.count, 8)
        XCTAssertEqual(pages.first?.range.location, 0)
        XCTAssertEqual(pages.last.map { NSMaxRange($0.range) }, text.length)
        for (page, next) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(NSMaxRange(page.range), next.range.location, "contiguous")
            XCTAssertGreaterThan(page.range.length, 0)
        }
        for page in pages {
            XCTAssertLessThanOrEqual(page.height, size.height - page.topSpacing + 0.5, "a page's lines fit it")
            XCTAssertGreaterThanOrEqual(page.layoutEnd, NSMaxRange(page.range))
        }
    }

    func testPagesNeverCutALine() {
        let text = CanvasText.section(1, chapters: 2, paragraphs: 12)
        let lineStarts = Set(lines(of: text, width: size.width).map(\.range.location))
        for page in ReaderPaginator(text: text, size: size).allPages {
            XCTAssertTrue(lineStarts.contains(page.range.location), "page at \(page.range.location) starts a line")
        }
    }

    func testPageBreaksStartPages() {
        let text = CanvasText.section(2, chapters: 4, paragraphs: 3)
        let paginator = ReaderPaginator(text: text, size: size)
        let starts = Set(paginator.allPages.map(\.range.location))
        var breaks: [Int] = []
        text.enumerateAttribute(.readerPageBreakBefore, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value as? Bool == true { breaks.append(range.location) }
        }
        XCTAssertEqual(breaks.count, 4)
        for location in breaks { XCTAssertTrue(starts.contains(location), "a page starts at the break at \(location)") }
        // The heading opening a section or following a forced break keeps its spacing before.
        let second = paginator.pages[paginator.pageIndex(containing: breaks[1])]
        XCTAssertEqual(second.topSpacing, 24)
    }

    /// Ten single-line paragraphs fit the page; a heading on the tenth line moves to the next
    /// page with the line it introduces.
    func testKeepWithNextMovesAHeadingOffThePageEnd() {
        let line = lines(of: CanvasText.body("Line"), width: 300)[0]
        let height = (line.bottom - line.top) * 10.5
        func page(withKeep keep: Bool) -> [ReaderPage] {
            let text = NSMutableAttributedString()
            for line in 0..<9 { text.append(CanvasText.body("Line \(line)\n", style: CanvasText.bodyStyle(spacing: 0))) }
            let heading = NSMutableAttributedString(attributedString: CanvasText.body("Heading\n", style: CanvasText.bodyStyle(spacing: 0)))
            if keep { heading.addAttribute(.readerKeepWithNext, value: true, range: NSRange(location: 0, length: heading.length)) }
            text.append(heading)
            for line in 0..<5 { text.append(CanvasText.body("Body \(line)\n", style: CanvasText.bodyStyle(spacing: 0))) }
            return ReaderPaginator(text: text, size: CGSize(width: 300, height: height)).allPages
        }
        let plain = page(withKeep: false), kept = page(withKeep: true)
        XCTAssertEqual(plain.count, 2)
        XCTAssertEqual(plain[1].range.location, 9 * 7 + 8, "without keep-with-next the heading ends page one")
        XCTAssertEqual(kept[1].range.location, 9 * 7, "the heading moves to page two")
    }

    func testAnAttachmentTallerThanAPageGetsItsOwnPage() {
        let text = NSMutableAttributedString(attributedString: CanvasText.body(CanvasText.sentence(40, seed: 1) + "\n"))
        let attachmentLocation = text.length
        text.append(CanvasText.attachment(size: CGSize(width: 200, height: 900)))
        text.append(CanvasText.body("\n" + CanvasText.sentence(40, seed: 2)))
        let pages = ReaderPaginator(text: text, size: size).allPages
        guard pages.count == 3 else { return XCTFail("\(pages.count) pages") }
        XCTAssertEqual(pages[1].range.location, attachmentLocation)
        XCTAssertEqual(pages[1].range.length, 2, "the attachment and its paragraph break")
        XCTAssertGreaterThan(pages[1].height, size.height)
    }

    /// Each page's own text, laid out alone as its column does, breaks into exactly the
    /// section's lines, including mid-paragraph starts in justified, hyphenated, indented text.
    func testPageTextLaysOutLikeTheSection() {
        let style = CanvasText.bodyStyle(alignment: .justified, hyphenates: true, indent: 24)
        let text = NSMutableAttributedString()
        for paragraph in 0..<6 {
            if paragraph > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(CanvasText.body("Incomprehensibilities notwithstanding, " + CanvasText.sentence(140, seed: paragraph), style: style))
        }
        let section = lines(of: text, width: size.width)
        let paginator = ReaderPaginator(text: text, size: size)
        var continued = 0
        for page in paginator.allPages {
            let pageText = paginator.text(for: page)
            if page.continuesParagraph {
                continued += 1
                let style = pageText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                XCTAssertEqual(style?.firstLineHeadIndent, style?.headIndent)
            }
            let expected = section.filter { NSLocationInRange($0.range.location, page.range) }
            let actual = lines(of: pageText, width: size.width).filter { $0.range.location < page.range.length }
            XCTAssertEqual(actual.map(\.range.length), expected.map(\.range.length), "page at \(page.range.location)")
            if let top = expected.first?.top {
                XCTAssertEqual(actual.last?.bottom ?? 0, (expected.last?.bottom ?? 0) - top, accuracy: 0.5)
            }
        }
        XCTAssertGreaterThan(continued, 0, "some pages continue a paragraph")
    }

    func testPaginationIsLazy() {
        let text = CanvasText.section(3, chapters: 1, paragraphs: 200)
        let paginator = ReaderPaginator(text: text, size: size)
        XCTAssertNotNil(paginator.page(at: 1))
        XCTAssertFalse(paginator.isComplete)
        XCTAssertLessThan(paginator.pages.count, 5)
        XCTAssertEqual(paginator.pageIndex(containing: text.length), paginator.allPages.count - 1)
        XCTAssertTrue(paginator.isComplete)
        XCTAssertNil(paginator.page(at: paginator.pages.count))
    }

    func testEmptySectionHasOnePage() {
        let paginator = ReaderPaginator(text: NSAttributedString(), size: size)
        XCTAssertEqual(paginator.allPages, [ReaderPage(range: NSRange(location: 0, length: 0), layoutEnd: 0, topSpacing: 0,
                                                       height: 0, continuesParagraph: false)])
        XCTAssertEqual(paginator.pageIndex(containing: 0), 0)
    }

    func testWritingDirectionFollowsTheFirstStrongCharacter() {
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "123 שלום world"), .rightToLeft)
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "— hello مرحبا"), .leftToRight)
        XCTAssertEqual(ReaderPaginator.writingDirection(of: "\u{2067}abc\u{2069} مرحبا"), .rightToLeft, "isolates are skipped")
        XCTAssertNil(ReaderPaginator.writingDirection(of: "1984, — !"))
    }

    /// About 1 MB of text: the first page is immediate, the whole section well under a second
    /// in release builds (the bounds here are generous for debug builds and shared machines).
    func testLongSectionPaginatesQuickly() {
        let paragraph = CanvasText.sentence(130, seed: 5)
        let text = NSMutableAttributedString()
        while text.length < 1_000_000 { text.append(CanvasText.body(paragraph + "\n")) }
        var start = Date()
        let paginator = ReaderPaginator(text: text, size: size)
        XCTAssertNotNil(paginator.page(at: 0))
        let first = Date().timeIntervalSince(start)
        XCTAssertLessThan(first, 0.25)
        start = Date()
        let count = paginator.allPages.count
        let all = Date().timeIntervalSince(start)
        XCTAssertLessThan(all, 3)
        print("1 MB section: first page \(first) s, all \(count) pages \(all) s")
    }
}
