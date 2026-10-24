import CoreGraphics
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

/// `::first-letter` (CSS Pseudo-Elements 4 §2.2, CSS 2 §5.12.2), styled in line or floated as a
/// drop cap from the book's own characters, and `::first-line`, which is disclosed instead
/// (#567). Built through the whole pipeline.
final class FirstLetterTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    private static let dropCap = "p::first-letter { float: left; font-size: 3em; font-weight: bold }"

    private func size(_ substring: String, in text: SectionText) -> CGFloat? {
        S.font(substring, in: text).map { CTFontGetSize($0 as CTFont) }
    }

    // MARK: Which characters

    func testTheFirstLetterIsTheFirstLetterNumberOrSymbolWithThePunctuationAroundIt() {
        // CSS Pseudo-Elements 4 §2.2.1: (P (Zs|P)*)? (L|N|S) ((Zs|P−(Ps|Pd))* (P−(Ps|Pd)))?
        func extent(_ text: String, afterPunctuation: Bool = false) -> FirstLetterText.Extent {
            let units = Array(text.utf16)
            return FirstLetterText.extent(units, 0..<units.count, afterPunctuation: afterPunctuation)
        }
        func letter(_ text: String) -> String? {
            guard case .letter(let end) = extent(text) else { return nil }
            return String(decoding: Array(text.utf16)[..<end], as: UTF16.self)
        }
        XCTAssertEqual(letter("Drop caps"), "D")
        XCTAssertEqual(letter("\u{201C}Drop,\u{201D}"), "\u{201C}D", "opening punctuation before it")
        XCTAssertEqual(letter("\u{201C} Drop"), "\u{201C} D", "with the space between")
        XCTAssertEqual(letter("\u{201C}A,\u{201D} said"), "\u{201C}A,\u{201D}", "and the punctuation after it")
        XCTAssertEqual(letter("A\u{2009}! here"), "A\u{2009}!", "a thin space is no word separator")
        XCTAssertEqual(letter("A ! here"), "A", "a space is")
        XCTAssertEqual(letter("A-b"), "A", "not a dash after it")
        XCTAssertEqual(letter("A(b)"), "A", "nor opening punctuation")
        XCTAssertEqual(letter("A. b"), "A.")
        XCTAssertEqual(letter("e\u{301}clair"), "e\u{301}", "a combining mark stays with its base")
        XCTAssertEqual(letter("1984"), "1", "a number")
        XCTAssertEqual(letter("\u{20AC}5"), "\u{20AC}", "a symbol")
        XCTAssertEqual(letter("\u{1D504}stral"), "\u{1D504}", "one character, two code units")
        XCTAssertEqual(letter("\u{1F44D}\u{1F3FD} fine"), "\u{1F44D}\u{1F3FD}", "one typographic character unit")
        XCTAssertEqual(extent("\u{201C}\u{2018}"), .punctuation, "the letter may still follow, in another run")
        XCTAssertEqual(extent(" Drop", afterPunctuation: true), .letter(end: 2), "the space after punctuation in an earlier run")
        XCTAssertEqual(extent(" Drop"), .none, "a line does not begin with a space before its letter")
        XCTAssertEqual(extent("\u{201C}\u{3000}A"), .none, "nor with an ideographic space after its punctuation")
        XCTAssertEqual(extent("\u{301}x"), .none)
        XCTAssertEqual(extent("\u{200B}x"), .none)
    }

    // MARK: Cascade

    func testTheFirstLetterInheritsFromTheBoxThatHoldsItAndTakesOnlyWhatAppliesToIt() throws {
        let styled = try StyleTestSupport.styled("<p id='p'><em id='em'>Drop</em> caps</p><span id='s'>x</span>", css: """
            p::first-letter { font-size: 2em; font-weight: bold; color: rgb(200, 0, 0); float: left; margin-right: 4px;
                              display: block; width: 100px; text-indent: 3em; text-transform: uppercase; position: absolute }
            p { text-indent: 1em } em { font-style: italic } span::first-letter { color: red }
            """)
        let rules = try XCTUnwrap(styled.style("p").firstLetter)
        XCTAssertNil(styled.style("em").firstLetter, "the rules are their element's, not inherited")
        let letter = rules.style(inheritingFrom: styled.style("em"))
        XCTAssertEqual(letter.fontSize, 32)
        XCTAssertEqual(letter.fontWeight, 700)
        XCTAssertTrue(letter.isItalic, "from the inline box that holds it (CSS Pseudo-Elements 4 §2.2.3)")
        XCTAssertEqual(letter.color, StyleTestSupport.color(200 / 255, 0, 0))
        XCTAssertEqual(letter.float, .left)
        XCTAssertEqual(letter.margin.right, .points(4))
        XCTAssertEqual(letter.textTransform, .uppercase)
        XCTAssertEqual(letter.display, .inline, "`display` does not apply")
        XCTAssertEqual(letter.width, .auto, "nor does `width`")
        XCTAssertEqual(letter.position, .static, "nor `position`")
        XCTAssertEqual(letter.textIndent, styled.style("em").textIndent, "an inherited property that does not apply is inherited")
        XCTAssertNotNil(styled.style("s").firstLetter, "the cascade keeps an inline element's rules; the writer styles only a block's letter")
    }

    func testNestedBlocksFirstLettersApplyOutermostFirst() throws {
        let text = try S.styled("<div><p>Text</p></div>", css: """
            div::first-letter { font-size: 2em; font-weight: bold } p::first-letter { font-size: 150% }
            """)
        XCTAssertEqual(text.string.string, "Text")
        XCTAssertEqual(size("T", in: text), 48, "the inner one inherits from the outer one")
        XCTAssertTrue(S.traits("T", in: text).contains(.traitBold))
        XCTAssertEqual(size("ext", in: text), 16)
    }

    // MARK: In line

    func testAnInlineFirstLetterIsStyledWithTheBooksCharactersAndMapUnchanged() throws {
        let body = "<p id='a'>Drop caps open the chapter.</p><p id='b'>Second paragraph.</p>"
        let css = "p::first-letter { font-size: 2em; font-weight: bold; color: rgb(200, 0, 0) }"
        // A stylesheet that styles nothing, so the document's nodes are the same.
        let text = try S.styled(body, css: css), plain = try S.styled(body, css: "/* none */")
        XCTAssertEqual(text.string.string, "Drop caps open the chapter.\nSecond paragraph.")
        XCTAssertEqual(text.string.string, plain.string.string)
        XCTAssertEqual(text.map, plain.map, "the letter is the book's own character")
        XCTAssertEqual(text.anchors, plain.anchors)
        XCTAssertEqual(size("D", in: text), 32); XCTAssertEqual(size("S", in: text), 32)
        XCTAssertTrue(S.traits("D", in: text).contains(.traitBold))
        XCTAssertEqual(size("rop", in: text), 16)
        XCTAssertFalse(S.traits("rop", in: text).contains(.traitBold))
        XCTAssertNotEqual(H.attribute(.foregroundColor, of: "D", in: text) as? PlatformColor,
                          H.attribute(.foregroundColor, of: "rop", in: text) as? PlatformColor)
        XCTAssertEqual(text.report, plain.report)
        XCTAssertNil(NativeDisclosure.text(for: text.report))
        S.assertTextMapContracts(text)
    }

    func testTextTransformChangesTheLettersCharactersAndThePassageKeepsTheBooks() throws {
        let text = try S.styled("<p>drop caps</p>", css: "p::first-letter { text-transform: uppercase }")
        XCTAssertEqual(text.string.string, "Drop caps")
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "drop caps")
        S.assertTextMapContracts(text, sameCharacters: false)
    }

    func testLeadingAndTrailingPunctuationAreOfTheFirstLetter() throws {
        let text = try S.styled("<p>\u{201C}A,\u{201D} said the first. \u{201C}B,\u{201D} said the second.</p>",
                                css: "p::first-letter { font-size: 2em }")
        for (offset, expected) in [(0, 32), (1, 32), (2, 32), (3, 32), (4, 16), (5, 16)] as [(Int, CGFloat)] {
            let font = text.string.attribute(.font, at: offset, effectiveRange: nil) as? PlatformFont
            XCTAssertEqual(font.map { CTFontGetSize($0 as CTFont) }, expected, "at \(offset)")
        }
        XCTAssertEqual(size("B", in: text), 16, "only the first")
        S.assertTextMapContracts(text)
    }

    func testGeneratedContentBeforeTheTextHoldsTheFirstLetter() throws {
        // CSS Pseudo-Elements 4 §2.2.2: with `p::before { content: "Note: " }`, the first letter is the N.
        let text = try S.styled("<p class='note'>Take care.</p>", css: """
            .note::before { content: 'Note: ' } p::first-letter { font-size: 2em }
            """)
        XCTAssertEqual(text.string.string, "Note: Take care.")
        XCTAssertEqual(size("N", in: text), 32)
        XCTAssertEqual(size("ote", in: text), 16)
        XCTAssertEqual(size("Take", in: text), 16)
        XCTAssertTrue(S.isGenerated(0, in: text))
        S.assertTextMapContracts(text)
    }

    func testAQuotationsOpeningMarkIsOfTheFirstLetterOfTheTextInIt() throws {
        // The mark is generated by the `q`'s `::before`, the letter is the `q`'s text: punctuation
        // in one run and the letter in the next. A float cannot take the mark, so the letter is
        // set in line, mark and all.
        for css in ["p::first-letter { font-size: 2em }", Self.dropCap] {
            let text = try S.styled("<p><q>Hello</q>, she said.</p>", css: css)
            XCTAssertEqual(text.string.string, "\u{201C}Hello\u{201D}, she said.", css)
            let expected: CGFloat = css == Self.dropCap ? 48 : 32
            XCTAssertEqual(size("\u{201C}", in: text), expected, css)
            XCTAssertEqual(size("H", in: text), expected, css)
            XCTAssertEqual(size("ello", in: text), 16, css)
            XCTAssertFalse(text.report.flowBoxesReflowed, css)
            S.assertTextMapContracts(text)
        }
    }

    func testWhatBeginsTheFirstLineOtherwiseLeavesItWithoutAFirstLetter() throws {
        let css = "p::first-letter, div::first-letter { font-size: 2em }"
        let files = ["a.png": RichFixture.image(width: 4, height: 4)]
        for body in ["<p><img src='a.png' alt=''/>Text</p>", "<p><br/>Text</p>", "<p>\u{301}Text</p>",
                     "<p><span style='display: inline-block'>Box</span> Text</p>", "<div><table><tr><td>Cell</td></tr></table>Text</div>"] {
            let text = try S.styled(body, css: css, files: files)
            XCTAssertEqual(size("Text", in: text), 16, body)
        }
        let floated = try S.styled("<p><span style='float: right'>Aside</span>Text</p>", css: css)
        XCTAssertEqual(size("T", in: floated), 32, "a float is not on the line")
        XCTAssertEqual(size("Aside", in: floated), 16)
        let empty = try S.styled("<div><p></p><p>Text</p></div>", css: "div::first-letter { font-size: 2em }")
        XCTAssertEqual(size("T", in: empty), 32, "an empty block has no line")
        let inline = try S.styled("<p>Plain <span>text</span></p>", css: "span::first-letter { font-size: 2em }")
        XCTAssertEqual(size("text", in: inline), 16, "an inline box has no first letter")
    }

    func testATableCellsFirstLetterIsStyledInItsOwnText() throws {
        let table = try TableCoverage.table("<table><tr><td>Cell text</td><td>More</td></tr></table>",
                                            css: "td::first-letter { font-size: 2em }")
        for cell in table.cells {
            let sizes = [0, 1].map { offset in
                (cell.content.attribute(.font, at: offset, effectiveRange: nil) as? PlatformFont).map { CTFontGetSize($0 as CTFont) }
            }
            XCTAssertEqual(sizes, [32, 16], cell.text)
        }
    }

    // MARK: Floated

    func testAFloatedFirstLetterIsWrittenAsAFloatedSpanAroundItWouldBe() throws {
        let words = "rop caps open the chapter, and the lines beside it wrap around the initial."
        let span = try S.styled("<p><span class='cap'>D</span>\(words)</p>",
                                css: ".cap { float: left; font-size: 3em; font-weight: bold }")
        let letter = try S.styled("<p>D\(words)</p>", css: Self.dropCap)
        XCTAssertEqual(letter.string.string, "D\n" + words, "a paragraph of its own for the layout")
        XCTAssertEqual(letter.string.string, span.string.string)
        XCTAssertEqual(letter.mappedText(in: 0..<letter.string.length), "D" + words, "the passage keeps its word whole")
        XCTAssertEqual(size("D", in: letter), 48)
        XCTAssertTrue(S.traits("D", in: letter).contains(.traitBold))
        XCTAssertNotNil(H.attribute(.readerFlowBox, of: "D", in: letter))
        XCTAssertNil(H.attribute(.readerFlowBox, of: "rop", in: letter))
        XCTAssertEqual(letter.report, span.report)
        S.assertTextMapContracts(letter)
    }

    func testAFloatedFirstLetterTakesItsPunctuationAndGeneratedContentWithIt() throws {
        let quoted = try S.styled("<p>\u{201C}Drop,\u{201D} she said.</p>", css: Self.dropCap)
        XCTAssertEqual(quoted.string.string, "\u{201C}D\nrop,\u{201D} she said.")
        XCTAssertEqual(quoted.mappedText(in: 0..<quoted.string.length), "\u{201C}Drop,\u{201D} she said.")
        let generated = try S.styled("<p>ake care.</p>", css: "p::before { content: 'T' } " + Self.dropCap)
        XCTAssertEqual(generated.string.string, "T\nake care.")
        XCTAssertTrue(S.isGenerated(0, in: generated))
        XCTAssertEqual(size("T", in: generated), 48)
        for text in [quoted, generated] { S.assertTextMapContracts(text) }
    }

    func testAFirstLetterRuleForOneAppearanceDecidesNothingButItsPaint() throws {
        // #130: only what paints follows `prefers-color-scheme`; a float or a size in a rule for
        // dark is resolved as in light, so the section's characters and map are the same.
        let body = "<p id='a'>Drop caps open the chapter.</p>"
        let css = "@media (prefers-color-scheme: dark) { p::first-letter { float: left; font-size: 3em; color: rgb(255, 0, 0) } }"
        let light = try S.styled(body, css: css), dark = try S.styled(body, css: css, typography: NativeTypography(fontSize: 16, isDark: true))
        let plain = try S.styled(body, css: "/* none */")
        for text in [light, dark] {
            XCTAssertEqual(text.string.string, plain.string.string)
            XCTAssertEqual(text.map, plain.map)
            XCTAssertEqual(text.anchors, plain.anchors)
            XCTAssertEqual(size("D", in: text), 16)
            XCTAssertFalse(text.report.flowBoxesReflowed)
        }
    }

    func testSelectorSupportFollowsWhatIsRendered() throws {
        let text = try S.styled("<p>a</p>", css: """
            @supports selector(p::first-letter) { p::before { content: '1' } }
            @supports not selector(p::first-line) { p::after { content: '2' } }
            """)
        XCTAssertEqual(text.string.string, "1a2")
    }

    // MARK: First line

    func testAFirstLineRuleIsDisclosedOncePerSectionWhereItMatchesABlockShown() throws {
        let sentence = "Styling this book gives the first line of some paragraphs, such as small capitals, is not shown."
        let text = try S.styled("<p>One.</p><p>Two.</p><p class='x'>Three.</p>",
                                css: "p::first-line { font-variant: small-caps } p.x:first-line { color: red }")
        XCTAssertTrue(text.report.firstLineStylesOmitted)
        XCTAssertEqual(text.string.string, "One.\nTwo.\nThree.", "nothing else changes")
        XCTAssertEqual(NativeDisclosure.text(for: text.report), sentence, "once, however many lines it would style")
        var book = text.report
        book.formUnion(text.report)
        XCTAssertEqual(NativeDisclosure.text(for: book), sentence, "and once for the book")
        for css in [".absent::first-line { color: red }", "span::first-line { color: red }", "p.gone::first-line { color: red } .gone { display: none }",
                    "p::first-line {}", "@media print { p::first-line { color: red } }"] {
            let unmatched = try S.styled("<p>One <span>two</span>.</p><p class='gone'>Gone.</p>", css: css)
            XCTAssertFalse(unmatched.report.firstLineStylesOmitted, css)
        }
        let dark = "@media (prefers-color-scheme: dark) { p::first-line { color: red } }"
        for isDark in [false, true] {
            let text = try S.styled("<p>One.</p>", css: dark, typography: NativeTypography(fontSize: 16, isDark: isDark))
            XCTAssertTrue(text.report.firstLineStylesOmitted, "the same in either appearance")
        }
    }
}

