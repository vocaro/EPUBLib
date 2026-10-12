import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Native geometry of the supported flex and grid subset, in points within
/// `AlignmentHarness.tolerance` unless a test states another.
@MainActor final class BoxAlignmentLayoutTests: XCTestCase {
    private typealias H = AlignmentHarness
    private let reset = "body { margin: 0 } p, div, h1, main, footer, section { margin: 0; padding: 0; text-indent: 0 } "
    private let size = CGSize(width: 400, height: 600)

    private func tops(_ phrases: [String], in section: SectionText, view: ReaderTextView) -> [CGFloat] {
        phrases.map { H.frame($0, in: section, view: view).minY }
    }

    // MARK: Main axis of a column

    func testColumnContainerCentresItsContentInADefiniteHeightInBothFlows() throws {
        let section = try H.build("<div class='box'><p>First centred line.</p><p>Second centred line.</p></div><p>After the box.</p>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: center; height: 400px }")
        XCTAssertFalse(section.report.flexGridSimplified)
        let view = H.scrolled(section, size: size)
        let first = H.frame("First centred line.", in: section, view: view)
        let second = H.frame("Second centred line.", in: section, view: view)
        H.assertEqual(first.minY, (400 - 2 * first.height) / 2)
        H.assertEqual(second.minY, first.maxY)
        H.assertEqual((first.minY + second.maxY) / 2, 200, "the content's middle is the box's")
        H.assertEqual(H.frame("After the box.", in: section, view: view).minY, 400, "the box keeps its whole height")
        // A page: the same geometry from the top of the page's text area.
        let paged = H.paged("First centred line.", in: section, size: size)
        XCTAssertEqual(paged.page, 0)
        H.assertEqual(paged.frame.minY, first.minY)
        H.assertEqual(H.paged("After the box.", in: section, size: size).frame.minY, 400)
    }

    func testJustifyContentDistributesFreeSpaceBetweenItems() throws {
        let body = "<div class='box'><p>Item one.</p><p>Item two.</p><p>Item three.</p></div><p>After the box.</p>"
        let phrases = ["Item one.", "Item two.", "Item three."]
        func tops(_ value: String) throws -> (items: [CGFloat], after: CGFloat, line: CGFloat) {
            let section = try H.build(body, css: reset + ".box { display: flex; flex-direction: column; justify-content: \(value); height: 400px }")
            let view = H.scrolled(section, size: size)
            return (self.tops(phrases, in: section, view: view), H.frame("After the box.", in: section, view: view).minY,
                    H.frame("Item one.", in: section, view: view).height)
        }
        let line = try tops("flex-start").line
        let free = 400 - 3 * line
        let expected: [(String, [CGFloat])] = [
            ("flex-start", [0, line, 2 * line]),
            ("normal", [0, line, 2 * line]),
            ("center", [free / 2, free / 2 + line, free / 2 + 2 * line]),
            ("flex-end", [free, free + line, free + 2 * line]),
            ("space-between", [0, line + free / 2, 2 * line + free]),
            ("space-around", [free / 6, line + free / 2, 2 * line + free * 5 / 6]),
            ("space-evenly", [free / 4, line + free / 2, 2 * line + free * 3 / 4]),
        ]
        for (value, positions) in expected {
            let result = try tops(value)
            for (top, position) in zip(result.items, positions) { H.assertEqual(top, position, value) }
            H.assertEqual(result.after, 400, "\(value): what follows starts below the box")
        }
    }

    func testAutoMarginsAndFlexGrowTakeFreeSpaceBeforeJustifyContent() throws {
        let pushed = try H.build("<div class='box'><p>Top item.</p><p class='low'>Bottom item.</p></div>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: center; height: 300px } .low { margin-top: auto }")
        var view = H.scrolled(pushed, size: size)
        H.assertEqual(H.frame("Top item.", in: pushed, view: view).minY, 0)
        H.assertEqual(H.frame("Bottom item.", in: pushed, view: view).maxY, 300)

        // The sticky-footer idiom: the main content grows, the footer rests at the bottom.
        let grown = try H.build("<div class='box'><main><p>Main content.</p></main><footer><p>Footer line.</p></footer></div>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: center; min-height: 300px } main { flex: 1 }")
        view = H.scrolled(grown, size: size)
        H.assertEqual(H.frame("Main content.", in: grown, view: view).minY, 0, "a grown item keeps its content at its top")
        H.assertEqual(H.frame("Footer line.", in: grown, view: view).maxY, 300)
    }

