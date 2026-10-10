import EPUBReading
import XCTest
@testable import EPUBViewing

final class PositioningStyleTests: XCTestCase {
    func testPositionKeywordsRetainTheirDistinctLayoutModes() throws {
        let cases: [(String, ComputedStyle.Position)] = [
            ("static", .static), ("relative", .relative), ("absolute", .absolute),
            ("fixed", .fixed), ("sticky", .sticky), ("-webkit-sticky", .sticky),
        ]
        for (keyword, expected) in cases {
            let result = try StyleTestSupport.styled("<span id='box'>Text</span>", css: "#box { position: \(keyword); }")
            let style = result.style("box")
            XCTAssertEqual(style.position, expected, keyword)
            XCTAssertEqual(style.isOutOfFlow, expected == .absolute || expected == .fixed, keyword)
        }
        let invalid = try StyleTestSupport.styled("<p id='box'>Text</p>", css: "#box { position:relative; position:somewhere; }")
        XCTAssertEqual(invalid.style("box").position, .relative)
    }

    func testClearKeywordsAndInvalidDeclarations() throws {
        let cases: [(String, ComputedStyle.Clear)] = [("none", .none), ("left", .left), ("right", .right), ("both", .both)]
        for (keyword, expected) in cases {
            let result = try StyleTestSupport.styled("<p id='box'>Text</p>", css: "#box { clear: \(keyword); }")
            XCTAssertEqual(result.style("box").clear, expected, keyword)
        }
        let result = try StyleTestSupport.styled("<p id='box'>Text</p>", css: "#box { clear:both; clear:center; }")
        XCTAssertEqual(result.style("box").clear, .both)
    }

    func testPositionClearAndInsetsSupportInheritanceAndInitialValues() throws {
        let result = try StyleTestSupport.styled("""
            <div id='parent'><span id='ordinary'>Text</span><span id='inherit'>Inherited</span>
            <span id='initial'>Initial</span><span id='unset'>Unset</span><span id='revert'>Revert</span></div>
            """, css: """
            #parent { position:fixed; clear:both; inset:1px 2px 3px 4px; }
            #inherit { position:inherit; clear:inherit; inset:inherit; }
            #initial { position:relative; clear:left; inset:9px; position:initial; clear:initial; inset:initial; }
            #unset { position:sticky; clear:right; inset:8px; position:unset; clear:unset; inset:unset; }
            #revert { position:absolute; clear:both; inset:7px; position:revert; clear:revert; inset:revert; }
            """)
        let inherited = result.style("inherit")
        XCTAssertEqual(inherited.position, .fixed)
        XCTAssertEqual(inherited.clear, .both)
        XCTAssertEqual(inherited.positionTop, .points(1))
        XCTAssertEqual(inherited.positionRight, .points(2))
        XCTAssertEqual(inherited.positionBottom, .points(3))
        XCTAssertEqual(inherited.positionLeft, .points(4))
        for id in ["ordinary", "initial", "unset", "revert"] {
            let style = result.style(id)
            XCTAssertEqual(style.position, .static, id)
            XCTAssertEqual(style.clear, .none, id)
            XCTAssertEqual(style.positionTop, .auto, id)
            XCTAssertEqual(style.positionRight, .auto, id)
            XCTAssertEqual(style.positionBottom, .auto, id)
            XCTAssertEqual(style.positionLeft, .auto, id)
        }
    }

    func testInsetsResolveRelativeAndSymbolicLengthsWithoutLosingSides() throws {
        let result = try StyleTestSupport.styled("<p id='box'>Text</p><p id='pair'>Pair</p><p id='three'>Three</p>", css: """
            #box { position:relative; font-size:20px; top:2em; right:10%; bottom:calc(3em - 10px); left:auto; }
            #pair { inset:5px auto; }
            #three { inset:-4px 8px 12px; }
            """)
        let box = result.style("box")
        XCTAssertEqual(box.positionTop, .points(40))
        XCTAssertEqual(box.positionRight, .percent(10))
        XCTAssertEqual(box.positionBottom, .points(50))
        XCTAssertEqual(box.positionLeft, .auto)
        let pair = result.style("pair")
        XCTAssertEqual(pair.positionTop, .points(5))
        XCTAssertEqual(pair.positionRight, .auto)
        XCTAssertEqual(pair.positionBottom, .points(5))
        XCTAssertEqual(pair.positionLeft, .auto)
        let three = result.style("three")
        XCTAssertEqual(three.positionTop, .points(-4))
        XCTAssertEqual(three.positionRight, .points(8))
        XCTAssertEqual(three.positionBottom, .points(12))
        XCTAssertEqual(three.positionLeft, .points(8))
    }

    func testOutOfFlowCompatibilitySetterKeepsSpecificPositionModes() {
        var style = ComputedStyle()
        style.position = .fixed
        style.isOutOfFlow = true
        XCTAssertEqual(style.position, .fixed)
        style.isOutOfFlow = false
        XCTAssertEqual(style.position, .static)
        style.position = .relative
        style.isOutOfFlow = false
        XCTAssertEqual(style.position, .relative)
        style.isOutOfFlow = true
        XCTAssertEqual(style.position, .absolute)
        style.position = .sticky
        XCTAssertFalse(style.isOutOfFlow)
    }

    func testTrailingInsetsCannotHideVisibleLeadingEdgeContent() throws {
        for fontSize: CGFloat in [12, 17, 32, 96] {
            let result = try StyleTestSupport.styled("""
                <div id='parent'><span id='inherited'>Text</span></div><span id='trailing'>Trailing</span><span id='relative'>Relative</span>
                """, css: """
                #parent { top:calc(-1200px + 100px); left:-64em; }
                #inherited { position:absolute; top:inherit; left:inherit; }
                #trailing { position:absolute; left:0; top:0; right:-9999px; bottom:-9999px; }
                #relative { position:relative; left:-64em; }
                """, typography: .init(fontSize: fontSize))
            XCTAssertTrue(result.style("inherited").isVisuallyHiddenPositionedBox)
            XCTAssertFalse(result.style("trailing").isVisuallyHiddenPositionedBox)
            XCTAssertFalse(result.style("relative").isVisuallyHiddenPositionedBox)
            XCTAssertEqual(result.style("trailing").positionRight, .points(-1000))
            XCTAssertEqual(result.style("trailing").positionBottom, .points(-1000))
        }
    }
}
