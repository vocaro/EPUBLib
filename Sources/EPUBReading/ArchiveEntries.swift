import EPUBCore
import Foundation
import ZIPFoundation

/// Reads an archive's entries for `EPUBPublication.open`: every one as it opens, or, for a book
/// opened on demand (`EPUBPublication.open(at:limits:onDemand:)`), each when it is first asked for.
///
/// An entry is read as opening has read one since #74: by its stream, not by the size it
/// declares, and held to its checksum, `resourceBytes`, `expandedBytes` and the archive's input
/// work (`ArchiveInputWork`). A book opened on demand is charged once for each entry it reads,
/// however often that entry is asked for, so its limits count what the entries it reads inflate
/// to, as a book read whole has them count every entry. A read that fails is charged nothing,
/// and fails again the same way if it is asked for again.
///
/// The publication keeps the reader of a book opened on demand, and its sections may be built on
/// several threads at once, so reads are serialized: ZIPFoundation reads a stored entry through
/// one file position.
final class ArchiveEntries: @unchecked Sendable {
    private let lock = NSLock()
    private let archive: Archive
    /// The bytes `archive` reads, whatever it was made from.
    private let bytes: Data
    private let directory: ArchiveBounds.Directory
    private let limits: EPUBImportLimits
    private let onProgress: (@Sendable (Int) -> Void)?
    private var inputWork: ArchiveInputWork
    /// Expanded bytes charged against `expandedBytes`.
    private var total = 0
    /// Entries not yet read, by path, with their place in the directory.
    private var pending: [String: (index: Int, entry: Entry)] = [:]
    /// Entries read on demand, which reading again charges nothing.
    private var charged: Set<String> = []

    init(archive: Archive, bytes: Data, directory: ArchiveBounds.Directory, limits: EPUBImportLimits,
         onProgress: (@Sendable (Int) -> Void)?) {
        self.archive = archive; self.bytes = bytes; self.directory = directory; self.limits = limits
        self.onProgress = onProgress
        inputWork = ArchiveInputWork(archiveBytes: bytes.count)
    }

    /// Reads `entry`, the one at `index` in the directory, charging it against the limits.
    func read(_ entry: Entry, index: Int, path: String) throws -> Data {
        try lock.withLock { try charge(entry, index: index, path: path) }
    }

    /// Leaves `entry` to be read when it is asked for.
    func hold(_ entry: Entry, index: Int, path: String) {
        lock.withLock { pending[path] = (index, entry) }
    }

    /// Whether an entry not yet read is at `path`.
    func holds(_ path: String) -> Bool { lock.withLock { pending[path] != nil } }

    /// The paths of the entries not yet read.
    var paths: [String] { lock.withLock { Array(pending.keys) } }

    /// The entry at `path`, read and no longer held for later; nil when none is held there.
    func take(_ path: String) throws -> Data? {
        try lock.withLock {
            guard let (index, entry) = pending[path] else { return nil }
            let data = try charge(entry, index: index, path: path)
            pending[path] = nil
            return data
        }
    }

    /// Leaves the entry at `path` unread for good: a font obfuscated with a key the package does
    /// not give.
    func remove(_ path: String) { lock.withLock { pending[path] = nil } }

    /// The entry at `path`, read now, and again each time it is asked for; nil when no entry not
    /// yet read at opening is there. Read without `charging`, it is held to `resourceBytes` alone
    /// and counts toward nothing, as opening reads an entry to hash it.
    func data(at path: String, charging: Bool = true) throws -> Data? {
        try lock.withLock {
            guard let (index, entry) = pending[path] else { return nil }
            if charged.contains(path) || !charging {
                // Read before within the limits, and from the same bytes, or read to be hashed:
                // charged nothing.
                var work = ArchiveInputWork(archiveBytes: bytes.count), sum = 0
                return try Self.extract(entry, index: index, path: path, archive: archive, bytes: bytes, directory: directory,
                                        limits: limits, inputWork: &work, total: &sum, onProgress: nil)
            }
            let data = try charge(entry, index: index, path: path)
            charged.insert(path)
            return data
        }
    }

    /// Expanded bytes the entries read so far were charged.
    var expandedBytes: Int { lock.withLock { total } }

    /// Reads an entry against the limits, and charges it only when it is read whole.
    private func charge(_ entry: Entry, index: Int, path: String) throws -> Data {
        var work = inputWork, sum = total
        let data = try Self.extract(entry, index: index, path: path, archive: archive, bytes: bytes, directory: directory,
                                    limits: limits, inputWork: &work, total: &sum, onProgress: onProgress)
        inputWork = work
        total = sum
        return data
    }

    private static func extract(_ entry: Entry, index: Int, path: String, archive: Archive, bytes archiveBytes: Data,
                                directory: ArchiveBounds.Directory, limits: EPUBImportLimits,
                                inputWork: inout ArchiveInputWork, total: inout Int,
                                onProgress: (@Sendable (Int) -> Void)?) throws -> Data {
        // An entry that declares more than a limit allows is refused before it is read,
        // unless it is compressed. A compressed entry is not read by its declared size,
        // which may be wrong either way with its data whole: a deflated one is held to the
        // limits below, by what it inflates to, and one in any other method is not read.
        // A data descriptor's size is read by the form of the descriptor's own bytes, not the
        // one ZIPFoundation takes from the entry's version and ZIP64 field (`DataDescriptor`).
        let declared = directory.describedSizes[index] ?? entry.uncompressedSize
        guard entry.isCompressed || (declared <= UInt64(limits.resourceBytes)
                                     && declared <= UInt64(limits.expandedBytes - total)) else {
            throw EPUBPublicationError.limitExceeded(path)
        }
        var bytes = Data()
        inputWork.beginEntry()
        let crc: CRC32
        do {
            func consume(_ chunk: Data) throws {
                try Task.checkCancellation()
                guard chunk.count <= limits.resourceBytes - bytes.count,
                      chunk.count <= limits.expandedBytes - total else {
                    throw EPUBPublicationError.limitExceeded(path)
                }
                try inputWork.consume(outputBytes: chunk.count)
                bytes.append(chunk)
                total += chunk.count
                onProgress?(total)
                try Task.checkCancellation()
            }
            // A deflated entry is inflated with zlib, not by ZIPFoundation, whose decoder
            // gives the same damaged stream different results on different opens (#583).
            if let deflated = directory.deflatedData[index] {
                crc = try archiveBytes.withUnsafeBytes {
                    try DeflateStream.inflate(UnsafeRawBufferPointer(rebasing: $0[deflated]),
                                              chunkSize: ArchiveInputWork.chunkSize, consumer: consume)
                }
            } else {
                crc = try archive.extract(entry, bufferSize: ArchiveInputWork.chunkSize, consumer: consume)
            }
        }
        catch let error as EPUBPublicationError { throw error }
        catch let error as CancellationError { throw error }
        // A method other than stored and Deflate, or a stream that does not inflate, is
        // damage in the archive however much the entry declares: what it declares is not
        // trusted, and a limit is exceeded only by bytes it inflates to (#74).
        catch { throw EPUBPublicationError.invalidArchive("\(path): \(error)") }
        guard crc == entry.checksum else { throw EPUBPublicationError.invalidArchive("CRC: \(path)") }
        return bytes
    }
}
