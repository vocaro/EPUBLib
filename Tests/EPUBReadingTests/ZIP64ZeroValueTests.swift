import CryptoKit
import EPUBCore
@testable import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// ZIP64 extra fields holding a zero: the first entry's header offset and an empty entry's sizes.
/// ZIPFoundation reads a zero there as no value at all, so opening restates it first.
final class ZIP64ZeroValueTests: XCTestCase {
    private func filesWithAnEmptyOne() throws -> [String: Data] {
        var files = try Fixture.files()
        files["OPS/empty.css"] = Data()
        return files
    }

    private func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

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

    func testAZIP64FieldAmongOtherExtraFieldsOfADescribedEntryIsRead() throws {
        // What a writer that cannot seek back and always uses ZIP64 produces: each entry's checksum
        // and sizes follow its data in a descriptor of 8-byte sizes, and its directory record
        // defers both sizes and the offset to a ZIP64 field, here between a timestamp and Unix IDs.
        let files = try filesWithAnEmptyOne()
        let timestamp = le(UInt16(0x5455)) + le(UInt16(5)) + Data([1, 0x10, 0x20, 0x30, 0x40])
        let owner = le(UInt16(0x7875)) + le(UInt16(11)) + Data([1, 4, 0xF5, 1, 0, 0, 4, 0x14, 0, 0, 0])
        var data = Data(), directory = Data()
        for entry in Fixture.storedEntries(files) {
            let checksum = le(entry.data.crc32(checksum: 0)), size = le(UInt64(entry.data.count)), offset = le(UInt64(data.count))
            // Version needed, flags (a UTF-8 name, a data descriptor), stored, time and date.
            let common = le(UInt16(45)) + le(UInt16(0x0808)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0x21))
            let extra = timestamp + le(UInt16(1)) + le(UInt16(24)) + size + size + offset + owner
            data += le(UInt32(0x0403_4b50)) + common + le(UInt32(0)) + le(UInt32.max) + le(UInt32.max)
            data += le(UInt16(entry.name.count)) + le(UInt16(20)) + entry.name + le(UInt16(1)) + le(UInt16(16)) + Data(count: 16)
            data += entry.data + le(UInt32(0x0807_4b50)) + checksum + size + size
            directory += le(UInt32(0x0201_4b50)) + le(UInt16(45)) + common + checksum + le(UInt32.max) + le(UInt32.max)
            directory += le(UInt16(entry.name.count)) + le(UInt16(extra.count)) + Data(count: 10) + le(UInt32.max) + entry.name + extra
        }
        let start = data.count
        data += directory + le(UInt32(0x0605_4b50)) + le(UInt32(0)) + le(UInt16(files.count)) + le(UInt16(files.count))
        data += le(UInt32(directory.count)) + le(UInt32(start)) + le(UInt16(0))
        XCTAssertNotEqual(ZIP64ZeroValues.inlined(in: data), data)
        try assertOpens(data, as: files)
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

    // MARK: Archives made to be restated into something else

    // Taking a zero out of a ZIP64 field moves the values after it eight bytes back. In each
    // archive below that would join or part the bytes of a signature, so that ZIPFoundation would
    // find other end records in the copy than the archive has, and through them another directory.

    func testARecordHoldingTheEndRecordIsNotRestated() throws {
        // The last record's ZIP64 field ends in the end record's first four bytes, as its disk
        // number, after a zero; the rest is the record's comment. The zero is a stored entry's
        // compressed size, which nothing reads, so the book opens as it is. Restated, the end
        // record would sit eight bytes back and count no entries, or (two bytes on) come apart.
        let files = try filesWithAnEmptyOne()
        let entries = Fixture.storedEntries(files)
        let plain = Fixture.storedArchive(entries.filter { !$0.data.isEmpty } + entries.filter { $0.data.isEmpty })
        let record = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/empty.css", in: plain)), end = plain.count - 22
        for lead in [0, 2] {
            var data = plain.prefix(end)
            data.replaceSubrange((record + 20)..<(record + 24), with: le(UInt32.max)) // The compressed size, deferred.
            // An extra field of 16 bytes, a comment of the end record's other bytes and a deferred disk number.
            data.replaceSubrange((record + 30)..<(record + 36), with: le(UInt16(16)) + le(UInt16(18 + lead)) + le(UInt16.max))
            data += le(UInt16(1)) + le(UInt16(12)) + Data(count: 8 + lead) + plain.suffix(22)
            XCTAssertEqual(ZIP64ZeroValues.inlined(in: data), data, "\(lead) bytes on")
            try assertOpens(data, as: files, "\(lead) bytes on")
        }
    }

