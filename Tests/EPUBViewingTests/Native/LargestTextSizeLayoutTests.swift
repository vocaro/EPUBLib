import CoreGraphics
import XCTest
@testable import EPUBViewing

/// The largest size the reader draws, 96 points, which Larger Text reaches (#675): long words,
/// tables and pictures in the columns the reader lays out, from a phone upright to the width
/// at which two columns become one, and the narrowest column a book pose keeps. Every
/// character is on a page and inside its column, and every table word is shown once.
@MainActor final class LargestTextSizeLayoutTests: XCTestCase {
    private typealias H = BoxLayoutHarness

    /// Words longer than any column at 96 points, a table of them, a table wider than the column,
    /// pictures wider and narrower than it, and the book's other usual blocks.
    private func section() throws -> SectionText {
        let body = """
        <h1>Antidisestablishmentarianism</h1>
        <p>Pneumonoultramicroscopicsilicovolcanoconiosis is a word, and so is \
        supercalifragilisticexpialidocious; https://example.com/a/very/long/path/without/any/spaces/at/all ends a line.</p>
        <table border='1'><tr><th>Name</th><th>Count</th></tr>\
        <tr><td>Incomprehensibilities</td><td>1912</td></tr><tr><td>Short</td><td>47</td></tr></table>
        <p>Words between the tables.</p>
        <table><tr><td>Left cell words</td><td>Middle cell words</td><td>Right cell words</td><td>Farthest cell</td></tr></table>
        <p>Before the wide picture <img src='wide.png' alt='Wide picture'/> and after it.</p>
        <p>Before the small picture <img src='small.png' alt='Small picture'/> and after it.</p>
        <ul><li>A list item that wraps</li><li>Second</li></ul>
        <blockquote><p>A quotation set in from both sides.</p></blockquote>
        <p>The last paragraph of ordinary words.</p>
        """
        return try H.build(body, css: "", fontSize: NativeTypography.maximumFontSize,
                           files: ["wide.png": RichFixture.image(width: 1600, height: 900), "small.png": RichFixture.image(width: 40, height: 40)])
    }

    /// Column sizes the reader lays pages out in, from `ReaderCanvasGeometry` itself.
    private func columns() -> [(label: String, size: CGSize)] {
        func spread(_ width: CGFloat, _ height: CGFloat, division: CGRect? = nil) -> ReaderCanvasGeometry.Spread {
            ReaderCanvasGeometry.spread(in: CGRect(x: 0, y: 0, width: width, height: height), division: division, isRightToLeft: false)
        }
        let twoColumns = spread(775, 500), oneColumn = spread(774, 500)
        let pose = spread(1000, 700, division: CGRect(x: 600, y: 0, width: 20, height: 700))
        XCTAssertEqual(twoColumns.columns.count, 2, "775 points across is two columns")
        XCTAssertEqual(oneColumn.columns.count, 1, "774 points across is one")
        XCTAssertEqual(pose.columns.count, 2)
        return [("iPhone SE upright", spread(375, 600).columnSize), ("phone upright", spread(402, 780).columnSize),
                ("phone on its side", spread(874, 340).columnSize),
                ("two columns at their narrowest", twoColumns.columnSize), ("one column just below", oneColumn.columnSize),
                ("book pose", pose.columnSize), ("iPad on its side", spread(1366, 980).columnSize)]
    }

    func testEveryPageHoldsItsTextInsideItsColumnAtNinetySixPoints() throws {
        let section = try section()
        let words = ["Antidisestablishmentarianism", "Pneumonoultramicroscopicsilicovolcanoconiosis", "spaces/at/all",
                     "Words between the tables.", "after it.", "The last paragraph of ordinary words."]
        for word in words { _ = H.range(word, in: section) }
        for (label, size) in columns() {
            XCTAssertGreaterThan(size.height, NativeTypography.maximumFontSize * 1.2, "\(label): a column holds a line")
            PageTextGeometryTests.assertVisiblePages(section, size: size, label: label)
            let paginator = ReaderPaginator(text: section.string, size: size)
            for (index, page) in paginator.allPages.enumerated() {
                let view = H.pageView(paginator, page: page)
                assertInsideColumn(view, width: size.width, range: view.shownCharacters, label: "\(label) page \(index)")
            }
        }
    }

    func testContinuousScrollHoldsItsTextInsideItsColumnAtNinetySixPoints() throws {
        let section = try section()
        for width in [375, 402, 720].map({ ReaderCanvasGeometry.scrollColumn(in: CGRect(x: 0, y: 0, width: CGFloat($0), height: 800), division: nil).width }) {
            let view = H.view(section.string, size: CGSize(width: width, height: 800), pageColumn: false)
            assertInsideColumn(view, width: width, range: NSRange(location: 0, length: section.string.length), label: "scroll \(width)")
        }
    }

    /// Each character that draws something, attachments among them, lies across no edge of
    /// the column: nothing is cut off at either side or pushed past it.
    private func assertInsideColumn(_ view: ReaderTextView, width: CGFloat, range: NSRange, label: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let characters = view.contentStorage.textStorage!.string as NSString
        var checked = 0
        for offset in range.location..<range.upperBound {
            guard let scalar = UnicodeScalar(characters.character(at: offset)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            let frames = view.segmentFrames(for: NSRange(location: offset, length: 1))
            XCTAssertFalse(frames.isEmpty, "\(label): character \(offset) is laid out", file: file, line: line)
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.minX, -0.75, "\(label): character \(offset) starts left of the column", file: file, line: line)
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.75, "\(label): character \(offset) ends past the column, \(frame)", file: file, line: line)
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, label, file: file, line: line)
    }
}
