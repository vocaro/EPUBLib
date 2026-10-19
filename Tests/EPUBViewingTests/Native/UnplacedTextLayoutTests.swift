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

/// Text TextKit can set on no line, which the reader's text container stops laying out once
/// TextKit has asked it for a line at one character `ReaderTextContainer.askLimit` times
/// running (#288). The one such text known, a tab with neither a stop after it nor a default
/// tab interval (#227), is put back by hand: every paragraph style the builder makes now has an
/// interval. Each layout runs under `BoundedLayout`, so that a layout the bound does not end
/// fails its test instead of hanging the suite.
@MainActor final class UnplacedTextLayoutTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 400, height: 600)
    private let float = "<div style='float:left; width:60px; height:40px'>F1.</div>"
    private let later = "<div style='float:right; width:80px; height:60px'>F2 later float.</div>"
    private let notLaidOut = "Some text in this book could not be laid out and is not shown."

    /// `text` with the paragraph holding `phrase` given a style without a tab stop or interval.
    private func withoutATabInterval(_ phrase: String, in text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let string = result.string as NSString
        let paragraph = string.paragraphRange(for: string.range(of: phrase))
        result.enumerateAttribute(.paragraphStyle, in: paragraph) { value, run, _ in
            let style = (value as? NSParagraphStyle ?? .default).mutableCopy() as! NSMutableParagraphStyle
            style.tabStops = []
            style.defaultTabInterval = 0
            result.addAttribute(.paragraphStyle, value: style, range: run)
        }
        return result
    }

    /// Runs `body` with every container answering at most a hundred times the bound between
    /// them, and fails when they were asked for more.
    private func bounded(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        let limit = 100 * ReaderTextContainer.askLimit
        let unfinished = try BoundedLayout.run(limit: limit, body)
        XCTAssertFalse(unfinished, "TextKit was still asking for a line after \(limit) answers", file: file, line: line)
    }

    /// The characters of `text` outside `excluded` that none of `view`'s lines holds.
    private func unplaced(in view: ReaderTextView, length: Int, excluding excluded: NSRange) -> Int {
        var placed = IndexSet(integersIn: excluded.location..<excluded.upperBound)
        for line in H.lines(in: view) where line.range.location < length {
            placed.insert(integersIn: line.range.location..<min(length, line.range.upperBound))
        }
        return length - placed.intersection(IndexSet(integersIn: 0..<length)).count
    }

    private func paragraph(_ phrase: String, in text: NSAttributedString) -> NSRange {
        let string = text.string as NSString
        return string.paragraphRange(for: string.range(of: phrase))
    }

    /// The character `view` finds at the middle of `phrase`'s line, which a tap there selects.
    private func character(atMiddleOf phrase: String, in section: SectionText, view: ReaderTextView) -> Int {
        let frame = H.frame(phrase, in: section, view: view), origin = view.containerOrigin
        return view.characterOffset(at: CGPoint(x: frame.midX + origin.x, y: frame.midY + origin.y))
    }

    // MARK: The bound

    /// TextKit asks the container for a line at the paragraph's first character until the
    /// container stops answering, and then goes on to the next paragraph, which it sets on
    /// the line after the paragraph's first.
    func testTheContainerEndsAParagraphTextKitCannotPlace() throws {
        let stuck = NSMutableParagraphStyle()
        stuck.tabStops = []
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = 28
        let text = NSMutableAttributedString(string: "A\ttab with nowhere to go.\n", attributes: [.paragraphStyle: stuck])
        text.append(NSAttributedString(string: "After.", attributes: [.paragraphStyle: style]))
        let storage = NSTextContentStorage(), manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = ReaderTextContainer(size: CGSize(width: 400, height: 0))
        var frames: [(start: Int, frame: CGRect, lines: Int)] = []
        try bounded {
            container.boxRegions = [.init(range: NSRange(location: NSNotFound, length: 0), frame: CGRect(x: 0, y: 5_000, width: 60, height: 40), side: .left)]
            container.paragraphText = text
            manager.textContainer = container
            storage.attributedString = text
            manager.enumerateTextLayoutFragments(from: storage.documentRange.location, options: [.ensuresLayout]) { fragment in
                frames.append((storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location), fragment.layoutFragmentFrame,
                               fragment.textLineFragments.filter { $0.characterRange.length > 0 }.count))
                return true
            }
        }
        XCTAssertEqual(container.unplacedParagraphs, 1, "the container refused TextKit a line once")
        XCTAssertEqual(frames.map(\.start), [0, 26], "and TextKit laid out the paragraph after it")
        guard frames.count == 2 else { return }
        XCTAssertEqual(frames[0].lines, 0, "the paragraph it could not place has no line")
        XCTAssertEqual(frames[1].lines, 1, "the next one has its own")
        XCTAssertEqual(frames[1].frame.minY, frames[0].frame.minY + frames[1].frame.height, accuracy: 0.5,
                       "a line below the first's top")
    }

    // MARK: The rest of the section

    /// Without the bound the box plan did not return from the paragraph, and with a bare one
    /// it counted the thousand empty lines TextKit asks for: the float after it was planned
    /// 22,000 points down, the paragraph after it was drawn over the float before it, and the
    /// page broke before the second float. The rest of the section is now laid out as if the
    /// paragraph were one line, as TextKit sets it, and is as it is when the paragraph's tab
    /// has its interval: in the plan, in a column of the whole section and on every page.
    func testTheRestOfASectionIsLaidOutAsIfTheParagraphHadOneLine() throws {
        let body = "<p>Before the float.</p>\(float)<p style='white-space:pre-wrap'>Stuck&#9;tab here.</p><p>After one.</p>\(later)<p>\(H.prose)</p><p>Last.</p>"
        let control = try H.build(body, css: H.reset), built = try H.build(body, css: H.reset)
        XCTAssertEqual(control.string.string, built.string.string)
        let text = withoutATabInterval("Stuck\ttab", in: built.string)
        let stuck = paragraph("Stuck\ttab", in: text)
        XCTAssertEqual(paragraph("Stuck\ttab", in: control.string), stuck)
        var plans: [ReaderBoxGeometry?] = [], views: [ReaderTextView] = [], pages: [[ReaderPage]] = [], pageViews: [[ReaderTextView]] = []
        try bounded {
            for text in [control.string, text] {
                plans.append(ReaderBoxLayout.resolve(text, viewport: size).geometry)
                views.append(H.view(text, size: size))
                let paginator = ReaderPaginator(text: text, size: size)
                pages.append(paginator.allPages)
                pageViews.append(paginator.allPages.map { H.pageView(paginator, page: $0) })
            }
        }
        guard plans.count == 2 else { return }
        XCTAssertEqual(views[1].readerContainer.unplacedParagraphs, 1, "the column's container refused the paragraph a line")
        let planned = try XCTUnwrap(plans[0]), plan = try XCTUnwrap(plans[1])
        XCTAssertEqual(plan.paragraphs.map(\.range), planned.paragraphs.map(\.range))
        for (paragraph, expected) in zip(plan.paragraphs, planned.paragraphs) {
            XCTAssertEqual(paragraph.flowStart, expected.flowStart, accuracy: 0.01, "the plan starts the paragraph at \(paragraph.range.location) where it does with an interval")
            XCTAssertEqual(paragraph.flowEnd, expected.flowEnd, accuracy: 0.01, "and ends it there")
        }
        XCTAssertEqual(plan.regions.map(\.range), planned.regions.map(\.range))
        for (region, expected) in zip(plan.regions, planned.regions) {
            XCTAssertEqual(region.frame.minY, expected.frame.minY, accuracy: 0.01, "the box at \(region.range.location) is planned where it is with an interval")
            XCTAssertEqual(region.frame.minX, expected.frame.minX, accuracy: 0.01)
        }
        func lines(_ view: ReaderTextView, outside range: NSRange) -> [(range: NSRange, frame: CGRect)] {
            H.lines(in: view).filter { NSIntersectionRange($0.range, range).length == 0 }
        }
        let column = lines(views[1], outside: stuck), expected = lines(views[0], outside: stuck)
        XCTAssertEqual(column.map(\.range), expected.map(\.range), "the column holds every other line")
        for (line, other) in zip(column, expected) {
            XCTAssertEqual(line.frame.minX, other.frame.minX, accuracy: 0.5, "the line at \(line.range.location) is where it is with an interval")
            XCTAssertEqual(line.frame.minY, other.frame.minY, accuracy: 0.5, "the line at \(line.range.location) is where it is with an interval")
        }
        XCTAssertTrue(H.lines(in: views[1], intersecting: stuck).isEmpty, "the paragraph TextKit could not place is not drawn")
        XCTAssertEqual(views[1].readerLayoutManager.usageBoundsForTextContainer.height, views[0].readerLayoutManager.usageBoundsForTextContainer.height,
                       accuracy: 0.5, "and the section is as tall")
        XCTAssertTrue(NSLocationInRange(character(atMiddleOf: "After one.", in: control, view: views[1]), H.range("After one.", in: control)),
                      "a point on the line after it is in that line")
        XCTAssertEqual(pages[1].map(\.range), pages[0].map(\.range), "the pages break where they do with an interval")
        for (page, other) in zip(pages[1], pages[0]) {
            XCTAssertEqual(page.height, other.height, accuracy: 0.5, "the page at \(page.range.location) is as tall")
            XCTAssertLessThanOrEqual(page.height + page.topSpacing, size.height + 0.75, "and fits its column")
        }
        for (view, page) in zip(pageViews[1], pages[1]) {
            let excluded = NSRange(location: max(0, stuck.location - page.range.location), length: stuck.length)
            XCTAssertEqual(unplaced(in: view, length: page.range.length, excluding: excluded), 0, "every other character of the page at \(page.range.location) has a line on it")
        }
        XCTAssertTrue(built.report.textNotLaidOut, "the section reports text that could not be laid out")
        XCTAssertFalse(control.report.textNotLaidOut, "a section whose text was all laid out does not")
        XCTAssertTrue(NativeDisclosure.text(for: built.report)?.hasSuffix(" " + notLaidOut) == true, "and the reader discloses it")
        XCTAssertFalse(NativeDisclosure.text(for: control.report)?.contains(notLaidOut) == true)
    }

    /// TextKit sets the lines of a paragraph up to the one it cannot place, and goes on below
    /// the paragraph's last line, its spacing after left out. The plan agrees: the paragraph
    /// after it is planned where it is drawn, beside or clear of the boxes as drawn, and the
    /// box after it is planned where its lines are.
    func testAParagraphThatSetsLinesFirstIsPlannedWhereTextKitEndsIt() throws {
        let body = "<p>Before the float.</p>\(float)<p style='white-space:pre-wrap; margin: 12px 0'>A long paragraph that wraps onto more than one line in this column of four hundred points before the&#9;tab here.</p><p>After one.</p>\(later)<p>\(H.prose)</p><p>Last.</p>"
        let section = try H.build(body, css: H.reset)
        let text = withoutATabInterval("A long paragraph", in: section.string)
        let stuck = paragraph("A long paragraph", in: text)
        var plan: ReaderBoxGeometry?, view: ReaderTextView?, pages: [ReaderPage] = []
        try bounded {
            plan = ReaderBoxLayout.resolve(text, viewport: size).geometry
            view = H.view(text, size: size)
            pages = H.pages(SectionText(spineIndex: 0, href: section.href, document: section.document, string: text, map: section.map,
                                        anchors: [:], notes: [:], title: nil, report: SectionReport()), size: size).pages
        }
        let geometry = try XCTUnwrap(plan), column = try XCTUnwrap(view)
        let set = H.lines(in: column, intersecting: stuck)
        XCTAssertEqual(set.count, 2, "TextKit set the two lines before the one with the tab")
        let next = try XCTUnwrap(geometry.paragraphs.first { $0.range.location == stuck.upperBound })
        let drawn = try XCTUnwrap(H.lines(in: column, intersecting: next.range).first)
        let first = try XCTUnwrap(next.lines.first)
        XCTAssertEqual(first.frame.minY, drawn.frame.minY, accuracy: 0.5, "the paragraph after it is planned on the line it is drawn on")
        XCTAssertEqual(first.frame.minX, drawn.frame.minX, accuracy: 0.5, "and as far along")
        XCTAssertEqual(drawn.frame.minY, set.map(\.frame.maxY).max()! + drawn.frame.height, accuracy: 0.5,
                       "a line below the last that TextKit set, as if the rest were one line")
        let box = try XCTUnwrap(geometry.regions.first { NSIntersectionRange($0.range, H.range("F2 later", in: section)).length > 0 })
        let boxLine = try XCTUnwrap(H.lines(in: column, intersecting: box.range).first)
        XCTAssertEqual(box.frame.minY, boxLine.frame.minY, accuracy: 0.5, "the box after it is planned where it is drawn")
        let boxes = geometry.regions.filter { !$0.reserved }.map(\.frame)
        let prose = H.lines(in: column).filter { line in !geometry.regions.contains { NSIntersectionRange($0.range, line.range).length > 0 } }
        XCTAssertFalse(H.overlaps(prose.map(\.frame), boxes), "no line of prose is drawn over a box")
        XCTAssertGreaterThan(pages.count, 0)
        XCTAssertTrue(section.report.textNotLaidOut)
    }

    /// A section without a box keeps TextKit's plain rectangle, which ends such a paragraph at
    /// its tab, unless one of its paragraphs has indents that take up the column: the container
    /// then answers for every line, and was asked for this one without end. The paragraph's
    /// frame ends with its first line, so a point on the line after it finds that line.
    func testAParagraphTextKitCannotPlaceInASectionWithoutABoxEndsWithItsLine() throws {
        let narrow = CGSize(width: 150, height: 400)
        let body = "<p style='margin-left:200px'>Indented past the column.</p><p style='white-space:pre-wrap'>Stuck&#9;tab.</p><p>After.</p><p>Last line.</p>"
        let section = try H.build(body, css: H.reset)
        let text = withoutATabInterval("Stuck\ttab", in: section.string)
        let stuck = paragraph("Stuck\ttab", in: text)
        var view: ReaderTextView?, plain: ReaderTextView?, pages: [ReaderPage] = []
        try bounded {
            XCTAssertNil(ReaderBoxLayout.resolve(text, viewport: narrow).geometry, "the section has no box plan")
            view = H.view(text, size: narrow)
            plain = H.view(section.string, size: narrow)
            pages = ReaderPaginator(text: text, size: narrow).allPages
        }
        let column = try XCTUnwrap(view), control = try XCTUnwrap(plain)
        XCTAssertFalse(column.readerContainer.isSimpleRectangularTextContainer, "the indents make the container answer for every line")
        XCTAssertGreaterThanOrEqual(column.readerContainer.unplacedParagraphs, 1, "and it refused TextKit a line")
        XCTAssertTrue(H.lines(in: column, intersecting: stuck).isEmpty)
        XCTAssertLessThan(column.readerLayoutManager.usageBoundsForTextContainer.height,
                          control.readerLayoutManager.usageBoundsForTextContainer.height + 1, "the section is no taller than with an interval")
        XCTAssertTrue(NSLocationInRange(character(atMiddleOf: "After.", in: section, view: column), H.range("After.", in: section)),
                      "a point on the line after it is in that line")
        XCTAssertEqual(pages.last?.range.upperBound, text.length, "the pages reach the end")
        XCTAssertTrue(pages.allSatisfy { $0.height + $0.topSpacing <= narrow.height + 0.75 }, "and each fits its column")
        XCTAssertTrue(section.report.textNotLaidOut)
    }

    // MARK: The report

    /// Characters of `text` that do not carry `record`.
    private func withoutRecord(_ record: SectionLayoutRecord, in text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.readerSectionLayout, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if (value as? SectionLayoutRecord) !== record { count += range.length }
        }
        return count
    }

    /// A layout reaches the record from whatever character TextKit was refused a line at, so
    /// every character the build writes carries it: the section's, those of its table cells,
    /// which TextKit 1 lays out on their own, and those of its notes, shown on their own.
    func testEveryCharacterTheBuildWritesCarriesTheSectionsRecord() throws {
        let picture = ["picture.png": RichFixture.image(width: 240, height: 160)]
        let body = """
            <h1>Heading</h1><p>Prose with <em>emphasis</em>, <a href='#note'>a note</a> and <img src='picture.png' alt='a picture'/>.</p>
            \(float)<ul><li>Item</li><li style='list-style-position:inside'>Inside</li></ul><pre>pre&#9;tab</pre>
            <table><caption>Caption</caption><tr><th>Head</th><td><p>Cell</p><ul><li>Cell item</li></ul></td></tr></table>
            <div style='display:flex'><div>Flex one</div><div>Flex two</div></div><hr/><m:math><m:mi>x</m:mi></m:math>
            <aside epub:type='footnote' id='note'><p>The note.</p></aside><p>\(H.prose)</p>
            """
        let section = try H.build(body, css: "", files: picture)
        XCTAssertEqual(withoutRecord(section.layout, in: section.string), 0, "every character of the section")
        var cells: [NSAttributedString] = []
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if let row = value as? TableRowAttachment { cells += row.table.cells.map(\.content) }
        }
        XCTAssertFalse(cells.isEmpty, "the table is a grid")
        for cell in cells { XCTAssertEqual(withoutRecord(section.layout, in: cell), 0, "every character of the cell \(cell.string.debugDescription)") }
        let note = try XCTUnwrap(section.notes["note"])
        XCTAssertEqual(withoutRecord(section.layout, in: note), 0, "every character of the note")
    }

    @MainActor private final class Calls { var count = 0 }

    /// The record is told on the main actor, after the layout that found the text, and once.
    func testTheRecordTellsItsObserverOnce() async throws {
        let section = try H.build("\(float)<p style='white-space:pre-wrap'>Stuck&#9;tab.</p><p>After.</p>", css: H.reset)
        let calls = Calls(), told = expectation(description: "the observer is told")
        section.layout.observe { calls.count += 1; told.fulfill() }
        let text = withoutATabInterval("Stuck\ttab", in: section.string)
        try bounded {
            _ = ReaderPaginator(text: text, size: size).allPages
            XCTAssertEqual(calls.count, 0, "not inside the layout")
        }
        await fulfillment(of: [told], timeout: 5)
        try bounded { _ = H.view(text, size: size) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.count, 1, "a second layout that finds it tells no one again")
        let late = Calls(), lateTold = expectation(description: "a later observer is told of what was found")
        section.layout.observe { late.count += 1; lateTold.fulfill() }
        await fulfillment(of: [lateTold], timeout: 5)
        XCTAssertEqual(late.count, 1)
    }
}
