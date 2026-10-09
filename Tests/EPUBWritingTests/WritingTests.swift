import EPUBCore
import EPUBReading
import EPUBText
import EPUBWriting
import Foundation
import Testing
import ZIPFoundation

struct WritingTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var facts: EPUBPackageMetadata {
        .init(metadata: .init(title: "Fish & Chips", authors: ["An Author"], languages: ["en"]),
              identifier: "urn:test:book", modificationDate: Date(timeIntervalSince1970: 0))
    }

    @Test func writtenPublicationReadsBackWithNavigationAndAnchoredText() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chapter = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
        let docs = try EPUBPackageWriter.documents(metadata: facts, resources: [chapter],
            spine: [.init(resource: chapter)], contents: [.init(title: "A & B", href: "EPUB/one.xhtml#start")],
            pages: [.init(title: "1", href: "EPUB/one.xhtml#start"), .init(title: "2", href: "EPUB/one.xhtml#middle")])
        var entries: [EPUBArchiveWriter.Entry] = []
        for doc in docs.sorted(by: { $0.path == "mimetype" || ($1.path != "mimetype" && $0.path < $1.path) }) {
            let url = dir.appendingPathComponent(doc.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try doc.content.write(to: url, atomically: true, encoding: .utf8)
            entries.append(.init(path: doc.path, fileURL: url))
        }
        let url = dir.appendingPathComponent(chapter.path)
        try "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Chapter</title></head><body><h1 id=\"start\">First</h1><p>Two <span id=\"middle\">é words</span>.</p><p id=\"end\"/></body></html>".write(to: url, atomically: true, encoding: .utf8)
        entries.append(.init(path: chapter.path, fileURL: url))
        let archive = dir.appendingPathComponent("book.epub")
        try await EPUBArchiveWriter.write(entries: entries, to: archive, maximumContentBytes: 1_000_000,
                                         modificationDate: facts.modificationDate)
        let publication = try EPUBPublication.open(at: archive)
        #expect(publication.metadata.title == "Fish & Chips")
        #expect(publication.metadata.authors == ["An Author"])
        #expect(publication.tableOfContents == [.init(title: "A & B", href: "EPUB/one.xhtml#start")])
        #expect(publication.pageList == [.init(label: "1", href: "EPUB/one.xhtml#start"), .init(label: "2", href: "EPUB/one.xhtml#middle")])
        let text = try publication.textSection(at: 0)
        #expect(text.text == "First\nTwo é words.")
        #expect(text.headings == [.init(mark: .init(offset: 0, separator: 0), text: "First")])
        #expect(text.anchors["middle"] == .init(offset: 10, separator: 1))
        #expect(text.anchors["end"] == .init(offset: text.text.utf8.count, separator: 0))
        let zip = try Archive(url: archive, accessMode: .read)
        #expect(Array(zip).first?.path == "mimetype")
        let archiveBytes = try Data(contentsOf: archive)
        #expect(archiveBytes[8] == 0 && archiveBytes[9] == 0) // First local header: stored, not deflated.
    }

    @Test func rejectsDuplicateResourcesAndUnknownNavigationTargets() throws {
        let resource = EPUBResource(id: "c", path: "EPUB/one.xhtml", mediaType: "application/xhtml+xml")
        #expect(throws: EPUBWritingError.self) {
            try EPUBPackageWriter.documents(metadata: facts, resources: [resource, resource],
                spine: [.init(resource: resource)], contents: [])
        }
        #expect(throws: EPUBWritingError.self) {
            try EPUBPackageWriter.documents(metadata: facts, resources: [resource],
                spine: [.init(resource: resource)], contents: [.init(title: "Missing", href: "EPUB/missing.xhtml")])
        }
    }

    @Test func failedBudgetRemovesPartialArchiveAndKeepsCallerFiles() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mime = dir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mime, atomically: true, encoding: .utf8)
        let asset = dir.appendingPathComponent("asset")
        try Data(repeating: 1, count: 100).write(to: asset)
        let output = dir.appendingPathComponent("output.epub")
        await #expect(throws: EPUBWritingError.resourceLimit("EPUB total size")) {
            try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime),
                .init(path: "EPUB/asset", fileURL: asset)], to: output, maximumContentBytes: 20,
                modificationDate: facts.modificationDate)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: asset.path))
    }

    @Test func sharedCallerAssetSurvivesAConsumingReference() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mime = dir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mime, atomically: true, encoding: .utf8)
        let asset = dir.appendingPathComponent("asset")
        try Data([1, 2, 3]).write(to: asset)
        try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime),
            .init(path: "EPUB/a", fileURL: asset, consume: true), .init(path: "EPUB/b", fileURL: asset)],
            to: dir.appendingPathComponent("book.epub"), maximumContentBytes: 100,
            modificationDate: facts.modificationDate)
        #expect(FileManager.default.fileExists(atPath: asset.path))
    }
    @Test func cancellationAfterAnEntryRemovesThePartialArchive() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mime = dir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mime, atomically: true, encoding: .utf8)
        let asset = dir.appendingPathComponent("asset")
        try Data(repeating: 1, count: 100).write(to: asset)
        let output = dir.appendingPathComponent("output.epub")
        let modificationDate = facts.modificationDate
        let task = Task {
            try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mime),
                .init(path: "EPUB/asset", fileURL: asset)], to: output, maximumContentBytes: 1_000,
                modificationDate: modificationDate) { fraction in
                    if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: asset.path))
    }

}
