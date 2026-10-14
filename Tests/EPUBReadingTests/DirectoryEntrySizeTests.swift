import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// Directory payloads are never read. Their sizes must not refuse a book, while the same
/// declarations on genuine files must retain the pre-extraction protection against #175.
final class DirectoryEntrySizeTests: XCTestCase {
    private func stating(_ sizes: [Int: UInt32], for name: String, in archive: Data) throws -> Data {
        var data = archive
        let record = try XCTUnwrap(Fixture.directoryOffset(of: name, in: data))
        for (field, value) in sizes {
            data.replaceSubrange((record + field)..<(record + field + 4),
                                 with: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }
        return data
    }

    private func statingZIP64(_ sizes: [Int: UInt64], for name: String, in archive: Data) throws -> Data {
        var data = archive
        let record = try XCTUnwrap(Fixture.directoryOffset(of: name, in: data))
        // Fixture ZIP64 .sizes places uncompressed and compressed values in its only extra field.
        let values = record + 46 + name.utf8.count + 4
        for (field, value) in sizes {
            let offset = values + (field == 24 ? 0 : 8)
            data.replaceSubrange(offset..<(offset + 8), with: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }
        return data
    }

    private func assertBook(_ data: Data, files: [String: Data], _ message: String, line: UInt = #line) throws {
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], message, line: line)
        for (path, expected) in files {
            XCTAssertEqual(try book.data(at: path), expected, "\(message): \(path)", line: line)
        }
    }

    private func assertRefusedUnread(_ data: Data, as expected: EPUBPublicationError, _ message: String, line: UInt = #line) {
        final class Chunks: @unchecked Sendable { var count = 0 }
        let chunks = Chunks()
        XCTAssertThrowsError(try EPUBPublication.open(data: data, onProgress: { _ in chunks.count += 1 }), message, line: line) {
            XCTAssertEqual($0 as? EPUBPublicationError, expected, message, line: line)
        }
        XCTAssertEqual(chunks.count, 0, "\(message): no payload was read", line: line)
    }

    func testStoredDirectoriesOpenWithEitherOrBothDeclaredSizes() throws {
        let files = try Fixture.files()
        // Names and platform attributes do not always agree. ZIPFoundation owns this decision.
        let directories = [Fixture.StoredEntry("OPS/"),
                           Fixture.StoredEntry("OPS/unix-directory", versionMadeBy: 3 << 8 | 20, externalAttributes: 0o040755 << 16),
                           Fixture.StoredEntry("OPS/mac-directory", versionMadeBy: 19 << 8 | 20, externalAttributes: 0o040755 << 16),
                           Fixture.StoredEntry("OPS/dos-directory", externalAttributes: 0x10)]
        let base = Fixture.storedArchive(Fixture.storedEntries(files) + directories)
        for directory in directories {
            let name = String(decoding: directory.name, as: UTF8.self)
            XCTAssertEqual(try Archive(data: base, accessMode: .read)[name]?.type, .directory, name)
            for size in [UInt32(77), UInt32(base.count + 1), UInt32(EPUBImportLimits().resourceBytes + 1), UInt32.max - 1] {
                for fields in [[20], [24], [20, 24]] {
                    let data = try stating(Dictionary(uniqueKeysWithValues: fields.map { ($0, size) }), for: name, in: base)
                    try assertBook(data, files: files, "\(name): size \(size), fields \(fields)")
                    XCTAssertThrowsError(try EPUBPublication.open(data: data).data(at: name), "the directory is not a resource")
                }
            }
        }
    }

    func testZIP64DirectoriesOpenEvenWithSizesLargerThanSignedIntegers() throws {
        let files = try Fixture.files()
        let base = Fixture.storedArchive(Fixture.storedEntries(files) + [Fixture.StoredEntry("OPS/")], zip64: .sizes)
        for size in [UInt64(1) << 40, 1 << 63, .max] {
            for fields in [[20], [24], [20, 24]] {
                try assertBook(statingZIP64(Dictionary(uniqueKeysWithValues: fields.map { ($0, size) }), for: "OPS/", in: base),
                               files: files, "ZIP64 size \(size), fields \(fields)")
            }
        }
    }

