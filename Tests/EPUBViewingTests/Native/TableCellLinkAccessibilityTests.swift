#if os(macOS)
import AppKit
import XCTest
@testable import EPUBViewing

/// A link in a table cell on the Mac as an assistive client is given it (doc/native-viewer.md,
/// "Links for VoiceOver on Mac"). A cell is a text view of its own, and its links are the
/// reader's elements, as those of the text around the table are: named by what they say, with
/// a place and a press. API level only: what VoiceOver says of them is recorded in
/// doc/voiceover-testing.md.
@MainActor final class TableCellLinkAccessibilityTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private static let css = ".parked { position: absolute; left: -999em; } td { padding: 4px 8px; } img { width: 32px; height: 32px; }"

    /// The table of the VoiceOver fixture's sixth section (`scripts/make-voiceover-fixture.py`),
    /// between two paragraphs that have a link each.
    private static let grid = """
        <p>Shown <a href="one.xhtml#before">words before</a> the grid.</p><table>\
        <tr><td>Plain first entry.</td><td>Before the <a href="two.xhtml#t">worded jump</a> after it, and then enough \
        further words to carry this entry on to another line.</td></tr>\
        <tr><td>Described: <a href="two.xhtml#t"><img src="p.png" alt="Described entry jump"/></a></td>\
        <td>Bare: <a href="two.xhtml#t"><img src="p.png" alt=""/></a></td></tr>\
        <tr><td><a href="two.xhtml#t"><img src="p.png" alt=""/> Entry jump with decoration</a></td>\
        <td><a class="parked" href="two.xhtml#t">Parked entry jump</a>Shown last entry.</td></tr>\
        </table><p>Shown <a href="one.xhtml#after">words after</a> the grid.</p>
        """

    private struct Mounted {
        var host: CanvasHost
        var view: ReaderTextView
        var table: TableModel
        var cells: [(key: ReaderTableInteraction.Key, cell: TableCellTextView)]
    }

    /// A page holding `body`, laid out until the surfaces of `count` cells are mounted.
    private func mount(_ body: String, cells count: Int, configuration: ReaderCanvasConfiguration = .init()) async throws -> Mounted {
        let section = try TableCoverage.section(body, css: Self.css, files: ["p.png": RichFixture.image(width: 64, height: 64)])
        let host = CanvasHost(FakeCanvasSource([section.string]), size: CGSize(width: 600, height: 700), configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        var cells: [(key: ReaderTableInteraction.Key, cell: TableCellTextView)] = []
        for _ in 0..<100 where cells.count != count {
            host.layOut()
            try await host.settle(50)
            for view in host.canvas.textViews { view.refreshTableInteractions() }
            cells = (host.canvas.textViews.first?.tableInteraction?.cells ?? [:]).map { (key: $0.key, cell: $0.value) }
                .sorted { ($0.key.location, $0.key.cell, $0.key.lower) < ($1.key.location, $1.key.cell, $1.key.lower) }
        }
        XCTAssertEqual(cells.count, count)
        return Mounted(host: host, view: try XCTUnwrap(host.canvas.textViews.first),
                       table: try XCTUnwrap(TableCoverage.tables(in: section.string).first), cells: cells)
    }

    /// All the characters a cell gives: every range of a cell counts from the first it shows.
    private func whole(_ cell: TableCellTextView) -> NSRange { NSRange(location: 0, length: cell.accessibilityNumberOfCharacters()) }

    /// The link elements of a cell's accessibility string, each with its characters.
    private func links(in cell: TableCellTextView, file: StaticString = #filePath, line: UInt = #line) throws
        -> [(element: ReaderLinkAccessibilityElement, range: NSRange)] {
        let rich = try XCTUnwrap(cell.accessibilityAttributedString(for: whole(cell)), file: file, line: line)
        XCTAssertEqual(rich.string, cell.accessibilityValue(), "the characters are the cell's own", file: file, line: line)
        XCTAssertEqual(rich.string, cell.accessibilityString(for: whole(cell)), file: file, line: line)
        var found: [(ReaderLinkAccessibilityElement, NSRange)] = []
        rich.enumerateAttribute(.accessibilityLink, in: NSRange(location: 0, length: rich.length)) { value, run, _ in
            guard let value else { return }
            guard let element = value as? ReaderLinkAccessibilityElement else {
                return XCTFail("a link AppKit made, which names an attachment by its character: \(value)", file: file, line: line)
            }
            found.append((element, run))
        }
        return found
    }

    private func children(of view: NSView) -> [ReaderLinkAccessibilityElement] {
        (view.accessibilityChildren() ?? []).compactMap { $0 as? ReaderLinkAccessibilityElement }
    }

    /// The element given as the attachment of the cell's character at `location`.
    private func attachment(at location: Int, in cell: TableCellTextView) throws -> NSAccessibilityElement? {
        let rich = try XCTUnwrap(cell.accessibilityAttributedString(for: whole(cell)))
        return rich.attribute(.accessibilityAttachment, at: location, effectiveRange: nil) as? NSAccessibilityElement
    }

    private var imageWord: String { NSAccessibility.Role.image.description(with: nil) ?? "" }

    func testACellsLinksAreNamedByWhatTheySayAndNeverByAnAttachmentsCharacter() async throws {
        let cells = try await mount(Self.grid, cells: 6).cells.map(\.cell)
        XCTAssertEqual(cells.map { $0.accessibilityValue() ?? "" },
                       ["Plain first entry.", "Before the worded jump after it, and then enough further words to carry this entry on to another line.",
                        "Described: \u{FFFC}", "Bare: \u{FFFC}", "\u{FFFC} Entry jump with decoration", "\u{FFFC}Shown last entry."],
                       "an attachment stays one character, so every range matches the cell's text")
        let found = try cells.map { try links(in: $0) }
        XCTAssertEqual(found.map { $0.map(\.range) },
                       [[], [NSRange(location: 11, length: 11)], [NSRange(location: 11, length: 1)], [NSRange(location: 6, length: 1)],
                        [NSRange(location: 0, length: 28)], [NSRange(location: 0, length: 1)]])
        XCTAssertFalse(imageWord.isEmpty)
        XCTAssertEqual(found.map { $0.map { $0.element.accessibilityTitle() ?? "" } },
                       [[], ["worded jump"], ["Described entry jump, \(imageWord)"], [imageWord], ["Entry jump with decoration"], ["Parked entry jump"]],
                       "never U+FFFC; a link that holds pictures and nothing else says that it is a picture")
        for (cell, links) in zip(cells, found) {
            // Find Next Link moves through the cell's children: the same elements, and none of AppKit's.
            XCTAssertEqual(children(of: cell).map { ObjectIdentifier($0) }, links.map { ObjectIdentifier($0.element) })
            XCTAssertEqual(cell.accessibilityChildren()?.count, links.count)
            for (link, range) in links {
                XCTAssertEqual(link.accessibilityRole(), .link)
                XCTAssertEqual(link.accessibilitySubrole(), .textLink, "the role AppKit gives a link in text, which VoiceOver calls a hyperlink")
                XCTAssertTrue(link.accessibilityParent() as AnyObject === cell)
                XCTAssertNil(link.accessibilityURL(), "the target is in a scheme of the reader's own, which nothing can open")
                // Asked for a part of the link, as a word or a line is, the cell gives the same element.
                let part = try XCTUnwrap(cell.accessibilityAttributedString(for: NSRange(location: NSMaxRange(range) - 1, length: 1)))
                XCTAssertTrue(part.attribute(.accessibilityLink, at: 0, effectiveRange: nil) as AnyObject === link)
            }
        }
    }

    /// VoiceOver announces an element given as a character's attachment as it reads, and none
    /// at a character of words: a cell's link is announced at its attachments, as the text's is.
    func testAnAttachmentInACellsLinkIsALinkWhereVoiceOverReadsIt() async throws {
        let mounted = try await mount(Self.grid, cells: 6)
        let cells = mounted.cells.map(\.cell)
        // A picture that is all its link holds is the link's own element. A press follows the
        // link, so inspecting the picture stays an action.
        let described = try XCTUnwrap(links(in: cells[2]).first?.element)
        XCTAssertTrue(try attachment(at: 11, in: cells[2]) === described)
        XCTAssertEqual(described.accessibilityCustomActions()?.map(\.name), ["Inspect Image: Described entry jump"])
        XCTAssertTrue(try XCTUnwrap(described.accessibilityCustomActions()?.first).handler?() ?? false)
        XCTAssertNotNil(mounted.host.canvas.imageInspector)
        mounted.host.canvas.imageInspector?.close()
        // Decoration that is all its link holds is the link, a picture without a name.
        let bare = try XCTUnwrap(links(in: cells[3]).first?.element)
        XCTAssertTrue(try attachment(at: 6, in: cells[3]) === bare)
        XCTAssertEqual(bare.accessibilityCustomActions()?.map(\.name), ["Inspect Image"])
        // Decoration that opens a link of words says "hyperlink" before them, and no name.
        let worded = try XCTUnwrap(links(in: cells[4]).first?.element)
        let opening = try XCTUnwrap(attachment(at: 0, in: cells[4]) as? ReaderLinkAccessibilityElement)
        XCTAssertFalse(opening === worded)
        XCTAssertEqual(opening.accessibilityRole(), .link)
        XCTAssertNil(opening.accessibilityTitle())
        XCTAssertEqual(opening.accessibilityCustomActions()?.count ?? 0, 0)
        XCTAssertEqual(opening.range, NSRange(location: 0, length: 1))
        XCTAssertNil(try attachment(at: 3, in: cells[4]), "the words are read as words")
        XCTAssertNil(try attachment(at: 12, in: cells[1]), "and so is a link of words alone")
        // A hidden label that is a link is the link, where a static text stood for its words.
        let parked = try XCTUnwrap(links(in: cells[5]).first?.element)
        XCTAssertTrue(try attachment(at: 0, in: cells[5]) === parked)
        // The elements are kept: VoiceOver asks one what it is after the string is returned.
        XCTAssertTrue(try links(in: cells[5]).first?.element === parked)
        XCTAssertTrue(try attachment(at: 0, in: cells[4]) === opening)
    }

    func testACellsLinkHasAPlaceInItsCellAndItsPressFollowsItFromThatCell() async throws {
        let mounted = try await mount(Self.grid, cells: 6)
        var pressed = 0
        for (key, cell) in mounted.cells {
            for (link, range) in try links(in: cell) {
                let title = link.accessibilityTitle() ?? ""
                // Its place is its characters', where VoiceOver's cursor is drawn. A hidden
                // label takes no room: without a place of some size VoiceOver cannot move to it.
                let place = link.accessibilityFrame(), characters = cell.accessibilityFrame(for: range)
                XCTAssertGreaterThanOrEqual(place.width, 1, title)
                XCTAssertGreaterThanOrEqual(place.height, 1, title)
                XCTAssertTrue(cell.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(place), "\(title): \(place) in \(cell.accessibilityFrame())")
                XCTAssertEqual(place.minX, characters.minX, accuracy: 1, title)
                XCTAssertEqual(place.width, max(characters.width, 1), accuracy: 1, title)
                XCTAssertEqual(place.midY, characters.midY, accuracy: 1, title)
                // Control-Option-Space presses it: the reader hears of the link and of where in
                // its cell it stands, as for a click.
                XCTAssertTrue(link.accessibilityPerformPress(), title)
                pressed += 1
                let reported = try XCTUnwrap(mounted.host.recorder.links.last, title)
                XCTAssertEqual(mounted.host.recorder.links.count, pressed, title)
                XCTAssertEqual(reported.link, .internal(href: "OPS/two.xhtml#t"), title)
                XCTAssertEqual(reported.position, ReaderTextPosition(
                    section: 0, offset: try TableCoverage.offset(ofRow: mounted.table.cells[key.cell].row, in: mounted.table),
                    tableCell: ReaderTablePosition(table: mounted.table.sourceOrder, cell: key.cell, offset: range.location)), title)
            }
        }
        XCTAssertEqual(pressed, 5)
    }

    func testAPageListsTheLinksOfItsCellsAmongItsOwnInReadingOrder() async throws {
        let mounted = try await mount(Self.grid, cells: 6)
        // Find Next Link moves through the children of the text VoiceOver is in. A row is one
        // character of the page's text, so the page lists its cells' links where the row stands.
        let listed = children(of: mounted.view)
        XCTAssertEqual(listed.map { $0.accessibilityTitle() ?? "" },
                       ["words before", "worded jump", "Described entry jump, \(imageWord)", imageWord, "Entry jump with decoration",
                        "Parked entry jump", "words after"])
        XCTAssertEqual(mounted.view.accessibilityChildren()?.count, 7, "the cells themselves are reached through their rows")
        // From a link VoiceOver goes on through the children of the link's own parent: each of
        // these is a child of the page, and another element than the cell's own.
        let inCells = try mounted.cells.flatMap { entry in try links(in: entry.cell).map { (cell: entry.cell, key: entry.key, link: $0.element, range: $0.range) } }
        XCTAssertEqual(inCells.count, 5)
        for (page, own) in zip(listed[1...5], inCells) {
            let title = page.accessibilityTitle() ?? ""
            XCTAssertTrue(page.accessibilityParent() as AnyObject === mounted.view, title)
            XCTAssertTrue(own.link.accessibilityParent() as AnyObject === own.cell, title)
            XCTAssertFalse(page === own.link, title)
            XCTAssertEqual(page.accessibilityRole(), .link, title)
            XCTAssertEqual(page.accessibilitySubrole(), .textLink, title)
            XCTAssertEqual(page.accessibilityTitle(), own.link.accessibilityTitle())
            XCTAssertEqual(page.accessibilityCustomActions()?.map(\.name), own.link.accessibilityCustomActions()?.map(\.name), title)
            // The same place on screen, and in the page's own coordinates as its child.
            XCTAssertEqual(page.accessibilityFrame(), own.link.accessibilityFrame(), title)
            XCTAssertEqual(NSAccessibility.screenRect(fromView: mounted.view, rect: page.accessibilityFrameInParentSpace()).midX,
                           page.accessibilityFrame().midX, accuracy: 1, title)
            XCTAssertEqual(NSAccessibility.screenRect(fromView: mounted.view, rect: page.accessibilityFrameInParentSpace()).midY,
                           page.accessibilityFrame().midY, accuracy: 1, title)
            XCTAssertTrue(mounted.view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(page.accessibilityFrame()), title)
            // The same press: the link is followed from its cell.
            XCTAssertTrue(page.accessibilityPerformPress(), title)
            XCTAssertEqual(mounted.host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml#t"), title)
            XCTAssertEqual(mounted.host.recorder.links.last?.position.tableCell,
                           ReaderTablePosition(table: mounted.table.sourceOrder, cell: own.key.cell, offset: own.range.location), title)
        }
        // Asked again, the page gives the same elements.
        XCTAssertEqual(children(of: mounted.view).map { ObjectIdentifier($0) }, listed.map { ObjectIdentifier($0) })
        // The page's own string has none of them: a row is one character, the group of its cells.
        let text = try XCTUnwrap(mounted.view.accessibilityAttributedString(for: mounted.view.shownCharacters))
        var own: [String] = []
        text.enumerateAttribute(.accessibilityLink, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let link = value as? ReaderLinkAccessibilityElement { own.append(link.accessibilityTitle() ?? "") }
        }
        XCTAssertEqual(own, ["words before", "words after"])
        // The page's own links press as they did.
        XCTAssertTrue(listed[0].accessibilityPerformPress())
        XCTAssertEqual(mounted.host.recorder.links.last?.link, .internal(href: "OPS/one.xhtml#before"))
        XCTAssertNil(mounted.host.recorder.links.last?.position.tableCell)
    }

    func testContinuousScrollListsTheLinksOfTheCellsOnScreenAsAPageDoes() async throws {
        let mounted = try await mount(Self.grid, cells: 6, configuration: .init(flow: .scrolled))
        XCTAssertTrue(mounted.view === mounted.host.canvas.scrollTextView)
        let listed = children(of: mounted.view)
        XCTAssertEqual(listed.map { $0.accessibilityTitle() ?? "" },
                       ["words before", "worded jump", "Described entry jump, \(imageWord)", imageWord, "Entry jump with decoration",
                        "Parked entry jump", "words after"])
        XCTAssertTrue(listed.allSatisfy { $0.accessibilityParent() as AnyObject === mounted.view })
        for link in listed {
            XCTAssertTrue(mounted.view.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(link.accessibilityFrame()), link.accessibilityTitle() ?? "")
        }
        // Inside its cell a link is the cell's own, as in pages.
        let parked = try XCTUnwrap(links(in: try XCTUnwrap(mounted.cells.last?.cell)).first?.element)
        XCTAssertEqual(parked.accessibilityTitle(), "Parked entry jump")
        XCTAssertTrue(parked.accessibilityPerformPress())
        XCTAssertEqual(mounted.host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml#t"))
        XCTAssertTrue(listed[5].accessibilityPerformPress())
        XCTAssertEqual(mounted.host.recorder.links.count, 2)
        XCTAssertEqual(mounted.host.recorder.links.last?.position, mounted.host.recorder.links.first?.position, "the same link from the page")
    }

    private func titles(of view: NSView) -> [String] { children(of: view).map { $0.accessibilityTitle() ?? "" } }

    /// The cells standing in `view`, in reading order.
    private func cells(of view: ReaderTextView) -> [(key: ReaderTableInteraction.Key, cell: TableCellTextView)] {
        (view.tableInteraction?.cells ?? [:]).map { (key: $0.key, cell: $0.value) }
            .sorted { ($0.key.location, $0.key.cell, $0.key.lower) < ($1.key.location, $1.key.cell, $1.key.lower) }
    }

    /// VoiceOver focuses the element it moves to. A cell's link on screen is left as it is,
    /// the one the page lists and the cell's own: told that an insertion point has moved,
    /// VoiceOver says the word beside it over the link's name (`LinkAccessibilityTests`).
    func testACellsLinkOnScreenTakesTheFocusAndIsLeftAsItIs() async throws {
        let mounted = try await mount(Self.grid, cells: 6)
        let listed = children(of: mounted.view)
        guard listed.count == 7 else { return XCTFail("\(listed.count) links") }
        let cell = mounted.cells[1].cell
        let own = try XCTUnwrap(links(in: cell).first)
        XCTAssertEqual(own.element.accessibilityTitle(), "worded jump")
        let shown = mounted.host.recorder.shown.count, inCell = cell.accessibilitySelectedTextRange()
        for link in listed + [own.element] {
            XCTAssertFalse(link.isAccessibilityFocused(), link.accessibilityTitle() ?? "")
            link.setAccessibilityFocused(true)
            XCTAssertEqual(mounted.view.selectedRange, NSRange(location: 0, length: 0), link.accessibilityTitle() ?? "")
        }
        XCTAssertEqual(cell.accessibilitySelectedTextRange(), inCell)
        XCTAssertEqual(mounted.host.recorder.shown.count, shown)
        // A link the page lists stands at its cell's row, one character of the page's text.
        let rows = Array(Set(mounted.cells.map(\.key.location))).sorted()
        XCTAssertEqual(rows.count, 3)
        mounted.view.setAccessibilitySelectedTextRange(NSRange(location: rows[1], length: 0))
        XCTAssertEqual(listed.map { $0.isAccessibilityFocused() }, [false, false, true, true, false, false, false], "both links of the second row")
        XCTAssertFalse(own.element.isAccessibilityFocused(), "the cell's own element has none: VoiceOver is inside the cell there")
        // The presses are what they were.
        XCTAssertTrue(listed[1].accessibilityPerformPress())
        XCTAssertTrue(own.element.accessibilityPerformPress())
        XCTAssertEqual(mounted.host.recorder.links.count, 2)
        XCTAssertEqual(mounted.host.recorder.links.last?.position, mounted.host.recorder.links.first?.position)
    }

    /// In continuous scroll the text's children end with the book's next link after the
    /// screen (`LinkAccessibilityTests`). A row below the screen has no cells, and a cell's
    /// link is its cell's element: where the next link is in a row, that row keeps its cells
    /// while it is below the screen, and its links are the next ones.
    func testContinuousScrollGivesTheLinksOfTheNextRowBelowTheScreenWhichKeepsItsCells() async throws {
        let filler = (0..<12).map { "<p>\(CanvasText.sentence(60, seed: $0))</p>" }.joined()
        let body = "<p>Shown <a href=\"one.xhtml#before\">words before</a> the grid.</p>\(filler)<table>"
            + "<tr><td>No jump here.</td><td>Nor in this entry.</td></tr>"
            + "<tr><td>Plain first entry.</td><td>Before the <a href=\"two.xhtml#t\">worded jump</a> after it.</td></tr>"
            + "<tr><td>Described: <a href=\"two.xhtml#t\"><img src=\"p.png\" alt=\"Described entry jump\"/></a></td><td>Plain last entry.</td></tr>"
            + "</table>\(filler)<p>Shown <a href=\"one.xhtml#after\">words after</a> the grid.</p>"
        let mounted = try await mount(body, cells: 0, configuration: .init(flow: .scrolled))
        let view = mounted.view
        XCTAssertNil(view.tableInteraction?.keptRow, "nothing is kept until an assistive client asks")
        // The first link on screen, and the next one: in the table's second row. The first
        // row has no link and no cells.
        XCTAssertEqual(titles(of: view), ["words before", "worded jump"])
        let kept = cells(of: view)
        XCTAssertEqual(kept.count, 2, "the cells of the row that holds the next link")
        let row = try XCTUnwrap(kept.first?.key.location)
        XCTAssertEqual(view.tableInteraction?.keptRow, row)
        XCTAssertTrue(kept.allSatisfy { $0.key.location == row })
        XCTAssertGreaterThanOrEqual(row, NSMaxRange(view.accessibilityVisibleCharacterRange()), "below the screen")
        let below = try XCTUnwrap(children(of: view).last)
        XCTAssertTrue(below.accessibilityParent() as AnyObject === view)
        XCTAssertGreaterThan(below.accessibilityFrameInParentSpace().minY, view.visibleRect.maxY, "its place is where it stands")
        XCTAssertGreaterThanOrEqual(below.accessibilityFrameInParentSpace().width, 1)
        XCTAssertTrue(children(of: view).last === below, "kept from one read to the next")
        XCTAssertEqual(cells(of: view).map { ObjectIdentifier($0.cell) }, kept.map { ObjectIdentifier($0.cell) })
        // The reader's own layout keeps the row's cells.
        mounted.host.layOut()
        view.refreshTableInteractions()
        XCTAssertEqual(cells(of: view).map { ObjectIdentifier($0.cell) }, kept.map { ObjectIdentifier($0.cell) })
        // Its press follows the link from its cell.
        XCTAssertTrue(below.accessibilityPerformPress())
        XCTAssertEqual(mounted.host.recorder.links.last?.link, .internal(href: "OPS/two.xhtml#t"))
        XCTAssertNotNil(mounted.host.recorder.links.last?.position.tableCell)
        // VoiceOver moves to it: the reader shows its row, with the insertion point on the row.
        let shown = mounted.host.recorder.shown.count
        below.setAccessibilityFocused(true)
        mounted.host.layOut()
        view.refreshTableInteractions()
        XCTAssertEqual(mounted.host.recorder.shown.count, shown + 1, "the reader showed the row")
        XCTAssertEqual(view.selectedRange, NSRange(location: row, length: 0))
        XCTAssertTrue(below.isAccessibilityFocused())
        XCTAssertTrue(below.accessibilityFrameInParentSpace().intersects(view.visibleRect), "on screen now")
        // The same element, with the next row's link beside it, and the next link below.
        XCTAssertEqual(titles(of: view), ["worded jump", "Described entry jump, \(imageWord)", "words after"])
        XCTAssertTrue(children(of: view).first === below, "the element VoiceOver is on is still the link's")
        XCTAssertNil(view.tableInteraction?.keptRow, "the next link is the text's own")
        // A link of the text's own that comes before the next row with one is the next.
        let early = try await mount("<p>Shown <a href=\"one.xhtml#before\">words before</a>.</p>\(filler)<p>An <a href=\"one.xhtml#mid\">early jump</a>.</p>"
            + "<table><tr><td>Entry</td><td>A <a href=\"two.xhtml#t\">worded jump</a>.</td></tr></table>\(filler)", cells: 0, configuration: .init(flow: .scrolled))
        XCTAssertEqual(titles(of: early.view), ["words before", "early jump"])
        XCTAssertNil(early.view.tableInteraction?.keptRow)
        XCTAssertTrue(cells(of: early.view).isEmpty)
    }

    private func surface(_ text: NSAttributedString, showing shown: NSRange? = nil) -> TableCellTextView {
        let cell = TableCellTextView(text: text, width: 400, characters: shown ?? NSRange(location: 0, length: text.length))
        cell.configure(frame: CGRect(x: 0, y: 0, width: 400, height: 200), scale: 1, textOffset: .zero, actionTitle: nil)
        return cell
    }

    /// A row that goes on over a page's end is shown in parts, each a cell surface over the
    /// lines on its page.
    func testACellThatShowsLaterLinesGivesTheLinksOfThoseLinesFromItsFirstShownCharacter() throws {
        let text = NSMutableAttributedString(attributedString: CanvasText.body(
            "Hidden line with a first jump, and then a crossing\njump goes on here before a second jump.\nLast shown line."))
        let string = text.string as NSString
        let first = string.range(of: "first jump"), crossing = string.range(of: "a crossing\njump goes"), second = string.range(of: "second jump")
        for (name, range) in [("a", first), ("b", crossing), ("c", second)] {
            text.addAttribute(.link, value: ReaderLink.internal(href: "OPS/\(name).xhtml").url, range: range)
        }
        let shown = NSRange(location: string.range(of: "jump goes").location, length: text.length - string.range(of: "jump goes").location)
        let cell = surface(text, showing: shown)
        var followed: [(url: URL, range: NSRange)] = []
        cell.onLink = { followed.append(($0, $1)) }
        let found = try links(in: cell)
        XCTAssertEqual(found.map(\.range), [NSRange(location: 0, length: 9), NSRange(location: second.location - shown.location, length: second.length)],
                       "the link above the shown lines is not given, and one that crosses into them is the part shown")
        XCTAssertEqual(found.map { $0.element.accessibilityTitle() ?? "" }, ["jump goes", "second jump"], "the words on this page")
        XCTAssertEqual(found.map(\.element.range), [NSRange(location: shown.location, length: 9), second], "an element keeps its place in the cell's whole text")
        XCTAssertEqual(children(of: cell).map { ObjectIdentifier($0) }, found.map { ObjectIdentifier($0.element) })
        XCTAssertTrue(found[0].element.accessibilityPerformPress())
        XCTAssertEqual(followed.last.flatMap { ReaderLink(url: $0.url) }, .internal(href: "OPS/b.xhtml"))
        XCTAssertEqual(followed.last?.range, NSRange(location: shown.location, length: 9))
        // Past the shown lines the cell gives nothing, as before.
        XCTAssertNil(cell.accessibilityAttributedString(for: NSRange(location: 0, length: shown.length + 1)))
        // A cell nothing follows links for, as in a test, has links that do nothing.
        cell.onLink = nil
        XCTAssertFalse(found[1].element.accessibilityPerformPress())
    }

    func testAFormulaInACellsLinkIsALinkByItsReadingAndOneOutsideALinkIsNoLink() throws {
        func formula(_ reading: String) -> NSAttributedString {
            let attachment = TextualTestAttachment()
            attachment.textEquivalent = reading
            return NSAttributedString(attachment: attachment)
        }
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Follow "))
        text.append(formula("E = mc²"))
        text.append(CanvasText.body(" now and read "))
        text.append(formula("x squared"))
        text.append(CanvasText.body(" on."))
        text.addAttribute(.link, value: ReaderLink.internal(href: "OPS/two.xhtml").url, range: NSRange(location: 0, length: 12))
        let cell = surface(text)
        let found = try links(in: cell)
        XCTAssertEqual(found.map(\.range), [NSRange(location: 0, length: 12)])
        XCTAssertEqual(found.first?.element.accessibilityTitle(), "Follow E = mc² now")
        let reading = try XCTUnwrap(attachment(at: 7, in: cell) as? ReaderLinkAccessibilityElement)
        XCTAssertEqual(reading.accessibilityTitle(), "E = mc²", "no picture: a formula is its reading")
        XCTAssertFalse(reading === found.first?.element)
        // What is not in a link is what it is in the text around the table, and no link.
        let unlinked = try XCTUnwrap(attachment(at: 22, in: cell))
        XCTAssertFalse(unlinked is ReaderLinkAccessibilityElement)
        XCTAssertEqual(unlinked.accessibilityRole(), .image)
        XCTAssertEqual(unlinked.accessibilityLabel(), "x squared")
    }

    func testDecorationAfterTheFirstCharacterOfACellsLinkIsPassedOver() async throws {
        let mounted = try await mount("""
            <table><tr><td>Plain entry.</td><td><a href="two.xhtml">Words then <img src="p.png" alt=""/> more \
            <img src="p.png" alt="a picture"/></a> and <img src="p.png" alt=""/> outside.</td></tr></table>
            """, cells: 2)
        let cell = try XCTUnwrap(mounted.cells.last?.cell)
        let value = try XCTUnwrap(cell.accessibilityValue()) as NSString
        let found = try links(in: cell)
        XCTAssertEqual(found.map { $0.element.accessibilityTitle() ?? "" }, ["Words then more a picture"], "decoration adds nothing to a name")
        let decoration = value.range(of: "\u{FFFC}"), picture = value.range(of: "\u{FFFC}", range: NSRange(location: decoration.upperBound, length: 12))
        XCTAssertNil(try attachment(at: decoration.location, in: cell), "nothing to announce, as outside a link in the text around the table")
        let outside = value.range(of: "\u{FFFC}", range: NSRange(location: picture.upperBound, length: value.length - picture.upperBound))
        XCTAssertNil(try attachment(at: outside.location, in: cell), "and as decoration outside the link")
        let among = try XCTUnwrap(attachment(at: picture.location, in: cell) as? ReaderLinkAccessibilityElement)
        XCTAssertEqual(among.accessibilityTitle(), "a picture, \(imageWord)", "a picture among a link's words is a link by its own words")
        XCTAssertEqual(among.accessibilityCustomActions()?.map(\.name), ["Inspect Image: a picture"])
    }
}
#endif
