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

    // doc/writing.md: no value is normalized by the writer, and a reader normalizes what it
    // reads. This package's strips and collapses the ASCII whitespace of a metadata value or a
    // label (EPUB Reading Systems 3.3 §5.3) and keeps other white space, so a value given with
    // a tab, a line end or spaces at its ends is in the document as given and is read back as
    // its words between single spaces. How the writer writes a tab or line end is
    // https://github.com/vocaro/EPUBLib/issues/254, below.
    @Test func whiteSpaceIsWrittenAsGivenAndReadBackStrippedAndCollapsed() async throws {
        let given = "  A\tLong\r\n   Title \u{A0} of  Two\u{3000}Lines\u{A0}\r", read = "A Long Title \u{A0} of Two\u{3000}Lines\u{A0}"
        let facts = EPUBPackageMetadata(metadata: .init(title: given, authors: [given], languages: ["en"]), identifier: given,
                                        modificationDate: WriterCoverage.date)
        let documents = try generate(facts, contents: [.init(title: given, href: "EPUB/one.xhtml")], pages: [.init(title: given, href: "EPUB/one.xhtml")])
        let package = try opf(documents)
        for name in ["dc:title", "dc:creator", "dc:identifier"] { expectScalars(package.named(name).map(\.text), [given], name) }
        expectScalars(try nav(documents).named("a").map(\.text), [given, given], "labels")
        let publication = try await reopened(documents)
        expectScalars([publication.metadata.title] + publication.metadata.authors + publication.metadata.identifiers, [read, read, read], "metadata read back")
        expectScalars(publication.tableOfContents.map(\.title) + (publication.pageList ?? []).map(\.label), [read, read], "labels read back")
    }

    // A parser reads a carriage return written as it stands as a line feed, and a tab or line end
    // written as it stands in an attribute value as a space (XML 1.0 §2.11, §3.3.3), but reads a
    // reference to one as that character. The writer writes each as Canonical XML does (§2.3): a
    // carriage return in text as `&#13;`, and a tab, line feed and carriage return in an
    // attribute value as `&#9;`, `&#10;` and `&#13;`, so that each reads back as given
    // (https://github.com/vocaro/EPUBLib/issues/254). A tab and a line feed in text stay as they are.
    @Test func tabsAndLineEndsAreWrittenAsCanonicalXMLWritesThemAndReadBackAsGiven() async throws {
        let given = "a\tb\nc\rd\r\ne"
        // As written in text and in an attribute value.
        let text = "a\tb\nc&#13;d&#13;\ne", attribute = "a&#9;b&#10;c&#13;d&#13;&#10;e"
        let odd = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml", properties: ["p" + given])
        let data = EPUBResource(id: "d", path: "EPUB/data.bin", mediaType: "application/x-odd;v=" + given)
        let facts = EPUBPackageMetadata(metadata: .init(title: given, authors: [given], languages: [given]), identifier: given,
                                        modificationDate: WriterCoverage.date, summary: given, keywords: [given])
        let contents = [EPUBNavigationItem(title: given, href: "EPUB/one.xhtml"), .init(title: given, children: [.init(title: "Last", href: "EPUB/one.xhtml")])]
        let documents = try generate(facts, resources: [odd, data], spine: [.init(resource: odd)], contents: contents,
                                     pages: [.init(title: given, href: "EPUB/one.xhtml")])
        // The bytes written. `String` holds a carriage return and line feed as one `Character`,
        // so the documents are searched by byte.
        let package = try WriterCoverage.document("EPUB/package.opf", in: documents)
        let navigation = try WriterCoverage.document("EPUB/nav.xhtml", in: documents)
        func expectHolds(_ document: String, _ markup: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(Data(document.utf8).range(of: Data(markup.utf8)) != nil, "\(markup.debugDescription)", sourceLocation: sourceLocation)
        }
        for name in ["dc:identifier", "dc:title", "dc:language", "dc:creator", "dc:description", "dc:subject"] {
            expectHolds(package, ">\(text)</\(name)>")
        }
        expectHolds(package, " media-type=\"application/x-odd;v=\(attribute)\"")
        expectHolds(package, " properties=\"p\(attribute)\"")
        expectHolds(navigation, " xml:lang=\"\(attribute)\" lang=\"\(attribute)\"")
        expectHolds(navigation, "<a href=\"one.xhtml\">\(text)</a>")
        expectHolds(navigation, "<span>\(text)</span>")
        for (path, document) in [("package", package), ("navigation", navigation)] {
            #expect(!document.utf8.contains(0x0D), "a carriage return as it stands in the \(path) document")
        }
        // To an XML parser, the values that were given.
        let parsed = try opf(documents), parsedNavigation = try nav(documents)
        for name in ["dc:identifier", "dc:title", "dc:language", "dc:creator", "dc:description", "dc:subject"] {
            expectScalars(parsed.named(name).map(\.text), [given], name)
        }
        let items = parsed.named("item")
        expectScalars(items.map { $0.attributes["media-type"] }, ["application/xhtml+xml", odd.mediaType, data.mediaType], "media-type")
        expectScalars(items.dropLast().map { $0.attributes["properties"] }, ["nav", "p" + given], "properties")
        let html = try #require(parsedNavigation.elements.first)
        expectScalars([html.attributes["xml:lang"], html.attributes["lang"]], [given, given], "lang")
        expectScalars(parsedNavigation.named("a").map(\.text), [given, "Last", given], "links")
        expectScalars(parsedNavigation.named("span").map(\.text), [given], "headings")
        // And to this package's reader, which reads a media type as given, and a metadata value or
        // a label with its ASCII whitespace collapsed, whatever was written for it.
        let publication = try await reopened(documents, content: [odd.path: WriterCoverage.xhtml("<p>Text</p>"), data.path: Data([0])])
        expectScalars(publication.resources.dropFirst().map(\.mediaType), [odd.mediaType, data.mediaType], "media types read back")
        let read = "a b c d e"
        expectScalars([publication.metadata.title] + publication.metadata.authors + publication.metadata.identifiers + publication.metadata.languages,
                      [read, read, read, read], "metadata read back")
        expectScalars(titles(publication.tableOfContents) + (publication.pageList ?? []).map(\.label), [read, read, "Last", read], "labels read back")
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

    // The writer takes media types and properties as given, and refuses an ID that is not an XML
    // name, so an ID holds no markup character (https://github.com/vocaro/EPUBLib/issues/96). What
    // it accepts must be escaped, so the manifest and spine still agree when read back.
    @Test func mediaTypesAndPropertiesWithMarkupCharactersAreEscapedWhereverTheyAreWritten() async throws {
        let odd = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml", properties: ["x&y", "a<b"])
        let data = EPUBResource(id: "d", path: "EPUB/data.bin", mediaType: "application/x-odd;v=\"1\"&<2>")
        let documents = try generate(resources: [odd, data], spine: [.init(resource: odd)])
        let items = try opf(documents).named("item")
        #expect(items.map { $0.attributes["properties"] } == ["nav", "a<b x&y", nil])
        #expect(items.last?.attributes["media-type"] == data.mediaType)
        let publication = try await reopened(documents, content: [odd.path: WriterCoverage.xhtml("<p>Text</p>"), data.path: Data([0])])
        #expect(Array(publication.resources.dropFirst()) == [odd, data])
        #expect(publication.spine == [.init(resource: odd)])
    }

    // MARK: Escaping beside a mark

    // A `Character`, and the composed character sequence Foundation's string search matches by,
    // holds an "&", "<", ">" or quote together with a combining mark, variation selector or
    // joiner after it. Searched for that way, "<" + U+0338 (a decomposed "≮") holds no "<", and
    // it was written as it stood (https://github.com/vocaro/EPUBLib/issues/203).

    /// Records each of `read` that is not its `given` scalar for scalar: `==` on `String` holds
    /// canonically equivalent texts equal, and a text read back in the other normalization form
    /// would pass it.
    private func expectScalars(_ read: [String?], _ given: [String], _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        func hex(_ text: String?) -> String { text.map { $0.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ") } ?? "nothing" }
        #expect(read.count == given.count, "\(what)", sourceLocation: sourceLocation)
        let wrong = zip(read, given).filter { read, given in read.map { !$0.unicodeScalars.elementsEqual(given.unicodeScalars) } ?? true }
        #expect(wrong.isEmpty, "\(what): \(wrong.count) differ, the first given as [\(hex(wrong.first?.1))] and read as [\(hex(wrong.first?.0 ?? nil))]",
                sourceLocation: sourceLocation)
    }
    private func titles(_ items: [EPUBNavigationItem]) -> [String] { items.flatMap { [$0.title] + titles($0.children) } }

    @Test func markupCharactersFollowedByAMarkAreEscapedInEveryTextValueAndReadBackScalarForScalar() async throws {
        // The issue's three; a "]]>", which text may not hold, closed by such a ">"; quotes; a "<"
        // between a prepended mark and a combining one; and one text in both normalization
        // forms, each of which must come back in the form it went in.
        let texts = ["a <\u{338} b", "A &\u{301} B", "<\u{FE0F}b>", "c ]]>\u{338} d", "\"\u{301}q\" '\u{308}s'", "n \u{600}<\u{338} m",
                     "a \u{226E} b e\u{301} \u{E9} a <\u{338} b"]
        for text in texts {
            let facts = EPUBPackageMetadata(metadata: .init(title: text, authors: [text, "Second " + text], languages: ["en"]), identifier: text,
                                            modificationDate: WriterCoverage.date, summary: text, keywords: [text, "Second " + text])
            let contents = [EPUBNavigationItem(title: text, href: "EPUB/one.xhtml", children: [.init(title: "Nested " + text, href: "EPUB/one.xhtml#n")]),
                            .init(title: "Unlinked " + text, children: [.init(title: "Last", href: "EPUB/one.xhtml")])]
            let documents = try generate(facts, contents: contents, pages: [.init(title: text, href: "EPUB/one.xhtml")])
            // Well-formed, and to an XML parser the text that was given.
            let package = try opf(documents), navigation = try nav(documents)
            for name in ["dc:title", "dc:identifier", "dc:description"] { expectScalars(package.named(name).map(\.text), [text], name) }
            for name in ["dc:creator", "dc:subject"] { expectScalars(package.named(name).map(\.text), [text, "Second " + text], name) }
            expectScalars(navigation.named("a").map(\.text), [text, "Nested " + text, "Last", text], "links")
            expectScalars(navigation.named("span").map(\.text), ["Unlinked " + text], "headings")
            // And to this package's reader.
            let publication = try await reopened(documents)
            expectScalars([publication.metadata.title] + publication.metadata.identifiers, [text, text], "title and identifier read back")
            expectScalars(publication.metadata.authors, [text, "Second " + text], "authors read back")
            expectScalars(titles(publication.tableOfContents), titles(contents), "contents read back")
            expectScalars((publication.pageList ?? []).map(\.label), [text], "pages read back")
        }
    }

    // A quote left as it stood ends its attribute value where the mark begins.
    @Test func quotesAndMarkupCharactersFollowedByAMarkAreEscapedInEveryAttributeValue() async throws {
        for m in WriterCoverage.clusteringMarks {
            let value = "q\"\(m)a'\(m)l<\(m)g>\(m)e&\(m)"
            let odd = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml", properties: ["p" + value])
            let data = EPUBResource(id: "d", path: "EPUB/data.bin", mediaType: "application/x-odd;" + value)
            let fragment = "a&\(m)b'\(m)"
            let documents = try generate(WriterCoverage.facts(languages: [value]), resources: [odd, data], spine: [.init(resource: odd)],
                                          contents: [.init(title: "Start", href: "EPUB/one.xhtml#" + fragment)])
            let package = try opf(documents), navigation = try nav(documents)
            let items = package.named("item")
            expectScalars(items.map { $0.attributes["id"] }, ["nav", odd.id, data.id], "id \(m.debugDescription)")
            expectScalars(items.map { $0.attributes["media-type"] }, ["application/xhtml+xml", odd.mediaType, data.mediaType], "media-type \(m.debugDescription)")
            expectScalars(items.dropLast().map { $0.attributes["properties"] }, ["nav", "p" + value], "properties \(m.debugDescription)")
            expectScalars(package.named("itemref").map { $0.attributes["idref"] }, [odd.id], "idref \(m.debugDescription)")
            let html = try #require(navigation.elements.first)
            expectScalars([html.attributes["xml:lang"], html.attributes["lang"]], [value, value], "lang \(m.debugDescription)")
            // No apostrophe is the writer's own, so none is left in what it wrote.
            for path in ["EPUB/package.opf", "EPUB/nav.xhtml"] {
                #expect(!(try WriterCoverage.document(path, in: documents)).unicodeScalars.contains("'"), "\(path) \(m.debugDescription)")
            }
            let publication = try await reopened(documents, content: [odd.path: WriterCoverage.xhtml("<p>Text</p>"), data.path: Data([0])])
            let resources = Array(publication.resources.dropFirst())
            expectScalars(resources.map(\.id) + publication.spine.map(\.resource.id), [odd.id, data.id, odd.id], "ids read back \(m.debugDescription)")
            expectScalars(resources.map(\.mediaType), [odd.mediaType, data.mediaType], "media types read back \(m.debugDescription)")
            expectScalars(resources.flatMap(\.properties), ["p" + value], "properties read back \(m.debugDescription)")
            expectScalars(publication.metadata.languages, [value], "language read back \(m.debugDescription)")
            // The reader gives a target with what is outside ASCII escaped.
            #expect(publication.tableOfContents.map(\.href) == ["EPUB/one.xhtml#" + WriterCoverage.escapingNonASCII(fragment)], "\(m.debugDescription)")
        }
    }

    @Test func everyScalarThatJoinsAMarkupCharactersCharacterLeavesItEscapedAndReadsBack() async throws {
        let (after, before, unjoined) = WriterCoverage.joiningMarkup
        // Unicode has thousands of the first and dozens of the second. With fewer, the loop below
        // would try little or nothing and pass.
        try #require(after.count > 2_000 && before.count > 20,
                     "String joins \(after.count) scalars to a markup character before them and \(before.count) to one after them")
        #expect(unjoined.isEmpty, "\(unjoined.prefix(8).map { String($0.value, radix: 16) })")
        #expect(WriterCoverage.clusteringMarks.allSatisfy { after.contains($0.unicodeScalars.first!) })
        #expect(before.contains("\u{600}") && before.contains("\u{110BD}") && Set(before).isDisjoint(with: after))
        /// Each markup character with `scalar` joined to it, the ">" closing a "]]>" where it can.
        func text(_ scalar: Unicode.Scalar, follows: Bool) -> String {
            var text = String.UnicodeScalarView("x".unicodeScalars)
            for character in WriterCoverage.markup {
                if follows, character == ">" { text.append(contentsOf: "]]".unicodeScalars) }
                if !follows { text.append(scalar) }
                text.append(character)
                if follows { text.append(scalar) }
            }
            text.append("y")
            return String(text)
        }
        let cases = after.map { text($0, follows: true) } + before.map { text($0, follows: false) }
        var written = 0
        for start in stride(from: 0, to: cases.count, by: 256) {
            // One book for each run of scalars: each text as an author, a subject and a label, and
            // all of them together as every value there is one of.
            let texts = Array(cases[start..<min(start + 256, cases.count)]), all = texts.joined(separator: " ")
            let first = "from U+" + String((after + before)[start].value, radix: 16)
            let marked = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml", properties: ["p" + texts.joined()])
            let data = EPUBResource(id: "d", path: "EPUB/data.bin", mediaType: "application/x-odd;" + all)
            let facts = EPUBPackageMetadata(metadata: .init(title: all, authors: texts, languages: [all]), identifier: all,
                                            modificationDate: WriterCoverage.date, summary: all, keywords: texts)
            let documents = try generate(facts, resources: [marked, data], spine: [.init(resource: marked)],
                                          contents: texts.map { .init(title: $0, href: "EPUB/one.xhtml") }, pages: texts.map { .init(title: $0, href: "EPUB/one.xhtml") })
            // Well-formed, and to an XML parser the values that were given.
            let package = try opf(documents), navigation = try nav(documents)
            for name in ["dc:title", "dc:identifier", "dc:description", "dc:language"] { expectScalars(package.named(name).map(\.text), [all], "\(name) \(first)") }
            for name in ["dc:creator", "dc:subject"] { expectScalars(package.named(name).map(\.text), texts, "\(name) \(first)") }
            let items = Array(package.named("item").dropFirst())
            expectScalars(items.map { $0.attributes["id"] } + package.named("itemref").map { $0.attributes["idref"] }, [marked.id, data.id, marked.id], "id \(first)")
            expectScalars(items.map { $0.attributes["media-type"] }, [marked.mediaType, data.mediaType], "media-type \(first)")
            expectScalars([items.first?.attributes["properties"]], ["p" + texts.joined()], "properties \(first)")
            let html = try #require(navigation.elements.first)
            expectScalars([html.attributes["xml:lang"], html.attributes["lang"]], [all, all], "lang \(first)")
            expectScalars(navigation.named("a").map(\.text), texts + texts, "labels \(first)")
            for path in ["EPUB/package.opf", "EPUB/nav.xhtml"] {
                #expect(!(try WriterCoverage.document(path, in: documents)).unicodeScalars.contains("'"), "\(path) \(first)")
            }
            // And to this package's reader.
            let publication = try await reopened(documents, content: [marked.path: WriterCoverage.xhtml("<p>Text</p>"), data.path: Data([0])])
            expectScalars([publication.metadata.title] + publication.metadata.identifiers + publication.metadata.languages, [all, all, all], "metadata read back \(first)")
            expectScalars(publication.metadata.authors, texts, "authors read back \(first)")
            expectScalars(publication.tableOfContents.map(\.title), texts, "contents read back \(first)")
            expectScalars((publication.pageList ?? []).map(\.label), texts, "pages read back \(first)")
            let resources = Array(publication.resources.dropFirst())
            expectScalars(resources.map(\.id) + publication.spine.map(\.resource.id), [marked.id, data.id, marked.id], "ids read back \(first)")
            expectScalars(resources.map(\.mediaType), [marked.mediaType, data.mediaType], "media types read back \(first)")
            expectScalars(resources.flatMap(\.properties), ["p" + texts.joined()], "properties read back \(first)")
            written += texts.count
        }
        #expect(written == after.count + before.count)
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

    // An empty language is left out, as the reader leaves it out of what it reads
    // (https://github.com/vocaro/EPUBLib/issues/96), and a list left with none is `und`.
    @Test func aMissingLanguageIsWrittenAsUndeterminedInThePackageAndNavigation() throws {
        for (languages, expected) in [([String](), "und"), ([""], "und"), ([" ", "\u{A0}\n"], "und"), (["pt-BR"], "pt-BR"), (["", "pt-BR"], "pt-BR")] {
            let documents = try generate(WriterCoverage.facts(languages: languages))
            #expect(try opf(documents).named("dc:language").map(\.text) == [expected], "\(languages)")
            let html = try #require(try nav(documents).elements.first)
            #expect(html.attributes["xml:lang"] == expected && html.attributes["lang"] == expected)
        }
    }

    // EPUB 3.3, 5.5.1 and 5.5.3.1.3: the metadata holds "dc:language [1 or more]", and creators "MAY
    // specify additional dc:language elements for multilingual Publications". `EPUBMetadata.languages`
    // is a list, every author in the same value is written, and the reader returns every language.
    @Test func everyMetadataLanguageIsWrittenAndReadBack() async throws {
        let languages = ["en", "fr", "grc", "en"]
        let documents = try generate(WriterCoverage.facts(languages: languages))
        #expect(try opf(documents).named("dc:language").map(\.text) == languages)
        #expect(try await reopened(documents).metadata.languages == languages)
        let html = try #require(try nav(documents).elements.first)
        #expect(html.attributes["xml:lang"] == "en" && html.attributes["lang"] == "en")
    }

    @Test func everyMetadataIdentifierIsWrittenAndReadBackWithItsOrderAndDuplicates() async throws {
        let primary = "urn:test:primary"
        for identifiers in [[String](), ["urn:isbn:9780000000002", "doi:10.0000/example"],
                            [primary, "urn:test:other"], ["urn:test:other", primary, primary, "urn:test:other"]] {
            let facts = EPUBPackageMetadata(metadata: .init(title: "T", languages: ["en"], identifiers: identifiers),
                identifier: primary, modificationDate: WriterCoverage.date)
            let documents = try generate(facts)
            let package = try opf(documents)
            let root = try #require(package.elements.first)
            let written = package.named("dc:identifier")
            let expected = identifiers.contains(primary) ? identifiers : [primary] + identifiers
            #expect(written.map(\.text) == expected)
            let unique = written.filter { $0.attributes["id"] == root.attributes["unique-identifier"] }
            #expect(unique.map(\.text) == [primary])
            #expect(written.firstIndex { $0.attributes["id"] == root.attributes["unique-identifier"] } == expected.firstIndex(of: primary))
            let readBack = try await reopened(documents).metadata
            #expect(readBack.identifiers == expected)
            let rewritten = try generate(.init(metadata: readBack, identifier: primary, modificationDate: WriterCoverage.date))
            #expect(try opf(rewritten).named("dc:identifier").map(\.text) == expected)
        }
    }

    @Test func everyMetadataLanguageAndIdentifierIsEscapedExactlyOnce() async throws {
        // These language strings exercise XML serialization, rather than language-tag validation.
        let languages = ["en", "x-&\u{338}<\"'>&amp;", "ja"]
        let primary = "urn:test:&\u{338}<\"'>&amp;"
        let identifiers = ["doi:10.0000/?a=1&b=<2>", primary, "urn:test:日本語🙂"]
        let facts = EPUBPackageMetadata(metadata: .init(title: "T", languages: languages, identifiers: identifiers),
            identifier: primary, modificationDate: WriterCoverage.date)
        let documents = try generate(facts)
        let package = try opf(documents)
        expectScalars(package.named("dc:language").map(\.text), languages, "languages written")
        expectScalars(package.named("dc:identifier").map(\.text), identifiers, "identifiers written")
        let readBack = try await reopened(documents).metadata
        expectScalars(readBack.languages, languages, "languages read back")
        expectScalars(readBack.identifiers, identifiers, "identifiers read back")
    }

    @Test func uniqueIdentifierMatchingPreservesCanonicallyEquivalentValuesExactly() async throws {
        let composed = "urn:test:é", decomposed = "urn:test:e\u{301}"
        for identifiers in [[composed], [composed, decomposed, decomposed]] {
            let facts = EPUBPackageMetadata(metadata: .init(title: "T", languages: ["en"], identifiers: identifiers),
                identifier: decomposed, modificationDate: WriterCoverage.date)
            let documents = try generate(facts)
            let written = try opf(documents).named("dc:identifier")
            let expected = identifiers.count == 1 ? [decomposed, composed] : identifiers
            expectScalars(written.map(\.text), expected, "identifier scalars written")
            expectScalars(written.filter { $0.attributes["id"] == "book-id" }.map(\.text), [decomposed], "unique identifier")
            expectScalars(try await reopened(documents).metadata.identifiers, expected, "identifier scalars read back")
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
        let navigation = try nav(try generate(pages: []))
        #expect(navigation.named("nav").filter { $0.attributes["epub:type"] == "page-list" }.isEmpty)
        for list in navigation.named("ol") {
            #expect(!navigation.children(of: list, named: "li").isEmpty, "an <ol> without <li> in \(navigation.named("nav").map(\.attributes))")
        }
    }

    // doc/writing.md: "navigation must resolve to a declared resource", and bad targets throw. An
    // entry with neither a target nor children cannot be written validly (EPUB 3.3, 7.3: "An ol
    // (ordered list) element MUST follow a span element"), but leaving it out, and with it a parent
    // left childless, loses the caller's contents without a word. It is refused, in the contents
    // and in the page list (https://github.com/vocaro/EPUBLib/issues/96).
    @Test func anUnlinkedContentsEntryWithoutChildrenIsRefusedOrWrittenNeverSilentlyDropped() throws {
        let contents: [EPUBNavigationItem] = [.init(title: "Start", href: "EPUB/one.xhtml"),
                                              .init(title: "Part without chapters", children: [.init(title: "Unlinked leaf")])]
        let refused = EPUBWritingError.invalidPublication("navigation entry without a target: Unlinked leaf")
        #expect(throws: refused) { try generate(contents: contents) }
        #expect(throws: refused) { try generate(pages: [.init(title: "1", href: "EPUB/one.xhtml"), .init(title: "Unlinked leaf")]) }
        #expect(throws: EPUBWritingError.invalidPublication("empty contents")) { try generate(contents: []) }
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

    // A target is checked by the path it resolves to, and was written as the text after its
    // "EPUB/". Spelled with an empty or dot segment, that text is another link: "/one.xhtml"
    // names the container root, "//one.xhtml" a host and "c:x/../one.xhtml" a scheme
    // (https://github.com/vocaro/EPUBLib/issues/240). The link written is the one checked: the
    // declared path from the navigation document, encoded as the manifest encodes it. A target is
    // found among the declared paths by canonical equivalence, so a decomposed "é" for a declared
    // composed one, and the other way round, is written as the declared path is. A target is
    // checked by that path alone: one spelled without "EPUB/" in front, as "x/../EPUB/one.xhtml"
    // and "%45PUB/one.xhtml" are, names the resource "EPUB/one.xhtml" does, and is accepted
    // (https://github.com/vocaro/EPUBLib/issues/606).
    @Test func everyTargetIsWrittenAsThePathItWasCheckedByWhateverItsSpelling() async throws {
        let odd = EPUBResource(id: "odd", path: "EPUB/text/a b \u{E9}.xhtml", mediaType: "application/xhtml+xml")
        let css = EPUBResource(id: "css", path: "EPUB/css/nav.css", mediaType: "text/css")
        let cafe = EPUBResource(id: "cafe", path: "EPUB/caf\u{E9}.xhtml", mediaType: "application/xhtml+xml")
        let sheet = EPUBResource(id: "sheet", path: "EPUB/css/cafe\u{301}.css", mediaType: "text/css")
        // Each target as given, the link it is written as in EPUB/nav.xhtml, and what that reaches.
        let plain = [("EPUB/one.xhtml", "one.xhtml", one), ("EPUB/one.xhtml#start", "one.xhtml#start", one),
                     (odd.href + "#start", "text/a%20b%20%C3%A9.xhtml#start", odd), (cafe.href, "caf%C3%A9.xhtml", cafe)]
        let respelled = [("EPUB//one.xhtml", "one.xhtml", one), ("EPUB///one.xhtml#start", "one.xhtml#start", one),
                         ("EPUB/c:x/../one.xhtml", "one.xhtml", one), ("EPUB/./one.xhtml", "one.xhtml", one),
                         ("EPUB/text/../one.xhtml#start", "one.xhtml#start", one),
                         ("EPUB//text/a b \u{E9}.xhtml#\u{E9}", "text/a%20b%20%C3%A9.xhtml#%C3%A9", odd),
                         // URL parsing drops a tab in a link, as it stands or written as a reference,
                         // so it is percent-encoded (https://github.com/vocaro/EPUBLib/issues/254).
                         ("EPUB/one.xhtml#a\tb", "one.xhtml#a%09b", one),
                         // The path is the declared one; the fragment, which is not checked, as given.
                         ("EPUB/cafe\u{301}.xhtml#e\u{301}", "caf%C3%A9.xhtml#e%CC%81", cafe), ("EPUB/cafe%CC%81.xhtml", "caf%C3%A9.xhtml", cafe),
                         // Spelled without "EPUB/" in front.
                         ("x/../EPUB/one.xhtml", "one.xhtml", one), ("%45PUB/one.xhtml#start", "one.xhtml#start", one),
                         ("EPUB/../EPUB/one.xhtml", "one.xhtml", one), ("%45%50%55%42/one.xhtml", "one.xhtml", one),
                         ("./EPUB/text/a b \u{E9}.xhtml#start", "text/a%20b%20%C3%A9.xhtml#start", odd),
                         ("x/y/../../EPUB/a/../cafe\u{301}.xhtml", "caf%C3%A9.xhtml", cafe)]
        let targets = plain + respelled
        let stylesheets = [("EPUB/css/nav.css", "css/nav.css", css), ("EPUB//css/nav.css", "css/nav.css", css),
                           ("EPUB///css/nav.css", "css/nav.css", css), ("EPUB/c:x/../css/nav.css", "css/nav.css", css),
                           ("EPUB/./css//nav.css", "css/nav.css", css), (sheet.href, "css/cafe%CC%81.css", sheet),
                           ("EPUB/css/caf\u{E9}.css", "css/cafe%CC%81.css", sheet), ("EPUB/css/caf%C3%A9.css", "css/cafe%CC%81.css", sheet),
                           ("x/../EPUB/css/nav.css", "css/nav.css", css), ("%45PUB/css/nav.css", "css/nav.css", css),
                           ("EPUB/../EPUB/css/nav.css", "css/nav.css", css)]
        let content = [one.path: WriterCoverage.xhtml("<p id=\"start\">Text</p>"), odd.path: WriterCoverage.xhtml("<p id=\"start\">Odd</p>"),
                       cafe.path: WriterCoverage.xhtml("<p>Caf\u{E9}</p>"), css.path: Data("p{}".utf8), sheet.path: Data("p{}".utf8)]
        // As a browser reads a link: by URL parsing, from the navigation document's URL.
        let base = try #require(URL(string: "https://reader.invalid/EPUB/nav.xhtml"))
        func expectReaches(_ link: String, _ resource: EPUBResource, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(!link.hasPrefix("/") && URL(string: link)?.scheme == nil, "\(what) is written as \(link)", sourceLocation: sourceLocation)
            let url = URL(string: link, relativeTo: base)?.absoluteURL
            #expect(url?.scheme == "https" && url?.host() == "reader.invalid" && url?.path(percentEncoded: false) == "/" + resource.path,
                    "\(what), written as \(link), reaches \(url?.absoluteString ?? "nothing")", sourceLocation: sourceLocation)
        }
        for (stylesheet, written, styles) in stylesheets {
            let documents = try generate(resources: [one, odd, cafe, css, sheet], spine: [one, odd, cafe].map { .init(resource: $0) },
                                         contents: targets.map { .init(title: "Entry", href: $0.0) },
                                         pages: targets.map { .init(title: "1", href: $0.0) }, stylesheet: stylesheet)
            let navigation = try nav(documents)
            let links = navigation.named("a").compactMap { $0.attributes["href"] }
            #expect(links == (targets + targets).map(\.1), "with the stylesheet \(stylesheet)")
            #expect(navigation.named("link").map { $0.attributes["href"] } == [written], "stylesheet \(stylesheet)")
            // The path of each link is a manifest href, byte for byte, as the manifest writes it.
            let manifest = try opf(documents).named("item").compactMap { $0.attributes["href"].map { Array($0.utf8) } }
            let linked = links + navigation.named("link").compactMap { $0.attributes["href"] }
            #expect(Set(linked.map { Array($0.split(separator: "#")[0].utf8) }).isSubset(of: manifest), "\(linked)")
            for ((given, _, resource), link) in zip(targets + targets, links) { expectReaches(link, resource, given) }
            expectReaches(written, styles, "stylesheet \(stylesheet)")
            let publication = try await reopened(documents, content: content)
            #expect(publication.tableOfContents.map(\.href) == targets.map { "EPUB/" + $0.1 })
            #expect((publication.pageList ?? []).map(\.href) == targets.map { "EPUB/" + $0.1 })
        }
    }

    // A doubled slash is an empty segment, and a `..` after it removes it rather than the name
    // before it, as URL parsing reads the target as given
    // (https://github.com/vocaro/EPUBLib/issues/605). With both one.xhtml and a/one.xhtml
    // declared, the target is checked, written and read back as the one a browser reaches.
    @Test func aDoubleDotAfterAnEmptySegmentRemovesItInTheTargetCheckedWrittenAndReadBack() async throws {
        let nested = EPUBResource(id: "nested", path: "EPUB/a/one.xhtml", mediaType: "application/xhtml+xml")
        // Each target as given, and the link it is written as in EPUB/nav.xhtml.
        let targets = [("EPUB/a//../one.xhtml", "a/one.xhtml"), ("EPUB/a///../../one.xhtml#start", "a/one.xhtml#start"),
                       ("EPUB/a/.//../one.xhtml", "a/one.xhtml"), ("EPUB/a/b//../../one.xhtml", "a/one.xhtml"),
                       ("EPUB//../one.xhtml", "one.xhtml"), ("EPUB/a//one.xhtml", "a/one.xhtml")]
        let root = try #require(URL(string: "https://reader.invalid/"))
        for (given, written) in targets {
            let url = URL(string: given, relativeTo: root)?.absoluteURL
            let path = url?.path(percentEncoded: false).split(separator: "/").joined(separator: "/")
            #expect(path == "EPUB/" + written.split(separator: "#")[0], "\(given) as a browser reads it")
        }
        let documents = try generate(resources: [one, nested], spine: [one, nested].map { .init(resource: $0) },
                                     contents: targets.map { .init(title: "Entry", href: $0.0) },
                                     pages: targets.map { .init(title: "1", href: $0.0) })
        #expect(try nav(documents).named("a").compactMap { $0.attributes["href"] } == (targets + targets).map(\.1))
        let content = [one.path: WriterCoverage.xhtml("<p id=\"start\">One</p>"), nested.path: WriterCoverage.xhtml("<p id=\"start\">Nested</p>")]
        let publication = try await reopened(documents, content: content)
        #expect(publication.tableOfContents.map(\.href) == targets.map { "EPUB/" + $0.1 })
        #expect((publication.pageList ?? []).map(\.href) == targets.map { "EPUB/" + $0.1 })
        // The name a `..` no longer removes is checked: here a colon, which no written path holds.
        #expect(throws: EPUBPublicationError.unsafePath("EPUB/c:x//../one.xhtml")) {
            try generate(resources: [one, nested], contents: [.init(title: "t", href: "EPUB/c:x//../one.xhtml")])
        }
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
        // An ID that is not an XML name without a colon by the character classes EPUBCheck holds
        // it to, those of XML 1.0 before its fifth edition, or that the writer gives its own
        // (https://github.com/vocaro/EPUBLib/issues/96); and a media type with nothing in it.
        for id in ["", "nav", "book-id", "1 chapter", "7", "a:b", "-x", ".x", " x", "x ", "x\u{0}", "x\u{1}", "\u{300}x", "x\u{2041}", "x\u{FFFE}",
                   "\u{2170}", "a\u{203F}b", "\u{10000}x"] {
            let resource = EPUBResource(id: id, path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
            #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid resource: EPUB/one.xhtml"), "\(id.debugDescription)") {
                try generate(resources: [resource], spine: [.init(resource: resource)], contents: [])
            }
        }
        for mediaType in ["", " ", "\r", "\u{A0}"] {
            let resource = EPUBResource(id: "x", path: "EPUB/one.xhtml", mediaType: mediaType)
            #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid resource: EPUB/one.xhtml"), "\(mediaType.debugDescription)") {
                try generate(resources: [resource], spine: [.init(resource: resource)], contents: [])
            }
        }
    }

    // A `Character` holds a "/", "\", ":" or "." together with a combining mark, variation
    // selector or joiner after it, so read that way "EPUB/../" + U+0301 + "x.xhtml" is a safe
    // path under EPUB/, and was written into the manifest as "../%CC%81x.xhtml"
    // (https://github.com/vocaro/EPUBLib/issues/181).
    @Test func resourcePathsAreCheckedWhateverMarkFollowsASeparatorOrDot() {
        for m in WriterCoverage.clusteringMarks {
            for path in ["EPUB/../\(m)x.xhtml", "EPUB/a/../../\(m)x.xhtml", "EPUB/./\(m)x.xhtml", "EPUB//\(m)x.xhtml", "EPUB/a\\\(m)b.xhtml",
                         "EPUB/a:\(m)b.xhtml", "/\(m)EPUB/x.xhtml", "EPUB\(m)/x.xhtml", "\(m)EPUB/x.xhtml", "EPUB/x\u{600}/..", "EPUB/x\u{600}/"] {
                let resource = EPUBResource(id: "x", path: path, mediaType: "application/xhtml+xml")
                #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid resource: \(path)"), "\(path.debugDescription)") {
                    try generate(resources: [resource], spine: [.init(resource: resource)], contents: [])
                }
            }
            // A target that leaves the package, or the archive, behind such a separator.
            for href in ["EPUB/../\(m)x.xhtml", "EPUB/../\(m)EPUB/one.xhtml", "../\(m)x.xhtml", "/\(m)EPUB/one.xhtml", "EPUB\\\(m)one.xhtml"] {
                #expect(throws: (any Error).self, "contents \(href.debugDescription)") { try generate(contents: [.init(title: "t", href: href)]) }
                #expect(throws: (any Error).self, "stylesheet \(href.debugDescription)") { try generate(stylesheet: href) }
            }
        }
    }

    @Test func aResourceWhoseNameBeginsWithAMarkIsWrittenUnderThatNameAndReadsBack() async throws {
        // By its bytes "EPUB/" + U+0301 + "x.xhtml" is a file in EPUB/, as it is to the reader.
        for m in WriterCoverage.clusteringMarks {
            let e = WriterCoverage.escapingNonASCII(m)
            let marked = EPUBResource(id: "m", path: "EPUB/\(m)x.xhtml", mediaType: "application/xhtml+xml")
            let nested = EPUBResource(id: "n", path: "EPUB/a/\(m)y.css", mediaType: "text/css")
            #expect(marked.href == "EPUB/\(e)x.xhtml")
            // A target as the resource's href spells it, and written out. Both are written as the
            // link they were checked as (https://github.com/vocaro/EPUBLib/issues/240).
            let contents = [EPUBNavigationItem(title: "Escaped", href: marked.href + "#\(e)top"),
                            EPUBNavigationItem(title: "Written", href: "EPUB/\(m)x.xhtml#\(m)top")]
            let documents = try generate(resources: [marked, nested], spine: [.init(resource: marked)], contents: contents, stylesheet: "EPUB/a/\(m)y.css")
            #expect(try opf(documents).named("item").map { $0.attributes["href"] } == ["nav.xhtml", "\(e)x.xhtml", "a/\(e)y.css"])
            let links = try nav(documents).named("a").compactMap { $0.attributes["href"] }
            #expect(links == ["\(e)x.xhtml#\(e)top", "\(e)x.xhtml#\(e)top"], "\(m.debugDescription)")
            #expect(try nav(documents).named("link").map { $0.attributes["href"] } == ["a/\(e)y.css"])
            let publication = try await reopened(documents, content: [marked.path: WriterCoverage.xhtml("<p>Marked</p>"), nested.path: Data("a{}".utf8)])
            #expect(publication.spine.map { Array($0.resource.path.unicodeScalars) } == [Array(marked.path.unicodeScalars)], "\(m.debugDescription)")
            #expect(Array(publication.resources.dropFirst()) == [marked, nested])
            #expect(publication.tableOfContents.map(\.href) == ["EPUB/\(e)x.xhtml#\(e)top", "EPUB/\(e)x.xhtml#\(e)top"])
            #expect(try publication.data(for: nested) == Data("a{}".utf8))
            #expect(try publication.textSection(at: 0).text == "Marked")
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

    // Manifest IDs compare code unit for code unit, as XML compares them: `caf\u{E9}` and
    // `cafe\u{301}` are two items, though `String` compares them equal, and a fallback or spine
    // item names the one with its own code units.
    @Test func canonicallyEquivalentResourceIDsAreTwoItems() async throws {
        let composed = EPUBResource(id: "caf\u{E9}", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
        let decomposed = EPUBResource(id: "cafe\u{301}", path: "EPUB/two.xhtml", mediaType: "application/xhtml+xml", fallbackID: "caf\u{E9}")
        let documents = try generate(resources: [composed, decomposed], spine: [.init(resource: decomposed), .init(resource: composed)])
        expectScalars(try opf(documents).named("item").map { $0.attributes["id"] }, ["nav", composed.id, decomposed.id], "item IDs")
        expectScalars(try opf(documents).named("itemref").map { $0.attributes["idref"] }, [decomposed.id, composed.id], "spine IDREFs")
        let publication = try await reopened(documents, content: [composed.path: WriterCoverage.xhtml("<p>One</p>"),
                                                                  decomposed.path: WriterCoverage.xhtml("<p>Two</p>")])
        #expect(publication.spine.map(\.resource.path) == [decomposed.path, composed.path])
        #expect(publication.fallbackChain(for: decomposed).map(\.path) == [decomposed.path, composed.path])
        // A spine item or fallback that names a declared ID only by canonical equivalence names none.
        let stray = EPUBResource(id: "cafe\u{301}", path: composed.path, mediaType: composed.mediaType)
        #expect(throws: EPUBWritingError.invalidPublication("spine references an undeclared resource")) {
            try generate(resources: [composed], spine: [.init(resource: stray)])
        }
        let dangling = EPUBResource(id: "d", path: "EPUB/two.xhtml", mediaType: "application/xhtml+xml", fallbackID: "cafe\u{301}")
        #expect(throws: EPUBWritingError.invalidPublication("fallback references an undeclared resource: cafe\u{301}")) {
            try generate(resources: [composed, dangling], spine: [.init(resource: composed)])
        }
    }

    @Test func navigationTargetsMustBeDeclaredResourcesInsideThePackage() {
        // A target is refused by the path it resolves to, however it is spelled: one that names a
        // file outside EPUB/, or no file, through EPUB/ or around it
        // (https://github.com/vocaro/EPUBLib/issues/606).
        for href in ["EPUB/missing.xhtml", "EPUB/missing.xhtml#x", "one.xhtml", "", "#frag", "META-INF/container.xml", "mimetype", "EPUB",
                     "EPUB/../one.xhtml", "x/../one.xhtml", "EPUB/../mimetype", "%45PUB/../META-INF/container.xml", "x/../EPUB/missing.xhtml",
                     "%45PUB", "x/../EPUB", "EPUB/../EPUB/../mimetype#x"] {
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
                     "EPUB/%zz.xhtml", "EPUB/one.xhtml#%zz", "EPUB\\one.xhtml", "x/../../EPUB/one.xhtml", "%2E%2E/EPUB/one.xhtml",
                     "EPUB%2Fone.xhtml"] {
            #expect(throws: (any Error).self, "contents \(href)") { try generate(contents: [.init(title: "t", href: href)]) }
            #expect(throws: (any Error).self, "page \(href)") { try generate(pages: [.init(title: "1", href: href)]) }
        }
    }

    // The package document gives its dc:identifier the XML ID "book-id" (and the navigation
    // document reserves "nav" in the manifest, which is refused). XML IDs are unique within a
    // document, and `unique-identifier` must resolve to the dc:identifier alone. "book-id" is
    // refused as "nav" is (https://github.com/vocaro/EPUBLib/issues/96).
    @Test func aResourceIDEqualToThePackageIdentifierElementIDIsRefusedOrKeptUnique() throws {
        let resource = EPUBResource(id: "book-id", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
        #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid resource: EPUB/one.xhtml")) {
            try generate(resources: [resource], spine: [.init(resource: resource)])
        }
        // A fallback to it names no manifest item.
        let fallback = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml", fallbackID: "book-id")
        #expect(throws: EPUBWritingError.invalidPublication("fallback references an undeclared resource: book-id")) {
            try generate(resources: [fallback], spine: [.init(resource: fallback)])
        }
    }
}
