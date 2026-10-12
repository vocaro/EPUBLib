import CryptoKit
import EPUBCore
@testable import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// Where an archive's end record is looked for: in the 65,557 bytes a record with the longest
/// comment takes and, when none begins there, through the rest of bytes that begin as an archive
/// does, which other bytes may follow. ZIPFoundation looks through every byte, a seek and a read
/// for each, so bytes that are no archive took it about a fifth of a second per mebibyte to refuse.
final class ArchiveEndRecordTests: XCTestCase {
    private let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    /// A local file header's signature, which an archive begins with when its first entry is at
    /// its first byte.
    private let localHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
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
        XCTAssertEqual(book.id, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), message, file: file, line: line)
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

    func testBytesWithNoEndRecordAreRefusedByTheirFirstFourBytesAndTheirLast() throws {
        // Four mebibytes took about a second to refuse, and the 256 MiB a book may be a minute.
        // The first four bytes say whether the rest is searched: these are no local file
        // header's signature, so it is not.
        let zeros = try UnreadZeros(count: 4 << 20)
        let head = 0..<4, tail = (zeros.count - 65_557)..<zeros.count
        assertOpening(zeros.data, throws: noEndRecord)
        XCTAssertEqual(try zeros.pagesUsed(outside: head, tail), [], "pages read between the first four bytes and the last 65,557")
        XCTAssertFalse(try zeros.pagesUsed().isEmpty, "and those were read")
        // Had a byte between them been read, this would have shown it.
        let middle = zeros.count / 2
        XCTAssertEqual(zeros.data[middle], 0)
        XCTAssertEqual(try zeros.pagesUsed(outside: head, tail), zeros.pages(holding: middle..<(middle + 1)).sorted())
    }

    func testOnlyTheEndsOfASliceOrOfAnOddLengthAreRead() throws {
        // A slice keeps its parent's indices: its first and last bytes are not the parent's.
        for (name, range) in [("an odd length", 0..<((1 << 19) - 12_345)), ("a slice", 123_457..<400_001), ("less than a record's reach", 70_000..<110_000)] {
            let zeros = try UnreadZeros(count: 1 << 19)
            let slice = zeros.data[range]
            XCTAssertEqual(slice.startIndex, range.lowerBound, name)
            assertOpening(slice, throws: noEndRecord, name)
            let head = range.lowerBound..<(range.lowerBound + 4), tail = max(range.lowerBound, range.upperBound - 65_557)..<range.upperBound
            XCTAssertEqual(try zeros.pagesUsed(outside: head, tail), [], name)
            XCTAssertFalse(try zeros.pagesUsed().isEmpty, name)
        }
    }

    func testBytesThatBeginAsAnArchiveAndHoldNoEndRecordAreSearchedThroughAndRefused() throws {
        // A local file header's signature and nothing else of an archive. Every byte is looked
        // at, where it lies, and there is no archive to give ZIPFoundation, whose own search of
        // these four mebibytes took about a second.
        let zeros = try UnreadZeros(count: 4 << 20)
        zeros.write(localHeader, at: 0)
        assertOpening(zeros.data, throws: noEndRecord)
        XCTAssertEqual(try zeros.pagesUsed(), zeros.pages(holding: 0..<zeros.count), "pages read for the search")
        XCTAssertNil(zeros.data.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)), "and nothing is given to ZIPFoundation")

        // Bytes that are nearly a signature at every offset hold none either.
        let nearly: [(name: String, pattern: [UInt8])] = [
            ("a signature's first byte", [0x50]), ("its first two", [0x50, 0x4B]), ("its first three", [0x50, 0x4B, 0x05]),
            ("all but its last", [0x50, 0x4B, 0x05, 0x07]), ("a local file header's signature", localHeader),
        ]
        for (name, pattern) in nearly {
            var data = repeating(pattern, count: 1 << 20)
            data.replaceSubrange(0..<4, with: localHeader)
            XCTAssertNil(data.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)), name)
            assertOpening(data, throws: noEndRecord, "a megabyte of \(name)")
        }
    }

    /// `count` bytes of `pattern` over and over.
    private func repeating(_ pattern: [UInt8], count: Int) -> Data {
        var data = Data(pattern)
        while data.count < count { data.append(data) }
        return Data(data.prefix(count))
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
        // makes of them is as it was: an archive of no entries, or no end record after all. The
        // first four bytes are looked at where no signature near the end has room for a record.
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
            XCTAssertEqual(try zeros.pagesUsed(outside: 0..<4, (count - 65_557 - 76)..<count), [], name)
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

    func testAnArchiveIsReadWithACommentOfAnyLengthAndBytesAfterIt() throws {
        let files = try Fixture.files()
        let entries = Fixture.storedEntries(files)
        // A comment of the greatest length: the record begins 65,557 bytes from the end.
        let comment = Data(repeating: 0x20, count: 65_535)
        for (name, layout) in [("plain", nil), ("ZIP64", Fixture.ZIP64Layout.everything)] {
            let longest = Fixture.storedArchive(entries, comment: comment, zip64: layout)
            XCTAssertEqual(Array(longest[(longest.count - 65_557)...].prefix(4)), signature, name)
            try assertOpens(longest, as: files, "\(name), the longest comment")
            // One byte more and no record could begin where this one does: the byte is none of
            // the archive's, and the record is found by looking further back.
            try assertOpens(longest + Data([0x20]), as: files, "\(name), a byte after the longest comment")
        }
        // Bytes after the record, which no comment length owns, are passed over, as many as a
        // comment could be and more.
        let plain = Fixture.storedArchive(entries), short = Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8))
        for extra in [1, 512, 65_535, 65_536, 65_537, 200_000] { try assertOpens(plain + Data(count: extra), as: files, "\(extra) bytes after the record") }
        try assertOpens(short + Data(count: 65_535 - 17), as: files, "a comment and bytes after it")
        try assertOpens(short + Data(count: 65_536 - 17), as: files, "a comment and a byte more after it")
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
        // With other bytes after it as well, it is read while its record begins in the last
        // 65,557. No record is looked for further back: these bytes do not begin as an archive does.
        try assertOpens(data + Data(count: 65_535), as: files, "and 65,535 bytes after it")
        assertOpening(data + Data(count: 65_536), throws: noEndRecord, "and 65,536 bytes after it")
    }

    // MARK: An archive and other bytes after it

    // A page a download was wrapped in, another file run on after the book: more after the
    // archive than a comment could be, so that no record begins where one is first looked for.
    func testABookFollowedByAMegabyteOfOtherBytesOpensAsTheBookAloneDoes() throws {
        let files = try Fixture.files()
        let entries = Fixture.storedEntries(files)
        let books: [(name: String, bytes: Data)] = [
            ("stored", Fixture.storedArchive(entries)), ("deflated", try Fixture.epub()),
            ("with a comment", Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8))),
            ("with the longest comment", Fixture.storedArchive(entries, comment: Data(repeating: 0x20, count: 65_535))),
            ("all ZIP64", Fixture.storedArchive(entries + [Fixture.StoredEntry("OPS/empty.css", Data())], zip64: .everything)),
        ]
        let after: [(name: String, bytes: Data)] = [
            ("zeros", Data(count: 1 << 20)),
            ("a page of HTML", repeating(Array("<html><body><p>This page wrapped the download. PK</p></body></html>\n".utf8), count: 1 << 20)),
            ("a signature's first byte", Data(repeating: 0x50, count: 1 << 20)),
            ("all of a signature but its last byte", repeating([0x50, 0x4B, 0x05, 0x07], count: 1 << 20)),
        ]
        for (name, bytes) in books {
            let alone = try EPUBPublication.open(data: bytes)
            for (kind, more) in after {
                let data = bytes + more, message = "\(name), then \(kind)"
                let book = try EPUBPublication.open(data: data)
                XCTAssertEqual(book.metadata, alone.metadata, message)
                XCTAssertEqual(book.resources, alone.resources, message)
                XCTAssertEqual(book.spine, alone.spine, message)
                XCTAssertEqual(book.tableOfContents, alone.tableOfContents, message)
                for resource in alone.resources { XCTAssertEqual(try book.data(for: resource), try alone.data(for: resource), "\(message): \(resource.path)") }
                // Its identity and the bytes another engine is handed are the whole file's.
                XCTAssertEqual(book.archiveData, data, message)
                XCTAssertEqual(book.id, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), message)
                XCTAssertNotEqual(book.id, alone.id, message)
                // ZIPFoundation is given the archive and none of what follows it.
                XCTAssertEqual(data.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)), bytes.count, message)
            }
        }
    }

    func testAFileOfABookAndOtherBytesAfterItOpens() throws {
        let bytes = try Fixture.epub() + Data(repeating: 0x0A, count: 1 << 20)
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".epub")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try EPUBPublication.open(at: url)
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(book.archiveData, bytes)
    }

    func testASliceOfLargerDataThatIsABookAndOtherBytesAfterItOpens() throws {
        // A slice keeps its parent's indices, which are not offsets into it. The archive's length
        // is a count from the slice's first byte, and ZIPFoundation is given that many bytes: the
        // bytes before the index of that number are the archive without its last 5,000, and so
        // without its record.
        let files = try Fixture.files()
        let plain = Fixture.storedArchive(Fixture.storedEntries(files))
        let slice = (Data(count: 5_000) + plain + Data(count: 70_000)).dropFirst(5_000)
        XCTAssertEqual(slice.startIndex, 5_000)
        XCTAssertEqual(slice.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)), plain.count, "the record is found by looking further back")
        try assertOpens(slice, as: files)
    }

    /// `count` zero bytes that begin as an archive does, with a record at each of `offsets`
    /// whose comment length is `comment`.
    private func led(_ count: Int, recordsAt offsets: [Int], comment: Int) -> Data {
        var data = Data(count: count)
        data.replaceSubrange(0..<4, with: localHeader)
        for offset in offsets {
            data.replaceSubrange(offset..<(offset + 4), with: signature)
            data.replaceSubrange((offset + 20)..<(offset + 22), with: le(UInt16(comment)))
        }
        return data
    }

    func testTheArchiveEndsWithTheCommentOfARecordFurtherBack() throws {
        func length(_ data: Data) -> Int? { data.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)) }
        let count = 200_000, tail = count - 65_557
        var cases: [(name: String, bytes: Data, length: Int?)] = [
            ("a record at the fourth byte", led(count, recordsAt: [4], comment: 0), 26),
            ("a record with a comment", led(count, recordsAt: [1_000], comment: 300), 1_322),
            ("a record with the longest comment", led(count, recordsAt: [1_000], comment: 65_535), 66_557),
            ("the last of three records", led(count, recordsAt: [1_000, 50_000, 90_000], comment: 7), 90_029),
            ("a record one byte further back than any begins", led(count, recordsAt: [tail - 1], comment: 65_535), count - 1),
            ("the same with no comment", led(count, recordsAt: [tail - 1], comment: 0), tail + 21),
            ("a record as far back as one begins", led(count, recordsAt: [tail], comment: 65_535), count),
            ("a record at the end and one further back", led(count, recordsAt: [1_000, count - 22], comment: 0), count),
            ("no record", led(count, recordsAt: [], comment: 0), nil),
            ("bytes no longer than a record reaches", led(65_557, recordsAt: [], comment: 0), nil),
        ]
        // A signature too near the end to be a record's is none, and the one further back is taken.
        var late = led(count, recordsAt: [1_000], comment: 0)
        late.replaceSubrange((count - 21)..<(count - 17), with: signature)
        cases.append(("a signature in the last 21 bytes", late, 1_022))
        // A record among the last bytes that they cut short is the one ZIPFoundation took, and
        // it looked no further back: nor is the whole one before it taken here.
        var short = led(count, recordsAt: [1_000, count - 30], comment: 0)
        short.replaceSubrange((count - 10)..<(count - 8), with: le(UInt16(9)))
        cases.append(("a record cut short after a whole one", short, nil))
        // Only bytes that begin as an archive does are searched.
        for (name, head) in [("an end record's", signature), ("a directory record's", [0x50, 0x4B, 0x01, 0x02]), ("a spanned archive's", [0x50, 0x4B, 0x07, 0x08]), ("zeros", [0, 0, 0, 0])] {
            var other = led(count, recordsAt: [1_000], comment: 0)
            other.replaceSubrange(0..<4, with: head)
            cases.append(("bytes that begin with \(name)", other, nil))
        }
        // Offsets and lengths are those of a slice, whatever its indices.
        let slice = (Data(count: 5_000) + led(count, recordsAt: [1_000], comment: 300)).dropFirst(5_000)
        XCTAssertEqual(slice.startIndex, 5_000)
        cases.append(("a slice", slice, 1_322))

        for (name, bytes, expected) in cases {
            XCTAssertEqual(length(bytes), expected, name)
            guard let expected else { continue }
            // ZIPFoundation makes an archive of what it is given and finds the record there.
            let given = bytes.prefix(expected)
            XCTAssertNoThrow(try Archive(data: given, accessMode: .read), name)
            XCTAssertEqual(given.withUnsafeBytes(ArchiveEndRecord.readableOffset(in:)), bytes.withUnsafeBytes { ArchiveEndRecord.lastSignature(in: $0, before: $0.count - 21) }, name)
        }
    }

    func testTheLastSignatureBeforeAnOffsetIsFoundWhateverTheBytesAre() {
        func found(_ data: Data, before end: Int) -> Int? { data.withUnsafeBytes { ArchiveEndRecord.lastSignature(in: $0, before: end) } }
        /// The same by the plainest means: the four bytes at each offset, from the last.
        func expected(_ data: Data, before end: Int) -> Int? {
            let bytes = [UInt8](data)
            return (0..<end).last { Array(bytes[$0..<($0 + 4)]) == signature }
        }
        // Nothing but signatures, at 0, 4, 8 and so on: the last that begins before each offset.
        let signatures = repeating(signature, count: 64)
        XCTAssertNil(found(signatures, before: 0))
        XCTAssertEqual(found(signatures, before: 1), 0)
        XCTAssertEqual(found(signatures, before: 8), 4)
        XCTAssertEqual(found(signatures, before: 9), 8)
        XCTAssertEqual(found(signatures, before: 56), 52)
        XCTAssertEqual(expected(signatures, before: 9), 8, "the plainest means find one too")
        // Bytes that hold no signature, that are nearly one at every offset, and that are
        // nothing but signatures: each alone, and with one signature at every offset about `end`.
        let patterns: [(name: String, pattern: [UInt8])] = [
            ("zeros", [0]), ("its first byte", [0x50]), ("its last byte", [0x06]), ("its first two", [0x50, 0x4B]), ("its first three", [0x50, 0x4B, 0x05]),
            ("all but its last", [0x50, 0x4B, 0x05, 0x07]), ("signatures", signature), ("signatures a byte apart", [0x50] + signature),
        ]
        for (name, pattern) in patterns {
            let filled = repeating(pattern, count: 120)
            // `end` has eight bytes or more after it.
            for end in [0, 1, 3, 7, 8, 9, 15, 16, 17, 23, 24, 25, 60, 111, 112] {
                XCTAssertEqual(found(filled, before: end), expected(filled, before: end), "\(name), before \(end)")
                for offset in max(0, end - 20)..<min(116, end + 6) {
                    var data = filled
                    data.replaceSubrange(offset..<(offset + 4), with: signature)
                    XCTAssertEqual(found(data, before: end), expected(data, before: end), "\(name) with a signature at \(offset), before \(end)")
                }
            }
        }
        // A signature that begins before `end` is found though it runs past it, and one that
        // begins at `end` is not.
        var data = Data(count: 64)
        data.replaceSubrange(30..<34, with: signature)
        XCTAssertEqual(found(data, before: 31), 30)
        XCTAssertNil(found(data, before: 30))
        XCTAssertEqual(found(data, before: 56), 30)
    }

    // What ZIPFoundation read of such a file, before opening looked only where a record ends an
    // archive, is what it reads of the bytes it is given now, where the archive's records keep
    // within it: the directory named by the last signature anywhere that has room for a record
    // after it.
    func testTheRecordTakenIsTheLastOneAnywhereAsZIPFoundationTookIt() throws {
        let files = try Fixture.files()
        let entries = Fixture.storedEntries(files)
        let plain = Fixture.storedArchive(entries), deflated = try Fixture.epub()
        let commented = Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8))
        let wide = Fixture.storedArchive(entries + [Fixture.StoredEntry("OPS/empty.css", Data())], zip64: .everything)
        // Zeros that hold one signature: a record of no entries and no comment.
        var noise = Data(count: 70_000)
        noise.replaceSubrange(100..<104, with: signature)
        let cases: [(name: String, bytes: Data, entries: Int)] = [
            ("a book and zeros", plain + Data(count: 70_000), files.count),
            ("a book with a comment and other bytes", commented + Data(repeating: 0x50, count: 70_000), files.count),
            ("an all-ZIP64 book and zeros", wide + Data(count: 70_000), files.count + 1),
            // The record again after the book, naming the same directory: the one read.
            ("a book, its record again and zeros", plain + Data(count: 100_000) + plain.suffix(22) + Data(count: 100_000), files.count),
            // Another archive's record is the last: its offsets are from that archive's own
            // first byte, and what lies there in this file is the first book's bytes.
            ("a book, another archive and zeros", plain + deflated + Data(count: 70_000), 0),
            // A signature in what follows the book is the last: a record of nothing.
            ("a book and bytes that hold a signature", plain + noise, 0),
            // The book's own record after those: the last again.
            ("a book, bytes that hold a signature, and its record again", plain + noise + plain.suffix(22) + Data(count: 70_000), files.count),
        ]
        func listing(_ archive: Archive) -> [String] {
            archive.map { "\($0.path(using: .utf8)) \($0.checksum) \($0.compressedSize) \($0.uncompressedSize) \($0.type) \($0.isCompressed)" }
        }
        for (name, bytes, entries) in cases {
            let length = try XCTUnwrap(bytes.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)), name)
            XCTAssertLessThan(length, bytes.count - 65_535, name)
            // What ZIPFoundation is given: the archive, with any ZIP64 zeros restated. Its own
            // search of the whole file, a seek and a read for each byte, comes to the same record.
            let archive = ZIP64ZeroValues.inlined(in: bytes.prefix(length))
            let given = try Archive(data: archive, accessMode: .read), whole = try Archive(data: archive + bytes.dropFirst(length), accessMode: .read)
            XCTAssertEqual(listing(given).count, entries, name)
            XCTAssertEqual(listing(given), listing(whole), name)
            if entries > 0 { try assertOpens(bytes, as: files, name) } else { assertOpening(bytes, throws: noEntries, name) }
        }
        XCTAssertEqual(try EPUBPublication.open(data: wide + Data(count: 70_000)).data(at: "OPS/empty.css"), Data(), "an entry whose ZIP64 sizes are zero")
        // A record among the last bytes that they cut short is the one ZIPFoundation took, and
        // it looked no further back for the book's.
        var short = Data(repeating: 0x41, count: 70_000)
        short.replaceSubrange((short.count - 30)..<(short.count - 26), with: signature)
        assertOpening(plain + short, throws: noEndRecord, "a book and bytes that end in a record cut short")
    }

    // An archive that more bytes follow than a comment could hold ends with its record's
    // comment, and is read as it would be with nothing after it. Where its own records place
    // something after that, ZIPFoundation, given the whole file, found bytes there, and is no
    // longer given them: here a directory that follows its end record, and below a directory
    // record whose lengths run past the archive's end.
    func testBytesAfterTheArchiveAreNoPartOfIt() throws {
        let files = try Fixture.files()
        let plain = Fixture.storedArchive(Fixture.storedEntries(files))
        let end = plain.count - 22
        let start = Int(plain[(end + 16)..<(end + 20)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        // The entries, the end record, and only then the directory, with other bytes around it.
        var moved = plain[..<start] + plain[end...] + Data(count: 70_000) + plain[start..<end] + Data(count: 70_000)
        moved.replaceSubrange((start + 16)..<(start + 20), with: le(UInt32(start + 22 + 70_000)))
        XCTAssertEqual(try Archive(data: moved, accessMode: .read).reduce(0) { count, _ in count + 1 }, files.count, "ZIPFoundation reads it of the whole file")
        XCTAssertEqual(moved.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)), start + 22)
        assertOpening(moved, throws: .invalidArchive("Central directory past the end of the archive"))
        // Within a comment's length of the end, the whole file is the archive, as it was.
        var near = plain[..<start] + plain[end...] + plain[start..<end]
        near.replaceSubrange((start + 16)..<(start + 20), with: le(UInt32(start + 22)))
        try assertOpens(Data(near), as: files, "a directory after its record, in the last bytes")
    }

    func testARecordThatRunsPastTheArchiveIsCutShortWhateverFollowsTheArchive() throws {
        // The last directory record says a comment of a thousand bytes follows it, more than
        // the archive has left. ZIPFoundation stops at a record it cannot read the whole of, so
        // the archive alone is a book without that entry, which its spine names.
        let files = try Fixture.files()
        let plain = Fixture.storedArchive(Fixture.storedEntries(files))
        let last = "OPS/two.xhtml"
        let record = try XCTUnwrap(Fixture.directoryOffset(of: last, in: plain))
        var cut = plain
        cut.replaceSubrange((record + 32)..<(record + 34), with: le(UInt16(1_000)))
        XCTAssertLessThan(plain.count - record, 1_000)
        XCTAssertEqual(try Archive(data: cut, accessMode: .read).reduce(0) { count, _ in count + 1 }, files.count - 1, "the archive alone")
        assertOpening(cut, throws: .missingResource(last), "the archive alone")
        // With other bytes after the archive the record had its thousand, and ZIPFoundation,
        // given the whole file, read the entry. Given the archive, it reads what the archive
        // alone holds.
        let followed = cut + Data(count: 70_000)
        XCTAssertEqual(try Archive(data: followed, accessMode: .read).reduce(0) { count, _ in count + 1 }, files.count, "ZIPFoundation reads it of the whole file")
        XCTAssertEqual(followed.withUnsafeBytes(ArchiveEndRecord.archiveLength(in:)), plain.count)
        assertOpening(followed, throws: .missingResource(last), "the archive and other bytes after it")
    }

    // MARK: A record the bytes cut short

    /// `count` zero bytes with a record at `offset` whose comment length is `comment`.
    private func bytes(_ count: Int, recordAt offset: Int, comment: Int) -> Data {
        var data = Data(count: count)
        data.replaceSubrange(offset..<(offset + 4), with: signature)
        data.replaceSubrange((offset + 20)..<(offset + 22), with: le(UInt16(comment)))
        return data
    }

    func testARecordIsReadableWhenTheBytesHoldAllOfItsComment() {
        func offset(_ data: Data) -> Int? { data.withUnsafeBytes(ArchiveEndRecord.offset(in:)) }
        func readable(_ data: Data) -> Int? { data.withUnsafeBytes(ArchiveEndRecord.readableOffset(in:)) }
        XCTAssertNil(readable(Data()))
        XCTAssertNil(readable(Data(count: 100)), "no signature")
        XCTAssertEqual(readable(bytes(22, recordAt: 0, comment: 0)), 0)
        XCTAssertNil(readable(bytes(22, recordAt: 0, comment: 1)), "a comment of one byte, and none after the record")
        XCTAssertEqual(readable(bytes(23, recordAt: 0, comment: 1)), 0)
        XCTAssertEqual(readable(bytes(100, recordAt: 50, comment: 28)), 50, "a comment to the last byte")
        XCTAssertEqual(readable(bytes(100, recordAt: 50, comment: 27)), 50, "a byte after the comment is passed over")
        XCTAssertNil(readable(bytes(100, recordAt: 50, comment: 29)), "a byte short")
        XCTAssertNil(readable(bytes(100, recordAt: 50, comment: 65_535)))
        XCTAssertEqual(readable(bytes(65_557, recordAt: 0, comment: 65_535)), 0, "the longest comment")
        XCTAssertNil(readable(bytes(65_556, recordAt: 0, comment: 65_535)))
        // The last signature with room for a record is the one read, as ZIPFoundation reads it:
        // a whole record before it does not stand in for one cut short.
        var two = bytes(100, recordAt: 10, comment: 0)
        two.replaceSubrange(60..<64, with: signature)
        two.replaceSubrange(80..<82, with: le(UInt16(19)))
        XCTAssertEqual(offset(two), 60)
        XCTAssertNil(readable(two), "18 bytes after the record")
        two.replaceSubrange(80..<82, with: le(UInt16(18)))
        XCTAssertEqual(readable(two), 60)
        // Offsets and lengths are those of a slice, whatever its indices.
        let slice = bytes(100_000, recordAt: 90_000, comment: 4_978).dropFirst(1_000).dropLast(5_000)
        XCTAssertEqual(slice.startIndex, 1_000)
        XCTAssertEqual(readable(slice), 89_000)
        XCTAssertNil(readable(slice.dropLast()))
        XCTAssertEqual(offset(slice.dropLast()), 89_000)
    }

    func testACutShortRecordIsRefusedBeforeItsDirectoryIsReadOrCopied() throws {
        // A megabyte of zeros with a ZIP64 end record and locator naming a directory at its
        // first byte: one record, whose header offset of zero is in its ZIP64 field. Such a
        // zero is restated in a copy of the archive, and ZIPFoundation is given the copy.
        let count = 1 << 20, end = count - 22
        let archive: [(bytes: [UInt8], offset: Int)] = [
            ([0x50, 0x4B, 0x01, 0x02], 0), ([12, 0], 30), ([0xFF, 0xFF, 0xFF, 0xFF], 42), ([1, 0, 8, 0], 46),
            ([0x50, 0x4B, 0x06, 0x06], end - 76), ([45, 0], end - 62), ([1], end - 44), ([0x50, 0x4B, 0x06, 0x07], end - 20), (signature, end),
        ]
        let whole = try UnreadZeros(count: count)
        for write in archive { whole.write(write.bytes, at: write.offset) }
        let restated = ZIP64ZeroValues.inlined(in: whole.data)
        XCTAssertFalse(try whole.pagesUsed(outside: 0..<58, (end - 76)..<count).isEmpty, "a copy is made, which every page is read for")
        XCTAssertNotEqual(restated, whole.data, "and the zero is restated in it")
        // With its end record cut short there is no archive to make, and so no copy, which
        // ZIPFoundation would have kept as it keeps whatever it refuses.
        let short = try UnreadZeros(count: count)
        for write in archive + [([1, 0], end + 20)] { short.write(write.bytes, at: write.offset) }
        assertOpening(short.data, throws: noEndRecord)
        XCTAssertEqual(try short.pagesUsed(outside: 0..<58, (end - 76)..<count), [], "pages read for a directory or a copy")
    }

    // ZIPFoundation does not close the file it opens over bytes it then refuses, and that file
    // keeps them (`ArchiveInputReleaseTests`), so opening asks it for an archive only of bytes
    // it forecasts ZIPFoundation will make one of. The forecast is held here to what
    // ZIPFoundation says. None of these is longer than a record reaches; a record further back
    // is held to it in `testTheArchiveEndsWithTheCommentOfARecordFurtherBack`. Each refusal
    // leaves its few bytes allocated.
    func testZIPFoundationMakesAnArchiveOfBytesWithAReadableRecordAndOfNoOthers() throws {
        let entries = Fixture.storedEntries(try Fixture.files())
        let plain = Fixture.storedArchive(entries)
        let commented = Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8))
        let wide = Fixture.storedArchive(entries, zip64: .everything)
        let end = plain.count - 22
        func stating(_ bytes: Data, at offset: Int, in data: Data) -> Data {
            var data = data
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            return data
        }
        var comment = Data(repeating: 0x20, count: 200)
        comment.replaceSubrange(178..<182, with: signature)
        var cases: [(name: String, bytes: Data, made: Bool)] = [
            ("nothing", Data(), false), ("zeros", Data(count: 100), false),
            ("21 bytes of a record", Data(signature) + Data(count: 17), false),
            ("a record of no entries", Data(signature) + Data(count: 18), true),
            ("a book", plain, true), ("a book with a comment", commented, true), ("an all-ZIP64 book", wide, true),
            ("a book and bytes after it", plain + Data(count: 512), true),
            ("a book with a comment and bytes after it", commented + Data(count: 512), true),
            ("a book cut one byte short of its comment's end", Data(commented.dropLast()), false),
            ("a book cut off after its record's 22 bytes", Data(commented.dropLast(17)), false),
            ("a book cut off inside its record", Data(plain.dropLast(3)), false),
            ("a comment length one more than the bytes after the record", stating(le(UInt16(1)), at: end + 20, in: plain), false),
            ("an all-ZIP64 book with a comment length and no comment", stating(le(UInt16.max), at: wide.count - 2, in: wide), false),
            ("a signature in a comment, 22 bytes from its end", Fixture.storedArchive(entries, comment: comment), false),
            // What its initialiser does not read, or reads past, is no refusal of its own.
            ("a directory past the end", stating(le(UInt32(0xFFFF_FFF0)), at: end + 16, in: plain), true),
            ("more entries counted than there are", stating(le(UInt16.max), at: end + 10, in: plain), true),
            ("a ZIP64 locator with no ZIP64 record before it", stating(Data([0x50, 0x4B, 0x06, 0x07]), at: end - 20, in: plain), true),
            ("a ZIP64 record of a version before 4.5", stating(le(UInt16(44)), at: wide.count - 22 - 62, in: wide), true),
            ("a ZIP64 record without its signature", stating(Data(count: 4), at: wide.count - 22 - 76, in: wide), true),
        ]
        // Every comment length about the 20 bytes that follow a record.
        for length in 0...40 { cases.append(("a comment length of \(length) with 20 bytes after the record", bytes(62, recordAt: 20, comment: length), length <= 20)) }
        for (name, bytes, made) in cases {
            let readable = bytes.withUnsafeBytes(ArchiveEndRecord.readableOffset(in:)) != nil
            XCTAssertEqual(readable, made, "\(name): the forecast")
            do {
                _ = try Archive(data: bytes, accessMode: .read)
                XCTAssertTrue(made, "\(name): ZIPFoundation made an archive")
            } catch {
                XCTAssertEqual(error as? Archive.ArchiveError, .missingEndOfCentralDirectoryRecord, name)
                XCTAssertFalse(made, "\(name): ZIPFoundation refused, and has kept the bytes")
            }
        }
    }
}
