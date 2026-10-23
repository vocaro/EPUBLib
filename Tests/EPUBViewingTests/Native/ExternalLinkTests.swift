import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A link outside the book (#683). EPUB Reading Systems 3.3 §3.9: before opening an `http` or
/// `https` link a reading system should have the reader's consent, and should have it before
/// handing a link to the application of its scheme, as `mailto` goes to the mail app. So the
/// reader asks, naming the address, and opens it only on Open, with the system: here the test
/// window's `openURL` action, which records the address and opens nothing. A host can refuse
/// such links, keeping the notice the reader gave before, or take them itself. No other scheme
/// is ever opened or given to the host.
@MainActor final class ExternalLinkTests: XCTestCase {
    /// What a host that takes links has been given.
    @MainActor private final class Handed {
        var urls: [URL] = []
    }

    private static let body = """
        <p>Visit <a href="https://example.invalid/page?q=1">the site</a> or <a href="mailto:reader@example.invalid">write to us</a>.</p>\
        <table><tr><td>Plain cell</td><td>See <a href="https://example.invalid/cell">the cell site</a>.</td></tr></table>\
        <p>Read the <a epub:type="noteref" href="#n1">first note</a> here.</p>\
        <aside epub:type="footnote" id="n1"><p>From <a href="https://example.invalid/source">the source page</a>.</p></aside>
        """

    private func open(_ body: String = body) async throws -> SessionCoverageReader {
        let reader = try SessionCoverageReader(SessionCoverageBook.epub([.init("one", body), .init("two", "<p>Second.</p>")]))
        addTeardownBlock { @MainActor in reader.close() }
        try await reader.settle()
        return reader
    }

    private func controls(_ reader: SessionCoverageReader) throws -> TestPageControls {
        try XCTUnwrap(reader.window?.pageControls)
    }

    private func kind(_ links: EPUBExternalLinks) -> String {
        switch links.behavior {
        case .ask: "ask"
        case .refuse: "refuse"
        case .handle: "handle"
        }
    }

    /// Sets what the mounted view says of links outside the book, and waits for the session to
    /// have it from the view, as a host's change reaches a reader already shown.
    private func use(_ links: EPUBExternalLinks, in reader: SessionCoverageReader) async throws {
        try controls(reader).externalLinks = links
        try await reader.wait("the reader takes \(kind(links))") { kind(reader.session.externalLinks) == kind(links) }
    }

    private func canvas(_ reader: SessionCoverageReader) throws -> ReaderCanvasView {
        try XCTUnwrap(reader.session.canvas)
    }

    /// The question shown: its title, its message, and its buttons as the platform orders them.
    private func question(_ reader: SessionCoverageReader) throws -> (title: String, message: String, buttons: [String])? {
        #if os(macOS)
        guard let alert = try canvas(reader).linkQuestion?.shown as? NSAlert else { return nil }
        return (alert.messageText, alert.informativeText, alert.buttons.map(\.title))
        #else
        // The question and the address are the title's two lines.
        guard let alert = try canvas(reader).linkQuestion?.shown as? UIAlertController else { return nil }
        let lines = (alert.title ?? "").split(separator: "\n", maxSplits: 1).map(String.init)
        return (lines.first ?? "", lines.count > 1 ? lines[1] : "", alert.actions.compactMap(\.title))
        #endif
    }

    private func assertAsked(_ address: String, in reader: SessionCoverageReader, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await reader.wait("the question about \(address)", file: file, line: line) { (try? question(reader)) != nil }
        let shown = try XCTUnwrap(question(reader), file: file, line: line)
        XCTAssertEqual(shown.title, "Open a link outside the book?", file: file, line: line)
        XCTAssertEqual(shown.message, address, "the question names the address", file: file, line: line)
        XCTAssertEqual(reader.session.askedLink?.url.absoluteString, address, file: file, line: line)
        #if os(macOS)
        XCTAssertEqual(shown.buttons, ["Open", "Cancel"], file: file, line: line)
        let alert = try XCTUnwrap(canvas(reader).linkQuestion?.shown as? NSAlert)
        let window = try XCTUnwrap(reader.window?.window)
        try await reader.wait("the sheet on the reader's window", file: file, line: line) { window.attachedSheet === alert.window }
        // Return chooses the sheet's default button while the sheet is the key window, which a
        // test leaves to the person at the Mac; Escape is Cancel's own key equivalent.
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell, "Return opens", file: file, line: line)
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}", "Escape cancels", file: file, line: line)
        #else
        XCTAssertEqual(shown.buttons, ["Cancel", "Open"], file: file, line: line)
        let alert = try XCTUnwrap(canvas(reader).linkQuestion?.shown as? UIAlertController)
        // UIKit gives a message an element of its own, which VoiceOver reads only on the next
        // swipe: the address is in the title, which it reads as the alert comes up (#793).
        XCTAssertNil(alert.message, file: file, line: line)
        XCTAssertEqual(alert.preferredAction?.title, "Open", "Return chooses Open", file: file, line: line)
        XCTAssertEqual(alert.actions.first { $0.style == .cancel }?.title, "Cancel", "Escape chooses Cancel", file: file, line: line)
        #endif
    }

    /// Answers the question shown. On Mac Open by a click of its button and Cancel by Escape,
    /// sent to the sheet; on iPhone and iPad as the alert's action does (the package test host
    /// does not complete a UIKit presentation, doc/testing.md).
    private func answer(_ open: Bool, in reader: SessionCoverageReader, file: StaticString = #filePath, line: UInt = #line) throws {
        let canvas = try canvas(reader)
        #if os(macOS)
        let alert = try XCTUnwrap(canvas.linkQuestion?.shown as? NSAlert, file: file, line: line)
        if open {
            alert.buttons[0].performClick(nil)
        } else {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: alert.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53), file: file, line: line)
            XCTAssertTrue(alert.window.performKeyEquivalent(with: event), "the sheet takes Escape", file: file, line: line)
        }
        #else
        let alert = try XCTUnwrap(canvas.linkQuestion?.shown as? UIAlertController, file: file, line: line)
        canvas.alertAnswered(open, to: alert)
        #endif
    }

    private func waitUntilAnswered(_ reader: SessionCoverageReader, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await reader.wait("the answer", file: file, line: line) {
            reader.session.askedLink == nil && reader.session.canvas?.linkQuestion == nil
        }
        #if os(macOS)
        let window = try XCTUnwrap(reader.window?.window)
        try await reader.wait("the sheet gone", file: file, line: line) { window.attachedSheet == nil }
        #endif
    }

    /// The `.link` run of the page column's own text whose target is `href`.
    private func link(_ href: String, in reader: SessionCoverageReader) throws -> (view: ReaderTextView, url: URL, range: NSRange) {
        for view in try canvas(reader).textViews {
            guard let storage = view.contentStorage.textStorage else { continue }
            var found: (URL, NSRange)?
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard let url = value as? URL, case .external(href)? = ReaderLink(url: url) else { return }
                found = (url, range); stop.pointee = true
            }
            if let found { return (view, found.0, found.1) }
        }
        throw XCTSkip("no link to \(href) on screen")
    }

    // MARK: In the text

    /// A pointer's click or tap on a web link: the reader asks and nothing is opened, the place
    /// stays, and no notice is given. Open opens the address once, with the system.
    func testAWebLinkClickedInTheTextIsAskedAboutAndOpenedOnOpen() async throws {
        let reader = try await open()
        let place = reader.session.visibleRange, located = reader.locations.count, events = reader.events.count
        let found = try link("https://example.invalid/page?q=1", in: reader)
        let canvas = try canvas(reader)
        #if os(macOS)
        // What AppKit calls when the link is clicked.
        _ = canvas.textView(found.view, clickedOnLink: found.url, at: found.range.location)
        #else
        // What the text view's primary action for the link does, on a tap.
        canvas.activateLink(found.url, range: found.range, in: found.view)
        #endif
        try await assertAsked("https://example.invalid/page?q=1", in: reader)
        XCTAssertEqual(try controls(reader).opened, [], "nothing opens before the reader answers")
        XCTAssertEqual(reader.notices(since: events), [])
        try answer(true, in: reader)
        try await waitUntilAnswered(reader)
        XCTAssertEqual(try controls(reader).opened, [URL(string: "https://example.invalid/page?q=1")!])
        XCTAssertEqual(reader.session.visibleRange, place)
        XCTAssertEqual(reader.locations.count, located, "following a link out of the book moves nothing in it")
        XCTAssertEqual(reader.notices(since: events), [])
    }

    /// VoiceOver's activation of the link's element, which Full Keyboard Access's activation and,
    /// on Mac, VoiceOver's Control-Option-Space use as well: an email address is asked about, and
    /// Cancel opens nothing.
    func testAnEmailLinkActivatedByVoiceOverIsAskedAboutAndCancelOpensNothing() async throws {
        let reader = try await open()
        let found = try link("mailto:reader@example.invalid", in: reader)
        #if os(macOS)
        let element = try XCTUnwrap((found.view.accessibilityChildren() ?? []).compactMap { $0 as? ReaderLinkAccessibilityElement }
            .first { $0.accessibilityTitle() == "write to us" })
        XCTAssertTrue(element.accessibilityPerformPress())
        #else
        let elements = try XCTUnwrap(found.view.accessibilityElements as? [UIAccessibilityElement])
        let element = try XCTUnwrap(elements.first { $0.accessibilityTraits.contains(.link) && $0.accessibilityLabel == "write to us" })
        XCTAssertTrue(element.accessibilityActivate())
        #endif
        try await assertAsked("mailto:reader@example.invalid", in: reader)
        try answer(false, in: reader)
        try await waitUntilAnswered(reader)
        XCTAssertEqual(try controls(reader).opened, [])
        XCTAssertEqual(reader.notices(), [])
    }

    // MARK: In a table cell and in a note

    /// A link in a table cell, by the cell's own click or tap and by the row's VoiceOver action.
    func testALinkInATableCellIsAskedAboutByPointerAndByVoiceOver() async throws {
        let reader = try await open()
        let view = try XCTUnwrap(try canvas(reader).textViews.first { $0.containsTableRows })
        view.refreshTableInteractions()
        let interaction = try XCTUnwrap(view.tableInteraction)
        let cell = try XCTUnwrap(interaction.cells.values.first { $0.cellText.string.hasPrefix("See") })
        let range = (cell.cellText.string as NSString).range(of: "the cell site")
        let url = try XCTUnwrap(cell.cellText.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
        // What a click (Mac) or a tap (iPhone and iPad) on the link in the cell calls.
        cell.onLink?(url, range)
        try await assertAsked("https://example.invalid/cell", in: reader)
        try answer(true, in: reader)
        try await waitUntilAnswered(reader)
        XCTAssertEqual(try controls(reader).opened, [URL(string: "https://example.invalid/cell")!])

        let follow = try XCTUnwrap(interaction.accessibilityActionsOfEveryRow().first { $0.name == "Follow Table Link: the cell site" })
        XCTAssertTrue(follow.perform())
        try await assertAsked("https://example.invalid/cell", in: reader)
        try answer(false, in: reader)
        try await waitUntilAnswered(reader)
        XCTAssertEqual(try controls(reader).opened.count, 1, "Cancel opened nothing")
    }

    /// A link outside the book in a note's popover did nothing; it is asked about as one in the
    /// text is. On iPhone and iPad the question stands over the note; on Mac the note closes
    /// for the sheet.
    func testALinkInANotesPopoverIsAskedAbout() async throws {
        let reader = try await open()
        let canvas = try canvas(reader)
        let source = try XCTUnwrap(reader.session.book.section(0))
        let noteref = try XCTUnwrap(SectionContentSupport.link("first note", in: source))
        reader.session.canvas(canvas, didActivate: noteref, at: .init(section: 0, offset: 0), rect: CGRect(x: 100, y: 100, width: 20, height: 20))
        #if os(macOS)
        try await reader.wait("the note shown") {
            (canvas.presentedNote as? NSPopover)?.isShown == true && (canvas.presentedNote as? NSPopover)?.contentViewController is ReaderNoteViewController
        }
        let note = try XCTUnwrap((canvas.presentedNote as? NSPopover)?.contentViewController as? ReaderNoteViewController)
        defer { (canvas.presentedNote as? NSPopover)?.close() }
        #else
        try await reader.wait("the note") { canvas.presentedNote is ReaderNoteViewController }
        let note = try XCTUnwrap(canvas.presentedNote as? ReaderNoteViewController)
        defer { note.dismiss(animated: false); canvas.presentedNote = nil }
        #endif
        let storage = try XCTUnwrap(note.textView.contentStorage.textStorage)
        let range = (storage.string as NSString).range(of: "the source page")
        let url = try XCTUnwrap(storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
        #if os(macOS)
        // What AppKit calls for a click on the link and for VoiceOver's press of its element.
        XCTAssertTrue(note.textView(note.textView, clickedOnLink: url, at: range.location))
        #else
        // What the note's primary action for the link does, on a tap and on VoiceOver's activation.
        try XCTUnwrap(note.onLink)(url)
        #endif
        try await assertAsked("https://example.invalid/source", in: reader)
        #if os(macOS)
        let popover = try XCTUnwrap(canvas.presentedNote as? NSPopover)
        try await reader.wait("the note closed, which would stand over the sheet") { !popover.isShown }
        #endif
        try answer(true, in: reader)
        try await waitUntilAnswered(reader)
        XCTAssertEqual(try controls(reader).opened, [URL(string: "https://example.invalid/source")!])
        XCTAssertEqual(reader.notices(), [])
    }

    // MARK: What is never opened

    /// Only web pages and email addresses. A script, a file, data, a telephone number, an app's
    /// own scheme, a web address with no host and one with no scheme are neither asked about,
    /// opened nor given to a host that takes links, whichever it chose; the reader says so.
    func testOtherSchemesAreNeverOpenedOrPassedOn() async throws {
        let reader = try await open()
        let canvas = try canvas(reader)
        let handed = Handed()
        let others = ["javascript:alert(1)", "JavaScript:void(0)", "file:///etc/hosts", "data:text/html,<p>x</p>",
                      "tel:+15555550100", "shortcuts://run-shortcut?name=x", "https:example.invalid", "http://",
                      "//example.invalid/page", "mailto:", "../../outside.xhtml"]
        for links in [EPUBExternalLinks.ask, .handle { handed.urls.append($0) }] {
            try await use(links, in: reader)
            let count = reader.events.count
            for href in others {
                reader.session.canvas(canvas, didActivate: .external(href), at: .init(section: 0, offset: 0), rect: .zero)
                XCTAssertNil(canvas.linkQuestion, "\(kind(links)): \(href) is not asked about")
                XCTAssertNil(reader.session.askedLink)
            }
            XCTAssertEqual(reader.notices(since: count), Array(repeating: "This reader opens only web and email links outside the book.", count: others.count), kind(links))
        }
        XCTAssertEqual(handed.urls, [], "a host is given no other scheme")
        XCTAssertEqual(try controls(reader).opened, [])
    }

    /// The address shown is the one opened, as the system has it: an international domain name
    /// in its ASCII form, and characters that would reorder or hide it escaped.
    func testTheAddressShownIsTheOneOpenedWithNothingHiddenInIt() throws {
        let reordered = try XCTUnwrap(ExternalLinkAddress("https://example.invalid/\u{202E}gpj.exe"))
        XCTAssertEqual(reordered.shown, "https://example.invalid/%E2%80%AEgpj.exe")
        let international = try XCTUnwrap(ExternalLinkAddress("https://exämple.invalid/x"))
        XCTAssertEqual(international.shown, "https://xn--exmple-cua.invalid/x")
        XCTAssertEqual(international.url.absoluteString, international.shown)
        XCTAssertNotNil(ExternalLinkAddress("HTTPS://Example.invalid/"), "a scheme is read in any case")
        let long = try XCTUnwrap(ExternalLinkAddress("https://example.invalid/" + String(repeating: "a", count: 2_000)))
        XCTAssertEqual(long.shown.count, ExternalLinkAddress.shownLength + 1)
        XCTAssertTrue(long.shown.hasPrefix("https://example.invalid/aaa"))
        XCTAssertTrue(long.shown.hasSuffix("…"))
    }

    // MARK: What a host chooses

    /// With links outside the book turned off, every one gives the notice the reader gave before,
    /// and nothing is asked or opened.
    func testWithLinksTurnedOffTheNoticeIsUnchanged() async throws {
        let reader = try await open()
        try await use(.refuse, in: reader)
        let canvas = try canvas(reader)
        let count = reader.events.count
        for href in ["https://example.invalid/page", "mailto:reader@example.invalid", "javascript:alert(1)"] {
            reader.session.canvas(canvas, didActivate: .external(href), at: .init(section: 0, offset: 0), rect: .zero)
        }
        XCTAssertEqual(reader.notices(since: count), Array(repeating: "This reader does not open links outside the book.", count: 3))
        XCTAssertEqual(reader.events.count, count + 3, "a refused link does nothing else: \(reader.events.dropFirst(count))")
        XCTAssertNil(canvas.linkQuestion)
        XCTAssertEqual(try controls(reader).opened, [])
        // Turned on again on the same reader, it asks again.
        try await use(.ask, in: reader)
        reader.session.canvas(canvas, didActivate: .external("https://example.invalid/again"), at: .init(section: 0, offset: 0), rect: .zero)
        try await assertAsked("https://example.invalid/again", in: reader)
        try answer(false, in: reader)
        try await waitUntilAnswered(reader)
    }

    /// A host that takes links is given each web or email address at once, with no question, and
    /// the reader opens nothing itself.
    func testAHostThatTakesLinksIsGivenTheAddressWithoutAQuestion() async throws {
        let reader = try await open()
        let handed = Handed()
        try await use(.handle { handed.urls.append($0) }, in: reader)
        let found = try link("https://example.invalid/page?q=1", in: reader)
        try canvas(reader).activateLink(found.url, range: found.range, in: found.view)
        reader.session.canvas(try canvas(reader), didActivate: .external("mailto:reader@example.invalid"), at: .init(section: 0, offset: 0), rect: .zero)
        XCTAssertEqual(handed.urls.map(\.absoluteString), ["https://example.invalid/page?q=1", "mailto:reader@example.invalid"])
        XCTAssertNil(try canvas(reader).linkQuestion)
        XCTAssertEqual(try controls(reader).opened, [])
        XCTAssertEqual(reader.notices(), [])
    }

    // MARK: One question at a time

    /// A second link while the first is asked about replaces the question; the first is answered
    /// no. Closing the reader takes a question away, and nothing opens after it.
    func testASecondLinkReplacesTheQuestionAndClosingTakesItAway() async throws {
        let reader = try await open()
        let canvas = try canvas(reader)
        reader.session.canvas(canvas, didActivate: .external("https://example.invalid/first"), at: .init(section: 0, offset: 0), rect: .zero)
        try await assertAsked("https://example.invalid/first", in: reader)
        let first = try XCTUnwrap(canvas.linkQuestion?.shown)
        reader.session.canvas(canvas, didActivate: .external("https://example.invalid/second"), at: .init(section: 0, offset: 0), rect: .zero)
        try await assertAsked("https://example.invalid/second", in: reader)
        // The first question's own answer, late, opens nothing.
        canvas.answerLinkQuestion(true, to: first)
        XCTAssertEqual(reader.session.askedLink?.url.absoluteString, "https://example.invalid/second")
        try answer(true, in: reader)
        try await waitUntilAnswered(reader)
        XCTAssertEqual(try controls(reader).opened.map(\.absoluteString), ["https://example.invalid/second"])

        reader.session.canvas(canvas, didActivate: .external("https://example.invalid/third"), at: .init(section: 0, offset: 0), rect: .zero)
        try await assertAsked("https://example.invalid/third", in: reader)
        let third = try XCTUnwrap(canvas.linkQuestion?.shown)
        #if os(macOS)
        let window = try XCTUnwrap(reader.window?.window)
        #endif
        reader.session.close()
        XCTAssertNil(canvas.linkQuestion)
        XCTAssertNil(reader.session.askedLink)
        #if os(macOS)
        XCTAssertNil(window.attachedSheet, "the sheet is gone with the reader")
        #endif
        canvas.answerLinkQuestion(true, to: third)
        XCTAssertEqual(try controls(reader).opened.count, 1, "nothing opens for a closed reader")
    }

    #if os(iOS)
    // MARK: VoiceOver's cursor after the question

    /// #793: as the alert went, VoiceOver took the screen's first item, a control of the host,
    /// though the link's element was still listed. After Cancel the cursor goes back to the item
    /// it was on when the question was asked: named with a screen change as the answer comes,
    /// and put back when VoiceOver comes to another item after it, or, with no item told of
    /// within a second, when it is still elsewhere then. After Open it is
    /// left to whatever was opened. Where VoiceOver comes back to the link by itself, nothing is
    /// done. VoiceOver's cursor is the canvas's to ask, so a test can say where it is.
    func testCancelPutsVoiceOversCursorBackOnTheLink() async throws {
        let reader = try await open()
        let canvas = try canvas(reader)
        let found = try link("https://example.invalid/page?q=1", in: reader)
        let elements = try XCTUnwrap(found.view.accessibilityElements as? [UIAccessibilityElement])
        let element = try XCTUnwrap(elements.first { $0.accessibilityTraits.contains(.link) && $0.accessibilityLabel == "the site" })
        let elsewhere = UIAccessibilityElement(accessibilityContainer: found.view)
        var cursor: NSObject = element
        canvas.voiceOverCursor = { cursor }
        var posted: [(name: UIAccessibility.Notification, item: AnyObject?)] = []
        canvas.postAccessibilityNotification = { name, item in posted.append((name, item.map { $0 as AnyObject })) }
        func backOnTheLink() -> Int { posted.filter { $0.name == .layoutChanged && $0.item === element }.count }
        func focus(_ item: NSObject?) {
            NotificationCenter.default.post(name: UIAccessibility.elementFocusedNotification, object: nil,
                                            userInfo: item.map { [UIAccessibility.focusedElementUserInfoKey: $0] } ?? [:])
        }
        func ask() async throws {
            cursor = element // VoiceOver activates the link it is on.
            XCTAssertTrue(element.accessibilityActivate())
            try await assertAsked("https://example.invalid/page?q=1", in: reader)
            cursor = elsewhere // VoiceOver is in the alert now.
        }

        // The link is named as the answer comes; VoiceOver comes to the host's first control
        // all the same: the cursor is put back, once.
        try await ask()
        try answer(false, in: reader)
        XCTAssertTrue(posted.contains { $0.name == .screenChanged && $0.item === element }, "\(posted)")
        focus(nil) // A move's first notification names only the item left.
        XCTAssertEqual(backOnTheLink(), 0)
        focus(elsewhere)
        XCTAssertEqual(backOnTheLink(), 1)
        focus(elsewhere)
        XCTAssertEqual(backOnTheLink(), 1, "only the first item VoiceOver comes to is put right")

        // VoiceOver comes back to the link itself: nothing more.
        try await ask()
        let before = posted.count
        try answer(false, in: reader)
        focus(element)
        try await TestDeadline.pause(.milliseconds(1_300))
        XCTAssertFalse(posted.dropFirst(before).contains { $0.name == .layoutChanged }, "\(posted.dropFirst(before))")

        // VoiceOver tells of no item, and its cursor is elsewhere a second later.
        try await ask()
        try answer(false, in: reader)
        try await reader.wait("the cursor put back after a second") { backOnTheLink() == 2 }

        // Open: the cursor is left to what was opened.
        try await ask()
        try answer(true, in: reader)
        focus(elsewhere)
        try await TestDeadline.pause(.milliseconds(1_300))
        XCTAssertEqual(backOnTheLink(), 2)
        XCTAssertEqual(try controls(reader).opened, [URL(string: "https://example.invalid/page?q=1")!])
    }
    #endif
}
