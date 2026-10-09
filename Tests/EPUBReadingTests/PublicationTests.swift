import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest

final class PublicationTests: XCTestCase {
    func testEPUB3MetadataSpineNestedContentsAndResources() throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        XCTAssertEqual(book.metadata.title, "A Test Book")
        XCTAssertEqual(book.metadata.authors, ["Test Author"])
        XCTAssertEqual(book.metadata.languages, ["en"])
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter")
        XCTAssertEqual(book.tableOfContents.first?.href, "OPS/one.xhtml#start")
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, "OPS/two.xhtml")
        XCTAssertTrue(String(decoding: try book.data(for: book.spine[0].resource), as: UTF8.self).contains("Opening words"))
    }
    func testEPUB2NCX() throws {
        let book = try EPUBPublication.open(data: Fixture.epub(epub2: true))
        XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter")
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, "OPS/two.xhtml")
    }
    func testSnapshotIdentityAndSourceReplacement() throws {
        let bytes = try Fixture.epub()
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".epub")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try EPUBPublication.open(at: url)
        try Data("replacement".utf8).write(to: url)
        XCTAssertEqual(book.archiveData, bytes)
        XCTAssertEqual(book.id, try EPUBPublication.open(data: bytes).id)
        XCTAssertEqual(book.id.count, 64)
    }
    func testArchiveAndExpansionLimits() throws {
        let bytes = try Fixture.epub()
        for keyPath in [\EPUBImportLimits.archiveBytes, \.resourceBytes, \.expandedBytes, \.entryCount, \.xmlBytes] {
            var limits = EPUBImportLimits()
            limits[keyPath: keyPath] = 1
            XCTAssertThrowsError(try EPUBPublication.open(data: bytes, limits: limits))
        }
    }
    func testTraversalAndRemoteReferencesFail() throws {
        for path in ["../escape", "/absolute", "a/../../escape", "a\\escape"] {
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: [path: "bad"])))
        }
        for href in ["../../../outside", "https://example.invalid/book", "%2e%2e/%2e%2e/escape"] {
            let xml = "<container><rootfiles><rootfile full-path=\"\(href)\"/></rootfiles></container>"
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["META-INF/container.xml": xml])))
        }
    }
    func testMalformedXMLMissingSpineAndEntitiesFail() throws {
        for xml in ["<broken>", "<package><manifest/><spine/></package>",
                    "<!DOCTYPE package [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><package>&x;</package>"] {
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": xml])))
        }
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["META-INF/encryption.xml": "<encryption/>"]))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsupportedEncryption)
        }
    }
    func testMissingResourceIsTyped() throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        XCTAssertThrowsError(try book.data(at: "../secret")) {
            XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("../secret"))
        }
    }
}

