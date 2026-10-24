import EPUBCore
import Foundation

extension HTMLSourceEncoding {
    /// `bytes`, which are `data` with its named references rewritten, when `utf8` reads `data` as
    /// it is and the reader gives them to libxml2's HTML parser as UTF-8. Under an XML
    /// declaration the screen may have read them through the encoding it names where `utf8` reads
    /// none: IBM037 for one written in EBCDIC (`4C 6F A7 94`), and UTF-16 named in ASCII, which
    /// the XML parser refuses. So they are screened again as the UTF-8 the parser is told they
    /// are, and refused where the screen refuses them (#743).
    static func asTheyAre(_ bytes: Data, of data: Data, path: String, doctypesAsHTML: Bool = false) throws -> Data {
        let body = data.dropFirst(data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        guard body.starts(with: Array("<?xml".utf8)) || body.starts(with: [0x4C, 0x6F, 0xA7, 0x94]) else { return bytes }
        guard XMLSafety.assessUTF8(bytes, doctypesAsHTML: doctypesAsHTML) == .safe else { throw ContentDocumentError.unsafeMarkup(path) }
        return bytes
    }
}
