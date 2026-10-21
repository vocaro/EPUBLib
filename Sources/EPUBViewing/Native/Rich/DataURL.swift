import Foundation

/// A `data:` URL read as the Fetch standard's data: URL processor reads one
/// (<https://fetch.spec.whatwg.org/#data-url-processor>), which is RFC 2397 as browsers read it.
/// The URL parser's part comes first: the C0 controls and spaces round the reference are read
/// past, tabs and newlines in it are left out, the scheme is matched in any case and a fragment
/// is dropped. The type is what precedes the first comma, and the body what follows it,
/// percent-decoded and, where the type ends in `;base64`, decoded as forgiving base64, which
/// reads past white space and needs no padding. The images of a section
/// (`NativeRichContent.image`), those inside a drawing in a book (`SVGContent.serialize`) and
/// those inside a drawing the renderer is given (`SVGContent.preparedImagesAreBounded`) are read
/// by it.
struct DataURL {
    /// The essence of the URL's MIME type, `type/subtype` in lower case: `text/plain` where it
    /// names none or one that does not parse.
    let mediaType: String
    let body: Data

    /// nil where the reference is not a `data:` URL, where the processor fails on it (it has no
    /// comma, or base64 that does not decode), and where the body would be longer than
    /// `maximumBytes`.
    init?(_ reference: String, maximumBytes: Int = .max) {
        guard let bytes = Self.afterScheme(reference) else { return nil }
        let end = bytes.firstIndex(of: 0x23) ?? bytes.endIndex // #
        guard let comma = bytes[..<end].firstIndex(of: 0x2C) else { return nil } // ,
        // The type as the URL parser leaves it: what it escapes in the path, and in a query
        // after a `?`, written as escapes. Percent-decoding the body undoes the same escapes.
        let digits = Array("0123456789ABCDEF".utf8)
        var escaped: [UInt8] = []
        var query = false
        for byte in bytes[..<comma] {
            query = query || byte == 0x3F // ?
            if byte < 0x20 || byte > 0x7E || (query && (byte == 0x20 || byte == 0x22 || byte == 0x3C || byte == 0x3E)) {
                escaped += [0x25, digits[Int(byte >> 4)], digits[Int(byte & 15)]]
            } else { escaped.append(byte) }
        }
        var type = escaped[...]
        while type.first == 0x20 { type.removeFirst() }
        while type.last == 0x20 { type.removeLast() }
        var body = Self.percentDecoded(bytes[(comma + 1)..<end])
        // `;base64` ends the type, after any spaces, in any case.
        if type.count > 6, String(decoding: type.suffix(6), as: UTF8.self).lowercased() == "base64" {
            var head = type.dropLast(6)
            while head.last == 0x20 { head.removeLast() }
            if head.last == 0x3B { // ;
                guard let decoded = Self.forgivingBase64(body, maximumBytes: maximumBytes) else { return nil }
                body = decoded
                type = head.dropLast()
            }
        }
        guard body.count <= maximumBytes else { return nil }
        mediaType = type.first == 0x3B ? "text/plain" : Self.essence(type) ?? "text/plain"
        self.body = Data(body)
    }

    /// Whether a reference is a `data:` URL, by its scheme as URL parsing reads it, whether or not
    /// the processor can read the rest.
    static func isDataURL(_ reference: String) -> Bool { afterScheme(reference) != nil }

    /// What follows `data:`, past the C0 controls and spaces round the reference and without its
    /// tabs and newlines; nil where it has another scheme or none.
    private static func afterScheme(_ reference: String) -> [UInt8]? {
        let bytes = reference.utf8
        guard let first = bytes.firstIndex(where: { $0 > 0x20 }), let last = bytes.lastIndex(where: { $0 > 0x20 }) else { return nil }
        let kept = bytes[first...last].filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        // A letter is matched in either case; the colon is itself.
        guard kept.count >= 5, zip(kept, "data:".utf8).allSatisfy({ ($0 | ($1 == 0x3A ? 0 : 0x20)) == $1 }) else { return nil }
        return Array(kept.dropFirst(5))
    }

    private static func percentDecoded(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == 0x25, index + 2 < bytes.endIndex, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    /// Infra's forgiving-base64 decode: ASCII white space is left out, and one or two `=` at the
    /// end of a whole number of quartets; a lone sextet at the end, or any other character, fails.
    /// The bits a short final quartet leaves over are dropped, whatever they are.
    private static func forgivingBase64(_ bytes: [UInt8], maximumBytes: Int) -> [UInt8]? {
        var text = bytes.filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0C && $0 != 0x0D && $0 != 0x20 }
        if text.count % 4 == 0, text.last == 0x3D { // =
            text.removeLast()
            if text.last == 0x3D { text.removeLast() }
        }
        let count = text.count / 4 * 3 + max(0, text.count % 4 - 1)
        guard text.count % 4 != 1, count <= maximumBytes else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(count)
        var buffer: UInt32 = 0, bits = 0
        for byte in text {
            let value: UInt8
            switch byte {
            case 0x41...0x5A: value = byte - 0x41
            case 0x61...0x7A: value = byte - 0x61 + 26
            case 0x30...0x39: value = byte - 0x30 + 52
            case 0x2B: value = 62 // +
            case 0x2F: value = 63 // /
            default: return nil
            }
            buffer = buffer << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return output
    }

    /// A MIME type's essence as the MIME Sniffing standard parses one: a type and a subtype of
    /// HTTP token characters round a `/`, in lower case, the parameters after a `;` set aside.
    private static func essence(_ type: ArraySlice<UInt8>) -> String? {
        let space: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        func isToken(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
        var text = type
        while let first = text.first, space.contains(first) { text.removeFirst() }
        while let last = text.last, space.contains(last) { text.removeLast() }
        guard let slash = text.firstIndex(of: 0x2F) else { return nil } // /
        let major = text[..<slash]
        var minor = text[(slash + 1)...].prefix { $0 != 0x3B }
        while let last = minor.last, space.contains(last) { minor.removeLast() }
        guard !major.isEmpty, !minor.isEmpty, major.allSatisfy(isToken), minor.allSatisfy(isToken) else { return nil }
        return String(decoding: major, as: UTF8.self).lowercased() + "/" + String(decoding: minor, as: UTF8.self).lowercased()
    }
}
