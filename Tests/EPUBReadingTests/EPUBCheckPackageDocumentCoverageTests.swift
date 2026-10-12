import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// The package document constructs EPUBCheck's scenarios check (`epub3/05-package-document`,
/// `03-resources`, `06-layouts`, `09-media-overlays`, `D-vocabularies`, `epub2/opf-*`), as a
/// reader meets them: valid ones are read, invalid ones are read past or refused with an
/// `EPUBPublicationError`.
final class EPUBCheckPackageDocumentCoverageTests: XCTestCase {
    /// The standard fixture's package document with parts replaced.
    private func package(version: String = "3.0", attributes: String = "", metadata: String? = nil, manifest: String? = nil,
                         spine: String? = nil, after: String = "") -> String {
        let metadata = metadata ?? "<dc:title>A Test Book</dc:title><dc:creator>Test Author</dc:creator><dc:language>en</dc:language><dc:identifier id=\"uid\">test-book</dc:identifier>"
        let manifest = manifest ?? """
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>\
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            """
        let spine = spine ?? "<spine toc=\"ncx\"><itemref idref=\"one\"/><itemref idref=\"two\"/></spine>"
        return """
            <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="uid" \(attributes)>\
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\(metadata)</metadata>\
            <manifest>\(manifest)</manifest>\(spine)\(after)</package>
            """
    }

