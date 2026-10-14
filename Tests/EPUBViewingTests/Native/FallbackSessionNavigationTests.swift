import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

@MainActor final class FallbackSessionNavigationTests: XCTestCase {
    func testLongEncodedFallbackPathsAndNearLimitCFIsSaveAndRestoreInAReopenedSession() async throws {
        let longPath = (0..<40).map { "d\($0)" + String(repeating: "é", count: 20) }.joined(separator: "/") + "/static.xhtml"
        let href = ResourceReference.encoded(path: longPath)
        XCTAssertGreaterThan(href.count, EPUBCFI.maximumLength)
        let packageID = String(repeating: "a", count: 2000), bodyID = String(repeating: "b", count: 2000)
        var book = Fixture.SpecBook()
        book.add("before", body: "<p>Before</p>")
        book.add(href: "source.json", id: "source", mediaType: "application/json", Data("{}".utf8), item: "fallback='static'")
        book.spine = "<itemref idref='before'/><itemref idref='source' id='\(packageID)'/>"
        let fallback = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body id='\(bodyID)'><p id='target'>Fallback needle</p></body></html>"
        book.resource(href, id: "static", mediaType: "application/xhtml+xml", Data(fallback.utf8), path: longPath)
        let archive = try book.archive()
        let first = try SessionCoverageReader(archive)
        defer { first.close() }
        try await first.settle()
        try await first.session.send(.navigate(href: "EPUB/source.json"))
        try await first.wait("qualified fallback position") { first.session.lastLocation?.href == "EPUB/source.json" }
        let saved = try XCTUnwrap(first.session.lastLocation)
        let bookmark = try XCTUnwrap(saved.bookmark)
        XCTAssertGreaterThan(bookmark.value.count, EPUBCFI.maximumLength, "qualification uses only its fixed-width allowance")
        XCTAssertLessThanOrEqual(bookmark.value.count, EPUBCFI.maximumQualifiedLength)
        XCTAssertTrue(EPUBCFI.isWellFormed(bookmark.value))
        XCTAssertFalse(bookmark.value.contains(href))
        XCTAssertEqual(first.session.book.section(1)?.document.cfiResource?.count, 64)
        first.close()
        let reopened = try SessionCoverageReader(archive)
        defer { reopened.close() }
        try await reopened.settle()
        try await reopened.session.send(.restore(saved))
        try await reopened.wait("restored long-path fallback") { reopened.section == 1 && reopened.session.lastLocation?.href == "EPUB/source.json" }
        XCTAssertTrue(reopened.notices().isEmpty)
        XCTAssertEqual(reopened.session.book.section(1)?.specText, "Fallback needle")
    }

    func testFallbackRelativeLinksNavigationSearchAndBookmarksUseTheSameOccurrence() async throws {
        var book = Fixture.SpecBook()
        book.add("before", body: "<p>Before</p>")
        book.add(href: "source.json", id: "source", mediaType: "application/json", Data("{}".utf8), item: "fallback='static'")
        book.resource("text/static.xhtml", id: "static", mediaType: "application/xhtml+xml",
                      Data(Fixture.SpecBook.xhtml(head: "<link rel='stylesheet' href='style.css'/>",
                        body: "<p id='start'>Fallback needle</p><p><a href='static.xhtml#target'>Local link</a></p><p id='target'>Target</p>").utf8))
        book.resource("text/style.css", id: "css", mediaType: "text/css", Data("p { color: rgb(255, 0, 0); }".utf8))
        book.navigation = "<nav epub:type='toc'><ol><li><a href='text/static.xhtml#target'>Fallback TOC</a></li></ol></nav>"
        let publication = try EPUBPublication.open(data: book.archive())
        let reader = try SessionCoverageReader(publication: publication)
        defer { reader.close() }
        try await reader.settle()
        try await reader.session.send(.navigate(href: "EPUB/text/static.xhtml#target"))
        try await reader.wait("fallback location") { reader.section == 1 && reader.session.lastLocation?.href == "EPUB/source.json" }
        XCTAssertEqual(reader.section, 1)
        let section = try XCTUnwrap(reader.session.book.section(1))
        XCTAssertEqual(section.document.path, "EPUB/text/static.xhtml")
        XCTAssertEqual(section.specLink("Local link"), .internal(href: "EPUB/text/static.xhtml#target"))
        XCTAssertEqual(reader.session.lastLocation?.href, "EPUB/source.json")
        let text = try XCTUnwrap(section.document.element(id: "start")?.children.first)
        let path = try SpineCFIs(publication: publication).cfi(spineIndex: 1, start: DOMPosition(text, 9), end: DOMPosition(text, 15), in: section.document)
        let location = EPUBLocation(publicationID: publication.id, href: section.href, quote: "needle",
            bookmark: EPUBEngineBookmark(engineID: NativeEngine.identifier, format: NativeEngine.bookmarkFormat, value: path))
        try await reader.session.send(.restore(location))
        XCTAssertEqual(reader.section, 1)
        XCTAssertTrue(reader.notices().isEmpty)
        let start = try reader.anchor("start", section: 1)
        XCTAssertTrue(reader.isVisible(start))
        let progress = NativeProgress(publication: publication)
        XCTAssertEqual(progress.title(at: ReaderTextPosition(section: 1, offset: section.anchors["target"]!),
                                      anchor: { _, id in section.anchors[id] }), "Fallback TOC")
    }
}
