@testable import EPUBViewing
import XCTest

/// HTML §15 "Rendering": presentational attributes as author-level hints of zero specificity,
/// and the user-agent stylesheet's defaults for the elements books use.
final class CSSCascadeHintCoverageTests: XCTestCase {
    private typealias Border = ComputedStyle.Border
    private let red = CSSCascadeSupport.color(1, 0, 0), blue = CSSCascadeSupport.color(0, 0, 1)

    private func styled(_ body: String, css: String = "", typography: NativeTypography = NativeTypography(fontSize: 16)) throws -> StyledDocument {
        try CSSCascadeSupport.styled(body, css: css, typography: typography)
    }

    private func points(_ length: ComputedStyle.Length, file: StaticString = #filePath, line: UInt = #line) -> CGFloat {
        CSSCascadeSupport.points(length, file: file, line: line)
    }

    // MARK: Presentational hints

    func testAlignOnBlocksCellsAndTables() throws {
        let result = try styled("""
            <p id="c" align="center">a</p><p id="l" align="LEFT">b</p><p id="r" align="right">c</p><p id="j" align="justify">d</p>
            <p id="m" align="middle">e</p><p id="sp" align=" Center ">f</p><p id="bad" align="bogus">g</p><h2 id="h" align="right">h</h2>
            <div id="d" align="center"><p id="dp">i</p></div><p>j<span id="span" align="center">k</span></p>
            <table id="tl" align="left"><tr><td>l</td></tr></table><table id="tr" align="RIGHT"><tr><td>m</td></tr></table>
            <table id="tc" align="center"><caption id="cap" align="left">n</caption><thead id="thead" align="center"><tr><th id="in-head">o</th></tr></thead>
            <tbody><tr id="row" align="right"><td id="cell" align="left">p</td><td id="plain">q</td><th id="head">r</th></tr></tbody></table>
            """)
        XCTAssertEqual(["c", "l", "r", "j", "m", "sp", "bad", "h"].map { result.style($0).textAlign }, [.center, .left, .right, .justify, .center, .center, .start, .right])
        XCTAssertEqual(result.style("dp").textAlign, .center, "A div's alignment is inherited")
        XCTAssertEqual(result.style("span").textAlign, .start, "align means nothing on a span")
        XCTAssertEqual(result.style("tl").float, .left)
        XCTAssertEqual(result.style("tr").float, .right)
        XCTAssertEqual(result.style("tc").float, ComputedStyle.Float.none)
        XCTAssertEqual([result.style("tc").margin.left, result.style("tc").margin.right], [.auto, .auto])
        XCTAssertEqual(result.style("cap").textAlign, .left)
        XCTAssertEqual(result.style("thead").textAlign, .center)
        XCTAssertEqual(result.style("row").textAlign, .right)
        XCTAssertEqual(result.style("cell").textAlign, .left)
        XCTAssertEqual(result.style("plain").textAlign, .right, "A cell inherits its row's alignment")
        XCTAssertEqual(result.style("head").textAlign, .center, "…but a th has the user-agent's own")
    }

    func testAlignOnImagesAndRules() throws {
        let aligns: [(String, ComputedStyle.Float, ComputedStyle.VerticalAlign)] = [
            ("left", .left, .baseline), ("RIGHT", .right, .baseline), ("top", .none, .top), ("middle", .none, .middle), ("absmiddle", .none, .middle),
            ("center", .none, .middle), ("bottom", .none, .baseline), ("baseline", .none, .baseline), ("texttop", .none, .textTop), ("bogus", .none, .baseline),
        ]
        let images = aligns.enumerated().map { "<img id=\"i\($0.offset)\" src=\"x.png\" alt=\"\" align=\"\($0.element.0)\"/>" }.joined()
        let result = try styled("""
            <p>\(images)</p><hr id="left" align="left" width="50%"/><hr id="right" align="right"/><hr id="center" align="center"/><hr id="plain"/>
            """)
        for (index, item) in aligns.enumerated() {
            XCTAssertEqual(result.style("i\(index)").float, item.1, item.0)
            XCTAssertEqual(result.style("i\(index)").verticalAlign, item.2, item.0)
        }
        XCTAssertEqual([result.style("left").margin.left, result.style("left").margin.right], [.points(0), .auto])
        XCTAssertEqual(result.style("left").width, .percent(50))
        XCTAssertEqual([result.style("right").margin.left, result.style("right").margin.right], [.auto, .points(0)])
        XCTAssertEqual([result.style("center").margin.left, result.style("center").margin.right], [.auto, .auto])
        XCTAssertEqual([result.style("plain").margin.left, result.style("plain").margin.right], [.auto, .auto], "A rule is centred by default")
    }

