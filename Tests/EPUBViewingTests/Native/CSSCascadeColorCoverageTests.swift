@testable import EPUBViewing
import XCTest

/// CSS Color: named, hex and functional notations, `currentcolor`, system colors, the
/// `background` shorthand's color and the reader's dark-appearance policy.
final class CSSCascadeColorCoverageTests: XCTestCase {
    private let hex = CSSCascadeSupport.hex
    private let rgba = CSSCascadeSupport.color

    /// The computed `color` of one paragraph per value, each over an inherited blue.
    private func colors(_ values: [String]) throws -> [ComputedStyle.Color?] {
        let body = "<div>" + values.indices.map { "<p id=\"e\($0)\">x</p>" }.joined() + "</div>"
        let css = "div { color: blue }\n" + values.enumerated().map { "#e\($0.offset) { color: \($0.element) }" }.joined(separator: "\n")
        let result = try CSSCascadeSupport.styled(body, css: css)
        return values.indices.map { result.style("e\($0)").color }
    }

    private func assertColors(_ cases: [(String, ComputedStyle.Color)], file: StaticString = #filePath, line: UInt = #line) throws {
        for (item, actual) in zip(cases, try colors(cases.map(\.0))) {
            CSSCascadeSupport.assertColor(actual, item.1, item.0, file: file, line: line)
        }
    }

    func testNamedColorsCoverCSSColor4AndIgnoreCase() throws {
        XCTAssertEqual(CSSPropertyParser.namedColors.count, 148, "CSS Color 4 §6.1 names 148 colors")
        try assertColors([
            ("aliceblue", hex(0xF0F8FF, 1)), ("BlanchedAlmond", hex(0xFFEBCD, 1)), ("burlywood", hex(0xDEB887, 1)),
            ("CORNFLOWERBLUE", hex(0x6495ED, 1)), ("darkgoldenrod", hex(0xB8860B, 1)), ("darkslategrey", hex(0x2F4F4F, 1)),
            ("darkslategray", hex(0x2F4F4F, 1)), ("lightgoldenrodyellow", hex(0xFAFAD2, 1)), ("mediumspringgreen", hex(0x00FA9A, 1)),
            ("papayawhip", hex(0xFFEFD5, 1)), ("peru", hex(0xCD853F, 1)), ("ReBeCcApUrPlE", hex(0x663399, 1)),
            ("lightslategrey", hex(0x778899, 1)), ("olivedrab", hex(0x6B8E23, 1)), ("thistle", hex(0xD8BFD8, 1)),
            ("grey", hex(0x808080, 1)), ("gray", hex(0x808080, 1)), ("aqua", hex(0x00FFFF, 1)), ("cyan", hex(0x00FFFF, 1)),
            ("fuchsia", hex(0xFF00FF, 1)), ("magenta", hex(0xFF00FF, 1)), ("green", hex(0x008000, 1)), ("lime", hex(0x00FF00, 1)),
            ("maroon", hex(0x800000, 1)), ("navy", hex(0x000080, 1)), ("teal", hex(0x008080, 1)), ("silver", hex(0xC0C0C0, 1)),
            ("orange", hex(0xFFA500, 1)), ("indigo", hex(0x4B0082, 1)), ("whitesmoke", hex(0xF5F5F5, 1)),
        ])
    }

    func testHexColorsOfThreeFourSixAndEightDigits() throws {
        try assertColors([
            ("#abc", hex(0xAABBCC, 1)), ("#ABCD", hex(0xAABBCC, 0xDD / 255)), ("#a1b2c3", hex(0xA1B2C3, 1)),
            ("#A1B2C380", hex(0xA1B2C3, 0x80 / 255)), ("#000", hex(0, 1)), ("#FfFfFf", hex(0xFFFFFF, 1)), ("#0000", hex(0, 0)),
        ])
    }

