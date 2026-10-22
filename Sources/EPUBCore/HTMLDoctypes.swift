import Foundation

/// A DOCTYPE where the HTML Standard ends it, for libxml2's HTML parser (#293).
///
/// The Standard ends a DOCTYPE at its first `>`, inside a quoted identifier as outside one
/// (abrupt-doctype-public-identifier and abrupt-doctype-system-identifier), so a DOCTYPE whose
/// identifier has lost its closing quote ends there, and the document after it is read. libxml2
/// 2.9 reads the quoted identifiers that follow a `PUBLIC` or `SYSTEM` keyword to their closing
/// quotes, past any `>`, and then skips to the next `>`: such a DOCTYPE took the root's start tag
/// with it, or the rest of the file. Where no keyword follows the name, libxml2 reads no
/// identifier and skips to the first `>`, where the Standard ends the DOCTYPE.
///
/// So the last letter of each keyword between a `<!DOCTYPE` and its first `>` is written as its
/// numeric character reference (`PUBLI&#67;`), as other recovery rewrites write a letter, and
/// libxml2 reads no identifier. The identifiers name no DTD that either parser loads, and neither
/// walk reads them. Wherever libxml2 is not reading a DOCTYPE there, the reference is inert: text
/// and attribute values decode it to the letter, and a comment, a processing instruction and raw
/// text show none of it. It holds no byte that begins or ends any of those, and no declaration
/// keyword or `[` can come of it.
package enum HTMLDoctypes {
    /// Whether `<!DOCTYPE`, in any case, begins at `position`.
    package static func opens(_ bytes: [UInt8], at position: Int) -> Bool {
        position + 2 <= bytes.count && bytes[position] == 0x3C && bytes[position + 1] == 0x21
            && matches(bytes, doctype, at: position + 2)
    }

    /// The index after the first `>` after the `<!DOCTYPE` at `position`, or `nil` where the
    /// input ends first.
    package static func end(_ bytes: [UInt8], from position: Int) -> Int? {
        let start = position + 2 + doctype.count
        guard start <= bytes.count else { return nil }
        return bytes[start...].firstIndex(of: 0x3E).map { $0 + 1 }
    }

    /// The index of the last letter of each `PUBLIC` and `SYSTEM`, in any case, in `range`:
    /// the letters to write as references, in ascending order.
    package static func keywordLetters(_ bytes: [UInt8], in range: Range<Int>) -> [Int] {
        var letters: [Int] = []
        var index = range.lowerBound
        while let found = keyword(bytes, in: index..<range.upperBound) {
            letters.append(found + 5)
            index = found + 6
        }
        return letters
    }

    /// Whether `range` holds a `PUBLIC` or `SYSTEM`, in any case.
    package static func holdsKeyword(_ bytes: [UInt8], in range: Range<Int>) -> Bool { keyword(bytes, in: range) != nil }

    private static func keyword(_ bytes: [UInt8], in range: Range<Int>) -> Int? {
        var index = range.lowerBound
        while index + 6 <= range.upperBound {
            if keywords.contains(where: { matches(bytes, $0, at: index) }) { return index }
            index += 1
        }
        return nil
    }

    /// A byte as its numeric character reference.
    package static func reference(_ byte: UInt8) -> [UInt8] { Array("&#\(byte);".utf8) }

    private static let doctype = Array("doctype".utf8)
    private static let keywords = [Array("public".utf8), Array("system".utf8)]

    /// ASCII case-insensitive; `token` is lowercase.
    private static func matches(_ bytes: [UInt8], _ token: [UInt8], at position: Int) -> Bool {
        position + token.count <= bytes.count
            && zip(bytes[position..<position + token.count], token).allSatisfy { byte, expected in
                (byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) == expected
            }
    }
}
