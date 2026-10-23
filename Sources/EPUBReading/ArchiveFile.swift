import EPUBCore
import Foundation

/// The bytes of the file a book is opened from (`EPUBPublication.open(at:)`), read no further than
/// opening them needs.
///
/// Opening refuses bytes longer than the archive limit by their length, and bytes with no end
/// record where one can begin by their last 65,557 and their first four (`ArchiveEndRecord`). A
/// file was read whole before either was looked at, so one of the 256 MiB a book may be that is
/// no book was 256 MiB read and allocated to be refused by what a few of its bytes say, and a
/// longer one as much again (#208). A file's length is now taken first, and where it has more
/// bytes than a record reaches, its ends are read; the whole file is read only when they leave it
/// a possible archive, and opening then reads those bytes as it reads any others. What is refused
/// this way is refused as opening its bytes refuses them, and by the same order of checks:
/// cancellation, the limits, then the end record.
///
/// A pipe or a socket, which cannot be read at an offset, has no length to take, and a device
/// gives none; each is read from its first byte as far as the limit allows, as before, and so is
/// a file whose ends cannot be read where its length puts them.
struct ArchiveFile {
    let handle: FileHandle
    /// How many of the file's bytes have been read.
    private(set) var bytesRead = 0

    init(handle: FileHandle) { self.handle = handle }

    /// The file's bytes from its first, as many as one more than `limits.archiveBytes`; or what
    /// `EPUBPublication.open(data:)` would throw for them, when the length or the ends say.
    mutating func bytes(limits: EPUBImportLimits) throws -> Data {
        if let length = try length() {
            try Task.checkCancellation()
            try limits.admit(archiveBytes: length)
            if length > ArchiveEndRecord.maximumLength, let refusal = refusal(length: length) { throw refusal }
        }
        let data = try handle.read(upToCount: limits.archiveBytes + 1) ?? Data()
        bytesRead += data.count
        return data
    }

    /// The length of a file that can be read at an offset, or nil for one that cannot: a pipe or
    /// a socket. It is the offset of the file's end, which the handle is moved back from to the
    /// file's first byte. `fstat` would tell a regular file from the rest, but it reads a file's
    /// timestamps too, an API that an app has to declare in its privacy manifest (#685). A
    /// device, `/dev/null` or `/dev/zero`, gives an end of 0, and is read from its first byte as
    /// any file of that length is.
    private func length() throws -> Int? {
        let end = lseek(handle.fileDescriptor, 0, SEEK_END)
        guard end >= 0 else { return nil }
        try handle.seek(toOffset: 0)
        return Int(exactly: end)
    }

    /// What the ends of a file of `length` bytes, more than a record reaches, refuse it as; nil
    /// when they leave it a possible archive, or cannot be read.
    private mutating func refusal(length: Int) -> EPUBPublicationError? {
        guard let tail = read(ArchiveEndRecord.maximumLength, at: length - ArchiveEndRecord.maximumLength) else { return nil }
        switch tail.withUnsafeBytes(ArchiveEndRecord.ending) {
        case .record: return nil
        case .cutShort: break
        case .none:
            guard let head = read(4, at: 0) else { return nil }
            if head.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }) == ArchiveEndRecord.localFileHeader {
                return nil
            }
        }
        // What `open(data:)` reports for bytes with no end record.
        return .notArchive
    }

    /// `count` bytes from `offset`, read without moving the handle from the file's first byte;
    /// nil when the file holds fewer there, or they cannot be read.
    private mutating func read(_ count: Int, at offset: Int) -> Data? {
        var data = Data(count: count)
        let done = data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let result = pread(handle.fileDescriptor, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset + done))
                if result > 0 { done += result } else if result < 0, errno == EINTR { continue } else { break }
            }
            return done
        }
        bytesRead += done
        return done == count ? data : nil
    }
}

extension EPUBImportLimits {
    /// Throws `limitExceeded("import limits")` unless every limit is more than zero and an archive
    /// of `count` bytes is within `archiveBytes`.
    func admit(archiveBytes count: Int) throws {
        guard archiveBytes > 0, count <= archiveBytes, resourceBytes > 0, expandedBytes > 0, entryCount > 0,
              xmlBytes > 0 else { throw EPUBPublicationError.limitExceeded("import limits") }
    }
}
