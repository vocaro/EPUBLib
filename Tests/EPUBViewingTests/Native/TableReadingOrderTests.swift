#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// What a table is to VoiceOver on iPhone and iPad, in pages and in continuous scroll
/// (doc/native-viewer.md, "Tables"): each row one element, where it stands among the lines of
/// its page, read as its cells' words and offering what its own cells can do. The text views
/// over the cells are for touch and offer an assistive technology nothing.
///
/// No assistive technology is driven here, and UIKit's accessibility is not loaded in a test
/// host. The tests read a text view's elements through the container protocol VoiceOver uses,
/// and hold whatever the reader mounts inside such a view to being hidden: on 2026-10-12
/// VoiceOver took what the cells' text views offered before every line of a page column, on
/// simulators and devices, and no in-process query shows that order.
@MainActor final class TableReadingOrderTests: XCTestCase {
    private typealias Subject = (reader: SessionCoverageReader, canvas: ReaderCanvasView, view: ReaderTextView)
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
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

    private func actions(_ element: UIAccessibilityElement) -> [String] { (element.accessibilityCustomActions ?? []).map(\.name) }

    private func perform(_ name: String, on element: UIAccessibilityElement, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(element.accessibilityCustomActions?.first { $0.name == name }, "no action \(name)", file: file, line: line)
        XCTAssertTrue(try XCTUnwrap(action.actionHandler, file: file, line: line)(action), name, file: file, line: line)
    }

    /// The views the reader itself mounts inside `view`, each kept from assistive technology.
    private func assertWhatIsMountedInsideIsHidden(_ view: ReaderTextView, count: Int, _ label: String,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let own = Bundle(for: ReaderTextView.self)
        let mounted = view.subviews.filter { Bundle(for: type(of: $0)) == own }
        XCTAssertEqual(mounted.count, count, "\(label): a text view over each cell on screen", file: file, line: line)
        XCTAssertEqual(mounted.count, view.tableInteraction?.cells.count, label, file: file, line: line)
        for inside in mounted {
            XCTAssertTrue(inside.accessibilityElementsHidden,
                          "\(label): \(type(of: inside)) inside a text view that lists its lines is read ahead of them", file: file, line: line)
            XCTAssertFalse(inside.isAccessibilityElement, label, file: file, line: line)
        }
    }

