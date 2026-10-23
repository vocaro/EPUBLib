import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SessionCoverageTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Books for the session coverage tests, built in code from original synthetic text.
enum SessionCoverageBook {
    struct Section {
        var name: String
        var body: String
        var linear = true
        var title: String?
        /// The whole document, in place of the XHTML wrapper around `body`.
        var raw: String?
        init(_ name: String, _ body: String = "", linear: Bool = true, title: String? = nil, raw: String? = nil) {
            self.name = name; self.body = body; self.linear = linear; self.title = title; self.raw = raw
        }
    }

    static func filler(_ count: Int) -> String {
        String(repeating: "<p>A paragraph of ordinary reading text for pagination.</p>", count: count)
    }

    static func page(_ title: String, _ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
            + "<head><title>\(title)</title></head><body>\(body)</body></html>"
    }

    private static func encoded(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#%?")))!
    }

    /// `toc`, `landmarks` and `pageList` are the `<li>` markup of each navigation list; a nil `toc`
    /// lists every section by its title, and a nil `landmarks` or `pageList` leaves that list out.
    /// `guide` is a whole OPF `<guide>` element and `manifest` extra `<item>` elements.
    /// `language` is the package's `dc:language`.
    static func epub(_ sections: [Section], toc: String? = nil, landmarks: String? = nil, pageList: String? = nil,
                     guide: String = "", manifest: String = "", spine: String = "", files: [String: String] = [:],
                     epub2: Bool = false, language: String = "en") throws -> Data {
        let items = sections.enumerated().map {
            "<item id=\"s\($0.offset)\" href=\"\(encoded($0.element.name)).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let itemrefs = sections.enumerated().map { "<itemref idref=\"s\($0.offset)\"\($0.element.linear ? "" : " linear=\"no\"")/>" }.joined()
        let entries = toc ?? sections.map { "<li><a href=\"\(encoded($0.name)).xhtml\">\($0.title ?? $0.name)</a></li>" }.joined()
        var nav = "<nav epub:type=\"toc\"><ol>\(entries)</ol></nav>"
        if let landmarks { nav += "<nav epub:type=\"landmarks\"><ol>\(landmarks)</ol></nav>" }
        if let pageList { nav += "<nav epub:type=\"page-list\"><ol>\(pageList)</ol></nav>" }
        var archive: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "OPS/book.opf": """
            <package xmlns="http://www.idpf.org/2007/opf" version="\(epub2 ? "2.0" : "3.0")" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>A Session Coverage Book</dc:title><dc:language>\(language)</dc:language><dc:identifier id="uid">session-coverage-book</dc:identifier></metadata><manifest>\(items)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" \(epub2 ? "" : "properties=\"nav\"")/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\(manifest)</manifest><spine toc="ncx"\(spine)>\(itemrefs)</spine>\(guide)</package>
            """,
            "OPS/nav.xhtml": page("Contents", nav),
            "OPS/toc.ncx": "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><navMap/></ncx>",
        ]
        for section in sections {
            archive["OPS/\(section.name).xhtml"] = section.raw ?? page(section.title ?? section.name, section.body)
        }
        archive.merge(files) { _, replacement in replacement }
        return try Fixture.archive(archive)
    }

    /// Three chapters and a nonlinear note between the first two. Chapter two has a `mid` anchor
    /// many pages in; the note and chapter three both hold the word "findword".
    static func chapters() throws -> Data {
        try epub([
            Section("one", "<h1 id=\"start\">First Chapter</h1><p>Opening words are visible.</p>\(filler(40))", title: "First Chapter"),
            Section("note", "<p id=\"note\">A nonlinear note holding findword apart.</p>", linear: false, title: "Note"),
            Section("two", "<h1 id=\"start\">Second Chapter</h1><p>The unique destination passage lives here.</p>\(filler(70))"
                + "<p id=\"mid\">A marked midpoint paragraph sits here.</p>\(filler(70))", title: "Second Chapter"),
            Section("three", "<h1>Third Chapter</h1><p>Closing words with findword at the end.</p>\(filler(30))", title: "Third Chapter"),
        ], toc: "<li><a href=\"one.xhtml\">First Chapter</a></li><li><a href=\"two.xhtml\">Second Chapter</a></li>"
            + "<li><a href=\"three.xhtml\">Third Chapter</a></li>")
    }
}

/// A native session with its events recorded, optionally mounted in a `ReaderTestWindow`.
@MainActor final class SessionCoverageReader {
    @MainActor private final class Sink {
        var events: [EPUBReaderEvent] = []
        var onEvent: (@MainActor (EPUBReaderEvent) -> Void)?
    }

