@testable import EPUBViewing
import XCTest

/// Media Queries Level 4 and CSS Conditional 3 (`@media`, `@supports`), against the reader's
/// documented nominal viewport and its light or dark appearance.
final class CSSSyntaxMediaCoverageTests: XCTestCase {
    private func mask(_ query: String) -> CSSMediaMask { CSSMedia.mask(query) }
    private let none: CSSMediaMask = []
    private var width: Int { Int(CSSMedia.viewport.width) }
    private var height: Int { Int(CSSMedia.viewport.height) }

    func testMediaTypesAndTheirModifiers() {
        for query in ["all", "ALL", "screen", "Screen", " screen ", "only screen", "ONLY SCREEN", "only all", "not print", "not tv", "not speech",
                      "not unknown-type", "screen, print", "print, screen", "bogus!, screen", "screen, bogus!", ",screen", "screen,", ",all,",
                      "not amzn-mobi", "not amzn-kf8", "amzn-kf8, screen", "screen and (-webkit-min-device-pixel-ratio:0)"] {
            XCTAssertEqual(mask(query), .all, query)
        }
        for query in ["print", "tv", "speech", "handheld", "projection", "unknown-type", "not screen", "not all", "only print", "NOT SCREEN",
                      "print, tv", "not only screen", "only not screen", "only", "not", "and", "screen print", "screen and", "screen and print",
                      "screen and all", "not screen print", ",", ",,", ",bogus,", "screen;", "(", "\"screen\"", "1", "screen (color)"] {
            XCTAssertEqual(mask(query), none, query)
        }
        // Kindle's media types and the escape hacks once written for Internet Explorer name no medium here.
        for query in ["amzn-kf8", "amzn-mobi", "amzn-mobi, amzn-kf8", "amzn-kf8 and (device-aspect-ratio: 1280/800)", "\\0screen",
                      "\\0screen\\,screen\\9", "screen and (min-width:0\\0)", "all and (-ms-high-contrast: none), (-ms-high-contrast: active)"] {
            XCTAssertEqual(mask(query), none, query)
        }
    }

    func testConditionsCombineWithAndOrNotAndParentheses() {
        for query in ["(color)", "(color) and (min-width: 1px)", "(color) and (width) and (height)", "(color) or (monochrome)",
                      "(monochrome) or (grid) or (color)", "not (monochrome)", "screen and (color)", "screen and (color) and (min-width: 1px)",
                      "screen and not (monochrome)", "screen and ((color) or (monochrome))", "((color))", "(((color)))", "(not (monochrome))",
                      "((color) and (not (monochrome)))", "(color) and ((monochrome) or (width))", "not ((monochrome) and (color))",
                      "only screen and (color)", "all and (color)", "(COLOR) AND (WIDTH)", "print, (color)"] {
            XCTAssertEqual(mask(query), .all, query)
        }
        for query in ["(monochrome)", "(color) and (monochrome)", "(monochrome) or (grid)", "not (color)", "print and (color)",
                      "not screen and (color)", "screen and (monochrome)", "not ((color))", "(not (color))", "not all and (color)",
                      "screen and not (color)"] {
            XCTAssertEqual(mask(query), none, query)
        }
        // Grammar errors make the whole query `not all`.
        for query in ["(color) and (width) or (height)", "(color) or (width) and (height)", "screen or (color)", "screen and (color) or (width)",
                      "not (monochrome) and (color)", "not not (color)", "only (color)", "(color) and not (monochrome)", "(color) and",
                      "and (color)", "(color) (width)", "not(monochrome)", "screen and(color)", "(color) or", "()", "( )",
                      "screen and (color) and", "not screen and not (color) and (width)"] {
            XCTAssertEqual(mask(query), none, query)
        }
    }

    func testNegatingAnUnknownFeatureStillMatchesNothing() {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/114")
        // Media Queries 4 §3.2: "An unknown <mf-name> or <mf-value> … results in the value
        // 'unknown'. A <media-query> whose value is 'unknown' must be replaced with not all", and
        // "the negation of unknown is unknown". web-platform-tests pins `not all and (bogus)`.
        XCTAssertEqual(mask("(bogus-feature)"), none)
        XCTAssertEqual(mask("all and (bogus-feature)"), none)
        XCTAssertEqual(mask("(bogus-feature) or (color)"), .all, "true or unknown is true")
        XCTAssertEqual(mask("not ((bogus-feature) and (monochrome))"), .all, "unknown and false is false")
        XCTAssertEqual(mask("not all and (bogus-feature)"), none)
        XCTAssertEqual(mask("not (bogus-feature)"), none)
        XCTAssertEqual(mask("not (bogus-feature: 1)"), none)
        XCTAssertEqual(mask("not (min-orientation: portrait)"), none)
    }