    func testARowIsReadOnceAsItsCellsWordsWhereItStandsAmongTheLines() async throws {
        let table = "<table><tr><td>First cell</td><td>Second cell</td></tr>"
            + "<tr><td>Third cell</td><td><a href='notes.xhtml'>Fourth cell link</a></td></tr></table>"
        // The chapter goes on for some screens, so the link's target is not on screen with it.
        let book = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", "<p>Words before the table.</p>" + table + "<p>Words after the table.</p>"
                                            + SessionCoverageBook.filler(120), title: "Tables"),
            SessionCoverageBook.Section("notes", "<h1>Notes</h1><p>The linked note.</p>", title: "Notes")]))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (reader, canvas, view) = try await reader(book, scrolled: scrolled)
            let all = try listed(view)
            let elements = Array(all.prefix(4))
            XCTAssertEqual(elements.map(words), ["Words before the table.", "First cell\tSecond cell",
                                                 "Third cell\tFourth cell link", "Words after the table."],
                           "\(flow): the rows in order between the lines around them, each once and no cell by itself")
            XCTAssertFalse(all.dropFirst(4).contains { words($0).contains("cell") }, "\(flow): nothing of the table is listed again")
            XCTAssertEqual(view.accessibilityElementCount(), all.count, flow)
            for (index, element) in elements.enumerated() {
                XCTAssertTrue(element.accessibilityTraits.contains(.staticText), "\(flow): \(words(element)) is text")
                XCTAssertFalse(element.accessibilityTraits.contains(.image), "\(flow): \(words(element)) is words, not a picture")
                XCTAssertTrue(element.accessibilityContainer as? ReaderTextView === view, flow)
                XCTAssertEqual(view.index(ofAccessibilityElement: element), index, flow)
            }
            // Down the page: a row stands below the line before it and above the line after it.
            let frames = elements.map(\.accessibilityFrameInContainerSpace)
            for (above, below) in zip(frames, frames.dropFirst()) {
                XCTAssertFalse(above.isEmpty || below.isEmpty, flow)
                XCTAssertLessThanOrEqual(above.maxY, below.minY + 0.5, "\(flow): \(above) is listed before \(below)")
            }
            assertWhatIsMountedInsideIsHidden(view, count: 4, flow)

            // A row offers what its own cells can do, and no other line repeats it. A page's
            // lines also turn the page.
            let turns = scrolled ? [] : ["Next Page", "Previous Page"]
            XCTAssertEqual(actions(elements[0]), turns, flow)
            XCTAssertEqual(actions(elements[1]), turns + ["Select Table Text: First cell", "Select Table Text: Second cell"], flow)
            XCTAssertEqual(actions(elements[2]), turns + ["Select Table Text: Third cell", "Select Table Text: Fourth cell link",
                                                          "Follow Table Link: Fourth cell link"], flow)
            XCTAssertEqual(actions(elements[3]), turns, flow)
            // VoiceOver offers a container's actions on every element inside it.
            XCTAssertEqual((view.accessibilityCustomActions ?? []).map(\.name), [], "\(flow): nothing for every line to repeat")

            try perform("Select Table Text: Second cell", on: elements[1])
            try await reader.wait("\(flow): the cell's words selected") { reader.session.selection?.text == "Second cell" }
            XCTAssertNotNil(reader.session.selection?.range.start.tableCell, flow)
            canvas.clearSelection()
            let linked = ReaderTextPosition(section: 1, offset: 0)
            XCTAssertFalse(reader.isVisible(linked), "\(flow): the link's target must be off screen for this to show anything")
            try perform("Follow Table Link: Fourth cell link", on: elements[2])
            try await reader.wait("\(flow): the linked chapter") { reader.isVisible(linked) }
        }
    }

    /// A row taller than a page continues on the next: each page's element reads the words its
    /// own continuation shows, so the row's words are read once across them.
    func testARowContinuedAcrossPagesIsReadByEachPagesOwnWords() async throws {
        let said = (1...700).map { "w\($0)" }
        let book = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tall", "<table><tr><td>Label</td><td>" + said.joined(separator: " ") + "</td></tr></table>", title: "Tall")]))
        let (_, canvas, view) = try await reader(book, scrolled: false)
        var read: [String] = [], pages = 0
        repeat {
            let column = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
            XCTAssertTrue(column === view, "one column, reused for each page")
            let elements = try listed(column)
            XCTAssertEqual(elements.count, 1, "page \(pages + 1): the continuation it shows, one element")
            for element in elements {
                XCTAssertTrue(element.accessibilityTraits.contains(.staticText) && !element.accessibilityTraits.contains(.image))
                read += (element.accessibilityLabel ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            }
            assertWhatIsMountedInsideIsHidden(column, count: column.tableInteraction?.cells.count ?? 0, "page \(pages + 1)")
            pages += 1
        } while pages < 40 && canvas.turnPage(forward: true) == .turned
        XCTAssertGreaterThan(pages, 1, "the row must be taller than a page for this to show anything")
        XCTAssertEqual(read, ["Label"] + said, "every word once, in order, across \(pages) pages")
    }

    /// A row of pictures without words is a picture, as an image in a line is; a row that
    /// shows neither words nor pictures is no stop at all, where VoiceOver would rest on
    /// silence.
    func testARowOfPicturesIsAPictureAndARowOfNothingIsNoElement() async throws {
        let body = "<table><tr>" + TableCoverage.box(40) + TableCoverage.box(30) + "</tr>"
            + "<tr><td></td><td> </td></tr>"
            + "<tr><td><img src='w40.png' alt='A drawn map'/></td><td>Beside the map</td></tr></table><p>Words after the table.</p>"
        let book = try TableCoverage.publication(body, files: TableCoverage.images([40, 30], height: 20))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            let (_, _, view) = try await reader(book, scrolled: scrolled)
            let elements = Array(try listed(view).prefix(3))
            XCTAssertEqual(elements.map(words), ["Book image", "A drawn map\tBeside the map", "Words after the table."], flow)
            XCTAssertEqual(elements.map { $0.accessibilityTraits.contains(.image) }, [true, false, false], flow)
            XCTAssertEqual(elements.map { $0.accessibilityTraits.contains(.staticText) }, [true, true, true], flow)
            XCTAssertEqual(actions(elements[0]).filter { $0.hasPrefix("Inspect Image") }, ["Inspect Image", "Inspect Image"], flow)
            XCTAssertEqual(actions(elements[1]).filter { $0.hasPrefix("Inspect Image") }, ["Inspect Image: A drawn map"], flow)
            XCTAssertEqual(actions(elements[2]).filter { $0.contains("Image") || $0.contains("Table") }, [], flow)
        }
    }
}
#endif
