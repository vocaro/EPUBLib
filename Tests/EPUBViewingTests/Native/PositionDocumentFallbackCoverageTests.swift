import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

/// A content document that is not well-formed XML is read by libxml2's HTML parser, which is
/// given UTF-8 and would end its input at a NUL. These hold the reader to showing such a
/// section's text in whatever encoding the XML parser would have read it, and all of it around
/// a NUL, without the fallback ever being given a declaration the screen did not see.
final class PositionDocumentFallbackCoverageTests: XCTestCase {
    private typealias S = SectionContentSupport

    private static let xhtml = #"xmlns="http://www.w3.org/1999/xhtml""#
    private static let head = "<head><title>T</title></head>"
    private static let utf16 = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>"

    private func parse(_ data: Data, limits: ContentLimits = .init()) throws -> ContentDocument {
        try ContentDocument.parse(data, path: "fallback.xhtml", limits: limits)
    }
    private func parse(_ markup: String) throws -> ContentDocument { try parse(Data(markup.utf8)) }
    private func page(_ body: String, prolog: String = "") -> String { "\(prolog)<html \(Self.xhtml)>\(Self.head)<body>\(body)</body></html>" }
    /// `prefix`, `bytes` and `suffix` in a paragraph of a document that declares `encoding`.
    private func declared(_ encoding: String, _ bytes: [UInt8], after prefix: String = "caf", before suffix: String = " one", tail: String = "<br>") -> Data {
        Data("<?xml version=\"1.0\" encoding=\"\(encoding)\"?><html \(Self.xhtml)>\(Self.head)<body><p>\(prefix)".utf8) + Data(bytes)
            + Data("\(suffix)</p>\(tail)<p>after</p></body></html>".utf8)
    }
    /// Elements with their attributes and text as itself, in document order.
    private func model(_ document: ContentDocument) -> [String] {
        document.nodes.map { node in
            node.isElement ? "<\(node.name)\(node.attributes.map { " \($0.name)=\($0.value.debugDescription)" }.joined())>" : node.text
        }
    }
    private func bodyModel(_ document: ContentDocument) -> [String] {
        guard let body = document.body else { return [] }
        return Array(model(document)[(body.order + 1)..<(body.subtreeEnd + 1)])
    }
    private func bodyText(_ document: ContentDocument) -> String { document.body?.textContent ?? "" }
    private func firstParagraph(_ document: ContentDocument) -> String? { document.nodes.first { $0.isHTML("p") }?.textContent }
    private func assertRecoveredWithoutCFIs(_ document: ContentDocument, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(document.recoveredAsHTML, label, file: file, line: line)
        XCTAssertFalse(document.canResolveCFIs, label, file: file, line: line)
        if let text = document.nodes.first(where: \.isText) {
            XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(text), to: DOMPosition(text, text.utf16Length), in: document), "", label, file: file, line: line)
        }
        XCTAssertNil(EPUBCFI.resolve(localPath: "/4/2/1:0", in: document), label, file: file, line: line)
    }
    private func assertThrows(_ expected: ContentDocumentError, _ label: String, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () throws -> ContentDocument) {
        XCTAssertThrowsError(try body(), label, file: file, line: line) { XCTAssertEqual($0 as? ContentDocumentError, expected, label, file: file, line: line) }
    }
    private func section(_ files: [String: Data], at index: Int = 0) throws -> SectionText {
        var all = try Fixture.files()
        all.merge(files) { _, replacement in replacement }
        let book = try EPUBPublication.open(data: try Fixture.archive(all))
        return SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: index, typography: NativeTypography(),
                                                        fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
    }

    /// Every way a document can be UTF-16 or UTF-32: either byte order, with a byte-order mark
    /// or without, before an XML declaration or not.
    private static let wide: [(label: String, mark: [UInt8], encoding: String.Encoding, declaration: String)] = [
        ("UTF-16 little endian with a mark", [0xFF, 0xFE], .utf16LittleEndian, ""),
        ("UTF-16 big endian with a mark", [0xFE, 0xFF], .utf16BigEndian, ""),
        ("UTF-16 little endian with a mark and a declaration", [0xFF, 0xFE], .utf16LittleEndian, utf16),
        ("UTF-16 big endian with a mark and a declaration", [0xFE, 0xFF], .utf16BigEndian, utf16),
        ("UTF-16 little endian with a declaration", [], .utf16LittleEndian, utf16),
        ("UTF-16 big endian with a declaration", [], .utf16BigEndian, utf16),
        ("UTF-16 little endian with neither", [], .utf16LittleEndian, ""),
        ("UTF-16 big endian with neither", [], .utf16BigEndian, ""),
        ("UTF-32 little endian with a mark", [0xFF, 0xFE, 0, 0], .utf32LittleEndian, ""),
        ("UTF-32 big endian with a mark", [0, 0, 0xFE, 0xFF], .utf32BigEndian, ""),
        ("UTF-32 little endian without a mark", [], .utf32LittleEndian, ""),
        ("UTF-32 big endian without a mark", [], .utf32BigEndian, ""),
    ]
    private func encoded(_ markup: String, _ variant: (label: String, mark: [UInt8], encoding: String.Encoding, declaration: String)) throws -> Data {
        Data(variant.mark) + (try XCTUnwrap((variant.declaration + markup).data(using: variant.encoding), variant.label))
    }

    // MARK: - UTF-16 and UTF-32

    /// The same section in UTF-8 and in each wide encoding is the same tree: the stray sign, the
    /// references, the astral character and the attribute as well as the text.
    func testAMalformedSectionInUTF16OrUTF32IsTheTreeOfItsUTF8Twin() throws {
        let markup = page("<p id=\"one\" title=\"caf\u{E9} < th\u{E9}\">caf\u{E9} \u{1F600} one<br>two &amp; three&nbsp;&mdash; x < y</p><p>after</p>")
        let twin = try parse(markup)
        assertRecoveredWithoutCFIs(twin, "UTF-8")
        XCTAssertEqual(bodyModel(twin), ["<p id=\"one\" title=\"caf\u{E9} < th\u{E9}\">", "caf\u{E9} \u{1F600} one", "<br>", "two & three\u{A0}\u{2014} x < y", "<p>", "after"])
        for variant in Self.wide {
            let document = try parse(try encoded(markup, variant))
            assertRecoveredWithoutCFIs(document, variant.label)
            XCTAssertEqual(model(document), model(twin), variant.label)
            XCTAssertEqual(document.element(id: "one")?.children.first?.utf16Length, 11, variant.label)
        }
    }

    /// Where the XML parser can tell the encoding (a mark, or `<?xml` in UTF-16, or UTF-32 big
    /// endian without a mark), an unclosed tag does not change the characters it read. The
    /// screen tells the rest, which the XML parser cannot read at all.
    func testAnUnclosedTagDoesNotChangeTheCharactersOfAWideDocument() throws {
        var readAsXML: [String] = []
        for variant in Self.wide {
            let strict = try parse(try encoded(page("<p>caf\u{E9} \u{4E2D}\u{6587} \u{1F600}</p><p>after</p>"), variant))
            let recovered = try parse(try encoded(page("<p>caf\u{E9} \u{4E2D}\u{6587} \u{1F600}</p><br><p>after</p>"), variant))
            XCTAssertTrue(recovered.recoveredAsHTML, variant.label)
            XCTAssertEqual(bodyText(recovered), "caf\u{E9} \u{4E2D}\u{6587} \u{1F600}after", variant.label)
            XCTAssertEqual(bodyText(strict), bodyText(recovered), variant.label)
            if !strict.recoveredAsHTML { readAsXML.append(variant.label) }
        }
        for label in Self.wide[..<6].map(\.label) { XCTAssertTrue(readAsXML.contains(label), "\(label) is no longer read as XML, so nothing was compared") }
    }

    /// A document with no namespace on its root is well-formed XML that the reader reads as
    /// HTML, as foliate did. In UTF-16 that was two replacement characters too.
    func testAWellFormedDocumentReadAsHTMLIsDecodedToo() throws {
        let markup = "<html><head><title>T</title></head><body><p>caf\u{E9}<span/> cr\u{E8}me</p></body></html>"
        let twin = try parse(markup)
        XCTAssertTrue(twin.recoveredAsHTML)
        for variant in Self.wide[..<6] {
            let document = try parse(try encoded(markup, variant))
            assertRecoveredWithoutCFIs(document, variant.label)
            XCTAssertEqual(model(document), model(twin), variant.label)
            XCTAssertEqual(bodyText(document), "caf\u{E9} cr\u{E8}me", variant.label)
        }
    }

    /// Half a code unit at the end of the file is no character, to the screen and the XML parser
    /// as here. A lone surrogate the screen refuses before any parser runs.
    func testWideBytesThatAreNotCharacters() throws {
        let markup = page("<p>one<br>two</p>")
        for variant in Self.wide[..<2] {
            let data = try encoded(markup, variant)
            XCTAssertEqual(bodyModel(try parse(data + Data([0x61]))), ["<p>", "one", "<br>", "two"], variant.label)
            var surrogate = try XCTUnwrap("<p>".data(using: variant.encoding))
            surrogate.append(contentsOf: variant.encoding == .utf16LittleEndian ? [0x00, 0xD8] : [0xD8, 0x00])
            assertThrows(.unsafeMarkup("fallback.xhtml"), variant.label) { try self.parse(data + surrogate) }
        }
    }

    /// Without a byte-order mark it is a NUL among the first bytes that tells UTF-16 or UTF-32,
    /// as one stands beside the first characters of markup. Bytes that hold no markup once
    /// decoded are not a document in that encoding: a spine item of another kind, or text that a
    /// NUL strayed into. They are refused as they were when the NUL ended the parser's input,
    /// and the section says it could not be shown instead of showing what they decode to.
    func testBytesThatOnlyANULTellsAsWideAndThatHoldNoMarkupAreRefused() throws {
        let binary: [(String, [UInt8])] = [
            ("data that begins with a NUL", [0x00, 0x01, 0x02, 0xFE, 0xFF, 0x00, 0x7F]), ("data with a NUL second", [0x7F, 0x00, 0x45, 0x4C, 0x46, 0x02]),
            ("data that begins with three", [0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x41]), ("text with a NUL second", Array("a\u{0}bc d".utf8)),
        ]
        for (label, bytes) in binary {
            XCTAssertTrue(XMLSafety.hasSafeDeclarations(Data(bytes)), "\(label): the screen refuses these bytes, so this is no test of the fallback")
            assertThrows(.malformed("fallback.xhtml"), label) { try self.parse(Data(bytes)) }
        }
        let text = try section(["OPS/one.xhtml": Data(binary[0].1)])
        XCTAssertTrue(text.report.withheld)
        XCTAssertEqual(text.string.string, "This section could not be shown.")
        // With a byte-order mark the encoding is said, and text without markup is text.
        for variant in Self.wide where !variant.mark.isEmpty && variant.declaration.isEmpty {
            XCTAssertEqual(try parse(try encoded("caf\u{E9} seulement", variant)).body?.textContent, "caf\u{E9} seulement", variant.label)
        }
        // And markup without a mark is markup, whatever its first character.
        for variant in Self.wide where variant.mark.isEmpty && variant.declaration.isEmpty {
            XCTAssertEqual(try parse(try encoded("\n<p>caf\u{E9}<br>seulement", variant)).body?.textContent, "caf\u{E9}seulement", variant.label)
        }
    }

    // MARK: - An encoding named in the XML declaration

    /// EPUB allows only UTF-8 and UTF-16, but libxml2 honours whatever the declaration names,
    /// so a well-formed section in ISO-8859-1 is read. With an unclosed tag it read `caf\u{FFFD}`.
    func testADeclaredSingleByteEncodingShowsItsText() throws {
        let cases: [(String, [UInt8], String)] = [
            ("ISO-8859-1", [0xE9], "caf\u{E9} one"), ("iso-8859-1", [0xE9, 0xA0, 0xFF], "caf\u{E9}\u{A0}\u{FF} one"), ("latin1", [0xE9], "caf\u{E9} one"),
            ("windows-1252", [0xE9, 0x20, 0x93, 0x97, 0x94, 0x80], "caf\u{E9} \u{201C}\u{2014}\u{201D}\u{20AC} one"),
            ("ISO-8859-15", [0xE9, 0xA4], "caf\u{E9}\u{20AC} one"), ("ISO-8859-2", [0xB3, 0xF3], "caf\u{142}\u{F3} one"),
            ("windows-1251", [0xEA, 0xE0, 0xF4, 0xE5], "caf\u{43A}\u{430}\u{444}\u{435} one"), ("KOI8-R", [0xCB, 0xC1], "caf\u{43A}\u{430} one"),
            ("ISO-8859-7", [0xE1, 0xE2], "caf\u{3B1}\u{3B2} one"), ("macintosh", [0x8E], "caf\u{E9} one"), ("US-ASCII", [0x65], "cafe one"),
        ]
        for (name, bytes, expected) in cases {
            let document = try parse(declared(name, bytes))
            assertRecoveredWithoutCFIs(document, name)
            XCTAssertEqual(bodyModel(document), ["<p>", expected, "<br>", "<p>", "after"], name)
            let strict = try parse(declared(name, bytes, tail: ""))
            XCTAssertFalse(strict.recoveredAsHTML, name)
            XCTAssertEqual(firstParagraph(strict), expected, "\(name): the XML parser reads other characters")
        }
        // In an attribute value and in the raw text of a style sheet as in text.
        let places = try parse(Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><html><head><title>caf".utf8) + Data([0xE9]) + Data("</title><style>p::before { content: \"".utf8)
            + Data([0xAB]) + Data("\" }</style></head><body><p title=\"".utf8) + Data([0xFC, 0x62, 0x65, 0x72]) + Data("\">x<br></p></body></html>".utf8))
        XCTAssertEqual(places.head?.textContent, "caf\u{E9}p::before { content: \"\u{AB}\" }")
        XCTAssertEqual(places.nodes.first { $0.isHTML("p") }?.attribute("title"), "\u{FC}ber")
    }

    /// For every byte of each single-byte encoding, the fallback reads the character the XML
    /// parser reads in the same document without its unclosed tag: its tree is that of the
    /// document written in UTF-8 with that character. A byte the XML parser cannot decode leaves
    /// it no reading, and the document is read as it was before, as UTF-8.
    func testEveryByteOfASingleByteEncodingIsTheCharacterTheXMLParserReads() throws {
        let names = ["ISO-8859-1", "ISO-8859-2", "ISO-8859-5", "ISO-8859-7", "ISO-8859-8", "ISO-8859-9", "ISO-8859-13", "ISO-8859-15", "windows-1250", "windows-1251",
                     "windows-1252", "windows-1253", "windows-1255", "windows-1257", "macintosh", "KOI8-R", "IBM437", "IBM850", "TIS-620", "US-ASCII"]
        var decoded = 0, undecodable = 0
        for name in names {
            for byte in UInt8(0x80)...0xFF {
                let label = "\(name) 0x\(String(byte, radix: 16))"
                let recovered = try parse(declared(name, [byte], after: "a", before: "b"))
                XCTAssertTrue(recovered.recoveredAsHTML, label)
                let strict = try parse(declared(name, [byte], after: "a", before: "b", tail: ""))
                guard !strict.recoveredAsHTML, let text = firstParagraph(strict) else {
                    undecodable += 1
                    XCTAssertEqual(firstParagraph(recovered), "a\u{FFFD}b", label)
                    continue
                }
                decoded += 1
                XCTAssertEqual(text.unicodeScalars.count, 3, label)
                XCTAssertEqual(firstParagraph(recovered), text, label)
                let twin = try parse("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html \(Self.xhtml)>\(Self.head)<body><p>\(text)</p><br><p>after</p></body></html>")
                XCTAssertEqual(model(recovered), model(twin), label)
            }
        }
        XCTAssertGreaterThan(decoded, 1_800, "the XML parser has stopped reading these encodings, so nothing was compared")
        XCTAssertGreaterThanOrEqual(undecodable, 128, "US-ASCII has no byte above 0x7F")
    }

    /// The encodings of more than one byte that libxml2 reads are read alike, where one byte
    /// may be half a character or (ISO-2022-JP, UTF-7) an ASCII byte no ASCII character.
    func testADeclaredMultibyteEncodingIsDecodedAsTheXMLParserDecodesIt() throws {
        let cases: [(String, [UInt8], String)] = [
            ("Shift_JIS", [0x93, 0xFA, 0x96, 0x7B, 0x83, 0x5C], "\u{65E5}\u{672C}\u{30BD}"), ("EUC-JP", [0xC6, 0xFC, 0xCB, 0xDC], "\u{65E5}\u{672C}"),
            ("ISO-2022-JP", [0x1B, 0x24, 0x42, 0x46, 0x7C, 0x4B, 0x5C, 0x1B, 0x28, 0x42], "\u{65E5}\u{672C}"), ("GBK", [0xD6, 0xD0, 0xCE, 0xC4], "\u{4E2D}\u{6587}"),
            ("GB18030", [0xD6, 0xD0, 0x81, 0x30, 0x84, 0x36], "\u{4E2D}\u{A5}"), ("Big5", [0xA4, 0xA4, 0xA4, 0xE5], "\u{4E2D}\u{6587}"),
            ("EUC-KR", [0xC7, 0xD1, 0xB1, 0xB9], "\u{D55C}\u{AD6D}"), ("UTF-7", Array("+AOk-+ZeU-".utf8), "\u{E9}\u{65E5}"),
        ]
        var compared = 0
        for (name, bytes, expected) in cases {
            let strict = try parse(declared(name, bytes, tail: ""))
            let recovered = try parse(declared(name, bytes))
            XCTAssertTrue(recovered.recoveredAsHTML, name)
            XCTAssertEqual(firstParagraph(recovered), firstParagraph(strict), name)
            guard !strict.recoveredAsHTML else { continue } // An encoding this platform's libxml2 has no decoder for.
            compared += 1
            XCTAssertEqual(firstParagraph(strict), "caf\(expected) one", name)
            XCTAssertEqual(bodyModel(recovered), ["<p>", "caf\(expected) one", "<br>", "<p>", "after"], name)
        }
        XCTAssertGreaterThanOrEqual(compared, 6, "the XML parser has stopped reading these encodings, so nothing was compared")
    }

    /// What the declaration names is whatever the XML parser reads in it, and nothing where that
    /// parser rejects it. Each form here is read by the XML parser in a well-formed document
    /// and by the fallback in the same document with an unclosed tag, and the two agree.
    func testTheFallbackReadsTheDeclarationAsTheXMLParserReadsIt() throws {
        let named = [
            "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>", "<?xml version='1.0' encoding='iso-8859-1'?>", "<?xml version=\"1.0\"  encoding = \"ISO-8859-1\" ?>",
            "<?xml\tversion=\"1.0\"\nencoding=\"ISO-8859-1\"\r\n?>", "<?xml version=\"1.0\" encoding=\"ISO-8859-1\" standalone=\"yes\"?>", "<?xml version=\"1.1\" encoding=\"ISO-8859-1\"?>",
            "\u{FEFF}<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>", "<?xml version=\"1.0\" encoding=\"ISO_8859-1\"?>", "<?xml version=\"1.0\" encoding=\"l1\"?>",
        ]
        let unnamed = [
            "", "<?xml version=\"1.0\"?>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<?xml version=\"1.0\" encoding=\"utf8\"?>", "\u{FEFF}<?xml version=\"1.0\" encoding=\"utf-8\"?>",
            "<?xml encoding=\"ISO-8859-1\"?>", "<?xml version=\"1.0\" encoding=\"ISO-8859-1\" bogus?>", "<?xml version=\"2.0\" encoding=\"ISO-8859-1\"?>",
            "<?xml version=\"1.0\" standalone=\"yes\" encoding=\"ISO-8859-1\"?>", "<?xml version=\"1.0\" encoding=\"ISO-8859-1?>", "<?xml version=\"1.0\" encoding=\"ISO 8859-1\"?>",
            "<?xml version=\"1.0\" encoding=\"\"?>", "<?XML version=\"1.0\" encoding=\"ISO-8859-1\"?>", " <?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>",
            "<?xmlversion=\"1.0\" encoding=\"ISO-8859-1\"?>", "<?xml-stylesheet href=\"a.css\" encoding=\"ISO-8859-1\"?>", "<!-- --><?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>",
            "<?xml version=\"1.0\" encoding=\"x-no-such-encoding\"?>", "<?xml version=\"1.0\" encoding=\"UTF-16\"?>", "<?xml version=\"1.0\" encoding=\"UTF-16LE\"?>",
            "<?xml version=\"1.0\" encoding=\"UCS-4\"?>", "<?xml version=\"1.0\" encoding=\"IBM037\"?>", "<?xml version=\"1.0\" encoding=\"HTML\"?>",
        ]
        // 0xE9 is `é` in ISO-8859-1 and no character in UTF-8.
        func document(_ declaration: String, tail: String) -> Data {
            Data("\(declaration)<html \(Self.xhtml)>\(Self.head)<body><p>caf".utf8) + Data([0xE9]) + Data("!</p>\(tail)</body></html>".utf8)
        }
        for declaration in named {
            let label = declaration.debugDescription
            let strict = try parse(document(declaration, tail: ""))
            XCTAssertFalse(strict.recoveredAsHTML, label)
            XCTAssertEqual(firstParagraph(strict), "caf\u{E9}!", label)
            let recovered = try parse(document(declaration, tail: "<br>"))
            XCTAssertTrue(recovered.recoveredAsHTML, label)
            XCTAssertEqual(firstParagraph(recovered), "caf\u{E9}!", label)
        }
        for declaration in unnamed {
            let label = declaration.debugDescription
            // Not ISO-8859-1 to the XML parser, which therefore cannot read the bytes at all.
            XCTAssertTrue(try parse(document(declaration, tail: "")).recoveredAsHTML, label)
            let recovered = try parse(document(declaration, tail: "<br>"))
            XCTAssertTrue(recovered.recoveredAsHTML, label)
            XCTAssertEqual(firstParagraph(recovered), "caf\u{FFFD}!", label)
        }
    }

    /// The same agreement over generated declarations, sound and broken: whenever the XML
    /// parser reads the well-formed document, the fallback reads the same characters in its
    /// twin, and otherwise it reads the bytes as UTF-8, as it did before.
    func testGeneratedDeclarationsAreReadAsTheXMLParserReadsThem() throws {
        var state: UInt64 = 201
        func random(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        func pick(_ choices: [String]) -> String { choices[random(choices.count)] }
        /// `sound` five times in six, and otherwise one of `broken`.
        func mostly(_ sound: String, _ broken: [String]) -> String { random(6) == 0 ? pick(broken) : sound }
        let names = ["ISO-8859-1", "ISO-8859-1", "iso-8859-15", "windows-1252", "windows-1251", "KOI8-R", "US-ASCII", "UTF-8", "utf-8", "UTF8", "latin1", "macintosh", "Shift_JIS",
                     "UTF-7", "UTF-16", "utf-16le", "x-bogus", "", "8859-1", "ISO 8859-1", "IBM037"]
        var readAsXML = 0, readAsBefore = 0
        for _ in 0..<4_000 {
            let quote = pick(["\"", "\"", "'"]), other = quote == "'" ? "\"" : "'"
            var declaration = pick(["", "", "", "\u{FEFF}"]) + mostly("<?xml", ["<?XML", " <?xml", "<?xm", "<!-- --><?xml"]) + mostly(" ", ["", "\t", "\n", "  "])
            declaration += mostly("version=\(quote)1.0\(quote)", ["version=\(other)1.1\(other)", "version=\(quote)2.0\(quote)", "", "version=1.0", "VERSION=\(quote)1.0\(quote)"]) + mostly(" ", ["", "\r\n", "  "])
            declaration += mostly("encoding", ["Encoding", "enc", ""]) + mostly("=", [" = ", "", "=="]) + quote + pick(names) + mostly(quote, [other, ""]) + mostly("", [" ", "\n"])
            declaration += mostly("", [" standalone=\(quote)yes\(quote)", " standalone=\(quote)no\(quote) ", " bogus", " standalone=\(quote)maybe\(quote)"]) + mostly("?>", [" ?>", ">", "?", "? >"])
            let bytes: [UInt8] = [[0xE9], [0xA4, 0xE9], [0xC3, 0xA9], [0x80], [0xCB, 0xC1], [0x65], [0x93, 0xFA]][random(7)]
            func document(_ tail: String) -> Data {
                Data("\(declaration)<html \(Self.xhtml)>\(Self.head)<body><p>a".utf8) + Data(bytes) + Data("b</p>\(tail)</body></html>".utf8)
            }
            let label = "\(declaration.debugDescription) before \(bytes)"
            // The screen refuses a declaration left open, in either document.
            guard let strict = try? parse(document("")), let recovered = try? parse(document("<br>")) else { continue }
            guard recovered.recoveredAsHTML else { return XCTFail("an unclosed tag is well-formed in \(label)") }
            if !strict.recoveredAsHTML {
                readAsXML += 1
                guard firstParagraph(recovered) == firstParagraph(strict) else {
                    return XCTFail("\(label): the XML parser reads \(String(describing: firstParagraph(strict))) and the fallback \(String(describing: firstParagraph(recovered)))")
                }
            } else {
                // No reading of the XML parser's to agree with: the parser is given the bytes
                // it was given before, which it reads as UTF-8.
                readAsBefore += 1
                let data = document("<br>"), rewritten = HTMLEntities.numericReferences(in: data)
                let source = try ContentDocument.htmlSource(data, rewritten: rewritten, path: "generated.xhtml", limits: .init())
                guard source.data == HTMLStraySigns.replaced(in: rewritten, limit: .max)?.data else {
                    return XCTFail("\(label): the XML parser does not read the document, and the fallback decodes it")
                }
            }
        }
        XCTAssertGreaterThan(readAsXML, 400, "the generator has stopped making declarations the XML parser reads")
        XCTAssertGreaterThan(readAsBefore, 400, "the generator has stopped making declarations it rejects")
    }

    /// Bytes the declared encoding cannot decode leave the XML parser no reading to agree with,
    /// and the declaration is more likely wrong than the text: `us-ascii` over UTF-8 is the
    /// common case. The document is read as it was before, as UTF-8 with a replacement
    /// character for what is not, wherever in it the undecodable byte stands.
    func testBytesTheDeclaredEncodingCannotDecodeAreReadAsUTF8AsBefore() throws {
        XCTAssertEqual(firstParagraph(try parse(declared("US-ASCII", Array("\u{E9} \u{2014}".utf8)))), "caf\u{E9} \u{2014} one")
        XCTAssertEqual(firstParagraph(try parse(declared("us-ascii", [0xE9]))), "caf\u{FFFD} one")
        XCTAssertEqual(firstParagraph(try parse(declared("x-no-such-encoding", Array("\u{E9}".utf8)))), "caf\u{E9} one")
        XCTAssertEqual(firstParagraph(try parse(declared("UTF-8", [0xE9]))), "caf\u{FFFD} one")
        // Beside a character the encoding does decode (`good`, which is no UTF-8), bytes it does
        // not: first in the document's text, in the middle of it, and last, when the decoder has
        // read everything else. Were the document decoded up to them, or past them, the
        // character would show.
        let cases: [(String, [UInt8], [UInt8])] = [("Shift_JIS", [0x93, 0xFA], [0x81, 0x20]), ("EUC-JP", [0xC6, 0xFC], [0xC6]), ("GBK", [0xD6, 0xD0], [0x81, 0x20]),
                                                   ("US-ASCII", [], [0xE9])]
        for (name, good, bad) in cases {
            let declaration = Data("<?xml version=\"1.0\" encoding=\"\(name)\"?>".utf8)
            let readable = try parse(declaration + Data("<html \(Self.xhtml)>\(Self.head)<body><p>".utf8) + Data(good) + Data("</p></body></html>".utf8))
            XCTAssertFalse(readable.recoveredAsHTML, "\(name) is no longer read by the XML parser, so nothing is shown here")
            let texts: [(String, Data)] = [
                ("first", Data("<html><body><p>".utf8) + Data(bad) + Data(" x<br>y ".utf8) + Data(good) + Data("</p><p>after</p></body></html>".utf8)),
                ("in the middle", Data("<html><body><p>x<br>y ".utf8) + Data(good) + Data(" ".utf8) + Data(bad) + Data(" z</p><p>after</p></body></html>".utf8)),
                ("last", Data("<html><body><p>x<br>y ".utf8) + Data(good) + Data("</p><p>after</p></body></html>".utf8) + Data(bad)),
            ]
            for (place, text) in texts {
                let label = "\(name), \(place)"
                let document = try parse(declaration + text)
                let asUTF8 = try parse(Data("<?xml version=\"1.0\"?>".utf8) + text)
                XCTAssertEqual(model(document), model(asUTF8), label)
                XCTAssertTrue(document.root.textContent.hasSuffix("after"), label)
                // libxml2 passes over what follows `</html>`, so there ASCII leaves nothing to see.
                XCTAssertEqual(document.root.textContent.unicodeScalars.contains("\u{FFFD}"), !(place == "last" && good.isEmpty), label)
            }
        }
    }

    /// The XML parser does not read an HTML `<meta charset>`, so the fallback does not either:
    /// the same section must not change its characters for an unclosed tag.
    func testAMetaCharsetIsNotRead() throws {
        for meta in ["<meta charset=\"ISO-8859-1\"/>", "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=ISO-8859-1\"/>", "<meta charset=\"UTF-16\"/>", "<meta charset=\"UTF-7\"/>"] {
            func document(_ tail: String) -> String { "<html \(Self.xhtml)><head>\(meta)<title>T</title></head><body><p>caf\u{E9} \u{C3}\u{A9} +AOk-</p>\(tail)</body></html>" }
            let strict = try parse(document(""))
            XCTAssertFalse(strict.recoveredAsHTML, meta)
            let recovered = try parse(document("<br>"))
            XCTAssertTrue(recovered.recoveredAsHTML, meta)
            XCTAssertEqual(firstParagraph(recovered), "caf\u{E9} \u{C3}\u{A9} +AOk-", meta)
            XCTAssertEqual(firstParagraph(recovered), firstParagraph(strict), meta)
        }
        // And an XML declaration is read whatever a `meta` beside it says.
        let both = Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><html><head><meta charset=\"utf-8\"><title>T</title></head><body><p>caf".utf8)
            + Data([0xE9]) + Data("</p></body></html>".utf8)
        XCTAssertEqual(firstParagraph(try parse(both)), "caf\u{E9}")
    }

    // MARK: - Safety

    /// The screen reads a document that is not UTF-16 or UTF-32 as ASCII, and in UTF-7 `<` is
    /// not the byte 0x3C. What the fallback decodes is screened again as the characters it is,
    /// so the parser is never given a declaration the screen did not see.
    func testADeclarationThatOnlyDecodingBringsIntoViewIsRefused() throws {
        let hidden = "<?xml version=\"1.0\" encoding=\"UTF-7\"?>+ADw-!DOCTYPE html [+ADw-!ENTITY e \"hidden\"+AD4-]+AD4-<html><body><p>+ACY-e+ADs- one<br>two</p></body></html>"
        XCTAssertTrue(XMLSafety.hasSafeDeclarations(Data(hidden.utf8)), "the screen reads these bytes, so this is no test of the fallback's own")
        assertThrows(.unsafeMarkup("fallback.xhtml"), "an internal subset in UTF-7") { try self.parse(hidden) }
        for markup in ["+ADw-!ENTITY e \"hidden\"+AD4-", "+ADw-!DOCTYPE html+AD4-[+ADw-!ATTLIST p title CDATA \"hidden\"+AD4-]+AD4-", "+ADw-p title+AD0AIg-open", "+ADw-!-- open"] {
            assertThrows(.unsafeMarkup("fallback.xhtml"), markup) {
                try self.parse("<?xml version=\"1.0\" encoding=\"UTF-7\"?><html><body><p>one<br>two</p>\(markup)</body></html>")
            }
        }
        // The same encoding with nothing to hide is decoded, markup and all.
        let plain = try parse("<?xml version=\"1.0\" encoding=\"UTF-7\"?><html><body><p>caf+AOk- one+ADw-br+AD4-two</p></body></html>")
        XCTAssertEqual(bodyModel(plain), ["<p>", "caf\u{E9} one", "<br>", "two"])
        // In UTF-16 the screen itself reads the characters, and refuses before any parser runs.
        for variant in Self.wide {
            assertThrows(.unsafeMarkup("fallback.xhtml"), variant.label) {
                try self.parse(try self.encoded("<!DOCTYPE html [<!ENTITY e \"hidden\">]><html><body><p>&e; one<br>two</p></body></html>", variant))
            }
        }
    }

    /// The fallback's parser reads no declaration, loads no DTD and reaches no network, whatever
    /// it is given: a DOCTYPE with an external subset, decoded from any encoding, declares
    /// nothing and its entity stays the text the author wrote.
    func testADecodedDoctypeDeclaresAndLoadsNothing() throws {
        let markup = "<!DOCTYPE html PUBLIC \"-//EPUBLib//DTD Missing//EN\" \"http://127.0.0.1:9/missing.dtd\"><html><body><p>&missing; one<br>two</p></body></html>"
        let twin = try parse(markup)
        XCTAssertEqual(bodyModel(twin), ["<p>", "&missing; one", "<br>", "two"])
        for variant in Self.wide { XCTAssertEqual(model(try parse(try encoded(markup, variant))), model(twin), variant.label) }
        let latin = try parse(Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>".utf8) + Data(markup.dropLast("</p></body></html>".count).utf8)
            + Data([0xE9]) + Data("</p></body></html>".utf8))
        XCTAssertEqual(bodyModel(latin), ["<p>", "&missing; one", "<br>", "two\u{E9}"])
    }

    // MARK: - Limits and cost

    /// The file is held to the byte limit, and so is what the parser is given of it once
    /// decoded: half the bytes of UTF-16 in ASCII, and more than the file where one byte or two
    /// are a character of two or three in UTF-8.
    func testDecodedBytesAreHeldToTheByteLimit() throws {
        let markup = "<html><body><p>one<br>two</p></body></html>"
        var limits = ContentLimits()
        for variant in Self.wide[..<2] {
            let data = try encoded(markup, variant)
            limits.bytes = data.count
            XCTAssertEqual(bodyText(try parse(data, limits: limits)), "onetwo", variant.label)
            limits.bytes = data.count - 1
            assertThrows(.limitExceeded("bytes"), variant.label) { try self.parse(data, limits: limits) }
            // Two bytes of UTF-16 that are three of UTF-8.
            let wider = try encoded("<html><body><p>\(String(repeating: "\u{4E2D}", count: 100))<br></p></body></html>", variant)
            limits.bytes = wider.count
            assertThrows(.limitExceeded("bytes"), variant.label) { try self.parse(wider, limits: limits) }
            limits.bytes = (wider.count - 2) / 2 + 200 // A byte for each code unit, and two more for each of the hundred.
            XCTAssertEqual(bodyText(try parse(wider, limits: limits)).utf16.count, 100, variant.label)
            limits.bytes -= 1
            assertThrows(.limitExceeded("bytes"), variant.label) { try self.parse(wider, limits: limits) }
        }
        // One byte of ISO-8859-1 that is two of UTF-8, a hundred times.
        let high = [UInt8](repeating: 0xE9, count: 100)
        let latin = declared("ISO-8859-1", high, after: "", before: "")
        limits.bytes = latin.count + 100
        XCTAssertEqual(firstParagraph(try parse(latin, limits: limits))?.utf16.count, 100)
        limits.bytes -= 1
        assertThrows(.limitExceeded("bytes"), "ISO-8859-1") { try self.parse(latin, limits: limits) }
        // The limit is the fallback's: the file is within it, and is read where it is well-formed.
        XCTAssertFalse(try parse(declared("ISO-8859-1", high, after: "", before: "", tail: ""), limits: limits).recoveredAsHTML)
        // A NUL in markup is the three bytes of U+FFFD, and one in text is none.
        let attribute = "<html><body><p title=\"a\u{0}b\u{0}c\">one<br>two</p></body></html>"
        limits.bytes = attribute.utf8.count + 4
        XCTAssertEqual(try parse(Data(attribute.utf8), limits: limits).nodes.first { $0.isHTML("p") }?.attribute("title"), "a\u{FFFD}b\u{FFFD}c")
        limits.bytes -= 1
        assertThrows(.limitExceeded("bytes"), "a NUL in markup") { try self.parse(Data(attribute.utf8), limits: limits) }
        let text = "<html><body><p>one\u{0}<br>\u{0}two</p></body></html>"
        limits.bytes = text.utf8.count
        XCTAssertEqual(bodyText(try parse(Data(text.utf8), limits: limits)), "onetwo")
    }

    /// Decoding and the reading of NULs each pass over the document once, at any size the byte
    /// limit admits and however many NULs it holds.
    func testDecodingAndNULsAreReadInOnePass() throws {
        func timed(_ label: String, _ data: Data, _ check: (ContentDocument) -> Void) throws {
            let start = Date()
            let document = try parse(data)
            XCTAssertLessThan(Date().timeIntervalSince(start), 30, label)
            XCTAssertTrue(document.recoveredAsHTML, label)
            check(document)
        }
        let count = 1_000_000
        try timed("ISO-8859-1", declared("ISO-8859-1", [UInt8](repeating: 0xE9, count: count), after: "", before: "")) {
            XCTAssertEqual(self.firstParagraph($0)?.utf16.count, count)
        }
        var japanese = [UInt8](repeating: 0x93, count: 2 * count) // 0x93 0xFA is one character of Shift_JIS.
        for index in stride(from: 1, to: japanese.count, by: 2) { japanese[index] = 0xFA }
        try timed("Shift_JIS", declared("Shift_JIS", japanese, after: "", before: "")) {
            XCTAssertEqual(self.firstParagraph($0)?.utf16.count, count)
        }
        try timed("UTF-16", Data([0xFF, 0xFE]) + (try XCTUnwrap(("<html><body><p>" + String(repeating: "\u{E9}", count: count) + "<br></p></body></html>").data(using: .utf16LittleEndian)))) {
            XCTAssertEqual(self.bodyText($0).utf16.count, count)
        }
        for (label, repeated, text) in [("in text", "a\u{0}", String(repeating: "a", count: 300_000)), ("after a sign", "<\u{0}", String(repeating: "<", count: 300_000)),
                                        ("in end tags", "</i\u{0}>", ""), ("in comments", "<!--\u{0}-->", ""), ("after end tags", "</i>\u{0}", ""), ("alone", "\u{0}", ""),
                                        ("in attribute values", "<br title=\"\u{0}\">", "")] {
            // A hundred thousand of what makes an element, which the node limit admits.
            let repeats = repeated.hasPrefix("<br") ? 100_000 : 300_000
            try timed("NULs \(label)", Data(("<html><body><p>" + String(repeating: repeated, count: repeats) + "</p><p>after<br></p></body></html>").utf8)) {
                XCTAssertEqual(self.bodyText($0), text + "after", label)
            }
        }
        // Undecodable bytes by the hundred thousand are one failed decoding, not one each.
        try timed("undecodable", declared("US-ASCII", [UInt8](repeating: 0xE9, count: 300_000), after: "", before: "")) {
            XCTAssertEqual(self.firstParagraph($0)?.unicodeScalars.count, 300_000)
        }
    }

    // MARK: - NUL

    /// libxml2 ended the document at a NUL after a tag or inside one, and read one in text as a
    /// space. HTML ignores U+0000 in the text of a body and reads U+FFFD in markup and in the
    /// raw text of `script` and `style`: no position of a NUL loses the text after it.
    func testNoTextIsLostAtANUL() throws {
        let cases: [(String, String, [String])] = [
            ("after a tag", "<p>a</p>\u{0}<p>after</p>", ["<p>", "a", "<p>", "after"]),
            ("in text", "<p>a\u{0}b</p><p>after</p>", ["<p>", "ab", "<p>", "after"]),
            ("several in text and between tags", "\u{0}<p>\u{0}a\u{0}\u{0}\u{0}b\u{0}</p>\u{0}\u{0}<p>after</p>\u{0}", ["<p>", "ab", "<p>", "after"]),
            ("in a tag name", "<p>a</p><d\u{0}iv>b</div><p>after</p>", ["<p>", "a", "<d>", "b", "<p>", "after"]),
            ("ending a tag name", "<p>a</p><b\u{0}>b</b><p>after</p>", ["<p>", "a", "<b>", "b", "<p>", "after"]),
            ("in an end tag", "<p>a</p\u{0}><p>after</p>", ["<p>", "a", "<p>", "after"]),
            ("in an attribute name", "<p ti\u{0}tle=\"x\">a</p><p>after</p>", ["<p ti=\"\">", "a", "<p>", "after"]),
            ("in an attribute value", "<p title=\"x\u{0}y\" class=c\u{0}d lang='e\u{0}'>a</p><p>after</p>", ["<p title=\"x\u{FFFD}y\" class=\"c\u{FFFD}d\" lang=\"e\u{FFFD}\">", "a", "<p>", "after"]),
            ("in a value after a quoted >", "<p title=\"x > \u{0}y\" cl\u{0}ass=\"c\">a</p><p>after</p>", ["<p title=\"x > \u{FFFD}y\" cl=\"\">", "a", "<p>", "after"]),
            ("between attributes", "<p title=\"x\"\u{0}class=\"c\" \u{0} lang=\"e\">a</p><p>after</p>", ["<p title=\"x\" lang=\"e\">", "a", "<p>", "after"]),
            ("in a comment", "<p>a</p><!-- c\u{0}d --><p>after</p>", ["<p>", "a", "<p>", "after"]),
            ("in a script", "<p>a</p><script>x\u{0}y</script><p>after</p>", ["<p>", "a", "<script>", "x\u{FFFD}y", "<p>", "after"]),
            ("in a style sheet", "<p>a</p><STYLE type=\"text/css\">x\u{0}y</STYLE><p>after</p>", ["<p>", "a", "<style type=\"text/css\">", "x\u{FFFD}y", "<p>", "after"]),
            ("after an empty script", "<p>a</p><script src=\"a.js\"/>x\u{0}y<p>after</p>", ["<p>", "a", "<script src=\"a.js\">", "xy", "<p>", "after"]),
            ("directly after a sign", "<p>a <\u{0} b</p><p>after</p>", ["<p>", "a < b", "<p>", "after"]),
            ("between a sign and a name", "<p>a <\u{0}b> c</p><p>after</p>", ["<p>", "a <b> c", "<p>", "after"]),
            ("between a sign and a slash", "<p>a <\u{0}/p> c</p><p>after</p>", ["<p>", "a </p> c", "<p>", "after"]),
            ("in a reference", "<p>a &am\u{0}p; &#6\u{0}0; &nb\u{0}sp;b</p><p>after</p>", ["<p>", "a & < \u{A0}b", "<p>", "after"]),
            ("in a processing instruction", "<p>a<?pi \u{0} ?> b</p><p>after</p>", ["<p>", "a b", "<p>", "after"]),
        ]
        for (label, body, expected) in cases {
            let document = try parse(page(body))
            assertRecoveredWithoutCFIs(document, label)
            XCTAssertEqual(bodyModel(document), expected, "a NUL \(label)")
            XCTAssertEqual(document.head?.textContent, "T", label)
        }
        // Between the elements of the document it is nothing at all: the tree is that of the
        // same document without it.
        let twin = try parse("<?xml version=\"1.0\"?><html \(Self.xhtml) lang=\"en\">\(Self.head)<body class=\"c\"><p>a<br>b</p></body></html>")
        for markup in ["<?xml version=\"1.0\"?>\u{0}<html \(Self.xhtml) lang=\"en\">\(Self.head)<body class=\"c\"><p>a<br>b</p></body></html>",
                       "<?xml version=\"1.0\"?><html \(Self.xhtml) lang=\"en\">\u{0}\(Self.head)\u{0}<body class=\"c\">\u{0}<p>a<br>b</p></body>\u{0}</html>\u{0}\u{0}\u{0}",
                       "<?xml version=\"1.0\"?><html \(Self.xhtml) lang=\"en\"><head>\u{0}<title>\u{0}T</title></head><body class=\"c\"><p>a<br>\u{0}b</p>\u{0}</body></html>"] {
            XCTAssertEqual(model(try parse(markup)), model(twin), markup.debugDescription)
        }
    }

    /// U+0000 is a character of UTF-16 and UTF-32 and of a declared encoding as it is a byte of
    /// UTF-8, and is read the same once they are decoded.
    func testANULInADecodedDocumentIsReadTheSame() throws {
        let markup = "<html><body><p>a\u{0}b</p>\u{0}<p title=\"x\u{0}y\">c <\u{0} d<br></p><style>e\u{0}f</style><p>apr\u{E8}s</p></body></html>"
        let expected = ["<p>", "ab", "<p title=\"x\u{FFFD}y\">", "c < d", "<br>", "<style>", "e\u{FFFD}f", "<p>", "apr\u{E8}s"]
        XCTAssertEqual(bodyModel(try parse(markup)), expected)
        for variant in Self.wide { XCTAssertEqual(bodyModel(try parse(try encoded(markup, variant))), expected, variant.label) }
        let latin = try parse(Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>".utf8) + (try XCTUnwrap(markup.data(using: .isoLatin1))))
        XCTAssertEqual(bodyModel(latin), expected)
    }

    /// Leaving a NUL out joins the bytes on either side of it. Nothing that was not markup
    /// becomes markup that way, and nothing ends that did not end: where the tokenizer is not
    /// in text the NUL is a character, U+FFFD, as HTML reads it there.
    func testANULNeverCompletesATagACommentOrADeclaration() throws {
        func nodes(_ body: String) throws -> ContentDocument { try parse(page(body)) }
        let comment = try nodes("<p>a</p><!-- b -\u{0}-> <p>hidden</p> --\u{0}> <p>hidden</p> --><p>after</p>")
        XCTAssertEqual(bodyModel(comment), ["<p>", "a", "<p>", "after"], "the comment ended at a `-->` it does not hold")
        let opener = try nodes("<p>a <!-\u{0}- b --> c</p><p>after</p>")
        XCTAssertEqual(bodyModel(opener), ["<p>", "a  c", "<p>", "after"], "`<!-` is not a comment, and ends at the first `>` as it did")
        let style = try nodes("<p>a</p><style>b</sty\u{0}le>c</style\u{0}d>e</style><p>after</p>")
        XCTAssertEqual(bodyModel(style), ["<p>", "a", "<style>", "b</sty\u{FFFD}le>c", "e", "<p>", "after"], "raw text ended at an end tag it does not hold")
        let script = try nodes("<p>a</p><scr\u{0}ipt>b</script><p>after</p>")
        XCTAssertFalse(script.nodes.contains { $0.name == "script" }, "a NUL in a name made a script of it")
        XCTAssertEqual(bodyText(script), "abafter")
        let tag = try nodes("<p>a <\u{0}b>c</b> <\u{0}!-- d --> <\u{0}script>e</script></p><p>after</p>")
        XCTAssertEqual(bodyModel(tag), ["<p>", "a <b>c <!-- d --> <script>e", "<p>", "after"], "a sign before a NUL opened markup")
        let attribute = try nodes("<p><a hr\u{0}ef=\"x\" title=\"a>b\" cl\u{0}ass=\"c\">a</a></p><p>after</p>")
        XCTAssertEqual(try XCTUnwrap(attribute.nodes.first { $0.isHTML("a") }).attributes.map(\.name), ["hr", "title", "cl"])
        // The screen takes this for a declaration that declares nothing, and so does the parser.
        let declaration = try nodes("<p>a</p><!DOC\u{0}TYPE html [<!ENT\u{0}ITY e \"hidden\">]> &e;<p>after</p>")
        XCTAssertEqual(bodyModel(declaration), ["<p>", "a", "]> &e;", "<p>", "after"])
        let cdata = try nodes("<p>a<![CDA\u{0}TA[ b ]]\u{0}> c</p><p>after</p>")
        XCTAssertTrue(bodyText(cdata).hasSuffix("after"))
        // Where a document holds every placeholder a sign could be given, the sign stays a sign
        // and the NUL after it stays between it and the name.
        let every = (0xFDD0...0xFDEF).map { "&#\($0);" }.joined()
        let kept = try nodes("<p>\(every) a <\u{0}b>c</b> d</p><p>after</p>")
        XCTAssertFalse(kept.nodes.contains { $0.isHTML("b") }, "a NUL left out made a tag of the sign before it")
        XCTAssertTrue(bodyText(kept).hasSuffix("after"))
        // Nor is a character made of halves a NUL stood between, in bytes that are not UTF-8:
        // here the three bytes of the noncharacter that a stray sign is given to the parser as.
        let halves = try parse(Data("<html><body><p>".utf8) + Data([0xEF, 0x00, 0xB7, 0x00, 0x00, 0x90]) + Data(" x < y</p><p>after</p></body></html>".utf8))
        let text = try XCTUnwrap(firstParagraph(halves))
        XCTAssertTrue(text.hasSuffix(" x < y"), text.debugDescription)
        XCTAssertGreaterThan(text.unicodeScalars.count, 6)
        XCTAssertTrue(text.unicodeScalars.dropLast(6).allSatisfy { $0 == "\u{FFFD}" }, "the halves were joined into \(text.debugDescription)")
    }

    /// The scan that reads NULs, against documents whose text and markup are known because they
    /// are assembled from pieces: a NUL put into text leaves the tree of the document without
    /// it, and one put into markup the tree of the document with U+FFFD written there.
    func testGeneratedNULsAreNothingInTextAndACharacterInMarkup() throws {
        let texts = ["one ", "two & three ", "x < y ", "caf\u{E9} ", "&amp; &lt; ", "1 <2 ", "\u{4E2D}\u{6587}", " ", "a > b ", "it's \"quoted\" ", "p <.05 ", "\u{1F600}"]
        // Each is markup from its first byte to its last. What follows `|` ends raw text: a NUL
        // there would leave it open over the text of the pieces after it.
        let markups = ["<p>", "</p>", "<b>", "</b>", "<br>", "<br/>", "<i class=\"k\">", "</i>", "<!-- note -->", "<!-- a > b -->", "<span title=\"a > b\" lang=en>", "</span>",
                       "<img src=a.png alt='b > c'>", "<a href=\"x?y=1&z=2\">", "</a>", "<style>p > i { color: red }|</style>", "<script>if (a < b) { c() }|</script>",
                       "<?pi d?>", "<div\n id=d1\t>", "</div >", "<table>", "<tr>", "<td>", "</td>", "</table>", "<h1 TITLE=x>", "</H1>"]
        var state: UInt64 = 0x201
        func random(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var inText = 0, inMarkup = 0, compared = 0
        for round in 0..<6_000 {
            var withNULs: [UInt8] = [], expected: [UInt8] = []
            func text(_ piece: String) {
                for byte in Array(piece.utf8) {
                    if byte & 0xC0 != 0x80, random(6) == 0 { withNULs.append(0); inText += 1 } // Not inside a character.
                    withNULs.append(byte); expected.append(byte)
                }
            }
            /// One NUL at most, which may change where the piece ends, and not before its `<`
            /// (where it is in text) nor directly after it (where the sign opens nothing).
            func markup(_ piece: String, withNUL: Bool) {
                let parts = piece.split(separator: "|", omittingEmptySubsequences: false).map { Array($0.utf8) }
                let at = withNUL && parts[0].count > 2 ? 2 + random(parts[0].count - 2) : nil
                for (index, byte) in parts[0].enumerated() {
                    if index == at { withNULs.append(0); expected.append(contentsOf: [0xEF, 0xBF, 0xBD]); inMarkup += 1 }
                    withNULs.append(byte); expected.append(byte)
                }
                for part in parts.dropFirst() { withNULs.append(contentsOf: part); expected.append(contentsOf: part) }
            }
            markup("<html><head><title>", withNUL: false)
            text("T")
            markup("</title></head><body>", withNUL: false)
            for _ in 0...random(12) {
                // In markup only on alternate rounds: half the documents have NULs in text alone.
                if random(2) == 0 { text(texts[random(texts.count)]) } else { markup(markups[random(markups.count)], withNUL: round % 2 == 1 && random(3) == 0) }
            }
            markup("<p>", withNUL: false)
            text("after")
            guard withNULs.contains(0), let document = try? parse(Data(withNULs)) else { continue } // The screen may read a NUL in markup as leaving it open.
            compared += 1
            let written = try parse(Data(expected))
            guard model(document) == model(written) else {
                return XCTFail("\(String(decoding: withNULs, as: UTF8.self).debugDescription) is not read as \(String(decoding: expected, as: UTF8.self).debugDescription)")
            }
            guard !document.nodes.contains(where: { $0.text.unicodeScalars.contains("\u{0}") || $0.attributes.contains { $0.value.unicodeScalars.contains("\u{0}") } }) else {
                return XCTFail("a NUL is left in the tree of \(String(decoding: withNULs, as: UTF8.self).debugDescription)")
            }
        }
        XCTAssertGreaterThan(compared, 4_000)
        XCTAssertGreaterThan(inText, 2_000)
        XCTAssertGreaterThan(inMarkup, 1_000)
    }

    /// Over generated markup of no particular shape, what the scan gives the parser is the
    /// document with each NUL left out or made U+FFFD and nothing else changed, no NUL is left,
    /// and none is left out directly after a `<` that is still a sign.
    func testTheNULScanChangesNothingElseAndJoinsNoSignToAName() throws {
        let tokens = ["<", "<", ">", "\"", "'", "=", "/", " ", "a", "p", "!", "?", "-", "--", "\u{0}", "\u{0}", "\u{0}", "\u{E9}", "&lt;", "<p>", "</p>", "<p ", "<a href=", "title=\"",
                      "<br/>", "/>", "</", "<?", "<!", "<!--", "-->", "<![CDATA[", "]]>", "<!DOCTYPE", "style", "script", "<style", "</style", "<style>", "</style>", "<STYLE ",
                      "<script>", "</script>", "<script />", "<title>", "</title>", "<html>", "<body>", "<table>", "<td>", "<div>", "</div>"]
        var state: UInt64 = 2010
        func random(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var withNULs = 0, replacedNULs = 0, removedNULs = 0
        for _ in 0..<30_000 {
            let markup = (0...random(20)).map { _ in tokens[random(tokens.count)] }.joined()
            let input = Array(markup.utf8)
            let output = [UInt8](try XCTUnwrap(HTMLNullCharacters.replaced(in: Data(input), limit: .max)))
            guard input.contains(0) else { XCTAssertEqual(output, input); continue }
            withNULs += 1
            var index = 0
            for (position, byte) in input.enumerated() {
                if byte != 0 {
                    guard index < output.count, output[index] == byte else { return XCTFail("more than its NULs changed in \(markup.debugDescription)") }
                    index += 1
                } else if output[index...].starts(with: [0xEF, 0xBF, 0xBD]) {
                    index += 3; replacedNULs += 1
                } else {
                    removedNULs += 1
                    guard position == 0 || input[position - 1] != 0x3C else { return XCTFail("a NUL was left out after a sign in \(markup.debugDescription)") }
                }
            }
            guard index == output.count else { return XCTFail("bytes were added to \(markup.debugDescription)") }
            // Through the reader, whatever of it the screen passes, no NUL reaches the tree.
            guard let document = try? parse(Data(("<html><body>" + markup).utf8)) else { continue }
            guard !document.nodes.contains(where: { ($0.name + $0.text + $0.attributes.map { $0.name + $0.value }.joined()).unicodeScalars.contains("\u{0}") }) else {
                return XCTFail("a NUL is left in the tree of \(markup.debugDescription)")
            }
        }
        XCTAssertGreaterThan(withNULs, 10_000)
        XCTAssertGreaterThan(replacedNULs, 3_000)
        XCTAssertGreaterThan(removedNULs, 3_000)
    }

    /// A section whose file is cut off inside markup is withheld by the screen, before either
    /// parser, and reading its NULs does not make it one the screen passes: what a NUL stands
    /// in is still left open.
    func testMarkupLeftOpenIsStillWithheldWhateverNULsItHolds() throws {
        let open = ["<p>a</p><di\u{0}v", "<p>a</p><p ti\u{0}", "<p>a</p><p title=\"x\u{0}", "<p>a</p><!-- \u{0}", "<p>a</p><!-- b --\u{0}>", "<p>a</p></\u{0}", "<p>a</p><?pi \u{0}",
                    "<p>a</p><\u{0}p>b</p><p", "<p>a <", "<p>a</p\u{0}"]
        for cut in open {
            let markup = "<html \(Self.xhtml)>\(Self.head)<body>\(cut)"
            assertThrows(.unsafeMarkup("fallback.xhtml"), cut.debugDescription) { try self.parse(markup) }
            for variant in Self.wide[..<4] {
                assertThrows(.unsafeMarkup("fallback.xhtml"), "\(cut.debugDescription) in \(variant.label)") { try self.parse(try self.encoded(markup, variant)) }
            }
            assertThrows(.unsafeMarkup("fallback.xhtml"), "\(cut.debugDescription) in ISO-8859-1") {
                try self.parse(Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\(markup)".utf8))
            }
        }
        let text = try section(["OPS/one.xhtml": Data("<html \(Self.xhtml)>\(Self.head)<body><p>one</p>\u{0}<p>two</p><p ti\u{0}".utf8)])
        XCTAssertTrue(text.report.withheld)
        XCTAssertEqual(text.string.string, "This section could not be shown.")
        // A sign that NULs follow is not the last byte of its file. The screen reads a character
        // there, as HTML does, and passed such a file before: it is shown, and ends in the sign.
        let padded = "<html \(Self.xhtml)>\(Self.head)<body><p>one</p><p>two <\u{0}\u{0}\u{0}"
        XCTAssertTrue(XMLSafety.hasSafeDeclarations(Data(padded.utf8)))
        XCTAssertEqual(bodyModel(try parse(padded)), ["<p>", "one", "<p>", "two <"])
    }

    // MARK: - What has not changed

    /// A section that is UTF-8 and holds no NUL is given to the parser as it was before: the
    /// bytes the XML parser was given, with their stray signs replaced and nothing else done.
    /// So is one that declares another encoding and is the same bytes in it.
    func testUTF8WithoutNULsIsGivenToTheParserAsItWas() throws {
        let tokens = ["<", "<", ">", "\"", "'", "=", "/", " ", " ", "a", "p", "x", "1", "!", "?", "-", ".", "_", "\n", "\u{E9}", "\u{4E2D}", "\u{1F600}", "\u{FFFD}", "\u{FEFF}", "&lt;", "&nbsp;", "&eacute;",
                      "&bogus;", "&", "&#233;", "<p>", "</p>", "<p ", "<a href=", "title=\"", "<br>", "<br/>", "</", "<?", "<!", "<!--", "-->", "<![CDATA[", "]]>", "<!DOCTYPE html>",
                      "<meta charset=\"ISO-8859-1\">", "<style>", "</style>", "<script>", "</script>", "<title>", "</title>", "<html>", "<head>", "<body>", "</body>", "<table>", "<td>", "<div>", "</div>"]
        let prologs = ["", "", "", "<?xml version=\"1.0\"?>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<?xml version='1.0' encoding='utf-8' standalone='no'?>\n", "\u{FEFF}",
                       "\u{FEFF}<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<?xml version=\"1.0\" encoding=\"x-no-such-encoding\"?>", "<?xml encoding=\"ISO-8859-1\"?>", "<?xml version=\"1.0\" encoding=\"UTF-16\"?>"]
        let legacy = ["<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>", "<?xml version=\"1.0\" encoding=\"windows-1252\"?>", "<?xml version=\"1.0\" encoding=\"US-ASCII\"?>", "\u{FEFF}<?xml version=\"1.0\" encoding=\"Shift_JIS\"?>"]
        var state: UInt64 = 20_100
        func random(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var recovered = 0, declaredLegacy = 0
        for round in 0..<20_000 {
            var body = (random(3) == 0 ? "" : "<html \(Self.xhtml)><body>") + (0...random(18)).map { _ in tokens[random(tokens.count)] }.joined()
            var prolog = prologs[random(prologs.count)]
            if round % 5 == 0 { // The bytes of ASCII are themselves in each of these.
                prolog = legacy[random(legacy.count)]
                body = String(String.UnicodeScalarView(body.unicodeScalars.filter(\.isASCII)))
                declaredLegacy += 1
            }
            let data = Data((prolog + body).utf8)
            let rewritten = HTMLEntities.numericReferences(in: data)
            let before = try XCTUnwrap(HTMLStraySigns.replaced(in: rewritten, limit: .max))
            guard let source = try? ContentDocument.htmlSource(data, rewritten: rewritten, path: "generated.xhtml", limits: .init()) else {
                return XCTFail("\((prolog + body).debugDescription) is refused by the fallback's own preparation")
            }
            guard source.data == before.data, source.placeholder == before.placeholder else {
                return XCTFail("\((prolog + body).debugDescription) is given to the parser as other bytes than before")
            }
            if (try? parse(data))?.recoveredAsHTML == true { recovered += 1 }
        }
        XCTAssertGreaterThan(recovered, 8_000, "the generator has stopped making documents the fallback reads")
        XCTAssertEqual(declaredLegacy, 4_000)
    }

    /// Well-formed XHTML is read by the XML parser in whatever encoding that parser reads, keeps
    /// its CFIs, and never comes to the fallback.
    func testWellFormedDocumentsAreStillReadAsXML() throws {
        let markup = page("<p id=\"one\">caf\u{E9} one</p><p>after</p>")
        for variant in Self.wide[..<6] {
            let document = try parse(try encoded(markup, variant))
            XCTAssertFalse(document.recoveredAsHTML, variant.label)
            XCTAssertTrue(document.canResolveCFIs, variant.label)
            let text = try XCTUnwrap(document.element(id: "one")?.children.first)
            XCTAssertEqual(EPUBCFI.localPath(from: DOMPosition(text, 3), to: DOMPosition(text, 4), in: document), "/4/2[one],/1:3,/1:4", variant.label)
        }
        let latin = try parse(declared("ISO-8859-1", [0xE9], tail: ""))
        XCTAssertFalse(latin.recoveredAsHTML)
        XCTAssertTrue(latin.canResolveCFIs)
    }

    // MARK: - Through a built section

    /// A section in UTF-16 or a declared ISO-8859-1 that is not well-formed is built with its
    /// text, and the reader's positions are those of the characters it shows: every character
    /// maps to its place in the document and back, a search finds the words where they are
    /// drawn, and an `id` is an anchor. It is still a section whose tree the HTML parser
    /// repaired, and says it has no CFIs to give.
    func testASectionInAnotherEncodingIsShownWhereItsPositionsSayItIs() throws {
        let markup = """
        <html \(Self.xhtml)><head><title>Caf\u{E9}</title><style>p > em { font-style: normal }</style></head>\
        <body><p>caf\u{E9} cr\u{E8}me <em>br\u{FB}l\u{E9}e</em><br>if x < y</p><p id='after'>d\u{E9}j\u{E0} vu</p></body></html>
        """
        var documents: [(String, Data)] = try Self.wide[..<6].map { ($0.label, try encoded(markup, $0)) }
        documents.append(("ISO-8859-1", Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>".utf8) + (try XCTUnwrap(markup.data(using: .isoLatin1)))))
        documents.append(("windows-1252", Data("<?xml version=\"1.0\" encoding=\"windows-1252\"?>".utf8) + (try XCTUnwrap(markup.data(using: .windowsCP1252)))))
        for (label, data) in documents {
            let text = try section(["OPS/one.xhtml": data])
            XCTAssertFalse(text.report.withheld, label)
            XCTAssertTrue(text.report.recoveredAsHTML, label)
            XCTAssertTrue(text.report.cfiUnavailable, label)
            XCTAssertEqual(text.string.string, "caf\u{E9} cr\u{E8}me br\u{FB}l\u{E9}e\u{2028}if x < y\nd\u{E9}j\u{E0} vu", label)
            XCTAssertEqual(text.title, "Caf\u{E9}", label)
            XCTAssertEqual(S.mapViolations(text) + S.locationViolations(text) + S.stringViolations(text), [], label)
            XCTAssertFalse(S.traits("br\u{FB}l\u{E9}e", in: text).contains(.traitItalic), "\(label): the style sheet was not read")
            let string = text.string.string as NSString
            XCTAssertEqual(string.substring(from: try XCTUnwrap(text.anchors["after"], label)), "d\u{E9}j\u{E0} vu", label)
            for query in ["cr\u{E8}me br\u{FB}l\u{E9}e", "x < y", "d\u{E9}j\u{E0}"] {
                let match = try XCTUnwrap(TextSearch.matches(of: query, in: text.document, locale: nil).first, "\(label): \(query)")
                let start = text.map.location(of: match.start), end = text.map.location(of: match.end, isEnd: true)
                XCTAssertEqual(string.substring(with: NSRange(location: start, length: end - start)), query, label)
                XCTAssertEqual(EPUBCFI.localPath(from: match.start, to: match.end, in: text.document), "", "\(label): \(query)")
            }
        }
    }

    /// A section with NULs in it is built whole, and positions count the characters shown: the
    /// NULs left out of its text are not characters of it, and the text after them is where a
    /// search and an anchor say it is.
    func testASectionWithNULsIsShownWholeWhereItsPositionsSayItIs() throws {
        let markup = """
        <html \(Self.xhtml)><head><title>T</title></head><body><p>o\u{0}ne</p>\u{0}<p title="a\u{0}b">two <\u{0} three</p>\
        <!-- \u{0} --><p id='after'>fo\u{0}ur</p></body></html>\u{0}\u{0}
        """
        var documents: [(String, Data)] = [("UTF-8", Data(markup.utf8))]
        documents.append(contentsOf: try Self.wide[..<2].map { ($0.label, try encoded(markup, $0)) })
        for (label, data) in documents {
            let text = try section(["OPS/one.xhtml": data])
            XCTAssertFalse(text.report.withheld, label)
            XCTAssertTrue(text.report.recoveredAsHTML, label)
            XCTAssertTrue(text.report.cfiUnavailable, label)
            XCTAssertEqual(text.string.string, "one\ntwo < three\nfour", label)
            XCTAssertEqual(S.mapViolations(text) + S.locationViolations(text) + S.stringViolations(text), [], label)
            XCTAssertEqual(text.document.nodes.first { $0.attribute("title") != nil }?.attribute("title"), "a\u{FFFD}b", label)
            let string = text.string.string as NSString
            XCTAssertEqual(string.substring(from: try XCTUnwrap(text.anchors["after"], label)), "four", label)
            let node = try XCTUnwrap(text.document.element(id: "after")?.children.first, label)
            XCTAssertEqual(node.utf16Length, 4, label)
            for query in ["one", "two < three", "four"] {
                let match = try XCTUnwrap(TextSearch.matches(of: query, in: text.document, locale: nil).first, "\(label): \(query)")
                let start = text.map.location(of: match.start), end = text.map.location(of: match.end, isEnd: true)
                XCTAssertEqual(string.substring(with: NSRange(location: start, length: end - start)), query, label)
                XCTAssertEqual(EPUBCFI.localPath(from: match.start, to: match.end, in: text.document), "", "\(label): \(query)")
            }
        }
    }

    /// What the fallback refuses is reported as every unreadable section is: withheld, with the
    /// notice in its place, and never a shorter text.
    func testASectionTheFallbackRefusesIsWithheldAndReported() throws {
        let hidden = "<?xml version=\"1.0\" encoding=\"UTF-7\"?>+ADw-!DOCTYPE html [+ADw-!ENTITY e \"hidden\"+AD4-]+AD4-<html><body><p>+ACY-e+ADs- one<br>two</p></body></html>"
        let text = try section(["OPS/one.xhtml": Data(hidden.utf8)])
        XCTAssertTrue(text.report.withheld)
        XCTAssertEqual(text.string.string, "This section could not be shown.")
        XCTAssertEqual(text.map.length, text.string.length)
    }
}