    func testRangeSyntaxAgainstTheNominalViewport() {
        for query in ["(width >= \(width)px)", "(width <= \(width)px)", "(width = \(width)px)", "(\(width)px <= width)", "(\(width)px = width)",
                      "(width>=\(width)px)", "(width > \(width - 1)px)", "(width < \(width + 1)px)", "(\(width - 1)px < width < \(width + 1)px)",
                      "(\(width)px <= width <= \(width)px)", "(\(width + 1)px > width >= \(width)px)", "(height >= \(height)px)",
                      "(\(height + 1)px > height)", "(aspect-ratio >= 3/4)", "(aspect-ratio = \(width) / \(height))", "(resolution >= 1dppx)",
                      "(width >= 1em)", "(WIDTH >= 1PX)", "screen and (width >= 1px)", "(width >= 1px) and (height >= 1px)", "(width > 0)"] {
            XCTAssertEqual(mask(query), .all, query)
        }
        for query in ["(width > \(width)px)", "(width < \(width)px)", "(\(width)px < width)", "(\(width)px < width < \(width + 100)px)",
                      "(\(width - 100)px < width < \(width)px)", "(height < \(height)px)", "(aspect-ratio > 1)", "(width >=)", "(>= 1px)",
                      "(width >= bogus)", "(bogus >= 1px)", "(width >= 1px >= )", "(width => 1px)", "(width >== 1px)", "(width <> 1px)",
                      "(1px < width < 2px < 3px)", "(width)(height)", "(orientation > portrait)"] {
            XCTAssertEqual(mask(query), none, query)
        }
    }

    func testMinAndMaxPrefixesAndEveryLengthUnit() {
        let em = Double(width) / 16
        for query in ["(min-width: \(width)px)", "(max-width: \(width)px)", "(min-width: \(em)em)", "(max-width: \(em)rem)", "(min-width: 0)",
                      "(min-width: \(Double(width) / 96)in)", "(max-width: \(Double(width) * 0.75)pt)", "(min-width: \(Double(width) / 16)pc)",
                      "(min-width: 1cm)", "(min-width: 1mm)", "(min-width: 1Q)", "(min-height: \(height)px)", "(max-height: \(height)px)",
                      "(min-device-width: 1px)", "(max-device-height: 10000px)", "(min-aspect-ratio: 1/100)", "(max-aspect-ratio: 100/1)",
                      "(min-aspect-ratio: 3/4)", "(MIN-WIDTH: 1PX)", "(min-color: 1)", "(min-resolution: 1dppx)", "(min-resolution: 96dpi)",
                      "(width: \(width)px)", "(height: \(height)px)", "(device-width: \(width)px)"] {
            XCTAssertEqual(mask(query), .all, query)
        }
        for query in ["(min-width: \(width + 1)px)", "(max-width: \(width - 1)px)", "(min-width: \(em + 0.1)em)", "(max-width: \(em - 0.1)rem)",
                      "(min-height: \(height + 1)px)", "(max-height: \(height - 1)px)", "(max-aspect-ratio: 1/2)", "(min-aspect-ratio: 2/1)",
                      "(width: \(width - 1)px)", "(min-width)", "(max-width)", "(min-width: bogus)", "(min-width: )", "(min-width: 1px 2px)",
                      "(min-width: 10%)", "(min-width: 1bogus)", "(min-orientation: portrait)", "(max-prefers-color-scheme: dark)",
                      "(min-width 1px)", "(min-width = 1px)", "(: 1px)", "(min-: 1px)"] {
            XCTAssertEqual(mask(query), none, query)
        }
    }

    func testDiscreteFeaturesOfAReaderThatNeitherPrintsNorRunsScripts() {
        for query in ["(orientation: portrait)", "(orientation)", "(color)", "(monochrome: 0)", "(grid: 0)", "(scripting: none)",
                      "(-webkit-min-device-pixel-ratio: 0)", "(-webkit-min-device-pixel-ratio: 1)", "(min-resolution: 1dppx)",
                      "not (scripting)", "not (monochrome)", "not (grid)", "(any-hover: none), (any-hover: hover)",
                      "(pointer: coarse), (pointer: fine)", "(ORIENTATION: PORTRAIT)"] {
            XCTAssertEqual(mask(query), .all, query)
        }
        for query in ["(orientation: landscape)", "(monochrome)", "(grid)", "(scripting)", "(scripting: enabled)", "(orientation: sideways)",
                      "(orientation: 1)", "(color: red)", "(pointer: none)", "(hover: bogus)"] {
            XCTAssertEqual(mask(query), none, query)
        }
        XCTAssertNotEqual(mask("(hover)"), mask("(hover: none)"), "(hover) is the negation of (hover: none)")
        XCTAssertNotEqual(mask("(any-hover)"), mask("(any-hover: none)"))
    }

