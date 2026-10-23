import EPUBCore
import EPUBReading
import EPUBTestSupport
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class TableInteractionTests: XCTestCase {
    private func chapter(_ body: String) -> String {
        "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head><title>Tables</title></head><body>\(body)</body></html>"
    }
    private let body = """
    <p id='before'>Before table.</p>
    <table id='table' border='1' cellpadding='8'><tr><th>Heading</th><th>References</th></tr>
    <tr><td id='cell'>Alpha   <em>😀 beta</em> gamma.</td><td><a href='#after'>Internal anchor</a><br/>
    <a epub:type='noteref' href='#note'>Footnote</a><br/><a href='https://example.com'>Outside link</a></td></tr>
    <tr><td colspan='2'>Merged cells remain selectable.</td></tr></table>
    <p id='after'>After table.</p><aside id='note' epub:type='footnote'><p>Authored note content.</p></aside>
    """

    private func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for native table interaction"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testPartialCellSelectionCopyActionCFIRoundTripAndRebuild() async throws {
        var performed: EPUBSelection?
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter(body)]))
        let action = EPUBSelectionAction(title: "Annotate", systemImage: "text.quote") { performed = $0 }
        let session = try NativeSession(publication: publication, action: action, rich: NativeRichContent(), onEvent: { _ in })
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { session.isReady && session.canvas?.textViews.first?.tableInteraction?.cells.count ?? 0 > 0 }
        let canvas = try XCTUnwrap(session.canvas), section = try XCTUnwrap(session.book.section(0))
        let view = try XCTUnwrap(canvas.textViews.first)
        let cell = try XCTUnwrap(view.tableInteraction?.cells.values.first { $0.cellText.string.contains("Alpha") })
        let selected = (cell.cellText.string as NSString).range(of: "😀 beta")
        cell.cellSelection = selected
        #if os(macOS)
        cell.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: cell))
        #else
        cell.textViewDidChangeSelection(cell)
        #endif
        canvas.performSelectionAction()
        let captured = try XCTUnwrap(performed)
        XCTAssertEqual(captured.text, "😀 beta")
        XCTAssertEqual(canvas.currentSelection?.range.start.tableCell?.offset, selected.location)
        XCTAssertEqual(canvas.currentSelection?.range.end.tableCell?.offset, selected.upperBound)
        let bookmark = try XCTUnwrap(captured.location.bookmark)
        let target = try XCTUnwrap(SpineCFIs(publication: publication).resolve(bookmark.value))
        let resolved = try XCTUnwrap(EPUBCFI.resolve(localPath: target.localPath, in: section.document))
        XCTAssertEqual(resolved.start.node.text, "😀 beta")
        XCTAssertEqual(resolved.start.offset, 0)
        XCTAssertEqual(resolved.end.node.text, "😀 beta")
        XCTAssertEqual(resolved.end.offset, 7)
        #if os(macOS)
        let pasteboard = NSPasteboard(name: .init("EPUBLibTableInteraction"))
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(cell.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), "😀 beta")
        let image = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/epublib-table-selection.png"))
        #else
        var copied: String?
        cell.copyTextToPasteboard = { copied = $0 }
        cell.copy(nil)
        XCTAssertEqual(copied, "😀 beta")
        #endif
        try await session.send(.setHighlights([EPUBHighlight(id: "selected-cell", location: captured.location)]))
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "selected-cell" }?.range, canvas.currentSelection?.range)
        try await session.send(.style(.init(fontSize: 24, isDark: true, flow: .scrolled)))
        try await wait { session.canvas?.configuration.flow == .scrolled && session.book.section(0)?.string.length == section.string.length }
        try await session.send(.locate(text: "😀 beta", highlight: true))
        try await wait { session.selection?.text == "😀 beta" }
        XCTAssertEqual(session.selection?.range.start.tableCell?.offset, selected.location)
        XCTAssertEqual(session.selection?.range.end.tableCell?.offset, selected.upperBound)
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "selected-cell" }?.range.start.tableCell?.offset, selected.location)
        try await session.send(.restore(captured.location))
        XCTAssertEqual(session.canvas?.anchor?.section, 0)
    }

    func testNativeCellLinksUseExactHitAndSessionPolicy() async throws {
        var events: [EPUBReaderEvent] = []
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter(body)]))
        let session = try NativeSession(publication: publication, action: nil, rich: NativeRichContent()) { events.append($0) }
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { session.isReady && session.canvas?.textViews.first?.tableInteraction?.cells.count ?? 0 > 0 }
        let view = try XCTUnwrap(session.canvas?.textViews.first)
        let cell = try XCTUnwrap(view.tableInteraction?.cells.values.first { $0.cellText.string.contains("Internal anchor") })
        for title in ["Footnote", "Outside link", "Internal anchor"] {
            let range = (cell.cellText.string as NSString).range(of: title)
            #if os(macOS)
            let manager = try XCTUnwrap(cell.layoutManager), container = try XCTUnwrap(cell.textContainer)
            let frame = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let point = CGPoint(x: frame.midX + cell.textContainerOrigin.x, y: frame.midY + cell.textContainerOrigin.y)
            let hit = try XCTUnwrap(cell.cellLink(at: point)); XCTAssertEqual(hit.range, range)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: cell.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            cell.mouseDown(with: event)
            #else
            let url = try XCTUnwrap(cell.cellText.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
            XCTAssertFalse(cell.textView(cell, shouldInteractWith: url, in: range, interaction: .invokeDefaultAction))
            #endif
            try await Task.sleep(for: .milliseconds(100))
            if title == "Outside link" {
                XCTAssertTrue(events.contains { if case .notice(let text) = $0 { return text.contains("outside the book") }; return false })
            } else if title == "Footnote" {
                XCTAssertNotNil(session.canvas?.presentedNote, "noteref opens authored note in place")
            } else {
                let section = try XCTUnwrap(session.book.section(0))
                XCTAssertEqual(session.canvas?.anchor?.offset, section.anchors["after"])
            }
        }
    }

    func testCompleteLineOverlaysFollowMergedCellsAndContinuations() async throws {
        let words = (0..<180).map { "word\($0)" }.joined(separator: " ")
        let fixture = try RichFixture("<table id='t' border='1'><tr><td rowspan='2'>\(words)</td><td>First</td></tr><tr><td>Second</td></tr><tr><td colspan='2'>Merged</td></tr></table>", typography: .init(fontSize: 30))
        let text = try XCTUnwrap(fixture.table("t"))
        let source = FakeCanvasSource([text])
        let host = CanvasHost(source, size: CGSize(width: 360, height: 400))
        defer { host.close() }
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut(); try await host.settle(50)
        var read: [String] = [], turns = 0
        repeat {
            for view in host.canvas.textViews {
                view.refreshTableInteractions()
                let interaction = try XCTUnwrap(view.tableInteraction)
                XCTAssertLessThan(interaction.cells.count, 12, "only native cells in the visible spread are mounted")
                for (_, cell) in interaction.cells.sorted(by: { ($0.key.location, $0.key.cell, $0.key.lower) < ($1.key.location, $1.key.cell, $1.key.lower) }) {
                    XCTAssertGreaterThan(cell.shownCharacters.length, 0)
                    XCTAssertLessThanOrEqual(cell.frame.maxY, view.bounds.maxY + 1)
                    read += cell.cellText.readerPlainText(in: cell.shownCharacters).split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("word") }.map(String.init)
                }
            }
            turns += 1
        } while host.canvas.turnPage(forward: true) == .turned && turns < 50
        XCTAssertGreaterThan(turns, 1)
        XCTAssertEqual(read, (0..<180).map { "word\($0)" })
    }

    func testCellMappingOmitsGeneratedTextAndPreservesOldTableUnitBookmark() throws {
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter(body)]))
        let section = SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: 0,
            typography: .init(), fonts: FontRegistry(publication: publication), rich: NativeRichContent()))
        let element = try XCTUnwrap(section.document.element(id: "cell"))
        let node = try XCTUnwrap(element.children.first { $0.isText })
        let position = section.renderedPosition(DOMPosition(node, 2))
        XCTAssertEqual(position.tableCell?.offset, 2)
        XCTAssertTrue(section.domPosition(position)?.node === node)
        XCTAssertEqual(section.domPosition(position)?.offset, 2)
        let table = try XCTUnwrap(section.document.element(id: "table"))
        XCTAssertNil(section.renderedPosition(DOMPosition(table, 0)).tableCell)
        let endNode = try XCTUnwrap(element.children.last { $0.isText })
        let end = section.renderedPosition(DOMPosition(endNode, 6), isEnd: true)
        XCTAssertEqual(section.tablePassage(ReaderTextRange(start: position, end: end)), "pha 😀 beta gamma")
    }

    func testLocatedCellPassageAcrossSpreadAndContinuationsKeepsFullCopy() async throws {
        let words = (0..<260).map { "word\($0)" }.joined(separator: " ")
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter(
            "<table border='1'><tr><td>\(words)</td><td>Other cell.</td></tr></table><p>After table.</p>")]))
        var performed: EPUBSelection?
        let session = try NativeSession(publication: publication,
            action: EPUBSelectionAction(title: "Annotate") { performed = $0 }, rich: NativeRichContent(), onEvent: { _ in })
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        window.resize(to: CGSize(width: 1100, height: 450))
        try await wait { session.isReady && session.canvas?.textViews.count == 2 }
        try await session.send(.style(.init(fontSize: 24)))
        try await session.send(.locate(text: words, highlight: true))
        try await wait { session.selection?.text == words }
        let canvas = try XCTUnwrap(session.canvas), range = try XCTUnwrap(canvas.currentSelection?.range)
        XCTAssertNotNil(range.start.tableCell); XCTAssertNotNil(range.end.tableCell)
        let controllers = canvas.textViews.compactMap(\.tableInteraction)
        XCTAssertEqual(controllers.filter { !$0.selectedText().isEmpty }.count, 2)
        let selected = controllers.flatMap { $0.cells.values }.filter { $0.cellSelection.length > 0 }
        for cell in selected {
            #if os(macOS)
            cell.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: cell))
            #else
            cell.textViewDidChangeSelection(cell)
            #endif
        }
        XCTAssertEqual(canvas.currentSelection?.range, range, "delayed native callbacks keep the complete located cell range")
        canvas.performSelectionAction(); XCTAssertEqual(performed?.text, words)
        XCTAssertTrue(controllers.contains { $0.selectionContinues(range, forward: true) })
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(canvas.currentSelection?.range, range)
        canvas.performSelectionAction(); XCTAssertEqual(performed?.text, words)
        XCTAssertTrue(canvas.textViews.flatMap { $0.tableInteraction?.cells.values.map { $0 } ?? [] }
            .contains { $0.cellSelection.location > 0 && $0.cellSelection.length > 0 })
        try await session.send(.locate(text: "word220 word221", highlight: true))
        try await wait { session.selection?.text == "word220 word221" }
        canvas.performSelectionAction()
        let saved = try XCTUnwrap(performed)
        let endpoint = try XCTUnwrap(canvas.currentSelection?.range.start)
        XCTAssertGreaterThan(endpoint.tableCell?.offset ?? 0, 1000)
        XCTAssertTrue(canvas.textViews.contains { $0.tableInteraction?.visibleCharacters(for: endpoint) != nil })
        try await session.send(.navigate(href: "OPS/one.xhtml"))
        try await session.send(.restore(saved.location))
        XCTAssertTrue(canvas.textViews.contains { view in
            guard let visible = view.tableInteraction?.visibleCharacters(for: endpoint), let offset = endpoint.tableCell?.offset else { return false }
            return NSLocationInRange(offset, visible)
        }, "restoring a precise cell CFI shows its actual later continuation")
        try await session.send(.style(.init(fontSize: 24, flow: .scrolled)))
        try await session.send(.restore(saved.location))
        XCTAssertTrue(canvas.textViews.contains { view in
            guard let visible = view.tableInteraction?.visibleCharacters(for: endpoint), let offset = endpoint.tableCell?.offset else { return false }
            return NSLocationInRange(offset, visible)
        }, "continuous scroll restores to the exact cell line")
        let targetFrame = try XCTUnwrap(canvas.tableAnchorFrame(for: endpoint))
        let scrollView = try XCTUnwrap(canvas.textViews.first)
        let targetPoint = scrollView.convert(CGPoint(x: targetFrame.midX + scrollView.containerOrigin.x,
            y: targetFrame.midY + scrollView.containerOrigin.y), to: canvas)
        XCTAssertTrue(canvas.bounds.contains(targetPoint), "the restored cell glyph is physically visible in continuous scroll")
    }

    func testBodyToCellProjectionAndAccessibilityActionsKeepExactRange() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/one.xhtml": chapter(body)]))
        let session = try NativeSession(publication: publication, action: nil, rich: NativeRichContent(), onEvent: { _ in })
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait { session.isReady && session.canvas?.textViews.first?.tableInteraction?.cells.count ?? 0 > 0 }
        let canvas = try XCTUnwrap(session.canvas), section = try XCTUnwrap(session.book.section(0))
        let tableCell = try XCTUnwrap(section.document.element(id: "cell"))
        let endNode = try XCTUnwrap(tableCell.children.last { $0.isText })
        let endpoint = section.renderedPosition(DOMPosition(endNode, 6), isEnd: true)
        let range = ReaderTextRange(start: ReaderTextPosition(section: 0, offset: 7), end: endpoint)
        canvas.show(range.start, selecting: range)
        try await wait { session.selection?.range == range }
        XCTAssertTrue(session.selection?.text.hasPrefix("table.") == true)
        XCTAssertTrue(session.selection?.text.hasSuffix("Alpha 😀 beta gamma") == true)
        XCTAssertTrue(canvas.textViews.contains { $0.selectedRange.length > 0 })
        let view = try XCTUnwrap(canvas.textViews.first)
        let controller = try XCTUnwrap(view.tableInteraction)
        XCTAssertFalse(controller.selectedText().isEmpty)
        XCTAssertTrue(controller.accessibilityActionsOfEveryRow().contains { $0.name.contains("Follow Table Link: Outside link") })
        #if os(macOS)
        let row = try XCTUnwrap(section.tables().first { $0.row.row == 1 })
        let spoken = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: row.offset, length: 1)))
        // The table has header cells, so it is data: the row's character gives the table, and
        // the row in it holds its two cells (`TableDataMacAccessibilityTests`).
        let table = try XCTUnwrap(spoken.attribute(.accessibilityAttachment, at: 0, effectiveRange: nil) as? ReaderTableElement)
        XCTAssertEqual(table.accessibilityRole(), .table)
        XCTAssertEqual((table.accessibilitySelectedRows()?.first as? ReaderTableRowElement)?.accessibilityChildren()?.count, 2)
        #else
        // The table has header cells, so it is data: each cell is an element that offers what it
        // can do itself, and the text view around the table offers none of it.
        let listed = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        let table = try XCTUnwrap(listed.first { $0 is UIAccessibilityContainerDataTable }, "the table is one container")
        let cells = try XCTUnwrap(table.accessibilityElements as? [UIAccessibilityElement])
        // The passage selected above runs into the table: a cell that holds part of it offers to
        // deselect and to copy, where the others offer to select.
        func offering(_ name: String) -> Int { cells.filter { $0.accessibilityCustomActions?.contains { $0.name == name } == true }.count }
        XCTAssertEqual(offering("Deselect Cell Text"), controller.cells.values.filter { $0.cellSelection.length > 0 }.count)
        XCTAssertGreaterThan(offering("Deselect Cell Text"), 0)
        XCTAssertEqual(offering("Copy"), offering("Deselect Cell Text"))
        XCTAssertEqual(offering("Select Cell Text"), cells.count - offering("Deselect Cell Text"))
        let alpha = try XCTUnwrap(cells.first { $0.accessibilityLabel?.hasPrefix("Alpha") == true })
        XCTAssertFalse(alpha.accessibilityCustomActions?.contains { $0.name.hasPrefix("Follow Link") } == true)
        let links = try XCTUnwrap(cells.first { $0.accessibilityLabel?.contains("Outside link") == true })
        XCTAssertTrue(links.accessibilityCustomActions?.contains { $0.name == "Follow Link: Outside link" } == true)
        XCTAssertFalse(listed.contains { $0.accessibilityCustomActions?.contains { $0.name.contains("Table") } == true })
        // VoiceOver would offer on every item whatever the text view around them offered.
        XCTAssertNil(view.accessibilityCustomActions)
        #endif
        canvas.clearSelection()
        let select = try XCTUnwrap(controller.accessibilityActionsOfEveryRow().first { $0.name.contains("Select Table Text: Alpha") })
        XCTAssertTrue(select.perform())
        canvas.performSelectionAction()
        XCTAssertEqual(session.selection?.text, "Alpha 😀 beta gamma.")
        XCTAssertNotNil(session.selection?.range.start.tableCell)
    }

    private func nativePoint(in cell: TableCellTextView, range: NSRange) -> CGPoint {
        #if os(macOS)
        let manager = cell.layoutManager!, container = cell.textContainer!
        #else
        let manager = cell.layoutManager, container = cell.textContainer
        #endif
        manager.ensureLayout(for: container)
        let character = NSRange(location: range.location, length: 1)
        let frame = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: character, actualCharacterRange: nil), in: container)
        #if os(macOS)
        let point = CGPoint(x: frame.midX + cell.textContainerOrigin.x, y: frame.midY + cell.textContainerOrigin.y)
        #else
        let point = CGPoint(x: frame.midX, y: frame.midY)
        #endif

        return point
    }

    #if os(macOS)
    func testUnselectedOverlaySuppressesColorEmojiAndTransparentImageInk() throws {
        let imageContext = try XCTUnwrap(CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8,
            bytesPerRow: 24 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        imageContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.45))
        imageContext.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: NSImage(cgImage: try XCTUnwrap(imageContext.makeImage()),
                                                                       size: CGSize(width: 24, height: 24)))
        let text = NSMutableAttributedString(string: "😀 linked ", attributes: [.font: NSFont.systemFont(ofSize: 32),
            .foregroundColor: NSColor.black])
        text.append(NSAttributedString(attachment: attachment))
        text.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: text.length))
        let link = (text.string as NSString).range(of: "linked")
        text.addAttributes([.link: URL(string: "https://example.com")!, .underlineStyle: NSUnderlineStyle.single.rawValue], range: link)
        let cell = TableCellTextView(text: text, width: 240, characters: NSRange(location: 0, length: text.length))
        let manager = try XCTUnwrap(cell.layoutManager)
        let container = try XCTUnwrap(cell.textContainer)

        func paintedAlpha(_ manager: NSLayoutManager, _ container: NSTextContainer) throws -> Int {
            manager.ensureLayout(for: container)
            let context = try XCTUnwrap(CGContext(data: nil, width: 260, height: 100, bitsPerComponent: 8,
                bytesPerRow: 260 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: 100); context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: CGPoint(x: 10, y: 10))
            NSGraphicsContext.restoreGraphicsState()
            let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: 260 * 100 * 4)
            return (0..<(260 * 100)).reduce(0) { $0 + Int(pixels[$1 * 4 + 3]) }
        }

        // The ordinary manager proves that foreground alpha alone still paints these glyphs.
        let controlStorage = NSTextStorage(attributedString: text)
        controlStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: 0, length: text.length))
        let control = NSLayoutManager(), controlContainer = NSTextContainer(size: CGSize(width: 240, height: 100))
        controlStorage.addLayoutManager(control); control.addTextContainer(controlContainer)
        XCTAssertGreaterThan(try paintedAlpha(control, controlContainer), 100)
        XCTAssertEqual(try paintedAlpha(manager, container), 0, "unselected cell overlays must add no authored pixels")
        cell.cellSelection = NSRange(location: 0, length: 2)
        XCTAssertGreaterThan(try paintedAlpha(manager, container), 100, "selected color emoji still draws native ink")
        cell.cellSelection = link
        XCTAssertGreaterThan(try paintedAlpha(manager, container), 100, "selected underlined links retain their native ink")
        cell.setCellHighlights([(link, ReaderHighlightPaint(fill: .yellow))])
        cell.cellSelection = NSRange(location: 0, length: 0)
        XCTAssertGreaterThan(try paintedAlpha(manager, container), 100, "highlighted links retain their native ink")
        cell.setCellHighlights([])
        cell.cellSelection = NSRange(location: text.length - 1, length: 1)
        let selectedImageAlpha = try paintedAlpha(manager, container)
        XCTAssertGreaterThan(selectedImageAlpha, 100, "selected translucent attachment still draws native ink")
        cell.setCellHighlights([(cell.cellSelection, ReaderHighlightPaint(fill: .yellow))])
        XCTAssertEqual(try paintedAlpha(manager, container), selectedImageAlpha, "overlapping selection and highlight paint translucent ink once")
        cell.cellSelection = NSRange(location: 0, length: 0)
        XCTAssertEqual(try paintedAlpha(manager, container), selectedImageAlpha)
        cell.setCellHighlights([])
        XCTAssertEqual(try paintedAlpha(manager, container), 0)
    }

    func testContinuedCellAccessibilityRangesAreRelativeToVisibleSlice() throws {
        let text = CanvasText.body("Earlier hidden cell line.\nVisible 😀 beta.\nSecond visible line.")
        let shown = (text.string as NSString).range(of: "Visible 😀 beta.\nSecond visible line.")
        let cell = TableCellTextView(text: text, width: 240, characters: shown)
        cell.configure(frame: CGRect(x: 0, y: 0, width: 168, height: 100), scale: 0.7,
                       textOffset: CGPoint(x: 0, y: 20), actionTitle: nil)
        XCTAssertNil(cell.accessibilityLabel(), "the same cell text is not repeated as both label and value")
        let expected = (text.string as NSString).substring(with: shown)
        XCTAssertEqual(cell.accessibilityValue(), expected)
        XCTAssertEqual(cell.accessibilityNumberOfCharacters(), expected.utf16.count)
        XCTAssertEqual(cell.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: shown.length))
        XCTAssertEqual(cell.accessibilityString(for: NSRange(location: 0, length: shown.length)), expected)
        XCTAssertEqual(cell.accessibilityAttributedString(for: NSRange(location: 0, length: shown.length))?.string, expected)
        XCTAssertNil(cell.accessibilityString(for: NSRange(location: shown.length, length: 1)))
        let emoji = (expected as NSString).range(of: "😀")
        XCTAssertEqual(cell.accessibilityRange(for: emoji.location + 1), emoji)
        var selected: NSRange?
        cell.onSelection = { selected = $0 }
        cell.setAccessibilitySelectedTextRange(emoji)
        XCTAssertEqual(selected, NSRange(location: shown.location + emoji.location, length: 2))
        XCTAssertEqual(cell.cellSelection, selected)
        XCTAssertEqual(cell.accessibilitySelectedTextRange(), emoji)
        XCTAssertEqual(cell.accessibilitySelectedTextRanges()?.first?.rangeValue, emoji)
        XCTAssertEqual(cell.accessibilitySelectedText(), "😀")
        cell.setAccessibilitySelectedTextRanges([NSValue(range: NSRange(location: 0, length: 7))])
        XCTAssertEqual(cell.cellSelection, NSRange(location: shown.location, length: 7))
        let firstLine = cell.accessibilityRange(forLine: 0)
        XCTAssertEqual(firstLine.location, 0)
        XCTAssertTrue(cell.accessibilityString(for: firstLine)?.hasPrefix("Visible") == true)
        XCTAssertEqual(cell.accessibilityLine(for: 0), 0)
        XCTAssertEqual(cell.accessibilityStyleRange(for: 0).location, 0)
        XCTAssertNotNil(cell.accessibilityRTF(for: NSRange(location: 0, length: shown.length)))
    }
    #endif

    func testContinuedScaledCellLinkAndImageHitsUseNativeConvertedCoordinates() async throws {
        let words = (0..<100).map { "word\($0)" }.joined(separator: " ")
        let fixture = try RichFixture("""
        <table id='t' border='1'><tr><td rowspan='2'>\(words)<br/><a href='#target'>Follow target</a><br/>
        <img src='image.png' width='900' alt='Inspect this diagram'/></td><td>First</td></tr><tr><td>Second</td></tr></table>
        """, files: ["image.png": RichFixture.image(width: 900, height: 80)], typography: .init(fontSize: 24))
        let section = SectionBuilder.build(SectionBuildRequest(publication: fixture.publication, spineIndex: 0,
            typography: .init(fontSize: 24), fonts: FontRegistry(publication: fixture.publication), rich: NativeRichContent()))
        let text = section.string
        let host = CanvasHost(FakeCanvasSource([text]), size: CGSize(width: 360, height: 400))
        defer { host.close() }
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        var foundLink = false, foundImage = false, pages = 0
        repeat {
            host.layOut(); try await host.settle(20)
            for view in host.canvas.textViews {
                for cell in view.tableInteraction?.cells.values ?? Dictionary<ReaderTableInteraction.Key, TableCellTextView>().values {
                    let link = (cell.cellText.string as NSString).range(of: "Follow target")
                    if link.location != NSNotFound, link.length > 0, NSIntersectionRange(link, cell.shownCharacters).length == link.length {
                        let nativePoint = nativePoint(in: cell, range: link)
                        let hitPoint = cell.convert(view.convert(nativePoint, from: cell), from: view)
                        guard let hit = cell.cellLink(at: hitPoint) else { XCTFail("Native continued cell link hit returned nil"); continue }
                        XCTAssertEqual(hit.range, link)
                        let bookPosition = try XCTUnwrap(view.tableInteraction?.selectionPosition(at: view.convert(nativePoint, from: cell)))
                        XCTAssertNotNil(bookPosition.tableCell)
                        foundLink = true
                    }
                    var imageRange: NSRange?
                    cell.cellText.enumerateAttribute(.attachment, in: cell.shownCharacters) { value, run, _ in
                        if value is ReaderImageAttachment { imageRange = run }
                    }
                    if let imageRange {
                        XCTAssertEqual(cell.cellImage(at: nativePoint(in: cell, range: imageRange))?.alt, "Inspect this diagram")
                        foundImage = true
                    }
                }
            }
            pages += 1
        } while host.canvas.turnPage(forward: true) == .turned && pages < 30
        XCTAssertGreaterThan(pages, 1)
        XCTAssertTrue(foundLink); XCTAssertTrue(foundImage)
    }
}
