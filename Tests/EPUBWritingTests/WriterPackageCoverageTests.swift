import EPUBCore
import EPUBReading
import EPUBText
import EPUBWriting
import Foundation
import Testing

/// `EPUBPackageWriter.documents`: escaping, structure, validation and read-back, against
/// doc/writing.md and the EPUB 3.3 package and navigation document rules.
struct WriterPackageCoverageTests {
    private let one = WriterCoverage.chapter
    private let two = EPUBResource(id: "d", path: "EPUB/two.xhtml", mediaType: "application/xhtml+xml")

    private func generate(_ facts: EPUBPackageMetadata = WriterCoverage.facts(), resources: [EPUBResource]? = nil,
                           spine: [EPUBSpineItem]? = nil, contents: [EPUBNavigationItem]? = nil,
                           pages: [EPUBNavigationItem] = [], stylesheet: String? = nil) throws -> [EPUBPackageWriter.Document] {
        try EPUBPackageWriter.documents(metadata: facts, resources: resources ?? [one], spine: spine ?? [.init(resource: one)],
            contents: contents ?? [.init(title: "Start", href: "EPUB/one.xhtml")], pages: pages, stylesheet: stylesheet)
    }
    private func opf(_ documents: [EPUBPackageWriter.Document]) throws -> WriterXMLProbe {
        try .parse(WriterCoverage.document("EPUB/package.opf", in: documents))
    }
    private func nav(_ documents: [EPUBPackageWriter.Document]) throws -> WriterXMLProbe {
        try .parse(WriterCoverage.document("EPUB/nav.xhtml", in: documents))
    }
    /// Writes the documents and content into an archive and opens it with the reader.
    private func reopened(_ documents: [EPUBPackageWriter.Document], content: [String: Data]? = nil) async throws -> EPUBPublication {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = content ?? [one.path: WriterCoverage.xhtml("<p>Text</p>")]
        return try EPUBPublication.open(at: try await WriterCoverage.archive(documents, content: content, in: directory))
    }

    // MARK: Escaping

    @Test func metadataWithMarkupCharactersQuotesAndAstralScalarsReadsBackExactly() async throws {
        let title = "A & B <C> \"D\" 'E' ]]> &amp; &#65; \u{1F600} e\u{301} \u{5E9}\u{5DC}\u{5D5}\u{5DD}"
        let authors = ["O'Neil & <Co>", "Second \"Author\""]
        let identifier = "urn:x?a=1&b=<2>"
        let publication = try await reopened(try generate(WriterCoverage.facts(title: title, authors: authors, identifier: identifier)))
        #expect(publication.metadata.title.unicodeScalars.elementsEqual(title.unicodeScalars))
        #expect(publication.metadata.authors == authors)
        #expect(publication.metadata.identifiers == [identifier])
        #expect(publication.metadata.languages == ["en"])
    }

    // XML 1.0 cannot carry most C0 controls or U+FFFE/U+FFFF even as references, so they are dropped.
    @Test func charactersXMLCannotCarryAreRemovedSoEveryDocumentStaysWellFormed() throws {
        let dirty = "A\u{0}B\u{1}C\u{B}D\u{1F}E\u{FFFE}F\u{FFFF}G\tH\nI"
        let clean = "ABCDEFG\tH\nI"
        let facts = EPUBPackageMetadata(metadata: .init(title: dirty, authors: [dirty], languages: ["en"]), identifier: dirty,
                                        modificationDate: WriterCoverage.date, summary: dirty, keywords: [dirty])
        let documents = try generate(facts, contents: [.init(title: dirty, href: "EPUB/one.xhtml")], pages: [.init(title: dirty, href: "EPUB/one.xhtml")])
        let package = try opf(documents)
        for name in ["dc:title", "dc:creator", "dc:identifier", "dc:description", "dc:subject"] {
            #expect(package.named(name).map(\.text) == [clean], "\(name)")
        }
        #expect(try nav(documents).named("a").map(\.text) == [clean, clean])
    }

    @Test func navigationLabelsAndFragmentsAreEscapedExactlyOnce() async throws {
        let contents: [EPUBNavigationItem] = [
            .init(title: "Tom & Jerry <i>", href: "EPUB/one.xhtml#a&b"),
            .init(title: "&amp; literally \"quoted\" 'single' ]]>", href: "EPUB/one.xhtml#it's"),
        ]
        let pages = [EPUBNavigationItem(title: "<1>", href: "EPUB/one.xhtml#p&1")]
        let publication = try await reopened(try generate(contents: contents, pages: pages))
        #expect(publication.tableOfContents == contents)
        #expect(publication.pageList == [.init(label: "<1>", href: "EPUB/one.xhtml#p&1")])
    }

