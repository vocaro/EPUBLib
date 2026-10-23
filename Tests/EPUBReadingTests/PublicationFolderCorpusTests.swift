import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
import ZIPFoundation

/// Books unpacked into folders, read as folders and as archives
/// (https://github.com/vocaro/EPUBLib/issues/680): the W3C's reading-system tests and EPUBCheck's
/// expanded fixtures, which are folders, against the archives packed from them, and EPUBCheck's
/// archived fixtures and the Project Gutenberg and Standard Ebooks books, which are archives,
/// against the folders unzipped from them. Each must open to the same publication or be refused
/// alike. The one difference allowed is `mimetype`, which a folder may lack: such a folder is held
/// to the archive packed with one. Each book, zipped again and stored, must keep its
/// `persistentID` and change its `id` (#679).
///
/// Each test is skipped unless its variable is set: `EPUBLIB_W3C_EPUB_TESTS`,
/// `EPUBLIB_EPUBCHECK_FIXTURES`, `EPUBLIB_GUTENBERG` or `EPUBLIB_STANDARD_EBOOKS`, as
/// `scripts/fetch-corpora.sh` prints them. Folders are unzipped under the temporary directory and
/// removed after each book. The corpora are data: nothing in them is executed.
final class PublicationFolderCorpusTests: XCTestCase {
    private enum Outcome {
        case opened(EPUBPublication)
        case refused(String)

        init(_ open: () throws -> EPUBPublication) {
            do { self = .opened(try open()) } catch { self = .refused(String(describing: error)) }
        }
    }

    /// What differs between the two readings, or nil when nothing does.
    private func difference(_ folder: Outcome, _ archive: Outcome) -> String? {
        switch (folder, archive) {
        case (.refused(let a), .refused(let b)): return a == b ? nil : "refused as \(a), the archive as \(b)"
        case (.refused(let a), .opened): return "refused as \(a), the archive opened"
        case (.opened, .refused(let b)): return "opened, the archive refused as \(b)"
        case (.opened(let a), .opened(let b)):
            var differences: [String] = []
            func compare<T: Equatable>(_ name: String, _ x: T, _ y: T) { if x != y { differences.append(name) } }
            compare("metadata", a.metadata, b.metadata)
            compare("resources", a.resources, b.resources)
            compare("spine", a.spine, b.spine)
            compare("contents", a.tableOfContents, b.tableOfContents)
            compare("landmarks", a.landmarks, b.landmarks)
            compare("page list", a.pageList, b.pageList)
            compare("cover", a.cover, b.cover)
            compare("progression", a.pageProgression, b.pageProgression)
            compare("unique identifier", a.uniqueIdentifier, b.uniqueIdentifier)
            compare("release identifier", a.releaseIdentifier, b.releaseIdentifier)
            compare("persistentID", a.persistentID, b.persistentID)
            compare("publication IDs", Array(a.publicationIDs.dropLast()), Array(b.publicationIDs.dropLast()))
            for resource in b.resources where (try? a.data(for: resource)) != (try? b.data(for: resource)) {
                differences.append("bytes of \(resource.path)")
            }
            return differences.isEmpty ? nil : "differs in " + differences.joined(separator: ", ")
        }
    }

    private struct Tally {
        var opened = 0, refused = 0, withoutMimetype = 0, skipped: [String] = [], differences: [String] = []
        mutating func count(_ outcome: Outcome) {
            if case .opened = outcome { opened += 1 } else { refused += 1 }
        }
        func report(_ name: String) {
            print("\(name): \(opened) opened alike, \(refused) refused alike, \(withoutMimetype) folders without mimetype, "
                  + "\(skipped.count) skipped, \(differences.count) differences")
            for line in skipped { print("  skipped \(line)") }
            for line in differences { print("  DIFFERENCE \(line)") }
        }
    }

    /// Reads the folder at `url` and the archive of `files`, its files as packed, and tallies.
    private func compare(folder url: URL, files: [String: Data], name: String, tally: inout Tally) throws {
        let folder = Outcome { try EPUBPublication.open(at: url) }
        var packed = files
        if packed["mimetype"] == nil {
            tally.withoutMimetype += 1
            packed["mimetype"] = Data("application/epub+zip".utf8)
        }
        let archive = Outcome { try EPUBPublication.open(data: Fixture.archive(packed)) }
        if let difference = difference(folder, archive) { tally.differences.append("\(name): \(difference)") } else { tally.count(folder) }
    }

