import CoreGraphics
import EPUBCore
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Rich attachments inside the reader's own canvas, paginated and scrolled.
@MainActor final class RichCanvasTests: XCTestCase {
    private func section(_ fixture: RichFixture) throws -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Before the table."))
        text.append(NSAttributedString(string: "\n"))
        text.append(try XCTUnwrap(fixture.table("t")))
        text.append(NSAttributedString(string: "\n"))
        text.append(CanvasText.body("After the table."))
        return text
    }

    /// The canvas drawn into a bitmap, top-left origin, 1 pixel per point.
    private func snapshot(_ canvas: ReaderCanvasView) -> CGImage? {
        #if os(macOS)
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        return bitmap.cgImage
        #else
        // The SwiftPM test runner has no screen to update, so draw the layers' own contents.
        func display(_ layer: CALayer) { layer.displayIfNeeded(); layer.sublayers?.forEach(display) }
        display(canvas.layer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: canvas.bounds, format: format).image { context in
            canvas.layer.render(in: context.cgContext)
        }.cgImage
        #endif
    }

    /// How many pixels of `rect` (points, top-left origin) are dark.
    private func ink(_ image: CGImage, in rect: CGRect, scale: CGFloat) -> Int {
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        // Draw the image so the rect's top-left pixel lands at the context's top-left.
        context.draw(image, in: CGRect(x: -rect.minX * scale, y: -(CGFloat(image.height) - rect.maxY * scale),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for index in 0..<(width * height) where pixels[index * 4 + 3] > 128 && Int(pixels[index * 4]) < 100 { count += 1 }
        return count
    }

    func testTablesDrawInsideTheCanvas() async throws {
        let fixture = try RichFixture("""
        <table id="t" border="1"><caption>QA table</caption><tr><th>Name</th><th>Value</th><th>Note</th></tr>
        <tr><td>Alpha</td><td>1</td><td>First</td></tr><tr><td>Beta</td><td>2</td><td>Second</td></tr></table>
        """)
        let text = try section(fixture)
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = flow
            let host = CanvasHost(FakeCanvasSource([text]), size: CGSize(width: 500, height: 700), configuration: configuration)
            defer { host.close() }
            host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut()
            try await host.settle(100)
            let view = try XCTUnwrap(host.canvas.textViews.first)
            let content = try XCTUnwrap(view.contentStorage.textStorage)
            var rows = NSRange(location: NSNotFound, length: 0)
            content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                guard value is TableRowAttachment else { return }
                rows = rows.location == NSNotFound ? range : NSUnionRange(rows, range)
            }
            XCTAssertNotEqual(rows.location, NSNotFound)
            let frame = view.segmentFrames(for: rows).reduce(CGRect.null) { $0.union($1) }
            let origin = view.containerOrigin
            let area = view.convert(frame.offsetBy(dx: origin.x, dy: origin.y), to: host.canvas)
            XCTAssertGreaterThan(area.height, 40, "\(flow)")
            let image = try XCTUnwrap(snapshot(host.canvas))
            let scale = CGFloat(image.width) / host.canvas.bounds.width
            XCTAssertGreaterThan(ink(image, in: area, scale: scale), 100, "The cells and rules are drawn (\(flow))")
        }
    }
}
