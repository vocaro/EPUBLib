import EPUBCore
@testable import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// A data descriptor's sizes are four bytes each, or eight in a ZIP64 archive (APPNOTE.TXT
/// 4.3.9). ZIPFoundation 0.9.20 takes them as eight for every entry marked version 4.5 or with a
/// ZIP64 field in its directory record, and as four for any other, whatever the descriptor holds.
/// Opening reads each descriptor by the form its own bytes show (#261).
final class DataDescriptorFormTests: XCTestCase {
    private func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// The test book's files and an empty one, whose descriptor's sizes are zero in either form.
    private func files() throws -> [String: Data] {
        var files = try Fixture.files()
        files["OPS/empty.css"] = Data()
        return files
    }

    private func deflated(_ data: Data) throws -> Data {
        // An empty file as ditto deflates it: one empty final block.
        data.isEmpty ? Data([0x03, 0x00]) : try (data as NSData).compressed(using: .zlib) as Data
    }

    /// `files` laid out as ditto lays out a book: flags 0x0008 alone, a checksum and sizes of zero
    /// in each local header, an Info-ZIP Unix field (0x5855) on every entry and its checksum and
    /// sizes after its data. `wide` gives the descriptor eight-byte sizes, `signed` its optional
    /// signature, `gap` that many bytes between it and what follows, and `zip64` each local
    /// header and directory record a ZIP64 field, as a writer that always uses ZIP64 does.
    private func describedArchive(_ files: [String: Data], method: UInt16, version: UInt16 = 45, wide: Bool = false,
                                  signed: Bool = true, zip64: Bool = false, gap: Int = 0) throws -> Data {
        var data = Data(), directory = Data()
        for entry in Fixture.storedEntries(files, flags: 0x0008) {
            let body = method == 8 ? try deflated(entry.data) : entry.data
            let crc = entry.data.crc32(checksum: 0), offset = UInt32(data.count)
            func size(_ value: Int) -> Data { wide ? le(UInt64(value)) : le(UInt32(value)) }
            // Access and modification times, and in the local header the owner's user and group IDs.
            let times = le(UInt32(0x6553_F100)) + le(UInt32(0x6553_F100))
            let localExtra = le(UInt16(0x5855)) + le(UInt16(12)) + times + le(UInt16(501)) + le(UInt16(20))
                + (zip64 ? le(UInt16(1)) + le(UInt16(16)) + Data(count: 16) : Data())
            let directoryExtra = le(UInt16(0x5855)) + le(UInt16(8)) + times
                + (zip64 ? le(UInt16(1)) + le(UInt16(16)) + le(UInt64(entry.data.count)) + le(UInt64(body.count)) : Data())
            // Version needed, flags, method, time and date.
            let common = le(version) + le(UInt16(0x0008)) + le(method) + le(UInt16(0x71AA)) + le(UInt16(0x576E))
            let deferred = le(zip64 ? UInt32.max : 0)
            data += le(UInt32(0x0403_4b50)) + common + le(UInt32(0)) + deferred + deferred
            data += le(UInt16(entry.name.count)) + le(UInt16(localExtra.count)) + entry.name + localExtra + body
            data += (signed ? le(UInt32(0x0807_4b50)) : Data()) + le(crc) + size(body.count) + size(entry.data.count)
            data += Data(repeating: 0x20, count: gap)
            directory += le(UInt32(0x0201_4b50)) + le(UInt16(0x0315)) + common + le(crc)
            directory += le(zip64 ? UInt32.max : UInt32(body.count)) + le(zip64 ? UInt32.max : UInt32(entry.data.count))
            directory += le(UInt16(entry.name.count)) + le(UInt16(directoryExtra.count)) + Data(count: 6)
            directory += le(UInt32(0o100644) << 16) + le(offset) + entry.name + directoryExtra
        }
        let start = data.count
        data += directory + le(UInt32(0x0605_4b50)) + le(UInt32(0)) + le(UInt16(files.count)) + le(UInt16(files.count))
        return data + le(UInt32(directory.count)) + le(UInt32(start)) + le(UInt16(0))
    }

