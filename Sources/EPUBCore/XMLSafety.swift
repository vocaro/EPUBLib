import Foundation

/// Reject actual entity declarations and internal DTD subsets before either XML parser runs.
/// Comments, CDATA, processing instructions and quoted identifiers are not declarations.
package enum XMLSafety {
    package static func hasSafeDeclarations(_ data: Data) -> Bool {
        guard let bytes = scanBytes(data) else { return false }
        var scanner = DeclarationScanner(bytes: bytes)
        return scanner.scan()
    }

    private static func scanBytes(_ data: Data) -> [UInt8]? {
        let prefix = Array(data.prefix(4))
        let encoding: String.Encoding?
        // Decode wide encodings rather than deleting NULs: deletion can turn an unrelated
        // Unicode code unit into an ASCII markup delimiter. Longest signatures come first.
        if prefix.starts(with: [0, 0, 0xFE, 0xFF]) || prefix.starts(with: [0, 0, 0]) {
            encoding = .utf32BigEndian
        } else if prefix.starts(with: [0xFF, 0xFE, 0, 0]) ||
                    (prefix.count == 4 && prefix[1...3].allSatisfy { $0 == 0 }) {
            encoding = .utf32LittleEndian
        } else if prefix.starts(with: [0xFE, 0xFF]) || prefix.first == 0 {
            encoding = .utf16BigEndian
        } else if prefix.starts(with: [0xFF, 0xFE]) || (prefix.count >= 2 && prefix[1] == 0) {
            encoding = .utf16LittleEndian
        } else {
            encoding = nil
        }
        if let encoding {
            return String(data: data, encoding: encoding).map { Array($0.utf8) }
        }
        // UTF-8 and ASCII-compatible XML encodings share the markup bytes. Leave non-ASCII
        // bytes intact; the actual parser validates the declared encoding and XML grammar.
        return Array(data)
    }
}

private struct DeclarationScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func scan() -> Bool {
        while index < bytes.count {
            guard bytes[index] == 0x3C else { index += 1; continue } // <
            if consume("<!--") {
                guard skip(until: "-->") else { return false }
            } else if consume("<![CDATA[") {
                guard skip(until: "]]>") else { return false }
            } else if consume("<?") {
                guard skip(until: "?>") else { return false }
            } else if consume("<!ENTITY") {
                return false
            } else if consume("<!DOCTYPE") {
                guard endTag(rejectSubset: true) else { return false }
            } else {
                index += 1
                guard endTag(rejectSubset: false) else { return false }
            }
        }
        return true
    }

    private mutating func consume(_ token: StaticString) -> Bool {
        token.withUTF8Buffer { buffer in
            guard bytes[index...].starts(with: buffer) else { return false }
            index += buffer.count
            return true
        }
    }

    private mutating func skip(until token: StaticString) -> Bool {
        while index < bytes.count {
            if consume(token) { return true }
            index += 1
        }
        return false
    }

    private mutating func endTag(rejectSubset: Bool) -> Bool {
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if let delimiter = quote {
                if byte == delimiter { quote = nil }
            } else if byte == 0x22 || byte == 0x27 { // double or single quote
                quote = byte
            } else if byte == 0x3E { // >
                return true
            } else if rejectSubset && byte == 0x5B { // [
                return false
            }
        }
        return false
    }
}