    // The writer takes IDs and media types as given. Whatever it accepts must be escaped, so the
    // manifest and spine still agree when read back.
    @Test func resourceIDsAndMediaTypesWithMarkupCharactersAreEscapedWhereverTheyAreWritten() async throws {
        let odd = EPUBResource(id: "a\"b'c<d>&e", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml", properties: ["x&y", "a<b"])
        let data = EPUBResource(id: "&amp;", path: "EPUB/data.bin", mediaType: "application/x-odd;v=\"1\"&<2>")
        let documents: [EPUBPackageWriter.Document]
        do { documents = try generate(resources: [odd, data], spine: [.init(resource: odd)]) } catch is EPUBWritingError { return }
        let items = try opf(documents).named("item")
        #expect(items.map { $0.attributes["id"] } == ["nav", odd.id, data.id])
        #expect(items.last?.attributes["media-type"] == data.mediaType)
        #expect(try opf(documents).named("itemref").map { $0.attributes["idref"] } == [odd.id])
        let publication = try await reopened(documents, content: [odd.path: WriterCoverage.xhtml("<p>Text</p>"), data.path: Data([0])])
        #expect(Array(publication.resources.dropFirst()) == [odd, data])
        #expect(publication.spine == [.init(resource: odd)])
    }

    // MARK: Package structure

    @Test func documentsNameTheirPathsRootfileVersionAndUniqueIdentifier() throws {
        let documents = try generate()
        #expect(documents.map(\.path).sorted() == ["EPUB/nav.xhtml", "EPUB/package.opf", "META-INF/container.xml", "mimetype"])
        #expect(try WriterCoverage.document("mimetype", in: documents) == "application/epub+zip")
        let container = try WriterXMLProbe.parse(WriterCoverage.document("META-INF/container.xml", in: documents))
        #expect(container.named("container").map(\.attributes) == [["xmlns": "urn:oasis:names:tc:opendocument:xmlns:container", "version": "1.0"]])
        #expect(container.named("rootfile").map(\.attributes) == [["full-path": "EPUB/package.opf", "media-type": "application/oebps-package+xml"]])
        let package = try opf(documents)
        let root = try #require(package.elements.first)
        #expect(root.name == "package" && root.attributes["version"] == "3.0" && root.attributes["xmlns"] == "http://www.idpf.org/2007/opf")
        let identifiers = package.named("dc:identifier")
        #expect(identifiers.count == 1)
        #expect(identifiers.first?.attributes["id"] == root.attributes["unique-identifier"])
        #expect(identifiers.first?.text == "urn:test:writer-coverage")
        let navigationItems = package.named("item").filter { ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav") }
        #expect(navigationItems.map(\.attributes) == [["id": "nav", "href": "nav.xhtml", "media-type": "application/xhtml+xml", "properties": "nav"]])
        let navigation = try nav(documents)
        #expect(navigation.elements.first?.attributes["xmlns"] == "http://www.w3.org/1999/xhtml")
        #expect(navigation.named("nav").filter { $0.attributes["epub:type"] == "toc" }.count == 1)
    }

    @Test func modificationAndCreationDatesAreUTCSecondsWhateverTheirFraction() throws {
        let cases: [(TimeInterval, String)] = [(1_700_000_000, "2023-11-14T22:13:20Z"), (0, "1970-01-01T00:00:00Z"),
            (951_782_400, "2000-02-29T00:00:00Z"), (1_719_791_999, "2024-06-30T23:59:59Z"), (253_402_300_799, "9999-12-31T23:59:59Z")]
        func metas(_ modified: Date, _ created: Date) throws -> [String: [String]] {
            let facts = EPUBPackageMetadata(metadata: .init(title: "T"), identifier: "id", modificationDate: modified, created: created)
            return Dictionary(grouping: try opf(try generate(facts)).named("meta"), by: { $0.attributes["property"] ?? "" })
                .mapValues { $0.map(\.text) }
        }
        for (seconds, expected) in cases {
            let written = try metas(Date(timeIntervalSince1970: seconds), Date(timeIntervalSince1970: seconds))
            #expect(written["dcterms:modified"] == [expected])
            #expect(written["dcterms:created"] == [expected])
        }
        // EPUB 3.3, 5.5.5 "Last modified date": CCYY-MM-DDThh:mm:ssZ in UTC, with no fraction.
        let pattern = try Regex(#"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#)
        let fractional = try metas(Date(timeIntervalSince1970: 1_700_000_000.75), Date(timeIntervalSince1970: 0.999))
        #expect(try #require(fractional["dcterms:modified"]?.first).wholeMatch(of: pattern) != nil)
        #expect(try #require(fractional["dcterms:created"]?.first).wholeMatch(of: pattern) != nil)
    }

    @Test func authorsSummaryAndKeywordsAreWrittenInTheGivenOrder() throws {
        let facts = EPUBPackageMetadata(metadata: .init(title: "T", authors: ["First", "Second", "Third"], languages: ["en"]),
            identifier: "id", modificationDate: WriterCoverage.date, summary: "Sum & <mary>", keywords: ["zeta", "alpha & beta", "zeta"])
        let package = try opf(try generate(facts))
        #expect(package.named("dc:creator").map(\.text) == ["First", "Second", "Third"])
        #expect(package.named("dc:description").map(\.text) == ["Sum & <mary>"])
        #expect(package.named("dc:subject").map(\.text) == ["zeta", "alpha & beta", "zeta"])
    }

    // "Package generation does not invent document facts."
    @Test func generationIsRepeatableAndAddsNoMetadataTheCallerDidNotSupply() throws {
        let facts = EPUBPackageMetadata(metadata: .init(title: "Only a title"), identifier: "id", modificationDate: WriterCoverage.date)
        let first = try generate(facts), second = try generate(facts)
        #expect(first.map(\.path) == second.map(\.path))
        #expect(first.map(\.content) == second.map(\.content))
        let package = try opf(first)
        for name in ["dc:creator", "dc:description", "dc:subject", "dc:date", "dc:publisher"] { #expect(package.named(name).isEmpty, "\(name)") }
        #expect(package.named("meta").compactMap { $0.attributes["property"] }.sorted() == ["dcterms:modified", "rendition:layout"])
    }

    @Test func aMissingLanguageIsWrittenAsUndeterminedInThePackageAndNavigation() throws {
        for (languages, expected) in [([String](), "und"), (["pt-BR"], "pt-BR")] {
            let documents = try generate(WriterCoverage.facts(languages: languages))
            #expect(try opf(documents).named("dc:language").map(\.text) == [expected])
            let html = try #require(try nav(documents).elements.first)
            #expect(html.attributes["xml:lang"] == expected && html.attributes["lang"] == expected)
        }
    }

    // EPUB 3.3, 5.5.1 and 5.5.3.1.3: the metadata holds "dc:language [1 or more]", and creators "MAY
    // specify additional dc:language elements for multilingual Publications". `EPUBMetadata.languages`
    // is a list, every author in the same value is written, and the reader returns every language.
    @Test func everyMetadataLanguageIsWrittenAndReadBack() async throws {
        try await withKnownIssue("https://github.com/vocaro/EPUBLib/issues/95") {
            let documents = try generate(WriterCoverage.facts(languages: ["en", "fr", "grc"]))
            let written = try opf(documents).named("dc:language").map(\.text)
            #expect(written == ["en", "fr", "grc"])
            let readBack = try await reopened(documents).metadata.languages
            #expect(readBack == ["en", "fr", "grc"])
        }
    }

    @Test func manifestPropertiesAreSortedAndTheCoverImageIsFoundOnReadBack() async throws {
        let rich = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml", properties: ["svg", "mathml", "scripted"])
        let cover = EPUBResource(id: "cover", path: "EPUB/images/cover.png", mediaType: "image/png", properties: ["cover-image"])
        let documents = try generate(resources: [rich, cover], spine: [.init(resource: rich)])
        let items = try opf(documents).named("item")
        #expect(items.map { $0.attributes["properties"] } == ["nav", "mathml scripted svg", "cover-image"])
        let publication = try await reopened(documents, content: [rich.path: WriterCoverage.xhtml("<p>Text</p>"), cover.path: Data([1, 2, 3])])
        #expect(publication.cover == cover)
        #expect(Array(publication.resources.dropFirst()) == [rich, cover])
        #expect(try publication.data(for: cover) == Data([1, 2, 3]))
    }

    @Test func spineLinearityLayoutOverridesAndPageProgressionReadBack() async throws {
        let three = EPUBResource(id: "e", path: "EPUB/three.xhtml", mediaType: "application/xhtml+xml")
        let spine = [EPUBSpineItem(resource: one), .init(resource: two, isLinear: false), .init(resource: three, layout: .prePaginated)]
        let content = [one.path: WriterCoverage.xhtml("<p>1</p>"), two.path: WriterCoverage.xhtml("<p>2</p>"), three.path: WriterCoverage.xhtml("<p>3</p>")]
        var facts = WriterCoverage.facts()
        let plain = try await reopened(try generate(facts, resources: [one, two, three], spine: spine), content: content)
        #expect(plain.spine == spine)
        #expect(plain.pageProgression == .default)
        facts.rightToLeft = true
        let documents = try generate(facts, resources: [one, two, three], spine: spine)
        #expect(try opf(documents).named("meta").filter { $0.attributes["property"] == "rendition:layout" }.map(\.text) == ["reflowable"])
        let reversed = try await reopened(documents, content: content)
        #expect(reversed.spine == spine)
        #expect(reversed.pageProgression == .rtl)
        #expect(try reversed.textSection(at: 1).isLinear == false)
    }

    @Test func theNavigationStylesheetIsLinkedRelativeToTheNavigationDocument() throws {
        let css = EPUBResource(id: "css", path: "EPUB/css/nav.css", mediaType: "text/css")
        let linked = try nav(try generate(resources: [one, css], stylesheet: "EPUB/css/nav.css")).named("link")
        #expect(linked.map(\.attributes) == [["rel": "stylesheet", "type": "text/css", "href": "css/nav.css"]])
        #expect(try nav(try generate(resources: [one, css])).named("link").isEmpty)
    }

    // MARK: Navigation

    @Test func nestedContentsUnlinkedParentsAndPagesReadBackIdentically() async throws {
        let contents: [EPUBNavigationItem] = [
            .init(title: "Part I", children: [
                .init(title: "Chapter 1", href: "EPUB/one.xhtml", children: [
                    .init(title: "Section 1.1", href: "EPUB/one.xhtml#s1", children: [.init(title: "Deep", href: "EPUB/one.xhtml#deep")]),
                    .init(title: "Section 1.2", href: "EPUB/one.xhtml#s2"),
                ]),
            ]),
            .init(title: "Chapter 2", href: "EPUB/two.xhtml"),
        ]
        let pages = [("i", "EPUB/one.xhtml#p-i"), ("1", "EPUB/one.xhtml#p1"), ("2", "EPUB/two.xhtml#p2")]
        let documents = try generate(resources: [one, two], spine: [.init(resource: one), .init(resource: two)], contents: contents,
                                      pages: pages.map { .init(title: $0.0, href: $0.1) })
        let publication = try await reopened(documents, content: [one.path: WriterCoverage.xhtml("<p>1</p>"), two.path: WriterCoverage.xhtml("<p>2</p>")])
        #expect(publication.tableOfContents == contents)
        #expect(publication.pageList == pages.map { EPUBPageListEntry(label: $0.0, href: $0.1) })
        #expect(publication.landmarks.isEmpty)
    }

    // EPUB 3.3, 7.3: an `ol` in a `nav` holds "li [1 or more]" (epubcheck's epub-nav-30.rnc:
    // `epub.nav.ol.content = epub.nav.oli+`), and 7.4.3: the page-list nav "is OPTIONAL". A book
    // without source pages has no page list to write; an empty `ol` makes its navigation invalid.
    @Test func aPublicationWithoutPagesHasNoEmptyNavigationList() throws {
        try withKnownIssue("https://github.com/vocaro/EPUBLib/issues/94") {
            let navigation = try nav(try generate(pages: []))
            for list in navigation.named("ol") {
                #expect(!navigation.children(of: list, named: "li").isEmpty, "an <ol> without <li> in \(navigation.named("nav").map(\.attributes))")
            }
        }
    }

    // doc/writing.md: "navigation must resolve to a declared resource", and bad targets throw. An
    // entry with neither a target nor children cannot be written validly (EPUB 3.3, 7.3: "An ol
    // (ordered list) element MUST follow a span element"), but leaving it out, and with it a parent
    // left childless, loses the caller's contents without a word.
    @Test func anUnlinkedContentsEntryWithoutChildrenIsRefusedOrWrittenNeverSilentlyDropped() throws {
        try withKnownIssue("https://github.com/vocaro/EPUBLib/issues/96") {
            let contents: [EPUBNavigationItem] = [.init(title: "Start", href: "EPUB/one.xhtml"),
                                                  .init(title: "Part without chapters", children: [.init(title: "Unlinked leaf")])]
            let documents: [EPUBPackageWriter.Document]
            do { documents = try generate(contents: contents) } catch is EPUBWritingError { return }
            let toc = try nav(documents)
            let labels = toc.elements.filter { $0.name == "a" || $0.name == "span" }.map(\.text)
            #expect(labels == ["Start", "Part without chapters", "Unlinked leaf"])
        }
    }

    @Test func resourcePathsWithSpacesHashesPercentSignsAndNonASCIIRoundTrip() async throws {
        let odd = EPUBResource(id: "odd", path: "EPUB/text/a b#c%d \u{E9}.xhtml", mediaType: "application/xhtml+xml")
        let image = EPUBResource(id: "img", path: "EPUB/images/na\u{EF}ve 100%.png", mediaType: "image/png")
        #expect(odd.href == "EPUB/text/a%20b%23c%25d%20%C3%A9.xhtml")
        let contents = [EPUBNavigationItem(title: "Odd", href: odd.href + "#start")]
        let documents = try generate(resources: [odd, image], spine: [.init(resource: odd)], contents: contents,
                                      pages: [.init(title: "1", href: odd.href + "#start")])
        #expect(try opf(documents).named("item").map { $0.attributes["href"] }
            == ["nav.xhtml", "text/a%20b%23c%25d%20%C3%A9.xhtml", "images/na%C3%AFve%20100%25.png"])
        let publication = try await reopened(documents, content: [odd.path: WriterCoverage.xhtml("<p id=\"start\">Odd text</p>"), image.path: Data([9, 8, 7])])
        #expect(Array(publication.resources.dropFirst()) == [odd, image])
        #expect(publication.spine == [.init(resource: odd)])
        #expect(publication.tableOfContents == contents)
        #expect(publication.pageList == [.init(label: "1", href: odd.href + "#start")])
        #expect(try publication.data(for: image) == Data([9, 8, 7]))
        let section = try publication.textSection(at: 0)
        #expect(section.text == "Odd text")
        #expect(section.resource.href == odd.href)
        #expect(section.anchors["start"] == EPUBTextMark(offset: 0, separator: 0))
    }

    @Test func everyWrittenContentsAndPageFragmentResolvesToAnAnchorInTheExtractedChapter() async throws {
        let chapter = WriterCoverage.xhtml("<h1 id=\"top\">Título</h1><p>Uno <span id=\"p1\"/>dos.</p><h2 id=\"secci\u{F3}n-2\">Sección</h2><p id=\"fin\">Fin</p>")
        let contents: [EPUBNavigationItem] = [.init(title: "Título", href: "EPUB/one.xhtml#top", children: [
            .init(title: "Sección", href: "EPUB/one.xhtml#secci%C3%B3n-2")]), .init(title: "Fin", href: "EPUB/one.xhtml#fin")]
        let publication = try await reopened(try generate(contents: contents, pages: [.init(title: "1", href: "EPUB/one.xhtml#p1")]),
                                             content: [one.path: chapter])
        #expect(publication.tableOfContents == contents)
        let section = try publication.textSection(at: 0)
        #expect(section.text == "Título\nUno dos.\nSección\nFin")
        func flattened(_ items: [EPUBNavigationItem]) -> [String] { items.flatMap { [$0.href].compactMap { $0 } + flattened($0.children) } }
        let targets = flattened(publication.tableOfContents) + (publication.pageList ?? []).map(\.href)
        #expect(targets.count == 4)
        for target in targets {
            let fragment = try #require(target.split(separator: "#").last?.removingPercentEncoding)
            #expect(section.anchors[fragment] != nil, "\(target)")
        }
        #expect(section.anchors["secci\u{F3}n-2"] == EPUBTextMark(offset: "Título\nUno dos.\n".utf8.count, separator: 1))
    }

    // MARK: Refused input

    @Test func unsafeReservedAndOutOfPackageResourcePathsAndIDsAreRefused() {
        for path in ["EPUB/../x.xhtml", "/EPUB/x.xhtml", "OPS/x.xhtml", "x.xhtml", "EPUB/a\\b.xhtml", "EPUB/a:b.xhtml", "", "EPUB/", "EPUB/x/",
                     "EPUB//x.xhtml", "EPUB/./x.xhtml", "EPUB/a\0b.xhtml", "EPUB/nav.xhtml", "EPUB/package.opf", "META-INF/container.xml", "mimetype"] {
            let resource = EPUBResource(id: "x", path: path, mediaType: "application/xhtml+xml")
            #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid resource: \(path)"), "\(path)") {
                try generate(resources: [resource], spine: [.init(resource: resource)], contents: [])
            }
        }
        for id in ["", "nav"] {
            let resource = EPUBResource(id: id, path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
            #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid resource: EPUB/one.xhtml"), "\(id)") {
                try generate(resources: [resource], spine: [.init(resource: resource)], contents: [])
            }
        }
    }

    @Test func duplicateIDsDuplicatePathsAndUndeclaredSpineItemsAreEachRefused() {
        let sameID = EPUBResource(id: "c", path: "EPUB/two.xhtml", mediaType: "application/xhtml+xml")
        let samePath = EPUBResource(id: "other", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
        #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid resource: EPUB/two.xhtml")) { try generate(resources: [one, sameID]) }
        #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid resource: EPUB/one.xhtml")) { try generate(resources: [one, samePath]) }
        #expect(throws: EPUBWritingError.invalidPublication("empty spine")) { try generate(spine: []) }
        // A spine item must equal a declared resource, not merely share its id.
        for stray in [two, EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "text/html"),
                      EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml", properties: ["svg"])] {
            #expect(throws: EPUBWritingError.invalidPublication("spine references an undeclared resource")) {
                try generate(spine: [.init(resource: one), .init(resource: stray)])
            }
        }
    }

    @Test func navigationTargetsMustBeDeclaredResourcesInsideThePackage() {
        for href in ["EPUB/missing.xhtml", "EPUB/missing.xhtml#x", "one.xhtml", "", "#frag", "META-INF/container.xml", "mimetype", "EPUB"] {
            let expected = EPUBWritingError.invalidPublication("navigation references an undeclared resource: \(href)")
            #expect(throws: expected, "contents \(href)") { try generate(contents: [.init(title: "t", href: href)]) }
            #expect(throws: expected, "nested \(href)") {
                try generate(contents: [.init(title: "p", href: "EPUB/one.xhtml", children: [.init(title: "t", href: href)])])
            }
            #expect(throws: expected, "page \(href)") { try generate(pages: [.init(title: "1", href: href)]) }
            #expect(throws: expected, "stylesheet \(href)") { try generate(stylesheet: href) }
        }
        // References that leave the archive, name another origin or carry a query never reach the output.
        for href in ["../outside.xhtml", "EPUB/../../outside.xhtml", "/EPUB/one.xhtml", "http://example.invalid/x", "EPUB/one.xhtml?q=1",
                     "EPUB/%zz.xhtml", "EPUB/one.xhtml#%zz", "EPUB\\one.xhtml"] {
            #expect(throws: (any Error).self, "contents \(href)") { try generate(contents: [.init(title: "t", href: href)]) }
            #expect(throws: (any Error).self, "page \(href)") { try generate(pages: [.init(title: "1", href: href)]) }
        }
    }

    // The package document gives its dc:identifier the XML ID "book-id" (and the navigation
    // document reserves "nav" in the manifest, which is refused). XML IDs are unique within a
    // document, and `unique-identifier` must resolve to the dc:identifier alone.
    @Test func aResourceIDEqualToThePackageIdentifierElementIDIsRefusedOrKeptUnique() throws {
        try withKnownIssue("https://github.com/vocaro/EPUBLib/issues/96") {
            let resource = EPUBResource(id: "book-id", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
            let documents: [EPUBPackageWriter.Document]
            do { documents = try generate(resources: [resource], spine: [.init(resource: resource)]) } catch is EPUBWritingError { return }
            let ids = try opf(documents).elements.compactMap { $0.attributes["id"] }
            #expect(Set(ids).count == ids.count, "the package document repeats an XML ID: \(ids)")
        }
    }
}
