import EPUBCore
@testable import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// Entries the directory lists that ZIPFoundation does not read: the book opens without them, as
/// without files the archive lacks, and says which they were (#261).
final class LostEntryTests: XCTestCase {
    private func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// The test book stored, its two chapters before its navigation document and NCX, which
    /// come last: what is lost from the end leaves the spine whole.
    private func book(last: [String] = ["OPS/nav.xhtml", "OPS/toc.ncx"]) throws -> (data: Data, files: [String: Data]) {
        let files = try Fixture.files()
        let first = files.keys.filter { !last.contains($0) }.sorted { a, b in a == "mimetype" || (b != "mimetype" && a < b) }
        return (Fixture.storedArchive((first + last).map { Fixture.StoredEntry($0, files[$0]!) }), files)
    }

    private func replacing(_ range: Range<Int>, of data: Data, with bytes: Data) -> Data {
        var copy = data
        copy.replaceSubrange(range, with: bytes)
        return copy
    }

    /// The archive with each of the three faults that lose `lost`, its last entries, and the
    /// names of those that can still be read.
    private func faults(_ data: Data, losing lost: [String]) throws -> [(fault: String, data: Data, named: [String])] {
        let end = data.count - 22, total = Int(data[end + 10]) | Int(data[end + 11]) << 8
        let first = try XCTUnwrap(Fixture.directoryOffset(of: lost[0], in: data))
        // A local header offset into the first chapter's text, where no header begins: every
        // record from there on is whole.
        let text = try XCTUnwrap(Fixture.dataOffset(of: "OPS/one.xhtml", in: data))
        let offset = replacing((first + 42)..<(first + 46), of: data, with: le(UInt32(text)))
        let count = replacing((end + 8)..<(end + 12), of: data, with: le(UInt16(total - lost.count)) + le(UInt16(total - lost.count)))
        // A comment that runs past the end of the archive: the record's name is whole, and where
        // the next record would begin is not known.
        let cut = replacing((first + 32)..<(first + 34), of: data, with: le(UInt16(lost.count == 1 ? 1000 : 0xFFFF)))
        return [("a local header offset that names no header", offset, lost), ("an end record that counts \(lost.count) fewer", count, lost),
                ("a record cut short", cut, [lost[0]])]
    }

