import CoreText
import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import StaticSVG
import SwiftUI
import XCTest
@testable import EPUBViewing

/// A live reader that is resized and restyled keeps the images a cold open at that size and
/// style mounts ([#54](https://github.com/vocaro/EPUBLib/issues/54)). These read the mounted
/// continuous-scroll text view itself, never a section's attributes or its fallback text.
@MainActor final class SVGRelayoutTests: XCTestCase {
    private struct Timeout: Error, CustomStringConvertible { let description: String }

    private func wait(_ label: String, timeout: TimeInterval = 60, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Timeout(description: "Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: A mounted session

    /// An image attachment in the mounted text view: where it is, what it shows and how.
    private struct MountedImage: Equatable {
        var location: Int
        var path: String
        var sizing: ImageSizing
        var isDark: Bool
        var fontSize: CGFloat
    }

    @MainActor private struct Reader {
        let session: NativeSession
        let window: ReaderTestWindow
        func close() { session.close(); window.close() }
    }

    private func open(_ publication: EPUBPublication, size: CGSize) async throws -> Reader {
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication) { _ in } as? NativeSession)
        let reader = Reader(session: session, window: ReaderTestWindow(session: session))
        try await resize(reader, to: size)
        try await wait("the reader") { session.isReady }
        return reader
    }

    private func resize(_ reader: Reader, to size: CGSize) async throws {
        reader.window.resize(to: size)
        // The canvas follows its window. A host that cannot give it that width (a device's own
        // scene) still relayouts whatever it has, which is all the style change needs.
        let deadline = Date().addingTimeInterval(5)
        while reader.session.canvas?.bounds.width != size.width, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #if os(macOS)
        XCTAssertEqual(reader.session.canvas?.bounds.width, size.width)
        #endif
    }

