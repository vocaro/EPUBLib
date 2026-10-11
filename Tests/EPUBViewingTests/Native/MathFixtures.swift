import Foundation

/// Representative MathML for the native reader's formula tests: wide formulas, inline and
/// display; `mglyph`; elementary math; and formulas in books that are not in English. The
/// formulas are the kinds textbooks set (expansions, series, derivations, physical laws,
/// matrices, cases), written as converters write them: some flat, some nested by precedence,
/// some wrapped in `mstyle` and `semantics`.
enum MathFixtures {
    struct Formula {
        let name: String
        /// The content of the `math` element.
        let body: String
        var isDisplay = true
        /// Whether rows keep it at a readable size in a narrow column at every font size: false
        /// for a formula whose width is one fraction, table or bracketed power, which has no
        /// break in it.
        var breaks = true

        var attributes: String { isDisplay ? "display=\"block\"" : "" }
        var markup: String { MathFixtures.math(body, attributes: attributes) }
    }

    static func math(_ body: String, attributes: String = "") -> String {
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" \(attributes)>\(body)</math>"
    }

    // MARK: Markup

    static func i(_ text: String) -> String { "<mi>\(text)</mi>" }
    static func n(_ text: String) -> String { "<mn>\(text)</mn>" }
    static func o(_ text: String) -> String { "<mo>\(text)</mo>" }
    static func t(_ text: String) -> String { "<mtext>\(text)</mtext>" }
    static func row(_ items: String...) -> String { "<mrow>\(items.joined())</mrow>" }
    static func sup(_ base: String, _ script: String) -> String { "<msup>\(base)\(script)</msup>" }
    static func sub(_ base: String, _ script: String) -> String { "<msub>\(base)\(script)</msub>" }
    static func frac(_ numerator: String, _ denominator: String) -> String { "<mfrac>\(numerator)\(denominator)</mfrac>" }
    static func sqrt(_ items: String...) -> String { "<msqrt>\(items.joined())</msqrt>" }
    static func paren(_ items: String...) -> String { "<mrow><mo>(</mo>\(items.joined())<mo>)</mo></mrow>" }
    static func table(_ rows: [[String]], attributes: String = "") -> String {
        "<mtable \(attributes)>" + rows.map { "<mtr>" + $0.map { "<mtd>\($0)</mtd>" }.joined() + "</mtr>" }.joined() + "</mtable>"
    }
    private static let times = "<mo>\u{2062}</mo>", apply = "<mo>\u{2061}</mo>"
    private static func joined(_ terms: [String], _ sign: String = "+") -> String { terms.joined(separator: o(sign)) }

    // MARK: Wide formulas

    /// A flat polynomial of fourteen terms: every `mo` a child of `math`.
    static let polynomial = Formula(name: "polynomial", body:
        i("p") + paren(i("x")) + o("=") + joined((0..<14).map { n("\(14 - $0)") + times + sup(i("x"), n("\(13 - $0)")) }))

    /// A binomial expansion nested by precedence: `lhs = <mrow>sum</mrow>`.
    static let binomialExpansion = Formula(name: "binomialExpansion", body: row(
        sup(paren(i("a"), o("+"), i("b")), n("7")), o("="),
        row(joined([sup(i("a"), n("7")), n("7") + sup(i("a"), n("6")) + i("b"), n("21") + sup(i("a"), n("5")) + sup(i("b"), n("2")),
                    n("35") + sup(i("a"), n("4")) + sup(i("b"), n("3")), n("35") + sup(i("a"), n("3")) + sup(i("b"), n("4")),
                    n("21") + sup(i("a"), n("2")) + sup(i("b"), n("5")), n("7") + i("a") + sup(i("b"), n("6")), sup(i("b"), n("7"))]))))

    /// A series whose terms are fractions.
    static let taylorSeries = Formula(name: "taylorSeries", body:
        sup(i("e"), i("x")) + o("=") + joined([n("1"), i("x")] + (2...9).map { frac(sup(i("x"), n("\($0)")), row(n("\($0)"), o("!"))) } + [o("⋯")]))

