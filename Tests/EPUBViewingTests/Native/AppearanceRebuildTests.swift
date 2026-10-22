import EPUBCore
import EPUBReading
import Foundation
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A page's text and the canvas it is drawn on are built for one appearance at every moment
/// (#243). A session builds for Light first and rebuilds a section for Dark when its host turns
/// Dark. Each test holds that rebuild at a rich-content hook and looks at the screen meanwhile,
/// so what it finds does not depend on how long a build takes.
@MainActor final class AppearanceRebuildTests: XCTestCase {
    func testAReaderMountedInADarkHostAfterItsLightBuildShowsNoLightTextOnADarkCanvas() async throws {
        let held = expectation(description: "the opening section's Dark build is held")
        let gate = DarkBuildGate(holding: "OPS/one.xhtml", held: held)
        defer { gate.release() }
        var events: [EPUBReaderEvent] = []
        let session = try NativeSession(publication: try EPUBPublication.open(data: Self.book()), action: nil, rich: gate) {
            events.append($0)
        }
        defer { session.close() }
        // Opened with no view: the first build is for Light, and it finishes before the mount.
        try await wait("the Light build") { session.book.isComplete }
        XCTAssertEqual(session.book.typography, NativeTypography(isDark: false))

        let window = ReaderTestWindow(session: session, colorScheme: .dark)
        defer { window.close() }
        await waitFor([held])
        let canvas = try await laidOutCanvas(session, dark: true)
        assertTextAgreesWithCanvas(canvas, "while the opening section's Dark build is held")
        // No page until one is built for Dark: not the Light one, on either canvas.
        XCTAssertFalse(session.isReady)
        XCTAssertFalse(events.contains(.ready))
        XCTAssertEqual(shownAppearances(canvas), [], "a page is shown before its Dark build")
        XCTAssertTrue(drawsDark(canvas), "the empty canvas is not in the host's appearance")

        gate.release()
        try await wait("the Dark reader") { session.isReady && session.book.isComplete && session.book.typography.isDark }
        await settle(canvas)
        assertTextAgreesWithCanvas(canvas, "once the Dark build is in")
        XCTAssertTrue(canvas.configuration.isDark)
        XCTAssertEqual(shownAppearances(canvas), [true], "the opening page is not shown in Dark")
        XCTAssertEqual(events.filter { $0 == .ready }.count, 1)
    }

    /// The opening page waits for the Dark build, and the host turns back to Light before it
    /// arrives: the Light build it already has is current again, and nothing is built.
    func testAHostThatTurnsBackToLightBeforeTheDarkBuildArrivesOpensTheReaderInLight() async throws {
        let held = expectation(description: "the opening section's Dark build is held")
        let gate = DarkBuildGate(holding: "OPS/one.xhtml", held: held)
        defer { gate.release() }
        var events: [EPUBReaderEvent] = []
        let session = try NativeSession(publication: try EPUBPublication.open(data: Self.book()), action: nil, rich: gate) {
            events.append($0)
        }
        defer { session.close() }
        try await wait("the Light build") { session.book.isComplete }
        let window = ReaderTestWindow(session: session, colorScheme: .dark)
        defer { window.close() }
        await waitFor([held])
        _ = try await laidOutCanvas(session, dark: true)
        XCTAssertFalse(session.isReady)

        window.pageControls.colorScheme = .light
        try await wait("the reader opened in Light while the Dark build is held") { session.isReady }
        let canvas = try await laidOutCanvas(session, dark: false)
        assertTextAgreesWithCanvas(canvas, "the reader opened in Light")
        XCTAssertEqual(shownAppearances(canvas), [false], "the opening page is not shown in Light")

        // The late Dark build is dropped, and the reader stays as it opened.
        gate.release()
        try await wait("the held build to finish") { gate.passes > 0 }
        try await observe(for: 0.5) { await settle(canvas) }
        assertTextAgreesWithCanvas(canvas, "after the late Dark build")
        XCTAssertEqual(shownAppearances(canvas), [false])
        XCTAssertEqual(session.book.typography, NativeTypography(isDark: false))
        XCTAssertEqual(events.filter { $0 == .ready }.count, 1)
    }

