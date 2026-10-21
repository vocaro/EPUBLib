import EPUBTestSupport
import XCTest
@testable import EPUBViewing

/// The flex, grid and box-alignment properties: parsing, shorthands, legacy names and the cascade.
final class BoxAlignmentStyleTests: XCTestCase {
    private func values(_ name: String, _ value: String) -> [CSSProperty: CSSValue]? {
        CSSPropertyParser.parse(name: name, text: value).map { Dictionary($0.map { ($0.property, $0.value) }, uniquingKeysWith: { $1 }) }
    }

    func testAlignmentLonghands() {
        XCTAssertEqual(values("flex-direction", "column")?[.flexDirection], .flexDirection(.column))
        XCTAssertEqual(values("flex-direction", "row-reverse")?[.flexDirection], .flexDirection(.rowReverse))
        XCTAssertNil(values("flex-direction", "diagonal"))
        XCTAssertEqual(values("flex-wrap", "wrap-reverse")?[.flexWrap], .flag(true))
        XCTAssertEqual(values("flex-wrap", "nowrap")?[.flexWrap], .flag(false))
        XCTAssertEqual(values("justify-content", "center")?[.justifyContent], .contentAlignment(.center))
        XCTAssertEqual(values("justify-content", "safe flex-end")?[.justifyContent], .contentAlignment(.flexEnd))
        XCTAssertEqual(values("justify-content", "space-evenly")?[.justifyContent], .contentAlignment(.spaceEvenly))
        XCTAssertNil(values("justify-content", "middle"))
        XCTAssertNil(values("justify-content", "center center"))
        XCTAssertEqual(values("align-content", "space-between")?[.alignContent], .contentAlignment(.spaceBetween))
        XCTAssertEqual(values("align-items", "flex-start")?[.alignItems], .itemAlignment(.start))
        XCTAssertEqual(values("align-items", "first baseline")?[.alignItems], .itemAlignment(.baseline))
        XCTAssertNil(values("align-items", "auto"), "auto is only a self-alignment")
        XCTAssertEqual(values("align-self", "auto")?[.alignSelf], .itemAlignment(.auto))
        XCTAssertEqual(values("align-self", "unsafe end")?[.alignSelf], .itemAlignment(.end))
        XCTAssertEqual(values("justify-items", "legacy center")?[.justifyItems], .itemAlignment(.normal))
        XCTAssertEqual(values("justify-self", "right")?[.justifySelf], .itemAlignment(.right))
        XCTAssertEqual(values("order", "-2")?[.order], .integer(-2))
        XCTAssertNil(values("order", "1.5"))
        XCTAssertEqual(values("flex-grow", "2.5")?[.flexGrow], .number(2.5))
        XCTAssertNil(values("flex-grow", "-1"))
        XCTAssertEqual(values("row-gap", "1em")?[.rowGap], .length(.value(1, .em)))
        XCTAssertEqual(values("row-gap", "normal")?[.rowGap], .length(.zero))
        XCTAssertNil(values("row-gap", "-1px"))
        XCTAssertEqual(values("box-sizing", "border-box")?[.boxSizing], .flag(true))
        XCTAssertEqual(values("box-sizing", "content-box")?[.boxSizing], .flag(false))
        XCTAssertNil(values("box-sizing", "padding-box"))
    }