    func testRowGapSeparatesStackedItemsWithoutADefiniteHeight() throws {
        for css in [".box { display: flex; flex-direction: column; gap: 20px }", ".box { display: grid; row-gap: 20px }",
                    ".box { display: grid; grid-gap: 20px 5px }"] {
            let section = try H.build("<div class='box'><p>Gap one.</p><p>Gap two.</p><p>Gap three.</p></div><p>After the gaps.</p>",
                                      css: reset + css)
            let view = H.scrolled(section, size: size)
            let line = H.frame("Gap one.", in: section, view: view).height
            let positions = tops(["Gap one.", "Gap two.", "Gap three.", "After the gaps."], in: section, view: view)
            for (top, expected) in zip(positions, [0, line + 20, 2 * line + 40, 3 * line + 40]) { H.assertEqual(top, expected, css) }
        }
    }

    // MARK: Cross axis of a column

    func testAlignItemsShrinksItemsToTheirContentAndPlacesThemAcrossTheColumn() throws {
        let body = "<div class='box'><p>Short item.</p><p class='own'>Own alignment.</p></div>"
        func frames(_ css: String) throws -> (CGRect, CGRect) {
            let section = try H.build(body, css: reset + css)
            let view = H.scrolled(section, size: size)
            return (H.frame("Short item.", in: section, view: view), H.frame("Own alignment.", in: section, view: view))
        }
        var (item, own) = try frames(".box { display: flex; flex-direction: column; align-items: center }")
        H.assertEqual(item.midX, 200); H.assertEqual(own.midX, 200)
        (item, own) = try frames(".box { display: flex; flex-direction: column; align-items: flex-end } .own { align-self: center }")
        H.assertEqual(item.maxX, 400); H.assertEqual(own.midX, 200)
        (item, own) = try frames(".box { display: flex; flex-direction: column; align-items: center } .own { align-self: flex-start }")
        H.assertEqual(item.midX, 200); H.assertEqual(own.minX, 0)
        (item, own) = try frames(".box { display: flex; flex-direction: column } .own { margin-left: auto }")
        H.assertEqual(item.minX, 0, "the default stretches an item across the column"); H.assertEqual(own.maxX, 400)
        (item, own) = try frames(".box { display: flex; flex-direction: column } .own { margin: 0 auto }")
        H.assertEqual(own.midX, 200)
        // Right to left: the end is the left edge.
        (item, own) = try frames(".box { display: flex; flex-direction: column; align-items: flex-end; direction: rtl } .own { align-self: flex-start }")
        H.assertEqual(item.minX, 0); H.assertEqual(own.maxX, 400)
    }

    func testAlignedItemsHonourWidthAndMaxWidthAndKeepTheirOwnTextAlignment() throws {
        let long = "This sentence is long enough to wrap onto several lines inside a narrow centred column of text."
        let section = try H.build("<div class='box'><p class='half'>\(long)</p><div class='quote'><p>A short verse.</p><p class='by'>Signed</p></div></div>",
            css: reset + ".box { display: flex; flex-direction: column; align-items: center } .half { width: 50% } "
                + ".quote { max-width: 80% } .by { text-align: right }")
        let view = H.scrolled(section, size: size)
        let half = H.frame(long, in: section, view: view)
        XCTAssertGreaterThanOrEqual(half.minX, 100 - H.tolerance)
        XCTAssertLessThanOrEqual(half.maxX, 300 + H.tolerance)
        XCTAssertGreaterThan(half.height, 2 * H.frame("Signed", in: section, view: view).height, "it wraps in its half column")
        let verse = H.frame("A short verse.", in: section, view: view), by = H.frame("Signed", in: section, view: view)
        H.assertEqual(verse.midX, 200, "the item is as wide as its widest paragraph, centred")
        H.assertEqual(by.maxX, verse.maxX, "a right-aligned paragraph ends at the item's edge, not the column's")
        // Wider content than the cap: the item is 80% of the column, still centred.
        let capped = try H.build("<div class='box'><p class='quote'>\(long) \(long)</p></div>",
            css: reset + ".box { display: flex; flex-direction: column; align-items: center } .quote { max-width: 80% }")
        let frame = H.frame(long, in: capped, view: H.scrolled(capped, size: size))
        XCTAssertGreaterThanOrEqual(frame.minX, 40 - H.tolerance)
        XCTAssertLessThanOrEqual(frame.maxX, 360 + H.tolerance)
    }

