@testable import EPUBViewing
import XCTest

/// CSS Cascade 4: origins and importance, specificity, order of appearance across sheets,
/// `inherit`/`initial`/`unset`/`revert`, inheritance, `style` attributes and custom properties.
final class CSSCascadeOrderCoverageTests: XCTestCase {
    private typealias Border = ComputedStyle.Border
    private let red = CSSCascadeSupport.color(1, 0, 0), blue = CSSCascadeSupport.color(0, 0, 1), maroon = CSSCascadeSupport.hex(0x800000)

    private func styled(_ body: String, css: String = "", typography: NativeTypography = NativeTypography(fontSize: 16)) throws -> StyledDocument {
        try CSSCascadeSupport.styled(body, css: css, typography: typography)
    }

    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Origins, importance, specificity and order

    /// CSS Cascade 4 §6.1: user-agent, then presentational hints and author rules, then the
    /// `style` attribute, then `!important` author rules, then an `!important` `style` attribute.
    func testOriginsAndImportanceApplyInCascadeOrder() throws {
        let result = try styled("""
            <table><tr><th id="ua">a</th><th id="hint" align="left">b</th><th id="author" align="left" class="r">c</th>
            <th id="inline" align="left" class="r" style="text-align: justify">d</th>
            <th id="important" class="i" style="text-align: justify">e</th>
            <th id="inline-important" class="i" style="text-align: end !important">f</th>
            <th id="specific" class="i">g</th><th id="weak" class="star">h</th><th id="spaced" class="s1 s2 s3">i</th></tr></table>
            """, css: """
            .r { text-align: right }
            .i { text-align: center !important }
            #specific { text-align: left !important }
            #inline-important, #important { text-align: left }
            .star { text-align: right ! IMPORTANT }
            #weak { text-align: left }
            .s1 { margin-left: 1px !important; margin-left: 2px }
            .s2 { margin-left: 3px !importantx }
            .s3 { margin-left: 4px !important !important }
            """)
        XCTAssertEqual(result.style("ua").textAlign, .center, "The user-agent sheet centres a th")
        XCTAssertEqual(result.style("hint").textAlign, .left, "A presentational hint beats the user-agent sheet")
        XCTAssertEqual(result.style("author").textAlign, .right, "An author rule beats a hint")
        XCTAssertEqual(result.style("inline").textAlign, .justify, "The style attribute beats author rules")
        XCTAssertEqual(result.style("important").textAlign, .center, "An !important rule beats the style attribute and a more specific normal rule")
        XCTAssertEqual(result.style("inline-important").textAlign, .end, "An !important style attribute beats !important rules")
        XCTAssertEqual(result.style("specific").textAlign, .left, "Among !important rules specificity decides")
        XCTAssertEqual(result.style("weak").textAlign, .right, "`! IMPORTANT` is important, whatever its case and spacing")
        XCTAssertEqual(result.style("spaced").margin.left, .points(1), "A malformed !important invalidates its declaration")
    }

    func testSpecificityComparesColumnsWithoutCarryAndOrderBreaksTies() throws {
        let classes = String(repeating: ".c", count: 11)
        let result = try styled("""
            <div><div><div><div><div><div><div><div><div><div><div><p id="one" class="c k">x</p><p id="two" class="c k">y</p></div></div></div></div></div></div></div></div></div></div></div>
            """, css: """
            #one { margin-left: 1px }
            \(classes) { margin-left: 2px; margin-right: 2px }
            .k { margin-top: 1px; margin-right: 1px }
            html body div div div div div div div div div div div p { margin-top: 2px; margin-bottom: 2px }
            p.c { padding-left: 1px } p.k { padding-left: 2px } .c.k { padding-right: 1px } p.c { padding-right: 2px }
            p { margin-bottom: 1px } :where(#one, #two) { margin-bottom: 3px } * { text-indent: 1px } p:not(#nope) { text-indent: 2px }
            """)
        for id in ["one", "two"] {
            XCTAssertEqual(result.style(id).margin.top, .points(1), "One class beats fourteen type selectors")
            XCTAssertEqual(result.style(id).margin.right, .points(2), "Eleven classes beat one")
            XCTAssertEqual(result.style(id).padding.left, .points(2), "Equal specificity: the later rule wins")
            XCTAssertEqual(result.style(id).padding.right, .points(1), "Two classes beat a class and a type though they come first")
            XCTAssertEqual(result.style(id).margin.bottom, .points(2), ":where() adds nothing, so the type selectors still win")
            XCTAssertEqual(result.style(id).textIndent, .points(2), ":not() counts its argument")
        }
        XCTAssertEqual(result.style("one").margin.left, .points(1), "One id beats eleven classes")
        XCTAssertEqual(result.style("two").margin.left, .points(2))
    }

