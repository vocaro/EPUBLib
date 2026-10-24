#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// What selecting a passage of the book's text by the accessibility actions of its lines does
/// on iPhone and iPad, in pages and in continuous scroll: VoiceOver cannot select the reader's
/// text as it does a text view's, so a line offers to select itself, to add itself to the
/// selection, and to move either end of the selection by a word; and a line that holds some
/// of the selection offers what the edit menu offers a touch's (doc/native-viewer.md, "Text
/// selected with VoiceOver").
///
/// The passage is the one DAISY's Non-visual Reading test reading-1310 (epub30-test-0302)
/// asks to have copied with assistive technology: the 399 characters, spaces aside, between
/// "Begin" and "End", from Melville's Moby-Dick (1851), which is in the public domain. The
/// markup is the test's, the line break and spaces inside the paragraph with it.
///
/// No assistive technology is driven here. The test performs the actions an element lists and
/// takes what the reader would have VoiceOver say from the canvas instead of posting it. What
/// VoiceOver says of it in a simulator is in doc/testing.md#voiceover-testing.
@MainActor final class LineSelectActionTests: XCTestCase {
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    /// The passage, as the reader gives it: 474 characters with its spaces.
    private static let passage = "Consider the subtleness of the sea; how its most dreaded creatures glide under water, "
        + "unapparent for the most part, and treacherously hidden beneath the loveliest tints of azure. Consider also the "
        + "devilish brilliance and beauty of many of its most remorseless tribes, as the dainty embellished shape of many "
        + "species of sharks. Consider, once more, the universal cannibalism of the sea; all whose creatures prey upon "
        + "each other, carrying on eternal war since the world began."

    private static let body = """
        <p>Copy the text (399 characters) between the words "Begin" and "End" from the passage below. </p>
        <p>Begin Consider the subtleness of the sea; how its most dreaded creatures glide under water, unapparent for the most part, and treacherously hidden beneath the loveliest tints of azure. Consider also the devilish brilliance and beauty of many
              of its most remorseless tribes, as the dainty embellished shape of many species of sharks. Consider, once more, the universal cannibalism of the sea; all whose creatures prey upon each other, carrying on eternal war since the world began. </p>
        <p>End</p>
        """

    /// What the reader posts to an assistive technology, taken in UIKit's place.
    @MainActor private final class Posts {
        var all: [(notification: UIAccessibility.Notification, argument: Any?)] = []
        var said: [String] { all.filter { $0.notification == .announcement }.compactMap { ($0.argument as? NSAttributedString)?.string } }
        var changed: [UIAccessibilityElement?] { all.filter { $0.notification == .layoutChanged }.map { $0.argument as? UIAccessibilityElement } }
        init(_ canvas: ReaderCanvasView) { canvas.postToAccessibility = { [unowned self] in all.append(($0, $1)) } }
    }

    private func actions(_ element: UIAccessibilityElement) -> [String] { (element.accessibilityCustomActions ?? []).map(\.name) }

    private func perform(_ name: String, on element: UIAccessibilityElement, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(element.accessibilityCustomActions?.first { $0.name == name }, "no action \(name) on \(element.accessibilityLabel ?? "")", file: file, line: line)
        XCTAssertTrue(try XCTUnwrap(action.actionHandler, file: file, line: line)(action), name, file: file, line: line)
    }

