@testable import EPUBViewing
import XCTest

/// Hostile stylesheets: each input must be read to its end without a trap and leave the rules
/// around it standing. No wall-clock bounds are asserted; a hang shows as a test that never ends.
final class CSSSyntaxRobustnessCoverageTests: XCTestCase {
    private func sheet(_ css: String) -> CSSStyleSheet { CSSSyntaxSupport.sheet(css) }

    func testRunsOfUnclosedOpenersAreBoundedEverywhereTheyCanAppear() {
        let comment = "/* "
        for opener in ["(", "[", "{", "f(", ":not(", "url(", "\"", comment, "@media (", "a{b:"] {
            let run = String(repeating: opener, count: 50_000)
            let nested = !["url(", "\"", comment].contains(opener)
            XCTAssertEqual(sheet(run).rules.count, 0, opener)
            let value = sheet("p { float: left; color: \(run) } q { clear: both }")
            XCTAssertEqual(value.rules.first?.declarations.map(\.property), [.float], opener)
            XCTAssertEqual(value.truncated, nested, opener)
            XCTAssertEqual(sheet("p\(run) { clear: both }").rules.count, 0, opener)
            XCTAssertEqual(CSSStyleSheet.declarations("float: left; color: \(run)").map(\.property), [.float], opener)
            // An unterminated comment is no token at all: an empty query list, and a bare `p`.
            XCTAssertEqual(CSSMedia.mask(run), opener == comment ? .all : [], opener)
            XCTAssertEqual(CSSSyntaxSupport.selectors("p\(run)")?.count, opener == comment ? 1 : nil, opener)
        }
    }

