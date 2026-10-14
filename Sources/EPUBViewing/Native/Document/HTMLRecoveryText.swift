import Foundation

/// Keeps XML character data when a content document is read by libxml2 as HTML.
///
/// CDATA in content becomes escaped text, so HTML does not discard it as a bogus comment.
/// Comments, attribute values, declarations and script/style raw text keep
/// their bytes; a literal CDATA opener in any of them must not become visible prose.
/// This runs before stray signs and NULs are handled, so CDATA's characters follow the same
/// rules and DOM offsets as ordinary text. The strict XML path never calls this preparation.
enum HTMLRecoveryText {
    static func prepared(_ data: Data, path: String, limit: Int) throws -> Data {
        let bytes = [UInt8](data)
        let cdataOpen = Array("<![CDATA[".utf8), cdataClose = Array("]]>".utf8)
        let commentOpen = Array("<!--".utf8), endTagOpen = Array("</".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(min(bytes.count, limit))
        var index = 0
        var rawText: [UInt8]?
        func starts(_ token: [UInt8], at start: Int) -> Bool {
            bytes[start...].starts(with: token)
        }
        func close(from start: Int) -> Int {
            bytes[start...].firstIndex(of: 0x3E).map { $0 + 1 } ?? bytes.count
        }
        func copy(to end: Int) {
            output.append(contentsOf: bytes[index..<end]); index = end
        }
        while index < bytes.count {
            if let element = rawText {
                if starts(endTagOpen, at: index),
                   HTMLNullCharacters.name(in: bytes, at: index + 2) == element {
                    rawText = nil
                    copy(to: close(from: index + 2))
                } else { copy(to: index + 1) }
            } else if starts(commentOpen, at: index) {
                copy(to: HTMLNullCharacters.comment(in: bytes, at: index))
            } else if starts(cdataOpen, at: index) {
                var end = index + cdataOpen.count
                while end < bytes.count, !starts(cdataClose, at: end) { end += 1 }
                guard end < bytes.count else { throw ContentDocumentError.malformed(path) }
                for byte in bytes[(index + cdataOpen.count)..<end] {
                    switch byte {
                    case 0x26: output.append(contentsOf: "&amp;".utf8)
                    case 0x3C: output.append(contentsOf: "&lt;".utf8)
                    case 0x3E: output.append(contentsOf: "&gt;".utf8)
                    default: output.append(byte)
                    }
                    guard output.count <= limit else { throw ContentDocumentError.limitExceeded("bytes") }
                }
                index = end + cdataClose.count
            } else if bytes[index] == 0x3C, index + 1 < bytes.count {
                let next = bytes[index + 1]
                if HTMLNullCharacters.isLetter(next) {
                    let tag = HTMLNullCharacters.startTag(in: bytes, at: index)
                    copy(to: tag.end); rawText = tag.rawText
                } else if next == 0x21 || next == 0x3F {
                    // A declaration or PI: quotes can hold `>` and a CDATA opener. Copy
                    // through its actual end, so neither is mistaken for content.
                    var end = index + 2, quote: UInt8?
                    while end < bytes.count {
                        let byte = bytes[end]; end += 1
                        if let delimiter = quote { if byte == delimiter { quote = nil } }
                        else if byte == 0x22 || byte == 0x27 { quote = byte }
                        else if byte == 0x3E { break }
                    }
                    copy(to: end)
                } else if next == 0x2F { copy(to: close(from: index + 2)) }
                else { copy(to: index + 1) }
            } else { copy(to: index + 1) }
            guard output.count <= limit else { throw ContentDocumentError.limitExceeded("bytes") }
        }
        return Data(output)
    }
}
