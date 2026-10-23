import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest

/// A book unpacked into a folder, as Apple Books keeps one on the Mac
/// (https://github.com/vocaro/EPUBLib/issues/680). `open(at:)` read a folder's URL with a
/// `FileHandle` and refused it; it now reads the folder as an OCF abstract container (EPUB 3.3
/// §4.2), with an archive's limits and refusals, `mimetype` optional.
final class PublicationFolderTests: XCTestCase {
    private var made: [URL] = []

    override func tearDown() {
        for url in made {
            // A test may leave a file it cannot be read; it is removed all the same.
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        made = []
        super.tearDown()
    }

    private func folder(_ files: [String: Data]) throws -> URL {
        let url = try Fixture.folder(files)
        made.append(url)
        return url
    }

    /// A book with a font obfuscated by IDPF's algorithm, keyed by its unique identifier.
    private func obfuscatedFontBook() throws -> Data {
        var files = try Fixture.files()
        // SHA-1('test-book'), as `PublicationSafetyTests` gives it.
        let key: [UInt8] = [0x35, 0x3f, 0x85, 0x83, 0x14, 0x98, 0xd7, 0xc5, 0x88, 0x9e,
                            0xff, 0x84, 0x22, 0xb1, 0x73, 0x61, 0xc1, 0x42, 0xbf, 0x54]
        var font = Data((0..<1100).map { UInt8($0 % 251) })
        for index in 0..<1040 { font[index] ^= key[index % key.count] }
        files["OPS/font.otf"] = font
        files["META-INF/encryption.xml"] = Data("<encryption><EncryptedData><EncryptionMethod Algorithm='http://www.idpf.org/2008/embedding'/><CipherData><CipherReference URI='OPS/font.otf'/></CipherData></EncryptedData></encryption>".utf8)
        files["OPS/book.opf"] = Data(String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
            .replacingOccurrences(of: "</manifest>", with: "<item id=\"font\" href=\"font.otf\" media-type=\"font/otf\"/></manifest>").utf8)
        return try Fixture.archive(files)
    }

    /// Requires the two to be one publication: everything a host reads of it but the `id` of the
    /// bytes it was opened from, and `archiveData`, which a folder does not have.
    private func assertSame(_ folder: EPUBPublication, _ zipped: EPUBPublication, _ name: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(folder.metadata, zipped.metadata, name, file: file, line: line)
        XCTAssertEqual(folder.resources, zipped.resources, name, file: file, line: line)
        XCTAssertEqual(folder.spine, zipped.spine, name, file: file, line: line)
        XCTAssertEqual(folder.tableOfContents, zipped.tableOfContents, name, file: file, line: line)
        XCTAssertEqual(folder.landmarks, zipped.landmarks, name, file: file, line: line)
        XCTAssertEqual(folder.pageList, zipped.pageList, name, file: file, line: line)
        XCTAssertEqual(folder.cover, zipped.cover, name, file: file, line: line)
        XCTAssertEqual(folder.pageProgression, zipped.pageProgression, name, file: file, line: line)
        XCTAssertEqual(folder.lostEntries, zipped.lostEntries, name, file: file, line: line)
        XCTAssertEqual(folder.uniqueIdentifier, zipped.uniqueIdentifier, name, file: file, line: line)
        XCTAssertEqual(folder.releaseIdentifier, zipped.releaseIdentifier, name, file: file, line: line)
        XCTAssertEqual(folder.persistentID, zipped.persistentID, name, file: file, line: line)
        XCTAssertEqual(folder.publicationIDs.dropLast(), zipped.publicationIDs.dropLast(), name, file: file, line: line)
        XCTAssertEqual(folder.publicationIDs.last, folder.id, name, file: file, line: line)
        XCTAssertNotEqual(folder.id, zipped.id, name, file: file, line: line)
        XCTAssertTrue(folder.archiveData.isEmpty, name, file: file, line: line)
        for resource in zipped.resources {
            XCTAssertEqual(try folder.data(for: resource), try zipped.data(for: resource), "\(name): \(resource.path)", file: file, line: line)
            XCTAssertEqual(folder.fallbackChain(for: resource), zipped.fallbackChain(for: resource), "\(name): \(resource.path)", file: file, line: line)
        }
    }

    /// Acceptance: each fixture unzipped into a folder opens to the same publication as the
    /// zipped fixture. Among them are names a Mac's `zip` and `ditto` kept decomposed, as HFS+ kept
    /// every name, a name with `#`, `%` and `?`, fixed layout, right-to-left and vertical books,
    /// a page list, an EPUB 2 book and an obfuscated font.
    func testEachFixtureUnzippedIntoAFolderOpensToTheSamePublication() throws {
        var fixtures: [(String, Data)] = [("plain", try Fixture.epub()), ("EPUB 2", try Fixture.epub(epub2: true)),
                                          ("zip on a Mac", Fixture.MacToolArchive.zip), ("ditto", Fixture.MacToolArchive.ditto),
                                          ("page list", try Fixture.pageList()), ("front matter", try Fixture.frontMatter()),
                                          ("EPUB 2 front matter", try Fixture.frontMatter(text: "text/chapter-1.xhtml", epub2: true)),
                                          ("alignment", try Fixture.alignment()), ("inline rows", try Fixture.inlineRows()),
                                          ("obfuscated font", try obfuscatedFontBook())]
        fixtures += try Fixture.Rendering.allCases.map { ($0.rawValue, try Fixture.rendering($0)) }
        for (name, archive) in fixtures {
            let zipped = try EPUBPublication.open(data: archive)
            let url = try folder(Fixture.unzipped(archive))
            try assertSame(try EPUBPublication.open(at: url), zipped, name)
        }
        // The font is read unobfuscated from the folder too.
        let font = try EPUBPublication.open(at: folder(Fixture.unzipped(obfuscatedFontBook())))
        XCTAssertEqual(try font.data(at: "OPS/font.otf"), Data((0..<1100).map { UInt8($0 % 251) }))
    }

    /// `mimetype` is part of an OCF ZIP container (EPUB 3.3 §4.2.2 reserves the name for one), so
    /// a folder may lack it; one it holds must name EPUB, as in an archive.
    func testAFolderNeedsNoMimetypeButOneItHoldsMustNameEPUB() throws {
        var files = try Fixture.unzipped(Fixture.epub())
        let zipped = try EPUBPublication.open(data: Fixture.epub())
        files["mimetype"] = nil
        try assertSame(try EPUBPublication.open(at: folder(files)), zipped, "without mimetype")
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidArchive("Missing EPUB mimetype"), "an archive needs one")
        }
        files["mimetype"] = Data("\u{FEFF} application/epub+zip\n".utf8)
        try assertSame(try EPUBPublication.open(at: folder(files)), zipped, "with mimetype as a text editor saves it")
        files["mimetype"] = Data("application/zip".utf8)
        XCTAssertThrowsError(try EPUBPublication.open(at: folder(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidArchive("Missing EPUB mimetype"))
        }
    }