    /// HTML's rules for parsing dimension values: leading digits with an optional fraction, then
    /// `%` for a percentage; anything else after the number is ignored, and no number is no hint.
    func testDimensionAttributesParseNumbersPercentagesAndJunk() throws {
        let widths: [(String, ComputedStyle.Length)] = [
            ("12.5", .points(12.5)), ("50%", .percent(50)), (" 40px ", .points(40)), ("junk", .auto), ("-5", .auto), ("1e3", .points(1)), ("", .auto),
            ("99999999", .points(StyleLimits.extent.upperBound)), (".5", .points(0.5)), ("0", .points(0)), ("30.5%", .percent(30.5)), ("%", .auto),
        ]
        let images = widths.enumerated().map { "<img id=\"w\($0.offset)\" src=\"x.png\" alt=\"\" width=\"\($0.element.0)\"/>" }.joined()
        let result = try styled("""
            <p>\(images)<img id="both" src="x.png" alt="" width="30" height="25%"/></p><p id="p" width="100" height="50">x</p>
            <table id="table" width="80%" height="100"><colgroup><col id="col" width="20%"/></colgroup><tr id="row" height="12"><td id="cell" width="30%" height="20">y</td>
            <td id="em" width="1.5em">z</td></tr></table>
            <svg xmlns="http://www.w3.org/2000/svg" id="svg" width="120" height="60px"><rect width="1" height="1"/></svg>
            <svg xmlns="http://www.w3.org/2000/svg" id="svg-percent" width="50%" height="100%"><rect width="1" height="1"/></svg>
            <svg xmlns="http://www.w3.org/2000/svg" id="svg-css" width="120" style="width: 30px"><rect width="1" height="1"/></svg>
            """)
        for (index, item) in widths.enumerated() { XCTAssertEqual(result.style("w\(index)").width, item.1, "width=\"\(item.0)\"") }
        XCTAssertEqual([result.style("both").width, result.style("both").height], [.points(30), .percent(25)])
        XCTAssertEqual([result.style("p").width, result.style("p").height], [.auto, .auto], "width and height mean nothing on a paragraph")
        XCTAssertEqual([result.style("table").width, result.style("table").height], [.percent(80), .points(100)])
        XCTAssertEqual(result.style("col").width, .percent(20))
        XCTAssertEqual(result.style("row").height, .points(12))
        XCTAssertEqual([result.style("cell").width, result.style("cell").height], [.percent(30), .points(20)])
        XCTAssertEqual(result.style("em").width, .points(1.5), "HTML dimensions have no units: what follows the number is ignored")
        XCTAssertEqual([result.style("svg").width, result.style("svg").height], [.points(120), .points(60)])
        XCTAssertEqual([result.style("svg-percent").width, result.style("svg-percent").height], [.percent(50), .percent(100)])
        XCTAssertEqual(result.style("svg-css").width, .points(30), "A style attribute beats the size attribute")
    }

    /// HTML §15.3.8: "The table element's width attribute maps to the dimension property
    /// (ignoring zero) 'width'", and likewise the width and height of `td` and `th`.
    func testZeroWidthAndHeightOnTablesAndCellsAreIgnored() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/121")
        let result = try styled(#"<table id="table" width="0"><tr><td id="cell" width="0" height="0">x</td><th id="head" width="0%">y</th></tr></table>"#)
        XCTAssertEqual(result.style("table").width, .auto, "<table width=\"0\">")
        XCTAssertEqual(result.style("cell").width, .auto, "<td width=\"0\">")
        XCTAssertEqual(result.style("cell").height, .auto, "<td height=\"0\">")
        XCTAssertEqual(result.style("head").width, .auto, "<th width=\"0%\">")
    }