    /// The image attachments mounted once the scroll view shows the whole book built for
    /// `style`. Each must also draw: a mounted image that cannot decode shows nothing.
    private func mountedImages(_ reader: Reader, style: EPUBReaderStyle) async throws -> [MountedImage] {
        let session = reader.session
        let typography = NativeTypography(fontSize: style.fontSize, isDark: style.appearance == .dark)
        try await wait("the whole book at \(style.fontSize) pt, \(style.appearance)") {
            guard session.book.isComplete, session.book.typography == typography, let canvas = session.canvas,
                  let view = canvas.scrollTextView, view.window != nil, let book = session.bookText else { return false }
            return canvas.scrollBook?.string === book.string && view.flowSourceText === book.string
        }
        let view = try XCTUnwrap(session.canvas?.scrollTextView)
        let storage = try XCTUnwrap(view.contentStorage.textStorage)
        let viewport = view.readerContainer.viewportSize
        XCTAssertGreaterThan(viewport.width, 0)
        var images: [MountedImage] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let image = value as? ReaderImageAttachment else { return }
            let bounds = image.layoutBounds(ReaderAttachment.Line(width: viewport.width, viewport: viewport))
            XCTAssertNotNil(image.bitmap(for: CGRect(origin: .zero, size: bounds.size), scale: 2),
                            "\(image.path) is mounted but does not draw")
            images.append(MountedImage(location: range.location, path: image.path, sizing: image.sizing,
                                       isDark: image.isDark, fontSize: image.fontSize))
        }
        return images
    }

    /// Scrolls through every linear section, as a person reading to each figure does.
    private func readThrough(_ reader: Reader) async throws {
        let spine = reader.session.publication.spine
        for (index, item) in spine.enumerated() where item.isLinear {
            try await reader.session.send(.navigate(href: item.resource.href))
            try await wait("section \(index)") { reader.session.visibleRange?.start.section == index }
        }
        guard let first = spine.firstIndex(where: \.isLinear) else { return }
        try await reader.session.send(.navigate(href: spine[first].resource.href))
        try await wait("the first section") { reader.session.visibleRange?.start.section == first }
    }

    /// The reported sequence in one live session, then a cold open at the final size and style.
    /// `figures` are the archive paths of the book's images in reading order.
    private func exerciseRelayout(_ publication: EPUBPublication, figures: [String]) async throws {
        let wide = CGSize(width: 800, height: 700), narrow = CGSize(width: 400, height: 700)
        let light = EPUBReaderStyle(fontSize: 17, appearance: .light, flow: .scrolled)
        let largeDark = EPUBReaderStyle(fontSize: 25, appearance: .dark, flow: .scrolled)

        let live = try await open(publication, size: wide)
        defer { live.close() }
        try await live.session.send(.style(light))
        let wideLight = try await mountedImages(live, style: light)
        XCTAssertEqual(wideLight.map(\.path), figures, "Wide, 17 pt, light")
        try await readThrough(live)
        try await resize(live, to: narrow)
        let narrowLight = try await mountedImages(live, style: light)
        XCTAssertEqual(narrowLight, wideLight, "A resize rebuilds nothing")
        try await live.session.send(.style(largeDark))
        let relayout = try await mountedImages(live, style: largeDark)
        XCTAssertEqual(relayout.map(\.path), figures, "Narrow, 25 pt, dark, in the session that was wide and light")
        XCTAssertTrue(relayout.allSatisfy(\.isDark), "The mounted images are the rebuilt ones")

        let cold = try await open(publication, size: narrow)
        defer { cold.close() }
        try await cold.session.send(.style(largeDark))
        let opened = try await mountedImages(cold, style: largeDark)
        XCTAssertEqual(opened.map(\.path), figures, "Narrow, 25 pt, dark, opened cold")
        XCTAssertEqual(relayout, opened, "A relayout mounts exactly what a cold open at that size and style mounts")
    }

    // MARK: Tests

    /// A book shaped like the networking one: figures as archive SVG whose labels use more font
    /// sets than the renderer caches, a drawing without text, and one figure shown twice.
    private static func figureBook() throws -> (data: Data, figures: [String]) {
        var files = try Fixture.files()
        // Distinct faces: each figure's labels need a font database of their own.
        let faces = ["TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT", "ArialMT", "Arial-BoldMT", "CourierNewPSMT"]
        var css = ""
        for (index, name) in faces.enumerated() {
            let font = try XCTUnwrap(SVGFontData.export(CTFontCreateWithName(name as CFString, 12, nil)), name)
            files["OPS/fonts/face\(index).ttf"] = font.data
            css += "@font-face { font-family: Figure\(index); src: url(fonts/face\(index).ttf); }\n"
            files["OPS/media/figure\(index).svg"] = Data("""
            <svg xmlns='http://www.w3.org/2000/svg' width='320' height='120' viewBox='0 0 320 120'>\
            <rect x='2' y='2' width='316' height='116' fill='white' stroke='black'/>\
            <text x='16' y='70' font-family='Figure\(index)' font-size='28'>Label \(index)</text></svg>
            """.utf8)
        }
        files["OPS/figures.css"] = Data(css.utf8)
        files["OPS/media/shapes.svg"] = Data("""
        <svg xmlns='http://www.w3.org/2000/svg' width='320' height='120' viewBox='0 0 320 120'>\
        <circle cx='160' cy='60' r='50' fill='none' stroke='black' stroke-width='4'/></svg>
        """.utf8)
        var body = "<h1 id='start'>Figures</h1>"
        var figures: [String] = []
        for name in ["figure0", "figure1", "shapes", "figure2", "figure3", "figure4", "figure0"] {
            body += "<p>\(String(repeating: "Ordinary reading text between two figures. ", count: 12))</p>"
            body += "<p><img src='media/\(name).svg' alt='Fallback text of \(name)'/></p>"
            figures.append("OPS/media/\(name).svg")
        }
        files["OPS/one.xhtml"] = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Figures</title>\
        <link rel="stylesheet" href="figures.css"/></head><body>\(body)</body></html>
        """.utf8)
        return (try Fixture.archive(files), figures)
    }

    func testRelayoutMountsTheSameSVGFiguresAsAColdOpen() async throws {
        let book = try Self.figureBook()
        try await exerciseRelayout(try EPUBPublication.open(data: book.data), figures: book.figures)
    }

    /// The unchanged publisher EPUB the issue was reported with, when it is provided.
    func testOriginalNetworkingFiguresSurviveRelayoutWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBLIB_SVG_CORPUS"] else {
            throw XCTSkip("Set EPUBLIB_SVG_CORPUS to the unchanged publisher networking EPUB")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "54d3886b30e92daca03f2f66065c01cb0d48c592824365605308b7b542c45c6d")
        let publication = try EPUBPublication.open(data: bytes)
        var figures: [String] = []
        for item in publication.spine where item.isLinear {
            let document = try ContentDocument.parse(publication.data(for: item.resource), path: item.resource.path)
            for image in document.nodes where image.isHTML("img") {
                let resolved = try ResourceReference.resolve(try XCTUnwrap(image.attribute("src")), relativeTo: document.path)
                figures.append(resolved.removingPercentEncoding ?? resolved)
            }
        }
        // The cover, one photograph and 33 SVG resources, two of them shown twice.
        XCTAssertEqual(figures.count, 37)
        XCTAssertEqual(Set(figures.filter { $0.hasSuffix(".svg") }).count, 33)
        try await exerciseRelayout(publication, figures: figures)
    }

    /// Closing returns a reader's images, and an SVG's renderer and font reservation with
    /// them, at once: not when the platform gets round to freeing the reader's views.
    func testClosingAReaderReleasesItsImagesAtOnce() async throws {
        final class Tracked { weak var source: ReaderImageSource? }
        let book = try Self.figureBook()
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try await open(try EPUBPublication.open(data: book.data), size: CGSize(width: 400, height: 700))
            defer { reader.close() }
            let session = reader.session
            try await session.send(.style(.init(fontSize: 19, appearance: .light, flow: flow)))
            try await wait("the \(flow) book on screen") {
                guard session.book.isComplete, session.book.typography == NativeTypography(fontSize: 19),
                      let canvas = session.canvas else { return false }
                if flow == .scrolled { return canvas.scrollBook != nil && canvas.scrollBook?.string === session.bookText?.string }
                return canvas.shownPage != nil && canvas.textViews.contains { $0.textLength > 0 }
            }
            // Read inside a pool of its own: an attribute the test enumerated must not be what
            // keeps an image alive afterwards.
            let images: [Tracked] = autoreleasepool {
                var images: [Tracked] = []
                for index in 0..<session.book.count {
                    guard let text = session.book.section(index)?.string else { continue }
                    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                        guard let image = value as? ReaderImageAttachment else { return }
                        let tracked = Tracked()
                        tracked.source = image.source
                        images.append(tracked)
                    }
                }
                return images
            }
            XCTAssertEqual(images.filter { $0.source != nil }.count, book.figures.count, "\(flow)")
            session.close()
            let deadline = Date().addingTimeInterval(10)
            while images.contains(where: { $0.source != nil }), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(images.filter { $0.source != nil }.count, 0, "\(flow): a closed reader still holds its images")
        }
    }

    /// The images of text the scroll view no longer shows go with it, also after a resize,
    /// when TextKit 2 otherwise keeps the old layout's attachments alive behind the new text.
    func testReplacedScrollContentReleasesItsImagesAfterAResize() async throws {
        final class Tracked { weak var attachment: NSTextAttachment? }
        let fixture = try RichFixture((0..<20).map { "<img id='i\($0)' src='dot.png' alt='figure \($0)'/>" }.joined(),
                                      files: ["dot.png": RichFixture.image(width: 200, height: 120)])
        func book(size: CGFloat) -> (sections: [NSAttributedString], images: [Tracked]) {
            var images: [Tracked] = []
            let sections = (0..<3).map { section in
                let text = NSMutableAttributedString()
                for paragraph in 0..<60 {
                    if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
                    text.append(CanvasText.body("S\(section)P\(paragraph) " + CanvasText.sentence(70, seed: paragraph), size: size))
                    guard paragraph % 3 == 0, let image = fixture.image("i\(paragraph / 3)") else { continue }
                    text.append(NSAttributedString(string: "\n"))
                    text.append(image)
                    for attachment in RichFixture.attachments(in: image) {
                        let tracked = Tracked()
                        tracked.attachment = attachment
                        images.append(tracked)
                    }
                }
                return text as NSAttributedString
            }
            return (sections, images)
        }
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        var first = book(size: 17)
        let source = FakeCanvasSource(first.sections)
        source.book = CanvasText.book(first.sections)
        first.sections = []
        let host = CanvasHost(source, size: CGSize(width: 800, height: 700), configuration: configuration)
        defer { host.close() }
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut(); try await host.settle()
        XCTAssertEqual(first.images.filter { $0.attachment != nil }.count, 60)
        host.resize(to: CGSize(width: 400, height: 700))
        try await host.settle()

        // A typography change: the section on screen arrives first, the whole book when it is built.
        var second = book(size: 25)
        source.sections = second.sections
        source.book = nil
        host.canvas.reloadContent(keeping: nil)
        host.layOut(); try await host.settle(100)
        source.book = CanvasText.book(second.sections)
        second.sections = []
        host.canvas.reloadContent(keeping: nil)
        host.layOut()
        let deadline = Date().addingTimeInterval(10)
        while first.images.contains(where: { $0.attachment != nil }), Date() < deadline { try await host.settle(50) }
        XCTAssertEqual(first.images.filter { $0.attachment != nil }.count, 0, "The replaced text's images are still alive")
        XCTAssertEqual(second.images.filter { $0.attachment != nil }.count, 60, "The mounted text keeps its own")
    }
}
