import Foundation
import libxml2

/// The UTF-8 that libxml2's HTML parser is given in place of a document in another encoding,
/// by the native reader's fallback and by text extraction's recovery alike (#247).
///
/// That parser is told its input is UTF-8 and looks for no other encoding, so a document in
/// UTF-16 came out as two replacement characters and `café` in ISO-8859-1 as `caf\u{FFFD}`. By
/// the time a document falls back to it, the declaration screen and the XML parser have each
/// read the bytes, and this reads them as they did rather than detecting anything anew:
///
/// - UTF-16 and UTF-32, by a byte-order mark or the NUL pattern of the first characters: the
///   signatures `XMLSafety` decodes by (`wideEncoding`), decoded as it decodes them. The XML parser
///   knows fewer of them (UTF-32 only big-endian without a mark, UTF-16 without a mark only
///   before `<?xml`) and reads each one it knows the same way. Bytes that nothing but a NUL
///   tells as one of these, and that hold no markup once decoded, are refused as malformed.
/// - Otherwise the encoding named in the XML declaration, as the XML parser reads it: that
///   parser is given the declaration with an empty element after it and asked which encoding
///   it took, and its own decoder for that name decodes the document. A declaration it rejects
///   names nothing, and neither does one whose encoding it has no decoder for.
/// - Otherwise the bytes as they are, `nil`, which each caller reads its own way: the reader as
///   UTF-8, with a replacement character for what is not, and extraction only when they are
///   UTF-8. So is a document that its declared encoding cannot decode, where the XML parser has
///   no reading to agree with and the declaration is more likely wrong than the text.
///
/// An HTML `<meta charset>` is not read. The XML parser does not read it either, and the same
/// section must not change its characters for an unclosed tag.
package enum HTMLSourceEncoding {
    package enum Failure: Error, Equatable {
        /// Bytes taken for UTF-16 or UTF-32 that do not decode, or that hold no markup.
        case malformed
        /// More than the caller's limit once decoded.
        case limitExceeded
        /// Decoded characters the declaration screen refuses, or one of their tags holds more
        /// attributes than it allows.
        case unsafe(XMLSafety.Assessment)
    }

    /// `data` as UTF-8, or `nil` when it is to be read as it is. `doctypesAsHTML` is the screen's
    /// reading of a DOCTYPE, as `XMLSafety` takes it.
    package static func utf8(_ data: Data, limit: Int, doctypesAsHTML: Bool = false) throws(Failure) -> Data? {
        if case let (encoding, mark)? = XMLSafety.wideEncoding(data) {
            // The screen decoded these bytes this way and refused what does not decode.
            guard let text = String(data: data.dropFirst(mark), encoding: encoding) else { throw .malformed }
            let decoded = Data(text.utf8)
            // Without a byte-order mark the encoding was told by a NUL among the first bytes,
            // where one stands beside the first characters of markup. Bytes that hold no markup
            // once decoded are something else (a spine item that is no document at all), and
            // are refused as they were when that NUL ended the parser's input.
            guard mark > 0 || holdsMarkup(decoded) else { throw .malformed }
            guard decoded.count <= limit else { throw .limitExceeded }
            return decoded
        }
        // A decoder that stops at bytes it cannot decode writes why to standard error.
        guard let decoded = LibXML2Messages.silenced({ declared(data) }) else { return nil }
        guard decoded.count <= limit else { throw .limitExceeded }
        // The screen read the bytes as ASCII. In an encoding that spells `<` another way (UTF-7)
        // the characters may hold a declaration it could not see, so it reads them as well.
        let assessment = XMLSafety.assessUTF8(decoded, doctypesAsHTML: doctypesAsHTML)
        guard assessment == .safe else { throw .unsafe(assessment) }
        return decoded
    }

    /// Whether `utf8` holds a `<` that opens markup in HTML: one before an ASCII letter, `/`, `!`
    /// or `?`, as `HTMLStraySigns` reads it in the reader. In the tokenizer's tag open state
    /// anything else emits the sign as a character.
    private static func holdsMarkup(_ utf8: Data) -> Bool {
        var index = utf8.startIndex
        while let sign = utf8[index...].firstIndex(of: 0x3C), sign + 1 < utf8.endIndex {
            let next = utf8[sign + 1]
            if (next | 0x20 >= 0x61 && next | 0x20 <= 0x7A) || next == 0x2F || next == 0x21 || next == 0x3F { return true }
            index = sign + 1
        }
        return false
    }

    /// The options of the reader's XML parse (`ContentDocument.xmlOptions`). None of them changes
    /// the encoding the parser takes from a declaration, so extraction's strict parse, with
    /// options of its own, takes the same one.
    private static let xmlOptions = Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue
        | XML_PARSE_NOWARNING.rawValue | XML_PARSE_NOCDATA.rawValue)

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
            xmlReadMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count), nil, nil, xmlOptions)
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
