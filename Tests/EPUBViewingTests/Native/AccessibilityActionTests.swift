#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// What each item of a page or a screen offers an assistive technology on iPhone and iPad, in
/// pages and in continuous scroll (doc/native-viewer.md, "Input and accessibility").
///
/// VoiceOver offers on an item its own custom actions and then those of everything that
/// contains it, so whatever a container offers is repeated on every line inside it. A line
/// offers its page turns in pages and nothing in continuous scroll; an image also its own
/// inspection; a table row also what its own cells can do; a link is followed by activating
/// it; and nothing that contains them offers anything.
///
/// No assistive technology is driven here, and UIKit's accessibility is not loaded in a test
/// host: UIKit gives a text view no actions of its own, so a test that holds a text view to
/// passing none on gives it one first, through the setter. The reader is mounted as an app
/// mounts it, in the public SwiftUI view, and the tests read the actions of every view above
/// a line; what SwiftUI's own accessibility elements offer is known only from
/// [speech sessions](doc/voiceover-testing.md).
@MainActor final class AccessibilityActionTests: XCTestCase {
    private typealias Subject = (reader: SessionCoverageReader, canvas: ReaderCanvasView, view: ReaderTextView)
    private var readers: [SessionCoverageReader] = []
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private static let square = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"#07c\"/></svg>"