    func testOrderOfAppearanceSpansLinkedSheetsStyleElementsAndImports() throws {
        let section = StyleTestSupport.xhtml(body: """
            <p id="p" class="c">x</p><style>#q { color: blue }</style><p id="q" class="c">y</p><p id="r" class="c">z</p>
            """, head: """
            <style>.c { color: red; text-indent: 1px; margin-left: 1px }</style>
            <link rel="stylesheet" href="css/a.css"/>
            <style>.c { text-indent: 3px }</style>
            <link rel="stylesheet" href="css/b.css" title="Preferred"/>
            <link rel="STYLESHEET" href="css/with%20space.css"/>
            <link href="css/norel.css"/>
            <link rel="stylesheet" href="css/c.css" media="print"/>
            """)
        let files = ["css/a.css": "@import \"i.css\"; .c { color: green; text-indent: 2px; margin-left: 2px }",
                     "css/i.css": ".c { color: yellow; margin-right: 7px; margin-left: 9px }", "css/b.css": ".c { margin-left: 4px }",
                     "css/with space.css": "#r { font-weight: 900 }", "css/norel.css": "#r { font-style: italic }", "css/c.css": ".c { color: black }"]
        let result = try StyleTestSupport.styled(section: section, files: files.mapValues { Data($0.utf8) }, typography: NativeTypography(fontSize: 16))
        XCTAssertEqual(result.style("p").color, CSSCascadeSupport.hex(0x008000), "A linked sheet follows the style element before it, and its import")
        XCTAssertEqual(result.style("p").textIndent, .points(3), "A style element after a link follows the linked sheet")
        XCTAssertEqual(result.style("p").margin.left, .points(4), "The last linked sheet wins")
        XCTAssertEqual(result.style("p").margin.right, .points(7), "An imported rule applies where nothing later overrides it")
        XCTAssertEqual(result.style("q").color, blue, "A style element in the body counts, by id over class")
        XCTAssertEqual(result.style("r").fontWeight, 900, "A percent-encoded href names the archive file")
        XCTAssertFalse(result.style("r").isItalic, "A link without rel=stylesheet is not a stylesheet")
        XCTAssertEqual(result.report, SectionReport())
    }

    func testAnInvalidDeclarationNeverBlocksAValidOneElsewhereInTheCascade() throws {
        let result = try styled("""
            <p id="a">a</p><p id="b" style="color: bogus; margin-left: 5px">b</p><p id="c">c</p><p id="d">d</p><p id="e">e</p>
            """, css: """
            p { color: red; display: block; float: left; position: relative; white-space: pre; text-align: right; list-style: square inside }
            #a { color: bogus; display: bogus; float: middle; position: floating; white-space: wide; text-align: 5px; list-style: 1 2 3 4 }
            #c { color: bogus !important; margin-left: 1px; margin-left: -webkit-calc(bogus) !important }
            #d { color: blue; color: ; margin-left: 2px; margin-left }
            #e { color: blue; colour: green; COLOR: lime; margin-left: 2px; margin--left: 9px }
            """)
        let a = result.style("a")
        XCTAssertEqual(a.color, red)
        XCTAssertEqual(a.display, .block); XCTAssertEqual(a.float, .left); XCTAssertEqual(a.position, .relative)
        XCTAssertEqual(a.whiteSpace, .pre); XCTAssertEqual(a.textAlign, .right)
        XCTAssertEqual(a.listStyleType, .square); XCTAssertEqual(a.listStylePosition, .inside)
        XCTAssertEqual(result.style("b").color, red, "An invalid style attribute declaration leaves the sheet's value")
        XCTAssertEqual(result.style("b").margin.left, .points(5))
        XCTAssertEqual(result.style("c").color, red, "!important does not rescue an invalid value")
        XCTAssertEqual(result.style("c").margin.left, .points(1))
        XCTAssertEqual(result.style("d").color, blue, "An empty value is invalid")
        XCTAssertEqual(result.style("d").margin.left, .points(2))
        XCTAssertEqual(result.style("e").color, CSSCascadeSupport.color(0, 1, 0), "Property names are case-insensitive; unknown ones are dropped")
        XCTAssertEqual(result.style("e").margin.left, .points(2))
    }

