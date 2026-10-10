import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Keeping an adjacent heading with its next paragraph must not split a float's visual group.
@MainActor final class BoxKeepWithNextTests: XCTestCase {
    func testKeptHeadingMovesItsEntireFloatGroupOrLeavesTheGroupIntact() throws {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: """
            <p>First leading line.<br/>Second leading line.</p>
            <figure><figcaption>Float caption.</figcaption></figure>
            <h2>Kept heading.</h2>
            <p class="following">Following paragraph begins below the figure and continues onto later pages.
            Every source character remains visible after the heading's keep adjustment.</p>
            """, css: """
            body,p,figure,figcaption,h2 { margin:0; padding:0; }
            p,figcaption,h2 { font-size:16px; line-height:20px; text-indent:0; }
            figure { float:left; width:100px; height:50px; }
            h2 { break-after:avoid; }
            .following { clear:left; }
            """))
        let section = SectionBuilder.build(.init(publication: publication, spineIndex: 0,
            typography: .init(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
        let size = CGSize(width: 360, height: 100)
        let paginator = ReaderPaginator(text: section.string, size: size)
        let pages = paginator.allPages
        let plan = try XCTUnwrap(paginator.text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage)
        let caption = (section.string.string as NSString).range(of: "Float caption.")
        let heading = (section.string.string as NSString).range(of: "Kept heading.")
        let group = try XCTUnwrap(plan.geometry.group(containing: caption.location))
        XCTAssertGreaterThan(group.location, 0, "The fixture needs leading source content before the atomic group")
        XCTAssertTrue(NSLocationInRange(heading.location, group), "The heading must wrap beside the figure")
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertTrue(pages.contains { $0.range.location <= group.location && $0.range.upperBound >= group.upperBound },
                      "Keep-with-next must retain the float and adjacent heading on the same page")
        var copied = "", cursor = 0
        for page in pages {
            XCTAssertEqual(page.range.location, cursor)
            cursor = page.range.upperBound
            XCTAssertLessThanOrEqual(page.height + page.topSpacing, size.height + 0.75)
            for candidate in plan.geometry.groups where NSIntersectionRange(candidate, page.range).length > 0 {
                XCTAssertGreaterThanOrEqual(candidate.location, page.range.location)
                XCTAssertLessThanOrEqual(candidate.upperBound, page.range.upperBound,
                                         "No page boundary may split an indivisible visual group")
            }
            let view = ReaderTextView(pageColumn: true)
            view.frame = CGRect(origin: .zero, size: size)
            view.readerContainer.size = CGSize(width: size.width, height: 0)
            view.readerContainer.viewportSize = size
            view.placement = .init(section: 0, offset: page.range.location, visibleLength: page.range.length)
            view.setContent(paginator.text(for: page))
            view.ensureFullLayout()
            copied += view.visibleText
            view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location,
                                                                  options: [.ensuresLayout]) { fragment in
                let start = view.offset(of: fragment.rangeInElement.location)
                for line in fragment.textLineFragments where line.characterRange.length > 0 {
                    let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
                    guard NSIntersectionRange(range, view.shownCharacters).length > 0 else { continue }
                    let frame = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                               dy: fragment.layoutFragmentFrame.minY)
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.75)
                    XCTAssertLessThanOrEqual(frame.maxY, page.height + 0.75)
                    XCTAssertLessThanOrEqual(frame.maxY + page.topSpacing, size.height + 0.75)
                }
                return true
            }
        }
        XCTAssertEqual(cursor, section.string.length)
        XCTAssertEqual(copied, section.string.readerPlainText())
    }
}