    func testRGBInLegacyAndModernSyntax() throws {
        try assertColors([
            ("rgb(255, 0, 0)", rgba(1, 0, 0, 1)), ("rgb(255,0,0)", rgba(1, 0, 0, 1)), ("RGB(0 128 0)", rgba(0, 128 / 255, 0, 1)),
            ("rgb(0 0 255 / 50%)", rgba(0, 0, 1, 0.5)), ("rgba(0, 0, 255, 0.25)", rgba(0, 0, 1, 0.25)),
            ("rgb(100%, 50%, 0%)", rgba(1, 0.5, 0, 1)), ("rgb(300, -20, 127.5)", rgba(1, 0, 0.5, 1)),
            ("rgb(0 0 0 / 2)", rgba(0, 0, 0, 1)), ("rgb(10 20 30 / -1)", rgba(10 / 255, 20 / 255, 30 / 255, 0)),
            ("rgba(255 255 0 / .5)", rgba(1, 1, 0, 0.5)), ("rgb(  12 ,34 , 56  )", rgba(12 / 255, 34 / 255, 56 / 255, 1)),
            ("rgb(0 0 0 / 100%)", rgba(0, 0, 0, 1)), ("rgb(120% 0% -5%)", rgba(1, 0, 0, 1)),
        ])
    }

    func testHSLWithHueUnitsWrappingAndClamping() throws {
        try assertColors([
            ("hsl(0, 100%, 50%)", rgba(1, 0, 0, 1)), ("hsl(120deg 100% 25%)", rgba(0, 0.5, 0, 1)), ("hsl(0.5turn 100% 50%)", rgba(0, 1, 1, 1)),
            ("hsl(3.14159265rad 100% 50%)", rgba(0, 1, 1, 1)), ("hsl(200grad 100% 50%)", rgba(0, 1, 1, 1)),
            ("hsl(-120 100% 50%)", rgba(0, 0, 1, 1)), ("hsl(480 100% 50%)", rgba(0, 1, 0, 1)), ("hsl(0 0% 50%)", rgba(0.5, 0.5, 0.5, 1)),
            ("hsla(240, 100%, 50%, 0.3)", rgba(0, 0, 1, 0.3)), ("hsl(120 200% 50%)", rgba(0, 1, 0, 1)),
            ("hsl(0 100% 150%)", rgba(1, 1, 1, 1)), ("hsl(30 100% 50%)", rgba(1, 0.5, 0, 1)), ("HSL(210 50% 40% / 25%)", rgba(0.2, 0.4, 0.6, 0.25)),
            ("hsl(720.5turn 100% 50%)", rgba(0, 1, 1, 1)),
        ])
    }

    func testHWB() throws {
        try assertColors([
            ("hwb(0 0% 0%)", rgba(1, 0, 0, 1)), ("hwb(120 20% 30%)", rgba(0.2, 0.7, 0.2, 1)), ("hwb(0 60% 60%)", rgba(0.5, 0.5, 0.5, 1)),
            ("hwb(240 0% 0% / 0.5)", rgba(0, 0, 1, 0.5)), ("hwb(77 100% 0%)", rgba(1, 1, 1, 1)), ("hwb(77 0% 100%)", rgba(0, 0, 0, 1)),
            ("hwb(0.25turn 0% 50%)", rgba(0.25, 0.5, 0, 1)),
        ])
    }

    func testInvalidColorsLeaveTheInheritedColor() throws {
        let invalid = ["#ab", "#abcde", "#abcdefa", "#abcdefabc", "#ggg", "abc", "#12 34", "rgb(255, 0)", "rgb()", "rgb(255 0 0 /)",
                       "rgb(255, 0 0)", "rgb(1,2,3,4,5)", "rgb(red, 0, 0)", "rgb(255 0 0 0.5)", "rgb(10px, 0, 0)", "hsl(120em 100% 50%)",
                       "hsl(120 100%)", "hsl(red 100% 50%)", "hwb(0 0%)", "notacolor", "red blue", "12", "\"red\"", "url(red)"]
        for (value, color) in zip(invalid, try colors(invalid)) { XCTAssertEqual(color, rgba(0, 0, 1, 1), value) }
    }

