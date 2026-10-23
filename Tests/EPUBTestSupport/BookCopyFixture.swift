import Foundation
import ZIPFoundation

/// Copies of one book, as a reader comes to have them: zipped again with other compression, its
/// package document edited, or unpacked into a folder (#679, #680).
public extension Fixture {
    /// `files` zipped with `compression`, `mimetype` first and stored, the rest in reverse order of
    /// their paths, unlike `archive(_:)`, so that no byte of the archive need match its.
    static func rezipped(_ files: [String: Data], compression: CompressionMethod) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for name in files.keys.sorted(by: { a, b in a == "mimetype" || (b != "mimetype" && a > b) }) {
            let bytes = files[name]!
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count),
                                 compressionMethod: name == "mimetype" ? .none : compression) { position, size in
                bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return archive.data!
    }

    /// The files of an archive, by the UTF-8 their entries' names are written in, which `zip` and
    /// `ditto` write without saying so; as they were zipped, an obfuscated font left obfuscated.
    static func unzipped(_ data: Data) throws -> [String: Data] {
        let archive = try Archive(data: data, accessMode: .read)
        var files: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            var bytes = Data()
            _ = try archive.extract(entry, skipCRC32: false) { bytes.append($0) }
            files[entry.path(using: .utf8)] = bytes
        }
        return files
    }

    /// A new folder under `parent` holding `files` by their paths, each name written as its bytes
    /// are, decomposed or not. The caller removes it.
    static func folder(_ files: [String: Data], in parent: URL = URL.temporaryDirectory) throws -> URL {
        let folder = parent.appending(path: "book-\(UUID().uuidString).epub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, bytes) in files {
            let url = folder.appending(path: path, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        return folder
    }
}
