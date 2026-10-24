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
            // Wide enough for "Callout", which widens a box narrower than it (#742).
            let relative = try callout("left:10vw; top:10vh; width:calc(40px + 2em)", size: viewport)
            XCTAssertEqual(relative.minX, viewport.width / 10, accuracy: 1, "\(viewport)")
            XCTAssertEqual(relative.minY, viewport.height / 10, accuracy: 1, "\(viewport)")
            XCTAssertEqual(relative.width, 72, accuracy: 1, "\(viewport)")
        }
    }

    func testNegativeInsetsAreClampedIntoTheColumn() throws {
        // `-998px` is drawn, a pixel short of the off-screen rule (#358).
        for declarations in ["left:-50px; top:0; width:100px", "right:-50px; top:0; width:100px", "left:-998px; top:-20px; width:100px",
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

    /// `doc/native-viewer.md`: "top/left offsets as the book wrote them: -999 CSS pixels or less
    /// in absolute units alone, and `-62.5em` or less, 1,000 pixels, when an `em` or a `rem` is
    /// in the offset, each counting as 16 pixels; calculations in those units alone count too";
    /// zero-area `clip: rect(...)` and `clip-path: inset(50%)`. Everything else stays visible.
    func testHiddenLabelHeuristicAtItsDocumentedBoundaries() throws {
        let hidden = ["left:-1000px", "top:-1000px", "left:-1000.5px", "left:-9999px", "left:calc(-1000px)", "left:calc(-500px - 500px)",
                      "left:calc(-250px * 4)", "left:-750pt", "left:-11in", "left:-1e9px", "inset:-2000px auto auto auto",
                      "left:-999px", "top:-999px", "left:-999.01px", "left:calc(-500px - 499px)", "left:-749.25pt",
                      "left:-999em", "top:-999rem", "left:-62.5em", "top:-62.5rem", "left:calc(-999px - 1em)", "left:calc(-50em - 200px)",
                      "clip:rect(0 0 0 0)", "clip:rect(0, 0, 0, 0)", "clip:rect(1px, 1px, 1px, 1px)", "clip:rect(0px 0px 0px 0px)",
                      "clip-path:inset(50%)", "clip-path:inset(100%)", "visibility:hidden"]
        let visible = ["left:-998px", "left:-998.99px", "top:-998px", "left:-800px", "left:-62.49em", "left:-62.4375em", "top:-62rem",
                       "left:calc(-50em - 199px)", "left:-999ex", "left:-999ch", "left:calc(-999em - 1%)", "top:-999vh",
                       "left:calc(-2000px + 50%)", "left:-200%", "left:-500vw", "right:-9999px", "bottom:-9999px", "left:-749pt",
                       "right:-999em", "margin-left:-999em",
                       "margin-left:-9999px", "clip:rect(0, 0, 1px, 1px)", "clip:rect(auto, auto, auto, auto)", "clip-path:inset(49%)",
                       "clip-path:none", "left:1000px"]
        func build(_ declarations: [String], fontSize: CGFloat) throws -> SectionText {
            try H.build(declarations.enumerated().map { "<span class='x' style='\($1)'>Label\($0).</span>" }.joined() + "<p>Visible end.</p>",
                        css: H.reset + ".x { position:absolute }", fontSize: fontSize)
        }
        for fontSize: CGFloat in [12, 17, 96] {
            let unseen = try build(hidden, fontSize: fontSize)
            XCTAssertEqual(unseen.string.drawnString, "Visible end.", "every one of these is hidden at \(fontSize) points")
            // All but `visibility: hidden` are still there for assistive technology.
            XCTAssertEqual(unseen.string.spokenLabels, hidden.indices.dropLast().map { "Label\($0)." }, "\(fontSize)")
            BuilderHarness.assertMapRoundTrips(unseen)
            let shown = try build(visible, fontSize: fontSize)
            XCTAssertEqual(shown.string.spokenLabels, [], "\(fontSize)")
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

    /// Standard Ebooks parks a title page's heading and byline, and the heading of an imprint or
    /// a colophon, at `left: -999em` for assistive technology, beside an image of the same words.
    /// The page draws that image under its three-em margin at every text size and keeps the
    /// words for VoiceOver in the image's line, with the same characters at every size.
    func testStandardEbooksTitlePageAndImprintDrawTheirImageAndKeepTheHiddenHeadingAtEveryTextSize() throws {
        typealias F = Fixture.Alignment
        let files = ["titlepage.png": RichFixture.image(width: 1400, height: 340), "logo.png": RichFixture.image(width: 220, height: 140)]
        let notice = "This edition was made for a test and is free of copyright."
        var first: (title: SectionText, imprint: SectionText)?
        for fontSize: CGFloat in [12, 17, 96] {
            let title = try H.build(F.shippedTitlePageBody, css: F.shippedCSS, fontSize: fontSize, files: files)
            let imprint = try H.build(F.shippedImprintBody, css: F.shippedCSS, fontSize: fontSize, files: files)
            XCTAssertEqual(title.string.drawnString, "\u{FFFC}", "the title page draws its image alone at \(fontSize) points")
            XCTAssertEqual(title.string.spokenLabels, ["An Aligned Book", "By Test Author."], "\(fontSize)")
            XCTAssertEqual(title.string.string, "\u{FFFC}\u{FFFC}\u{FFFC}", "the heading, the byline and the image, at \(fontSize) points")
            XCTAssertEqual(imprint.string.drawnString, "\u{FFFC}\n" + notice, "the imprint draws its logo and its text at \(fontSize) points")
            XCTAssertEqual(imprint.string.spokenLabels, ["Imprint"], "\(fontSize)")
            XCTAssertEqual(title.string.readerPlainText(), "An Aligned Book By Test Author.", "what VoiceOver and Copy get")
            XCTAssertEqual(imprint.string.readerPlainText(), "Imprint The publisher's logo.\n" + notice)
            for (section, image) in [(title, 2), (imprint, 1)] {
                XCTAssertTrue(section.string.attribute(.attachment, at: image, effectiveRange: nil) is ReaderImageAttachment)
                XCTAssertFalse(section.report.flowBoxesReflowed, "a hidden heading is not a box, so nothing is disclosed")
                BuilderHarness.assertMapRoundTrips(section)
            }
            // The image stands three ems below the top of its page, where the heading and byline
            // used to be drawn above it.
            let (paginator, pages) = H.pages(title, size: size, "\(fontSize)")
            XCTAssertEqual(pages.count, 1, "\(fontSize)")
            let image = try XCTUnwrap(H.pageView(paginator, page: pages[0]).segmentFrames(for: NSRange(location: 2, length: 1)).first)
            XCTAssertEqual(pages[0].topSpacing + image.minY, 3 * fontSize, accuracy: 0.5, "`margin-top: 3em` at \(fontSize) points")
            XCTAssertEqual(image.width, size.width, accuracy: 0.5, "`width: 100%` at \(fontSize) points")
            // A position inside the hidden heading or byline is its label.
            let page = try XCTUnwrap(title.document.element(id: "titlepage"))
            let words = title.document.nodes[page.order...page.subtreeEnd].filter(\.isText)
            XCTAssertEqual(words.map(\.text), ["An Aligned Book", "By ", "Test Author", "."])
            for (text, label) in zip(words, [0, 1, 1, 1]) {
                XCTAssertEqual(title.map.location(of: DOMPosition(text, 1)), label, "\(text.text) at \(fontSize) points")
            }
            XCTAssertEqual(title.anchors["titlepage"], 0)
            XCTAssertEqual(imprint.anchors["notice"], 3)
            if let first {
                for (section, baseline) in [(title, first.title), (imprint, first.imprint)] {
                    XCTAssertEqual(section.string.string, baseline.string.string, "the same characters at \(fontSize) points")
                    XCTAssertEqual(section.map, baseline.map, "the same map at \(fontSize) points")
                    XCTAssertEqual(section.anchors, baseline.anchors, "the same anchors at \(fontSize) points")
                }
            } else { first = (title, imprint) }
        }
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

    /// HTML §15.5.13 makes a `marquee` an `inline-block`, so one with no size stays on its
    /// paragraph's line, and its text does not move (#607). The paragraph's alignment still
    /// places the line.
    func testAMarqueeStaysOnItsParagraphsLine() throws {
        let (section, view) = try layout("<p class='c'>Before <marquee>moving</marquee> after words.</p>", css: ".c { text-align:center }")
        XCTAssertEqual(section.string.string, "Before moving after words.")
        XCTAssertEqual(H.lines(in: view).count, 1)
        let before = H.frame("Before", in: section, view: view), moving = H.frame("moving", in: section, view: view)
        XCTAssertEqual(moving.minY, before.minY, accuracy: 1)
        XCTAssertGreaterThan(moving.minX, before.maxX)
        XCTAssertGreaterThan(before.minX, 50, "centred in the 360-point column")
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

    /// A sized inline block's own margins stand between its content and its line's edges, so one
    /// whose width and margins together are wider than the line is as wide as the room between
    /// its margins. It was as wide as the column and started after its left margin, running past
    /// the column's right edge (#720).
    func testASizedInlineBlockWiderThanItsLineKeepsItsMarginsInsideTheColumn() throws {
        let (section, view) = try layout("<p>Before <span class='b'>Inline box.</span> after words.</p>",
                                         css: ".b { display:inline-block; width:500px; margin:0 20px 0 30px }")
        let region = try XCTUnwrap(H.region("Inline box.", in: section, view: view))
        XCTAssertEqual(region.frame.minX, 30, accuracy: 0.5, "after its left margin, at the start of a row of its own")
        XCTAssertEqual(region.frame.maxX, 340, accuracy: 1, "before its right margin, inside the column")
        XCTAssertGreaterThanOrEqual(H.frame("Inline box.", in: section, view: view).minY, H.frame("Before", in: section, view: view).maxY - 0.5)
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    /// CSS Text 3, 5.2: a word is not broken between two characters unless `overflow-wrap` or
    /// `word-break` lets it be, so a number wider than its box overflows the box on one line. The
    /// reader draws nothing outside its column, so a sized inline block or an absolutely
    /// positioned box narrower than a word it holds is as wide as the word, as far as its
    /// containing block allows, as a float is (#152). A box 20 points wide set `12345` on three
    /// lines, `12`, `34` and `5` (#742).
    func testASizedInlineBlockOrPositionedBoxNarrowerThanItsLongestWordIsAsWideAsThatWord() throws {
        for css in [".n { display:inline-block; width:20px }", ".n { display:inline-block; max-width:20px }",
                    ".n { position:absolute; left:0; top:0; width:20px }", ".n { position:absolute; right:0; top:0; max-width:20px }",
                    ".n { position:absolute; left:0; right:340px; top:0 }"] {
            for fontSize: CGFloat in [16, 25] {
                let label = "\(css) at \(fontSize) points"
                let (section, view) = try layout("<p>Lead <span class='n'>12345</span> verse text follows.</p>", css: css, fontSize: fontSize)
                XCTAssertEqual(H.lines(in: view, intersecting: H.range("12345", in: section)).count, 1, "the number is one word on one line: \(label)")
                let region = try XCTUnwrap(H.region("12345", in: section, view: view), label)
                let number = H.frame("12345", in: section, view: view)
                XCTAssertGreaterThanOrEqual(region.frame.width, number.width - 0.5, label)
                XCTAssertLessThan(region.frame.width, number.width + 2, "the word's width, not a share of the column: \(label)")
                XCTAssertTrue(region.frame.insetBy(dx: -1, dy: -1).contains(number), label)
                if css.contains("right:0") { XCTAssertEqual(region.frame.maxX, 360, accuracy: 1, "at its right inset: \(label)") }
                let prose = H.ink("Lead", in: section, view: view) + H.ink("verse text follows.", in: section, view: view)
                XCTAssertFalse(H.overlaps(prose, [number]), label)
                XCTAssertEqual(view.visibleText, section.string.string, label)
            }
        }
    }

    /// The word's width stops at the containing block: a sized inline block or a positioned box
    /// whose word is wider than its containing block is as wide as that block, and its word is
    /// broken there, as nothing leaves the column.
    func testASizedInlineBlockOrPositionedBoxWhoseWordIsWiderThanItsContainingBlockIsAsWideAsThatBlock() throws {
        let number = String(repeating: "1234567890", count: 6)
        for (body, css) in [("<blockquote><p><span class='n'>\(number)</span> verse text follows.</p></blockquote>",
                             "blockquote { margin:0 40px } .n { display:inline-block; width:20px }"),
                            ("<div class='c'><p><span class='n'>\(number)</span> verse text follows.</p></div>",
                             ".c { position:relative; margin:0 40px } .n { position:absolute; left:0; top:0; width:20px }")] {
            let (section, view) = try layout(body, css: css)
            let region = try XCTUnwrap(H.region(number, in: section, view: view), css)
            XCTAssertEqual(region.frame.minX, 40, accuracy: 0.5, css)
            XCTAssertEqual(region.frame.maxX, 320, accuracy: 1, "the containing block's content box: \(css)")
            XCTAssertGreaterThan(H.lines(in: view, intersecting: H.range(number, in: section)).count, 1, css)
            XCTAssertEqual(view.visibleText, section.string.string, css)
        }
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
