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

/// Rich content in the flow that `visibility: hidden` or `visibility: collapse` hides: an image,
/// an SVG file, an inline SVG drawing, a formula, a rule, the words shown where an image cannot
/// be drawn, and the pictures and formulas of a table ("Hidden text" in `doc/native-viewer.md`,
/// [#549](https://github.com/vocaro/EPUBLib/issues/549)). It keeps its room and draws nothing
/// (#132), and as hidden text is (#357, `HiddenTextTests`) it is left out of what VoiceOver
/// reads, of what a selection copies and of what search finds, and a hidden image is not
/// opened from its room. One that sets `visibility: visible` again is shown and read.
@MainActor final class HiddenRichContentTests: XCTestCase {
    private typealias H = BoxLayoutHarness
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private static let drawing = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="blue"/></svg>"#
    private static let files = ["p.png": RichFixture.image(width: 40, height: 40), "art.svg": Data(drawing.utf8)]

    /// A hidden picture between shown words; a hidden paragraph that holds an SVG file, an inline
    /// drawing, a formula and a picture shown again; a hidden rule; the words of a hidden picture
    /// that cannot be drawn; and a picture `visibility: collapse` hides.
    private static let body = """
        <p>Shown before <img class="v" src="p.png" alt="Veiled picture"/> shown after.</p>\
        <p class="v">Masked <img src="art.svg" alt="Masked drawing"/> \
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><title>Masked inline</title><rect width="40" height="20"/></svg> \
        <math xmlns="http://www.w3.org/1998/Math/MathML" alttext="Masked formula"><mi>x</mi></math> \
        <img class="u" src="p.png" alt="Revealed picture"/> end.</p>\
        <hr class="v"/>\
        <p>Lost <img class="v" src="missing.png" alt="Lost words"/> found.</p>\
        <p>Folded <img class="c" src="p.png" alt="Collapsed picture"/> done.</p>\
        <p>Last words.</p>
        """
    private static let hiding = ".v { visibility: hidden } .c { visibility: collapse } .u { visibility: visible } "
        + "img, svg { width: 20px; height: 20px } "
    private static let showing = ".v, .c, .u { visibility: visible } img, svg { width: 20px; height: 20px } "
    private static let hiddenWords = ["Veiled", "Masked", "Lost words", "Collapsed"]

    /// The section's characters, the same whether the content is hidden or shown.
    private static let characters = "Shown before \u{FFFC} shown after.\nMasked \u{FFFC} \u{FFFC} \u{FFFC} \u{FFFC} end.\n\u{FFFC}\n"
        + "Lost Lost words found.\nFolded \u{FFFC} done.\nLast words."
    /// What VoiceOver, Copy and search read of it shown: every picture's and formula's words.
    private static let shownRead = "Shown before Veiled picture shown after.\n"
        + "Masked Masked drawing Masked inline Masked formula Revealed picture end.\n\nLost Lost words found.\n"
        + "Folded Collapsed picture done.\nLast words."
    /// What they read of it hidden: the words shown again, and the breaks that keep the lines apart.
    private static let read = "Shown before  shown after.\nRevealed picture\n\nLost  found.\nFolded  done.\nLast words."

    private func section(hidden: Bool = true) throws -> SectionText {
        try H.build(Self.body, css: H.reset + (hidden ? Self.hiding : Self.showing), files: Self.files)
    }

