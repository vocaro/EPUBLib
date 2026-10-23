import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// The identity a host keys a saved position on (https://github.com/vocaro/EPUBLib/issues/679).
///
/// `id` is the SHA-256 of the file's bytes, which change when a book is downloaded again, zipped
/// again with other compression or edited in its metadata, as Calibre does. `persistentID` is the
/// package's unique identifier, which EPUB 3.3 §5.5.3.1.1 asks its makers to keep through "minor
/// revisions such as updating metadata", and the SHA-256 of the content where it has none.
final class PublicationIdentityTests: XCTestCase {
    private typealias Book = Fixture.SpecBook

    private let identifier = "urn:uuid:A1B0D67E-2E81-4DF5-9E67-A64CBE366809"

    private func book() -> Book {
        var book = Book()
        book.identifier = identifier
        book.add("one", body: "<h1 id=\"start\">One</h1><p>The first chapter.</p>")
        book.add("two", body: "<h1>Two</h1><p>The second chapter.</p>")
        return book
    }

    /// The book's files with its package document changed by `edit`.
    private func edited(_ files: [String: Data], _ edit: (String) -> String) -> [String: Data] {
        var files = files
        files["EPUB/package.opf"] = Data(edit(String(decoding: files["EPUB/package.opf"]!, as: UTF8.self)).utf8)
        return files
    }

    /// The package's metadata edited as a library manager edits it: another title and author, a
    /// series, another identifier beside the unique one, and a new modification date.
    private func metadataEdited(_ files: [String: Data]) -> [String: Data] {
        edited(files) {
            $0.replacingOccurrences(of: "<dc:title>A Conformance Book</dc:title>", with: "<dc:title>A Conformance Book, Revised</dc:title>")
                .replacingOccurrences(of: "<dc:creator>Test Author</dc:creator>",
                                      with: "<dc:creator>Test Author</dc:creator><dc:creator>An Editor</dc:creator>"
                                        + "<dc:identifier>isbn:9780000000002</dc:identifier>"
                                        + "<meta name=\"calibre:series\" content=\"Tests\"/>")
                .replacingOccurrences(of: "2026-01-01T00:00:00Z", with: "2026-10-22T08:00:00Z")
        }
    }

    private func open(_ files: [String: Data]) throws -> EPUBPublication { try EPUBPublication.open(data: Fixture.archive(files)) }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Acceptance: a position saved in a book restores in a copy zipped again with other
    /// compression and in a copy whose metadata alone was changed. Each copy is other bytes and has
    /// another `id`; each has the book's `persistentID`.
    func testThePersistentIDOutlastsAnotherZipAndAMetadataEdit() throws {
        let files = book().archiveFiles
        let original = try Fixture.archive(files)
        let book = try EPUBPublication.open(data: original)
        XCTAssertEqual(book.id, sha256(original))
        XCTAssertEqual(book.uniqueIdentifier, identifier)
        XCTAssertEqual(book.persistentID, identifier)
        for (name, copy) in [("stored", try Fixture.rezipped(files, compression: .none)),
                             ("deflated in another order", try Fixture.rezipped(files, compression: .deflate)),
                             ("metadata edited", try Fixture.archive(metadataEdited(files)))] {
            XCTAssertNotEqual(copy, original, name)
            let opened = try EPUBPublication.open(data: copy)
            XCTAssertEqual(opened.id, sha256(copy), "\(name): the id is still the file's")
            XCTAssertNotEqual(opened.id, book.id, name)
            XCTAssertEqual(opened.persistentID, book.persistentID, name)
            XCTAssertTrue(opened.publicationIDs.contains(book.persistentID), name)
        }
    }

    /// Acceptance: another edition, with another unique identifier, is not taken for the same
    /// book, though its files are otherwise the same.
    func testAnotherEditionIsAnotherBook() throws {
        var other = book()
        other.identifier = "urn:uuid:0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
        let book = try open(book().archiveFiles), edition = try open(other.archiveFiles)
        XCTAssertEqual(edition.persistentID, other.identifier)
        XCTAssertNotEqual(edition.persistentID, book.persistentID)
        XCTAssertFalse(edition.publicationIDs.contains(book.persistentID), "a location saved in the first is not the edition's")
        XCTAssertFalse(edition.publicationIDs.contains(book.id))
        XCTAssertFalse(book.publicationIDs.contains(edition.persistentID))
    }

    /// The release identifier tells versions apart: EPUB 3.0.1 §4.1.2's example, the unique
    /// identifier and `dcterms:modified` joined by `@` without white space, with the ends of
    /// each value read past as a metadata value's are.
    func testTheReleaseIdentifierJoinsTheUniqueIdentifierAndTheModificationDate() throws {
        let files = edited(book().archiveFiles) {
            $0.replacingOccurrences(of: ">\(identifier)<", with: ">\n      \(identifier)\n    <")
                .replacingOccurrences(of: "2026-01-01T00:00:00Z", with: " 2011-01-01T12:00:00Z ")
        }
        let book = try open(files)
        XCTAssertEqual(book.uniqueIdentifier, identifier)
        XCTAssertEqual(book.releaseIdentifier, "urn:uuid:A1B0D67E-2E81-4DF5-9E67-A64CBE366809@2011-01-01T12:00:00Z")
        XCTAssertEqual(book.persistentID, identifier)
        // The edited copy is another version of the same book.
        let revised = try open(metadataEdited(self.book().archiveFiles))
        XCTAssertEqual(revised.releaseIdentifier, identifier + "@2026-10-22T08:00:00Z")
        XCTAssertEqual(try open(self.book().archiveFiles).releaseIdentifier, identifier + "@2026-01-01T00:00:00Z")
    }

