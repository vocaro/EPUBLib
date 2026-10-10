import EPUBCore
import EPUBReading
import EPUBTestSupport
import ImageIO
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class ReaderSpreadSelectionTests: XCTestCase {
    private func host(rtl: Bool = false) -> CanvasHost {
        var configuration = ReaderCanvasConfiguration()
        configuration.isRightToLeft = rtl
        configuration.selectionActionTitle = "Save passage"
        let host = CanvasHost(FakeCanvasSource([CanvasText.section(0, chapters: 1, paragraphs: 30)]),
                              size: CGSize(width: 1000, height: 600), configuration: configuration)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        return host
    }

    private func assertSelection(_ host: CanvasHost, _ range: ReaderTextRange, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(host.source.sections[0])
        let expected = source.readerPlainText(in: NSRange(location: range.start.offset, length: range.end.offset - range.start.offset))
        XCTAssertEqual(host.canvas.currentSelection, ReaderSelection(range: range, text: expected), file: file, line: line)
        for view in host.canvas.columns where !view.isHidden {
            if let local = host.canvas.localRange(of: range, in: view) {
                XCTAssertEqual(view.selectedRange, local, file: file, line: line)
                XCTAssertEqual(host.canvas.selectionText(for: view), expected, file: file, line: line)
                #if os(macOS)
                let pasteboard = NSPasteboard.withUniqueName()
                XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string), file: file, line: line)
                XCTAssertEqual(pasteboard.string(forType: .string), expected, file: file, line: line)
                pasteboard.releaseGlobally()
                #else
                view.pasteboard = UIPasteboard.withUniqueName()
                view.copy(nil)
                XCTAssertEqual(view.pasteboard.string, expected, file: file, line: line)
                #endif
            } else { XCTAssertEqual(view.selectedRange.length, 0, file: file, line: line) }
        }
    }

    func testCrossColumnSelectionCopyDelayedDelegateHostActionAndRelayout() async throws {
        for rtl in [false, true] {
            let host = host(rtl: rtl)
            defer { host.close() }
            XCTAssertEqual(host.canvas.columns.count, 2)
            let boundary = host.canvas.columns[1].placement.offset
            let range = ReaderTextRange(section: 0, (boundary - 37)..<(boundary + 43))
            host.canvas.show(range.start, selecting: range)
            try assertSelection(host, range)
            // UIKit/AppKit can deliver selection delegate notifications after setters return.
            for view in host.canvas.columns { host.canvas.textViewSelectionDidChange(view) }
            try assertSelection(host, range)
            host.canvas.performSelectionAction()
            XCTAssertEqual((host.recorder.selections.last ?? nil)?.range, range)
            XCTAssertEqual(host.recorder.actions, 1)
            let shown = host.canvas.visibleRange
            host.canvas.turnPageFromInput(forward: true)
            XCTAssertEqual(host.canvas.visibleRange, shown, "selection prevents keys/wheel/swipes/edge taps paging")
            #if os(iOS)
            XCTAssertFalse(host.canvas.accessibilityScroll(.next))
            for view in host.canvas.columns { XCTAssertEqual(view.accessibilityValue, view.visibleText) }
            #else
            for view in host.canvas.columns { XCTAssertEqual(view.accessibilityNumberOfCharacters(), view.placement.visibleLength) }
            #endif
            host.resize(to: CGSize(width: 1100, height: 650))
            try assertSelection(host, range)
            var style = host.canvas.configuration
            style.flow = .scrolled
            host.canvas.configuration = style
            XCTAssertEqual(host.canvas.currentSelection?.range, range)
            style.flow = .paginated
            host.canvas.configuration = style
            try assertSelection(host, range)
            host.canvas.clearSelection()
            XCTAssertFalse(host.canvas.hasSelection)
            XCTAssertTrue(host.canvas.columns.allSatisfy { $0.selectedRange.length == 0 })
        }
    }

    func testLocatedSelectionAcrossSpreadContinuesAndKeepsHighlights() throws {
        let host = host()
        defer { host.close() }
        let end = try XCTUnwrap(host.canvas.visibleRange).end.offset
        let range = ReaderTextRange(section: 0, (end - 45)..<(end + 97))
        host.canvas.setHighlights([ReaderHighlight(id: "saved", range: range, kind: .annotation),
                                  ReaderHighlight(id: "found", range: range, kind: .search)])
        host.canvas.show(range.start, selecting: range)
        try assertSelection(host, range)
        XCTAssertTrue(host.canvas.subviews.contains { $0 is ReaderSelectionContinuation })
        try snapshot(host.canvas, name: "located-before-continuation")
        XCTAssertEqual(host.canvas.turnPage(forward: true), .turned)
        try assertSelection(host, range)
        XCTAssertTrue(host.canvas.subviews.contains { $0 is ReaderSelectionContinuation })
        XCTAssertEqual(host.canvas.columns.first?.selectedRange, NSRange(location: 0, length: 97))
        for view in host.canvas.columns where view.selectedRange.length > 0 {
            var found = false
            view.readerLayoutManager.enumerateRenderingAttributes(from: view.readerLayoutManager.documentRange.location, reverse: false) { _, attributes, _ in
                if attributes[.backgroundColor] != nil { found = true }
                return true
            }
            XCTAssertTrue(found, "search/saved highlights continue with source selection")
        }
        try snapshot(host.canvas, name: "located-continuation")
        XCTAssertEqual(host.canvas.turnPage(forward: false), .turned)
        try assertSelection(host, range)
        host.canvas.clearSelection()
        XCTAssertFalse(host.canvas.subviews.contains { $0 is ReaderSelectionContinuation })
    }

    func testFullDraggedRangeCFIRoundTripsForSavedHighlightAndLocate() async throws {
        let words = (0..<1800).map { "word\($0)" }.joined(separator: " ")
        let data = try Fixture.epub(overrides: ["OPS/one.xhtml":
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Spread</title></head><body><p>\(words)</p></body></html>"])
        let publication = try EPUBPublication.open(data: data)
        var chosen: EPUBSelection?
        var events = [EPUBReaderEvent]()
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication,
            selectionAction: EPUBSelectionAction(title: "Save") { chosen = $0 }) { events.append($0) } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        window.resize(to: CGSize(width: 1000, height: 600))
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() {
                guard Date() < deadline else { XCTFail("Selection state did not settle"); return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await wait { session.isReady && session.canvas?.columns.count == 2 }
        let canvas = try XCTUnwrap(session.canvas)
        let boundary = canvas.columns[1].placement.offset
        let range = ReaderTextRange(section: 0, (boundary - 28)..<(boundary + 38))
        canvas.beginSelectionDrag(at: range.start)
        canvas.extendSelectionDrag(to: range.end)
        canvas.endSelectionDrag()
        canvas.performSelectionAction()
        let selected = try XCTUnwrap(chosen)
        XCTAssertEqual(selected.text, canvas.currentSelection?.text)
        let bookmark = try XCTUnwrap(selected.location.bookmark)
        XCTAssertTrue(bookmark.value.contains(","), "the bookmark carries both full range endpoints")
        XCTAssertEqual(session.selection?.range, range)
        let saved = try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(selected.location))
        try await session.send(.setHighlights([EPUBHighlight(id: "saved-spread", location: saved)]))
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "saved-spread" }?.range, range)
        try await session.send(.style(.init(fontSize: 23, isDark: true)))
        try await wait { session.book.isComplete && canvas.currentSelection?.range == range }
        try await session.send(.setHighlights([EPUBHighlight(id: "saved-spread", location: saved)]))
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "saved-spread" }?.range, range)
        try await session.send(.locate(text: selected.text, highlight: true))
        try await wait { session.selection?.range == range }
        XCTAssertEqual(canvas.currentSelection?.text, selected.text)
        for view in canvas.columns where view.selectedRange.length > 0 {
            XCTAssertEqual(canvas.selectionText(for: view), selected.text)
        }
        XCTAssertTrue(events.contains { if case .selectionChanged(let value) = $0 { return value?.text == selected.text }; return false })
    }

    #if os(macOS)
    func testNativeCellOriginDragCrossesIntoBodyAndContinuedCellColumn() async throws {
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        for continuedCell in [false, true] {
            let table = "<table border='1'><tr><td>\(continuedCell ? words : "Origin cell has selectable words.")</td><td>Other cell.</td></tr></table>"
            let data = try Fixture.epub(overrides: ["OPS/one.xhtml":
                "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Cells</title></head><body>\(table)<p>\(words)</p></body></html>"])
            let publication = try EPUBPublication.open(data: data)
            var chosen: EPUBSelection?
            let session = try NativeSession(publication: publication,
                action: EPUBSelectionAction(title: "Save") { chosen = $0 }, rich: NativeRichContent(), onEvent: { _ in })
            let window = ReaderTestWindow(session: session)
            defer { session.close(); window.close() }
            window.resize(to: CGSize(width: 1000, height: 600))
            let deadline = Date().addingTimeInterval(15)
            while session.canvas?.columns.count != 2 || session.canvas?.columns.first?.tableInteraction?.cells.isEmpty != false {
                guard Date() < deadline else { XCTFail("Missing native table columns"); return }
                try await Task.sleep(for: .milliseconds(20))
            }
            let canvas = try XCTUnwrap(session.canvas)
            let first = canvas.columns[0], last = canvas.columns[1]
            let cell = try XCTUnwrap(first.tableInteraction?.cells.values.first {
                $0.cellText.string.hasPrefix(continuedCell ? "word0" : "Origin")
            })
            let startPoint = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: canvas)
            let endPoint: CGPoint
            if continuedCell {
                let target = try XCTUnwrap(last.tableInteraction?.cells.values.first { $0.cellText.string.hasPrefix("word0") })
                endPoint = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: canvas)
            } else {
                let frame = try XCTUnwrap(last.segmentFrames(for: NSRange(location: 25, length: 1)).first)
                endPoint = last.convert(CGPoint(x: frame.midX, y: frame.midY), to: canvas)
            }
            let start = try XCTUnwrap(canvas.selectionPosition(at: startPoint))
            let end = try XCTUnwrap(canvas.selectionPosition(at: endPoint))
            XCTAssertNotNil(start.tableCell)
            if continuedCell { XCTAssertNotNil(end.tableCell) } else { XCTAssertNil(end.tableCell) }
            let range = ReaderTextRange(start: min(start, end), end: max(start, end))
            func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            NSApplication.shared.postEvent(try event(.leftMouseDragged, point: endPoint), atStart: false)
            NSApplication.shared.postEvent(try event(.leftMouseUp, point: endPoint), atStart: false)
            cell.mouseDown(with: try event(.leftMouseDown, point: startPoint))
            canvas.performSelectionAction()
            XCTAssertEqual(canvas.currentSelection?.range, range)
            XCTAssertEqual(session.selection?.range, range)
            XCTAssertEqual(chosen?.text, session.selectionText(in: range))
            let pasteboard = NSPasteboard.withUniqueName()
            XCTAssertTrue(cell.writeSelection(to: pasteboard, type: .string))
            XCTAssertEqual(pasteboard.string(forType: .string), chosen?.text)
            pasteboard.releaseGlobally()
            let selected = try XCTUnwrap(chosen)
            try await session.send(.setHighlights([EPUBHighlight(id: "cell-spread", location: selected.location)]))
            XCTAssertEqual(session.drawnHighlights.first { $0.id == "cell-spread" }?.range, range)
            try snapshot(canvas, name: continuedCell ? "cell-to-cell" : "cell-to-body")
        }
    }
    #endif

    #if os(macOS)
    func testNativeMouseDragAcrossColumnsInBothReadingDirections() throws {
        for rtl in [false, true] {
            let host = host(rtl: rtl)
            defer { host.close() }
            let first = host.canvas.columns[0], last = host.canvas.columns[1]
            let startFrame = try XCTUnwrap(first.segmentFrames(for: NSRange(location: first.placement.visibleLength - 30, length: 1)).first)
            let endFrame = try XCTUnwrap(last.segmentFrames(for: NSRange(location: 35, length: 1)).first)
            let startPoint = first.convert(CGPoint(x: startFrame.midX, y: startFrame.midY), to: host.canvas)
            let endPoint = last.convert(CGPoint(x: endFrame.midX, y: endFrame.midY), to: host.canvas)
            let start = try XCTUnwrap(host.canvas.selectionPosition(at: startPoint))
            let end = try XCTUnwrap(host.canvas.selectionPosition(at: endPoint))
            let range = ReaderTextRange(start: min(start, end), end: max(start, end))
            func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.canvas.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: host.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            NSApplication.shared.postEvent(try event(.leftMouseDragged, point: endPoint), atStart: false)
            NSApplication.shared.postEvent(try event(.leftMouseUp, point: endPoint), atStart: false)
            first.mouseDown(with: try event(.leftMouseDown, point: startPoint))
            XCTAssertFalse(host.canvas.isDraggingSelection)
            try assertSelection(host, range)
            first.canvas?.textViewSelectionDidChange(first)
            try assertSelection(host, range)
            try snapshot(host.canvas, name: rtl ? "drag-rtl" : "drag-ltr")
        }
    }
    #else
    func testUIKitNativeSelectionBridgeCrossesColumnAndExtendsHandle() throws {
        let host = host()
        defer { host.close() }
        let first = host.canvas.columns[0], last = host.canvas.columns[1]
        let boundary = last.placement.offset
        let original = ReaderTextRange(section: 0, (boundary - 30)..<(boundary - 10))
        host.canvas.show(original.start, selecting: original)
        let bridge = ReaderSpreadSelectionGestureDelegate(view: first)
        let press = SimulatedSelectionPress(canvas: host.canvas)
        let startFrame = try XCTUnwrap(first.segmentFrames(for: NSRange(location: first.placement.visibleLength - 20, length: 1)).first)
        let endFrame = try XCTUnwrap(last.segmentFrames(for: NSRange(location: 25, length: 1)).first)
        press.point = first.convert(CGPoint(x: startFrame.midX, y: startFrame.midY), to: host.canvas)
        let anchor = try XCTUnwrap(host.canvas.selectionPosition(at: press.point))
        XCTAssertTrue(bridge.gestureRecognizerShouldBegin(press))
        press.phase = .began; bridge.drag(press)
        press.point = last.convert(CGPoint(x: endFrame.midX, y: endFrame.midY), to: host.canvas)
        let end = try XCTUnwrap(host.canvas.selectionPosition(at: press.point))
        press.phase = .changed; bridge.drag(press)
        press.phase = .ended; bridge.drag(press)
        let range = ReaderTextRange(start: anchor, end: end)
        try assertSelection(host, range)
        for view in host.canvas.columns { host.canvas.textViewSelectionDidChange(view) }
        try assertSelection(host, range)
        // Dragging an existing native selection handle fixes the opposite endpoint.
        host.canvas.show(original.start, selecting: original)
        let pan = SimulatedSelectionPan(canvas: host.canvas)
        let handleFrame = try XCTUnwrap(first.segmentFrames(for: NSRange(location: first.placement.visibleLength - 10, length: 1)).first)
        pan.point = first.convert(CGPoint(x: handleFrame.midX, y: handleFrame.midY), to: host.canvas)
        XCTAssertTrue(bridge.gestureRecognizerShouldBegin(pan))
        pan.phase = .began; bridge.drag(pan)
        pan.point = press.point
        pan.phase = .changed; bridge.drag(pan)
        pan.phase = .ended; bridge.drag(pan)
        try assertSelection(host, ReaderTextRange(start: original.start, end: end))
        XCTAssertTrue(first.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer && $0.delegate is ReaderSpreadSelectionGestureDelegate } == true)
        XCTAssertTrue(first.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer && $0.delegate is ReaderSpreadSelectionGestureDelegate } == true)
        try snapshot(host.canvas, name: "touch-column-selection")
    }
    func testUIKitCellOriginBridgeRejectsBodyAncestorAndCopiesFullCellRange() async throws {
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let data = try Fixture.epub(overrides: ["OPS/one.xhtml":
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Cells</title></head><body><table border='1'><tr><td>\(words)</td><td>Other cell.</td></tr></table></body></html>"])
        let publication = try EPUBPublication.open(data: data)
        let session = try NativeSession(publication: publication, action: nil, rich: NativeRichContent(), onEvent: { _ in })
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        window.resize(to: CGSize(width: 1000, height: 600))
        let deadline = Date().addingTimeInterval(15)
        while session.canvas?.columns.count != 2 || session.canvas?.columns.first?.tableInteraction?.cells.isEmpty != false {
            guard Date() < deadline else { XCTFail("Missing native table columns"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let canvas = try XCTUnwrap(session.canvas), first = canvas.columns[0], last = canvas.columns[1]
        let cell = try XCTUnwrap(first.tableInteraction?.cells.values.first { $0.cellText.string.hasPrefix("word0") })
        let target = try XCTUnwrap(last.tableInteraction?.cells.values.first { $0.cellText.string.hasPrefix("word0") })
        let press = SimulatedSelectionPress(canvas: canvas)
        press.point = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: canvas)
        let start = try XCTUnwrap(canvas.selectionPosition(at: press.point))
        let bridge = ReaderSpreadSelectionGestureDelegate(view: cell)
        XCTAssertTrue(bridge.gestureRecognizerShouldBegin(press))
        XCTAssertFalse(ReaderSpreadSelectionGestureDelegate(view: first).gestureRecognizerShouldBegin(press),
                       "only the cell surface owns a touch beginning in its native text")
        press.phase = .began; bridge.drag(press)
        press.point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: canvas)
        let end = try XCTUnwrap(canvas.selectionPosition(at: press.point))
        press.phase = .changed; bridge.drag(press)
        press.phase = .ended; bridge.drag(press)
        let range = ReaderTextRange(start: min(start, end), end: max(start, end))
        XCTAssertEqual(canvas.currentSelection?.range, range)
        XCTAssertEqual(canvas.currentSelection?.text, session.selectionText(in: range))
        var copied: String?
        cell.copyTextToPasteboard = { copied = $0 }
        cell.copy(nil)
        XCTAssertEqual(copied, canvas.currentSelection?.text)
        XCTAssertTrue(cell.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer && $0.delegate is ReaderSpreadSelectionGestureDelegate } == true)
        XCTAssertTrue(cell.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer && $0.delegate is ReaderSpreadSelectionGestureDelegate } == true)
        try snapshot(canvas, name: "touch-cell-to-cell")
    }
    #endif

    private func snapshot(_ view: ReaderCanvasView, name: String) throws {
        let image: CGImage
        #if os(macOS)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        image = try XCTUnwrap(bitmap.cgImage)
        let directory = "/private/tmp"
        #else
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        image = try XCTUnwrap(UIGraphicsImageRenderer(bounds: view.bounds, format: format).image {
            view.layer.render(in: $0.cgContext)
        }.cgImage)
        let directory = NSTemporaryDirectory()
        #endif
        let output = URL(fileURLWithPath: directory).appendingPathComponent("epublib-spread-selection-\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = XCTAttachment(contentsOfFile: output)
        attachment.name = "Spread selection \(name)"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#if os(iOS)
@MainActor private final class SimulatedSelectionPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    weak var canvas: UIView?
    init(canvas: UIView) { self.canvas = canvas; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func location(in view: UIView?) -> CGPoint { canvas?.convert(point, to: view) ?? point }
}

@MainActor private final class SimulatedSelectionPress: UILongPressGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    weak var canvas: UIView?
    init(canvas: UIView) { self.canvas = canvas; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func location(in view: UIView?) -> CGPoint { canvas?.convert(point, to: view) ?? point }
}
#endif
