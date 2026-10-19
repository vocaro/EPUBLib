import CoreGraphics
import EPUBReading
import EPUBTestSupport
import Foundation
import ObjectiveC
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A cap on what one layout may ask of the reader's text container, for input TextKit might
/// never finish laying out. TextKit asks a container that is not a plain rectangle for the next
/// line down for as long as it has placed nothing, so a test of such input would hang the
/// suite. Under the cap the container's answer is replaced, once it has been asked `limit`
/// times, by an empty rectangle: TextKit takes that for a full container and the layout
/// returns, leaving the test to fail. The container is `final` and the layouts under test
/// make their own, so the cap goes on the method TextKit calls, for the length of `run` only.
@MainActor enum BoundedLayout {
    private typealias Answer = @convention(c) (AnyObject, Selector, CGRect, Int, NSWritingDirection, UnsafeMutablePointer<CGRect>?) -> CGRect
    private typealias Replacement = @convention(block) (AnyObject, CGRect, Int, NSWritingDirection, UnsafeMutablePointer<CGRect>?) -> CGRect
    nonisolated(unsafe) private static var asked = 0
    nonisolated(unsafe) private static var limit = Int.max

    /// Whether the layouts of the `run` under way have used up their answers.
    static var isSpent: Bool { asked > limit }

    /// Runs `body` with every `ReaderTextContainer` answering at most `limit` times between
    /// them; true when they were asked for more.
    static func run(limit: Int, _ body: () throws -> Void) throws -> Bool {
        let selector = #selector(NSTextContainer.lineFragmentRect(forProposedRect:at:writingDirection:remaining:))
        let method = try XCTUnwrap(class_getInstanceMethod(ReaderTextContainer.self, selector))
        // Were the method TextKit's own, capping it would cap every container in the process.
        XCTAssertNotEqual(method, class_getInstanceMethod(NSTextContainer.self, selector), "the reader's container answers for its lines itself")
        guard method != class_getInstanceMethod(NSTextContainer.self, selector) else { return true }
        let original = method_getImplementation(method)
        let answer = unsafeBitCast(original, to: Answer.self)
        let replacement: Replacement = { container, proposed, index, direction, remaining in
            asked += 1
            guard asked <= Self.limit else { remaining?.pointee = .zero; return .zero }
            return answer(container, selector, proposed, index, direction, remaining)
        }
        asked = 0; Self.limit = limit
        let capped = imp_implementationWithBlock(replacement)
        _ = method_setImplementation(method, capped)
        defer { _ = method_setImplementation(method, original); _ = imp_removeBlock(capped) }
        try body()
        return asked > limit
    }
}

