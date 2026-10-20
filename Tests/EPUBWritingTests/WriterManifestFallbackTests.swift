import EPUBCore
import EPUBReading
import EPUBWriting
import Foundation
import Testing

struct WriterManifestFallbackTests {
    @Test func designatedFallbacksRoundTripThroughTheWrittenManifest() async throws {
        let original = EPUBResource(id: "source", path: "EPUB/source.json", mediaType: "application/json", fallbackID: "middle")
        let middle = EPUBResource(id: "middle", path: "EPUB/middle.bin", mediaType: "application/x-foreign", fallbackID: "static")
        let final = EPUBResource(id: "static", path: "EPUB/static.xhtml", mediaType: "application/xhtml+xml")
        let resources = [original, middle, final]
        let docs = try EPUBPackageWriter.documents(metadata: WriterCoverage.facts(), resources: resources,
                                                  spine: [.init(resource: original)], contents: [.init(title: "Source", href: original.href)])
        let directory = try WriterCoverage.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try await WriterCoverage.archive(docs, content: [original.path: Data("{}".utf8), middle.path: Data("foreign".utf8),
                                                       final.path: WriterCoverage.xhtml("<p>Readable</p>")], in: directory)
        let reopened = try EPUBPublication.open(at: archive)
        #expect(reopened.spine[0].resource == original)
        #expect(reopened.fallbackChain(for: reopened.spine[0].resource) == resources)
    }

    @Test func cyclicFallbacksAreRefusedByTheWriter() {
        let a = EPUBResource(id: "a", path: "EPUB/a.json", mediaType: "application/json", fallbackID: "b")
        let b = EPUBResource(id: "b", path: "EPUB/b.json", mediaType: "application/json", fallbackID: "a")
        #expect(throws: EPUBWritingError.invalidPublication("cyclic manifest fallback: a")) {
            try EPUBPackageWriter.documents(metadata: WriterCoverage.facts(), resources: [a, b], spine: [.init(resource: a)], contents: [])
        }
    }

    @Test func undeclaredFallbackIDsAreRefusedByTheWriter() {
        let original = EPUBResource(id: "source", path: "EPUB/source.json", mediaType: "application/json", fallbackID: "absent")
        #expect(throws: EPUBWritingError.invalidPublication("fallback references an undeclared resource: absent")) {
            try EPUBPackageWriter.documents(metadata: WriterCoverage.facts(), resources: [original],
                                            spine: [.init(resource: original)], contents: [])
        }
    }
}
