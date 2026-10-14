import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import Foundation
import XCTest

final class ParserPreflightSafetyTests: XCTestCase {
    private func attributes(_ count: Int, boolean: Bool = false) -> String {
        (0..<count).map { boolean ? " a\($0)" : " a\($0)='v'" }.joined()
    }

    func testAttributeBoundCountsOccurrencesAndAllowsItsBoundary() {
        let limit = XMLSafety.attributesPerElement
        for values in [attributes(limit), String(repeating: " a='v'", count: limit), attributes(limit, boolean: true)] {
            XCTAssertTrue(XMLSafety.hasBoundedAttributes(Data("<p\(values)>x</p>".utf8)))
            XCTAssertFalse(XMLSafety.hasBoundedAttributes(Data("<p\(values) extra='v'>x</p>".utf8)))
        }
        let many = "<p\(attributes(limit + 1))>x</p>"
        XCTAssertEqual(XMLSafety.assess(Data(many.utf8)), .attributeLimitExceeded)
        XCTAssertEqual(XMLSafety.assess(many.data(using: .utf16)!), .attributeLimitExceeded)
        let scsu = Data("<?xml version='1.0' encoding='SCSU'?>".utf8) + Data([0x0F]) + many.data(using: .utf16BigEndian)!
        XCTAssertEqual(XMLSafety.assess(scsu), .attributeLimitExceeded)
        XCTAssertTrue(XMLSafety.hasSafeDeclarations(Data("<p title=\"\(attributes(limit + 1))\">x</p>".utf8)), "one attribute, many spaces and equals in its value")
        XCTAssertTrue(XMLSafety.hasSafeDeclarations(Data("<!-- \(many) --><p>x</p>".utf8)), "comment text is not a tag")
        XCTAssertTrue(XMLSafety.hasSafeDeclarations(Data("<p><![CDATA[\(many)]]></p>".utf8)))
    }

    func testStrictAndRecoveredExtractionRefuseAttributeFanoutBeforeParsing() throws {
        let over = attributes(XMLSafety.attributesPerElement + 1)
        for body in ["<p\(over)>text</p>", "<p\(over)>text</wrong>", "<p\(attributes(XMLSafety.attributesPerElement + 1, boolean: true))>text</p>"] {
            let chapter = "<html xmlns='http://www.w3.org/1999/xhtml'><head/><body>\(body)</body></html>"
            var files = try Fixture.files(); files["OPS/one.xhtml"] = Data(chapter.utf8)
            let publication = try EPUBPublication.open(data: Fixture.archive(files))
            for recovering in [false, true] {
                XCTAssertThrowsError(try publication.textSection(at: 0, recoversMalformedMarkup: recovering)) {
                    XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("attributesPerElement"))
                }
            }
        }
        let chapter = "<html xmlns='http://www.w3.org/1999/xhtml'><head/><body><p\(attributes(XMLSafety.attributesPerElement))>text</p></body></html>"
        var files = try Fixture.files(); files["OPS/one.xhtml"] = Data(chapter.utf8)
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).textSection(at: 0).text, "text")
    }

    func testHTMLContextsCannotHideActualAttributeFanout() {
        let over = "<div\(attributes(XMLSafety.attributesPerElement + 1))>x</div>"
        for source in ["<?bogus>" + over,
                       "<script><!-- </script>" + over + "-->",
                       "<!-- <x a=' --> " + over + " ' -->",
                       "<script><x a='</script>" + over + "'",
                       "</foo a=\"<x b='\">" + over + "'",
                       "<script>text</bogus><x a='</script>" + over + "'",
                       "<script>text</scriptfoobar><x a='</script>" + over + "'",
                       "<script></bogus><x a='</script>" + over + "'",
                       "<script>text</scriptfoobar><!-- </script>" + over + " -->",
                       "<script>text</scriptfoobar><style> </script>" + over + "</style>",
                       "<![CDATA[>" + over + "]]>" ] {
            XCTAssertFalse(XMLSafety.hasBoundedAttributes(Data(source.utf8), asHTML: true), source.prefix(120).description)
        }
        XCTAssertTrue(XMLSafety.hasBoundedAttributes(Data(("<!-- " + over + " -->").utf8), asHTML: true))
        XCTAssertTrue(XMLSafety.hasBoundedAttributes(Data(("<script>var example = \"" + over + "\";</script>").utf8), asHTML: true))
    }

    func testEncodedDeclarationsAreScreenedWithoutRequiringParserSupport() throws {
        let utf7 = Data("<?xml version='1.0' encoding='UTF-7'?>+ADw-!DOCTYPE x [+ADw-!ENTITY y 'z'>]><x/>".utf8)
        XCTAssertEqual(XMLSafety.assess(utf7), .unsafe)
        XCTAssertEqual(XMLSafety.assess(Data(String(decoding: utf7, as: UTF8.self).replacingOccurrences(of: "version='1.0'", with: "version='1.2'").utf8)), .unsafe)
        let scsu = Data("<?xml version='1.0' encoding='SCSU'?>".utf8) + Data([0x0F])
            + "<!DOCTYPE x [<!ENTITY y 'z'>]><x/>".data(using: .utf16BigEndian)!
        XCTAssertEqual(XMLSafety.assess(scsu), .unsafe, "SCSU Unicode mode hides markup bytes")
        let converted = CFStringConvertIANACharSetNameToEncoding("IBM037" as CFString)
        if converted != kCFStringEncodingInvalidId {
            let ibm037 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
            for name in ["IBM037", "UTF-8", "utf8"] {
                let text = "<?xml version='1.0' encoding='\(name)'?><!DOCTYPE x [<!ENTITY y 'z'>]><x/>"
                if let ebcdic = text.data(using: ibm037) {
                    XCTAssertEqual(XMLSafety.assess(ebcdic), .unsafe, "EBCDIC declaration naming \(name)")
                }
            }
        }
        let ebcdicSCSU: [UInt8] = [0x4C, 0x6F, 0xA7, 0x94, 0x93, 0x40, 0xA5, 0x85, 0x99, 0xA2, 0x89, 0x96, 0x95, 0x7E, 0x7F, 0xF1, 0x4B, 0xF0, 0x7F,
                                  0x40, 0x85, 0x95, 0x83, 0x96, 0x84, 0x89, 0x95, 0x87, 0x7E, 0x7F, 0xE2, 0xC3, 0xE2, 0xE4, 0x7F]
            + [UInt8](repeating: 0x40, count: 8) + [0x6F, 0x6E]
        XCTAssertEqual(XMLSafety.assess(Data(ebcdicSCSU) + Data([0x0F])
            + "<!DOCTYPE x [<!ENTITY y 'z'>]><x/>".data(using: .utf16BigEndian)!), .unsafe)
        let wideProlog = "<?xml version='1.2' encoding='UTF-16BE'" + String(repeating: " ", count: 6) + "?>"
        let mixedWide = Data([0xFF, 0xFE]) + wideProlog.data(using: .utf16LittleEndian)!
            + "<!DOCTYPE x [<!ENTITY y 'z'>]><x/>".data(using: .utf16BigEndian)!
        XCTAssertEqual(XMLSafety.assess(mixedWide), .unsafe, "ambiguous switch after a wide declaration")
        var files = try Fixture.files()
        files["OPS/one.xhtml"] = utf7
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertThrowsError(try publication.textSection(at: 0)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent("OPS/one.xhtml"))
        }
        files["OPS/book.opf"] = utf7
        XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files))) {
            XCTAssertEqual($0 as? EPUBPublicationError, .invalidXML("OPS/book.opf"))
        }
    }
}
