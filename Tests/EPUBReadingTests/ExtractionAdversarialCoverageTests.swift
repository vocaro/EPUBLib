import EPUBCore
import EPUBReading
import EPUBText
import EPUBTestSupport
import XCTest

/// Books are untrusted: hostile or damaged section bytes must end in text or a typed error,
/// within the documented limits, never a trap or unbounded work.
final class ExtractionAdversarialCoverageTests: XCTestCase {
    private static let files: [String: Data] = (try? Fixture.files()) ?? [:]
    private let path = "OPS/one.xhtml"

    private func book(_ data: Data) throws -> EPUBPublication {
        var files = Self.files
        files[path] = data
        return try EPUBPublication.open(data: Fixture.archive(files))
    }
    private func book(_ xml: String) throws -> EPUBPublication { try book(Data(xml.utf8)) }
    private func page(_ body: String, head: String = "<title>T</title>") -> String {
        "<html xmlns='http://www.w3.org/1999/xhtml'><head>\(head)</head><body>\(body)</body></html>"
    }
    /// Extraction either returns a section whose positions lie inside its text, or throws `malformedContent`.
    private func assertReturnsOrIsMalformed(_ data: Data, recovering: Bool, _ message: @autoclosure () -> String,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let publication = try book(data)
        do {
            let section = try publication.textSection(at: 0, recoversMalformedMarkup: recovering)
            let count = section.text.utf8.count
            XCTAssertTrue(section.anchors.values.allSatisfy { (0...count).contains($0.offset) && (0...1).contains($0.separator) },
                          message(), file: file, line: line)
            XCTAssertTrue(section.headings.allSatisfy { (0...count).contains($0.mark.offset) }, message(), file: file, line: line)
        } catch let error as EPUBTextExtractionError {
            XCTAssertEqual(error, .malformedContent(path), message(), file: file, line: line)
        }
    }

    // MARK: Traps

    // CRASHES THE TEST PROCESS, so it is disabled by name (remove `disabled_` to reproduce):
    //   EPUBText/TextExtraction.swift:340: Fatal error: Unexpectedly found nil while unwrapping an Optional value
    // XML 1.0's Name production admits ":" alone. libxml2 reports the element with only a
    // recoverable namespace error, so the strict reader hands the name ":" to `start`, where
    // `name.split(separator: ":")` is empty and `parts.last!` traps. The input is otherwise
    // well-formed XHTML; any section of an untrusted book can carry it.
    func disabled_testAnElementNamedWithALoneColonIsReadOrRefusedWithoutTrapping() throws {
        try assertReturnsOrIsMalformed(Data(page("<p>a<:/>b</p>").utf8), recovering: false, "strict")
    }

    // CRASHES THE TEST PROCESS at the same line through the recovery path: libxml2's HTML parser
    // also accepts ":" as a tag name. Disabled by name (remove `disabled_` to reproduce).
    func disabled_testARecoveredElementNamedWithALoneColonIsReadOrRefusedWithoutTrapping() throws {
        try assertReturnsOrIsMalformed(Data(page("<p>a</b><:>b</p>").utf8), recovering: true, "recovery")
    }

    // Names that merely contain or end in a colon take the same code and must stay harmless.
    func testElementNamesWithEmptyOrUndeclaredPrefixesAreReadAsText() throws {
        XCTAssertEqual(try book(page("<p>x<a:>y</a:>z</p>")).textSection(at: 0).text, "xyz")
        let section = try book(page("<p>x<foo:bar id='q'>y</foo:bar>z</p>")).textSection(at: 0)
        XCTAssertEqual(section.text, "xyz")
        XCTAssertEqual(section.anchors["q"], EPUBTextMark(offset: 1, separator: 0))
    }

    // MARK: Work bounded by the limits

    // An ID is held until the next text character, and each new one is compared with every ID
    // still held. A section of textless anchors (well inside the 100,000-element and 4 MiB
    // defaults) therefore costs quadratic time, where the same anchors each followed by a
    // character are linear. Both are timed in this process, best of three, so load cancels out.
    func testTextlessAnchorsDoNotMakeExtractionQuadratic() throws {
        let count = 6_000
        func seconds(_ body: String) throws -> (Double, EPUBTextSection) {
            let publication = try book(page(body))
            var best = Double.infinity
            var result: EPUBTextSection?
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                result = try publication.textSection(at: 0)
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            return (best, try XCTUnwrap(result))
        }
        let (control, spaced) = try seconds((0..<count).map { "<a id=\"a\($0)\"/>x" }.joined() + "<p>end</p>")
        let (adversarial, textless) = try seconds((0..<count).map { "<a id=\"a\($0)\"/>" }.joined() + "<p>end</p>")
        XCTAssertEqual(spaced.anchors.count, count)
        XCTAssertEqual(textless.anchors.count, count)
        XCTAssertTrue(textless.anchors.values.allSatisfy { $0 == EPUBTextMark(offset: 0, separator: 0) })
        XCTAssertEqual(textless.text, "end")
        XCTAssertLessThan(adversarial, control * 8,
            "\(count) textless anchors took \(adversarial)s; the same anchors with text between them took \(control)s")
    }

