import CoreText
import CryptoKit
import EPUBReading
import EPUBTestSupport
@testable import EPUBViewing
import XCTest

/// CSS Fonts: the `font` shorthand and its longhands, size keywords and the reader's scaling,
/// `@font-face` descriptors and sources, and matching against a book's embedded faces.
final class CSSCascadeFontCoverageTests: XCTestCase {
    private func styled(_ body: String, css: String, typography: NativeTypography = NativeTypography(fontSize: 16)) throws -> StyledDocument {
        try CSSCascadeSupport.styled(body, css: css, typography: typography)
    }

    private func paragraphs(_ ids: String) -> String { ids.map { "<p id=\"\($0)\">x</p>" }.joined() }

    // MARK: The font shorthand and longhands

    func testFontShorthandTakesStyleVariantWeightAndStretchInAnyOrder() throws {
        let result = try styled(paragraphs("abcdefgh"), css: """
            #a { font: italic small-caps bold 12px/1.5 "A B", serif }
            #b { font: bold italic 12px serif }
            #c { font: small-caps 600 condensed oblique 2em/30px Palatino }
            #d { font: normal normal normal normal 80% sans-serif }
            #e { font: 900 x-large/normal fantasy }
            #f { font: ITALIC BOLD 12PX/2 SERIF }
            #g { font: lighter 1em "X" }
            #h { font: 12pt/15pt Times New Roman, Georgia }
            """)
        let a = result.style("a")
        XCTAssertTrue(a.isItalic); XCTAssertTrue(a.isSmallCaps)
        XCTAssertEqual(a.fontWeight, 700); XCTAssertEqual(a.fontSize, 12)
        XCTAssertEqual(a.lineHeight, .multiple(1.5)); XCTAssertEqual(a.fontFamilies, ["a b", "serif"])
        let b = result.style("b")
        XCTAssertTrue(b.isItalic); XCTAssertFalse(b.isSmallCaps); XCTAssertEqual(b.fontWeight, 700); XCTAssertEqual(b.lineHeight, .normal)
        let c = result.style("c")
        XCTAssertTrue(c.isItalic); XCTAssertTrue(c.isSmallCaps); XCTAssertEqual(c.fontWeight, 600)
        XCTAssertEqual(c.fontSize, 32); XCTAssertEqual(c.lineHeight, .points(30)); XCTAssertEqual(c.fontFamilies, ["palatino"])
        let d = result.style("d")
        XCTAssertFalse(d.isItalic); XCTAssertFalse(d.isSmallCaps); XCTAssertEqual(d.fontWeight, 400)
        XCTAssertEqual(d.fontSize, 12.8, accuracy: 0.0001); XCTAssertEqual(d.fontFamilies, ["sans-serif"])
        XCTAssertEqual(result.style("e").fontWeight, 900)
        XCTAssertEqual(result.style("e").fontSize, 24)
        XCTAssertEqual(result.style("e").lineHeight, .normal)
        let f = result.style("f")
        XCTAssertTrue(f.isItalic); XCTAssertEqual(f.fontWeight, 700); XCTAssertEqual(f.fontSize, 12)
        XCTAssertEqual(f.lineHeight, .multiple(2)); XCTAssertEqual(f.fontFamilies, ["serif"])
        XCTAssertEqual(result.style("g").fontWeight, 100, "lighter than the inherited 400")
        XCTAssertEqual(result.style("g").fontFamilies, ["x"])
        XCTAssertEqual(result.style("h").fontSize, 16)
        XCTAssertEqual(result.style("h").lineHeight, .points(20))
        XCTAssertEqual(result.style("h").fontFamilies, ["times new roman", "georgia"])
    }