    func testShorthandsAndLonghandsOverrideEachOtherInOrderAndBySpecificity() throws {
        let result = try styled("""
            <p id="a">a</p><p id="b">b</p><p id="c">c</p><p id="d">d</p><p id="e">e</p><p id="f">f</p><ul id="g"><li>g</li></ul><p id="h">h</p>
            <p id="i">i</p><p id="j">j</p>
            """, css: """
            #a { margin-left: 9px; margin: 1px } #b { margin: 1px; margin-left: 9px }
            #c { margin-left: 3px !important; margin: 8px }
            #d { border-top-color: blue; border: 1px solid red } #e { border: 1px solid red; border-top-color: blue }
            #f { font-weight: bold; line-height: 3; font: 12px serif }
            #g { list-style-type: square; list-style: inside }
            #h { text-decoration-color: blue; color: red; text-decoration: underline }
            p { margin: 1px; border-left: 4px solid } #i { margin-left: 9px; border-left-width: 2px }
            #j { background-color: red; background: none; padding: 1px 2px; padding-top: 5px; padding: 3px }
            """)
        XCTAssertEqual(result.style("a").margin.left, .points(1))
        XCTAssertEqual(result.style("b").margin, .init(top: .points(1), right: .points(1), bottom: .points(1), left: .points(9)))
        XCTAssertEqual(result.style("c").margin, .init(top: .points(8), right: .points(8), bottom: .points(8), left: .points(3)))
        XCTAssertEqual(result.style("d").border.top.color, red)
        XCTAssertEqual(result.style("e").border.top.color, blue)
        XCTAssertEqual(result.style("e").border.left.color, red)
        XCTAssertEqual(result.style("f").fontWeight, 400)
        XCTAssertEqual(result.style("f").lineHeight, .normal)
        XCTAssertEqual(result.style("g").listStyleType, .disc)
        XCTAssertEqual(result.style("g").listStylePosition, .inside)
        XCTAssertEqual(result.style("h").textDecorationColor, red, "The shorthand resets the color to currentcolor")
        XCTAssertEqual(result.style("i").margin, .init(top: .points(1), right: .points(1), bottom: .points(1), left: .points(9)))
        XCTAssertEqual(result.style("i").border.left, Border(width: 2, style: .solid, color: nil), "A longhand overrides one part of a less specific shorthand")
        XCTAssertNil(result.style("j").backgroundColor)
        XCTAssertEqual(result.style("j").padding, .init(.points(3)))
    }

    // MARK: Global keywords and inheritance

