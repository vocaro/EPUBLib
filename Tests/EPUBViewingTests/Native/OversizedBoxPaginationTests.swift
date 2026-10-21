import EPUBTestSupport
import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A sized inline block taller than a page stays in flow, and the rest of it from one of its
/// paragraphs on is set as a box where that rest fits a page. The Cambridge Shakespeare
/// (Project Gutenberg #50559) sets each scene of a play so: one inline block of hundreds of
/// verse lines, whose pagination took minutes of main-thread work (#573).
@MainActor final class OversizedBoxPaginationTests: XCTestCase {
    /// The book's own rules for its scenes.
    static let css = """
    .container { margin-left: 2em }
    .poem { display: inline-block; margin-left: 5%; text-align: left; min-width: 25em; max-width: 50em }
    .poem .stanza { margin: 1em 0 1em 0 }
    .poem .i0 { display: block; margin-left: 0; padding-left: 3em; text-indent: -3em }
    .stagecenter { text-align: center; margin-left: 5%; margin-right: 5% }
    .personae { font-style: italic; padding-left: 1em }
    h2 { text-align: center }
    p { text-align: justify }
    """

    static func verse(_ seed: inout UInt64, words: Int) -> String {
        let vocabulary = ["thou", "art", "perfect", "then", "our", "ship", "hath", "touch'd", "upon", "the", "deserts",
                          "of", "Bohemia", "my", "lord", "and", "fear", "we", "have", "landed", "in", "ill", "time",
                          "skies", "look", "grimly", "threaten", "present", "blusters", "conscience", "heavens", "angry"]
        return (0..<words).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return vocabulary[Int(seed >> 33) % vocabulary.count]
        }.joined(separator: " ")
    }

    /// `count` scenes of `lines` verse lines each, in stanzas of four, as the book marks them up.
    static func scenes(_ count: Int, lines: Int) -> String {
        var seed: UInt64 = 7
        var body = "<div class=\"container\">"
        for scene in 0..<count {
            body += "<h2>Scene \(scene + 1)</h2><div class=\"poem\"><div class=\"stanza\"><div class=\"stagecenter\"><i>Enter</i> a Mariner.</div></div>"
            for line in 0..<lines {
                if line % 4 == 0 { body += (line > 0 ? "</div>" : "") + "<div class=\"stanza\">" }
                let speaker = line % 4 == 0 ? "<i class=\"personae\">Ant.</i> " : ""
                body += "<div class=\"i0\">\(speaker)\(verse(&seed, words: 6 + Int(seed % 5)))</div>"
            }
            body += "</div></div>"
        }
        return body + "</div>"
    }

    static func section(scenes count: Int, lines: Int, fontSize: CGFloat) throws -> NSAttributedString {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: scenes(count, lines: lines), css: css))
        return SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: NativeTypography(fontSize: fontSize), fonts: FontRegistry(publication: publication), rich: NativeRichContent())).string
    }

    /// The reader's column for a viewport, as `ReaderCanvasView` paginates it.
    static func column(_ viewport: CGSize) -> CGSize {
        ReaderCanvasGeometry.spread(in: CGRect(origin: .zero, size: viewport), division: nil, isRightToLeft: false).columnSize
    }

    private static func ranges(_ pairs: [(Int, Int)]) -> [NSRange] { pairs.map { NSRange(location: $0.0, length: $0.1) } }

    /// Every attempt at the rest of the scene measured its max-content and laid it out again:
    /// 17 s of release CPU for these 400 lines at phone size on 777515cf, and 96 s for 800.
    func testAPageTallSceneIsPaginatedInTimeLinearInItsLength() throws {
        for (viewport, fontSize) in [(CGSize(width: 390, height: 844), CGFloat(17)), (CGSize(width: 820, height: 1180), 19)] {
            let text = try Self.section(scenes: 1, lines: 400, fontSize: fontSize)
            var pages: [ReaderPage] = []
            var regions: [ReaderBoxGeometry.Region] = []
            let seconds = TestCPUClock.measure {
                let paginator = ReaderPaginator(text: text, size: Self.column(viewport))
                pages = paginator.allPages
                regions = (paginator.text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage)?.geometry.regions ?? []
            }
            print("A 400-line scene at \(viewport), \(fontSize) pt: \(pages.count) pages in \(seconds) CPU s")
            XCTAssertLessThan(seconds, 3, "A 400-line scene at \(viewport), \(fontSize) pt: \(pages.count) pages")
            // The scene is taller than a page, and the rest of it that fits one is a box.
            XCTAssertGreaterThan(pages.count, 10)
            let box = try XCTUnwrap(regions.first { !$0.reserved }, "The scene's last page is set as a box")
            XCTAssertEqual(box.range.upperBound, text.length)
            XCTAssertLessThanOrEqual(try XCTUnwrap(pages.last).range.location, box.range.location, "The box is on one page")
            XCTAssertEqual(pages.first?.range.location, 0)
            for (page, next) in zip(pages, pages.dropFirst()) { XCTAssertEqual(page.range.upperBound, next.range.location) }
            XCTAssertEqual(pages.last.map(\.range.upperBound), text.length)
        }
    }

    /// The pages of a 100-line scene as 777515cf cut them, before #573's fix, at the phone and
    /// tablet columns on the Mac and in the iOS 27 simulator, whose fonts break some lines
    /// elsewhere. The rest of the scene that fits a page is the box that starts the last page.
    ///
    /// The phone's last two pages are cut as #150 has them, on both platforms. The scene's inline block takes its
    /// width from its container's content box, 2em inside the column (CSS 2.2 10.1), where it
    /// took the whole column's: its `min-width` of 25em is wider than either, so it is as wide
    /// as it may be, now 34 points narrower. More of its verse wraps, so the rest that fits a
    /// page starts later and the page before it ends there. The tablet's block is narrower than
    /// both widths and is unchanged.
    func testAPageTallScenesPagesAndTheRestSetAsABox() throws {
        #if os(macOS)
        let phone = Self.ranges([(0, 590), (590, 699), (1289, 696), (1985, 731), (2716, 663), (3379, 657), (4036, 782)])
        let tablet = Self.ranges([(0, 1368), (1368, 1599), (2967, 256), (3223, 1595)])
        #else
        let phone = Self.ranges([(0, 590), (590, 699), (1289, 682), (1971, 728), (2699, 627), (3326, 710), (4036, 782)])
        let tablet = Self.ranges([(0, 1368), (1368, 1635), (3003, 220), (3223, 1595)])
        #endif
        let expected: [(viewport: CGSize, fontSize: CGFloat, pages: [NSRange])] = [
            (CGSize(width: 390, height: 844), 17, phone), (CGSize(width: 820, height: 1180), 19, tablet),
        ]
        for entry in expected {
            let text = try Self.section(scenes: 1, lines: 100, fontSize: entry.fontSize)
            XCTAssertEqual(text.length, 4818)
            let paginator = ReaderPaginator(text: text, size: Self.column(entry.viewport))
            XCTAssertEqual(paginator.allPages.map(\.range), entry.pages, "\(entry.viewport) at \(entry.fontSize) pt")
            let regions = (paginator.text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage)?.geometry.regions ?? []
            XCTAssertEqual(regions.filter { !$0.reserved }.map(\.range), [NSRange(location: entry.pages.last!.location,
                                                                                  length: text.length - entry.pages.last!.location)])
        }
    }
}
