import Foundation

/// Where an archive's end-of-central-directory record is looked for.
///
/// The record is 22 bytes and a comment of at most 65,535 (APPNOTE.TXT 4.3.16), and it ends the
/// archive, so its signature begins in the last 65,557 bytes or the bytes are no ZIP archive.
/// ZIPFoundation 0.9.20 looks for the signature at every offset back to the first, with a seek
/// and a read for each: about a fifth of a second for each mebibyte it finds none in, and a
/// minute for a file of the size a book may be. A book is untrusted input and may be any file
/// at all, so opening looks in those last bytes first and gives ZIPFoundation only bytes in
/// which it finds a signature that soon.
///
/// Nor does ZIPFoundation close the file it opens over bytes it then refuses, and that file
/// keeps them: every such refusal costs the process the size of what it was offered, for good.
/// It refuses bytes it finds no signature in and bytes whose record gives a comment longer than
/// what follows it, and none for anything else in them. Opening refuses both first
/// (`readableOffset(in:)`), so ZIPFoundation is given only bytes it makes an archive of, which
/// closes that file when it goes.
enum ArchiveEndRecord {
    /// The length of a record with the longest comment.
    static let maximumLength = 22 + 65_535

    /// The offset of the signature ZIPFoundation takes for the end record's: the last one that
    /// has 22 bytes or more from it to the end, whatever they hold. nil when none begins in the
    /// last `maximumLength` bytes; the bytes before those are not read.
    static func offset(in bytes: UnsafeRawBufferPointer) -> Int? {
        let first = max(0, bytes.count - maximumLength)
        var offset = bytes.count - 22
        while offset >= first {
            if UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) == 0x0605_4b50 { return offset }
            offset -= 1
        }
        return nil
    }

    /// `offset(in:)` when ZIPFoundation can read the record there: the bytes after its 22 are
    /// no fewer than the comment length it gives. nil when they are fewer, as when there is no
    /// signature; ZIPFoundation looks no further back for another record either.
    static func readableOffset(in bytes: UnsafeRawBufferPointer) -> Int? {
        guard let offset = offset(in: bytes) else { return nil }
        let commentLength = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 20, as: UInt16.self)))
        return commentLength <= bytes.count - offset - 22 ? offset : nil
    }
}
