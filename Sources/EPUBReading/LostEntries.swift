import EPUBCore
import Foundation

/// Entries an archive's directory lists that ZIPFoundation does not read (#261).
///
/// ZIPFoundation 0.9.20 reads the directory a record at a time, as many as the end record counts,
/// and ends without a word at the first entry it cannot read: one whose record the end of the
/// archive cuts short or whose signature is not a record's, one whose local header offset names
/// no local header, and an encrypted one. Every entry from there on is left unread, and so is
/// every record that follows the last one the end record counts. The book is opened without them,
/// as without files the archive lacks (#171), and `EPUBPublication.lostEntries` says so.
///
/// Where iteration ends short of the count, the entries lost are as many as the count has left,
/// unless what is there begins the end records or the directory's signature: then the count
/// overstated the records and none is missing. Where it reaches the count, they are the records
/// that follow. The names are those of the records that can be read from where iteration ended:
/// every one after an entry whose local header is missing, one cut short whose name is whole,
/// and none where what is there is no record.
enum LostEntries {
    /// The entries lost when ZIPFoundation's iteration ends at `position` in `bytes` having read
    /// `read` of the `counted` the end record gives, with no more than `limit` of their names.
    static func find(in bytes: UnsafeRawBufferPointer, at position: UInt64, read: UInt64, counted: UInt64,
                     names limit: Int) -> EPUBLostEntries? {
        let count = bytes.count
        func u16(_ offset: Int) -> Int { Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
        func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        // An end record, a ZIP64 end record or its locator, or the directory's digital signature.
        let ends: Set<UInt32> = [0x0605_4b50, 0x0606_4b50, 0x0706_4b50, 0x0505_4b50]
        guard position <= UInt64(count) else { return nil }
        var record = Int(position)
        let short = read < counted
        if short, record <= count - 4, ends.contains(u32(record)) { return nil }
        var found: UInt64 = 0, paths: [String] = []
        while !short || found < counted - read, record <= count - 46, u32(record) == 0x0201_4b50 {
            let nameLength = u16(record + 28)
            guard nameLength <= count - record - 46 else { break }
            found += 1
            if paths.count < limit {
                // A name bit 11 declares UTF-8 that is not, which refuses an entry that is read,
                // has no path to give.
                paths.append(EntryName.path(name: bytes[(record + 46)..<(record + 46 + nameLength)], flags: UInt16(u16(record + 8))) ?? "")
            }
            let length = 46 + nameLength + u16(record + 30) + u16(record + 32)
            // The next record begins where this one ends, which the end of the archive cuts off.
            guard length <= count - record else { break }
            record += length
        }
        let lost = short ? counted - read : found
        return lost == 0 ? nil : EPUBLostEntries(count: Int(clamping: lost), paths: paths)
    }
}
