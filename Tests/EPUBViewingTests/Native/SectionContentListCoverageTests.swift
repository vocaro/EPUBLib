import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// List markers and counters: HTML's `ol`/`ul`/`menu`/`li` attributes and CSS Lists markers.
final class SectionContentListCoverageTests: XCTestCase {
    private typealias H = BuilderHarness
    private typealias S = SectionContentSupport

    private func items(_ body: String, rules: [H.Rule] = []) throws -> [String] {
        let text = try H.build(body, rules: rules)
        S.assertTextMapContracts(text)
        return S.paragraphs(text)
    }

    func testNestedListsCountOnTheirOwnAndTheOuterListCarriesOn() throws {
        XCTAssertEqual(try items("<ol><li>a<ol><li>a1</li><li>a2</li></ol></li><li>b<ul><li>b1</li></ul></li><li>c</li></ol>"),
                       ["1.\ta", "1.\ta1", "2.\ta2", "2.\tb", "◦\tb1", "3.\tc"])
        // Two lists in a row each start again.
        XCTAssertEqual(try items("<ol><li>a</li><li>b</li></ol><ol><li>c</li></ol>"), ["1.\ta", "2.\tb", "1.\tc"])
    }

    func testBulletsChangeWithNestingDepth() throws {
        XCTAssertEqual(try items("<ul><li>a<ul><li>b<ul><li>c<ul><li>d</li></ul></li></ul></li></ul></li></ul><menu><li>m</li></menu>"),
                       ["•\ta", "◦\tb", "▪\tc", "▪\td", "•\tm"])
    }

    func testStartReversedAndValueAttributes() throws {
        XCTAssertEqual(try items("<ol start='5' reversed=''><li>x</li><li>y</li></ol>"), ["5.\tx", "4.\ty"])
        // A reversed list counts down from its number of items; `value` restarts from there (HTML 4.4.5, 4.4.8).
        XCTAssertEqual(try items("<ol reversed='reversed'><li>x</li><li value='7'>y</li><li>z</li></ol>"), ["3.\tx", "7.\ty", "6.\tz"])
        XCTAssertEqual(try items("<ol><li value='10'>x</li><li>y</li><li value='3'>z</li><li>w</li></ol>"), ["10.\tx", "11.\ty", "3.\tz", "4.\tw"])
        XCTAssertEqual(try items("<ol start='0'><li>x</li></ol><ol start='-1'><li>a</li><li>b</li><li>c</li></ol>"),
                       ["0.\tx", "-1.\ta", "0.\tb", "1.\tc"])
        XCTAssertEqual(try items("<ol start=' 7 '><li>a</li></ol><ol start='+4'><li>a</li></ol><ol start='abc'><li>a</li></ol>"),
                       ["7.\ta", "4.\ta", "1.\ta"])
    }

    func testAReversedListCountsOnlyItsOwnItems() throws {
        XCTAssertEqual(try items("<ol reversed=''><li>a<ol><li>n1</li><li>n2</li><li>n3</li></ol></li><li>b</li></ol>"),
                       ["2.\ta", "1.\tn1", "2.\tn2", "3.\tn3", "1.\tb"])
    }

    func testTypeAttributesChooseTheNumbering() throws {
        XCTAssertEqual(try items("""
            <ol type="a"><li>x</li></ol><ol type="A"><li>x</li></ol><ol type="i"><li>x</li></ol><ol type="I"><li>x</li></ol>\
            <ol type="1"><li>x</li></ol><ul type="square"><li>x</li></ul><ul type="circle"><li>x</li></ul><ul type="none"><li>x</li></ul>\
            <ol><li type="a">x</li><li>y</li><li type="I">z</li></ol>
            """), ["a.\tx", "A.\tx", "i.\tx", "I.\tx", "1.\tx", "▪\tx", "◦\tx", "x", "a.\tx", "2.\ty", "III.\tz"])
    }