    /// Every kind of item on one page and one screen: lines of words, a link inside a line, a
    /// picture with words, one without and one marked as decoration, a picture that is a link,
    /// and a table row with a link in a cell. The chapter goes on for some screens, so the
    /// links' target is not on screen with them.
    private static func book() throws -> EPUBPublication {
        try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("offers", """
                <h1>What each line offers</h1><p>Plain words above.</p>\
                <p>Words before <a href="notes.xhtml">Lone jump</a> words after.</p>\
                <p>Described picture <img src="square.svg" alt="Square with words"/> ends its line.</p>\
                <p>Nameless picture <img src="square.svg"/> ends its line.</p>\
                <p>Decoration <img src="square.svg" alt=""/> passed over.</p>\
                <p><a href="notes.xhtml"><img src="square.svg" alt="Pictured jump"/></a></p>\
                <table><tr><td>Left cell</td><td><a href="notes.xhtml">Right cell jump</a></td></tr></table>\
                <p>Plain words below.</p>
                """ + SessionCoverageBook.filler(120), title: "Offers"),
            SessionCoverageBook.Section("notes", "<h1>Notes</h1><p>The linked note.</p>", title: "Notes")],
            manifest: "<item id=\"square\" href=\"square.svg\" media-type=\"image/svg+xml\"/>", files: ["OPS/square.svg": square]))
    }

    /// A reader on the book's first section, in pages or in continuous scroll, and the text
    /// view that lists its lines, once the cells on screen have their text views.
    private func reader(_ publication: EPUBPublication, scrolled: Bool) async throws -> Subject {
        let reader = try SessionCoverageReader(publication: publication)
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        if scrolled {
            try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
            try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
            try await reader.settle()
        }
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(scrolled ? canvas.scrollTextView : canvas.textViews.first { !$0.isHidden })
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.isEmpty == false }
        return (reader, canvas, view)
    }

    private func listed(_ view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws -> [UIAccessibilityElement] {
        XCTAssertFalse(view.isAccessibilityElement, "the text view is a container of its lines", file: file, line: line)
        return try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement], "the text view lists no lines", file: file, line: line)
    }

    /// An element's words, without the break that ends its paragraph.
    private func words(_ element: UIAccessibilityElement) -> String {
        (element.accessibilityLabel ?? "").trimmingCharacters(in: .newlines)
    }

    /// What VoiceOver offers on `element`: its own actions, then those of everything that
    /// contains it, as far as the window.
    private func offered(on element: UIAccessibilityElement) -> [String] {
        var names = (element.accessibilityCustomActions ?? []).map(\.name)
        var container = element.accessibilityContainer as? UIView
        while let view = container {
            names += (view.accessibilityCustomActions ?? []).map(\.name)
            container = view.superview
        }
        return names
    }

    private func perform(_ name: String, on element: UIAccessibilityElement, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let action = try XCTUnwrap(element.accessibilityCustomActions?.first { $0.name == name }, "no action \(name)", file: file, line: line)
        return try XCTUnwrap(action.actionHandler, file: file, line: line)(action)
    }

    func testEachItemOffersItsOwnActionsAndNothingThatContainsItOffersAny() async throws {
        let book = try Self.book()
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (reader, canvas, view) = try await reader(book, scrolled: scrolled)
            let elements = Array(try listed(view).prefix(15))
            XCTAssertEqual(elements.map(words), [
                "What each line offers", "Plain words above.", "Words before ", "Lone jump", " words after.",
                "Described picture ", "Square with words", " ends its line.", "Nameless picture ", "", " ends its line.",
                "Decoration  passed over.", "Pictured jump", "Left cell\tRight cell jump", "Plain words below."], flow)
            let link = elements[3], described = elements[6], nameless = elements[9], pictured = elements[12], row = elements[13]
            XCTAssertEqual(link.accessibilityTraits, .link, flow)
            XCTAssertEqual(described.accessibilityTraits, [.staticText, .image], flow)
            XCTAssertEqual(nameless.accessibilityTraits, [.staticText, .image], flow)
            XCTAssertNil(nameless.accessibilityLabel, flow)
            XCTAssertEqual(pictured.accessibilityTraits, [.link, .image], flow)

            // A line turns its page, and in continuous scroll offers nothing. An image also
            // offers its own inspection and a row what its own cells can do; a line with
            // decoration in it, and a link, offer no more than a line.
            let turns = scrolled ? [] : ["Next Page", "Previous Page"]
            let own = [6: ["Inspect Image: Square with words"], 9: ["Inspect Image"], 12: ["Inspect Image: Pictured jump"],
                       13: ["Select Table Text: Left cell", "Select Table Text: Right cell jump", "Follow Table Link: Right cell jump"]]
            for (index, element) in elements.enumerated() {
                XCTAssertEqual(offered(on: element), turns + (own[index] ?? []), "\(flow): \(words(element))")
            }
            // In continuous scroll a line has no actions at all, not an empty list of them.
            if scrolled { XCTAssertNil(elements[1].accessibilityCustomActions, flow) }

            // The text view passes on nothing while it lists its lines, whatever it holds:
            // VoiceOver would offer it on every one of them.
            view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Held by the text view") { _ in true }]
            XCTAssertNil(view.accessibilityCustomActions, flow)
            XCTAssertEqual(offered(on: elements[1]), turns, flow)
            view.accessibilityCustomActions = nil

            // Each does what it says. An image is inspected by its action and by activating it.
            XCTAssertNil(canvas.imageInspector, flow)
            XCTAssertTrue(try perform("Inspect Image", on: nameless), flow)
            XCTAssertNotNil(canvas.imageInspector, flow)
            canvas.imageInspector?.close()
            XCTAssertTrue(described.accessibilityActivate(), flow)
            XCTAssertNotNil(canvas.imageInspector, flow)
            canvas.imageInspector?.close()
            XCTAssertFalse(elements[1].accessibilityActivate(), "\(flow): a line opens nothing")
            XCTAssertNil(canvas.imageInspector, flow)
            // A picture that is a link is inspected by its action and followed by activating it.
            XCTAssertTrue(try perform("Inspect Image: Pictured jump", on: pictured), flow)
            XCTAssertNotNil(canvas.imageInspector, flow)
            canvas.imageInspector?.close()
            XCTAssertTrue(try perform("Select Table Text: Left cell", on: row), flow)
            try await reader.wait("\(flow): the cell's words selected") { reader.session.selection?.text == "Left cell" }
            canvas.clearSelection()
            let linked = ReaderTextPosition(section: 1, offset: 0)
            XCTAssertFalse(reader.isVisible(linked), "\(flow): the link's target must be off screen for this to show anything")
            XCTAssertTrue(link.accessibilityActivate(), flow)
            try await reader.wait("\(flow): the linked chapter") { reader.isVisible(linked) }
        }
    }

    /// A page turn asked for by name is a command, as a host's is: selected text holds back a
    /// tap or a swipe, which could be meant for the selection, and not this. Nothing else
    /// offers the turn now, so a turn that selected text held back could not be made at all.
    func testALinesPageTurnIsNotHeldBackBySelectedTextAndFailsAtTheEndsOfTheBook() async throws {
        let host = CanvasHost(FakeCanvasSource([CanvasText.body(CanvasText.sentence(700, seed: 5))]), size: CGSize(width: 420, height: 350))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        var view = try XCTUnwrap(host.canvas.textViews.first)
        var line = try XCTUnwrap(try listed(view).first)
        XCTAssertFalse(try perform("Previous Page", on: line), "the book's first page has none before it")
        XCTAssertEqual(view.placement.offset, 0)

        view.selectedRange = NSRange(location: 0, length: 6)
        host.canvas.textViewSelectionDidChange(view)
        try await host.settle()
        XCTAssertTrue(host.canvas.hasSelection)
        host.canvas.turnPageFromInput(forward: true)
        XCTAssertEqual(view.placement.offset, 0, "a key, a tap or a swipe is held back while text is selected")
        XCTAssertTrue(try perform("Next Page", on: line))
        view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertGreaterThan(view.placement.offset, 0, "the action turned the page")

        host.canvas.clearSelection()
        var turned = 1
        while turned < 200, host.canvas.turnPage(forward: true) == .turned { turned += 1 }
        view = try XCTUnwrap(host.canvas.textViews.first)
        line = try XCTUnwrap(try listed(view).first)
        let last = view.placement.offset
        XCTAssertFalse(try perform("Next Page", on: line), "the book's last page has none after it")
        XCTAssertEqual(host.canvas.textViews.first?.placement.offset, last)
    }

    /// A note's text view lists no lines: it keeps UIKit's own elements and passes on what
    /// UIKit holds for them. It has no canvas to inspect an image in, so it offers no
    /// inspection, which could not be performed.
    func testANotesTextViewKeepsWhatUIKitOffersAndAddsNothing() throws {
        let text = NSMutableAttributedString(attributedString: CanvasText.body("A note with a picture "))
        text.append(CanvasText.attachment(size: CGSize(width: 20, height: 20)))
        let note = ReaderNoteViewController(text: text, dark: false, width: 320)
        note.loadViewIfNeeded()
        let view = note.textView
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        XCTAssertNil(view.canvas)
        XCTAssertEqual((view.accessibilityCustomActions ?? []).map(\.name), [], "nothing of the reader's")
        view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Held by the text view") { _ in true }]
        XCTAssertEqual((view.accessibilityCustomActions ?? []).map(\.name), ["Held by the text view"])
    }
}
#endif
