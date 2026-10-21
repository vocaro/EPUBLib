import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// Whether opening lets go of the bytes it was offered, by every way out of it.
///
/// ZIPFoundation 0.9.20 reads an in-memory archive through a file whose cookie keeps the bytes,
/// and does not close that file when it refuses them, so the bytes of every archive it refused
/// stayed allocated for the life of the process: 16 MiB for each 16 MiB file that was no book.
/// The bytes here are in memory of their own, whose release is seen: no figure for the
/// process's memory, which varies with the machine and with what else it is doing.
final class ArchiveInputReleaseTests: XCTestCase {
    private let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    /// A local file header's signature, which an archive begins with.
    private let localHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    /// What ZIPFoundation says of bytes it finds no end record in.
    private let noEndRecord = EPUBPublicationError.invalidArchive("missingEndOfCentralDirectoryRecord")
    private let chapter = "OPS/one.xhtml"

    private func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// `data` with the bytes at `offset` replaced.
    private func stating(_ bytes: Data, at offset: Int, in data: Data) -> Data {
        var data = data
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        return data
    }

    private func limits(_ change: (inout EPUBImportLimits) -> Void) -> EPUBImportLimits {
        var limits = EPUBImportLimits()
        change(&limits)
        return limits
    }

    /// Asserts that opening `bytes` fails, with `expected` when one is given, and that the bytes
    /// are released by the time it has.
    private func assertRefusedAndReleased(_ bytes: Data, limits: EPUBImportLimits = .init(), as expected: EPUBPublicationError?,
                                          _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let (error, released) = offered(bytes, limits: limits)
        if let expected {
            XCTAssertEqual(error as? EPUBPublicationError, expected, "\(name): \(String(describing: error))", file: file, line: line)
        } else {
            XCTAssertNotNil(error, "\(name): opened", file: file, line: line)
        }
        XCTAssertTrue(released, "\(name): the bytes were still held after they were refused", file: file, line: line)
    }

