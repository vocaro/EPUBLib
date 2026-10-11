import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// `META-INF/container.xml` and `META-INF/encryption.xml`.
final class ContainerDocumentCoverageTests: XCTestCase {
    private static let idpf = "http://www.idpf.org/2008/embedding"
    private static let adobe = "http://ns.adobe.com/pdf/enc#RC"

    /// The plain book with everything under `OPS/` moved to `folder` ("" for the container root)
    /// and its package document renamed, as `fullPath` then has to say.
    private func relocated(to folder: String, package: String = "book.opf", fullPath: String) throws -> Data {
        var files: [String: Data] = [:]
        for (path, data) in try Fixture.files() {
            files[path.hasPrefix("OPS/") ? folder + (path == "OPS/book.opf" ? package : String(path.dropFirst(4))) : path] = data
        }
        files["META-INF/container.xml"] = Data(String(decoding: files["META-INF/container.xml"]!, as: UTF8.self)
            .replacingOccurrences(of: "OPS/book.opf", with: fullPath).utf8)
        return try Fixture.archive(files)
    }

    private func container(_ rootfiles: String) -> (String) -> String {
        { _ in "<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\">\(rootfiles)</container>" }
    }

    private func assertOpening(_ data: @autoclosure () throws -> Data, throws expected: EPUBPublicationError,
                               _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EPUBPublication.open(data: data()), message, file: file, line: line) {
            XCTAssertEqual($0 as? EPUBPublicationError, expected, "\(message): \($0)", file: file, line: line)
        }
    }

    // MARK: container.xml

    func testAPackageDocumentInTheContainerRootResolvesItsReferencesFromTheRoot() throws {
        let book = try EPUBPublication.open(data: relocated(to: "", fullPath: "book.opf"))
        XCTAssertEqual(book.spine.map(\.resource.path), ["one.xhtml", "two.xhtml"])
        XCTAssertEqual(book.spine[0].resource.href, "one.xhtml")
        XCTAssertEqual(book.tableOfContents.first?.href, "one.xhtml#start")
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, "two.xhtml")
    }

    func testThePackageDocumentMayHaveAnyNameInAnyFolder() throws {
        let book = try EPUBPublication.open(data: relocated(to: "a/b c/d/", package: "volume.xml", fullPath: "a/b c/d/volume.xml"))
        XCTAssertEqual(book.metadata.title, "A Test Book")
        XCTAssertEqual(book.spine.map(\.resource.path), ["a/b c/d/one.xhtml", "a/b c/d/two.xhtml"])
        XCTAssertEqual(book.spine[0].resource.href, "a/b%20c/d/one.xhtml")
        XCTAssertEqual(book.tableOfContents.first?.href, "a/b%20c/d/one.xhtml#start")
    }

    func testARootfilePathOutsideASCIINamesItsFile() throws {
        let book = try EPUBPublication.open(data: relocated(to: "B\u{FC}cher/", package: "\u{672C}.opf", fullPath: "B\u{FC}cher/\u{672C}.opf"))
        XCTAssertEqual(book.spine.map(\.resource.path), ["B\u{FC}cher/one.xhtml", "B\u{FC}cher/two.xhtml"])
        XCTAssertEqual(book.tableOfContents.first?.href, "B%C3%BCcher/one.xhtml#start")
    }

    func testAPercentEncodedRootfilePathNamesTheDecodedFile() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/81")
        // EPUB 3.3 §4.2.6.3.1.3: full-path is a path-relative-scheme-less-URL string, so a space
        // in the path is written %20.
        let literal = try EPUBPublication.open(data: relocated(to: "My Books/", fullPath: "My Books/book.opf"))
        XCTAssertEqual(literal.spine.map(\.resource.path), ["My Books/one.xhtml", "My Books/two.xhtml"], "written with a space")
        XCTAssertEqual(try EPUBPublication.open(data: relocated(to: "My Books/", fullPath: "My%20Books/book.opf")).spine.map(\.resource.path),
                       ["My Books/one.xhtml", "My Books/two.xhtml"], "written %20")
    }

    func testTheFirstRootfileNamesThePackageDocument() throws {
        // EPUB Reading Systems 3.3 §4.1.3: by default the package document of the first rootfile.
        let other = String(decoding: try Fixture.files()["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "A Test Book", with: "Another Rendition")
        func title(_ paths: [String]) throws -> String {
            let rootfiles = paths.map { "<rootfile full-path=\"\($0)\" media-type=\"application/oebps-package+xml\"/>" }.joined()
            return try EPUBPublication.open(data: Fixture.packageVariant(container: container("<rootfiles>\(rootfiles)</rootfiles>"),
                                                                         adding: ["OPS/other.opf": Data(other.utf8)])).metadata.title
        }
        XCTAssertEqual(try title(["OPS/book.opf", "OPS/other.opf"]), "A Test Book")
        XCTAssertEqual(try title(["OPS/other.opf", "OPS/book.opf", "OPS/missing.opf"]), "Another Rendition")
    }

    func testAContainerDocumentAsPackagingToolsWriteItIsRead() throws {
        // A byte-order mark, a declaration, a prefix for the namespace, attributes in another
        // order and elements this library has no use for.
        let xml = """
            \u{FEFF}<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <!-- Written by a packaging tool -->
            <ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <ocf:rootfiles>
                <ocf:rootfile
                    media-type="application/oebps-package+xml"
                    full-path="OPS/book.opf" />
              </ocf:rootfiles>
              <ocf:links><ocf:link href="OPS/map.xml" rel="mapping" media-type="application/xml"/></ocf:links>
            </ocf:container>

            """
        let book = try EPUBPublication.open(data: Fixture.packageVariant(container: { _ in xml }))
        XCTAssertEqual(book.metadata.title, "A Test Book")
    }

    func testAContainerThatNamesNoReadablePackageDocumentFailsTyped() throws {
        assertOpening(try Fixture.packageVariant(adding: ["META-INF/container.xml": nil]), throws: .missingResource("META-INF/container.xml"))
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles/>")), throws: .invalidXML("container rootfile"), "no rootfile")
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile media-type=\"application/oebps-package+xml\"/></rootfiles>")),
                      throws: .invalidXML("container rootfile"), "no full-path")
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"\"/></rootfiles>")),
                      throws: .invalidXML("container rootfile"), "an empty full-path")
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"OPS/absent.opf\"/></rootfiles>")),
                      throws: .missingResource("OPS/absent.opf"))
        assertOpening(try Fixture.packageVariant(container: { _ in "<container><rootfiles>" }), throws: .invalidXML("META-INF/container.xml"))
        assertOpening(try Fixture.packageVariant(container: { _ in "" }), throws: .invalidXML("META-INF/container.xml"), "an empty file")
        assertOpening(try Fixture.packageVariant(container: container("<rootfiles><rootfile full-path=\"OPS/one.xhtml\"/></rootfiles>")),
                      throws: .invalidXML("OPF package, manifest or spine"), "a rootfile that is no package document")
    }

    func testFilesNoManifestListsAreIgnoredButReadable() throws {
        // What stores and tools leave in a container; EPUB 3.3 §4.2.6.1 lets META-INF hold more.
        let extras: [String: Data?] = [
            "META-INF/com.apple.ibooks.display-options.xml": Data("<display_options/>".utf8),
            "META-INF/calibre_bookmarks.txt": Data("encoding=json+base64:".utf8),
            "META-INF/rights.xml": Data("<rights/>".utf8), "META-INF/signatures.xml": Data("<signatures/>".utf8),
            "iTunesMetadata.plist": Data("<plist/>".utf8), "OPS/Thumbs.db": Data([0, 1, 2]),
            // As a Mac's Finder archives a folder.
            "__MACOSX/OPS/._one.xhtml": Data([0, 5, 22, 7]), "OPS/.DS_Store": Data([0, 0, 0, 1]),
        ]
        let plain = try EPUBPublication.open(data: Fixture.epub())
        let book = try EPUBPublication.open(data: Fixture.packageVariant(adding: extras))
        XCTAssertEqual(book.resources, plain.resources)
        XCTAssertEqual(book.metadata, plain.metadata)
        XCTAssertEqual(try book.data(at: "OPS/Thumbs.db"), Data([0, 1, 2]))
    }

    // MARK: encryption.xml

    private func encryption(_ entries: [(algorithm: String, uri: String)]) -> Data {
        let body = entries.map {
            "<enc:EncryptedData><enc:EncryptionMethod Algorithm=\"\($0.algorithm)\"/><enc:CipherData>"
                + "<enc:CipherReference URI=\"\($0.uri)\"/></enc:CipherData></enc:EncryptedData>"
        }.joined(separator: "\n  ")
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              \(body)
            </encryption>
            """.utf8)
    }

    private func obfuscated(_ original: Data, key: [UInt8], prefix: Int) -> Data {
        var bytes = original
        for index in 0..<min(prefix, bytes.count) { bytes[index] ^= key[index % key.count] }
        return bytes
    }

    private func sha1(_ text: String) -> [UInt8] { Array(Insecure.SHA1.hash(data: Data(text.utf8))) }

    private func font(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }) }

    /// The plain book with its unique identifier's element content replaced by `identifier`.
    private func book(identifier: String, fonts: [String: Data], encryption: Data) throws -> Data {
        var adding: [String: Data?] = ["META-INF/encryption.xml": encryption]
        for (path, data) in fonts { adding[path] = data }
        return try Fixture.packageVariant(opf: { $0.replacingOccurrences(of: ">test-book<", with: ">\(identifier)<") }, adding: adding)
    }

    func testObfuscatedFontsShorterThanAtAndBeyondTheObfuscatedPrefix() throws {
        let uuid = "urn:uuid:00112233-4455-6677-8899-aabbccddeeff"
        let cases: [(algorithm: String, key: [UInt8], prefix: Int)] = [
            (Self.idpf, sha1(uuid), 1040),
            (Self.adobe, Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11)), 1024),
        ]
        for (algorithm, key, prefix) in cases {
            for count in [0, 1, key.count - 1, key.count, key.count + 1, prefix - 1, prefix, prefix + 1, 3_000] {
                let original = font(count)
                let data = try book(identifier: uuid, fonts: ["OPS/font.otf": obfuscated(original, key: key, prefix: prefix)],
                                    encryption: encryption([(algorithm, "OPS/font.otf")]))
                XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/font.otf"), original, "\(algorithm), \(count) bytes")
            }
        }
    }

    func testSeveralFontsUnderBothAlgorithmsAreEachDecodedOnce() throws {
        let uuid = "urn:uuid:00112233-4455-6677-8899-aabbccddeeff"
        let adobeKey = Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11))
        let originals = ["OPS/fonts/a.otf": font(2_000), "OPS/fonts/b.ttf": font(1_500), "OPS/fonts/c.woff": font(900), "OPS/plain.otf": font(1_200)]
        let data = try book(identifier: uuid, fonts: [
            "OPS/fonts/a.otf": obfuscated(originals["OPS/fonts/a.otf"]!, key: sha1(uuid), prefix: 1040),
            "OPS/fonts/b.ttf": obfuscated(originals["OPS/fonts/b.ttf"]!, key: adobeKey, prefix: 1024),
            "OPS/fonts/c.woff": obfuscated(originals["OPS/fonts/c.woff"]!, key: sha1(uuid), prefix: 1040),
            "OPS/plain.otf": originals["OPS/plain.otf"]!,
        ], encryption: encryption([(Self.idpf, "OPS/fonts/a.otf"), (Self.adobe, "OPS/fonts/b.ttf"), (Self.idpf, "OPS/fonts/c.woff")]))
        let book = try EPUBPublication.open(data: data)
        for (path, original) in originals { XCTAssertEqual(try book.data(at: path), original, path) }
        XCTAssertEqual(book.archiveData, data)
    }

    func testACipherReferenceIsAPercentEncodedPathFromTheContainerRoot() throws {
        // EPUB 3.3 §4.2.5: in META-INF files, URLs are relative to the root, not to the package.
        let original = font(1_100)
        let data = try book(identifier: "test-book", fonts: ["OPS/fonts/My Font \u{E9}.otf": obfuscated(original, key: sha1("test-book"), prefix: 1040)],
                            encryption: encryption([(Self.idpf, "OPS/fonts/My%20Font%20%C3%A9.otf")]))
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/fonts/My Font \u{E9}.otf"), original)
    }

    func testTheIDPFKeyIgnoresXMLWhiteSpaceInTheIdentifier() throws {
        // EPUB 3.3 §4.4.3: U+0020, U+0009, U+000D and U+000A are removed before hashing.
        let original = font(1_100)
        let data = try book(identifier: "\n    urn:isbn: 978 0\t00 000000\n 2\r\n  ",
                            fonts: ["OPS/font.otf": obfuscated(original, key: sha1("urn:isbn:9780000000002"), prefix: 1040)],
                            encryption: encryption([(Self.idpf, "OPS/font.otf")]))
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/font.otf"), original)
    }

    func testTheIDPFKeyKeepsOtherSpaceCharactersOfTheIdentifier() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/82")
        // EPUB 3.3 §4.4.3 removes "specifically, the Unicode code points U+0020, U+0009, U+000D
        // and U+000A"; an ideographic or no-break space inside the identifier is part of the key.
        let identifier = "\u{66F8}\u{540D}\u{3000}\u{7B2C}\u{4E00}\u{5DFB}\u{A0}2"
        let original = font(1_100)
        let data = try book(identifier: identifier, fonts: ["OPS/font.otf": obfuscated(original, key: sha1(identifier), prefix: 1040)],
                            encryption: encryption([(Self.idpf, "OPS/font.otf")]))
        let decoded = try EPUBPublication.open(data: data).data(at: "OPS/font.otf")
        XCTAssertEqual(Array(decoded.prefix(8)), Array(original.prefix(8)), "the font's first bytes")
        XCTAssertEqual(decoded.suffix(60), original.suffix(60), "bytes after the obfuscated prefix are never changed")
    }

    func testAnAdobeKeyIsReadFromAnUpperCaseOrPaddedIdentifier() throws {
        let key = Array(stride(from: UInt8(0x00), through: UInt8(0xff), by: 0x11))
        let original = font(1_100)
        for identifier in ["urn:uuid:00112233-4455-6677-8899-AABBCCDDEEFF", "\n  urn:uuid:00112233-4455-6677-8899-aabbccddeeff\n  "] {
            let data = try book(identifier: identifier, fonts: ["OPS/font.otf": obfuscated(original, key: key, prefix: 1024)],
                                encryption: encryption([(Self.adobe, "OPS/font.otf")]))
            XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/font.otf"), original, identifier)
        }
    }

    func testEncryptionThatCannotBeUndoneFailsAsUnsupported() throws {
        func entry(_ method: String, _ cipher: String) -> Data {
            Data(("<encryption xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" xmlns:enc=\"http://www.w3.org/2001/04/xmlenc#\">"
                + "<enc:EncryptedData>\(method)\(cipher)</enc:EncryptedData></encryption>").utf8)
        }
        let reference = "<enc:CipherData><enc:CipherReference URI=\"OPS/one.xhtml\"/></enc:CipherData>"
        let documents = [
            // A rights-managed chapter, as a store's DRM writes it.
            "AES": entry("<enc:EncryptionMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#aes256-cbc\"/>"
                + "<ds:KeyInfo xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\"><ds:RetrievalMethod URI=\"license.lcpl#/encryption/content_key\"/>"
                + "</ds:KeyInfo>", reference),
            "no method": entry("", reference),
            "no reference": entry("<enc:EncryptionMethod Algorithm=\"\(Self.idpf)\"/>", "<enc:CipherData/>"),
            "an algorithm of its own": entry("<enc:EncryptionMethod Algorithm=\"urn:example:scramble\"/>", reference),
        ]
        for (name, document) in documents {
            assertOpening(try Fixture.packageVariant(adding: ["META-INF/encryption.xml": document]), throws: .unsupportedEncryption, name)
        }
        // A key cannot be derived from an identifier that is no UUID, or from none.
        assertOpening(try book(identifier: "test-book", fonts: ["OPS/font.otf": font(100)], encryption: encryption([(Self.adobe, "OPS/font.otf")])),
                      throws: .unsupportedEncryption, "Adobe without a UUID")
        assertOpening(try book(identifier: "  ", fonts: ["OPS/font.otf": font(100)], encryption: encryption([(Self.idpf, "OPS/font.otf")])),
                      throws: .unsupportedEncryption, "IDPF without an identifier")
        assertOpening(try Fixture.packageVariant(adding: ["META-INF/encryption.xml": Data("<encryption><EncryptedData>".utf8)]),
                      throws: .invalidXML("META-INF/encryption.xml"))
    }
}
