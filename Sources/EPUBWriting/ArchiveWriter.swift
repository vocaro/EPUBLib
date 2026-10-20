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
            let source = entry.fileURL.standardizedFileURL
            consumption[source] = (consumption[source] ?? true) && entry.consume
        }
        // The source must be exactly the mimetype (EPUB 3.3, 4.3.3: no padding or whitespace).
        // One byte past it is read, so trailing bytes are refused without reading a large file.
        let mimetype = Data("application/epub+zip".utf8)
        let mime = try FileHandle(forReadingFrom: entries[0].fileURL)
        defer { try? mime.close() }
        guard try mime.read(upToCount: mimetype.count + 1) == mimetype else {
            throw EPUBWritingError.invalidPublication("invalid mimetype")
        }
        var remainingUses = Dictionary(grouping: entries, by: { $0.fileURL.standardizedFileURL }).mapValues(\.count)
        await progress(0)
        try Task.checkCancellation()
        let archive = try Archive(url: destination, accessMode: .create)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        var bytes: Int64 = 0
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: entry.fileURL)
            defer { try? handle.close() }
            // Measure the opened file, so a symbolic link's target supplies both size and bytes.
            guard let size = Int64(exactly: try handle.seekToEnd()), size <= maximumContentBytes - bytes else {
                throw EPUBWritingError.resourceLimit("EPUB total size")
            }
            bytes += size
            try archive.addEntry(with: entry.path, type: .file, uncompressedSize: size,
                                 modificationDate: modificationDate,
                                 compressionMethod: entry.path == "mimetype" ? .none : .deflate) { position, count in
                try autoreleasepool {
                    try Task.checkCancellation()
                    try handle.seek(toOffset: UInt64(position))
                    return try handle.read(upToCount: count) ?? Data()
                }
            }
            try handle.close()
            let source = entry.fileURL.standardizedFileURL
            remainingUses[source, default: 1] -= 1
            if consumption[source] == true, remainingUses[source] == 0 {
                try FileManager.default.removeItem(at: entry.fileURL)
            }
            await progress(Double(index + 1) / Double(entries.count))
        }
        completed = true
    }
}
