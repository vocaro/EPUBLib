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

/// Floats and `clear` against CSS 2.2 sections 9.5 and 10.3.5 and the "Floats and positioned
/// boxes" section of `doc/native-viewer.md`. Points, in a 360 by 600 column unless a test says.
@MainActor final class BoxLayoutFloatCoverageTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 360, height: 600)
    private let arabic = Array(repeating: "نص عربي طويل يلتف حول المربع العائم ثم يعود إلى العمود الكامل تحته", count: 4).joined(separator: " ")

    private func layout(_ body: String, css: String, size: CGSize? = nil, fontSize: CGFloat = 16,
                        files: [String: Data] = [:]) throws -> (section: SectionText, view: ReaderTextView) {
        let section = try H.build(body, css: H.reset + css, fontSize: fontSize, files: files)
        return (section, H.view(section.string, size: size ?? self.size))
    }

    /// The prose lines that share rows with `region`, and those below it.
    private func proseLines(_ phrase: String, around region: ReaderBoxGeometry.Region, in section: SectionText,
                            view: ReaderTextView) -> (beside: [CGRect], below: [CGRect]) {
        let lines = H.lines(in: view, intersecting: H.range(phrase, in: section)).map(\.frame)
        return (lines.filter { $0.minY < region.frame.maxY - 0.5 }, lines.filter { $0.minY >= region.frame.maxY - 0.5 })
    }

    // MARK: Placement

    func testLeftAndRightFloatsShareARowAndProseRunsBetweenThem() throws {
        let (section, view) = try layout("<figure class='l'>Alpha box.</figure><figure class='r'>Beta box.</figure><p>\(H.prose)</p>",
                                         css: "figure { width:100px; height:80px } .l { float:left } .r { float:right }")
        let left = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        let right = try XCTUnwrap(H.region("Beta box.", in: section, view: view))
        XCTAssertEqual(left.frame.minX, 0, accuracy: 0.5); XCTAssertEqual(left.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(right.frame.maxX, 360, accuracy: 0.5); XCTAssertEqual(right.frame.minY, 0, accuracy: 0.5, "the same row")
        let lines = proseLines(H.prose, around: left, in: section, view: view)
        XCTAssertFalse(lines.beside.isEmpty)
        XCTAssertTrue(lines.beside.allSatisfy { $0.minX >= 99 && $0.maxX <= 261 }, "\(lines.beside)")
        XCTAssertTrue(lines.below.contains { $0.minX < 1 && $0.width > 280 }, "the full column returns below both")
    }

    /// The reader stacks same-side floats (a browser sets them side by side while they fit).
    /// Either way nothing may overlap and nothing may be lost.
    func testConsecutiveSameSideFloatsNeverOverlapEachOtherOrTheProse() throws {
        let (section, view) = try layout("<figure>Alpha box.</figure><figure>Beta box.</figure><figure>Gamma box.</figure><p>\(H.prose)</p>",
                                         css: "figure { float:left; width:100px; height:80px }")
        let regions = try ["Alpha box.", "Beta box.", "Gamma box."].map { try XCTUnwrap(H.region($0, in: section, view: view)) }
        for (index, region) in regions.enumerated() {
            for other in regions.dropFirst(index + 1) {
                let overlap = region.frame.intersection(other.frame)
                XCTAssertTrue(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5, "\(region.frame) \(other.frame)")
            }
            XCTAssertGreaterThanOrEqual(region.frame.minX, -0.5); XCTAssertLessThanOrEqual(region.frame.maxX, 360.5)
        }
        let prose = H.ink(H.prose, in: section, view: view)
        XCTAssertFalse(H.overlaps(prose, regions.map(\.frame)))
        for phrase in ["Alpha box.", "Beta box.", "Gamma box."] {
            XCTAssertFalse(H.overlaps(H.ink(phrase, in: section, view: view), prose), phrase)
        }
        XCTAssertEqual(view.visibleText, section.string.string)
        H.pages(section, size: size)
    }

    func testAFloatAsWideAsTheColumnOrWiderLeavesItsProseBelowIt() throws {
        for declarations in ["width:500px", "width:100%", "width:300px; margin:0 50px", "width:150%", "min-width:400px"] {
            let (section, view) = try layout("<figure>Alpha box.</figure><p>\(H.prose)</p>", css: "figure { float:left; \(declarations) }")
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view), declarations)
            XCTAssertGreaterThanOrEqual(region.frame.minX, -0.5, declarations)
            XCTAssertLessThanOrEqual(region.frame.maxX, 360.5, "a box never leaves the column: \(declarations)")
            let caption = H.frame("Alpha box.", in: section, view: view)
            XCTAssertTrue(region.frame.insetBy(dx: -1, dy: -1).contains(caption), declarations)
            let lines = proseLines(H.prose, around: region, in: section, view: view)
            XCTAssertTrue(lines.beside.isEmpty, "no room beside it: \(declarations)")
            XCTAssertEqual(try XCTUnwrap(lines.below.first).minX, 0, accuracy: 0.5, declarations)
            XCTAssertEqual(view.visibleText, section.string.string, declarations)
        }
    }

    func testDropCapsOfOneLetterSeveralLettersAndAnAstralCharacterShrinkToTheirGlyphs() throws {
        for (cap, rest) in [("W", "ords follow the initial."), ("Once", "upon a time there was."), ("\u{1D504}", "stral letters are one character.")] {
            let (section, view) = try layout("<p><span class='cap'>\(cap)</span>\(cap == "Once" ? " " : "")\(rest) \(H.prose)</p>",
                                             css: ".cap { float:left; font-size:48px }")
            XCTAssertTrue(section.string.string.hasPrefix(cap + "\n" + rest), cap)
            let region = try XCTUnwrap(H.region(cap, in: section, view: view), cap)
            XCTAssertEqual(region.range, NSRange(location: 0, length: cap.utf16.count + 1), "the whole character and its break: \(cap)")
            let glyph = H.frame(cap, in: section, view: view)
            XCTAssertGreaterThanOrEqual(region.frame.width, glyph.width - 0.5, cap)
            XCTAssertLessThan(region.frame.width, glyph.width + 2, "content width, not a share of the column: \(cap)")
            XCTAssertEqual(region.frame.minX, 0, accuracy: 0.5, cap)
            let first = try XCTUnwrap(H.lines(in: view, intersecting: H.range(rest, in: section)).first).frame
            XCTAssertEqual(first.minX, region.frame.maxX, accuracy: 1, "the word continues at the initial's edge: \(cap)")
            XCTAssertEqual(first.minY, region.frame.minY, accuracy: 1, cap)
            XCTAssertFalse(H.overlaps([glyph], H.ink(rest, in: section, view: view) + H.ink(H.prose, in: section, view: view)), cap)
            BuilderHarness.assertMapRoundTrips(section)
        }
    }

    func testAFloatDirectlyAfterAHeadingStartsBelowItAndLaterBlocksWrapBesideIt() throws {
        let (section, view) = try layout("<h2>Heading words</h2><figure>Alpha box.</figure><p>Short prose.</p><h3>Second heading</h3><p>\(H.prose)</p>",
                                         css: "figure { float:left; width:100px; height:120px }")
        let heading = H.frame("Heading words", in: section, view: view)
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        XCTAssertEqual(region.frame.minY, heading.maxY, accuracy: 1)
        let short = H.frame("Short prose.", in: section, view: view), second = H.frame("Second heading", in: section, view: view)
        XCTAssertEqual(short.minY, region.frame.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(short.minX, 99)
        // Prose shorter than the float: the next block still starts beside it (CSS 2.2 9.5), not below.
        XCTAssertLessThan(second.minY, region.frame.maxY)
        XCTAssertGreaterThanOrEqual(second.minX, 99)
        XCTAssertGreaterThanOrEqual(second.minY, short.maxY - 0.5)
        XCTAssertTrue(proseLines(H.prose, around: region, in: section, view: view).below.contains { $0.minX < 1 })
    }

    func testAFloatAtTheVeryEndOfASectionCountsTowardsItsHeightAndPages() throws {
        let (section, view) = try layout("<p>\(H.prose)</p><figure>Alpha box.</figure>", css: "figure { float:right; width:100px; height:80px }")
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        XCTAssertEqual(region.frame.maxX, 360, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(view.readerLayoutManager.usageBoundsForTextContainer.maxY, region.frame.maxY - 1,
                                    "a trailing box still contributes to the document's height")
        let pages = H.pages(section, size: size).pages
        XCTAssertTrue(pages.contains { NSIntersectionRange($0.range, region.range).length == region.range.length && $0.height >= 79 },
                      "the page showing the box is as tall as the box")
    }

    func testAFloatInsideAListItemKeepsTheItemsTextBesideIt() throws {
        let (section, view) = try layout("<ul><li><span class='f'>Alpha box.</span>Item text. \(H.prose)</li><li>Second item.</li></ul>",
                                         css: ".f { float:left; width:100px; height:60px } ul { padding-left:40px }")
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        let item = H.frame("Item text.", in: section, view: view)
        XCTAssertLessThan(item.minY, region.frame.maxY)
        XCTAssertGreaterThanOrEqual(item.minX, region.frame.maxX - 1)
        XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), [region.frame]))
        XCTAssertGreaterThanOrEqual(H.frame("Second item.", in: section, view: view).minY, region.frame.maxY - 0.5,
                                    "what follows the item's text is not hidden behind the box")
        XCTAssertEqual(section.string.string.components(separatedBy: "\u{2022}").count - 1, 2, "one marker an item")
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testNestedFloatsStayReadableInReadingOrderInsideTheOuterBox() throws {
        let (section, view) = try layout("<div class='o'><p>Outer words.</p><div class='i'>Inner words.</div></div><p>\(H.prose)</p>",
                                         css: ".o { float:left; width:160px } .i { float:right; width:60px }")
        let outer = H.frame("Outer words.", in: section, view: view), inner = H.frame("Inner words.", in: section, view: view)
        let region = try XCTUnwrap(H.region("Outer words.", in: section, view: view))
        XCTAssertEqual(region.frame.width, 160, accuracy: 1)
        XCTAssertTrue(region.frame.insetBy(dx: -1, dy: -1).contains(outer)); XCTAssertTrue(region.frame.insetBy(dx: -1, dy: -1).contains(inner))
        XCTAssertGreaterThanOrEqual(inner.minY, outer.maxY - 0.5, "reading order")
        XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), [region.frame]))
        XCTAssertTrue(section.report.flowBoxesReflowed)
        H.pages(section, size: size)
    }

    func testAHiddenFloatLeavesNoBoxNoTextAndNoDisclosure() throws {
        for hiding in ["display:none", "visibility:hidden; display:none"] {
            let (section, view) = try layout("<figure style='\(hiding)'>Alpha box.</figure><p>\(H.prose)</p>",
                                             css: "figure { float:left; width:100px; height:80px }")
            XCTAssertEqual(section.string.string, H.prose, hiding)
            XCTAssertFalse(view.readerContainer.hasNonlinearGeometry, hiding)
            XCTAssertFalse(section.report.flowBoxesReflowed, hiding)
            XCTAssertEqual(try XCTUnwrap(H.lines(in: view).first).frame.minX, 0, accuracy: 0.5, hiding)
        }
    }

    // MARK: Widths and edges

    func testPercentageFloatWidthsMarginsAndPaddingFollowTheColumnWidth() throws {
        for width: CGFloat in [300, 600, 900] {
            let (section, view) = try layout("<figure>Alpha box.</figure><p>\(H.prose)</p>",
                                             css: "figure { float:left; width:40%; margin-right:5%; padding-left:5% }", size: CGSize(width: width, height: 700))
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
            XCTAssertEqual(region.frame.minX, 0, accuracy: 0.5, "\(width)")
            XCTAssertEqual(region.frame.width, width * 0.5, accuracy: 0.6, "content, padding and margin: \(width)")
            XCTAssertEqual(try XCTUnwrap(region.contentFrame).minX, width * 0.05, accuracy: 0.6, "\(width)")
            XCTAssertEqual(try XCTUnwrap(region.contentFrame).width, width * 0.4, accuracy: 0.6, "\(width)")
            XCTAssertEqual(H.frame("Alpha box.", in: section, view: view).minX, width * 0.05, accuracy: 1, "\(width)")
            let beside = proseLines(H.prose, around: region, in: section, view: view).beside
            XCTAssertEqual(try XCTUnwrap(beside.first).minX, width * 0.5, accuracy: 1, "\(width)")
        }
    }

    func testViewportUnitFloatWidthsFollowTheReadingViewport() throws {
        for viewport in [CGSize(width: 300, height: 500), CGSize(width: 600, height: 700), CGSize(width: 900, height: 400)] {
            for (declaration, expected) in [("width:50vw", viewport.width / 2), ("width:20vh", viewport.height / 5),
                                            ("width:20svh", viewport.height / 5), ("width:20dvh", viewport.height / 5)] {
                let (section, view) = try layout("<figure>Alpha box.</figure><p>\(H.prose)</p>", css: "figure { float:left; \(declaration) }", size: viewport)
                XCTAssertEqual(try XCTUnwrap(H.region("Alpha box.", in: section, view: view)).frame.width, expected, accuracy: 0.6,
                               "\(declaration) at \(viewport)")
            }
        }
    }

    func testFloatWidthsInEmFollowTheReaderFontSize() throws {
        for fontSize: CGFloat in [16, 25] {
            let (section, view) = try layout("<figure>Alpha box.</figure><p>\(H.prose)</p>", css: "figure { float:left; width:10em; height:3em }",
                                             fontSize: fontSize)
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
            XCTAssertEqual(region.frame.width, 10 * fontSize, accuracy: 0.6, "\(fontSize)")
            XCTAssertEqual(region.frame.height, max(3 * fontSize, H.frame("Alpha box.", in: section, view: view).height), accuracy: 1, "\(fontSize)")
        }
    }

    func testFloatBordersReserveSpaceLikeMarginsAndPadding() throws {
        let (section, view) = try layout("<figure>Alpha box.</figure><p>\(H.prose)</p>",
                                         css: "figure { float:left; width:100px; border-left:10px solid black; border-right:6px solid black; padding-right:4px }")
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        XCTAssertEqual(region.frame.width, 120, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(region.contentFrame).minX, 10, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(region.contentFrame).width, 100, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(proseLines(H.prose, around: region, in: section, view: view).beside.first).minX, 120, accuracy: 1)
    }

    func testNegativeFloatMarginsNeverPullTheBoxOutOfTheColumn() throws {
        for side in ["left", "right"] {
            let (section, view) = try layout("<figure>Alpha box.</figure><p>\(H.prose)</p>",
                                             css: "figure { float:\(side); width:100px; height:60px; margin-left:-40px; margin-right:-40px }")
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view), side)
            XCTAssertGreaterThanOrEqual(region.frame.minX, -0.5, side); XCTAssertLessThanOrEqual(region.frame.maxX, 360.5, side)
            XCTAssertEqual(try XCTUnwrap(region.contentFrame).width, 100, accuracy: 0.5, side)
            XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), H.ink("Alpha box.", in: section, view: view)), side)
        }
    }

    /// `doc/native-viewer.md`, Limitations: "`box-sizing` applies to heights only".
    func testBoxSizingDoesNotChangeAFloatsWidth() throws {
        let (section, view) = try layout("<figure>Alpha box.</figure><p>\(H.prose)</p>",
                                         css: "figure { float:left; width:120px; padding:0 20px; box-sizing:border-box; height:60px }")
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        XCTAssertEqual(try XCTUnwrap(region.contentFrame).width, 120, accuracy: 0.5, "the content box keeps the authored width")
        XCTAssertEqual(region.frame.width, 160, accuracy: 1)
    }

    func testARequestedHeightSmallerThanTheContentNeverTruncatesIt() throws {
        let caption = "A caption that is several lines long inside its narrow floating box."
        let (section, view) = try layout("<figure>\(caption)</figure><p>\(H.prose)</p>", css: "figure { float:left; width:120px; height:20px }")
        let region = try XCTUnwrap(H.region(caption, in: section, view: view))
        let ink = H.frame(caption, in: section, view: view)
        XCTAssertGreaterThan(ink.height, 60, "the caption wraps")
        XCTAssertGreaterThanOrEqual(region.frame.maxY, ink.maxY - 0.5, "the box grows to its content")
        XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), H.ink(caption, in: section, view: view)))
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    func testAnImageAloneInAnAutoWidthFloatShrinksTheBoxToTheImage() throws {
        let (section, view) = try layout("<div class='f'><img src='picture.png' alt='Pic'/></div><p>\(H.prose)</p>",
                                         css: ".f { float:left } img { width:120px; height:80px }",
                                         files: ["picture.png": RichFixture.image(width: 240, height: 160)])
        let region = try XCTUnwrap(view.readerContainer.boxRegions.first { !$0.reserved })
        XCTAssertEqual(region.frame.width, 120, accuracy: 1)
        XCTAssertEqual(region.frame.height, 80, accuracy: 2)
        let lines = proseLines(H.prose, around: region, in: section, view: view)
        XCTAssertFalse(lines.beside.isEmpty)
        XCTAssertTrue(lines.beside.allSatisfy { $0.minX >= 119 })
    }

    // MARK: Right to left

    func testRightToLeftProseWrapsBesideLeftAndRightFloats() throws {
        for side in ["left", "right"] {
            let (section, view) = try layout("<div dir='rtl'><figure>Alpha box.</figure><p>\(arabic)</p></div>",
                                             css: "figure { float:\(side); width:100px; height:40px }")
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view), side)
            XCTAssertEqual(region.frame.minX, side == "left" ? 0 : 260, accuracy: 0.5, side)
            let lines = proseLines(arabic, around: region, in: section, view: view)
            XCTAssertFalse(lines.beside.isEmpty, side)
            if side == "left" { XCTAssertTrue(lines.beside.allSatisfy { $0.minX >= 99 && $0.maxX <= 360.5 }, "\(lines.beside)") }
            else { XCTAssertTrue(lines.beside.allSatisfy { $0.maxX <= 261 && $0.minX >= -0.5 }, "\(lines.beside)") }
            XCTAssertTrue(lines.below.dropLast().allSatisfy { $0.maxX > 358 && $0.width > 250 }, "full lines from the right edge below: \(side)")
            XCTAssertFalse(H.overlaps(H.ink(arabic, in: section, view: view), H.ink("Alpha box.", in: section, view: view)), side)
        }
    }

    // MARK: Clear

    func testClearOnlyClearsFloatsThatExistOnItsSide() throws {
        // No float at all: `clear` changes nothing and no geometry is planned.
        let plain = try H.build("<p>First words.</p><p class='c'>Cleared words.</p>", css: H.reset + ".c { clear:both }")
        XCTAssertNil(ReaderBoxLayout.resolve(plain.string, viewport: size).geometry)
        XCTAssertFalse(plain.report.flowBoxesReflowed)
        // One float: only its own side or `both` move the paragraph below it.
        for (side, clear, cleared) in [("left", "none", false), ("left", "right", false), ("left", "left", true), ("left", "both", true),
                                       ("right", "left", false), ("right", "right", true), ("right", "both", true)] {
            let (section, view) = try layout("<figure>Alpha box.</figure><p class='c'>Cleared words here.</p>",
                                             css: "figure { float:\(side); width:100px; height:80px } .c { clear:\(clear) }")
            let frame = H.frame("Cleared words here.", in: section, view: view)
            if cleared {
                XCTAssertEqual(frame.minY, 80, accuracy: 1, "\(side) \(clear)")
                XCTAssertEqual(frame.minX, 0, accuracy: 0.5, "\(side) \(clear)")
            } else {
                XCTAssertEqual(frame.minY, 0, accuracy: 1, "beside the float: \(side) \(clear)")
            }
        }
    }

    /// CSS 2.2 9.5.2: `clear` on a block-level box puts its top border edge below earlier floats,
    /// so everything inside it starts below them. The reader reads `clear` only from the block
    /// that directly owns a paragraph.
    func testClearOnABlockContainerMovesItsParagraphsBelowTheFloat() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/151")
        let (section, view) = try layout("<figure>Alpha box.</figure><div class='c'><p>Cleared words here.</p></div>",
                                         css: "figure { float:left; width:100px; height:80px } .c { clear:both }")
        let frame = H.frame("Cleared words here.", in: section, view: view)
        XCTAssertGreaterThanOrEqual(frame.minY, 79, "the container clears the 80-point float, so its paragraph is below it")
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
    }

    /// HTML's rendering section gives `br` the `clear` property (`br[clear]`), and every browser
    /// starts the next line below the floats: the idiom old books use after a floated figure.
    func testALineBreakWithClearMovesTheRestOfItsParagraphBelowTheFloat() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/151")
        let (section, view) = try layout("<figure>Alpha box.</figure><p>Short.<br style='clear:both'/>Cleared words here.</p>",
                                         css: "figure { float:left; width:100px; height:80px }")
        XCTAssertEqual(H.frame("Short.", in: section, view: view).minY, 0, accuracy: 1, "before the break: beside the float")
        XCTAssertGreaterThanOrEqual(H.frame("Cleared words here.", in: section, view: view).minY, 79, "after the break: below the float")
    }

    /// CSS 2.2 9.5.2: on a float, `clear` adds the constraint that its top is below the bottom of
    /// earlier floats of the named side.
    func testClearOnAFloatPutsItBelowEarlierFloatsOfTheOtherSide() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/151")
        let (section, view) = try layout("<figure class='l'>Alpha box.</figure><figure class='r'>Beta box.</figure><p>\(H.prose)</p>",
                                         css: "figure { width:100px; height:80px } .l { float:left } .r { float:right; clear:left }")
        let right = try XCTUnwrap(H.region("Beta box.", in: section, view: view))
        XCTAssertEqual(right.frame.maxX, 360, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(right.frame.minY, 79, "below the left float it clears")
    }

    // MARK: Containing block

    /// CSS 2.2 9.5 and 10.1: a float moves to the edge of its containing block, the content box
    /// of its nearest block container, not to the edge of the column.
    func testAFloatInsideAnIndentedBlockSitsAtThatBlocksContentEdge() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/150")
        for (side, edge) in [("left", CGFloat(40)), ("right", 320)] {
            let (section, view) = try layout("<blockquote><figure>Alpha box.</figure><p>\(H.prose)</p></blockquote>",
                                             css: "blockquote { margin:0 40px } figure { float:\(side); width:100px; height:60px }")
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view), side)
            XCTAssertEqual(side == "left" ? region.frame.minX : region.frame.maxX, edge, accuracy: 1,
                           "the \(side) float touches the blockquote's content edge, 40 points inside the column")
        }
    }

    /// CSS 2.2 9.5: line boxes beside a float are shortened to make room for it, so a paragraph
    /// whose own margin is narrower than the float starts at the float's edge.
    func testProseWithItsOwnLeftMarginStartsAtTheFloatsEdgeNotPastIt() throws {
        let (section, view) = try layout("<figure>Alpha box.</figure><p class='m'>\(H.prose)</p>",
                                         css: "figure { float:left; width:100px; height:60px } .m { margin-left:50px }")
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        XCTAssertEqual(region.frame.maxX, 100, accuracy: 0.5)
        let lines = proseLines(H.prose, around: region, in: section, view: view)
        XCTAssertFalse(lines.beside.isEmpty)
        for line in lines.beside { XCTAssertEqual(line.minX, 100, accuracy: 1.5, "beside the float: at its edge, not 50 points past it") }
        XCTAssertEqual(try XCTUnwrap(lines.below.first).minX, 50, accuracy: 1, "below the float: the paragraph's own margin")
    }

    /// The same paragraph with and without a float before it: its margins are its own. With a
    /// float in the section the reader's text container takes over line placement, and for a
    /// right-to-left paragraph with margins that placement leaves the column.
    func testRightToLeftProseWithMarginsKeepsThemInASectionWithAFloat() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/150")
        let column = CGSize(width: 400, height: 600)
        let css = "figure { float:left; width:100px; height:40px } .m { margin:0 30px 0 50px }"
        /// The horizontal extent of the paragraph's selectable text, over all of its lines.
        func extent(_ section: SectionText, _ view: ReaderTextView) -> CGRect {
            var bounds = CGRect.null
            for line in H.lines(in: view, intersecting: H.range(arabic, in: section)) {
                for frame in view.segmentFrames(for: line.range) { bounds = bounds.union(frame) }
            }
            return bounds
        }
        let (plain, plainView) = try layout("<div dir='rtl'><p class='m'>\(arabic)</p></div>", css: css, size: column)
        let alone = extent(plain, plainView)
        XCTAssertGreaterThanOrEqual(alone.minX, 48, "without a float the text keeps its 50-point left margin")
        XCTAssertEqual(alone.maxX, 370, accuracy: 1.5, "and starts at its 30-point right margin")
        let (section, view) = try layout("<div dir='rtl'><figure>Alpha box.</figure><p class='m'>\(arabic)</p></div>", css: css, size: column)
        let beside = extent(section, view)
        XCTAssertLessThanOrEqual(beside.maxX, 400.5, "no line may leave the 400-point column")
        XCTAssertEqual(beside.maxX, 370, accuracy: 1.5, "with a float before it the paragraph still starts at its 30-point right margin")
        XCTAssertGreaterThanOrEqual(beside.minX, 48, "and keeps its 50-point left margin")
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    /// CSS Logical Properties 1, 3.1: `inline-start` and `inline-end` map to left and right by
    /// the containing block's direction.
    func testFloatInlineStartAndInlineEndFollowTheWritingDirection() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/124")
        let css = "figure { width:100px; height:40px } .s { float:inline-start } .e { float:inline-end }"
        let (ltr, ltrView) = try layout("<figure class='s'>Start box.</figure><figure class='e'>End box.</figure><p>\(H.prose)</p>", css: css)
        XCTAssertEqual(try XCTUnwrap(H.region("Start box.", in: ltr, view: ltrView)).frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(H.region("End box.", in: ltr, view: ltrView)).frame.maxX, 360, accuracy: 0.5)
        let (rtl, rtlView) = try layout("<div dir='rtl'><figure class='s'>Start box.</figure><figure class='e'>End box.</figure><p>\(arabic)</p></div>", css: css)
        XCTAssertEqual(try XCTUnwrap(H.region("Start box.", in: rtl, view: rtlView)).frame.maxX, 360, accuracy: 0.5,
                       "right to left: the inline start is the right edge")
        XCTAssertEqual(try XCTUnwrap(H.region("End box.", in: rtl, view: rtlView)).frame.minX, 0, accuracy: 0.5,
                       "right to left: the inline end is the left edge")
    }

    // MARK: Width resolution

    /// CSS 2.2 10.4: when `min-width` is greater than `max-width`, the minimum wins.
    func testMinimumWidthWinsOverASmallerMaximumInBoxGeometry() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/153")
        let limits = "width:100px; min-width:200px; max-width:150px"
        var (section, view) = try layout("<figure>Alpha box.</figure><p>\(H.prose)</p>", css: "figure { float:left; \(limits) }")
        XCTAssertEqual(try XCTUnwrap(H.region("Alpha box.", in: section, view: view)).frame.width, 200, accuracy: 1, "a float")
        (section, view) = try layout("<aside>Alpha box.</aside><p>\(H.prose)</p>", css: "aside { position:absolute; left:0; top:0; \(limits) }")
        XCTAssertEqual(try XCTUnwrap(H.region("Alpha box.", in: section, view: view)).frame.width, 200, accuracy: 1, "an absolutely positioned box")
        (section, view) = try layout("<div class='r'><p>\(H.prose)</p></div>", css: ".r { position:relative; \(limits) }")
        let widest = H.lines(in: view, intersecting: H.range(H.prose, in: section)).map(\.frame.maxX).max() ?? 0
        XCTAssertGreaterThan(widest, 152, "a relative container: its lines fill 200 points, not 150")
        XCTAssertLessThanOrEqual(widest, 201)
    }

    /// CSS 2.2 10.3.5: an auto-width float is shrink-to-fit, its widest content. The reader's
    /// centred `figcaption` contributes its text width rather than the measuring column's width.
    func testAnAutoWidthFloatedFigureWithACaptionShrinksToItsContent() throws {
        let (section, view) = try layout("<figure><img id='image' src='picture.png' alt='Pic'/><figcaption>Caption text.</figcaption></figure><p>\(H.prose)</p>",
                                         css: "figure { float:left } img { width:120px; height:80px }",
                                         files: ["picture.png": RichFixture.image(width: 240, height: 160)])
        let region = try XCTUnwrap(H.region("Caption text.", in: section, view: view))
        XCTAssertLessThan(H.frame("Caption text.", in: section, view: view).width, 119, "the image is the widest content")
        XCTAssertEqual(region.frame.width, 120, accuracy: 2, "the figure is as wide as its 120-point image")
        let imageOffset = try XCTUnwrap(section.anchors["image"])
        let image = try XCTUnwrap(view.segmentFrames(for: NSRange(location: imageOffset, length: 1)).first)
        XCTAssertEqual(image.width, 120, accuracy: 1)
        XCTAssertEqual(image.height, 80, accuracy: 1)
        XCTAssertGreaterThanOrEqual(image.minX, region.frame.minX - 0.5)
        XCTAssertLessThanOrEqual(image.maxX, region.frame.maxX + 0.5)
        let lines = proseLines(H.prose, around: region, in: section, view: view)
        XCTAssertFalse(lines.beside.isEmpty, "prose wraps beside the figure")
        XCTAssertTrue(lines.beside.allSatisfy { $0.minX >= 119 }, "\(lines.beside)")
    }

    /// CSS 2.2 10.2: a percentage width refers to the containing block, here the float's 160-point
    /// content box, including the preliminary attachment proposal before its line is clipped.
    func testAPercentageWidthImageInsideASizedFloatIsSizedByTheFloat() throws {
        let column = CGSize(width: 400, height: 600)
        for declaration in ["width:100%", "max-width:100%"] {
            let (section, view) = try layout("<figure><img id='image' src='picture.png' alt='Pic'/><figcaption>Caption text.</figcaption></figure><p>\(H.prose)</p>",
                                             css: "figure { float:right; width:40% } img { \(declaration) }", size: column,
                                             files: ["picture.png": RichFixture.image(width: 600, height: 400)])
            let offset = try XCTUnwrap(section.anchors["image"])
            let image = try XCTUnwrap(view.segmentFrames(for: NSRange(location: offset, length: 1)).first, declaration)
            XCTAssertEqual(image.width, 160, accuracy: 1.5, "40% of the 400-point column: \(declaration)")
            XCTAssertEqual(image.height, 160 * 400 / 600, accuracy: 2, declaration)
            XCTAssertLessThanOrEqual(image.maxX, 400.5, "the image stays inside the column: \(declaration)")
            let region = try XCTUnwrap(H.region("Caption text.", in: section, view: view), declaration)
            XCTAssertEqual(region.frame.minX, 240, accuracy: 1, declaration)
            XCTAssertLessThanOrEqual(region.frame.maxX, 400.5, declaration)
        }
    }

    func testPreliminaryAttachmentProposalUsesContentWidthAndRetainsViewportUnits() {
        let viewport = CGSize(width: 400, height: 600)
        let container = ReaderTextContainer(size: viewport)
        container.viewportSize = viewport
        container.boxOverride = CGRect(x: 240, y: 0, width: 160, height: 200)
        let line = ReaderAttachment.Line(container: container, fragment: CGRect(origin: .zero, size: viewport),
                                         position: .zero, font: nil, characterIndex: 0)
        XCTAssertEqual(line.width, 160)
        XCTAssertEqual(line.viewport, viewport)
        var sizing = ImageSizing(intrinsic: CGSize(width: 600, height: 400))
        sizing.width = .percent(100)
        XCTAssertEqual(sizing.size(lineWidth: line.available, viewport: line.viewport, heightLimit: line.viewport.height).width, 160)
        sizing.width = .viewportWidth(10)
        XCTAssertEqual(sizing.size(lineWidth: line.available, viewport: line.viewport, heightLimit: line.viewport.height).width, 40,
                       "viewport units retain the 400-point page, rather than the 160-point figure")
    }

    func testPercentageImagesResolveInsidePositionedAndInlineBlockFigures() throws {
        let column = CGSize(width: 400, height: 600)
        for box in ["position:absolute; left:30px; top:0; width:40%", "display:inline-block; width:40%"] {
            for declaration in ["width:100%", "max-width:100%", "width:50%", "max-width:50%"] {
                let expected: CGFloat = declaration.contains("50%") ? 80 : 160
                let (section, view) = try layout("<figure><img id='image' src='picture.png' alt='Pic'/><figcaption>Caption.</figcaption></figure><p>\(H.prose)</p>",
                    css: "figure { \(box) } img { \(declaration) }", size: column,
                    files: ["picture.png": RichFixture.image(width: 600, height: 400)])
                let offset = try XCTUnwrap(section.anchors["image"])
                let image = try XCTUnwrap(view.segmentFrames(for: NSRange(location: offset, length: 1)).first)
                let region = try XCTUnwrap(H.region("Caption.", in: section, view: view))
                XCTAssertEqual(image.width, expected, accuracy: 1.5, "\(box); \(declaration)")
                XCTAssertEqual(image.height, expected * 2 / 3, accuracy: 2)
                XCTAssertGreaterThanOrEqual(image.minX, region.frame.minX - 1)
                XCTAssertLessThanOrEqual(image.maxX, region.frame.maxX + 1)
                XCTAssertEqual(region.contentFrame?.width ?? region.frame.width, 160, accuracy: 1.5)
            }
        }
    }

    func testAutoWidthFiguresUseNaturalImagesAndAlignedCaptionAdvances() throws {
        for alignment in ["left", "center", "right"] {
            for declaration in ["", "width:100%", "max-width:100%"] {
                let (section, view) = try layout("<figure><img id='image' src='picture.png' alt='Pic'/><figcaption>Cap.</figcaption></figure><p>\(H.prose)</p>",
                    css: "figure { float:left } figcaption { text-align:\(alignment) } img { \(declaration) }",
                    files: ["picture.png": RichFixture.image(width: 120, height: 80)])
                let region = try XCTUnwrap(H.region("Cap.", in: section, view: view))
                let offset = try XCTUnwrap(section.anchors["image"])
                let image = try XCTUnwrap(view.segmentFrames(for: NSRange(location: offset, length: 1)).first)
                XCTAssertEqual(region.frame.width, 120, accuracy: 2, "\(alignment); \(declaration)")
                XCTAssertEqual(image.width, 120, accuracy: 1.5)
                XCTAssertEqual(image.height, 80, accuracy: 1.5)
                let caption = H.frame("Cap.", in: section, view: view)
                XCTAssertGreaterThanOrEqual(caption.minX, region.frame.minX - 1)
                XCTAssertLessThanOrEqual(caption.maxX, region.frame.maxX + 1)
                let lines = proseLines(H.prose, around: region, in: section, view: view)
                XCTAssertFalse(lines.beside.isEmpty)
                XCTAssertTrue(lines.beside.allSatisfy { $0.minX >= 119 })
            }
        }
    }

    /// CSS Text 3, 5.2: with `overflow-wrap: normal` a line breaks only at a wrap opportunity, so
    /// a number wider than its float overflows on one line. The reader breaks it inside the word.
    func testAWordIsNotBrokenInsideAFloatNarrowerThanIt() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/152")
        let (section, view) = try layout("<p><span class='n'>12345</span>Verse text follows the number. \(H.prose)</p>", css: ".n { float:left; width:20px }")
        let number = H.range("12345", in: section)
        XCTAssertEqual(H.lines(in: view, intersecting: number).count, 1, "the number is one word on one line")
        XCTAssertFalse(H.overlaps(H.ink("12345", in: section, view: view), H.ink("Verse text follows the number.", in: section, view: view)))
    }

    /// CSS 2.2 9.5: "If a shortened line box is too small to contain any content, then the line
    /// box is shifted downward … until either some content fits or there are no more floats
    /// present." A word wider than the slot beside a float goes below it; it is never cut in two.
    func testProseWordsAreNotBrokenInANarrowSlotBesideAFloat() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/152")
        let words = "Extraordinarily considerable vocabulary necessitates uninterrupted consideration."
        let (section, view) = try layout("<figure>Alpha box.</figure><p>\(words) \(H.prose)</p>", css: "figure { float:left; width:300px; height:120px }")
        let text = section.string.string as NSString
        let lines = H.lines(in: view, intersecting: H.range(words, in: section))
        var broken: [String] = []
        for (line, next) in zip(lines, lines.dropFirst()) {
            let last = text.substring(with: NSRange(location: line.range.upperBound - 1, length: 1)), first = text.substring(with: NSRange(location: next.range.location, length: 1))
            if last.rangeOfCharacter(from: .letters) != nil, first.rangeOfCharacter(from: .letters) != nil {
                broken.append(text.substring(with: line.range) + "|" + text.substring(with: next.range).prefix(8))
            }
        }
        XCTAssertEqual(broken, [], "lines that end inside a word, in the 60-point slot beside a 300-point float")
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    // MARK: Groups

    /// `doc/native-viewer.md`: "A box and the prose wrapping beside it stay together when they fit
    /// a page. Oversized groups … instead continue as native blocks". Each row here is one float
    /// and the one line beside it; rows that only touch are not one group.
    func testARunOfFloatAndTextRowsLongerThanAPageKeepsItsFloats() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/149")
        func rows(_ count: Int) throws -> (SectionText, ReaderTextView) {
            try layout("<dl>" + (0..<count).map { "<dt>Term\($0)</dt><dd>Meaning \($0).</dd>" }.joined() + "</dl>",
                       css: "dl, dt, dd { margin:0; padding:0 } dt { float:left; width:80px }")
        }
        for count in [5, 20, 40] { // 40 rows are about 890 points: more than one 600-point page.
            let (section, view) = try rows(count)
            for row in [0, count / 2, count - 1] {
                let term = H.frame("Term\(row)", in: section, view: view), meaning = H.frame("Meaning \(row).", in: section, view: view)
                XCTAssertEqual(meaning.minY, term.minY, accuracy: 1, "\(count) rows: definition \(row) is beside its term")
                XCTAssertGreaterThanOrEqual(meaning.minX, 79, "\(count) rows: definition \(row) is right of the 80-point term")
            }
            H.pages(section, size: size, "\(count) rows")
        }
    }

    func testTheTailOfAnOversizedFloatKeepsEveryCharacterAndFitsItsPages() throws {
        let small = CGSize(width: 360, height: 300)
        let (section, view) = try layout("<aside><p>First part. \(H.prose)</p><p>Second part.</p><p>Third part.</p></aside><p>Following text. \(H.prose)</p>",
                                         css: "aside { float:left; width:150px }", size: small)
        XCTAssertEqual(view.visibleText, section.string.string)
        let parts = ["First part.", "Second part.", "Third part."].map { H.frame($0, in: section, view: view).minY }
        XCTAssertEqual(parts, parts.sorted(), "the box's paragraphs keep their order")
        XCTAssertGreaterThanOrEqual(H.frame("Following text.", in: section, view: view).minY, parts[1] - 0.5, "what follows the box is not above its tail")
        XCTAssertFalse(H.overlaps(H.ink("Following text.", in: section, view: view),
                                  ["Second part.", "Third part."].flatMap { H.ink($0, in: section, view: view) }))
        let pages = H.pages(section, size: small).pages
        XCTAssertGreaterThan(pages.count, 3, "the long box text continues across pages")
        BuilderHarness.assertMapRoundTrips(section)
    }
}
