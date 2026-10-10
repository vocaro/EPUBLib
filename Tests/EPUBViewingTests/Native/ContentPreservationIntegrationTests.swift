import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class ContentPreservationIntegrationTests: XCTestCase {
    private func section(_ body: String, css: String) throws -> SectionText {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css))
        return SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: .init(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
    }

    func testBoxedTableCellKeepsItsWidthAndAllTextAcrossContinuations() throws {
        let words = (0..<200).map { "word\($0)" }
        let source = try section("""
            <table><tr><td><aside>\(words.joined(separator: " "))</aside></td><td>Other cell</td></tr></table>
            """, css: "table { width: 100%; } td:first-child { width: 80%; } aside { position: absolute; width: 50%; }")
        let row = try XCTUnwrap(RichFixture.attachments(in: source.string).first as? TableRowAttachment)
        let viewport = CGSize(width: 400, height: 300)
        let layout = row.layout(width: viewport.width, viewportHeight: viewport.height)
        let index = try XCTUnwrap(row.table.cells.firstIndex { $0.content.string.contains("word0") })
        let cell = row.table.cells[index]
        let unboxed = NSMutableAttributedString(attributedString: cell.content)
        unboxed.removeAttribute(.readerFlowBox, range: NSRange(location: 0, length: unboxed.length))
        let fullWidth = TableCellLayout(unboxed, width: layout.contentFrames[index].width, viewportHeight: viewport.height)
        XCTAssertGreaterThan(layout.cellText[index].lines.count, fullWidth.lines.count,
                             "The callout must wrap within its box inside the cell")
        let paginator = ReaderPaginator(text: source.string, size: viewport)
        let pages = paginator.allPages
        let spoken = pages.flatMap(\.tableFragments).map { $0.attachment.textEquivalent }.joined(separator: " ")
        XCTAssertEqual(spoken.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("word") }.map(String.init), words)
        XCTAssertEqual(paginator.text.string, source.string.string)
        XCTAssertTrue(pages.allSatisfy { $0.height <= viewport.height + 0.5 })
    }

    func testContinuedTableUsesTheWidthOfItsEnclosingCallout() throws {
        let words = (0..<200).map { "word\($0)" }
        let source = try section("""
            <aside><table><tr><td>\(words.joined(separator: " "))</td><td>Other</td></tr></table></aside>
            """, css: "aside { position: absolute; width: 60%; margin-top: 32px; } table { width: 100%; }")
        for width: CGFloat in [240, 400] {
            let viewport = CGSize(width: width, height: 300)
            let paginator = ReaderPaginator(text: source.string, size: viewport)
            let pages = paginator.allPages
            let fragments = pages.flatMap(\.tableFragments)
            XCTAssertGreaterThan(fragments.count, 1)
            for entry in fragments {
                let style = try XCTUnwrap(paginator.text.attribute(.paragraphStyle, at: entry.offset,
                                                                  effectiveRange: nil) as? NSParagraphStyle)
                let available = width - style.headIndent + style.tailIndent
                let layout = entry.attachment.layout(width: width, viewportHeight: viewport.height)
                XCTAssertEqual(layout.lineWidth * layout.scale, available, accuracy: 1)
                XCTAssertLessThan(layout.lineWidth * layout.scale, width * 0.8)
            }
            let spoken = fragments.map { $0.attachment.textEquivalent }.joined(separator: " ")
            XCTAssertEqual(spoken.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("word") }.map(String.init), words)
            XCTAssertTrue(pages.allSatisfy { $0.height + $0.topSpacing <= viewport.height + 0.5 })
        }
    }
}
