@testable import EPUBViewing
import XCTest

/// CSS Syntax Level 3 §5 parsing and error recovery: what a malformed rule or declaration may
/// take with it, and what it must leave alone.
final class CSSSyntaxParserRecoveryCoverageTests: XCTestCase {
    private func sheet(_ css: String) -> CSSStyleSheet { CSSSyntaxSupport.sheet(css) }
    private func subjects(_ css: String) -> [String] { CSSSyntaxSupport.subjects(sheet(css)) }
    private func properties(_ declarations: String) -> [CSSProperty] { CSSSyntaxSupport.properties(declarations) }
    private let red = StyleTestSupport.color(1, 0, 0)

    func testAnInvalidDeclarationIsDroppedAloneWhereverItStands() {
        let invalid = [
            "bogus-property: 1", "color red", "color", ": red", "color:", "color: ", "color: red green", "margin: 1em 2em 3em 4em 5em",
            "*zoom: 1", "_height: 1px", "color: red\\9", "color: #ggg", "width: 10", "color: rgb(1, 2", "font-weight: bold)",
            "color: 'red'", "$color: red", "color = red", "color: red, blue", "1color: red",
        ]
        for declaration in invalid where !declaration.contains("rgb(1, 2") {
            XCTAssertEqual(properties("float: left; \(declaration); clear: both"), [.float, .clear], declaration)
            XCTAssertEqual(properties("\(declaration); clear: both"), [.clear], declaration)
            XCTAssertEqual(properties("clear: both; \(declaration)"), [.clear], declaration)
        }
        // An unclosed function takes the rest of the list, so only what precedes it survives.
        XCTAssertEqual(properties("float: left; color: rgb(1, 2; clear: both"), [.float])
    }

    func testAMissingSemicolonCostsBothDeclarationsButNotTheNext() {
        XCTAssertEqual(properties("color: red font-weight: bold; clear: both"), [.clear])
        XCTAssertEqual(properties("color: red\nfont-weight: bold\nclear: both"), [])
        XCTAssertEqual(properties(";;; color: red ;; ; clear: both;;"), [.color, .clear])
    }

    func testWhitespaceCommentsAndCaseAroundDeclarationPartsAreInsignificant() {
        XCTAssertEqual(properties("  color  :  red  ;clear:both"), [.color, .clear])
        XCTAssertEqual(properties("/* a */ color /* b */ : /* c */ red /* d */ ; /* e */ clear: both /* f */"), [.color, .clear])
        XCTAssertEqual(properties("COLOR: RED; Clear: BOTH"), [.color, .clear])
        XCTAssertEqual(properties("color\n:\nred\n;\nclear\n:\nboth"), [.color, .clear])
        XCTAssertEqual(properties("co/**/lor: red; clear: both"), [.clear], "A comment splits a name into two tokens")
    }

