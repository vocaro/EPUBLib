import EPUBCore
import EPUBReading
import EPUBWriting
import Foundation
import XCTest

/// The structural rules EPUBCheck holds a written publication to, asserted on what EPUBWriting
/// writes, so the default gate catches them without the EPUBCheck executable.
/// `EPUBCheckWriterValidationTests` runs the same books through the real validator.
final class EPUBCheckWriterOutputCoverageTests: XCTestCase {
    private typealias Book = EPUBCheckWrittenBook
    private typealias XML = EPUBCheckXMLElement

    private func package(_ book: Book, file: StaticString = #filePath, line: UInt = #line) throws -> XML {
        try XCTUnwrap(XML.parse(try book.document("EPUB/package.opf")), "the package document is not well-formed XML", file: file, line: line)
    }

    private func navigation(_ book: Book, file: StaticString = #filePath, line: UInt = #line) throws -> XML {
        try XCTUnwrap(XML.parse(try book.document("EPUB/nav.xhtml")), "the navigation document is not well-formed XML", file: file, line: line)
    }

    private var paged: Book {
        var book = Book.minimal
        book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml#start")]
        return book
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("epubcheck-writer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: What EPUBCheck reports of the writer's output

    func testABookWithoutPagesWritesNoEmptyPageList() throws {
        // RSC-005 `element "ol" incomplete; missing required element "li"`. EPUB 3.3, 7.3: a
        // `nav`'s `ol` holds one or more `li`; the page list itself is optional (7.4.3).
        let html = try navigation(.minimal)
        XCTAssertTrue(html.descendants("nav").filter { $0.attributes["epub:type"] == "page-list" }.isEmpty)
        let lists = html.descendants("ol")
        XCTAssertFalse(lists.isEmpty)
        for list in lists { XCTAssertFalse(list.children.filter { $0.name == "li" }.isEmpty, "an ol with no li") }
    }

    func testContentsWithoutAnEntryAreRefusedOrWrittenAsAValidList() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/96")
        // RSC-005, as above: the contents `nav` is required and its list needs an entry, so
        // empty contents cannot be written as they are.
        for (name, contents) in [("no entries", [EPUBNavigationItem]()), ("an entry with no target or children", [.init(title: "A heading")])] {
            var book = paged
            book.contents = contents
            guard let document = try? book.document("EPUB/nav.xhtml"), let nav = XML.parse(document) else { continue }
            let toc = try XCTUnwrap(nav.descendants("nav").first { $0.attributes["epub:type"] == "toc" }, name)
            for list in toc.descendants("ol") { XCTAssertFalse(list.children.filter { $0.name == "li" }.isEmpty, "\(name): an ol with no li") }
        }
    }

    func testNavigationLabelsAreNeverWrittenEmpty() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/96")
        // RSC-005 "Anchors within nav elements must contain text". EPUB 3.3, 7.3: the `a` or
        // `span` "MUST provide a non-zero-length text label".
        for title in ["", "  \n", "\u{1}"] {
            var book = paged
            book.contents = [.init(title: title, href: "EPUB/chapter.xhtml"), .init(title: title, children: [.init(title: "Chapter", href: "EPUB/chapter.xhtml#start")])]
            book.pages = [.init(title: title, href: "EPUB/chapter.xhtml")]
            guard let document = try? book.document("EPUB/nav.xhtml"), let nav = XML.parse(document) else { continue }
            for label in nav.descendants("a") + nav.descendants("span") {
                XCTAssertFalse(label.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "an empty <\(label.name)> for the title \(title.debugDescription)")
            }
        }
    }

