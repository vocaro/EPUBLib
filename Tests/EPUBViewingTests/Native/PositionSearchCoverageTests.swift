import Foundation
import XCTest
@testable import EPUBViewing

/// `TextSearch` on text and queries the recorded foliate vectors do not hold. Every search runs
/// twice, with and without the prefilter: the prefilter is an optimization and must never
/// change what is found.
final class PositionSearchCoverageTests: XCTestCase {
    private static let xhtml = #"xmlns="http://www.w3.org/1999/xhtml""#

    private func document(_ body: String, lang: String? = "en") throws -> ContentDocument {
        let language = lang.map { " lang=\"\($0)\"" } ?? ""
        let markup = "<html \(Self.xhtml)\(language)><head><title>Title words</title></head><body>\(body)</body></html>"
        return try ContentDocument.parse(Data(markup.utf8), path: "search.xhtml")
    }

    /// The matches of a query as the reader normalizes it, in the document's own language.
    private func matches(_ query: String, in document: ContentDocument, limit: Int = .max,
                         file: StaticString = #filePath, line: UInt = #line) -> [TextSearch.Match] {
        let locale = TextSearch.locale(of: document), normalized = TextSearch.normalizeQuote(query)
        let filtered = TextSearch.matches(of: normalized, in: document, locale: locale, limit: limit)
        let complete = TextSearch.matches(of: normalized, in: document, locale: locale, limit: limit, usePrefilter: false)
        XCTAssertEqual(filtered.map { [$0.start.node.order, $0.start.offset, $0.end.node.order, $0.end.offset] },
                       complete.map { [$0.start.node.order, $0.start.offset, $0.end.node.order, $0.end.offset] },
                       "the prefilter changed the result for \(query.debugDescription)", file: file, line: line)
        return complete
    }
    private func found(_ query: String, in document: ContentDocument, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        matches(query, in: document, file: file, line: line).map { TextSearch.text(of: $0, in: document) }
    }
    private func offsets(_ query: String, in document: ContentDocument, file: StaticString = #filePath, line: UInt = #line) -> [[Int]] {
        matches(query, in: document, file: file, line: line).map { [$0.start.offset, $0.end.offset] }
    }

    // MARK: - What compares equal

    func testCaseDiacriticsWidthAndCanonicalFormAreIgnored() throws {
        let document = try document("<p>Résumé RESUME résumé ｒｅｓｕｍｅ Re&#x301;sume&#x301; resumé rèsumê rasume</p>")
        let expected = ["Résumé", "RESUME", "résumé", "ｒｅｓｕｍｅ", "Re\u{301}sume\u{301}", "resumé", "rèsumê"]
        for query in ["resume", "RESUME", "Résumé", "re\u{301}sume\u{301}", "ｒｅｓｕｍｅ", "ＲÉＳＵＭÉ", "rēsūmē"] {
            XCTAssertEqual(found(query, in: document), expected, query)
        }
        XCTAssertEqual(found("rasume", in: document), ["rasume"])
        XCTAssertEqual(found("resumes", in: document), [])
    }

    /// foliate compares windows of as many graphemes as the query has, so a character that
    /// expands (a ligature, ß) matches only spellings of the same length.
    func testExpansionsMatchOnlySpellingsOfTheSameLength() throws {
        let ligatures = try document("<p>ﬁne ﬂow fine FINE ﬁ</p>")
        XCTAssertEqual(found("fine", in: ligatures), ["fine", "FINE"])
        XCTAssertEqual(found("ﬁne", in: ligatures), ["ﬁne"])
        XCTAssertEqual(found("ﬁ", in: ligatures), ["ﬁ", "ﬁ"])
        XCTAssertEqual(found("fi", in: ligatures), ["fi", "FI"])
        let german = try document("<p>straße strasse STRASSE Straße ẞ ss</p>", lang: "de")
        XCTAssertEqual(found("ss", in: german), ["ss", "SS", "ss"])
        XCTAssertEqual(found("ß", in: german), ["ß", "ß", "ẞ"])
        XCTAssertEqual(found("straße", in: german), ["straße", "Straße"])
        XCTAssertEqual(found("strasse", in: german), ["strasse", "STRASSE"])
    }

