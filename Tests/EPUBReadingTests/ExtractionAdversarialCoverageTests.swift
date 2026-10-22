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

    // XML 1.0's Name production admits ":" alone. libxml2 reports the element with only a
    // recoverable namespace error and hands on the name ":", where a split at the colon leaves
    // no piece to be the local name; the strict path now refuses it (#178). The input is
    // otherwise well-formed XHTML; any section of an untrusted book can carry it.
    func testAnElementNamedWithALoneColonIsReadOrRefusedWithoutTrapping() throws {
        try assertReturnsOrIsMalformed(Data(page("<p>a<:/>b</p>").utf8), recovering: false, "strict")
    }

    // The same name through the recovery path. To HTML `<:` is text, not a tag (#198); libxml2's
    // HTML parser still hands on the name ":" for `<a::>`, once it has taken `a` for a prefix.
    func testARecoveredElementNamedWithALoneColonIsReadOrRefusedWithoutTrapping() throws {
        try assertReturnsOrIsMalformed(Data(page("<p>a</b><a::>b</p>").utf8), recovering: true, "recovery")
        try assertReturnsOrIsMalformed(Data(page("<p>a</b><:>b</p>").utf8), recovering: true, "recovery, as text")
    }

    // A name that begins or ends with a colon is no qualified name. libxml2 reports it with a
    // recoverable namespace error and reads on; the native reader takes that error for markup
    // that is not well-formed and reads the section as HTML, where `<:` is text (#198). So
    // strict extraction refuses the section, and recovery reads what the reader shows (#178).
    func testNamesWithALeadingOrTrailingColonAreMalformedAndRecoveredAsTheReaderShowsThem() throws {
        let cases = [
            ("<div>a<:p>b</:p>c</div>", "a<:p>bc"),
            ("<p>a<:script>b</:script>c</p>", "a<:script>bc"),
            ("<p>a<:img alt='ALT'/>c</p>", "a<:img alt='ALT'/>c"),
            // HTML reads a tag name on through its colon: an unknown inline element.
            ("<div>a<p:>b</p:>c</div>", "abc"),
            ("<p>a<script:>b</script:>c</p>", "abc"),
            ("<p>a<style:>b</style:>c</p>", "abc"),
            ("<p>a<img: alt='ALT'/>c</p>", "ac"),
            ("<p>x<a:>y</a:>z</p>", "xyz"),
            // A second colon: libxml2 takes `a` for a prefix and keeps `b:script` whole.
            ("<p>a<a:b:script>b</a:b:script>c</p>", "abc"),
            // Attribute names, and a processing instruction's target, which may hold no colon.
            ("<p :='v' a:='w' :a='x' id='i'>a</p>", "a"),
            ("<p>a<?a:b x?>b</p>", "ab"),
        ]
        for (body, text) in cases {
            let publication = try book(page(body))
            XCTAssertThrowsError(try publication.textSection(at: 0), body) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), body)
            }
            let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
            XCTAssertEqual(section.text, text, body)
            XCTAssertTrue(section.recoveredAsHTML, body)
        }
    }

    // Names made only of colons are refused in the same way. Recovered, `<:` is text and gives
    // no element its ID; what libxml2's HTML parser leaves of `a:` and the colons, once it has
    // taken `a` for a prefix, is an unknown inline element that keeps its text and its ID.
    func testNamesMadeOnlyOfColonsAreMalformedAndRecoveredAsText() throws {
        for name in [":", "::", ":::"] {
            let publication = try book(page("<p>a<\(name) id='q'>b</\(name)>c<\(name)/></p>",
                                            head: "<title>T<\(name)>U</\(name)></title>"))
            XCTAssertThrowsError(try publication.textSection(at: 0), name) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), name)
            }
            let recovered = try publication.textSection(at: 0, recoversMalformedMarkup: true)
            XCTAssertEqual(recovered.text, "a<\(name) id='q'>bc<\(name)/>", name)
            XCTAssertEqual(recovered.title, "T<\(name)>U", name)
            XCTAssertEqual(recovered.anchors, [:], name)
            let element = try book(page("<p>a</b><a:\(name) id='q'>b</a:\(name)>c</p>")).textSection(at: 0, recoversMalformedMarkup: true)
            XCTAssertEqual(element.text, "abc", name)
            XCTAssertEqual(element.anchors, ["q": EPUBTextMark(offset: 1, separator: 0)], name)
            XCTAssertTrue(element.recoveredAsHTML, name)
        }
    }

    // Such a name is never the XHTML root, keeps its tag in structural MathML notation, and is
    // ignored as an attribute name, where the same split looks for EPUB-namespace types.
    func testANameMadeOnlyOfColonsIsNoRootKeepsItsTagInMathNotationAndIsNoSemanticType() throws {
        let rooted = "<: xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>a</p></body></:>"
        XCTAssertThrowsError(try book(rooted).textSection(at: 0)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path))
        }
        let math = try book(page("<p>a</b><math xmlns='http://www.w3.org/1998/Math/MathML'><a:: id='m'><mi>x</mi></a::></math>b</p>"))
            .textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(math.text, #"amath(:("x"))b"#)
        XCTAssertEqual(math.anchors, ["m": EPUBTextMark(offset: 6, separator: 0)])
        let attributes = try book(page("<p xmlns:e='http://www.idpf.org/2007/ops' :='v' ::='w' e:type='x' id='i'>a</p>"))
        XCTAssertThrowsError(try attributes.textSection(at: 0)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path))
        }
        let recovered = try attributes.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(recovered.text, "a")
        XCTAssertEqual(recovered.semanticTypes, ["x"])
        XCTAssertEqual(recovered.anchors, ["i": EPUBTextMark(offset: 0, separator: 0)])
    }

    // A prefix that is never declared names no namespace, as in the reader, whose HTML parser
    // drops it: the element is read by its local name. Strictly it is no malformed name.
    func testElementNamesWithUndeclaredPrefixesAreReadByTheirLocalNames() throws {
        let section = try book(page("<p>x<foo:bar id='q'>y</foo:bar>z<foo:script>s</foo:script></p><foo:p>w</foo:p>")).textSection(at: 0)
        XCTAssertEqual(section.text, "xyz\nw")
        XCTAssertEqual(section.anchors["q"], EPUBTextMark(offset: 1, separator: 0))
        XCTAssertFalse(section.recoveredAsHTML)
    }

    // Neither is the XHTML root or body. Recovered, each is text, as the reader shows it; there
    // `<:html …>` opens the body, and the title is the body's text, as other undisplayed text is.
    func testHTMLAndBodyNamedWithALeadingColonAreNoRootOrBody() throws {
        let documents = [
            // The title, built in the body, is hidden there as every title is (#287).
            ("<:html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><body><p>a</p></body></:html>",
             "<:html xmlns='http://www.w3.org/1999/xhtml'>\na"),
            ("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>T</title></head><:body><p>a</p></:body></html>",
             "<:body>\na"),
        ]
        for (document, text) in documents {
            let publication = try book(document)
            XCTAssertThrowsError(try publication.textSection(at: 0), document) {
                XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), document)
            }
            let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
            XCTAssertEqual(section.text, text, document)
            XCTAssertTrue(section.recoveredAsHTML, document)
        }
    }

    // `xmlns:` names no prefix, so it declares none, and no default namespace either (#178).
    func testAnXMLNSAttributeWithAnEmptyPrefixDeclaresNothing() throws {
        let publication = try book(page("<p xmlns:='urn:x'>a<img alt='ALT'/>b<span id='s'>c</span></p><p>d</p>"))
        XCTAssertThrowsError(try publication.textSection(at: 0)) {
            XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path))
        }
        let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
        XCTAssertEqual(section.text, "aALTbc\nd")
        XCTAssertEqual(section.anchors, ["s": EPUBTextMark(offset: 5, separator: 0)])
    }

    // Beside `xmlns`, `xmlns:` gives one result whichever comes first: strict extraction refuses it,
    // and recovery reads the element in the namespace `xmlns` names, as the reader does (#213). An
    // element's declarations are read in document order, so each order here is one the walk takes.
    func testAnEmptyPrefixDeclarationBesideXMLNSGivesOneResultInEitherOrder() throws {
        let xhtml = "xmlns='http://www.w3.org/1999/xhtml'", empty = "xmlns:='urn:x'"
        for declarations in [[xhtml, empty], [empty, xhtml]] {
            let pair = declarations.joined(separator: " ")
            let documents = [
                "<html \(pair)><head><title>T</title></head><body><p id='p'>a<img alt='ALT'/>b</p><p>c</p></body></html>",
                page("<p \(pair) id='p'>a<img alt='ALT'/>b</p><p>c</p>"),
            ]
            for document in documents {
                let publication = try book(document)
                XCTAssertThrowsError(try publication.textSection(at: 0), document) {
                    XCTAssertEqual($0 as? EPUBTextExtractionError, .malformedContent(path), document)
                }
                let section = try publication.textSection(at: 0, recoversMalformedMarkup: true)
                XCTAssertEqual(section.text, "aALTb\nc", document)
                XCTAssertEqual(section.title, "T", document)
                XCTAssertEqual(section.anchors, ["p": EPUBTextMark(offset: 0, separator: 0)], document)
                XCTAssertTrue(section.recoveredAsHTML, document)
            }
        }
    }

    // Well-formed prefixed names are read in the namespace each prefix names.
    func testWellFormedPrefixedNamesAreReadInTheirNamespaces() throws {
        let section = try book(page("<div xmlns:epub='http://www.idpf.org/2007/ops' xmlns:m='http://www.w3.org/1998/Math/MathML' "
            + "xmlns:svg='http://www.w3.org/2000/svg' xmlns:h='http://www.w3.org/1999/xhtml'>a<epub:switch>"
            + "<epub:case required-namespace='urn:x'>b</epub:case><epub:default>c</epub:default></epub:switch>"
            + "<m:math><m:mi>x</m:mi></m:math><svg:svg><svg:text>d</svg:text></svg:svg><h:script>s</h:script>"
            + "<h:p epub:type='z'>e</h:p></div>")).textSection(at: 0)
        XCTAssertEqual(section.text, #"abcmath("x")d"# + "\ne")
        XCTAssertEqual(section.semanticTypes, ["z"])
        XCTAssertFalse(section.recoveredAsHTML)
    }

    // MARK: Work bounded by the limits

    // Pending IDs must not make textless anchors quadratic. Compare with the same anchors
    // followed by text, using thread CPU time, best of three, excluding scheduling delay.
    func testTextlessAnchorsDoNotMakeExtractionQuadratic() throws {
        let count = 6_000
        func seconds(_ body: String) throws -> (Double, EPUBTextSection) {
            let publication = try book(page(body))
            var best = Double.infinity
            var result: EPUBTextSection?
            for _ in 0..<3 {
                let start = TestCPUClock.seconds()
                result = try publication.textSection(at: 0)
                best = min(best, TestCPUClock.seconds() - start)
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

    func testPendingAnchorDuplicatesKeepTheirFirstPositionInBothParsers() throws {
        for recovering in [false, true] {
            let prefix = recovering ? "<p>start</b></p>" : "<p>start</p>"
            let section = try book(page(prefix + "<a id='same'/><a id='same'/><a id='next'/>"
                + "<p>target</p><a id='same'/><a id='end'/><a id='end'/>")).textSection(
                    at: 0, recoversMalformedMarkup: recovering)
            XCTAssertEqual(section.text, "start\ntarget")
            XCTAssertEqual(section.anchors, [
                "same": EPUBTextMark(offset: 6, separator: 1),
                "next": EPUBTextMark(offset: 6, separator: 1),
                "end": EPUBTextMark(offset: 12, separator: 0),
            ])
            XCTAssertEqual(section.recoveredAsHTML, recovering)
        }
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
        for replacement in Array("<>&\"'=/![]-;?#:".utf8) + [0x00, 0x20, 0x80, 0xFF] {
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
