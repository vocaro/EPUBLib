import CryptoKit
import EPUBCore
import EPUBReading
import EPUBTestSupport
import Foundation
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#endif

@MainActor final class NavigationSequenceTests: XCTestCase {
    private func wait(_ label: String, timeout: TimeInterval = 30, until condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(label)")
                return false
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func testWholeBookJumpConvergesAfterSparseEndAndDiagramVisits() async throws {
        var diagrams: [Int] = []
        let sections = (0..<74).map { index -> NSAttributedString in
            if index == 73 { return CanvasText.body(" \n", size: 17) }
            if index >= 67 {
                return CanvasText.body((0..<4_000).map { "entry \($0)" }.joined(separator: "\n"))
            }
            let section = NSMutableAttributedString(attributedString:
                CanvasText.section(index, chapters: 1, paragraphs: 45))
            if index == 66 {
                for height in [260, 440, 600] {
                    section.append(CanvasText.body("\n"))
                    diagrams.append(section.length)
                    section.append(CanvasText.attachment(size: CGSize(width: 650, height: height)))
                    section.append(CanvasText.body("\n" + CanvasText.sentence(140, seed: height)))
                }
            }
            return section
        }
        let source = FakeCanvasSource(sections)
        source.book = CanvasText.book(sections)
        let host = CanvasHost(source, size: CGSize(width: 800, height: 600))
        defer { host.close() }
        for index in sections.indices {
            host.canvas.show(ReaderTextPosition(section: index, offset: 0), selecting: nil)
        }
        host.resize(to: CGSize(width: 800, height: 700))
        host.canvas.configuration.flow = .scrolled
        for offset in diagrams {
            let target = ReaderTextPosition(section: 66, offset: offset)
            host.canvas.show(target, selecting: nil)
            let view = try XCTUnwrap(host.canvas.scrollTextView)
            view.scrollRangeToVisible(NSRange(location: try XCTUnwrap(source.book).location(of: target), length: 1))
            try await host.settle(200)
        }
        for target in [ReaderTextPosition(section: 42, offset: 12_000),
                       ReaderTextPosition(section: 12, offset: 5_000),
                       ReaderTextPosition(section: 71, offset: 8_000)] {
            XCTAssertLessThan(target.offset, sections[target.section].length)
            host.canvas.show(target, selecting: nil)
            let shown = try XCTUnwrap(host.canvas.visibleRange?.start)
            XCTAssertEqual(shown.section, target.section)
            XCTAssertLessThanOrEqual(shown.offset, target.offset)
            XCTAssertGreaterThan(shown.offset, target.offset - 200, "The target's actual line must be at the viewport top")
        }
        let target = ReaderTextPosition(section: 42, offset: 12_000)
        host.canvas.show(target, selecting: nil)
        for width in [390, 800] {
            host.resize(to: CGSize(width: width, height: 600))
            let shown = try XCTUnwrap(host.canvas.visibleRange?.start)
            XCTAssertEqual(shown.section, target.section)
            XCTAssertLessThanOrEqual(shown.offset, target.offset)
            XCTAssertGreaterThan(shown.offset, target.offset - 200)
        }
        host.canvas.show(ReaderTextPosition(section: 73, offset: sections[73].length), selecting: nil)
        XCTAssertTrue(host.canvas.isScrolledToEnd)
        let view = try XCTUnwrap(host.canvas.scrollTextView)
        let last = try XCTUnwrap(view.lineFrame(containing: try XCTUnwrap(source.book).string.length - 1))
        let visible = host.canvas.scrollVisibleContainerRect
        XCTAssertGreaterThan(last.maxY, visible.minY)
        XCTAssertLessThanOrEqual(last.maxY, visible.maxY + 1)
        host.canvas.show(ReaderTextPosition(section: 0, offset: 0), selecting: nil)
        XCTAssertTrue(host.canvas.isScrolledToStart)
        XCTAssertEqual(host.canvas.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
    }

    #if os(macOS)
    /// Local qualification against the unchanged publisher EPUB from issue #41. The copyrighted
    /// book is deliberately absent from test resources; provide its path to opt in.
    func testPublisherSectionNavigationAfterDiagramVisits() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBLIB_NAVIGATION_EPUB"] else {
            throw XCTSkip("Set EPUBLIB_NAVIGATION_EPUB to the publisher EPUB described in issue #41")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "0529d143930199a315ac7c6f60f71ec8357321e7781851894f9f329e406081f5")
        let publication = try EPUBPublication.open(data: data)
        XCTAssertEqual(publication.spine.count, 74)
        var locations: [EPUBLocation] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication) {
            if case .relocated(let location) = $0 { locations.append(location) }
        } as? NativeSession)
        let window = ReaderTestWindow(session: session)
        window.resize(to: CGSize(width: 800, height: 600))
        defer { session.close(); window.close() }
        guard try await wait("ready", until: { session.isReady }) else { return }
        for item in publication.spine {
            try await session.send(.navigate(href: item.resource.path))
            guard try await wait(item.resource.path, until: { session.lastLocation?.href == item.resource.path }) else { return }
        }
        window.resize(to: CGSize(width: 800, height: 700))
        try await session.send(.style(.init(fontSize: 17, isDark: false, flow: .scrolled)))
        guard try await wait("complete scroll book", timeout: 60, until: {
            session.book.isComplete && session.canvas?.scrollBook != nil
        }) else { return }
        let diagrams = ["A dashboard wireframe", "Three line charts", "Three panels explaining"]
        for (fragment, alternative) in zip(["toc_id_410", "toc_id_412", "toc_id_414"], diagrams) {
            let count = locations.count
            try await session.send(.navigate(href: "index_split_065.html#\(fragment)"))
            guard try await wait(fragment, until: {
                locations.dropFirst(count).contains { $0.href == "index_split_065.html" }
            }) else { return }
            let view = try XCTUnwrap(session.canvas?.scrollTextView)
            let storage = try XCTUnwrap(view.contentStorage.textStorage)
            var diagram: NSRange?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if let value = value as? any ReaderTextualAttachment, value.textEquivalent.hasPrefix(alternative) {
                    diagram = range; stop.pointee = true
                }
            }
            let range = try XCTUnwrap(diagram, "Missing original diagram: \(alternative)")
            view.scrollRangeToVisible(range)
            try await Task.sleep(for: .milliseconds(200))
        }
        let count = locations.count
        try await session.send(.navigate(href: "index_split_041.html#toc_id_238"))
        guard try await wait("strict matching target relocation", until: {
            locations.dropFirst(count).contains { $0.href == "index_split_041.html" }
        }) else { return }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.lastLocation?.href, "index_split_041.html")
        let index = try XCTUnwrap(publication.spine.firstIndex { $0.resource.path == "index_split_041.html" })
        let section = try XCTUnwrap(session.book.section(index))
        let target = try XCTUnwrap(section.anchors["toc_id_238"])
        let shown = try XCTUnwrap(session.canvas?.visibleRange)
        XCTAssertEqual(shown.start.section, index)
        XCTAssertLessThanOrEqual(abs(shown.start.offset - target), 100, "Requested heading should be at the viewport top")
        let saved = try XCTUnwrap(session.lastLocation)
        try await session.send(.navigate(href: "index_split_065.html#toc_id_410"))
        try await session.send(.restore(saved))
        guard try await wait("restored target document", until: { session.lastLocation?.href == "index_split_041.html" }) else { return }
        XCTAssertEqual(session.canvas?.visibleRange?.start, shown.start)
        let canvas = try XCTUnwrap(session.canvas)
        let view = try XCTUnwrap(canvas.scrollTextView)
        let frame = try XCTUnwrap(view.lineFrame(containing: try XCTUnwrap(canvas.scrollBook).location(of: shown.start)))
        XCTAssertEqual(frame.minY, canvas.scrollVisibleContainerRect.minY, accuracy: 1,
            "The saved target must be physically aligned, not just reported in a relocation")
        if let output = ProcessInfo.processInfo.environment["EPUBLIB_NAVIGATION_SNAPSHOT"],
           let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
    #endif
}
