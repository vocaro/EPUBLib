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

/// What the text views give an assistive technology of the host's highlights
/// ([#682](https://github.com/vocaro/EPUBLib/issues/682)): on UIKit each item's value names the
/// highlights over its words, and a Highlights rotor moves between them through the book; on
/// AppKit the highlighted characters are marked in the rich text a client reads, and a
/// Highlights rotor lists them by style and words. API level only: no assistive technology is
/// driven ([VoiceOver testing](doc/testing.md#voiceover-testing) has what VoiceOver said).
@MainActor final class HighlightAccessibilityTests: XCTestCase {
    private var readers: [Reader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    @MainActor private final class Events {
        var all: [EPUBReaderEvent] = []
    }

    @MainActor private final class Reader {
        let session: NativeSession
        let window: ReaderTestWindow
        let events: Events
        init(session: NativeSession, window: ReaderTestWindow, events: Events) {
            self.session = session; self.window = window; self.events = events
        }
        var canvas: ReaderCanvasView { session.canvas! }
        var selections: [EPUBSelection] {
            events.all.compactMap { event -> EPUBSelection? in
                if case .selectionChanged(let value) = event { return value }
                return nil
            }
        }
        func close() { session.close(); window.close() }

        func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { throw SessionCoverageTimeout(description: "Timed out waiting for \(label)") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// The location the reader reports for `text`, selected where it is found: a host's
        /// saved highlight.
        func location(of text: String) async throws -> EPUBLocation {
            let before = selections.count
            try await session.send(.locate(text: text, highlight: true))
            try await wait("the selection of \(text)") { selections.count > before && selections.last?.text == text }
            return selections.last!.location
        }

        /// Highlights each passage in its style, and shows the book's opening again, nothing
        /// selected.
        func highlight(_ passages: [(text: String, style: EPUBHighlightStyle)], thenShow href: String = "OPS/one.xhtml") async throws {
            var highlights: [EPUBHighlight] = []
            for (index, passage) in passages.enumerated() {
                highlights.append(EPUBHighlight(id: "h\(index)", location: try await location(of: passage.text), style: passage.style))
            }
            try await session.send(.setHighlights(highlights))
            try await wait("every highlight drawn") { Set(session.drawnHighlights.filter { $0.kind == .annotation }.map(\.id)).count == passages.count }
            try await session.send(.navigate(href: href))
            try await wait("the opening") { session.visibleRange?.start.section == 0 && session.visibleRange?.start.offset == 0 }
        }
    }

    private func open(_ data: Data, flow: EPUBReadingFlow = .paginated, size: CGSize) async throws -> Reader {
        let publication = try EPUBPublication.open(data: data)
        let events = Events()
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { event in
            events.all.append(event)
        } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        window.resize(to: size)
        let opened = Reader(session: session, window: window, events: events)
        readers.append(opened)
        try await opened.wait("the reader") { session.isReady && session.book.isComplete && session.lastLocation != nil }
        try await session.send(.style(.init(appearance: .light, flow: flow)))
        try await opened.wait("the flow") { session.canvas?.configuration.flow == flow && !(session.canvas?.textViews.isEmpty ?? true) }
        return opened
    }

    private func chapter(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Marks</title></head><body>\(body)</body></html>"
    }

    private func filler(_ count: Int, _ name: String) -> String {
        (1...count).map { "<p>Filler \(name) line \($0) of ordinary reading text.</p>" }.joined()
    }

    /// Four passages on the first page, and two far beyond it: one pages later in the first
    /// chapter, one in the second.
    private var book: Data {
        get throws {
            try Fixture.epub(overrides: [
                "OPS/one.xhtml": chapter("<h1 id=\"start\">Marks</h1><p>Amber words stand here.</p><p>Fern words stand here.</p>"
                    + "<p>Sky words stand here.</p><p>Rose words rest there.</p>" + filler(80, "first")
                    + "<p>Distant words stand here.</p>" + filler(10, "late")),
                "OPS/two.xhtml": chapter("<h1>Second</h1><p>Chapter words stand here.</p>" + filler(10, "second")),
            ])
        }
    }

    /// The styles of the first page: a whole line, part of one, two on one line, and a line
    /// with none.
    private let firstPage: [(text: String, style: EPUBHighlightStyle)] = [
        ("Amber words stand here.", .init(color: .yellow)),
        ("Sky words", .init(color: .blue, mark: .underline)),
        ("Rose", .init(color: .pink, mark: .dottedUnderline)),
        ("rest there.", .init(color: .purple)),
    ]

    private var onePage: CGSize {
        #if os(macOS)
        CGSize(width: 600, height: 700)
        #else
        CGSize(width: 390, height: 844)
        #endif
    }

    func testAHighlightIsNamedByItsStyleInEveryAppearanceOfItsName() {
        XCTAssertEqual(EPUBHighlightColor.allCases.map { EPUBHighlightStyle(color: $0).spokenName },
                       ["Yellow highlight", "Green highlight", "Blue highlight", "Pink highlight", "Purple highlight"])
        XCTAssertEqual(EPUBHighlightStyle(color: .green, mark: .dashedUnderline).spokenName, "Green highlight", "the mark stands for the color")
        XCTAssertEqual(EPUBHighlightMark.allCases.map(\.name), ["Underline", "Double underline", "Dotted underline", "Dashed underline"])
    }

    #if os(iOS)
    // MARK: UIKit

    /// Every line and cell VoiceOver is given, tables' cells in place of their tables.
    private func items(of view: ReaderTextView) -> [UIAccessibilityElement] {
        (view.accessibilityElements ?? []).flatMap { item -> [UIAccessibilityElement] in
            guard let element = item as? UIAccessibilityElement else { return [] }
            if let cells = element.accessibilityElements as? [UIAccessibilityElement], !cells.isEmpty { return cells }
            return [element]
        }
    }

    private func words(_ element: UIAccessibilityElement) -> String {
        (element.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func item(_ prefix: String, in view: ReaderTextView) throws -> UIAccessibilityElement {
        try XCTUnwrap(items(of: view).first { words($0).hasPrefix(prefix) }, "\(prefix) is listed")
    }

    /// The item the view's Highlights rotor gives with VoiceOver's cursor on `element` (on none
    /// of the view's items when nil), asked twice from the same item, as VoiceOver asks.
    private func rotorItem(from element: UIAccessibilityElement?, in view: ReaderTextView, forward: Bool,
                           file: StaticString = #filePath, line: UInt = #line) throws -> UIAccessibilityElement? {
        let rotor = try XCTUnwrap(view.accessibilityCustomRotors?.first { $0.name == "Highlights" }, "the Highlights rotor", file: file, line: line)
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = forward ? .next : .previous
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: element ?? view, targetRange: nil)
        let first = rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement
        let second = rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement
        XCTAssertTrue(first === second, "asked again: \(first.map(words) ?? "none"), then \(second.map(words) ?? "none")", file: file, line: line)
        return first
    }

    /// An item says after its words which highlights are over them: a whole line's by its
    /// style's name, part of one by its name and the words it covers, and two on one line each
    /// in turn. The value follows the highlights as they change, on the same item.
    func testAnItemSaysWhichHighlightsAreOverItsWords() async throws {
        let reader = try await open(try book, size: onePage)
        let view = try XCTUnwrap(reader.canvas.textViews.first)
        XCTAssertNil(try item("Amber", in: view).accessibilityValue, "nothing before the host highlights")
        try await reader.highlight(firstPage)
        let column = try XCTUnwrap(reader.canvas.textViews.first)
        XCTAssertEqual(try item("Amber", in: column).accessibilityValue, "Yellow highlight")
        XCTAssertNil(try item("Fern", in: column).accessibilityValue)
        XCTAssertEqual(try item("Sky", in: column).accessibilityValue, "Blue highlight: Sky words")
        XCTAssertEqual(try item("Rose", in: column).accessibilityValue, "Pink highlight: Rose, Purple highlight: rest there.")
        XCTAssertNil(try item("Marks", in: column).accessibilityValue, "the heading has none")
        XCTAssertEqual(try item("Sky", in: column).accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines), "Sky words stand here.",
                       "the words are the line's own")

        let amber = try item("Amber", in: column)
        let saved = reader.session.drawnHighlights.first { $0.id == "h0" }!
        reader.canvas.setHighlights([ReaderHighlight(id: "h0", range: saved.range, kind: .annotation, style: .init(color: .green, mark: .underline))])
        XCTAssertEqual(amber.accessibilityValue, "Green highlight", "asked each time it is read")
        reader.canvas.setHighlights([ReaderHighlight(id: "s", range: saved.range, kind: .search)])
        XCTAssertNil(amber.accessibilityValue, "a search match is no host highlight")
        reader.canvas.setHighlights([])
        XCTAssertNil(amber.accessibilityValue)
    }

    /// The rotor is there while a host highlight is drawn, and moves from highlight to
    /// highlight through the book, a page turned or a chapter shown for each one elsewhere, and
    /// back again; one item is one stop, however many highlights begin in it.
    func testTheHighlightsRotorMovesBetweenHighlightsThroughTheBook() async throws {
        let reader = try await open(try book, size: onePage)
        var view = try XCTUnwrap(reader.canvas.textViews.first)
        XCTAssertFalse(view.accessibilityCustomRotors?.contains { $0.name == "Highlights" } ?? false, "no rotor without highlights")
        try await reader.highlight(firstPage + [("Distant words stand here.", .init(color: .green, mark: .doubleUnderline)),
                                                ("Chapter words", .init(color: .yellow, mark: .dashedUnderline))])
        view = try XCTUnwrap(reader.canvas.textViews.first)
        XCTAssertEqual(view.accessibilityCustomRotors?.map(\.systemRotorType), [.heading, .none, .none], "the Headings rotor, then two of the reader's own")
        XCTAssertEqual(view.accessibilityCustomRotors?.dropFirst().map(\.name), ["Paragraphs", "Highlights"])
        let heading = try item("Marks", in: view)
        var heard: [String] = [], cursor: UIAccessibilityElement = heading
        while let next = try rotorItem(from: cursor, in: try XCTUnwrap(cursor.accessibilityContainer as? ReaderTextView), forward: true) {
            let column = try XCTUnwrap(next.accessibilityContainer as? ReaderTextView)
            XCTAssertTrue(reader.canvas.textViews.contains { $0 === column }, "\(words(next)) is on the page now shown")
            XCTAssertNotEqual(column.index(ofAccessibilityElement: next), NSNotFound)
            heard.append("\(words(next)) | \(next.accessibilityValue ?? "")")
            cursor = next
            XCTAssertLessThan(heard.count, 10)
        }
        XCTAssertEqual(heard, ["Amber words stand here. | Yellow highlight", "Sky words stand here. | Blue highlight: Sky words",
                               "Rose words rest there. | Pink highlight: Rose, Purple highlight: rest there.",
                               "Distant words stand here. | Green highlight", "Chapter words stand here. | Yellow highlight: Chapter words"])
        XCTAssertEqual(reader.session.visibleRange?.start.section, 1, "the reader shows the second chapter")
        var back: [String] = []
        while let previous = try rotorItem(from: cursor, in: try XCTUnwrap(cursor.accessibilityContainer as? ReaderTextView), forward: false) {
            back.append(words(previous))
            cursor = previous
            XCTAssertLessThan(back.count, 10)
        }
        XCTAssertEqual(back, ["Distant words stand here.", "Rose words rest there.", "Sky words stand here.", "Amber words stand here."])
        XCTAssertEqual(reader.session.visibleRange?.start.offset, 0, "back on the first page")
        // From none of the lines: the first highlight, or the last.
        let first = try XCTUnwrap(reader.canvas.textViews.first)
        XCTAssertEqual(try rotorItem(from: nil, in: first, forward: true).map(words), "Amber words stand here.")
    }

    /// In continuous scroll the rotor scrolls to a highlight below the screen.
    func testTheHighlightsRotorScrollsToAHighlightBelowTheScreen() async throws {
        let reader = try await open(try book, flow: .scrolled, size: onePage)
        try await reader.highlight([("Amber words stand here.", .init(color: .yellow)),
                                    ("Distant words stand here.", .init(color: .green, mark: .underline))])
        let view = try XCTUnwrap(reader.canvas.scrollTextView)
        let amber = try item("Amber", in: view)
        XCTAssertEqual(amber.accessibilityValue, "Yellow highlight")
        let distant = try XCTUnwrap(try rotorItem(from: amber, in: view, forward: true))
        XCTAssertEqual(words(distant), "Distant words stand here.")
        XCTAssertEqual(distant.accessibilityValue, "Green highlight")
        let visible = try XCTUnwrap(reader.session.visibleRange)
        XCTAssertGreaterThan(visible.start.offset, 0, "the reader scrolled to it")
        XCTAssertTrue(try rotorItem(from: distant, in: view, forward: false).map(words) == "Amber words stand here.")
    }

    /// A cell of a table of data says it is highlighted, and the rotor stops on it.
    func testACellOfATableOfDataSaysItIsHighlightedAndTheRotorStopsOnIt() async throws {
        let table = chapter("""
            <h1 id="start">Marks</h1><p>Words before the table.</p>
            <table><thead><tr><th>Grain</th><th>Count</th></tr></thead>
            <tbody><tr><td>Barley</td><td>Forty two</td></tr><tr><td>Oats</td><td>Seven</td></tr></tbody></table>
            <p>Words after the table.</p>
            """)
        let reader = try await open(try Fixture.epub(overrides: ["OPS/one.xhtml": table]), size: onePage)
        try await reader.highlight([("Forty two", .init(color: .green, mark: .underline)), ("Seven", .init(color: .pink))])
        let view = try XCTUnwrap(reader.canvas.textViews.first)
        let forty = try item("Forty two", in: view)
        XCTAssertEqual(forty.accessibilityValue, "Green highlight")
        XCTAssertEqual(try item("Seven", in: view).accessibilityValue, "Pink highlight")
        XCTAssertNil(try item("Barley", in: view).accessibilityValue)
        let before = try item("Words before", in: view)
        XCTAssertTrue(try rotorItem(from: before, in: view, forward: true) === forty)
        XCTAssertEqual(try rotorItem(from: forty, in: view, forward: true).map(words), "Seven")
    }
    #endif

    #if os(macOS)
    // MARK: AppKit

    private func rotor(of view: ReaderTextView) -> NSAccessibilityCustomRotor? {
        view.accessibilityCustomRotors().first { $0.label == "Highlights" }
    }

    /// Every highlight the rotor gives, asked from nowhere and then from each result on, as
    /// VoiceOver lists a rotor's items.
    private func listed(by view: ReaderTextView, forward: Bool = true) throws -> [NSAccessibilityCustomRotor.ItemResult] {
        let rotor = try XCTUnwrap(rotor(of: view), "the Highlights rotor")
        let delegate = try XCTUnwrap(rotor.itemSearchDelegate)
        var current: NSAccessibilityCustomRotor.ItemResult?, results: [NSAccessibilityCustomRotor.ItemResult] = []
        while results.count < 20 {
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.searchDirection = forward ? .next : .previous
            parameters.currentItem = current
            guard let result = delegate.rotor(rotor, resultFor: parameters) else { break }
            results.append(result)
            current = result
        }
        return results
    }

    /// The characters a host highlight covers are highlighted text in the rich text an
    /// assistive client reads, on its background, and nothing else is.
    func testHighlightedCharactersAreMarkedInTheRichTextAClientReads() async throws {
        let reader = try await open(try book, size: onePage)
        try await reader.highlight(firstPage)
        let view = try XCTUnwrap(reader.canvas.textViews.first)
        let text = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        var marked: [String] = []
        text.enumerateAttribute(.accessibilityHighlightedText, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value as? Bool == true else { return }
            marked.append((text.string as NSString).substring(with: range))
            XCTAssertNotNil(text.attribute(.accessibilityTextBackground, at: range.location, effectiveRange: nil))
        }
        XCTAssertEqual(marked, ["Amber words stand here.", "Sky words", "Rose", "rest there."])
        reader.canvas.setHighlights([])
        let plain = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        var any = false
        plain.enumerateAttribute(.accessibilityHighlightedText, in: NSRange(location: 0, length: plain.length)) { value, _, _ in if value != nil { any = true } }
        XCTAssertFalse(any, "nothing once the highlights are gone")
    }

    /// The rotor is there while a host highlight is drawn, and lists every highlight of the
    /// book in order by its style and words, either way: those on the page as the column and
    /// their characters, any other as a token, which VoiceOver has the reader load, and the
    /// reader turns to its page then and not before.
    func testTheHighlightsRotorListsTheBooksHighlightsAndTurnsToOneOnAnotherPage() async throws {
        let reader = try await open(try book, size: onePage)
        var view = try XCTUnwrap(reader.canvas.textViews.first)
        XCTAssertNil(rotor(of: view), "no rotor without highlights")
        try await reader.highlight(firstPage + [("Distant words stand here.", .init(color: .green, mark: .doubleUnderline)),
                                                ("Chapter words", .init(color: .yellow, mark: .dashedUnderline))])
        view = try XCTUnwrap(reader.canvas.textViews.first)
        let shown = reader.session.visibleRange
        let results = try listed(by: view)
        XCTAssertEqual(results.map(\.customLabel), ["Yellow highlight: Amber words stand here.", "Blue highlight: Sky words", "Pink highlight: Rose",
                                                    "Purple highlight: rest there.", "Green highlight: Distant words stand here.",
                                                    "Yellow highlight: Chapter words"])
        XCTAssertEqual(reader.session.visibleRange, shown, "listing shows nothing")
        let text = view.contentStorage.textStorage?.string as NSString? ?? ""
        for result in results.prefix(4) {
            XCTAssertTrue(result.targetElement === view, "\(result.customLabel ?? ""): on the page")
            XCTAssertNil(result.itemLoadingToken)
            XCTAssertTrue((result.customLabel ?? "").hasSuffix(text.substring(with: result.targetRange)), "\(result.customLabel ?? ""): its characters")
        }
        XCTAssertEqual(try listed(by: view, forward: false).map(\.customLabel), Array(results.map(\.customLabel).reversed()))
        let distant = results[4]
        let token = try XCTUnwrap(distant.itemLoadingToken, "a token for a highlight on another page")
        XCTAssertNil(distant.targetElement)
        let loaded = try XCTUnwrap(view.accessibilityElement(withToken: token) as? ReaderTextView, "the column that shows it")
        let range = view.accessibilityRangeInTargetElement(withToken: token)
        XCTAssertEqual((loaded.contentStorage.textStorage?.string as NSString?)?.substring(with: range), "Distant words stand here.")
        XCTAssertNotEqual(reader.session.visibleRange, shown, "the reader turned to its page")
        // From a place on the page: the next one after it.
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        let current = NSAccessibilityCustomRotor.ItemResult(targetElement: loaded)
        current.targetRange = range
        parameters.currentItem = current
        XCTAssertEqual(try XCTUnwrap(rotor(of: loaded)?.itemSearchDelegate).rotor(try XCTUnwrap(rotor(of: loaded)), resultFor: parameters)?.customLabel,
                       "Yellow highlight: Chapter words")
    }

    /// In continuous scroll the scroll view gives every highlight of the book as its own
    /// characters.
    func testTheHighlightsRotorOfContinuousScrollGivesTheScrollViewsOwnCharacters() async throws {
        let reader = try await open(try book, flow: .scrolled, size: onePage)
        try await reader.highlight([("Amber words stand here.", .init(color: .yellow)),
                                    ("Chapter words", .init(color: .pink, mark: .underline))])
        let view = try XCTUnwrap(reader.canvas.scrollTextView)
        try await reader.wait("the whole book in the scroll view") { reader.canvas.scrollBook != nil }
        let results = try listed(by: view)
        XCTAssertEqual(results.map(\.customLabel), ["Yellow highlight: Amber words stand here.", "Pink highlight: Chapter words"])
        let text = view.contentStorage.textStorage?.string as NSString? ?? ""
        for result in results {
            XCTAssertTrue(result.targetElement === view)
            XCTAssertTrue((result.customLabel ?? "").hasSuffix(text.substring(with: result.targetRange)), result.customLabel ?? "")
        }
    }
    #endif
}
