@testable import EPUBViewing
import XCTest

/// CSS Syntax Level 3 §4 tokenization, one token family per test.
final class CSSSyntaxTokenizerCoverageTests: XCTestCase {
    private func tokens(_ text: String) -> [CSSToken] { CSSSyntaxSupport.tokens(text) }
    private func int(_ value: Double, signed: Bool = false) -> CSSToken { CSSSyntaxSupport.integer(value, signed: signed) }
    private func real(_ value: Double, signed: Bool = false) -> CSSToken { CSSSyntaxSupport.real(value, signed: signed) }
    private func dim(_ value: Double, _ unit: String, integer: Bool = true, signed: Bool = false) -> CSSToken {
        CSSSyntaxSupport.dimension(value, unit, integer: integer, signed: signed)
    }

    func testCommentsProduceNoTokenInAnyPositionAndAnUnterminatedOneEndsTheInput() {
        XCTAssertEqual(tokens("/**/"), [])
        XCTAssertEqual(tokens("a/**/b"), [.ident("a"), .ident("b")], "A comment separates tokens without becoming whitespace")
        XCTAssertEqual(tokens("a/* x */ /* y */b"), [.ident("a"), .whitespace, .ident("b")])
        XCTAssertEqual(tokens("/* * / ** /* */x"), [.ident("x")], "Comments do not nest and end at the first */")
        XCTAssertEqual(tokens("a /* never closed"), [.ident("a"), .whitespace])
        XCTAssertEqual(tokens("a/*/b"), [.ident("a")], "The slash of /*/ cannot also close the comment")
        XCTAssertEqual(tokens("1/**/px"), [int(1), .ident("px")])
        XCTAssertEqual(tokens("\"/* text */\""), [.string("/* text */")])
        XCTAssertEqual(tokens("url(/*x*/)"), [.url("/*x*/")], "An unquoted URL has no comments")
        XCTAssertEqual(tokens("a / b */"), [.ident("a"), .whitespace, .delim("/"), .whitespace, .ident("b"), .whitespace, .delim("*"), .delim("/")])
    }

