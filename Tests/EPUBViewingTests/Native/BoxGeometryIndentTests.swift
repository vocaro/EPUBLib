import EPUBTestSupport
import XCTest
@testable import EPUBViewing

/// Paragraph indents where a text has box geometry. A float or positioned box anywhere makes the
/// text container place every line, and TextKit then wraps a line within its paragraph's indents
/// but aligns and justifies it across the whole rectangle it was given. The reader gives TextKit
/// paragraphs without indents and puts the indents into each line's rectangle, so a paragraph
/// sits where it does in a text without boxes
/// ([#63](https://github.com/vocaro/EPUBLib/issues/63)).
@MainActor final class BoxGeometryIndentTests: XCTestCase {
    private typealias H = AlignmentHarness

    private static let size = CGSize(width: 400, height: 4_000)
    /// The space a wrapped line ends with hangs past the line's edge.
    private static let hang: CGFloat = 6
    private static let prose = "words that go on long enough to wrap onto a second line of the column and then onto a third one."
    /// A paragraph of each kind: its first word, its style and its left and right edges.
    private static let paragraphs: [(word: String, style: String, left: CGFloat, right: CGFloat)] = [
        ("Plain", "", 0, 400),
        ("Quoted", "margin: 0 60px 0 40px", 40, 340),
        ("Centred", "margin: 0 60px 0 40px; text-align: center", 40, 340),
        ("Ended", "margin: 0 60px 0 40px; text-align: right", 40, 340),
        ("Indented", "text-indent: 24px", 0, 400),
        ("Hanging", "padding-left: 32px; text-indent: -16px; margin-right: 50px", 16, 350),
        ("Trailing", "margin-right: 70px; text-align: right", 0, 330),
        ("Mirrored", "direction: rtl; margin: 0 60px 0 40px", 40, 340),
    ]
    private static let justified: [(word: String, style: String, left: CGFloat, right: CGFloat, indent: CGFloat)] = [
        ("Justified", "margin: 0 60px 0 40px; text-align: justify", 40, 340, 0),
        ("Flush", "text-indent: 24px; text-align: justify", 0, 400, 24),
    ]

    /// The section with a floated initial ahead of its paragraphs, or with the initial inline.
    private func section(floated: Bool) throws -> SectionText {
        let css = "body { margin: 0 } p, ol, li { margin: 0; padding: 0; text-indent: 0; hyphens: none } "
            + ".cap { font-size: 40px\(floated ? "; float: left" : "") } .after { clear: both } ol { padding-left: 40px; margin-right: 30px }"
        var body = "<p><span class='cap'>W</span>ith an initial, \(Self.prose)</p><p class='after'>Below the initial.</p>"
        for paragraph in Self.paragraphs { body += "<p style='\(paragraph.style)'>\(paragraph.word) \(Self.prose)</p>" }
        for paragraph in Self.justified { body += "<p style='\(paragraph.style)'>\(paragraph.word) \(Self.prose)</p>" }
        body += "<p style='margin: 0 60px 0 40px; text-align: center'>Middle.</p><p style='margin: 0 60px 0 40px; text-align: right'>Edge.</p>"
        body += "<ol><li>Listed \(Self.prose)</li></ol>"
        return try H.build(body, css: css)
    }

    /// Each line of the paragraph starting with `word`, in text container coordinates.
    private func lines(_ word: String, in section: SectionText, view: ReaderTextView, offset: Int = 0) -> [CGRect] {
        let text = section.string.string as NSString
        let start = text.range(of: word).location
        guard start != NSNotFound else { XCTFail("\(word) is rendered"); return [] }
        var range = text.paragraphRange(for: NSRange(location: start, length: 0))
        range = NSRange(location: start, length: range.upperBound - start)
        while range.length > 0, ReaderAlignmentLayout.isParagraphBreak(text.character(at: range.upperBound - 1)) { range.length -= 1 }
        return view.segmentFrames(for: NSRange(location: range.location - offset, length: range.length))
    }