    // MARK: A row's only item

    func testRowContainerPlacesItsOnlyItemAlongBothAxes() throws {
        let body = "<div class='row'><p>Only item.</p></div><p>After the row.</p>"
        func frames(_ declarations: String) throws -> (item: CGRect, after: CGRect) {
            let section = try H.build(body, css: reset + ".row { display: flex; height: 300px; \(declarations) }")
            XCTAssertFalse(section.report.flexGridSimplified)
            let view = H.scrolled(section, size: size)
            return (H.frame("Only item.", in: section, view: view), H.frame("After the row.", in: section, view: view))
        }
        var result = try frames("justify-content: center; align-items: center")
        H.assertEqual(result.item.midX, 200); H.assertEqual(result.item.midY, 150); H.assertEqual(result.after.minY, 300)
        result = try frames("justify-content: flex-end; align-items: flex-end")
        H.assertEqual(result.item.maxX, 400); H.assertEqual(result.item.maxY, 300)
        result = try frames("justify-content: space-around")
        H.assertEqual(result.item.midX, 200); H.assertEqual(result.item.minY, 0, "stretched: its content stays at the top")
        result = try frames("flex-direction: row-reverse")
        H.assertEqual(result.item.maxX, 400, "a reversed row starts at the right")
        // The 2009 syntax old Apple-targeted books use.
        let legacy = try H.build(body, css: reset + ".row { display: -webkit-box; -webkit-box-pack: center; -webkit-box-align: center; height: 300px }")
        let item = H.frame("Only item.", in: legacy, view: H.scrolled(legacy, size: size))
        H.assertEqual(item.midX, 200); H.assertEqual(item.midY, 150)
    }

    // MARK: Grid

    func testOneCellGridCentresWithPlaceItemsAndAlignContent() throws {
        let body = "<div class='grid'><p>Grid cell.</p></div><p>After the grid.</p>"
        for declarations in ["place-items: center", "place-content: center; justify-items: center",
                             "align-items: center; justify-items: center", "align-content: center; justify-items: center"] {
            let section = try H.build(body, css: reset + ".grid { display: grid; min-height: 300px; \(declarations) }")
            XCTAssertFalse(section.report.flexGridSimplified)
            let view = H.scrolled(section, size: size)
            let cell = H.frame("Grid cell.", in: section, view: view)
            H.assertEqual(cell.midX, 200, declarations); H.assertEqual(cell.midY, 150, declarations)
            H.assertEqual(H.frame("After the grid.", in: section, view: view).minY, 300, declarations)
        }
    }

    func testOneColumnGridStretchesOrPacksItsRows() throws {
        let body = "<div class='grid'><p>Row one.</p><p>Row two.</p></div>"
        func tops(_ declarations: String) throws -> (CGFloat, CGFloat, CGFloat) {
            let section = try H.build(body, css: reset + ".grid { display: grid; height: 300px; \(declarations) }")
            let view = H.scrolled(section, size: size)
            let one = H.frame("Row one.", in: section, view: view), two = H.frame("Row two.", in: section, view: view)
            return (one.minY, two.minY, one.height)
        }
        // Auto rows share the height: each item sits in a row of half the box.
        var (one, two, line) = try tops("")
        H.assertEqual(one, 0); H.assertEqual(two, 150)
        (one, two, line) = try tops("align-items: center")
        H.assertEqual(one, (150 - line) / 2); H.assertEqual(two, 150 + (150 - line) / 2)
        (one, two, line) = try tops("align-items: end")
        H.assertEqual(one, 150 - line); H.assertEqual(two, 300 - line)
        // Packed rows keep their own height.
        (one, two, line) = try tops("align-content: center")
        H.assertEqual(one, (300 - 2 * line) / 2); H.assertEqual(two, (300 - 2 * line) / 2 + line)
        (one, two, line) = try tops("align-content: space-between")
        H.assertEqual(one, 0); H.assertEqual(two, 300 - line)
        (one, two, line) = try tops("align-content: end")
        H.assertEqual(two, 300 - line)
        let section = try H.build(body, css: reset + ".grid { display: grid; justify-items: end }")
        H.assertEqual(H.frame("Row two.", in: section, view: H.scrolled(section, size: size)).maxX, 400)
    }