    private func words(_ element: UIAccessibilityElement) -> String {
        (element.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A reader on the passage, in pages or in continuous scroll, in a window `size` big, with
    /// what its selection action was given.
    private func reader(scrolled: Bool, size: CGSize = CGSize(width: 402, height: 874),
                        used: @escaping @MainActor (EPUBSelection) -> Void) async throws -> (SessionCoverageReader, ReaderCanvasView) {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("passage", Self.body + SessionCoverageBook.filler(60), title: "Passage")]))
        let reader = try SessionCoverageReader(publication: publication, action: EPUBSelectionAction(title: "Use passage", perform: used))
        readers.append(reader)
        reader.window?.resize(to: size)
        try await reader.settle()
        if scrolled {
            try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
            try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
            try await reader.settle()
        }
        return (reader, try XCTUnwrap(reader.session.canvas))
    }

    /// The lines a text view lists, in reading order.
    private func lines(_ view: ReaderTextView) throws -> [UIAccessibilityElement] {
        try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement], "the text view lists no lines")
    }

    func testVoiceOverSelectsAndCopiesDAISYsPassageAsATouchSelectsIt() async throws {
        XCTAssertEqual(Self.passage.count, 474)
        XCTAssertEqual(Self.passage.filter { $0 != " " }.count, 399, "DAISY's count leaves out the spaces")
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            var used: [EPUBSelection] = []
            let (reader, canvas) = try await reader(scrolled: scrolled) { used.append($0) }
            let view = try XCTUnwrap(scrolled ? canvas.scrollTextView : canvas.textViews.first { !$0.isHidden })
            let pasteboard = UIPasteboard.withUniqueName()
            defer { UIPasteboard.remove(withName: pasteboard.name) }
            for view in canvas.textViews { view.pasteboard = pasteboard }
            let turns = scrolled ? [] : ["Next Page", "Previous Page"]

            // The passage selected by touch, and what the host is given for it: the control.
            let shown = try XCTUnwrap(view.contentStorage.textStorage?.string as NSString?)
            let start = shown.range(of: "Consider the subtleness").location, end = NSMaxRange(shown.range(of: "the world began."))
            XCTAssertNotEqual(start, NSNotFound, flow)
            view.selectedRange = NSRange(location: start, length: end - start)
            canvas.textViewSelectionDidChange(view)
            try await reader.wait("\(flow): the passage selected by touch") { reader.session.selection?.text == Self.passage }
            canvas.performSelectionAction()
            let touched = try XCTUnwrap(used.last, flow)
            XCTAssertEqual(touched.text, Self.passage, flow)
            XCTAssertEqual(touched.location.bookmark?.format, NativeEngine.bookmarkFormat, "\(flow): the passage's CFI")
            canvas.clearSelection()
            try await reader.wait("\(flow): nothing selected") { reader.session.selection == nil }
            used.removeAll()
            let offset = scrolled ? view.contentOffset : .zero

            let posts = Posts(canvas)
            let listed = try lines(view)
            let first = try XCTUnwrap(listed.first { words($0).hasPrefix("Begin Consider") }, flow)
            let last = try XCTUnwrap(listed.first { words($0).hasSuffix("the world began.") }, flow)
            let ending = try XCTUnwrap(listed.first { words($0) == "End" }, flow)
            let firstIndex = try XCTUnwrap(listed.firstIndex { $0 === first }), lastIndex = try XCTUnwrap(listed.firstIndex { $0 === last })
            XCTAssertLessThan(firstIndex + 1, lastIndex, "\(flow): the passage takes more than two lines")
            // Every line of text offers to select itself; nothing is selected to add it to.
            for line in listed { XCTAssertEqual(actions(line), turns + ["Select Line"], "\(flow): \(words(line))") }

            // Its first line selected, with the word before the passage: shown selected, said
            // so, and the line offers what a selection is for.
            try perform("Select Line", on: first)
            XCTAssertEqual(canvas.currentSelection?.text, words(first), flow)
            XCTAssertTrue(first.accessibilityTraits.contains(.selected), flow)
            XCTAssertFalse(listed[firstIndex + 1].accessibilityTraits.contains(.selected), flow)
            XCTAssertEqual(posts.changed.count, 1, flow)
            XCTAssertTrue(posts.changed.first.flatMap { $0 } === first, "\(flow): VoiceOver is told that this item changed")
            XCTAssertEqual(posts.said, [], flow)
            let selectedActions = turns + ["Deselect Text", "Copy", "Use passage", "Unselect First Word", "Unselect Last Word",
                                           "Select Previous Word", "Select Next Word"]
            XCTAssertEqual(actions(first), selectedActions, flow)
            XCTAssertEqual(actions(last), turns + ["Select Line", "Extend Selection to Line"], flow)
            XCTAssertTrue(view.isFirstResponder, "\(flow): UIKit draws the selection of the view it is in")

            // "Begin" taken out of it. The line still holds some of the selection and offers
            // the same, so VoiceOver is told nothing but the word.
            try perform("Unselect First Word", on: first)
            XCTAssertEqual(canvas.currentSelection.map { String($0.text.prefix(8)) }, "Consider", flow)
            XCTAssertEqual(posts.said, ["Begin unselected"], flow)
            XCTAssertEqual(posts.changed.count, 1, flow)

            // The passage's last line added to it: every line between is selected now, and
            // "End" is not.
            try perform("Extend Selection to Line", on: last)
            try await reader.wait("\(flow): the passage selected") { reader.session.selection?.text == Self.passage }
            XCTAssertEqual(canvas.currentSelection?.text, Self.passage, flow)
            for line in listed[firstIndex...lastIndex] { XCTAssertTrue(line.accessibilityTraits.contains(.selected), "\(flow): \(words(line))") }
            XCTAssertFalse(ending.accessibilityTraits.contains(.selected), flow)
            XCTAssertEqual(posts.changed.count, 2, flow)
            XCTAssertTrue(posts.changed.last.flatMap { $0 } === last, flow)
            XCTAssertEqual(actions(last), selectedActions, flow)
            XCTAssertEqual(actions(ending), turns + ["Select Line", "Extend Selection to Line"], flow)

            // Copied exactly, and given to the host as a touch selection of it is.
            try perform("Copy", on: last)
            XCTAssertEqual(pasteboard.string, Self.passage, flow)
            XCTAssertEqual(posts.said, ["Begin unselected", "Copied"], flow)
            try perform("Use passage", on: listed[firstIndex + 1])
            XCTAssertEqual(used, [touched], "\(flow): the same passage and CFI as for a touch selection")
            XCTAssertEqual(reader.selections().compactMap { $0 }.last, touched, flow)
            XCTAssertEqual(posts.changed.count, 2, "\(flow): neither changes what an item offers")
            if scrolled { XCTAssertEqual(view.contentOffset, offset, "\(flow): selecting scrolled nothing") }

            // Deselected from any of its lines.
            try perform("Deselect Text", on: listed[firstIndex + 1])
            try await reader.wait("\(flow): nothing selected") { reader.session.selection == nil }
            XCTAssertFalse(listed.contains { $0.accessibilityTraits.contains(.selected) }, flow)
            XCTAssertTrue(posts.changed.last.flatMap { $0 } === listed[firstIndex + 1], flow)
            XCTAssertEqual(actions(last), turns + ["Select Line"], flow)
            reader.close()
        }
    }

    /// Each end moves by a word in either direction, and says the word; a word too far, past
    /// the end of the selection or the section, is refused.
    func testEitherEndMovesByAWordAndSaysWhichWord() async throws {
        let (_, canvas) = try await reader(scrolled: false) { _ in }
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        let posts = Posts(canvas)
        let first = try XCTUnwrap(try lines(view).first { words($0).hasPrefix("Begin Consider") })
        try perform("Select Line", on: first)
        let line = try XCTUnwrap(canvas.currentSelection?.text)
        let lastWord = try XCTUnwrap(line.split(separator: " ").last.map(String.init))

        try perform("Unselect Last Word", on: first)
        XCTAssertEqual(canvas.currentSelection?.text, String(line.dropLast(lastWord.count + 1)))
        try perform("Select Next Word", on: first)
        XCTAssertEqual(canvas.currentSelection?.text, line)
        try perform("Select Next Word", on: first)
        let next = try XCTUnwrap(canvas.currentSelection?.text.dropFirst(line.count + 1))
        XCTAssertFalse(next.isEmpty)
        XCTAssertFalse(next.contains(" "), "one word more: \(next)")
        try perform("Unselect First Word", on: first)
        try perform("Select Previous Word", on: first)
        XCTAssertTrue(canvas.currentSelection?.text.hasPrefix("Begin Consider") == true)
        XCTAssertEqual(posts.said, ["\(lastWord) unselected", "\(lastWord) selected", "\(next) selected", "Begin unselected", "Begin selected"])

        // Back to the section's first word, and no further.
        let previous = try XCTUnwrap(first.accessibilityCustomActions?.first { $0.name == "Select Previous Word" }?.actionHandler)
        var moves = 0
        while moves < 40, previous(UIAccessibilityCustomAction(name: "Select Previous Word") { _ in false }) { moves += 1 }
        XCTAssertEqual(moves, 15, "the fifteen words of the paragraph before, \"(399\" and \"Begin\" each one")
        XCTAssertTrue(canvas.currentSelection?.text.hasPrefix("Copy the text") == true)
        // A selection of one word keeps it.
        canvas.clearSelection()
        let ending = try XCTUnwrap(try lines(view).first { words($0) == "End" })
        try perform("Select Line", on: ending)
        let refused = try XCTUnwrap(ending.accessibilityCustomActions?.first { $0.name == "Unselect First Word" })
        XCTAssertFalse(try XCTUnwrap(refused.actionHandler)(refused))
        XCTAssertEqual(canvas.currentSelection?.text, "End")
    }

    /// A selection grows onto the next page by a word, and a page turn then keeps it: a page
    /// that shows none of the selection, as any turn away from a passage does, takes it away.
    func testAPassageAcrossPagesIsSelectedAWordIntoTheNextPage() async throws {
        let (reader, canvas) = try await reader(scrolled: false, size: CGSize(width: 402, height: 360)) { _ in }
        canvas.postToAccessibility = { _, _ in }
        var view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        let first = try XCTUnwrap(try lines(view).first { words($0).hasPrefix("Begin Consider") })
        XCTAssertNil(try lines(view).first { words($0).hasSuffix("the world began.") }, "the passage must run past the first page")
        try perform("Select Line", on: first)
        try perform("Unselect First Word", on: first)
        var pages = 1
        while try lines(view).first(where: { words($0).hasSuffix("the world began.") }) == nil {
            let last = try XCTUnwrap(try lines(view).last)
            if !last.accessibilityTraits.contains(.selected) { try perform("Extend Selection to Line", on: last) }
            try perform("Select Next Word", on: last)
            try perform("Next Page", on: last)
            view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
            XCTAssertTrue(try lines(view).first?.accessibilityTraits.contains(.selected) == true, "page \(pages + 1) opens selected")
            pages += 1
            guard pages < 6 else { return XCTFail("the passage's end is never shown") }
        }
        try perform("Extend Selection to Line", on: try XCTUnwrap(try lines(view).first { words($0).hasSuffix("the world began.") }))
        try await reader.wait("the passage selected across \(pages) pages") { reader.session.selection?.text == Self.passage }
        XCTAssertNotNil(canvas.selectionContinuation, "the reader shows that the selection goes on before this page")
    }

    /// A table's cell keeps its own selection, and a line's takes its place: the two are one
    /// selection, whichever was made last.
    func testATablesCellAndALineSelectInTurn() async throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", "<p>Words before the table.</p>"
                + "<table><tr><th>Station</th><th>Depth</th></tr><tr><td>Alder</td><td>Twelve meters</td></tr></table>"
                + "<p>Words after the table.</p>" + SessionCoverageBook.filler(60), title: "Tables")]))
        let reader = try SessionCoverageReader(publication: publication)
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        canvas.postToAccessibility = { _, _ in }
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.count == 4 }
        let listed = try lines(view)
        let before = try XCTUnwrap(listed.first { words($0) == "Words before the table." })
        let after = try XCTUnwrap(listed.first { words($0) == "Words after the table." })
        let table = try XCTUnwrap(listed.first { $0 is UIAccessibilityContainerDataTable })
        let cell = try XCTUnwrap((table.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }.first { $0.accessibilityLabel == "Alder" })

        try perform("Select Line", on: before)
        try perform("Select Cell Text", on: cell)
        try await reader.wait("the cell's words selected") { reader.session.selection?.text == "Alder" }
        XCTAssertFalse(before.accessibilityTraits.contains(.selected))
        XCTAssertEqual(actions(before), ["Next Page", "Previous Page", "Select Line"], "a cell's selection is not a line's to grow")
        XCTAssertEqual(actions(cell), ["Next Page", "Previous Page", "Deselect Cell Text", "Copy"])
        try perform("Select Line", on: after)
        try await reader.wait("the line selected") { reader.session.selection?.text == "Words after the table." }
        XCTAssertEqual(actions(cell), ["Next Page", "Previous Page", "Select Cell Text"])
        XCTAssertTrue(after.accessibilityTraits.contains(.selected))
    }
}
#endif
