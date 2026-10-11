import CoreText
import XCTest
@testable import EPUBViewing

final class FontLengthTests: XCTestCase {
    func testExUsesEmbeddedFaceAndParentMetricsForFontSize() throws {
        let face = CTFontCreateWithName("Georgia" as CFString, 12, nil)
        guard CTFontCopyPostScriptName(face) as String == "Georgia",
              let url = CTFontCopyAttribute(face, kCTFontURLAttribute) as? URL else {
            throw XCTSkip("Georgia is not installed for the embedded-face fixture")
        }
        let bytes = try Data(contentsOf: url)
        for size: CGFloat in [16, 25] {
            let section = StyleTestSupport.xhtml(body: """
                <div id="parent"><p id="child">Embedded font metrics</p><p id="relative">Relative size</p></div>
                """, css: """
                @font-face { font-family: "book face"; src: url("fonts/book.ttf") }
                #parent { font-family: "book face" }
                #child { margin-left: 2ex; padding-right: 1ex; text-indent: 3ex; letter-spacing: 0.1ex }
                #relative { font-size: 2ex }
                """)
            let publication = try StyleTestSupport.publication(section: section, files: ["fonts/book.ttf": bytes])
            let document = try ContentDocument.parse(Data(section.utf8), path: "OPS/one.xhtml")
            let fonts = FontRegistry(publication: publication)
            var report = SectionReport()
            let sheets = SectionStyles.load(for: document, publication: publication, fonts: fonts, report: &report)
            let resolver = StyleResolver(document: document, stylesheets: sheets,
                typography: NativeTypography(fontSize: size), fonts: fonts)
            let styles = StyleTestSupport.styleAll(document, resolver)
            let parent = try XCTUnwrap(styles[try XCTUnwrap(document.element(id: "parent")).order])
            let child = try XCTUnwrap(styles[try XCTUnwrap(document.element(id: "child")).order])
            let relative = try XCTUnwrap(styles[try XCTUnwrap(document.element(id: "relative")).order])
            XCTAssertEqual(fonts.font(for: child).fontName, "Georgia")
            let metric = CTFontGetXHeight(fonts.font(for: child) as CTFont)
            XCTAssertEqual(child.margin.left.resolve(reference: 300, viewport: .zero)!, metric * 2, accuracy: 0.001)
            XCTAssertEqual(child.padding.right.resolve(reference: 300, viewport: .zero)!, metric, accuracy: 0.001)
            XCTAssertEqual(child.textIndent.resolve(reference: 300, viewport: .zero)!, metric * 3, accuracy: 0.001)
            XCTAssertEqual(child.letterSpacing, metric * 0.1, accuracy: 0.001)
            XCTAssertEqual(relative.fontSize, CTFontGetXHeight(fonts.font(for: parent) as CTFont) * 2, accuracy: 0.001)
        }
    }
}