    func testTableBorderCellpaddingAndCellspacing() throws {
        let result = try styled("""
            <table id="t1" border="" cellpadding="4" cellspacing="0"><tbody><tr><td id="c1">a</td><th id="h1">b</th></tr></tbody></table>
            <table id="t2" border="3"><tr><td id="c2">c</td></tr></table><table id="t3" border="0"><tr><td id="c3">d</td></tr></table>
            <table id="t4" border="junk"><tr><td id="c4">e</td></tr></table><table id="t5" border="999"><tr><td id="c5">f</td></tr></table>
            <table id="t6" cellspacing="5%" cellpadding="5%"><tr><td id="c6">g</td></tr></table>
            <table id="t7" cellpadding="7" border="1"><tr><td id="outer">h<table id="inner"><tr><td id="inner-cell">i</td></tr></table></td></tr></table>
            <table id="t8" border="1" cellpadding="6" cellspacing="9"><tr><td id="c8">j</td></tr></table><table id="t9"><tr><td id="c9">k</td></tr></table>
            """, css: "#c8 { padding: 9px; border: 0 } #t8 { border-spacing: 1px }")
        XCTAssertEqual(result.style("t1").border, .init(Border(width: 1, style: .outset, color: nil)), "An empty border attribute is 1px")
        XCTAssertEqual(result.style("t1").borderSpacing, .zero)
        for id in ["c1", "h1"] {
            XCTAssertEqual(result.style(id).padding, .init(.points(4)), id)
            XCTAssertEqual(result.style(id).border, .init(Border(width: 1, style: .inset, color: nil)), id)
        }
        XCTAssertEqual(result.style("t2").border.top, Border(width: 3, style: .outset, color: nil))
        XCTAssertEqual(result.style("c2").border.top, Border(width: 1, style: .inset, color: nil), "Cells are ruled 1px whatever the table's width")
        XCTAssertFalse(result.style("t3").border.top.isVisible)
        XCTAssertFalse(result.style("c3").border.top.isVisible)
        XCTAssertEqual(result.style("t4").border.top.width, 1, "An unparsable border is 1px")
        XCTAssertTrue(result.style("c4").border.top.isVisible)
        XCTAssertEqual(result.style("t5").border.top.width, StyleLimits.borderWidth.upperBound)
        XCTAssertEqual(result.style("t6").borderSpacing, CGSize(width: 2, height: 2), "cellspacing takes pixels only")
        XCTAssertEqual(result.style("c6").padding, .init(.points(1)))
        XCTAssertEqual(result.style("outer").padding, .init(.points(7)))
        XCTAssertFalse(result.style("inner").border.top.isVisible)
        XCTAssertEqual(result.style("inner-cell").padding, .init(.points(1)), "A nested table's cells follow their own table")
        XCTAssertFalse(result.style("inner-cell").border.top.isVisible)
        XCTAssertEqual(result.style("c8").padding, .init(.points(9)), "Author rules beat cellpadding and border")
        XCTAssertFalse(result.style("c8").border.top.isVisible)
        XCTAssertEqual(result.style("t8").borderSpacing, CGSize(width: 1, height: 1))
        XCTAssertEqual(result.style("c9").padding, .init(.points(1)))
        XCTAssertFalse(result.style("t9").border.top.isVisible)
    }