    /// Acceptance: a symbolic link out of the folder is refused, and so is a link anywhere in it,
    /// whatever it points at and whether the book names it or not, as a link entry is in an
    /// archive. The folder the URL names may itself be a link.
    func testASymbolicLinkInTheFolderIsRefused() throws {
        let files = try Fixture.unzipped(Fixture.epub())
        let outside = try folder(["outside.xhtml": files["OPS/two.xhtml"]!, "images/picture.png": Data([1, 2, 3])])
        let cases: [(String, String, String)] = [
            ("a chapter linked out of the folder", "OPS/two.xhtml", outside.appending(path: "outside.xhtml").path),
            ("a chapter linked up and out", "OPS/two.xhtml", "../../\(outside.lastPathComponent)/outside.xhtml"),
            ("a chapter linked inside the folder", "OPS/two.xhtml", "one.xhtml"),
            ("a folder linked out of it", "OPS/images", outside.appending(path: "images").path),
            ("a link nothing names", "OPS/notes.xhtml", "/etc/hosts"),
            ("a link to nothing", "zzz", "missing"),
            ("the container document", "META-INF/container.xml", outside.appending(path: "outside.xhtml").path),
        ]
        for (name, path, target) in cases {
            var copy = files
            copy[path] = nil
            let url = try folder(copy)
            let link = url.appending(path: path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            XCTAssertThrowsError(try EPUBPublication.open(at: url), name) {
                XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath(path), name)
            }
        }
        let book = try folder(files)
        let link = URL.temporaryDirectory.appending(path: "link-\(UUID().uuidString).epub")
        made.append(link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: book)
        try assertSame(try EPUBPublication.open(at: link), try EPUBPublication.open(data: Fixture.epub()), "a linked folder")
    }

