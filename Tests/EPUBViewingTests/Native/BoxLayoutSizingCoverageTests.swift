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

/// Width, margin, padding, indent and line-height resolution against CSS 2.2 sections 8, 10 and
/// 16.1, CSS Values 3 and `doc/issue-21-css-sizing.md`. Points throughout.
@MainActor final class BoxLayoutSizingCoverageTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let widths: [CGFloat] = [300, 600, 900]

    private func resolved(_ section: SectionText, width: CGFloat, height: CGFloat = 700) -> NSAttributedString {
        let text = ReaderBoxLayout.resolve(section.string, viewport: CGSize(width: width, height: height)).text
        XCTAssertEqual(text.string, section.string.string, "resolution never changes characters")
        return text
    }

    // MARK: Auto margins and widths

    func testPercentageWidthBetweenAutoMarginsCentresABlockAtEveryColumnWidth() throws {
        let section = try H.build("""
            <div class='a'><p>Eighty percent wide.</p></div><div class='b'><p>Maximum eighty.</p></div>\
            <div class='o'><div class='i'><p>Nested ninety.</p></div></div><div class='c'><p>Plain auto margins.</p></div>
            """, css: H.reset + ".a { width:80%; margin:0 auto } .b { max-width:80%; margin:1em auto } .o { width:80%; margin:0 auto } "
                + ".i { width:90%; margin:0 auto } .c { margin:0 auto }")
        XCTAssertFalse(section.report.flowBoxesReflowed)
        for width in widths {
            let text = resolved(section, width: width)
            for phrase in ["Eighty percent wide.", "Maximum eighty."] {
                let style = H.paragraphStyle(phrase, in: section, text: text)
                XCTAssertEqual(style.headIndent, width * 0.1, accuracy: 0.05, "\(phrase) \(width)")
                XCTAssertEqual(style.firstLineHeadIndent, width * 0.1, accuracy: 0.05, "\(phrase) \(width)")
                XCTAssertEqual(style.tailIndent, -width * 0.1, accuracy: 0.05, "\(phrase) \(width)")
            }
            // 90% of an 80% box: 4% of the column each side, inside the outer 10%.
            let nested = H.paragraphStyle("Nested ninety.", in: section, text: text)
            XCTAssertEqual(nested.headIndent, width * 0.14, accuracy: 0.05, "\(width)")
            XCTAssertEqual(nested.tailIndent, -width * 0.14, accuracy: 0.05, "\(width)")
            let plain = H.paragraphStyle("Plain auto margins.", in: section, text: text)
            XCTAssertEqual(plain.headIndent, 0, accuracy: 0.05, "auto margins without a width leave the block across the column: \(width)")
            XCTAssertEqual(plain.tailIndent, 0, accuracy: 0.05, "\(width)")
        }
        BuilderHarness.assertMapRoundTrips(section)
    }

    /// `doc/issue-21-css-sizing.md`: "Insets remain bounded to preserve a readable column." The
    /// bound is a third of the column for both sides together.
    func testCentredAndIndentedBlocksKeepAtLeastTwoThirdsOfTheColumn() throws {
        let long = "A paragraph long enough to wrap onto more lines than one inside its box."
        let section = try H.build("<div class='half'><p>Half \(long)</p></div><div class='deep'><p>Deep \(long)</p></div><div class='side'><p>Side \(long)</p></div>",
                                  css: H.reset + ".half { width:50%; margin:0 auto } .deep { margin:0 45% } .side { padding-left:60% }")
        for width in widths {
            let text = resolved(section, width: width)
            let half = H.paragraphStyle("Half", in: section, text: text)
            XCTAssertEqual(half.headIndent, width / 6, accuracy: 0.05, "centred still, each side bounded to a sixth: \(width)")
            XCTAssertEqual(half.tailIndent, -width / 6, accuracy: 0.05, "\(width)")
            for phrase in ["Deep", "Side"] {
                let style = H.paragraphStyle(phrase, in: section, text: text)
                XCTAssertGreaterThanOrEqual(style.headIndent, 0, "\(phrase) \(width)")
                XCTAssertEqual(style.headIndent - style.tailIndent, width / 3, accuracy: 0.05, "\(phrase) \(width)")
            }
            let view = H.view(section.string, size: CGSize(width: width, height: 700))
            XCTAssertTrue(H.lines(in: view).allSatisfy { $0.frame.minX >= -0.5 && $0.frame.maxX <= width + 0.5 }, "\(width)")
        }
    }

    /// The reader sizes an ordinary block only by a percentage width between auto margins. Other
    /// widths leave the block across the column: this pins that it stays whole and readable.
    func testOtherWidthsOnOrdinaryBlocksLeaveTheTextWholeInsideTheColumn() throws {
        let long = "A paragraph long enough to wrap onto more lines than one inside its box at any of these widths."
        let body = "<div class='a'><p>First \(long)</p></div><div class='b'><p>Second \(long)</p></div><div class='c'><p>Third \(long)</p></div>"
        let plain = try H.build(body, css: H.reset)
        let section = try H.build(body, css: H.reset + ".a { width:200px; margin:0 auto } .b { width:50% } .c { max-width:20em; margin:0 auto }")
        XCTAssertEqual(section.string.string, plain.string.string)
        XCTAssertEqual(section.map, plain.map)
        for width in widths {
            let view = H.view(section.string, size: CGSize(width: width, height: 700))
            XCTAssertTrue(H.lines(in: view).allSatisfy { $0.frame.minX >= -0.5 && $0.frame.maxX <= width + 0.5 }, "\(width)")
            XCTAssertEqual(view.visibleText, section.string.string, "\(width)")
        }
    }

    // MARK: Indents

    func testHangingIndentsInPointsAndPercentages() throws {
        let long = "indent paragraph that is long enough to wrap onto a second line of text in every column here, "
            + "even the widest of the three, which holds well over a hundred characters on each of its lines."
        let section = try H.build("<p class='h'>Hanging \(long)</p><p class='hp'>Percent \(long)</p><p class='n'>Negative \(long)</p>",
                                  css: H.reset + ".h { margin-left:2em; text-indent:-2em } .hp { padding-left:10%; text-indent:-10% } .n { text-indent:-5em }")
        for width in widths {
            let text = resolved(section, width: width)
            let hanging = H.paragraphStyle("Hanging", in: section, text: text)
            XCTAssertEqual(hanging.firstLineHeadIndent, 0, accuracy: 0.05, "\(width)"); XCTAssertEqual(hanging.headIndent, 32, accuracy: 0.05, "\(width)")
            let percent = H.paragraphStyle("Percent", in: section, text: text)
            XCTAssertEqual(percent.firstLineHeadIndent, 0, accuracy: 0.05, "\(width)"); XCTAssertEqual(percent.headIndent, width * 0.1, accuracy: 0.05, "\(width)")
            // An indent past the column's edge cannot be drawn: the first line starts at the edge.
            let negative = H.paragraphStyle("Negative", in: section, text: text)
            XCTAssertEqual(negative.firstLineHeadIndent, 0, accuracy: 0.05, "\(width)"); XCTAssertEqual(negative.headIndent, 0, accuracy: 0.05, "\(width)")
            let view = H.view(section.string, size: CGSize(width: width, height: 700))
            let lines = H.lines(in: view, intersecting: H.range("Hanging " + long, in: section)).map(\.frame)
            XCTAssertGreaterThan(lines.count, 1, "\(width)")
            XCTAssertEqual(lines[0].minX, 0, accuracy: 0.5, "\(width)"); XCTAssertEqual(lines[1].minX, 32, accuracy: 0.5, "\(width)")
        }
    }

    func testTextIndentAppliesToTheFirstLineOfEachBlockInABlockquote() throws {
        let long = "long enough to wrap onto another line of text for sure in this narrow quotation."
        let section = try H.build("<blockquote><p>Quote one \(long)</p><p>Quote two \(long)</p><div>Bare block \(long)</div></blockquote><p>Outside \(long)</p>",
                                  css: H.reset + "p { text-indent:2em } blockquote { margin:0 40px }")
        let view = H.view(section.string, size: CGSize(width: 400, height: 700))
        for (phrase, edge) in [("Quote one", CGFloat(40)), ("Quote two", 40), ("Outside", 0)] {
            let lines = H.lines(in: view, intersecting: H.range("\(phrase) \(long)", in: section)).map(\.frame)
            XCTAssertGreaterThan(lines.count, 1, phrase)
            XCTAssertEqual(lines[0].minX, edge + 32, accuracy: 0.5, "first line: \(phrase)")
            XCTAssertEqual(lines[1].minX, edge, accuracy: 0.5, "later lines: \(phrase)")
        }
        // `text-indent` is inherited: the blockquote's own block of text has none here.
        XCTAssertEqual(try XCTUnwrap(H.lines(in: view, intersecting: H.range("Bare block", in: section)).first).frame.minX, 40, accuracy: 0.5)
    }

    /// CSS 2.2 16.1: `text-indent` indents the first line of a block container. The paragraph is
    /// the block; the list marker sits outside the item's box and does not take the indent's place.
    func testTextIndentAppliesToAListItemsFirstParagraph() throws {
        let section = try H.build("<ul><li><p>Item one.</p><p>Item two.</p></li></ul>", css: H.reset + "p { text-indent:2em } ul { padding-left:40px }")
        let view = H.view(section.string, size: CGSize(width: 400, height: 700))
        XCTAssertEqual(H.frame("Item two.", in: section, view: view).minX, 72, accuracy: 1, "the item's second paragraph: 40 points of padding and 2em")
        XCTAssertEqual(H.frame("Item one.", in: section, view: view).minX, 72, accuracy: 1, "its first paragraph is indented the same")
    }

    // MARK: Margins

    func testAdjoiningMarginsCollapseBetweenSiblingsAndThroughAParentsFirstChild() throws {
        let section = try H.build("""
            <p class='a'>One.</p><p class='a'>Two.</p><div class='d'><p class='c'>Three.</p></div><div class='e'><p class='c'>Four.</p></div>\
            <p class='n'>Five.</p><p class='a'>Six.</p><p class='x'>Seven.</p><p class='y'>Eight.</p>
            """, css: H.reset + ".a { margin:20px 0 } .d { margin-top:30px } .c { margin-top:10px } .e { margin-top:30px; padding-top:5px } "
                + ".n { margin:20px 0 -10px } .x { margin-bottom:-10px } .y { margin-top:-20px }")
        let view = H.view(section.string, size: CGSize(width: 400, height: 700))
        let frames = ["One.", "Two.", "Three.", "Four.", "Five.", "Six.", "Seven.", "Eight."].map { H.frame($0, in: section, view: view) }
        let gaps = zip(frames, frames.dropFirst()).map { $1.minY - $0.maxY }
        XCTAssertEqual(gaps[0], 20, accuracy: 0.5, "siblings: the larger of two equal margins, not their sum")
        XCTAssertEqual(gaps[1], 30, accuracy: 0.5, "a parent's and its first child's top margins collapse with the sibling's bottom margin")
        XCTAssertEqual(gaps[2], 45, accuracy: 0.5, "padding keeps a parent's margin apart from its child's: 30 + 5 + 10")
        XCTAssertEqual(gaps[3], 20, accuracy: 0.5)
        XCTAssertEqual(gaps[4], 10, accuracy: 0.5, "a negative margin is deducted from the positive one: 20 - 10")
        XCTAssertEqual(gaps[5], 20, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(gaps[6], -0.5, "two negative margins never draw one paragraph over another")
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    func testAdjoiningPercentageMarginsCollapseAtTheLiveWidth() throws {
        let section = try H.build("<p class='a'>First.</p><p class='b'>Second.</p><div class='d'><p class='c'>Third.</p></div><p class='m'>Fourth.</p><p>Fifth.</p>",
                                  css: H.reset + ".a { margin:5% 0 } .b { margin:10% 0 4% } .d { margin-top:8% } .c { margin-top:3% } .m { margin:10px 0 2% }")
        for width in widths {
            let text = resolved(section, width: width)
            XCTAssertEqual(H.paragraphStyle("First.", in: section, text: text).paragraphSpacing, width * 0.10, accuracy: 0.05, "the larger sibling margin: \(width)")
            XCTAssertEqual(H.paragraphStyle("Second.", in: section, text: text).paragraphSpacing, width * 0.08, accuracy: 0.05, "4%, 8% and 3% adjoin: \(width)")
            XCTAssertEqual(H.paragraphStyle("Third.", in: section, text: text).paragraphSpacing, 10, accuracy: 0.05, "a margin in points: \(width)")
            XCTAssertEqual(H.paragraphStyle("Fourth.", in: section, text: text).paragraphSpacing, width * 0.02, accuracy: 0.05, "\(width)")
        }
    }

    /// CSS 2.2 8.3 and 8.4: percentage margins and padding refer to the containing block's
    /// width, also for the top and bottom.
    func testVerticalPercentagePaddingAndMarginsUseTheContainingWidthNotTheHeight() throws {
        let section = try H.build("<p>Before.</p><div class='d'><p>Inside.</p></div><p>After.</p>", css: H.reset + ".d { padding:10% 0; margin:5% 0 }")
        for width in widths {
            var gaps: [[CGFloat]] = []
            for height: CGFloat in [400, 1400] {
                let view = H.view(section.string, size: CGSize(width: width, height: height))
                let frames = ["Before.", "Inside.", "After."].map { H.frame($0, in: section, view: view) }
                gaps.append([frames[1].minY - frames[0].maxY, frames[2].minY - frames[1].maxY])
            }
            XCTAssertEqual(gaps[0][0], width * 0.15, accuracy: 0.5, "margin and padding above: \(width)")
            XCTAssertEqual(gaps[0][1], width * 0.15, accuracy: 0.5, "\(width)")
            XCTAssertEqual(gaps[0][0], gaps[1][0], accuracy: 0.01, "the viewport's height does not matter: \(width)")
            XCTAssertEqual(gaps[0][1], gaps[1][1], accuracy: 0.01, "\(width)")
        }
    }

    // MARK: Line height

    func testLineHeightFormsGiveTheSameLineBoxes() throws {
        let body = "<p class='n'>Number.</p><p class='x'>Pixels.</p><p class='p'>Percent.</p><p class='e'>Ems.</p><p class='d'>Normal.</p><p class='z'>Zero.</p><p class='i'>Invalid.</p>"
        let css = H.reset + ".n { line-height:2 } .x { line-height:40px } .p { line-height:200% } .e { line-height:2em } .d { line-height:normal } "
            + ".z { line-height:0 } .i { line-height:2; line-height:-1 }"
        for fontSize: CGFloat in [16, 25] {
            let section = try H.build(body, css: css, fontSize: fontSize)
            let view = H.view(section.string, size: CGSize(width: 400, height: 700))
            func height(_ phrase: String) -> CGFloat { H.frame(phrase, in: section, view: view).height }
            XCTAssertEqual(height("Number."), 2 * fontSize, accuracy: 1, "\(fontSize)")
            XCTAssertEqual(height("Percent."), 2 * fontSize, accuracy: 1, "\(fontSize)")
            XCTAssertEqual(height("Ems."), 2 * fontSize, accuracy: 1, "\(fontSize)")
            XCTAssertEqual(height("Invalid."), 2 * fontSize, accuracy: 1, "a negative line height is invalid and dropped: \(fontSize)")
            // Absolute line heights scale with the reader's size, as font sizes do.
            XCTAssertEqual(height("Pixels."), 40 * fontSize / 16, accuracy: 1, "\(fontSize)")
            XCTAssertGreaterThan(height("Normal."), fontSize); XCTAssertLessThan(height("Normal."), 1.5 * fontSize)
            XCTAssertGreaterThanOrEqual(height("Zero."), fontSize / 4, "lines never collapse onto each other: \(fontSize)")
            let tops = ["Number.", "Pixels.", "Percent.", "Ems.", "Normal.", "Zero.", "Invalid."].map { H.frame($0, in: section, view: view).minY }
            XCTAssertEqual(tops, tops.sorted(), "\(fontSize)")
        }
    }

    // MARK: Calculations and units

    /// `doc/native-viewer.md`, Limitations: mixed-unit calculations use the nominal 600-point
    /// viewport. Sums of one unit are exact.
    func testCalculatedFloatWidths() throws {
        func width(_ declaration: String, column: CGFloat) throws -> CGFloat {
            let section = try H.build("<figure>Alpha box.</figure><p>\(H.prose)</p>", css: H.reset + "figure { float:left; width:\(declaration) }")
            let view = H.view(section.string, size: CGSize(width: column, height: 700))
            return try XCTUnwrap(H.region("Alpha box.", in: section, view: view), declaration).frame.width
        }
        for column in widths {
            XCTAssertEqual(try width("calc(25% + 25%)", column: column), column / 2, accuracy: 0.6, "\(column)")
            XCTAssertEqual(try width("calc(100% / 4)", column: column), column / 4, accuracy: 0.6, "\(column)")
            XCTAssertEqual(try width("calc(10px + 5em)", column: column), 90, accuracy: 0.6, "\(column)")
            XCTAssertEqual(try width("calc(10vw + 10vw)", column: column), column / 5, accuracy: 0.6, "\(column)")
            // Exact at the nominal column; elsewhere between the exact value and its approximation.
            let mixed = try width("calc(50% - 20px)", column: column)
            let exact = column / 2 - 20, approximated = column * (50 - 20.0 / 6) / 100
            XCTAssertGreaterThanOrEqual(mixed, min(exact, approximated) - 0.6, "\(column)")
            XCTAssertLessThanOrEqual(mixed, max(exact, approximated) + 0.6, "\(column)")
        }
        XCTAssertEqual(try width("calc(50% - 20px)", column: 600), 280, accuracy: 0.6)
    }

    func testInvalidWidthDeclarationsAreDroppedAndTheEarlierOneStands() throws {
        for invalid in ["-50px", "wide", "50", "10px 20px", "calc(10px +)"] {
            let section = try H.build("<figure>Alpha box.</figure><p>\(H.prose)</p>", css: H.reset + "figure { float:left; width:140px; width:\(invalid) }")
            let view = H.view(section.string, size: CGSize(width: 400, height: 700))
            XCTAssertEqual(try XCTUnwrap(H.region("Alpha box.", in: section, view: view), invalid).frame.width, 140, accuracy: 0.6, invalid)
        }
    }

    /// CSS Values 3, 5.1.2: `vmin` is the smaller of `vw` and `vh`, `vmax` the larger. The reader
    /// reads `vmin` as `vw` and `vmax` as `vh`, which is only right when the viewport is taller
    /// than it is wide.
    func testViewportMinimumAndMaximumUnitsFollowTheSmallerAndLargerSide() throws {
        for viewport in [CGSize(width: 300, height: 500), CGSize(width: 700, height: 400)] {
            let smaller = min(viewport.width, viewport.height), larger = max(viewport.width, viewport.height)
            for (declaration, expected) in [("width:50vmin", smaller / 2), ("width:50vmax", larger / 2)] {
                let section = try H.build("<figure>Alpha box.</figure><p>\(H.prose)</p>", css: H.reset + "figure { float:left; \(declaration) }")
                let view = H.view(section.string, size: viewport)
                XCTAssertEqual(try XCTUnwrap(H.region("Alpha box.", in: section, view: view)).frame.width, expected, accuracy: 0.6,
                               "\(declaration) in a \(Int(viewport.width)) by \(Int(viewport.height)) viewport")
            }
            for (declaration, expected) in [("height:50vmin", smaller / 2), ("height:50vmax", larger / 2)] {
                let section = try H.build("<div class='box'><p>Line.</p></div><p>After.</p>",
                                          css: H.reset + ".box { display:flex; flex-direction:column; justify-content:center; \(declaration) }")
                let view = H.view(section.string, size: viewport, pageColumn: false)
                XCTAssertEqual(H.frame("After.", in: section, view: view).minY, expected, accuracy: 2,
                               "\(declaration) in a \(Int(viewport.width)) by \(Int(viewport.height)) viewport")
            }
        }
    }
}
