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

    /// The plain book under `folder` in place of `OPS/`, its spine given an ID, which the bases
    /// of a package document that was read assert and the fallback's `/6/N` do not.
    private func files(in folder: String, spineID: String) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (path, data) in try Fixture.files() where path.hasPrefix("OPS/") {
            files[folder + String(path.dropFirst(4))] = path == "OPS/book.opf"
                ? Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: #"<spine toc="ncx">"#, with: #"<spine toc="ncx" id="\#(spineID)">"#).utf8) : data
        }
        return files
    }

    private func open(_ files: [String: Data], fullPath: String) throws -> EPUBPublication {
        var files = files
        files["mimetype"] = Data("application/epub+zip".utf8)
        files["META-INF/container.xml"] = Data(container.replacingOccurrences(of: "OPS/book.opf", with: fullPath).utf8)
        return try EPUBPublication.open(data: Fixture.archive(files))
    }

    /// The bases come from the package document the publication's spine was read from, however
    /// the container's `full-path` names it.
    func testARootfilePathNamesThePackageDocumentItNamesToThePublication() throws {
        let book = try files(in: "My Books/", spineID: "s")
        let plain = try SpineCFIs(publication: open(book, fullPath: "My Books/book.opf")).bases
        XCTAssertEqual(plain, ["epubcfi(/6[s]/2)", "epubcfi(/6[s]/4)"])
        for fullPath in ["My%20Books/book.opf", "%4Dy%20Books/b%6Fok.opf", "./My%20Books/text/%2E%2E/book.opf", "My Books/%2E/book.opf"] {
            XCTAssertEqual(try SpineCFIs(publication: open(book, fullPath: fullPath)).bases, plain, fullPath)
        }
        // A name that is no URL is still read as it is written.
        for folder in ["50% off #1/", "a%20b/", "%2e%2e/"] {
            let publication = try open(files(in: folder, spineID: "s"), fullPath: folder + "book.opf")
            XCTAssertEqual(publication.spine.map(\.resource.path), [folder + "one.xhtml", folder + "two.xhtml"], folder)
            XCTAssertEqual(try SpineCFIs(publication: publication).bases, plain, folder)
        }
        // With a package document under each spelling, the one the URL names is the publication's.
        let both = try files(in: "a b/", spineID: "decoded").merging(files(in: "a%20b/", spineID: "written")) { $1 }
        for (fullPath, folder, spineID) in [("a%20b/book.opf", "a b/", "decoded"), ("a%2520b/book.opf", "a%20b/", "written")] {
            let publication = try open(both, fullPath: fullPath)
            XCTAssertEqual(publication.spine.map(\.resource.path), [folder + "one.xhtml", folder + "two.xhtml"], fullPath)
            XCTAssertEqual(try SpineCFIs(publication: publication).bases, ["epubcfi(/6[\(spineID)]/2)", "epubcfi(/6[\(spineID)]/4)"], fullPath)
        }
    }

    /// A separator or dot segment of `full-path` is one whatever mark follows it, here as to the
    /// publication (https://github.com/vocaro/EPUBLib/issues/181).
    func testARootfilePathIsReadWhereAMarkFollowsASeparatorOrDotSegment() throws {
        for mark in Fixture.clusteringMarks {
            let folder = "Books/\(mark)x/"
            let book = try files(in: folder, spineID: "s")
            for fullPath in [folder + "book.opf", "Books/y/../\(mark)x/book.opf", "Books/./\(mark)x/book.opf", "Books/\(Fixture.escapingNonASCII(mark))x/book.opf"] {
                let publication = try open(book, fullPath: fullPath)
                XCTAssertEqual(publication.spine.map(\.resource.path), [folder + "one.xhtml", folder + "two.xhtml"], fullPath.debugDescription)
                XCTAssertEqual(try SpineCFIs(publication: publication).bases, ["epubcfi(/6[s]/2)", "epubcfi(/6[s]/4)"], fullPath.debugDescription)
            }
        }
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
