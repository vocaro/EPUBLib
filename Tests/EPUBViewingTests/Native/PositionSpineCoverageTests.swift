import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// The package half of CFIs through real publications whose package documents are laid out
/// in ways the recorded foliate packages are not.
final class PositionSpineCoverageTests: XCTestCase {
    private static let metadata = #"<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Spine</dc:title><dc:language>en</dc:language><dc:identifier id="uid">spine-book</dc:identifier></metadata>"#
    private static let manifest = #"<manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="three" href="three.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>"#

    private func package(_ children: String, version: String = "3.0") -> String {
        "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"\(version)\" unique-identifier=\"uid\">\(children)</package>"
    }

    private func open(_ opf: String) throws -> (publication: EPUBPublication, spine: SpineCFIs) {
        let third = #"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Third</title></head><body><h1 id="top">Third Chapter</h1><p id="p">A third <em>passage</em> to name.</p></body></html>"#
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": opf, "OPS/three.xhtml": third]))
        return (publication, try SpineCFIs(publication: publication))
    }

    private func document(_ publication: EPUBPublication, _ index: Int) throws -> ContentDocument {
        let resource = publication.spine[index].resource
        return try ContentDocument.parse(publication.data(for: resource), path: resource.path)
    }

    /// EPUB CFI 1.1, section 3.1.1: steps count the package document's real children, so the
    /// spine is `/6` only when it is the package's third element.
    func testBasesFollowTheSpinesPlaceAmongThePackagesChildren() throws {
        let itemrefs = #"<itemref idref="one"/><itemref idref="two"/><itemref idref="three"/>"#
        let layouts: [(String, String, String)] = [
            ("the usual order", package("\(Self.metadata)\(Self.manifest)<spine>\(itemrefs)</spine>"), "/6"),
            ("the spine first", package("<spine>\(itemrefs)</spine>\(Self.metadata)\(Self.manifest)"), "/2"),
            ("the spine second", package("\(Self.metadata)<spine>\(itemrefs)</spine>\(Self.manifest)"), "/4"),
            ("a guide before the spine", package("\(Self.metadata)\(Self.manifest)<guide><reference type=\"text\" href=\"one.xhtml\"/></guide><spine>\(itemrefs)</spine>",
                                                 version: "2.0"), "/8"),
            ("indented, with comments and instructions",
             "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- lead -->\n" + package("\n  <!-- a -->\n  \(Self.metadata)\n  <?note b?>\n  \(Self.manifest)\n  <!-- c -->\n  "
                + "<spine>\n    <!-- d -->\n    <itemref idref=\"one\"/>\n    <!-- e -->\n    <itemref idref=\"two\"/>\n    <itemref idref=\"three\"/>\n  </spine>\n") + "\n", "/6"),
        ]
        for (label, opf, spineStep) in layouts {
            let (publication, spine) = try open(opf)
            XCTAssertEqual(publication.spine.count, 3, label)
            XCTAssertEqual(spine.bases, ["epubcfi(\(spineStep)/2)", "epubcfi(\(spineStep)/4)", "epubcfi(\(spineStep)/6)"], label)
            for (index, base) in spine.bases.enumerated() {
                XCTAssertEqual(spine.resolve(base)?.spineIndex, index, "\(label) \(base)")
                XCTAssertEqual(spine.resolve(base)?.localPath, "", "\(label) \(base)")
                XCTAssertEqual(spine.resolve(EPUBCFI.joinIndirections(base, "/4/2/1:3"))?.localPath, "/4/2/1:3", label)
            }
            // The same item steps under another child of the package name no spine item.
            for other in ["/2", "/4", "/6", "/8"] where other != spineStep {
                XCTAssertNil(spine.resolve("epubcfi(\(other)/2!/4/2/1:0)"), "\(label) \(other)")
            }
            // (The odd steps before the first and after the last itemref name those itemrefs, as
            // the recorded foliate packages show; the empty chunk between two itemrefs names none.)
            for cfi in ["\(spineStep)", "\(spineStep)/0", "\(spineStep)/3", "\(spineStep)/5", "\(spineStep)/8", "\(spineStep)/9", "\(spineStep)/2/2", "/0", "/20", "!\(spineStep)/2"] {
                XCTAssertNil(spine.resolve("epubcfi(\(cfi))"), "\(label) \(cfi)")
            }
        }
    }