    func testASessionClosedWhileItsOpeningPageWaitsForItsDarkBuildDoesNothingMore() async throws {
        let held = expectation(description: "the opening section's Dark build is held")
        let gate = DarkBuildGate(holding: "OPS/one.xhtml", held: held)
        defer { gate.release() }
        var events: [EPUBReaderEvent] = []
        let session = try NativeSession(publication: try EPUBPublication.open(data: Self.book()), action: nil, rich: gate) {
            events.append($0)
        }
        defer { session.close() }
        try await wait("the Light build") { session.book.isComplete }
        let window = ReaderTestWindow(session: session, colorScheme: .dark)
        defer { window.close() }
        await waitFor([held])
        let canvas = try await laidOutCanvas(session, dark: true)
        XCTAssertFalse(session.isReady)
        let emitted = events.count

        session.close()
        gate.release()
        try await wait("the held build to finish") { gate.passes > 0 }
        try await observe(for: 0.5) { await settle(canvas) }
        XCTAssertEqual(events.count, emitted, "a closed session emitted \(events.dropFirst(emitted))")
        XCTAssertFalse(session.isReady)
        XCTAssertNil(session.canvas)
        XCTAssertEqual(session.readerState?.status.lifecycle, .closed)
        XCTAssertEqual(shownAppearances(canvas), [], "a closed session's page is shown")
    }

    /// A note opened while the page's Dark rebuild is held comes from its own section's build,
    /// for Dark: it is drawn in Dark, though the page behind it is still Light.
    func testANoteOpenedDuringARebuildIsShownInTheAppearanceItsTextWasBuiltFor() async throws {
        let held = expectation(description: "the shown section's Dark rebuild is held")
        let gate = DarkBuildGate(holding: "OPS/one.xhtml", held: held)
        defer { gate.release() }
        let data = try SessionCoverageBook.epub([
            .init("one", SessionCoverageBook.filler(40) + "<hr/>" + SessionCoverageBook.filler(40)),
            .init("notes", "<p>Notes.</p><aside epub:type='footnote' id='n1'><p>The note's words.</p></aside>"),
        ])
        let session = try NativeSession(publication: try EPUBPublication.open(data: data), action: nil, rich: gate) { _ in }
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("the Light reader") { session.isReady && session.book.isComplete }

        window.pageControls.colorScheme = .dark
        await waitFor([held])
        let canvas = try await laidOutCanvas(session, dark: true)
        XCTAssertFalse(canvas.configuration.isDark, "the page left Light before its Dark rebuild")
        defer { closeNote(canvas) }
        let opened = try XCTUnwrap(session.activateLink(.note(href: "OPS/notes.xhtml#n1"),
                                                        from: CGRect(x: 100, y: 100, width: 20, height: 20)))
        await opened.value
        let note = try XCTUnwrap(presentedNote(canvas))
        XCTAssertEqual(note.textView.contentStorage.textStorage?.string, "The note's words.")
        XCTAssertEqual(builtAppearances([note.textView]), [true], "the note's text is not built for Dark")
        XCTAssertTrue(noteDrawsDark(canvas, note), "a note built for Dark is drawn in Light")
    }

    func testALiveChangeToDarkKeepsThePageAndCanvasInOneAppearanceInEitherFlow() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let held = expectation(description: "the shown section's Dark rebuild is held, \(flow)")
            let gate = DarkBuildGate(holding: "OPS/one.xhtml", held: held)
            defer { gate.release() }
            let session = try NativeSession(publication: try EPUBPublication.open(data: Self.book()), action: nil, rich: gate) { _ in }
            let window = ReaderTestWindow(session: session)
            defer { session.close(); window.close() }
            try await wait("the Light reader") { session.isReady && session.book.isComplete }
            try await session.send(.style(.init(flow: flow)))
            // Continuous scroll shows the whole book, built for Light, until a rebuild replaces it.
            try await wait("the whole book in continuous scroll") { flow == .paginated || session.canvas?.scrollBook != nil }
            let canvas = try await laidOutCanvas(session, dark: false)
            XCTAssertEqual(shownAppearances(canvas), [false], "the page is not shown in Light, \(flow)")
            XCTAssertFalse(canvas.configuration.isDark)

