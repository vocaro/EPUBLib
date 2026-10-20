import CoreGraphics
@testable import EPUBViewing
import MathMLLayout
import XCTest

final class MathGlyphImageTests: XCTestCase {
    private func build(_ body: String, files: [String: Data] = [:], attributes: String = "",
                       dark: Bool = false, cache: ReaderImageCache = ReaderImageCache(budget: 16 << 20)) throws
        -> (MathAttachment, SectionReport) {
        let book = try RichMediaBook(body: "<p>\(MathFixtures.math(body, attributes: attributes))</p>", files: files, cache: cache)
        let text = book.build(dark: dark)
        return (try XCTUnwrap(text.richMediaFormulas.first), text.report)
    }

    private var redPNG: Data {
        RichMediaImages.solid(width: 40, height: 20, red: 1, green: 0, blue: 0)
    }

    private func redPixelCount(_ layout: MathLayout) -> Int {
        let bitmap = RichMediaImages.bitmap(width: Int(ceil(layout.width)) + 4,
                                            height: Int(ceil(layout.ascent + layout.descent)) + 4) { context, _ in
            layout.draw(in: context, baselineOrigin: CGPoint(x: 2, y: layout.descent + 2))
        }
        var count = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let pixel = RichMediaImages.rgba(bitmap, x: x, y: y)
                if pixel[0] > 200 && pixel[1] < 50 && pixel[2] < 50 && pixel[3] > 200 { count += 1 }
            }
        }
        return count
    }

    func testPNGDrawsAtAuthoredSizeAndBaselineAndKeepsItsDescription() throws {
        let glyph = "<mglyph src='images/star.png' alt=' red star ' width='30px' height='12px' valign='-3px'/>"
        for body in ["<mi>\(glyph)</mi>", "<mrow>\(glyph)</mrow>"] {
            let (attachment, report) = try build(body, files: ["images/star.png": redPNG])
            XCTAssertEqual(attachment.layout.width, 30, accuracy: 0.01)
            XCTAssertEqual(attachment.layout.ascent, 9, accuracy: 0.01)
            XCTAssertEqual(attachment.layout.descent, 3, accuracy: 0.01)
            XCTAssertGreaterThan(redPixelCount(attachment.layout), 250, "the PNG's red pixels are drawn")
            XCTAssertEqual(attachment.label, "red star")
            XCTAssertEqual(attachment.textEquivalent, "red star")
            XCTAssertEqual(report.mathApproximations, 0)
            XCTAssertEqual(report.unreadableResources, 0)
        }
        let (authored, _) = try build("<mi>\(glyph)</mi>", files: ["images/star.png": redPNG], attributes: "alttext='whole equation'")
        XCTAssertEqual(authored.label, "whole equation")
        XCTAssertGreaterThan(redPixelCount(authored.layout), 250)
    }

    func testEveryTokenKeepsMultipleImagesAmongItsCharacters() throws {
        let cache = ReaderImageCache(budget: 16 << 20)
        for token in ["mi", "mn", "mo", "mtext", "ms"] {
            let (attachment, report) = try build("<\(token)>a<mglyph src='star.png' alt='star' width='10px' height='10px'/>b<mglyph src='star.png' alt='sun' width='10px' height='10px'/>c</\(token)>",
                                                 files: ["star.png": redPNG], cache: cache)
            XCTAssertGreaterThan(redPixelCount(attachment.layout), 150, token)
            XCTAssertTrue(attachment.label.contains("star"), attachment.label)
            XCTAssertTrue(attachment.label.contains("sun"), attachment.label)
            XCTAssertFalse(attachment.label.contains("\u{FFFC}"))
            XCTAssertEqual(report.mathApproximations, 0)
        }
        XCTAssertEqual(cache.decodeCount, 5, "one decode per publication, despite two uses in each token")
        let book = try RichMediaBook(body: "<p>\(MathFixtures.math("<mi><mglyph src='star.png' alt='star'/></mi>"))</p>",
                                     files: ["star.png": redPNG], cache: cache)
        _ = book.build()
        _ = book.build(fontSize: 28)
        XCTAssertEqual(cache.decodeCount, 6, "rebuilding the same publication reuses its decode")
    }

    func testMissingCorruptAndRemoteImagesFallBackWithoutLosingTheFormula() throws {
        for src in ["missing.png", "broken.png", "https://example.invalid/star.png", "file:///etc/hosts"] {
            let (attachment, report) = try build("<mi>x</mi><mo>+</mo><mi><mglyph src='\(src)' alt='star'/></mi>",
                                                 files: ["broken.png": Data("not an image".utf8)])
            XCTAssertEqual(attachment.label, "x plus star")
            XCTAssertEqual(report.mathFallbacks, 0)
            XCTAssertEqual(report.mathApproximations, 1)
            XCTAssertEqual(report.remoteResourcesRefused, src.contains(":") ? 1 : 0)
            XCTAssertEqual(report.unreadableResources, src.contains(":") ? 0 : 1)
            XCTAssertEqual(redPixelCount(attachment.layout), 0)
        }
        let (box, report) = try build("<mi><mglyph src='missing.png'/></mi>")
        XCTAssertGreaterThan(box.layout.width, 0)
        XCTAssertEqual(box.label, "", "a missing description is not invented for speech")
        XCTAssertEqual(report.mathApproximations, 1)
    }

    func testEncodedReferencesIntrinsicSizingAndDownsampling() throws {
        let (encoded, report) = try build("<mi><mglyph src='images/my%20star.png?x=1#fragment' alt='star'/></mi>",
                                         files: ["images/my star.png": redPNG])
        XCTAssertEqual(encoded.layout.width, 40, accuracy: 0.01)
        XCTAssertEqual(encoded.layout.ascent + encoded.layout.descent, 20, accuracy: 0.01)
        XCTAssertEqual(report.unreadableResources, 0)
        let large = RichMediaImages.solid(width: 2048, height: 512)
        let cache = ReaderImageCache(budget: 16 << 20)
        let (attachment, _) = try build("<mi><mglyph src='large.png' alt='wide' width='100px'/></mi>",
                                       files: ["large.png": large], cache: cache)
        XCTAssertEqual(attachment.layout.width, 100, accuracy: 0.01)
        XCTAssertEqual(attachment.layout.ascent + attachment.layout.descent, 25, accuracy: 0.01)
        XCTAssertLessThanOrEqual(cache.totalCost, 1024 * 256 * 4)
    }

    func testSVGAndDarkAppearanceUseTheImagePipeline() throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='red'/></svg>".utf8)
        for dark in [false, true] {
            let (attachment, report) = try build("<mi><mglyph src='star.svg' alt='star' width='20px'/></mi>",
                                                 files: ["star.svg": svg], dark: dark)
            XCTAssertEqual(attachment.layout.width, 20, accuracy: 0.01)
            XCTAssertGreaterThan(redPixelCount(attachment.layout), 100)
            XCTAssertEqual(report.mathApproximations, 0)
        }
    }

    func testGlyphImagesSurviveRowBreakingAndElementaryColumns() throws {
        let glyph = "<mglyph src='star.png' alt='star' width='10px' height='10px'/>"
        let (broken, _) = try build("<mi>\(glyph)</mi><mo linebreak='newline'>=</mo><mi>\(glyph)</mi>", files: ["star.png": redPNG])
        XCTAssertEqual(broken.formula.natural.rows.count, 2)
        XCTAssertGreaterThan(redPixelCount(broken.layout), 150)
        let (stack, _) = try build("<mstack><mn>1\(glyph)2\(glyph)3</mn></mstack>", files: ["star.png": redPNG])
        XCTAssertTrue((175...210).contains(redPixelCount(stack.layout)), "each image appears in its own number column once")
        XCTAssertTrue(stack.label.contains("star"))
    }

    func testFormulaRetainsABoundedSetOfDecodedGlyphImages() throws {
        let png = RichMediaImages.solid(width: 1024, height: 1024, red: 1, green: 0, blue: 0)
        let files = Dictionary(uniqueKeysWithValues: (0..<5).map { ("\($0).png", png) })
        let content = (0..<5).map { "<mi><mglyph src='\($0).png' alt='symbol \($0)' width='10px' height='10px'/></mi>" }.joined()
        let (attachment, report) = try build(content, files: files)
        XCTAssertEqual(report.unreadableResources, 1)
        XCTAssertEqual(report.mathApproximations, 1)
        XCTAssertEqual(report.mathFallbacks, 0)
        XCTAssertTrue((340...410).contains(redPixelCount(attachment.layout)), "four images draw; the fifth uses its description")
        XCTAssertTrue(attachment.label.contains("symbol 4"))
    }
}
