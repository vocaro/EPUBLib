import CoreGraphics
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

/// TextKit cannot place a tab that has no tab stop after it. In a plain container it ends the
/// paragraph at the tab; a container with boxes it asks for the next line down, without end.
/// A list item's marker is followed by a tab to its one stop, and that stop was not always
/// ahead of the marker: a box left in flow starts its first line on or past it, and TextKit
/// measures a right-to-left paragraph's stops short by its tail indent. Sections of a few
/// hundred bytes therefore never finished laying out, and a right-to-left list showed its
/// markers and no text. Every layout here runs under `BoundedLayout`, so a section that
/// TextKit does not finish fails its test instead of hanging the suite.
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
    /// and the pages hold the section once.
    @discardableResult
    private func layOut(_ body: String, css: String = "", size: CGSize? = nil, fontSize: CGFloat = 16, limit: Int = 100_000,
                        file: StaticString = #filePath, line: UInt = #line) throws -> SectionText? {
        let size = size ?? self.size
        let section = try H.build(body, css: H.reset + css, fontSize: fontSize)
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
    /// the reader's container with a box in it. Without the cap this layout does not return.
    func testTheCapEndsALayoutTextKitWouldNotFinish() throws {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        let text = NSAttributedString(string: "A\ttab with nowhere to go.", attributes: [.paragraphStyle: style])
        var lines = 0
        let unfinished = try BoundedLayout.run(limit: 2_000) {
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