    func testPrefersColorSchemeFollowsTheAppearanceInEveryPosition() {
        XCTAssertEqual(mask("(prefers-color-scheme: dark)"), .dark)
        XCTAssertEqual(mask("(prefers-color-scheme: light)"), .light)
        XCTAssertEqual(mask("(PREFERS-COLOR-SCHEME: DARK)"), .dark)
        XCTAssertEqual(mask("not (prefers-color-scheme: dark)"), .light)
        XCTAssertEqual(mask("not all and (prefers-color-scheme: dark)"), .light)
        XCTAssertEqual(mask("screen and (prefers-color-scheme: dark)"), .dark)
        XCTAssertEqual(mask("only screen and (prefers-color-scheme: dark) and (color)"), .dark)
        XCTAssertEqual(mask("print and (prefers-color-scheme: dark)"), none)
        XCTAssertEqual(mask("(prefers-color-scheme: dark), (prefers-color-scheme: light)"), .all)
        XCTAssertEqual(mask("(prefers-color-scheme: dark) or (prefers-color-scheme: light)"), .all)
        XCTAssertEqual(mask("(prefers-color-scheme: dark) and (prefers-color-scheme: light)"), none)
        XCTAssertEqual(mask("(prefers-color-scheme: dark), print"), .dark)
        XCTAssertEqual(mask("((prefers-color-scheme: dark) and (color)) or (monochrome)"), .dark)
        XCTAssertEqual(mask("(prefers-color-scheme)"), .all)
        XCTAssertEqual(mask("(prefers-color-scheme: sepia)"), none)
        XCTAssertEqual(mask("(prefers-color-scheme: no-preference)"), none)
        XCTAssertEqual(mask("(min-prefers-color-scheme: dark)"), none)
    }

