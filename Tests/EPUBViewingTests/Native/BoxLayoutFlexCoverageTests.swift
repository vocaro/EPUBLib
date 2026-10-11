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

/// The single-column flex and grid subset against CSS Flexible Box Layout 1, CSS Grid Layout 1,
/// CSS Box Alignment 3 and the "Flex and grid alignment" section of `doc/native-viewer.md`.
/// Points, within 2 of the value CSS gives (the documented tolerance), in a 400 by 600 viewport
/// whose y axis starts at the top edge of a box that opens the section.
@MainActor final class BoxLayoutFlexCoverageTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 400, height: 600)
    private let tolerance: CGFloat = 2
    private let column = "display:flex; flex-direction:column; height:300px"
    private enum Place { case top, middle, bottom }
    private enum Side { case left, centre, right }

    private func scrolled(_ body: String, css: String, size: CGSize? = nil, fontSize: CGFloat = 16) throws -> (section: SectionText, view: ReaderTextView) {
        let section = try H.build(body, css: H.reset + css, fontSize: fontSize)
        return (section, H.view(section.string, size: size ?? self.size, pageColumn: false))
    }

    /// One item in a container, and the paragraph after the container.
    private func single(_ container: String, item: String = "", attributes: String = "") throws -> (item: CGRect, after: CGRect, section: SectionText) {
        let (section, view) = try scrolled("<div class='box' \(attributes)><p class='i'>Only item.</p></div><p>After the box.</p>",
                                           css: ".box { \(container) } .i { \(item) }")
        return (H.frame("Only item.", in: section, view: view), H.frame("After the box.", in: section, view: view), section)
    }

    /// The tops of the paragraphs "Row 1." … "Row n." in a container, and of the paragraph after it.
    private func rows(_ count: Int, _ container: String, items: String = "") throws -> (tops: [CGFloat], after: CGFloat, line: CGFloat, section: SectionText) {
        let body = "<div class='box'>" + (1...count).map { "<p class='r\($0)'>Row \($0).</p>" }.joined() + "</div><p>After the box.</p>"
        let (section, view) = try scrolled(body, css: ".box { \(container) } \(items)")
        let frames = (1...count).map { H.frame("Row \($0).", in: section, view: view) }
        return (frames.map(\.minY), H.frame("After the box.", in: section, view: view).minY, frames[0].height, section)
    }

    private func assert(_ frame: CGRect, _ place: Place, in height: CGFloat = 300, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        switch place {
        case .top: XCTAssertEqual(frame.minY, 0, accuracy: tolerance, message, file: file, line: line)
        case .middle: XCTAssertEqual(frame.midY, height / 2, accuracy: tolerance, message, file: file, line: line)
        case .bottom: XCTAssertEqual(frame.maxY, height, accuracy: tolerance, message, file: file, line: line)
        }
    }

    private func assert(_ frame: CGRect, _ side: Side, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        switch side {
        case .left: XCTAssertEqual(frame.minX, 0, accuracy: tolerance, message, file: file, line: line)
        case .centre: XCTAssertEqual(frame.midX, 200, accuracy: tolerance, message, file: file, line: line)
        case .right: XCTAssertEqual(frame.maxX, 400, accuracy: tolerance, message, file: file, line: line)
        }
    }

    // MARK: justify-content

    /// CSS Box Alignment 3, 4.3: with one item `space-between` falls back to `flex-start`,
    /// `space-around` and `space-evenly` to `center`; `left` and `right` behave as `start` on an
    /// axis that is not horizontal; `safe` and `unsafe` only say what overflowing content does.
    func testEveryJustifyContentValueWithOneItemInAColumn() throws {
        let cases: [(String, Place)] = [
            ("flex-start", .top), ("start", .top), ("normal", .top), ("stretch", .top), ("left", .top), ("right", .top), ("space-between", .top),
            ("safe flex-start", .top), ("center", .middle), ("space-around", .middle), ("space-evenly", .middle), ("safe center", .middle),
            ("unsafe center", .middle), ("flex-end", .bottom), ("end", .bottom), ("unsafe end", .bottom),
        ]
        for (value, place) in cases {
            let result = try single(column + "; justify-content:\(value)")
            assert(result.item, place, value)
            XCTAssertEqual(result.after.minY, 300, accuracy: tolerance, "what follows starts below the box: \(value)")
            XCTAssertFalse(result.section.report.flexGridSimplified, value)
        }
        for invalid in ["middle", "center center", "baseline top", "auto"] {
            assert(try single(column + "; justify-content:flex-end; justify-content:\(invalid)").item, .bottom, "an invalid value is dropped: \(invalid)")
        }
    }

    func testJustifyContentWithTwoAndManyItems() throws {
        for (value, positions) in [("start", [0.0, 1]), ("left", [0, 1]), ("right", [0, 1]), ("stretch", [0, 1])] as [(String, [CGFloat])] {
            let result = try rows(2, column + "; justify-content:\(value)")
            for (top, position) in zip(result.tops, positions) { XCTAssertEqual(top, position * result.line, accuracy: tolerance, value) }
        }
        var result = try rows(2, column + "; justify-content:end")
        XCTAssertEqual(result.tops[1] + result.line, 300, accuracy: tolerance); XCTAssertEqual(result.tops[0] + 2 * result.line, 300, accuracy: tolerance)
        // Seven items: the free space is shared between, around or evenly among them.
        result = try rows(7, column + "; justify-content:space-between")
        let line = result.line, free = 300 - 7 * line
        XCTAssertGreaterThan(free, 100)
        for (index, top) in result.tops.enumerated() { XCTAssertEqual(top, CGFloat(index) * (line + free / 6), accuracy: tolerance, "space-between \(index)") }
        result = try rows(7, column + "; justify-content:space-around")
        for (index, top) in result.tops.enumerated() { XCTAssertEqual(top, free / 14 + CGFloat(index) * (line + free / 7), accuracy: tolerance, "space-around \(index)") }
        result = try rows(7, column + "; justify-content:space-evenly")
        for (index, top) in result.tops.enumerated() { XCTAssertEqual(top, CGFloat(index + 1) * free / 8 + CGFloat(index) * line, accuracy: tolerance, "space-evenly \(index)") }
        XCTAssertEqual(result.after, 300, accuracy: tolerance)
    }

    /// An empty box takes no room in the reader's paragraph model, with or without a height.
    func testAContainerWithNoItemsOrOnlyWhitespaceAndHiddenOnesRendersNothing() throws {
        for content in ["", "   \n  ", "<span style='display:none'>Hidden.</span>", " <!-- comment --> <p hidden='hidden'>Hidden too.</p> "] {
            for container in [column + "; justify-content:center", "display:grid; height:300px; place-items:center", "display:flex; height:300px; align-items:center"] {
                let (section, view) = try scrolled("<p>Before.</p><div class='box'>\(content)</div><p>After.</p>", css: ".box { \(container) }")
                XCTAssertEqual(section.string.string, "Before.\nAfter.", "\(content) \(container)")
                XCTAssertFalse(H.hasAlignment(section), "\(content) \(container)")
                XCTAssertFalse(section.report.flexGridSimplified, "\(content) \(container)")
                XCTAssertEqual(H.frame("After.", in: section, view: view).minY, H.frame("Before.", in: section, view: view).maxY, accuracy: 0.5)
            }
        }
    }

    func testBareTextDirectlyInAContainerFormsAnonymousItems() throws {
        let (section, view) = try scrolled("<div class='box'>Bare one<p>Para two.</p>bare three</div><p>After the box.</p>",
                                           css: ".box { \(column); justify-content:space-between; align-items:center }")
        XCTAssertEqual(section.string.string, "Bare one\nPara two.\nbare three\nAfter the box.")
        let frames = ["Bare one", "Para two.", "bare three"].map { H.frame($0, in: section, view: view) }
        let free = 300 - frames.map(\.height).reduce(0, +)
        XCTAssertEqual(frames[0].minY, 0, accuracy: tolerance)
        XCTAssertEqual(frames[1].minY, frames[0].height + free / 2, accuracy: tolerance)
        XCTAssertEqual(frames[2].maxY, 300, accuracy: tolerance)
        for frame in frames { assert(frame, Side.centre, "anonymous items are aligned like elements") }
        BuilderHarness.assertMapRoundTrips(section)
    }

    // MARK: flex-grow and auto margins

    /// CSS Flexbox 9.7: when the flex factors sum to less than one, only that fraction of the
    /// free space is distributed.
    func testFlexGrowFractionsBelowOneDistributeOnlyThatShareOfTheFreeSpace() throws {
        let half = try single(column + "; justify-content:center", item: "flex-grow:0.5")
        let free = 300 - half.item.height
        XCTAssertEqual(half.item.minY, free / 4, accuracy: tolerance, "half goes to the item, below its content; the rest is centred")
        XCTAssertEqual(half.after.minY, 300, accuracy: tolerance)
        let quarters = try rows(2, column + "; justify-content:flex-end", items: ".r1, .r2 { flex-grow:0.25 }")
        let rest = 300 - 2 * quarters.line
        XCTAssertEqual(quarters.tops[0], rest / 2, accuracy: tolerance)
        XCTAssertEqual(quarters.tops[1], rest / 2 + quarters.line + rest / 4, accuracy: tolerance)
        let whole = try single(column + "; justify-content:center", item: "flex-grow:1")
        assert(whole.item, .top, "a grown item keeps its content at its top")
    }

    func testFlexGrowSharesFreeSpaceInProportion() throws {
        var result = try rows(3, column, items: ".r1 { flex-grow:1 } .r2 { flex-grow:3 }")
        var free = 300 - 3 * result.line
        XCTAssertEqual(result.tops[0], 0, accuracy: tolerance)
        XCTAssertEqual(result.tops[1], result.line + free / 4, accuracy: tolerance)
        XCTAssertEqual(result.tops[2], 300 - result.line, accuracy: tolerance)
        result = try rows(2, column, items: ".r1 { flex-grow:2.5 } .r2 { flex-grow:7.5 }")
        free = 300 - 2 * result.line
        XCTAssertEqual(result.tops[1], result.line + free / 4, accuracy: tolerance)
        XCTAssertEqual(result.after, 300, accuracy: tolerance)
    }

    func testFlexShorthandForms() throws {
        func item(_ flex: String) throws -> CGRect { try single(column + "; justify-content:center", item: "flex:\(flex)").item }
        for grows in ["1", "auto", "2 1 0%", "1 1 auto", "30px", "1 30px", "30px 1", "2 2", "1 0", "1e3"] {
            assert(try item(grows), .top, "grows: flex:\(grows)")
        }
        for fixed in ["none", "0", "0 0 auto", "initial", "0 1 auto", "0 auto", "0 0 0", "0 0 0px"] {
            assert(try item(fixed), .middle, "does not grow: flex:\(fixed)")
        }
        for invalid in ["1 2 3 4", "-1", "1 1 1", "grow", "1 -1"] {
            assert(try item(invalid), .middle, "invalid and dropped: flex:\(invalid)")
        }
        let half = try item("0.5")
        XCTAssertEqual(half.minY, (300 - half.height) / 4, accuracy: tolerance)
        // Longhand: zero and an invalid negative value.
        assert(try single(column + "; justify-content:center", item: "flex-grow:0").item, .middle, "flex-grow:0")
        assert(try single(column + "; justify-content:center", item: "flex-grow:1; flex-grow:-1").item, .top, "a negative factor is invalid: the 1 stands")
        assert(try single(column + "; justify-content:center", item: "-webkit-flex:1").item, .top, "-webkit-flex")
    }

    /// CSS Flexbox 8.1: auto margins absorb free space before `justify-content` sees any.
    func testAutoMarginsTakeFreeSpaceBeforeJustifyContent() throws {
        assert(try single(column + "; justify-content:flex-end", item: "margin:auto 0").item, .middle, "both auto margins centre")
        assert(try single(column + "; justify-content:center", item: "margin-top:auto").item, .bottom, "margin-top:auto")
        assert(try single(column + "; justify-content:flex-end", item: "margin-bottom:auto").item, .top, "margin-bottom:auto")
        var result = try rows(2, column + "; justify-content:flex-end", items: ".r1 { margin-bottom:auto }")
        XCTAssertEqual(result.tops[0], 0, accuracy: tolerance); XCTAssertEqual(result.tops[1], 300 - result.line, accuracy: tolerance)
        result = try rows(2, column + "; justify-content:flex-start", items: ".r1 { margin-top:auto }")
        XCTAssertEqual(result.tops[0], 300 - 2 * result.line, accuracy: tolerance); XCTAssertEqual(result.tops[1], 300 - result.line, accuracy: tolerance)
        result = try rows(2, column + "; justify-content:center", items: ".r1, .r2 { margin-top:auto }")
        let free = 300 - 2 * result.line
        XCTAssertEqual(result.tops[0], free / 2, accuracy: tolerance, "two auto margins share the space")
        XCTAssertEqual(result.tops[1], 300 - result.line, accuracy: tolerance)
        // Growth comes first: nothing is left for the margin.
        result = try rows(2, column, items: ".r1 { flex:1 } .r2 { margin-top:auto }")
        XCTAssertEqual(result.tops[0], 0, accuracy: tolerance); XCTAssertEqual(result.tops[1], 300 - result.line, accuracy: tolerance)
    }

    // MARK: Gaps

    func testGapFormsBetweenStackedItems() throws {
        func gap(_ container: String, fontSize: CGFloat = 16) throws -> CGFloat {
            let (section, view) = try scrolled("<div class='box'><p>Gap one.</p><p>Gap two.</p></div>", css: ".box { \(container) }", fontSize: fontSize)
            return H.frame("Gap two.", in: section, view: view).minY - H.frame("Gap one.", in: section, view: view).maxY
        }
        let flex = "display:flex; flex-direction:column; "
        for (declaration, expected) in [("gap:2em", 32), ("gap:12px 40px", 12), ("row-gap:calc(1em + 4px)", 20), ("gap:normal", 0), ("row-gap:0", 0),
                                        ("gap:20px; gap:-5px", 20), ("gap:20px; row-gap:normal", 0), ("column-gap:30px", 0)] as [(String, CGFloat)] {
            XCTAssertEqual(try gap(flex + declaration), expected, accuracy: 0.5, declaration)
        }
        XCTAssertEqual(try gap(flex + "gap:1.5em", fontSize: 25), 37.5, accuracy: 0.5, "an em gap follows the reader's font size")
        for declaration in ["gap:8px", "grid-gap:8px", "grid-row-gap:8px", "row-gap:8px"] {
            XCTAssertEqual(try gap("display:grid; " + declaration), 8, accuracy: 0.5, declaration)
        }
        // Documented: percentage gaps are not laid out.
        XCTAssertEqual(try gap(flex + "gap:10%"), 0, accuracy: 0.5)
        // A gap is part of the content the free space is measured against.
        let result = try rows(2, column + "; justify-content:center; gap:20px")
        XCTAssertEqual(result.tops[0], (300 - 2 * result.line - 20) / 2, accuracy: tolerance)
        XCTAssertEqual(result.tops[1], result.tops[0] + result.line + 20, accuracy: tolerance)
        XCTAssertEqual(result.after, 300, accuracy: tolerance)
        // One item has no gap to show.
        XCTAssertEqual(try single("display:flex; flex-direction:column; gap:50px").after.minY, try single("display:flex; flex-direction:column").after.minY, accuracy: 0.5)
    }

    // MARK: Across the line

    /// CSS Box Alignment 3: `self-start` and `self-end` follow the item, `flex-start`/`start` and
    /// `flex-end`/`end` the container; baseline alignment is documented as not laid out.
    func testAlignItemsAndAlignSelfKeywordsAcrossAColumn() throws {
        let cases: [(String, Side)] = [
            ("flex-start", .left), ("start", .left), ("self-start", .left), ("normal", .left), ("stretch", .left), ("baseline", .left),
            ("first baseline", .left), ("last baseline", .left), ("center", .centre), ("safe center", .centre), ("flex-end", .right),
            ("end", .right), ("self-end", .right), ("unsafe flex-end", .right),
        ]
        for (value, side) in cases {
            assert(try single("display:flex; flex-direction:column; align-items:\(value)").item, side, "align-items:\(value)")
            assert(try single("display:flex; flex-direction:column; align-items:center", item: "align-self:\(value)").item, side, "align-self:\(value)")
        }
        assert(try single("display:flex; flex-direction:column; align-items:center", item: "align-self:auto").item, .centre, "auto takes the container's")
        assert(try single("display:flex; flex-direction:column; align-items:center; align-items:middle").item, .centre, "an invalid value is dropped")
        // Right to left: the start edge is the right one.
        for (value, side) in [("flex-start", Side.right), ("start", .right), ("stretch", .right), ("center", .centre), ("flex-end", .left), ("end", .left)] {
            let result = try single("display:flex; flex-direction:column; align-items:\(value)", attributes: "dir='rtl'")
            assert(result.item, side, "right to left, align-items:\(value)")
        }
    }

    func testARowsOnlyItemFollowsJustifyContentAutoMarginsAndDirection() throws {
        let cases: [(String, String, Side)] = [
            ("justify-content:flex-start", "", .left), ("justify-content:start", "", .left), ("justify-content:normal", "", .left),
            ("justify-content:left", "", .left), ("justify-content:space-between", "", .left), ("justify-content:center", "", .centre),
            ("justify-content:space-around", "", .centre), ("justify-content:space-evenly", "", .centre), ("justify-content:flex-end", "", .right),
            ("justify-content:end", "", .right), ("justify-content:right", "", .right), ("flex-direction:row-reverse", "", .right),
            ("flex-direction:row-reverse; justify-content:flex-end", "", .left), ("flex-direction:row-reverse; justify-content:center", "", .centre),
            ("justify-content:center", "margin-left:auto", .right), ("justify-content:flex-end", "margin-right:auto", .left),
            ("justify-content:flex-end", "margin:0 auto", .centre), ("justify-content:center", "flex:1", .left),
            ("flex-flow:row wrap; justify-content:center", "", .centre),
        ]
        for (container, item, side) in cases {
            let result = try single("display:flex; " + container, item: item)
            assert(result.item, side, "\(container) \(item)")
            XCTAssertFalse(result.section.report.flexGridSimplified, container)
        }
        for (container, side) in [("justify-content:flex-start", Side.right), ("justify-content:flex-end", .left), ("justify-content:left", .left),
                                  ("justify-content:right", .right), ("justify-content:center", .centre), ("flex-direction:row-reverse", .left)] {
            assert(try single("display:flex; " + container, attributes: "dir='rtl'").item, side, "right to left, \(container)")
        }
        // Down the row's height: align-items and align-self.
        for (container, item, place) in [("align-items:center", "", Place.middle), ("align-items:flex-end", "", .bottom), ("align-items:stretch", "", .top),
                                         ("align-items:center", "align-self:flex-start", .top), ("", "align-self:end", .bottom), ("", "margin:auto 0", .middle)] {
            let result = try single("display:flex; height:300px; " + container, item: item)
            assert(result.item, place, "\(container) \(item)")
            XCTAssertEqual(result.after.minY, 300, accuracy: tolerance, "\(container) \(item)")
        }
    }

    // MARK: Direction shorthands

    func testFlexFlowAndColumnReverse() throws {
        for flow in ["column", "column nowrap", "nowrap column", "column wrap-reverse"] {
            // A wrapping column with a definite height is laid out as one column, and disclosed.
            let result = try single("display:flex; flex-flow:\(flow); justify-content:center; height:300px")
            assert(result.item, .middle, "flex-flow:\(flow)")
            XCTAssertEqual(result.section.report.flexGridSimplified, flow.contains("wrap-reverse"), flow)
        }
        assert(try single("display:flex; flex-flow:row; justify-content:center").item, Side.centre, "flex-flow:row")
        assert(try single("display:flex; flex-direction:column; flex-flow:bogus; justify-content:center; height:300px").item, .middle, "an invalid flex-flow is dropped")
        // One item: the main axis starts at the bottom.
        let reverse = "display:flex; flex-direction:column-reverse; height:300px"
        for (value, place) in [("normal", Place.bottom), ("flex-start", .bottom), ("flex-end", .top), ("center", .middle), ("start", .top),
                               ("end", .bottom), ("space-between", .bottom), ("space-around", .middle)] {
            let result = try single(reverse + "; justify-content:\(value)")
            assert(result.item, place, "column-reverse, \(value)")
            XCTAssertFalse(result.section.report.flexGridSimplified, value)
        }
        // Several items: reading order, in block flow, disclosed.
        let several = try rows(3, reverse + "; justify-content:center")
        XCTAssertTrue(several.section.report.flexGridSimplified)
        XCTAssertFalse(H.hasAlignment(several.section))
        for (index, top) in several.tops.enumerated() { XCTAssertEqual(top, CGFloat(index) * several.line, accuracy: 0.5) }
        XCTAssertNotNil(NativeDisclosure.text(for: several.section.report))
    }

    // MARK: Grid

    func testGridPlaceShorthandsAndSelfAlignmentInOneCell() throws {
        let grid = "display:grid; height:300px; "
        let cases: [(String, String, Place, Side)] = [
            ("place-items:end", "", .bottom, .right), ("place-items:start end", "", .top, .right), ("place-items:end start", "", .bottom, .left),
            ("place-items:center stretch", "", .middle, .left), ("", "place-self:center", .middle, .centre), ("", "place-self:end start", .bottom, .left),
            ("place-items:center", "place-self:start", .top, .left), ("place-items:center", "place-self:auto end", .middle, .right),
            ("", "justify-self:center", .top, .centre), ("", "align-self:end", .bottom, .left), ("justify-items:right", "", .top, .right),
            ("justify-items:left", "", .top, .left), ("justify-items:legacy center", "", .top, .left), ("place-content:end", "", .bottom, .left),
            ("place-content:center", "", .middle, .left), ("place-content:space-between", "", .top, .left), ("place-content:space-evenly start", "", .middle, .left),
        ]
        for (container, item, place, side) in cases {
            let result = try single(grid + container, item: item)
            assert(result.item, place, "\(container) \(item)"); assert(result.item, side, "\(container) \(item)")
            XCTAssertEqual(result.after.minY, 300, accuracy: tolerance, "\(container) \(item)")
            XCTAssertFalse(result.section.report.flexGridSimplified, "\(container) \(item)")
        }
    }

    func testGridAlignContentPacksOrStretchesTwoRows() throws {
        let grid = "display:grid; height:300px; align-content:"
        var result = try rows(2, grid + "start")
        let line = result.line, free = 300 - 2 * line
        for (value, tops) in [("start", [0, line]), ("flex-start", [0, line]), ("center", [free / 2, free / 2 + line]), ("end", [free, free + line]),
                              ("flex-end", [free, free + line]), ("space-between", [0, 300 - line]), ("space-around", [free / 4, line + free * 3 / 4]),
                              ("space-evenly", [free / 3, line + free * 2 / 3]), ("stretch", [0, 150]), ("normal", [0, 150])] {
            result = try rows(2, grid + value)
            for (top, expected) in zip(result.tops, tops) { XCTAssertEqual(top, expected, accuracy: tolerance, value) }
            XCTAssertEqual(result.after, 300, accuracy: tolerance, value)
        }
        // Stretched rows: each item is placed in its own half.
        result = try rows(2, "display:grid; height:300px; align-items:end", items: ".r1 { align-self:center }")
        XCTAssertEqual(result.tops[0], (150 - line) / 2, accuracy: tolerance); XCTAssertEqual(result.tops[1], 300 - line, accuracy: tolerance)
        // One row: the fallbacks of the distributed values.
        for (value, place) in [("space-between", Place.top), ("space-around", .middle), ("space-evenly", .middle), ("stretch", .top)] {
            assert(try single(grid + value).item, place, "one row, \(value)")
        }
    }

    func testOneTrackGridTemplatesAlignAndWiderOnesAreDisclosedBlocks() throws {
        let oneTrack = ["grid-template-columns:none", "grid-template-columns:1fr", "grid-template-columns:100%", "grid-template-columns:auto",
                        "grid-template-columns:minmax(0, 1fr)", "grid-template-columns:repeat(1, 1fr)", "grid-template-columns:[full-start] 1fr [full-end]",
                        "grid-template-columns:fit-content(300px)", "grid-template-areas:\"a\" \"b\"", "grid-template:auto / 1fr", "grid:auto-flow / 1fr",
                        "grid-auto-flow:row dense", "grid-template-columns:1fr 1fr; grid-template-columns:1fr"]
        for template in oneTrack {
            let result = try rows(2, "display:grid; height:300px; place-items:center; \(template)")
            XCTAssertFalse(result.section.report.flexGridSimplified, template)
            XCTAssertEqual(result.tops[0], (150 - result.line) / 2, accuracy: tolerance, template)
            XCTAssertEqual(result.tops[1], 150 + (150 - result.line) / 2, accuracy: tolerance, template)
            XCTAssertEqual(result.after, 300, accuracy: tolerance, template)
        }
        let wider = ["grid-template-columns:1fr 1fr", "grid-template-columns:50% 50%", "grid-template-columns:repeat(2, 1fr)",
                     "grid-template-columns:repeat(1, 1fr 1fr)", "grid-template-columns:repeat(auto-fill, minmax(100px, 1fr))",
                     "grid-template-areas:\"a b\"", "grid-template:auto / 1fr 2fr", "grid-auto-flow:column", "grid:auto / auto-flow 1fr"]
        for template in wider {
            let result = try rows(2, "display:grid; height:300px; place-items:center; \(template)")
            XCTAssertTrue(result.section.report.flexGridSimplified, template)
            XCTAssertFalse(H.hasAlignment(result.section), template)
            XCTAssertEqual(result.tops[0], 0, accuracy: 0.5, template); XCTAssertEqual(result.tops[1], result.line, accuracy: 0.5, template)
            XCTAssertEqual(result.after, 2 * result.line, accuracy: 0.5, "blocks in reading order: \(template)")
        }
    }

    /// An inline container with one child sets no disclosure. It still reads in order.
    func testInlineFlexAndInlineGridWithOneChildKeepEveryWordInOrder() throws {
        for display in ["inline-flex", "inline-grid", "-webkit-inline-box"] {
            let (section, view) = try scrolled("<p>Before <span class='f'><span>only child</span></span> after.</p><p>Next paragraph.</p>",
                                               css: ".f { display:\(display); align-items:center; justify-content:center }")
            let words = section.string.string.split(whereSeparator: \.isWhitespace).map(String.init)
            XCTAssertEqual(words, ["Before", "only", "child", "after.", "Next", "paragraph."], display)
            let tops = ["Before", "only child", "after.", "Next paragraph."].map { H.frame($0, in: section, view: view) }
            for (earlier, later) in zip(tops, tops.dropFirst()) {
                XCTAssertTrue(later.minY >= earlier.maxY - 0.5 || (abs(later.minY - earlier.minY) < 0.5 && later.minX >= earlier.maxX - 0.5), display)
            }
            BuilderHarness.assertMapRoundTrips(section)
        }
    }

    // MARK: Heights

    func testDefiniteHeightUnitsAtThreeViewports() throws {
        let centre = "display:flex; flex-direction:column; justify-content:center; "
        func after(_ css: String, body: String = "<div class='box'><p>Sized content.</p></div><p>After.</p>", viewport: CGSize) throws -> (after: CGFloat, middle: CGFloat, line: CGFloat) {
            let (section, view) = try scrolled(body, css: css, size: viewport)
            let content = H.frame("Sized content.", in: section, view: view)
            return (H.frame("After.", in: section, view: view).minY, content.midY, content.height)
        }
        for viewport in [CGSize(width: 320, height: 500), CGSize(width: 400, height: 600), CGSize(width: 700, height: 950)] {
            let w = viewport.width, h = viewport.height
            let cases: [(String, CGFloat)] = [
                ("height:200px", 200), ("height:50vh", h / 2), ("min-height:50vw", w / 2), ("height:50svh", h / 2), ("height:50lvh", h / 2),
                ("height:50dvh", h / 2), ("height:calc(50vh + 20px)", h / 2 + 20), ("height:calc(100vh - 10em)", h - 160),
                ("min-height:calc(25vh + 25vw)", h / 4 + w / 4), ("height:calc(10em + 40px)", 200), ("height:12.5em", 200),
            ]
            for (declaration, expected) in cases {
                let result = try after(".box { \(centre)\(declaration) }", viewport: viewport)
                XCTAssertEqual(result.after, expected, accuracy: tolerance, "\(declaration) at \(viewport)")
                XCTAssertEqual(result.middle, expected / 2, accuracy: tolerance, "\(declaration) at \(viewport)")
            }
            // A percentage needs a definite chain from the viewport.
            var result = try after("html, body { height:100% } .box { \(centre)height:40% }", viewport: viewport)
            XCTAssertEqual(result.after, 0.4 * h, accuracy: tolerance, "\(viewport)")
            result = try after("html { height:100% } .box { \(centre)height:40% }", viewport: viewport)
            XCTAssertEqual(result.after, result.line, accuracy: 0.5, "the body's auto height breaks the chain: block flow at \(viewport)")
            result = try after("body { height:100% } .box { \(centre)height:40% }", viewport: viewport)
            XCTAssertEqual(result.after, result.line, accuracy: 0.5, "the root's auto height breaks the chain at \(viewport)")
            // An ancestor in points makes the chain definite again.
            let nested = "<div class='o'><div class='box'><p>Sized content.</p></div><p>After.</p></div>"
            result = try after(".o { height:300px } .box { \(centre)height:50% }", body: nested, viewport: viewport)
            XCTAssertEqual(result.after, 150, accuracy: tolerance, "\(viewport)")
            result = try after(".o { height:300px } .box { \(centre)height:calc(50% + 20px) }", body: nested, viewport: viewport)
            XCTAssertEqual(result.after, 170, accuracy: tolerance, "a sum with a percentage, exactly: \(viewport)")
            result = try after(".o { min-height:300px } .box { \(centre)min-height:50% }", body: nested, viewport: viewport)
            XCTAssertEqual(result.after, result.line, accuracy: 0.5, "a minimum height is not a definite height for a percentage: \(viewport)")
        }
    }

    /// CSS 2.2 10.7: `max-height` caps `height`, then `min-height` raises it: the minimum wins.
    func testMinimumAndMaximumHeightPrecedence() throws {
        let centre = column.replacingOccurrences(of: "height:300px", with: "justify-content:center")
        for (declarations, expected) in [("height:100px; min-height:300px; max-height:200px", 300), ("height:300px; max-height:200px", 200),
                                         ("height:100px; min-height:200px", 200), ("min-height:200px; max-height:100px", 200),
                                         ("height:250px; min-height:100px; max-height:400px", 250), ("height:80vh; max-height:240px", 240)] as [(String, CGFloat)] {
            let result = try single(centre + "; " + declarations)
            XCTAssertEqual(result.after.minY, expected, accuracy: tolerance, declarations)
            XCTAssertEqual(result.item.midY, expected / 2, accuracy: tolerance, declarations)
        }
        // A maximum alone leaves the height to the content: nothing to distribute.
        let capped = try single(centre + "; max-height:200px")
        XCTAssertEqual(capped.item.minY, 0, accuracy: 0.5); XCTAssertEqual(capped.after.minY, capped.item.maxY, accuracy: 0.5)
    }

    func testBoxSizingPaddingAndBordersOfTheContainer() throws {
        let centre = column + "; justify-content:center"
        var result = try single(centre + "; padding:20px 0; border:10px solid black")
        XCTAssertEqual(result.item.midY, 30 + 150, accuracy: tolerance, "content box: padding and border outside the 300 points")
        XCTAssertEqual(result.after.minY, 360, accuracy: tolerance)
        result = try single(centre + "; padding:20px 0; border:10px solid black; box-sizing:border-box")
        XCTAssertEqual(result.item.midY, 150, accuracy: tolerance, "border box: both inside the 300 points")
        XCTAssertEqual(result.after.minY, 300, accuracy: tolerance)
        result = try single(centre + "; padding:20px 0; border:10px solid black; -webkit-box-sizing:border-box; box-sizing:content-box")
        XCTAssertEqual(result.after.minY, 360, accuracy: tolerance, "the later declaration wins")
        // Vertical percentage padding refers to the containing block's width: 40 of 400 points.
        result = try single(centre + "; padding:10% 0")
        XCTAssertEqual(result.item.midY, 40 + 150, accuracy: tolerance); XCTAssertEqual(result.after.minY, 380, accuracy: tolerance)
        // Padding and border as large as a border-box height leave no box to align in.
        result = try single(column.replacingOccurrences(of: "300px", with: "100px") + "; justify-content:center; box-sizing:border-box; padding:60px 0")
        XCTAssertGreaterThanOrEqual(result.item.minY, -0.5)
        XCTAssertGreaterThanOrEqual(result.after.minY, result.item.maxY + 60 - tolerance, "its content is not clipped: what follows is below it and the padding")
    }

    func testZeroHeightsAndHeightsBeyondOneViewport() throws {
        for declarations in ["height:0", "min-height:0", "height:0vh", "height:calc(10px - 10px)"] {
            let result = try single("display:flex; flex-direction:column; justify-content:center; " + declarations)
            XCTAssertEqual(result.item.minY, 0, accuracy: 0.5, declarations)
            XCTAssertEqual(result.after.minY, result.item.maxY, accuracy: 0.5, "content is never clipped: \(declarations)")
        }
        // "The height used is at most one viewport, so a box that opens a page stays on that page."
        for declarations in ["height:5000px", "min-height:300vh", "height:calc(100vh + 500px)", "height:1e9px"] {
            let result = try single("display:flex; flex-direction:column; justify-content:center; " + declarations)
            XCTAssertEqual(result.item.midY, 300, accuracy: tolerance, declarations)
            XCTAssertEqual(result.after.minY, 600, accuracy: tolerance, declarations)
            let pages = H.pages(result.section, size: size, declarations).pages
            XCTAssertEqual(pages.count, 2, "the box fills its page and what follows starts the next: \(declarations)")
        }
    }

    func testEmHeightsAndGapsFollowTheReaderFontSize() throws {
        for fontSize: CGFloat in [16, 25] {
            let (section, view) = try scrolled("<div class='box'><p>Gap one.</p><p>Gap two.</p></div><p>After.</p>",
                                               css: ".box { display:flex; flex-direction:column; justify-content:center; min-height:20em; gap:2em }", fontSize: fontSize)
            let one = H.frame("Gap one.", in: section, view: view), two = H.frame("Gap two.", in: section, view: view)
            XCTAssertEqual(two.minY - one.maxY, 2 * fontSize, accuracy: 0.5, "\(fontSize)")
            XCTAssertEqual((one.minY + two.maxY) / 2, 10 * fontSize, accuracy: tolerance, "\(fontSize)")
            XCTAssertEqual(H.frame("After.", in: section, view: view).minY, 20 * fontSize, accuracy: tolerance, "\(fontSize)")
        }
    }

    /// Mixed-unit heights are exact on the container itself. On an ancestor the general rule
    /// applies (Limitations: mixed-unit calculations use the nominal 600 by 800 viewport), so a
    /// percentage of it lies between the exact value and that approximation.
    func testAPercentageOfAnAncestorsMixedUnitHeight() throws {
        for viewport in [CGSize(width: 400, height: 600), CGSize(width: 600, height: 800), CGSize(width: 500, height: 1000)] {
            let (section, view) = try scrolled("<div class='box'><p>Sized content.</p></div><p>After.</p>",
                                               css: "html { height:100% } body { height:calc(100vh - 100px) } .box { display:flex; flex-direction:column; justify-content:center; height:100% }",
                                               size: viewport)
            let after = H.frame("After.", in: section, view: view).minY
            let exact = viewport.height - 100, approximated = viewport.height * 0.875
            XCTAssertGreaterThanOrEqual(after, min(exact, approximated) - tolerance, "\(viewport)")
            XCTAssertLessThanOrEqual(after, max(exact, approximated) + tolerance, "\(viewport)")
        }
    }

    // MARK: Interplay

    func testAnAlignedBoxDirectlyAfterAFloatKeepsItsHeightAndCentre() throws {
        let (section, view) = try scrolled("<figure>Alpha box.</figure><div class='box'><p>Centred words.</p></div><p>After the box.</p>",
                                           css: "figure { float:left; width:100px; height:60px } .box { \(column); justify-content:center; height:400px }")
        XCTAssertTrue(view.readerContainer.hasNonlinearGeometry)
        let centred = H.frame("Centred words.", in: section, view: view), after = H.frame("After the box.", in: section, view: view)
        XCTAssertEqual(after.minY - centred.midY, 200, accuracy: tolerance, "the lower half of the box is below its centred line")
        XCTAssertEqual(after.minY, 400, accuracy: tolerance)
        XCTAssertFalse(H.overlaps(H.ink("Centred words.", in: section, view: view), H.ink("Alpha box.", in: section, view: view)))
        XCTAssertFalse(section.report.flexGridSimplified, "the float is outside the container")
        H.pages(section, size: size)
    }

    /// `doc/native-viewer.md`: alignment "never changes a section's characters". It holds for
    /// items that are blocks already; inline children become blocks, as CSS blockifies them,
    /// so there the separators change and only the words and their order stay.
    func testAlignmentRulesNeverChangeCharactersMapOrAnchorsOfBlockItems() throws {
        let long = String(repeating: "A sentence of ordinary prose that fills its lines. ", count: 6)
        let body = """
            <div class="box" id="box"><h2 id="h">Heading</h2><p id="a">First <em>item</em> text.</p><div class="g" id="g"><p>Cell one.</p><p>Cell two.</p></div>\
            <ul><li id="li">A list item</li></ul><p id="l">\(long)</p></div><div class="row"><p id="only">Only in a row.</p></div><p id="end" dir="rtl">نص عربي.</p>
            """
        let css = """
            .box { display:flex; flex-direction:column; justify-content:space-evenly; align-items:flex-end; min-height:80vh; gap:1em; box-sizing:border-box; padding:1em 0 }
            .g { display:grid; place-items:center; align-content:space-around; flex:0.5; row-gap:10px } #a { margin-top:auto; align-self:center; order:0 }
            .row { display:flex; justify-content:flex-end; align-items:center; height:200px } #l { flex-grow:2; max-width:70% }
            """
        let aligned = try H.build(body, css: css), plain = try H.build(body, css: ".box { padding:1em 0 }")
        XCTAssertTrue(H.hasAlignment(aligned)); XCTAssertFalse(H.hasAlignment(plain))
        XCTAssertEqual(aligned.string.string, plain.string.string)
        XCTAssertEqual(aligned.map, plain.map)
        XCTAssertEqual(aligned.anchors, plain.anchors)
        BuilderHarness.assertMapRoundTrips(aligned)
        for viewport in [CGSize(width: 300, height: 400), size, CGSize(width: 900, height: 700)] {
            let resolved = ReaderBoxLayout.resolve(aligned.string, viewport: viewport).text
            XCTAssertEqual(resolved.string, aligned.string.string, "\(viewport)")
            H.pages(aligned, size: viewport, "\(viewport)")
        }
        // Inline children: the same words in the same order, each child a block of its own.
        let inlineBody = "<div class='c'><span>One</span> <span>Two</span> three <em>four</em></div>"
        let stacked = try H.build(inlineBody, css: ".c { display:flex; flex-direction:column }"), flowed = try H.build(inlineBody, css: "")
        XCTAssertEqual(stacked.string.string.split(whereSeparator: \.isWhitespace), flowed.string.string.split(whereSeparator: \.isWhitespace))
        XCTAssertEqual(flowed.string.string, "One Two three four")
        BuilderHarness.assertMapRoundTrips(stacked)
    }

    // MARK: Expected product defects

    /// CSS Flexbox 9.2 and 9.7: an item's outer size includes its own padding and border, so they
    /// are content of the container and come out of its free space. The reader measures the
    /// item's lines alone and puts its padding outside the box's height.
    func testAnItemsOwnPaddingIsPartOfTheContainersContent() throws {
        let (section, view) = try scrolled("<p>Before.</p><div class='box'><div class='item'><p>Line.</p></div></div><p>After.</p>",
                                           css: ".box { \(column); justify-content:center; height:400px } .item { padding:40px 0 }")
        let top = H.frame("Before.", in: section, view: view).maxY
        XCTAssertEqual(H.frame("After.", in: section, view: view).minY, top + 400, accuracy: tolerance, "the box is 400 points tall, padded item included")
        XCTAssertEqual(H.frame("Line.", in: section, view: view).midY, top + 200, accuracy: tolerance, "the item, padding and all, is centred in it")
    }

    /// CSS Flexbox 4: a flex item establishes an independent formatting context, so the margins
    /// of what it holds stay inside it (CSS 2.2 8.3.1) and count as the container's content.
    func testMarginsNestedInsideTheFirstAndLastItemsStayInsideTheBox() throws {
        let (section, view) = try scrolled("<p>Before.</p><div class='box'><div class='item'><p class='m'>Line.</p></div></div><p>After.</p>",
                                           css: ".box { \(column); justify-content:center; height:400px } .m { margin:16px 0 }")
        let top = H.frame("Before.", in: section, view: view).maxY
        XCTAssertEqual(H.frame("After.", in: section, view: view).minY, top + 400, accuracy: tolerance, "the box is 400 points tall")
        XCTAssertEqual(H.frame("Line.", in: section, view: view).midY, top + 200, accuracy: tolerance, "equal margins above and below: the line is in the middle")
    }

    /// CSS Flexbox 4 and 9.7: every in-flow child is a flex item, an empty one too, and takes
    /// its share of the free space: the spacer that pushes a footer to the bottom.
    func testAnEmptyGrowingItemTakesTheFreeSpace() throws {
        let (section, view) = try scrolled("<div class='box'><p>Top line.</p><div class='spacer'></div><p>Bottom line.</p></div><p>After.</p>",
                                           css: ".box { \(column); height:400px } .spacer { flex:1 }")
        XCTAssertEqual(H.frame("Top line.", in: section, view: view).minY, 0, accuracy: tolerance)
        XCTAssertEqual(H.frame("After.", in: section, view: view).minY, 400, accuracy: tolerance)
        XCTAssertEqual(H.frame("Bottom line.", in: section, view: view).maxY, 400, accuracy: tolerance, "the spacer grows, so the last item rests at the bottom")
    }

    /// CSS Box Alignment 3, 6.1 and 6.3: `left` and `right` are values of `justify-*` only.
    /// `align-items: right` is invalid, so the earlier declaration stands.
    func testAlignItemsAndAlignSelfRejectLeftAndRight() throws {
        for value in ["right", "left"] {
            assert(try single("display:flex; flex-direction:column; align-items:center; align-items:\(value)").item, .centre, "align-items:\(value) is invalid")
            assert(try single("display:flex; flex-direction:column; align-items:center", item: "align-self:\(value)").item, .centre, "align-self:\(value) is invalid")
        }
    }
}
