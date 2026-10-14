import Foundation

/// Linear tokenization before libxml2 can check each attribute against all its predecessors.
/// Counts occurrences, including duplicate names, namespace declarations and HTML booleans.
/// XML and HTML quote a value only after `=`; quotes in names or unquoted values hide nothing.
struct AttributeScanner {
    let bytes: [UInt8]
    let limit: Int
    var html = false
    var index = 0
    var rawText: String?

    mutating func scan() -> Bool {
        outer: while index < bytes.count {
            if rawText != nil {
                // Before entering raw text libxml2 processes an immediately following end tag;
                // in raw text its recovery parser stops at a matching name prefix. Either
                // script/style end is exposed to cover a prior ambiguous raw-text end.
                let immediate = bytes[index...].starts(with: [0x3C, 0x2F])
                let ignored = matches("</body", at: index) || matches("</html", at: index)
                if !immediate || ignored {
                    while index < bytes.count, !rawClose { index += 1 }
                }
                self.rawText = nil
                if index == bytes.count { break }
            }
            guard bytes[index] == 0x3C else { index += 1; continue }
            if html {
                if consume("<!--") { skipHTMLComment(); continue }
                if consume("<?") || consume("<!") { skip(">", exposingRawEnds: true); continue }
                if consume("</") { skip(">", exposingRawEnds: true); continue }
            } else {
                if consume("<!--") { skip("-->"); continue }
                if consume("<![CDATA[") { skip("]]>"); continue }
                if consume("<?") { skip("?>"); continue }
            }
            index += 1
            guard index < bytes.count else { break }
            let byte = bytes[index] | 0x20
            guard (byte >= 0x61 && byte <= 0x7A) || bytes[index] >= 0x80 || [0x3A, 0x5F].contains(bytes[index]) else { continue }
            let nameStart = index
            while index < bytes.count, !space(bytes[index]), ![0x2F, 0x3E].contains(bytes[index]) {
                if html && rawClose { continue outer }
                index += 1
            }
            let name = html ? String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased() : ""
            var attributes = 0
            while index < bytes.count {
                if html && rawClose { continue outer }
                while index < bytes.count, space(bytes[index]) || bytes[index] == 0x2F { index += 1 }
                guard index < bytes.count else { break }
                if html && rawClose { continue outer }
                if bytes[index] == 0x3E {
                    rawText = html && (name == "script" || name == "style") && (index == 0 || bytes[index - 1] != 0x2F) ? name : nil
                    index += 1; break
                }
                attributes += 1
                guard attributes <= limit else { return false }
                // At least one byte, even for an invalid name, ensures forward progress.
                index += 1
                while index < bytes.count, !space(bytes[index]), ![0x2F, 0x3D, 0x3E].contains(bytes[index]) {
                    if html && rawClose { continue outer }
                    index += 1
                }
                while index < bytes.count, space(bytes[index]) { index += 1 }
                guard index < bytes.count, bytes[index] == 0x3D else { continue }
                index += 1
                while index < bytes.count, space(bytes[index]) { index += 1 }
                if index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 {
                    let quote = bytes[index]; index += 1
                    while index < bytes.count, bytes[index] != quote {
                        // A prior ambiguous script/style end can leave libxml2 in raw text
                        // while this scan sees a quoted tag. Never hide its later real end.
                        if html && rawClose { continue outer }
                        index += 1
                    }
                    if index < bytes.count { index += 1 }
                } else {
                    while index < bytes.count, !space(bytes[index]), bytes[index] != 0x3E {
                        if html && rawClose { continue outer }
                        index += 1
                    }
                }
            }
        }
        return true
    }

    private func space(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0A, 0x0C, 0x0D].contains(byte) }
    private var rawClose: Bool {
        bytes[index] == 0x3C && (matches("</script", at: index) || matches("</style", at: index))
    }
    private func matches(_ token: String, at position: Int) -> Bool {
        let token = Array(token.utf8)
        guard token.count <= bytes.count - position else { return false }
        return zip(bytes[position..<position + token.count], token).allSatisfy { ($0 | 0x20) == ($1 | 0x20) }
    }
    private mutating func consume(_ token: StaticString) -> Bool {
        token.withUTF8Buffer {
            guard bytes[index...].starts(with: $0) else { return false }
            index += $0.count; return true
        }
    }
    private mutating func skip(_ token: StaticString, exposingRawEnds: Bool = false) {
        while index < bytes.count {
            if exposingRawEnds && rawClose { return }
            if consume(token) { return }
            index += 1
        }
    }

    private mutating func skipHTMLComment() {
        let end = HTMLRecoveryComments.end(in: bytes, from: index)
        while index < end {
            if rawClose { return }
            index += 1
        }
    }
}
