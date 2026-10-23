import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewingTestSupport
import XCTest
@testable import EPUBViewing

/// A mounted reader over fixed-layout pages ([#5](https://github.com/vocaro/EPUBLib/issues/5)):
/// what the host is told, page turns, positions that restore to their page, search in a page's
/// drawing, and the engine contract.
@MainActor final class FixedLayoutSessionTests: XCTestCase {
    typealias Book = Fixture.SpecBook

    private func mount(_ book: Book) throws -> SpecConformanceReader {
        let reader = try SpecConformanceReader(book)
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    /// A book of pages of every shape opens with nothing disclosed for its layout, keeps every
    /// capability, and turns page by page through each.
    func testABookOfPagesDisclosesNothingAndTurnsThroughEveryPage() async throws {
        let reader = try mount(FixedLayoutPageTests.pages())
        try await reader.waitUntilReady()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(reader.disclosures.contains { $0.contains("fixed page layout") }, "\(reader.disclosures)")
        XCTAssertTrue(reader.session.capabilities.isSuperset(of: [.pagination, .scrolling, .bookmarks, .search, .highlights]))
        XCTAssertEqual(reader.session.book.count, 4)
        XCTAssertTrue((0..<4).allSatisfy { reader.session.book.section($0)?.fixedPage != nil })
        let visited = try await reader.pageThrough()
        XCTAssertEqual(visited, [0, 1, 2, 3])
        XCTAssertTrue(reader.session.canvas?.showsFixedPages == true)
    }

    /// `Fixture.rendering(.fixedLayout)` has two pages of positioned text, which reflow and are
    /// disclosed, and a page of each shape that is shown whole.
    func testTheRenderingFixtureReflowsItsTextPagesAndShowsItsOthersWhole() throws {
        let build = try SpecConformanceBuild(archive: Fixture.rendering(.fixedLayout))
        XCTAssertEqual(build.publication.spine.map(\.layout), Array(repeating: .prePaginated, count: 6))
        XCTAssertEqual(build.sections.map { $0.fixedPage?.size }, [nil, nil, CGSize(width: 600, height: 800), CGSize(width: 600, height: 800),
                                                                  CGSize(width: 600, height: 800), CGSize(width: 1000, height: 600)])
        XCTAssertEqual(build.sections.map(\.report.fixedLayoutReflowed), [true, true, false, false, false, false])
        XCTAssertTrue(build.disclosure?.hasPrefix("This book's fixed page layout is shown as reflowable text.") == true,
                      build.disclosure ?? "no disclosure")
        XCTAssertEqual(build.specAlternatives.dropFirst(2), ["A plate of the fixed-layout fixture", "A drawn page", "An SVG page", ""])
    }

    /// Every page's location carries a CFI into its document, or for a raster image in the
    /// spine the spine item's own CFI, and restoring it shows that page again.
    func testEveryPagesLocationRestoresToThatPage() async throws {
        let reader = try mount(FixedLayoutPageTests.pages())
        try await reader.waitUntilReady()
        let session = reader.session
        var saved: [EPUBLocation] = []
        for index in 0..<4 {
            let href = session.publication.spine[index].resource.href
            try await session.send(.navigate(href: href))
            try await reader.wait("page \(index)") { session.visibleRange?.start.section == index && session.lastLocation?.href == href }
            let location = try XCTUnwrap(session.lastLocation)
            let bookmark = try XCTUnwrap(location.bookmark, "page \(index)")
            XCTAssertEqual(bookmark.engineID, NativeEngine.identifier)
            XCTAssertTrue(bookmark.value.hasPrefix("epubcfi("), bookmark.value)
            saved.append(location)
        }
        XCTAssertTrue(saved[0].bookmark!.value.contains("!"), "a CFI into the XHTML page's document: \(saved[0].bookmark!.value)")
        XCTAssertTrue(saved[2].bookmark!.value.contains("!"), "a CFI into the SVG document: \(saved[2].bookmark!.value)")
        XCTAssertFalse(saved[3].bookmark!.value.contains("!"), "the raster page's spine item: \(saved[3].bookmark!.value)")
        for (index, location) in saved.enumerated().reversed() {
            try await session.send(.navigate(href: session.publication.spine[index == 0 ? 3 : 0].resource.href))
            try await reader.wait("away from \(index)") { session.visibleRange?.start.section != index }
            try await session.send(.restore(location))
            try await reader.wait("restored \(index)") { session.visibleRange?.start.section == index }
            XCTAssertEqual(session.lastLocation?.bookmark, location.bookmark, "page \(index)")
        }
        XCTAssertTrue(reader.notices.isEmpty, "\(reader.notices)")
    }

    /// In a landscape window two pages share a spread: the location carries a CFI for each,
    /// and restoring it shows the same spread.
    func testASpreadsLocationCarriesBothPagesAndRestores() async throws {
        let reader = try mount(FixedLayoutPageTests.pages())
        reader.window.resize(to: CGSize(width: 1100, height: 800))
        try await reader.waitUntilReady()
        let session = reader.session
        try await reader.wait("a spread") { session.visibleRange?.end.section == 1 }
        let spread = try XCTUnwrap(session.lastLocation)
        XCTAssertEqual(spread.rangeBookmarks?.count, 2)
        try await session.send(.nextPage)
        try await reader.wait("the next spread") { session.visibleRange?.start.section == 2 && session.visibleRange?.end.section == 3 }
        try await session.send(.restore(spread))
        try await reader.wait("the first spread again") { session.visibleRange?.start.section == 0 && session.visibleRange?.end.section == 1 }
    }

    /// Search finds the words a page's drawing holds, in an XHTML page's SVG and in an SVG
    /// document, and shows the page.
    func testSearchFindsTheWordsOfAPagesDrawing() async throws {
        let reader = try mount(FixedLayoutPageTests.pages())
        try await reader.waitUntilReady()
        let session = reader.session
        try await session.send(.search(text: "SVG page words"))
        try await reader.wait("the SVG page found") { session.searchResults?.results.count == 1 && session.visibleRange?.start.section == 2 }
        XCTAssertEqual(session.searchResults?.results.first?.spineIndex, 2)
        try await session.send(.search(text: "words"))
        try await reader.wait("both drawings found") { session.searchResults?.results.map(\.spineIndex) == [1, 2] }
    }

    /// The engine contract holds for a session over fixed-layout pages.
    func testTheEngineContractHoldsForFixedLayoutPages() async throws {
        let publication = try EPUBPublication.open(data: FixedLayoutPageTests.pages().archive())
        do {
            try await EPUBEngineContract.verify(engine: NativeEngine(), publication: publication,
                firstHref: publication.spine[1].resource.href, secondHref: publication.spine[2].resource.href, text: "words") { session in
                    let window = ReaderTestWindow(session: session)
                    return { window.close() }
                }
        } catch let error as EPUBEngineContract.Failure {
            XCTFail(error.description)
        }
    }
}