    func testBgcolorTextAndFontColorTakeCSSColorsAndBareHex() throws {
        let section = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body id="body" bgcolor="#eeeeee" text="navy">
            <table id="table" bgcolor="FFFF00"><tr id="row" bgcolor="#00ff00"><td id="named" bgcolor=" Red ">a</td><td id="bare" bgcolor="ff0000">b</td>
            <td id="junk" bgcolor="nocolor">c</td><td id="inject" bgcolor="red; color: blue">d</td><td id="none">e</td></tr></table>
            <p id="p" bgcolor="red" text="red">f <font id="font" color="#abc">g</font> <font id="bad" color="red; font-size: 99px" size="3">h</font></p>
            </body></html>
            """
        let result = try StyleTestSupport.styled(section: section, files: [:], typography: NativeTypography(fontSize: 16))
        XCTAssertEqual(result.style("body").backgroundColor, CSSCascadeSupport.hex(0xEEEEEE))
        XCTAssertEqual(result.style("body").color, CSSCascadeSupport.hex(0x000080))
        XCTAssertEqual(result.style("table").backgroundColor, CSSCascadeSupport.hex(0xFFFF00))
        XCTAssertEqual(result.style("row").backgroundColor, CSSCascadeSupport.hex(0x00FF00))
        XCTAssertEqual(result.style("named").backgroundColor, red)
        XCTAssertEqual(result.style("bare").backgroundColor, red, "Six bare hex digits, as old HTML wrote colors")
        XCTAssertNil(result.style("junk").backgroundColor)
        XCTAssertNil(result.style("inject").backgroundColor, "An attribute is one value: it cannot carry a second declaration")
        XCTAssertEqual(result.style("inject").color, CSSCascadeSupport.hex(0x000080))
        XCTAssertNil(result.style("none").backgroundColor, "Backgrounds are not inherited")
        XCTAssertNil(result.style("p").backgroundColor, "bgcolor and text mean nothing on a paragraph")
        XCTAssertEqual(result.style("p").color, CSSCascadeSupport.hex(0x000080))
        XCTAssertEqual(result.style("font").color, CSSCascadeSupport.hex(0xAABBCC))
        XCTAssertEqual(result.style("bad").color, CSSCascadeSupport.hex(0x000080))
        XCTAssertEqual(result.style("bad").fontSize, 16)
    }

    /// HTML §15.3.4: `<font size>` 1–7 is x-small…xxx-large, `+n`/`-n` are relative to 3.
    func testFontElementSizeAndFace() throws {
        let sizes: [(String, CGFloat?)] = [("1", 10), ("2", 13), ("3", 16), ("4", 18), ("5", 24), ("6", 32), ("7", 48), ("+1", 18), ("-1", 13),
                                           ("+10", 48), ("-10", 10), ("0", 10), ("8", 48), (" 5 ", 24), ("junk", nil), ("", nil)]
        let fonts = sizes.enumerated().map { "<font id=\"s\($0.offset)\" size=\"\($0.element.0)\">x</font>" }.joined()
        let result = try styled("""
            <div style="font-size: 20px">\(fonts)<font size="+1">a<font id="nested" size="+1">b</font></font>
            <font id="face" face="Georgia, 'Times New Roman' , serif">c</font><font id="empty" face="">d</font>
            <font id="odd" face="a; color: red">e</font><font id="plain">f</font></div>
            """, css: "div { font-family: Palatino }")
        for (index, item) in sizes.enumerated() { XCTAssertEqual(result.style("s\(index)").fontSize, item.1 ?? 20, "size=\"\(item.0)\"") }
        XCTAssertEqual(result.style("nested").fontSize, 18, "A relative size is relative to 3, not to the parent font")
        XCTAssertEqual(result.style("face").fontFamilies, ["georgia", "times new roman", "serif"])
        XCTAssertEqual(result.style("empty").fontFamilies, ["palatino"])
        XCTAssertEqual(result.style("odd").fontFamilies.count, 1)
        XCTAssertNil(result.style("odd").color)
        XCTAssertEqual(result.style("plain").display, .inline)
        XCTAssertEqual(result.style("plain").fontSize, 20)
    }

    /// A `Character` holds a quote, comma or backslash together with a combining mark after it or
    /// a prepended mark before it. Read that way the quote stayed in the name the hint quotes, so
    /// the declaration was no font list, and the comma parted nothing
    /// (https://github.com/vocaro/EPUBLib/issues/203).
    func testAFontFaceIsReadWhateverMarkStandsBesideAQuoteCommaOrBackslash() throws {
        let result = try styled("""
            <div><font id="quote" face="&quot;&#x301;x&quot;, Georgia">a</font><font id="apostrophe" face="'&#x308;x', Georgia">b</font>
            <font id="comma" face="Arial,&#x301;x, Georgia">c</font><font id="backslash" face="x&#x600;\\, Georgia">d</font>
            <font id="prepended" face="x&#x600;&quot;, Georgia">e</font></div>
            """, css: "div { font-family: Palatino }")
        func families(_ id: String) -> [[String]] { result.style(id).fontFamilies.map { $0.unicodeScalars.map { String($0.value, radix: 16) } } }
        func scalars(_ names: String...) -> [[String]] { names.map { $0.unicodeScalars.map { String($0.value, radix: 16) } } }
        XCTAssertEqual(families("quote"), scalars("\u{301}x", "georgia"))
        XCTAssertEqual(families("apostrophe"), scalars("\u{308}x", "georgia"))
        XCTAssertEqual(families("comma"), scalars("arial", "\u{301}x", "georgia"))
        // A backslash left before a combining mark only escapes the mark, and the name is the
        // same. Left after a prepended mark it escapes the quote that closes the name.
        XCTAssertEqual(families("backslash"), scalars("x\u{600}", "georgia"))
        XCTAssertEqual(families("prepended"), scalars("x\u{600}", "georgia"))
    }

    func testHintsRankBelowEveryAuthorRuleAndAboveTheUserAgentSheet() throws {
        let result = try styled("""
            <table><tr><th id="ua" align="left">a</th><td id="bg" bgcolor="red">b</td></tr></table>
            <p id="where" class="w" align="center">c</p><p id="inline" align="center" style="text-align: right">d</p>
            <p id="invalid" align="center" style="text-align: bogus">e</p><p><img id="img" src="x.png" width="100" height="50" alt=""/></p>
            <table id="table" border="1"><tr><td id="cell">f</td></tr></table><p id="important" align="center" class="imp">g</p>
            <font id="font" size="7" color="red" face="Georgia">h</font><p id="universal" align="right">i</p>
            """, css: """
            :where(.w) { text-align: justify } img { width: auto } td { background: none } #table { border: 0 }
            .imp { text-align: left !important } font { font: 12px serif; color: inherit } * { letter-spacing: 1px } :where(#universal) { text-align: inherit }
            """)
        XCTAssertEqual(result.style("ua").textAlign, .left, "A hint beats the user-agent's th { text-align: center }")
        XCTAssertEqual(result.style("where").textAlign, .justify, "An author rule of zero specificity still follows the hints")
        XCTAssertEqual(result.style("inline").textAlign, .right)
        XCTAssertEqual(result.style("invalid").textAlign, .center, "An invalid style attribute leaves the hint")
        XCTAssertEqual(result.style("img").width, .auto)
        XCTAssertEqual(result.style("img").height, .points(50))
        XCTAssertNil(result.style("bg").backgroundColor)
        XCTAssertFalse(result.style("table").border.top.isVisible)
        XCTAssertTrue(result.style("cell").border.top.isVisible, "The table's attribute still rules its cells")
        XCTAssertEqual(result.style("important").textAlign, .left)
        XCTAssertEqual(result.style("font").fontSize, 12)
        XCTAssertEqual(result.style("font").fontFamilies, ["serif"])
        XCTAssertNil(result.style("font").color)
        XCTAssertEqual(result.style("universal").textAlign, .start, "inherit in an author rule replaces the hint with the parent's value")
    }

    /// HTML §15.3.3: `br[clear=left i] { clear: left; }`, `br[clear=right i] { clear: right; }`,
    /// `br[clear=all i], br[clear=both i] { clear: both; }`.
    func testBrClearAttributeClearsFloats() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/121")
        let result = try styled(#"<p>a<br id="left" clear="left"/>b<br id="right" clear="RIGHT"/>c<br id="all" clear="all"/>d<br id="both" clear="both"/>e<br id="plain"/></p>"#)
        XCTAssertEqual(result.style("plain").clear, ComputedStyle.Clear.none)
        XCTAssertEqual(result.style("left").clear, .left, "<br clear=\"left\">")
        XCTAssertEqual(result.style("right").clear, .right, "<br clear=\"RIGHT\">")
        XCTAssertEqual(result.style("all").clear, .both, "<br clear=\"all\">")
        XCTAssertEqual(result.style("both").clear, .both, "<br clear=\"both\">")
    }

    /// SVG 1.1 §5.1.2: an `svg` element's `width` and `height` are `<length>`s with CSS units (SVG 2
    /// maps them to the CSS properties), so `2in` is 192px and `210mm` an A4 page's width, as
    /// `ImageSizing.length` reads them.
    func testSVGSizeAttributesHonourCSSUnits() throws {
        func svg(_ id: String, _ width: String, _ height: String) -> String {
            "<svg xmlns=\"http://www.w3.org/2000/svg\" id=\"\(id)\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 2 1\"><rect width=\"2\" height=\"1\"/></svg>"
        }
        let result = try styled(svg("in", "2in", "1in") + svg("mm", "210mm", "297mm") + svg("em", "10em", "5em") + svg("pt", "72pt", "36pt") + svg("cm", "2.54cm", "1.27cm"))
        let expected: [(String, CGFloat, CGFloat)] = [("in", 192, 96), ("mm", 210 * 96 / 25.4, 297 * 96 / 25.4), ("em", 160, 80), ("pt", 96, 48), ("cm", 96, 48)]
        for (id, width, height) in expected {
            let style = result.style(id)
            guard case .points(let w) = style.width, case .points(let h) = style.height else { XCTFail("\(id): \(style.width) × \(style.height)"); continue }
            XCTAssertEqual(w, width, accuracy: 0.01, "width of #\(id)")
            XCTAssertEqual(h, height, accuracy: 0.01, "height of #\(id)")
        }
        // The same drawing through the builder's own factory, when the SVG renderer is available.
        let fixture = try RichFixture(svg("drawing", "2in", "1in"))
        guard let attachment = RichFixture.attachments(in: fixture.svg("drawing")).first as? ReaderImageAttachment else { return }
        let shown = attachment.sizing.size(lineWidth: 600, viewport: CGSize(width: 600, height: 800), heightLimit: 800)
        XCTAssertEqual(shown.width, 192, accuracy: 0.01, "A 2in × 1in drawing is shown 192 × 96 points on a 600-point line")
        XCTAssertEqual(shown.height, 96, accuracy: 0.01)
    }

    func testSVGSizeUnitsUseTheElementFontAndYieldToAuthorCSS() throws {
        let result = try styled("""
            <svg xmlns="http://www.w3.org/2000/svg" id="font" width="10em" height="5em" style="font-size:20px"><rect width="1" height="1"/></svg>
            <svg xmlns="http://www.w3.org/2000/svg" id="rule" width="2in" height="1in"><rect width="1" height="1"/></svg>
            <svg xmlns="http://www.w3.org/2000/svg" id="inline" width="2in" height="1in" style="width:80px;height:40px"><rect width="1" height="1"/></svg>
            <svg xmlns="http://www.w3.org/2000/svg" id="bad" width="2in nonsense" height="1in; width:1px"><rect width="1" height="1"/></svg>
            """, css: "#rule { width: 120px; height: 60px }")
        XCTAssertEqual(result.style("font").width, .points(200))
        XCTAssertEqual(result.style("font").height, .points(100))
        XCTAssertEqual(result.style("rule").width, .points(120))
        XCTAssertEqual(result.style("rule").height, .points(60))
        XCTAssertEqual(result.style("inline").width, .points(80))
        XCTAssertEqual(result.style("inline").height, .points(40))
        XCTAssertEqual(result.style("bad").width, .auto)
        XCTAssertEqual(result.style("bad").height, .auto)
    }

    func testHiddenAttributeHidesUntilAnAuthorRuleShows() throws {
        let result = try styled("""
            <p id="h" hidden="">a</p><p>b<span id="s" hidden="hidden">c</span></p><div id="d" hidden=""><p id="child">d</p></div>
            <p id="shown" hidden="" class="show">e</p><p id="inline" hidden="" style="display: inline">f</p><p id="plain">g</p>
            """, css: ".show { display: block }")
        XCTAssertEqual(result.style("h").display, ComputedStyle.Display.none)
        XCTAssertEqual(result.style("s").display, ComputedStyle.Display.none)
        XCTAssertEqual(result.style("d").display, ComputedStyle.Display.none)
        XCTAssertEqual(result.style("child").display, .block, "display is not inherited; the hidden subtree is simply not built")
        XCTAssertEqual(result.style("shown").display, .block, "HTML: hidden is a user-agent rule, which any author display overrides")
        XCTAssertEqual(result.style("inline").display, .inline)
        XCTAssertEqual(result.style("plain").display, .block)
    }

    // MARK: The user-agent stylesheet

    func testUserAgentDefaultsForHeadingsAndFlowContent() throws {
        let result = try styled("""
            <h1 id="h1">a</h1><h2 id="h2">a</h2><h3 id="h3">a</h3><h4 id="h4">a</h4><h5 id="h5">a</h5><h6 id="h6">a</h6>
            <p id="p">p</p><blockquote id="blockquote">b</blockquote><pre id="pre">p</pre><address id="address">a</address>
            <dl id="dl"><dt id="dt">t</dt><dd id="dd">d</dd></dl><figure id="figure"><figcaption id="figcaption">c</figcaption></figure><hr id="hr"/>
            <section id="section"><article id="article"><aside id="aside">a</aside><nav id="nav">n</nav><header id="header">h</header>
            <footer id="footer">f</footer><main id="main">m</main><hgroup id="hgroup">g</hgroup></article></section>
            <details id="details"><summary id="summary">s</summary>d</details><div id="div">d</div><center id="center"><p id="in-center">c</p></center>
            """, typography: NativeTypography(fontSize: 20))
        let headings: [(String, CGFloat, CGFloat)] = [("h1", 2, 0.67), ("h2", 1.5, 0.83), ("h3", 1.17, 1), ("h4", 1, 1.33), ("h5", 0.83, 1.67), ("h6", 0.67, 2.33)]
        for (id, size, margin) in headings {
            let style = result.style(id)
            XCTAssertEqual(style.fontSize, 20 * size, accuracy: 0.0001, id)
            XCTAssertEqual(points(style.margin.top), 20 * size * margin, accuracy: 0.0001, "\(id): margins are in the heading's own em")
            XCTAssertEqual(points(style.margin.bottom), 20 * size * margin, accuracy: 0.0001, id)
            XCTAssertEqual(style.fontWeight, 700, id); XCTAssertEqual(style.display, .block, id); XCTAssertEqual(style.breakAfter, .avoid, id)
        }
        XCTAssertEqual(result.style("p").margin, .init(top: .points(20), right: .points(0), bottom: .points(20), left: .points(0)))
        XCTAssertEqual(result.style("blockquote").margin, .init(top: .points(20), right: .points(40), bottom: .points(20), left: .points(40)))
        XCTAssertEqual(result.style("pre").fontFamilies, ["monospace"])
        XCTAssertEqual(result.style("pre").whiteSpace, .pre)
        XCTAssertEqual(result.style("pre").margin.top, .points(20))
        XCTAssertTrue(result.style("address").isItalic)
        XCTAssertEqual(result.style("dl").margin.top, .points(20))
        XCTAssertEqual(result.style("dd").margin.left, .points(40))
        XCTAssertEqual(result.style("figure").margin, .init(top: .points(20), right: .points(40), bottom: .points(20), left: .points(40)))
        // doc/native-viewer.md, "Paragraph sizing": "Centered figcaption text at 0.9em is an intentional user-agent reader default."
        XCTAssertEqual(result.style("figcaption").textAlign, .center)
        XCTAssertEqual(result.style("figcaption").fontSize, 18, accuracy: 0.0001)
        let rule = result.style("hr")
        XCTAssertEqual(rule.margin, .init(top: .points(10), right: .auto, bottom: .points(10), left: .auto))
        XCTAssertEqual(rule.border, .init(Border(width: 1, style: .inset, color: nil)))
        XCTAssertEqual(rule.color, CSSCascadeSupport.hex(0x808080))
        for id in ["p", "blockquote", "pre", "address", "dl", "dt", "dd", "figure", "figcaption", "hr", "section", "article", "aside", "nav",
                   "header", "footer", "main", "hgroup", "details", "summary", "div", "center"] {
            XCTAssertEqual(result.style(id).display, .block, id)
        }
        for id in ["address", "dt", "section", "article", "aside", "nav", "header", "footer", "main", "hgroup", "details", "summary", "div", "center"] {
            XCTAssertEqual(result.style(id).margin, .init(.points(0)), id)
        }
        XCTAssertEqual(result.style("center").textAlign, .center)
        XCTAssertEqual(result.style("in-center").textAlign, .center)
        let body = try XCTUnwrap(result.document.nodes.first { $0.isElement && $0.name == "body" })
        XCTAssertEqual(result.styles[body.order]?.margin, .init(.points(0)), "The reader, not the book's body, owns the page margins")
        XCTAssertEqual(result.styles[body.order]?.display, .block)
    }

    func testUserAgentDefaultsForPhrasingContent() throws {
        let result = try styled("""
            <p id="p">p <code id="code">c</code><kbd id="kbd">k</kbd><samp id="samp">s</samp><tt id="tt">t</tt><em id="em">e</em><i id="i">i</i>
            <cite id="cite">c</cite><var id="var">v</var><dfn id="dfn">d</dfn><b id="b">b</b><strong id="strong">s</strong><small id="small">s</small>
            <big id="big">b</big><sub id="sub">s</sub><sup id="sup">s</sup><u id="u">u</u><ins id="ins">i</ins><s id="s">s</s><strike id="strike">s</strike>
            <del id="del">d</del><mark id="mark">m</mark><a id="link" href="x.xhtml">l</a><a id="anchor">a</a><q id="q">q</q><abbr id="abbr">a</abbr>
            <span id="span">s</span><time id="time">t</time><bdi id="bdi">b</bdi><nobr id="nobr">n</nobr><ruby id="ruby">r<rt id="rt">t</rt></ruby>
            <font id="font">f</font><br id="br"/><wbr id="wbr"/></p><h1>h<strong id="heading-strong">s</strong></h1>
            """)
        for id in ["code", "kbd", "samp", "tt"] { XCTAssertEqual(result.style(id).fontFamilies, ["monospace"], id) }
        for id in ["em", "i", "cite", "var", "dfn"] { XCTAssertTrue(result.style(id).isItalic, id) }
        for id in ["b", "strong"] { XCTAssertEqual(result.style(id).fontWeight, 700, id) }
        XCTAssertEqual(result.style("heading-strong").fontWeight, 900, "bolder than a heading's bold")
        XCTAssertEqual(result.style("small").fontSize, 16 / 1.2, accuracy: 0.0001)
        XCTAssertEqual(result.style("big").fontSize, 16 * 1.2, accuracy: 0.0001)
        XCTAssertEqual(result.style("sub").verticalAlign, .sub); XCTAssertEqual(result.style("sup").verticalAlign, .super)
        XCTAssertEqual(result.style("sub").fontSize, 16 / 1.2, accuracy: 0.0001); XCTAssertEqual(result.style("sup").fontSize, 16 / 1.2, accuracy: 0.0001)
        for id in ["u", "ins", "link"] { XCTAssertEqual(result.style(id).textDecoration, .underline, id) }
        for id in ["s", "strike", "del"] { XCTAssertEqual(result.style(id).textDecoration, .lineThrough, id) }
        XCTAssertEqual(result.style("mark").backgroundColor, CSSCascadeSupport.color(1, 1, 0))
        XCTAssertEqual(result.style("mark").color, CSSCascadeSupport.color(0, 0, 0))
        XCTAssertEqual(result.style("nobr").whiteSpace, .nowrap)
        XCTAssertEqual(result.style("ruby").display, .ruby); XCTAssertEqual(result.style("rt").display, .rubyText)
        let plain = result.style("span")
        XCTAssertEqual(plain.display, .inline); XCTAssertEqual(plain.fontSize, 16); XCTAssertEqual(plain.fontWeight, 400); XCTAssertFalse(plain.isItalic)
        for id in ["anchor", "abbr", "time", "bdi", "font", "br", "wbr"] { XCTAssertEqual(result.style(id), plain, "\(id) is an unstyled inline") }
        // A `q` is one too, with quotation marks before and after it (HTML §15.3.6).
        var quotation = result.style("q")
        XCTAssertEqual(quotation.generated?.before?.content, [.openQuote])
        XCTAssertEqual(quotation.generated?.after?.content, [.closeQuote])
        quotation.generated = nil
        XCTAssertEqual(quotation, plain)
        for id in ["code", "em", "b", "small", "sup", "u", "mark", "link", "nobr"] { XCTAssertEqual(result.style(id).display, .inline, id) }
    }

    func testUserAgentDefaultsForListsAndTables() throws {
        let result = try styled("""
            <ul id="ul"><li id="li">a<ul id="ul2"><li>b<ul id="ul3"><li id="li3">c</li></ul></li></ul><ol id="ol-in-ul"><li>d</li></ol></li></ul>
            <ol id="ol"><li>e<ul id="ul-in-ol"><li>f</li></ul></li></ol><menu id="menu"><li>g</li></menu><dir id="dir"><li>h</li></dir>
            <table id="table"><caption id="caption">c</caption><colgroup id="colgroup"><col id="col"/></colgroup><thead id="thead"><tr><th id="th">h</th></tr></thead>
            <tbody id="tbody"><tr id="tr"><td id="td">d</td></tr><tr valign="top"><td id="top">t</td><td id="own" valign="bottom">u</td></tr></tbody>
            <tfoot id="tfoot"><tr><td>f</td></tr></tfoot></table>
            """, css: "body { text-indent: 2em; font-weight: 300 }")
        for id in ["ul", "ol", "menu", "dir"] {
            let style = result.style(id)
            XCTAssertEqual(style.display, .block, id)
            XCTAssertEqual([style.margin.top, style.margin.bottom], [.points(16), .points(16)], id)
            XCTAssertGreaterThanOrEqual(points(style.padding.left), 16, "\(id) leaves room for its markers")
        }
        XCTAssertEqual(["ul", "ul2", "ul3", "ol", "ol-in-ul", "ul-in-ol", "menu", "dir"].map { result.style($0).listStyleType },
                       [.disc, .circle, .square, .decimal, .decimal, .circle, .disc, .disc])
        for id in ["ul2", "ul3", "ol-in-ul", "ul-in-ol"] {
            XCTAssertEqual([result.style(id).margin.top, result.style(id).margin.bottom], [.points(0), .points(0)], "\(id): a nested list has no margins")
        }
        XCTAssertEqual(result.style("li").display, .listItem)
        XCTAssertEqual(result.style("li3").listStyleType, .square)
        let displays: [(String, ComputedStyle.Display)] = [("table", .table), ("caption", .tableCaption), ("colgroup", .tableColumnGroup), ("col", .tableColumn),
                                                           ("thead", .tableHeaderGroup), ("tbody", .tableRowGroup), ("tfoot", .tableFooterGroup),
                                                           ("tr", .tableRow), ("th", .tableCell), ("td", .tableCell)]
        for (id, display) in displays { XCTAssertEqual(result.style(id).display, display, id) }
        XCTAssertEqual(result.style("table").borderSpacing, CGSize(width: 2, height: 2))
        XCTAssertFalse(result.style("table").borderCollapse)
        XCTAssertEqual(result.style("td").textIndent, .points(0), "A table does not inherit an indent")
        XCTAssertEqual(result.style("td").fontWeight, 300, "…but does inherit the font")
        XCTAssertEqual(result.style("td").padding, .init(.points(1)))
        XCTAssertEqual(result.style("th").fontWeight, 700); XCTAssertEqual(result.style("th").textAlign, .center)
        XCTAssertEqual(result.style("caption").textAlign, .center)
        for id in ["thead", "tbody", "tfoot", "tr", "td", "th"] { XCTAssertEqual(result.style(id).verticalAlign, .middle, id) }
        XCTAssertEqual(result.style("top").verticalAlign, .top, "A cell takes its row's valign")
        XCTAssertEqual(result.style("own").verticalAlign, .bottom)
    }

    func testMetadataInertAndForeignElements() throws {
        let section = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:m="http://www.w3.org/1998/Math/MathML"><head id="head"><title id="title">T</title>
            <meta id="meta" charset="utf-8"/><link id="link" rel="stylesheet" href="missing.css"/><style id="style">p { color: red }</style>
            <script id="head-script">var x = 1;</script><base id="base" href="."/></head><body>
            <script id="script">var y = 2;</script><template id="template">t</template><datalist id="datalist"><option>o</option></datalist>
            <object id="object"><param id="param" name="n" value="v"/></object><map><area id="area" href="x.xhtml"/></map>
            <dialog id="dialog">closed</dialog><dialog id="open" open="">open</dialog><ruby>x<rp id="rp">(</rp></ruby><noscript id="noscript">n</noscript>
            <p><img id="img" src="x.png" alt=""/><svg xmlns="http://www.w3.org/2000/svg" id="svg"><title id="svg-title">t</title></svg>
            <m:math id="math"><m:mi>x</m:mi></m:math><video id="video" src="v.mp4"/><audio id="audio" src="a.mp3"/><canvas id="canvas"/>
            <iframe id="iframe" src="x.xhtml"/><embed id="embed" src="x.png"/><x-note id="custom">c</x-note>
            <input id="input"/><button id="button">b</button><select id="select"><option>o</option></select><textarea id="textarea">t</textarea></p>
            <m:math id="display-math" display="block"><m:mi>y</m:mi></m:math></body></html>
            """
        let result = try StyleTestSupport.styled(section: section, files: [:], typography: NativeTypography(fontSize: 16))
        for id in ["head", "title", "meta", "link", "style", "head-script", "base", "script", "template", "datalist", "param", "area", "dialog", "rp"] {
            XCTAssertEqual(result.style(id).display, ComputedStyle.Display.none, id)
        }
        XCTAssertEqual(result.style("open").display, .block)
        for id in ["noscript", "img", "svg", "math", "video", "audio", "canvas", "iframe", "embed", "object", "custom"] {
            XCTAssertEqual(result.style(id).display, .inline, id)
        }
        for id in ["input", "button", "select", "textarea"] { XCTAssertEqual(result.style(id).display, .inlineBlock, id) }
        XCTAssertEqual(result.style("display-math").display, .block)
        XCTAssertEqual(result.style("display-math").textAlign, .center)
    }
}