/// TextKit cannot place a tab that has neither a tab stop after it nor a default tab interval.
/// In a plain container it ends the paragraph at the tab; a container with boxes it asks for
/// the next line down, without end. A list item's marker is followed by a tab to its one stop,
/// and that stop was not always ahead of the marker: a box left in flow starts its first line
/// on or past it, and TextKit measures a right-to-left paragraph's stops short by its tail
/// indent. A tab also reaches a paragraph that had no stop at all: one an inline box keeps, one
/// in a string marker, the one between the cells of a table flowed as rows, and any tab of a
/// `pre` block whose font gives its space no advance. Sections of a hundred bytes therefore
/// never finished laying out, and without a box in them lost the rest of the paragraph. Every
/// paragraph style the builder makes now has an interval of a point or more. Every layout here
/// runs under `BoundedLayout`, so a section that TextKit does not finish fails its test
/// instead of hanging the suite.
@MainActor final class BoxLayoutTerminationCoverageTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 400, height: 600)
    private let float = "<div style='float:left; width:60px; height:40px'>F.</div>"
    private let hebrew = "\u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD} \u{5E1}\u{5E4}\u{5E8} \u{5E7}\u{5D5}\u{5E8}\u{5D0}"

    /// Characters of the first `length` in `view` that none of its lines holds.
    private func unplaced(in view: ReaderTextView, length: Int) -> Int {
        var placed = IndexSet()
        for line in H.lines(in: view) where line.range.location < length {
            placed.insert(integersIn: line.range.location..<min(length, line.range.upperBound))
        }
        return length - placed.count
    }

    /// Lays `body` out as the reader does: the box plan, the pages, each page's column and the
    /// whole section in one column. The container may answer `limit` times in all. Fails
    /// where the layout did not finish, returning nil so that nothing lays the section out
    /// again without the cap, and otherwise unless every character has a line in each column
    /// and the pages hold the section once. `reset` leaves the reader's own style sheet out.
    @discardableResult
    private func layOut(_ body: String, css: String = "", reset: Bool = true, files: [String: Data] = [:], size: CGSize? = nil,
                        fontSize: CGFloat = 16, limit: Int = 100_000,
                        file: StaticString = #filePath, line: UInt = #line) throws -> SectionText? {
        let size = size ?? self.size
        let section = try H.build(body, css: (reset ? H.reset : "") + css, fontSize: fontSize, files: files)
        var stage = "planning its boxes", missingOnPages = 0, missingInColumn = 0
        let unfinished = try BoundedLayout.run(limit: limit) {
            _ = ReaderBoxLayout.resolve(section.string, viewport: size)
            guard !BoundedLayout.isSpent else { return }
            stage = "paginating"
            let paginator = ReaderPaginator(text: section.string, size: size)
            let pages = paginator.allPages
            guard !BoundedLayout.isSpent else { return }
            stage = "laying out a page's column"
            for page in pages { missingOnPages += unplaced(in: H.pageView(paginator, page: page), length: page.range.length) }
            guard !BoundedLayout.isSpent else { return }
            stage = "laying out the whole section in one column"
            missingInColumn = unplaced(in: H.view(section.string, size: size), length: section.string.length)
        }
        guard !unfinished else {
            XCTFail("TextKit was still asking for a line after \(limit) answers while \(stage)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(missingOnPages, 0, "every character has a line on its page", file: file, line: line)
        XCTAssertEqual(missingInColumn, 0, "every character has a line in a column of the whole section", file: file, line: line)
        H.pages(section, size: size, file: file, line: line)
        return section
    }

    // MARK: The cap

    /// The cap is what keeps these tests from hanging, so it is shown to end a layout that
    /// TextKit does not: a paragraph with a tab and neither a stop nor an interval for it, in
    /// the reader's container with a box in it. The container ends this layout itself once it
    /// has been asked for the line `ReaderTextContainer.askLimit` times (#288); the cap ends it
    /// sooner, as it would were the container's own bound gone.
    func testTheCapEndsALayoutTextKitWouldNotFinish() throws {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        let text = NSAttributedString(string: "A\ttab with nowhere to go.", attributes: [.paragraphStyle: style])
        var lines = 0
        let unfinished = try BoundedLayout.run(limit: ReaderTextContainer.askLimit / 2) {
            let storage = NSTextContentStorage(), manager = NSTextLayoutManager()
            storage.addTextLayoutManager(manager)
            let container = ReaderTextContainer(size: CGSize(width: 400, height: 0))
            container.boxRegions = [.init(range: NSRange(location: NSNotFound, length: 0), frame: CGRect(x: 0, y: 5_000, width: 60, height: 40), side: .left)]
            container.paragraphText = text
            manager.textContainer = container
            storage.attributedString = text
            manager.enumerateTextLayoutFragments(from: storage.documentRange.location, options: [.ensuresLayout]) { fragment in
                lines += fragment.textLineFragments.filter { $0.characterRange.length > 0 }.count
                return true
            }
        }
        XCTAssertTrue(unfinished, "TextKit asks for a line for this paragraph until the container stops answering")
        XCTAssertLessThanOrEqual(lines, 1, "and places no more than the text before the tab")
    }

    // MARK: The issue's sections

    /// The smallest section found that never finished, 658 bytes: at 1,024 by 300 points and a
    /// 22-point font the box plan measured `A5 again.`, a positioned box in a list item that
    /// the plan leaves in flow, beside the float before it.
    func testTheSmallestSectionThatNeverFinishedIsLaidOut() throws {
        try layOut("<div style=''><p>P2 box it returns prose to Ordinary supercalifragilistic and and a to prose box.</p><ul><li><div style='float:right; width:20vw; '>F4 and the. <span style='float:right; width:70%'>inner 4</span> a.</div></li><li><div style='position:absolute; right:10px; top:0; width:1px; '>A5 again. <span style='display:inline-block; width:100%'>ib 5</span></div></li></ul></div><div style='float:left; width:8em; clear:left;'>F6 wraps returns. <span style='float:left; width:calc(20% + 30px)'>inner 6</span> wraps the the I and.</div><div style='position:absolute; left:0; top:0; width:90px; height:240px;'>A7 returns column wraps wraps a Ordinary.</div>",
                   size: CGSize(width: 1024, height: 300), fontSize: 22)
    }

    /// The issue's second section: its box plan finished and its pagination did not.
    func testTheSectionWhosePaginationNeverFinishedIsPaged() throws {
        try layOut("<blockquote style='margin:0 10%'><p>P2 returns I a prose column and the again again prose supercalifragilistic.</p><ul><li><div style=''><p>P5 it below wraps returns a column.</p><div style='position:absolute; right:0; top:0; width:1px; '>A6 it to below prose and.</div></div></li><li><ul><li><div style='float:right; width:120px; height:240px;'>F8 again Ordinary full prose I.</div></li></ul></li></ul></blockquote><div style='position:relative; margin-left:10%;'><blockquote style='margin:0 10%'><blockquote style='margin:0 20px'><div style='position:absolute; left:5%; top:5%; width:24px; height:601px;'>A12 column.</div><ul><li><div style='float:left; width:120px; '>F14 the a. <span style='float:right; width:120px'>inner 14</span> the supercalifragilistic returns full Ordinary beside.</div></li></ul><div style='position:relative; height:200px;'><div style='float:left; width:1px; margin:8px; padding:5px; border:0px solid;'>F16 again. <span style='display:inline-block; width:24px'>ib 16</span></div></div></blockquote><div style=''><div style='position:absolute; right:0; top:10px; width:90px; '>A18 supercalifragilistic full. <span style='float:left; width:1px'>inner 18</span> and column box it wraps.</div></div></blockquote></div>")
    }

    // MARK: A list item in a box left in flow

    /// A float inside a float is left in flow at its own width, which moves the first line of
    /// the item in it onto the marker's stop. With a float already placed, the box plan
    /// measures that item beside it and did not return.
    func testAnItemInABoxLeftInFlowIsMeasuredBesideAnEarlierFloat() throws {
        try layOut("\(float)<p>Before.</p><div style='float:left; width:200px'><div style='float:right; width:100px'><ul><li>Item text here.</li></ul></div></div><p>After.</p>")
    }

    /// The same item before any box: the plan measures it in a plain container, which TextKit
    /// finishes, and the float after it gives the section the boxes its pagination then never
    /// got past.
    func testAnItemInABoxLeftInFlowIsPagedInASectionWithALaterFloat() throws {
        try layOut("<div style='float:left; width:200px'><div style='float:right; width:100px'><ul><li>Item text here.</li></ul></div></div><p>After.</p>\(float)<p>End.</p>")
    }

    /// With no other box the section is plain text and was laid out, but the item's line ended
    /// at its marker: `Item text here.` had no line and was not drawn. It follows the marker now.
    func testAnItemInABoxLeftInFlowKeepsItsTextAfterItsMarker() throws {
        guard let section = try layOut("<div style='float:left; width:200px'><div style='float:right; width:100px'><ul><li>Item text here.</li></ul></div></div><p>After.</p>") else { return }
        let view = H.view(section.string, size: size)
        let marker = H.frame("\u{2022}", in: section, view: view), text = H.frame("Item", in: section, view: view)
        XCTAssertEqual(marker.minY, text.minY, accuracy: 0.5, "the item's text is on its marker's line")
        XCTAssertGreaterThanOrEqual(text.minX, marker.maxX - 0.5, "after the marker")
        XCTAssertLessThanOrEqual(text.minX - marker.maxX, 16, "and within an em of it")
    }

    /// A table row keeps its own paragraph style, whose stops are the system's and end 336
    /// points along. In a box left in flow at the far side of a wide page the row's marker
    /// starts beyond the last of them.
    func testATableInAnItemPastTheSystemTabStopsIsLaidOut() throws {
        try layOut("\(float)<div style='float:right; width:20vw'><div style='float:right; width:50%'><ul><li><table><tr><td>Cell</td></tr></table></li></ul></div></div><p>After.</p>",
                   size: CGSize(width: 1024, height: 600))
    }

    // MARK: A tab no stop is ahead of

    /// Characters of `text` in a paragraph TextKit could not place a tab in: one with no
    /// paragraph style, or with a style whose default tab interval is under a point.
    private func withoutATabInterval(_ text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let interval = (value as? NSParagraphStyle)?.defaultTabInterval ?? 0
            if !(interval.isFinite && interval >= 1) { count += range.length }
        }
        return count
    }

    /// The text of every table cell in `text`, the cells of the tables in those cells included.
    private func cells(in text: NSAttributedString) -> [NSAttributedString] {
        var tables: [TableModel] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let row = value as? TableRowAttachment, !tables.contains(where: { $0 === row.table }) { tables.append(row.table) }
        }
        return tables.flatMap { $0.cells.flatMap { [$0.content] + cells(in: $0.content) } }
    }

    private func font(_ phrase: String, in section: SectionText) throws -> PlatformFont {
        try XCTUnwrap(section.string.attribute(.font, at: H.range(phrase, in: section).location, effectiveRange: nil) as? PlatformFont)
    }

    private func tabInterval(_ phrase: String, in section: SectionText) -> CGFloat {
        H.paragraphStyle(phrase, in: section, text: section.string).defaultTabInterval
    }

    /// Whether what follows a tab starts at `start` where the text before the tab ends at `end`:
    /// at the first multiple of `interval` after it.
    private func isNextStop(_ start: CGFloat, after end: CGFloat, every interval: CGFloat) -> Bool {
        abs(start - (start / interval).rounded() * interval) <= 0.5 && start >= end - 0.5 && start - end <= interval + 0.5
    }

    /// An inline box that keeps its white space keeps its tabs, in a block that keeps none and
    /// so gave its paragraph neither a stop nor an interval. Beside a float the box plan did
    /// not return.
    func testATabKeptByAnInlineBoxIsLaidOutBesideAFloat() throws {
        try layOut("\(float)<p>Before <span style='white-space:pre'>a&#9;b</span> after the tab.</p><p>After.</p>")
    }

    /// The same tab wherever its inline box stands, and under the reader's own style sheet.
    func testATabKeptByAnInlineBoxIsLaidOutWhereverItStands() throws {
        let kept = "<span style='white-space:pre'>a&#9;b</span>"
        let picture = ["picture.png": RichFixture.image(width: 240, height: 160)]
        for body in [
            "<p>Call <code style='white-space:pre-wrap'>f(x,&#9;y)</code> to finish.</p>",
            "<p>Text <a href='#x' style='white-space:break-spaces'>a&#9;b</a> more.</p>",
            "<h1>Head \(kept) tail</h1>",
            "<dl><dt>Term</dt><dd>Definition \(kept) tail.</dd></dl>",
            "<ul style='list-style:none'><li>Item \(kept) text.</li></ul>",
            "<table><caption>Caption \(kept) tail</caption><tr><td>1</td><td>2</td></tr></table>",
            "<p dir='rtl'>\(hebrew) \(kept) \(hebrew)</p>",
        ] {
            try layOut("\(float)\(body)<p>After.</p>")
            try layOut("\(float)\(body)<p>After.</p>", reset: false)
        }
        try layOut("<div style='float:left; width:200px'>Box \(kept) text.</div><p>After.</p>")
        try layOut("<p><span style='float:left; font-size:3em'>D</span>rop cap \(kept) and prose.</p>")
        try layOut("<img src='picture.png' alt='Picture' style='float:right; width:120px'/><p>Text \(kept) more.</p>", files: picture)
    }

    /// With no box the section is plain text and was laid out, but its paragraph ended at the
    /// tab: `b after the tab.` had no line and was not drawn. The tab advances as it does in a
    /// `pre` block of the paragraph's font, to the next multiple of eight spaces.
    func testATabKeptByAnInlineBoxAdvancesAsInAPreBlock() throws {
        guard let section = try layOut("<p>Before <span style='white-space:pre'>a&#9;b</span> after the tab.</p><p>After.</p>") else { return }
        let view = H.view(section.string, size: size)
        let before = H.frame("Before a", in: section, view: view), after = H.frame("b after", in: section, view: view)
        let interval = 8 * InlineStyling.spaceAdvance(try font("Before", in: section))
        XCTAssertEqual(tabInterval("Before", in: section), interval, accuracy: 0.01, "the paragraph's interval is eight of its spaces")
        XCTAssertEqual(before.minY, after.minY, accuracy: 0.5, "the text after the tab is on the tab's line")
        XCTAssertTrue(isNextStop(after.minX, after: before.maxX, every: interval), "at the next multiple of eight spaces: \(after.minX) after \(before.maxX)")
    }

    /// A string marker is written into its item's paragraph as it is, and one set inside has
    /// no stop: with a tab in it and a float before it, the box plan did not return.
    func testAStringMarkerWithATabSetInsideIsLaidOutBesideAFloat() throws {
        try layOut("\(float)<ul style=\"list-style:'a\\9 b' inside\"><li>Item text here.</li></ul><p>After.</p>")
        try layOut("\(float)<ul><li style=\"list-style-type:'\\9 '; list-style-position:inside\">Item text here.</li></ul><p>After.</p>")
    }

    /// In plain text the item ended at its marker's tab, and `Item text here.` was not drawn.
    func testAStringMarkerWithATabSetInsideKeepsItsItemsText() throws {
        guard let section = try layOut("<ul style=\"list-style:'a\\9 b' inside\"><li>Item text here.</li></ul><p>After.</p>") else { return }
        let view = H.view(section.string, size: size)
        let lead = view.segmentFrames(for: NSRange(location: 0, length: 1)).reduce(CGRect.null) { $0.union($1) }
        let text = H.frame("bItem text here.", in: section, view: view)
        let interval = 8 * InlineStyling.spaceAdvance(try font("Item", in: section))
        XCTAssertEqual((section.string.string as NSString).substring(to: 3), "a\tb", "the marker opens the item's paragraph")
        XCTAssertEqual(lead.minY, text.minY, accuracy: 0.5, "the rest of the marker and the item's text are on its line")
        XCTAssertTrue(isNextStop(text.minX, after: lead.maxX, every: interval), "at the next multiple of eight spaces: \(text.minX) after \(lead.maxX)")
    }

    /// A table whose rows stand in a row group inside a row group is no grid, and flows as
    /// rows of text with a tab between their cells. Beside a float the box plan did not return
    /// from the first of those tabs.
    func testATableFlowedAsTabbedRowsIsLaidOutBesideAFloat() throws {
        try layOut("\(float)<table><tbody><tbody><tr><td>One</td><td>Two</td></tr><tr><th>Three</th><td>Four</td><td>Five</td></tr></tbody></tbody></table><p>After.</p>")
    }

    /// In plain text each row ended at its first tab: only its first cell was drawn. A row's
    /// cells now follow one another on its line, each at the next multiple of eight spaces.
    func testATableFlowedAsTabbedRowsShowsEveryCell() throws {
        guard let section = try layOut("<table><tbody><tbody><tr><td>One</td><td>Two</td></tr></tbody></tbody></table><p>After.</p>") else { return }
        XCTAssertEqual(SectionContentSupport.paragraphs(section).first, "One\tTwo", "the row is a paragraph, its cells a tab apart")
        let view = H.view(section.string, size: size)
        let one = H.frame("One", in: section, view: view), two = H.frame("Two", in: section, view: view)
        let interval = 8 * InlineStyling.spaceAdvance(try font("One", in: section))
        XCTAssertEqual(one.minY, two.minY, accuracy: 0.5, "the second cell is on the first one's line")
        XCTAssertGreaterThan(two.minX, one.maxX, "after it")
        XCTAssertTrue(isNextStop(two.minX, after: one.maxX, every: interval), "at the next multiple of eight spaces: \(two.minX) after \(one.maxX)")
    }

    /// Georgia with a space that has no advance, as a book's own font may have it.
    private func fontWithoutASpaceAdvance() throws -> Data {
        let font = CTFontCreateWithName("Georgia" as CFString, 12, nil)
        guard CTFontCopyPostScriptName(font) as String == "Georgia", let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
              var data = try? Data(contentsOf: url) else { throw XCTSkip("Georgia is not installed for the embedded-face fixture") }
        func u16(_ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
        func u32(_ offset: Int) -> Int { u16(offset) << 16 | u16(offset + 2) }
        func table(_ tag: String) -> Int? {
            let wanted = tag.utf8.reduce(0) { $0 << 8 | Int($1) }
            return (0..<u16(4)).first { u32(12 + $0 * 16) == wanted }.map { u32(12 + $0 * 16 + 8) }
        }
        var space: UniChar = 0x20, glyph: CGGlyph = 0
        // `hmtx` holds an advance and a side bearing for each of the first `numberOfHMetrics` glyphs.
        guard CTFontGetGlyphsForCharacters(font, &space, &glyph, 1), let header = table("hhea"), let metrics = table("hmtx"),
              Int(glyph) < u16(header + 34) else { throw XCTSkip("Georgia's space has no metrics of its own to clear") }
        data[metrics + 4 * Int(glyph)] = 0
        data[metrics + 4 * Int(glyph) + 1] = 0
        return data
    }

    /// A `pre` block's interval is eight spaces of its font, which is nothing where the font's
    /// space has no advance: the block then had no interval, and its tabs nowhere to go. The
    /// interval is never under a point.
    func testAPreBlockInAFontWhoseSpaceHasNoAdvanceIsLaidOut() throws {
        let files = ["fonts/spaceless.ttf": try fontWithoutASpaceAdvance()]
        let css = "@font-face { font-family: \"spaceless\"; src: url(\"fonts/spaceless.ttf\") } pre { font-family: \"spaceless\" }"
        let body = "<pre>col&#9;col&#9;col\n&#9;indented</pre><p>After.</p>"
        guard let section = try layOut(body, css: css, files: files) else { return }
        XCTAssertEqual(InlineStyling.spaceAdvance(try font("indented", in: section)), 0, "the block is set in the font whose space has no advance")
        XCTAssertEqual(tabInterval("indented", in: section), 1, "and its tabs are a point apart")
        try layOut(float + body, css: css, files: files)
    }

    // MARK: The interval of every paragraph

    /// The invariant the layouts above rest on: no paragraph the builder hands to layout is
    /// without a default tab interval. Every character of a section has a paragraph style
    /// with one, and so has every copy the layout restyles (the box plan's, a page's) and the
    /// text of every table cell and note.
    func testNoParagraphOfASectionIsWithoutATabInterval() throws {
        let kept = "<span style='white-space:pre'>a&#9;b</span>"
        let body = """
            <h1>Heading \(kept)</h1><p style='margin-left:10%; text-indent:2em'>Sized at layout. \(H.prose)</p><p dir='rtl'>\(hebrew)</p>
            <ul><li>Outside.</li><li style='list-style-position:inside'>Inside.</li><li style="list-style-type:'a\\9 b'">A string.</li>
            <li style='list-style:none'>None.</li><li><p><span style='float:left; font-size:3em'>D</span>rop cap in an item.</p></li>
            <li><table><tr><td>Rows</td><td>in an item</td></tr></table></li></ul><ol dir='rtl'><li>\(hebrew)</li></ol>
            <pre>pre&#9;tabs\n&#9;line</pre><p style='white-space:pre-wrap'>kept&#9;tabs</p>
            <div style='float:left; width:120px'>Float <code style='white-space:pre-wrap'>f(x,&#9;y)</code>.</div>
            <div style='position:absolute; top:10px; right:0; width:80px'>Positioned.</div>
            <p>An <span style='display:inline-block; width:60px'>inline block</span>, <img src='missing.png' alt='a picture'/>,<br/>a break.</p>
            <div style='float:left; width:200px'><div style='float:right; width:100px'><ul><li>Left in flow.</li></ul></div></div>
            <table><caption>Caption \(kept)</caption><tr><th>Head</th><td>Cell \(kept)</td></tr>
            <tr><td><ul><li>Cell item</li></ul><table><tr><td>Inner</td><td>grid</td></tr></table></td><td><pre>cell&#9;pre</pre></td></tr></table>
            <table><tbody><tbody><tr><td>One</td><td>Two</td></tr></tbody></tbody></table><table><tr><td>One column.</td></tr></table>
            <div style='display:flex'><div>Flex one</div><div>Flex two</div></div><hr/><m:math><m:mi>x</m:mi></m:math>
            <aside epub:type='footnote' id='note'><p>A note \(kept).</p><ul><li>Its item.</li></ul></aside>
            <p style='page-break-before:always'>After a break. \(H.prose)</p>
            """
        guard let section = try layOut(body, reset: false) else { return }
        XCTAssertFalse(section.report.withheld)
        XCTAssertEqual(withoutATabInterval(section.string), 0, "every paragraph of the section has an interval")
        XCTAssertEqual(withoutATabInterval(ReaderBoxLayout.resolve(section.string, viewport: size).text), 0, "as the box plan restyles it")
        let paginator = ReaderPaginator(text: section.string, size: size)
        XCTAssertGreaterThan(paginator.allPages.count, 1)
        for page in paginator.allPages {
            XCTAssertEqual(withoutATabInterval(paginator.text(for: page)), 0, "on the page at \(page.range.location)")
        }
        let cells = cells(in: section.string)
        XCTAssertGreaterThanOrEqual(cells.count, 8, "the grids' cells, those of the grid in a cell included")
        for cell in cells { XCTAssertEqual(withoutATabInterval(cell), 0, "in the cell \(cell.string.debugDescription)") }
        let note = try XCTUnwrap(section.notes["note"])
        XCTAssertGreaterThan(note.length, 0)
        XCTAssertEqual(withoutATabInterval(note), 0, "in a note")
    }

    /// The whole book's text joins its sections with a paragraph break of its own, and a
    /// section that could not be read is a notice the builder writes without a document.
    func testTheWholeBookAndANoticeHaveATabIntervalOnEveryParagraph() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let book = NativeBook(publication: publication, typography: NativeTypography(), rich: NativeRichContent())
        defer { book.close() }
        for index in publication.spine.indices { _ = await book.build(index) }
        let whole = try XCTUnwrap(book.bookText)
        XCTAssertGreaterThan(whole.string.length, try XCTUnwrap(book.section(0)).string.length, "more than one section is joined")
        XCTAssertEqual(withoutATabInterval(whole.string), 0)
        struct Unreadable: Error {}
        let notice = SectionBuilder.withheld(SectionBuildRequest(publication: publication, spineIndex: 0, typography: NativeTypography(),
            fonts: FontRegistry(publication: publication), rich: NativeRichContent()), reason: Unreadable())
        XCTAssertGreaterThan(notice.string.length, 0)
        XCTAssertEqual(withoutATabInterval(notice.string), 0)
    }

    /// Which interval a paragraph has: eight spaces of its own box's font (CSS's initial
    /// `tab-size`), whatever font an inline box in it has and whether or not the box keeps its
    /// tabs; and the marker's width in the paragraph an outside marker opens, unless the item
    /// keeps its tabs. A `pre` block's interval and a marker's are what they were.
    func testAParagraphsTabIntervalIsItsBoxsTabSizeOrItsMarkersWidth() throws {
        let section = try H.build("""
            <p>Plain <code style='font-family:monospace; white-space:pre'>a&#9;b</code> text.</p><pre>pre&#9;tabs</pre>
            <ul><li>Bullet item.</li><li style='white-space:pre-wrap'>Kept&#9;tabs.</li></ul>
            """, css: H.reset)
        func eightSpaces(_ phrase: String) throws -> CGFloat { 8 * InlineStyling.spaceAdvance(try font(phrase, in: section)) }
        XCTAssertNotEqual(try eightSpaces("Plain"), try eightSpaces("pre"), accuracy: 0.5, "the fixture's fonts differ")
        XCTAssertNotEqual(try eightSpaces("Plain"), try eightSpaces("a\tb"), accuracy: 0.5)
        XCTAssertEqual(tabInterval("Plain", in: section), try eightSpaces("Plain"), accuracy: 0.01, "a paragraph: eight spaces of its block's font")
        XCTAssertEqual(tabInterval("pre", in: section), try eightSpaces("pre"), accuracy: 0.01, "a `pre` block: eight spaces of its own")
        let marker = InlineStyling.width(of: "\u{2022} ", font: try font("\u{2022}", in: section))
        XCTAssertEqual(tabInterval("Bullet", in: section), marker, accuracy: 0.01, "an item with an outside marker: the marker's width")
        XCTAssertEqual(tabInterval("Kept", in: section), try eightSpaces("Kept"), accuracy: 0.01, "unless it keeps its tabs")
    }

    // MARK: A float as wide as its text

    /// A drop cap that opens a list item is a float as wide as its text, which begins with the
    /// item's marker and its tab. Measured where the tab had no stop, the float came out as
    /// wide as the marker alone and stacked the marker, the tab and the capital on three lines.
    func testADropCapOpeningAnItemStandsOnItsMarkersLine() throws {
        guard let section = try layOut("<ul><li><p><span style='float:left; font-size:3em'>D</span>rop cap and the prose that wraps beside it for a few lines of the column, and then below it.</p></li></ul>") else { return }
        let view = H.view(section.string, size: size)
        let capital = H.range("D", in: section)
        XCTAssertEqual(H.lines(in: view, intersecting: NSRange(location: 0, length: capital.upperBound)).count, 1, "the marker, its tab and the capital share a line")
        let region = try XCTUnwrap(H.region("D", in: section, view: view), "the capital is a float")
        XCTAssertGreaterThanOrEqual(region.contentFrame?.width ?? 0, H.frame("D", in: section, view: view).maxX - H.frame("\u{2022}", in: section, view: view).minX - 0.5,
                                    "in a float as wide as the three")
    }

    // MARK: A right-to-left list

    /// A right-to-left list indented from the left, as the reader's own style sheet indents
    /// every list: the indent is the paragraph's tail, by which TextKit measures the marker's
    /// stop short, to behind the marker. With a box in the section its layout did not return.
    func testARightToLeftListBesideAFloatIsLaidOut() throws {
        try layOut("\(float)<ul dir='rtl'><li>\(hebrew)</li></ul><p>After.</p>", css: "ul { padding-left: 2em }")
    }

    /// The same list in a section of plain text, which was laid out with the marker alone on
    /// the item's line: no right-to-left list indented this way showed its text.
    func testARightToLeftListKeepsItsTextAfterItsMarker() throws {
        guard let section = try layOut("<ul dir='rtl'><li>\(hebrew)</li></ul><ol dir='rtl'><li>\(hebrew)</li></ol><p>After.</p>", css: "ul, ol { padding-left: 2em }") else { return }
        let view = H.view(section.string, size: size)
        for item in ["\u{2022}", "1."] {
            let marker = H.frame(item, in: section, view: view)
            let text = H.lines(in: view, intersecting: H.range(item, in: section)).first.map { entry in
                view.segmentFrames(for: NSRange(location: entry.range.location + (item as NSString).length + 1, length: 1)).reduce(CGRect.null) { $0.union($1) }
            } ?? .null
            XCTAssertFalse(text.isNull, "the item's first letter is laid out after \(item)")
            XCTAssertEqual(marker.minY, text.minY, accuracy: 0.5, "on the marker's line")
            XCTAssertLessThanOrEqual(text.maxX, marker.minX + 0.5, "to its left")
            XCTAssertLessThanOrEqual(marker.minX - text.maxX, 16, "and within an em of it")
        }
    }
}
