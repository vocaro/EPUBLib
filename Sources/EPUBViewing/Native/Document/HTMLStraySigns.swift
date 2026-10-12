import Foundation

/// Keeps a `<` that opens no markup as text through libxml2's HTML parser.
///
/// That parser takes every `<` in text for the start of a tag. Where no name follows, it
/// discards the input through the next `>`, so `if x < y then done</p>` loses the rest of its
/// sentence; and `.`, `_` and `:` start a name for it, so `p <.05 and` opens an element. HTML
/// keeps the sign: in the tokenizer's tag open state anything but an ASCII letter, `/`, `!` or
/// `?` emits "a U+003C LESS-THAN SIGN character token".
///
/// Each such sign is given to the parser as a placeholder, a noncharacter the document does not
/// hold, and is the sign again in the text and attribute values of the tree. The placeholder
/// needs no knowledge of where the parser is. In text it is a character, which is the repair.
/// Everywhere else the parser already took the sign for an ordinary byte and takes the
/// placeholder the same way: kept in an attribute value and in the raw text of `script` and
/// `style`, passed over in a tag, a comment or a declaration. A reference (`&lt;`) would serve
/// in text but stay a reference in raw text, and where libxml2 ends raw text cannot be told
/// from the bytes alone: directly after the start tag, the end tag of any element then open
/// ends it (`<p><style></p>`).
enum HTMLStraySigns {
    /// The bytes to parse, and the placeholder that stands for a sign in them: `nil` when
    /// nothing was replaced and `data` is returned as it is. The result is `nil` when the bytes
    /// would be longer than `limit`.
    static func replaced(in data: Data, limit: Int) -> (data: Data, placeholder: Unicode.Scalar?)? {
        let bytes = [UInt8](data)
        var next = straySign(in: bytes, from: 0)
        // A document that holds every placeholder there is, is parsed as it is.
        guard next != nil, let placeholder = placeholder(absentFrom: bytes) else { return (data, nil) }
        let replacement = Array(String(placeholder).utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var copied = 0 // `output` holds the bytes before this index.
        while let sign = next {
            output.append(contentsOf: bytes[copied..<sign])
            output.append(contentsOf: replacement)
            copied = sign + 1
            guard output.count + bytes.count - copied <= limit else { return nil }
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
            let next = bytes[sign + 1]
            // A NUL here ends the parser's input. It is as far as that parser, told the bytes
            // are UTF-8, reads of UTF-16 or UTF-32 text, which is left as it was.
            if next == 0 { return nil }
            let opensMarkup = (next | 0x20 >= 0x61 && next | 0x20 <= 0x7A) || next == 0x2F || next == 0x21 || next == 0x3F // / ! ?
            if !opensMarkup { return sign }
            index = sign + 1
        }
        return nil
    }

    /// One of U+FDD0 to U+FDEF, which Unicode keeps for a program's own use, that `bytes` holds
    /// neither as itself nor as a numeric character reference: `nil` when they hold all of them.
    private static func placeholder(absentFrom bytes: [UInt8]) -> Unicode.Scalar? {
        var held: UInt32 = 0 // Bit n is U+FDD0 + n.
        func hold(_ value: UInt32) { if value >= 0xFDD0, value <= 0xFDEF { held |= 1 << (value - 0xFDD0) } }
        /// Calls `body` with the index of each `byte` that two more bytes follow.
        func each(_ byte: UInt8, _ body: (Int) -> Void) {
            var index = 0
            while let found = bytes[index...].firstIndex(of: byte), found + 2 < bytes.count { body(found); index = found + 1 }
        }
        each(0xEF) { if bytes[$0 + 1] == 0xB7 { hold(0xFDC0 + UInt32(bytes[$0 + 2] & 0x3F)) } } // U+FDC0 to U+FDFF
        each(0x26) { ampersand in // &
            guard bytes[ampersand + 1] == 0x23 else { return } // #
            let radix: UInt32 = bytes[ampersand + 2] | 0x20 == 0x78 ? 16 : 10 // x
            var value: UInt32 = 0
            var index = ampersand + (radix == 16 ? 3 : 2)
            while index < bytes.count, value <= 0x10FFFF, let number = digit(bytes[index], radix: radix) {
                value = value * radix + number
                index += 1
            }
            hold(value)
        }
        return (0..<32).first { held & (1 << $0) == 0 }.flatMap { Unicode.Scalar(0xFDD0 + UInt32($0)) }
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