    private func open(_ opf: String, _ overrides: [String: String] = [:]) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.epub(overrides: overrides.merging(["OPS/book.opf": opf]) { first, _ in first }))
    }

    // MARK: Identifiers

    func testAManifestIdentifierWithSurroundingWhitespaceIsTheIdentifierWithoutIt() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/80")
        // EPUBCheck accepts these (its issue 332): `id` and `idref` are XML IDs and ID
        // references, whose values are whitespace-normalized.
        let opf = package(
            manifest: """
                <item id=" one " href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>\
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                """,
            spine: "<spine toc=\"ncx\"><itemref idref=\"one\"/><itemref idref=\"\n  two\t\"/></spine>")
        let book: EPUBPublication
        do { book = try open(opf) } catch { return XCTFail("refused: \(error)") }
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(book.spine.map(\.resource.id), ["one", "two"])
    }

    func testAnItemrefNamingNoManifestItemIsATypedRefusal() throws {
        XCTAssertThrowsError(try open(package(spine: "<spine><itemref idref=\"one\"/><itemref idref=\"missing\"/></spine>"))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("Spine idref"))
        }
    }

    func testAManifestItemWithoutAMediaTypeIsATypedRefusal() throws {
        XCTAssertThrowsError(try open(package(manifest: "<item id=\"one\" href=\"one.xhtml\"/><item id=\"two\" href=\"two.xhtml\" media-type=\"application/xhtml+xml\"/>"))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("Manifest item"))
        }
    }

    // MARK: Metadata

    func testMetadataValuesCollapseTheirWhitespace() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/75")
        // EPUB 3.3, 5.5.2: "Whitespace within these element values is not significant. Sequences
        // of one or more whitespace characters are collapsed to a single space during processing."
        let book = try open(package(metadata: """
            <dc:title>
                A   Test
                Book
            </dc:title>
            <dc:creator>Test\tAuthor,
                Esq.</dc:creator>
            <dc:language> en </dc:language><dc:identifier id="uid"> test-book </dc:identifier>
            """))
        XCTAssertEqual(book.metadata.title, "A Test Book")
        XCTAssertEqual(book.metadata.authors, ["Test Author, Esq."])
        XCTAssertEqual(book.metadata.languages, ["en"])
        XCTAssertEqual(book.metadata.identifiers, ["test-book"])
    }

    func testTheFirstTitleIsTheTitleWhateverItsRefinementsSay() throws {
        // EPUB Reading Systems 3.3, 5.3: "Reading systems MUST recognize the first dc:title
        // element in document order as the main title of the EPUB publication".
        let book = try open(package(metadata: """
            <dc:title id="t1">The First Title</dc:title><dc:title id="t2">The Main Title</dc:title><dc:title id="t3" xml:lang="fr">Le titre</dc:title>\
            <meta refines="#t1" property="title-type">subtitle</meta><meta refines="#t2" property="title-type">main</meta>\
            <meta refines="#t2" property="display-seq">1</meta><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>\
            <dc:language>en</dc:language><dc:identifier id="uid">test-book</dc:identifier>
            """))
        XCTAssertEqual(book.metadata.title, "The First Title")
    }

    func testCreatorsLanguagesAndIdentifiersKeepDocumentOrderAndLeaveOutOtherElements() throws {
        let book = try open(package(metadata: """
            <dc:identifier>urn:isbn:9780000000002</dc:identifier><dc:title>A Test Book</dc:title>\
            <dc:creator id="c1" opf:role="aut" opf:file-as="Second, Author">Author Second</dc:creator><dc:contributor>An Editor</dc:contributor>\
            <dc:creator id="c2">Author First</dc:creator><dc:publisher>A Press</dc:publisher><dc:language>fr-CA</dc:language>\
            <dc:language>en</dc:language><dc:identifier id="uid">urn:uuid:0e0e0e0e-1111-2222-3333-444444444444</dc:identifier>\
            <meta refines="#c2" property="role" scheme="marc:relators">aut</meta><meta refines="#c2" property="display-seq">1</meta>\
            <dc:date>2026</dc:date><dc:subject>Testing</dc:subject><dc:description>A description.</dc:description><dc:rights>None.</dc:rights>
            """))
        XCTAssertEqual(book.metadata.authors, ["Author Second", "Author First"])
        XCTAssertEqual(book.metadata.languages, ["fr-CA", "en"])
        XCTAssertEqual(book.metadata.identifiers, ["urn:isbn:9780000000002", "urn:uuid:0e0e0e0e-1111-2222-3333-444444444444"])
    }

    func testEmptyMetadataValuesAreLeftOut() throws {
        let book = try open(package(metadata: """
            <dc:title>  </dc:title><dc:title>The Second Title</dc:title><dc:creator/><dc:creator> \n </dc:creator><dc:creator>Test Author</dc:creator>\
            <dc:language/><dc:identifier id="uid">test-book</dc:identifier>
            """))
        XCTAssertEqual(book.metadata.title, "The Second Title")
        XCTAssertEqual(book.metadata.authors, ["Test Author"])
        XCTAssertEqual(book.metadata.languages, [])
    }

    func testAPackageWithoutMetadataStillOpensWithEmptyFacts() throws {
        let opf = """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>\
            </manifest><spine><itemref idref="one"/></spine></package>
            """
        let book = try open(opf)
        XCTAssertEqual(book.metadata, EPUBMetadata(title: ""))
        XCTAssertTrue(book.tableOfContents.isEmpty)
        XCTAssertNil(book.cover)
    }

    func testLinksCollectionsBindingsAndToursAreReadPast() throws {
        let book = try open(package(
            metadata: """
                <dc:title>A Test Book</dc:title><dc:language>en</dc:language><dc:identifier id="uid">test-book</dc:identifier>\
                <link rel="record" href="meta/record.xml" media-type="application/marc"/><link rel="dcterms:conformsTo" href="http://www.idpf.org/epub/a11y/accessibility-20170105.html#wcag-aa"/>\
                <meta property="schema:accessMode">textual</meta><meta name="generator" content="a test"/>
                """,
            after: """
                <guide/><bindings><mediaType media-type="application/x-demo" handler="one"/></bindings>\
                <collection role="http://example.org/roles/group"><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">A Group Title</dc:title></metadata><link href="one.xhtml"/></collection>\
                <tours><tour id="t" title="A Tour"><site title="Stop" href="one.xhtml"/></tour></tours>
                """))
        XCTAssertEqual(book.metadata.title, "A Test Book", "a collection's own title is not the book's")
        XCTAssertEqual(book.spine.count, 2)
        XCTAssertTrue(book.landmarks.isEmpty)
    }

    // MARK: Forms of the document

    func testPrefixedPackageElementsAreRead() throws {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opf:package xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="uid">
              <opf:metadata><dc:title>A Prefixed Book</dc:title><dc:creator opf:role="aut">Test Author</dc:creator><dc:language>en</dc:language>
                <dc:identifier id="uid" opf:scheme="UUID">test-book</dc:identifier><opf:meta name="cover" content="one"/></opf:metadata>
              <opf:manifest><opf:item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
                <opf:item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><opf:item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></opf:manifest>
              <opf:spine toc="ncx"><opf:itemref idref="one"/><opf:itemref idref="two" linear="no"/></opf:spine>
              <opf:guide><opf:reference type="text" title="Start" href="two.xhtml"/></opf:guide>
            </opf:package>
            """
        let book = try open(opf)
        XCTAssertEqual(book.metadata, EPUBMetadata(title: "A Prefixed Book", authors: ["Test Author"], languages: ["en"], identifiers: ["test-book"]))
        XCTAssertEqual(book.spine.map(\.isLinear), [true, false])
        XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter")
        XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["text"], title: "Start", href: "OPS/two.xhtml")])
        XCTAssertEqual(book.cover?.id, "one")
    }

    func testAPackageDocumentWithAByteOrderMarkOrInUTF16IsRead() throws {
        let opf = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + package(metadata: "<dc:title>Bücher — 本</dc:title><dc:language>de</dc:language><dc:identifier id=\"uid\">test-book</dc:identifier>")
        var files = try Fixture.files()
        files["OPS/book.opf"] = Data([0xEF, 0xBB, 0xBF]) + Data(opf.utf8)
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).metadata.title, "Bücher — 本", "UTF-8 with a byte order mark")
        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
            let wide = opf.replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"UTF-16\"")
            let mark = encoding == .utf16LittleEndian ? Data([0xFF, 0xFE]) : encoding == .utf16BigEndian ? Data([0xFE, 0xFF]) : Data()
            files["OPS/book.opf"] = mark + (try XCTUnwrap(wide.data(using: encoding)))
            let book = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertEqual(book.metadata.title, "Bücher — 本", "\(encoding)")
            XCTAssertEqual(book.spine.count, 2, "\(encoding)")
        }
    }

    func testEPUB2DocumentsWithTheirPublicDoctypesAreRead() throws {
        // External identifiers every EPUB 2 toolchain writes: none is fetched, none has a subset.
        var files = try Fixture.files(epub2: true)
        files["OPS/book.opf"] = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE package PUBLIC \"+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN\" \"http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd\">\n".utf8)
            + files["OPS/book.opf"]!
        files["OPS/toc.ncx"] = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\"\n  \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\">\n".utf8)
            + files["OPS/toc.ncx"]!
        files["META-INF/container.xml"] = Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n".utf8)
            + Data(String(decoding: files["META-INF/container.xml"]!, as: UTF8.self).replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: "").utf8)
        let book = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(book.metadata.title, "A Test Book")
        XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter")
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, "OPS/two.xhtml")
    }

    func testAPackageDocumentInADeclaredLegacyEncodingIsReadInThatEncoding() throws {
        // RSC-028 for EPUBCheck (only UTF-8 and UTF-16 are allowed), and what older Windows
        // toolchains wrote. The XML declaration names the encoding, so nothing is guessed.
        for (name, encoding) in [("ISO-8859-1", String.Encoding.isoLatin1), ("windows-1252", .windowsCP1252)] {
            let opf = "<?xml version=\"1.0\" encoding=\"\(name)\"?>\n"
                + package(metadata: "<dc:title>Café Zürich</dc:title><dc:creator>Æsop Ñandú</dc:creator><dc:language>fr</dc:language><dc:identifier id=\"uid\">test-book</dc:identifier>")
            var files = try Fixture.files()
            files["OPS/book.opf"] = try XCTUnwrap(opf.data(using: encoding))
            let book = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertEqual(book.metadata.title, "Café Zürich", name)
            XCTAssertEqual(book.metadata.authors, ["Æsop Ñandú"], name)
        }
    }

    // MARK: Manifest

    func testAManifestHrefWithUnencodedSpacesAndLettersNamesTheFile() throws {
        // PKG-010 and RSC-020 for EPUBCheck, and common: the href is written as the file is named.
        let manifest = """
            <item id="one" href="text files/chapter one é.xhtml" media-type="application/xhtml+xml"/>\
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            """
        let nav = String(decoding: try Fixture.files()["OPS/nav.xhtml"]!, as: UTF8.self)
            .replacingOccurrences(of: "one.xhtml#start", with: "text files/chapter one é.xhtml#start")
        let book = try open(package(manifest: manifest, spine: "<spine><itemref idref=\"one\"/></spine>"),
                            ["OPS/text files/chapter one é.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Found.</p></body></html>", "OPS/nav.xhtml": nav])
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/text files/chapter one é.xhtml"])
        XCTAssertEqual(book.spine.map(\.resource.href), ["OPS/text%20files/chapter%20one%20%C3%A9.xhtml"])
        XCTAssertEqual(book.tableOfContents.first?.href, "OPS/text%20files/chapter%20one%20%C3%A9.xhtml#start")
        XCTAssertTrue(String(decoding: try book.data(for: book.spine[0].resource), as: UTF8.self).contains("Found."))
    }

    func testAManifestHrefWithAStrayPercentSignIsATypedRefusal() throws {
        let manifest = "<item id=\"one\" href=\"100%.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        XCTAssertThrowsError(try open(package(manifest: manifest, spine: "<spine><itemref idref=\"one\"/></spine>"), ["OPS/100%.xhtml": "<html/>"])) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("100%.xhtml"))
        }
    }

    func testManifestPropertiesAreSeparatedByAnyWhitespace() throws {
        let book = try open(package(manifest: """
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml" properties="  scripted\n  svg\tmathml "/>\
            <item id="two" href="two.xhtml" media-type="application/xhtml+xml" properties=""/>\
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="scripted\n nav"/>
            """, spine: "<spine><itemref idref=\"one\"/><itemref idref=\"two\"/></spine>"))
        XCTAssertEqual(book.spine[0].resource.properties, ["scripted", "svg", "mathml"])
        XCTAssertEqual(book.spine[1].resource.properties, [])
        XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter", "the navigation document is found among its other properties")
    }

    func testTheCoverImagePropertyNamesTheCoverBeforeTheEPUB2Meta() throws {
        let manifest = """
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>\
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\
            <item id="old" href="old.jpg" media-type="image/jpeg"/><item id="new" href="new.jpg" media-type="image/jpeg" properties="cover-image"/>
            """
        let metadata = "<dc:title>A Test Book</dc:title><dc:language>en</dc:language><dc:identifier id=\"uid\">test-book</dc:identifier><meta content=\"old\" name=\"cover\"/>"
        let images = ["OPS/old.jpg": "old", "OPS/new.jpg": "new"]
        XCTAssertEqual(try open(package(metadata: metadata, manifest: manifest, spine: "<spine><itemref idref=\"one\"/></spine>"), images).cover?.path, "OPS/new.jpg")
        let epub2 = manifest.replacingOccurrences(of: " properties=\"cover-image\"", with: "")
        XCTAssertEqual(try open(package(version: "2.0", metadata: metadata, manifest: epub2, spine: "<spine><itemref idref=\"one\"/></spine>"), images).cover?.path,
                       "OPS/old.jpg")
        XCTAssertNil(try open(package(manifest: epub2, spine: "<spine><itemref idref=\"one\"/></spine>"), images).cover, "neither")
    }

    func testARemoteManifestResourceIsLeftOutOfTheBook() throws {
        // Valid EPUB 3 (audio, video and fonts may be remote). Nothing is fetched, and the item
        // is left out as doc/architecture.md says.
        let manifest = """
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml" properties="remote-resources"/>\
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\
            <item id="audio" href="https://example.invalid/audio/one.mp4" media-type="audio/mp4"/>
            """
        let book = try open(package(manifest: manifest, spine: "<spine><itemref idref=\"one\"/></spine>"))
        XCTAssertEqual(book.resources.map(\.id), ["one", "nav"])
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml"])
        XCTAssertEqual(book.spine[0].resource.properties, ["remote-resources"])
        XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter")
    }

    func testAManifestHrefWithAQueryNamesTheFileBeforeIt() throws {
        // RSC-033 for EPUBCheck. The query cannot change which entry is meant.
        let manifest = "<item id=\"one\" href=\"one.xhtml?version=2\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        let book = try open(package(manifest: manifest, spine: "<spine><itemref idref=\"one\"/></spine>"))
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml"])
        XCTAssertEqual(book.spine[0].resource.href, "OPS/one.xhtml")
        XCTAssertTrue(String(decoding: try book.data(for: book.spine[0].resource), as: UTF8.self).contains("Opening words"))
    }

    func testAManifestHrefDifferingInCaseFromItsEntryNamesThatEntry() throws {
        // Archive names are case-sensitive, and a file system that is not hides the mismatch from
        // a book's author: the one entry that differs only in case is the one meant.
        let manifest = "<item id=\"one\" href=\"One.XHTML\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        let book = try open(package(manifest: manifest, spine: "<spine><itemref idref=\"one\"/></spine>"))
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml"])
        XCTAssertTrue(String(decoding: try book.data(for: book.spine[0].resource), as: UTF8.self).contains("Opening words"))
        XCTAssertEqual(book.tableOfContents.first?.href, "OPS/one.xhtml#start", "the contents entry names the same resource")
    }

    func testMediaOverlayDocumentsAndTheirAudioAreOrdinaryResources() throws {
        // Media overlays are outside the API; a book that has them reads as any other.
        let manifest = """
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml" media-overlay="one-overlay"/>\
            <item id="one-overlay" href="overlays/one.smil" media-type="application/smil+xml"/><item id="audio" href="audio/one.mp3" media-type="audio/mpeg"/>\
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            """
        let metadata = """
            <dc:title>A Narrated Book</dc:title><dc:language>en</dc:language><dc:identifier id="uid">test-book</dc:identifier>\
            <meta property="media:duration" refines="#one-overlay">0:00:12.500</meta><meta property="media:duration">0:00:12.500</meta>\
            <meta property="media:narrator">A Narrator</meta><meta property="media:active-class">-epub-media-overlay-active</meta>
            """
        let smil = """
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0"><body><par id="p1">\
            <text src="../one.xhtml#start"/><audio src="../audio/one.mp3" clipBegin="0s" clipEnd="12.5s"/></par></body></smil>
            """
        let book = try open(package(metadata: metadata, manifest: manifest, spine: "<spine><itemref idref=\"one\"/></spine>"),
                            ["OPS/overlays/one.smil": smil, "OPS/audio/one.mp3": "not really audio"])
        XCTAssertEqual(book.metadata.title, "A Narrated Book")
        XCTAssertEqual(book.resources.map(\.mediaType).sorted(), ["application/smil+xml", "application/xhtml+xml", "application/xhtml+xml", "audio/mpeg"])
        XCTAssertEqual(String(decoding: try book.data(at: "OPS/overlays/one.smil"), as: UTF8.self), smil)
    }

    // MARK: Spine

    func testSpineItemLayoutOverridesApplyInBothDirections() throws {
        let fixed = "<dc:title>A Test Book</dc:title><dc:language>en</dc:language><dc:identifier id=\"uid\">test-book</dc:identifier><meta property=\"rendition:layout\">pre-paginated</meta>"
        let overridden = try open(package(metadata: fixed, spine: """
            <spine><itemref idref="one" properties="page-spread-left rendition:layout-reflowable"/><itemref idref="two" properties="rendition:spread-none"/></spine>
            """))
        XCTAssertEqual(overridden.spine.map(\.layout), [.reflowable, .prePaginated])
        let reflowable = try open(package(spine: """
            <spine><itemref idref="one"/><itemref idref="two" properties="  rendition:layout-pre-paginated\n rendition:page-spread-center"/></spine>
            """))
        XCTAssertEqual(reflowable.spine.map(\.layout), [.reflowable, .prePaginated])
        let stated = fixed.replacingOccurrences(of: "pre-paginated", with: "reflowable")
        XCTAssertEqual(try open(package(metadata: stated)).spine.map(\.layout), [.reflowable, .reflowable])
    }

    func testThePageProgressionDirectionIsReadAndAnythingElseIsTheDefault() throws {
        for (value, expected) in [("rtl", EPUBPageProgression.rtl), ("ltr", .ltr), ("default", .default), ("sideways", .default), ("", .default)] {
            let book = try open(package(spine: "<spine page-progression-direction=\"\(value)\"><itemref idref=\"one\"/></spine>"))
            XCTAssertEqual(book.pageProgression, expected, value)
        }
        XCTAssertEqual(try open(package()).pageProgression, .default)
    }

    func testOnlyLinearNoMakesASpineItemNonlinear() throws {
        let book = try open(package(spine: """
            <spine><itemref idref="one" linear="no"/><itemref idref="two" linear="yes"/><itemref idref="nav"/><itemref idref="one" linear="no"/></spine>
            """))
        XCTAssertEqual(book.spine.map(\.isLinear), [false, true, true, false])
        XCTAssertEqual(book.spine.map(\.resource.id), ["one", "two", "nav", "one"], "a repeated item keeps each occurrence")
    }

    func testASpineOfOnlyNonlinearItemsStillOpens() throws {
        let book = try open(package(spine: "<spine><itemref idref=\"one\" linear=\"no\"/><itemref idref=\"two\" linear=\"no\"/></spine>"))
        XCTAssertEqual(book.spine.map(\.isLinear), [false, false])
    }

    // MARK: Navigation named by the package

    func testAnEPUB3PackageWithoutANavigationDocumentFallsBackToItsNCX() throws {
        let manifest = """
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>\
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            """
        let book = try open(package(manifest: manifest))
        XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter")
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, "OPS/two.xhtml")
        let neither = try open(package(manifest: manifest, spine: "<spine><itemref idref=\"one\"/></spine>"))
        XCTAssertTrue(neither.tableOfContents.isEmpty, "an NCX the spine does not name is not read")
    }
}
