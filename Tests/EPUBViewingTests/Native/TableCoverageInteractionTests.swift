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
        XCTAssertEqual(element.accessibilityRole(), .staticText)
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
