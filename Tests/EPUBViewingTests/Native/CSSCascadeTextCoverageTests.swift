@testable import EPUBViewing
import XCTest

/// CSS Text, Text Decoration, Lists and Fragmentation: keyword forms, vendor and EPUB aliases,
/// what inherits and what an invalid value leaves behind.
final class CSSCascadeTextCoverageTests: XCTestCase {
    private func styled(_ body: String, css: String = "") throws -> StyledDocument { try CSSCascadeSupport.styled(body, css: css) }

    /// One `<p>` per rule body under a `<div id="parent">` styled by `parent`.
    private func paragraphs(_ bodies: [String], parent: String = "") throws -> [ComputedStyle] {
        let body = "<div id=\"parent\">" + bodies.indices.map { "<p id=\"e\($0)\">x</p>" }.joined() + "</div>"
        let css = "#parent { \(parent) }\n" + bodies.enumerated().map { "#e\($0.offset) { \($0.element) }" }.joined(separator: "\n")
        let result = try styled(body, css: css)
        return bodies.indices.map { result.style("e\($0)") }
    }

    // MARK: Alignment, indentation and spacing

    func testTextAlignKeywordsVendorAliasesAndInvalidValues() throws {
        let valid: [(String, ComputedStyle.TextAlign)] = [
            ("start", .start), ("END", .end), ("left", .left), ("right", .right), ("center", .center), ("justify", .justify),
            ("-webkit-center", .center), ("-moz-center", .center), ("-webkit-left", .left), ("-moz-right", .right), ("justify-all", .justify),
        ]
        for (item, style) in zip(valid, try paragraphs(valid.map { "text-align: \($0.0)" }, parent: "text-align: right")) {
            XCTAssertEqual(style.textAlign, item.1, item.0)
        }
        let invalid = ["middle", "\".\"", "centre", "left right", "5px", "top"]
        for (value, style) in zip(invalid, try paragraphs(invalid.map { "text-align: \($0)" }, parent: "text-align: right")) {
            XCTAssertEqual(style.textAlign, .right, "\(value) is invalid, so the alignment is inherited")
        }
    }

    func testStartAndEndStayRelativeToTheParagraphsDirection() throws {
        let result = try styled("""
            <div dir="rtl"><p id="start" style="text-align: start">a</p><p id="end" style="text-align: end">b</p><p id="plain">c</p>
            <p id="left" style="text-align: left">d</p></div>
            """)
        XCTAssertEqual(result.style("start").textAlign, .start)
        XCTAssertEqual(result.style("start").direction, .rtl)
        XCTAssertEqual(result.style("end").textAlign, .end)
        XCTAssertEqual(result.style("plain").textAlign, .start)
        XCTAssertEqual(result.style("left").textAlign, .left, "A physical side does not follow the direction")
    }

    /// CSS Text 3 §6.1: `match-parent` "behaves the same as inherit (computes to its parent's
    /// computed value) except that an inherited value of start or end is interpreted against the
    /// parent's direction".
    func testMatchParentTakesTheParentsAlignment() throws {
        let result = try styled("""
            <div style="text-align: center"><p id="center">a</p></div><div style="text-align: right"><p id="right">b</p></div>
            <div style="text-align: justify"><p id="justify">c</p></div>
            """, css: "p { text-align: match-parent }")
        XCTAssertEqual(result.style("center").textAlign, .center)
        XCTAssertEqual(result.style("right").textAlign, .right)
        XCTAssertEqual(result.style("justify").textAlign, .justify)
    }

