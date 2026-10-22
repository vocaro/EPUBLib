import EPUBCore
import EPUBReading
import EPUBTestSupport
@testable import EPUBViewing
import Foundation
import XCTest

/// CSS Custom Properties for Cascading Variables 1 (#119): custom properties that cascade and
/// inherit, `var()` with its fallbacks, substitution at computed-value time, cycles, and what is
/// invalid at computed-value time. Expected values are the specification's examples and those of
/// the WPT files named in each test (web-platform-tests/wpt, css/css-variables).
final class CSSCustomPropertyTests: XCTestCase {
    private let red = CSSCascadeSupport.color(1, 0, 0), lime = CSSCascadeSupport.color(0, 1, 0), blue = CSSCascadeSupport.color(0, 0, 1)

    private func styled(_ body: String, css: String = "", dark: Bool = false) throws -> StyledDocument {
        try CSSCascadeSupport.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: dark))
    }

    // MARK: Cascade and inheritance

    /// §2's example: a custom property is declared on any element, cascades, and inherits.
    func testCustomPropertiesCascadeAndInheritLikeOtherInheritedProperties() throws {
        let result = try styled("""
            <p id="p"><span id="s1">a</span></p><div id="d"><span id="s2">b</span></div>
            <div id="alert"><span id="s3">c</span><p id="q"><span id="s4">d</span></p></div>
            """, css: """
            :root { --color: #0000ff; }
            div { --color: #00ff00; }
            #alert { --color: #ff0000; }
            * { color: var(--color); }
            """)
        XCTAssertEqual(result.style("s1").color, blue, "Inherited from the root element")
        XCTAssertEqual(result.style("s2").color, lime, "Set on its own div")
        XCTAssertEqual(result.style("s3").color, red, "Set on #alert, whose rule is more specific")
        XCTAssertEqual(result.style("s4").color, red, "Inherited from #alert")
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("q"), "--color"), "#ff0000")
    }

    /// §2: names are case-sensitive, compared code point by code point
    /// (css-vars-custom-property-case-sensitive-001.html).
    func testNamesAreCaseSensitive() throws {
        let result = try styled(#"<p id="a">a</p><p id="b">b</p><p id="c">c</p>"#, css: """
            :root { --accent: #ff0000; --ACCENT: #00ff00; --Accent: #0000ff }
            #a { color: var(--ACCENT) } #b { color: var(--accent) } #c { color: var(--aCCENT, #0000ff) }
            """)
        XCTAssertEqual(result.style("a").color, lime)
        XCTAssertEqual(result.style("b").color, red)
        XCTAssertEqual(result.style("c").color, blue, "--aCCENT is none of the three")
    }

    /// `!important`, origins and the `style` attribute order custom properties as they do any
    /// other (CSS Cascade 4 §6), and a `style` attribute may declare and use them.
    func testImportanceAndTheStyleAttributeCascadeCustomProperties() throws {
        let result = try styled("""
            <p id="i" class="k">i</p><p id="s" style="--x: #00ff00">s</p><p id="si" class="k" style="--x: #00ff00">si</p>
            <p id="sii" class="k" style="--x: #00ff00 !important">sii</p><p id="own" style="--w: 30px; width: var(--w)">own</p>
            """, css: """
            p { color: var(--x) }
            .k { --x: #0000ff !important }
            #i, #s, #si, #sii { --x: #ff0000 }
            """)
        XCTAssertEqual(result.style("i").color, blue, "An !important declaration beats a more specific one")
        XCTAssertEqual(result.style("s").color, lime, "The style attribute beats author rules")
        XCTAssertEqual(result.style("si").color, blue, "An !important rule beats the style attribute")
        XCTAssertEqual(result.style("sii").color, lime, "An !important style attribute beats !important rules")
        XCTAssertEqual(result.style("own").width, .points(30))
    }

    /// CSS-wide keywords are cascaded as for any property and never substituted (§2;
    /// variable-definition-keywords.html): `initial` is the guaranteed-invalid value, and
    /// `inherit`, `unset` and `revert` take the parent's value.
    func testCSSWideKeywordsInCustomProperties() throws {
        let result = try styled("""
            <div style="--var: 20px;"><div id="inherit" style="--var: inherit;">a</div></div>
            <div style="--var: 20px;"><div id="initial" style="--var: initial;">b</div></div>
            <div style="--var: 20px;"><div id="unset" style="--var: unset;">c</div></div>
            <div style="--var: 20px;"><div id="revert" style="--var: revert;">d</div></div>
            <div style="--var: 20px;"><div id="layer" style="--var: revert-layer;">e</div></div>
            """, css: "div > div { --var: 10px; margin-left: var(--var, 1px) }")
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("inherit"), "--var"), "20px")
        XCTAssertNil(CSSCustomPropertySupport.value(result.style("initial"), "--var"))
        XCTAssertEqual(result.style("initial").margin.left, .points(1), "The guaranteed-invalid value takes the fallback")
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("unset"), "--var"), "20px")
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("revert"), "--var"), "20px")
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("layer"), "--var"), "20px", "Layers are flattened, so revert-layer is revert")
    }

    /// `all` resets every property but `direction` and custom properties (§2).
    func testAllLeavesCustomPropertiesAlone() throws {
        let result = try styled(#"<div style="--gap: 3px"><div id="reset"><p id="p">x</p></div></div>"#,
                                css: "#reset { all: initial } #p { margin-left: var(--gap) }")
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("reset"), "--gap"), "3px")
        XCTAssertEqual(result.style("p").margin.left, .points(3))
    }

    /// An empty value is valid and is not the guaranteed-invalid value (§2.2).
    func testAnEmptyValueIsValid() throws {
        let result = try styled(#"<p id="p" style="--empty:; --space: ; margin-left: var(--empty) 4px var(--space); margin-right: var(--empty, 9px)">x</p>"#)
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("p"), "--empty"), "")
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("p"), "--space"), "")
        XCTAssertEqual(result.style("p").margin.left, .points(4))
        XCTAssertEqual(result.style("p").margin.right, .zero, "An empty value is substituted, not the fallback: nothing is a margin")
    }

    // MARK: var()

    /// Fallbacks (§3): used when the property is the guaranteed-invalid value, empty when the
    /// comma has nothing after it, holding commas of their own, and nested.
    func testFallbacks() throws {
        let result = try styled(#"<p id="p">x</p><p id="q">y</p>"#, css: """
            :root { --set: 5px }
            #p { margin-left: var(--missing, 7px); margin-right: var(--missing,) 3px; text-indent: var(--set, 9px);
                 width: var(--a, var(--b, var(--c, 11px))); font-family: var(--missing, "Gill Sans", serif) }
            #q { margin-left: var(--missing, var(--set)); margin-right: var(--missing, var(--also-missing)) }
            """)
        XCTAssertEqual(result.style("p").margin.left, .points(7))
        XCTAssertEqual(result.style("p").margin.right, .points(3), "An empty fallback")
        XCTAssertEqual(result.style("p").textIndent, .points(5), "The fallback of a defined property is not used")
        XCTAssertEqual(result.style("p").width, .points(11), "Nested fallbacks")
        XCTAssertEqual(result.style("p").fontFamilies, ["gill sans", "serif"], "Everything after the first comma is the fallback")
        XCTAssertEqual(result.style("q").margin.left, .points(5), "A var() in a fallback")
        XCTAssertEqual(result.style("q").margin.right, .zero, "Invalid at computed-value time: unset, margins' initial 0")
    }

    /// Substitution is of tokens, not text (§3): `var(--n)px` is a number and an identifier,
    /// not a dimension. Into `calc()`, it is one value among the others.
    func testSubstitutionIsOfTokensIntoAnyValueIncludingCalc() throws {
        let result = try styled(#"<p id="p">x</p><p id="q">y</p>"#, css: """
            :root { --n: 12; --gap: 12px; --sum: 2px + 3px; --half: 50% }
            #p { width: 8px; width: var(--n)px; padding-left: calc(var(--gap) * 2); padding-right: calc(var(--sum)) }
            #q { margin-left: calc(var(--n) * 1px); width: calc(var(--half) - 10px) }
            """)
        XCTAssertEqual(result.style("p").width, .auto, "12 then px is invalid at computed-value time, so unset")
        XCTAssertEqual(result.style("p").padding.left, .points(24))
        XCTAssertEqual(result.style("p").padding.right, .points(5))
        XCTAssertEqual(result.style("q").margin.left, .points(12))
        XCTAssertEqual(result.style("q").width, .percent(50 - 10.0 / 6), "A percentage less a length, approximated against the nominal viewport")
    }

    /// A shorthand with a `var()` sets each of its longhands pending, and the shorthand is
    /// parsed once substituted (§3; variable-substitution-variable-declaration.html's #target1,
    /// variable-reference-shorthands.html). Sides by flow follow the element's direction.
    func testShorthandsAndLogicalSidesAreSubstitutedAsAWhole() throws {
        let result = try styled("""
            <p id="margin">a</p><p id="border">b</p><p id="font">c</p><p id="mixed">d</p>
            <p id="rtl" style="direction: rtl">e</p><p id="dir" style="--dir: rtl">f</p>
            """, css: """
            #margin { margin: var(--var2); --var2: var(--var1) 10px; --var1: var(--var0) 13px 17px; --var0: 23px; }
            #border { --b: 2px dashed #ff0000; border: var(--b) }
            #font { --f: italic 700 20px/1.5 Georgia, serif; font: var(--f) }
            #mixed { --m: 1px; margin: var(--m) 5px }
            #rtl, #dir { --s: 6px; margin-inline-start: var(--s) }
            #dir { direction: var(--dir) }
            """)
        let margin = result.style("margin").margin
        XCTAssertEqual([margin.top, margin.right, margin.bottom, margin.left], [.points(23), .points(13), .points(17), .points(10)])
        XCTAssertEqual(CSSCustomPropertySupport.value(result.style("margin"), "--var2"), "23px 13px 17px 10px")
        let border = result.style("border").border
        XCTAssertEqual(border.left, ComputedStyle.Border(width: 2, style: .dashed, color: red))
        XCTAssertEqual(border.top, border.left)
        let font = result.style("font")
        XCTAssertEqual([font.isItalic ? 1 : 0, font.fontWeight], [1, 700])
        XCTAssertEqual(font.fontSize, 20)
        XCTAssertEqual(font.lineHeight, .multiple(1.5))
        XCTAssertEqual(font.fontFamilies, ["georgia", "serif"])
        XCTAssertEqual(result.style("mixed").margin.left, .points(5))
        XCTAssertEqual(result.style("mixed").margin.top, .points(1))
        XCTAssertEqual([result.style("rtl").margin.right, result.style("rtl").margin.left], [.points(6), .zero])
        XCTAssertEqual(result.style("dir").direction, .rtl)
        XCTAssertEqual([result.style("dir").margin.right, result.style("dir").margin.left], [.points(6), .zero],
                       "A direction from var() maps the sides by flow")
    }

    /// The name argument is itself substituted, then parsed as a `<custom-property-name>`
    /// (§3's example; var-parsing.html, variable-reference.html).
    func testTheNameArgumentIsSubstitutedThenParsed() throws {
        let result = try styled(#"<p id="p">x</p><p id="q">y</p>"#, css: """
            :root { --other: 10px; --myvar: --other; }
            #p { width: var(var(--myvar)); margin-left: var({--other}); margin-right: var(--other 1px, 4px) }
            #q { width: 3px; width: var(prop); margin-left: var(prop, 6px) }
            """)
        XCTAssertEqual(result.style("p").width, .points(10))
        XCTAssertEqual(result.style("p").margin.left, .points(10), "A name in braces")
        XCTAssertEqual(result.style("p").margin.right, .points(4), "A name argument that is not one name takes the fallback")
        XCTAssertEqual(result.style("q").width, .auto, "var(prop) is valid at parse time and invalid at computed-value time")
        XCTAssertEqual(result.style("q").margin.left, .points(6))
    }

    /// What is invalid at parse time is dropped and an earlier declaration stands; what is
    /// invalid at computed-value time is `unset` (§3.1, and its example).
    func testInvalidAtParseTimeAndAtComputedValueTime() throws {
        let result = try styled(#"<div id="parent"><p id="p">x</p><p id="q">y</p><p id="r">z</p></div>"#, css: """
            :root { --not-a-color: 20px; }
            #parent { color: #0000ff }
            #p { background-color: #ff0000; background-color: var(--not-a-color); color: #ff0000; color: var(--not-a-color) }
            #q { margin-left: 5px; margin-left: var(); margin-right: 5px; margin-right: var(, 1px); text-indent: 5px; text-indent: var(--x) ! }
            #r { margin-left: 5px; margin-left: var(--missing); margin-right: 5px; margin-right: scale(var(--#invalid)) }
            #r { color: #00ff00 }
            """)
        XCTAssertNil(result.style("p").backgroundColor, "Not inherited: unset is initial, transparent")
        XCTAssertEqual(result.style("p").color, blue, "Inherited: unset is the parent's")
        XCTAssertEqual(result.style("q").margin.left, .points(5), "var() without a name is invalid at parse time")
        XCTAssertEqual(result.style("q").margin.right, .points(5))
        XCTAssertEqual(result.style("q").textIndent, .points(5), "A top-level ! is not a <declaration-value>")
        XCTAssertEqual(result.style("r").margin.left, .zero)
        XCTAssertEqual(result.style("r").margin.right, .zero)
        XCTAssertEqual(result.style("r").color, lime, "variable-invalid-recovery.html: the next rule still applies")
    }

    /// A value that is a CSS-wide keyword once substituted is that keyword (§3; revert-in-fallback.html,
    /// variable-css-wide-keywords-after-substitution.html).
    func testAKeywordFromSubstitutionActsAsThatKeyword() throws {
        let result = try styled(#"<div style="margin-left: 6px; --y: 4px"><p id="p">x</p></div>"#, css: """
            #p { margin-left: var(--unknown, inherit); display: inline; display: var(--unknown, revert);
                 --x: var(--unknown, revert); --y: var(--unknown, inherit); --z: var(--empty-unknown,) initial }
            """)
        let p = result.style("p")
        XCTAssertEqual(p.margin.left, .points(6))
        XCTAssertEqual(p.display, .block, "revert is the user agent's display of a p")
        XCTAssertNil(CSSCustomPropertySupport.value(p, "--x"), "The parent has no --x to revert to")
        XCTAssertEqual(CSSCustomPropertySupport.value(p, "--y"), "4px")
        XCTAssertNil(CSSCustomPropertySupport.value(p, "--z"), "initial, once substituted, is the guaranteed-invalid value")
    }

    // MARK: Cycles

    /// A custom property in a dependency cycle is invalid at computed-value time, and only the
    /// references a substitution follows count (variable-cycles.html, every case).
    func testDependencyCycles() throws {
        let cases: [(declarations: [String], invalid: [String], valid: [String])] = [
            (["--a:var(--a)"], ["--a"], []),
            (["--a:var(--b)", "--b:var(--a)"], ["--a", "--b"], []),
            (["--a:var(--b, cycle)", "--b:var(--c, cycle)", "--c:var(--a, cycle)"], ["--a", "--b", "--c"], []),
            (["--x:var(--y, valid)", "--y:var(--a, valid)", "--a:var(--b, cycle)", "--b:var(--c, cycle)", "--c:var(--a, cycle)"],
             ["--a", "--b", "--c"], ["--x", "--y"]),
            (["--x:var(--a, valid)", "--a:var(--b, cycle)", "--b:var(--c, cycle)", "--c:var(--a, cycle) var(--y)", "--y:valid"],
             ["--a", "--b", "--c"], ["--x", "--y"]),
            (["--x:var(--a, valid)", "--a:var(--b, cycle)", "--b:var(--c, cycle) var(--y)", "--c:var(--a, cycle)", "--y:valid"],
             ["--a", "--b", "--c"], ["--x", "--y"]),
            (["--x:var(--a, valid)", "--a:var(--b, cycle)", "--b:var(--c, cycle)", "--c:var(--a, cycle) var(--y)", "--y:var(--z)", "--z:valid"],
             ["--a", "--b", "--c"], ["--x", "--y", "--z"]),
            (["--x:var(--a, valid)", "--a:var(--b, cycle)", "--b:var(--c, cycle) var(--a, cycle)", "--c:var(--d, cycle)", "--d:var(--b, cycle)"],
             ["--a", "--b", "--c", "--d"], ["--x"]),
            (["--x:var(--a, valid)", "--a:var(--b, cycle)", "--b:var(--c, cycle)", "--c:var(--d, cycle) var(--a, cycle)",
              "--d:var(--b, cycle) var(--y)", "--y:valid"], ["--a", "--b", "--c", "--d"], ["--x", "--y"]),
            (["--x:var(--a, valid)", "--a:var(--b, cycle) var(--y, valid) var(--c, cycle)", "--b:var(--a, cycle) ", "--c:var(--d, cycle)",
              "--d:var(--a, cycle)", "--y:valid"], ["--a", "--b", "--c", "--d"], ["--x", "--y"]),
            // The fallbacks are not used, so they make no cycle (csswg-drafts#11500).
            (["--x:var(--a, valid)", "--a:var(--y, var(--b, cycle))", "--b:var(--y, var(--c, cycle))", "--c:var(--y, var(--a, cycle))", "--y:valid"],
             [], ["--a", "--b", "--c", "--x", "--y"]),
        ]
        for (index, test) in cases.enumerated() {
            // In every order: which properties are in a cycle does not depend on the order they are declared in.
            for declarations in [test.declarations, test.declarations.reversed()] {
                let style = try styled(#"<div id="d" style="\#((declarations + ["--sanity:valid"]).joined(separator: ";"))">x</div>"#).style("d")
                for name in test.invalid { XCTAssertNil(CSSCustomPropertySupport.value(style, name), "case \(index): \(name) in \(declarations)") }
                for name in test.valid { XCTAssertNotNil(CSSCustomPropertySupport.value(style, name), "case \(index): \(name) in \(declarations)") }
                XCTAssertEqual(CSSCustomPropertySupport.value(style, "--sanity"), "valid")
            }
        }
    }

    /// variable-substitution-variable-declaration.html: references between custom properties,
    /// through fallbacks and across inheritance.
    func testCustomPropertiesReferringToEachOther() throws {
        let result = try styled("""
            <div id="target2parent"><div id="target2">a</div></div><div id="target3">b</div><div id="target4">c</div>
            <div id="target5">d</div><div id="target6">e</div><div id="target7">f</div><div id="target8">g</div>
            <div id="target9">h</div><div id="target10parent"><div id="target10">i</div></div>
            """, css: """
            #target2parent { --var2: var(--var1, fallback); --var1: var(--var2, fallback); }
            #target2 { --var1: good; }
            #target3 { --var2: var(--var1, 3px); --var1: var(--var0, 5px); }
            #target4 { --varA: var(--varB); --varB: var(--varA); --varC: var(--varB,13px); }
            #target5 { --varA: var(--varB); --varB: var(--varA) var(--varC); --varC: var(--varB,13px); }
            #target6 { --varA: var(--varB); --varB: var(--varA) var(--varDoesNotExist,var(--varC)); --varC: var(--varB,13px); }
            #target7 { --varDoesExist: 5px; --varA: var(--varB); --varB: var(--varA) var(--varDoesExist,var(--varC)); --varC: var(--varB,13px); }
            #target8 { --varA: var(--varA, 9px); --varB: var(--varA, 7px); }
            #target9 { --varA: good; --varB: very var(--varA, var(--varC)); --varC: var(--varB); }
            #target10parent { --varA: good; --varB: Also good; --varC: another good one; }
            #target10 { --varA: var(--varB); --varB: var(--varA); --varC: var(--varB); }
            """)
        let expected: [(String, String, String?)] = [
            ("target2parent", "--var1", nil), ("target2parent", "--var2", nil), ("target2", "--var1", "good"), ("target2", "--var2", nil),
            ("target3", "--var1", "5px"), ("target3", "--var2", "5px"),
            ("target4", "--varA", nil), ("target4", "--varB", nil), ("target4", "--varC", "13px"),
            ("target5", "--varA", nil), ("target5", "--varB", nil), ("target5", "--varC", nil),
            ("target6", "--varA", nil), ("target6", "--varB", nil), ("target6", "--varC", "13px"),
            ("target7", "--varA", nil), ("target7", "--varB", nil), ("target7", "--varC", "13px"),
            ("target8", "--varA", nil), ("target8", "--varB", "7px"),
            ("target9", "--varA", "good"), ("target9", "--varB", "very good"), ("target9", "--varC", "very good"),
            ("target10", "--varA", nil), ("target10", "--varB", nil), ("target10", "--varC", nil),
        ]
        for (id, name, value) in expected {
            XCTAssertEqual(CSSCustomPropertySupport.value(result.style(id), name), value, "#\(id) \(name)")
        }
    }

    /// §3's example of a cycle through `calc()`, and a property that refers into a cycle.
    func testACycleIsInvalidAndAReferenceToItTakesItsFallback() throws {
        let p = try styled(#"<p id="p">x</p>"#, css: """
            :root { --one: calc(var(--two) + 20px); --two: calc(var(--one) - 20px); }
            #p { width: var(--one, 9px); margin-left: 2px; margin-left: var(--two) }
            """).style("p")
        XCTAssertNil(CSSCustomPropertySupport.value(p, "--one"))
        XCTAssertNil(CSSCustomPropertySupport.value(p, "--two"))
        XCTAssertEqual(p.width, .points(9))
        XCTAssertEqual(p.margin.left, .zero)
    }

    // MARK: Where custom properties apply

    /// Pseudo-elements inherit their element's custom properties and declare their own
    /// (variable-pseudo-element.html).
    func testPseudoElementsInheritAndDeclareCustomProperties() throws {
        let result = try styled(#"<div id="div1">div1</div><div id="div2">div2</div><div id="div3">div3</div>"#, css: """
            :root { --color: #00ff00; --color2: #ff0000; }
            div::before { content: '[before]'; } div::after { content: '[after]'; }
            #div1 { color: #ff0000; } #div1::before, #div1::after { color: var(--color2); --color2: #00ff00; }
            #div2 { color: var(--color2); } #div2::before, #div2::after { color: var(--color); }
            #div3 { color: var(--color); } #div3::before, #div3::after { --color: #ff0000; }
            """)
        for id in ["div1", "div2", "div3"] {
            let generated = try XCTUnwrap(result.style(id).generated, id)
            XCTAssertEqual(generated.before?.color, lime, id)
            XCTAssertEqual(generated.after?.color, lime, id)
        }
    }

    /// §2's example of strings kept apart for translation, substituted into `content`.
    func testCustomPropertiesInGeneratedContent() throws {
        let result = try styled(#"<p><a id="a" href="http://example.com/">link</a></p>"#, css: """
            :root, :root:lang(en) { --external-link: "external link"; }
            :root:lang(el) { --external-link: "εξωτερικός σύνδεσμος"; }
            a[href^="http"]::after { content: " (" var(--external-link) ")" }
            """)
        XCTAssertEqual(result.style("a").generated?.after?.content, [.string(" ("), .string("external link"), .string(")")])
    }

    /// `@supports` takes a custom property declaration, and a declaration with a valid `var()`.
    func testSupportsConditions() throws {
        let result = try styled(#"<p id="p">x</p>"#, css: """
            @supports (--x: y) { #p { padding-left: 1px } }
            @supports (--empty:) { #p { padding-right: 2px } }
            @supports (color: var(--x)) { #p { padding-top: 3px } }
            @supports (color: var()) { #p { padding-bottom: 4px } }
            @supports (--: y) { #p { text-indent: 5px } }
            """)
        let padding = result.style("p").padding
        XCTAssertEqual([padding.left, padding.right, padding.top, padding.bottom], [.points(1), .points(2), .points(3), .zero])
        XCTAssertEqual(result.style("p").textIndent, .zero, "-- is reserved")
    }

    /// HTML's presentational attributes are read by HTML's rules and substitute nothing; SVG's
    /// are CSS values (variable-presentation-attribute.html).
    func testPresentationalAttributes() throws {
        let result = try styled("""
            <div style="--c: #ff0000; --w: 40px"><font id="font" color="var(--c)">x</font>
            <svg xmlns="http://www.w3.org/2000/svg" id="svg" width="var(--w)" height="10"/></div>
            """)
        XCTAssertNil(result.style("font").color)
        XCTAssertEqual(result.style("svg").width, .points(40))
    }

    /// What paints follows the reader's appearance, and the custom properties substituted into
    /// it with it; everything else is resolved as in the light appearance, the custom properties
    /// substituted into it included, so that a section's characters are the same in both (#130).
    func testAppearanceMediaDecideCustomPropertiesForWhatPaintsAlone() throws {
        let body = #"<p id="p">x</p><p id="q">y</p><img id="img" src="a.png" alt=""/>"#
        let css = """
            :root { --fg: #ff0000; --c: #ff0000 }
            @media (prefers-color-scheme: dark) { :root { --fg: transparent; --gap: 9px; --invert: invert(100%); --label: "dark" } }
            @media (prefers-color-scheme: light) { :root { --pad: 4px; --c: transparent } }
            #p { color: var(--fg); margin-left: var(--gap, 1px); padding-left: var(--pad, 0px) }
            #q { color: var(--c) }
            #q::before { content: var(--label, "light") }
            #img { filter: var(--invert, none) }
            """
        let light = try styled(body, css: css), dark = try styled(body, css: css, dark: true)
        XCTAssertEqual(light.style("p").color, red)
        XCTAssertEqual(dark.style("p").color, CSSCascadeSupport.color(0, 0, 0, 0), "Transparent text stays so in dark appearance")
        XCTAssertEqual([light, dark].map { $0.style("p").margin.left }, [.points(1), .points(1)], "A dark-only --gap does not set a margin")
        XCTAssertEqual([light, dark].map { $0.style("p").padding.left }, [.points(4), .points(4)], "A light-only --pad sets one in both")
        XCTAssertEqual(light.style("q").color, CSSCascadeSupport.color(0, 0, 0, 0))
        XCTAssertNil(dark.style("q").color, "Dark appearance: --c is #ff0000, and the reader's palette applies")
        XCTAssertEqual([light, dark].map { $0.style("q").generated?.before?.content }, [[.string("light")], [.string("light")]],
                       "Generated characters are the light appearance's")
        XCTAssertEqual([light, dark].map { $0.style("img").invertsColors }, [false, true])
    }
}

/// The bounds that keep a hostile book's custom properties from stalling the reader or
/// exhausting its memory: on one substitution, as browsers bound it (CSS Values 5
/// §long-substitution), and on a section (`StyleResolver.maximumSubstitutionWork`).
final class CSSCustomPropertyLimitTests: XCTestCase {
    private func styled(_ body: String, css: String) throws -> StyledDocument {
        try CSSCascadeSupport.styled(body, css: css)
    }

    /// The doubling of variable-exponential-blowup.html: each property twice the one before. One
    /// substitution may produce 65,536 component values, so the 16th is invalid and so is every
    /// one after it, and the work stays a small part of the section's budget.
    func testExponentialExpansionStopsAtTheBoundOnOneSubstitution() throws {
        var css = #"--v0: "Something really really really long";"#
        for index in 0..<30 { css += "--v\(index + 1): var(--v\(index)), var(--v\(index));" }
        var result: StyledDocument?
        let seconds = try TestCPUClock.measure {
            result = try styled(#"<p id="p">x</p>"#, css: ":root { \(css) } :root::before { content: var(--v31) } #p { --w: var(--v14) }")
        }
        let style = try XCTUnwrap(result).style("p")
        // Each is twice the one before, a comma and a space: 3 × 2ⁿ - 2 component values.
        XCTAssertEqual(style.customProperties?.light.values["--v14"]?.count, 3 * (1 << 14) - 2)
        XCTAssertEqual(style.customProperties?.light.values["--w"]?.count, 3 * (1 << 14) - 2)
        for index in 15...30 { XCTAssertNil(style.customProperties?.light.values["--v\(index)"], "--v\(index)") }
        let root = try XCTUnwrap(result).document.root
        XCTAssertNil(try XCTUnwrap(result).styles[root.order]?.generated, "content: var(--v31) is invalid, so normal")
        XCTAssertFalse(try XCTUnwrap(result).resolver.substitutionsTruncated)
        XCTAssertLessThan(seconds, 10, "CPU seconds")
    }

    /// A substituted value nests functions and blocks no deeper than a written one may.
    func testNestingFromSubstitutionIsBoundedAsWrittenNestingIs() throws {
        var css = "--d0: x;"
        for index in 0..<40 { css += "--d\(index + 1): f(var(--d\(index)));" }
        let style = try styled(#"<p id="p">x</p>"#, css: ":root { \(css) } #p { width: var(--d33, 3px) }").style("p")
        XCTAssertEqual(style.customProperties?.light.values["--d32"]?.depth, CSSParser.maximumNesting)
        XCTAssertNil(style.customProperties?.light.values["--d33"])
        XCTAssertEqual(style.width, .points(3))
    }

    /// A chain of references as long as a stylesheet can hold, declared so that each refers to
    /// one not yet resolved, resolves on the small stack of a background build: nothing recurses
    /// along it.
    func testALongChainOfReferencesNeedsNoDeepStack() throws {
        let count = 20_000
        let chain = (1...count).reversed().map { "--v\($0): var(--v\($0 - 1));" }.joined()
        let css = ":root { \(chain) --v0: 5px } #p { margin-left: var(--v\(count)) }"
        final class Box: @unchecked Sendable { var result: StyledDocument?; var error: Error?; let done = DispatchSemaphore(value: 0) }
        let box = Box()
        let thread = Thread {
            do { box.result = try CSSCascadeSupport.styled(#"<p id="p">x</p>"#, css: css) } catch { box.error = error }
            box.done.signal()
        }
        thread.stackSize = 448 * 1_024
        thread.start()
        box.done.wait()
        if let error = box.error { throw error }
        let result = try XCTUnwrap(box.result)
        XCTAssertEqual(result.style("p").margin.left, .points(5))
        XCTAssertFalse(result.resolver.substitutionsTruncated)
    }

    /// Many elements that each substitute a long value: the bound on a section stops them, the
    /// rest of their substitutions are invalid at computed-value time, and the section says so.
    func testTheSectionBoundStopsWorkThatEachElementRepeats() throws {
        var css = "--a0: x;"
        for index in 0..<14 { css += "--a\(index + 1): var(--a\(index)) var(--a\(index));" }
        let body = String(repeating: #"<p style="--x: var(--a14) y; margin-left: var(--x)">x</p>"#, count: 2_000) + #"<p id="last" style="--x: var(--a0)">z</p>"#
        var result: StyledDocument?
        let seconds = try TestCPUClock.measure { result = try styled(body, css: ":root { \(css) }") }
        let styled = try XCTUnwrap(result)
        XCTAssertTrue(styled.resolver.substitutionsTruncated)
        XCTAssertNil(styled.style("last").customProperties?.light.values["--x"], "Past the bound, substitution fails")
        XCTAssertLessThanOrEqual(styled.resolver.substitution.light.spentWork,
                                 StyleResolver.maximumSubstitutionWork + 2 * CSSSubstitution.maximumTokens + 64)
        XCTAssertLessThan(seconds, 20, "CPU seconds")
    }

    /// The bound on a section is disclosed with the rest of its styling that was too large.
    func testABuiltSectionDisclosesTheBound() throws {
        func report(_ body: String, css: String) throws -> SectionReport {
            let book = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css))
            return SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 0, typography: NativeTypography(),
                                                            fonts: FontRegistry(publication: book), rich: PlaceholderRichContent())).report
        }
        var doubling = "--a0: x;"
        for index in 0..<14 { doubling += "--a\(index + 1): var(--a\(index)) var(--a\(index));" }
        let element = #"<p style="--x: var(--a14) y; width: var(--x)">x</p>"#
        XCTAssertFalse(try report(String(repeating: element, count: 4), css: ":root { \(doubling) }").stylesTruncated, "Within the bound")
        XCTAssertTrue(try report(String(repeating: element, count: 100), css: ":root { \(doubling) }").stylesTruncated)
    }

    /// Elements that declare the same custom properties under the same parent share what they
    /// compute to, so a rule that sets one on every element costs one computation per level of
    /// distinct custom properties, not one per element.
    func testElementsThatDeclareTheSameCustomPropertiesShareThem() throws {
        let body = String(repeating: "<div><p>x <span>y</span></p></div>", count: 2_000)
        let result = try styled(body, css: ":root { --y: a } * { --x: var(--y) z; margin-left: var(--w, 1px) }")
        XCTAssertLessThan(result.resolver.substitution.light.spentWork, 1_000)
        let spans = result.document.nodes.filter { $0.isElement && $0.name == "span" }
        XCTAssertEqual(Set(spans.compactMap { result.styles[$0.order]?.customProperties.map(ObjectIdentifier.init) }).count, 1)
    }

    /// A book whose design system is built on custom properties, as a web framework's is: a few
    /// hundred on the root, components that declare their own, and chapters that set some in
    /// their `style` attributes, which nothing is shared with. It stays far within the bound.
    func testADesignSystemStaysFarWithinTheSectionBound() throws {
        var root = ""
        for index in 0..<300 { root += "--ds-token-\(index): \(index % 7)px;" }
        for index in 0..<40 { root += "--ds-color-\(index): #\(String(format: "%06x", index * 4_000));" }
        root += "--ds-primary: var(--ds-color-3); --ds-body-color: var(--ds-color-1); --ds-font: Georgia, serif;"
        let css = """
            :root { \(root) }
            body { color: var(--ds-body-color); font-family: var(--ds-font) }
            .card { --card-pad: var(--ds-token-3); --card-border: 1px solid var(--ds-primary); padding: var(--card-pad); border: var(--card-border) }
            .btn { --btn-pad-x: var(--ds-token-5); --btn-pad-y: var(--ds-token-2); --btn-color: var(--ds-primary);
                   padding: var(--btn-pad-y) var(--btn-pad-x); color: var(--btn-color) }
            section { margin-left: calc(var(--chapter, 1) * var(--ds-token-4)) }
            p { text-indent: var(--ds-token-6); margin: var(--ds-token-1) 0 }
            """
        let paragraph = "<p>Words <span class=\"btn\">act</span> and more words.</p>"
        let chapter = { (index: Int) in
            "<section style=\"--chapter: \(index)\"><h2>Chapter</h2><div class=\"card\">\(String(repeating: paragraph, count: 4))</div>"
                + String(repeating: paragraph, count: 30) + "</section>"
        }
        let result = try styled((0..<100).map(chapter).joined(), css: css)
        let spent = result.resolver.substitution.light.spentWork + result.resolver.substitution.appearance.spentWork
        print("Design system substitution work: \(spent) of \(StyleResolver.maximumSubstitutionWork) for each side")
        XCTAssertFalse(result.resolver.substitutionsTruncated)
        XCTAssertLessThan(spent, StyleResolver.maximumSubstitutionWork / 4)
    }
}

/// Reads computed custom properties as text, the way a browser serializes one.
enum CSSCustomPropertySupport {
    /// The light appearance's value of `name`, nil for the guaranteed-invalid value.
    static func value(_ style: ComputedStyle, _ name: String) -> String? {
        style.customProperties?.light.values[name].map { text($0.components) }
    }

    static func text(_ components: [CSSComponent]) -> String {
        components.map { component in
            switch component {
            case .token(let token): text(token)
            case .function(let name, let arguments): name + "(" + text(arguments) + ")"
            case .block(let open, let contents):
                open == .openCurly ? "{" + text(contents) + "}" : open == .openSquare ? "[" + text(contents) + "]" : "(" + text(contents) + ")"
            }
        }.joined()
    }

    private static func number(_ value: Double, _ isInteger: Bool) -> String { isInteger ? String(Int(value)) : String(value) }

    private static func text(_ token: CSSToken) -> String {
        switch token {
        case .ident(let value): value
        case .function(let name): name + "("
        case .atKeyword(let name): "@" + name
        case .hash(let value, _): "#" + value
        case .string(let value): "\"" + value + "\""
        case .url(let value): "url(" + value + ")"
        case .delim(let scalar): String(scalar)
        case .number(let value, let isInteger, _): number(value, isInteger)
        case .percentage(let value): number(value, value == value.rounded()) + "%"
        case .dimension(let value, let unit, let isInteger, _): number(value, isInteger) + unit
        case .whitespace: " "
        case .colon: ":"
        case .semicolon: ";"
        case .comma: ","
        case .badString, .badURL, .cdo, .cdc, .openSquare, .closeSquare, .openParen, .closeParen, .openCurly, .closeCurly: "?"
        }
    }
}
