import EPUBTestSupport
import EPUBCore
import Foundation
import libxml2
import XCTest

/// `XMLSafety.hasSafeDeclarations`, the screen every XML parser in the package runs behind.
final class XMLSafetyCoverageTests: XCTestCase {
    private func safe(_ xml: String, _ encoding: String.Encoding = .utf8) -> Bool {
        XMLSafety.hasSafeDeclarations(xml.data(using: encoding)!)
    }

    func testMarkupWithoutDeclarationsIsSafe() {
        for xml in [
            "", "   \n", "plain text, it's \"quoted\" and 1 > 0", "<a/>", "<a>b</a>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><a/>",
            "<!DOCTYPE html><html/>", "<!DOCTYPE html >\n<html/>",
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\"><html/>",
            "<!DOCTYPE html SYSTEM 'about:legacy-compat'><html/>",
            "<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\"\n \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\">\n<ncx/>",
            "<!DOCTYPE x PUBLIC \"a [b]\" 'c [<!ENTITY d \"e\">]'><x/>",
            "<a title=\"x > y [z] <!ENTITY\" data-q='say \"hi\" > [now]'>it's</a>",
            "<p>don't</p><p>\"quoted\"</p><p>a &gt; b &lt; c ]]&gt; [x]</p>",
            "<a><!-- <!DOCTYPE x [<!ENTITY y 'z'>]> ' \" --><b/></a>",
            "<a><![CDATA[<!DOCTYPE x [<!ENTITY y 'z'>]> ' \" <unclosed ]]></a>",
            "<?pi <!DOCTYPE x [<!ENTITY y 'z'>]> ' \" ?><a/>",
            "<!---->", "<![CDATA[]]>", "<??>", "<a\n  b='1'\n  c=\"2\"\n/>",
        ] {
            XCTAssertTrue(safe(xml), xml)
        }
        XCTAssertTrue(XMLSafety.hasSafeDeclarations(Data([0xEF, 0xBB, 0xBF]) + Data("<?xml version=\"1.0\"?><a>\u{E9}</a>".utf8)), "a UTF-8 byte-order mark")
    }

    func testEntityDeclarationsAndInternalSubsetsAreUnsafeWhereverTheyStand() {
        for xml in [
            "<!DOCTYPE x [<!ENTITY y 'z'>]><x>&y;</x>", "<!DOCTYPE x []><x/>", "<!DOCTYPE x[]><x/>", "<!DOCTYPE\nx\n[\n]\n><x/>",
            "<!DOCTYPE x SYSTEM \"x.dtd\" [<!ATTLIST x y CDATA 'z'>]><x/>", "<!DOCTYPE x PUBLIC 'p' 's' [ <!ELEMENT x ANY> ]><x/>",
            "<?xml version=\"1.0\"?>\n<!-- a comment -->\n<!DOCTYPE x [<!ENTITY % p SYSTEM 'http://example.invalid/p.dtd'> %p;]><x/>",
            "<!ENTITY y 'z'><x/>", "<x/><!ENTITY y SYSTEM 'file:///etc/passwd'>", "<x><!ENTITY y 'z'></x>",
            "<!DOCTYPE x [<!ENTITY a '&#38;b;&#38;b;'><!ENTITY b '&#38;c;&#38;c;'><!ENTITY c 'lol'>]><x>&a;</x>",
            "<!-- one --><!-- two --><![CDATA[three]]><?four?><!DOCTYPE x [<!ENTITY y 'z'>]><x/>",
        ] {
            XCTAssertFalse(safe(xml), xml)
        }
    }

    func testMarkupLeftOpenAtTheEndIsUnsafe() {
        for xml in ["<a><!-- never closed", "<a><!-- never closed --", "<a><![CDATA[never closed]]", "<?xml version=\"1.0\"", "<a href=\"never closed>",
                    "<a href='never closed\">", "<a", "<", "<!DOCTYPE html", "<!DOCTYPE html PUBLIC \"never closed>"] {
            XCTAssertFalse(safe(xml), xml)
        }
    }

