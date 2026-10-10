import CoreGraphics
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing

/// Source order and visual Y order diverge when a float shares rows with following prose.
final class ReaderVisualLineTests: XCTestCase {
    private func line(_ offset: Int, _ length: Int, x: CGFloat, y: CGFloat, width: CGFloat = 100,
                      height: CGFloat = 20) -> ReaderVisualLine {
        ReaderVisualLine(frame: CGRect(x: x, y: y, width: width, height: height),
                         range: NSRange(location: offset, length: length))
    }

    func testViewportIncludesLeftFloatAndAdjacentLaterSourceText() {
        let lines = [line(0, 30, x: 0, y: 0), line(30, 30, x: 0, y: 20),
                     line(100, 40, x: 120, y: 0), line(140, 40, x: 120, y: 20),
                     line(180, 40, x: 0, y: 40)]
        XCTAssertEqual(ReaderVisualLine.sourceRange(intersecting: CGRect(x: 0, y: 20, width: 300, height: 20), in: lines),
                       NSRange(location: 30, length: 150))
        // Once the float has ended, it must stop keeping its earlier source text in the range.
        XCTAssertEqual(ReaderVisualLine.sourceRange(intersecting: CGRect(x: 0, y: 40, width: 300, height: 20), in: lines),
                       NSRange(location: 180, length: 40))
    }

    func testViewportIncludesRightFloatAndPositionedTextInAnySourceOrder() {
        let lines = [line(300, 50, x: 200, y: 10), line(80, 40, x: 0, y: 10),
                     line(0, 30, x: 0, y: -50), line(350, 30, x: 0, y: 200)]
        XCTAssertEqual(ReaderVisualLine.sourceRange(intersecting: CGRect(x: 0, y: 10, width: 300, height: 20), in: lines),
                       NSRange(location: 80, length: 270))
        XCTAssertEqual(ReaderVisualLine.sourceRange(intersecting: CGRect(x: 0, y: 10, width: 150, height: 20), in: lines),
                       NSRange(location: 80, length: 40), "The horizontal viewport also limits visibility")
    }

    func testBoundariesUseTheWholeVisualRowInsteadOfTheLeftEdgeFragment() {
        let lines = [line(0, 30, x: 0, y: 0), line(30, 30, x: 0, y: 20),
                     line(100, 40, x: 120, y: 0), line(140, 40, x: 120, y: 20)]
        XCTAssertEqual(ReaderVisualLine.boundary(at: 10, lineEnd: false, in: lines, length: 180), 0)
        XCTAssertEqual(ReaderVisualLine.boundary(at: 10, lineEnd: true, in: lines, length: 180), 140)
        XCTAssertEqual(ReaderVisualLine.boundary(at: 30, lineEnd: false, in: lines, length: 180), 30)
        XCTAssertEqual(ReaderVisualLine.boundary(at: 30, lineEnd: true, in: lines, length: 180), 180)
        XCTAssertEqual(ReaderVisualLine.boundary(at: -10, lineEnd: true, in: lines, length: 180), 0)
        XCTAssertEqual(ReaderVisualLine.boundary(at: 100, lineEnd: false, in: lines, length: 180), 180)
    }

    @MainActor func testNativeFloatAndAdjacentBodyKeepBothSourceRangesAndBodyAnchor() throws {
        let xhtml = StyleTestSupport.xhtml(body:
            "<aside id=\"float\">Float caption with several words.</aside>"
            + "<p id=\"body\">Body prose wraps beside the float and continues beneath its final line.</p>",
            css: "#float { float:left; width:100px; margin:0; } p { margin:0; }")
        let publication = try StyleTestSupport.publication(section: xhtml)
        let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: NativeTypography(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
        let view = ReaderTextView(pageColumn: false)
        view.readerContainer.widthTracksTextView = false
        view.readerContainer.size = CGSize(width: 300, height: 10_000)
        view.readerContainer.viewportSize = CGSize(width: 300, height: 400)
        view.setContent(section.string)
        view.ensureFullLayout()
        XCTAssertTrue(view.readerContainer.hasNonlinearGeometry)
        let floatOffset = try XCTUnwrap(section.anchors["float"])
        let bodyOffset = try XCTUnwrap(section.anchors["body"])
        let floating = try XCTUnwrap(view.line(containing: floatOffset))
        let body = try XCTUnwrap(view.line(containing: bodyOffset))
        let region = try XCTUnwrap(view.readerContainer.boxRegions.first { NSLocationInRange(floatOffset, $0.range) })
        XCTAssertEqual(floating.frame.minY, body.frame.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(body.frame.minX, region.frame.maxX - 0.5,
                                   "Adjacent body text starts beyond the float's authored exclusion edge")
        XCTAssertTrue(view.fragment(atContainerY: body.frame.midY, holds: bodyOffset),
                      "The left float at the same Y must not invalidate the body's source anchor")
        let top = min(floating.frame.minY, body.frame.minY)
        let bottom = max(floating.frame.maxY, body.frame.maxY)
        let visible = try XCTUnwrap(view.visibleCharacterRange(in: CGRect(x: 0, y: top, width: 300, height: bottom - top)))
        XCTAssertTrue(NSLocationInRange(floatOffset, visible))
        XCTAssertTrue(NSLocationInRange(bodyOffset, visible))
    }

    @MainActor func testFinalFloatRetainsItsVisualBottomAndSourceLines() throws {
        let xhtml = StyleTestSupport.xhtml(body:
            "<p>Leading body prose.</p><aside id=\"float\">"
            + "A final floated callout retains every line of selectable native text.</aside>",
            css: "#float { float:right; width:100px; margin:0; } p { margin:0; }")
        let publication = try StyleTestSupport.publication(section: xhtml)
        let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: NativeTypography(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
        let view = ReaderTextView(pageColumn: false)
        view.readerContainer.widthTracksTextView = false
        view.readerContainer.size = CGSize(width: 300, height: 10_000)
        view.readerContainer.viewportSize = CGSize(width: 300, height: 400)
        view.setContent(section.string)
        view.ensureFullLayout()
        let final = try XCTUnwrap(view.line(containing: section.string.length - 1))
        XCTAssertGreaterThanOrEqual(view.readerLayoutManager.usageBoundsForTextContainer.maxY, final.frame.maxY - 0.5,
                                   "A final float's zero flow advance must not shorten the scrollable text bounds")
        let visible = try XCTUnwrap(view.visibleCharacterRange(in: CGRect(x: 0, y: final.frame.minY, width: 300,
                                                                        height: final.frame.height)))
        XCTAssertEqual(NSMaxRange(visible), section.string.length)
    }

    func testEmptyViewportAndLinesOutsideItHaveNoVisibleSourceRange() {
        let lines = [line(20, 30, x: 0, y: 50), line(50, 0, x: 0, y: 0)]
        XCTAssertNil(ReaderVisualLine.sourceRange(intersecting: .zero, in: lines))
        XCTAssertNil(ReaderVisualLine.sourceRange(intersecting: CGRect(x: 0, y: 0, width: 300, height: 20), in: lines))
    }
}