    func testTextIndentIsALengthThatInheritsAsComputedAndResetsInTables() throws {
        let result = try styled("""
            <p id="a">a<span id="small">s</span></p><p id="b">b</p><p id="c">c</p><p id="d">d</p><p id="e">e</p>
            <div id="outer"><table><tr><td id="cell">x</td></tr></table><ul><li id="item">y</li></ul></div>
            """, css: """
            #a { text-indent: -2em; font-size: 20px } #small { font-size: 10px }
            #b { text-indent: 5% } #c { text-indent: 1cm }
            #d { text-indent: 3px; text-indent: hanging } #e { text-indent: 3px; text-indent: 1em 2em }
            #outer { text-indent: 20px }
            """)
        XCTAssertEqual(result.style("a").textIndent, .points(-40))
        XCTAssertEqual(result.style("small").textIndent, .points(-40), "An em indent is inherited as its computed length")
        XCTAssertEqual(result.style("b").textIndent, .percent(5))
        XCTAssertEqual(CSSCascadeSupport.points(result.style("c").textIndent), 96 / 2.54, accuracy: 0.0001)
        XCTAssertEqual(result.style("d").textIndent, .points(3), "A keyword without a length is invalid")
        XCTAssertEqual(result.style("e").textIndent, .points(3), "Two lengths are invalid")
        XCTAssertEqual(result.style("cell").textIndent, .points(0), "HTML's table { text-indent: initial }")
        XCTAssertEqual(result.style("item").textIndent, .points(20))
    }

    func testLineHeightNumbersInheritAsFactorsAndLengthsAsLengths() throws {
        let result = try styled("""
            <p id="number">a<span id="number-child">b</span></p><p id="length">c<span id="length-child">d</span></p>
            <p id="percent">e<span id="percent-child">f</span></p><p id="normal">g</p><p id="zero">h</p>
            <p id="negative">i</p><p id="two">j</p><p id="keyword">k</p>
            """, css: """
            #number { line-height: 1.5; font-size: 30px } #length { line-height: 1.5em; font-size: 30px } #percent { line-height: 150%; font-size: 30px }
            span { font-size: 10px }
            #normal { line-height: NORMAL } #zero { line-height: 0 }
            #negative { line-height: 2; line-height: -1 } #two { line-height: 2; line-height: 1.5 2 } #keyword { line-height: 2; line-height: auto }
            """)
        XCTAssertEqual(result.style("number").lineHeightPoints, 45)
        XCTAssertEqual(result.style("number-child").lineHeight, .multiple(1.5))
        XCTAssertEqual(result.style("number-child").lineHeightPoints, 15, "A number is inherited as the factor")
        XCTAssertEqual(result.style("length").lineHeight, .points(45))
        XCTAssertEqual(result.style("length-child").lineHeight, .points(45), "A length is inherited as computed")
        XCTAssertEqual(result.style("percent").lineHeight, .points(45))
        XCTAssertEqual(result.style("percent-child").lineHeight, .points(45), "A percentage is inherited as computed")
        XCTAssertEqual(result.style("normal").lineHeight, .normal)
        XCTAssertNil(result.style("normal").lineHeightPoints)
        XCTAssertEqual(result.style("zero").lineHeight, .multiple(0))
        for id in ["negative", "two", "keyword"] { XCTAssertEqual(result.style(id).lineHeight, .multiple(2), id) }
    }

