import Foundation

/// Reject actual entity declarations and internal DTD subsets before either XML parser runs.
/// Comments, CDATA, processing instructions and quoted identifiers are not declarations.
package enum XMLSafety {
    /// A fixed per-tag bound also caps the parsers' quadratic attribute uniqueness checks.
    package static let attributesPerElement = 1024
    package enum Assessment: Equatable { case safe, unsafe, attributeLimitExceeded }

    package static func hasSafeDeclarations(_ data: Data) -> Bool { assess(data) == .safe }

    package static func assess(_ data: Data) -> Assessment {
        guard let sources = scanBytes(data) else { return .unsafe }
        for source in sources {
            let result = assessUTF8(source)
            if result != .safe { return result }
        }
        return .safe
    }

    package static func assessUTF8(_ data: Data) -> Assessment {
        let bytes = Array(data)
        guard hasBoundedAttributes(bytes) else { return .attributeLimitExceeded }
        var scanner = DeclarationScanner(bytes: bytes)
        return scanner.scan() ? .safe : .unsafe
    }

    /// Also screen the exact UTF-8 supplied to HTML recovery, whose lexical contexts can differ
    /// from those of malformed XML. This counts duplicate and boolean attributes as well.
    package static func hasBoundedAttributes(_ data: Data, asHTML: Bool = false) -> Bool {
        var scanner = AttributeScanner(bytes: Array(data), limit: attributesPerElement, html: asHTML)
        return scanner.scan()
    }

    private static func hasBoundedAttributes(_ bytes: [UInt8]) -> Bool {
        var scanner = AttributeScanner(bytes: bytes, limit: attributesPerElement)
        return scanner.scan()
    }

    private static func scanBytes(_ data: Data) -> [Data]? {
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
            guard let text = String(data: data, encoding: encoding) else { return nil }
            let decoded = Data(text.utf8)
            if let named = XMLMarkupEncoding.declaredEncoding(Data(decoded.dropFirst(decoded.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0))) {
                let name = named.lowercased().replacingOccurrences(of: "-", with: "")
                let compatible: [String]
                switch encoding {
                case .utf16BigEndian: compatible = ["utf16", "utf16be", "utf8"]
                case .utf16LittleEndian: compatible = ["utf16", "utf16le", "utf8"]
                case .utf32BigEndian: compatible = ["utf32", "utf32be", "utf8"]
                default: compatible = ["utf32", "utf32le", "utf8"]
                }
                // A parser can switch away from the initially detected wide encoding after its
                // declaration. Refuse that ambiguous mixed source rather than scan the wrong text.
                guard compatible.contains(name) else { return nil }
            }
            return [decoded]
        }
        return XMLMarkupEncoding.decoded(data)
    }
}

/// Follows XML's lexical rules, which every well-formed document obeys. Where a document breaks
/// them, a `<` no markup can follow and, in an element's tag, a quote no attribute value can open
/// are characters, as HTML reads them: an XML parser stops at either one whatever this scan says,
/// and taking it for markup would only hide what follows from the scan.
private struct DeclarationScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func scan() -> Bool {
        while index < bytes.count {
            guard bytes[index] == 0x3C else { index += 1; continue } // <
            // A stray sign in prose (`x < y`) or a style sheet (`content: "<"`) is a character,
            // not a tag whose quotes and `>` would be sought through the text after it.
            guard opensMarkup else { index += 1; continue }
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
                // libxml2 reads a `[` directly after the closing `>` as the internal subset too.
                if index < bytes.count, bytes[index] == 0x5B { return false }
            } else if consume("<!") {
                guard endTag(rejectSubset: false) else { return false }
            } else {
                index += 1
                guard endElementTag() else { return false }
            }
        }
        return true
    }

    /// Whether the `<` at `index` can open markup: a name start (any non-ASCII byte may be one),
    /// `/`, `!` or `?` follows. At the end of input it is markup left open.
    private var opensMarkup: Bool {
        guard index + 1 < bytes.count else { return true }
        let next = bytes[index + 1]
        let letter = next | 0x20
        return (letter >= 0x61 && letter <= 0x7A) || next >= 0x80
            || next == 0x2F || next == 0x21 || next == 0x3F || next == 0x3A || next == 0x5F // / ! ? : _
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

    /// Scans through the `>` that ends a declaration, whose literals are quoted wherever they
    /// stand (`<!ATTLIST x a CDATA "=">`).
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

    /// Scans through the `>` that ends an element's tag. A quote there delimits only an attribute
    /// value, after `=`: anywhere else (`<y then it's`) it is a character and hides nothing.
    private mutating func endElementTag() -> Bool {
        var quote: UInt8?
        var valueFollows = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if let delimiter = quote {
                if byte == delimiter { quote = nil }
            } else if valueFollows && (byte == 0x22 || byte == 0x27) { // double or single quote
                quote = byte
                valueFollows = false
            } else if byte == 0x3E { // >
                return true
            } else if byte == 0x3D { // =
                valueFollows = true
            } else if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { // not XML white space
                valueFollows = false
            }
        }
        return false
    }
}
