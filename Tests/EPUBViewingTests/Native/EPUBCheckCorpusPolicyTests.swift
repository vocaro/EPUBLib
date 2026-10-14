import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

@MainActor final class EPUBCheckCorpusPolicyTests: XCTestCase {
    private typealias Book = Fixture.SpecBook
    private typealias Build = SpecConformanceBuild
    private typealias Outcome = EPUBCheckCorpusTests.Outcome

    private func outcome(_ built: Build) -> Outcome {
        var result = Outcome(fixture: "generated", verdict: .valid, ids: [])
        for index in built.sections.indices {
            EPUBCheckCorpusTests.recordDocumentPolicy(built[index], resource: built.publication.spine[index].resource,
                                                      publication: built.publication, outcome: &result)
        }
        return result
    }

    func testParsedAuthoredDocumentsAndTheirClonesNeverGainSyntheticRasterOrigin() throws {
        for markup in [Book.xhtml(body: "<img src='image.png'/>"), "<svg xmlns='http://www.w3.org/2000/svg'><rect width='20' height='20'/></svg>"] {
            let document = try ContentDocument.parse(Data(markup.utf8), path: "authored.xml", asContent: false)
            XCTAssertEqual(document.origin, .authored)
            XCTAssertEqual(document.withoutCFIs().origin, .authored)
            XCTAssertEqual(document.withCFIResource("effective.xml").origin, .authored)
            let synthetic = document.asSyntheticRaster()
            XCTAssertEqual(synthetic.origin, .syntheticRaster)
            XCTAssertFalse(synthetic.canResolveCFIs)
            XCTAssertEqual(synthetic.withoutCFIs().origin, .syntheticRaster)
            XCTAssertEqual(synthetic.withCFIResource("effective.xml").origin, .syntheticRaster)
            XCTAssertFalse(synthetic.withCFIResource("effective.xml").canResolveCFIs)
        }
    }

    func testOnlySelectedSyntheticRasterDocumentsAreExemptFromTextCFIs() throws {
        var book = Book()
        book.add(href: "image.png", id: "image", mediaType: "image/png", Book.image(width: 20, height: 20))
        book.add(href: "image-source.json", id: "image-source", mediaType: "application/json", Data("{}".utf8), item: "fallback='image'")
        book.add(href: "text-source.json", id: "text-source", mediaType: "application/json", Data("{}".utf8), item: "fallback='text'")
        book.resource("text.xhtml", id: "text", mediaType: "application/xhtml+xml", Data(Book.xhtml(body: "<p>Authored fallback</p>").utf8))
        book.add(href: "svg-source.json", id: "svg-source", mediaType: "application/json", Data("{}".utf8), item: "fallback='svg'")
        book.resource("drawing.svg", id: "svg", mediaType: "image/svg+xml", Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><rect width='20' height='20'/></svg>".utf8))
        let built = try Build(book)
        XCTAssertEqual(built.sections.map { $0.document.origin }, [.syntheticRaster, .syntheticRaster, .authored, .authored])
        XCTAssertTrue(built[2].document.canResolveCFIs)
        XCTAssertTrue(built[3].document.canResolveCFIs)
        var result = outcome(built)
        let rasterPaths = ["EPUB/image.png", "EPUB/image-source.json"]
        XCTAssertEqual(result.cfiUnavailable, rasterPaths, "the raw outcome still reports every unavailable CFI")
        XCTAssertEqual(result.syntheticRasterDocuments, rasterPaths)
        XCTAssertTrue(result.unexpectedCFIUnavailable.isEmpty)
        XCTAssertNil(result.withheldUnsupportedMedia)
        let authoredPaths = ["EPUB/text-source.json", "EPUB/svg-source.json"]
        result.cfiUnavailable += authoredPaths
        XCTAssertEqual(result.unexpectedCFIUnavailable, authoredPaths, "an authored fallback's CFI loss remains a policy failure")
        XCTAssertTrue(result.withheld.isEmpty)
    }

    func testUnsupportedForeignChainsAreDisclosedButFailedSupportedCandidatesStillFailPolicy() throws {
        var book = Book()
        book.add(href: "dtbook.xml", id: "dtbook", mediaType: "application/x-dtbook+xml", Data("<dtbook>Unavailable</dtbook>".utf8))
        book.add(href: "bad-image.bin", id: "bad-image", mediaType: "image/x-unknown", Data("not an image".utf8))
        book.add(href: "bad-svg.svg", id: "bad-svg", mediaType: "image/svg+xml", Data("<html><body>Not SVG</body></html>".utf8))
        book.add(href: "unsafe-source.json", id: "unsafe-source", mediaType: "application/json", Data("{}".utf8), item: "fallback='unsafe'")
        book.resource("unsafe.xhtml", id: "unsafe", mediaType: "application/xhtml+xml", Data("<!DOCTYPE html [<!ENTITY x 'unsafe'>]><html xmlns='http://www.w3.org/1999/xhtml'><body>&x;</body></html>".utf8))
        book.add(href: "missing-source.json", id: "missing-source", mediaType: "application/json", Data("{}".utf8), item: "fallback='missing'")
        book.manifest += "<item id='missing' href='missing.xhtml' media-type='application/xhtml+xml'/>"
        let built = try Build(book)
        XCTAssertTrue(built.sections.allSatisfy { $0.report.withheld })
        XCTAssertTrue(built.sections.allSatisfy { $0.specText == "This section could not be shown." })
        let result = outcome(built)
        XCTAssertEqual(result.withheld.count, 5, "all omissions remain in the raw outcome")
        XCTAssertEqual(result.withheldUnsupportedMedia, ["EPUB/dtbook.xml"])
        XCTAssertEqual(Set(result.unexpectedWithheld.keys), Set(["EPUB/bad-image.bin", "EPUB/bad-svg.svg", "EPUB/unsafe-source.json", "EPUB/missing-source.json"]))
        XCTAssertNil(result.syntheticRasterDocuments)
    }

    func testSyntheticRasterClassificationUsesTheImageDeclarationWhenFallbackIDsShareAPath() throws {
        let image = Book.image(width: 20, height: 20)
        var book = Book()
        book.add(href: "shared.bin", id: "source", mediaType: "application/x-foreign", image, item: "fallback='image'")
        book.resource("shared.bin", id: "image", mediaType: "image/png", image)
        let built = try Build(book)
        XCTAssertEqual(built[0].document.origin, .syntheticRaster)
        let result = outcome(built)
        XCTAssertEqual(result.cfiUnavailable, ["EPUB/shared.bin"])
        XCTAssertEqual(result.syntheticRasterDocuments, ["EPUB/shared.bin"])
        XCTAssertTrue(result.unexpectedCFIUnavailable.isEmpty)
    }

    func testUnaffectedOutcomeJSONDoesNotAcquireEmptyClassificationFields() throws {
        let result = Outcome(fixture: "authored", verdict: .valid, ids: [])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("syntheticRasterDocuments"))
        XCTAssertFalse(encoded.contains("withheldUnsupportedMedia"))
        XCTAssertTrue(encoded.contains("cfiUnavailable"))
        XCTAssertTrue(encoded.contains("withheld"))
    }
}
