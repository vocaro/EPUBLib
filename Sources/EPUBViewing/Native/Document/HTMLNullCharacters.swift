import EPUBCore
import Foundation

/// Reads U+0000 as HTML reads it, before libxml2's HTML parser comes to one.
///
/// That parser ends its input at a NUL that follows a tag or stands inside one, so
/// `<p>a</p>` NUL `<p>after</p>` lost its second paragraph, and reads a NUL inside text as a
/// space. HTML ends nothing there: in the text of a body it ignores U+0000, and inside markup
/// and the raw text of `script` and `style` it reads U+FFFD.
///
/// So a NUL in text is left out, and one in markup becomes U+FFFD. Markup is a comment, a
/// start tag through its `>` with HTML's quoting of attribute values, anything else a `<`
/// opens (`</`, `<!`, `<?`) through the next `>`, and the raw text of `script` and `style`
/// through its end tag. Leaving a NUL out therefore joins only bytes of text, and never
/// completes a tag, a comment or a declaration. `HTMLStraySigns` has already made a character
/// of a `<` that a NUL follows, as HTML does; where it could not, that NUL stays, as U+FFFD,
/// between the sign and what would have made a tag of it. In bytes that are not UTF-8 a NUL
/// stays likewise where leaving it out would join the halves of a character.
///
/// After a DOCTYPE, a `>` and a `[` that only NULs stand between are kept apart. The screen
/// refuses a `[` directly after a DOCTYPE's `>`, where libxml2's XML parser reads an internal
/// subset, and leaving the NULs out would give the parser what the screen refuses. The first
/// NUL is `<!>`, which libxml2 2.9.13 reads as nothing wherever this scan reads text, so the
/// text is what it is without the NUL. (An HTML tokenizer reads `title`, `textarea` and the
/// like as RCDATA or raw text, and would show it there.) It holds no quote and no `-->`, `?>`
/// or `]]>`, so it ends nothing the screen may be reading there; an empty comment `<!---->`
/// would end a comment the screen reads in a style sheet. The screen ends a DOCTYPE past a
/// quoted `>`, and reads one in the raw text of a style sheet, so here any `>` after the first
/// `<!DOCTYPE` may end one.
///
/// The scan follows what libxml2 does with the bytes it is given here, not what HTML would:
/// raw text ends at an end tag of its own name and at no other. Where the two part (libxml2
/// ends raw text at any end tag directly after `<style>`), a NUL reads as U+FFFD that might
/// have been left out. Nothing reads as text that is not.
enum HTMLNullCharacters {
    private static let replacement: [UInt8] = [0xEF, 0xBF, 0xBD] // U+FFFD

    /// `data` without its NULs, or `nil` when that is longer than `limit`. It is `data` itself
    /// when it holds none.
    static func replaced(in data: Data, limit: Int) -> Data? {
        guard data.contains(0) else { return data }
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var rawText: [UInt8]? // The name of the `script` or `style` whose raw text this is.
        let doctype = bytes.firstRange(of: doctypeOpen)?.lowerBound ?? bytes.count
        /// Whether the NULs from `start` stand between a `>` that may end a DOCTYPE and a `[`.
        func opensSubset(at start: Int) -> Bool {
            start > doctype && bytes[start - 1] == 0x3E && bytes[start...].first(where: { $0 != 0 }) == 0x5B
        }
        /// Copies the markup that ends before `end`.
        func copyMarkup(to end: Int) {
            for byte in bytes[index..<end] {
                if byte == 0 { output.append(contentsOf: replacement) } else { output.append(byte) }
            }
            index = end
        }
        /// The index after the next `>` at or after `start`, or the end of the input.
        func close(from start: Int) -> Int { start < bytes.count ? (bytes[start...].firstIndex(of: 0x3E).map { $0 + 1 } ?? bytes.count) : bytes.count }
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil
            if let element = rawText {
                if byte == 0x3C, next == 0x2F { // An end tag: only one of its own name ends raw text.
                    if name(in: bytes, at: index + 2) == element { rawText = nil }
                    copyMarkup(to: close(from: index + 2))
                } else {
                    copyMarkup(to: index + 1)
                }
            } else if byte == 0x3C, let next {
                if bytes[index...].starts(with: commentOpen) {
                    copyMarkup(to: comment(in: bytes, at: index))
                } else if isLetter(next) {
                    let tag = startTag(in: bytes, at: index)
                    copyMarkup(to: tag.end)
                    rawText = tag.rawText
                } else if next == 0x2F || next == 0x21 || next == 0x3F { // / ! ?
                    copyMarkup(to: close(from: index + 2))
                } else {
                    // A sign left as it was. A NUL after it stays between it and the next byte.
                    output.append(byte)
                    index += 1
                    if next == 0 { copyMarkup(to: index + 1) }
                }
            } else {
                // Text. Before a byte that only continues a character, which is not UTF-8, a
                // NUL stays, so that the bytes on either side are not joined into a character.
                // The first of the NULs between a `>` that may end a DOCTYPE and a `[` is `<!>`.
                if byte != 0 {
                    output.append(byte)
                } else if let next, next & 0xC0 == 0x80 {
                    output.append(contentsOf: replacement)
                } else if opensSubset(at: index) {
                    output.append(contentsOf: emptyComment)
                }
                index += 1
            }
        }
        return output.count <= limit ? Data(output) : nil
    }

    private static let commentOpen = Array("<!--".utf8)
    private static let doctypeOpen = Array("<!DOCTYPE".utf8) // As the screen spells it.
    private static let emptyComment = Array("<!>".utf8)

    /// The index after the `-->` or `--!>` that ends the comment opened at `start`.
    static func comment(in bytes: [UInt8], at start: Int) -> Int {
        HTMLRecoveryComments.end(in: bytes, from: start + commentOpen.count)
    }

    /// The index after the `>` that ends the start tag at `start`, or the end of the input, and
    /// the tag's name when raw text follows it. A quote opens an attribute's value only after
    /// `=`, and `/>` ends a tag that nothing follows.
    static func startTag(in bytes: [UInt8], at start: Int) -> (end: Int, rawText: [UInt8]?) {
        let name = name(in: bytes, at: start + 1)
        let rawText = name == Array("script".utf8) || name == Array("style".utf8) ? name : nil
        var index = start + 1 + name.count
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3E { return (index + 1, rawText) } // >
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x3E { return (index + 2, nil) } // />
            index += 1
            if isSpace(byte) || byte == 0x2F { continue }
            // An attribute's name is at least the byte just passed.
            while index < bytes.count, !isSpace(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3D, bytes[index] != 0x3E { index += 1 }
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == 0x3D else { continue } // =
            index += 1
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count else { break }
            if bytes[index] == 0x22 || bytes[index] == 0x27 { // double or single quote
                guard let quote = bytes[(index + 1)...].firstIndex(of: bytes[index]) else { break }
                index = quote + 1
            } else {
                while index < bytes.count, !isSpace(bytes[index]), bytes[index] != 0x3E { index += 1 }
            }
        }
        return (bytes.count, nil)
    }

    /// The tag name libxml2 reads at `start`, in lowercase: ASCII letters and digits, `:`, `-`,
    /// `_` and `.`.
    static func name(in bytes: [UInt8], at start: Int) -> [UInt8] {
        guard start < bytes.count else { return [] }
        return bytes[start...].prefix { isLetter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x3A || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E }
            .map { isLetter($0) ? $0 | 0x20 : $0 }
    }

    static func isLetter(_ byte: UInt8) -> Bool { byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A }
    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
}