    /// The last modification date is the `dcterms:modified` that refines nothing (EPUB 3.3
    /// §5.5.5); a package without one, as every EPUB 2 package is, has no release identifier.
    func testAReleaseIdentifierNeedsTheModificationDateOfThePackage() throws {
        let refining = edited(book().archiveFiles) {
            $0.replacingOccurrences(of: "<meta property=\"dcterms:modified\">",
                                    with: "<meta property=\"dcterms:modified\" refines=\"#uid\">2020-02-02T00:00:00Z</meta>\n<meta property=\"dcterms:modified\">")
        }
        XCTAssertEqual(try open(refining).releaseIdentifier, identifier + "@2026-01-01T00:00:00Z")
        let undated = edited(book().archiveFiles) {
            $0.replacingOccurrences(of: "<meta property=\"dcterms:modified\">2026-01-01T00:00:00Z</meta>", with: "")
        }
        XCTAssertNil(try open(undated).releaseIdentifier)
        XCTAssertEqual(try open(undated).persistentID, identifier)
        let epub2 = try EPUBPublication.open(data: Fixture.epub(epub2: true))
        XCTAssertEqual(epub2.uniqueIdentifier, "test-book")
        XCTAssertEqual(epub2.persistentID, "test-book")
        XCTAssertNil(epub2.releaseIdentifier)
    }

    /// A package that names no unique identifier, or one with no value, is known by the SHA-256 of
    /// its content: each resource by its path and bytes, and the spine's order. A metadata edit and
    /// another zip leave it; a change to a chapter or to the reading order does not.
    func testABookWithoutAUniqueIdentifierIsKnownByItsContent() throws {
        let packages: [(String, (String) -> String)] = [
            ("no attribute", { $0.replacingOccurrences(of: " unique-identifier=\"uid\"", with: "") }),
            ("an attribute that names nothing", { $0.replacingOccurrences(of: "unique-identifier=\"uid\"", with: "unique-identifier=\"gone\"") }),
            ("an empty identifier", { $0.replacingOccurrences(of: ">\(self.identifier)<", with: ">\u{A0}<") }),
        ]
        for (name, unnamed) in packages {
            let files = edited(book().archiveFiles, unnamed)
            let book = try open(files)
            XCTAssertNil(book.uniqueIdentifier, name)
            XCTAssertNil(book.releaseIdentifier, name)
            XCTAssertEqual(book.persistentID.count, 64, name)
            XCTAssertTrue(book.persistentID.allSatisfy(\.isHexDigit), name)
            XCTAssertNotEqual(book.persistentID, book.id, name)
            XCTAssertEqual(book.publicationIDs, [book.persistentID, book.id], name)
            XCTAssertEqual(try EPUBPublication.open(data: Fixture.rezipped(files, compression: .none)).persistentID, book.persistentID, name)
            XCTAssertEqual(try open(metadataEdited(files)).persistentID, book.persistentID, name)
            var chapter = files
            chapter["EPUB/two.xhtml"] = Data(String(decoding: files["EPUB/two.xhtml"]!, as: UTF8.self)
                .replacingOccurrences(of: "second chapter", with: "second chapter, corrected").utf8)
            XCTAssertNotEqual(try open(chapter).persistentID, book.persistentID, name)
            let reordered = edited(files) {
                $0.replacingOccurrences(of: "<itemref idref=\"one\"/>\n    <itemref idref=\"two\"/>",
                                        with: "<itemref idref=\"two\"/>\n    <itemref idref=\"one\"/>")
            }
            XCTAssertEqual(try open(reordered).spine.map(\.resource.id), ["two", "one"], name)
            XCTAssertNotEqual(try open(reordered).persistentID, book.persistentID, name)
        }
    }

    /// A location saved under the content's SHA-256, before the package gave a unique identifier,
    /// still names the book once it has one, and one saved under the file's SHA-256 before
    /// `persistentID` names that file: `publicationIDs` holds them in the order to look them up.
    func testPublicationIDsHoldEveryIdentityInTheOrderToLookAPositionUp() throws {
        let files = book().archiveFiles
        let book = try open(files)
        let unnamed = try open(edited(files) { $0.replacingOccurrences(of: " unique-identifier=\"uid\"", with: "") })
        XCTAssertEqual(book.publicationIDs, [identifier, unnamed.persistentID, book.id])
    }

    /// EPUB Reading Systems 3.3 §5.2: a reading system should not depend on a unique identifier
    /// naming one publication alone. Two books that give one share `persistentID`, where a saved
    /// position is restored as far as its CFI resolves, and `id`, the release identifier and the
    /// metadata tell them apart.
    func testTwoBooksThatShareAUniqueIdentifierShareThePersistentIDAlone() throws {
        var other = book()
        other.metadata = "<dc:title>Another Book Altogether</dc:title><dc:language>en</dc:language>"
        let first = try open(book().archiveFiles)
        let second = try open(edited(other.archiveFiles) { $0.replacingOccurrences(of: "2026-01-01", with: "2026-03-03") })
        XCTAssertEqual(first.persistentID, second.persistentID)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.releaseIdentifier, second.releaseIdentifier)
        XCTAssertNotEqual(first.metadata.title, second.metadata.title)
    }
}
