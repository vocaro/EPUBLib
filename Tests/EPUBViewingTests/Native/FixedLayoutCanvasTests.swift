import CoreGraphics
import EPUBCore
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Fixed-layout pages in the canvas, behind a fake data source
/// ([#5](https://github.com/vocaro/EPUBLib/issues/5)): spreads of two sections, page turns by
/// the spread, flowing sections before and after, right-to-left books and a host's division.
@MainActor final class FixedLayoutCanvasTests: XCTestCase {
    private var hosts: [CanvasHost] = []
    private struct MissingColumns: Error {}

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    /// A fixed-layout page's text, as the builder makes it: one image of `size`.
    static func page(_ size: CGSize = CGSize(width: 600, height: 800), seed: Int = 0) -> NSAttributedString {
        let data = Fixture.SpecBook.image(width: Int(size.width / 10), height: Int(size.height / 10), red: CGFloat(seed % 5) / 5)
        let source = ReaderImageSource.bitmap(data, path: "page\(seed).png", key: "fixed-layout-canvas-\(seed)-\(size)")!
        let image = ReaderImageAttachment(source: source, sizing: ImageSizing(intrinsic: size), alternative: .text("Page \(seed)"),
                                          style: ComputedStyle(), cache: .shared)
        return FixedLayoutPage(size: size).text(for: image)
    }

