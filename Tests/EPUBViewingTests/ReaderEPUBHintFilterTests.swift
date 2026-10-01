#if DEBUG
import WebKit
import XCTest
@testable import EPUBViewing

@MainActor
final class ReaderEPUBHintFilterTests: XCTestCase {
    private static let hint = #"<link rel="preconnect" href="https://example.invalid/"/>"#
    private static let prefixedHint =
        #"<x:link xmlns:x="http://www.w3.org/1999/xhtml" rel="preconnect" "#
        + #"href="https://example.invalid/"/>"#

    private static func section(prologue: String = "", head: String = "", body: String) -> String {
        prologue
            + #"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title>"#
            + head + "</head><body>" + body + "</body></html>"
    }


    func testAHintIsRemovedWhateverItsSpelling() async throws {
        let outcomes = try await filter([
            "plain": Self.section(head: Self.hint, body: "<p>Text.</p>"),
            "prefixed": Self.section(head: Self.prefixedHint, body: "<p>Text.</p>"),
            "notWellFormed": #"<html><head><link rel="dns-prefetch" href="//example.invalid">"#
                + "</head><body><p>Text.<br></p></body></html>",
        ])
        for name in ["plain", "prefixed", "notWellFormed"] {
            let outcome = try XCTUnwrap(outcomes[name])
            assertFiltered(outcome, name)
        }
        for name in ["plain", "prefixed"] {
            XCTAssertFalse(try XCTUnwrap(outcomes[name]).withheld, "\(name) was withheld")
        }
    }


    func testABooksOwnParserErrorDoesNotSwitchTheFilterOff() async throws {
        let outcomes = try await filter([
            "literal": Self.section(head: Self.hint, body: "<parsererror/><p>Text.</p>"),
            "literalWithPrefixedHint": Self.section(
                head: Self.prefixedHint, body: "<parsererror/><p>Text.</p>"),
            "fromAnEntity": Self.section(
                prologue: #"<!DOCTYPE html [<!ENTITY p "&#60;parsererror/>">]>"#,
                head: Self.prefixedHint, body: "&p;<p>Text.</p>"),
        ])
        for name in ["literal", "literalWithPrefixedHint", "fromAnEntity"] {
            assertFiltered(try XCTUnwrap(outcomes[name]), name)
        }
    }


    func testAnEntityBorneHintIsFilteredThoughTheTextNeverSaysLink() async throws {
        let markup = Self.section(
            prologue: #"<!DOCTYPE html [<!ENTITY h "&#60;l&#105;nk rel='preconnect' "#
                + #"href='https://example.invalid/'/>">]>"#,
            head: "&h;", body: "<p>Text.</p>")
        XCTAssertFalse(markup.lowercased().contains("link"), "the fixture spells the element")

        let outcomes = try await filter(["entity": markup])
        let outcome = try XCTUnwrap(outcomes["entity"])
        XCTAssertTrue(
            outcome.armedIn.contains(Self.xhtml),
            "the entity did not expand to a link under \(Self.xhtml), so this proves nothing")
        assertFiltered(outcome, "entity")
    }


    func testAHintOnlyTheHTMLReadingSeesIsNotHandedBack() async throws {
        let markup = Self.section(body: "<p><![CDATA[x>" + Self.hint + "]]></p>")
        let outcomes = try await filter(["cdata": markup])
        let outcome = try XCTUnwrap(outcomes["cdata"])
        assertFiltered(outcome, "cdata")
    }


    func testASectionWithNoHintIsHandedBackAsItsOriginalText() async throws {
        let markup = Self.section(
            head: #"<link rel="stylesheet" href="style.css"/>"#,
            body: #"<p><a href="https://example.invalid/">An ordinary link.</a></p>"#)
        let outcomes = try await filter(["clean": markup])
        let outcome = try XCTUnwrap(outcomes["clean"])
        XCTAssertEqual(outcome.armedIn, [])
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertTrue(outcome.unchanged, "a section with nothing to remove was rewritten")
    }


    private static let xhtml = "application/xhtml+xml"

    private struct Outcome: Decodable {
        let armedIn: [String]
        let leftIn: [String]
        let removed: Int
        let unchanged: Bool
        let withheld: Bool
    }

    private func assertFiltered(
        _ outcome: Outcome, _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            outcome.armedIn.isEmpty, "\(name) carries no hint under either parser",
            file: file, line: line)
        XCTAssertEqual(
            outcome.leftIn, [], "\(name) still carries a hint under \(outcome.leftIn)",
            file: file, line: line)
        XCTAssertEqual(outcome.removed, 1, "\(name) was not counted once", file: file, line: line)
        XCTAssertFalse(outcome.unchanged, "\(name) was handed back as it came in",
                       file: file, line: line)
    }

    private static let harness = #"""
        const READINGS = ['application/xhtml+xml', 'text/html']
        const RELS = [
            'dns-prefetch', 'preconnect', 'prefetch', 'prerender', 'preload', 'modulepreload',
        ]
        const hintsUnder = (markup, type) => [
            ...new DOMParser().parseFromString(markup, type).getElementsByTagName('*'),
        ].filter(element => element.localName === 'link'
            && (element.getAttribute('rel') ?? '').toLowerCase().split(/\s+/)
                .some(rel => RELS.includes(rel))).length
        const outcomes = {}
        for (const [name, markup] of Object.entries(fixtures)) {
            const result = withoutPreconnectingLinks(markup)
            outcomes[name] = {
                armedIn: READINGS.filter(type => hintsUnder(markup, type) > 0),
                leftIn: READINGS.filter(type => hintsUnder(result.text, type) > 0),
                removed: result.removed,
                unchanged: result.text === markup,
                withheld: result.text === WITHHELD_SECTION,
            }
        }
        return JSON.stringify(outcomes)
        """#

    private func filter(_ fixtures: [String: String]) async throws -> [String: Outcome] {
        let fixturesJSON = try XCTUnwrap(String(
            data: try JSONSerialization.data(withJSONObject: fixtures, options: [.sortedKeys]),
            encoding: .utf8))
        let script = "(() => {\nconst fixtures = \(fixturesJSON)\n"
            + (try filterBlock()) + "\n" + Self.harness + "\n})()"
        let webView = WKWebView()
        let result = try await webView.evaluateJavaScript(script)
        let json = try XCTUnwrap(
            result as? String, "the harness returned \(String(describing: result))")
        return try JSONDecoder().decode([String: Outcome].self, from: Data(json.utf8))
    }

    private func filterBlock() throws -> String {
        let script = try XCTUnwrap(
            String(data: try readerResource("bootstrap.js"), encoding: .utf8))
        let begin = try XCTUnwrap(
            script.range(of: "// BEGIN hint-filter"), "bootstrap.js has no hint-filter block")
        let end = try XCTUnwrap(
            script.range(of: "// END hint-filter", range: begin.upperBound..<script.endIndex),
            "bootstrap.js's hint-filter block is not closed")
        return String(script[begin.lowerBound..<end.lowerBound])
    }

    private func readerResource(_ name: String) throws -> Data {
        let candidates = [FoliateTestResources.bundle].compactMap {
            $0.url(forResource: ReaderEPUBAssets.resourceDirectory, withExtension: nil)
        }
        guard let directory = candidates.first else {
            throw XCTSkip("this build carries no \(ReaderEPUBAssets.resourceDirectory) resources")
        }
        return try Data(contentsOf: directory.appending(path: name))
    }
}
#endif
