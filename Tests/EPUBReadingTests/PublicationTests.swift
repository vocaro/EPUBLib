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
