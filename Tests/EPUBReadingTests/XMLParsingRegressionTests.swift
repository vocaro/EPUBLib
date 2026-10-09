@testable import EPUBCore
@testable import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest
import Foundation

final class XMLParsingRegressionTests: XCTestCase {
    func testNavigationRoleTokensAcceptAllXMLWhitespace() throws {
        for separator in [" ", "&#x9;", "&#xA;", "&#xD;", " &#x9;&#xA;&#xD; "] {
            let nav = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Contents</title></head><body>
            <nav epub:type="\(separator)frontmatter\(separator)toc\(separator)"><ol>
              <li><a href="one.xhtml">First Chapter</a></li>
            </ol></nav></body></html>
            """
            let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": nav]))
            XCTAssertEqual(book.tableOfContents.map(\.title), ["First Chapter"], "separator: \(separator)")
        }
    }

    func testDeclarationExamplesInCDATAArePlainText() throws {
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>XML tutorial</title></head>
        <body><pre><![CDATA[<!ENTITY example "value">]]></pre></body></html>
        """
        XCTAssertTrue(XMLParser(data: Data(chapter.utf8)).parse())
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter]))
        XCTAssertEqual(try book.textSection(at: 0).text, "<!ENTITY example \"value\">")
    }

    func testDeclarationExamplesInCommentsDoNotRejectTheBook() throws {
        var files = try Fixture.files()
        let opf = String(decoding: files["OPS/book.opf"]!, as: UTF8.self)
        files["OPS/book.opf"] = Data(("<!-- Example syntax: <!ENTITY example 'value'> -->" + opf).utf8)
        XCTAssertTrue(XMLParser(data: files["OPS/book.opf"]!).parse())
        XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).metadata.title, "A Test Book")
    }

    func testCommentsAndProcessingInstructionsDoNotHideRealDeclarations() throws {
        let prologs = [
            "<!-- <!ENTITY example 'value'> -->",
            "<?example <!DOCTYPE html [ ?>",
            "<!-- <![CDATA[ -->",
            "<!-- quote: \" --><?example '> [' ?>",
        ]
        for prolog in prologs {
            for declaration in [
                "<!DOCTYPE html []>",
                "<!DOCTYPE html [<!-- no entities, but still an internal subset -->]>",
                "<!DOCTYPE html [<!ENTITY x 'expanded'>]>",
                "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///never-read'>]>",
            ] {
                let xml = prolog + declaration + "<html><body>Text</body></html>"
                let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xml]))
                XCTAssertThrowsError(try book.textSection(at: 0), xml)
                XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": xml])), xml)
            }
        }
    }

    func testQuotedExternalIdentifiersAreNotInternalSubsets() throws {
        // A bracket or > inside the quoted system identifier is not DTD syntax. The external
        // identifier remains unresolved; the document needs no declarations from it.
        for identifier in ["https://example.invalid/schema[example].dtd", "urn:example:greater>than["] {
            let xml = "<!DOCTYPE html SYSTEM '\(identifier)'><html><body><p>Text</p></body></html>"
            XCTAssertTrue(XMLParser(data: Data(xml.utf8)).parse())
            let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xml]))
            XCTAssertEqual(try book.textSection(at: 0).text, "Text")
            XCTAssertNoThrow(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": xml])))
        }
    }

    func testHarmlessAndRealDeclarationsAcrossUnicodeEncodings() throws {
        let encodings: [(String.Encoding, String)] = [
            (.utf8, "UTF-8"), (.utf16, "UTF-16"),
            (.utf16BigEndian, "UTF-16BE"), (.utf16LittleEndian, "UTF-16LE"),
            (.utf32BigEndian, "UTF-32BE"),
        ]
        for (encoding, name) in encodings {
            let declaration = "<?xml version='1.0' encoding='\(name)'?>"
            let harmless = declaration + "<!-- <!ENTITY example 'value'> -->"
                + "<html><body><pre><![CDATA[<!DOCTYPE html [ <!ENTITY example 'value'> ]>]]></pre></body></html>"
            var files = try Fixture.files()
            files["OPS/one.xhtml"] = try XCTUnwrap(harmless.data(using: encoding))
            let book = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertEqual(try book.textSection(at: 0).text,
                           "<!DOCTYPE html [ <!ENTITY example 'value'> ]>", name)
            files["OPS/nav.xhtml"] = files["OPS/one.xhtml"]
            XCTAssertNoThrow(try EPUBPublication.open(data: Fixture.archive(files)), name)

            let hostile = declaration + "<!-- harmless -->"
                + "<!DOCTYPE html [<!ENTITY x 'expanded'>]><html><body>&x;</body></html>"
            files["OPS/one.xhtml"] = try XCTUnwrap(hostile.data(using: encoding))
            let hostileBook = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertThrowsError(try hostileBook.textSection(at: 0), name)
            files["OPS/nav.xhtml"] = files["OPS/one.xhtml"]
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.archive(files)), name)
        }
    }

    func testUnterminatedCommentsAndCDATAAreRejected() throws {
        for xml in ["<html><body><!-- text", "<html><body><![CDATA[text"] {
            let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xml]))
            XCTAssertThrowsError(try book.textSection(at: 0))
            XCTAssertThrowsError(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": xml])))
        }
    }


    func testDeclarationScreeningHandlesUTF32LEIndependentlyOfParserSupport() throws {
        // Apple's XML parser does not accept UTF-32LE here. The pre-parser safety check must
        // still recognize its markup if a parser supports it on another platform/version.
        let harmless = "<!-- <!ENTITY x 'example'> --><html><body>Text</body></html>"
        let hostile = "<!DOCTYPE html [<!ENTITY x 'expanded'>]><html><body>&x;</body></html>"
        for bom in [Data(), Data([0xFF, 0xFE, 0, 0])] {
            XCTAssertTrue(XMLSafety.hasSafeDeclarations(bom + (try XCTUnwrap(harmless.data(using: .utf32LittleEndian)))))
            XCTAssertFalse(XMLSafety.hasSafeDeclarations(bom + (try XCTUnwrap(hostile.data(using: .utf32LittleEndian)))))
        }
    }

    func testEPUBTypeAndAPlainTypeOnOneElementStayApart() throws {
        // Varying the other attributes varies the order the parser's attribute dictionary
        // iterates in, which once decided which of the two survived.
        for extra in ["", " id=\"a\"", " id=\"a\" class=\"b\"", " id=\"a\" class=\"b\" dir=\"ltr\"",
                      " id=\"a\" class=\"b\" dir=\"ltr\" rel=\"c\"", " hreflang=\"en\" rel=\"c\" tabindex=\"0\""] {
            let both = "type=\"application/xhtml+xml\" epub:type=\"bodymatter\"\(extra)"
            let nav = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Contents</title></head><body>
            <nav type="text/html" epub:type="toc"\(extra)><ol><li><a href="one.xhtml">First Chapter</a></li></ol></nav>
            <nav epub:type="landmarks"><ol><li><a href="two.xhtml" \(both)>Start</a></li></ol></nav>
            <nav type="text/html" epub:type="page-list" hidden=""\(extra)><ol><li><a href="two.xhtml#p">2</a></li></ol></nav>
            </body></html>
            """
            let book = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": nav]))
            XCTAssertEqual(book.tableOfContents.map(\.title), ["First Chapter"], extra)
            XCTAssertEqual(book.landmarks, [EPUBLandmark(types: ["bodymatter"], title: "Start", href: "OPS/two.xhtml")], extra)
            XCTAssertEqual(book.pageList, [EPUBPageListEntry(label: "2", href: "OPS/two.xhtml#p")], extra)

            // The OPF guide reads the plain `type`, which an `epub:type` beside it must not replace.
            var files = try Fixture.files(epub2: true)
            let opf = String(decoding: files["OPS/book.opf"]!, as: UTF8.self).replacingOccurrences(of: "</package>", with: """
                <guide xmlns:epub="http://www.idpf.org/2007/ops"><reference href="two.xhtml" \
                type="text" epub:type="bodymatter"\(extra)/></guide></package>
                """)
            files["OPS/book.opf"] = Data(opf.utf8)
            XCTAssertEqual(try EPUBPublication.open(data: Fixture.archive(files)).landmarks.map(\.types), [["text"]], extra)
        }
    }

    func testNavigationTypesAreReadByNamespace() throws {
        func contents(_ html: String, _ nav: String) throws -> [String] {
            let document = "\(html)<head><title>Contents</title></head><body>\(nav)"
                + "<ol><li><a href=\"one.xhtml\">First Chapter</a></li></ol></nav></body></html>"
            return try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": document])).tableOfContents.map(\.title)
        }
        let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\""
        XCTAssertEqual(try contents("\(xhtml) xmlns:ops=\"http://www.idpf.org/2007/ops\">", "<nav ops:type=\"toc\">"),
                       ["First Chapter"], "any prefix bound to the OPS namespace")
        XCTAssertEqual(try contents("\(xhtml)>", "<nav epub:type=\"toc\">"), ["First Chapter"], "an undeclared epub prefix")
        XCTAssertEqual(try contents("\(xhtml)>", "<nav xmlns:epub=\"urn:unrelated\" epub:type=\"toc\">"), [],
                       "an epub prefix bound elsewhere")
        XCTAssertEqual(try contents("\(xhtml)>", "<div xmlns:ops=\"http://www.idpf.org/2007/ops\"/><nav ops:type=\"toc\">"), [],
                       "a sibling's declaration is out of scope")
        let plain = "\(xhtml)><body><nav type=\"page-list\"><ol><li><a href=\"two.xhtml\">2</a></li></ol></nav></body></html>"
        XCTAssertNil(try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/nav.xhtml": plain])).pageList,
                     "a plain type is not epub:type")
    }

}