extension PublicationTests {
    func testPercentEncodedResourceNamesAndRelativeNavigation() throws {
        let original = try EPUBPublication.open(data: Fixture.epub())
        let opf = String(decoding: try original.data(at: "OPS/book.opf"), as: UTF8.self)
            .replacingOccurrences(of: "one.xhtml", with: "chapter%23one.xhtml")
        let nav = String(decoding: try original.data(at: "OPS/nav.xhtml"), as: UTF8.self)
            .replacingOccurrences(of: "one.xhtml#start", with: "./chapter%23one.xhtml#start")
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: [
            "OPS/book.opf": opf, "OPS/nav.xhtml": nav, "OPS/chapter#one.xhtml": "<html/>",
        ]))
        XCTAssertEqual(book.spine[0].resource.path, "OPS/chapter#one.xhtml")
        XCTAssertEqual(book.tableOfContents[0].href, "OPS/chapter%23one.xhtml#start")
    }
    func testIDPFFontObfuscationIsDecodedWithoutChangingArchive() throws {
        // A zero-byte source makes the expected decoded bytes exactly the SHA-1 key.
        let xml = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><CipherData><CipherReference URI="OPS/font.otf"/></CipherData></EncryptedData></encryption>
        """
        let data = try Fixture.epub(overrides: ["META-INF/encryption.xml": xml, "OPS/font.otf": String(repeating: "\0", count: 1050)])
        let book = try EPUBPublication.open(data: data)
        let decoded = try book.data(at: "OPS/font.otf")
        XCTAssertNotEqual(decoded.prefix(20), Data(repeating: 0, count: 20))
        XCTAssertEqual(decoded.prefix(20), decoded[20..<40])
        XCTAssertEqual(decoded.suffix(10), Data(repeating: 0, count: 10))
        XCTAssertEqual(book.archiveData, data)
    }
}

extension PublicationTests {
    func testHTMLDoctypeAllowsOrdinaryBracketsInNavigationText() throws {
        let xml = "<!DOCTYPE html><html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><ol><li><a href='one.xhtml'>Chapter [One]</a></li></ol></nav></body></html>"
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": xml]))
        XCTAssertEqual(book.tableOfContents[0].title, "Chapter [One]")
    }
}

extension PublicationTests {
    func testLandmarksComeFromTheNavigationDocument() throws {
        let book = try EPUBPublication.open(data: Fixture.frontMatter(text: "text/chapter-2.xhtml"))
        XCTAssertEqual(book.landmarks, [
            EPUBLandmark(types: ["cover"], title: "Cover", href: "OPS/text/cover.xhtml"),
            EPUBLandmark(types: ["titlepage"], title: "Titlepage", href: "OPS/text/titlepage.xhtml"),
            EPUBLandmark(types: ["bodymatter", "z3998:fiction"], title: "A Front-Matter Book", href: "OPS/text/chapter-1.xhtml"),
        ], "the navigation document's landmarks, not the guide's references")
        XCTAssertTrue(try EPUBPublication.open(data: Fixture.frontMatter(bodymatter: nil)).landmarks.isEmpty)
    }

    func testGuideReferencesAreTheLandmarksOfABookWithoutThem() throws {
        let guide = [
            EPUBLandmark(types: ["cover"], title: "Cover", href: "OPS/text/cover.xhtml"),
            EPUBLandmark(types: ["title-page"], title: "Titlepage", href: "OPS/text/titlepage.xhtml"),
            EPUBLandmark(types: ["text"], title: "Text", href: "OPS/text/chapter-1.xhtml#chapter-1"),
        ]
        for epub2 in [true, false] {
            let book = try EPUBPublication.open(data: Fixture.frontMatter(bodymatter: nil, text: "text/chapter-1.xhtml#chapter-1", epub2: epub2))
            XCTAssertEqual(book.landmarks, guide, epub2 ? "EPUB 2" : "a navigation document without landmarks")
        }
    }

    func testALandmarkOutsideTheArchiveIsLeftOutWithoutRefusingTheBook() throws {
        for href in ["../../outside.xhtml", "https://example.invalid/chapter.xhtml", "/absolute.xhtml"] {
            let book = try EPUBPublication.open(data: Fixture.frontMatter(bodymatter: href, text: href))
            XCTAssertEqual(book.landmarks.map(\.types), [["cover"], ["titlepage"]], href)
            let epub2 = try EPUBPublication.open(data: Fixture.frontMatter(bodymatter: nil, text: href, epub2: true))
            XCTAssertEqual(epub2.landmarks.map(\.types), [["cover"], ["title-page"]], href)
        }
    }

    func testARepeatedManifestItemIsReadOnceAndAConflictingOneRefused() throws {
        let original = try EPUBPublication.open(data: Fixture.epub())
        let opf = String(decoding: try original.data(at: "OPS/book.opf"), as: UTF8.self)
        let item = #"<item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>"#
        let repeated = try EPUBPublication.open(data: Fixture.epub(overrides: [
            "OPS/book.opf": opf.replacingOccurrences(of: item, with: item + item + item),
        ]))
        XCTAssertEqual(repeated.resources, original.resources)
        XCTAssertEqual(repeated.spine, original.spine)
        let conflicting = #"<item id="two" href="one.xhtml" media-type="application/xhtml+xml"/>"#
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: [
            "OPS/book.opf": opf.replacingOccurrences(of: item, with: item + conflicting),
        ]))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("Manifest item"))
        }
    }

    func testAManifestItemTheArchiveLacksIsLeftOutUnlessTheSpineNamesIt() throws {
        let original = try EPUBPublication.open(data: Fixture.epub())
        let opf = String(decoding: try original.data(at: "OPS/book.opf"), as: UTF8.self)
            .replacingOccurrences(of: "<manifest>", with: #"<manifest><item id="cover" href="Images/cover.jpeg" media-type="image/jpeg"/>"#)
            .replacingOccurrences(of: "</metadata>", with: #"<meta name="cover" content="cover"/></metadata>"#)
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": opf]))
        XCTAssertEqual(book.resources, original.resources)
        XCTAssertEqual(book.spine, original.spine)
        XCTAssertNil(book.cover)
        XCTAssertThrowsError(try book.data(at: "OPS/Images/cover.jpeg")) {
            XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("OPS/Images/cover.jpeg"))
        }
        var files = try Fixture.files()
        files["OPS/two.xhtml"] = nil
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("OPS/two.xhtml"))
        }
    }

    func testAControlCharacterCopiedIntoNavigationReadsAsASpace() throws {
        let original = try EPUBPublication.open(data: Fixture.epub())
        let nav = String(decoding: try original.data(at: "OPS/nav.xhtml"), as: UTF8.self)
            .replacingOccurrences(of: "Second Chapter", with: "Second\u{18}Chapter")
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": nav]))
        XCTAssertEqual(book.tableOfContents, original.tableOfContents)
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: [
            "OPS/nav.xhtml": nav.replacingOccurrences(of: "</nav>", with: "</nav"),
        ])))
    }
}

extension PublicationTests {
    func testThePageListComesFromAHiddenNavigationListInOrder() throws {
        let book = try EPUBPublication.open(data: Fixture.pageList())
        XCTAssertEqual(book.pageList?.map(\.label), Fixture.pageLabels)
        XCTAssertEqual(book.pageList?.first, EPUBPageListEntry(label: "i", href: "OPS/front.xhtml#page-i"))
        XCTAssertEqual(book.pageList?.last, EPUBPageListEntry(label: "5", href: "OPS/chapter-2.xhtml#page-5"))
        let plain = try EPUBPublication.open(data: Fixture.epub())
        XCTAssertNil(plain.pageList, "a book without one")
        XCTAssertEqual(plain.tableOfContents.map(\.title), ["First Chapter"])
    }

    func testAPageListIsReadInDocumentOrderLeavingOutWhatDoesNotResolve() throws {
        func pages(_ list: String) throws -> [EPUBPageListEntry]? {
            let nav = String(decoding: try Fixture.files()["OPS/nav.xhtml"]!, as: UTF8.self)
                .replacingOccurrences(of: "</body>", with: "<nav epub:type=\"page-list\" hidden=\"\">\(list)</nav></body>")
            return try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": nav])).pageList
        }
        // As EPUBPackageWriter writes it for a book without pages.
        XCTAssertNil(try pages("<h2>Source pages</h2><ol></ol>"))
        XCTAssertNil(try pages("<ol><li><a href=\"https://example.invalid/one.xhtml\">1</a></li></ol>"))
        XCTAssertEqual(try pages("""
            <ol><li><a href="one.xhtml#p1"> 1 </a></li><li><span>No link</span></li>\
            <li><a href="../../outside.xhtml">2</a></li><li><a href="two.xhtml">3</a><ol><li><a href="two.xhtml#p4">4</a></li></ol></li></ol>
            """), [EPUBPageListEntry(label: "1", href: "OPS/one.xhtml#p1"), EPUBPageListEntry(label: "3", href: "OPS/two.xhtml"),
                   EPUBPageListEntry(label: "4", href: "OPS/two.xhtml#p4")], "a nested list in document order")
    }

    func testTheNCXPageListFillsAPageListTheNavigationDocumentLacks() throws {
        let ncx = String(decoding: try Fixture.files()["OPS/toc.ncx"]!, as: UTF8.self).replacingOccurrences(of: "</ncx>", with: """
            <pageList><navLabel><text>Pages</text></navLabel><pageTarget id="p1" type="normal" value="1" playOrder="3">\
            <navLabel><text>1</text></navLabel><content src="one.xhtml#start"/></pageTarget><pageTarget id="p2" type="normal" \
            value="2" playOrder="4"><navLabel><text>2</text></navLabel><content src="two.xhtml"/></pageTarget></pageList></ncx>
            """)
        let pages = [EPUBPageListEntry(label: "1", href: "OPS/one.xhtml#start"), EPUBPageListEntry(label: "2", href: "OPS/two.xhtml")]
        for epub2 in [true, false] {
            let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/toc.ncx": ncx], epub2: epub2))
            XCTAssertEqual(book.pageList, pages, epub2 ? "EPUB 2" : "a navigation document without a page list")
        }
        let nav = String(decoding: try Fixture.files()["OPS/nav.xhtml"]!, as: UTF8.self).replacingOccurrences(of: "</body>",
            with: "<nav epub:type=\"page-list\"><ol><li><a href=\"two.xhtml#x\">ii</a></li></ol></nav></body>")
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/toc.ncx": ncx, "OPS/nav.xhtml": nav])).pageList,
                       [EPUBPageListEntry(label: "ii", href: "OPS/two.xhtml#x")], "the navigation document's own list")
        // An EPUB 3 book never needed its NCX to open.
        XCTAssertNil(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/toc.ncx": "<ncx><pageList>"])).pageList)
    }

    func testALocationSavedWithoutPagesStillDecodes() throws {
        let saved = #"{"publicationID":"book","href":"OPS/one.xhtml","progression":0.5,"title":"First Chapter","#
            + #""bookmark":{"engineID":"org.epublib.reader","format":"epublib-cfi-v1","value":"epubcfi(/6/2!/4/2/1:0)"}}"#
        var location = try JSONDecoder().decode(EPUBLocation.self, from: Data(saved.utf8))
        XCTAssertEqual(location.title, "First Chapter")
        XCTAssertNil(location.page)
        XCTAssertNil(location.pages)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(location), as: UTF8.self).contains("page"))
        location.page = EPUBPageListEntry(label: "4", href: "OPS/one.xhtml#page-4")
        location.pages = [EPUBPageListEntry(label: "4", href: "OPS/one.xhtml#page-4"), EPUBPageListEntry(label: "5", href: "OPS/two.xhtml")]
        XCTAssertEqual(try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(location)), location)
    }
}
