/// A data descriptor's sizes, read by the form its own bytes have.
///
/// An entry whose general purpose bit 3 is set gives its checksum and sizes after its data, in a
/// data descriptor: an optional signature, the checksum, then the compressed and uncompressed
/// sizes, of four bytes each or, in a ZIP64 archive, eight (APPNOTE.TXT 4.3.9). ZIPFoundation
/// 0.9.20 reads eight-byte sizes for every entry marked version 4.5 or more, or with a ZIP64 field
/// in its directory record, and four-byte sizes for every other, whatever the descriptor holds.
/// A 16-byte descriptor read as a 24-byte one has an uncompressed size that runs into the next
/// local header's signature, petabytes; a 24-byte one read as a 16-byte one has the top half of
/// its compressed size, zero. A stored entry's limits are checked by that size before it is read,
/// so a book whose stored entries were marked version 4.5 over 16-byte descriptors was refused
/// (#261). A deflated entry's limits are checked as it inflates, and either form puts the checksum
/// in the same place, so neither was misread.
///
/// The signature is taken to be there when the first four bytes are the signature's, as
/// ZIPFoundation and APPNOTE.TXT take it. The form is then the one whose sizes are the sizes its
/// directory record gives: a writer states the same sizes in both. Where neither form's are, the
/// descriptor's are read by the form that ends where the next local header or the directory
/// begins. Where neither form does either, nothing tells its sizes, and the record's, which the
/// entry's data is read by, are taken.
enum DataDescriptor {
    /// The uncompressed size of the descriptor at `offset` in `bytes`, of an entry whose directory
    /// record gives `compressed` and `uncompressed` as its sizes.
    static func uncompressedSize(in bytes: UnsafeRawBufferPointer, at offset: Int,
                                 compressed: UInt64, uncompressed: UInt64) -> UInt64 {
        func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        func u64(_ offset: Int) -> UInt64 { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        let count = bytes.count
        guard offset >= 0, offset <= count - 4 else { return uncompressed }
        // The sizes begin after the signature and the checksum, or after the checksum alone.
        let sizes = offset + (u32(offset) == 0x0807_4b50 ? 8 : 4)
        // Each form's sizes, where the bytes hold them, and the offset that form ends at.
        var forms: [(compressed: UInt64, uncompressed: UInt64, end: Int)] = []
        if sizes <= count - 8 { forms.append((UInt64(u32(sizes)), UInt64(u32(sizes + 4)), sizes + 8)) }
        if sizes <= count - 16 { forms.append((u64(sizes), u64(sizes + 8), sizes + 16)) }
        if forms.contains(where: { $0.compressed == compressed && $0.uncompressed == uncompressed }) { return uncompressed }
        // A local header or a directory record begins where the descriptor ends.
        let followed = forms.filter { $0.end <= count - 4 && [0x0403_4b50, 0x0201_4b50].contains(u32($0.end)) }
        return followed.count == 1 ? followed[0].uncompressed : uncompressed
    }
}
