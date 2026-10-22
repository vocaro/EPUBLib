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
    /// so everything inside it starts below them. The reader read `clear` only from the block
    /// that directly owns a paragraph (#151).
    func testClearOnABlockContainerMovesItsParagraphsBelowTheFloat() throws {
        let (section, view) = try layout("<figure>Alpha box.</figure><div class='c'><p>Cleared words here.</p></div>",
                                         css: "figure { float:left; width:100px; height:80px } .c { clear:both }")
        let frame = H.frame("Cleared words here.", in: section, view: view)
        XCTAssertGreaterThanOrEqual(frame.minY, 79, "the container clears the 80-point float, so its paragraph is below it")
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
    }

    /// HTML's rendering section gives `br` the `clear` property (`br[clear]`), and every browser
    /// starts the next line below the floats: the idiom old books use after a floated figure.
    func testALineBreakWithClearMovesTheRestOfItsParagraphBelowTheFloat() throws {
        let (section, view) = try layout("<figure>Alpha box.</figure><p>Short.<br style='clear:both'/>Cleared words here.</p>",
                                         css: "figure { float:left; width:100px; height:80px }")
        XCTAssertEqual(H.frame("Short.", in: section, view: view).minY, 0, accuracy: 1, "before the break: beside the float")
        XCTAssertGreaterThanOrEqual(H.frame("Cleared words here.", in: section, view: view).minY, 79, "after the break: below the float")
    }

    /// CSS 2.2 9.5.2: on a float, `clear` adds the constraint that its top is below the bottom of
    /// earlier floats of the named side.
    func testClearOnAFloatPutsItBelowEarlierFloatsOfTheOtherSide() throws {
        let (section, view) = try layout("<figure class='l'>Alpha box.</figure><figure class='r'>Beta box.</figure><p>\(H.prose)</p>",
                                         css: "figure { width:100px; height:80px } .l { float:left } .r { float:right; clear:left }")
        let right = try XCTUnwrap(H.region("Beta box.", in: section, view: view))
        XCTAssertEqual(right.frame.maxX, 360, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(right.frame.minY, 79, "below the left float it clears")
    }

    /// Rule 10 moves the float alone: the prose after it still starts at the top, beside the
    /// float it cleared, and a float names only its own sides: one clearing `right` with only a
    /// left float before it stays on the first row.
    func testClearOnAFloatMovesOnlyThatFloatAndOnlyBelowTheSidesItNames() throws {
        let (section, view) = try layout("<figure class='l'>Alpha box.</figure><figure class='r'>Beta box.</figure><p>\(H.prose)</p>",
                                         css: "figure { width:100px; height:80px } .l { float:left } .r { float:right; clear:left }")
        let left = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        let lines = proseLines(H.prose, around: left, in: section, view: view)
        XCTAssertEqual(try XCTUnwrap(lines.beside.first).minY, 0, accuracy: 1, "the flow is not moved by the float's clearance")
        XCTAssertTrue(lines.beside.allSatisfy { $0.minX >= 99 }, "\(lines.beside)")
        XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), [left.frame, try XCTUnwrap(H.region("Beta box.", in: section, view: view)).frame]))
        let (other, otherView) = try layout("<figure class='l'>Alpha box.</figure><figure class='r'>Beta box.</figure><p>\(H.prose)</p>",
                                            css: "figure { width:100px; height:80px } .l { float:left } .r { float:right; clear:right }")
        XCTAssertEqual(try XCTUnwrap(H.region("Beta box.", in: other, view: otherView)).frame.minY, 0, accuracy: 0.5, "no right float before it")
    }

    /// A cleared container's top is below the float, and so is all it holds: a float it opens
    /// with, and the paragraph after that float. Inside the container nothing clears again, so
    /// that paragraph wraps beside the container's own float (CSS 2.2 9.5.2).
    func testAClearedContainerOpeningWithAFloatPutsTheFloatAndItsProseBelowTheEarlierFloat() throws {
        let (section, view) = try layout("<figure class='a'>Alpha box.</figure><div class='c'><figure class='b'>Beta box.</figure><p>Inside words. \(H.prose)</p></div>",
                                         css: ".a { float:left; width:100px; height:80px } .b { float:right; width:100px; height:60px } .c { clear:both }")
        let beta = try XCTUnwrap(H.region("Beta box.", in: section, view: view))
        XCTAssertEqual(beta.frame.minY, 80, accuracy: 1, "the container's float starts at the container's top")
        XCTAssertEqual(beta.frame.maxX, 360, accuracy: 0.5)
        let inside = H.frame("Inside words.", in: section, view: view)
        XCTAssertEqual(inside.minY, 80, accuracy: 1, "the container's prose starts at its top too, beside its own float")
        XCTAssertEqual(inside.minX, 0, accuracy: 0.5)
        let lines = proseLines(H.prose, around: beta, in: section, view: view)
        XCTAssertTrue(lines.beside.allSatisfy { $0.maxX <= 261 }, "\(lines.beside)")
        XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), [beta.frame]))
    }

    /// `clear` on a paragraph is at its top: a drop cap opening it goes below the float with it,
    /// and its words wrap beside the drop cap instead of clearing that as well.
    func testAClearedParagraphKeepsItsWordsBesideItsOwnDropCap() throws {
        let (section, view) = try layout("<figure>Alpha box.</figure><p class='c'><span class='cap'>D</span>rop cap words. \(H.prose)</p>",
                                         css: "figure { float:left; width:100px; height:80px } .c { clear:both } .cap { float:left; font-size:48px }")
        let cap = try XCTUnwrap(H.region("D", in: section, view: view))
        XCTAssertEqual(cap.frame.minY, 80, accuracy: 1, "the drop cap is at the paragraph's top, below the float")
        XCTAssertEqual(cap.frame.minX, 0, accuracy: 0.5)
        let words = H.frame("rop cap", in: section, view: view)
        XCTAssertEqual(words.minY, cap.frame.minY, accuracy: 1, "the words start beside the drop cap")
        XCTAssertEqual(words.minX, cap.frame.maxX, accuracy: 1)
    }

    /// An empty block that clears, the clearfix idiom, moves what follows it below the float.
    func testAnEmptyClearingBlockMovesTheNextParagraphBelowTheFloat() throws {
        let (section, view) = try layout("<figure>Alpha box.</figure><p>Short.</p><div class='c'></div><p>After words.</p>",
                                         css: "figure { float:left; width:100px; height:80px } .c { clear:left }")
        XCTAssertEqual(H.frame("Short.", in: section, view: view).minY, 0, accuracy: 1)
        let after = H.frame("After words.", in: section, view: view)
        XCTAssertEqual(after.minY, 80, accuracy: 1)
        XCTAssertEqual(after.minX, 0, accuracy: 0.5)
    }

    /// A `br` clears only the sides it names, and the paragraph's lines after the cleared one
    /// take the full column.
    func testALineBreakClearsOnlyTheSidesItNames() throws {
        for (clear, cleared) in [("left", true), ("right", false), ("none", false)] {
            let (section, view) = try layout("<figure>Alpha box.</figure><p>Short.<br style='clear:\(clear)'/>Cleared words here. \(H.prose)</p>",
                                             css: "figure { float:left; width:100px; height:80px }")
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view), clear)
            let first = H.frame("Cleared words here.", in: section, view: view)
            if cleared {
                XCTAssertEqual(first.minY, 80, accuracy: 1, clear)
                XCTAssertEqual(first.minX, 0, accuracy: 0.5, clear)
                XCTAssertTrue(proseLines(H.prose, around: region, in: section, view: view).beside.isEmpty, clear)
            } else {
                XCTAssertLessThan(first.minY, 79, "beside the float: \(clear)")
                XCTAssertGreaterThanOrEqual(first.minX, 99, clear)
            }
            XCTAssertEqual(view.visibleText, section.string.string, clear)
        }
    }

    // MARK: Forced breaks

    /// After a forced break the margin above a box is its first paragraph's spacing before, and
    /// the section's layout sets the box's lines below it. Measured on its own the box had no
    /// such spacing: the plan put the box at the top of the margin and the text after it a
    /// margin higher than drawn. That text, set beside the narrow float in the plan, was drawn
    /// across the wide float under it (#362, seen as a drop-cap paragraph). Neither a line nor
    /// a box's text may cross an earlier float, in the section or on a page.
    func testTextAfterABoxAtAForcedBreakStaysOutOfEarlierFloats() throws {
        let wide = "Wide float words, enough of them to fill three of its lines."
        let floats = "<figure class='n'>Narrow.</figure><figure class='w'>\(wide)</figure>"
        let css = ".n { float:left; width:60px; height:40px } .w { float:left; width:250px; height:100px } .d { float:left; font-size:2em } "
            + ".b { float:right; width:80px; height:40px; margin-top:60px; break-before:page } .under { float:left }"
        for (label, body, boxes, opening) in [
            ("prose", "<figure class='b'>Broken.</figure><p>Prose follows. \(H.prose)</p>", ["Broken."], "Prose follows. "),
            ("drop cap", "<figure class='b'>Broken.</figure><p><span class='d'>D</span>rop cap. \(H.prose)</p>", ["Broken.", "D"], "rop cap. "),
            ("pushed below", "<figure class='b under'>Broken.</figure><p>Prose follows. \(H.prose)</p>", ["Broken."], "Prose follows. "),
        ] {
            let (section, view) = try layout(floats + body, css: css)
            var regions: [ReaderBoxGeometry.Region] = []
            for phrase in ["Narrow.", wide] + boxes {
                let region = try XCTUnwrap(H.region(phrase, in: section, view: view), "\(label): \(phrase)")
                for ink in H.ink(phrase, in: section, view: view) {
                    XCTAssertTrue(region.frame.insetBy(dx: -1, dy: -1).contains(ink), "\(label): \(phrase) \(ink) is drawn in its region \(region.frame)")
                }
                regions.append(region)
            }
            let paragraph = H.range(opening + H.prose, in: section)
            XCTAssertFalse(H.overlaps(H.ink(opening + H.prose, in: section, view: view), regions.map(\.frame)),
                           "\(label): no line of the paragraph crosses a float")
            XCTAssertEqual(paragraph.upperBound, section.string.length, label)
            XCTAssertEqual(view.visibleText, section.string.string, label)
            XCTAssertEqual(Self.proseOverBoxText(in: view), [], label)
            let (paginator, pages) = H.pages(section, size: size, label)
            for page in pages {
                XCTAssertEqual(Self.proseOverBoxText(in: H.pageView(paginator, page: page)), [], "\(label): page at \(page.range.location)")
            }
        }
    }

    /// A paragraph after a forced break keeps the margin above it too, and the plan has its lines
    /// below that margin. TextKit proposes the first line there, and the container took that
    /// place for where the margin starts: it wrapped the lines a margin higher than they are
    /// drawn, beside the narrow float, and drew them across the wide one under it (#362).
    func testAParagraphAtAForcedBreakWrapsWhereItsLinesAreDrawn() throws {
        let wide = "Wide float words, enough of them to fill three of its lines."
        let (section, view) = try layout("<figure class='n'>Narrow.</figure><figure class='w'>\(wide)</figure><p class='f'>Forced paragraph. \(H.prose)</p>",
            css: ".n { float:left; width:60px; height:40px } .w { float:left; width:250px; height:100px } .f { margin-top:30px; break-before:page }")
        let regions = try ["Narrow.", wide].map { try XCTUnwrap(H.region($0, in: section, view: view)) }
        let lines = H.lines(in: view, intersecting: H.range("Forced paragraph.", in: section))
        let first = try XCTUnwrap(lines.first).frame
        XCTAssertEqual(first.minY, 30, accuracy: 0.5, "the paragraph keeps its margin")
        XCTAssertGreaterThanOrEqual(first.minX, regions[1].frame.maxX - 0.5, "its first line is beside the wide float it is drawn beside")
        XCTAssertFalse(H.overlaps(H.ink("Forced paragraph. " + H.prose, in: section, view: view), regions.map(\.frame)))
        XCTAssertEqual(Self.proseOverBoxText(in: view), [])
        let (paginator, pages) = H.pages(section, size: size)
        for page in pages {
            XCTAssertEqual(Self.proseOverBoxText(in: H.pageView(paginator, page: page)), [], "page at \(page.range.location)")
        }
    }

    /// A forced break before a float changes where pages break and nothing else: the margin above
    /// the float is in the flow before it, as before a paragraph (#192), and the section is laid
    /// out as it is with the break unforced, where that margin ends the paragraph before.
    func testAForcedBreakBeforeAFloatLeavesTheSectionsLayoutAsItIsWithoutIt() throws {
        func arrangement(forced: Bool) throws -> (regions: [CGRect], lines: [CGRect]) {
            let (section, view) = try layout("<p>Lead words.</p><figure class='b'>Broken.</figure><p>Prose follows. \(H.prose)</p>",
                css: ".b { float:right; width:80px; height:40px; margin-top:60px\(forced ? "; break-before:page" : "") }")
            return (view.readerContainer.boxRegions.filter { !$0.reserved }.map(\.frame), H.lines(in: view).map(\.frame))
        }
        let unforced = try arrangement(forced: false), forced = try arrangement(forced: true)
        XCTAssertEqual(forced.regions.count, 1)
        XCTAssertEqual(forced.regions.map(\.minY), unforced.regions.map(\.minY))
        XCTAssertEqual(forced.lines.count, unforced.lines.count)
        for (line, other) in zip(forced.lines, unforced.lines) {
            XCTAssertEqual(line.minY, other.minY, accuracy: 0.01)
            XCTAssertEqual(line.minX, other.minX, accuracy: 0.01)
        }
    }

    /// Lines of text outside every box that `view` draws over a box's text, by their source ranges.
    private static func proseOverBoxText(in view: ReaderTextView) -> [NSRange] {
        guard let page = view.readerContainer.boxPage else { return [] }
        let regions = page.geometry.regions.filter { !$0.reserved }
        guard let text = view.contentStorage.textStorage?.string as NSString? else { return [] }
        var boxes: [CGRect] = [], prose: [(NSRange, [CGRect])] = []
        for line in H.lines(in: view) {
            var part = line.range
            while part.length > 0, let scalar = UnicodeScalar(text.character(at: part.location)), CharacterSet.whitespacesAndNewlines.contains(scalar) { part.location += 1; part.length -= 1 }
            while part.length > 0, let scalar = UnicodeScalar(text.character(at: part.upperBound - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { part.length -= 1 }
            guard part.length > 0 else { continue }
            let ink = view.segmentFrames(for: part)
            let source = NSRange(location: line.range.location + page.offset, length: line.range.length)
            if regions.contains(where: { NSIntersectionRange($0.range, source).length > 0 }) { boxes += ink } else { prose.append((source, ink)) }
        }
        return prose.filter { H.overlaps($0.1, boxes) }.map(\.0)
    }

    // MARK: Containing block

    /// CSS 2.2 9.5 and 10.1: a float moves to the edge of its containing block, the content box
    /// of its nearest block container, not to the edge of the column.
    func testAFloatInsideAnIndentedBlockSitsAtThatBlocksContentEdge() throws {
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
    /// right-to-left paragraph with margins that placement left the column.
    ///
    /// The margins are measured on the text without the space that ends each wrapped line. CSS
    /// removes that space (CSS Text 3, 4.1.3), and TextKit hangs it past the line's end: here
    /// into the left margin, by 2.7 points on a line whose text fills it, so a bound on the
    /// selectable text allowed for 2 points and failed by 0.7 (#150). Without the space the bound
    /// is the margin itself.
    func testRightToLeftProseWithMarginsKeepsThemInASectionWithAFloat() throws {
        let column = CGSize(width: 400, height: 600)
        let css = "figure { float:left; width:100px; height:40px } .m { margin:0 30px 0 50px }"
        /// The horizontal extent of the paragraph's selectable text over all of its lines: with
        /// the space each wrapped line ends with, and without it.
        func extent(_ section: SectionText, _ view: ReaderTextView) -> (selectable: CGRect, text: CGRect) {
            var bounds = CGRect.null
            for line in H.lines(in: view, intersecting: H.range(arabic, in: section)) {
                for frame in view.segmentFrames(for: line.range) { bounds = bounds.union(frame) }
            }
            return (bounds, H.ink(arabic, in: section, view: view).reduce(CGRect.null) { $0.union($1) })
        }
        let (plain, plainView) = try layout("<div dir='rtl'><p class='m'>\(arabic)</p></div>", css: css, size: column)
        let alone = extent(plain, plainView)
        XCTAssertGreaterThanOrEqual(alone.text.minX, 49.5, "without a float the text keeps its 50-point left margin")
        XCTAssertEqual(alone.text.maxX, 370, accuracy: 1.5, "and starts at its 30-point right margin")
        let (section, view) = try layout("<div dir='rtl'><figure>Alpha box.</figure><p class='m'>\(arabic)</p></div>", css: css, size: column)
        let beside = extent(section, view)
        XCTAssertGreaterThanOrEqual(beside.selectable.minX, -0.5, "no line may leave the 400-point column, its last space included")
        XCTAssertLessThanOrEqual(beside.selectable.maxX, 400.5, "no line may leave the 400-point column, its last space included")
        XCTAssertEqual(beside.text.maxX, 370, accuracy: 1.5, "with a float before it the paragraph still starts at its 30-point right margin")
        XCTAssertGreaterThanOrEqual(beside.text.minX, 49.5, "and keeps its 50-point left margin")
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    /// A drop cap in a block quotation: the initial is at the quotation's content edge, beside
    /// its word, and not in the quotation's margin 40 points from it (#150). So it is in pages.
    func testADropCapInAnIndentedBlockStandsAtItsWord() throws {
        let (section, view) = try layout("<blockquote><p><span class='cap'>D</span>rop cap words. \(H.prose)</p></blockquote>",
                                         css: "blockquote { margin:0 40px } .cap { float:left; font-size:48px }")
        let cap = try XCTUnwrap(H.region("D", in: section, view: view))
        XCTAssertEqual(cap.frame.minX, 40, accuracy: 0.5, "at the quotation's content edge")
        let words = H.frame("rop cap", in: section, view: view)
        XCTAssertEqual(words.minX, cap.frame.maxX, accuracy: 1, "the word continues at the initial's edge")
        XCTAssertEqual(words.minY, cap.frame.minY, accuracy: 1)
        let lines = proseLines(H.prose, around: cap, in: section, view: view)
        XCTAssertTrue(lines.beside.allSatisfy { $0.minX >= cap.frame.maxX - 0.5 && $0.maxX <= 320.5 }, "\(lines.beside)")
        XCTAssertTrue(lines.below.allSatisfy { abs($0.minX - 40) < 0.5 && $0.maxX <= 320.5 }, "below it the quotation's own edges: \(lines.below)")
        let (paginator, pages) = H.pages(section, size: size)
        let page = H.pageView(paginator, page: try XCTUnwrap(pages.first))
        let opening = try XCTUnwrap(H.lines(in: page).first { NSIntersectionRange($0.range, H.range("rop cap", in: section)).length > 0 })
        XCTAssertEqual(opening.frame.minX, cap.frame.maxX, accuracy: 1, "the page sets the word where the section does")
    }

    /// Both sides of a right-to-left block quotation: a left float at its left content edge and a
    /// right float at its right one, with the prose between them.
    func testFloatsInsideAnIndentedRightToLeftBlockSitAtItsContentEdges() throws {
        let (section, view) = try layout("<blockquote dir='rtl'><figure class='l'>Alpha box.</figure><figure class='r'>Beta box.</figure><p>\(arabic)</p></blockquote>",
                                         css: "blockquote { margin:0 30px 0 50px } figure { width:80px; height:40px } .l { float:left } .r { float:right }")
        let left = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        let right = try XCTUnwrap(H.region("Beta box.", in: section, view: view))
        XCTAssertEqual(left.frame.minX, 50, accuracy: 0.5)
        XCTAssertEqual(right.frame.maxX, 330, accuracy: 0.5)
        let lines = proseLines(arabic, around: left, in: section, view: view)
        XCTAssertFalse(lines.beside.isEmpty)
        XCTAssertTrue(lines.beside.allSatisfy { $0.minX >= left.frame.maxX - 0.5 && $0.maxX <= right.frame.minX + 0.5 }, "\(lines.beside)")
        XCTAssertTrue(lines.below.allSatisfy { $0.minX >= 49.5 && $0.maxX <= 330.5 }, "\(lines.below)")
        XCTAssertFalse(H.overlaps(H.ink(arabic, in: section, view: view), [left.frame, right.frame]))
    }

    /// A float's percentages are of its containing block's width (CSS 2.2 10.2 and 10.3.5), and
    /// percentage margins on that block are resolved at the column's size, as its prose has them.
    func testAFloatInAnIndentedBlockTakesItsPercentagesFromThatBlock() throws {
        for (side, width) in [("left", CGFloat(300)), ("right", 300), ("left", 600), ("right", 600)] {
            let label = "\(side) \(width)"
            let (section, view) = try layout("<blockquote><figure>Alpha box.</figure><p>\(H.prose)</p></blockquote>",
                css: "blockquote { margin:0 10% } figure { float:\(side); width:50%; height:60px }", size: CGSize(width: width, height: 600))
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view), label)
            XCTAssertEqual(region.frame.width, width * 0.4, accuracy: 0.6, "half of the quotation's content width: \(label)")
            XCTAssertEqual(side == "left" ? region.frame.minX : region.frame.maxX, width * (side == "left" ? 0.1 : 0.9), accuracy: 0.6, label)
            let lines = proseLines(H.prose, around: region, in: section, view: view)
            XCTAssertFalse(lines.beside.isEmpty, label)
            XCTAssertTrue(lines.beside.allSatisfy { side == "left" ? abs($0.minX - region.frame.maxX) < 1 : abs($0.minX - width * 0.1) < 1 }, "\(label) \(lines.beside)")
            XCTAssertTrue(lines.below.allSatisfy { abs($0.minX - width * 0.1) < 1 }, "\(label) \(lines.below)")
        }
    }

    /// CSS 2.2 9.5: a line beside a float is shortened on the float's side, so no text is set
    /// between a left float and the line's start, or between a right float and its end. A float
    /// in an indented block, or in a positioned container with a margin, leaves room there for
    /// the prose after the block, and that prose was set in it, on the far side of the float.
    func testProseBesideAFloatIsNeverSetOnTheFloatsOuterSide() throws {
        for (container, side) in [("blockquote", "left"), ("blockquote", "right"), ("div class='p'", "left"), ("div class='p'", "right")] {
            let label = "\(container) \(side)"
            let (section, view) = try layout("<\(container)><figure>Alpha box.</figure><p>Short.</p></\(container.prefix { $0 != " " })><p>\(H.prose)</p>",
                css: "blockquote { margin:0 80px } .p { position:relative; margin-\(side):80px } figure { float:\(side); width:100px; height:120px }")
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view), label)
            XCTAssertEqual(side == "left" ? region.frame.minX : region.frame.maxX, side == "left" ? 80 : 280, accuracy: 0.5, label)
            let lines = proseLines(H.prose, around: region, in: section, view: view)
            XCTAssertFalse(lines.beside.isEmpty, label)
            for line in lines.beside {
                if side == "left" { XCTAssertGreaterThanOrEqual(line.minX, region.frame.maxX - 0.5, "\(label): \(line)") }
                else { XCTAssertLessThanOrEqual(line.maxX, region.frame.minX + 0.5, "\(label): \(line)") }
            }
            XCTAssertTrue(lines.below.contains { $0.minX < 1 && $0.width > 300 }, "the full column below it: \(label)")
            XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), [region.frame]), label)
            XCTAssertEqual(view.visibleText, section.string.string, label)
        }
    }

    /// A sized inline box's percentage width is of its block's content width as well.
    func testAnInlineBlockInAnIndentedBlockTakesItsPercentageWidthFromThatBlock() throws {
        let (section, view) = try layout("<blockquote><p>Lead <span class='i'>Inline box.</span> after.</p></blockquote>",
                                         css: "blockquote { margin:0 40px } .i { display:inline-block; width:50%; height:30px }")
        let region = try XCTUnwrap(H.region("Inline box.", in: section, view: view))
        XCTAssertEqual(region.frame.width, 140, accuracy: 0.6, "half of the quotation's 280-point content width")
        XCTAssertGreaterThan(region.frame.minX, H.frame("Lead", in: section, view: view).maxX - 0.5)
        XCTAssertLessThanOrEqual(region.frame.maxX, 320.5)
    }

    /// CSS Logical Properties 1, 3.1: `inline-start` and `inline-end` map to left and right by
    /// the containing block's direction.
    func testFloatInlineStartAndInlineEndFollowTheWritingDirection() throws {
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
    /// a number wider than its float overflows on one line. The reader cannot overflow its column,
    /// so it widens the float to the number instead (#152).
    func testAWordIsNotBrokenInsideAFloatNarrowerThanIt() throws {
        let (section, view) = try layout("<p><span class='n'>12345</span>Verse text follows the number. \(H.prose)</p>", css: ".n { float:left; width:20px }")
        let number = H.range("12345", in: section)
        XCTAssertEqual(H.lines(in: view, intersecting: number).count, 1, "the number is one word on one line")
        XCTAssertFalse(H.overlaps(H.ink("12345", in: section, view: view), H.ink("Verse text follows the number.", in: section, view: view)))
    }

    /// CSS 2.2 9.5: "If a shortened line box is too small to contain any content, then the line
    /// box is shifted downward … until either some content fits or there are no more floats
    /// present." A word wider than the slot beside a float goes below it; it is never cut in two.
    /// The words do not hyphenate here (`hyphens: manual`); the reader's style sheet has them
    /// hyphenate, and then the slot holds a word's first part (the next test).
    func testProseWordsAreNotBrokenInANarrowSlotBesideAFloat() throws {
        let words = "Extraordinarily considerable vocabulary necessitates uninterrupted consideration."
        let (section, view) = try layout("<figure>Alpha box.</figure><p>\(words) \(H.prose)</p>",
                                         css: "figure { float:left; width:300px; height:120px } p { hyphens:manual }")
        XCTAssertEqual(Self.brokenWords(H.lines(in: view, intersecting: H.range(words, in: section)), in: section), [],
                       "lines that end inside a word, in the 60-point slot beside a 300-point float")
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    /// Each line of `lines` that ends inside a word, with the start of the line after it.
    private static func brokenWords(_ lines: [(range: NSRange, frame: CGRect)], in section: SectionText) -> [String] {
        let text = section.string.string as NSString
        var broken: [String] = []
        for (line, next) in zip(lines, lines.dropFirst()) {
            let last = text.substring(with: NSRange(location: line.range.upperBound - 1, length: 1)), first = text.substring(with: NSRange(location: next.range.location, length: 1))
            if last.rangeOfCharacter(from: .letters) != nil, first.rangeOfCharacter(from: .letters) != nil {
                broken.append(text.substring(with: line.range) + "|" + text.substring(with: next.range).prefix(8))
            }
        }
        return broken
    }

    /// Each line of `lines` that ends inside a word where the platform's English hyphenation
    /// dictionary has no hyphenation point, with the start of the line after it.
    private static func breaksOffHyphenationPoints(_ lines: [(range: NSRange, frame: CGRect)], in section: SectionText) -> [String] {
        let text = section.string.string as NSString
        let locale = Locale(identifier: "en") as NSLocale as CFLocale
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var off: [String] = []
        for (line, next) in zip(lines, lines.dropFirst()) where !brokenWords([line, next], in: section).isEmpty {
            let start = text.rangeOfCharacter(from: separators, options: .backwards, range: NSRange(location: 0, length: line.range.upperBound))
            let end = text.rangeOfCharacter(from: separators, range: NSRange(location: next.range.location, length: text.length - next.range.location))
            let word = start.location == NSNotFound ? 0 : start.upperBound
            let characters = text.substring(with: NSRange(location: word, length: (end.location == NSNotFound ? text.length : end.location) - word)) as CFString
            let point = CFStringGetHyphenationLocationBeforeIndex(characters, line.range.upperBound - word + 1,
                                                                  CFRange(location: 0, length: CFStringGetLength(characters)), 0, locale, nil)
            if point != line.range.upperBound - word { off += brokenWords([line, next], in: section) }
        }
        return off
    }

    /// With `hyphens: auto`, the reader's default, a hyphenation point is a place a line may end
    /// (CSS Text 3, 5.4), so a word's first part and its hyphen are content that fits the slot,
    /// and the slot holds them, as WebKit sets them there. Every line that ends inside a word
    /// ends at a hyphenation point of the platform's dictionary for the text's language. A word
    /// that has none, a number here, is not cut but goes below the float (CSS 2.2 9.5).
    func testAHyphenatingParagraphSetsTheFirstPartOfAWordInTheSlotBesideAFloat() throws {
        let words = "Extraordinarily considerable vocabulary necessitates uninterrupted consideration."
        let (section, view) = try layout("<figure>Alpha box.</figure><p>\(words) \(H.prose)</p>", css: "figure { float:left; width:300px; height:120px }")
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        let lines = H.lines(in: view, intersecting: H.range(words, in: section))
        let first = try XCTUnwrap(lines.first)
        XCTAssertEqual(first.frame.minY, 0, accuracy: 0.5, "the paragraph starts beside the float")
        XCTAssertGreaterThanOrEqual(first.frame.minX, region.frame.maxX - 0.5)
        XCTAssertFalse(Self.brokenWords(lines, in: section).isEmpty, "the slot holds parts of words")
        XCTAssertEqual(Self.breaksOffHyphenationPoints(lines, in: section), [])
        XCTAssertEqual(view.visibleText, section.string.string)
        let number = "12345678901234567890"
        let (other, otherView) = try layout("<figure>Alpha box.</figure><p>\(number) \(H.prose)</p>", css: "figure { float:left; width:300px; height:120px }")
        let opening = H.lines(in: otherView, intersecting: H.range(number, in: other))
        XCTAssertEqual(opening.count, 1, "the number is on one line")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(opening.first).frame.minY, 119.5, "below the float")
        XCTAssertEqual(try XCTUnwrap(opening.first).frame.minX, 0, accuracy: 0.5)
    }

    /// A float narrower than its longest word is as wide as that word and no wider: a verse
    /// number in a float sized in pixels, at the reader's larger font sizes too, stands on one
    /// line with the verse beside it, in the section and on its page (#152).
    func testAFloatNarrowerThanItsLongestWordIsAsWideAsThatWord() throws {
        for fontSize: CGFloat in [16, 25] {
            let (section, view) = try layout("<p><span class='n'>12345</span>Verse text follows the number. \(H.prose)</p>",
                                             css: ".n { float:left; width:20px }", fontSize: fontSize)
            let region = try XCTUnwrap(H.region("12345", in: section, view: view), "\(fontSize)")
            let number = H.frame("12345", in: section, view: view)
            XCTAssertEqual(H.lines(in: view, intersecting: H.range("12345", in: section)).count, 1, "\(fontSize)")
            XCTAssertGreaterThanOrEqual(region.frame.width, number.width - 0.5, "\(fontSize)")
            XCTAssertLessThan(region.frame.width, number.width + 2, "the word's width, not a share of the column: \(fontSize)")
            XCTAssertTrue(region.frame.insetBy(dx: -1, dy: -1).contains(number), "\(fontSize)")
            let verse = try XCTUnwrap(H.lines(in: view, intersecting: H.range("Verse text", in: section)).first).frame
            XCTAssertEqual(verse.minX, region.frame.maxX, accuracy: 1, "the verse starts at the float's edge: \(fontSize)")
            XCTAssertEqual(verse.minY, region.frame.minY, accuracy: 1, "\(fontSize)")
            let (paginator, pages) = H.pages(section, size: size, "\(fontSize)")
            let page = H.pageView(paginator, page: try XCTUnwrap(pages.first))
            XCTAssertEqual(H.lines(in: page, intersecting: H.range("12345", in: section)).count, 1, "the page sets it as the section does: \(fontSize)")
        }
    }

    /// `text-indent` inherits into the float, whose first line starts that far in, as WebKit
    /// starts it. The float holds the indent and the number after it on one line.
    func testAFloatNarrowerThanItsIndentedFirstWordHoldsTheIndentAndTheWord() throws {
        for fontSize: CGFloat in [16, 25] {
            let (section, view) = try layout("<p><span class='n'>12345</span>Verse text follows the number. \(H.prose)</p>",
                                             css: "p { text-indent:1.5em } .n { float:left; width:20px }", fontSize: fontSize)
            let region = try XCTUnwrap(H.region("12345", in: section, view: view), "\(fontSize)")
            let number = H.frame("12345", in: section, view: view)
            XCTAssertEqual(H.lines(in: view, intersecting: H.range("12345", in: section)).count, 1, "\(fontSize)")
            XCTAssertEqual(number.minX, region.frame.minX + 1.5 * fontSize, accuracy: 1, "after the indent: \(fontSize)")
            XCTAssertLessThanOrEqual(number.maxX, region.frame.maxX + 0.5, "\(fontSize)")
            XCTAssertLessThan(region.frame.width, 1.5 * fontSize + number.width + 2, "the indent and the word, no more: \(fontSize)")
            XCTAssertFalse(H.overlaps([number], H.ink("Verse text follows the number.", in: section, view: view)), "\(fontSize)")
        }
    }

    /// Where the float's text hyphenates (`hyphens: auto`, the reader's default) a line may end
    /// at a hyphenation point, so the float keeps its width and sets its words in parts, each
    /// break at a hyphenation point, as WebKit sets them. Where it does not, it is as wide as its
    /// longest word.
    func testAFloatWhoseWordsHyphenateKeepsItsWidthAndOneWhoseWordsDoNotWidensToThem() throws {
        let words = "Extraordinarily considerable vocabulary."
        for hyphens in ["auto", "manual"] {
            let (section, view) = try layout("<aside>\(words)</aside><p>\(H.prose)</p>",
                                             css: "aside { float:right; width:60px; hyphens:\(hyphens) }")
            let region = try XCTUnwrap(H.region(words, in: section, view: view), hyphens)
            let content = try XCTUnwrap(region.contentFrame, hyphens)
            let lines = H.lines(in: view, intersecting: H.range(words, in: section))
            if hyphens == "auto" {
                XCTAssertEqual(content.width, 60, accuracy: 0.5, "the float keeps its width")
                XCTAssertFalse(Self.brokenWords(lines, in: section).isEmpty, "its words are set in parts")
                XCTAssertEqual(Self.breaksOffHyphenationPoints(lines, in: section), [])
            } else {
                let longest = H.frame("Extraordinarily", in: section, view: view).width
                XCTAssertGreaterThanOrEqual(content.width, longest - 0.5, "as wide as its longest word")
                XCTAssertLessThan(content.width, longest + 2)
                XCTAssertEqual(Self.brokenWords(lines, in: section), [])
            }
            XCTAssertEqual(content.maxX, 360, accuracy: 0.5, hyphens)
            let ink = H.ink(words, in: section, view: view)
            XCTAssertTrue(ink.allSatisfy { $0.minX >= content.minX - 0.5 && $0.maxX <= content.maxX + 0.5 }, "\(hyphens): \(ink)")
            XCTAssertEqual(view.visibleText, section.string.string, hyphens)
        }
    }

    /// A line may not end after an opening bracket or guillemet, or before a closing one (UAX #14,
    /// LB13 and LB14), so the space inside `( exemple )` or `« Non »` does not part the brackets
    /// from their word, and nor does a no-break space or the narrow one French sets inside
    /// guillemets. Such a unit is one word to the room beside a float and to a float's width: it
    /// goes below the float, or widens it, and is never cut between two characters.
    func testBracketsAndGuillemetsStayWithTheirWordBesideAndInsideAFloat() throws {
        let quoted = ["« Non »", "«\u{00A0}Non\u{00A0}»", "«\u{202F}Non\u{202F}»"]
        for opening in ["( exemple ) suit."] + quoted.map { $0 + " dit-il." } {
            for slot in [50, 60, 70] {
                let label = "\(opening) beside \(slot)"
                let (section, view) = try layout("<figure>Alpha box.</figure><p lang='fr'>\(opening) \(H.prose)</p>",
                                                 css: "figure { float:left; width:\(360 - slot)px; height:200px } p { hyphens:manual }")
                XCTAssertEqual(Self.brokenWords(H.lines(in: view, intersecting: H.range(opening, in: section)), in: section), [], label)
                XCTAssertEqual(view.visibleText, section.string.string, label)
            }
        }
        for unit in quoted {
            for width in [42, 43] {
                let label = "\(unit) in \(width)"
                let (section, view) = try layout("<p lang='fr'><span class='n'>\(unit) dit-il</span>La suite du texte. \(H.prose)</p>",
                                                 css: ".n { float:left; width:\(width)px } p { hyphens:manual }")
                let region = try XCTUnwrap(H.region(unit, in: section, view: view), label)
                XCTAssertEqual(H.lines(in: view, intersecting: H.range(unit, in: section)).count, 1, label)
                XCTAssertGreaterThanOrEqual(region.frame.width, H.frame(unit, in: section, view: view).width - 0.5, "widened to the unit: \(label)")
            }
        }
    }

    /// The word's width stops at the containing block: a float whose word is wider than the
    /// column is as wide as the column, and its word is broken there, as nothing leaves the column.
    func testAFloatWhoseWordIsWiderThanTheColumnIsAsWideAsTheColumn() throws {
        let number = String(repeating: "1234567890", count: 6)
        let (section, view) = try layout("<blockquote><p><span class='n'>\(number)</span>Verse text follows the number.</p></blockquote>",
                                         css: "blockquote { margin:0 40px } .n { float:left; width:20px }")
        let region = try XCTUnwrap(H.region(number, in: section, view: view))
        XCTAssertEqual(region.frame.minX, 40, accuracy: 0.5)
        XCTAssertEqual(region.frame.maxX, 320, accuracy: 1, "the quotation's content box")
        XCTAssertGreaterThan(H.lines(in: view, intersecting: H.range(number, in: section)).count, 1)
        XCTAssertGreaterThanOrEqual(H.frame("Verse text", in: section, view: view).minY, region.frame.maxY - 0.5)
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    /// The floor is the float's longest word, not its images: an image with no size of its own
    /// in a float narrower than the image still shrinks to the float.
    func testAnImageInAFloatNarrowerThanItStillShrinksToTheFloat() throws {
        let (section, view) = try layout("<figure><img id='image' src='picture.png' alt='Pic'/><figcaption>Cap.</figcaption></figure><p>\(H.prose)</p>",
                                         css: "figure { float:left; width:100px }", files: ["picture.png": RichFixture.image(width: 240, height: 160)])
        let region = try XCTUnwrap(H.region("Cap.", in: section, view: view))
        XCTAssertEqual(region.frame.width, 100, accuracy: 1)
        let image = try XCTUnwrap(view.segmentFrames(for: NSRange(location: try XCTUnwrap(section.anchors["image"]), length: 1)).first)
        XCTAssertEqual(image.width, 100, accuracy: 1)
        XCTAssertTrue(proseLines(H.prose, around: region, in: section, view: view).beside.allSatisfy { $0.minX >= 99 })
    }

    /// CSS 2.2 9.5: a line beside a float too narrow for the line's first word is shifted down
    /// past the float, on either side of it, and starts at the column's edge there. The word does
    /// not hyphenate (`hyphens: manual`).
    func testALineWhoseFirstWordIsWiderThanTheSlotBesideAFloatStartsBelowIt() throws {
        for side in ["left", "right"] {
            let (section, view) = try layout("<figure>Alpha box.</figure><p>Extraordinarily \(H.prose)</p>",
                                             css: "figure { float:\(side); width:300px; height:120px } p { hyphens:manual }")
            let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view), side)
            let first = try XCTUnwrap(H.lines(in: view, intersecting: H.range("Extraordinarily", in: section)).first).frame
            XCTAssertGreaterThanOrEqual(first.minY, region.frame.maxY - 0.5, "below the float: \(side)")
            XCTAssertEqual(first.minX, 0, accuracy: 0.5, side)
            XCTAssertGreaterThan(first.width, 300, "the full column: \(side)")
            XCTAssertFalse(H.overlaps(H.ink(H.prose, in: section, view: view), [region.frame]), side)
            H.pages(section, size: size, side)
        }
    }

    /// Words that fit the slot beside a float are set in it (CSS 2.2 9.5 shifts a line only when
    /// no content fits), and the line that opens with a word too wide for it goes below the float.
    func testShortWordsAreSetInANarrowSlotBesideAFloatAndALongOneBelowIt() throws {
        let short = "To be or not to be."
        let (section, view) = try layout("<figure>Alpha box.</figure><p>\(short) Extraordinarily \(H.prose)</p>",
                                         css: "figure { float:left; width:300px; height:120px } p { hyphens:manual }")
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        let beside = H.lines(in: view, intersecting: H.range(short, in: section)).map(\.frame)
        XCTAssertFalse(beside.isEmpty)
        XCTAssertTrue(beside.allSatisfy { $0.minX >= 299.5 && $0.maxY <= region.frame.maxY + 0.5 }, "in the 60-point slot: \(beside)")
        let long = try XCTUnwrap(H.lines(in: view, intersecting: H.range("Extraordinarily", in: section)).first).frame
        XCTAssertGreaterThanOrEqual(long.minY, region.frame.maxY - 0.5)
        XCTAssertEqual(long.minX, 0, accuracy: 0.5)
    }

    // MARK: Groups

    /// A definition list of `count` rows, each a floated term and the definition beside it.
    private func rows(_ count: Int, css: String = "") throws -> (section: SectionText, view: ReaderTextView) {
        try layout("<dl>" + (0..<count).map { "<dt>Term\($0)</dt><dd>Meaning \($0).</dd>" }.joined() + "</dl>",
                   css: "dl, dt, dd { margin:0; padding:0 } dt { float:left; width:80px } " + css)
    }

    /// `doc/native-viewer.md`: "A box and the prose wrapping beside it stay together when they fit
    /// a page. Oversized groups … instead continue as native blocks". Each row here is one float
    /// and the one line beside it; rows that only touch are not one group.
    func testARunOfFloatAndTextRowsLongerThanAPageKeepsItsFloats() throws {
        for count in [5, 20, 40] { // 40 rows are about 890 points: more than one 600-point page.
            let (section, view) = try rows(count)
            XCTAssertEqual(view.readerContainer.boxRegions.filter { !$0.reserved }.count, count, "\(count) rows: every term floats")
            for row in [0, count / 2, count - 1] {
                let term = H.frame("Term\(row)", in: section, view: view), meaning = H.frame("Meaning \(row).", in: section, view: view)
                XCTAssertEqual(meaning.minY, term.minY, accuracy: 1, "\(count) rows: definition \(row) is beside its term")
                XCTAssertGreaterThanOrEqual(meaning.minX, 79, "\(count) rows: definition \(row) is right of the 80-point term")
            }
            H.pages(section, size: size, "\(count) rows")
        }
    }

    /// The run of rows above on pages: a page ends between two rows, and on every page each
    /// definition is beside its term (#149).
    func testARunOfFloatAndTextRowsLongerThanAPageBreaksBetweenRows() throws {
        let count = 40
        let (section, _) = try rows(count)
        let (paginator, pages) = H.pages(section, size: size)
        XCTAssertGreaterThan(pages.count, 1)
        let views = pages.map { H.pageView(paginator, page: $0) }
        for row in 0..<count {
            let term = H.range("Term\(row)", in: section), meaning = H.range("Meaning \(row).", in: section)
            let page = try XCTUnwrap(pages.firstIndex { NSLocationInRange(term.location, $0.range) })
            XCTAssertTrue(NSLocationInRange(meaning.upperBound - 1, pages[page].range), "row \(row) is on one page")
            func frame(_ range: NSRange) -> CGRect {
                views[page].segmentFrames(for: NSRange(location: range.location - pages[page].range.location, length: range.length))
                    .reduce(CGRect.null) { $0.union($1) }
            }
            let termFrame = frame(term), meaningFrame = frame(meaning)
            XCTAssertFalse(termFrame.isNull || meaningFrame.isNull, "row \(row) is laid out on page \(page)")
            XCTAssertEqual(meaningFrame.minY, termFrame.minY, accuracy: 1, "page \(page): definition \(row) is beside its term")
            XCTAssertGreaterThanOrEqual(meaningFrame.minX, 79, "page \(page): definition \(row) is right of the term")
            XCTAssertLessThanOrEqual(meaningFrame.maxY + pages[page].topSpacing, size.height + 0.75, "row \(row) fits page \(page)")
        }
    }

    /// Terms taller than their definitions make rows that overlap: each definition after the first
    /// starts beside the term above it, and each term below that one, so the run is one group.
    /// Within a page it keeps its floats; longer than a page it continues as native blocks, every
    /// character in reading order, as an oversized group does.
    func testARunOfOverlappingRowsLongerThanAPageContinuesInFlow() throws {
        for count in [5, 40] { // 30-point terms: 150 points for 5 rows, 1,200 for 40.
            let (section, view) = try rows(count, css: "dt { height:30px }")
            let regions = view.readerContainer.boxRegions.filter { !$0.reserved }
            XCTAssertEqual(regions.count, count == 5 ? 5 : 0, "\(count) rows")
            if count == 40 {
                for row in [0, 20, 39] {
                    XCTAssertGreaterThanOrEqual(H.frame("Meaning \(row).", in: section, view: view).minY,
                                                H.frame("Term\(row)", in: section, view: view).maxY - 0.5, "reading order: row \(row)")
                }
            }
            XCTAssertEqual(view.visibleText, section.string.string, "\(count) rows")
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