    /// Books and other bytes whose last end-record signature begins a record they do not hold
    /// the whole of: its comment length is more than the bytes after it.
    private func cutShort() throws -> [(name: String, bytes: Data)] {
        let entries = Fixture.storedEntries(try Fixture.files())
        let plain = Fixture.storedArchive(entries)
        let commented = Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8))
        let wide = Fixture.storedArchive(entries, zip64: .everything)
        var comment = Data(repeating: 0x20, count: 200)
        comment.replaceSubrange(178..<182, with: signature)
        // A megabyte of text that is no archive, with a signature near its end by chance.
        var text = Data(repeating: 0x41, count: 1 << 20)
        text.replaceSubrange((text.count - 30)..<(text.count - 26), with: signature)
        return [
            ("a comment length one more than the bytes after the record", stating(le(UInt16(1)), at: plain.count - 2, in: plain)),
            ("the longest comment length and no comment", stating(le(UInt16.max), at: plain.count - 2, in: plain)),
            ("a book cut one byte short of its comment's end", Data(commented.dropLast())),
            ("a book cut off after its record's 22 bytes", Data(commented.dropLast(17))),
            ("a ZIP64 book with a comment length and no comment", stating(le(UInt16(1)), at: wide.count - 2, in: wide)),
            ("a signature in a comment, 22 bytes from its end", Fixture.storedArchive(entries, comment: comment)),
            ("a megabyte of text with a signature 30 bytes from its end", text),
            ("a record alone, with a comment length", Data(signature) + Data(count: 16) + le(UInt16(1))),
        ]
    }

    // MARK: Bytes ZIPFoundation would refuse

    // Each of these reached ZIPFoundation, which read the record at the signature, found the
    // comment short, said there was no end record and kept the bytes. Of the ZIP64 book it kept
    // the copy that restates its zeros, whose release nothing here sees: that no such copy is
    // made any longer is seen in `ArchiveEndRecordTests`.
    func testBytesWhoseEndRecordIsCutShortAreReleased() throws {
        for (name, bytes) in try cutShort() { assertRefusedAndReleased(bytes, as: noEndRecord, name) }
    }

    func testBytesWithNoEndRecordAreReleased() {
        var late = Data(repeating: 0x41, count: 4096)
        late.replaceSubrange((late.count - 21)..<(late.count - 17), with: signature)
        var far = Data(repeating: 0x41, count: 70_000)
        far.replaceSubrange(0..<4, with: signature)
        // Bytes that begin as an archive does are searched to their first for a record, where
        // they lie. ZIPFoundation, which would keep them, is not asked to.
        var led = Data(repeating: 0x50, count: 1 << 20)
        led.replaceSubrange(0..<4, with: localHeader)
        var ledLate = led
        ledLate.replaceSubrange((ledLate.count - 21)..<(ledLate.count - 17), with: signature)
        let cases: [(String, Data)] = [
            ("text", Data(repeating: 0x41, count: 65_536)), ("zeros", Data(count: 1 << 20)),
            ("21 bytes of a record", Data(signature) + Data(count: 17)),
            ("a signature too near the end for a record", late),
            ("a signature further back than a record begins", far),
            ("a megabyte that begins as an archive does", led),
            ("the same with a signature too near the end for a record", ledLate),
        ]
        for (name, bytes) in cases { assertRefusedAndReleased(bytes, as: noEndRecord, name) }
    }

    // MARK: Bytes ZIPFoundation makes an archive of

    // An archive closes its file when it goes, and it goes when opening is over, however that is.
    func testBytesRefusedOnceTheirArchiveIsMadeAreReleased() throws {
        let files = try Fixture.files()
        let entries = Fixture.storedEntries(files)
        let plain = Fixture.storedArchive(entries)
        let record = try XCTUnwrap(Fixture.directoryOffset(of: chapter, in: plain))
        let content = try XCTUnwrap(Fixture.dataOffset(of: chapter, in: plain))
        let mimetype = entries[0], rest = Array(entries.dropFirst())
        let far = le(UInt32(0xFFFF_FFF0))
        let cases: [(name: String, bytes: Data, limits: EPUBImportLimits, expected: EPUBPublicationError)] = [
            ("no entries", Data(signature) + Data(count: 18), .init(), .invalidArchive("Missing EPUB mimetype")),
            // What `ArchiveBounds` refuses before an entry is read.
            ("a directory past the end", stating(far, at: plain.count - 6, in: plain), .init(), .invalidArchive("Central directory past the end of the archive")),
            ("an entry header past the end", stating(far, at: record + 42, in: plain), .init(), .invalidArchive("Entry header past the end of the archive")),
            ("entry data past the end", stating(le(UInt32(0x00FF_FFFF)), at: record + 24, in: plain), .init(), .invalidArchive("Entry data past the end of the archive")),
            // What the walk through the entries refuses.
            ("an unsafe path", Fixture.storedArchive([mimetype, Fixture.StoredEntry("../evil", "x")] + rest), .init(), .unsafePath("../evil")),
            ("a symlink", Fixture.storedArchive([mimetype, Fixture.StoredEntry("link", Data("target".utf8), versionMadeBy: 3 << 8 | 20, externalAttributes: 0o120777 << 16)] + rest),
             .init(), .unsafePath("link")),
            ("a path twice", Fixture.storedArchive(entries + [entries[1]]), .init(), .invalidArchive("Duplicate path: META-INF/container.xml")),
            ("more entries than the limit", plain, limits { $0.entryCount = 2 }, .limitExceeded("entry count")),
            ("an entry declared larger than the limit", plain, limits { $0.resourceBytes = 64 }, .limitExceeded("META-INF/container.xml")),
            ("entries declared larger together than the limit", plain, limits { $0.expandedBytes = 64 }, .limitExceeded("META-INF/container.xml")),
            ("a checksum that does not match", stating(Data([plain[content] ^ 0xFF]), at: content, in: plain), .init(), .invalidArchive("CRC: \(chapter)")),
            // What the book's own documents are refused for, every entry read.
            ("another mimetype", Fixture.storedArchive([Fixture.StoredEntry("mimetype", "text/plain")] + rest), .init(), .invalidArchive("Missing EPUB mimetype")),
            ("no container", Fixture.storedArchive([mimetype]), .init(), .missingResource("META-INF/container.xml")),
            ("a container that is not XML", Fixture.storedArchive(entries.map { $0.name == Data("META-INF/container.xml".utf8) ? Fixture.StoredEntry("META-INF/container.xml", "<container") : $0 }),
             .init(), .invalidXML("META-INF/container.xml")),
            ("a document larger than the limit", plain, limits { $0.xmlBytes = 16 }, .limitExceeded("META-INF/container.xml")),
            // ZIP64 zeros are restated in a copy, and the archive is made of that.
            ("an all-ZIP64 archive with an unsafe path", Fixture.storedArchive([mimetype, Fixture.StoredEntry("../evil", "x")] + rest, zip64: .everything), .init(), .unsafePath("../evil")),
            // An archive that other bytes follow is made of its own bytes, which are the same
            // memory, or of a copy of those alone.
            ("no entries, and other bytes after", Data(localHeader) + Data(signature) + Data(count: 18) + Data(count: 70_000), .init(), .invalidArchive("Missing EPUB mimetype")),
            ("a checksum that does not match, and other bytes after", stating(Data([plain[content] ^ 0xFF]), at: content, in: plain) + Data(count: 70_000), .init(), .invalidArchive("CRC: \(chapter)")),
            ("entry data past the archive's end, among the bytes after", stating(le(UInt32(plain.count)), at: record + 24, in: plain) + Data(count: 1 << 20), .init(),
             .invalidArchive("Entry data past the end of the archive")),
            ("an all-ZIP64 archive with an unsafe path, and other bytes after",
             Fixture.storedArchive([mimetype, Fixture.StoredEntry("../evil", "x")] + rest, zip64: .everything) + Data(count: 70_000), .init(), .unsafePath("../evil")),
        ]
        for (name, bytes, limits, expected) in cases { assertRefusedAndReleased(bytes, limits: limits, as: expected, name) }
    }

    func testBytesRefusedWhileAnEntryIsReadAreReleased() throws {
        let files = try Fixture.files()
        let deflated = try Fixture.epub()
        let record = try XCTUnwrap(Fixture.directoryOffset(of: chapter, in: deflated))
        let content = try XCTUnwrap(Fixture.dataOffset(of: chapter, in: deflated))
        // An entry that says it inflates to one byte, read with a limit a byte under what it
        // does inflate to: the refusal is thrown from inside the inflating.
        let size = try XCTUnwrap(files[chapter]).count
        assertRefusedAndReleased(stating(le(UInt32(1)), at: record + 24, in: deflated), limits: limits { $0.resourceBytes = size - 1 },
                                 as: .limitExceeded(chapter), "an entry that inflates past the limit")
        assertRefusedAndReleased(stating(le(UInt32(0x1234_5678)), at: record + 16, in: deflated), as: .invalidArchive("CRC: \(chapter)"),
                                 "an inflated entry whose checksum does not match")
        assertRefusedAndReleased(stating(Data(repeating: 0xFF, count: 24), at: content, in: deflated),
                                 as: .invalidArchive("\(chapter): corruptedData"), "a stream that does not inflate")
        // ZIPFoundation's own error, which is not yet typed (#74): only that it is one.
        var entries = Fixture.storedEntries(files)
        let index = try XCTUnwrap(entries.firstIndex { $0.name == Data(chapter.utf8) })
        entries[index].method = 12 // bzip2
        assertRefusedAndReleased(Fixture.storedArchive(entries), as: nil, "a method that is neither stored nor Deflate")
    }

    func testBytesAreReleasedWhenOpeningIsCancelledPartWayThroughAnEntry() async throws {
        let bytes = try Fixture.epub(overrides: ["OPS/payload": String(repeating: "x", count: 131_072)])
        let release = Release()
        let task = Task.detached { () -> Error? in
            autoreleasepool {
                let input = watchedCopy(of: bytes, telling: release)
                do {
                    _ = try EPUBPublication.open(data: input, onProgress: { expanded in
                        if expanded > 32_768 { withUnsafeCurrentTask { $0?.cancel() } }
                    })
                    return nil
                } catch { return error }
            }
        }
        let error = await task.value
        XCTAssertTrue(error is CancellationError, String(describing: error))
        XCTAssertTrue(release.happened)
    }

    func testBytesThatOpenAreKeptByTheBookAndReleasedWithIt() throws {
        let files = try Fixture.files()
        let entries = Fixture.storedEntries(files)
        // The last has ZIP64 zeros to restate, so its archive is made of a copy.
        let books: [(String, Data)] = [
            ("stored", Fixture.storedArchive(entries)), ("deflated", try Fixture.epub()),
            ("with a comment", Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8))),
            ("all ZIP64", Fixture.storedArchive(entries + [Fixture.StoredEntry("OPS/empty.css", Data())], zip64: .everything)),
            // Its archive is made of the bytes as far as the record's comment, and of a copy of
            // those where ZIP64 zeros are restated. The book keeps them all.
            ("with other bytes after it", Fixture.storedArchive(entries) + Data(count: 70_000)),
            ("all ZIP64, with other bytes after it", Fixture.storedArchive(entries + [Fixture.StoredEntry("OPS/empty.css", Data())], zip64: .everything) + Data(count: 70_000)),
        ]
        for (name, bytes) in books {
            let release = Release()
            try autoreleasepool {
                let book = try EPUBPublication.open(data: watchedCopy(of: bytes, telling: release))
                XCTAssertEqual(book.spine.count, 2, name)
                // `archiveData` is the bytes themselves, so they last as long as the book does.
                XCTAssertFalse(release.happened, "\(name): released while the book has them")
                XCTAssertEqual(book.archiveData, bytes, name)
            }
            XCTAssertTrue(release.happened, "\(name): the bytes were still held after the book had gone")
        }
    }

    // MARK: What is seen when bytes are kept

    // The fault itself, in the pinned ZIPFoundation and nowhere of this package's: asked for an
    // archive of bytes whose end record is cut short it keeps them, and the release that the
    // tests above wait for never comes. Opening asks it for no such archive
    // (`ArchiveEndRecord.readableOffset`). Each run of this test leaves those few bytes allocated.
    func testZIPFoundationKeepsBytesItRefusesAndReleasesThoseItMakesAnArchiveOf() throws {
        let plain = Fixture.storedArchive(Fixture.storedEntries(try Fixture.files()))
        let short = stating(le(UInt16(1)), at: plain.count - 2, in: plain)
        let kept = Release(), released = Release()
        try autoreleasepool {
            XCTAssertThrowsError(try Archive(data: watchedCopy(of: short, telling: kept), accessMode: .read)) {
                XCTAssertEqual($0 as? Archive.ArchiveError, .missingEndOfCentralDirectoryRecord)
            }
            XCTAssertNoThrow(try Archive(data: watchedCopy(of: plain, telling: released), accessMode: .read))
        }
        XCTAssertFalse(kept.happened, "ZIPFoundation released bytes it refused: if its version has changed, opening may no longer need to refuse them first")
        XCTAssertTrue(released.happened)
    }
}

/// Whether memory given to a `Data` to free has been freed.
private final class Release: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var happened: Bool { lock.withLock { value } }
    func record() { lock.withLock { value = true } }
}

/// A copy of `bytes` in memory of its own, which tells `release` when that memory is freed:
/// when the last `Data` sharing it has gone. More than the 14 bytes a `Data` holds in itself.
private func watchedCopy(of bytes: Data, telling release: Release) -> Data {
    precondition(bytes.count > 14)
    let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 16)
    memory.copyBytes(from: bytes)
    return Data(bytesNoCopy: memory.baseAddress!, count: bytes.count, deallocator: .custom { pointer, _ in
        pointer.deallocate()
        release.record()
    })
}

/// What opening made of a copy of `bytes` in memory of its own, and whether that memory had
/// been freed once the copy had gone, with whatever opening returned.
private func offered(_ bytes: Data, limits: EPUBImportLimits) -> (error: Error?, released: Bool) {
    let release = Release()
    let error: Error? = autoreleasepool {
        let input = watchedCopy(of: bytes, telling: release)
        do { _ = try EPUBPublication.open(data: input, limits: limits); return nil } catch { return error }
    }
    return (error, release.happened)
}
