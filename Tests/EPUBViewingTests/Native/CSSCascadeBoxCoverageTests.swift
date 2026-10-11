@testable import EPUBViewing
import XCTest

/// CSS 2.2 box properties: margin, padding, border and inset shorthands with their logical
/// aliases, display and visibility, sizes and the table properties.
final class CSSCascadeBoxCoverageTests: XCTestCase {
    private typealias Length = ComputedStyle.Length
    private typealias Border = ComputedStyle.Border
    private let red = CSSCascadeSupport.color(1, 0, 0), blue = CSSCascadeSupport.color(0, 0, 1), green = CSSCascadeSupport.hex(0x008000)

    private func paragraphs(_ bodies: [String]) throws -> [ComputedStyle] {
        let body = bodies.indices.map { "<p id=\"e\($0)\">x</p>" }.joined()
        let css = bodies.enumerated().map { "#e\($0.offset) { \($0.element) }" }.joined(separator: "\n")
        let result = try CSSCascadeSupport.styled(body, css: "p { margin: 0 }\n" + css)
        return bodies.indices.map { result.style("e\($0)") }
    }

    private func edges(_ top: Length, _ right: Length, _ bottom: Length, _ left: Length) -> ComputedStyle.Edges<Length> {
        .init(top: top, right: right, bottom: bottom, left: left)
    }

    func testMarginPaddingAndInsetShorthandsWithLogicalSides() throws {
        let styles = try paragraphs([
            "margin: 1px 2px 3px 4px; padding: 5px 6px",
            "margin: auto; padding-inline: 1px 2px; padding-block-start: 3px; margin-block: 1em; margin-inline-end: auto; margin-inline-start: 7px",
            "position: absolute; inset: 1px 2px",
            "position: absolute; inset: auto 0",
            "margin: 0 auto; margin-top: -1em",
            "padding: 1px 2px 3px; padding-block: 9px",
            "margin: 9px; margin: 1px 2px 3px 4px 5px", "margin: 9px; margin: 1px,2px", "padding: 9px; padding: auto", "padding: 9px; padding: 1px -1px",
            "margin: 9px; margin: 1px bogus", "padding: 9px; padding: inherit 1px", "margin-left: 9px; margin-left: 1px 2px",
        ])
        XCTAssertEqual(styles[0].margin, edges(.points(1), .points(2), .points(3), .points(4)))
        XCTAssertEqual(styles[0].padding, edges(.points(5), .points(6), .points(5), .points(6)))
        XCTAssertEqual(styles[1].margin, edges(.points(16), .auto, .points(16), .points(7)))
        XCTAssertEqual(styles[1].padding, edges(.points(3), .points(2), .points(0), .points(1)))
        XCTAssertEqual([styles[2].positionTop, styles[2].positionRight, styles[2].positionBottom, styles[2].positionLeft],
                       [.points(1), .points(2), .points(1), .points(2)])
        XCTAssertEqual([styles[3].positionTop, styles[3].positionRight, styles[3].positionBottom, styles[3].positionLeft],
                       [.auto, .points(0), .auto, .points(0)])
        XCTAssertEqual(styles[4].margin, edges(.points(-16), .auto, .points(0), .auto))
        XCTAssertEqual(styles[5].padding, edges(.points(9), .points(2), .points(9), .points(2)))
        XCTAssertEqual(styles[6].margin, .init(.points(9)), "Five values are invalid, so the earlier shorthand stays")
        XCTAssertEqual(styles[7].margin, .init(.points(9)), "A comma")
        XCTAssertEqual(styles[8].padding, .init(.points(9)), "padding: auto")
        XCTAssertEqual(styles[9].padding, .init(.points(9)), "One negative padding invalidates the declaration")
        XCTAssertEqual(styles[10].margin, .init(.points(9)))
        XCTAssertEqual(styles[11].padding, .init(.points(9)), "A global keyword cannot be one of several values")
        XCTAssertEqual(styles[12].margin.left, .points(9))
    }