    func testHexEscapesTakeUpToSixDigitsAndOneTrailingWhitespace() {
        XCTAssertEqual(tokens(#"\26 B"#), [.ident("&B")])
        XCTAssertEqual(tokens(#"\000026B"#), [.ident("&B")], "Six digits end the escape without whitespace")
        XCTAssertEqual(tokens(#"\0000261"#), [.ident("&1")])
        XCTAssertEqual(tokens(#"\26  B"#), [.ident("&"), .whitespace, .ident("B")], "Only one whitespace belongs to the escape")
        XCTAssertEqual(tokens("\\26\r\nB"), [.ident("&B")], "CRLF is one newline")
        XCTAssertEqual(tokens("\\26\tB"), [.ident("&B")])
        XCTAssertEqual(tokens(#"\41\42 \43"#), [.ident("ABC")])
        XCTAssertEqual(tokens(#"\e9 t\E9"#), [.ident("été")], "Hex digits are case-insensitive")
        XCTAssertEqual(tokens(##"a\.b\:c\#d\ e"##), [.ident("a.b:c#d e")])
        XCTAssertEqual(tokens(#"\g\h"#), [.ident("gh")], "A non-hex escape is the character itself")
        XCTAssertEqual(tokens(#"\1F600"#), [.ident("\u{1F600}")])
    }

    func testEscapesOutsideTheScalarRangeAndNULBecomeReplacementCharacters() {
        XCTAssertEqual(tokens(#"\0 "#), [.ident("\u{FFFD}")])
        XCTAssertEqual(tokens(#"\000000"#), [.ident("\u{FFFD}")])
        XCTAssertEqual(tokens(#"\D800 x"#), [.ident("\u{FFFD}x")], "A surrogate is not a scalar value")
        XCTAssertEqual(tokens(#"\DFFF"#), [.ident("\u{FFFD}")])
        XCTAssertEqual(tokens(#"\D7FF"#), [.ident("\u{D7FF}")])
        XCTAssertEqual(tokens(#"\10FFFF"#), [.ident("\u{10FFFF}")])
        XCTAssertEqual(tokens(#"\110000"#), [.ident("\u{FFFD}")])
        XCTAssertEqual(tokens(#"\FFFFFF"#), [.ident("\u{FFFD}")])
        XCTAssertEqual(tokens("a\u{0}b"), [.ident("a\u{FFFD}b")], "NUL is replaced before tokenizing (§3.3)")
        XCTAssertEqual(tokens("\"\u{0}\""), [.string("\u{FFFD}")])
    }

    func testABackslashBeforeANewlineIsNotAnEscapeOutsideAString() {
        XCTAssertEqual(tokens("a\\\nb"), [.ident("a"), .delim("\\"), .whitespace, .ident("b")])
        XCTAssertEqual(tokens("\\\n"), [.delim("\\"), .whitespace])
        XCTAssertEqual(tokens("#\\\n"), [.delim("#"), .delim("\\"), .whitespace])
    }

    func testStringsHandleEscapesContinuationsBothQuotesAndTheEndOfInput() {
        XCTAssertEqual(tokens("\"a\\\nb\""), [.string("ab")], "An escaped newline continues the string")
        XCTAssertEqual(tokens("'a\\\r\nb'"), [.string("ab")])
        XCTAssertEqual(tokens(#""a\62 c""#), [.string("abc")])
        XCTAssertEqual(tokens(#"'it\'s'"#), [.string("it's")])
        XCTAssertEqual(tokens(#""say 'x'" 'say "y"'"#), [.string("say 'x'"), .whitespace, .string("say \"y\"")])
        XCTAssertEqual(tokens(#""\"""#), [.string("\"")])
        XCTAssertEqual(tokens("''"), [.string("")])
        XCTAssertEqual(tokens("\"open"), [.string("open")], "The end of input closes a string")
        XCTAssertEqual(tokens("\"open\\"), [.string("open")], "A backslash at the end of input adds nothing")
        XCTAssertEqual(tokens("\"a;b}c{d\""), [.string("a;b}c{d")])
    }

    func testAnUnescapedNewlineMakesABadStringAndTokenizingResumesOnTheNextLine() {
        XCTAssertEqual(tokens("\"a\nb\""), [.badString, .whitespace, .ident("b"), .string("")])
        XCTAssertEqual(tokens("'a\rb"), [.badString, .whitespace, .ident("b")])
        XCTAssertEqual(tokens("'a\u{0C}b"), [.badString, .whitespace, .ident("b")], "A form feed is a newline")
        XCTAssertEqual(tokens("x: 'a\n; y: z"),
                       [.ident("x"), .colon, .whitespace, .badString, .whitespace, .semicolon, .whitespace, .ident("y"), .colon, .whitespace, .ident("z")])
    }

    func testNumbersFollowTheNumberGrammar() {
        XCTAssertEqual(tokens("0"), [int(0)])
        XCTAssertEqual(tokens("007"), [int(7)])
        XCTAssertEqual(tokens("-0"), [int(0, signed: true)])
        XCTAssertEqual(tokens("+12"), [int(12, signed: true)])
        XCTAssertEqual(tokens("-.25"), [real(-0.25, signed: true)])
        XCTAssertEqual(tokens("1.0"), [real(1)], "A fraction makes a number a non-integer, whatever its value")
        XCTAssertEqual(tokens("1e3"), [real(1000)])
        XCTAssertEqual(tokens("1E-2"), [real(0.01)])
        XCTAssertEqual(tokens("1e+2"), [real(100)])
        XCTAssertEqual(tokens("-2.5e1"), [real(-25, signed: true)])
        XCTAssertEqual(tokens("1."), [int(1), .delim(".")], "A dot needs a digit after it")
        XCTAssertEqual(tokens(".5.5"), [real(0.5), real(0.5)])
        XCTAssertEqual(tokens("1..5"), [int(1), .delim("."), real(0.5)])
        XCTAssertEqual(tokens("+-1"), [.delim("+"), int(-1, signed: true)])
        XCTAssertEqual(tokens("1 000"), [int(1), .whitespace, int(0)])
        XCTAssertEqual(tokens("+"), [.delim("+")])
        XCTAssertEqual(tokens("+a"), [.delim("+"), .ident("a")])
        XCTAssertEqual(tokens("."), [.delim(".")])
        XCTAssertEqual(tokens("-"), [.delim("-")])
        XCTAssertEqual(tokens("1e"), [dim(1, "e")])
        XCTAssertEqual(tokens("1e+"), [dim(1, "e"), .delim("+")])
    }

    func testAUnitStartingWithEIsNotAnExponentAndPercentagesNeedAnAdjacentSign() {
        XCTAssertEqual(tokens("1em"), [dim(1, "em")])
        XCTAssertEqual(tokens("1ex"), [dim(1, "ex")])
        XCTAssertEqual(tokens("2E"), [dim(2, "E")])
        XCTAssertEqual(tokens("1e3px"), [dim(1000, "px", integer: false)])
        XCTAssertEqual(tokens("1.5e1em"), [dim(15, "em", integer: false)])
        XCTAssertEqual(tokens("1e-x"), [dim(1, "e-x")])
        XCTAssertEqual(tokens("1e-"), [dim(1, "e-")])
        XCTAssertEqual(tokens("-1x"), [dim(-1, "x", signed: true)])
        XCTAssertEqual(tokens("1-x"), [dim(1, "-x")])
        XCTAssertEqual(tokens("1--x"), [dim(1, "--x")])
        XCTAssertEqual(tokens("1-2"), [int(1), int(-2, signed: true)])
        XCTAssertEqual(tokens("12px34"), [dim(12, "px34")])
        XCTAssertEqual(tokens(#"1\65 m"#), [dim(1, "em")], "A unit may be escaped")
        XCTAssertEqual(tokens("1_"), [dim(1, "_")])
        XCTAssertEqual(tokens("50%"), [.percentage(50)])
        XCTAssertEqual(tokens("-12.5%"), [.percentage(-12.5)])
        XCTAssertEqual(tokens("1e2%"), [.percentage(100)])
        XCTAssertEqual(tokens("50 %"), [int(50), .whitespace, .delim("%")])
        XCTAssertEqual(tokens("%"), [.delim("%")])
    }

    func testUnquotedURLsTrimWhitespaceDecodeEscapesAndEndWithTheInput() {
        XCTAssertEqual(tokens("url(a.css)"), [.url("a.css")])
        XCTAssertEqual(tokens("URL(  a.css\n)"), [.url("a.css")])
        XCTAssertEqual(tokens("Url(\ta.css\t)"), [.url("a.css")])
        XCTAssertEqual(tokens("url()"), [.url("")])
        XCTAssertEqual(tokens("url(   )"), [.url("")])
        XCTAssertEqual(tokens(#"url(a\)b)"#), [.url("a)b")])
        XCTAssertEqual(tokens(#"url(a\ b)"#), [.url("a b")])
        XCTAssertEqual(tokens(#"url(\66oo\27)"#), [.url("foo'")])
        XCTAssertEqual(tokens("url(a.css"), [.url("a.css")], "The end of input closes a URL")
        XCTAssertEqual(tokens("url(a.css  "), [.url("a.css")])
        XCTAssertEqual(tokens("url(../a/b.css?x=1&y=2#z);"), [.url("../a/b.css?x=1&y=2#z"), .semicolon])
        XCTAssertEqual(tokens("url(a;b{c}d)"), [.url("a;b{c}d")])
    }

    func testAMalformedURLIsOneBadTokenThroughItsClosingParenthesis() {
        XCTAssertEqual(tokens("url(a b) c"), [.badURL, .whitespace, .ident("c")])
        XCTAssertEqual(tokens("url(a'b) c"), [.badURL, .whitespace, .ident("c")])
        XCTAssertEqual(tokens("url(a\"b) c"), [.badURL, .whitespace, .ident("c")])
        XCTAssertEqual(tokens("url(a(b) c"), [.badURL, .whitespace, .ident("c")])
        XCTAssertEqual(tokens("url(a\u{7F}b) c"), [.badURL, .whitespace, .ident("c")], "A non-printable character is not allowed")
        XCTAssertEqual(tokens("url(a\u{1}b) c"), [.badURL, .whitespace, .ident("c")])
        XCTAssertEqual(tokens("url(a\\\nb) c"), [.badURL, .whitespace, .ident("c")], "A backslash before a newline is not an escape")
        XCTAssertEqual(tokens(#"url(a(b\)c) d"#), [.badURL, .whitespace, .ident("d")], "An escaped parenthesis does not end the bad URL")
        XCTAssertEqual(tokens("url(a b"), [.badURL])
    }

    func testAQuotedURLIsAFunctionHoldingAString() {
        XCTAssertEqual(tokens("url('a.css')"), [.function("url"), .string("a.css"), .closeParen])
        XCTAssertEqual(tokens("url( \"a b.css\" )"), [.function("url"), .whitespace, .string("a b.css"), .whitespace, .closeParen])
        XCTAssertEqual(tokens("url(\n\n'a.css')"), [.function("url"), .whitespace, .string("a.css"), .closeParen])
        XCTAssertEqual(CSSSyntaxSupport.components("URL('a.css')"), [.function("url", [.token(.string("a.css"))])])
        XCTAssertEqual(tokens("url-prefix(a)"), [.function("url-prefix"), .ident("a"), .closeParen], "Only url( itself reads a URL")
    }

    func testCommentDelimitersOfHTMLAreTokensAndHyphenRunsAreIdentifiers() {
        XCTAssertEqual(tokens("<!-- -->"), [.cdo, .whitespace, .cdc])
        XCTAssertEqual(tokens("<!---->"), [.cdo, .cdc])
        XCTAssertEqual(tokens("<!-"), [.delim("<"), .delim("!"), .delim("-")])
        XCTAssertEqual(tokens("< !--"), [.delim("<"), .whitespace, .delim("!"), .ident("--")])
        XCTAssertEqual(tokens("-->x"), [.cdc, .ident("x")])
        XCTAssertEqual(tokens("a-->b"), [.ident("a--"), .delim(">"), .ident("b")], "Inside a name, hyphens are name characters")
        XCTAssertEqual(tokens("--x"), [.ident("--x")])
        XCTAssertEqual(tokens("--"), [.ident("--")])
        XCTAssertEqual(tokens("--1"), [.ident("--1")])
        XCTAssertEqual(tokens("-x-y"), [.ident("-x-y")])
        XCTAssertEqual(tokens(#"-\31"#), [.ident("-1")])
        XCTAssertEqual(tokens("- x"), [.delim("-"), .whitespace, .ident("x")])
    }

    func testHashAndAtKeywordTokensNeedANameAndFallBackToDelimiters() {
        XCTAssertEqual(tokens("#a"), [.hash("a", isID: true)])
        XCTAssertEqual(tokens("#1"), [.hash("1", isID: false)])
        XCTAssertEqual(tokens("#-a"), [.hash("-a", isID: true)])
        XCTAssertEqual(tokens("#-1"), [.hash("-1", isID: false)])
        XCTAssertEqual(tokens("#--"), [.hash("--", isID: true)])
        XCTAssertEqual(tokens("#_"), [.hash("_", isID: true)])
        XCTAssertEqual(tokens(#"#\31 a"#), [.hash("1a", isID: true)], "An escaped digit may start an identifier")
        XCTAssertEqual(tokens("#é"), [.hash("é", isID: true)])
        XCTAssertEqual(tokens("# a"), [.delim("#"), .whitespace, .ident("a")])
        XCTAssertEqual(tokens("#"), [.delim("#")])
        XCTAssertEqual(tokens("#{"), [.delim("#"), .openCurly])
        XCTAssertEqual(tokens("@media"), [.atKeyword("media")])
        XCTAssertEqual(tokens("@-webkit-keyframes"), [.atKeyword("-webkit-keyframes")])
        XCTAssertEqual(tokens("@--x"), [.atKeyword("--x")])
        XCTAssertEqual(tokens(#"@\69mport"#), [.atKeyword("import")])
        XCTAssertEqual(tokens("@1"), [.delim("@"), int(1)])
        XCTAssertEqual(tokens("@ a"), [.delim("@"), .whitespace, .ident("a")])
        XCTAssertEqual(tokens("@-"), [.delim("@"), .delim("-")])
        XCTAssertEqual(tokens("@"), [.delim("@")])
    }

    func testEveryNewlineFormIsWhitespaceAndRunsCollapseIntoOneToken() {
        for newline in ["\n", "\r", "\r\n", "\u{0C}", " \t\r\n\u{0C}\r \n"] {
            XCTAssertEqual(tokens("a\(newline)b"), [.ident("a"), .whitespace, .ident("b")], newline.debugDescription)
        }
        XCTAssertEqual(tokens("a\r\rb"), [.ident("a"), .whitespace, .ident("b")])
        XCTAssertEqual(tokens("  "), [.whitespace])
        XCTAssertEqual(tokens("a\u{0B}b"), [.ident("a"), .delim("\u{0B}"), .ident("b")], "A vertical tab is not CSS whitespace")
    }

    func testIdentifiersAcceptNonASCIIAndFunctionNamesAreLowercasedOnlyAsComponents() {
        XCTAssertEqual(tokens("café"), [.ident("café")])
        XCTAssertEqual(tokens("第一章"), [.ident("第一章")])
        XCTAssertEqual(tokens("e\u{301}"), [.ident("e\u{301}")], "A combining mark continues the name")
        XCTAssertEqual(tokens("\u{1F600}x"), [.ident("\u{1F600}x")])
        XCTAssertEqual(tokens("_a-b_1"), [.ident("_a-b_1")])
        XCTAssertEqual(tokens("RGB(1)"), [.function("RGB"), int(1), .closeParen])
        XCTAssertEqual(CSSSyntaxSupport.components("RGB(1)"), [.function("rgb", [.token(int(1))])])
        XCTAssertEqual(tokens("a ("), [.ident("a"), .whitespace, .openParen])
        XCTAssertEqual(tokens("a!b~c|d^e$f*g=h>i,j:k;l"),
                       [.ident("a"), .delim("!"), .ident("b"), .delim("~"), .ident("c"), .delim("|"), .ident("d"), .delim("^"), .ident("e"),
                        .delim("$"), .ident("f"), .delim("*"), .ident("g"), .delim("="), .ident("h"), .delim(">"), .ident("i"), .comma,
                        .ident("j"), .colon, .ident("k"), .semicolon, .ident("l")])
    }

    func testAUnicodeRangeDescriptorDoesNotDisturbItsFontFaceOrTheNextRule() {
        let sheet = CSSSyntaxSupport.sheet("""
            @font-face { font-family: Face; unicode-range: U+0025-00FF, u+4??, U+1F600; src: url(face.ttf) }
            p { clear: both }
            """)
        XCTAssertEqual(sheet.fontFaces, [CSSFontFace(family: "face", sources: ["OPS/css/face.ttf"])])
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["p"])
    }
}