    private func assertOpens(_ data: Data, as files: [String: Data], losing lost: [String], named: [String]? = nil,
                             _ message: String, line: UInt = #line) {
        do {
            let book = try EPUBPublication.open(data: data)
            let expected = lost.isEmpty ? nil : EPUBLostEntries(count: lost.count, paths: named ?? lost)
            XCTAssertEqual(book.lostEntries, expected, message, line: line)
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], message, line: line)
            // A manifest item whose entry is lost is left out, as one the archive lacks is.
            let manifest = ["OPS/one.xhtml", "OPS/two.xhtml", "OPS/nav.xhtml", "OPS/toc.ncx"]
            XCTAssertEqual(Set(book.resources.map(\.path)), Set(manifest).subtracting(lost), message, line: line)
            for (path, bytes) in files where !lost.contains(path) {
                XCTAssertEqual(try book.data(at: path), bytes, "\(message): \(path)", line: line)
            }
            for path in lost {
                XCTAssertThrowsError(try book.data(at: path), "\(message): \(path)", line: line) {
                    XCTAssertEqual($0 as? EPUBPublicationError, .missingResource(path), "\(message): \(path)", line: line)
                }
            }
        } catch {
            XCTFail("\(message): \(error)", line: line)
        }
    }

    func testEachFaultOpensTheBookWithoutTheEntriesItLosesAndSaysWhichTheyWere() throws {
        for lost in [["OPS/toc.ncx"], ["OPS/nav.xhtml", "OPS/toc.ncx"]] {
            let (data, files) = try book()
            XCTAssertNil(try EPUBPublication.open(data: data).lostEntries, "the archive itself")
            for (fault, damaged, named) in try faults(data, losing: lost) {
                assertOpens(damaged, as: files, losing: lost, named: named, "\(fault), losing \(lost.count)")
            }
        }
    }

    func testASpineItemAmongTheLostEntriesStillRefusesTheBook() throws {
        let (data, _) = try book(last: ["OPS/two.xhtml"])
        XCTAssertEqual(try EPUBPublication.open(data: data).spine.count, 2)
        for (fault, damaged, _) in try faults(data, losing: ["OPS/two.xhtml"]) {
            XCTAssertThrowsError(try EPUBPublication.open(data: damaged), fault) {
                XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("OPS/two.xhtml"), fault)
            }
        }
    }

    func testWhatIsNotARecordNamesNoEntry() throws {
        // ZIPFoundation stops where a record's signature is not one, and where an entry is
        // encrypted. A record that is no record names nothing; an encrypted one is whole.
        let (data, files) = try book()
        let nav = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/nav.xhtml", in: data))
        let unsigned = replacing(nav..<(nav + 1), of: data, with: Data([0x51]))
        assertOpens(unsigned, as: files, losing: ["OPS/nav.xhtml", "OPS/toc.ncx"], named: [], "a record with another signature")
        let encrypted = replacing((nav + 8)..<(nav + 10), of: data, with: le(UInt16(0x0801)))
        assertOpens(encrypted, as: files, losing: ["OPS/nav.xhtml", "OPS/toc.ncx"], "an encrypted entry")
    }

    func testAnIntactArchiveReportsNothing() throws {
        var files = try Fixture.files()
        files["OPS/empty.css"] = Data()
        var entries = Fixture.storedEntries(files)
        entries.insert(Fixture.StoredEntry("OPS/", versionMadeBy: 3 << 8 | 20, externalAttributes: 0o040755 << 16), at: 2)
        for (name, data) in [("written by ZIPFoundation", try Fixture.epub()), ("zip", Fixture.MacToolArchive.zip),
                             ("ditto", Fixture.MacToolArchive.ditto), ("stored, with a directory", Fixture.storedArchive(entries)),
                             ("data descriptors", Fixture.storedArchive(Fixture.storedEntries(files, flags: 0x0808))),
                             ("all ZIP64", Fixture.storedArchive(entries, zip64: .everything)),
                             ("a comment", Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8)))] {
            XCTAssertNil(try EPUBPublication.open(data: data).lostEntries, name)
        }
        // An end record that counts more records than there are loses none: the end record is
        // where the next one would be.
        let (data, plain) = try book()
        let end = data.count - 22, total = UInt16(plain.count)
        assertOpens(replacing((end + 8)..<(end + 12), of: data, with: le(total + 2) + le(total + 2)), as: plain, losing: [], "counting two more")
    }

    func testLostNamesAreTheEntryPathsTheyWouldHaveBeenRead() throws {
        // ditto's UTF-8 names without bit 11, one decomposed as on disk, and a code page 437
        // name: each lost entry's path is the one its entry is read under when it is not lost.
        var entries = Fixture.storedEntries(try Fixture.files())
        var legacy = Fixture.StoredEntry("OPS/", Data("body {}".utf8), flags: 0)
        legacy.name = Data("OPS/r".utf8) + Data([0x82]) + Data("sum".utf8) + Data([0x82]) + Data(".css".utf8) // résumé in code page 437
        entries.append(legacy)
        for (name, data) in [("ditto", Fixture.MacToolArchive.ditto), ("code page 437", Fixture.storedArchive(entries))] {
            let archive = try Archive(data: data, accessMode: .read)
            let paths = archive.map(EntryName.path(of:))
            for lost in 1...3 {
                let end = data.count - 22
                let counted = replacing((end + 8)..<(end + 12), of: data, with: le(UInt16(paths.count - lost)) + le(UInt16(paths.count - lost)))
                let found = try ArchiveBounds.check(counted, archive: Archive(data: counted, accessMode: .read), names: .max).lostEntries
                XCTAssertEqual(found, EPUBLostEntries(count: lost, paths: Array(paths.suffix(lost))), "\(name), \(lost) lost")
                // No more names than asked for are kept; the count is whole.
                let named = try ArchiveBounds.check(counted, archive: Archive(data: counted, accessMode: .read), names: 1).lostEntries
                XCTAssertEqual(named, EPUBLostEntries(count: lost, paths: Array(paths.suffix(lost).prefix(1))), "\(name), \(lost) lost, one name")
            }
        }
    }

    func testLostEntriesAreFoundWithinTheBytesWhateverTheyHold() throws {
        // A book is untrusted input: wherever iteration ends and whatever the count, no read
        // leaves the bytes.
        let (data, _) = try book()
        let start = try XCTUnwrap(Fixture.directoryOffset(of: "mimetype", in: data))
        for length in [0, 3, 4, 45, 46, 60, data.count - start] {
            let bytes = data.prefix(start + length)
            for position in [0, start, start + 1, bytes.count - 46, bytes.count - 4, bytes.count, bytes.count + 1] where position >= 0 {
                for (read, counted) in [(UInt64(0), UInt64(0)), (0, 1), (1, 3), (0, .max), (3, 3)] {
                    _ = bytes.withUnsafeBytes { LostEntries.find(in: $0, at: UInt64(position), read: read, counted: counted, names: .max) }
                }
            }
        }
        let found = data.withUnsafeBytes { LostEntries.find(in: $0, at: UInt64(start), read: 0, counted: .max, names: 2) }
        XCTAssertEqual(found, EPUBLostEntries(count: .max, paths: ["mimetype", "META-INF/container.xml"]), "a count no archive could hold")
    }
}