    // MARK: Heights

    func testHeightsResolveAgainstTheViewportThePercentageChainAndBoxSizing() throws {
        let body = "<div class='box'><p>Sized content.</p></div>"
        func middle(_ css: String, size: CGSize) throws -> CGFloat {
            let section = try H.build(body, css: reset + ".box { display: flex; flex-direction: column; justify-content: center } " + css)
            return H.frame("Sized content.", in: section, view: H.scrolled(section, size: size)).midY
        }
        for viewport in [CGSize(width: 320, height: 500), CGSize(width: 400, height: 600), CGSize(width: 700, height: 950)] {
            H.assertEqual(try middle(".box { min-height: 100vh }", size: viewport), viewport.height / 2)
            H.assertEqual(try middle(".box { height: 50vh }", size: viewport), viewport.height / 4)
            H.assertEqual(try middle(".box { min-height: 50vw }", size: viewport), viewport.width / 4)
            H.assertEqual(try middle("html, body { height: 100% } .box { height: 50% }", size: viewport), viewport.height / 4)
            H.assertEqual(try middle("html { height: 100% } body { height: 50% } .box { min-height: 100% }", size: viewport), viewport.height / 4)
            // A percentage of an indefinite height is no height: block flow.
            let line = try middle("", size: viewport) * 2
            H.assertEqual(try middle(".box { height: 50% }", size: viewport), line / 2)
            // Mixed units are exact, not approximated against a nominal page.
            H.assertEqual(try middle(".box { min-height: calc(100vh - 100px) }", size: viewport), (viewport.height - 100) / 2)
            // One viewport at most: a taller box would centre its content off the page.
            H.assertEqual(try middle(".box { min-height: 150vh }", size: viewport), viewport.height / 2)
            H.assertEqual(try middle(".box { height: 100vh; max-height: 50vh }", size: viewport), viewport.height / 4)
        }
        // Padding is outside a content-box height and inside a border-box one.
        H.assertEqual(try middle(".box { height: 300px; padding: 50px 0 }", size: size), 50 + 150)
        H.assertEqual(try middle(".box { height: 300px; padding: 50px 0; box-sizing: border-box }", size: size), 50 + 100)
    }

    func testContentTallerThanItsBoxKeepsBlockFlow() throws {
        let long = String(repeating: "A sentence of ordinary prose that fills its lines. ", count: 12)
        let section = try H.build("<div class='box'><p>\(long)</p><p>\(long)</p></div>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: center; min-height: 100px }")
        let resolved = ReaderBoxLayout.resolve(section.string, viewport: size)
        XCTAssertTrue(resolved.text.isEqual(to: section.string), "nothing to distribute: the source formatting stands")
        XCTAssertNil(resolved.geometry)
        XCTAssertEqual(ReaderAlignmentLayout.lead(in: resolved.text, at: 0), 0)
    }

    func testATextViewGivesBackSpaceItsContentOutgrows() throws {
        let long = Array(repeating: "A sentence of ordinary prose that fills its lines.", count: 10).joined(separator: " ")
        let section = try H.build("<div class='box'><p>\(long)</p></div><p>After the box.</p>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: center; min-height: 50vh }")
        let view = H.scrolled(section, size: CGSize(width: 600, height: 800))
        let roomy = H.frame(long, in: section, view: view)
        H.assertEqual(roomy.midY, 200, "centred in 50vh of an 800-point viewport")
        // Narrow and short: the paragraph is taller than half the viewport.
        view.readerContainer.size = CGSize(width: 200, height: 0)
        view.readerContainer.viewportSize = CGSize(width: 200, height: 300)
        view.refreshFlowBoxLayout()
        view.ensureFullLayout()
        let tight = H.frame(long, in: section, view: view)
        XCTAssertGreaterThan(tight.height, 150)
        H.assertEqual(tight.minY, 0, "no stale space above")
        H.assertEqual(H.frame("After the box.", in: section, view: view).minY, tight.maxY, "or below")
    }

    // MARK: Nesting

