import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

final class FallbackCFIQualificationTests: XCTestCase {
    private func document() throws -> ContentDocument {
        try ContentDocument.parse(Data("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body id='body'><p id='p'>First second</p></body></html>".utf8), path: "fallback.xhtml")
    }

    func testQualifiedPositionsAndRangesRoundTripWithEscapedResourceNames() throws {
        let original = try document()
        let text = try XCTUnwrap(original.element(id: "p")?.children.first)
        let unqualified = EPUBCFI.localPath(from: DOMPosition(text, 1), to: DOMPosition(text, 6), in: original)
        XCTAssertEqual(unqualified, "/4[body]/2[p],/1:1,/1:6")
        for resource in ["EPUB/fallback.xhtml", "EPUB/é 😀;[x]^.xhtml", "EPUB/a%23b%25c.xhtml"] {
            let fallback = original.withCFIResource(resource)
            for (start, end) in [(1, 1), (1, 6)] {
                let path = EPUBCFI.localPath(from: DOMPosition(text, start), to: DOMPosition(text, end), in: fallback)
                XCTAssertTrue(EPUBCFI.isWellFormed(EPUBCFI.wrap(path)), path)
                let expression = try EPUBCFI.parse(path)
                XCTAssertEqual(EPUBCFI.innerString(expression), path)
                let resolved = try XCTUnwrap(EPUBCFI.resolve(expression, in: fallback))
                XCTAssertEqual(resolved.start, DOMPosition(text, start))
                XCTAssertEqual(resolved.end, DOMPosition(text, end))
                XCTAssertNil(EPUBCFI.resolve(localPath: path, in: original))
                XCTAssertNil(EPUBCFI.resolve(localPath: path, in: original.withCFIResource("other.xhtml")))
            }
            XCTAssertNil(EPUBCFI.resolve(localPath: unqualified, in: fallback))
        }
        XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(text, 1), to: DOMPosition(text, 6), in: original), unqualified)
    }

    func testQualifiedHTMLRootsKeepTheirExistingIDAssertionsAndOriginalPaths() throws {
        let original = try ContentDocument.parse(Data("<html id='root'><head><title>T</title></head><body id='body'><p id='p'>First second</p></body></html>".utf8), path: "old.html")
        XCTAssertTrue(original.recoveredAsHTML)
        XCTAssertTrue(original.canResolveCFIs)
        let text = try XCTUnwrap(original.element(id: "p")?.children.first)
        let before = EPUBCFI.localPath(from: DOMPosition(text, 1), to: DOMPosition(text, 6), in: original)
        let qualified = original.withCFIResource("EPUB/fallback.xhtml")
        let path = EPUBCFI.localPath(from: DOMPosition(text, 1), to: DOMPosition(text, 6), in: qualified)
        XCTAssertTrue(path.contains("/4[body;vnd.epublib.resource="))
        XCTAssertTrue(path.contains("/2[p]"))
        XCTAssertEqual(try XCTUnwrap(EPUBCFI.resolve(localPath: path, in: qualified)).start, DOMPosition(text, 1))
        XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(text, 1), to: DOMPosition(text, 6), in: original), before)
        XCTAssertNil(EPUBCFI.resolve(localPath: before, in: qualified))
    }

    func testDuplicateAndMisplacedResourceAssertionsAreRefused() throws {
        let fallback = try document().withCFIResource("a.xhtml")
        let digest = try XCTUnwrap(fallback.cfiResource)
        for path in ["/4[body;vnd.epublib.resource=\(digest);vnd.epublib.resource=\(digest)]/2[p]/1:1",
                     "/4[body;vnd.epublib.resource=\(digest)]/2[p;vnd.epublib.resource=\(digest)]/1:1",
                     "/4[body]/2[p;vnd.epublib.resource=\(digest)]/1:1",
                     "/4[body;vnd.epublib.resource=wrong.xhtml]/2[p]/1:1"] {
            XCTAssertNil(EPUBCFI.resolve(localPath: path, in: fallback), path)
        }
    }

    func testResourceDigestsStayCompactAndNearLimitCFIsKeepTheirOriginalBudget() throws {
        let original = try document()
        let fallback = original.withCFIResource(String(repeating: "é", count: 800))
        let digest = try XCTUnwrap(fallback.cfiResource)
        XCTAssertEqual(digest.utf8.count, 64)
        XCTAssertEqual(try document().withCFIResource(String(repeating: "é", count: 800)).cfiResource, digest)
        XCTAssertNotEqual(original.withCFIResource("other").cfiResource, digest)
        // Only the fixed qualification overhead extends the existing wire validation. DOM ID
        // assertions and their full ordinary-CFI4096-character allowance stay intact.
        let id = String(repeating: "a", count: EPUBCFI.maximumLength - "epubcfi(/4[]/2/1:0)".count)
        let ordinary = "epubcfi(/4[\(id)]/2/1:0)"
        XCTAssertEqual(ordinary.count, EPUBCFI.maximumLength)
        XCTAssertTrue(EPUBCFI.isWellFormed(ordinary))
        let qualified = "epubcfi(/4[\(id);vnd.epublib.resource=\(digest)]/2/1:0)"
        XCTAssertTrue(EPUBCFI.isWellFormed(qualified))
        XCTAssertEqual(qualified.count, ordinary.count + 86)
        XCTAssertFalse(EPUBCFI.isWellFormed("epubcfi(/4[a\(id)]/2/1:0)"))
        XCTAssertFalse(EPUBCFI.isWellFormed("epubcfi(/4[a\(id);vnd.epublib.resource=\(digest)]/2/1:0)"))
        XCTAssertFalse(EPUBCFI.isWellFormed(qualified.replacingOccurrences(of: digest, with: String(repeating: "x", count: 64))))
        XCTAssertNil(SpineCFIs(package: nil, spineCount: 1).resolve("epubcfi(/6/2[;vnd.epublib.resource=\(digest)]!/4/2/1:0)"))
    }

    @MainActor func testFallbackCFIsKeepOriginalSpineOccurrenceAndResolveAfterReopening() throws {
        var book = Fixture.SpecBook()
        book.add(href: "source.json", id: "source", mediaType: "application/json", Data("{}".utf8), item: "fallback='static'")
        book.resource("static.xhtml", id: "static", mediaType: "application/xhtml+xml",
                      Data(Fixture.SpecBook.xhtml(body: "<p id='p'>First second</p>").utf8))
        book.spine = "<itemref idref='source'/><itemref idref='source'/>"
        let first = try SpecConformanceBuild(book), second = try SpecConformanceBuild(archive: book.archive())
        let spine = try SpineCFIs(publication: first.publication)
        for index in 0..<2 {
            let text = try XCTUnwrap(first[index].document.element(id: "p")?.children.first)
            let cfi = spine.cfi(spineIndex: index, start: DOMPosition(text, 1), end: DOMPosition(text, 6), in: first[index].document)
            XCTAssertTrue(EPUBCFI.isWellFormed(cfi))
            let target = try XCTUnwrap(try SpineCFIs(publication: second.publication).resolve(cfi))
            XCTAssertEqual(target.spineIndex, index)
            let range = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: second[index].document))
            XCTAssertEqual([range.start.offset, range.end.offset], [1, 6])
            XCTAssertEqual(range.start.node.text, "First second")
            XCTAssertEqual(first[index].href, "EPUB/source.json")
        }
    }
}
