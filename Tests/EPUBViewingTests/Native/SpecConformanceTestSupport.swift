import CoreText
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

/// A `Fixture.SpecBook` through the reader as a host uses it: opened from its archive bytes and
/// every spine section built with the production cascade and rich-content factory.
@MainActor struct SpecConformanceBuild {
    typealias Book = Fixture.SpecBook

    let publication: EPUBPublication
    let sections: [SectionText]

    init(_ book: Book, fontSize: CGFloat = 16) throws {
        try self.init(archive: book.archive(), fontSize: fontSize)
    }

    init(archive: Data, fontSize: CGFloat = 16) throws {
        publication = try EPUBPublication.open(data: archive)
        let fonts = FontRegistry(publication: publication)
        let rich = NativeEngine().rich
        let publication = publication
        sections = publication.spine.indices.map {
            SectionBuilder.build(SectionBuildRequest(publication: publication, spineIndex: $0,
                typography: NativeTypography(fontSize: fontSize), fonts: fonts, rich: rich))
        }
    }

    subscript(index: Int) -> SectionText { sections[index] }

    var report: SectionReport {
        sections.reduce(into: SectionReport()) { $0.formUnion($1.report) }
    }

    /// What the host is told to disclose for the whole book.
    var disclosure: String? { NativeDisclosure.text(for: report) }

    /// Every rendered offset of every section names a DOM position whose CFI resolves back to
    /// it through the package's spine, and the text map round-trips.
    func assertPositionsRoundTrip(file: StaticString = #filePath, line: UInt = #line) throws {
        let spine = try SpineCFIs(publication: publication)
        for section in sections where section.document.canResolveCFIs && !section.report.withheld {
            BuilderHarness.assertMapRoundTrips(section, file: file, line: line)
            for location in stride(from: 0, through: section.string.length, by: max(1, section.string.length / 40)) {
                guard let position = section.map.position(at: location, in: section.document) else { continue }
                let cfi = spine.cfi(spineIndex: section.spineIndex, start: position, end: position, in: section.document)
                XCTAssertTrue(EPUBCFI.isWellFormed(cfi), cfi, file: file, line: line)
                guard let target = spine.resolve(cfi), let resolved = EPUBCFI.resolve(localPath: target.localPath, in: section.document) else {
                    XCTFail("\(cfi) does not resolve", file: file, line: line); continue
                }
                XCTAssertEqual(target.spineIndex, section.spineIndex, cfi, file: file, line: line)
                XCTAssertEqual(section.map.location(of: resolved.start), section.map.location(of: position), cfi, file: file, line: line)
            }
        }
    }
}

extension SectionText {
    /// The rendered characters, attachments as U+FFFC.
    var specText: String { string.string }

    func specLocation(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let range = (string.string as NSString).range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound, "\(phrase.debugDescription) is not rendered in \(string.string.debugDescription)", file: file, line: line)
        return range.location == NSNotFound ? 0 : range.location
    }

    func specAttribute<Value>(_ key: NSAttributedString.Key, at phrase: String, file: StaticString = #filePath, line: UInt = #line) -> Value? {
        guard string.length > 0 else { return nil }
        return string.attribute(key, at: specLocation(phrase, file: file, line: line), effectiveRange: nil) as? Value
    }

    func specParagraph(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) -> NSParagraphStyle {
        specAttribute(.paragraphStyle, at: phrase, file: file, line: line) ?? NSParagraphStyle()
    }

    func specFont(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) -> PlatformFont {
        specAttribute(.font, at: phrase, file: file, line: line) ?? PlatformFont.systemFont(ofSize: 1)
    }

    func specFamily(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        CTFontCopyFamilyName(specFont(phrase, file: file, line: line) as CTFont) as String
    }

    func specLink(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) -> ReaderLink? {
        (specAttribute(.link, at: phrase, file: file, line: line) as URL?).flatMap(ReaderLink.init(url:))
    }

    /// The section's attachments in order, with where each stands.
    var specAttachments: [(location: Int, attachment: NSTextAttachment)] {
        var found: [(Int, NSTextAttachment)] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { found.append((range.location, attachment)) }
        }
        return found
    }

    var specImages: [ReaderImageAttachment] { specAttachments.compactMap { $0.attachment as? ReaderImageAttachment } }

    /// The pages the section paginates into in a column of `size`, as the canvas slices them.
    @MainActor func specPages(_ size: CGSize) -> (paginator: ReaderPaginator, pages: [ReaderPage]) {
        let paginator = ReaderPaginator(text: string, size: size)
        return (paginator, paginator.allPages)
    }
}

extension ReaderImageAttachment {
    /// The size the image takes on a line of `width` in a `viewport`.
    func specSize(lineWidth width: CGFloat, viewport: CGSize = CGSize(width: 400, height: 600)) -> CGSize {
        layoutBounds(ReaderAttachment.Line(width: width, viewport: viewport)).size
    }
}

/// A mounted reader over a `Fixture.SpecBook`, driven through the public commands.
@MainActor final class SpecConformanceReader {
    let session: NativeSession
    let window: ReaderTestWindow
    private(set) var events: [EPUBReaderEvent] = []

    init(_ book: Fixture.SpecBook) throws {
        let publication = try EPUBPublication.open(data: book.archive())
        var sink: ((EPUBReaderEvent) -> Void)?
        session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { sink?($0) } as? NativeSession)
        window = ReaderTestWindow(session: session)
        sink = { [weak self] in self?.events.append($0) }
    }

    func close() { session.close(); window.close() }

    var locations: [EPUBLocation] { events.compactMap { if case .relocated(let location) = $0 { return location }; return nil } }
    var disclosures: [String] { events.compactMap { if case .disclosure(let text) = $0 { return text }; return nil } }
    var notices: [String] { events.compactMap { if case .notice(let text) = $0 { return text }; return nil } }

    func wait(_ label: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
              until condition: () -> Bool) async throws {
        let deadline = TestDeadline(seconds: timeout)
        while !condition() {
            guard try !deadline.hasPassed() else { return XCTFail("Timed out waiting for \(label)", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Ready, every section built and the opening position reported.
    func waitUntilReady(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wait("ready, built and located", file: file, line: line) {
            events.contains(.ready) && session.book.isComplete && session.lastLocation != nil && session.visibleRange != nil
        }
    }

    /// The text on screen: the visible range's characters.
    var visibleText: String {
        guard let range = session.visibleRange, let section = session.book.section(range.start.section) else { return "" }
        let end = range.end.section == range.start.section ? range.end.offset : section.string.length
        return (section.string.string as NSString).substring(with: NSRange(location: range.start.offset, length: max(0, end - range.start.offset)))
    }

    /// Turns pages forward to the book's end, returning the section each page starts in.
    func pageThrough(limit: Int = 400) async throws -> [Int] {
        var visited = [session.visibleRange?.start.section ?? -1]
        for _ in 0..<limit {
            guard session.readerState?.status.canGoNext != false else { break }
            let before = session.visibleRange
            try await session.send(.nextPage)
            try await wait("the next page") { session.visibleRange != before || session.readerState?.status.canGoNext == false }
            if let section = session.visibleRange?.start.section, section != visited.last { visited.append(section) }
        }
        return visited
    }
}
