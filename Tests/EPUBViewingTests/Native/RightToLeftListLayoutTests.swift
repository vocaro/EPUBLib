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

/// Right-to-left list items as the reader lays them out (#276, #124): the list is indented on
/// its start side, the right, its marker hangs in that indent, and every line of an item starts
/// at the same edge, as a left-to-right list's lines do on the left. In the page's TextKit 2
/// text, with and without a float in the section and on pages, and in a table cell's TextKit 1
/// text. Points, in a 360-point column, measured from the start side's edge.
@MainActor final class RightToLeftListLayoutTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 360, height: 600)
    private let hebrew = Array(repeating: "שלום עולם, טקסט ארוך שממשיך אל השורה הבאה", count: 5).joined(separator: " ")
    private let english = Array(repeating: "Hello world, a long text that goes on to the next line", count: 5).joined(separator: " ")

    /// Where an item is drawn, from the start side's edge: its marker's extent and where each of
    /// its lines starts, the first after the marker.
    private struct Placement {
        var marker: ClosedRange<CGFloat>
        var starts: [CGFloat]
    }

    /// From the start side's edge of a `width` column, the extent of `frame`.
    private static func extent(_ frame: CGRect, width: CGFloat, rtl: Bool) -> ClosedRange<CGFloat> {
        rtl ? (width - frame.maxX)...(width - frame.minX) : frame.minX...frame.maxX
    }

    /// The item whose text begins with `phrase`, in `view`'s layout of `text`.
    private func placement(of phrase: String, in text: NSAttributedString, view: ReaderTextView, rtl: Bool,
                           file: StaticString = #filePath, line: UInt = #line) throws -> Placement {
        let string = text.string as NSString
        let start = string.range(of: phrase).location
        XCTAssertNotEqual(start, NSNotFound, "\(phrase) is laid out", file: file, line: line)
        XCTAssertEqual(string.character(at: start - 1), 0x09, "a tab follows the marker", file: file, line: line)
        let paragraph = string.paragraphRange(for: NSRange(location: start, length: 0))
        let width = view.readerContainer.size.width
        let marker = try XCTUnwrap(view.segmentFrames(for: NSRange(location: paragraph.location, length: start - 1 - paragraph.location))
            .reduce(CGRect?.none) { $0?.union($1) ?? $1 }, file: file, line: line)
        var starts: [CGFloat] = []
        for entry in H.lines(in: view, intersecting: NSRange(location: start, length: paragraph.upperBound - start)) {
            let first = max(entry.range.location, start)
            let frame = try XCTUnwrap(view.segmentFrames(for: NSRange(location: first, length: 1)).first, file: file, line: line)
            starts.append(Self.extent(frame, width: width, rtl: rtl).lowerBound)
        }
        return Placement(marker: Self.extent(marker, width: width, rtl: rtl), starts: starts)
    }

    /// Every line of the item starts `indent` from the start side's edge, and its marker lies
    /// in the indent, a gap before the text: as a browser hangs an outside marker.
    private func assertHangs(_ placement: Placement, indent: CGFloat, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(placement.starts.count, 2, "\(label): the item wraps", file: file, line: line)
        for (index, start) in placement.starts.enumerated() {
            XCTAssertEqual(start, indent, accuracy: 0.5, "\(label): line \(index) starts at the list's start indent", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(placement.marker.lowerBound, -0.5, "\(label): the marker is in the column", file: file, line: line)
        XCTAssertLessThanOrEqual(placement.marker.upperBound, indent - 1, "\(label): a gap separates the marker from the text", file: file, line: line)
    }

    private func assertMirrors(_ rtl: Placement, _ ltr: Placement, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rtl.marker.lowerBound, ltr.marker.lowerBound, accuracy: 0.5, "\(label): the marker's outer edge", file: file, line: line)
        XCTAssertEqual(rtl.marker.upperBound, ltr.marker.upperBound, accuracy: 0.5, "\(label): the marker's inner edge", file: file, line: line)
        XCTAssertEqual(rtl.starts.first ?? -1, ltr.starts.first ?? -2, accuracy: 0.5, "\(label): the first line's text", file: file, line: line)
        XCTAssertEqual(rtl.starts.dropFirst().first ?? -1, ltr.starts.dropFirst().first ?? -2, accuracy: 0.5, "\(label): the wrapped lines", file: file, line: line)
    }

    // MARK: Page text

    /// The reader's own stylesheet indents a list 2 em on its start side (HTML 15.3.7), so a
    /// right-to-left list is the mirror of a left-to-right one. Its first line's text started a
    /// first-line indent further along than its wrapped lines, where TextKit 2 measured the
    /// marker's stop from, and the indent was on the end side.
    func testARightToLeftItemUnderTheDefaultStylesheetMirrorsALeftToRightOne() throws {
        let rtlText = try H.build("<ul dir='rtl'><li>\(hebrew)</li></ul>", css: "")
        let ltrText = try H.build("<ul><li>\(english)</li></ul>", css: "")
        let rtl = try placement(of: "שלום", in: rtlText.string, view: H.view(rtlText.string, size: size), rtl: true)
        let ltr = try placement(of: "Hello", in: ltrText.string, view: H.view(ltrText.string, size: size), rtl: false)
        assertHangs(ltr, indent: 32, "left to right")
        assertHangs(rtl, indent: 32, "right to left")
        assertMirrors(rtl, ltr, "default stylesheet")
    }

    /// The reproduction in #276: an indent on each side, as the book sets them, with the reset
    /// stylesheet. TextKit 2 measures a right-to-left stop less the tail indent too.
    func testARightToLeftItemWithIndentsOnBothSidesStartsEveryLineAtItsStartIndent() throws {
        for (label, css) in [("start only", "ul { padding-right: 40px }"), ("both sides", "ul { padding-right: 40px; padding-left: 30px }"),
                             ("by flow", "ul { padding-inline: 40px 30px }"), ("wide end", "ul { padding: 0 40px 0 90px }")] {
            let section = try H.build("<ul dir='rtl'><li>\(hebrew)</li></ul>", css: H.reset + css)
            assertHangs(try placement(of: "שלום", in: section.string, view: H.view(section.string, size: size), rtl: true), indent: 40, label)
        }
    }

    /// Numbers of more than one digit, a justified item and a nested list: each item's lines
    /// start at its own list's indent.
    func testNumberedJustifiedAndNestedRightToLeftItems() throws {
        let items = (1...10).map { "<li>פריט \($0) \(hebrew)</li>" }.joined()
        let section = try H.build("<ol dir='rtl' style='text-align:justify'>\(items)<li>אחרון<ul><li>מקונן \(hebrew)</li></ul></li></ol>", css: "")
        let view = H.view(section.string, size: size)
        for number in [1, 9, 10] {
            assertHangs(try placement(of: "פריט \(number) ", in: section.string, view: view, rtl: true), indent: 32, "item \(number)")
        }
        assertHangs(try placement(of: "מקונן", in: section.string, view: view, rtl: true), indent: 64, "nested item")
    }

    /// With a float in the section the container gives TextKit each line's indents itself
    /// (`ReaderTextContainer.lineInsets`). Beside a float on the end side and below it, every
    /// line starts at the list's indent; beside one on the start side the item is laid out as a
    /// left-to-right item beside a float on its start side, mirrored.
    func testARightToLeftItemInASectionWithAFloatMirrorsALeftToRightOne() throws {
        let css = ".f { width:80px; height:120px } .end { float:inline-end } .start { float:inline-start }"
        for side in ["end", "start"] {
            func layOut(_ direction: String, _ words: String) throws -> (SectionText, ReaderTextView) {
                let section = try H.build("<div dir='\(direction)'><figure class='f \(side)'>Box.</figure><ul><li>\(words)</li></ul></div>",
                                          css: H.reset + "ul { padding-inline-start: 2em } " + css)
                return (section, H.view(section.string, size: size))
            }
            let (rtlSection, rtlView) = try layOut("rtl", hebrew), (ltrSection, ltrView) = try layOut("ltr", english)
            let float = try XCTUnwrap(H.region("Box.", in: rtlSection, view: rtlView), side)
            XCTAssertEqual(side == "end" ? float.frame.minX : size.width - float.frame.maxX, 0, accuracy: 0.5, "the float is on the \(side) side")
            let rtl = try placement(of: "שלום", in: rtlSection.string, view: rtlView, rtl: true)
            let ltr = try placement(of: "Hello", in: ltrSection.string, view: ltrView, rtl: false)
            if side == "end" { assertHangs(rtl, indent: 32, "beside a float on the end side") }
            assertMirrors(rtl, ltr, "a float on the \(side) side")
            for (index, start) in rtl.starts.enumerated() {
                XCTAssertEqual(start, ltr.starts[index], accuracy: 0.5, "\(side): line \(index) starts where its mirror does")
            }
        }
    }

    /// Pages lay a list out as the section does, and an item continued on the next page starts
    /// its lines there at the same indent.
    func testRightToLeftItemsKeepTheirIndentOnEveryPage() throws {
        let items = (1...6).map { "<li>פריט \($0) \(hebrew)</li>" }.joined()
        let section = try H.build("<ol dir='rtl'>\(items)</ol>", css: "")
        let (paginator, pages) = H.pages(section, size: CGSize(width: 360, height: 200))
        XCTAssertGreaterThan(pages.count, 2)
        var markers = 0
        for page in pages {
            let view = H.pageView(paginator, page: page)
            let text = paginator.text(for: page)
            let string = text.string as NSString
            for entry in H.lines(in: view) where entry.range.location < page.range.length {
                // A marker's line starts after its tab, and a line of the item continued from the page before at its first character.
                let tab = string.range(of: "\t", range: entry.range)
                if tab.location != NSNotFound { markers += 1 }
                let first = tab.location == NSNotFound ? entry.range.location : tab.upperBound
                guard first < entry.range.upperBound, string.character(at: first) != 0x0A else { continue }
                let frame = try XCTUnwrap(view.segmentFrames(for: NSRange(location: first, length: 1)).first)
                XCTAssertEqual(size.width - frame.maxX, 32, accuracy: 0.5, "page at \(page.range.location): line \(entry.range)")
            }
        }
        XCTAssertEqual(markers, 6, "every item's marker is on a page")
    }

    // MARK: Table cells

    /// A cell lays its text out with TextKit 1 (`TableCellLayout`), which measures a
    /// right-to-left stop from the right edge as the stylesheet sets it. The list is indented
    /// on the start side there too, with every line at its indent, inside the cell's padding.
    func testARightToLeftItemInATableCellStartsEveryLineAtItsStartIndent() throws {
        for (label, direction, words) in [("right to left", "rtl", hebrew), ("left to right", "ltr", english)] {
            let section = try H.build("<table style='border-spacing:0' dir='\(direction)'><tr><td style='padding:0 20px'><ul><li>\(words)</li></ul></td>"
                + "<td>Second cell.</td></tr></table><p>After.</p>", css: "")
            let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
            let width: CGFloat = 360
            let layout = TableRowAttachment(table: table, row: 0).layout(width: width, viewportHeight: 600)
            let cell = layout.cellText[0], column = layout.contentFrames[0]
            XCTAssertGreaterThan(column.width, 200, "\(label): the list's cell is wide enough to wrap in")
            XCTAssertEqual(layout.cellFrames[0].width - column.width, 40, accuracy: 0.5, "\(label): the cell's padding is outside its column")
            // The cell's own text in a container as `TableCellLayout` makes one, so that its glyphs can be measured.
            let storage = NSTextStorage(attributedString: cell.interactionText)
            let manager = NSLayoutManager()
            let container = ReaderTextContainer(size: CGSize(width: max(1, column.width), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager); manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            func frame(_ range: NSRange) -> CGRect {
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var result = CGRect.null
                manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in result = result.union(rect) }
                return result
            }
            var lines: [NSRange] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
                lines.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            }
            XCTAssertEqual(lines, cell.lines.map(\.characters), "\(label): the cell's lines")
            let string = cell.interactionText.string as NSString
            let tab = string.range(of: "\t")
            XCTAssertNotEqual(tab.location, NSNotFound)
            let rtl = direction == "rtl"
            var placement = Placement(marker: Self.extent(frame(NSRange(location: 0, length: tab.location)), width: column.width, rtl: rtl), starts: [])
            for line in lines where line.upperBound > tab.upperBound {
                placement.starts.append(Self.extent(frame(NSRange(location: max(line.location, tab.upperBound), length: 1)), width: column.width, rtl: rtl).lowerBound)
            }
            assertHangs(placement, indent: 32, label)
        }
    }
}
