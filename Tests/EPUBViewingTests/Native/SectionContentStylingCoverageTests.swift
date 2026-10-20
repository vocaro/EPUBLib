import CoreText
import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Inline styling that changes a section's characters or their attributes: `text-transform`,
/// small capitals, colors, backgrounds, decorations and links.
final class SectionContentStylingCoverageTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    private let upper: [H.Rule] = [(".u", { $0.textTransform = .uppercase })]
    private let lower: [H.Rule] = [(".l", { $0.textTransform = .lowercase })]
    private let capital: [H.Rule] = [(".c", { $0.textTransform = .capitalize })]

    // MARK: text-transform

    func testCapitalizeRaisesTheFirstLetterOfEachWordAcrossInlineBoundaries() throws {
        let text = try H.build("<p class='c'>hello <b>wor</b>ld it's o'neil <i>é</i>cole 1st «quoted» (paren) ALREADY</p>", rules: capital)
        // CSS Text 3 section 2.1: the first typographic letter unit of each word; a word may span elements.
        XCTAssertEqual(text.string.string, "Hello World It's O'neil École 1st «Quoted» (Paren) ALREADY")
        S.assertTextMapContracts(text, sameCharacters: false)
    }

    func testCapitalizeStartsAfreshInEachBlockAndAfterGeneratedText() throws {
        let text = try H.build("<div class='c'><p>one</p><p>two<br/>three</p><ol><li>four</li></ol><p><q>five</q> x<img src='picture.png' alt='i'/>six</p></div>",
                               rules: capital)
        XCTAssertEqual(S.paragraphs(text), ["One", "Two\u{2028}Three", "1.\tFour", "“Five” X[i]Six"])
    }

    func testUppercaseAndLowercaseAreTailoredToTheLanguage() throws {
        // CSS Text 3 section 2.1.1: case mappings are language-sensitive (Turkish dotted i, Greek tonos, final sigma).
        XCTAssertEqual(try H.build("<p class='u' lang='tr'>istanbul ılık</p>", rules: upper).string.string, "İSTANBUL ILIK")
        XCTAssertEqual(try H.build("<p class='u'>istanbul</p>", rules: upper).string.string, "ISTANBUL")
        XCTAssertEqual(try H.build("<p class='l' lang='tr'>İSTANBUL ILIK</p>", rules: lower).string.string, "istanbul ılık")
        XCTAssertEqual(try H.build("<p class='u' lang='el'>άλφα</p>", rules: upper).string.string, "ΑΛΦΑ")
        XCTAssertEqual(try H.build("<p class='l'>ΌΣΟΣ ΣΟΦΟΣ</p>", rules: lower).string.string, "όσος σοφος")
    }

    func testATransformThatChangesLengthMapsOnlyItsExpandedGraphemeAndLeavesNeighboursExact() throws {
        let text = try H.build("<p>ab <span class='u'>straße</span> cd</p>", rules: upper)
        XCTAssertEqual(text.string.string, "ab STRASSE cd")
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "ab straße cd")
        let source = try XCTUnwrap(S.textNode("straße", in: text))
        let spans = text.map.spans.filter { $0.node == source.order }
        XCTAssertEqual(spans.map { [$0.location, $0.length, $0.offset, $0.sourceLength] }, [[3, 4, 0, 4], [7, 2, 4, 1], [9, 1, 5, 1]])
        XCTAssertEqual(spans.map(\.isExact), [true, false, true])
        for offset in 0...4 { XCTAssertEqual(text.map.location(of: DOMPosition(source, offset)), 3 + offset, "offset \(offset)") }
        XCTAssertEqual(text.map.location(of: DOMPosition(source, 5)), 9)
        XCTAssertEqual(text.map.location(of: DOMPosition(source, 6), isEnd: true), 10)
        XCTAssertEqual(text.map.position(at: 8, in: text.document), DOMPosition(source, 4))
        XCTAssertEqual(text.map.endPosition(at: 8, in: text.document), DOMPosition(source, 5))
        XCTAssertEqual(text.mappedText(in: 7..<8), "ß")
        XCTAssertEqual(text.mappedText(in: 8..<9), "ß")
        XCTAssertEqual(text.mappedText(in: 7..<9), "ß")
        XCTAssertEqual(text.mappedText(in: 6..<10), "aße")
        S.assertTextMapContracts(text, sameCharacters: false)
    }

    func testFullCaseMappingsOfLigaturesAndSpecialLetters() throws {
        let text = try H.build("<p class='u'>ﬁn ŉ ǰ ß ﬃ</p><p>after</p>", rules: upper)
        XCTAssertEqual(S.paragraphs(text), ["FIN ʼN J\u{30C} SS FFI", "after"])
        S.assertTextMapContracts(text, sameCharacters: false)
        let after = try XCTUnwrap(S.textNode("after", in: text))
        XCTAssertEqual(text.map.location(of: DOMPosition(after, 2)), H.location(of: "after", in: text) + 2)
    }

    func testTransformsLeaveAstralAndCombiningCharactersWhole() throws {
        let text = try H.build("<p class='u'>a\u{301}b 😀c 𐐨</p>", rules: upper)
        XCTAssertEqual(text.string.string, "A\u{301}B 😀C 𐐀") // Deseret small long i has an astral capital.
        S.assertTextMapContracts(text, sameCharacters: false)
    }

    func testTransformsFromTheStylesheetInheritAndNoneRestores() throws {
        let text = try S.styled("""
            <h1>Chapter <span class="keep">one</span> <em>title</em></h1><p class="low">SHOUT <b>LOUD</b></p><p class="cap">the end</p>
            """, css: "h1 { text-transform: uppercase } .keep { text-transform: none } .low { text-transform: lowercase } "
                + ".cap { text-transform: capitalize }")
        XCTAssertEqual(S.paragraphs(text), ["CHAPTER one TITLE", "shout loud", "The End"])
        S.assertTextMapContracts(text, sameCharacters: false)
    }

    // MARK: Small capitals

    func testSmallCapitalsKeepTheBooksCharactersWhenTheFontHasThem() throws {
        let text = try S.styled("<p>It was <span style='font-variant: small-caps'>the Best of Straße</span>, <span style='font-variant-caps: all-small-caps'>NASA</span>.</p>")
        let serif = ComputedStyle(fontFamilies: ["serif"], fontSize: 16, isSmallCaps: true)
        guard !FontRegistry(publication: H.publication).needsSyntheticSmallCaps(for: serif) else {
            throw XCTSkip("the system serif has no small capitals here")
        }
        XCTAssertEqual(text.string.string, "It was the Best of Straße, NASA.")
        XCTAssertNotEqual(S.font("the Best", in: text), S.font("It was", in: text))
        S.assertTextMapContracts(text)
    }

    func testSynthesizedSmallCapitalsLeaveThePassageTextInTheBooksOwnCase() throws {
        // A font without small capitals shows lower-case letters as smaller capitals. That is how they are drawn;
        // the passage text (Copy, `EPUBSelection.text`) is "the book's own characters", as a browser's is.
        let style = ComputedStyle(fontFamilies: ["georgia"], fontSize: 16, isSmallCaps: true)
        guard FontRegistry(publication: H.publication).needsSyntheticSmallCaps(for: style) else {
            throw XCTSkip("needs an installed family without small capitals (Georgia)")
        }
        let text = try H.build("<p><span class='sc'>It was</span> the best of times.</p>",
                               rules: [(".sc", { $0.fontFamilies = ["georgia"]; $0.isSmallCaps = true })])
        XCTAssertEqual(text.string.string, "IT WAS the best of times.")
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "It was the best of times.")
    }

    // MARK: Colors, backgrounds and decorations

    func testInlineBackgroundsNestAndEndWithTheirElement() throws {
        let yellow: [H.Rule] = [(".y", { $0.backgroundColor = .init(red: 1, green: 1, blue: 0) }),
                                (".g", { $0.backgroundColor = .init(red: 0, green: 1, blue: 0) }),
                                (".t", { $0.backgroundColor = .init(red: 1, green: 0, blue: 0, alpha: 0) })]
        let text = try H.build("<p>plain <span class='y'>yellow <b>inner</b> <span class='g'>green</span> <span class='t'>clear</span></span> after</p>"
                               + "<p><span class='y'>one</span><span>two</span></p>", rules: yellow)
        func background(_ word: String) -> [CGFloat]? {
            (H.attribute(.backgroundColor, of: word, in: text) as? PlatformColor)?.cgColor.components.map { Array($0.prefix(3)) }
        }
        XCTAssertNil(background("plain"))
        XCTAssertEqual(background("yellow"), [1, 1, 0])
        XCTAssertEqual(background("inner"), [1, 1, 0])
        XCTAssertEqual(background("green"), [0, 1, 0])
        XCTAssertEqual(background("clear"), [1, 1, 0]) // A transparent background shows the one behind it.
        XCTAssertNil(background("after"))
        XCTAssertEqual(background("one"), [1, 1, 0])
        XCTAssertNil(background("two"), "a background ends with its element")
    }

    func testBookColorsApplyInLightAppearanceAndThePaletteInDark() throws {
        let rules: [H.Rule] = [(".red", { $0.color = .init(red: 1, green: 0, blue: 0) }), (".hid", { $0.isHidden = true }),
                               (".mark", { $0.backgroundColor = .init(red: 1, green: 1, blue: 0) })]
        let body = "<p class='red'>red <span class='hid'>hidden</span> <a href='two.xhtml'>link</a> <span class='mark'>marked</span> <u>under</u></p>"
        let light = try H.build(body, rules: rules), dark = try H.build(body, dark: true, rules: rules)
        XCTAssertEqual(light.string.string, dark.string.string)
        XCTAssertEqual((H.attribute(.foregroundColor, of: "red", in: light) as? PlatformColor)?.cgColor.components?.first, 1)
        XCTAssertEqual(H.attribute(.foregroundColor, of: "red", in: dark) as? PlatformColor, ReaderPalette.text(dark: true))
        XCTAssertEqual(H.attribute(.foregroundColor, of: "hidden", in: light) as? PlatformColor, .clear)
        XCTAssertEqual(H.attribute(.foregroundColor, of: "hidden", in: dark) as? PlatformColor, .clear)
        XCTAssertEqual(H.attribute(.foregroundColor, of: "link", in: light) as? PlatformColor, ReaderPalette.link(dark: false))
        XCTAssertEqual(H.attribute(.foregroundColor, of: "link", in: dark) as? PlatformColor, ReaderPalette.link(dark: true))
        XCTAssertNotNil(H.attribute(.backgroundColor, of: "marked", in: light))
        XCTAssertNil(H.attribute(.backgroundColor, of: "marked", in: dark))
        XCTAssertNotNil(H.attribute(.underlineStyle, of: "under", in: dark))
        XCTAssertEqual(light.map, dark.map)
    }

    func testLetterSpacingAndWordSpacingFromTheStylesheet() throws {
        let text = try S.styled("<p style='letter-spacing: 2px'>wide <span style='letter-spacing: normal'>normal</span></p>"
                                + "<p style='word-spacing: 4px'>two words</p>")
        XCTAssertEqual(H.attribute(.kern, of: "wide", in: text) as? CGFloat, 2)
        XCTAssertNil(H.attribute(.kern, of: "normal", in: text))
        XCTAssertNil(H.attribute(.kern, of: "two", in: text))
        XCTAssertEqual(H.attribute(.kern, of: " words", in: text) as? CGFloat, 4)
        // Spaces styled apart from their words still map exactly.
        S.assertTextMapContracts(text)
    }

    func testOnlyLinksWithATargetLookLikeLinks() throws {
        let text = try H.build("<p><a href='two.xhtml'>linked</a> <a>bare</a> <a id='x' name='y'>anchor</a> <a href='https://example.com'>out</a></p>")
        XCTAssertEqual(H.attribute(.foregroundColor, of: "linked", in: text) as? PlatformColor, ReaderPalette.link(dark: false))
        XCTAssertNotNil(H.attribute(.underlineStyle, of: "linked", in: text))
        XCTAssertNotNil(H.attribute(.underlineStyle, of: "out", in: text))
        for word in ["bare", "anchor"] {
            XCTAssertEqual(H.attribute(.foregroundColor, of: word, in: text) as? PlatformColor, ReaderPalette.text(dark: false), word)
            XCTAssertNil(H.attribute(.underlineStyle, of: word, in: text), word)
            XCTAssertNil(H.attribute(.link, of: word, in: text), word)
        }
    }

    func testSyntheticSmallCapsExpansionKeepsAuthoredCopyOffsetsAndSmallerCapitalGlyphs() throws {
        let style = ComputedStyle(fontFamilies: ["georgia"], fontSize: 16, isSmallCaps: true)
        guard FontRegistry(publication: H.publication).needsSyntheticSmallCaps(for: style) else {
            throw XCTSkip("needs an installed family without small capitals (Georgia)")
        }
        let text = try H.build("<p><span class='sc'>It was Straße.</span> After.</p>",
                               rules: [(".sc", { $0.fontFamilies = ["georgia"]; $0.isSmallCaps = true })])
        XCTAssertEqual(text.string.string, "IT WAS STRASSE. After.")
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "It was Straße. After.")
        let small = try XCTUnwrap(S.font("T", in: text)), capital = try XCTUnwrap(S.font("I", in: text))
        XCTAssertLessThan(small.pointSize, capital.pointSize, "synthesized small-cap styling is retained")
        let ss = H.location(of: "SS", in: text)
        let source = try XCTUnwrap(S.textNode("It was Straße.", in: text))
        XCTAssertEqual(text.map.position(at: ss + 1, in: text.document), DOMPosition(source, 11))
        XCTAssertEqual(text.map.endPosition(at: ss + 1, in: text.document), DOMPosition(source, 12))
        XCTAssertEqual(text.mappedText(in: ss..<(ss + 2)), "ß")
        XCTAssertEqual(text.mappedText(in: 1..<6), "t was")
        let start = try XCTUnwrap(text.map.position(at: ss, in: text.document))
        let end = try XCTUnwrap(text.map.endPosition(at: ss + 2, in: text.document))
        let cfi = EPUBCFI.localPath(from: start, to: end, in: text.document)
        let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: cfi, in: text.document))
        XCTAssertEqual(resolved.start, start); XCTAssertEqual(resolved.end, end)
        XCTAssertEqual(text.mappedText(in: text.map.location(of: resolved.start)..<text.map.location(of: resolved.end, isEnd: true)), "ß")
        XCTAssertEqual(TextSearch.matches(of: "Straße", in: text.document, locale: "en").count, 1)
        S.assertTextMapContracts(text, sameCharacters: false)
    }
}