    func testFontShorthandResetsEveryLonghandItOmits() throws {
        let result = try styled(#"<p id="p">x</p><p id="q">y</p><p id="r">z</p>"#, css: """
            p { font-style: italic; font-weight: bold; font-variant: small-caps; line-height: 3; font-family: Georgia; font-size: 30px }
            #p { font: 12px serif }
            #q { font: italic 12px serif; font-style: normal; line-height: 2 }
            #r { font: caption }
            """)
        let p = result.style("p")
        XCTAssertFalse(p.isItalic); XCTAssertFalse(p.isSmallCaps)
        XCTAssertEqual(p.fontWeight, 400); XCTAssertEqual(p.lineHeight, .normal)
        XCTAssertEqual(p.fontFamilies, ["serif"]); XCTAssertEqual(p.fontSize, 12)
        XCTAssertFalse(result.style("q").isItalic, "A longhand after the shorthand wins")
        XCTAssertEqual(result.style("q").lineHeight, .multiple(2))
        let r = result.style("r")
        XCTAssertFalse(r.isItalic); XCTAssertFalse(r.isSmallCaps); XCTAssertEqual(r.fontWeight, 400)
        XCTAssertEqual(r.lineHeight, .normal); XCTAssertEqual(r.fontSize, 16, "A system font is the reader's size")
        XCTAssertEqual(r.fontFamilies, ["system-ui"])
    }

    func testSystemFontKeywordsAreTheSystemFontAtTheReadersSize() throws {
        let keywords = ["caption", "icon", "menu", "message-box", "small-caption", "STATUS-BAR", "-apple-system-body", "-apple-system-headline"]
        let body = keywords.indices.map { "<p id=\"k\($0)\">x</p>" }.joined()
        let css = "p { font: italic bold 40px Georgia }\n" + keywords.enumerated().map { "#k\($0.offset) { font: \($0.element) }" }.joined(separator: "\n")
        let result = try styled(body, css: css, typography: NativeTypography(fontSize: 20))
        for (index, keyword) in keywords.enumerated() {
            let style = result.style("k\(index)")
            XCTAssertEqual(style.fontFamilies, ["system-ui"], keyword)
            XCTAssertEqual(style.fontSize, 20, keyword)
            XCTAssertEqual(style.fontWeight, 400, keyword)
            XCTAssertFalse(style.isItalic, keyword)
        }
    }

    func testAnInvalidFontShorthandLeavesTheEarlierDeclarations() throws {
        let invalid = ["bold serif", "12px", "italic 12px/ serif", "12px/1.5", "normal normal normal normal normal 12px serif",
                       "bold 12px inherit", "12px Goudy Bookletter 1911", "12px, serif", "-12px serif", "caption serif", "12px/-1 serif",
                       "serif 12px", "12px serif / 2"]
        let body = invalid.indices.map { "<p id=\"i\($0)\">x</p>" }.joined()
        let css = invalid.enumerated().map { "#i\($0.offset) { font-family: Georgia; font-size: 20px; font: \($0.element) }" }.joined(separator: "\n")
        let result = try styled(body, css: css)
        for (index, value) in invalid.enumerated() {
            XCTAssertEqual(result.style("i\(index)").fontFamilies, ["georgia"], value)
            XCTAssertEqual(result.style("i\(index)").fontSize, 20, value)
        }
    }

    /// CSS Fonts 4 §2.4 and §2.7: `font-style` is `normal | italic | oblique <angle>?`, and the
    /// `font` shorthand takes any `<'font-style'>` before the size.
    func testFontShorthandAcceptsAnObliqueAngle() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/125")
        let result = try styled(#"<p id="p">x</p><p id="q">y</p>"#, css: """
            #p { font: oblique 10deg 12px serif }
            #q { font: bold oblique -8deg 12px/2 Georgia }
            """)
        XCTAssertEqual(result.style("p").fontSize, 12, "font: oblique 10deg 12px serif")
        XCTAssertTrue(result.style("p").isItalic)
        XCTAssertEqual(result.style("p").fontFamilies, ["serif"])
        XCTAssertEqual(result.style("q").fontWeight, 700, "font: bold oblique -8deg 12px/2 Georgia")
        XCTAssertEqual(result.style("q").lineHeight, .multiple(2))
    }

    func testFontFamilyListsKeepOrderQuotingAndEscapes() throws {
        let result = try styled(paragraphs("abcdef"), css: """
            #a { font-family: "A, B", serif }
            #b { font-family: Gill   Sans  ,'Open Sans' }
            #c { font-family: \\41 rial, "Foo\\"Bar" }
            #d { font-family: Sans-Serif, MONOSPACE, System-UI }
            #e { font-family: "serif", Fantasy }
            #f { font-family: \((1...20).map { "F\($0)" }.joined(separator: ", ")) }
            """)
        XCTAssertEqual(result.style("a").fontFamilies, ["a, b", "serif"])
        XCTAssertEqual(result.style("b").fontFamilies, ["gill sans", "open sans"])
        XCTAssertEqual(result.style("c").fontFamilies, ["arial", "foo\"bar"])
        XCTAssertEqual(result.style("d").fontFamilies, ["sans-serif", "monospace", "system-ui"])
        XCTAssertEqual(result.style("e").fontFamilies, ["serif", "fantasy"])
        XCTAssertEqual(result.style("f").fontFamilies, (1...CSSPropertyParser.maximumFamilies).map { "f\($0)" }, "A list is bounded")
    }

    func testAnInvalidFontFamilyListLeavesTheInheritedFamilies() throws {
        let invalid = ["Goudy Bookletter 1911", "serif,", ", serif", "\"A\" \"B\"", "A \"B\"", "inherit, serif", "12px", "A, 5, B", "A / B", "A, initial"]
        let body = "<div>" + invalid.indices.map { "<p id=\"i\($0)\">x</p>" }.joined() + "</div>"
        let css = "div { font-family: Georgia }\n" + invalid.enumerated().map { "#i\($0.offset) { font-family: \($0.element) }" }.joined(separator: "\n")
        let result = try styled(body, css: css)
        for (index, value) in invalid.enumerated() { XCTAssertEqual(result.style("i\(index)").fontFamilies, ["georgia"], value) }
    }

    /// CSS Fonts 4 §2.2.1's table for `bolder` and `lighter`.
    func testRelativeWeightsFollowTheInheritedWeight() throws {
        let weights = [100, 200, 300, 349, 350, 400, 500, 549, 550, 600, 700, 749, 750, 800, 899, 900]
        let body = weights.map { "<div style=\"font-weight: \($0)\"><b id=\"b\($0)\">x</b><span id=\"l\($0)\" style=\"font-weight: lighter\">y</span></div>" }.joined()
        let result = try styled(body, css: "")
        for weight in weights {
            let bolder = weight < 350 ? 400 : weight < 550 ? 700 : 900
            let lighter = weight < 550 ? 100 : weight < 750 ? 400 : 700
            XCTAssertEqual(result.style("b\(weight)").fontWeight, bolder, "bolder than \(weight)")
            XCTAssertEqual(result.style("l\(weight)").fontWeight, lighter, "lighter than \(weight)")
        }
    }

    func testFontWeightKeywordsNumbersAndInvalidValues() throws {
        let result = try styled(paragraphs("abcd") + #"<div id="e">x<p id="f">y</p></div>"#, css: """
            #a { font-weight: BOLD } #b { font-weight: 550 } #c { font-weight: bold; font-weight: normal } #d { font-weight: 100 }
            #e { font-weight: 600; font-weight: 0; font-weight: 1001; font-weight: 400px; font-weight: -400; font-weight: heavy; font-weight: bold bold }
            """)
        XCTAssertEqual(result.style("a").fontWeight, 700)
        XCTAssertEqual(result.style("b").fontWeight, 550)
        XCTAssertEqual(result.style("c").fontWeight, 400)
        XCTAssertEqual(result.style("d").fontWeight, 100)
        XCTAssertEqual(result.style("e").fontWeight, 600, "Weights outside 1–1000, with units or unknown keywords are invalid")
        XCTAssertEqual(result.style("f").fontWeight, 600, "inherited")
    }

    func testFontStyleAndVariantForms() throws {
        let result = try styled("""
            <p id="a">a</p><p id="b">b</p><p id="c">c</p><p id="d">d</p><p id="e">e</p>
            <div id="caps">x<p id="f">f</p><p id="g">g</p><p id="h">h</p><p id="i">i</p><em id="j">j</em></div>
            """, css: """
            #a { font-style: oblique } #b { font-style: OBLIQUE -5deg } #c { font-style: italic; font-style: normal }
            #d { font-style: italic; font-style: italic 10deg; font-style: slanted }
            #e { font-style: oblique 10deg 20deg }
            #caps { font-variant: small-caps; font-style: italic }
            #f { font-variant: normal } #g { font-variant: oldstyle-nums } #h { font-variant: bogus } #i { font-variant-caps: normal }
            #j { font-style: normal }
            """)
        XCTAssertTrue(result.style("a").isItalic)
        XCTAssertTrue(result.style("b").isItalic)
        XCTAssertFalse(result.style("c").isItalic)
        XCTAssertTrue(result.style("d").isItalic, "Invalid font-style values leave the earlier one")
        XCTAssertFalse(result.style("e").isItalic)
        XCTAssertTrue(result.style("caps").isSmallCaps)
        XCTAssertFalse(result.style("f").isSmallCaps)
        XCTAssertFalse(result.style("g").isSmallCaps, "The font-variant shorthand resets the caps it does not name")
        XCTAssertTrue(result.style("h").isSmallCaps, "An invalid font-variant leaves the inherited caps")
        XCTAssertFalse(result.style("i").isSmallCaps)
        XCTAssertTrue(result.style("h").isItalic, "font-style inherits")
        XCTAssertFalse(result.style("j").isItalic, "An author rule beats the user-agent's em { font-style: italic }")
        XCTAssertTrue(result.style("j").isSmallCaps)
    }

    // MARK: Sizes

    func testAbsoluteSizeKeywordsIgnoreTheParentAndRelativeOnesFollowIt() throws {
        let keywords: [(String, CGFloat)] = [("xx-small", 9), ("x-small", 10), ("small", 13), ("medium", 16), ("large", 18),
                                             ("x-large", 24), ("xx-large", 32), ("xxx-large", 48), ("MEDIUM", 16)]
        let body = "<div>" + keywords.indices.map { "<p id=\"k\($0)\">x</p>" }.joined()
            + #"<p id="larger">a<span id="smaller">b</span></p><p id="chain">c<span id="chain2">d<span id="chain3">e</span></span></p></div>"#
        let css = "div { font-size: 40px }\n" + keywords.enumerated().map { "#k\($0.offset) { font-size: \($0.element.0) }" }.joined(separator: "\n")
            + "\n#larger { font-size: LARGER } #smaller { font-size: smaller } #chain, #chain2, #chain3 { font-size: larger }"
        let result = try styled(body, css: css)
        for (index, keyword) in keywords.enumerated() { XCTAssertEqual(result.style("k\(index)").fontSize, keyword.1, keyword.0) }
        XCTAssertEqual(result.style("larger").fontSize, 48, accuracy: 0.0001)
        XCTAssertEqual(result.style("smaller").fontSize, 40, accuracy: 0.0001)
        XCTAssertEqual(result.style("chain3").fontSize, 40 * 1.2 * 1.2 * 1.2, accuracy: 0.0001)
    }

    func testNestedEmAndPercentageSizesCompoundWithinTheBounds() throws {
        let result = try styled("""
            <div id="a">a<div id="b">b<div id="c">c</div></div></div>
            <div class="h" id="h1">x<div class="h" id="h2">x<div class="h" id="h3">x<div class="h" id="h4">x<div class="h" id="h5">x</div></div></div></div></div>
            <div class="d" id="d1">x<div class="d" id="d2">x<div class="d" id="d3">x<div class="d" id="d4">x</div></div></div></div>
            """, css: "#a { font-size: 150% } #b { font-size: 1.5em } #c { font-size: 50% } .h { font-size: 0.5em } .d { font-size: 10em }")
        XCTAssertEqual(result.style("a").fontSize, 24)
        XCTAssertEqual(result.style("b").fontSize, 36)
        XCTAssertEqual(result.style("c").fontSize, 18)
        XCTAssertEqual(result.style("h2").fontSize, 4)
        XCTAssertEqual(result.style("h5").fontSize, StyleLimits.fontSize.lowerBound, "Text never shrinks out of sight")
        XCTAssertEqual(result.style("d2").fontSize, StyleLimits.fontSize.upperBound)
        XCTAssertEqual(result.style("d4").fontSize, StyleLimits.fontSize.upperBound)
    }

    /// `ComputedStyle`: "Absolute font sizes are scaled by `typography.fontSize / 16`, so a book's
    /// own sizes keep their proportions while the reader's size governs the whole book."
    func testTheReadersSizeScalesFontSizesAndAbsoluteLineHeightsButNotBoxLengths() throws {
        let body = #"<p id="a">a</p><p id="b">b</p><p id="c">c</p><p id="d">d</p><p id="e">e</p><p id="f">f</p><p id="g">g</p>"#
        let css = """
            #a { font-size: 16px; margin-left: 16px; line-height: 24px; text-indent: 1em; letter-spacing: 0.5em }
            #b { font-size: 12pt } #c { font-size: 2em; margin-left: 1em } #d { font-size: 150% } #e { font-size: medium }
            #f { font-size: 1rem } #g { font-size: calc(8px + 0.5em); line-height: 150% }
            """
        let base = try styled(body, css: css)
        let large = try styled(body, css: css, typography: NativeTypography(fontSize: 24))
        for id in ["a", "b", "c", "d", "e", "f", "g"] {
            XCTAssertEqual(large.style(id).fontSize, base.style(id).fontSize * 1.5, accuracy: 0.0001, "#\(id) keeps its proportion")
        }
        XCTAssertEqual(large.style("a").fontSize, 24, "16px is the reader's size")
        XCTAssertEqual(large.style("b").fontSize, 24)
        XCTAssertEqual(large.style("c").fontSize, 48)
        XCTAssertEqual(large.style("a").margin.left, .points(16), "Box lengths in px do not scale")
        XCTAssertEqual(large.style("a").lineHeight, .points(36), "An absolute line height keeps its ratio to the text")
        XCTAssertEqual(large.style("a").textIndent, .points(24), "Lengths in em follow the scaled text")
        XCTAssertEqual(large.style("a").letterSpacing, 12)
        XCTAssertEqual(large.style("c").margin.left, .points(48))
        XCTAssertEqual(large.style("g").lineHeight, .points(36))
        XCTAssertEqual(NativeTypography(fontSize: 5).fontSize, NativeTypography.minimumFontSize, "The reader's size is 12–96")
        XCTAssertEqual(NativeTypography(fontSize: 500).fontSize, NativeTypography.maximumFontSize)
    }

    // MARK: @font-face rules

    private func faces(_ css: String) -> CSSStyleSheet { CSSStyleSheet.parse(css, path: "OPS/css/book.css") }

    func testFontFaceDescriptorsAreCaseInsensitiveWithWeightRangesAndStyles() {
        let sheet = faces("""
            @font-face { font-family: "My Font"; src: url(a.ttf) }
            @font-face { font-family: My   Font; src: url(b.ttf); font-weight: 300 500 }
            @FONT-FACE { FONT-FAMILY: "X"; SRC: URL(c.ttf) FORMAT("TRUETYPE"); FONT-WEIGHT: BOLD; FONT-STYLE: ITALIC }
            @font-face { font-family: Y; src: url(d.ttf); font-weight: 900 100; font-style: oblique 14deg }
            @font-face { font-family: Z; src: url(e.ttf); font-weight: bolder; font-style: normal; unicode-range: U+0-7F; font-display: swap }
            @font-face { font-family: W; src: url(f.ttf); font-weight: normal }
            """)
        XCTAssertEqual(sheet.fontFaces, [
            CSSFontFace(family: "my font", sources: ["OPS/css/a.ttf"]),
            CSSFontFace(family: "my font", weights: 300...500, sources: ["OPS/css/b.ttf"]),
            CSSFontFace(family: "x", weights: 700...700, isItalic: true, sources: ["OPS/css/c.ttf"]),
            CSSFontFace(family: "y", weights: 100...900, isItalic: true, sources: ["OPS/css/d.ttf"]),
            CSSFontFace(family: "z", sources: ["OPS/css/e.ttf"]),
            CSSFontFace(family: "w", sources: ["OPS/css/f.ttf"]),
        ])
        XCTAssertFalse(sheet.truncated)
    }

    func testFontFaceSourcesKeepLoadableArchiveFilesInOrder() {
        let sheet = faces("""
            @font-face { font-family: A; src: local("Georgia"), local(Georgia), url(a.woff2) format("woff2"), url(a.ttf) format(truetype),
                         url(a.eot) format("embedded-opentype"), url(a.svg#f) format("svg"), url(a.otf) format("opentype") tech(variations) }
            @font-face { font-family: B; src: url("../fonts/My%20Font.ttf"), url(./x/../y.otf), url(a.ttf?v=3#iefix), url(a.ttf) }
            @font-face { font-family: C; src: url(https://example.com/a.woff), url(//cdn.example.com/b.woff), url(HTTP://example.com/c.woff), url(local.woff) }
            @font-face { font-family: D; src: url(../../../outside.ttf), url(data:font/ttf;base64,AAAA), url(), url(inside.ttf) }
            @font-face { font-family: E; src: url("quoted name.ttf"), url(spaced\\ name.ttf) }
            """)
        XCTAssertEqual(sheet.fontFaces.map(\.sources), [
            ["OPS/css/a.woff2", "OPS/css/a.ttf", "OPS/css/a.otf"],
            ["OPS/fonts/My Font.ttf", "OPS/css/y.otf", "OPS/css/a.ttf"],
            ["OPS/css/local.woff"],
            // `..` stops at the container root.
            ["outside.ttf", "OPS/css/inside.ttf"],
            ["OPS/css/quoted name.ttf", "OPS/css/spaced name.ttf"],
        ])
        XCTAssertEqual(sheet.remoteReferences, 3, "Remote sources are counted and never listed")
    }

    func testFontFaceRulesWithoutAFamilyOrALoadableSourceAreDropped() {
        let sheet = faces("""
            @font-face { font-family: NoSource }
            @font-face { src: url(nofamily.ttf) }
            @font-face { font-family: RemoteOnly; src: url(https://example.com/a.woff2) format("woff2") }
            @font-face { font-family: OldFormats; src: url(a.eot) format("embedded-opentype"), url(a.svg) format("svg") }
            @font-face { font-family: Unknown; src: url(a.xyz) format("woff3") }
            @font-face { font-family: LocalOnly; src: local("Georgia") }
            @media print { @font-face { font-family: Printed; src: url(print.ttf) } }
            @media screen { @font-face { font-family: Screened; src: url(screen.ttf) } }
            @font-face { font-family: Kept; src: url(kept.ttf) }
            """)
        XCTAssertEqual(sheet.fontFaces.map(\.family), ["screened", "kept"])
        XCTAssertEqual(sheet.remoteReferences, 1)
    }

    // MARK: Matching embedded faces

    func testAnEmbeddedFamilyShadowsAnInstalledFamilyOfTheSameName() throws {
        let fonts = try CSSCascadeSupport.registry(files: ["fonts/t.ttf": try CSSCascadeSupport.fontFile("TimesNewRomanPSMT")])
        guard CTFontCopyFamilyName(fonts.font(for: CSSCascadeSupport.fontStyle(["georgia"])) as CTFont) as String == "Georgia" else {
            throw XCTSkip("Georgia is not installed")
        }
        var report = SectionReport()
        fonts.register([CSSFontFace(family: "georgia", sources: ["OPS/fonts/t.ttf"])], report: &report)
        XCTAssertEqual(fonts.font(for: CSSCascadeSupport.fontStyle(["georgia"])).fontName, "TimesNewRomanPSMT",
                       "The book's face wins over the system's (CSS Fonts 4 §5.2 step 3), also for an already resolved family")
        XCTAssertEqual(fonts.font(for: CSSCascadeSupport.fontStyle(["georgia"], weight: 700, italic: true)).fontName, "TimesNewRomanPSMT")
        XCTAssertEqual(report, SectionReport())
    }

    func testStyleIsMatchedBeforeWeightAndMissingFacesAreSynthesized() throws {
        let fonts = try CSSCascadeSupport.registry(files: ["fonts/g.ttf": try CSSCascadeSupport.fontFile("Georgia"),
                                                           "fonts/gi.ttf": try CSSCascadeSupport.fontFile("Georgia-Italic"),
                                                           "fonts/gb.ttf": try CSSCascadeSupport.fontFile("Georgia-Bold")])
        var report = SectionReport()
        fonts.register([
            CSSFontFace(family: "pair", sources: ["OPS/fonts/g.ttf"]),
            CSSFontFace(family: "pair", weights: 700...700, sources: ["OPS/fonts/gb.ttf"]),
            CSSFontFace(family: "pair", isItalic: true, sources: ["OPS/fonts/gi.ttf"]),
            CSSFontFace(family: "italic only", isItalic: true, sources: ["OPS/fonts/gi.ttf"]),
            CSSFontFace(family: "ranged", weights: 300...700, sources: ["OPS/fonts/g.ttf"]),
        ], report: &report)
        let style = CSSCascadeSupport.fontStyle
        XCTAssertEqual(fonts.font(for: style(["pair"], 400, false)).fontName, "Georgia")
        XCTAssertEqual(fonts.font(for: style(["pair"], 700, false)).fontName, "Georgia-Bold")
        XCTAssertEqual(fonts.font(for: style(["pair"], 400, true)).fontName, "Georgia-Italic")
        XCTAssertEqual(fonts.font(for: style(["pair"], 700, true)).fontName, "Georgia-Italic", "An italic face beats an upright one of the right weight")
        XCTAssertTrue(fonts.needsSyntheticBold(for: style(["pair"], 700, true)))
        XCTAssertFalse(fonts.needsSyntheticItalic(for: style(["pair"], 700, true)))
        XCTAssertFalse(fonts.needsSyntheticBold(for: style(["pair"], 700, false)))
        XCTAssertEqual(fonts.font(for: style(["italic only"], 400, false)).fontName, "Georgia-Italic", "A family's only face serves upright text too")
        XCTAssertFalse(fonts.needsSyntheticItalic(for: style(["italic only"], 400, false)))
        XCTAssertFalse(fonts.needsSyntheticItalic(for: style(["italic only"], 400, true)))
        XCTAssertEqual(fonts.font(for: style(["ranged"], 600, false)).fontName, "Georgia")
        XCTAssertFalse(fonts.needsSyntheticBold(for: style(["ranged"], 600, false)), "A face declaring 300–700 is its own bold")
        XCTAssertEqual(report, SectionReport())
    }

    func testFamilyNamesMatchCaseInsensitivelyFromRuleToFace() throws {
        let section = StyleTestSupport.xhtml(body: #"<p id="p">x</p><p id="q">y</p>"#, css: """
            @font-face { font-family: "Book Face"; src: url(fonts/g.ttf) }
            #p { font-family: BOOK   FACE, monospace }
            #q { font-family: 'book face', monospace; font-weight: bold }
            """)
        let book = try StyleTestSupport.publication(section: section, files: ["fonts/g.ttf": try CSSCascadeSupport.fontFile("Georgia")])
        let fonts = FontRegistry(publication: book)
        let document = try ContentDocument.parse(Data(section.utf8), path: "OPS/one.xhtml")
        var report = SectionReport()
        let sheets = SectionStyles.load(for: document, publication: book, fonts: fonts, report: &report)
        let styles = StyleTestSupport.styleAll(document, StyleResolver(document: document, stylesheets: sheets, typography: NativeTypography(), fonts: fonts))
        XCTAssertEqual(fonts.font(for: styles[document.element(id: "p")!.order]!).fontName, "Georgia")
        XCTAssertEqual(fonts.font(for: styles[document.element(id: "q")!.order]!).fontName, "Georgia")
        XCTAssertTrue(fonts.needsSyntheticBold(for: styles[document.element(id: "q")!.order]!))
        XCTAssertEqual(report, SectionReport())
    }

    func testUnloadableFontDataFallsThroughToLaterSourcesAndFamilies() throws {
        let georgia = try CSSCascadeSupport.fontFile("Georgia")
        let fonts = try CSSCascadeSupport.registry(files: [
            "fonts/g.ttf": georgia, "fonts/magic.ttf": Data([0, 1, 0, 0] + [UInt8](repeating: 0xFF, count: 508)),
            "fonts/cut.ttf": georgia.prefix(2000), "fonts/empty.ttf": Data(), "fonts/page.ttf": Data("<html><body>Not found</body></html>".utf8),
            "fonts/otto.otf": Data("OTTO".utf8 + [UInt8](repeating: 0, count: 64)), "fonts/woff.woff": Data("wOFF".utf8 + [UInt8](repeating: 7, count: 64)),
            "fonts/woff2.woff2": Data("wOF2".utf8 + [UInt8](repeating: 7, count: 64)),
        ])
        var report = SectionReport()
        let broken = ["magic.ttf", "cut.ttf", "empty.ttf", "page.ttf", "otto.otf", "woff.woff", "woff2.woff2"]
        fonts.register(broken.map { CSSFontFace(family: $0, sources: ["OPS/fonts/\($0)"]) }, report: &report)
        XCTAssertEqual(report.unreadableResources, broken.count, "Each face with no loadable source is reported")
        XCTAssertFalse(report.stylesTruncated)
        for family in broken {
            let font = fonts.font(for: CSSCascadeSupport.fontStyle([family, "monospace"]))
            XCTAssertTrue(CTFontGetSymbolicTraits(font as CTFont).contains(.traitMonoSpace), "\(family) falls through to the next family")
        }
        fonts.register([CSSFontFace(family: "recovered", sources: broken.map { "OPS/fonts/\($0)" } + ["OPS/fonts/missing.ttf", "OPS/fonts/g.ttf"])],
                       report: &report)
        XCTAssertEqual(report.unreadableResources, broken.count, "A face with one loadable source is not a failure")
        XCTAssertEqual(fonts.font(for: CSSCascadeSupport.fontStyle(["recovered", "monospace"])).fontName, "Georgia")
    }

    /// EPUB Reading Systems 3.3 §6.3: a reading system "MUST support TrueType, OpenType, WOFF, and
    /// WOFF2 font resources referenced from @font-face rules."
    func testAWOFFFontLoads() throws {
        let woff = try CSSCascadeSupport.woff(from: try CSSCascadeSupport.fontFile("Georgia"))
        XCTAssertTrue(FontRegistry.isFontData(woff))
        let fonts = try CSSCascadeSupport.registry(files: ["fonts/g.woff": woff])
        var report = SectionReport()
        fonts.register([CSSFontFace(family: "wrapped", sources: ["OPS/fonts/g.woff"])], report: &report)
        XCTAssertEqual(report.unreadableResources, 0)
        XCTAssertEqual(fonts.font(for: CSSCascadeSupport.fontStyle(["wrapped", "monospace"])).fontName, "Georgia")
    }

    /// `FontRegistry`: fonts are "decoded from the archive, IDPF/Adobe obfuscation already removed
    /// by `EPUBReading`". EPUB 3.3 §4.3: the first 1040 bytes are XORed with the SHA-1 of the
    /// publication's unique identifier.
    func testAnObfuscatedFontLoads() throws {
        let font = try CSSCascadeSupport.fontFile("Georgia")
        let key = Array(Insecure.SHA1.hash(data: Data("test-book".utf8)))
        var obfuscated = [UInt8](font)
        for index in 0..<min(1040, obfuscated.count) { obfuscated[index] ^= key[index % key.count] }
        XCTAssertFalse(FontRegistry.isFontData(Data(obfuscated)), "The stored bytes are not a font until they are decoded")
        var files = try Fixture.files()
        files["OPS/one.xhtml"] = Data(StyleTestSupport.xhtml(body: "<p>x</p>").utf8)
        files["OPS/fonts/g.ttf"] = Data(obfuscated)
        files["META-INF/encryption.xml"] = Data("""
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">\
            <EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><CipherData><CipherReference URI="OPS/fonts/g.ttf"/></CipherData>\
            </EncryptedData></encryption>
            """.utf8)
        let fonts = FontRegistry(publication: try EPUBPublication.open(data: Fixture.archive(files)))
        var report = SectionReport()
        fonts.register([CSSFontFace(family: "obfuscated", sources: ["OPS/fonts/g.ttf"])], report: &report)
        XCTAssertEqual(report, SectionReport())
        XCTAssertEqual(fonts.font(for: CSSCascadeSupport.fontStyle(["obfuscated", "monospace"])).fontName, "Georgia")
    }

    func testFacesPastTheBooksFontBudgetAreDroppedAsTruncation() throws {
        let font = try CSSCascadeSupport.smallFontFile()
        var files: [String: Data] = [:]
        for index in 0...FontRegistry.maximumFonts { files["fonts/\(index).ttf"] = font }
        let fonts = try CSSCascadeSupport.registry(files: files)
        var report = SectionReport()
        fonts.register((0..<FontRegistry.maximumFonts).map { CSSFontFace(family: "f\($0)", sources: ["OPS/fonts/\($0).ttf"]) }, report: &report)
        XCTAssertEqual(report, SectionReport(), "\(FontRegistry.maximumFonts) font files are within the budget")
        fonts.register([CSSFontFace(family: "over", sources: ["OPS/fonts/\(FontRegistry.maximumFonts).ttf"])], report: &report)
        XCTAssertTrue(report.stylesTruncated, "A face past the budget is a dropped style")
        XCTAssertEqual(report.unreadableResources, 0, "…not an unreadable resource")
        let last = fonts.font(for: CSSCascadeSupport.fontStyle(["f\(FontRegistry.maximumFonts - 1)", "monospace"]))
        XCTAssertFalse(CTFontGetSymbolicTraits(last as CTFont).contains(.traitMonoSpace), "The last face within the budget loaded")
        let over = fonts.font(for: CSSCascadeSupport.fontStyle(["over", "monospace"]))
        XCTAssertTrue(CTFontGetSymbolicTraits(over as CTFont).contains(.traitMonoSpace), "The face past it falls through")
        fonts.register([CSSFontFace(family: "again", sources: ["OPS/fonts/0.ttf"])], report: &report)
        let again = fonts.font(for: CSSCascadeSupport.fontStyle(["again", "monospace"]))
        XCTAssertFalse(CTFontGetSymbolicTraits(again as CTFont).contains(.traitMonoSpace), "A file already loaded costs nothing more")
    }
}
