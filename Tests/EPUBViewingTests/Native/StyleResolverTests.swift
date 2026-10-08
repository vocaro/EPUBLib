import EPUBReading
@testable import EPUBViewing
import Synchronization
import XCTest

final class StyleResolverTests: XCTestCase {
    private func styled(_ body: String, css: String = "", head: String = "", files: [String: String] = [:],
                        typography: NativeTypography = NativeTypography(fontSize: 16)) throws -> StyledDocument {
        try StyleTestSupport.styled(body, css: css, head: head, files: files, typography: typography)
    }
    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> ComputedStyle.Color {
        StyleTestSupport.color(red, green, blue, alpha)
    }
    private func points(_ length: ComputedStyle.Length) -> CGFloat {
        if case .points(let value) = length { return value }
        XCTFail("\(length) is not in points")
        return .nan
    }

    func testUserAgentDefaults() throws {
        let result = try styled("""
            <h1 id="h1">T</h1><p id="p">P <b id="b">B</b> <code id="code">c</code> <sup id="sup">1</sup></p>
            <pre id="pre">  x</pre><ul id="ul"><li id="li">i<ul id="inner"><li>j</li></ul></li></ul><ol id="ol"/>
            <blockquote id="bq">q</blockquote><figure id="figure"><figcaption id="caption">c</figcaption></figure>
            <noscript id="noscript">n</noscript><script id="script"/><p id="hidden" hidden="">h</p>
            <table id="table"><tr id="tr"><th id="th">h</th><td id="td">d</td></tr></table>
            <ruby id="ruby">漢<rp id="rp">(</rp><rt id="rt">kan</rt></ruby><a id="link" href="x.xhtml">l</a><a id="anchor">a</a>
            <m:math id="math" display="block"><m:mi>x</m:mi></m:math><m:math id="inline-math"><m:mi>y</m:mi></m:math>
            """, typography: NativeTypography(fontSize: 20))
        let html = result.styles[result.document.root.order]!
        XCTAssertEqual(html.fontFamilies, ["serif"])
        XCTAssertEqual(html.lineHeight, .multiple(1.4))
        XCTAssertEqual(html.hyphens, .auto)
        XCTAssertEqual(result.style("h1").fontSize, 40)
        XCTAssertEqual(result.style("h1").fontWeight, 700)
        XCTAssertEqual(result.style("h1").margin.top, .points(40 * 0.67))
        XCTAssertEqual(result.style("h1").breakAfter, .avoid)
        XCTAssertEqual(result.style("p").margin.top, .points(20))
        XCTAssertEqual(result.style("p").display, .block)
        XCTAssertEqual(result.style("b").fontWeight, 700)
        XCTAssertEqual(result.style("code").fontFamilies, ["monospace"])
        XCTAssertEqual(result.style("sup").verticalAlign, .super)
        XCTAssertEqual(result.style("sup").fontSize, 20 / 1.2, accuracy: 0.001)
        XCTAssertEqual(result.style("pre").whiteSpace, .pre)
        XCTAssertEqual(result.style("ul").padding.left, .points(40))
        XCTAssertEqual(result.style("ul").listStyleType, .disc)
        XCTAssertEqual(result.style("inner").listStyleType, .circle)
        XCTAssertEqual(result.style("inner").margin.top, .points(0))
        XCTAssertEqual(result.style("li").display, .listItem)
        XCTAssertEqual(result.style("ol").listStyleType, .decimal)
        XCTAssertEqual(result.style("bq").margin.left, .points(40))
        XCTAssertEqual(result.style("caption").textAlign, .center)
        XCTAssertLessThan(result.style("caption").fontSize, 20)
        XCTAssertEqual(result.style("noscript").display, .inline, "Scripts never run, so noscript renders")
        XCTAssertEqual(result.style("script").display, ComputedStyle.Display.none)
        XCTAssertEqual(result.style("hidden").display, ComputedStyle.Display.none)
        XCTAssertEqual(result.style("table").display, .table)
        XCTAssertEqual(result.style("table").borderSpacing, CGSize(width: 2, height: 2))
        XCTAssertEqual(result.style("tr").display, .tableRow)
        XCTAssertEqual(result.style("th").textAlign, .center)
        XCTAssertEqual(result.style("td").display, .tableCell)
        XCTAssertEqual(result.style("td").verticalAlign, .middle)
        XCTAssertEqual(result.style("ruby").display, .ruby)
        XCTAssertEqual(result.style("rt").display, .rubyText)
        XCTAssertEqual(result.style("rp").display, ComputedStyle.Display.none)
        XCTAssertEqual(result.style("link").textDecoration, .underline)
        XCTAssertEqual(result.style("anchor").textDecoration, [])
        XCTAssertEqual(result.style("math").display, .block)
        XCTAssertEqual(result.style("math").textAlign, .center)
        XCTAssertEqual(result.style("math").margin.top, .points(10))
        XCTAssertEqual(result.style("inline-math").display, .inline)
    }

