import EPUBCore
import EPUBWriting
import Foundation
import Testing

/// A failure to write a book has a plain message, which a host shows as it is
/// (https://github.com/vocaro/EPUBLib/issues/698).
struct WritingErrorMessageTests {
    /// The message for each case. The switch has no default: a case added to the enum does not
    /// compile here until its message is written down.
    private static func expected(_ error: EPUBWritingError) -> String {
        switch error {
        case .invalidPublication: "This book cannot be saved as an EPUB because it has errors."
        case .resourceLimit: "This book is too large to save as an EPUB."
        }
    }

    private var facts: EPUBPackageMetadata {
        .init(metadata: .init(title: "A Book", languages: ["en"]), identifier: "urn:test:book",
              modificationDate: Date(timeIntervalSince1970: 0))
    }

    @Test func eachFailureToWriteABookHasAPlainMessage() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WritingErrorMessageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mimetype = folder.appending(path: "mimetype")
        try Data("application/epub+zip".utf8).write(to: mimetype)
        let asset = folder.appending(path: "asset")
        try Data(repeating: 1, count: 100).write(to: asset)
        var thrown: [EPUBWritingError] = []
        do { _ = try EPUBPackageWriter.documents(metadata: facts, resources: [], spine: [], contents: []) }
        catch let error as EPUBWritingError { thrown.append(error) }
        do {
            try await EPUBArchiveWriter.write(entries: [.init(path: "mimetype", fileURL: mimetype), .init(path: "EPUB/asset", fileURL: asset)],
                                              to: folder.appending(path: "book.epub"), maximumContentBytes: 20,
                                              modificationDate: facts.modificationDate)
        } catch let error as EPUBWritingError { thrown.append(error) }
        #expect(thrown == [.invalidPublication("empty spine"), .resourceLimit("EPUB total size")])
        for error in thrown {
            #expect(error.localizedDescription == Self.expected(error))
            #expect((error as NSError).localizedRecoverySuggestion == nil)
            #expect(!error.localizedDescription.localizedCaseInsensitiveContains("spine"))
            #expect(String(describing: error).contains("EPUB total size") || String(describing: error).contains("empty spine"))
        }
        // Each message is in the module's string catalog, which holds no other (#684).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Sources/EPUBWriting/Localizable.xcstrings"))) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(Set(strings.keys) == Set(thrown.map(Self.expected)))
        #expect(strings.values.allSatisfy { !(($0["comment"] as? String) ?? "").isEmpty })
    }
}
