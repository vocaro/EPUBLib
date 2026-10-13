import CoreGraphics
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Headings marked for assistive technology in the built text (`ReaderHeading`, "Accessibility"
/// in `doc/native-viewer.md`): which characters carry a heading and at what level, and that the
/// mark changes no character, no span of the text map, no anchor and no line of the layout.
@MainActor final class HeadingTextTests: XCTestCase {
    private typealias H = BoxLayoutHarness

    private static let hide = ".sr { position:absolute; left:-999em } "

    private func build(_ body: String, css: String = "", files: [String: Data] = [:]) throws -> SectionText {
        try H.build(body, css: H.reset + Self.hide + css, files: files)
    }

    /// Each heading in the text: its level and what is read of its characters.
    private func headings(_ text: NSAttributedString) -> [String] {
        text.readerHeadings().map { "\($0.heading.level) \(text.readerPlainText(in: $0.range))" }
    }

    /// The characters that carry a heading, as the text has them.
    private func marked(_ section: SectionText) -> [String] {
        section.string.readerHeadings().map { (section.string.string as NSString).substring(with: $0.range) }
    }

    // MARK: Which characters

    func testHeadingsCarryTheirLevelsAndOrdinaryTextCarriesNone() throws {
        let section = try build("<h1>One</h1><p>Plain words.</p><h2>Two <em>with</em> emphasis</h2><h3>Three</h3>"
            + "<h4>Four</h4><h5>Five</h5><h6>Six</h6><p>More plain words.</p>")
        XCTAssertEqual(section.string.string, "One\nPlain words.\nTwo with emphasis\nThree\nFour\nFive\nSix\nMore plain words.")
        XCTAssertEqual(headings(section.string), ["1 One", "2 Two with emphasis", "3 Three", "4 Four", "5 Five", "6 Six"])
        // A heading is its words: the break that ends its paragraph is no part of it, and so
        // two headings one after the other are two.
        XCTAssertEqual(marked(section), ["One", "Two with emphasis", "Three", "Four", "Five", "Six"])
        let text = section.string.string as NSString
        for plain in ["Plain words.", "More plain words."] {
            var range = NSRange()
            XCTAssertNil(section.string.attribute(.readerHeading, at: text.range(of: plain).location, longestEffectiveRange: &range,
                                                  in: NSRange(location: 0, length: text.length)))
            XCTAssertTrue(NSLocationInRange(NSMaxRange(text.range(of: plain)) - 1, range), "\(plain) is plain to its last character")
        }
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testARoleMakesAHeadingAndTakesOneAway() throws {
        let section = try build("""
            <div role="heading" aria-level="3">By role</div><p role="heading">Level two without one</p>\
            <h2 aria-level="4">Moved</h2><h2 role="presentation">Only looks like one</h2><h3 role="none">Nor this</h3>\
            <h1 aria-level="9">Too deep</h1><h4 aria-level="x">Its own</h4><h5 aria-level="0">Its own again</h5>\
            <p aria-level="2">No role</p><p role="note">Another role</p>
            """)
        XCTAssertEqual(headings(section.string),
                       ["3 By role", "2 Level two without one", "4 Moved", "0 Too deep", "4 Its own", "5 Its own again"])
        // What the reader lays out as a heading does not follow the role: these are kept with
        // the paragraph after them all the same.
        for kept in ["Only looks like one", "Nor this"] {
            XCTAssertEqual(BuilderHarness.attribute(.readerKeepWithNext, of: kept, in: section) as? Bool, true, kept)
        }
    }

    func testAHeadingIsItsOwnTextFromItsFirstCharacterToItsLast() throws {
        let image = ["title.png": RichFixture.image(width: 240, height: 80)]
        // After a list marker, around a line break, with generated quotation marks.
        let section = try build("""
            <ul><li><h3>In a list</h3></li></ul><h2>Chapter 1<br/>The Title</h2><h2><q>Quoted</q></h2>\
            <h2>First of two</h2><h2>Second of two</h2><h1><img alt="A title drawn as a picture" src="title.png"/></h1>\
            <h1><span style="display:block">Upper block</span><span style="display:block">Lower block</span></h1><p>End.</p>
            """, files: image)
        XCTAssertEqual(marked(section), ["In a list", "Chapter 1\u{2028}The Title", "“Quoted”", "First of two", "Second of two",
                                         "\u{FFFC}", "Upper block\nLower block"])
        XCTAssertEqual(headings(section.string), ["3 In a list", "2 Chapter 1\u{2028}The Title", "2 “Quoted”", "2 First of two",
                                                  "2 Second of two", "1 A title drawn as a picture", "1 Upper block\nLower block"])
        let found = section.string.readerHeadings()
        XCTAssertFalse(found[3].heading === found[4].heading, "two headings, each its own")
        // One heading over two paragraphs is one object, and the break between them is its own.
        var whole = NSRange()
        let upper = H.range("Upper block", in: section)
        XCTAssertTrue(section.string.attribute(.readerHeading, at: upper.location, longestEffectiveRange: &whole,
                                               in: NSRange(location: 0, length: section.string.length)) as? ReaderHeading === found[6].heading)
        XCTAssertEqual(whole, found[6].range)
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testAHeadingRunInWithItsParagraphIsOnlyItsOwnWords() throws {
        for body in ["<p><span role=\"heading\" aria-level=\"4\">Run in.</span> The paragraph goes on.</p>",
                     "<div><h4 style=\"display:inline\">Run in.</h4> The paragraph goes on.</div>"] {
            let section = try build(body)
            XCTAssertEqual(section.string.string, "Run in. The paragraph goes on.", body)
            XCTAssertEqual(headings(section.string), ["4 Run in."], body)
            XCTAssertEqual(section.string.readerHeadings().first?.range, NSRange(location: 0, length: 7), body)
        }
        // Inside a table's cell, where a block is written inline.
        let table = try H.build("<table><tr><td><h3>Cell heading</h3>and its words</td><td>Other</td></tr></table>", css: H.reset)
        XCTAssertEqual(table.string.readerHeadings().count, 0, "a table's rows are attachments, each read by its cells")
    }

    // MARK: Hidden labels

    func testAHiddenHeadingIsAHeadingAndAHiddenBylineIsNot() throws {
        let section = try build("<h1 class=\"sr\">The Hidden Title</h1><p class=\"sr\">By the author</p><p>Shown words.</p>")
        XCTAssertEqual(section.string.string, "\u{FFFC}\u{FFFC}Shown words.")
        XCTAssertEqual(section.string.spokenLabels, ["The Hidden Title", "By the author"])
        XCTAssertEqual(headings(section.string), ["1 The Hidden Title"])
        XCTAssertEqual(section.string.readerHeadings().first?.range, NSRange(location: 0, length: 1), "the title's label, not the byline's")
    }

    func testHiddenWordsAreAHeadingOnlyWhereTheBookMadeThemOne() throws {
        // A hidden label waiting for a line stands at the start of the heading after it, and is
        // no part of that heading.
        let before = try build("<p class=\"sr\">Parked note</p><h2>Shown heading</h2><p>Words.</p>")
        XCTAssertEqual(before.string.string, "\u{FFFC}Shown heading\nWords.")
        XCTAssertEqual(marked(before), ["Shown heading"])
        // Hidden words inside a shown heading are that heading's.
        let inside = try build("<h2>Chapter <span class=\"sr\">the first, unseen</span> One</h2><p>Words.</p>")
        XCTAssertEqual(inside.string.spokenLabels, ["the first, unseen"])
        XCTAssertEqual(headings(inside.string), ["2 Chapter the first, unseen One"])
        XCTAssertEqual(inside.string.readerHeadings().count, 1, "one heading, its hidden words among the shown")
        // A heading inside a hidden box, beside words that are not one.
        let box = try build("<div class=\"sr\"><h3>Inner heading</h3><p>Other words</p></div><p>Shown.</p>")
        XCTAssertEqual(box.string.spokenLabels, ["Inner heading", "Other words"])
        XCTAssertEqual(headings(box.string), ["3 Inner heading"])
        // A shown heading that holds nothing but hidden words.
        let only = try build("<h2><span class=\"sr\">Heard and not seen</span></h2><p>Shown.</p>")
        XCTAssertEqual(headings(only.string), ["2 Heard and not seen"])
        // Hidden from assistive technology too: no label, so nothing to be a heading.
        let unheard = try build("<h1 class=\"sr\" aria-hidden=\"true\">Nobody is given this</h1><p>Shown.</p>")
        XCTAssertEqual(headings(unheard.string), [])
    }

    // MARK: Nothing else changes

    /// A chapter with headings of every kind the tests above cover.
    private static let chapter = """
        <h1 id="top">A chapter title long enough to take two lines of a narrow page column, and then some</h1>\
        <p id="first">\(CanvasText.sentence(120, seed: 1))</p><h2 id="second">Second level</h2>\
        <ul><li><h3>In a list</h3>\(CanvasText.sentence(40, seed: 2))</li></ul>\
        <h1 class="sr">A hidden heading</h1><p class="sr">A hidden byline</p><p>\(CanvasText.sentence(200, seed: 3))</p>\
        <h4>Fourth <a href="#top">linked</a> level<br/>on two lines</h4><p>\(CanvasText.sentence(300, seed: 4))</p>\
        <div><h5 style="display:inline">Run in.</h5> \(CanvasText.sentence(90, seed: 5))</div>\
        <h6 id="last">Sixth level</h6><p>\(CanvasText.sentence(400, seed: 6))</p>
        """

    /// The same markup with every heading element told to be presentation only: it goes
    /// through the same builder, is laid out as a heading, and carries no mark.
    private static var unmarkedChapter: String {
        chapter.replacingOccurrences(of: "<h([1-6])", with: "<h$1 role=\"presentation\"", options: .regularExpression)
    }

    func testTheMarkChangesNoCharacterNoMapSpanAndNoAnchor() throws {
        let marked = try build(Self.chapter), unmarked = try build(Self.unmarkedChapter)
        XCTAssertEqual(headings(marked.string).count, 7)
        XCTAssertEqual(headings(unmarked.string), [])
        XCTAssertEqual(marked.string.string, unmarked.string.string, "the same characters")
        XCTAssertEqual(marked.map, unmarked.map, "the same spans of the text map")
        XCTAssertEqual(marked.anchors, unmarked.anchors, "the same anchors")
        XCTAssertEqual(marked.report, unmarked.report, "nothing more is disclosed")
        BuilderHarness.assertMapRoundTrips(marked)
        // Every other attribute is where it was: the same keys on every character, and the
        // same fonts, paragraph styles, colors, links and pagination flags.
        let compared: [NSAttributedString.Key] = [.font, .paragraphStyle, .foregroundColor, .link, .readerKeepWithNext, .readerPageBreakBefore]
        for index in 0..<marked.string.length {
            let with = marked.string.attributes(at: index, effectiveRange: nil)
            let without = unmarked.string.attributes(at: index, effectiveRange: nil)
            XCTAssertEqual(Set(with.keys).subtracting([.readerHeading]), Set(without.keys), "the attributes of character \(index)")
            for key in compared {
                XCTAssertEqual(with[key] as? NSObject, without[key] as? NSObject, "\(key.rawValue) of character \(index)")
            }
        }
    }

    private struct Line: Equatable {
        let page: Int
        let range: NSRange
        let frame: CGRect
    }

    /// Every line of every page of `text` at `size`: its characters and where it lies.
    private func lines(_ text: NSAttributedString, size: CGSize) -> [Line] {
        let paginator = ReaderPaginator(text: text, size: size)
        var lines: [Line] = []
        for (index, page) in paginator.allPages.enumerated() {
            let view = H.pageView(paginator, page: page)
            for line in H.lines(in: view, intersecting: view.shownCharacters) {
                lines.append(Line(page: index, range: NSRange(location: line.range.location + page.range.location, length: line.range.length),
                                  frame: line.frame.offsetBy(dx: 0, dy: page.topSpacing)))
            }
        }
        return lines
    }

    /// The same lines on the same pages in the same places. A width may differ in its last
    /// bits: the mark ends an attribute run where the heading's words end, and CoreText then
    /// sums the same glyph advances in another order (78.94507570612708 and 78.9450757061271).
    private func assertSameLines(_ first: [Line], _ second: [Line], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(first.map(\.page), second.map(\.page), "the same lines on the same pages, \(label)", file: file, line: line)
        XCTAssertEqual(first.map(\.range), second.map(\.range), "the same characters in each line, \(label)", file: file, line: line)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.frame.origin, b.frame.origin, "line \(a.range) on page \(a.page + 1), \(label)", file: file, line: line)
            XCTAssertEqual(a.frame.height, b.frame.height, "line \(a.range) on page \(a.page + 1), \(label)", file: file, line: line)
            XCTAssertEqual(a.frame.width, b.frame.width, accuracy: 1e-9, "line \(a.range) on page \(a.page + 1), \(label)", file: file, line: line)
        }
    }

    func testTheMarkMovesNoLineOnAnyPage() throws {
        let marked = try build(Self.chapter), unmarked = try build(Self.unmarkedChapter)
        let stripped = NSMutableAttributedString(attributedString: marked.string)
        stripped.removeAttribute(.readerHeading, range: NSRange(location: 0, length: stripped.length))
        XCTAssertEqual(headings(stripped), [])
        for size in [CGSize(width: 320, height: 560), CGSize(width: 520, height: 700)] {
            let with = lines(marked.string, size: size)
            XCTAssertGreaterThan(Set(with.map(\.page)).count, 3, "several pages at \(size)")
            // The text as built and the same text with the mark taken off: the same objects
            // in every other attribute, so any difference would be the mark's.
            assertSameLines(with, lines(stripped, size: size), "with and without the mark at \(size)")
            // And the book whose headings are none to a listener: built apart, laid out the same.
            assertSameLines(with, lines(unmarked.string, size: size), "beside the same book without headings at \(size)")
        }
        // The first heading does take two lines at the narrow size, for the views' tests.
        let title = marked.string.readerHeadings()[0].range
        XCTAssertGreaterThan(lines(marked.string, size: CGSize(width: 320, height: 560)).filter { NSIntersectionRange($0.range, title).length > 0 }.count, 1)
    }
}
