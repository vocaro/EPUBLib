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

    /// Standard Ebooks' compatible build in one continuous scroll view. Its title page is an
    /// image, its heading and byline hidden off to the left and kept for VoiceOver on lines of
    /// no height; the chapter here floats an initial,
    /// so the whole book has box geometry and the text container places every line. The flex
    /// pages must sit where they do on pages of their own, which have none (#63).
    func testShippedStandardEbooksPagesKeepTheirPlaceInContinuousScroll() async throws {
        let prose = String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 60)
        let title = try H.build(F.shippedTitleBody, css: F.shippedCSS, files: ["titlepage.png": RichFixture.image(width: 1400, height: 340)])
        XCTAssertEqual(title.string.drawnString, "\u{FFFC}", "the title page draws its image alone")
        XCTAssertEqual(title.string.spokenLabels, ["An Aligned Book", "By Test Author."])
        XCTAssertFalse(title.report.flowBoxesReflowed, "a hidden heading is not a box")
        let texts = [title, try H.build(F.shippedDedicationBody, css: F.shippedCSS),
                     try H.build(F.shippedEpigraphBody, css: F.shippedCSS),
                     try H.build("<h2>Chapter</h2><p><span style='float: left; font-size: 3em'>T</span>he chapter opens here.</p>" + prose,
                                 css: F.shippedCSS)]
        for text in texts { XCTAssertFalse(text.report.flexGridSimplified) }
        let verses = ["A lantern in the window, burning low,", "Kept for the one who is not yet home,",
                      "And every road that leaves the town will know", "The way back."]
        let dedication = ["For those", "who read", "to the last page"]
        for size in [CGSize(width: 500, height: 700), CGSize(width: 340, height: 640)] {
            // Pages: each section in a column of its own.
            let pages = CanvasHost(FakeCanvasSource(texts.map(\.string)), size: size, configuration: .init(flow: .paginated))
            defer { pages.close() }
            var paged: [String: CGRect] = [:]
            for (section, phrases) in [(1, dedication), (2, verses + ["An Imagined Poet"])] {
                pages.canvas.show(ReaderTextPosition(section: section, offset: 0), selecting: nil)
                pages.layOut()
                XCTAssertEqual(pages.canvas.textViews.first?.readerContainer.hasNonlinearGeometry, false)
                for phrase in phrases { paged[phrase] = try frame(phrase, section: section, of: texts, in: pages.canvas) }
            }
            // Continuous scroll: the whole book in one text view.
            let source = FakeCanvasSource(texts.map(\.string))
            source.book = CanvasText.book(texts.map(\.string))
            let host = CanvasHost(source, size: size, configuration: .init(flow: .scrolled))
            defer { host.close() }
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
            var visible = try visibleArea()
            var lines: [CGRect] = []
            for phrase in verses + ["An Imagined Poet"] {
                let line = try frame(phrase, section: 2, of: texts, in: host.canvas), page = try XCTUnwrap(paged[phrase])
                XCTAssertEqual(line.minX, page.minX, accuracy: 1, "\(phrase) at \(size)")
                XCTAssertEqual(line.maxX, page.maxX, accuracy: 1, "\(phrase) at \(size)")
                XCTAssertEqual(line.height, page.height, accuracy: 1, "\(phrase) wraps as on its page, at \(size)")
                lines.append(line)
            }
            let poet = lines[4], left = lines[0].minX
            XCTAssertEqual(lines[1].minX - left, 16, accuracy: 1, "an indented verse line")
            XCTAssertEqual(lines[2].minX, left, accuracy: 1)
            XCTAssertEqual((left + poet.maxX) / 2, visible.midX, accuracy: tolerance, "the quotation is centred, at \(size)")
            XCTAssertLessThanOrEqual(lines.map(\.maxX).max() ?? 0, poet.maxX + 1, "the attribution ends at the quotation's right edge")
            XCTAssertLessThanOrEqual(poet.maxX - left, 0.8 * visible.width + 1, "no wider than `max-width: 80%`")
            XCTAssertEqual((lines[0].minY + poet.maxY) / 2 - visible.minY, 0.49 * visible.height, accuracy: tolerance)
            // The dedication: centred lines in a centred paragraph.
            host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
            try await host.settle()
            visible = try visibleArea()
            for phrase in dedication {
                let line = try frame(phrase, section: 1, of: texts, in: host.canvas), page = try XCTUnwrap(paged[phrase])
                XCTAssertEqual(line.midX, visible.midX, accuracy: tolerance, "\(phrase) at \(size)")
                XCTAssertEqual(line.minX, page.minX, accuracy: 1, "\(phrase) at \(size)")
            }
            let first = try frame(dedication[0], section: 1, of: texts, in: host.canvas)
            let last = try frame(dedication[2], section: 1, of: texts, in: host.canvas)
            XCTAssertEqual((first.minY + last.maxY) / 2 - visible.minY, 0.49 * visible.height, accuracy: tolerance)
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
