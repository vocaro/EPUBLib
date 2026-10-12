import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

/// The command table of `doc/native-viewer.md`, row by row, on a mounted native session.
@MainActor final class SessionCoverageCommandTests: XCTestCase {
    private typealias Section = SessionCoverageBook.Section

    private func open(_ data: Data, action: EPUBSelectionAction? = nil) throws -> SessionCoverageReader {
        let reader = try SessionCoverageReader(data, action: action)
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    private func bookmark(_ cfi: String) -> EPUBEngineBookmark {
        EPUBEngineBookmark(engineID: EPUBReader.identifier, format: EPUBReader.bookmarkFormat, value: cfi)
    }

    private func everyCommand(_ publicationID: String) -> [EPUBReaderCommand] {
        let location = EPUBLocation(publicationID: publicationID, bookmark: bookmark("epubcfi(/6/2!/4/2/1:0)"))
        return [
            .nextPage, .previousPage, .restore(location), .navigate(href: "OPS/one.xhtml"), .locate(text: "Opening words", highlight: true),
            .search(text: "Opening"), .searchHighlight(text: "Opening"), .clearSearch, .nextSearchResult, .previousSearchResult,
            .showSearchResult(EPUBSearchResult(index: 0, location: location, spineIndex: 0, matchedText: "Opening")),
            .style(EPUBReaderStyle(fontSize: 20)), .setHighlights([EPUBHighlight(id: "h", location: location)]),
            // Commands the reader would refuse for their content are refused for its state first.
            .navigate(href: ""), .locate(text: "", highlight: false), .search(text: " "), .style(EPUBReaderStyle(fontSize: .nan)),
            .restore(EPUBLocation(publicationID: "another book")),
        ]
    }

    // MARK: Lifecycle

    /// `doc/architecture.md`, Engine contract: "Cancellation before submission throws
    /// `CancellationError`", commands need a mounted, ready reader, and after `close` every
    /// command fails and callbacks are disabled.
    func testEveryCommandIsRefusedBeforeMountingWhenCancelledAndAfterClosing() async throws {
        let reader = try SessionCoverageReader(Fixture.epub(), mounted: false)
        defer { reader.close() }
        let session = reader.session
        for command in everyCommand(reader.publication.id) {
            do { try await session.send(command); XCTFail("An unmounted reader accepted \(command)") }
            catch { XCTAssertEqual(error as? EPUBReaderError, .notReady, "\(command)") }
            let cancelled = Task { try await session.send(command) }
            cancelled.cancel()
            do { try await cancelled.value; XCTFail("A cancelled \(command) was accepted") } catch is CancellationError {} catch {
                XCTFail("A cancelled \(command) threw \(error)")
            }
        }
        XCTAssertTrue(reader.events.isEmpty, "an unmounted reader emits nothing: \(reader.events)")
        XCTAssertEqual(reader.state.status.lifecycle, .loading)
        XCTAssertEqual(reader.state.status.search, .idle, "a search that was never submitted reports no failure")
        XCTAssertEqual(reader.state.status.activeCommands, 0)
        XCTAssertEqual(reader.state.status.style, EPUBReaderStyle())

        session.close()
        session.close()
        for command in everyCommand(reader.publication.id) {
            do { try await session.send(command); XCTFail("A closed reader accepted \(command)") }
            catch { XCTAssertEqual(error as? EPUBReaderError, .closed, "\(command)") }
            // Cancellation is still reported first.
            let cancelled = Task { try await session.send(command) }
            cancelled.cancel()
            do { try await cancelled.value; XCTFail("A cancelled \(command) was accepted") } catch is CancellationError {} catch {
                XCTFail("A cancelled \(command) threw \(error)")
            }
        }
        XCTAssertTrue(reader.events.isEmpty)
        XCTAssertEqual(reader.state.status.lifecycle, .closed)
        XCTAssertEqual(reader.state.status.activeCommands, 0)
    }

    /// "Views returned by a closed session contain no reader."
    func testASessionClosedBeforeMountingNeverBecomesReady() async throws {
        let reader = try SessionCoverageReader(Fixture.epub(), mounted: false)
        defer { reader.close() }
        reader.session.close()
        reader.mount()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(reader.session.canvas)
        XCTAssertFalse(reader.session.isReady)
        XCTAssertTrue(reader.events.isEmpty, "\(reader.events)")
        XCTAssertEqual(reader.state.status.lifecycle, .closed)
    }

    /// The whole public route a host takes: `EPUBReader` as an `EPUBReaderEngine`, the session
    /// as an `EPUBReaderSession`, `EPUBReaderView` to mount it.
    func testThePublicEngineOpensABookAtItsStartWithEveryCapability() async throws {
        let publication = try EPUBPublication.open(data: Fixture.epub())
        let engine: any EPUBReaderEngine = EPUBReader()
        XCTAssertEqual(engine.id, "org.epublib.reader")
        XCTAssertEqual(EPUBReader.identifier, engine.id)
        XCTAssertEqual(EPUBReader.bookmarkFormat, "epublib-cfi-v1")
        var events: [EPUBReaderEvent] = []
        let session = try engine.makeSession(publication: publication, selectionAction: nil) { events.append($0) }
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        // `doc/architecture.md`: "sessions advertise every capability".
        XCTAssertEqual(session.capabilities, [.pagination, .scrolling, .typography, .selection, .bookmarks, .locateText,
                                              .navigateHref, .searchHighlight, .highlights, .search, .searchResults])
        let state = try XCTUnwrap(session.readerState)
        XCTAssertEqual(state.status.capabilities, session.capabilities)
        func wait(_ label: String, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() {
                guard Date() < deadline else { throw SessionCoverageTimeout(description: "Timed out waiting for \(label)") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func locations() -> [EPUBLocation] { events.compactMap { if case .relocated(let location) = $0 { return location }; return nil } }
        try await wait("the first location") { !locations().isEmpty }
        XCTAssertEqual(events.first, .ready, "readiness comes before anything else")
        let first = try XCTUnwrap(locations().first)
        XCTAssertEqual(first.publicationID, publication.id)
        XCTAssertEqual(first.href, "OPS/one.xhtml")
        XCTAssertEqual(first.title, "First Chapter")
        XCTAssertEqual(first.bookmark?.engineID, EPUBReader.identifier)
        XCTAssertEqual(first.bookmark?.format, EPUBReader.bookmarkFormat)
        XCTAssertNil(first.quote)
        XCTAssertNil(first.rangeBookmarks)
        XCTAssertEqual(state.status.location, locations().last)
        XCTAssertEqual(state.status.lifecycle, .ready)
        try await session.send(.navigate(href: publication.spine[1].resource.href))
        try await wait("the second chapter") { state.status.location?.href == "OPS/two.xhtml" }
        XCTAssertEqual(locations().last?.href, "OPS/two.xhtml")
        XCTAssertEqual(events.filter { $0 == .ready }.count, 1)
    }

    // MARK: navigate(href:)

    /// "An encoded spine or resource href with optional fragment; unknown or non-local hrefs
    /// throw `invalidCommand`."
    func testNavigationRefusesWhatIsNotASectionOfThisBookAndStaysWhereItIs() async throws {
        let reader = try open(SessionCoverageBook.epub([
            Section("one", "<h1 id=\"start\">One</h1>\(SessionCoverageBook.filler(30))"),
            Section("two", "<h1 id=\"start\">Two</h1>\(SessionCoverageBook.filler(30))"),
        ], manifest: "<item id=\"pic\" href=\"pic.png\" media-type=\"image/png\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>",
           files: ["OPS/pic.png": "not really a png", "OPS/style.css": "p { margin: 0 }"]))
        try await reader.settle()
        XCTAssertTrue(reader.publication.resources.contains { $0.path == "OPS/pic.png" })
        let original = reader.session.visibleRange
        let count = reader.events.count
        let refused = [
            "", "#start", "?", "OPS/", "OPS", "OPS/missing.xhtml", "OPS/missing.xhtml#start",
            // Resources of the book that are not in its spine.
            "OPS/pic.png", "OPS/style.css", "OPS/nav.xhtml", "OPS/toc.ncx", "OPS/book.opf", "META-INF/container.xml", "mimetype",
            // A query, another origin, another scheme.
            "OPS/two.xhtml?page=2", "OPS/two.xhtml?", "OPS/two.xhtml?a#start", "https://example.invalid/OPS/two.xhtml",
            "//example.invalid/OPS/two.xhtml", "file:///OPS/two.xhtml", "mailto:reader@example.invalid", "javascript:void(0)",
            // Archive paths are case-sensitive and hrefs carry no surrounding space.
            "OPS/TWO.xhtml", "ops/two.xhtml", "OPS/Two.XHTML", " OPS/two.xhtml", "OPS/two.xhtml ", "OPS/two.xhtml\n",
            // Not an encoded reference at all.
            "OPS/two%.xhtml", "OPS/two%zz.xhtml", "OPS\\two.xhtml", "two.xhtml", "../OPS/two.xhtml",
            "OPS/two.xhtml#" + String(repeating: "x", count: 5_000),
        ]
        for href in refused { await reader.refuses(.navigate(href: href), "the href \(href.prefix(60).debugDescription)") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reader.session.visibleRange, original, "a refused navigation moved the reader")
        XCTAssertEqual(reader.events.count, count, "a refused navigation emitted \(reader.events.dropFirst(count))")
        XCTAssertEqual(reader.state.status.activeCommands, 0)
    }

    func testNavigationAcceptsEquivalentEncodingsAndShowsAnUnknownFragmentsSection() async throws {
        let reader = try open(SessionCoverageBook.epub([
            Section("one", "<h1 id=\"start\">One</h1>\(SessionCoverageBook.filler(30))"),
            Section("caf\u{E9} na\u{EF}ve", "<h1>Accented</h1>\(SessionCoverageBook.filler(80))<p id=\"r\u{E9}sum\u{E9} point\">The marked place.</p>"
                + SessionCoverageBook.filler(80)),
            Section("three", "<h1 id=\"start\">Three</h1>\(SessionCoverageBook.filler(30))"),
        ]))
        try await reader.settle()
        let accented = reader.publication.spine[1].resource.href
        XCTAssertEqual(accented, "OPS/caf%C3%A9%20na%C3%AFve.xhtml")
        let marked = try reader.anchor("r\u{E9}sum\u{E9} point", section: 1)
        XCTAssertGreaterThan(marked.offset, 1_000)
        // The section, however its href is escaped.
        for href in [accented, "OPS/caf%c3%a9%20na%c3%afve.xhtml", "OPS/%63af%C3%A9%20na%C3%AFve%2Exhtml"] {
            try await reader.session.send(.navigate(href: "OPS/three.xhtml"))
            try await reader.wait("chapter three") { reader.section == 2 }
            try await reader.session.send(.navigate(href: href))
            try await reader.wait(href) { reader.session.visibleRange?.start == ReaderTextPosition(section: 1, offset: 0) }
            XCTAssertEqual(reader.session.lastLocation?.href, accented, "locations carry the resource's own href")
        }
        // A fragment, however it is escaped.
        for fragment in ["r%C3%A9sum%C3%A9%20point", "r%c3%a9sum%c3%a9%20point", "%72%C3%A9sum%C3%A9%20point"] {
            try await reader.session.send(.navigate(href: "OPS/three.xhtml"))
            try await reader.wait("chapter three") { reader.section == 2 }
            try await reader.session.send(.navigate(href: accented + "#" + fragment))
            try await reader.wait("the marked place by \(fragment)") { reader.isVisible(marked) }
        }
        // A fragment its document does not have, and an empty one, show the document's start.
        for href in ["OPS/three.xhtml#no-such-id", "OPS/three.xhtml#", "OPS/three.xhtml#%20"] {
            try await reader.session.send(.navigate(href: accented))
            try await reader.wait("the accented chapter") { reader.section == 1 }
            let count = reader.events.count
            try await reader.session.send(.navigate(href: href))
            try await reader.wait(href) { reader.session.visibleRange?.start == ReaderTextPosition(section: 2, offset: 0) }
            XCTAssertTrue(reader.notices(since: count).isEmpty, "\(href): \(reader.notices(since: count))")
        }
        // The place already shown: accepted, and nothing to report.
        try await reader.wait("the location") { reader.locations.last == reader.session.lastLocation }
        let count = reader.events.count
        try await reader.session.send(.navigate(href: "OPS/three.xhtml"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reader.session.visibleRange?.start, ReaderTextPosition(section: 2, offset: 0))
        XCTAssertEqual(reader.events.count, count, "\(reader.events.dropFirst(count))")
    }

    // MARK: Page turns

    /// "stops at the book's ends; skips nonlinear sections as foliate-js did."
    func testPageTurnsStepOverANonlinearSectionInBothDirectionsAndFlows() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try open(SessionCoverageBook.epub([
                Section("lead", "<p>A nonlinear lead-in.</p>", linear: false),
                Section("one", "<h1>One</h1>\(SessionCoverageBook.filler(70))"),
                Section("note", "<p>A nonlinear note.</p>", linear: false),
                Section("two", "<h1>Two</h1>\(SessionCoverageBook.filler(70))"),
                Section("tail", "<p>A nonlinear afterword.</p>", linear: false),
            ]))
            try await reader.settle()
            let state = reader.state
            try await reader.session.send(.style(EPUBReaderStyle(flow: flow)))
            if flow == .scrolled { try await reader.wait("the whole book") { reader.session.canvas?.scrollBook != nil } }
            try await reader.wait("the first linear section") { reader.session.visibleRange?.start == ReaderTextPosition(section: 1, offset: 0) }
            try await reader.wait("the start boundary in \(flow)") { state.status.canGoPrevious == false && state.status.canGoNext == true }
            let start = try XCTUnwrap(reader.session.visibleRange)
            try await reader.session.send(.previousPage)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(reader.session.visibleRange, start, "\(flow): nothing linear precedes the first chapter")

            var forward: [Int] = [1]
            for turn in 0..<200 where state.status.canGoNext != false {
                let shown = reader.session.visibleRange
                try await reader.session.send(.nextPage)
                try await reader.wait("\(flow) turn \(turn)") { reader.session.visibleRange != shown || state.status.canGoNext == false }
                if let section = reader.section, forward.last != section { forward.append(section) }
            }
            XCTAssertEqual(forward, [1, 3], "\(flow): the note is stepped over")
            XCTAssertEqual(state.status.canGoNext, false, "\(flow): only the nonlinear afterword follows")
            let end = try XCTUnwrap(reader.session.visibleRange)
            try await reader.session.send(.nextPage)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(reader.session.visibleRange, end, "\(flow): a turn at the book's end stays")

            var backward: [Int] = [3]
            for turn in 0..<200 where state.status.canGoPrevious != false {
                let shown = reader.session.visibleRange
                try await reader.session.send(.previousPage)
                try await reader.wait("\(flow) turn back \(turn)") { reader.session.visibleRange != shown || state.status.canGoPrevious == false }
                if let section = reader.section, backward.last != section { backward.append(section) }
            }
            XCTAssertEqual(backward, [3, 1], "\(flow): the note is stepped over on the way back")
            XCTAssertFalse(reader.locations.contains { $0.href == "OPS/note.xhtml" || $0.href == "OPS/lead.xhtml" || $0.href == "OPS/tail.xhtml" },
                           "\(flow): no nonlinear section was shown")

            // Navigation still reaches one; a page turn from it rejoins the linear order.
            try await reader.session.send(.navigate(href: "OPS/note.xhtml"))
            try await reader.wait("\(flow) note") { reader.section == 2 && reader.session.lastLocation?.href == "OPS/note.xhtml" }
            try await reader.session.send(.nextPage)
            try await reader.wait("\(flow) the chapter after the note") { reader.session.visibleRange?.start == ReaderTextPosition(section: 3, offset: 0) }
            try await reader.session.send(.navigate(href: "OPS/note.xhtml"))
            try await reader.wait("\(flow) note again") { reader.section == 2 }
            try await reader.session.send(.previousPage)
            try await reader.wait("\(flow) the chapter before the note") { reader.section == 1 }
            reader.close()
        }
    }

    func testPageTurnsCrossAnEmptySectionAndASinglePageBookHasNoTurns() async throws {
        let reader = try open(SessionCoverageBook.epub([
            Section("one", "<p>Before the empty section.</p>"), Section("empty", ""), Section("blank", "<p>   </p>\n"),
            Section("three", "<p>After the empty sections.</p>"),
        ]))
        try await reader.settle()
        XCTAssertEqual(reader.session.book.section(1)?.string.length, 0)
        var seen: [Int] = [0]
        for turn in 0..<8 where reader.state.status.canGoNext != false {
            let shown = reader.section
            try await reader.session.send(.nextPage)
            try await reader.wait("turn \(turn)") { reader.section != shown }
            seen.append(try XCTUnwrap(reader.section))
        }
        XCTAssertEqual(seen, [0, 1, 2, 3], "each section is one page, the empty ones too")
        XCTAssertEqual(reader.locations.map(\.href).reduce(into: [String?]()) { if $0.last != $1 { $0.append($1) } },
                       ["OPS/one.xhtml", "OPS/empty.xhtml", "OPS/blank.xhtml", "OPS/three.xhtml"])
        XCTAssertEqual(reader.state.status.canGoNext, false)
        XCTAssertEqual(reader.locations.last?.progression, 1, "the last page of a book is 1")
        for turn in 0..<8 where reader.state.status.canGoPrevious != false {
            let shown = reader.section
            try await reader.session.send(.previousPage)
            try await reader.wait("turn back \(turn)") { reader.section != shown }
        }
        XCTAssertEqual(reader.section, 0)

        let single = try open(SessionCoverageBook.epub([Section("only", "<p>The whole book is this line.</p>")]))
        try await single.settle()
        try await single.wait("boundaries") { single.state.status.canGoNext == false && single.state.status.canGoPrevious == false }
        XCTAssertEqual(single.locations.count, 1)
        XCTAssertEqual(single.locations.first?.progression, 1, "its one page is read to the end")
        let count = single.events.count
        try await single.session.send(.nextPage)
        try await single.session.send(.previousPage)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(single.events.count, count, "\(single.events.dropFirst(count))")
        XCTAssertEqual(single.session.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
    }

    /// `doc/reader-controls.md`: "Previous/next always submit logical commands"; `nextPage` moves
    /// on in reading order whichever way the book's pages progress.
    func testPageCommandsAreLogicalInARightToLeftBook() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try open(Fixture.rendering(.rightToLeft))
            try await reader.settle()
            XCTAssertEqual(reader.session.canvas?.configuration.isRightToLeft, true)
            try await reader.session.send(.style(EPUBReaderStyle(flow: flow)))
            if flow == .scrolled { try await reader.wait("the whole book") { reader.session.canvas?.scrollBook != nil } }
            try await reader.wait("\(flow): the start") {
                reader.session.visibleRange?.start == ReaderTextPosition(section: 0, offset: 0) && reader.state.status.canGoPrevious == false
                    && reader.state.status.canGoNext == true && reader.locations.last == reader.session.lastLocation
            }
            let start = try XCTUnwrap(reader.session.visibleRange)
            try await reader.session.send(.previousPage)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(reader.session.visibleRange, start, "\(flow): nothing precedes the first page")
            var position = start.start, progression = try XCTUnwrap(reader.session.lastLocation?.progression)
            for turn in 1...2 {
                try await reader.session.send(.nextPage)
                try await reader.wait("\(flow): turn \(turn)") {
                    (reader.session.visibleRange.map { $0.start > position } ?? false) && reader.locations.last == reader.session.lastLocation
                }
                let next = try XCTUnwrap(reader.session.lastLocation?.progression)
                XCTAssertGreaterThan(next, progression, "\(flow): turn \(turn) reads on")
                position = try XCTUnwrap(reader.session.visibleRange?.start)
                progression = next
            }
            for _ in 1...2 { try await reader.session.send(.previousPage) }
            try await reader.wait("\(flow): the start again") { reader.session.visibleRange?.start == start.start }
            reader.close()
        }
    }

    /// `NativeBook`: nonlinear sections are left out of the whole text "unless no section is
    /// linear" — "a book with no linear section keeps all". Such a book has to be readable from
    /// end to end by page turns in either flow.
    func testABookWithNoLinearSectionIsReadThroughByPageTurnsInEitherFlow() async throws {
        for flow in [EPUBReadingFlow.scrolled, .paginated] {
            let reader = try open(SessionCoverageBook.epub([
                Section("a", "<p>First section.</p>\(SessionCoverageBook.filler(60))", linear: false),
                Section("b", "<p>Second section.</p>\(SessionCoverageBook.filler(60))", linear: false),
            ]))
            try await reader.settle()
            try await reader.session.send(.style(EPUBReaderStyle(flow: flow)))
            if flow == .scrolled { try await reader.wait("the whole book") { reader.session.canvas?.scrollBook != nil } }
            try await reader.wait("\(flow): the start") { reader.session.visibleRange?.start == ReaderTextPosition(section: 0, offset: 0) }
            var seen: [Int] = [0]
            for turn in 0..<80 where reader.state.status.canGoNext != false {
                let shown = reader.session.visibleRange
                try await reader.session.send(.nextPage)
                try await reader.wait("\(flow): turn \(turn)") { reader.session.visibleRange != shown || reader.state.status.canGoNext == false }
                if let section = reader.section, seen.last != section { seen.append(section) }
            }
            XCTAssertEqual(seen, [0, 1], "\(flow): page turns read on into the second section")
            reader.close()
        }
    }

    // MARK: restore

    /// "Same publication, engine ID and `epublib-cfi-v1` format or `incompatibleLocation`"; "An
    /// empty collection, a contradictory first bookmark, a foreign identity/format or malformed
    /// CFI is incompatible".
    func testRestoreRefusesLocationsItCannotTrustAndStaysWhereItIs() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        try await reader.session.send(.navigate(href: "OPS/two.xhtml#mid"))
        try await reader.wait("the midpoint") { reader.isVisible(try! reader.anchor("mid", section: 2)) }
        try await reader.wait("its location") { reader.locations.last == reader.session.lastLocation }
        let saved = try XCTUnwrap(reader.session.lastLocation)
        let value = try XCTUnwrap(saved.bookmark?.value)
        try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
        try await reader.wait("chapter one") { reader.section == 0 }
        try await reader.wait("its location") { reader.locations.last == reader.session.lastLocation }
        let original = reader.session.visibleRange
        let count = reader.events.count

        var incompatible: [(String, EPUBLocation)] = []
        func add(_ label: String, _ change: (inout EPUBLocation) -> Void) { var location = saved; change(&location); incompatible.append((label, location)) }
        add("another publication") { $0.publicationID = String($0.publicationID.reversed()) }
        add("an empty publication") { $0.publicationID = "" }
        add("no bookmark, only an href") { $0.bookmark = nil }
        add("no bookmark, only a quote") { $0 = EPUBLocation(publicationID: $0.publicationID, quote: "A marked midpoint paragraph sits here.") }
        add("no bookmark, only progression") { $0 = EPUBLocation(publicationID: $0.publicationID, progression: 0.5) }
        add("another engine") { $0.bookmark?.engineID = "org.example.reader" }
        add("an engine differing in case") { $0.bookmark?.engineID = "ORG.EPUBLIB.READER" }
        add("another format") { $0.bookmark?.format = "epublib-cfi-v2" }
        add("the WebKit reader's tag") { $0.bookmark?.engineID = "org.epubreaderlib.foliate"; $0.bookmark?.format = "epubcfi-v1" }
        for (label, malformed) in [("empty", ""), ("no wrapper", "/6/6!/4/2/1:0"), ("an empty wrapper", "epubcfi()"),
                                   ("unclosed", "epubcfi(/6/6!/4/2/1:0"), ("unbalanced", "epubcfi(/6/6!/4(/2/1:0)"),
                                   ("trailing text", value + " "), ("a line break", "epubcfi(/6/6!/4/2\n/1:0)"),
                                   ("a control character", "epubcfi(/6/6!/4/2\u{7}/1:0)"),
                                   ("too long", "epubcfi(/6/6!/4/2[" + String(repeating: "x", count: 5_000) + "]/1:0)")] {
            add("a malformed CFI: \(label)") { $0.bookmark?.value = malformed }
        }
        add("an empty range collection") { $0.rangeBookmarks = [] }
        add("a range collection that contradicts the bookmark") { $0.rangeBookmarks = [self.bookmark("epubcfi(/6/2!/4/2/1:0)")] }
        add("a foreign range segment") { $0.rangeBookmarks = [$0.bookmark!, EPUBEngineBookmark(engineID: "x", format: "y", value: "epubcfi(/6/8!/4/2/1:0)")] }
        for (label, location) in incompatible {
            do { try await reader.session.send(.restore(location)); XCTFail("Restored \(label)") }
            catch { XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation, label) }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reader.session.visibleRange, original)
        XCTAssertEqual(reader.events.count, count, "an incompatible location emitted \(reader.events.dropFirst(count))")

        // The saved location itself is still good, in the same collection form or without it.
        var single = saved
        single.rangeBookmarks = [try XCTUnwrap(saved.bookmark)]
        try await reader.session.send(.restore(single))
        try await reader.wait("the midpoint again") { reader.section == 2 }
        XCTAssertNil(reader.session.selection, "restoring selects nothing")
        XCTAssertTrue(reader.session.drawnHighlights.isEmpty, "and highlights nothing")
        XCTAssertTrue(reader.notices(since: count).isEmpty)
    }

