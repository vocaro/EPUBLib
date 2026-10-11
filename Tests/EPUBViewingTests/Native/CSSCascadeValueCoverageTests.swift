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
}
