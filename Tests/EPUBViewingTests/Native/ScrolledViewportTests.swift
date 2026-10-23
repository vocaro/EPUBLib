import EPUBCore
import EPUBReading
import CryptoKit
import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class ScrolledViewportTests: XCTestCase {
    /// An unchanged, opt-in publisher source exercises the production CSS builder and native
    /// SwiftUI host. Keep the source outside the repository; its CC BY attribution stays in it.
    func testOriginalNetworkingQuestionsResizeAndColdRestoreWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBLIB_SCROLL_CORPUS"] else {
            throw XCTSkip("Set EPUBLIB_SCROLL_CORPUS to the unchanged publisher networking EPUB")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "54d3886b30e92daca03f2f66065c01cb0d48c592824365605308b7b542c45c6d")
        let publication = try EPUBPublication.open(data: bytes)
        func open() throws -> (NativeSession, ReaderTestWindow) {
            let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
            return (session, ReaderTestWindow(session: session))
        }
        let (session, window) = try open()
        defer { session.close(); window.close() }
        window.resize(to: CGSize(width: 800, height: 700))
        try await wait { session.readerState?.status.lifecycle == .ready && session.book.isComplete }
        try await session.send(.style(.init(fontSize: 17, flow: .scrolled)))
        try await wait { session.book.isComplete && session.canvas?.scrollTextView != nil }
        #if os(macOS)
        let scroll = try XCTUnwrap(session.canvas?.scrollContainer as? NSScrollView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        #endif
        let questionHref = try XCTUnwrap(publication.spine.map(\.resource.path).first { $0.hasSuffix("ch009.xhtml") }) + "#questions-8"
        try await session.send(.navigate(href: questionHref))
        try await TestDeadline.pause(.milliseconds(500))
        try capture(try XCTUnwrap(session.canvas), name: "wide-light")
        window.resize(to: CGSize(width: 400, height: 700))
        try await TestDeadline.pause(.milliseconds(500))
        try capture(try XCTUnwrap(session.canvas), name: "narrow-light")
        try assertContained(try XCTUnwrap(session.canvas))
        let bodyHref = try XCTUnwrap(publication.spine.map(\.resource.path).first { $0.hasSuffix("ch008.xhtml") })
        try await session.send(.navigate(href: bodyHref))
        try await TestDeadline.pause(.milliseconds(500))
        try capture(try XCTUnwrap(session.canvas), name: "narrow-body-light")
        try assertContained(try XCTUnwrap(session.canvas))
        try await session.send(.style(.init(fontSize: 25, isDark: true, flow: .scrolled)))
        try await wait { session.book.isComplete && session.book.typography.fontSize == 25 }
        try await session.send(.navigate(href: bodyHref))
        try await TestDeadline.pause(.milliseconds(500))
        try capture(try XCTUnwrap(session.canvas), name: "narrow-body-dark")
        try assertContained(try XCTUnwrap(session.canvas))
        try await session.send(.navigate(href: questionHref))
        try await TestDeadline.pause(.milliseconds(500))
        let canvas = try XCTUnwrap(session.canvas)
        try capture(canvas, name: "narrow-dark")
        try assertContained(canvas)
        let saved = try XCTUnwrap(session.readerState?.status.location)
        let previousStart = try XCTUnwrap(canvas.visibleRange?.start)
        session.close()
        window.close()
        let (reopened, coldWindow) = try open()
        defer { reopened.close(); coldWindow.close() }
        coldWindow.resize(to: CGSize(width: 400, height: 700))
        try await wait { reopened.readerState?.status.lifecycle == .ready && reopened.book.isComplete }
        try await reopened.send(.style(.init(fontSize: 25, isDark: true, flow: .scrolled)))
        try await wait { reopened.book.isComplete && reopened.book.typography.fontSize == 25 }
        #if os(macOS)
        let coldScroll = try XCTUnwrap(reopened.canvas?.scrollContainer as? NSScrollView)
        coldScroll.scrollerStyle = .legacy
        coldScroll.autohidesScrollers = false
        #endif
        try await reopened.send(.restore(saved))
        try await TestDeadline.pause(.milliseconds(500))
        let coldCanvas = try XCTUnwrap(reopened.canvas)
        try capture(coldCanvas, name: "cold-dark", requireReadable: true)
        try assertContained(coldCanvas)
        XCTAssertEqual(coldCanvas.visibleRange?.start, previousStart)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = TestDeadline(seconds: 30)
        while !condition() {
            guard try !deadline.hasPassed() else { XCTFail("Timed out waiting for the reader"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func capture(_ canvas: ReaderCanvasView, name: String, requireReadable: Bool = false) throws {
        let directory = ProcessInfo.processInfo.environment["EPUBLIB_SCROLL_VISUAL_OUTPUT"]
        guard directory != nil || requireReadable else { return }
        #if os(macOS)
        canvas.layoutSubtreeIfNeeded()
        func display(_ view: NSView) {
            for child in view.subviews { display(child) }
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        display(canvas)
        // Capture the displayed native layers, then check opaque glyph pixels in every
        // restored question/choice line so a matching location alone cannot pass this test.
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(canvas.bounds.width * 2), height: Int(canvas.bounds.height * 2),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: canvas.bounds.height * 2)
        context.scaleBy(x: 2, y: -2)
        try XCTUnwrap(canvas.layer).render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if requireReadable { try assertVisibleLinesHaveInk(canvas, bitmap: bitmap) }
        #else
        let data = try XCTUnwrap(UIGraphicsImageRenderer(bounds: canvas.bounds).image { context in
            canvas.layer.render(in: context.cgContext)
        }.pngData())
        #endif
        if let directory { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")) }
    }

    #if os(macOS)
    private func assertVisibleLinesHaveInk(_ canvas: ReaderCanvasView, bitmap: NSBitmapImageRep) throws {
        let view = try XCTUnwrap(canvas.scrollTextView)
        let text = try XCTUnwrap(view.contentStorage.textStorage).string as NSString
        let question = text.range(of: "What is the primary value of the OSI network model?")
        let finalChoice = text.range(of: "OSI networks are more secure")
        XCTAssertNotEqual(question.location, NSNotFound)
        XCTAssertNotEqual(finalChoice.location, NSNotFound)
        guard question.location != NSNotFound, finalChoice.location != NSNotFound else { return }
        var checked = 0, location = question.location
        var report: [[String: Any]] = []
        while location < NSMaxRange(finalChoice) {
            let line = try XCTUnwrap(view.line(containing: location))
            let next = NSMaxRange(line.range)
            XCTAssertGreaterThan(next, location)
            guard next > location else { break }
            location = next
            let frame = view.convert(line.frame.offsetBy(dx: view.containerOrigin.x, dy: view.containerOrigin.y), to: canvas)
            if frame.minY >= 0, frame.maxY <= canvas.bounds.height, frame.intersects(canvas.bounds),
               !text.substring(with: line.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let pixels = frame.intersection(canvas.bounds)
                var ink = 0
                for y in Int(pixels.minY * 2)..<min(bitmap.pixelsHigh, Int(ceil(pixels.maxY * 2))) {
                    for x in max(0, Int(pixels.minX * 2))..<min(bitmap.pixelsWide, Int(ceil(pixels.maxX * 2))) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           min(color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent) > 0.35 { ink += 1 }
                    }
                }
                XCTAssertGreaterThan(ink, 20, "Restored visible line must draw its glyphs: \(text.substring(with: line.range))")
                report.append(["text": text.substring(with: line.range), "opaqueInkPixels": ink,
                               "frame": [frame.minX, frame.minY, frame.width, frame.height]])
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 8, "Validate the complete question and choices, not only a location")
        if let directory = ProcessInfo.processInfo.environment["EPUBLIB_SCROLL_VISUAL_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("cold-ink.json"))
        }
    }
    #endif

    func testContinuousColumnFitsLegacyScrollerAfterResizeAndFontChange() async throws {
        let paragraphs = (0..<18).map { _ in "What is the primary value of the OSI network model?\nIt divides network communication into layers with specific responsibilities.\n" }.joined()
        let source = FakeCanvasSource([CanvasText.body(paragraphs)])
        let host = CanvasHost(source, size: CGSize(width: 800, height: 700), configuration: .init(flow: .scrolled))
        defer { host.close() }
        host.canvas.show(.init(section: 0, offset: 0), selecting: nil)
        #if os(macOS)
        let scroll = try XCTUnwrap(host.canvas.scrollContainer as? NSScrollView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        #endif
        for width in [800.0, 400.0, 800.0, 400.0] {
            host.resize(to: CGSize(width: width, height: 700))
            try await host.settle()
            try assertContained(host.canvas)
        }
        source.sections = [CanvasText.body(paragraphs, size: 25)]
        host.canvas.configuration.isDark = true
        host.canvas.reloadContent(keeping: .init(section: 0, offset: 0))
        host.layOut()
        try await host.settle()
        try assertContained(host.canvas)
    }

    #if os(macOS)
    func testLegacyScrollerAppearanceAndPreferenceChangeRewrapWithoutWindowResize() async throws {
        let source = FakeCanvasSource([CanvasText.body("A short document.")])
        let host = CanvasHost(source, size: CGSize(width: 400, height: 700), configuration: .init(flow: .scrolled))
        defer { host.close() }
        host.canvas.show(.init(section: 0, offset: 0), selecting: nil)
        let scroll = try XCTUnwrap(host.canvas.scrollContainer as? NSScrollView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        source.sections = [CanvasText.section(0, chapters: 3, paragraphs: 10)]
        host.canvas.reloadContent(keeping: .init(section: 0, offset: 0))
        try await host.settle()
        host.layOut()
        XCTAssertLessThan(scroll.contentSize.width, host.canvas.bounds.width)
        try assertContained(host.canvas)
        for style in [NSScroller.Style.overlay, .legacy, .overlay, .legacy] {
            scroll.scrollerStyle = style
            try await host.settle()
            host.layOut()
            try assertContained(host.canvas)
        }
    }

    func testLegacyScrollerColumnStaysOnTheReadableSideOfADivision() async throws {
        let source = FakeCanvasSource([CanvasText.section(0, chapters: 2, paragraphs: 8)])
        let host = CanvasHost(source, size: CGSize(width: 800, height: 700), configuration: .init(flow: .scrolled))
        defer { host.close() }
        host.canvas.show(.init(section: 0, offset: 0), selecting: nil)
        let scroll = try XCTUnwrap(host.canvas.scrollContainer as? NSScrollView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        for division in [CGRect(x: 260, y: 0, width: 40, height: 700), CGRect(x: 520, y: 0, width: 40, height: 700)] {
            host.canvas.configuration.division = division
            host.layOut()
            try await host.settle()
            try assertContained(host.canvas)
            let view = try XCTUnwrap(host.canvas.scrollTextView)
            let column = view.convert(CGRect(origin: view.containerOrigin, size: view.readerContainer.viewportSize), to: host.canvas)
            XCTAssertTrue(column.maxX <= division.minX || column.minX >= division.maxX)
        }
    }
    #endif

    private func assertContained(_ canvas: ReaderCanvasView, file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(canvas.scrollTextView, file: file, line: line)
        #if os(macOS)
        let scroll = try XCTUnwrap(canvas.scrollContainer as? NSScrollView, file: file, line: line)
        XCTAssertLessThanOrEqual(view.containerOrigin.x + view.readerContainer.size.width,
                                 scroll.contentSize.width - 1, "Entire wrapping column retains a visible right inset", file: file, line: line)
        #else
        XCTAssertLessThanOrEqual(view.containerOrigin.x + view.readerContainer.size.width,
                                 view.bounds.width - 1, file: file, line: line)
        #endif
        let visible = canvas.scrollVisibleContainerRect
        var count = 0
        view.readerLayoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for nativeLine in fragment.textLineFragments where nativeLine.characterRange.length > 0 {
                let frame = nativeLine.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
                guard frame.intersects(visible) else { continue }
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, file: file, line: line)
                XCTAssertLessThanOrEqual(frame.maxX, view.readerContainer.size.width + 0.5, file: file, line: line)
                count += 1
            }
            return fragment.layoutFragmentFrame.minY < visible.maxY
        }
        XCTAssertGreaterThan(count, 0, file: file, line: line)
    }
}
