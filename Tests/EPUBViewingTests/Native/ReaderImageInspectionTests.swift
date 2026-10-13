import CoreGraphics
import EPUBCore
import EPUBReading
import ImageIO
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class ReaderImageInspectionTests: XCTestCase {
    private func pixels(width: Int = 2448, height: Int = 524) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 40, to: width - 40, by: 40) {
            context.fill(CGRect(x: x, y: 30, width: 8, height: height - 60))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func attachment(_ data: Data) throws -> ReaderImageAttachment {
        let source = try XCTUnwrap(ReaderImageSource.bitmap(data, path: "hashing.png", key: UUID().uuidString))
        var sizing = ImageSizing(intrinsic: source.pixelSize)
        sizing.width = .points(200)
        return ReaderImageAttachment(source: source, sizing: sizing, alternative: .text("Hashing example"),
            style: ComputedStyle(), cache: ReaderImageCache(budget: 96 << 20))
    }

    func testArchiveResolutionIsIndependentOfInlineCSSAndDecodeRemainsBounded() throws {
        let image = try attachment(pixels())
        let inline = try XCTUnwrap(image.bitmap(for: CGRect(x: 0, y: 0, width: 200, height: 43), scale: 1))
        XCTAssertLessThan(inline.width, 300)
        let inspected = try XCTUnwrap(ReaderImageInspection.bitmap(for: image))
        XCTAssertEqual(inspected.width, 2448)
        XCTAssertEqual(inspected.height, 524)
        XCTAssertEqual(image.source.data, try pixels())
        for size in [CGSize(width: 8192, height: 8192), CGSize(width: 20000, height: 1000), CGSize(width: 3000, height: 20000)] {
            let dimension = ReaderImageInspection.decodeDimension(for: size)
            XCTAssertLessThanOrEqual(dimension, ReaderImageInspection.maximumDimension)
            let scale = CGFloat(dimension) / max(size.width, size.height)
            XCTAssertLessThanOrEqual(Int(ceil(size.width * scale) * ceil(size.height * scale)), ReaderImageInspection.maximumPixels)
        }
    }

    func testInspectionZoomHitDiscoveryAndClosePreserveReaderStateInBothFlows() async throws {
        let image = try attachment(pixels())
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Before the example.\n"))
        let position = text.length
        text.append(NSAttributedString(attachment: image, attributes: CanvasText.body("a").attributes(at: 0, effectiveRange: nil)))
        text.append(CanvasText.body("\nAfter the example."))
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            var configuration = ReaderCanvasConfiguration(); configuration.flow = flow
            let source = FakeCanvasSource([text]); source.book = CanvasText.book([text])
            let host = CanvasHost(source, size: flow == .paginated ? CGSize(width: 320, height: 700) : CGSize(width: 800, height: 600), configuration: configuration)
            defer { host.close() }
            host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut(); try await host.settle(100)
            let view = try XCTUnwrap(host.canvas.textViews.first)
            let frame = try XCTUnwrap(view.segmentFrames(for: NSRange(location: position, length: 1)).first)
            XCTAssertTrue(view.image(at: CGPoint(x: frame.midX + view.containerOrigin.x, y: frame.midY + view.containerOrigin.y)) === image)
            XCTAssertNil(view.image(at: CGPoint(x: -50, y: -50)))
            #if os(macOS)
            let spoken = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: position, length: 1)))
            let element = try XCTUnwrap(spoken.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil) as? NSAccessibilityElement)
            XCTAssertEqual(element.accessibilityCustomActions()?.first?.name, "Inspect Image: Hashing example")
            #else
            // The image's own element offers it, and the text view, whose actions VoiceOver
            // would offer on every line, does not.
            let listed = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
            XCTAssertEqual(listed.filter { $0.accessibilityCustomActions?.contains { $0.name == "Inspect Image: Hashing example" } == true }
                .map(\.accessibilityLabel), ["Hashing example"])
            XCTAssertNil(view.accessibilityCustomActions)
            #endif
            view.selectedRange = NSRange(location: 0, length: 6)
            #if os(macOS)
            host.window.makeFirstResponder(view)
            #else
            view.becomeFirstResponder()
            #endif
            let selection = view.selectedRange, anchor = host.canvas.anchor, visible = host.canvas.visibleRange
            host.canvas.inspectImage(image)
            let inspector = try XCTUnwrap(host.canvas.imageInspector)
            #if os(macOS)
            XCTAssertTrue(view.isAccessibilityHidden())
            #else
            XCTAssertTrue(inspector.accessibilityViewIsModal)
            #endif
            let fitted: CGFloat
            #if os(macOS)
            fitted = inspector.scrollView.magnification
            #else
            fitted = inspector.scrollView.zoomScale
            #endif
            try snapshot(inspector, name: "fixture-\(flow)-fitted")
            inspector.zoomIn(); inspector.zoomIn()
            try snapshot(inspector, name: "fixture-\(flow)-zoomed")
            #if os(macOS)
            XCTAssertGreaterThan(inspector.scrollView.magnification, fitted * 3)
            #else
            XCTAssertGreaterThan(inspector.scrollView.zoomScale, fitted * 3)
            #endif
            XCTAssertEqual(host.canvas.anchor, anchor)
            XCTAssertEqual(host.canvas.visibleRange, visible)
            XCTAssertNil(host.canvas.edgeTurn(at: CGPoint(x: 0, y: 200)))
            inspector.fit()
            #if os(macOS)
            XCTAssertEqual(inspector.scrollView.magnification, fitted, accuracy: 0.0001)
            #else
            XCTAssertEqual(inspector.scrollView.zoomScale, fitted, accuracy: 0.0001)
            #endif
            inspector.close()
            XCTAssertNil(host.canvas.imageInspector)
            XCTAssertEqual(view.selectedRange, selection)
            #if os(macOS)
            XCTAssertTrue(host.window.firstResponder === view)
            XCTAssertFalse(view.isAccessibilityHidden())
            #else
            XCTAssertTrue(view.isFirstResponder)
            #endif
            XCTAssertEqual(host.canvas.anchor, anchor)
        }
    }

    func testInspectionDoesNotRetainAReaderAfterItsHostCloses() async throws {
        let image = try attachment(pixels(width: 120, height: 40))
        weak var canvas: ReaderCanvasView?
        weak var inspector: ReaderImageInspector?
        var host: CanvasHost? = CanvasHost(FakeCanvasSource([CanvasText.body("Reader")]))
        canvas = host?.canvas
        #if os(macOS)
        host?.window.makeFirstResponder(host?.canvas)
        #else
        host?.canvas.becomeFirstResponder()
        #endif
        host?.canvas.inspectImage(image)
        try await host?.settle(300)
        inspector = host?.canvas.imageInspector
        XCTAssertNotNil(inspector)
        host?.close()
        host = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(canvas)
        XCTAssertNil(inspector)
    }

    func testTableCellImageHitUsesItsDrawnFrame() throws {
        let fixture = try RichFixture("<table id='t'><tr><th>Example</th><th>Label</th></tr><tr><td>Before <img src='image.png' alt='Formula'/> after</td><td>Formula example</td></tr></table>", files: ["image.png": pixels(width: 120, height: 40)])
        let row = try XCTUnwrap(RichFixture.attachments(in: fixture.table("t")).last as? TableRowAttachment)
        let height = row.height(width: 400, viewportHeight: 600)
        let regions = row.images(size: CGSize(width: 400, height: height), viewportHeight: 600)
        let image = try XCTUnwrap(regions.first)
        XCTAssertEqual(image.image.alt, "Formula")
        XCTAssertTrue(row.image(at: CGPoint(x: image.frame.midX, y: image.frame.midY), size: CGSize(width: 400, height: height), viewportHeight: 600) === image.image)
        XCTAssertNil(row.image(at: CGPoint(x: -1, y: -1), size: CGSize(width: 400, height: height), viewportHeight: 600))
    }

    func testExactHashingImageInspectionWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBLIB_IMAGE_INSPECTION_REPRODUCER"] else {
            throw XCTSkip("Set EPUBLIB_IMAGE_INSPECTION_REPRODUCER for the original #35 hashing image")
        }
        let publication = try EPUBPublication.open(at: URL(fileURLWithPath: path))
        let data = try publication.data(at: "EPUB/assets/image116-1.png")
        let image = try attachment(data)
        XCTAssertEqual(image.source.pixelSize, CGSize(width: 2448, height: 524))
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Hashes the key 137\n"))
        text.append(NSAttributedString(attachment: image)); text.append(CanvasText.body("\nFigure 7.1"))
        let host = CanvasHost(FakeCanvasSource([text]), size: CGSize(width: 800, height: 600))
        defer { host.close() }
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut(); try await host.settle(100)
        host.canvas.inspectImage(image)
        let inspector = try XCTUnwrap(host.canvas.imageInspector)
        try snapshot(inspector, name: "fitted")
        inspector.zoomIn(); inspector.zoomIn()
        try snapshot(inspector, name: "zoomed")
    }

    private func snapshot(_ inspector: ReaderImageInspector, name: String) throws {
        let image: CGImage
        #if os(macOS)
        inspector.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds))
        inspector.cacheDisplay(in: inspector.bounds, to: bitmap)
        image = try XCTUnwrap(bitmap.cgImage)
        #else
        inspector.layoutIfNeeded()
        func display(_ layer: CALayer) { layer.displayIfNeeded(); layer.sublayers?.forEach(display) }
        display(inspector.layer)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        image = try XCTUnwrap(UIGraphicsImageRenderer(bounds: inspector.bounds, format: format).image {
            inspector.layer.render(in: $0.cgContext)
        }.cgImage)
        #endif
        #if os(macOS)
        let directory = "/private/tmp"
        #else
        let directory = NSTemporaryDirectory()
        #endif
        let output = URL(fileURLWithPath: directory).appendingPathComponent("epublib-hashing-inspector-\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = XCTAttachment(contentsOfFile: output)
        attachment.name = "Image inspector \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
