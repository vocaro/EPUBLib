import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing

/// The book of `Fixture.inlineRows()` through the public reader: its chapter of marks is laid
/// out in pages and in continuous scroll, where it is four chapters below what the scroll view
/// lays out first, as the chapter is laid out by itself.
@MainActor final class BoxLayoutInlineRowSessionTests: XCTestCase {
    private typealias H = BoxLayoutHarness

    private func wait(_ label: String, timeout: TimeInterval = 30, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The lines of `chapter` each text view of `canvas` has laid out, by the chapter's own
    /// offsets, in that view's text container.
    private func lines(of chapter: Int, length: Int, in canvas: ReaderCanvasView) -> [(view: ReaderTextView, lines: [(range: NSRange, frame: CGRect)])] {
        canvas.textViews.compactMap { view in
            let start: Int, shown: NSRange
            if let book = canvas.scrollBook {
                start = -book.location(of: ReaderTextPosition(section: chapter, offset: 0))
                view.ensureLayout(from: -start, through: -start + length)
                shown = NSRange(location: -start, length: length)
            } else {
                guard view.placement.section == chapter else { return nil }
                start = view.placement.offset
                shown = view.shownCharacters
            }
            return (view, H.lines(in: view, intersecting: shown).map { (NSRange(location: $0.range.location + start, length: $0.range.length), $0.frame) })
        }
    }

    /// What `canvas` shows of `chapter` against the chapter laid out by itself in a column as
    /// wide: the same line breaks, each line as far right and as far below the first one shown.
    private func assertShownAsAlone(_ chapter: SectionText, in canvas: ReaderCanvasView, _ label: String) throws {
        let text = chapter.string.string as NSString
        let shown = lines(of: 4, length: chapter.string.length, in: canvas)
        let first = try XCTUnwrap(shown.first, label)
        XCTAssertNotNil(first.view.readerContainer.boxPage, "the chapter is laid out by its box geometry, \(label)")
        let size = CGSize(width: first.view.readerContainer.size.width, height: first.view.readerContainer.viewportSize.height)
        let expected = H.lines(in: H.view(chapter.string, size: size, pageColumn: false))
        var compared = 0, stars: [CGRect] = []
        for (view, lines) in shown {
            let top = try XCTUnwrap(lines.first, label)
            let other = try XCTUnwrap(expected.first { $0.range.location == top.range.location }, "\(label): the first line shown is a line of the chapter alone")
            for line in lines {
                guard let match = expected.first(where: { $0.range.location == line.range.location }) else {
                    XCTFail("\(label): the line at \(line.range) is not a line of the chapter alone")
                    continue
                }
                // In the book the chapter's last line also holds the break before the next chapter.
                XCTAssertEqual(min(line.range.upperBound, chapter.string.length), match.range.upperBound, "\(label) \(line.range)")
                XCTAssertEqual(line.frame.minX, match.frame.minX, accuracy: 0.5, "\(label) \(line.range)")
                XCTAssertEqual(line.frame.minY - top.frame.minY, match.frame.minY - other.frame.minY, accuracy: 0.5, "\(label) \(line.range)")
                compared += 1
                if text.substring(with: NSIntersectionRange(line.range, NSRange(location: 0, length: text.length))) == "*\n" { stars.append(line.frame) }
            }
            var overlapping = 0
            for (index, line) in lines.enumerated() {
                for other in lines.dropFirst(index + 1) where H.overlaps([line.frame.insetBy(dx: 0.5, dy: 0.5)], [other.frame.insetBy(dx: 0.5, dy: 0.5)]) { overlapping += 1 }
            }
            XCTAssertEqual(overlapping, 0, "no line is drawn over another, \(label) at \(view.placement.offset)")
        }
        XCTAssertGreaterThan(compared, 12, label)
        // Forty-nine marks in the chapter; whatever part of them is shown is in rows of several.
        XCTAssertGreaterThanOrEqual(stars.count, 9, "the first run is shown, \(label)")
        let rows = Dictionary(grouping: stars) { ($0.minY * 2).rounded() }
        XCTAssertLessThanOrEqual(rows.count * 3, stars.count * 2, "the marks are side by side, not one to a line: \(label)")
    }

    func testTheChapterOfMarksIsSetInRowsInPagesAndInContinuousScroll() async throws {
        let publication = try EPUBPublication.open(data: Fixture.inlineRows())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("the whole book") { session.readerState?.status.lifecycle == .ready && session.book.isComplete }
        let chapter = try XCTUnwrap(session.book.section(4))
        var positions: [EPUBReadingFlow: String] = [:]
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            try await session.send(.style(EPUBReaderStyle(fontSize: 17, flow: flow)))
            try await wait("\(flow) book") { session.book.isComplete && session.readerState?.status.style.flow == flow }
            try await session.send(.navigate(href: "OPS/torn.xhtml"))
            try await wait("\(flow) chapter") { session.visibleRange?.start == ReaderTextPosition(section: 4, offset: 0) }
            try await wait("\(flow) location") { session.readerState?.status.location?.href == "OPS/torn.xhtml" }
            positions[flow] = try XCTUnwrap(session.readerState?.status.location?.bookmark?.value)
            try assertShownAsAlone(chapter, in: try XCTUnwrap(session.canvas), "\(flow)")
        }
        // The fifth spine item, from its heading, in both flows; where the range ends is the flow's.
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            XCTAssertEqual(positions[flow]?.hasPrefix("epubcfi(/6/10!/4,/2[heading]/1:0,"), true, "\(flow): \(positions[flow] ?? "")")
        }
    }
}