    /// `archive` with the version needed to extract set to `version` in the local header and the
    /// directory record of every entry that has a data descriptor, and nothing else changed.
    private func marking(_ archive: Data, version: UInt16) throws -> Data {
        var data = archive
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        let end = data.count - 22
        XCTAssertEqual(u32(end), 0x0605_4b50, "an end record with no comment")
        var record = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            XCTAssertEqual(u32(record), 0x0201_4b50)
            if u16(record + 8) & 0x0008 != 0 {
                let local = u32(record + 42)
                data.replaceSubrange((record + 6)..<(record + 8), with: le(version))
                data.replaceSubrange((local + 4)..<(local + 6), with: le(version))
            }
            record += 46 + u16(record + 28) + u16(record + 30) + u16(record + 32)
        }
        return data
    }

    private func assertOpens(_ data: Data, as files: [String: Data], limits: EPUBImportLimits = .init(), _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        do {
            let book = try EPUBPublication.open(data: data, limits: limits)
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], message, file: file, line: line)
            for (path, bytes) in files { XCTAssertEqual(try book.data(at: path), bytes, "\(message): \(path)", file: file, line: line) }
        } catch {
            XCTFail("\(message): \(error)", file: file, line: line)
        }
    }

    // MARK: ditto's descriptors on entries marked version 4.5

    func testDittosBookMarkedVersion45Opens() throws {
        // ditto's own bytes: every file deflated and followed by a 16-byte descriptor. Only the
        // version each entry needs is changed, from 2.0 to 4.5.
        let original = Fixture.MacToolArchive.ditto
        let marked = try marking(original, version: 45)
        XCTAssertNotEqual(marked, original)
        let expected = try EPUBPublication.open(data: original)
        do {
            let book = try EPUBPublication.open(data: marked)
            XCTAssertEqual(book.spine.map(\.resource.path), expected.spine.map(\.resource.path))
            for path in expected.resources.map(\.path) + ["OPS/book.opf", "META-INF/container.xml", "mimetype"] {
                XCTAssertEqual(try book.data(at: path), try expected.data(at: path), path)
            }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testEntriesMarkedVersion45WithFourByteSizesOpen() throws {
        let files = try files()
        for method in [UInt16(0), 8] {
            for signed in [true, false] {
                let name = "\(method == 0 ? "stored" : "deflated"), \(signed ? "16" : "12")-byte descriptors"
                assertOpens(try describedArchive(files, method: method, signed: signed), as: files, name)
                // A ZIP64 field in the record makes ZIPFoundation take eight-byte sizes too.
                assertOpens(try describedArchive(files, method: method, signed: signed, zip64: true), as: files, "\(name), ZIP64 fields")
            }
        }
    }

    func testAStoredEntryMarkedVersion45IsHeldToTheLimitsByItsOwnSize() throws {
        // The size the limits are checked by before an entry is read is its descriptor's.
        let files = try files()
        let data = try describedArchive(files, method: 0)
        let (largest, bytes) = try XCTUnwrap(files.max { $0.value.count < $1.value.count })
        var limits = EPUBImportLimits()
        limits.resourceBytes = bytes.count
        assertOpens(data, as: files, limits: limits, "at the limit")
        limits.resourceBytes -= 1
        XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded(largest))
        }
    }

    // MARK: Eight-byte sizes, and descriptors that disagree with their records

    func testEightByteDescriptorsOpenWhateverVersionTheirEntriesAreMarkedWith() throws {
        // A genuine ZIP64 descriptor, with a ZIP64 field or the version alone to say so, and one
        // on an entry marked version 2.0, which ZIPFoundation reads as four-byte sizes.
        let files = try files()
        for method in [UInt16(0), 8] {
            for signed in [true, false] {
                let name = "\(method == 0 ? "stored" : "deflated"), \(signed ? "24" : "20")-byte descriptors"
                assertOpens(try describedArchive(files, method: method, wide: true, signed: signed, zip64: true), as: files, "\(name), ZIP64 fields")
                assertOpens(try describedArchive(files, method: method, wide: true, signed: signed), as: files, "\(name), version 4.5")
                assertOpens(try describedArchive(files, method: method, version: 20, wide: true, signed: signed), as: files, "\(name), version 2.0")
            }
        }
    }

    func testADescriptorsOwnSizeIsCheckedWhateverVersionItsEntryIsMarkedWith() throws {
        // A descriptor whose sizes are not its record's is told by where it ends: where the next
        // header begins. Its uncompressed size, a byte more than the largest entry's, is what the
        // limits are checked by before the entry is read, which is then read by its record's.
        let files = try files()
        let (largest, bytes) = try XCTUnwrap(files.max { $0.value.count < $1.value.count })
        var limits = EPUBImportLimits()
        limits.resourceBytes = bytes.count
        for wide in [false, true] {
            for version in [UInt16(20), 45] {
                var data = try describedArchive(files, method: 0, version: version, wide: wide)
                let size = try XCTUnwrap(Fixture.dataOffset(of: largest, in: data)) + bytes.count + (wide ? 16 : 12)
                data.replaceSubrange(size..<(size + (wide ? 8 : 4)), with: wide ? le(UInt64(bytes.count + 1)) : le(UInt32(bytes.count + 1)))
                let name = "\(wide ? "eight" : "four")-byte sizes, version \(version)"
                XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits), name) {
                    XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded(largest), name)
                }
                assertOpens(data, as: files, "\(name), under the default limits")
            }
        }
    }

    func testADescriptorThatNothingPlacesIsReadPastByItsRecordsSizes() throws {
        // Sizes that are not the record's in either form, and bytes after the descriptor that
        // begin no header: the record's sizes, which the entry's data is read by, are taken.
        let files = try files()
        for version in [UInt16(20), 45] {
            var data = try describedArchive(files, method: 0, version: version, gap: 4)
            let (largest, bytes) = try XCTUnwrap(files.max { $0.value.count < $1.value.count })
            let size = try XCTUnwrap(Fixture.dataOffset(of: largest, in: data)) + bytes.count + 12
            data.replaceSubrange(size..<(size + 4), with: le(UInt32.max))
            assertOpens(data, as: files, "version \(version)")
        }
    }

    func testADescriptorIsReadWithinTheBytesWhereverItIsPlaced() throws {
        // A book is untrusted input: wherever its records place a descriptor, and however near
        // the end, nothing outside the bytes is read. Sizes of 1 and 2 are no form's here.
        let whole = try describedArchive(try files(), method: 0)
        func size(_ data: Data, at offset: Int) -> UInt64 {
            data.withUnsafeBytes { DataDescriptor.uncompressedSize(in: $0, at: offset, compressed: 1, uncompressed: 2) }
        }
        for offset in -1...(whole.count + 1) { _ = size(whole, at: offset) }
        let descriptor = try XCTUnwrap(Fixture.dataOffset(of: "mimetype", in: whole)) + "application/epub+zip".utf8.count
        for length in descriptor...(descriptor + 28) {
            for offset in (descriptor - 1)...(length + 1) { _ = size(whole.prefix(length), at: offset) }
        }
        // The mimetype's 16-byte descriptor, cut short before its sizes end, and whole.
        XCTAssertEqual(size(whole.prefix(descriptor + 15), at: descriptor), 2, "cut short: the record's")
        XCTAssertEqual(size(whole, at: descriptor), 20, "followed by the next local header: its own")
        XCTAssertEqual(size(whole.prefix(descriptor + 16), at: descriptor), 2, "followed by nothing: the record's")
    }
}
