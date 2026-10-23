import CoreText
import EPUBCore
import EPUBReading
@testable import EPUBViewing
import XCTest
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// "Each setting changes the text in both flows on iPhone, iPad and Mac, and keeps the
/// position" (#673): a mounted reader, sent each setting in turn through the public `.style`
/// command, shows text with that setting in the text view on screen, with the place it showed
/// still on screen.
@MainActor final class ReaderTextSettingsSessionTests: XCTestCase {
    private static let midpoint = "A marked midpoint paragraph sits here."

    /// The midpoint paragraph's attributes as the text view on screen holds them.
    private func shown(_ reader: SessionCoverageReader) throws -> (text: NSAttributedString, at: Int) {
        let canvas = try XCTUnwrap(reader.session.canvas)
        let views = canvas.scrollTextView.map { [$0] } ?? canvas.columns
        for view in views {
            guard let text = view.contentStorage.textStorage else { continue }
            let found = (text.string as NSString).range(of: Self.midpoint)
            if found.location != NSNotFound { return (text, found.location) }
        }
        throw XCTSkip("the midpoint is in no text view") // never expected: it is on screen
    }

    private func exercise(_ flow: EPUBReadingFlow) async throws {
        let reader = try SessionCoverageReader(try styledBook())
        defer { reader.close() }
        try await reader.settle()
        var style = EPUBReaderStyle(flow: flow)
        try await reader.session.send(.style(style))
        try await reader.settle()
        try await reader.session.send(.navigate(href: "OPS/two.xhtml#mid"))
        let mid = try reader.anchor("mid", section: 1)
        try await reader.wait("the midpoint on screen") { reader.isVisible(mid) }
        let size: CGFloat = 17

        func send(_ label: String, _ change: (inout EPUBReaderStyle.Typography) -> Void) async throws {
            change(&style.typography)
            let expected = ReaderTextSettings(style.typography)
            try await reader.session.send(.style(style))
            try await reader.wait("the book rebuilt for \(label)") {
                reader.session.book.isComplete && reader.session.book.typography.text == expected
                    && (flow == .paginated || reader.session.canvas?.scrollBook != nil)
            }
            try await reader.settle()
            XCTAssertEqual(reader.state.status.style, style, label)
            XCTAssertTrue(reader.isVisible(mid), "\(label) lost the place: \(String(describing: reader.session.visibleRange))")
        }
        func paragraph(_ label: String) throws -> NSParagraphStyle {
            let (text, at) = try shown(reader)
            return try XCTUnwrap(text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle, label)
        }
        func kern(_ offset: Int) throws -> CGFloat {
            let (text, at) = try shown(reader)
            return text.attribute(.kern, at: at + offset, effectiveRange: nil) as? CGFloat ?? 0
        }
        let space = (Self.midpoint as NSString).range(of: " ").location

        try await send("the font") { $0.fontFamily = .monospace }
        let (text, at) = try shown(reader)
        let font = try XCTUnwrap(text.attribute(.font, at: at, effectiveRange: nil) as? PlatformFont)
        XCTAssertTrue(CTFontGetSymbolicTraits(font as CTFont).contains(.traitMonoSpace), "the font")

        try await send("line height") { $0.lineHeight = 2 }
        XCTAssertEqual(try paragraph("line height").lineHeightMultiple * InlineStyling.naturalLineHeight(font), 2 * size,
                       accuracy: 0.01)

        try await send("letter spacing") { $0.letterSpacing = 0.12 }
        XCTAssertEqual(try kern(0), 0.12 * size, accuracy: 0.001, "letter spacing")

        try await send("word spacing") { $0.wordSpacing = 0.16 }
        XCTAssertEqual(try kern(space), (0.12 + 0.05) * size, accuracy: 0.001, "the book's own word spacing, with the switch off")

        try await send("alignment") { $0.alignment = .justified }
        XCTAssertEqual(try paragraph("alignment").alignment, .justified)

        try await send("hyphenation") { $0.hyphenation = false }
        XCTAssertEqual(try paragraph("hyphenation").hyphenationFactor, 0)

        try await send("paragraph spacing") { $0.paragraphSpacing = 2 }
        let spacing = try paragraph("paragraph spacing")
        XCTAssertEqual(max(spacing.paragraphSpacing, spacing.paragraphSpacingBefore), 2 * size, accuracy: 0.5)

        try await send("the switch") { $0.overridesBookStyles = true }
        XCTAssertEqual(try kern(space), (0.12 + 0.16) * size, accuracy: 0.001, "the setting over the book's word spacing")

        // The margins are the canvas's: a new column width, and no rebuild.
        let canvas = try XCTUnwrap(reader.session.canvas)
        let typography = reader.session.book.typography
        style.typography.pageMargins = 0
        try await reader.session.send(.style(style))
        try await reader.wait("the wider column") {
            switch flow {
            case .paginated:
                let wide = ReaderCanvasGeometry.spread(in: canvas.pageArea, division: nil, isRightToLeft: false, margins: 0)
                return canvas.spread == wide
            case .scrolled:
                let wide = ReaderCanvasGeometry.scrollColumn(in: canvas.scrollColumnArea(), division: nil, margins: 0)
                return abs((canvas.scrollTextView?.readerContainer.size.width ?? 0) - wide.width) < 0.5
            }
        }
        try await reader.settle()
        XCTAssertEqual(reader.session.book.typography, typography, "margins rebuild no text")
        XCTAssertEqual(canvas.configuration.pageMargins, 0)
        XCTAssertTrue(reader.isVisible(mid), "the margins lost the place: \(String(describing: reader.session.visibleRange))")
        let ordinary = ReaderCanvasGeometry.scrollColumn(in: canvas.scrollColumnArea(), division: nil).width
        let widest = ReaderCanvasGeometry.scrollColumn(in: canvas.scrollColumnArea(), division: nil, margins: 0).width
        XCTAssertGreaterThan(widest, ordinary, "the test window is narrow enough for margins to matter")
    }

