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
        XCTAssertEqual(saved.bookmark?.format, "epubcfi-v1")
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

    /// A stored foliate bookmark keeps resolving: the CFI names the same DOM position.
    func testFoliateBookmarkRestores() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        // `/6/4` is the second itemref; `/4/2/1:4` is four characters into the h1's text.
        let foliate = EPUBLocation(publicationID: session.publication.id, bookmark: EPUBEngineBookmark(
            engineID: "org.epubreaderlib.foliate", format: "epubcfi-v1", value: "epubcfi(/6/4!/4/2/1:4)"))
        try await session.send(.restore(foliate))
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