    /// A derivation with several relations and flat brackets.
    static let derivation = Formula(name: "derivation", body:
        sup(paren(i("x"), o("+"), n("1")), n("3")) + o("=") + paren(i("x"), o("+"), n("1")) + paren(i("x"), o("+"), n("1")) + paren(i("x"), o("+"), n("1"))
        + o("=") + paren(sup(i("x"), n("2")), o("+"), n("2"), i("x"), o("+"), n("1")) + paren(i("x"), o("+"), n("1"))
        + o("=") + sup(i("x"), n("3")) + o("+") + n("3") + sup(i("x"), n("2")) + o("+") + n("3") + i("x") + o("+") + n("1"))

    static let quadratic = Formula(name: "quadratic", body:
        i("x") + o("=") + frac(row(o("−"), i("b"), o("±"), sqrt(sup(i("b"), n("2")), o("−"), n("4"), i("a"), i("c"))), row(n("2"), i("a"))))

    static let normalDensity = Formula(name: "normalDensity", body:
        i("f") + paren(i("x")) + o("=") + frac(n("1"), row(i("σ"), sqrt(n("2"), i("π"))))
        + sup(i("e"), row(o("−"), frac(sup(paren(i("x"), o("−"), i("μ")), n("2")), row(n("2"), sup(i("σ"), n("2")))))))

    /// One fraction as wide as a line: nothing in it may break.
    static let wideFraction = Formula(name: "wideFraction", body:
        i("r") + o("=") + frac(row(joined((1...9).map { sub(i("x"), n("\($0)")) + times + sub(i("y"), n("\($0)")) })),
                               row(sqrt(joined((1...5).map { sup(sub(i("x"), n("\($0)")), n("2")) })),
                                   sqrt(joined((1...5).map { sup(sub(i("y"), n("\($0)")), n("2")) })))),
        breaks: false)

    /// Matrices break only at the relation between them.
    static let matrixProduct = Formula(name: "matrixProduct", body:
        paren(table((1...4).map { r in (1...4).map { c in sub(i("a"), n("\(r)\(c)")) } }))
        + paren(table((1...4).map { [sub(i("x"), n("\($0)"))] }))
        + o("=") + paren(table((1...4).map { r in [joined((1...4).map { c in sub(i("a"), n("\(r)\(c)")) + sub(i("x"), n("\(c)")) })] })))

    /// Cases with their conditions in words: one table.
    static let piecewise = Formula(name: "piecewise", body:
        i("f") + paren(i("n")) + o("=") + "<mrow><mo>{</mo>" + table([
            [row(frac(i("n"), n("2"))), t("if n is an even whole number")],
            [row(n("3"), i("n"), o("+"), n("1")), t("if n is an odd whole number greater than one")],
            [n("1"), t("otherwise")],
        ], attributes: "columnalign=\"left left\"") + "</mrow>",
        breaks: false)

    /// A system of equations as an alignment table.
    static let alignedSystem = Formula(name: "alignedSystem", body: table([
        [row(n("2"), i("x"), o("+"), n("3"), i("y"), o("−"), i("z"), o("+"), n("4"), i("w")), o("="), n("12")],
        [row(i("x"), o("−"), n("5"), i("y"), o("+"), n("2"), i("z"), o("−"), i("w")), o("="), row(o("−"), n("7"))],
        [row(n("4"), i("x"), o("+"), i("y"), o("+"), n("6"), i("z"), o("+"), n("3"), i("w")), o("="), n("30")],
    ], attributes: "columnalign=\"right center left\""))

    static let schrodinger = Formula(name: "schrodinger", body: row(
        i("i"), i("ℏ"), frac(o("∂"), row(o("∂"), i("t"))), i("Ψ"), paren(i("𝐫"), o(","), i("t")), o("="),
        row(o("["), row(o("−"), frac(sup(i("ℏ"), n("2")), row(n("2"), i("m"))), sup(o("∇"), n("2")), o("+"), i("V"), paren(i("𝐫"), o(","), i("t"))), o("]")),
        i("Ψ"), paren(i("𝐫"), o(","), i("t"))))

    static let navierStokes = Formula(name: "navierStokes", body:
        i("ρ") + paren(frac(row(o("∂"), i("𝐮")), row(o("∂"), i("t"))), o("+"), i("𝐮"), o("⋅"), o("∇"), i("𝐮"))
        + o("=") + o("−") + o("∇") + i("p") + o("+") + i("μ") + sup(o("∇"), n("2")) + i("𝐮")
        + o("+") + frac(n("1"), n("3")) + i("μ") + o("∇") + paren(o("∇"), o("⋅"), i("𝐮")) + o("+") + i("ρ") + i("𝐠"))

