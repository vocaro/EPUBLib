import CoreText
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class SectionBuilderTests: XCTestCase {
    private typealias H = BuilderHarness

    // MARK: Whitespace

    func testWhitespaceCollapsesAcrossInlineBoundaries() throws {
        let text = try H.build("""
            <p>  Hello   <em> world </em>  again\t</p>
            <p>a<span> </span> <b> b</b></p>
            """)
        XCTAssertEqual(text.string.string, "Hello world again\na b")
        H.assertMapRoundTrips(text)
    }

    func testBlockStartAndEndSpacesAndInterBlockWhitespaceAreDropped() throws {
        let text = try H.build("\n  <div>\n   <p>\n one\n </p>\n   <p>two</p>\n  </div>\n ")
        XCTAssertEqual(text.string.string, "one\ntwo")
        H.assertMapRoundTrips(text)
    }

    func testPreformattedTextKeepsSpacesTabsAndLinesInOneParagraph() throws {
        let text = try H.build("<pre>\n  let a = 1\n\tb()\n</pre><p>after</p>")
        XCTAssertEqual(text.string.string, "  let a = 1\u{2028}\tb()\nafter")
        let style = try XCTUnwrap(H.paragraphStyle(text, at: 0))
        XCTAssertEqual(style.lineBreakMode, .byCharWrapping)
        let font = FontRegistry(publication: H.publication).font(for: ComputedStyle(fontFamilies: ["monospace"], fontSize: 16))
        XCTAssertEqual(style.defaultTabInterval, 8 * InlineStyling.spaceAdvance(font), accuracy: 0.01)
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "after", in: text))?.lineBreakMode, .byWordWrapping)
        H.assertMapRoundTrips(text)
    }

    func testPreLineAndPreWrap() throws {
        let text = try H.build("<p class='line'>a  \n   b    c</p><p class='wrap'>x   y\n z</p>", rules: [
            (".line", { $0.whiteSpace = .preLine }), (".wrap", { $0.whiteSpace = .preWrap }),
        ])
        XCTAssertEqual(text.string.string, "a\u{2028}b c\nx   y\u{2028} z")
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "x", in: text))?.lineBreakMode, .byWordWrapping)
        H.assertMapRoundTrips(text)
    }

    func testLineBreaksAndBlankLines() throws {
        let text = try H.build("<p>one<br/>two <br/> three<br/></p><p><br/></p><p>four<br/><br/></p><p>five</p>")
        XCTAssertEqual(text.string.string, "one\u{2028}two\u{2028}three\n\nfour\u{2028}\nfive")
        let trailing = try H.build("<p>last</p><p><br/></p>")
        XCTAssertEqual(trailing.string.string, "last")
    }

    func testSegmentBreakBetweenEastAsianCharactersDisappears() throws {
        let text = try H.build("<p>漢字\nかな\nand\nLatin、\n<span>テスト</span></p>")
        XCTAssertEqual(text.string.string, "漢字かな and Latin、テスト")
        H.assertMapRoundTrips(text)
    }

    // MARK: Blocks

    func testAdjoiningMarginsCollapseIntoParagraphSpacing() throws {
        let text = try H.build("""
            <div id="outer"><p id="a">First</p><p id="b">Second</p></div>
            <div id="padded"><p id="c">Third</p></div>
            """, rules: [
                ("p", { $0.margin = .init(top: .points(10), right: .zero, bottom: .points(12), left: .zero) }),
                ("#b", { $0.margin.top = .points(20) }),
                ("#outer", { $0.margin.top = .points(30) }),
                ("#padded", { $0.margin.top = .points(4); $0.padding.top = .points(5) }),
            ])
        let first = try XCTUnwrap(H.paragraphStyle(text, at: 0))
        XCTAssertEqual(first.paragraphSpacingBefore, 30) // The div's margin and its first child's collapse.
        XCTAssertEqual(first.paragraphSpacing, 20) // max(12, 20)
        let second = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: "Second", in: text)))
        XCTAssertEqual(second.paragraphSpacingBefore, 0)
        XCTAssertEqual(second.paragraphSpacing, 12 + 5 + 10) // max(12, 4), then padding, then the child's margin.
        let third = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: "Third", in: text)))
        XCTAssertEqual(third.paragraphSpacing, 12)
    }

    func testHorizontalBoxesAccumulateIntoIndents() throws {
        let text = try H.build("""
            <blockquote><div class="box"><p>Quoted text</p></div></blockquote><p class="pct">Percent</p>
            """, rules: [
                ("blockquote", { $0.margin.left = .points(40); $0.margin.right = .points(40) }),
                (".box", { $0.padding.left = .points(10); $0.border.left = .init(width: 2, style: .solid); $0.margin.right = .points(7) }),
                ("p", { $0.textIndent = .points(15) }),
                (".pct", { $0.margin.left = .percent(10) }),
            ])
        let quoted = try XCTUnwrap(H.paragraphStyle(text, at: 0))
        XCTAssertEqual(quoted.headIndent, 40 + 2 + 10)
        XCTAssertEqual(quoted.firstLineHeadIndent, 52 + 15)
        XCTAssertEqual(quoted.tailIndent, -(40 + 7))
        let percent = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: "Percent", in: text)))
        XCTAssertEqual(percent.headIndent, 60) // 10% of the nominal 600-pt column.
        XCTAssertEqual(percent.firstLineHeadIndent, 75)
    }

    func testTextIndentAppliesToABlocksFirstLineOnly() throws {
        let text = try H.build("<div class='i'>Lead<p>Para</p>Tail</div>", rules: [(".i", { $0.textIndent = .points(20) })])
        XCTAssertEqual(text.string.string, "Lead\nPara\nTail")
        XCTAssertEqual(H.paragraphStyle(text, at: 0)?.firstLineHeadIndent, 20)
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "Para", in: text))?.firstLineHeadIndent, 20) // Inherited.
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "Tail", in: text))?.firstLineHeadIndent, 0)
    }

    func testDeepIndentationIsCapped() throws {
        let text = try H.build(String(repeating: "<blockquote>", count: 10) + "<p>Deep</p>" + String(repeating: "</blockquote>", count: 10))
        let style = try XCTUnwrap(H.paragraphStyle(text, at: 0))
        XCTAssertEqual(style.headIndent - style.tailIndent, 200, accuracy: 0.01)
    }

    func testAlignmentLineHeightSpacingHyphenationAndDirection() throws {
        let text = try H.build("""
            <p class="c">Centre</p><p class="j">Justify</p><p class="m">Multiple</p><p class="pt">Points</p>
            <p class="none">Plain</p><div dir="rtl"><p class="e">نهاية</p><p>بداية</p></div><p dir="auto">auto</p>
            """, rules: [
                (".c", { $0.textAlign = .center }), (".j", { $0.textAlign = .justify }),
                (".m", { $0.lineHeight = .multiple(1.5); $0.letterSpacing = 1.5 }),
                (".pt", { $0.lineHeight = .points(30) }), (".none", { $0.hyphens = .none; $0.lineHeight = .normal }),
                (".e", { $0.textAlign = .end }),
            ])
        func style(_ substring: String) throws -> NSParagraphStyle {
            try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: substring, in: text)))
        }
        XCTAssertEqual(try style("Centre").alignment, .center)
        XCTAssertEqual(try style("Justify").alignment, .justified)
        XCTAssertEqual(try style("Plain").alignment, .natural)
        let font = FontRegistry(publication: H.publication).font(for: ComputedStyle(fontFamilies: ["serif"], fontSize: 16))
        XCTAssertEqual(try style("Multiple").lineHeightMultiple, 1.5 * 16 / InlineStyling.naturalLineHeight(font), accuracy: 0.001)
        XCTAssertEqual(H.attribute(.kern, of: "Multiple", in: text) as? CGFloat, 1.5)
        XCTAssertEqual(try style("Points").minimumLineHeight, 30)
        XCTAssertEqual(try style("Points").maximumLineHeight, 30)
        XCTAssertEqual(try style("Plain").lineHeightMultiple, 0)
        XCTAssertEqual(try style("Centre").hyphenationFactor, 1) // The reader's default is `hyphens: auto`.
        XCTAssertEqual(try style("Plain").hyphenationFactor, 0)
        XCTAssertEqual(try style("نهاية").baseWritingDirection, .rightToLeft)
        XCTAssertEqual(try style("نهاية").alignment, .left) // `end` in right-to-left text.
        XCTAssertEqual(try style("بداية").alignment, .natural)
        XCTAssertEqual(try style("Centre").baseWritingDirection, .leftToRight)
        XCTAssertEqual(try style("auto").baseWritingDirection, .natural)
    }

    func testPageBreaksAndKeepWithNext() throws {
        let text = try H.build("""
            <h1>Title</h1><p>Intro</p><section class="chapter"><h2>Part</h2><p>Body</p></section>
            <p class="after">Before break</p><p>Forced</p><dl><dt>Term</dt><dd>Definition</dd></dl>
            """, rules: [
                (".chapter", { $0.breakBefore = .page; $0.margin.top = .points(24) }),
                (".after", { $0.breakAfter = .page }),
                ("p", { $0.margin = .init(top: .points(8), right: .zero, bottom: .points(8), left: .zero) }),
            ])
        func value(_ key: NSAttributedString.Key, _ substring: String) -> Bool {
            H.attribute(key, of: substring, in: text) as? Bool == true
        }
        XCTAssertFalse(value(.readerPageBreakBefore, "Title"))
        XCTAssertTrue(value(.readerKeepWithNext, "Title"))
        XCTAssertTrue(value(.readerPageBreakBefore, "Part"))
        XCTAssertTrue(value(.readerKeepWithNext, "Part"))
        XCTAssertFalse(value(.readerKeepWithNext, "Body"))
        XCTAssertFalse(value(.readerPageBreakBefore, "Body"))
        XCTAssertTrue(value(.readerPageBreakBefore, "Forced"))
        XCTAssertTrue(value(.readerKeepWithNext, "Term"))
        XCTAssertFalse(value(.readerKeepWithNext, "Definition"))
        // After a forced break the gap is the later paragraph's spacing before, so it survives at a page top.
        let part = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: "Part", in: text)))
        XCTAssertEqual(part.paragraphSpacingBefore, 24, accuracy: 0.01)
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "Intro", in: text))?.paragraphSpacing, 0)
    }

    func testLoneBlockAttachmentIsCentredUnlessEndAligned() throws {
        let rich = BuilderRecordingRich()
        let text = try H.build("""
            <p>Text <img src="picture.png" alt=""/> inline</p><img class="b" src="picture.png" alt=""/>
            <div class="r"><img class="b" src="picture.png" alt=""/></div><hr/>
            """, rich: rich, rules: [(".b", { $0.display = .block }), (".r", { $0.textAlign = .right })])
        let units = text.map.spans.filter { !$0.isExact && $0.sourceLength == 0 }
        XCTAssertEqual(units.count, 4)
        XCTAssertEqual(H.paragraphStyle(text, at: units[0].location)?.alignment, .natural)
        XCTAssertEqual(H.paragraphStyle(text, at: units[1].location)?.alignment, .center)
        XCTAssertEqual(H.paragraphStyle(text, at: units[2].location)?.alignment, .right)
        XCTAssertEqual(H.paragraphStyle(text, at: units[3].location)?.alignment, .center)
        XCTAssertEqual(rich.calls, ["image:img", "image:img", "image:img", "hr"])
        H.assertMapRoundTrips(text)
    }

    // MARK: Inline

    func testInlineAttributes() throws {
        let text = try H.build("""
            <p class="book">Coloured <span class="mark">marked</span> <u>under</u> <s>struck</s> x<sup>2</sup> H<sub>2</sub>O \
            <span class="up">straße</span> <span class="cap">two words</span> <span class="lo">LOW</span> \
            <span class="hide">ghost</span> <span lang="fr">bonjour</span> <span class="small">caps</span></p>
            """, rules: [
                (".book", { $0.color = .init(red: 0.5, green: 0, blue: 0) }),
                (".mark", { $0.backgroundColor = .init(red: 1, green: 1, blue: 0) }),
                (".up", { $0.textTransform = .uppercase }), (".cap", { $0.textTransform = .capitalize }),
                (".lo", { $0.textTransform = .lowercase }), (".hide", { $0.isHidden = true }),
                (".small", { $0.isSmallCaps = true }),
            ])
        XCTAssertEqual(text.string.string, "Coloured marked under struck x2 H2O STRASSE Two Words low ghost bonjour caps")
        let book = try XCTUnwrap(H.attribute(.foregroundColor, of: "Coloured", in: text) as? PlatformColor)
        XCTAssertEqual(book.cgColor.components?.first ?? 0, 0.5, accuracy: 0.01)
        XCTAssertNotNil(H.attribute(.backgroundColor, of: "marked", in: text))
        XCTAssertNil(H.attribute(.backgroundColor, of: "Coloured", in: text))
        XCTAssertEqual(H.attribute(.underlineStyle, of: "under", in: text) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(H.attribute(.strikethroughStyle, of: "struck", in: text) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(try XCTUnwrap(H.attribute(.baselineOffset, of: "2 H", in: text) as? CGFloat), 16 / 3, accuracy: 0.01)
        let sub = H.location(of: "2O", in: text)
        XCTAssertEqual(try XCTUnwrap(text.string.attribute(.baselineOffset, at: sub, effectiveRange: nil) as? CGFloat), -16 / 5, accuracy: 0.01)
        XCTAssertEqual(H.attribute(.foregroundColor, of: "ghost", in: text) as? PlatformColor, .clear)
        XCTAssertEqual(H.attribute(InlineStyling.languageKey, of: "bonjour", in: text) as? String, "fr")
        XCTAssertEqual(H.attribute(InlineStyling.languageKey, of: "Coloured", in: text) as? String, "en")
        let fonts = FontRegistry(publication: H.publication)
        XCTAssertEqual(H.attribute(.font, of: "caps", in: text) as? PlatformFont,
                       fonts.font(for: ComputedStyle(fontFamilies: ["serif"], fontSize: 16, isSmallCaps: true)))
        // A transform that changes the length maps the run as a whole.
        let strasse = H.location(of: "STRASSE", in: text)
        let span = try XCTUnwrap(text.map.spans.first { $0.location == strasse })
        XCTAssertFalse(span.isExact)
        XCTAssertEqual(span.sourceLength, 6)
        H.assertMapRoundTrips(text)
    }

    func testDarkAppearanceUsesThePalette() throws {
        let text = try H.build("<p class='book'>Text <span class='mark'>marked</span> <a href='two.xhtml'>link</a></p>", dark: true,
                               rules: [(".book", { $0.color = .init(red: 0.5, green: 0, blue: 0) }),
                                       (".mark", { $0.backgroundColor = .init(red: 1, green: 1, blue: 0) })])
        XCTAssertEqual(H.attribute(.foregroundColor, of: "Text", in: text) as? PlatformColor, ReaderPalette.text(dark: true))
        XCTAssertNil(H.attribute(.backgroundColor, of: "marked", in: text))
        XCTAssertEqual(H.attribute(.foregroundColor, of: "link", in: text) as? PlatformColor, ReaderPalette.link(dark: true))
    }

    func testSyntheticObliqueOnlyWithoutAnItalicFace() throws {
        let text = try H.build("<p><em>slanted</em></p>")
        XCTAssertNil(H.attribute(.obliqueness, of: "slanted", in: text)) // The system serif has an italic.
    }

    func testSyntheticFacesForFamiliesThatLackThem() throws {
        let georgia = CTFontCreateWithName("Georgia" as CFString, 12, nil)
        guard CTFontCopyPostScriptName(georgia) as String == "Georgia",
              let url = CTFontCopyAttribute(georgia, kCTFontURLAttribute) as? URL else { throw XCTSkip("Georgia is not installed") }
        var files = try Fixture.files()
        files["OPS/fonts/regular.ttf"] = try Data(contentsOf: url)
        let book = try EPUBPublication.open(data: Fixture.archive(files))
        let fonts = FontRegistry(publication: book)
        var report = SectionReport()
        fonts.register([CSSFontFace(family: "regular only", sources: ["OPS/fonts/regular.ttf"])], report: &report)
        let text = H.build(document: try H.document("<p class='face'><em>slant</em> <b>bold</b> <span class='g'>Small Caps</span></p>"),
                           rules: [(".face", { $0.fontFamilies = ["regular only"] }),
                                   (".g", { $0.fontFamilies = ["georgia"]; $0.isSmallCaps = true })],
                           publication: book, fonts: fonts)
        XCTAssertEqual(H.attribute(.obliqueness, of: "slant", in: text) as? CGFloat, 0.2)
        XCTAssertNil(H.attribute(.strokeWidth, of: "slant", in: text))
        XCTAssertEqual(H.attribute(.strokeWidth, of: "bold", in: text) as? CGFloat, -3)
        XCTAssertNil(H.attribute(.obliqueness, of: "bold", in: text))
        XCTAssertEqual(text.string.string, "slant bold SMALL CAPS")
        let capital = try XCTUnwrap(H.attribute(.font, of: "SMALL", in: text) as? PlatformFont)
        let small = try XCTUnwrap(H.attribute(.font, of: "MALL", in: text) as? PlatformFont)
        XCTAssertEqual(small.pointSize, capital.pointSize * 0.7, accuracy: 0.01)
        H.assertMapRoundTrips(text)
    }

    func testQuotesIsolatesAndWordBreaks() throws {
        let text = try H.build("""
            <p>He said <q>she said <q>no</q> twice</q>.</p><p lang="de"><q>Ja</q></p>\
            <p>a <span dir="rtl">ש b</span> c <bdi>d</bdi> <bdo dir="rtl">ef</bdo> long<wbr/>word</p>
            """)
        XCTAssertEqual(text.string.string,
                       "He said “she said ‘no’ twice”.\n„Ja“\na \u{2067}ש b\u{2069} c \u{2068}d\u{2069} \u{2067}\u{202E}ef\u{202C}\u{2069} long\u{200B}word")
        H.assertMapRoundTrips(text)
        // Generated characters have no span.
        let quote = H.location(of: "“", in: text)
        XCTAssertFalse(text.map.spans.contains { $0.location <= quote && quote < $0.location + $0.length })
    }

    // MARK: Links and notes

    func testLinksResolveInsideTheArchive() throws {
        let text = try H.build("""
            <p><a href="two.xhtml#start">internal</a> <a href="https://example.com/x">external</a> \
            <a href="../../escape.xhtml">escape</a> <a href="#here">here</a> <a id="here" name="n">anchor</a> \
            <a href="mailto:a@b.c">mail</a> <a class="own" href="two.xhtml">own colour</a></p>
            """, rules: [(".own", { $0.color = .init(red: 0, green: 0.5, blue: 0) })])
        func link(_ substring: String) -> ReaderLink? {
            (H.attribute(.link, of: substring, in: text) as? URL).flatMap(ReaderLink.init(url:))
        }
        XCTAssertEqual(link("internal"), .internal(href: "OPS/two.xhtml#start"))
        XCTAssertEqual(link("external"), .external("https://example.com/x"))
        XCTAssertEqual(link("escape"), .external("../../escape.xhtml"))
        XCTAssertEqual(link("here"), .internal(href: "OPS/one.xhtml#here"))
        XCTAssertEqual(link("mail"), .external("mailto:a@b.c"))
        XCTAssertNil(link("anchor"))
        XCTAssertEqual(H.attribute(.foregroundColor, of: "internal", in: text) as? PlatformColor, ReaderPalette.link(dark: false))
        let own = try XCTUnwrap(H.attribute(.foregroundColor, of: "own colour", in: text) as? PlatformColor)
        XCTAssertEqual(own.cgColor.components?[1] ?? 0, 0.5, accuracy: 0.01)
    }

    /// Hostile nesting: each note's text is captured once, in the innermost note holding it, so
    /// note content cannot grow with nesting depth times document size.
    func testNestedNotesAreCapturedOnceEach() throws {
        for type in ["endnote", "footnote"] {
            var body = ""
            for depth in 0..<190 {
                body += "<aside epub:type='\(type)' id='n\(depth)'>"
                    + String(repeating: "<p>A paragraph of note \(depth).</p>", count: 100)
            }
            body += String(repeating: "</aside>", count: 190) + "<p>After.</p>"
            let document = try H.document(body)
            let start = Date()
            let text = H.build(document: document)
            let elapsed = Date().timeIntervalSince(start)
            let sourceLength = document.nodes.reduce(0) { $0 + ($1.isText ? $1.utf16Length : 0) }
            let noteIDs = (0..<190).map { "n\($0)" }
            let noteLength = noteIDs.reduce(0) { $0 + (text.notes[$1]?.length ?? 0) }
            XCTAssertEqual(noteIDs.filter { text.notes[$0] != nil }.count, 190, type)
            XCTAssertLessThanOrEqual(noteLength, sourceLength * 2, "\(type): notes amplify their content")
            let outer = try XCTUnwrap(text.notes["n0"]?.string)
            XCTAssertTrue(outer.hasPrefix("A paragraph of note 0."), type)
            XCTAssertFalse(outer.contains("note 1."), "\(type): a nested note is its own note")
            XCTAssertTrue(text.notes["n189"]?.string.contains("note 189.") == true, type)
            XCTAssertLessThan(elapsed, 10, "\(type): nested notes took \(elapsed) s")
            XCTAssertEqual(text.string.string.hasSuffix("After."), true)
            if type == "footnote" { XCTAssertEqual(text.string.string, "After.") }
        }
    }

    func testNoteReferencesAndNotes() throws {
        let text = try H.build("""
            <p>Claim<a epub:type="noteref" href="#fn1">1</a>, role<a role="doc-noteref" href="notes.xhtml#n2">2</a>, \
            target<a href="#fn3">3</a>.</p>
            <aside epub:type="footnote" id="fn1"><p><a href="#fn1">1</a> The <em>first</em> note.</p><p>Second paragraph.</p></aside>
            <aside role="doc-footnote" id="fn3"><p id="fn3p">Third note.</p></aside>
            <p id="after">After the notes.</p>
            <section epub:type="endnotes"><ol><li id="en1" epub:type="endnote"><p>An endnote. <a epub:type="backlink" href="#ref">↩</a></p></li>
            <li id="en2"><aside epub:type="rearnote" id="en2n">Rear note.</aside></li></ol></section>
            """)
        func link(_ substring: String) -> ReaderLink? {
            (H.attribute(.link, of: substring, in: text) as? URL).flatMap(ReaderLink.init(url:))
        }
        XCTAssertEqual(link("1"), .note(href: "OPS/one.xhtml#fn1"))
        XCTAssertEqual(link("2"), .note(href: "OPS/notes.xhtml#n2"))
        XCTAssertEqual(link("3"), .note(href: "OPS/one.xhtml#fn3"))
        // Footnotes are hidden; endnotes stay in the flow.
        XCTAssertFalse(text.string.string.contains("first"))
        XCTAssertFalse(text.string.string.contains("Third"))
        XCTAssertTrue(text.string.string.contains("An endnote."))
        XCTAssertTrue(text.string.string.contains("Rear note."))
        XCTAssertEqual(text.notes["fn1"]?.string, "1 The first note.\nSecond paragraph.")
        XCTAssertNil(text.notes["fn1"]?.attribute(.link, at: 0, effectiveRange: nil)) // The note's own number.
        XCTAssertEqual(text.notes["fn3"]?.string, "Third note.")
        XCTAssertEqual(text.notes["fn3p"]?.string, "Third note.")
        XCTAssertEqual(text.notes["en1"]?.string, "An endnote.")
        XCTAssertEqual(text.notes["en2n"]?.string, "Rear note.")
        // A hidden note's id points at the next rendered character.
        XCTAssertEqual(text.anchors["fn1"], H.location(of: "After", in: text))
        XCTAssertEqual(text.anchors["fn3p"], H.location(of: "After", in: text))
        let note = try XCTUnwrap(text.notes["fn1"])
        let font = try XCTUnwrap(note.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        XCTAssertEqual(font.pointSize, 16)
        XCTAssertNotNil(note.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        H.assertMapRoundTrips(text)
    }

    // MARK: Lists

    func testListMarkersAndCounters() throws {
        let text = try H.build("""
            <ol start="3"><li>three</li><li value="10">ten</li><li>eleven</li></ol>
            <ol reversed=""><li>c</li><li>b</li><li>a</li></ol>
            <ul><li>disc<ul class="c"><li>circle</li></ul></li></ul>
            <ol class="alpha"><li>alpha</li></ol><ol class="roman" start="4"><li>roman</li></ol>
            <ol class="greek" start="2"><li>greek</li></ol><ol class="zero"><li>zero</li></ol>
            <ul class="string"><li>dash</li></ul><ul class="none"><li>none</li></ul><ol class="in"><li>inside</li></ol>
            """, rules: [
                (".c", { $0.listStyleType = .circle }), (".alpha", { $0.listStyleType = .upperAlpha }),
                (".roman", { $0.listStyleType = .lowerRoman }), (".greek", { $0.listStyleType = .lowerGreek }),
                (".zero", { $0.listStyleType = .decimalLeadingZero }), (".string", { $0.listStyleType = .string("– ") }),
                (".none", { $0.listStyleType = .none }), (".in", { $0.listStylePosition = .inside }),
                ("ol", { $0.padding.left = .points(40) }), ("ul", { $0.padding.left = .points(40) }),
            ])
        XCTAssertEqual(text.string.string.components(separatedBy: "\n"), [
            "3.\tthree", "10.\tten", "11.\televen", "3.\tc", "2.\tb", "1.\ta", "•\tdisc", "◦\tcircle", "A.\talpha",
            "iv.\troman", "β.\tgreek", "01.\tzero", "– \tdash", "none", "1. inside",
        ])
        // An outside marker hangs in the list's padding with a tab stop at the content edge.
        let style = try XCTUnwrap(H.paragraphStyle(text, at: 0))
        XCTAssertEqual(style.headIndent, 40)
        XCTAssertEqual(style.tabStops.map(\.location), [40])
        XCTAssertLessThan(style.firstLineHeadIndent, 40)
        XCTAssertGreaterThan(style.firstLineHeadIndent, 20)
        let nested = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: "circle", in: text)))
        XCTAssertEqual(nested.headIndent, 80)
        XCTAssertTrue(H.paragraphStyle(text, at: H.location(of: "inside", in: text))?.tabStops.isEmpty == true)
        // Markers are generated: no span.
        XCTAssertEqual(text.map.spans.first?.location, 3)
        H.assertMapRoundTrips(text)
    }

    func testListItemWithBlocksAndEmptyItems() throws {
        let text = try H.build("<ol><li><p>para</p><p>more</p></li><li></li><li>last</li></ol>")
        XCTAssertEqual(text.string.string, "1.\tpara\nmore\n2.\t\n3.\tlast")
        XCTAssertTrue(H.paragraphStyle(text, at: H.location(of: "more", in: text))?.tabStops.isEmpty == true)
    }

    // MARK: Ruby

    func testRubyAnnotatesBaseText() throws {
        let text = try H.build("<p>前<ruby>漢<rp>(</rp><rt>kan</rt><rp>)</rp>字<rt>ji</rt></ruby>後</p>", rootAttributes: "lang='ja'")
        XCTAssertEqual(text.string.string, "前漢字後")
        let first = text.string.attribute(InlineStyling.rubyKey, at: 1, effectiveRange: nil)
        let second = text.string.attribute(InlineStyling.rubyKey, at: 2, effectiveRange: nil)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNil(text.string.attribute(InlineStyling.rubyKey, at: 0, effectiveRange: nil))
        XCTAssertNil(text.string.attribute(InlineStyling.rubyKey, at: 3, effectiveRange: nil))
        let annotation = first as! CTRubyAnnotation
        XCTAssertEqual(CTRubyAnnotationGetTextForPosition(annotation, .before) as String?, "kan")
        H.assertMapRoundTrips(text)
    }

    // MARK: Rich content and fallbacks

    func testRichContentIsInsertedAsUnits() throws {
        let rich = BuilderRecordingRich()
        let text = try H.build("""
            <p>Before <svg xmlns="http://www.w3.org/2000/svg" id="art"><g id="inner"/></svg> and \
            <math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>.</p>\
            <object data="picture.png" type="image/png">fallback</object>\
            <object data="clip.mp4" type="video/mp4"><p>Video fallback</p></object><embed src="thing.swf"/>\
            <p><img src="https://example.com/remote.png" alt=""/><img src="data:image/png;base64,AAAA" alt=""/></p>
            """, rich: rich)
        XCTAssertEqual(rich.calls, ["svg", "math", "image:object", "image:img", "image:img"])
        XCTAssertEqual(text.report.unsupportedElements, ["object": 1, "embed": 1])
        XCTAssertEqual(text.report.remoteResourcesRefused, 1)
        XCTAssertEqual(text.report.unreadableResources, 1)
        XCTAssertTrue(text.string.string.contains("Video fallback"))
        XCTAssertEqual(text.string.string.components(separatedBy: "fallback").count, 2) // Only the video's.
        let svg = try XCTUnwrap(text.map.spans.first { $0.node == text.document.element(id: "art")!.order })
        XCTAssertEqual(text.anchors["inner"], svg.location)
        XCTAssertEqual(text.anchors["art"], svg.location)
        H.assertMapRoundTrips(text)
    }

    func testOneColumnTablesFlowAsText() throws {
        let text = try H.build("<table><tr><td><p>Callout</p><ul><li>point</li></ul></td></tr><tr><td>More</td></tr></table>",
                               rules: [("ul", { $0.padding.left = .points(40) })])
        XCTAssertEqual(text.string.string, "Callout\n•\tpoint\nMore")
        H.assertMapRoundTrips(text)
    }

    func testTableFallbackAndRenderedCells() throws {
        let table = """
            <table id="t"><caption>Caption</caption><thead><tr><th>Name</th><th>Value</th></tr></thead>
            <tbody><tr><td>a <em>b</em></td><td><p>one</p><p>two</p></td></tr><tr><td/><td id="cell">only</td></tr></tbody></table><p>After</p>
            """
        let fallback = try H.build(table)
        XCTAssertEqual(fallback.string.string, "Caption\nName\tValue\na b\tone two\n\tonly\nAfter")
        XCTAssertEqual(fallback.anchors["cell"], H.location(of: "only", in: fallback))
        H.assertMapRoundTrips(fallback)
        let rich = BuilderRecordingRich(rendersTables: true)
        let rendered = try H.build(table, rich: rich)
        XCTAssertEqual(rendered.string.string, "Name | Value | a b | one\ntwo |  | only\nAfter")
        let unit = try XCTUnwrap(rendered.map.spans.first)
        XCTAssertFalse(unit.isExact)
        XCTAssertEqual(unit.node, rendered.document.element(id: "t")!.order)
        XCTAssertEqual(rendered.anchors["cell"], 0)
        // The break after the table continues its last row's attributes, not the attachment.
        let afterTable = H.location(of: "\nAfter", in: rendered)
        XCTAssertNil(rendered.string.attribute(.attachment, at: afterTable, effectiveRange: nil))
        // A cell's emphasis is rendered, not just its text.
        let em = (rendered.string.string as NSString).range(of: "b |").location
        let font = try XCTUnwrap(rendered.string.attribute(.font, at: em, effectiveRange: nil) as? PlatformFont)
        XCTAssertTrue(CTFontGetSymbolicTraits(font as CTFont).contains(.traitItalic))
        H.assertMapRoundTrips(rendered)
    }

    func testScriptsMediaFormsAndHiddenContent() throws {
        let text = try H.build("""
            <p id="first">Visible<script>alert(1)</script></p><noscript><p>No script</p></noscript>
            <video src="v.mp4"><source src="v.webm"/>Your reader cannot play video.</video>
            <audio/><iframe src="x.html">frame text</iframe><canvas>Canvas fallback</canvas>
            <form><label>Name</label><input type="text"/><input type="hidden"/><button>Go</button><select><option>o</option></select></form>
            <div class="gone"><p id="hidden">Hidden</p></div><p id="next">Next</p><p hidden="">attr</p>
            """, head: "<script src='a.js'></script>", rules: [(".gone", { $0.display = .none }), ("form", { $0.display = .block })])
        XCTAssertEqual(text.string.string, "Visible\nNo script\nYour reader cannot play video. Canvas fallback\nNameGo\nNext")
        XCTAssertEqual(text.report.scriptsRefused, 2)
        XCTAssertEqual(text.report.unsupportedElements, ["video": 1, "audio": 1, "iframe": 1, "canvas": 1, "form": 1,
                                                         "input": 1, "button": 1, "select": 1])
        XCTAssertEqual(text.anchors["hidden"], H.location(of: "Next", in: text))
        XCTAssertEqual(text.anchors["first"], 0)
        H.assertMapRoundTrips(text)
    }

    func testMathFallbackSkipsAnnotations() throws {
        let rich = FallbackMath()
        let text = try H.build("""
            <p>Let <math xmlns="http://www.w3.org/1998/Math/MathML"><semantics><mrow><mi>x</mi><mo>=</mo><mn>1</mn></mrow>\
            <annotation encoding="application/x-tex">x=1</annotation></semantics></math>.</p>
            """, rich: rich)
        XCTAssertEqual(text.string.string, "Let x=1.")
    }

    func testEPUBSwitchPrefersMathML() throws {
        let rich = BuilderRecordingRich()
        let text = try H.build("""
            <p><epub:switch><epub:case required-namespace="http://www.w3.org/1998/Math/MathML">\
            <math xmlns="http://www.w3.org/1998/Math/MathML"><mi>y</mi></math></epub:case>\
            <epub:default>y (image)</epub:default></epub:switch></p>
            """, rich: rich)
        XCTAssertEqual(rich.calls, ["math"])
        XCTAssertFalse(text.string.string.contains("image"))
    }

    func testAttachmentParagraphsNeverGetAMaximumLineHeight() throws {
        let text = try H.build("<p class='fixed'>Text <img src='picture.png' alt=''/> more</p><p class='fixed'>Plain</p>"
                               + "<p class='m'>x <img src='picture.png' alt=''/></p>", rich: BuilderRecordingRich(), rules: [
            (".fixed", { $0.lineHeight = .points(20) }), (".m", { $0.lineHeight = .multiple(1.5) }),
        ])
        let withImage = try XCTUnwrap(H.paragraphStyle(text, at: 0))
        XCTAssertEqual(withImage.maximumLineHeight, 0)
        XCTAssertEqual(withImage.minimumLineHeight, 20)
        XCTAssertEqual(H.paragraphStyle(text, at: H.location(of: "Plain", in: text))?.maximumLineHeight, 20)
        let multiple = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: "x ", in: text)))
        XCTAssertEqual(multiple.maximumLineHeight, 0)
        XCTAssertEqual(multiple.lineHeightMultiple, 0)
        XCTAssertEqual(multiple.minimumLineHeight, 24)
    }

    func testRecoveredHTMLSendsFormulasAndDrawingsToTheFactory() throws {
        let data = try Fixture.epub(overrides: [
            "OPS/one.xhtml": "<html><body><p>Let <math><mi>x</mi></math> be <svg><rect/></svg><p>unclosed</body></html>",
        ])
        let book = try EPUBPublication.open(data: data)
        let rich = BuilderRecordingRich()
        let text = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 0, typography: NativeTypography(),
                                                            fonts: FontRegistry(publication: book), rich: rich))
        XCTAssertTrue(text.report.recoveredAsHTML)
        XCTAssertEqual(rich.calls, ["math", "svg"])
        XCTAssertEqual(text.map.spans.filter { !$0.isExact && $0.sourceLength == 0 }.count, 2)
    }

    func testFloatsWordSpacingAndBreakInside() throws {
        let rich = BuilderRecordingRich()
        let text = try H.build("""
            <img class="l" src="picture.png" alt=""/><img class="r" src="picture.png" alt=""/>
            <p class="w">wide words here</p>
            <div class="keep"><p>One</p><h3>Two</h3><p>Three</p></div><p>Four</p>
            """, rich: rich, rules: [
                ("img", { $0.display = .block }), (".l", { $0.float = .left }), (".r", { $0.float = .right }),
                (".w", { $0.wordSpacing = 4; $0.letterSpacing = 1 }), (".keep", { $0.breakInside = .avoid }),
            ])
        XCTAssertEqual(H.paragraphStyle(text, at: 0)?.alignment, .left)
        XCTAssertEqual(H.paragraphStyle(text, at: 2)?.alignment, .right)
        XCTAssertEqual(H.attribute(.kern, of: " words", in: text) as? CGFloat, 5)
        XCTAssertEqual(H.attribute(.kern, of: "words", in: text) as? CGFloat, 1)
        func keeps(_ substring: String) -> Bool { H.attribute(.readerKeepWithNext, of: substring, in: text) as? Bool == true }
        XCTAssertTrue(keeps("One"))
        XCTAssertTrue(keeps("Two"))
        XCTAssertFalse(keeps("Three"))
        XCTAssertFalse(keeps("Four"))
        H.assertMapRoundTrips(text)
    }

    func testOutOfFlowBoxesAreLeftOutOfReflowedText() throws {
        let text = try H.build("<p>Figure<span class='label' id='l'>x+y</span></p><h1 class='label'>Title page</h1><p id='n'>Next</p>",
                               rules: [(".label", { $0.isOutOfFlow = true })])
        XCTAssertEqual(text.string.string, "Figure\nNext")
        XCTAssertEqual(text.anchors["l"], H.location(of: "Next", in: text))
        let fixed = try EPUBPublication.open(data: Fixture.rendering(.fixedLayout))
        let document = try ContentDocument.parse(fixed.data(for: fixed.spine[0].resource), path: fixed.spine[0].resource.path)
        let page = H.build(document: document, rules: [("h1", { $0.isOutOfFlow = true })], publication: fixed)
        XCTAssertTrue(page.string.string.hasPrefix("Fixed one"))
    }

    func testSwitchBranchesAnchorInDocumentOrder() throws {
        let text = try H.build("""
            <p><epub:switch><epub:case required-namespace="http://www.w3.org/1998/Math/MathML">\
            <math xmlns="http://www.w3.org/1998/Math/MathML" id="m"><mi>y</mi></math></epub:case>\
            <epub:default><span id="d">y</span></epub:default></epub:switch> after</p>
            """, rich: BuilderRecordingRich())
        XCTAssertEqual(text.anchors["m"], 0)
        XCTAssertEqual(text.anchors["d"], 1)
    }

    // MARK: Reports, anchors, titles and withheld sections

    func testReportFlagsTitleAndAnchors() throws {
        let text = try H.build("<h1 id='top'>  A <em>title</em> </h1><p id='v'>vertical</p><div id='empty'></div>",
                               head: "<title>\n  The   Title \n</title>", rules: [("html", { $0.writingMode = .verticalRL })])
        XCTAssertEqual(text.title, "The Title")
        XCTAssertTrue(text.report.verticalWritingFlattened)
        XCTAssertFalse(text.report.fixedLayoutReflowed)
        XCTAssertEqual(text.anchors["top"], 0)
        XCTAssertEqual(text.anchors["v"], H.location(of: "vertical", in: text))
        XCTAssertEqual(text.anchors["empty"], text.string.length)
        XCTAssertNil(try H.build("<p>x</p>", head: "<title> </title>").title)
    }

    func testFixedLayoutRecoveredHTMLAndWithheldSections() throws {
        let fixed = try EPUBPublication.open(data: Fixture.rendering(.fixedLayout))
        let fixedText = SectionBuilder.build(SectionBuildRequest(publication: fixed, spineIndex: 0, typography: NativeTypography(),
                                                                 fonts: FontRegistry(publication: fixed), rich: PlaceholderRichContent()))
        XCTAssertTrue(fixedText.report.fixedLayoutReflowed)
        XCTAssertTrue(fixedText.string.string.hasPrefix("Fixed one"))

        let data = try Fixture.epub(overrides: [
            "OPS/one.xhtml": "<html><body><p>Unclosed <b>bold</p><p>next<a epub:type='noteref' href='#n'>1</a></p><aside epub:type='footnote' id='n'>Note</aside></body></html>",
            "OPS/two.xhtml": "<?xml version='1.0'?><!DOCTYPE html [<!ENTITY boom 'x'>]><html><body>&boom;</body></html>",
        ])
        let book = try EPUBPublication.open(data: data)
        func build(_ index: Int) -> SectionText {
            SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: index, typography: NativeTypography(),
                                                     fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
        }
        let recovered = build(0)
        XCTAssertTrue(recovered.report.recoveredAsHTML)
        XCTAssertEqual(recovered.string.string, "Unclosed bold\nnext1")
        XCTAssertEqual(recovered.notes["n"]?.string, "Note")
        XCTAssertEqual((recovered.string.attribute(.link, at: recovered.string.length - 1, effectiveRange: nil) as? URL)
            .flatMap(ReaderLink.init(url:)), .note(href: "OPS/one.xhtml#n"))
        H.assertMapRoundTrips(recovered)
        let refused = build(1)
        XCTAssertTrue(refused.report.withheld)
        XCTAssertEqual(refused.string.string, "This section could not be shown.")
        XCTAssertTrue(refused.map.spans.isEmpty)
    }

    func testSectionsOfTheFixtureBuildWithTheirTitles() throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        let text = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: 1, typography: NativeTypography(),
                                                            fonts: FontRegistry(publication: book), rich: PlaceholderRichContent()))
        XCTAssertEqual(text.title, "Second Chapter")
        XCTAssertEqual(text.href, "OPS/two.xhtml")
        XCTAssertTrue(text.string.string.hasPrefix("Second Chapter\nThe unique destination passage lives here.\n"))
        XCTAssertEqual(text.anchors["start"], 0)
        H.assertMapRoundTrips(text)
    }

    // MARK: Text map

    func testMapRoundTripsOverMixedContent() throws {
        let text = try H.build("""
            <section id="s"><h2>Heading <small>small</small></h2>
            <p>Text with   <a href="#s">a link</a>,\n<em>emphasis</em>, <q>quotes</q> and\tbreaks<br/>\n here.</p>
            <ul><li>One <b>bold</b></li><li><p>Two</p></li></ul><pre>  code\n\n  more</pre>
            <blockquote><p dir="rtl">مرحبا <span dir="ltr">world</span></p></blockquote>
            <p><ruby>字<rt>ji</rt></ruby> <span class="up">upper ß</span></p></section>
            """, rules: [(".up", { $0.textTransform = .uppercase })])
        H.assertMapRoundTrips(text)
        // Every source character is either mapped or lies in collapsed whitespace or generated-only content.
        let p = try XCTUnwrap(text.document.nodes.first { $0.isText && $0.text.hasPrefix("Text with") })
        XCTAssertEqual(text.map.location(of: DOMPosition(p, 0)), H.location(of: "Text with", in: text))
        XCTAssertEqual(text.map.location(of: DOMPosition(p, 9)), H.location(of: " a link", in: text))
        XCTAssertEqual(text.map.location(of: DOMPosition(p, 11)), H.location(of: " a link", in: text))
        let position = try XCTUnwrap(text.map.position(at: H.location(of: "a link", in: text) + 2, in: text.document))
        XCTAssertEqual(position.node.text, "a link")
        XCTAssertEqual(position.offset, 2)
    }

    // MARK: Performance and concurrency

    func testMegabyteChapterBuildsQuickly() throws {
        var body = "", index = 0
        while body.utf8.count < 1_000_000 {
            body += "<p id='p\(index)'>Lorem ipsum <em>dolor</em> sit amet, <a href='#p0'>consectetur</a> adipiscing elit, sed do "
                + "eiusmod tempor incididunt ut <span class='x'>labore et dolore</span> magna aliqua. Ut enim ad minim veniam.</p>\n"
            index += 1
        }
        let document = try H.document(body)
        let start = Date()
        let text = H.build(document: document)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(text.anchors.count, index)
        XCTAssertLessThan(text.map.spans.count, index * 8)
        XCTAssertLessThan(elapsed, 4, "1 MB chapter took \(elapsed) s")
        print("SectionBuilder: 1 MB chapter (\(index) paragraphs) in \(Int(elapsed * 1000)) ms")
    }

    func testSectionsBuildConcurrently() throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        let fonts = FontRegistry(publication: book)
        let results = Results(count: 32)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let text = SectionBuilder.build(SectionBuildRequest(publication: book, spineIndex: index % 2, typography: NativeTypography(),
                                                                fonts: fonts, rich: PlaceholderRichContent()))
            results.set(index, text.string.string)
        }
        let values = results.values
        for index in values.indices { XCTAssertEqual(values[index], values[index % 2]) }
        XCTAssertEqual(values[0]?.hasPrefix("First Chapter\nOpening words are visible.\n"), true)
    }
}

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: String) { lock.withLock { storage[index] = value } }
    var values: [String?] { lock.withLock { storage } }
}

/// A factory whose MathML is unsupported, so the builder falls back to the formula's text.
private struct FallbackMath: RichContentFactory {
    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? { nil }
    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        NSAttributedString(string: "—")
    }
}
