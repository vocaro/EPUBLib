import CoreGraphics
import CoreText
import Foundation
@testable import MathMLLayout
import XCTest

final class MathMLLayoutTests: XCTestCase {
    private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    private func node(_ body: String, display: Bool = false) throws -> MathMLNode {
        let attribute = display ? " display=\"block\"" : ""
        return try MathMLNode.parse(xml: Data("<math xmlns=\"http://www.w3.org/1998/Math/MathML\"\(attribute)>\(body)</math>".utf8))
    }

    private func layout(_ body: String, size: CGFloat = 20, display: Bool = false, font: String? = nil) throws -> MathLayout {
        try MathLayout(node(body, display: display), style: MathStyle(fontSize: size, color: black, fontName: font))
    }

    private func height(_ layout: MathLayout) -> CGFloat { layout.ascent + layout.descent }

    /// Draws `layout` into a bitmap with a margin and returns the bounds of its ink, in
    /// points relative to the baseline origin (y up).
    private func ink(_ layout: MathLayout, margin: CGFloat = 20) -> CGRect? {
        let scale: CGFloat = 2
        let width = Int((layout.width + 2 * margin) * scale), height = Int((self.height(layout) + 2 * margin) * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        layout.draw(in: context, baselineOrigin: CGPoint(x: margin, y: margin + layout.descent))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 24 {
                minX = min(minX, column); maxX = max(maxX, column); minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows run top-down.
        let top = CGFloat(height - minY) / scale, bottom = CGFloat(height - maxY - 1) / scale
        return CGRect(x: CGFloat(minX) / scale - margin, y: bottom - margin - layout.descent,
                      width: CGFloat(maxX - minX + 1) / scale, height: top - bottom)
    }

    func testUsesThePlatformMathFont() {
        let font = MathFont.named(nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font.base) as String, "STIXTwoMath-Regular")
        XCTAssertNotNil(font.table)
        XCTAssertEqual(font.constants.scriptPercentScaleDown, 70)
    }

    func testFractionIsTallerThanItsRowAndStraddlesTheAxis() throws {
        let row = try layout("<mi>a</mi><mo>+</mo><mi>b</mi>")
        let fraction = try layout("<mfrac><mi>a</mi><mi>b</mi></mfrac>")
        XCTAssertGreaterThan(fraction.ascent, row.ascent)
        XCTAssertGreaterThan(fraction.descent, row.descent)
        let display = try layout("<mfrac><mi>a</mi><mi>b</mi></mfrac>", display: true)
        XCTAssertGreaterThan(height(display), height(fraction), "display style uses full-size parts and larger shifts")
        // Text-style parts are a script level down.
        XCTAssertLessThan(fraction.width, display.width)
    }

    func testLineThicknessZeroStacksWithoutARule() throws {
        let stack = try layout("<mfrac linethickness=\"0\"><mi>n</mi><mi>k</mi></mfrac>", display: true)
        let fraction = try layout("<mfrac><mi>n</mi><mi>k</mi></mfrac>", display: true)
        XCTAssertGreaterThan(height(stack), 0)
        let thick = try layout("<mfrac linethickness=\"thick\"><mi>n</mi><mi>k</mi></mfrac>", display: true)
        XCTAssertGreaterThanOrEqual(height(thick), height(fraction))
    }

    func testSuperscriptIsRaisedAndShrunk() throws {
        let base = try layout("<mi>x</mi>")
        let power = try layout("<msup><mi>x</mi><mn>2</mn></msup>")
        let two = try layout("<mn>2</mn>")
        XCTAssertGreaterThan(power.ascent, base.ascent + 0.2 * two.ascent)
        let scriptWidth = power.width - base.width - MathFont.named(nil).constants.spaceAfterScript * 20
        XCTAssertEqual(scriptWidth / two.width, 0.7, accuracy: 0.05)
        let subscripted = try layout("<msub><mi>x</mi><mn>2</mn></msub>")
        XCTAssertGreaterThan(subscripted.descent, base.descent + 0.2 * two.ascent)
        XCTAssertLessThan(subscripted.ascent, power.ascent)
    }

    func testSubAndSuperscriptsKeepTheirGap() throws {
        let both = try layout("<msubsup><mi>x</mi><mi>i</mi><mn>2</mn></msubsup>")
        let power = try layout("<msup><mi>x</mi><mn>2</mn></msup>")
        let sub = try layout("<msub><mi>x</mi><mi>i</mi></msub>")
        XCTAssertGreaterThanOrEqual(both.ascent, power.ascent - 0.01)
        XCTAssertGreaterThanOrEqual(both.descent, sub.descent - 0.01)
    }

    func testScriptSizesShrinkToAMinimum() {
        let engine = LayoutEngine(fontName: nil)
        var context = LayoutContext(fontSize: 17, unclampedSize: 17, minSize: min(17, max(8, 17 * 0.6)), display: false,
                                    color: black)
        engine.setScriptLevel(&context, 1)
        XCTAssertEqual(context.fontSize, 17 * 0.7, accuracy: 0.001)
        engine.setScriptLevel(&context, 2)
        XCTAssertEqual(context.fontSize, 17 * 0.6, accuracy: 0.001, "STIX's 55% is clamped to 60%")
        engine.setScriptLevel(&context, 5)
        XCTAssertEqual(context.fontSize, 17 * 0.6, accuracy: 0.001)
        engine.setScriptLevel(&context, 0)
        XCTAssertEqual(context.fontSize, 17, accuracy: 0.001)
    }

    func testRadicalCoversItsRadicand() throws {
        let radicand = try layout("<mfrac><mi>a</mi><mi>b</mi></mfrac>")
        let root = try layout("<msqrt><mfrac><mi>a</mi><mi>b</mi></mfrac></msqrt>")
        XCTAssertGreaterThan(root.ascent, radicand.ascent)
        XCTAssertGreaterThanOrEqual(root.descent, radicand.descent)
        XCTAssertGreaterThan(root.width, radicand.width)
        let indexed = try layout("<mroot><mi>x</mi><mn>3</mn></mroot>")
        let square = try layout("<msqrt><mi>x</mi></msqrt>")
        XCTAssertGreaterThan(indexed.width, square.width - 0.01)
    }

    func testStretchyFencesGrowWithTheirRow() throws {
        let plain = try layout("<mo>(</mo><mi>x</mi><mo>)</mo>")
        let tall = try layout("<mo>(</mo><mfrac><mfrac><mi>a</mi><mi>b</mi></mfrac><mi>c</mi></mfrac><mo>)</mo>", display: true)
        let content = try layout("<mfrac><mfrac><mi>a</mi><mi>b</mi></mfrac><mi>c</mi></mfrac>", display: true)
        XCTAssertGreaterThan(height(tall), height(plain) * 1.5)
        XCTAssertGreaterThanOrEqual(height(tall), height(content) * 0.9)
        let unstretched = try layout("<mo stretchy=\"false\">(</mo><mfrac><mfrac><mi>a</mi><mi>b</mi></mfrac><mi>c</mi></mfrac><mo stretchy=\"false\">)</mo>",
                                     display: true)
        XCTAssertEqual(height(unstretched), height(content), accuracy: 0.01)
    }

    func testVeryTallFencesUseGlyphAssemblies() throws {
        let rows = (1...12).map { "<mtr><mtd><mn>\($0)</mn></mtd></mtr>" }.joined()
        let table = try layout("<mtable>\(rows)</mtable>")
        let fenced = try layout("<mo>{</mo><mtable>\(rows)</mtable><mo>}</mo>")
        XCTAssertGreaterThanOrEqual(height(fenced), height(table) * 0.9)
        let engine = LayoutEngine(fontName: nil)
        let context = LayoutContext(fontSize: 20, unclampedSize: 20, minSize: 12, display: false, color: black)
        let brace = try engine.layout(MathMLNode(name: "mo", text: "{"), context,
                                      Embellishment(form: .prefix, stretch: .vertical(ascent: 200, descent: 190)), depth: 0)
        XCTAssertEqual(brace.height, max(390 * 0.901, 390 - 10), accuracy: 6, "TeX's delimiter factor and shortfall")
        XCTAssertEqual((brace.ascent - brace.descent) / 2, engine.value(\.axisHeight, context), accuracy: 0.5,
                       "symmetric fences centre on the math axis")
    }

    func testHorizontalStretchCoversTheBase() throws {
        let label = try layout("<mstyle scriptlevel=\"1\"><mtext>a long arrow label</mtext></mstyle>")
        let arrow = try layout("<mover><mo>→</mo><mtext>a long arrow label</mtext></mover>")
        XCTAssertGreaterThanOrEqual(arrow.width, label.width - 0.01)
        let brace = try layout("<munder><mrow><mi>a</mi><mo>+</mo><mi>b</mi><mo>+</mo><mi>c</mi></mrow><mo>⏟</mo></munder>")
        let row = try layout("<mi>a</mi><mo>+</mo><mi>b</mi><mo>+</mo><mi>c</mi>")
        XCTAssertGreaterThan(brace.descent, row.descent + 2)
        XCTAssertEqual(brace.width, row.width, accuracy: 1)
    }

    func testLimitsGoUnderAndOverInDisplayStyleOnly() throws {
        let sum = "<munderover><mo>∑</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover>"
        let display = try layout(sum, display: true)
        let inline = try layout(sum)
        let bare = try layout("<mo>∑</mo>", display: true)
        XCTAssertGreaterThan(display.ascent, bare.ascent)
        XCTAssertGreaterThan(display.descent, bare.descent)
        XCTAssertGreaterThan(height(display), height(inline))
        // In text style the limits become scripts beside the operator.
        let operatorWidth = try layout("<mo>∑</mo>").width
        XCTAssertGreaterThan(inline.width, operatorWidth + 5)
        XCTAssertLessThan(display.width, inline.width + operatorWidth)
        // Integrals do not take movable limits, and are larger in display style.
        let integral = try layout("<mo>∫</mo>", display: true), small = try layout("<mo>∫</mo>")
        XCTAssertGreaterThan(height(integral), height(small) * 1.3)
    }

    func testAccentSitsOnItsBase() throws {
        let base = try layout("<mi>x</mi>")
        let hat = try layout("<mover><mi>x</mi><mo>^</mo></mover>")
        XCTAssertGreaterThan(hat.ascent, base.ascent)
        XCTAssertLessThan(hat.ascent, base.ascent * 2.2)
        let wide = try layout("<mover><mrow><mi>x</mi><mi>y</mi><mi>z</mi></mrow><mo>^</mo></mover>")
        let row = try layout("<mi>x</mi><mi>y</mi><mi>z</mi>")
        XCTAssertGreaterThan(wide.ascent, row.ascent)
        XCTAssertGreaterThanOrEqual(wide.width, row.width - 0.01)
    }

    func testOperatorSpacingFollowsTheDictionaryAndForm() throws {
        let a = try layout("<mi>a</mi>").width, b = try layout("<mi>b</mi>").width
        let plus = try layout("<mo>+</mo>").width
        let sum = try layout("<mi>a</mi><mo>+</mo><mi>b</mi>").width
        XCTAssertEqual(sum - (a + b + plus), 2 * 20 * 4 / 18, accuracy: 0.5, "medium space each side of a binary operator")
        let relation = try layout("<mi>a</mi><mo>=</mo><mi>b</mi>").width - a - b - (try layout("<mo>=</mo>").width)
        XCTAssertEqual(relation, 2 * 20 * 5 / 18, accuracy: 0.5)
        // A prefix minus, and a minus after a relation or an opening fence, are unary.
        let minus = try layout("<mo>−</mo>").width, three = try layout("<mn>3</mn>").width
        XCTAssertEqual(try layout("<mo>−</mo><mn>3</mn>").width, minus + three, accuracy: 0.5)
        let equals = try layout("<mi>x</mi><mo>=</mo><mo>−</mo><mn>3</mn>").width
        XCTAssertEqual(equals, try layout("<mi>x</mi><mo>=</mo><mrow><mo>−</mo><mn>3</mn></mrow>").width, accuracy: 0.01)
        XCTAssertEqual(try layout("<mo>-</mo>").width, minus, accuracy: 0.01, "hyphen-minus draws as the minus sign")
    }

    func testMathVariants() {
        XCTAssertEqual(MathVariant.italic.apply(to: "x"), "𝑥")
        XCTAssertEqual(MathVariant.italic.apply(to: "h"), "ℎ")
        XCTAssertEqual(MathVariant.italic.apply(to: "α"), "𝛼")
        XCTAssertEqual(MathVariant.doubleStruck.apply(to: "RZ1"), "ℝℤ𝟙")
        XCTAssertEqual(MathVariant.bold.apply(to: "v2"), "𝐯𝟐")
        XCTAssertEqual(MathVariant.fraktur.apply(to: "gH"), "𝔤ℌ")
        XCTAssertEqual(MathVariant.script.apply(to: "L"), "ℒ")
        XCTAssertEqual(MathVariant.sansSerifBoldItalic.apply(to: "ω"), "𝟂")
        XCTAssertEqual(MathVariant(attribute: "bold-italic"), .boldItalic)
    }

    func testSingleLetterIdentifiersAreItalic() throws {
        let italic = try layout("<mi>x</mi>"), upright = try layout("<mi mathvariant=\"normal\">x</mi>")
        XCTAssertNotEqual(italic.width, upright.width)
        let function = try layout("<mi>sin</mi>"), text = try layout("<mtext>sin</mtext>")
        XCTAssertEqual(function.width, text.width, accuracy: 0.01, "multi-letter identifiers are upright")
    }

    func testTablesAlignOnTheAxisAndGrow() throws {
        let one = try layout("<mtable><mtr><mtd><mn>1</mn></mtd><mtd><mn>2</mn></mtd></mtr></mtable>")
        let two = try layout("<mtable><mtr><mtd><mn>1</mn></mtd><mtd><mn>2</mn></mtd></mtr><mtr><mtd><mn>3</mn></mtd><mtd><mn>4</mn></mtd></mtr></mtable>")
        XCTAssertGreaterThan(height(two), height(one) * 1.8)
        let axis = MathFont.named(nil).constants.axisHeight * 20
        XCTAssertEqual((two.ascent - two.descent) / 2, axis, accuracy: 0.5)
        let labeled = try layout("<mtable><mlabeledtr><mtd><mtext>(1)</mtext></mtd><mtd><mi>x</mi></mtd></mlabeledtr></mtable>")
        XCTAssertGreaterThan(labeled.width, try layout("<mtext>(1)</mtext>").width + (try layout("<mi>x</mi>").width))
    }

    func testRemainingElementsLayOut() throws {
        let bodies = [
            "<menclose notation=\"box circle roundedbox updiagonalstrike downdiagonalstrike longdiv top bottom left right actuarial madruwb horizontalstrike verticalstrike unknown\"><mi>x</mi></menclose>",
            "<mpadded width=\"+1em\" height=\"2ex\" depth=\"50%\" lspace=\"0.2em\" voffset=\"-0.1em\"><mi>x</mi></mpadded>",
            "<mphantom><mi>x</mi></mphantom>", "<mspace width=\"1em\" height=\"1ex\" depth=\"0.5ex\"/>",
            "<mfenced open=\"[\" close=\"]\" separators=\";,\"><mi>a</mi><mi>b</mi><mi>c</mi></mfenced>",
            "<semantics><mi>x</mi><annotation encoding=\"TeX\">x</annotation></semantics>",
            "<maction actiontype=\"toggle\" selection=\"2\"><mi>a</mi><mi>b</mi></maction>",
            "<merror><mtext>error</mtext></merror>", "<ms>text</ms>",
            "<mstyle mathcolor=\"red\" mathbackground=\"#ff08\" mathsize=\"big\" scriptlevel=\"+1\" displaystyle=\"true\"><mi>x</mi></mstyle>",
            "<mmultiscripts><mi>C</mi><mi>k</mi><none/><mprescripts/><mi>n</mi><none/></mmultiscripts>",
            "<mfrac bevelled=\"true\"><mn>1</mn><mn>2</mn></mfrac>",
            "<munder accentunder=\"true\"><mi>x</mi><mo>_</mo></munder>",
            "<mtable frame=\"dashed\" rowlines=\"solid\" columnlines=\"dashed\" columnalign=\"left right\" align=\"baseline 1\"><mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr><mtr><mtd><mi>c</mi></mtd><mtd columnalign=\"center\"><mi>d</mi></mtd></mtr></mtable>",
            "<mi>sin</mi><mo>\u{2061}</mo><mi>x</mi><mo>\u{2062}</mo><mi>y</mi>",
        ]
        for body in bodies {
            let result = try layout(body)
            XCTAssertGreaterThan(result.width, 0, body)
            XCTAssertTrue(result.ascent.isFinite && result.descent.isFinite, body)
        }
        XCTAssertEqual(try layout("<mphantom><mi>x</mi></mphantom>").width, try layout("<mi>x</mi>").width, accuracy: 0.01)
        XCTAssertNil(ink(try layout("<mphantom><mi>x</mi></mphantom>")), "phantoms take space but draw nothing")
    }

    func testUnsupportedAndInvalidMarkupThrow() throws {
        XCTAssertThrowsError(try layout("<mlongdiv><mn>1</mn><mn>2</mn></mlongdiv>")) {
            XCTAssertEqual($0 as? MathLayoutError, .unsupported("mlongdiv"))
        }
        XCTAssertThrowsError(try layout("<mrow><mi>x</mi><mstack/></mrow>")) {
            XCTAssertEqual($0 as? MathLayoutError, .unsupported("mstack"))
        }
        XCTAssertThrowsError(try layout("<mi><mglyph src=\"a.png\" alt=\"a\"/></mi>")) {
            XCTAssertEqual($0 as? MathLayoutError, .unsupported("mglyph"))
        }
        XCTAssertThrowsError(try layout("<mfrac><mi>x</mi></mfrac>")) {
            XCTAssertEqual($0 as? MathLayoutError, .invalidMarkup("mfrac"))
        }
        XCTAssertThrowsError(try MathMLNode.parse(xml: Data("<math><mi>x</math>".utf8)))
        XCTAssertThrowsError(try MathMLNode.parse(xml: Data(#"<!DOCTYPE m [<!ENTITY a "aaaa">]><math><mi>&a;</mi></math>"#.utf8)))
    }

    func testUntrustedInputIsBounded() throws {
        let deep = String(repeating: "<mrow>", count: 100) + "<mi>x</mi>" + String(repeating: "</mrow>", count: 100)
        XCTAssertThrowsError(try layout(deep)) { XCTAssertEqual($0 as? MathLayoutError, .limitExceeded) }
        let deepNode = (0..<10_000).reduce(MathMLNode(name: "mi", text: "x")) { inner, _ in MathMLNode(name: "mrow", children: [inner]) }
        XCTAssertThrowsError(try MathLayout(deepNode, style: MathStyle(fontSize: 17, color: black))) {
            XCTAssertEqual($0 as? MathLayoutError, .limitExceeded)
        }
        let wide = MathMLNode(name: "math", children: Array(repeating: MathMLNode(name: "mi", text: "x"), count: 30_000))
        XCTAssertThrowsError(try MathLayout(wide, style: MathStyle(fontSize: 17, color: black))) {
            XCTAssertEqual($0 as? MathLayoutError, .limitExceeded)
        }
        XCTAssertThrowsError(try layout("<mspace width=\"1e9em\"/><mspace width=\"999em\"/><mspace width=\"999em\"/><mspace width=\"999em\"/>")) {
            XCTAssertEqual($0 as? MathLayoutError, .limitExceeded)
        }
        let long = try layout("<mtext>\(String(repeating: "a", count: 40_000))</mtext>", size: 1)
        XCTAssertLessThanOrEqual(long.width, MathLimits.extent)
        XCTAssertThrowsError(try layout("<mtext>\(String(repeating: "a", count: 60_000))</mtext>", size: 1))
        // Hostile stretch requests stay bounded.
        let rows = String(repeating: "<mtr><mtd><mn>1</mn></mtd></mtr>", count: 400)
        let tall = try layout("<mo>(</mo><mtable>\(rows)</mtable><mo>)</mo>", size: 4)
        XCTAssertLessThan(height(tall), MathLimits.extent)
    }

    func testBoxCoversItsInk() throws {
        let bodies = [
            "<mi>f</mi>", "<msup><mi>f</mi><mn>2</mn></msup>", "<mo>∫</mo>", "<mi>j</mi>",
            "<msubsup><mo>∫</mo><mn>0</mn><mn>1</mn></msubsup>", "<mover><mi>A</mi><mo>~</mo></mover>",
            "<msqrt><mfrac><mi>a</mi><mi>b</mi></mfrac></msqrt>", "<menclose notation=\"circle\"><mi>x</mi></menclose>",
        ]
        for body in bodies {
            for display in [false, true] {
                let result = try layout(body, display: display)
                guard let ink = ink(result) else { XCTFail(body); continue }
                XCTAssertGreaterThanOrEqual(ink.minX, -0.5, body)
                XCTAssertLessThanOrEqual(ink.maxX, result.width + 0.5, body)
                XCTAssertLessThanOrEqual(ink.maxY, result.ascent + 0.5, body)
                XCTAssertGreaterThanOrEqual(ink.minY, -result.descent - 0.5, body)
            }
        }
    }

    func testLayoutIsDeterministicAndThreadSafe() throws {
        let body = "<mi>x</mi><mo>=</mo><mfrac><mrow><mo>−</mo><mi>b</mi><mo>±</mo><msqrt><msup><mi>b</mi><mn>2</mn></msup><mo>−</mo><mn>4</mn><mi>a</mi><mi>c</mi></msqrt></mrow><mrow><mn>2</mn><mi>a</mi></mrow></mfrac>"
        let parsed = try node(body, display: true)
        let reference = try MathLayout(parsed, style: MathStyle(fontSize: 19, color: black, isDisplay: true))
        let results = UnsafeMutableBufferPointer<CGFloat>.allocate(capacity: 64 * 3)
        defer { results.deallocate() }
        let sendable = SendableBuffer(buffer: results)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let layout = try? MathLayout(parsed, style: MathStyle(fontSize: 19, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                                                                  isDisplay: true))
            sendable.buffer[index * 3] = layout?.width ?? -1
            sendable.buffer[index * 3 + 1] = layout?.ascent ?? -1
            sendable.buffer[index * 3 + 2] = layout?.descent ?? -1
        }
        for index in 0..<64 {
            XCTAssertEqual(results[index * 3], reference.width)
            XCTAssertEqual(results[index * 3 + 1], reference.ascent)
            XCTAssertEqual(results[index * 3 + 2], reference.descent)
        }
        let again = try MathLayout(parsed, style: MathStyle(fontSize: 19, color: black, isDisplay: true))
        XCTAssertEqual(ink(again), ink(reference))
    }

    func testFallsBackWithoutAMathFont() throws {
        let missing = try layout("<mfrac><mi>a</mi><mi>b</mi></mfrac>", font: "NoSuchFont-Regular")
        let standard = try layout("<mfrac><mi>a</mi><mi>b</mi></mfrac>")
        XCTAssertEqual(missing.width, standard.width, "an unknown font name uses the platform's math font")
        // A text font has no MATH table: fallback constants and drawn fences.
        let plain = try layout("<mo>(</mo><mfrac><mfrac><mi>a</mi><mi>b</mi></mfrac><mi>c</mi></mfrac><mo>)</mo><msqrt><mi>x</mi></msqrt>",
                               display: true, font: "Helvetica")
        let content = try layout("<mfrac><mfrac><mi>a</mi><mi>b</mi></mfrac><mi>c</mi></mfrac>", display: true, font: "Helvetica")
        XCTAssertGreaterThanOrEqual(height(plain), height(content) * 0.9)
        XCTAssertNotNil(ink(plain))
    }

    func testParsesNamespacesTokensAndReferences() throws {
        let parsed = try MathMLNode.parse(xml: Data("""
        <m:math xmlns:m="http://www.w3.org/1998/Math/MathML" alttext="x"><m:mrow><m:mi> x </m:mi><m:mo>&#x2212;</m:mo><m:mtext>a<m:malignmark/>b</m:mtext></m:mrow></m:math>
        """.utf8))
        XCTAssertEqual(parsed.name, "math")
        XCTAssertEqual(parsed.attributes["alttext"], "x")
        let row = parsed.children[0]
        XCTAssertEqual(row.children.map(\.name), ["mi", "mo", "mtext"])
        XCTAssertEqual(row.children[1].text, "\u{2212}")
        XCTAssertEqual(row.children[2].text, "ab")
        XCTAssertEqual(row.children[2].children.map(\.name), ["malignmark"])
    }

    func testAccessibilityDescription() throws {
        XCTAssertEqual(try node("<msup><mi>x</mi><mn>2</mn></msup><mo>+</mo><mn>1</mn>").accessibilityDescription,
                       "x squared plus 1")
        XCTAssertEqual(try node("<mfrac><mi>a</mi><mi>b</mi></mfrac>").accessibilityDescription, "a over b")
        XCTAssertEqual(try node("<mfrac><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow><mi>c</mi></mfrac>").accessibilityDescription,
                       "start fraction a plus b over c end fraction")
        XCTAssertEqual(try node("<msqrt><mi>x</mi></msqrt>").accessibilityDescription, "the square root of x")
        XCTAssertEqual(try node("<msub><mi>x</mi><mn>1</mn></msub><mo>=</mo><mo>−</mo><mn>3</mn>").accessibilityDescription,
                       "x sub 1 equals minus 3")
    }
}

private struct SendableBuffer: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<CGFloat>
}
