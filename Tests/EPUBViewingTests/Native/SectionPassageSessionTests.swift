import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewingTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Public selection, saved quotes, native Copy and location restoration must use authored
/// characters while the native renderer retains its flow boxes and substituted glyphs.
@MainActor final class SectionPassageSessionTests: XCTestCase {
    private func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAuthoredPassagesSurviveSelectionNativeCopyLocateAndSavedCFIsInBothFlows() async throws {
        let chapter = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Passages</title><style>
            .cap { float: left; font-size: 3em; line-height: 1 }
            .box { display: inline-block; width: 60px }
            .sc { font-family: Georgia; font-variant: small-caps }
            .up { text-transform: uppercase }
            </style></head><body><p><span class="cap">D</span>rop caps open the chapter.</p>
            <p>Before <span class="box">callout</span> after.</p>
            <pre>let a = 1\n  b()\n</pre><p><span class="sc">It was Straße.</span></p>
            <p>A <span class="up">straße</span> end.</p></body></html>
            """
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter]))
        var events: [EPUBReaderEvent] = [], used: EPUBSelection?
        let action = EPUBSelectionAction(title: "Use passage") { used = $0 }
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: action) {
            events.append($0)
        } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("ready and built") { session.isReady && session.book.isComplete }
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            try await session.send(.style(.init(fontSize: 20, flow: flow)))
            try await wait("rebuilt") { session.book.isComplete }
            for expected in ["Drop caps open the chapter.", "Before callout after.", "let a = 1\n  b()", "It was Straße.", "A straße end."] {
                try await session.send(.locate(text: expected, highlight: true))
                try await wait("authored selection") { session.selection?.text == expected && session.canvas?.currentSelection?.text == expected }
                let selection = try XCTUnwrap(events.compactMap { event -> EPUBSelection? in
                    if case .selectionChanged(let value) = event { return value }; return nil
                }.last)
                XCTAssertEqual(selection.text, expected)
                XCTAssertEqual(selection.location.quote, expected)
                let canvas = try XCTUnwrap(session.canvas)
                session.canvasDidRequestSelectionAction(canvas)
                XCTAssertEqual(used, selection)
                let range = try XCTUnwrap(session.selection?.range)
                let views = canvas.textViews.filter { canvas.localRange(of: range, in: $0) != nil }
                XCTAssertFalse(views.isEmpty)
                for view in views {
                    XCTAssertEqual(canvas.selectionText(for: view), expected)
                    #if os(macOS)
                    let pasteboard = NSPasteboard.withUniqueName()
                    XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
                    XCTAssertEqual(pasteboard.string(forType: .string), expected)
                    pasteboard.releaseGlobally()
                    #else
                    view.pasteboard = UIPasteboard.withUniqueName()
                    view.copy(nil)
                    XCTAssertEqual(view.pasteboard.string, expected)
                    #endif
                }
                let saved = selection.location
                try await session.send(.setHighlights([EPUBHighlight(id: "authored", location: saved)]))
                let highlight = try XCTUnwrap(session.drawnHighlights.first { $0.id == "authored" })
                XCTAssertEqual(highlight.range, range)
                let text = try XCTUnwrap(session.book.section(0))
                XCTAssertEqual(text.mappedText(in: highlight.range.start.offset..<highlight.range.end.offset), expected)
                try await session.send(.navigate(href: "OPS/two.xhtml"))
                try await session.send(.restore(saved))
                XCTAssertEqual(session.visibleRange?.start.section, 0)
                // A saved authored quote remains a valid .locate input after its CFI restoration.
                try await session.send(.locate(text: try XCTUnwrap(saved.quote), highlight: true))
                try await wait("relocated authored passage") { session.selection?.text == expected }
            }
        }
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false })
    }

    func testNativeCopyOfAnExpandedGraphemeUsesAuthoredTextBeforeSelectionDebounce() async throws {
        let chapter = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Copy</title>
            <style>.up { text-transform: uppercase }</style></head><body><p>A <span class="up">straße</span> end.</p></body></html>
            """
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter]))
        var used: EPUBSelection?
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication,
            selectionAction: EPUBSelectionAction(title: "Use passage") { used = $0 }, onEvent: { _ in }) as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("ready and built") { session.isReady && session.book.isComplete }
        let text = try XCTUnwrap(session.book.section(0))
        let ss = (text.string.string as NSString).range(of: "SS")
        XCTAssertNotEqual(ss.location, NSNotFound)
        let range = ReaderTextRange(section: 0, ss.location..<NSMaxRange(ss))
        let canvas = try XCTUnwrap(session.canvas)
        canvas.show(range.start, selecting: nil)
        let view = try XCTUnwrap(canvas.textViews.first { canvas.localRange(of: range, in: $0) != nil })
        view.selectedRange = try XCTUnwrap(canvas.localRange(of: range, in: view))
        // Copy can be requested immediately, before the canvas or session has received the
        // native selection delegate callback. It still resolves through the authored map.
        XCTAssertEqual(canvas.selectionText(for: view), "ß")
        #if os(macOS)
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), "ß")
        pasteboard.releaseGlobally()
        #else
        view.pasteboard = UIPasteboard.withUniqueName()
        view.copy(nil)
        XCTAssertEqual(view.pasteboard.string, "ß")
        #endif
        canvas.textViewSelectionDidChange(view)
        try await wait("authored native selection") { session.selection?.text == "ß" && canvas.currentSelection?.text == "ß" }
        canvas.performSelectionAction()
        XCTAssertEqual(used?.text, "ß")
        XCTAssertEqual(used?.location.quote, "ß")
        try await session.send(.setHighlights([EPUBHighlight(id: "native", location: try XCTUnwrap(used?.location))]))
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "native" }?.range, range)
    }

    @MainActor private final class OptionalPassageSource: ReaderCanvasDataSource {
        let text = CanvasText.body("Rendered body")
        var passage: String?
        var sectionCount: Int { 1 }
        func text(forSection index: Int) -> NSAttributedString? { text }
        func selectionText(in range: ReaderTextRange) -> String? { passage }
        func isLinear(section index: Int) -> Bool { true }
        var bookText: ReaderBookText? { nil }
    }

    func testUnavailableCellPassageFallsBackButExplicitEmptyPassageDoesNot() throws {
        let source = OptionalPassageSource()
        let host = CanvasHost(FakeCanvasSource([source.text]))
        defer { host.close() }
        host.canvas.dataSource = source
        let owner = NSObject()
        let range = ReaderTextRange(
            start: ReaderTextPosition(section: 0, offset: 0, tableCell: ReaderTablePosition(table: 0, cell: 0, offset: 1)),
            end: ReaderTextPosition(section: 0, offset: 0, tableCell: ReaderTablePosition(table: 0, cell: 0, offset: 3)))
        let selected = ReaderSelection(range: range, text: "cell text")
        source.passage = nil
        host.canvas.setExternalSelection(selected, source: owner)
        XCTAssertEqual(host.canvas.currentSelection?.text, "cell text")
        XCTAssertEqual(host.canvas.selectionText(for: owner), "cell text")
        source.passage = ""
        host.canvas.setExternalSelection(selected, source: owner)
        XCTAssertEqual(host.canvas.currentSelection?.text, "")
        XCTAssertEqual(host.canvas.selectionText(for: owner), "")
    }
}
