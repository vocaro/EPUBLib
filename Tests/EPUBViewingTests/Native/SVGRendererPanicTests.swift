import CResvg
import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#endif

/// Actual renderer calls without SVGContent's screens: all five panic families from #186,
/// and the zero-length repeating gradient. A regression ends this isolated test process.
final class SVGRendererPanicTests: XCTestCase {
    private struct Input: Sendable {
        let name: String
        let body: String
        var canvas = "0 0 100 100"
        var failsInitialRaster = true
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
            Input(name: "raster circle", body: "<circle cx='5' cy='5' r='1e7'/>", canvas: "0 0 10 10", failsInitialRaster: false),
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
    private static func exercise(_ input: Input, dimension: Int = 4096) throws {
        let options = try XCTUnwrap(resvg_options_create())
        defer { resvg_options_destroy(options) }
        let drawing = svg(input).replacingOccurrences(of: "</svg>", with: "<rect id='probe' width='1' height='1'/></svg>")
        let (status, parsed) = rawParse(Data(drawing.utf8), options: options)
        if let tree = parsed {
            defer { resvg_tree_destroy(tree) }
            XCTAssertEqual(status, 0, input.name)
            var beforeBox = resvg_rect(x: 0, y: 0, width: 0, height: 0)
            var beforeTransform = resvg_transform_identity()
            "probe".withCString { node in
                XCTAssertTrue(resvg_node_exists(tree, node), input.name)
                XCTAssertTrue(resvg_get_node_transform(tree, node, &beforeTransform), input.name)
                XCTAssertTrue(resvg_get_node_bbox(tree, node, &beforeBox), input.name)
                XCTAssertTrue(resvg_get_node_stroke_bbox(tree, node, &beforeBox), input.name)
            }
            let shouldFail = input.failsInitialRaster || dimension != 64
            XCTAssertEqual(rawRender(tree, dimension: dimension), !shouldFail, "\(input.name) at \(dimension) pixels")
            if shouldFail {
                // A panic consumes the renderer state, keeping only the stable opaque handle.
                XCTAssertTrue(resvg_is_image_empty(tree), input.name)
                XCTAssertEqual(resvg_get_image_size(tree).width, 0, input.name)
                var bbox = resvg_rect(x: 0, y: 0, width: 0, height: 0)
                XCTAssertFalse(resvg_get_image_bbox(tree, &bbox), input.name)
                XCTAssertFalse(resvg_get_object_bbox(tree, &bbox), input.name)
                var transform = resvg_transform_identity()
                "probe".withCString { node in
                    XCTAssertFalse(resvg_node_exists(tree, node), input.name)
                    XCTAssertFalse(resvg_get_node_transform(tree, node, &transform), input.name)
                    XCTAssertFalse(resvg_get_node_bbox(tree, node, &bbox), input.name)
                    XCTAssertFalse(resvg_get_node_stroke_bbox(tree, node, &bbox), input.name)
                }
                XCTAssertFalse(rawRender(tree, dimension: 16), "A failed tree cannot be reused: \(input.name)")
            } else {
                XCTAssertFalse(resvg_is_image_empty(tree), "The small-raster neighbour remains usable")
                XCTAssertTrue(rawRender(tree, dimension: 64), input.name)
            }
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
        for input in Self.inputs { for dimension in [64, 4096] { try Self.exercise(input, dimension: dimension) } }
    }

    func testKnownPanicsShowInitialOrLaterFallbackWithoutAbort() throws {
        for input in Self.inputs {
            let png = RichMediaImages.solid(width: 40, height: 20)
            let drawing = Self.svg(input).replacingOccurrences(of: "data:image/png;base64,\(png.base64EncodedString())", with: "w.png")
            let text = try RichMediaBook(body: "<p>\(drawing)</p>", files: ["w.png": png]).build()
            if !input.failsInitialRaster {
                let image = try XCTUnwrap(text.richMediaImages.first, input.name)
                XCTAssertNil(image.source.decode(maxPixelSize: 4096), input.name)
                XCTAssertEqual(image.textEquivalent, "Fallback", input.name)
                XCTAssertNil(text.report.unsupportedElements["svg"], "A later failure cannot change the immutable section report")
                continue
            }
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

    func testRefreshingCellAttachmentWordsPreservesCompleteTokenOwnership() throws {
        let section = try RichMediaBook(body: "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 10 10'><text x='1' y='5' font-size='2'>Retained diagram words</text><circle cx='5' cy='5' r='1e7'/></svg>").build()
        let image = try XCTUnwrap(section.richMediaImages.first)
        let word = "supercalifragilisticexpialidocious"
        let text = NSMutableAttributedString(attributedString: CanvasText.body(word + " "))
        text.append(NSAttributedString(attachment: image))
        text.append(CanvasText.body(" tail"))
        let layout = TableCellLayout(text, width: 40, viewportHeight: 200)
        let first = try XCTUnwrap(layout.lines.first?.characters)
        XCTAssertLessThan(first.upperBound, word.utf16.count, "The first line ends inside a word")
        let rest = NSRange(location: first.upperBound, length: text.length - first.upperBound)
        XCTAssertEqual(layout.spokenText(in: first), word)
        XCTAssertEqual(layout.spokenText(in: rest), "tail")
        XCTAssertNil(image.source.decode(maxPixelSize: 4096))
        XCTAssertEqual(layout.spokenText(in: first, refreshingAttachments: true), word, "The slice that starts a word still speaks it whole")
        XCTAssertEqual(layout.spokenText(in: rest, refreshingAttachments: true), "Retained diagram words tail", "Later slices speak the current attachment without repeating a clipped word")
    }

    func testReadableAlternativeBitmapForALaterRasterFailure() throws {
        // This circle draws at the initial 64-pixel raster but panics when the inspector
        // asks for 4096. Each checked draw independently contains that failure.
        let text = try RichMediaBook(body: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><text x='1' y='5' font-size='2'>Diagram unavailable</text><circle cx='5' cy='5' r='1e7'/></svg>").build()
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

#if os(iOS)
extension SVGRendererPanicTests {
    @MainActor func testCachedDataTableCellReadsItsWordsBesideLaterFailureWords() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let text = try RichMediaBook(body: "<table border='1'><tr><td>Before <svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 10 10'><text x='1' y='5' font-size='2'>Retained diagram words</text><circle cx='5' cy='5' r='1e7'/></svg> after.</td><td>Other cell.</td></tr></table>").build()
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = flow
            let host = CanvasHost(FakeCanvasSource([text.string]), configuration: configuration)
            defer { host.close() }
            host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut()
            let view = try XCTUnwrap(flow == .scrolled ? host.canvas.scrollTextView : host.canvas.textViews.first)
            let listed = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
            let table = try XCTUnwrap(listed.first { $0 is UIAccessibilityContainerDataTable })
            let cells = try XCTUnwrap(table.accessibilityElements as? [UIAccessibilityElement])
            let item = try XCTUnwrap(cells.first { $0.accessibilityLabel == "Before after." })
            let cellView = try XCTUnwrap(view.tableInteraction?.cells.values.first { $0.cellText.string.hasPrefix("Before") })
            var retainedImage: ReaderImageAttachment?
            cellView.cellText.enumerateAttribute(.attachment, in: cellView.shownCharacters) { value, _, _ in
                if let image = value as? ReaderImageAttachment { retainedImage = image }
            }
            let image = try XCTUnwrap(retainedImage)
            XCTAssertNil(image.source.decode(maxPixelSize: 4096))
            XCTAssertEqual(item.accessibilityLabel, "Before Retained diagram words after.", "The cached cell reads its words and the failure alternative in order")
            XCTAssertEqual(cells.last?.accessibilityLabel, "Other cell.")
            view.tableInteraction?.removeViews()
            XCTAssertEqual(item.accessibilityLabel, "Before Retained diagram words after.", "Retained fragments keep their words after mounted views are removed")
            let retainedTable = try XCTUnwrap((view.accessibilityElements as? [UIAccessibilityElement])?.first { $0 === table })
            XCTAssertTrue((retainedTable.accessibilityElements as? [UIAccessibilityElement] ?? []).contains { $0 === item }, "The cell under the cursor is retained")
        }
    }

    @MainActor func testCachedPageAndScrollAccessibilityElementsReadLaterFailureWords() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let text = try RichMediaBook(body: "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 10 10'><text x='1' y='5' font-size='2'>Retained diagram words</text><circle cx='5' cy='5' r='1e7'/></svg>").build()
            let image = try XCTUnwrap(text.richMediaImages.first)
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = flow
            let host = CanvasHost(FakeCanvasSource([text.string]), configuration: configuration)
            defer { host.close() }
            host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut()
            let view = try XCTUnwrap(flow == .scrolled ? host.canvas.scrollTextView : host.canvas.textViews.first)
            let listed = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
            let item = try XCTUnwrap(listed.first { $0.accessibilityTraits.contains(.image) })
            XCTAssertNil(item.accessibilityLabel, "An unnamed image before its later render fails")
            XCTAssertNil(image.source.decode(maxPixelSize: 4096))
            XCTAssertEqual(item.accessibilityLabel, "Retained diagram words", "The cached element now reads the failure alternative")
            XCTAssertTrue((view.accessibilityElements as? [UIAccessibilityElement] ?? []).contains { $0 === item }, "The element under the cursor is retained")
        }
    }
}
#endif
