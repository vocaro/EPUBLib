import EPUBCore
import Foundation
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
            let started = Date()
            _ = XMLSafety.hasSafeDeclarations(data)
            XCTAssertLessThan(Date().timeIntervalSince(started), 20, unit)
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
