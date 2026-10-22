@testable import EPUBViewing
import XCTest

/// CSS Values and Units: every unit, number forms, range checks, `calc()` and the comparison
/// functions, and the bounds that keep hostile values out of layout.
final class CSSCascadeValueCoverageTests: XCTestCase {
    private func points(_ length: ComputedStyle.Length, file: StaticString = #filePath, line: UInt = #line) -> CGFloat {
        CSSCascadeSupport.points(length, file: file, line: line)
    }

    /// One `<p>` per rule body, so a table of declarations costs one document.
    private func paragraphs(_ bodies: [String], extra: String = "") throws -> [ComputedStyle] {
        let body = bodies.indices.map { "<p id=\"e\($0)\">x</p>" }.joined()
        let css = bodies.enumerated().map { "#e\($0.offset) { \($0.element) }" }.joined(separator: "\n")
        let result = try CSSCascadeSupport.styled(body, css: extra + "\n" + css)
        return bodies.indices.map { result.style("e\($0)") }
    }

    func testEveryAbsoluteUnitConvertsToPointsWhateverItsCase() throws {
        let style = try CSSCascadeSupport.paragraph("""
            margin-left: 96PX; margin-right: 72pt; margin-top: 6pc; margin-bottom: 1in; padding-left: 2.54cm;
            padding-right: 25.4mm; padding-top: 101.6Q; padding-bottom: 1IN; text-indent: 1Pc; width: 0.5In
            """)
        for length in [style.margin.left, style.margin.right, style.margin.top, style.margin.bottom,
                       style.padding.left, style.padding.right, style.padding.top, style.padding.bottom] {
            XCTAssertEqual(points(length), 96, accuracy: 0.0001, "An inch is 96 CSS px, 72pt, 6pc, 2.54cm, 25.4mm and 101.6Q")
        }
        XCTAssertEqual(points(style.textIndent), 16, accuracy: 0.0001)
        XCTAssertEqual(points(style.width), 48, accuracy: 0.0001)
    }