    func testLetterAndWordSpacingAreLengthsThatInheritAsComputed() throws {
        let result = try styled(#"<p id="a">a<span id="child">b</span></p><p id="b">c</p><p id="c">d</p><p id="d">e</p>"#, css: """
            #a { letter-spacing: 0.1em; word-spacing: 0.5em; font-size: 30px } #child { font-size: 10px }
            #b { letter-spacing: 2px; letter-spacing: normal; word-spacing: 3px; word-spacing: NORMAL }
            #c { letter-spacing: -0.5px; word-spacing: -1px }
            #d { letter-spacing: 1px; letter-spacing: wide; word-spacing: 2px; word-spacing: 1px 2px }
            """)
        XCTAssertEqual(result.style("a").letterSpacing, 3, accuracy: 0.0001)
        XCTAssertEqual(result.style("a").wordSpacing, 15, accuracy: 0.0001)
        XCTAssertEqual(result.style("child").letterSpacing, 3, accuracy: 0.0001)
        XCTAssertEqual(result.style("child").wordSpacing, 15, accuracy: 0.0001)
        XCTAssertEqual(result.style("b").letterSpacing, 0)
        XCTAssertEqual(result.style("b").wordSpacing, 0)
        XCTAssertEqual(result.style("c").letterSpacing, -0.5)
        XCTAssertEqual(result.style("c").wordSpacing, -1)
        XCTAssertEqual(result.style("d").letterSpacing, 1)
        XCTAssertEqual(result.style("d").wordSpacing, 2)
    }

    func testTextTransformWhiteSpaceAndWritingModeKeywords() throws {
        let transforms: [(String, ComputedStyle.TextTransform)] = [("uppercase", .uppercase), ("LOWERCASE", .lowercase), ("capitalize", .capitalize),
                                                                   ("none", .none), ("full-width", .none)]
        for (item, style) in zip(transforms, try paragraphs(transforms.map { "text-transform: \($0.0)" }, parent: "text-transform: uppercase")) {
            XCTAssertEqual(style.textTransform, item.1, item.0)
        }
        let spaces: [(String, ComputedStyle.WhiteSpace)] = [("normal", .normal), ("nowrap", .nowrap), ("PRE", .pre), ("pre-wrap", .preWrap),
                                                            ("pre-line", .preLine), ("break-spaces", .breakSpaces), ("-moz-pre-wrap", .preWrap)]
        for (item, style) in zip(spaces, try paragraphs(spaces.map { "white-space: \($0.0)" }, parent: "white-space: pre")) {
            XCTAssertEqual(style.whiteSpace, item.1, item.0)
        }
        let modes: [(String, ComputedStyle.WritingMode)] = [
            ("writing-mode: vertical-rl", .verticalRL), ("-epub-writing-mode: vertical-rl", .verticalRL), ("-webkit-writing-mode: vertical-lr", .verticalLR),
            ("-epub-writing-mode: horizontal-tb", .horizontalTB), ("writing-mode: tb-rl", .verticalRL), ("writing-mode: lr-tb", .horizontalTB),
        ]
        for (item, style) in zip(modes, try paragraphs(modes.map(\.0), parent: "writing-mode: vertical-lr")) {
            XCTAssertEqual(style.writingMode, item.1, item.0)
        }
        let inherited = try paragraphs(["text-transform: bogus; white-space: bogus; writing-mode: diagonal", ""],
                                       parent: "text-transform: capitalize; white-space: pre-line; -epub-writing-mode: vertical-rl")
        for style in inherited {
            XCTAssertEqual(style.textTransform, .capitalize)
            XCTAssertEqual(style.whiteSpace, .preLine)
            XCTAssertEqual(style.writingMode, .verticalRL)
        }
        XCTAssertTrue(ComputedStyle.WhiteSpace.pre.preservesSpaces && ComputedStyle.WhiteSpace.pre.preservesNewlines && !ComputedStyle.WhiteSpace.pre.wraps)
        XCTAssertTrue(!ComputedStyle.WhiteSpace.preLine.preservesSpaces && ComputedStyle.WhiteSpace.preLine.preservesNewlines && ComputedStyle.WhiteSpace.preLine.wraps)
        XCTAssertTrue(!ComputedStyle.WhiteSpace.nowrap.preservesSpaces && !ComputedStyle.WhiteSpace.nowrap.preservesNewlines && !ComputedStyle.WhiteSpace.nowrap.wraps)
        XCTAssertTrue(ComputedStyle.WhiteSpace.breakSpaces.preservesSpaces && ComputedStyle.WhiteSpace.breakSpaces.wraps)
    }

    // MARK: Decoration and vertical alignment

    func testTextDecorationShorthandAndLonghands() throws {
        let styles = try paragraphs([
            "text-decoration: underline overline",
            "text-decoration: line-through wavy rgb(1, 2, 3) from-font",
            "text-decoration: underline; text-decoration: red",
            "text-decoration-line: underline line-through; text-decoration-color: blue",
            "text-decoration: underline; text-decoration: underline none",
            "text-decoration: underline; text-decoration: bogus",
            "text-decoration: underline 2px dotted",
            "-webkit-text-decoration: overline",
            "text-decoration: underline; text-decoration-style: wavy; text-decoration-thickness: 3px; text-underline-offset: 2px",
            "text-decoration: line-through; text-decoration: blink",
            "color: green; text-decoration: underline",
            "text-decoration: overline; text-decoration-line: NONE",
        ])
        XCTAssertEqual(styles[0].textDecoration, [.underline, .overline])
        XCTAssertEqual(styles[1].textDecoration, .lineThrough)
        CSSCascadeSupport.assertColor(styles[1].textDecorationColor, CSSCascadeSupport.color(1 / 255, 2 / 255, 3 / 255))
        XCTAssertEqual(styles[2].textDecoration, [], "A shorthand without a line resets it to none")
        XCTAssertEqual(styles[3].textDecoration, [.underline, .lineThrough])
        XCTAssertEqual(styles[3].textDecorationColor, CSSCascadeSupport.color(0, 0, 1))
        XCTAssertEqual(styles[4].textDecoration, .underline, "none cannot join another line")
        XCTAssertEqual(styles[5].textDecoration, .underline)
        XCTAssertEqual(styles[6].textDecoration, .underline, "A thickness and a style are accepted and not drawn")
        XCTAssertEqual(styles[7].textDecoration, .overline)
        XCTAssertEqual(styles[8].textDecoration, .underline)
        XCTAssertEqual(styles[9].textDecoration, [])
        XCTAssertEqual(styles[10].textDecorationColor, CSSCascadeSupport.hex(0x008000), "The default decoration color is the text's")
        XCTAssertEqual(styles[11].textDecoration, [])
    }

    func testDecorationsPropagateToInFlowDescendantsOnly() throws {
        let result = try styled("""
            <p id="p">a<span id="s">b<span id="g">c</span></span><span id="f">f</span><span id="abs">g</span><sup id="sup">1</sup></p>
            <p id="plain">h<span id="own">i</span></p>
            """, css: """
            #p { text-decoration: underline red } #s { color: blue } #f { float: left } #abs { position: absolute }
            #own { text-decoration: line-through }
            """)
        for id in ["s", "g", "sup"] {
            XCTAssertEqual(result.style(id).textDecoration, .underline, id)
            XCTAssertEqual(result.style(id).textDecorationColor, CSSCascadeSupport.color(1, 0, 0), "\(id) keeps the decorating box's color")
        }
        XCTAssertEqual(result.style("f").textDecoration, [], "A float is not decorated by its parent")
        XCTAssertEqual(result.style("abs").textDecoration, [], "Nor is an out-of-flow box")
        XCTAssertNil(result.style("f").textDecorationColor)
        XCTAssertEqual(result.style("plain").textDecoration, [], "A child's decoration never reaches its parent or siblings")
        XCTAssertEqual(result.style("own").textDecoration, .lineThrough)
    }

    func testVerticalAlignKeywordsLengthsAndPercentages() throws {
        let keywords: [(String, ComputedStyle.VerticalAlign)] = [
            ("baseline", .baseline), ("sub", .sub), ("SUPER", .super), ("top", .top), ("middle", .middle), ("bottom", .bottom),
            ("text-top", .textTop), ("text-bottom", .textBottom), ("-3px", .offset(-3)), ("0", .offset(0)),
            ("0.5em; font-size: 10px", .offset(5)), ("50%; line-height: 20px", .offset(10)), ("-25%; line-height: 2; font-size: 10px", .offset(-5)),
        ]
        let body = keywords.indices.map { "<span id=\"v\($0)\">x<b id=\"c\($0)\">y</b></span>" }.joined()
        let css = keywords.enumerated().map { "#v\($0.offset) { vertical-align: \($0.element.0) }" }.joined(separator: "\n")
            + "\n#bad { vertical-align: sub; vertical-align: bogus } #two { vertical-align: sub; vertical-align: 1px 2px }"
        let result = try styled("<p>\(body)<span id=\"bad\">z</span><span id=\"two\">w</span></p>", css: css)
        for (index, item) in keywords.enumerated() {
            XCTAssertEqual(result.style("v\(index)").verticalAlign, item.1, item.0)
            XCTAssertEqual(result.style("c\(index)").verticalAlign, .baseline, "vertical-align is not inherited")
        }
        XCTAssertEqual(result.style("bad").verticalAlign, .sub)
        XCTAssertEqual(result.style("two").verticalAlign, .sub)
    }

    // MARK: Hyphenation and direction

    func testHyphensAndItsPrefixedAliasesShareOneCascadedValue() throws {
        let cases: [(String, ComputedStyle.Hyphens)] = [
            ("hyphens: none", .none), ("-epub-hyphens: none", .none), ("-webkit-hyphens: MANUAL", .manual), ("-moz-hyphens: none", .none),
            ("-ms-hyphens: none", .none), ("adobe-hyphenate: none", .none), ("adobe-hyphenate: explicit", .manual),
            ("hyphens: none; -webkit-hyphens: auto", .auto), ("-epub-hyphens: auto; hyphens: none", .none),
            ("hyphens: none; hyphens: sometimes", .none), ("hyphens: none; -epub-hyphens: all", .none), ("hyphens: initial", .manual),
            ("", .auto),
        ]
        for (item, style) in zip(cases, try paragraphs(cases.map(\.0))) { XCTAssertEqual(style.hyphens, item.1, item.0) }
        let inherited = try styled(#"<div style="-epub-hyphens: none"><p id="p">a<em id="em">b</em></p></div>"#)
        XCTAssertEqual(inherited.style("em").hyphens, ComputedStyle.Hyphens.none)
    }

    func testDirectionComesFromThePropertyOrTheDirAttributeWithAuthorRulesWinning() throws {
        let result = try styled("""
            <div id="attr" dir="RTL"><p id="child">a</p><p id="back" dir="ltr">b</p></div><p id="prop">c</p><p id="both" dir="rtl">d</p>
            <p id="auto" dir="auto">e</p><p id="bad" dir="sideways">f</p><p id="invalid">g</p><p id="upper">h</p>
            """, css: "#prop { direction: rtl } #both { direction: ltr } #invalid { direction: rtl; direction: auto } #upper { direction: RTL }")
        XCTAssertEqual(result.style("attr").direction, .rtl)
        XCTAssertEqual(result.style("child").direction, .rtl)
        XCTAssertEqual(result.style("back").direction, .ltr)
        XCTAssertEqual(result.style("prop").direction, .rtl)
        XCTAssertEqual(result.style("both").direction, .ltr, "HTML maps dir in the user-agent sheet, so an author rule overrides it")
        XCTAssertEqual(result.style("auto").direction, .ltr, "dir=auto follows the content, which is left-to-right here")
        XCTAssertEqual(result.style("bad").direction, .ltr)
        XCTAssertEqual(result.style("invalid").direction, .rtl)
        XCTAssertEqual(result.style("upper").direction, .rtl)
    }

    // MARK: Lists

    func testListStyleTypeKeywordsStringsAndInheritance() throws {
        let cases: [(String, ComputedStyle.ListStyleType)] = [
            ("disc", .disc), ("circle", .circle), ("square", .square), ("decimal", .decimal), ("decimal-leading-zero", .decimalLeadingZero),
            ("lower-roman", .lowerRoman), ("UPPER-ROMAN", .upperRoman), ("lower-alpha", .lowerAlpha), ("upper-alpha", .upperAlpha),
            ("lower-latin", .lowerAlpha), ("upper-latin", .upperAlpha), ("lower-greek", .lowerGreek), ("none", .none),
            ("\"- \"", .string("- ")), ("'★'", .string("★")),
        ]
        let body = cases.indices.map { "<ul id=\"l\($0)\"><li id=\"i\($0)\">x</li></ul>" }.joined()
            + #"<ul id="bad"><li>y</li></ul><ul id="two"><li>z</li></ul>"#
        let css = cases.enumerated().map { "#l\($0.offset) { list-style-type: \($0.element.0) }" }.joined(separator: "\n")
            + "\n#bad { list-style-type: square; list-style-type: 12px } #two { list-style-type: square; list-style-type: disc circle }"
        let result = try styled(body, css: css)
        for (index, item) in cases.enumerated() {
            XCTAssertEqual(result.style("l\(index)").listStyleType, item.1, item.0)
            XCTAssertEqual(result.style("i\(index)").listStyleType, item.1, "\(item.0) is inherited by the item")
        }
        XCTAssertEqual(result.style("bad").listStyleType, .square)
        XCTAssertEqual(result.style("two").listStyleType, .square)
    }

    func testListStyleShorthandSetsTypeAndPositionAndResetsWhatItOmits() throws {
        let cases: [(String, ComputedStyle.ListStyleType, ComputedStyle.ListStylePosition)] = [
            ("list-style: square inside", .square, .inside), ("list-style: none", .none, .outside),
            ("list-style-type: square; list-style: url(b.png)", .disc, .outside), ("list-style: none inside", .none, .inside),
            ("list-style: \"–\" outside", .string("–"), .outside), ("list-style: upper-alpha url(b.png) outside", .upperAlpha, .outside),
            ("list-style: none url(b.png)", .none, .outside), ("list-style: square; list-style: none none none", .square, .outside),
            ("list-style: square; list-style: disc circle", .square, .outside),
            ("list-style-position: inside; list-style: decimal", .decimal, .outside),
            ("list-style: square; list-style-position: INSIDE", .square, .inside),
            ("list-style-position: inside; list-style-position: middle", .disc, .inside),
        ]
        let body = cases.indices.map { "<ul id=\"l\($0)\"><li id=\"i\($0)\">x</li></ul>" }.joined()
        let css = cases.enumerated().map { "#l\($0.offset) { \($0.element.0) }" }.joined(separator: "\n")
        let result = try styled(body, css: css)
        for (index, item) in cases.enumerated() {
            XCTAssertEqual(result.style("l\(index)").listStyleType, item.1, item.0)
            XCTAssertEqual(result.style("l\(index)").listStylePosition, item.2, item.0)
            XCTAssertEqual(result.style("i\(index)").listStylePosition, item.2, "\(item.0): the position is inherited")
        }
    }

    /// HTML §15.3.8: `ol[type=a s]` and its siblings are case-sensitive, `ul[type=… i]` is not.
    func testHTMLListTypeAttributesChooseTheMarker() throws {
        let result = try styled("""
            <ol id="a" type="a"><li id="a-item">x</li><li id="roman-item" type="I">y</li></ol><ol id="A" type="A"><li>x</li></ol>
            <ol id="i" type="i"><li>x</li></ol><ol id="I" type="I"><li>x</li></ol><ol id="one" type="1"><li>x</li></ol>
            <ol id="unknown" type="x"><li>x</li></ol><ul id="circle" type="CIRCLE"><li id="circle-item">x</li></ul>
            <ul id="none" type="none"><li>x</li></ul><ul id="square" type="Square"><li>x</li></ul>
            <ol id="css" type="a"><li>x</li></ol><ul><li id="disc-item" type="disc">x<ul><li id="nested">y</li></ul></li></ul>
            """, css: "#css { list-style-type: upper-roman }")
        XCTAssertEqual(result.style("a").listStyleType, .lowerAlpha)
        XCTAssertEqual(result.style("a-item").listStyleType, .lowerAlpha)
        XCTAssertEqual(result.style("roman-item").listStyleType, .upperRoman)
        XCTAssertEqual(result.style("A").listStyleType, .upperAlpha)
        XCTAssertEqual(result.style("i").listStyleType, .lowerRoman)
        XCTAssertEqual(result.style("I").listStyleType, .upperRoman)
        XCTAssertEqual(result.style("one").listStyleType, .decimal)
        XCTAssertEqual(result.style("unknown").listStyleType, .decimal)
        XCTAssertEqual(result.style("circle").listStyleType, .circle)
        XCTAssertEqual(result.style("circle-item").listStyleType, .circle)
        XCTAssertEqual(result.style("none").listStyleType, ComputedStyle.ListStyleType.none)
        XCTAssertEqual(result.style("square").listStyleType, .square)
        XCTAssertEqual(result.style("css").listStyleType, .upperRoman, "An author rule beats the attribute")
        XCTAssertEqual(result.style("nested").listStyleType, .circle, "A nested list's own default beats the marker its parent item asked for")
    }

    // MARK: Fragmentation

    func testBreakPropertiesAndTheirPageBreakAliases() throws {
        typealias Break = ComputedStyle.Break
        let before: [(String, Break)] = [
            ("break-before: auto", .auto), ("break-before: avoid", .avoid), ("break-before: avoid-page", .avoid), ("break-before: page", .page),
            ("break-before: left", .page), ("break-before: right", .page), ("break-before: recto", .page), ("break-before: verso", .page),
            ("break-before: ALWAYS", .page), ("break-before: column", .column), ("break-before: avoid-column", .avoid),
            ("page-break-before: always", .page), ("page-break-before: left", .page), ("page-break-before: right", .page),
            ("page-break-before: avoid", .avoid), ("break-before: page; page-break-before: auto", .auto),
            ("break-before: avoid; page-break-before: page", .avoid), ("break-before: avoid; page-break-before: column", .avoid),
            ("break-before: avoid; break-before: sometimes", .avoid), ("page-break-before: always; break-before: auto", .auto),
            ("break-before: auto; page-break-before: always", .page),
        ]
        for (item, style) in zip(before, try paragraphs(before.map(\.0))) { XCTAssertEqual(style.breakBefore, item.1, item.0) }
        let after: [(String, Break)] = [("break-after: page", .page), ("page-break-after: always", .page), ("page-break-after: avoid", .avoid),
                                        ("break-after: avoid-page", .avoid), ("break-after: column", .column), ("page-break-after: AUTO", .auto)]
        for (item, style) in zip(after, try paragraphs(after.map(\.0))) { XCTAssertEqual(style.breakAfter, item.1, item.0) }
        let inside: [(String, Break)] = [("break-inside: avoid", .avoid), ("break-inside: avoid-page", .avoid), ("break-inside: avoid-column", .avoid),
                                         ("page-break-inside: avoid", .avoid), ("break-inside: avoid; break-inside: auto", .auto),
                                         ("break-inside: page", .auto), ("page-break-inside: always", .auto),
                                         ("page-break-inside: avoid; page-break-inside: auto", .auto)]
        for (item, style) in zip(inside, try paragraphs(inside.map(\.0))) { XCTAssertEqual(style.breakInside, item.1, item.0) }
    }

    func testBreaksAreNotInherited() throws {
        let result = try styled(#"<div id="d"><p id="p">x</p></div><h2 id="h">y<span id="s">z</span></h2>"#,
                                css: "#d { break-before: page; break-after: page; break-inside: avoid }")
        XCTAssertEqual(result.style("d").breakBefore, .page)
        XCTAssertEqual(result.style("p").breakBefore, .auto)
        XCTAssertEqual(result.style("p").breakAfter, .auto)
        XCTAssertEqual(result.style("p").breakInside, .auto)
        XCTAssertEqual(result.style("h").breakAfter, .avoid, "Headings stay with what follows")
        XCTAssertEqual(result.style("s").breakAfter, .auto)
    }

    // MARK: Properties outside the subset

    func testPropertiesOutsideTheSubsetAreIgnoredWithoutDisturbingTheirRule() throws {
        let css = """
            #p { text-shadow: 1px 1px 2px red; color: red; font-kerning: none; font-stretch: condensed; margin-left: 4px; border-radius: 5px;
                 overflow: hidden; widows: 2; orphans: 2; text-indent: 2px; unicode-bidi: embed; -epub-text-emphasis: dot; text-emphasis: sesame;
                 box-shadow: 0 0 5px #000; transform: rotate(5deg); font-weight: bold; -webkit-font-smoothing: antialiased; word-break: break-all;
                 font-feature-settings: "liga" 1; quotes: "«" "»"; cursor: pointer; z-index: 3; -epub-ruby-position: over; text-align-last: center;
                 --custom: { a: b }; content: "x"; opacity: 0.5; text-align: center }
            """
        let style = try styled(#"<p id="p">x</p>"#, css: css).style("p")
        XCTAssertEqual(style.color, CSSCascadeSupport.color(1, 0, 0))
        XCTAssertEqual(style.margin.left, .points(4))
        XCTAssertEqual(style.textIndent, .points(2))
        XCTAssertEqual(style.fontWeight, 700)
        XCTAssertEqual(style.textAlign, .center)
        let sheet = CSSStyleSheet.parse(css, path: "OPS/a.css")
        XCTAssertFalse(sheet.truncated)
        XCTAssertEqual(sheet.rules.first?.declarations.map(\.property), [.color, .marginLeft, .textIndent, .fontWeight, .textAlign])
    }
}
