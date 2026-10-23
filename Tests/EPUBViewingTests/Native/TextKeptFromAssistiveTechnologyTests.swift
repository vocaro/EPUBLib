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

/// Shown text that the book keeps from assistive technology with `aria-hidden="true"`, on its
/// element or on one round it ("Alternative text" and "Hidden text" in `doc/native-viewer.md`,
/// [#552](https://github.com/vocaro/EPUBLib/issues/552)). WAI-ARIA 1.2 and HTML-AAM hide it from
/// assistive technology and from nothing else: it is drawn, a selection copies it and search
/// finds it, and VoiceOver is not given it, as #408 has it for an image or a rule.
/// `aria-hidden="false"` inside it shows nothing to VoiceOver again.
@MainActor final class TextKeptFromAssistiveTechnologyTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    /// A drop cap whose word the line also gives, a row of stars between scenes, words kept in a
    /// line with `aria-hidden="false"` inside them, a heading of kept words alone and one with
    /// some, a link of kept words alone and one with some, generated text, a formula and the
    /// words shown for a picture that cannot be drawn.
    private static let body = """
        <p><span aria-hidden="true">T</span>he night came.</p>\
        <p aria-hidden="true">* * *</p>\
        <p>Shown <span aria-hidden="true">kept <b>bold</b> <span aria-hidden="false">again</span></span> words.</p>\
        <h2><span aria-hidden="true">Kept heading</span></h2>\
        <h2>Heading <span aria-hidden="true">kept part</span> end</h2>\
        <p>Go <a href="two.xhtml" aria-hidden="true">kept link</a> and <a href="three.xhtml">shown <span aria-hidden="true">kept</span> link</a>.</p>\
        <p class="g" aria-hidden="true">Generated</p>\
        <p>Formula <math xmlns="http://www.w3.org/1998/Math/MathML" aria-hidden="true" alttext="Kept formula"><mi>x</mi></math> \
        and <span aria-hidden="true"><img src="missing.png" alt="Kept lost"/></span> end.</p>\
        <p>Last words.</p>
        """
    private static let css = H.reset + ".g::before { content: 'Before ' }"
    private static let keptWords = ["The night", "*", "kept", "Kept", "bold", "again", "Before", "Generated"]

    /// The section's characters, the same with `aria-hidden` or without.
    private static let characters = "The night came.\n* * *\nShown kept bold again words.\nKept heading\nHeading kept part end\n"
        + "Go kept link and shown kept link.\nBefore Generated\nFormula \u{FFFC} and Kept lost end.\nLast words."
    /// What a selection, a copy and a search's context read: all of it.
    private static let copied = "The night came.\n* * *\nShown kept bold again words.\nKept heading\nHeading kept part end\n"
        + "Go kept link and shown kept link.\nBefore Generated\nFormula Kept formula and Kept lost end.\nLast words."
    /// What VoiceOver is given: none of the kept words, and the breaks that keep the lines apart.
    private static let spoken = "he night came.\n\nShown  words.\n\nHeading  end\nGo  and shown  link.\n\nFormula  and  end.\nLast words."

    private func section(kept: Bool = true) throws -> SectionText {
        try H.build(kept ? Self.body : Self.body.replacingOccurrences(of: "aria-hidden=\"true\"", with: "data-shown=\"true\""), css: Self.css)
    }

    private func host(_ section: SectionText, size: CGSize = CGSize(width: 420, height: 600)) throws -> (CanvasHost, ReaderTextView) {
        let host = CanvasHost(FakeCanvasSource([section.string]), size: size)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(view.placement.visibleLength, section.string.length, "the section is one page")
        return (host, view)
    }

    private func assertNoKeptWord(_ text: String?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in Self.keptWords {
            XCTAssertFalse((text ?? "").contains(word), "\(message): \(word) in \((text ?? "").debugDescription)", file: file, line: line)
        }
    }

    // MARK: The text

    func testKeptTextIsDrawnCopiedAndFoundAndNotGivenToVoiceOver() throws {
        let kept = try section(), shown = try section(kept: false)
        XCTAssertEqual(kept.string.string, Self.characters, "its characters stay")
        XCTAssertEqual(shown.string.string, Self.characters)
        XCTAssertEqual(kept.string.readerPlainText(), Self.copied, "what Copy, a selection and a search's context read")
        XCTAssertEqual(shown.string.readerPlainText(), Self.copied)
        XCTAssertEqual(kept.mappedText(in: 0..<kept.string.length), shown.mappedText(in: 0..<shown.string.length),
                       "a copy of the book's own text takes them")
        XCTAssertEqual(kept.string.readerPlainText(spoken: true), Self.spoken, "what VoiceOver is given")
        XCTAssertEqual(shown.string.readerPlainText(spoken: true), Self.copied)
        BuilderHarness.assertMapRoundTrips(kept)
        let text = Self.characters as NSString
        for word in ["T", "* * *", "kept bold again", "Kept heading", "kept part", "kept link", "Before Generated", "Kept lost"] {
            let range = text.range(of: word)
            XCTAssertNotEqual(range.location, NSNotFound, word)
            for location in range.location..<NSMaxRange(range) {
                XCTAssertNotNil(kept.string.attribute(.readerUnspoken, at: location, effectiveRange: nil), word)
                XCTAssertNil(kept.string.attribute(.readerHidden, at: location, effectiveRange: nil), "\(word) is shown")
            }
            XCTAssertNil(shown.string.attribute(.readerUnspoken, at: range.location, effectiveRange: nil), word)
            // It is drawn as the same words without `aria-hidden` are.
            XCTAssertEqual(kept.string.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? PlatformColor,
                           shown.string.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? PlatformColor, word)
        }
        for word in ["he night came", "Shown ", " words", "Heading ", " end", "shown ", " link.", "Last words"] {
            XCTAssertNil(kept.string.attribute(.readerUnspoken, at: text.range(of: word).location, effectiveRange: nil), word)
        }
        // The formula is kept as an image is: its words are copied and not spoken.
        let formula = try XCTUnwrap(kept.string.attribute(.attachment, at: text.range(of: "\u{FFFC}").location, effectiveRange: nil) as? MathAttachment)
        XCTAssertTrue(formula.isHiddenFromAssistiveTechnology)
        XCTAssertEqual(formula.textEquivalent, "Kept formula")
        XCTAssertEqual(formula.spokenEquivalent, "")
        // A link of kept words alone stays a link, which has nothing else to be read by.
        XCTAssertTrue(kept.string.holdsUnspokenWordsAlone(inLinkAt: text.range(of: "kept link").location))
        XCTAssertFalse(kept.string.holdsUnspokenWordsAlone(inLinkAt: text.range(of: "shown kept link").location))
        // Kept words between two shown ones read as one space, as hidden words do.
        let joined = try H.build("<p>un<span aria-hidden='true'>believ</span>able</p>", css: H.reset)
        XCTAssertEqual(joined.string.readerPlainText(), "unbelievable")
        XCTAssertEqual(joined.string.readerPlainText(spoken: true), "un able")
        // A list's markers are kept with its items.
        let list = try H.build("<ul aria-hidden='true'><li>Kept item</li></ul><p>After.</p>", css: H.reset)
        XCTAssertTrue(list.string.readerPlainText().contains("Kept item"), list.string.readerPlainText())
        XCTAssertEqual(list.string.readerPlainText(spoken: true), "\nAfter.")
    }

    /// A table cell's text is marked as it is written, in a table kept from assistive
    /// technology and in a cell of a shown one. VoiceOver reads a cell's words without the kept
    /// ones, and a copy of its row, a selection of it and search take them (#551).
    func testATableCellsKeptWordsAreLeftOutOfWhatVoiceOverReadsOfItAndCopied() throws {
        let section = try H.build("""
            <table aria-hidden="true"><tr><td>Kept cell</td><td>Kept too</td></tr></table>\
            <table><tr><td>Plain <span aria-hidden="true">kept</span> cell</td><td>Next</td></tr>\
            <tr><td>un<span aria-hidden="true">believ</span>able</td><td><span aria-hidden="true">Kept alone</span></td></tr></table>
            """, css: H.reset)
        var rows: [TableRowAttachment] = []
        section.string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
            if let row = value as? TableRowAttachment { rows.append(row) }
        }
        XCTAssertEqual(rows.count, 3)
        let cells = rows.prefix(2).map { $0.table.cells[0].content }
        for (cell, word) in zip(cells, ["Kept cell", "kept"]) {
            let range = (cell.string as NSString).range(of: word)
            XCTAssertNotNil(cell.attribute(.readerUnspoken, at: range.location, effectiveRange: nil), word)
            XCTAssertEqual(cell.readerPlainText(), cell.string, "a copy of the cell takes \(word)")
            XCTAssertTrue(cell.readerHiddenCharacters(in: NSRange(location: 0, length: cell.length)).contains(range),
                          "a cell's text area gives \(word) to an assistive client as spaces")
        }
        XCTAssertEqual(rows.map(\.cellWords), [["", ""], ["Plain cell", "Next"], ["un able", ""]],
                       "what VoiceOver reads of each cell: kept words between two shown ones read as one space")
        XCTAssertEqual(rows.map(\.spokenEquivalent), ["\t", "Plain cell\tNext", "un able\t"])
        XCTAssertEqual(rows.map(\.textEquivalent), ["Kept cell\tKept too", "Plain kept cell\tNext", "unbelievable\tKept alone"],
                       "what a selection of the row reads")
        XCTAssertEqual(rows.map(\.copyTextEquivalent), ["Kept cell\tKept too", "Plain kept cell\tNext", "unbelievable\tKept alone"],
                       "what a copy of the row takes")
        XCTAssertEqual(rows.map(\.saysNothing), [true, false, false], "a row of kept words alone has nothing to say")
        XCTAssertEqual(section.string.readerPlainText(), "Kept cell\tKept too\nPlain kept cell\tNext\nunbelievable\tKept alone")
        XCTAssertEqual(section.string.readerPlainText(spoken: true), "\t\nPlain cell\tNext\nun able\t")
        XCTAssertEqual(section.mappedText(in: 0..<section.string.length),
                       "Kept cell\tKept too\nPlain kept cell\tNext\nunbelievable\tKept alone")
        // Search finds them.
        XCTAssertEqual(try batch("believ", in: section).results.count, 1)
        XCTAssertEqual(try batch("Kept alone", in: section).results.count, 1)
    }

    /// The room the kept words take, and so every line and page, is theirs as it is without
    /// `aria-hidden`.
    func testKeptTextTakesTheRoomItTakesWithoutAriaHidden() throws {
        let size = CGSize(width: 240, height: 120)
        let (keptPaginator, keptPages) = H.pages(try section(), size: size)
        let (shownPaginator, shownPages) = H.pages(try section(kept: false), size: size)
        XCTAssertEqual(keptPages.map(\.range), shownPages.map(\.range))
        XCTAssertGreaterThan(keptPages.count, 1)
        for (keptPage, shownPage) in zip(keptPages, shownPages) {
            XCTAssertEqual(H.lines(in: H.pageView(keptPaginator, page: keptPage)).map(\.range),
                           H.lines(in: H.pageView(shownPaginator, page: shownPage)).map(\.range))
        }
    }

    func testCopyAndTheSelectionAHostIsToldOfKeepKeptText() async throws {
        let kept = try section()
        let (host, view) = try host(kept)
        XCTAssertEqual(view.visibleText, Self.copied)
        view.selectedRange = NSRange(location: 0, length: kept.string.length)
        host.canvas.textViewSelectionDidChange(view)
        try await host.settle()
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.text, Self.copied, "the selection a host is told of")
        #if os(macOS)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), Self.copied)
        #else
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("org.epublib.tests.kept-text.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        view.pasteboard = pasteboard
        view.copy(nil)
        XCTAssertEqual(pasteboard.string, Self.copied)
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

    func testSearchFindsKeptText() throws {
        let kept = try section(), shown = try section(kept: false)
        for (query, count) in [("kept", 5), ("The night", 1), ("bold again", 1), ("Kept heading", 1), ("Generated", 1)] {
            let found = try batch(query, in: kept)
            XCTAssertEqual(found.results.count, count, query)
            XCTAssertEqual(found.results.map(\.matchedText), try batch(query, in: shown).results.map(\.matchedText), query)
            XCTAssertEqual(found.results.map(\.contextAfter), try batch(query, in: shown).results.map(\.contextAfter), query)
        }
        XCTAssertEqual(try batch("Shown", in: kept).results.first?.contextAfter, " kept bold again words.")
    }

    // MARK: VoiceOver

    #if os(macOS)
    /// AppKit reads a text view's characters one for one with its ranges: a kept character is
    /// given to an assistive client as a space, as a hidden one is. A heading of kept words
    /// alone is no heading, and a link of kept words alone is a link without a name.
    func testOnMacAKeptCharacterIsASpaceToAnAssistiveClient() throws {
        let kept = try section()
        let (host, view) = try host(kept)
        let value = " he night came.\n     \nShown                 words.\n            \nHeading           end\n"
            + "Go           and shown      link.\n                \nFormula \u{FFFC} and           end.\nLast words."
        XCTAssertEqual(view.accessibilityValue(), value)
        XCTAssertEqual((view.accessibilityValue() as NSString?)?.length, kept.string.length, "every range matches the text")
        let whole = NSRange(location: 0, length: kept.string.length)
        XCTAssertEqual(view.accessibilityString(for: whole), value)
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: whole))
        XCTAssertEqual(rich.string, value)
        var attachments = 0
        rich.enumerateAttribute(.accessibilityAttachment, in: whole) { value, _, _ in if value != nil { attachments += 1 } }
        XCTAssertEqual(attachments, 0, "no element for the formula the book keeps from assistive technology")
        var levels: [NSRange] = []
        rich.enumerateAttribute(.accessibilityHeadingLevel, in: whole) { value, run, _ in if value != nil { levels.append(run) } }
        XCTAssertEqual(levels.map { (value as NSString).substring(with: $0) }, ["Heading           end"], "the heading of kept words alone has no level")
        let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        XCTAssertEqual(children.filter { $0.accessibilityRole()?.rawValue == "AXHeading" }.map { $0.accessibilityLabel() ?? "nil" },
                       ["Heading end"])
        let links = children.filter { $0.accessibilityRole() == .link }
        XCTAssertEqual(links.map { $0.accessibilityTitle() ?? "nil" }, ["nil", "shown link"])
        XCTAssertTrue(links.first?.accessibilityPerformPress() == true, "the link of kept words alone is followed")
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        var lines: [String] = []
        for line in 0..<20 {
            let range = view.accessibilityRange(forLine: line)
            guard range.location != NSNotFound else { break }
            lines.append(view.accessibilityString(for: range) ?? "")
        }
        XCTAssertEqual(lines.count, 9)
        assertNoKeptWord(lines.joined(), "the lines VoiceOver reads")
        if let data = view.accessibilityRTF(for: whole) {
            let rtf = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            assertNoKeptWord(rtf.string, "the rich text an assistive client is given")
        }
        view.selectedRange = whole
        assertNoKeptWord(view.accessibilitySelectedText(), "the selected text an assistive client is given")
    }

    /// Continuous scroll and a note's popover show their text in a text view of AppKit's own
    /// accessibility, which gives kept characters as spaces too.
    func testOnMacAViewThatIsNotAPageGivesKeptCharactersAsSpaces() throws {
        let kept = try section()
        let view = H.view(kept.string, size: CGSize(width: 420, height: 600), pageColumn: false)
        let value = try XCTUnwrap(view.accessibilityValue())
        XCTAssertEqual((value as NSString).length, kept.string.length)
        assertNoKeptWord(value, "the value")
        XCTAssertTrue(value.contains("he night came."))
    }

    /// The row of a table used for layout is a group called by its cells' words, and a row of a
    /// table of data its table, named by that row's: none of them kept (#551). A cell's text
    /// area gives kept characters as spaces, and its selected text leaves them out.
    func testOnMacATableCellsKeptWordsAreNotInWhatItsRowIsCalled() async throws {
        let view = try await tablesHost().view
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        var elements: [NSAccessibilityElement] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            if let element = value as? NSAccessibilityElement { elements.append(element) }
        }
        XCTAssertEqual(elements.map { $0.accessibilityRole() }, [.group, .table, .table])
        XCTAssertEqual(elements.map { $0.accessibilityLabel() }, ["Left words, Right words", "Name, Note", "Alder tree"],
                       "what the row's group and the table at each row are called")
        let table = try XCTUnwrap(elements.last as? ReaderTableElement)
        let rows = try XCTUnwrap(table.accessibilityRows() as? [NSAccessibilityElement])
        XCTAssertEqual(rows.compactMap { $0.accessibilityChildren() }.joined().count, 4, "every cell of the table, the one of kept words alone too")
        let mounted = (view.tableInteraction?.cells ?? [:]).sorted { ($0.key.location, $0.key.cell) < ($1.key.location, $1.key.cell) }.map(\.value)
        XCTAssertEqual(mounted.count, 6)
        for cell in mounted {
            assertNoUnheardWord(cell.accessibilityValue(), "a cell's text area")
            cell.cellSelection = cell.shownCharacters
            assertNoUnheardWord(cell.accessibilitySelectedText(), "the selected text of a cell's text area")
        }
        XCTAssertEqual(mounted.map { $0.accessibilitySelectedText() ?? "nil" }, ["Left  words", "Right  words", "Name", "Note", "Alder  tree", ""])
        XCTAssertEqual(mounted.map { $0.cellText.readerPlainText(in: $0.cellSelection) },
                       ["Left unheard words", "Right Unheard picture words", "Name", "Note", "Alder unheard words tree", "Unheard alone"],
                       "what a copy of each cell's selection takes")
    }
    #else
    private func described(_ element: UIAccessibilityElement) -> String {
        let traits = element.accessibilityTraits
        let kind = [(UIAccessibilityTraits.link, "link"), (.header, "heading"), (.image, "image"), (.staticText, "text")]
            .filter { traits.contains($0.0) }.map(\.1)
        return kind.joined(separator: "+") + " " + (element.accessibilityLabel.map { "\"\($0)\"" } ?? "nil")
    }

    func testOnIPhoneAndIPadNoElementReadsKeptText() throws {
        let kept = try section()
        let (host, view) = try host(kept)
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map(described), [
            "text \"he night came.\n\"", "text \"Shown  words.\n\"", "heading+text \"Heading  end\"",
            "text \"Go \"", "link nil", "text \" and \"", "link \"shown  link\"", "text \".\n\"",
            "text \"Formula  and  end.\n\"", "text \"Last words.\"",
        ], "no element for the stars, the heading of kept words or the generated words; the link of kept words alone is a link without a name")
        assertNoKeptWord(elements.compactMap(\.accessibilityLabel).joined(separator: "|"), "what VoiceOver reads")
        XCTAssertTrue(elements[4].accessibilityActivate(), "the link of kept words alone is followed")
        XCTAssertEqual(host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml"))
        XCTAssertEqual(view.accessibilityValue, Self.spoken)
    }

    /// The row of a table used for layout is a line of its cells' words, and a table of data a
    /// table of cells, each its words: none of them kept, nor in the names of the actions that
    /// select a cell's words (#551). A cell of kept words alone says nothing and has nothing to
    /// select, and keeps its place in the grid.
    func testOnIPhoneAndIPadATableCellsKeptWordsAreNotInItsElementOrItsRowsLine() async throws {
        let view = try await tablesHost().view
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.count, 4, "the lines before and after, the row's line and the table of data")
        let words = { (element: UIAccessibilityElement) in element.accessibilityLabel?.trimmingCharacters(in: .newlines) }
        XCTAssertEqual(words(elements[1]), "Left words\tRight words", "the row's line")
        let actions = (elements[1].accessibilityCustomActions ?? []).map(\.name).filter { $0.hasPrefix("Select") }
        XCTAssertEqual(actions, ["Select Table Text: Left  words", "Select Table Text: Right  words"])
        let table = try XCTUnwrap(elements[2] as? UIAccessibilityContainerDataTable & UIAccessibilityElement)
        let cells = try XCTUnwrap(table.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(cells.map(words), ["Name", "Note", "Alder tree", nil], "each cell's element")
        XCTAssertEqual(cells.map { ($0.accessibilityCustomActions ?? []).map(\.name).filter { $0.hasSuffix("Cell Text") } },
                       [["Select Cell Text"], ["Select Cell Text"], ["Select Cell Text"], []])
        for element in elements + cells {
            assertNoUnheardWord(element.accessibilityLabel, "what VoiceOver reads")
            for action in element.accessibilityCustomActions ?? [] { assertNoUnheardWord(action.name, "an action's name") }
        }
        assertNoUnheardWord(view.accessibilityValue, "the page's value")
    }
    #endif

    // MARK: Table cells

    /// A table used for layout and a table of data, each with words kept from assistive
    /// technology in a cell, the first with a picture kept so in another, the second with a
    /// cell of kept words alone. Every word kept begins "unheard" or "Unheard", and no other.
    private static let tables = """
        <p>Words before.</p>\
        <table role="presentation"><tr><td>Left <span aria-hidden="true">unheard</span> words</td>\
        <td>Right <img src="p.png" alt="Unheard picture" aria-hidden="true"/> words</td></tr></table>\
        <table><tr><th>Name</th><th>Note</th></tr>\
        <tr><td>Alder <span aria-hidden="true">unheard words</span> tree</td><td><span aria-hidden="true">Unheard alone</span></td></tr></table>\
        <p>Words after.</p>
        """
    /// What a selection of the whole section and a copy of it take: every kept word.
    private static let tablesCopied = "Words before.\nLeft unheard words\tRight Unheard picture words\nName\tNote\n"
        + "Alder unheard words tree\tUnheard alone\nWords after."

    private func tablesSection() throws -> SectionText {
        try H.build(Self.tables, css: H.reset + "img { width: 20px; height: 20px }",
                    files: ["p.png": RichFixture.image(width: 40, height: 40)])
    }

    /// A host showing `tables` on one page, with the text views of its cells.
    private func tablesHost() async throws -> (host: CanvasHost, view: ReaderTextView) {
        let (host, view) = try host(try tablesSection())
        for _ in 0..<40 where (view.tableInteraction?.cells.count ?? 0) < 6 {
            host.layOut()
            try await host.settle(50)
            view.refreshTableInteractions()
        }
        return (host, view)
    }

    private func assertNoUnheardWord(_ text: String?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse((text ?? "").localizedCaseInsensitiveContains("unheard"), "\(message): \((text ?? "").debugDescription)", file: file, line: line)
    }

    /// A selection of the section, Copy and the selection a host is told of take the kept words
    /// in a table's cells, and VoiceOver is given none of them (#551).
    func testCopyAndTheSelectionAHostIsToldOfKeepATableCellsKeptWords() async throws {
        let section = try tablesSection()
        XCTAssertEqual(section.mappedText(in: 0..<section.string.length), Self.tablesCopied)
        XCTAssertEqual(section.string.readerPlainText(), Self.tablesCopied)
        assertNoUnheardWord(section.string.readerPlainText(spoken: true), "what VoiceOver is given")
        let (host, view) = try await tablesHost()
        view.selectedRange = NSRange(location: 0, length: section.string.length)
        XCTAssertEqual(host.canvas.selectionText(for: view), Self.tablesCopied)
        host.canvas.textViewSelectionDidChange(view)
        try await host.settle()
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.text, Self.tablesCopied, "the selection a host is told of")
        #if os(macOS)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), Self.tablesCopied)
        #else
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("org.epublib.tests.kept-cells.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        view.pasteboard = pasteboard
        view.copy(nil)
        XCTAssertEqual(pasteboard.string, Self.tablesCopied)
        #endif
    }
}
