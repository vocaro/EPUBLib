import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing

final class TextSearchTests: XCTestCase {
    private func document(_ body: String, lang: String = "en") throws -> ContentDocument {
        let markup = #"<html xmlns="http://www.w3.org/1999/xhtml" lang="\#(lang)"><head><title>Title words</title></head><body>"#
            + body + "</body></html>"
        return try ContentDocument.parse(Data(markup.utf8), path: "search.xhtml")
    }

    /// The matched text, read from the document as the DOM range would cover it.
    private func matched(_ match: TextSearch.Match, in document: ContentDocument) -> String {
        var string = ""
        for order in match.start.node.order...match.end.node.order where document.nodes[order].isText {
            let utf16 = Array(document.nodes[order].text.utf16)
            let from = order == match.start.node.order ? match.start.offset : 0
            let to = order == match.end.node.order ? match.end.offset : utf16.count
            string += String(decoding: utf16[from..<to], as: UTF16.self)
        }
        return string
    }

    func testMatchesSpanInlineElementsAndCollapseWhitespace() throws {
        let document = try document("<p>A word split across <b>bold</b>face, then   spaced\n\t out.</p><p>Next</p>")
        let bold = TextSearch.matches(of: "boldface", in: document, locale: "en")
        XCTAssertEqual(bold.map { matched($0, in: document) }, ["boldface"])
        XCTAssertEqual(bold.first?.start.node.text, "bold")
        XCTAssertEqual(TextSearch.matches(of: "then spaced out", in: document, locale: "en").map { matched($0, in: document) },
                       ["then   spaced\n\t out"])
        XCTAssertEqual(TextSearch.matches(of: "out.Next", in: document, locale: "en").count, 1,
                       "text nodes join without a separator, as foliate's strings did")
    }

    func testTheTitleScriptsAndStylesAreNotSearched() throws {
        let document = try document("<p>Visible</p><script>var hidden = 1;</script><style>p { color: red }</style>")
        XCTAssertEqual(TextSearch.matches(of: "Title words", in: document, locale: "en"), [])
        XCTAssertEqual(TextSearch.matches(of: "hidden", in: document, locale: "en"), [])
        XCTAssertEqual(TextSearch.matches(of: "color", in: document, locale: "en"), [])
        XCTAssertEqual(TextSearch.matches(of: "visible", in: document, locale: "en").count, 1)
    }

    func testFormatCharactersVanishAndCaseAndDiacriticsAreIgnored() throws {
        let document = try document("<p>Zero&#xFEFF;width soft&#xAD;hyphen Café CAFE cafe&#x301; ＡＢＣ</p>")
        XCTAssertEqual(TextSearch.matches(of: "zerowidth softhyphen", in: document, locale: "en").count, 1)
        XCTAssertEqual(TextSearch.matches(of: "cafe", in: document, locale: "en").map { matched($0, in: document) },
                       ["Café", "CAFE", "cafe\u{301}"])
        XCTAssertEqual(TextSearch.matches(of: "abc", in: document, locale: "en").map { matched($0, in: document) }, ["ＡＢＣ"])
        XCTAssertEqual(TextSearch.matches(of: "it’s", in: try self.document("<p>it's</p>"), locale: "en").count, 1,
                       "root collation treats the apostrophes alike")
    }

    func testOverlappingMatchesAndTheLimit() throws {
        let document = try document("<p>aaaa</p>")
        XCTAssertEqual(TextSearch.matches(of: "aa", in: document, locale: "en").map(\.start.offset), [0, 1, 2])
        XCTAssertEqual(TextSearch.matches(of: "aa", in: document, locale: "en", limit: 1).map(\.start.offset), [0])
        XCTAssertEqual(TextSearch.matches(of: "aa", in: document, locale: "en", limit: 0), [])
        XCTAssertEqual(TextSearch.matches(of: "", in: document, locale: "en"), [])
        XCTAssertEqual(TextSearch.matches(of: "aaaaa", in: document, locale: "en"), [])
    }

    /// foliate's window keeps one unit for a one-grapheme query, so every white-space grapheme
    /// becomes its own space; longer queries collapse runs.
    func testWhitespaceRunsCollapseOnlyForLongerQueries() throws {
        let document = try document("<p>a \n b</p>")
        XCTAssertEqual(TextSearch.matches(of: " ", in: document, locale: "en").count, 3)
        XCTAssertEqual(TextSearch.matches(of: "a b", in: document, locale: "en").map { matched($0, in: document) }, ["a \n b"])
    }

