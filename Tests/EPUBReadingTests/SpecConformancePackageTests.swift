import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBText
import Foundation
import XCTest

/// One requirement of EPUB 3.3 or EPUB Reading Systems 3.3 per test, for what a reading system
/// does before it shows anything: the container, the package document and the navigation
/// document. Each names the requirement it holds the publication model to.
final class SpecConformancePackageTests: XCTestCase {
    private typealias Book = Fixture.SpecBook

    private func twoChapters() -> Book {
        var book = Book()
        book.add("one", body: "<h1 id=\"start\">One</h1><p>The first chapter.</p>")
        book.add("two", body: "<h1>Two</h1><p>The second chapter.</p>")
        return book
    }

    private func flatten(_ items: [EPUBNavigationItem]) -> [EPUBNavigationItem] { items.flatMap { [$0] + flatten($0.children) } }

    // MARK: Open Container Format (RS 3.3 section 4)

    /// RS 4.1.3: the package document of the first `rootfile` is the default rendition, in
    /// whatever directory and under whatever name the container gives it.
    func testTheFirstRootfileNamesThePackageWhereverItLives() throws {
        for (directory, name) in [("", "package.opf"), ("OEBPS", "content.opf"), ("a/deep/Folder", "Book.OPF"), ("EPUB", "volume.xml")] {
            var book = twoChapters()
            book.directory = directory; book.packageName = name
            let publication = try EPUBPublication.open(data: book.archive())
            let prefix = directory.isEmpty ? "" : directory + "/"
            XCTAssertEqual(publication.spine.map(\.resource.path), [prefix + "one.xhtml", prefix + "two.xhtml"], directory)
            XCTAssertEqual(publication.tableOfContents.map(\.href), [prefix + "one.xhtml", prefix + "two.xhtml"], directory)
            XCTAssertTrue(String(decoding: try publication.data(for: publication.spine[1].resource), as: UTF8.self).contains("second chapter"))
        }
        var first = twoChapters(), decoy = twoChapters()
        decoy.metadata = "<dc:title>The Decoy</dc:title><dc:language>en</dc:language>"
        decoy.directory = "ALT"
        decoy.sections.removeLast()
        first.rootFiles = decoy.archiveFiles.filter { $0.key.hasPrefix("ALT/") }
        first.container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
                <rootfile full-path="ALT/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """
        let publication = try EPUBPublication.open(data: first.archive())
        XCTAssertEqual(publication.metadata.title, "A Conformance Book", "the first rootfile, not the last")
        XCTAssertEqual(publication.spine.count, 2)
    }