    /// Unzips the archive at `url` into a folder, when it opens whole, and compares the two.
    private func compare(archiveAt url: URL, name: String, tally: inout Tally, rezip: Bool = false) throws {
        let data = try Data(contentsOf: url)
        guard case .opened(let zipped) = Outcome({ try EPUBPublication.open(data: data) }) else {
            tally.skipped.append("\(name): the archive is refused, and there is nothing whole to unzip")
            return
        }
        guard zipped.lostEntries == nil, let files = try? Fixture.unzipped(data),
              files.count == (try Archive(data: data, accessMode: .read)).filter({ $0.type == .file }).count else {
            tally.skipped.append("\(name): entries that cannot be unzipped as they stand")
            return
        }
        // A path that is a file and a folder's too, or a name the file system refuses.
        let parent = URL.temporaryDirectory.appending(path: "unzipped-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder: URL
        do { folder = try Fixture.folder(files, in: parent) } catch {
            tally.skipped.append("\(name): the file system does not hold its entries as they stand: \(error.localizedDescription)")
            return
        }
        // Names that differ only in case are one file on a file system that ignores case, as a
        // Mac's does unless told otherwise; that folder is not the archive's container.
        let written = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile } }
            .filter { $0 }.count
        guard written == files.count else {
            tally.skipped.append("\(name): the file system holds \(written ?? 0) files for its \(files.count) entries")
            return
        }
        let unzipped = Outcome { try EPUBPublication.open(at: folder) }
        if let difference = difference(unzipped, .opened(zipped)) { tally.differences.append("\(name): \(difference)"); return }
        tally.count(unzipped)
        // #679 on a real book: zipped again, stored, it is the same book.
        if rezip, case .opened(let stored) = Outcome({ try EPUBPublication.open(data: Fixture.rezipped(files, compression: .none)) }),
           stored.persistentID != zipped.persistentID || stored.id == zipped.id {
            tally.differences.append("\(name): zipped again, its persistentID changed or its id did not")
        }
    }

    func testEveryW3CTestReadsAlikeAsAFolderAndAsAnArchive() throws {
        guard let root = ProcessInfo.processInfo.environment[SpecConformanceCorpus.environmentKey].map(URL.init(fileURLWithPath:)) else {
            throw XCTSkip("Set \(SpecConformanceCorpus.environmentKey) to the tests directory of w3c/epub-tests")
        }
        var tally = Tally()
        let tests = try SpecConformanceCorpus.testDirectories(under: root)
        XCTAssertGreaterThan(tests.count, 150)
        for test in tests {
            try compare(folder: test.url, files: SpecConformanceCorpus.files(ofExpandedEPUBAt: test.url), name: test.id, tally: &tally)
        }
        tally.report("W3C epub-tests")
        XCTAssertEqual(tally.differences, [])
        XCTAssertEqual(tally.opened + tally.refused, tests.count)
    }

    func testEveryEPUBCheckPublicationReadsAlikeAsAFolderAndAsAnArchive() throws {
        guard let root = EPUBCheckCorpus.root() else {
            throw XCTSkip("Set \(EPUBCheckCorpus.environmentKey) to src/test/resources of an EPUBCheck checkout")
        }
        var folders = Tally(), archives = Tally()
        let items = EPUBCheckCorpus.publications(under: root)
        XCTAssertGreaterThan(items.count, 400)
        for item in items {
            if item.isDirectory {
                var files: [String: Data] = [:]
                for file in EPUBCheckCorpus.files(under: item.url) { files[file.path] = try Data(contentsOf: file.url) }
                try compare(folder: item.url, files: files, name: item.path, tally: &folders)
            } else {
                try compare(archiveAt: item.url, name: item.path, tally: &archives)
            }
        }
        folders.report("EPUBCheck expanded fixtures")
        archives.report("EPUBCheck archived fixtures, unzipped")
        XCTAssertEqual(folders.differences, [])
        XCTAssertEqual(archives.differences, [])
        XCTAssertGreaterThan(folders.opened + folders.refused, 100)
        XCTAssertGreaterThan(archives.opened, 10)
    }

    func testEveryGutenbergBookUnzippedReadsAlikeAsAFolder() throws {
        try compareBooks("EPUBLIB_GUTENBERG", "Project Gutenberg")
    }

    func testEveryStandardEbooksBookUnzippedReadsAlikeAsAFolder() throws {
        try compareBooks("EPUBLIB_STANDARD_EBOOKS", "Standard Ebooks")
    }

    /// Every book of the collection `key` names, unzipped and zipped again.
    private func compareBooks(_ key: String, _ name: String) throws {
        guard let root = ProcessInfo.processInfo.environment[key].map(URL.init(fileURLWithPath:)) else {
            throw XCTSkip("Set \(key) with scripts/fetch-corpora.sh")
        }
        var tally = Tally()
        let books = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "epub" }.sorted { $0.path < $1.path }
        XCTAssertEqual(books.count, 50)
        for book in books { try compare(archiveAt: book, name: book.lastPathComponent, tally: &tally, rezip: true) }
        tally.report(name)
        XCTAssertEqual(tally.differences, [])
        XCTAssertEqual(tally.opened, books.count)
    }
}