    /// A canvas over `count` pages and, at the indices in `flowing`, sections of text.
    private func host(pages count: Int, flowing: Set<Int> = [], sides: [Int: EPUBPageSpread] = [:], spread: EPUBSpread = .auto,
                      size: CGSize = CGSize(width: 1100, height: 800), configuration: ReaderCanvasConfiguration = .init(),
                      pageSize: CGSize = CGSize(width: 600, height: 800), show section: Int = 0) -> CanvasHost {
        let sections: [NSAttributedString?] = (0..<count).map {
            flowing.contains($0) ? CanvasText.section($0, paragraphs: 3) : Self.page(pageSize, seed: $0)
        }
        let source = FakeCanvasSource(sections)
        for index in 0..<count where !flowing.contains(index) {
            source.fixedPages[index] = ReaderFixedPage(size: pageSize, side: sides[index], spread: spread)
        }
        let host = CanvasHost(source, size: size, configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: section, offset: 0), selecting: nil)
        host.layOut()
        return host
    }

    private func shownSections(_ canvas: ReaderCanvasView) -> [Int?] { canvas.textViews.map(\.placement.section) }

    /// The columns on screen, which must be `count`: a test stops here rather than index past them.
    private func columns(_ canvas: ReaderCanvasView, _ count: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [ReaderTextView] {
        let views = canvas.textViews
        guard views.count == count else {
            XCTFail("\(views.count) columns on screen, showing \(shownSections(canvas)), not \(count)", file: file, line: line)
            throw MissingColumns()
        }
        return views
    }

    /// In a landscape canvas two pages share a spread, meeting at its middle, each fitted whole
    /// with its aspect kept. The visible range runs from the first page's section to the end of
    /// the second's, and a turn moves by the whole spread, to the book's end and back.
    func testALandscapeCanvasShowsTwoPagesSideBySideAndTurnsByTheSpread() throws {
        let host = host(pages: 5)
        let canvas = host.canvas
        XCTAssertEqual(shownSections(canvas), [0, 1])
        let pair = try columns(canvas, 2)
        let left = pair[0].frame, right = pair[1].frame
        XCTAssertEqual(left.maxX, right.minX, "the pages meet")
        XCTAssertEqual(left.width / left.height, 600.0 / 800, accuracy: 0.01)
        XCTAssertEqual(left.size, right.size)
        XCTAssertEqual(canvas.visibleRange, ReaderTextRange(start: ReaderTextPosition(section: 0, offset: 0),
                                                           end: ReaderTextPosition(section: 1, offset: 1)))
        XCTAssertEqual(host.recorder.shown.last?.range, canvas.visibleRange)
        XCTAssertEqual(canvas.canTurnPage(forward: true), true)
        XCTAssertEqual(canvas.canTurnPage(forward: false), false)
        XCTAssertEqual(canvas.layoutPage, EPUBLayoutPage(index: 0, count: 5, sectionIndex: 0, sectionCount: 1, shownCount: 2))
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(shownSections(canvas), [2, 3])
        XCTAssertEqual(canvas.layoutPage?.index, 2, "a page each")
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(shownSections(canvas), [4], "the last page, its partner's slot empty")
        XCTAssertEqual(canvas.layoutPage?.shownCount, 1)
        XCTAssertEqual(try columns(canvas, 1)[0].frame, left, "in the first slot's half, against the middle")
        XCTAssertEqual(canvas.canTurnPage(forward: true), false)
        XCTAssertEqual(canvas.turnPage(forward: true), .atBoundary)
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(shownSections(canvas), [2, 3])
        XCTAssertTrue(canvas.showsFixedPages)
        XCTAssertEqual(canvas.shownPageNumber, 3, "the first page's place in the book")
        // Shown any page of a spread, the canvas shows the spread.
        canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        XCTAssertEqual(shownSections(canvas), [0, 1])
    }

    /// In a portrait canvas a page with the default setting is shown alone, as large as fits,
    /// centered, and each turn shows the next.
    func testAPortraitCanvasShowsOnePageAtATime() throws {
        let host = host(pages: 3, size: CGSize(width: 600, height: 700))
        let canvas = host.canvas
        XCTAssertEqual(shownSections(canvas), [0])
        let frame = try columns(canvas, 1)[0].frame
        XCTAssertEqual(frame.midX, canvas.bounds.midX, accuracy: 1)
        XCTAssertEqual(frame.width / frame.height, 600.0 / 800, accuracy: 0.01)
        let area = ReaderCanvasGeometry.fixedArea(in: canvas.pageArea)
        XCTAssertEqual(frame.height, area.height, accuracy: 1, "a portrait page as tall as the area")
        for section in 1..<3 {
            XCTAssertEqual(canvas.turnPage(forward: true), .turned)
            XCTAssertEqual(shownSections(canvas), [section])
        }
    }

    /// `rendition:spread` `none` shows every page alone even in landscape, and `both` pairs
    /// them in portrait too.
    func testTheSpreadSettingDecidesWhetherPagesPair() throws {
        XCTAssertEqual(shownSections(host(pages: 4, spread: .none).canvas), [0])
        XCTAssertEqual(shownSections(host(pages: 4, spread: .both, size: CGSize(width: 600, height: 700)).canvas), [0, 1])
    }

    /// Right to left the first page of a spread is the right-hand one, and the sides an itemref
    /// names are kept: a page put on the left begins no spread.
    func testRightToLeftThePairsFirstPageIsOnTheRight() throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.isRightToLeft = true
        let host = host(pages: 4, sides: [1: .left, 2: .left], configuration: configuration)
        let canvas = host.canvas
        XCTAssertEqual(shownSections(canvas), [0, 1])
        let pair = try columns(canvas, 2)
        XCTAssertGreaterThan(pair[0].frame.minX, pair[1].frame.minX, "the first page on the right")
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(shownSections(canvas), [2], "a left page alone on the left")
        XCTAssertLessThan(try columns(canvas, 1)[0].frame.maxX, canvas.bounds.midX + 1)
    }

    /// A center page stands alone, centered on the whole spread.
    func testACenterPageStandsAlone() throws {
        let host = host(pages: 3, sides: [0: .center])
        XCTAssertEqual(shownSections(host.canvas), [0])
        XCTAssertEqual(try columns(host.canvas, 1)[0].frame.midX, host.canvas.bounds.midX, accuracy: 1)
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(shownSections(host.canvas), [1, 2])
    }

    /// Text before and after a run of pages flows in columns; turning reaches the pages' first
    /// spread from the text's last page, the text after them from their last, and back.
    func testPagesAndFlowingSectionsTurnIntoEachOther() throws {
        let host = host(pages: 4, flowing: [0, 3])
        let canvas = host.canvas
        XCTAssertFalse(canvas.showsFixedPages)
        while canvas.visibleRange?.start.section == 0 { XCTAssertEqual(canvas.turnPage(forward: true), .turned) }
        XCTAssertEqual(shownSections(canvas), [1, 2])
        XCTAssertTrue(canvas.showsFixedPages)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 3, offset: 0))
        XCTAssertFalse(canvas.showsFixedPages)
        XCTAssertEqual(canvas.textViews.count, 2, "the text's two columns")
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(shownSections(canvas), [1, 2])
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(canvas.visibleRange?.end, ReaderTextPosition(section: 0, offset: host.source.sections[0]!.length),
                       "the text's end")
    }

    /// Across a host's division (a fold or hinge) each page of a spread fills its side up to it.
    func testADivisionPutsAPageEitherSideOfIt() throws {
        var configuration = ReaderCanvasConfiguration()
        let hinge = CGRect(x: 540, y: 0, width: 34, height: 705)
        configuration.division = hinge
        let host = host(pages: 2, spread: .landscape, size: CGSize(width: 1114, height: 705), configuration: configuration)
        XCTAssertEqual(shownSections(host.canvas), [0, 1])
        let views = try columns(host.canvas, 2)
        XCTAssertEqual(views[0].frame.maxX, hinge.minX, accuracy: 1)
        XCTAssertEqual(views[1].frame.minX, hinge.maxX, accuracy: 1)
    }

    /// A page not built yet leaves its slot in the spread empty and is awaited; once it is
    /// built the spread shows both.
    func testAPageNotBuiltLeavesItsSlotEmptyUntilItIs() throws {
        let host = host(pages: 2)
        let built = host.source.sections[1]
        host.source.sections[1] = nil
        host.canvas.reloadContent(keeping: nil)
        XCTAssertEqual(shownSections(host.canvas), [0])
        XCTAssertTrue(host.canvas.awaitsSection(1))
        host.source.sections[1] = built
        host.canvas.reloadContent(keeping: nil)
        XCTAssertEqual(shownSections(host.canvas), [0, 1])
        XCTAssertFalse(host.canvas.awaitsSection(1))
    }

    /// A page is its image: a tap or click in an edge zone over it turns the page, where over an
    /// image in flowing text it is the image's. A tap in the middle is the image's too, and one
    /// on the margin around the page shows or hides the host's controls.
    func testAnEdgeOfAPageTurnsIt() throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.pageControls = EPUBPageControls(leftTapWidth: 200, rightTapWidth: 200)
        configuration.togglesControls = true
        let host = host(pages: 2, spread: .none, size: CGSize(width: 600, height: 700), configuration: configuration,
                        pageSize: CGSize(width: 1000, height: 600))
        let page = try XCTUnwrap(host.canvas.textViews.first)
        let left = CGPoint(x: page.frame.minX + 20, y: page.frame.midY), right = CGPoint(x: page.frame.maxX - 20, y: page.frame.midY)
        XCTAssertNotNil(page.image(at: host.canvas.convert(left, to: page)), "the point is on the page's image")
        XCTAssertEqual(host.canvas.edgeTurn(at: left), false)
        XCTAssertEqual(host.canvas.edgeTurn(at: right), true)
        XCTAssertFalse(host.canvas.togglesControls(at: CGPoint(x: page.frame.midX, y: page.frame.midY)))
        XCTAssertTrue(host.canvas.togglesControls(at: CGPoint(x: page.frame.midX, y: page.frame.maxY + 10)), "below the page")
    }

    /// With a page-turn animation (#688) a turn slides a spread of pages in as any other, and a
    /// swipe brings in the next spread, both its pages where the canvas shows them, never the
    /// other page of the spread on screen.
    func testASwipeBringsInTheNextSpreadOfPages() throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.pageTurnAnimation = .slide
        let host = host(pages: 6, configuration: configuration)
        let canvas = host.canvas
        XCTAssertEqual(shownSections(canvas), [0, 1])
        let width = canvas.bounds.width
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: -0.3 * width)
        let transition = try XCTUnwrap(canvas.pageTransition)
        XCTAssertEqual(transition.dragForward, true)
        XCTAssertEqual(transition.preview.map(\.placement.section), [2, 3], "the next spread's pages")
        let frames = transition.preview.map(\.frame)
        XCTAssertEqual(shownSections(canvas), [0, 1], "nothing is turned yet")
        canvas.dragPage(by: -0.6 * width)
        XCTAssertEqual(canvas.endPageDrag(turns: true, animated: true), .turned)
        XCTAssertEqual(shownSections(canvas), [2, 3])
        XCTAssertEqual(try columns(canvas, 2).map(\.frame), frames, "laid out where the canvas shows them")
        canvas.endPageTransition()
        XCTAssertTrue(canvas.beginPageDrag())
        canvas.dragPage(by: 0.3 * width)
        XCTAssertEqual(canvas.pageTransition?.preview.map(\.placement.section), [0, 1], "the spread before")
        XCTAssertEqual(canvas.endPageDrag(turns: false, animated: false), nil)
        canvas.endPageTransition()
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(canvas.pageTransition?.motion, .slide, "a turn slides the spread in")
        XCTAssertEqual(shownSections(canvas), [4, 5])
        canvas.endPageTransition()
    }

    /// Continuous scroll shows the pages one after another, each as large as the scroll's
    /// column and the visible height let it be.
    func testContinuousScrollShowsAScrollOfPages() throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        let host = host(pages: 3, size: CGSize(width: 600, height: 700), configuration: configuration)
        host.source.book = CanvasText.book(host.source.sections.map { $0! })
        host.canvas.reloadContent(keeping: nil)
        host.layOut()
        XCTAssertFalse(host.canvas.showsFixedPages)
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        let image = try XCTUnwrap(view.contentStorage.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? ReaderImageAttachment)
        let size = image.displaySize(ReaderAttachment.Line(width: view.readerContainer.size.width, viewport: view.readerContainer.viewportSize))
        XCTAssertLessThanOrEqual(size.height, view.readerContainer.viewportSize.height + 0.5)
        XCTAssertEqual(size.width / size.height, 600.0 / 800, accuracy: 0.01)
    }
}
