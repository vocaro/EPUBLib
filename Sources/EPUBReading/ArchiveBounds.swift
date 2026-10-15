import EPUBCore
import Foundation
import ZIPFoundation

/// Refuses an archive whose own records would send ZIPFoundation past its end, or claim a stored
/// entry larger than the archive could hold.
///
/// ZIPFoundation 0.9.20 reads an in-memory archive through a file that traps when it is read
/// after a seek past its end, and it seeks wherever the end record, a directory record or a data
/// descriptor's place says without comparing that with the archive's length. It also takes the
/// size it reads an entry by from the directory unchecked: one of 2^63 bytes or more traps as it
/// becomes an `Int64`, and a stored entry is read in chunks until the whole size has been asked
/// for, so opening takes as long as that size says however few bytes the archive has. A book is
/// untrusted input, so `check` walks the directory first, as ZIPFoundation's iterator will and
/// with the values it will use, and throws where that would trap. Entries whose extraction
/// would overrun their bounds are then classified by ZIPFoundation itself, before any entry
/// is read: directory data is never extracted, so its declared sizes need no extraction bound.
/// A deflated entry's sizes cost nothing when they are wrong: it is read as far as its stream
/// goes, and no further than the archive does. A record ZIPFoundation merely stops at (one cut
/// short, or with another signature) is left to it, and the entries it leaves unread from there
/// on are reported (`LostEntries`).
enum ArchiveBounds {
    /// What the walk finds in a directory it does not refuse.
    struct Directory {
        /// By its place in the directory, the uncompressed size each entry with a data descriptor
        /// gives there, read by the descriptor's own form (`DataDescriptor`).
        var describedSizes: [Int: UInt64] = [:]
        /// The entries the directory lists that ZIPFoundation's iteration does not reach.
        var lostEntries: EPUBLostEntries?
        /// The places of entries whose data would overrun their bounds if they were read.
        fileprivate var oversized: [UInt64] = []
    }

    /// `data` is what ZIPFoundation reads: the bytes its `Archive` was made from. No more than
    /// `names` of the lost entries' names are kept.
    static func check(_ data: Data, archive: Archive, names: Int) throws -> Directory {
        let directory = try data.withUnsafeBytes { try walk($0, names: names) }
        var pending = directory.oversized.makeIterator()
        guard var next = pending.next() else { return directory }
        // The structural scan above makes this iterator safe. Use the library's own type,
        // rather than a second interpretation of the name and platform-specific attributes.
        // Checking all suspect entries here keeps genuine files refused before any extraction.
        for (index, entry) in archive.enumerated() where UInt64(index) == next {
            guard entry.type == .directory else {
                throw EPUBPublicationError.invalidArchive("Entry data past the end of the archive")
            }
            guard let following = pending.next() else { return directory }
            next = following
        }
        return directory
    }

    private static func walk(_ bytes: UnsafeRawBufferPointer, names: Int) throws -> Directory {
        var directory = Directory()
        let count = bytes.count
        func u16(_ offset: Int) -> Int { Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
        func u32(_ offset: Int) -> UInt64 { UInt64(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        func u64(_ offset: Int) -> UInt64 { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        func pastTheEnd(_ part: String) -> EPUBPublicationError { .invalidArchive("\(part) past the end of the archive") }

        // The end record: the last one in the archive, with the whole of its comment.
        guard count >= 22, let end = stride(from: count - 22, through: 0, by: -1).first(where: { u32($0) == 0x0605_4b50 }),
              count - end - 22 >= u16(end + 20) else { return directory }
        var entries = UInt64(u16(end + 10)), position = u32(end + 16)
        // A ZIP64 end record and its locator directly before the end record replace its values.
        if end > 76, u32(end - 20) == 0x0706_4b50, u32(end - 76) == 0x0606_4b50, u16(end - 76 + 14) >= 45 {
            entries = u64(end - 76 + 32)
            position = u64(end - 76 + 48)
        }

        var index: UInt64 = 0
        var headerBytesRemaining = count
        while index < entries {
            guard position <= UInt64(count) else { throw pastTheEnd("Central directory") }
            let record = Int(position)
            guard count - record >= 46, u32(record) == 0x0201_4b50 else { break }
            let nameLength = u16(record + 28), extraLength = u16(record + 30)
            let length = 46 + nameLength + extraLength + u16(record + 32)
            guard count - record >= length else { break }
            let flags = u16(record + 8)
            var compressed = u32(record + 20), uncompressed = u32(record + 24), header = u32(record + 42)

            // A ZIP64 extra field holds, in this order, the values the record gives as all ones.
            // ZIPFoundation reads the first such field, only when it holds exactly those values,
            // and takes a zero in it for a value that is not there.
            let expected = [uncompressed, compressed, header].filter { $0 == 0xFFFF_FFFF }.count * 8 + (u16(record + 34) == 0xFFFF ? 4 : 0)
            var field = record + 46 + nameLength
            let extraEnd = field + extraLength
            while field < extraEnd - 4 {
                let next = field + 4 + u16(field + 2)
                guard next <= extraEnd else { break }
                if u16(field) == 0x0001 {
                    guard next - field - 4 == expected else { break }
                    var value = field + 4
                    func take(_ current: inout UInt64) {
                        guard current == 0xFFFF_FFFF else { return }
                        if u64(value) > 0 { current = u64(value) }
                        value += 8
                    }
                    take(&uncompressed); take(&compressed); take(&header)
                    break
                }
                field = next
            }

            guard header <= UInt64(count) else { throw pastTheEnd("Entry header") }
            let local = Int(header)
            guard count - local >= 30, u32(local) == 0x0403_4b50 else { break }
            let dataStart = local + 30 + u16(local + 26) + u16(local + 28)
            guard dataStart <= count else { break }
            // The iterator copies and scans each local header's name and extra field anew.
            // Overlapping/reused headers must not multiply that work beyond the input's size.
            let headerBytes = dataStart - local
            guard headerBytes <= headerBytesRemaining else {
                throw EPUBPublicationError.limitExceeded("archive input work")
            }
            headerBytesRemaining -= headerBytes
            if flags & 0x0008 != 0 {
                // The descriptor follows the data, whose size the directory's method chooses.
                let (descriptor, overflow) = UInt64(dataStart).addingReportingOverflow(u16(record + 10) == 0 ? uncompressed : compressed)
                guard !overflow, descriptor <= UInt64(count) else { throw pastTheEnd("Data descriptor") }
                directory.describedSizes[Int(index)] = DataDescriptor.uncompressedSize(in: bytes, at: Int(descriptor),
                                                                                       compressed: compressed, uncompressed: uncompressed)
            }
            // ZIPFoundation's iterator ends at an encrypted entry.
            guard flags & 0x0001 == 0 else { break }
            // The size an entry is read by, which the local header's method chooses. A stored
            // entry is read a chunk at a time until that many bytes have been asked for, whether
            // or not the archive has any left to give. A deflated one is read no further than
            // its stream goes or the archive does, so its compressed size need only be one
            // ZIPFoundation can hold, and its uncompressed size is not read by at all.
            let method = u16(local + 8)
            if (method == 0 ? uncompressed : compressed) > (method == 8 ? UInt64(Int64.max) : UInt64(count - dataStart)) {
                directory.oversized.append(index)
            }

            position = UInt64(record + length)
            index += 1
        }
        // Where ZIPFoundation's iteration ends: at the record it stops at, or after the last.
        directory.lostEntries = LostEntries.find(in: bytes, at: position, read: index, counted: entries, names: names)
        return directory
    }
}
