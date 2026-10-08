import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

final class SpineCFIsTests: XCTestCase {
    private let container = #"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#

    private func section(_ publication: EPUBPublication, _ index: Int) throws -> ContentDocument {
        let item = publication.spine[index].resource
        return try ContentDocument.parse(publication.data(for: item), path: item.path)
    }

    func testBasesComeFromThePackageDocument() throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        XCTAssertEqual(try SpineCFIs(publication: publication).bases, ["epubcfi(/6/2)", "epubcfi(/6/4)"])
    }

    func testSpineAndItemrefIDsAreAsserted() throws {
        var files = try Fixture.files()
        let opf = try XCTUnwrap(String(data: try XCTUnwrap(files["OPS/book.opf"]), encoding: .utf8))
        files["OPS/book.opf"] = Data(opf.replacingOccurrences(of: #"<spine toc="ncx"><itemref idref="one"/>"#,
                                                              with: #"<spine toc="ncx" id="s"><itemref idref="one" id="ref[1]"/>"#).utf8)
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(try SpineCFIs(publication: publication).bases, ["epubcfi(/6[s]/2[ref^[1^]])", "epubcfi(/6[s]/4)"])
    }

    func testFullCFIsJoinTheBaseAndTheLocalPath() throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let spine = try SpineCFIs(publication: publication)
        let document = try section(publication, 1)
        let text = try XCTUnwrap(document.nodes.first { $0.isText && $0.text.hasPrefix("The unique destination") })
        let position = spine.cfi(spineIndex: 1, start: DOMPosition(text, 4), end: DOMPosition(text, 4), in: document)
        XCTAssertEqual(position, "epubcfi(/6/4!/4/4/1:4)")
        let range = spine.cfi(spineIndex: 1, start: DOMPosition(text, 4), end: DOMPosition(text, 22), in: document)
        XCTAssertEqual(range, "epubcfi(/6/4!/4/4,/1:4,/1:22)")
        let resolved = try XCTUnwrap(spine.resolve(range))
        XCTAssertEqual(resolved.spineIndex, 1)
        XCTAssertEqual(resolved.localPath, "/4/4,/1:4,/1:22")
        let positions = try XCTUnwrap(EPUBCFI.resolve(localPath: resolved.localPath, in: document))
        XCTAssertEqual([positions.start, positions.end], [DOMPosition(text, 4), DOMPosition(text, 22)])
        XCTAssertEqual(spine.resolve("epubcfi(/6/2)")?.spineIndex, 0)
        XCTAssertEqual(spine.resolve("epubcfi(/6/2)")?.localPath, "", "a bare spine CFI names the section itself")
    }

    /// foliate's retry ignores the itemref ID assertion, so Epub.js's manifest-ID assertions and
    /// stale IDs still resolve by index.
    func testItemrefIDAssertionsAreIgnored() throws {
        let spine = try SpineCFIs(publication: EPUBPublication.open(data: Fixture.epub()))
        XCTAssertEqual(spine.resolve("epubcfi(/6/4[one]!/4/2)")?.spineIndex, 1)
        XCTAssertEqual(spine.resolve("epubcfi(/6/2[nowhere]!/4/2)")?.spineIndex, 0)
        for cfi in ["epubcfi(/6/6!/4/2)", "epubcfi(/6/3)", "epubcfi(/4/2)", "epubcfi(!/4)", "", "garbage", "epubcfi(/6/2,/4)"] {
            XCTAssertNil(spine.resolve(cfi), cfi)
        }
    }

    func testAnUnreadablePackageFallsBackToFoliatesFakeBases() throws {
        var files = try Fixture.files()
        files["META-INF/container.xml"] = Data(container.replacingOccurrences(of: #" media-type="application/oebps-package+xml""#,
                                                                              with: "").utf8)
        let spine = try SpineCFIs(publication: EPUBPublication.open(data: Fixture.archive(files)))
        XCTAssertEqual(spine.bases, ["epubcfi(/6/2)", "epubcfi(/6/4)"])
        XCTAssertEqual(spine.resolve("epubcfi(/6/4[x]!/4/2/1:3)")?.spineIndex, 1)
        XCTAssertEqual(spine.resolve("epubcfi(/6/4[x]!/4/2/1:3)")?.localPath, "/4/2/1:3")
        XCTAssertNil(spine.resolve("epubcfi(/6/3)"))
        XCTAssertNil(spine.resolve("epubcfi(/6/6)"))
        XCTAssertEqual(SpineCFIs(package: nil, spineCount: 3).bases, ["epubcfi(/6/2)", "epubcfi(/6/4)", "epubcfi(/6/6)"])
    }
}
