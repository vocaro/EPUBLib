import CoreGraphics
import EPUBCore
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Formulas in the reader's own TextKit 2 canvas, in a phone-width column: wide ones break into
/// rows inside the column, block formulas keep their own paragraph, inline ones their line, a
/// page keeps a formula whole, and each formula's reading reaches accessibility with its language.
@MainActor final class MathCanvasTests: XCTestCase {
    private typealias F = MathFixtures

    private struct Placed {
        let attachment: MathAttachment
        /// The attachment's box, in its text view's container coordinates.
        let box: CGRect
        /// The line fragment holding it.
        let line: CGRect
        let offset: Int
        let view: ReaderTextView
    }

    private var hosts: [CanvasHost] = []
    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private func host(_ body: String, fontSize: CGFloat = 16, flow: EPUBReadingFlow = .paginated,
                      size: CGSize = CGSize(width: 340, height: 700), root: String = "") async throws -> CanvasHost {
        let text = try BuilderHarness.build(body, rootAttributes: root, rich: NativeRichContent(),
                                            rules: [("body", { $0.fontSize = fontSize })])
        XCTAssertEqual(text.report.mathFallbacks, 0)
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = flow
        let host = CanvasHost(FakeCanvasSource([text.string]), size: size, configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        try await host.settle(150)
        return host
    }

    /// Every formula the canvas's views show, in order.
    private func formulas(in canvas: ReaderCanvasView) throws -> [Placed] {
        var found: [Placed] = []
        for view in canvas.textViews {
            let layoutManager = try XCTUnwrap(view.textLayoutManager)
            let shown = view.isPageColumn ? view.shownCharacters.length : Int.max
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame
                for line in fragment.textLineFragments {
                    line.attributedString.enumerateAttribute(.attachment, in: line.characterRange) { value, range, _ in
                        guard let formula = value as? MathAttachment,
                              let location = layoutManager.location(fragment.rangeInElement.location, offsetBy: range.location) else { return }
                        let offset = view.offset(of: location)
                        guard offset < shown else { return }
                        let box = fragment.frameForTextAttachment(at: location).offsetBy(dx: frame.minX, dy: frame.minY)
                        guard box.width > 0.01, box.height > 0.01 else { return }
                        found.append(Placed(attachment: formula, box: box, line: line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY),
                                            offset: offset, view: view))
                    }
                }
                return true
            }
        }
        return found
    }

    private func columnWidth(_ view: ReaderTextView) throws -> CGFloat {
        try XCTUnwrap(view.textLayoutManager?.textContainer).size.width
    }

    /// The canvas drawn into a bitmap, top-left origin.
    private func snapshot(_ canvas: ReaderCanvasView) -> CGImage? {
        #if os(macOS)
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        return bitmap.cgImage
        #else
        func display(_ layer: CALayer) { layer.displayIfNeeded(); layer.sublayers?.forEach(display) }
        display(canvas.layer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: canvas.bounds, format: format).image { context in
            canvas.layer.render(in: context.cgContext)
        }.cgImage
        #endif
    }

    /// The ink in `rect` (canvas points, top-left origin): its horizontal extent in points and
    /// the bands of consecutive inked pixel rows, each a row of the formula.
    private func ink(_ image: CGImage, in rect: CGRect, canvas: ReaderCanvasView) -> (bands: Int, left: CGFloat, right: CGFloat)? {
        let scale = CGFloat(image.width) / canvas.bounds.width
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -rect.minX * scale, y: -(CGFloat(image.height) - rect.maxY * scale),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var bands = 0, blank = Int.max / 2, left = width, right = -1
        for row in 0..<height {
            var inked = false
            for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 128 && Int(pixels[(row * width + column) * 4]) < 110 {
                inked = true
                left = min(left, column); right = max(right, column)
            }
            if inked {
                // Rows of a formula are at least two-fifths of an em apart; a gap of a pixel or two is within one.
                if blank >= Int(3 * scale) { bands += 1 }
                blank = 0
            } else { blank += 1 }
        }
        return right < 0 ? nil : (bands, CGFloat(left) / scale, CGFloat(right + 1) / scale)
    }

    private func areaInCanvas(_ placed: Placed, canvas: ReaderCanvasView) -> CGRect {
        let origin = placed.view.containerOrigin
        return placed.view.convert(placed.box.offsetBy(dx: origin.x, dy: origin.y), to: canvas)
    }

    func testWideDisplayFormulaIsDrawnAsRowsWithinTheColumn() async throws {
        let body = "<p>Lead paragraph.</p>\(F.polynomial.markup)<p>After the formula the text goes on.</p>"
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            for fontSize in [CGFloat(16), 28] {
                let host = try await host(body, fontSize: fontSize, flow: flow)
                let placed = try XCTUnwrap(try formulas(in: host.canvas).first, "\(flow) \(fontSize)")
                let column = try columnWidth(placed.view)
                XCTAssertLessThan(column, 340)
                let formula = placed.attachment.formula
                XCTAssertLessThan(column / formula.layout.width, 0.5, "one row would be under half size")
                let rows = formula.arrangement(fitting: column)
                XCTAssertGreaterThan(rows.rows.count, 2)
                // Full size, inside the column, at the bounds its attachment gives.
                XCTAssertLessThanOrEqual(placed.box.maxX, column + 0.5, "\(flow) \(fontSize)")
                XCTAssertGreaterThanOrEqual(placed.box.minX, -0.5)
                XCTAssertEqual(placed.box.width, rows.width, accuracy: 0.6, "\(flow) \(fontSize)")
                XCTAssertEqual(placed.box.height, rows.height + 2 * 0.15 * fontSize, accuracy: 0.6, "\(flow) \(fontSize)")
                XCTAssertEqual(placed.box.midX, column / 2, accuracy: 1, "a display formula is centred as a whole")
                // Its own paragraph, clear of the text before and after.
                let storage = try XCTUnwrap(placed.view.contentStorage.textStorage)
                let before = try XCTUnwrap(placed.view.lineFrame(containing: 0))
                let after = try XCTUnwrap(placed.view.lineFrame(containing: (storage.string as NSString).range(of: "After the formula").location))
                XCTAssertLessThanOrEqual(before.maxY, placed.box.minY + 0.5)
                XCTAssertGreaterThanOrEqual(after.minY, placed.box.maxY - 0.5)
                // What is drawn is those rows, not one row squeezed into their box.
                let image = try XCTUnwrap(snapshot(host.canvas))
                let extent = try XCTUnwrap(ink(image, in: areaInCanvas(placed, canvas: host.canvas), canvas: host.canvas), "\(flow) \(fontSize)")
                // The engine uses the font's MATH leading, which can leave less than the
                // old fixed three-point gap between rows at phone text sizes. Check ink in
                // each actual engine row box instead of inferring rows from that old gap.
                let area = areaInCanvas(placed, canvas: host.canvas)
                for (index, row) in rows.rows.enumerated() {
                    let rowArea = CGRect(x: area.minX + row.x,
                                         y: area.minY + 0.15 * fontSize + row.baseline - row.layout.ascent,
                                         width: row.layout.width, height: row.layout.ascent + row.layout.descent)
                    XCTAssertNotNil(ink(image, in: rowArea, canvas: host.canvas), "row \(index) \(flow) \(fontSize)")
                }
                XCTAssertLessThan(extent.left, fontSize * 0.5, "the first row starts at the left edge")
                XCTAssertGreaterThan(extent.right, placed.box.width - fontSize * 0.5, "the widest row reaches the right edge")
            }
        }
    }

    func testInlineFormulasKeepTheirLineUntilTheyAreWiderThanIt() async throws {
        let body = "<p>Short ones such as \(F.inlineShort.markup) sit in the text, and a long sum such as \(F.inlineSeries.markup) breaks where the line ends, after which the sentence goes on for a while.</p>"
        for fontSize in [CGFloat(16), 28] {
            let host = try await host(body, fontSize: fontSize)
            let placed = try formulas(in: host.canvas)
            XCTAssertGreaterThan(placed.count, 2)
            let column = try columnWidth(placed[0].view)
            // The short formula is one row at its natural size, on a line it shares with words.
            let short = placed[0]
            XCTAssertEqual(short.box.size.width, short.attachment.layout.width, accuracy: 0.6)
            XCTAssertEqual(short.box.height, short.attachment.bounds(lineWidth: 0, height: 0).height, accuracy: 0.6)
            XCTAssertLessThan(short.box.height, fontSize * 1.6)
            XCTAssertGreaterThan(short.line.width, short.box.width + fontSize * 2, "words share its line")
            // Its baseline is the line's: the box's bottom is the formula's descent below it.
            let layoutManager = try XCTUnwrap(short.view.textLayoutManager)
            let location = try XCTUnwrap(short.view.textRange(for: NSRange(location: short.offset, length: 1))?.location)
            let fragment = try XCTUnwrap(layoutManager.textLayoutFragment(for: location))
            let line = try XCTUnwrap(fragment.textLineFragments.first { NSLocationInRange(short.offset - short.view.offset(of: fragment.rangeInElement.location), $0.characterRange) })
            let baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            XCTAssertEqual(short.box.maxY - baseline, short.attachment.layout.descent + short.attachment.clearance.bottom, accuracy: 0.6)
            // The long formula's engine rows occupy consecutive text lines, with the
            // sentence sharing the first and last rather than one tall attachment line.
            let long = Array(placed.dropFirst())
            XCTAssertGreaterThan(long.count, 1)
            for row in long {
                XCTAssertLessThanOrEqual(row.box.maxX, column + 0.5)
                XCTAssertLessThan(row.box.height, fontSize * 2)
            }
            for (above, below) in zip(long, long.dropFirst()) {
                XCTAssertGreaterThan(below.box.minY, above.box.minY)
                XCTAssertLessThanOrEqual(above.box.maxY, below.box.minY + 0.5)
            }
            if fontSize == 16 { XCTAssertGreaterThan(long[0].box.minX, 0, "the first row uses the space left after text") }
            XCTAssertGreaterThan(long.last!.line.width, long.last!.box.width + fontSize, "the sentence continues on the last formula row")
        }
    }

    func testAnUnbreakableNumberFillsTheColumnAndIsDisclosed() async throws {
        let markup = F.math(F.n(String(repeating: "1", count: 100)), attributes: "display='block'")
        let text = try BuilderHarness.build(markup, rich: NativeRichContent(), rules: [("body", { $0.fontSize = 28 })])
        XCTAssertEqual(text.report.mathReductions, 1)
        XCTAssertEqual(NativeDisclosure.text(for: text.report), "One wide formula is reduced in size on narrow pages.")
        let host = try await host(markup, fontSize: 28)
        let placed = try XCTUnwrap(try formulas(in: host.canvas).first)
        let column = try columnWidth(placed.view)
        XCTAssertEqual(placed.box.width, column, accuracy: 0.6)
    }

    func testAPageKeepsABrokenFormulaWhole() async throws {
        // Enough text that the formula's rows cannot all follow it on the first page.
        let body = "<p>\(CanvasText.sentence(60, seed: 2))</p>\(F.polynomial.markup)<p>\(CanvasText.sentence(30, seed: 5))</p>"
        let host = try await host(body, fontSize: 22, size: CGSize(width: 340, height: 420))
        var found: Placed?
        for _ in 0..<6 {
            if let placed = try formulas(in: host.canvas).first { found = placed; break }
            guard host.canvas.turnPage(forward: true) == .turned else { break }
            host.layOut()
            try await host.settle(150)
        }
        let placed = try XCTUnwrap(found, "the formula is on some page")
        let rows = placed.attachment.formula.arrangement(fitting: try columnWidth(placed.view))
        XCTAssertGreaterThan(rows.rows.count, 2)
        let viewport = try XCTUnwrap(placed.view.textLayoutManager?.textContainer as? ReaderTextContainer).viewportSize
        XCTAssertGreaterThan(viewport.height, 0)
        XCTAssertGreaterThanOrEqual(placed.box.minY, -0.5)
        XCTAssertLessThanOrEqual(placed.box.maxY, viewport.height + 0.5, "every row is on the page that shows the formula")
        XCTAssertEqual(placed.box.height, rows.height + 2 * 0.15 * 22, accuracy: 0.6, "at full size: the page is tall enough")
    }

    func testInlineRowsKeepTheirSourceAndReadingAcrossPagesAndResize() async throws {
        let sum = (1...45).map { "<msub><mi>x</mi><mn>\($0)</mn></msub>" }.joined(separator: "<mo>+</mo>")
        let label = "the sum of forty-five terms"
        let body = "<p>Before \(F.math(sum, attributes: "alttext='\(label)'")) after the sum.</p>"
        let host = try await host(body, fontSize: 22, size: CGSize(width: 340, height: 190))
        let source = try XCTUnwrap(host.canvas.textViews.first?.contentStorage.textStorage).string
        var indices: [Int] = []
        var page = 0
        repeat {
            let placed = try formulas(in: host.canvas)
            if !placed.isEmpty {
                indices += placed.map(\.attachment.row)
                let visible = host.canvas.textViews.map(\.visibleText).joined()
                XCTAssertEqual(visible.components(separatedBy: label).count - 1, 1, "one reading on page \(page)")
                #if os(iOS)
                let labels = host.canvas.textViews.flatMap { ($0.accessibilityElements as? [UIAccessibilityElement] ?? []).compactMap(\.accessibilityLabel) }
                XCTAssertEqual(labels.filter { $0 == label }.count, 1, "one accessible formula on each continuation page")
                #else
                var readings: [String] = []
                for view in host.canvas.textViews {
                    let text = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
                    text.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                        if let element = value as? NSAccessibilityElement, let words = element.accessibilityLabel() { readings.append(words) }
                    }
                }
                XCTAssertEqual(readings.filter { $0 == label }.count, 1, "one accessible formula on each continuation page")
                // A client may ask for one continuation character rather than the whole
                // page. That query must not give the same formula a second image reading.
                for row in placed where row.offset > 0 && row.attachment.row > 0 {
                    let piece = try XCTUnwrap(row.view.accessibilityAttributedString(for: NSRange(location: row.offset, length: 1)))
                    XCTAssertNil(piece.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil))
                }
                #endif
            }
            page += 1
            guard host.canvas.turnPage(forward: true) == .turned else { break }
            host.layOut()
            try await host.settle(100)
        } while page < 12
        XCTAssertGreaterThan(page, 1)
        XCTAssertEqual(indices, Array(0..<indices.count), "every engine row is shown exactly once across page boundaries")
        XCTAssertGreaterThan(indices.count, 4)
        // The source character slots remain stable at another width; continuations do not
        // insert characters that would move bookmarks, search results or the following text.
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.canvas.frame.size.width = 480
        host.layOut()
        try await host.settle(100)
        let resized = try XCTUnwrap(host.canvas.textViews.first?.contentStorage.textStorage)
        XCTAssertTrue(source.hasPrefix(resized.string) || resized.string.hasPrefix(source))
        XCTAssertEqual(resized.readerPlainText().components(separatedBy: label).count - 1, 1)
    }

    func testInlineRowsDrawInkAfterTextAtEachWidth() async throws {
        let body = "<p>Before \(F.inlineSeries.markup) after.</p>"
        for width in [CGFloat(340), 460] {
            let host = try await host(body, flow: .scrolled, size: CGSize(width: width, height: 900))
            let placed = try formulas(in: host.canvas)
            XCTAssertGreaterThan(placed.count, 1)
            XCTAssertGreaterThan(placed[0].box.minX, 10, "the formula starts after Before")
            let image = try XCTUnwrap(snapshot(host.canvas))
            for row in placed {
                let pixels = try XCTUnwrap(ink(image, in: areaInCanvas(row, canvas: host.canvas), canvas: host.canvas), "row=\(row.attachment.row) box=\(row.box) width=\(width)")
                XCTAssertEqual(pixels.bands, 1)
                XCTAssertGreaterThan(pixels.right - pixels.left, 20)
            }
        }
    }

    func testReadingsReachAccessibilityWithTheirLanguage() async throws {
        let authored = F.math(F.fraction, attributes: "alttext=\"\(F.frenchAlttext)\"")
        let host = try await host("<p>Soit \(authored) et \(F.math(F.fraction)) deux fractions.</p>", root: "xml:lang=\"fr\"")
        let placed = try formulas(in: host.canvas)
        XCTAssertEqual(placed.map(\.attachment.label), [F.frenchAlttext, "début de fraction a sur b au carré fin de fraction"])
        XCTAssertEqual(placed.map(\.attachment.language), ["fr", "fr"])
        let view = placed[0].view
        XCTAssertEqual(view.visibleText, "Soit \(F.frenchAlttext) et \("début de fraction a sur b au carré fin de fraction") deux fractions.")
        #if os(macOS)
        let text = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        for formula in placed {
            let element = try XCTUnwrap(text.attribute(.accessibilityAttachment, at: formula.offset, effectiveRange: nil) as? NSAccessibilityElement)
            XCTAssertEqual(element.accessibilityLabel(), formula.attachment.label)
            XCTAssertEqual(text.attribute(.accessibilityLanguage, at: formula.offset, effectiveRange: nil) as? String, formula.attachment.language)
        }
        // AppKit reports the text's own language from its markup; the generated reading differs from it.
        XCTAssertEqual(text.attribute(.accessibilityLanguage, at: 0, effectiveRange: nil) as? String, "fr")
        #else
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        let images = elements.filter { $0.accessibilityTraits.contains(.image) }
        XCTAssertEqual(images.map(\.accessibilityLabel), [F.frenchAlttext, "début de fraction a sur b au carré fin de fraction"])
        XCTAssertEqual(images.map(\.accessibilityLanguage), ["fr", "fr"])
        // The words around them are in the text's own language (#65).
        XCTAssertEqual(Set(elements.filter { !$0.accessibilityTraits.contains(.image) }.map(\.accessibilityLanguage)), ["fr"])
        #endif
    }
}
