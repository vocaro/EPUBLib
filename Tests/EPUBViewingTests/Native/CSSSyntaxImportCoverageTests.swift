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
        // Nothing may name a path outside the archive, whatever its spelling.
        let hostile = ["../../../etc/passwd", "..%2F..%2F..%2Fetc%2Fpasswd", "%2e%2e/%2e%2e/%2e%2e/x.css", "a/../../../../x.css", "%", "%zz",
                       "%00", "a%00.css", "#", "?", "#frag", "?query", "sub\\\\z.css", "..\\\\..\\\\x.css", ":", " ", "%C3"]
        for target in hostile {
            let sheet = sheet("@import \"\(target)\"; p { clear: both }")
            XCTAssertEqual(sheet.imports, [], target)
            XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["p"], target)
        }
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
    }

    func testAnInvalidRuleBeforeAnImportDoesNotInvalidateIt() {
        // The same sentence counts only *valid* rules: one the parser discards cannot stand
        // between an @import and the start of the sheet.
        XCTAssertEqual(imports("@unknown-rule x; @import 'a.css';"), ["OPS/css/a.css"], "An unknown at-rule")
        XCTAssertEqual(imports("p:no-such-pseudo-class { clear: both } @import 'a.css';"), ["OPS/css/a.css"], "A rule with an invalid selector")
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