/// Drop caps made with `::first-letter`, laid out by the reader's own TextKit stack.
@MainActor final class FirstLetterLayoutTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 360, height: 600)

    func testAFloatedFirstLetterIsADropCapBesideTheLinesItSpans() throws {
        let words = "rop caps open the chapter. "
        let css = "p::first-letter { float: left; font-size: 48px; line-height: 1 } p { line-height: 20px }"
        let section = try H.build("<p>D\(words)\(H.prose)</p>", css: H.reset + css)
        let view = H.view(section.string, size: size)
        let cap = try XCTUnwrap(H.region("D", in: section, view: view))
        XCTAssertEqual(cap.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(cap.frame.minY, 0, accuracy: 0.5)
        let first = H.frame("rop caps", in: section, view: view)
        XCTAssertEqual(first.minY, cap.frame.minY, accuracy: 1, "the word starts beside the initial")
        XCTAssertEqual(first.minX, cap.frame.maxX, accuracy: 1)
        let lines = H.lines(in: view, intersecting: H.range(H.prose, in: section)).map(\.frame)
        let beside = lines.filter { $0.minY < cap.frame.maxY - 0.5 }, below = lines.filter { $0.minY >= cap.frame.maxY - 0.5 }
        XCTAssertTrue((2...3).contains(beside.count), "two or three lines beside it: \(beside)")
        XCTAssertTrue(beside.allSatisfy { $0.minX >= cap.frame.maxX - 0.5 }, "\(beside)")
        XCTAssertFalse(below.isEmpty)
        XCTAssertTrue(below.allSatisfy { $0.minX < 0.5 }, "the full column below it: \(below)")
        XCTAssertFalse(H.overlaps(H.ink("D", in: section, view: view), H.ink(H.prose, in: section, view: view)))
        // The same as a floated span around the letter.
        let span = try H.build("<p><span class='cap'>D</span>\(words)\(H.prose)</p>",
                               css: H.reset + css.replacingOccurrences(of: "p::first-letter", with: ".cap"))
        let spanView = H.view(span.string, size: size)
        let spanCap = try XCTUnwrap(H.region("D", in: span, view: spanView))
        let spanFirst = H.frame("rop caps", in: span, view: spanView)
        for (shown, expected) in [(cap.frame, spanCap.frame), (first, spanFirst)] {
            XCTAssertEqual(shown.minX, expected.minX, accuracy: 0.01); XCTAssertEqual(shown.minY, expected.minY, accuracy: 0.01)
            XCTAssertEqual(shown.width, expected.width, accuracy: 0.01); XCTAssertEqual(shown.height, expected.height, accuracy: 0.01)
        }
        H.pages(section, size: size)
    }

    func testAnInlineFirstLetterIsSetOnTheFirstLineAtItsSize() throws {
        let section = try H.build("<p>Drop caps \(H.prose)</p>", css: H.reset + "p::first-letter { font-size: 40px }")
        let view = H.view(section.string, size: size)
        XCTAssertNil(H.region("D", in: section, view: view), "no float")
        let letter = H.frame("D", in: section, view: view), rest = H.frame("rop", in: section, view: view)
        XCTAssertEqual(rest.minX, letter.maxX, accuracy: 1, "on the same line, followed by its word")
        XCTAssertEqual(rest.minY, letter.minY, accuracy: 1)
        let lines = H.lines(in: view)
        XCTAssertGreaterThan(lines.count, 2)
        XCTAssertGreaterThan(lines[0].frame.height, lines[1].frame.height * 1.5, "the first line is as tall as the letter")
    }
}
