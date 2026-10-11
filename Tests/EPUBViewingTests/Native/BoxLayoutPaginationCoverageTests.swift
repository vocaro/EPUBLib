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
    /// floated figure followed by a drop cap does. The paragraph after them is drawn with its
    /// first line above the page and every other line on one row.
    func testFloatsInARowOpeningAPageKeepTheProseAfterThemInRows() throws {
        #if os(macOS)
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/146")
        #endif
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
    /// on the machine these tests were written on, 1,000 took 12 seconds and 3,000 over 4 minutes.
    func testResolvingConsecutiveFloatsDoesNotGrowCubically() throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/155", options: .nonStrict())
        func seconds(_ count: Int) throws -> TimeInterval {
            let section = try build((0..<count).map { "<figure>F\($0).</figure>" }.joined() + "<p>End.</p>", css: "figure { float:left; width:60px }")
            return (0..<2).map { _ in
                let start = Date()
                XCTAssertEqual(ReaderBoxLayout.resolve(section.string, viewport: size).text.string, section.string.string)
                return Date().timeIntervalSince(start)
            }.min() ?? 0
        }
        let small = try seconds(150), large = try seconds(600)
        // Linear work is 4 times as long, quadratic 16, cubic 64.
        XCTAssertLessThan(large, 30 * max(small, 0.001), "150 floats took \(small) s and 600 took \(large) s")
    }
}