    func testAlignmentShorthands() {
        XCTAssertEqual(values("flex-flow", "column wrap"), [.flexDirection: .flexDirection(.column), .flexWrap: .flag(true)])
        XCTAssertEqual(values("flex-flow", "wrap"), [.flexDirection: .flexDirection(.row), .flexWrap: .flag(true)])
        XCTAssertNil(values("flex-flow", "column row"))
        XCTAssertEqual(values("flex", "1")?[.flexGrow], .number(1))
        XCTAssertEqual(values("flex", "none")?[.flexGrow], .number(0))
        XCTAssertEqual(values("flex", "auto")?[.flexGrow], .number(1))
        XCTAssertEqual(values("flex", "2 1 0")?[.flexGrow], .number(2))
        XCTAssertEqual(values("flex", "0 0 auto")?[.flexGrow], .number(0))
        XCTAssertEqual(values("flex", "30%")?[.flexGrow], .number(1), "a lone basis grows by one")
        XCTAssertEqual(values("flex", "initial")?[.flexGrow], .initial)
        XCTAssertNil(values("flex", "1 2 3 4"))
        XCTAssertEqual(values("place-items", "center"), [.alignItems: .itemAlignment(.center), .justifyItems: .itemAlignment(.center)])
        XCTAssertEqual(values("place-items", "start end"), [.alignItems: .itemAlignment(.start), .justifyItems: .itemAlignment(.end)])
        XCTAssertEqual(values("place-content", "center space-between"),
                       [.alignContent: .contentAlignment(.center), .justifyContent: .contentAlignment(.spaceBetween)])
        XCTAssertEqual(values("place-self", "auto center"), [.alignSelf: .itemAlignment(.auto), .justifySelf: .itemAlignment(.center)])
        XCTAssertNil(values("place-items", "auto"))
        XCTAssertEqual(values("gap", "2em 10px"), [.rowGap: .length(.value(2, .em))], "the column gap is not laid out")
        XCTAssertEqual(values("grid-gap", "8px"), [.rowGap: .length(.value(8, .px))])
        XCTAssertNil(values("gap", "1px 2px 3px"))
    }

    /// CSS Box Alignment 3, 5.1, 6.1 and 6.2: `left` and `right` are values of the `justify-`
    /// properties alone, `justify-content` has no baseline, `safe` and `unsafe` go only before a
    /// position, and a baseline takes `first` or `last` in either order. The `place-` shorthands
    /// give their first value to the `align-` property. An invalid value is dropped.
    func testEachAlignmentPropertyTakesOnlyItsOwnKeywords() {
        for value in ["left", "right", "safe left", "unsafe right"] {
            XCTAssertNil(values("align-items", value), value)
            XCTAssertNil(values("align-self", value), value)
            XCTAssertNil(values("align-content", value), value)
            XCTAssertNil(values("-webkit-box-align", value), value)
        }
        XCTAssertEqual(values("justify-content", "safe right")?[.justifyContent], .contentAlignment(.right))
        XCTAssertEqual(values("justify-self", "unsafe left")?[.justifySelf], .itemAlignment(.left))
        XCTAssertEqual(values("justify-items", "right")?[.justifyItems], .itemAlignment(.right))
        XCTAssertNil(values("justify-content", "baseline"))
        XCTAssertNil(values("justify-content", "first baseline"))
        XCTAssertEqual(values("align-content", "last baseline")?[.alignContent], .contentAlignment(.start))
        XCTAssertEqual(values("align-items", "baseline last")?[.alignItems], .itemAlignment(.baseline), "either order")
        XCTAssertEqual(values("-webkit-box-pack", "justify")?[.justifyContent], .contentAlignment(.spaceBetween))
        for value in ["safe stretch", "unsafe normal", "safe baseline", "safe space-between", "safe safe center", "center safe", "safe",
                      "first last", "first first baseline"] {
            XCTAssertNil(values("justify-content", value), value)
            XCTAssertNil(values("align-items", value), value)
        }
        XCTAssertNil(values("align-self", "safe auto"))
        XCTAssertNil(values("flex-direction", "safe column"))
        XCTAssertNil(values("justify-items", "legacy stretch"))
        XCTAssertNil(values("justify-items", "legacy legacy"))
        XCTAssertEqual(values("justify-items", "right legacy")?[.justifyItems], .itemAlignment(.normal))
        // The shorthands.
        XCTAssertNil(values("place-items", "right"))
        XCTAssertNil(values("place-items", "legacy"))
        XCTAssertNil(values("place-self", "left center"))
        XCTAssertNil(values("place-content", "left"))
        XCTAssertEqual(values("place-items", "center right"), [.alignItems: .itemAlignment(.center), .justifyItems: .itemAlignment(.right)])
        XCTAssertEqual(values("place-content", "baseline"), [.alignContent: .contentAlignment(.start), .justifyContent: .contentAlignment(.start)],
                       "justify-content has no baseline: it is start")
        XCTAssertEqual(values("place-content", "safe center space-between"),
                       [.alignContent: .contentAlignment(.center), .justifyContent: .contentAlignment(.spaceBetween)])
        XCTAssertEqual(values("place-items", "first baseline"), [.alignItems: .itemAlignment(.baseline), .justifyItems: .itemAlignment(.baseline)])
        XCTAssertEqual(values("place-self", "unsafe end safe start"), [.alignSelf: .itemAlignment(.end), .justifySelf: .itemAlignment(.start)])
        XCTAssertNil(values("place-self", "center center center"))
    }