    /// Anything but a file or a folder is refused, a pipe among them, unopened, so that opening
    /// does not wait on it.
    func testAPipeInTheFolderIsRefusedUnopened() throws {
        let url = try folder(Fixture.unzipped(Fixture.epub()))
        XCTAssertEqual(mkfifo(url.appending(path: "OPS/pipe").path, 0o600), 0)
        XCTAssertThrowsError(try EPUBPublication.open(at: url)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("OPS/pipe"))
        }
    }

    /// A name that an archive's entry could not have is refused as that entry is: one with a
    /// backslash, which other systems read as a separator.
    func testANameThatIsNoArchivePathIsRefused() throws {
        var files = try Fixture.unzipped(Fixture.epub())
        files["OPS/a\\b.xhtml"] = Data("x".utf8)
        XCTAssertThrowsError(try EPUBPublication.open(at: folder(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("OPS/a\\b.xhtml"))
        }
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("OPS/a\\b.xhtml"), "as in an archive")
        }
    }

    /// Acceptance: a folder over the limits is refused. Its files are held to `resourceBytes` each
    /// and `expandedBytes` together, and its files and folders to `entryCount`, each exactly.
    func testAFolderOverTheLimitsIsRefused() throws {
        let files = try Fixture.unzipped(Fixture.epub())
        let url = try folder(files)
        // `mimetype`, `META-INF`, `OPS` and the files in them.
        let entries = files.count + 2
        var limits = EPUBImportLimits()
        limits.expandedBytes = files.values.reduce(0) { $0 + $1.count }
        limits.resourceBytes = files.values.map(\.count).max()!
        limits.entryCount = entries
        limits.archiveBytes = 1
        let largest = files.max { $0.value.count < $1.value.count }!.key
        _ = try EPUBPublication.open(at: url, limits: limits)
        var under = limits
        under.expandedBytes -= 1
        XCTAssertThrowsError(try EPUBPublication.open(at: url, limits: under)) {
            guard case .limitExceeded = $0 as? EPUBPublicationError else { return XCTFail("\($0)") }
        }
        under = limits
        under.resourceBytes -= 1
        XCTAssertThrowsError(try EPUBPublication.open(at: url, limits: under)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded(largest))
        }
        under = limits
        under.entryCount -= 1
        XCTAssertThrowsError(try EPUBPublication.open(at: url, limits: under)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("entry count"))
        }
        for value in [0, -1, Int.min] {
            under = EPUBImportLimits()
            under.entryCount = value
            XCTAssertThrowsError(try EPUBPublication.open(at: url, limits: under)) {
                XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("import limits"))
            }
        }
    }

    /// A file longer than a limit allows is refused by its length, unread, as a stored entry is
    /// by its declared size: here one of 8 GiB that the file system holds sparse.
    func testAFileOverTheLimitIsRefusedByItsLengthUnread() throws {
        let url = try folder(Fixture.unzipped(Fixture.epub()))
        let large = url.appending(path: "OPS/large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 8 << 30)
        try handle.close()
        let read = ReadCount()
        XCTAssertThrowsError(try EPUBPublication.open(at: url, onProgress: { read.set($0) })) {
            XCTAssertEqual($0 as? EPUBPublicationError, .limitExceeded("OPS/large.bin"))
        }
        XCTAssertLessThan(read.value, 1 << 20, "the file was not read")
    }

    /// Cancellation while the folder's files are read throws `CancellationError`.
    func testCancellationWhileReadingAFolderReturnsNoPublication() async throws {
        var files = try Fixture.unzipped(Fixture.epub())
        files["OPS/payload"] = Data(repeating: 0x78, count: 131_072)
        let url = try folder(files)
        let task = Task.detached {
            try EPUBPublication.open(at: url, onProgress: { read in
                if read > 32_768 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; XCTFail("Cancelled reading returned a publication") }
        catch is CancellationError {}
    }

    /// A file that cannot be read gives the system's error, with its path.
    func testAnUnreadableFileGivesTheSystemsError() throws {
        let url = try folder(Fixture.unzipped(Fixture.epub()))
        let file = url.appending(path: "OPS/two.xhtml")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        made.insert(file, at: 0)
        XCTAssertThrowsError(try EPUBPublication.open(at: url)) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EACCES, "\($0)")
            XCTAssertEqual(($0 as NSError).userInfo[NSFilePathErrorKey] as? String, "OPS/two.xhtml")
        }
    }

    /// What is not a folder is opened as a file, as before.
    func testWhatIsNotAFolderIsOpenedAsAFile() throws {
        let file = URL.temporaryDirectory.appending(path: "book-\(UUID().uuidString).epub")
        made.append(file)
        try Fixture.epub().write(to: file)
        XCTAssertEqual(try EPUBPublication.open(at: file).id,
                       SHA256.hash(data: try Fixture.epub()).map { String(format: "%02x", $0) }.joined())
        XCTAssertThrowsError(try EPUBPublication.open(at: file.appending(path: "missing"))) {
            XCTAssertNil($0 as? EPUBPublicationError, "\($0)")
        }
        XCTAssertThrowsError(try EPUBPublication.open(at: URL(string: "https://example.com/book.epub")!)) {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("https://example.com/book.epub"))
        }
    }

    /// #680: a position saved in the zipped book restores in the folder, which has its
    /// `persistentID`, with or without a unique identifier. Files the manifest does not list, as a
    /// Mac's Finder and Apple Books add them, change the folder's `id` and not its identity.
    func testAFolderHasTheIdentityOfItsZippedBook() throws {
        for (name, archive) in [("with a unique identifier", try Fixture.epub()),
                                ("without one", try Fixture.epub(overrides: ["OPS/book.opf": String(decoding: try Fixture.files()["OPS/book.opf"]!, as: UTF8.self)
                                    .replacingOccurrences(of: " unique-identifier=\"uid\"", with: "")]))] {
            let zipped = try EPUBPublication.open(data: archive)
            var files = try Fixture.unzipped(archive)
            let book = try EPUBPublication.open(at: folder(files))
            XCTAssertEqual(book.persistentID, zipped.persistentID, name)
            files[".DS_Store"] = Data([0, 0, 0, 1])
            files["iTunesMetadata.plist"] = Data("<plist/>".utf8)
            let added = try EPUBPublication.open(at: folder(files))
            XCTAssertEqual(added.persistentID, zipped.persistentID, name)
            XCTAssertNotEqual(added.id, book.id, name)
        }
    }
}

/// The last count an import reported, from whatever thread it reports on.
private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func set(_ value: Int) { lock.withLock { count = value } }
}