    func testCascadeOrder() throws {
        let result = try styled("""
            <p id="a" class="c">a</p><p id="b" class="c" style="color: #00f">b</p>
            <p id="c" class="c" style="color: #00f">c</p><p id="d" class="d" style="color: #00f !important">d</p>
            """, css: """
            p { color: red; font-weight: 300 }
            .c { color: green }
            p { font-weight: 600 }
            p.c { text-align: right }
            .c { text-align: left }
            #c { color: yellow !important }
            p.d { color: lime !important }
            """)
        XCTAssertEqual(result.style("a").color, color(0, 128 / 255, 0), "A class beats a type selector")
        XCTAssertEqual(result.style("a").fontWeight, 600, "Later rules of equal specificity win")
        XCTAssertEqual(result.style("a").textAlign, .right, "Specificity beats order")
        XCTAssertEqual(result.style("b").color, color(0, 0, 1), "The style attribute beats rules")
        XCTAssertEqual(result.style("c").color, color(1, 1, 0), "!important rules beat the style attribute")
        XCTAssertEqual(result.style("d").color, color(0, 0, 1), "An !important style attribute beats !important rules")
    }

    func testInheritanceAndGlobalKeywords() throws {
        let result = try styled("""
            <div id="div"><p id="inherits">x</p><p id="explicit">y</p><p id="initial">z</p><p id="unset">u</p>
            <h1 id="revert">r</h1><span id="all">s</span></div>
            """, css: """
            div { color: red; margin-left: 10px; text-indent: 2em; font-size: 20px; font-family: Georgia }
            #explicit { margin-left: inherit; color: unset }
            #initial { color: initial; font-size: initial; font-family: initial; text-indent: initial }
            #unset { margin-left: unset; text-indent: unset }
            h1 { display: inline; font-weight: normal }
            #revert { display: revert; font-weight: revert }
            #all { all: initial }
            """, typography: NativeTypography(fontSize: 18))
        XCTAssertEqual(result.style("inherits").color, color(1, 0, 0))
        XCTAssertEqual(result.style("inherits").margin.left, .points(0), "Margins are not inherited")
        XCTAssertEqual(result.style("inherits").textIndent, .points(2 * 20 * 18 / 16), "em computes before inheriting")
        XCTAssertEqual(result.style("explicit").margin.left, .points(10))
        XCTAssertEqual(result.style("explicit").color, color(1, 0, 0))
        XCTAssertNil(result.style("initial").color)
        XCTAssertEqual(result.style("initial").fontSize, 18)
        XCTAssertEqual(result.style("initial").fontFamilies, ["serif"])
        XCTAssertEqual(result.style("unset").margin.left, .points(0))
        XCTAssertEqual(result.style("revert").display, .block)
        XCTAssertEqual(result.style("revert").fontWeight, 700)
        XCTAssertEqual(result.style("all").display, .inline)
        XCTAssertNil(result.style("all").color)
        XCTAssertEqual(result.style("all").fontSize, 18)
    }

    func testShorthands() throws {
        let result = try styled("""
            <p id="m1">a</p><p id="m2">b</p><p id="m3">c</p><p id="m4">d</p><p id="border">e</p><p id="font">f</p>
            <ul id="list"><li>g</li></ul><p id="bg">h</p><p id="breaks">i</p><p id="side">j</p><p id="none">k</p>
            """, css: """
            #m1 { margin: 1px } #m2 { margin: 1px 2px } #m3 { margin: 1px 2px 3px } #m4 { margin: 1px 2px 3px 4px; margin-right: auto }
            #border { border: 2px dashed red; border-left: thick double; border-top-style: none }
            #font { font: italic small-caps 300 2em/30px Palatino, serif }
            #list { list-style: inside lower-roman }
            #bg { background: #123456 url(x.png) no-repeat }
            #breaks { page-break-before: always; page-break-inside: avoid; break-after: column }
            #side { padding: 1em 0; padding-left: 5%; border-width: 1px; border-style: solid }
            #none { border: 3px none }
            """)
        XCTAssertEqual(result.style("m1").margin, .init(.points(1)))
        XCTAssertEqual(result.style("m2").margin, .init(top: .points(1), right: .points(2), bottom: .points(1), left: .points(2)))
        XCTAssertEqual(result.style("m3").margin, .init(top: .points(1), right: .points(2), bottom: .points(3), left: .points(2)))
        XCTAssertEqual(result.style("m4").margin, .init(top: .points(1), right: .auto, bottom: .points(3), left: .points(4)))
        let border = result.style("border").border
        XCTAssertEqual(border.right, .init(width: 2, style: .dashed, color: color(1, 0, 0)))
        XCTAssertEqual(border.left, .init(width: 5, style: .double, color: nil))
        XCTAssertEqual(border.top.width, 0, "A border with style none has no width")
        let font = result.style("font")
        XCTAssertTrue(font.isItalic); XCTAssertTrue(font.isSmallCaps)
        XCTAssertEqual(font.fontWeight, 300)
        XCTAssertEqual(font.fontSize, 32)
        XCTAssertEqual(font.lineHeight, .points(30))
        XCTAssertEqual(font.fontFamilies, ["palatino", "serif"])
        XCTAssertEqual(result.style("list").listStyleType, .lowerRoman)
        XCTAssertEqual(result.style("list").listStylePosition, .inside)
        XCTAssertEqual(result.style("bg").backgroundColor, color(0x12 / 255, 0x34 / 255, 0x56 / 255))
        XCTAssertEqual(result.style("breaks").breakBefore, .page)
        XCTAssertEqual(result.style("breaks").breakInside, .avoid)
        XCTAssertEqual(result.style("breaks").breakAfter, .column)
        XCTAssertEqual(result.style("side").padding, .init(top: .points(16), right: .points(0), bottom: .points(16), left: .percent(5)))
        XCTAssertEqual(result.style("side").border.bottom.width, 1)
        XCTAssertEqual(result.style("none").border.top.width, 0)
    }