    private func host(_ section: SectionText, size: CGSize = CGSize(width: 420, height: 500)) throws -> (CanvasHost, ReaderTextView) {
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

    /// The attachments of `text` with their characters, in order.
    private static func attachments(_ text: NSAttributedString) -> [(attachment: NSTextAttachment, location: Int)] {
        var found: [(NSTextAttachment, Int)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, run, _ in
            if let attachment = value as? NSTextAttachment { found.append((attachment, run.location)) }
        }
        return found
    }

    // MARK: The text

    func testHiddenRichContentKeepsItsCharactersAndIsLeftOutOfWhatIsRead() throws {
        let hidden = try section(), shown = try section(hidden: false)
        XCTAssertEqual(hidden.string.string, Self.characters, "its characters stay, to take their room")
        XCTAssertEqual(shown.string.string, Self.characters)
        XCTAssertEqual(shown.string.readerPlainText(), Self.shownRead)
        XCTAssertEqual(shown.string.readerPlainText(spoken: true), Self.shownRead)
        XCTAssertEqual(hidden.string.readerPlainText(), Self.read, "what Copy, a selection and a search's context read")
        XCTAssertEqual(hidden.string.readerPlainText(spoken: true), Self.read, "what VoiceOver is given")
        XCTAssertEqual(hidden.mappedText(in: 0..<hidden.string.length), Self.read, "what a copy of the book's own text takes")
        BuilderHarness.assertMapRoundTrips(hidden)

        // Each hidden attachment's character is hidden, as hidden text's is, and the attachment
        // is passed over by assistive technology. Its words stay its own, for when it is shown.
        let found = Self.attachments(hidden.string), standing = Self.attachments(shown.string)
        XCTAssertEqual(found.map { String(describing: type(of: $0.attachment)) }, ["ReaderImageAttachment", "ReaderImageAttachment",
            "ReaderImageAttachment", "MathAttachment", "ReaderImageAttachment", "ReaderRuleAttachment", "ReaderImageAttachment"])
        let revealed = (Self.characters as NSString).range(of: "\u{FFFC} end").location
        for ((attachment, location), (twin, _)) in zip(found, standing) {
            let isShown = location == revealed
            XCTAssertEqual(hidden.string.attribute(.readerHidden, at: location, effectiveRange: nil) == nil, isShown, "\(location)")
            XCTAssertNil(shown.string.attribute(.readerHidden, at: location, effectiveRange: nil), "\(location)")
            XCTAssertEqual(hidden.string.passesOver(attachment, at: NSRange(location: location, length: 1)), !isShown, "\(location)")
            let words = attachment as? ReaderTextualAttachment, twinWords = twin as? ReaderTextualAttachment
            XCTAssertEqual(words?.textEquivalent, twinWords?.textEquivalent, "\(location)")
            if !(attachment is ReaderRuleAttachment) { XCTAssertEqual(words?.spokenEquivalent.isEmpty, !isShown, "\(location)") }
        }
        // The words of a picture that cannot be drawn are hidden as its character would be.
        let lost = (Self.characters as NSString).range(of: "Lost words")
        XCTAssertNotNil(hidden.string.attribute(.readerHidden, at: lost.location, effectiveRange: nil))
        // A part of the text reads what is shown of it: one space where a hidden picture
        // stands between two shown words, as its room sets them apart on the page.
        let joined = try H.build("<p>un<img class='v' src='p.png' alt='Veiled'/>able</p>", css: H.reset + Self.hiding, files: Self.files)
        XCTAssertEqual(joined.string.readerPlainText(), "un able")
        XCTAssertEqual(joined.string.readerPlainText(spoken: true), "un able")
    }

    /// The pictures and formulas in a table's cells: in a hidden table, and hidden in a shown one.
    /// A cell that sets `visibility: visible` again reads its own.
    func testATableCellReadsItsShownPicturesAndFormulasOnly() throws {
        let section = try H.build("""
            <table class="v"><tr><td>Masked cell <img src="p.png" alt="Masked cell picture"/></td>\
            <td class="u">Revealed cell <img src="p.png" alt="Revealed cell picture"/></td></tr></table>\
            <table><tr><td>Plain <img class="v" src="p.png" alt="Veiled cell picture"/> cell</td>\
            <td>Next <math xmlns="http://www.w3.org/1998/Math/MathML" class="v" alttext="Veiled cell formula"><mi>y</mi></math> cell</td></tr></table>
            """, css: H.reset + Self.hiding, files: Self.files)
        let rows = Self.attachments(section.string).compactMap { $0.attachment as? TableRowAttachment }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.cellWords), [["", "Revealed cell Revealed cell picture"], ["Plain cell", "Next cell"]],
                       "what VoiceOver reads of each cell")
        XCTAssertEqual(rows.map(\.textEquivalent), ["\tRevealed cell Revealed cell picture", "Plain cell\tNext cell"])
        XCTAssertEqual(section.string.readerPlainText(), "\tRevealed cell Revealed cell picture\nPlain cell\tNext cell")
        XCTAssertEqual(section.mappedText(in: 0..<section.string.length), "\tRevealed cell Revealed cell picture\nPlain  cell\tNext  cell",
                       "what a copy of the rows takes: the cells' own characters, a space each side of what is hidden")
        XCTAssertEqual(rows.map(\.saysNothing), [false, false])
        // A cell's pictures that are hidden are passed over where a cell is read, and are no
        // picture of a cell that VoiceOver is told of.
        let size = CGSize(width: 400, height: 200)
        let pictures = rows.map { $0.spokenCells(size: size, viewportHeight: 800).flatMap(\.images).map(\.alt) }
        XCTAssertEqual(pictures, [["Revealed cell picture"], []])
        for row in rows {
            for cell in row.table.cells {
                for (attachment, location) in Self.attachments(cell.content) {
                    let hiddenHere = cell.content.attribute(.readerHidden, at: location, effectiveRange: nil) != nil
                    XCTAssertEqual(cell.content.passesOver(attachment, at: NSRange(location: location, length: 1)), hiddenHere)
                }
            }
        }
    }

    // MARK: Copy and a selection

    func testCopyAndTheSelectionAHostIsToldOfLeaveHiddenRichContentOut() async throws {
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
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("org.epublib.tests.hidden-rich.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        view.pasteboard = pasteboard
        view.copy(nil)
        XCTAssertEqual(pasteboard.string, Self.read)
        #endif
        // A selection of a hidden picture alone copies nothing of it.
        let veiled = (Self.characters as NSString).range(of: "\u{FFFC}")
        XCTAssertEqual(view.plainText(in: veiled), "")
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

    func testSearchReadsNoHiddenRichContent() throws {
        let hidden = try section(), shown = try section(hidden: false)
        for query in ["before", "after", "found", "done", "Last"] {
            let standing = try batch(query, in: shown), found = try batch(query, in: hidden)
            XCTAssertEqual(found.results.count, 1, query)
            XCTAssertEqual(standing.results.count, 1, query)
            for result in found.results {
                assertNoHiddenWord(result.contextBefore + result.matchedText + result.contextAfter, "the context of \(query)")
            }
        }
        XCTAssertEqual(try batch("before", in: shown).results.first?.contextAfter, " Veiled picture shown after.")
        XCTAssertEqual(try batch("before", in: hidden).results.first?.contextAfter, " shown after.")
        // An occurrence that takes in a hidden picture's character is no result, as one that
        // takes in hidden words is not.
        XCTAssertEqual(try batch("before shown", in: shown).results.count, 1)
        XCTAssertEqual(try batch("before shown", in: hidden).results.count, 0)
    }

    // MARK: VoiceOver

    #if os(macOS)
    /// AppKit reads a text view's characters one for one with its ranges: a hidden attachment's
    /// is a space, as a hidden word's is, with no element. A hidden rule is passed over as one
    /// the book keeps from assistive technology is: its character and its break are spaces and
    /// its line is part of the line after it.
    func testOnMacHiddenRichContentIsASpaceWithNoElement() throws {
        let hidden = try section()
        let (_, view) = try host(hidden)
        let value = "Shown before   shown after.\n             \u{FFFC}     \n  Lost            found.\nFolded   done.\nLast words."
        XCTAssertEqual(view.accessibilityValue(), value)
        XCTAssertEqual((view.accessibilityValue() as NSString?)?.length, hidden.string.length, "every range matches the text")
        let whole = NSRange(location: 0, length: hidden.string.length)
        XCTAssertEqual(view.accessibilityString(for: whole), value)
        XCTAssertEqual(view.accessibilityAttributedString(for: whole)?.string, value)
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: whole))
        var elements: [(location: Int, element: NSAccessibilityElement)] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: whole) { value, run, _ in
            if let element = value as? NSAccessibilityElement { elements.append((run.location, element)) }
        }
        let revealed = (Self.characters as NSString).range(of: "\u{FFFC} end").location
        XCTAssertEqual(elements.map(\.location), [revealed], "an element for the picture shown again, and for nothing hidden")
        XCTAssertEqual(elements.first?.element.accessibilityLabel(), "Revealed picture")
        XCTAssertEqual(elements.first.map { ($0.element.accessibilityCustomActions() ?? []).map(\.name) }, ["Inspect Image: Revealed picture"])
        var lines: [String] = []
        for line in 0..<20 {
            let range = view.accessibilityRange(forLine: line)
            guard range.location != NSNotFound else { break }
            lines.append(view.accessibilityString(for: range) ?? "")
        }
        XCTAssertEqual(lines, ["Shown before   shown after.\n", "             \u{FFFC}     \n", "  Lost            found.\n", "Folded   done.\n", "Last words."],
                       "no line of its own for the hidden rule")
        assertNoHiddenWord(lines.joined(), "the lines VoiceOver reads")
        view.selectedRange = whole
        assertNoHiddenWord(view.accessibilitySelectedText(), "the selected text an assistive client is given")
    }

    /// Continuous scroll gives the same spaces.
    func testOnMacAViewThatIsNotAPageGivesHiddenRichContentAsSpaces() throws {
        let hidden = try section()
        let view = H.view(hidden.string, size: CGSize(width: 420, height: 600), pageColumn: false)
        let value = try XCTUnwrap(view.accessibilityValue())
        XCTAssertEqual((value as NSString).length, hidden.string.length)
        XCTAssertEqual(value.filter { $0 == "\u{FFFC}" }.count, 1, "the character of the picture shown again alone")
        assertNoHiddenWord(value, "the value")
    }

    /// A row's group is called by its cells' shown words, and offers to inspect its shown
    /// pictures alone.
    func testOnMacATableRowIsCalledByItsShownWordsAndPictures() throws {
        let section = try H.build("""
            <table class="v"><tr><td>Masked cell <img src="p.png" alt="Masked cell picture"/></td>\
            <td class="u">Revealed cell <img src="p.png" alt="Revealed cell picture"/></td></tr></table>\
            <table><tr><td>Plain <img class="v" src="p.png" alt="Veiled cell picture"/> cell</td><td>Next</td></tr></table>
            """, css: H.reset + Self.hiding, files: Self.files)
        let (_, view) = try host(section)
        let whole = NSRange(location: 0, length: section.string.length)
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: whole))
        var groups: [NSAccessibilityElement] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: whole) { value, _, _ in
            if let element = value as? NSAccessibilityElement { groups.append(element) }
        }
        XCTAssertEqual(groups.map { $0.accessibilityLabel() ?? "nil" }, ["Revealed cell Revealed cell picture", "Plain cell, Next"])
        XCTAssertEqual(groups.map { ($0.accessibilityCustomActions() ?? []).map(\.name) }, [["Inspect Image: Revealed cell picture"], []])
    }
    #else
    func testOnIPhoneAndIPadNoElementReadsHiddenRichContent() throws {
        let hidden = try section()
        let (_, view) = try host(hidden)
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        let labels = elements.map { $0.accessibilityLabel ?? "" }
        assertNoHiddenWord(labels.joined(separator: "|"), "what VoiceOver reads")
        XCTAssertEqual(labels, ["Shown before  shown after.\n", "Revealed picture", "Lost  found.\n", "Folded  done.\n", "Last words."],
                       "a line with a hidden picture in it is one element; the picture shown again is one")
        XCTAssertEqual(elements.map { $0.accessibilityTraits.contains(.image) }, [false, true, false, false, false])
        let inspections = elements.flatMap { ($0.accessibilityCustomActions ?? []).map(\.name).filter { $0.hasPrefix("Inspect Image") } }
        XCTAssertEqual(inspections, ["Inspect Image: Revealed picture"])
        XCTAssertEqual(view.accessibilityValue, Self.read)
    }

    /// A page of hidden pictures alone lists nothing, as a page of hidden text alone lists
    /// nothing: unlike decoration, nobody reads them.
    func testOnIPhoneAndIPadAPageOfHiddenPicturesAloneListsNothing() throws {
        let section = try H.build("<p class='v'><img src='p.png' alt='Veiled'/></p><hr class='v'/>"
                                  + "<p><math xmlns='http://www.w3.org/1998/Math/MathML' class='v' alttext='Veiled formula'><mi>x</mi></math></p>",
                                  css: H.reset + Self.hiding + "img { display: block }", files: Self.files)
        let host = CanvasHost(FakeCanvasSource([section.string, CanvasText.body("Next section.")]), size: CGSize(width: 420, height: 400))
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        let view = try XCTUnwrap(host.canvas.columns.first)
        XCTAssertEqual(view.accessibilityElementCount(), 0)
        XCTAssertTrue(host.canvas.accessibilityScroll(.next), "the page after it is one scroll away")
        XCTAssertEqual((view.accessibilityElements as? [UIAccessibilityElement])?.map { $0.accessibilityLabel ?? "" }, ["Next section."])
    }

    /// A table's row is read by its cells' shown words.
    func testOnIPhoneAndIPadATableRowReadsItsShownWordsAndPictures() throws {
        let section = try H.build("""
            <table class="v"><tr><td>Masked cell <img src="p.png" alt="Masked cell picture"/></td>\
            <td class="u">Revealed cell <img src="p.png" alt="Revealed cell picture"/></td></tr></table>\
            <table><tr><td>Plain <img class="v" src="p.png" alt="Veiled cell picture"/> cell</td><td>Next</td></tr></table>
            """, css: H.reset + Self.hiding, files: Self.files)
        let (_, view) = try host(section)
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        let labels = elements.map { $0.accessibilityLabel ?? "" }
        XCTAssertFalse(labels.joined().contains("Masked") || labels.joined().contains("Veiled"), "\(labels)")
        XCTAssertTrue(labels.joined().contains("Revealed cell picture"), "\(labels)")
        let inspections = elements.flatMap { ($0.accessibilityCustomActions ?? []).map(\.name).filter { $0.hasPrefix("Inspect Image") } }
        XCTAssertEqual(inspections, ["Inspect Image: Revealed cell picture"])
    }
    #endif

    // MARK: The image inspector

    /// A tap or a double click on a hidden picture's room opens nothing, as a browser gives a
    /// pointer nothing of a hidden element, and the inspector does not open for it.
    func testAHiddenPictureIsNotOpenedFromItsRoom() throws {
        let hidden = try section()
        let (host, view) = try host(hidden)
        func center(of location: Int) throws -> CGPoint {
            let frame = try XCTUnwrap(view.segmentFrames(for: NSRange(location: location, length: 1)).first, "\(location)")
            return CGPoint(x: frame.midX + view.containerOrigin.x, y: frame.midY + view.containerOrigin.y)
        }
        let found = Self.attachments(hidden.string).filter { $0.attachment is ReaderImageAttachment }
        let revealed = (Self.characters as NSString).range(of: "\u{FFFC} end").location
        for (attachment, location) in found {
            let image = try XCTUnwrap(attachment as? ReaderImageAttachment)
            if location == revealed {
                XCTAssertTrue(view.image(at: try center(of: location)) === image, "the picture shown again is opened")
                host.canvas.inspectImage(image)
                XCTAssertNotNil(host.canvas.imageInspector)
                host.canvas.imageInspector?.close()
            } else {
                XCTAssertNil(view.image(at: try center(of: location)), "\(location): \(image.alt)")
                host.canvas.inspectImage(image)
                XCTAssertNil(host.canvas.imageInspector, "\(location): \(image.alt)")
            }
        }
    }
}
