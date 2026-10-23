import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// A book opened on demand, as a Quick Look thumbnail or preview opens one (#695): the same book
/// as one read whole, of which only the entries that describe it are read at opening, and every
/// other entry when it is first asked for, held to its checksum and the limits then.
final class OnDemandOpeningTests: XCTestCase {
    private static let picture = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })

    /// The fixture book with a cover, a large picture and a stylesheet beside its two chapters.
    private func files() throws -> [String: Data] {
        var files = try Fixture.files()
        let opf = String(decoding: files["OPS/book.opf"]!, as: UTF8.self).replacingOccurrences(of: "</manifest>", with: """
            <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>\
            <item id="picture" href="picture.bin" media-type="application/octet-stream"/>\
            <item id="style" href="style.css" media-type="text/css"/></manifest>
            """)
        files["OPS/book.opf"] = Data(opf.utf8)
        files["OPS/cover.png"] = Data("not really a picture".utf8)
        files["OPS/picture.bin"] = Self.picture
        files["OPS/style.css"] = Data("p { margin: 0 }".utf8)
        return files
    }

    func testABookOpenedOnDemandIsTheBookReadWhole() throws {
        let data = try Fixture.archive(files())
        let whole = try EPUBPublication.open(data: data)
        let book = try EPUBPublication.open(data: data, onDemand: true)
        XCTAssertEqual(book.id, whole.id)
        XCTAssertEqual(book.metadata, whole.metadata)
        XCTAssertEqual(book.resources, whole.resources)
        XCTAssertEqual(book.spine, whole.spine)
        XCTAssertEqual(book.tableOfContents, whole.tableOfContents)
        XCTAssertEqual(book.landmarks, whole.landmarks)
        XCTAssertEqual(book.pageList, whole.pageList)
        XCTAssertEqual(book.cover, whole.cover)
        XCTAssertEqual(book.lostEntries, whole.lostEntries)
        XCTAssertEqual(book.archiveData, whole.archiveData)
        for resource in whole.resources {
            XCTAssertEqual(try book.data(for: resource), try whole.data(for: resource), resource.path)
        }
        XCTAssertThrowsError(try book.data(at: "OPS/absent.xhtml")) {
            XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("OPS/absent.xhtml"))
        }
    }

    func testOpeningOnDemandReadsOnlyWhatDescribesTheBook() throws {
        let files = try files()
        let data = try Fixture.archive(files)
        let whole = try EPUBPublication.open(data: data)
        let book = try EPUBPublication.open(data: data, onDemand: true)
        // The mimetype, container, package document, navigation document and NCX.
        let described = ["mimetype", "META-INF/container.xml", "OPS/book.opf", "OPS/nav.xhtml", "OPS/toc.ncx"]
            .reduce(0) { $0 + files[$1]!.count }
        XCTAssertEqual(book.expandedBytesRead, described)
        XCTAssertEqual(whole.expandedBytesRead, files.values.reduce(0) { $0 + $1.count })
        // An entry is charged once, however often it is read.
        XCTAssertEqual(try book.data(at: "OPS/cover.png"), files["OPS/cover.png"])
        XCTAssertEqual(try book.data(at: "OPS/cover.png"), files["OPS/cover.png"])
        XCTAssertEqual(book.expandedBytesRead, described + files["OPS/cover.png"]!.count)
        XCTAssertEqual(try book.data(at: "OPS/picture.bin"), Self.picture)
        XCTAssertEqual(book.expandedBytesRead, described + files["OPS/cover.png"]!.count + Self.picture.count)
    }

    func testAnEntryThatWouldRefuseTheBookIsAResourceThatCannotBeRead() throws {
        var data = try Fixture.archive(files())
        let directory = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/picture.bin", in: data))
        data[directory + 16] ^= 0xFF // The directory's CRC, which is the one read.
        XCTAssertThrowsError(try EPUBPublication.open(data: data)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidArchive("CRC: OPS/picture.bin"))
        }
        let book = try EPUBPublication.open(data: data, onDemand: true)
        for _ in 0..<2 {
            XCTAssertThrowsError(try book.data(at: "OPS/picture.bin")) {
                XCTAssertEqual($0 as? EPUBPublicationError, .invalidArchive("CRC: OPS/picture.bin"))
            }
        }
        XCTAssertEqual(try book.data(at: "OPS/style.css"), Data("p { margin: 0 }".utf8))
    }

    func testTheLimitsCountWhatIsReadOnDemand() throws {
        let data = try Fixture.archive(files())
        var limits = EPUBImportLimits()
        limits.resourceBytes = 200_000
        XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("OPS/picture.bin"))
        }
        let book = try EPUBPublication.open(data: data, limits: limits, onDemand: true)
        XCTAssertThrowsError(try book.data(at: "OPS/picture.bin")) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("OPS/picture.bin"))
        }
        XCTAssertNotNil(try book.data(at: "OPS/one.xhtml"))

        // The whole book's limit is met by the entries read, each counted once: what was read
        // stays readable, and the entry that passes the limit does not.
        let opened = try EPUBPublication.open(data: data, onDemand: true)
        limits = EPUBImportLimits()
        limits.expandedBytes = opened.expandedBytesRead + 10_000
        let bounded = try EPUBPublication.open(data: data, limits: limits, onDemand: true)
        let chapter = try bounded.data(at: "OPS/one.xhtml")
        XCTAssertEqual(try bounded.data(at: "OPS/one.xhtml"), chapter)
        XCTAssertThrowsError(try bounded.data(at: "OPS/picture.bin")) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("OPS/picture.bin"))
        }
        XCTAssertEqual(try bounded.data(at: "OPS/one.xhtml"), chapter)
    }

    func testAnObfuscatedFontIsDecodedOnDemandAsInABookReadWhole() throws {
        let font = Data((0..<2_000).map { UInt8($0 % 253) })
        let key = Array(Insecure.SHA1.hash(data: Data("test-book".utf8)))
        var obfuscated = font
        for index in 0..<1_040 { obfuscated[index] ^= key[index % key.count] }
        var files = try Fixture.files()
        files["OPS/font.otf"] = obfuscated
        files["META-INF/encryption.xml"] = Data("""
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">\
            <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>\
            <enc:CipherData><enc:CipherReference URI="OPS/font.otf"/></enc:CipherData></enc:EncryptedData></encryption>
            """.utf8)
        let book = try EPUBPublication.open(data: Fixture.archive(files), onDemand: true)
        XCTAssertEqual(try book.data(at: "OPS/font.otf"), font)
    }

    func testReadsOnSeveralThreadsAtOnceGiveTheEntriesBytes() throws {
        let book = try EPUBPublication.open(data: Fixture.archive(files()), onDemand: true)
        let paths = ["OPS/picture.bin", "OPS/one.xhtml", "OPS/two.xhtml", "OPS/style.css"]
        let expected = try paths.map { try EPUBPublication.open(data: Fixture.archive(files())).data(at: $0) }
        let results = NSMutableArray(array: Array(repeating: NSNull(), count: 64))
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let data = try? book.data(at: paths[index % paths.count])
            lock.withLock { results[index] = data ?? NSNull() }
        }
        for index in 0..<64 { XCTAssertEqual(results[index] as? Data, expected[index % paths.count], "read \(index)") }
    }

    func testAPrefixOfTheSpineKeepsTheRestOfTheBook() throws {
        let book = try EPUBPublication.open(data: Fixture.archive(files()), onDemand: true)
        let opening = book.prefix(spineItems: 1)
        XCTAssertEqual(opening.spine, Array(book.spine.prefix(1)))
        XCTAssertEqual(opening.id, book.id)
        XCTAssertEqual(opening.resources, book.resources)
        XCTAssertEqual(opening.tableOfContents, book.tableOfContents)
        XCTAssertEqual(opening.cover, book.cover)
        XCTAssertEqual(try opening.data(at: "OPS/two.xhtml"), try book.data(at: "OPS/two.xhtml"))
        XCTAssertEqual(book.prefix(spineItems: 0).spine.count, 1, "a spine is never empty")
    }
}
