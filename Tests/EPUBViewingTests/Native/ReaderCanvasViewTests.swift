import CoreGraphics
import EPUBCore
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The TextKit 2 canvas hosted in a real window behind a fake data source.
@MainActor final class ReaderCanvasViewTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private func host(_ sections: [NSAttributedString?], linear: [Bool]? = nil,
                      size: CGSize = CGSize(width: 600, height: 700),
                      configuration: ReaderCanvasConfiguration = .init(),
                      show position: ReaderTextPosition? = ReaderTextPosition(section: 0, offset: 0)) -> CanvasHost {
        let host = CanvasHost(FakeCanvasSource(sections, linear: linear), size: size, configuration: configuration)
        hosts.append(host)
        if let position { host.canvas.show(position, selecting: nil) }
        host.layOut()
        return host
    }

    private func sections(_ count: Int, paragraphs: Int = 8) -> [NSAttributedString?] {
        (0..<count).map { CanvasText.section($0, paragraphs: paragraphs) }
    }

    private func assertTextKit2(_ canvas: ReaderCanvasView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(canvas.textViews.isEmpty, file: file, line: line)
        for view in canvas.textViews {
            XCTAssertNotNil(view.textLayoutManager, "TextKit 2", file: file, line: line)
            XCTAssertTrue(view.textLayoutManager === view.readerLayoutManager, file: file, line: line)
            XCTAssertTrue(view.textContainer is ReaderTextContainer, file: file, line: line)
        }
    }

    // MARK: Paginated flow

    func testPaginatedColumnsAreTextKit2SlicesOfTheSection() throws {
        let host = host(sections(2))
        let canvas = host.canvas
        assertTextKit2(canvas)
        let range = try XCTUnwrap(canvas.visibleRange)
        XCTAssertEqual(range.start, ReaderTextPosition(section: 0, offset: 0))
        XCTAssertEqual(canvas.textViews.count, 1)
        let column = canvas.textViews[0]
        let section = try XCTUnwrap(host.source.sections[0])
        XCTAssertEqual(column.visibleText, (section.string as NSString).substring(with: NSRange(location: 0, length: range.end.offset)))
        XCTAssertFalse(column.isScrollEnabledForReader, "page columns never scroll")
        let spread = try XCTUnwrap(canvas.spread)
        XCTAssertEqual(column.frame.minX, spread.columns[0].minX, accuracy: 0.01)
        XCTAssertEqual(column.readerContainer.viewportSize, spread.columnSize)
        XCTAssertEqual(host.recorder.shown.last?.range, range)
        XCTAssertEqual(host.recorder.shown.last?.progress, 0)
        // The slice's own layout is exact, its page fits the column, and the view clips the
        // rest of the last paragraph.
        let last = try XCTUnwrap(column.lineFrame(containing: column.placement.visibleLength - 1))
        XCTAssertLessThanOrEqual(last.maxY, spread.columns[0].height + 0.5)
        XCTAssertGreaterThan(column.textLength, column.placement.visibleLength)
        XCTAssertEqual(column.frame.height, last.maxY, accuracy: 0.5)
    }

    func testTurningPagesWalksTheSectionsContiguously() throws {
        let host = host(sections(3, paragraphs: 3))
        let canvas = host.canvas
        var previous = try XCTUnwrap(canvas.visibleRange)
        var sectionsSeen: Set<Int> = [0]
        var turns = 0
        while turns < 200 {
            let result = canvas.turnPage(forward: true)
            if result == .atBoundary { break }
            XCTAssertEqual(result, .turned)
            let range = try XCTUnwrap(canvas.visibleRange)
            if range.start.section == previous.start.section {
                XCTAssertEqual(range.start, previous.end, "pages follow each other")
            } else {
                XCTAssertEqual(range.start, ReaderTextPosition(section: previous.start.section + 1, offset: 0))
                XCTAssertEqual(previous.end.offset, host.source.sections[previous.start.section]?.length,
                               "the previous section was shown to its end")
            }
            sectionsSeen.insert(range.start.section)
            previous = range
            turns += 1
        }
        XCTAssertEqual(sectionsSeen, [0, 1, 2])
        XCTAssertEqual(canvas.turnPage(forward: true), .atBoundary, "the book's last page")
        XCTAssertEqual(previous.end.offset, host.source.sections[2]?.length)
        // And back to the start.
        var back = 0
        while canvas.turnPage(forward: false) == .turned { back += 1 }
        XCTAssertEqual(back, turns)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
        XCTAssertEqual(canvas.turnPage(forward: false), .atBoundary)
        assertTextKit2(canvas)
    }

    func testTurningBackIntoASectionShowsItsEnd() throws {
        let host = host(sections(2), show: ReaderTextPosition(section: 1, offset: 0))
        XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
        let range = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertEqual(range.start.section, 0)
        XCTAssertEqual(range.end.offset, host.source.sections[0]?.length)
    }

    func testAnUnbuiltNeighbourIsPending() throws {
        let host = host([CanvasText.section(0, paragraphs: 1), nil])
        let before = host.canvas.visibleRange
        var result = host.canvas.turnPage(forward: true)
        while result == .turned { result = host.canvas.turnPage(forward: true) }
        XCTAssertEqual(result, .pending(section: 1))
        XCTAssertEqual(host.recorder.needed.last?.section, 1)
        XCTAssertEqual(host.recorder.needed.last?.forward, true)
        XCTAssertEqual(host.canvas.visibleRange?.start.section, 0, "nothing changes until the section is built")
        _ = before
        // Once built, the session shows its start.
        host.source.sections[1] = CanvasText.section(1, paragraphs: 1)
        host.canvas.show(ReaderTextPosition(section: 1, offset: 0), selecting: nil)
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
    }

    func testPageTurnsStepOverNonlinearSections() throws {
        let host = host(sections(3, paragraphs: 1), linear: [true, false, true])
        var result = host.canvas.turnPage(forward: true)
        while result == .turned, host.canvas.visibleRange?.start.section == 0 { result = host.canvas.turnPage(forward: true) }
        XCTAssertEqual(host.canvas.visibleRange?.start.section, 2)
        XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(host.canvas.visibleRange?.start.section, 0)
    }

    func testShowLandsOnThePageHoldingThePosition() throws {
        let host = host(sections(1, paragraphs: 20))
        let length = try XCTUnwrap(host.source.sections[0]).length
        for offset in [0, 1500, length / 2, length - 3, length] {
            host.canvas.show(ReaderTextPosition(section: 0, offset: offset), selecting: nil)
            let range = try XCTUnwrap(host.canvas.visibleRange)
            XCTAssertTrue(range.start.offset <= offset && (offset < range.end.offset || offset == length),
                          "\(offset) in \(range)")
            XCTAssertEqual(host.recorder.shown.last?.range, range)
            XCTAssertEqual(host.recorder.shown.last?.progress ?? -1, Double(range.start.offset) / Double(length), accuracy: 1e-9)
        }
    }

    func testWideWindowsShowTwoConsecutiveSlices() throws {
        let host = host(sections(1, paragraphs: 20), size: CGSize(width: 1100, height: 800))
        let canvas = host.canvas
        XCTAssertEqual(canvas.textViews.count, 2)
        let left = canvas.textViews[0], right = canvas.textViews[1]
        XCTAssertLessThan(left.frame.maxX, right.frame.minX)
        XCTAssertEqual(right.placement.offset, left.placement.offset + left.placement.visibleLength)
        let range = try XCTUnwrap(canvas.visibleRange)
        XCTAssertEqual(range.end.offset, right.placement.offset + right.placement.visibleLength)
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        XCTAssertEqual(canvas.visibleRange?.start, range.end, "a turn moves by the whole spread")
        assertTextKit2(canvas)
    }

    func testRightToLeftSpreadsPutTheFirstSliceOnTheRight() throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.isRightToLeft = true
        let host = host(sections(1, paragraphs: 20), size: CGSize(width: 1100, height: 800), configuration: configuration)
        let first = host.canvas.columns[0], second = host.canvas.columns[1]
        XCTAssertEqual(first.placement.offset, 0)
        XCTAssertGreaterThan(first.frame.minX, second.frame.maxX)
    }

    func testDivisionPutsTheColumnsEitherSideOfTheFold() throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.division = CGRect(x: 280, y: 0, width: 40, height: 700)
        let host = host(sections(1, paragraphs: 20), configuration: configuration)
        let columns = host.canvas.textViews
        XCTAssertEqual(columns.count, 2, "book pose always shows two columns")
        XCTAssertLessThan(columns[0].frame.maxX, 280)
        XCTAssertGreaterThan(columns[1].frame.minX, 320)
    }

    func testResizingKeepsThePosition() throws {
        let host = host(sections(1, paragraphs: 30))
        let target = 9_000
        host.canvas.show(ReaderTextPosition(section: 0, offset: target), selecting: nil)
        for size in [CGSize(width: 1100, height: 800), CGSize(width: 420, height: 800), CGSize(width: 600, height: 700)] {
            host.resize(to: size)
            let range = try XCTUnwrap(host.canvas.visibleRange)
            XCTAssertTrue(range.start.offset <= target && target < range.end.offset, "\(size): \(range)")
        }
    }

    func testReloadKeepsThePositionWithRebuiltText() throws {
        let host = host(sections(2, paragraphs: 20))
        host.canvas.show(ReaderTextPosition(section: 0, offset: 6_000), selecting: nil)
        let start = try XCTUnwrap(host.canvas.visibleRange?.start)
        // A style rebuild: the same characters at a larger size.
        let rebuilt = NSMutableAttributedString(attributedString: try XCTUnwrap(host.source.sections[0]))
        rebuilt.addAttribute(.font, value: PlatformFont.systemFont(ofSize: 26), range: NSRange(location: 0, length: rebuilt.length))
        host.source.sections[0] = rebuilt
        host.canvas.reloadContent(keeping: nil)
        let range = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertTrue(range.start.offset <= 6_000 && 6_000 < range.end.offset, "the kept position, not the page start \(start)")
        let font = host.canvas.textViews[0].contentStorage.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        XCTAssertEqual(font?.pointSize, 26)
    }

    // MARK: Highlights, selection, links

    func testHighlightsAreRenderingAttributesThatSurvivePageTurns() throws {
        let host = host(sections(1, paragraphs: 20))
        let canvas = host.canvas
        let firstEnd = try XCTUnwrap(canvas.visibleRange).end.offset
        canvas.setHighlights([
            ReaderHighlight(id: "a", range: ReaderTextRange(section: 0, 10..<40), kind: .annotation),
            ReaderHighlight(id: "s", range: ReaderTextRange(section: 0, (firstEnd + 5)..<(firstEnd + 20)), kind: .search),
        ])
        func highlighted(_ view: ReaderTextView) -> [(NSRange, PlatformColor)] {
            var result: [(NSRange, PlatformColor)] = []
            let layoutManager = view.readerLayoutManager
            layoutManager.enumerateRenderingAttributes(from: layoutManager.documentRange.location, reverse: false) { _, attributes, range in
                if let color = attributes[.backgroundColor] as? PlatformColor {
                    result.append((NSRange(location: view.offset(of: range.location),
                                           length: view.offset(of: range.endLocation) - view.offset(of: range.location)), color))
                }
                return true
            }
            return result
        }
        var drawn = highlighted(canvas.textViews[0])
        XCTAssertEqual(drawn.map(\.0), [NSRange(location: 10, length: 30)])
        XCTAssertEqual(drawn.first?.1, ReaderPalette.annotationHighlight(dark: false))
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        drawn = highlighted(canvas.textViews[0])
        XCTAssertEqual(drawn.map(\.0), [NSRange(location: 5, length: 15)], "reapplied in the new page's own characters")
        XCTAssertEqual(drawn.first?.1, ReaderPalette.searchHighlight(dark: false))
        XCTAssertEqual(canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(highlighted(canvas.textViews[0]).map(\.0), [NSRange(location: 10, length: 30)])
        canvas.configuration.isDark = true
        XCTAssertEqual(highlighted(canvas.textViews[0]).first?.1, ReaderPalette.annotationHighlight(dark: true))
        // The text itself never changes.
        let storage = try XCTUnwrap(canvas.textViews[0].contentStorage.textStorage)
        var painted = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { painted = true }
        }
        XCTAssertFalse(painted)
        canvas.setHighlights([])
        XCTAssertTrue(highlighted(canvas.textViews[0]).isEmpty)
    }

    func testSelectionIsReportedInSectionPositionsOnceItSettles() async throws {
        let host = host(sections(1, paragraphs: 20))
        let canvas = host.canvas
        XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        let column = canvas.textViews[0]
        let offset = column.placement.offset
        column.selectedRange = NSRange(location: 4, length: 12)
        canvas.textViewSelectionDidChange(column) // UIKit does not notify programmatic changes.
        XCTAssertTrue(host.recorder.selections.isEmpty, "not before it settles")
        try await host.settle()
        let selection = try XCTUnwrap(host.recorder.selections.last ?? nil)
        XCTAssertEqual(selection.range, ReaderTextRange(section: 0, (offset + 4)..<(offset + 16)))
        XCTAssertEqual(selection.text, column.plainText(in: NSRange(location: 4, length: 12)))
        XCTAssertEqual(canvas.currentSelection, selection)
        XCTAssertEqual(host.recorder.selections.count, 1)

        canvas.clearSelection()
        XCTAssertEqual(host.recorder.selections.count, 2)
        XCTAssertNil(host.recorder.selections.last ?? nil)
        XCTAssertEqual(column.selectedRange.length, 0)
    }

    func testSelectionNeverReachesTheClippedContext() async throws {
        let host = host(sections(1, paragraphs: 20))
        let column = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertGreaterThan(column.textLength, column.placement.visibleLength, "the page ends mid-paragraph")
        column.selectedRange = NSRange(location: column.placement.visibleLength - 5, length: 20)
        host.canvas.textViewSelectionDidChange(column)
        XCTAssertEqual(NSMaxRange(column.selectedRange), column.placement.visibleLength)
        try await host.settle()
        XCTAssertEqual(host.canvas.currentSelection?.range.end.offset, column.placement.visibleLength)
    }

    func testShowSelectingSelectsNativelyAndReports() async throws {
        let host = host(sections(1, paragraphs: 20))
        let text = try XCTUnwrap(host.source.sections[0])
        let range = ReaderTextRange(section: 0, 7_000..<7_040)
        host.canvas.show(range.start, selecting: range)
        let column = try XCTUnwrap(host.canvas.textViews.first { NSLocationInRange(7_000 - $0.placement.offset, NSRange(location: 0, length: $0.placement.visibleLength)) })
        XCTAssertEqual(column.selectedRange.location, 7_000 - column.placement.offset)
        try await host.settle()
        let selection = try XCTUnwrap(host.recorder.selections.last ?? nil)
        XCTAssertEqual(selection.range, range)
        XCTAssertEqual(selection.text, (text.string as NSString).substring(with: NSRange(location: 7_000, length: 40)))
    }

    func testSelectionRunningPastThePageIsReportedExactlyAsShown() async throws {
        let host = host(sections(1, paragraphs: 20))
        let pageEnd = try XCTUnwrap(host.canvas.visibleRange).end.offset
        let range = ReaderTextRange(section: 0, (pageEnd - 10)..<(pageEnd + 30))
        host.canvas.show(range.start, selecting: range)
        try await host.settle()
        XCTAssertEqual(host.recorder.selections.count, 1)
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.range, range)
        XCTAssertEqual(host.canvas.currentSelection?.range, range)
        let column = try XCTUnwrap(host.canvas.textViews.first)
        XCTAssertEqual(column.selectedRange, NSRange(location: column.placement.visibleLength - 10, length: 10),
                       "selected natively up to the page's end")
    }

    /// "Energy ", a formula attachment reading "E = mc²", " is famous."
    private func formulaText() -> (text: NSAttributedString, formula: TextualTestAttachment) {
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Energy "))
        let formula = TextualTestAttachment()
        formula.textEquivalent = "E = mc²"
        formula.image = CanvasText.attachment(size: CGSize(width: 40, height: 20))
            .attribute(.attachment, at: 0, effectiveRange: nil).flatMap { ($0 as? NSTextAttachment)?.image }
        formula.bounds = CGRect(x: 0, y: 0, width: 40, height: 20)
        text.append(NSAttributedString(attachment: formula))
        text.append(CanvasText.body(" is famous."))
        return (text, formula)
    }

    func testTextualAttachmentsAreExposedToVoiceOver() throws {
        let (text, formula) = formulaText()
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            var configuration = ReaderCanvasConfiguration()
            configuration.flow = flow
            let host = host([text], configuration: configuration)
            let view = try XCTUnwrap(host.canvas.textViews.first)
            #if os(macOS)
            let attributed = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: 0, length: text.length)))
            XCTAssertEqual(attributed.string, text.string, "accessibility ranges match the text")
            let element = try XCTUnwrap(attributed.attribute(.accessibilityAttachment, at: 7, effectiveRange: nil)
                                            as? NSAccessibilityElement, "\(flow)")
            XCTAssertEqual(element.accessibilityLabel(), "E = mc²")
            XCTAssertEqual(element.accessibilityRole(), .image)
            XCTAssertTrue(element.accessibilityParent() as? ReaderTextView === view)
            XCTAssertFalse(element.accessibilityFrameInParentSpace().isEmpty)
            let tail = try XCTUnwrap(view.accessibilityAttributedString(for: NSRange(location: 5, length: 4)))
            XCTAssertNotNil(tail.attribute(.accessibilityAttachment, at: 2, effectiveRange: nil), "ranges are local")
            #else
            XCTAssertEqual(formula.accessibilityLabel, "E = mc²")
            if flow == .paginated { XCTAssertEqual(view.accessibilityValue, "Energy E = mc² is famous.") }
            #endif
        }
    }

    func testSelectionAndCopyReadAttachmentsAsTheirText() async throws {
        let (text, _) = formulaText()
        let host = host([text])
        let column = host.canvas.textViews[0]
        column.selectedRange = NSRange(location: 0, length: text.length)
        host.canvas.textViewSelectionDidChange(column)
        try await host.settle()
        let expected = "Energy E = mc² is famous."
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.text, expected)
        XCTAssertEqual(column.visibleText, expected)
        #if os(macOS)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.epublib.tests.copy.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(column.writeSelection(to: pasteboard, types: column.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        #else
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("org.epublib.tests.copy.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        column.pasteboard = pasteboard
        column.copy(nil)
        XCTAssertEqual(pasteboard.string, expected)
        #endif
    }

    func testSelectionActionReportsTheSelectionFirst() async throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.selectionActionTitle = "Ask about this"
        let host = host(sections(1), configuration: configuration)
        let column = host.canvas.textViews[0]
        column.selectedRange = NSRange(location: 0, length: 9)
        host.canvas.textViewSelectionDidChange(column)
        #if os(macOS)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(host.canvas.textView(column, menu: NSMenu(), for: event, at: 0))
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(item.title, "Ask about this")
        host.canvas.selectionActionChosen(item)
        #else
        let menu = try XCTUnwrap(host.canvas.textView(column, editMenuForTextInRanges: [NSValue(range: column.selectedRange)],
                                                      suggestedActions: []))
        let inline = try XCTUnwrap(menu.children.first as? UIMenu)
        let action = try XCTUnwrap(inline.children.first as? UIAction)
        XCTAssertEqual(action.title, "Ask about this")
        host.canvas.performSelectionAction()
        #endif
        XCTAssertEqual(host.recorder.actions, 1)
        XCTAssertEqual(host.recorder.selections.count, 1, "the selection is reported before the action")
        XCTAssertEqual((host.recorder.selections.last ?? nil)?.range, ReaderTextRange(section: 0, 0..<9))
    }

    func testLinksAreReportedNeverOpened() throws {
        let host = host(sections(1))
        let column = host.canvas.textViews[0]
        let storage = try XCTUnwrap(column.contentStorage.textStorage)
        var linkRange = NSRange(location: NSNotFound, length: 0)
        var linkURL: URL?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let url = value as? URL { linkRange = range; linkURL = url; stop.pointee = true }
        }
        let url = try XCTUnwrap(linkURL)
        #if os(macOS)
        XCTAssertTrue(host.canvas.textView(column, clickedOnLink: url, at: linkRange.location + 2), "handled, not opened")
        #else
        host.canvas.activateLink(url, range: linkRange, in: column)
        #endif
        let activation = try XCTUnwrap(host.recorder.links.last)
        XCTAssertEqual(activation.link, .internal(href: "OPS/two.xhtml#target"))
        XCTAssertEqual(activation.position, ReaderTextPosition(section: 0, offset: column.placement.offset + linkRange.location))
        XCTAssertFalse(activation.rect.isEmpty)
        XCTAssertTrue(host.canvas.bounds.contains(activation.rect))
        XCTAssertTrue(column.frame.intersects(activation.rect))
    }

    func testNoteTextShowsInAPopover() throws {
        let host = host(sections(1))
        let note = CanvasText.body("A footnote.")
        host.canvas.presentNote(note, from: CGRect(x: 100, y: 100, width: 20, height: 20))
        #if os(macOS)
        let popover = try XCTUnwrap(host.canvas.presentedNote as? NSPopover)
        XCTAssertTrue(popover.isShown)
        let controller = try XCTUnwrap(popover.contentViewController as? ReaderNoteViewController)
        XCTAssertEqual(controller.textView.contentStorage.textStorage?.string, "A footnote.")
        XCTAssertNotNil(controller.textView.textLayoutManager)
        popover.close()
        #else
        let controller = try XCTUnwrap(host.canvas.presentedNote as? ReaderNoteViewController)
        XCTAssertEqual(controller.textView.contentStorage.textStorage?.string, "A footnote.")
        XCTAssertNotNil(controller.textView.textLayoutManager)
        XCTAssertEqual(controller.modalPresentationStyle, .popover)
        #endif
    }

    func testDarkAppearance() throws {
        let host = host(sections(1))
        host.canvas.configuration.isDark = true
        #if os(macOS)
        XCTAssertEqual(host.canvas.appearance?.name, .darkAqua)
        XCTAssertEqual(host.canvas.layer?.backgroundColor, ReaderPalette.background(dark: true).cgColor)
        #else
        XCTAssertEqual(host.canvas.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(host.canvas.backgroundColor, ReaderPalette.background(dark: true))
        #endif
        host.canvas.configuration.isDark = false
        #if os(macOS)
        XCTAssertEqual(host.canvas.appearance?.name, .aqua)
        #else
        XCTAssertEqual(host.canvas.overrideUserInterfaceStyle, .light)
        #endif
    }

    #if os(macOS)
    func testPageTurnKeysTurnAndSelectionShortcutsStillWork() throws {
        let host = host(sections(1, paragraphs: 20))
        let column = host.canvas.textViews[0]
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: host.window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let start = try XCTUnwrap(host.canvas.visibleRange?.start)
        column.keyDown(with: key(124, "\u{F703}", [.function, .numericPad]))
        let next = try XCTUnwrap(host.canvas.visibleRange?.start)
        XCTAssertGreaterThan(next.offset, start.offset, "Right")
        host.canvas.textViews[0].keyDown(with: key(49, " ", [.shift]))
        XCTAssertEqual(host.canvas.visibleRange?.start, start, "Shift-Space")
        host.canvas.keyDown(with: key(121, "\u{F72D}", [.function]))
        XCTAssertEqual(host.canvas.visibleRange?.start, next, "Page Down on the canvas")
        let view = host.canvas.textViews[0]
        view.keyDown(with: key(0, "a", [.command]))
        view.selectAll(nil) // What Cmd-A performs through the menu.
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: view.placement.visibleLength), "the page, not its context")
        XCTAssertEqual(host.canvas.visibleRange?.start, next, "Cmd-A does not turn")
    }

    func testWheelTicksTurnPages() throws {
        let host = host(sections(1, paragraphs: 20))
        let start = try XCTUnwrap(host.canvas.visibleRange?.start)
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -30, wheel2: 0, wheel3: 0))
        host.canvas.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        XCTAssertGreaterThan(try XCTUnwrap(host.canvas.visibleRange?.start).offset, start.offset)
    }
    #else
    func testPageTurnKeyCommandsTakePriorityAndLeaveSelectionChords() throws {
        let host = host(sections(1, paragraphs: 20))
        let commands = try XCTUnwrap(host.canvas.keyCommands)
        XCTAssertEqual(commands.count, 6)
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))
        XCTAssertFalse(commands.contains { !$0.modifierFlags.isDisjoint(with: [.command, .alternate, .control]) })
        let start = try XCTUnwrap(host.canvas.visibleRange?.start)
        host.canvas.pageTurnKeyCommand(try XCTUnwrap(commands.first { $0.input == UIKeyCommand.inputRightArrow }))
        XCTAssertGreaterThan(try XCTUnwrap(host.canvas.visibleRange?.start), start)
        host.canvas.pageTurnKeyCommand(try XCTUnwrap(commands.first { $0.input == " " && $0.modifierFlags == .shift }))
        XCTAssertEqual(host.canvas.visibleRange?.start, start)
        XCTAssertNil(ReaderTextView.pageTurnDirection(input: UIKeyCommand.inputLeftArrow, flags: .shift))
        XCTAssertNil(ReaderTextView.pageTurnDirection(input: "a", flags: .command))
        XCTAssertTrue(host.canvas.textViews[0].next === host.canvas, "the text views' keys reach the canvas")
    }
    #endif

    // MARK: Continuous scroll

    private func scrolledHost(_ sections: [NSAttributedString?], book: Bool, show position: ReaderTextPosition,
                              size: CGSize = CGSize(width: 600, height: 700)) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        let host = host(sections, size: size, configuration: configuration, show: nil)
        if book { host.source.book = CanvasText.book(sections.compactMap { $0 }) }
        host.canvas.show(position, selecting: nil)
        host.layOut()
        return host
    }

    func testScrolledFlowIsOneTextKit2ScrollView() throws {
        let host = scrolledHost(sections(2), book: false, show: ReaderTextPosition(section: 0, offset: 0))
        let canvas = host.canvas
        assertTextKit2(canvas)
        let view = try XCTUnwrap(canvas.scrollTextView)
        XCTAssertTrue(view.isScrollEnabledForReader)
        XCTAssertEqual(canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
        let column = ReaderCanvasGeometry.scrollColumn(in: canvas.pageArea, division: nil)
        XCTAssertEqual(view.readerContainer.size.width, column.width, accuracy: 0.5)
        #if os(macOS)
        let scrollView = try XCTUnwrap(canvas.scrollContainer as? NSScrollView)
        XCTAssertTrue(scrollView.automaticallyAdjustsContentInsets)
        XCTAssertTrue(scrollView.documentView === view)
        XCTAssertEqual(view.textContainerOrigin.x, column.minX, accuracy: 0.5)
        #else
        XCTAssertEqual(view.contentInsetAdjustmentBehavior, .automatic)
        XCTAssertEqual(view.contentInset, UIEdgeInsets(top: 48, left: 0, bottom: 64, right: 0))
        XCTAssertEqual(view.textContainerInset.top, 0)
        XCTAssertEqual(view.textContainerInset.bottom, 0)
        XCTAssertEqual(view.textContainerInset.left, column.minX, accuracy: 0.5)
        XCTAssertEqual(view.topEdgeEffect.style, .soft)
        XCTAssertEqual(view.bottomEdgeEffect.style, .soft)
        XCTAssertEqual(view.frame, canvas.bounds, "content runs under the bars")
        #endif
    }

    func testScrolledShowPutsThePositionAtTheTop() throws {
        let host = scrolledHost(sections(3), book: true, show: ReaderTextPosition(section: 1, offset: 2_000))
        let range = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertEqual(range.start.section, 1)
        XCTAssertLessThanOrEqual(range.start.offset, 2_000)
        XCTAssertGreaterThan(range.start.offset, 1_900, "the line holding the position is the first visible")
        XCTAssertGreaterThan(range.end, range.start)
    }

    func testScrolledPageTurnsScrollByAViewportLessALine() throws {
        let host = scrolledHost(sections(2), book: true, show: ReaderTextPosition(section: 0, offset: 0))
        let first = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        let second = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertGreaterThan(second.start, first.start)
        XCTAssertLessThan(second.start, first.end, "the last line stays on screen")
        XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
        XCTAssertEqual(host.canvas.visibleRange?.start, first.start)
        XCTAssertEqual(host.canvas.turnPage(forward: false), .atBoundary)
    }

    func testScrolledSectionEndTurnsToTheNextSectionUntilTheBookIsBuilt() throws {
        let host = scrolledHost([CanvasText.section(0, paragraphs: 1), CanvasText.section(1, paragraphs: 1)], book: false,
                                show: ReaderTextPosition(section: 0, offset: 0))
        var result = host.canvas.turnPage(forward: true)
        while result == .turned, host.canvas.visibleRange?.start.section == 0 { result = host.canvas.turnPage(forward: true) }
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 1, offset: 0))
        XCTAssertNil(host.canvas.scrollBook)
    }

    func testWholeBookSwapKeepsTheVisibleStart() throws {
        let all = sections(4)
        let host = scrolledHost(all, book: false, show: ReaderTextPosition(section: 2, offset: 3_000))
        XCTAssertNil(host.canvas.scrollBook)
        let before = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertEqual(before.start.section, 2)
        host.source.book = CanvasText.book(all.compactMap { $0 })
        host.canvas.reloadContent(keeping: nil)
        XCTAssertNotNil(host.canvas.scrollBook)
        XCTAssertEqual(host.canvas.visibleRange?.start, before.start)
        XCTAssertEqual(host.recorder.shown.last?.range.start, before.start)
        // Ranges and highlights in the whole book are in section positions.
        host.canvas.setHighlights([ReaderHighlight(id: "h", range: ReaderTextRange(section: 2, 3_000..<3_020), kind: .search)])
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        let book = try XCTUnwrap(host.canvas.scrollBook)
        let global = book.location(of: ReaderTextPosition(section: 2, offset: 3_000))
        var found = false
        view.readerLayoutManager.enumerateRenderingAttributes(from: view.readerLayoutManager.documentRange.location, reverse: false) { _, attributes, range in
            if attributes[.backgroundColor] != nil, view.offset(of: range.location) == global { found = true }
            return true
        }
        XCTAssertTrue(found)
    }

    func testScrollingReportsTheVisibleRange() async throws {
        let host = scrolledHost(sections(3), book: true, show: ReaderTextPosition(section: 0, offset: 0))
        let reports = host.recorder.shown.count
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        let line = try XCTUnwrap(view.lineFrame(containing: 6_000))
        // The person scrolls (not through the canvas).
        #if os(macOS)
        let scrollView = try XCTUnwrap(host.canvas.scrollContainer as? NSScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: line.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #else
        view.contentOffset = CGPoint(x: 0, y: line.minY)
        #endif
        try await host.settle()
        XCTAssertGreaterThan(host.recorder.shown.count, reports)
        let range = try XCTUnwrap(host.recorder.shown.last?.range)
        XCTAssertGreaterThan(range.start, ReaderTextPosition(section: 0, offset: 3_000))
        XCTAssertGreaterThan(range.end, range.start)
        XCTAssertEqual(host.canvas.visibleRange, range)
    }

    func testFlowSwitchKeepsThePosition() throws {
        let host = host(sections(2, paragraphs: 20))
        host.canvas.show(ReaderTextPosition(section: 1, offset: 8_000), selecting: nil)
        host.canvas.configuration.flow = .scrolled
        host.layOut()
        var range = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertEqual(range.start.section, 1)
        XCTAssertTrue(range.start.offset <= 8_000 && 8_000 < range.end.offset, "\(range)")
        XCTAssertNotNil(host.canvas.scrollTextView)
        XCTAssertTrue(host.canvas.columns.isEmpty)
        host.canvas.configuration.flow = .paginated
        host.layOut()
        range = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertTrue(range.start.offset <= 8_000 && 8_000 < range.end.offset, "\(range)")
        XCTAssertNil(host.canvas.scrollTextView)
    }

    // MARK: Resizing, caches and memory

    func testPaginationsAreCachedByColumnSize() throws {
        let host = host(sections(2, paragraphs: 20))
        let small = try XCTUnwrap(host.canvas.spread?.columnSize)
        let first = try XCTUnwrap(host.canvas.paginator(for: 0))
        host.resize(to: CGSize(width: 1100, height: 800))
        XCTAssertNotEqual(host.canvas.spread?.columnSize, small)
        host.resize(to: CGSize(width: 600, height: 700))
        XCTAssertTrue(host.canvas.paginator(for: 0) === first, "back at the first size, its pagination is reused")
        host.canvas.reloadContent(keeping: nil)
        XCTAssertTrue(host.canvas.paginator(for: 0) === first, "a reload with the same text keeps it")
        host.source.sections[0] = NSAttributedString(attributedString: try XCTUnwrap(host.source.sections[0]))
        host.canvas.reloadContent(keeping: nil)
        XCTAssertFalse(host.canvas.paginator(for: 0) === first, "rebuilt text is paginated afresh")
    }

    /// A dual-screen phone closing to its outer display lays the reader out three times in about
    /// 70 ms, and opening it three more. The reading position stays on screen throughout, and a
    /// restore afterwards lands (#12).
    func testABurstOfScrolledResizesKeepsThePositionAndRestoresLand() async throws {
        let host = scrolledHost([longSection(200_000)], book: true, show: ReaderTextPosition(section: 0, offset: 100_000),
                                size: CGSize(width: 867, height: 669))
        // The person scrolls on a little (not through the canvas).
        #if os(macOS)
        let scrollView = try XCTUnwrap(host.canvas.scrollContainer as? NSScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + 300))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #else
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        view.contentOffset = CGPoint(x: 0, y: view.contentOffset.y + 300)
        #endif
        try await host.settle()
        let reading = try XCTUnwrap(host.canvas.visibleRange?.start)
        XCTAssertGreaterThan(reading.offset, 100_000)
        func assertShows(_ position: ReaderTextPosition, _ step: String) throws {
            let range = try XCTUnwrap(host.canvas.visibleRange)
            XCTAssertTrue(range.start <= position && position < range.end, "\(step): \(range)")
        }
        for size in [CGSize(width: 779, height: 669), CGSize(width: 294, height: 678), CGSize(width: 382, height: 678),
                     CGSize(width: 466, height: 678), CGSize(width: 951, height: 669), CGSize(width: 867, height: 669)] {
            host.resize(to: size)
            try assertShows(reading, "\(size)")
        }
        try await host.settle()
        try assertShows(reading, "settled")
        // The session's restore: the position from before the burst, then another and back.
        for offset in [reading.offset, 150_000, reading.offset] {
            let position = ReaderTextPosition(section: 0, offset: offset)
            host.canvas.show(position, selecting: nil)
            try assertShows(position, "show \(offset)")
        }
    }

    func testALiveResizeKeepsTheSpreadUntilItEnds() throws {
        let host = host(sections(1, paragraphs: 30))
        host.canvas.show(ReaderTextPosition(section: 0, offset: 9_000), selecting: nil)
        let spread = host.canvas.spread, range = host.canvas.visibleRange
        host.canvas.beginDeferringLayout()
        host.resize(to: CGSize(width: 1100, height: 800))
        host.resize(to: CGSize(width: 1000, height: 800))
        XCTAssertEqual(host.canvas.spread, spread, "the old spread stays on screen")
        XCTAssertEqual(host.canvas.visibleRange, range)
        XCTAssertNotNil(host.canvas.pendingSpread)
        host.canvas.endDeferringLayout()
        XCTAssertNil(host.canvas.pendingSpread)
        XCTAssertEqual(host.canvas.spread?.columns.count, 2)
        let after = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertTrue(after.start.offset <= 9_000 && 9_000 < after.end.offset)
    }

    private func longSection(_ length: Int, seed: Int = 9) -> NSAttributedString {
        let paragraph = CanvasText.sentence(130, seed: seed)
        let text = NSMutableAttributedString()
        while text.length < length { text.append(CanvasText.body(paragraph + "\n")) }
        return text
    }

    func testALongRepaginationRunsInStepsKeepingTheOldSpread() async throws {
        let text = longSection(600_000)
        let host = host([text])
        let target = text.length - 100
        host.canvas.show(ReaderTextPosition(section: 0, offset: target), selecting: nil)
        let spread = host.canvas.spread
        host.resize(to: CGSize(width: 1100, height: 800))
        XCTAssertEqual(host.canvas.spread, spread, "the old spread stays while the new size paginates")
        XCTAssertNotNil(host.canvas.pendingSpread)
        let deadline = Date().addingTimeInterval(20)
        while host.canvas.pendingSpread != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(host.canvas.pendingSpread)
        XCTAssertEqual(host.canvas.spread?.columns.count, 2)
        let range = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertTrue(range.start.offset <= target && target < range.end.offset, "\(range)")
    }

    func testACommandDuringRepaginationActsOnTheNewSpread() throws {
        let text = longSection(600_000)
        let host = host([text])
        host.canvas.show(ReaderTextPosition(section: 0, offset: text.length - 100), selecting: nil)
        host.resize(to: CGSize(width: 1100, height: 800))
        XCTAssertNotNil(host.canvas.pendingSpread)
        let before = try XCTUnwrap(host.canvas.visibleRange)
        XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
        XCTAssertNil(host.canvas.pendingSpread)
        XCTAssertEqual(host.canvas.spread?.columns.count, 2)
        XCTAssertLessThan(try XCTUnwrap(host.canvas.visibleRange).end.offset, before.end.offset)
    }

    func testPaginatorsKeepToTheLayoutBudgetAndTrimUnderPressure() throws {
        let big: [NSAttributedString?] = (0..<4).map { longSection(700_000, seed: $0) }
        let host = host(big)
        for section in 0..<4 {
            host.canvas.show(ReaderTextPosition(section: section, offset: 400_000), selecting: nil)
            XCTAssertLessThanOrEqual(host.canvas.heldPaginatorLayout, ReaderCanvasView.heldLayoutBudget, "after \(section)")
        }
        XCTAssertGreaterThan(host.canvas.cachedPaginatorCount, 1)
        // The section's end, so pagination finishes whatever the page size (700,000 is not the
        // last page on an iPad's larger pages).
        host.canvas.show(ReaderTextPosition(section: 3, offset: try XCTUnwrap(big[3]).length), selecting: nil)
        XCTAssertFalse(try XCTUnwrap(host.canvas.paginator(for: 3)).holdsLayout, "a finished pagination holds no layout")
        host.canvas.trimCaches()
        XCTAssertEqual(host.canvas.cachedPaginatorCount, 1)
        XCTAssertNotNil(host.canvas.visibleRange)
    }

    func testAHugeLineBreakParagraphTurnsPagesQuickly() throws {
        var lines: [String] = []
        var length = 0
        while length < 300_000 {
            let line = "\(lines.count) " + CanvasText.sentence(lines.count % 9 + 1, seed: lines.count)
            lines.append(line)
            length += line.utf16.count + 1
        }
        let host = host([CanvasText.body(lines.joined(separator: "\u{2028}"))])
        let start = Date()
        for _ in 0..<20 { XCTAssertEqual(host.canvas.turnPage(forward: true), .turned) }
        XCTAssertLessThan(Date().timeIntervalSince(start) / 20, 0.15, "per page turn, with generous room for a loaded machine")
        let column = host.canvas.textViews[0]
        XCTAssertLessThan(column.textLength - column.placement.visibleLength, 400, "a few lines of context, not the rest")
    }

    func testANarrowBookPoseSideGivesOneColumn() throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.division = CGRect(x: 455, y: 0, width: 41, height: 700)
        let host = host(sections(1, paragraphs: 20), size: CGSize(width: 571, height: 700), configuration: configuration)
        XCTAssertEqual(host.canvas.textViews.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(host.canvas.textViews.first).frame.maxX, 455)
        XCTAssertNotNil(host.canvas.visibleRange)
    }

    // MARK: Edge taps, focus

    func testEdgeTapsTurnPagesUnlessOnALinkOrASelection() throws {
        let text = NSMutableAttributedString(attributedString: NSAttributedString(string: "Linked", attributes: [
            .font: PlatformFont.systemFont(ofSize: 17), .link: ReaderLink.internal(href: "OPS/two.xhtml").url]))
        text.append(CanvasText.body(" " + CanvasText.sentence(900, seed: 1)))
        let host = host([text])
        let canvas = host.canvas, bounds = canvas.bounds
        let column = canvas.textViews[0]
        XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: bounds.maxX - 10, y: bounds.midY)), true)
        XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: bounds.minX + 10, y: bounds.midY)), false)
        XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.midX, y: bounds.midY)))
        // The link starts the first line, inside the left zone.
        let linkFrame = try XCTUnwrap(column.segmentFrames(for: NSRange(location: 0, length: 6)).first)
        let origin = column.containerOrigin
        let onLink = column.convert(CGPoint(x: linkFrame.midX + origin.x, y: linkFrame.midY + origin.y), to: canvas)
        XCTAssertLessThan(onLink.x, ReaderCanvasView.edgeZoneWidth)
        XCTAssertEqual(column.link(at: canvas.convert(onLink, to: column)), ReaderLink.internal(href: "OPS/two.xhtml").url)
        XCTAssertNil(canvas.edgeTurn(at: onLink), "the link keeps its tap")
        XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: onLink.x, y: onLink.y + 200)), false)
        canvas.configuration.isRightToLeft = true
        XCTAssertEqual(canvas.edgeTurn(at: CGPoint(x: bounds.maxX - 10, y: bounds.midY)), false, "mirrored")
        canvas.configuration.isRightToLeft = false
        column.selectedRange = NSRange(location: 10, length: 5)
        canvas.textViewSelectionDidChange(column)
        XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.maxX - 10, y: bounds.midY)), "a tap with a selection is the text's")
        #if os(iOS)
        let swipe = try XCTUnwrap(canvas.gestureRecognizers?.first { $0 is UISwipeGestureRecognizer })
        XCTAssertFalse(canvas.gestureRecognizerShouldBegin(swipe), "no swipe turns while text is selected")
        canvas.clearSelection()
        XCTAssertTrue(canvas.gestureRecognizerShouldBegin(swipe))
        #endif
        canvas.clearSelection()
        canvas.configuration.flow = .scrolled
        host.layOut()
        XCTAssertNil(canvas.edgeTurn(at: CGPoint(x: bounds.maxX - 10, y: bounds.midY)))
    }

    #if os(macOS)
    func testEdgeClicksTurnPages() throws {
        let host = host(sections(1, paragraphs: 30))
        let canvas = host.canvas
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let start = try XCTUnwrap(canvas.visibleRange?.start)
        // In the margin, beside the column.
        let margin = CGPoint(x: canvas.bounds.maxX - 5, y: canvas.bounds.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: margin))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: margin))
        let next = try XCTUnwrap(canvas.visibleRange?.start)
        XCTAssertGreaterThan(next, start)
        // Over the column's text, inside the zone: a click turns, a drag would select.
        let column = canvas.textViews[0]
        let onText = CGPoint(x: column.frame.maxX - 20, y: column.frame.minY + 40)
        XCTAssertNotNil(canvas.edgeTurn(at: onText))
        host.window.postEvent(mouse(.leftMouseUp, at: onText), atStart: false)
        column.mouseDown(with: mouse(.leftMouseDown, at: onText))
        XCTAssertGreaterThan(try XCTUnwrap(canvas.visibleRange?.start), next)
    }
    #endif

    func testChangingFlowKeepsKeyboardFocus() throws {
        let host = host(sections(1))
        let canvas = host.canvas
        canvas.focus(canvas.textViews.first)
        XCTAssertTrue(canvas.hasKeyboardFocus)
        canvas.configuration.flow = .scrolled
        host.layOut()
        XCTAssertTrue(canvas.hasKeyboardFocus)
        let scroll = try XCTUnwrap(canvas.scrollTextView)
        #if os(macOS)
        XCTAssertTrue(host.window.firstResponder === scroll)
        #else
        XCTAssertTrue(scroll.isFirstResponder)
        #endif
        canvas.configuration.flow = .paginated
        host.layOut()
        XCTAssertTrue(canvas.hasKeyboardFocus)
    }

    // MARK: Nonlinear sections, viewport

    func testBookTextMapsAroundOmittedSections() {
        let sections = (0..<5).map { NSAttributedString(string: String(repeating: "\($0)", count: 10)) }
        let book = CanvasText.book(sections, omitting: [1, 4])
        XCTAssertEqual(book.string.length, 3 * 10 + 2)
        XCTAssertFalse(book.contains(section: 1))
        XCTAssertFalse(book.contains(section: 4))
        XCTAssertTrue(book.contains(section: 2))
        for section in [0, 2, 3] {
            for offset in [0, 5, 10] {
                let position = ReaderTextPosition(section: section, offset: offset)
                XCTAssertEqual(book.position(at: book.location(of: position)), position)
            }
        }
        XCTAssertEqual(book.position(at: book.string.length), ReaderTextPosition(section: 3, offset: 10))
        XCTAssertEqual(book.position(at: 10), ReaderTextPosition(section: 0, offset: 10), "the separator ends section 0")
    }

    func testWholeBookLeavesOutNonlinearSectionsAndShowsThemAlone() throws {
        let all = sections(3, paragraphs: 2)
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        let host = host(all, linear: [true, false, true], configuration: configuration, show: nil)
        host.source.book = CanvasText.book(all.compactMap { $0 }, omitting: [1])
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        XCTAssertNotNil(host.canvas.scrollBook)
        host.canvas.show(ReaderTextPosition(section: 1, offset: 100), selecting: nil)
        XCTAssertNil(host.canvas.scrollBook, "a nonlinear section shows on its own")
        XCTAssertEqual(host.canvas.scrollTextView?.placement.section, 1)
        XCTAssertEqual(host.canvas.visibleRange?.start.section, 1)
        var turns = 0
        while host.canvas.visibleRange?.start.section == 1, turns < 50 {
            XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
            turns += 1
        }
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 2, offset: 0))
        XCTAssertNotNil(host.canvas.scrollBook, "back in the whole book")
        host.canvas.reloadContent(keeping: ReaderTextPosition(section: 1, offset: 0))
        XCTAssertNil(host.canvas.scrollBook)
    }

    func testScrollViewportFollowsTheSafeArea() throws {
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = .scrolled
        let host = host(sections(1), configuration: configuration)
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        let before = view.readerContainer.viewportSize.height
        XCTAssertGreaterThan(before, 0)
        #if os(iOS)
        host.controller.additionalSafeAreaInsets = UIEdgeInsets(top: 60, left: 0, bottom: 40, right: 0)
        #else
        let scrollView = try XCTUnwrap(host.canvas.scrollContainer as? NSScrollView)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: scrollView.contentInsets.top + 60, left: 0,
                                                bottom: scrollView.contentInsets.bottom + 40, right: 0)
        host.canvas.needsLayout = true
        #endif
        host.layOut()
        XCTAssertEqual(view.readerContainer.viewportSize.height, before - 100, accuracy: 1)
    }

    // MARK: Performance

    func testLongSectionOpensAndTurnsQuickly() throws {
        let paragraph = CanvasText.sentence(130, seed: 9)
        let text = NSMutableAttributedString()
        while text.length < 1_000_000 { text.append(CanvasText.body(paragraph + "\n")) }
        var start = Date()
        let host = host([text])
        let open = Date().timeIntervalSince(start)
        XCTAssertLessThan(open, 1)
        start = Date()
        for _ in 0..<20 { XCTAssertEqual(host.canvas.turnPage(forward: true), .turned) }
        let turns = Date().timeIntervalSince(start) / 20
        XCTAssertLessThan(turns, 0.15)
        start = Date()
        host.canvas.show(ReaderTextPosition(section: 0, offset: text.length - 10), selecting: nil)
        let end = Date().timeIntervalSince(start)
        XCTAssertLessThan(end, 3)
        print("1 MB section: open \(open) s, turn \(turns) s, show end \(end) s")
    }

    func testWholeBookScrollsQuickly() throws {
        let sections = (0..<300).map { CanvasText.section($0, chapters: 1, paragraphs: 30) as NSAttributedString? }
        var start = Date()
        let host = scrolledHost(sections, book: true, show: ReaderTextPosition(section: 150, offset: 100))
        let open = Date().timeIntervalSince(start)
        let length = try XCTUnwrap(host.canvas.scrollBook).string.length
        XCTAssertGreaterThan(length, 3_000_000)
        XCTAssertEqual(host.canvas.visibleRange?.start.section, 150)
        start = Date()
        for _ in 0..<30 { XCTAssertEqual(host.canvas.turnPage(forward: true), .turned) }
        let turns = Date().timeIntervalSince(start) / 30
        start = Date()
        host.canvas.show(ReaderTextPosition(section: 290, offset: 0), selecting: nil)
        let jump = Date().timeIntervalSince(start)
        XCTAssertEqual(host.canvas.visibleRange?.start.section, 290)
        XCTAssertLessThan(open, 5)
        XCTAssertLessThan(turns, 0.25)
        XCTAssertLessThan(jump, 1)
        print("\(length) characters in 300 sections: open \(open) s, viewport step \(turns) s, jump \(jump) s")
    }
}

extension ReaderTextView {
    var isScrollEnabledForReader: Bool {
        #if os(macOS)
        enclosingScrollView != nil
        #else
        isScrollEnabled
        #endif
    }
}
