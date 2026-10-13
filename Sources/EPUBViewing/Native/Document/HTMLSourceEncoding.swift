import EPUBCore
import Foundation
import libxml2

/// The UTF-8 that libxml2's HTML parser is given in place of a document in another encoding.
///
/// That parser is told its input is UTF-8 and looks for no other encoding, so a document in
/// UTF-16 came out as two replacement characters and `café` in ISO-8859-1 as `caf\u{FFFD}`. By
/// the time a document falls back to it, the declaration screen and the XML parser have each
/// read the bytes, and this reads them as they did rather than detecting anything anew:
///
/// - UTF-16 and UTF-32, by a byte-order mark or the NUL pattern of the first characters: the
///   signatures `XMLSafety` decodes by, in its order, decoded as it decodes them. The XML parser
///   knows fewer of them (UTF-32 only big-endian without a mark, UTF-16 without a mark only
///   before `<?xml`) and reads each one it knows the same way. Bytes that nothing but a NUL
///   tells as one of these, and that hold no markup once decoded, are refused as malformed.
/// - Otherwise the encoding named in the XML declaration, as the XML parser reads it: that
///   parser is given the declaration with an empty element after it and asked which encoding
///   it took, and its own decoder for that name decodes the document. A declaration it rejects
///   names nothing, and neither does one whose encoding it has no decoder for.
/// - Otherwise the bytes as they are, which is how the document was read before: as UTF-8,
///   with a replacement character for what is not. So is a document that its declared encoding
///   cannot decode, where the XML parser has no reading to agree with and the declaration is
///   more likely wrong than the text.
///
/// An HTML `<meta charset>` is not read. The XML parser does not read it either, and the same
/// section must not change its characters for an unclosed tag.
enum HTMLSourceEncoding {
    /// `data` as UTF-8, or `nil` when it is to be read as it is.
    static func utf8(_ data: Data, path: String, limit: Int) throws -> Data? {
        if case let (encoding, mark)? = wide(data) {
            // The screen decoded these bytes this way and refused what does not decode.
            guard let text = String(data: data.dropFirst(mark), encoding: encoding) else { throw ContentDocumentError.malformed(path) }
            let decoded = Data(text.utf8)
            // Without a byte-order mark the encoding was told by a NUL among the first bytes,
            // where one stands beside the first characters of markup. Bytes that hold no markup
            // once decoded are something else (a spine item that is no document at all), and
            // are refused as they were when that NUL ended the parser's input.
            guard mark > 0 || holdsMarkup(decoded) else { throw ContentDocumentError.malformed(path) }
            guard decoded.count <= limit else { throw ContentDocumentError.limitExceeded("bytes") }
            return decoded
        }
        guard let decoded = declared(data) else { return nil }
        guard decoded.count <= limit else { throw ContentDocumentError.limitExceeded("bytes") }
        // The screen read the bytes as ASCII. In an encoding that spells `<` another way (UTF-7)
        // the characters may hold a declaration it could not see, so it reads them as well.
        guard XMLSafety.hasSafeDeclarations(decoded) else { throw ContentDocumentError.unsafeMarkup(path) }
        return decoded
    }

    /// A UTF-16 or UTF-32 signature and the length of its byte-order mark, as `XMLSafety` tells
    /// them. Longest signatures come first.
    static func wide(_ data: Data) -> (encoding: String.Encoding, mark: Int)? {
        let prefix = Array(data.prefix(4))
        if prefix.starts(with: [0, 0, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if prefix.starts(with: [0, 0, 0]) { return (.utf32BigEndian, 0) }
        if prefix.starts(with: [0xFF, 0xFE, 0, 0]) { return (.utf32LittleEndian, 4) }
        if prefix.count == 4 && prefix[1...3].allSatisfy({ $0 == 0 }) { return (.utf32LittleEndian, 0) }
        if prefix.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        if prefix.first == 0 { return (.utf16BigEndian, 0) }
        if prefix.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if prefix.count >= 2 && prefix[1] == 0 { return (.utf16LittleEndian, 0) }
        return nil
    }

    /// Whether `utf8` holds a `<` that opens markup.
    private static func holdsMarkup(_ utf8: Data) -> Bool {
        var index = utf8.startIndex
        while let sign = utf8[index...].firstIndex(of: 0x3C), sign + 1 < utf8.endIndex {
            if HTMLStraySigns.opensMarkup(before: utf8[sign + 1]) { return true }
            index = sign + 1
        }
        return false
    }

    /// The document in UTF-8 when its XML declaration names another encoding that decodes all
    /// of it into other bytes than its own.
    private static func declared(_ data: Data) -> Data? {
        // The XML parser passes over a UTF-8 byte-order mark before the declaration.
        let body = data.dropFirst(data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        guard body.starts(with: Array("<?xml".utf8)), let end = body.range(of: Data("?>".utf8))?.upperBound else { return nil }
        var declaration = Data(data[..<end])
        declaration.append(contentsOf: Array("<x/>".utf8))
        guard declaration.count <= Int(Int32.max) else { return nil }
        let parsed = declaration.withUnsafeBytes { buffer in
            xmlReadMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, nil, ContentDocument.xmlOptions)
        }
        guard let parsed else { return nil }
        defer { xmlFreeDoc(parsed) }
        guard let encoding = parsed.pointee.encoding.map({ String(cString: $0) }),
              // The two names the XML parser reads as UTF-8 without a decoder.
              !["utf-8", "utf8"].contains(encoding.lowercased()),
              let handler = xmlFindCharEncodingHandler(encoding) else { return nil }
        defer { xmlCharEncCloseFunc(handler) }
        guard let decoded = decoded(body, by: handler), decoded != body else { return nil }
        return decoded
    }

    /// A line feed after the document, which a decoder reads only once it has read all before it.
    private static let sentinel: UInt8 = 0x0A

    /// `body` through one of libxml2's decoders, or `nil` when it does not decode all of it.
    ///
    /// The decoder is called once. Where it stops at bytes it cannot decode, the count it
    /// returns may hide the error and a second call would read on past them, so all the input
    /// must be gone and the sentinel must have come through. The output has room for three
    /// bytes to each byte of input, which is the most a legacy encoding makes of one; a call
    /// that runs out of room reads as a failure too.
    private static func decoded(_ body: Data, by handler: UnsafeMutablePointer<xmlCharEncodingHandler>) -> Data? {
        guard body.count <= Int(Int32.max) / 4, let input = xmlBufferCreateSize(body.count + 8) else { return nil }
        defer { xmlBufferFree(input) }
        guard let output = xmlBufferCreateSize(body.count * 3 + 16) else { return nil }
        defer { xmlBufferFree(output) }
        let added = body.withUnsafeBytes { xmlBufferAdd(input, $0.bindMemory(to: xmlChar.self).baseAddress, Int32($0.count)) }
        guard added == 0, xmlBufferAdd(input, [sentinel], 1) == 0 else { return nil }
        _ = xmlCharEncInFunc(handler, output, input)
        let length = Int(xmlBufferLength(output))
        guard xmlBufferLength(input) == 0, length > 0, let content = xmlBufferContent(output), content[length - 1] == sentinel else { return nil }
        return Data(bytes: content, count: length - 1)
    }
}