    func testGreekCyrillicHebrewArabicKanaAndHangul() throws {
        let greek = try document("<p>ΣΟΦΟΣ σοφος σοφοσ ϲοφοϲ σοφός</p>")
        XCTAssertEqual(found("σοφος", in: greek), ["ΣΟΦΟΣ", "σοφος", "σοφοσ", "ϲοφοϲ", "σοφός"], "final, medial and lunate sigma, and tonos")
        let cyrillic = try document("<p>ёлка ЕЛКА елка йод иод</p>")
        XCTAssertEqual(found("елка", in: cyrillic), ["ёлка", "ЕЛКА", "елка"])
        XCTAssertEqual(found("иод", in: cyrillic), ["иод"], "short i is its own letter")
        let semitic = try document("<p dir=\"rtl\">שָׁלוֹם שלום مَرْحَبًا مرحبا</p>")
        XCTAssertEqual(found("שלום", in: semitic), ["שָׁלוֹם", "שלום"], "points are ignored")
        XCTAssertEqual(found("مرحبا", in: semitic), ["مَرْحَبًا", "مرحبا"], "vowel marks are ignored")
        let starts = matches("שלום", in: semitic).map(\.start.offset)
        XCTAssertEqual(starts, starts.sorted(), "matches come in logical order, not visual")
        let kana = try document("<p>カタカナ かたかな ｶﾀｶﾅ がたかな ガタカナ</p>", lang: "ja")
        XCTAssertEqual(found("かたかな", in: kana), ["カタカナ", "かたかな", "ｶﾀｶﾅ", "がたかな", "ガタカナ"], "script, width and voicing")
        let hangul = try document("<p>한글 한국 ㄱ ᄀ ﾡ 한글날</p>", lang: "ko")
        XCTAssertEqual(found("한글", in: hangul), ["한글", "한글"])
        XCTAssertEqual(found("ㄱ", in: hangul), ["ㄱ", "ᄀ", "ﾡ"], "compatibility, conjoining and halfwidth jamo")
        let digits = try document("<p>123 １２３ ١٢٣ ①②③ 12³</p>")
        XCTAssertEqual(found("123", in: digits), ["123", "１２３", "١٢٣", "①②③", "12³"])
    }

    func testFormatCharactersVanishAndEveryKindOfSpaceIsASpace() throws {
        let spaces = try document("<p>a&#xA0;b a b a&#x2003;b a&#x3000;b a\tb a\nb a&#x200B;b a&#x2060;b a&#xAD;b a&#x200D;b a&#xFEFF;b ab</p>")
        XCTAssertEqual(found("a b", in: spaces).count, 6, "no-break, ordinary, em and ideographic spaces, tab and newline")
        XCTAssertEqual(found("ab", in: spaces), ["a\u{200B}b", "a\u{2060}b", "a\u{AD}b", "a\u{200D}b", "a\u{FEFF}b", "ab"])
        XCTAssertEqual(found("a\u{AD}b", in: spaces).count, 6, "format characters leave the query too")
        let words = try document("<p>A hy&#xAD;phen&#xAD;at&#xAD;ed word; می&#x200C;خواهم؛ co&#x2011;operate.</p>")
        XCTAssertEqual(found("hyphenated word", in: words), ["hy\u{AD}phen\u{AD}at\u{AD}ed word"])
        XCTAssertEqual(found("میخواهم", in: words), ["می\u{200C}خواهم"], "a zero-width non-joiner is a format character")
        XCTAssertEqual(found("می\u{200C}خواهم", in: words), ["می\u{200C}خواهم"])
        XCTAssertEqual(found("co-operate", in: words), [], "a non-breaking hyphen is punctuation of its own")
        XCTAssertEqual(found("co\u{2011}operate", in: words), ["co\u{2011}operate"])
    }