    func testLocalesComeFromTheBodyThenTheRootLangAttribute() throws {
        func locale(_ markup: String) throws -> String? {
            TextSearch.locale(of: try ContentDocument.parse(Data(markup.utf8), path: "l.xhtml"))
        }
        XCTAssertEqual(try locale(#"<html xmlns="http://www.w3.org/1999/xhtml" lang="fr"><body lang="de"/></html>"#), "de")
        XCTAssertEqual(try locale(#"<html xmlns="http://www.w3.org/1999/xhtml" lang="fr"><body/></html>"#), "fr")
        XCTAssertNil(try locale(#"<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="fr"><body/></html>"#))
        // foliate threw without a body; the root's language is the natural reading.
        XCTAssertEqual(try locale(#"<svg xmlns="http://www.w3.org/2000/svg" lang="fr"/>"#), "fr")
    }

    func testTurkishDottedAndDotlessIStayApart() throws {
        let document = try document("<p>Istanbul istanbul</p>", lang: "tr")
        XCTAssertEqual(TextSearch.matches(of: "istanbul", in: document, locale: "tr").map(\.start.offset), [9])
        XCTAssertEqual(TextSearch.matches(of: "ISTANBUL", in: document, locale: "tr").map(\.start.offset), [0])
    }

    func testTailoredMatchesAndMissesAgreeWithHistoricalFoliate() throws {
        struct Vectors: Decodable {
            struct Fixture: Decodable {
                let locale: String
                let query: String
                let matches: [[Int]]
            }
            let fixtures: [Fixture]
        }
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(SearchCollationGoldenVectors.json.utf8))
        XCTAssertEqual(vectors.fixtures.count, SearchCollationFixtures.fixtures.count)
        XCTAssertTrue(vectors.fixtures.contains { $0.matches.isEmpty }, "record nonmatches as well as matches")
        for (fixture, vector) in zip(SearchCollationFixtures.fixtures, vectors.fixtures) {
            XCTAssertEqual(vector.locale, fixture.locale)
            XCTAssertEqual(vector.query, fixture.query)
            let document = try ContentDocument.parse(Data(fixture.markup.utf8), path: "tailored.xhtml")
            func ranges(_ matches: [TextSearch.Match]) -> [[Int]] {
                matches.map { [$0.start.node.order, $0.start.offset, $0.end.node.order, $0.end.offset] }
            }
            let filtered = TextSearch.matches(of: fixture.query, in: document, locale: TextSearch.locale(of: document))
            let complete = TextSearch.matches(of: fixture.query, in: document, locale: TextSearch.locale(of: document), usePrefilter: false)
            let label = "\(fixture.locale): \(fixture.query) in \(fixture.body)"
            XCTAssertEqual(ranges(complete), vector.matches, label)
            XCTAssertEqual(filtered, complete, "The prefilter suppressed or added a match: \(label)")
        }
    }

    func testAOneMegabyteSectionSearchesQuickly() throws {
        let paragraph = "<p>It was the best of times, it was the worst of times, it was the age of wisdom, "
            + "it was the age of <em>foolishness</em>, it was the epoch of belief — “café” naïve résumé.</p>\n"
        let count = 1_048_576 / paragraph.utf8.count + 1
        let body = String(repeating: paragraph, count: count) + "<p>The final unique sentence ends here.</p>"
        let document = try document(body)
        let clock = TestCPUClock.self
        var matches: [TextSearch.Match] = []
        let unique = clock.measure {
            matches = TextSearch.matches(of: "the final UNIQUE sentence ends here.", in: document, locale: "en")
        }
        XCTAssertEqual(matches.count, 1)
        let common = clock.measure {
            matches = TextSearch.matches(of: "the age of foolishness", in: document, locale: "en")
        }
        XCTAssertEqual(matches.count, count)
        let accented = clock.measure {
            matches = TextSearch.matches(of: "naive resume", in: document, locale: "en")
        }
        XCTAssertEqual(matches.count, count)
        // A reader can type decomposed accents even when a book stores composed letters.
        // Canonical equivalence must keep the established fast scan as well as its matches.
        let decomposed = clock.measure {
            matches = TextSearch.matches(of: "naïve résumé".decomposedStringWithCanonicalMapping, in: document, locale: "en")
        }
        XCTAssertEqual(matches.count, count)
        print("1 MB search CPU seconds: unique \(unique), common \(common), accented \(accented), decomposed query \(decomposed)")
        #if DEBUG
        let bound = 2.0
        #else
        let bound = 0.1
        #endif
        XCTAssertLessThan(unique, bound)
        XCTAssertLessThan(common, bound)
        XCTAssertLessThan(accented, bound)
        XCTAssertLessThan(decomposed, bound)
    }

    /// Unverified collations use the complete window scan. Record its cost without a fragile
    /// wall-clock assertion; correctness must not depend on a locale having a fast key table.
    func testOneMegabyteFrenchSearchRecordsFallbackCost() throws {
        let paragraph = "<p>Un paragraphe de texte français ordinaire, avec un café et quelques accents.</p>"
        let count = 1_048_576 / paragraph.utf8.count + 1
        let document = try document(String(repeating: paragraph, count: count) + "<p>La phrase finale unique.</p>", lang: "fr")
        var matches: [TextSearch.Match] = []
        let time = ContinuousClock().measure {
            matches = TextSearch.matches(of: "la PHRASE finale unique.", in: document, locale: "fr")
        }
        XCTAssertEqual(matches.count, 1)
        print("1 MB French unfiltered search: \(time)")
    }
}
