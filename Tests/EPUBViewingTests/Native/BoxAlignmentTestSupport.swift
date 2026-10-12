import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Builds sections through the production CSS cascade and measures where native layout puts
/// their text, for the flex and grid alignment tests.
@MainActor enum AlignmentHarness {
    /// Points. Shrink-to-fit adds a point of slack to a measured width, so an end-aligned line
    /// stops a point short of its edge, and TextKit and string drawing round a line's advance
    /// differently by a fraction of a point.
    static let tolerance: CGFloat = 2

    static func build(_ body: String, css: String, fontSize: CGFloat = 16, files: [String: Data] = [:]) throws -> SectionText {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css), files: files)
        return SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: NativeTypography(fontSize: fontSize), fonts: FontRegistry(publication: publication),
            rich: NativeRichContent()))
    }

    /// Ignoring case: a face without small capitals renders them as smaller capitals.
    static func range(_ phrase: String, in section: SectionText) -> NSRange {
        (section.string.string as NSString).range(of: phrase, options: .caseInsensitive)
    }

    /// The section in a text view of its own, as continuous scroll shows a section by itself.
    /// The view's y axis starts at the top edge of a box that opens the section.
    static func scrolled(_ section: SectionText, size: CGSize) -> ReaderTextView {
        let view = ReaderTextView(pageColumn: false)
        view.frame = CGRect(origin: .zero, size: size)
        view.readerContainer.size = CGSize(width: size.width, height: 0)
        view.readerContainer.viewportSize = size
        view.placement.visibleLength = section.string.length
        view.setContent(section.string)
        view.ensureFullLayout()
        return view
    }

    static func frame(_ phrase: String, in section: SectionText, view: ReaderTextView, offset: Int = 0,
                      file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        let range = range(phrase, in: section)
        XCTAssertNotEqual(range.location, NSNotFound, "\(phrase) is rendered", file: file, line: line)
        guard range.location != NSNotFound else { return .null }
        let frames = view.segmentFrames(for: NSRange(location: range.location - offset, length: range.length))
        XCTAssertFalse(frames.isEmpty, "\(phrase) is laid out", file: file, line: line)
        return frames.reduce(CGRect.null) { $0.union($1) }
    }

    /// Where paginated flow shows `phrase`: its page, and its frame in that page's column, from
    /// the top of the page's text area. Lays the page out as the canvas does.
    static func paged(_ phrase: String, in section: SectionText, size: CGSize,
                      file: StaticString = #filePath, line: UInt = #line) -> (page: Int, frame: CGRect) {
        let paginator = ReaderPaginator(text: section.string, size: size)
        let range = range(phrase, in: section)
        XCTAssertNotEqual(range.location, NSNotFound, "\(phrase) is rendered", file: file, line: line)
        guard range.location != NSNotFound else { return (0, .null) }
        let index = paginator.pageIndex(containing: range.location)
        let page = paginator.allPages[index]
        let view = ReaderTextView(pageColumn: true)
        view.frame = CGRect(x: 0, y: page.topSpacing, width: size.width, height: size.height - page.topSpacing)
        view.readerContainer.size = CGSize(width: size.width, height: 0)
        view.readerContainer.viewportSize = size
        view.placement = ReaderTextPlacement(section: 0, offset: page.range.location, visibleLength: page.range.length)
        view.setContent(paginator.text(for: page))
        view.ensureFullLayout()
        let frame = frame(phrase, in: section, view: view, offset: page.range.location, file: file, line: line)
        return (index, frame.offsetBy(dx: 0, dy: page.topSpacing))
    }

    static func assertEqual(_ value: CGFloat, _ expected: CGFloat, _ message: String = "", tolerance: CGFloat = tolerance,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, accuracy: tolerance, message, file: file, line: line)
    }
}