    let publication: EPUBPublication
    let session: NativeSession
    private(set) var window: ReaderTestWindow?
    private let sink: Sink

    /// `onEvent` runs inside the session's callback, after the event is recorded.
    convenience init(_ data: Data, action: EPUBSelectionAction? = nil, mounted: Bool = true,
                     onEvent: (@MainActor (EPUBReaderEvent) -> Void)? = nil) throws {
        try self.init(publication: EPUBPublication.open(data: data), action: action, mounted: mounted, onEvent: onEvent)
    }

    init(publication: EPUBPublication, action: EPUBSelectionAction? = nil, mounted: Bool = true,
         onEvent: (@MainActor (EPUBReaderEvent) -> Void)? = nil) throws {
        let sink = Sink()
        sink.onEvent = onEvent
        self.sink = sink
        self.publication = publication
        session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: action) { event in
            sink.events.append(event)
            sink.onEvent?(event)
        } as? NativeSession)
        if mounted { window = ReaderTestWindow(session: session) }
    }

    var events: [EPUBReaderEvent] { sink.events }
    var onEvent: (@MainActor (EPUBReaderEvent) -> Void)? {
        get { sink.onEvent }
        set { sink.onEvent = newValue }
    }
    var state: EPUBReaderState { session.readerState! }
    var locations: [EPUBLocation] { locations(since: 0) }
    func locations(since index: Int) -> [EPUBLocation] {
        events.dropFirst(index).compactMap { if case .relocated(let location) = $0 { return location }; return nil }
    }
    func notices(since index: Int = 0) -> [String] {
        events.dropFirst(index).compactMap { if case .notice(let text) = $0 { return text }; return nil }
    }
    func selections(since index: Int = 0) -> [EPUBSelection?] {
        events.dropFirst(index).compactMap { if case .selectionChanged(let value) = $0 { return .some(value) }; return nil }
    }
    var section: Int? { session.visibleRange?.start.section }

    func mount() { window = ReaderTestWindow(session: session) }
    func close() { session.close(); window?.close(); window = nil }

    func wait(_ label: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
              until condition: () -> Bool) async throws {
        let deadline = TestDeadline(seconds: timeout)
        while !condition() {
            guard try !deadline.hasPassed() else {
                throw SessionCoverageTimeout(description: "Timed out waiting for \(label) (\(file):\(line))")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Ready, located and with every section built for the current typography.
    func settle(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wait("a ready, built and located reader", file: file, line: line) {
            session.isReady && session.book.isComplete && session.book.hasAnnouncedCompletion && session.lastLocation != nil && locations.last == session.lastLocation
        }
    }

    func isVisible(_ position: ReaderTextPosition) -> Bool {
        session.visibleRange.map { $0.start <= position && position < $0.end } ?? false
    }

    func anchor(_ id: String, section: Int) throws -> ReaderTextPosition {
        ReaderTextPosition(section: section, offset: try XCTUnwrap(session.book.section(section)?.anchors[id], "no anchor \(id)"))
    }

    /// Sends a command expecting `invalidCommand`, whatever its message.
    func refuses(_ command: EPUBReaderCommand, _ label: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await session.send(command)
            XCTFail("Accepted \(label)", file: file, line: line)
        } catch {
            guard case .invalidCommand = error as? EPUBReaderError else {
                return XCTFail("\(label): expected invalidCommand, received \(error)", file: file, line: line)
            }
        }
    }
}

/// What a host observes and toggles around a mounted reader: whether the view is in the
/// hierarchy, and the fold it reserves.
@MainActor @Observable final class SessionCoverageStage {
    var mounted = true
    var division: CGRect?
}

private struct SessionCoverageStageView: View {
    let session: any EPUBReaderSession
    let stage: SessionCoverageStage
    var body: some View {
        ZStack {
            if stage.mounted { EPUBReaderView(session: session).epubReaderDivision(stage.division) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A window whose reader the test can take out of the hierarchy and put back, as a host's own
/// navigation does, without closing the session.
@MainActor final class SessionCoverageStageWindow {
    let stage = SessionCoverageStage()
    #if os(macOS)
    private let window: NSWindow
    #else
    private let window: UIWindow
    #endif

    init(session: any EPUBReaderSession, size: CGSize = CGSize(width: 600, height: 700)) {
        let view = SessionCoverageStageView(session: session, stage: stage)
        #if os(macOS)
        window = makeMacTestWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.keepLightAppearance()
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        #else
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
        window.keepLightAppearance()
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        #endif
    }

    func close() {
        #if os(macOS)
        window.close()
        window.contentView = nil
        #else
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }
}