    func testLengthsAndFontScaling() throws {
        let typography = NativeTypography(fontSize: 32)
        let result = try styled("""
            <div id="outer"><p id="px">a</p><p id="pt">b</p><p id="em">c<span id="nested">d</span></p><p id="rem">e</p>
            <p id="percent">f</p><p id="keyword">g</p><p id="smaller">h</p><p id="calc">i</p><p id="vw">j</p>
            <p id="absurd">k</p><p id="tiny">l</p><p id="units">m</p><p id="lh">n</p><p id="lh-em">o</p></div>
            """, css: """
            html { font-size: 20px }
            #outer { font-size: 1.5em }
            #px { font-size: 16px; margin-left: 16px }
            #pt { font-size: 12pt; text-indent: 1in }
            #em { font-size: 2em; margin-top: 1em }
            #nested { font-size: 50% }
            #rem { font-size: 1rem; padding-left: 2rem }
            #percent { font-size: 200%; width: 50% }
            #keyword { font-size: x-large }
            #smaller { font-size: smaller }
            #calc { width: calc(100% - 2em); margin-left: calc(1em + 4px); font-size: calc(10px + 1em) }
            #vw { width: 50vw; height: 25vh; margin-left: 10vmin }
            #absurd { font-size: 9000px; margin-left: 99999px; line-height: 500 }
            #tiny { font-size: 0 }
            #units { margin-left: 1cm; margin-right: 6pc; margin-top: 10mm; margin-bottom: 40Q; text-indent: 2ex }
            #lh { font-size: 16px; line-height: 24px }
            #lh-em { line-height: 150% }
            """, typography: typography)
        let scale: CGFloat = 32 / 16
        let root = 20 * scale
        let outer = root * 1.5
        XCTAssertEqual(result.styles[result.document.root.order]!.fontSize, root, "Absolute sizes scale with the reader's size")
        XCTAssertEqual(result.style("outer").fontSize, outer)
        XCTAssertEqual(result.style("px").fontSize, 32, "16px is the reader's size")
        XCTAssertEqual(result.style("px").margin.left, .points(16), "Only font sizes scale")
        XCTAssertEqual(result.style("pt").fontSize, 32, "12pt is 16px")
        XCTAssertEqual(result.style("pt").textIndent, .points(96))
        XCTAssertEqual(result.style("em").fontSize, outer * 2, "font-size em is relative to the parent")
        XCTAssertEqual(result.style("em").margin.top, .points(outer * 2), "Other em lengths use the element's own size")
        XCTAssertEqual(result.style("nested").fontSize, outer)
        XCTAssertEqual(result.style("rem").fontSize, root)
        XCTAssertEqual(result.style("rem").padding.left, .points(root * 2))
        XCTAssertEqual(result.style("percent").fontSize, outer * 2)
        XCTAssertEqual(result.style("percent").width, .percent(50))
        XCTAssertEqual(result.style("keyword").fontSize, 32 * 1.5)
        XCTAssertEqual(result.style("smaller").fontSize, outer / 1.2, accuracy: 0.001)
        let calcSize = 10 * scale + outer
        XCTAssertEqual(result.style("calc").fontSize, calcSize)
        XCTAssertEqual(result.style("calc").margin.left, .points(calcSize + 4))
        guard case .percent(let percent) = result.style("calc").width else { return XCTFail("calc() with % stays symbolic") }
        XCTAssertEqual(percent, 100 - 2 * calcSize / 6, accuracy: 0.001)
        XCTAssertEqual(result.style("vw").width, .viewportWidth(50))
        XCTAssertEqual(result.style("vw").height, .viewportHeight(25))
        XCTAssertEqual(result.style("vw").margin.left, .viewportWidth(10))
        XCTAssertEqual(result.style("absurd").fontSize, 400)
        XCTAssertEqual(result.style("absurd").margin.left, .points(1000))
        XCTAssertEqual(result.style("absurd").lineHeight, .multiple(10))
        XCTAssertEqual(result.style("tiny").fontSize, 4)
        let units = result.style("units")
        XCTAssertEqual(points(units.margin.left), 96 / 2.54, accuracy: 0.0001)
        XCTAssertEqual(points(units.margin.right), 96, accuracy: 0.0001)
        XCTAssertEqual(points(units.margin.top), 96 / 2.54, accuracy: 0.0001)
        XCTAssertEqual(points(units.margin.bottom), 96 / 2.54, accuracy: 0.0001)
        XCTAssertEqual(units.textIndent, .points(outer))
        XCTAssertEqual(result.style("lh").lineHeight, .points(48), "Absolute line heights keep their ratio to the font")
        XCTAssertEqual(result.style("lh-em").lineHeight, .points(outer * 1.5))
    }

