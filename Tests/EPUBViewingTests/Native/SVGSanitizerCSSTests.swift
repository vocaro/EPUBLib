import CoreText
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import StaticSVG
import XCTest
@testable import EPUBViewing

/// The CSS the SVG sanitizer hands the bundled renderer, as the reader shows it. Every `filter`
/// the renderer would apply is removed or refused, wherever its tokenizer finds one
/// ([#253](https://github.com/vocaro/EPUBLib/issues/253)), and CSS is read by Unicode scalar, so
/// that a mark after a delimiter hides nothing and each input behaves as its mark-free twin does
/// ([#248](https://github.com/vocaro/EPUBLib/issues/248)).
///
/// What the sanitizer writes and the renderer reads is tested in StaticSVG's
/// `SVGSanitizerCSSTests`. These check the reader's attachment, its section report and the font
/// registry's family names.
final class SVGSanitizerCSSTests: XCTestCase {
    private static let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"

    // MARK: #253: a filter wherever the renderer finds one

    /// Each spelling was drawn by the renderer before this screen read it: the rectangle came out
    /// inverted (#253). The direct entry now refuses it, as it refuses the well-spelled twin, and
    /// through the reader both draw the red fill and blue stroke with the filter omitted.
    func testEveryFilterSpellingIsRefusedDirectlyAndOmittedFromTheDrawing() throws {
        let rect = "<rect x='10' y='10' width='20' height='20'"
        let twins = [
            ("\(rect) style='fill:red !importantfilter:invert(1); stroke:blue; stroke-width:4'/>",
             "\(rect) style='fill:red !important; filter:invert(1); stroke:blue; stroke-width:4'/>"),
            ("\(rect) style='fill:red *filter:invert(1); stroke:blue; stroke-width:4'/>",
             "\(rect) style='fill:red; filter:invert(1); stroke:blue; stroke-width:4'/>"),
            ("\(rect) fill='red' stroke='blue' stroke-width='4' xlink:filter='invert(1)'/>",
             "\(rect) fill='red' stroke='blue' stroke-width='4' filter='invert(1)'/>"),
            ("<style>.r{fill:red !importantfilter:invert(1);stroke:blue;stroke-width:4}</style>\(rect) class='r'/>",
             "<style>.r{fill:red !important;filter:invert(1);stroke:blue;stroke-width:4}</style>\(rect) class='r'/>"),
            ("<style>.r{stroke:blue;stroke-width:4;fill:red *filter:invert(1)}</style>\(rect) class='r'/>",
             "<style>.r{stroke:blue;stroke-width:4;fill:red;filter:invert(1)}</style>\(rect) class='r'/>"),
        ]
        for (spelling, twin) in twins {
            for attributes in [spelling, twin] {
                let svg = "<svg \(Self.ns) id='s' width='40' height='40'>\(attributes)</svg>"
                XCTAssertNil(ReaderImageSource.svg(Data(svg.utf8), path: "", key: UUID().uuidString), "refused directly: \(attributes)")
                let fixture = try RichFixture(svg)
                let attachment = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment, attributes)
                let image = try XCTUnwrap(attachment.source.decode(maxPixelSize: 40))
                XCTAssertEqual(RichMediaImages.rgba(image, x: 20, y: 20), [255, 0, 0, 255], "fill without the filter: \(attributes)")
                XCTAssertEqual(RichMediaImages.rgba(image, x: 10, y: 20), [0, 0, 255, 255], "the stroke after it: \(attributes)")
                XCTAssertEqual(fixture.report.report.unsupportedElements["svg:filter"], 1, attributes)
            }
        }
    }

    // MARK: #248: CSS read by scalar

    /// An embedded font's own family name comes from its file, which is book content. Before, a
    /// font whose name table said `Times'New Roman` was written `'Times'New Roman'`, and a name
    /// could end the string and add declarations of its own. Such a name is not put in the CSS:
    /// the family stays as the drawing names it. How StaticSVG writes other names is tested there.
    func testAnEmbeddedFontsOwnNameIsQuotedOnlyWhenNothingInItIsCSS() throws {
        var font = try XCTUnwrap(SVGFontData.export(CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 12, nil))).data
        func replace(_ name: String, with other: String, encoding: (String) -> [UInt8]) {
            let (from, to) = (encoding(name), encoding(other))
            var index = font.startIndex
            while let range = font[index...].firstRange(of: from) {
                font.replaceSubrange(range, with: to)
                index = range.upperBound
            }
        }
        let utf16 = { (text: String) in Array(text.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }
        replace("Times New Roman", with: "Times'New Roman", encoding: { Array($0.utf8) })
        replace("Times New Roman", with: "Times'New Roman", encoding: utf16)
        let fixture = try RichFixture("<svg \(Self.ns) id='s' width='180' height='40'><text x='2' y='30' font-family='BookFont' style='font-family: BookFont; font-size: 24px'>Archive font</text></svg>", files: ["font.ttf": font])
        var report = SectionReport()
        fixture.fonts.register(CSSStyleSheet.parse("@font-face { font-family: BookFont; src: url(font.ttf); }", path: "OPS/one.xhtml").fontFaces, report: &report)
        let snapshot = fixture.fonts.svgFonts(families: ["bookfont"])
        XCTAssertEqual(snapshot.aliases["bookfont"], "Times'New Roman", "the name is the font's own")
        let data = try XCTUnwrap(SVGContent.serialize(fixture.element("s"), resolve: { _ in nil }, publication: fixture.publication, fontAliases: snapshot.aliases))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("font-family=\"BookFont\" style=\"font-family: BookFont; font-size: 24px\""), text)
    }
}