    func testAStretchedOrGrownItemThatIsAContainerAlignsInsideItsNewHeight() throws {
        let grown = try H.build("<div class='outer'><p>Heading line.</p><div class='inner'><p>Centred inside.</p></div></div>",
            css: reset + ".outer { display: flex; flex-direction: column; height: 400px } "
                + ".inner { flex: 1; display: flex; flex-direction: column; justify-content: center; align-items: center }")
        var view = H.scrolled(grown, size: size)
        let heading = H.frame("Heading line.", in: grown, view: view)
        var inner = H.frame("Centred inside.", in: grown, view: view)
        H.assertEqual(heading.minY, 0)
        H.assertEqual(inner.midY, heading.maxY + (400 - heading.height) / 2)
        H.assertEqual(inner.midX, 200)
        // A row's only item stretches to the row's height.
        let stretched = try H.build("<div class='outer'><div class='inner'><p>Centred inside.</p></div></div>",
            css: reset + ".outer { display: flex; height: 300px } .inner { display: flex; flex-direction: column; justify-content: center }")
        view = H.scrolled(stretched, size: size)
        inner = H.frame("Centred inside.", in: stretched, view: view)
        H.assertEqual(inner.midY, 150)
        // A nested box with its own height counts as content of the outer one.
        let boxed = try H.build("<div class='outer'><div class='inner'><p>Centred inside.</p></div></div><p>After both.</p>",
            css: reset + ".outer { display: flex; flex-direction: column; justify-content: center; height: 400px } "
                + ".inner { display: flex; flex-direction: column; justify-content: flex-end; height: 100px }")
        view = H.scrolled(boxed, size: size)
        H.assertEqual(H.frame("Centred inside.", in: boxed, view: view).maxY, 150 + 100, "the inner box is centred, its content at its bottom")
        H.assertEqual(H.frame("After both.", in: boxed, view: view).minY, 400)
    }

    // MARK: Pages

    func testAnAlignedBoxKeepsItsSpaceWhereverItsPageStarts() throws {
        let css = reset + ".box { display: flex; flex-direction: column; justify-content: center; min-height: 100vh }"
        // After a forced break.
        var section = try H.build("<p>Before the break.</p><div class='box' style='break-before: page'><p>Centred after a break.</p></div>", css: css)
        var paged = H.paged("Centred after a break.", in: section, size: size)
        XCTAssertEqual(paged.page, 1)
        H.assertEqual(paged.frame.midY, 300)
        // Pushed to a new page by what is before it (an unforced break): the margin above is
        // truncated there, the box's own space is not.
        section = try H.build("<p style='margin-bottom: 500px'>Before the box.</p><div class='box'><p>Centred after prose.</p></div><p>After the box.</p>", css: css)
        paged = H.paged("Centred after prose.", in: section, size: size)
        XCTAssertEqual(paged.page, 1)
        H.assertEqual(paged.frame.midY, 300)
        XCTAssertEqual(H.paged("After the box.", in: section, size: size).page, 2, "the box fills its page")
        // With room left on the page the box starts there, as it would in a browser: its
        // content is centred in the box, which runs past the page's end.
        section = try H.build("<p>Before the box.</p><div class='box' style='min-height: 60vh'><p>Centred in a box below.</p></div>", css: css)
        let before = H.paged("Before the box.", in: section, size: size), below = H.paged("Centred in a box below.", in: section, size: size)
        XCTAssertEqual(below.page, 0)
        H.assertEqual(below.frame.midY, before.frame.maxY + 180)
        // Below a heading on the same page: the box starts under it.
        section = try H.build("<h1>Heading</h1><div class='box' style='min-height: 300px'><p>Centred under a heading.</p></div>", css: css)
        let heading = H.paged("Heading", in: section, size: size), under = H.paged("Centred under a heading.", in: section, size: size)
        XCTAssertEqual(under.page, 0)
        H.assertEqual(under.frame.midY, heading.frame.maxY + 150)
        // Every page still fits its column and the pages cover the text once.
        let paginator = ReaderPaginator(text: section.string, size: size)
        XCTAssertTrue(paginator.allPages.allSatisfy { $0.height + $0.topSpacing <= size.height + 0.5 })
        XCTAssertEqual(paginator.allPages.map(\.range.length).reduce(0, +), section.string.length)
    }

    func testBottomAlignedContentIsNotCappedAtHalfThePage() throws {
        let section = try H.build("<div class='box'><p>Bottom of the page.</p></div>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: flex-end; min-height: 100vh }")
        H.assertEqual(H.paged("Bottom of the page.", in: section, size: size).frame.maxY, 600)
    }

