import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An inset beyond the column must leave visible lines and must not truncate the section
/// ([#289](https://github.com/vocaro/EPUBLib/issues/289)). Check characters in line fragments,
/// rather than merely checking the text storage, which can hold text TextKit never lays out.
@MainActor final class ExhaustedLineInsetTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private let float = "<div style='float:left; width:60px; height:40px'>F.</div>"

    private func assertVisibleCharacters(_ text: NSAttributedString, in view: ReaderTextView, width: CGFloat,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let lines = H.lines(in: view)
        let string = text.string as NSString
        for offset in 0..<text.length {
            let visible = lines.filter { NSLocationInRange(offset, $0.range) }
            XCTAssertFalse(visible.isEmpty, "character \(offset) has a visual line", file: file, line: line)
            if ReaderAlignmentLayout.isParagraphBreak(string.character(at: offset)) { continue }
            XCTAssertTrue(visible.contains { $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.minX < width && $0.frame.maxX > 0 },
                          "character \(offset) has a line intersecting the column: \(visible)", file: file, line: line)
            // A visible line can still carry a character outside its clipped width (a tab to an
            // over-wide marker's stop, for example). Its own selectable glyph must be visible.
            if let scalar = UnicodeScalar(string.character(at: offset)), CharacterSet.whitespaces.contains(scalar) { continue }
            let frames = view.segmentFrames(for: NSRange(location: offset, length: 1))
            XCTAssertTrue(frames.contains { $0.height > 0 && $0.minX < width && $0.maxX > 0 },
                          "character \(offset) intersects the column: \(frames)", file: file, line: line)
        }
    }

    private func check(_ body: String, at size: CGSize, css: String = "") throws {
        let section = try H.build(body, css: H.reset + css)
        let view = H.view(section.string, size: size, pageColumn: false)
        assertVisibleCharacters(section.string, in: view, width: size.width)
        let result = H.pages(section, size: size)
        for page in result.pages {
            let pageView = H.pageView(result.paginator, page: page)
            let pageText = result.paginator.text(for: page)
            let visibleText = pageText.attributedSubstring(from: NSRange(location: 0, length: page.range.length))
            assertVisibleCharacters(visibleText, in: pageView, width: size.width)
        }
    }

    func testRightToLeftPaddingAtAndBeyondTheColumnKeepsTheWholeSection() throws {
        for size in [CGSize(width: 180, height: 240), CGSize(width: 400, height: 600)] {
            for inset in [size.width, 600] {
                try check(float + "<div style='padding-left:\(inset)px'><p dir='rtl'>שלום עולם</p></div><p>After one.</p><p>After two.</p>", at: size)
            }
        }
    }

    func testExhaustedFirstLineAndHeadIndentsRemainVisibleWithAndWithoutBoxes() throws {
        for prefix in ["", float] {
            for direction in ["ltr", "rtl"] {
                try check(prefix + "<p dir='\(direction)' style='text-indent:500px'>First indented words.</p><p>After indent.</p>",
                          at: CGSize(width: 400, height: 600))
                try check(prefix + "<div style='padding-left:600px'><p dir='\(direction)'>Indented words wrap and continue.</p></div><p>After inset.</p>",
                          at: CGSize(width: 180, height: 240))
            }
        }
    }

    func testAMarkerWiderThanTheColumnKeepsTheMarkerAndItemVisible() throws {
        for prefix in ["", float] {
            try check(prefix + "<ol start='123456789'><li>Listed words.</li><li>After item.</li></ol><p>After list.</p>",
                      at: CGSize(width: 180, height: 600), css: "ol { list-style-type: decimal } li { font-size: 64px }")
        }
    }

    func testJustifiedListDropCapHasItsGlyphsIntrinsicWidth() throws {
        let size = CGSize(width: 400, height: 600)
        var intrinsicWidth: CGFloat?
        for alignment in ["left", "justify"] {
            let section = try H.build("<ol><li style='text-align:\(alignment)'><p><span style='float:left; font-size:3em'>D</span>rop cap words follow.</p></li></ol><p>After list.</p>", css: H.reset)
            let view = H.view(section.string, size: size)
            let region = try XCTUnwrap(H.region("D", in: section, view: view), alignment)
            let glyph = H.frame("D", in: section, view: view)
            XCTAssertLessThan(region.frame.width, 100, alignment)
            XCTAssertGreaterThanOrEqual(region.frame.width, glyph.width - 0.5, alignment)
            // A list's marker spacing contributes to the float's content width. Alignment
            // must retain that same intrinsic width, rather than stretch it to the column.
            if let intrinsicWidth {
                XCTAssertEqual(region.frame.width, intrinsicWidth, accuracy: 0.5, alignment)
            } else {
                intrinsicWidth = region.frame.width
            }
            assertVisibleCharacters(section.string, in: view, width: size.width)
            H.pages(section, size: size, alignment)
        }
    }
}
