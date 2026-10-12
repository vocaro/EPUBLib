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

    func testNamedCharacterReferencesUnderAnOEBOrNCXDoctypeDoNotVanish() throws {
        // As EPUB 2 era tools wrote them. The XML parser reports no text and no error for a name
        // it has no declaration for once an external subset is named, and neither DTD is read.
        let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, opf: {
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE package PUBLIC \"+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN\"\n"
                + "  \"http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd\">\n"
                + $0.replacingOccurrences(of: "A Test Book", with: "Les Mis&eacute;rables").replacingOccurrences(of: "Test Author", with: "Fran&ccedil;ois&nbsp;P.")
        }, ncx: {
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\"\n"
                + "  \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\">\n" + $0.replacingOccurrences(of: "First Chapter", with: "Don&rsquo;t&nbsp;Panic")
        }))
        XCTAssertEqual(book.metadata.title, "Les Mis\u{E9}rables")
        XCTAssertEqual(book.metadata.authors, ["Fran\u{E7}ois\u{A0}P."])
        XCTAssertEqual(book.tableOfContents.first?.title, "Don\u{2019}t\u{A0}Panic")
    }

    func testBytesThatSpellAReferenceInsideAnotherEncodingsCharactersAreLeftAlone() throws {
        // In ISO-2022-JP the three characters below are the bytes 30 26, 70 69, 3B 33: `&pi;` runs
        // across them. The named-reference rewrite reads bytes as ASCII, so it is kept from a
        // document whose declared encoding does not keep ASCII bytes for ASCII characters (#185).
        let title = "\u{611B}\u{97C8}\u{5C71}"
        var files = try Fixture.files()
        let opf = "<?xml version=\"1.0\" encoding=\"ISO-2022-JP\"?>\n" + String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: title)
        let encoded = try XCTUnwrap(opf.data(using: .iso2022JP))
        XCTAssertNotNil(encoded.range(of: Data("&pi;".utf8)), "the fixture holds the bytes of a reference")
        files["OPS/book.opf"] = encoded
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).metadata.title, title)
        // An encoding that does keep them is still rewritten: Latin-1, as old converters declare.
        let latin = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n<!DOCTYPE package PUBLIC \"+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN\" "
            + "\"http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd\">\n" + String(decoding: try Fixture.files()["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: "D\u{E9}j\u{E0}&nbsp;vu &mdash; encore")
        files["OPS/book.opf"] = try XCTUnwrap(latin.data(using: .isoLatin1))
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).metadata.title, "D\u{E9}j\u{E0}\u{A0}vu \u{2014} encore")
    }

    func testNamedCharacterReferencesUnderTheOEBPackageDoctypeAreDecoded() throws {
        // OEB 1.2's package DTD declares XHTML's character entities and EPUB 2 era tools used
        // them. The DTD is never read, and under its DOCTYPE the XML parser reports no text for a
        // name it has no declaration for, in element content or in an attribute value.
        let oebPackage = "<!DOCTYPE package PUBLIC \"+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN\" \"http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd\">"
        let opf = String(decoding: try Fixture.files(epub2: true)["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: "Les Mis&eacute;rables")
            .replacingOccurrences(of: "Test Author", with: "Fran&ccedil;ois&nbsp;Mauriac &amp; Cie")
            .replacingOccurrences(of: "</package>", with: "<guide><reference type=\"text\" title=\"D&eacute;but &ndash; 1\" href=\"one.xhtml\"/></guide></package>")
        let documents = [Data((oebPackage + opf).utf8), Data(opf.utf8),
                         try XCTUnwrap(("<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + oebPackage + opf).data(using: .utf16))]
        for document in documents {
            let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, adding: ["OPS/book.opf": document]))
            XCTAssertEqual(book.metadata.title, "Les Mis\u{E9}rables")
            XCTAssertEqual(book.metadata.authors, ["Fran\u{E7}ois\u{A0}Mauriac & Cie"])
            XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["text"], title: "D\u{E9}but \u{2013} 1", href: "OPS/one.xhtml")])
        }
    }

    func testTheDTDADoctypeNamesIsNotRead() throws {
        // A DTD on this disk declares a name of its own. Were the file ever read, its replacement
        // text would stand in the title, whatever a reference to that name reads as otherwise.
        //
        // This is no coverage of the reference rewrite: no change to the rewrite, or to how
        // `XMLParser` is set up, can fail it. The parser does not read the file whatever it is
        // told: with `shouldResolveExternalEntities` set, under each
        // `externalEntityResolvingPolicy`, or with the file among its `allowedExternalEntityURLs`.
        // The test trips only if the parser is replaced or something that loads DTDs is added.
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dtd = directory.appending(path: "package.dtd")
        try Data("<!ENTITY local \"READ\">".utf8).write(to: dtd)
        let data = try Fixture.packageVariant(epub2: true, opf: {
            "<!DOCTYPE package SYSTEM \"\(dtd.absoluteString)\">" + $0.replacingOccurrences(of: "A Test Book", with: "A Test&local; Book")
        })
        let title: String
        do { title = try EPUBPublication.open(data: data).metadata.title } catch EPUBPublicationError.invalidXML("OPS/book.opf") { return }
        XCTAssertFalse(title.contains("READ"), title)
    }

    func testBytesThatSpellAReferenceInsideAShiftedRunAreTheCharactersTheirEncodingSays() throws {
        // ISO-2022-JP, ISO-2022-KR and HZ switch a run of 7-bit bytes to two-byte characters, where
        // the bytes of `&pi;` or `&ne;` are parts of kanji, hangul or hanzi and not a reference to
        // decode. Such a document is read exactly as its encoding says.
        let escape: UInt8 = 0x1B
        let titles: [(encoding: String, bytes: [UInt8], text: String)] = [
            ("ISO-2022-JP", [escape, 0x24, 0x42, 0x30, 0x26, 0x70, 0x69, 0x3B, 0x33, escape, 0x28, 0x42], "\u{611B}\u{97C8}\u{5C71}"),
            ("ISO-2022-JP", [escape, 0x24, 0x42, 0x24, 0x26, 0x6E, 0x65, 0x3B, 0x7E, escape, 0x28, 0x42], "\u{3046}\u{922C}\u{6642}"),
            ("ISO-2022-KR", [0x0E, 0x30, 0x26, 0x70, 0x69, 0x3B, 0x33, 0x0F], "\u{AC09}\u{65CF}\u{BE99}"),
            ("HZ-GB-2312", Array("~{".utf8) + [0x30, 0x26, 0x70, 0x69, 0x3B, 0x33] + Array("~}".utf8), "\u{5509}\u{75D6}\u{6000}"),
        ]
        for (encoding, bytes, text) in titles {
            for epub2 in [false, true] {
                var files = try Fixture.files(epub2: epub2)
                // The package's title, and the first label of the document the contents come from.
                for (path, plain) in [("OPS/book.opf", "A Test Book"),
                                      epub2 ? ("OPS/toc.ncx", "First Chapter") : ("OPS/nav.xhtml", "First <em>Chapter</em>")] {
                    let parts = String(decoding: files[path]!, as: UTF8.self).components(separatedBy: plain)
                    guard parts.count == 2 else { return XCTFail("\(plain) in \(path)") }
                    files[path] = Data("<?xml version=\"1.0\" encoding=\"\(encoding)\"?>\(parts[0])".utf8) + Data(bytes) + Data(parts[1].utf8)
                }
                let book = try EPUBPublication.open(data: Fixture.archive(files))
                XCTAssertEqual(book.metadata.title, text, "\(encoding), EPUB \(epub2 ? 2 : 3)")
                XCTAssertEqual(book.tableOfContents.first?.title, text, "\(encoding), EPUB \(epub2 ? 2 : 3)")
            }
        }
    }

    private static let oebDoctype = "<!DOCTYPE package PUBLIC \"+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN\" \"http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd\">"
    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    func testNamedCharacterReferencesAreDecodedInAUTF8PackageThatHoldsATildeAndBrace() throws {
        // `~{` opens a two-byte run in HZ. The parser reads by the encoding the XML declaration
        // names, UTF-8 without one, whatever bytes follow: here a LaTeX accent in a description is
        // plain text, and the title's reference is a reference, with a DOCTYPE or without.
        let opf = String(decoding: try Fixture.files(epub2: true)["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: "Les Mis&eacute;rables")
            .replacingOccurrences(of: "<dc:language>", with: "<dc:description>Printed in Espa\\~{n}a.</dc:description><dc:language>")
        let prologs = [Data(), Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n".utf8),
                       Data("<?xml version = '1.0' encoding = 'utf8' ?>".utf8),
                       Self.byteOrderMark + Data("<?xml version=\"1.0\"?>".utf8),
                       Self.byteOrderMark + Data("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>".utf8),
                       // A processing instruction, not a declaration.
                       Data("<?xml-stylesheet href=\"package.css\"?>".utf8)]
        for prolog in prologs {
            for doctype in [Self.oebDoctype, ""] {
                let document = prolog + Data((doctype + opf).utf8)
                let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, adding: ["OPS/book.opf": document]))
                XCTAssertEqual(book.metadata.title, "Les Mis\u{E9}rables", String(decoding: prolog, as: UTF8.self) + doctype)
            }
        }
    }

    func testAStrayEscapeOrShiftControlInAUTF8PackageLeavesItsNamedReferencesToDecode() throws {
        // ESC, SO and SI switch character sets in the ISO-2022 encodings. In a UTF-8 document each
        // is one more control XML forbids, read as a space, and the bytes around it mean the same.
        for control in ["\u{1B}", "\u{0E}", "\u{0F}"] {
            for doctype in [Self.oebDoctype, ""] {
                let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, opf: {
                    doctype + $0.replacingOccurrences(of: "A Test Book", with: "Les Mis&eacute;rables")
                        .replacingOccurrences(of: "Test Author", with: "Victor\(control)Hugo")
                }))
                XCTAssertEqual(book.metadata.title, "Les Mis\u{E9}rables", "\(control.unicodeScalars.first!.value) \(doctype)")
                XCTAssertEqual(book.metadata.authors, ["Victor Hugo"], "\(control.unicodeScalars.first!.value) \(doctype)")
            }
        }
    }

    func testNamedCharacterReferencesAreDecodedInADeclaredSingleByteEncoding() throws {
        // ISO 8859's parts and the Windows code pages keep every byte below 0x80 for ASCII, so a
        // reference in one is what its bytes spell, and a byte above is the letter the encoding
        // says. The declared name decides, in each listed spelling: `~{` in the text does not.
        let documents: [(declaration: String, letters: [UInt8], read: String)] = [
            ("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>", [0xE7], "\u{E7}"),
            ("<?xml version='1.0' encoding='iso_8859-15'?>", [0xA4], "\u{20AC}"),
            ("<?xml version=\"1.0\" encoding=\"latin1\" standalone=\"no\"?>", [0xE7], "\u{E7}"),
            ("<?xml version = \"1.0\" encoding = \"Windows-1252\" ?>", [0x93, 0xE7, 0x94], "\u{201C}\u{E7}\u{201D}"),
            ("<?xml version=\"1.0\" encoding=\"CP1251\"?>", [0xC6], "\u{416}"),
            ("<?xml version=\"1.0\" encoding=\"x-cp1250\"?>", [0x8A], "\u{160}"),
            ("<?xml version=\"1.0\" encoding=\"US-ASCII\"?>", [], ""),
        ]
        let opf = String(decoding: try Fixture.files(epub2: true)["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: "Les Mis&eacute;rables &mdash; I")
            .replacingOccurrences(of: "<dc:language>", with: "<dc:description>Printed in Espa\\~{n}a.</dc:description><dc:language>")
        let parts = opf.components(separatedBy: " Author")
        guard parts.count == 2 else { return XCTFail("Test Author in the package") }
        for (declaration, letters, read) in documents {
            let document = Data((declaration + Self.oebDoctype + parts[0]).utf8) + Data(letters) + Data((" Author" + parts[1]).utf8)
            let book = try EPUBPublication.open(data: Fixture.packageVariant(epub2: true, adding: ["OPS/book.opf": document]))
            XCTAssertEqual(book.metadata.title, "Les Mis\u{E9}rables \u{2014} I", declaration)
            XCTAssertEqual(book.metadata.authors, ["Test\(read) Author"], declaration)
        }
    }

    func testBytesThatSpellAReferenceAreLeftAloneInAnEncodingNotKnownToKeepASCII() throws {
        // SCSU and LMBCS spend the bytes after a tag byte on one character, with none of the
        // controls or `~{` that shift other encodings: the `&` after the tag, and in LMBCS the `p`
        // too, belong to that character and what follows is text. Only a declared encoding known
        // to keep ASCII has its references rewritten, however the declaration is spelled; one too
        // long to be read to its end may name any encoding.
        let scsu: [UInt8] = [0x05, 0x26] + Array("pi; and more".utf8), scsuText = "\u{2026}pi; and more"
        let documents: [(prolog: Data, bytes: [UInt8], text: String)] = [
            (Data("<?xml version=\"1.0\" encoding=\"SCSU\"?>".utf8), scsu, scsuText),
            (Data("<?xml version='1.0' encoding='scsu' standalone='yes'?>".utf8), scsu, scsuText),
            (Data("<?xml\tversion = \"1.0\"\n  encoding\t=\r\n\"SCSU\" ?>".utf8), scsu, scsuText),
            (Self.byteOrderMark + Data("<?xml version=\"1.0\" encoding=\"SCSU\"?>".utf8), scsu, scsuText),
            (Data(("<?xml version=\"1.0\"" + String(repeating: " ", count: 4096) + "encoding=\"SCSU\"?>").utf8), scsu, scsuText),
            (Data("<?xml version=\"1.0\" encoding=\"LMBCS-1\"?>".utf8), [0x14, 0x26] + Array("pi; and more".utf8), "\u{2670}i; and more"),
        ]
        for (index, (prolog, bytes, text)) in documents.enumerated() {
            for epub2 in [false, true] {
                var files = try Fixture.files(epub2: epub2)
                // The package's title, and the first label of the document the contents come from.
                for (path, plain) in [("OPS/book.opf", "A Test Book"),
                                      epub2 ? ("OPS/toc.ncx", "First Chapter") : ("OPS/nav.xhtml", "First <em>Chapter</em>")] {
                    let parts = String(decoding: files[path]!, as: UTF8.self).components(separatedBy: plain)
                    guard parts.count == 2 else { return XCTFail("\(plain) in \(path)") }
                    files[path] = prolog + Data(parts[0].utf8) + Data(bytes) + Data(parts[1].utf8)
                }
                let book = try EPUBPublication.open(data: Fixture.archive(files))
                XCTAssertEqual(book.metadata.title, text, "document \(index), EPUB \(epub2 ? 2 : 3)")
                XCTAssertEqual(book.tableOfContents.first?.title, text, "document \(index), EPUB \(epub2 ? 2 : 3)")
            }
        }
    }

    /// The plain book with `prolog` put before its package document and before the document its
    /// contents come from, and with `bytes` for the package's title and that document's first
    /// label: the two texts as they are read.
    private func titleAndFirstLabel(prolog: Data, bytes: [UInt8], epub2: Bool) throws -> [String?] {
        var files = try Fixture.files(epub2: epub2)
        for (path, plain) in [("OPS/book.opf", "A Test Book"),
                              epub2 ? ("OPS/toc.ncx", "First Chapter") : ("OPS/nav.xhtml", "First <em>Chapter</em>")] {
            let parts = String(decoding: files[path]!, as: UTF8.self).components(separatedBy: plain)
            guard parts.count == 2 else { XCTFail("\(plain) in \(path)"); return [] }
            files[path] = prolog + Data(parts[0].utf8) + Data(bytes) + Data(parts[1].utf8)
        }
        let book = try EPUBPublication.open(data: Fixture.archive(files))
        return [book.metadata.title, book.tableOfContents.first?.title]
    }

    func testAControlCharacterInsideADeclarationDoesNotHideTheEncodingItNames() throws {
        // The parser refuses a control character inside an XML declaration, whose bytes read as
        // they stand name no encoding: a pseudo-attribute `\u{0B}encoding` or `encoding\u{0B}`, or
        // no declaration at all. Read once more with a space for the control, the declaration is
        // well formed and names HZ, where the bytes of `&pi;` are parts of hanzi. What is rewritten
        // is decided by the bytes that are parsed, so these are read as their encoding says.
        let hanzi = Array("~{0&pi;3~}".utf8), text = "\u{5509}\u{75D6}\u{6000}"
        let prologs = ["<?xml version=\"1.0\"\u{0B}encoding=\"HZ-GB-2312\"?>",
                       "<?xml\u{0C}version=\"1.0\" encoding=\"HZ-GB-2312\"?>",
                       "<?xml version=\"1.0\" encoding\u{0B}=\"HZ-GB-2312\"?>"]
        for prolog in prologs {
            for epub2 in [false, true] {
                XCTAssertEqual(try titleAndFirstLabel(prolog: Data(prolog.utf8), bytes: hanzi, epub2: epub2), [text, text],
                               "\(prolog.debugDescription), EPUB \(epub2 ? 2 : 3)")
            }
        }
    }

    func testAControlCharacterInsideAUTF8DeclarationLeavesNamedReferencesToDecode() throws {
        // The other way round. With a control character between `=` and the quote, the declaration
        // as it stands is none to decide a rewrite by, and the parser refuses it. Read once more
        // with a space there it is well formed and names UTF-8, or no encoding: that parse
        // succeeds, and the title's reference is decoded as in any UTF-8 package, with a DOCTYPE
        // or without.
        let prologs = ["<?xml version=\u{0C}\"1.0\"?>", "<?xml version=\"1.0\" encoding=\u{0B}\"UTF-8\"?>"]
        for prolog in prologs {
            for doctype in [Self.oebDoctype, ""] {
                let data = try Fixture.packageVariant(epub2: true, opf: {
                    prolog + doctype + $0.replacingOccurrences(of: "A Test Book", with: "Les Mis&eacute;rables")
                })
                XCTAssertEqual(try EPUBPublication.open(data: data).metadata.title, "Les Mis\u{E9}rables", prolog.debugDescription + doctype)
            }
        }
    }

    func testBytesThatSpellAReferenceAreLeftAloneAfterADeclarationWrittenInEBCDIC() throws {
        // The parser takes a document that starts with `<?xm` in EBCDIC to declare itself in that
        // encoding. It converts the first 45 bytes so, here the whole declaration, and decodes the
        // rest in the encoding the declaration names: SCSU here (one that names UTF-8 it goes on
        // reading as EBCDIC, so a document that continues in UTF-8 is refused). The declaration is
        // not one this package reads, so nothing after it is rewritten: in SCSU the `&` after the
        // tag byte 0x05 belongs to one character, and `pi;` is text.
        // `<?xml version="1.0" encoding="SCSU"`, eight spaces and `?>` in code page 037.
        let declaration: [UInt8] = [0x4C, 0x6F, 0xA7, 0x94, 0x93, 0x40, 0xA5, 0x85, 0x99, 0xA2, 0x89, 0x96, 0x95, 0x7E, 0x7F, 0xF1, 0x4B, 0xF0, 0x7F,
                                    0x40, 0x85, 0x95, 0x83, 0x96, 0x84, 0x89, 0x95, 0x87, 0x7E, 0x7F, 0xE2, 0xC3, 0xE2, 0xE4, 0x7F]
            + [UInt8](repeating: 0x40, count: 8) + [0x6F, 0x6E]
        XCTAssertEqual(declaration.count, 45)
        let scsu: [UInt8] = [0x05, 0x26] + Array("pi; and more".utf8), text = "\u{2026}pi; and more"
        for epub2 in [false, true] {
            XCTAssertEqual(try titleAndFirstLabel(prolog: Data(declaration), bytes: scsu, epub2: epub2), [text, text], "EPUB \(epub2 ? 2 : 3)")
        }
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