    func testSemicolonsAndBracesInsideStringsFunctionsAndBlocksDoNotEndADeclaration() {
        let sheet = sheet("""
            p { font-family: "a;b}c{d", serif; clear: both }
            q { font-family: 'x', "y;" ; clear: both }
            i { bogus: url(a;b}c.png); clear: both }
            b { bogus: (a;b{c;d}e); clear: both }
            u { bogus: [a;b] fn(;}) ; clear: both }
            s { bogus: fn( "}" ')' ); clear: both }
            em { clear: both }
            """)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["p", "q", "i", "b", "u", "s", "em"])
        for rule in sheet.rules {
            XCTAssertTrue(rule.declarations.contains { $0.property == .clear }, rule.selectors[0].compounds[0].name ?? "")
        }
        XCTAssertEqual(sheet.rules[0].declarations.first, CSSDeclaration(property: .fontFamily, value: .families(["a;b}c{d", "serif"]), important: false))
    }

    func testAnUnclosedFunctionOrBlockRunsToTheEndOfTheStylesheet() {
        // CSS Syntax §5.4.8 and §5.4.9: only the matching closer or the end of input ends a function or block.
        XCTAssertEqual(subjects("p { color: rgb(0, 0, 0; clear: both } q { clear: both }"), [])
        let open = sheet("a { clear: both } p { float: left; bogus: [x; clear: both } q { clear: both }")
        XCTAssertEqual(CSSSyntaxSupport.subjects(open), ["a", "p"])
        XCTAssertEqual(open.rules.last?.declarations.map(\.property), [.float], "Only what precedes the unclosed block survives")
        XCTAssertEqual(subjects("a { clear: both } p[title { clear: both } q { clear: both }"), ["a"])
    }

    func testAStrayCloserInsideABlockSpoilsOnlyItsOwnDeclaration() {
        XCTAssertEqual(properties("color: red; ] ; clear: both"), [.color, .clear])
        XCTAssertEqual(properties("color: red) ; clear: both"), [.clear])
        XCTAssertEqual(properties("color: red; ) clear: both; float: left"), [.color, .float])
        XCTAssertEqual(subjects("p { color: red; ] } q { clear: both }"), ["p", "q"])
    }

    func testTheEndOfInputClosesAnOpenRuleBlockOrStatement() {
        XCTAssertEqual(sheet("p { color: red").rules.map { $0.declarations.map(\.property) }, [[.color]])
        XCTAssertEqual(sheet("p { color: red; clear: both").rules.map { $0.declarations.map(\.property) }, [[.color, .clear]])
        XCTAssertEqual(sheet("p { color: red !important").rules.first?.declarations.first?.important, true)
        XCTAssertEqual(subjects("@media screen { p { color: red"), ["p"])
        XCTAssertEqual(subjects("@media screen { @supports (color: red) { p { color: red }"), ["p"])
        XCTAssertEqual(subjects("p { color: red } q"), ["p"], "A selector with no block is not a rule")
        XCTAssertEqual(subjects("p { color: red } q {"), ["p"])
        XCTAssertEqual(sheet("@import \"a.css\"").imports, [CSSImport(path: "OPS/css/a.css", media: .all)])
        XCTAssertEqual(subjects("p { color: red } /* open comment"), ["p"])
        XCTAssertEqual(subjects("p { font-family: \"open string"), ["p"])
    }

    func testAStrayClosingBraceAtTopLevelInvalidatesOnlyTheRuleItPrefixes() {
        // The brace is an ordinary token of the next rule's prelude (§5.4.1, §5.4.3).
        XCTAssertEqual(subjects("} p { color: red } q { color: red }"), ["q"])
        XCTAssertEqual(subjects("p { color: red } } q { color: red } i { color: red }"), ["p", "i"])
        XCTAssertEqual(subjects("p { color: red }} q { color: red }\ni { color: red }"), ["p", "i"])
        XCTAssertEqual(subjects(") p { color: red } ] q { color: red } i { color: red }"), ["i"])
    }

    func testAStraySemicolonBetweenRulesBelongsToTheNextRulesPrelude() {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/116")
        // §5.4.1 "consume a list of rules": only whitespace, CDO/CDC and at-keywords are special
        // at rule level, so `;` starts a qualified rule whose prelude is then an invalid selector.
        XCTAssertEqual(subjects("p { color: red }; q { color: red } i { color: red }"), ["p", "i"])
    }

    func testAnInvalidOrUnknownAtRuleLeavesFollowingRulesAlone() {
        XCTAssertEqual(subjects("@bogus; p { color: red }"), ["p"])
        XCTAssertEqual(subjects("@bogus x, y (z) [w] \"s\"; p { color: red }"), ["p"])
        XCTAssertEqual(subjects("@bogus { q { color: red } } p { color: red }"), ["p"])
        XCTAssertEqual(subjects("@bogus x { q { color: red } } @bogus; p { color: red }"), ["p"])
        XCTAssertEqual(subjects("@media; p { color: red }"), ["p"], "A block at-rule written as a statement is ignored")
        XCTAssertEqual(subjects("@supports; @font-face; @page; p { color: red }"), ["p"])
        XCTAssertEqual(subjects("@import; @import bogus; @namespace; p { color: red }"), ["p"])
        XCTAssertEqual(subjects("@ p { color: red } q { color: red }"), ["q"], "A lone @ is a delimiter in a selector")
        XCTAssertEqual(subjects("@charset \"x\" p { color: red } q { color: red }"), ["q"], "Without a semicolon an at-rule takes the next block")
        XCTAssertEqual(subjects("@media screen { @bogus; p { color: red } @bogus { q { color: red } } i { color: red } }"), ["p", "i"])
    }

    func testBlockAtRulesThatDoNotApplyToReflowedTextAreSkippedWhole() {
        let sheet = sheet("""
            @page { margin: 1em } a { clear: both }
            @page :first { margin: 0; @top-center { content: "x" } } b { clear: both }
            @font-face { font-family: Face; src: url(face.ttf) } i { clear: both }
            @keyframes fade { from { color: red } 50% { color: blue } to { color: red } } u { clear: both }
            @-webkit-keyframes fade { 0% { top: 0 } } s { clear: both }
            @counter-style stars { system: cyclic; symbols: "*" } em { clear: both }
            @font-feature-values Face { @styleset { nice: 1 } } q { clear: both }
            @-moz-document url-prefix() { p { color: red } } p { clear: both }
            @container (min-width: 1px) { p { color: red } } h1 { clear: both }
            @property --x { syntax: "*"; inherits: false } h2 { clear: both }
            @viewport { width: device-width } h3 { clear: both }
            @starting-style { p { color: red } } h4 { clear: both }
            """)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["a", "b", "i", "u", "s", "em", "q", "p", "h1", "h2", "h3", "h4"])
        XCTAssertEqual(sheet.rules.map { $0.declarations.map(\.property) }, Array(repeating: [.clear], count: 12),
                       "No rule from inside a skipped block applies")
        XCTAssertEqual(sheet.fontFaces.map(\.family), ["face"])
        XCTAssertFalse(sheet.truncated)
    }

    func testImportantIsRecognisedOnlyAsTheLastTwoTokensOfAValue() {
        func important(_ text: String) -> [Bool] { CSSStyleSheet.declarations(text).map(\.important) }
        for form in ["red !important", "red!important", "red ! important", "red !IMPORTANT", "red !Important", "red !/* c */important",
                     "red !important  ", "red\n!\nimportant"] {
            XCTAssertEqual(important("color: \(form)"), [true], form)
        }
        XCTAssertEqual(important("color: red"), [false])
        XCTAssertEqual(important("margin: 1px 2px !important"), [true, true, true, true])
        for junk in ["red !important junk", "red !ie", "red !", "red important", "!important", "red !important !important",
                     "!important red", "red !!important", "red !important!", "red ! important important", "red \\!important"] {
            XCTAssertEqual(properties("color: \(junk)"), [], junk)
            XCTAssertEqual(properties("color: \(junk); clear: both"), [.clear], junk)
        }
    }

    func testCustomPropertiesVariablesAndNestedRulesKeepTheRestOfTheList() {
        // Custom properties are kept apart from the other declarations (#119), whatever they hold.
        XCTAssertEqual(properties("--x: {a:b}; clear: both"), [.clear])
        XCTAssertEqual(CSSStyleSheet.block("--x: {a:b}; clear: both").custom.map(\.name), ["--x"])
        XCTAssertEqual(properties("--x: ; --y:; --z: a b c !important; clear: both"), [.clear])
        XCTAssertEqual(CSSStyleSheet.block("--x: ; --y:; --z: a b c !important; clear: both").custom.map(\.important), [false, false, true])
        XCTAssertEqual(properties("--x: { color: red; }; clear: both"), [.clear])
        // A declaration that holds a valid var() is valid at parse time, and substituted at computed-value time.
        XCTAssertEqual(properties("color: var(--x); clear: both"), [.color, .clear])
        XCTAssertEqual(properties("color: var(--x, red); width: calc(var(--w) * 2); clear: both"), [.color, .width, .clear])
        XCTAssertEqual(properties("color: var(); width: var(, 1px); clear: both"), [.clear], "A var() with no name is invalid at parse time")
        XCTAssertEqual(properties("bogus: {a:b}; clear: both"), [.clear])
        XCTAssertEqual(properties("color: red; & > p { color: blue } clear: both"), [.color, .clear], "CSS Nesting is not supported")
        XCTAssertEqual(properties("color: red; .x { color: blue; float: left } clear: both"), [.color, .clear])
        XCTAssertEqual(properties("color: red; @media print { color: blue } clear: both"), [.color, .clear])
        XCTAssertEqual(properties("color: red; @bogus; clear: both"), [.color, .clear])
    }

    func testAStyleAttributeIsADeclarationListNotARule() {
        XCTAssertEqual(properties("{ color: red }"), [])
        XCTAssertEqual(properties("p { color: red }"), [])
        XCTAssertEqual(properties("color: red }; clear: both"), [.clear], "A stray brace is part of the value it follows")
        XCTAssertEqual(properties("color: red; <!-- clear: both; --> float: left"), [.color])
        XCTAssertEqual(properties(""), [])
        XCTAssertEqual(properties("   /* only a comment */   "), [])
    }

    func testTheLastValidDeclarationWinsAndAnInvalidOneNeverClobbersIt() throws {
        let result = try StyleTestSupport.styled("""
            <p id="last">a</p><p id="invalid">b</p><p id="empty">c</p><p id="unknown">d</p>
            <p id="inline" style="text-align: right; text-align: bogus; text-align: ">e</p>
            <p id="important">f</p><p id="shorthand">g</p>
            """, css: """
            #last { text-align: left; text-align: right }
            #invalid { text-align: right; text-align: bogus-value }
            #empty { text-align: right; text-align: ; text-align }
            #unknown { text-align: right; -vendor-text-align: left; text-align: 12px }
            #important { text-align: right !important; text-align: left }
            #shorthand { margin-left: 7px; margin: 1px 2px 3px 4px 5px; margin: bogus }
            """)
        for id in ["last", "invalid", "empty", "unknown", "inline", "important"] {
            XCTAssertEqual(result.style(id).textAlign, .right, id)
        }
        XCTAssertEqual(result.style("shorthand").margin.left, .points(7))
    }

    func testVendorPrefixedAndUnknownPropertiesAreIgnoredBesideKnownOnes() throws {
        let result = try StyleTestSupport.styled(#"<p id="p">x</p>"#, css: """
            #p { -webkit-box-shadow: 0 0 1px #000; -moz-border-radius: 3px; -o-transition: all 1s; -ms-interpolation-mode: bicubic;
                 behavior: url(pie.htc); zoom: 1; color: red; -unknown-thing: "x" 1 2 3 url(y) fn(a, b); clear: both }
            """)
        XCTAssertEqual(result.style("p").color, red)
        XCTAssertEqual(result.style("p").clear, .both)
        XCTAssertFalse(result.report.stylesTruncated, "Ignoring a property is not a bound")
    }

    func testHTMLCommentDelimitersAreIgnoredAtTopLevelOnly() {
        XCTAssertEqual(subjects("<!-- p { color: red } -->"), ["p"])
        XCTAssertEqual(subjects("<!--\np { color: red }\n-->\nq { color: red }"), ["p", "q"])
        XCTAssertEqual(subjects("p { color: red } <!-- --> --> <!-- q { color: red }"), ["p", "q"])
        XCTAssertEqual(subjects("<!--@media screen { p { color: red } }-->"), ["p"])
        // Inside a block they are tokens of a (then invalid) selector: §5.4.1 with the top-level flag unset.
        XCTAssertEqual(subjects("@media screen { <!-- p { color: red } --> q { color: red } i { color: red } }"), ["i"])
    }

    func testCharsetRulesAreIgnoredWhereverTheyAppear() {
        XCTAssertEqual(subjects("@charset \"utf-8\"; p { color: red }"), ["p"])
        XCTAssertEqual(subjects("p { color: red } @charset \"utf-8\"; q { color: red }"), ["p", "q"])
        XCTAssertEqual(subjects("@CHARSET 'iso-8859-1'; @charset \"x\"; p { color: red }"), ["p"])
        XCTAssertEqual(sheet("@charset \"utf-8\"; @import 'a.css';").imports.map(\.path), ["OPS/css/a.css"])
    }
}