    func testBorderShorthandsTakeWidthStyleAndColorInAnyOrder() throws {
        let styles = try paragraphs([
            "border: red solid 1px",
            "border: solid",
            "border: 2px solid red; border: none",
            "border: 2px solid red; border: 0",
            "border: thin",
            "border: 4px solid red; border-color: blue green; border-style: dotted; border-width: thin medium thick 7px",
            "border-top: 2px dashed blue; border-inline-start: 3px double red; border-block-end: thick solid",
            "border: 1em solid; font-size: 20px",
            "border: 2px solid red; border-left: hidden",
            "border-style: solid; border-width: 2px 4px; border-color: CurrentColor",
            "border-right: 6px groove rgb(0 0 255); border-right-color: red; border-right-width: 1px; border-right-style: ridge",
        ])
        XCTAssertEqual(styles[0].border, .init(Border(width: 1, style: .solid, color: red)))
        XCTAssertEqual(styles[1].border, .init(Border(width: 3, style: .solid, color: nil)), "The width defaults to medium and the color to the text's")
        XCTAssertEqual(styles[2].border, .init(Border(width: 0, style: .none, color: nil)), "A shorthand resets every part it omits")
        XCTAssertEqual(styles[3].border, .init(Border(width: 0, style: .none, color: nil)))
        XCTAssertEqual(styles[4].border.top.width, 0, "A width without a style draws nothing")
        XCTAssertEqual(styles[5].border.top, Border(width: 1, style: .dotted, color: blue))
        XCTAssertEqual(styles[5].border.right, Border(width: 3, style: .dotted, color: green))
        XCTAssertEqual(styles[5].border.bottom, Border(width: 5, style: .dotted, color: blue))
        XCTAssertEqual(styles[5].border.left, Border(width: 7, style: .dotted, color: green))
        XCTAssertEqual(styles[6].border.top, Border(width: 2, style: .dashed, color: blue))
        XCTAssertEqual(styles[6].border.left, Border(width: 3, style: .double, color: red))
        XCTAssertEqual(styles[6].border.bottom, Border(width: 5, style: .solid, color: nil))
        XCTAssertEqual(styles[6].border.right, Border(width: 0, style: .none, color: nil))
        XCTAssertEqual(styles[7].border.top.width, 20, "em is the element's own font size")
        XCTAssertEqual(styles[8].border.left, Border(width: 0, style: .hidden, color: nil))
        XCTAssertEqual(styles[8].border.right, Border(width: 2, style: .solid, color: red))
        XCTAssertEqual(styles[9].border.top, Border(width: 2, style: .solid, color: nil))
        XCTAssertEqual(styles[9].border.left, Border(width: 4, style: .solid, color: nil))
        XCTAssertEqual(styles[10].border.right, Border(width: 1, style: .ridge, color: red))
        XCTAssertFalse(styles[10].border.top.isVisible)
    }

    func testInvalidBorderDeclarationsLeaveTheEarlierBorder() throws {
        let invalid = ["border: 1px solid red blue", "border: solid solid", "border: 1px 2px solid", "border: -1px solid", "border: 10% solid",
                       "border: 1px solid bogus", "border-width: -1px", "border-width: 1px 2px 3px 4px 5px", "border-style: bogus",
                       "border-left-style: dotted dashed", "border-color: red bogus", "border-top: 1px, solid", "border-width: 10%"]
        let styles = try paragraphs(invalid.map { "border: 2px dashed blue; \($0)" })
        for (value, style) in zip(invalid, styles) { XCTAssertEqual(style.border, .init(Border(width: 2, style: .dashed, color: blue)), value) }
    }

    func testTheComputedWidthOfAnUndrawnBorderIsZeroAlsoWhenInherited() throws {
        let result = try CSSCascadeSupport.styled("""
            <p id="p">a<span id="ps">b</span></p><p id="q">c<span id="qs">d</span></p><p id="r">e</p><p id="s">f</p><p id="t">g<span id="ts">h</span></p>
            """, css: """
            #p { border: 5px none red } #ps { border-width: inherit; border-style: solid }
            #q { border: 5px solid red } #qs { border: inherit }
            #r { border-top-style: solid } #s { border: 2px solid; border-width: initial }
            #t { border: 5px solid red } #ts { border-style: solid }
            """)
        XCTAssertEqual(result.style("p").border.top.width, 0)
        XCTAssertEqual(result.style("ps").border.top.width, 0, "CSS 2.2 §8.5.1: the computed width is 0 when the style is none")
        XCTAssertEqual(result.style("qs").border, .init(Border(width: 5, style: .solid, color: red)))
        XCTAssertEqual(result.style("r").border.top, Border(width: 3, style: .solid, color: nil), "medium")
        XCTAssertEqual(result.style("r").border.left.width, 0)
        XCTAssertEqual(result.style("s").border.top.width, 3)
        XCTAssertEqual(result.style("ts").border.top, Border(width: 3, style: .solid, color: nil), "Borders are not inherited")
    }