    func testRomanAndAlphabeticNumberingAtTheirLimits() throws {
        let rules: [H.Rule] = [(".r", { $0.listStyleType = .upperRoman }), (".a", { $0.listStyleType = .lowerAlpha }),
                               (".g", { $0.listStyleType = .lowerGreek }), (".z", { $0.listStyleType = .decimalLeadingZero })]
        // CSS Counter Styles 3: roman covers 1–3999 and the alphabetic systems 1 upwards; outside they fall back to decimal.
        XCTAssertEqual(try items("<ol class='r'><li value='3999'>a</li><li>b</li><li value='0'>c</li><li value='1994'>d</li></ol>", rules: rules),
                       ["MMMCMXCIX.\ta", "4000.\tb", "0.\tc", "MCMXCIV.\td"])
        XCTAssertEqual(try items("<ol class='a'><li value='26'>a</li><li>b</li><li value='0'>c</li><li value='703'>d</li><li value='-2'>e</li></ol>",
                                 rules: rules), ["z.\ta", "aa.\tb", "0.\tc", "aaa.\td", "-2.\te"])
        XCTAssertEqual(try items("<ol class='g'><li value='24'>a</li><li>b</li></ol>", rules: rules), ["ω.\ta", "αα.\tb"])
        XCTAssertEqual(try items("<ol class='z'><li value='9'>a</li><li>b</li><li value='-3'>c</li><li value='100'>d</li></ol>", rules: rules),
                       ["09.\ta", "10.\tb", "-03.\tc", "100.\td"])
    }

    func testListStylesFromTheStylesheet() throws {
        let text = try S.styled("""
            <ol style="list-style-type: lower-roman"><li>a</li><li style="list-style-type: '→ '">b</li></ol>\
            <ul style="list-style: square inside"><li>c</li></ul><ol style="list-style-type: upper-latin"><li>d</li></ol>\
            <ul style="list-style: none"><li>e</li></ul><ol style="list-style-type: decimal-leading-zero"><li>f</li></ol>
            """)
        XCTAssertEqual(S.paragraphs(text), ["i.\ta", "→ \tb", "▪ c", "A.\td", "e", "01.\tf"])
        S.assertTextMapContracts(text)
    }

    func testItemsHoldingBlocksEmptyItemsAndImages() throws {
        XCTAssertEqual(try items("<ol><li><p>p1</p><p>p2</p></li><li> </li><li><br/></li><li><div><p>deep</p></div></li><li>a<p>b</p></li></ol>"),
                       ["1.\tp1", "p2", "2.\t", "3.\t", "4.\tdeep", "5.\ta", "b"])
        XCTAssertEqual(try items("<ul><li><img src='picture.png' alt='I'/></li><li><b>bold</b> text</li></ul>"), ["•\t[I]", "•\tbold text"])
    }

    func testItemsThatAreNotDisplayedDoNotCount() throws {
        XCTAssertEqual(try items("<ol><li hidden=''>h</li><li>v</li><li class='dn'>h</li><li>w</li></ol>", rules: [(".dn", { $0.display = .none })]),
                       ["1.\tv", "2.\tw"])
        XCTAssertEqual(try items("<ol><li>a</li><div>not an item</div><li>b</li></ol>"), ["1.\ta", "not an item", "2.\tb"])
    }

    func testItemsOutsideAnyListAndOtherListItemBoxesGetBullets() throws {
        XCTAssertEqual(try items("<li>orphan1</li><li>orphan2</li><div class='item'>div item</div>", rules: [(".item", { $0.display = .listItem })]),
                       ["•\torphan1", "•\torphan2", "•\tdiv item"])
    }

