import Foundation

extension Fixture {
    /// Documents about which libxml2 2.9 writes to standard error unless a handler takes the
    /// message (#392). A repeated or malformed `xml:id` raises a validity error, which
    /// `XML_PARSE_NOERROR` does not silence; bytes that the declared encoding cannot decode
    /// raise a conversion error, which libxml2 raises with no parser to report it to.
    public enum NoisyMarkup {
        /// The reviewer's file on #392, byte for byte: 147 bytes, no final newline.
        public static let repeatedID = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect xml:id="a" width="1" height="1"/>\
            <rect xml:id="a" width="1" height="1"/></svg>
            """.utf8)
        /// An `xml:id` that is not an NCName.
        public static let invalidID = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect xml:id="1 a" width="1" height="1"/></svg>
            """.utf8)
        /// An undeclared prefix, a relative namespace name, an undeclared entity and an unknown
        /// XML version: messages that `XML_PARSE_NOERROR` and `XML_PARSE_NOWARNING` do silence.
        public static let otherMessages = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><q:rect width=\"1\" height=\"1\"/></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:r=\"relative\" width=\"10\" height=\"10\"><r:rect/></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><title>&nosuch;</title></svg>",
            "<?xml version=\"1.5\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>",
        ].map { Data($0.utf8) }

        /// An SVG that declares `encoding` and holds `bytes` in its title, which that encoding
        /// cannot decode.
        public static func undecodableSVG(_ encoding: String = "US-ASCII", _ bytes: [UInt8] = [0xE9]) -> Data {
            undecodable(encoding, bytes, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><title>",
                        "</title><rect width=\"1\" height=\"1\"/></svg>")
        }

        /// An XHTML content document that declares `encoding` and holds `bytes` in a paragraph,
        /// which that encoding cannot decode.
        public static func undecodableXHTML(_ encoding: String = "US-ASCII", _ bytes: [UInt8] = [0xE9]) -> Data {
            undecodable(encoding, bytes, "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><p>",
                        "</p></body></html>")
        }

        /// Encodings with a byte sequence each cannot decode: libxml2's own ASCII decoder, and
        /// Shift_JIS, which it decodes by a system converter.
        public static let undecodableEncodings: [(encoding: String, bytes: [UInt8])] = [("US-ASCII", [0xE9]), ("Shift_JIS", [0x81, 0x20, 0xFF])]

        /// An XHTML content document whose paragraphs repeat an `xml:id`.
        public static let repeatedIDXHTML = Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head>\
            <body><p xml:id="a">One</p><p xml:id="a">Two</p><p xml:id="1 b">Three</p></body></html>
            """.utf8)

        /// Markup that is not well-formed XML, so the HTML parser reads it, with repeated `id`
        /// and `name` values, which that parser registers as IDs.
        public static let repeatedIDHTML = Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head>\
            <body><p id="a">One<p id="a">Two<a name="b"></a><a name="b"></a><p xml:id="c">Three<p xml:id="c">Four</body></html>
            """.utf8)

        private static func undecodable(_ encoding: String, _ bytes: [UInt8], _ before: String, _ after: String) -> Data {
            Data("<?xml version=\"1.0\" encoding=\"\(encoding)\"?>\(before)caf".utf8) + bytes + Data(after.utf8)
        }
    }
}