    func testOptionalMetadataWithoutAValueIsLeftOut() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/96")
        // RSC-005 `character content of element "dc:creator" invalid; must be a string with
        // length at least 1`. EPUB 3.3, 5.5.2: these elements "MUST have non-empty values after
        // leading and trailing ASCII whitespace is stripped".
        var book = paged
        book.metadata.metadata = .init(title: "A Written Book", authors: ["", "  ", "Test Author"], languages: ["en"])
        book.metadata.summary = " "
        book.metadata.keywords = ["", "\t", "kept"]
        let metadata = try XCTUnwrap(try package(book).children.first { $0.name == "metadata" })
        for element in metadata.children where element.name.hasPrefix("dc:") {
            XCTAssertFalse(element.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "an empty <\(element.name)>")
        }
        XCTAssertEqual(metadata.children.filter { $0.name == "dc:creator" }.map(\.content), ["Test Author"])
        XCTAssertEqual(metadata.children.filter { $0.name == "dc:subject" }.map(\.content), ["kept"])
    }

    func testRequiredMetadataWithoutAValueIsRefusedOrNeverWrittenEmpty() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/96")
        // RSC-005, as above, for `dc:title`, `dc:language` and `dc:identifier`, each REQUIRED.
        var untitled = paged, unidentified = paged, unspoken = paged
        untitled.metadata.metadata = .init(title: " \n ", authors: ["Test Author"], languages: ["en"])
        unidentified.metadata.identifier = ""
        unspoken.metadata.metadata = .init(title: "A Written Book", languages: [""])
        for (name, book) in [("title", untitled), ("identifier", unidentified), ("language", unspoken)] {
            guard let document = try? book.document("EPUB/package.opf"), let package = XML.parse(document) else { continue }
            let metadata = try XCTUnwrap(package.children.first { $0.name == "metadata" })
            let element = try XCTUnwrap(metadata.children.first { $0.name == "dc:" + name }, name)
            XCTAssertFalse(element.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "an empty <dc:\(name)>")
        }
    }

    func testResourceIdentifiersThatAreNotXMLNamesAreRefusedOrNeverWritten() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/96")
        // RSC-005 `value of attribute "id" is invalid; must be an XML name without colons`.
        for id in ["1 chapter", "7", "a:b", "-x", "two words"] {
            var book = Book()
            book.addChapter(id: id, path: "EPUB/chapter.xhtml", title: "Chapter")
            book.pages = [.init(title: "1", href: "EPUB/chapter.xhtml")]
            guard let document = try? book.document("EPUB/package.opf"), let package = XML.parse(document) else { continue }
            let written = package.descendants("item").compactMap { $0.attributes["id"] } + package.descendants("itemref").compactMap { $0.attributes["idref"] }
            for value in written {
                XCTAssertNotNil(value.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9._\-]*/#), "\(value.debugDescription) written for the resource id \(id.debugDescription)")
            }
        }
    }

    // MARK: Facts given and facts written

    func testEveryLanguageGivenIsWritten() throws {
        var book = paged
        book.metadata.metadata = .init(title: "A Written Book", languages: ["en", "fr", "ja"])
        let metadata = try XCTUnwrap(try package(book).children.first { $0.name == "metadata" })
        XCTAssertEqual(metadata.children.filter { $0.name == "dc:language" }.map(\.content), ["en", "fr", "ja"])
    }

    func testEveryIdentifierGivenIsWritten() throws {
        var book = paged
        book.metadata.metadata = .init(title: "A Written Book", languages: ["en"], identifiers: ["urn:isbn:9780000000002", "doi:10.0000/example"])
        let package = try package(book)
        let identifiers = try XCTUnwrap(package.children.first { $0.name == "metadata" }).children.filter { $0.name == "dc:identifier" }
        XCTAssertEqual(identifiers.first { $0.attributes["id"] == package.attributes["unique-identifier"] }?.content, book.metadata.identifier,
                       "the unique identifier")
        XCTAssertEqual(identifiers.map(\.content), [book.metadata.identifier] + book.metadata.metadata.identifiers)
    }

    // MARK: Structure EPUBCheck accepts, kept

    func testThePackageDocumentCarriesWhatEPUB3Requires() throws {
        var book = paged
        book.addChapter(id: "aside", path: "EPUB/aside.xhtml", title: "Aside", linear: false)
        let plate = book.add(id: "plate", path: "EPUB/plate.xhtml", mediaType: "application/xhtml+xml", data: Book.page(title: "Plate", body: "<p>Plate.</p>"))
        book.spine.append(.init(resource: plate, layout: .prePaginated))
        book.add(id: "cover", path: "EPUB/cover.png", mediaType: "image/png", data: Data([0x89, 0x50]), properties: ["cover-image"])
        book.metadata.rightToLeft = true
        book.metadata.created = Date(timeIntervalSince1970: 1_700_000_000)
        let package = try package(book)
        XCTAssertEqual(package.name, "package")
        XCTAssertEqual(package.attributes["xmlns"], "http://www.idpf.org/2007/opf")
        XCTAssertEqual(package.attributes["version"], "3.0")
        let metadata = try XCTUnwrap(package.children.first { $0.name == "metadata" })
        let unique = metadata.children.filter { $0.name == "dc:identifier" && $0.attributes["id"] == package.attributes["unique-identifier"] }
        XCTAssertEqual(unique.map(\.content), [book.metadata.identifier])
        XCTAssertEqual(metadata.children.filter { $0.name == "dc:title" }.map(\.content), ["A Written Book"])
        XCTAssertEqual(metadata.children.filter { $0.name == "dc:language" }.map(\.content), ["en"])
        let modified = metadata.children.filter { $0.name == "meta" && $0.attributes["property"] == "dcterms:modified" }.map(\.content)
        XCTAssertEqual(modified, ["2025-06-15T15:06:40Z"], "exactly one, as CCYY-MM-DDThh:mm:ssZ")
        XCTAssertEqual(metadata.children.filter { $0.attributes["property"] == "dcterms:created" }.map(\.content), ["2023-11-14T22:13:20Z"])
        let items = try XCTUnwrap(package.children.first { $0.name == "manifest" }).children
        XCTAssertEqual(Set(items.compactMap { $0.attributes["id"] }).count, items.count, "manifest ids are unique")
        XCTAssertEqual(Set(items.compactMap { $0.attributes["href"] }).count, items.count, "manifest hrefs are unique")
        XCTAssertEqual(items.filter { ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav") }.map { $0.attributes["href"] }, ["nav.xhtml"])
        XCTAssertEqual(items.first { $0.attributes["id"] == "cover" }?.attributes["properties"], "cover-image")
        XCTAssertTrue(items.allSatisfy { $0.attributes["media-type"]?.isEmpty == false })
        let spine = try XCTUnwrap(package.children.first { $0.name == "spine" })
        XCTAssertEqual(spine.attributes["page-progression-direction"], "rtl")
        XCTAssertEqual(spine.children.map { $0.attributes["idref"] }, ["chapter", "aside", "plate"])
        XCTAssertEqual(spine.children.map { $0.attributes["linear"] }, [nil, "no", nil])
        XCTAssertEqual(spine.children.map { $0.attributes["properties"] }, [nil, nil, "rendition:layout-pre-paginated"])
        XCTAssertTrue(spine.children.allSatisfy { ref in items.contains { $0.attributes["id"] == ref.attributes["idref"] } })
    }

    func testTheNavigationDocumentIsXHTMLWithOneContentsNavAndAHiddenPageList() throws {
        var book = paged
        book.contents = [.init(title: "Part", children: [.init(title: "Chapter", href: "EPUB/chapter.xhtml"), .init(title: "Start", href: "EPUB/chapter.xhtml#start")])]
        let html = try navigation(book)
        XCTAssertEqual(html.name, "html")
        XCTAssertEqual(html.attributes["xmlns"], "http://www.w3.org/1999/xhtml")
        XCTAssertEqual(html.attributes["xmlns:epub"], "http://www.idpf.org/2007/ops")
        XCTAssertFalse(try XCTUnwrap(html.descendants("title").first).content.isEmpty)
        let navs = html.descendants("nav")
        XCTAssertEqual(navs.filter { $0.attributes["epub:type"] == "toc" }.count, 1)
        let toc = try XCTUnwrap(navs.first { $0.attributes["epub:type"] == "toc" })
        XCTAssertEqual(toc.children.filter { $0.name == "ol" }.count, 1)
        let part = try XCTUnwrap(toc.descendants("li").first)
        XCTAssertEqual(part.children.map(\.name), ["span", "ol"], "a heading without a target is a span before its list")
        XCTAssertEqual(part.descendants("a").map { $0.attributes["href"] }, ["chapter.xhtml", "chapter.xhtml#start"])
        let pages = try XCTUnwrap(navs.first { $0.attributes["epub:type"] == "page-list" })
        XCTAssertNotNil(pages.attributes["hidden"])
        XCTAssertEqual(pages.descendants("a").map(\.content), ["1"])
    }

    func testMarkupCharactersAreEscapedOnceInEveryField() throws {
        let text = #"Fish & Chips <b> "quoted" 'single' ]]> &amp; &#38; <!-- --> <?pi?>"#
        var book = Book()
        book.metadata.metadata = .init(title: text, authors: [text], languages: ["en"])
        book.metadata.identifier = "urn:test:" + text
        book.metadata.summary = text
        book.metadata.keywords = [text]
        book.addChapter(id: "c1", path: "EPUB/c1.xhtml", title: "Chapter", listed: false)
        book.contents = [.init(title: text, href: "EPUB/c1.xhtml")]
        book.pages = [.init(title: text, href: "EPUB/c1.xhtml#start")]
        let metadata = try XCTUnwrap(try package(book).children.first { $0.name == "metadata" })
        for name in ["dc:title", "dc:creator", "dc:description", "dc:subject"] {
            XCTAssertEqual(metadata.children.first { $0.name == name }?.content, text, name)
        }
        XCTAssertEqual(metadata.children.first { $0.name == "dc:identifier" }?.content, "urn:test:" + text)
        XCTAssertEqual(try navigation(book).descendants("a").map(\.content), [text, text])
    }

    func testCharactersXMLForbidsAreLeftOutOfWhatIsWritten() throws {
        var book = paged
        book.metadata.metadata = .init(title: "A\u{0}B\u{8}C\u{B}D\u{1F}E\u{FFFE}F\u{FFFF}G", authors: ["An\u{1}Author"], languages: ["en"])
        book.contents = [.init(title: "Chap\u{C}ter\tOne", href: "EPUB/chapter.xhtml")]
        let metadata = try XCTUnwrap(try package(book).children.first { $0.name == "metadata" })
        XCTAssertEqual(metadata.children.first { $0.name == "dc:title" }?.content, "ABCDEFG")
        XCTAssertEqual(metadata.children.first { $0.name == "dc:creator" }?.content, "AnAuthor")
        XCTAssertEqual(try navigation(book).descendants("a").first?.content, "Chapter\tOne")
    }

    func testResourcePathsWithReservedCharactersAreWrittenEncodedAndReadBack() async throws {
        var book = Book()
        let paths = ["EPUB/text files/chapter one.xhtml", "EPUB/chapter-#2.xhtml", "EPUB/100%-pure.xhtml", "EPUB/text/première/chapitre-é.xhtml",
                     "EPUB/第三章.xhtml", "EPUB/what?.xhtml", "EPUB/a+b&c=d;e,f@g$h!i'j(k)l~m.xhtml"]
        for (index, path) in paths.enumerated() { book.addChapter(id: "c\(index)", path: path, title: "Chapter \(index)") }
        book.pages = [.init(title: "1", href: book.files[1].resource.href + "#start")]
        let package = try package(book)
        let hrefs = package.descendants("item").compactMap { $0.attributes["href"] }.filter { $0 != "nav.xhtml" }
        XCTAssertEqual(hrefs.map { "EPUB/" + ($0.removingPercentEncoding ?? "") }, paths)
        for href in hrefs {
            XCTAssertNil(href.wholeMatch(of: #/.*[ #?<>"\\^`{|}].*/#), "\(href) is not a valid relative URL")
            XCTAssertNil(href.firstMatch(of: #/%(?![0-9A-Fa-f]{2})/#), "\(href) has a bare percent sign")
            XCTAssertTrue(href.unicodeScalars.allSatisfy(\.isASCII), "\(href) is not percent-encoded")
        }
        let links = try navigation(book).descendants("a").compactMap { $0.attributes["href"] }
        XCTAssertEqual(links.prefix(paths.count).map { "EPUB/" + ($0.removingPercentEncoding ?? "") }, paths)
        XCTAssertEqual(links.last, "chapter-%232.xhtml#start")

        let publication = try EPUBPublication.open(at: try await book.write(in: try temporaryDirectory()))
        XCTAssertEqual(publication.spine.map(\.resource.path), paths)
        XCTAssertEqual(publication.tableOfContents.map(\.href), book.files.map(\.resource.href))
        XCTAssertEqual(publication.pageList, [EPUBPageListEntry(label: "1", href: "EPUB/chapter-%232.xhtml#start")])
        for (index, item) in publication.spine.enumerated() {
            XCTAssertEqual(try publication.data(for: item.resource), book.files[index].data, paths[index])
        }
    }

    func testAWrittenBookReadsBackWithItsFacts() async throws {
        var book = Book()
        book.metadata.metadata = .init(title: "Ünïcödé — 日本語 עברית 🙂 & <more>", authors: ["First Author", "مؤلف الاختبار"], languages: ["ar"])
        book.metadata.rightToLeft = true
        book.add(id: "cover-image", path: "EPUB/images/cover.png", mediaType: "image/png", data: try Book.image(.png), properties: ["cover-image"])
        book.addChapter(id: "one", path: "EPUB/one.xhtml", title: "One")
        book.addChapter(id: "aside", path: "EPUB/aside.xhtml", title: "Aside", linear: false, listed: false)
        let plate = book.add(id: "plate", path: "EPUB/plate.xhtml", mediaType: "application/xhtml+xml", data: Book.page(title: "Plate", body: "<p>Plate.</p>"))
        book.spine.append(.init(resource: plate, layout: .prePaginated))
        book.contents = [.init(title: "Part & Parcel", children: [.init(title: "One <1>", href: "EPUB/one.xhtml#start")]), .init(title: "Plate", href: "EPUB/plate.xhtml")]
        book.pages = [.init(title: "i", href: "EPUB/one.xhtml"), .init(title: "٢", href: "EPUB/plate.xhtml")]
        let publication = try EPUBPublication.open(at: try await book.write(in: try temporaryDirectory()))
        XCTAssertEqual(publication.metadata.title, book.metadata.metadata.title)
        XCTAssertEqual(publication.metadata.authors, book.metadata.metadata.authors)
        XCTAssertEqual(publication.metadata.languages, ["ar"])
        XCTAssertEqual(publication.metadata.identifiers, [book.metadata.identifier])
        XCTAssertEqual(publication.pageProgression, .rtl)
        XCTAssertEqual(publication.cover?.path, "EPUB/images/cover.png")
        XCTAssertEqual(publication.spine, [EPUBSpineItem(resource: book.files[1].resource), EPUBSpineItem(resource: book.files[2].resource, isLinear: false),
                                           EPUBSpineItem(resource: plate, layout: .prePaginated)])
        XCTAssertEqual(publication.tableOfContents, [
            EPUBNavigationItem(title: "Part & Parcel", children: [EPUBNavigationItem(title: "One <1>", href: "EPUB/one.xhtml#start")]),
            EPUBNavigationItem(title: "Plate", href: "EPUB/plate.xhtml"),
        ])
        XCTAssertEqual(publication.pageList, [EPUBPageListEntry(label: "i", href: "EPUB/one.xhtml"), EPUBPageListEntry(label: "٢", href: "EPUB/plate.xhtml")])
    }

    func testTheArchiveStartsWithAnUnpaddedStoredMimetypeAndHoldsEachEntryOnce() async throws {
        var book = paged
        book.add(id: "css", path: "EPUB/styles/book.css", mediaType: "text/css", data: Data("p { margin: 0 }".utf8))
        let bytes = [UInt8](try Data(contentsOf: try await book.write(in: try temporaryDirectory())))
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        XCTAssertEqual(Array(bytes[0..<4]), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(u16(6) & 0x0001, 0, "not encrypted")
        XCTAssertEqual(u16(8), 0, "stored, not deflated")
        XCTAssertEqual(u16(26), 8, "the name is `mimetype`")
        XCTAssertEqual(u16(28), 0, "no extra field, so the media type starts at byte 38 (PKG-005)")
        XCTAssertEqual(String(decoding: bytes[30..<38], as: UTF8.self), "mimetype")
        XCTAssertEqual(String(decoding: bytes[38..<58], as: UTF8.self), "application/epub+zip")
        XCTAssertEqual(Array(bytes[58..<62]), [0x50, 0x4B, 0x03, 0x04], "nothing pads the media type")
        // The central directory lists every file once, with no directory entries.
        var names: [String] = [], offset = 0
        while offset + 46 <= bytes.count {
            guard Array(bytes[offset..<offset + 4]) == [0x50, 0x4B, 0x01, 0x02] else { offset += 1; continue }
            names.append(String(decoding: bytes[(offset + 46)..<(offset + 46 + u16(offset + 28))], as: UTF8.self))
            XCTAssertTrue([0, 8].contains(u16(offset + 10)), "OCF allows only stored and deflated entries")
            offset += 46 + u16(offset + 28) + u16(offset + 30) + u16(offset + 32)
        }
        XCTAssertEqual(names, ["mimetype", "EPUB/nav.xhtml", "EPUB/package.opf", "META-INF/container.xml", "EPUB/chapter.xhtml", "EPUB/styles/book.css"])
    }

    func testTheContainerNamesThePackageDocument() throws {
        let container = try XCTUnwrap(XML.parse(try paged.document("META-INF/container.xml")))
        XCTAssertEqual(container.name, "container")
        XCTAssertEqual(container.attributes["xmlns"], "urn:oasis:names:tc:opendocument:xmlns:container")
        XCTAssertEqual(container.attributes["version"], "1.0")
        let rootfiles = container.descendants("rootfile")
        XCTAssertEqual(rootfiles.map { $0.attributes["full-path"] }, ["EPUB/package.opf"])
        XCTAssertEqual(rootfiles.map { $0.attributes["media-type"] }, ["application/oebps-package+xml"])
        XCTAssertEqual(try paged.document("mimetype"), "application/epub+zip")
    }
}