    /// "A CFI that no longer resolves … produces a `.notice`"; "`restore` similarly refuses an
    /// incompatible location or emits a notice for an unresolved collection without navigating."
    func testRestoreOfAWellFormedCFIThatNamesNothingIsNoticedWithoutNavigating() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        try await reader.session.send(.navigate(href: "OPS/two.xhtml"))
        try await reader.wait("chapter two") { reader.section == 2 }
        try await reader.wait("its location") { reader.locations.last == reader.session.lastLocation }
        let original = reader.session.visibleRange
        let unresolved = [
            "a spine item the book lacks": "epubcfi(/6/400!/4/2/1:0)",
            "a spine step of zero": "epubcfi(/6/0!/4/2/1:0)",
            "an element its document lacks": "epubcfi(/6/2!/4/900/1:0)",
            "a path that is not a CFI": "epubcfi(not a path)",
            "only the package": "epubcfi(/6)",
        ]
        for (label, value) in unresolved.sorted(by: { $0.key < $1.key }) {
            let count = reader.events.count
            do { try await reader.session.send(.restore(EPUBLocation(publicationID: reader.publication.id, bookmark: bookmark(value)))) }
            catch {
                XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation, label)
                continue
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(reader.notices(since: count), ["the saved position could not be found in this book"], label)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(reader.session.visibleRange, original, "\(label) moved the reader")
            XCTAssertTrue(reader.locations(since: count).isEmpty, label)
        }
        XCTAssertEqual(reader.state.status.lifecycle, .ready)
        XCTAssertEqual(reader.state.status.activeCommands, 0)
    }

    /// A saved position is a place in the text, whatever the typography and flow it is restored in.
    func testASavedPositionRestoresToTheSameTextInEitherFlowAndAtAnotherSize() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        let mid = try reader.anchor("mid", section: 2)
        try await reader.session.send(.navigate(href: "OPS/two.xhtml#mid"))
        try await reader.wait("the midpoint") { reader.isVisible(mid) }
        try await reader.wait("its location") { reader.locations.last == reader.session.lastLocation }
        let saved = try XCTUnwrap(reader.session.lastLocation)
        let shown = try XCTUnwrap(reader.session.visibleRange)
        XCTAssertEqual(saved.href, "OPS/two.xhtml")
        XCTAssertEqual(saved.title, "Second Chapter")
        // Round-tripped as a host stores it.
        let stored = try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(stored, saved)

        try await reader.session.send(.navigate(href: "OPS/three.xhtml"))
        try await reader.wait("chapter three") { reader.section == 3 }
        try await reader.session.send(.restore(stored))
        try await reader.wait("the saved page") { reader.session.visibleRange == shown }
        try await reader.wait("the saved location") { reader.session.lastLocation == saved }

        for style in [EPUBReaderStyle(fontSize: 26), EPUBReaderStyle(fontSize: 26, flow: .scrolled), EPUBReaderStyle(flow: .scrolled)] {
            try await reader.session.send(.style(style))
            try await reader.wait("the book at \(style)") { reader.session.book.isComplete && reader.session.book.typography.fontSize == style.fontSize }
            if style.flow == .scrolled { try await reader.wait("the whole book") { reader.session.canvas?.scrollBook != nil } }
            try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
            try await reader.wait("chapter one") { reader.section == 0 }
            try await reader.session.send(.restore(stored))
            try await reader.wait("the saved text at \(style)") { reader.isVisible(shown.start) }
            XCTAssertEqual(reader.session.visibleRange?.start.section, 2)
            if style.flow == .scrolled, let top = reader.session.visibleRange?.start {
                XCTAssertLessThan(shown.start.offset - top.offset, 200, "\(style): the saved line rests at the top")
            }
        }
        XCTAssertTrue(reader.notices().isEmpty, "\(reader.notices())")
    }

    // MARK: locate

    /// "A miss emits `.notice("the cited passage could not be found in this book")`."
    func testLocateRefusesEmptyAndOverlongTextAndNoticesEveryMiss() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        try await reader.session.send(.searchHighlight(text: "findword"))
        XCTAssertEqual(reader.state.status.searchResults?.count, 2)
        let original = reader.session.visibleRange
        var count = reader.events.count
        for text in ["", " ", "\n\t ", "\u{200B}\u{2060}", String(repeating: "x", count: 4_097)] {
            for highlight in [false, true] {
                await reader.refuses(.locate(text: text, highlight: highlight), "the passage \(text.prefix(12).debugDescription)")
            }
        }
        XCTAssertEqual(reader.events.count, count, "a refused passage emitted \(reader.events.dropFirst(count))")
        XCTAssertEqual(reader.state.status.searchResults?.count, 2, "and left the search alone")

        // The longest passage accepted, a passage across two documents and a plain miss.
        let across = "A paragraph of ordinary reading text for pagination. A nonlinear note holding findword apart."
        for text in [String(repeating: "x", count: 4_096), across, "Nothing like this sentence is in the book."] {
            count = reader.events.count
            try await reader.session.send(.locate(text: text, highlight: true))
            try await reader.wait("the miss") { !reader.notices(since: count).isEmpty }
            XCTAssertEqual(reader.notices(since: count), ["the cited passage could not be found in this book"])
        }
        XCTAssertEqual(reader.session.visibleRange, original, "a miss keeps the position")
        XCTAssertNil(reader.session.selection)
        XCTAssertTrue(reader.selections().isEmpty)
        // "Clears search highlights", even on a miss.
        XCTAssertNil(reader.state.status.searchResults)
        XCTAssertEqual(reader.state.status.search, .idle)
        XCTAssertTrue(reader.session.drawnHighlights.isEmpty)
    }

    /// "First match in reading order": the spine's order, nonlinear documents included, as
    /// search results are ordered. Without `highlight` nothing is selected.
    func testLocateShowsTheFirstMatchInSpineOrderAndSelectsOnlyWhenAsked() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        try await reader.session.send(.locate(text: "findword", highlight: false))
        try await reader.wait("the note") { reader.section == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(reader.session.selection, "nothing is selected without highlight")
        XCTAssertNil(reader.session.canvas?.currentSelection)
        XCTAssertTrue(reader.selections().isEmpty, "\(reader.selections())")
        XCTAssertTrue(reader.notices().isEmpty)

        try await reader.session.send(.locate(text: "Closing  WORDS with\u{A0}findword", highlight: true))
        try await reader.wait("the selected passage") { reader.selections().last??.text == "Closing words with findword" }
        let selection = try XCTUnwrap(reader.selections().last.flatMap { $0 })
        XCTAssertEqual(reader.section, 3)
        XCTAssertEqual(selection.location.href, "OPS/three.xhtml")
        XCTAssertEqual(selection.location.quote, "Closing words with findword")
        XCTAssertEqual(selection.location.publicationID, reader.publication.id)
        XCTAssertNil(selection.location.progression, "a selection is a passage, not a reading position")
        XCTAssertNil(selection.location.title)
        // Locating again without highlight drops the selection and says so.
        let count = reader.events.count
        try await reader.session.send(.locate(text: "Opening words are visible.", highlight: false))
        try await reader.wait("chapter one") { reader.section == 0 }
        try await reader.wait("the cleared selection") { reader.selections(since: count).contains { $0 == nil } }
        XCTAssertNil(reader.session.selection)
    }

    /// A passage found only in content that renders nothing is a place to go, not a passage to
    /// select, and not a miss.
    func testLocateShowsWhereAPassageFoundOnlyInHiddenContentIs() async throws {
        let reader = try open(SessionCoverageBook.epub([
            Section("one", "<p>Opening words.</p>\(SessionCoverageBook.filler(20))"),
            Section("two", "<p>Second chapter.</p><p style=\"display:none\">Hidden lantern phrase kept from readers.</p>"
                + SessionCoverageBook.filler(20)),
        ]))
        try await reader.settle()
        for highlight in [true, false] {
            try await reader.session.send(.navigate(href: "OPS/one.xhtml"))
            try await reader.wait("chapter one") { reader.section == 0 }
            let count = reader.events.count
            try await reader.session.send(.locate(text: "Hidden lantern phrase", highlight: highlight))
            try await reader.wait("the hidden passage's document") { reader.section == 1 }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(reader.session.selection, "content that renders nothing cannot be selected")
            XCTAssertNil(reader.session.canvas?.currentSelection)
            XCTAssertTrue(reader.notices(since: count).isEmpty, "it was found: \(reader.notices(since: count))")
            XCTAssertTrue(reader.selections(since: count).allSatisfy { $0 == nil })
        }
    }

    /// `NativeSession.locate`: "A match inside content that renders nothing of its own (a hidden
    /// footnote) is a place to go, not a passage to select; one that renders is preferred."
    /// Where in its section the hidden content sits cannot change which occurrence is chosen.
    func testLocatePrefersARenderedOccurrenceWhereverAnEarlierHiddenOneSitsInItsSection() async throws {
        XCTExpectFailure("https://github.com/vocaro/EPUBLib/issues/158")
        let hidden = "<p style=\"display:none\">Twice told tale, kept from readers.</p>"
        let placements = [
            ("at its section's start", hidden + "<p>Second chapter.</p>" + SessionCoverageBook.filler(20)),
            ("in its section's middle", "<p>Second chapter.</p>" + hidden + SessionCoverageBook.filler(20)),
            ("at its section's end", "<p>Second chapter.</p>" + SessionCoverageBook.filler(20) + hidden),
        ]
        for (label, body) in placements {
            let reader = try open(SessionCoverageBook.epub([
                Section("one", "<p>Opening words.</p>\(SessionCoverageBook.filler(20))"), Section("two", body),
                Section("three", "<p>Third chapter.</p>\(SessionCoverageBook.filler(20))<p>Twice told tale in the open.</p>"),
            ]))
            try await reader.settle()
            try await reader.session.send(.locate(text: "Twice told tale", highlight: true))
            try await reader.wait("\(label): an occurrence") { reader.section != 0 }
            XCTAssertEqual(reader.section, 2, "hidden \(label): the reader went to the document where the passage renders nothing, "
                + "not to the one where it renders")
            if reader.section == 2 {
                try await reader.wait("\(label): the selected passage") { reader.selections().last??.text == "Twice told tale" }
            }
            XCTAssertTrue(reader.notices().isEmpty, "\(label): \(reader.notices())")
            reader.close()
        }
    }

    // MARK: style

    /// "Font size 12–96 …". Sizes outside the range are drawn at its nearest end; a size that is
    /// not a number is refused.
    func testFontSizesAreDrawnWithinTwelveToNinetySixAndNonfiniteOnesRefused() async throws {
        let reader = try open(Fixture.epub())
        try await reader.settle()
        for (size, drawn) in [(12.0, 12.0), (96, 96), (11, 12), (0, 12), (-40, 12), (97, 96), (1e12, 96), (12.5, 12.5), (95.5, 95.5)] {
            try await reader.session.send(.style(EPUBReaderStyle(fontSize: size)))
            XCTAssertEqual(Double(reader.session.book.typography.fontSize), drawn, "size \(size)")
            try await reader.wait("the book at \(size)") { reader.session.book.isComplete }
            XCTAssertEqual(reader.state.status.style.flow, .paginated)
            XCTAssertNotNil(reader.session.visibleRange)
        }
        let before = reader.state.status.style
        let typography = reader.session.book.typography
        for size in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            await reader.refuses(.style(EPUBReaderStyle(fontSize: size, appearance: .dark, flow: .scrolled)), "a font size of \(size)")
        }
        XCTAssertEqual(reader.state.status.style, before, "a refused style changes nothing")
        XCTAssertEqual(reader.session.book.typography, typography)
        XCTAssertEqual(reader.session.canvas?.configuration.flow, .paginated)
        XCTAssertEqual(reader.state.status.effectiveAppearance, .light)
        XCTAssertFalse(reader.events.contains { if case .failed = $0 { return true }; return false })
    }

    /// "Size or resolved appearance rebuilds the text; the position is kept across rebuilds and
    /// flow switches." Host highlights are positions in the text and stay with it.
    func testThePositionAndHighlightsAreKeptAcrossSizeAppearanceAndFlowChanges() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        let mid = try reader.anchor("mid", section: 2)
        try await reader.session.send(.locate(text: "A marked midpoint paragraph sits here.", highlight: true))
        try await reader.wait("the selected midpoint") { reader.selections().last??.text == "A marked midpoint paragraph sits here." }
        let passage = try XCTUnwrap(reader.selections().last.flatMap { $0 })
        try await reader.session.send(.setHighlights([EPUBHighlight(id: "kept", location: passage.location)]))
        let drawn = try XCTUnwrap(reader.session.drawnHighlights.first { $0.id == "kept" }?.range)
        XCTAssertEqual(drawn.start, mid)
        try await reader.session.send(.navigate(href: "OPS/two.xhtml#mid"))
        try await reader.wait("the midpoint") { reader.isVisible(mid) }

        let styles = [
            EPUBReaderStyle(fontSize: 28), EPUBReaderStyle(fontSize: 28, appearance: .dark),
            EPUBReaderStyle(fontSize: 28, appearance: .dark, flow: .scrolled), EPUBReaderStyle(fontSize: 13, appearance: .light, flow: .scrolled),
            EPUBReaderStyle(fontSize: 13, appearance: .light), EPUBReaderStyle(), EPUBReaderStyle(flow: .scrolled), EPUBReaderStyle(),
        ]
        for style in styles {
            try await reader.session.send(.style(style))
            XCTAssertEqual(reader.state.status.style, style)
            try await reader.wait("the book at \(style)") {
                reader.session.book.isComplete && reader.session.book.typography == NativeTypography(fontSize: style.fontSize, isDark: style.appearance == .dark)
                    && reader.session.canvas?.configuration.flow == style.flow && reader.locations.last == reader.session.lastLocation
            }
            try await reader.wait("the midpoint at \(style)") { reader.isVisible(mid) }
            XCTAssertEqual(reader.session.drawnHighlights.filter { $0.id == "kept" }.map(\.range), [drawn], "\(style)")
            XCTAssertEqual(reader.session.lastLocation?.href, "OPS/two.xhtml", "\(style)")
        }
        // After page turns the page's own start is what is kept.
        for _ in 0..<3 { try await reader.session.send(.nextPage) }
        try await reader.wait("three pages on") { reader.session.visibleRange.map { $0.start > mid } ?? false }
        let start = try XCTUnwrap(reader.session.visibleRange?.start)
        for style in [EPUBReaderStyle(fontSize: 24), EPUBReaderStyle(fontSize: 24, flow: .scrolled), EPUBReaderStyle(fontSize: 15)] {
            try await reader.session.send(.style(style))
            try await reader.wait("the book at \(style)") {
                reader.session.book.isComplete && reader.session.book.typography.fontSize == style.fontSize
                    && reader.session.canvas?.configuration.flow == style.flow
            }
            try await reader.wait("the turned-to page's start at \(style)") { reader.isVisible(start) }
        }
        XCTAssertTrue(reader.notices().isEmpty, "\(reader.notices())")
        XCTAssertEqual(reader.events.filter { $0 == .ready }.count, 1)
    }

    // MARK: setHighlights

    /// "Replaces drawn host highlights"; "one `.notice` per rejected highlight".
    func testHighlightsAreReplacedAsAWholeAndEachRejectedOneIsNoticedOnce() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        func passage(_ text: String) async throws -> EPUBLocation {
            let count = reader.events.count
            try await reader.session.send(.locate(text: text, highlight: true))
            try await reader.wait("the passage \(text)") { reader.selections(since: count).last??.text == text }
            return try XCTUnwrap(reader.selections(since: count).last.flatMap { $0 }).location
        }
        let opening = try await passage("Opening words are visible.")
        let words = try await passage("words are")
        let destination = try await passage("The unique destination passage lives here.")
        var foreign = opening
        foreign.publicationID = "another book"
        var unbookmarked = opening
        unbookmarked.bookmark = nil
        var missing = opening
        missing.bookmark?.value = "epubcfi(/6/400!/4/2/1:0)"
        var point = opening
        point.bookmark?.value = "epubcfi(/6/2!/4/4/1:3)"

        var count = reader.events.count
        try await reader.session.send(.setHighlights([
            EPUBHighlight(id: "opening", location: opening), EPUBHighlight(id: "foreign", location: foreign),
            EPUBHighlight(id: "missing", location: missing), EPUBHighlight(id: "destination", location: destination),
            EPUBHighlight(id: "unbookmarked", location: unbookmarked), EPUBHighlight(id: "words", location: words),
            EPUBHighlight(id: "same", location: opening),
        ]))
        func annotations() -> [String] { reader.session.drawnHighlights.filter { $0.kind == .annotation }.map(\.id) }
        XCTAssertEqual(annotations(), ["opening", "destination", "words", "same"], "the valid ones, in the order given")
        XCTAssertEqual(reader.notices(since: count).sorted(), [
            "a highlight belongs to another book or reader and was not drawn: foreign",
            "a highlight belongs to another book or reader and was not drawn: unbookmarked",
            "a highlight's passage could not be found in this book: missing",
        ])
        let ranges = Dictionary(uniqueKeysWithValues: reader.session.drawnHighlights.map { ($0.id, $0.range) })
        XCTAssertEqual(ranges["opening"], ranges["same"], "two highlights of one passage are both drawn")
        let outer = try XCTUnwrap(ranges["opening"]), inner = try XCTUnwrap(ranges["words"])
        XCTAssertTrue(outer.start < inner.start && inner.end < outer.end, "an overlapping highlight keeps its own range")
        XCTAssertEqual(ranges["destination"]?.start.section, 2)

        // A position rather than a passage has nothing to draw.
        count = reader.events.count
        try await reader.session.send(.setHighlights([EPUBHighlight(id: "point", location: point), EPUBHighlight(id: "words", location: words)]))
        XCTAssertEqual(annotations(), ["words"], "the earlier list is gone")
        XCTAssertEqual(reader.notices(since: count), ["a highlight's passage could not be found in this book: point"])

        count = reader.events.count
        try await reader.session.send(.setHighlights([]))
        XCTAssertTrue(reader.session.drawnHighlights.isEmpty, "an empty array removes them")
        XCTAssertEqual(reader.events.count, count)
    }

    /// "No partial annotation is drawn while a section is building": a highlight sent the moment
    /// the reader is ready, before the rest of the book is built, appears once its section is.
    func testAHighlightSetAsSoonAsTheReaderIsReadyIsDrawnWhenItsSectionIsBuilt() async throws {
        let sections = [Section("one", "<p>Opening words.</p>")] + (0..<12).map {
            Section("later\($0)", "<h1>Later \($0)</h1>\(SessionCoverageBook.filler(150))<p>The far passage number \($0) ends here.</p>")
        }
        let data = try SessionCoverageBook.epub(sections)
        let publication = try EPUBPublication.open(data: data)
        // `/6/26` is the thirteenth itemref; `/4/304` its last paragraph, whose first eight characters are highlighted.
        let location = EPUBLocation(publicationID: publication.id, bookmark: bookmark("epubcfi(/6/26!/4/304,/1:0,/1:8)"))
        var sent: Task<Void, Error>?
        var builtWhenSent: Bool?
        var holder: SessionCoverageReader?
        let reader = try SessionCoverageReader(data, onEvent: { event in
            guard event == .ready, let reader = holder else { return }
            sent = Task {
                builtWhenSent = reader.session.book.section(12) != nil
                try await reader.session.send(.setHighlights([EPUBHighlight(id: "far", location: location)]))
            }
        })
        holder = reader
        addTeardownBlock { @MainActor in reader.close() }
        try await reader.wait("the highlight command") { sent != nil }
        try await sent?.value
        try await reader.wait("the highlight") { reader.session.drawnHighlights.contains { $0.id == "far" } }
        let range = try XCTUnwrap(reader.session.drawnHighlights.first { $0.id == "far" }?.range)
        let section = try XCTUnwrap(reader.session.book.section(12))
        XCTAssertEqual(section.string.attributedSubstring(from: NSRange(location: range.start.offset, length: range.end.offset - range.start.offset)).string,
                       "The far ", "built when sent: \(String(describing: builtWhenSent))")
        try await reader.settle()
        XCTAssertEqual(reader.session.drawnHighlights.filter { $0.id == "far" }.map(\.range), [range])
        XCTAssertTrue(reader.notices().isEmpty, "\(reader.notices())")
        XCTAssertEqual(reader.section, 0, "drawing a highlight does not move the reader")
    }

    // MARK: Search

    /// `doc/reader-controls.md`, Order: "Spine order across every spine document, nonlinear ones
    /// included". `.search` "opens the first rendered match in spine order".
    func testSearchListsAndOpensAMatchInANonlinearDocumentInSpineOrder() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let reader = try open(SessionCoverageBook.chapters())
            try await reader.settle()
            try await reader.session.send(.style(EPUBReaderStyle(flow: flow)))
            if flow == .scrolled { try await reader.wait("the whole book") { reader.session.canvas?.scrollBook != nil } }
            try await reader.session.send(.search(text: "findword"))
            let found = try XCTUnwrap(reader.state.status.searchResults)
            XCTAssertEqual(found.results.map(\.spineIndex), [1, 3], "\(flow)")
            XCTAssertEqual(found.results.map(\.location.href), ["OPS/note.xhtml", "OPS/three.xhtml"])
            XCTAssertEqual(found.currentIndex, 0)
            try await reader.wait("\(flow): the note") { reader.section == 1 }
            XCTAssertEqual(found.results[0].sectionTitle, "First Chapter", "the contents entry in effect")
            XCTAssertEqual(found.results[1].sectionTitle, "Third Chapter")
            let progressions = try found.results.map { try XCTUnwrap($0.location.progression) }
            XCTAssertEqual(progressions, progressions.sorted())
            XCTAssertTrue(progressions.allSatisfy { (0...1).contains($0) })
            try await reader.session.send(.nextSearchResult)
            try await reader.wait("\(flow): chapter three") { reader.section == 3 }
            try await reader.session.send(.nextSearchResult)
            try await reader.wait("\(flow): the note again") { reader.section == 1 }
            XCTAssertEqual(reader.state.status.searchResults?.currentIndex, 0)
            reader.close()
        }
    }

    /// The order of what a host hears: the withdrawal of the earlier list, the search, its
    /// results, its relocation, its completion. "No matches is a completed search with an empty
    /// list" and "preserve the position".
    func testSearchEventsArriveInTheDocumentedOrder() async throws {
        let reader = try open(SessionCoverageBook.chapters())
        try await reader.settle()
        /// The search events since `count`, with nil standing for a relocation (or several in a row).
        func searchEvents(since count: Int) -> [EPUBReaderEvent?] {
            reader.events.dropFirst(count).reduce(into: [EPUBReaderEvent?]()) { events, event in
                switch event {
                case .searchChanged, .searchResultsChanged: events.append(event)
                case .relocated: if events.last != .some(nil) { events.append(nil) }
                default: break
                }
            }
        }
        var count = reader.events.count
        try await reader.session.send(.clearSearch)
        XCTAssertEqual(searchEvents(since: count), [.searchChanged(.idle)], "clearing with no search withdraws nothing")

        count = reader.events.count
        try await reader.session.send(.search(text: "absent unicorn"))
        XCTAssertEqual(searchEvents(since: count), [
            .searchChanged(.searching(query: "absent unicorn")), .searchResultsChanged(EPUBSearchResults(query: "absent unicorn")),
            .searchChanged(.completed(query: "absent unicorn", hasMatches: false)),
        ], "no relocation: no matches preserve the position")

        count = reader.events.count
        try await reader.session.send(.search(text: "unique destination"))
        let found = try XCTUnwrap(reader.state.status.searchResults)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(reader.locations(since: count).last?.href, "OPS/two.xhtml")
        XCTAssertEqual(searchEvents(since: count), [
            .searchResultsChanged(nil), .searchChanged(.searching(query: "unique destination")), .searchResultsChanged(found),
            nil, .searchChanged(.completed(query: "unique destination", hasMatches: true)),
        ], "the withdrawal, the search, its results, the relocation, the completion")

        // The same query again is a new search: withdrawn, searched, listed. Its match is on screen.
        count = reader.events.count
        try await reader.session.send(.search(text: "unique destination"))
        XCTAssertEqual(searchEvents(since: count).compactMap { $0 }, [
            .searchResultsChanged(nil), .searchChanged(.searching(query: "unique destination")), .searchResultsChanged(found),
            .searchChanged(.completed(query: "unique destination", hasMatches: true)),
        ])

        count = reader.events.count
        try await reader.session.send(.clearSearch)
        XCTAssertEqual(searchEvents(since: count), [.searchResultsChanged(nil), .searchChanged(.idle)])
        count = reader.events.count
        for command in [EPUBReaderCommand.nextSearchResult, .previousSearchResult] { try await reader.session.send(command) }
        XCTAssertEqual(reader.events.count, count, "\"No effect without results.\"")
    }
}
