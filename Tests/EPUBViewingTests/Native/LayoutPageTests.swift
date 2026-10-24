import CoreGraphics
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// #681: the pages of the layout on screen (`EPUBReaderStatus.layoutPage`), going to a
/// progression (`.goToProgression`, `.goToStart`, `.goToEnd`), and the keys that go to the book's
/// start and end. Expectations come from the issue: page X of Y counts every page that page turns
/// pass once, in order, in each layout; 0, 0.5 and 1 are the first page, the page holding the
/// point half way through as `EPUBLocation.progression` measures it, and the last page.
@MainActor final class LayoutPageTests: XCTestCase {
    private var hosts: [CanvasHost] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts.removeAll()
        try await super.tearDown()
    }

    private struct Timeout: Error {}
    @MainActor private final class Served { var whileCounting: Bool? }

    private func wait(_ label: String, timeout: TimeInterval = 60, until condition: () -> Bool) async throws {
        let deadline = TestDeadline(seconds: timeout)
        while !condition() {
            guard try !deadline.hasPassed() else {
                XCTFail("Timed out waiting for \(label)")
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Books

    private static let words = ["reading", "pages", "river", "morning", "lantern", "harbour", "quiet", "letters",
                                "garden", "window", "evening", "journey", "mountain", "candle", "story", "orchard"]

    /// A book of `sections` sections, each a heading and `paragraphs` paragraphs of `count` words;
    /// the `nonlinear` ones are `linear="no"`. It has no landmarks, so it opens at its first
    /// linear section.
    static func book(sections: Int, paragraphs: Int, words count: Int = 60, nonlinear: Set<Int> = []) throws -> Data {
        try Fixture.archive(bookFiles(sections: sections, paragraphs: paragraphs, words: count, nonlinear: nonlinear))
    }

    private static func bookFiles(sections: Int, paragraphs: Int, words count: Int, nonlinear: Set<Int> = []) -> [String: String] {
        var manifest = "", spine = ""
        var files: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "OPS/nav.xhtml": """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="s0.xhtml">Section 0</a></li></ol></nav></body></html>
            """,
        ]
        for index in 0..<sections {
            manifest += "<item id=\"s\(index)\" href=\"s\(index).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"s\(index)\"\(nonlinear.contains(index) ? " linear=\"no\"" : "")/>"
            let body = (0..<paragraphs).map { paragraph in
                "<p>S\(index)P\(paragraph) "
                    + (0..<count).map { words[($0 * 7 + paragraph * 3 + index) % words.count] }.joined(separator: " ") + ".</p>"
            }.joined()
            files["OPS/s\(index).xhtml"] = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Section \(index)</title></head><body><h1>Section \(index)</h1>\(body)</body></html>
            """
        }
        files["OPS/book.opf"] = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Layout Pages</dc:title><dc:language>en</dc:language><dc:identifier id="uid">layout-pages-\(sections)-\(paragraphs)-\(count)</dc:identifier></metadata><manifest>\(manifest)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>\(spine)</spine></package>
        """
        return files
    }

    /// `book(sections:paragraphs:words:)` with a picture of its own before every fourth paragraph,
    /// and one more that ends each section.
    static func illustratedBook(sections: Int, paragraphs: Int, words count: Int = 60) throws -> Data {
        var files = bookFiles(sections: sections, paragraphs: paragraphs, words: count).mapValues { Data($0.utf8) }
        var manifest = ""
        for index in 0..<sections {
            let path = "OPS/s\(index).xhtml"
            var document = String(decoding: try XCTUnwrap(files[path]), as: UTF8.self)
            for paragraph in stride(from: 0, to: paragraphs, by: 4) {
                let name = "figure-\(index)-\(paragraph).png"
                files["OPS/" + name] = RichFixture.image(width: 240 + paragraph, height: 160)
                manifest += "<item id=\"f\(index)-\(paragraph)\" href=\"\(name)\" media-type=\"image/png\"/>"
                document = document.replacingOccurrences(of: "<p>S\(index)P\(paragraph) ",
                                                         with: "<p><img src=\"\(name)\" alt=\"Figure \(index)-\(paragraph)\"/></p><p>S\(index)P\(paragraph) ")
            }
            let last = "figure-\(index)-end.png"
            files["OPS/" + last] = RichFixture.image(width: 300, height: 120)
            manifest += "<item id=\"f\(index)-end\" href=\"\(last)\" media-type=\"image/png\"/>"
            document = document.replacingOccurrences(of: "</body>", with: "<p><img src=\"\(last)\" alt=\"Figure \(index) end\"/></p></body>")
            files[path] = Data(document.utf8)
        }
        let package = String(decoding: try XCTUnwrap(files["OPS/book.opf"]), as: UTF8.self)
        files["OPS/book.opf"] = Data(package.replacingOccurrences(of: "<item id=\"nav\"", with: manifest + "<item id=\"nav\"").utf8)
        return try Fixture.archive(files)
    }

    private func open(_ data: Data) throws -> (NativeSession, ReaderTestWindow) {
        let publication = try EPUBPublication.open(data: data)
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication) { _ in } as? NativeSession)
        return (session, ReaderTestWindow(session: session))
    }

    // MARK: Page X of Y

    /// Page X of Y in portrait, in a landscape spread of two columns, and after a text size
    /// change: turning from the first page to the last passes every page counted once, in order,
    /// and each section's own pages; a nonlinear section that page turns step over is not counted.
    func testPagesAreCountedAndIndexedInBothOrientationsAndAfterATextSizeChange() async throws {
        let (session, window) = try open(Self.book(sections: 4, paragraphs: 14, nonlinear: [1]))
        defer { session.close(); window.close() }
        let state = try XCTUnwrap(session.readerState)
        try await wait("the whole book") { session.isReady && session.book.isComplete }
        var counts: [String: Int] = [:]
        let layouts: [(label: String, size: CGSize, fontSize: Double, columns: Int)] = [
            ("portrait", CGSize(width: 600, height: 800), 17, 1),
            ("landscape", CGSize(width: 1100, height: 700), 17, 2),
            ("landscape with larger text", CGSize(width: 1100, height: 700), 26, 2),
            ("portrait with larger text", CGSize(width: 600, height: 800), 26, 1),
        ]
        for layout in layouts {
            window.resize(to: layout.size)
            if state.status.style.fontSize != layout.fontSize { try await session.send(.style(.init(fontSize: layout.fontSize))) }
            try await wait("\(layout.label): the spread") {
                session.book.isComplete && session.canvas?.pendingSpread == nil
                    && session.canvas?.spread?.columns.count == layout.columns
            }
            try await session.send(.goToStart)
            try await wait("\(layout.label): the count") { state.status.layoutPage?.count != nil }
            counts[layout.label] = try await turnThrough(session, layout.label)
        }
        XCTAssertGreaterThan(try XCTUnwrap(counts["landscape with larger text"]), try XCTUnwrap(counts["landscape"]))
        XCTAssertGreaterThan(try XCTUnwrap(counts["portrait with larger text"]), try XCTUnwrap(counts["portrait"]))
    }

    /// Turns from the first page to the last, checking each spread's numbers against the pages
    /// turned past, and returns the book's count.
    private func turnThrough(_ session: NativeSession, _ label: String) async throws -> Int {
        let state = try XCTUnwrap(session.readerState)
        let count = try XCTUnwrap(state.status.layoutPage?.count, label)
        XCTAssertEqual(state.status.layoutPage?.index, 0, "\(label): the first page")
        var passed = 0
        var passedInSection: [Int: Int] = [:]
        var sectionCounts: [Int: Int] = [:]
        for turn in 0... {
            let page = try XCTUnwrap(state.status.layoutPage, "\(label) turn \(turn)")
            let range = try XCTUnwrap(session.visibleRange, "\(label) turn \(turn)")
            let section = range.start.section
            XCTAssertEqual(page.index, passed, "\(label) turn \(turn)")
            XCTAssertEqual(page.count, count, "\(label) turn \(turn)")
            XCTAssertEqual(page.sectionIndex, passedInSection[section, default: 0], "\(label) turn \(turn)")
            XCTAssertEqual(page.shownCount, session.canvas?.textViews.count, "\(label) turn \(turn)")
            sectionCounts[section] = try XCTUnwrap(page.sectionCount, "\(label) turn \(turn)")
            passed += page.shownCount
            passedInSection[section, default: 0] += page.shownCount
            if state.status.canGoNext == false { break }
            guard turn < 1_000 else { XCTFail("\(label): no last page"); break }
            try await session.send(.nextPage)
            try await wait("\(label) turn \(turn + 1)") { session.visibleRange != range }
        }
        XCTAssertEqual(passed, count, "\(label): every page counted is turned past once")
        XCTAssertEqual(sectionCounts, passedInSection, "\(label): each section's pages")
        XCTAssertEqual(Set(passedInSection.keys), [0, 2, 3], "\(label): page turns step over the nonlinear section")
        return count
    }

    /// A long book is counted a little at a time: page turns are shown at once while it is, the
    /// main queue is served between its slices, and the count arrives afterwards with the page
    /// turned to. Continuous scroll has no pages.
    func testCountingALongBookDoesNotHoldUpPageTurns() async throws {
        let (session, window) = try open(Self.book(sections: 40, paragraphs: 16, words: 110))
        defer { session.close(); window.close() }
        let state = try XCTUnwrap(session.readerState)
        try await wait("the whole book", timeout: 180) { session.isReady && session.book.isComplete }
        let canvas = try XCTUnwrap(session.canvas)
        // A new size drops every count, so the whole book is counted again from here.
        let size = CGSize(width: 560, height: 760)
        window.resize(to: size)
        try await wait("the new spread") {
            canvas.pendingSpread == nil && canvas.pageCounter.size == canvas.spread?.columnSize
                && state.status.layoutPage != nil && canvas.spread?.columnSize != nil
        }
        XCTAssertNil(state.status.layoutPage?.count, "the count has only begun")
        XCTAssertTrue(canvas.pageCounter.isCounting)

        let served = Served()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { served.whileCounting = state.status.layoutPage?.count == nil }
        }
        try await wait("the main queue") { served.whileCounting != nil }
        XCTAssertEqual(served.whileCounting, true, "the main queue is served while the book is counted")

        var turned = 0
        for turn in 1...3 {
            let shown = try XCTUnwrap(session.visibleRange)
            turned += try XCTUnwrap(state.status.layoutPage?.shownCount)
            try await session.send(.nextPage)
            XCTAssertNotEqual(session.visibleRange, shown, "turn \(turn) is shown at once")
            XCTAssertNil(state.status.layoutPage?.count, "turn \(turn) did not wait for the count")
            let slices = canvas.pageCounter.slices
            try await wait("counting after turn \(turn)") { canvas.pageCounter.slices > slices }
        }
        try await wait("the count", timeout: 300) { state.status.layoutPage?.count != nil }
        let page = try XCTUnwrap(state.status.layoutPage)
        XCTAssertEqual(page.sectionIndex, turned, "the page turned to")
        XCTAssertEqual(page.index, turned, "the book's first section")
        XCTAssertGreaterThan(try XCTUnwrap(page.count), 40)
        XCTAssertNotNil(page.sectionCount)
        try await wait("counting to end") { !canvas.pageCounter.isCounting }

        try await session.send(.style(.init(flow: .scrolled)))
        try await wait("continuous scroll") { state.status.style.flow == .scrolled && session.canvas?.scrollTextView != nil }
        XCTAssertNil(state.status.layoutPage, "continuous scroll has no pages")
    }

    /// Closing a reader lets go at once of every image in the sections it counted, while it
    /// counts and once it has counted them all, as closing does of the reader's own pages
    /// (`SVGRelayoutTests.testClosingAReaderReleasesItsImagesAtOnce`). On iOS, text that ends
    /// with an image keeps that image alive after its layout is gone, until text that ends with
    /// another is laid out. The counter lays out every section's last page, which here ends
    /// with a picture, and an iPhone simulator kept one picture of a closed reader.
    func testClosingReleasesTheImagesOfEverySectionCounted() async throws {
        for whileCounting in [true, false] {
            try await exerciseClosing(whileCounting: whileCounting)
        }
    }

    private func exerciseClosing(whileCounting: Bool) async throws {
        final class Tracked { weak var source: ReaderImageSource? }
        let sections = whileCounting ? 30 : 6, label = whileCounting ? "while counting" : "counted"
        let (session, window) = try open(Self.illustratedBook(sections: sections, paragraphs: 16, words: 110))
        defer { session.close(); window.close() }
        try await wait("\(label): the whole book", timeout: 180) { session.isReady && session.book.isComplete }
        let canvas = try XCTUnwrap(session.canvas)
        // A new size starts the count afresh.
        window.resize(to: CGSize(width: 560, height: 760))
        try await wait("\(label): the count under way") {
            canvas.pendingSpread == nil && canvas.pageCounter.size == canvas.spread?.columnSize
                && (canvas.pageCounter.holdsPartialCount || !whileCounting)
        }
        if whileCounting {
            XCTAssertNil(session.readerState?.status.layoutPage?.count, "the count has only begun")
        } else {
            try await wait("the count") { session.readerState?.status.layoutPage?.count != nil && !canvas.pageCounter.isCounting }
        }
        // Read inside a pool of its own, so that nothing the test enumerated keeps an image alive.
        let images: [Tracked] = autoreleasepool {
            var images: [Tracked] = []
            for index in 0..<session.book.count {
                guard let text = session.book.section(index)?.string else { continue }
                text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    guard let image = value as? ReaderImageAttachment else { return }
                    let tracked = Tracked()
                    tracked.source = image.source
                    images.append(tracked)
                }
            }
            return images
        }
        XCTAssertEqual(images.count, sections * 5, label)
        session.close()
        XCTAssertFalse(canvas.pageCounter.isCounting, label)
        XCTAssertFalse(canvas.pageCounter.holdsPartialCount, label)
        let deadline = TestDeadline(seconds: 10)
        while images.contains(where: { $0.source != nil }), try !deadline.hasPassed() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(images.filter { $0.source != nil }.count, 0, "\(label): a closed reader still holds images through its count")
    }

    // MARK: Progression

    /// 0, 0.5 and 1 in both flows: the first page, the page holding the point half way through
    /// by the linear sections' sizes, as `EPUBLocation.progression` measures it, and the last
    /// page; values outside 0...1 go to the nearer end, and values that are no number are refused.
    /// A nonlinear section shown by a link has its own pages but no place among the book's.
    func testGoingToAProgressionShowsTheFirstPageThePageThereAndTheLastPage() async throws {
        let (session, window) = try open(Self.book(sections: 5, paragraphs: 12, nonlinear: [0, 4]))
        defer { session.close(); window.close() }
        let state = try XCTUnwrap(session.readerState)
        try await wait("the whole book") { session.isReady && session.book.isComplete }
        XCTAssertTrue(session.capabilities.contains(.goToProgression))

        // The point half way through, as foliate-js weighed sections: by their documents' bytes.
        let publication = session.publication
        let linear = publication.spine.indices.filter { publication.spine[$0].isLinear }
        XCTAssertEqual(linear, [1, 2, 3])
        let sizes = try linear.map { Double(try publication.data(for: publication.spine[$0].resource).count) }
        let total = sizes.reduce(0, +)
        func length(_ section: Int) throws -> Int { try XCTUnwrap(session.book.section(section)).string.length }
        func progression(of position: ReaderTextPosition) throws -> Double {
            let index = try XCTUnwrap(linear.firstIndex(of: position.section))
            let before = sizes[..<index].reduce(0, +)
            return (before + sizes[index] * Double(position.offset) / Double(try length(position.section))) / total
        }
        var before = 0.0
        var half: ReaderTextPosition?
        for (section, size) in zip(linear, sizes) {
            if 0.5 * total < before + size {
                half = ReaderTextPosition(section: section, offset: Int((0.5 * total - before) / size * Double(try length(section))))
                break
            }
            before += size
        }
        let middle = try XCTUnwrap(half)
        let start = ReaderTextPosition(section: 1, offset: 0)
        let end = ReaderTextPosition(section: 3, offset: try length(3))

        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            try await session.send(.style(.init(flow: flow)))
            if flow == .scrolled { try await wait("whole-book scroll") { session.canvas?.scrollBook != nil } }
            for (label, command) in [("1", EPUBReaderCommand.goToEnd), ("7", .goToProgression(7))] {
                try await session.send(.goToStart)
                try await wait("\(flow) \(label): away from the end") { state.status.canGoNext == true }
                try await session.send(command)
                try await wait("\(flow) \(label): the last page") { state.status.canGoNext == false }
                XCTAssertEqual(session.visibleRange?.end.section, end.section, "\(flow) \(label)")
                if flow == .paginated {
                    XCTAssertEqual(session.visibleRange?.end, end, "\(flow) \(label)")
                    XCTAssertEqual(session.lastLocation?.progression, 1, "\(flow) \(label): read to its end")
                    try await wait("\(flow) \(label): the count") { state.status.layoutPage?.count != nil }
                    let page = try XCTUnwrap(state.status.layoutPage)
                    XCTAssertEqual(try XCTUnwrap(page.index) + page.shownCount, page.count, "\(flow) \(label): the last page")
                } else {
                    XCTAssertNil(state.status.layoutPage, "continuous scroll has no pages")
                }
            }
            for (label, command) in [("0", EPUBReaderCommand.goToStart), ("-2", .goToProgression(-2))] {
                try await session.send(.goToEnd)
                try await wait("\(flow) \(label): away from the start") { state.status.canGoPrevious == true }
                try await session.send(command)
                try await wait("\(flow) \(label): the first page") { state.status.canGoPrevious == false }
                XCTAssertEqual(session.visibleRange?.start, start, "\(flow) \(label)")
                if flow == .paginated { XCTAssertEqual(state.status.layoutPage?.index, 0, "\(flow) \(label)") }
            }

            try await session.send(.goToProgression(0.5))
            try await wait("\(flow): half way") {
                session.visibleRange.map { $0.start <= middle && middle < $0.end } == true
            }
            let shown = try XCTUnwrap(session.visibleRange)
            XCTAssertLessThanOrEqual(try progression(of: shown.start), 0.5, "\(flow): what is shown starts at or before the point")
            if flow == .paginated {
                let reported = try XCTUnwrap(session.lastLocation?.progression)
                XCTAssertGreaterThanOrEqual(reported, 0.5, "a page's progression is measured at its end")
                XCTAssertEqual(reported, try progression(of: shown.end), accuracy: 1e-9)
            }

            for value in [Double.nan, .infinity, -.infinity] {
                do {
                    try await session.send(.goToProgression(value))
                    XCTFail("\(flow): \(value) was accepted")
                } catch let error as EPUBReaderError {
                    guard case .invalidCommand = error else { return XCTFail("\(flow): \(value) gave \(error)") }
                }
            }
            XCTAssertEqual(session.visibleRange, shown, "\(flow): a refused progression moves nothing")
        }

        try await session.send(.style(.init(flow: .paginated)))
        try await session.send(.navigate(href: "OPS/s0.xhtml"))
        try await wait("the nonlinear section") { session.visibleRange?.start.section == 0 }
        try await wait("its count") { state.status.layoutPage?.sectionCount != nil && state.status.layoutPage?.count != nil }
        let page = try XCTUnwrap(state.status.layoutPage)
        XCTAssertNil(page.index, "page turns do not reach a nonlinear section")
        XCTAssertEqual(page.sectionIndex, 0)
    }

    // MARK: Keys

    /// Sections 0 and 3 are nonlinear: the book's start is section 1's, its end section 2's.
    private func keyHost(flow: EPUBReadingFlow, buildEnd: Bool = true) -> CanvasHost {
        let sections = (0..<4).map { CanvasText.section($0, paragraphs: 20) }
        let source = FakeCanvasSource(sections, linear: [false, true, true, false])
        source.book = CanvasText.book(sections, omitting: [0, 3])
        if !buildEnd { source.sections[2] = nil; source.book = nil }
        var configuration = ReaderCanvasConfiguration()
        configuration.flow = flow
        let host = CanvasHost(source, configuration: configuration)
        hosts.append(host)
        host.canvas.show(ReaderTextPosition(section: 1, offset: sections[1].length / 2), selecting: nil)
        host.layOut()
        return host
    }

    private func bookStart(_ host: CanvasHost) -> ReaderTextPosition { ReaderTextPosition(section: 1, offset: 0) }
    private func bookEnd(_ host: CanvasHost) throws -> ReaderTextPosition {
        ReaderTextPosition(section: 2, offset: try XCTUnwrap(host.source.sections[2]).length)
    }

    #if os(macOS)
    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags, in host: CanvasHost) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: host.window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// Home and End, and Command-Up and Command-Down, which come as key equivalents, go to the
    /// book's start and end in both flows, past its nonlinear sections.
    func testHomeEndAndCommandArrowsGoToTheBooksStartAndEnd() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let host = keyHost(flow: flow)
            let canvas = host.canvas
            XCTAssertTrue(host.window.makeFirstResponder(try XCTUnwrap(canvas.textViews.first)))
            let moves: [(label: String, event: NSEvent, end: Bool)] = try [
                ("End", key(119, "\u{F72B}", [.function], in: host), true),
                ("Home", key(115, "\u{F729}", [.function], in: host), false),
                ("Command-Down", key(125, "\u{F701}", [.command, .function, .numericPad], in: host), true),
                ("Command-Up", key(126, "\u{F700}", [.command, .function, .numericPad], in: host), false),
            ]
            for move in moves {
                let label = "\(flow): \(move.label)"
                if move.event.modifierFlags.contains(.command) {
                    XCTAssertTrue(canvas.handlePageKeyEquivalent(move.event), label)
                } else {
                    try XCTUnwrap(canvas.textViews.first).keyDown(with: move.event)
                }
                XCTAssertEqual(canvas.canTurnPage(forward: move.end), false, label)
                XCTAssertEqual(canvas.canTurnPage(forward: !move.end), true, label)
                if move.end {
                    XCTAssertEqual(canvas.visibleRange?.end.section, 2, label)
                    if flow == .paginated { XCTAssertEqual(canvas.visibleRange?.end, try bookEnd(host), label) }
                } else {
                    XCTAssertEqual(canvas.visibleRange?.start, bookStart(host), label)
                }
            }
        }
    }
    #else
    /// Home and End go to the book's start and end in both flows, past its nonlinear sections, on
    /// an iPad's keyboard; Command-Up and Command-Down are the Mac's alone.
    func testHomeAndEndKeyCommandsGoToTheBooksStartAndEnd() throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let host = keyHost(flow: flow)
            let canvas = host.canvas
            let commands = canvas.pageKeyCommands
            let home = try XCTUnwrap(commands.first { $0.input == UIKeyCommand.inputHome && $0.modifierFlags.isEmpty })
            let end = try XCTUnwrap(commands.first { $0.input == UIKeyCommand.inputEnd && $0.modifierFlags.isEmpty })
            XCTAssertFalse(commands.contains { $0.input == UIKeyCommand.inputUpArrow || $0.input == UIKeyCommand.inputDownArrow })
            let action = #selector(ReaderCanvasView.pageTurnKeyCommand(_:))
            XCTAssertTrue(canvas.canPerformAction(action, withSender: home), "\(flow)")
            XCTAssertTrue(try XCTUnwrap(canvas.textViews.first).canPerformAction(action, withSender: end), "\(flow)")
            try XCTUnwrap(canvas.textViews.first).pageTurnKeyCommand(end)
            XCTAssertEqual(canvas.canTurnPage(forward: true), false, "\(flow): End")
            XCTAssertEqual(canvas.visibleRange?.end.section, 2, "\(flow): End")
            if flow == .paginated { XCTAssertEqual(canvas.visibleRange?.end, try bookEnd(host), "\(flow): End") }
            canvas.pageTurnKeyCommand(home)
            XCTAssertEqual(canvas.canTurnPage(forward: false), false, "\(flow): Home")
            XCTAssertEqual(canvas.visibleRange?.start, bookStart(host), "\(flow): Home")
        }
    }

    /// A hardware keyboard's page keys reach the reader only through its responders, and UIKit
    /// gives nothing focus by itself: on an iPad simulator `XCUIElement.typeKey` Home, End and
    /// Right Arrow did nothing with no view focused. The reader takes keyboard focus when it is
    /// shown and when it is touched, but leaves a field that holds it alone.
    func testTheReaderTakesTheKeyboardFocusNoOtherViewHolds() throws {
        let host = keyHost(flow: .paginated)
        let canvas = host.canvas
        XCTAssertTrue(canvas.hasKeyboardFocus, "shown with no view focused")
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        host.window.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        XCTAssertFalse(canvas.hasKeyboardFocus)
        canvas.takeKeyboardFocusIfFree()
        XCTAssertTrue(field.isFirstResponder, "a field keeps its focus and its keyboard")
        XCTAssertFalse(canvas.hasKeyboardFocus)
        XCTAssertTrue(field.resignFirstResponder())
        canvas.takeKeyboardFocusIfFree()
        XCTAssertTrue(canvas.hasKeyboardFocus, "a touch takes the focus once no view holds it")
    }
    #endif

    /// The book's end in a section not built yet is asked of the delegate, which shows its end
    /// once it is (`NativeSession.canvas(_:needsSection:forward:reason:)`).
    func testTheBooksEndInASectionNotBuiltIsAskedFor() throws {
        let host = keyHost(flow: .paginated, buildEnd: false)
        host.canvas.performPageActionFromInput(.bookEnd)
        XCTAssertEqual(host.recorder.needed.last?.section, 2)
        XCTAssertEqual(host.recorder.needed.last?.forward, false)
    }

    /// The book's start and end are named and helped by their keys alone: no tap, swipe or wheel
    /// goes there.
    func testTheBooksStartAndEndAreNamedAndHelpedByTheirKeys() {
        let controls = EPUBPageControls()
        #if os(macOS)
        XCTAssertEqual(controls.helpHints(for: .bookStart, paginated: true, isRightToLeft: false, platform: .mouse),
                       ["With reader focus: Home, Command-Up Arrow"])
        XCTAssertEqual(controls.helpHints(for: .bookEnd, paginated: true, isRightToLeft: true, platform: .mouse),
                       ["With reader focus: End, Command-Down Arrow"])
        #else
        XCTAssertEqual(controls.helpHints(for: .bookStart, paginated: true, isRightToLeft: false, platform: .touch),
                       ["With reader focus: Home"])
        XCTAssertEqual(controls.helpHints(for: .bookEnd, paginated: true, isRightToLeft: true, platform: .touch),
                       ["With reader focus: End"])
        #endif
        XCTAssertTrue(EPUBPageControls.hostOnly.helpHints(for: .bookEnd, paginated: true, isRightToLeft: false, platform: .touch).isEmpty)
        XCTAssertEqual(EPUBPageAction.bookStart.label(in: .paginated), "First Page")
        XCTAssertEqual(EPUBPageAction.bookEnd.label(in: .paginated), "Last Page")
        XCTAssertEqual(EPUBPageAction.bookStart.label(in: .scrolled), "Scroll to Beginning")
        XCTAssertEqual(EPUBPageAction.bookEnd.label(in: .scrolled), "Scroll to End")
        XCTAssertEqual(EPUBReaderCommand.goToStart, .goToProgression(0))
        XCTAssertEqual(EPUBReaderCommand.goToEnd, .goToProgression(1))
    }
}
