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

/// Where a tab lands in a section with a float or positioned box and in one without (#334). A
/// tab with no stop of its own goes to the next multiple of its block's interval (`tab-size`,
/// CSS Text 3 §4.2), measured from the paragraph's leading edge, the edge its indents are
/// measured from: the left, and the right in right-to-left text. In a section with a box the
/// text container sets every line and TextKit is shown paragraphs without their indents, so it
/// measured the interval from each line's start: an indented paragraph's tab landed an indent
/// further along, 50.89 points from the edge where it is 61.78 without the box. Right to left
/// TextKit 2 measured it from the first line's start less the tail indent, with a box or
/// without. The same paragraphs now put their tabs in the same places in both sections, in
/// the section's layout and on its pages. Points, in a 400-point column.
@MainActor final class TabStopLayoutTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 400, height: 600)
    /// A box after every paragraph under test, which none of their lines is beside: with it the
    /// text container sets the section's lines, where TextKit sets them itself without it.
    private let box = "<div style='float:left; width:60px; height:40px'>F.</div><p>After.</p>"

    /// Where the text after each tab in the paragraph that holds `phrase` starts, from the
    /// leading edge of the column, laid out in `view`: its first character's leading edge.
    private func tabStarts(_ phrase: String, in section: SectionText, view: ReaderTextView, rtl: Bool,
                           file: StaticString = #filePath, line: UInt = #line) -> [CGFloat] {
        let string = section.string.string as NSString
        let found = string.range(of: phrase)
        XCTAssertNotEqual(found.location, NSNotFound, "\(phrase) is laid out", file: file, line: line)
        guard found.location != NSNotFound else { return [] }
        let paragraph = string.paragraphRange(for: found)
        var starts: [CGFloat] = []
        var cursor = paragraph.location
        while true {
            let tab = string.range(of: "\t", options: .literal, range: NSRange(location: cursor, length: paragraph.upperBound - cursor))
            guard tab.location != NSNotFound, tab.upperBound < paragraph.upperBound else { break }
            let after = view.segmentFrames(for: NSRange(location: tab.upperBound, length: 1)).reduce(CGRect.null) { $0.union($1) }
            XCTAssertFalse(after.isNull, "\(phrase): the text after a tab is laid out", file: file, line: line)
            starts.append(rtl ? size.width - after.maxX : after.minX)
            cursor = tab.upperBound
        }
        XCTAssertFalse(starts.isEmpty, "\(phrase): the paragraph holds a tab", file: file, line: line)
        return starts
    }

    /// The tab starts of each of `phrases` in `body`, laid out without a box in the section and
    /// with one, in the section's column and on its first page; each layout's are the same as
    /// the section's without a box, which are returned.
    private func starts(of phrases: [String], in body: String, css: String = "", rtl: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) throws -> [String: [CGFloat]] {
        var plain: [String: [CGFloat]] = [:]
        for withBox in [false, true] {
            let section = try H.build(body + (withBox ? box : ""), css: H.reset + css)
            let view = H.view(section.string, size: size)
            XCTAssertEqual(view.readerContainer.hasNonlinearGeometry, withBox,
                           "the text container sets the lines \(withBox ? "with" : "only with") a box", file: file, line: line)
            let (paginator, pages) = H.pages(section, size: size, file: file, line: line)
            let page = try XCTUnwrap(pages.first, file: file, line: line)
            let pageView = H.pageView(paginator, page: page)
            for phrase in phrases {
                let label = "\(phrase), \(withBox ? "with a box" : "without one")"
                let laidOut = tabStarts(phrase, in: section, view: view, rtl: rtl, file: file, line: line)
                let paged = tabStarts(phrase, in: section, view: pageView, rtl: rtl, file: file, line: line)
                let expected = plain[phrase] ?? laidOut
                XCTAssertEqual(laidOut.count, expected.count, label, file: file, line: line)
                XCTAssertEqual(paged.count, expected.count, "\(label), on its page", file: file, line: line)
                for (index, start) in expected.enumerated() {
                    if index < laidOut.count {
                        XCTAssertEqual(laidOut[index], start, accuracy: 0.5, "\(label): tab \(index + 1)", file: file, line: line)
                    }
                    if index < paged.count {
                        XCTAssertEqual(paged[index], start, accuracy: 0.5, "\(label): tab \(index + 1), on its page", file: file, line: line)
                    }
                }
                if !withBox { plain[phrase] = laidOut }
            }
        }
        return plain
    }

    /// Whether `start` is a multiple of `interval` from the column's leading edge.
    private func isStop(_ start: CGFloat, every interval: CGFloat) -> Bool {
        abs(start - (start / interval).rounded() * interval) <= 0.5
    }

    /// The interval of the paragraph that holds `phrase` in `body`.
    private func tabInterval(of phrase: String, in body: String) throws -> CGFloat {
        let section = try H.build(body, css: H.reset)
        return H.paragraphStyle(phrase, in: section, text: section.string).defaultTabInterval
    }

    /// Paragraphs indented by a margin, by padding and by a negative and a positive
    /// `text-indent`, a `pre` block of several lines in an indented block, the issue's paragraph
    /// whose tab is in an inline box that keeps its white space, and a list item that keeps its
    /// tabs past its marker's stop. The interval is eight of the paragraph's spaces, 30.89
    /// points at the reader's 16, and 79.13 in the `pre` block's monospaced font. With a box
    /// the margin's tab was at 50.89 (Bb), the `text-indent` ones at 63.89 and 37.89, and the
    /// inline box's 0.62 points after its `a`, where it is 11.5 points after it without one.
    func testATabLandsInTheSamePlaceWithAndWithoutABoxInTheSection() throws {
        let body = """
            <p style='margin-left:20px; white-space:pre-wrap'>Margin\tBb\tCc</p>\
            <p style='padding-left:1.5em; white-space:pre-wrap'>Padded\tBb\tCc</p>\
            <p style='margin-left:20px; text-indent:13px; white-space:pre-wrap'>Indented\tBb\tCc</p>\
            <p style='margin-left:20px; text-indent:-13px; white-space:pre-wrap'>Hanging\tBb\tCc</p>\
            <div style='margin-left:37px'><pre>Preformatted\tBb
            Second\tline\tof it
            \tThird</pre></div>\
            <p style='margin-left:20px'>Before <span style='white-space:pre'>a\tb</span> after the tab.</p>\
            <ul style='padding-left:30px'><li style='white-space:pre-wrap'>Item\tBb\tCc</li></ul>
            """
        let phrases = ["Margin", "Padded", "Indented", "Hanging", "Preformatted", "Before", "Item"]
        let starts = try starts(of: phrases, in: body)
        XCTAssertEqual(try tabInterval(of: "Margin", in: body), 8 * 3.86, accuracy: 0.1, "eight spaces")
        for phrase in phrases where phrase != "Item" {
            let interval = try tabInterval(of: phrase, in: body)
            for (index, start) in (starts[phrase] ?? []).enumerated() {
                XCTAssertTrue(isStop(start, every: interval), "\(phrase): tab \(index + 1) at a multiple of \(interval) from the edge: \(start)")
            }
        }
        XCTAssertEqual(starts["Preformatted"]?.count, 4, "the `pre` block's lines after its first have their tabs too")
    }

    /// The same with a `tab-size` of four spaces and of 50 pixels, which are 50 points at the
    /// reader's 16 (#378).
    func testATabLandsInTheSamePlaceWithAndWithoutABoxAtAnyTabSize() throws {
        for (tabSize, expected) in [("4", 4 * 3.86), ("50px", CGFloat(50))] {
            let body = """
                <p style='margin-left:20px; white-space:pre-wrap; tab-size:\(tabSize)'>Margin\tBb\tCc\tDd</p>\
                <p style='margin-left:20px; text-indent:13px; white-space:pre-wrap; tab-size:\(tabSize)'>Indented\tBb\tCc</p>
                """
            let starts = try starts(of: ["Margin", "Indented"], in: body)
            let interval = try tabInterval(of: "Margin", in: body)
            XCTAssertEqual(interval, expected, accuracy: 0.1, "tab-size: \(tabSize)")
            for (phrase, stops) in starts {
                for (index, start) in stops.enumerated() {
                    XCTAssertTrue(isStop(start, every: interval), "tab-size: \(tabSize), \(phrase): tab \(index + 1) at a multiple of \(interval): \(start)")
                }
            }
        }
    }

    /// Right to left, a paragraph indented on both sides by different amounts: its tabs land on
    /// multiples of the interval from its right edge, where TextKit 2 measured them from its first
    /// line's start less its tail indent without a box, ten points short here, and from each
    /// line's start with one. Also a `pre` block of several lines, a `text-indent` and a
    /// `tab-size`.
    func testARightToLeftTabLandsInTheSamePlaceWithAndWithoutABoxInTheSection() throws {
        let words = ["\u{5E9}\u{5DC}\u{5D5}\u{5DD}", "\u{5E2}\u{5D5}\u{5DC}\u{5DD}", "\u{5E1}\u{5E4}\u{5E8}", "\u{5E7}\u{5D5}\u{5E8}\u{5D0}"]
        let row = words.joined(separator: "\t")
        let body = """
            <div dir='rtl'>\
            <p style='margin-right:20px; margin-left:30px; white-space:pre-wrap'>\(row)</p>\
            <p style='margin-right:20px; margin-left:30px; text-indent:13px; white-space:pre-wrap'>\(words[1])\t\(row)</p>\
            <p style='margin-right:20px; white-space:pre-wrap; tab-size:4'>\(words[2])\t\(row)</p>\
            <div style='margin-right:37px; margin-left:12px'><pre>\(words[3])\t\(row)
            \(row)</pre></div></div>
            """
        let phrases = [row, "\(words[1])\t\(row)", "\(words[2])\t\(row)", "\(words[3])\t\(row)"]
        let starts = try starts(of: phrases, in: body, rtl: true)
        XCTAssertEqual(try tabInterval(of: phrases[2], in: body), 4 * 3.86, accuracy: 0.1, "four spaces")
        for (phrase, stops) in starts {
            let interval = try tabInterval(of: phrase, in: body)
            for (index, start) in stops.enumerated() {
                XCTAssertTrue(isStop(start, every: interval), "\(phrase.prefix(4)): tab \(index + 1) at a multiple of \(interval) from the right edge: \(start)")
            }
        }
        XCTAssertEqual(starts["\(words[3])\t\(row)"]?.count, 7, "the `pre` block's second line has its tabs too")
    }

    /// A flex container that centers its item moves the item's paragraph across
    /// (`ReaderAlignmentLayout`), by the width it measured the paragraph at, tab included. Its
    /// tab lands where it was measured, so the item keeps its one line, in the same place with
    /// and without a box.
    func testATabInACenteredFlexItemLandsInTheSamePlaceWithAndWithoutABox() throws {
        let body = "<div style='display:flex; justify-content:center'><p style='white-space:pre; margin-left:7px'>Centered\titem</p></div>"
        let starts = try starts(of: ["Centered"], in: body)
        for withBox in [false, true] {
            let section = try H.build(body + (withBox ? box : ""), css: H.reset)
            let view = H.view(section.string, size: size)
            let before = H.frame("Centered", in: section, view: view), after = H.frame("item", in: section, view: view)
            XCTAssertEqual(before.minY, after.minY, accuracy: 0.5, "\(withBox ? "with" : "without") a box: the item is on one line")
            XCTAssertGreaterThan(before.minX, 100, "and moved to the middle")
            XCTAssertEqual(size.width - after.maxX, before.minX - 7, accuracy: 2, "between equal margins")
        }
        XCTAssertEqual(starts["Centered"]?.count, 1)
    }
}
