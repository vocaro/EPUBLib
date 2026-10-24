import Foundation

/// Keeps a `<` that opens no markup as text through libxml2's HTML parser.
///
/// That parser takes every `<` in text for the start of a tag. Where no name follows, it
/// discards the input through the next `>`, so `if x < y then done</p>` loses the rest of its
/// sentence; and `.`, `_` and `:` start a name for it, so `p <.05 and` opens an element. HTML
/// keeps the sign: in the tokenizer's tag open state anything but an ASCII letter, `/`, `!` or
/// `?` emits "a U+003C LESS-THAN SIGN character token".
///
/// Each such sign is given to the parser as a placeholder, a noncharacter the parser cannot read
/// in the document, and is the sign again in the text and attribute values of the tree. The
/// parser reads one that the document holds as itself or as a numeric character reference, also
/// where only NULs stand in the reference, which `HTMLNullCharacters` then leaves out. It can
/// also assemble one in text from bytes that are not UTF-8: libxml2 2.9.13 copies each of those
/// into text as it is, and a text node joins those that only markup it drops, or a character it
/// drops, stood between: with no `b` open, `\xEF\xB7</b>\x90` is U+FDD0. The placeholder
/// needs no knowledge of where the parser is. In text it is a character, which is the repair.
/// Everywhere else the parser already took the sign for an ordinary byte and takes the
/// placeholder the same way: kept in an attribute value and in the raw text of `script` and
/// `style`, passed over in a tag, a comment or a declaration. A reference (`&lt;`) would serve
/// in text but stay a reference in raw text, and where libxml2 ends raw text cannot be told
/// from the bytes alone: directly after the start tag, the end tag of any element then open
/// ends it (`<p><style></p>`).
///
/// The bytes are UTF-8: `HTMLSourceEncoding` has decoded any other encoding. A sign before a
/// NUL opens nothing either, and `HTMLNullCharacters` then reads the NUL.
enum HTMLStraySigns {
    /// The bytes to parse, and the placeholder that stands for a sign in them: `nil` when
    /// nothing was replaced and `data` is returned as it is. So it is when the parser could read
    /// every placeholder there is in `data`, and when the placeholders, each two bytes longer
    /// than the sign, would make the bytes longer than `limit`: libxml2 then reads the signs as
    /// it read them before, and the section is not refused for them.
    static func replaced(in data: Data, limit: Int) -> (data: Data, placeholder: Unicode.Scalar?) {
        let bytes = [UInt8](data)
        var next = straySign(in: bytes, from: 0)
        guard next != nil, let placeholder = placeholder(absentFrom: bytes) else { return (data, nil) }
        let replacement = Array(String(placeholder).utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var copied = 0 // `output` holds the bytes before this index.
        while let sign = next {
            output.append(contentsOf: bytes[copied..<sign])
            output.append(contentsOf: replacement)
            copied = sign + 1
            guard output.count + bytes.count - copied <= limit else { return (data, nil) }
            next = straySign(in: bytes, from: copied)
        }
        output.append(contentsOf: bytes[copied...])
        return (Data(output), placeholder)
    }

    /// `text` from the parsed tree, with each placeholder the sign it stands for.
    static func restored(_ text: String, from placeholder: Unicode.Scalar) -> String {
        guard text.unicodeScalars.contains(placeholder) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { scalars.append(scalar == placeholder ? "<" : scalar) }
        return String(scalars)
    }

    /// The first `<` at or after `start` that opens no markup.
    private static func straySign(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while let sign = bytes[index...].firstIndex(of: 0x3C) {
            guard sign + 1 < bytes.count else { return sign }
            if !opensMarkup(before: bytes[sign + 1]) { return sign }
            index = sign + 1
        }
        return nil
    }

    /// Whether a `<` before `next` opens markup: an ASCII letter, `/`, `!` or `?`.
    static func opensMarkup(before next: UInt8) -> Bool {
        (next | 0x20 >= 0x61 && next | 0x20 <= 0x7A) || next == 0x2F || next == 0x21 || next == 0x3F
    }

    /// One of U+FDD0 to U+FDEF, which Unicode keeps for a program's own use, that the parser
    /// cannot read in `bytes`: `nil` when it could read all of them.
    private static func placeholder(absentFrom bytes: [UInt8]) -> Unicode.Scalar? {
        var held: UInt32 = 0 // Bit n is U+FDD0 + n.
        func hold(_ value: UInt32) { if value >= 0xFDD0, value <= 0xFDEF { held |= 1 << (value - 0xFDD0) } }
        // As itself or as a reference, once the NULs among its bytes are left out.
        let joined = bytes.contains(0) ? bytes.filter { $0 != 0 } : bytes
        /// Calls `body` with the index of each `byte` that two more bytes follow.
        func each(_ byte: UInt8, _ body: (Int) -> Void) {
            var index = 0
            while let found = joined[index...].firstIndex(of: byte), found + 2 < joined.count { body(found); index = found + 1 }
        }
        each(0xEF) { if joined[$0 + 1] == 0xB7 { hold(0xFDC0 + UInt32(joined[$0 + 2] & 0x3F)) } } // U+FDC0 to U+FDFF
        each(0x26) { ampersand in // &
            guard joined[ampersand + 1] == 0x23 else { return } // #
            let radix: UInt32 = joined[ampersand + 2] | 0x20 == 0x78 ? 16 : 10 // x
            var value: UInt32 = 0
            var index = ampersand + (radix == 16 ? 3 : 2)
            while index < joined.count, value <= 0x10FFFF, let number = digit(joined[index], radix: radix) {
                value = value * radix + number
                index += 1
            }
            hold(value)
        }
        // Assembled from bytes that are not UTF-8, in their order, whatever stands between them.
        // These are read with their NULs: a NUL is no part of a character, and `HTMLNullCharacters`
        // keeps one where leaving it out would join a character's halves, so a byte that is not
        // UTF-8 here is not UTF-8 to libxml2 either.
        var assembled = 0 // 1 after such an 0xEF, 2 after an 0xB7 that one came before.
        var index = 0
        while index < bytes.count {
            if let length = characterLength(in: bytes, at: index) { index += length; continue }
            let byte = bytes[index]
            if assembled == 2, byte >= 0x90, byte <= 0xAF { hold(0xFDC0 + UInt32(byte & 0x3F)) }
            if assembled >= 1, byte == 0xB7 { assembled = 2 }
            if byte == 0xEF { assembled = max(assembled, 1) }
            index += 1
        }
        return (0..<32).first { held & (1 << $0) == 0 }.flatMap { Unicode.Scalar(0xFDD0 + UInt32($0)) }
    }

    /// The length of the character libxml2 2.9.13's HTML parser decodes at `index`, or `nil`
    /// where it decodes none and copies the byte as it is (`htmlCurrentChar`). It reads a lead
    /// byte with the continuation bytes its high bits call for, and refuses an overlong form; a
    /// surrogate or a value past U+10FFFF is a character it then drops.
    private static func characterLength(in bytes: [UInt8], at index: Int) -> Int? {
        let lead = bytes[index]
        guard lead >= 0x80 else { return 1 }
        func continues(_ offset: Int) -> Bool { index + offset < bytes.count && bytes[index + offset] & 0xC0 == 0x80 }
        func bits(_ offset: Int) -> UInt32 { UInt32(bytes[index + offset] & 0x3F) }
        guard lead & 0x40 != 0, continues(1) else { return nil }
        if lead & 0xE0 != 0xE0 { return lead >= 0xC2 ? 2 : nil } // C0 and C1 are overlong.
        guard continues(2) else { return nil }
        if lead & 0xF0 != 0xF0 { return (UInt32(lead & 0x0F) << 12 | bits(1) << 6 | bits(2)) >= 0x800 ? 3 : nil }
        guard lead & 0xF8 == 0xF0, continues(3) else { return nil }
        return (UInt32(lead & 0x07) << 18 | bits(1) << 12 | bits(2) << 6 | bits(3)) >= 0x10000 ? 4 : nil
    }

    private static func digit(_ byte: UInt8, radix: UInt32) -> UInt32? {
        let value: UInt32
        switch byte {
        case 0x30...0x39: value = UInt32(byte) - 0x30 // 0 to 9
        case 0x41...0x46, 0x61...0x66: value = UInt32(byte | 0x20) - 0x57 // A to F, a to f
        default: return nil
        }
        return value < radix ? value : nil
    }
}