    func testTensOfThousandsOfNestedElementsFailWithoutExhaustingTheStack() throws {
        let open = String(repeating: "<div>", count: 50_000), close = String(repeating: "</div>", count: 50_000)
        var limits = EPUBTextExtractionLimits()
        for depth in [limits.depth, 100_000] {
            limits.depth = depth
            for (body, recovering) in [(open + "deep" + close, false), (open + "deep" + close, true), ("<p>x</b></p>" + open + "deep", true)] {
                XCTAssertThrowsError(try book(page(body)).textSection(at: 0, limits: limits, recoversMalformedMarkup: recovering)) {
                    // Which of the two is right for a well-formed document past libxml2's cap is asserted in
                    // ExtractionInputCoverageTests.testAWellFormedDocumentDeeperThanTheParserCapReportsTheDepthLimit.
                    XCTAssertTrue([.limitExceeded("depth"), .malformedContent(path)].contains($0 as? EPUBTextExtractionError), "\($0)")
                }
            }
        }
    }

    func testHugeAttributeValuesAreSkippedAndHugeAlternativesObeyTheOutputLimit() throws {
        let ignored = try book(page("<p title='" + String(repeating: "v", count: 3_900_000) + "'>x</p>")).textSection(at: 0)
        XCTAssertEqual(ignored.text, "x")
        let alternative = String(repeating: "é ", count: 900_000)
        let publication = try book(page("<p><img id='i' alt='\(alternative)'/></p>"))
        let section = try publication.textSection(at: 0)
        XCTAssertEqual(section.text.utf8.count, 900_000 * 3 - 1)
        XCTAssertEqual(section.anchors["i"], EPUBTextMark(offset: 0, separator: 0))
        var limits = EPUBTextExtractionLimits()
        limits.outputBytes = 900_000 * 3 - 2
        XCTAssertThrowsError(try publication.textSection(at: 0, limits: limits)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .limitExceeded("outputBytes"))
        }
    }

    // MARK: Damaged bytes

    private let sample = "<?xml version='1.0' encoding='utf-8'?><!DOCTYPE html><html xmlns='http://www.w3.org/1999/xhtml'><head><title>T &amp; t</title>"
        + "<style>p{}</style></head><body><!-- c --><h1 id=\"h\">A&nbsp;B</h1><p class='x' title='q \"r\"'>one<br/>two &#x1F600; é "
        + "<![CDATA[<raw> & ]]><img alt=\"pic\"/></p><script>if (a) {}</script><math xmlns='http://www.w3.org/1998/Math/MathML' alttext='m'><mi>x</mi></math>"
        + "<p>end</p></body></html>"

    func testEveryTruncationOfADocumentReturnsOrIsMalformed() throws {
        let bytes = Array(sample.utf8)
        XCTAssertEqual(try book(sample).textSection(at: 0).text, "A B\none\ntwo \u{1F600} é <raw> & pic\nm\nend")
        for length in 0..<bytes.count {
            for recovering in [false, true] {
                try assertReturnsOrIsMalformed(Data(bytes[..<length]), recovering: recovering, "first \(length) bytes, recovering \(recovering)")
            }
        }
    }

    // The byte-level scans (declaration safety, reference translation, recovery preparation)
    // index around every delimiter; put each delimiter at positions throughout a document.
    func testDelimiterMutationsOfADocumentNeverTrap() throws {
        let bytes = Array(sample.utf8)
        // ":" is left out: next to "<" it is the trap recorded above, which would end the test process.
        for replacement in Array("<>&\"'=/![]-;?#".utf8) + [0x00, 0x20, 0x80, 0xFF] {
            for index in stride(from: Int(replacement) % 3, to: bytes.count, by: 3) {
                var mutated = bytes
                mutated[index] = replacement
                for recovering in [false, true] {
                    try assertReturnsOrIsMalformed(Data(mutated), recovering: recovering,
                        "byte \(index) replaced with \(replacement), recovering \(recovering)")
                }
            }
        }
    }

    func testUnterminatedConstructsAtTheEndOfARecoveredDocumentReturnOrAreMalformed() throws {
        for tail in ["<", "</", "<a", "<a ", "<a b", "<a b=", "<a b=\"", "<a b='", "<a b=\">", "<a/", "<a /", "<a =", "<a ==>", "<a \"=\"\">",
                     "<![CDATA[", "<![CDATA[]]", "<![CDATA", "<!--", "<!-", "<!", "<!DOCTYPE", "<!DOCTYPE \"", "<!doctype html [", "<?", "<?x",
                     "<script", "<script>", "<script/>", "</script", "<style>", "<STYLE>p{}</STYLE", "<title>", "<textarea>",
                     "&", "&#", "&#x", "&#x;", "&nbsp", "&;", "]]>", "-->", "\"", "'"] {
            for base in ["<html><body><p>x</b>", "<html><body><p title=\"t\">x</b></p>", ""] {
                try assertReturnsOrIsMalformed(Data((base + tail).utf8), recovering: true, base + tail)
                try assertReturnsOrIsMalformed(Data((base + tail + "</p></body></html>").utf8), recovering: true, base + tail + "…")
            }
        }
    }
}
