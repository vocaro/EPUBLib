import CoreGraphics
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Uses the actual native AX entry points, rather than assuming a bounded AXValue bounds
/// VoiceOver's separately indexed line and attributed-text requests.
@MainActor final class PageAccessibilityTests: XCTestCase {
    private var hosts: [CanvasHost] = []
    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }
    private func host(_ text: NSAttributedString, size: CGSize = CGSize(width: 420, height: 350)) -> CanvasHost {
        let host = CanvasHost(FakeCanvasSource([text]), size: size)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        host.layOut()
        return host
    }
    #if os(macOS)
    func testNativeAccessibilityRejectsContinuationTextAndLines() throws {
        let host = host(CanvasText.body(CanvasText.sentence(700, seed: 3)))
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let length = view.placement.visibleLength
        XCTAssertGreaterThan(view.textLength, length, "must actually contain clipped continuation context")
        XCTAssertEqual(view.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: length))
        XCTAssertNil(view.accessibilityString(for: NSRange(location: length, length: 1)))
        XCTAssertNil(view.accessibilityAttributedString(for: NSRange(location: 0, length: length + 1)))
        XCTAssertNil(view.accessibilityRTF(for: NSRange(location: length, length: 1)))
        XCTAssertEqual(view.accessibilityRange(for: length).location, NSNotFound)
        XCTAssertEqual(view.accessibilityStyleRange(for: length).location, NSNotFound)
        var line = 0, ranges: [NSRange] = []
        while line < 100 {
            let range = view.accessibilityRange(forLine: line)
            if range.location == NSNotFound { break }
            XCTAssertLessThanOrEqual(NSMaxRange(range), length)
            ranges.append(range)
            line += 1
        }
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertEqual(NSMaxRange(try XCTUnwrap(ranges.last)), length)
        XCTAssertEqual(ranges.map { view.accessibilityString(for: $0) ?? "" }.joined(), view.visibleText)
        // VoiceOver counts visible lines from the page's end insertion point, and re-enters a
        // column at an offset it kept from a longer previous page. Both stay on the last line.
        XCTAssertEqual(view.accessibilityLine(for: length), ranges.count - 1)
        XCTAssertEqual(view.accessibilityLine(for: view.textLength), ranges.count - 1)
        XCTAssertEqual(view.accessibilityLine(for: -1), NSNotFound)
        view.setAccessibilitySelectedTextRange(NSRange(location: view.textLength, length: 0))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: length, length: 0))
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), ranges.count - 1)
    }
    #endif
}

extension PageAccessibilityTests {
    private func accessibleText(_ view: ReaderTextView) throws -> String {
        #if os(macOS)
        var result = "", index = 0
        while index < 200 {
            let range = view.accessibilityRange(forLine: index)
            if range.location == NSNotFound { break }
            XCTAssertGreaterThan(range.length, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(range), view.shownCharacters.length)
            result += try XCTUnwrap(view.accessibilityString(for: range))
            index += 1
        }
        return result
        #else
        XCTAssertFalse(view.isAccessibilityElement, "the native text element must not traverse hidden storage")
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(view.accessibilityElementCount(), elements.count)
        XCTAssertNil(view.accessibilityElement(at: elements.count))
        for (index, element) in elements.enumerated() {
            XCTAssertTrue(element.accessibilityContainer as? ReaderTextView === view)
            XCTAssertEqual(view.index(ofAccessibilityElement: element), index)
            XCTAssertTrue(view.accessibilityElement(at: index) as? UIAccessibilityElement === element)
            XCTAssertFalse(element.accessibilityFrameInContainerSpace.isNull)
            XCTAssertTrue((element.accessibilityCustomActions ?? []).map(\.name).contains("Next Page"))
            XCTAssertTrue((element.accessibilityCustomActions ?? []).map(\.name).contains("Previous Page"))
        }
        return elements.map { $0.accessibilityLabel ?? "" }.joined()
        #endif
    }

    func testPageLineReadingOrderAcrossSpreadsAndTypography() throws {
        for size in [CGSize(width: 420, height: 350), CGSize(width: 1100, height: 420)] {
            for fontSize: CGFloat in [17, 25] {
                let text = CanvasText.body((0..<700).map { "word\($0)" }.joined(separator: " "),
                    style: CanvasText.bodyStyle(alignment: .justified), size: fontSize)
                let host = host(text, size: size)
                XCTAssertEqual(host.canvas.textViews.count, size.width > 1000 ? 2 : 1)
                var spoken = "", turns = 0
                repeat {
                    for view in host.canvas.textViews where !view.isHidden {
                        let shown = try accessibleText(view)
                        XCTAssertEqual(shown, view.visibleText)
                        spoken += shown
                    }
                    turns += 1
                    XCTAssertLessThan(turns, 100)
                } while turns < 100 && host.canvas.turnPage(forward: true) == .turned
                XCTAssertEqual(spoken, text.string, "every source character is exposed once on its own page")
            }
        }
    }

