import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// The package document's `metadata`: Dublin Core values, the cover, encodings and prologs.
final class PackageMetadataCoverageTests: XCTestCase {
    private static let dublinCore = "xmlns:dc=\"http://purl.org/dc/elements/1.1/\""

    /// The plain book with its whole `metadata` element replaced.
    private func book(metadata: String, attributes: String = PackageMetadataCoverageTests.dublinCore, epub2: Bool = false,
                      adding: [String: Data?] = [:], opf edit: @escaping (String) -> String = { $0 }) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.packageVariant(epub2: epub2, opf: { opf in
            let start = opf.range(of: "<metadata")!.lowerBound, end = opf.range(of: "</metadata>")!.upperBound
            return edit(opf.replacingCharacters(in: start..<end, with: "<metadata \(attributes)>\(metadata)</metadata>"))
        }, adding: adding))
    }

    // MARK: Values

    func testWhiteSpaceInMetadataValuesIsStrippedAndCollapsed() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/75")
        // EPUB Reading Systems 3.3 §5.3: "Reading systems MUST strip and collapse ASCII whitespace
        // from Dublin Core and meta element values before processing." (W3C test pkg-meta-whitespace)
        let book = try book(metadata: """

                <dc:title>
                    A  Long
                    Test\tBook
                </dc:title>
                <dc:creator>  \t           Test    Author         </dc:creator>
                <dc:language> en </dc:language>
                <dc:identifier id="uid"> test-book </dc:identifier>

            """)
        XCTAssertEqual(book.metadata.title, "A Long Test Book")
        XCTAssertEqual(book.metadata.authors, ["Test Author"])
        XCTAssertEqual(book.metadata.languages, ["en"])
        XCTAssertEqual(book.metadata.identifiers, ["test-book"])
    }

    func testTheFirstTitleIsTheMainTitleAndRepeatedElementsKeepTheirOrder() throws {
        // EPUB Reading Systems 3.3 §5.3: the first dc:title in document order is the main title,
        // whatever a title-type refinement says.
        let book = try book(metadata: """
            <dc:title/><dc:title>   </dc:title>
            <dc:title id="t1">The Short Title</dc:title><meta refines="#t1" property="title-type">short</meta>
            <dc:title id="t2">The Main Title of the Book</dc:title><meta refines="#t2" property="title-type">main</meta>
            <dc:creator id="c1">Second Writer</dc:creator><meta refines="#c1" property="display-seq">2</meta>
            <dc:creator/>
            <dc:creator id="c2">First Writer</dc:creator><meta refines="#c2" property="display-seq">1</meta>
            <dc:contributor>An Editor</dc:contributor><dc:publisher>A Press</dc:publisher>
            <dc:language>fr-CA</dc:language><dc:language>en</dc:language><dc:language></dc:language>
            <dc:identifier>urn:isbn:9780000000002</dc:identifier><dc:identifier id="uid">urn:uuid:00112233-4455-6677-8899-aabbccddeeff</dc:identifier>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta><meta property="dcterms:title">Not a Dublin Core element</meta>
            """)
        XCTAssertEqual(book.metadata.title, "The Short Title")
        XCTAssertEqual(book.metadata.authors, ["Second Writer", "First Writer"])
        XCTAssertEqual(book.metadata.languages, ["fr-CA", "en"])
        XCTAssertEqual(book.metadata.identifiers, ["urn:isbn:9780000000002", "urn:uuid:00112233-4455-6677-8899-aabbccddeeff"])
    }

    func testDublinCoreElementsAreReadUnderAnyPrefixOrADefaultNamespace() throws {
        let expected = EPUBMetadata(title: "A Test Book", authors: ["Test Author"], languages: ["en"], identifiers: ["test-book"])
        let prefixed = try book(metadata: "<d:title>A Test Book</d:title><d:creator>Test Author</d:creator><d:language>en</d:language>"
            + "<d:identifier id=\"uid\">test-book</d:identifier>", attributes: "xmlns:d=\"http://purl.org/dc/elements/1.1/\"")
        XCTAssertEqual(prefixed.metadata, expected, "another prefix")
        let dc = "xmlns=\"http://purl.org/dc/elements/1.1/\""
        let unprefixed = try book(metadata: "<title \(dc)>A Test Book</title><creator \(dc)>Test Author</creator><language \(dc)>en</language>"
            + "<identifier \(dc) id=\"uid\">test-book</identifier>", attributes: "")
        XCTAssertEqual(unprefixed.metadata, expected, "a default namespace on each element")
    }

    func testAPackageWhoseOwnElementsCarryAPrefixIsRead() throws {
        let plain = try EPUBPublication.open(data: Fixture.epub())
        let data = try Fixture.packageVariant(opf: { opf in
            var opf = opf.replacingOccurrences(of: "<package xmlns=\"http://www.idpf.org/2007/opf\"", with: "<opf:package xmlns:opf=\"http://www.idpf.org/2007/opf\"")
            for name in ["metadata", "manifest", "item", "spine", "itemref"] {
                opf = opf.replacingOccurrences(of: "<\(name)>", with: "<opf:\(name)>").replacingOccurrences(of: "<\(name) ", with: "<opf:\(name) ")
                    .replacingOccurrences(of: "</\(name)>", with: "</opf:\(name)>")
            }
            return opf.replacingOccurrences(of: "</package>", with: "</opf:package>")
        })
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.metadata, plain.metadata)
        XCTAssertEqual(book.spine, plain.spine)
        XCTAssertEqual(book.tableOfContents, plain.tableOfContents)
    }

    func testMetadataInsideTheDeprecatedDCMetadataAndXMetadataElementsIsRead() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/85")
        // OPF 2.0.1 §2.2: "Reading Systems must allow the specification of the deprecated
        // dc-metadata and x-metadata elements", as packages converted from OEBPS 1.2 still have.
        let book = try book(metadata: "<dc-metadata \(Self.dublinCore)><dc:title>An Older Book</dc:title><dc:creator>Older Author</dc:creator>"
            + "<dc:language>en</dc:language><dc:identifier id=\"uid\">older-book</dc:identifier></dc-metadata>"
            + "<x-metadata><meta name=\"cover\" content=\"cover\"/></x-metadata>", attributes: "", epub2: true,
            adding: ["OPS/cover.jpg": Data([0xFF, 0xD8, 0xFF])],
            opf: { $0.replacingOccurrences(of: "<manifest>", with: "<manifest><item id=\"cover\" href=\"cover.jpg\" media-type=\"image/jpeg\"/>") })
        XCTAssertEqual(book.metadata, EPUBMetadata(title: "An Older Book", authors: ["Older Author"], languages: ["en"], identifiers: ["older-book"]))
        XCTAssertEqual(book.cover?.path, "OPS/cover.jpg")
    }

    func testCharacterDataSectionsCommentsAndReferencesInATitle() throws {
        let book = try book(metadata: "<dc:title>Tom <![CDATA[& Jerry <3]]><!-- an editor's note --><?proof read?> &#x1F600; &amp; caf&#233; &lt;b&gt;</dc:title>"
            + "<dc:creator><![CDATA[A. <Author>]]></dc:creator><dc:language>en</dc:language><dc:identifier id=\"uid\">test-book</dc:identifier>")
        XCTAssertEqual(book.metadata.title, "Tom & Jerry <3 \u{1F600} & caf\u{E9} <b>")
        XCTAssertEqual(book.metadata.authors, ["A. <Author>"])
    }

    func testTitlesKeepLettersBeyondTheBasicPlaneCombiningMarksAndMixedDirections() throws {
        // A mathematical letter and a family emoji (surrogate pairs in UTF-16, the second joined
        // by zero-width joiners), a decomposed accent, Hebrew, Arabic and Japanese.
        let title = "\u{1D518}nicode e\u{301}te\u{301} \u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{645}\u{631}\u{62D}\u{628}\u{627} \u{65E5}\u{672C}\u{8A9E} "
            + "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let metadata = "<dc:title>\(title)</dc:title><dc:creator>\u{5DB}\u{5D5}\u{5EA}\u{5D1}</dc:creator><dc:language>he</dc:language>"
            + "<dc:identifier id=\"uid\">test-book</dc:identifier>"
        let utf8 = try book(metadata: metadata)
        XCTAssertEqual(Array(utf8.metadata.title.unicodeScalars), Array(title.unicodeScalars))
        XCTAssertEqual(utf8.metadata.authors, ["\u{5DB}\u{5D5}\u{5EA}\u{5D1}"])
        var files = try Fixture.files()
        let opf = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: title)
        for (name, bytes) in [("little-endian", try XCTUnwrap(opf.data(using: .utf16))),
                              ("big-endian", Data([0xFE, 0xFF]) + (try XCTUnwrap(opf.data(using: .utf16BigEndian))))] {
            files["OPS/book.opf"] = bytes
            let book = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertEqual(Array(book.metadata.title.unicodeScalars), Array(title.unicodeScalars), name)
            XCTAssertEqual(book.spine.count, 2, name)
        }
    }

    func testAPackageWithoutMetadataOpensWithNone() throws {
        let book = try EPUBPublication.open(data: Fixture.packageVariant(opf: { opf in
            let start = opf.range(of: "<metadata")!.lowerBound, end = opf.range(of: "</metadata>")!.upperBound
            return opf.replacingCharacters(in: start..<end, with: "")
        }))
        XCTAssertEqual(book.metadata, EPUBMetadata(title: ""))
        XCTAssertNil(book.cover)
        XCTAssertEqual(book.spine.count, 2)
    }

    func testAnyPackageVersionIsRead() throws {
        // EPUB Reading Systems 3.3 has a reader attempt older versions (W3C test
        // pkg-version-backward uses "0"); a version this library does not know is no reason to refuse.
        for version in ["version=\"0\"", "version=\"2.0\"", "version=\"3.1\"", "version=\"4.0\"", "version=\"\"", ""] {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(opf: { $0.replacingOccurrences(of: "version=\"3.0\"", with: version) }))
            XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter", version)
        }
    }

    // MARK: Cover

    private func coverBook(items: String, meta: String = "", epub2: Bool = false) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.packageVariant(epub2: epub2, opf: {
            $0.replacingOccurrences(of: "<manifest>", with: "<manifest>" + items).replacingOccurrences(of: "</metadata>", with: meta + "</metadata>")
        }, adding: ["OPS/images/old.jpg": Data([1]), "OPS/images/new.jpg": Data([2])]))
    }

    func testTheCoverImagePropertyWinsOverTheLegacyCoverMeta() throws {
        let old = "<item id=\"old\" href=\"images/old.jpg\" media-type=\"image/jpeg\"/>"
        let new = "<item id=\"new\" href=\"images/new.jpg\" media-type=\"image/jpeg\" properties=\"  svg\n\tcover-image \"/>"
        let meta = "<meta name=\"cover\" content=\"old\"/>"
        XCTAssertEqual(try coverBook(items: old + new, meta: meta).cover?.path, "OPS/images/new.jpg", "both")
        XCTAssertEqual(try coverBook(items: new + old, meta: meta).cover?.path, "OPS/images/new.jpg", "both, in the other order")
        XCTAssertEqual(try coverBook(items: old + new).cover?.id, "new", "the property alone")
        XCTAssertEqual(try coverBook(items: old, meta: meta).cover?.id, "old", "the meta alone, in an EPUB 3 package")
        XCTAssertNil(try coverBook(items: old).cover, "neither")
    }

    func testTheLegacyCoverMetaNamesAManifestItemById() throws {
        let items = "<item id=\"old\" href=\"images/old.jpg\" media-type=\"image/jpeg\"/><item id=\"new\" href=\"images/new.jpg\" media-type=\"image/jpeg\"/>"
        XCTAssertEqual(try coverBook(items: items, meta: "<meta name=\"cover\" content=\"new\"/>", epub2: true).cover?.path, "OPS/images/new.jpg")
        XCTAssertEqual(try coverBook(items: items, meta: "<meta content=\"old\" name=\"cover\"/>", epub2: true).cover?.id, "old",
                       "attributes in the order calibre writes them")
        XCTAssertEqual(try coverBook(items: items, meta: "<meta name=\"cover\" content=\"new\"></meta><meta name=\"calibre:series\" content=\"old\"/>",
                                     epub2: true).cover?.id, "new", "among other metas")
        XCTAssertNil(try coverBook(items: items, meta: "<meta name=\"cover\" content=\"absent\"/>", epub2: true).cover, "an id no item has")
        XCTAssertNil(try coverBook(items: items, meta: "<meta name=\"cover\"/>", epub2: true).cover, "no content")
    }

    // MARK: Encodings and prologs

    func testDocumentsThatStartWithAByteOrderMarkAreRead() throws {
        for epub2 in [false, true] {
            var files = try Fixture.files(epub2: epub2)
            let plain = try EPUBPublication.open(data: Fixture.archive(files))
            for path in ["META-INF/container.xml", "OPS/book.opf", "OPS/nav.xhtml", "OPS/toc.ncx"] {
                let text = String(decoding: files[path]!, as: UTF8.self).replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: "")
                files[path] = Data([0xEF, 0xBB, 0xBF]) + Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n" + text).utf8)
            }
            let book = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertEqual(book.metadata, plain.metadata)
            XCTAssertEqual(book.tableOfContents, plain.tableOfContents)
            XCTAssertEqual(book.spine, plain.spine)
        }
    }

    func testEveryPackageDocumentMayBeUTF16() throws {
        for epub2 in [false, true] {
            var files = try Fixture.files(epub2: epub2)
            let plain = try EPUBPublication.open(data: Fixture.archive(files))
            for path in ["META-INF/container.xml", "OPS/book.opf", "OPS/nav.xhtml", "OPS/toc.ncx"] {
                let text = String(decoding: files[path]!, as: UTF8.self).replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: "")
                files[path] = try XCTUnwrap(("<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + text).data(using: .utf16))
            }
            let book = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertEqual(book.metadata, plain.metadata)
            XCTAssertEqual(book.tableOfContents, plain.tableOfContents)
            XCTAssertEqual(book.spine, plain.spine)
        }
    }

    func testAPackageDocumentInItsDeclaredLatin1IsRead() throws {
        // EPUB asks for UTF-8 or UTF-16, but packages converted long ago declare Latin-1.
        var files = try Fixture.files(epub2: true)
        let opf = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n" + String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: "D\u{E9}j\u{E0} vu \u{AB}\u{A0}encore\u{A0}\u{BB}")
        files["OPS/book.opf"] = try XCTUnwrap(opf.data(using: .isoLatin1))
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).metadata.title, "D\u{E9}j\u{E0} vu \u{AB}\u{A0}encore\u{A0}\u{BB}")
    }

    func testAnEPUB2PackageWithItsHistoricalDoctypesIsRead() throws {
        // Neither DTD is fetched; without an internal subset neither is a declaration to refuse.
        let plain = try EPUBPublication.open(data: Fixture.epub(epub2: true))
        let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, opf: {
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE package PUBLIC \"+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN\"\n"
                + "  \"http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd\">\n" + $0
        }, ncx: {
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\"\n"
                + "  \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\">\n" + $0
        }))
        XCTAssertEqual(book.metadata, plain.metadata)
        XCTAssertEqual(book.tableOfContents, plain.tableOfContents)
    }

    func testAControlCharacterInATitleOrAnNCXLabelReadsAsASpace() throws {
        // doc/architecture.md: a C0 control XML forbids "reads as a space in an ASCII-compatible document".
        let plain = try EPUBPublication.open(data: Fixture.epub(epub2: true))
        let data = try Fixture.packageVariant(epub2: true, opf: { $0.replacingOccurrences(of: "A Test Book", with: "A\u{0C}Test\u{1F}Book") },
                                              ncx: { $0.replacingOccurrences(of: "First Chapter", with: "First\u{01}Chapter") })
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.metadata.title, "A Test Book")
        XCTAssertEqual(book.tableOfContents, plain.tableOfContents)
    }

    func testAControlCharacterInAUTF16DocumentIsNotRepaired() throws {
        var files = try Fixture.files()
        let opf = String(decoding: files["OPS/book.opf"]!, as: UTF8.self).replacingOccurrences(of: "A Test Book", with: "A\u{0C}Test Book")
        files["OPS/book.opf"] = try XCTUnwrap(opf.data(using: .utf16))
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("OPS/book.opf"))
        }
    }
}
