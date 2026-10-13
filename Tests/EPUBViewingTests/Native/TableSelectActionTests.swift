#if os(iOS)
import EPUBCore
import EPUBReading
import UIKit
import XCTest
@testable import EPUBViewing

/// What selecting a table's text by its accessibility action does on iPhone and iPad, in pages
/// and in continuous scroll, for a row of a table that is not data (Select Table Text) and a
/// cell of one that is (Select Cell Text): the reader reports the words, draws them selected,
/// tells the assistive technology so, and the same item then offers what a selection is for
/// (doc/native-viewer.md, "Tables").
///
/// No assistive technology is driven here. The test performs the actions an element lists,
/// reads the pixels the canvas draws, and takes what the reader would have VoiceOver say from
/// the canvas instead of posting it. That VoiceOver performs the action, says the words and
/// offers the rest on a device is in doc/voiceover-testing.md.
@MainActor final class TableSelectActionTests: XCTestCase {
    private typealias Cell = UIAccessibilityElement & UIAccessibilityContainerDataTableCell
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    /// A table that arranges two things side by side and a table of data, with lines around
    /// them, and enough after them for the chapter to go on past the screen.
    private static let body = """
        <p>Words before the tables.</p>\
        <table><tr><td>Left cell</td><td>Right cell</td></tr></table>\
        <p>Words between the tables.</p>\
        <table><tr><th>Station</th><th>Depth</th></tr><tr><td>Alder</td><td>Twelve metres</td></tr></table>\
        <p>Words after the tables.</p>
        """

    private func actions(_ element: UIAccessibilityElement) -> [String] { (element.accessibilityCustomActions ?? []).map(\.name) }

    private func perform(_ name: String, on element: UIAccessibilityElement, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(element.accessibilityCustomActions?.first { $0.name == name }, "no action \(name)", file: file, line: line)
        XCTAssertTrue(try XCTUnwrap(action.actionHandler, file: file, line: line)(action), name, file: file, line: line)
    }

    /// The canvas as it is drawn, one pixel to a point, as bytes of red, green, blue and alpha.
    private func pixels(_ canvas: ReaderCanvasView) throws -> [UInt8] {
        canvas.layoutIfNeeded()
        let width = Int(canvas.bounds.width), height = Int(canvas.bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // UIKit's layers are drawn from the top; the bitmap's rows are kept from the top too.
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            canvas.layer.render(in: context)
        }
        return bytes
    }

