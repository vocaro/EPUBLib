import CoreText
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class NoteReachabilityTests: XCTestCase {
    func testALegacyNamedAnchorAnywhereInAHiddenNoteNamesTheWholeNote() throws {
        let text = try BuilderHarness.build("""
            <p>Claim<a href='#fn1'>plain</a> <a epub:type='noteref' href='#fn1'>typed</a>.</p>\
            <aside epub:type='footnote'><p>First.</p><p><a name='fn1'/>Second.</p></aside><p>After.</p>
            """)
        XCTAssertEqual(text.notes["fn1"]?.string, "First.\nSecond.")
        for label in ["plain", "typed"] {
            XCTAssertEqual(SectionContentSupport.link(label, in: text), .note(href: "OPS/one.xhtml#fn1"))
        }
        XCTAssertEqual(text.anchors["fn1"], BuilderHarness.location(of: "After.", in: text))
        XCTAssertFalse(text.string.string.contains("Second."))
        SectionContentSupport.assertTextMapContracts(text)
    }

    func testNamedNoteAnchorsKeepIdPrecedenceAndExistingNameRules() throws {
        let text = try BuilderHarness.build("""
            <p><a href='#claimed'>claimed link</a> <a href='#first'>first link</a> <a href='#alias'>alias link</a></p>\
            <p id='claimed'>Id wins.</p><p><a name='first'/>First name wins.</p>\
            <aside epub:type='footnote'><p><a name='claimed'/>Not the claimed note.</p>\
            <p><a name='first'/>Not the first name.</p><p><a id='own' name='alias'/>Own-id note.</p></aside>
            """)
        XCTAssertNil(text.notes["claimed"])
        XCTAssertNil(text.notes["first"])
        XCTAssertNil(text.notes["alias"], "An anchor with an id keeps the existing #133 behavior")
        XCTAssertNotNil(text.notes["own"])
        for label in ["claimed", "first", "alias"] {
            XCTAssertEqual(SectionContentSupport.link(label + " link", in: text), .internal(href: "OPS/one.xhtml#" + label))
        }
        XCTAssertEqual(text.anchors["claimed"], BuilderHarness.location(of: "Id wins.", in: text))
        XCTAssertEqual(text.anchors["first"], BuilderHarness.location(of: "First name wins.", in: text))
        SectionContentSupport.assertTextMapContracts(text)
    }

    func testRichTableCellsAndCaptionsUseTheirEnclosingNotesRules() throws {
        let text = try SectionContentSupport.styled("""
            <p id='ref'>Text.</p><aside epub:type='footnote' id='outer'><p>Before.</p>\
            <table><caption>Caption <a role='doc-backlink' href='#ref'>caption-back</a></caption>\
            <tr><td><p>Cell <a href='#outer'>1.</a> <a role='doc-backlink' href='#ref'>cell-back</a></p>\
            <div epub:type='endnote' id='inner'><b>Separate note.</b></div><p>Tail.</p>\
            <div epub:type='endnote'>Unnamed note.</div></td>\
            <td><p><b>Bold</b> <a href='two.xhtml'>target</a> <a epub:type='backlink' href='#ref'>typed-back</a></p></td></tr>\
            </table><p>After.</p></aside><p>End.</p>
            """)
        let note = try XCTUnwrap(text.notes["outer"])
        let table = try XCTUnwrap(TableCoverage.tables(in: note).first)
        XCTAssertEqual(table.cells.map(\.content.string), ["Cell 1.\nTail.\nUnnamed note.", "Bold target"])
        XCTAssertEqual(text.notes["inner"]?.string, "Separate note.")
        XCTAssertFalse(note.string.contains("caption-back"))
        XCTAssertTrue(note.string.contains("Caption"))
        XCTAssertFalse(text.string.string.contains("Before."))
        let first = try XCTUnwrap(table.cells.first).content
        let ownNumber = (first.string as NSString).range(of: "1.").location
        guard ownNumber != NSNotFound else { return XCTFail("The note's own number was lost") }
        XCTAssertNil(first.attribute(.link, at: ownNumber, effectiveRange: nil))
        let second = try XCTUnwrap(table.cells.last).content
        let target = (second.string as NSString).range(of: "target").location
        guard target != NSNotFound else { return XCTFail("The ordinary link was lost") }
        XCTAssertEqual((second.attribute(.link, at: target, effectiveRange: nil) as? URL).flatMap(ReaderLink.init(url:)),
                       .internal(href: "OPS/two.xhtml"))
        let bold = try XCTUnwrap(second.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        XCTAssertTrue(CTFontGetSymbolicTraits(bold as CTFont).contains(.traitBold))
        SectionContentSupport.assertTextMapContracts(text)
    }

    func testAnonymousRichTableCellsAlsoLeaveOutBacklinksAndSeparatelyCapturedNotes() throws {
        let text = try SectionContentSupport.styled("""
            <p>Text.</p><aside epub:type='footnote' id='outer'><table>\
            <tr><td>One.</td><td>Two.</td></tr><p>Anonymous <a role='doc-backlink' href='#ref'>back</a>\
            <span epub:type='endnote' id='inner'>Separate.</span> tail.</p></table></aside>
            """)
        let note = try XCTUnwrap(text.notes["outer"])
        let table = try XCTUnwrap(TableCoverage.tables(in: note).first)
        XCTAssertEqual(table.cells.map(\.content.string), ["One.", "Two.", "Anonymous tail."])
        XCTAssertEqual(text.notes["inner"]?.string, "Separate.")
    }
}

@MainActor final class NoteLinkSessionTests: XCTestCase {
    private enum NewerAction: Equatable { case link, note, command }

    private func shownNoteText(_ canvas: ReaderCanvasView) -> String? {
        #if os(macOS)
        let controller = (canvas.presentedNote as? NSPopover)?.contentViewController as? ReaderNoteViewController
        #else
        let controller = canvas.presentedNote as? ReaderNoteViewController
        #endif
        return controller?.textView.contentStorage.textStorage?.string
    }

    /// Close the presentation before its reader window is torn down, including on a failed test.
    private func closeNote(_ canvas: ReaderCanvasView?) {
        #if os(macOS)
        (canvas?.presentedNote as? NSPopover)?.close()
        #else
        (canvas?.presentedNote as? ReaderNoteViewController)?.dismiss(animated: false)
        #endif
        canvas?.presentedNote = nil
    }

    private func dismissNote(_ canvas: ReaderCanvasView) async {
        #if os(macOS)
        closeNote(canvas)
        #else
        // Package XCTest can route and construct the note, but its generic UIKit modal
        // transition never attaches even a plain controller. Actual presentation is verified
        // by the app-hosted lane; this lane cancels the pending transition without awaiting it.
        guard ProcessInfo.processInfo.environment["EPUBLIB_NOTE_APP_HOSTED"] == "YES" else {
            closeNote(canvas)
            return
        }
        if let controller = canvas.presentedNote as? ReaderNoteViewController {
            @MainActor func state() -> String {
                "presenting=\(controller.isBeingPresented), dismissing=\(controller.isBeingDismissed), "
                    + "presenter=\(controller.presentingViewController != nil), attached=\(controller.viewIfLoaded?.window != nil)"
                    + ", loaded=\(controller.isViewLoaded), noteFrame=\(String(describing: controller.viewIfLoaded?.frame)), "
                    + "preferredSize=\(controller.preferredContentSize), sourceRect=\(String(describing: controller.popoverPresentationController?.sourceRect)), "
                    + "sourceBounds=\(String(describing: controller.popoverPresentationController?.sourceView?.bounds)), "
                    + "sourceSafeArea=\(String(describing: controller.popoverPresentationController?.sourceView?.safeAreaInsets))"
                    + ", presenterAttached=\(controller.presentingViewController?.viewIfLoaded?.window != nil), "
                    + "presenterBounds=\(String(describing: controller.presentingViewController?.viewIfLoaded?.bounds)), "
                    + "keyWindow=\(canvas.window?.isKeyWindow == true), scene=\(String(describing: canvas.window?.windowScene?.activationState.rawValue)), "
                    + "app=\(UIApplication.shared.applicationState), animations=\(UIView.areAnimationsEnabled)"
            }
            // presentNote starts an animated presentation. Its text exists before UIKit has
            // attached the controller, and dismissing at that instant can lose the completion
            // callback. Wait for actual transition state, with a bound on both phases.
            @MainActor func waitForTransition(_ phase: String, until settled: @MainActor () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(5)
                while !settled() {
                    guard Date() < deadline else {
                        XCTFail("Note cleanup timed out during \(phase): \(state())")
                        return false
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return true
            }
            print("NoteLinkSessionTests UIKit cleanup waiting for presentation: \(state())")
            guard await waitForTransition("presentation", until: {
                !controller.isBeingPresented && controller.presentingViewController != nil && controller.viewIfLoaded?.window != nil
            }) else { closeNote(canvas); return }
            print("NoteLinkSessionTests UIKit cleanup dismissing: \(state())")
            controller.dismiss(animated: false)
            _ = await waitForTransition("dismissal", until: {
                !controller.isBeingDismissed && controller.presentingViewController == nil && controller.viewIfLoaded?.window == nil
            })
            print("NoteLinkSessionTests UIKit cleanup finished: \(state())")
        }
        canvas.presentedNote = nil
        #endif
    }

    private func waitFor(_ expectations: [XCTestExpectation], file: StaticString = #filePath, line: UInt = #line) async {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 20)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    func testDelayedPlainNoteActivationCannotReplaceANewerLink() async throws {
        try await overlappingActivation(slowFragment: "slow-note", newer: .link)
    }

    func testDelayedPlainNoteActivationCannotReplaceANewerNote() async throws {
        try await overlappingActivation(slowFragment: "slow-note", newer: .note)
    }

    func testDelayedPlainNoteActivationCannotReplaceANewerNavigateCommand() async throws {
        try await overlappingActivation(slowFragment: "slow-note", newer: .command)
    }

    func testDelayedMissingNoteActivationCannotNavigateOverANewerCommand() async throws {
        try await overlappingActivation(slowFragment: "missing", newer: .command)
    }

    /// The rich factory holds the slow target's build until the newer action has finished.
    /// Task handles prove both activations have completed, without a timing delay or a poll.
    private func overlappingActivation(slowFragment: String, newer: NewerAction) async throws {
        let started = expectation(description: "the slow section is held in its build")
        let opened = expectation(description: "the source is ready and located")
        let navigated = newer == .note ? nil : expectation(description: "the newer target was shown")
        let gate = NoteTargetBuildGate(started: started)
        defer { gate.release() }
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            .init("one", "<p>The source.</p>"),
            .init("slow", "<hr/><p>Slow target.</p><aside epub:type='footnote' id='slow-note'>The old note.</aside>", linear: false),
            .init("fast", "<p id='target'>The new target.</p><aside epub:type='footnote' id='fast-note'>The new note.</aside>"),
        ]))
        var events: [EPUBReaderEvent] = []
        var didOpen = false, didNavigate = false
        let session = try NativeSession(publication: publication, action: nil, rich: gate) { event in
            events.append(event)
            if case .relocated(let location) = event {
                if location.href == "OPS/one.xhtml", !didOpen { didOpen = true; opened.fulfill() }
                if location.href == "OPS/fast.xhtml", !didNavigate { didNavigate = true; navigated?.fulfill() }
            }
        }
        let window = NoteSessionHost(session: session)
        defer { closeNote(session.canvas); session.close(); window.close() }
        await waitFor([opened])
        let canvas = try XCTUnwrap(session.canvas)
        // A real content anchor, below the iPhone status bar and inside the canvas's safe area.
        let rect = CGRect(x: 100, y: 100, width: 20, height: 20)
        let old = try XCTUnwrap(session.activateLink(.internal(href: "OPS/slow.xhtml#" + slowFragment), from: rect))
        await waitFor([started])
        switch newer {
        case .link:
            let current = try XCTUnwrap(session.activateLink(.internal(href: "OPS/fast.xhtml#target"), from: rect))
            await current.value
        case .note:
            let current = try XCTUnwrap(session.activateLink(.note(href: "OPS/fast.xhtml#fast-note"), from: rect))
            await current.value
            XCTAssertEqual(shownNoteText(canvas), "The new note.")
        case .command:
            try await session.send(.navigate(href: "OPS/fast.xhtml#target"))
        }
        if let navigated { await waitFor([navigated]) }
        let place = session.visibleRange
        let note = shownNoteText(canvas)
        let eventCount = events.count
        gate.release()
        await old.value
        XCTAssertEqual(session.visibleRange, place, "The older lookup cannot navigate after the newer action")
        XCTAssertEqual(shownNoteText(canvas), note, "The older lookup cannot replace the newer note")
        XCTAssertFalse(events.dropFirst(eventCount).contains { if case .relocated = $0 { true } else { false } })
        XCTAssertEqual(events.filter { $0 == .ready }.count, 1)
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.readerState?.status.lifecycle, .ready)
        await dismissNote(canvas)
    }

    func testPlainCrossDocumentLinksPresentCapturedNotesWithoutNavigating() async throws {
        let reader = try SessionCoverageReader(SessionCoverageBook.epub([
            .init("one", """
                <p><a href='notes.xhtml#fn1'>id note</a> <a href='notes.xhtml#fn%C3%A9'>legacy note</a> \
                <a epub:type='noteref' href='notes.xhtml#fn1'>typed note</a> \
                <a href='notes.xhtml#ordinary'>ordinary target</a> <a href='notes.xhtml#missing'>missing note</a> \
                <a href='missing.xhtml#fn1'>missing document</a> <a href='https://example.invalid/n'>external</a></p>
                """),
            .init("notes", """
                <p>Notes opening.</p><aside epub:type='footnote' id='fn1'><p>The id note.</p></aside>\
                <aside epub:type='footnote'><p><a name='fné'/>The legacy note.</p></aside><p id='ordinary'>Ordinary target.</p>
                """, linear: false),
        ]), mounted: false)
        let host = NoteSessionHost(session: reader.session)
        defer { closeNote(reader.session.canvas); reader.close(); host.close() }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let source = try XCTUnwrap(reader.session.book.section(0))
        func activate(_ label: String) throws {
            let link = try XCTUnwrap(SectionContentSupport.link(label, in: source))
            reader.session.canvas(canvas, didActivate: link, at: .init(section: 0, offset: 0),
                                  rect: CGRect(x: 100, y: 100, width: 20, height: 20))
        }
        let place = reader.session.visibleRange
        let count = reader.events.count
        for (label, expected) in [("id note", "The id note."), ("legacy note", "The legacy note."), ("typed note", "The id note.")] {
            try activate(label)
            try await reader.wait(label) { self.shownNoteText(canvas) == expected }
            XCTAssertEqual(reader.session.visibleRange, place)
            await dismissNote(canvas)
        }
        XCTAssertTrue(reader.locations(since: count).isEmpty)

        try activate("external")
        try await reader.wait("external refusal") { !reader.notices(since: count).isEmpty }
        XCTAssertEqual(reader.notices(since: count), ["This reader does not open links outside the book."])
        try activate("missing document")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reader.session.visibleRange, place)

        try activate("ordinary target")
        try await reader.wait("ordinary target navigation") { reader.section == 1 }
        XCTAssertEqual(reader.session.lastLocation?.href, "OPS/notes.xhtml")
        try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
        try await reader.wait("return to source") { reader.section == 0 }
        try activate("missing note")
        try await reader.wait("missing fragment navigation") { reader.section == 1 }
    }
}

