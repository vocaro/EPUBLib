import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class LongParagraphPaginationTests: XCTestCase {
    private struct Line {
        let range: NSRange
        let top: CGFloat
        let bottom: CGFloat
    }

    private func lines(_ text: NSAttributedString, width: CGFloat) -> [Line] {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = ReaderTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.attributedString = text
        var result: [Line] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                result.append(Line(range: NSRange(location: start + line.characterRange.location, length: line.characterRange.length),
                                   top: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
                                   bottom: fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY))
            }
            return true
        }
        return result
    }

    private func fixture(fontSize: CGFloat = 17, rtl: Bool = false) -> NSAttributedString {
        let style = CanvasText.bodyStyle(alignment: .justified, hyphenates: true, indent: 24)
        let paragraph = rtl ? String(repeating: "שלום עולם הספר הארוך ממשיך עם מילים שונות ובדיקת שורות. ", count: 230)
            : (0..<120).map { CanvasText.sentence(30 + $0 % 9, seed: $0) }.joined(separator: " ")
        let text = NSMutableAttributedString(attributedString: CanvasText.body(paragraph + "\n", style: style, size: fontSize))
        text.append(CanvasText.body("Following block has more words to wrap onto several additional lines. " + CanvasText.sentence(100, seed: 11), size: fontSize))
        return text
    }

    func testLongParagraphTailAndFollowingBlockUseMeasuredLines() throws {
        for rtl in [false, true] {
            for font in [CGFloat(17), 29] {
                var checkedTail = false
                for width in [CGFloat(237), 320, 431] {
                    let size = CGSize(width: width, height: 500)
                    let text = fixture(fontSize: font, rtl: rtl)
                    let paragraphEnd = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)).upperBound
                    XCTAssertGreaterThan(paragraphEnd, ReaderPaginator.wholeParagraphJustification)
                    let paginator = ReaderPaginator(text: text, size: size)
                    let pages = paginator.allPages
                    let measured = lines(paginator.text, width: width)
                    XCTAssertEqual(pages.first?.range.location, 0)
                    XCTAssertEqual(pages.last?.range.upperBound, text.length)
                    for (page, next) in zip(pages, pages.dropFirst()) {
                        XCTAssertEqual(page.range.upperBound, next.range.location)
                    }
                    XCTAssertEqual(pages.map { (text.string as NSString).substring(with: $0.range) }.joined(), text.string)
                    for page in pages {
                        let displayed = lines(paginator.text(for: page), width: width).filter { $0.range.location < page.range.length }
                        let expected = measured.filter { NSLocationInRange($0.range.location, page.range) }
                        let label = "width \(width), font \(font), rtl \(rtl), offset \(page.range.location)"
                        XCTAssertEqual(displayed.map(\.range.length),
                                       page.measuredLineLengths ?? expected.map(\.range.length), label)
                        XCTAssertEqual(displayed.last?.range.upperBound, page.range.length, label)
                        XCTAssertEqual(paginator.text(for: page).attributedSubstring(from: NSRange(location: 0, length: page.range.length)).string,
                                       (text.string as NSString).substring(with: page.range), label)
                        XCTAssertEqual(displayed.last?.bottom ?? 0, page.height + page.topSpacing, accuracy: 0.5, label)
                        XCTAssertLessThanOrEqual(page.height + page.topSpacing, size.height + 0.5, label)
                        XCTAssertLessThanOrEqual(paginator.text(for: page).length - page.range.length,
                                                 ReaderPaginator.wholeParagraphJustification * 2 + 50, label)
                        if page.continuesParagraph && page.range.location < paragraphEnd && page.range.upperBound > paragraphEnd {
                            checkedTail = true
                        }
                    }
                }
                XCTAssertTrue(checkedTail, "fixture includes a mid-paragraph page also showing the following block")
            }
        }
    }

    func testNativeColumnsResizeAndSelectAtTheLongParagraphTail() async throws {
        for rtl in [false, true] {
            for font in [CGFloat(17), 29] {
                let text = fixture(fontSize: font, rtl: rtl)
                let paragraphEnd = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)).upperBound
                let target = paragraphEnd - 220
                let selection = ReaderTextRange(section: 0, target..<(target + 20))
                let host = CanvasHost(FakeCanvasSource([text]), size: CGSize(width: 400, height: 620),
                                      configuration: ReaderCanvasConfiguration(isRightToLeft: rtl))
                defer { host.close() }
                host.canvas.show(selection.start, selecting: selection)
                host.layOut()
                XCTAssertEqual(host.canvas.currentSelection?.range, selection)
                XCTAssertEqual(host.canvas.currentSelection?.text, (text.string as NSString).substring(with: NSRange(location: target, length: 20)))
                for size in [CGSize(width: 400, height: 620), CGSize(width: 1000, height: 620), CGSize(width: 500, height: 700)] {
                    host.resize(to: size)
                    try await host.settle()
                    host.layOut()
                    let spread = try XCTUnwrap(host.canvas.spread)
                    XCTAssertEqual(spread.columns.count, size.width == 1000 ? 2 : 1)
                    let visible = try XCTUnwrap(host.canvas.visibleRange)
                    XCTAssertLessThanOrEqual(visible.start.offset, target)
                    XCTAssertGreaterThan(visible.end.offset, target)
                    XCTAssertEqual(host.recorder.shown.last?.range, visible)
                    let paginator = ReaderPaginator(text: text, size: spread.columnSize)
                    for column in host.canvas.textViews {
                        let page = try XCTUnwrap(paginator.page(at: paginator.pageIndex(containing: column.placement.offset)))
                        XCTAssertEqual(column.placement.visibleLength, page.range.length)
                        XCTAssertEqual(column.visibleText, (text.string as NSString).substring(with: page.range))
                        var cursor = 0
                        var actualLengths: [Int] = []
                        while cursor < column.placement.visibleLength {
                            let line = try XCTUnwrap(column.line(containing: cursor))
                            XCTAssertEqual(line.range.location, cursor)
                            XCTAssertLessThanOrEqual(line.range.upperBound, column.placement.visibleLength)
                            XCTAssertLessThanOrEqual(line.frame.maxY, column.frame.height + 0.5)
                            actualLengths.append(line.range.length)
                            cursor = line.range.upperBound
                        }
                        XCTAssertEqual(cursor, column.placement.visibleLength)
                        if let canonical = page.measuredLineLengths { XCTAssertEqual(actualLengths, canonical) }
                        XCTAssertLessThanOrEqual(column.frame.height, spread.columnSize.height + 0.5)
                    }
                }
            }
        }
    }

    func testLongParagraphBeforeTableRetainsEveryContinuation() throws {
        let words = (0..<300).map { "word\($0)" }
        let fixture = try RichFixture("<table id='t'><tr><td>\(words.joined(separator: " "))</td><td>Other cell</td></tr></table>")
        let text = NSMutableAttributedString(attributedString: self.fixture())
        // End with the long paragraph directly, so the table is the following block.
        let paragraphEnd = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)).upperBound
        text.deleteCharacters(in: NSRange(location: paragraphEnd, length: text.length - paragraphEnd))
        text.append(try XCTUnwrap(fixture.table("t")))
        text.append(CanvasText.body("\nFollowing table conclusion."))
        for width in [CGFloat(237), 320, 431] {
            let paginator = ReaderPaginator(text: text, size: CGSize(width: width, height: 500))
            let pages = paginator.allPages
            XCTAssertEqual(pages.last?.range.upperBound, text.length)
            let spoken = pages.flatMap(\.tableFragments).map { $0.attachment.textEquivalent }.joined(separator: " ")
            XCTAssertEqual(spoken.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("word") }.map(String.init), words)
            for page in pages {
                XCTAssertLessThanOrEqual(page.height + page.topSpacing, 500.5)
                for entry in page.tableFragments { XCTAssertTrue(NSLocationInRange(entry.offset, page.range)) }
            }
        }
    }

    func testContinuedTailKeepsFirstCharacterMarkedHeadingWithItsBody() throws {
        for rtl in [false, true] {
            let text = NSMutableAttributedString(attributedString: fixture(rtl: rtl))
            let paragraphEnd = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)).upperBound
            text.deleteCharacters(in: NSRange(location: paragraphEnd, length: text.length - paragraphEnd))
            let headingStart = text.length
            let heading = NSMutableAttributedString(attributedString: CanvasText.body("Following heading\n"))
            heading.addAttribute(.readerKeepWithNext, value: true, range: NSRange(location: 0, length: 1))
            text.append(heading)
            let headingEnd = text.length
            text.append(CanvasText.body(CanvasText.sentence(100, seed: 11)))
            XCTAssertNil(text.attribute(.readerKeepWithNext, at: headingEnd - 1, effectiveRange: nil))
            XCTAssertEqual(text.attribute(.readerKeepWithNext, at: headingStart, effectiveRange: nil) as? Bool, true)
            for width in [CGFloat(237), 320, 431] {
                for height in [CGFloat(400), 500] {
                    let pages = ReaderPaginator(text: text, size: CGSize(width: width, height: height)).allPages
                    if let orphan = pages.first(where: { $0.range.upperBound == headingEnd }) {
                        XCTFail("Heading stranded at width \(width), height \(height), rtl \(rtl), offset \(orphan.range.location)")
                        return
                    }
                }
            }
        }
    }
}