    func testMarkersAreGeneratedUnlinkedAndLeftOutOfThePassageText() throws {
        let text = try H.build("<ol><li id='one'><a href='two.xhtml'>link</a></li><li id='two'><p id='p'>para</p></li></ol>")
        XCTAssertEqual(text.string.string, "1.\tlink\n2.\tpara")
        for location in [0, 1, 2, 8, 9, 10] { XCTAssertTrue(S.isGenerated(location, in: text), "\(location)") }
        XCTAssertNil(text.string.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(text.string.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertNotNil(text.string.attribute(.link, at: 3, effectiveRange: nil))
        // An item's anchor is its marker, so a link to it shows the number too.
        XCTAssertEqual(text.anchors["one"], 0)
        XCTAssertEqual(text.anchors["two"], 8)
        XCTAssertEqual(text.anchors["p"], 8)
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "link\npara")
        // A position at a marker is the item's first character.
        XCTAssertEqual(text.map.position(at: 0, in: text.document), DOMPosition(try XCTUnwrap(S.textNode("link", in: text)), 0))
    }

    func testRightToLeftListsKeepTheirMarkersInAReversedParagraph() throws {
        let text = try H.build("<ol dir='rtl'><li>א</li><li>ב</li></ol>")
        XCTAssertEqual(S.paragraphs(text), ["1.\tא", "2.\tב"])
        let style = try XCTUnwrap(H.paragraphStyle(text, at: 0))
        XCTAssertEqual(style.baseWritingDirection, .rightToLeft)
        XCTAssertEqual(style.tabStops.count, 1)
        XCTAssertGreaterThan(style.headIndent, 0)
    }

    func testARightToLeftListIsIndentedOnItsStartSide() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/124")
        // HTML 15.3.7: `ol, ul, menu { padding-inline-start: 40px }` — the start side, which is the right in
        // right-to-left text. The paragraph style's head indent is that side.
        let ltr = try XCTUnwrap(H.paragraphStyle(try H.build("<ol><li>a</li></ol>"), at: 0))
        let rtl = try XCTUnwrap(H.paragraphStyle(try H.build("<ol dir='rtl'><li>א</li></ol>"), at: 0))
        XCTAssertEqual(ltr.headIndent, 32)
        XCTAssertEqual(ltr.tailIndent, 0)
        XCTAssertEqual(rtl.headIndent, ltr.headIndent, "the list's padding is not on its start side")
        XCTAssertEqual(rtl.tailIndent, ltr.tailIndent, "the list's padding is on its end side")
    }

    func testAThousandItemsHangMarkersThatFitBeforeTheirText() throws {
        let text = try H.build("<ol>" + (1...1200).map { "<li>item \($0)</li>" }.joined() + "</ol>")
        let paragraphs = S.paragraphs(text)
        XCTAssertEqual(paragraphs.count, 1200)
        XCTAssertEqual(paragraphs[0], "1.\titem 1")
        XCTAssertEqual(paragraphs[1199], "1200.\titem 1200")
        let fonts = FontRegistry(publication: H.publication)
        let font = fonts.font(for: ComputedStyle(fontFamilies: ["serif"], fontSize: 16))
        for marker in ["1.", "1200."] {
            let style = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: marker + "\t", in: text)))
            let width = InlineStyling.width(of: marker, font: font)
            let stop = try XCTUnwrap(style.tabStops.first?.location)
            // The marker ends before the tab stop where the text starts, and wrapped lines align with the text.
            XCTAssertGreaterThanOrEqual(style.firstLineHeadIndent, 0, marker)
            XCTAssertLessThanOrEqual(style.firstLineHeadIndent + width, stop + 0.01, marker)
            XCTAssertEqual(style.headIndent, stop, accuracy: 0.01, marker)
        }
    }

    func testEnormousCounterValuesAreClampedNotTrapped() throws {
        let paragraphs = try items("""
            <ol><li value="2147483648">a</li><li value="99999999999999999999">b</li><li value="-99999999999999999999">c</li></ol>\
            <ol start="9223372036854775807"><li>d</li><li>e</li></ol><ol start="-9223372036854775808" reversed=""><li>f</li><li>g</li></ol>
            """)
        XCTAssertEqual(paragraphs.count, 7)
        for paragraph in paragraphs { XCTAssertLessThan(paragraph.utf16.count, 20, paragraph) }
        XCTAssertEqual(paragraphs.map { String($0.suffix(1)) }, ["a", "b", "c", "d", "e", "f", "g"])
    }

    func testDeeplyNestedListsStayReadable() throws {
        let depth = 40
        let text = try H.build(String(repeating: "<ol><li>", count: depth) + "deep" + String(repeating: "</li></ol>", count: depth))
        XCTAssertTrue(text.string.string.hasSuffix("1.\tdeep"))
        let style = try XCTUnwrap(H.paragraphStyle(text, at: H.location(of: "deep", in: text)))
        XCTAssertLessThanOrEqual(style.headIndent - style.tailIndent, 200.01)
        S.assertTextMapContracts(text)
    }
}