    func testPageSlicesCarryResolvedSpacingButNoAlignmentToResolveAgain() throws {
        let section = try H.build("<div class='box'><p>Centred once.</p></div>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: center; align-items: center; min-height: 100vh }")
        XCTAssertNotNil(section.string.attribute(.readerAlignment, at: 0, effectiveRange: nil))
        let paginator = ReaderPaginator(text: section.string, size: size)
        let slice = paginator.text(for: paginator.allPages[0])
        XCTAssertNil(slice.attribute(.readerAlignment, at: 0, effectiveRange: nil))
        XCTAssertNil(slice.attribute(.readerAlignmentLead, at: 0, effectiveRange: nil))
        XCTAssertTrue(ReaderBoxLayout.resolve(slice, viewport: size).text === slice)
    }

    // MARK: A box's paragraphs

    /// Continuous scroll finds the box around a position from the paragraphs' own tags.
    func testBoxesAroundALocationAreTheParagraphsSharingAContainerWithAHeight() throws {
        let column = "display: flex; flex-direction: column; justify-content: center; "
        let section = try H.build("""
            <p>Before the boxes.</p>\
            <div class='outer'><p>Outer first.</p><div class='inner'><p>Inner first.</p><p>Inner last.</p></div><p>Outer last.</p></div>\
            <div class='loose'><p>No height one.</p><p>No height two.</p></div>\
            <div class='row'><p>Left.</p><p>Right.</p></div><p>After the boxes.</p>
            """, css: reset + ".outer { \(column) min-height: 500px } .inner { \(column) height: 200px } "
                + ".loose { \(column) align-items: center } .row { display: flex; height: 300px }")
        let text = section.string
        func start(_ phrase: String) -> Int { H.range(phrase, in: section).location }
        func boxes(_ phrase: String, offset: Int = 0) -> [NSRange] {
            ReaderAlignmentLayout.boxes(in: text, around: start(phrase) + offset)
        }
        let outer = NSRange(location: start("Outer first."), length: start("No height one.") - start("Outer first."))
        let inner = NSRange(location: start("Inner first."), length: start("Outer last.") - start("Inner first."))
        XCTAssertEqual(boxes("Outer first."), [outer])
        XCTAssertEqual(boxes("Outer last.", offset: 6), [outer], "from any character of any of its paragraphs")
        XCTAssertEqual(boxes("Inner first."), [outer, inner], "the outermost first")
        XCTAssertEqual(boxes("Inner last.", offset: 11), [outer, inner], "a paragraph's own break is its last character")
        XCTAssertEqual(boxes("Before the boxes."), [])
        XCTAssertEqual(boxes("No height two."), [], "a container without a height composes nothing down the page")
        XCTAssertEqual(boxes("Right."), [], "a row with several items is in block flow")
        XCTAssertEqual(boxes("After the boxes."), [])
        XCTAssertEqual(ReaderAlignmentLayout.boxes(in: text, around: -1), [])
        XCTAssertEqual(ReaderAlignmentLayout.boxes(in: NSAttributedString(), around: 0), [])
        // The same from resolved text, which is what a scroll view holds.
        let resolved = ReaderBoxLayout.resolve(text, viewport: size).text
        XCTAssertEqual(ReaderAlignmentLayout.boxes(in: resolved, around: start("Inner last.")), [outer, inner])
        XCTAssertGreaterThan(ReaderAlignmentLayout.lead(in: resolved, at: outer.location), 0)
        // In a whole book a section's end is the break after it: still the box that ends there,
        // and never the next section's paragraphs, even where a spine repeats an item.
        let page = try H.build("<section><p>For someone.</p><p>With thanks.</p></section>",
                               css: reset + "section { \(column) min-height: 98vh }")
        let book = CanvasText.book([page.string, page.string, section.string])
        let length = page.string.length
        XCTAssertEqual(ReaderAlignmentLayout.boxes(in: book.string, around: book.location(of: ReaderTextPosition(section: 0, offset: length))),
                       [NSRange(location: 0, length: length)])
        XCTAssertEqual(ReaderAlignmentLayout.boxes(in: book.string, around: book.location(of: ReaderTextPosition(section: 1, offset: 3))),
                       [NSRange(location: length + 1, length: length)])
        XCTAssertEqual(ReaderAlignmentLayout.boxes(in: book.string, around: book.string.length), [],
                       "the book's end is in its last paragraph, which is in no box")
    }

