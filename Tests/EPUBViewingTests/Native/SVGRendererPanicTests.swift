import CResvg
import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing

/// Actual renderer calls without SVGContent's screens: all five panic families from #186,
/// and the zero-length repeating gradient. A regression ends this isolated test process.
final class SVGRendererPanicTests: XCTestCase {
    private struct Input: Sendable {
        let name: String
        let body: String
        var canvas = "0 0 100 100"
    }
    private static var inputs: [Input] {
        let png = RichMediaImages.solid(width: 40, height: 20).base64EncodedString()
        let mask = "<mask id='m'><rect width='100' height='100' fill='white'/></mask>"
        return [
            Input(name: "image fit", body: "<rect width='1' height='1'/><image width='1' height='100000000' href='data:image/png;base64,\(png)'/>", canvas: "0 0 10 10"),
            Input(name: "mask rounding", body: "<mask id='m' x='0.25' width='0.5'><rect width='100' height='100' fill='white'/></mask><path d='M 200 0 L 200.00002 50' stroke='black' mask='url(#m)'/>", canvas: "0 0 400 100"),
            Input(name: "mask far box", body: "<mask id='m' width='0.01'><rect width='100' height='100' fill='white'/></mask><rect x='1000000' width='1' height='1' mask='url(#m)'/>", canvas: "0 0 4000000 4000000"),
            Input(name: "marker overflow", body: "<marker id='k' viewBox='0 0 10 10' markerWidth='1e30' markerHeight='1e30'><path d='M0 0L10 5L0 10z'/></marker><path d='M10 10L50 50L90 10' fill='none' stroke='black' marker-mid='url(#k)' stroke-width='1e30'/>") ,
            Input(name: "marker underflow", body: "<marker id='k' viewBox='0 0 10 10' markerWidth='1e-30' markerHeight='1e-30'><path d='M0 0L10 5L0 10z'/></marker><path d='M10 10L50 50L90 10' fill='none' stroke='black' marker-mid='url(#k)' stroke-width='1e-30'/>") ,
            Input(name: "float bounds", body: mask + "<g mask='url(#m)'>" + String(repeating: "<g transform='scale(1e9)'>", count: 4) + "<rect width='300' height='1'/>" + String(repeating: "</g>", count: 5)),
            Input(name: "float curve", body: "<path d='M0 0 Q 1e20 1e20 3e20 1e20' fill='none' stroke='black'/>") ,
            Input(name: "raster arc", body: "<path d='M5 5 a1e12 1e12 0 1 0 0 1e12 z'/>", canvas: "0 0 10 10"),
            Input(name: "raster circle", body: "<circle cx='5' cy='5' r='1e7'/>", canvas: "0 0 10 10"),
            Input(name: "zero-length repeating gradient", body: "<linearGradient id='g' x1='0' x2='0' spreadMethod='repeat'><stop offset='0.07' stop-color='#fff'/><stop offset='0.29' stop-color='#fff'/><stop offset='1' stop-color='#fff'/></linearGradient><rect width='50' height='50' fill='url(#g)'/>") ,
        ]
    }

    private static func svg(_ input: Input, title: String = "Fallback") -> String {
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='\(input.canvas)'><title>\(title)</title>\(input.body)</svg>"
    }

    private static func rawParse(_ bytes: Data, options: OpaquePointer) -> (Int32, OpaquePointer?) {
        var tree: OpaquePointer?
        let status = bytes.withUnsafeBytes {
            resvg_parse_tree_from_data($0.baseAddress!.assumingMemoryBound(to: CChar.self), UInt($0.count), options, &tree)
        }
        return (status, tree)
    }

