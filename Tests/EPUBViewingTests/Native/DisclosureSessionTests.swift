import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A details in a reader ([#708](https://github.com/vocaro/EPUBLib/issues/708), "Details and
/// summary" in `doc/native-viewer.md`): its summary opens and closes it in place in either
/// flow, what a closed one holds is not on the page, and search, a link's target and a saved
/// position inside it open it. VoiceOver's own reading of it is in doc/testing.md; here the
/// elements it is given are read through the protocols it uses.
@MainActor final class DisclosureSessionTests: XCTestCase {
    private var readers: [SessionCoverageReader] = []

    override func tearDown() async throws {
        for reader in readers { reader.close() }
        readers.removeAll()
        try await super.tearDown()
    }

    private func reader(flow: EPUBReadingFlow = .paginated) async throws -> SessionCoverageReader {
        let book = try SessionCoverageBook.epub([
            SessionCoverageBook.Section("chart", DisclosureTests.body + SessionCoverageBook.filler(40), title: "Chart"),
            SessionCoverageBook.Section("after", "<h1>After</h1><p>The next section.</p>", title: "After")])
        let reader = try SessionCoverageReader(book)
        readers.append(reader)
        reader.window?.resize(to: CGSize(width: 600, height: 700))
        try await reader.settle()
        if flow == .scrolled {
            try await reader.session.send(.style(EPUBReaderStyle(flow: .scrolled)))
            try await reader.wait("the whole book in the scroll view") { reader.session.canvas?.scrollBook != nil }
            try await reader.settle()
        }
        return reader
    }

    private func disclosure(_ reader: SessionCoverageReader) throws -> ReaderDisclosure {
        try XCTUnwrap(reader.session.book.section(0)?.disclosures.first)
    }

    private func isOpen(_ reader: SessionCoverageReader) throws -> Bool {
        reader.session.book.isOpen(try disclosure(reader), inSection: 0)
    }

    /// What the reader shows: the page's columns, or the lines on screen in continuous scroll.
    private func shown(_ reader: SessionCoverageReader) throws -> String {
        let canvas = try XCTUnwrap(reader.session.canvas)
        if let view = canvas.scrollTextView {
            return view.plainText(in: try XCTUnwrap(canvas.scrollVisibleCharacters()))
        }
        return canvas.textViews.map(\.visibleText).joined(separator: "\n")
    }

    /// The text view showing the summary, and the summary's characters in it.
    private func summary(_ reader: SessionCoverageReader, file: StaticString = #filePath, line: UInt = #line) throws
        -> (view: ReaderTextView, range: NSRange) {
        let canvas = try XCTUnwrap(reader.session.canvas, file: file, line: line)
        let summary = try disclosure(reader).summary
        let range = ReaderTextRange(section: 0, summary.location..<NSMaxRange(summary))
        for view in canvas.textViews { if let local = canvas.localRange(of: range, in: view) { return (view, local) } }
        throw SessionCoverageTimeout(description: "the summary is not on screen")
    }

    /// Where the summary's words are on the canvas.
    private func summaryFrame(_ reader: SessionCoverageReader) throws -> CGRect {
        let (view, range) = try summary(reader)
        let frame = view.segmentFrames(for: range).reduce(CGRect.null) { $0.union($1) }
        XCTAssertFalse(frame.isNull)
        let origin = view.containerOrigin
        return view.convert(frame.offsetBy(dx: origin.x, dy: origin.y), to: try XCTUnwrap(reader.session.canvas))
    }

    /// A touch or a click on the summary: what the text views' link handling calls.
    private func activate(_ reader: SessionCoverageReader) throws {
        let (view, range) = try summary(reader)
        let url = try XCTUnwrap(view.contentStorage.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
        try XCTUnwrap(reader.session.canvas).activateLink(url, range: range, in: view)
    }

    // MARK: Opening and closing

    func testTheSummaryOpensAndClosesItsDetailsAndThePlaceIsKept() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try await reader(flow: flow)
            let label = "\(flow)"
            XCTAssertFalse(try isOpen(reader), label)
            let closedText = try shown(reader)
            XCTAssertTrue(closedText.contains(DisclosureTests.summary), label)
            XCTAssertTrue(closedText.contains("Words after the chart."), "\(label): what follows the details stands under its summary")
            for word in DisclosureTests.hiddenWords { XCTAssertFalse(closedText.contains(word), "\(label): \(word) is on the page") }
            let start = try XCTUnwrap(reader.session.visibleRange?.start)
            let place = try summaryFrame(reader)
            let length = try XCTUnwrap(reader.session.book.section(0)?.string.length)

            try activate(reader)
            XCTAssertTrue(try isOpen(reader), label)
            let openText = try shown(reader)
            for word in DisclosureTests.hiddenWords { XCTAssertTrue(openText.contains(word), "\(label): \(word) is shown") }
            XCTAssertEqual(reader.session.visibleRange?.start, start, "\(label): the same place")
            XCTAssertEqual(try summaryFrame(reader).minY, place.minY, accuracy: 1, "\(label): the summary stays where it was")
            XCTAssertEqual(reader.session.book.section(0)?.string.length, length, "\(label): no character comes or goes")

            try activate(reader)
            XCTAssertFalse(try isOpen(reader), label)
            XCTAssertEqual(try shown(reader), closedText, "\(label): closed again, as before")
            XCTAssertEqual(reader.session.visibleRange?.start, start, label)
            XCTAssertEqual(try summaryFrame(reader).minY, place.minY, accuracy: 1, label)
            reader.close()
        }
    }

    func testAnOpenAttributeShowsTheDetailsOpenAndItsSummaryClosesIt() async throws {
        let book = try SessionCoverageBook.epub([
            SessionCoverageBook.Section("chart", DisclosureTests.body.replacingOccurrences(of: "<details id=", with: "<details open=\"\" id="),
                                        title: "Chart")])
        let reader = try SessionCoverageReader(book)
        readers.append(reader)
        try await reader.settle()
        XCTAssertTrue(try isOpen(reader))
        XCTAssertTrue(try shown(reader).contains("Harbor arrivals"))
        try activate(reader)
        XCTAssertFalse(try isOpen(reader))
        XCTAssertFalse(try shown(reader).contains("Harbor arrivals"))
    }

    func testAPassageCopiedAcrossAClosedDetailsTakesNothingItHides() async throws {
        let reader = try await reader()
        let text = try XCTUnwrap(reader.session.book.section(0))
        let characters = text.string.string as NSString
        let range = ReaderTextRange(section: 0, characters.range(of: "Words before").location
                                    ..< NSMaxRange(characters.range(of: "Words after the chart.")))
        XCTAssertEqual(reader.session.selectionText(in: range),
                       "Words before the chart.\n\(DisclosureTests.summary)\nWords after the chart.")
        reader.session.setDisclosure(try disclosure(reader).id, inSection: 0, open: true)
        let open = try XCTUnwrap(reader.session.selectionText(in: range))
        for word in DisclosureTests.hiddenWords { XCTAssertTrue(open.contains(word), word) }
    }

    // MARK: Search, targets and saved places

    func testSearchFindsWordsInAClosedDetailsAndOpensItToShowThem() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try await reader(flow: flow)
            let label = "\(flow)"
            // Listed without being shown: the details stays closed.
            try await reader.session.send(.searchHighlight(text: "harbor arrivals"))
            let results = try XCTUnwrap(reader.state.status.searchResults, label)
            XCTAssertEqual(results.results.count, 1, label)
            let result = try XCTUnwrap(results.results.first)
            XCTAssertEqual(result.matchedText, "Harbor arrivals", label)
            XCTAssertEqual(result.contextAfter, " fell each month.", label)
            XCTAssertFalse(try isOpen(reader), label)
            // Its place is the words' own: the range of the text and the CFI of the document.
            let text = try XCTUnwrap(reader.session.book.section(0))
            let words = (text.string.string as NSString).range(of: "Harbor arrivals")
            let range = try XCTUnwrap(reader.session.searchResultRanges.first)
            XCTAssertEqual(range, ReaderTextRange(section: 0, words.location..<NSMaxRange(words)), label)
            let dom = try XCTUnwrap(text.domRange(range))
            XCTAssertEqual(TextSearch.text(of: TextSearch.Match(start: dom.start, end: dom.end), in: text.document), "Harbor arrivals", label)
            let bookmark = try XCTUnwrap(result.location.bookmark?.value)
            let target = try XCTUnwrap(SpineCFIs(publication: reader.publication).resolve(bookmark))
            XCTAssertEqual(target.spineIndex, 0)
            let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: text.document))
            XCTAssertEqual(ReaderTextRange(start: text.renderedPosition(resolved.start), end: text.renderedPosition(resolved.end, isEnd: true)),
                           range, "\(label): the CFI names the words in the details")
            // Shown, it opens the details and shows the words.
            try await reader.session.send(.showSearchResult(result))
            XCTAssertTrue(try isOpen(reader), label)
            XCTAssertTrue(try shown(reader).contains("Harbor arrivals fell each month."), label)
            XCTAssertEqual(reader.session.searchResultRanges.first, range, "\(label): its place has not moved")
            XCTAssertEqual(reader.session.drawnHighlights.last?.range, range, label)
            // A search that shows what it finds opens it as well.
            try await reader.session.send(.clearSearch)
            reader.session.setDisclosure(try disclosure(reader).id, inSection: 0, open: false)
            XCTAssertFalse(try isOpen(reader))
            try await reader.session.send(.search(text: "Closing remark"))
            XCTAssertTrue(try isOpen(reader), label)
            XCTAssertTrue(try shown(reader).contains("Closing remark inside."), label)
            reader.close()
        }
    }

    func testALinkTargetOrASavedPlaceInsideAClosedDetailsOpensIt() async throws {
        let reader = try await reader()
        let href = try XCTUnwrap(reader.session.book.section(0)?.href)
        try await reader.session.send(.navigate(href: href + "#inside"))
        XCTAssertTrue(try isOpen(reader))
        XCTAssertTrue(try shown(reader).contains("Closing remark inside."))
        XCTAssertTrue(reader.isVisible(try reader.anchor("inside", section: 0)))
        // A place saved there is restored there, opening the details again.
        try await reader.session.send(.locate(text: "Closing remark inside.", highlight: true))
        try await reader.wait("the passage selected") { reader.session.selection?.text == "Closing remark inside." }
        let saved = try XCTUnwrap(reader.session.selection)
        let location = try XCTUnwrap(reader.selections().last??.location)
        reader.session.setDisclosure(try disclosure(reader).id, inSection: 0, open: false)
        try await reader.session.send(.navigate(href: try XCTUnwrap(reader.session.book.section(1)?.href)))
        XCTAssertFalse(try isOpen(reader))
        try await reader.session.send(.restore(location))
        XCTAssertTrue(try isOpen(reader))
        XCTAssertTrue(reader.isVisible(saved.range.start))
        // A place outside it leaves it as it is.
        reader.session.setDisclosure(try disclosure(reader).id, inSection: 0, open: false)
        try await reader.session.send(.navigate(href: href))
        XCTAssertFalse(try isOpen(reader))
    }

    // MARK: VoiceOver

    #if os(iOS)
    private func elements(_ view: ReaderTextView) throws -> [UIAccessibilityElement] {
        try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
    }

    func testVoiceOverIsGivenTheSummaryAsAButtonThatSaysWhetherItIsExpanded() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try await reader(flow: flow)
            let label = "\(flow)"
            let (view, _) = try summary(reader)
            var listed = try elements(view)
            var button = try XCTUnwrap(listed.first { $0.accessibilityLabel == DisclosureTests.summary }, label)
            XCTAssertEqual(button.accessibilityTraits, .button, "\(label): a button, not a link")
            XCTAssertEqual(button.accessibilityExpandedStatus, .collapsed, label)
            for word in DisclosureTests.hiddenWords {
                XCTAssertFalse(listed.contains { $0.accessibilityLabel?.contains(word) == true }, "\(label): \(word) is read")
            }
            XCTAssertFalse(listed.contains { $0 is UIAccessibilityContainerDataTable }, "\(label): no table while it is closed")
            // A double tap opens it, and VoiceOver is told that the summary changed, to read it again.
            var posted: [(UIAccessibility.Notification, Any?)] = []
            try XCTUnwrap(reader.session.canvas).postToAccessibility = { posted.append(($0, $1)) }
            XCTAssertTrue(button.accessibilityActivate(), label)
            XCTAssertTrue(try isOpen(reader), label)
            XCTAssertTrue(posted.contains { $0.0 == .layoutChanged && $0.1 as AnyObject === button }, label)
            let opened = try summary(reader).view
            try await reader.wait("the cells' text views") { opened.tableInteraction?.cells.isEmpty == false }
            listed = try elements(opened)
            button = try XCTUnwrap(listed.first { $0.accessibilityLabel == DisclosureTests.summary }, label)
            XCTAssertEqual(button.accessibilityTraits, .button, label)
            XCTAssertEqual(button.accessibilityExpandedStatus, .expanded, label)
            XCTAssertTrue(listed.contains { $0.accessibilityLabel?.contains("Harbor arrivals") == true }, label)
            // The table it holds is a table of data, its cells in their rows and columns.
            let table = try XCTUnwrap(listed.compactMap { $0 as? UIAccessibilityElement & UIAccessibilityContainerDataTable }.first,
                                      "\(label): the table is a table to VoiceOver")
            XCTAssertEqual(table.accessibilityRowCount(), 3, label)
            XCTAssertEqual(table.accessibilityColumnCount(), 2, label)
            let cell = try XCTUnwrap(table.accessibilityDataTableCellElement(forRow: 1, column: 1) as? UIAccessibilityElement, label)
            XCTAssertEqual(cell.accessibilityLabel, "41", label)
            // And closes it again.
            XCTAssertTrue(button.accessibilityActivate(), label)
            XCTAssertFalse(try isOpen(reader), label)
            let closed = try elements(try summary(reader).view)
            XCTAssertEqual(closed.first { $0.accessibilityLabel == DisclosureTests.summary }?.accessibilityExpandedStatus, .collapsed, label)
            reader.close()
        }
    }
    #else
    private func disclosureChildren(_ view: ReaderTextView) -> [ReaderLinkAccessibilityElement] {
        (view.accessibilityChildren() ?? []).compactMap { $0 as? ReaderLinkAccessibilityElement }
            .filter { $0.accessibilityRole() == .disclosureTriangle }
    }

    func testVoiceOverIsGivenTheSummaryAsADisclosureTriangleThatSaysWhetherItIsExpanded() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try await reader(flow: flow)
            let label = "\(flow)"
            let (view, range) = try summary(reader)
            let triangle = try XCTUnwrap(disclosureChildren(view).first, "\(label): among the text's children")
            XCTAssertEqual(triangle.accessibilityTitle(), DisclosureTests.summary, label)
            XCTAssertNil(triangle.accessibilitySubrole(), label)
            XCTAssertFalse(triangle.isAccessibilityExpanded(), label)
            XCTAssertEqual(triangle.accessibilityValue() as? NSNumber, 0, label)
            XCTAssertEqual(triangle.range, range, label)
            // What the text gives an assistive client of a closed details is spaces and the
            // breaks of lines that take no room.
            let value = try XCTUnwrap(view.accessibilityValue())
            for word in DisclosureTests.hiddenWords { XCTAssertFalse(value.contains(word), "\(label): \(word) is given") }
            // Control-Option-Space opens it.
            XCTAssertTrue(triangle.accessibilityPerformPress(), label)
            XCTAssertTrue(try isOpen(reader), label)
            let opened = try summary(reader).view
            let expanded = try XCTUnwrap(disclosureChildren(opened).first, label)
            XCTAssertTrue(expanded.isAccessibilityExpanded(), label)
            XCTAssertEqual(expanded.accessibilityValue() as? NSNumber, 1, label)
            XCTAssertTrue(try XCTUnwrap(opened.accessibilityValue()).contains("Harbor arrivals"), label)
            // The table it holds is a table to VoiceOver: one element at each of its rows.
            try await reader.wait("the cells' text views") { opened.tableInteraction?.cells.isEmpty == false }
            let rich = try XCTUnwrap(opened.accessibilityAttributedString(for: opened.isPageColumn ? opened.shownCharacters
                                                                           : NSRange(location: 0, length: opened.textLength)))
            var tables: [NSAccessibilityElement] = []
            rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
                if let element = value as? NSAccessibilityElement, element.accessibilityRole() == .table { tables.append(element) }
            }
            XCTAssertFalse(tables.isEmpty, "\(label): the table is a table to VoiceOver")
            XCTAssertEqual(tables.first?.accessibilityRows()?.count, 3, label)
            XCTAssertTrue(expanded.accessibilityPerformPress(), label)
            XCTAssertFalse(try isOpen(reader), label)
            reader.close()
        }
    }

    func testAClickOnTheSummaryOpensAndClosesIt() async throws {
        let reader = try await reader()
        let canvas = try XCTUnwrap(reader.session.canvas)
        let (view, range) = try summary(reader)
        let url = try XCTUnwrap(view.contentStorage.textStorage?.attribute(.link, at: range.location, effectiveRange: nil))
        XCTAssertTrue(canvas.textView(view, clickedOnLink: url, at: range.location))
        XCTAssertTrue(try isOpen(reader))
        let opened = try summary(reader)
        XCTAssertTrue(canvas.textView(opened.view, clickedOnLink: url, at: opened.range.location + 2), "the triangle and the words alike")
        XCTAssertFalse(try isOpen(reader))
    }
    #endif
}