    /// A `<` that no tag can follow is a character to HTML (tokenization, tag open state) and an
    /// error to XML. It opens nothing: quotes after it are prose, and a declaration after it is
    /// still seen.
    func testALessThanSignThatOpensNoTagIsACharacter() {
        for xml in [
            "<p>if x < y then it's done</p><p>next</p>", "<style>a::after { content: \"<\" }</style>", "<p>1<2, 3 <= 4 and it's \"so</p>",
            "<p>a << b, a <> b, a <- b's</p>", "<pre>if (i < n) { s = \"it's\"; c = '\"'; }</pre>", "< '", "<\t\"", "<<<'<<\"",
        ] {
            XCTAssertTrue(safe(xml), xml)
        }
        XCTAssertTrue(safe("<p>if x < y then it's done</p>", .utf16), "decoded UTF-16")
        for xml in [
            "<p>x < y's <!ENTITY e 'f'></p>", "< ' <!DOCTYPE x [<!ENTITY y 'z'>]><x>&y;</x>", "<p>a < \"b\" <!DOCTYPE x []></p>",
            // These two once passed, each declaration inside a tag that began at the stray sign.
            "< \"<!DOCTYPE x [<!ENTITY y 'z'>]>\" ><x/>", "<x>1 < 2 <!ENTITY y SYSTEM 'file:///etc/passwd'> 3 > 2</x>",
        ] {
            XCTAssertFalse(safe(xml), xml)
        }
        XCTAssertFalse(safe("<p>x < y's <!ENTITY e 'f'></p>", .utf16), "decoded UTF-16")
        XCTAssertFalse(safe("<p>x <"), "a sign that ends the input may yet open a tag")
    }

    /// In a tag a quote delimits only an attribute value, after `=`. Anywhere else XML has no
    /// quoted string and HTML reads a character (tokenization, attribute name and unquoted
    /// attribute value states), so it neither takes in the rest of the file nor hides a declaration.
    func testAQuoteThatOpensNoAttributeValueIsACharacter() {
        for xml in [
            "<p>if x <y then it's done</p><p>next</p>", "<p>x <\u{A0}y, it's</p>", "<a title=it's>x</a>", "<img alt=\"5\" tall\"/><p>next</p>",
            "</p it's>", "<!doctype html public \"-//W3C//DTD HTML 4.01//EN\"><p>it's</p>",
            "<a b = 'c > [d] <!ENTITY' e\n=\n\"<!DOCTYPE x [\">f</a>", "<a\tb\r=\t'>'\n/>",
        ] {
            XCTAssertTrue(safe(xml), xml)
        }
        // These once passed, each declaration between two quotes that delimit nothing.
        for xml in ["<a b'> <!ENTITY c 'd'> '>e</a>", "<a b'> <!DOCTYPE x [<!ENTITY c 'd'>]> '><x/>", "<a b=c'> <!ENTITY d 'e'> '/>"] {
            XCTAssertFalse(safe(xml), xml)
        }
        // A declaration is no tag: its literals are quoted wherever they stand, and one that
        // holds `=` must not make its own closing quote open a string over what follows.
        XCTAssertTrue(safe("<!ATTLIST x a CDATA '>' b CDATA \"<!ENTITY\"><x/>"))
        for xml in ["<!ATTLIST x a CDATA \"=\"><!ENTITY y \"z\">", "<!NOTATION n SYSTEM '='><!ENTITY y 'z'><x/>"] {
            XCTAssertFalse(safe(xml), xml)
        }
    }

    /// libxml2 2.9 reads a `[` that directly follows a DOCTYPE's closing `>` as that DOCTYPE's
    /// internal subset all the same, and every XML parser behind the screen is built on it.
    func testABracketDirectlyAfterADoctypeIsAnInternalSubset() {
        for xml in [
            "<!DOCTYPE x>[<!ATTLIST x a CDATA 'v'>]><x/>", "<!DOCTYPE x>[<!ELEMENT x ANY>]><x/>", "<!DOCTYPE x SYSTEM \"x.dtd\">[]><x/>",
            "<?xml version=\"1.0\"?>\n<!DOCTYPE x PUBLIC 'p' 's' >[<!NOTATION n SYSTEM 's'>]><x/>", "<!DOCTYPE x>[",
        ] {
            XCTAssertFalse(safe(xml), xml)
        }
        for xml in ["<!DOCTYPE x> [x]<x/>", "<!DOCTYPE x>\n<x>[</x>", "<!DOCTYPE x><x a='['>[]</x>", "<!DOCTYPE x>"] {
            XCTAssertTrue(safe(xml), xml)
        }
    }

