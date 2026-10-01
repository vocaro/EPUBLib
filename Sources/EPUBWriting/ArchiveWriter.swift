import EPUBCore
import Foundation
import ZIPFoundation

/// Streams prepared files into OCF ZIP entries without loading assets into memory.
public enum EPUBArchiveWriter {
    public struct Entry: Sendable {
        public let path: String
        public let fileURL: URL
        /// Only temporary, producer-owned files may be consumed after their final use.
        public let consume: Bool
        public init(path: String, fileURL: URL, consume: Bool = false) {
            self.path = path; self.fileURL = fileURL; self.consume = consume
        }
    }

    /// Destination must be new. Cancellation/failure removes the unfinished archive.
    public static func write(entries: [Entry], to destination: URL, maximumContentBytes: Int64,
                             modificationDate: Date, progress: @Sendable (Double) async -> Void = { _ in }) async throws {
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path),
              maximumContentBytes > 0, entries.first?.path == "mimetype" else {
            throw EPUBWritingError.invalidPublication("archive destination, budget or mimetype order")
        }
        var paths: Set<String> = []
        var consumption: [URL: Bool] = [:]
        for entry in entries {
            guard ResourceReference.isSafePath(entry.path), paths.insert(entry.path).inserted,
                  entry.fileURL.isFileURL, entry.fileURL.standardizedFileURL != destination.standardizedFileURL else {
                throw EPUBWritingError.invalidPublication("duplicate or invalid entry: \(entry.path)")
            }
            // A caller-owned reference keeps a shared file alive even if another entry consumes it.
            consumption[entry.fileURL] = (consumption[entry.fileURL] ?? true) && entry.consume
        }
        let mime = try FileHandle(forReadingFrom: entries[0].fileURL)
        defer { try? mime.close() }
        guard try mime.read(upToCount: 20) == Data("application/epub+zip".utf8) else {
            throw EPUBWritingError.invalidPublication("invalid mimetype")
        }
        var remainingUses = Dictionary(grouping: entries, by: \.fileURL).mapValues(\.count)
        await progress(0)
        try Task.checkCancellation()
        let archive = try Archive(url: destination, accessMode: .create)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        var bytes: Int64 = 0
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let size = try entry.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size >= 0, Int64(size) <= maximumContentBytes - bytes else {
                throw EPUBWritingError.resourceLimit("EPUB total size")
            }
            bytes += Int64(size)
            let handle = try FileHandle(forReadingFrom: entry.fileURL)
            defer { try? handle.close() }
            try archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(size),
                                 modificationDate: modificationDate,
                                 compressionMethod: entry.path == "mimetype" ? .none : .deflate) { position, count in
                try autoreleasepool {
                    try Task.checkCancellation()
                    try handle.seek(toOffset: UInt64(position))
                    return try handle.read(upToCount: count) ?? Data()
                }
            }
            try handle.close()
            remainingUses[entry.fileURL, default: 1] -= 1
            if consumption[entry.fileURL] == true, remainingUses[entry.fileURL] == 0 {
                try FileManager.default.removeItem(at: entry.fileURL)
            }
            await progress(Double(index + 1) / Double(entries.count))
        }
        completed = true
    }
}