    /// RS 4.1.3: files in META-INF a reading system has no use for must not make it fail, and an
    /// ancillary `manifest.xml` is never used in place of the package document's manifest.
    func testMetaInfFilesAReadingSystemDoesNotUseAreIgnored() throws {
        var book = twoChapters()
        let plain = try EPUBPublication.open(data: book.archive())
        book.rootFiles = [
            "META-INF/manifest.xml": Data("""
                <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">
                  <manifest:file-entry manifest:full-path="EPUB/three.xhtml" manifest:media-type="application/xhtml+xml"/>
                </manifest:manifest>
                """.utf8),
            "META-INF/metadata.xml": Data("<unknown xmlns=\"http://example.org/ns\"><title>Another Title</title></unknown>".utf8),
            "META-INF/signatures.xml": Data("<signatures xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"/>".utf8),
            "META-INF/com.apple.ibooks.display-options.xml": Data("<display_options><platform name=\"*\"><option name=\"specified-fonts\">true</option></platform></display_options>".utf8),
            "META-INF/calibre_bookmarks.txt": Data("encoding=json+base64:W10=".utf8),
            "META-INF/not xml at all": Data([0x00, 0xFF, 0x3C, 0x26]),
            "EPUB/three.xhtml": Data(Book.xhtml(body: "<p>Listed only by the ancillary manifest.</p>").utf8),
        ]
        let publication = try EPUBPublication.open(data: book.archive())
        XCTAssertEqual(publication.metadata, plain.metadata)
        XCTAssertEqual(publication.spine, plain.spine)
        XCTAssertEqual(publication.resources, plain.resources)
        XCTAssertEqual(publication.tableOfContents, plain.tableOfContents)
    }

    /// EPUB 3.3 section 5.6.2 and RS 4.1.1: manifest hrefs are URLs relative to the package
    /// document, so they may climb out of its directory (inside the container), carry `.`
    /// segments and percent-encode what a URL cannot hold; navigation hrefs are relative to the
    /// navigation document.
    func testManifestAndNavigationHrefsResolveAsRelativeURLs() throws {
        var book = Book()
        book.directory = "EPUB/package"
        book.add(href: "../text/chapter%20one.xhtml", id: "one", mediaType: "application/xhtml+xml",
                 Data(Book.xhtml(body: "<p id=\"a b\">Chapter with a space in its name.</p>").utf8), path: "../text/chapter one.xhtml")
        book.add(href: "./text/./na%C3%AFve-%E7%AB%A0.xhtml", id: "two", mediaType: "application/xhtml+xml",
                 Data(Book.xhtml(body: "<p>Chapter with accented and Han letters in its name.</p>").utf8), path: "text/naïve-章.xhtml")
        book.add(href: "text/100%25%23.xhtml", id: "three", mediaType: "application/xhtml+xml",
                 Data(Book.xhtml(body: "<p>Chapter with reserved characters in its name.</p>").utf8), path: "text/100%#.xhtml")
        book.navigationItem = nil
        book.manifest = "\n    <item id=\"nav\" href=\"../nav/toc.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        book.files["../nav/toc.xhtml"] = Data(Book.xhtml(title: "Contents", body: """
            <nav epub:type="toc"><ol>
              <li><a href="../text/chapter%20one.xhtml#a%20b">One</a></li>
              <li><a href="../package/text/na%C3%AFve-%E7%AB%A0.xhtml">Two</a></li>
              <li><a href="./../package/text/100%25%23.xhtml#top">Three</a></li>
            </ol></nav>
            """).utf8)
        var files = book.archiveFiles
        // `Book` joins paths textually; the archive holds them normalized.
        for (path, data) in files where path.contains("/../") {
            files[path] = nil
            files[path.replacingOccurrences(of: "EPUB/package/../", with: "EPUB/")] = data
        }
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(publication.spine.map(\.resource.path),
                       ["EPUB/text/chapter one.xhtml", "EPUB/package/text/naïve-章.xhtml", "EPUB/package/text/100%#.xhtml"])
        XCTAssertEqual(publication.spine.map(\.resource.href),
                       ["EPUB/text/chapter%20one.xhtml", "EPUB/package/text/na%C3%AFve-%E7%AB%A0.xhtml", "EPUB/package/text/100%25%23.xhtml"])
        XCTAssertEqual(publication.tableOfContents.map(\.href), [
            "EPUB/text/chapter%20one.xhtml#a%20b", "EPUB/package/text/na%C3%AFve-%E7%AB%A0.xhtml", "EPUB/package/text/100%25%23.xhtml#top",
        ])
        for item in publication.spine {
            XCTAssertTrue(String(decoding: try publication.data(for: item.resource), as: UTF8.self).contains("Chapter with"), item.resource.path)
            XCTAssertEqual(item.resource.href.removingPercentEncoding, item.resource.path)
        }
    }

    /// RS 4.2: a container split into segments, or using a compression method other than
    /// Deflate (or none), is in error.
    func testASplitOrNonDeflateContainerIsRefused() throws {
        let whole = try twoChapters().archive()
        XCTAssertNoThrow(try EPUBPublication.open(data: whole))
        // The first segment of a spanned archive: the spanning marker, then entries with no
        // central directory.
        let segment = Data([0x50, 0x4B, 0x07, 0x08]) + whole.prefix(whole.count / 2)
        XCTAssertThrowsError(try EPUBPublication.open(data: segment), "a split archive's first segment") {
            guard case .invalidArchive = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
        }
        // Method 12 (bzip2) on the package document, in its local and central headers.
        var bytes = [UInt8](whole)
        var patched = 0
        let name = Array("EPUB/package.opf".utf8)
        for index in bytes.indices.dropLast(46) where bytes[index] == 0x50 && bytes[index + 1] == 0x4B {
            let local = bytes[index + 2] == 0x03 && bytes[index + 3] == 0x04
            let central = bytes[index + 2] == 0x01 && bytes[index + 3] == 0x02
            guard local || central else { continue }
            let nameStart = index + (local ? 30 : 46)
            guard nameStart + name.count <= bytes.count, Array(bytes[nameStart..<nameStart + name.count]) == name else { continue }
            let method = index + (local ? 8 : 10)
            XCTAssertEqual(bytes[method], 8, "the fixture deflates it")
            bytes[method] = 12
            patched += 1
        }
        XCTAssertEqual(patched, 2)
        XCTAssertThrowsError(try EPUBPublication.open(data: Data(bytes)), "an entry compressed with bzip2")
    }

    // MARK: Package metadata (RS 3.3 section 5.3)

    /// RS 5.3: "Reading systems MUST strip and collapse ASCII whitespace from Dublin Core and
    /// meta element values before processing" (W3C test pkg-meta-whitespace).
    func testMetadataValuesAreStrippedAndCollapsed() throws {
        var book = twoChapters()
        book.metadata = """
            <dc:title>
                  A Long Title
                  Wrapped by Its   Editor
                </dc:title>
                <dc:creator>  \t  Ada \t  Example   </dc:creator>
                <dc:language> en </dc:language>
            """
        let metadata = try EPUBPublication.open(data: book.archive()).metadata
        XCTAssertEqual(metadata.title, "A Long Title Wrapped by Its Editor")
        XCTAssertEqual(metadata.authors, ["Ada Example"])
        XCTAssertEqual(metadata.languages, ["en"])
    }

    /// RS 5.3: the first `dc:title` in document order is the main title whatever refines it, and
    /// the first `dc:creator` the primary creator, the others following in document order.
    func testTheFirstTitleIsTheMainTitleAndCreatorsKeepDocumentOrder() throws {
        var book = twoChapters()
        book.metadata = """
            <dc:title id="t1">The Main Title</dc:title>
                <dc:title id="t2">A Subtitle</dc:title>
                <meta refines="#t2" property="title-type">main</meta>
                <meta refines="#t2" property="display-seq">1</meta>
                <meta refines="#t1" property="title-type">subtitle</meta>
                <dc:creator id="c1" xmlns:opf="http://www.idpf.org/2007/opf" opf:role="aut" opf:file-as="Zed, Zoe">Zoe Zed</dc:creator>
                <dc:creator id="c2">Abe Able</dc:creator>
                <meta refines="#c2" property="display-seq">1</meta>
                <dc:contributor>An Editor</dc:contributor>
                <dc:creator>Mia Middle</dc:creator>
                <dc:language>fr-CA</dc:language>
                <dc:language>en</dc:language>
                <dc:identifier>urn:isbn:9780000000002</dc:identifier>
            """
        let metadata = try EPUBPublication.open(data: book.archive()).metadata
        XCTAssertEqual(metadata.title, "The Main Title")
        XCTAssertEqual(metadata.authors, ["Zoe Zed", "Abe Able", "Mia Middle"])
        XCTAssertEqual(metadata.languages, ["fr-CA", "en"])
        XCTAssertEqual(metadata.identifiers, [book.identifier, "urn:isbn:9780000000002"])
    }

    /// RS 5.3 to 5.6: unrecognized `meta` expressions, manifest and spine `properties` values,
    /// collections with an unknown role and linked records must be ignored, never fatal; so
    /// must the deprecated `bindings` element.
    func testVocabularyTheReaderDoesNotKnowIsIgnored() throws {
        var book = twoChapters()
        let plain = try EPUBPublication.open(data: book.archive())
        book.packageAttributes = "prefix=\"ex: http://example.org/vocab# rendition: http://www.idpf.org/vocab/rendition/#\" xml:lang=\"en\" dir=\"ltr\""
        book.metadata += """

                <meta property="ex:shelf">Third from the left</meta>
                <meta property="unprefixed-and-unknown">value</meta>
                <meta property="schema:accessMode">textual</meta>
                <meta name="generator" content="An Imagined Tool 1.0"/>
                <meta property="rendition:flow">scrolled-continuous</meta>
                <meta property="rendition:orientation">landscape</meta>
                <meta property="rendition:spread">both</meta>
                <link rel="record" href="meta/record.xml" media-type="application/marc"/>
                <link rel="ex:unknown" href="https://example.org/record"/>
            """
        book.sections[0].item = "properties=\"ex:special future-property\""
        book.sections[1].itemref = "properties=\"ex:odd page-spread-left rendition:align-x-center\" id=\"ref-two\""
        book.manifest = "\n    <item id=\"handler\" href=\"handler.xhtml\" media-type=\"application/xhtml+xml\" properties=\"scripted\"/>"
        book.files["handler.xhtml"] = Data(Book.xhtml(body: "<p>A handler.</p>").utf8)
        book.trailer = """

              <bindings><mediaType media-type="application/x-demo" handler="handler"/></bindings>
              <collection role="http://example.org/roles/unknown"><link href="one.xhtml"/></collection>
              <collection role="index"><link href="two.xhtml"/></collection>
            """
        let publication = try EPUBPublication.open(data: book.archive())
        XCTAssertEqual(publication.metadata, plain.metadata)
        XCTAssertEqual(publication.spine.map(\.resource.path), plain.spine.map(\.resource.path))
        XCTAssertEqual(publication.spine.map(\.isLinear), [true, true])
        XCTAssertEqual(publication.spine.map(\.layout), [.reflowable, .reflowable])
        XCTAssertEqual(publication.spine[0].resource.properties, ["ex:special", "future-property"], "unknown values are kept as written")
        XCTAssertEqual(publication.tableOfContents, plain.tableOfContents)
        XCTAssertEqual(publication.pageProgression, .default)
    }

    /// RS 12 and 13: a package whose `version` is below or above 3.0 must be attempted.
    func testAPackageOfAnotherVersionIsStillRead() throws {
        for version in ["3.0", "3.1", "3.3", "4.0", "2.0", "0", "", "next"] {
            var book = twoChapters()
            book.version = version
            let publication = try EPUBPublication.open(data: book.archive())
            XCTAssertEqual(publication.spine.count, 2, version)
            XCTAssertEqual(publication.tableOfContents.map(\.title), ["one", "two"], version)
        }
    }

    /// RS 5.2: a unique identifier is not assumed unique to one publication. Two books sharing
    /// one are two publications.
    func testTwoBooksSharingAUniqueIdentifierAreDistinctPublications() throws {
        var first = twoChapters(), second = twoChapters()
        second.metadata = "<dc:title>Another Book Altogether</dc:title><dc:language>en</dc:language>"
        XCTAssertEqual(first.identifier, second.identifier)
        let one = try EPUBPublication.open(data: first.archive()), other = try EPUBPublication.open(data: second.archive())
        XCTAssertEqual(one.metadata.identifiers, other.metadata.identifiers)
        XCTAssertNotEqual(one.id, other.id)
        first.metadata += " "
        XCTAssertNotEqual(try EPUBPublication.open(data: first.archive()).id, one.id, "the fingerprint is of the bytes")
    }

    // MARK: Spine (RS 3.3 section 5.5)

    /// RS 5.5: the spine, not the manifest and not file names, gives the reading order; an
    /// itemref is linear unless it says `linear="no"`; an absent `page-progression-direction`
    /// is `default`.
    func testTheSpineGivesReadingOrderLinearityAndProgression() throws {
        var book = Book()
        for name in ["c-third", "a-notes", "d-first", "b-second"] { book.add(name, body: "<p>\(name)</p>") }
        book.spine = """
                <itemref idref="d-first" linear="yes"/>
                <itemref idref="b-second"/>
                <!-- <itemref idref="a-notes"/> -->
                <itemref idref="a-notes" linear="no"/>
                <itemref idref="c-third"/>
            """
        var publication = try EPUBPublication.open(data: book.archive())
        XCTAssertEqual(publication.spine.map(\.resource.path), ["EPUB/d-first.xhtml", "EPUB/b-second.xhtml", "EPUB/a-notes.xhtml", "EPUB/c-third.xhtml"])
        XCTAssertEqual(publication.spine.map(\.isLinear), [true, true, false, true])
        XCTAssertEqual(publication.resources.map(\.id).prefix(4), ["c-third", "a-notes", "d-first", "b-second"], "the manifest keeps its own order")
        XCTAssertEqual(publication.pageProgression, .default)
        for (written, expected) in [("rtl", EPUBPageProgression.rtl), ("ltr", .ltr), ("default", .default)] {
            book.spineAttributes = "page-progression-direction=\"\(written)\" toc=\"ncx\""
            publication = try EPUBPublication.open(data: book.archive())
            XCTAssertEqual(publication.pageProgression, expected)
        }
        for index in publication.spine.indices {
            let section = try publication.textSection(at: index)
            XCTAssertEqual(section.text, publication.spine[index].resource.id)
            XCTAssertEqual(section.isLinear, index != 2)
        }
    }

    /// RS 8.1.1.1 and 5.5.1: `rendition:layout` is `reflowable` unless the package says
    /// otherwise, and a spine item's own override takes the global value's place.
    func testRenditionLayoutIsGlobalWithSpineOverrides() throws {
        var book = Book()
        for name in ["one", "two", "three"] { book.add(name, body: "<p>\(name)</p>") }
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).spine.map(\.layout), [.reflowable, .reflowable, .reflowable])
        book.sections[1].itemref = "properties=\"rendition:layout-pre-paginated rendition:spread-none\""
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).spine.map(\.layout), [.reflowable, .prePaginated, .reflowable])
        book.metadata += "<meta property=\"rendition:layout\"> pre-paginated </meta>"
        book.sections[1].itemref = "properties=\"page-spread-left rendition:layout-reflowable\""
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).spine.map(\.layout), [.prePaginated, .reflowable, .prePaginated])
        book.metadata = book.metadata.replacingOccurrences(of: " pre-paginated ", with: "reflowable")
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).spine.map(\.layout), [.reflowable, .reflowable, .reflowable])
    }

    /// RS 5.5.1: when an itemref carries more than one override of the same property, only the
    /// first is used (W3C test fxl-spine-overrides_duplicate).
    func testTheFirstOfSeveralLayoutOverridesWins() throws {
        var book = Book()
        book.metadata += "<meta property=\"rendition:layout\">pre-paginated</meta>"
        book.add("page", body: "<p>A fixed page.</p>")
        book.add("flow", itemref: "properties=\"rendition:layout-reflowable rendition:layout-pre-paginated\"", body: "<p>Reflowable text.</p>")
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).spine.map(\.layout), [.prePaginated, .reflowable])
        book.metadata = book.metadata.replacingOccurrences(of: "pre-paginated", with: "reflowable")
        book.sections[1].itemref = "properties=\"rendition:layout-pre-paginated rendition:layout-reflowable\""
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).spine.map(\.layout), [.reflowable, .prePaginated])
    }

    // MARK: Navigation document (RS 3.3 section 7)

    /// RS 7: the links and headings of the `toc nav` are what the reader offers, in document
    /// order with their nesting; an entry may be an unlinked `span` heading its own list, and
    /// other `nav` elements are not the table of contents. EPUB 3.3 section 7.5: `hidden` has
    /// no effect on the navigation data outside the content flow.
    func testTheTableOfContentsKeepsNestingUnlinkedEntriesAndHiddenBranches() throws {
        var book = twoChapters()
        book.navigation = """
            <nav epub:type="landmarks" hidden=""><ol><li><a epub:type="bodymatter" href="one.xhtml">Start of Content</a></li></ol></nav>
            <nav><h2>Figures</h2><ol><li><a href="two.xhtml#figure">A figure</a></li></ol></nav>
            <nav epub:type="toc" id="toc" hidden="hidden" role="doc-toc">
              <h1>Contents</h1>
              <ol>
                <li><span>Part I</span>
                  <ol>
                    <li><a href="one.xhtml#start">Chapter <i>One</i></a></li>
                    <li hidden="hidden"><a href="one.xhtml">A hidden entry</a>
                      <ol><li><a href="two.xhtml" style="display: none">Deeper still</a></li></ol>
                    </li>
                  </ol>
                </li>
                <li><a href="two.xhtml">Chapter Two</a></li>
              </ol>
            </nav>
            """
        let contents = try EPUBPublication.open(data: book.archive()).tableOfContents
        XCTAssertEqual(contents, [
            EPUBNavigationItem(title: "Part I", children: [
                EPUBNavigationItem(title: "Chapter One", href: "EPUB/one.xhtml#start"),
                EPUBNavigationItem(title: "A hidden entry", href: "EPUB/one.xhtml", children: [
                    EPUBNavigationItem(title: "Deeper still", href: "EPUB/two.xhtml"),
                ]),
            ]),
            EPUBNavigationItem(title: "Chapter Two", href: "EPUB/two.xhtml"),
        ])
    }

    /// A navigation label is HTML text: a label its authoring tool wrapped or indented reads as
    /// its words separated by single spaces, as a browser renders it (and as foliate-js's
    /// `normalizeWhitespace` read it).
    func testANavigationLabelWrappedByItsAuthoringToolReadsAsCollapsedText() throws {
        var book = twoChapters()
        book.navigation = """
            <nav epub:type="toc">
              <ol>
                <li>
                  <a href="one.xhtml">
                    <span class="number">1</span>
                    <span class="title">The First
                      Chapter</span>
                  </a>
                </li>
                <li><a href="two.xhtml">Two</a></li>
              </ol>
            </nav>
            """
        let contents = try EPUBPublication.open(data: book.archive()).tableOfContents
        XCTAssertEqual(contents.map(\.title), ["1 The First Chapter", "Two"])
    }

    /// The cover image is the manifest item with the `cover-image` property (EPUB 3.3 D.4.1),
    /// or, in an EPUB 2 package, the item the `cover` meta names.
    func testTheCoverImageComesFromTheManifestPropertyOrTheEPUB2Meta() throws {
        var book = twoChapters()
        let front = Book.image(width: 8, height: 12)
        book.resource("images/front.png", id: "front", mediaType: "image/png", front)
        book.resource("images/other.jpg", id: "other", mediaType: "image/jpeg", Book.image(width: 8, height: 12, as: .jpeg), item: "properties=\"cover-image\"")
        book.metadata += "<meta name=\"cover\" content=\"front\"/>"
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).cover?.path, "EPUB/images/other.jpg", "the EPUB 3 property comes first")
        book.manifest = book.manifest.replacingOccurrences(of: " properties=\"cover-image\"", with: "")
        let legacy = try EPUBPublication.open(data: book.archive())
        XCTAssertEqual(legacy.cover?.path, "EPUB/images/front.png")
        XCTAssertEqual(legacy.cover?.mediaType, "image/png")
        XCTAssertEqual(try legacy.data(for: try XCTUnwrap(legacy.cover)), front)
        XCTAssertNil(try EPUBPublication.open(data: twoChapters().archive()).cover)
    }

    // MARK: XML processing (RS 3.3 section 3.6)

    /// RS 3.6: XML is read by a namespace-aware processor, so the prefixes a package or
    /// navigation document binds to the OPF, Dublin Core, XHTML and EPUB namespaces are its own.
    func testNamespacePrefixesAreTheDocumentsOwn() throws {
        var book = twoChapters()
        let plain = try EPUBPublication.open(data: book.archive())
        var files = book.archiveFiles
        files["EPUB/package.opf"] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <o:package xmlns:o="http://www.idpf.org/2007/opf" xmlns:elements="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="uid">
              <o:metadata>
                <elements:identifier id="uid">\(book.identifier)</elements:identifier>
                <elements:title>A Conformance Book</elements:title>
                <elements:creator>Test Author</elements:creator>
                <elements:language>en</elements:language>
              </o:metadata>
              <o:manifest>
                <o:item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
                <o:item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
                <o:item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              </o:manifest>
              <o:spine page-progression-direction="rtl"><o:itemref idref="one"/><o:itemref idref="two" linear="no"/></o:spine>
            </o:package>
            """.utf8)
        files["EPUB/nav.xhtml"] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <h:html xmlns:h="http://www.w3.org/1999/xhtml" xmlns:ops="http://www.idpf.org/2007/ops">
              <h:head><h:title>Contents</h:title></h:head>
              <h:body>
                <h:nav ops:type="toc"><h:ol><h:li><h:a href="one.xhtml">one</h:a></h:li><h:li><h:a href="two.xhtml">two</h:a></h:li></h:ol></h:nav>
                <h:nav ops:type="page-list"><h:ol><h:li><h:a href="two.xhtml#p1">1</h:a></h:li></h:ol></h:nav>
              </h:body>
            </h:html>
            """.utf8)
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(publication.metadata, plain.metadata)
        XCTAssertEqual(publication.spine.map(\.resource), plain.spine.map(\.resource))
        XCTAssertEqual(publication.spine.map(\.isLinear), [true, false])
        XCTAssertEqual(publication.pageProgression, .rtl)
        XCTAssertEqual(publication.tableOfContents, plain.tableOfContents)
        XCTAssertEqual(publication.pageList, [EPUBPageListEntry(label: "1", href: "EPUB/two.xhtml#p1")])
    }

    // MARK: Backward compatibility (RS 3.3 section 12)

    /// RS 12: an EPUB 2 publication is processed as its own specifications define: the OPF 2.0
    /// package with its DOCTYPE, the NCX the spine's `toc` attribute names (nested, in document
    /// order whatever its `playOrder`), the guide and the `cover` meta. External identifiers in
    /// the DOCTYPEs are never resolved (RS 3.6).
    func testAnEPUB2PackageWithDoctypesNCXAndGuideIsRead() throws {
        let chapter = { (title: String, text: String) in
            Data("""
                <?xml version="1.0" encoding="utf-8"?>
                <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
                <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
                <head><title>\(title)</title><link rel="stylesheet" type="text/css" href="../Styles/style.css"/></head>
                <body><h2 id="heading">\(title)</h2><p>\(text)&nbsp;&mdash;&nbsp;&copy;&nbsp;2026</p></body>
                </html>
                """.utf8)
        }
        let files: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                   <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.utf8),
            "OEBPS/content.opf": Data("""
                <?xml version="1.0" encoding="utf-8" standalone="yes"?>
                <!DOCTYPE package PUBLIC "+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN" "http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd">
                <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                    <dc:identifier id="BookId" opf:scheme="UUID">urn:uuid:2b6d9c5e-7a41-4f0b-8c3d-9e1f5a6b7c8d</dc:identifier>
                    <dc:title>An Older Book</dc:title>
                    <dc:creator opf:role="aut" opf:file-as="Writer, A.">A. Writer</dc:creator>
                    <dc:language>en-GB</dc:language>
                    <dc:date opf:event="publication">2009-05-01</dc:date>
                    <meta name="cover" content="cover-image"/>
                    <meta content="0.9.9" name="Sigil version"/>
                  </metadata>
                  <manifest>
                    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                    <item id="cover-image" href="Images/cover.png" media-type="image/png"/>
                    <item id="css" href="Styles/style.css" media-type="text/css"/>
                    <item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c1" href="Text/chapter1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="Text/chapter2.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine toc="ncx">
                    <itemref idref="cover" linear="no"/>
                    <itemref idref="c1"/>
                    <itemref idref="c2"/>
                  </spine>
                  <guide>
                    <reference type="cover" title="Cover" href="Text/cover.xhtml"/>
                    <reference type="toc" title="Table of Contents" href="Text/chapter1.xhtml#heading"/>
                    <reference type="text" title="Beginning" href="Text/chapter1.xhtml"/>
                  </guide>
                </package>
                """.utf8),
            "OEBPS/toc.ncx": Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
                <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
                <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="en">
                  <head>
                    <meta name="dtb:uid" content="urn:uuid:2b6d9c5e-7a41-4f0b-8c3d-9e1f5a6b7c8d"/>
                    <meta name="dtb:depth" content="2"/>
                  </head>
                  <docTitle><text>An Older Book</text></docTitle>
                  <docAuthor><text>A. Writer</text></docAuthor>
                  <navMap>
                    <navPoint id="navPoint-1" playOrder="3">
                      <navLabel><text>Part the First</text></navLabel>
                      <content src="Text/chapter1.xhtml"/>
                      <navPoint id="navPoint-2" playOrder="1" class="chapter">
                        <navLabel><text>Its Opening</text></navLabel>
                        <content src="Text/chapter1.xhtml#heading"/>
                      </navPoint>
                    </navPoint>
                    <navPoint id="navPoint-3" playOrder="2">
                      <navLabel><text>Part the Second</text></navLabel>
                      <content src="Text/chapter2.xhtml"/>
                    </navPoint>
                  </navMap>
                </ncx>
                """.utf8),
            "OEBPS/Images/cover.png": Book.image(width: 6, height: 9),
            "OEBPS/Styles/style.css": Data("h2 { text-align: center; }".utf8),
            "OEBPS/Text/cover.xhtml": chapter("Cover", "The cover page"),
            "OEBPS/Text/chapter1.xhtml": chapter("Chapter 1", "The first chapter"),
            "OEBPS/Text/chapter2.xhtml": chapter("Chapter 2", "The second chapter"),
        ]
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(publication.metadata, EPUBMetadata(title: "An Older Book", authors: ["A. Writer"], languages: ["en-GB"],
                                                          identifiers: ["urn:uuid:2b6d9c5e-7a41-4f0b-8c3d-9e1f5a6b7c8d"]))
        XCTAssertEqual(publication.spine.map(\.resource.path), ["OEBPS/Text/cover.xhtml", "OEBPS/Text/chapter1.xhtml", "OEBPS/Text/chapter2.xhtml"])
        XCTAssertEqual(publication.spine.map(\.isLinear), [false, true, true])
        XCTAssertEqual(publication.tableOfContents, [
            EPUBNavigationItem(title: "Part the First", href: "OEBPS/Text/chapter1.xhtml", children: [
                EPUBNavigationItem(title: "Its Opening", href: "OEBPS/Text/chapter1.xhtml#heading"),
            ]),
            EPUBNavigationItem(title: "Part the Second", href: "OEBPS/Text/chapter2.xhtml"),
        ])
        XCTAssertEqual(publication.landmarks, [
            EPUBLandmark(types: ["cover"], title: "Cover", href: "OEBPS/Text/cover.xhtml"),
            EPUBLandmark(types: ["toc"], title: "Table of Contents", href: "OEBPS/Text/chapter1.xhtml#heading"),
            EPUBLandmark(types: ["text"], title: "Beginning", href: "OEBPS/Text/chapter1.xhtml"),
        ])
        XCTAssertEqual(publication.cover?.path, "OEBPS/Images/cover.png")
        XCTAssertNil(publication.pageList)
        let text = try publication.textSection(at: 1)
        XCTAssertEqual(text.title, "Chapter 1")
        // doc/text-extraction.md: "Whitespace is normalized to single spaces": the no-break spaces too.
        XCTAssertEqual(text.text, "Chapter 1\nThe first chapter — © 2026")
        XCTAssertEqual(text.headings.map(\.text), ["Chapter 1"])
        XCTAssertFalse(text.recoveredAsHTML)
    }

    /// An EPUB 3 package keeps its NCX for older reading systems; the navigation document is
    /// the table of contents (RS 7), whatever the NCX says.
    func testTheNavigationDocumentIsPreferredToAnNCXKeptForOlderReaders() throws {
        var book = twoChapters()
        book.spineAttributes = "toc=\"ncx\""
        book.resource("toc.ncx", id: "ncx", mediaType: "application/x-dtbncx+xml", Data("""
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
              <navPoint id="n1" playOrder="1"><navLabel><text>From the NCX</text></navLabel><content src="two.xhtml"/></navPoint>
            </navMap></ncx>
            """.utf8))
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).tableOfContents.map(\.title), ["one", "two"])
        // Without a navigation document the same package falls back to its NCX.
        book.navigationItem = nil
        XCTAssertEqual(try EPUBPublication.open(data: book.archive()).tableOfContents,
                       [EPUBNavigationItem(title: "From the NCX", href: "EPUB/two.xhtml")])
    }

    /// EPUB 3.3 section 3.9 and RS 3.6: the container, package and navigation documents are XML
    /// in UTF-8 or UTF-16; a byte order mark or a UTF-16 encoding changes nothing that is read.
    func testPackageDocumentsInUTF16OrWithAByteOrderMarkAreRead() throws {
        var book = Book()
        book.metadata = "<dc:title>Größe und 日本語</dc:title><dc:creator>Zoë Example</dc:creator><dc:language>de</dc:language>"
        book.add("one", body: "<p>Eins.</p>")
        book.navigation = "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">Kapitel Ⅰ — Größe</a></li></ol></nav>"
        let plain = try EPUBPublication.open(data: book.archive())
        XCTAssertEqual(plain.metadata.title, "Größe und 日本語")
        XCTAssertEqual(plain.tableOfContents.map(\.title), ["Kapitel Ⅰ — Größe"])
        let mark = Data([0xEF, 0xBB, 0xBF])
        func utf16(_ data: Data, bigEndian: Bool) -> Data {
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"UTF-16\"")
            return Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) + text.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)!
        }
        let encodings: [(name: String, encode: (Data) -> Data)] = [
            ("a UTF-8 byte order mark", { mark + $0 }), ("UTF-16, little-endian", { utf16($0, bigEndian: false) }),
            ("UTF-16, big-endian", { utf16($0, bigEndian: true) }),
        ]
        for (name, encode) in encodings {
            var files = book.archiveFiles
            for path in ["META-INF/container.xml", "EPUB/package.opf", "EPUB/nav.xhtml"] { files[path] = encode(try XCTUnwrap(files[path])) }
            let publication = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertEqual(publication.metadata, plain.metadata, name)
            XCTAssertEqual(publication.spine, plain.spine, name)
            XCTAssertEqual(publication.tableOfContents, plain.tableOfContents, name)
        }
    }
}
