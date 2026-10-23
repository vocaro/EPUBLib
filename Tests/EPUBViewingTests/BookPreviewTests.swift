import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The preview a Quick Look preview extension shows (#695): the cover, title and authors, and the
/// opening of the book in the package's reader, which builds the opening sections and no more.
@MainActor final class BookPreviewTests: XCTestCase {
    /// A book of `count` linear chapters of `paragraphs` paragraphs each, with a cover.
    private func book(chapters count: Int, paragraphs: Int = 3, nonlinear: Set<Int> = []) -> Fixture.SpecBook {
        var book = BookThumbnailTests.book(cover: ("cover.png", "image/png", BookThumbnailTests.halves(width: 60, height: 90), ""))
        book.sections = []
        for index in 1...count {
            let words = String(repeating: "<p>Chapter \(index) goes on, as chapters do, for a while longer.</p>", count: paragraphs)
            book.add("chapter\(index)", itemref: nonlinear.contains(index) ? "linear=\"no\"" : "",
                     body: "<h1>Chapter \(index)</h1><p>Words of chapter \(index) alone.</p>\(words)")
        }
        return book
    }

    func testThePreviewHasTheCoverTitleAndAuthors() throws {
        let preview = EPUBPreview(publication: try EPUBPublication.open(data: book(chapters: 2).archive()))
        XCTAssertEqual(preview.title, "A Conformance Book")
        XCTAssertEqual(preview.authors, ["Test Author"])
        XCTAssertEqual(preview.cover?.content, .cover)
        let plain = EPUBPreview(publication: try EPUBPublication.open(data: BookThumbnailTests.book().archive()))
        XCTAssertNil(plain.cover, "no title page stands in for a cover beside the title")
    }

    func testTheOpeningIsTheFirstSectionsOfTheBook() throws {
        let preview = EPUBPreview(publication: try EPUBPublication.open(data: book(chapters: 9).archive()))
        XCTAssertEqual(preview.opening.spine.map(\.resource.id), ["chapter1", "chapter2", "chapter3", "chapter4"])
        // Nonlinear items before the fourth linear one are kept in their places, and not counted.
        let skipping = EPUBPreview(publication: try EPUBPublication.open(data: book(chapters: 9, nonlinear: [2, 3]).archive()))
        XCTAssertEqual(skipping.opening.spine.map(\.resource.id), (1...6).map { "chapter\($0)" })
        // Long sections end the opening sooner: the second brings it past the bytes it holds.
        let long = EPUBPreview(publication: try EPUBPublication.open(data: book(chapters: 6, paragraphs: 2_500).archive()))
        XCTAssertEqual(long.opening.spine.count, 2)
        XCTAssertEqual(EPUBPreview.openingBytes, 256 * 1024)
    }

    func testThePreviewReaderBuildsTheOpeningAndReadsNoFurther() async throws {
        let data = try book(chapters: 9).archive()
        let whole = try EPUBPublication.open(data: data)
        let preview = EPUBPreview(publication: try EPUBPublication.open(data: data, onDemand: true))
        let pages = PreviewPages()
        pages.open(preview.opening)
        let session = try XCTUnwrap(pages.session as? NativeSession)
        XCTAssertEqual(session.style.flow, .scrolled, "a preview starts in continuous scroll")
        let window = ReaderTestWindow(session: session)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(20)
        while !(session.isReady && session.book.isComplete), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(session.isReady && session.book.isComplete, "the opening is built")
        XCTAssertEqual(session.book.count, 4)
        XCTAssertTrue(session.book.section(0)?.string.string.contains("Words of chapter 1 alone.") == true)
        XCTAssertNil(pages.failure)
        // The fifth chapter on was never read: reading it now adds its bytes.
        let read = preview.opening.expandedBytesRead
        XCTAssertLessThan(read, whole.expandedBytesRead)
        let fifth = try preview.opening.data(at: "EPUB/chapter5.xhtml")
        XCTAssertEqual(preview.opening.expandedBytesRead, read + fifth.count)
        pages.close()
        XCTAssertTrue(session.closed)
        XCTAssertNil(pages.session)
    }

    func testAPreviewOfAFileOpensItOnDemand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        let data = try book(chapters: 9).archive()
        try data.write(to: url)
        let preview = try EPUBPreview(contentsOf: url)
        XCTAssertEqual(preview.opening.spine.count, 4)
        XCTAssertLessThan(preview.opening.expandedBytesRead, try EPUBPublication.open(data: data).expandedBytesRead)
    }

    func testThePreviewViewShowsTheOpeningInTheReader() async throws {
        let preview = EPUBPreview(publication: try EPUBPublication.open(data: book(chapters: 6).archive(), onDemand: true))
        let view = EPUBPreviewView(preview: preview)
        #if os(macOS)
        let window = makeMacTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                                       backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.keepLightAppearance()
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.close(); window.contentView = nil }
        func canvases() -> [ReaderCanvasView] { Self.canvases(in: window.contentView) }
        #else
        let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.keepLightAppearance()
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func canvases() -> [ReaderCanvasView] { Self.canvases(in: window) }
        #endif
        let deadline = Date().addingTimeInterval(20)
        func shown() -> String? { canvases().first?.shownText?.text.string }
        while shown()?.contains("Words of chapter 1 alone.") != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(canvases().count, 1)
        XCTAssertTrue(shown()?.contains("Words of chapter 1 alone.") == true, "the opening is on screen: \(shown() ?? "nothing")")
        XCTAssertEqual(canvases().first?.configuration.flow, .scrolled)
    }

    private static func canvases(in view: PlatformView?) -> [ReaderCanvasView] {
        guard let view else { return [] }
        if let canvas = view as? ReaderCanvasView { return [canvas] }
        return view.subviews.flatMap { canvases(in: $0) }
    }
}
