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

/// Runs of sized inline blocks against CSS 2.2 section 9.4.2 (inline formatting contexts) and
/// the "Floats and positioned boxes" section of `doc/native-viewer.md`: the boxes of a run sit
/// side by side on their block's line, each after the white space the source has before it, and
/// go on at the start of the next line when one is full; the text after them goes on from the
/// last box. Points, in a 400 by 600 column at 16 points unless a test says, so `5em` is 80.
@MainActor final class BoxLayoutInlineRowTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 400, height: 600)
    private let wide = ".m { display:inline-block; width:5em; text-align:center } "

    private func layout(_ body: String, css: String, size: CGSize? = nil) throws -> (section: SectionText, view: ReaderTextView) {
        let section = try H.build(body, css: H.reset + css)
        return (section, H.view(section.string, size: size ?? self.size))
    }

    private func marks(_ count: Int, _ text: String = "*") -> String {
        Array(repeating: "<span class='m'>\(text)</span>", count: count).joined(separator: " ")
    }

    /// The content box the plan gave each sized inline block of `section`, in source order.
    private func boxes(in section: SectionText, view: ReaderTextView) -> [CGRect] {
        view.readerContainer.boxRegions.filter { !$0.reserved }.sorted { $0.range.location < $1.range.location }
            .compactMap { region in section.string.attribute(.readerFlowBox, at: region.range.location, effectiveRange: nil) != nil ? region.contentFrame : nil }
    }

    /// Where the glyphs of each box's own text are drawn, in the same order.
    private func glyphs(in section: SectionText, view: ReaderTextView) -> [CGRect] {
        view.readerContainer.boxRegions.filter { !$0.reserved }.sorted { $0.range.location < $1.range.location }.map { region in
            var range = region.range
            if (section.string.string as NSString).character(at: range.upperBound - 1) == 0x0A { range.length -= 1 }
            return view.segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
        }
    }

    /// The advance of the space between two words of `phrase`'s paragraph.
    private func space(at phrase: String, in section: SectionText) throws -> CGFloat {
        let font = try XCTUnwrap(section.string.attribute(.font, at: H.range(phrase, in: section).location, effectiveRange: nil) as? PlatformFont)
        return InlineStyling.spaceAdvance(font)
    }

    /// Where CSS puts `count` boxes `width` wide that follow one another on lines from `left`
    /// to `right`, the first at `first` on the line at `top`, each `gap` after the one before.
    private func rows(_ count: Int, width: CGFloat, gap: CGFloat, first: CGFloat, top: CGFloat, pitch: CGFloat,
                      left: CGFloat = 0, right: CGFloat) -> [CGRect] {
        var result: [CGRect] = []
        var x = first, y = top
        for _ in 0..<count {
            if x + width > right + 0.01 { x = left; y += pitch }
            result.append(CGRect(x: x, y: y, width: width, height: pitch))
            x += width + gap
        }
        return result
    }

    private func assertPlaced(_ boxes: [CGRect], _ expected: [CGRect], _ label: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(boxes.count, expected.count, "every box is placed \(label)", file: file, line: line)
        for (index, (box, other)) in zip(boxes, expected).enumerated() {
            XCTAssertEqual(box.minX, other.minX, accuracy: 0.5, "box \(index) \(label)", file: file, line: line)
            XCTAssertEqual(box.minY, other.minY, accuracy: 0.5, "box \(index) \(label)", file: file, line: line)
            XCTAssertEqual(box.width, other.width, accuracy: 0.5, "box \(index) \(label)", file: file, line: line)
        }
    }

    // MARK: Rows

    func testARunAfterProseSitsSideBySideWrapsLikeWordsAndLeavesTheProseAfterItClear() throws {
        let body = "<p>Before the gap came \(marks(9)) and the prose goes on after the marks for a line or two more of ordinary words.</p><p>The next paragraph.</p>"
        let (section, view) = try layout(body, css: wide)
        XCTAssertEqual(section.string.string, "Before the gap came\n" + String(repeating: "*\n", count: 9)
            + "and the prose goes on after the marks for a line or two more of ordinary words.\nThe next paragraph.",
            "each box is a paragraph of its own in the text, as before")
        XCTAssertEqual(view.visibleText, section.string.string)
        let before = try XCTUnwrap(H.lines(in: view, intersecting: H.range("Before the gap came", in: section)).last).frame
        let gap = try space(at: "Before", in: section), pitch = before.height
        let placed = boxes(in: section, view: view)
        // 400 points take the prefix and three boxes; four fill the second line; two are left.
        let expected = rows(9, width: 80, gap: gap, first: before.maxX + gap, top: before.minY, pitch: pitch, right: 400)
        assertPlaced(placed, expected)
        XCTAssertEqual(Set(expected.map(\.minY)).count, 3, "the fixture wraps twice")
        XCTAssertEqual(expected[0].minY, before.minY, "the first row is the line the prose stopped on")
        for (mark, box) in zip(glyphs(in: section, view: view), placed) {
            XCTAssertEqual(mark.midX, box.midX, accuracy: 1, "a mark is centred in its box")
            XCTAssertEqual(mark.minY, box.minY, accuracy: 0.5)
        }
        // The prose after the run goes on from the last box, a space after it, and then below.
        let after = H.lines(in: view, intersecting: H.range("and the prose goes on", in: section))
        let last = try XCTUnwrap(expected.last)
        XCTAssertEqual(after[0].frame.minY, last.minY, accuracy: 0.5, "on the last row")
        XCTAssertEqual(after[0].frame.minX, last.maxX + gap, accuracy: 1, "a space after the last box")
        XCTAssertEqual(after[1].frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(after[1].frame.minY, last.minY + pitch, accuracy: 0.5)
        let prose = H.ink("and the prose goes on after the marks for a line or two more of ordinary words.", in: section, view: view)
        XCTAssertFalse(H.overlaps(prose, placed), "the prose after the run is clear of every box")
        XCTAssertFalse(H.overlaps(prose, H.ink("Before the gap came", in: section, view: view)))
        XCTAssertFalse(H.overlaps(H.ink("Before the gap came", in: section, view: view), placed))
        // The next block is below all of it.
        let next = H.frame("The next paragraph.", in: section, view: view)
        XCTAssertEqual(next.minX, 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(next.minY, (after.last?.frame.maxY ?? 0) - 0.5)
        BuilderHarness.assertMapRoundTrips(section)
        H.pages(section, size: size)
    }

    func testARunThatOpensItsBlockStartsThatBlocksLineWithItsIndentAndTheNextBlockIsBelowIt() throws {
        let body = "<p>A lead paragraph.</p><p class='i'>\(marks(6))</p><p>Below the rows.</p>"
        let (section, view) = try layout(body, css: wide + ".i { text-indent:24px }")
        let lead = H.frame("A lead paragraph.", in: section, view: view)
        let gap = try space(at: "A lead", in: section), pitch = lead.height
        // Not after the lead paragraph's last line: on the block's own first line, indented.
        let expected = rows(6, width: 80, gap: gap, first: 24, top: lead.maxY, pitch: pitch, right: 400)
        assertPlaced(boxes(in: section, view: view), expected)
        XCTAssertEqual(Set(expected.map(\.minY)).count, 2)
        XCTAssertEqual(expected[4].minX, 0, "the second line of the block has no indent")
        let below = H.frame("Below the rows.", in: section, view: view)
        XCTAssertEqual(below.minX, 0, accuracy: 0.5, "a new block starts its own line, not beside the last box")
        XCTAssertEqual(below.minY, lead.maxY + 2 * pitch, accuracy: 1, "below the second row")
        XCTAssertEqual(view.visibleText, section.string.string)
        H.pages(section, size: size)
    }

    func testABoxThatOpensEachParagraphStartsThatParagraphsLineWithItsWordStraightAfter() throws {
        let body = "<p><span class='l'>A</span>mber</p><p><span class='l'>B</span>asalt</p><p><span class='l'>C</span>halk</p>"
        let (section, view) = try layout(body, css: ".l { display:inline-block; width:1.5em }")
        XCTAssertEqual(section.string.string, "A\nmber\nB\nasalt\nC\nhalk")
        let placed = boxes(in: section, view: view), pitch = H.frame("mber", in: section, view: view).height
        XCTAssertEqual(placed.count, 3)
        for (index, (box, rest)) in zip(placed, ["mber", "asalt", "halk"]).enumerated() {
            XCTAssertEqual(box.minX, 0, accuracy: 0.5, "initial \(index) opens its own line")
            XCTAssertEqual(box.minY, CGFloat(index) * pitch, accuracy: 0.5, "one line a paragraph")
            XCTAssertEqual(box.width, 24, accuracy: 0.5)
            let word = H.frame(rest, in: section, view: view)
            XCTAssertEqual(word.minY, box.minY, accuracy: 0.5, "the word is on its initial's line")
            XCTAssertEqual(word.minX, 24, accuracy: 1, "straight after the box: no white space in the source")
        }
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    func testWhiteSpaceBetweenBoxesIsOneSpaceAndNoneLeavesThemTouching() throws {
        var (section, view) = try layout("<p><span class='m'>*</span><span class='m'>*</span>\n\t <span class='m'>*</span> tail</p>", css: wide)
        let gap = try space(at: "tail", in: section)
        var placed = boxes(in: section, view: view)
        XCTAssertEqual(placed.map(\.minX), [0, 80, 160 + gap], "touching, then one collapsed space")
        XCTAssertEqual(Set(placed.map(\.minY)), [0])
        XCTAssertEqual(H.frame("tail", in: section, view: view).minX, 240 + 2 * gap, accuracy: 1)
        // The boxes' own margins, borders and padding stand between their contents.
        (section, view) = try layout("<p>\(marks(3))</p>", css: wide + ".m { margin:0 6px; padding:0 4px; border:1px solid }")
        placed = boxes(in: section, view: view)
        assertPlaced(placed, rows(3, width: 80, gap: gap + 22, first: 11, top: 0, pitch: placed[0].height, right: 400))
    }

    func testAForcedBreakBetweenBoxesStartsANewRow() throws {
        let (section, view) = try layout("<p>\(marks(2))<br/>\(marks(2)) tail</p>", css: wide)
        let gap = try space(at: "tail", in: section)
        let placed = boxes(in: section, view: view)
        XCTAssertEqual(placed.count, 4)
        XCTAssertEqual(placed.map(\.minX), [0, 80 + gap, 0, 80 + gap])
        XCTAssertEqual(placed[1].minY, placed[0].minY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(placed[2].minY, placed[0].maxY - 0.5, "after the break: the next line")
        XCTAssertEqual(placed[3].minY, placed[2].minY, accuracy: 0.5)
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    func testARunInARightToLeftBlockIsSetFromTheRight() throws {
        let (section, view) = try layout("<p dir='rtl'>\(marks(6)) שלום</p>", css: wide)
        let placed = boxes(in: section, view: view)
        XCTAssertEqual(placed.count, 6)
        let gap = try space(at: "שלום", in: section)
        for (index, box) in placed.prefix(4).enumerated() {
            XCTAssertEqual(box.maxX, 400 - CGFloat(index) * (80 + gap), accuracy: 0.5, "box \(index) from the right edge")
            XCTAssertEqual(box.minY, placed[0].minY, accuracy: 0.5)
        }
        XCTAssertEqual(placed[4].maxX, 400, accuracy: 0.5, "the fifth opens the second line at the right")
        XCTAssertGreaterThanOrEqual(placed[4].minY, placed[0].maxY - 0.5)
        let word = H.frame("שלום", in: section, view: view)
        XCTAssertEqual(word.minY, placed[5].minY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(word.maxX, placed[5].minX - gap + 1, "the text after the run is to its left")
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    func testARunInAnIndentedBlockKeepsToThatBlocksEdges() throws {
        let (section, view) = try layout("<blockquote>\(marks(7)) tail</blockquote>", css: wide + "blockquote { margin:0 50px 0 30px }")
        let gap = try space(at: "tail", in: section)
        let placed = boxes(in: section, view: view)
        // 320 points between the block's edges: three to a line.
        assertPlaced(placed, rows(7, width: 80, gap: gap, first: 30, top: 0, pitch: placed[0].height, left: 30, right: 350))
        XCTAssertEqual(placed.map(\.minX).max() ?? 0, 30 + 2 * (80 + gap), accuracy: 0.5)
        XCTAssertLessThanOrEqual(placed.map(\.maxX).max() ?? 0, 350.5, "no box passes the block's right edge")
    }

    func testProseBetweenTwoRunsCarriesTheLineFromOneToTheOther() throws {
        let (section, view) = try layout("<p>One \(marks(2)) two \(marks(1)) three.</p>", css: ".m { display:inline-block; width:3em; text-align:center }")
        let gap = try space(at: "One", in: section)
        let one = H.frame("One", in: section, view: view), two = H.frame("two", in: section, view: view)
        let placed = boxes(in: section, view: view)
        XCTAssertEqual(placed.count, 3)
        XCTAssertEqual(placed[0].minX, one.maxX + gap, accuracy: 0.5)
        XCTAssertEqual(placed[1].minX, placed[0].maxX + gap, accuracy: 0.5)
        XCTAssertEqual(two.minX, placed[1].maxX + gap, accuracy: 1)
        XCTAssertEqual(placed[2].minX, two.maxX + gap, accuracy: 1, "the second run follows the prose between them")
        let three = H.frame("three.", in: section, view: view)
        XCTAssertEqual(three.minX, placed[2].maxX + gap, accuracy: 1)
        for frame in placed + [two, three] { XCTAssertEqual(frame.minY, one.minY, accuracy: 0.5, "all of it is one line") }
        XCTAssertEqual(H.lines(in: view).map { ($0.frame.minY * 2).rounded() }.max(), (one.minY * 2).rounded(), "and nothing is below it")
        XCTAssertEqual(view.visibleText, section.string.string)
        H.pages(section, size: size)
    }

    func testProseThatGoesOnFromABoxOnItsPrefixLineWrapsBelowAndTheNextBlockFollowsIt() throws {
        let tail = "and then the sentence runs on for long enough to fill the rest of this line and two more below it, word after ordinary word."
        let (section, view) = try layout("<p>One \(marks(1)) \(tail)</p><p>The next paragraph.</p>", css: wide)
        let one = H.frame("One", in: section, view: view), box = try XCTUnwrap(boxes(in: section, view: view).first)
        let gap = try space(at: "One", in: section), pitch = one.height
        let lines = H.lines(in: view, intersecting: H.range(tail, in: section))
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        XCTAssertEqual(lines[0].frame.minY, one.minY, accuracy: 0.5, "the prose goes on on the box's line")
        XCTAssertEqual(lines[0].frame.minX, box.maxX + gap, accuracy: 1)
        for (index, line) in lines.enumerated().dropFirst() {
            XCTAssertEqual(line.frame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(line.frame.minY, one.minY + CGFloat(index) * pitch, accuracy: 0.5, "line \(index) is a line below the one before")
        }
        let next = H.frame("The next paragraph.", in: section, view: view)
        XCTAssertEqual(next.minY, one.minY + CGFloat(lines.count) * pitch, accuracy: 0.5, "the next block is the line after the last")
        XCTAssertEqual(view.visibleText, section.string.string)
        H.pages(section, size: size)
    }

    /// A point just inside the leading edge of `frame`, as the reader's views take them.
    private func offset(at frame: CGRect, in view: ReaderTextView) -> Int {
        view.characterOffset(at: CGPoint(x: view.containerOrigin.x + frame.minX + 2, y: view.containerOrigin.y + frame.midY))
    }

    func testAPointOnTheProseTheBoxesOrTheProseAfterThemFindsItsOwnCharacters() throws {
        let tail = "and then the sentence runs on for long enough to fill the rest of this line and one more below it."
        let (section, view) = try layout("<p>One \(marks(2)) \(tail)</p><p>The next paragraph.</p>", css: wide)
        let one = H.range("One", in: section), after = H.range(tail, in: section)
        XCTAssertEqual(offset(at: H.frame("One", in: section, view: view), in: view), one.location)
        let regions = view.readerContainer.boxRegions.filter { !$0.reserved }.sorted { $0.range.location < $1.range.location }
        for (region, mark) in zip(regions, glyphs(in: section, view: view)) {
            XCTAssertEqual(offset(at: mark, in: view), region.range.location, "a point on a mark finds the mark")
        }
        // The prose after them is on their line, above its own paragraph's place in the flow.
        let lines = H.lines(in: view, intersecting: after)
        XCTAssertEqual(lines[0].frame.minY, H.frame("One", in: section, view: view).minY, accuracy: 0.5)
        XCTAssertEqual(offset(at: lines[0].frame, in: view), after.location, "a point on the prose after the boxes finds that prose")
        XCTAssertEqual(offset(at: lines[1].frame, in: view), lines[1].range.location)
        XCTAssertEqual(offset(at: H.frame("The next paragraph.", in: section, view: view), in: view), H.range("The next paragraph.", in: section).location)
    }

    // MARK: What the writer records

    func testTheWriterRecordsWhereEachBoxIsOnItsLine() throws {
        let section = try H.build("<p class='i'><span class='m'>a</span> <span class='m'>b</span><span class='m'>c</span><br/><span class='m'>d</span> text "
            + "<span class='m'>e</span></p><p>Other<span class='m'>f</span></p><div><div>inner</div><span class='m'>g</span></div>",
            css: H.reset + wide + ".i { text-indent:24px }")
        var records: [String: ReaderInlineBox] = [:]
        section.string.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: section.string.length)) { value, range, _ in
            guard let inline = (value as? ReaderFlowBoxParagraph)?.constraints.first?.inline else { return }
            records[(section.string.string as NSString).substring(with: NSRange(location: range.location, length: 1))] = inline
        }
        XCTAssertEqual(records.count, 7, "every sized inline block carries its place")
        let a = try XCTUnwrap(records["a"]), b = try XCTUnwrap(records["b"]), c = try XCTUnwrap(records["c"]), d = try XCTUnwrap(records["d"])
        let e = try XCTUnwrap(records["e"]), f = try XCTUnwrap(records["f"]), g = try XCTUnwrap(records["g"])
        XCTAssertEqual([a, b, c, d, e, f, g].map(\.continuesLine), [false, true, true, false, true, true, false])
        XCTAssertEqual(a.firstLineIndent, 24, "the box that opens the block takes its text-indent")
        XCTAssertEqual([b, c, d, e, f, g].map(\.firstLineIndent), [0, 0, 0, 0, 0, 0])
        XCTAssertGreaterThan(b.leadingSpace, 2, "the space before b")
        XCTAssertEqual(a.trailingSpace, b.leadingSpace)
        XCTAssertEqual([c.leadingSpace, b.trailingSpace, f.leadingSpace, g.leadingSpace], [0, 0, 0, 0])
        XCTAssertEqual(d.trailingSpace, b.leadingSpace, "the space before the text after d")
        XCTAssertEqual(e.leadingSpace, b.leadingSpace, "the space after the text before e")
        XCTAssertTrue(a.block === b.block && b.block === e.block, "one block, one line")
        XCTAssertFalse(e.block === f.block)
        // That block's own text carries the same object.
        let text = H.range("text", in: section)
        XCTAssertTrue(section.string.attribute(.readerParagraphFlow, at: text.location, effectiveRange: nil) as? ReaderParagraphFlow === d.block)
        // The break between c and d is the empty paragraph it always was.
        XCTAssertEqual(section.string.string, "a\nb\nc\n\nd\ntext\ne\nOther\nf\ninner\ng")
    }

    func testFloatsPositionedBoxesAndUnsizedInlineBlocksCarryNoLine() throws {
        let section = try H.build("<p>Text <span class='f'>float</span> <span class='a'>absolute</span> <span class='u'>unsized</span></p>",
                                  css: H.reset + ".f { float:left; width:50px } .a { position:absolute; width:50px } .u { display:inline-block }")
        var kinds: [Bool] = []
        section.string.enumerateAttribute(.readerFlowBox, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if let constraint = (value as? ReaderFlowBoxParagraph)?.constraints.first { kinds.append(constraint.inline == nil) }
        }
        XCTAssertEqual(kinds, [true, true])
    }

    // MARK: Pages

    func testEachPageShowsItsRowsWhereTheSectionHasThem() throws {
        let filler = String(repeating: "<p>An ordinary line of reading text before the marks.</p>", count: 9)
        let body = filler + "<p>Before the gap came \(marks(11)) and the prose goes on after the marks.</p>"
            + String(repeating: "<p>An ordinary line of reading text after the marks.</p>", count: 14)
        let small = CGSize(width: 400, height: 240)
        let section = try H.build(body, css: H.reset + wide)
        let whole = H.view(section.string, size: small)
        let (paginator, pages) = H.pages(section, size: small)
        XCTAssertGreaterThan(pages.count, 2)
        let run = NSUnionRange(H.range("Before the gap came", in: section), H.range("and the prose goes on after the marks.", in: section))
        let index = try XCTUnwrap(pages.firstIndex { NSLocationInRange(run.location, $0.range) })
        let page = pages[index]
        XCTAssertGreaterThanOrEqual(page.range.upperBound, run.upperBound, "the run and the prose on its rows share a page")
        let view = H.pageView(paginator, page: page)
        let expected = H.lines(in: whole, intersecting: page.range)
        let top = try XCTUnwrap(expected.map(\.frame.minY).min())
        let lines = H.lines(in: view, intersecting: view.shownCharacters)
        XCTAssertEqual(lines.map { NSRange(location: $0.range.location + page.range.location, length: $0.range.length) }, expected.map(\.range))
        for (line, other) in zip(lines, expected) {
            XCTAssertEqual(line.frame.minX, other.frame.minX, accuracy: 0.5, "\(other.range)")
            XCTAssertEqual(line.frame.minY, other.frame.minY - top, accuracy: 0.5, "\(other.range)")
            XCTAssertLessThanOrEqual(line.frame.maxY + page.topSpacing, small.height + 0.75)
        }
        // The marks on that page: two after the prose, then four to a line.
        let stars = lines.filter { NSLocationInRange($0.range.location + page.range.location, run) && $0.range.length == 2 }
        XCTAssertEqual(stars.count, 11)
        XCTAssertEqual(Dictionary(grouping: stars) { ($0.frame.minY * 2).rounded() }.values.map(\.count).sorted(), [1, 2, 4, 4])
        var overlapping = 0
        for (first, line) in lines.enumerated() {
            for other in lines.dropFirst(first + 1) where H.overlaps([line.frame.insetBy(dx: 0.5, dy: 0.5)], [other.frame.insetBy(dx: 0.5, dy: 0.5)]) { overlapping += 1 }
        }
        XCTAssertEqual(overlapping, 0, "no line of the page is drawn over another")
    }

    func testARunTallerThanAPageFallsBackToBlocksWithEveryCharacter() throws {
        let section = try H.build("<p>Before \(marks(60)) after.</p>", css: H.reset + wide)
        let small = CGSize(width: 200, height: 200)
        let (_, pages) = H.pages(section, size: small)
        XCTAssertGreaterThan(pages.count, 1, "sixty boxes two to a line do not fit one page: they page as blocks in reading order")
    }

    // MARK: Continuous scroll

    /// A long text shown part way down, as continuous scroll shows a book at a later chapter.
    /// The rows and the prose after them are laid out as in the chapter alone.
    ///
    /// This was written for TextKit having only an estimate of the text above, the chapter's
    /// lines then standing elsewhere than the plan has them. Here TextKit lays out all of the
    /// text above (every fragment's layout is available), and the 96 points the chapter stood
    /// from its planned place were the plan's: it left out the spacing before each of the six
    /// headings above, 16 points each (#377). Where TextKit does estimate, the container takes a
    /// planned paragraph's lines to the plan from its own first line (`ReaderTextContainer`).
    func testRowsAndTheProseAfterThemAreLaidOutTheSameFarIntoABook() throws {
        let chapter = try H.build(Fixture.InlineRows.body, css: Fixture.InlineRows.css)
        let alone = H.view(chapter.string, size: size, pageColumn: false)
        let expected = H.lines(in: alone)
        let book = NSMutableAttributedString()
        for index in 1...4 {
            book.append(try H.build(Fixture.InlineRows.prose(index), css: Fixture.InlineRows.css).string)
            book.append(NSAttributedString(string: "\n"))
        }
        let start = book.length
        book.append(chapter.string)
        let view = ReaderTextView(pageColumn: false)
        view.frame = CGRect(origin: .zero, size: size)
        view.readerContainer.size = CGSize(width: size.width, height: 0)
        view.readerContainer.viewportSize = size
        view.placement = ReaderTextPlacement(section: nil, offset: 0, visibleLength: book.length)
        view.setContent(book)
        view.ensureLayout(from: start, through: book.length)
        let lines = H.lines(in: view, intersecting: NSRange(location: start, length: chapter.string.length))
        XCTAssertEqual(lines.map { NSRange(location: $0.range.location - start, length: $0.range.length) }, expected.map(\.range),
                       "the chapter breaks its lines as it does alone")
        let top = try XCTUnwrap(lines.first).frame.minY, alonesTop = try XCTUnwrap(expected.first).frame.minY
        for (line, other) in zip(lines, expected) {
            XCTAssertEqual(line.frame.minX, other.frame.minX, accuracy: 0.5, "\(other.range)")
            XCTAssertEqual(line.frame.minY - top, other.frame.minY - alonesTop, accuracy: 0.5, "\(other.range)")
        }
        var overlapping = 0
        for (first, line) in lines.enumerated() {
            for other in lines.dropFirst(first + 1) where H.overlaps([line.frame.insetBy(dx: 0.5, dy: 0.5)], [other.frame.insetBy(dx: 0.5, dy: 0.5)]) { overlapping += 1 }
        }
        XCTAssertEqual(overlapping, 0, "no line is drawn over another")
        // A point on a mark or on the prose after a run finds its own characters there too.
        let text = chapter.string.string as NSString
        let star = try XCTUnwrap(lines.first { text.substring(with: NSRange(location: $0.range.location - start, length: 1)) == "*" })
        XCTAssertEqual(offset(at: star.frame, in: view), star.range.location, "a point on a mark finds the mark")
        let word = H.range("and a single word after the gap", in: chapter)
        let prose = try XCTUnwrap(lines.first { $0.range.location == start + word.location })
        XCTAssertEqual(offset(at: prose.frame, in: view), prose.range.location, "a point on the prose after the run finds that prose")
        // The plan measured all of the text above the chapter, and the chapter is where it has it.
        let planned = try XCTUnwrap(view.readerContainer.boxPage?.geometry.paragraph(at: start + H.range("The corner of the page", in: chapter).location))
        let shown = try XCTUnwrap(view.line(containing: planned.range.location))
        XCTAssertEqual(shown.frame.minY, planned.lines.first?.frame.minY ?? 0, accuracy: 0.75,
                       "the chapter is where the plan has it, below the spacing before every heading above")
    }
}
