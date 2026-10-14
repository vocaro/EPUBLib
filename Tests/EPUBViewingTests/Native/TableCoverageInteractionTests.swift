import CoreGraphics
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The native text surface over a cell (`TableCellTextView`) and the surfaces a text view mounts
/// for its visible rows (`ReaderTableInteraction`): "select and Copy cell text, invoke the host's
/// selection action, follow internal links … Interaction surfaces are mounted only for visible cells."
@MainActor final class TableCoverageInteractionTests: XCTestCase {
    private func notifySelectionChanged(_ cell: TableCellTextView) {
        #if os(macOS)
        cell.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: cell))
        #else
        cell.textViewDidChangeSelection(cell)
        #endif
    }

    /// The frame of a character's glyph in the cell's own coordinates.
    private func glyphFrame(_ index: Int, in cell: TableCellTextView) -> CGRect {
        #if os(macOS)
        let manager = cell.layoutManager!, container = cell.textContainer!
        #else
        let manager = cell.layoutManager, container = cell.textContainer
        #endif
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let frame = manager.boundingRect(forGlyphRange: glyphs, in: container)
        #if os(macOS)
        return frame.offsetBy(dx: cell.textContainerOrigin.x, dy: cell.textContainerOrigin.y)
        #else
        return frame
        #endif
    }

    private func surface(_ text: NSAttributedString, showing shown: NSRange? = nil, width: CGFloat = 400) -> TableCellTextView {
        let cell = TableCellTextView(text: text, width: width, characters: shown ?? NSRange(location: 0, length: text.length))
        cell.configure(frame: CGRect(x: 0, y: 0, width: width, height: 200), scale: 1, textOffset: .zero, actionTitle: nil)
        return cell
    }

    // MARK: One cell's surface

    func testASurfaceIsSelectableUneditableTransparentAndKeepsItsCellsWholeText() {
        let text = CanvasText.body("First line of the cell.\nSecond line of the cell.")
        let shown = (text.string as NSString).range(of: "Second line of the cell.")
        let cell = TableCellTextView(text: text, width: 300, characters: shown)
        XCTAssertFalse(cell.isEditable)
        XCTAssertTrue(cell.isSelectable)
        XCTAssertEqual(cell.cellText.string, text.string, "the whole cell, so offsets are the cell's")
        XCTAssertEqual(cell.shownCharacters, shown)
        XCTAssertEqual(cell.cellSelection.length, 0)
        // Its glyphs are invisible: the row's drawing is the ink.
        let storage: NSTextStorage? = cell.textStorage
        XCTAssertEqual(storage?.string, text.string)
        XCTAssertEqual(storage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor, PlatformColor.clear)
        XCTAssertEqual(storage?.attribute(.foregroundColor, at: shown.location, effectiveRange: nil) as? PlatformColor, PlatformColor.clear)
        #if os(macOS)
        XCTAssertFalse(cell.drawsBackground)
        #else
        XCTAssertEqual(cell.backgroundColor, .clear)
        XCTAssertFalse(cell.isAccessibilityElement)
        XCTAssertTrue(cell.accessibilityElementsHidden, "for touch: VoiceOver reads the row")
        #endif
    }

    func testASelectionIsClampedToTheLinesTheSurfaceShowsAndReported() {
        let text = CanvasText.body("Hidden line one.\nShown line two.\nShown line three.")
        let shown = (text.string as NSString).range(of: "Shown line two.\nShown line three.")
        let cell = surface(text, showing: shown)
        var reported: [NSRange] = []
        cell.onSelection = { reported.append($0) }
        cell.cellSelection = NSRange(location: 3, length: shown.location + 5 - 3)
        XCTAssertEqual(reported, [], "setting a selection in code reports nothing by itself")
        notifySelectionChanged(cell)
        XCTAssertEqual(cell.cellSelection, NSRange(location: shown.location, length: 5), "the part outside the shown lines is dropped")
        XCTAssertEqual(reported.last, NSRange(location: shown.location, length: 5))
        cell.cellSelection = NSRange(location: shown.location + 2, length: 4)
        notifySelectionChanged(cell)
        XCTAssertEqual(reported.last, NSRange(location: shown.location + 2, length: 4), "a selection inside them is kept as it is")
        cell.cellSelection = NSRange(location: 0, length: 6)
        notifySelectionChanged(cell)
        XCTAssertEqual(cell.cellSelection.length, 0, "a selection wholly in hidden lines is none")
        XCTAssertEqual(reported.last?.length, 0)
        // Selected characters are drawn in their own ink again, over the selection's background.
        cell.cellSelection = NSRange(location: shown.location, length: 5)
        let storage: NSTextStorage? = cell.textStorage
        XCTAssertNotEqual(storage?.attribute(.foregroundColor, at: shown.location, effectiveRange: nil) as? PlatformColor, PlatformColor.clear)
        XCTAssertEqual(storage?.attribute(.foregroundColor, at: shown.location + 6, effectiveRange: nil) as? PlatformColor, PlatformColor.clear)
    }

    func testCopyOfACellSelectionIsItsTextWithAttachmentsAsTheirTextUnlessTheCanvasHasMore() throws {
        let formula = TextualTestAttachment()
        formula.textEquivalent = "x squared"
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Area is "))
        text.append(NSAttributedString(attachment: formula))
        text.append(CanvasText.body(" exactly \u{1F600}."))
        let cell = surface(text)
        cell.cellSelection = NSRange(location: 5, length: text.length - 5)
        func copied() throws -> String? {
            #if os(macOS)
            let pasteboard = NSPasteboard(name: .init("org.epublib.tests.TableCoverageInteraction"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(cell.writeSelection(to: pasteboard, type: .string))
            return pasteboard.string(forType: .string)
            #else
            var result: String?
            cell.copyTextToPasteboard = { result = $0 }
            cell.copy(nil)
            return result
            #endif
        }
        XCTAssertEqual(try copied(), "is x squared exactly \u{1F600}.", "never U+FFFC")
        cell.onCopy = { nil }
        XCTAssertEqual(try copied(), "is x squared exactly \u{1F600}.", "nothing from the canvas: the cell's own selection")
        cell.onCopy = { "The whole passage, across cells and pages" }
        XCTAssertEqual(try copied(), "The whole passage, across cells and pages")
        #if os(macOS)
        XCTAssertEqual(cell.writablePasteboardTypes, [.string])
        XCTAssertFalse(cell.writeSelection(to: NSPasteboard(name: .init("org.epublib.tests.TableCoverageInteraction.rtf")), type: .rtf), "only plain text leaves the reader")
        #endif
    }

    func testAPointMapsToTheNearestInsertionPointWithoutSplittingACharacter() {
        let text = CanvasText.body("Alpha \u{1F600} beta\nSecond line here")
        let string = text.string as NSString
        let cell = surface(text)
        func offset(_ index: Int, _ fraction: CGFloat) -> Int {
            let frame = glyphFrame(index, in: cell)
            return cell.cellCharacterOffset(at: CGPoint(x: frame.minX + frame.width * fraction, y: frame.midY))
        }
        XCTAssertEqual(offset(2, 0.2), 2, "the left of a glyph is before it")
        XCTAssertEqual(offset(2, 0.8), 3, "the right of it is after it")
        let emoji = string.range(of: "\u{1F600}")
        XCTAssertEqual(emoji.length, 2)
        XCTAssertEqual(offset(emoji.location, 0.2), emoji.location)
        XCTAssertEqual(offset(emoji.location, 0.8), emoji.upperBound, "never between the halves of a surrogate pair")
        let second = string.range(of: "Second")
        XCTAssertEqual(offset(second.location, 0.2), second.location)
        XCTAssertEqual(offset(second.location + 5, 0.8), second.upperBound)
        let last = glyphFrame(text.length - 1, in: cell)
        XCTAssertEqual(cell.cellCharacterOffset(at: CGPoint(x: last.maxX + 60, y: last.maxY + 300)), text.length, "past the text is its end")
    }

    func testPointsOutsideTheShownLinesClampToThem() {
        let text = CanvasText.body("Hidden line one.\nShown line two.\nHidden line three.")
        let shown = (text.string as NSString).range(of: "Shown line two.\n")
        let cell = surface(text, showing: shown)
        let above = glyphFrame(3, in: cell), below = glyphFrame(shown.upperBound + 4, in: cell), inside = glyphFrame(shown.location + 6, in: cell)
        XCTAssertEqual(cell.cellCharacterOffset(at: CGPoint(x: above.midX, y: above.midY)), shown.location)
        XCTAssertEqual(cell.cellCharacterOffset(at: CGPoint(x: below.midX, y: below.midY)), shown.upperBound)
        XCTAssertEqual(cell.cellCharacterOffset(at: CGPoint(x: inside.minX + 1, y: inside.midY)), shown.location + 6)
    }

    func testALinkIsHitOnItsOwnGlyphsOnlyAndOnlyInTheShownLines() throws {
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Before the link after it.\nA second line with another one."))
        let string = text.string as NSString
        let first = string.range(of: "the link"), second = string.range(of: "another one")
        text.addAttribute(.link, value: ReaderLink.internal(href: "OPS/two.xhtml#a").url, range: first)
        text.addAttribute(.link, value: ReaderLink.external("https://example.com/").url.absoluteString, range: second)
        let cell = surface(text)
        func hit(_ index: Int, in cell: TableCellTextView) -> (url: URL, range: NSRange)? {
            let frame = glyphFrame(index, in: cell)
            return cell.cellLink(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        let found = try XCTUnwrap(hit(first.location + 5, in: cell))
        XCTAssertEqual(found.range, first, "the whole link's range, wherever in it the hit lands")
        XCTAssertEqual(ReaderLink(url: found.url), .internal(href: "OPS/two.xhtml#a"))
        XCTAssertEqual(hit(second.location, in: cell).flatMap { ReaderLink(url: $0.url) }, .external("https://example.com/"), "a link stored as a string")
        XCTAssertNil(hit(2, in: cell), "text that is not a link")
        XCTAssertNil(hit(first.upperBound + 1, in: cell))
        let end = glyphFrame(text.length - 1, in: cell)
        XCTAssertNil(cell.cellLink(at: CGPoint(x: end.maxX + 80, y: end.midY)), "the empty space after a line is not its last character")
        XCTAssertNil(cell.cellLink(at: CGPoint(x: end.midX, y: end.maxY + 120)), "nor is the space below the text")
        // A continuation showing only the second line does not answer for the first line's link.
        let continuation = surface(text, showing: string.range(of: "A second line with another one."))
        XCTAssertNil(hit(first.location + 2, in: continuation))
        XCTAssertNotNil(hit(second.location + 2, in: continuation))
    }

    func testHighlightsAreDrawnOnlyOnTheShownCharactersAndReplaceEarlierOnes() {
        let text = CanvasText.body("Hidden line one.\nShown line two.")
        let shown = (text.string as NSString).range(of: "Shown line two.")
        let cell = surface(text, showing: shown)
        let storage: NSTextStorage? = cell.textStorage
        func background(_ index: Int) -> PlatformColor? { storage?.attribute(.backgroundColor, at: index, effectiveRange: nil) as? PlatformColor }
        cell.setCellHighlights([(NSRange(location: 4, length: shown.location + 5 - 4), PlatformColor.yellow)])
        XCTAssertNil(background(6), "the hidden part of a highlight is another continuation's to draw")
        XCTAssertEqual(background(shown.location), PlatformColor.yellow)
        XCTAssertEqual(background(shown.location + 4), PlatformColor.yellow)
        XCTAssertNil(background(shown.location + 5))
        XCTAssertNotEqual(storage?.attribute(.foregroundColor, at: shown.location, effectiveRange: nil) as? PlatformColor, PlatformColor.clear,
                          "highlighted characters get their ink back")
        cell.setCellHighlights([(NSRange(location: shown.location + 8, length: 3), PlatformColor.green), (NSRange(location: 900, length: 5), PlatformColor.red)])
        XCTAssertNil(background(shown.location), "the earlier highlight is gone")
        XCTAssertEqual(background(shown.location + 8), PlatformColor.green)
        XCTAssertEqual(storage?.attribute(.foregroundColor, at: shown.location, effectiveRange: nil) as? PlatformColor, PlatformColor.clear)
        cell.setCellHighlights([])
        XCTAssertNil(background(shown.location + 8))
    }

    #if os(macOS)
    func testACellSurfaceReadsAttachmentsFramesAndImageActionsToAssistiveTechnology() throws {
        let formula = TextualTestAttachment()
        formula.textEquivalent = "x squared"
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Hidden line.\nArea "))
        text.append(NSAttributedString(attachment: formula))
        text.append(CanvasText.body(" done.\nLast line."))
        let shown = NSRange(location: 13, length: text.length - 13)
        let cell = surface(text, showing: shown)
        let whole = NSRange(location: 0, length: shown.length)
        let spoken = try XCTUnwrap(cell.accessibilityAttributedString(for: whole))
        XCTAssertEqual(spoken.length, shown.length)
        let element = try XCTUnwrap(spoken.attribute(.accessibilityAttachment, at: 5, effectiveRange: nil) as? NSAccessibilityElement)
        XCTAssertEqual(element.accessibilityLabel(), "x squared")
        XCTAssertEqual(element.accessibilityRole(), .image, "named by its words, as in the text around a table")
        XCTAssertTrue(element.accessibilityParent() as? NSView === cell)
        XCTAssertEqual(element.accessibilityFrameInParentSpace(), glyphFrame(shown.location + 5, in: cell), "where it is drawn")
        XCTAssertNil(spoken.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil))
        XCTAssertNil(cell.accessibilityAttributedString(for: NSRange(location: 0, length: shown.length + 1)), "past the shown lines")
        XCTAssertNil(cell.accessibilityRTF(for: NSRange(location: shown.length, length: 4)))
        // Lines are numbered within the slice, and the insertion point is on one of them.
        XCTAssertEqual(cell.accessibilityRange(forLine: 0), NSRange(location: 0, length: 13))
        XCTAssertEqual(cell.accessibilityRange(forLine: 1).location, 13)
        XCTAssertEqual(cell.accessibilityRange(forLine: 2).location, NSNotFound)
        XCTAssertEqual(cell.accessibilityLine(for: 15), 1)
        XCTAssertEqual(cell.accessibilityLine(for: 900), NSNotFound)
        cell.setAccessibilitySelectedTextRange(NSRange(location: 14, length: 2))
        XCTAssertEqual(cell.accessibilityInsertionPointLineNumber(), 1)
        cell.setAccessibilitySelectedTextRange(NSRange(location: shown.length, length: 5))
        XCTAssertEqual(cell.accessibilitySelectedTextRange(), NSRange(location: 14, length: 2), "a range past the slice is ignored")
        XCTAssertEqual(cell.accessibilityRange(for: -1).location, NSNotFound)
        XCTAssertEqual(cell.accessibilityRange(for: shown.length).location, NSNotFound)
        XCTAssertEqual(cell.accessibilityStyleRange(for: shown.length).location, NSNotFound)
        XCTAssertEqual(cell.accessibilityRange(for: NSPoint(x: 10, y: 10)).location, NSNotFound, "without a window there is no screen point")
        XCTAssertEqual(cell.accessibilityFrame(for: NSRange(location: shown.length + 1, length: 1)), .zero)
        XCTAssertEqual(cell.accessibilityCustomActions()?.count, 0, "no image to inspect")
    }

    /// The elements `cell` gives in its rich text for `range`, each with its place in that text.
    private func attachmentElements(of cell: TableCellTextView, in range: NSRange? = nil) throws -> [(location: Int, element: NSAccessibilityElement)] {
        let range = range ?? NSRange(location: 0, length: cell.shownCharacters.length)
        let rich = try XCTUnwrap(cell.accessibilityAttributedString(for: range))
        XCTAssertEqual(rich.length, range.length)
        var found: [(Int, NSAccessibilityElement)] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, run, _ in
            if let element = value as? NSAccessibilityElement { found.append((run.location, element)) }
        }
        return found
    }

    /// What an element is to an assistive client: its role, what it is called or holds, whether
    /// it has help, and what it offers.
    private func described(_ element: NSAccessibilityElement) -> String {
        let role = [NSAccessibility.Role.staticText: "text", .image: "image", .group: "group", .link: "link"][element.accessibilityRole() ?? .unknown] ?? "other"
        let actions = (element.accessibilityCustomActions() ?? []).map(\.name)
        return "\(role) label \(element.accessibilityLabel() ?? "nil") value \(element.accessibilityValue() as? String ?? "nil")"
            + (element.accessibilityHelp() == nil ? "" : " help") + (actions.isEmpty ? "" : " \(actions)")
    }

    /// What a cell can hold besides words, one kind to a cell, as the VoiceOver fixture's
    /// section of entries has them (`scripts/make-voiceover-fixture.py`).
    private static let entries = [
        "<p>Upper part closes.</p><hr/><p>Lower half opens.</p>",
        "Sum <math xmlns=\"http://www.w3.org/1998/Math/MathML\" alttext=\"x squared\"><msup><mi>x</mi><mn>2</mn></msup></math> stated.",
        "Drawn <img src=\"square.png\" alt=\"Blue entry square\"/> shown.",
        "<span class=\"parked\">Parked entry words.</span>Seen entry words.",
        "Ornament <img src=\"square.png\" alt=\"\"/> passed.",
        "Undescribed <img src=\"square.png\"/> stands.",
    ]
    private static let entryStyle = ".parked { position: absolute; left: -999em; } img { width: 20px; height: 20px; }"

    private func hostOfEntries(nested: Bool = false) async throws -> (host: CanvasHost, cells: [TableCellTextView]) {
        let rows = stride(from: 0, to: Self.entries.count, by: 2).map { "<tr><td>\(Self.entries[$0])</td><td>\(Self.entries[$0 + 1])</td></tr>" }.joined()
        let inner = nested ? "<tr><td><table><tr><td>Inner one</td><td>Inner two</td></tr></table></td><td>Beside the inner grid.</td></tr>" : ""
        let section = try TableCoverage.section("<p>Entries follow.</p><table border='1'>\(rows)\(inner)</table>", css: Self.entryStyle,
                                                files: ["square.png": RichFixture.image(width: 40, height: 40)])
        let host = try await host(section, size: CGSize(width: 480, height: 600))
        let cells = mounted(host).map(\.cell)
        XCTAssertEqual(cells.count, Self.entries.count + (nested ? 2 : 0), "a text of its own for each cell of the table, and none for a table inside one")
        return (host, cells)
    }

    /// A cell is a text area of its own to VoiceOver on Mac, reached by interacting with its
    /// row and then with it. Each attachment's character carries an element there, as it does
    /// in the text around the table: the reader's word for a rule, an image named by its words
    /// for a formula or a picture, a hidden label's words as text, an image without a name for
    /// a picture nobody describes, and nothing for decoration.
    func testACellsAttachmentsAreToAssistiveTechnologyWhatTheyAreInThePagesText() async throws {
        let (host, cells) = try await hostOfEntries()
        defer { host.close() }
        let attachment = "\u{FFFC}"
        XCTAssertEqual(cells.map { $0.accessibilityValue() ?? "" },
                       ["Upper part closes.\n\(attachment)\nLower half opens.", "Sum \(attachment) stated.", "Drawn \(attachment) shown.",
                        "\(attachment)Seen entry words.", "Ornament \(attachment) passed.", "Undescribed \(attachment) stands."],
                       "the characters as they are, so every range matches")
        let found = try cells.map { try attachmentElements(of: $0) }
        XCTAssertEqual(found.map { $0.map(\.location) }, [[19], [4], [6], [0], [], [12]], "decoration has no element")
        XCTAssertEqual(found.map { $0.map { described($0.element) } }, [
            ["text label nil value \(ReaderRuleAttachment.spokenName)"],
            ["image label x squared value nil"],
            ["image label Blue entry square value nil help [\"Inspect Image: Blue entry square\"]"],
            ["text label nil value Parked entry words."],
            [],
            ["image label nil value nil [\"Inspect Image\"]"],
        ], "an image without a name has no help: VoiceOver reads the help of an element without a label in the label's place")
        for (cell, elements) in zip(cells, found) {
            for (location, element) in elements {
                XCTAssertTrue(element.accessibilityParent() as? NSView === cell)
                XCTAssertTrue((element.accessibilityChildren() ?? []).isEmpty)
                XCTAssertEqual(cell.accessibilityString(for: NSRange(location: location, length: 1)), attachment)
                XCTAssertEqual(element.accessibilityFrameInParentSpace(), glyphFrame(location, in: cell), "where it is drawn")
            }
        }
        XCTAssertFalse(try XCTUnwrap(found[0].first).element.accessibilityFrameInParentSpace().isEmpty, "a rule has a place")
        // A formula's reading has its own voice, as in the text around the table.
        let rich = try XCTUnwrap(cells[1].accessibilityAttributedString(for: NSRange(location: 0, length: cells[1].shownCharacters.length)))
        XCTAssertEqual(rich.attribute(.accessibilityLanguage, at: 4, effectiveRange: nil) as? String, "en")
        // The picture's element opens the picture, as the cell's own action does.
        XCTAssertNil(host.canvas.imageInspector)
        XCTAssertTrue(try XCTUnwrap(found[2].first?.element.accessibilityCustomActions()?.first).handler?() ?? false)
        XCTAssertNotNil(host.canvas.imageInspector)
        host.canvas.imageInspector?.close()
        XCTAssertEqual(cells.map { ($0.accessibilityCustomActions() ?? []).map(\.name) },
                       [[], [], ["Inspect Image: Blue entry square"], [], [], ["Inspect Image"]])
    }

    /// A rule or a picture the book keeps from assistive technology has no element in a cell,
    /// as in the text around the table, whatever words the picture has, and offers nothing to
    /// inspect. One that is all its link holds is the link.
    func testACellGivesNoElementForWhatTheBookKeepsFromAssistiveTechnology() async throws {
        let kept = [
            "<p>Upper part closes.</p><hr role=\"presentation\"/><p>Lower half opens.</p>",
            "Kept <img src=\"square.png\" alt=\"Kept words\" aria-hidden=\"true\"/> passed.",
            "Quiet <img src=\"square.png\" role=\"none\"/> passed.",
            "<a href=\"two.xhtml\"><img src=\"square.png\" alt=\"Unsaid\" aria-hidden=\"true\"/></a>",
        ]
        let section = try TableCoverage.section("<p>Entries follow.</p><table border='1'><tr><td>\(kept[0])</td><td>\(kept[1])</td></tr>"
                                                + "<tr><td>\(kept[2])</td><td>\(kept[3])</td></tr></table>", css: Self.entryStyle,
                                                files: ["square.png": RichFixture.image(width: 40, height: 40)])
        let host = try await host(section, size: CGSize(width: 480, height: 600))
        defer { host.close() }
        let cells = mounted(host).map(\.cell)
        XCTAssertEqual(cells.count, 4)
        let found = try cells.map { try attachmentElements(of: $0) }
        XCTAssertEqual(found.map { $0.map(\.location) }, [[], [], [], [0]])
        XCTAssertEqual(found[3].first?.element.accessibilityRole(), .link)
        XCTAssertEqual(found[3].first?.element.accessibilityTitle(), NSAccessibility.Role.image.description(with: nil),
                       "a link that is a picture alone is called a picture, without the words kept from assistive technology")
        XCTAssertEqual(cells.map { ($0.accessibilityCustomActions() ?? []).map(\.name) }, [[], [], [], []])
        XCTAssertEqual(cells[1].cellText.readerPlainText(in: cells[1].shownCharacters), "Kept Kept words passed.", "what Copy takes from the cell")
    }

    /// The same content in a page's text gives the same elements: one function says what an
    /// attachment is to an assistive client (`NSAccessibilityElement.setReaderAttachment`), and
    /// a rule's is `ReaderRuleAttachment.makeSeparator` in both.
    func testACellGivesTheElementsThePagesTextGivesForTheSameContent() async throws {
        let (cellHost, cells) = try await hostOfEntries()
        defer { cellHost.close() }
        let inCells = try cells.map { try attachmentElements(of: $0).map { described($0.element) } }
        let section = try TableCoverage.section(Self.entries.map { $0.hasPrefix("<p>") ? $0 : "<p>\($0)</p>" }.joined(),
                                                css: Self.entryStyle, files: ["square.png": RichFixture.image(width: 40, height: 40)])
        let pageHost = try await host(section, size: CGSize(width: 480, height: 1200))
        defer { pageHost.close() }
        let view = try XCTUnwrap(pageHost.canvas.textViews.first)
        XCTAssertEqual(view.placement.visibleLength, section.string.length, "the section is one page")
        let rich = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: 0, length: section.string.length)))
        var onThePage: [String] = []
        rich.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            if let element = value as? NSAccessibilityElement { onThePage.append(described(element)) }
        }
        XCTAssertEqual(inCells.flatMap { $0 }, onThePage)
        XCTAssertEqual(onThePage.count, 5)
    }

    /// VoiceOver asks an element what it is after the read that gave it. A cell made a new
    /// element for every read and kept none, so the element was gone by then and VoiceOver
    /// said nothing at a cell's attachment. An element is kept for as long as its cell is.
    func testACellKeepsItsAttachmentElementsFromOneReadToTheNext() async throws {
        let (host, cells) = try await hostOfEntries()
        defer { host.close() }
        let rule = cells[0]
        weak var kept: NSAccessibilityElement?
        var location = 0
        try autoreleasepool {
            let first = try XCTUnwrap(try attachmentElements(of: rule).first)
            (kept, location) = (first.element, first.location)
        }
        let element = try XCTUnwrap(kept, "the element outlives the string it was given in")
        XCTAssertEqual(element.accessibilityValue() as? String, ReaderRuleAttachment.spokenName)
        XCTAssertTrue(try XCTUnwrap(try attachmentElements(of: rule).first).element === element, "the same element on the next read")
        // A read of part of the cell gives it at its place in that part, and none where no attachment is.
        let part = try attachmentElements(of: rule, in: NSRange(location: location - 3, length: 6))
        XCTAssertEqual(part.map(\.location), [3])
        XCTAssertTrue(part.first?.element === element)
        XCTAssertTrue(try attachmentElements(of: rule, in: NSRange(location: 0, length: location)).isEmpty)
        XCTAssertTrue(try attachmentElements(of: rule, in: NSRange(location: location + 1, length: 5)).isEmpty)
        // Each cell has its own.
        let formula = try XCTUnwrap(try attachmentElements(of: cells[1]).first).element
        XCTAssertFalse(formula === element)
        XCTAssertTrue(try XCTUnwrap(try attachmentElements(of: cells[1]).first).element === formula)
    }

    /// The reader's word for a rule is what VoiceOver is told and no word of the book: the
    /// cell's text for a selection or a copy, and the row's for a listener on iPhone or iPad
    /// and for a search, have nothing in the rule's place.
    func testARuleInACellHasNoWordsForACopyASelectionOrItsRow() async throws {
        let (host, cells) = try await hostOfEntries()
        defer { host.close() }
        let rule = cells[0]
        XCTAssertEqual(rule.cellText.readerPlainText(), "Upper part closes.\n\nLower half opens.")
        rule.cellSelection = rule.shownCharacters
        XCTAssertEqual(rule.accessibilitySelectedText(), "Upper part closes.\n\nLower half opens.")
        XCTAssertEqual(rule.accessibilitySelectedTextRange(), NSRange(location: 0, length: rule.cellText.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(rule.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), "Upper part closes.\n\nLower half opens.")
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertFalse(view.visibleText.localizedCaseInsensitiveContains(ReaderRuleAttachment.spokenName))
        XCTAssertTrue(view.visibleText.contains("Upper part closes. Lower half opens.\tSum x squared stated."), view.visibleText)
        XCTAssertEqual(rule.accessibilityNumberOfCharacters(), rule.cellText.length)
        XCTAssertEqual(rule.accessibilityRange(forLine: 1), NSRange(location: 19, length: 2), "the rule's line: its character and the break after it")
    }

    /// A row that goes on over a page's end has a text for each part of a cell. Each gives the
    /// attachments of its own lines, at their places from the first character it shows.
    func testAPartOfACellGivesTheAttachmentsOfItsOwnLines() throws {
        let text = NSMutableAttributedString(attributedString: CanvasText.body("First line.\n"))
        text.append(NSAttributedString(attachment: ReaderRuleAttachment(style: ComputedStyle(), isDark: false)))
        text.append(CanvasText.body("\nThird line "))
        let label = SpokenLabelAttachment(text: "mots gard\u{E9}s", language: "fr")
        text.append(NSAttributedString(attachment: label))
        text.append(CanvasText.body(" ends."))
        let ruleAt = 12, labelAt = text.length - 7
        let upper = surface(text, showing: NSRange(location: 0, length: ruleAt + 2))
        let lower = surface(text, showing: NSRange(location: ruleAt + 2, length: text.length - ruleAt - 2))
        XCTAssertEqual(try attachmentElements(of: upper).map { "\($0.location) \(described($0.element))" },
                       ["\(ruleAt) text label nil value \(ReaderRuleAttachment.spokenName)"])
        XCTAssertEqual(try attachmentElements(of: lower).map { "\($0.location) \(described($0.element))" },
                       ["\(labelAt - ruleAt - 2) text label nil value mots gard\u{E9}s"])
        // A label that says what language it is in is read in that language's voice.
        let rich = try XCTUnwrap(lower.accessibilityAttributedString(for: NSRange(location: 0, length: lower.shownCharacters.length)))
        XCTAssertEqual(rich.attribute(.accessibilityLanguage, at: labelAt - ruleAt - 2, effectiveRange: nil) as? String, "fr")
        XCTAssertNotEqual(rich.attribute(.accessibilityLanguage, at: 0, effectiveRange: nil) as? String, "fr")
        XCTAssertNil(upper.accessibilityAttributedString(for: NSRange(location: 0, length: ruleAt + 3)), "past the lines it shows")
    }

    /// A table inside a cell is drawn with its cell and has no text views of its own, so each
    /// of its rows is its cells' words to a listener in the cell, as text.
    func testATableInsideACellIsItsCellsWordsAsText() async throws {
        let (host, cells) = try await hostOfEntries(nested: true)
        defer { host.close() }
        let outer = cells[6]
        XCTAssertEqual(outer.accessibilityValue(), "\u{FFFC}")
        XCTAssertEqual(try attachmentElements(of: outer).map { "\($0.location) \(described($0.element))" },
                       ["0 text label nil value Inner one\tInner two"])
        XCTAssertEqual(cells[7].accessibilityValue(), "Beside the inner grid.")
        XCTAssertTrue(try attachmentElements(of: cells[7]).isEmpty)
    }
    #endif

    // MARK: A text view's surfaces

    private func host(_ section: SectionText, size: CGSize = CGSize(width: 360, height: 400),
                      configuration: ReaderCanvasConfiguration = .init()) async throws -> CanvasHost {
        let host = CanvasHost(FakeCanvasSource([section.string]), size: size, configuration: configuration)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        try await settle(host) { _ in true }
        return host
    }

    /// Lays the canvas out and refreshes its surfaces until `condition` holds for the mounted
    /// ones, for at most a few seconds: layout after a show or a page turn takes some turns.
    private func settle(_ host: CanvasHost, until condition: ([(key: ReaderTableInteraction.Key, cell: TableCellTextView)]) -> Bool) async throws {
        for _ in 0..<100 {
            host.layOut()
            try await host.settle(50)
            for view in host.canvas.textViews { view.refreshTableInteractions() }
            if condition(mounted(host)) { return }
        }
    }

    private func mounted(_ host: CanvasHost) -> [(key: ReaderTableInteraction.Key, cell: TableCellTextView)] {
        host.canvas.textViews.flatMap { view in (view.tableInteraction?.cells ?? [:]).map { (key: $0.key, cell: $0.value) } }
            .sorted { ($0.key.location, $0.key.cell, $0.key.lower) < ($1.key.location, $1.key.cell, $1.key.lower) }
    }

    func testSurfacesAreMountedForTheRowsOnThePageOnlyAndReleasedWhenItTurns() async throws {
        let rows = (0..<150).map { "<tr><td>Row \($0)</td><td>Value \($0)</td></tr>" }.joined()
        let section = try TableCoverage.section("<table border='1'>\(rows)</table><p>After the table.</p>")
        let host = try await host(section)
        defer { host.close() }
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let first = mounted(host)
        XCTAssertGreaterThan(first.count, 4)
        XCTAssertLessThan(first.count, 80, "a page of rows, not the table's 300 cells")
        XCTAssertEqual(first.count % 2, 0, "both cells of every row on the page")
        XCTAssertTrue(first.allSatisfy { $0.key.location < view.placement.visibleLength }, "none for the layout context past the page")
        XCTAssertTrue(first.allSatisfy { $0.cell.superview === view })
        XCTAssertTrue(first.allSatisfy { $0.cell.frame.maxY <= view.bounds.maxY + 1 && $0.cell.frame.minY >= view.bounds.minY - 1 })
        let shownFirst = first.map { $0.cell.cellText.string }
        XCTAssertEqual(shownFirst.first, "Row 0")
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        try await settle(host) { cells in cells.contains { $0.cell.cellText.string == "Row \(first.count / 2)" } }
        XCTAssertTrue(first.allSatisfy { $0.cell.superview == nil }, "the last page's surfaces are released")
        let second = mounted(host)
        XCTAssertGreaterThan(second.count, 4)
        XCTAssertTrue(Set(second.map { $0.cell.cellText.string }).isDisjoint(with: shownFirst), "the next page's cells are other rows")
        XCTAssertEqual(second.first?.cell.cellText.string, "Row \(first.count / 2)")
    }

    func testATextViewWithoutTableRowsHasNoInteractionSurfaces() async throws {
        let section = try TableCoverage.section("<p>Only prose here.</p><table><tr><td>A one-column callout</td></tr></table>")
        let host = try await host(section)
        defer { host.close() }
        let view = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertFalse(view.containsTableRows)
        XCTAssertNil(view.tableInteraction)
        XCTAssertFalse(view.selectTableRange(ReaderTextRange(section: 0, 0..<5)))
    }

    func testSelectingInACellReportsItsExactRangeAndTextAndClearsTheOtherCells() async throws {
        let section = try TableCoverage.section("<p>Before</p><table border='1'><tr><td>Alpha \u{1F600} one</td><td>Beta two</td></tr><tr><td>Gamma three</td><td>Delta four</td></tr></table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let host = try await host(section)
        defer { host.close() }
        let cells = mounted(host)
        XCTAssertEqual(cells.map { $0.cell.cellText.string }, ["Alpha \u{1F600} one", "Beta two", "Gamma three", "Delta four"])
        let alpha = cells[0].cell, delta = cells[3].cell
        alpha.cellSelection = (alpha.cellText.string as NSString).range(of: "\u{1F600} one")
        notifySelectionChanged(alpha)
        let first = try XCTUnwrap(host.canvas.currentSelection)
        XCTAssertEqual(first.text, "\u{1F600} one")
        XCTAssertEqual(first.range.start, try TableCoverage.position(in: table, cell: "Alpha \u{1F600} one", offset: 6))
        XCTAssertEqual(first.range.end, try TableCoverage.position(in: table, cell: "Alpha \u{1F600} one", offset: 12))
        XCTAssertEqual(section.tablePassage(first.range), first.text, "the range names exactly the selected characters")
        // A selection in another cell replaces it.
        delta.cellSelection = NSRange(location: 0, length: 5)
        notifySelectionChanged(delta)
        XCTAssertEqual(host.canvas.currentSelection?.text, "Delta")
        XCTAssertEqual(host.canvas.currentSelection?.range.start, try TableCoverage.position(in: table, cell: "Delta four", offset: 0))
        XCTAssertEqual(alpha.cellSelection.length, 0, "one selection at a time")
        XCTAssertEqual(host.canvas.textViews.first?.tableInteraction?.selectedText(), "Delta")
        try await host.settle(300)
        XCTAssertEqual(host.recorder.selections.last.flatMap { $0 }?.text, "Delta", "the host hears of the selection once it settles")
        // Emptying it clears the reader's selection.
        let reports = host.recorder.selections.count
        delta.cellSelection = NSRange(location: 2, length: 0)
        notifySelectionChanged(delta)
        XCTAssertNil(host.canvas.currentSelection)
        try await host.settle(300)
        XCTAssertGreaterThan(host.recorder.selections.count, reports)
        XCTAssertNil(host.recorder.selections.last.flatMap { $0 }, "and that it ended")
    }

    func testAPointInACellSurfaceIsThatCellsCharacterAndAPointBetweenCellsIsNone() async throws {
        let section = try TableCoverage.section("<table border='1' cellpadding='12' cellspacing='12'><tr><td>Alpha one</td><td>Beta two</td></tr><tr><td>Gamma three</td><td>Delta four</td></tr></table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let host = try await host(section)
        defer { host.close() }
        let view = try XCTUnwrap(host.canvas.textViews.first), interaction = try XCTUnwrap(view.tableInteraction)
        let cells = mounted(host)
        XCTAssertEqual(cells.count, 4)
        for (index, entry) in cells.enumerated() {
            let frame = entry.cell.frame
            let position = try XCTUnwrap(interaction.selectionPosition(at: CGPoint(x: frame.minX + 1, y: frame.midY)), "cell \(index)")
            XCTAssertEqual(position.tableCell?.table, table.sourceOrder)
            XCTAssertEqual(position.tableCell?.cell, index)
            XCTAssertEqual(position.tableCell?.offset, 0, "its left edge is before its first character")
            XCTAssertEqual(position.offset, try TableCoverage.offset(ofRow: index / 2, in: table))
            let end = try XCTUnwrap(interaction.selectionPosition(at: CGPoint(x: frame.maxX - 0.5, y: frame.midY)))
            XCTAssertEqual(end.tableCell?.cell, index)
            XCTAssertGreaterThan(end.tableCell?.offset ?? 0, 0)
            XCTAssertNotNil(section.tableCell(position))
            // The canvas resolves the same point to the same cell.
            XCTAssertEqual(host.canvas.selectionPosition(at: view.convert(CGPoint(x: frame.minX + 1, y: frame.midY), to: host.canvas)), position)
        }
        // In the spacing between two cells, and in a cell's padding, there is no surface.
        let gap = CGPoint(x: (cells[0].cell.frame.maxX + cells[1].cell.frame.minX) / 2, y: cells[0].cell.frame.midY)
        XCTAssertNil(interaction.selectionPosition(at: gap))
        XCTAssertNil(interaction.selectionPosition(at: CGPoint(x: cells[0].cell.frame.minX - 6, y: cells[0].cell.frame.midY)))
        XCTAssertNil(interaction.selectionPosition(at: CGPoint(x: -500, y: -500)))
    }

    func testALinkInACellIsReportedWithItsTargetAndItsCellPosition() async throws {
        let section = try TableCoverage.section("""
        <table border='1'><tr><td>Plain</td><td>See <a href="#target">the target</a> and <a href="https://example.com/x">outside</a>.</td></tr></table><p id="target">Target</p>
        """)
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let host = try await host(section)
        defer { host.close() }
        let cell = try XCTUnwrap(mounted(host).first { $0.cell.cellText.string.hasPrefix("See") }?.cell)
        let string = cell.cellText.string as NSString
        for (title, expected) in [("the target", ReaderLink.internal(href: "OPS/one.xhtml#target")), ("outside", ReaderLink.external("https://example.com/x"))] {
            let range = string.range(of: title)
            let frame = glyphFrame(range.location + 2, in: cell)
            let hit = try XCTUnwrap(cell.cellLink(at: CGPoint(x: frame.midX, y: frame.midY)), title)
            XCTAssertEqual(hit.range, range)
            cell.onLink?(hit.url, hit.range)
            let reported = try XCTUnwrap(host.recorder.links.last, title)
            XCTAssertEqual(reported.link, expected, "the session decides what an external link does: \(title)")
            XCTAssertEqual(reported.position, try TableCoverage.position(in: table, cell: "See the target and outside.", offset: range.location))
            XCTAssertFalse(reported.rect.isEmpty)
            XCTAssertTrue(host.canvas.bounds.intersects(reported.rect), "where the link is, for a note's popover")
        }
        XCTAssertEqual(host.recorder.links.count, 2)
        let actions = try XCTUnwrap(host.canvas.textViews.first?.tableInteraction).accessibilityActionsOfEveryRow().map(\.name)
        XCTAssertTrue(actions.contains("Follow Table Link: the target"))
        XCTAssertTrue(actions.contains("Follow Table Link: outside"))
        XCTAssertTrue(actions.contains("Select Table Text: Plain"))
    }

    func testSelectingARangeOfCellsSelectsEachCellsShareOnItsSurface() async throws {
        let section = try TableCoverage.section("<p>Before</p><table border='1'><tr><td>Alpha one</td><td>Beta two</td></tr><tr><td>Gamma three</td><td>Delta four</td></tr></table><p>After</p>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let host = try await host(section)
        defer { host.close() }
        let view = try XCTUnwrap(host.canvas.textViews.first), interaction = try XCTUnwrap(view.tableInteraction)
        let range = ReaderTextRange(start: try TableCoverage.position(in: table, cell: "Alpha one", offset: 6),
                                    end: try TableCoverage.position(in: table, cell: "Gamma three", offset: 5))
        XCTAssertTrue(interaction.select(range, reporting: false))
        let cells = mounted(host).map(\.cell)
        XCTAssertEqual(cells.map(\.cellSelection), [NSRange(location: 6, length: 3), NSRange(location: 0, length: 8), NSRange(location: 0, length: 5), NSRange(location: 0, length: 0)])
        XCTAssertEqual(interaction.selectedText(), "one\tBeta two\tGamma", "as the passage reads: \(section.tablePassage(range) ?? "")")
        XCTAssertEqual(section.tablePassage(range), "one\tBeta two\tGamma")
        XCTAssertFalse(interaction.selectionContinues(range, forward: true), "all of it is on this page")
        XCTAssertEqual(interaction.visibleCharacters(for: range.end), NSRange(location: 0, length: 11))
        XCTAssertNil(interaction.visibleCharacters(for: ReaderTextPosition(section: 0, offset: 3)))
        interaction.clearSelection()
        XCTAssertTrue(cells.allSatisfy { $0.cellSelection.length == 0 })
        // A range of prose only selects nothing in the table.
        XCTAssertFalse(interaction.select(ReaderTextRange(section: 0, 0..<4), reporting: false))
        // A range from the prose through the whole table selects every cell wholly.
        XCTAssertTrue(interaction.select(ReaderTextRange(section: 0, 2..<section.string.length), reporting: false))
        XCTAssertEqual(mounted(host).map { $0.cell.cellSelection.length }, [9, 8, 11, 10])
    }

    func testHighlightsOnCellRangesReachOnlyTheirCells() async throws {
        let section = try TableCoverage.section("<table border='1'><tr><td>Alpha one</td><td>Beta two</td></tr><tr><td>Gamma three</td><td>Delta four</td></tr></table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        let host = try await host(section)
        defer { host.close() }
        let interaction = try XCTUnwrap(host.canvas.textViews.first?.tableInteraction)
        let range = ReaderTextRange(start: try TableCoverage.position(in: table, cell: "Beta two", offset: 5),
                                    end: try TableCoverage.position(in: table, cell: "Gamma three", offset: 5))
        interaction.highlights([ReaderHighlight(id: "h", range: range, kind: .annotation)])
        func highlighted(_ cell: TableCellTextView) -> [Int] {
            let storage: NSTextStorage? = cell.textStorage
            return (0..<cell.cellText.length).filter { storage?.attribute(.backgroundColor, at: $0, effectiveRange: nil) != nil }
        }
        let cells = mounted(host).map(\.cell)
        XCTAssertEqual(highlighted(cells[0]), [])
        XCTAssertEqual(highlighted(cells[1]), [5, 6, 7])
        XCTAssertEqual(highlighted(cells[2]), [0, 1, 2, 3, 4])
        XCTAssertEqual(highlighted(cells[3]), [])
        interaction.highlights([])
        XCTAssertTrue(cells.allSatisfy { highlighted($0).isEmpty })
    }

    func testContinuousScrollMountsSurfacesForTheVisibleRowsOfALongTableOnly() async throws {
        let rows = (0..<300).map { "<tr><td>Row \($0)</td><td>Value \($0)</td></tr>" }.joined()
        let section = try TableCoverage.section("<table border='1'>\(rows)</table>")
        let table = try XCTUnwrap(TableCoverage.tables(in: section.string).first)
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        let host = try await host(section, configuration: configuration)
        defer { host.close() }
        let top = mounted(host)
        XCTAssertGreaterThan(top.count, 4)
        XCTAssertLessThan(top.count, 120, "the rows on screen, not the table's 600 cells")
        XCTAssertTrue(top.contains { $0.cell.cellText.string == "Row 0" })
        // Far down the table other rows are mounted, and the first ones are released.
        host.canvas.show(ReaderTextPosition(section: 0, offset: try TableCoverage.offset(ofRow: 200, in: table)), selecting: nil)
        try await settle(host) { cells in cells.contains { $0.cell.cellText.string == "Row 200" } && !cells.contains { $0.cell.cellText.string == "Row 0" } }
        let lower = mounted(host)
        XCTAssertTrue(lower.contains { $0.cell.cellText.string == "Row 200" })
        XCTAssertFalse(lower.contains { $0.cell.cellText.string == "Row 0" })
        XCTAssertLessThan(lower.count, 120)
        XCTAssertTrue(top.filter { $0.cell.cellText.string == "Row 0" }.allSatisfy { $0.cell.superview == nil })
        // A precise cell position there has a frame on screen.
        let anchor = try TableCoverage.position(in: table, cell: "Value 200", offset: 3)
        let frame = try XCTUnwrap(host.canvas.tableAnchorFrame(for: anchor))
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertNil(host.canvas.tableAnchorFrame(for: ReaderTextPosition(section: 0, offset: 0)), "not a cell position")
        XCTAssertNil(host.canvas.tableAnchorFrame(for: ReaderTextPosition(section: 0, offset: 0, tableCell: ReaderTablePosition(table: table.sourceOrder + 3, cell: 0, offset: 0))))
        XCTAssertNil(host.canvas.tableAnchorFrame(for: ReaderTextPosition(section: 0, offset: 0, tableCell: ReaderTablePosition(table: table.sourceOrder, cell: 9_999, offset: 0))))
    }
}
