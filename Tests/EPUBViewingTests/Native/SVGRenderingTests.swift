import CoreGraphics
import CoreText
import CryptoKit
import EPUBCore
import EPUBReading
import Foundation
import ImageIO
import StaticSVG
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    }

    func testImageChildTransformUsesRendererAndArchiveBitmap() throws {
        let fixture = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='100' height='50'><image transform='translate(20 10)' href='dot.png' width='20' height='20'/></svg>", files: ["dot.png": RichFixture.image(width: 20, height: 20)])
        let image = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment)
        XCTAssertEqual(image.source.format, .svg)
        let bitmap = try XCTUnwrap(image.source.decode(maxPixelSize: 100))
        XCTAssertEqual(pixel(bitmap, 10, 10)[3], 0)
        XCTAssertEqual(pixel(bitmap, 25, 15)[3], 255)
    }

    func testCyclicUseFallsBackAndOmittedFiltersPreserveDisclosedDrawing() throws {
        let fixture = try RichFixture("""
        <svg xmlns='http://www.w3.org/2000/svg' id='cycle' width='20' height='20'><title>Recursive diagram</title><defs><g id='a'><use href='#b'/></g><g id='b'><use href='#a'/></g></defs><use href='#a'/></svg>
        <svg xmlns='http://www.w3.org/2000/svg' id='filter' width='20' height='20'><desc>Blurred diagram</desc><filter id='f'><feGaussianBlur stdDeviation='2'/></filter><rect width='20' height='20' filter='url(#f)'/></svg>
        """)
        XCTAssertEqual(fixture.svg("cycle")?.string, "Recursive diagram")
        let filtered = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("filter")).first as? ReaderImageAttachment)
        XCTAssertEqual(filtered.alt, "Blurred diagram")
        XCTAssertEqual(pixel(try XCTUnwrap(filtered.source.decode(maxPixelSize: 20)), 10, 10), [0, 0, 0, 255])
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg"], 1)
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg:filter"], 1)
        let pattern = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='10' height='10'><title>Pattern sample</title><defs><pattern id='p' patternUnits='userSpaceOnUse' width='1e9' height='1e9'><rect width='1e9' height='1e9'/></pattern></defs><rect width='10' height='10' fill='url(#p)'/></svg>")
        XCTAssertEqual(pattern.svg("s")?.string, "Pattern sample")
        XCTAssertEqual(pattern.report.report.unsupportedElements["svg:pattern"], 1)
    }

    func testFilterCSSOmissionPreservesPaintFontsAndLocalClipping() throws {
        let svg = """
        <svg xmlns='http://www.w3.org/2000/svg' id='s' width='120' height='80'>
        <defs><filter id='shadow'><feGaussianBlur stdDeviation='1e9'/></filter>
        <clipPath id='clip'><rect width='60' height='80'/></clipPath></defs>
        <style>.box { filter /* comment */ : url('#shadow'); fill: red; }
        .label {font-size: 14px; filter: url(#shadow); fill: blue; font-family: Arial;}</style>
        <rect class='box' width='120' height='80' style='clip-path: url(#clip); FILTER: url("#shadow"); stroke: blue;'/>
        <text class='label' x='2' y='30'>Labels survive</text></svg>
        """
        let fixture = try RichFixture(svg)
        let attachment = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment)
        let image = try XCTUnwrap(attachment.source.decode(maxPixelSize: 120))
        XCTAssertEqual(pixel(image, 30, 50), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, 90, 50)[3], 0)
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg:filter"], 1)
    }

    func testOmittedFiltersStillRespectExpansionDepthAndArchiveReferenceLimits() throws {
        let fixture = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='20' height='10'><filter id='f'><feImage href='file:///tmp/private.png'/></filter><image href='https://example.com/private.png' width='10' height='10'/><rect x='10' width='10' height='10' fill='blue' filter='url(#f)'/></svg>")
        let attachment = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment)
        let image = try XCTUnwrap(attachment.source.decode(maxPixelSize: 20))
        XCTAssertEqual(pixel(image, 5, 5)[3], 0)
        XCTAssertEqual(pixel(image, 15, 5), [0, 0, 255, 255])
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg:image"], 1)
    }

    func testFourLayerDiagramKeepsAttachmentsAndInspectionInBothAppearancesAtNarrowWidths() throws {
        let boxes = ["Application", "Transport", "Internetwork", "Link"].enumerated().map { row, label in
            "<g filter='url(#Shadow)'><rect x='10' y='\(row * 40 + 10)' width='120' height='40' fill='white' stroke='black'/><text x='20' y='\(row * 40 + 35)' fill='black' font-family='Arial' font-size='14'>\(label)</text></g>"
        }.joined()
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' id='inline' width='140' height='180'><title>Four TCP/IP layers</title><defs><filter id='Shadow'><feGaussianBlur in='SourceAlpha' stdDeviation='1.308'/><feOffset dx='2' dy='2'/><feFlood flood-opacity='.5'/><feComposite operator='in'/></filter></defs>\(boxes)</svg>"
        for dark in [false, true] {
            let fixture = try RichFixture(svg + "<img id='archive' src='layers.svg' alt='Four TCP/IP layers'/>", files: ["layers.svg": Data(svg.utf8)], typography: .init(isDark: dark))
            let inline = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("inline")).first as? ReaderImageAttachment)
            let archive = try XCTUnwrap(RichFixture.attachments(in: fixture.image("archive")).first as? ReaderImageAttachment)
            for attachment in [inline, archive] {
                XCTAssertEqual(attachment.isDark, dark)
                XCTAssertEqual(attachment.alt, "Four TCP/IP layers")
                let bounds = attachment.layoutBounds(line(90, viewport: CGSize(width: 90, height: 300)))
                XCTAssertLessThanOrEqual(bounds.width, 90)
                XCTAssertGreaterThan(bounds.height, 100)
                XCTAssertNotNil(attachment.bitmap(for: bounds, scale: 2))
                let inspected = try XCTUnwrap(ReaderImageInspection.bitmap(for: attachment))
                XCTAssertGreaterThan(inspected.height, Int(bounds.height))
                for row in 0..<4 {
                    var ink = 0
                    for y in (row * 40 + 22)..<(row * 40 + 37) {
                        for x in 19..<121 {
                            let p = pixel(inspected, Int(CGFloat(x) * CGFloat(inspected.width) / 140), Int(CGFloat(y) * CGFloat(inspected.height) / 180))
                            if p[0] < 100 && p[1] < 100 && p[2] < 100 && p[3] > 200 { ink += 1 }
                        }
                    }
                    XCTAssertGreaterThan(ink, 40, "Each layer label must paint in the inspection bitmap")
                }
            }
            XCTAssertEqual(fixture.report.report.unsupportedElements["svg:filter"], 2)
            XCTAssertNil(fixture.report.report.unsupportedElements["svg"])
        }
    }

    @MainActor func testFilteredDiagramOpensZoomsAndClosesInNarrowNativeReaders() async throws {
        for dark in [false, true] {
            let fixture = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='180' height='240'><title>TCP/IP layers</title><filter id='f'><feGaussianBlur stdDeviation='2'/></filter><g filter='url(#f)'><rect width='180' height='240' fill='white' stroke='black'/><text x='10' y='30' font-size='14'>Application Transport</text><text x='10' y='60' font-size='14'>Internetwork Link</text></g></svg>", typography: .init(isDark: dark))
            let rendered = try XCTUnwrap(fixture.svg("s"))
            let attachment = try XCTUnwrap(RichFixture.attachments(in: rendered).first as? ReaderImageAttachment)
            for flow in [EPUBReadingFlow.paginated, .scrolled] {
                var configuration = ReaderCanvasConfiguration(); configuration.flow = flow; configuration.isDark = dark
                let source = FakeCanvasSource([rendered]); source.book = CanvasText.book([rendered])
                let host = CanvasHost(source, size: CGSize(width: 320, height: 700), configuration: configuration)
                defer { host.close() }
                host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
                host.layOut(); try await host.settle(100)
                let anchor = host.canvas.anchor
                host.canvas.inspectImage(attachment)
                let inspector = try XCTUnwrap(host.canvas.imageInspector)
                #if os(macOS)
                let fitted = inspector.scrollView.magnification
                #else
                let fitted = inspector.scrollView.zoomScale
                #endif
                inspector.zoomIn(); inspector.zoomIn()
                #if os(macOS)
                XCTAssertGreaterThan(inspector.scrollView.magnification, fitted)
                #else
                XCTAssertGreaterThan(inspector.scrollView.zoomScale, fitted)
                #endif
                inspector.close()
                XCTAssertNil(host.canvas.imageInspector)
                XCTAssertEqual(host.canvas.anchor, anchor)
            }
        }
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

    func testColorFontGlyphsCannotBypassSVGPreflight() throws {
        let fixture = try RichFixture("<svg xmlns='http://www.w3.org/2000/svg' id='s' width='80' height='40'><text x='2' y='30' font-family='Apple Color Emoji' font-size='24'>ABC</text></svg>")
        let attachment = try XCTUnwrap(RichFixture.attachments(in: fixture.svg("s")).first as? ReaderImageAttachment)
        XCTAssertEqual(fixture.report.report.unsupportedElements["svg:font-color"], 1)
        XCTAssertNotNil(attachment.source.decode(maxPixelSize: 80))
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
            let svg = try XCTUnwrap(SVGContent.document(document.root), resource.path)
            if svg.constructs.contains(.filter) { filtered += 1 }
            let snapshot = fonts.svgFonts(families: svg.fontFamilies)
            let serialized = try XCTUnwrap(SVGContent.serialize(document.root, resolve: { _ in nil }, publication: publication, fontAliases: snapshot.aliases), resource.path)
            let source = try XCTUnwrap(ReaderImageSource.svg(serialized, path: resource.path, key: resource.path, fonts: snapshot.fonts), resource.path)
            let image = try XCTUnwrap(source.decode(maxPixelSize: 1024), resource.path)
            XCTAssertGreaterThan(image.width, 10)
            if resource.path == "media/file5.svg" {
                // Coordinates from the unchanged publisher viewBox (10 6 135 186).
                // These regions contain the four labels, without the surrounding borders.
                for row in 0..<4 {
                    var ink = 0
                    let top = Int(CGFloat(25 + row * 39) / 186 * CGFloat(image.height))
                    let bottom = Int(CGFloat(40 + row * 39) / 186 * CGFloat(image.height))
                    for y in top..<bottom {
                        for x in Int(CGFloat(image.width) * 25 / 135)..<Int(CGFloat(image.width) * 110 / 135) {
                            let p = pixel(image, x, y)
                            if p[0] < 100 && p[1] < 100 && p[2] < 100 && p[3] > 200 { ink += 1 }
                        }
                    }
                    XCTAssertGreaterThan(ink, 200, "Original TCP/IP layer \(row) has painted text")
                }
                for dark in [false, true] {
                    let fixture = try RichFixture("<img id='layers' src='layers.svg' alt='Four TCP/IP layers'/>", files: ["layers.svg": data], typography: .init(isDark: dark))
                    let attachment = try XCTUnwrap(RichFixture.attachments(in: fixture.image("layers")).first as? ReaderImageAttachment)
                    let bounds = attachment.layoutBounds(line(90, viewport: CGSize(width: 90, height: 300)))
                    XCTAssertLessThanOrEqual(bounds.width, 90)
                    XCTAssertNotNil(attachment.bitmap(for: bounds, scale: 2))
                    XCTAssertNotNil(ReaderImageInspection.bitmap(for: attachment))
                    XCTAssertEqual(fixture.report.report.unsupportedElements["svg:filter"], 1)
                }
            }
            rendered += 1
            dimensions.append(["path": resource.path, "width": image.width, "height": image.height])
            if (resource.path == "media/file29.svg" || resource.path == "media/file32.svg" || resource.path == "media/file5.svg"), let outputPath = ProcessInfo.processInfo.environment["EPUBLIB_SVG_CORPUS_VISUAL_OUTPUT"] {
                let output = NSMutableData()
                let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                let suffix = resource.path == "media/file29.svg" ? "" : resource.path == "media/file5.svg" ? ".layers.png" : ".paths.png"
                try (output as Data).write(to: URL(fileURLWithPath: outputPath + suffix))
            }
        }
        XCTAssertEqual(rendered, 33)
        XCTAssertEqual(filtered, 6, "Shadows are omitted while essential drawings render")
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