    func testBalancedNestingBeyondTheBoundLosesOnlyItsOwnDeclaration() {
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}"), ("calc(", ")")] {
            let deep = String(repeating: open, count: 20_000) + "1" + String(repeating: close, count: 20_000)
            let sheet = sheet("a { clear: both } p { float: left; bogus: \(deep); clear: both } q { clear: both }")
            XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["a", "p", "q"], open)
            XCTAssertEqual(sheet.rules[1].declarations.map(\.property), [.float, .clear], open)
            XCTAssertTrue(sheet.truncated, open)
        }
        let shallow = String(repeating: "(", count: 8) + "1px" + String(repeating: ")", count: 8)
        let within = sheet("p { bogus: fn\(shallow); clear: both }")
        XCTAssertEqual(within.rules.first?.declarations.map(\.property), [.clear])
        XCTAssertFalse(within.truncated, "Ordinary nesting is not a bound")
    }

    func testOversizedSelectorsAreRefusedAndReportedWithoutDisturbingOtherRules() {
        let hostile = [
            String(repeating: ".a", count: 50_000), String(repeating: "#a", count: 50_000), String(repeating: "[a]", count: 30_000),
            String(repeating: ":not(p)", count: 20_000), String(repeating: "a > ", count: 30_000) + "a", String(repeating: "a ", count: 50_000),
            String(repeating: "a + ", count: 30_000) + "a", (0..<5_000).map { "p\($0)" }.joined(separator: ", "),
            String(repeating: ":is(", count: 10_000) + "p" + String(repeating: ")", count: 10_000),
            String(repeating: ":not(", count: 6) + "p" + String(repeating: ")", count: 6),
            "p:nth-child(2n of " + String(repeating: ":nth-child(2n of ", count: 5) + "p" + String(repeating: ")", count: 6),
            ":is(" + (0..<5_000).map { ".c\($0)" }.joined(separator: ", ") + ")",
        ]
        for selector in hostile {
            let sheet = sheet("a { clear: both } \(selector) { clear: both } q { clear: both }")
            XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["a", "q"], String(selector.prefix(24)))
            XCTAssertTrue(sheet.truncated, String(selector.prefix(24)))
        }
    }

    func testLongButSimpleSelectorsAndValuesAreKept() throws {
        let name = String(repeating: "n", count: 100_000)
        let long = sheet(".\(name), #\(name), \(name) { clear: both } q { font-family: \"\(name)\" }")
        XCTAssertEqual(long.rules.map(\.selectors.count), [3, 1])
        XCTAssertFalse(long.truncated)
        XCTAssertEqual(long.rules.last?.declarations.map(\.property), [.fontFamily])
        let list = (0..<CSSSelectorParser.maximumSelectors).map { ".c\($0)" }.joined(separator: ",")
        let widest = sheet("\(list) { clear: both }")
        XCTAssertEqual(widest.rules.first?.selectors.count, CSSSelectorParser.maximumSelectors, "A list exactly at the bound is whole")
        XCTAssertFalse(widest.truncated)
        let chain = (0..<CSSSelectorParser.maximumCompounds).map { _ in "div" }.joined(separator: " > ")
        XCTAssertEqual(sheet("\(chain) { clear: both }").rules.count, 1)
        let classes = String(repeating: ".a", count: CSSSelectorParser.maximumSimpleSelectors)
        XCTAssertEqual(CSSSyntaxSupport.specificity(classes), [0, UInt32(CSSSelectorParser.maximumSimpleSelectors), 0])
    }

    func testVeryLongTokensOfEveryKind() {
        let count = 300_000
        func single(_ text: String) -> CSSToken? {
            let tokens = CSSSyntaxSupport.tokens(text)
            XCTAssertEqual(tokens.count, 1, String(text.prefix(12)))
            return tokens.first
        }
        XCTAssertEqual(single(String(repeating: "a", count: count)), .ident(String(repeating: "a", count: count)))
        XCTAssertEqual(single("\"" + String(repeating: "s", count: count) + "\""), .string(String(repeating: "s", count: count)))
        XCTAssertEqual(single("url(" + String(repeating: "u", count: count) + ")"), .url(String(repeating: "u", count: count)))
        XCTAssertEqual(single("#" + String(repeating: "h", count: count)), .hash(String(repeating: "h", count: count), isID: true))
        XCTAssertEqual(single(String(repeating: "\\41 ", count: count / 4)), .ident(String(repeating: "A", count: count / 4)))
        XCTAssertEqual(single(String(repeating: " \n\t", count: count)), .whitespace)
        XCTAssertEqual(single("0." + String(repeating: "0", count: count) + "5"), CSSSyntaxSupport.real(0))
        XCTAssertEqual(single("1" + String(repeating: "0", count: 5) + "px"), CSSSyntaxSupport.dimension(100_000, "px"))
        XCTAssertNotNil(single(String(repeating: "9", count: count)), "A number beyond any float is still one token")
        XCTAssertNotNil(single("1e" + String(repeating: "9", count: count)))
        XCTAssertEqual(CSSSyntaxSupport.tokens("/*" + String(repeating: "*", count: count)), [])
        XCTAssertEqual(CSSSyntaxSupport.tokens(String(repeating: "/**/", count: count)), [])
        XCTAssertEqual(CSSSyntaxSupport.tokens(String(repeating: "<!---->", count: 50_000)).count, 100_000)
        XCTAssertEqual(CSSSyntaxSupport.tokens(String(repeating: "\u{0}", count: count)), [.ident(String(repeating: "\u{FFFD}", count: count))])
    }

    func testHugeAndDegenerateNumbersNeverTrapInSelectorsMediaOrValues() throws {
        let huge = String(repeating: "9", count: 400)
        for expression in ["\(huge)n+1", "n+\(huge)", "-\(huge)n-\(huge)", "\(huge)", "1e\(huge)n", "2147483648n+2147483648", "-2147483649",
                           "9223372036854775807n+9223372036854775807", "9223372036854775808", "999999999n+999999999", "-999999999n-999999999"] {
            _ = try CSSSyntaxSupport.matched("p:nth-child(\(expression)), p:nth-last-of-type(\(expression))", in: #"<p id="p">x</p><p id="q">y</p>"#)
        }
        XCTAssertEqual(try CSSSyntaxSupport.matched("p:nth-child(999999999n+2)", in: #"<p id="p">x</p><p id="q">y</p>"#), ["q"])
        for query in ["(min-width: \(huge)px)", "(min-width: -\(huge)px)", "(aspect-ratio: \(huge)/\(huge))", "(aspect-ratio: 1/0)", "(aspect-ratio: 0/0)",
                      "(width >= 1e\(huge)px)", "(min-resolution: \(huge)dpi)", "(min-width: 1e-\(huge)px)", "(\(huge)px < width < \(huge)px)"] {
            _ = CSSMedia.mask(query)
        }
        XCTAssertEqual(CSSMedia.mask("(aspect-ratio: 1/0)"), [])
        let sheet = sheet("""
            @font-face { font-family: F; src: url(f.ttf); font-weight: \(huge) } @font-face { font-family: G; src: url(g.ttf); font-weight: 1 1e\(huge) }
            @font-face { font-family: H; src: url(h.ttf); font-weight: -1 0.4 } p { clear: both }
            """)
        XCTAssertEqual(sheet.fontFaces.map(\.family), ["f", "g", "h"])
        XCTAssertEqual(sheet.fontFaces.map(\.weights), [400...400, 400...400, 400...400], "An out-of-range weight leaves the default")
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["p"])
    }

    func testAnAtRulePreludeOfUnbalancedTokensEndsAtItsSemicolonOrBlock() {
        // CSS Syntax §5.4.2 "consume an at-rule": blocks, functions and strings are consumed whole
        // before the rule's terminating semicolon or block is looked for.
        let sheet = sheet("""
            @media all {
              a { clear: both }
              @bogus ) ] ~ ^ 1e3 #1 url(x y) U+26 [ ; a { float: left } ] ( ; a { float: left } } ) "; a { float: left } }" ;
              b { clear: both }
              @bogus ' ; b { float: left } ' [ ( { ; } ) ] { b { float: left } ; b { float: left } }
              i { clear: both }
              @import "never.css"
            }
            u { clear: both }
            @media all { s { clear: both } @bogus (; s { float: left } ) }
            q { clear: both }
            """)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["a", "b", "i", "u", "s", "q"])
        XCTAssertEqual(sheet.rules.map { $0.declarations.map(\.property) }, Array(repeating: [.clear], count: 6))
        XCTAssertEqual(sheet.imports, [])
    }

    func testImportingOneSheetHundredsOfTimesAtEveryLevelIsBounded() throws {
        // 400 imports at each of five levels name 400⁴ sheet loads; the sheet bound must stop them.
        let fan = (0..<400).map { _ in "@import 'next.css';" }.joined()
        var files = ["level0.css": fan.replacingOccurrences(of: "next", with: "level1") + " #p { clear: both }"]
        for level in 1..<8 { files["level\(level).css"] = fan.replacingOccurrences(of: "next", with: "level\(level + 1)") + " #l\(level) { clear: both }" }
        let result = try StyleTestSupport.styled(#"<p id="p">x</p>"#, head: #"<link rel="stylesheet" href="level0.css"/>"#, files: files)
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["p"])
        XCTAssertLessThanOrEqual(result.sheets.count, SectionStyles.maximumSheets + SectionStyles.maximumImportDepth + 1)
        XCTAssertTrue(result.report.stylesTruncated)
    }

    func testManyLinksToMissingAndEmptySheetsAreCountedNotFatal() throws {
        let head = (0..<3_000).map { #"<link rel="stylesheet" href="missing\#($0).css"/><link rel="stylesheet" href="empty.css"/>"# }.joined()
        let result = try StyleTestSupport.styled(#"<p id="p">x</p>"#, css: "#p { clear: both }", head: head, files: ["empty.css": ""])
        XCTAssertEqual(CSSSyntaxSupport.marked(result), ["p"])
        XCTAssertEqual(result.report.unreadableResources, 3_000)
        XCTAssertFalse(result.report.stylesTruncated, "An empty sheet uses none of the section's budget")
    }

    /// CPU seconds of this thread: unlike a wall clock, unaffected by other work on the machine.
    private func threadSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    private func matchingSeconds(siblings: Int, css: String, sibling: String = "<p>x</p>") throws -> Double {
        let section = StyleTestSupport.xhtml(body: "<h1>t</h1>" + String(repeating: sibling, count: siblings), css: css)
        let document = try ContentDocument.parse(Data(section.utf8), path: "OPS/one.xhtml")
        let sheets = [CSSStyleSheet.parse(css, path: "OPS/one.xhtml")]
        let start = threadSeconds()
        let resolver = StyleResolver(document: document, stylesheets: sheets, typography: NativeTypography(fontSize: 16))
        XCTAssertEqual(StyleTestSupport.styleAll(document, resolver).count, document.nodes.filter(\.isElement).count)
        return threadSeconds() - start
    }

    func testSubsequentSiblingMatchingDoesNotGrowWithTheSquareOfTheSiblingCount() throws {
        // A body of a book's paragraphs under one parent is ordinary, and a hostile one may hold
        // every node the document bound allows. Four times the siblings is four times the
        // elements to style; sixteen times the work means each one rescans all before it.
        let css = "nav ~ p { clear: both } aside ~ p { float: left }"
        _ = try matchingSeconds(siblings: 200, css: css)
        let small = try matchingSeconds(siblings: 1_000, css: css)
        let large = try matchingSeconds(siblings: 4_000, css: css)
        XCTAssertLessThan(large / small, 8, "1,000 siblings took \(small) s of CPU and 4,000 took \(large) s")
    }

    func testASiblingSearchBehindAnotherCombinatorOrPseudoClassDoesNotRescanEitherForEveryElement() throws {
        // What is left of a `~` is tested against earlier siblings whatever joins it to the rest:
        // where every sibling passes the compound and fails further left (`aside + p ~ p`,
        // `html > p ~ p`), where the search belongs to an ancestor of the subject, and where a
        // pseudo-class holds the search. One search inside another multiplied the two walks.
        let shapes: [(css: String, sibling: String, siblings: Int)] = [
            ("h1 + p ~ p { clear: both } aside + p ~ p { float: left }", "<p>x</p>", 1_000),
            ("html > p ~ p { clear: both } nav ~ p ~ p { float: left }", "<p>x</p>", 1_000),
            ("nav ~ p i { clear: both } aside ~ p > i { float: left }", "<p><i>x</i></p>", 1_000),
            ("p:not(nav ~ p) { clear: both } p:is(aside ~ p) { float: left }", "<p>x</p>", 1_000),
            (":is(nav ~ p) ~ p { clear: both }", "<p>x</p>", 500),
        ]
        for shape in shapes {
            _ = try matchingSeconds(siblings: 200, css: shape.css, sibling: shape.sibling)
            let small = try matchingSeconds(siblings: shape.siblings, css: shape.css, sibling: shape.sibling)
            let large = try matchingSeconds(siblings: shape.siblings * 4, css: shape.css, sibling: shape.sibling)
            XCTAssertLessThan(large / small, 8, "\(shape.css): \(shape.siblings) siblings took \(small) s of CPU and four times as many took \(large) s")
        }
    }

    func testCombinatorHeavySelectorsOverADeepSiblingRichDocumentTerminate() throws {
        // 90 levels, each with three earlier siblings: every combinator has many candidates and
        // the leftmost compound never matches, so each selector exhausts its search.
        let depth = 90
        let body = String(repeating: "<div><i/><b/><i/><div class=\"k\">", count: depth) + "<p id=\"p\">x</p>" + String(repeating: "</div></div>", count: depth)
        let chain = (0..<10).map { _ in "i ~ div > div" }.joined(separator: " ")
        let css = """
            x ~ \(chain) p { clear: both }
            x \(chain) p { clear: both }
            \((0..<7).map { _ in "b + i ~ div div" }.joined(separator: " ")) x p { clear: both }
            x > \((0..<15).map { _ in "div.k div" }.joined(separator: " ")) p { clear: both }
            \((0..<30).map { _ in "div" }.joined(separator: " ")) > x ~ p { clear: both }
            \(chain) p { float: left }
            """
        let result = try StyleTestSupport.styled(body, css: css)
        XCTAssertEqual(CSSSyntaxSupport.marked(result), [])
        XCTAssertEqual(result.style("p").float, .left, "The same chain without the impossible ancestor matches")
        XCTAssertFalse(result.report.stylesTruncated)
    }
}