    func testIndentedParagraphsSitWhereTheyDoWithoutBoxGeometry() throws {
        let boxed = try section(floated: true), plain = try section(floated: false)
        let boxedView = H.scrolled(boxed, size: Self.size), plainView = H.scrolled(plain, size: Self.size)
        XCTAssertTrue(boxedView.readerContainer.hasNonlinearGeometry, "the float gives the text box geometry")
        XCTAssertFalse(plainView.readerContainer.hasNonlinearGeometry)
        // The text view keeps the hook that hides the indents from TextKit.
        XCTAssertTrue(boxedView.contentStorage.delegate === boxedView.readerContainer)
        for paragraph in Self.paragraphs + [("Listed", "", 0, 370)] {
            let expected = lines(paragraph.word, in: plain, view: plainView), actual = lines(paragraph.word, in: boxed, view: boxedView)
            XCTAssertGreaterThan(expected.count, 1, paragraph.word)
            XCTAssertEqual(actual.count, expected.count, "\(paragraph.word): the same lines")
            for (index, (line, reference)) in zip(actual, expected).enumerated() {
                XCTAssertEqual(line.minX, reference.minX, accuracy: 0.5, "\(paragraph.word), line \(index)")
                XCTAssertEqual(line.maxX, reference.maxX, accuracy: 0.5, "\(paragraph.word), line \(index)")
                XCTAssertGreaterThanOrEqual(line.minX, paragraph.left - 0.5, paragraph.word)
                XCTAssertLessThanOrEqual(line.maxX, paragraph.right + Self.hang, paragraph.word)
            }
        }
        // TextKit breaks a justified paragraph's lines differently where it places each line, so
        // the edges are what must hold: full lines from the left edge to the right one.
        for paragraph in Self.justified {
            let actual = lines(paragraph.word, in: boxed, view: boxedView)
            XCTAssertGreaterThan(actual.count, 1, paragraph.word)
            for (index, line) in actual.enumerated() {
                XCTAssertEqual(line.minX, paragraph.left + (index == 0 ? paragraph.indent : 0), accuracy: 0.5, "\(paragraph.word), line \(index)")
                if index < actual.count - 1 { XCTAssertGreaterThanOrEqual(line.maxX, paragraph.right - 1, "\(paragraph.word), line \(index)") }
                XCTAssertLessThanOrEqual(line.maxX, paragraph.right + Self.hang, paragraph.word)
            }
        }
        // One-line paragraphs, by their CSS: centred between the margins and ending at the right one.
        let middle = H.frame("Middle.", in: boxed, view: boxedView), edge = H.frame("Edge.", in: boxed, view: boxedView)
        XCTAssertEqual(middle.midX, 190, accuracy: 0.5)
        XCTAssertEqual(edge.maxX, 340, accuracy: 0.5)
        // A list item's text starts at the list's indent after its marker.
        let listed = H.frame("Listed", in: boxed, view: boxedView), reference = H.frame("Listed", in: plain, view: plainView)
        XCTAssertEqual(listed.minX, reference.minX, accuracy: 0.5)
        XCTAssertEqual(listed.minX, 40, accuracy: 0.5)
    }

    func testPagesWithBoxGeometryKeepParagraphIndents() throws {
        let boxed = try section(floated: true), plain = try section(floated: false)
        let size = CGSize(width: 400, height: 2_400)
        for word in ["Quoted", "Centred", "Ended", "Hanging", "Mirrored", "Middle.", "Edge.", "Listed"] {
            let actual = H.paged(word, in: boxed, size: size), expected = H.paged(word, in: plain, size: size)
            XCTAssertEqual(actual.frame.minX, expected.frame.minX, accuracy: 0.5, word)
            XCTAssertEqual(actual.frame.maxX, expected.frame.maxX, accuracy: 0.5, word)
        }
        XCTAssertEqual(H.paged("Middle.", in: boxed, size: size).frame.midX, 190, accuracy: 0.5)
        XCTAssertEqual(H.paged("Edge.", in: boxed, size: size).frame.maxX, 340, accuracy: 0.5)
    }

    /// A view that showed text with boxes shows plain text with its indents again.
    func testReplacingBoxedTextWithPlainTextRestoresItsIndents() throws {
        let boxed = try section(floated: true), plain = try section(floated: false)
        let view = H.scrolled(boxed, size: Self.size)
        XCTAssertTrue(view.readerContainer.hasNonlinearGeometry)
        view.setContent(plain.string)
        view.ensureFullLayout()
        XCTAssertFalse(view.readerContainer.hasNonlinearGeometry)
        let reference = H.scrolled(plain, size: Self.size)
        for word in ["Quoted", "Centred", "Ended", "Hanging"] {
            let actual = lines(word, in: plain, view: view), expected = lines(word, in: plain, view: reference)
            XCTAssertEqual(actual.count, expected.count, word)
            for (line, other) in zip(actual, expected) {
                XCTAssertEqual(line.minX, other.minX, accuracy: 0.5, word)
                XCTAssertEqual(line.maxX, other.maxX, accuracy: 0.5, word)
            }
        }
        view.setContent(boxed.string)
        view.ensureFullLayout()
        XCTAssertEqual(H.frame("Edge.", in: boxed, view: view).maxX, 340, accuracy: 0.5)
    }
}
