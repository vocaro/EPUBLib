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

/// The reader's fragments with chosen margins, by the offset each paragraph starts at.
private final class BoxMarginFragments: NSObject, NSTextLayoutManagerDelegate {
    let margins: [Int: (top: CGFloat, bottom: CGFloat)]
    weak var storage: NSTextContentStorage?
    init(margins: [Int: (top: CGFloat, bottom: CGFloat)], storage: NSTextContentStorage) { self.margins = margins; self.storage = storage }

    func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in element: NSTextElement) -> NSTextLayoutFragment {
        let fragment = ReaderBoxLayoutFragment(textElement: element, range: nil)
        if let storage, let margin = margins[storage.offset(from: storage.documentRange.location, to: location)] {
            fragment.topAdjustment = margin.top; fragment.bottomAdjustment = margin.bottom
        }
        return fragment
    }
}

/// Box geometry where it meets pages, relayout, hit testing and hostile input: what
/// `doc/native-viewer.md` promises of groups, fallbacks and "recompute geometry from source
/// formatting", and that untrusted lengths and counts neither crash nor stall the layout.
@MainActor final class BoxLayoutPaginationCoverageTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let size = CGSize(width: 400, height: 600)

    /// Floats, a drop cap, positioned boxes, a sized inline-block and aligned boxes in one section.
    private let mixedBody = """
        <h2>Mixed boxes</h2><figure class="l">Left figure caption.</figure><p>First prose. \(BoxLayoutHarness.prose)</p>\
        <p><span class="cap">D</span>rop cap paragraph. \(BoxLayoutHarness.prose)</p><aside class="abs">Absolute callout words.</aside>\
        <figure class="r">Right figure caption.</figure><p>Second prose. \(BoxLayoutHarness.prose)</p>\
        <p>Before inline <span class="ib">Sized inline box.</span> after inline. \(BoxLayoutHarness.prose)</p>\
        <div class="rel"><p>Relative block words.</p></div><div class="flex"><p>Centred flex words.</p><p>Second flex line.</p></div>\
        <div class="grid"><p>Grid cell words.</p></div><p>Closing prose. \(BoxLayoutHarness.prose)</p>
        """
    private let mixedCSS = """
        figure { width:35% } .l { float:left; margin-right:8px } .r { float:right; clear:right; padding:4px }
        .cap { float:left; font-size:3em } .abs { position:absolute; right:0; top:40px; width:30% }
        .ib { display:inline-block; width:4em; height:2em } .rel { position:relative; margin-left:10%; left:-2% }
        .flex { display:flex; flex-direction:column; justify-content:center; align-items:center; min-height:50vh; gap:1em }
        .grid { display:grid; place-items:center; height:20vh }
        """

    private func build(_ body: String, css: String, fontSize: CGFloat = 16) throws -> SectionText {
        try H.build(body, css: H.reset + css, fontSize: fontSize)
    }

    /// `phrase`'s frame on the page showing it, from the top of that page's text.
    private func paged(_ phrase: String, in section: SectionText, _ paginator: ReaderPaginator, pages: [ReaderPage],
                       file: StaticString = #filePath, line: UInt = #line) throws -> (page: Int, frame: CGRect, view: ReaderTextView) {
        let range = H.range(phrase, in: section, file: file, line: line)
        let index = try XCTUnwrap(pages.firstIndex { NSLocationInRange(range.location, $0.range) }, file: file, line: line)
        let view = H.pageView(paginator, page: pages[index])
        let frames = view.segmentFrames(for: NSRange(location: range.location - pages[index].range.location, length: range.length))
        XCTAssertFalse(frames.isEmpty, "\(phrase) is laid out on its page", file: file, line: line)
        return (index, frames.reduce(CGRect.null) { $0.union($1) }, view)
    }

    private func assertLinesFit(_ view: ReaderTextView, page: ReaderPage, size: CGSize, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for entry in H.lines(in: view) where NSIntersectionRange(entry.range, view.shownCharacters).length > 0 {
            XCTAssertGreaterThanOrEqual(entry.frame.minY, -0.75, label, file: file, line: line)
            XCTAssertLessThanOrEqual(entry.frame.maxY + page.topSpacing, size.height + 0.75, label, file: file, line: line)
        }
    }

    // MARK: Pages

    /// "A box and the prose wrapping beside it stay together when they fit a page."
    func testAFloatGroupThatWouldCrossAPageBoundaryMovesWholeToTheNextPage() throws {
        let section = try build("<p class='lead'>Lead words.</p><figure>Alpha box.</figure><p>\(H.prose)</p>",
                                css: ".lead { margin-bottom:480px } figure { float:left; width:100px; height:200px }")
        let (paginator, pages) = H.pages(section, size: size)
        let plan = try XCTUnwrap(paginator.text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage)
        let caption = H.range("Alpha box.", in: section)
        let group = try XCTUnwrap(plan.geometry.group(containing: caption.location))
        XCTAssertGreaterThanOrEqual(plan.geometry.bounds(of: group).height, 199)
        XCTAssertEqual(pages.first?.range, NSRange(location: 0, length: group.location), "the first page ends early rather than splitting the group")
        let float = try paged("Alpha box.", in: section, paginator, pages: pages)
        XCTAssertEqual(float.page, 1)
        XCTAssertGreaterThanOrEqual(pages[1].range.upperBound, group.upperBound)
        XCTAssertEqual(float.frame.minY, 0, accuracy: 1, "the box opens its page")
        let beside = H.lines(in: float.view).filter { $0.range.location >= caption.upperBound - pages[1].range.location && $0.frame.minY < 199 }
        XCTAssertFalse(beside.isEmpty)
        XCTAssertTrue(beside.allSatisfy { $0.frame.minX >= 99 }, "its prose is beside it on that page")
        assertLinesFit(float.view, page: pages[1], size: size, "page 1")
    }

    /// "Oversized groups … continue as native blocks in reading order."
    func testAFloatTallerThanAPageFallsBackToFlowWithEveryCharacter() throws {
        for declarations in ["float:left; width:100px; height:700px", "float:right; width:100px; height:200vh", "position:absolute; top:0; right:0; width:100px; height:601px"] {
            let section = try build("<figure>Alpha box.</figure><p>\(H.prose)</p>", css: "figure { \(declarations) }")
            let view = H.view(section.string, size: size)
            XCTAssertTrue(view.readerContainer.boxRegions.isEmpty, declarations)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(H.lines(in: view, intersecting: H.range(H.prose, in: section)).first).frame.minY,
                                        H.frame("Alpha box.", in: section, view: view).maxY - 0.5, "reading order: \(declarations)")
            XCTAssertEqual(view.visibleText, section.string.string, declarations)
            XCTAssertTrue(section.report.flowBoxesReflowed, declarations)
            H.pages(section, size: size, declarations)
        }
    }

    func testEveryPageOfAMixedBoxSectionShowsItsOwnTextOnceWithinItsColumn() throws {
        for fontSize: CGFloat in [16, 25] {
            let section = try build(mixedBody, css: mixedCSS, fontSize: fontSize)
            XCTAssertTrue(section.report.flowBoxesReflowed)
            BuilderHarness.assertMapRoundTrips(section)
            for viewport in [CGSize(width: 180, height: 240), CGSize(width: 362, height: 660), CGSize(width: 720, height: 980)] {
                let label = "\(Int(viewport.width))x\(Int(viewport.height)) at \(Int(fontSize))"
                let (paginator, pages) = H.pages(section, size: viewport, label)
                var shown = ""
                for (index, page) in pages.enumerated() {
                    let view = H.pageView(paginator, page: page)
                    shown += view.visibleText
                    assertLinesFit(view, page: page, size: viewport, "\(label), page \(index)")
                }
                XCTAssertEqual(shown, section.string.string, label)
            }
        }
    }

    /// An aligned box whose first line has no room left on a page: it opens the next page with
    /// its own space above the line, kept in full.
    func testAnAlignedBoxAtAPageBoundaryMovesToTheNextPageWithItsLead() throws {
        let section = try build("<p class='lead'>Lead words.</p><div class='box'><p>Centred words.</p></div><p>After the box.</p>",
                                css: ".lead { margin-bottom:450px } .box { display:flex; flex-direction:column; justify-content:center; height:300px }")
        let (paginator, pages) = H.pages(section, size: size)
        XCTAssertEqual(pages.count, 2)
        let centred = try paged("Centred words.", in: section, paginator, pages: pages)
        XCTAssertEqual(centred.page, 1)
        XCTAssertEqual(pages[1].range.location, H.range("Centred words.", in: section).location, "the box opens the page")
        XCTAssertEqual(pages[1].topSpacing + centred.frame.midY, 150, accuracy: 2, "centred in its 300 points from the top of the page")
        let after = try paged("After the box.", in: section, paginator, pages: pages)
        XCTAssertEqual(after.page, 1)
        XCTAssertEqual(pages[1].topSpacing + after.frame.minY, 300, accuracy: 2)
    }

    /// A page that opens just below a box as wide as the column is the section's own layout
    /// from that line down: each line breaks where the whole section breaks it and stands as
    /// far below the page's first line, a float further down the page keeps its place with its
    /// prose beside it, and a point on the first line hits the page's first word.
    func testAPageOpeningBelowAFullWidthBoxIsLaidOutAsTheSectionIs() throws {
        let short = Array(repeating: "Ordinary prose returns to the full column below the box.", count: 3).joined(separator: " ")
        let rest = "After the box. \(short)</p><figure class='y'>Second box.</figure><p>Beside second. \(H.prose)</p>"
        let kinds = [("a float as wide as the column", "<figure class='x'>Boxed words.</figure><p>" + rest, ".x { float:left; width:100%; height:100px }"),
                     ("an absolute box as wide as the column", "<aside class='x'>Boxed words.</aside><p>" + rest, ".x { position:absolute; width:100%; height:100px }"),
                     ("a sized inline-block wider than the column", "<p>Before <span class='x'>Boxed words.</span> " + rest, ".x { display:inline-block; width:500px; height:100px }")]
        for (name, body, css) in kinds {
            var checked = false
            // A margin under the first paragraph moves the box down to the foot of the first page.
            for margin in stride(from: 380, through: 520, by: 10) where !checked {
                let section = try build("<p class='lead'>Lead words.</p>" + body,
                                        css: ".lead { margin-bottom:\(margin)px } .y { float:left; width:120px; height:90px } " + css)
                let (paginator, pages) = H.pages(section, size: size, name)
                let after = H.range("After the box.", in: section), beside = H.range("Beside second.", in: section)
                guard let index = pages.firstIndex(where: { $0.range.location == after.location }), index > 0,
                      NSLocationInRange(beside.location, pages[index].range) else { continue }
                checked = true
                let page = pages[index], label = "below \(name) (lead margin \(margin))"
                let view = H.pageView(paginator, page: page)
                assertLinesFit(view, page: page, size: size, label)
                // The whole section in one view, measured from the line that opens the page.
                let whole = H.view(section.string, size: size)
                let expected = H.lines(in: whole, intersecting: page.range)
                let top = try XCTUnwrap(expected.first, label).frame.minY
                let lines = H.lines(in: view, intersecting: view.shownCharacters)
                XCTAssertEqual(lines.map { NSRange(location: $0.range.location + page.range.location, length: $0.range.length) }, expected.map(\.range),
                               "the section's line breaks, \(label)")
                for (line, other) in zip(lines, expected) {
                    XCTAssertEqual(line.frame.minX, other.frame.minX, accuracy: 0.5, "\(label) \(other.range)")
                    XCTAssertEqual(line.frame.minY, other.frame.minY - top, accuracy: 0.5, "\(label) \(other.range)")
                }
                // The float further down the page: where the section has it, its prose beside it.
                let region = try XCTUnwrap(H.region("Second box.", in: section, view: whole), label).frame.offsetBy(dx: 0, dy: -top)
                XCTAssertGreaterThan(region.minY, 60, "the second float is below the page's first lines, \(label)")
                let caption = H.range("Second box.", in: section)
                let words = view.segmentFrames(for: NSRange(location: caption.location - page.range.location, length: caption.length))
                XCTAssertFalse(words.isEmpty, label)
                XCTAssertTrue(words.allSatisfy { region.insetBy(dx: -1, dy: -1).contains($0) }, "the float's words are in its box, \(label)")
                let wrapped = lines.filter { $0.range.location >= beside.location - page.range.location && $0.frame.minY < region.maxY - 0.5 }
                XCTAssertGreaterThanOrEqual(wrapped.count, 3, label)
                XCTAssertTrue(wrapped.allSatisfy { $0.frame.minX >= region.maxX - 0.5 }, "prose stays beside the float, \(label)")
                let first = try XCTUnwrap(lines.first, label)
                let hit = view.characterOffset(at: CGPoint(x: view.containerOrigin.x + first.frame.minX + 2, y: view.containerOrigin.y + first.frame.midY))
                XCTAssertLessThanOrEqual(hit, 1, "a point on the first line hits the page's first word, \(label)")
            }
            XCTAssertTrue(checked, "the fixture puts the prose and the second float on one page: \(name)")
        }
    }

    /// The same below a forced break, where the page keeps the paragraph's own margin above its
    /// first line: the column starts that far down and the line at the column's top.
    func testProseAfterAForcedBreakBelowAFullWidthFloatOpensItsColumn() throws {
        let section = try build("<p class='lead'>Lead words.</p><figure>Boxed words.</figure><p class='b'>After the box. \(H.prose)</p>",
                                css: ".lead { margin-bottom:100px } figure { float:left; width:100%; height:100px } .b { break-before:page; margin-top:30px }")
        let (paginator, pages) = H.pages(section, size: size)
        XCTAssertEqual(pages.count, 2)
        let page = try XCTUnwrap(pages.last)
        XCTAssertEqual(page.range.location, H.range("After the box.", in: section).location, "the forced break opens the page")
        XCTAssertEqual(page.topSpacing, 30, accuracy: 0.5)
        let view = H.pageView(paginator, page: page)
        let lines = shownLines(view)
        XCTAssertGreaterThan(lines.count, 10)
        XCTAssertEqual(lines.first?.frame.minY ?? -1, 0, accuracy: 0.5, "the prose opens its column")
        XCTAssertEqual(lines.map(\.frame.maxY).max() ?? 0, page.height, accuracy: 0.5, "the page is as tall as its lines")
        assertLinesFit(view, page: page, size: size, "the page after the break")
    }

    func testALongParagraphBesideATallFloatInAVeryWideColumnWrapsAllTheWayDown() throws {
        let long = Array(repeating: "Ordinary prose wraps beside the box and returns to the full column below it.", count: 420).joined(separator: " ")
        XCTAssertGreaterThan(long.utf16.count, 30_000)
        let section = try build("<figure>Alpha box.</figure><p>\(long)</p>", css: "figure { float:left; width:100px; height:500px }")
        let wide = CGSize(width: 6000, height: 600)
        let view = H.view(section.string, size: wide)
        let region = try XCTUnwrap(H.region("Alpha box.", in: section, view: view))
        XCTAssertEqual(region.frame.height, 500, accuracy: 1)
        let lines = H.lines(in: view, intersecting: NSRange(location: region.range.upperBound, length: section.string.length - region.range.upperBound))
        let beside = lines.filter { $0.frame.minY < region.frame.maxY - 0.5 }
        XCTAssertGreaterThan(beside.count, 10)
        XCTAssertTrue(beside.allSatisfy { $0.frame.minX >= 99 }, "every row beside the float is planned, not only the first 8,194 characters")
        XCTAssertEqual(view.visibleText, section.string.string)
        H.pages(section, size: wide)
    }

    // MARK: Relayout

    /// "Resizing and reader typography changes recompute geometry from source formatting."
    func testRelayoutAtANewSizeMatchesAFreshLayoutAtThatSize() throws {
        let section = try build(mixedBody, css: mixedCSS)
        let sizes = [CGSize(width: 362, height: 660), CGSize(width: 640, height: 720), CGSize(width: 300, height: 420), CGSize(width: 362, height: 660)]
        let view = H.view(section.string, size: sizes[0], pageColumn: false)
        let selection = H.range("Absolute callout", in: section)
        view.selectedRange = selection
        for viewport in sizes.dropFirst() {
            view.frame = CGRect(origin: .zero, size: viewport)
            view.readerContainer.size = CGSize(width: viewport.width, height: 0)
            view.readerContainer.viewportSize = viewport
            view.refreshFlowBoxLayout()
            view.ensureFullLayout()
            let fresh = H.view(section.string, size: viewport, pageColumn: false)
            let relaid = H.lines(in: view), expected = H.lines(in: fresh)
            XCTAssertEqual(relaid.map(\.range), expected.map(\.range), "the same line breaks at \(viewport)")
            for (line, other) in zip(relaid, expected) {
                XCTAssertEqual(line.frame.minX, other.frame.minX, accuracy: 0.5, "\(viewport) \(line.range)")
                XCTAssertEqual(line.frame.minY, other.frame.minY, accuracy: 0.5, "\(viewport) \(line.range)")
                XCTAssertEqual(line.frame.width, other.frame.width, accuracy: 0.5, "\(viewport) \(line.range)")
            }
            XCTAssertEqual(view.readerContainer.boxRegions.map(\.range), fresh.readerContainer.boxRegions.map(\.range), "\(viewport)")
            for (region, other) in zip(view.readerContainer.boxRegions, fresh.readerContainer.boxRegions) {
                XCTAssertEqual(region.frame.minX, other.frame.minX, accuracy: 0.5, "\(viewport)"); XCTAssertEqual(region.frame.minY, other.frame.minY, accuracy: 0.5, "\(viewport)")
                XCTAssertEqual(region.frame.width, other.frame.width, accuracy: 0.5, "\(viewport)"); XCTAssertEqual(region.frame.height, other.frame.height, accuracy: 0.5, "\(viewport)")
            }
            XCTAssertEqual(view.contentStorage.textStorage?.string, section.string.string)
            XCTAssertEqual(view.selectedRange, selection, "\(viewport)")
        }
    }

    /// A reader font size is a rebuild: the same characters, map and anchors at every size.
    func testReaderFontSizeChangesBoxGeometryButNoCharacters() throws {
        let sections = try [12, 16, 25, 40].map { try build(mixedBody, css: mixedCSS, fontSize: $0) }
        for section in sections.dropFirst() {
            XCTAssertEqual(section.string.string, sections[0].string.string)
            XCTAssertEqual(section.map, sections[0].map)
            XCTAssertEqual(section.anchors, sections[0].anchors)
            H.pages(section, size: size)
        }
        // An em-sized box grows with the text; a percentage-sized one does not.
        for fontSize: CGFloat in [12, 16, 25, 40] {
            let section = try build("<figure>Left figure caption.</figure><p>\(H.prose)</p><p>Before <span class='ib'>Sized inline box.</span> after.</p>",
                                    css: "figure { float:left; width:35% } .ib { display:inline-block; width:8em }", fontSize: fontSize)
            let view = H.view(section.string, size: CGSize(width: 800, height: 900))
            XCTAssertEqual(try XCTUnwrap(H.region("Sized inline box.", in: section, view: view)).frame.width, 8 * fontSize, accuracy: 1, "\(fontSize)")
            XCTAssertEqual(try XCTUnwrap(H.region("Left figure caption.", in: section, view: view)).frame.width, 280, accuracy: 1, "\(fontSize)")
        }
    }

    // MARK: Expected product defects

    /// The lines of a page's own characters, by where their text is drawn and selected.
    private func shownLines(_ view: ReaderTextView) -> [(range: NSRange, frame: CGRect)] {
        H.lines(in: view).filter { NSIntersectionRange($0.range, view.shownCharacters).length > 0 }.map { line in
            (line.range, view.segmentFrames(for: line.range).reduce(CGRect.null) { $0.union($1) })
        }
    }

    /// A page shows every line of its own characters: none above its top or below its column.
    /// Prose that follows a box as wide as the column and opens the next page starts at that
    /// page's top; its first lines were once laid out twice the box's height above it.
    func testProseOpeningAPageBelowAFullWidthBoxIsDrawnOnThatPage() throws {
        let prose = "After the box. \(H.prose) \(H.prose)"
        let kinds = [("a float as wide as the column", "<figure class='x'>Boxed words.</figure><p>\(prose)</p>", ".x { float:left; width:100%; height:100px }"),
                     ("an absolute box as wide as the column", "<aside class='x'>Boxed words.</aside><p>\(prose)</p>", ".x { position:absolute; width:100%; height:100px }"),
                     ("a sized inline-block wider than the column", "<p>Before <span class='x'>Boxed words.</span> \(prose)</p>", ".x { display:inline-block; width:500px; height:100px }")]
        for (name, body, css) in kinds {
            var checked = false
            // A margin under the first paragraph moves the box down to the foot of the first page.
            for margin in stride(from: 380, through: 520, by: 10) where !checked {
                let section = try build("<p class='lead'>Lead words.</p>" + body, css: ".lead { margin-bottom:\(margin)px } " + css)
                let (paginator, pages) = H.pages(section, size: size, name)
                let after = H.range("After the box.", in: section)
                guard let index = pages.firstIndex(where: { $0.range.location == after.location }), index > 0 else { continue }
                checked = true
                let lines = shownLines(H.pageView(paginator, page: pages[index]))
                XCTAssertEqual(lines.first?.frame.minY ?? -1, 0, accuracy: 1, "the prose opens the page at its top, below \(name) (lead margin \(margin))")
                XCTAssertEqual(lines.filter { $0.frame.minY < -0.75 }.count, 0, "lines above the page's top edge, below \(name) (lead margin \(margin))")
            }
            XCTAssertTrue(checked, "the fixture puts the prose at the top of a page: \(name)")
        }
    }

    /// `clear` puts a paragraph exactly at a float's bottom edge. On a page that does not start
    /// at the section's start, that first line is laid out beside the float's column as though
    /// the float went on, so the page's lines break differently from the measured ones and the
    /// last of them falls below the page.
    func testAClearedParagraphBelowAFloatIsLaidOutOnALaterPageAsItWasMeasured() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/147")
        let small = CGSize(width: 180, height: 240)
        let section = try build("<p class='lead'>Lead.</p><p>Before words.</p><figure>Float box.</figure><p class='c'>After the float. \(H.prose)</p>",
                                css: ".lead { margin-bottom:216px } figure { float:left; width:60px; height:75px } .c { clear:both }")
        // The whole section, from its own origin: the cleared paragraph starts at the column's edge.
        let whole = H.view(section.string, size: small)
        XCTAssertEqual(H.frame("After the float.", in: section, view: whole).minX, 0, accuracy: 1)
        let (paginator, pages) = H.pages(section, size: small)
        let after = H.range("After the float.", in: section)
        let index = try XCTUnwrap(pages.firstIndex { NSLocationInRange(after.location, $0.range) })
        XCTAssertEqual(pages[index].range.location, H.range("Before words.", in: section).location, "the float and the cleared paragraph share the second page")
        let lines = shownLines(H.pageView(paginator, page: pages[index]))
        let first = try XCTUnwrap(lines.first { NSLocationInRange(after.location - pages[index].range.location, $0.range) })
        XCTAssertEqual(first.frame.minX, 0, accuracy: 1, "below the float the line starts at the column's edge, as measured")
        XCTAssertLessThanOrEqual((lines.map(\.frame.maxY).max() ?? 0) + pages[index].topSpacing, small.height + 0.75, "the page's last line is inside its column")
    }

    /// A page that opens with two floats in a row, stacked on one side or one on each side, as a
    /// floated figure followed by a drop cap does. The paragraph after them was once drawn with
    /// its first line above the page and every other line on one row.
    func testFloatsInARowOpeningAPageKeepTheProseAfterThemInRows() throws {
        let small = CGSize(width: 180, height: 240)
        for (name, css) in [("stacked on the left", ".x, .y { float:left; width:60px; height:75px }"),
                            ("left and right", ".x { float:left; width:50px; height:75px } .y { float:right; width:50px; height:75px }")] {
            let section = try build("<p class='lead'>Lead.</p><figure class='x'>Float one.</figure><figure class='y'>Float two.</figure><p>After the floats. \(H.prose)</p>",
                                    css: ".lead { margin-bottom:216px } " + css)
            let (paginator, pages) = H.pages(section, size: small, name)
            XCTAssertGreaterThan(pages.count, 1, name)
            XCTAssertEqual(pages[1].range.location, H.range("Float one.", in: section).location, "the floats open the second page: \(name)")
            let view = H.pageView(paginator, page: pages[1])
            let lines = shownLines(view)
            XCTAssertEqual(lines.filter { $0.frame.minY < -0.75 }.count, 0, "lines above the page's top edge: \(name)")
            // Each line's own ink, without the break or blank that ends it.
            let inks = lines.map { line in view.segmentFrames(for: NSRange(location: line.range.location, length: max(1, line.range.length - 1))).reduce(CGRect.null) { $0.union($1) } }
            var overlapping = 0
            for (index, ink) in inks.enumerated() {
                for other in inks.dropFirst(index + 1) where H.overlaps([ink], [other]) { overlapping += 1 }
            }
            XCTAssertEqual(overlapping, 0, "pairs of lines drawn over each other, of \(lines.count) lines: \(name)")
        }
    }

    /// The fragments TextKit starts above the top of `view`'s text. It lays the lines of such a
    /// fragment one over another, so there must be none.
    private func fragmentsAboveTheTop(_ view: ReaderTextView) -> Int {
        var count = 0
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
            if fragment.layoutFragmentFrame.origin.y < 0 { count += 1 }
            return true
        }
        return count
    }

    /// Pairs of the lines `view` shows whose ink is drawn over each other.
    private func overlappingLines(_ view: ReaderTextView) -> Int {
        let inks = shownLines(view).map { line in
            view.segmentFrames(for: NSRange(location: line.range.location, length: max(1, line.range.length - 1))).reduce(CGRect.null) { $0.union($1) }
        }
        var overlapping = 0
        for (index, ink) in inks.enumerated() {
            for other in inks.dropFirst(index + 1) where H.overlaps([ink], [other]) { overlapping += 1 }
        }
        return overlapping
    }

    /// The boxes that can open a page, each followed by prose.
    private let pageOpeners: [(name: String, body: String, css: String)] = [
        ("one float", "<figure class='x'>Float one.</figure><p>After the boxes. \(BoxLayoutHarness.prose)</p>", ".x { float:left; width:60px; height:75px }"),
        ("two floats stacked on the left", "<figure class='x'>Float one.</figure><figure class='x'>Float two.</figure><p>After the boxes. \(BoxLayoutHarness.prose)</p>",
         ".x { float:left; width:60px; height:75px }"),
        ("a float on each side", "<figure class='x'>Float one.</figure><figure class='y'>Float two.</figure><p>After the boxes. \(BoxLayoutHarness.prose)</p>",
         ".x { float:left; width:50px; height:75px } .y { float:right; width:50px; height:75px }"),
        ("a float and a drop cap", "<figure class='x'>Float one.</figure><p><span class='cap'>A</span>fter the boxes. \(BoxLayoutHarness.prose)</p>",
         ".x { float:right; width:60px; height:75px } .cap { float:left; font-size:2.6em }"),
        ("a float of two paragraphs", "<figure class='x'><p>Top.</p><p>End.</p></figure><p>After the boxes. \(BoxLayoutHarness.prose)</p>",
         ".x { float:left; width:70px; height:85px }"),
        ("an absolute box", "<aside class='x'>Boxed.</aside><p>After the boxes. \(BoxLayoutHarness.prose)</p>", ".x { position:absolute; right:0; width:70px; height:85px }"),
        ("a float as wide as the column", "<figure class='x'>Float one.</figure><p>After the boxes. \(BoxLayoutHarness.prose)</p>", ".x { float:left; width:100%; height:80px }"),
        ("a sized inline-block as wide as the column", "<p>Before <span class='x'>Boxed words.</span> After the boxes. \(BoxLayoutHarness.prose)</p>",
         ".x { display:inline-block; width:500px; height:80px }")]

    /// A page that opens with boxes is the section's own layout from the boxes down: no line
    /// over another, each line broken where the whole section breaks it and as far below the
    /// page's first. A box takes back its lines' height with a negative margin, which TextKit
    /// adds to that height only to within rounding, a few 1e-14 either way with the text size
    /// and how far down the section the box is. Where the sum fell short the paragraph after
    /// the boxes started above the page's top and had all its lines on one row, so the boxes
    /// are tried at many heights and sizes.
    func testAPageOpeningWithBoxesIsLaidOutAsTheSectionIsWhereverTheBoxesStand() throws {
        let small = CGSize(width: 180, height: 240)
        for (name, body, css) in pageOpeners {
            var checked = 0
            for fontSize: CGFloat in [12, 14.5, 16, 19.3] {
                // A margin under the first paragraph moves the boxes down past the foot of the first page.
                for margin in stride(from: 172.0, through: 215.0, by: 6.1) {
                    let label = "\(name), text size \(fontSize), lead margin \(margin)"
                    let section = try build("<p class='lead'>Lead.</p>" + body, css: ".lead { margin-bottom:\(margin)px } " + css, fontSize: fontSize)
                    let (paginator, pages) = H.pages(section, size: small, label)
                    let after = H.range("fter the boxes.", in: section)
                    guard let plan = paginator.text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage,
                          let index = pages.firstIndex(where: { NSLocationInRange(after.location, $0.range) }), index > 0,
                          plan.geometry.regions.contains(where: { !$0.reserved && $0.range.location == pages[index].range.location }) else { continue }
                    checked += 1
                    let page = pages[index], view = H.pageView(paginator, page: page)
                    XCTAssertEqual(fragmentsAboveTheTop(view), 0, "fragments above the page's top: \(label)")
                    XCTAssertEqual(overlappingLines(view), 0, "pairs of lines drawn over each other: \(label)")
                    assertLinesFit(view, page: page, size: small, label)
                    let whole = H.view(section.string, size: small)
                    let expected = H.lines(in: whole, intersecting: page.range), lines = H.lines(in: view, intersecting: view.shownCharacters)
                    XCTAssertEqual(lines.map { NSRange(location: $0.range.location + page.range.location, length: $0.range.length) }, expected.map(\.range),
                                   "the section's line breaks: \(label)")
                    let first = try XCTUnwrap(lines.first, label), top = try XCTUnwrap(expected.first, label)
                    for (line, other) in zip(lines, expected) {
                        XCTAssertEqual(line.frame.minX, other.frame.minX, accuracy: 0.5, "\(label) \(other.range)")
                        XCTAssertEqual(line.frame.minY - first.frame.minY, other.frame.minY - top.frame.minY, accuracy: 0.5, "\(label) \(other.range)")
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(checked, 12, "the fixture opens pages with \(name)")
        }
    }

    /// The same at the start of a section, where a box that falls short of its lines' height
    /// puts the paragraph after it above the top of the whole text: in the paginator's own
    /// layout and in continuous scroll.
    func testASectionOpeningWithBoxesKeepsTheProseAfterThemInRows() throws {
        for (name, body, css) in pageOpeners {
            for fontSize in stride(from: CGFloat(11), through: 31, by: 1.3) {
                let label = "\(name), text size \(fontSize)"
                let section = try build(body, css: css, fontSize: fontSize)
                let size = CGSize(width: 320, height: 2_000)
                let whole = H.view(section.string, size: size, pageColumn: false)
                XCTAssertEqual(fragmentsAboveTheTop(whole), 0, "fragments above the text's top: \(label)")
                XCTAssertEqual(overlappingLines(whole), 0, "pairs of lines drawn over each other: \(label)")
                let (paginator, pages) = H.pages(section, size: size, label)
                let first = H.pageView(paginator, page: pages[0])
                XCTAssertEqual(fragmentsAboveTheTop(first), 0, "fragments above the first page's top: \(label)")
                XCTAssertEqual(overlappingLines(first), 0, "pairs of lines drawn over each other on the first page: \(label)")
            }
        }
    }

    /// Boxes that open a page can all stand below the point its text flows from. Here an
    /// absolute box with a top inset is the highest thing on the page: it pushes the float before
    /// it down past itself, and the prose after it too. The page's top is the absolute box's,
    /// above which nothing can be laid out, so the float's lines, the absolute box's and the
    /// prose's are each placed from that top: where the section has them, in rows.
    func testBoxesThatAllStandBelowWhereAPagesTextStartsAreLaidOutAsTheSectionHasThem() throws {
        let small = CGSize(width: 180, height: 240)
        let section = try build("<p class='lead'>Lead.</p><figure class='x'>Float one.</figure><aside class='a'>Absolute words.</aside><p>After the boxes. \(H.prose)</p>",
                                css: ".lead { break-after:page } .x { float:left; width:60px; height:75px } .a { position:absolute; left:0; top:1.7em; width:100% }")
        let (paginator, pages) = H.pages(section, size: small)
        let plan = try XCTUnwrap(paginator.text.attribute(.readerBoxPage, at: 0, effectiveRange: nil) as? ReaderBoxPage)
        let float = H.range("Float one.", in: section), absolute = H.range("Absolute words.", in: section), after = H.range("After the boxes.", in: section)
        let page = try XCTUnwrap(pages.dropFirst().first)
        XCTAssertEqual(page.range.location, float.location, "the forced break opens the page with the float")
        XCTAssertTrue(NSLocationInRange(after.location, page.range))
        // The float starts where the lead ended, and stands below the absolute box that follows it.
        let start = try XCTUnwrap(plan.geometry.paragraph(at: float.location)).flowStart
        let top = try XCTUnwrap(plan.geometry.regions.first { $0.range.location == absolute.location }).frame.minY
        XCTAssertGreaterThan(top, start + 2, "the highest box on the page is below where the page's text flows from")
        XCTAssertGreaterThan(try XCTUnwrap(plan.geometry.regions.first { $0.range.location == float.location }).frame.minY, top + 10)
        XCTAssertEqual(page.layoutTop, top, accuracy: 0.5, "the page starts at the absolute box")

        let view = H.pageView(paginator, page: page)
        XCTAssertEqual(fragmentsAboveTheTop(view), 0, "fragments above the page's top")
        XCTAssertEqual(overlappingLines(view), 0, "pairs of lines drawn over each other")
        assertLinesFit(view, page: page, size: small, "the page of boxes")
        let whole = H.view(section.string, size: small)
        let expected = H.lines(in: whole, intersecting: page.range), lines = H.lines(in: view, intersecting: view.shownCharacters)
        XCTAssertEqual(lines.map { NSRange(location: $0.range.location + page.range.location, length: $0.range.length) }, expected.map(\.range), "the section's line breaks")
        for (line, other) in zip(lines, expected) {
            // The boxes' own lines to half a point. The prose is pushed down to a box's bottom edge,
            // where rounding can take it a point further (https://github.com/vocaro/EPUBLib/issues/147).
            let accuracy: CGFloat = other.range.location < after.location ? 0.5 : 1.5
            XCTAssertEqual(line.frame.minX, other.frame.minX, accuracy: 0.5, "\(other.range)")
            XCTAssertEqual(line.frame.minY, other.frame.minY - page.layoutTop, accuracy: accuracy, "\(other.range)")
        }
        XCTAssertEqual(H.frame("Absolute words.", in: section, view: whole).minY, top, accuracy: 0.5)
        let shown = view.segmentFrames(for: NSRange(location: absolute.location - page.range.location, length: absolute.length)).reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(shown.minY, 0, accuracy: 0.5, "the absolute box is at the page's top")
    }

    /// TextKit starts each fragment where the one before it ends, and lays the lines of a
    /// fragment that starts above the top of its container one over another, however little
    /// above. A fragment whose margins take back more than its height would end there, so its
    /// frame ends at the top instead; one that ends inside the container, above where it
    /// starts, is left as it is (the last paragraph of a box of several does).
    func testAFragmentWhoseMarginsTakeBackMoreThanItsHeightEndsAtItsContainersTop() throws {
        let prose = Array(repeating: "Ordinary prose wraps beside the box and returns to the full column below it.", count: 3).joined(separator: " ")
        let paragraphs = ["Box words.", prose, "Last paragraph of words that wraps to a second line at least."]
        let text = NSAttributedString(string: paragraphs.joined(separator: "\n"), attributes: [.font: PlatformFont.systemFont(ofSize: 16)])
        let starts = paragraphs.indices.map { index in paragraphs[..<index].reduce(0) { $0 + $1.utf16.count + 1 } }
        func layout(_ margins: [Int: (top: CGFloat, bottom: CGFloat)]) -> [(frame: CGRect, lines: [CGFloat])] {
            let storage = NSTextContentStorage(), manager = NSTextLayoutManager()
            storage.addTextLayoutManager(manager)
            let container = ReaderTextContainer(size: CGSize(width: 180, height: 0))
            container.lineFragmentPadding = 0
            // A box elsewhere: the container is no plain rectangle, as on every page with a box.
            container.boxRegions = [.init(range: NSRange(location: 0, length: 0), frame: CGRect(x: 0, y: 50_000, width: 60, height: 60), side: .left)]
            manager.textContainer = container
            let delegate = BoxMarginFragments(margins: margins, storage: storage)
            manager.delegate = delegate
            storage.attributedString = text
            var fragments: [(CGRect, [CGFloat])] = []
            manager.enumerateTextLayoutFragments(from: storage.documentRange.location, options: [.ensuresLayout]) { fragment in
                fragments.append((fragment.layoutFragmentFrame, fragment.textLineFragments.filter { $0.characterRange.length > 0 }.map(\.typographicBounds.minY)))
                return true
            }
            return withExtendedLifetime(delegate) { fragments }
        }
        let natural = layout([:])
        XCTAssertEqual(natural.count, 3)
        let heights = natural.map(\.frame.height), rows = natural[1].lines
        XCTAssertGreaterThanOrEqual(rows.count, 4, "the second paragraph wraps")
        XCTAssertEqual(rows, rows.sorted()); XCTAssertEqual(Set(rows).count, rows.count, "its lines are in rows")
        for top: CGFloat in [0, 30] {
            for excess: CGFloat in [0, heights[0].ulp, 2.2e-14, 1e-9, 0.5, 10] {
                let label = "a top margin of \(top) and \(excess) more than its height taken back"
                let fragments = layout([starts[0]: (top, -(top + heights[0] + excess))])
                XCTAssertEqual(fragments[0].lines.first ?? -1, top, accuracy: 1e-6, label)
                XCTAssertGreaterThanOrEqual(fragments[1].frame.origin.y, 0, "the next fragment starts in the container: \(label)")
                XCTAssertEqual(fragments[1].frame.origin.y, 0, accuracy: 1e-9, label)
                XCTAssertEqual(fragments[1].lines.count, rows.count, label)
                for (line, row) in zip(fragments[1].lines, rows) { XCTAssertEqual(line, row, accuracy: 1e-6, "its lines keep their rows: \(label)") }
                XCTAssertEqual(fragments[2].frame.origin.y, heights[1], accuracy: 1e-6, label)
            }
        }
        // The second fragment takes back the first's height too, and more: it ends at the top.
        let returned = layout([starts[1]: (0, -(heights[1] + heights[0] + 5))])
        XCTAssertEqual(returned[1].frame.origin.y, heights[0], accuracy: 1e-6)
        XCTAssertEqual(returned[2].frame.origin.y, 0, "the fragment after it starts at the container's top")
        XCTAssertEqual(returned[2].lines.count, natural[2].lines.count)
        for (line, row) in zip(returned[2].lines, natural[2].lines) { XCTAssertEqual(line, row, accuracy: 1e-6) }
        // Half of the first's height: it ends inside the container, and stays there.
        let inside = layout([starts[1]: (0, -(heights[1] + heights[0] / 2))])
        XCTAssertEqual(inside[2].frame.origin.y, heights[0] / 2, accuracy: 1e-6)
        XCTAssertEqual(inside[2].lines.count, natural[2].lines.count)
        for (line, row) in zip(inside[2].lines, natural[2].lines) { XCTAssertEqual(line, row, accuracy: 1e-6) }
    }

    /// A table row starts below every float. Its first row begins exactly at the float's bottom
    /// edge and is placed beside the float's column as though the float went on: shifted right
    /// by the float's width, out of step with the rows after it and past the column's edge.
    func testATableDirectlyBelowAFloatSpansTheColumn() throws {
        #if os(macOS)
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/147")
        #endif
        let small = CGSize(width: 180, height: 240)
        var shifted: [String] = []
        for margin in [0, 8, 16, 24, 32, 40] {
            let section = try build("<p class='lead'>Lead.</p><figure>Float box.</figure><table><tr><td>Cell one</td><td>Cell two</td></tr>"
                                    + "<tr><td>Cell three</td><td>Cell four</td></tr></table><p>After the table.</p>",
                                    css: ".lead { margin-bottom:\(margin)px } figure { float:left; width:60px; height:75px }")
            let view = H.view(section.string, size: small)
            let region = try XCTUnwrap(view.readerContainer.boxRegions.first { !$0.reserved })
            var rows: [CGRect] = []
            section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, range, _ in
                if value is TableRowAttachment, let frame = view.segmentFrames(for: range).first { rows.append(frame) }
            }
            XCTAssertEqual(rows.count, 2, "two table rows")
            for (index, row) in rows.enumerated() {
                XCTAssertGreaterThanOrEqual(row.minY, region.frame.maxY - 0.5, "the table is below the float")
                if row.minX > 1 || row.maxX > small.width + 0.5 { shifted.append("lead margin \(margin), row \(index): x \(row.minX) to \(row.maxX)") }
            }
        }
        XCTAssertEqual(shifted, [], "every row starts at the column's left edge and ends inside the 180-point column")
    }

    // MARK: Hit testing

    func testPointsInsideBoxesAndBesideThemHitTheirOwnCharacters() throws {
        let prefix = Array(repeating: "Earlier ordinary text around a callout.", count: 9).joined(separator: " ")
        let section = try build("<p>\(prefix)</p><aside>Later source callout.</aside><figure>Float caption.</figure><p>Following prose words. \(H.prose)</p>",
                                css: "aside { position:absolute; left:220px; top:24px; width:160px } figure { float:right; width:120px; height:60px }")
        let view = H.view(section.string, size: size)
        let callout = try XCTUnwrap(H.region("Later source callout.", in: section, view: view))
        XCTAssertLessThan(callout.frame.minY, H.frame("Earlier ordinary text", in: section, view: view).maxY + 30, "the callout is drawn before its source position")
        for phrase in ["Later source callout.", "Float caption.", "Following prose words.", "Earlier ordinary text"] {
            let range = H.range(phrase, in: section)
            let word = NSRange(location: range.location, length: (phrase as NSString).range(of: " ").location)
            let frame = try XCTUnwrap(view.segmentFrames(for: word).first, phrase)
            let hit = view.characterOffset(at: CGPoint(x: view.containerOrigin.x + frame.midX, y: view.containerOrigin.y + frame.midY))
            XCTAssertTrue(hit >= word.location && hit <= word.upperBound, "\(phrase): \(hit) is not in \(word)")
            XCTAssertEqual(view.line(containing: range.location).map { NSLocationInRange(range.location, $0.range) }, true, phrase)
        }
        XCTAssertEqual(view.visibleText, section.string.string)
    }

    // MARK: Geometry lookups

    func testGroupAndParagraphLookupsAtTheirEdges() {
        let geometry = ReaderBoxGeometry()
        geometry.formGroups()
        XCTAssertTrue(geometry.groups.isEmpty)
        XCTAssertNil(geometry.group(containing: 0)); XCTAssertNil(geometry.paragraph(at: 0))
        XCTAssertTrue(geometry.bounds(of: NSRange(location: 0, length: 10)).isNull)
        for index in 0..<6 {
            let y = CGFloat(index * 20)
            geometry.paragraphs.append(.init(range: NSRange(location: index * 10, length: 10), flowStart: y, flowEnd: y + 20,
                                             lines: [(NSRange(location: index * 10, length: 10), CGRect(x: 0, y: y, width: 80, height: 20))]))
        }
        // Only a reserved prefix: nothing is indivisible.
        geometry.regions = [.init(range: NSRange(location: 0, length: 4), frame: CGRect(x: 0, y: 0, width: 30, height: 20), side: .none, reserved: true)]
        geometry.formGroups()
        XCTAssertTrue(geometry.groups.isEmpty)
        // Two boxes whose rows do not meet: two groups, each with the lines sharing its rows.
        geometry.regions = [.init(range: NSRange(location: 10, length: 10), frame: CGRect(x: 100, y: 20, width: 50, height: 30), side: .left),
                            .init(range: NSRange(location: 40, length: 10), frame: CGRect(x: 100, y: 80, width: 50, height: 10), side: .right)]
        geometry.formGroups()
        XCTAssertEqual(geometry.groups, [NSRange(location: 10, length: 20), NSRange(location: 40, length: 10)])
        XCTAssertNil(geometry.group(containing: 9)); XCTAssertEqual(geometry.group(containing: 10), geometry.groups[0])
        XCTAssertEqual(geometry.group(containing: 29), geometry.groups[0]); XCTAssertNil(geometry.group(containing: 30))
        XCTAssertNil(geometry.group(containing: 39)); XCTAssertEqual(geometry.group(containing: 49), geometry.groups[1])
        XCTAssertNil(geometry.group(containing: 50)); XCTAssertNil(geometry.group(containing: 1_000))
        XCTAssertEqual(geometry.bounds(of: geometry.groups[0]), CGRect(x: 0, y: 20, width: 150, height: 40))
        XCTAssertEqual(geometry.bounds(of: NSRange(location: 0, length: 5)), CGRect(x: 0, y: 0, width: 80, height: 20), "any range: its lines")
        XCTAssertEqual(geometry.paragraph(at: 0)?.range, NSRange(location: 0, length: 10))
        XCTAssertEqual(geometry.paragraph(at: 59)?.range, NSRange(location: 50, length: 10))
        XCTAssertNil(geometry.paragraph(at: 60))
    }

    // MARK: Hostile input

    func testExtremeLengthsOnBoxesNeverCrashLeaveTheColumnOrLoseCharacters() throws {
        let floats = ["width:1e309px", "width:calc(1px / 0)", "width:99999999px; height:99999999px", "margin-left:1e30px", "width:calc(100% - 1e12px)",
                      "width:1e-320px", "padding:0 1e9px", "width:0", "height:1e308px", "margin:-1e9px", "border:1e9px solid black",
                      "width:calc(1e308px * 1e308)", "min-width:1e9px; max-width:0", "width:calc(0px / 0)", "width:-0px", "width:0.0001px; height:0.0001px"]
        for declarations in floats.flatMap({ ["float:left; \($0)", "position:absolute; left:10px; top:10px; \($0)", "display:inline-block; \($0)"] }) {
            let section = try build("<p>Lead words.</p><div class='x'>Boxed words here.</div><p>\(H.prose)</p>", css: ".x { \(declarations) }")
            let resolved = ReaderBoxLayout.resolve(section.string, viewport: size)
            XCTAssertEqual(resolved.text.string, section.string.string, declarations)
            for region in resolved.geometry?.regions ?? [] {
                XCTAssertTrue([region.frame.minX, region.frame.minY, region.frame.width, region.frame.height].allSatisfy(\.isFinite), declarations)
                XCTAssertGreaterThanOrEqual(region.frame.minX, -0.5, declarations); XCTAssertLessThanOrEqual(region.frame.maxX, size.width + 0.5, declarations)
            }
            H.pages(section, size: size, declarations)
        }
        let insets = ["left:1e309px; top:1e309px", "inset:-1e308px", "left:calc(1px / 0); top:calc(0px / 0)", "top:99999999px", "bottom:1e30px; right:1e30px",
                      "inset:1e9%", "top:-99999999vh; left:5px"]
        for declarations in insets {
            let section = try build("<p>Lead words.</p><div class='x'>Boxed words here.</div><p>\(H.prose)</p>", css: ".x { position:absolute; width:100px; \(declarations) }")
            XCTAssertEqual(ReaderBoxLayout.resolve(section.string, viewport: size).text.string, section.string.string, declarations)
            H.pages(section, size: size, declarations)
        }
        let aligned = ["height:1e309px", "min-height:calc(1px / 0)", "gap:1e9px", "height:99999999vh", "min-height:1e308px; max-height:1e308px",
                       "height:calc(100% * 1e300)", "padding:1e9px 0; height:100vh; box-sizing:border-box"]
        for declarations in aligned {
            let section = try build("<div class='x'><p class='g'>Item one.</p><p>Item two.</p></div><p>After.</p>",
                                    css: ".x { display:flex; flex-direction:column; justify-content:space-around; \(declarations) } .g { flex-grow:1e309; flex:1e308 }")
            XCTAssertEqual(ReaderBoxLayout.resolve(section.string, viewport: size).text.string, section.string.string, declarations)
            H.pages(section, size: size, declarations)
        }
    }

    func testDegenerateViewportsLeaveTheTextUntouched() throws {
        let section = try build("<figure>Alpha box.</figure><p class='m'>Short prose words.</p><div class='box'><p>Centred words.</p></div>",
                                css: "figure { float:left; width:100px } .m { margin:5% 10%; text-indent:5% } .box { display:flex; flex-direction:column; justify-content:center; height:50vh }")
        for viewport in [CGSize.zero, CGSize(width: 0, height: 600), CGSize(width: 360, height: 0), CGSize(width: -100, height: 600), CGSize(width: 360, height: -1),
                         CGSize(width: CGFloat.nan, height: 600), CGSize(width: 360, height: CGFloat.nan), CGSize(width: CGFloat.infinity, height: 600),
                         CGSize(width: 360, height: CGFloat.infinity), CGSize(width: 1, height: 1), CGSize(width: 0.001, height: 0.001)] {
            let resolved = ReaderBoxLayout.resolve(section.string, viewport: viewport)
            XCTAssertEqual(resolved.text.string, section.string.string, "\(viewport)")
            if !(viewport.width > 0 && viewport.height > 0) { XCTAssertNil(resolved.geometry, "no plan without a column: \(viewport)") }
            for text in [ReaderParagraphSizingLayout.applying(to: section.string, viewport: viewport), ReaderAlignmentLayout.applying(to: section.string, viewport: viewport),
                         ReaderFlowBoxLayout.applying(to: section.string, viewport: viewport), resolved.text] {
                XCTAssertEqual(text.string, section.string.string, "\(viewport)")
                text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    guard let style = value as? NSParagraphStyle else { return }
                    XCTAssertTrue([style.headIndent, style.firstLineHeadIndent, style.tailIndent, style.paragraphSpacing, style.paragraphSpacingBefore]
                        .allSatisfy(\.isFinite), "\(viewport)")
                }
            }
        }
        // A column too small for a word still pages every character.
        H.pages(section, size: CGSize(width: 40, height: 40))
    }

    func testDeepNestingOfPositionedAndPercentageSizedBlocksResolves() throws {
        let depth = 150
        let section = try build(String(repeating: "<div class='n'>", count: depth) + "<figure>Alpha box.</figure><p>Deep words. \(H.prose)</p>"
                                + String(repeating: "</div>", count: depth), css: ".n { position:relative; margin:0 1%; padding:1% 0; left:1px } figure { float:left; width:30% }")
        let view = H.view(section.string, size: size)
        XCTAssertEqual(view.visibleText, section.string.string)
        XCTAssertTrue(H.lines(in: view).allSatisfy { $0.frame.minX >= -0.5 && $0.frame.maxX <= size.width + 0.5 })
        H.pages(section, size: size)
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testHundredsOfFloatsBetweenParagraphsPageCompletely() throws {
        let section = try build((0..<300).map { "<figure>F\($0).</figure><p>Paragraph \($0) of ordinary prose that is long enough to wrap beside its little box.</p>" }.joined(),
                                css: "figure { float:left; width:60px; height:30px }")
        let pages = H.pages(section, size: size).pages
        XCTAssertGreaterThan(pages.count, 5)
        BuilderHarness.assertMapRoundTrips(section)
    }

    /// Books are untrusted, and a contents page or a gallery made of floats has hundreds of them
    /// with nothing between. Four times as many floats must not cost sixty-four times as long:
    /// while each collision rescanned the earlier boxes from the first, 1,000 took 12 seconds
    /// and 3,000 over 4 minutes on the machine these tests were written on.
    func testResolvingConsecutiveFloatsDoesNotGrowCubically() throws {
        func seconds(_ count: Int) throws -> Double {
            let section = try build((0..<count).map { "<figure>F\($0).</figure>" }.joined() + "<p>End.</p>", css: "figure { float:left; width:60px }")
            return (0..<2).map { _ in
                let start = threadSeconds()
                XCTAssertEqual(ReaderBoxLayout.resolve(section.string, viewport: size).text.string, section.string.string)
                return threadSeconds() - start
            }.min() ?? 0
        }
        let small = try seconds(150), large = try seconds(600)
        // Linear work is 4 times as long, quadratic 16, cubic 64.
        XCTAssertLessThan(large, 30 * max(small, 0.001), "150 floats took \(small) s of CPU and 600 took \(large) s")
    }

    /// CPU seconds of this thread: unlike a wall clock, unaffected by other work on the machine.
    private func threadSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    /// Floats that drop past positioned boxes, which sit wherever their insets say and so in no
    /// particular order in the list. The asides are written from the largest `top` to the
    /// smallest. An inset is held to 1,000 points (`StyleLimits.offset`), so all but the last
    /// forty are given that same place and stack from there down in the order they are
    /// written; the last forty are the column above them, written bottom first. Every float
    /// then drops past the whole stack and the floats before it. Rescanning from the first box
    /// after every drop took 0.4 s of CPU for 150 of each and over 20 s for 600, and would have
    /// in any order: each drop cost one scan as far as the next collision, wherever in the list
    /// that was.
    func testResolvingFloatsBelowBoxesWrittenBottomFirstDoesNotGrowCubically() throws {
        func seconds(_ count: Int) throws -> Double {
            let section = try build((0..<count).map { "<aside style='top:\((count - 1 - $0) * 25)px'>A\($0).</aside>" }.joined()
                                    + (0..<count).map { "<figure>F\($0).</figure>" }.joined() + "<p>End.</p>",
                                    css: "aside { position:absolute; left:0; width:60px; height:25px } figure { float:left; width:60px }")
            return (0..<2).map { _ in
                let start = threadSeconds()
                XCTAssertEqual(ReaderBoxLayout.resolve(section.string, viewport: size).text.string, section.string.string)
                return threadSeconds() - start
            }.min() ?? 0
        }
        let small = try seconds(150), large = try seconds(600)
        // Linear work is 4 times as long, quadratic 16, cubic 64.
        XCTAssertLessThan(large, 30 * small, "150 of each took \(small) s of CPU and 600 took \(large) s")
    }

    // MARK: Collisions

    /// Where a box comes to rest is defined by the scan the layout began with: drop below the
    /// first obstacle in the list that the box touches, look again from the start of the list,
    /// and stop when it touches none. One pass over the sorted list has to leave every box in
    /// that same place, whatever the obstacles' order, overlaps and shared edges, at whole
    /// coordinates and at ones whose sums round.
    func testABoxSettlesWhereDroppingBelowEachCollisionInTurnLeavesIt() {
        func rescanned(_ frame: CGRect, below obstacles: [CGRect]) -> (frame: CGRect, drops: Int) {
            var frame = frame, drops = 0
            while let collision = obstacles.first(where: { $0.intersects(frame) }) { frame.origin.y = collision.maxY; drops += 1 }
            return (frame, drops)
        }
        var random = SectionContentRandom(state: 0x155_C011_1DE5)
        var moved = 0, chains = 0, failures: [String] = []
        for round in 0..<4_000 {
            // Whole units make edges that meet exactly; the line height of 16-point text makes sums that round.
            let unit: CGFloat = round % 2 == 0 ? 5 : 22.29001636661211 / 2
            var obstacles: [CGRect] = []
            if round % 4 < 2 {
                // Scattered boxes: overlapping, nested, abutting and apart.
                for _ in 0..<random.next(40) {
                    obstacles.append(CGRect(x: CGFloat(random.next(8)) * 50, y: CGFloat(random.next(30)) * unit,
                                            width: CGFloat(1 + random.next(4)) * 50, height: CGFloat(1 + random.next(6)) * unit))
                }
            } else {
                // Columns of boxes each directly below the one before, as a run of floats lands, with the odd gap.
                for column in 0..<(1 + random.next(3)) {
                    var top = CGFloat(random.next(3)) * unit
                    for _ in 0..<random.next(25) {
                        let height = CGFloat(1 + random.next(4)) * unit
                        obstacles.append(CGRect(x: CGFloat(column) * 130, y: top, width: CGFloat(60 + random.next(3) * 60), height: height))
                        top += height + (random.chance(6) ? CGFloat(1 + random.next(4)) * unit : 0)
                    }
                }
            }
            // Source order is top first for floats in flow and any order at all for positioned boxes.
            if round % 3 != 0 {
                for index in obstacles.indices.dropFirst().reversed() { obstacles.swapAt(index, random.next(index + 1)) }
            }
            let frame = CGRect(x: CGFloat(random.next(8)) * 50, y: CGFloat(random.next(12)) * unit,
                               width: CGFloat(1 + random.next(4)) * 50, height: CGFloat(1 + random.next(8)) * unit)
            let expected = rescanned(frame, below: obstacles)
            let settled = ReaderBoxLayout.settled(frame, below: obstacles)
            if settled != expected.frame {
                failures.append("round \(round): \(frame) below \(obstacles) rests at \(settled.minY), not \(expected.frame.minY)")
            }
            if expected.drops > 0 { moved += 1 }
            if expected.drops >= 5 { chains += 1 }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of 4,000 boxes rest somewhere else: \(failures.prefix(2).joined(separator: "; "))")
        XCTAssertGreaterThan(moved, 2_000, "most rounds move the box")
        XCTAssertGreaterThan(chains, 400, "and many take it past obstacle after obstacle")
        // Nothing to avoid, and nothing in the way.
        let alone = CGRect(x: 10, y: 30, width: 60, height: 20)
        XCTAssertEqual(ReaderBoxLayout.settled(alone, below: []), alone)
        XCTAssertEqual(ReaderBoxLayout.settled(alone, below: [CGRect(x: 70, y: 0, width: 60, height: 100), CGRect(x: 10, y: 50, width: 60, height: 20),
                                                              CGRect(x: 10, y: 0, width: 60, height: 30)]), alone, "boxes that only share an edge with it")
    }

    /// One box at the top of a column of obstacles, listed in a shuffled order, drops past every
    /// one of them. Looking again from the start of the list after each drop is half the square
    /// of the column's length in comparisons for that one box, in whatever order the list is;
    /// sorting it is not. Sixteen times the column is some twenty times the sorting and 256
    /// times the rescanning.
    func testSettlingABoxBelowAColumnOfObstaclesInAnyOrderIsNotQuadratic() {
        func seconds(_ count: Int) -> Double {
            var random = SectionContentRandom(state: 0x155_0C01)
            var obstacles = (0..<count).map { CGRect(x: 0, y: CGFloat($0) * 20, width: 60, height: 20) }
            for index in obstacles.indices.dropFirst().reversed() { obstacles.swapAt(index, random.next(index + 1)) }
            return (0..<3).map { _ in
                let start = threadSeconds()
                let settled = ReaderBoxLayout.settled(CGRect(x: 0, y: 0, width: 60, height: 20), below: obstacles)
                let elapsed = threadSeconds() - start
                XCTAssertEqual(settled, CGRect(x: 0, y: CGFloat(count) * 20, width: 60, height: 20), "below the whole column of \(count)")
                return elapsed
            }.min() ?? 0
        }
        let small = seconds(1_000), large = seconds(16_000)
        XCTAssertLessThan(large, 64 * small, "1,000 obstacles took \(small) s of CPU and 16,000 took \(large) s")
    }

    /// End to end: every float in a run that cannot sit side by side comes to rest clear of all
    /// the boxes placed before it, on either side and at any height.
    func testFloatsInARunOfMixedSidesAndHeightsNeverOverlap() throws {
        let count = 14
        let section = try build((0..<count).map { "<figure class='\($0 % 3 == 0 ? "r" : "l")' style='height:\(20 + $0 * 7 % 25)px'>F\($0).</figure>" }.joined()
                                + "<p>End. \(H.prose)</p>", css: "figure { width:230px } .l { float:left } .r { float:right }")
        let plan = try XCTUnwrap(ReaderBoxLayout.resolve(section.string, viewport: size).geometry)
        let floats = plan.regions.filter { $0.side != .none }
        XCTAssertEqual(floats.count, count, "the run fits a page, so every float keeps its box")
        for (index, float) in floats.enumerated() {
            XCTAssertGreaterThanOrEqual(float.frame.minY, 0)
            for earlier in floats[..<index] {
                XCTAssertFalse(float.frame.intersects(earlier.frame), "float \(index) at \(float.frame) overlaps an earlier one at \(earlier.frame)")
            }
        }
        XCTAssertGreaterThan(Set(floats.map(\.frame.minY)).count, count / 2, "the floats were pushed down past one another")
    }
}
