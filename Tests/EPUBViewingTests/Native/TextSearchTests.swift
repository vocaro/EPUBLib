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

    func testAOneMegabyteSectionSearchesQuickly() throws {
        let paragraph = "<p>It was the best of times, it was the worst of times, it was the age of wisdom, "
            + "it was the age of <em>foolishness</em>, it was the epoch of belief — “café” naïve résumé.</p>\n"
        let count = 1_048_576 / paragraph.utf8.count + 1
        let body = String(repeating: paragraph, count: count) + "<p>The final unique sentence ends here.</p>"
        let document = try document(body)
        let clock = ContinuousClock()
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
        print("1 MB search: unique \(unique), common \(common), accented \(accented)")
        #if DEBUG
        let bound = Duration.seconds(2)
        #else
        let bound = Duration.milliseconds(100)
        #endif
        XCTAssertLessThan(unique, bound)
        XCTAssertLessThan(common, bound)
        XCTAssertLessThan(accented, bound)
    }
}