    func testNestedMediaRulesIntersectAndStatementOrEmptyFormsAreHandled() {
        let sheet = CSSSyntaxSupport.sheet("""
            @media screen { @media print { a { clear: both } } b { clear: both } }
            @media (prefers-color-scheme: dark) { @media (prefers-color-scheme: light) { i { clear: both } } u { clear: both } @media screen { s { clear: both } } }
            @media print { @media screen { q { clear: both } } }
            @media not all { em { clear: both } }
            @media { h1 { clear: both } }
            @MEDIA SCREEN { h2 { clear: both } }
            @media screen; h3 { clear: both }
            @media screen, print and (bogus) { h4 { clear: both } }
            @media (prefers-color-scheme: light) { @supports (clear: both) { @media not print { h5 { clear: both } } } }
            @media bogus! { h6 { clear: both } }
            @media screen { p { clear: both } @media (prefers-color-scheme: dark) { p { float: left } } p { float: right } }
            """)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["b", "u", "s", "h1", "h2", "h3", "h4", "h5", "p", "p", "p"])
        XCTAssertEqual(sheet.rules.map(\.media), [.all, .dark, .dark, .all, .all, .all, .all, .light, .all, .dark, .all])
        XCTAssertFalse(sheet.truncated)
    }

    func testMediaRulesNestedBeyondTheBoundAreDroppedAndReported() {
        func nested(_ depth: Int) -> CSSStyleSheet {
            CSSSyntaxSupport.sheet(String(repeating: "@media screen { ", count: depth) + "p { clear: both } " + String(repeating: "}", count: depth))
        }
        let within = nested(CSSStyleSheet.maximumConditionalNesting)
        XCTAssertEqual(CSSSyntaxSupport.subjects(within), ["p"])
        XCTAssertFalse(within.truncated)
        let beyond = nested(CSSStyleSheet.maximumConditionalNesting + 1)
        XCTAssertEqual(CSSSyntaxSupport.subjects(beyond), [])
        XCTAssertTrue(beyond.truncated)
    }

    func testAppearanceMediaFromLinkStyleImportAndMediaRulesCompose() throws {
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p><p id="b">b</p><p id="c">c</p><p id="d">d</p><p id="e">e</p>"#, head: """
            <link rel="stylesheet" href="dark.css" media="(prefers-color-scheme: dark)"/>
            <link rel="stylesheet" href="main.css"/>
            <style media="(prefers-color-scheme: light)">#b { text-align: right }</style>
            <style media="screen and (prefers-color-scheme: dark)">@media (prefers-color-scheme: light) { #e { text-align: right } }</style>
            """)
        let files = [
            "dark.css": "#a { text-align: right } @media (prefers-color-scheme: light) { #a { font-weight: 700 } } @import 'never.css';",
            "main.css": """
                @import "night.css" (prefers-color-scheme: dark);
                @import "day.css" not all and (prefers-color-scheme: dark);
                @media (prefers-color-scheme: dark) { #d { text-indent: 3px } }
                """,
            "night.css": "#c { text-align: right } @media (prefers-color-scheme: light) { #c { font-weight: 700 } }",
            "day.css": "#d { text-align: right }",
        ]
        let light = try CSSSyntaxSupport.styled(section: section, files: files)
        let dark = try CSSSyntaxSupport.styled(section: section, files: files, dark: true)
        XCTAssertEqual(["a", "b", "c", "d", "e"].map { light.style($0).textAlign }, [.start, .right, .start, .right, .start])
        XCTAssertEqual(["a", "b", "c", "d", "e"].map { dark.style($0).textAlign }, [.right, .start, .right, .start, .start])
        XCTAssertEqual(["a", "c"].map { dark.style($0).fontWeight }, [400, 400], "A light rule inside a dark sheet never applies")
        XCTAssertEqual(["a", "c"].map { light.style($0).fontWeight }, [400, 400])
        XCTAssertEqual(light.style("d").textIndent, .points(0))
        XCTAssertEqual(dark.style("d").textIndent, .points(3))
        XCTAssertEqual([light, dark].map(\.report.unreadableResources), [0, 0], "An @import after a rule is never followed")
    }

    func testSupportsConditions() {
        func supports(_ condition: String) -> Bool { !CSSSyntaxSupport.sheet("@supports \(condition) { p { clear: both } }").rules.isEmpty }
        for condition in ["(clear: both)", "(color: red)", "( color : red )", "(COLOR: RED)", "(color: red) and (clear: both)",
                          "(bogus: 1) or (color: red)", "(color: red) or (bogus: 1) or (worse: 2)", "not (bogus: 1)", "not (color: bogus)",
                          "(not (bogus: 1))", "not (not (color: red))", "((color: red))", "((color: red) or (bogus: 1)) and (clear: both)",
                          "(color: red) and (not (bogus: 1))", "selector(p > i)", "selector(p:nth-child(2n + 1))", "selector(:is(p, i))",
                          "not selector(:bogus)", "not selector(p >)", "not bogus-function(1)", "(color: red) and selector(p)",
                          "(margin: 1px 2px)", "(font: italic 12px serif)"] {
            XCTAssertTrue(supports(condition), condition)
        }
        for condition in ["(bogus: 1)", "(color: bogus)", "(color:)", "(color)", "(color: red) and (bogus: 1)", "(bogus: 1) or (worse: 2)",
                          "not (color: red)", "(color: red) and (clear: both) or (bogus: 1)", "(color: red) or (clear: both) and (bogus: 1)",
                          "not (bogus: 1) and (color: red)", "not not (bogus: 1)", "selector(:bogus)", "selector(p >)", "selector()",
                          "bogus-function(1)", "not(bogus: 1)", "(color: red) and(clear: both)", "", "color: red", "(color: red) and",
                          "and (color: red)", "(color: red) (clear: both)", "()", "(width: 10)"] {
            XCTAssertFalse(supports(condition), condition)
        }
    }

    func testSupportsRulesNestWithMediaAndKeepTheirMedia() {
        let sheet = CSSSyntaxSupport.sheet("""
            @supports (clear: both) { @media (prefers-color-scheme: dark) { a { clear: both } } b { clear: both } @supports (bogus: 1) { i { clear: both } } }
            @media (prefers-color-scheme: dark) { @supports not (bogus: 1) { u { clear: both } } }
            @supports (bogus: 1) { @media screen { s { clear: both } } @font-face { font-family: Hidden; src: url(h.ttf) } }
            @SUPPORTS (clear: both) { @font-face { font-family: Shown; src: url(s.ttf) } }
            """)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["a", "b", "u"])
        XCTAssertEqual(sheet.rules.map(\.media), [.dark, .all, .dark])
        XCTAssertEqual(sheet.fontFaces.map(\.family), ["shown"])
    }
}