    func testFontRelativeUnitsUseTheElementsOwnSizeWhateverTheDeclarationOrder() throws {
        let result = try CSSCascadeSupport.styled(#"<p id="p">x</p>"#, css: """
            html { font-size: 10px }
            #p { margin-left: 2em; margin-right: 1.5rem; padding-left: 1EM; text-indent: 1ReM; width: 10ch; font-size: 20px }
            """)
        let style = result.style("p")
        XCTAssertEqual(style.fontSize, 20)
        XCTAssertEqual(style.margin.left, .points(40), "em is the element's own computed size, though font-size comes last in the rule")
        XCTAssertEqual(style.margin.right, .points(15))
        XCTAssertEqual(style.padding.left, .points(20))
        XCTAssertEqual(style.textIndent, .points(10))
        // CSS Values §6.1.1: the advance of "0", or 0.5em when that is impractical to measure.
        XCTAssertGreaterThanOrEqual(points(style.width), 80)
        XCTAssertLessThanOrEqual(points(style.width), 130)
    }

    func testViewportUnitsStaySymbolicIncludingLogicalAndDynamicVariants() throws {
        let style = try CSSCascadeSupport.paragraph("""
            width: 50vw; height: 25vh; margin-left: 10vi; margin-top: 5vb; padding-left: 5svw; padding-top: 6dvh; max-width: 80LVW
            """)
        XCTAssertEqual(style.width, .viewportWidth(50))
        XCTAssertEqual(style.height, .viewportHeight(25))
        XCTAssertEqual(style.margin.left, .viewportWidth(10), "The inline axis of horizontal text is the width")
        XCTAssertEqual(style.margin.top, .viewportHeight(5))
        XCTAssertEqual(style.padding.left, .viewportWidth(5))
        XCTAssertEqual(style.padding.top, .viewportHeight(6))
        XCTAssertEqual(style.maxWidth, .viewportWidth(80))
    }

    /// CSS Values 3, 5.1.2: `vmin` is the smaller of `vw` and `vh`, `vmax` the larger. Which side
    /// that is only layout knows, so they stay symbolic as themselves, not as `vw` and `vh`.
    func testViewportMinimumAndMaximumUnitsStaySymbolicAndResolveAgainstTheSmallerAndLargerSide() throws {
        let style = try CSSCascadeSupport.paragraph("""
            width: 50vmin; height: 25VMAX; margin-left: 10svmin; margin-top: 5dvmax; padding-left: 2cqmin;
            max-width: calc(40vmin + 40vmin); min-height: calc(10vmax * 2)
            """)
        XCTAssertEqual(style.width, .viewportMin(50))
        XCTAssertEqual(style.height, .viewportMax(25))
        XCTAssertEqual(style.margin.left, .viewportMin(10))
        XCTAssertEqual(style.margin.top, .viewportMax(5))
        XCTAssertEqual(style.padding.left, .viewportMin(2), "A container unit with no container is the small viewport's")
        XCTAssertEqual(style.maxWidth, .viewportMin(80))
        XCTAssertEqual(style.minHeight, .viewportMax(20))
        for (viewport, smaller, larger) in [(CGSize(width: 300, height: 500), 300.0, 500.0), (CGSize(width: 700, height: 400), 400.0, 700.0)] {
            XCTAssertEqual(style.width.resolve(reference: 0, viewport: viewport), smaller / 2, "\(viewport)")
            XCTAssertEqual(style.height.resolve(reference: 0, viewport: viewport), larger / 4, "\(viewport)")
        }
        // Font sizes resolve when they are computed, against the nominal 600 × 800 media-query
        // viewport, as `vw` and `vh` do.
        let fonts = try paragraphs(["font-size: 5vmin", "font-size: 5vmax", "font-size: calc(2vmin + 2vmax)"])
        XCTAssertEqual(fonts.map(\.fontSize), [30, 40, 28])
    }

    func testPercentagesStaySymbolicForLayout() throws {
        let style = try CSSCascadeSupport.paragraph("""
            width: 50%; margin-left: -10%; text-indent: 5%; padding-left: 7.5%; max-width: 80%; min-height: 20%; position: relative; left: 3%
            """)
        XCTAssertEqual(style.width, .percent(50))
        XCTAssertEqual(style.margin.left, .percent(-10))
        XCTAssertEqual(style.textIndent, .percent(5))
        XCTAssertEqual(style.padding.left, .percent(7.5))
        XCTAssertEqual(style.maxWidth, .percent(80))
        XCTAssertEqual(style.minHeight, .percent(20))
        XCTAssertEqual(style.positionLeft, .percent(3))
    }

    func testUnitlessZeroIsALengthAndOtherUnitlessNumbersAreNot() throws {
        let styles = try paragraphs([
            "margin: 5px; margin: 0; padding: 5px; padding: -0; text-indent: 5px; text-indent: +0; width: 5px; width: 0.0",
            "width: 10px; width: 10; margin-left: 5px; margin-left: 7; text-indent: 3px; text-indent: 1.5; line-height: 2",
        ])
        XCTAssertEqual(styles[0].margin, .init(.points(0)))
        XCTAssertEqual(styles[0].padding, .init(.points(0)))
        XCTAssertEqual(styles[0].textIndent, .points(0))
        XCTAssertEqual(styles[0].width, .points(0))
        XCTAssertEqual(styles[1].width, .points(10), "A unitless length is invalid and leaves the earlier declaration")
        XCTAssertEqual(styles[1].margin.left, .points(5))
        XCTAssertEqual(styles[1].textIndent, .points(3))
        XCTAssertEqual(styles[1].lineHeight, .multiple(2), "line-height does take a number")
    }

    func testSignedFractionalAndExponentNumbersParse() throws {
        let style = try CSSCascadeSupport.paragraph("""
            margin-left: +10px; margin-right: .5em; margin-top: 1.5e1px; margin-bottom: 1E1PX; text-indent: -1.5e-1em;
            padding-left: 1e0px; line-height: +1.5
            """)
        XCTAssertEqual(style.margin.left, .points(10))
        XCTAssertEqual(style.margin.right, .points(8))
        XCTAssertEqual(style.margin.top, .points(15))
        XCTAssertEqual(style.margin.bottom, .points(10))
        XCTAssertEqual(points(style.textIndent), -2.4, accuracy: 0.0001)
        XCTAssertEqual(style.padding.left, .points(1))
        XCTAssertEqual(style.lineHeight, .multiple(1.5))
    }

    func testNegativeValuesAreRejectedWhereAPropertyDisallowsThem() throws {
        let style = try CSSCascadeSupport.paragraph("""
            padding-left: 3px; padding-left: -1px; width: 30px; width: -1px; height: 31px; height: -5%; min-width: 4px; min-width: -4px;
            max-width: 50px; max-width: -50px; border-top: 2px solid; border-top-width: -2px; font-size: 20px; font-size: -20px;
            line-height: 3; line-height: -3; border-spacing: 4px; border-spacing: -4px; padding-right: 6px; padding-right: -6%
            """)
        XCTAssertEqual(style.padding.left, .points(3))
        XCTAssertEqual(style.padding.right, .points(6))
        XCTAssertEqual(style.width, .points(30))
        XCTAssertEqual(style.height, .points(31))
        XCTAssertEqual(style.minWidth, .points(4))
        XCTAssertEqual(style.maxWidth, .points(50))
        XCTAssertEqual(style.border.top.width, 2)
        XCTAssertEqual(style.fontSize, 20)
        XCTAssertEqual(style.lineHeight, .multiple(3))
        XCTAssertEqual(style.borderSpacing, CGSize(width: 4, height: 4))
    }

    func testNegativeValuesAreKeptWhereAPropertyAllowsThem() throws {
        let style = try CSSCascadeSupport.paragraph("""
            margin: -5px -1em; text-indent: -2em; letter-spacing: -1px; word-spacing: -2px; vertical-align: -3px;
            position: relative; top: -4px; left: -5%
            """)
        XCTAssertEqual(style.margin, .init(top: .points(-5), right: .points(-16), bottom: .points(-5), left: .points(-16)))
        XCTAssertEqual(style.textIndent, .points(-32))
        XCTAssertEqual(style.letterSpacing, -1)
        XCTAssertEqual(style.wordSpacing, -2)
        XCTAssertEqual(style.verticalAlign, .offset(-3))
        XCTAssertEqual(style.positionTop, .points(-4))
        XCTAssertEqual(style.positionLeft, .percent(-5))
    }

    func testCalcAddsSubtractsMultipliesAndDividesThroughNesting() throws {
        let style = try CSSCascadeSupport.paragraph("""
            width: calc(1px + 2px); height: calc(10px - 4px); margin-left: calc(2 * 3px); margin-right: calc(3px * 2);
            margin-top: calc(12px / 4); margin-bottom: calc(calc(10px + 5px) * 2); padding-left: calc(2 * (3px + (1em - 5px)));
            padding-right: -webkit-calc(1px + 1px); padding-top: CALC(1PX + 1Em); text-indent: calc(1px - -2px);
            min-width: calc( 1px*2 ); max-width: calc(1em * 2 / 4); padding-bottom: calc(100% / 4)
            """)
        XCTAssertEqual(style.width, .points(3))
        XCTAssertEqual(style.height, .points(6))
        XCTAssertEqual(style.margin.left, .points(6))
        XCTAssertEqual(style.margin.right, .points(6))
        XCTAssertEqual(style.margin.top, .points(3))
        XCTAssertEqual(style.margin.bottom, .points(30))
        XCTAssertEqual(style.padding.left, .points(28))
        XCTAssertEqual(style.padding.right, .points(2))
        XCTAssertEqual(style.padding.top, .points(17))
        XCTAssertEqual(style.textIndent, .points(3))
        XCTAssertEqual(style.minWidth, .points(2))
        XCTAssertEqual(style.maxWidth, .points(8))
        XCTAssertEqual(style.padding.bottom, .percent(25))
    }

    func testCalcWithATypeErrorOrMalformedSyntaxLeavesTheEarlierDeclaration() throws {
        let invalid = ["calc(1px + 2)", "calc(2px * 3px)", "calc(6 / 2px)", "calc()", "calc(1px + )", "calc(+ 1px)", "calc(1px 2px)",
                       "calc(1px+2px)", "calc(1px -2px)", "calc(1px * )", "calc(1px / )", "calc(2)", "calc(1px, 2px)", "calc(1px + 2deg)"]
        let styles = try paragraphs(invalid.map { "width: 11px; width: \($0)" })
        for (expression, style) in zip(invalid, styles) { XCTAssertEqual(style.width, .points(11), expression) }
    }

    /// CSS Values 4 §10 (calc() syntax): "whitespace is required on both sides of the + and - operators."
    func testCalcRequiresWhitespaceOnBothSidesOfPlus() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/125")
        let style = try CSSCascadeSupport.paragraph("width: 11px; width: calc(1px+ 2px)")
        XCTAssertEqual(style.width, .points(11), "`calc(1px+ 2px)` is invalid, as `calc(1px +2px)` is, so the earlier width stays")
    }

    /// CSS Values 4 §10 (calc() syntax): `<calc-product> = <calc-value> [ [ '*' | '/' ] <calc-value> ]*`, where a
    /// `<calc-value>` is also a parenthesized sum; a product needs only one side to be a number.
    func testCalcMultipliesAndDividesByNumericSubexpressions() throws {
        let cases: [(String, CGFloat)] = [("calc(2 * 3 * 4px)", 24), ("calc((1 + 2) * 4px)", 12), ("calc(4px * (1 + 2))", 12),
                                          ("calc(2 / 4 * 10px)", 5), ("calc(12px / (1 + 2))", 4), ("calc(1em * (18 / 16))", 18)]
        let styles = try paragraphs(cases.map { "width: \($0.0)" })
        for (item, style) in zip(cases, styles) {
            guard case .points(let value) = style.width else { XCTFail("\(item.0) computed to \(style.width), not \(item.1)px"); continue }
            XCTAssertEqual(value, item.1, accuracy: 0.0001, item.0)
        }
    }

    /// `line-height` takes a `<number>`, and a math function may stand wherever its type is allowed
    /// (CSS Values 4 §10): designers write the ratio, `calc(24 / 16)`.
    func testLineHeightAcceptsANumericCalcExpression() throws {
        let styles = try paragraphs(["line-height: calc(24 / 16)", "line-height: calc(1 + 0.5)", "line-height: calc(1.5)"])
        XCTAssertEqual(styles[2].lineHeight, .multiple(1.5))
        XCTAssertEqual(styles[0].lineHeight, .multiple(1.5), "calc(24 / 16)")
        XCTAssertEqual(styles[1].lineHeight, .multiple(1.5), "calc(1 + 0.5)")
    }

    /// CSS Values 4 §10.8–§10.9: any `<calc-value>` that is a number, a constant, a parenthesised
    /// sum or a nested math function, is a factor or a divisor; a product or quotient needs a
    /// number on one side of `*` and on the right of `/`, and a sum one type throughout (#122).
    func testCalcFactorsAndDivisorsAreAnyNumberSubexpression() throws {
        let cases: [(String, CGFloat)] = [("calc(4px * 2 * 3)", 24), ("calc((2 * 3) * 4px)", 24), ("calc(4px / 2 / 2)", 1),
                                          ("calc(10px * (1 / 4))", 2.5), ("calc(min(2, 3) * 4px)", 8), ("calc(4px * max(1, 2))", 8),
                                          ("calc(clamp(1, 5, 3) * 1px)", 3), ("calc(1px * calc(2 + 3))", 5), ("calc(20px / calc(2 * 5))", 2),
                                          ("calc((1 + 1) * (2px + 3px))", 10), ("calc(2 * (1 + 1) * (1em - 6px))", 40),
                                          ("calc(-1 * -4px)", 4), ("calc(1px * (3 - 1) / (1 + 1))", 1), ("calc(pi * 10px)", 31.415_926_5),
                                          ("calc(E * 10px)", 27.182_818_3), ("calc(2px * PI / pi)", 2), ("min(10px, 2 * 4px)", 8),
                                          ("calc(1em * (18 / 16) + 2 * (1px * 3))", 24)]
        let styles = try paragraphs(cases.map { "width: 11px; width: \($0.0)" })
        for (item, style) in zip(cases, styles) {
            guard case .points(let value) = style.width else { XCTFail("\(item.0) computed to \(style.width), not \(item.1)px"); continue }
            XCTAssertEqual(value, item.1, accuracy: 0.0001, item.0)
        }
        XCTAssertEqual(try CSSCascadeSupport.paragraph("width: calc(100% / (2 + 2))").width, .percent(25))
        let invalid = ["calc((1px + 1px) * 2px)", "calc(2 / 1px)", "calc(4px / (1px + 1px))", "calc(2 * 3)", "calc((1 + 2))",
                       "calc(1px + (1 + 2))", "calc(1 + 2px)", "calc(min(1, 2) * 3px * 1px)", "calc(1px * pi * 2px)",
                       "calc(bogus * 1px)", "calc(-pi * 1px)", "calc(infinity)", "calc(2 * (1px * 1px))", "calc(1px * (2 + 1px))",
                       "min(1px, 2)", "calc(e)"]
        let rejected = try paragraphs(invalid.map { "width: 11px; width: \($0)" })
        for (expression, style) in zip(invalid, rejected) { XCTAssertEqual(style.width, .points(11), expression) }
    }

    /// CSS Values 4 §10.9.2: dividing by zero gives an infinity, and zero by zero NaN, which every
    /// comparison function returns; at the top level an infinity is the end of the range the
    /// property allows and NaN is 0 (web-platform-tests calc-catch-divide-by-0.html and
    /// calc-infinity-nan-computed.html).
    func testDivisionByZeroIsInfiniteAndClampedToTheRangeAndNaNIsZero() throws {
        let widths: [(String, CGFloat)] = [("calc(100px / 0)", StyleLimits.extent.upperBound),
                                           ("calc(100px / (2 - 2))", StyleLimits.extent.upperBound),
                                           ("calc(100px / (2 - (-62 + 64)))", StyleLimits.extent.upperBound),
                                           ("calc(100px * (1 / 0))", StyleLimits.extent.upperBound),
                                           ("calc(1px * max(1/0, 0))", StyleLimits.extent.upperBound),
                                           ("calc(infinity * 1px)", StyleLimits.extent.upperBound),
                                           ("calc(max(infinity * 1px, 10px))", StyleLimits.extent.upperBound),
                                           ("calc(1px * min(1/0, 0))", 0), ("calc(100px * 0 / 0)", 0), ("calc(1px * max(0/0, 0))", 0),
                                           ("calc(1px * clamp(0, 0/0, 10))", 0), ("calc(1px * clamp(-1/0, 0, 1/0))", 0),
                                           ("calc(1px * clamp(-1/0, 1/0, 10))", 10), ("calc(NaN * 1px)", 0), ("calc(nan * 1rem)", 0),
                                           ("max(15px, NaN * 1px)", 0), ("max(NaN * 1px, 15px)", 0), ("min(15px, NaN * 1px)", 0),
                                           ("clamp(NaN * 1px, 5px, 10px)", 0), ("calc(infinity * 1px - infinity * 1px)", 0),
                                           ("calc(100px / infinity)", 0), ("calc(10.135262721212548pc - 199pt / NaN)", 0)]
        let styles = try paragraphs(widths.map { "width: 11px; width: \($0.0)" })
        for (item, style) in zip(widths, styles) {
            guard case .points(let value) = style.width else { XCTFail("\(item.0) computed to \(style.width), not \(item.1)px"); continue }
            XCTAssertEqual(value, item.1, accuracy: 0.0001, item.0)
        }
        let style = try CSSCascadeSupport.paragraph("""
            margin-left: calc(-1px / 0); margin-right: calc(1px / -0); text-indent: calc(-infinity * 1em); padding-left: calc(1px / 0);
            line-height: calc(1 / 0); font-size: calc(1px / 0); border-left: calc(1px / 0) solid; letter-spacing: calc(0px / 0)
            """)
        XCTAssertEqual(style.margin.left, .points(StyleLimits.offset.lowerBound))
        XCTAssertEqual(style.margin.right, .points(StyleLimits.offset.lowerBound), "1 / -0 is -∞")
        XCTAssertEqual(style.textIndent, .points(StyleLimits.offset.lowerBound))
        XCTAssertEqual(style.padding.left, .points(StyleLimits.extent.upperBound))
        XCTAssertEqual(style.lineHeight, .multiple(StyleLimits.lineHeightMultiple.upperBound))
        XCTAssertEqual(style.fontSize, StyleLimits.fontSize.upperBound)
        XCTAssertEqual(style.border.left.width, StyleLimits.borderWidth.upperBound)
        XCTAssertEqual(style.letterSpacing, 0)
        XCTAssertEqual(try CSSCascadeSupport.paragraph("width: calc(infinity * 1%)").width, .percent(StyleLimits.percent.upperBound))
    }

    /// A math function that resolves to a number stands wherever a number does (CSS Values 4
    /// §10.9), rounded where an integer is wanted, a half toward +∞, and clamped to the range
    /// the context allows rather than refused as an out-of-range literal is (§10.12).
    func testANumberCalcStandsWhereverANumberOrIntegerIs() throws {
        func value(_ name: String, _ text: String) -> CSSValue? { CSSPropertyParser.parse(name: name, text: text)?.first?.value }
        XCTAssertEqual(value("line-height", "calc(24 / 16)"), .lineHeight(.number(1.5)))
        XCTAssertEqual(value("line-height", "calc(-1)"), .lineHeight(.number(0)), "-1 is clamped, as the literal is refused")
        XCTAssertNil(value("line-height", "-1"))
        XCTAssertEqual(value("line-height", "max(1.2, 3 / 2)"), .lineHeight(.number(1.5)))
        XCTAssertEqual(value("line-height", "calc(1em * 3 / 2)"), .lineHeight(.length(.calc(.product(.value(1, .em), 1.5)))))
        XCTAssertEqual(value("font-weight", "calc(300 + 400)"), .fontWeight(.absolute(700)))
        XCTAssertEqual(value("font-weight", "calc(2000)"), .fontWeight(.absolute(1000)))
        XCTAssertNil(value("font-weight", "2000"))
        XCTAssertNil(value("font-weight", "calc(1px)"))
        XCTAssertEqual(CSSPropertyParser.parse(name: "font", text: "calc(350 * 2) 12px serif")?.first { $0.property == .fontWeight }?.value,
                       .fontWeight(.absolute(700)))
        XCTAssertEqual(value("filter", "invert(calc(1 / 2))"), .flag(true))
        XCTAssertEqual(value("filter", "invert(calc(1 / 4))"), .flag(false))
        XCTAssertEqual(value("order", "calc(2.5)"), .integer(3))
        XCTAssertEqual(value("order", "calc(-2.5)"), .integer(-2), "A half rounds toward +∞")
        XCTAssertEqual(value("order", "calc(1 / 0)"), .integer(1_000_000))
        XCTAssertNil(value("order", "2.5"))
        XCTAssertEqual(value("flex-grow", "calc(1 + 1)"), .number(2))
        XCTAssertEqual(value("flex-grow", "calc(-1)"), .number(0))
        XCTAssertEqual(CSSPropertyParser.parse(name: "flex", text: "calc(2 * 2) 1 auto")?.first { $0.property == .flexGrow }?.value,
                       .number(4))
        XCTAssertEqual(value("grid-template-columns", "repeat(calc(1 + 2), 1fr)"), .integer(3))
        XCTAssertEqual(value("counter-increment", "c calc(1 + 1)"), .counterChanges([ComputedStyle.CounterChange(name: "c", value: 2)]))
        XCTAssertEqual(value("counter-reset", "c calc(5 / 2)"), .counterChanges([ComputedStyle.CounterChange(name: "c", value: 3)]))
        let sheet = CSSStyleSheet.parse("@font-face { font-family: F; src: url(f.ttf); font-weight: calc(100 * 3) calc(350 * 2) }", path: "a.css")
        XCTAssertEqual(sheet.fontFaces.map(\.weights), [300...700])
    }

    /// What a `var()` substitutes is parsed as written once substituted (#717), so a factor or
    /// divisor it supplies is a number sub-expression like any other.
    func testFactorsAndDivisorsSubstitutedByVarAreNumberSubexpressions() throws {
        let styles = try paragraphs(["width: calc(var(--a) * var(--b) * 1px)", "width: calc(var(--sum) * 1px)",
                                     "width: calc(1em * var(--ratio))", "line-height: calc(var(--px) / var(--base))",
                                     "width: calc(12px / var(--sum))", "font-weight: calc(var(--a) * 350)"],
                                    extra: ":root { --a: 2; --b: 3; --sum: (1 + 2); --ratio: calc(18 / 16); --px: 24; --base: 16 }")
        for (index, expected) in [(0, 6.0), (1, 3), (2, 18), (4, 4)] {
            XCTAssertEqual(points(styles[index].width), CGFloat(expected), accuracy: 0.0001, "\(index)")
        }
        XCTAssertEqual(styles[3].lineHeight, .multiple(1.5))
        XCTAssertEqual(styles[5].fontWeight, 700)
    }

    /// CSS Values 4 §10.12: a top-level calculation is clamped to the range the property allows.
    func testATopLevelCalcIsClampedToThePropertysRange() throws {
        let style = try CSSCascadeSupport.paragraph("""
            width: calc(-10px); padding-left: calc(1px - 5px); margin-left: calc(-5px * 3); border-left: calc(-3px) solid;
            border-spacing: calc(-3px); min-height: calc(0px - 1em)
            """)
        XCTAssertEqual(style.width, .points(0))
        XCTAssertEqual(style.padding.left, .points(0))
        XCTAssertEqual(style.margin.left, .points(-15), "Margins may be negative")
        XCTAssertEqual(style.border.left.width, 0)
        XCTAssertEqual(style.borderSpacing, .zero)
        XCTAssertEqual(style.minHeight, .points(0))
    }

    func testMinMaxAndClampChooseAmongLengths() throws {
        let style = try CSSCascadeSupport.paragraph("""
            width: min(100px, 200px); height: max(100px, 200px); margin-left: min(10px, 1em); margin-top: max(1em, 5px);
            min-width: clamp(100px, 50px, 300px); max-width: clamp(100px, 500px, 300px); padding-left: clamp(1px, 5px, 10px);
            padding-right: clamp(30px, 20px, 10px); text-indent: max(-5px, -10px); padding-top: min(1px + 2px, 10px);
            padding-bottom: calc(min(4px, 8px) * 2); margin-right: MAX(1px, 2px, 3px); margin-bottom: min(7px)
            """)
        XCTAssertEqual(style.width, .points(100))
        XCTAssertEqual(style.height, .points(200))
        XCTAssertEqual(style.margin.left, .points(10))
        XCTAssertEqual(style.margin.top, .points(16))
        XCTAssertEqual(style.minWidth, .points(100))
        XCTAssertEqual(style.maxWidth, .points(300))
        XCTAssertEqual(style.padding.left, .points(5))
        XCTAssertEqual(style.padding.right, .points(30), "clamp(MIN, VAL, MAX) is max(MIN, min(VAL, MAX)): the minimum wins")
        XCTAssertEqual(style.textIndent, .points(-5))
        XCTAssertEqual(style.padding.top, .points(3))
        XCTAssertEqual(style.padding.bottom, .points(8))
        XCTAssertEqual(style.margin.right, .points(3))
        XCTAssertEqual(style.margin.bottom, .points(7))
    }

    func testComparisonFunctionsWithMixedTypesOrWrongArityAreInvalid() throws {
        let invalid = ["min()", "min(1, 2)", "clamp(1px, 2px)", "min(10px 5px)", "max(1px, 2)", "clamp(1px, 2px, 3px, 4px)", "max(1px,)"]
        let styles = try paragraphs(invalid.map { "width: 11px; width: \($0)" })
        for (expression, style) in zip(invalid, styles) { XCTAssertEqual(style.width, .points(11), expression) }
    }

    func testOversizedExpressionsAreBoundedWithoutTrapping() throws {
        let deep = "calc(" + String(repeating: "(", count: 40) + "1px" + String(repeating: ")", count: 40) + ")"
        let long = "calc(" + Array(repeating: "1px", count: 400).joined(separator: " + ") + ")"
        let wide = "min(" + Array(repeating: "1px", count: 400).joined(separator: ", ") + ")"
        let styles = try paragraphs(["width: \(deep)", "width: \(long)", "width: \(wide)", "width: 7px"])
        for style in styles.dropLast() {
            // Either evaluated or dropped by a bound; never a trap, a hang or a non-finite length.
            switch style.width {
            case .auto: break
            case .points(let value): XCTAssertTrue(value.isFinite && value >= 0)
            default: XCTFail("\(style.width)")
            }
        }
        XCTAssertEqual(styles[3].width, .points(7), "Rules after an oversized value still apply")
    }

    func testHugeFiniteValuesAreClampedToTheStyleLimits() throws {
        let style = try CSSCascadeSupport.paragraph("""
            width: 1e30px; margin-left: -1e30px; padding-left: 1e30em; text-indent: 1e30px; border: 1e30px solid; font-size: 1e30px;
            line-height: 1e30; border-spacing: 1e30px; letter-spacing: 1e30px; word-spacing: -1e30px; vertical-align: 1e30px
            """)
        XCTAssertEqual(style.width, .points(StyleLimits.extent.upperBound))
        XCTAssertEqual(style.margin.left, .points(StyleLimits.offset.lowerBound))
        XCTAssertEqual(style.padding.left, .points(StyleLimits.extent.upperBound))
        XCTAssertEqual(style.textIndent, .points(StyleLimits.offset.upperBound))
        XCTAssertEqual(style.border.top.width, StyleLimits.borderWidth.upperBound)
        XCTAssertEqual(style.fontSize, StyleLimits.fontSize.upperBound)
        XCTAssertEqual(style.lineHeight, .multiple(StyleLimits.lineHeightMultiple.upperBound))
        XCTAssertEqual(style.borderSpacing.width, StyleLimits.borderSpacing.upperBound)
        XCTAssertTrue(style.letterSpacing.isFinite && style.letterSpacing > 0 && style.letterSpacing <= 10_000)
        XCTAssertTrue(style.wordSpacing.isFinite && style.wordSpacing < 0 && style.wordSpacing >= -10_000)
        XCTAssertEqual(style.verticalAlign, .offset(StyleLimits.offset.upperBound))
    }

    /// CSS Values 4 §5: a value outside what an implementation supports "must be converted to
    /// the closest value supported by the implementation". A number past `Double`'s range is
    /// such a value, and the closest supported one is the largest, as for `1e30px`.
    func testNumbersBeyondDoubleRangeClampLikeOtherHugeValues() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/125")
        let styles = try paragraphs(["width: 1e30px", "width: 1e400px", "font-size: 1e30px", "font-size: 1e400px",
                                     "margin-left: -1e30px", "margin-left: -1e400px"])
        XCTAssertEqual(styles[1].width, styles[0].width, "width: 1e400px")
        XCTAssertEqual(styles[3].fontSize, styles[2].fontSize, "font-size: 1e400px")
        XCTAssertEqual(styles[5].margin.left, styles[4].margin.left, "margin-left: -1e400px")
    }

    /// CSS Values 4 §10.12: infinities are clamped and NaN is censored to zero at the top level.
    func testNonFiniteCalculationsNeverReachAComputedStyle() throws {
        let nan = "calc(1e308px * 1e308 * 0)", indeterminate = "calc(1e308px * 1e308 - 1e308px * 1e308)", infinite = "calc(1e308px * 1e308)"
        for expression in [nan, indeterminate, infinite] {
            let style = try CSSCascadeSupport.paragraph("""
                width: \(expression); margin-left: \(expression); padding-left: \(expression); text-indent: \(expression);
                font-size: \(expression); line-height: \(expression); letter-spacing: \(expression); word-spacing: \(expression);
                vertical-align: \(expression); border: \(expression) solid; border-spacing: \(expression); top: \(expression)
                """)
            for length in [style.width, style.margin.left, style.padding.left, style.textIndent, style.positionTop] {
                guard case .points(let value) = length else { XCTFail("\(length) from \(expression)"); continue }
                XCTAssertTrue(value.isFinite, expression)
            }
            XCTAssertTrue(StyleLimits.fontSize.contains(style.fontSize), "\(style.fontSize) from \(expression)")
            XCTAssertTrue(style.lineHeightPoints?.isFinite == true, "\(style.lineHeight) from \(expression)")
            XCTAssertTrue(style.letterSpacing.isFinite && style.wordSpacing.isFinite, expression)
            XCTAssertTrue(style.border.top.width.isFinite && style.borderSpacing.width.isFinite, expression)
            guard case .offset(let offset) = style.verticalAlign else { XCTFail("\(style.verticalAlign)"); continue }
            XCTAssertTrue(offset.isFinite, expression)
        }
    }

    /// CSS Values 4 §6.1.1: `lh` is "the computed value of the line-height property of the
    /// element on which it is used", and `rlh` "the value of the lh unit on the root element".
    func testLhAndRlhFollowTheComputedLineHeight() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/125")
        let result = try CSSCascadeSupport.styled(#"<p id="p">x</p><p id="q">y</p>"#, css: """
            html { line-height: 2 }
            #p { font-size: 20px; line-height: 3; margin-top: 1lh; margin-bottom: 1rlh }
            #q { font-size: 20px; line-height: 30px; padding-top: 2lh }
            """)
        XCTAssertEqual(result.style("p").lineHeightPoints, 60)
        XCTAssertEqual(result.style("p").margin.top, .points(60), "1lh with line-height: 3 at 20px")
        XCTAssertEqual(result.style("p").margin.bottom, .points(32), "1rlh with the root's line-height: 2 at 16px")
        XCTAssertEqual(result.style("q").padding.top, .points(60), "2lh with line-height: 30px")
    }

    func testRemIsTheRootsComputedFontSizeAndTheInitialSizeOnTheRootsOwnFontSize() throws {
        let section = """
            <html xmlns="http://www.w3.org/1999/xhtml" id="html"><head><title>T</title><style>
            html { font-size: 2rem } body { margin-left: 1rem; font-size: 0.5rem } p { font-size: 1rem; text-indent: 2rem }
            </style></head><body id="body"><p id="p">x</p></body></html>
            """
        let result = try StyleTestSupport.styled(section: section, files: [:], typography: NativeTypography(fontSize: 18))
        XCTAssertEqual(result.style("html").fontSize, 36, "On the root's font-size, rem is the initial size: the reader's")
        XCTAssertEqual(result.style("body").margin.left, .points(36))
        XCTAssertEqual(result.style("body").fontSize, 18)
        XCTAssertEqual(result.style("p").fontSize, 36, "rem ignores the parent's size")
        XCTAssertEqual(result.style("p").textIndent, .points(72))
    }

    /// CSS Values 4 §6.1: rem is "the computed value of the em unit on the root element". Only in
    /// the root's own `font-size` does it stand for the initial size instead.
    func testRemInTheRootsOtherPropertiesIsTheRootsOwnComputedFontSize() throws {
        let section = """
            <html xmlns="http://www.w3.org/1999/xhtml" id="html"><head><title>T</title><style>
            html { font-size: 20px; padding-left: 2rem; text-indent: 1rem; line-height: 1.5rem }
            </style></head><body><p id="p">x</p></body></html>
            """
        let result = try StyleTestSupport.styled(section: section, files: [:], typography: NativeTypography(fontSize: 16))
        let root = result.style("html")
        XCTAssertEqual(root.fontSize, 20)
        XCTAssertEqual(root.padding.left, .points(40), "2rem on the root itself")
        XCTAssertEqual(root.textIndent, .points(20), "1rem on the root itself")
        XCTAssertEqual(root.lineHeight, .points(30), "1.5rem on the root itself, which every element inherits")
    }

    /// The root's own rem holds inside `calc()` and beside viewport units too, and the line height
    /// it gives the root is the one every element inherits.
    func testRemOnTheRootIsItsOwnSizeInCalcAndBesideViewportUnits() throws {
        let section = """
            <html xmlns="http://www.w3.org/1999/xhtml" id="html"><head><title>T</title><style>
            html { font-size: calc(1rem + 4px); margin-left: calc(1rem + 10px); line-height: calc(1rem + 10px);
                   width: calc(10vw + 3rem); min-height: calc(10vh + 2rem) }
            </style></head><body><p id="p">x</p></body></html>
            """
        let result = try StyleTestSupport.styled(section: section, files: [:], typography: NativeTypography(fontSize: 16))
        let root = result.style("html")
        XCTAssertEqual(root.fontSize, 20, "In calc() in the root's font-size, rem is still the reader's size")
        XCTAssertEqual(root.margin.left, .points(30))
        XCTAssertEqual(root.lineHeight, .points(30))
        XCTAssertEqual(root.width, .viewportWidth(20), "3rem is 60 points, a tenth of the nominal 600-point width")
        XCTAssertEqual(root.boxAlignment.minHeight?.points, 40)
        XCTAssertEqual(root.boxAlignment.minHeight?.viewportHeight, 10)
        XCTAssertEqual(result.style("p").lineHeight, .points(30))
    }
}
