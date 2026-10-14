import Foundation

/// Protects an `&#` with no initial digit from libxml2's HTML parser. It otherwise drops the
/// sign, and can truncate an attribute at it. A placeholder is inert in every parser context;
/// unlike `&amp;`, it also restores the exact bytes when the parser stays in script/style text.
package enum HTMLLiteralAmpersands {
    package static func prepared(_ data: Data, limit: Int) -> (data: Data, placeholder: String?)? {
        guard data.count <= limit else { return nil }
        let bytes = Array(data)
        func invalid(at index: Int) -> Bool {
            guard bytes[index] == 0x26, index + 1 < bytes.count, bytes[index + 1] == 0x23 else { return false }
            var next = index + 2
            let hex = next < bytes.count && bytes[next] | 0x20 == 0x78
            if hex { next += 1 }
            return next == bytes.count || digit(bytes[next], hex: hex) == nil
        }
        guard bytes.indices.contains(where: invalid) else { return (data, nil) }
        // Include authored numeric references as well as literal scalars: a decoded reference
        // must never become one of our signs. Named HTML references contain no private-use or
        // noncharacter scalar. Selection is linear, even when all common placeholders occur.
        var held: [UInt32: Int] = [:]
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars { held[scalar.value, default: 0] += 1 }
        for index in bytes.indices where bytes[index] == 0x26 && index + 1 < bytes.count && bytes[index + 1] == 0x23 {
            var next = index + 2
            let hex = next < bytes.count && bytes[next] | 0x20 == 0x78
            if hex { next += 1 }
            var value: UInt32 = 0, hasDigit = false
            while next < bytes.count, let number = digit(bytes[next], hex: hex) {
                hasDigit = true
                value = min(0x110000, value * (hex ? 16 : 10) + number)
                next += 1
            }
            if hasDigit { held[value, default: 0] += 1 }
        }
        let common = (UInt32(0xFDD0)...0xFDEF).first { held[$0] == nil }
        let spare = common ?? (UInt32(0xE000)...0xF8FF).first { held[$0] == nil }
            ?? (UInt32(0xF0000)...0xFFFFD).first { held[$0] == nil }
            ?? (UInt32(0x100000)...0x10FFFD).first { held[$0] == nil }
        let placeholder: String
        if let spare, let scalar = Unicode.Scalar(spare) { placeholder = String(scalar) }
        else {
            // Even a document containing every candidate remains repairable. A prefix longer
            // than all authored occurrences cannot be formed by parsing or joining text nodes.
            // A different final scalar fixes the boundary if authored prefix scalars precede
            // the replacement, so restoration cannot reorder those authored characters.
            let prefix = (UInt32(0xFDD0)...0xFDEF).min { held[$0, default: 0] < held[$1, default: 0] }!
            let suffix: UInt32 = prefix == 0xFDEF ? 0xFDD0 : 0xFDEF
            placeholder = String(repeating: String(Unicode.Scalar(prefix)!), count: held[prefix, default: 0] + 1)
                + String(Unicode.Scalar(suffix)!)
        }
        let replacement = Array(placeholder.utf8)
        var output = [UInt8](); output.reserveCapacity(min(limit, bytes.count))
        for index in bytes.indices {
            if invalid(at: index) { output.append(contentsOf: replacement) }
            else { output.append(bytes[index]) }
            guard output.count <= limit else { return nil }
        }
        return (Data(output), placeholder)
    }

    package static func restored(_ text: String, placeholder: String?) -> String {
        guard let placeholder else { return text }
        return text.replacingOccurrences(of: placeholder, with: "&", options: .literal)
    }

    private static func digit(_ byte: UInt8, hex: Bool) -> UInt32? {
        switch byte {
        case 0x30...0x39: UInt32(byte - 0x30)
        case 0x41...0x46 where hex: UInt32(byte | 0x20) - 0x57
        case 0x61...0x66 where hex: UInt32(byte | 0x20) - 0x57
        default: nil
        }
    }
}

package enum HTMLRecoveryComments {
    /// libxml2 ends a comment at either `-->` or `--!>`. Keep every preparation scan in that
    /// same context, without changing the comment bytes or treating its examples as prose.
    package static func end(in bytes: [UInt8], from start: Int) -> Int {
        closedEnd(in: bytes, from: start) ?? bytes.count
    }

    package static func closedEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 2 < bytes.count {
            if bytes[index] == 0x2D, bytes[index + 1] == 0x2D {
                if bytes[index + 2] == 0x3E { return index + 3 }
                if bytes[index + 2] == 0x21, index + 3 < bytes.count, bytes[index + 3] == 0x3E { return index + 4 }
            }
            index += 1
        }
        return nil
    }
}