    func testMatchOffsetsCountUTF16UnitsAroundAstralCharacters() throws {
        let document = try document("<p>𝒜𝒷 😀😀 a𝒜 👨‍👩‍👧x</p>")
        XCTAssertEqual(offsets("😀", in: document), [[5, 7], [7, 9]])
        XCTAssertEqual(offsets("a", in: document), [[0, 2], [10, 11], [11, 13]], "mathematical letters are their letters at base strength")
        XCTAssertEqual(offsets("x", in: document), [[22, 23]], "after an eight-unit emoji sequence")
        XCTAssertEqual(found("😀 a", in: document), ["😀 a"])
        for match in matches("a", in: document) + matches("😀", in: document) {
            let path = EPUBCFI.localPath(from: match.start, to: match.end, in: document)
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: path, in: document))
            XCTAssertEqual(TextSearch.Match(start: resolved.start, end: resolved.end), match, path)
        }
    }

    func testQueriesAreLiteralText() throws {
        let document = try document("<p>.*+?^${}()|[]\\ a.c abc a*c [a-z] \\d (x) x|y &amp; &lt;b&gt; %20 100%</p>")
        for query in [".*+?^${}()|[]\\", "a.c", "a*c", "[a-z]", "\\d", "(x)", "x|y", "&", "<b>", "%20", "100%", "$", "^"] {
            XCTAssertEqual(found(query, in: document), [query], query)
        }
        XCTAssertEqual(found(".", in: document).count, 2)
        XCTAssertEqual(found("*", in: document).count, 2)
    }

    // MARK: - Queries at the edges

    func testEmptyWhiteSpaceAndOverlongQueries() throws {
        let document = try document("<p>one two</p>")
        XCTAssertEqual(TextSearch.normalizeQuote(""), "")
        XCTAssertEqual(TextSearch.normalizeQuote(" \t\n\u{A0}\u{3000} "), "", "white space alone is no query")
        XCTAssertEqual(TextSearch.normalizeQuote("\u{AD}\u{200B}\u{FEFF}"), "", "nor are format characters")
        XCTAssertEqual(TextSearch.normalizeQuote("  a \n\t b\u{A0}\u{A0}c\u{AD}d  "), "a b cd")
        for usePrefilter in [true, false] {
            XCTAssertEqual(TextSearch.matches(of: "", in: document, locale: "en", usePrefilter: usePrefilter), [])
            XCTAssertEqual(TextSearch.matches(of: "one", in: document, locale: "en", limit: 0, usePrefilter: usePrefilter), [])
            XCTAssertEqual(TextSearch.matches(of: "one", in: document, locale: "en", limit: -1, usePrefilter: usePrefilter), [])
            XCTAssertEqual(TextSearch.matches(of: " ", in: document, locale: "en", usePrefilter: usePrefilter).count, 1, "a lone space finds spaces")
            XCTAssertEqual(TextSearch.matches(of: "one two", in: document, locale: "en", usePrefilter: usePrefilter).count, 1, "the whole text")
            XCTAssertEqual(TextSearch.matches(of: "one two ", in: document, locale: "en", usePrefilter: usePrefilter), [], "longer than the text")
            XCTAssertEqual(TextSearch.matches(of: String(repeating: "one two ", count: 600), in: document, locale: "en", usePrefilter: usePrefilter), [])
        }
        let empty = try self.document("")
        XCTAssertEqual(found("one", in: empty), [])
        let blank = try self.document("<p>   </p><p>\n</p>")
        XCTAssertEqual(found("one", in: blank), [])
    }

    func testOverlappingOccurrencesAreAllFoundUpToTheLimit() throws {
        let document = try document("<p>aaaaa</p><p>aa</p>")
        XCTAssertEqual(offsets("aaa", in: document), [[0, 3], [1, 4], [2, 5], [3, 1], [4, 2]], "windows also run on into the next text node")
        XCTAssertEqual(matches("aaa", in: document, limit: 2).map(\.start.offset), [0, 1])
        XCTAssertEqual(matches("aa", in: document, limit: 5).map(\.start.offset), [0, 1, 2, 3, 4])
        XCTAssertEqual(matches("aaaaaaa", in: document).count, 1)
        XCTAssertEqual(matches("aaaaaaaa", in: document).count, 0)
        let ordered = matches("a", in: document)
        XCTAssertEqual(ordered.count, 7)
        XCTAssertTrue(zip(ordered, ordered.dropFirst()).allSatisfy { $0.start < $1.start }, "reading order")
    }

    /// foliate joins a document's text nodes with nothing between them: a match may run from
    /// one block into the next, and only white space in the markup separates their words.
    func testTextNodesJoinWithoutSeparatorsAcrossElementsAndBlocks() throws {
        let tight = try document("<p>end of one</p><p>start of two</p><ul><li>three</li><li>four</li></ul>")
        XCTAssertEqual(found("onestart", in: tight), ["onestart"])
        XCTAssertEqual(found("one start", in: tight), [])
        XCTAssertEqual(found("threefour", in: tight), ["threefour"])
        let spaced = try document("<p>end of one</p>\n<p>start of two</p>\n<table><tr><td>cell a</td> <td>cell b</td></tr></table>")
        XCTAssertEqual(found("one start", in: spaced), ["one\nstart"])
        XCTAssertEqual(found("onestart", in: spaced), [])
        XCTAssertEqual(found("cell a cell b", in: spaced), ["cell a cell b"])
        let inline = try document("<p>un<b>bro</b><i>k</i>en<!-- note --> wo<span><span>r</span></span>d, line<br/>break, im<img src=\"a.png\" alt=\"ALT\"/>age</p>")
        XCTAssertEqual(found("unbroken word", in: inline), ["unbroken word"])
        XCTAssertEqual(found("linebreak", in: inline), ["linebreak"], "a line break element is not white space in the text")
        XCTAssertEqual(found("image", in: inline), ["image"], "nor is an image, and its alt text is not searched")
        XCTAssertEqual(found("ALT", in: inline), [])
        let match = try XCTUnwrap(matches("unbroken word", in: inline).first)
        XCTAssertEqual(match.start.node.text, "un")
        XCTAssertEqual(match.end.node.text, "d, line")
        XCTAssertEqual([match.start.offset, match.end.offset], [0, 1])
    }

    func testACarriageReturnLineFeedPairIsOneSpace() throws {
        let ascii = try document("<p>a&#13;&#10;b a&#13;b a&#10;b a&#13;&#10;&#13;&#10; b</p>")
        XCTAssertEqual(found("a b", in: ascii), ["a\r\nb", "a\rb", "a\nb", "a\r\n\r\n b"])
        XCTAssertEqual(TextSearch.matches(of: " ", in: ascii, locale: "en").count, 9, "one unit per white-space grapheme for a one-grapheme query")
        let mixed = try document("<p>é&#13;&#10;b é b</p>")
        XCTAssertEqual(found("e b", in: mixed), ["é\r\nb", "é b"])
    }

    /// The comparison appends private-use sentinels to both sides; text and queries that hold
    /// private-use characters themselves (icon fonts) must still compare by their own content.
    func testPrivateUseCharactersCompareAsThemselves() throws {
        let document = try document("<p>a&#xE000;b ab &#xE001;b a&#xE000; a&#xE001; &#xF0000;&#x10FFFD; a&#xE002;</p>")
        XCTAssertEqual(found("ab", in: document), ["ab"])
        XCTAssertEqual(found("a\u{E000}", in: document), ["a\u{E000}", "a\u{E000}"])
        XCTAssertEqual(found("a\u{E001}", in: document), ["a\u{E001}"])
        XCTAssertEqual(found("\u{E001}b", in: document), ["\u{E001}b"])
        XCTAssertEqual(found("a\u{E000}b", in: document), ["a\u{E000}b"])
        XCTAssertEqual(found("\u{F0000}\u{10FFFD}", in: document), ["\u{F0000}\u{10FFFD}"])
        XCTAssertEqual(found("a\u{E003}", in: document), [])
        XCTAssertEqual(found("a", in: document).count, 5)
    }

    func testAQueryOfOnlyIgnorableCharactersFindsOnlyIgnorableWindows() throws {
        // A combining mark that starts a text node is a grapheme of its own.
        let document = try document("<p><b>&#x301;</b><i>&#x301;</i><u>&#x300;</u>e&#x301; x</p>")
        XCTAssertEqual(TextSearch.matches(of: "\u{301}", in: document, locale: "en").count, 3)
        XCTAssertEqual(TextSearch.matches(of: "\u{301}", in: document, locale: "en", usePrefilter: false).count, 3)
        XCTAssertEqual(TextSearch.matches(of: "\u{301}", in: document, locale: "en", limit: 2).map(\.start.node.order),
                       TextSearch.matches(of: "\u{301}", in: document, locale: "en", limit: 2, usePrefilter: false).map(\.start.node.order))
        XCTAssertEqual(TextSearch.matches(of: "\u{301}", in: document, locale: "en", limit: 2).count, 2)
        XCTAssertEqual(TextSearch.matches(of: "e", in: document, locale: "en").map(\.end.offset), [2], "a mark after its base is part of that grapheme")
    }

    /// One paragraph of several hundred thousand characters, and queries that match at every
    /// character or nearly match everywhere: the search the reader runs finds exactly what is
    /// there (no wall-clock bound is asserted).
    func testAHugeParagraphAndQueriesThatMatchEverywhere() throws {
        let sentence = "It was the best of times, it was the worst of times, it was the age of wisdom. "
        let count = 300_000 / sentence.utf8.count
        let document = try document("<p>" + String(repeating: sentence, count: count) + "</p>")
        func search(_ query: String, in document: ContentDocument, limit: Int = .max) -> [TextSearch.Match] {
            TextSearch.matches(of: query, in: document, locale: "en", limit: limit)
        }
        XCTAssertEqual(search("e", in: document).count, 7 * count)
        XCTAssertEqual(search("e", in: document, limit: 10_000).count, 10_000)
        XCTAssertEqual(search("it was the", in: document).count, 3 * count)
        XCTAssertEqual(search(" ", in: document).count, 18 * count, "every space")
        XCTAssertEqual(search("wisdom. It was the best", in: document).count, count - 1, "only across repeats")
        XCTAssertEqual(search(String(sentence.dropLast()) + "?", in: document).count, 0, "a near miss at every repeat")
        XCTAssertEqual(search(String(sentence.dropLast()), in: document).count, count)
        let last = try XCTUnwrap(search("wisdom.", in: document).last)
        XCTAssertEqual(last.end.offset, count * sentence.utf16.count - 1)
        XCTAssertEqual(EPUBCFI.localPath(from: last.start, to: last.end, in: document), "/4/2,/1:\(last.start.offset),/1:\(last.end.offset)")
        XCTAssertEqual(TextSearch.text(of: last, in: document), "wisdom.")

        let letters = try self.document("<p>" + String(repeating: "a", count: 20_000) + "</p>")
        XCTAssertEqual(search("a", in: letters, limit: 10_000).count, 10_000)
        XCTAssertEqual(search(String(repeating: "a", count: 200), in: letters).count, 20_000 - 199)
        XCTAssertEqual(search(String(repeating: "a", count: 200) + "b", in: letters).count, 0)
        XCTAssertEqual(search(String(repeating: "A", count: 20_000), in: letters).count, 1)
        XCTAssertEqual(search(String(repeating: "a", count: 20_001), in: letters).count, 0)
    }

    // MARK: - Where the search looks

    func testScriptAndStyleTextIsNeverSearchedWhereverItSits() throws {
        let document = try ContentDocument.parse(Data("""
        <html \(Self.xhtml) lang="en"><head><title>needle in the title</title><style>.needle { }</style><script>var needle;</script></head>
        <body><script type="text/javascript">needle();</script><p>A <style>needle</style>visible needle<script>needle</script>.</p>
        <svg xmlns="http://www.w3.org/2000/svg"><style>.needle{}</style><script>needle</script><title>needle of the figure</title><text>drawn needle</text></svg>
        <noscript><p>needle without scripts</p></noscript><template><p>needle in a template</p></template><p hidden="hidden">needle unseen</p>
        <div style="display:none">needle undisplayed</div></body></html>
        """.utf8), path: "where.xhtml")
        let found = TextSearch.matches(of: "needle", in: document, locale: "en")
        XCTAssertEqual(found.map { $0.start.node.parent?.name }, ["p", "title", "text", "p", "p", "p", "div"],
                       "the body's text nodes outside script and style; what renders is decided later")
        XCTAssertEqual(found, TextSearch.matches(of: "needle", in: document, locale: "en", usePrefilter: false))

        // Without a body the whole document is searched, the title included (text-walker's root).
        let headOnly = try ContentDocument.parse(Data("<html \(Self.xhtml)><head><title>Only a needle</title><style>needle</style></head></html>".utf8), path: "head.xhtml")
        XCTAssertEqual(TextSearch.matches(of: "needle", in: headOnly, locale: "en").map { $0.start.node.parent?.name }, ["title"])
        let frames = try ContentDocument.parse(Data("<html \(Self.xhtml)><head><title>needle</title></head><frameset><noframes>needle here</noframes></frameset></html>".utf8),
                                               path: "frames.xhtml")
        XCTAssertEqual(TextSearch.matches(of: "needle", in: frames, locale: "en").map { $0.start.node.parent?.name }, ["noframes"])
        // Markup read as HTML has lowercase names, so its scripts are skipped too.
        let recovered = try ContentDocument.parse(Data("<HTML><BODY><SCRIPT>needle</SCRIPT><STYLE>needle</STYLE><P>needle<BR>shown</BODY></HTML>".utf8), path: "old.html")
        XCTAssertTrue(recovered.recoveredAsHTML)
        XCTAssertEqual(TextSearch.matches(of: "needle", in: recovered, locale: "en").map { $0.start.node.parent?.name }, ["p"])
    }

    func testTheSearchLocaleToleratesAnyLanguageTag() throws {
        func locale(root: String?, body: String?) throws -> String? {
            let markup = "<html \(Self.xhtml)\(root.map { " lang=\"\($0)\"" } ?? "")><head><title>T</title></head><body\(body.map { " lang=\"\($0)\"" } ?? "")><p>x</p></body></html>"
            return TextSearch.locale(of: try ContentDocument.parse(Data(markup.utf8), path: "locale.xhtml"))
        }
        XCTAssertNil(try locale(root: nil, body: nil))
        XCTAssertEqual(try locale(root: "fr", body: ""), "fr", "an empty body language defers to the root")
        XCTAssertNil(try locale(root: "", body: ""))
        XCTAssertEqual(try locale(root: "fr", body: "de-CH"), "de-CH")
        XCTAssertEqual(try locale(root: " en ", body: nil), " en ", "the attribute as written")
        let html = try ContentDocument.parse(Data("<html LANG=\"tr\"><head><title>B</title></head><body><p>x</p></body></html>".utf8), path: "shaped.xhtml")
        XCTAssertEqual(TextSearch.locale(of: html), "tr", "HTML attribute names are case-insensitive")

        // Whatever the tag, a search runs and plain letters still match across case.
        for tag in ["en", "EN", "en_US", "en-US-u-co-phonebk", "de-u-co-phonebk", "English", "x-klingon", "zz", "und", "*", " ", "tr-TR", "ja-JP", "zh-Hant-TW",
                    "sr-Latn", "i-default", "en-", "-", "12345", String(repeating: "x", count: 300), "en\u{301}", "🙂", "ar-u-nu-arab"] {
            let document = try self.document("<p>Plain WORDS and words; ｗｏｒｄｓ too.</p>", lang: tag.replacingOccurrences(of: "\"", with: ""))
            XCTAssertEqual(found("words", in: document).count, 3, tag.debugDescription)
            XCTAssertEqual(found("plain words", in: document).count, 1, tag.debugDescription)
            XCTAssertEqual(found("absent", in: document), [], tag.debugDescription)
        }
    }

    // MARK: - The prefilter

    /// Random text over the scripts books are mostly written in, searched for pieces of itself
    /// (as written and as a reader would type them, without accents): the prefilter must find
    /// exactly what the full comparison finds, in every language the prefilter runs for.
    func testThePrefilterChangesNothingForCommonScripts() throws {
        var state: UInt64 = 0x5EED_0F_5EA7C4
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let ranges: [ClosedRange<UInt32>] = [
            0x41...0x5A, 0x61...0x7A, 0x61...0x7A, 0x30...0x39, 0x20...0x2F, 0xC0...0xFF, 0x100...0x17F, 0x391...0x3A1, 0x3B1...0x3C9, 0x400...0x45F,
            0x3041...0x3096, 0x30A1...0x30FA, 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF66...0xFF6F, 0xFF71...0xFF9D, 0x5D0...0x5EA,
            0x621...0x63A, 0x641...0x64A, 0xAC00...0xAC20, 0x4E00...0x4E20, 0x300...0x304, 0x2010...0x2027, 0x1E00...0x1E99, 0x1EA0...0x1EF9,
        ]
        var compared = 0, differences: [String] = []
        for locale in ["en", "sv", "tr", "es", "da", "de", "ja"] {
            for _ in 0..<40 {
                var scalars = String.UnicodeScalarView()
                for _ in 0..<10 {
                    let range = ranges[next(ranges.count)]
                    for _ in 0..<(1 + next(6)) {
                        if let scalar = Unicode.Scalar(range.lowerBound + UInt32(next(Int(range.upperBound - range.lowerBound) + 1))) { scalars.append(scalar) }
                    }
                    if next(3) == 0 { scalars.append(" ") }
                }
                let text = String(scalars)
                let body = text.unicodeScalars.map { "&#x\(String($0.value, radix: 16));" }.joined()
                let document = try self.document("<p>\(body)</p>", lang: locale)
                let graphemes = Array(text)
                for length in 1...4 where graphemes.count >= length {
                    for _ in 0..<8 {
                        let start = next(graphemes.count - length + 1)
                        var query = String(graphemes[start..<start + length])
                        if next(2) == 0 { query = query.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil) }
                        query = TextSearch.normalizeQuote(query)
                        guard !query.isEmpty else { continue }
                        let filtered = TextSearch.matches(of: query, in: document, locale: locale)
                        let complete = TextSearch.matches(of: query, in: document, locale: locale, usePrefilter: false)
                        compared += 1
                        if filtered != complete {
                            let lost = complete.filter { !filtered.contains($0) }.map { TextSearch.text(of: $0, in: document) }
                            let extra = filtered.filter { !complete.contains($0) }.map { TextSearch.text(of: $0, in: document) }
                            differences.append("\(locale): \(query.debugDescription) loses \(lost) and adds \(extra)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 5_000)
        XCTAssertEqual(differences.count, 0, differences.prefix(12).joined(separator: "; "))
    }

    /// Japanese collation (JIS X 4061, as CLDR tailors it) reads the prolonged sound mark as
    /// the vowel it lengthens and an iteration mark as the kana it repeats: with base
    /// sensitivity `Intl.Collator('ja')` equates らあめん with ラーメン and こころ with こゝろ, and
    /// so does the comparison here. Contextual marks must bypass per-character keys.
    func testJapaneseLengthAndIterationMarksAreNotLostToThePrefilter() throws {
        // The system JavaScriptCore Intl.Collator oracle distinguishes halfwidth prolonged
        // sound marks from their vowel expansions in ja. Keep those as same-form/parity cases.
        let document = try document("<p>ラーメン らあめん ﾗｰﾒﾝ コーヒー ｺｰﾋｰ こゝろ かゞみ</p>", lang: "ja")
        for (query, expected) in [("らあめん", ["ラーメン", "らあめん"]), ("こおひい", ["コーヒー"]), ("こころ", ["こゝろ"]), ("かがみ", ["かゞみ"]),
                                  ("ﾗｰﾒﾝ", ["ﾗｰﾒﾝ"]), ("ｺｰﾋｰ", ["ｺｰﾋｰ"])] {
            let complete = TextSearch.matches(of: query, in: document, locale: "ja", usePrefilter: false).map { TextSearch.text(of: $0, in: document) }
            XCTAssertEqual(complete, expected, "\(query): the full comparison")
            let filtered = TextSearch.matches(of: query, in: document, locale: "ja").map { TextSearch.text(of: $0, in: document) }
            XCTAssertEqual(filtered, expected, "\(query): the search the reader runs")
        }
    }

    /// Base strength ignores the iota subscript (`Intl.Collator('sv')` equates τω with τῷ, as
    /// every locale does). The Swedish and Danish key path folds case first, which spells the
    /// subscript out as a second letter, so the keys no longer agree.
    func testGreekIotaSubscriptIsNotLostToThePrefilterInSwedishAndDanish() throws {
        for locale in ["en", "sv", "da"] {
            let document = try document("<p>ἐν τῷ κόσμῳ, τω ᾳ ᾼ</p>", lang: locale)
            for (query, expected) in [("τω", ["τῷ", "τω"]), ("α", ["ᾳ", "ᾼ"]), ("κοσμω", ["κόσμῳ"])] {
                let complete = TextSearch.matches(of: query, in: document, locale: locale, usePrefilter: false).map { TextSearch.text(of: $0, in: document) }
                XCTAssertEqual(complete, expected, "\(locale) \(query): the full comparison")
                let filtered = TextSearch.matches(of: query, in: document, locale: locale).map { TextSearch.text(of: $0, in: document) }
                XCTAssertEqual(filtered, expected, "\(locale) \(query): the search the reader runs")
            }
        }
    }

    /// Canonically equivalent strings are equal to any collator: `Intl.Collator` returns 0 for a
    /// precomposed Hangul syllable against its conjoining jamo, and for a voiced kana against the
    /// kana and a combining voiced mark, in every locale. A book stored in the other
    /// normalization form than the query (decomposed text is what macOS file names and some
    /// converters produce; typed queries are composed) must still be found. The comparison
    /// here fails when the grapheme that differs in form is the last of the window.
    func testCanonicallyEquivalentHangulAndKanaMatchAcrossNormalizationForms() throws {
        let cases: [(String, String, String, String)] = [
            ("ko", "Hangul", "\u{D55C}\u{AE00}", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}"),
            ("en", "Hangul in an English book", "\u{D55C}\u{AE00}", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}"),
            ("ja", "voiced kana", "\u{304B}\u{304E}", "\u{304B}\u{304D}\u{3099}"),
            ("ja", "semi-voiced katakana", "\u{30B3}\u{30D4}", "\u{30B3}\u{30D2}\u{309A}"),
            ("fr", "a Latin letter, for comparison", "caf\u{E9}", "cafe\u{301}"),
            ("en", "canonical angle brackets", "\u{2329}\u{232A}", "\u{3008}\u{3009}"),
            ("en", "canonical CJK compatibility ideograph", "\u{FA6C}", "\u{242EE}"),
        ]
        for (locale, label, composed, decomposed) in cases {
            XCTAssertEqual(composed.decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value), decomposed.unicodeScalars.map(\.value), label)
            XCTAssertEqual(composed.count, decomposed.count, "\(label): the same graphemes")
            for (query, text, direction) in [(composed, decomposed, "a composed query in decomposed text"),
                                             (decomposed, composed, "a decomposed query in composed text")] {
                let body = text.unicodeScalars.map { "&#x\(String($0.value, radix: 16));" }.joined()
                let document = try self.document("<p>\(body)</p>", lang: locale)
                XCTAssertEqual(TextSearch.matches(of: query, in: document, locale: locale, usePrefilter: false).count, 1,
                               "\(label), \(direction): the full comparison")
                let filtered = TextSearch.matches(of: query, in: document, locale: locale)
                XCTAssertEqual(filtered.count, 1, "\(label), \(direction): the search the reader runs")
                let match = try XCTUnwrap(filtered.first)
                XCTAssertEqual([match.start.offset, match.end.offset], [0, text.utf16.count], label)
                XCTAssertEqual(TextSearch.text(of: match, in: document).unicodeScalars.map(\.value), text.unicodeScalars.map(\.value),
                               "normalization must not alter the book's source text")
                let cfi = EPUBCFI.localPath(from: match.start, to: match.end, in: document)
                let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: cfi, in: document))
                XCTAssertEqual(TextSearch.Match(start: resolved.start, end: resolved.end), match, label)
            }
        }
    }

    /// Root collation gives some letters with no Unicode decomposition the primary weight of a
    /// basic letter (`Intl.Collator('en', { sensitivity: 'base' })` equates a with 🅰 and s with
    /// ꞅ). The prefilter derives keys from decompositions and files them elsewhere.
    func testLettersWithoutDecompositionsAreNotLostToThePrefilter() throws {
        let document = try document("<p>🅰 a ꞅ s Ꝛ r</p>")
        for (query, expected) in [("a", ["🅰", "a"]), ("s", ["ꞅ", "s"]), ("r", ["Ꝛ", "r"])] {
            let complete = TextSearch.matches(of: query, in: document, locale: "en", usePrefilter: false).map { TextSearch.text(of: $0, in: document) }
            XCTAssertEqual(complete, expected, "\(query): the full comparison")
            let filtered = TextSearch.matches(of: query, in: document, locale: "en").map { TextSearch.text(of: $0, in: document) }
            XCTAssertEqual(filtered, expected, "\(query): the search the reader runs")
        }
    }

    func testUnverifiedCharactersAndKeyHitsMergeInOrderWithoutDuplicatesUpToTheLimit() throws {
        let document = try document("<p>a 🅰 a ꞅ s Ꝛ r 🅰 a</p>")
        for query in ["a", "🅰", "s", "ꞅ", "r", "Ꝛ", "a a", "a 🅰"] {
            let complete = TextSearch.matches(of: query, in: document, locale: "en", usePrefilter: false)
            for limit in [1, 2, 3, 4, 10] {
                let filtered = TextSearch.matches(of: query, in: document, locale: "en", limit: limit)
                XCTAssertEqual(filtered, Array(complete.prefix(limit)), "\(query) limit \(limit)")
            }
        }
        XCTAssertEqual(offsets("a", in: document), [[0, 1], [2, 4], [5, 6], [15, 17], [18, 19]])
        let emptyKeys = try self.document("<p><b>&#x301;</b>ـ<i>&#x300;</i></p>")
        for limit in [1, 2, 3, 10] {
            XCTAssertEqual(TextSearch.matches(of: "\u{301}", in: emptyKeys, locale: "en", limit: limit),
                           TextSearch.matches(of: "\u{301}", in: emptyKeys, locale: "en", limit: limit, usePrefilter: false),
                           "ignorable windows and fallback windows share the same ordering and limit")
        }
    }

    func testContextualAndCanonicallyEquivalentMatchesRetainSourceOffsetsAcrossTextNodes() throws {
        let japanese = try document("<p>🙂 <b>こ</b><i>ゝろ</i> <b>か</b><i>き&#x3099;</i> こゝろ</p>", lang: "ja")
        for (query, expected, endOffset) in [("こころ", "こゝろ", 2), ("かぎ", "かき\u{3099}", 2)] {
            let match = try XCTUnwrap(matches(query, in: japanese, limit: 1).first)
            XCTAssertEqual(TextSearch.text(of: match, in: japanese).unicodeScalars.map(\.value), expected.unicodeScalars.map(\.value))
            XCTAssertEqual(match.start.node.parent?.name, "b")
            XCTAssertEqual(match.end.node.parent?.name, "i")
            XCTAssertEqual([match.start.offset, match.end.offset], [0, endOffset])
            let cfi = EPUBCFI.localPath(from: match.start, to: match.end, in: japanese)
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: cfi, in: japanese))
            XCTAssertEqual(TextSearch.Match(start: resolved.start, end: resolved.end), match)
        }
        let korean = try document("<p>🙂 <b>&#x1112;&#x1161;&#x11AB;</b><i>&#x1100;&#x1173;&#x11AF;</i></p>", lang: "ko")
        let match = try XCTUnwrap(matches("한글", in: korean).first)
        XCTAssertEqual([match.start.offset, match.end.offset], [0, 3])
        XCTAssertEqual(TextSearch.text(of: match, in: korean).unicodeScalars.map(\.value),
                       "한글".decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
    }

    /// Additional blocks found by the original collation sweep are deliberately outside the
    /// key table's recorded classes. Neither a plain query nor one containing these characters
    /// may reject a window just because its context-free keys differ.
    func testUnrecordedCollationBlocksDoNotLoseMatches() throws {
        let ranges: [ClosedRange<UInt32>] = [0x1F130...0x1F189, 0xA640...0xA69F, 0xA75A...0xA75B,
                                            0xA783...0xA786, 0xA79B...0xA79D, 0xFE70...0xFE7F]
        let characters = ranges.flatMap { $0 }.compactMap(Unicode.Scalar.init)
        let body = characters.map { "&#x\(String($0.value, radix: 16));" }.joined(separator: " ")
        let document = try self.document("<p>\(body) a s r и й ا ـ</p>")
        for query in ["a", "s", "r", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "t", "u", "v", "w", "x", "y", "z", "и", "й", "ا", "ـ"] {
            XCTAssertEqual(TextSearch.matches(of: query, in: document, locale: "en"),
                           TextSearch.matches(of: query, in: document, locale: "en", usePrefilter: false), query)
        }
        for scalar in characters {
            let query = String(scalar)
            XCTAssertEqual(TextSearch.matches(of: query, in: document, locale: "en", limit: 3),
                           TextSearch.matches(of: query, in: document, locale: "en", limit: 3, usePrefilter: false), query)
        }
    }

    func testALongUnicodeParagraphKeepsFallbackWindowsAndFinalOffsetsCorrect() throws {
        let count = 10_000
        let document = try document("<p>" + String(repeating: "漢a", count: count) + "🅰</p>")
        let matches = TextSearch.matches(of: "a", in: document, locale: "en")
        XCTAssertEqual(matches.count, count + 1)
        XCTAssertEqual(matches.prefix(3).map(\.start.offset), [1, 3, 5])
        let last = try XCTUnwrap(matches.last)
        XCTAssertEqual([last.start.offset, last.end.offset], [2 * count, 2 * count + 2])
        XCTAssertEqual(TextSearch.text(of: last, in: document), "🅰")
        XCTAssertEqual(TextSearch.matches(of: "a", in: document, locale: "en", limit: 3), Array(matches.prefix(3)))
        XCTAssertEqual(TextSearch.matches(of: "missing", in: document, locale: "en"), [])
    }
}
