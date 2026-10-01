import EPUBCore
import EPUBReading
import EPUBViewing
import EPUBViewingTestSupport
import EPUBTestSupport
import SwiftUI
import WebKit
import XCTest
@testable import EPUBViewing

@MainActor final class FoliateIntegrationTests: XCTestCase {
    private func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Reader did not reach the expected state")
    }
    func testMountedReaderNavigationSelectionRestoreAndClose() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        var events: [EPUBReaderEvent] = []
        var selected: EPUBSelection?
        let engine: any EPUBReaderEngine = FoliateEngine()
        let session = try engine.makeSession(publication: publication,
            selectionAction: EPUBSelectionAction(title: "Use passage") { selected = $0 }) { events.append($0) }
        let foliate = try XCTUnwrap(session as? FoliateSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { events.contains(.ready) }
        for invalid in ["", "#fragment", "https://example.invalid/", "../secret"] {
            do { try await session.send(.navigate(href: invalid)); XCTFail("Invalid href accepted") }
            catch { guard case .invalidCommand = error as? EPUBReaderError else { return XCTFail("Wrong error: \(error)") } }
        }
        let webView = try XCTUnwrap(foliate.model.webView)
        let rendered = try await webView.evaluateJavaScript("""
            document.querySelector('foliate-view').renderer.getContents().some(c => {
                const heading = c.doc.querySelector('h1');
                return heading?.getBoundingClientRect().height > 0 && c.doc.body.textContent.includes('Opening words');
            })
            """) as? Bool
        XCTAssertEqual(rendered, true, "Initial section must render visible text")
        try await session.send(.style(.init(fontSize: 23, isDark: true, flow: .scrolled)))
        try await session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait { foliate.model.location?.sectionIndex == 1 }
        try await session.send(.locate(text: "The unique destination passage lives here.", highlight: true))
        try await wait { foliate.model.selection?.text.contains("unique destination") == true }
        foliate.performSelection()
        XCTAssertTrue(selected?.text.contains("unique destination") == true)
        XCTAssertEqual(selected?.location.publicationID, publication.id)
        let overlay = try await webView.evaluateJavaScript("""
            document.querySelector('foliate-view').renderer.getContents().reduce((n,c) => n + (c.overlayer?.element?.children?.length ?? 0), 0)
            """) as? Int
        XCTAssertEqual(overlay, 0, "Locating a passage must remove search overlays")
        let saved = try XCTUnwrap(events.compactMap { event -> EPUBLocation? in
            if case .relocated(let location) = event { return location }; return nil
        }.last)
        try await session.send(.navigate(href: "OPS/one.xhtml#start"))
        try await wait { foliate.model.location?.sectionIndex == 0 }
        try await session.send(.restore(saved))
        try await wait { foliate.model.location?.sectionIndex == 1 }
        var incompatible = saved
        incompatible.bookmark?.engineID = "another-engine"
        do { try await session.send(.restore(incompatible)); XCTFail("Incompatible bookmark accepted") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation) }
        try await session.send(.locate(text: "Opening words are visible.", highlight: false))
        try await wait { foliate.model.location?.sectionIndex == 0 }
        let unselected = try await webView.evaluateJavaScript("""
            document.querySelector('foliate-view').renderer.getContents().every(c => !c.doc.getSelection() || c.doc.getSelection().isCollapsed)
            """) as? Bool
        XCTAssertEqual(unselected, true)
        let count = events.count
        session.close()
        foliate.model.apply(.failed(reason: "late callback"))
        do { try await session.send(.nextPage); XCTFail("Closed session accepted command") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .closed) }
        XCTAssertEqual(events.count, count)
    }
    func testScrolledEdgeFadeIsDrawnOnIOSOnly() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        var events: [EPUBReaderEvent] = []
        let session = try FoliateEngine().makeSession(publication: publication, selectionAction: nil) { events.append($0) }
        let foliate = try XCTUnwrap(session as? FoliateSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { events.contains(.ready) }
        try await session.send(.style(.init(flow: .scrolled)))
        let webView = try XCTUnwrap(foliate.model.webView)
        var state: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(20)
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            state = try await webView.evaluateJavaScript("""
                ({ scrolled: document.querySelector('foliate-view').renderer.scrolled === true,
                   marked: document.documentElement.classList.contains('sw-macos'),
                   strips: document.querySelectorAll('.sw-edge-fade').length })
                """) as? [String: Any] ?? [:]
        } while state["scrolled"] as? Bool != true && Date() < deadline
        XCTAssertEqual(state["scrolled"] as? Bool, true)
        #if os(macOS)
        XCTAssertEqual(state["marked"] as? Bool, true)
        XCTAssertEqual(state["strips"] as? Int, 0, "the Mac reader must not draw the scroll-edge fade")
        #else
        XCTAssertEqual(state["marked"] as? Bool, false)
        XCTAssertEqual(state["strips"] as? Int, 2, "iOS keeps the scroll-edge fade under floating chrome")
        #endif
    }
    func testNotReadyAndCancellationDoNotSubmit() async throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        let session = try FoliateEngine().makeSession(publication: book) { _ in XCTFail("Unmounted reader emitted") }
        defer { session.close() }
        do { try await session.send(.nextPage); XCTFail("Unmounted reader accepted command") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .notReady) }
        let task = Task { try await session.send(.nextPage) }
        task.cancel()
        do { try await task.value; XCTFail("Canceled command accepted") } catch is CancellationError {}
    }
    func testReusableEngineContract() async throws {
        do {
            try await EPUBEngineContract.verify(engine: FoliateEngine(),
                publication: EPUBPublication.open(data: Fixture.epub()),
                firstHref: "OPS/one.xhtml", secondHref: "OPS/two.xhtml", text: "Opening words are visible.") { session in
                    let window = ReaderTestWindow(session: session)
                    return { window.close() }
                }
        } catch let error as EPUBEngineContract.Failure {
            XCTFail(error.description)
        }
    }
}