            window.pageControls.colorScheme = .dark
            await waitFor([held])
            _ = try await laidOutCanvas(session, dark: true)
            assertTextAgreesWithCanvas(canvas, "while the shown section's Dark rebuild is held, \(flow)")
            XCTAssertEqual(session.readerState?.status.effectiveAppearance, .dark)

            gate.release()
            try await wait("the Dark reader") {
                session.book.isComplete && session.book.typography.isDark && canvas.configuration.isDark
            }
            await settle(canvas)
            assertTextAgreesWithCanvas(canvas, "once the Dark rebuild is in, \(flow)")
            XCTAssertEqual(shownAppearances(canvas), [true], "the page is not shown in Dark, \(flow)")
        }
    }

    /// Once the page on screen is in Dark, a page turn can reach a section whose Dark rebuild
    /// has not arrived: that page is drawn on the canvas of the appearance its text has.
    func testAPageTurnToASectionNotYetRebuiltForDarkDrawsItInItsOwnAppearance() async throws {
        let held = expectation(description: "the second section's Dark rebuild is held")
        let gate = DarkBuildGate(holding: "OPS/two.xhtml", held: held)
        defer { gate.release() }
        let data = try SessionCoverageBook.epub([
            .init("one", "<p>The first section, one page long.</p>"),
            .init("two", "<p>The second section.</p><hr/><p>Its last words.</p>"),
        ])
        let session = try NativeSession(publication: try EPUBPublication.open(data: data), action: nil, rich: gate) { _ in }
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("the Light reader") { session.isReady && session.book.isComplete }

        window.pageControls.colorScheme = .dark
        await waitFor([held])
        try await wait("the first section in Dark") { session.book.isCurrent(0) && session.canvas?.configuration.isDark == true }
        let canvas = try await laidOutCanvas(session, dark: true)
        XCTAssertEqual(shownAppearances(canvas), [true], "the first section is not shown in Dark")
        try await session.send(.nextPage)
        await settle(canvas)
        XCTAssertEqual(session.visibleRange?.start.section, 1)
        XCTAssertFalse(session.book.isCurrent(1), "the second section was rebuilt before the hook released it")
        assertTextAgreesWithCanvas(canvas, "on the section still built for Light")

        gate.release()
        try await wait("the second section in Dark") { session.book.isComplete && canvas.configuration.isDark }
        await settle(canvas)
        XCTAssertEqual(shownAppearances(canvas), [true], "the second section is not shown in Dark")
    }

    // MARK: - Support

    /// A long opening section, as the issue measured, with a rule where the hook holds it.
    private static func book() throws -> Data {
        try SessionCoverageBook.epub([
            .init("one", SessionCoverageBook.filler(40) + "<hr/>" + SessionCoverageBook.filler(40)),
            .init("two", SessionCoverageBook.filler(10)),
        ])
    }

    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitFor(_ expectations: [XCTestExpectation], file: StaticString = #filePath, line: UInt = #line) async {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 20)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    /// The mounted canvas, once the host's appearance has reached the session, laid out after
    /// every main-actor job already queued: the mounted view's readiness among them.
    private func laidOutCanvas(_ session: NativeSession, dark: Bool) async throws -> ReaderCanvasView {
        try await wait("the host's appearance and a laid-out canvas") {
            session.systemIsDark == dark && (session.canvas?.bounds.width ?? 0) > 0
        }
        let canvas = try XCTUnwrap(session.canvas)
        await settle(canvas)
        return canvas
    }

    private func settle(_ canvas: ReaderCanvasView) async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #if os(macOS)
        canvas.window?.contentView?.layoutSubtreeIfNeeded()
        #else
        canvas.window?.layoutIfNeeded()
        #endif
    }

    /// Runs `body` repeatedly for `duration`: a look at a state nothing more should change.
    private func observe(for duration: TimeInterval, _ body: () async -> Void) async throws {
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            await body()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The appearances the text on screen was built for, told by its body text's colour.
    private func shownAppearances(_ canvas: ReaderCanvasView) -> Set<Bool> { builtAppearances(canvas.textViews) }

    private func builtAppearances(_ views: [ReaderTextView]) -> Set<Bool> {
        var built: Set<Bool> = []
        for view in views {
            guard let storage = view.contentStorage.textStorage else { continue }
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                guard let color = value as? PlatformColor else { return }
                for dark in [false, true] where color == ReaderPalette.text(dark: dark) { built.insert(dark) }
            }
        }
        return built
    }

    /// Whether the canvas paints a Dark background.
    private func drawsDark(_ canvas: ReaderCanvasView) -> Bool {
        #if os(macOS)
        canvas.layer?.backgroundColor == ReaderPalette.background(dark: true).cgColor
        #else
        canvas.backgroundColor == ReaderPalette.background(dark: true)
        #endif
    }

    private func presentedNote(_ canvas: ReaderCanvasView) -> ReaderNoteViewController? {
        #if os(macOS)
        (canvas.presentedNote as? NSPopover)?.contentViewController as? ReaderNoteViewController
        #else
        canvas.presentedNote as? ReaderNoteViewController
        #endif
    }

    /// Whether a note's popover is drawn in Dark: its appearance on the Mac, its view's style
    /// and background on iPhone and iPad.
    private func noteDrawsDark(_ canvas: ReaderCanvasView, _ note: ReaderNoteViewController) -> Bool {
        #if os(macOS)
        (canvas.presentedNote as? NSPopover)?.appearance?.name == .darkAqua
        #else
        note.overrideUserInterfaceStyle == .dark && note.textView.backgroundColor == ReaderPalette.background(dark: true)
        #endif
    }

    /// Closes a note before its reader window goes, as `NoteReachabilityTests` does.
    private func closeNote(_ canvas: ReaderCanvasView) {
        #if os(macOS)
        (canvas.presentedNote as? NSPopover)?.close()
        #else
        (canvas.presentedNote as? ReaderNoteViewController)?.dismiss(animated: false)
        #endif
        canvas.presentedNote = nil
    }

    private func assertTextAgreesWithCanvas(_ canvas: ReaderCanvasView, _ moment: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let dark = drawsDark(canvas)
        XCTAssertEqual(dark, canvas.configuration.isDark, "\(moment): the canvas paints another appearance than it has",
                       file: file, line: line)
        XCTAssertTrue(shownAppearances(canvas).isSubset(of: [dark]),
                      "\(moment): text built for \(dark ? "Light" : "Dark") is shown on a \(dark ? "Dark" : "Light") canvas",
                      file: file, line: line)
    }
}

/// Holds every build for Dark of one document at its rule, until released; builds for Light
/// pass. One release lets every held build finish, and `passes` counts them.
private final class DarkBuildGate: RichContentFactory, @unchecked Sendable {
    private let condition = NSCondition()
    private let path: String
    private let held: XCTestExpectation
    private var announced = false
    private var released = false
    private var passed = 0
    private let content = NativeRichContent()

    init(holding path: String, held: XCTestExpectation) { self.path = path; self.held = held }

    /// How many held builds have been let through.
    var passes: Int {
        condition.lock()
        defer { condition.unlock() }
        return passed
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        if context.typography.isDark, context.document.path == path {
            condition.lock()
            if !announced { announced = true; held.fulfill() }
            while !released { condition.wait() }
            passed += 1
            condition.unlock()
        }
        return content.horizontalRule(element, style: style, context: context)
    }

    func image(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        content.image(element, style: style, context: context)
    }
    func svg(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        content.svg(element, style: style, context: context)
    }
    func table(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        content.table(element, style: style, context: context)
    }
    func math(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString? {
        content.math(element, style: style, context: context)
    }
}
