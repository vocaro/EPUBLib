import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class BoxPreflightTests: XCTestCase {
    func testFirstFloatPreflightsOnlyNearbyLinesAndPreservesOneMegabyteTail() throws {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(
            body: "<figure>Short floating caption.</figure>",
            css: "body,figure {margin:0;padding:0;} figure {float:left;width:120px;height:100px;}"))
        let caption = SectionBuilder.build(.init(publication: publication, spineIndex: 0,
            typography: .init(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent())).string
        let sentence = CanvasText.sentence(130, seed: 5)
        let size = CGSize(width: 500, height: 700)
        for singleParagraph in [false, true] {
            let prose = NSMutableAttributedString()
            if singleParagraph {
                let body = "Opening prose. " + Array(repeating: sentence,
                    count: 1_000_000 / sentence.utf16.count + 1).joined(separator: " ") + " Final tail complete.\n"
                prose.append(CanvasText.body(body))
            } else {
                prose.append(CanvasText.body("Opening prose. " + sentence + "\n"))
                while prose.length < 1_000_000 { prose.append(CanvasText.body(sentence + "\n")) }
                prose.append(CanvasText.body("Final tail complete.\n"))
            }
            let text = NSMutableAttributedString(attributedString: caption)
            // SectionBuilder trims a section's final paragraph terminator. Restore it before
            // appending ordinary prose so that the float remains a separate native paragraph.
            text.append(NSAttributedString(string: "\n", attributes: caption.attributes(at: caption.length - 1, effectiveRange: nil)))
            text.append(prose)
            let start = Date()
            let paginator = ReaderPaginator(text: text, size: size)
            let initialized = Date().timeIntervalSince(start)
            let plan = try XCTUnwrap((paginator.text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage)?.geometry)
            let plannedLines = plan.paragraphs.flatMap(\.lines)
            XCTAssertFalse(plan.regions.isEmpty, "The performance fixture must retain its actual float")
            XCTAssertGreaterThan(plannedLines.count, 1)
            XCTAssertLessThan(plannedLines.count, 500, "Ordinary distant prose must not enter the visual preflight")
            XCTAssertLessThan(plannedLines.map { $0.range.upperBound }.max() ?? 0, text.length / 10)
            XCTAssertEqual(paginator.text.string, text.string, "Bounded preflight must retain all source characters")
            XCTAssertTrue(paginator.pages.isEmpty)

            let firstStart = Date()
            let first = try XCTUnwrap(paginator.page(at: 0))
            let firstTime = Date().timeIntervalSince(firstStart)
            XCTAssertEqual(paginator.pages.count, 1)
            XCTAssertFalse(paginator.isComplete)
            XCTAssertTrue(paginator.holdsLayout)
            XCTAssertLessThan(paginator.paginatedLength, text.length / 100)
            if !singleParagraph {
                XCTAssertLessThan(paginator.heldLayoutLength, text.length / 10,
                                  "Opening a section must leave distant native paragraphs unmeasured")
            }
            let firstView = view(paginator, page: first)
            let firstCharacters = firstView.contentStorage.textStorage!.string as NSString
            let opening = firstCharacters.range(of: "Opening prose.")
            let openingFrame = try XCTUnwrap(firstView.lineFrame(containing: opening.location))
            let region = try XCTUnwrap(plan.regions.first { !$0.reserved })
            XCTAssertLessThan(openingFrame.minY, region.frame.maxY)
            XCTAssertGreaterThanOrEqual(openingFrame.minX, region.frame.maxX - 0.75,
                                        "The bounded preflight must still wrap the first native line beside the float")
            XCTAssertLessThanOrEqual(openingFrame.maxY, first.height + 0.75)
            XCTAssertEqual(firstView.visibleText, (text.string as NSString).substring(with: first.range))

            let restStart = Date()
            let pages = paginator.allPages
            let remaining = Date().timeIntervalSince(restStart)
            XCTAssertGreaterThan(pages.count, 100)
            XCTAssertTrue(paginator.isComplete)
            XCTAssertFalse(paginator.holdsLayout)
            var displayed = "", cursor = 0
            for page in pages {
                XCTAssertEqual(page.range.location, cursor, "Every original source character is reached exactly once")
                XCTAssertLessThanOrEqual(page.height + page.topSpacing, size.height + 0.75)
                let pageText = paginator.text(for: page).string as NSString
                displayed += pageText.substring(to: page.range.length)
                cursor = page.range.upperBound
            }
            XCTAssertEqual(cursor, text.length)
            XCTAssertEqual(displayed, text.string)
            let last = try XCTUnwrap(pages.last)
            let lastView = view(paginator, page: last)
            XCTAssertTrue(lastView.visibleText.contains("Final tail complete."))
            XCTAssertEqual(lastView.visibleText, (text.string as NSString).substring(with: last.range))
            let tail = (lastView.contentStorage.textStorage!.string as NSString).range(of: "Final tail complete.")
            let tailFrame = try XCTUnwrap(lastView.lineFrame(containing: tail.location))
            XCTAssertGreaterThanOrEqual(tailFrame.minY, -0.75)
            XCTAssertLessThanOrEqual(tailFrame.maxY, last.height + 0.75)
            print("1 MB float preflight: oneParagraph=\(singleParagraph), plannedLines=\(plannedLines.count), init=\(initialized)s, firstPage=\(firstTime)s, remaining \(pages.count) pages=\(remaining)s")
        }
    }

    private func view(_ paginator: ReaderPaginator, page: ReaderPage) -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.frame = CGRect(origin: .zero, size: CGSize(width: paginator.size.width, height: paginator.size.height - page.topSpacing))
        view.readerContainer.size = CGSize(width: paginator.size.width, height: 0)
        view.readerContainer.viewportSize = paginator.size
        view.placement = .init(section: 0, offset: page.range.location, visibleLength: page.range.length)
        view.setContent(paginator.text(for: page))
        view.ensureFullLayout()
        return view
    }
}