    /// What the screen is for, on generated markup: nothing that passes it, well-formed or not,
    /// gives the XML parser behind it a declaration to read.
    func testNothingThatPassesTheScreenDeclaresAnythingToTheXMLParser() {
        let tokens = [
            "<", "<", "<", ">", ">", "'", "'", "\"", "\"", "=", "=", " ", " ", "\n", "\t", "/", "!", "?", "[", "]", "-", "a", "y", "1", ":", "_", "\u{E9}", "\u{A0}",
            "<x>", "</x>", "<x a='", "<x a=\"", "<x ", "<x/>", "<!DOCTYPE x ", "<!DOCTYPE x [", "<!DOCTYPE x>", "<!DOCTYPE x>[", "<!ENTITY y 'z'>", "<!ENTITY y \"z\">", "]>",
            "<!ATTLIST x a CDATA 'v'>", "<!ATTLIST x a CDATA \"=\">", "<!NOTATION n SYSTEM '='>", "<!ELEMENT x ANY>", "PUBLIC 'p' 's'", "SYSTEM \"s\"",
            "<!--", "-->", "<![CDATA[", "]]>", "<?", "?>", "<?xml version=\"1.0\"?>", "<!ATTLIST x a CDATA ", "\"=\"", "'='", "'>'", "\">\"",
            "&y;", "&amp;", "it's", " < y ", "<y ", "a='b'", "a=\"b\"", "a = 'b'", "</", "<!", "<!doctype x [", "<!entity y 'z'>",
        ]
        let prologs = ["", "", "<?xml version=\"1.0\"?>", "<!-- c -->", "<!DOCTYPE x>", "<!DOCTYPE x SYSTEM 's'>", "<!DOCTYPE x [<!ENTITY y 'z'>]>", "<!DOCTYPE x ["]
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var passed = 0, declaring = 0
        for round in 0..<30_000 {
            var text = (0...next(14)).map { _ in tokens[next(tokens.count)] }.joined()
            // One input in three stands in a root element after a prolog and one in three where
            // the parser reads an internal subset, so that more of them are read past their start.
            switch round % 3 {
            case 1: text = prologs[next(prologs.count)] + "<x>" + text + "</x>"
            case 2: text = "<!DOCTYPE x>[" + text + "]><x>&y;</x>"
            default: break
            }
            let data = Data(text.utf8)
            let declarations = DeclarationCounter()
            let parser = XMLParser(data: data)
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = declarations
            parser.parse()
            if declarations.count > 0 { declaring += 1 }
            guard XMLSafety.hasSafeDeclarations(data) else { continue }
            passed += 1
            XCTAssertEqual(declarations.count, 0, text.debugDescription)
        }
        XCTAssertGreaterThan(passed, 2_000, "most inputs were refused, so little was checked")
        XCTAssertGreaterThan(declaring, 500, "the generator must write declarations the parser reads")
    }

    // MARK: A DOCTYPE read as HTML reads it (#293)

    /// With `doctypesAsHTML`, the screen reads a DOCTYPE to its first `>`, as the HTML Standard
    /// ends one inside a quoted identifier: a DOCTYPE that has lost a closing quote is safe for
    /// libxml2's HTML parser, given its keywords renamed. XML reads on to the closing quote and
    /// still calls it unsafe. An internal subset or a declaration on either side of that `>`,
    /// and a DOCTYPE that never ends, is refused either way.
    func testADoctypeReadAsHTMLEndsAtItsFirstGreaterThanSign() {
        let chapter = "\n<html><head><title>T</title></head><body><p>x</p></body></html>"
        for doctype in ["<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd>",
                        "<!DOCTYPE html SYSTEM 'about:legacy-compat>", "<!doctype html public \"x>", "<!DOCTYPE html PUBLIC \"a [b]\" 'c>"] {
            let data = Data((doctype + chapter).utf8)
            XCTAssertFalse(XMLSafety.hasSafeDeclarations(data), doctype)
            XCTAssertEqual(XMLSafety.assess(data, doctypesAsHTML: true), .safe, doctype)
        }
        for xml in ["<!DOCTYPE html [<!ENTITY e 'v'>]>", "<!DOCTYPE html []>", "<!doctype html [ ]>", "<!DOCTYPE html SYSTEM \"x> [<!ENTITY e 'v'>]>",
                    "<!DOCTYPE html SYSTEM \"x>[", "<!DOCTYPE html SYSTEM 'x> <!ENTITY % p SYSTEM \"p.dtd\">",
                    "<!DOCTYPE html>[<!ELEMENT p ANY>]>", "<x/><!DOCTYPE html [ \"y\" >"] {
            XCTAssertEqual(XMLSafety.assess(Data((xml + chapter).utf8), doctypesAsHTML: true), .unsafe, xml)
        }
        XCTAssertEqual(XMLSafety.assess(Data("<html/><!DOCTYPE html PUBLIC \"x".utf8), doctypesAsHTML: true), .unsafe, "the input ends inside it")
    }