    func testGridTemplatesAreCountedInColumns() {
        XCTAssertEqual(values("grid-template-columns", "none")?[.gridColumns], .integer(0))
        XCTAssertEqual(values("grid-template-columns", "1fr")?[.gridColumns], .integer(1))
        XCTAssertEqual(values("grid-template-columns", "100px 1fr auto")?[.gridColumns], .integer(3))
        XCTAssertEqual(values("grid-template-columns", "[full-start] minmax(1em, 1fr) [main] fit-content(40ch)")?[.gridColumns], .integer(2))
        XCTAssertEqual(values("grid-template-columns", "repeat(3, 1fr)")?[.gridColumns], .integer(3))
        XCTAssertEqual(values("grid-template-columns", "repeat(2, 1fr 2fr) 10px")?[.gridColumns], .integer(5))
        XCTAssertEqual(values("grid-template-columns", "repeat(auto-fill, minmax(8em, 1fr))")?[.gridColumns], .integer(2))
        XCTAssertNil(values("grid-template-columns", "1fr, 1fr"))
        XCTAssertEqual(values("grid-template-areas", "\"head head\" \"side main\"")?[.gridAreas], .integer(2))
        XCTAssertEqual(values("grid-template-areas", "\"only\"")?[.gridAreas], .integer(1))
        XCTAssertEqual(values("grid-template-areas", "none")?[.gridAreas], .integer(0))
        XCTAssertEqual(values("grid-auto-flow", "column dense")?[.gridAutoFlow], .flag(true))
        XCTAssertEqual(values("grid-auto-flow", "row")?[.gridAutoFlow], .flag(false))
        XCTAssertEqual(values("grid-template", "auto 1fr / 1fr 3fr")?[.gridColumns], .integer(2))
        XCTAssertEqual(values("grid-template", "\"a b c\" 2em \"d e f\" auto")?[.gridAreas], .integer(3))
        XCTAssertEqual(values("grid", "auto-flow / 1fr 1fr 1fr")?[.gridColumns], .integer(3))
        XCTAssertEqual(values("grid", "none"), [.gridColumns: .integer(0), .gridAreas: .integer(0), .gridAutoFlow: .flag(false)])
        XCTAssertEqual(values("grid-column", "2 / span 2")?[.gridPlacement], .flag(true))
        XCTAssertEqual(values("grid-area", "main")?[.gridPlacement], .flag(true))
        XCTAssertEqual(values("grid-row", "auto")?[.gridPlacement], .flag(false))
    }

    /// Books made for older reading systems spell flexbox with vendor prefixes and the 2009 and
    /// 2012 drafts' names.
    func testLegacyFlexboxNamesMapToTheSameProperties() {
        XCTAssertEqual(values("display", "-webkit-box")?[.display], .display(.block, blockifies: true))
        XCTAssertEqual(values("display", "grid")?[.display], .display(.block, blockifies: true, grid: true))
        XCTAssertEqual(values("-webkit-box-orient", "vertical")?[.flexDirection], .flexDirection(.column))
        XCTAssertEqual(values("-webkit-box-pack", "justify")?[.justifyContent], .contentAlignment(.spaceBetween))
        XCTAssertEqual(values("-webkit-box-pack", "center")?[.justifyContent], .contentAlignment(.center))
        XCTAssertEqual(values("-webkit-box-align", "center")?[.alignItems], .itemAlignment(.center))
        XCTAssertEqual(values("-ms-flex-pack", "distribute")?[.justifyContent], .contentAlignment(.spaceAround))
        XCTAssertEqual(values("-webkit-justify-content", "flex-end")?[.justifyContent], .contentAlignment(.flexEnd))
        XCTAssertEqual(values("-webkit-align-items", "center")?[.alignItems], .itemAlignment(.center))
        XCTAssertEqual(values("-webkit-flex-direction", "column")?[.flexDirection], .flexDirection(.column))
        XCTAssertEqual(values("-webkit-box-flex", "1")?[.flexGrow], .number(1))
        XCTAssertEqual(values("-webkit-flex", "1 0 auto")?[.flexGrow], .number(1))
        XCTAssertEqual(values("-webkit-box-sizing", "border-box")?[.boxSizing], .flag(true))
    }