    func testABoxLongerThanAnyScreenIsNotMeasured() throws {
        let paragraphs = (0..<1_600).map { "<p>Paragraph \($0) of a section that its body lays out as a column.</p>" }.joined()
        let section = try H.build(paragraphs, css: reset + "html { height: 100% } body { display: flex; flex-direction: column; min-height: 100% }")
        XCTAssertGreaterThan(section.string.length, ReaderAlignmentLayout.maximumMeasuredContainer)
        XCTAssertNotNil(section.string.attribute(.readerAlignment, at: 0, effectiveRange: nil))
        for location in [0, section.string.length / 2, section.string.length] {
            XCTAssertEqual(ReaderAlignmentLayout.boxes(in: section.string, around: location), [], "\(location)")
        }
    }

    // MARK: Other content

    func testRulesAndTablesAreMeasuredInsideAnAlignedBox() throws {
        let section = try H.build("""
            <div class='box'><p>Above the rule.</p><hr/><table><tr><td>North</td><td>East</td></tr><tr><td>South</td><td>West</td></tr></table>\
            <p>Below the table.</p></div><p>After the box.</p>
            """, css: reset + ".box { display: flex; flex-direction: column; justify-content: center; align-items: center; height: 500px }")
        XCTAssertFalse(section.report.flexGridSimplified)
        let view = H.scrolled(section, size: size)
        let above = H.frame("Above the rule.", in: section, view: view), below = H.frame("Below the table.", in: section, view: view)
        XCTAssertGreaterThan(below.minY - above.maxY, 2 * above.height, "the rule and both table rows are between them")
        H.assertEqual((above.minY + below.maxY) / 2, 250)
        H.assertEqual(above.midX, 200); H.assertEqual(below.midX, 200)
        H.assertEqual(H.frame("After the box.", in: section, view: view).minY, 500)
        BuilderHarness.assertMapRoundTrips(section)
    }

    func testAnAlignedBoxInASectionWithFloatsKeepsBothLayouts() throws {
        let prose = Array(repeating: "Prose continues beside the initial and then below it across the column.", count: 4).joined(separator: " ")
        let section = try H.build("<div class='box'><p>Centred opening.</p></div><p><span class='cap'>W</span>\(prose)</p>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: center; align-items: center; height: 300px } "
                + ".cap { float: left; font-size: 48px }")
        XCTAssertTrue(section.report.flowBoxesReflowed)
        let view = H.scrolled(section, size: size)
        let opening = H.frame("Centred opening.", in: section, view: view)
        H.assertEqual(opening.midX, 200)
        let cap = H.frame("W", in: section, view: view), body = H.frame("Prose continues", in: section, view: view)
        XCTAssertGreaterThanOrEqual(body.minX, cap.maxX - 1, "the float still has prose beside it")
        XCTAssertGreaterThan(cap.minY, opening.maxY)
        let paginator = ReaderPaginator(text: section.string, size: size)
        XCTAssertTrue(paginator.allPages.allSatisfy { $0.height + $0.topSpacing <= size.height + 0.75 })
        XCTAssertEqual(paginator.allPages.map { page in
            (paginator.text(for: page).string as NSString).substring(with: NSRange(location: 0, length: page.range.length))
        }.joined(), section.string.string)
    }

    // MARK: Relayout

    func testRelayoutStartsFromSourceFormattingAndKeepsTextAndSelection() throws {
        let section = try H.build("<div class='box'><p>Relaid out passage.</p></div><p>Following text.</p>",
            css: reset + ".box { display: flex; flex-direction: column; justify-content: center; align-items: center; min-height: 100vh }")
        let view = H.scrolled(section, size: size)
        let selection = NSRange(location: 3, length: 6)
        view.selectedRange = selection
        for viewport in [CGSize(width: 300, height: 500), CGSize(width: 900, height: 700), size, size] {
            view.readerContainer.size = CGSize(width: viewport.width, height: 0)
            view.readerContainer.viewportSize = viewport
            view.refreshFlowBoxLayout()
            view.ensureFullLayout()
            let frame = H.frame("Relaid out passage.", in: section, view: view)
            H.assertEqual(frame.midY, viewport.height / 2); H.assertEqual(frame.midX, viewport.width / 2)
            H.assertEqual(H.frame("Following text.", in: section, view: view).minY, viewport.height)
            XCTAssertEqual(view.contentStorage.textStorage?.string, section.string.string)
            XCTAssertEqual(view.selectedRange, selection)
        }
    }
}
