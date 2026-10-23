import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

/// A host highlight's style ([#682](https://github.com/vocaro/EPUBLib/issues/682)): its color
/// and the mark under its text, as the mounted reader paints them in both flows, in both
/// appearances, in table cells and across a page break, read from the pixels its views last
/// painted (`ReaderPaintRecorder`).
@MainActor final class HighlightStyleTests: XCTestCase {
    // MARK: Colors

    /// WCAG 2.2's relative luminance of an sRGB color.
    private func luminance(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func components(_ color: PlatformColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(macOS)
        (color.usingColorSpace(.sRGB) ?? color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return (red, green, blue, alpha)
    }

    private func contrast(_ a: (red: CGFloat, green: CGFloat, blue: CGFloat), _ b: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGFloat {
        let one = luminance(a.red, a.green, a.blue), two = luminance(b.red, b.green, b.blue)
        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    /// A highlight's fill as it shows over the page.
    private func fill(_ color: EPUBHighlightColor, dark: Bool) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let page = components(ReaderPalette.background(dark: dark)), fill = ReaderPalette.highlightFill(color, dark: dark)
        func blend(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat { top * fill.alpha + bottom * (1 - fill.alpha) }
        return (blend(fill.red, page.red), blend(fill.green, page.green), blend(fill.blue, page.blue))
    }

    /// Every color keeps the reader's text over it at 4.5:1 or more and draws its mark at 3:1
    /// or more against it, WCAG 2.2's floors for text and for a graphic that carries meaning,
    /// in both appearances. Yellow is drawn as every host highlight was before styles.
    func testEveryColorKeepsTheTextOverItReadableAndItsMarkSeenInBothAppearances() {
        XCTAssertEqual(EPUBHighlightColor.allCases, [.yellow, .green, .blue, .pink, .purple])
        for dark in [false, true] {
            let text = components(ReaderPalette.text(dark: dark))
            for color in EPUBHighlightColor.allCases {
                let under = fill(color, dark: dark), mark = ReaderPalette.highlightMark(color, dark: dark)
                let label = "\(color) \(dark ? "dark" : "light")"
                XCTAssertGreaterThanOrEqual(contrast((text.red, text.green, text.blue), under), dark ? 8 : 14, label)
                XCTAssertGreaterThanOrEqual(contrast(mark, under), 3, label)
                let page = components(ReaderPalette.background(dark: dark))
                XCTAssertGreaterThanOrEqual(contrast(mark, (page.red, page.green, page.blue)), 3, label)
                XCTAssertEqual(components(ReaderPalette.mark(color, dark: dark)).alpha, 1, "\(label): a mark is opaque")
            }
            XCTAssertEqual(ReaderPalette.annotationHighlight(dark: dark), ReaderPalette.highlight(EPUBHighlightColor.yellow, dark: dark))
        }
        XCTAssertEqual(components(ReaderPalette.annotationHighlight(dark: false)).alpha, 0.55, accuracy: 0.001)
        XCTAssertEqual(components(ReaderPalette.annotationHighlight(dark: true)).alpha, 0.35, accuracy: 0.001)
    }

    /// Each color paints a fill of its own, far enough from every other and from a search
    /// match's that the pictures below can tell them apart, and so can a reader.
    func testEveryColorPaintsAFillOfItsOwn() {
        for dark in [false, true] {
            func pixel(_ rgb: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> [Int] { [rgb.red, rgb.green, rgb.blue].map { Int(($0 * 255).rounded()) } }
            var fills = EPUBHighlightColor.allCases.map { (name: "\($0)", pixel: pixel(fill($0, dark: dark))) }
            let page = components(ReaderPalette.background(dark: dark))
            for kind in [ReaderHighlight.Kind.search, .currentSearch] {
                let color = components(ReaderPalette.highlight(kind, dark: dark))
                fills.append(("\(kind)", pixel((color.red * color.alpha + page.red * (1 - color.alpha),
                                                color.green * color.alpha + page.green * (1 - color.alpha),
                                                color.blue * color.alpha + page.blue * (1 - color.alpha)))))
            }
            for (index, one) in fills.enumerated() {
                for other in fills[(index + 1)...] {
                    let apart = zip(one.pixel, other.pixel).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertGreaterThan(apart, 3, "\(one.name) and \(other.name) \(dark ? "dark" : "light")")
                }
            }
        }
    }

    // MARK: Marks

    /// Each mark the reader strokes itself, in a table nested in a cell, is a pattern of its
    /// own: a solid line, two lines, dots, dashes. Drawn into a picture of its own.
    func testEachMarkIsStrokedInAPatternOfItsOwn() throws {
        let width = 200, height = 40
        func stroke(_ mark: EPUBHighlightMark) throws -> [[Bool]] {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                // Down the page, as the cell's layout draws.
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                mark.draw(color: CGColor(red: 0, green: 0, blue: 0, alpha: 1), from: 10, to: 190, baseline: 10, fontSize: 24, in: context)
            }
            return (0..<height).map { y in (0..<width).map { x in pixels[(y * width + x) * 4 + 3] > 127 } }
        }
        func rows(_ picture: [[Bool]]) -> [Int] { picture.indices.filter { picture[$0].contains(true) } }
        /// The runs of inked pixels along the most inked row.
        func runs(_ picture: [[Bool]]) -> Int {
            guard let row = rows(picture).max(by: { picture[$0].filter { $0 }.count < picture[$1].filter { $0 }.count }) else { return 0 }
            var count = 0, inked = false
            for pixel in picture[row] { if pixel && !inked { count += 1 }; inked = pixel }
            return count
        }
        func bands(_ picture: [[Bool]]) -> Int {
            var count = 0, last: Int?
            for row in rows(picture) { if last.map({ row != $0 + 1 }) ?? true { count += 1 }; last = row }
            return count
        }
        let underline = try stroke(.underline), double = try stroke(.doubleUnderline)
        let dotted = try stroke(.dottedUnderline), dashed = try stroke(.dashedUnderline)
        XCTAssertGreaterThan(rows(underline).first ?? 0, 10, "under the baseline, down the page")
        XCTAssertEqual(bands(underline), 1)
        XCTAssertEqual(runs(underline), 1, "solid")
        XCTAssertEqual(bands(double), 2, "two lines")
        XCTAssertEqual(runs(double), 1)
        XCTAssertGreaterThan(runs(dashed), 10, "dashes")
        XCTAssertGreaterThan(runs(dotted), runs(dashed), "dots, closer together than dashes")
    }

    // MARK: Painted pages

    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private final class Events {
        var all: [EPUBReaderEvent] = []
        var selections: [EPUBSelection] {
            all.compactMap { event -> EPUBSelection? in
                if case .selectionChanged(let value) = event { return value }
                return nil
            }
        }
    }

    @MainActor private struct Reader {
        let session: NativeSession
        let events: Events
        let window: ReaderTestWindow
        let canvas: ReaderCanvasView
        let recorder: ReaderPaintRecorder
        let dark: Bool
        var background: PlatformColor { ReaderPalette.background(dark: dark) }
        var painted: ReaderPaintBitmap { recorder.bitmap(background: background) }
        /// A fill over the page as painted beside the text, its top left corner: on a Mac a
        /// dark continuous scroll is painted dark gray there, where its pages are black.
        func fillPixels(_ color: EPUBHighlightColor, in region: CGRect? = nil) -> Int {
            let picture = painted, index = (4 * picture.width + 4) * 4
            func value(_ offset: Int) -> CGFloat { CGFloat(picture.pixels[index + offset]) / 255 }
            let page = PlatformColor(red: value(0), green: value(1), blue: value(2), alpha: 1)
            return picture.count(of: ReaderPalette.highlight(color, dark: dark), over: page, in: region)
        }
        /// An opaque line of the mark's color, wherever it stands.
        func markPixels(_ color: EPUBHighlightColor, in region: CGRect? = nil) -> Int {
            painted.count(of: ReaderPalette.mark(color, dark: dark), over: background, in: region, tolerance: 10)
        }
        var inkPixels: Int { painted.ink(over: background) }

        func paint(timeout: TimeInterval, until condition: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                recorder.flush()
                if condition() { return true }
                guard Date() < deadline else { return false }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// AppKit's text checking redraws a text view's fragments about a second after its text
        /// is set (`HighlightPaintTests`): it is turned off before a change under test.
        func stopTextChecking() {
            #if os(macOS)
            func visit(_ view: NSView) {
                (view as? NSTextView)?.enabledTextCheckingTypes = 0
                view.subviews.forEach(visit)
            }
            visit(canvas)
            #endif
        }

        func quiesce() async throws {
            stopTextChecking()
            var draws = -1, rounds = 0
            while draws != recorder.draws, rounds < 30 {
                draws = recorder.draws
                rounds += 1
                for _ in 0..<15 {
                    recorder.flush()
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        /// The location the reader reports for `text`, selected where it is found, and then
        /// left unselected: a host's saved highlight.
        func location(of text: String) async throws -> EPUBLocation {
            let before = events.selections.count
            try await session.send(.locate(text: text, highlight: true))
            let deadline = Date().addingTimeInterval(20)
            while !(events.selections.count > before && events.selections.last?.text == text) {
                guard Date() < deadline else { throw SessionCoverageTimeout(description: "Timed out waiting for the selection of \(text)") }
                try await Task.sleep(for: .milliseconds(20))
            }
            canvas.clearSelection()
            return events.selections.last!.location
        }

        func close() {
            recorder.stop()
            session.close()
            window.close()
        }
    }

    private var onePage: CGSize {
        #if os(macOS)
        CGSize(width: 600, height: 700)
        #else
        CGSize(width: 390, height: 844)
        #endif
    }

    private func open(_ data: Data, flow: EPUBReadingFlow, size: CGSize? = nil, dark: Bool = false) async throws -> Reader {
        let publication = try EPUBPublication.open(data: data)
        let events = Events()
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) {
            events.all.append($0)
        } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        if let size { window.resize(to: size) }
        try await wait("the reader") { session.isReady && session.book.isComplete && session.lastLocation != nil }
        try await session.send(.style(.init(appearance: dark ? .dark : .light, flow: flow)))
        try await wait("the styled book") {
            session.book.isComplete && session.book.typography.isDark == dark && session.canvas?.configuration.flow == flow
                && !(session.canvas?.textViews.isEmpty ?? true)
        }
        let canvas = try XCTUnwrap(session.canvas)
        let recorder = ReaderPaintRecorder(root: canvas)
        let reader = Reader(session: session, events: events, window: window, canvas: canvas, recorder: recorder, dark: dark)
        reader.stopTextChecking()
        recorder.synchronize()
        let painted = try await reader.paint(timeout: 10) { reader.inkPixels > 0 }
        XCTAssertTrue(painted, "the opening page was never painted")
        try await reader.quiesce()
        return reader
    }

    /// With `EPUBLIB_PAINT_DIR` set, keeps a step's picture there, for looking at a failure.
    private func keep(_ reader: Reader, _ label: String) {
        guard let directory = ProcessInfo.processInfo.environment["EPUBLIB_PAINT_DIR"] else { return }
        reader.painted.writePNG(to: URL(fileURLWithPath: directory).appendingPathComponent("styles \(label).png"))
    }

    private func chapter(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Styles</title></head><body>\(body)</body></html>"
    }

    /// Five passages on the first page and screen, one for each color; nothing in the book is
    /// any highlight's color or any mark's.
    private static let passages = ["Amber words stand here.", "Fern words stand here.", "Sky words stand here.",
                                   "Rose words stand here.", "Plum words stand here."]

    private var styledBook: Data {
        get throws {
            try Fixture.epub(overrides: ["OPS/one.xhtml": chapter("<h1 id=\"start\">Styles</h1>"
                + Self.passages.map { "<p>\($0)</p>" }.joined()
                + String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: 50))])
        }
    }

    /// Two rounds of styles over the five passages: each color with a mark and without one,
    /// and each mark on a color.
    private static let rounds: [[EPUBHighlightStyle]] = [
        [.init(color: .yellow), .init(color: .green, mark: .underline), .init(color: .blue, mark: .doubleUnderline),
         .init(color: .pink, mark: .dottedUnderline), .init(color: .purple, mark: .dashedUnderline)],
        [.init(color: .yellow, mark: .dashedUnderline), .init(color: .green), .init(color: .blue, mark: .underline),
         .init(color: .pink, mark: .doubleUnderline), .init(color: .purple, mark: .dottedUnderline)],
    ]

    /// Every style is painted in its color, with its mark where it has one and with none
    /// where it has none, and each change of style repaints in place.
    private func exerciseStyles(flow: EPUBReadingFlow, size: CGSize? = nil, dark: Bool = false) async throws {
        let reader = try await open(try styledBook, flow: flow, size: size, dark: dark)
        defer { reader.close() }
        let label = "\(flow)\(dark ? " dark" : "")"
        for color in EPUBHighlightColor.allCases {
            XCTAssertEqual(reader.fillPixels(color), 0, "\(label): the book has no \(color) fill of its own")
            XCTAssertEqual(reader.markPixels(color), 0, "\(label): the book has no \(color) mark of its own")
        }
        var locations: [EPUBLocation] = []
        for passage in Self.passages { locations.append(try await reader.location(of: passage)) }
        // Back to the chapter's start: continuous scroll shows each passage found at the top.
        try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
        try await reader.quiesce()
        let shown = reader.session.visibleRange
        for (round, styles) in Self.rounds.enumerated() {
            let highlights = zip(locations, styles).enumerated().map { EPUBHighlight(id: "h\($0.offset)", location: $0.element.0, style: $0.element.1) }
            try await reader.session.send(.setHighlights(highlights))
            XCTAssertEqual(reader.session.drawnHighlights.map(\.style), styles, "\(label) round \(round)")
            let painted = try await reader.paint(timeout: 5) {
                zip(EPUBHighlightColor.allCases, styles).allSatisfy { color, style in
                    reader.fillPixels(color) > 0 && (style.mark == nil) == (reader.markPixels(color) == 0)
                }
            }
            keep(reader, "\(label) round \(round)")
            for (color, style) in zip(EPUBHighlightColor.allCases, styles) {
                XCTAssertGreaterThan(reader.fillPixels(color), 0, "\(label) round \(round): \(color) painted")
                if style.mark == nil {
                    XCTAssertEqual(reader.markPixels(color), 0, "\(label) round \(round): \(color) has no mark")
                } else {
                    XCTAssertGreaterThan(reader.markPixels(color), 0, "\(label) round \(round): \(color) has its \(style.mark!) mark")
                }
            }
            XCTAssertTrue(painted, "\(label) round \(round)")
            XCTAssertEqual(reader.session.visibleRange, shown, "\(label): a style repaints in place")
            try await reader.quiesce()
        }
        try await reader.session.send(.setHighlights([]))
        let cleared = try await reader.paint(timeout: 5) {
            EPUBHighlightColor.allCases.allSatisfy { reader.fillPixels($0) == 0 && reader.markPixels($0) == 0 }
        }
        XCTAssertTrue(cleared, "\(label): every fill and mark leaves with its highlight")
    }

    func testEveryStyleIsPaintedWithItsColorAndMarkWhenPaginated() async throws {
        try await exerciseStyles(flow: .paginated, size: onePage)
    }

    func testEveryStyleIsPaintedWithItsColorAndMarkWhenScrolled() async throws {
        try await exerciseStyles(flow: .scrolled)
    }

    func testEveryStyleIsPaintedWithItsColorAndMarkInDarkAppearance() async throws {
        try await exerciseStyles(flow: .paginated, size: onePage, dark: true)
        try await exerciseStyles(flow: .scrolled, dark: true)
    }

    /// Each mark is given to the text view as what it is, in its color's shade, on the
    /// characters it underlines; a later highlight takes the mark of one beneath it, its own or
    /// none, and a search match over a marked highlight leaves the mark. The text never changes.
    func testEachMarkIsGivenToTheTextAsItIsAndOnlyAHighlightReplacesIt() async throws {
        let reader = try await open(try styledBook, flow: .paginated, size: onePage)
        defer { reader.close() }
        let section = try XCTUnwrap(reader.session.visibleRange?.start.section)
        let view = try XCTUnwrap(reader.canvas.textViews.first)
        let text = view.contentStorage.textStorage?.string as NSString? ?? ""
        func range(of words: String) throws -> ReaderTextRange {
            let local = text.range(of: words)
            XCTAssertNotEqual(local.location, NSNotFound, words)
            return ReaderTextRange(section: section, (view.placement.offset + local.location)..<(view.placement.offset + NSMaxRange(local)))
        }
        /// The mark the text view is given for the character `offset` into `words`.
        func mark(at words: String, offset: Int = 0) -> (mark: EPUBHighlightMark?, color: PlatformColor?) {
            let location = text.range(of: words).location + offset
            var found: (EPUBHighlightMark?, PlatformColor?) = (nil, nil)
            let manager = view.readerLayoutManager
            manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attributes, textRange in
                let lower = view.offset(of: textRange.location), upper = view.offset(of: textRange.endLocation)
                guard lower <= location, location < upper else { return lower <= location }
                found = ((attributes[.readerHighlightMark] as? String).flatMap(EPUBHighlightMark.init(rawValue:)),
                         attributes[.readerHighlightMarkColor] as? PlatformColor)
                return false
            }
            return found
        }
        let before = view.contentStorage.textStorage.map(NSAttributedString.init(attributedString:))
        XCTAssertTrue(view.readerLayoutManager.textLayoutFragment(for: view.readerLayoutManager.documentRange.location) is ReaderLayoutFragment,
                      "the reader's fragments draw the marks")
        for each in EPUBHighlightMark.allCases {
            let style = EPUBHighlightStyle(color: .blue, mark: each)
            reader.canvas.setHighlights([ReaderHighlight(id: "m", range: try range(of: "Sky words stand"), kind: .annotation, style: style)])
            XCTAssertEqual(mark(at: "Sky words").mark, each)
            XCTAssertEqual(mark(at: "Sky words").color, ReaderPalette.mark(.blue, dark: false), "\(each)")
            XCTAssertNil(mark(at: "Rose words").mark, "\(each): nowhere else")
        }

        // Beneath and over: a later host highlight without a mark takes the mark away where
        // it lies, a search match leaves it.
        let sky = try range(of: "Sky words stand here.")
        let marked = ReaderHighlight(id: "under", range: sky, kind: .annotation, style: .init(color: .blue, mark: .underline))
        // "words" in the middle of it.
        let words = ReaderTextRange(section: section, (sky.start.offset + 4)..<(sky.start.offset + 9))
        reader.canvas.setHighlights([marked, ReaderHighlight(id: "over", range: words, kind: .annotation, style: .init(color: .pink))])
        XCTAssertEqual(mark(at: "Sky words").mark, .underline, "the mark before the later highlight")
        XCTAssertNil(mark(at: "Sky words", offset: 5).mark, "a later highlight without a mark takes the mark away")
        XCTAssertEqual(mark(at: "Sky words stand", offset: 10).mark, .underline, "and only where it lies")
        reader.canvas.setHighlights([marked, ReaderHighlight(id: "search", range: words, kind: .search)])
        XCTAssertEqual(mark(at: "Sky words", offset: 5).mark, .underline, "a search match leaves the mark beneath it")
        reader.canvas.setHighlights([])
        XCTAssertNil(mark(at: "Sky words").mark)
        XCTAssertNil(mark(at: "Sky words", offset: 5).mark)
        XCTAssertEqual(view.contentStorage.textStorage.map(NSAttributedString.init(attributedString:)), before, "the text is never changed")
    }

    /// A highlight that runs from one page onto the next is painted in its style on both, and
    /// again on the first when the reader turns back.
    func testAHighlightAcrossAPageBreakIsPaintedInItsStyleOnBothPages() async throws {
        let reader = try await open(try styledBook, flow: .paginated, size: onePage)
        defer { reader.close() }
        let visible = try XCTUnwrap(reader.session.visibleRange)
        let across = ReaderTextRange(section: visible.end.section, (visible.end.offset - 40)..<(visible.end.offset + 40))
        reader.canvas.setHighlights([ReaderHighlight(id: "across", range: across, kind: .annotation, style: .init(color: .purple, mark: .dashedUnderline))])
        var painted = try await reader.paint(timeout: 5) { reader.fillPixels(.purple) > 0 && reader.markPixels(.purple) > 0 }
        XCTAssertTrue(painted, "the first page's part")
        try await reader.quiesce()
        XCTAssertEqual(reader.canvas.turnPage(forward: true), .turned)
        painted = try await reader.paint(timeout: 5) { reader.fillPixels(.purple) > 0 && reader.markPixels(.purple) > 0 }
        XCTAssertTrue(painted, "the next page's part")
        XCTAssertEqual(reader.canvas.turnPage(forward: false), .turned)
        painted = try await reader.paint(timeout: 5) { reader.fillPixels(.purple) > 0 && reader.markPixels(.purple) > 0 }
        XCTAssertTrue(painted, "the first page's part again")
    }

    /// A styled highlight in a table's cell, and in a table nested in a cell, is painted in
    /// its color with its mark, on its own words, in both flows: the cell's text view draws the
    /// first, and the cell's layout the second.
    func testAStyledHighlightInATableCellAndInANestedTableIsPaintedWithItsMark() async throws {
        let rows = (0..<3).map { "<tr><td>Inner \($0) words</td><td>y</td></tr>" }.joined()
        let table = chapter("""
        <h1 id="start">Styles</h1><p>Plain words before the table.</p>
        <table><tr><td>Popcorn kernels here</td><td>Nothing to find</td></tr>
        <tr><td><table>\(rows)<tr><td>Nestedneedle words</td><td>z</td></tr></table></td><td>x</td></tr></table>
        <p>Plain words after the table.</p>
        """)
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try await open(try Fixture.epub(overrides: ["OPS/one.xhtml": table]), flow: flow)
            defer { reader.close() }
            let cell = try await reader.location(of: "Popcorn kernels")
            let nested = try await reader.location(of: "Nestedneedle")
            try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
            try await reader.quiesce()
            try await reader.session.send(.setHighlights([
                EPUBHighlight(id: "cell", location: cell, style: .init(color: .green, mark: .underline)),
                EPUBHighlight(id: "nested", location: nested, style: .init(color: .pink, mark: .doubleUnderline)),
            ]))
            XCTAssertEqual(reader.session.drawnHighlights.filter { $0.range.start.tableCell != nil }.count, 2, "\(flow)")
            let painted = try await reader.paint(timeout: 10) {
                reader.fillPixels(.green) > 0 && reader.markPixels(.green) > 0 && reader.fillPixels(.pink) > 0 && reader.markPixels(.pink) > 0
            }
            keep(reader, "\(flow) table marks")
            XCTAssertTrue(painted, "\(flow): green \(reader.fillPixels(.green))/\(reader.markPixels(.green)), pink \(reader.fillPixels(.pink))/\(reader.markPixels(.pink))")
            try await reader.quiesce()
            try await reader.session.send(.setHighlights([
                EPUBHighlight(id: "cell", location: cell, style: .init(color: .green)),
                EPUBHighlight(id: "nested", location: nested, style: .init(color: .pink)),
            ]))
            let unmarked = try await reader.paint(timeout: 5) {
                reader.markPixels(.green) == 0 && reader.markPixels(.pink) == 0 && reader.fillPixels(.green) > 0 && reader.fillPixels(.pink) > 0
            }
            XCTAssertTrue(unmarked, "\(flow): the marks leave with the style that had them")
        }
    }
}
