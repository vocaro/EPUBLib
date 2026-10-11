import EPUBCore
import Foundation

/// Refuses an archive whose own records would send ZIPFoundation past its end, or claim an entry
/// larger than the archive could hold.
///
/// ZIPFoundation 0.9.20 reads an in-memory archive through a file that traps when it is read
/// after a seek past its end, and it seeks wherever the end record, a directory record or a data
/// descriptor's place says without comparing that with the archive's length. It also takes the
/// size it reads an entry by from the directory unchecked: one of 2^63 bytes or more traps as it
/// becomes an `Int64`, and a stored entry is read in chunks until the whole size has been asked
/// for, so opening takes as long as that size says however few bytes the archive has. A book is
/// untrusted input, so `check` walks the directory first, as ZIPFoundation's iterator will and
/// with the values it will use, and throws where that would trap or where an entry's sizes are
/// more than the archive has bytes for. A record ZIPFoundation merely stops at (one cut short,
/// or with another signature) is left to it.
enum ArchiveBounds {
    /// `data` is what ZIPFoundation reads: the bytes its `Archive` was made from.
    static func check(_ data: Data) throws {
        try data.withUnsafeBytes { try check($0) }
    }

    private static func check(_ bytes: UnsafeRawBufferPointer) throws {
        let count = bytes.count
        func u16(_ offset: Int) -> Int { Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
        func u32(_ offset: Int) -> UInt64 { UInt64(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        func u64(_ offset: Int) -> UInt64 { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        func pastTheEnd(_ part: String) -> EPUBPublicationError { .invalidArchive("\(part) past the end of the archive") }

        // The end record: the last one in the archive, with the whole of its comment.
        guard count >= 22, let end = stride(from: count - 22, through: 0, by: -1).first(where: { u32($0) == 0x0605_4b50 }),
              count - end - 22 >= u16(end + 20) else { return }
        var entries = UInt64(u16(end + 10)), position = u32(end + 16)
        // A ZIP64 end record and its locator directly before the end record replace its values.
        if end > 76, u32(end - 20) == 0x0706_4b50, u32(end - 76) == 0x0606_4b50, u16(end - 76 + 14) >= 45 {
            entries = u64(end - 76 + 32)
            position = u64(end - 76 + 48)
        }

        var index: UInt64 = 0
        while index < entries {
            guard position <= UInt64(count) else { throw pastTheEnd("Central directory") }
            let record = Int(position)
            guard count - record >= 46, u32(record) == 0x0201_4b50 else { return }
            let nameLength = u16(record + 28), extraLength = u16(record + 30)
            let length = 46 + nameLength + extraLength + u16(record + 32)
            guard count - record >= length else { return }
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
            guard count - local >= 30, u32(local) == 0x0403_4b50 else { return }
            let dataStart = local + 30 + u16(local + 26) + u16(local + 28)
            guard dataStart <= count else { return }
            if flags & 0x0008 != 0 {
                // The descriptor follows the data, whose size the directory's method chooses.
                let (descriptor, overflow) = UInt64(dataStart).addingReportingOverflow(u16(record + 10) == 0 ? uncompressed : compressed)
                guard !overflow, descriptor <= UInt64(count) else { throw pastTheEnd("Data descriptor") }
            }
            // ZIPFoundation's iterator ends at an encrypted entry.
            guard flags & 0x0001 == 0 else { return }
            // The size an entry is read by, which the local header's method chooses. A stored
            // entry is read a chunk at a time until that many bytes have been asked for, whether
            // or not the archive has any left to give.
            let method = u16(local + 8)
            guard (method == 0 ? uncompressed : compressed) <= UInt64(count - dataStart) else { throw pastTheEnd("Entry data") }
            // Deflate's shortest code for its longest copy turns two bits into 258 bytes, so no
            // stream inflates to more than 1,032 times its own length.
            if method == 8 {
                let (most, overflow) = compressed.multipliedReportingOverflow(by: 1032)
                guard overflow || uncompressed <= most else {
                    throw EPUBPublicationError.invalidArchive("Entry larger than its compressed data can hold")
                }
            }

            position = UInt64(record + length)
            index += 1
        }
    }
}
