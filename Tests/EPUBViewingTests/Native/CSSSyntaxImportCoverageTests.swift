@testable import EPUBViewing
import XCTest

/// `@import` (CSS Cascade 4 §2): its forms, conditions, placement and how its target resolves
/// inside the archive.
final class CSSSyntaxImportCoverageTests: XCTestCase {
    private func sheet(_ css: String) -> CSSStyleSheet { CSSSyntaxSupport.sheet(css, path: "OPS/css/main.css") }
    private func imports(_ css: String) -> [String] { sheet(css).imports.map(\.path) }

    func testEveryImportFormAndItsMediaCondition() {
        let sheet = sheet("""
            @charset "utf-8";
            @import "a.css";
            @import 'b.css' screen;
            @import url(c.css);
            @import url("d.css") screen and (orientation: portrait);
            @import url( 'e.css' ) (prefers-color-scheme: dark);
            @IMPORT URL(f.css) ALL;
            @import "g.css" print;
            @import "h.css" print, screen;
            @import "i.css" bogus!;
            @import "j.css" not all and (monochrome);
            @import/* c */"k.css"/* c */screen/* c */;
            @import;
            @import bogus;
            @import "l.css" {}
            @import url();
            @import "";
            @import "m.css" not (prefers-color-scheme: dark)
            """)
        XCTAssertEqual(sheet.imports, [
            CSSImport(path: "OPS/css/a.css", media: .all), CSSImport(path: "OPS/css/b.css", media: .all), CSSImport(path: "OPS/css/c.css", media: .all),
            CSSImport(path: "OPS/css/d.css", media: .all), CSSImport(path: "OPS/css/e.css", media: .dark), CSSImport(path: "OPS/css/f.css", media: .all),
            CSSImport(path: "OPS/css/h.css", media: .all), CSSImport(path: "OPS/css/j.css", media: .all), CSSImport(path: "OPS/css/k.css", media: .all),
            CSSImport(path: "OPS/css/m.css", media: .light),
        ])
        XCTAssertEqual(sheet.remoteReferences, 0)
        XCTAssertFalse(sheet.truncated)
    }

    func testImportLayerAndSupportsConditions() {
        XCTAssertEqual(imports("""
            @import "a.css" layer;
            @import "b.css" layer(base);
            @import "c.css" layer(base) screen;
            @import "d.css" supports(clear: both);
            @import "e.css" supports((clear: both) and (color: red));
            @import "f.css" supports(not (bogus: 1)) screen;
            @import "g.css" layer supports(clear: both) screen;
            @import "h.css" supports(bogus: 1);
            @import "i.css" supports(not (clear: both));
            @import "j.css" supports((clear: both) and (bogus: 1));
            @import "k.css" supports(clear: both) print;
            @import "l.css" supports();
            """), ["a", "b", "c", "d", "e", "f", "g"].map { "OPS/css/\($0).css" })
    }

