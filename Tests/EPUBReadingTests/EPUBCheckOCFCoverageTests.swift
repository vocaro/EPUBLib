import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// The container constructs EPUBCheck's OCF scenarios (`epub3/04-ocf`, `epub2/ocf-publication`)
/// check, as a reader meets them: valid ones are read, invalid ones are read past or refused
/// with an `EPUBPublicationError`.
final class EPUBCheckOCFCoverageTests: XCTestCase {
    /// A ZIP archive written byte by byte, so entries can take forms ZIPFoundation never writes.
    private struct RawZIP {
        struct Entry {
            var name: [UInt8]
            /// The bytes stored in the archive.
            var stored: Data
            var method: UInt16 = 0
            var flags: UInt16 = 0
            var crc: UInt32
            var size: UInt32
            var usesDataDescriptor = false

            init(_ name: String, _ content: Data, deflated: Bool = false, dataDescriptor: Bool = false) throws {
                self.name = Array(name.utf8)
                stored = deflated ? try (content as NSData).compressed(using: .zlib) as Data : content
                method = deflated ? 8 : 0
                // Bit 11: the name is UTF-8. Bit 3: sizes and CRC follow the data.
                flags = 0x0800 | (dataDescriptor ? 0x0008 : 0)
                crc = RawZIP.crc32(content); size = UInt32(content.count); usesDataDescriptor = dataDescriptor
            }
        }

        static func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }

        static func set(_ value: UInt32, at offset: Int, in data: inout Data) {
            for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) }
        }

        /// Whether the end record, a directory record or a data descriptor flag sends a reader
        /// past the end of the archive.
        static func namesAnOffsetPastTheEnd(_ data: Data) -> Bool {
            let bytes = [UInt8](data)
            func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
            func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
            guard bytes.count >= 22, let end = stride(from: bytes.count - 22, through: 0, by: -1)
                .first(where: { u32($0) == 0x0605_4B50 }) else { return false }
            var record = u32(end + 16)
            if record > bytes.count { return true }
            for _ in 0..<u16(end + 10) {
                guard record + 46 <= bytes.count, u32(record) == 0x0201_4B50 else { return false }
                let local = u32(record + 42)
                if local > bytes.count { return true }
                if local + 30 <= bytes.count {
                    let payload = local + 30 + u16(local + 26) + u16(local + 28)
                    // Bit 3 of either flags field: the descriptor is read after the compressed bytes.
                    if (u16(record + 8) | u16(local + 6)) & 0x0008 != 0, payload + u32(record + 20) > bytes.count { return true }
                }
                record += 46 + u16(record + 28) + u16(record + 30) + u16(record + 32)
            }
            return false
        }

        static func archive(_ entries: [Entry], comment: [UInt8] = []) -> Data {
            var data = Data(), directory = Data()
            func u16(_ value: UInt16, _ data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            func u32(_ value: UInt32, _ data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            let time: UInt32 = 0x5A21_0000 // DOS time and date
            for entry in entries {
                let offset = UInt32(data.count), packed = UInt32(entry.stored.count), name = UInt16(entry.name.count)
                u32(0x0403_4B50, &data); u16(20, &data); u16(entry.flags, &data); u16(entry.method, &data); u32(time, &data)
                u32(entry.usesDataDescriptor ? 0 : entry.crc, &data); u32(entry.usesDataDescriptor ? 0 : packed, &data)
                u32(entry.usesDataDescriptor ? 0 : entry.size, &data); u16(name, &data); u16(0, &data)
                data.append(contentsOf: entry.name); data.append(entry.stored)
                if entry.usesDataDescriptor { u32(0x0807_4B50, &data); u32(entry.crc, &data); u32(packed, &data); u32(entry.size, &data) }
                u32(0x0201_4B50, &directory); u16(20, &directory); u16(20, &directory); u16(entry.flags, &directory)
                u16(entry.method, &directory); u32(time, &directory); u32(entry.crc, &directory); u32(packed, &directory)
                u32(entry.size, &directory); u16(name, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory)
                u16(0, &directory); u32(0, &directory); u32(offset, &directory); directory.append(contentsOf: entry.name)
            }
            let start = UInt32(data.count), count = UInt16(entries.count)
            data.append(directory)
            u32(0x0605_4B50, &data); u16(0, &data); u16(0, &data); u16(count, &data); u16(count, &data)
            u32(UInt32(directory.count), &data); u32(start, &data); u16(UInt16(comment.count), &data); data.append(contentsOf: comment)
            return data
        }
    }

    /// The standard fixture's files in archive order, `mimetype` first.
    private func entries(deflated: Bool = false, dataDescriptor: Bool = false,
                         files: [String: Data]? = nil) throws -> [RawZIP.Entry] {
        let files = try files ?? Fixture.files()
        return try files.keys.sorted { a, b in a == "mimetype" || (b != "mimetype" && a < b) }.map { name in
            try RawZIP.Entry(name, files[name]!, deflated: deflated && name != "mimetype", dataDescriptor: dataDescriptor && name != "mimetype")
        }
    }

    /// The two ZIPFoundation errors `open` lets through untyped. Each has a test of its own
    /// (an unsupported compression method, a corrupt deflate stream), so the sweeps pass them over.
    private static let reportedLeaks = ["ArchiveError invalidCompressionMethod", "CompressionError corruptedData"]

    private func assertTyped(_ bytes: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try EPUBPublication.open(data: bytes) } catch {
            if Self.reportedLeaks.contains("\(type(of: error)) \(error)") { return }
            XCTAssertTrue(error is EPUBPublicationError, "\(message): \(type(of: error)) \(error)", file: file, line: line)
        }
    }

    // MARK: Valid containers

    func testAHandWrittenArchiveOfStoredEntriesIsRead() throws {
        let book = try EPUBPublication.open(data: RawZIP.archive(entries()))
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(try book.data(at: "OPS/one.xhtml"), try Fixture.files()["OPS/one.xhtml"])
    }

    func testEntriesWhoseSizesFollowTheirDataAreRead() throws {
        // What a streaming writer (java.util.zip, most converters) writes: general-purpose bit 3
        // and a data descriptor after each deflated entry.
        let book = try EPUBPublication.open(data: RawZIP.archive(entries(deflated: true, dataDescriptor: true)))
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(try book.data(at: "OPS/two.xhtml"), try Fixture.files()["OPS/two.xhtml"])
        XCTAssertEqual(book.tableOfContents.first?.title, "First Chapter")
    }

    func testAnArchiveCommentIsReadPast() throws {
        let book = try EPUBPublication.open(data: RawZIP.archive(entries(), comment: Array("Packed by a test.".utf8)))
        XCTAssertEqual(book.metadata.title, "A Test Book")
    }

    func testDirectoryEntriesAndAnEmptyDirectoryAreReadPast() throws {
        let archive = try Archive(data: Fixture.epub(), accessMode: .update)
        for name in ["OPS/", "META-INF/", "OPS/empty/"] {
            try archive.addEntry(with: name, type: .directory, uncompressedSize: Int64(0)) { _, _ in Data() }
        }
        let book = try EPUBPublication.open(data: try XCTUnwrap(archive.data))
        XCTAssertEqual(book.resources.map(\.path).sorted(), ["OPS/nav.xhtml", "OPS/one.xhtml", "OPS/toc.ncx", "OPS/two.xhtml"])
    }

    func testAPackageDocumentAtTheArchiveRootResolvesItsReferences() throws {
        var files: [String: Data] = [:]
        for (name, data) in try Fixture.files() { files[name.hasPrefix("OPS/") ? String(name.dropFirst(4)) : name] = data }
        files["META-INF/container.xml"] = Data(String(decoding: files["META-INF/container.xml"]!, as: UTF8.self)
            .replacingOccurrences(of: "OPS/book.opf", with: "book.opf").utf8)
        let book = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(book.spine.map(\.resource.path), ["one.xhtml", "two.xhtml"])
        XCTAssertEqual(book.spine.map(\.resource.href), ["one.xhtml", "two.xhtml"])
        XCTAssertEqual(book.tableOfContents.first?.href, "one.xhtml#start")
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, "two.xhtml")
        XCTAssertFalse(try book.data(for: book.spine[1].resource).isEmpty)
    }

    func testAPackageDocumentReachesSiblingDirectoriesThroughParentSegments() throws {
        let files = try Fixture.files()
        let opf = String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "href=\"one.xhtml\"", with: "href=\"../text/./one.xhtml\"")
            .replacingOccurrences(of: "href=\"two.xhtml\"", with: "href=\"../text/sub/../two.xhtml\"")
            .replacingOccurrences(of: "href=\"nav.xhtml\"", with: "href=\"../nav/nav.xhtml\"")
            .replacingOccurrences(of: "href=\"toc.ncx\"", with: "href=\"../toc.ncx\"")
        let nav = String(decoding: files["OPS/nav.xhtml"]!, as: UTF8.self)
            .replacingOccurrences(of: "href=\"one.xhtml#start\"", with: "href=\"../text/one.xhtml#start\"")
            .replacingOccurrences(of: "href=\"two.xhtml\"", with: "href=\"../text/two.xhtml\"")
        let book = try EPUBPublication.open(data: Fixture.archive([
            "mimetype": files["mimetype"]!,
            "META-INF/container.xml": Data(String(decoding: files["META-INF/container.xml"]!, as: UTF8.self)
                .replacingOccurrences(of: "OPS/book.opf", with: "OPS/package/book.opf").utf8),
            "OPS/package/book.opf": Data(opf.utf8), "OPS/nav/nav.xhtml": Data(nav.utf8), "OPS/toc.ncx": files["OPS/toc.ncx"]!,
            "OPS/text/one.xhtml": files["OPS/one.xhtml"]!, "OPS/text/two.xhtml": files["OPS/two.xhtml"]!,
        ]))
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/text/one.xhtml", "OPS/text/two.xhtml"])
        XCTAssertEqual(book.tableOfContents.first?.href, "OPS/text/one.xhtml#start")
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, "OPS/text/two.xhtml")
    }

    func testTheFirstRootfileIsThePackageDocument() throws {
        // A multiple-rendition container. EPUB Reading Systems 3.3, 4.2: a reading system "MUST,
        // by default, use the package document referenced from the first rootfile element".
        let container = """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles>\
            <rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/>\
            <rootfile full-path="ALT/other.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """
        let other = String(decoding: try Fixture.files()["OPS/book.opf"]!, as: UTF8.self).replacingOccurrences(of: "A Test Book", with: "Another Rendition")
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: [
            "META-INF/container.xml": container, "ALT/other.opf": other, "ALT/one.xhtml": "<html/>", "ALT/two.xhtml": "<html/>",
            "ALT/nav.xhtml": String(decoding: try Fixture.files()["OPS/nav.xhtml"]!, as: UTF8.self), "ALT/toc.ncx": "<ncx/>",
        ]))
        XCTAssertEqual(book.metadata.title, "A Test Book")
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
    }

    func testAnEntryNameAndAnHrefInDifferentNormalizationFormsNameOneResource() throws {
        // An archive packed on a file system that decomposes names, referenced by a composed href.
        var files = try Fixture.files()
        files["OPS/cafe\u{301}.xhtml"] = files.removeValue(forKey: "OPS/one.xhtml")
        files["OPS/book.opf"] = Data(String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "href=\"one.xhtml\"", with: "href=\"caf%C3%A9.xhtml\"").utf8)
        files["OPS/nav.xhtml"] = Data(String(decoding: files["OPS/nav.xhtml"]!, as: UTF8.self)
            .replacingOccurrences(of: "one.xhtml#start", with: "caf\u{E9}.xhtml#start").utf8)
        let book = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(book.spine.count, 2)
        XCTAssertTrue(String(decoding: try book.data(for: book.spine[0].resource), as: UTF8.self).contains("Opening words"))
        XCTAssertEqual(book.tableOfContents.first?.href, "OPS/caf%C3%A9.xhtml#start")
    }

    func testFilesThePackageDoesNotDescribeAreReadPast() throws {
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: [
            "META-INF/metadata.xml": "<metadata xmlns=\"http://www.idpf.org/2013/metadata\"/>",
            "META-INF/manifest.xml": "<manifest/>", "META-INF/signatures.xml": "<signatures xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"/>",
            "META-INF/com.apple.ibooks.display-options.xml": "<display_options><platform name=\"*\"><option name=\"specified-fonts\">true</option></platform></display_options>",
            "iTunesMetadata.plist": "<plist/>", "OPS/unlisted.txt": "Not in the manifest.", "OPS/.hidden": "",
        ]))
        XCTAssertEqual(book.resources.map(\.path).sorted(), ["OPS/nav.xhtml", "OPS/one.xhtml", "OPS/toc.ncx", "OPS/two.xhtml"])
        XCTAssertEqual(try book.data(at: "OPS/unlisted.txt"), Data("Not in the manifest.".utf8), "an archive path still reads")
    }

    // MARK: Invalid containers, read past

    func testAMimetypeEntryThatIsCompressedAndLastIsReadPast() throws {
        // PKG-005/PKG-007 territory: hand-zipped books put `mimetype` anywhere and deflate it.
        let files = try Fixture.files()
        let ordered = try files.keys.sorted { a, b in b == "mimetype" || (a != "mimetype" && a < b) }.map {
            try RawZIP.Entry($0, files[$0]!, deflated: true)
        }
        XCTAssertEqual(String(decoding: ordered.last!.name, as: UTF8.self), "mimetype")
        let book = try EPUBPublication.open(data: RawZIP.archive(ordered))
        XCTAssertEqual(book.spine.count, 2)
    }

    // MARK: Invalid containers, refused

    func testAMimetypeWithPaddingIsRefusedAsDocumented() throws {
        for content in ["application/epub+zip\n", "application/epub+zip ", " application/epub+zip", "\u{FEFF}application/epub+zip",
                        "application/epub+zip\r\n", "application/x-epub+zip", ""] {
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["mimetype": content])), content.debugDescription) {
                XCTAssertEqual($0 as? EPUBPublicationError, .invalidArchive("Missing EPUB mimetype"), content.debugDescription)
            }
        }
    }

    func testAContainerWithoutAUsableRootfileIsATypedRefusal() throws {
        let head = "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\">"
        for container in [head + "<rootfiles/></container>", head + "<rootfiles><rootfile media-type=\"application/oebps-package+xml\"/></rootfiles></container>",
                          head + "<rootfiles><rootfile full-path=\"\"/></rootfiles></container>", head + "</container>"] {
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["META-INF/container.xml": container])), container) {
                XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("container rootfile"), container)
            }
        }
        var files = try Fixture.files()
        files["META-INF/container.xml"] = nil
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("META-INF/container.xml"))
        }
    }

    func testAMissingPackageDocumentIsATypedMissingResource() throws {
        var files = try Fixture.files()
        files["OPS/book.opf"] = nil
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("OPS/book.opf"))
        }
    }

    func testAnEntryWithACompressionMethodOtherThanStoredOrDeflatedIsATypedRefusal() throws {
        // OCF allows only methods 0 and 8; method 12 is bzip2 and 93 is Zstandard.
        for method: UInt16 in [1, 9, 12, 14, 93, 99] {
            var all = try entries()
            let index = try XCTUnwrap(all.firstIndex { String(decoding: $0.name, as: UTF8.self) == "OPS/two.xhtml" })
            all[index].method = method
            let bytes = RawZIP.archive(all)
            XCTAssertThrowsError(try EPUBPublication.open(data: bytes), "method \(method)") {
                XCTAssertTrue($0 is EPUBPublicationError, "method \(method): \(type(of: $0)) \($0)")
            }
        }
    }

    func testACorruptDeflateStreamIsATypedRefusal() throws {
        var all = try entries(deflated: true)
        let index = try XCTUnwrap(all.firstIndex { String(decoding: $0.name, as: UTF8.self) == "OPS/two.xhtml" })
        // Block type 3 is reserved: no inflater accepts it.
        all[index].stored = Data(repeating: 0xFF, count: 64)
        XCTAssertThrowsError(try EPUBPublication.open(data: RawZIP.archive(all))) {
            XCTAssertTrue($0 is EPUBPublicationError, "\(type(of: $0)) \($0)")
        }
    }

    func testADeflatedEntryThatInflatesToOtherBytesFailsItsChecksum() throws {
        var all = try entries(deflated: true)
        let index = try XCTUnwrap(all.firstIndex { String(decoding: $0.name, as: UTF8.self) == "OPS/two.xhtml" })
        let other = Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Swapped.</p></body></html>".utf8)
        all[index].stored = try (other as NSData).compressed(using: .zlib) as Data
        all[index].size = UInt32(other.count)
        XCTAssertThrowsError(try EPUBPublication.open(data: RawZIP.archive(all))) {
            guard case .invalidArchive(let reason) = $0 as? EPUBPublicationError else { return XCTFail("\(type(of: $0)) \($0)") }
            XCTAssertTrue(reason.contains("CRC"), reason)
        }
    }

    func testEveryTruncationOfAnArchiveIsRefusedWithATypedError() throws {
        let bytes = try RawZIP.archive(entries(files: smallBook()))
        XCTAssertNoThrow(try EPUBPublication.open(data: bytes))
        for length in 0..<bytes.count {
            XCTAssertThrowsError(try EPUBPublication.open(data: bytes.prefix(length)), "\(length) of \(bytes.count) bytes") {
                XCTAssertTrue($0 is EPUBPublicationError, "\(length) of \(bytes.count) bytes: \(type(of: $0)) \($0)")
            }
        }
    }

    // Disabled: each of these three traps the process instead of throwing. ZIPFoundation's
    // in-memory file (Archive+MemoryFile.swift, `readData`) forms the range
    // `offset..<offset + min(count, data.count - offset)`, whose upper bound is below its lower
    // bound once the archive has sought past its end, and `EPUBPublication.open(data:)` (which
    // `open(at:)` also calls) reaches it for any offset an archive's own directory names:
    // "Fatal error: Range requires lowerBound <= upperBound". Rename to `test…` to reproduce.

    func disabled_testALocalHeaderOffsetPastTheEndOfTheArchiveIsATypedRefusal() throws {
        var bytes = try RawZIP.archive(entries(files: smallBook()))
        let record = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        RawZIP.set(UInt32(bytes.count + 1), at: record + 42, in: &bytes)
        XCTAssertThrowsError(try EPUBPublication.open(data: bytes)) { XCTAssertTrue($0 is EPUBPublicationError, "\(type(of: $0)) \($0)") }
    }

    func disabled_testACentralDirectoryOffsetPastTheEndOfTheArchiveIsATypedRefusal() throws {
        var bytes = try RawZIP.archive(entries(files: smallBook()))
        RawZIP.set(UInt32(bytes.count + 1), at: bytes.count - 22 + 16, in: &bytes)
        XCTAssertThrowsError(try EPUBPublication.open(data: bytes)) { XCTAssertTrue($0 is EPUBPublicationError, "\(type(of: $0)) \($0)") }
    }

    func disabled_testADataDescriptorPastTheEndOfTheArchiveIsATypedRefusal() throws {
        var bytes = try RawZIP.archive(entries(deflated: true, dataDescriptor: true, files: smallBook()))
        // The second record's compressed size: its data descriptor is sought after that many bytes.
        let first = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        let record = try XCTUnwrap(bytes[(first + 4)...].range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        RawZIP.set(0x7FFF_0000, at: record + 20, in: &bytes)
        XCTAssertThrowsError(try EPUBPublication.open(data: bytes)) { XCTAssertTrue($0 is EPUBPublicationError, "\(type(of: $0)) \($0)") }
    }

    /// Damages every byte of `range` three ways. An archive whose directory then names an offset
    /// past its end is left out: those trap (the disabled tests above) and would end the run.
    private func sweep(_ bytes: Data, _ range: Range<Int>, _ part: String, file: StaticString = #filePath, line: UInt = #line) {
        var skipped = 0
        for index in range {
            for mask: UInt8 in [0xFF, 0x01, 0x80] {
                var damaged = bytes
                damaged[index] ^= mask
                if RawZIP.namesAnOffsetPastTheEnd(damaged) { skipped += 1; continue }
                assertTyped(damaged, "byte \(index - range.lowerBound) of \(part), mask \(mask)", file: file, line: line)
            }
        }
        print("EPUBCheck OCF sweep of \(part): \(range.count * 3 - skipped) damaged archives opened or refused, \(skipped) left out as trapping")
    }

    func testEveryDamagedByteOfTheArchiveDirectoryIsOpenedOrRefusedWithATypedError() throws {
        for deflated in [false, true] {
            let bytes = try RawZIP.archive(entries(deflated: deflated, files: smallBook()))
            let directory = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
            sweep(bytes, directory..<bytes.count, deflated ? "the directory of deflated entries" : "the directory of stored entries")
        }
    }

    func testEveryDamagedByteOfALocalHeaderIsOpenedOrRefusedWithATypedError() throws {
        for (deflated, descriptor) in [(false, false), (true, false), (true, true)] {
            let bytes = try RawZIP.archive(entries(deflated: deflated, dataDescriptor: descriptor, files: smallBook()))
            // The second entry's local header: signature to the end of its name.
            let second = try XCTUnwrap(bytes.dropFirst(4).range(of: Data([0x50, 0x4B, 0x03, 0x04]))).lowerBound
            sweep(bytes, second..<(second + 30 + "META-INF/container.xml".utf8.count),
                  "a local header (\(deflated ? "deflated" : "stored")\(descriptor ? ", data descriptor" : ""))")
        }
    }

    /// A book of a few short files, so byte-level sweeps stay quick.
    private func smallBook() throws -> [String: Data] {
        let page = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><p>Text.</p></body></html>"
        return [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"b.opf\"/></rootfiles></container>".utf8),
            "b.opf": Data("""
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="u"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
                <dc:title>T</dc:title><dc:language>en</dc:language><dc:identifier id="u">small</dc:identifier></metadata><manifest>\
                <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="n" href="n.xhtml" media-type="application/xhtml+xml" properties="nav"/>\
                </manifest><spine><itemref idref="a"/></spine></package>
                """.utf8),
            "a.xhtml": Data(page.utf8),
            "n.xhtml": Data("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"a.xhtml\">A</a></li></ol></nav></body></html>".utf8),
        ]
    }

    // MARK: Encryption and obfuscation

    private func encryption(_ algorithm: String, uri: String) -> String {
        """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">\
        <enc:EncryptedData><enc:EncryptionMethod Algorithm="\(algorithm)"/><enc:CipherData><enc:CipherReference URI="\(uri)"/></enc:CipherData>\
        </enc:EncryptedData></encryption>
        """
    }

    private func obfuscated(_ font: Data, identifier: String, prefix: Int = 1040) -> Data {
        let key = Array(Insecure.SHA1.hash(data: Data(identifier.utf8)))
        var bytes = font
        for index in 0..<min(prefix, bytes.count) { bytes[bytes.startIndex + index] ^= key[index % key.count] }
        return bytes
    }

    func testAnObfuscatedFontNamedByAnEncodedURIIsDecoded() throws {
        let font = Data((0..<2_000).map { UInt8($0 % 253) })
        var files = try Fixture.files()
        files["OPS/fonts/My Font é.otf"] = obfuscated(font, identifier: "test-book")
        files["META-INF/encryption.xml"] = Data(encryption("http://www.idpf.org/2008/embedding", uri: "OPS/fonts/My%20Font%20%C3%A9.otf").utf8)
        let book = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(try book.data(at: "OPS/fonts/My Font é.otf"), font)
    }

    func testAnObfuscatedFontShorterThanTheObfuscatedPrefixIsDecodedWhole() throws {
        let font = Data((0..<100).map { UInt8(200 - $0) })
        var files = try Fixture.files()
        files["OPS/tiny.woff"] = obfuscated(font, identifier: "test-book")
        files["META-INF/encryption.xml"] = Data(encryption("http://www.idpf.org/2008/embedding", uri: "OPS/tiny.woff").utf8)
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).data(at: "OPS/tiny.woff"), font)
    }

    func testTheObfuscationKeyLeavesOutWhitespaceInTheUniqueIdentifier() throws {
        // EPUB 3.3, 4.4.3: "All whitespace characters ... MUST be removed from this identifier —
        // specifically, the Unicode code points U+0020, U+0009, U+000D and U+000A."
        let font = Data((0..<1_500).map { UInt8($0 % 251) })
        var files = try Fixture.files()
        files["OPS/book.opf"] = Data(String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: ">test-book<", with: ">\n  urn:uuid: 5f0c 9a3e\t-\r\n 77aa \n<").utf8)
        files["OPS/font.ttf"] = obfuscated(font, identifier: "urn:uuid:5f0c9a3e-77aa")
        files["META-INF/encryption.xml"] = Data(encryption("http://www.idpf.org/2008/embedding", uri: "OPS/font.ttf").utf8)
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).data(at: "OPS/font.ttf"), font)
    }

    func testAnUnknownEncryptionAlgorithmIsRefusedAsDocumented() throws {
        for algorithm in ["http://www.w3.org/2001/04/xmlenc#aes256-cbc", "http://example.org/unknown", ""] {
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: [
                "META-INF/encryption.xml": encryption(algorithm, uri: "OPS/one.xhtml"),
            ])), algorithm) { XCTAssertEqual($0 as? EPUBPublicationError, .unsupportedEncryption, algorithm) }
        }
    }
}