    /// How many pixels of `frame` differ between two drawings of a canvas `width` points wide.
    /// With `ground`, only those that were the cell's ground before, its commonest colour:
    /// a selection tints the ground behind the words, where ink drawn a second time over the
    /// row's own darkens the edges of the letters and nothing else.
    private func changed(_ before: [UInt8], _ after: [UInt8], in frame: CGRect, width: Int, ground: Bool = false) -> Int {
        var places: [Int] = []
        for y in max(0, Int(frame.minY))..<max(0, Int(frame.maxY)) {
            for x in max(0, Int(frame.minX))..<min(width, Int(frame.maxX)) where (y * width + x) * 4 + 3 < before.count {
                places.append((y * width + x) * 4)
            }
        }
        func colour(_ bytes: [UInt8], _ place: Int) -> UInt32 { bytes[place..<place + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        let commonest = Dictionary(grouping: places) { colour(before, $0) }.max { $0.value.count < $1.value.count }?.key
        return places.filter { place in
            (!ground || colour(before, place) == commonest)
                && (0..<4).contains { abs(Int(before[place + $0]) - Int(after[place + $0])) > 8 }
        }.count
    }

    func testSelectingATablesTextShowsItSaysSoAndOffersWhatASelectionIsFor() async throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", Self.body + SessionCoverageBook.filler(120), title: "Tables")]))
        for scrolled in [false, true] {
            let flow = scrolled ? "continuous scroll" : "pages"
            var used: [String] = []
            let reader = try SessionCoverageReader(publication: publication, action: EPUBSelectionAction(title: "Use passage") { used.append($0.text) })
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
            try await reader.wait("the cells' text views") { view.tableInteraction?.cells.count == 6 }
            var said: [String] = []
            canvas.announce = { said.append($0) }
            let turns = scrolled ? [] : ["Next Page", "Previous Page"]

            let listed = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
            let row = try XCTUnwrap(listed.first { $0.accessibilityLabel?.hasPrefix("Left cell") == true }, flow)
            let table = try XCTUnwrap(listed.first { $0 is UIAccessibilityContainerDataTable }, flow)
            let cell = try XCTUnwrap((table.accessibilityElements ?? []).compactMap { $0 as? Cell }.first { $0.accessibilityLabel == "Twelve metres" }, flow)
            // A row names the cell in each of its actions; a cell's are its own. Otherwise the
            // two are the same thing, and are held to the same here.
            let cases: [(item: UIAccessibilityElement, words: String, select: String, deselect: String, rest: [String])] = [
                (row, "Left cell", "Select Table Text: Left cell", "Deselect Table Text: Left cell", ["Select Table Text: Right cell"]),
                (cell, "Twelve metres", "Select Cell Text", "Deselect Cell Text", [])]
            for (item, words, select, deselect, rest) in cases {
                let label = "\(flow), \(select)"
                let surface = try XCTUnwrap(view.tableInteraction?.cells.values.first { $0.cellText.string.hasPrefix(words) }, label)
                var copied: [String] = []
                surface.copyTextToPasteboard = { copied.append($0) }
                let frame = surface.convert(surface.bounds, to: canvas)
                let width = Int(canvas.bounds.width)
                XCTAssertEqual(actions(item), turns + [select] + rest, label)
                let plain = try pixels(canvas)
                said.removeAll()

                // Selected: reported, drawn in the cell, and said.
                try perform(select, on: item)
                try await reader.wait("\(label): the words selected") { reader.session.selection?.text == words }
                XCTAssertNotNil(reader.session.selection?.range.start.tableCell, label)
                let selected = try pixels(canvas)
                XCTAssertGreaterThan(changed(plain, selected, in: frame, width: width, ground: true), 200,
                                     "\(label): pixels of the cell's \(Int(frame.width)) × \(Int(frame.height)) ground that show the selection")
                XCTAssertEqual(said, ["Selected: \(words)"], label)

                // The item then offers what a selection is for, where its select action stood.
                XCTAssertEqual(actions(item), turns + [deselect, "Copy", "Use passage"] + rest, label)
                try perform("Copy", on: item)
                XCTAssertEqual(copied, [words], label)
                XCTAssertEqual(said, ["Selected: \(words)", "Copied"], label)
                XCTAssertEqual(used, [], label)
                try perform("Use passage", on: item)
                XCTAssertEqual(used, [words], label)
                used.removeAll()
                XCTAssertEqual(reader.session.selection?.text, words, "\(label): neither takes the selection away")

                // Deselected: reported, no longer drawn, said, and the item offers what it did.
                try perform(deselect, on: item)
                try await reader.wait("\(label): nothing selected") { reader.session.selection == nil }
                XCTAssertEqual(changed(plain, try pixels(canvas), in: frame, width: width), 0, "\(label): the cell as it was drawn before")
                XCTAssertEqual(said, ["Selected: \(words)", "Copied", "Deselected"], label)
                XCTAssertEqual(actions(item), turns + [select] + rest, label)
            }

            // A selection in one cell is offered on that cell's item and no other.
            try perform("Select Cell Text", on: cell)
            try await reader.wait("\(flow): the cell's words selected") { reader.session.selection?.text == "Twelve metres" }
            XCTAssertEqual(actions(row), turns + ["Select Table Text: Left cell", "Select Table Text: Right cell"], flow)
            // Selecting elsewhere moves the selection, and what is offered with it.
            try perform("Select Table Text: Right cell", on: row)
            try await reader.wait("\(flow): the other table's words selected") { reader.session.selection?.text == "Right cell" }
            XCTAssertEqual(actions(row), turns + ["Select Table Text: Left cell", "Deselect Table Text: Right cell", "Copy", "Use passage"], flow)
            XCTAssertEqual(actions(cell), turns + ["Select Cell Text"], flow)
            canvas.clearSelection()
            XCTAssertEqual(actions(row), turns + ["Select Table Text: Left cell", "Select Table Text: Right cell"], flow)
            reader.close()
        }
    }

    /// A passage selected in code, as a located passage is and a selection carried across a
    /// new layout, is selected in every cell it takes in, and no cell is first responder for
    /// UIKit to draw it in: each cell shows its own share.
    func testAPassageSelectedInCodeShowsInEveryCellItTakesIn() async throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", Self.body + SessionCoverageBook.filler(120), title: "Tables")]))
        let reader = try SessionCoverageReader(publication: publication)
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.count == 6 }
        canvas.announce = { _ in }
        let row = try XCTUnwrap((view.accessibilityElements as? [UIAccessibilityElement])?.first { $0.accessibilityLabel?.hasPrefix("Left cell") == true })
        // The two cells' places in the book, from selecting each.
        var ends: [ReaderTextRange] = []
        for words in ["Left cell", "Right cell"] {
            try perform("Select Table Text: \(words)", on: row)
            try await reader.wait("\(words) selected") { reader.session.selection?.text == words }
            ends.append(try XCTUnwrap(canvas.currentSelection?.range))
        }
        canvas.clearSelection()
        try await reader.wait("nothing selected") { reader.session.selection == nil }
        let plain = try pixels(canvas)