    func testStoredFileBoundsStillRefuseBeforeReadingAfterAnOversizedDirectory() throws {
        let files = try Fixture.files()
        // Unix and macOS mode bits override a trailing slash. A suffix-only exception here
        // would mistake these genuine files for directories and reopen the stored-entry stall.
        let entries = [Fixture.StoredEntry("OPS/"), Fixture.StoredEntry("OPS/file.bin"),
                       Fixture.StoredEntry("OPS/unix-file/", versionMadeBy: 3 << 8 | 20, externalAttributes: 0o100644 << 16),
                       Fixture.StoredEntry("OPS/mac-file/", versionMadeBy: 19 << 8 | 20, externalAttributes: 0o100644 << 16)]
        let base = try stating([24: UInt32.max - 1], for: "OPS/", in: Fixture.storedArchive(Fixture.storedEntries(files) + entries))
        for entry in entries.dropFirst() {
            let name = String(decoding: entry.name, as: UTF8.self)
            XCTAssertEqual(try Archive(data: base, accessMode: .read)[name]?.type, .file, name)
            assertRefusedUnread(try stating([24: UInt32(base.count + 1)], for: name, in: base),
                                as: .invalidArchive("Entry data past the end of the archive"), name)
        }
        let wide = Fixture.storedArchive(Fixture.storedEntries(files) + entries, zip64: .sizes)
        let directoryFirst = try statingZIP64([24: .max], for: "OPS/", in: wide)
        for size in [UInt64(1) << 40, 1 << 63, .max] {
            assertRefusedUnread(try statingZIP64([24: size], for: "OPS/file.bin", in: directoryFirst),
                                as: .invalidArchive("Entry data past the end of the archive"), "ZIP64 file size \(size)")
        }
    }

    func testDirectoryIteratorOffsetsAndDescriptorsRemainBounded() throws {
        let entries = Fixture.storedEntries(try Fixture.files()) + [Fixture.StoredEntry("OPS/")]
        let base = Fixture.storedArchive(entries)
        assertRefusedUnread(try stating([42: UInt32(base.count + 1)], for: "OPS/", in: base),
                            as: .invalidArchive("Entry header past the end of the archive"), "a directory header outside the archive")
        // Iteration seeks a descriptor even for a directory. That seek must stay bounded.
        for method in [UInt16(0), 8] {
            let described = Fixture.storedArchive(Fixture.storedEntries(try Fixture.files())
                                                 + [Fixture.StoredEntry("OPS/", flags: 0x0808, method: method)])
            let field = method == 0 ? 24 : 20
            assertRefusedUnread(try stating([field: UInt32(described.count + 1)], for: "OPS/", in: described),
                                as: .invalidArchive("Data descriptor past the end of the archive"), "directory method \(method)")
        }
    }

    func testOversizedDirectoriesStillCheckUnsafePathsAndEntryCounts() throws {
        let entries = Fixture.storedEntries(try Fixture.files())
        let unsafe = try stating([24: UInt32.max - 1], for: "../", in: Fixture.storedArchive(entries + [Fixture.StoredEntry("../")]))
        XCTAssertThrowsError(try EPUBPublication.open(data: unsafe)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("../"))
        }
        let data = try stating([24: UInt32.max - 1], for: "OPS/", in: Fixture.storedArchive(entries + [Fixture.StoredEntry("OPS/")]))
        var limits = EPUBImportLimits()
        limits.entryCount = entries.count
        XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("entry count"))
        }
    }

    func testAStoredFilesCompressedSizeDoesNotDetermineItsReadSize() throws {
        let files = try Fixture.files()
        let base = Fixture.storedArchive(Fixture.storedEntries(files) + [Fixture.StoredEntry("OPS/empty.bin")], zip64: .sizes)
        let data = try statingZIP64([20: .max], for: "OPS/empty.bin", in: base)
        try assertBook(data, files: files, "a stored file reads by its uncompressed size")
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/empty.bin"), Data())
    }

    func testTheOwnersIssue260FuzzReproducerOpensUnchanged() throws {
        // https://github.com/vocaro/EPUBLib/issues/260#issuecomment-6141048993
        // OPS/ is stored, with compressed size zero and uncompressed size 5,000.
        let data = try XCTUnwrap(Data(base64Encoded: """
        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
        """, options: .ignoreUnknownCharacters))
        XCTAssertEqual(data.count, 1756)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                       "a40419e36f7dd55895436ac57963e94a8c4bc687c31d9d24bf82e6263f4c49c8")
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.metadata.title, "Review Book")
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml"])
        XCTAssertTrue(try book.textSection(at: 0).text.contains("Reading text for the review of issue 175, repeated."))
        XCTAssertEqual(try book.data(at: "OPS/empty.css"), Data())
    }
}
