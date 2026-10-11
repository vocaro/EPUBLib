import CryptoKit
import EPUBCore
@testable import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// ZIP64 extra fields holding a zero: the first entry's header offset and an empty entry's sizes.
/// ZIPFoundation reads a zero there as no value at all, so opening restates it first.
final class ZIP64ZeroValueTests: XCTestCase {
    private func filesWithAnEmptyOne() throws -> [String: Data] {
        var files = try Fixture.files()
        files["OPS/empty.css"] = Data()
        return files
    }

    private func assertOpens(_ data: Data, as files: [String: Data], _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], message, file: file, line: line)
        for (path, bytes) in files { XCTAssertEqual(try book.data(at: path), bytes, "\(message): \(path)", file: file, line: line) }
    }

    // MARK: Opening

    func testAnEmptyEntryOfAnAllZIP64ArchiveIsReadWhereverItSits() throws {
        // After other entries its sizes are zero and its offset is not; first, all three are zero
        // and nothing is left in its ZIP64 field.
        let files = try filesWithAnEmptyOne()
        let sorted = Fixture.storedEntries(files)
        let empty = try XCTUnwrap(sorted.first { $0.data.isEmpty })
        try assertOpens(Fixture.storedArchive(sorted, zip64: .everything), as: files, "among the others")
        try assertOpens(Fixture.storedArchive([empty] + sorted.filter { !$0.data.isEmpty }, zip64: .everything), as: files, "first")
    }

    func testADeflatedEmptyEntryWithZIP64SizesIsRead() throws {
        // What a writer told always to use ZIP64 makes of an empty file it deflates: two compressed
        // bytes that expand to none, so its ZIP64 field gives up one size and keeps the other.
        let name = "OPS/empty.css"
        var entries = Fixture.storedEntries(try Fixture.files())
        entries.append(Fixture.StoredEntry(name, Data([0x03, 0x00]), method: 8))
        var data = Fixture.storedArchive(entries, zip64: .sizes)
        // storedArchive describes the two bytes as the entry's own. State what they inflate to: in
        // the directory record and the local header, no checksum and an uncompressed size of zero.
        let record = try XCTUnwrap(Fixture.directoryOffset(of: name, in: data))
        let content = try XCTUnwrap(Fixture.dataOffset(of: name, in: data))
        for checksum in [record + 16, content - 20 - name.utf8.count - 16] {
            data.replaceSubrange(checksum..<(checksum + 4), with: [0, 0, 0, 0])
        }
        for size in [record + 46 + name.utf8.count + 4, content - 16] {
            data.replaceSubrange(size..<(size + 8), with: [UInt8](repeating: 0, count: 8))
        }
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: name), Data())
    }

    func testTheBookKeepsTheBytesItWasOpenedFrom() throws {
        // What is restated for ZIPFoundation is a copy: the identity and the bytes handed to other
        // engines are the file's own.
        let data = Fixture.storedArchive(Fixture.storedEntries(try filesWithAnEmptyOne()), zip64: .everything)
        XCTAssertNotEqual(ZIP64ZeroValues.inlined(in: data), data)
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.archiveData, data)
        XCTAssertEqual(book.id, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testAnAllZIP64ArchiveIsStillBounded() throws {
        let files = try filesWithAnEmptyOne()
        let data = Fixture.storedArchive(Fixture.storedEntries(files), zip64: .everything)
        var limits = EPUBImportLimits()
        limits.resourceBytes = files.values.map(\.count).max()! - 1
        XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits)) {
            guard case .limitExceeded = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
        }
        limits = EPUBImportLimits()
        limits.entryCount = files.count - 1
        XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("entry count"))
        }
    }

    func testAnAllZIP64ArchiveThatIsASliceOfLargerDataIsRead() throws {
        // A slice keeps its parent's indices, which are not offsets into the archive.
        let files = try filesWithAnEmptyOne()
        let archive = Fixture.storedArchive(Fixture.storedEntries(files), zip64: .everything)
        let slice = (Data(repeating: 0x20, count: 13) + archive + Data(repeating: 0x20, count: 7)).dropFirst(13).dropLast(7)
        XCTAssertEqual(slice.startIndex, 13)
        try assertOpens(slice, as: files)
        XCTAssertEqual(ZIP64ZeroValues.inlined(in: slice), ZIP64ZeroValues.inlined(in: archive))
    }

    // MARK: Restating

    func testOnlyDirectoryRecordsHoldingAZeroAreRestated() throws {
        let entries = Fixture.storedEntries(try Fixture.files())
        for (name, data) in [("no ZIP64 fields", Fixture.storedArchive(entries)),
                             ("data descriptors", Fixture.storedArchive(Fixture.storedEntries(try Fixture.files(), flags: 0x0808))),
                             ("ZIP64 sizes, none zero", Fixture.storedArchive(entries, zip64: .sizes)),
                             ("written by ZIPFoundation", try Fixture.epub())] {
            XCTAssertEqual(ZIP64ZeroValues.inlined(in: data), data, name)
        }
        // With ZIP64 offsets, only the first entry's is zero: its record alone changes, by the four
        // bytes of its offset and the length and last value of its ZIP64 field.
        let data = Fixture.storedArchive(entries, zip64: .everything)
        let restated = ZIP64ZeroValues.inlined(in: data)
        XCTAssertEqual(restated.count, data.count)
        let first = try XCTUnwrap(Fixture.directoryOffset(of: "mimetype", in: data))
        let second = try XCTUnwrap(Fixture.directoryOffset(of: "META-INF/container.xml", in: data))
        XCTAssertEqual(restated[..<first], data[..<first], "the entries themselves")
        XCTAssertEqual(restated[second...], data[second...], "every other record and the end records")
        let extra = first + 46 + "mimetype".utf8.count
        XCTAssertEqual(Array(restated[(first + 42)..<(first + 46)]), [0, 0, 0, 0], "the offset")
        XCTAssertEqual(Array(restated[extra..<(extra + 4)]), [1, 0, 16, 0], "a ZIP64 field of the two sizes")
        XCTAssertEqual(restated[(extra + 4)..<(extra + 20)], data[(extra + 4)..<(extra + 20)], "which are as they were")
        XCTAssertEqual(ZIP64ZeroValues.inlined(in: restated), restated, "and nothing is left to restate")
    }

    func testAZIP64FieldThatDoesNotMatchItsRecordIsLeftAlone() throws {
        // APPNOTE.TXT 4.5.3: a value "MUST only appear" when its field in the record is all ones.
        // ZIPFoundation ignores a field of any other length, so there is nothing of its to restate.
        var data = Fixture.storedArchive(Fixture.storedEntries(try filesWithAnEmptyOne()), zip64: .sizes)
        let record = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/empty.css", in: data))
        data.replaceSubrange((record + 20)..<(record + 24), with: [0, 0, 0, 0]) // The compressed size, stated in place.
        XCTAssertEqual(ZIP64ZeroValues.inlined(in: data), data)
    }

    func testDamagedBytesAreRestatedWithoutTrappingOrChangingLength() throws {
        // A book is untrusted input: whatever the bytes claim, no read or write leaves them.
        let entries = [Fixture.StoredEntry("mimetype", "application/epub+zip"), Fixture.StoredEntry("empty"), Fixture.StoredEntry("a", "b")]
        for layout in [Fixture.ZIP64Layout.sizes, .everything] {
            let whole = Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8), zip64: layout)
            for length in 0...whole.count {
                XCTAssertEqual(ZIP64ZeroValues.inlined(in: whole.prefix(length)).count, length, "cut at \(length)")
                XCTAssertEqual(ZIP64ZeroValues.inlined(in: whole.suffix(length)).count, length, "the last \(length)")
            }
            for index in whole.indices {
                for value in [UInt8.min, 1, 0x7F, .max] {
                    var damaged = whole
                    damaged[index] = value
                    XCTAssertEqual(ZIP64ZeroValues.inlined(in: damaged).count, whole.count, "\(value) at \(index)")
                }
            }
        }
        // The ZIP64 end record's count of entries and directory offset, 44 and 28 bytes before the
        // end record, holding the largest numbers they can.
        let data = Fixture.storedArchive(entries, zip64: .everything)
        func damaging(_ data: Data, at offset: Int, with bytes: [UInt8]) -> Data {
            var copy = data
            copy.replaceSubrange(offset..<(offset + 8), with: bytes)
            return copy
        }
        let end = data.count - 22, most = [UInt8](repeating: 0xFF, count: 8)
        // UInt64.max, Int.max and the first offset too near the end to hold a record.
        for offset in [most, [UInt8](repeating: 0xFF, count: 7) + [0x7F], withUnsafeBytes(of: UInt64(data.count - 45).littleEndian) { Array($0) }] {
            let damaged = damaging(data, at: end - 28, with: offset)
            XCTAssertEqual(ZIP64ZeroValues.inlined(in: damaged), damaged, "no directory at \(offset)")
        }
        XCTAssertEqual(ZIP64ZeroValues.inlined(in: damaging(data, at: end - 44, with: most)),
                       damaging(ZIP64ZeroValues.inlined(in: data), at: end - 44, with: most), "the records there are, and no further")
    }
}
