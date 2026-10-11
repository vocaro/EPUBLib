import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// The OCF ZIP container: entry names, layouts other ZIP writers produce, damage and limits.
final class ContainerArchiveCoverageTests: XCTestCase {
    private func assertOpening(_ data: Data, limits: EPUBImportLimits = .init(), throws expected: EPUBPublicationError,
                               _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits), message, file: file, line: line) {
            XCTAssertEqual($0 as? EPUBPublicationError, expected, "\(message): \($0)", file: file, line: line)
        }
    }

    // MARK: Layout

    func testTheMimetypeEntryNeedNotComeFirstOrBeStored() throws {
        // EPUB 3.3 §4.3.3 binds the creator; a reader that insisted would refuse books zipped in one pass.
        let files = try Fixture.files()
        let archive = try Archive(accessMode: .create)
        for name in files.keys.sorted() { // Upper case sorts first: META-INF, OPS, then mimetype.
            let bytes = files[name]!
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { position, size in
                bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        let data = try XCTUnwrap(archive.data)
        XCTAssertNotEqual(try Archive(data: data, accessMode: .read).makeIterator().next()?.path, "mimetype")
        XCTAssertEqual(try EPUBPublication.open(data: data).spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
    }

    func testAnArchiveWithoutTheEPUBMimetypeIsRefusedAsInvalid() throws {
        var files = try Fixture.files()
        files["mimetype"] = nil
        assertOpening(try Fixture.archive(files), throws: .invalidArchive("Missing EPUB mimetype"), "no mimetype entry")
        assertOpening(try Fixture.epub(overrides: ["mimetype": "application/zip"]), throws: .invalidArchive("Missing EPUB mimetype"))
        assertOpening(try Fixture.epub(overrides: ["mimetype": ""]), throws: .invalidArchive("Missing EPUB mimetype"), "empty")
        assertOpening(Fixture.storedArchive([]), throws: .invalidArchive("Missing EPUB mimetype"), "an archive of no entries")
    }

    func testBytesThatAreNoZIPArchiveAreRefusedAsInvalid() throws {
        let whole = try Fixture.epub()
        for (name, data) in [("empty", Data()), ("text", Data("application/epub+zip".utf8)),
                             ("cut before the directory", Data(whole.prefix(whole.count / 2))),
                             ("a lone signature", Data([0x50, 0x4b, 0x03, 0x04]))] {
            XCTAssertThrowsError(try EPUBPublication.open(data: data), name) {
                guard case .invalidArchive = $0 as? EPUBPublicationError else { return XCTFail("\(name): \($0)") }
            }
        }
    }

    func testDirectoryRecordsAreAcceptedAndAreNotResources() throws {
        var entries = Fixture.storedEntries(try Fixture.files())
        entries.insert(Fixture.StoredEntry("META-INF/"), at: 1)
        // Written by a Unix tool: the mode says directory.
        entries.insert(Fixture.StoredEntry("OPS/", versionMadeBy: 3 << 8 | 20, externalAttributes: 0o040755 << 16), at: 2)
        let plain = try EPUBPublication.open(data: Fixture.epub())
        let book = try EPUBPublication.open(data: Fixture.storedArchive(entries))
        XCTAssertEqual(book.resources, plain.resources)
        XCTAssertEqual(book.tableOfContents, plain.tableOfContents)
        XCTAssertThrowsError(try book.data(at: "OPS/")) {
            XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("OPS/"))
        }
    }

    func testEntriesWhoseSizesFollowTheirDataAreRead() throws {
        // Streaming writers set bit 3 and leave the local header's CRC and sizes zero.
        let files = try Fixture.files()
        let book = try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files, flags: 0x0808)))
        XCTAssertEqual(book.metadata.title, "A Test Book")
        for (path, bytes) in files { XCTAssertEqual(try book.data(at: path), bytes, path) }
    }

    func testEntrySizesInZIP64ExtraFieldsAreReadAndBounded() throws {
        // EPUB Reading Systems 3.3 §4.2: a reader must "support the ZIP64 extensions". A writer
        // that cannot seek back uses them for entries of any size.
        let files = try Fixture.files()
        let data = Fixture.storedArchive(Fixture.storedEntries(files), zip64: .sizes)
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        for (path, bytes) in files { XCTAssertEqual(try book.data(at: path), bytes, path) }
        var limits = EPUBImportLimits()
        limits.resourceBytes = files.values.map(\.count).max()! - 1
        XCTAssertThrowsError(try EPUBPublication.open(data: data, limits: limits), "a size read from a ZIP64 field is still bounded") {
            guard case .limitExceeded = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
        }
    }

    func testAnEmptyEntryWithZIP64SizesIsRead() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/72")
        // The same layout holding one empty file, which Python's zipfile and Info-ZIP's unzip read
        // as empty. Its sizes are 0xFFFFFFFF in the headers and zero in the ZIP64 field.
        var files = try Fixture.files()
        files["OPS/empty.css"] = Data()
        let data = Fixture.storedArchive(Fixture.storedEntries(files), zip64: .sizes)
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/empty.css"), Data())
    }

    // DISABLED: TRAPS THE TEST PROCESS ("Fatal error: Range requires lowerBound <= upperBound" in
    // ZIPFoundation's Archive.MemoryFile.readData, reached from EPUBPublication.open(data:) as it
    // iterates the archive). Rename to `test…` to reproduce. The archive is valid: Python's zipfile
    // and Info-ZIP's unzip read it. Every entry's header offset is 0xFFFFFFFF in the directory
    // with the real offset in its ZIP64 extra field, as a writer told always to use ZIP64 writes;
    // the first entry's real offset is zero, which ZIPFoundation takes for "absent".
    // https://github.com/vocaro/EPUBLib/issues/72
    func disabled_testAZIP64ArchiveWithItsOffsetsInExtraFieldsIsRead() throws {
        // EPUB Reading Systems 3.3 §4.2: a reader must "support the ZIP64 extensions".
        let files = try Fixture.files()
        let book = try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files), zip64: .everything))
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        for (path, bytes) in files { XCTAssertEqual(try book.data(at: path), bytes, path) }
    }

    func testTheIdentityIsTheSHA256OfTheArchiveBytesWhateverTheBookSays() throws {
        // doc/integration.md: files that change "have a different SHA-256 identity, even when their
        // metadata identifier is unchanged". Here only the archive's comment differs.
        let entries = Fixture.storedEntries(try Fixture.files())
        let plain = Fixture.storedArchive(entries), commented = Fixture.storedArchive(entries, comment: Data("Packed for a test".utf8))
        let first = try EPUBPublication.open(data: plain), second = try EPUBPublication.open(data: commented)
        XCTAssertEqual(first.id, SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(second.id, SHA256.hash(data: commented).map { String(format: "%02x", $0) }.joined())
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.metadata, second.metadata)
        XCTAssertEqual(second.archiveData, commented)
    }

    // MARK: Entry names

    func testUTF8EntryNamesAreReadWithoutTheLanguageEncodingFlag() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/73")
        // EPUB 3.3 §4.3.2: names are UTF-8. The zip and ditto tools on a Mac write UTF-8 names and
        // leave general-purpose bit 11 clear, which ZIP itself reads as code page 437.
        var files = try Fixture.packageVariantFiles(
            opf: { $0.replacingOccurrences(of: "href=\"one.xhtml\"", with: "href=\"caf%C3%A9.xhtml\"") },
            nav: { $0.replacingOccurrences(of: "one.xhtml#start", with: "caf%C3%A9.xhtml#start") })
        files["OPS/caf\u{E9}.xhtml"] = files.removeValue(forKey: "OPS/one.xhtml")
        func book(flags: UInt16) throws -> EPUBPublication {
            try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files, flags: flags)))
        }
        XCTAssertEqual(try book(flags: 0x0800).spine.first?.resource.path, "OPS/caf\u{E9}.xhtml", "with the flag")
        XCTAssertEqual(try book(flags: 0).spine.first?.resource.path, "OPS/caf\u{E9}.xhtml", "without the flag")
        XCTAssertEqual(try book(flags: 0).tableOfContents.first?.href, "OPS/caf%C3%A9.xhtml#start", "without the flag")
    }

    func testADecomposedEntryNameAnswersToAPrecomposedReference() throws {
        // A Mac's file system hands zip tools decomposed names; packages are written precomposed.
        let decomposed = "OPS/cafe\u{301}.xhtml", precomposed = "OPS/caf\u{E9}.xhtml"
        XCTAssertNotEqual(Array(decomposed.utf8), Array(precomposed.utf8))
        var files = try Fixture.packageVariantFiles(
            opf: { $0.replacingOccurrences(of: "href=\"one.xhtml\"", with: "href=\"caf%C3%A9.xhtml\"") },
            nav: { $0.replacingOccurrences(of: "one.xhtml#start", with: "cafe%CC%81.xhtml#start") })
        let chapter = try XCTUnwrap(files.removeValue(forKey: "OPS/one.xhtml"))
        var entries = Fixture.storedEntries(files)
        entries.append(Fixture.StoredEntry(decomposed, chapter))
        let book = try EPUBPublication.open(data: Fixture.storedArchive(entries))
        XCTAssertEqual(book.spine.count, 2)
        XCTAssertEqual(try book.data(for: book.spine[0].resource), chapter)
        XCTAssertEqual(try book.data(at: decomposed), chapter)
        XCTAssertEqual(try book.data(at: precomposed), chapter)
        XCTAssertEqual(book.tableOfContents.first?.href?.removingPercentEncoding, book.spine[0].resource.path + "#start")
    }

    func testEntryNamesDifferingOnlyByCaseAreDifferentFiles() throws {
        let files = try Fixture.packageVariantFiles(
            opf: { $0.replacingOccurrences(of: "<manifest>", with: "<manifest><item id=\"upper\" href=\"ONE.xhtml\" media-type=\"application/xhtml+xml\"/>") },
            adding: ["OPS/ONE.xhtml": Data("<html/>".utf8)])
        let book = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(try book.data(at: "OPS/ONE.xhtml"), Data("<html/>".utf8))
        XCTAssertNotEqual(try book.data(at: "OPS/one.xhtml"), Data("<html/>".utf8))
        XCTAssertEqual(Set(book.resources.map(\.path)).count, book.resources.count)
        XCTAssertThrowsError(try book.data(at: "ops/one.xhtml"))
    }

    func testEntryNamesEqualAfterNormalizationAreDuplicates() throws {
        // EPUB 3.3 §4.2.3: names in one directory are unique after canonical normalization.
        var entries = Fixture.storedEntries(try Fixture.files())
        entries.append(Fixture.StoredEntry("OPS/caf\u{E9}.css", "a{}"))
        entries.append(Fixture.StoredEntry("OPS/cafe\u{301}.css", "b{}"))
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.storedArchive(entries))) {
            guard case .invalidArchive(let reason) = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("Duplicate"), reason)
        }
    }

    // MARK: Damage

    // A book is untrusted input. ZIPFoundation's in-memory file traps when it is read after a seek
    // past its end ("Fatal error: Range requires lowerBound <= upperBound"), so these inputs took
    // the host down instead of failing to open.
    func testAnOffsetBeyondTheEndOfTheArchiveIsRefusedWithoutTrapping() throws {
        // An entry whose local header the directory places one byte past the end of the archive.
        var entry = try Fixture.epub()
        let record = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/one.xhtml", in: entry))
        entry.replaceSubrange((record + 42)..<(record + 46), with: withUnsafeBytes(of: UInt32(entry.count + 1).littleEndian) { Array($0) })
        // A directory the end record places beyond the end of the archive.
        var directory = try Fixture.epub()
        let end = directory.count - 22
        directory.replaceSubrange((end + 16)..<(end + 20), with: [0xF0, 0xFF, 0xFF, 0x7F])
        for (name, data) in [("entry offset", entry), ("directory offset", directory)] {
            XCTAssertThrowsError(try EPUBPublication.open(data: data), name) {
                guard case .invalidArchive = $0 as? EPUBPublicationError else { return XCTFail("\(name): \($0)") }
            }
        }
    }

    /// `archive` with one 32-bit size of `name`'s directory record (at 20 the compressed size, at
    /// 24 the uncompressed) set to all ones and `value` in a ZIP64 extra field, where a ZIP64
    /// writer puts a size too large for the field.
    private func archive(_ archive: Data, givingSize field: Int, of name: String, as value: UInt64) throws -> Data {
        var data = archive
        let record = try XCTUnwrap(Fixture.directoryOffset(of: name, in: data))
        XCTAssertEqual([data[record + 30], data[record + 31]], [0, 0], "the record has no extra field yet")
        data.replaceSubrange((record + field)..<(record + field + 4), with: [0xFF, 0xFF, 0xFF, 0xFF])
        data[record + 30] = 12
        data.insert(contentsOf: [1, 0, 8, 0] + withUnsafeBytes(of: value.littleEndian) { Array($0) }, at: record + 46 + name.utf8.count)
        return data
    }

    func testAZIP64OffsetOrSizeBeyondTheEndOfTheArchiveIsRefusedWithoutTrapping() throws {
        func assertRefused(_ data: Data, _ name: String, line: UInt = #line) {
            XCTAssertThrowsError(try EPUBPublication.open(data: data), name, line: line) {
                guard case .invalidArchive = $0 as? EPUBPublicationError else { return XCTFail("\(name): \($0)", line: line) }
            }
        }
        // Every size and header offset in a ZIP64 field, behind a ZIP64 end record. The first
        // entry's offset is zero, which ZIPFoundation reads only from the record itself, so it is
        // stated there and that record's ZIP64 field keeps its two sizes.
        var wide = Fixture.storedArchive(Fixture.storedEntries(try Fixture.files()), zip64: .everything)
        let first = try XCTUnwrap(Fixture.directoryOffset(of: "mimetype", in: wide))
        wide.replaceSubrange((first + 42)..<(first + 46), with: [0, 0, 0, 0])
        wide[first + 46 + "mimetype".utf8.count + 2] = 16
        XCTAssertEqual(try EPUBPublication.open(data: wide).spine.count, 2, "offsets inside the archive are followed")
        // An entry's header offset comes after the two sizes in its record's ZIP64 field; the
        // directory's offset ends the ZIP64 end record, 28 bytes before the end record.
        let record = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/one.xhtml", in: wide))
        for (name, field) in [("header", record + 46 + "OPS/one.xhtml".utf8.count + 20), ("directory", wide.count - 22 - 28)] {
            for offset in [UInt64(wide.count) + 1, 1 << 32, 1 << 63, .max] {
                var data = wide
                data.replaceSubrange(field..<(field + 8), with: withUnsafeBytes(of: offset.littleEndian) { Array($0) })
                assertRefused(data, "a \(name) offset of \(offset)")
            }
        }

        // A data descriptor sought after a ZIP64 size, which may also wrap around.
        let described = Fixture.storedArchive(Fixture.storedEntries(try Fixture.files(), flags: 0x0808))
        XCTAssertEqual(try EPUBPublication.open(data: described).spine.count, 2)
        for size in [UInt64(described.count), 1 << 63, .max] {
            assertRefused(try archive(described, givingSize: 24, of: "OPS/one.xhtml", as: size), "a described size of \(size)")
        }

        // A deflated entry's ZIP64 size: read by when it is the entry's own, and refused at 2^63
        // bytes or more, which the signed size ZIPFoundation reads by cannot hold.
        let deflated = try Fixture.epub()
        let field = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/one.xhtml", in: deflated)) + 20
        let compressed = (0..<4).reduce(UInt64(0)) { $0 | UInt64(deflated[field + $1]) << (8 * UInt64($1)) }
        XCTAssertEqual(try EPUBPublication.open(data: archive(deflated, givingSize: 20, of: "OPS/one.xhtml", as: compressed)).spine.count, 2)
        for size in [UInt64(1) << 63, .max] {
            assertRefused(try archive(deflated, givingSize: 20, of: "OPS/one.xhtml", as: size), "a compressed size of \(size)")
        }
    }

    func testADamagedOrUnreadableEntryFailsAsAnInvalidArchive() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/74")
        // A stored entry's damage is typed (CRC). Deflated data that does not inflate, or a method
        // other than stored and Deflate (EPUB Reading Systems 3.3 §4.2: in error), must be too.
        var damaged = try Fixture.epub()
        let offset = try XCTUnwrap(Fixture.dataOffset(of: "OPS/one.xhtml", in: damaged))
        damaged[offset] = 0x07 // A final block of the reserved type.
        var entries = Fixture.storedEntries(try Fixture.files())
        let index = try XCTUnwrap(entries.firstIndex { $0.name == Data("OPS/two.xhtml".utf8) })
        entries[index].method = 12 // bzip2
        for (name, data) in [("deflate stream", damaged), ("bzip2 method", Fixture.storedArchive(entries))] {
            XCTAssertThrowsError(try EPUBPublication.open(data: data), name) {
                guard case .invalidArchive = $0 as? EPUBPublicationError else {
                    return XCTFail("\(name): not an EPUBPublicationError.invalidArchive but \(type(of: $0)): \($0)")
                }
            }
        }
    }

    func testAChecksumThatDoesNotMatchADeflatedEntryIsRefused() throws {
        // The stream inflates soundly, so only the checksum can tell.
        let payload = String(repeating: "abcdefgh", count: 4_096)
        var data = try Fixture.epub(overrides: ["OPS/payload.txt": payload])
        let directory = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/payload.txt", in: data))
        data[directory + 16] ^= 0xFF // The directory's CRC, which is the one read.
        assertOpening(data, throws: .invalidArchive("CRC: OPS/payload.txt"))
    }

    func testAnEntryLargerThanItsDeclaredSizeCannotPassAResourceLimit() throws {
        // The directory says 10 bytes; the stream inflates to 131,072.
        var data = try Fixture.epub(overrides: ["OPS/payload.txt": String(repeating: "x", count: 131_072)])
        let directory = try XCTUnwrap(Fixture.directoryOffset(of: "OPS/payload.txt", in: data))
        data.replaceSubrange((directory + 24)..<(directory + 28), with: [10, 0, 0, 0])
        var limits = EPUBImportLimits()
        limits.resourceBytes = 40_000
        assertOpening(data, limits: limits, throws: .limitExceeded("OPS/payload.txt"), "one resource")
        limits = EPUBImportLimits()
        limits.expandedBytes = 100_000
        assertOpening(data, limits: limits, throws: .limitExceeded("OPS/payload.txt"), "the whole book")
    }

    // MARK: Limits

    func testTheDefaultLimitsAreTheDocumentedOnes() {
        // doc/architecture.md: "256 MiB compressed, 512 MiB expanded, 32 MiB per resource, 20,000
        // entries and 4 MiB per XML document".
        let limits = EPUBImportLimits()
        XCTAssertEqual([limits.archiveBytes, limits.expandedBytes, limits.resourceBytes, limits.entryCount, limits.xmlBytes],
                       [256 << 20, 512 << 20, 32 << 20, 20_000, 4 << 20])
    }

    func testEachLimitAdmitsItsExactValueAndRefusesOneLess() throws {
        let files = try Fixture.files()
        let bytes = try Fixture.archive(files)
        let largest = try XCTUnwrap(files.max { $0.value.count < $1.value.count })
        // The largest XML document the parser reads; an EPUB 3 book's NCX is read only for pages.
        let xml = try XCTUnwrap(["META-INF/container.xml", "OPS/book.opf", "OPS/nav.xhtml", "OPS/toc.ncx"]
            .max { files[$0]!.count < files[$1]!.count })
        var exact = EPUBImportLimits()
        exact.archiveBytes = bytes.count
        exact.expandedBytes = files.values.reduce(0) { $0 + $1.count }
        exact.resourceBytes = largest.value.count
        exact.entryCount = files.count
        exact.xmlBytes = files[xml]!.count
        XCTAssertEqual(try EPUBPublication.open(data: bytes, limits: exact).spine.count, 2)

        var limits = exact; limits.archiveBytes -= 1
        assertOpening(bytes, limits: limits, throws: .limitExceeded("import limits"), "archiveBytes")
        limits = exact; limits.entryCount -= 1
        assertOpening(bytes, limits: limits, throws: .limitExceeded("entry count"), "entryCount")
        limits = exact; limits.resourceBytes -= 1
        assertOpening(bytes, limits: limits, throws: .limitExceeded(largest.key), "resourceBytes")
        limits = exact; limits.xmlBytes -= 1
        assertOpening(bytes, limits: limits, throws: .limitExceeded(xml), "xmlBytes")
        limits = exact; limits.expandedBytes -= 1
        XCTAssertThrowsError(try EPUBPublication.open(data: bytes, limits: limits), "expandedBytes") {
            guard case .limitExceeded = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
        }
        for keyPath in [\EPUBImportLimits.archiveBytes, \.resourceBytes, \.expandedBytes, \.entryCount, \.xmlBytes] {
            for value in [0, -1] {
                limits = exact; limits[keyPath: keyPath] = value
                assertOpening(bytes, limits: limits, throws: .limitExceeded("import limits"), "\(keyPath) = \(value)")
            }
        }
    }

    func testOpeningAFileHonoursTheArchiveLimitAtItsBoundary() throws {
        let bytes = try Fixture.epub()
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".epub")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var limits = EPUBImportLimits()
        limits.archiveBytes = bytes.count
        XCTAssertEqual(try EPUBPublication.open(at: url, limits: limits).archiveData, bytes)
        limits.archiveBytes = bytes.count - 1
        XCTAssertThrowsError(try EPUBPublication.open(at: url, limits: limits)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("import limits"))
        }
        for value in [0, -1] {
            limits.archiveBytes = value
            XCTAssertThrowsError(try EPUBPublication.open(at: url, limits: limits)) {
                guard case .limitExceeded = $0 as? EPUBPublicationError else { return XCTFail("\(value): \($0)") }
            }
        }
    }

    // MARK: Files

    func testOpeningSomethingThatIsNoReadableEPUBFileThrows() throws {
        XCTAssertThrowsError(try EPUBPublication.open(at: XCTUnwrap(URL(string: "https://example.invalid/book.epub")))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("https://example.invalid/book.epub"))
        }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try EPUBPublication.open(at: directory.appending(path: "missing.epub")), "a missing file")
        XCTAssertThrowsError(try EPUBPublication.open(at: directory), "a directory")
        let empty = directory.appending(path: "empty.epub")
        try Data().write(to: empty)
        XCTAssertThrowsError(try EPUBPublication.open(at: empty), "an empty file") {
            guard case .invalidArchive = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Progress and cancellation

    func testProgressRisesToTheExpandedSizeOfTheBook() throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [Int] = []
            func add(_ value: Int) { lock.lock(); storage.append(value); lock.unlock() }
            var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
        }
        var files = try Fixture.files()
        files["OPS/payload.bin"] = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        files["OPS/empty.css"] = Data()
        let recorder = Recorder()
        _ = try EPUBPublication.open(data: Fixture.archive(files), onProgress: { recorder.add($0) })
        let values = recorder.values
        XCTAssertEqual(values.last, files.values.reduce(0) { $0 + $1.count })
        XCTAssertEqual(values, values.sorted(), "never falls")
        XCTAssertGreaterThan(values.count, files.count, "a large entry reports as it expands")
        XCTAssertLessThanOrEqual(zip(values, values.dropFirst()).map { $1 - $0 }.max() ?? 0, 32_768, "in bounded steps")
    }

    func testOpeningTheSameBytesFromSeveralTasksAtOnceGivesTheSameBook() async throws {
        // doc/architecture.md sends large books to a background task; nothing says only one.
        let bytes = try Fixture.epub(overrides: ["OPS/payload.txt": String(repeating: "0123456789", count: 20_000)])
        let expected = try EPUBPublication.open(data: bytes)
        try await withThrowingTaskGroup(of: EPUBPublication.self) { group in
            for _ in 0..<16 { group.addTask { try EPUBPublication.open(data: bytes) } }
            for try await book in group {
                XCTAssertEqual(book.id, expected.id)
                XCTAssertEqual(book.spine, expected.spine)
                XCTAssertEqual(book.tableOfContents, expected.tableOfContents)
                XCTAssertEqual(try book.data(at: "OPS/payload.txt"), try expected.data(at: "OPS/payload.txt"))
            }
        }
    }

    func testATaskCancelledBeforeOpeningReadsNothing() async throws {
        let bytes = try Fixture.epub()
        let task = Task.detached { () throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try EPUBPublication.open(data: bytes, onProgress: { _ in XCTFail("expanded an entry") }).spine.count
        }
        do { _ = try await task.value; XCTFail("A cancelled task opened the book") }
        catch is CancellationError {}
    }
}