    func testFontWeightsStylesAndTextProperties() throws {
        let result = try styled("""
            <div id="light"><b id="bolder">b<b id="boldest">c</b></b><span id="lighter">l</span></div>
            <p id="text">t</p><p id="oblique">o</p><p id="caps">c</p><div dir="rtl" id="rtl"><p id="inner">r</p></div>
            <p id="vertical">v</p><p id="va">a</p><p id="hidden">h</p><p id="abs">x</p>
            """, css: """
            #light { font-weight: 300 }
            #lighter { font-weight: lighter }
            #text { text-align: justify; white-space: pre-line; text-transform: uppercase; letter-spacing: 0.1em; word-spacing: 2px; hyphens: none }
            #oblique { font-style: oblique 10deg }
            #caps { font-variant-caps: all-small-caps }
            #vertical { -webkit-writing-mode: vertical-rl }
            #va { vertical-align: 50%; line-height: 20px }
            #hidden { visibility: collapse }
            #abs { position: absolute; float: right }
            """)
        XCTAssertEqual(result.style("bolder").fontWeight, 400)
        XCTAssertEqual(result.style("boldest").fontWeight, 700)
        XCTAssertEqual(result.style("lighter").fontWeight, 100)
        let text = result.style("text")
        XCTAssertEqual(text.textAlign, .justify)
        XCTAssertEqual(text.whiteSpace, .preLine)
        XCTAssertEqual(text.textTransform, .uppercase)
        XCTAssertEqual(text.letterSpacing, 1.6, accuracy: 0.0001)
        XCTAssertEqual(text.wordSpacing, 2)
        XCTAssertEqual(text.hyphens, ComputedStyle.Hyphens.none)
        XCTAssertTrue(result.style("oblique").isItalic)
        XCTAssertTrue(result.style("caps").isSmallCaps)
        XCTAssertEqual(result.style("inner").direction, .rtl)
        XCTAssertEqual(result.style("vertical").writingMode, .verticalRL)
        XCTAssertEqual(result.style("va").verticalAlign, .offset(10))
        XCTAssertTrue(result.style("hidden").isHidden)
        XCTAssertTrue(result.style("abs").isOutOfFlow)
        XCTAssertEqual(result.style("abs").float, .right)
    }