    func testInheritInitialUnsetAndRevertOnInheritedAndOtherProperties() throws {
        let result = try styled("""
            <div id="d"><p id="inherit">a</p><p id="initial">b</p><p id="unset">c</p><h1 id="revert">d</h1><b id="rb">e</b>
            <ul><li id="rl">f</li></ul><p id="rh" align="center" style="text-align: revert">g</p><p id="rlayer">h</p><p id="ri">i</p>
            <p id="upper">j</p></div>
            """, css: """
            #d { color: maroon; text-indent: 3px; border: 2px solid red; margin-left: 10px; padding-left: 4px; text-align: right }
            #inherit { border: inherit; margin-left: inherit; padding-left: inherit; text-indent: inherit }
            #initial { color: initial; text-indent: initial; text-align: initial; display: initial; margin: initial; font-weight: initial }
            #unset { color: unset; text-indent: unset; border: unset; margin-left: unset; display: unset }
            h1#revert { margin: revert; font-size: revert; font-weight: revert; display: inline; display: revert; color: revert }
            #rb { font-weight: 100; font-weight: revert }
            #rl { display: block; display: revert; list-style-type: square; list-style-type: revert }
            #rlayer { margin-top: 50px; margin-top: revert-layer }
            #ri { text-align: left; text-align: revert }
            #upper { color: INHERIT; margin-left: Initial; text-indent: UNSET; display: Revert }
            """)
        let inherit = result.style("inherit")
        XCTAssertEqual(inherit.border, .init(Border(width: 2, style: .solid, color: red)))
        XCTAssertEqual(inherit.margin.left, .points(10))
        XCTAssertEqual(inherit.padding.left, .points(4))
        XCTAssertEqual(inherit.textIndent, .points(3))
        let initial = result.style("initial")
        XCTAssertNil(initial.color)
        XCTAssertEqual(initial.textIndent, .points(0)); XCTAssertEqual(initial.textAlign, .start)
        XCTAssertEqual(initial.display, .inline); XCTAssertEqual(initial.margin, .init(.points(0))); XCTAssertEqual(initial.fontWeight, 400)
        let unset = result.style("unset")
        XCTAssertEqual(unset.color, maroon, "unset inherits an inherited property")
        XCTAssertEqual(unset.textIndent, .points(3))
        XCTAssertEqual(unset.border, .init(Border()), "…and resets any other")
        XCTAssertEqual(unset.margin.left, .points(0)); XCTAssertEqual(unset.display, .inline)
        let revert = result.style("revert")
        XCTAssertEqual(revert.fontSize, 32); XCTAssertEqual(revert.fontWeight, 700); XCTAssertEqual(revert.display, .block)
        XCTAssertEqual(CSSCascadeSupport.points(revert.margin.top), 32 * 0.67, accuracy: 0.0001)
        XCTAssertEqual(revert.margin.left, .points(0))
        XCTAssertEqual(revert.color, maroon, "With no user-agent value, revert is unset")
        XCTAssertEqual(result.style("rb").fontWeight, 700, "The user-agent's bolder")
        XCTAssertEqual(result.style("rl").display, .listItem)
        XCTAssertEqual(result.style("rl").listStyleType, .disc, "Inherited from the ul")
        XCTAssertEqual(result.style("rh").textAlign, .right, "revert rolls back presentational hints too: they are author-level")
        XCTAssertEqual(result.style("rlayer").margin.top, .points(16), "Without layers, revert-layer rolls back to the user-agent origin")
        XCTAssertEqual(result.style("ri").textAlign, .right)
        let upper = result.style("upper")
        XCTAssertEqual(upper.color, maroon); XCTAssertEqual(upper.margin.left, .points(0))
        XCTAssertEqual(upper.textIndent, .points(3)); XCTAssertEqual(upper.display, .block)
    }

    func testAllResetsEveryPropertyButDirection() throws {
        let result = try styled("""
            <div id="d"><p id="inherit">a</p><b id="unset">b</b><h1 id="revert" class="x">c</h1><p id="initial" dir="rtl">d</p>
            <p id="then" dir="rtl">e</p></div>
            """, css: """
            #d { color: maroon; border: 2px solid red; margin-left: 10px; text-align: right; float: left; width: 50% }
            #inherit { all: inherit } #unset { all: unset } h1.x { font-size: 10px; display: inline; font-style: italic; all: revert }
            #initial { margin-left: 5px; all: initial } #then { all: initial; margin-left: 5px; color: blue }
            """)
        let inherit = result.style("inherit")
        XCTAssertEqual(inherit.border, .init(Border(width: 2, style: .solid, color: red)))
        XCTAssertEqual(inherit.margin.left, .points(10)); XCTAssertEqual(inherit.float, .left); XCTAssertEqual(inherit.width, .percent(50))
        XCTAssertEqual(inherit.margin.top, .points(0), "The parent's margin, not the user-agent's for p")
        XCTAssertEqual(result.style("unset").fontWeight, 400, "all: unset drops the user-agent's bolder too")
        XCTAssertEqual(result.style("unset").color, maroon)
        XCTAssertEqual(result.style("unset").textAlign, .right)
        let revert = result.style("revert")
        XCTAssertEqual(revert.fontSize, 32); XCTAssertEqual(revert.display, .block); XCTAssertFalse(revert.isItalic); XCTAssertEqual(revert.fontWeight, 700)
        let initial = result.style("initial")
        XCTAssertEqual(initial.display, .inline); XCTAssertNil(initial.color); XCTAssertEqual(initial.margin.left, .points(0))
        XCTAssertEqual(initial.textAlign, .start)
        XCTAssertEqual(initial.direction, .rtl, "CSS Cascade 4 §3.2: all excludes direction")
        XCTAssertEqual(result.style("then").margin.left, .points(5), "Declarations after all still apply")
        XCTAssertEqual(result.style("then").color, blue)
    }

