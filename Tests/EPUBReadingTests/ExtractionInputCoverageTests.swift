import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest

/// Input classes of the strict extraction path: namespaces, character references, encodings,
/// spine shapes and each documented limit at its boundary.
final class ExtractionInputCoverageTests: XCTestCase {
    private static let files: [String: Data] = (try? Fixture.files()) ?? [:]
    private let path = "OPS/one.xhtml"
    private let xhtml11 = #"<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">"#

    private func book(_ xml: String) throws -> EPUBPublication { try book(Data(xml.utf8)) }
    private func book(_ data: Data) throws -> EPUBPublication {
        var files = Self.files
        files[path] = data
        return try EPUBPublication.open(data: Fixture.archive(files))
    }
    private func page(_ body: String, head: String = "<title>T</title>") -> String {
        "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head>\(head)</head><body>\(body)</body></html>"
    }
    private func assertMalformed(_ publication: EPUBPublication, recovering: Bool = false, _ message: String = "",
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try publication.textSection(at: 0, recoversMalformedMarkup: recovering), message, file: file, line: line) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), message, file: file, line: line)
        }
    }
    private func assertLimit(_ name: String, _ publication: EPUBPublication, _ limits: EPUBTextExtractionLimits, recovering: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits, recoversMalformedMarkup: recovering), file: file, line: line) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded(name), file: file, line: line)
        }
    }

    // MARK: Namespaces and document structure

    func testXHTMLUnderANamespacePrefixIsReadLikeTheDefaultNamespace() throws {
        let section = try book("<h:html xmlns:h='http://www.w3.org/1999/xhtml'><h:head><h:title>Pre</h:title></h:head><h:body id='b'>"
            + "<h:h1 id='h'>Head</h:h1><h:p>Para<h:br/>two <h:img alt='pic'/></h:p><h:script>no</h:script></h:body></h:html>").textSection(at: 0)
        XCTAssertEqual(section.title, "Pre")
        XCTAssertEqual(section.text, "Head\nPara\ntwo pic")
        XCTAssertEqual(section.anchors, ["b": EPUBTextMark(offset: 0, separator: 0), "h": EPUBTextMark(offset: 0, separator: 0)])
        XCTAssertEqual(section.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 0, separator: 0), text: "Head")])
    }

    // Well-formed XML that is not an XHTML document is a structural rejection, which the docs
    // keep an error under recovery too.
    func testWellFormedDocumentsWithoutExactlyOneXHTMLBodyAreMalformedOnBothPaths() throws {
        for xml in [
            "<svg xmlns='http://www.w3.org/2000/svg'><text>x</text></svg>",
            "<html xmlns='urn:not-xhtml'><head><title>T</title></head><body><p>x</p></body></html>",
            "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>a</p></body><body><p>b</p></body></html>",
            "<html xmlns='http://www.w3.org/1999/xhtml'><div><body><p>x</p></body></div></html>",
            "<HTML><BODY><P>x</P></BODY></HTML>",
            "<body xmlns='http://www.w3.org/1999/xhtml'><p>x</p></body>",
        ] {
            let publication = try book(xml)
            assertMalformed(publication, xml)
            assertMalformed(publication, recovering: true, xml)
        }
    }

    func testAnEmptyOrWhitespaceOnlyBodyIsAnEmptySectionNotAnError() throws {
        for body in ["<body></body>", "<body/>", "<body>  \n\t </body>", "<body><div><p> </p></div><!-- nothing --></body>"] {
            let section = try book("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Blank</title></head>\(body)</html>").textSection(at: 0)
            XCTAssertEqual(section.title, "Blank", body)
            XCTAssertEqual(section.text, "", body)
            XCTAssertTrue(section.anchors.isEmpty && section.headings.isEmpty && section.semanticTypes.isEmpty, body)
            XCTAssertFalse(section.recoveredAsHTML, body)
        }
    }

    // MARK: Character references

    func testNamedReferencesCoverCaseVariantsSymbolsAndInvisibleCharacters() throws {
        let section = try book(page("<p>&Eacute;&eacute;&Alpha;&hellip;&euro;&thinsp;|&ensp;|&zwnj;|&shy;|&lrm;|&nsub;</p>")).textSection(at: 0)
        XCTAssertEqual(section.text, "ÉéΑ…€ | |\u{200C}|\u{AD}|\u{200E}|⊄")
    }

    func testNamedReferencesDecodeInAttributeValuesAndAfterAStandaloneDeclaration() throws {
        let section = try book("<?xml version='1.0' encoding='utf-8' standalone='no'?>" + xhtml11
            + page("<p id='caf&eacute;'>x&nbsp;y</p>", head: "<title>A&mdash;B</title><meta name='n' content='a&nbsp;b'/>")).textSection(at: 0)
        XCTAssertEqual(section.title, "A—B")
        XCTAssertEqual(section.text, "x y")
        XCTAssertEqual(section.anchors, ["café": EPUBTextMark(offset: 0, separator: 0)])
    }

    func testTheHTMLStandardsNamesDecodeInTextAttributesAndTitlesWithOrWithoutADoctype() throws {
        // The viewer's table (#184): names HTML 4 lacks, those of two scalars, and HTML 5's U+27E8
        // and U+27E9 for `&lang;` and `&rang;`, where libxml2's HTML 4 table has U+2329 and U+232A.
        for prolog in ["", xhtml11] {
            let section = try book(prolog + page("<p id='Dvo&rcaron;&aacute;k'>Dvo&rcaron;&aacute;k &check; &lang;1&rang; &NotEqualTilde;</p>",
                                                 head: "<title>&ccaron;&comma;&Afr;</title>")).textSection(at: 0)
            XCTAssertEqual(section.title, "\u{10D},\u{1D504}", prolog)
            XCTAssertEqual(section.text, "Dvo\u{159}\u{E1}k \u{2713} \u{27E8}1\u{27E9} \u{2242}\u{338}", prolog)
            XCTAssertEqual(section.anchors, ["Dvo\u{159}\u{E1}k": EPUBTextMark(offset: 0, separator: 0)], prolog)
            XCTAssertFalse(section.recoveredAsHTML, prolog)
        }
    }

    func testUnknownMiscasedAndUnterminatedReferencesAreMalformedInTextAttributesAndTitles() throws {
        for (body, head) in [
            ("<p>a&NBSP;b</p>", "<title>T</title>"), ("<p>a&bogus;b</p>", "<title>T</title>"),
            ("<p>A <img alt='x &bogus; y'/> B</p>", "<title>T</title>"), ("<p id='a&bogus;b'>A</p>", "<title>T</title>"),
            ("<p>x</p>", "<title>A &bogus; B</title>"), ("<p>a&nbsp b</p>", "<title>T</title>"),
            ("<p>a&abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz;b</p>", "<title>T</title>"), ("<p>a & b</p>", "<title>T</title>"),
        ] {
            // With an external DOCTYPE an undeclared name is no well-formedness error, so the
            // reader itself must refuse it; without one the parser does. The viewer reads such a
            // section as HTML, as recovery does, keeping a name HTML does not know as written.
            assertMalformed(try book(xhtml11 + page(body, head: head)), body + head)
            assertMalformed(try book(page(body, head: head)), body + head)
        }
        assertMalformed(try book(page("<p>a</p>") + "&"))
    }

    func testNumericReferencesDecodeAstralScalarsAndRefuseInvalidCodePoints() throws {
        let section = try book(page("<p>a&#x1F600;<b id='b'>b</b>&#128512;c</p>")).textSection(at: 0)
        XCTAssertEqual(section.text, "a\u{1F600}b\u{1F600}c")
        XCTAssertEqual(section.anchors["b"], EPUBTextMark(offset: 5, separator: 0))
        for reference in ["&#0;", "&#x1;", "&#xD800;", "&#xFFFE;", "&#x110000;", "&#;", "&#x;", "&#xZ;"] {
            assertMalformed(try book(page("<p>a\(reference)b</p>")), reference)
        }
    }

    func testReferenceSpellingsInProcessingInstructionsAndDoctypeIdentifiersStayInert() throws {
        let section = try book("<?xml version='1.0'?><?xml-stylesheet href='a.css' type='text/css'?><!DOCTYPE html SYSTEM \"x&nbsp;y\">"
            + page("<?php echo '&nbsp;&bogus;'; ?><p>a&nbsp;b</p>")).textSection(at: 0)
        XCTAssertEqual(section.text, "a b")
    }

    // MARK: Encodings

    func testAUTF8ByteOrderMarkIsAnEncodingSignatureNotText() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let xml = page("<p id='a'>café “q”</p>", head: "<title>Té</title>")
        for prefix in ["", "<?xml version='1.0' encoding='UTF-8'?>"] {
            let section = try book(bom + Data((prefix + xml).utf8)).textSection(at: 0)
            XCTAssertEqual(section.title, "Té")
            XCTAssertEqual(section.text, "café “q”")
            XCTAssertEqual(section.anchors["a"], EPUBTextMark(offset: 0, separator: 0))
        }
        let recovered = try book(bom + Data(page("<p id='a'>café</b> x</p>", head: "<title>Té</title>").utf8))
            .textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(recovered.recoveredAsHTML)
        XCTAssertEqual(recovered.title, "Té")
        XCTAssertEqual(recovered.text, "café x")
        XCTAssertEqual(recovered.anchors["a"], EPUBTextMark(offset: 0, separator: 0))
    }

    func testUTF16WithAByteOrderMarkNeedsNoDeclarationAndOffsetsStayUTF8Bytes() throws {
        let xml = page("<p id='a'>café\u{1F600}</p><p id='b'>x</p>", head: "<title>Té</title>")
        let encoded = [Data([0xFF, 0xFE]) + (try XCTUnwrap(xml.data(using: .utf16LittleEndian))),
                       Data([0xFE, 0xFF]) + (try XCTUnwrap(xml.data(using: .utf16BigEndian)))]
        for data in encoded {
            let section = try book(data).textSection(at: 0)
            XCTAssertEqual(section.title, "Té")
            XCTAssertEqual(section.text, "café\u{1F600}\nx")
            XCTAssertEqual(section.anchors, ["a": EPUBTextMark(offset: 0, separator: 0), "b": EPUBTextMark(offset: 10, separator: 1)])
            XCTAssertFalse(section.recoveredAsHTML)
        }
    }

    // XML 1.0, 4.3.3: an entity with neither a byte-order mark nor an encoding declaration is
    // UTF-8; UTF-16 bytes there are a fatal error rather than something to guess at.
    func testUTF16WithoutAByteOrderMarkOrDeclarationIsMalformedOnTheStrictPath() throws {
        let xml = page("<p>café</p>")
        assertMalformed(try book(try XCTUnwrap(xml.data(using: .utf16LittleEndian))))
        assertMalformed(try book(try XCTUnwrap(xml.data(using: .utf16BigEndian))))
    }

    func testDeclaredLegacyEncodingsDecodeTogetherWithNamedReferences() throws {
        let latin1 = "<?xml version='1.0' encoding='ISO-8859-1'?>" + page("<p>café&nbsp;&mdash;&eacute;</p>", head: "<title>Té</title>")
        let first = try book(try XCTUnwrap(latin1.data(using: .isoLatin1))).textSection(at: 0)
        XCTAssertEqual(first.title, "Té")
        XCTAssertEqual(first.text, "café —é")
        let windows = "<?xml version='1.0' encoding='windows-1252'?>" + page("<p>café “q” €&hellip;</p>")
        XCTAssertEqual(try book(try XCTUnwrap(windows.data(using: .windowsCP1252))).textSection(at: 0).text, "café “q” €…")
    }

    func testInvalidUTF8AndUndeclaredLegacyBytesAreMalformedWithOrWithoutRecovery() throws {
        let open = Data("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>caf".utf8)
        let close = Data("</p></body></html>".utf8)
        for (declaration, bytes) in [("", [UInt8]([0xE9])), ("<?xml version='1.0' encoding='UTF-8'?>", [0xE9]), ("", [0xC3, 0x28]), ("", [0xF0, 0x9F, 0x98])] {
            let publication = try book(Data(declaration.utf8) + open + Data(bytes) + close)
            assertMalformed(publication, "\(bytes)")
            assertMalformed(publication, recovering: true, "\(bytes)")
        }
    }

    // Converted books often keep an HTML charset declaration that no longer matches their bytes.
    func testAConflictingHTMLMetaCharsetNeverRedecodesUTF8Text() throws {
        let head = "<meta http-equiv='Content-Type' content='text/html; charset=ISO-8859-1'/><meta charset='windows-1252'/><title>Té</title>"
        let strict = try book(page("<p>café x</p>", head: head)).textSection(at: 0)
        XCTAssertEqual(strict.text, "café x")
        XCTAssertEqual(strict.title, "Té")
        let recovered = try book(page("<p>café</b> x</p>", head: head)).textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(recovered.recoveredAsHTML)
        XCTAssertEqual(recovered.text, "café x")
        XCTAssertEqual(recovered.title, "Té")
    }

    func testEmptyTruncatedAndBinarySectionFilesFailAsMalformedContent() throws {
        for bytes in [[UInt8](), [0x3C], [0x00, 0x00, 0x00], Array("  \n".utf8), [0xFF, 0xFE], [0xFE, 0xFF, 0x00], [0xEF, 0xBB, 0xBF],
                      [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46], [0x00, 0x00, 0xFE, 0xFF], [0x3C, 0x00]] {
            let publication = try book(Data(bytes))
            assertMalformed(publication, "\(bytes)")
            assertMalformed(publication, recovering: true, "\(bytes)")
        }
    }

    // MARK: Spine handling

    func testNonXHTMLSpineItemsFailWithTheirMediaTypeEvenWhenRecoveryIsRequested() throws {
        let opf = String(decoding: try XCTUnwrap(Self.files["OPS/book.opf"]), as: UTF8.self)
        for type in ["image/svg+xml", "image/jpeg", "text/html", "application/x-dtbook+xml", ""] {
            var files = Self.files
            files["OPS/book.opf"] = Data(opf.replacingOccurrences(of: "href=\"one.xhtml\" media-type=\"application/xhtml+xml\"",
                with: "href=\"one.xhtml\" media-type=\"\(type)\"").utf8)
            let publication = try EPUBPublication.open(data: Fixture.archive(files))
            XCTAssertEqual(publication.spine[0].resource.mediaType, type)
            for recovering in [false, true] {
                XCTAssertThrowsError(try publication.textSection(at: 0, recoversMalformedMarkup: recovering), type) {
                    XCTAssertEqual($0 as? EPUBTextExtractionError, .unsupportedMediaType(type))
                }
            }
            XCTAssertEqual(try publication.textSection(at: 1).title, "Second Chapter")
        }
    }

    func testWholeBookIterationReportsEmptyNonlinearAndRepeatedSectionsInSpineOrder() throws {
        var files = Self.files
        files["OPS/book.opf"] = Data("""
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
        <dc:title>Spine</dc:title><dc:language>en</dc:language><dc:identifier id="uid">spine-coverage</dc:identifier></metadata><manifest>\
        <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>\
        <item id="blank" href="blank.xhtml" media-type="application/xhtml+xml"/>\
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="one"/>\
        <itemref idref="blank" linear="no"/><itemref idref="one"/><itemref idref="nav" linear="no"/><itemref idref="two"/></spine></package>
        """.utf8)
        files["OPS/blank.xhtml"] = Data("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Blank</title></head><body><div><p> </p></div></body></html>".utf8)
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        let sections = try publication.spine.indices.map { try publication.textSection(at: $0) }
        XCTAssertEqual(sections.map(\.spineIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(sections.map(\.isLinear), [true, false, true, false, true])
        XCTAssertEqual(sections.map(\.resource.path), ["OPS/one.xhtml", "OPS/blank.xhtml", "OPS/one.xhtml", "OPS/nav.xhtml", "OPS/two.xhtml"])
        XCTAssertEqual(sections.map(\.title), ["First Chapter", "Blank", "First Chapter", "Contents", "Second Chapter"])
        XCTAssertEqual(sections[1].text, "")
        XCTAssertEqual(sections[0].text, sections[2].text)
        XCTAssertEqual(sections[0].anchors, sections[2].anchors)
        XCTAssertEqual(sections[3].text, "First Chapter\nSecond Chapter")
        XCTAssertEqual(sections[3].semanticTypes, ["toc"])
    }

    // MARK: Limits

    func testASectionAtExactlyTheInputLimitIsReadAndOneByteLessIsRefused() throws {
        let xml = page("<p>é</p>")
        let publication = try book(xml)
        var limits = EPUBTextExtractionLimits()
        limits.inputBytes = xml.utf8.count
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits).text, "é")
        limits.inputBytes -= 1
        assertLimit("inputBytes", publication, limits)
        assertLimit("inputBytes", publication, limits, recovering: true)
    }

    func testDepthAndElementLimitsAdmitExactlyTheirBound() throws {
        // html > body > div > p > b is five levels; html, head, title, body, div, p and b are seven elements.
        let publication = try book("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><div><p><b>x</b></p></div></body></html>")
        var limits = EPUBTextExtractionLimits()
        limits.depth = 5
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits).text, "x")
        limits.depth = 4
        assertLimit("depth", publication, limits)
        limits = EPUBTextExtractionLimits()
        limits.elementCount = 7
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits).text, "x")
        limits.elementCount = 6
        assertLimit("elementCount", publication, limits)
    }

    // "UTF-8 bytes per output field": the title is bounded like the text.
    func testTheOutputLimitAppliesToTheTitleFieldAsWell() throws {
        let publication = try book(page("<p>x</p>", head: "<title>" + String(repeating: "é", count: 10) + "</title>"))
        var limits = EPUBTextExtractionLimits()
        limits.outputBytes = 20
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits).title, String(repeating: "é", count: 10))
        limits.outputBytes = 19
        assertLimit("outputBytes", publication, limits)
    }

    func testNonPositiveLimitsAreRefusedAsExtractionLimits() throws {
        let publication = try book(page("<p>x</p>"))
        for key in [\EPUBTextExtractionLimits.inputBytes, \.outputBytes, \.depth, \.elementCount] {
            for value in [0, -1, Int.min] {
                var limits = EPUBTextExtractionLimits()
                limits[keyPath: key] = value
                assertLimit("extraction limits", publication, limits)
                assertLimit("extraction limits", publication, limits, recovering: true)
            }
            var limits = EPUBTextExtractionLimits()
            limits[keyPath: key] = Int.max
            XCTAssertEqual(try publication.textSection(at: 0, limits: limits).text, "x")
        }
    }

    func testDefaultElementAndDepthLimitsHoldAtTheirDocumentedBounds() throws {
        // html, head, title, body and one paragraph, then 99,995 empty inline elements: 100,000 in all.
        func elements(_ extra: Int) -> String { page(String(repeating: "<i/>", count: extra) + "<p>end</p>") }
        XCTAssertEqual(try book(elements(100_000 - 5)).textSection(at: 0).text, "end")
        assertLimit("elementCount", try book(elements(100_000 - 4)), EPUBTextExtractionLimits())
        // html and body, then 62 nested divs: 64 levels.
        func nested(_ count: Int) -> String {
            page(String(repeating: "<div>", count: count) + "deep" + String(repeating: "</div>", count: count))
        }
        XCTAssertEqual(try book(nested(62)).textSection(at: 0).text, "deep")
        assertLimit("depth", try book(nested(63)), EPUBTextExtractionLimits())
    }

    func testASectionAtTheDefaultInputLimitExtractsCompletelyAndOneByteOverIsRefused() throws {
        let limit = EPUBTextExtractionLimits().inputBytes
        let open = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Big</title></head><body><p id='first'>"
        let close = "</p><p id='last'>end</p></body></html>"
        let unit = "word wörd 字 "
        var prose = String(repeating: unit, count: (limit - open.utf8.count - close.utf8.count) / unit.utf8.count)
        prose += String(repeating: "x", count: limit - open.utf8.count - close.utf8.count - prose.utf8.count)
        let xml = open + prose + close
        XCTAssertEqual(xml.utf8.count, limit)
        let section = try book(xml).textSection(at: 0)
        let expected = prose.trimmingCharacters(in: .whitespaces) + "\nend"
        XCTAssertTrue(section.text == expected, "\(section.text.utf8.count) bytes extracted, \(expected.utf8.count) expected")
        XCTAssertEqual(section.anchors, ["first": EPUBTextMark(offset: 0, separator: 0),
                                         "last": EPUBTextMark(offset: expected.utf8.count - 3, separator: 1)])
        assertLimit("inputBytes", try book(xml + "\n"), EPUBTextExtractionLimits())
    }

    // doc/text-extraction.md distinguishes "malformed XHTML and exceeded limits", and promises of
    // the same parser cap under recovery that it "returns limitExceeded("depth") ... even with a
    // larger caller limit". A well-formed document is not malformed XHTML on either path.
    func testAWellFormedDocumentDeeperThanTheParserCapReportsTheDepthLimit() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/91")
        func nested(_ count: Int) -> String {
            page(String(repeating: "<div>", count: count) + "deep" + String(repeating: "</div>", count: count))
        }
        var limits = EPUBTextExtractionLimits()
        limits.depth = 400
        // html, body and 253 divs are 255 levels, which the parser admits.
        XCTAssertEqual(try book(nested(253)).textSection(at: 0, limits: limits).text, "deep")
        let deep = try book(nested(300))
        assertLimit("depth", deep, limits, recovering: true)
        assertLimit("depth", deep, limits)
    }
}