    private static func rawRender(_ tree: OpaquePointer, dimension: Int) -> Bool {
        let size = resvg_get_image_size(tree)
        guard size.width > 0, size.height > 0 else { return false }
        let scale = Float(dimension) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded(.down)))
        let height = max(1, Int((size.height * scale).rounded(.down)))
        var transform = resvg_transform_identity()
        transform.a = scale; transform.d = scale
        var pixels = Data(count: width * height * 4)
        return pixels.withUnsafeMutableBytes {
            resvg_render_checked(tree, transform, UInt32(width), UInt32(height), $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private static let ordinary = Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='16' height='16' fill='red'/></svg>".utf8)

    /// Raw C parse/render fail and then the same options render an unrelated ordinary tree.
    private static func exercise(_ input: Input) throws {
        let options = try XCTUnwrap(resvg_options_create())
        defer { resvg_options_destroy(options) }
        let (status, parsed) = rawParse(Data(svg(input).utf8), options: options)
        if let tree = parsed {
            defer { resvg_tree_destroy(tree) }
            XCTAssertEqual(status, 0, input.name)
            XCTAssertFalse(rawRender(tree, dimension: 4096), input.name)
            // A panic consumes the renderer state, keeping only the stable opaque handle.
            XCTAssertTrue(resvg_is_image_empty(tree), input.name)
            XCTAssertEqual(resvg_get_image_size(tree).width, 0, input.name)
            var bbox = resvg_rect(x: 0, y: 0, width: 0, height: 0)
            XCTAssertFalse(resvg_get_image_bbox(tree, &bbox), input.name)
            XCTAssertFalse(resvg_get_object_bbox(tree, &bbox), input.name)
            XCTAssertFalse(rawRender(tree, dimension: 16), "A failed tree cannot be reused: \(input.name)")
        } else {
            XCTAssertNotEqual(status, 0, input.name)
        }
        let (nextStatus, next) = rawParse(ordinary, options: options)
        let nextTree = try XCTUnwrap(next, input.name)
        defer { resvg_tree_destroy(nextTree) }
        XCTAssertEqual(nextStatus, 0, input.name)
        XCTAssertTrue(rawRender(nextTree, dimension: 16), "Next drawing: \(input.name)")
    }

    func testEveryKnownPanicIsContainedWithoutSwiftScreeningAndTheNextDrawingRenders() throws {
        for input in Self.inputs { try Self.exercise(input) }
    }

    func testKnownPanicsShowSectionFallbackAndDiscloseUnsupportedSVG() throws {
        for input in Self.inputs {
            let text = try RichMediaBook(body: "<p>\(Self.svg(input))</p>").build()
            XCTAssertTrue(text.richMediaImages.isEmpty, input.name)
            XCTAssertEqual(text.richMediaPlain, "Fallback", input.name)
            XCTAssertEqual(text.report.unsupportedElements["svg"], 1, input.name)
        }
    }

    func testCaughtPanicsDoNotAffectConcurrentUnrelatedDrawings() {
        let inputs = Self.inputs
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            for input in inputs where index == 0 {
                do { try Self.exercise(input) } catch { XCTFail("\(input.name): \(error)") }
            }
            for _ in 0..<20 {
                let options = resvg_options_create()!
                let (_, parsed) = Self.rawParse(Self.ordinary, options: options)
                if let tree = parsed {
                    XCTAssertTrue(Self.rawRender(tree, dimension: 16))
                    resvg_tree_destroy(tree)
                } else { XCTFail("Unrelated drawing refused") }
                resvg_options_destroy(options)
            }
        }
    }

    func testReadableAlternativeBitmapForALaterRasterFailure() throws {
        // Within tiny-skia's coordinate reach at the initial 64-pixel raster, but outside
        // it when the inspector asks for 4096. The checked draw must still contain it.
        let text = try RichMediaBook(body: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><text x='1' y='5' font-size='2'>Diagram unavailable</text><circle cx='5' cy='5' r='100000'/></svg>").build()
        let image = try XCTUnwrap(text.richMediaImages.first)
        XCTAssertNotNil(image.cache.image(for: image.source, maxPixelSize: 64))
        XCTAssertNil(image.source.decode(maxPixelSize: 4096))
        XCTAssertTrue(image.source.hasFailedSVGRendering)
        XCTAssertNil(image.cache.image(for: image.source, maxPixelSize: 64), "Discard earlier successful cached sizes after failure")
        let fallback = try XCTUnwrap(image.bitmap(for: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2))
        let pixels = try XCTUnwrap(fallback.dataProvider?.data as Data?)
        XCTAssertGreaterThan(pixels.enumerated().filter { $0.offset % 4 == 3 && $0.element != 0 }.count, 100,
                             "The failure alternative paints visible glyphs")
        XCTAssertEqual(image.textEquivalent, "Diagram unavailable", "Preserve text labels even without title or desc")
        let short = try XCTUnwrap(image.fallbackBitmap(size: CGSize(width: 200, height: 3), scale: 2))
        let shortPixels = try XCTUnwrap(short.dataProvider?.data as Data?)
        XCTAssertTrue(shortPixels.enumerated().contains { $0.offset % 4 == 3 && $0.element != 0 }, "A short frame still fits fallback glyphs")
        #if os(iOS)
        XCTAssertEqual(image.accessibilityLabel, "Diagram unavailable")
        #endif
    }
}