    func testDisplayKeywordsVisibilityAndFloat() throws {
        typealias Display = ComputedStyle.Display
        let displays: [(String, Display)] = [
            ("none", .none), ("inline", .inline), ("BLOCK", .block), ("list-item", .listItem), ("inline-block", .inlineBlock), ("table", .table),
            ("inline-table", .table), ("table-row-group", .tableRowGroup), ("table-header-group", .tableHeaderGroup),
            ("table-footer-group", .tableFooterGroup), ("table-row", .tableRow), ("table-cell", .tableCell), ("table-caption", .tableCaption),
            ("table-column", .tableColumn), ("table-column-group", .tableColumnGroup), ("ruby", .ruby), ("ruby-text", .rubyText),
            ("flow-root", .block), ("block flow", .block), ("inline flow-root", .inlineBlock), ("inline list-item", .listItem),
            ("block ruby", .ruby), ("list-item; display: bogus", .listItem), ("list-item; display: block block block block", .listItem),
            ("list-item; display: inline 5px", .listItem), ("list-item; display: \"block\"", .listItem),
        ]
        let body = "<div>" + displays.indices.map { "<span id=\"d\($0)\">x<i id=\"c\($0)\">y</i></span>" }.joined() + "</div>"
        let css = displays.enumerated().map { "#d\($0.offset) { display: \($0.element.0) }" }.joined(separator: "\n")
        let result = try CSSCascadeSupport.styled(body + """
            <div id="hidden"><p id="inherits">a<span id="shown">b</span></p></div><p id="collapse">c</p><p id="invalid">d</p>
            <p id="left">e<span id="float-child">f</span></p><p id="start">g</p><p id="end">h</p><p id="center">i</p>
            """, css: css + """

            #hidden { visibility: hidden } #shown { visibility: VISIBLE } #collapse { visibility: collapse }
            #invalid { visibility: hidden; visibility: invisible }
            #left { float: left } #start { float: inline-start } #end { float: inline-end } #center { float: right; float: center }
            """)
        for (index, item) in displays.enumerated() {
            XCTAssertEqual(result.style("d\(index)").display, item.1, item.0)
            XCTAssertEqual(result.style("c\(index)").display, .inline, "display is not inherited")
        }
        XCTAssertTrue(result.style("hidden").isHidden)
        XCTAssertTrue(result.style("inherits").isHidden, "visibility inherits")
        XCTAssertFalse(result.style("shown").isHidden, "…and a descendant can show itself again")
        XCTAssertTrue(result.style("collapse").isHidden)
        XCTAssertTrue(result.style("invalid").isHidden)
        XCTAssertEqual(result.style("left").float, .left)
        XCTAssertEqual(result.style("float-child").float, ComputedStyle.Float.none)
        XCTAssertEqual(result.style("start").float, .left)
        XCTAssertEqual(result.style("end").float, .right)
        XCTAssertEqual(result.style("center").float, .right)
    }