    func testInheritedPropertiesReachDescendantsAndOthersStopAtTheirElement() throws {
        let result = try styled(#"<div id="top"><section id="mid"><div><span id="deep">x</span></div></section></div>"#, css: """
            #top { font-family: Georgia, serif; font-size: 20px; font-weight: 600; font-style: italic; font-variant: small-caps; line-height: 2;
                   color: red; text-align: center; text-indent: 5px; white-space: pre-wrap; text-transform: uppercase; letter-spacing: 1px;
                   word-spacing: 2px; direction: rtl; writing-mode: vertical-rl; list-style-type: square; list-style-position: inside;
                   hyphens: none; visibility: hidden; border-collapse: collapse; border-spacing: 3px 4px; caption-side: bottom;
                   display: block; float: left; clear: both; position: relative; top: 1px; left: 2px; margin: 3px; padding: 4px;
                   border: 5px solid blue; width: 100px; height: 50px; min-width: 10px; max-width: 200px; min-height: 5px; max-height: 300px;
                   background-color: yellow; vertical-align: top; break-before: page; break-after: page; break-inside: avoid;
                   text-decoration: underline; filter: invert(1); box-sizing: border-box }
            """)
        let top = result.style("top"), deep = result.style("deep")
        var expected = ComputedStyle()
        expected.fontFamilies = ["georgia", "serif"]; expected.fontSize = 20; expected.fontWeight = 600; expected.isItalic = true
        expected.isSmallCaps = true; expected.lineHeight = .multiple(2); expected.color = red; expected.textAlign = .center
        expected.textIndent = .points(5); expected.whiteSpace = .preWrap; expected.textTransform = .uppercase; expected.letterSpacing = 1
        expected.wordSpacing = 2; expected.direction = .rtl; expected.writingMode = .verticalRL; expected.listStyleType = .square
        expected.listStylePosition = .inside; expected.hyphens = .none; expected.isHidden = true; expected.borderCollapse = true
        expected.borderSpacing = CGSize(width: 3, height: 4); expected.captionSide = .bottom
        // A decoration is drawn through descendants in the decorating box's color; it is not inherited.
        expected.textDecoration = .underline; expected.textDecorationColor = red
        XCTAssertEqual(deep, expected, "Three levels down, exactly the inherited properties and nothing else")
        XCTAssertEqual(top.float, .left); XCTAssertEqual(top.position, .relative); XCTAssertEqual(top.width, .points(100))
        XCTAssertEqual(top.border.top, Border(width: 5, style: .solid, color: blue)); XCTAssertTrue(top.invertsColors)
        XCTAssertEqual(result.style("mid").display, .block, "The user-agent's own value for the child, not the parent's")
        XCTAssertEqual(result.style("mid").margin, .init(.points(0)))
    }

    func testTheRootElementIsBlockAndInheritsTheReadersDefaults() throws {
        func root(_ css: String, size: CGFloat = 18) throws -> ComputedStyle {
            let result = try styled("<p>x</p>", css: css, typography: NativeTypography(fontSize: size))
            return result.styles[result.document.root.order]!
        }
        let plain = try root("")
        XCTAssertEqual(plain.display, .block)
        XCTAssertEqual(plain.fontSize, 18); XCTAssertEqual(plain.fontFamilies, ["serif"]); XCTAssertEqual(plain.fontWeight, 400)
        XCTAssertEqual(plain.lineHeight, .multiple(1.4)); XCTAssertEqual(plain.hyphens, .auto); XCTAssertNil(plain.color)
        XCTAssertEqual(try root("html { display: inline }").display, .block, "CSS Display 3 §2.8: the root is blockified")
        XCTAssertEqual(try root(":root { display: inline-block }").display, .block)
        XCTAssertEqual(try root("html { display: none }").display, ComputedStyle.Display.none)
        XCTAssertEqual(try root("html { font-size: 2em }").fontSize, 36, "The root's em is the reader's size")
        XCTAssertEqual(try root("html { font-size: 150% }").fontSize, 27)
        XCTAssertEqual(try root("html { font-size: larger }").fontSize, 18 * 1.2, accuracy: 0.0001)
        XCTAssertEqual(try root("html { line-height: inherit; hyphens: inherit; font-family: inherit }").lineHeight, .multiple(1.4))
        XCTAssertEqual(try root("html { line-height: initial }").lineHeight, .normal)
        XCTAssertEqual(try root("html { font-size: 62.5% }").fontSize, 11.25)
        XCTAssertEqual(try root("html { font-size: 16px }", size: 30).fontSize, 30, "16px is the reader's size, whatever it is")
    }

    // MARK: The style attribute

    func testStyleAttributesTolerateStrayPunctuationCommentsAndCase() throws {
        let result = try styled("""
            <p id="a" style="">a</p><p id="b" style=";;color:red;;MARGIN-LEFT:7PX;">b</p><p id="c" style="color: red; background: url(x">c</p>
            <p id="d" style="color: red } p { color: blue">d</p><p id="e" style="  color : red  ;  text-indent : 2px  ">e</p>
            <p id="f" style="color: red; color: ; margin-left: 5px">f</p><p id="g" style="/* c */ color: red /* d */; /* margin-left: 9px */">g</p>
            <p id="h" style="color: red&#10;;&#9;margin-left:&#10;3px">h</p><p id="i" style="color: red; @media print { color: blue } margin-left: 4px">i</p>
            <p id="j" style="font-family: &quot;A B&quot;, 'C'">j</p><p id="k" style="color: red !important; margin-left: 2px">k</p>
            <p id="l" style="{ color: red }">l</p><p id="m" style="color=red">m</p>
            """, css: "#k { color: blue !important; margin-left: 9px !important } #a, #l, #m { color: blue }")
        XCTAssertEqual(result.style("a").color, blue)
        XCTAssertEqual(result.style("b").color, red); XCTAssertEqual(result.style("b").margin.left, .points(7))
        XCTAssertEqual(result.style("c").color, red, "An unterminated url() ends with the attribute")
        XCTAssertNil(result.style("d").color, "A declaration cannot close the attribute and open a rule")
        XCTAssertEqual(result.style("e").color, red); XCTAssertEqual(result.style("e").textIndent, .points(2))
        XCTAssertEqual(result.style("f").color, red); XCTAssertEqual(result.style("f").margin.left, .points(5))
        XCTAssertEqual(result.style("g").color, red); XCTAssertEqual(result.style("g").margin.left, .points(0))
        XCTAssertEqual(result.style("h").color, red); XCTAssertEqual(result.style("h").margin.left, .points(3))
        XCTAssertEqual(result.style("i").color, red); XCTAssertEqual(result.style("i").margin.left, .points(4))
        XCTAssertEqual(result.style("j").fontFamilies, ["a b", "c"])
        XCTAssertEqual(result.style("k").color, red); XCTAssertEqual(result.style("k").margin.left, .points(9))
        XCTAssertEqual(result.style("l").color, blue, "A style attribute is a declaration list, not a rule")
        XCTAssertEqual(result.style("m").color, blue)
        XCTAssertFalse(result.resolver.stylesTruncated)
    }

    func testAStyleAttributePastTheLimitIsCutAndReported() throws {
        let limit = StyleResolver.maximumInlineStyleBytes
        let head = "color: red;"
        let within = head + String(repeating: " ", count: limit - head.utf8.count - "text-indent:9px".utf8.count) + "text-indent:9px"
        XCTAssertEqual(within.utf8.count, limit)
        let over = head + String(repeating: " ", count: limit - head.utf8.count) + "text-indent: 9px"
        let fits = try styled("<p id=\"p\" style=\"\(within)\">x</p>")
        XCTAssertFalse(fits.resolver.stylesTruncated, "Exactly \(limit) bytes fit")
        XCTAssertEqual(fits.style("p").textIndent, .points(9))
        let cut = try styled("<p id=\"p\" style=\"\(over)\">x</p><p id=\"q\" style=\"margin-left: 3px\">y</p>")
        XCTAssertTrue(cut.resolver.stylesTruncated)
        XCTAssertEqual(cut.style("p").color, red, "What precedes the cut applies")
        XCTAssertEqual(cut.style("p").textIndent, .points(0), "What follows it does not")
        XCTAssertEqual(cut.style("q").margin.left, .points(3))
    }

    /// `SectionStyles` cuts an oversized sheet after a `}`, "so no rule is cut". A `style`
    /// attribute cut inside a value must likewise not apply a value its author never wrote.
    func testACutStyleAttributeNeverAppliesPartOfADeclaration() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/125")
        let limit = StyleResolver.maximumInlineStyleBytes
        let head = "color: red; "
        let padding = String(repeating: " ", count: limit - head.utf8.count - "line-height: 1.5".utf8.count)
        let style = head + padding + "line-height: 1.55; margin-left: 9px"
        XCTAssertTrue(String(decoding: style.utf8.prefix(limit), as: UTF8.self).hasSuffix("line-height: 1.5"), "The cut falls inside 1.55")
        let result = try styled("<p id=\"p\" style=\"\(style)\">x</p>")
        XCTAssertTrue(result.resolver.stylesTruncated)
        XCTAssertEqual(result.style("p").color, red)
        let lineHeight = result.style("p").lineHeight
        XCTAssertTrue(lineHeight == .multiple(1.4) || lineHeight == .multiple(1.55),
                      "\(lineHeight): the cut declaration is dropped (the inherited 1.4) or kept whole (1.55), never read as 1.5")
    }

    // MARK: Custom properties

    /// CSS Custom Properties for Cascading Variables 1 §3 (part of the CSS Snapshot that EPUB
    /// Reading Systems 3.3 §6.3 requires): `var()` substitutes a custom property's value.
    func testCustomPropertiesSubstituteIntoVar() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/119")
        let result = try styled(#"<div id="d"><p id="a">a</p><p id="b">b</p><p id="c">c</p><p id="e">e<span id="f">f</span></p></div>"#, css: """
            :root { --accent: #0000ff; --gap: 12px }
            #d { color: red }
            #a { color: var(--accent) }
            #b { margin-left: var(--gap); padding-left: calc(var(--gap) * 2) }
            #c { color: var(--missing, #0000ff) }
            #e { --accent: #00ff00 } #f { color: var(--accent) }
            """)
        XCTAssertEqual(result.style("a").color, blue, "color: var(--accent) with :root { --accent: #0000ff }")
        XCTAssertEqual(result.style("b").margin.left, .points(12), "margin-left: var(--gap)")
        XCTAssertEqual(result.style("b").padding.left, .points(24), "var() inside calc()")
        XCTAssertEqual(result.style("c").color, blue, "The fallback of an undefined property")
        XCTAssertEqual(result.style("f").color, CSSCascadeSupport.color(0, 1, 0), "Custom properties inherit and can be redefined")
    }

    // MARK: Hostile input

    func testStylesheetsCutShortNeverTrapAndKeepTheRulesBeforeTheCut() throws {
        let fragments = [
            "p { color: rgb(", "p { width: calc(", "p { background: url(", "p { font: 12px/", "p { color: #", "p { margin: 1px 2px /",
            "p { color: hsl(120 100%", "p { clip: rect(", "p { font-family: \"unterminated", "p { color: red !", "p { filter: invert(",
            "p { border: 1px solid rgb(0 0 0 /", "p { list-style: url(", "p { text-decoration: underline rgb(", "p { width: min(1px,",
            "p { font: italic", "p { margin:", "p {", "p", "@font-face { src: url(", "@font-face { font-family:", "@media (", "p { color: \\",
            "p { grid-template-columns: repeat(", "p { content: '\\", "p { width: 1e", "p { width: -", "p { width: +.", "@import", "@import url(",
            "@namespace", "p { color: rgba(1,2,3,", "p{font:12px/1.2 a,", "/* unterminated comment", "p { width: calc((((((((((((", "p { width: clamp(1px,",
            "p { vertical-align: calc(1px *", "p { line-height: calc(", "p { border-spacing: 1px calc(", "p { color: hwb(0 0%", "p { font-weight: +",
            "p { text-align: center left", "p { display: block flow", "@supports (", "p[", "p:not(", "p::", "@", "#", ".", "\\", "u+", "<!--", "p { --x: {",
        ]
        for fragment in fragments {
            let result = try styled(#"<p id="p">x</p>"#, css: "p { text-indent: 3px }\n" + fragment)
            XCTAssertEqual(result.style("p").textIndent, .points(3), fragment)
            XCTAssertTrue(result.style("p").fontSize.isFinite, fragment)
        }
        let inline = fragments.filter { $0.hasPrefix("p { ") }.map { String($0.dropFirst(4)) }
        let body = inline.enumerated().map { "<p id=\"i\($0.offset)\" style=\"text-indent: 3px; \(escaped($0.element))\">x</p>" }.joined()
        let result = try styled(body)
        for (index, fragment) in inline.enumerated() { XCTAssertEqual(result.style("i\(index)").textIndent, .points(3), fragment) }
    }
}
