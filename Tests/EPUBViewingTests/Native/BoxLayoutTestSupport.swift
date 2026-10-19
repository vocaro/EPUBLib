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

/// Sections through the production cascade and builder, laid out by the reader's own TextKit
/// stack without a window, for the box layout coverage tests (`BoxLayout…CoverageTests`).
@MainActor enum BoxLayoutHarness {
    /// No user-agent margins, padding or indents: every expected coordinate is the rule under test.
    static let reset = "html, body { margin: 0; padding: 0 } p, div, figure, figcaption, aside, section, blockquote, ul, ol, li, "
        + "h1, h2, h3, main, footer, header { margin: 0; padding: 0; text-indent: 0 } "

    static let prose = Array(repeating: "Ordinary prose wraps beside the box and returns to the full column below it.",
                             count: 14).joined(separator: " ")

    static func build(_ body: String, css: String, fontSize: CGFloat = 16, files: [String: Data] = [:]) throws -> SectionText {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css), files: files)
        return SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: NativeTypography(fontSize: fontSize), fonts: FontRegistry(publication: publication),
            rich: NativeRichContent()))
    }

    /// The whole of `text` in one text view, every line laid out. The y axis starts at the text's top.
    static func view(_ text: NSAttributedString, size: CGSize, pageColumn: Bool = true) -> ReaderTextView {
        let view = ReaderTextView(pageColumn: pageColumn)
        view.frame = CGRect(origin: .zero, size: size)
        view.readerContainer.size = CGSize(width: size.width, height: 0)
        view.readerContainer.viewportSize = size
        view.placement = ReaderTextPlacement(section: 0, offset: 0, visibleLength: text.length)
        view.setContent(text)
        view.ensureFullLayout()
        return view
    }

    static func range(_ phrase: String, in section: SectionText, file: StaticString = #filePath, line: UInt = #line) -> NSRange {
        let range = (section.string.string as NSString).range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound, "\(phrase) is rendered", file: file, line: line)
        return range
    }

    /// The union of `phrase`'s laid-out segments, in text container coordinates; null when absent.
    static func frame(_ phrase: String, in section: SectionText, view: ReaderTextView,
                      file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        let range = range(phrase, in: section, file: file, line: line)
        guard range.location != NSNotFound else { return .null }
        let frames = view.segmentFrames(for: range)
        XCTAssertFalse(frames.isEmpty, "\(phrase) is laid out", file: file, line: line)
        return frames.reduce(CGRect.null) { $0.union($1) }
    }

    /// Each visual line touching `range`: its characters and typographic bounds.
    static func lines(in view: ReaderTextView, intersecting range: NSRange? = nil) -> [(range: NSRange, frame: CGRect)] {
        var result: [(NSRange, CGRect)] = []
        let wanted = range ?? NSRange(location: 0, length: view.textLength)
        view.readerLayoutManager.enumerateTextLayoutFragments(from: view.contentStorage.documentRange.location,
                                                               options: [.ensuresLayout]) { fragment in
            let start = view.offset(of: fragment.rangeInElement.location)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                let lineRange = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
                if NSIntersectionRange(wanted, lineRange).length > 0 {
                    result.append((lineRange, line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                                             dy: fragment.layoutFragmentFrame.origin.y)))
                }
            }
            return true
        }
        return result
    }

    /// The lines of `phrase`, each trimmed of the blanks TextKit hangs past a line's end.
    static func ink(_ phrase: String, in section: SectionText, view: ReaderTextView,
                    file: StaticString = #filePath, line: UInt = #line) -> [CGRect] {
        let range = range(phrase, in: section, file: file, line: line)
        guard range.location != NSNotFound else { return [] }
        let text = section.string.string as NSString
        return lines(in: view, intersecting: range).flatMap { entry -> [CGRect] in
            var part = NSIntersectionRange(entry.range, range)
            while part.length > 0, let scalar = UnicodeScalar(text.character(at: part.upperBound - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { part.length -= 1 }
            return part.length > 0 ? view.segmentFrames(for: part) : []
        }
    }

    /// The planned exclusion of the float, positioned box or sized inline-block holding `phrase`.
    static func region(_ phrase: String, in section: SectionText, view: ReaderTextView,
                       file: StaticString = #filePath, line: UInt = #line) -> ReaderBoxGeometry.Region? {
        let range = range(phrase, in: section, file: file, line: line)
        return view.readerContainer.boxRegions.first { !$0.reserved && NSIntersectionRange($0.range, range).length > 0 }
    }

    static func overlaps(_ first: [CGRect], _ second: [CGRect]) -> Bool {
        first.contains { a in second.contains { b in
            let overlap = a.intersection(b)
            return !overlap.isNull && overlap.width >= 0.5 && overlap.height >= 0.5
        } }
    }

    /// Pages `section` at `size` and checks what every pagination owes the reader: the pages
    /// cover the text once, in order, and none is taller than its column.
    @discardableResult
    static func pages(_ section: SectionText, size: CGSize, _ label: String = "",
                      file: StaticString = #filePath, line: UInt = #line) -> (paginator: ReaderPaginator, pages: [ReaderPage]) {
        let paginator = ReaderPaginator(text: section.string, size: size)
        let pages = paginator.allPages
        var cursor = 0, copied = ""
        for page in pages {
            XCTAssertEqual(page.range.location, cursor, "pages are contiguous \(label)", file: file, line: line)
            cursor = page.range.upperBound
            XCTAssertLessThanOrEqual(page.height + page.topSpacing, size.height + 0.75, "a page fits its column \(label)", file: file, line: line)
            copied += (paginator.text(for: page).string as NSString).substring(to: page.range.length)
        }
        XCTAssertEqual(cursor, section.string.length, "the pages reach the end \(label)", file: file, line: line)
        XCTAssertEqual(copied, section.string.string, "the pages hold every character once \(label)", file: file, line: line)
        return (paginator, pages)
    }

    /// One page's column, laid out as the canvas lays it out.
    static func pageView(_ paginator: ReaderPaginator, page: ReaderPage) -> ReaderTextView {
        let view = ReaderTextView(pageColumn: true)
        view.frame = CGRect(origin: .zero, size: CGSize(width: paginator.size.width, height: paginator.size.height - page.topSpacing))
        view.readerContainer.size = CGSize(width: paginator.size.width, height: 0)
        view.readerContainer.viewportSize = paginator.size
        view.placement = ReaderTextPlacement(section: 0, offset: page.range.location, visibleLength: page.range.length)
        view.setContent(paginator.text(for: page))
        view.ensureFullLayout()
        return view
    }

    static func paragraphStyle(_ phrase: String, in section: SectionText, text: NSAttributedString,
                               file: StaticString = #filePath, line: UInt = #line) -> NSParagraphStyle {
        let range = range(phrase, in: section, file: file, line: line)
        guard range.location != NSNotFound else { return .default }
        return text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
    }

    static func hasAlignment(_ section: SectionText) -> Bool {
        var tagged = false
        section.string.enumerateAttribute(.readerAlignment, in: NSRange(location: 0, length: section.string.length)) { value, _, stop in
            if value != nil { tagged = true; stop.pointee = true }
        }
        return tagged
    }
}
