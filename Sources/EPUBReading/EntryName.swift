import EPUBCore
import Foundation
import ZIPFoundation

/// What a directory record's name makes of its entry: the archive path the reader keeps the entry
/// under, and whether it is a file, a folder or a link.
///
/// ZIP reads a name as code page 437 unless general-purpose bit 11 declares it UTF-8
/// (APPNOTE.TXT appendix D), and so does ZIPFoundation's `Entry.path`. A container's names are
/// UTF-8 all the same (EPUB 3.3 §4.3.2), and writers of UTF-8 names leave the bit clear: `zip`
/// and `ditto` on a Mac do. Read as code page 437, `café.xhtml` is `caf├⌐.xhtml`, a file no
/// manifest href names.
///
/// The name is read from the record's own bytes (#207), which `ArchiveBounds` finds for every
/// entry ZIPFoundation reads. ZIPFoundation decodes it with Foundation, which drops a byte-order
/// mark that opens the bytes, so `EF BB BF` + `mimetype` was `mimetype` again, and it tells a
/// folder by a closing "/" it looks for by `Character`, which a Prepend-class scalar before the
/// "/" takes into itself: `OPS/` + U+0600 + `/` was a folder without bit 11 and a file with it.
struct EntryName {
    /// A file, a folder or a symbolic link, as ZIPFoundation's `Entry.type` tells it but for the
    /// closing "/", which is the name's last byte.
    let type: Entry.EntryType
    private let reading: Result<String, EPUBPublicationError>

    /// The archive path, or `invalidArchive` for a name that bit 11 declares UTF-8 and that is
    /// not, which names the entry by its bytes (`escaped(_:)`).
    var path: String {
        get throws(EPUBPublicationError) { try reading.get() }
    }

    /// The name of the directory record at `record` in `bytes`, all of which the bytes hold.
    init(record: Int, in bytes: UnsafeRawBufferPointer) {
        func u16(_ offset: Int) -> UInt16 { UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: record + offset, as: UInt16.self)) }
        let attributes = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: record + 38, as: UInt32.self))
        let name = UnsafeRawBufferPointer(rebasing: bytes[(record + 46)..<(record + 46 + Int(u16(28)))])
        type = Self.type(closingSlash: name.last == 0x2F, madeBy: u16(4), attributes: attributes)
        reading = Self.path(name: name, flags: u16(8)).map { .success($0) }
            ?? .failure(.invalidArchive("Entry name not UTF-8: \(Self.escaped(name))"))
    }

    /// The path a name with these general-purpose flags spells, also for a record ZIPFoundation
    /// does not read (`LostEntries`); nil when bit 11 declares it UTF-8 and it is not.
    ///
    /// A name that is well-formed UTF-8 is read as UTF-8 whatever bit 11 says, so the same bytes
    /// spell the same path with the bit and without it, and every scalar they spell is kept, a
    /// byte-order mark among them. Any other name is read as code page 437 with the bit clear,
    /// as ZIPFoundation reads it, which keeps a book with such a name open (EPUB Reading Systems
    /// 3.3 §4.1.2 has a reader attempt names outside the rules); with the bit set it is refused.
    ///
    /// Bytes that are well formed as UTF-8 and were meant as code page 437 are read as UTF-8.
    /// Every accented letter of code page 437 is a byte UTF-8 allows only after a lead byte, and
    /// those are its box-drawing characters, Greek letters and mathematical signs, so a name
    /// written in that code page is well-formed UTF-8 only where it looks like UTF-8 misread:
    /// `├⌐` for `é`.
    ///
    /// The two readings place every ASCII character alike. Each spells ASCII as itself, and
    /// well-formed UTF-8 spells an ASCII character no other way (an overlong form is not well
    /// formed), so a separator, a dot, a backslash, a colon or a NUL is in one reading exactly
    /// where it is in the other, and is the byte it is in the name.
    static func path(name: some Collection<UInt8>, flags: UInt16) -> String? {
        // Foundation's UTF-8 decoder drops a byte-order mark that begins the bytes; this does not.
        if let utf8 = String(validating: name, as: UTF8.self) { return utf8 }
        guard flags & 0x0800 == 0 else { return nil }
        // ZIPFoundation's code page 437: Core Foundation's DOS Latin US, which has a character
        // for every byte.
        let codePage437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x400)))
        return String(data: Data(name), encoding: codePage437) ?? ""
    }

    /// ZIPFoundation's `Entry.type` of a record made by `madeBy` with these external attributes,
    /// and a name that ends in "/" or does not. An entry whose Unix mode is a file's, a folder's
    /// or a link's is one; an MS-DOS entry with the directory attribute is a folder; otherwise a
    /// folder's name ends in "/" (APPNOTE.TXT 4.4.17.1), with or without bit 11.
    static func type(closingSlash: Bool, madeBy: UInt16, attributes: UInt32) -> Entry.EntryType {
        switch madeBy >> 8 {
        case 3, 19: // Unix and OS X: the file type is in the mode, in the upper 16 bits.
            switch mode_t(truncatingIfNeeded: attributes >> 16) & S_IFMT {
            case S_IFREG: return .file
            case S_IFDIR: return .directory
            case S_IFLNK: return .symlink
            default: break
            }
        case 0: // MS-DOS, as ZIPFoundation reads its attributes.
            if attributes >> 4 == 0x01 { return .directory }
        default: break
        }
        return closingSlash ? .directory : .file
    }

    /// A name's bytes as text that tells them all: printable ASCII as itself, and every other
    /// byte, a space and "%" among them, as "%" and two hexadecimal digits, as a URL escapes it.
    static func escaped(_ name: some Sequence<UInt8>) -> String {
        name.map { $0 > 0x20 && $0 < 0x7F && $0 != 0x25 ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }
}
