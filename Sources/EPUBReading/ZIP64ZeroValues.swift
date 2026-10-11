import Foundation

/// ZIP64 values of zero, which ZIPFoundation 0.9.20 misreads.
///
/// A central directory record whose 32-bit size or offset field holds 0xFFFFFFFF keeps the real
/// value in its ZIP64 extended information extra field (APPNOTE.TXT 4.5.3), and that value can be
/// zero: the first entry's local header is at offset 0, and an empty entry has no bytes.
/// ZIPFoundation takes a zero there for a value that is absent and falls back to the 32-bit field,
/// so it looks for the first entry 4 GiB into the archive, where its in-memory file traps, and
/// reports an empty entry as 4 GiB long.
enum ZIP64ZeroValues {
    /// `archive`, or a copy that states each such zero where ZIPFoundation reads it: in the
    /// record's 32-bit field, and no longer in the extra field, which lists only the values its
    /// record defers to it.
    ///
    /// Whatever the bytes, the copy has the archive's length and differs from it only inside
    /// directory records that end at or before the end record (the ZIP64 end record, where
    /// ZIPFoundation uses one), and in those only in the 32-bit sizes and offset and the ZIP64
    /// field. The end records are thus the same bytes in the same place, and the copy is checked
    /// not to have gained a ZIP64 end record and locator ahead of them, so ZIPFoundation finds
    /// the directory it would find in the archive, record for record: a restated record gives
    /// the values its ZIP64 field gave, and any other is as it was. Where that check fails, as
    /// where there is nothing to restate, the archive is returned as it came. A record that runs
    /// into the end records is not restated, nor is any after it. Nothing outside the directory
    /// changes, so an entry reads differently only if the archive lays that entry's own header
    /// or data over one of its directory records.
    static func inlined(in archive: Data) -> Data {
        var result = archive
        var changed = false
        let directory = archive.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Directory? in
            func read<T: FixedWidthInteger>(_ offset: Int, as type: T.Type = T.self) -> T? { bytes.read(offset, as: type) }
            func write(_ replacement: [UInt8], at offset: Int) {
                let start = result.startIndex + offset
                result.replaceSubrange(start..<(start + replacement.count), with: replacement)
                changed = true
            }
            guard let directory = Directory(in: bytes), var record = Int(exactly: directory.start) else { return nil }
            var remaining = directory.count
            // A record that runs into the end records is left alone, and so are those after it.
            while remaining > 0, record <= directory.limit - 46, read(record, as: UInt32.self) == 0x0201_4b50,
                  let nameLength = read(record + 28, as: UInt16.self).map(Int.init),
                  let extraLength = read(record + 30, as: UInt16.self).map(Int.init),
                  let commentLength = read(record + 32, as: UInt16.self).map(Int.init),
                  nameLength + extraLength + commentLength <= directory.limit - 46 - record {
                let extraEnd = record + 46 + nameLength + extraLength
                // The fields a ZIP64 value stands in for, in the order the extra field lists
                // their values: uncompressed size, compressed size, local header offset. A disk
                // number of 0xFFFF adds four bytes after them.
                let deferred = [record + 24, record + 20, record + 42].filter { read($0, as: UInt32.self) == .max }
                let disk = read(record + 34, as: UInt16.self) == .max ? 4 : 0
                var field = extraEnd - extraLength
                while field < extraEnd - 4, let id = read(field, as: UInt16.self),
                      let size = read(field + 2, as: UInt16.self).map(Int.init), field + 4 + size <= extraEnd {
                    guard id == 1 else { field += 4 + size; continue }
                    // ZIPFoundation reads the field only when it holds exactly those values.
                    guard size == deferred.count * 8 + disk else { break }
                    let values = deferred.indices.map { field + 4 + $0 * 8 }
                    guard values.contains(where: { read($0, as: UInt64.self) == 0 }) else { break }
                    // The field shrinks to the values still deferred to it. Zeros fill what it
                    // gives up and read as empty fields, so every length around it holds.
                    var kept: [UInt8] = []
                    for (header, value) in zip(deferred, values) {
                        if read(value, as: UInt64.self) == 0 { write([0, 0, 0, 0], at: header) }
                        else { kept += bytes[value..<(value + 8)] }
                    }
                    kept += bytes[(field + 4 + deferred.count * 8)..<(field + 4 + size)]
                    write([UInt8(kept.count), 0] + kept + [UInt8](repeating: 0, count: size - kept.count), at: field + 2)
                    break
                }
                record = extraEnd + commentLength
                remaining -= 1
            }
            return directory
        }
        // Every byte from `limit` on is as it was, so the end records ZIPFoundation used are. What
        // moved before them can still have made a ZIP64 end record and locator where there were
        // none, and with them another directory: the copy must lead where the archive does.
        guard changed, result.withUnsafeBytes({ Directory(in: $0) }) == directory else { return archive }
        return result
    }

    /// Where ZIPFoundation finds an archive's directory.
    private struct Directory: Equatable {
        /// The first record's offset and the number of records.
        let start: UInt64, count: UInt64
        /// The end record's offset, and the offset the end records begin at: the same, or the
        /// ZIP64 end record's when that is where `start` and `count` come from.
        let end: Int, limit: Int

        /// The end record is the last one in the archive. A ZIP64 end record and its locator,
        /// when they sit right before it, give the directory's place and length instead.
        init?(in bytes: UnsafeRawBufferPointer) {
            var end = bytes.count - 22
            while end >= 0, bytes.read(end, as: UInt32.self) != 0x0605_4b50 { end -= 1 }
            guard end >= 0, let count = bytes.read(end + 10, as: UInt16.self),
                  let start = bytes.read(end + 16, as: UInt32.self) else { return nil }
            self.end = end
            if end > 76, bytes.read(end - 20, as: UInt32.self) == 0x0706_4b50,
               bytes.read(end - 76, as: UInt32.self) == 0x0606_4b50,
               let version = bytes.read(end - 62, as: UInt16.self), version >= 45,
               let count = bytes.read(end - 44, as: UInt64.self), let start = bytes.read(end - 28, as: UInt64.self) {
                (self.start, self.count, limit) = (start, count, end - 76)
            } else {
                (self.start, self.count, limit) = (UInt64(start), UInt64(count), end)
            }
        }
    }
}

private extension UnsafeRawBufferPointer {
    /// The little-endian integer at `offset`, or nil when it does not lie within the bytes.
    func read<T: FixedWidthInteger>(_ offset: Int, as type: T.Type = T.self) -> T? {
        guard offset >= 0, offset <= count - MemoryLayout<T>.size else { return nil }
        return T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
