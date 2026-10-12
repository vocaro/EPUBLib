import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The alignment fixtures in a mounted canvas: page columns and one continuous scroll view, as
/// the reader shows them. Geometry is in the canvas's coordinates.
@MainActor final class BoxAlignmentCanvasTests: XCTestCase {
    private typealias H = AlignmentHarness
    private typealias F = Fixture.Alignment
    /// A visible line is placed to within a point; alignment adds its own tolerance.
    private let tolerance: CGFloat = 2.5

    private func sections() throws -> [SectionText] {
        let prose = String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 60)
        return [try H.build(F.titleBody, css: F.titleCSS), try H.build(F.epigraphBody, css: F.epigraphCSS),
                try H.build(F.dedicationBody, css: F.dedicationCSS),
                try H.build("<h2>Chapter</h2><p>The chapter opens here.</p>" + prose, css: "body { margin: 0 }")]
    }

    /// `phrase`'s frame in the canvas, from the text view showing it.
    private func frame(_ phrase: String, section: Int, of texts: [SectionText], in canvas: ReaderCanvasView,
                       file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let range = H.range(phrase, in: texts[section])
        for view in canvas.textViews {
            let local: Int
            if let book = canvas.scrollBook {
                local = book.location(of: ReaderTextPosition(section: section, offset: range.location))
            } else {
                guard view.placement.section == section, range.location >= view.placement.offset,
                      range.location < view.placement.offset + view.placement.visibleLength else { continue }
                local = range.location - view.placement.offset
            }
            view.ensureLayout(from: local, through: local + range.length)
            let frames = view.segmentFrames(for: NSRange(location: local, length: range.length))
            guard !frames.isEmpty else { continue }
            let origin = view.containerOrigin
            return view.convert(frames.reduce(CGRect.null) { $0.union($1) }.offsetBy(dx: origin.x, dy: origin.y), to: canvas)
        }
        XCTFail("\(phrase) is not on screen", file: file, line: line)
        return .null
    }

    func testPaginatedEpigraphIsCentredInItsColumnWithOneAndTwoColumns() async throws {
        let texts = try sections()
        for (size, columns) in [(CGSize(width: 500, height: 700), 1), (CGSize(width: 1100, height: 700), 2)] {
            let host = CanvasHost(FakeCanvasSource(texts.map(\.string)), size: size, configuration: .init(flow: .paginated))
            defer { host.close() }
            host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
            host.layOut()
            let spread = try XCTUnwrap(host.canvas.spread)
            XCTAssertEqual(spread.columns.count, columns)
            let column = spread.columns[0]
            let verse = try frame("A quiet line stands alone.", section: 1, of: texts, in: host.canvas)
            let source = try frame("An Imagined Author", section: 1, of: texts, in: host.canvas)
            XCTAssertEqual((verse.minY + source.maxY) / 2, column.minY + 0.49 * column.height, accuracy: tolerance,
                           "the middle of the column's page, \(columns) column(s)")
            XCTAssertEqual(verse.midX, column.midX, accuracy: tolerance)
            XCTAssertEqual(source.maxX, verse.maxX, accuracy: tolerance)
            XCTAssertEqual(host.canvas.textViews.count, 1, "the epigraph is one page: a spread's other column stays empty")
            XCTAssertEqual(host.canvas.visibleRange, ReaderTextRange(section: 1, 0..<texts[1].string.length))
            // The grid dedication and the percentage-height title page, by page turns.
            XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
            let to = try frame("For the patient reader.", section: 2, of: texts, in: host.canvas)
            XCTAssertEqual(to.midY, column.minY + 0.45 * column.height, accuracy: tolerance)
            XCTAssertEqual(to.midX, column.midX, accuracy: tolerance)
            XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
            XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
            let title = try frame("An Aligned Book", section: 0, of: texts, in: host.canvas)
            let byline = try frame("Test Author", section: 0, of: texts, in: host.canvas)
            XCTAssertEqual((title.minY + byline.maxY) / 2, column.midY, accuracy: tolerance)
            XCTAssertEqual(title.midX, column.midX, accuracy: tolerance)
            // A resize repaginates and recentres.
            host.resize(to: CGSize(width: size.width, height: 560))
            try await host.settle()
            let resized = try XCTUnwrap(host.canvas.spread).columns[0]
            let again = try frame("An Aligned Book", section: 0, of: texts, in: host.canvas)
            let below = try frame("Test Author", section: 0, of: texts, in: host.canvas)
            XCTAssertEqual((again.minY + below.maxY) / 2, resized.midY, accuracy: tolerance)
        }
    }

    /// A section with floats pages through its box geometry, whose origin once put a page's top
    /// spacing inside the column as well as above it.
    func testPagesOfSectionsWithFloatsKeepTopSpacingAndAlignedBoxesOnce() throws {
        let reset = "body { margin: 0 } p, div { margin: 0; padding: 0; text-indent: 0 } .cap { float: left; font-size: 48px } "
        let prose = Array(repeating: "Prose continues beside the initial and then below it across the column.", count: 4).joined(separator: " ")
        let float = "<p><span class='cap'>W</span>\(prose)</p>"
        let box = ".box { display: flex; flex-direction: column; justify-content: center; height: 300px } "
        let texts = [
            try H.build("<p class='first'>Opening line.</p>" + float, css: reset + ".first { margin-top: 40px }"),
            try H.build("<div class='box'><p>Centred opening.</p></div>" + float, css: reset + box),
            try H.build("<p>Before the break.</p><div class='box' style='break-before: page'><p>Centred after a break.</p></div>" + float, css: reset + box),
            // The margin leaves no room for the box's first line on the first page: an unforced break.
            try H.build("<p style='margin-bottom: 500px'>Before the box.</p><div class='box' style='height: auto; min-height: 100vh'>"
                + "<p>Centred after prose.</p></div>" + float, css: reset + box),
        ]
        let host = CanvasHost(FakeCanvasSource(texts.map(\.string)), size: CGSize(width: 500, height: 700), configuration: .init(flow: .paginated))
        defer { host.close() }
        func top(_ phrase: String, section: Int) throws -> (line: CGRect, column: CGRect) {
            host.canvas.show(ReaderTextPosition(section: section, offset: H.range(phrase, in: texts[section]).location), selecting: nil)
            host.layOut()
            XCTAssertNotNil(host.canvas.textViews.first?.readerContainer.boxPage, "the section has box geometry")
            return (try frame(phrase, section: section, of: texts, in: host.canvas), try XCTUnwrap(host.canvas.spread).columns[0])
        }
        var result = try top("Opening line.", section: 0)
        XCTAssertEqual(result.line.minY - result.column.minY, 40, accuracy: 1, "a first paragraph's margin, once")
        result = try top("Centred opening.", section: 1)
        XCTAssertEqual(result.line.midY - result.column.minY, 150, accuracy: tolerance)
        result = try top("Centred after a break.", section: 2)
        XCTAssertEqual(result.line.midY - result.column.minY, 150, accuracy: tolerance)
        result = try top("Centred after prose.", section: 3)
        XCTAssertEqual(host.canvas.visibleRange?.start.offset, H.range("Centred after prose.", in: texts[3]).location, "it opens a page")
        XCTAssertEqual(result.line.midY, result.column.midY, accuracy: tolerance)
    }

    func testPaginatedSelectionAndHighlightsUseTheSameOffsetsInAnAlignedSection() async throws {
        let texts = try sections()
        let host = CanvasHost(FakeCanvasSource(texts.map(\.string)), size: CGSize(width: 500, height: 700),
                              configuration: .init(flow: .paginated))
        defer { host.close() }
        let quiet = H.range("quiet line", in: texts[1])
        let range = ReaderTextRange(section: 1, quiet.location..<quiet.upperBound)
        host.canvas.show(range.start, selecting: range)
        host.layOut()
        try await host.settle()
        XCTAssertEqual(host.canvas.currentSelection?.range, range)
        XCTAssertEqual(host.canvas.currentSelection?.text, "quiet line")
        let column = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(column.selectedRange, NSRange(location: quiet.location, length: quiet.length))
        XCTAssertEqual(column.visibleText, texts[1].string.string)
        host.canvas.setHighlights([ReaderHighlight(id: "h", range: range, kind: .annotation)])
        let selected = try frame("quiet line", section: 1, of: texts, in: host.canvas)
        let verse = try frame("A quiet line stands alone.", section: 1, of: texts, in: host.canvas)
        XCTAssertTrue(verse.insetBy(dx: -1, dy: -1).contains(selected), "the passage is drawn inside its centred line")
    }

    func testScrolledNavigationRestsAnAlignedBoxAtTheTopOfTheVisibleArea() async throws {
        let texts = try sections()
        let source = FakeCanvasSource(texts.map(\.string))
        source.book = CanvasText.book(texts.map(\.string))
        let host = CanvasHost(source, size: CGSize(width: 500, height: 700), configuration: .init(flow: .scrolled))
        defer { host.close() }
        func middle(_ first: String, _ last: String, section: Int) throws -> (offset: CGFloat, visible: CGRect, midX: CGFloat) {
            let canvas = host.canvas
            let top = try frame(first, section: section, of: texts, in: canvas), bottom = try frame(last, section: section, of: texts, in: canvas)
            let view = try XCTUnwrap(canvas.scrollTextView)
            let origin = view.containerOrigin
            let visible = view.convert(canvas.scrollVisibleContainerRect.offsetBy(dx: origin.x, dy: origin.y), to: canvas)
            return ((top.minY + bottom.maxY) / 2 - visible.minY, visible, top.midX)
        }
        // The epigraph, mid-book: its box opens at the top of the visible area, its text in the middle.
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        host.layOut()
        try await host.settle()
        var result = try middle("A quiet line stands alone.", "An Imagined Author", section: 1)
        XCTAssertGreaterThan(result.visible.height, 300)
        XCTAssertEqual(result.offset, 0.49 * result.visible.height, accuracy: tolerance)
        XCTAssertEqual(result.midX, result.visible.midX, accuracy: tolerance)
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
        XCTAssertEqual(host.canvas.scrollTextView?.contentStorage.textStorage?.string, source.book?.string.string)
        // The grid dedication after it.
        host.canvas.show(ReaderTextPosition(section: 2, offset: 0), selecting: nil)
        try await host.settle()
        result = try middle("For the patient reader.", "For the patient reader.", section: 2)
        XCTAssertEqual(result.offset, 0.45 * result.visible.height, accuracy: tolerance)
        // The epigraph above it is exactly its border box tall: `calc(98vh - 3em)`.
        let book = try XCTUnwrap(host.canvas.scrollBook), scroll = try XCTUnwrap(host.canvas.scrollTextView)
        scroll.ensureLayout(from: book.location(of: ReaderTextPosition(section: 1, offset: 0)),
                            through: book.location(of: ReaderTextPosition(section: 2, offset: texts[2].string.length)))
        let verse = try frame("A quiet line stands alone.", section: 1, of: texts, in: host.canvas)
        let attribution = try frame("An Imagined Author", section: 1, of: texts, in: host.canvas)
        let dedication = try frame("For the patient reader.", section: 2, of: texts, in: host.canvas)
        let height = result.visible.height
        XCTAssertEqual((dedication.midY - 0.45 * height) - ((verse.minY + attribution.maxY) / 2 - 0.49 * height),
                       0.98 * height - 48, accuracy: tolerance)
        // The title page opens the text, where TextKit drops the space before a first paragraph.
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        try await host.settle()
        result = try middle("An Aligned Book", "Test Author", section: 0)
        XCTAssertEqual(result.offset, result.visible.height / 2, accuracy: tolerance)
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
        // A resize keeps the shown box at the top of the new visible area and recentres its text.
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        try await host.settle()
        for size in [CGSize(width: 420, height: 560), CGSize(width: 640, height: 820)] {
            host.resize(to: size)
            try await host.settle()
            result = try middle("A quiet line stands alone.", "An Imagined Author", section: 1)
            XCTAssertEqual(result.offset, 0.49 * result.visible.height, accuracy: tolerance, "\(size)")
            XCTAssertEqual(result.midX, result.visible.midX, accuracy: tolerance, "\(size)")
            XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
        }
        // Ordinary positions still rest their own line at the top.
        let opening = H.range("The chapter opens here.", in: texts[3]).location
        host.canvas.show(ReaderTextPosition(section: 3, offset: opening), selecting: nil)
        try await host.settle()
        let line = try frame("The chapter opens here.", section: 3, of: texts, in: host.canvas)
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        let origin = view.containerOrigin
        let visible = view.convert(host.canvas.scrollVisibleContainerRect.offsetBy(dx: origin.x, dy: origin.y), to: host.canvas)
        XCTAssertEqual(line.minY, visible.minY, accuracy: 1.5)
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 3, offset: opening))
    }

    /// The visible reading area of the scroll view, in the canvas's coordinates.
    private func visibleArea(of canvas: ReaderCanvasView) throws -> CGRect {
        let view = try XCTUnwrap(canvas.scrollTextView)
        let origin = view.containerOrigin
        return view.convert(canvas.scrollVisibleContainerRect.offsetBy(dx: origin.x, dy: origin.y), to: canvas)
    }

    /// A page turned back to leaves the position at its section's end, which for a one-page
    /// dedication is the box's last line. Changing to continuous scroll there must show the box
    /// as navigating to it does, and so must any other position inside it. The book is Standard
    /// Ebooks' compatible build, which has box geometry: the text container places every line.
    func testScrolledPositionInsideAnAlignedBoxRestsTheBoxAtTheTopOfTheVisibleArea() async throws {
        let prose = String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 60)
        let tall = "<section style='display: flex; flex-direction: column; justify-content: center; min-height: 98vh'>"
            + (0..<90).map { "<p>Line \($0) of a box taller than the screen.</p>" }.joined() + "</section>"
        let texts = [try H.build(F.shippedTitleBody, css: F.shippedCSS), try H.build(F.shippedDedicationBody, css: F.shippedCSS),
                     try H.build(F.shippedEpigraphBody, css: F.shippedCSS),
                     try H.build("<h2>Chapter</h2><p>The chapter opens here.</p>" + prose, css: F.shippedCSS),
                     try H.build(tall, css: F.shippedCSS)]
        let source = FakeCanvasSource(texts.map(\.string))
        source.book = CanvasText.book(texts.map(\.string))
        let host = CanvasHost(source, size: CGSize(width: 500, height: 700), configuration: .init(flow: .paginated))
        defer { host.close() }
        /// How far the box starting `section` has its top edge below the top of the visible
        /// area, and its lines' middle as a share of that area's height.
        func box(_ first: String, _ last: String, section: Int) throws -> (top: CGFloat, middle: CGFloat) {
            let canvas = host.canvas, view = try XCTUnwrap(canvas.scrollTextView), book = try XCTUnwrap(canvas.scrollBook)
            let visible = try visibleArea(of: canvas)
            let top = try frame(first, section: section, of: texts, in: canvas), bottom = try frame(last, section: section, of: texts, in: canvas)
            let lead = ReaderAlignmentLayout.lead(in: try XCTUnwrap(view.contentStorage.textStorage),
                                                  at: book.location(of: ReaderTextPosition(section: section, offset: 0)))
            XCTAssertGreaterThan(lead, 100, "the box has space above its first line")
            return (top.minY - lead - visible.minY, ((top.minY + bottom.maxY) / 2 - visible.minY) / visible.height)
        }
        /// The box that is `section` is on screen whole, and its first line is the visible start.
        func assertWholeBoxIsShown(_ section: Int, line: UInt = #line) throws {
            let range = try XCTUnwrap(host.canvas.visibleRange)
            XCTAssertEqual(range.start, ReaderTextPosition(section: section, offset: 0), line: line)
            XCTAssertGreaterThanOrEqual(range.end, ReaderTextPosition(section: section, offset: texts[section].string.length), line: line)
        }
        // Paging: back from the chapter over the epigraph to the dedication.
        host.canvas.show(ReaderTextPosition(section: 3, offset: 0), selecting: nil)
        host.layOut()
        XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(host.canvas.visibleRange, ReaderTextRange(section: 1, 0..<texts[1].string.length))
        XCTAssertEqual(host.canvas.anchor, ReaderTextPosition(section: 1, offset: texts[1].string.length), "the section's end")
        host.canvas.configuration.flow = .scrolled
        host.layOut()
        try await host.settle()
        XCTAssertEqual(host.canvas.scrollTextView?.readerContainer.hasNonlinearGeometry, true, "the book has box geometry")
        var result = try box("For those", "to the last page", section: 1)
        XCTAssertEqual(result.top, 0, accuracy: 1.5, "the dedication's top edge is at the top of the visible area")
        XCTAssertEqual(result.middle, 0.49, accuracy: 0.01)
        try assertWholeBoxIsShown(1)
        // A resize keeps it so.
        for size in [CGSize(width: 420, height: 560), CGSize(width: 500, height: 700)] {
            host.resize(to: size)
            try await host.settle()
            result = try box("For those", "to the last page", section: 1)
            XCTAssertEqual(result.top, 0, accuracy: 1.5, "\(size)")
            XCTAssertEqual(result.middle, 0.49, accuracy: 0.01, "\(size)")
        }
        // The person scrolls the box's first line off the top (not through the canvas). The
        // position a resize keeps is then the visible start, inside the box, and the resize
        // shows the box whole again.
        let scroll = try XCTUnwrap(host.canvas.scrollTextView), book = try XCTUnwrap(host.canvas.scrollBook)
        let second = ReaderTextPosition(section: 1, offset: H.range("who read", in: texts[1]).location)
        let delta = try XCTUnwrap(scroll.lineFrame(containing: book.location(of: second))).minY - host.canvas.scrollVisibleContainerRect.minY
        #if os(macOS)
        let clip = try XCTUnwrap(host.canvas.scrollContainer as? NSScrollView).contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + delta))
        try XCTUnwrap(clip.enclosingScrollView).reflectScrolledClipView(clip)
        #else
        scroll.contentOffset.y += delta
        #endif
        try await host.settle()
        XCTAssertEqual(host.canvas.visibleRange?.start, second, "the second line is at the top")
        host.resize(to: CGSize(width: 460, height: 640))
        try await host.settle()
        result = try box("For those", "to the last page", section: 1)
        XCTAssertEqual(result.top, 0, accuracy: 1.5)
        XCTAssertEqual(result.middle, 0.49, accuracy: 0.01)
        // A position on a line in the middle of the epigraph, as a search result has.
        let third = H.range("And every road", in: texts[2]).location
        host.canvas.show(ReaderTextPosition(section: 2, offset: third), selecting: nil)
        try await host.settle()
        result = try box("A lantern in the window", "An Imagined Poet", section: 2)
        XCTAssertEqual(result.top, 0, accuracy: 1.5, "the epigraph's top edge is at the top of the visible area")
        XCTAssertEqual(result.middle, 0.49, accuracy: 0.01)
        try assertWholeBoxIsShown(2)
        // A box taller than the visible area: its top edge there could put the position off
        // screen, so every position in it rests its own line, the ones on its first screen too.
        for phrase in ["Line 45 of a box", "Line 5 of a box"] {
            let far = H.range(phrase, in: texts[4]).location
            host.canvas.show(ReaderTextPosition(section: 4, offset: far), selecting: nil)
            try await host.settle()
            let line = try frame(phrase, section: 4, of: texts, in: host.canvas)
            XCTAssertEqual(line.minY, try visibleArea(of: host.canvas).minY, accuracy: 1.5, "\(phrase): the position's own line")
            XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 4, offset: far), phrase)
        }
    }

    /// A rest is accepted within a point of the top, and the line above a rested one ends where
    /// it starts. In a book with box geometry the canvas reads the lines on screen from their
    /// frames, so a view standing half a point high shows a sliver of the line above. That line
    /// is not the visible start, which a resize keeps, and a sliver of a line at the bottom is
    /// not the visible end.
    func testALineShowingASliverIsNotTheVisibleStartOrEndInABookWithBoxGeometry() async throws {
        let prose = (0..<60).map { "<p>Paragraph \($0) of ordinary reading text, long enough to wrap onto a second line of the column.</p>" }.joined()
        let texts = [try H.build(F.shippedTitleBody, css: F.shippedCSS), try H.build(F.shippedDedicationBody, css: F.shippedCSS),
                     try H.build(F.shippedEpigraphBody, css: F.shippedCSS),
                     try H.build("<h2>Chapter</h2><p>The chapter opens here.</p>" + prose, css: F.shippedCSS)]
        let source = FakeCanvasSource(texts.map(\.string))
        source.book = CanvasText.book(texts.map(\.string))
        let host = CanvasHost(source, size: CGSize(width: 500, height: 700), configuration: .init(flow: .scrolled))
        defer { host.close() }
        // The title page first, so that its last line, the one above the dedication, is laid out.
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        try await host.settle()
        let canvas = host.canvas, view = try XCTUnwrap(canvas.scrollTextView), book = try XCTUnwrap(canvas.scrollBook)
        XCTAssertTrue(view.readerContainer.hasNonlinearGeometry, "the book has box geometry")
        /// Scrolls as the person does, not through the canvas.
        func scrollByHand(_ delta: CGFloat) throws {
            #if os(macOS)
            let clip = try XCTUnwrap(canvas.scrollContainer as? NSScrollView).contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta))
            try XCTUnwrap(clip.enclosingScrollView).reflectScrolledClipView(clip)
            #else
            view.contentOffset.y += delta
            #endif
        }
        func paragraph(_ index: Int) -> ReaderTextPosition {
            ReaderTextPosition(section: 3, offset: H.range("Paragraph \(index) of ordinary", in: texts[3]).location)
        }
        /// Where continuous scroll rests `position`: its line, or its box from the top edge.
        func rest(_ position: ReaderTextPosition) throws -> CGRect {
            let location = book.location(of: position)
            return view.anchorFrame(of: try XCTUnwrap(view.lineFrame(containing: location)), at: location)
        }
        // The dedication rests its box's top edge, below the title page's last line; a
        // paragraph rests its first line, below the last line of the paragraph before.
        for position in [ReaderTextPosition(section: 1, offset: 0), paragraph(7), paragraph(31)] {
            canvas.show(position, selecting: nil)
            try await host.settle()
            XCTAssertEqual(canvas.visibleRange?.start, position, "rested")
            // Up to where half a point of the line above shows, whatever the rest left of it.
            try scrollByHand(try rest(position).minY - 0.5 - canvas.scrollVisibleContainerRect.minY)
            try await host.settle()
            let above = try XCTUnwrap(view.lineFrame(containing: book.location(of: position) - 1))
            let sliver = above.maxY - canvas.scrollVisibleContainerRect.minY
            XCTAssertGreaterThan(sliver, 0, "the line above \(position) shows")
            XCTAssertLessThan(sliver, 1, "by less than the point a rest is accepted within")
            XCTAssertEqual(canvas.visibleRange?.start, position, "a sliver of the line above is not the visible start")
            // The person has scrolled, so a resize keeps the visible start: the same line.
            for size in [CGSize(width: 500, height: 560), CGSize(width: 500, height: 700)] {
                host.resize(to: size)
                try await host.settle()
                XCTAssertEqual(try rest(position).minY, canvas.scrollVisibleContainerRect.minY, accuracy: 1.5, "\(position) at \(size)")
                XCTAssertEqual(canvas.visibleRange?.start, position, "\(size)")
            }
        }
        // The bottom: to where half a point of a paragraph's first line shows there.
        let last = paragraph(44)
        try scrollByHand(try rest(last).minY + 0.5 - canvas.scrollVisibleContainerRect.maxY)
        try await host.settle()
        let sliver = canvas.scrollVisibleContainerRect.maxY - (try rest(last)).minY
        XCTAssertGreaterThan(sliver, 0, "the paragraph's first line shows")
        XCTAssertLessThan(sliver, 1)
        XCTAssertEqual(canvas.visibleRange?.end, last, "the visible end is the end of the line before")
    }

    /// A box rested by its top edge stays there through changes of the visible height at the
    /// same column width. Its first line moves by the change in the space above it, and on the
    /// Mac the step that holds the first line on screen in place after a layout behind the view
    /// took that for one and scrolled by as much (#313). When this was found the step compared
    /// the visible top with where it had been for equality, and the rest reaches the same place
    /// by arithmetic that differs in the last bit from one height to another, so the defect
    /// came and went. Here 700 to 560 showed it on 2026-10-12; 700 to 600 and to 650 move the
    /// line by 49 and 24.5 points, which are exact in binary and so leave the arithmetic the
    /// same wherever the box is.
    func testAChangeOfHeightAloneKeepsABoxRestedByItsTopEdgeAtTheTop() async throws {
        let prose = String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 60)
        let texts = [try H.build(F.shippedTitleBody, css: F.shippedCSS), try H.build(F.shippedDedicationBody, css: F.shippedCSS),
                     try H.build(F.shippedEpigraphBody, css: F.shippedCSS),
                     try H.build("<h2>Chapter</h2><p>The chapter opens here.</p>" + prose, css: F.shippedCSS)]
        let source = FakeCanvasSource(texts.map(\.string))
        source.book = CanvasText.book(texts.map(\.string))
        let host = CanvasHost(source, size: CGSize(width: 500, height: 700), configuration: .init(flow: .scrolled))
        defer { host.close() }
        // The title page first, so that the text above the dedication is laid out.
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        try await host.settle()
        let canvas = host.canvas, view = try XCTUnwrap(canvas.scrollTextView), book = try XCTUnwrap(canvas.scrollBook)
        let dedication = ReaderTextPosition(section: 1, offset: 0), location = book.location(of: dedication)
        /// How far the dedication's top edge is below the top of the visible area, and the
        /// space the box keeps above its first line.
        func box() throws -> (top: CGFloat, lead: CGFloat) {
            let line = try XCTUnwrap(view.lineFrame(containing: location))
            let rest = view.anchorFrame(of: line, at: location)
            return (rest.minY - canvas.scrollVisibleContainerRect.minY, line.minY - rest.minY)
        }
        canvas.show(dedication, selecting: nil)
        try await host.settle()
        var shown = try box()
        XCTAssertEqual(shown.top, 0, accuracy: 1, "shown")
        XCTAssertEqual(canvas.visibleRange?.start, dedication, "shown")
        let column = view.readerContainer.size.width
        for height: CGFloat in [640, 700, 560, 700, 600, 700, 650] {
            let before = shown.lead
            host.resize(to: CGSize(width: 500, height: height))
            try await host.settle()
            shown = try box()
            XCTAssertEqual(view.readerContainer.size.width, column, "the column keeps its width, so its lines wrap as they did")
            XCTAssertGreaterThan(abs(shown.lead - before), 20, "the space above the first line follows the height, \(height)")
            XCTAssertEqual(shown.top, 0, accuracy: 1, "the box's top edge at height \(height)")
            XCTAssertEqual(canvas.visibleRange?.start, dedication, "height \(height)")
        }
    }

    /// The same in a book without box geometry, where TextKit places the lines: a flex box, a
    /// grid, and the box that opens the text, whose space above its first line TextKit drops.
    func testChangingToScrollOnAPageTurnedBackToShowsItsBoxAsComposed() async throws {
        let texts = try sections()
        let source = FakeCanvasSource(texts.map(\.string))
        source.book = CanvasText.book(texts.map(\.string))
        let host = CanvasHost(source, size: CGSize(width: 500, height: 700), configuration: .init(flow: .paginated))
        defer { host.close() }
        let pages: [(section: Int, first: String, last: String, middle: CGFloat)] = [
            (2, "For the patient reader.", "For the patient reader.", 0.45), (1, "A quiet line stands alone.", "An Imagined Author", 0.49),
            (0, "An Aligned Book", "Test Author", 0.5)]
        for page in pages {
            host.canvas.show(ReaderTextPosition(section: page.section + 1, offset: 0), selecting: nil)
            host.layOut()
            XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
            XCTAssertEqual(host.canvas.anchor, ReaderTextPosition(section: page.section, offset: texts[page.section].string.length))
            host.canvas.configuration.flow = .scrolled
            host.layOut()
            try await host.settle()
            XCTAssertEqual(host.canvas.scrollTextView?.readerContainer.hasNonlinearGeometry, false)
            let visible = try visibleArea(of: host.canvas)
            let top = try frame(page.first, section: page.section, of: texts, in: host.canvas)
            let bottom = try frame(page.last, section: page.section, of: texts, in: host.canvas)
            XCTAssertEqual((top.minY + bottom.maxY) / 2 - visible.minY, page.middle * visible.height, accuracy: tolerance, "\(page.first)")
            XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: page.section, offset: 0), "\(page.first)")
            // And back: the page being read is the one shown.
            host.canvas.configuration.flow = .paginated
            host.layOut()
            XCTAssertEqual(host.canvas.visibleRange, ReaderTextRange(section: page.section, 0..<texts[page.section].string.length))
        }
    }

    /// Standard Ebooks' compatible build in one continuous scroll view. Its title page positions
    /// a heading and a byline (and the chapter here floats an initial), so the whole book has box
    /// geometry and the text container places every line. The flex pages must sit where they do
    /// on pages of their own, which have none (#63). The pages are as wide as the scroll view
    /// shows text in, which on a Mac with legacy scroll bars is the window less a scroll bar, so
    /// the two columns are the same width under either kind (#302).
    func testShippedStandardEbooksPagesKeepTheirPlaceInContinuousScroll() async throws {
        let prose = String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 60)
        let texts = [try H.build(F.shippedTitleBody, css: F.shippedCSS), try H.build(F.shippedDedicationBody, css: F.shippedCSS),
                     try H.build(F.shippedEpigraphBody, css: F.shippedCSS),
                     try H.build("<h2>Chapter</h2><p><span style='float: left; font-size: 3em'>T</span>he chapter opens here.</p>" + prose,
                                 css: F.shippedCSS)]
        for text in texts { XCTAssertFalse(text.report.flexGridSimplified) }
        let verses = ["A lantern in the window, burning low,", "Kept for the one who is not yet home,",
                      "And every road that leaves the town will know", "The way back."]
        let dedication = ["For those", "who read", "to the last page"]
        for size in [CGSize(width: 500, height: 700), CGSize(width: 340, height: 640)] {
            for bars in CanvasScrollBars.allCases {
                let here = "at \(size) with \(bars) scroll bars"
                // Continuous scroll: the whole book in one text view.
                let source = FakeCanvasSource(texts.map(\.string))
                source.book = CanvasText.book(texts.map(\.string))
                let host = CanvasHost(source, size: size, configuration: .init(flow: .scrolled))
                defer { host.close() }
                try host.setScrollBars(bars)
                func visibleArea() throws -> CGRect {
                    let view = try XCTUnwrap(host.canvas.scrollTextView)
                    let origin = view.containerOrigin
                    return view.convert(host.canvas.scrollVisibleContainerRect.offsetBy(dx: origin.x, dy: origin.y), to: host.canvas)
                }
                host.canvas.show(ReaderTextPosition(section: 2, offset: 0), selecting: nil)
                host.layOut()
                try await host.settle()
                let scroll = try XCTUnwrap(host.canvas.scrollTextView)
                XCTAssertNotNil(host.canvas.scrollBook)
                XCTAssertTrue(scroll.readerContainer.hasNonlinearGeometry, "the book has box geometry")
                // A legacy scroll bar takes its width from what the scroll view shows text in.
                let shown = scroll.convert(scroll.bounds, to: host.canvas)
                XCTAssertEqual(shown.width, size.width - bars.width, here)
                // Pages that wide: each section in a column of its own.
                let pages = CanvasHost(FakeCanvasSource(texts.map(\.string)), size: CGSize(width: shown.width, height: size.height),
                                       configuration: .init(flow: .paginated))
                defer { pages.close() }
                var paged: [String: CGRect] = [:]
                for (section, phrases) in [(1, dedication), (2, verses + ["An Imagined Poet"])] {
                    pages.canvas.show(ReaderTextPosition(section: section, offset: 0), selecting: nil)
                    pages.layOut()
                    XCTAssertEqual(pages.canvas.textViews.first?.readerContainer.hasNonlinearGeometry, false)
                    for phrase in phrases {
                        paged[phrase] = try frame(phrase, section: section, of: texts, in: pages.canvas).offsetBy(dx: shown.minX, dy: 0)
                    }
                }
                var visible = try visibleArea()
                var lines: [CGRect] = []
                for phrase in verses + ["An Imagined Poet"] {
                    let line = try frame(phrase, section: 2, of: texts, in: host.canvas), page = try XCTUnwrap(paged[phrase])
                    XCTAssertEqual(line.minX, page.minX, accuracy: 1, "\(phrase) \(here)")
                    XCTAssertEqual(line.maxX, page.maxX, accuracy: 1, "\(phrase) \(here)")
                    XCTAssertEqual(line.height, page.height, accuracy: 1, "\(phrase) wraps as on its page, \(here)")
                    lines.append(line)
                }
                let poet = lines[4], left = lines[0].minX
                XCTAssertEqual(lines[1].minX - left, 16, accuracy: 1, "an indented verse line")
                XCTAssertEqual(lines[2].minX, left, accuracy: 1)
                XCTAssertEqual((left + poet.maxX) / 2, visible.midX, accuracy: tolerance, "the quotation is centred, \(here)")
                XCTAssertLessThanOrEqual(lines.map(\.maxX).max() ?? 0, poet.maxX + 1, "the attribution ends at the quotation's right edge")
                XCTAssertLessThanOrEqual(poet.maxX - left, 0.8 * visible.width + 1, "no wider than `max-width: 80%`")
                XCTAssertEqual((lines[0].minY + poet.maxY) / 2 - visible.minY, 0.49 * visible.height, accuracy: tolerance, here)
                // The dedication: centred lines in a centred paragraph.
                host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
                try await host.settle()
                visible = try visibleArea()
                for phrase in dedication {
                    let line = try frame(phrase, section: 1, of: texts, in: host.canvas), page = try XCTUnwrap(paged[phrase])
                    XCTAssertEqual(line.midX, visible.midX, accuracy: tolerance, "\(phrase) \(here)")
                    XCTAssertEqual(line.minX, page.minX, accuracy: 1, "\(phrase) \(here)")
                }
                let first = try frame(dedication[0], section: 1, of: texts, in: host.canvas)
                let last = try frame(dedication[2], section: 1, of: texts, in: host.canvas)
                XCTAssertEqual((first.minY + last.maxY) / 2 - visible.minY, 0.49 * visible.height, accuracy: tolerance, here)
            }
        }
    }

    func testScrolledSectionShownOnItsOwnKeepsItsLeadAndSelection() async throws {
        // Before the whole book is built, continuous scroll shows the current section by itself.
        let texts = try sections()
        let host = CanvasHost(FakeCanvasSource(texts.map(\.string)), size: CGSize(width: 500, height: 700),
                              configuration: .init(flow: .scrolled))
        defer { host.close() }
        let quiet = H.range("quiet line", in: texts[1])
        let range = ReaderTextRange(section: 1, quiet.location..<quiet.upperBound)
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: range)
        host.layOut()
        try await host.settle()
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        XCTAssertNil(host.canvas.scrollBook)
        XCTAssertEqual(view.selectedRange, NSRange(location: quiet.location, length: quiet.length))
        XCTAssertEqual(host.canvas.currentSelection?.range, range)
        let verse = try frame("A quiet line stands alone.", section: 1, of: texts, in: host.canvas)
        let source = try frame("An Imagined Author", section: 1, of: texts, in: host.canvas)
        let origin = view.containerOrigin
        let visible = view.convert(host.canvas.scrollVisibleContainerRect.offsetBy(dx: origin.x, dy: origin.y), to: host.canvas)
        XCTAssertEqual((verse.minY + source.maxY) / 2 - visible.minY, 0.49 * visible.height, accuracy: tolerance)
    }
}
