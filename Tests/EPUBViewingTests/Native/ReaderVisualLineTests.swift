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

    /// A line that shows nothing (hidden labels alone, on a line of no height) is whole in the
    /// viewport whenever the line after it is at the top. It is not on screen for that, and
    /// counts only where the viewport reaches no other line.
    func testALineThatShowsNothingCountsOnlyWhereNoOtherLineIsReached() {
        let lines = [line(0, 2, x: 0, y: 100, height: 0.001), line(2, 30, x: 0, y: 100.001), line(32, 30, x: 0, y: 120.001),
                     line(62, 1, x: 0, y: 140.001, height: 0.001), line(63, 30, x: 0, y: 140.002)]
        let shows: (ReaderVisualLine) -> Bool = { $0.frame.height > 0.5 }
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 40.5)
        XCTAssertEqual(ReaderVisualLine.sourceRange(mostlyWithin: viewport, in: lines), NSRange(location: 0, length: 63),
                       "by their frames alone the lines of no height at the top and the bottom are in it")
        XCTAssertEqual(ReaderVisualLine.sourceRange(mostlyWithin: viewport, in: lines, seen: shows), NSRange(location: 2, length: 60))
        XCTAssertEqual(ReaderVisualLine.sourceRange(mostlyWithin: CGRect(x: 0, y: 99.5, width: 300, height: 0.5005), in: lines, seen: shows),
                       NSRange(location: 0, length: 2), "nothing else is reached")
    }

    /// A rest is accepted within a point of the top, and the line above ends where the rested
    /// one starts: a sliver of a line at either edge is in the viewport and not on screen.
    func testLinesShowingLessThanHalfAtAnEdgeAreNotMostlyInTheViewport() {
        let lines = [line(0, 30, x: 0, y: 0), line(30, 30, x: 0, y: 20), line(60, 30, x: 0, y: 40), line(90, 30, x: 0, y: 60)]
        func mostly(_ y: CGFloat, _ height: CGFloat) -> NSRange? {
            ReaderVisualLine.sourceRange(mostlyWithin: CGRect(x: 0, y: y, width: 300, height: height), in: lines)
        }
        // Half a point of the first line and of the last.
        XCTAssertEqual(ReaderVisualLine.sourceRange(intersecting: CGRect(x: 0, y: 19.5, width: 300, height: 41), in: lines),
                       NSRange(location: 0, length: 120))
        XCTAssertEqual(mostly(19.5, 41), NSRange(location: 30, length: 60))
        // What arithmetic alone leaves of them.
        XCTAssertEqual(mostly(20 - 1e-12, 40 + 2e-12), NSRange(location: 30, length: 60))
        // A point cut off the first line on screen and the last.
        XCTAssertEqual(mostly(21, 38), NSRange(location: 30, length: 60))
        // Half a line counts, as a line whose middle is at the top does where TextKit places lines.
        XCTAssertEqual(mostly(10, 60), NSRange(location: 0, length: 120))
        XCTAssertEqual(mostly(10.5, 59), NSRange(location: 30, length: 60))
        // The horizontal viewport still limits what is on screen.
        XCTAssertNil(ReaderVisualLine.sourceRange(mostlyWithin: CGRect(x: 150, y: 20, width: 150, height: 40), in: lines))
    }

    func testAFloatCountsByItsOwnFrameAmongLinesMostlyInTheViewport() {
        // An initial three lines tall at the left, earlier in the source than the prose beside it.
        let lines = [line(0, 1, x: 0, y: 0, width: 40, height: 60), line(1, 40, x: 50, y: 0), line(41, 40, x: 50, y: 20),
                     line(81, 40, x: 50, y: 40), line(121, 40, x: 0, y: 60)]
        func mostly(_ y: CGFloat) -> NSRange? {
            ReaderVisualLine.sourceRange(mostlyWithin: CGRect(x: 0, y: y, width: 300, height: 100 - y), in: lines)
        }
        XCTAssertEqual(mostly(20), NSRange(location: 0, length: 161), "the initial is mostly on screen beside the second line")
        XCTAssertEqual(mostly(40), NSRange(location: 81, length: 80), "its last third is not")
    }

    func testALineTallerThanTheViewportIsOnScreenWhereItHoldsTheMiddle() {
        // A table row three screens tall below a line of prose.
        let lines = [line(0, 30, x: 0, y: 0), line(30, 1, x: 0, y: 20, width: 300, height: 900), line(31, 30, x: 0, y: 920)]
        func mostly(_ y: CGFloat) -> NSRange? {
            ReaderVisualLine.sourceRange(mostlyWithin: CGRect(x: 0, y: y, width: 300, height: 300), in: lines)
        }
        XCTAssertEqual(mostly(19.5), NSRange(location: 30, length: 1), "rested half a point low: not the line above")
        XCTAssertEqual(mostly(400), NSRange(location: 30, length: 1))
        XCTAssertEqual(mostly(700), NSRange(location: 30, length: 31), "the line after it is mostly on screen too")
    }

    func testEveryLineInTheViewportCountsWhenItMostlyShowsNone() {
        // The space an aligned box keeps above its first line fills the viewport.
        let lines = [line(0, 30, x: 0, y: 0), line(30, 30, x: 0, y: 400)]
        XCTAssertEqual(ReaderVisualLine.sourceRange(mostlyWithin: CGRect(x: 0, y: 15, width: 300, height: 390), in: lines),
                       NSRange(location: 0, length: 60))
        XCTAssertEqual(ReaderVisualLine.sourceRange(mostlyWithin: CGRect(x: 0, y: 15, width: 300, height: 300), in: lines),
                       NSRange(location: 0, length: 30))
        XCTAssertNil(ReaderVisualLine.sourceRange(mostlyWithin: CGRect(x: 0, y: 30, width: 300, height: 300), in: lines))
        XCTAssertNil(ReaderVisualLine.sourceRange(mostlyWithin: .zero, in: lines))
    }

    func testEmptyViewportAndLinesOutsideItHaveNoVisibleSourceRange() {
        let lines = [line(20, 30, x: 0, y: 50), line(50, 0, x: 0, y: 0)]
        XCTAssertNil(ReaderVisualLine.sourceRange(intersecting: .zero, in: lines))
        XCTAssertNil(ReaderVisualLine.sourceRange(intersecting: CGRect(x: 0, y: 0, width: 300, height: 20), in: lines))
    }
}
