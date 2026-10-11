import CoreGraphics
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Positioned boxes, sized inline-blocks and the visually-hidden heuristic against CSS 2.2
/// sections 9.3, 9.4.3 and 10.3.7, CSS Positioned Layout 3 and the "Floats and positioned boxes"
/// section of `doc/native-viewer.md`. Points, in a 360 by 600 column unless a test says.
@MainActor final class BoxLayoutPositionedCoverageTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 360, height: 600)

    private func layout(_ body: String, css: String, size: CGSize? = nil, fontSize: CGFloat = 16) throws -> (section: SectionText, view: ReaderTextView) {
        let section = try H.build(body, css: H.reset + css, fontSize: fontSize)
        return (section, H.view(section.string, size: size ?? self.size))
    }

    /// The planned frame of an absolutely positioned `aside` before a paragraph of prose.
    private func callout(_ declarations: String, size: CGSize? = nil) throws -> CGRect {
        let (section, view) = try layout("<aside>Callout words.</aside><p>\(H.prose)</p>", css: "aside { position:absolute; \(declarations) }", size: size)
        let region = try XCTUnwrap(H.region("Callout words.", in: section, view: view), declarations)
        let glyphs = H.frame("Callout words.", in: section, view: view)
        XCTAssertTrue(region.frame.insetBy(dx: -1, dy: -1).contains(glyphs), "the box's text is drawn inside its frame: \(declarations)")
        XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), [region.frame]), "prose keeps clear of the box: \(declarations)")
        XCTAssertEqual(view.visibleText, section.string.string, declarations)
        return region.frame
    }

    // MARK: Insets

    func testInsetShorthandWithOneToFourValuesPlacesAnAbsoluteBox() throws {
        let box = "width:100px; height:50px; "
        // top, right, bottom, left; with a width and a height the right and bottom are over-constrained.
        for (inset, origin) in [("30px", CGPoint(x: 30, y: 30)), ("30px 50px", CGPoint(x: 50, y: 30)), ("30px 50px 70px", CGPoint(x: 50, y: 30)),
                                ("30px 50px 70px 90px", CGPoint(x: 90, y: 30)), ("auto 0 0 auto", CGPoint(x: 260, y: 550)),
                                ("auto auto 20px 10px", CGPoint(x: 10, y: 530)), ("10% 0 auto auto", CGPoint(x: 260, y: 60))] {
            let frame = try callout(box + "inset:\(inset)")
            XCTAssertEqual(frame.minX, origin.x, accuracy: 1, inset); XCTAssertEqual(frame.minY, origin.y, accuracy: 1, inset)
            XCTAssertEqual(frame.width, 100, accuracy: 1, inset); XCTAssertEqual(frame.height, 50, accuracy: 1, inset)
        }
    }

    func testEachInsetAloneAndItsLonghandPairs() throws {
        let box = "width:100px; height:50px; "
        for (declarations, origin) in [("left:24px; top:72px", CGPoint(x: 24, y: 72)), ("right:24px; top:0", CGPoint(x: 236, y: 0)),
                                       ("left:0; bottom:32px", CGPoint(x: 0, y: 518)), ("right:24px; bottom:32px", CGPoint(x: 236, y: 518)),
                                       ("left:24px", CGPoint(x: 24, y: 0)), ("right:24px", CGPoint(x: 236, y: 0)), ("top:72px", CGPoint(x: 0, y: 72))] {
            let frame = try callout(box + declarations)
            XCTAssertEqual(frame.minX, origin.x, accuracy: 1, declarations); XCTAssertEqual(frame.minY, origin.y, accuracy: 1, declarations)
        }
    }

    /// CSS 2.2 10.3.7: over-constrained in a left-to-right containing block, `right` is ignored;
    /// with an auto width the box fills the space between both insets.
    func testLeftAndRightInsetsWithAndWithoutAWidth() throws {
        var frame = try callout("left:20px; right:40px; width:100px; top:10px")
        XCTAssertEqual(frame.minX, 20, accuracy: 1); XCTAssertEqual(frame.width, 100, accuracy: 1)
        frame = try callout("left:20px; right:40px; top:10px")
        XCTAssertEqual(frame.minX, 20, accuracy: 1); XCTAssertEqual(frame.width, 300, accuracy: 1, "between both insets")
        frame = try callout("left:20px; right:40px; top:10px; max-width:120px")
        XCTAssertEqual(frame.minX, 20, accuracy: 1)
    }

    func testPercentageInsetsAndWidthsResolveAgainstTheContainingBlock() throws {
        for viewport in [CGSize(width: 360, height: 600), CGSize(width: 600, height: 800), CGSize(width: 900, height: 500)] {
            let frame = try callout("left:25%; top:10%; width:25%", size: viewport)
            XCTAssertEqual(frame.minX, viewport.width / 4, accuracy: 1, "\(viewport)")
            XCTAssertEqual(frame.minY, viewport.height / 10, accuracy: 1, "\(viewport)")
            XCTAssertEqual(frame.width, viewport.width / 4, accuracy: 1, "\(viewport)")
            let relative = try callout("left:10vw; top:10vh; width:calc(10px + 2em)", size: viewport)
            XCTAssertEqual(relative.minX, viewport.width / 10, accuracy: 1, "\(viewport)")
            XCTAssertEqual(relative.minY, viewport.height / 10, accuracy: 1, "\(viewport)")
            XCTAssertEqual(relative.width, 42, accuracy: 1, "\(viewport)")
        }
    }

    func testNegativeInsetsAreClampedIntoTheColumn() throws {
        for declarations in ["left:-50px; top:0; width:100px", "right:-50px; top:0; width:100px", "left:-999px; top:-20px; width:100px",
                             "left:500px; top:0; width:100px"] {
            let frame = try callout(declarations)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, declarations); XCTAssertLessThanOrEqual(frame.maxX, 360.5, declarations)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.5, declarations)
        }
    }

    /// `doc/native-viewer.md`: "auto margins center a non-floated box".
    func testAutoMarginsCentreAnAbsoluteBoxOfDefiniteWidth() throws {
        let frame = try callout("top:0; width:100px; margin:0 auto")
        XCTAssertEqual(frame.midX, 180, accuracy: 1)
    }

    /// CSS 2.2 10.3.7: with `left` and `width` auto and `right` set, the width is shrink-to-fit
    /// and the box's right edge is at the inset. The reader gives the box the whole column, so
    /// a note positioned at the right appears at the left.
    func testAnAbsoluteBoxWithOnlyARightInsetEndsAtThatInset() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/153")
        let (section, view) = try layout("<aside>Note.</aside><p>\(H.prose)</p>", css: "aside { position:absolute; right:40px; top:10px }")
        let note = H.frame("Note.", in: section, view: view)
        XCTAssertEqual(note.minY, 10, accuracy: 1)
        XCTAssertEqual(note.maxX, 320, accuracy: 1.5, "the box ends 40 points from the right edge, and its text with it")
        let region = try XCTUnwrap(H.region("Note.", in: section, view: view))
        XCTAssertEqual(region.frame.maxX, 320, accuracy: 1.5)
    }

    /// CSS 2.2 10.3.7: with `left`, `width` and `right` all set and both side margins auto, the
    /// margins are equal: the box is centred between the insets.
    func testAnAbsoluteBoxBetweenLeftAndRightInsetsWithAutoMarginsIsCentred() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/153")
        let frame = try callout("top:0; left:0; right:0; width:100px; margin:0 auto")
        XCTAssertEqual(frame.midX, 180, accuracy: 1, "centred between left:0 and right:0")
    }

    /// CSS 2.2 10.3.7: over-constrained in a right-to-left containing block, `left` is ignored.
    func testOverConstrainedInsetsIgnoreLeftInARightToLeftContainingBlock() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/153")
        let (section, view) = try layout("<div class='c' dir='rtl'><aside>Callout words.</aside><p>نص عربي قصير.</p></div>",
                                         css: ".c { position:relative; direction:rtl } aside { position:absolute; left:20px; right:40px; width:100px; top:0 }")
        let region = try XCTUnwrap(H.region("Callout words.", in: section, view: view))
        XCTAssertEqual(region.frame.width, 100, accuracy: 1)
        XCTAssertEqual(region.frame.maxX, 320, accuracy: 1, "40 points from the right edge: `right` wins, `left` is ignored")
    }

    // MARK: Containing block

    func testAnAbsoluteBoxUsesItsNearestPositionedAncestorNotAPlainOne() throws {
        let css = ".c { margin-left:60px; width:240px } .p { position:relative } aside { position:absolute; left:10px; top:20px; width:100px }"
        // Inside a relative container: from its padding edge, below what precedes the container.
        var (section, view) = try layout("<p>Before words.</p><div class='c p'><div><aside>Callout words.</aside><p>Inner text.</p></div></div>", css: css)
        var region = try XCTUnwrap(H.region("Callout words.", in: section, view: view))
        let before = H.frame("Before words.", in: section, view: view)
        XCTAssertEqual(region.frame.minX, 70, accuracy: 1); XCTAssertEqual(region.frame.minY, before.maxY + 20, accuracy: 1)
        // No positioned ancestor: from the section's own origin.
        (section, view) = try layout("<p>Before words.</p><div class='c'><div><aside>Callout words.</aside><p>Inner text.</p></div></div>", css: css)
        region = try XCTUnwrap(H.region("Callout words.", in: section, view: view))
        XCTAssertEqual(region.frame.minX, 10, accuracy: 1); XCTAssertEqual(region.frame.minY, 20, accuracy: 1)
        // The nearest of two positioned ancestors.
        (section, view) = try layout("<div class='p' style='margin-left:20px'><div class='c p'><aside>Callout words.</aside><p>Inner text.</p></div></div>", css: css)
        region = try XCTUnwrap(H.region("Callout words.", in: section, view: view))
        XCTAssertEqual(region.frame.minX, 90, accuracy: 1, "20 and 60 points of margin, then the 10-point inset")
    }

    func testAnAbsoluteBoxWithoutInsetsStaysWhereItsSourceIs() throws {
        let (section, view) = try layout("<p>Before words.</p><aside>Callout words.</aside><p>\(H.prose)</p>", css: "aside { position:absolute; width:100px }")
        let region = try XCTUnwrap(H.region("Callout words.", in: section, view: view))
        XCTAssertEqual(region.frame.minY, H.frame("Before words.", in: section, view: view).maxY, accuracy: 1)
        XCTAssertEqual(region.frame.minX, 0, accuracy: 0.5)
        XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), [region.frame]))
    }

    func testAFixedBoxUsesTheFirstViewportAndAppearsOnce() throws {
        let (section, view) = try layout("<p>Before words.</p><aside>Fixed words.</aside><p>\(H.prose) \(H.prose)</p>",
                                         css: "aside { position:fixed; right:0; bottom:0; width:100px; height:40px }")
        let region = try XCTUnwrap(H.region("Fixed words.", in: section, view: view))
        XCTAssertEqual(region.frame.minX, 260, accuracy: 1); XCTAssertEqual(region.frame.maxY, 600, accuracy: 1)
        let (paginator, pages) = H.pages(section, size: size)
        XCTAssertGreaterThan(pages.count, 1)
        let shown = pages.map { H.pageView(paginator, page: $0).visibleText }
        XCTAssertEqual(shown.filter { $0.contains("Fixed words.") }.count, 1, "not repeated on each page")
        XCTAssertEqual(shown.joined(), section.string.string)
    }

    // MARK: Relative

    func testRelativeOffsetsMoveContentWithinTheColumn() throws {
        func frames(_ declarations: String) throws -> (before: CGRect, moved: CGRect, after: CGRect) {
            let (section, view) = try layout("<p>Before words.</p><div class='r'><p>Relative words.</p></div><p>After words.</p>",
                                             css: ".r { position:relative; \(declarations) }")
            XCTAssertEqual(view.visibleText, section.string.string, declarations)
            return (H.frame("Before words.", in: section, view: view), H.frame("Relative words.", in: section, view: view),
                    H.frame("After words.", in: section, view: view))
        }
        var result = try frames("margin-left:50px; left:-30px")
        XCTAssertEqual(result.moved.minX, 20, accuracy: 1)
        result = try frames("margin-left:50px; right:30px")
        XCTAssertEqual(result.moved.minX, 20, accuracy: 1, "`right` moves the box left")
        result = try frames("margin-left:50px; width:200px; left:10px; right:30px")
        XCTAssertEqual(result.moved.minX, 60, accuracy: 1, "left to right: `left` wins over `right`")
        result = try frames("width:200px; left:60px")
        XCTAssertEqual(result.moved.minX, 60, accuracy: 1)
        result = try frames("left:-30px")
        XCTAssertEqual(result.moved.minX, 0, accuracy: 0.5, "never out of the column")
        // Positive vertical offsets move the content, and what follows it, down.
        for declarations in ["top:40px", "bottom:-40px"] {
            result = try frames(declarations)
            XCTAssertEqual(result.moved.minY, result.before.maxY + 40, accuracy: 1, declarations)
            XCTAssertGreaterThanOrEqual(result.after.minY, result.moved.maxY - 0.5, declarations)
        }
    }

    /// `doc/native-viewer.md`: sticky positioning and negative relative vertical offsets are
    /// outside the subset. They must read as ordinary flow.
    func testStickyAndUpwardRelativeOffsetsStayInFlowInReadingOrder() throws {
        let body = "<p>Before words.</p><div class='r'><p>Moved words.</p></div><p>After words.</p>"
        let (plain, plainView) = try layout(body, css: "")
        let expected = ["Before words.", "Moved words.", "After words."].map { H.frame($0, in: plain, view: plainView) }
        for declarations in ["position:relative; top:-40px", "position:relative; bottom:40px", "position:sticky; top:0",
                             "position:-webkit-sticky; top:0; bottom:0", "position:relative; top:-200%"] {
            let (section, view) = try layout(body, css: ".r { \(declarations) }")
            XCTAssertEqual(section.string.string, plain.string.string, declarations)
            for (phrase, frame) in zip(["Before words.", "Moved words.", "After words."], expected) {
                let actual = H.frame(phrase, in: section, view: view)
                XCTAssertEqual(actual.minY, frame.minY, accuracy: 0.5, "\(declarations): \(phrase)")
                XCTAssertEqual(actual.minX, frame.minX, accuracy: 0.5, "\(declarations): \(phrase)")
            }
            H.pages(section, size: size, declarations)
            BuilderHarness.assertMapRoundTrips(section)
        }
    }

    /// CSS 2.2 9.4.3: `left` moves a relatively positioned box to the right by that amount. The
    /// reader drops the offset of a box as wide as the column, the usual case.
    func testARelativeLeftOffsetMovesAFullWidthBlock() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/153")
        let (section, view) = try layout("<p>Before words.</p><div class='r'><p>Relative words.</p></div><p>After words.</p>",
                                         css: ".r { position:relative; left:30px }")
        XCTAssertEqual(H.frame("Before words.", in: section, view: view).minX, 0, accuracy: 0.5)
        XCTAssertEqual(H.frame("Relative words.", in: section, view: view).minX, 30, accuracy: 1, "moved 30 points to the right")
        XCTAssertEqual(H.frame("After words.", in: section, view: view).minX, 0, accuracy: 0.5)
    }

    // MARK: Visually hidden labels

    /// `doc/native-viewer.md`: "absolute-unit top/left offsets of -1,000 CSS pixels or less,
    /// including calculations containing only absolute units"; zero-area `clip: rect(...)` and
    /// `clip-path: inset(50%)`. Everything else stays visible.
    func testHiddenLabelHeuristicAtItsDocumentedBoundaries() throws {
        let hidden = ["left:-1000px", "top:-1000px", "left:-1000.5px", "left:-9999px", "left:calc(-1000px)", "left:calc(-500px - 500px)",
                      "left:calc(-250px * 4)", "left:-750pt", "left:-11in", "left:-1e9px", "inset:-2000px auto auto auto",
                      "clip:rect(0 0 0 0)", "clip:rect(0, 0, 0, 0)", "clip:rect(1px, 1px, 1px, 1px)", "clip:rect(0px 0px 0px 0px)",
                      "clip-path:inset(50%)", "clip-path:inset(100%)", "visibility:hidden"]
        let visible = ["left:-999px", "left:-999.99px", "top:-999px", "left:-999em", "top:-999rem", "left:calc(-999px - 1em)",
                       "left:calc(-2000px + 50%)", "left:-200%", "left:-500vw", "right:-9999px", "bottom:-9999px", "left:-749pt",
                       "margin-left:-9999px", "clip:rect(0, 0, 1px, 1px)", "clip:rect(auto, auto, auto, auto)", "clip-path:inset(49%)",
                       "clip-path:none", "left:1000px"]
        func build(_ declarations: [String], fontSize: CGFloat) throws -> SectionText {
            try H.build(declarations.enumerated().map { "<span class='x' style='\($1)'>Label\($0).</span>" }.joined() + "<p>Visible end.</p>",
                        css: H.reset + ".x { position:absolute }", fontSize: fontSize)
        }
        for fontSize: CGFloat in [12, 16, 40] {
            XCTAssertEqual(try build(hidden, fontSize: fontSize).string.string, "Visible end.", "every one of these is hidden at \(fontSize) points")
            let shown = try build(visible, fontSize: fontSize)
            for (index, declaration) in visible.enumerated() {
                XCTAssertTrue(shown.string.string.contains("Label\(index)."), "\(declaration) stays visible at \(fontSize) points")
            }
            BuilderHarness.assertMapRoundTrips(shown)
            H.pages(shown, size: size, "\(fontSize)")
        }
    }

    func testOnlyAbsoluteAndFixedBoxesAreHiddenByOffscreenOffsets() throws {
        for (position, isHidden) in [("absolute", true), ("fixed", true), ("relative", false), ("static", false), ("sticky", false)] {
            let section = try H.build("<p>Shown.</p><span class='x'>Label.</span><p>End.</p>", css: H.reset + ".x { position:\(position); left:-9999px; top:-9999px }")
            XCTAssertEqual(section.string.string.contains("Label."), !isHidden, position)
            XCTAssertTrue(section.string.string.hasPrefix("Shown.") && section.string.string.hasSuffix("End."), position)
        }
        // A float or an inline-block with the same offsets is not positioned at all.
        let floated = try H.build("<span class='x'>Label.</span><p>End.</p>", css: H.reset + ".x { float:left; left:-9999px }")
        XCTAssertTrue(floated.string.string.contains("Label."))
    }

    // MARK: Inline-block

    /// `doc/native-viewer.md`: "Unsized inline-blocks remain inline."
    func testUnsizedInlineBlocksStayInlineAndSizedOnesBecomeBoxes() throws {
        let body = "<p>Before <span class='b'>Inline box.</span> after words.</p>"
        let (plain, plainView) = try layout(body, css: ".b { display:inline-block }")
        XCTAssertEqual(plain.string.string, "Before Inline box. after words.")
        XCTAssertFalse(plain.report.flowBoxesReflowed)
        XCTAssertFalse(plainView.readerContainer.hasNonlinearGeometry)
        XCTAssertEqual(H.lines(in: plainView).count, 1)
        for declarations in ["width:120px", "height:40px", "min-width:120px", "max-width:120px", "min-height:40px"] {
            let (section, view) = try layout(body, css: ".b { display:inline-block; \(declarations) }")
            XCTAssertTrue(section.report.flowBoxesReflowed, declarations)
            let box = H.frame("Inline box.", in: section, view: view), before = H.frame("Before", in: section, view: view)
            XCTAssertEqual(box.minY, before.minY, accuracy: 2, "it fits after its prefix: \(declarations)")
            XCTAssertGreaterThan(box.minX, before.maxX, declarations)
            XCTAssertFalse(H.overlaps(H.ink("after words.", in: section, view: view), [before, box]), declarations)
            XCTAssertEqual(view.visibleText, section.string.string, declarations)
        }
    }

    func testASizedInlineBlockWiderThanTheRestOfItsLineOrTheColumnTakesItsOwnRow() throws {
        var (section, view) = try layout("<p>Before words fill most of this line <span class='b'>Inline box.</span> after words.</p>",
                                         css: ".b { display:inline-block; width:200px }")
        var before = H.frame("Before words fill most of this line", in: section, view: view), box = H.frame("Inline box.", in: section, view: view)
        XCTAssertGreaterThanOrEqual(box.minY, before.maxY - 0.5, "no room after the prefix: the next row")
        XCTAssertEqual(try XCTUnwrap(H.region("Inline box.", in: section, view: view)).frame.width, 200, accuracy: 1)
        XCTAssertFalse(H.overlaps(H.ink("after words.", in: section, view: view), [before, box]))
        (section, view) = try layout("<p>Before <span class='b'>Inline box.</span> after words.</p>", css: ".b { display:inline-block; width:500px }")
        before = H.frame("Before", in: section, view: view); box = H.frame("Inline box.", in: section, view: view)
        let region = try XCTUnwrap(H.region("Inline box.", in: section, view: view))
        XCTAssertLessThanOrEqual(region.frame.maxX, 360.5, "never wider than the column")
        XCTAssertGreaterThanOrEqual(box.minY, before.maxY - 0.5)
        XCTAssertGreaterThanOrEqual(H.frame("after words.", in: section, view: view).minY, box.maxY - 0.5)
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    func testAnInlineBlockInsideAFloatStaysReadableInOrder() throws {
        let (section, view) = try layout("<div class='f'><span class='b'>Inline box.</span> tail words.</div><p>\(H.prose)</p>",
                                         css: ".f { float:left; width:160px } .b { display:inline-block; width:80px }")
        let box = H.frame("Inline box.", in: section, view: view), tail = H.frame("tail words.", in: section, view: view)
        XCTAssertLessThanOrEqual(box.maxX, 161); XCTAssertLessThanOrEqual(tail.maxX, 161)
        XCTAssertGreaterThanOrEqual(tail.minY, box.minY - 0.5, "reading order")
        XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), H.ink("Inline box.", in: section, view: view) + H.ink("tail words.", in: section, view: view)))
        XCTAssertEqual(view.visibleText, section.string.string)
        H.pages(section, size: size)
    }

    /// The fallback for boxes the planner leaves in flow: `ReaderFlowBoxLayout`.
    func testFallbackWidthsCentreWithAutoMarginsAndKeepAReadableColumn() throws {
        let section = try H.build("<div class='o'><div class='c'>Centred fallback words.</div></div><div class='d'><div class='n'>Narrow fallback words.</div></div>",
                                  css: H.reset + ".o { display:inline-block; width:100% } .c { display:inline-block; width:50%; margin:0 auto } "
                                    + ".d { margin:0 300px } .n { display:inline-block; width:10px }")
        for column: CGFloat in [240, 480, 900] {
            let text = ReaderFlowBoxLayout.applying(to: section.string, viewport: CGSize(width: column, height: 600))
            XCTAssertEqual(text.string, section.string.string)
            let centred = H.paragraphStyle("Centred fallback words.", in: section, text: text)
            XCTAssertEqual(centred.headIndent, column / 4, accuracy: 0.5, "\(column)")
            XCTAssertEqual(centred.tailIndent, -column / 4, accuracy: 0.5, "\(column)")
            let narrow = H.paragraphStyle("Narrow fallback words.", in: section, text: text)
            XCTAssertGreaterThanOrEqual(narrow.headIndent, 0, "\(column)")
            let width = column - narrow.headIndent + narrow.tailIndent
            XCTAssertGreaterThanOrEqual(width, min(column / 3, 64) - 0.5, "deep indentation still leaves a readable column: \(column)")
            XCTAssertLessThanOrEqual(width, column, "\(column)")
        }
    }

    /// `doc/native-viewer.md`: "Up to eight nested width constraints resolve within the enclosing
    /// box in this fallback."
    func testEightNestedWidthConstraintsResolveAndANinthIsIgnored() throws {
        func nested(_ depth: Int) -> String {
            String(repeating: "<div class='n'>", count: depth) + "<p>Depth \(depth) words.</p>" + String(repeating: "</div>", count: depth)
        }
        let section = try H.build([1, 2, 8, 9, 12].map(nested).joined(), css: H.reset + ".n { display:inline-block; width:90% }")
        let column: CGFloat = 900
        let text = ReaderFlowBoxLayout.applying(to: section.string, viewport: CGSize(width: column, height: 600))
        func width(_ depth: Int) -> CGFloat {
            let style = H.paragraphStyle("Depth \(depth) words.", in: section, text: text)
            return column - style.headIndent + style.tailIndent
        }
        XCTAssertEqual(width(1), column * 0.9, accuracy: 0.5)
        XCTAssertEqual(width(2), column * 0.81, accuracy: 0.5)
        XCTAssertEqual(width(8), column * pow(0.9, 8), accuracy: 0.5)
        XCTAssertEqual(width(9), column * pow(0.9, 8), accuracy: 0.5, "the ninth constraint is not applied")
        XCTAssertEqual(width(12), column * pow(0.9, 8), accuracy: 0.5)
        H.pages(section, size: CGSize(width: column, height: 600))
        BuilderHarness.assertMapRoundTrips(section)
    }
}
