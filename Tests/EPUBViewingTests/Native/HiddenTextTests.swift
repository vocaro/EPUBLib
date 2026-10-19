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

/// Text in the flow that `visibility: hidden` or `visibility: collapse` hides ("Hidden text" in
/// `doc/native-viewer.md`, [#357](https://github.com/vocaro/EPUBLib/issues/357)). It keeps the
/// room it takes, as a browser keeps it, and like a browser the reader leaves it out of what
/// VoiceOver reads, of what a selection copies and of what search finds. A descendant that sets
/// `visibility: visible` again is shown and read. Positions and CFIs inside it still resolve.
@MainActor final class HiddenTextTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    /// Hidden words inside a shown line, a hidden paragraph with shown words inside it, and a
    /// word `visibility: collapse` hides. No hidden word is one a shown word contains.
    private static let body = """
        <p>Shown opening words <span class="v">veiled words in the line</span> shown closing words.</p>\
        <p class="v">Masked paragraph words <span class="u">revealed words inside</span> masked again.</p>\
        <p>Shown <span class="c">collapsed</span> last words.</p>
        """
    private static let hiding = ".v { visibility: hidden } .c { visibility: collapse } .u { visibility: visible } "
    /// The same book with every word shown.
    private static let showing = ".v, .c, .u { visibility: visible } "
    private static let hiddenWords = ["veiled", "Masked", "masked", "collapsed"]

    /// The section's characters, the same whether the words are hidden or shown.
    private static let characters = "Shown opening words veiled words in the line shown closing words.\n"
        + "Masked paragraph words revealed words inside masked again.\nShown collapsed last words."
    /// What VoiceOver, Copy and search read of it: the shown words. A paragraph's break stays
    /// where hidden words end it, so the lines around them stay apart.
    private static let read = "Shown opening words  shown closing words.\nrevealed words inside\nShown  last words."

    private func section(hidden: Bool = true) throws -> SectionText {
        try H.build(Self.body, css: H.reset + (hidden ? Self.hiding : Self.showing))
    }

    private func host(_ section: SectionText, size: CGSize = CGSize(width: 420, height: 400)) throws -> (CanvasHost, ReaderTextView) {
        let host = CanvasHost(FakeCanvasSource([section.string]), size: size)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(view.placement.visibleLength, section.string.length, "the section is one page")
        return (host, view)
    }

    private func assertNoHiddenWord(_ text: String?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in Self.hiddenWords {
            XCTAssertFalse((text ?? "").contains(word), "\(message): \(word) in \((text ?? "").debugDescription)", file: file, line: line)
        }
    }

    // MARK: The text

    func testHiddenTextKeepsItsCharactersAndIsLeftOutOfWhatIsRead() throws {
        let hidden = try section(), shown = try section(hidden: false)
        XCTAssertEqual(hidden.string.string, Self.characters, "its characters stay, to take their room")
        XCTAssertEqual(shown.string.string, Self.characters)
        XCTAssertEqual(shown.string.readerPlainText(), Self.characters)
        XCTAssertEqual(hidden.string.readerPlainText(), Self.read, "what VoiceOver, Copy and search read")
        for word in Self.hiddenWords {
            let range = (Self.characters as NSString).range(of: word)
            XCTAssertNotNil(hidden.string.attribute(.readerHidden, at: range.location, effectiveRange: nil), word)
            XCTAssertNil(shown.string.attribute(.readerHidden, at: range.location, effectiveRange: nil), word)
        }
        let revealed = (Self.characters as NSString).range(of: "revealed")
        XCTAssertNil(hidden.string.attribute(.readerHidden, at: revealed.location, effectiveRange: nil), "shown again inside")
        BuilderHarness.assertMapRoundTrips(hidden)
        // A part of the text reads its own shown words, and hidden words between two shown
        // ones set them apart, as the room the hidden words take does on the page.
        let line = (Self.characters as NSString).range(of: "Shown opening words veiled words in the line shown")
        XCTAssertEqual(hidden.string.readerPlainText(in: line), "Shown opening words  shown")
        let joined = try H.build("<p>un<span class='v'>believ</span>able and<span class='v'> hidden </span>words</p>",
                                 css: H.reset + Self.hiding)
        XCTAssertEqual(joined.string.readerPlainText(), "un able and words")
        XCTAssertEqual(joined.string.readerPlainText(in: NSRange(location: 2, length: 6)), " ", "hidden words alone, between two shown")
    }

    /// The room the words take is theirs whether they are hidden or shown: the same lines, in
    /// the same places, on the same pages.
    func testHiddenTextTakesTheRoomItTakesShown() throws {
        let size = CGSize(width: 240, height: 90)
        let hidden = try section(), shown = try section(hidden: false)
        let (hiddenPaginator, hiddenPages) = H.pages(hidden, size: size)
        let (shownPaginator, shownPages) = H.pages(shown, size: size)
        XCTAssertEqual(hiddenPages.map(\.range), shownPages.map(\.range), "the same pages")
        XCTAssertGreaterThan(hiddenPages.count, 1, "the text runs over pages at this size")
        for (hiddenPage, shownPage) in zip(hiddenPages, shownPages) {
            let hiddenLines = H.lines(in: H.pageView(hiddenPaginator, page: hiddenPage))
            let shownLines = H.lines(in: H.pageView(shownPaginator, page: shownPage))
            XCTAssertEqual(hiddenLines.map(\.range), shownLines.map(\.range), "the same lines")
            for (a, b) in zip(hiddenLines, shownLines) {
                XCTAssertEqual(a.frame.minX, b.frame.minX, accuracy: 0.01)
                XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 0.01)
                XCTAssertEqual(a.frame.width, b.frame.width, accuracy: 0.01)
                XCTAssertEqual(a.frame.height, b.frame.height, accuracy: 0.01)
            }
        }
        // Each hidden word is laid out where its shown twin is.
        let hiddenView = H.view(hidden.string, size: CGSize(width: 240, height: 1000))
        let shownView = H.view(shown.string, size: CGSize(width: 240, height: 1000))
        for word in Self.hiddenWords {
            XCTAssertEqual(H.frame(word, in: hidden, view: hiddenView), H.frame(word, in: shown, view: shownView), word)
        }
    }

    func testATableCellReadsItsShownWordsOnly() throws {
        let section = try H.build("""
            <table><tr><td>Left <span class="v">veiled</span> cell</td><td class="v">Masked <span class="u">revealed</span> cell</td></tr>\
            <tr><td class="c">collapsed</td><td>Plain</td></tr></table>
            """, css: H.reset + Self.hiding)
        var rows: [TableRowAttachment] = []
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if let row = value as? TableRowAttachment { rows.append(row) }
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.table.cells.map(\.text), ["Left cell", "revealed", "", "Plain"], "what VoiceOver reads of each cell")
        XCTAssertEqual(rows.map(\.textEquivalent), ["Left cell\trevealed", "\tPlain"], "what a row reads where it stands")
        XCTAssertEqual(rows.first?.table.cells[0].content.readerPlainText(), "Left  cell", "what Copy takes from the cell")
        XCTAssertEqual(rows[1].saysNothing, false)
    }

    func testAuthoredCopyAndSearchContextsExcludeHiddenCaseSubstitutionsAcrossMapSpans() throws {
        let text = try H.build("<p>un<span class='v up'>se<b>cr</b>et ß</span>able <span class='v sc'>straße</span>end <span class='up'>Straße</span></p>",
                               css: H.reset + Self.hiding + ".up { text-transform: uppercase } .sc { font-family: Georgia; font-variant: small-caps }")
        XCTAssertTrue(text.string.string.contains("SECRET SS"), "the hidden transform keeps its rendered characters")
        XCTAssertEqual(text.mappedText(in: 0..<text.string.length), "un able end Straße")
        let secret = (text.string.string as NSString).range(of: "SECRET SS")
        XCTAssertEqual(text.mappedText(in: secret.location..<NSMaxRange(secret)), " ", "a hidden run is considered across all its source spans")
        let expanded = (text.string.string as NSString).range(of: "SS")
        XCTAssertEqual(text.mappedText(in: expanded.location..<NSMaxRange(expanded)), "", "a partial hidden run copies no authored ß")
        let results = try batch("able", in: text)
        XCTAssertEqual(results.results.count, 1)
        let context = try XCTUnwrap(results.results.first)
        XCTAssertFalse((context.contextBefore + context.contextAfter).contains("secret"))
        XCTAssertFalse((context.contextBefore + context.contextAfter).contains("straße"), "the hidden small-cap source is excluded")
        let source = try XCTUnwrap(text.document.nodes.first { $0.isText && $0.text == "et ß" })
        let lower = text.map.location(of: DOMPosition(source, 3)), upper = text.map.location(of: DOMPosition(source, 4), isEnd: true)
        XCTAssertEqual(upper - lower, 2)
        XCTAssertEqual(text.map.position(at: lower, in: text.document), DOMPosition(source, 3))
        XCTAssertEqual(text.map.endPosition(at: upper, in: text.document), DOMPosition(source, 4))
    }

    func testAuthoredTableCopyExcludesHiddenTransformsButKeepsVisibleSourceCase() throws {
        let text = try H.build("<table><tr><td>un<span class='v up'>secret ß</span>able <span class='up'>Straße</span></td>"
                               + "<td class='v up'>masked <span class='u'>Revealed ß</span> again</td></tr></table>",
                               css: H.reset + Self.hiding + ".up { text-transform: uppercase }")
        let row = try XCTUnwrap(text.tables().first)
        XCTAssertEqual(text.mappedText(in: row.offset..<(row.offset + 1)), "un able Straße\tRevealed ß")
        let cell = row.row.table.cells[0]
        let start = ReaderTextPosition(section: 0, offset: row.offset,
            tableCell: ReaderTablePosition(table: row.row.table.sourceOrder, cell: 0, offset: 0))
        let end = ReaderTextPosition(section: 0, offset: row.offset,
            tableCell: ReaderTablePosition(table: row.row.table.sourceOrder, cell: 0, offset: cell.content.length))
        XCTAssertEqual(text.tablePassage(ReaderTextRange(start: start, end: end)), "un able Straße")
        let hidden = (cell.content.string as NSString).range(of: "SECRET SS")
        var hiddenStart = start, hiddenEnd = end
        hiddenStart.tableCell?.offset = hidden.location
        hiddenEnd.tableCell?.offset = NSMaxRange(hidden)
        let hiddenRange = ReaderTextRange(start: hiddenStart, end: hiddenEnd)
        XCTAssertTrue(text.holdsHiddenText(hiddenRange))
        XCTAssertEqual(text.tablePassage(hiddenRange), " ")
        XCTAssertEqual(try batch("secret", in: text).results.count, 0)
        XCTAssertEqual(try batch("Revealed", in: text).results.count, 1)
    }

    // MARK: VoiceOver, Copy and a selection

    #if os(macOS)
    /// AppKit's text view reads its characters one for one with its ranges: a hidden one is
    /// given as a space, so every range still matches the text and nothing hidden is said.
    func testOnMacAHiddenCharacterIsASpaceToAnAssistiveClient() throws {
        let hidden = try section()
        let (_, view) = try host(hidden)
        let blanked = Self.blanked(hidden.string)
        XCTAssertEqual(view.accessibilityValue(), blanked, "the characters as they are, hidden ones as spaces")
        XCTAssertEqual((view.accessibilityValue() as NSString?)?.length, hidden.string.length)
        let whole = NSRange(location: 0, length: hidden.string.length)
        XCTAssertEqual(view.accessibilityString(for: whole), blanked)
        XCTAssertEqual(view.accessibilityAttributedString(for: whole)?.string, blanked)
        let veiled = (Self.characters as NSString).range(of: "veiled words")
        XCTAssertEqual(view.accessibilityString(for: veiled), String(repeating: " ", count: veiled.length))
        var lines: [String] = []
        for line in 0..<20 {
            let range = view.accessibilityRange(forLine: line)
            guard range.location != NSNotFound else { break }
            lines.append(view.accessibilityString(for: range) ?? "")
        }
        XCTAssertGreaterThan(lines.count, 2)
        assertNoHiddenWord(lines.joined(), "the lines VoiceOver reads")
        XCTAssertTrue(lines.joined().contains("revealed words inside"), "shown again inside: \(lines)")
        if let data = view.accessibilityRTF(for: whole) {
            let rtf = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            assertNoHiddenWord(rtf.string, "the rich text an assistive client is given")
        }
        view.selectedRange = whole
        assertNoHiddenWord(view.accessibilitySelectedText(), "the selected text an assistive client is given")
    }

    /// Continuous scroll and a note's popover show their text in a text view of AppKit's own
    /// accessibility, which the reader's gives hidden characters as spaces too.
    func testOnMacAViewThatIsNotAPageGivesHiddenCharactersAsSpaces() throws {
        let hidden = try section()
        let view = H.view(hidden.string, size: CGSize(width: 420, height: 600), pageColumn: false)
        let blanked = Self.blanked(hidden.string)
        XCTAssertEqual(view.accessibilityValue(), blanked)
        let whole = NSRange(location: 0, length: hidden.string.length)
        XCTAssertEqual(view.accessibilityString(for: whole), blanked)
        XCTAssertEqual(view.accessibilityAttributedString(for: whole)?.string, blanked)
        view.selectedRange = whole
        XCTAssertEqual(view.accessibilitySelectedText(), blanked)
        if let data = view.accessibilityRTF(for: whole) {
            let rtf = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            assertNoHiddenWord(rtf.string, "the rich text an assistive client is given")
        }
    }

    /// The characters, each hidden one but a break a space.
    private static func blanked(_ text: NSAttributedString) -> String {
        let result = NSMutableString(string: text.string)
        text.enumerateAttribute(.readerHidden, in: NSRange(location: 0, length: text.length)) { value, run, _ in
            guard value != nil else { return }
            for index in run.location..<NSMaxRange(run) where ![0x0A, 0x2028, 0x2029].contains(result.character(at: index)) {
                result.replaceCharacters(in: NSRange(location: index, length: 1), with: " ")
            }
        }
        return result as String
    }
    #else
    func testOnIPhoneAndIPadNoElementReadsHiddenText() throws {
        let hidden = try section()
        let (_, view) = try host(hidden)
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        let labels = elements.map { $0.accessibilityLabel ?? "" }
        assertNoHiddenWord(labels.joined(separator: "|"), "what VoiceOver reads")
        XCTAssertEqual(labels.joined(separator: " ").split(whereSeparator: \.isWhitespace), Self.read.split(whereSeparator: \.isWhitespace),
                       "every shown word, once: \(labels)")
        XCTAssertFalse(labels.contains { $0.allSatisfy(\.isWhitespace) }, "no element for a line of hidden words alone: \(labels)")
        XCTAssertEqual(view.accessibilityValue, Self.read)
    }
    #endif

    func testCopyAndTheSelectionAHostIsToldOfLeaveHiddenTextOut() async throws {
        let hidden = try section()
        let (host, view) = try host(hidden)
        XCTAssertEqual(view.visibleText, Self.read)
        view.selectedRange = NSRange(location: 0, length: hidden.string.length)
        host.canvas.textViewSelectionDidChange(view)
        try await host.settle()
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.text, Self.read, "the selection a host is told of")
        #if os(macOS)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), Self.read)
        #else
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("org.epublib.tests.hidden.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        view.pasteboard = pasteboard
        view.copy(nil)
        XCTAssertEqual(pasteboard.string, Self.read)
        #endif
        // A selection of hidden words alone copies nothing of them.
        let veiled = (Self.characters as NSString).range(of: "veiled words in the line")
        XCTAssertEqual(view.plainText(in: veiled), "")
    }

    /// A heading the book hides in the flow is no heading to VoiceOver: a browser leaves it out
    /// of the page's headings with its words.
    func testAHiddenHeadingIsNotReadAsAHeading() throws {
        let hidden = try H.build("<h2 class='v'>Masked heading</h2><p>Shown words.</p>", css: H.reset + Self.hiding)
        XCTAssertEqual(hidden.string.readerHeadings().count, 1, "the heading is marked, as its characters are")
        XCTAssertEqual(hidden.string.readerPlainText(), "\nShown words.")
        let (_, view) = try host(hidden)
        #if os(macOS)
        assertNoHiddenWord(view.accessibilityValue(), "the page's value")
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: 0, length: hidden.string.length)))
        var levels = 0
        rich.enumerateAttribute(.accessibilityHeadingLevel, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            if value != nil { levels += 1 }
        }
        XCTAssertEqual(levels, 0, "no heading level on the spaces given for the hidden heading")
        let shown = try H.build("<h2>Shown heading</h2><p>Shown words.</p>", css: H.reset)
        let (_, shownView) = try host(shown)
        let shownRich = try XCTUnwrap(shownView.accessibilityAttributedString(for: NSRange(location: 0, length: shown.string.length)))
        XCTAssertEqual(shownRich.attribute(.accessibilityHeadingLevel, at: 0, effectiveRange: nil) as? Int, 2, "a shown heading keeps its level")
        #else
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" }, ["Shown words."])
        XCTAssertFalse(elements.contains { $0.accessibilityTraits.contains(.header) })
        #endif
    }

    // MARK: Search

    private func batch(_ query: String, in text: SectionText) throws -> SearchResultBuilder.Batch {
        let publication = BuilderHarness.publication
        let section = SearchResultBuilder.Section(
            text: text, publicationID: publication.id, engineID: "engine", bookmarkFormat: "format",
            spine: try SpineCFIs(publication: publication), progress: NativeProgress(publication: publication))
        return SearchResultBuilder.results(for: TextSearch.matches(of: query, in: text.document, locale: "en"),
                                           in: section, firstIndex: 0, limit: .max)
    }

    func testSearchFindsNoOccurrenceInHiddenText() throws {
        let hidden = try section(), shown = try section(hidden: false)
        for word in ["veiled", "masked", "collapsed"] {
            XCTAssertEqual(try batch(word, in: shown).results.count, word == "masked" ? 2 : 1, word)
            XCTAssertEqual(try batch(word, in: hidden).results.count, 0, "\(word) is hidden")
        }
        XCTAssertEqual(try batch("words in the line shown", in: hidden).results.count, 0, "a match that takes in hidden words")
        let found = try batch("words", in: hidden)
        // "words" stands in the hidden line once and in the hidden paragraph once.
        XCTAssertEqual(try batch("words", in: shown).results.count, 6)
        XCTAssertEqual(found.results.count, 4)
        XCTAssertEqual(found.results.map(\.matchedText), Array(repeating: "words", count: 4))
        for result in found.results {
            assertNoHiddenWord(result.contextBefore + result.matchedText + result.contextAfter, "a result's context")
        }
        let revealed = try batch("revealed words", in: hidden)
        XCTAssertEqual(revealed.results.count, 1, "shown again inside")
        XCTAssertEqual(revealed.results.first?.contextBefore, "")
        XCTAssertEqual(revealed.results.first?.contextAfter, " inside")
        let range = try XCTUnwrap(revealed.ranges.first)
        XCTAssertEqual(range, ReaderTextRange(section: 0, (Self.characters as NSString).range(of: "revealed words").location
            ..< NSMaxRange((Self.characters as NSString).range(of: "revealed words"))))
    }

    // MARK: Positions

    /// A saved position or a CFI inside hidden text names the same characters it named before:
    /// they are still in the text, only left out of what is read.
    func testPositionsAndCFIsInsideHiddenTextStillResolve() throws {
        let hidden = try section(), shown = try section(hidden: false)
        let spine = try SpineCFIs(publication: BuilderHarness.publication)
        for word in ["veiled", "Masked", "collapsed", "revealed"] {
            let range = (Self.characters as NSString).range(of: word)
            for text in [hidden, shown] {
                let start = try XCTUnwrap(text.map.position(at: range.location, in: text.document), word)
                let end = try XCTUnwrap(text.map.endPosition(at: NSMaxRange(range), in: text.document), word)
                XCTAssertEqual(text.map.location(of: start), range.location, word)
                XCTAssertEqual(text.map.location(of: end, isEnd: true), NSMaxRange(range), word)
                let cfi = spine.cfi(spineIndex: 0, start: start, end: end, in: text.document)
                XCTAssertFalse(cfi.isEmpty, word)
                let target = try XCTUnwrap(spine.resolve(cfi), cfi)
                XCTAssertEqual(target.spineIndex, 0)
                let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: text.document), cfi)
                XCTAssertEqual(text.renderedPosition(resolved.start).offset, range.location, cfi)
                XCTAssertEqual(text.renderedPosition(resolved.end, isEnd: true).offset, NSMaxRange(range), cfi)
            }
            // Hiding the words changes none of their CFIs.
            let hiddenStart = try XCTUnwrap(hidden.map.position(at: range.location, in: hidden.document))
            let shownStart = try XCTUnwrap(shown.map.position(at: range.location, in: shown.document))
            XCTAssertEqual(spine.cfi(spineIndex: 0, start: hiddenStart, end: hiddenStart, in: hidden.document),
                           spine.cfi(spineIndex: 0, start: shownStart, end: shownStart, in: shown.document), word)
        }
    }
}