        canvas.show(ends[0].start, selecting: ReaderTextRange(start: ends[0].start, end: ends[1].end))
        try await reader.wait("both cells' words selected") { reader.session.selection?.text == "Left cell\tRight cell" }
        let selected = try pixels(canvas)
        for words in ["Left cell", "Right cell"] {
            let surface = try XCTUnwrap(view.tableInteraction?.cells.values.first { $0.cellText.string.hasPrefix(words) })
            XCTAssertFalse(surface.isFirstResponder, words)
            XCTAssertGreaterThan(changed(plain, selected, in: surface.convert(surface.bounds, to: canvas), width: Int(canvas.bounds.width), ground: true), 200,
                                 "pixels of the ground of \(words) that show the selection")
        }
        // The passage is one selection: the row offers to copy it once.
        XCTAssertEqual(actions(row), ["Next Page", "Previous Page", "Deselect Table Text: Left cell", "Copy", "Deselect Table Text: Right cell"])
    }

    /// UIKit draws the selection of a text view that is first responder, as a touch in a cell
    /// makes it. The cell then paints none of its own over it, and paints it again when the
    /// view gives that up with its words still selected.
    func testACellLeavesItsSelectionToUIKitWhileItIsFirstResponder() async throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", Self.body + SessionCoverageBook.filler(120), title: "Tables")]))
        let reader = try SessionCoverageReader(publication: publication)
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.count == 6 }
        canvas.announce = { _ in }
        let row = try XCTUnwrap((view.accessibilityElements as? [UIAccessibilityElement])?.first { $0.accessibilityLabel?.hasPrefix("Left cell") == true })
        let surface = try XCTUnwrap(view.tableInteraction?.cells.values.first { $0.cellText.string.hasPrefix("Left cell") })
        func painted() -> Bool { surface.textStorage.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil }
        XCTAssertFalse(painted(), "nothing is selected")
        try perform("Select Table Text: Left cell", on: row)
        XCTAssertFalse(surface.isFirstResponder, "the action takes no keyboard focus")
        XCTAssertTrue(painted())
        XCTAssertTrue(surface.becomeFirstResponder())
        XCTAssertEqual(surface.cellSelection, NSRange(location: 0, length: 9))
        XCTAssertFalse(painted(), "UIKit draws it now")
        XCTAssertTrue(surface.resignFirstResponder())
        XCTAssertEqual(surface.cellSelection, NSRange(location: 0, length: 9), "the words stay selected")
        XCTAssertTrue(painted(), "and UIKit no longer draws them")
        canvas.clearSelection()
        XCTAssertFalse(painted())
    }

    /// A host that gives no selection action has none to offer; Copy needs no host.
    func testWithoutASelectionActionASelectedCellOffersCopyAlone() async throws {
        let publication = try EPUBPublication.open(data: SessionCoverageBook.epub([
            SessionCoverageBook.Section("tables", Self.body + SessionCoverageBook.filler(120), title: "Tables")]))
        let reader = try SessionCoverageReader(publication: publication)
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let view = try XCTUnwrap(canvas.textViews.first { !$0.isHidden })
        try await reader.wait("the cells' text views") { view.tableInteraction?.cells.count == 6 }
        canvas.announce = { _ in }
        let row = try XCTUnwrap((view.accessibilityElements as? [UIAccessibilityElement])?.first { $0.accessibilityLabel?.hasPrefix("Left cell") == true })
        try perform("Select Table Text: Left cell", on: row)
        XCTAssertEqual(actions(row), ["Next Page", "Previous Page", "Deselect Table Text: Left cell", "Copy", "Select Table Text: Right cell"])
    }
}
#endif
