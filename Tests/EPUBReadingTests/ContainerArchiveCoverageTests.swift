import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBText
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
        // The same layout holding one empty file, which Python's zipfile and Info-ZIP's unzip read
        // as empty. Its sizes are 0xFFFFFFFF in the headers and zero in the ZIP64 field.
        var files = try Fixture.files()
        files["OPS/empty.css"] = Data()
        let data = Fixture.storedArchive(Fixture.storedEntries(files), zip64: .sizes)
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/empty.css"), Data())
    }

    func testAZIP64ArchiveWithItsOffsetsInExtraFieldsIsRead() throws {
        // EPUB Reading Systems 3.3 §4.2: a reader must "support the ZIP64 extensions". Every
        // entry's header offset is 0xFFFFFFFF in the directory with the real offset in its ZIP64
        // extra field, as a writer told always to use ZIP64 writes; Python's zipfile and
        // Info-ZIP's unzip read it. The first entry's real offset is zero.
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

    func testAnEntryNameWithAColonIsReadLikeTheOtherCharactersOCFForbids() throws {
        // OCF forbids `" * : < > ? \ |` in file names for whoever writes a book (EPUB 3.3, File
        // paths and file names). The snapshot is looked up by key, so a reader has nothing to
        // fear from any of them but `\`.
        let chapter = Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Named with a colon.</p></body></html>".utf8)
        let data = try Fixture.packageVariant(
            opf: { $0.replacingOccurrences(of: "href=\"two.xhtml\"", with: "href=\"Chapter%202%3A%20On.xhtml\"") },
            nav: { $0.replacingOccurrences(of: "href=\"two.xhtml\"", with: "href=\"./Chapter%202:%20On.xhtml\"") },
            adding: ["OPS/Chapter 2: On.xhtml": chapter, "OPS/notes: \"draft\" <1>?*|.txt": Data("kept".utf8), "a:b/c:d.txt": Data("kept".utf8)])
        let book = try EPUBPublication.open(data: data)
        XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/Chapter 2: On.xhtml"])
        XCTAssertEqual(book.spine[1].resource.href, "OPS/Chapter%202%3A%20On.xhtml")
        XCTAssertEqual(try book.data(for: book.spine[1].resource), chapter)
        XCTAssertEqual(book.tableOfContents.first?.children.first?.href, book.spine[1].resource.href)
        XCTAssertEqual(try book.data(at: "OPS/notes: \"draft\" <1>?*|.txt"), Data("kept".utf8))
        XCTAssertEqual(try book.data(at: "a:b/c:d.txt"), Data("kept".utf8))
        assertOpening(try Fixture.packageVariant(adding: ["OPS/a:\\b.txt": Data()]), throws: .unsafePath("OPS/a:\\b.txt"), "a backslash is still refused")
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

    // A `Character` holds a "/", "\", ":" or "." together with a combining mark, variation
    // selector or joiner after it, so read that way "../" + U+0301 + "x" is one harmless name. An
    // archive and a file system read bytes (https://github.com/vocaro/EPUBLib/issues/181).
    func testAnEntryNameIsCheckedWhateverMarkFollowsItsSeparatorsAndDots() throws {
        let entries = Fixture.storedEntries(try Fixture.files())
        for m in Fixture.clusteringMarks {
            for name in ["../\(m)x", "OPS/../\(m)x", "OPS/../../\(m)x", "./\(m)x", "OPS/./\(m)x", "/\(m)x", "OPS//\(m)x", "OPS\\\(m)x", "..\\\(m)x"] {
                assertOpening(Fixture.storedArchive(entries + [Fixture.StoredEntry(name, "x")]), throws: .unsafePath(name), name.debugDescription)
            }
        }
        // A prepended mark takes the separator after it into its `Character`. The last is a
        // file's name to ZIPFoundation, which looks for a closing "/" by `Character`.
        for name in ["OPS/x\u{600}/..", "OPS\u{600}/../x", "OPS/x\u{600}/./y", "OPS/x\u{600}//y", "OPS/x\u{600}\\y", "OPS/x\u{600}/"] {
            assertOpening(Fixture.storedArchive(entries + [Fixture.StoredEntry(name, "x")]), throws: .unsafePath(name), name.debugDescription)
        }
        // A colon is a character of a name that is read, beside a mark as anywhere else
        // (https://github.com/vocaro/EPUBLib/issues/171). Each such entry answers to its own name.
        let colons = Fixture.clusteringMarks.flatMap { ["OPS/a:\($0)x", "C:\($0)/x"] } + ["OPS/x\u{600}:y"]
        let book = try EPUBPublication.open(data: Fixture.storedArchive(entries + colons.map { Fixture.StoredEntry($0, $0) }))
        for name in colons { XCTAssertEqual(try book.data(at: name), Data(name.utf8), name.debugDescription) }
    }

    func testAnEntryWhoseNameBeginsWithAMarkIsAFileOfThatNameInItsFolder() throws {
        // By its bytes "OPS/" + U+0301 + "x.css" is a file in OPS: not OPS/x.css, nor x.css in a
        // folder named "OPS" + U+0301. Dots and a mark are a name. Each answers to its own name.
        for m in Fixture.clusteringMarks {
            let names = ["OPS/\(m)x.css", "OPS/x.css", "OPS\(m)/x.css", "\(m)x.css", "OPS/.\(m)", "OPS/..\(m)", "OPS/\(m)/\(m)"]
            var entries = Fixture.storedEntries(try Fixture.files())
            // Folders, told by a closing slash and by a Unix mode.
            entries.append(Fixture.StoredEntry("OPS/\(m)a/"))
            entries.append(Fixture.StoredEntry("OPS/\(m)b/", versionMadeBy: 3 << 8 | 20, externalAttributes: 0o040755 << 16))
            entries.append(Fixture.StoredEntry("OPS/c\u{600}/", versionMadeBy: 3 << 8 | 20, externalAttributes: 0o040755 << 16))
            entries += names.map { Fixture.StoredEntry($0, $0) }
            let book = try EPUBPublication.open(data: Fixture.storedArchive(entries))
            for name in names { XCTAssertEqual(try book.data(at: name), Data(name.utf8), name.debugDescription) }
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"])
            XCTAssertThrowsError(try book.data(at: "OPS/\(m)a/"))
        }
    }

    // MARK: Entry names and the language-encoding flag

    // A name that is well-formed UTF-8 is read as UTF-8 whether or not general-purpose bit 11
    // says so; any other name is read as before: code page 437 without the bit, refused with it.

    /// A stored entry named by `bytes` as they are, valid in an encoding or in none.
    private func entry(named bytes: [UInt8], _ text: String = "", flags: UInt16) -> Fixture.StoredEntry {
        var entry = Fixture.StoredEntry("", text, flags: flags)
        entry.name = Data(bytes)
        return entry
    }

    /// The plain book with `entries` after its own.
    private func book(adding entries: [Fixture.StoredEntry]) throws -> Data {
        Fixture.storedArchive(Fixture.storedEntries(try Fixture.files()) + entries)
    }

    func testNamesInSeveralScriptsAreReadAlikeWithAndWithoutTheFlag() throws {
        // Accented Latin precomposed and decomposed, CJK, Cyrillic, an emoji beyond the BMP, one
        // joined from three by zero-width joiners, and Greek, punctuation and Hebrew with spaces.
        let names = ["caf\u{E9}", "re\u{301}sume\u{301}", "\u{65E5}\u{672C}\u{8A9E}", "\u{433}\u{43B}\u{430}\u{432}\u{430}",
                     "\u{1F600}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{3B1} \u{2013} \u{5D0}\u{5D1}"]
        let items = names.enumerated().map { index, name in
            "<item id=\"n\(index)\" href=\"\(name.utf8.map { String(format: "%%%02X", $0) }.joined()).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }
        var files = try Fixture.packageVariantFiles(opf: {
            $0.replacingOccurrences(of: "</manifest>", with: items.joined() + "</manifest>")
                .replacingOccurrences(of: "</spine>", with: names.indices.map { "<itemref idref=\"n\($0)\"/>" }.joined() + "</spine>")
        })
        for name in names {
            files["OPS/\(name).xhtml"] = Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(name)</title></head><body><p>\(name)</p></body></html>".utf8)
        }
        let flagged = try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files)))
        XCTAssertEqual(flagged.spine.dropFirst(2).map(\.resource.path), names.map { "OPS/\($0).xhtml" })
        // zip on a Mac leaves every flag clear; ditto sets bit 3 alone, for its data descriptors.
        for flags: UInt16 in [0, 0x0008] {
            let book = try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files, flags: flags)))
            XCTAssertEqual(book.resources, flagged.resources, "flags \(flags)")
            XCTAssertEqual(book.spine, flagged.spine, "flags \(flags)")
            XCTAssertEqual(book.resources.map { Array($0.path.utf8) }, flagged.resources.map { Array($0.path.utf8) }, "flags \(flags)")
            for (path, bytes) in files { XCTAssertEqual(try book.data(at: path), bytes, "\(path), flags \(flags)") }
            for index in book.spine.indices {
                XCTAssertEqual(try book.textSection(at: index), try flagged.textSection(at: index), "section \(index), flags \(flags)")
            }
            XCTAssertEqual(try book.textSection(at: 2).text, names[0], "flags \(flags)")
        }
    }

    func testWithoutTheFlagTheNormalizationFormsOfANameAreOnePath() throws {
        // As with the flag: a decomposed entry answers to a precomposed href and the reverse, and
        // the paths and hrefs the book gives are spelled the same, byte for byte, either way.
        let decomposed = "OPS/cafe\u{301}.xhtml", precomposed = "OPS/caf\u{E9}.xhtml"
        for (name, href) in [(decomposed, "caf%C3%A9.xhtml"), (precomposed, "cafe%CC%81.xhtml")] {
            var files = try Fixture.packageVariantFiles(
                opf: { $0.replacingOccurrences(of: "href=\"one.xhtml\"", with: "href=\"\(href)\"") },
                nav: { $0.replacingOccurrences(of: "one.xhtml#start", with: "\(href)#start") })
            let chapter = try XCTUnwrap(files.removeValue(forKey: "OPS/one.xhtml"))
            func open(flags: UInt16) throws -> EPUBPublication {
                try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files, flags: flags) + [Fixture.StoredEntry(name, chapter, flags: flags)]))
            }
            let book = try open(flags: 0), flagged = try open(flags: 0x0800)
            XCTAssertEqual(book.spine.count, 2, name)
            XCTAssertEqual(try book.data(for: book.spine[0].resource), chapter, name)
            XCTAssertEqual(try book.data(at: decomposed), chapter, name)
            XCTAssertEqual(try book.data(at: precomposed), chapter, name)
            XCTAssertEqual(Array(book.spine[0].resource.path.utf8), Array(flagged.spine[0].resource.path.utf8), name)
            XCTAssertEqual(book.tableOfContents, flagged.tableOfContents, name)
        }
    }

    func testEveryCollisionOfNamesAsTheyAreReadIsADuplicate() throws {
        func assertDuplicates(_ first: Fixture.StoredEntry, _ second: Fixture.StoredEntry, _ message: String, line: UInt = #line) {
            for entries in [[first, second], [second, first]] {
                XCTAssertThrowsError(try EPUBPublication.open(data: book(adding: entries)), message, line: line) {
                    guard case .invalidArchive(let reason) = $0 as? EPUBPublicationError else { return XCTFail("\(message): \($0)", line: line) }
                    XCTAssertTrue(reason.contains("Duplicate"), "\(message): \(reason)", line: line)
                }
            }
        }
        let precomposed = Array("OPS/caf\u{E9}.css".utf8), decomposed = Array("OPS/cafe\u{301}.css".utf8)
        assertDuplicates(entry(named: precomposed, flags: 0), entry(named: precomposed, flags: 0x0800), "the same bytes with and without the flag")
        assertDuplicates(entry(named: precomposed, flags: 0), entry(named: decomposed, flags: 0), "both forms without the flag")
        assertDuplicates(entry(named: precomposed, flags: 0x0800), entry(named: decomposed, flags: 0), "one form with the flag, the other without")
        // Code page 437 has é at 0x82, which is not UTF-8 by itself: two spellings of one name.
        let legacy = Array("OPS/caf".utf8) + [0x82] + Array(".css".utf8)
        assertDuplicates(entry(named: precomposed, flags: 0), entry(named: legacy, flags: 0), "UTF-8 and code page 437 bytes of one name")
        assertDuplicates(entry(named: decomposed, flags: 0x0800), entry(named: legacy, flags: 0), "decomposed UTF-8 and code page 437 bytes of one name")

        // The reverse: a name flagged as UTF-8 that spells out what the other's bytes are in code
        // page 437. The two were one path while the second was read so, and are two files.
        let misread = "OPS/caf\u{251C}\u{2310}.css"
        let two = try EPUBPublication.open(data: book(adding: [Fixture.StoredEntry(misread, "a{}"), entry(named: precomposed, "b{}", flags: 0)]))
        XCTAssertEqual(try two.data(at: misread), Data("a{}".utf8))
        XCTAssertEqual(try two.data(at: "OPS/caf\u{E9}.css"), Data("b{}".utf8))
    }

    func testANameThatIsNotUTF8IsReadAsCodePage437WithoutTheFlagAndRefusedWithIt() throws {
        // A book whose chapter a DOS-era tool named: é is the single byte 0x82.
        var files = try Fixture.packageVariantFiles(opf: { $0.replacingOccurrences(of: "href=\"one.xhtml\"", with: "href=\"caf%C3%A9.xhtml\"") })
        let chapter = try XCTUnwrap(files.removeValue(forKey: "OPS/one.xhtml"))
        let legacy = entry(named: Array("OPS/caf".utf8) + [0x82] + Array(".xhtml".utf8), String(decoding: chapter, as: UTF8.self), flags: 0)
        let book = try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files, flags: 0) + [legacy]))
        XCTAssertEqual(book.spine.first?.resource.path, "OPS/caf\u{E9}.xhtml")
        XCTAssertEqual(try book.data(at: "OPS/caf\u{E9}.xhtml"), chapter)

        // Each way bytes fail to be UTF-8, and what code page 437 makes of them. One such byte
        // decides for the whole name: the well-formed é before the last is read as ├⌐ with it.
        let malformed: [(String, [UInt8], String)] = [
            ("a continuation byte alone", [0x82], "\u{E9}"),
            ("a lead byte with nothing after it", [0xC3], "\u{251C}"),
            ("a sequence cut short", [0xE4, 0xB8], "\u{3A3}\u{2555}"),
            ("an overlong form", [0xC0, 0xAF], "\u{2514}\u{BB}"),
            ("a surrogate", [0xED, 0xA0, 0x80], "\u{3C6}\u{E1}\u{C7}"),
            ("a value past U+10FFFF", [0xF4, 0x90, 0x80, 0x80], "\u{2320}\u{C9}\u{C7}\u{C7}"),
            ("a byte UTF-8 never uses", [0xFF], "\u{A0}"),
            ("a well-formed sequence before a byte that is not", [0xC3, 0xA9, 0x82], "\u{251C}\u{2310}\u{E9}"),
        ]
        for (form, bytes, reading) in malformed {
            let name = Array("OPS/x".utf8) + bytes + Array(".css".utf8)
            let book = try EPUBPublication.open(data: self.book(adding: [entry(named: name, "a{}", flags: 0)]))
            XCTAssertEqual(try book.data(at: "OPS/x\(reading).css"), Data("a{}".utf8), form)
            XCTAssertThrowsError(try EPUBPublication.open(data: self.book(adding: [entry(named: name, "a{}", flags: 0x0800)])), form) {
                guard case .unsafePath = $0 as? EPUBPublicationError else { return XCTFail("\(form): \($0)") }
            }
        }
    }

    func testBytesThatAreBothUTF8AndCodePage437AreReadAsUTF8() throws {
        // Well-formed UTF-8 is also some string of code page 437, whose every byte is a
        // character: box-drawing characters, Greek letters and mathematical signs where UTF-8
        // has its lead bytes. A manifest may name either reading; the entry is the UTF-8 one.
        let readings: [([UInt8], String, String)] = [
            ([0xC3, 0xA9], "\u{E9}", "\u{251C}\u{2310}"),
            ([0xCE, 0xB1], "\u{3B1}", "\u{256C}\u{2592}"),
            ([0xE2, 0x82, 0xAC], "\u{20AC}", "\u{393}\u{E9}\u{BC}"),
            ([0xF0, 0x9F, 0x98, 0x80], "\u{1F600}", "\u{2261}\u{192}\u{FF}\u{C7}"),
        ]
        for (bytes, utf8, codePage437) in readings {
            XCTAssertEqual(Array(utf8.utf8), bytes)
            func item(_ id: String, _ name: String) -> String {
                "<item id=\"\(id)\" href=\"\(name.utf8.map { String(format: "%%%02X", $0) }.joined()).css\" media-type=\"text/css\"/>"
            }
            let files = try Fixture.packageVariantFiles(opf: {
                $0.replacingOccurrences(of: "</manifest>", with: item("utf8", utf8) + item("cp437", codePage437) + "</manifest>")
            })
            let name = Array("OPS/".utf8) + bytes + Array(".css".utf8)
            let book = try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files, flags: 0) + [entry(named: name, "a{}", flags: 0)]))
            XCTAssertEqual(book.resources.first { $0.id == "utf8" }?.path, "OPS/\(utf8).css", utf8)
            XCTAssertNil(book.resources.first { $0.id == "cp437" }, utf8)
            XCTAssertEqual(try book.data(at: "OPS/\(utf8).css"), Data("a{}".utf8), utf8)
            XCTAssertThrowsError(try book.data(at: "OPS/\(codePage437).css"), utf8) {
                XCTAssertEqual($0 as? EPUBPublicationError, .missingResource("OPS/\(codePage437).css"))
            }
        }
    }

    func testAnUnsafeNameIsRefusedAsItIsReadWithAndWithoutTheFlag() throws {
        // The refusal names the path that was judged: the UTF-8 one, which is what would have
        // become the entry's key.
        for name in ["OPS/caf\u{E9}/../x.css", "../caf\u{E9}.css", "OPS/caf\u{E9}/..", "OPS/./caf\u{E9}.css", "OPS//caf\u{E9}.css",
                     "/caf\u{E9}.css", "OPS/caf\u{E9}\\x.css", "OPS/caf\u{E9}\0.css", "OPS/\u{65E5}\u{672C}/../../x"] {
            for flags: UInt16 in [0, 0x0800] {
                assertOpening(try book(adding: [Fixture.StoredEntry(name, "a{}", flags: flags)]), throws: .unsafePath(name),
                              "\(name.debugDescription), flags \(flags)")
            }
        }
        // A colon is a character of a name, read alike either way.
        for flags: UInt16 in [0, 0x0800] {
            let book = try EPUBPublication.open(data: book(adding: [Fixture.StoredEntry("C:caf\u{E9}.css", "a{}", flags: flags)]))
            XCTAssertEqual(try book.data(at: "C:caf\u{E9}.css"), Data("a{}".utf8), "flags \(flags)")
        }
        // Whatever is made of a name, the flag does not change it. These put a combining mark
        // after a separator, a dot, a backslash and a colon, where it joins them in one character.
        func outcome(_ name: String, flags: UInt16) -> String {
            do { return try EPUBPublication.open(data: book(adding: [Fixture.StoredEntry(name, "a{}", flags: flags)])).data(at: name).count.description }
            catch { return String(describing: error) }
        }
        for name in ["OPS/a/\u{301}../x.css", "OPS/..\u{301}/x.css", "OPS/.\u{301}/x.css", "OPS/a\\\u{301}x.css", "OPS/a:\u{301}x.css", "OPS/a/\u{301}"] {
            XCTAssertEqual(outcome(name, flags: 0), outcome(name, flags: 0x0800), name.debugDescription)
        }
    }

    func testANameWithAMarkBesideASeparatorIsCheckedWithAndWithoutTheFlag() throws {
        // The two rules together. A name without the flag is read as UTF-8, so it can hold a mark
        // beside a separator as a flagged one can, and either is checked by its bytes
        // (https://github.com/vocaro/EPUBLib/issues/181). CC 81 is U+0301, which joins the
        // character before it; D8 80 is U+0600, which joins the one after.
        let refused: [(String, [UInt8])] = [
            ("OPS/../\u{301}x.css", Array("OPS/../".utf8) + [0xCC, 0x81] + Array("x.css".utf8)),
            ("OPS/a\u{600}/../x.css", Array("OPS/a".utf8) + [0xD8, 0x80] + Array("/../x.css".utf8)),
            ("OPS/a\\\u{301}x.css", Array("OPS/a\\".utf8) + [0xCC, 0x81] + Array("x.css".utf8)),
        ]
        // A mark that opens a name after a real separator hides nothing: the first is a file in
        // OPS. A colon is a character of a name that is read, before a mark as anywhere else
        // (https://github.com/vocaro/EPUBLib/issues/171).
        let kept: [(String, [UInt8])] = [
            ("OPS/\u{301}x.css", Array("OPS/".utf8) + [0xCC, 0x81] + Array("x.css".utf8)),
            ("OPS/a:\u{301}x.css", Array("OPS/a:".utf8) + [0xCC, 0x81] + Array("x.css".utf8)),
        ]
        for flags: UInt16 in [0, 0x0800] {
            for (name, bytes) in refused {
                XCTAssertEqual(Array(name.utf8), bytes, name.debugDescription)
                assertOpening(try book(adding: [entry(named: bytes, "a{}", flags: flags)]), throws: .unsafePath(name),
                              "\(name.debugDescription), flags \(flags)")
            }
            let book = try EPUBPublication.open(data: self.book(adding: kept.map { entry(named: $0.1, $0.0, flags: flags) }))
            for (name, bytes) in kept {
                XCTAssertEqual(Array(name.utf8), bytes, name.debugDescription)
                XCTAssertEqual(try book.data(at: name), Data(name.utf8), "\(name.debugDescription), flags \(flags)")
            }
            XCTAssertThrowsError(try book.data(at: "OPS/x.css"), "flags \(flags)")
            XCTAssertThrowsError(try book.data(at: "OPS/a:x.css"), "flags \(flags)")
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], "flags \(flags)")
        }
    }

    func testBytesOnlyAForgivingDecoderReadsAsASeparatorOrADotAreNotUTF8() throws {
        // Overlong forms: a dot, a slash, a backslash, a colon and a NUL each spelled in more
        // bytes than UTF-8 allows. A decoder that accepted them would read `OPS/../x.css` in the
        // first. They are not UTF-8, so without the flag each is a name in code page 437, a file
        // like any other, and with it no name at all.
        let overlong: [(String, [UInt8], String)] = [
            ("../", [0xC0, 0xAE, 0xC0, 0xAE, 0xC0, 0xAF], "\u{2514}\u{AB}\u{2514}\u{AB}\u{2514}\u{BB}"),
            ("/", [0xE0, 0x80, 0xAF], "\u{3B1}\u{C7}\u{BB}"),
            ("\\", [0xC1, 0x9C], "\u{2534}\u{A3}"),
            (":", [0xC0, 0xBA], "\u{2514}\u{2551}"),
            ("\0", [0xC0, 0x80], "\u{2514}\u{C7}"),
        ]
        for (meant, bytes, reading) in overlong {
            let name = Array("OPS/".utf8) + bytes + Array("x.css".utf8)
            let book = try EPUBPublication.open(data: self.book(adding: [entry(named: name, "a{}", flags: 0)]))
            XCTAssertEqual(try book.data(at: "OPS/\(reading)x.css"), Data("a{}".utf8), meant.debugDescription)
            XCTAssertThrowsError(try book.data(at: "OPS/\(meant)x.css"), meant.debugDescription)
            XCTAssertThrowsError(try book.data(at: "x.css"), meant.debugDescription)
            XCTAssertThrowsError(try EPUBPublication.open(data: self.book(adding: [entry(named: name, "a{}", flags: 0x0800)])), meant.debugDescription) {
                guard case .unsafePath = $0 as? EPUBPublicationError else { return XCTFail("\(meant.debugDescription): \($0)") }
            }
        }
    }

    func testAFlaglessUTF8NameIsOneKeyForEverythingThatNamesAnEntry() throws {
        // The package document's folder as the container names it, manifest and navigation hrefs
        // resolved from that folder, an obfuscated font's cipher reference, and text extraction.
        let folder = "\u{152}uvres", font = "fonts/\u{E9}t\u{E9}.otf"
        var files: [String: Data] = [:]
        for (path, bytes) in try Fixture.packageVariantFiles(
            opf: { $0.replacingOccurrences(of: "</manifest>", with: "<item id=\"font\" href=\"fonts/%C3%A9t%C3%A9.otf\" media-type=\"font/otf\"/></manifest>") },
            container: { $0.replacingOccurrences(of: "OPS/book.opf", with: "%C5%92uvres/book.opf") }) {
            files[path.hasPrefix("OPS/") ? "\(folder)\(path.dropFirst(3))" : path] = bytes
        }
        let original = Data((0..<1100).map { UInt8($0 % 251) }), key = Array(Insecure.SHA1.hash(data: Data("test-book".utf8)))
        var obfuscated = original
        for index in 0..<1040 { obfuscated[index] ^= key[index % key.count] }
        files["\(folder)/\(font)"] = obfuscated
        files["META-INF/encryption.xml"] = Data(("<encryption><EncryptedData><EncryptionMethod Algorithm='http://www.idpf.org/2008/embedding'/>"
            + "<CipherData><CipherReference URI='%C5%92uvres/fonts/%C3%A9t%C3%A9.otf'/></CipherData></EncryptedData></encryption>").utf8)
        for flags: UInt16 in [0x0800, 0] {
            let book = try EPUBPublication.open(data: Fixture.storedArchive(Fixture.storedEntries(files, flags: flags)))
            XCTAssertEqual(book.spine.map(\.resource.path), ["\(folder)/one.xhtml", "\(folder)/two.xhtml"], "flags \(flags)")
            XCTAssertEqual(book.tableOfContents.first?.href, "%C5%92uvres/one.xhtml#start", "flags \(flags)")
            XCTAssertEqual(book.resources.first { $0.id == "font" }?.path, "\(folder)/\(font)", "flags \(flags)")
            XCTAssertEqual(try book.data(at: "\(folder)/\(font)"), original, "flags \(flags)")
            XCTAssertEqual(try book.textSection(at: 1).title, "Second Chapter", "flags \(flags)")
        }
    }

    func testBooksArchivedByZipAndDittoOnAMacOpen() throws {
        let chapters = ["caf\u{E9}", "r\u{E9}sum\u{E9}", "\u{65E5}\u{672C}\u{8A9E}", "\u{433}\u{43B}\u{430}\u{432}\u{430}", "\u{1F600}"]
        let titles = ["Latin, precomposed", "Latin, decomposed on disk", "CJK", "Cyrillic", "Emoji"]
        for (tool, data) in [("zip", Fixture.MacToolArchive.zip), ("ditto", Fixture.MacToolArchive.ditto)] {
            // What the tool wrote: the file system's bytes, one name decomposed, and bit 11 clear.
            for name in ["OPS/caf\u{E9}.xhtml", "OPS/re\u{301}sume\u{301}.xhtml", "OPS/\u{65E5}\u{672C}\u{8A9E}.xhtml",
                         "OPS/\u{433}\u{43B}\u{430}\u{432}\u{430}.xhtml", "OPS/\u{1F600}.xhtml"] {
                let record = try XCTUnwrap(Fixture.directoryOffset(of: name, in: data), "\(tool): \(name)")
                XCTAssertEqual(data[record + 9] & 0x08, 0, "\(tool): \(name)")
            }
            let book = try EPUBPublication.open(data: data)
            XCTAssertEqual(book.spine.map(\.resource.path), chapters.map { "OPS/\($0).xhtml" }, tool)
            XCTAssertEqual(book.tableOfContents.map(\.title), titles, tool)
            XCTAssertEqual(book.tableOfContents.map { $0.href?.removingPercentEncoding }, chapters.map { Optional("OPS/\($0).xhtml") }, tool)
            for (index, title) in titles.enumerated() {
                XCTAssertEqual(try book.textSection(at: index).text, title, "\(tool): \(chapters[index])")
            }
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

    // MARK: Sizes the archive cannot hold

    /// `archive` with a 32-bit field of `name`'s directory record set to `value`: at 16 its
    /// checksum, at 20 its compressed size and at 24 its uncompressed size.
    private func archive(_ archive: Data, stating value: Int, at field: Int, of name: String) throws -> Data {
        var data = archive
        let record = try XCTUnwrap(Fixture.directoryOffset(of: name, in: data))
        data.replaceSubrange((record + field)..<(record + field + 4), with: withUnsafeBytes(of: UInt32(value).littleEndian) { Array($0) })
        return data
    }

    /// Asserts that `data` is refused as an invalid archive before any of its entries is read.
    private func assertRefusedUnread(_ data: Data, _ name: String, line: UInt = #line) {
        // Progress is reported on the opening thread, after each chunk an entry gives.
        final class Chunks: @unchecked Sendable { var count = 0 }
        let chunks = Chunks()
        XCTAssertThrowsError(try EPUBPublication.open(data: data, onProgress: { _ in chunks.count += 1 }), name, line: line) {
            guard case .invalidArchive = $0 as? EPUBPublicationError else { return XCTFail("\(name): \($0)", line: line) }
        }
        XCTAssertEqual(chunks.count, 0, "\(name): chunks read before the refusal", line: line)
    }

    // ZIPFoundation reads a stored entry a chunk at a time until it has asked for the size the
    // directory gives, with or without bytes to answer, so opening took as long as that size
    // said: seconds for a terabyte, and no end for the largest a ZIP64 field holds. The sizes
    // here are small ones, which the archive cannot hold either.
    func testAStoredEntryDeclaredLargerThanTheArchiveIsRefusedBeforeAnyEntryIsRead() throws {
        let name = "OPS/one.xhtml"
        let plain = Fixture.storedArchive(Fixture.storedEntries(try Fixture.files()))
        // Every byte from the entry's first to the archive's last, the most the entry could hold.
        let room = try plain.count - XCTUnwrap(Fixture.dataOffset(of: name, in: plain))
        assertOpening(try archive(plain, stating: room, at: 24, of: name), throws: .invalidArchive("CRC: \(name)"),
                      "a size the archive has the bytes for is read, and fails its checksum")
        // A ZIP64 field's own 12 bytes come after the entry, and are that much more room.
        for excess in [1, 1 << 20] {
            assertRefusedUnread(try archive(plain, stating: room + excess, at: 24, of: name), "\(excess) more than the archive holds")
            assertRefusedUnread(try archive(plain, givingSize: 24, of: name, as: UInt64(room + 12 + excess)), "\(excess) more, in a ZIP64 field")
        }

        // The same entry behind a data descriptor, which gives the size its limits are checked
        // by. With Deflate as the directory's method the descriptor is sought after the
        // compressed size, where it is, and the entry is still read as its header says: stored,
        // by the directory's uncompressed size.
        var described = Fixture.storedArchive(Fixture.storedEntries(try Fixture.files(), flags: 0x0808))
        let record = try XCTUnwrap(Fixture.directoryOffset(of: name, in: described))
        described.replaceSubrange((record + 10)..<(record + 12), with: [8, 0])
        XCTAssertEqual(try EPUBPublication.open(data: described).spine.count, 2, "with its own size it is read")
        let space = try described.count - XCTUnwrap(Fixture.dataOffset(of: name, in: described))
        assertOpening(try archive(described, stating: space, at: 24, of: name), throws: .invalidArchive("CRC: \(name)"))
        for excess in [1, 1 << 20] {
            assertRefusedUnread(try archive(described, stating: space + excess, at: 24, of: name), "described, \(excess) more than the archive holds")
            assertRefusedUnread(try archive(described, givingSize: 24, of: name, as: UInt64(space + 12 + excess)), "described, \(excess) more, in a ZIP64 field")
        }
    }

    // A deflated entry is read by its stream, as far as that goes, and held to its checksum.
    // Neither size its directory states makes ZIPFoundation read without data, so an entry
    // whose data is whole is the book's whatever uncompressed size they give it, and whatever
    // compressed size that reaches the end of its stream and is one ZIPFoundation can hold.
    func testADeflatedEntryIsReadByItsStreamWhateverSizesItsDirectoryStates() throws {
        let name = "OPS/one.xhtml"
        let book = try Fixture.epub(), chapter = try XCTUnwrap(Fixture.files()[name])
        let record = try XCTUnwrap(Fixture.directoryOffset(of: name, in: book))
        let compressed = (0..<4).reduce(0) { $0 | Int(book[record + 20 + $1]) << (8 * $1) }
        func assertRead(_ data: Data, _ message: String, line: UInt = #line) throws {
            let opened = try EPUBPublication.open(data: data)
            XCTAssertEqual(try opened.data(at: name), chapter, message, line: line)
            XCTAssertEqual(opened.spine.count, 2, message, line: line)
        }
        // The uncompressed size is not read by at all: less than the entry inflates to, more
        // than Deflate makes of any data (1,032 times its length, two bits for a copy of 258
        // bytes), more than a resource may be, and the most a field holds.
        for size in [0, 1, chapter.count + 1, 1032 * compressed, 1032 * compressed + 1, EPUBImportLimits().resourceBytes + 1, Int(UInt32.max) - 1] {
            try assertRead(try archive(book, stating: size, at: 24, of: name), "an uncompressed size of \(size)")
        }
        for size in [UInt64(1) << 40, 1 << 63, .max] {
            try assertRead(try archive(book, givingSize: 24, of: name, as: size), "an uncompressed size of \(size) in a ZIP64 field")
        }

        // The compressed size is how far the entry may be read. Past the end of its stream is
        // not read, and past the end of the archive there is nothing to read.
        let room = try book.count - XCTUnwrap(Fixture.dataOffset(of: name, in: book))
        for size in [compressed + 1, room, room + 1, Int(UInt32.max) - 1] {
            try assertRead(try archive(book, stating: size, at: 20, of: name), "a compressed size of \(size)")
        }
        for size in [UInt64(1) << 40, UInt64(Int64.max)] {
            try assertRead(try archive(book, givingSize: 20, of: name, as: size), "a compressed size of \(size) in a ZIP64 field")
        }
        // Short of its stream's end the entry is cut off. ZIPFoundation's own error for that
        // is not yet typed (#74): only that it is one.
        for size in [0, 1, compressed - 1] {
            XCTAssertThrowsError(try EPUBPublication.open(data: archive(book, stating: size, at: 20, of: name)), "a compressed size of \(size)")
        }
    }

    // The limits are for what a book expands to. A stored entry is as long as its directory
    // says; a deflated one is as long as its stream makes it, which is counted as it is read.
    func testADeflatedEntryIsHeldToTheLimitsByWhatItInflatesToAndNotByItsDeclaredSize() throws {
        let name = "OPS/payload.txt"
        let payload = String(repeating: "x", count: 131_072)
        let data = try Fixture.epub(overrides: [name: payload])
        let total = try Fixture.files().values.reduce(payload.utf8.count) { $0 + $1.count }
        var limits = EPUBImportLimits()
        limits.resourceBytes = payload.utf8.count
        limits.expandedBytes = total
        XCTAssertEqual(try EPUBPublication.open(data: data, limits: limits).data(at: name), Data(payload.utf8), "at both limits")
        // Declared larger than either limit and no larger than it was: the same book.
        for size in [payload.utf8.count + 1, total + 1, 1 << 30, Int(UInt32.max) - 1] {
            let book = try EPUBPublication.open(data: archive(data, stating: size, at: 24, of: name), limits: limits)
            XCTAssertEqual(try book.data(at: name), Data(payload.utf8), "declared as \(size) bytes")
        }
        // A byte over either limit is refused as it is inflated, whatever was declared.
        for size in [10, payload.utf8.count, 1 << 30] {
            let stated = try archive(data, stating: size, at: 24, of: name)
            var less = limits
            less.resourceBytes -= 1
            assertOpening(stated, limits: less, throws: .limitExceeded(name), "one resource, declared as \(size) bytes")
            less = limits
            less.expandedBytes -= 1
            XCTAssertThrowsError(try EPUBPublication.open(data: stated, limits: less), "the whole book, with one entry declared as \(size) bytes") {
                guard case .limitExceeded = $0 as? EPUBPublicationError else { return XCTFail("\(size): \($0)") }
            }
        }
    }

    func testEntriesThatCompressAsFarAsDeflateAllowsAreRead() throws {
        // A megabyte of zeros, as ZIPFoundation's own writer deflates it.
        let megabyte = String(repeating: "\0", count: 1 << 20)
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/zeros.bin": megabyte])).data(at: "OPS/zeros.bin"), Data(count: 1 << 20))

        // The most any stream can hold: one block whose codes are a zero and the block's end at
        // two bits each, a copy of 258 bytes at one bit and a distance of one at one bit. After
        // the 108 bits that say so and a first zero, every two zero bits are 258 more zeros.
        let copies = 2 + 4 * 30_000
        let stream = Data([0xED, 0xC0, 0x01, 0x09, 0x00, 0x00, 0x00, 0x80, 0xA0, 0xFE, 0xAF, 0xEE, 0x88, 0x06]) + Data(count: 30_000) + Data([0x03])
        let zeros = Data(count: 1 + 258 * copies)
        XCTAssertGreaterThan(zeros.count, 1031 * stream.count)
        var entries = Fixture.storedEntries(try Fixture.files())
        entries.append(Fixture.StoredEntry("OPS/zeros.bin", stream, method: 8))
        // storedArchive describes the stream as the entry's own bytes; the directory, which is
        // what is read, gets the checksum and size of what it inflates to.
        var data = try archive(Fixture.storedArchive(entries), stating: Int(zeros.crc32(checksum: 0)), at: 16, of: "OPS/zeros.bin")
        data = try archive(data, stating: zeros.count, at: 24, of: "OPS/zeros.bin")
        XCTAssertEqual(try EPUBPublication.open(data: data).data(at: "OPS/zeros.bin"), zeros)
        // A size no stream of that length holds is still not what the entry is read by.
        XCTAssertEqual(try EPUBPublication.open(data: archive(data, stating: 1032 * stream.count + 1, at: 24, of: "OPS/zeros.bin")).data(at: "OPS/zeros.bin"), zeros)
    }

    func testEntriesTheArchiveHoldsInFullAreReadWhateverTheirLayout() throws {
        var files = try Fixture.files()
        files["OPS/empty.css"] = Data()
        func assertRead(_ data: Data, _ name: String, line: UInt = #line) throws {
            let book = try EPUBPublication.open(data: data)
            for (path, bytes) in files { XCTAssertEqual(try book.data(at: path), bytes, "\(name): \(path)", line: line) }
        }
        // An empty stored entry has no bytes to be short of, even as the last entry before the
        // directory, and neither has an empty deflated one of two bytes.
        let entries = Fixture.storedEntries(files)
        try assertRead(Fixture.storedArchive(entries), "an empty entry")
        try assertRead(Fixture.storedArchive(entries.filter { !$0.data.isEmpty } + entries.filter { $0.data.isEmpty }), "an empty last entry")
        var deflated = entries.filter { !$0.data.isEmpty }
        deflated.append(Fixture.StoredEntry("OPS/empty.css", Data([0x03, 0x00]), method: 8))
        var data = try archive(Fixture.storedArchive(deflated), stating: 0, at: 16, of: "OPS/empty.css")
        data = try archive(data, stating: 0, at: 24, of: "OPS/empty.css")
        try assertRead(data, "an empty deflated entry")

        // Sizes that follow the data, with the descriptor's optional signature and without it.
        let described = Fixture.storedArchive(Fixture.storedEntries(files, flags: 0x0808))
        try assertRead(described, "data descriptors")
        var unsigned = described
        for (path, bytes) in files {
            let descriptor = try XCTUnwrap(Fixture.dataOffset(of: path, in: described)) + bytes.count
            XCTAssertEqual(Array(described[descriptor..<(descriptor + 4)]), [0x50, 0x4B, 0x07, 0x08], path)
            // The checksum and sizes move up over the signature; four spare bytes follow them.
            unsigned.replaceSubrange(descriptor..<(descriptor + 16), with: described[(descriptor + 4)..<(descriptor + 16)] + Data(count: 4))
        }
        try assertRead(unsigned, "data descriptors without their signature")
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