    func testCascadeComputesContainerAndItemValues() throws {
        let result = try StyleTestSupport.styled("""
            <section id="flex"><p id="item">a</p><p id="plain">b</p></section>
            <div id="grid"><p id="cell">c</p></div><div id="block"><p id="child">d</p></div>
            """, css: """
            #flex { display: flex; flex-flow: column wrap; justify-content: center; align-items: center;
                    gap: 1em; box-sizing: border-box; min-height: calc(98vh - 3em); height: 50%; max-height: calc(50vmin + 2em) }
            #item { align-self: flex-end; order: 2; flex: 1; justify-content: inherit }
            #grid { display: grid; grid-template-columns: 1fr 1fr; place-items: center; height: calc(10px + 2em) }
            #cell { grid-column: 2 }
            @supports (display: flex) and (justify-content: center) { #block { align-items: center } }
            @supports not (display: grid) { #block { align-items: flex-end } }
            """)
        let flex = result.style("flex").boxAlignment
        XCTAssertTrue(result.style("flex").blockifiesChildren)
        XCTAssertFalse(flex.isGrid)
        XCTAssertEqual(flex.direction, .column)
        XCTAssertTrue(flex.wraps)
        XCTAssertEqual(flex.justifyContent, .center)
        XCTAssertEqual(flex.alignItems, .center)
        XCTAssertEqual(flex.rowGap, .points(16))
        XCTAssertTrue(flex.isBorderBox)
        // The style's own length folds the 3em into the unit against the nominal 800-point page;
        // the box keeps the exact sum.
        XCTAssertEqual(result.style("flex").minHeight, .viewportHeight(92))
        XCTAssertEqual(flex.minHeight, ComputedStyle.MixedLength(points: -48, percent: 0, viewportWidth: 0, viewportHeight: 98,
                                                                 viewportMin: 0, viewportMax: 0))
        XCTAssertEqual(flex.maxHeight, ComputedStyle.MixedLength(points: 32, percent: 0, viewportWidth: 0, viewportHeight: 0,
                                                                 viewportMin: 50, viewportMax: 0), "vmin is kept as itself, not as vw")
        XCTAssertEqual(flex.maxHeight?.resolve(viewport: CGSize(width: 700, height: 400)), 232, "half the smaller side and 2em")
        XCTAssertEqual(result.style("flex").height, .percent(50))
        XCTAssertNil(flex.height, "one unit alone is exact already")
        let item = result.style("item").boxAlignment
        XCTAssertEqual(item.alignSelf, .end)
        XCTAssertEqual(item.order, 2)
        XCTAssertEqual(item.grow, 1)
        XCTAssertEqual(item.justifyContent, .center, "inherit copies the parent's computed value")
        XCTAssertEqual(item.alignItems, .normal, "alignment is not inherited")
        XCTAssertEqual(result.style("plain").boxAlignment, ComputedStyle.BoxAlignment(), "initial values")
        let grid = result.style("grid").boxAlignment
        XCTAssertTrue(grid.isGrid)
        XCTAssertEqual(grid.gridColumns, 2)
        XCTAssertEqual(grid.alignItems, .center)
        XCTAssertEqual(grid.justifyItems, .center)
        XCTAssertEqual(result.style("grid").height, .points(42))
        XCTAssertNil(grid.height)
        XCTAssertTrue(result.style("cell").boxAlignment.hasGridPlacement)
        XCTAssertEqual(result.style("block").boxAlignment.alignItems, .center, "@supports sees the new properties")
        XCTAssertFalse(result.style("child").boxAlignment.isGrid)
    }
}