    func testColorsAndDarkAppearance() throws {
        let body = """
            <div id="div"><p id="p">a <a id="link" href="#x">l</a></p><p id="current">c</p><p id="transparent">t</p>
            <p id="system">s</p></div>
            """
        let css = """
            div { color: hsl(0, 100%, 50%); background-color: rgba(0, 0, 255, 0.5) }
            p { border: 1px solid #0f0; text-decoration: underline wavy #abc }
            #current { border-color: currentColor; background: currentColor; color: blue }
            #transparent { color: transparent; background: transparent }
            #system { color: CanvasText }
            a { text-decoration-color: blue; color: inherit }
            """
        let light = try styled(body, css: css)
        XCTAssertEqual(light.style("div").color, color(1, 0, 0))
        XCTAssertEqual(light.style("div").backgroundColor, color(0, 0, 1, 0.5))
        XCTAssertNil(light.style("p").backgroundColor, "Backgrounds are not inherited")
        XCTAssertEqual(light.style("p").border.top.color, color(0, 1, 0))
        XCTAssertEqual(light.style("p").textDecorationColor, color(0xAA / 255, 0xBB / 255, 0xCC / 255))
        XCTAssertNil(light.style("current").border.top.color, "currentColor borders use the text color")
        XCTAssertEqual(light.style("current").backgroundColor, color(0, 0, 1))
        XCTAssertEqual(light.style("transparent").color, color(0, 0, 0, 0))
        XCTAssertNil(light.style("transparent").backgroundColor)
        XCTAssertNil(light.style("system").color)
        XCTAssertEqual(light.style("link").textDecoration, .underline)
        XCTAssertEqual(light.style("link").textDecorationColor, color(0, 0, 1))

        let dark = try styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: true))
        for id in ["div", "p", "current", "link"] {
            let style = dark.style(id)
            XCTAssertNil(style.color, id)
            XCTAssertNil(style.backgroundColor, id)
            XCTAssertNil(style.textDecorationColor, id)
            XCTAssertNil(style.border.top.color, id)
        }
        XCTAssertEqual(dark.style("transparent").color, color(0, 0, 0, 0), "Invisible text stays invisible in dark appearance")
    }

    func testTextDecorationPropagates() throws {
        let result = try styled("""
            <p id="p">a <span id="span">b <em id="em">c</em></span> <span id="block">d</span> <span id="ib">e</span></p>
            """, css: """
            #p { text-decoration: underline; color: red }
            #span { text-decoration: none; color: blue }
            #em { text-decoration-line: line-through }
            #ib { display: inline-block }
            """)
        XCTAssertEqual(result.style("span").textDecoration, .underline, "Descendants cannot remove an ancestor's decoration")
        XCTAssertEqual(result.style("span").textDecorationColor, color(1, 0, 0), "A propagated decoration keeps its box's color")
        XCTAssertEqual(result.style("em").textDecoration, [.underline, .lineThrough])
        XCTAssertEqual(result.style("em").textDecorationColor, color(0, 0, 1))
        XCTAssertEqual(result.style("ib").textDecoration, [], "Decorations do not propagate into inline blocks")
    }

    func testSelectors() throws {
        let result = try styled("""
            <section epub:type="chapter bodymatter" id="chapter" xml:lang="fr-CA">
            <aside epub:type="footnote" id="note">n</aside><aside epub:type="rearnote" id="rearnote">r</aside>
            <p id="p1" class="first">1</p><p id="p2" title="hello world">2</p><div id="d1">d</div><p id="p3" lang="de">3</p><p id="p4" data-x="pre-mid-post">4</p>
            </section><ol id="ol"><li id="li1">a</li><li id="li2">b</li><li id="li3">c</li><li id="li4">d</li><li id="li5">e</li></ol>
            <div id="empty"></div><div id="whitespace"> </div><svg xmlns="http://www.w3.org/2000/svg" id="svg"><circle id="circle" class="dot"/></svg>
            """, css: """
            @namespace epub "http://www.idpf.org/2007/ops";
            @namespace svg url(http://www.w3.org/2000/svg);
            [epub|type~="footnote"] { color: red }
            *|*[epub|type^="rear"] { color: blue }
            section[epub|type~=bodymatter] > p:first-of-type { text-align: right }
            p + div { text-align: center }
            div ~ p { font-weight: 700 }
            p[title*="lo w"] { font-style: italic }
            p[data-x^="pre"][data-x$="post"] { text-indent: 1px }
            P#P1.FIRST { font-weight: 100 }
            :lang(fr) p:not(:lang(de)) { text-transform: uppercase }
            li:nth-child(2n+1) { color: green }
            li:nth-last-child(2) { font-weight: 900 }
            li:first-child:not(:last-child) { text-decoration: underline }
            li:only-child, li:nth-of-type(4) { text-align: right }
            li:is(:nth-child(5), .missing) { font-style: italic }
            li:where(#li3) { font-style: italic }
            #li3 { font-style: normal }
            div:empty { color: blue }
            svg|circle.dot { color: red }
            p:hover, p:visited { color: purple }
            :root { line-height: 2 }
            """)
        XCTAssertEqual(result.style("note").color, color(1, 0, 0), "epub|type~=footnote matches")
        XCTAssertEqual(result.style("rearnote").color, color(0, 0, 1))
        XCTAssertEqual(result.style("p1").textAlign, .right)
        XCTAssertEqual(result.style("p2").textAlign, .start)
        XCTAssertEqual(result.style("p1").fontWeight, 400, "Ids and classes are case-sensitive")
        XCTAssertEqual(result.style("d1").textAlign, .center)
        XCTAssertEqual(result.style("p3").fontWeight, 700)
        XCTAssertEqual(result.style("p1").fontWeight, 400)
        XCTAssertTrue(result.style("p2").isItalic)
        XCTAssertEqual(result.style("p4").textIndent, .points(1))
        XCTAssertEqual(result.style("p1").textTransform, .uppercase)
        XCTAssertEqual(result.style("p3").textTransform, .none)
        XCTAssertEqual(["li1", "li2", "li3", "li4", "li5"].map { result.style($0).color }, [color(0, 128 / 255, 0), nil, color(0, 128 / 255, 0), nil, color(0, 128 / 255, 0)])
        XCTAssertEqual(result.style("li4").fontWeight, 900)
        XCTAssertEqual(result.style("li1").textDecoration, .underline)
        XCTAssertEqual(result.style("li4").textAlign, .right)
        XCTAssertTrue(result.style("li5").isItalic)
        XCTAssertFalse(result.style("li3").isItalic, ":where() has no specificity")
        XCTAssertEqual(result.style("empty").color, color(0, 0, 1))
        XCTAssertNil(result.style("whitespace").color)
        XCTAssertEqual(result.style("circle").color, color(1, 0, 0))
        XCTAssertNotEqual(result.style("p2").color, color(128 / 255, 0, 128 / 255), "Dynamic pseudo-classes never match")
        XCTAssertEqual(result.styles[result.document.root.order]!.lineHeight, .multiple(2))
    }

    func testDefaultNamespaceAndHTMLCaseInsensitivity() throws {
        let result = try styled("""
            <p id="p">p</p><svg xmlns="http://www.w3.org/2000/svg"><text id="svgtext" class="c">t</text></svg>
            """, css: """
            @namespace url(http://www.w3.org/1999/xhtml);
            .c, P { color: red }
            """)
        XCTAssertEqual(result.style("p").color, color(1, 0, 0), "HTML type selectors are case-insensitive")
        XCTAssertNil(result.style("svgtext").color, "A default namespace restricts selectors without a type")
    }

    func testMediaRulesFollowAppearance() throws {
        let body = #"<p id="p">x</p><p id="q">y</p>"#
        let css = """
            p { text-align: left }
            @media (prefers-color-scheme: dark) { p { text-align: right } }
            @media print { p { text-align: center } }
            @media amzn-kf8 { #q { font-weight: bold } }
            """
        XCTAssertEqual(try styled(body, css: css).style("p").textAlign, .left)
        XCTAssertEqual(try styled(body, css: css, typography: .init(fontSize: 16, isDark: true)).style("p").textAlign, .right)
        XCTAssertEqual(try styled(body, css: css).style("q").fontWeight, 400)
    }

    func testPresentationalHints() throws {
        let result = try styled("""
            <p id="p" align="center">p</p><img id="img" src="x.png" width="120" height="50%" align="left" alt=""/>
            <table id="table" border="2" cellspacing="5" cellpadding="3" bgcolor="ff0000"><tr><td id="td" valign="top" nowrap="">t</td></tr></table>
            <font id="font" color="blue" face="Georgia, 'Times'" size="+2">f</font><p id="evil" align="center; color: red">e</p>
            <div id="override" align="right">o</div>
            """, css: "div { text-align: left }")
        XCTAssertEqual(result.style("p").textAlign, .center)
        XCTAssertEqual(result.style("img").width, .points(120))
        XCTAssertEqual(result.style("img").height, .percent(50))
        XCTAssertEqual(result.style("img").float, .left)
        XCTAssertEqual(result.style("table").border.top, .init(width: 2, style: .outset, color: nil))
        XCTAssertEqual(result.style("table").borderSpacing, CGSize(width: 5, height: 5))
        XCTAssertEqual(result.style("table").backgroundColor, color(1, 0, 0))
        XCTAssertEqual(result.style("td").verticalAlign, .top)
        XCTAssertEqual(result.style("td").whiteSpace, .nowrap)
        XCTAssertEqual(result.style("td").padding.left, .points(3))
        XCTAssertEqual(result.style("td").border.left, .init(width: 1, style: .inset, color: nil))
        XCTAssertEqual(result.style("font").color, color(0, 0, 1))
        XCTAssertEqual(result.style("font").fontFamilies, ["georgia", "times"])
        XCTAssertEqual(result.style("font").fontSize, 24)
        XCTAssertEqual(result.style("evil").textAlign, .start)
        XCTAssertNil(result.style("evil").color)
        XCTAssertEqual(result.style("override").textAlign, .left, "Author rules beat presentational hints")
    }

    func testSourcesLinksImportsAndRemoteReferences() throws {
        let section = StyleTestSupport.xhtml(body: #"<p id="p">x</p><p id="q" class="q">y</p>"#, head: """
            <link rel="stylesheet" href="css/main.css"/>
            <link rel="stylesheet" href="https://example.com/remote.css"/>
            <link rel="stylesheet" href="//cdn.example.com/x.css"/>
            <link rel="alternate stylesheet" href="css/alternate.css"/>
            <link rel="stylesheet" href="css/print.css" media="print"/>
            <link rel="stylesheet" href="css/missing.css"/>
            <link rel="StyleSheet" type="text/x-oeb1-css" href="css/oeb.css"/>
            <style type="text/plain">p { color: red }</style>
            <style media="screen">p { font-weight: 700 }</style>
            """)
        let files: [String: String] = [
            "css/main.css": """
                @import "base.css";
                @import url("https://fonts.example.com/css");
                @font-face { font-family: "Remote"; src: url(https://example.com/f.woff2) format("woff2"), url("../fonts/f.ttf") format("truetype"), url(f.eot?#iefix) format("embedded-opentype") }
                p { text-align: center }
                """,
            "css/base.css": "p { text-align: right; text-indent: 2px } @import url(ignored.css);",
            "css/alternate.css": "p { color: red }",
            "css/print.css": "p { color: red }",
            "css/oeb.css": "p { word-spacing: 3px }",
        ]
        let result = try StyleTestSupport.styled(section: section, files: files.mapValues { Data($0.utf8) },
                                                 typography: NativeTypography(fontSize: 16))
        XCTAssertEqual(result.style("p").textAlign, .center, "The importing sheet follows its import")
        XCTAssertEqual(result.style("p").textIndent, .points(2))
        XCTAssertNil(result.style("p").color)
        XCTAssertEqual(result.style("p").fontWeight, 700)
        XCTAssertEqual(result.style("p").wordSpacing, 3, "EPUB 2's OEB CSS type is CSS")
        XCTAssertEqual(result.report.remoteResourcesRefused, 4)
        XCTAssertEqual(result.report.unreadableResources, 1)
        XCTAssertEqual(result.sheets.flatMap(\.fontFaces), [CSSFontFace(family: "remote", sources: ["OPS/fonts/f.ttf"])])
        XCTAssertFalse(result.report.stylesTruncated)
    }

    func testImportDepthCyclesAndBounds() throws {
        var files: [String: String] = [:]
        for level in 0..<8 { files["css/\(level).css"] = "@import \"\(level + 1).css\"; .l\(level) { color: red }" }
        files["css/cycle.css"] = "@import \"cycle.css\"; p { text-align: center }"
        let rules = (0..<(CSSStyleSheet.maximumRules + 10)).map { ".r\($0) { color: red }" }.joined(separator: "\n")
        files["css/many.css"] = rules
        let deep = try styled(#"<p id="p">x</p>"#, head: #"<link rel="stylesheet" href="css/0.css"/>"#, files: files)
        XCTAssertEqual(deep.sheets.count, SectionStyles.maximumImportDepth + 1)
        XCTAssertTrue(deep.report.stylesTruncated)
        let cycle = try styled(#"<p id="p">x</p>"#, head: #"<link rel="stylesheet" href="css/cycle.css"/>"#, files: files)
        XCTAssertEqual(cycle.style("p").textAlign, .center)
        XCTAssertFalse(cycle.report.stylesTruncated)
        let many = try styled(#"<p id="p">x</p>"#, head: #"<link rel="stylesheet" href="css/many.css"/>"#, files: files)
        XCTAssertEqual(many.sheets.map(\.rules.count).reduce(0, +), CSSStyleSheet.maximumRules)
        XCTAssertTrue(many.report.stylesTruncated)
        let large = "p { color: red }/*" + String(repeating: "x", count: SectionStyles.maximumSheetBytes) + "*/ p { color: blue }"
        let big = try styled(#"<p id="p">x</p>"#, head: #"<link rel="stylesheet" href="big.css"/>"#, files: ["big.css": large])
        XCTAssertTrue(big.report.stylesTruncated)
        XCTAssertEqual(big.style("p").color, color(1, 0, 0))
    }

    func testFlexAndGridItemsAreBlockified() throws {
        let result = try styled("""
            <section id="flex"><blockquote id="item">q</blockquote><span id="span">s</span><span id="abs">a</span>
            <div id="grid"><em id="cell">c</em></div></section>
            """, css: """
            #flex { display: flex } #item { display: inline-block } #abs { position: absolute } #grid { display: inline-grid }
            """)
        XCTAssertEqual(result.style("flex").display, .block)
        XCTAssertTrue(result.style("flex").blockifiesChildren)
        XCTAssertEqual(result.style("item").display, .block)
        XCTAssertEqual(result.style("span").display, .block)
        XCTAssertEqual(result.style("abs").display, .inline, "Out-of-flow boxes keep their display")
        XCTAssertEqual(result.style("grid").display, .block, "An inline grid inside a flex container is blockified too")
        XCTAssertEqual(result.style("cell").display, .block)
        XCTAssertFalse(result.style("item").blockifiesChildren)
    }

    func testAbsoluteSizeKeywordsMatchWebKit() throws {
        let result = try styled(#"<p id="small">s</p><p id="large">l</p><p id="xx">x</p>"#,
                                css: "#small { font-size: small } #large { font-size: large } #xx { font-size: xx-small }",
                                typography: NativeTypography(fontSize: 32))
        XCTAssertEqual(result.style("small").fontSize, 26)
        XCTAssertEqual(result.style("large").fontSize, 36)
        XCTAssertEqual(result.style("xx").fontSize, 18)
    }

    func testRootFontSizeIsTheBasisForRem() throws {
        let result = try styled(#"<p id="p">x</p>"#, css: "html { font-size: 10px } p { font-size: 2rem; margin-top: 1rem }",
                                typography: NativeTypography(fontSize: 24))
        XCTAssertEqual(result.style("p").fontSize, 30)
        XCTAssertEqual(result.style("p").margin.top, .points(15))
    }

    /// A Standard Ebooks-sized cascade over a long chapter: the rule index keeps this fast.
    func testPerformanceOfALargeDocument() throws {
        var css = "@namespace epub \"http://www.idpf.org/2007/ops\";\n"
        for i in 0..<3000 {
            switch i % 6 {
            case 0: css += ".c\(i) { margin-left: \(i % 7)em }\n"
            case 1: css += "section.s\(i % 50) > p.c\(i) + p { text-indent: 0 }\n"
            case 2: css += "#id\(i) span { font-weight: bold }\n"
            case 3: css += "[epub|type~=\"t\(i)\"] { font-style: italic }\n"
            case 4: css += "p:nth-child(\(i % 9)n+1) em.c\(i) { color: red }\n"
            default: css += "body section.s\(i % 50) p > em { text-decoration: underline }\n"
            }
        }
        css += "p { margin: 0; text-indent: 1em } h2 + p, hr + p { text-indent: 0 } i > i, em > i { font-style: normal }"
        var body = ""
        for s in 0..<800 {
            body += "<section class=\"s\(s % 50)\" epub:type=\"t\(s * 6 + 3)\"><h2 id=\"id\(s)\">Heading</h2>"
            for p in 0..<4 { body += "<p class=\"c\(s * 6 + p)\">Text <em class=\"c\(s * 6 + 4)\">em</em> <span>s</span></p>" }
            body += "</section>"
        }
        let section = StyleTestSupport.xhtml(body: body, css: css)
        let document = try ContentDocument.parse(Data(section.utf8), path: "OPS/one.xhtml")
        let book = try StyleTestSupport.publication(section: section)
        var report = SectionReport()
        let sheets = SectionStyles.load(for: document, publication: book, report: &report)
        XCTAssertEqual(sheets[0].rules.count, 3003)
        let elements = document.nodes.filter(\.isElement).count
        XCTAssertGreaterThan(elements, 10_000)
        let start = Date()
        let resolver = StyleResolver(document: document, stylesheets: sheets, typography: NativeTypography())
        let styles = StyleTestSupport.styleAll(document, resolver)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(styles.count, elements)
        // Release builds take well under 100 ms; debug builds are several times slower.
        XCTAssertLessThan(elapsed, 3, "Styling \(elements) elements took \(elapsed) s")
        print("Styled \(elements) elements against \(sheets[0].rules.count) rules in \(Int(elapsed * 1000)) ms")
    }

    func testConcurrentResolution() throws {
        let result = try styled(#"<div id="d"><p id="p" class="x">x</p></div>"#, css: ".x { color: red }")
        let resolver = result.resolver
        let node = result.document.element(id: "p")!
        let parent = result.style("d")
        let colors = Mutex<[ComputedStyle.Color?]>([])
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let style = resolver.style(for: node, parent: parent)
            colors.withLock { $0.append(style.color) }
        }
        XCTAssertEqual(colors.withLock { $0 }, Array(repeating: color(1, 0, 0), count: 64))
    }

    func testCaptionSideIsParsedAndInherited() throws {
        let styled = try StyleTestSupport.styled(
            "<table id='t'><caption id='c'>Caption</caption><tr><td>1</td></tr></table><table id='u'><caption id='d'>D</caption></table>",
            css: "#t { caption-side: bottom } #d { caption-side: nonsense }")
        XCTAssertEqual(styled.style("t").captionSide, .bottom)
        XCTAssertEqual(styled.style("c").captionSide, .bottom, "inherited")
        XCTAssertEqual(styled.style("d").captionSide, .top, "an invalid value is dropped")
    }
}
