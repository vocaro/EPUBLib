import EPUBCore
@testable import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// Where an archive's end record is looked for: no further back than the 65,557 bytes a record
/// with the longest comment takes. ZIPFoundation looks through every byte, a seek and a read for
/// each, so bytes that are no archive took it about a fifth of a second per mebibyte to refuse.
final class ArchiveEndRecordTests: XCTestCase {
    private let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    /// What ZIPFoundation says of bytes it finds no end record in.
    private let noEndRecord = EPUBPublicationError.invalidArchive("missingEndOfCentralDirectoryRecord")
    /// What opening says of an archive of no entries.
    private let noEntries = EPUBPublicationError.invalidArchive("Missing EPUB mimetype")

    private func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private func assertOpening(_ data: Data, throws expected: EPUBPublicationError, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EPUBPublication.open(data: data), message, file: file, line: line) {
            XCTAssertEqual($0 as? EPUBPublicationError, expected, "\(message): \($0)", file: file, line: line)
        }
    }

    private func assertOpens(_ data: Data, as files: [String: Data], _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], message, file: file, line: line)
        XCTAssertEqual(book.archiveData, data, message, file: file, line: line)
        for (path, bytes) in files { XCTAssertEqual(try book.data(at: path), bytes, "\(message): \(path)", file: file, line: line) }
    }

    /// Zero bytes the system has given no memory yet. It gives a page of them memory when one of
    /// the page's bytes is first read or written, which tells what a reader of them looked at.
    private final class UnreadZeros {
        let count: Int
        private let base: UnsafeMutableRawPointer
        private let pageSize = Int(getpagesize())

        init(count: Int) throws {
            guard let base = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), base != MAP_FAILED else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOMEM)
            }
            self.base = base
            self.count = count
        }

        deinit { munmap(base, count) }

        /// The bytes themselves and no copy, for as long as this object lasts.
        var data: Data { Data(bytesNoCopy: base, count: count, deallocator: .none) }

        func write(_ bytes: [UInt8], at offset: Int) {
            precondition(offset >= 0 && offset + bytes.count <= count)
            bytes.withUnsafeBytes { base.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }

        /// The pages that hold `bytes`.
        func pages(holding bytes: Range<Int>) -> Set<Int> {
            Set((bytes.lowerBound / pageSize)...((bytes.upperBound - 1) / pageSize))
        }

        /// The pages read or written so far.
        func pagesUsed() throws -> Set<Int> {
            var states = [CChar](repeating: 0, count: (count + pageSize - 1) / pageSize)
            guard mincore(base, count, &states) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
            // Whatever is said of a page (in memory, referenced, modified, paged out) says it was
            // used, but for its being anonymous memory, which all of these are.
            return Set(states.indices.filter { Int32(UInt8(bitPattern: states[$0])) & ~MINCORE_ANONYMOUS != 0 })
        }

        /// The pages used that hold none of `bytes`.
        func pagesUsed(outside bytes: Range<Int>...) throws -> [Int] {
            try pagesUsed().subtracting(bytes.reduce(into: Set<Int>()) { $0.formUnion(pages(holding: $1)) }).sorted()
        }
    }

    // MARK: Bytes that are no archive

    func testBytesWithNoEndRecordAreRefusedByTheirLastBytesAlone() throws {
        // Four mebibytes took about a second to refuse, and the 256 MiB a book may be a minute.
        let zeros = try UnreadZeros(count: 4 << 20)
        let tail = (zeros.count - 65_557)..<zeros.count
        assertOpening(zeros.data, throws: noEndRecord)
        XCTAssertEqual(try zeros.pagesUsed(outside: tail), [], "pages read before the last 65,557 bytes")
        XCTAssertFalse(try zeros.pagesUsed().isEmpty, "and those were read")
        // Had the first byte been read, this would have shown it.
        XCTAssertEqual(zeros.data.first, 0)
        XCTAssertEqual(try zeros.pagesUsed(outside: tail), [0])
    }

    func testOnlyTheLastBytesOfASliceOrOfAnOddLengthAreRead() throws {
        // A slice keeps its parent's indices: its last bytes are not the parent's.
        for (name, range) in [("an odd length", 0..<((1 << 19) - 12_345)), ("a slice", 123_457..<400_001), ("less than a record's reach", 70_000..<110_000)] {
            let zeros = try UnreadZeros(count: 1 << 19)
            let slice = zeros.data[range]
            XCTAssertEqual(slice.startIndex, range.lowerBound, name)
            assertOpening(slice, throws: noEndRecord, name)
            XCTAssertEqual(try zeros.pagesUsed(outside: max(range.lowerBound, range.upperBound - 65_557)..<range.upperBound), [], name)
            XCTAssertFalse(try zeros.pagesUsed().isEmpty, name)
        }
    }

    func testRestatingZIP64ValuesLooksNoFurtherBackForAnEndRecord() throws {
        // The directory is found for ZIPFoundation before it is asked, and in the same bytes.
        let zeros = try UnreadZeros(count: 1 << 20)
        XCTAssertEqual(ZIP64ZeroValues.inlined(in: zeros.data).count, zeros.count)
        XCTAssertEqual(try zeros.pagesUsed(outside: (zeros.count - 65_557)..<zeros.count), [])
        XCTAssertFalse(try zeros.pagesUsed().isEmpty)
    }

    func testBytesTooFewToHoldAnEndRecordAreRefused() {
        for count in [0, 1, 4, 21, 22, 23] { assertOpening(Data(count: count), throws: noEndRecord, "\(count) zero bytes") }
        for count in 4..<22 { assertOpening(Data(signature) + Data(count: count - 4), throws: noEndRecord, "\(count) bytes of a record") }
        // The whole of a record that counts no entries is an archive, though not a book.
        assertOpening(Data(signature) + Data(count: 18), throws: noEntries)
    }

    func testAFileThatIsNoArchiveIsRefusedAsItsBytesAre() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".epub")
        try Data(String(repeating: "Not a book. ", count: 20_000).utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try EPUBPublication.open(at: url)) { XCTAssertEqual($0 as? EPUBPublicationError, noEndRecord) }
    }

    // MARK: A signature in the last bytes of what is no archive

    func testASignatureInTheLastBytesSendsNothingBackThroughTheRest() throws {
        // Each is a megabyte of zeros with a few bytes written near its end. What ZIPFoundation
        // makes of them is as it was: an archive of no entries, or no end record after all.
        let count = 1 << 20, end = count - 22
        let cases: [(name: String, writes: [(bytes: [UInt8], offset: Int)], expected: EPUBPublicationError)] = [
            ("a record of no entries at the end", [(signature, end)], noEntries),
            ("the same as far back as one can begin", [(signature, count - 65_557), ([0xFF, 0xFF], count - 65_557 + 20)], noEntries),
            ("a comment longer than the bytes left", [(signature, end), ([1, 0], end + 20)], noEndRecord),
            ("a signature too near the end for a record", [(signature, end + 1)], noEndRecord),
            ("a signature every four bytes", (0..<16_384).map { (signature, count - 4 * ($0 + 1)) }, noEndRecord),
            ("a ZIP64 locator with no ZIP64 record before it", [(signature, end), ([0x50, 0x4B, 0x06, 0x07], end - 20)], noEntries),
        ]
        for (name, writes, expected) in cases {
            let zeros = try UnreadZeros(count: count)
            for write in writes { zeros.write(write.bytes, at: write.offset) }
            assertOpening(zeros.data, throws: expected, name)
            // A ZIP64 end record and its locator are looked for in the 76 bytes before the record.
            XCTAssertEqual(try zeros.pagesUsed(outside: (count - 65_557 - 76)..<count), [], name)
        }
    }

    func testTheDirectoryARecordNamesIsReadAndNothingBetween() throws {
        // Records counting entries from the first byte on, where there is none: one entry, and
        // 2^63 of them in a ZIP64 end record with its locator.
        let count = 1 << 20, end = count - 22
        let one: [(bytes: [UInt8], offset: Int)] = [(signature, end), ([1, 0, 1, 0], end + 8)]
        let many: [(bytes: [UInt8], offset: Int)] = [
            (signature, end), ([0x50, 0x4B, 0x06, 0x07], end - 20), ([0x50, 0x4B, 0x06, 0x06], end - 76),
            ([45, 0], end - 62), ([0, 0, 0, 0, 0, 0, 0, 0x80], end - 44),
        ]
        for (name, writes) in [("one entry", one), ("2^63 entries", many)] {
            let zeros = try UnreadZeros(count: count)
            for write in writes { zeros.write(write.bytes, at: write.offset) }
            assertOpening(zeros.data, throws: noEntries, name)
            XCTAssertEqual(try zeros.pagesUsed(outside: 0..<46, (end - 76)..<count), [], name)
            XCTAssertTrue(try zeros.pagesUsed().contains(0), name)
        }
    }

    // MARK: Where a record may begin

    func testTheLastSignatureWithRoomForARecordIsFoundWithinALongestRecordOfTheEnd() {
        func offset(_ data: Data) -> Int? { data.withUnsafeBytes(ArchiveEndRecord.offset(in:)) }
        func bytes(_ count: Int, signaturesAt offsets: Int...) -> Data {
            var data = Data(count: count)
            for offset in offsets { data.replaceSubrange(offset..<(offset + 4), with: signature) }
            return data
        }
        XCTAssertEqual(ArchiveEndRecord.maximumLength, 65_557)
        XCTAssertNil(offset(Data()))
        XCTAssertNil(offset(Data(signature)))
        XCTAssertNil(offset(bytes(21, signaturesAt: 0)))
        XCTAssertEqual(offset(bytes(22, signaturesAt: 0)), 0)
        XCTAssertNil(offset(bytes(22, signaturesAt: 1)), "21 bytes are no record")
        XCTAssertEqual(offset(bytes(100, signaturesAt: 10, 50, 79)), 50, "the last with 22 bytes to the end")
        XCTAssertEqual(offset(bytes(100, signaturesAt: 10, 50, 78)), 78)
        XCTAssertEqual(offset(bytes(100_000, signaturesAt: 100_000 - 65_557)), 100_000 - 65_557, "a record with the longest comment")
        XCTAssertNil(offset(bytes(100_000, signaturesAt: 100_000 - 65_558)), "one byte further back than any record begins")
        XCTAssertEqual(offset(bytes(65_557, signaturesAt: 0)), 0)
        XCTAssertNil(offset(bytes(65_558, signaturesAt: 0)))
        // Offsets are from the first byte of a slice, whatever its indices.
        let slice = bytes(100_000, signaturesAt: 2_000, 90_000).dropFirst(1_000).dropLast(5_000)
        XCTAssertEqual(slice.startIndex, 1_000)
        XCTAssertEqual(offset(slice), 89_000)
        XCTAssertNil(offset(bytes(100_000, signaturesAt: 2_000, 90_000).dropFirst(1_000).dropLast(9_990)), "cut 10 bytes into its record")
    }

    func testAnArchiveIsReadWithACommentOfAnyLengthAndBytesAfterItThatFarBack() throws {
        let files = try Fixture.files()
        let entries = Fixture.storedEntries(files)
        // A comment of the greatest length: the record begins 65,557 bytes from the end.
        let comment = Data(repeating: 0x20, count: 65_535)
        for (name, layout) in [("plain", nil), ("ZIP64", Fixture.ZIP64Layout.everything)] {
            let longest = Fixture.storedArchive(entries, comment: comment, zip64: layout)
            XCTAssertEqual(Array(longest[(longest.count - 65_557)...].prefix(4)), signature, name)
            try assertOpens(longest, as: files, "\(name), the longest comment")
            // One byte more and no record could begin where this one does.
            assertOpening(longest + Data([0x20]), throws: noEndRecord, "\(name), a byte after the longest comment")
        }
        // Bytes after the record, which no comment length owns, are passed over as far back.
        let plain = Fixture.storedArchive(entries), short = Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8))
        for extra in [1, 512, 65_535] { try assertOpens(plain + Data(count: extra), as: files, "\(extra) bytes after the record") }
        assertOpening(plain + Data(count: 65_536), throws: noEndRecord, "65,536 bytes after the record")
        try assertOpens(short + Data(count: 65_535 - 17), as: files, "a comment and bytes after it")
        assertOpening(short + Data(count: 65_536 - 17), throws: noEndRecord, "a comment and a byte more after it")
    }

    func testASignatureInsideTheCommentIsReadAsItWas() throws {
        let files = try Fixture.files()
        let entries = Fixture.storedEntries(files)
        let plain = Fixture.storedArchive(entries)
        for length in [200, 65_535] {
            // In the comment's last 21 bytes it has no room to be a record's.
            var comment = Data(repeating: 0x20, count: length)
            comment.replaceSubrange((length - 21)..<(length - 17), with: signature)
            try assertOpens(Fixture.storedArchive(entries, comment: comment), as: files, "a signature 21 bytes from the end of \(length)")
            // A byte earlier it is the last with room, and ZIPFoundation reads the comment's text
            // after it as a record: one with a comment of 8,224 bytes, which are not there.
            comment = Data(repeating: 0x20, count: length)
            comment.replaceSubrange((length - 22)..<(length - 18), with: signature)
            assertOpening(Fixture.storedArchive(entries, comment: comment), throws: noEndRecord, "a signature 22 bytes from the end of \(length)")
            // A comment that ends in a second record naming the same directory: the one read.
            comment = Data(repeating: 0x20, count: length - 22) + plain.suffix(22)
            try assertOpens(Fixture.storedArchive(entries, comment: comment), as: files, "a record at the end of \(length)")
        }
    }

    func testAnArchiveBehindOtherBytesIsReadWhenItsOffsetsCountThem() throws {
        // A self-extracting archive is a program with the archive after it. More of it than a
        // record's reach changes nothing: the end record is still at the end.
        let files = try Fixture.files()
        let plain = Fixture.storedArchive(Fixture.storedEntries(files))
        let stub = Data(repeating: 0x90, count: 100_000)
        var data = stub + plain
        // Left as they were, the offsets name places in the program.
        assertOpening(data, throws: noEntries, "offsets from the archive's own first byte")
        func add(_ amount: Int, at offset: Int) {
            let value = data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            data.replaceSubrange(offset..<(offset + 4), with: le(value + UInt32(amount)))
        }
        for name in files.keys { add(stub.count, at: try XCTUnwrap(Fixture.directoryOffset(of: name, in: data)) + 42) }
        add(stub.count, at: data.count - 22 + 16)
        try assertOpens(data, as: files, "offsets from the file's first byte")
    }
}
