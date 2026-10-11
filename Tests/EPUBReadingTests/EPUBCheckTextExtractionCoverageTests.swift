import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import Foundation
import XCTest

/// Content document constructs EPUBCheck's scenarios check, as headless text extraction meets
/// them, and the classification the opt-in corpus runners rely on.
final class EPUBCheckTextExtractionCoverageTests: XCTestCase {
    private func page(_ body: String, prolog: String = "<!DOCTYPE html>", encoding: String = "UTF-8") -> String {
        """
        <?xml version="1.0" encoding="\(encoding)"?>
        \(prolog)
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en"><head><title>Page</title></head><body>\(body)</body></html>
        """
    }

    private func section(_ document: Data) throws -> EPUBTextSection {
        var files = try Fixture.files()
        files["OPS/one.xhtml"] = document
        return try EPUBPublication.open(data: Fixture.archive(files)).textSection(at: 0)
    }

    func testAUTF16ContentDocumentExtracts() throws {
        // EPUB 3.3, 3.3: XML-based resources "MUST be encoded in UTF-8 or UTF-16".
        let text = page("<h1 id=\"h\">Überschrift</h1><p>Zwölf Boxkämpfer — 日本語 — jagen Viktor.</p>", encoding: "UTF-16")
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let mark = encoding == .utf16LittleEndian ? Data([0xFF, 0xFE]) : Data([0xFE, 0xFF])
            let extracted = try section(mark + (try XCTUnwrap(text.data(using: encoding))))
            XCTAssertEqual(extracted.text, "Überschrift\nZwölf Boxkämpfer — 日本語 — jagen Viktor.", "\(encoding)")
            XCTAssertEqual(extracted.title, "Page", "\(encoding)")
            XCTAssertEqual(extracted.headings.map(\.text), ["Überschrift"], "\(encoding)")
            XCTAssertEqual(extracted.anchors["h"], EPUBTextMark(offset: 0, separator: 0), "\(encoding)")
        }
    }

    func testAContentDocumentInADeclaredLegacyEncodingExtractsInThatEncoding() throws {
        // RSC-028 for EPUBCheck. The XML declaration names the encoding, so nothing is guessed.
        for (name, encoding) in [("ISO-8859-1", String.Encoding.isoLatin1), ("windows-1252", .windowsCP1252)] {
            let text = page("<p>Café Zürich, Æsop &amp; Ñandú.</p>", encoding: name)
            XCTAssertEqual(try section(try XCTUnwrap(text.data(using: encoding))).text, "Café Zürich, Æsop & Ñandú.", name)
        }
    }

    func testEPUB2AndEPUB3DoctypesExtract() throws {
        for prolog in ["<!DOCTYPE html>", "<!DOCTYPE html SYSTEM \"about:legacy-compat\">", "",
                       "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\"\n \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">",
                       "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">"] {
            let extracted = try section(Data(page("<p>Caf&#233; d&#xE9;j&#224; vu &amp; more.</p>", prolog: prolog).utf8))
            XCTAssertEqual(extracted.text, "Café déjà vu & more.", prolog)
            XCTAssertFalse(extracted.recoveredAsHTML, prolog)
        }
    }

    func testASpineItemThatIsNotXHTMLFailsWithItsMediaTypeWhateverItsFallback() throws {
        // The documented answer for an SVG content document and for a foreign resource with a
        // manifest fallback: "other spine media types fail explicitly".
        let opf = """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
            <dc:title>T</dc:title><dc:language>en</dc:language><dc:identifier id="uid">t</dc:identifier></metadata><manifest>\
            <item id="plate" href="plate.svg" media-type="image/svg+xml"/><item id="slides" href="slides.pdf" media-type="application/pdf" fallback="one"/>\
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\
            </manifest><spine><itemref idref="plate"/><itemref idref="slides"/><itemref idref="one"/></spine></package>
            """
        let book = try EPUBPublication.open(data: Fixture.epub(overrides: [
            "OPS/book.opf": opf, "OPS/slides.pdf": "%PDF-1.4",
            "OPS/plate.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><title>A plate</title><text x=\"1\" y=\"5\">Plate</text></svg>",
        ]))
        XCTAssertThrowsError(try book.textSection(at: 0)) { XCTAssertEqual($0 as? EPUBTextExtractionError, .unsupportedMediaType("image/svg+xml")) }
        XCTAssertThrowsError(try book.textSection(at: 1)) { XCTAssertEqual($0 as? EPUBTextExtractionError, .unsupportedMediaType("application/pdf")) }
        XCTAssertTrue(try book.textSection(at: 2).text.hasPrefix("First Chapter"))
    }

    func testADocumentDeclaringEntitiesInAnInternalSubsetFailsAsDocumentedWithOrWithoutRecovery() throws {
        var files = try Fixture.files()
        files["OPS/one.xhtml"] = Data(page("<p>Published by &publisher;.</p>", prolog: "<!DOCTYPE html [\n <!ENTITY publisher \"A Press\">\n]>").utf8)
        let book = try EPUBPublication.open(data: Fixture.archive(files))
        for recovers in [false, true] {
            XCTAssertThrowsError(try book.textSection(at: 0, recoversMalformedMarkup: recovers), "recovery \(recovers)") {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent("OPS/one.xhtml"), "recovery \(recovers)")
            }
        }
    }

    // MARK: The corpus runners' own classification

    func testScenariosClassifyTheirFixturesByWhatEPUBCheckReports() {
        let feature = """
            Feature: A feature

              Background:
                Given EPUB test files located at '/area/files/'
                And EPUBCheck with default settings

              @spec @xref:sec-one
              Scenario: a valid publication
                When checking EPUB 'one-valid'
                Then no errors or warnings are reported

              Rule: a rule

                Example: an error
                  When checking EPUB 'two-error.epub'
                  Then the error RSC-005 is reported 2 times
                  And the message contains 'something'
                  And no other errors or warnings are reported

              Scenario: a warning in a single document
                Given the reporting level is set to USAGE
                When checking document 'three-warning.xhtml'
                Then warning HTM-055 is reported
                And usage ACC-004 is reported

              Scenario: only a usage
                When checking file 'sub/../four-usage.opf'
                Then usage OPF-090 is reported
                But no other errors or warnings are reported

              Scenario: listed messages
                Given test files located at '/other/'
                When checking EPUB 'five'
                Then the following errors are reported
                  | RSC-005 | first  |
                  | OPF-014 | second |
                And no other errors or warnings are reported

              Scenario: nothing asserted about messages
                When checking EPUB 'six'
                Then the JSON report is valid
            """
        let scenarios = EPUBCheckCorpus.scenarios(in: feature, feature: "area/a.feature")
        XCTAssertEqual(scenarios.map(\.path), ["area/files/one-valid", "area/files/two-error.epub", "area/files/three-warning.xhtml",
                                             "area/files/four-usage.opf", "other/five", "area/files/six"])
        XCTAssertEqual(scenarios.map(\.verdict), [.valid, .invalid, .invalid, .valid, .invalid, .unclassified])
        XCTAssertEqual(scenarios.map(\.ids), [[], ["RSC-005"], ["HTM-055", "ACC-004"], ["OPF-090"], ["RSC-005", "OPF-014"], []])
        XCTAssertEqual(scenarios.map(\.name).first, "a valid publication")
    }

    func testAPackageDocumentWrappedInAContainerOpensWithAStubForEachManifestItem() throws {
        let opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:title>Wrapped</dc:title><dc:language>en</dc:language><dc:identifier id="uid">wrapped</dc:identifier></metadata>
              <manifest>
                <item id="c1" href="text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
                <item id='n' properties='nav' media-type='application/xhtml+xml' href='nav.xhtml'/>
                <item id="i" href="../images/a&amp;b.png" media-type="image/png"/><item id="s" href="plate.svg" media-type="image/svg+xml"/>
                <item id="r" href="https://example.invalid/remote.mp3" media-type="audio/mpeg"/>
              </manifest><spine><itemref idref="c1"/><itemref idref="s"/></spine></package>
            """
        let wrapped = EPUBCheckCorpus.container(aroundPackageDocument: Data(opf.utf8))
        XCTAssertThrowsError(try EPUBPublication.open(data: wrapped), "the remote item is refused, as documented") {
            XCTAssertEqual($0 as? EPUBPublicationError, .unsafePath("https://example.invalid/remote.mp3"))
        }
        let local = opf.replacingOccurrences(of: "<item id=\"r\" href=\"https://example.invalid/remote.mp3\" media-type=\"audio/mpeg\"/>", with: "")
        let book = try EPUBPublication.open(data: EPUBCheckCorpus.container(aroundPackageDocument: Data(local.utf8)))
        XCTAssertEqual(book.metadata.title, "Wrapped")
        XCTAssertEqual(book.spine.map(\.resource.path), ["EPUB/text/chapter 1.xhtml", "EPUB/plate.svg"])
        XCTAssertEqual(book.resources.map(\.path).sorted(), ["EPUB/nav.xhtml", "EPUB/plate.svg", "EPUB/text/chapter 1.xhtml", "images/a&b.png"])
        XCTAssertEqual(book.tableOfContents.map(\.title), ["Stub"])
        XCTAssertEqual(try book.textSection(at: 0).text, "Stub.")
        let single = try EPUBPublication.open(data: EPUBCheckCorpus.container(aroundContentDocument: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8),
                                                                              name: "document.svg", mediaType: "image/svg+xml"))
        XCTAssertEqual(single.spine.map(\.resource.mediaType), ["image/svg+xml"])
    }
}