    /// Two chapters with a marked paragraph many pages into the second, and the book's own word
    /// spacing on `p`, which wins over the setting until the switch is on.
    private func styledBook() throws -> Data {
        let head = "<link rel=\"stylesheet\" href=\"book.css\"/>"
        func page(_ title: String, _ body: String) -> String {
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(title)</title>\(head)</head><body>\(body)</body></html>"
        }
        return try SessionCoverageBook.epub([
            SessionCoverageBook.Section("one", raw: page("one", "<h1>First Chapter</h1>\(SessionCoverageBook.filler(30))")),
            SessionCoverageBook.Section("two", raw: page("two", "<h1>Second Chapter</h1>\(SessionCoverageBook.filler(60))"
                + "<p id=\"mid\">\(Self.midpoint)</p>\(SessionCoverageBook.filler(60))")),
        ], manifest: "<item id=\"css\" href=\"book.css\" media-type=\"text/css\"/>",
           files: ["OPS/book.css": "p { word-spacing: 0.05em }"])
    }

    func testEachSettingChangesTheTextAndKeepsThePlaceWhenPaginated() async throws { try await exercise(.paginated) }
    func testEachSettingChangesTheTextAndKeepsThePlaceInContinuousScroll() async throws { try await exercise(.scrolled) }

    func testASettingThatIsNotANumberIsRefused() async throws {
        let reader = try SessionCoverageReader(try styledBook())
        defer { reader.close() }
        try await reader.settle()
        for value in [Double.nan, .infinity] {
            for setting in [\EPUBReaderStyle.Typography.lineHeight, \.paragraphSpacing, \.letterSpacing, \.wordSpacing, \.pageMargins] {
                var style = EPUBReaderStyle()
                style.typography[keyPath: setting] = value
                await reader.refuses(.style(style), "\(setting) \(value)")
            }
        }
        XCTAssertEqual(reader.state.status.style, EPUBReaderStyle())
    }

    /// A host keeps a reader's choices (#692) by encoding them.
    func testTheSettingsRoundTripThroughCodable() throws {
        let typography = EPUBReaderStyle.Typography(fontFamily: .named("OpenDyslexic"), lineHeight: 1.5, paragraphSpacing: 2,
                                                    letterSpacing: 0.12, wordSpacing: 0.16, pageMargins: 0.5,
                                                    alignment: .start, hyphenation: false, overridesBookStyles: true)
        let decoded = try JSONDecoder().decode(EPUBReaderStyle.Typography.self, from: JSONEncoder().encode(typography))
        XCTAssertEqual(decoded, typography)
        XCTAssertEqual(try JSONDecoder().decode(EPUBReaderStyle.Typography.self, from: JSONEncoder().encode(EPUBReaderStyle.Typography())),
                       EPUBReaderStyle.Typography())
    }
}
