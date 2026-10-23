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
        // Media Queries 4 §3.2: "An unknown <mf-name> or <mf-value> … results in the value
        // 'unknown'. A <media-query> whose value is 'unknown' must be replaced with not all", and
        // "the negation of unknown is unknown". web-platform-tests pins `not all and (bogus)` (#114).
        XCTAssertEqual(mask("(bogus-feature)"), none)
        XCTAssertEqual(mask("all and (bogus-feature)"), none)
        XCTAssertEqual(mask("(bogus-feature) or (color)"), .all, "true or unknown is true")
        XCTAssertEqual(mask("not ((bogus-feature) and (monochrome))"), .all, "unknown and false is false")
        XCTAssertEqual(mask("not all and (bogus-feature)"), none)
        XCTAssertEqual(mask("not (bogus-feature)"), none)
        XCTAssertEqual(mask("not (bogus-feature: 1)"), none)
        XCTAssertEqual(mask("not (min-orientation: portrait)"), none)
    }

    func testUnknownPassesThroughNotAndOrTheMediaTypeAndTheList() {
        // web-platform-tests css/mediaqueries/test_media_queries.html, "three-valued logic", with
        // its (width) true and (height) false here (color) and (monochrome), and negation-001
        // and -002.html: Kleene's and, or and not (§3.1), and an unknown query is `not all`.
        for query in ["((unknown) or (color))", "not ((unknown) and (monochrome))", "(color) or (not ((unknown) and (color)))",
                      "(color) or (not ((unknown) or (color)))", "(color) or (not ((unknown) and (monochrome)))",
                      "(color) and (not ((unknown) and (monochrome)))", "(color) or (not ((unknown) or (monochrome)))",
                      "not (unknown(color) and (monochrome))", "not print and (unknown)", "not unknown-type and (unknown)",
                      "(unknown), (color)", "screen and (unknown), screen", "not all and (unknown), not print"] {
            XCTAssertEqual(mask(query), .all, query)
        }
        for query in ["(unknown)", "not (unknown)", "((unknown) and (color))", "not ((unknown) and (color))", "((unknown) and (monochrome))",
                      "not ((unknown) or (color))", "((unknown) or (monochrome))", "not ((unknown) or (monochrome))",
                      "(color) and (not ((unknown) and (color)))", "(color) and (not ((unknown) or (color)))",
                      "(color) and (not ((unknown) or (monochrome)))", "unknown(color)", "not unknown(color)",
                      "not (unknown(color) or (monochrome))", "only all and (unknown)",
                      "not screen and (unknown)", "not all and (unknown) and (color)", "not (unknown), print"] {
            XCTAssertEqual(mask(query), none, query)
        }
    }

    func testWhatIsNotAConditionInParenthesesIsUnknownButAGrammarErrorOutsideIsNotAll() {
        // `<general-enclosed>` (§2.2): parentheses around anything that is neither a condition nor
        // a feature, or a function, are unknown, so `or` can still be true beside them. The same
        // words outside parentheses are not a query at all (§3.2), whatever `or` joins them to.
        for query in ["(not (monochrome) and (color))", "(not (monochrome) or (color))", "((color) and not (monochrome))",
                      "((color) or not (monochrome))", "((color) and (width) or (height))", "()", "( )", "(color) and ()", "not ()",
                      "not ((color) and not (monochrome))", "not (1px < 2px)", "not (600px = 600px)", "not (width width)"] {
            XCTAssertEqual(mask(query), none, query)
        }
        for query in ["(color) or ((color) and not (monochrome))", "(color) or ()", "(color) or (width width)", "(color) or f(x)",
                      "(color) or (1px < 2px)"] {
            XCTAssertEqual(mask(query), .all, query)
        }
        // `<any-value>` holds no bad string or URL and no stray closing bracket.
        for query in ["(color) or (\"bad\nstring)", "(color) or (url(a b))", "(color) or ([)])", "(color) or [color]",
                      "(color) or {color}", "(color) or not (monochrome)", "(color) or color"] {
            XCTAssertEqual(mask(query), none, query)
        }
        // `layer` is never a media type (§2.1; web-platform-tests mq-invalid-media-type-layer-001).
        for query in ["layer", "not layer", "only layer", "not layer and (color)", "layer, print"] {
            XCTAssertEqual(mask(query), none, query)
        }
        XCTAssertEqual(mask("layer, screen"), .all)
    }

    func testAValueItsFeatureDoesNotTakeIsUnknownAndOneItTakesIsKnown() {
        // A feature is known when it or its negation matches, and unknown when neither does
        // (web-platform-tests test_media_queries.html, expression_should_be_known/_unknown, and
        // prefers-color-scheme, prefers-contrast, scripting and display-mode.html).
        func known(_ feature: String) -> Bool { mask("(\(feature)), not all and (\(feature))") == .all }
        for feature in ["width: 0", "width: -0", "width: 0.0", "width: 0em", "width: -1px", "min-width: -1px", "max-height: -0cm",
                        "width > 0", "width < -100000em", "0px < width < 100000px", "100000px > width >= 0px", "width = 0.001mm",
                        "aspect-ratio: 1", "aspect-ratio: 0.5", "aspect-ratio: 1  / \t\n1", "max-aspect-ratio: 1/0",
                        "device-aspect-ratio: 0/0", "aspect-ratio: 0/1", "aspect-ratio: 1.0/1.0", "color: -1", "min-monochrome: 327",
                        "max-color-index: 0", "resolution: 0dpi", "resolution: 1.5x", "resolution\t: 120dpcm", "max-resolution: infinite",
                        "resolution < infinite", "grid: 1", "grid: -0", "scan: interlace", "overflow-block: paged", "update: slow",
                        "pointer: none", "prefers-contrast: custom", "scripting: initial-only", "display-mode: picture-in-picture",
                        "inverted-colors: inverted", "forced-colors: active", "color-gamut: rec2020", "dynamic-range: high",
                        "prefers-reduced-data: reduce", "-webkit-device-pixel-ratio: 2", "-webkit-max-device-pixel-ratio: 1.5",
                        "min--moz-device-pixel-ratio: 1.5", "max-device-pixel-ratio: 3", "prefers-color-scheme", "orientation"] {
            XCTAssertTrue(known(feature), feature)
        }
        for feature in ["bogus", "bogus: 1", "--foo: bar", "min-width", "max-orientation", "min-orientation: portrait", "min-grid: 0",
                        "max-grid: 1", "grid: 2", "grid: -1", "grid: 0.0", "min-scan: interlace", "scan: 1", "color: 1.0", "color: 1/1",
                        "min-monochrome: 1.5", "aspect-ratio: -1/1", "aspect-ratio: 1/-1", "aspect-ratio: invalid",
                        "aspect-ratio: 1 / invalid", "aspect-ratio: 1 invalid", "aspect-ratio: 1px", "resolution: -3dpi",
                        "resolution: 2", "min-resolution: 1px", "resolution: none", "width: 100", "min-width: 2dppx",
                        "width: 10%", "width: 1px 2px", "width > = 0px", "width < = 0px", "0px = width = 100px",
                        "0px < width > 100px", "0px > width < 100px", "min-width > 0px", "1px < 2px", "width < height",
                        "orientation > portrait", "overflow-block = scroll", "overflow-block < scroll", "overflow-block: optional-paged",
                        "update: some-random-invalid-thing", "prefers-color-scheme: no-preference", "prefers-color-scheme: none",
                        "prefers-color-scheme: dark light", "prefers-color-scheme: light/dark", "prefers-contrast: high",
                        "prefers-contrast: none", "scripting: 0", "scripting: invalid", "display-mode: none", "display-mode: 10px",
                        "hover: bogus", "-webkit-min-bogus: 0", "-webkit-min-device-pixel-ratio", "orientation:", "width:",
                        "color-gamut: 1"] {
            XCTAssertFalse(known(feature), feature)
        }
        XCTAssertEqual(mask("(max-resolution: infinite)"), .all)
        XCTAssertEqual(mask("(resolution: infinite)"), none)
        XCTAssertEqual(mask("(max-aspect-ratio: 1/0)"), .all, "A degenerate ratio is compared by its quotient")
        XCTAssertEqual(mask("(-webkit-max-device-pixel-ratio: 1.5)"), none)
        XCTAssertEqual(mask("(max--moz-device-pixel-ratio: 2)"), .all)
    }

    func testAStyleRuleUnderAnUnknownNegationAppliesNowhere() throws {
        let sheet = CSSSyntaxSupport.sheet("""
            @media not (bogus-feature) { a { clear: both } }
            @media not all and (bogus-feature) { b { clear: both } }
            @media not (min-orientation: portrait) { i { clear: both } }
            @media not print and (bogus-feature) { u { clear: both } }
            @media (color) or ((color) and not (monochrome)) { s { clear: both } }
            """)
        XCTAssertEqual(CSSSyntaxSupport.subjects(sheet), ["u", "s"])
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p><p id="b">b</p>"#, head: """
            <style media="not (bogus-feature: 1)">#a { text-indent: 3px }</style>
            <style media="not (bogus-feature: 1), screen">#b { text-indent: 3px }</style>
            """)
        let styled = try CSSSyntaxSupport.styled(section: section)
        XCTAssertEqual(["a", "b"].map { styled.style($0).textIndent }, [.points(0), .points(3)])
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

    /// Media Queries 4 §2.4 takes a `<length>`, `<resolution>`, `<number>` or `<integer>` as a
    /// feature's value, and CSS Values 4 §10 lets a math function stand wherever its type
    /// does. Relative units are those of the initial values (§1.3): an `em` of 16 pixels, an
    /// `ex` and a `ch` of half that, and viewport units of the nominal viewport (#756;
    /// web-platform-tests css/mediaqueries/mq-calc-*.html, relative-units-*.html and
    /// test_media_queries.html's `expression_should_be_known("resolution: calc(6x / 2)")`).
    func testMathFunctionsAndRelativeUnitsInAFeaturesValue() {
        // The issue's queries, and their negations.
        for (query, matches) in [("(min-width: calc(100px + 1em))", true), ("(resolution: calc(6x / 2))", false),
                                 ("(min-width: 10vw)", true), ("(max-width: 40ex)", false), ("(min-width: 30ch)", true)] {
            XCTAssertEqual(mask(query), matches ? .all : none, query)
            XCTAssertEqual(mask("not \(query)"), matches ? none : .all, "not \(query)")
            XCTAssertEqual(mask("not all and \(query)"), matches ? none : .all, "not all and \(query)")
        }
        let em = Double(width) / 16
        for query in ["(width: calc(\(width)px))", "(width: calc(\(em)em))", "(width: calc(\(width / 2)px * 2))", "(width: 100vw)",
                      "(height: 100vh)", "(width: 100vmin)", "(height: 100vmax)", "(width: 100vi)", "(height: 100dvh)", "(width: 100cqw)",
                      "(width: \(em * 2)ex)", "(width: \(em * 2)ch)", "(min-width: 30lh)", "(min-width: 30rlh)", "(min-width: 30cap)",
                      "(width: \(em)ic)", "(width: calc(50vw + \(width / 2)px))", "(width: min(\(width)px, 100em))",
                      "(width: clamp(0px, \(width)px, 1000px))", "(width >= calc(100vh - \(height - width)px))",
                      "(calc(10px) < width < calc(10em * 4))", "(min-width: calc(1px / 0 * -1))", "(min-width: calc(0 / 0 * 1px))",
                      "(resolution: calc(1x + 1dppx))", "(resolution: calc(192dpi))", "(min-resolution: calc(2x * 0.5))",
                      "(max-resolution: calc(infinity * 1x))", "(min-resolution: calc(-1x))", "(-webkit-device-pixel-ratio: calc(4 / 2))",
                      "(color: calc(4 * 2))", "(min-color: calc(1.4))", "(aspect-ratio: calc(3) / calc(4))", "(min-aspect-ratio: calc(1 / 2))",
                      "(monochrome: calc(0))"] {
            XCTAssertEqual(mask(query), .all, query)
        }
        for query in ["(min-width: calc(\(width)px + 1px))", "(max-width: calc(\(em)em - 1px))", "(min-width: 101vw)", "(max-height: 99vh)",
                      "(min-width: \(em * 2 + 1)ex)", "(max-resolution: calc(1dppx))", "(color: calc(7))",
                      "(max-width: calc(0 / 0 * 1px))", "(max-aspect-ratio: calc(-1) / 1)"] {
            XCTAssertEqual(mask(query), none, query)
        }
        // A math function of another type is unknown, as a literal of it is.
        func known(_ feature: String) -> Bool { mask("(\(feature)), not all and (\(feature))") == .all }
        for feature in ["width: calc(1)", "width: calc(10%)", "width: calc(1px + 1)", "width: calc(1dppx)", "width: calc(1deg)",
                        "width: min(1px, 1)", "resolution: calc(2)", "resolution: calc(1px)", "color: calc(1px)",
                        "aspect-ratio: calc(1px) / 1", "-webkit-device-pixel-ratio: calc(1x)", "width: calc()", "width: bogus(1px)"] {
            XCTAssertFalse(known(feature), feature)
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
        // `filter` follows the appearance, so it shows which rules apply in which (#130).
        let section = StyleTestSupport.xhtml(body: #"<p id="a">a</p><p id="b">b</p><p id="c">c</p><p id="d">d</p><p id="e">e</p>"#, head: """
            <link rel="stylesheet" href="dark.css" media="(prefers-color-scheme: dark)"/>
            <link rel="stylesheet" href="main.css"/>
            <style media="(prefers-color-scheme: light)">#b { filter: invert(1) }</style>
            <style media="screen and (prefers-color-scheme: dark)">@media (prefers-color-scheme: light) { #e { filter: invert(1) } }</style>
            """)
        let files = [
            "dark.css": "#a { filter: invert(1) } @media (prefers-color-scheme: light) { #a { color: transparent } } @import 'never.css';",
            "main.css": """
                @import "night.css" (prefers-color-scheme: dark);
                @import "day.css" not all and (prefers-color-scheme: dark);
                @media (prefers-color-scheme: dark) { #d { text-indent: 3px } }
                """,
            "night.css": "#c { filter: invert(1) } @media (prefers-color-scheme: light) { #c { color: transparent } }",
            "day.css": "#d { filter: invert(1) }",
        ]
        let light = try CSSSyntaxSupport.styled(section: section, files: files)
        let dark = try CSSSyntaxSupport.styled(section: section, files: files, dark: true)
        XCTAssertEqual(["a", "b", "c", "d", "e"].map { light.style($0).invertsColors }, [false, true, false, true, false])
        XCTAssertEqual(["a", "b", "c", "d", "e"].map { dark.style($0).invertsColors }, [true, false, true, false, false])
        XCTAssertEqual(["a", "c"].map { dark.style($0).color }, [nil, nil], "A light rule inside a dark sheet never applies")
        XCTAssertEqual(["a", "c"].map { light.style($0).color }, [nil, nil])
        XCTAssertEqual([light, dark].map { $0.style("d").textIndent }, [.points(0), .points(0)],
                       "What does not paint is resolved as in light appearance")
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
