import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewingTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

/// The native engine end to end: a mounted session in a real window, driven only through the
/// public commands, observed through its events and its own visible range.
@MainActor final class NativeSessionTests: XCTestCase {
    private func wait(_ label: String = "the reader", timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func open(_ data: Data, action: EPUBSelectionAction? = nil)
        throws -> (NativeSession, ReaderTestWindow, () -> [EPUBReaderEvent]) {
        let publication = try EPUBPublication.open(data: data)
        var events: [EPUBReaderEvent] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: action) {
            events.append($0)
        } as? NativeSession)
        return (session, ReaderTestWindow(session: session), { events })
    }

    private func locations(_ events: [EPUBReaderEvent]) -> [EPUBLocation] {
        events.compactMap { if case .relocated(let location) = $0 { return location }; return nil }
    }

    func testReusableEngineContract() async throws {
        do {
            try await EPUBEngineContract.verify(engine: NativeEngine(),
                publication: EPUBPublication.open(data: Fixture.epub()),
                firstHref: "OPS/one.xhtml", secondHref: "OPS/two.xhtml", text: "Opening words are visible.") { session in
                    let window = ReaderTestWindow(session: session)
                    return { window.close() }
                }
        } catch let error as EPUBEngineContract.Failure {
            XCTFail(error.description)
        }
    }

    func testNotReadyAndCancellationDoNotSubmit() async throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        let session = try NativeEngine().makeSession(publication: book) { _ in XCTFail("Unmounted reader emitted") }
        defer { session.close() }
        do { try await session.send(.nextPage); XCTFail("Unmounted reader accepted command") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .notReady) }
        let task = Task { try await session.send(.nextPage) }
        task.cancel()
        do { try await task.value; XCTFail("Canceled command accepted") } catch is CancellationError {}
    }

    func testMountedReaderNavigationSelectionRestoreAndClose() async throws {
        var selected: EPUBSelection?
        let (session, window, events) = try open(Fixture.epub(), action: EPUBSelectionAction(title: "Use passage") { selected = $0 })
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        XCTAssertEqual(session.visibleRange?.start.section, 0)
        for invalid in ["", "#fragment", "https://example.invalid/", "../secret"] {
            do { try await session.send(.navigate(href: invalid)); XCTFail("Invalid href accepted: \(invalid)") }
            catch { guard case .invalidCommand = error as? EPUBReaderError else { return XCTFail("Wrong error: \(error)") } }
        }
        try await session.send(.style(.init(fontSize: 23, isDark: true, flow: .scrolled)))
        try await session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait("second section") { session.visibleRange?.start.section == 1 }
        try await session.send(.locate(text: "The unique  destination passage lives here.", highlight: true))
        try await wait("selection") { session.selection?.text.contains("unique destination") == true }
        let selection = try XCTUnwrap(events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        XCTAssertEqual(selection.text, "The unique destination passage lives here.")
        XCTAssertEqual(selection.location.bookmark?.engineID, EPUBReader.identifier)
        canvasRequestsSelectionAction(session)
        XCTAssertEqual(selected?.text, selection.text)
        XCTAssertEqual(selected?.location.publicationID, session.publication.id)

        let saved = try XCTUnwrap(locations(events()).last)
        XCTAssertEqual(saved.href, "OPS/two.xhtml")
        XCTAssertEqual(saved.bookmark?.format, EPUBReader.bookmarkFormat)
        try await session.send(.navigate(href: "OPS/one.xhtml#start"))
        try await wait("first section") { session.visibleRange?.start.section == 0 }
        try await session.send(.restore(saved))
        try await wait("restored section") { session.visibleRange?.start.section == 1 }
        var incompatible = saved
        incompatible.bookmark?.engineID = "another-engine"
        do { try await session.send(.restore(incompatible)); XCTFail("Incompatible bookmark accepted") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation) }

        try await session.send(.locate(text: "Opening words are visible.", highlight: false))
        try await wait("located first section") { session.visibleRange?.start.section == 0 }
        let before = events().count
        try await session.send(.locate(text: "Nothing like this sentence is in the book.", highlight: false))
        try await wait("a miss") { events().dropFirst(before).contains(.notice(NativeSession.passageNotFound)) }

        let count = events().count
        session.close()
        do { try await session.send(.nextPage); XCTFail("Closed session accepted command") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .closed) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events().count, count)
    }

    /// Bookmarks carry EPUBLib's own identity. A CFI the WebKit reader recorded still names the
    /// same position once a host re-tags it; under the old tag it is another engine's bookmark.
    func testBookmarksCarryEPUBLibsIdentityAndForeignTagsAreRefused() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        XCTAssertEqual(EPUBReader.identifier, "org.epublib.reader")
        XCTAssertEqual(EPUBReader.bookmarkFormat, "epublib-cfi-v1")
        // `/6/4` is the second itemref; `/4/2/1:4` is four characters into the h1's text.
        let recorded = "epubcfi(/6/4!/4/2/1:4)"
        let legacy = EPUBLocation(publicationID: session.publication.id, bookmark: EPUBEngineBookmark(
            engineID: "org.epubreaderlib.foliate", format: "epubcfi-v1", value: recorded))
        do { try await session.send(.restore(legacy)); XCTFail("A foliate-tagged bookmark was accepted") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation) }
        let retagged = EPUBLocation(publicationID: session.publication.id, bookmark: EPUBEngineBookmark(
            engineID: EPUBReader.identifier, format: EPUBReader.bookmarkFormat, value: recorded))
        try await session.send(.restore(retagged))
        try await wait("restored section") { session.visibleRange?.start.section == 1 }
    }

    func testScriptsAreDisclosedAndNeverRun() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/one.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>One</title><script>document.title='ran'</script></head>"
                + "<body><h1 id=\"start\">One</h1><p>Opening words are visible.</p><script src=\"x.js\"></script></body></html>",
        ]))
        defer { session.close(); window.close() }
        try await wait("disclosure") {
            events().contains { if case .disclosure(let text) = $0 { return text.contains("interactive") }; return false }
        }
        XCTAssertFalse(session.book.section(0)?.string.string.contains("ran") ?? true)
    }

    func testSearchAndHostHighlightsAreDrawnAndCleared() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.searchHighlight(text: "ORDINARY reading"))
        try await wait("search highlights") { session.drawnHighlights.filter { $0.kind == .search }.count == 100 }
        let match = try XCTUnwrap(session.drawnHighlights.first)
        let text = try XCTUnwrap(session.book.section(match.range.start.section)?.string.string as NSString?)
        XCTAssertEqual(text.substring(with: NSRange(location: match.range.start.offset, length: match.range.end.offset - match.range.start.offset)),
                       "ordinary reading")
        try await session.send(.clearSearch)
        XCTAssertTrue(session.drawnHighlights.isEmpty)

        try await session.send(.locate(text: "The unique destination passage lives here.", highlight: true))
        try await wait("selection") { session.selection != nil }
        let selected = try XCTUnwrap(events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        try await session.send(.setHighlights([EPUBHighlight(id: "note-1", location: selected.location)]))
        try await wait("host highlight") { session.drawnHighlights.contains { $0.id == "note-1" && $0.kind == .annotation } }
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "note-1" }?.range, session.selection?.range)
        var foreign = selected.location
        foreign.publicationID = "another-book"
        let before = events().count
        try await session.send(.setHighlights([EPUBHighlight(id: "foreign", location: foreign)]))
        XCTAssertTrue(session.drawnHighlights.isEmpty)
        XCTAssertTrue(events().dropFirst(before).contains { if case .notice = $0 { return true }; return false })
    }

    private func chapter(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body>\(body)</body></html>"
    }

    func testQuickTypographyChangesLeaveEverySectionAtTheLastSize() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.style(.init(fontSize: 20)))
        try await session.send(.style(.init(fontSize: 30)))
        try await wait("rebuilt book") { session.book.isComplete && session.book.typography.fontSize == 30 }
        for index in 0..<session.book.count {
            let section = try XCTUnwrap(session.book.section(index))
            var sizes = Set<CGFloat>()
            section.string.enumerateAttribute(.font, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
                if let font = value as? PlatformFont { sizes.insert(font.pointSize) }
            }
            XCTAssertFalse(sizes.contains(20), "section \(index) kept a 20-pt build: \(sizes)")
        }
    }

    func testLocateInsideATableSelectsTheTable() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/two.xhtml": chapter("<p>Before.</p><table><tr><td>Alpha cell</td><td>Beta cell</td></tr><tr><td>1</td><td>2</td></tr></table><p>After the table.</p>"),
        ]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.locate(text: "Beta cell", highlight: true))
        try await wait("selection") { session.selection != nil }
        let selection = try XCTUnwrap(session.selection)
        XCTAssertEqual(selection.range.start.section, 1)
        XCTAssertFalse(selection.range.isEmpty, "the table unit is selected, not an empty range after it")
    }

    func testARangeEndingWithAnImageResolvesToTheSameRange() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/one.xhtml": chapter("<p>Alpha <img src=\"pic.png\" alt=\"a picture\"/></p><p>Next.</p>"),
            "OPS/pic.png": "not really a png",
        ]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let section = try XCTUnwrap(session.book.section(0))
        let end = (section.string.string as NSString).range(of: "\n").location
        XCTAssertGreaterThan(end, 6)
        let range = ReaderTextRange(section: 0, 0..<end)
        session.canvas(try XCTUnwrap(session.canvas), didChangeSelection: ReaderSelection(range: range, text: ""))
        let selected = try XCTUnwrap(events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        try await session.send(.setHighlights([EPUBHighlight(id: "h", location: selected.location)]))
        try await wait("highlight") { session.drawnHighlights.contains { $0.id == "h" } }
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "h" }?.range, range)
    }

    func testABareSectionBookmarkRestoresToThatSection() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: ["OPS/two.xhtml": chapter("")]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let before = events().count
        try await session.send(.restore(EPUBLocation(publicationID: session.publication.id, bookmark: EPUBEngineBookmark(
            engineID: EPUBReader.identifier, format: EPUBReader.bookmarkFormat, value: "epubcfi(/6/4)"))))
        try await wait("restored section") { session.visibleRange?.start.section == 1 }
        XCTAssertFalse(events().dropFirst(before).contains { if case .notice = $0 { return true }; return false })
    }

    func testPassageTextLeavesOutGeneratedQuotes() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/one.xhtml": chapter("<p>She said <q>hello there</q> and left.</p>"),
        ]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.locate(text: "She said hello there and left.", highlight: true))
        try await wait("selection") { session.selection != nil }
        XCTAssertEqual(session.selection?.text, "She said hello there and left.")
    }

    func testTheWholeBookLeavesOutNonlinearSections() async throws {
        let package = String(decoding: try XCTUnwrap(Fixture.files()["OPS/book.opf"]), as: UTF8.self)
            .replacingOccurrences(of: "<itemref idref=\"two\"/>", with: "<itemref idref=\"two\" linear=\"no\"/>")
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": package]))
        XCTAssertFalse(publication.spine[1].isLinear)
        let book = NativeBook(publication: publication, typography: NativeTypography(), rich: NativeRichContent())
        defer { book.close() }
        for index in publication.spine.indices { _ = await book.build(index) }
        let text = try XCTUnwrap(book.bookText)
        XCTAssertTrue(text.contains(section: 0))
        XCTAssertFalse(text.contains(section: 1))
        XCTAssertEqual(text.string.length, book.section(0)?.string.length)
    }

    func testARemountedReaderShowsItsPlaceAgain() async throws {
        let (session, window, events) = try open(Fixture.epub())
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait("second section") { session.visibleRange?.start.section == 1 }
        window.close()
        let again = ReaderTestWindow(session: session)
        defer { session.close(); again.close() }
        try await wait("remounted canvas") { session.canvas?.visibleRange?.start.section == 1 }
        XCTAssertEqual(events().filter { $0 == .ready }.count, 1)
    }

    // MARK: - Opening position

    /// The first location a freshly opened book reports, once the reader is ready.
    private func openingLocation(_ data: Data) async throws -> (NativeSession, EPUBLocation) {
        let (session, window, events) = try open(data)
        addTeardownBlock { @MainActor in session.close(); window.close() }
        try await wait("first location") { !locations(events()).isEmpty }
        XCTAssertEqual(events().first, .ready)
        return (session, try XCTUnwrap(locations(events()).first))
    }

    /// With nothing restored, a book opens at its text start, as foliate-js's `showTextStart` did:
    /// a Standard Ebooks title on its first chapter, not its cover or titlepage.
    func testABookOpensAtItsBodymatterLandmark() async throws {
        let (session, first) = try await openingLocation(Fixture.frontMatter())
        XCTAssertEqual(first.href, "OPS/text/chapter-1.xhtml")
        XCTAssertEqual(first.title, "Chapter 1")
        // `/6/6` is the third itemref.
        XCTAssertTrue(first.bookmark?.value.hasPrefix("epubcfi(/6/6!") == true, first.bookmark?.value ?? "no bookmark")
        XCTAssertEqual(session.visibleRange?.start, ReaderTextPosition(section: 2, offset: 0))
        // The front matter is still a page turn away.
        try await session.send(.previousPage)
        try await wait("titlepage") { session.visibleRange?.start.section == 1 }
    }

    func testAnEPUB2BookOpensAtItsGuideTextReference() async throws {
        let (session, first) = try await openingLocation(Fixture.frontMatter(bodymatter: nil, text: "text/chapter-1.xhtml", epub2: true))
        XCTAssertEqual(first.href, "OPS/text/chapter-1.xhtml")
        XCTAssertEqual(session.visibleRange?.start.section, 2)
    }

    func testABookWithoutLandmarksOpensAtItsFirstLinearSection() async throws {
        let (session, first) = try await openingLocation(Fixture.frontMatter(bodymatter: nil))
        XCTAssertEqual(first.href, "OPS/text/cover.xhtml")
        XCTAssertEqual(session.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
    }

    /// A fragment resolves as `.navigate(href:)` resolves one: the page holding its anchor.
    func testATextStartFragmentOpensOnTheAnchorsPage() async throws {
        let (session, first) = try await openingLocation(Fixture.frontMatter(bodymatter: "text/chapter-1.xhtml#deep"))
        XCTAssertEqual(first.href, "OPS/text/chapter-1.xhtml")
        let anchor = ReaderTextPosition(section: 2, offset: try XCTUnwrap(session.book.section(2)?.anchors["deep"]))
        let visible = try XCTUnwrap(session.visibleRange)
        XCTAssertGreaterThan(visible.start.offset, 0, "the anchor is pages into its section")
        XCTAssertTrue(visible.start <= anchor && anchor < visible.end, "\(anchor) is not in \(visible)")
    }

    /// A text start that names no section of the book falls back to the first linear section.
    func testATextStartThatDoesNotResolveFallsBackToTheFirstLinearSection() throws {
        for href in ["text/missing.xhtml#chapter-1", "nav.xhtml", "toc.ncx"] {
            let publication = try EPUBPublication.open(data: Fixture.frontMatter(bodymatter: href))
            XCTAssertEqual(publication.landmarks.last?.types.first, "bodymatter", "\(href) is a landmark")
            let target = NativeSession.openingTarget(of: publication)
            XCTAssertEqual(target.section, 0, href)
            XCTAssertNil(target.fragment, href)
        }
        let package = String(decoding: try XCTUnwrap(Fixture.files()["OPS/book.opf"]), as: UTF8.self)
            .replacingOccurrences(of: "<itemref idref=\"one\"/>", with: "<itemref idref=\"one\" linear=\"no\"/>")
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": package]))
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 1, "the first linear section")
    }

    /// A host restores a saved position as soon as the reader is ready. The text start shows
    /// first, then the restored position replaces it and stays.
    func testARestoreOnReadyWinsOverTheTextStart() async throws {
        let publication = try EPUBPublication.open(data: Fixture.frontMatter())
        // `/6/4` is the titlepage, before the text start; `/4/2/1:4` is four characters into its h1.
        let saved = EPUBLocation(publicationID: publication.id, bookmark: EPUBEngineBookmark(
            engineID: EPUBReader.identifier, format: EPUBReader.bookmarkFormat, value: "epubcfi(/6/4!/4/2/1:4)"))
        @MainActor final class Reader { var session: NativeSession? }
        let reader = Reader()
        var events: [EPUBReaderEvent] = []
        let made = try NativeEngine().makeSession(publication: publication, selectionAction: nil) { event in
            events.append(event)
            guard event == .ready, let session = reader.session else { return }
            Task {
                do { try await session.send(.restore(saved)) } catch { XCTFail("Restore refused: \(error)") }
            }
        }
        let session = try XCTUnwrap(made as? NativeSession)
        reader.session = session
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("restored position") { locations(events).last?.href == "OPS/text/titlepage.xhtml" }
        try await wait("whole book") { session.book.isComplete }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(locations(events).first?.href, "OPS/text/chapter-1.xhtml")
        XCTAssertEqual(locations(events).last?.href, "OPS/text/titlepage.xhtml")
        XCTAssertEqual(session.visibleRange?.start.section, 1)
        XCTAssertFalse(events.contains { if case .notice = $0 { return true }; return false })
    }

    private func canvasRequestsSelectionAction(_ session: NativeSession) {
        session.canvasDidRequestSelectionAction(try! XCTUnwrap(session.canvas))
    }

    private func exercise(_ kind: Fixture.Rendering) async throws {
        let data = try await Task.detached { try Fixture.rendering(kind) }.value
        let (session, window, events) = try open(data)
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let publication = session.publication
        switch kind {
        case .escapedHref:
            XCTAssertEqual(publication.spine[0].resource.href, "OPS/chapter%20%23100%25%3F.xhtml")
            let toc = try XCTUnwrap(publication.tableOfContents.first?.href)
            try await session.send(.navigate(href: toc))
            try await wait("fragment") { session.visibleRange?.start.section == 0 }
        case .fixedLayout:
            XCTAssertEqual(publication.spine[0].layout, .prePaginated)
            try await wait("fixed-layout disclosure") {
                events().contains { if case .disclosure(let text) = $0 { return text.contains("fixed page layout") }; return false }
            }
            try await session.send(.style(.init(fontSize: 22)))
        case .rightToLeft:
            XCTAssertEqual(publication.pageProgression, .rtl)
            XCTAssertEqual(session.canvas?.configuration.isRightToLeft, true)
        case .vertical:
            try await wait("vertical disclosure") {
                events().contains { if case .disclosure(let text) = $0 { return text.contains("Vertical") }; return false }
            }
        case .largeIllustrated:
            XCTAssertEqual(publication.spine.count, 40)
            XCTAssertGreaterThan(data.count, 20 * 1024 * 1024)
        }
        try await wait("first location") { locations(events()).last?.href == publication.spine[0].resource.href }
        let href = try XCTUnwrap(locations(events()).last?.href)
        try await session.send(.navigate(href: publication.spine.last!.resource.href))
        try await wait("last section") { session.visibleRange?.start.section == publication.spine.count - 1 }
        try await session.send(.navigate(href: href))
        try await wait("first section again") { session.visibleRange?.start.section == 0 }
        XCTAssertEqual(events().filter { $0 == .ready }.count, 1)
        XCTAssertFalse(events().contains { if case .failed = $0 { return true }; return false })
    }

    func testEncodedHrefRoundTrip() async throws { try await exercise(.escapedHref) }
    func testFixedLayoutReflows() async throws { try await exercise(.fixedLayout) }
    func testRightToLeft() async throws { try await exercise(.rightToLeft) }
    func testVerticalWriting() async throws { try await exercise(.vertical) }
    func testLargeIllustratedBook() async throws { try await exercise(.largeIllustrated) }
}