    /// A sum wholly inside brackets: its breaks are all inside them.
    static let bracketedSum = Formula(name: "bracketedSum", body:
        i("S") + o("=") + frac(n("1"), i("n")) + paren(joined((1...12).map { sub(i("a"), n("\($0)")) + sub(i("b"), n("\($0)")) })))

    /// Words as operands, as in a business or science primer: the bracketed power is one unit.
    static let wordEquation = Formula(name: "wordEquation", body:
        t("future value") + o("=") + t("principal") + o("×") + sup(paren(n("1"), o("+"), frac(t("annual rate"), t("periods per year"))),
                                                                  row(t("periods per year"), o("×"), t("years"))),
        breaks: false)

    /// As a converter wraps it: `mstyle`, `semantics`, a TeX annotation.
    static let wrappedSeries = Formula(name: "wrappedSeries", body:
        "<mstyle displaystyle=\"true\"><semantics>" + row(
            "<munderover><mo>∑</mo>" + row(i("k"), o("="), n("1")) + i("n") + "</munderover>", sup(i("k"), n("2")), o("="),
            joined((1...8).map { sup(n("\($0)"), n("2")) } + [o("⋯"), sup(i("n"), n("2"))]), o("="),
            frac(row(i("n"), paren(i("n"), o("+"), n("1")), paren(n("2"), i("n"), o("+"), n("1"))), n("6")))
        + "<annotation encoding=\"application/x-tex\">\\sum_{k=1}^n k^2</annotation></semantics></mstyle>")

    static let variance = Formula(name: "variance", body:
        t("Var") + paren(i("X")) + o("=") + i("E") + "<mrow><mo>[</mo>" + sup(paren(i("X"), o("−"), i("μ")), n("2")) + "<mo>]</mo></mrow>"
        + o("=") + i("E") + "<mrow><mo>[</mo>" + sup(i("X"), n("2")) + "<mo>]</mo></mrow>" + o("−") + n("2") + i("μ") + i("E") + "<mrow><mo>[</mo>" + i("X") + "<mo>]</mo></mrow>"
        + o("+") + sup(i("μ"), n("2")) + o("=") + i("E") + "<mrow><mo>[</mo>" + sup(i("X"), n("2")) + "<mo>]</mo></mrow>" + o("−") + sup(i("μ"), n("2")))

    /// A long list in braces: only separators to break at, all inside the braces.
    static let longSet = Formula(name: "longSet", body:
        i("P") + o("=") + "<mrow><mo>{</mo>" + ["2", "3", "5", "7", "11", "13", "17", "19", "23", "29", "31", "37", "41", "43", "47", "53", "59", "61", "67", "71"]
            .map(n).joined(separator: o(",")) + o(",") + o("…") + "<mo>}</mo></mrow>")

    /// The author's own breaks: one on an operator, one on a space.
    static let authoredBreaks = Formula(name: "authoredBreaks", body:
        i("a") + o("=") + i("b") + o("+") + i("c") + "<mo linebreak=\"newline\">=</mo>" + i("d") + o("+") + i("e")
        + "<mspace linebreak=\"newline\"/>" + o("=") + i("f"))

    static let inlineSeries = Formula(name: "inlineSeries", body:
        sub(i("s"), i("n")) + o("=") + joined((1...16).map { sub(i("a"), n("\($0)")) }), isDisplay: false)

    static let inlineDerivation = Formula(name: "inlineDerivation", body: derivation.body, isDisplay: false)

    static let inlineShort = Formula(name: "inlineShort", body: i("y") + o("=") + i("m") + i("x") + o("+") + i("b"), isDisplay: false)

    static let inlineWideFraction = Formula(name: "inlineWideFraction", body: wideFraction.body, isDisplay: false, breaks: false)

    /// Display and inline, breakable and not.
    static let wide: [Formula] = [
        polynomial, binomialExpansion, taylorSeries, derivation, quadratic, normalDensity, wideFraction, matrixProduct,
        piecewise, alignedSystem, schrodinger, navierStokes, bracketedSum, wordEquation, wrappedSeries, variance, longSet,
        authoredBreaks, inlineSeries, inlineDerivation, inlineShort, inlineWideFraction,
    ]