    /// `HTMLDoctypes` on generated DOCTYPEs: with the last letter of each `PUBLIC` and `SYSTEM`
    /// before its first `>` written as a reference, libxml2's HTML parser (2.9 on this Mac) reads
    /// no identifier and ends the DOCTYPE at that `>`, where the Standard ends it, so the
    /// element written after it is in the tree. As written, the identifiers often take it.
    func testARenamedDoctypeEndsWhereTheHTMLStandardEndsIt() {
        let parts = ["html", " ", " ", "\t", "\n", "PUBLIC", "public", "Public", "SYSTEM", "system", "PUBLICX", "\"", "\"", "'", "'", "x",
                     "-//W3C//DTD XHTML 1.1//EN", "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd", "about:legacy-compat", "[", "]", "=", "/", "&", "#"]
        var state: UInt64 = 0x0293_0293_0293_0293
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let starts = ["<!DOCTYPE html ", "<!DOCTYPE ", "<!doctype html\t", "<!DOCTYPE html", "<!DOCTYPE\nHTML\n"]
        let keywords = ["PUBLIC", "SYSTEM", "public", "System"], quotes = ["\"", "'"]
        var taken = 0
        for _ in 0..<4_000 {
            // Half of them a keyword and a quote where libxml2 looks for them, after the name.
            let keyword = next(2) == 0 ? keywords[next(keywords.count)] + [" ", "", "\t"][next(3)] + quotes[next(quotes.count)] : ""
            let doctype = starts[next(starts.count)] + keyword + (0...next(6)).map { _ in parts[next(parts.count)] }.joined()
            let after = "><i>m</i> \" ' <b>n</b>"
            let bytes = Array((doctype + after).utf8)
            var renamed: [UInt8] = []
            let letters = Set(HTMLDoctypes.keywordLetters(bytes, in: 0..<doctype.utf8.count + 1))
            for (index, byte) in bytes.enumerated() {
                renamed.append(contentsOf: letters.contains(index) ? HTMLDoctypes.reference(byte) : [byte])
            }
            XCTAssertTrue(Self.libxml2Builds("i", from: renamed), doctype.debugDescription)
            if !Self.libxml2Builds("i", from: bytes) { taken += 1 }
        }
        XCTAssertGreaterThan(taken, 200, "the generator must write DOCTYPEs whose identifiers libxml2 reads past their first \">\"")
    }

