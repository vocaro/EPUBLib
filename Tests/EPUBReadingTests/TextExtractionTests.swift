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

    func testDecorativeImageOnlySectionsAndAbsentTitlesArePreserved() throws {
        let section = try book("<img src='image.png' alt=''/><img src='another.png'/>", head: "<title> \n </title>").textSection(at: 0)
        XCTAssertNil(section.title)
        XCTAssertEqual(section.text, "")
        XCTAssertNil(try book("<p>Text</p>", head: "").textSection(at: 0).title)
    }

    func testImageAlternativesPreserveFormulaTableHeadingAndExerciseOrder() throws {
        // Representative publisher XHTML, without relying on the availability of image bytes.
        let section = try book("""
        <h2>Exercises</h2>
        <p>Evaluate <img src='missing.svg' alt='p ∧ q'/> when p is true.</p>
        <table><tr><th><img src='header.png' alt='p ∨ q'/></th><th>Result</th></tr>
        <tr><td>True</td><td>False</td></tr></table>
        <ol><li><img src='formula1.png' alt='¬p'/></li><li><img src='formula2.png' alt='p → q'/></li></ol>
        """).textSection(at: 0)
        XCTAssertEqual(section.text, "Exercises\nEvaluate p ∧ q when p is true.\np ∨ q\nResult\nTrue\nFalse\n¬p\np → q")
    }

    func testImageAlternativesShareInlineWhitespaceNormalization() throws {
        let section = try book("""
        <p>f(<img src='formula.png' alt='x²'/>)=<img src='answer.png' alt='  x&#x9;+&#xA;1  '/> units.</p>
        <p>A<img alt=''/><img/><img alt='&#x9; &#xA; '/>B<img alt='C'/>D</p>
        """).textSection(at: 0)
        XCTAssertEqual(section.text, "f(x²)= x + 1 units.\nABCD")
    }

    func testPublisherMathJaxAlternativesRemainLiteralAndAppearOnce() throws {
        // Markup from Introduction to Philosophy: Logic (2020), abbreviated to the relevant
        // nodes. Preserve the publisher's LaTeX string; neither title nor rendering rewrites it.
        let section = try book(#"""
        <table class="grid aligncenter"><caption>Truth table for negation</caption><tbody><tr>
        <th scope="col"><strong><img src="assets/297a066ea90d7b8037a5e99d9505f27a.png" alt="A" title="A" class="latex mathjax" /></strong></th>
        <th scope="col"><strong><img src="assets/ff6c3c3e1e7102327509062af3d5a429.png" alt="\neg A" title="\neg A" class="latex mathjax" /></strong></th>
        </tr><tr><td>T</td><td>F</td></tr><tr><td>F</td><td>T</td></tr></tbody></table>
        <ol><li class="therefore-med"><img src="assets/b4c0918653e3ff6b7a9233ecac70db98.png" alt="/ \therefore" title="/ \therefore" class="latex mathjax" /> Alex is not a sea bream.</li></ol>
        """#).textSection(at: 0)
        XCTAssertEqual(section.text, #"Truth table for negation"# + "\nA\n" + #"\neg A"# + "\nT\nF\nF\nT\n" + #"/ \therefore Alex is not a sea bream."#)
    }

    func testImageAlternativesAreDecodedOnceAndNeverUseTitleOrForeignAttributes() throws {
        let section = try book("""
        <p><img alt='A &amp; B &lt;x&gt; &quot;q&quot; &#x3B1;' title='Duplicate title'/></p>
        <img title='Title only'/><img xmlns:a='urn:other' a:alt='Foreign attribute'/>
        <svg xmlns='http://www.w3.org/2000/svg'><img alt='Foreign element'/></svg>
        <x:img xmlns:x='http://www.w3.org/1999/xhtml' alt='Aliased XHTML'/>
        """).textSection(at: 0)
        XCTAssertEqual(section.text, "A & B <x> \"q\" α\nAliased XHTML")
    }

    func testImageAlternativesAreExcludedFromHeadAndSuppressedSubtrees() throws {
        let section = try book("""
        <p>Kept</p><script><img alt='Script alternative'/></script>
        <style><img alt='Style alternative'/></style><template><img id='hidden' alt='Template alternative'/></template>
        <p><img alt='Body alternative'/></p>
        """, head: "<title>Metadata</title><img alt='Head alternative'/>").textSection(at: 0)
        XCTAssertEqual(section.title, "Metadata")
        XCTAssertEqual(section.text, "Kept\nBody alternative")
        XCTAssertNil(section.anchors["hidden"])
    }

    func testImageAlternativesContributeToHeadingAndUTF8AnchorOffsets() throws {
        let section = try book("""
        <p>Préface</p><h2 id='heading'><img id='formula' alt='  α²  '/> law</h2>
        <p id='after'>Next <img id='inline' alt='é'/>!</p><img id='end' alt=''/>
        """).textSection(at: 0)
        let prefix = "Préface\n"
        let afterPrefix = "Préface\nα² law\n"
        XCTAssertEqual(section.text, afterPrefix + "Next é!")
        let headingMark = EPUBTextMark(offset: prefix.utf8.count, separator: 1)
        XCTAssertEqual(section.anchors["heading"], headingMark)
        XCTAssertEqual(section.anchors["formula"], headingMark)
        XCTAssertEqual(section.headings, [EPUBTextHeading(mark: headingMark, text: "α² law")])
        XCTAssertEqual(section.anchors["after"], EPUBTextMark(offset: afterPrefix.utf8.count, separator: 1))
        XCTAssertEqual(section.anchors["inline"], EPUBTextMark(offset: (afterPrefix + "Next ").utf8.count, separator: 1))
        XCTAssertEqual(section.anchors["end"], EPUBTextMark(offset: section.text.utf8.count, separator: 0))
    }

    func testImageOnlyAlternativeUsesNoTitleFallbackOrResourceAccess() throws {
        let section = try book("<img id='image' src='https://example.invalid/never-fetch' alt='  Publisher formula: x²  ' title='Do not duplicate'/>",
            head: "<title> \n </title>").textSection(at: 0)
        XCTAssertNil(section.title)
        XCTAssertEqual(section.text, "Publisher formula: x²")
        XCTAssertEqual(section.anchors["image"], EPUBTextMark(offset: 0, separator: 0))
    }

    func testImageAlternativesRespectOutputDepthAndElementLimits() throws {
        let publication = try book("<p><img alt='éééé'/></p>", head: "")
        var limits = EPUBTextExtractionLimits()
        limits.outputBytes = 8
        XCTAssertEqual(try publication.textSection(at: 0, limits: limits).text, "éééé")
        limits.outputBytes = 7
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
        limits = EPUBTextExtractionLimits()
        limits.depth = 3
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("depth"))
        }
        limits = EPUBTextExtractionLimits()
        limits.elementCount = 4
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("elementCount"))
        }
        let combined = try book("<p>A<img alt=' é '/>Z</p>", head: "")
        limits = EPUBTextExtractionLimits()
        limits.outputBytes = 6
        XCTAssertEqual(try combined.textSection(at: 0, limits: limits).text, "A é Z")
        limits.outputBytes = 5
        XCTAssertThrowsError(try combined.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
    }

    func testMalformedAndEntityBearingImageAlternativesFailSafely() throws {
        for xml in [
            "<html><body><img alt='unescaped & alternative'/></body></html>",
            "<!DOCTYPE html [<!ENTITY formula 'unsafe'>]><html><body><img alt='&formula;'/></body></html>",
            "<!DOCTYPE html [<!ENTITY formula SYSTEM 'https://example.invalid/never-fetch'>]><html><body><img alt='&formula;'/></body></html>",
        ] {
            let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": xml]))
            XCTAssertThrowsError(try publication.textSection(at: 0)) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent("OPS/one.xhtml"))
            }
        }
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
        let xml = "<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE html SYSTEM 'https://example.invalid/never-fetch'><html><head><title>Encoded</title></head><body><p>Café [one] <img alt='α &amp; β'/></p></body></html>"
        files["OPS/one.xhtml"] = try XCTUnwrap(xml.data(using: .utf16))
        let publication = try EPUBPublication.open(data: Fixture.archive(files))
        XCTAssertEqual(try publication.textSection(at: 0).text, "Café [one] α & β")
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
