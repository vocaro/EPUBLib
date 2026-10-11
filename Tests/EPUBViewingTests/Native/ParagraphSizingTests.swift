import CoreText
import EPUBReading
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class ParagraphSizingTests: XCTestCase {
    private func build(_ body: String, css: String, size: CGFloat = 16) throws -> SectionText {
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: css))
        let fonts = FontRegistry(publication: publication)
        return SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: NativeTypography(fontSize: size), fonts: fonts, rich: PlaceholderRichContent()))
    }

    private func style(_ text: NSAttributedString, containing word: String) throws -> NSParagraphStyle {
        let index = (text.string as NSString).range(of: word).location
        XCTAssertNotEqual(index, NSNotFound)
        return try XCTUnwrap(text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
    }

    func testNestedPercentagesResolveAgainstContainingContentAtEachWidthAndSize() throws {
        for size: CGFloat in [16, 25] {
            let section = try build("<div><p>Nested content</p></div>", css: """
                body { margin: 0 } div { margin: 0 10%; padding: 0 }
                p { margin: 0 5%; padding: 0; text-indent: 10% }
                """, size: size)
            for width: CGFloat in [300, 600, 900] {
                let viewport = CGSize(width: width, height: 700)
                let text = ReaderBoxLayout.resolve(section.string, viewport: viewport).text
                let paragraph = try style(text, containing: "Nested")
                // div's content is 80% of the column; p's percentages use that content box.
                XCTAssertEqual(paragraph.headIndent, width * 0.14, accuracy: 0.01)
                XCTAssertEqual(paragraph.tailIndent, -width * 0.14, accuracy: 0.01)
                XCTAssertEqual(paragraph.firstLineHeadIndent, width * 0.22, accuracy: 0.01)
                XCTAssertEqual(text.string, section.string.string)
                BuilderHarness.assertMapRoundTrips(section)
            }
        }
    }

    func testVerticalPercentMarginsAndPaddingCollapseAtLiveWidth() throws {
        let section = try build("<p>First paragraph</p><p>Second paragraph</p>", css: """
            body { margin: 0; padding: 0 } p { margin: 5% 0; padding: 0 }
            """)
        for width: CGFloat in [300, 600, 900] {
            let text = ReaderBoxLayout.resolve(section.string, viewport: CGSize(width: width, height: 700)).text
            XCTAssertEqual(try style(text, containing: "First").paragraphSpacingBefore, width * 0.05, accuracy: 0.01)
            XCTAssertEqual(try style(text, containing: "First").paragraphSpacing, width * 0.05, accuracy: 0.01)
            XCTAssertEqual(try style(text, containing: "Second").paragraphSpacing, width * 0.05, accuracy: 0.01)
        }
        let padded = try build("<div><p>Inside</p></div>", css: """
            body { margin: 0 } div { margin: 5% 10%; padding: 2% }
            p { margin: 3% 0; padding: 0 }
            """)
        let text = ReaderBoxLayout.resolve(padded.string, viewport: CGSize(width: 300, height: 700)).text
        XCTAssertEqual(try style(text, containing: "Inside").paragraphSpacingBefore, 15 + 6 + 6.84, accuracy: 0.01)
    }

    func testFlowBoxDescendantPercentagesUseConstrainedReadableContentWidth() throws {
        for display in ["float: left", "display: inline-block"] {
            let section = try build("<div><p>Constrained content</p></div>", css: """
                body { margin: 0; padding: 0 } div { \(display); width: 50%; margin: 0; padding: 0 }
                p { margin: 10% 0; padding: 0; text-indent: 10% }
                """)
            for width: CGFloat in [300, 600, 900] {
                let viewport = CGSize(width: width, height: 700)
                let paragraph = try style(ReaderBoxLayout.resolve(section.string, viewport: viewport).text,
                                          containing: "Constrained")
                XCTAssertEqual(paragraph.paragraphSpacingBefore, width * 0.05, accuracy: 0.01)
                XCTAssertEqual(paragraph.paragraphSpacing, width * 0.05, accuracy: 0.01)
                XCTAssertEqual(paragraph.firstLineHeadIndent - paragraph.headIndent, width * 0.05, accuracy: 0.01)
            }
        }
        let cases: [(String, CGFloat)] = [
            ("width: auto; max-width: 50%", 150),
            ("width: 50%; max-width: 40%; min-width: 70%", 210),
            ("width: 20px", 100), // The existing flow fallback preserves a readable column.
        ]
        for (constraints, contentWidth) in cases {
            let section = try build("<div><p>Constrained content</p></div>", css: """
                body { margin: 0; padding: 0 } div { float: left; \(constraints); margin: 0; padding: 0 }
                p { margin: 10% 0; padding: 0 }
                """)
            // Isolate dimension resolution before the box engine's placement/measurement.
            let text = ReaderParagraphSizingLayout.applying(to: section.string, viewport: CGSize(width: 300, height: 700))
            XCTAssertEqual(try style(text, containing: "Constrained").paragraphSpacingBefore, contentWidth * 0.1, accuracy: 0.01)
        }
    }

    func testRTLPercentageInsetsAndListMarkers() throws {
        let section = try build("<p dir='rtl'>مرحبا بالعالم</p><ul><li>List item</li></ul>", css: """
            body { margin: 0 } p { margin: 0 5% 0 10%; text-indent: 5% }
            ul { margin: 0; padding-left: 10% } li { margin: 0; padding: 0 }
            """)
        let text = ReaderBoxLayout.resolve(section.string, viewport: CGSize(width: 300, height: 700)).text
        let rtl = try style(text, containing: "مرحبا")
        XCTAssertEqual(rtl.headIndent, 15, accuracy: 0.01)
        XCTAssertEqual(rtl.tailIndent, -30, accuracy: 0.01)
        XCTAssertEqual(rtl.firstLineHeadIndent, 30, accuracy: 0.01)
        let item = try style(text, containing: "List item")
        XCTAssertGreaterThanOrEqual(item.headIndent, 30)
        XCTAssertLessThan(item.firstLineHeadIndent, item.headIndent)
    }

    func testPaginationResolvesBeforeMeasuringAndKeepsContinuationFormatting() throws {
        let section = try build("<p>" + CanvasText.sentence(300, seed: 1) + "</p>", css: """
            body { margin: 0 } p { margin: 0 10%; text-indent: 10% }
            """)
        for width: CGFloat in [300, 600] {
            let paginator = ReaderPaginator(text: section.string, size: CGSize(width: width, height: 180))
            let pages = paginator.allPages
            XCTAssertGreaterThan(pages.count, 1)
            let paragraph = try style(paginator.text, containing: "the")
            XCTAssertEqual(paragraph.headIndent, width * 0.1, accuracy: 0.01)
            for page in pages {
                let slice = paginator.text(for: page)
                XCTAssertNil(slice.attribute(.readerParagraphSizing, at: 0, effectiveRange: nil))
                if page.continuesParagraph {
                    let continued = try XCTUnwrap(slice.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                    XCTAssertEqual(continued.firstLineHeadIndent, continued.headIndent)
                }
            }
        }
    }

    func testScrolledRelayoutUsesSourceDimensionsWithoutCompoundingOrChangingSelection() throws {
        let section = try build("<p>Scrollable passage retained across repeated resizing.</p>", css: """
            body { margin: 0 } p { margin: 0 10%; text-indent: 5% }
            """)
        let view = ReaderTextView(pageColumn: false)
        view.readerContainer.viewportSize = CGSize(width: 600, height: 700)
        view.setContent(section.string)
        let selection = NSRange(location: 3, length: 5)
        view.selectedRange = selection
        for width: CGFloat in [300, 900, 300, 600] {
            view.readerContainer.viewportSize = CGSize(width: width, height: 700)
            view.refreshFlowBoxLayout()
            let storage = try XCTUnwrap(view.contentStorage.textStorage)
            XCTAssertEqual(try style(storage, containing: "Scrollable").headIndent, width * 0.1, accuracy: 0.01)
            XCTAssertEqual(storage.string, section.string.string)
            XCTAssertEqual(view.selectedRange, selection)
        }
    }

    func testExUsesResolvedFontMetricsAndAuthorCaptionAlignmentWins() throws {
        for size: CGFloat in [16, 25] {
            let section = try build("<p>Font metrics</p><figure><figcaption>Author caption</figcaption></figure>", css: """
                p { font-family: monospace; margin: 0 2ex; text-indent: 1ex }
                figcaption { text-align: left }
                """, size: size)
            let font = try XCTUnwrap(section.string.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
            let ex = CTFontGetXHeight(font as CTFont)
            let paragraph = try style(section.string, containing: "Font metrics")
            XCTAssertEqual(paragraph.headIndent, 2 * ex, accuracy: 0.01)
            XCTAssertEqual(paragraph.firstLineHeadIndent, 3 * ex, accuracy: 0.01)
            XCTAssertEqual(try style(section.string, containing: "Author caption").alignment, .left)
        }
        let defaultCaption = try build("<figure><figcaption>Default caption</figcaption></figure>", css: "")
        XCTAssertEqual(try style(defaultCaption.string, containing: "Default caption").alignment, .center)
    }

    func testRichRowsDoNotRepeatDynamicLeadingOrTrailingMargins() throws {
        let body = "<table><tr><td>First row</td><td>Value</td></tr><tr><td>Second row</td><td>Value</td></tr></table>"
        let publication = try StyleTestSupport.publication(section: StyleTestSupport.xhtml(body: body, css: """
            body { margin: 0 } table { margin: 5% 0; padding: 0 }
            """))
        let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: NativeTypography(fontSize: 16), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
        let text = ReaderBoxLayout.resolve(section.string, viewport: CGSize(width: 300, height: 700)).text
        let characters = text.string as NSString
        let firstRange = characters.paragraphRange(for: NSRange(location: 0, length: 0))
        XCTAssertLessThan(firstRange.upperBound, text.length)
        let first = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let second = try XCTUnwrap(text.attribute(.paragraphStyle, at: firstRange.upperBound, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(first.paragraphSpacingBefore, 15, accuracy: 0.01)
        XCTAssertEqual(first.paragraphSpacing, 0, accuracy: 0.01)
        XCTAssertEqual(second.paragraphSpacingBefore, 0, accuracy: 0.01)
        XCTAssertEqual(second.paragraphSpacing, 15, accuracy: 0.01)
    }
}