    // MARK: mglyph

    /// A glyph image named by its `alt`, inside a token, as MathML 3 has it.
    static let glyphInToken = "<mi><mglyph src=\"braid.png\" alt=\"braid 23\" width=\"1em\" height=\"1em\"/></mi><mo>=</mo><mi>x</mi>"
    /// A glyph between a token's own characters.
    static let glyphInText = "<mtext>the <mglyph src=\"rune.png\" alt=\"rune ansuz\"/> sign</mtext>"
    /// A glyph without an `alt`, and one outside any token (MathML 2).
    static let glyphWithoutAlt = "<mi>a</mi><mo><mglyph src=\"op.png\"/></mo><mi>b</mi>"
    static let glyphAlone = "<mrow><mi>k</mi><mglyph src=\"star.png\" alt=\"star\"/></mrow>"

    // MARK: Elementary math

    /// Column addition with a carry row.
    static let addition = """
    <mstack><mscarries><mn>1</mn><mn>1</mn><none/></mscarries><mn>496</mn><msrow><mo>+</mo><mn>28</mn></msrow><msline/><mn>524</mn></mstack>
    """
    /// Subtraction with borrows that cross out the digits beneath them.
    static let subtraction = """
    <mstack><mscarries crossout="updiagonalstrike"><mn>2</mn><mn>12</mn><mscarry crossout="none"><none/></mscarry></mscarries>\
    <mn>2,327</mn><msrow><mo>−</mo><mn>1,156</mn></msrow><msline/><mn>1,171</mn></mstack>
    """
    /// Long multiplication: partial products shifted a place each.
    static let multiplication = """
    <mstack><mn>123</mn><msrow><mo>×</mo><mn>321</mn></msrow><msline/>\
    <msgroup shift="1"><mn>123</mn><mn>246</mn><mn>369</mn></msgroup><msline/><mn>39483</mn></mstack>
    """
    /// Decimals align on the point.
    static let decimals = "<mstack><mn>12.5</mn><msrow><mo>+</mo><mn>3.25</mn></msrow><msline/><mn>15.75</mn></mstack>"
    /// Long division in the default (`lefttop`) style, from the MathML 3 specification's example.
    static let longDivision = """
    <mlongdiv><mn>3</mn><mn>435.3</mn><mn>1306</mn><msgroup position="2" shift="-1">\
    <msgroup><mn>12</mn><msline length="2"/></msgroup><msgroup><mn>10</mn><mn>9</mn><msline length="2"/></msgroup>\
    <msgroup><mn>16</mn><mn>15</mn><msline length="2"/><mn>1.0</mn></msgroup>\
    <msgroup position="-1"><mn>9</mn><msline length="3"/><mn>1</mn></msgroup></msgroup></mlongdiv>
    """
    /// The German notation: dividend, colon, divisor, equals, result.
    static let germanDivision = """
    <mlongdiv longdivstyle=":right=right"><mn>12</mn><mn>32</mn><mn>384</mn>\
    <msgroup position="1"><mn>36</mn><msline length="2"/></msgroup>\
    <msgroup><mn>24</mn><mn>24</mn><msline length="2"/><mn>0</mn></msgroup></mlongdiv>
    """
    /// A stacked style the reader draws as `lefttop`.
    static let frenchDivision = "<mlongdiv longdivstyle=\"stackedrightright\"><mn>12</mn><mn>32</mn><mn>384</mn></mlongdiv>"

    static let elementary: [(name: String, body: String)] = [
        ("addition", addition), ("subtraction", subtraction), ("multiplication", multiplication), ("decimals", decimals),
        ("longDivision", longDivision), ("germanDivision", germanDivision), ("frenchDivision", frenchDivision),
    ]

    // MARK: Languages

    /// One formula in French and German content, with the author's reading and without.
    static let fraction = "<mfrac><mi>a</mi><msup><mi>b</mi><mn>2</mn></msup></mfrac>"
    static let frenchAlttext = "a sur b au carré"
    static let germanAlttext = "a durch b Quadrat"
    /// What MathMLLayout 0.1.0 generates for it, whatever the book's language.
    static let englishReading = "start fraction a over b squared end fraction"
}