    func testADirectoryAfterTheEndRecordIsNotRestated() throws {
        // The end record names a directory after itself, in the archive's comment: the book's
        // records, then one whose ZIP64 field holds a zero between a value ending 50 4B and one
        // starting 05 06, the file's last 22 bytes from there on. Restated, those would be an
        // end record after the archive's own, and the ZIP64 end record and locator in the
        // record's name would send ZIPFoundation to a directory of one hidden file.
        let files = try Fixture.files()
        let whole = Fixture.storedArchive([Fixture.StoredEntry("hidden.txt", "read only from a copy")] + Fixture.storedEntries(files))
        let hidden = Int(whole.suffix(6).prefix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) })
        let book = try XCTUnwrap(Fixture.directoryOffset(of: "mimetype", in: whole))
        var name = Data("x".utf8) + le(UInt32(0x0606_4b50)) + le(UInt64(44)) + le(UInt16(45)) + le(UInt16(45)) + Data(count: 8)
        name += le(UInt64(1)) + le(UInt64(1)) + le(UInt64(book - hidden)) + le(UInt64(hidden)) + le(UInt32(0x0706_4b50)) + Data(count: 6)
        let extra = le(UInt16(1)) + le(UInt16(24)) + Data([1, 0, 0, 0, 0, 0, 0x50, 0x4B]) + Data(count: 8) + Data([0x05, 0x06]) + Data(count: 10)
        var comment = Data(whole[book..<(whole.count - 22)])
        comment += le(UInt32(0x0201_4b50)) + le(UInt16(20)) + le(UInt16(45)) + le(UInt16(0x0800)) + Data(count: 10)
        comment += le(UInt32.max) + le(UInt32.max) + le(UInt16(name.count)) + le(UInt16(extra.count)) + Data(count: 10)
        comment += le(UInt32.max) + name + extra
        var data = whole.prefix(book)
        data += le(UInt32(0x0605_4b50)) + le(UInt32(0)) + le(UInt16(files.count + 1)) + le(UInt16(files.count + 1))
        data += le(UInt32(comment.count)) + le(UInt32(book + 22)) + le(UInt16(comment.count)) + comment
        XCTAssertEqual(ZIP64ZeroValues.inlined(in: data), data)
        try assertOpens(data, as: files)
    }

    func testACopyThatWouldGainAZIP64EndRecordIsNotReturned() throws {
        // Every record ends before the end record. The last one's name is the start of a ZIP64 end
        // record, 76 bytes before the end record, and its ZIP64 field holds a zero between a value
        // ending 50 4B and one starting 06 07: restated, a locator's signature 20 bytes before the
        // end record. ZIPFoundation would then take the directory from the ZIP64 end record.
        let files = try Fixture.files()
        let plain = Fixture.storedArchive(Fixture.storedEntries(files))
        let name = le(UInt32(0x0606_4b50)) + le(UInt64(44)) + le(UInt16(45)) + le(UInt16(45)) + Data(count: 8) + le(UInt64(1)) + le(UInt64(1)) + Data(count: 6)
        let extra = le(UInt16(1)) + le(UInt16(24)) + Data(count: 6) + Data([0x50, 0x4B]) + Data(count: 8) + Data([0x06, 0x07]) + Data(count: 6)
        var data = plain.prefix(plain.count - 22)
        let record = data.count
        data += le(UInt32(0x0201_4b50)) + le(UInt16(20)) + le(UInt16(45)) + le(UInt16(0x0800)) + Data(count: 10)
        data += le(UInt32.max) + le(UInt32.max) + le(UInt16(name.count)) + le(UInt16(extra.count)) + le(UInt16(2)) + Data(count: 8)
        data += le(UInt32.max) + name + extra + Data(count: 2)
        data += le(UInt32(0x0605_4b50)) + le(UInt32(0)) + le(UInt16(files.count + 1)) + le(UInt16(files.count + 1)) + plain.suffix(10)
        XCTAssertEqual(ZIP64ZeroValues.inlined(in: data), data)
        try assertOpens(data, as: files)
        // With no ZIP64 end record in its name the same record is restated, as any other is.
        var plainlyNamed = data
        plainlyNamed[record + 46] = 0x51
        XCTAssertNotEqual(ZIP64ZeroValues.inlined(in: plainlyNamed), plainlyNamed)
    }
}