    /// Whether libxml2's HTML parser, with recovery's options, builds an element named `name`.
    private static func libxml2Builds(_ name: String, from bytes: [UInt8]) -> Bool {
        let options = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
            | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NODEFDTD.rawValue)
        guard let document = bytes.withUnsafeBufferPointer({ buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                htmlReadMemory($0, Int32(buffer.count), nil, "UTF-8", options)
            }
        }) else { return false }
        defer { xmlFreeDoc(document) }
        var pending = [xmlDocGetRootElement(document)]
        while let node = pending.popLast() {
            guard let node else { continue }
            if node.pointee.type == XML_ELEMENT_NODE, String(cString: node.pointee.name) == name { return true }
            pending.append(node.pointee.next)
            pending.append(node.pointee.children)
        }
        return false
    }

    func testWideEncodingsAreDecodedBeforeScreening() throws {
        let harmless = "<?xml version='1.0'?><!-- <!DOCTYPE x [<!ENTITY y 'z'>]> --><x a='[' b=\"<!ENTITY\">\u{E9}\u{65E5}\u{1F600}</x>"
        let hostile = "<?xml version='1.0'?><!DOCTYPE x [<!ENTITY y 'z'>]><x>&y;\u{E9}\u{65E5}\u{1F600}</x>"
        let encodings: [(String, String.Encoding, [UInt8])] = [
            ("UTF-16 with its mark", .utf16, []), ("UTF-16BE", .utf16BigEndian, []), ("UTF-16LE", .utf16LittleEndian, []),
            ("UTF-16BE with a mark", .utf16BigEndian, [0xFE, 0xFF]), ("UTF-16LE with a mark", .utf16LittleEndian, [0xFF, 0xFE]),
            ("UTF-32BE", .utf32BigEndian, []), ("UTF-32LE", .utf32LittleEndian, []),
            ("UTF-32BE with a mark", .utf32BigEndian, [0, 0, 0xFE, 0xFF]), ("UTF-32LE with a mark", .utf32LittleEndian, [0xFF, 0xFE, 0, 0]),
        ]
        for (name, encoding, mark) in encodings {
            XCTAssertTrue(XMLSafety.hasSafeDeclarations(Data(mark) + (try XCTUnwrap(harmless.data(using: encoding)))), name)
            XCTAssertFalse(XMLSafety.hasSafeDeclarations(Data(mark) + (try XCTUnwrap(hostile.data(using: encoding)))), name)
            // White space may precede the document's first tag.
            XCTAssertFalse(XMLSafety.hasSafeDeclarations(Data(mark) + (try XCTUnwrap(("\n " + hostile.dropFirst(21)).data(using: encoding)))), name)
        }
    }

    func testShortTruncatedAndSlicedInputIsScreenedWithoutTrapping() throws {
        // The encoding is guessed from four bytes that may not all be there.
        let prefixes: [[UInt8]] = [[0], [0, 0], [0, 0, 0], [0, 0, 0, 0], [0x3C], [0x3C, 0], [0x3C, 0, 0], [0x3C, 0, 0, 0], [0, 0x3C], [0, 0, 0x3C],
                                  [0xFF], [0xFE], [0xFF, 0xFE], [0xFE, 0xFF], [0xFF, 0xFE, 0], [0xFF, 0xFE, 0, 0], [0, 0, 0xFE], [0, 0, 0xFE, 0xFF],
                                  [0xEF], [0xEF, 0xBB], [0xEF, 0xBB, 0xBF], [0x80], [0xC3], [0xF0, 0x9F]]
        for bytes in prefixes {
            _ = XMLSafety.hasSafeDeclarations(Data(bytes))
            _ = XMLSafety.hasSafeDeclarations(Data(bytes) + Data("<!DOCTYPE x [".utf8))
        }
        let odd = try XCTUnwrap("<x/>".data(using: .utf16)).dropLast()
        XCTAssertFalse(XMLSafety.hasSafeDeclarations(Data(odd)), "half a UTF-16 code unit")
        _ = XMLSafety.hasSafeDeclarations(Data([0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x3C])) // An unpaired surrogate.
        // A slice of a larger buffer keeps its parent's indices.
        let padded = Data(repeating: 0x20, count: 100) + Data("<!DOCTYPE x [<!ENTITY y 'z'>]><x/>".utf8) + Data(repeating: 0x20, count: 100)
        XCTAssertFalse(XMLSafety.hasSafeDeclarations(padded[90..<140]))
        XCTAssertTrue(XMLSafety.hasSafeDeclarations(padded[0..<100]))
        XCTAssertTrue(XMLSafety.hasSafeDeclarations(padded[140...]))
    }

    func testFourMebibytesOfOpenMarkupAreScreenedInOnePass() {
        // Each of these makes a careless scanner start again from every byte.
        for unit in ["<", "<!--", "<![CDATA[", "<?", "<a '", "<!DOCTYPE", "<!-- -", "]]", "<a b=\"\">"] {
            let data = Data(String(repeating: unit, count: 4 * 1024 * 1024 / unit.utf8.count).utf8)
            let started = TestCPUClock.seconds()
            _ = XMLSafety.hasSafeDeclarations(data)
            XCTAssertLessThan(TestCPUClock.seconds() - started, 20, unit)
        }
    }

    func testADeclarationInAnEncodingTheScreenCannotReadIsNotCalledSafe() throws {
        // The screen reads bytes that are not UTF-16 or UTF-32 as ASCII markup, but the XML parsers
        // behind it honour whatever encoding the document declares. UTF-7 spells `<` as `+ADw-`
        // and EBCDIC as 0x4C, so neither declaration below contains the bytes `<!DOCTYPE`.
        // Only an encoding the platform's parser reads can carry a declaration past the screen.
        let utf7 = Data("<?xml version=\"1.0\" encoding=\"UTF-7\"?>+ADw-!DOCTYPE x [+ADw-!ENTITY y \"z\">]><x>&y;</x>".utf8)
        if XMLParser(data: utf7).parse() { XCTAssertFalse(XMLSafety.hasSafeDeclarations(utf7), "UTF-7, which the XML parser reads") }
        let converted = CFStringConvertIANACharSetNameToEncoding("IBM037" as CFString)
        let ibm037 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
        if converted != kCFStringEncodingInvalidId,
           let ebcdic = "<?xml version=\"1.0\" encoding=\"IBM037\"?><!DOCTYPE x [<!ENTITY y \"z\">]><x>&y;</x>".data(using: ibm037),
           XMLParser(data: ebcdic).parse() {
            XCTAssertFalse(XMLSafety.hasSafeDeclarations(ebcdic), "EBCDIC, which the XML parser reads")
        }
    }
}

/// Counts every declaration `XMLParser` reads from a DOCTYPE, including those of a document it
/// goes on to reject.
private final class DeclarationCounter: NSObject, XMLParserDelegate {
    var count = 0
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { count += 1 }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { count += 1 }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { count += 1 }
    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String, type: String?, defaultValue: String?) { count += 1 }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { count += 1 }
    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { count += 1 }
}
