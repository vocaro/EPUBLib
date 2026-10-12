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
/// A file may still be an archive and then bytes that are none of it: the page a download was
/// wrapped in, another file run on after it. ZIPFoundation read such a file by the last
/// signature anywhere in it. So bytes with no signature in their last 65,557 that begin with a
/// local file header's, as an archive does whose first entry is at its first byte, are searched
/// back to the first, once and in memory, and ZIPFoundation is given them as far as the comment
/// of the record found (`archiveLength(in:)`). Bytes that begin with anything else are refused
/// by their last bytes and their first four, the rest unread: an archive with other bytes both
/// before it and, more than a comment's length of them, after it is among those.
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

    /// How many of `bytes`, from the first, ZIPFoundation is given for the archive, or nil when
    /// they hold none it would make one of.
    ///
    /// All of them when a signature begins in the last `maximumLength`: that one is the record
    /// ZIPFoundation takes, and there is no archive when it cannot read it. Otherwise, when the
    /// bytes begin with a local file header's signature, those up to the end of the comment of
    /// the last record before them, which more than a comment's length of other bytes follows.
    /// That is the record ZIPFoundation took of the whole file, and the last signature in what
    /// it is given, so it finds the same one within a comment's length of the end and reads the
    /// directory that record names.
    ///
    /// In that second case what follows the comment is no part of the archive, which is read as
    /// it would be with nothing after it. So where its own records place something there (a
    /// directory, a header, an entry's data, or the end of a record whose lengths run that
    /// far), ZIPFoundation, given the whole file, found bytes, and now finds the archive's end.
    /// In the first, the few bytes after the comment are given with the rest, as they were.
    static func archiveLength(in bytes: UnsafeRawBufferPointer) -> Int? {
        if offset(in: bytes) != nil { return readableOffset(in: bytes) == nil ? nil : bytes.count }
        let searched = bytes.count - maximumLength
        guard searched > 0, UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self)) == 0x0403_4b50,
              let offset = lastSignature(in: bytes, before: searched) else { return nil }
        return offset + 22 + Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 20, as: UInt16.self)))
    }

    /// The offset of the last end-record signature that begins before `end`, which has eight
    /// bytes or more after it.
    ///
    /// Eight offsets are tried at a time, as the eight bytes of a word: each byte against the
    /// signature's first, the byte after it against the second, and so on. The work is the
    /// same whatever the bytes are, one pass over them, so no input makes the search slow: a
    /// file of the size a book may be takes hundredths of a second. A search for the first
    /// byte alone, with a comparison wherever it is found, is no quicker over text and takes
    /// seconds over bytes that are mostly that one.
    static func lastSignature(in bytes: UnsafeRawBufferPointer, before end: Int) -> Int? {
        func word(_ offset: Int) -> UInt64 { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        var block = end - 8
        if block >= 0 {
            var after = word(block + 8)
            while block >= 0 {
                let here = word(block)
                // A byte is zero where the byte at its offset and the three after it are the
                // signature's: the shifts bring each of those three to the offset's own place.
                let differing = (here ^ 0x5050_5050_5050_5050) | ((here >> 8 | after << 56) ^ 0x4B4B_4B4B_4B4B_4B4B)
                    | ((here >> 16 | after << 48) ^ 0x0505_0505_0505_0505) | ((here >> 24 | after << 40) ^ 0x0606_0606_0606_0606)
                // Nonzero when any byte is zero, though not only at the bytes that are.
                if (differing &- 0x0101_0101_0101_0101) & ~differing & 0x8080_8080_8080_8080 != 0 {
                    for place in (0..<8).reversed() where (differing >> (8 * place)) & 0xFF == 0 { return block + place }
                }
                after = here
                block -= 8
            }
        }
        // The first offsets, fewer than eight of them.
        var offset = block + 7
        while offset >= 0 {
            if UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) == 0x0605_4b50 { return offset }
            offset -= 1
        }
        return nil
    }
}