    func testSizeKeywordsLogicalAliasesAndInvalidValues() throws {
        let styles = try paragraphs([
            "width: 10px; width: auto", "max-width: 40px; max-width: none", "max-width: 40px; max-width: auto", "min-width: 4px; min-width: auto",
            "height: 5px; height: fit-content", "width: 5px; width: min-content", "width: 5px; width: max-content",
            "inline-size: 10em; block-size: 50%; max-inline-size: 30em; min-block-size: 2px; min-inline-size: 1px; max-block-size: 9px",
            "width: 5px; width: 10px 20px", "height: 5px; height: none", "max-height: 5px; max-height: 1e3px",
        ])
        XCTAssertEqual(styles[0].width, .auto)
        XCTAssertEqual(styles[1].maxWidth, .auto, "none")
        XCTAssertEqual(styles[2].maxWidth, .points(40), "max-width has no auto")
        XCTAssertEqual(styles[3].minWidth, .auto)
        XCTAssertEqual(styles[4].height, .auto, "Intrinsic sizing keywords size as auto does")
        XCTAssertEqual(styles[5].width, .auto)
        XCTAssertEqual(styles[6].width, .auto)
        XCTAssertEqual(styles[7].width, .points(160))
        XCTAssertEqual(styles[7].height, .percent(50))
        XCTAssertEqual(styles[7].maxWidth, .points(480))
        XCTAssertEqual(styles[7].minHeight, .points(2))
        XCTAssertEqual(styles[7].minWidth, .points(1))
        XCTAssertEqual(styles[7].maxHeight, .points(9))
        XCTAssertEqual(styles[8].width, .points(5))
        XCTAssertEqual(styles[9].height, .points(5), "height has no none")
        XCTAssertEqual(styles[10].maxHeight, .points(1000))
        let nested = try CSSCascadeSupport.styled(#"<div style="width: 100px; height: 50px; max-width: 200px; min-height: 5px"><p id="p">x</p></div>"#)
        XCTAssertEqual([nested.style("p").width, nested.style("p").height, nested.style("p").maxWidth, nested.style("p").minHeight],
                       [.auto, .auto, .auto, .auto], "Sizes are not inherited")
    }

    func testTablePropertiesInheritIntoCellsAndResetAtANestedTable() throws {
        let result = try CSSCascadeSupport.styled("""
            <table id="t"><caption id="caption">c</caption><tbody><tr><td id="cell">x<table id="inner"><tr><td id="inner-cell">y</td></tr></table></td></tr></tbody></table>
            <table id="one"><tr><td>z</td></tr></table><table id="bad"><tr><td>w</td></tr></table>
            """, css: """
            #t { border-spacing: 1px 2px; border-collapse: collapse; caption-side: bottom }
            #one { border-spacing: 0.5em; border-collapse: collapse; border-collapse: separate }
            #bad { border-spacing: 3px; border-spacing: 5%; border-spacing: 1px 2px 3px; border-spacing: -1px; border-collapse: merge; caption-side: left }
            """)
        XCTAssertEqual(result.style("cell").borderSpacing, CGSize(width: 1, height: 2))
        XCTAssertTrue(result.style("cell").borderCollapse)
        XCTAssertEqual(result.style("caption").captionSide, .bottom)
        XCTAssertEqual(result.style("inner").borderSpacing, CGSize(width: 2, height: 2), "HTML's table { border-spacing: 2px; border-collapse: separate }")
        XCTAssertFalse(result.style("inner").borderCollapse)
        XCTAssertFalse(result.style("inner-cell").borderCollapse)
        XCTAssertEqual(result.style("one").borderSpacing, CGSize(width: 8, height: 8))
        XCTAssertFalse(result.style("one").borderCollapse)
        XCTAssertEqual(result.style("bad").borderSpacing, CGSize(width: 3, height: 3))
        XCTAssertFalse(result.style("bad").borderCollapse)
        XCTAssertEqual(result.style("bad").captionSide, .top)
    }

    /// CSS 2.2 §17.6.1: 'border-spacing' has the initial value 0. Only HTML's `table` gets 2px,
    /// from the user-agent sheet, so a table built from `div`s with `display: table` has none.
    func testBorderSpacingIsInitiallyZeroOutsideHTMLTables() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/125")
        let result = try CSSCascadeSupport.styled("""
            <div id="grid" style="display: table"><div style="display: table-row"><div id="cell" style="display: table-cell">x</div></div></div>
            <table id="table"><tr><td>y</td></tr></table><table id="reset" style="border-spacing: initial"><tr><td>z</td></tr></table>
            """)
        XCTAssertEqual(result.style("table").borderSpacing, CGSize(width: 2, height: 2))
        XCTAssertEqual(result.style("grid").borderSpacing, .zero, "display: table on a div")
        XCTAssertEqual(result.style("cell").borderSpacing, .zero)
        XCTAssertEqual(result.style("reset").borderSpacing, .zero, "border-spacing: initial")
    }
}
