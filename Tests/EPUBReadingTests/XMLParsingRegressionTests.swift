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

    func testNamesMadeOfALoneColonAreSkippedInContainerPackageAndNavigationDocuments() throws {
        // XML 1.0's Name admits ":" alone, and the parser hands such a name on. These documents
        // take local names by splitting at colons, so the name must survive having no pieces.
        func book(_ file: String, _ target: String, _ replacement: String, epub2: Bool = false) throws -> EPUBPublication {
            let source = String(decoding: try XCTUnwrap(Fixture.files(epub2: epub2)[file]), as: UTF8.self)
            XCTAssertTrue(source.contains(target), "\(file) has no \(target)")
            return try EPUBPublication.open(data: Fixture.epub(
                overrides: [file: source.replacingOccurrences(of: target, with: replacement)], epub2: epub2))
        }
        let books = [
            try book("META-INF/container.xml", "<rootfiles>", "<:/><rootfiles><:>x</:>"),
            try book("OPS/book.opf", "<dc:creator>", "<:>x</:><dc:creator>"),
            try book("OPS/book.opf", "<manifest>", "<manifest><: id='z' href='z.xhtml' media-type='application/xhtml+xml'/>"),
            try book("OPS/book.opf", "<itemref idref=\"one\"/>", "<: idref='two'/><itemref :='q' idref=\"one\"/>"),
        ]
        for (index, book) in books.enumerated() {
            XCTAssertEqual(book.metadata.title, "A Test Book", "\(index)")
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], "\(index)")
            XCTAssertEqual(book.tableOfContents.map(\.title), ["First Chapter"], "\(index)")
        }
        XCTAssertThrowsError(try book("OPS/book.opf", "package", ":"), "a package document whose root is not a package")
        // Each label is reworded, so its document and not the other one is known to have been read.
        let nav = try book("OPS/nav.xhtml", "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml#start\">First <em>Chapter</em></a>",
            "<: epub:type=\"toc\"/><nav epub:type=\"toc\"><:/><ol><:>x</:><li><a href=\"one.xhtml#start\">Opening <:>Part</:></a>")
        XCTAssertEqual(nav.tableOfContents.map(\.title), ["Opening Part"])
        let ncx = try book("OPS/toc.ncx", "<navMap><navPoint id=\"one\" playOrder=\"1\"><navLabel><text>First Chapter</text>",
            "<navMap><:/><navPoint id=\"one\" playOrder=\"1\"><navLabel><:/><text>Opening <:>Part</:></text>", epub2: true)
        XCTAssertEqual(ncx.tableOfContents.map(\.title), ["Opening Part"])
    }

    func testNamesThatNamespacesInXMLForbidsAreUnknownElementsInContainerPackageAndNavigationDocuments() throws {
        // libxml2 reports these names with a namespace error and reads on, and XMLParser hands
        // each on as written, with no error (#644).
        final class Names: NSObject, XMLParserDelegate {
            var elements: [String] = [], attributes: [String] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                elements.append(name)
                self.attributes += attributes.keys.sorted()
            }
        }
        let names = Names()
        let parser = XMLParser(data: Data("<r><:navPoint/><script:/><a:b:c/><a::/><p :id='1' id:='2' a:b:c='3' xmlns:='4'/></r>".utf8))
        parser.delegate = names
        XCTAssertTrue(parser.parse())
        XCTAssertEqual(names.elements, ["r", ":navPoint", "script:", "a:b:c", "a::", "p"])
        XCTAssertEqual(names.attributes, [":id", "a:b:c", "id:", "xmlns:"])

        // Each is an unknown element, as libxml2's XML parser reads it, and not the element its
        // last piece names; the book is not refused. Every decoy here was
        // once read as that element, and each case has one, so that each is shown on its own.
        let typed = "full-path='missing.opf' media-type='application/oebps-package+xml'"
        let navStart = "<nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml#start\">"
        let decoys = "<ol><li><a href=\"two.xhtml\">Decoy</a></li></ol>"
        let pointStart = "<navPoint id=\"one\" playOrder=\"1\"><navLabel>"
        func decoy(_ element: String, before tag: String, in start: String) -> String {
            start.replacingOccurrences(of: tag, with: element + tag)
        }
        let cases: [(file: String, target: String, replacement: String)] = [
            ("META-INF/container.xml", "<rootfiles>", "<rootfiles><:rootfile \(typed)/>"),
            ("META-INF/container.xml", "<rootfiles>", "<rootfiles><rootfile: \(typed)/>"),
            ("META-INF/container.xml", "<rootfiles>", "<rootfiles><a:b:rootfile \(typed)/>"),
            ("OPS/book.opf", "<itemref idref=\"one\"/>", "<:itemref idref='two'/><itemref idref=\"one\"/>"),
            ("OPS/book.opf", "<itemref idref=\"one\"/>", "<itemref: idref='two'/><itemref idref=\"one\"/>"),
            ("OPS/book.opf", "<itemref idref=\"one\"/>", "<opf:a:itemref idref='two'/><itemref idref=\"one\"/>"),
            ("OPS/nav.xhtml", navStart, "<x:y:nav epub:type=\"toc\">\(decoys)</x:y:nav>\(navStart)"),
            // An attribute's name is split the same way: `:epub:type` is not `epub:type`.
            ("OPS/nav.xhtml", navStart, "<nav :epub:type=\"toc\">\(decoys)</nav>\(navStart)"),
            ("OPS/nav.xhtml", navStart, decoy("<:a href=\"two.xhtml\">Decoy</:a>", before: "<a ", in: navStart)),
            ("OPS/nav.xhtml", navStart, decoy("<span: href=\"two.xhtml\">Decoy</span:>", before: "<a ", in: navStart)),
            ("OPS/nav.xhtml", navStart, decoy("<a:b:ol>\(decoys.dropFirst(4).dropLast(5))</a:b:ol>", before: "<a ", in: navStart)),
            ("OPS/toc.ncx", pointStart, "<:navPoint id=\"z\"><navLabel><text>Decoy</text></navLabel>"
                + "<content src=\"two.xhtml\"/></:navPoint>\(pointStart)"),
            ("OPS/toc.ncx", pointStart, decoy("<a:b:navLabel><text>Decoy</text></a:b:navLabel>", before: "<navLabel>", in: pointStart)),
            ("OPS/toc.ncx", pointStart, decoy("<content: src=\"two.xhtml\"/>", before: "<navLabel>", in: pointStart)),
        ]
        for (file, target, replacement) in cases {
            let epub2 = file.hasSuffix(".ncx")
            let source = String(decoding: try XCTUnwrap(Fixture.files(epub2: epub2)[file]), as: UTF8.self)
            XCTAssertTrue(source.contains(target), "\(file) has no \(target)")
            let book: EPUBPublication
            do {
                book = try EPUBPublication.open(data: Fixture.epub(
                    overrides: [file: source.replacingOccurrences(of: target, with: replacement)], epub2: epub2))
            } catch {
                XCTFail("\(replacement): \(error)")
                continue
            }
            XCTAssertEqual(book.spine.map(\.resource.path), ["OPS/one.xhtml", "OPS/two.xhtml"], replacement)
            XCTAssertEqual(book.tableOfContents.map(\.title), ["First Chapter"], replacement)
            XCTAssertEqual(book.tableOfContents.first?.href, "OPS/one.xhtml#start", replacement)
            XCTAssertEqual(book.tableOfContents.first?.children.map(\.title), ["Second Chapter"], replacement)
        }
    }

}
