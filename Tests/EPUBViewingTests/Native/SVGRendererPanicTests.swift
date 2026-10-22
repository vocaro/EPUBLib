import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#endif

/// What a reader shows for all five panic families from #186 and the zero-length repeating
/// gradient: their fallback, at once or after a later draw fails. The raw renderer calls without
/// the screens are StaticSVG's `SVGRendererPanicTests`.
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
