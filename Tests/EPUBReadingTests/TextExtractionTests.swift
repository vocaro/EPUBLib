import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest

final class TextExtractionTests: XCTestCase {
    private func book(_ body: String, head: String = "<title>Chapter title</title>") throws -> EPUBPublication {
        try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml":
            "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head>\(head)</head><body>\(body)</body></html>"]))
    }

    func testSpineOrderResourceIdentityAndTitles() throws {
        let bytes = try Fixture.epub()
        let publication = try EPUBPublication.open(data: bytes)
        let sections = try publication.spine.indices.map { try publication.textSection(at: $0) }
        XCTAssertEqual(sections.map(\.spineIndex), [0, 1])
        XCTAssertEqual(sections.map(\.title), ["First Chapter", "Second Chapter"])
        XCTAssertEqual(sections.map(\.resource), publication.spine.map(\.resource))
        XCTAssertTrue(sections[0].text.contains("Opening words are visible."))
        XCTAssertEqual(publication.archiveData, bytes)
    }

    // Ported from StudyWright's extraction regressions: metadata must not leak into prose,
    // including a head/title that differs from the body's visible heading.
    func testHeadTitleScriptStyleAndTemplateNeverBecomeBodyText() throws {
        let publication = try book("<h1>Visible heading</h1><p>Read me.</p><script>bad script</script><style>bad style</style><template>bad template</template>",
            head: "<title>Metadata only</title><style>bad head style</style>")
        let section = try publication.textSection(at: 0)
        XCTAssertEqual(section.title, "Metadata only")
        XCTAssertEqual(section.text, "Visible heading\nRead me.")
    }

    func testEmbeddedSVGScriptAndStyleAreNotText() throws {
        let section = try book("<svg xmlns='http://www.w3.org/2000/svg'><script>bad script</script><style>bad style</style><text>Diagram label</text></svg>").textSection(at: 0)
        XCTAssertEqual(section.text, "Diagram label")
    }

    func testInlineMarkupEntitiesCDATAAndWordJoiners() throws {
        let section = try book("<p>un<em>break</em>able &amp; &#8217; m\u{FEFF}— A<![CDATA[<B>]]>C &#xfeff;</p>").textSection(at: 0)
        XCTAssertEqual(section.text, "unbreakable & ’ m\u{FEFF}— A<B>C \u{FEFF}")
    }

    func testBlocksLineBreaksAndWhitespaceDoNotGlueWords() throws {
        let section = try book("<h2>Heading</h2><div>  First\n  line<br/>Second line</div><ul><li>One</li><li>Two</li></ul><table><tr><td>A</td><td>B</td></tr></table>").textSection(at: 0)
        XCTAssertEqual(section.text, "Heading\nFirst line\nSecond line\nOne\nTwo\nA\nB")
    }

    func testSemanticRolesAreReportedWithoutFilteringOrFilenameHeuristics() throws {
        for role in ["chapter", "colophon", "copyright-page", "titlepage", "halftitlepage", "imprint", "endnotes", "custom:role"] {
            let section = try book("<section epub:type='backmatter \(role)'><p>Retained text</p></section>").textSection(at: 0)
            XCTAssertEqual(section.semanticTypes, ["backmatter", role])
            XCTAssertEqual(section.text, "Retained text")
        }
        let section = try book("<p>A chapter about copyright and colophons.</p>").textSection(at: 0)
        XCTAssertTrue(section.semanticTypes.isEmpty)
    }

    func testSemanticNamespaceAliasesWhitespaceAndRebinding() throws {
        let section = try book("""
        <section xmlns:e='http://www.idpf.org/2007/ops' e:type='chapter&#x9;bodymatter'>
          <p xmlns:epub='urn:unrelated' epub:type='colophon'>Text</p>
          <aside e:type='footnote'>Note</aside>
        </section>
        """).textSection(at: 0)
        XCTAssertEqual(section.semanticTypes, ["chapter", "bodymatter", "footnote"])
    }

    func testEmptyImageOnlySectionsAndAbsentTitlesArePreserved() throws {
        let section = try book("<img src='image.png' alt='Not OCR'/>", head: "<title> \n </title>").textSection(at: 0)
        XCTAssertNil(section.title)
        XCTAssertEqual(section.text, "")
        XCTAssertNil(try book("<p>Text</p>", head: "").textSection(at: 0).title)
    }

    func testNonlinearAndRepeatedResourcesRetainTheirSpineOccurrence() throws {
        let original = try EPUBPublication.open(data: Fixture.epub())
        let opf = String(decoding: try original.data(at: "OPS/book.opf"), as: UTF8.self)
            .replacingOccurrences(of: "<itemref idref=\"two\"/>", with: "<itemref idref=\"one\" linear=\"no\"/>")
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": opf]))
        let first = try publication.textSection(at: 0), second = try publication.textSection(at: 1)
        XCTAssertTrue(first.isLinear)
        XCTAssertFalse(second.isLinear)
        XCTAssertEqual(first.resource, second.resource)
        XCTAssertNotEqual(first.spineIndex, second.spineIndex)
        XCTAssertEqual(first.text, second.text)
    }

    func testEncodedResourceReferenceRemainsNavigable() throws {
        let original = try EPUBPublication.open(data: Fixture.epub())
        let opf = String(decoding: try original.data(at: "OPS/book.opf"), as: UTF8.self)
            .replacingOccurrences(of: "one.xhtml", with: "chapter%23one.xhtml")
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": opf,
            "OPS/chapter#one.xhtml": "<html><body><p>Text</p></body></html>"]))
        XCTAssertEqual(try publication.textSection(at: 0).resource.href, "OPS/chapter%23one.xhtml")
    }

    func testMalformedOrEntityBearingXHTMLFailsWithoutARegexFallback() throws {
        for xml in ["<html><body><script>leak", "<html><body><p>unescaped & entity</p></body></html>",
            "<!DOCTYPE html [<!ENTITY x 'expanded'>]><html><body>&x;</body></html>",
            "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><html><body>&x;</body></html>",
            "<html><head><title>No body</title></head></html>"] {
            let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xml]))
            XCTAssertThrowsError(try publication.textSection(at: 0)) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent("OPS/one.xhtml"))
            }
        }
    }

    func testUTF16AndOrdinaryExternalDoctype() throws {
        var files = try Fixture.files()
        let xml = "<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE html SYSTEM 'https://example.invalid/never-fetch'><html><head><title>Encoded</title></head><body><p>Café [one]</p></body></html>"
        files["OPS/one.xhtml"] = try XCTUnwrap(xml.data(using: .utf16))
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(try publication.textSection(at: 0).text, "Café [one]")
        files["OPS/one.xhtml"] = try XCTUnwrap("<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE html [<!ENTITY x 'unsafe'>]><html><body>&x;</body></html>".data(using: .utf16))
        let unsafe = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertThrowsError(try unsafe.textSection(at: 0))
    }

    func testInputOutputDepthAndElementLimits() throws {
        let publication = try book("<p>éééé</p>", head: "")
        for key in [\EPUBTextExtractionLimits.inputBytes, \.outputBytes, \.depth, \.elementCount] {
            var limits = EPUBTextExtractionLimits()
            limits[keyPath: key] = 1
            XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
                guard case .limitExceeded = $0 as? EPUBTextExtractionError else { return XCTFail("\($0)") }
            }
            limits[keyPath: key] = 0
            XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits))
        }
        var exact = EPUBTextExtractionLimits(); exact.outputBytes = 8
        XCTAssertEqual(try publication.textSection(at: 0, limits: exact).text, "éééé")
        exact.outputBytes = 7
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: exact))
    }

    func testInvalidIndicesAndUnsupportedSpineMediaFailExplicitly() throws {
        let publication = try book("<p>Text</p>")
        for index in [-1, publication.spine.count] {
            XCTAssertThrowsError(try publication.textSection(at: index)) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .invalidSpineIndex(index))
            }
        }
        let opf = String(decoding: try publication.data(at: "OPS/book.opf"), as: UTF8.self)
            .replacingOccurrences(of: "href=\"one.xhtml\" media-type=\"application/xhtml+xml\"", with: "href=\"one.xhtml\" media-type=\"image/svg+xml\"")
        let unsupported = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": opf]))
        XCTAssertThrowsError(try unsupported.textSection(at: 0)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .unsupportedMediaType("image/svg+xml"))
        }
    }

    func testCancellationPropagates() async throws {
        let publication = try book("<p>Text</p>")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try publication.textSection(at: 0)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} // Never converted to malformedContent.
    }
}
