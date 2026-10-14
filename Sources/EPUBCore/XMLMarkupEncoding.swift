import Foundation
import libxml2

/// Decodes only for the safety preflight. The parser still receives the original bytes.
/// Use the same legacy converters as libxml2: Foundation does not expose SCSU or LMBCS.
enum XMLMarkupEncoding {
    static func decoded(_ data: Data) -> [Data]? {
        let body = Data(data.dropFirst(data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0))
        if body.starts(with: [0x4C, 0x6F, 0xA7, 0x94]) {
            // libxml2 initially converts 45 EBCDIC bytes, then switches to the declaration's
            // encoding. In particular an EBCDIC declaration can introduce an SCSU body.
            let initial = convert(Data(body.prefix(45)), encoding: "IBM037")
            guard initial.complete, let encoding = declaredEncoding(initial.data, requireEnd: false) else {
                let converted = convert(body, encoding: "IBM037")
                // A delayed encoding name can make libxml2 grow the initial converted chunk
                // before switching. Without the name in its initial 45 bytes, the split is
                // ambiguous; do not pretend a whole-file IBM037 reading is authoritative.
                guard declaredEncoding(converted.data) == nil else { return nil }
                return converted.complete ? [converted.data] : [converted.data, body]
            }
            let prefix = initial.data
            // UTF-8 is libxml2's already-decoded representation, so naming it does not switch
            // the EBCDIC input converter back to raw UTF-8.
            if ["utf-8", "utf8"].contains(encoding.lowercased()) {
                let converted = convert(body, encoding: "IBM037")
                return converted.complete ? [converted.data] : [converted.data, body]
            }
            let tail = convert(Data(body.dropFirst(45)), encoding: encoding)
            return tail.complete ? [prefix + tail.data] : [prefix + tail.data, body]
        }
        guard let encoding = declaredEncoding(body) else { return [body] }
        if ["utf-8", "utf8"].contains(encoding.lowercased()) { return [body] }
        let converted = convert(body, encoding: encoding)
        // A decoder failure cannot yield a successful strict parse. Inspect the converted prefix
        // nevertheless (the parser may read declarations before that error), and also the raw
        // bytes that an explicitly UTF-8 HTML fallback can receive.
        return converted.complete ? [converted.data] : [converted.data, body]
    }

    /// Read pseudo-attributes without parsing any document content or imposing a short prolog
    /// cutoff. Only XML white space separates them; invalid declarations are left to the parser.
    static func declaredEncoding(_ data: Data, requireEnd: Bool = true) -> String? {
        let bytes = Array(data)
        guard bytes.starts(with: Array("<?xml".utf8)), bytes.count > 5, space(bytes[5]) else { return nil }
        var index = 5
        var names: [String] = []
        var declared: String?
        while index < bytes.count {
            while index < bytes.count, space(bytes[index]) { index += 1 }
            if bytes[index...].starts(with: [0x3F, 0x3E]) { return names.first == "version" ? declared : nil }
            let start = index
            while index < bytes.count, bytes[index] >= 0x61, bytes[index] <= 0x7A { index += 1 }
            guard index > start else { return nil }
            let name = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !names.contains(name), names.isEmpty ? name == "version" :
                (name == "encoding" && names == ["version"]) || (name == "standalone" && names.first == "version") else { return nil }
            names.append(name)
            while index < bytes.count, space(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == 0x3D else { return nil }
            index += 1
            while index < bytes.count, space(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 else { return nil }
            let quote = bytes[index]; index += 1
            let value = index
            while index < bytes.count, bytes[index] != quote { index += 1 }
            guard index < bytes.count else { return nil }
            let text = String(decoding: bytes[value..<index], as: UTF8.self)
            if name == "encoding" {
                guard !text.isEmpty, bytes[value..<index].allSatisfy({ $0 < 0x80 && $0 != 0 }) else { return nil }
                declared = text
                if !requireEnd { return declared }
            } else if name == "version" {
                // libxml2 reads other 1.x versions with a warning, and still switches encoding.
                guard text.hasPrefix("1."), text.utf8.count > 2,
                      text.utf8.dropFirst(2).allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            } else if name == "standalone" {
                guard ["yes", "no"].contains(text) else { return nil }
            }
            index += 1
        }
        return nil
    }

    private static func space(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0A, 0x0D].contains(byte) }

    private static func convert(_ data: Data, encoding: String) -> (data: Data, complete: Bool) {
        guard data.count <= Int(Int32.max) / 4, let handler = xmlFindCharEncodingHandler(encoding) else { return (Data(), false) }
        defer { xmlCharEncCloseFunc(handler) }
        guard let input = xmlBufferCreateSize(data.count + 8) else { return (Data(), false) }
        defer { xmlBufferFree(input) }
        guard let output = xmlBufferCreateSize(data.count * 3 + 16) else { return (Data(), false) }
        defer { xmlBufferFree(output) }
        let added = data.withUnsafeBytes { xmlBufferAdd(input, $0.bindMemory(to: xmlChar.self).baseAddress, Int32($0.count)) }
        // Refuse partial or failed conversion. No unconverted bytes are classified as safe.
        guard added == 0 else { return (Data(), false) }
        let result = xmlCharEncInFunc(handler, output, input)
        let complete = result >= 0 && xmlBufferLength(input) == 0
        let length = Int(xmlBufferLength(output))
        guard length > 0, let content = xmlBufferContent(output) else { return (Data(), complete && data.isEmpty) }
        return (Data(bytes: content, count: length), complete)
    }
}
