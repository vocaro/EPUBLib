import Foundation
import ZIPFoundation

/// The archive path an entry's name spells: the key the reader keeps the entry under.
///
/// ZIP reads a name as code page 437 unless general-purpose bit 11 declares it UTF-8
/// (APPNOTE.TXT appendix D), and so does ZIPFoundation's `Entry.path`. A container's names are
/// UTF-8 all the same (EPUB 3.3 §4.3.2), and writers of UTF-8 names leave the bit clear: `zip`
/// and `ditto` on a Mac do. Read as code page 437, `café.xhtml` is `caf├⌐.xhtml`, a file no
/// manifest href names.
enum EntryName {
    /// A name that is well-formed UTF-8 is read as UTF-8 whatever bit 11 says, by the decoder
    /// ZIPFoundation reads a flagged name with, so the same bytes spell the same path with the
    /// bit and without it. Any other name is left to ZIPFoundation: code page 437 with the bit
    /// clear, which keeps a book with such a name open (EPUB Reading Systems 3.3 §4.1.2 has a
    /// reader attempt names outside the rules), and with the bit set no path at all.
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
    /// where it is in the other.
    static func path(of entry: Entry) -> String {
        // "" is what `path(using:)` makes of bytes the encoding cannot read, and of no bytes.
        let utf8 = entry.path(using: .utf8)
        return utf8.isEmpty ? entry.path : utf8
    }
}
