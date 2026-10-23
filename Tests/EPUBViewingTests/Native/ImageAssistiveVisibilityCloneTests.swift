import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing

/// Layout may replace an image attachment to resolve its size. The replacement keeps the
/// publisher's assistive visibility while its alternative remains available to Copy/search,
/// and the language its words are in (#548).
@MainActor final class ImageAssistiveVisibilityCloneTests: XCTestCase {
    private let words = "Kept illustration words"
    private let visibility: [(markup: String, hidden: Bool)] = [
        ("aria-hidden='true'", true),
        ("role='presentation'", true),
        ("aria-hidden='false'", false)
    ]

    func testFloatedImageResolutionPreservesAssistiveVisibilityAndWords() throws {
        let viewport = CGSize(width: 360, height: 600)
        for side in ["left", "right"] {
            for item in visibility {
                let section = try RichMediaBook(body:
                    "<p><img id='image' src='picture.png' alt='\(words)' lang='fr' \(item.markup)/></p><p>Following prose.</p>",
                    files: ["picture.png": RichMediaImages.solid(width: 240, height: 192)],
                    head: "<style>body,p{margin:0;padding:0}img{float:\(side);width:120px;height:96px}</style>").build()
                let original = try XCTUnwrap(section.richMediaImages.first)
                let offset = try XCTUnwrap(section.anchors["image"])
                let result = ReaderBoxLayout.resolve(section.string, viewport: viewport)
                XCTAssertNotNil(result.geometry, "The fixture exercises float resolution")
                let clone = try image(in: result.text, at: offset)
                XCTAssertFalse(clone === original, "Float sizing must actually replace the attachment")
                XCTAssertEqual(clone.sizing.size(lineWidth: viewport.width, viewport: viewport,
                    heightLimit: viewport.height), CGSize(width: 120, height: 96))
                assertVisibilityAndWords(clone, in: result.text, at: offset, hidden: item.hidden)
                XCTAssertEqual(section.string.string, result.text.string, "Source coordinates stay intact")
            }
        }
    }

    func testPageFittedImagePreservesAssistiveVisibilityAndWords() throws {
        let viewport = CGSize(width: 200, height: 200)
        for item in visibility {
            let section = try RichMediaBook(body:
                "<p><img id='image' src='picture.png' alt='\(words)' lang='fr' \(item.markup) style='width:100px;height:400px'/></p>",
                files: ["picture.png": RichMediaImages.solid(width: 100, height: 400)]).build()
            let offset = try XCTUnwrap(section.anchors["image"])
            let paginator = ReaderPaginator(text: section.string, size: viewport)
            let original = try image(in: paginator.text, at: offset)
            // A flow-fallback page has less room than the ordinary viewport: this exercises
            // the production page-slice fitting path, independently of TextKit's page plan.
            let page = ReaderPage(range: NSRange(location: 0, length: section.string.length),
                layoutEnd: section.string.length, topSpacing: 40, height: 159,
                continuesParagraph: false, usesFlowFallback: true)
            let fitted = paginator.text(for: page)
            let clone = try image(in: fitted, at: offset)
            XCTAssertFalse(clone === original, "Page fitting must actually replace the attachment")
            let originalSize = original.sizing.size(lineWidth: viewport.width, viewport: viewport,
                heightLimit: viewport.height)
            let fittedSize = clone.sizing.size(lineWidth: viewport.width, viewport: viewport,
                heightLimit: viewport.height)
            XCTAssertGreaterThan(originalSize.height, 159)
            XCTAssertEqual(fittedSize.height, 159, accuracy: 0.001)
            XCTAssertLessThan(fittedSize.height, originalSize.height)
            assertVisibilityAndWords(clone, in: fitted, at: offset, hidden: item.hidden)
            XCTAssertEqual(section.string.string, fitted.string, "Source coordinates stay intact")
        }
    }

    private func image(in text: NSAttributedString, at offset: Int) throws -> ReaderImageAttachment {
        try XCTUnwrap(text.attribute(.attachment, at: offset, effectiveRange: nil) as? ReaderImageAttachment)
    }

    private func assertVisibilityAndWords(_ image: ReaderImageAttachment, in text: NSAttributedString,
                                          at offset: Int, hidden: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let range = NSRange(location: offset, length: 1)
        XCTAssertEqual(image.isHiddenFromAssistiveTechnology, hidden, file: file, line: line)
        XCTAssertEqual(image.isPassedOverByAssistiveTechnology, hidden, file: file, line: line)
        XCTAssertEqual(image.textEquivalent, words, file: file, line: line)
        XCTAssertEqual(image.spokenEquivalent, hidden ? "" : words, file: file, line: line)
        XCTAssertEqual(image.textLanguage, "fr", "the language of the element its words come from", file: file, line: line)
        XCTAssertEqual(text.readerPlainText(in: range, spoken: true), hidden ? "" : words, file: file, line: line)
        XCTAssertEqual(text.readerPlainText(in: range), words, "The selection/search projection keeps the words", file: file, line: line)
        XCTAssertEqual(text.readerCopyPlainText(in: range), words, file: file, line: line)
    }
}
