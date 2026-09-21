#if !os(macOS)
import EPUBReaderLib
import EPUBReaderTesting
import EPUBTestSupport
import SwiftUI
import WebKit
import XCTest
@testable import EPUBReaderFoliate

/// Swiping past the end of a scrolled-flow section advances into the next one
/// (`bootstrap.js`'s touch boundary listener; vocaro/studywright#74).
///
/// **Two separate defects, one gesture, and this drives both at once.** A section shorter than
/// the viewport is sized to its own content in scrolled flow, so the page around it belongs to
/// the *host* document and a touch there never reached a listener attached only to the section's
/// document — so the flick here is dispatched on `document`. And WebKit can deliver as few as one
/// `touchmove` — sometimes none — before `touchend` for a quick flick, so a rule that judged only
/// individual moves missed swipes whose travel shows up at the end — so the flick here carries
/// **no `touchmove` at all**. Either defect alone loses the turn.
///
/// **A deliberately short book.** The shared fixture's chapters carry fifty paragraphs each and
/// render about 2426 pt into a 778 pt viewport, where native scrolling still has content to show
/// and the listener is right to ignore a drag. #74's actual shape is the opposite — a section
/// shorter than the viewport, which the renderer reports as pinned at both edges at once — so
/// this overrides both chapters with one short paragraph.
///
/// iOS only. `TouchEvent`/`Touch` are not constructible in macOS WebKit, and the Mac host turns
/// pages with the wheel listener, which has its own coverage.
@MainActor final class ScrolledSwipeTurnTests: XCTestCase {

    private func wait(
        _ description: String, until condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(20)
        while try await !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(description)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testAFlickWithNoTouchMoveAdvancesTheSectionFromTheHostPage() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: [
            "OPS/one.xhtml": Self.shortChapter("First Chapter", "Opening words are visible."),
            "OPS/two.xhtml": Self.shortChapter(
                "Second Chapter", "The unique destination passage lives here."),
        ]))
        var events: [EPUBReaderEvent] = []
        let session = try FoliateEngine().makeSession(
            publication: publication, selectionAction: nil) { events.append($0) }
        let foliate = try XCTUnwrap(session as? FoliateSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }

        try await wait("the reader is ready") { events.contains(.ready) }
        try await session.send(.style(.init(flow: .scrolled)))
        let webView = try XCTUnwrap(foliate.model.webView)
        try await wait("the renderer is scrolled") {
            try await webView.evaluateJavaScript(
                "document.querySelector('foliate-view').renderer.scrolled === true") as? Bool == true
        }

        // The section is shorter than the viewport, so the renderer reports itself pinned at
        // both edges at once and nothing native is left to scroll — the state in which a push
        // forward can only mean the next section.
        let geometry = try await webView.evaluateJavaScript("""
            (() => {
                const { start, size, viewSize } = document.querySelector('foliate-view').renderer
                return { start, size, viewSize }
            })()
            """) as? [String: Any] ?? [:]
        let size = geometry["size"] as? Double ?? -1
        let viewSize = geometry["viewSize"] as? Double ?? -1
        XCTAssertLessThan(
            viewSize, size,
            "the overridden chapter is not shorter than the viewport, so this no longer "
                + "exercises #74's shape (size \(size), viewSize \(viewSize))")
        try await require(atEnd(in: webView), "the short section is not pinned at its end")

        let before = try await sectionIndex(in: webView)
        try await flick(in: webView)
        try await wait("the section advanced") { try await sectionIndex(in: webView) > before }

        let after = try await sectionIndex(in: webView)
        XCTAssertEqual(
            after, before + 1,
            "one flick turned \(after - before) sections; it must advance exactly one")
    }

    /// A chapter with one short paragraph: far shorter than any test viewport.
    private static func shortChapter(_ title: String, _ sentence: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(title)</title></head>"
            + "<body><h1 id=\"start\">\(title)</h1><p>\(sentence)</p></body></html>"
    }

    private func require(_ condition: Bool, _ message: String) throws {
        _ = try XCTUnwrap(condition ? true : nil, message)
    }

    /// The index of the section currently rendered.
    private func sectionIndex(in webView: WKWebView) async throws -> Int {
        let value = try await webView.evaluateJavaScript("""
            (() => {
                const contents = document.querySelector('foliate-view').renderer.getContents()
                return contents.length ? contents[0].index : -1
            })()
            """)
        return value as? Int ?? -1
    }

    /// Whether the renderer is pinned at its end, by `bootstrap.js`'s own rule
    /// (`rendererBoundary`: `start + size >= viewSize - 2`).
    private func atEnd(in webView: WKWebView) async throws -> Bool {
        try await webView.evaluateJavaScript("""
            (() => {
                const { start, size, viewSize } = document.querySelector('foliate-view').renderer
                return viewSize > 0 && start + size >= viewSize - 2
            })()
            """) as? Bool == true
    }

    /// One upward flick on the host page: touch down, then straight to touch up 200 pt higher,
    /// with **no `touchmove` in between**. Dispatched on `document` rather than on the section's
    /// own document, which is what a touch on the page around a short section reaches.
    private func flick(in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript("""
            (() => {
                const send = (type, clientY, ended) => {
                    const touch = new Touch({
                        identifier: 1, target: document.body, clientX: 40, clientY })
                    const points = ended ? [] : [touch]
                    document.dispatchEvent(new TouchEvent(type, {
                        bubbles: true, cancelable: true,
                        touches: points, targetTouches: points, changedTouches: [touch] }))
                }
                send('touchstart', 600, false)
                send('touchend', 400, true)
                return true
            })()
            """)
    }
}
#endif
