import EPUBCore
import EPUBWriting
import Foundation
import Testing
import ZIPFoundation

private actor WriterRecorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func add(_ value: Value) { values.append(value) }
}

/// `EPUBArchiveWriter.write`: OCF ZIP structure, streaming, the content budget, cleanup after
/// failure and ownership of source files, against doc/writing.md and EPUB 3.3 OCF (4.3).
struct WriterArchiveCoverageTests {
    private typealias Entry = EPUBArchiveWriter.Entry
    private let date = WriterCoverage.date

    /// A little-endian ZIP header field.
    private func field(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func contents(of archive: URL) throws -> [(path: String, data: Data)] {
        let zip = try Archive(url: archive, accessMode: .read)
        return try zip.map { entry in
            var data = Data()
            _ = try zip.extract(entry) { data.append($0) }
            return (entry.path, data)
        }
    }

    // MARK: Container structure

    // EPUB 3.3, 4.3.3: the mimetype file is "the first file in the OCF ZIP container", neither
    // compressed nor encrypted, with no extra field, so "application/epub+zip" starts at byte 38.
    @Test func mimetypeIsFirstStoredWithoutExtraFieldAndItsContentStartsAtByte38() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let asset = try WriterCoverage.file("asset", Data(repeating: 0x61, count: 4_000), in: directory)
        let output = directory.appendingPathComponent("book.epub")
        try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime), .init(path: "EPUB/asset.txt", fileURL: asset)],
                                         to: output, maximumContentBytes: 10_000, modificationDate: date)
        let bytes = try Data(contentsOf: output)
        #expect(Array(bytes[0..<4]) == [0x50, 0x4B, 0x03, 0x04])
        #expect(field(bytes, 6, 2) & 0x0009 == 0) // Neither encrypted nor followed by a data descriptor.
        #expect(field(bytes, 8, 2) == 0) // Stored.
        #expect(field(bytes, 18, 4) == 20 && field(bytes, 22, 4) == 20)
        #expect(field(bytes, 26, 2) == 8)
        #expect(field(bytes, 28, 2) == 0) // No extra field.
        #expect(String(decoding: bytes[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: bytes[38..<58], as: UTF8.self) == "application/epub+zip")
        // Every other entry is deflated.
        #expect(Array(bytes[58..<62]) == [0x50, 0x4B, 0x03, 0x04])
        #expect(field(bytes, 58 + 8, 2) == 8)
        let entries = Array(try Archive(url: output, accessMode: .read))
        #expect(entries.map(\.path) == ["mimetype", "EPUB/asset.txt"])
        #expect(entries.last?.uncompressedSize == 4_000)
        #expect((entries.last?.compressedSize ?? .max) < 4_000)
    }

    @Test func nonASCIIEntryNamesAreFlaggedUTF8AndKeepTheirExactScalars() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let asset = try WriterCoverage.file("asset", Data([1, 2, 3]), in: directory)
        let names = ["EPUB/caf\u{E9} \u{1F600}.txt", "EPUB/cafe\u{301}-decomposed.txt", "EPUB/\u{65E5}\u{672C}\u{8A9E}/\u{7AE0} 1#2%.xhtml"]
        let output = directory.appendingPathComponent("names.epub")
        try await EPUBArchiveWriter.write(entries: [Entry(path: "mimetype", fileURL: mime)] + names.map { Entry(path: $0, fileURL: asset) },
                                         to: output, maximumContentBytes: 1_000, modificationDate: date)
        let written = try contents(of: output)
        #expect(written.count == 4)
        for (entry, name) in zip(written.dropFirst(), names) {
            #expect(entry.path.unicodeScalars.elementsEqual(name.unicodeScalars), "\(name)")
            #expect(entry.data == Data([1, 2, 3]))
        }
        // General-purpose bit 11 says the name is UTF-8, as OCF requires of every file name.
        let bytes = try Data(contentsOf: output)
        #expect(field(bytes, 58 + 6, 2) & 0x0800 != 0)
    }

    @Test func zeroByteAndMultiChunkFilesRoundTripByteForByteAtTheExactBudget() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var noise = Data(capacity: 3_000_000)
        for _ in 0..<(3_000_000 / 8) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            withUnsafeBytes(of: state) { noise.append(contentsOf: $0) }
        }
        let files: [(String, Data)] = [("EPUB/empty.bin", Data()), ("EPUB/noise.bin", noise), ("EPUB/zeros.bin", Data(count: 1_500_001)),
                                       ("EPUB/one.bin", Data([0x42])), ("EPUB/empty-too.bin", Data())]
        var entries = [Entry(path: "mimetype", fileURL: try WriterCoverage.mimetype(in: directory))]
        for (index, file) in files.enumerated() {
            entries.append(.init(path: file.0, fileURL: try WriterCoverage.file("source-\(index)", file.1, in: directory)))
        }
        let output = directory.appendingPathComponent("large.epub")
        let total = Int64(20 + files.reduce(0) { $0 + $1.1.count })
        try await EPUBArchiveWriter.write(entries: entries, to: output, maximumContentBytes: total, modificationDate: date)
        let written = try contents(of: output)
        #expect(written.map { $0.path } == ["mimetype"] + files.map { $0.0 })
        for (entry, file) in zip(written.dropFirst(), files) { #expect(entry.data == file.1, "\(file.0)") }
        #expect(written.first?.data == Data("application/epub+zip".utf8))
    }

    // "The caller chooses a ... modification date for reproducible output."
    @Test func identicalInputsGiveIdenticalArchivesStampedWithTheGivenDate() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = [Entry(path: "mimetype", fileURL: try WriterCoverage.mimetype(in: directory)),
                       Entry(path: "EPUB/a.txt", fileURL: try WriterCoverage.file("a", Data("alpha alpha alpha".utf8), in: directory)),
                       Entry(path: "META-INF/container.xml", fileURL: try WriterCoverage.file("c", Data("<container/>".utf8), in: directory))]
        var archives: [Data] = []
        for (name, stamp) in [("first", date), ("second", date), ("later", date.addingTimeInterval(86_400))] {
            let output = directory.appendingPathComponent(name + ".epub")
            try await EPUBArchiveWriter.write(entries: entries, to: output, maximumContentBytes: 1_000, modificationDate: stamp)
            archives.append(try Data(contentsOf: output))
            for entry in try Archive(url: output, accessMode: .read) {
                #expect(entry.fileAttributes[.modificationDate] as? Date == stamp, "\(entry.path)")
            }
        }
        #expect(archives[0] == archives[1])
        #expect(archives[0] != archives[2])
    }

    // MARK: Budget and progress

    @Test func theContentBudgetCountsEveryEntryIncludingTheMimetype() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = [Entry(path: "mimetype", fileURL: try WriterCoverage.mimetype(in: directory)),
                       Entry(path: "EPUB/a", fileURL: try WriterCoverage.file("a", Data(repeating: 1, count: 60), in: directory)),
                       Entry(path: "EPUB/b", fileURL: try WriterCoverage.file("b", Data(repeating: 2, count: 40), in: directory), consume: true)]
        let refused = directory.appendingPathComponent("refused.epub")
        await #expect(throws: EPUBWritingError.resourceLimit("EPUB total size")) {
            try await EPUBArchiveWriter.write(entries: entries, to: refused, maximumContentBytes: 119, modificationDate: date)
        }
        #expect(!exists(refused))
        #expect(entries.allSatisfy { exists($0.fileURL) }) // The entry that broke the budget was never consumed.
        for budget: Int64 in [0, -1, .min] {
            await #expect(throws: EPUBWritingError.self) {
                try await EPUBArchiveWriter.write(entries: entries, to: refused, maximumContentBytes: budget, modificationDate: date)
            }
            #expect(!exists(refused))
        }
        let exact = directory.appendingPathComponent("exact.epub")
        try await EPUBArchiveWriter.write(entries: entries, to: exact, maximumContentBytes: 120, modificationDate: date)
        #expect(try contents(of: exact).map { $0.data.count } == [20, 60, 40])
    }

    @Test func progressRunsInOrderFromZeroThroughOneOncePerEntry() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try WriterCoverage.file("asset", Data(repeating: 3, count: 50_000), in: directory)
        let entries = [Entry(path: "mimetype", fileURL: try WriterCoverage.mimetype(in: directory))]
            + (1...3).map { Entry(path: "EPUB/\($0).bin", fileURL: asset) }
        let recorder = WriterRecorder<Double>()
        try await EPUBArchiveWriter.write(entries: entries, to: directory.appendingPathComponent("book.epub"), maximumContentBytes: 1_000_000,
                                         modificationDate: date) { await recorder.add($0) }
        #expect(await recorder.values == [0, 0.25, 0.5, 0.75, 1])
    }

    // MARK: Refused input

    @Test func invalidEntryListsFailBeforeAnythingIsCreatedOrConsumed() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = Entry(path: "mimetype", fileURL: try WriterCoverage.mimetype(in: directory))
        let assetURL = try WriterCoverage.file("asset", Data([1, 2, 3]), in: directory)
        let output = directory.appendingPathComponent("book.epub")
        func asset(_ path: String) -> Entry { Entry(path: path, fileURL: assetURL, consume: true) }
        var cases: [(String, [Entry])] = [
            ("no entries", []), ("mimetype second", [asset("EPUB/a"), mime]), ("no mimetype", [asset("EPUB/a")]),
            ("mimetype under a directory", [Entry(path: "EPUB/mimetype", fileURL: mime.fileURL), asset("EPUB/a")]),
            ("duplicate path", [mime, asset("EPUB/a"), asset("EPUB/a")]), ("second mimetype", [mime, asset("mimetype")]),
            ("entry is the destination", [mime, Entry(path: "EPUB/self", fileURL: output)]),
            ("remote source", [mime, Entry(path: "EPUB/remote", fileURL: try #require(URL(string: "https://example.invalid/a")))]),
        ]
        for path in ["../a", "EPUB/../a", "/a", "a\\b", "a:b", "", "EPUB/", "EPUB//a", "./a", "EPUB/.", "EPUB/a\0b"] {
            cases.append(("path \(path.debugDescription)", [mime, asset(path)]))
        }
        for (label, entries) in cases {
            await #expect(throws: EPUBWritingError.self, "\(label)") {
                try await EPUBArchiveWriter.write(entries: entries, to: output, maximumContentBytes: 1_000, modificationDate: date)
            }
            #expect(!exists(output), "\(label)")
            #expect(exists(assetURL) && exists(mime.fileURL), "\(label)")
        }
    }

    // A `Character` holds a "/", "\", ":" or "." together with a combining mark, variation
    // selector or joiner after it, so read that way "EPUB/../" + U+0301 + "a" is a safe path and
    // was written as an entry of that name (https://github.com/vocaro/EPUBLib/issues/181).
    @Test func entryPathsAreCheckedWhateverMarkFollowsASeparatorOrDot() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = Entry(path: "mimetype", fileURL: try WriterCoverage.mimetype(in: directory))
        let assetURL = try WriterCoverage.file("asset", Data([1, 2, 3]), in: directory)
        for (index, m) in WriterCoverage.clusteringMarks.enumerated() {
            let refused = directory.appendingPathComponent("refused.epub")
            for path in ["../\(m)a", "EPUB/../\(m)a", "EPUB/../../\(m)a", "/\(m)a", "EPUB//\(m)a", "./\(m)a", "EPUB/./\(m)a", "a\\\(m)b", "a:\(m)b",
                         "EPUB/a\u{600}/..", "EPUB/a\u{600}/"] {
                await #expect(throws: EPUBWritingError.invalidPublication("duplicate or invalid entry: \(path)"), "\(path.debugDescription)") {
                    try await EPUBArchiveWriter.write(entries: [mime, Entry(path: path, fileURL: assetURL)], to: refused, maximumContentBytes: 1_000,
                                                     modificationDate: date)
                }
                #expect(!exists(refused), "\(path.debugDescription)")
            }
            // A name that begins with the mark, or is dots and the mark, is written as it is.
            let names = ["EPUB/\(m)a.txt", "EPUB/a.txt", "EPUB\(m)/a.txt", "\(m)a.txt", "EPUB/.\(m)", "EPUB/..\(m)"]
            let output = directory.appendingPathComponent("names-\(index).epub")
            try await EPUBArchiveWriter.write(entries: [mime] + names.map { Entry(path: $0, fileURL: assetURL) }, to: output, maximumContentBytes: 1_000,
                                             modificationDate: date)
            #expect(try contents(of: output).dropFirst().map { Array($0.path.unicodeScalars) } == names.map { Array($0.unicodeScalars) }, "\(m.debugDescription)")
        }
    }

    @Test func aMimetypeFileWithOtherContentIsRefused() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("book.epub")
        for (index, content) in ["", "application/epub", "Application/epub+zip", " application/epub+zip", "application/zip+epub!!!", "\u{FEFF}application/epub+zip"].enumerated() {
            let mime = try WriterCoverage.file("mimetype-\(index)", Data(content.utf8), in: directory)
            await #expect(throws: EPUBWritingError.invalidPublication("invalid mimetype"), "\(content.debugDescription)") {
                try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime)], to: output, maximumContentBytes: 1_000,
                                                 modificationDate: date)
            }
            #expect(!exists(output))
        }
    }

    // EPUB 3.3, 4.3.3: "The mimetype file MUST NOT contain any leading or trailing padding or
    // whitespace." doc/writing.md: the writer "stores the exact mimetype". A trailing newline is
    // the usual way to get it wrong (echo, an editor), and the reader refuses such an archive.
    @Test func aMimetypeFileWithTrailingBytesIsRefused() async throws {
        try await withKnownIssue("https://github.com/vocaro/EPUBLib/issues/97") {
            let directory = try WriterCoverage.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let mime = try WriterCoverage.file("mimetype", Data("application/epub+zip\n".utf8), in: directory)
            let output = directory.appendingPathComponent("book.epub")
            await #expect(throws: EPUBWritingError.invalidPublication("invalid mimetype")) {
                try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime)], to: output, maximumContentBytes: 1_000,
                                                 modificationDate: date)
            }
            #expect(!exists(output))
        }
    }

    @Test func anExistingDestinationOfAnyKindIsRefusedAndLeftUntouched() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = [Entry(path: "mimetype", fileURL: try WriterCoverage.mimetype(in: directory))]
        let existing = try WriterCoverage.file("existing.epub", Data("keep".utf8), in: directory)
        let folder = directory.appendingPathComponent("folder.epub")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for destination in [existing, folder, try #require(URL(string: "https://example.invalid/book.epub"))] {
            await #expect(throws: EPUBWritingError.invalidPublication("archive destination, budget or mimetype order")) {
                try await EPUBArchiveWriter.write(entries: entries, to: destination, maximumContentBytes: 1_000, modificationDate: date)
            }
        }
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        #expect(exists(folder))
    }

    @Test func aDestinationThatCannotBeCreatedFailsWithoutLeavingAFile() async throws {
        let directory = try WriterCoverage.directory()
        let locked = directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try WriterCoverage.mimetype(in: directory)
        for destination in [directory.appendingPathComponent("no/such/folder/book.epub"), locked.appendingPathComponent("book.epub")] {
            await #expect(throws: (any Error).self, "\(destination.lastPathComponent) in \(destination.deletingLastPathComponent().lastPathComponent)") {
                try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: source, consume: true)], to: destination,
                                                 maximumContentBytes: 1_000, modificationDate: date)
            }
            #expect(!exists(destination))
            #expect(exists(source))
        }
    }

    // MARK: Failure while writing

    @Test func aMissingSourceFileRemovesThePartialArchiveAndKeepsCallerFiles() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let present = try WriterCoverage.file("present", Data(repeating: 5, count: 10_000), in: directory)
        let output = directory.appendingPathComponent("book.epub")
        await #expect(throws: (any Error).self) {
            try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime), .init(path: "EPUB/a", fileURL: present),
                .init(path: "EPUB/b", fileURL: directory.appendingPathComponent("never-written")), .init(path: "EPUB/c", fileURL: present)],
                to: output, maximumContentBytes: 1_000_000, modificationDate: date)
        }
        #expect(!exists(output))
        #expect(exists(present) && exists(mime))
        await #expect(throws: (any Error).self) {
            try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: directory.appendingPathComponent("no-mimetype"))],
                                             to: output, maximumContentBytes: 1_000_000, modificationDate: date)
        }
        #expect(!exists(output))
    }

    @Test func aSourceThatDisappearsWhileWritingFailsCleanly() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let early = try WriterCoverage.file("early", Data(repeating: 5, count: 10_000), in: directory)
        let late = try WriterCoverage.file("late", Data(repeating: 6, count: 10_000), in: directory)
        let output = directory.appendingPathComponent("book.epub")
        await #expect(throws: (any Error).self) {
            try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime), .init(path: "EPUB/early", fileURL: early),
                .init(path: "EPUB/late", fileURL: late)], to: output, maximumContentBytes: 1_000_000, modificationDate: date) { fraction in
                    if fraction > 0.5 { try? FileManager.default.removeItem(at: late) }
                }
        }
        #expect(!exists(output))
        #expect(exists(early))
    }

    @Test func cancellationBeforeTheFirstEntryCreatesNoArchiveAndConsumesNothing() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let asset = try WriterCoverage.file("asset", Data(repeating: 1, count: 100), in: directory)
        let output = directory.appendingPathComponent("book.epub")
        let stamp = date
        let task = Task {
            try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime, consume: true),
                .init(path: "EPUB/asset", fileURL: asset, consume: true)], to: output, maximumContentBytes: 1_000, modificationDate: stamp) { fraction in
                    if fraction == 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!exists(output))
        #expect(exists(mime) && exists(asset))
    }

    // MARK: Source file ownership

    @Test func consumedFilesAreDeletedOnlyAfterTheirFinalEntryAndCallerFilesAreKept() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let temporary = try WriterCoverage.file("temporary", Data("t".utf8), in: directory)
        let shared = try WriterCoverage.file("shared", Data("s".utf8), in: directory)
        let kept = try WriterCoverage.file("kept", Data("k".utf8), in: directory)
        let output = directory.appendingPathComponent("book.epub")
        let recorder = WriterRecorder<[Bool]>()
        try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime),
            .init(path: "EPUB/a", fileURL: temporary, consume: true), .init(path: "EPUB/b", fileURL: shared, consume: true),
            .init(path: "EPUB/c", fileURL: kept), .init(path: "EPUB/d", fileURL: shared, consume: true)],
            to: output, maximumContentBytes: 1_000, modificationDate: date) { _ in
                await recorder.add([temporary, shared, kept].map { FileManager.default.fileExists(atPath: $0.path) })
            }
        // After: nothing, mimetype, a, b, c, d.
        #expect(await recorder.values == [[true, true, true], [true, true, true], [false, true, true], [false, true, true],
                                         [false, true, true], [false, false, true]])
        #expect(exists(mime) && exists(kept))
        #expect(try contents(of: output).map { String(decoding: $0.data, as: UTF8.self) } == ["application/epub+zip", "t", "s", "k", "s"])
    }

    // A staging directory may link to large media instead of copying it. The entry's declared size
    // must be that of the bytes that are read, whichever of the link or its target is archived.
    @Test func aSymbolicLinkToASourceFileIsArchivedWithItsWholeContentOrRefused() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let content = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let target = try WriterCoverage.file("target.bin", content, in: directory)
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let output = directory.appendingPathComponent("book.epub")
        try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime), .init(path: "EPUB/linked.bin", fileURL: link)],
                                         to: output, maximumContentBytes: 1_000_000, modificationDate: date)
        let written = try #require(try contents(of: output).last)
        #expect(written.data.count == content.count)
        let identical = written.data == content
        #expect(identical)
        #expect(exists(target) && exists(link))
    }

    // "A non-consuming reference keeps a shared file alive." The same file reached through two
    // spellings of its path is still one shared, caller-owned file; the writer already compares
    // standardized URLs when it checks entries against the destination.
    @Test func aCallerOwnedFileReferencedThroughAnotherSpellingSurvivesAConsumingEntry() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let shared = try WriterCoverage.file("shared", Data("s".utf8), in: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("sub/../shared")
        #expect(alias.standardizedFileURL == shared.standardizedFileURL)
        let output = directory.appendingPathComponent("book.epub")
        do {
            try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime),
                .init(path: "EPUB/a", fileURL: shared, consume: true), .init(path: "EPUB/b", fileURL: alias)],
                to: output, maximumContentBytes: 1_000, modificationDate: date)
        } catch {
            Issue.record("writing failed after the shared file was consumed: \(error)")
        }
        #expect(exists(shared), "the caller-owned file was deleted")
        #expect(exists(output))
        #expect(try contents(of: output).map(\.data) == [Data("application/epub+zip".utf8), Data("s".utf8), Data("s".utf8)])
    }

    @Test func aSymbolicLinkUsesItsTargetsSizeForTheBudgetAndConsumesOnlyTheLink() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let content = Data(repeating: 7, count: 10_000)
        let target = try WriterCoverage.file("target.bin", content, in: directory)
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let output = directory.appendingPathComponent("book.epub")
        let entries: [EPUBArchiveWriter.Entry] = [.init(path: "mimetype", fileURL: mime),
            .init(path: "EPUB/linked.bin", fileURL: link, consume: true)]
        await #expect(throws: EPUBWritingError.resourceLimit("EPUB total size")) {
            try await EPUBArchiveWriter.write(entries: entries, to: output, maximumContentBytes: 1_000, modificationDate: date)
        }
        #expect(!exists(output))
        #expect(exists(link) && exists(target))
        try await EPUBArchiveWriter.write(entries: entries, to: output, maximumContentBytes: 10_020, modificationDate: date)
        #expect(try contents(of: output).last?.data == content)
        #expect(!exists(link))
        #expect(exists(target))
    }

    @Test func consumedPathSpellingsAreKeptUntilTheirFinalSharedUse() async throws {
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mime = try WriterCoverage.mimetype(in: directory)
        let shared = try WriterCoverage.file("shared", Data("s".utf8), in: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("sub/../shared")
        let output = directory.appendingPathComponent("book.epub")
        let recorder = WriterRecorder<Bool>()
        try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime),
            .init(path: "EPUB/a", fileURL: shared, consume: true), .init(path: "EPUB/b", fileURL: alias, consume: true)],
            to: output, maximumContentBytes: 1_000, modificationDate: date) { _ in
                await recorder.add(FileManager.default.fileExists(atPath: shared.path))
            }
        #expect(await recorder.values == [true, true, true, false])
        #expect(try contents(of: output).map(\.data) == [Data("application/epub+zip".utf8), Data("s".utf8), Data("s".utf8)])
    }
}
