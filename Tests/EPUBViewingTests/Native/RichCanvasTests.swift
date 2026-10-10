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

    func testFloatAndUpwardPositionedTextDrawAsSelectableNativeGlyphs() async throws {
        let prose = Array(repeating: "Ordinary prose shares visual rows with the native boxes, then continues below them.", count: 6).joined(separator: " ")
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: """
            <p id="prefix">Leading paragraph before native boxes.</p>
            <figure id="float"><figcaption>FLOAT GLYPHS</figcaption></figure>
            <p>\(prose)</p>
            <aside id="callout">UPWARD GLYPHS</aside>
            <p>Trailing paragraph remains visible.</p>
            """, css: """
            body, p, figure, figcaption, aside { margin:0; padding:0; }
            p { text-indent:0; }
            figure { float:left; width:140px; height:96px; }
            aside { position:absolute; left:200px; top:24px; width:160px; height:64px; }
            """))
        let section = SectionBuilder.build(.init(publication: publication, spineIndex: 0,
            typography: .init(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = flow
            let source = FakeCanvasSource([section.string])
            if flow == .scrolled { source.book = CanvasText.book([section.string]) }
            let host = CanvasHost(source, size: CGSize(width: 500, height: 700), configuration: configuration)
            defer { host.close() }
            host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut()
            try await host.settle(100)
            let view = try XCTUnwrap(host.canvas.textViews.first)
            view.ensureFullLayout()
            let geometry = try XCTUnwrap(view.readerContainer.boxPage?.geometry)
            for phrase in ["FLOAT GLYPHS", "UPWARD GLYPHS"] {
                let sourceRange = (section.string.string as NSString).range(of: phrase)
                XCTAssertNotEqual(sourceRange.location, NSNotFound)
                let localRange = NSRange(location: sourceRange.location - view.placement.offset, length: sourceRange.length)
                let paragraph = try XCTUnwrap(geometry.paragraph(at: sourceRange.location))
                XCTAssertTrue(paragraph.isBox, "\(flow) \(phrase): the fixture must exercise native box layout")
                XCTAssertEqual(paragraph.flowStart, paragraph.flowEnd, accuracy: 0.01,
                               "\(flow) \(phrase): rendering must survive a box with zero flow advance")
                if phrase == "UPWARD GLYPHS" {
                    XCTAssertLessThan(paragraph.topAdjustment, -50, "The later DOM callout must draw above its flow cursor")
                }
                let frames = view.segmentFrames(for: localRange)
                XCTAssertFalse(frames.isEmpty)
                let origin = view.containerOrigin
                let image = try XCTUnwrap(snapshot(host.canvas))
                let scale = CGFloat(image.width) / host.canvas.bounds.width
                for frame in frames {
                    let area = view.convert(frame.offsetBy(dx: origin.x, dy: origin.y), to: host.canvas)
                    XCTAssertTrue(host.canvas.bounds.contains(area), "\(flow) \(phrase): glyphs must be inside the snapshot")
                    XCTAssertGreaterThan(ink(image, in: area, scale: scale), 40,
                                         "Native box glyphs must actually draw, even with zero flow height: \(flow) \(phrase)")
                }
                let storage = try XCTUnwrap(view.contentStorage.textStorage)
                var hasAttachment = false
                storage.enumerateAttribute(.attachment, in: localRange) { value, _, _ in
                    if value != nil { hasAttachment = true }
                }
                XCTAssertFalse(hasAttachment, "Box text must remain native glyphs rather than a raster attachment")
                let selection = ReaderTextRange(section: 0, sourceRange.location..<sourceRange.upperBound)
                host.canvas.show(selection.start, selecting: selection)
                host.layOut()
                try await host.settle(30)
                let selectedView = try XCTUnwrap(host.canvas.textViews.first)
                XCTAssertEqual(selectedView.plainText(in: selectedView.selectedRange), phrase,
                               "Rendered native box glyphs retain their exact selectable text")
            }
        }
    }

}