    func testAnInvalidColorNeverReplacesAnEarlierValidOne() throws {
        let result = try CSSCascadeSupport.styled(#"<p id="a">a</p><p id="b">b</p><p id="c">c</p><p id="d">d</p>"#, css: """
            #a { color: red; color: #ggg; background-color: lime; background-color: 5px }
            #b { border: 1px solid red; border-color: bogus; border-top-color: rgb(1, 2) }
            #c { text-decoration: underline red; text-decoration-color: nope }
            #d { color: red; color: rgb(
            """)
        XCTAssertEqual(result.style("a").color, rgba(1, 0, 0, 1))
        XCTAssertEqual(result.style("a").backgroundColor, rgba(0, 1, 0, 1))
        XCTAssertEqual(result.style("b").border.top.color, rgba(1, 0, 0, 1))
        XCTAssertEqual(result.style("b").border.left.color, rgba(1, 0, 0, 1))
        XCTAssertEqual(result.style("c").textDecorationColor, rgba(1, 0, 0, 1))
        XCTAssertEqual(result.style("d").color, rgba(1, 0, 0, 1), "A function cut off by the end of the sheet is invalid")
    }

    func testCurrentColorIsTheElementsOwnColorWhateverTheDeclarationOrder() throws {
        let result = try CSSCascadeSupport.styled("""
            <div><p id="p">x <span id="s">s</span> <span id="t">t</span></p><p id="q">y</p><p id="r">z</p></div>
            """, css: """
            div { color: red }
            #p { color: blue; border: 1px solid }
            #s { color: currentColor; background-color: currentColor }
            #t { border: 1px solid; border-color: inherit; color: lime }
            #q { background-color: currentcolor; border: 2px solid CURRENTCOLOR; color: green }
            #r { color: CurrentColor }
            """)
        XCTAssertNil(result.style("p").border.top.color, "A border without a color is the text color")
        XCTAssertEqual(result.style("s").color, rgba(0, 0, 1, 1), "color: currentcolor inherits")
        XCTAssertEqual(result.style("s").backgroundColor, rgba(0, 0, 1, 1))
        XCTAssertNil(result.style("t").border.top.color, "An inherited currentcolor border follows the child's own color")
        XCTAssertEqual(result.style("q").backgroundColor, hex(0x008000, 1), "currentcolor uses the color declared later in the same rule")
        XCTAssertNil(result.style("q").border.top.color)
        XCTAssertEqual(result.style("r").color, rgba(1, 0, 0, 1))
    }

    func testTransparentAndSystemColorsMeanTheReadersPalette() throws {
        let result = try CSSCascadeSupport.styled(#"<div><p id="sys">x</p><p id="clear">y</p><p id="alpha">z</p></div>"#, css: """
            div { color: red; background-color: yellow }
            #sys { color: CanvasText; background-color: Canvas }
            #clear { color: TRANSPARENT; background-color: transparent }
            #alpha { background-color: rgba(10, 20, 30, 0) }
            """)
        XCTAssertNil(result.style("sys").color, "CanvasText is the reader's text color, not the inherited one")
        XCTAssertNil(result.style("sys").backgroundColor)
        XCTAssertEqual(result.style("clear").color, rgba(0, 0, 0, 0))
        XCTAssertNil(result.style("clear").backgroundColor)
        XCTAssertNil(result.style("alpha").backgroundColor, "A fully transparent background is no background")
    }

    func testBackgroundShorthandTakesTheFinalLayersColorAndResetsWithoutOne() throws {
        let result = try CSSCascadeSupport.styled("""
            <p id="a">a</p><p id="b">b</p><p id="c">c</p><p id="d">d</p><p id="e">e</p><p id="f">f</p><p id="g">g</p><p id="h">h</p>
            """, css: """
            #a { background: url(a.png), url(b.png) #abc }
            #b { background-color: red; background: none }
            #c { background-color: red; background: red blue }
            #d { background: url(x.png) no-repeat center / cover rgba(0, 0, 255, 0.5) }
            #e { background-color: red; background: url(x.png) }
            #f { background: RED }
            #g { background: red; background-color: transparent }
            #h { background: red; background: inherit }
            """)
        XCTAssertEqual(result.style("a").backgroundColor, hex(0xAABBCC, 1))
        XCTAssertNil(result.style("b").backgroundColor)
        XCTAssertEqual(result.style("c").backgroundColor, rgba(1, 0, 0, 1), "Two colors are invalid")
        XCTAssertEqual(result.style("d").backgroundColor, rgba(0, 0, 1, 0.5))
        XCTAssertNil(result.style("e").backgroundColor, "A shorthand without a color resets it to transparent")
        XCTAssertEqual(result.style("f").backgroundColor, rgba(1, 0, 0, 1))
        XCTAssertNil(result.style("g").backgroundColor)
        XCTAssertNil(result.style("h").backgroundColor, "The parent has no background to inherit")
    }

    /// CSS 2.2 §4.2: "User agents must ignore a declaration with an illegal value." A stylesheet
    /// gives a solid color first and a gradient the engine may not know second; an engine that
    /// cannot parse the second keeps the first.
    func testAnUnparsableBackgroundLeavesTheFallbackColor() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/120")
        let result = try CSSCascadeSupport.styled(#"<p id="prefixed">a</p><p id="unknown">b</p>"#, css: """
            #prefixed { background: #336699; background: -moz-linear-gradient(top, #fff, #000) }
            #unknown { background: #336699; background: no-such-keyword }
            """)
        XCTAssertEqual(result.style("prefixed").backgroundColor, hex(0x336699, 1), "-moz-linear-gradient() is not a background value here")
        XCTAssertEqual(result.style("unknown").backgroundColor, hex(0x336699, 1), "no-such-keyword is not a background value")
    }

    func testDarkAppearanceChangesColorsAndNothingElse() throws {
        let body = """
            <p id="p" style="color: red; background: yellow; border: 2px dashed blue; text-decoration: underline green; margin-left: 3px">x</p>
            <hr id="hr"/><p id="t" style="color: transparent">t</p><p id="scheme">s</p>
            """
        let css = "@media (prefers-color-scheme: dark) { #scheme { margin-left: 5px; color: white; font-weight: 700 } }"
        let light = try CSSCascadeSupport.styled(body, css: css)
        let dark = try CSSCascadeSupport.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: true))
        XCTAssertEqual(light.style("hr").color, hex(0x808080, 1))
        for id in ["p", "hr", "scheme"] {
            XCTAssertNil(dark.style(id).color, id)
            XCTAssertNil(dark.style(id).backgroundColor, id)
            XCTAssertNil(dark.style(id).textDecorationColor, id)
            XCTAssertNil(dark.style(id).border.top.color, id)
        }
        XCTAssertEqual(dark.style("t").color, rgba(0, 0, 0, 0))
        var expected = light.style("p")
        expected.color = nil; expected.backgroundColor = nil; expected.textDecorationColor = nil
        expected.border = .init(.init(width: 2, style: .dashed, color: nil))
        XCTAssertEqual(dark.style("p"), expected, "Only colors differ between appearances")
        // What does not paint is resolved as in light appearance, so that a section's characters are the
        // same in either (#130): a dark media rule's other declarations apply in neither.
        XCTAssertEqual([light, dark].map { $0.style("scheme").margin.left }, [.points(0), .points(0)])
        XCTAssertEqual([light, dark].map { $0.style("scheme").fontWeight }, [400, 400])
    }
}