    func testLinksAndAttachmentLabelsRemainAccessible() throws {
        let text = NSMutableAttributedString(attributedString: CanvasText.body("Follow link then "))
        let link = URL(string: "https://example.org/visible")!
        text.addAttribute(.link, value: ReaderLink.external(link.absoluteString).url,
            range: NSRange(location: 7, length: 4))
        let formula = TextualTestAttachment()
        formula.textEquivalent = "E = mc²"
        formula.image = (CanvasText.attachment(size: CGSize(width: 40, height: 20))
            .attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
        formula.bounds = CGRect(x: 0, y: 0, width: 40, height: 20)
        text.append(NSAttributedString(attachment: formula))
        text.append(CanvasText.body(" before " + CanvasText.sentence(700, seed: 0)))
        let host = host(text)
        let view = try XCTUnwrap(host.canvas.textViews.first)
        #if os(macOS)
        let attributed = try XCTUnwrap(view.accessibilityAttributedString(for: view.shownCharacters))
        let attachment = try XCTUnwrap(attributed.attribute(.accessibilityAttachment, at: 17, effectiveRange: nil) as? NSAccessibilityElement)
        XCTAssertEqual(attachment.accessibilityLabel(), formula.textEquivalent)
        // AppKit's native attributed-text link metadata is preserved by the bounded query.
        XCTAssertNotNil(attributed.attribute(NSAttributedString.Key("AXLink"), at: 7, effectiveRange: nil))
        #else
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" }.joined(), view.visibleText)
        let linkElement = try XCTUnwrap(elements.first { $0.accessibilityTraits.contains(.link) })
        XCTAssertEqual(linkElement.accessibilityLabel, "link")
        XCTAssertTrue(linkElement.accessibilityActivate())
        XCTAssertEqual(host.recorder.links.last?.position, ReaderTextPosition(section: 0, offset: 7))
        XCTAssertEqual(host.recorder.links.last?.link, .external(link.absoluteString))
        XCTAssertTrue(elements.contains { $0.accessibilityLabel == "E = mc²" && $0.accessibilityTraits.contains(.image) })
        let next = try XCTUnwrap(elements.first?.accessibilityCustomActions?.first { $0.name == "Next Page" })
        let before = view.placement.offset
        XCTAssertTrue(try XCTUnwrap(next.actionHandler)(next))
        XCTAssertGreaterThan(try XCTUnwrap(host.canvas.textViews.first).placement.offset, before)
        let previous = try XCTUnwrap(host.canvas.textViews.first?.accessibilityElements?.first as? UIAccessibilityElement)
        let action = try XCTUnwrap(previous.accessibilityCustomActions?.first { $0.name == "Previous Page" })
        XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action))
        XCTAssertEqual(host.canvas.textViews.first?.placement.offset, before)
        #endif
    }

    #if os(iOS)
    func testVoiceOverReadsSpreadColumnsInSourceOrder() throws {
        for rtl in [false, true] {
            let text = CanvasText.body((0..<900).map { String(format: "word%04d", $0) }.joined(separator: " "))
            let host = CanvasHost(FakeCanvasSource([text]), size: CGSize(width: 1100, height: 420),
                                  configuration: ReaderCanvasConfiguration(isRightToLeft: rtl))
            hosts.append(host)
            host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            host.layOut()
            // Geometry alone puts a lower or right-hand column second; the reading order is the source's.
            let columns = try XCTUnwrap(host.canvas.accessibilityElements as? [ReaderTextView])
            XCTAssertEqual(columns.count, 2)
            XCTAssertLessThan(columns[0].placement.offset, columns[1].placement.offset)
            XCTAssertEqual(columns[0].frame.minX < columns[1].frame.minX, !rtl)
            XCTAssertFalse(host.canvas.isAccessibilityElement)
            host.canvas.configuration.flow = .scrolled
            host.layOut()
            XCTAssertNil(host.canvas.accessibilityElements, "continuous scroll keeps UIKit's own traversal")
        }
    }

    func testLayoutOnlyParagraphMetadataDoesNotSplitAccessibleLinesOrInventHeadings() throws {
        let text = NSMutableAttributedString(attributedString:
            CanvasText.body("An ordinary body paragraph " + CanvasText.sentence(200, seed: 0)))
        text.addAttributes([.readerKeepWithNext: true, .readerPageBreakBefore: true],
            range: NSRange(location: 0, length: 1))
        // A decoration difference is also not a new reading unit.
        text.addAttribute(.foregroundColor, value: UIColor.red, range: NSRange(location: 8, length: 3))
        let host = host(text)
        let view = try XCTUnwrap(host.canvas.textViews.first)
        let lines = view.pageAccessibilityLines
        let elements = try XCTUnwrap(view.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(elements.count, lines.count)
        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" }, lines.map { view.plainText(in: $0.range) })
        XCTAssertTrue(elements.allSatisfy { $0.accessibilityTraits.contains(.staticText) })
        XCTAssertFalse(elements.contains { $0.accessibilityTraits.contains(.header) },
            "pagination's keep-with-next flag does not imply a semantic heading")
        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" }.joined(), view.visibleText)
    }
    #endif

    #if os(macOS)
    func testNewAndReusedColumnsStartAccessibilityAtFirstLineAndResolveScreenPoints() throws {
        let text = CanvasText.body((0..<900).map { String(format: "word%04d", $0) }.joined(separator: " "))
        // Keep the window unordered so this test does not interrupt a user's live
        // VoiceOver session. A window association suffices for native screen conversions.
        let canvas = ReaderCanvasView(frame: .zero)
        let source = FakeCanvasSource([text])
        let recorder = CanvasRecorder()
        canvas.dataSource = source
        canvas.delegate = recorder
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(canvas.textViews.count, 2)
        for spread in 0..<3 {
            for (column, view) in canvas.textViews.enumerated() where !view.isHidden {
                let lines = view.pageAccessibilityLines
                XCTAssertGreaterThan(lines.count, 3)
                XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0),
                    "installing a page must not leave the native caret in hidden continuation storage")
                XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
                XCTAssertEqual(view.accessibilityValue(), view.visibleText,
                    "the value announced after installation must reflect the new visible page")
                XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 0,
                    "VoiceOver should enter a newly installed page at its first line")
                for index in [0, lines.count / 2, lines.count - 1] {
                    let line = lines[index]
                    let local = CGRect(x: line.frame.minX + view.containerOrigin.x + 2,
                        y: line.frame.midY + view.containerOrigin.y, width: 1, height: 1)
                    let screen = NSAccessibility.screenRect(fromView: view, rect: local)
                    let range = view.accessibilityRange(for: CGPoint(x: screen.midX, y: screen.midY))
                    XCTAssertTrue(NSLocationInRange(range.location, line.range),
                        "screen point must resolve in its own visible line, column \(column), line \(index)")
                    XCTAssertEqual(view.accessibilityLine(for: range.location), index)
                }
                let middle = lines[lines.count / 2].range.location
                view.setAccessibilitySelectedTextRange(NSRange(location: middle, length: 0))
                XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), lines.count / 2,
                    "an intentional visible caret must remain where the user put it")
                view.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 0))
                XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 0)
                XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 0))
                XCTAssertFalse(window.isVisible)
            }
            XCTAssertEqual(canvas.turnPage(forward: true), .turned)
        }
        // Installing replacement page storage resets its incidental native caret, then the
        // canvas must reinstate an intentional passage selection in source coordinates.
        let view = try XCTUnwrap(canvas.textViews.last)
        let local = NSRange(location: view.pageAccessibilityLines[2].range.location, length: 12)
        let position = ReaderTextPosition(section: 0, offset: view.placement.offset + local.location)
        let passage = ReaderTextRange(section: 0, position.offset..<(position.offset + local.length))
        canvas.show(position, selecting: passage)
        XCTAssertEqual(canvas.currentSelection?.range, passage)
        canvas.reloadContent(keeping: position)
        XCTAssertEqual(canvas.currentSelection?.range, passage)
        let selectedView = try XCTUnwrap(canvas.textViews.first { $0.selectedRange.length > 0 })
        let nativeRange = NSRange(location: selectedView.pageAccessibilityLines[4].range.location, length: 10)
        selectedView.selectedRange = nativeRange
        canvas.textViewSelectionDidChange(selectedView)
        let nativePassage = try XCTUnwrap(canvas.currentSelection?.range)
        canvas.reloadContent(keeping: nativePassage.start)
        XCTAssertEqual(canvas.currentSelection?.range, nativePassage)
        XCTAssertFalse(window.isVisible)
    }

    /// VoiceOver comes back to a column it has left at the text offset it had on the page before
    /// unless the spread's layout change is posted by the element that holds the columns, and
    /// not by the window (#337). What VoiceOver does with it is heard only in a speech session
    /// (doc/voiceover-testing.md); this holds the notification to that shape.
    func testASpreadsLayoutChangeIsPostedByTheElementHoldingItsColumns() throws {
        let text = CanvasText.body((0..<900).map { String(format: "word%04d", $0) }.joined(separator: " "))
        func reader() -> (canvas: ReaderCanvasView, source: FakeCanvasSource, recorder: CanvasRecorder) {
            let canvas = ReaderCanvasView(frame: .zero), source = FakeCanvasSource([text]), recorder = CanvasRecorder()
            canvas.dataSource = source
            canvas.delegate = recorder
            return (canvas, source, recorder)
        }
        typealias Posted = (element: AnyObject, notification: NSAccessibility.Notification, named: [AnyObject])
        /// The notifications of each page turn: forward twice, then back.
        func turns(_ canvas: ReaderCanvasView, in window: NSWindow) throws -> [Posted] {
            var posted: [Posted] = [], all: [Posted] = []
            canvas.postAccessibilityNotification = { element, notification, userInfo in
                posted.append((element as AnyObject, notification, userInfo[.uiElements] as? [AnyObject] ?? []))
            }
            canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(canvas.textViews.count, 2)
            for forward in [true, true, false] {
                posted.removeAll()
                XCTAssertEqual(canvas.turnPage(forward: forward), .turned)
                XCTAssertEqual(posted.count, 1, "one notification for a page turn")
                let change = try XCTUnwrap(posted.first)
                XCTAssertEqual(change.notification, .layoutChanged)
                XCTAssertEqual(change.named.map(ObjectIdentifier.init), canvas.textViews.map(ObjectIdentifier.init),
                               "the change names the visible columns")
                all.append(change)
            }
            // Unordered, so a live VoiceOver session on this Mac hears nothing of it.
            XCTAssertFalse(window.isVisible)
            return all
        }
        let frame = CGRect(x: 0, y: 0, width: 1100, height: 500)
        // As in a host's interface, where the columns share a group with its controls.
        let hosted = reader()
        let group = NSView(frame: frame)
        group.setAccessibilityElement(true)
        group.setAccessibilityRole(.group)
        hosted.canvas.frame = group.bounds
        hosted.canvas.autoresizingMask = [.width, .height]
        group.addSubview(hosted.canvas)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = group
        defer { window.contentView = nil; window.close() }
        for change in try turns(hosted.canvas, in: window) {
            XCTAssertTrue(change.element === group, "posted by \(change.element), not by the group that holds the columns")
        }
        // With nothing between the canvas and its window, the window holds the columns.
        let alone = reader()
        let bare = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        bare.isReleasedWhenClosed = false
        bare.contentView = alone.canvas
        defer { bare.contentView = nil; bare.close() }
        for change in try turns(alone.canvas, in: bare) {
            XCTAssertTrue(change.element === bare, "posted by \(change.element), not by the window")
        }
    }

    func testPageAccessibilitySelectionCannotReachContinuationAndComposedCharactersStayWhole() throws {
        let host = host(CanvasText.body(String(repeating: "Hello 👨‍👩‍👧‍👦 e\u{301} world. ", count: 150)))
        let view = try XCTUnwrap(host.canvas.textViews.first)
        view.selectedRange = NSRange(location: 2, length: 4)
        let before = view.selectedRange
        view.setAccessibilitySelectedTextRange(NSRange(location: view.shownCharacters.length, length: 1))
        XCTAssertEqual(view.selectedRange, before)
        view.setAccessibilitySelectedTextRanges([NSValue(range: NSRange(location: view.shownCharacters.length, length: 1))])
        XCTAssertEqual(view.selectedRange, before)
        let text = try XCTUnwrap(view.contentStorage.textStorage).string as NSString
        for index in 0..<view.shownCharacters.length {
            let range = view.accessibilityRange(for: index)
            XCTAssertEqual(range, text.rangeOfComposedCharacterSequence(at: index))
            XCTAssertLessThanOrEqual(NSMaxRange(range), view.shownCharacters.length)
        }
        XCTAssertEqual(view.accessibilityFrame(for: NSRange(location: view.shownCharacters.length, length: 1)), .zero)
        XCTAssertNil(view.accessibilityString(for: NSRange(location: NSNotFound, length: 1)))
    }
    #endif
}
