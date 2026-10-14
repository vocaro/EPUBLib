#if os(macOS)
import AppKit
import XCTest
@testable import EPUBViewing

/// The lines of a table cell on the Mac as an assistive client is given them. A cell is a text
/// view of its own (`TableCellTextView`), which VoiceOver reads by line through the line of its
/// insertion point. API level only: what VoiceOver says is recorded in doc/testing.md.
@MainActor final class TableCellLineAccessibilityTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private func surface(_ text: NSAttributedString, showing shown: NSRange? = nil, width: CGFloat = 400) -> TableCellTextView {
        let cell = TableCellTextView(text: text, width: width, characters: shown ?? NSRange(location: 0, length: text.length))
        cell.configure(frame: CGRect(x: 0, y: 0, width: width, height: 200), scale: 1, textOffset: .zero, actionTitle: nil)
        return cell
    }

    /// The cell's lines in order, each as the characters it gives for them.
    private func lines(of cell: TableCellTextView) -> [NSRange] {
        var found: [NSRange] = []
        while found.count < 200 {
            let range = cell.accessibilityRange(forLine: found.count)
            guard range.location != NSNotFound else { break }
            found.append(range)
        }
        return found
    }

    /// The words VoiceOver's Read Line has to read with the insertion point at `offset`: the
    /// line the cell gives for its insertion point, and that line's characters.
    private func lineRead(in cell: TableCellTextView, at offset: Int, file: StaticString = #filePath, line: UInt = #line) -> String? {
        cell.setAccessibilitySelectedTextRange(NSRange(location: offset, length: 0))
        XCTAssertEqual(cell.accessibilitySelectedTextRange(), NSRange(location: offset, length: 0), file: file, line: line)
        let number = cell.accessibilityInsertionPointLineNumber()
        XCTAssertEqual(number, cell.accessibilityLine(for: offset), "the insertion point's line is its offset's", file: file, line: line)
        guard number != NSNotFound else { return nil }
        return cell.accessibilityString(for: cell.accessibilityRange(forLine: number))
    }

    /// VoiceOver leaves the insertion point after a word it has read, so after a cell's last
    /// word it is after the cell's last character. That offset is on the cell's last line, as
    /// the offset after a page's last character is on the page's (`ReaderTextView.accessibilityLine(for:)`):
    /// with no line there Read Line said nothing.
    func testTheInsertionPointAfterACellsLastCharacterIsOnItsLastLine() {
        let text = CanvasText.body("First line of the cell.\nSecond line of the cell.\nLast words.")
        let cell = surface(text)
        let length = cell.accessibilityNumberOfCharacters()
        XCTAssertEqual(length, text.length)
        XCTAssertEqual(lines(of: cell).map { cell.accessibilityString(for: $0) },
                       ["First line of the cell.\n", "Second line of the cell.\n", "Last words."])
        XCTAssertEqual(cell.accessibilityLine(for: length), 2, "after the last character")
        XCTAssertEqual(cell.accessibilityLine(for: length - 1), 2, "on it")
        XCTAssertEqual(cell.accessibilityLine(for: 0), 0)
        XCTAssertEqual(lineRead(in: cell, at: length), "Last words.")
        XCTAssertEqual(lineRead(in: cell, at: length - 1), "Last words.")
        XCTAssertEqual(lineRead(in: cell, at: 0), "First line of the cell.\n")
        // A line's first character is on that line, and the offset before it is not after the
        // line above: only the end of the text has an insertion point with no character.
        let second = (text.string as NSString).range(of: "Second")
        XCTAssertEqual(lineRead(in: cell, at: second.location), "Second line of the cell.\n")
        XCTAssertEqual(lineRead(in: cell, at: second.location - 1), "First line of the cell.\n")
    }

    /// A cell's text never changes, so an offset past the one after its last character is not
    /// the cell's: nothing is made up for it, and every range still matches the cell's text.
    func testAnOffsetThatIsNotTheCellsHasNoLine() {
        let cell = surface(CanvasText.body("Third cell"))
        XCTAssertEqual(cell.accessibilityNumberOfCharacters(), 10)
        XCTAssertEqual(lines(of: cell), [NSRange(location: 0, length: 10)])
        XCTAssertEqual(cell.accessibilityLine(for: 10), 0, "a cell of one line: its end is on that line")
        XCTAssertEqual(cell.accessibilityLine(for: 11), NSNotFound)
        XCTAssertEqual(cell.accessibilityLine(for: 5_000), NSNotFound)
        XCTAssertEqual(cell.accessibilityLine(for: -1), NSNotFound)
        XCTAssertEqual(cell.accessibilityLine(for: NSNotFound), NSNotFound)
        XCTAssertEqual(cell.accessibilityRange(forLine: 1).location, NSNotFound, "and the cell has no line more for it")
        // The offset after the last character is still no character.
        XCTAssertEqual(cell.accessibilityRange(for: 10).location, NSNotFound)
        XCTAssertNil(cell.accessibilityString(for: NSRange(location: 10, length: 1)))
        XCTAssertEqual(cell.accessibilityString(for: NSRange(location: 10, length: 0)), "")
    }

    /// A paragraph the cell's width breaks into lines: the lines are the layout's, they cover
    /// the text once, and its end is on the last of them.
    func testTheEndOfAWrappedCellIsOnTheLastLineTheLayoutMade() throws {
        let words = "Before the worded jump after it, and then enough further words to carry this entry on to another line."
        let cell = surface(CanvasText.body(words), width: 140)
        let found = lines(of: cell)
        XCTAssertGreaterThan(found.count, 3)
        XCTAssertEqual(found.first?.location, 0)
        for (line, next) in zip(found, found.dropFirst()) { XCTAssertEqual(NSMaxRange(line), next.location, "no gap and no overlap") }
        XCTAssertEqual(found.last.map(NSMaxRange), words.utf16.count)
        for (index, line) in found.enumerated() {
            XCTAssertEqual(cell.accessibilityLine(for: line.location), index)
            XCTAssertEqual(cell.accessibilityLine(for: NSMaxRange(line) - 1), index)
        }
        let last = try XCTUnwrap(lineRead(in: cell, at: words.utf16.count))
        XCTAssertEqual(last, cell.accessibilityString(for: try XCTUnwrap(found.last)))
        XCTAssertTrue(last.hasSuffix("line."), last)
        XCTAssertFalse(last.hasPrefix("Before"), "the last line, not the first")
    }

    /// A cell cut at a page's end shows a slice of its lines on each page, and every range
    /// counts from the first character the slice shows. The end of a slice is on the slice's
    /// last line, never on a line of the page after.
    func testTheEndOfASliceOfAContinuedCellIsOnTheSlicesLastLine() {
        let text = CanvasText.body("Hidden line one.\nShown line two.\nShown line three.\nHidden line four.")
        let string = text.string as NSString
        let middle = surface(text, showing: string.range(of: "Shown line two.\nShown line three.\n"))
        let length = middle.accessibilityNumberOfCharacters()
        XCTAssertEqual(lines(of: middle).map { middle.accessibilityString(for: $0) }, ["Shown line two.\n", "Shown line three.\n"])
        XCTAssertEqual(middle.accessibilityLine(for: length), 1)
        XCTAssertEqual(lineRead(in: middle, at: length), "Shown line three.\n", "not the hidden line that follows it")
        XCTAssertEqual(middle.accessibilityLine(for: length + 1), NSNotFound, "the next page's characters are not this slice's")
        XCTAssertEqual(lineRead(in: middle, at: 0), "Shown line two.\n")
        let end = surface(text, showing: string.range(of: "Hidden line four."))
        XCTAssertEqual(lineRead(in: end, at: end.accessibilityNumberOfCharacters()), "Hidden line four.")
        let start = surface(text, showing: string.range(of: "Hidden line one.\n"))
        XCTAssertEqual(lineRead(in: start, at: start.accessibilityNumberOfCharacters()), "Hidden line one.\n")
    }

    /// A slice that shows no character has no line, at its end or anywhere.
    func testACellThatShowsNothingHasNoLine() {
        let cell = surface(CanvasText.body("Words on another page."), showing: NSRange(location: 0, length: 0))
        XCTAssertEqual(cell.accessibilityNumberOfCharacters(), 0)
        XCTAssertEqual(lines(of: cell), [])
        XCTAssertEqual(cell.accessibilityLine(for: 0), NSNotFound)
        XCTAssertEqual(cell.accessibilityInsertionPointLineNumber(), NSNotFound)
    }

    /// The cells of a table built by the real pipeline and mounted on a page, as VoiceOver
    /// finds them: the VoiceOver fixture's own (`scripts/make-voiceover-fixture.py`), a cell
    /// whose words are a link, and one of several lines.
    func testEveryMountedCellOfATableHasALineForTheEndOfItsText() async throws {
        let long = "Before the worded jump after it, and then enough further words to carry this entry on to another line."
        let section = try TableCoverage.section("""
            <p>Shown words before the table.</p><table>\
            <tr><td>First cell</td><td>Second cell</td></tr>\
            <tr><td>Left cell</td><td><a href="two.xhtml#t">Right cell jump</a></td></tr>\
            <tr><td>Plain first entry.</td><td>\(long)</td></tr>\
            </table><p>Shown words after the table.</p>
            """, css: "td { padding: 4px 8px; }")
        let host = CanvasHost(FakeCanvasSource([section.string]), size: CGSize(width: 360, height: 700))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        var cells: [TableCellTextView] = []
        for _ in 0..<100 where cells.count != 6 {
            host.layOut()
            try await host.settle(50)
            for view in host.canvas.textViews { view.refreshTableInteractions() }
            cells = (host.canvas.textViews.first?.tableInteraction?.cells ?? [:])
                .sorted { ($0.key.location, $0.key.cell, $0.key.lower) < ($1.key.location, $1.key.cell, $1.key.lower) }.map(\.value)
        }
        XCTAssertEqual(cells.map { $0.accessibilityValue() ?? "" },
                       ["First cell", "Second cell", "Left cell", "Right cell jump", "Plain first entry.", long])
        for cell in cells {
            let value = try XCTUnwrap(cell.accessibilityValue()), found = lines(of: cell)
            let end = cell.accessibilityNumberOfCharacters()
            XCTAssertEqual(end, value.utf16.count)
            XCTAssertEqual(found.map(\.length).reduce(0, +), end, "the lines are the cell's text, once")
            XCTAssertEqual(cell.accessibilityLine(for: end), found.count - 1, value)
            let read = try XCTUnwrap(lineRead(in: cell, at: end), value)
            XCTAssertTrue(value.hasSuffix(read), "\(read) ends \(value)")
            XCTAssertFalse(read.isEmpty)
            XCTAssertEqual(cell.accessibilityLine(for: end + 1), NSNotFound)
        }
        XCTAssertGreaterThan(lines(of: cells[5]).count, 1, "a cell of several lines, whose end is on the last")
        XCTAssertNotEqual(lineRead(in: cells[5], at: long.utf16.count), lineRead(in: cells[5], at: 0))
    }
}
#endif
