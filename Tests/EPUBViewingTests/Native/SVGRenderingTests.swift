import CoreGraphics
import CoreText
import CryptoKit
import EPUBCore
import EPUBReading
import Foundation
import ImageIO
import XCTest
@testable import EPUBViewing

final class SVGRenderingTests: XCTestCase {
    private let drawing = """
    <svg xmlns='http://www.w3.org/2000/svg' width='200' height='100' viewBox='0 0 200 100'>
    <title>Workflow</title><desc>Red box and blue circle.</desc>
    <defs><clipPath id='clip'><rect width='40' height='30'/></clipPath></defs>
    <rect width='200' height='100' fill='white'/>
    <g transform='translate(10 10)' clip-path='url(#clip)'><rect width='80' height='40' fill='red'/></g>
    <circle cx='140' cy='30' r='20' fill='blue'/>
    <path d='M70 30 C80 10 100 50 110 30' fill='none' stroke='green' stroke-width='4'/>
    <text x='10' y='88' font-family='Arial' font-size='20'>SVG labels</text></svg>
    """

    func testInlineAndResourceRenderIdenticalShapesTextTransformsAndClipping() throws {
        let fixture = try RichFixture(drawing.replacingOccurrences(of: "<svg ", with: "<svg id='inline' ") + "<img id='file' src='drawing.svg'/>", files: ["drawing.svg": Data(drawing.utf8)])
        let inline = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("inline")).first as? ReaderImageAttachment)
        let file = try XCTUnwrap(RichFixture.attachments(in: fixture.image("file")).first as? ReaderImageAttachment)
        XCTAssertEqual(inline.alt, "Workflow. Red box and blue circle.")
        XCTAssertEqual(file.alt, inline.alt)
        let image = try XCTUnwrap(inline.source.decode(maxPixelSize: 200))
        XCTAssertEqual(image.dataProvider?.data as Data?, try XCTUnwrap(file.source.decode(maxPixelSize: 200)).dataProvider?.data as Data?)
        XCTAssertEqual(pixel(image, 20, 20), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, 60, 20), [255, 255, 255, 255])
        XCTAssertEqual(pixel(image, 140, 30), [0, 0, 255, 255])
        XCTAssertEqual(pixel(image, 90, 30), [0, 128, 0, 255], "Cubic path connector")
        var ink = 0
        for y in 70..<90 { for x in 10..<120 { let p = pixel(image, x, y); if p[0] < 100 && p[1] < 100 && p[2] < 100 { ink += 1 } } }
        XCTAssertGreaterThan(ink, 100, "Font glyphs must actually be painted")
        XCTAssertEqual(fixture.report.report.unsupportedElements, [:])
        if let path = ProcessInfo.processInfo.environment["EPUBLIB_SVG_VISUAL_OUTPUT"] {
            let output = NSMutableData()
            let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            try (output as Data).write(to: URL(fileURLWithPath: path))
        }
    }

    func testViewBoxOffsetLetterboxingAndStretch() throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='160' height='80' viewBox='10 20 40 40'><rect x='10' y='20' width='40' height='40' fill='red'/></svg>"
        let fixture = try RichFixture(svg.replacingOccurrences(of: "<svg ", with: "<svg id='s' "))
        let attachment = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment)
        XCTAssertEqual(attachment.sizing.intrinsic, CGSize(width: 160, height: 80))
        let image = try XCTUnwrap(attachment.source.decode(maxPixelSize: 160))
        XCTAssertEqual(pixel(image, 20, 40)[3], 0)
        XCTAssertEqual(pixel(image, 80, 40), [255, 0, 0, 255])
        let stretched = svg.replacingOccurrences(of: "width='160'", with: "preserveAspectRatio='none' width='160'")
        let source = try XCTUnwrap(ReaderImageSource.svg(Data(stretched.utf8), path: "", key: "stretch"))
        XCTAssertEqual(pixel(try XCTUnwrap(source.decode(maxPixelSize: 160)), 20, 40), [255, 0, 0, 255])
    }

    func testImageChildTransformUsesRendererAndArchiveBitmap() throws {
        let fixture = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='100' height='50'><image transform='translate(20 10)' href='dot.png' width='20' height='20'/></svg>", files: ["dot.png": RichFixture.image(width: 20, height: 20)])
        let image = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment)
        XCTAssertEqual(image.source.format, .svg)
        let bitmap = try XCTUnwrap(image.source.decode(maxPixelSize: 100))
        XCTAssertEqual(pixel(bitmap, 10, 10)[3], 0)
        XCTAssertEqual(pixel(bitmap, 25, 15)[3], 255)
    }

    func testRendererCannotReadExistingAbsoluteImageOrRecursiveSVGData() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try RichFixture.image(width: 10, height: 10).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><image href='\(path.path)' width='10' height='10'/><rect x='10' width='10' height='10' fill='blue'/></svg>"
        let source = try XCTUnwrap(ReaderImageSource.svg(Data(svg.utf8), path: "", key: "external"))
        let image = try XCTUnwrap(source.decode(maxPixelSize: 20))
        XCTAssertEqual(pixel(image, 5, 5)[3], 0)
        XCTAssertEqual(pixel(image, 15, 5), [0, 0, 255, 255])
        let nested = Data(svg.utf8).base64EncodedString()
        XCTAssertNil(ReaderImageSource.svg(Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><image href='data:image/svg+xml;base64,\(nested)' width='10' height='10'/></svg>".utf8), path: "", key: "nested"))
    }

    func testCyclicUseAndFiltersHaveAuthoredDisclosedFallback() throws {
        let fixture = try RichFixture("""
        <svg xmlns='http://www.w3.org/2000/svg' id='cycle' width='20' height='20'><title>Recursive diagram</title><defs><g id='a'><use href='#b'/></g><g id='b'><use href='#a'/></g></defs><use href='#a'/></svg>
        <svg xmlns='http://www.w3.org/2000/svg' id='filter' width='20' height='20'><desc>Blurred diagram</desc><filter id='f'><feGaussianBlur stdDeviation='2'/></filter><rect width='20' height='20' filter='url(#f)'/></svg>
        """)
        XCTAssertEqual(fixture.svg("cycle")?.string, "Recursive diagram")
        XCTAssertEqual(fixture.svg("filter")?.string, "Blurred diagram")
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg"], 2)
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg:filter"], 1)
        let pattern = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='10' height='10'><title>Pattern sample</title><defs><pattern id='p' patternUnits='userSpaceOnUse' width='1e9' height='1e9'><rect width='1e9' height='1e9'/></pattern></defs><rect width='10' height='10' fill='url(#p)'/></svg>")
        XCTAssertEqual(pattern.svg("s")?.string, "Pattern sample")
        XCTAssertEqual(pattern.report.report.unsupportedElements["svg:pattern"], 1)
    }

    func testCoreTextSFNTExportAndEmbeddedFontAlias() throws {
        let exported = try XCTUnwrap(SVGFontData.export(CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 12, nil)))
        XCTAssertFalse((CTFontManagerCreateFontDescriptorsFromData(exported.data as CFData) as? [CTFontDescriptor] ?? []).isEmpty)
        let fixture = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='180' height='40'><text x='2' y='30' font-family='BookFont' font-size='24'>Archive font</text></svg>", files: ["font.ttf": exported.data])
        var report = SectionReport()
        fixture.fonts.register(CSSStyleSheet.parse("@font-face { font-family: BookFont; src: url(font.ttf); }", path: "OPS/one.xhtml").fontFaces, report: &report)
        let snapshot = fixture.fonts.svgFonts(families: ["bookfont"])
        XCTAssertEqual(snapshot.aliases["bookfont"], exported.family)
        XCTAssertFalse(snapshot.fonts.isEmpty)
        let attachment = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment)
        XCTAssertGreaterThan((try XCTUnwrap(attachment.source.decode(maxPixelSize: 180)).dataProvider?.data as Data?)?.filter { $0 > 0 }.count ?? 0, 100)
    }

    func testLegacyAppleBoldFontKeepsWeightWhenOS2TableIsMissing() throws {
        let font = CTFontCreateWithName("Courier-Bold" as CFString, 12, nil)
        let exported = try XCTUnwrap(SVGFontData.export(font))
        func u16(_ offset: Int) -> Int { Int(exported.data[offset]) << 8 | Int(exported.data[offset + 1]) }
        func u32(_ offset: Int) -> Int { u16(offset) << 16 | u16(offset + 2) }
        let index = try XCTUnwrap((0..<u16(4)).first { u32(12 + $0 * 16) == 0x4F532F32 })
        let offset = u32(12 + index * 16 + 8)
        XCTAssertEqual(u16(offset + 4), 700)
        XCTAssertFalse((CTFontManagerCreateFontDescriptorsFromData(exported.data as CFData) as? [CTFontDescriptor] ?? []).isEmpty)
    }

    func testColorFontGlyphsCannotBypassSVGPreflight() throws {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 12, nil)
        XCTAssertTrue(SVGFontData.hasColorGlyphs(font))
        if let exported = SVGFontData.export(font) {
            XCTAssertTrue(exported.strippedColorGlyphs)
            XCTAssertFalse(SVGFontData.hasColorGlyphs(exported.data))
            XCTAssertFalse((CTFontManagerCreateFontDescriptorsFromData(exported.data as CFData) as? [CTFontDescriptor] ?? []).isEmpty)
        }
        let fixture = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='80' height='40'><text x='2' y='30' font-family='Apple Color Emoji' font-size='24'>ABC</text></svg>")
        let attachment = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment)
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg:font-color"], 1)
        XCTAssertNotNil(attachment.source.decode(maxPixelSize: 80))
    }

    func testLiveFontDatabasesStayBoundedAfterOptionsCacheEviction() throws {
        let exported = try XCTUnwrap(SVGFontData.export(CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 12, nil)))
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><text y='15'>ABC</text></svg>".utf8)
        var held: [SVGRenderer] = []
        // SFNT permits trailing bytes. Distinct padded valid fonts force separate immutable
        // databases, while keeping every parsed tree alive beyond the four-entry cache.
        for index in 0..<20 {
            var data = exported.data
            data.append(Data(count: SVGFontData.maximumBytes - data.count))
            data[data.count - 1] = UInt8(index)
            guard let renderer = SVGRenderer(svg, fonts: [SVGFontData(family: exported.family, data: data)]) else { break }
            held.append(renderer)
        }
        XCTAssertGreaterThan(held.count, 1)
        XCTAssertLessThan(held.count, 20, "Live trees must retain the database byte reservation")
        XCTAssertNotNil(held.first?.render(maxPixelSize: 40))
        held.removeAll()
        var replacement = exported.data
        replacement.append(Data(count: SVGFontData.maximumBytes - replacement.count))
        replacement[replacement.count - 1] = 250
        XCTAssertNotNil(SVGRenderer(svg, fonts: [SVGFontData(family: exported.family, data: replacement)]), "Releasing trees returns their reservations")
    }

    func testRepeatedUseStylesAndRasterRequestsRespectLayerBudget() throws {
        let svg = """
        <svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'>
        <style>.layer { opacity: .5; }</style><defs><g id='a' class='layer'><rect width='100' height='100'/></g></defs>
        <use href='#a'/><use href='#a'/><use href='#a'/></svg>
        """
        let document = try ContentDocument.parse(Data(svg.utf8), path: "style.svg")
        let layers = SVGContent.isolatedLayers(document.root)
        XCTAssertGreaterThan(layers, document.nodes.filter(\.isElement).count, "Expanded uses and CSS isolation are counted")
        let source = try XCTUnwrap(ReaderImageSource.svg(Data(svg.utf8), path: "", key: "budget"))
        let image = try XCTUnwrap(source.decode(maxPixelSize: Int.max))
        XCTAssertLessThanOrEqual(image.width * image.height * (4 + 25 * 5 * layers), 96 * 1024 * 1024)
        let deep = String(repeating: "<g>", count: 65) + "<rect width='1' height='1'/>" + String(repeating: "</g>", count: 65)
        XCTAssertNil(ReaderImageSource.svg(Data("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'>\(deep)</svg>".utf8), path: "", key: "deep"))
    }

    func testExpandedPathCostAndLargeDataRasterAreRefusedBeforeRendering() throws {
        let path = String(repeating: "L1 1 ", count: 120_000)
        let uses = String(repeating: "<use href='#a'/>", count: 20)
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><defs><path id='a' d='M0 0 \(path)'/></defs>\(uses)</svg>"
        XCTAssertNil(ReaderImageSource.svg(Data(svg.utf8), path: "", key: "expanded"))
        let data = RichFixture.image(width: 2100, height: 2100).base64EncodedString()
        let embedded = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><image href='data:image/png;base64,\(data)' width='10' height='10'/></svg>"
        XCTAssertNil(ReaderImageSource.svg(Data(embedded.utf8), path: "", key: "pixels"))
    }

    func testOriginalNetworkingSVGCorpusWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBLIB_SVG_CORPUS"] else { throw XCTSkip("Set EPUBLIB_SVG_CORPUS to the unchanged publisher networking EPUB") }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "54d3886b30e92daca03f2f66065c01cb0d48c592824365605308b7b542c45c6d")
        let publication = try EPUBPublication.open(data: bytes)
        let fonts = FontRegistry(publication: publication)
        var rendered = 0
        var filtered = 0
        var dimensions: [[String: Any]] = []
        for resource in publication.resources where resource.path.hasSuffix(".svg") {
            let data = try publication.data(at: resource.path)
            let document = try ContentDocument.parse(data, path: resource.path)
            if SVGContent.unsupportedConstructs(document.root).contains("svg:filter") { filtered += 1; continue }
            let snapshot = fonts.svgFonts(families: SVGContent.fontFamilies(document.root))
            let serialized = try XCTUnwrap(SVGContent.serialize(document.root, resolve: { _ in nil }, publication: publication, fontAliases: snapshot.aliases), resource.path)
            let source = try XCTUnwrap(ReaderImageSource.svg(serialized, path: resource.path, key: resource.path, fonts: snapshot.fonts), resource.path)
            let image = try XCTUnwrap(source.decode(maxPixelSize: 1024), resource.path)
            XCTAssertGreaterThan(image.width, 10)
            rendered += 1
            dimensions.append(["path": resource.path, "width": image.width, "height": image.height])
            if (resource.path == "media/file29.svg" || resource.path == "media/file32.svg"), let outputPath = ProcessInfo.processInfo.environment["EPUBLIB_SVG_CORPUS_VISUAL_OUTPUT"] {
                let output = NSMutableData()
                let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                try (output as Data).write(to: URL(fileURLWithPath: resource.path == "media/file29.svg" ? outputPath : outputPath + ".paths.png"))
            }
        }
        XCTAssertEqual(rendered, 27)
        XCTAssertEqual(filtered, 6, "Unsupported shadows have explicit authored fallback")
        if let outputPath = ProcessInfo.processInfo.environment["EPUBLIB_SVG_CORPUS_VISUAL_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: dimensions, options: .prettyPrinted).write(to: URL(fileURLWithPath: outputPath + ".dimensions.json"))
        }
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }
}
