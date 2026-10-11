import CryptoKit
import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import Foundation
import XCTest

/// Issue #43: author-published XHTML with HTML named references, missing attribute values and
/// mismatched tags. Fixtures reproduce each defect pattern; no publisher text is included.
final class MalformedContentExtractionTests: XCTestCase {
    private let path = "OPS/one.xhtml"
    private let xhtml11 = #"<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">"#

    private func book(_ xml: String) throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.epub(overrides: [path: xml]))
    }
    private func book(_ data: Data) throws -> EPUBPublication {
        var files = try Fixture.files()
        files[path] = data
        return try EPUBPublication.open(data: Fixture.archive(files))
    }
    private func page(_ body: String, head: String = "<title>T</title>") -> String {
        "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head>\(head)</head><body>\(body)</body></html>"
    }
    private func assertMalformed(_ publication: EPUBPublication, recovering: Bool = false,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try publication.textSection(at: 0, recoversMalformedMarkup: recovering), file: file, line: line) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), file: file, line: line)
        }
    }

    // MARK: Named character references (default behavior)

    func testXHTMLNamedReferencesDecodeWithoutLoadingTheDTD() throws {
        let named = try book(xhtml11 + page("<p id='a'>A&nbsp;B&mdash;C</p><h2 id='h'>Caf&eacute; <img alt='&eacute;t&eacute;'/></h2>",
            head: "<title>Caf&eacute;&nbsp;title</title>")).textSection(at: 0)
        XCTAssertEqual(named.text, "A B—C\nCafé été")
        XCTAssertEqual(named.title, "Café title")
        XCTAssertEqual(named.anchors["a"], EPUBTextMark(offset: 0, separator: 0))
        XCTAssertEqual(named.anchors["h"], EPUBTextMark(offset: 8, separator: 1))
        XCTAssertEqual(named.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 8, separator: 1), text: "Café été")])
        XCTAssertFalse(named.recoveredAsHTML)
        // Exactly the section a numeric reference produces; the DOCTYPE is irrelevant.
        let numeric = try book(page("<p id='a'>A&#160;B&#8212;C</p><h2 id='h'>Caf&#233; <img alt='&#233;t&#233;'/></h2>",
            head: "<title>Caf&#233;&#160;title</title>")).textSection(at: 0)
        XCTAssertEqual(named, numeric)
    }

    func testExistingTwoLabelMethodRemainsAFunctionValue() throws {
        let publication = try book(xhtml11 + page("<p>A&nbsp;B&mdash;C</p>"))
        let extract: (Int, EPUBTextExtractionLimits) throws -> EPUBTextSection = publication.textSection(at:limits:)
        let section = try extract(0, EPUBTextExtractionLimits())
        XCTAssertEqual(section.text, "A B—C")
        XCTAssertEqual(try publication.textSection(at: 0), section)
        XCTAssertEqual(try publication.textSection(at: 0, recoversMalformedMarkup: false), section)
        let malformed = try book(xhtml11 + page("<p>A&nbsp;B</b></p>"))
        let strict: (Int, EPUBTextExtractionLimits) throws -> EPUBTextSection = malformed.textSection(at:limits:)
        XCTAssertThrowsError(try strict(0, EPUBTextExtractionLimits())) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path))
        }
    }

    func testNamedReferenceTranslationLeavesCDATACommentsAndEscapesLiteral() throws {
        let section = try book(xhtml11 + page("<p>A<![CDATA[&nbsp;]]>B<!-- &bogus; --> &amp;nbsp; &lt;&times;&gt;</p>")).textSection(at: 0)
        XCTAssertEqual(section.text, "A&nbsp;B &nbsp; <×>")
    }

    func testNamedReferencesInMathMLKeepStructuralNotation() throws {
        let section = try book(xhtml11 + page("<p>x&nbsp;<math xmlns='http://www.w3.org/1998/Math/MathML'><mi>a</mi><mo>&times;</mo><mi>b</mi></math></p>"))
            .textSection(at: 0)
        XCTAssertEqual(section.text, #"x math("a", "×", "b")"#)
    }

    func testUTF16NamedReferencesAreTranslatedInTheirOwnEncoding() throws {
        let xml = "<?xml version='1.0' encoding='UTF-16'?>" + xhtml11
            + page("<p>A&nbsp;&mdash;&nbsp;B</p>", head: "<title>Caf&eacute;</title>")
        for encoding in [String.Encoding.utf16, .utf16BigEndian, .utf16LittleEndian] {
            let section = try book(try XCTUnwrap(xml.data(using: encoding))).textSection(at: 0)
            XCTAssertEqual(section.text, "A — B")
            XCTAssertEqual(section.title, "Café")
            XCTAssertFalse(section.recoveredAsHTML)
        }
    }

    func testUnknownNamedReferenceIsATypedRejectionUnlessRecoveryIsRequested() throws {
        let publication = try book(xhtml11 + page("<p>Known&nbsp;and &bogus; names</p>"))
        assertMalformed(publication)
        let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(section.text, "Known and &bogus; names")
        XCTAssertTrue(section.recoveredAsHTML)
    }

    // MARK: Opt-in HTML recovery

    func testMismatchedListAndHeadingTagsRecoverTextOrderIDsAndHeadings() throws {
        let publication = try book("<?xml version='1.0' encoding='utf-8'?><!DOCTYPE html>" + page(
            "<section id='s' epub:type='chapter'><h1>Title</h1><h2 id='s:intro'><ol type='1'><li>Introduction</h2><p>Hundreds of groups.</p></section>",
            head: "<title>Teaching &amp; Tech</title>"))
        assertMalformed(publication)
        let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(section.recoveredAsHTML)
        XCTAssertEqual(section.title, "Teaching & Tech")
        XCTAssertEqual(section.text, "Title\nIntroduction\nHundreds of groups.")
        XCTAssertEqual(section.semanticTypes, ["chapter"])
        XCTAssertEqual(section.anchors, ["s": EPUBTextMark(offset: 0, separator: 0), "s:intro": EPUBTextMark(offset: 6, separator: 1)])
        XCTAssertEqual(section.headings, [EPUBTextHeading(mark: EPUBTextMark(offset: 0, separator: 0), text: "Title"),
                                          EPUBTextHeading(mark: EPUBTextMark(offset: 6, separator: 1), text: "Introduction")])
        XCTAssertEqual(section.resource, publication.spine[0].resource)
        XCTAssertEqual(section.spineIndex, 0)
    }

    func testMissingAndBooleanAttributeValuesRecover() throws {
        let publication = try book(page("<p>Before</p><iframe name='x' frameborder='0' allowfullscreen\"true\" webkitallowfullscreen='true' src=''></iframe><video controls><source src='v.mp4'/></video><p>After</p>"))
        assertMalformed(publication)
        let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(section.text, "Before\nAfter")
        XCTAssertTrue(section.recoveredAsHTML)
    }

    func testRecoveredUTF8OffsetsUnclosedParagraphsAndVoidElements() throws {
        let section = try book(page("<h1 id='t'>Café</h1><p id='p'>naïve<br>text<p>next", head: ""))
            .textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(section.text, "Café\nnaïve\ntext\nnext")
        XCTAssertNil(section.title)
        XCTAssertEqual(section.anchors["t"], EPUBTextMark(offset: 0, separator: 0))
        XCTAssertEqual(section.anchors["p"], EPUBTextMark(offset: 6, separator: 1))
        XCTAssertEqual(section.headings.map(\.text), ["Café"])
    }

    func testRecoveryExcludesScriptStyleTemplateAndRetainsHiddenProse() throws {
        let publication = try book(page("<p hidden='hidden'>Hidden retained</p><script>if (a < b && c) leak()</script><style>p{}</style><template><p>tmpl</p></template><p>Visible & bare &nbsp;x</p>"))
        assertMalformed(publication)
        XCTAssertEqual(try publication.textSection(at: 0, recoversMalformedMarkup: true).text, "Hidden retained\nVisible & bare x")
        // An unterminated script is never turned into prose.
        let truncated = try book("<html><body><p>Kept</p><script>leak")
        assertMalformed(truncated)
        XCTAssertEqual(try truncated.textSection(at: 0, recoversMalformedMarkup: true).text, "Kept")
    }

    func testRecoveredMathMLMatchesStrictStructuralNotation() throws {
        let strict = try book(page("<p>x <math xmlns='http://www.w3.org/1998/Math/MathML'><mfrac><mi>a</mi><mi>b</mi></mfrac></math> &amp; y</p><p>z <math xmlns='http://www.w3.org/1998/Math/MathML'><msup><mi>x</mi><mn>2</mn></msup></math><br/></p>"))
            .textSection(at: 0)
        XCTAssertEqual(strict.text, #"x math(frac("a", "b")) & y"# + "\n" + #"z math(sup("x", "2"))"#)
        // Same formulas around a malformed tag; HTML's undeclared <math> is still MathML.
        let recovered = try book(page("<p>x <math xmlns='http://www.w3.org/1998/Math/MathML'><mfrac><mi>a</mi><mi>b</mi></mfrac></math> &amp; y</p><p>z <math><msup><mi>x</mi><mn>2</mn></msup></math><br></p>"))
            .textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(recovered.recoveredAsHTML)
        XCTAssertEqual(recovered.text, strict.text)
    }

    func testRecoveryDecodesUTF16AndRejectsUndeclaredLegacyEncodings() throws {
        let xml = "<?xml version='1.0' encoding='UTF-16'?>" + page("<p>Caf&eacute; <b>bold</p>", head: "<title>Caf&eacute;</title>")
        for encoding in [String.Encoding.utf16, .utf16BigEndian, .utf16LittleEndian] {
            let publication = try book(try XCTUnwrap(xml.data(using: encoding)))
            assertMalformed(publication)
            let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
            XCTAssertEqual(section.text, "Café bold")
            XCTAssertEqual(section.title, "Café")
        }
        // A declared legacy encoding remains supported by the strict XML parser...
        let latin1 = "<?xml version='1.0' encoding='ISO-8859-1'?>" + page("<p>café</p>")
        XCTAssertEqual(try book(try XCTUnwrap(latin1.data(using: .isoLatin1))).textSection(at: 0, recoversMalformedMarkup: true).text, "café")
        // ...but recovery never guesses at bytes that are not UTF-8 or UTF-16/32.
        let broken = "<?xml version='1.0' encoding='ISO-8859-1'?>" + page("<p>café</b></p>")
        assertMalformed(try book(try XCTUnwrap(broken.data(using: .isoLatin1))), recovering: true)
    }

    func testRecoveryNeverAdmitsDeclarationsOrExternalEntities() throws {
        for xml in [
            "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><html><body><p>&x;</p><p a\"b\"></body></html>",
            "<!DOCTYPE html [<!ENTITY x SYSTEM 'https://example.invalid/never-fetch'>]><html><body><p>&x;</b></body></html>",
            "<!DOCTYPE html [<!ENTITY nbsp 'INJECTED'>]><html><body><p>&nbsp;</b></body></html>",
            "<!ENTITY x 'loose'><html><body><p>&x;</b></body></html>",
        ] {
            assertMalformed(try book(xml), recovering: true)
        }
        let utf16 = "<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE html [<!ENTITY x 'unsafe'>]><html><body><p>&x;</b></body></html>"
        assertMalformed(try book(try XCTUnwrap(utf16.data(using: .utf16))), recovering: true)
    }

    func testStrayQuoteThatDefeatsTheXMLDeclarationScanRecovers() throws {
        // A quote opening no value (`=text/x-python"`) desynchronizes XML quote tracking, so the
        // strict preflight refuses the bytes before any parser runs.
        let publication = try book(page("<div class='task' data-language=text/x-python\"><p class='c'>Prose &amp; code</p></div><p>Tail</p>"))
        assertMalformed(publication)
        let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(section.recoveredAsHTML)
        XCTAssertEqual(section.text, "Prose & code\nTail")
    }

    func testRecoveryRefusesDeclarationsHiddenAfterAStrayQuote() throws {
        for xml in [
            "<html><body><div lang=x\"><p>t</p></div><!DOCTYPE html [<!ENTITY x 'y'>]><p>&x;</p></body></html>",
            "<html><body><div lang=x\"><p>t</p></div><!ENTITY x SYSTEM 'file:///etc/passwd'><p>&x;</p></body></html>",
            "<html><body><div lang=x\"><p>t</p></div><!entity x 'lower'><p>&x;</p></body></html>",
            "<html><body><div lang=x\"><p>t</p></div><!ATTLIST p hidden CDATA 'x'></body></html>",
            "<!doctype html [ ]><html><body><div lang=x\"><p>t</p></div></body></html>",
            "<html><body><div lang=x\"><p>t</p></div><!DOCTYPE html \"x>\" [<!-- <!ELEMENT p ANY> -->]></body></html>",
            // A quoted '>' does not end the DOCTYPE; its empty internal subset is still refused.
            "<!DOCTYPE html SYSTEM 'unused>identifier' []><html><body><p>t</b></p></body></html>",
            "<!DOCTYPE html SYSTEM 'unused>identifier' [ ]><html><body><div lang=x\"><p>t</p></div></body></html>",
            "<!DOCTYPE html SYSTEM 'unterminated><html><body><p>t</b></p></body></html>",
            // Even inert-looking examples in comments are refused on the recovery path.
            "<html><body><div lang=x\"><p>t</p><!-- <!ENTITY example 'text'> --></div></body></html>",
        ] {
            assertMalformed(try book(xml), recovering: true)
        }
        // Declarations inside CDATA are escaped character data, not markup.
        let quoted = try book(page("<div lang=x\"><p>Example: <![CDATA[<!ENTITY x 'y'>]]></p></div>"))
            .textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(quoted.text, "Example: <!ENTITY x 'y'>")
    }

    func testRecoveredCDATAMatchesStrictCharacterData() throws {
        let content = "<p id='a'>A <![CDATA[x < y && z > w; <script>not code</script> &amp;]]> B</p><p>z <math xmlns='http://www.w3.org/1998/Math/MathML'><mi><![CDATA[a<b&c]]></mi></math></p><!-- <![CDATA[ hidden ]]> --><p>end</p>"
        let strict = try book(page(content)).textSection(at: 0)
        XCTAssertEqual(strict.text, "A x < y && z > w; <script>not code</script> &amp; B\n" + #"z math("a<b&c")"# + "\nend")
        // The same character data after a malformed tag.
        let recovered = try book(page("<p hidden\"x\"></p>" + content)).textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertTrue(recovered.recoveredAsHTML)
        XCTAssertEqual(recovered.text, strict.text)
        XCTAssertEqual(recovered.anchors["a"], strict.anchors["a"])
    }

    func testCDATAMarkersInQuotedAttributesRemainAuthoredAlternatives() throws {
        // XML forbids '<' in attribute values, so only the recovery path can see these.
        let publication = try book(page("<p hidden\"x\">a</p><p><img alt='<![CDATA[A & B]]>'/> <math xmlns='http://www.w3.org/1998/Math/MathML' alttext=\"<![CDATA[x<y]]>\"><mi>x</mi></math> <![CDATA[c<d]]></p>"))
        assertMalformed(publication)
        let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(section.text, "a\n<![CDATA[A & B]]> <![CDATA[x<y]]> c<d")
    }

    func testScriptRawTextIsCopiedAndSelfClosingScriptsEndImmediately() throws {
        let strict = try book(page("<script>//<![CDATA[\nif (a<b) {}\n//]]></script><p><![CDATA[x<y]]></p><script/><p><![CDATA[p&q]]></p>")).textSection(at: 0)
        XCTAssertEqual(strict.text, "x<y\np&q")
        let recovered = try book(page("<p hidden\"x\"></p><SCRIPT>//<![CDATA[\nif (a<b) {}\n//]]></SCRIPT><p><![CDATA[x<y]]></p><script/><p><![CDATA[p&q]]></p>"))
            .textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(recovered.text, strict.text)
    }

    func testUnterminatedCDATAIsRefusedRatherThanExposingTheRest() throws {
        let publication = try book(page("<p>Kept</b><![CDATA[ unterminated <script>leak()</script></p>"))
        assertMalformed(publication)
        assertMalformed(publication, recovering: true)
    }

    func testRecoveryNeverReturnsAParserTruncatedTree() throws {
        // libxml2 stops building the tree past 256 levels; a deeper caller limit cannot admit it.
        func nested(_ count: Int) throws -> EPUBPublication {
            try book(page("<p hidden\"x\">a</p>" + String(repeating: "<div>", count: count) + "deep"
                + String(repeating: "</div>", count: count) + "<p>tail</p>", head: ""))
        }
        var limits = EPUBTextExtractionLimits(); limits.depth = 400
        let deep = try nested(300)
        assertMalformed(deep)
        XCTAssertThrowsError(try deep.textSection(at: 0, limits: limits, recoversMalformedMarkup: true)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("depth"))
        }
        XCTAssertThrowsError(try deep.textSection(at: 0, recoversMalformedMarkup: true)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("depth"))
        }
        // Below libxml2's cap, deep recovery is complete when the caller allows it.
        XCTAssertEqual(try nested(250).textSection(at: 0, limits: limits, recoversMalformedMarkup: true).text, "a\ndeep\ntail")
    }

    func testRecoveryDoesNotRepairWellFormedStructuralRejections() throws {
        // Well-formed but bodiless: a structural defect, not a parser verdict.
        assertMalformed(try book("<html><head><title>No body</title></head></html>"), recovering: true)
        // Malformed and still bodiless after recovery.
        assertMalformed(try book("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>x</head></html>"), recovering: true)
    }

    func testRecoveryEnforcesDepthElementAndOutputLimits() throws {
        // The defect precedes all content, so only the recovery walk can reach each limit.
        let publication = try book(page("<p hidden\"x\">é</p><div><div><div><p>deep</p></div></div></div>", head: ""))
        assertMalformed(publication)
        XCTAssertEqual(try publication.textSection(at: 0, recoversMalformedMarkup: true).text, "é\ndeep")
        let cases: [(WritableKeyPath<EPUBTextExtractionLimits, Int>, Int, Int, String)] = [
            (\.depth, 5, 6, "depth"), (\.elementCount, 7, 8, "elementCount"), (\.outputBytes, 6, 7, "outputBytes")]
        for (key, failing, passing, name) in cases {
            var limits = EPUBTextExtractionLimits()
            limits[keyPath: key] = failing
            XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits, recoversMalformedMarkup: true)) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded(name))
            }
            limits[keyPath: key] = passing
            XCTAssertEqual(try publication.textSection(at: 0, limits: limits, recoversMalformedMarkup: true).text, "é\ndeep")
        }
        var input = EPUBTextExtractionLimits(); input.inputBytes = 8
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: input, recoversMalformedMarkup: true)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("inputBytes"))
        }
    }

    func testRecoveryIsIgnoredForWellFormedDocuments() throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        for index in publication.spine.indices {
            let strict = try publication.textSection(at: index)
            XCTAssertFalse(strict.recoveredAsHTML)
            XCTAssertEqual(try publication.textSection(at: index, recoversMalformedMarkup: true), strict)
        }
    }

    func testCancellationIsNotConvertedToRecoveryOrMalformedContent() async throws {
        let publication = try book(page("<p>broken</b>"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try publication.textSection(at: 0, recoversMalformedMarkup: true)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    // MARK: Exact originals (opt-in)

    /// Exact author-published originals from issue #43. Real books are not part of the repository;
    /// set `EPUBLIB_ISSUE43_CORPUS` to a directory containing these unchanged files.
    private static let originals: [(file: String, bytes: Int, sha256: String, spine: Int, malformed: [String])] = [
        ("casebook.epub", 1_768_727, "a4bfaf0fa5e820f84bc53510fc9310f9c1adfaa07ed3179271a3756bd386a816", 63, []),
        ("cnp3-2021.epub", 27_915_740, "87fa4ba202defe463cbe78905695f9f8ae29edebad7bfd3cfd47c285d734869b", 50,
         ["principles/reliability.xhtml", "principles/network.xhtml", "exercises/sockets.xhtml", "exercises/network.xhtml",
          "exercises/transport.xhtml", "exercises/dns.xhtml", "exercises/http.xhtml", "exercises/tls.xhtml",
          "exercises/trace.xhtml", "exercises/tcp.xhtml", "exercises/tcp-2.xhtml", "exercises/ipv6.xhtml",
          "exercises/routing-policies.xhtml", "exercises/lan.xhtml"]),
        ("cnp3-beta2018.epub", 7_318_319, "14af9c408b414f5659f0f46a19061f94f4e7428285ea53907ade488e9a7bc887", 40,
         ["principles/reliability.xhtml", "principles/network.xhtml", "protocols/ipv6.xhtml", "exercises/sockets.xhtml",
          "exercises/transport.xhtml", "exercises/dns.xhtml", "exercises/http.xhtml", "exercises/tls.xhtml",
          "exercises/trace.xhtml", "exercises/tcp.xhtml", "exercises/tcp-2.xhtml", "exercises/ipv6.xhtml"]),
        ("teaching-tech-together-2018.epub", 532_976, "71052d99d6fd4d984e583427253ecf509e8a7fd3ab8e2015bfb9dd62aec684b4", 2,
         ["EPUB/text/ch001.xhtml"]),
    ]

    func testOriginalIssue43Archives() throws {
        guard let directory = ProcessInfo.processInfo.environment["EPUBLIB_ISSUE43_CORPUS"] else {
            throw XCTSkip("Set EPUBLIB_ISSUE43_CORPUS to the directory of original issue #43 EPUBs")
        }
        for original in Self.originals {
            let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(original.file))
            XCTAssertEqual(data.count, original.bytes, original.file)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), original.sha256, original.file)
            let publication = try EPUBPublication.open(data: data)
            XCTAssertEqual(publication.spine.count, original.spine, original.file)
            var rejected: [String] = [], recovered: [String] = []
            var bytes = 0
            for index in publication.spine.indices {
                let path = publication.spine[index].resource.path
                var strict: EPUBTextSection?
                do { strict = try publication.textSection(at: index) }
                catch EPUBTextExtractionError.malformedContent(let failed) { XCTAssertEqual(failed, path); rejected.append(path) }
                let section = try publication.textSection(at: index, recoversMalformedMarkup: true)
                if let strict { XCTAssertEqual(section, strict, path) }
                if section.recoveredAsHTML { recovered.append(path) }
                if original.file.hasPrefix("cnp3"), path == "principles/network.xhtml" {
                    // Its stray-quote attribute defeats the XML declaration scan before parsing.
                    XCTAssertTrue(section.recoveredAsHTML)
                    XCTAssertGreaterThan(section.text.utf8.count, 50_000)
                    XCTAssertEqual(section.headings.count, 9) // Every <h1>–<h6> start tag in the source.
                }
                XCTAssertEqual(section.spineIndex, index)
                XCTAssertEqual(section.resource, publication.spine[index].resource)
                if original.file == "casebook.epub" { XCTAssertFalse(section.text.contains("&nbsp;"), path) }
                let utf8 = Array(section.text.utf8)
                for (id, mark) in section.anchors { XCTAssertLessThanOrEqual(mark.offset, utf8.count, "\(path)#\(id)") }
                for heading in section.headings {
                    guard let word = heading.text.split(separator: " ").first else { continue }
                    XCTAssertTrue(utf8[heading.mark.offset...].starts(with: word.utf8), "\(path): \(heading.text)")
                }
                bytes += utf8.count
            }
            XCTAssertEqual(rejected, recovered, original.file)
            XCTAssertEqual(Set(rejected), Set(original.malformed), original.file)
            print("\(original.file): \(publication.spine.count) spine sections; strict extracted \(publication.spine.count - rejected.count), rejected \(rejected.count); with recovery extracted \(publication.spine.count) (\(recovered.count) recovered as HTML), \(bytes) UTF-8 bytes")
        }
    }
}