    func testImportTargetsResolveAgainstTheImportingSheetAndStayInsideTheArchive() {
        XCTAssertEqual(imports("""
            @import "../fonts/f.css"; @import "./x.css"; @import "sub/y.css"; @import "my%20sheet.css"; @import "caf%C3%A9.css";
            @import "a.css?v=2"; @import "b.css#frag"; @import "c.css?v=2#frag"; @import "  d.css  "; @import "../../root.css";
            @import "../css/../css/./e.css";
            """), ["OPS/fonts/f.css", "OPS/css/x.css", "OPS/css/sub/y.css", "OPS/css/my sheet.css", "OPS/css/café.css", "OPS/css/a.css",
                   "OPS/css/b.css", "OPS/css/c.css", "OPS/css/d.css", "root.css", "OPS/css/e.css"])
        // Nothing may name a path outside the archive, whatever its spelling: `..` stops at the
        // container root and a leading `/` names it (EPUB Reading Systems 3.3 §4.1.1).
        let climbing = ["../../../etc/passwd": "etc/passwd", "%2e%2e/%2E%2E/%2e%2e/etc/passwd": "etc/passwd", "%2e%2e/%2e%2e/%2e%2e/x.css": "x.css",
                        "a/../../../../x.css": "x.css", "/etc/passwd": "etc/passwd", "/../../x.css": "x.css"]
        for (target, path) in climbing {
            XCTAssertEqual(imports("@import \"\(target)\";"), [path], target)
        }
        // What does not decode to a path an entry can have names nothing, an escaped slash among
        // it (https://github.com/vocaro/EPUBLib/issues/660).
        let hostile = ["%", "%zz", "%00", "a%00.css", "#", "?", "#frag", "?query", "sub\\\\z.css", "..\\\\..\\\\x.css", " ", "%C3", "/", "../../..",
                       "//example.invalid/x.css", "..%2F..%2F..%2Fetc%2Fpasswd", "sub%2Fy.css"]
        for target in hostile {
            let sheet = sheet("@import \"\(target)\"; p { clear: both }")
            XCTAssertEqual(sheet.imports, [], target)
            XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["p"], target)
        }
        XCTAssertEqual(imports("@import \":\";"), ["OPS/css/:"], "a colon alone is a file name, if an unlikely one")
    }

    func testRemoteAndOtherNonArchiveImportsAreCountedAndNeverBecomeArchivePaths() {
        let sheet = sheet("""
            @import "https://example.com/a.css"; @import url(http://example.com/b.css); @import "//cdn.example.com/c.css";
            @import "HTTPS://EXAMPLE.COM/d.css" screen; @import url("ftp://example.com/e.css"); @import "file:///etc/hosts";
            @import "https://example.com/print.css" print;
            @import url("data:text/css,p%7Bcolor%3Ared%7D"); @import "DATA:text/css,";
            p { clear: both }
            """)
        XCTAssertEqual(sheet.imports, [])
        XCTAssertEqual(sheet.remoteReferences, 6, "Six references leave the archive; the print one never applies and data: URLs are not remote")
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["p"])
    }

    func testAnImportAfterAnyStyleOrConditionalRuleIsIgnored() {
        XCTAssertEqual(imports("p { clear: both } @import 'a.css';"), [])
        XCTAssertEqual(imports("@media screen { p { clear: both } } @import 'a.css';"), [])
        XCTAssertEqual(imports("@supports (clear: both) { p { clear: both } } @import 'a.css';"), [])
        XCTAssertEqual(imports("@font-face { font-family: F; src: url(f.ttf) } @import 'a.css';"), [])
        XCTAssertEqual(imports("@import 'a.css'; p { clear: both } @import 'b.css';"), ["OPS/css/a.css"])
        XCTAssertEqual(imports("@media screen { @import 'a.css'; }"), [], "Not at top level")
        XCTAssertEqual(imports("@supports (clear: both) { @import 'a.css'; }"), [])
        XCTAssertEqual(imports("p { @import 'a.css'; clear: both }"), [])
        XCTAssertEqual(imports("@charset 'x'; @layer base, theme; @import 'a.css'; @import 'b.css';"), ["OPS/css/a.css", "OPS/css/b.css"],
                       "@charset and @layer statements may precede @import")
        XCTAssertEqual(imports("<!-- @import 'a.css'; --> @import 'b.css';"), ["OPS/css/a.css", "OPS/css/b.css"])
    }

    func testAnImportAfterANamespaceRuleIsIgnored() {
        // CSS Cascade 4 §2: "Any @import rules must precede all other valid at-rules and style
        // rules in a style sheet (ignoring @charset and @layer statement rules) … or else the
        // @import rule is invalid." CSS Namespaces §3 places @namespace after every @import.
        XCTAssertEqual(imports(#"@namespace epub "http://www.idpf.org/2007/ops"; @import "late.css"; p { clear: both }"#), [])
        XCTAssertEqual(imports(#"@import "a.css"; @namespace svg "http://www.w3.org/2000/svg"; @import "b.css";"#), ["OPS/css/a.css"])
        XCTAssertEqual(imports(#"@namespace svg; @import "a.css";"#), ["OPS/css/a.css"], "A malformed @namespace is no rule")
        XCTAssertEqual(imports(#"@import "a.css"; @import "b.css"; @namespace svg "http://www.w3.org/2000/svg"; svg|a { clear: both }"#),
                       ["OPS/css/a.css", "OPS/css/b.css"])
    }

    func testTheImportsEndWithExactlyTheRulesChromiumKeeps() {
        // #603: the section of @import rules ends at the first rule that is valid, by the same
        // tests that decide whether the rule is kept, as in Chromium.
        let a = ["OPS/css/a.css"]
        // Rules this parser once refused, which Chromium keeps.
        XCTAssertEqual(imports("& { clear: both } @import 'a.css';"), [], "A top-level nesting selector")
        XCTAssertEqual(imports("a:-webkit-full-screen { clear: both } @import 'a.css';"), [], "A -webkit- pseudo-class Chromium knows")
        XCTAssertEqual(imports("p::-webkit-scrollbar { width: 0 } @import 'a.css';"), [], "Any ::-webkit- pseudo-element")
        // Rules this parser once kept, which Chromium drops.
        XCTAssertEqual(imports("p::no-such-element { clear: both } @import 'a.css';"), a, "An unknown pseudo-element")
        XCTAssertEqual(imports("p:not(::before) { clear: both } @import 'a.css';"), a, "A pseudo-element inside :not()")
        // Known at-rules with a prelude their grammar does not take.
        for rule in ["@supports bogus {}", "@supports (clear: both) and {}", "@keyframes {}", "@keyframes a b {}", "@keyframes none {}",
                     "@keyframes initial {}", "@keyframes '' {}", "@-webkit-keyframes 1 {}", "@font-face x {}", "@layer a, b {}",
                     "@layer a b {}", "@layer a . b {}", "@layer inherit {}", "@page x y {}", "@page :bogus {}", "@page : first {}",
                     "@counter-style {}", "@counter-style none {}", "@counter-style decimal {}", "@counter-style a b {}",
                     "@font-feature-values {}", "@font-feature-values serif {}", "@font-feature-values Face, {}", "@property x {}",
                     "@property -- {}", "@property --a --b {}", "@font-palette-values p {}", "@position-try x {}",
                     "@container {}", "@container card {}", "@container none (min-width: 1px) {}", "@container (a) and (b) or (c) {}",
                     "@container not (a) and (b) {}", "@scope .a {}", "@scope (.a) (.b) {}", "@scope (p::before) {}", "@scope (.a) to {}",
                     "@scope (:bogus) {}", "@starting-style x {}", "@view-transition x {}", "@function f() {}", "@function --f(x) {}",
                     "@function --f() returns {}"] {
            XCTAssertEqual(imports("\(rule) @import 'a.css';"), a, rule)
        }
        // And the same at-rules with one it takes.
        for rule in ["@supports (clear: both) {}", "@supports not (bogus: 1) {}", "@supports (bogus) {}", "@keyframes k {}",
                     "@keyframes 'k' {}", "@-webkit-keyframes K {}", "@font-face {}", "@layer {}", "@layer a.b {}", "@page {}",
                     "@page name {}", "@page :first {}", "@page name:left, :right {}", "@counter-style stars {}",
                     #"@font-feature-values Face, "Other Face", Two Words {}"#, "@property --x {}", "@font-palette-values --p {}",
                     "@position-try --x {}", "@container (min-width: 1px) {}", "@container card (min-width: 1px) and style(--x: 1) {}",
                     "@container not (a) {}", "@container (a) or (b) or (c) {}", "@scope {}", "@scope (.a) {}", "@scope (.a) to (.b) {}",
                     "@scope to (.b) {}", "@starting-style {}", "@view-transition {}", "@function --f() {}",
                     "@function --f(--a <length>, --b) returns <length> {}", "@media bogus! {}", "@media {}"] {
            XCTAssertEqual(imports("\(rule) @import 'a.css';"), [], rule)
        }
    }

    func testALayerStatementMayPrecedeTheImportsButNotStandBetweenThem() {
        // CSS Cascade 5 §2: "Any @import rules must precede all other valid at-rules and style
        // rules in a style sheet (ignoring @charset and @layer statement rules)", and §6.4.2
        // allows the statements only "before the first @import".
        XCTAssertEqual(imports("@import 'a.css'; @layer x; @import 'b.css';"), ["OPS/css/a.css"])
        XCTAssertEqual(imports("@layer x; @layer y.z, w; @import 'a.css'; @import 'b.css';"), ["OPS/css/a.css", "OPS/css/b.css"])
        XCTAssertEqual(imports("@import 'a.css' print; @layer x; @import 'b.css';"), [], "An import that never applies is still a rule")
        XCTAssertEqual(imports("@import 'a.css'; @layer x, initial; @import 'b.css';"), ["OPS/css/a.css", "OPS/css/b.css"],
                       "A statement that names no layer is no rule")
        XCTAssertEqual(imports("@import 'a.css'; @layer; @import 'b.css';"), ["OPS/css/a.css", "OPS/css/b.css"])
        XCTAssertEqual(imports("@import bogus; @layer x; @import 'a.css';"), ["OPS/css/a.css"], "An import without a sheet is no rule")
        XCTAssertEqual(imports("@import 'a.css' supports(); @layer x; @import 'b.css';"), ["OPS/css/b.css"],
                       "Nor is one whose supports() does not parse")
        XCTAssertEqual(imports("@namespace x 'u'; @layer x; @namespace y 'v'; y|p { clear: both } @import 'a.css';"), [])
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet("@namespace x 'u'; @layer x; @namespace y 'v'; y|p { clear: both } p { clear: both }")), ["p"],
                       "A layer statement after @namespace ends the namespaces too")
        // A layer() that names no one layer is left to the media query list, which it spoils.
        XCTAssertEqual(imports("@import 'a.css' layer(a, b); @import 'b.css' layer(x.y);"), ["OPS/css/b.css"])
    }

    func testARuleWithAnInvalidPreludeIsDroppedWithAllItHolds() {
        let sheet = sheet("""
            @layer a, b { p { clear: both } }
            @supports bogus { q { clear: both } }
            @font-face x { font-family: F; src: url(f.ttf) }
            @layer a { i { clear: both } }
            @font-face { font-family: G; src: url(g.ttf) }
            """)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["i"])
        XCTAssertEqual(sheet.fontFaces.map(\.family), ["g"])
    }

    func testAnInvalidRuleBeforeAnImportDoesNotInvalidateIt() {
        // The same sentence counts only *valid* rules: one the parser discards cannot stand
        // between an @import and the start of the sheet.
        XCTAssertEqual(imports("@unknown-rule x; @import 'a.css';"), ["OPS/css/a.css"], "An unknown at-rule")
        XCTAssertEqual(imports("p:no-such-pseudo-class { clear: both } @import 'a.css';"), ["OPS/css/a.css"], "A rule with an invalid selector")
        XCTAssertEqual(imports("@bogus { p { clear: both } } @import 'a.css';"), ["OPS/css/a.css"], "An unknown at-rule with a block")
        XCTAssertEqual(imports("@media screen; @font-face; @import 'a.css';"), ["OPS/css/a.css"], "Block at-rules written as statements")
        XCTAssertEqual(imports("svg|a { clear: both } @import 'a.css';"), ["OPS/css/a.css"], "A selector with an undeclared prefix")
        XCTAssertEqual(imports("@import 'a.css'; @bogus; p:bogus { clear: both } @import 'b.css'; p { clear: both } @import 'c.css';"),
                       ["OPS/css/a.css", "OPS/css/b.css"], "Nor between two imports")
        // A valid rule ends the imports whether or not anything of it applies.
        XCTAssertEqual(imports("p {} @import 'a.css';"), [], "An empty style rule")
        XCTAssertEqual(imports("p { bogus: 1 } @import 'a.css';"), [], "A style rule with no valid declaration")
        XCTAssertEqual(imports("p::selection { color: red } @import 'a.css';"), [], "A style rule for a pseudo-element that is not rendered")
        XCTAssertEqual(imports("@media print { p { clear: both } } @import 'a.css';"), [], "A conditional rule that never applies")
        XCTAssertEqual(imports("@page { margin: 0 } @import 'a.css';"), [], "An at-rule that does not apply to reflowed text")
        XCTAssertEqual(imports("@-webkit-keyframes k { from { color: red } } @import 'a.css';"), [])
    }

    func testImportedRulesPrecedeTheImportingSheetInImportOrder() throws {
        let result = try StyleTestSupport.styled(#"<p id="a">a</p><p id="b">b</p><p id="c">c</p>"#,
                                                 head: #"<link rel="stylesheet" href="css/main.css"/>"#, files: [
            "css/main.css": "@import 'first.css'; @import \"sub/second.css\"; #c { text-align: center }",
            "css/first.css": "#a { text-align: left } #b { text-align: left } #c { text-align: left }",
            "css/sub/second.css": "@import '../../shared/deep.css'; #b { text-align: right } #c { text-align: right }",
            "shared/deep.css": "#a { text-align: right } #b { text-align: center }",
        ])
        XCTAssertEqual(result.style("a").textAlign, .right, "A nested import resolves against its own sheet and follows earlier imports")
        XCTAssertEqual(result.style("b").textAlign, .right, "An importing sheet follows what it imports")
        XCTAssertEqual(result.style("c").textAlign, .center)
        XCTAssertEqual(result.sheets.count, 4)
        XCTAssertEqual(result.report.unreadableResources, 0)
        XCTAssertFalse(result.report.stylesTruncated)
    }

    func testPercentEncodedAndNonASCIIImportTargetsAreRead() throws {
        let result = try StyleTestSupport.styled(#"<p id="a">a</p><p id="b">b</p><p id="c">c</p>"#,
                                                 head: #"<link rel="stylesheet" href="css/my%20main.css?v=3#top"/>"#, files: [
            "css/my main.css": "@import 'caf%C3%A9.css'; @import url(sp%20ace.css?x#y); @import 'missing%20one.css'; #c { clear: both }",
            "css/café.css": "#a { clear: both }",
            "css/sp ace.css": "#b { clear: both }",
        ])
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["a", "b", "c"])
        XCTAssertEqual(result.report.unreadableResources, 1, "The one missing import is reported")
    }

    func testMutualImportsAndDiamondsTerminate() throws {
        let head = ["a.css", "left.css", "right.css"].map { #"<link rel="stylesheet" href="\#($0)"/>"# }.joined()
        let result = try StyleTestSupport.styled(#"<p id="a">a</p><p id="b">b</p><p id="c">c</p>"#, head: head, files: [
            "a.css": "@import 'b.css'; #a { clear: both }",
            "b.css": "@import 'a.css'; @import './b.css'; @import 'sub/../b.css'; #b { clear: both }",
            "left.css": "@import 'shared.css';", "right.css": "@import 'shared.css';",
            "shared.css": "#c { clear: both }",
        ])
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["a", "b", "c"])
        XCTAssertEqual(result.sheets.count, 6, "b, a; shared, left; shared, right: a diamond loads its shared sheet once per path")
        XCTAssertFalse(result.report.stylesTruncated, "A cycle is not a bound")
        XCTAssertEqual(result.report.unreadableResources, 0)
    }
}