/// A real session and canvas, with a plain UIKit presenter. SwiftUI hosting is exercised by
/// other session tests; this fixture keeps its presentation transitions out of note routing.
@MainActor private final class NoteSessionHost {
    #if os(macOS)
    private let window: ReaderTestWindow
    #else
    private let window: UIWindow
    private let controller = UIViewController()
    private let canvas = ReaderCanvasView(frame: .zero)
    #endif

    init(session: NativeSession) {
        #if os(macOS)
        window = ReaderTestWindow(session: session)
        #else
        let size = CGRect(x: 0, y: 0, width: 390, height: 844)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            window = UIWindow(windowScene: scene)
            window.frame = size
        } else {
            window = UIWindow(frame: size)
        }
        window.keepLightAppearance()
        controller.view = canvas
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        canvas.layoutIfNeeded()
        session.attach(canvas)
        #endif
    }

    func close() {
        #if os(macOS)
        window.close()
        #else
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }
}

/// Blocks only rich-content construction in the slow document. Both a background build and an
/// on-demand build may reach the gate; one release lets all of them finish.
private final class NoteTargetBuildGate: RichContentFactory, @unchecked Sendable {
    private let condition = NSCondition()
    private let started: XCTestExpectation
    private var announced = false
    private var released = false
    private let content = NativeRichContent()

    init(started: XCTestExpectation) { self.started = started }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func horizontalRule(_ element: ContentNode, style: ComputedStyle, context: RichContentContext) -> NSAttributedString {
        if context.document.path == "OPS/slow.xhtml" {
            condition.lock()
            if !announced { announced = true; started.fulfill() }
            while !released { condition.wait() }
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
