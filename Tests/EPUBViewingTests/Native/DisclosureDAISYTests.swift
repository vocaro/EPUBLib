import CoreGraphics
import EPUBCore
import EPUBReading
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// DAISY's extdescription-010 in the reader ([#708](https://github.com/vocaro/EPUBLib/issues/708)):
/// a chart's long description, a table among it, in a details under the chart. The book is
/// fetched for a run and never committed ("DAISY's extended description test" in
/// doc/testing.md): `EPUBLIB_DAISY_EXTDESC` names it, and without it the test is skipped.
@MainActor final class DisclosureDAISYTests: XCTestCase {
    static let summary = "Expand / collapse Extended Description"

    func testDAISYsDetailsUnderAnImageOpensClosesAndHoldsATableOfData() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBLIB_DAISY_EXTDESC"], !path.isEmpty else {
            throw XCTSkip("EPUBLIB_DAISY_EXTDESC names no copy of DAISY's epub30-test-0350")
        }
        let publication = try EPUBPublication.open(at: URL(fileURLWithPath: path))
        let index = try XCTUnwrap(publication.spine.firstIndex { $0.resource.path.hasSuffix("testDetailsUnderImage.xhtml") })
        let reader = try SessionCoverageReader(publication: publication)
        defer { reader.close() }
        reader.window?.resize(to: CGSize(width: 600, height: 700))
        try await reader.settle()
        let session = reader.session
        // In continuous scroll the summary's line is at the top once its details is gone to,
        // so what follows it is on screen, whatever the chart above it takes of a page.
        try await session.send(.style(EPUBReaderStyle(flow: .scrolled)))
        try await reader.wait("the whole book in the scroll view") { session.canvas?.scrollBook != nil }
        try await reader.settle()
        let text = try XCTUnwrap(session.book.section(index))
        try await session.send(.navigate(href: text.href + "#image1-extended-desc"))

        // The details is closed, and its summary is its triangle and words.
        let disclosure = try XCTUnwrap(text.disclosures.first)
        XCTAssertEqual(text.disclosures.count, 1)
        XCTAssertFalse(disclosure.isOpenInBook)
        XCTAssertFalse(session.book.isOpen(disclosure, inSection: index))
        XCTAssertEqual((text.string.string as NSString).substring(with: disclosure.summary), "\u{25B8} " + Self.summary)
        let canvas = try XCTUnwrap(session.canvas)
        func shown() -> String {
            if let view = canvas.scrollTextView { return view.plainText(in: canvas.scrollVisibleCharacters() ?? NSRange()) }
            return canvas.textViews.map(\.visibleText).joined(separator: "\n")
        }
        XCTAssertTrue(shown().contains(Self.summary))
        XCTAssertFalse(shown().contains("Overview"), "a closed details shows only its summary")
        XCTAssertTrue(shown().contains("Filler text after the image"), "what follows stands under the summary: \(shown())")

        let range = ReaderTextRange(section: index, disclosure.summary.location..<NSMaxRange(disclosure.summary))
        func summaryView() throws -> (ReaderTextView, NSRange) {
            for view in canvas.textViews { if let local = canvas.localRange(of: range, in: view) { return (view, local) } }
            throw XCTSkip("the summary is not on screen")
        }
        #if os(iOS)
        func button() throws -> UIAccessibilityElement {
            let (view, _) = try summaryView()
            let listed = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
            return try XCTUnwrap(listed.first { $0.accessibilityLabel == Self.summary })
        }
        XCTAssertEqual(try button().accessibilityTraits, .button)
        XCTAssertEqual(try button().accessibilityExpandedStatus, .collapsed)
        XCTAssertTrue(try button().accessibilityActivate())
        XCTAssertTrue(session.book.isOpen(disclosure, inSection: index))
        XCTAssertEqual(try button().accessibilityExpandedStatus, .expanded)
        #else
        func triangle() throws -> ReaderLinkAccessibilityElement {
            let (view, _) = try summaryView()
            return try XCTUnwrap((view.accessibilityChildren() ?? []).compactMap { $0 as? ReaderLinkAccessibilityElement }
                .first { $0.accessibilityRole() == .disclosureTriangle })
        }
        XCTAssertEqual(try triangle().accessibilityTitle(), Self.summary)
        XCTAssertFalse(try triangle().isAccessibilityExpanded())
        XCTAssertTrue(try triangle().accessibilityPerformPress())
        XCTAssertTrue(session.book.isOpen(disclosure, inSection: index))
        XCTAssertTrue(try triangle().isAccessibilityExpanded())
        #endif
        XCTAssertTrue(shown().contains("Overview"), "open, the description follows its summary: \(shown())")

        // Its table is a table of data: five rows of four columns under their header cells.
        let rows = DisclosureTests.rows(in: text.string).filter { disclosure.hides($0.location) }
        XCTAssertEqual(rows.count, 5)
        let table = try XCTUnwrap(rows.first?.row.table)
        XCTAssertTrue(table.isData)
        XCTAssertEqual(table.columnCount, 4)
        XCTAssertTrue(table.cells.contains { $0.content.string == "Qtr Total" })

        // Closed again, the place is kept; search opens it to show what it finds.
        let start = session.visibleRange?.start
        session.setDisclosure(disclosure.id, inSection: index, open: false)
        XCTAssertEqual(session.visibleRange?.start, start)
        XCTAssertFalse(shown().contains("Overview"))
        try await session.send(.search(text: "Qtr Total"))
        let results = try XCTUnwrap(reader.state.status.searchResults?.results)
        XCTAssertEqual(results.filter { $0.spineIndex == index }.count, 1, "the table's last row; the book's other test has its own")
        XCTAssertTrue(session.book.isOpen(disclosure, inSection: index))
    }
}
