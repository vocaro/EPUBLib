import EPUBCore
import EPUBReading
import EPUBViewing
import EPUBTestSupport
import Foundation
import WebKit
import XCTest
@testable import EPUBViewing

@MainActor final class LayoutRenderingTests: XCTestCase {
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while try await !condition() {
            guard Date() < deadline else { return XCTFail("Rendering timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func exercise(_ kind: Fixture.Rendering) async throws {
        let data = try await Task.detached { try Fixture.rendering(kind) }.value
        let publication = try EPUBPublication.open(data: data)
        var events: [EPUBReaderEvent] = []
        let session = try FoliateEngine().makeSession(publication: publication) { events.append($0) }
        let foliate = try XCTUnwrap(session as? FoliateSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { events.contains(.ready) }
        let web = try XCTUnwrap(foliate.model.webView)
        func evaluate(_ expression: String) async throws -> Bool {
            try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents().some(c => { \(expression) })") as? Bool == true
        }
        try await wait {
            try await evaluate("const h=c.doc.querySelector('h1'); return h && h.getBoundingClientRect().height > 0 && h.getBoundingClientRect().width > 0;")
        }
        switch kind {
        case .escapedHref:
            XCTAssertEqual(publication.spine[0].resource.path, "OPS/chapter #100%?.xhtml")
            XCTAssertEqual(publication.spine[0].resource.href, "OPS/chapter%20%23100%25%3F.xhtml")
            XCTAssertEqual(publication.tableOfContents.first?.href, "OPS/chapter%20%23100%25%3F.xhtml#start%20%2350%25")
        case .fixedLayout:
            XCTAssertEqual(publication.spine[0].layout, .prePaginated)
            XCTAssertFalse(session.capabilities.contains(.scrolling))
            XCTAssertFalse(session.capabilities.contains(.typography))
            for (style, error) in [(EPUBReaderStyle(fontSize: 22), EPUBReaderError.unsupported(.typography)),
                                   (EPUBReaderStyle(flow: .scrolled), .unsupported(.scrolling))] {
                do { try await session.send(.style(style)); XCTFail("Unsupported fixed-layout control accepted") }
                catch let actual { XCTAssertEqual(actual as? EPUBReaderError, error) }
            }
            let viewport = try await evaluate("return c.doc.querySelector('meta[name=viewport]')?.content.includes('width=600');")
            XCTAssertTrue(viewport)
        case .rightToLeft:
            let rtl = try await evaluate("return c.doc.defaultView.getComputedStyle(c.doc.documentElement).direction === 'rtl';")
            XCTAssertTrue(rtl)
        case .vertical:
            let vertical = try await evaluate("return c.doc.defaultView.getComputedStyle(c.doc.documentElement).writingMode === 'vertical-rl';")
            XCTAssertTrue(vertical)
        case .largeIllustrated:
            XCTAssertEqual(publication.spine.count, 40)
            XCTAssertGreaterThan(data.count, 20 * 1024 * 1024)
            try await wait { try await evaluate("return Array.from(c.doc.images).some(i => i.complete && i.naturalWidth === 1024 && i.getBoundingClientRect().width > 0);") }
        }
        try await wait { foliate.model.location?.sectionIndex == 0 }
        if kind == .escapedHref {
            try await session.send(.navigate(href: XCTUnwrap(publication.tableOfContents.first?.href)))
        }
        let href = try XCTUnwrap(events.compactMap { event -> String? in
            if case .relocated(let location) = event { return location.href }; return nil
        }.last)
        XCTAssertEqual(href, publication.spine[0].resource.href)
        // Round-trip an emitted href, including characters with URL syntax meaning.
        try await session.send(.navigate(href: publication.spine.last!.resource.href))
        try await wait { foliate.model.location?.sectionIndex == publication.spine.count - 1 }
        try await session.send(.navigate(href: href))
        try await wait { foliate.model.location?.sectionIndex == 0 }
        XCTAssertEqual(events.filter { $0 == .ready }.count, 1)
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false })
    }
    func testEncodedHrefRoundTrip() async throws { try await exercise(.escapedHref) }
    func testFixedLayout() async throws { try await exercise(.fixedLayout) }
    func testRightToLeft() async throws { try await exercise(.rightToLeft) }
    func testVerticalWriting() async throws { try await exercise(.vertical) }
    func testLargeIllustratedBook() async throws { try await exercise(.largeIllustrated) }
}
