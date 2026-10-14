import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class SVGHTMLRecoveryTests: XCTestCase {
    private let drawing = """
    <svg xmlns='http://www.w3.org/2000/svg' id='drawing' width='160' height='80' viewBox='10 20 80 40' preserveAspectRatio='none'>
    <title>Repeated bands</title><defs>
    <linearGradient id='paint' gradientUnits='userSpaceOnUse' x1='10' y1='20' x2='30' y2='20' spreadMethod='repeat'>
    <stop offset='0' stop-color='red'></stop><stop offset='1' stop-color='blue'></stop></linearGradient>
    <clipPath id='clip' clipPathUnits='userSpaceOnUse'><rect x='10' y='20' width='60' height='40'></rect></clipPath>
    </defs><rect x='10' y='20' width='80' height='40' fill='url(#paint)' clip-path='url(#clip)'></rect></svg>
    """

    private func document(_ markup: String) throws -> ContentDocument {
        try ContentDocument.parse(Data(markup.utf8), path: "OPS/one.xhtml")
    }

    private func image(in text: SectionText) throws -> ReaderImageAttachment {
        XCTAssertEqual(text.richMediaImages.count, 1)
        return try XCTUnwrap(text.richMediaImages.first)
    }

    private func draw(_ attachment: ReaderImageAttachment) throws -> CGImage {
        let size = CGSize(width: 160, height: 80)
        let image = try XCTUnwrap(attachment.image(forBounds: CGRect(origin: .zero, size: size), textContainer: nil, characterIndex: 0))
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return try XCTUnwrap(UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage)
        #else
        return try XCTUnwrap(RichImageTests.draw(image, size: size, scale: 1))
        #endif
    }

    func testRecoveredInlineGradientViewBoxAndClipPathDrawLikeStrictXML() throws {
        let markup = RichMediaBook.xhtml(drawing)
        let strict = try RichMediaBook(section: markup).build()
        XCTAssertFalse(strict.document.recoveredAsHTML)
        let strictImage = try image(in: strict)
        let expected = try draw(strictImage)
        let ink = RichMediaImages.rgba(expected, x: 10, y: 40)
        XCTAssertEqual(ink[3], 255)
        XCTAssertGreaterThan(ink[0], 128, "a gradient paints red toward its beginning")
        XCTAssertGreaterThan(ink[2], 32, "the gradient also paints blue, rather than a solid fallback")
        XCTAssertEqual(RichMediaImages.rgba(expected, x: 50, y: 40), ink, "spreadMethod repeats every 40 displayed points")
        XCTAssertEqual(RichMediaImages.rgba(expected, x: 90, y: 40), ink)
        XCTAssertEqual(RichMediaImages.rgba(expected, x: 140, y: 40)[3], 0, "the restored clipPath clips the final 40 points")

        let recoveries = [
            markup.replacingOccurrences(of: "<body>", with: "<body><p>&nbsp;</p>"),
            markup.replacingOccurrences(of: "</body>", with: "<p>After</div></body>"),
            markup.replacingOccurrences(of: "xmlns=\"http://www.w3.org/1999/xhtml\"", with: "")
        ]
        for markup in recoveries {
            let text = try RichMediaBook(section: markup).build()
            XCTAssertTrue(text.document.recoveredAsHTML)
            XCTAssertFalse(text.document.canResolveCFIs, "restoring SVG names does not qualify an HTML 4 tree for CFIs")
            let recovered = try image(in: text)
            XCTAssertEqual(recovered.source.format, .svg)
            XCTAssertEqual(recovered.sizing.intrinsic, CGSize(width: 160, height: 80))
            XCTAssertEqual(recovered.alt, "Repeated bands")
            let bitmap = try draw(recovered)
            XCTAssertEqual(bitmap.width, expected.width)
            XCTAssertEqual(bitmap.height, expected.height)
            // Compare complete sampled rows through the same color-space conversion,
            // including repeated bands and transparency beyond the clip, on both platforms.
            for y in stride(from: 0, to: 80, by: 5) {
                for x in 0..<160 {
                    XCTAssertEqual(RichMediaImages.rgba(bitmap, x: x, y: y), RichMediaImages.rgba(expected, x: x, y: y), "pixel (\(x), \(y))")
                }
            }
            let offset = try XCTUnwrap(text.richMediaAttachments.first?.location)
            let position = try XCTUnwrap(text.map.position(at: offset, in: text.document))
            XCTAssertTrue(position.node === text.document.element(id: "drawing"))
            XCTAssertEqual(position.offset, 0)
            for (order, node) in text.document.nodes.enumerated() {
                XCTAssertEqual(node.order, order)
                if let parent = node.parent { XCTAssertTrue(parent.children[node.indexInParent] === node) }
            }
        }
    }

    func testHTMLRecoveryAppliesEverySVGElementAndAttributeAdjustment() throws {
        // HTML Standard tables, including names of constructs the renderer later omits.
        // Exercise conversion of actual HTML tokens, not just the table lookup helper.
        let elements = ["altGlyph", "altGlyphDef", "altGlyphItem", "animateColor", "animateMotion", "animateTransform",
                        "clipPath", "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix",
                        "feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA",
                        "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology",
                        "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile", "feTurbulence",
                        "foreignObject", "glyphRef", "linearGradient", "radialGradient", "textPath"]
        let attributes = ["attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode", "clipPathUnits",
                          "diffuseConstant", "edgeMode", "filterUnits", "glyphRef", "gradientTransform", "gradientUnits",
                          "kernelMatrix", "kernelUnitLength", "keyPoints", "keySplines", "keyTimes", "lengthAdjust",
                          "limitingConeAngle", "markerHeight", "markerUnits", "markerWidth", "maskContentUnits", "maskUnits",
                          "numOctaves", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "pointsAtX",
                          "pointsAtY", "pointsAtZ", "preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY",
                          "repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures", "specularConstant",
                          "specularExponent", "spreadMethod", "startOffset", "stdDeviation", "stitchTiles", "surfaceScale",
                          "systemLanguage", "tableValues", "targetX", "targetY", "textLength", "viewBox", "viewTarget",
                          "xChannelSelector", "yChannelSelector", "zoomAndPan"]
        let content = elements.enumerated().map { "<\($0.element.uppercased()) id='e\($0.offset)'></\($0.element.uppercased())>" }.joined()
        let properties = attributes.map { "\($0.uppercased())='KeepCase'" }.joined(separator: " ")
        let parsed = try document("<html><head><title>T</title></head><body><svg id='svg' \(properties)>\(content)</svg></body></html>")
        XCTAssertTrue(parsed.recoveredAsHTML)
        let svg = try XCTUnwrap(parsed.element(id: "svg"))
        XCTAssertEqual(svg.namespace, ContentNamespace.svg)
        for (i, name) in elements.enumerated() {
            let element = try XCTUnwrap(parsed.element(id: "e\(i)"), name)
            XCTAssertEqual(element.name, name)
            XCTAssertEqual(element.namespace, ContentNamespace.svg)
        }
        for name in attributes { XCTAssertEqual(svg.attribute(name), "KeepCase", name) }
    }

    func testSVGAdjustmentsRespectStrictXMLAndHTMLIntegrationPoints() throws {
        let strict = try document(RichMediaBook.xhtml("<svg xmlns='http://www.w3.org/2000/svg' id='s' viewbox='0 0 10 10'><lineargradient id='g' spreadmethod='repeat'></lineargradient></svg>"))
        XCTAssertFalse(strict.recoveredAsHTML)
        XCTAssertNotNil(strict.element(id: "s")?.attribute("viewbox"))
        XCTAssertNil(strict.element(id: "s")?.attribute("viewBox"))
        XCTAssertEqual(strict.element(id: "g")?.name, "lineargradient", "XML SVG is case-sensitive")
        XCTAssertNotNil(strict.element(id: "g")?.attribute("spreadmethod"))
        let recovered = try document("""
            <html><head><title>T</title></head><body><linearGradient id='outside' viewBox='0 0 1 1'></linearGradient>
            <svg id='svg'><foreignObject id='foreign'><div id='html' viewBox='0 0 1 1'>Prose
            <svg id='inner' viewBox='0 0 2 1'><linearGradient id='gradient'></linearGradient></svg></div></foreignObject>
            <desc><span id='description'>Description</span></desc><unknownCamelCase id='unknown'></unknownCamelCase></svg></body></html>
            """)
        XCTAssertEqual(recovered.element(id: "outside")?.name, "lineargradient")
        XCTAssertEqual(recovered.element(id: "outside")?.namespace, "")
        XCTAssertNotNil(recovered.element(id: "outside")?.attribute("viewbox"))
        XCTAssertEqual(recovered.element(id: "foreign")?.name, "foreignObject")
        XCTAssertEqual(recovered.element(id: "html")?.namespace, "")
        XCTAssertNotNil(recovered.element(id: "html")?.attribute("viewbox"))
        XCTAssertEqual(recovered.element(id: "inner")?.namespace, ContentNamespace.svg)
        XCTAssertNotNil(recovered.element(id: "inner")?.attribute("viewBox"))
        XCTAssertEqual(recovered.element(id: "gradient")?.name, "linearGradient")
        XCTAssertEqual(recovered.element(id: "description")?.namespace, "")
        XCTAssertEqual(recovered.element(id: "unknown")?.name, "unknowncamelcase", "only names in the adjustment table gain mixed case")
    }

    func testRecoveredForeignAttributesStayBoundedAndUnsafeContentIsOmitted() throws {
        let svg = drawing.replacingOccurrences(of: "</svg>", with: """
            <foreignObject><p>Do not render HTML</p></foreignObject><animateTransform attributeName='transform'></animateTransform>
            <script>alert(1)</script><use XLINK:HREF='#clip' XML:LANG='en' XML:SPACE='preserve' foo:href='file:///unbound'/>
            <image href='file:///external' width='1' height='1'></image></svg>
            """)
        let book = try RichMediaBook(section: RichMediaBook.xhtml("<p>&nbsp;</p>" + svg))
        let text = book.build()
        XCTAssertTrue(text.document.recoveredAsHTML)
        let use = try XCTUnwrap(text.document.nodes.first { $0.name == "use" })
        XCTAssertEqual(use.attribute("href", namespace: ContentNamespace.xlink), "#clip")
        XCTAssertEqual(use.attribute("lang", namespace: ContentNamespace.xml), "en")
        XCTAssertEqual(use.attribute("space", namespace: ContentNamespace.xml), "preserve")
        XCTAssertEqual(use.attribute("foo:href"), "file:///unbound")
        let root = try XCTUnwrap(text.document.element(id: "drawing"))
        let bytes = try XCTUnwrap(SVGContent.serialize(root, resolve: { _ in nil }, publication: book.publication))
        let serialized = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["foreignObject", "animateTransform", "<script", "foo:href", "file:", "Do not render HTML"] {
            XCTAssertFalse(serialized.contains(forbidden), forbidden)
        }
        XCTAssertTrue(serialized.contains("xlink:href=\"#clip\""))
        XCTAssertEqual(text.report.unsupportedElements["svg:foreignObject"], 1)
        XCTAssertEqual(text.report.unsupportedElements["svg:animateTransform"], 1)
        XCTAssertEqual(text.report.unsupportedElements["svg:script"], 1)
        let rendered = try draw(try image(in: text))
        XCTAssertGreaterThan(RichMediaImages.rgba(rendered, x: 10, y: 40)[0], 128)
    }

    func testRecoveredGradientNamesCannotEvadeTheRenderingCostScreen() throws {
        let stops = String(repeating: "<stop stop-color='red'></stop>", count: 5_000)
        let rects = String(repeating: "<rect width='1' height='1' fill='url(#g)'></rect>", count: 2_000)
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' id='svg' width='20' height='20'><defs><linearGradient id='g'>\(stops)</linearGradient></defs>\(rects)</svg>"
        let strict = try document(RichMediaBook.xhtml(svg))
        let recovered = try document(RichMediaBook.xhtml("<p>&nbsp;</p>" + svg))
        XCTAssertFalse(strict.recoveredAsHTML)
        XCTAssertTrue(recovered.recoveredAsHTML)
        let strictRoot = try XCTUnwrap(strict.element(id: "svg")), recoveredRoot = try XCTUnwrap(recovered.element(id: "svg"))
        let original = SVGContent.copyVerdict(strictRoot), adjusted = SVGContent.copyVerdict(recoveredRoot)
        XCTAssertGreaterThan(original.copies, SVGContent.maximumSharedCopies)
        XCTAssertEqual(adjusted.copies, original.copies, "preflight counts the same restored names the renderer receives")
        XCTAssertFalse(adjusted.withinLimits)
        XCTAssertFalse(SVGContent.isWithinRenderingLimits(recoveredRoot))
        // This refusal is checked before rendering; never give the expensive SVG to the decoder.
    }
}
