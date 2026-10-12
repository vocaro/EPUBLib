import EPUBCore
import EPUBReading
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Continuous scroll after an assistive technology has read the book's text (doc/native-viewer.md
/// "Continuous scroll"): the place reported and kept is still the text on screen.
///
/// VoiceOver and an XCUITest snapshot list one element for every paragraph of the book, each with
/// its frame, so UIKit asks TextKit 2 where every paragraph is and the whole book is laid out.
/// No assistive technology is driven here, and a test host has no accessibility elements to
/// walk: UIKit's text accessibility is not loaded in it, and the scroll text view answers with
/// none. `readEveryParagraph(of:)` stands in for the read by asking the text view for each
/// paragraph's rectangle through the platform's own text geometry (`firstRect(for:)` on UIKit,
/// `accessibilityFrame(for:)` on AppKit), which lays the book out the same way.
@MainActor final class ScrolledAccessibilityReadTests: XCTestCase {
    private typealias Subject = (reader: SessionCoverageReader, canvas: ReaderCanvasView, view: ReaderTextView)
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    /// Six chapters of labelled paragraphs ("d07" is the fourth chapter's seventh), the fourth
    /// some twenty screens into the book.
    private func book() throws -> Data {
        let chapters = [("front", 24), ("harbor", 28), ("market", 56), ("pass", 56), ("river", 50), ("summit", 31)]
        return try SessionCoverageBook.epub(chapters.enumerated().map { index, chapter in
            let letter = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(index)))
            var body = "<h1>Chapter \(chapter.0)</h1>"
            for paragraph in 1...chapter.1 {
                let label = "\(letter)" + (paragraph < 10 ? "0" : "") + "\(paragraph)"
                body += "<p>\(label) " + CanvasText.sentence(48 + (paragraph * 5 + index) % 9, seed: paragraph + index) + "</p>"
            }
            return SessionCoverageBook.Section(chapter.0, body, title: "Chapter \(chapter.0)")
        })
    }

    /// The scroll bar the scroll view has. A Mac prefers one kind by its pointing devices and its
    /// settings, and can change its mind while a reader is open: a legacy one takes its width
    /// from the text as soon as the text is longer than the window, an overlay one takes none.
    /// `preferred` leaves the scroll view with the kind this Mac prefers.
    private enum ScrollBar: String { case preferred, legacy, overlay }

    /// A reader as the steps that found the defect left it: opened in pages, sent to the fourth
    /// chapter, then switched to continuous scroll, so the chapters above it are only estimated.
    /// `shown` is whether the window has drawn the scroll view once, as it has by the time a
    /// person can do anything to it. On a Mac that first display lays the reader out again when
    /// a legacy scroll bar has narrowed the text, and aligns the scroll offset to the pixel grid.
    private func scrolledAtTheFourthChapter(scrollBar: ScrollBar = .preferred, shown: Bool = false) async throws -> Subject {
        let reader = try SessionCoverageReader(try book())
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 402, height: 874))
        try await reader.settle()
        try await reader.session.send(.navigate(href: reader.publication.spine[3].resource.href))
        try await reader.wait("the fourth chapter") { reader.section == 3 }
        try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
        try await reader.settle()
        let canvas = try XCTUnwrap(reader.session.canvas)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 3, offset: 0))
        #if os(macOS)
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
        switch scrollBar {
        case .preferred: // Which kind that is decides what these tests met, so the log says.
            print("Scroll bars this Mac prefers: \(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay")")
        case .legacy:
            scrollView.scrollerStyle = .legacy
            XCTAssertLessThan(scrollView.contentSize.width, canvas.bounds.width, "a legacy scroll bar takes its width from the text")
        case .overlay:
            scrollView.scrollerStyle = .overlay
            XCTAssertEqual(scrollView.contentSize.width, canvas.bounds.width, "an overlay scroll bar takes no width")
        }
        if shown { reader.window?.window.displayIfNeeded() }
        #endif
        return (reader, canvas, try XCTUnwrap(canvas.scrollTextView))
    }

    private func unlaidParagraphs(of view: ReaderTextView) -> Int {
        var count = 0
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.readerLayoutManager.documentRange.location, options: []) { fragment in
            if fragment.state != .layoutAvailable { count += 1 }
            return true
        }
        return count
    }

    /// Asks the text view where every paragraph of the book is, as a read of its accessibility
    /// elements does, and checks that this laid the whole book out.
    private func readEveryParagraph(of view: ReaderTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertGreaterThan(unlaidParagraphs(of: view), 100, "most of the book is only estimated before the read", file: file, line: line)
        let text = try XCTUnwrap(view.contentStorage.textStorage).string as NSString
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            #if os(macOS)
            _ = view.accessibilityFrame(for: range)
            #else
            if let start = view.position(from: view.beginningOfDocument, offset: range.location),
               let end = view.position(from: start, offset: range.length), let paragraph = view.textRange(from: start, to: end) {
                _ = view.firstRect(for: paragraph)
            }
            #endif
        }
        XCTAssertEqual(unlaidParagraphs(of: view), 0, "the read lays the whole book out", file: file, line: line)
    }

    /// The characters TextKit 2 laid out for the scroll view's viewport: what the view draws.
    private func drawnCharacters(of view: ReaderTextView) throws -> Range<Int> {
        let range = try XCTUnwrap(view.readerLayoutManager.textViewportLayoutController.viewportRange)
        return view.offset(of: range.location)..<view.offset(of: range.endLocation)
    }

    /// The label of the paragraph holding `position`, for a failure's message.
    private func paragraph(at position: ReaderTextPosition, in reader: SessionCoverageReader) -> String {
        guard let text = reader.session.book.section(position.section)?.string.string as NSString?, text.length > 0 else { return "?" }
        let range = text.paragraphRange(for: NSRange(location: min(position.offset, text.length - 1), length: 0))
        return text.substring(with: NSRange(location: range.location, length: min(3, range.length)))
    }

    /// The reported and kept place is in the text the view draws, and one screen on from `before`.
    private func assertShown(_ range: ReaderTextRange, after before: ReaderTextRange, _ label: String, _ subject: Subject,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let (reader, canvas, view) = subject
        let book = try XCTUnwrap(canvas.scrollBook, file: file, line: line)
        let drawn = try drawnCharacters(of: view)
        let first = paragraph(at: book.position(at: drawn.lowerBound), in: reader)
        XCTAssertTrue(drawn.contains(book.location(of: range.start)),
                      "\(label): the view draws from paragraph \(first) and the reader reports paragraph \(paragraph(at: range.start, in: reader))",
                      file: file, line: line)
        XCTAssertLessThanOrEqual(book.location(of: range.end), drawn.upperBound, "\(label): the reported end is drawn", file: file, line: line)
        XCTAssertEqual(range.start.section, 3, "\(label): a screen on from the fourth chapter's start is in that chapter", file: file, line: line)
        XCTAssertGreaterThan(range.start, before.start, "\(label): moved on", file: file, line: line)
        XCTAssertLessThan(range.start, before.end, "\(label): the last line read is still on screen", file: file, line: line)
        XCTAssertEqual(canvas.anchor, range.start, "\(label): the visible start is the position kept", file: file, line: line)
        XCTAssertEqual(reader.session.visibleRange, range, label, file: file, line: line)
        XCTAssertEqual(reader.locations.last?.href, reader.publication.spine[3].resource.href,
                       "\(label): the chapter on screen is the chapter reported", file: file, line: line)
    }

    /// Back in pages, the page shown holds `kept`, the line that was first on screen, and is in
    /// the text the scroll view was drawing.
    private func assertPagesShow(_ kept: ReaderTextPosition, _ subject: Subject, _ label: String = "",
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let (reader, canvas, view) = subject
        let book = try XCTUnwrap(canvas.scrollBook, file: file, line: line)
        let drawn = try drawnCharacters(of: view)
        try await reader.session.send(.style(EPUBReaderStyle(flow: .paginated)))
        try await reader.wait("pages", file: file, line: line) { canvas.scrollTextView == nil && canvas.shownPage != nil }
        let page = try XCTUnwrap(canvas.visibleRange, file: file, line: line)
        let places = "\(label)the page begins in paragraph \(paragraph(at: page.start, in: reader)), the scroll view drew from "
            + "\(paragraph(at: book.position(at: drawn.lowerBound), in: reader)) and its first line was in \(paragraph(at: kept, in: reader))"
        XCTAssertTrue(page.start <= kept && kept < page.end, places, file: file, line: line)
        XCTAssertTrue(book.location(of: page.start) < drawn.upperBound && book.location(of: page.end) > drawn.lowerBound, places, file: file, line: line)
        XCTAssertEqual(reader.locations.last?.href, reader.publication.spine[3].resource.href, label, file: file, line: line)
    }

    /// The steps that found the defect: Scroll Forward twice after the read, then back to pages.
    private func assertScrollStepsAfterAReadKeepTheTextOnScreen(_ subject: Subject, _ label: String = "") async throws {
        let (reader, canvas, view) = subject
        let opening = try XCTUnwrap(canvas.visibleRange)
        try readEveryParagraph(of: view)
        try await reader.session.send(.nextPage)
        let first = try XCTUnwrap(canvas.visibleRange)
        try assertShown(first, after: opening, label + "the first step", subject)
        try await reader.session.send(.nextPage)
        let second = try XCTUnwrap(canvas.visibleRange)
        try assertShown(second, after: first, label + "the second step", subject)
        try await assertPagesShow(second.start, subject, label)
    }

    /// The read comes when the view is at rest, so a change of flow can follow it with no scroll
    /// between: the place the person scrolled to is read off the screen as the read left it.
    private func assertAChangeToPagesAfterAReadShowsTheTextScrolledTo(_ subject: Subject, _ label: String = "") async throws {
        let (reader, canvas, view) = subject
        let opening = try XCTUnwrap(canvas.visibleRange)
        // The person scrolls a few screens on (not through the canvas).
        #if os(macOS)
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + 2_000))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #else
        view.contentOffset.y += 2_000
        #endif
        try await reader.wait(label + "the place scrolled to") { (canvas.visibleRange?.start ?? opening.start) > opening.end }
        let reading = try XCTUnwrap(canvas.visibleRange?.start)
        XCTAssertEqual(reading.section, 3, label)
        try readEveryParagraph(of: view)
        try await assertPagesShow(reading, subject, label)
    }

    func testScrollStepsAfterAReadOfEveryParagraphReportAndKeepTheTextOnScreen() async throws {
        try await assertScrollStepsAfterAReadKeepTheTextOnScreen(try await scrolledAtTheFourthChapter())
    }

    func testAChangeToPagesAfterAReadShowsTheTextThePersonScrolledTo() async throws {
        try await assertAChangeToPagesAfterAReadShowsTheTextScrolledTo(try await scrolledAtTheFourthChapter())
    }

    #if os(macOS)
    /// Both hold with either scroll bar, whichever this Mac prefers, whether the read comes before
    /// the scroll view's first display or straight after it. With a legacy scroll bar that display
    /// lays the narrowed text out again, leaving the chapters above estimated, and AppKit then
    /// moves the view a fraction of a point onto the pixel grid. The reader took that for a view
    /// that had moved and no longer held its first line, so the place was a chapter back
    /// ([#302](https://github.com/vocaro/EPUBLib/issues/302)).
    private func assertThePlaceIsKeptThroughARead(with scrollBar: ScrollBar) async throws {
        for shown in [false, true] {
            let label = "\(scrollBar.rawValue) scroll bar, \(shown ? "shown" : "not yet shown"): "
            try await assertScrollStepsAfterAReadKeepTheTextOnScreen(
                try await scrolledAtTheFourthChapter(scrollBar: scrollBar, shown: shown), label)
            try await assertAChangeToPagesAfterAReadShowsTheTextScrolledTo(
                try await scrolledAtTheFourthChapter(scrollBar: scrollBar, shown: shown), label)
        }
    }

    func testThePlaceIsKeptThroughAReadWithALegacyScrollBar() async throws {
        try await assertThePlaceIsKeptThroughARead(with: .legacy)
    }

    func testThePlaceIsKeptThroughAReadWithAnOverlayScrollBar() async throws {
        try await assertThePlaceIsKeptThroughARead(with: .overlay)
    }
    #endif
}
