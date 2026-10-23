import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A `details` element and its `summary` ("Details and summary" in `doc/native-viewer.md`,
/// [#708](https://github.com/vocaro/EPUBLib/issues/708)): the section's text holds the whole
/// details, written open, and what a closed one holds is collapsed where it is shown, its
/// characters kept, so that every position, search result and CFI reads the same text whether
/// it is open or closed.
@MainActor final class DisclosureTests: XCTestCase {
    private typealias H = BoxLayoutHarness

    /// A picture's long description in a details, as DAISY's extdescription-010 has one: a
    /// heading, words, a table of data and more words, before and after the details words of
    /// the page. Every word is the repository's own.
    static let body = """
        <p>Words before the chart.</p>\
        <details id="described"><summary>Show the long description</summary>\
        <div><h3>Summary of the figures</h3><p>Harbor arrivals fell each month.</p>\
        <table><tr><th scope="col">Month</th><th scope="col">Ships</th></tr>\
        <tr><th scope="row">April</th><td>41</td></tr><tr><th scope="row">May</th><td>37</td></tr></table>\
        <p id="inside">Closing remark inside.</p></div></details>\
        <p>Words after the chart.</p>
        """
    static let summary = "Show the long description"
    static let hiddenWords = ["Summary of the figures", "Harbor arrivals", "Closing remark inside"]

    private func section(_ body: String = DisclosureTests.body, css: String = "") throws -> SectionText {
        try H.build(body, css: css)
    }

    private func shown(_ section: SectionText, open: Bool) -> NSAttributedString {
        ReaderDisclosures.render(section.string, section.disclosures) { _ in open }
    }

    /// The table rows of `text`, each with where it stands.
    static func rows(in text: NSAttributedString) -> [(row: TableRowAttachment, location: Int)] {
        var rows: [(TableRowAttachment, Int)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let row = value as? TableRowAttachment { rows.append((row, range.location)) }
        }
        return rows
    }

    // MARK: The text

    func testADetailsIsWrittenWholeAndItsSummaryIsWhatOpensIt() throws {
        let section = try section()
        let text = section.string.string as NSString
        // Its characters do not depend on whether it is open: every word is in the text.
        for word in Self.hiddenWords + ["Words after the chart."] {
            XCTAssertNotEqual(text.range(of: word).location, NSNotFound, word)
        }
        // The table's rows are in it too, each one attachment, its cells' words in the row.
        let rows = Self.rows(in: section.string)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.first?.row.table.cells.contains { $0.content.string == "April" } ?? false)
        let disclosure = try XCTUnwrap(section.disclosures.first)
        XCTAssertEqual(section.disclosures.count, 1)
        XCTAssertFalse(disclosure.isOpenInBook, "no open attribute")
        XCTAssertEqual(disclosure.id, section.document.element(id: "described")?.order)
        // The summary is its triangle and its words, without the break after them.
        XCTAssertEqual(text.substring(with: disclosure.summary), "\u{25B8} " + Self.summary)
        XCTAssertEqual(disclosure.marker, disclosure.summary.location)
        // What it hides is every paragraph after the summary's, to the details' end.
        let content = try XCTUnwrap(disclosure.content.first)
        XCTAssertEqual(disclosure.content.count, 1)
        XCTAssertEqual(content.location, text.range(of: "Summary of the figures").location)
        XCTAssertEqual(NSMaxRange(content), text.range(of: "Words after the chart.").location, "the last break is the details'")
        XCTAssertTrue(rows.allSatisfy { disclosure.hides($0.location) })
        XCTAssertFalse(disclosure.hides(disclosure.summary.location))
        XCTAssertFalse(disclosure.hides(text.range(of: "Words after").location))
        // Every character of the summary, its triangle included, opens and closes the details.
        for location in disclosure.summary.location..<NSMaxRange(disclosure.summary) {
            let url = section.string.attribute(.link, at: location, effectiveRange: nil) as? URL
            XCTAssertEqual(url.flatMap(ReaderLink.init(url:)), .disclosure(disclosure.id), "\(location)")
            XCTAssertEqual(section.string.attribute(.readerExpanded, at: location, effectiveRange: nil) as? Bool, false)
        }
        // The triangle is the summary's own, which VoiceOver does not read: it says the state.
        XCTAssertNotNil(section.string.attribute(.readerUnspoken, at: disclosure.summary.location, effectiveRange: nil))
        XCTAssertEqual(section.string.readerPlainText(in: disclosure.summary, spoken: true), Self.summary)
        // A summary is no link to the eye.
        let color = section.string.attribute(.foregroundColor, at: text.range(of: Self.summary).location, effectiveRange: nil) as? PlatformColor
        XCTAssertEqual(color, ReaderPalette.text(dark: false))
        XCTAssertNil(section.string.attribute(.readerExpanded, at: text.range(of: "Words after").location, effectiveRange: nil))
    }

    func testAnOpenDetailsShowsItsOpenTriangleAndAnotherKindHasNone() throws {
        let section = try section("""
            <details open="open"><summary>Opened by the book</summary><p>Shown words.</p></details>\
            <details><p>No summary at all.</p></details>\
            <section><summary>Not a details' summary</summary></section>
            """)
        let text = section.string.string as NSString
        XCTAssertEqual(section.disclosures.count, 1, "a details without a summary does not close, nor does a stray summary")
        let disclosure = try XCTUnwrap(section.disclosures.first)
        XCTAssertTrue(disclosure.isOpenInBook)
        XCTAssertEqual(text.substring(with: disclosure.summary), "\u{25BE} Opened by the book")
        XCTAssertNotEqual(text.range(of: "No summary at all.").location, NSNotFound)
        XCTAssertEqual(text.range(of: "\u{25B8}").location, NSNotFound)
        XCTAssertTrue(text.contains("Not a details' summary"))
        XCTAssertFalse(text.contains("\u{25BE} Not a details"), "only a details' first summary has a triangle")
    }

    func testRightToLeftClosedTrianglePointsLeft() throws {
        let section = try section("<details dir=\"rtl\"><summary>מבוא</summary><p>תוכן</p></details>")
        let disclosure = try XCTUnwrap(section.disclosures.first)
        XCTAssertTrue(disclosure.isRightToLeft)
        XCTAssertEqual((section.string.string as NSString).substring(with: NSRange(location: try XCTUnwrap(disclosure.marker), length: 1)),
                       "\u{25C2}")
        let opened = shown(section, open: true)
        XCTAssertEqual((opened.string as NSString).substring(with: NSRange(location: disclosure.marker!, length: 1)), "\u{25BE}")
        XCTAssertEqual(shown(section, open: false).string, section.string.string, "closed as the book has it: the same triangle")
    }

    func testAClosedDetailsIsShownCollapsedAndAnOpenOneWhole() throws {
        let section = try section()
        let disclosure = try XCTUnwrap(section.disclosures.first)
        let content = try XCTUnwrap(disclosure.content.first)
        let closed = shown(section, open: false), open = shown(section, open: true)
        // No character moves either way: only the triangle turns.
        XCTAssertEqual(closed.string, section.string.string)
        XCTAssertEqual(closed.length, open.length)
        XCTAssertEqual((open.string as NSString).substring(with: NSRange(location: disclosure.summary.location, length: 1)), "\u{25BE}")
        XCTAssertEqual(open.attribute(.readerExpanded, at: disclosure.summary.location, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(closed.attribute(.readerExpanded, at: disclosure.summary.location, effectiveRange: nil) as? Bool, false)
        // Closed, what it holds is hidden and collapsed, character for character, and has no
        // link, heading, table or picture left.
        var run = NSRange()
        XCTAssertNotNil(closed.attribute(.readerCollapsed, at: content.location, longestEffectiveRange: &run,
                                         in: NSRange(location: 0, length: closed.length)))
        XCTAssertEqual(run, content)
        XCTAssertEqual(closed.readerCollapsedRun(at: content.location + 3), content)
        closed.enumerateAttributes(in: content) { attributes, range, _ in
            XCTAssertNotNil(attributes[.readerHidden], "\(range)")
            XCTAssertNil(attributes[.readerHeading], "\(range)")
            XCTAssertNil(attributes[.link], "\(range)")
            if let attachment = attributes[.attachment] { XCTAssertTrue(attachment is ReaderCollapsedAttachment, "\(range)") }
            XCTAssertEqual((attributes[.font] as? PlatformFont)?.pointSize ?? 1, SpokenLabelAttachment.lineHeight, accuracy: 0.0001)
        }
        XCTAssertNil(closed.attribute(.readerCollapsed, at: disclosure.summary.location, effectiveRange: nil))
        // What is read of it: the summary, then the words after the details, a break apart.
        XCTAssertEqual(closed.readerPlainText(spoken: true), "Words before the chart.\n\(Self.summary)\nWords after the chart.")
        let read = open.readerPlainText(spoken: true)
        for word in Self.hiddenWords { XCTAssertTrue(read.contains(word), word) }
        // Open, it is the section as it is written, but for the triangle and the state.
        open.enumerateAttribute(.readerCollapsed, in: NSRange(location: 0, length: open.length)) { value, range, _ in
            XCTAssertNil(value, "\(range)")
        }
        // As the book has it, it is the section's own text.
        XCTAssertTrue(ReaderDisclosures.render(section.string, section.disclosures) { $0.isOpenInBook } !== section.string,
                      "closed by the book, it is collapsed")
        let opened = try self.section(Self.body.replacingOccurrences(of: "<details id=", with: "<details open=\"\" id="))
        XCTAssertTrue(ReaderDisclosures.render(opened.string, opened.disclosures) { $0.isOpenInBook } === opened.string)
    }

    func testANestedDetailsIsCollapsedWithTheOneAroundIt() throws {
        let section = try section("""
            <details open=""><summary>Outer</summary><p>Outer words.</p>\
            <details><summary>Inner</summary><p>Inner words.</p></details><p>Outer end.</p></details><p>After.</p>
            """)
        XCTAssertEqual(section.disclosures.count, 2)
        let text = section.string.string as NSString
        let outer = section.disclosures[0], inner = section.disclosures[1]
        XCTAssertTrue(outer.hides(text.range(of: "Inner words.").location))
        XCTAssertEqual(section.disclosures(hiding: text.range(of: "Inner words.").location).map(\.id), [outer.id, inner.id],
                       "outermost first: those that must open for it to show")
        let both = ReaderDisclosures.render(section.string, section.disclosures) { $0.id == outer.id }
        XCTAssertEqual(both.readerPlainText(spoken: true), "Outer\nOuter words.\nInner\nOuter end.\nAfter.")
        let none = ReaderDisclosures.render(section.string, section.disclosures) { $0.id == inner.id }
        XCTAssertEqual(none.readerPlainText(spoken: true), "Outer\nAfter.", "a closed outer one hides the inner, whatever it is")
    }

    // MARK: Layout

    func testAClosedDetailsTakesTheRoomOfItsSummaryAlone() throws {
        let size = CGSize(width: 420, height: 2000)
        let section = try section(css: H.reset)
        // The same page with nothing in the details but its summary: what a browser lays out
        // for it closed.
        let bare = try self.section("""
            <p>Words before the chart.</p><details><summary>Show the long description</summary></details>\
            <p>Words after the chart.</p>
            """, css: H.reset)
        let closed = H.view(shown(section, open: false), size: size)
        let reference = H.view(bare.string, size: size)
        let open = H.view(shown(section, open: true), size: size)
        let after = H.frame("Words after the chart.", in: section, view: closed)
        XCTAssertEqual(after.minY, H.frame("Words after the chart.", in: bare, view: reference).minY, accuracy: 0.5,
                       "the words after the details stand where they would with no content in it")
        XCTAssertEqual(H.frame(Self.summary, in: section, view: closed).minY,
                       H.frame(Self.summary, in: bare, view: reference).minY, accuracy: 0.5)
        XCTAssertGreaterThan(H.frame("Words after the chart.", in: section, view: open).minY, after.maxY + 100,
                             "open, the description and its table stand between")
        // Nothing of what is collapsed takes room, the table's rows among it.
        let content = try XCTUnwrap(section.disclosures.first?.content.first)
        for line in H.lines(in: closed, intersecting: content) where NSIntersectionRange(line.range, content).length == line.range.length {
            XCTAssertLessThan(line.frame.height, 0.01, "\(line.range)")
            XCTAssertEqual(line.frame.minY, H.frame(Self.summary, in: section, view: closed).maxY, accuracy: 1,
                           "it lies against the summary")
        }
        // The user-agent sheet's margins: the gap to the words after is that paragraph's own,
        // not the heading's that opens the description.
        let styled = try self.section(Self.body)
        let styledBare = try self.section("""
            <p>Words before the chart.</p><details><summary>Show the long description</summary></details>\
            <p>Words after the chart.</p>
            """)
        XCTAssertEqual(H.frame("Words after the chart.", in: styled, view: H.view(shown(styled, open: false), size: size)).minY,
                       H.frame("Words after the chart.", in: styledBare, view: H.view(styledBare.string, size: size)).minY,
                       accuracy: 0.5)
    }
}
