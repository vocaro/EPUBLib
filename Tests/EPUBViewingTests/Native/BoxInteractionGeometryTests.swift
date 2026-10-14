import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// #225: the visual origin of a signed flow fragment is independent of its minimum edge.
@MainActor final class BoxInteractionGeometryTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 400, height: 600)

    func testLastParagraphOfMultiParagraphBoxesUsesDrawnLinesForLookupAndHits() throws {
        for declarations in ["float:left; width:100px", "position:absolute; left:220px; top:30px; width:100px"] {
            let section = try H.build("<figure><p>Top words here.</p><p>Bottom words wrap to more than one line here.</p></figure><p>After. \(H.prose)</p>",
                                      css: H.reset + "figure { \(declarations) }")
            let view = H.view(section.string, size: size)
            let bottom = H.range("Bottom words wrap to more than one line here.", in: section)
            let raw = PageTextGeometryTests.rawLines(in: view, intersecting: bottom)
            XCTAssertGreaterThan(raw.count, 1, declarations)
            let range = try XCTUnwrap(view.textRange(for: NSRange(location: bottom.location, length: 1)))
            let fragment = try XCTUnwrap(view.readerLayoutManager.textLayoutFragment(for: range.location))
            XCTAssertLessThan(fragment.layoutFragmentFrame.height, 0, "the fixture exercises a signed final fragment: \(declarations)")
            let harness = H.lines(in: view, intersecting: bottom)
            XCTAssertEqual(harness.map(\.range), raw.map(\.range))
            for (line, reported) in zip(raw, harness) {
                let lookedUp = try XCTUnwrap(view.line(containing: line.range.location))
                XCTAssertEqual(lookedUp.range, line.range)
                XCTAssertEqual(lookedUp.frame.minY, line.frame.minY, accuracy: 0.01, declarations)
                XCTAssertEqual(reported.frame.minY, line.frame.minY, accuracy: 0.01, declarations)
                // Native selection segments, rather than another frame conversion, establish
                // where TextKit draws the first visible character on this line.
                let drawn = try XCTUnwrap(view.segmentFrames(for: NSRange(location: line.range.location, length: 1)).first)
                XCTAssertEqual(lookedUp.frame.minY, drawn.minY, accuracy: 0.5, declarations)
                let local = CGPoint(x: drawn.midX, y: drawn.midY)
                let hit = view.characterOffset(at: CGPoint(x: local.x + view.containerOrigin.x, y: local.y + view.containerOrigin.y))
                XCTAssertTrue(line.range.location...min(line.range.upperBound, line.range.location + 1) ~= hit,
                              "hit \(hit) selects the drawn character at \(line.range.location): \(declarations)")
                let selected = try XCTUnwrap(view.readerLayoutManager.lineFragmentRange(for: local, inContainerAt: range.location))
                XCTAssertEqual(view.offset(of: selected.location), line.range.location, declarations)
                XCTAssertEqual(view.offset(of: selected.endLocation), line.range.upperBound, declarations)
            }
            let (paginator, pages) = H.pages(section, size: size, declarations)
            for page in pages {
                let shown = H.pageView(paginator, page: page)
                for line in PageTextGeometryTests.rawLines(in: shown, intersecting: shown.shownCharacters) {
                    XCTAssertGreaterThanOrEqual(line.frame.minY, -0.5, declarations)
                    XCTAssertLessThanOrEqual(line.frame.maxY + page.topSpacing, size.height + 0.75, declarations)
                }
            }
        }
    }

    func testClearedParagraphWithLaterBoxMatchesPlannedLinesAndDrawnPositions() throws {
        for width in ["100%", "100px"] {
            for fontSize: CGFloat in [12, 16, 19.3] {
                let label = "\(width), \(fontSize) pt"
                let section = try H.build("<p>Lead.</p><figure class='w'>Wide float.</figure><p class='m'>Cleared. \(H.prose)</p><figure class='x'>Later float.</figure><p>End words.</p>",
                                          css: H.reset + ".w { float:left; width:\(width); height:50px } .x { float:left; width:60px; height:75px } .m { clear:both }", fontSize: fontSize)
                let view = H.view(section.string, size: size)
                let geometry = try XCTUnwrap(view.readerContainer.boxPage?.geometry)
                let cleared = H.range("Cleared.", in: section)
                let paragraph = try XCTUnwrap(geometry.paragraph(at: cleared.location))
                let actual = PageTextGeometryTests.rawLines(in: view, intersecting: paragraph.range)
                XCTAssertEqual(actual.map(\.range), paragraph.lines.map(\.range), "planned line breaks: \(label)")
                let prior = try XCTUnwrap(H.region("Wide float.", in: section, view: view))
                XCTAssertEqual(paragraph.lines.first?.frame.minY ?? -1, prior.frame.maxY, accuracy: 0.5, label)
                for (line, planned) in zip(actual, paragraph.lines) {
                    XCTAssertEqual(line.frame.minX, planned.frame.minX, accuracy: 0.5, label)
                    XCTAssertEqual(line.frame.minY, planned.frame.minY, accuracy: 0.5, label)
                    let drawn = try XCTUnwrap(view.segmentFrames(for: NSRange(location: line.range.location, length: 1)).first)
                    XCTAssertEqual(drawn.minY, planned.frame.minY, accuracy: 0.5, "drawn position: \(label)")
                }
                let later = H.range("Later float.", in: section)
                let laterLine = try XCTUnwrap(geometry.paragraph(at: later.location)?.lines.first)
                XCTAssertEqual(try XCTUnwrap(view.segmentFrames(for: NSRange(location: later.location, length: 1)).first).minY,
                               laterLine.frame.minY, accuracy: 0.5, "later box keeps its plan: \(label)")
                H.pages(section, size: size, label)
            }
        }
    }

    func testClearWithoutShapesPreservesNativeLayoutAndPageRanges() throws {
        let body = "<p>Lead.</p><p class='m'>Cleared. \(H.prose)</p><p>End words. \(H.prose)</p>"
        let plain = try H.build(body, css: H.reset)
        let clear = try H.build(body, css: H.reset + ".m { clear:both }")
        let plainView = H.view(plain.string, size: size), clearView = H.view(clear.string, size: size)
        XCTAssertNil(plainView.readerContainer.boxPage)
        XCTAssertNil(clearView.readerContainer.boxPage)
        let original = PageTextGeometryTests.rawLines(in: plainView, intersecting: plainView.shownCharacters)
        let actual = PageTextGeometryTests.rawLines(in: clearView, intersecting: clearView.shownCharacters)
        XCTAssertEqual(actual.map(\.range), original.map(\.range))
        XCTAssertEqual(actual.map(\.frame), original.map(\.frame))
        XCTAssertEqual(H.pages(clear, size: size).pages, H.pages(plain, size: size).pages)
    }
}
