import CryptoKit
import EPUBCore
@testable import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// What of a file is read to open the book in it (https://github.com/vocaro/EPUBLib/issues/208).
///
/// A file was read whole, as far as one byte past the archive limit, before anything was asked of
/// its bytes: 256 MiB read and allocated to refuse a file of 256 MiB that is no book by its last
/// 65,557 bytes and its first four, and as much to refuse a longer one by its length. These count
/// the bytes read, not the time or memory that took.
final class ArchiveFileTests: XCTestCase {
    /// What ZIPFoundation says of bytes it finds no end record in.
    private let noEndRecord = EPUBPublicationError.notArchive
    private let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private let localHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    /// The last bytes and the first four.
    private let ends = 65_557 + 4

    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        super.tearDown()
    }

    /// A file of `count` zero bytes but for `writes`: sparse, so that no more than those is
    /// written to the disk however long it is.
    private func file(count: Int, writes: [(bytes: [UInt8], offset: Int)] = []) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".epub")
        files.append(url)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(count))
        for write in writes {
            try handle.seek(toOffset: UInt64(write.offset))
            try handle.write(contentsOf: write.bytes)
        }
        return url
    }

    private func file(_ data: Data) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".epub")
        files.append(url)
        try data.write(to: url)
        return url
    }

    /// What reading the file at `url` to open it gives or throws, and how many bytes it read.
    private static func reading(_ url: URL, limits: EPUBImportLimits = .init()) throws -> (result: Result<Data, Error>, read: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var file = ArchiveFile(handle: handle)
        let result = Result { try file.bytes(limits: limits) }
        return (result, file.bytesRead)
    }

    /// What opening gives, as text that two outcomes can be compared by.
    private func outcome(_ open: () throws -> EPUBPublication) -> String {
        do {
            let book = try open()
            return "opens \(book.id) \(book.spine.map(\.resource.path))"
        } catch {
            return "\(type(of: error)) \(error)"
        }
    }

    private func limits(_ change: (inout EPUBImportLimits) -> Void) -> EPUBImportLimits {
        var limits = EPUBImportLimits()
        change(&limits)
        return limits
    }

    // MARK: Refused by its ends

    func testAFileOfTheLengthABookMayBeThatIsNoArchiveIsRefusedByItsEnds() throws {
        // 256 MiB of zeros, the default archive limit: no record in the last 65,557 bytes and no
        // local file header's signature in the first four.
        let length = EPUBImportLimits().archiveBytes
        let url = try file(count: length)
        let (result, read) = try Self.reading(url)
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? EPUBPublicationError, self.noEndRecord) }
        XCTAssertEqual(read, ends, "bytes read of \(length)")
        XCTAssertThrowsError(try EPUBPublication.open(at: url)) { XCTAssertEqual($0 as? EPUBPublicationError, self.noEndRecord) }
    }

    func testARecordItsLastBytesCutShortRefusesItUnreadBeyondThem() throws {
        // The last signature begins a record whose comment runs past the end: no archive, and the
        // first four bytes are not needed to say so.
        let length = 16 << 20, end = length - 22
        for (name, writes) in [("a comment length past the end", [(signature, end), ([1, 0], end + 20)]),
                               ("a signature too near the end for a record, after one that is cut short",
                                [(signature, length - 100), ([0xFF, 0], length - 80), (signature, length - 10)])] {
            let (result, read) = try Self.reading(try file(count: length, writes: writes.map { (bytes: $0.0, offset: $0.1) }))
            XCTAssertThrowsError(try result.get(), name) { XCTAssertEqual($0 as? EPUBPublicationError, self.noEndRecord, name) }
            XCTAssertEqual(read, 65_557, name)
        }
    }

    func testBytesThatBeginAsAnArchiveDoAreReadWholeToBeSearched() throws {
        // A local file header's signature first: the archive may end further back, with other
        // bytes after it, so every byte is read and searched, as before.
        let length = 4 << 20
        let url = try file(count: length, writes: [(localHeader, 0)])
        let (result, read) = try Self.reading(url)
        XCTAssertEqual(try result.get().count, length)
        XCTAssertEqual(read, ends + length)
        XCTAssertThrowsError(try EPUBPublication.open(at: url)) { XCTAssertEqual($0 as? EPUBPublicationError, self.noEndRecord) }
    }

    // MARK: Refused by its length

    func testAFileLongerThanTheLimitIsRefusedUnread() throws {
        // As its bytes were when one more than the limit had been read: by the import limits.
        let book = try Fixture.epub()
        let small = limits { $0.archiveBytes = 1 << 20 }
        for (name, url) in [("zeros", try file(count: (1 << 20) + 1)), ("a book and a megabyte after it", try file(book + Data(count: 1 << 20)))] {
            let (result, read) = try Self.reading(url, limits: small)
            XCTAssertThrowsError(try result.get(), name) { XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("import limits"), name) }
            XCTAssertEqual(read, 0, name)
        }
        // A limit no file is within, and one no file can be read to, are refused before the file
        // is looked at.
        for (archiveBytes, refusal) in [(0, "archiveBytes"), (Int.max, "archiveBytes")] {
            XCTAssertThrowsError(try EPUBPublication.open(at: try file(book), limits: limits { $0.archiveBytes = archiveBytes })) {
                XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded(refusal))
            }
        }
    }

    func testACancelledOpeningReadsNothing() async throws {
        let url = try file(count: 4 << 20)
        let (error, read) = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let (result, read) = try Self.reading(url)
            return (result.map { _ in () }.mapError { $0 }, read)
        }.value
        XCTAssertThrowsError(try error.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(read, 0)
    }

    // MARK: Read whole

    func testAFileItsEndsLeaveAPossibleArchiveIsReadWholeAndOpensAsItsBytesDo() throws {
        let entries = Fixture.storedEntries(try Fixture.files())
        let book = try Fixture.epub()
        let cases: [(name: String, bytes: Data, read: Int)] = [
            ("a book shorter than a record reaches", book, book.count),
            ("a book with the longest comment", Fixture.storedArchive(entries, comment: Data(repeating: 0x20, count: 65_535)), 65_557),
            ("an all-ZIP64 book", Fixture.storedArchive(entries + [Fixture.StoredEntry("OPS/empty.css")], zip64: .everything), 0),
            ("a book and a megabyte of other bytes after it", book + Data(repeating: 0x0A, count: 1 << 20), ends),
            ("a book and a megabyte of zeros before it", Data(count: 1 << 20) + book, 65_557),
        ]
        for (name, bytes, before) in cases {
            let url = try file(bytes)
            let (result, read) = try Self.reading(url)
            XCTAssertEqual(try result.get(), bytes, name)
            // The ends, where the file is longer than they reach, and then every byte.
            XCTAssertEqual(read, (bytes.count > 65_557 ? before : 0) + bytes.count, name)
            XCTAssertEqual(outcome { try EPUBPublication.open(at: url) }, outcome { try EPUBPublication.open(data: bytes) }, name)
        }
    }

    // MARK: The same refusal as the bytes'

    func testEveryFileIsRefusedOrOpenedAsItsBytesAre() throws {
        // Files that are no archive, are one, or are cut short or followed by other bytes, each
        // under limits that admit it, refuse it by its length, or admit nothing.
        let entries = Fixture.storedEntries(try Fixture.files())
        let book = try Fixture.epub(), plain = Fixture.storedArchive(entries)
        var cutShort = plain
        cutShort.replaceSubrange((cutShort.count - 2)..<cutShort.count, with: [1, 0])
        let contents: [(String, Data)] = [
            ("nothing", Data()), ("a hundred zeros", Data(count: 100)), ("a record alone", Data(signature) + Data(count: 18)),
            ("a megabyte of zeros", Data(count: 1 << 20)), ("a megabyte of text", Data(repeating: 0x41, count: 1 << 20)),
            ("a local file header's signature and a megabyte of zeros", Data(localHeader) + Data(count: 1 << 20)),
            ("a book", book), ("a stored book", plain), ("a book with a record cut short", cutShort),
            ("a book cut short", book.dropLast(3)), ("a book and a megabyte after it", book + Data(count: 1 << 20)),
            ("a megabyte of zeros and a book", Data(count: 1 << 20) + book),
            ("a megabyte of zeros, then a book and 70,000 bytes after it", Data(count: 1 << 20) + plain + Data(count: 70_000)),
        ]
        let limitSets: [(String, EPUBImportLimits)] = [
            ("the default limits", EPUBImportLimits()), ("an archive limit of 512 KiB", limits { $0.archiveBytes = 512 << 10 }),
            ("an archive limit of the book's length", limits { $0.archiveBytes = book.count }),
            ("no resource bytes", limits { $0.resourceBytes = 0 }), ("no XML bytes", limits { $0.xmlBytes = 0 }),
            ("no entries", limits { $0.entryCount = 0 }),
        ]
        for (name, bytes) in contents {
            let url = try file(bytes)
            for (limitsName, limits) in limitSets {
                XCTAssertEqual(outcome { try EPUBPublication.open(at: url, limits: limits) },
                               outcome { try EPUBPublication.open(data: bytes, limits: limits) }, "\(name), \(limitsName)")
            }
        }
    }

    // MARK: What cannot be read at an offset

    /// `body` given a URL whose file is the read end of a pipe that `bytes` are written into.
    private func throughAPipe(_ bytes: Data, _ body: (URL) throws -> Void) throws {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        let (reader, writer) = (ends[0], ends[1])
        // A reader that stops early leaves the writer an error, not a signal.
        XCTAssertNotEqual(fcntl(writer, F_SETNOSIGPIPE, 1), -1)
        let written = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = write(writer, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count <= 0 { break }
                    offset += count
                }
            }
            close(writer)
            written.signal()
        }
        defer {
            close(reader)
            written.wait()
        }
        try body(URL(fileURLWithPath: "/dev/fd/\(reader)"))
    }

    func testAPipeIsReadFromItsFirstByteAndRefusedOrOpenedAsItsBytesAre() throws {
        let book = try Fixture.epub()
        for (name, bytes) in [("a book", book), ("a megabyte of text", Data(repeating: 0x41, count: 1 << 20)), ("nothing", Data())] {
            try throughAPipe(bytes) { url in
                let (result, read) = try Self.reading(url)
                XCTAssertEqual(try result.get(), bytes, name)
                XCTAssertEqual(read, bytes.count, name)
            }
            try throughAPipe(bytes) { url in
                XCTAssertEqual(outcome { try EPUBPublication.open(at: url) }, outcome { try EPUBPublication.open(data: bytes) }, name)
            }
        }
        // Devices, which give an end of 0: nothing to read, and so no end record, and zeros
        // without end, read as far as one more than the limit.
        XCTAssertThrowsError(try EPUBPublication.open(at: URL(fileURLWithPath: "/dev/null"))) {
            XCTAssertEqual($0 as? EPUBPublicationError, self.noEndRecord)
        }
        let (result, read) = try Self.reading(URL(fileURLWithPath: "/dev/zero"), limits: limits { $0.archiveBytes = 1 << 20 })
        XCTAssertEqual(try result.get(), Data(count: (1 << 20) + 1))
        XCTAssertEqual(read, (1 << 20) + 1)
        XCTAssertThrowsError(try EPUBPublication.open(at: URL(fileURLWithPath: "/dev/zero"), limits: limits { $0.archiveBytes = 1 << 20 })) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("import limits"))
        }
    }
}