    /// Every CFI the library writes for a spine item resolves to that item and to the same
    /// range, with itemref and spine IDs that need escaping.
    func testEveryIssuedCFIComesBackToItsSpineItemAndRange() throws {
        let (publication, spine) = try open(package("\(Self.metadata)\(Self.manifest)<spine id=\"s(1)\" toc=\"ncx\"><itemref id=\"r[1]\" idref=\"one\"/>"
            + "<itemref idref=\"two\" id=\"r,2;x=y\" linear=\"no\"/><itemref id=\"r^3 !/4\" idref=\"three\"/></spine>"))
        XCTAssertEqual(spine.bases, ["epubcfi(/6[s^(1^)]/2[r^[1^]])", "epubcfi(/6[s^(1^)]/4[r^,2^;x^=y])", "epubcfi(/6[s^(1^)]/6[r^^3 !/4])"])
        XCTAssertEqual(publication.spine.map(\.isLinear), [true, false, true], "a nonlinear item keeps its step")
        for index in publication.spine.indices {
            let document = try document(publication, index)
            let texts = document.nodes.filter { $0.isText && $0.utf16Length > 3 && document.body?.isAncestor(of: $0) == true }
            let first = try XCTUnwrap(texts.first), last = try XCTUnwrap(texts.last)
            for (start, end) in [(DOMPosition(first, 1), DOMPosition(first, 1)), (DOMPosition(first, 1), DOMPosition(first, 3)),
                                 (DOMPosition(first), DOMPosition(last, last.utf16Length)), (DOMPosition(try XCTUnwrap(document.body)), DOMPosition(last, 2))] {
                let cfi = spine.cfi(spineIndex: index, start: start, end: end, in: document)
                XCTAssertTrue(cfi.hasPrefix("epubcfi(" + EPUBCFI.unwrap(spine.bases[index]) + "!"), cfi)
                XCTAssertTrue(EPUBCFI.isWellFormed(cfi), cfi)
                let target = try XCTUnwrap(spine.resolve(cfi), cfi)
                XCTAssertEqual(target.spineIndex, index, cfi)
                XCTAssertEqual(target.localPath, EPUBCFI.localPath(from: start, to: end, in: document), cfi)
                let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: document), cfi)
                XCTAssertEqual([resolved.start, resolved.end], [start, end], cfi)
                // The base alone orders CFIs of different spine items in spine order.
                if index > 0 {
                    let earlier = spine.cfi(spineIndex: index - 1, start: start, end: end, in: document)
                    XCTAssertEqual(EPUBCFI.compare(earlier, cfi), -1, "\(earlier) before \(cfi)")
                }
            }
        }
    }

    /// The package path resolves by its steps alone, as foliate resolved it: an itemref ID
    /// assertion is not consulted, whether it names nothing, a manifest item or another itemref.
    func testThePackagePathResolvesByItsStepsWhateverItAsserts() throws {
        let (_, spine) = try open(package("\(Self.metadata)\(Self.manifest)<spine><itemref id=\"r1\" idref=\"one\"/><itemref id=\"r2\" idref=\"two\"/>"
            + "<itemref id=\"r3\" idref=\"three\"/></spine>"))
        for (cfi, index) in [("epubcfi(/6/2[r1]!/4)", 0), ("epubcfi(/6/2[r2]!/4)", 0), ("epubcfi(/6/2[r3]!/4)", 0), ("epubcfi(/6/4[one]!/4)", 1),
                             ("epubcfi(/6/4[nothing]!/4)", 1), ("epubcfi(/6[r1]/6!/4)", 2), ("epubcfi(/6/6[]!/4)", 2), ("epubcfi(/6/6[r3;s=a]!/4)", 2),
                             ("epubcfi(/06/004[r2]!/4)", 1), ("  epubcfi(/6/4!/4)  ", 1), ("/6/4!/4", 1)] {
            XCTAssertEqual(spine.resolve(cfi)?.spineIndex, index, cfi)
            XCTAssertEqual(spine.resolve(cfi)?.localPath, "/4", cfi)
        }
        // Whatever follows the first indirection is the local path, unchanged.
        XCTAssertEqual(spine.resolve("epubcfi(/6/4[r2]!/4[body]/2[p^]1]/1:3[ab,cd;s=b])")?.localPath, "/4[body]/2[p^]1]/1:3[ab,cd;s=b]")
        XCTAssertEqual(spine.resolve("epubcfi(/6/4!/4/2!/4/6/1:0)")?.localPath, "/4/2!/4/6/1:0", "a second indirection stays in the local path")
        XCTAssertEqual(spine.resolve("epubcfi(/6/4!/4/2,/1:0,/3:5)")?.localPath, "/4/2,/1:0,/3:5")
        XCTAssertEqual(spine.resolve("epubcfi(/6/4!,/4/2/1:0,/4/6/1:5)")?.localPath, ",/4/2/1:0,/4/6/1:5", "a range over the whole document path")
    }

    /// A spine that names one resource twice is invalid (epubcheck OPF-034), but books do it.
    /// A CFI into a repeat names that repeat, the itemref its package path lands on (EPUB
    /// Reading Systems 3.3 §5.5). foliate looked the itemref's `idref` up among the spine items
    /// and named the first; the reader departs from it on purpose (#108).
    func testARepeatedSpineItemResolvesToTheItemrefItsPathLandsOn() throws {
        let (publication, spine) = try open(package("\(Self.metadata)\(Self.manifest)<spine><itemref idref=\"one\"/><itemref idref=\"two\"/>"
            + "<itemref idref=\"one\"/><itemref idref=\"three\"/></spine>"))
        XCTAssertEqual(publication.spine.count, 4)
        XCTAssertEqual(spine.bases, ["epubcfi(/6/2)", "epubcfi(/6/4)", "epubcfi(/6/6)", "epubcfi(/6/8)"])
        XCTAssertEqual(spine.resolve("epubcfi(/6/2!/4/2/1:0)")?.spineIndex, 0)
        XCTAssertEqual(spine.resolve("epubcfi(/6/6!/4/2/1:0)")?.spineIndex, 2)
        XCTAssertEqual(spine.resolve("epubcfi(/6/6!/4/2/1:0)")?.localPath, "/4/2/1:0")
        XCTAssertEqual(spine.resolve("epubcfi(/6/8!/4/2/1:0)")?.spineIndex, 3, "items after the repeat keep their own step")
        XCTAssertEqual(publication.spine[0].resource.path, publication.spine[2].resource.path, "the repeat is the same document")
    }

    func testASpineOfOneItem() throws {
        let (publication, spine) = try open(package("\(Self.metadata)\(Self.manifest)<spine><itemref idref=\"three\"/></spine>"))
        XCTAssertEqual(spine.bases, ["epubcfi(/6/2)"])
        let document = try document(publication, 0)
        let passage = try XCTUnwrap(document.nodes.first { $0.isText && $0.text == "passage" })
        let cfi = spine.cfi(spineIndex: 0, start: DOMPosition(passage, 1), end: DOMPosition(passage, 4), in: document)
        XCTAssertEqual(cfi, "epubcfi(/6/2!/4/4[p]/2,/1:1,/1:4)")
        XCTAssertEqual(spine.resolve(cfi)?.spineIndex, 0)
        XCTAssertNil(spine.resolve("epubcfi(/6/4!/4/4[p]/2,/1:1,/1:4)"))
        XCTAssertNil(spine.resolve("epubcfi(/6/0!/4)"))
    }

    /// Without a package document read as foliate read it, the bases are foliate's `/6/N`.
    func testFakeBasesCoverExactlyTheSpine() throws {
        XCTAssertEqual(SpineCFIs(package: nil, spineCount: 0).bases, [])
        XCTAssertEqual(SpineCFIs(package: nil, spineCount: -3).bases, [])
        XCTAssertNil(SpineCFIs(package: nil, spineCount: 0).resolve("epubcfi(/6/2!/4)"))
        let opf = try ContentDocument.parse(Data(package("\(Self.metadata)\(Self.manifest)<spine><itemref id=\"r1\" idref=\"one\"/><itemref idref=\"two\"/></spine>").utf8),
                                            path: "book.opf", asContent: false)
        XCTAssertEqual(SpineCFIs(package: opf, spineCount: 2).bases, ["epubcfi(/6/2[r1])", "epubcfi(/6/4)"])
        // A spine the publication read differently cannot be matched item for item.
        let mismatched = SpineCFIs(package: opf, spineCount: 3)
        XCTAssertEqual(mismatched.bases, ["epubcfi(/6/2)", "epubcfi(/6/4)", "epubcfi(/6/6)"])
        XCTAssertEqual(mismatched.resolve("epubcfi(/6/6!/4)")?.spineIndex, 2)
        XCTAssertNil(mismatched.resolve("epubcfi(/6/8!/4)"))
        XCTAssertNil(mismatched.resolve("epubcfi(/6/5!/4)"))
        XCTAssertNil(mismatched.resolve("epubcfi(/6/0!/4)"))
        // A package without a spine, or with an empty one, has nothing to index.
        for children in ["\(Self.metadata)\(Self.manifest)", "\(Self.metadata)\(Self.manifest)<spine/>", "\(Self.metadata)\(Self.manifest)<spine><!-- none --></spine>"] {
            let empty = try ContentDocument.parse(Data(package(children).utf8), path: "book.opf", asContent: false)
            XCTAssertEqual(SpineCFIs(package: empty, spineCount: 2).bases, ["epubcfi(/6/2)", "epubcfi(/6/4)"], children)
        }
    }
}
