import EPUBReading
import EPUBTestSupport
@testable import EPUBViewing
import MathMLLayout
import XCTest
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class MathContentTests: XCTestCase {
    private struct Section {
        let formulas: [ContentNode]
        let context: RichContentContext
    }

    private func section(_ body: String, dark: Bool = false) throws -> Section {
        let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\(body)</body></html>"
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xhtml]))
        let document = try ContentDocument.parse(Data(xhtml.utf8), path: "OPS/one.xhtml")
        let context = RichContentContext(
            publication: publication, document: document, spineIndex: 0,
            typography: NativeTypography(fontSize: 17, isDark: dark), fonts: FontRegistry(publication: publication),
            style: { _, parent in parent }, renderContent: { element, _ in NSAttributedString(string: element.textContent) },
            resolve: { _ in nil }, report: SectionReportBox())
        let formulas = document.nodes.filter { $0.namespace == ContentNamespace.mathML && $0.name == "math" }
        return Section(formulas: formulas, context: context)
    }

    private func math(_ body: String, attributes: String = "") -> String {
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" \(attributes)>\(body)</math>"
    }

    private func make(_ body: String, attributes: String = "", style: ComputedStyle = ComputedStyle(fontSize: 17),
                      dark: Bool = false) throws -> (NSAttributedString?, SectionReport) {
        let section = try section("<p>\(math(body, attributes: attributes))</p>", dark: dark)
        let result = MathContent.make(try XCTUnwrap(section.formulas.first), style: style, context: section.context)
        return (result, section.context.report.report)
    }

    private func attachment(_ string: NSAttributedString?) throws -> MathAttachment {
        let string = try XCTUnwrap(string)
        XCTAssertEqual(string.length, 1)
        return try XCTUnwrap(string.attribute(.attachment, at: 0, effectiveRange: nil) as? MathAttachment)
    }

    /// The formula drawn into a bitmap: the colours of its inked pixels.
    private func inkColors(_ layout: MathLayout) -> [(red: CGFloat, green: CGFloat, blue: CGFloat)] {
        let width = Int(layout.width * 2) + 2, height = Int((layout.ascent + layout.descent) * 2) + 2
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        layout.draw(in: context, baselineOrigin: CGPoint(x: 0, y: layout.descent))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).compactMap { index in
            let alpha = CGFloat(pixels[index * 4 + 3])
            guard alpha > 250 else { return nil }
            return (CGFloat(pixels[index * 4]) / alpha, CGFloat(pixels[index * 4 + 1]) / alpha, CGFloat(pixels[index * 4 + 2]) / alpha)
        }
    }

    func testFormulaIsOneAttachmentOnTheBaseline() throws {
        let (result, report) = try make("<mfrac><mi>a</mi><mi>b</mi></mfrac>", attributes: "alttext=\"a/b\"")
        let attachment = try attachment(result)
        let layout = attachment.layout
        XCTAssertEqual(report.mathFallbacks, 0)
        XCTAssertGreaterThan(layout.descent, 0, "a fraction hangs below the baseline")
        let content = NSTextContentStorage()
        content.attributedString = result
        let bounds = attachment.attachmentBounds(for: [:], location: content.documentRange.location, textContainer: nil,
                                                 proposedLineFragment: CGRect(x: 0, y: 0, width: 500, height: 20), position: .zero)
        let clearance = attachment.clearance
        XCTAssertGreaterThan(clearance.top, 0, "a display fraction rises past the text")
        XCTAssertGreaterThan(clearance.bottom, 0)
        XCTAssertEqual(bounds, CGRect(x: 0, y: -layout.descent - clearance.bottom, width: layout.width,
                                      height: layout.ascent + layout.descent + clearance.top + clearance.bottom))
        XCTAssertNotNil(result?.attribute(.font, at: 0, effectiveRange: nil), "the line keeps the text's font metrics")
    }

    func testWideFormulaScalesToTheLine() throws {
        let terms = (1...30).map { "<msup><mi>x</mi><mn>\($0)</mn></msup><mo>+</mo>" }.joined() + "<mn>1</mn>"
        let attachment = try attachment(try make(terms).0)
        let layout = attachment.layout
        XCTAssertGreaterThan(layout.width, 300)
        let bounds = attachment.bounds(lineWidth: 300, height: 0)
        XCTAssertEqual(bounds.width, 300, accuracy: 0.001)
        let scale = 300 / layout.width
        let clearance = attachment.clearance
        XCTAssertEqual(bounds.height, (layout.ascent + layout.descent + clearance.top + clearance.bottom) * scale, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, -(layout.descent + clearance.bottom) * scale, accuracy: 0.001)
        // Before layout knows the line, the reader container's viewport bounds it.
        let container = ReaderTextContainer(size: CGSize(width: 250, height: 400))
        container.viewportSize = CGSize(width: 250, height: 400)
        let content = NSTextContentStorage()
        content.attributedString = NSAttributedString(attachment: attachment)
        let fitted = attachment.attachmentBounds(for: [:], location: content.documentRange.location, textContainer: container,
                                                 proposedLineFragment: .zero, position: .zero)
        XCTAssertEqual(fitted.width, 250, accuracy: 0.001)
    }

    func testTallFormulaScalesToThePage() throws {
        let rows = (1...40).map { "<mtr><mtd><mn>\($0)</mn></mtd></mtr>" }.joined()
        let attachment = try attachment(try make("<mo>(</mo><mtable>\(rows)</mtable><mo>)</mo>").0)
        XCTAssertGreaterThan(attachment.bounds(lineWidth: 0, height: 0).height, 500)
        let container = ReaderTextContainer(size: CGSize(width: 300, height: 0))
        container.viewportSize = CGSize(width: 300, height: 400)
        let content = NSTextContentStorage()
        content.attributedString = NSAttributedString(attachment: attachment)
        let fitted = attachment.attachmentBounds(for: [:], location: content.documentRange.location, textContainer: container,
                                                 proposedLineFragment: CGRect(x: 0, y: 0, width: 300, height: 20), position: .zero)
        XCTAssertEqual(fitted.height, 400, accuracy: 0.001, "a page-high formula fits its page")
        let natural = attachment.bounds(lineWidth: 0, height: 0)
        XCTAssertEqual(fitted.width / natural.width, fitted.height / natural.height, accuracy: 0.0001, "scaled uniformly")
    }

    /// Table cells draw their text with string drawing, which may use TextKit 1.
    func testStringDrawingPutsTheFormulaOnTheBaseline() throws {
        let (formula, _) = try make("<mfrac><mi>a</mi><mi>b</mi></mfrac>", attributes: "display=\"block\"")
        let attachment = try attachment(formula)
        let font = PlatformFont.systemFont(ofSize: 17)
        let text = NSMutableAttributedString(string: "x", attributes: [.font: font, .foregroundColor: PlatformColor.black])
        text.append(try XCTUnwrap(formula))
        let width = 200, height = 120, scale = 2
        let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
                                bytesPerRow: width * scale * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Flipped, as string drawing expects: y grows downward from the top-left.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        #if os(iOS)
        UIGraphicsPushContext(context)
        text.draw(with: CGRect(x: 10, y: 20, width: 180, height: 90), options: [.usesLineFragmentOrigin], context: nil)
        UIGraphicsPopContext()
        #elseif os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(with: CGRect(x: 10, y: 20, width: 180, height: 90), options: [.usesLineFragmentOrigin], context: nil)
        NSGraphicsContext.restoreGraphicsState()
        #endif
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * scale * scale * 4)
        func inkRows(columns: Range<Int>) -> (top: CGFloat, bottom: CGFloat)? {
            var rows: [Int] = []
            for row in 0..<(height * scale) where columns.contains(where: { pixels[(row * width * scale + $0) * 4 + 3] > 64 }) {
                rows.append(row)
            }
            // Bitmap rows run top-down; in points from the top.
            return rows.first.map { (CGFloat($0) / CGFloat(scale), CGFloat(rows.last! + 1) / CGFloat(scale)) }
        }
        let x = try XCTUnwrap(inkRows(columns: (10 * scale)..<(17 * scale)))
        let fraction = try XCTUnwrap(inkRows(columns: (22 * scale)..<(10 + Int(attachment.layout.width) + 8) * scale))
        // The fraction straddles the x's baseline (its bottom) by its own ascent and descent.
        XCTAssertEqual(fraction.bottom - x.bottom, attachment.layout.descent, accuracy: 1.5)
        XCTAssertEqual(x.bottom - fraction.top, attachment.layout.ascent, accuracy: 1.5)
    }

    func testSmallFormulasLeaveTheLineSpacingAlone() throws {
        var style = ComputedStyle(fontSize: 17)
        style.lineHeight = .multiple(1.4)
        for body in ["<mi>x</mi>", "<msup><mi>x</mi><mn>2</mn></msup>", "<msub><mi>x</mi><mn>1</mn></msub>",
                     "<mi>y</mi><mo>=</mo><mn>2</mn><mi>x</mi><mo>+</mo><mn>1</mn>"] {
            let attachment = try attachment(try make(body, style: style).0)
            XCTAssertEqual(attachment.clearance.top, 0, body)
            XCTAssertEqual(attachment.clearance.bottom, 0, body)
        }
    }

    func testUsesTheElementsFontSizeAndDisplayStyle() throws {
        let small = try attachment(try make("<mfrac><mi>a</mi><mi>b</mi></mfrac>").0).layout
        let large = try attachment(try make("<mfrac><mi>a</mi><mi>b</mi></mfrac>", style: ComputedStyle(fontSize: 34)).0).layout
        XCTAssertEqual(large.width / small.width, 2, accuracy: 0.05)
        let block = try attachment(try make("<mfrac><mi>a</mi><mi>b</mi></mfrac>", attributes: "display=\"block\"").0).layout
        XCTAssertGreaterThan(block.ascent + block.descent, small.ascent + small.descent)
    }

    func testColorsFollowTheAppearance() throws {
        let body = "<mi mathcolor=\"#ff0000\">x</mi><mi>y</mi>"
        let light = inkColors(try attachment(try make(body).0).layout)
        XCTAssertTrue(light.contains { $0.red > 0.9 && $0.green < 0.1 }, "mathcolor applies in light appearance")
        XCTAssertTrue(light.contains { $0.red < 0.1 && $0.green < 0.1 && $0.blue < 0.1 }, "the reader's text color elsewhere")
        let dark = inkColors(try attachment(try make(body, dark: true).0).layout)
        XCTAssertFalse(dark.isEmpty)
        XCTAssertTrue(dark.allSatisfy { $0.red > 0.8 && abs($0.red - $0.green) < 0.05 }, "dark appearance ignores book colors")
        var styled = ComputedStyle(fontSize: 17)
        styled.color = .init(red: 0, green: 0, blue: 1)
        let blue = inkColors(try attachment(try make("<mi>y</mi>", style: styled).0).layout)
        XCTAssertTrue(blue.allSatisfy { $0.blue > 0.9 && $0.red < 0.1 }, "the CSS color of the math element")
    }

    func testUnsupportedMarkupFallsBackToAlttext() throws {
        let (result, report) = try make("<mlongdiv><mn>3</mn><mn>12</mn></mlongdiv>", attributes: "alttext=\"12 ÷ 3\"")
        XCTAssertEqual(result?.string, "12 ÷ 3")
        XCTAssertNil(result?.attribute(.attachment, at: 0, effectiveRange: nil))
        let font = try XCTUnwrap(result?.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        #if os(iOS)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #elseif os(macOS)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic))
        #endif
        XCTAssertEqual(report.mathFallbacks, 1)
        let (text, textReport) = try make("<mstack><mn>12</mn></mstack>")
        XCTAssertEqual(text?.string, "12", "without alttext the text content stands in")
        XCTAssertEqual(textReport.mathFallbacks, 1)
        let (empty, _) = try make("<mstack/>")
        XCTAssertNil(empty)
        // Markup from another namespace inside math is not MathML the engine knows.
        let section = try section("<p>\(math("<mi>x</mi><span>y</span>", attributes: "alttext=\"x y\""))</p>")
        XCTAssertEqual(MathContent.make(section.formulas[0], style: ComputedStyle(fontSize: 17), context: section.context)?.string, "x y")
    }

    func testConvertsTheContentTree() throws {
        let section = try section("<p>\(math("<mrow><mi mathvariant=\"bold\">x</mi><mo>+</mo><mtext>a<malignmark/>b</mtext></mrow><annotation encoding=\"TeX\">x+ab</annotation>"))</p>")
        let node = try MathContent.convert(section.formulas[0], keepsColors: true, depth: 0)
        XCTAssertEqual(node.name, "math")
        XCTAssertEqual(node.children.map(\.name), ["mrow", "annotation"])
        XCTAssertTrue(node.children[1].children.isEmpty && node.children[1].text.isEmpty)
        let row = node.children[0]
        XCTAssertEqual(row.children.map(\.name), ["mi", "mo", "mtext"])
        XCTAssertEqual(row.children[0].attributes["mathvariant"], "bold")
        XCTAssertEqual(row.children[2].text, "ab")
        XCTAssertEqual(row.children[2].children.map(\.name), ["malignmark"])
    }

    func testImageDrawsLazilyAtItsSize() throws {
        let attachment = try attachment(try make("<msqrt><mi>x</mi></msqrt>").0)
        let bounds = attachment.bounds(lineWidth: 500, height: 0)
        let image = try XCTUnwrap(attachment.image(size: bounds.size))
        XCTAssertEqual(image.size.width, bounds.width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, bounds.height, accuracy: 0.5)
        XCTAssertTrue(attachment.image(size: bounds.size) === image, "cached per size")
        XCTAssertNil(attachment.image(size: .zero))
    }

    @MainActor
    func testAccessibilityReadsTheAlttext() throws {
        let described = try attachment(try make("<msup><mi>x</mi><mn>2</mn></msup>", attributes: "alttext=\"x^2\"").0)
        XCTAssertEqual(described.label, "x^2")
        let spoken = try attachment(try make("<msup><mi>x</mi><mn>2</mn></msup>").0)
        XCTAssertEqual(spoken.label, "x squared")
        #if os(iOS)
        XCTAssertEqual(described.accessibilityLabel, "x^2")
        #elseif os(macOS)
        XCTAssertEqual(described.image?.accessibilityDescription, "x^2")
        XCTAssertEqual(described.textEquivalent, "x^2")
        #endif
    }

    func testEveryCorpusConstructLaysOut() throws {
        // The elements the PDFReflowLib conversions use, as they nest there.
        let formulas = [
            "<mstyle displaystyle=\"true\"><mfrac><mrow><mo>−</mo><mn>36</mn></mrow><mrow><mo>−</mo><mn>9</mn></mrow></mfrac></mstyle>",
            "<mrow><mn>2</mn><msub><mi>x</mi><mn>1</mn></msub><mo>+</mo><mn>3</mn><msub><mi>x</mi><mn>2</mn></msub><mo>=</mo><mn>1</mn></mrow>",
            "<mrow><mi>y</mi><mo>+</mo><mi>d</mi><mi>y</mi><mo>=</mo><mstyle displaystyle=\"true\"><mfrac><mi>u</mi><mi>v</mi></mfrac></mstyle></mrow>",
            "<mrow><mn>5</mn><msqrt><mn>9</mn><mo>·</mo><mn>5</mn></msqrt><mo>+</mo><msup><mi>x</mi><mn>2</mn></msup></mrow>",
        ]
        let section = try section(formulas.map { "<p>\(math($0, attributes: "alttext=\"f\""))</p>" }.joined())
        for formula in section.formulas {
            _ = try attachment(MathContent.make(formula, style: ComputedStyle(fontSize: 17), context: section.context))
        }
        XCTAssertEqual(section.context.report.report.mathFallbacks, 0)
    }
}
