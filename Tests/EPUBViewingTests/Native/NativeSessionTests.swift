import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewingTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

/// The native engine end to end: a mounted session in a real window, driven only through the
/// public commands, observed through its events and its own visible range.
@MainActor final class NativeSessionTests: XCTestCase {
    private func wait(_ label: String = "the reader", timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func open(_ data: Data, action: EPUBSelectionAction? = nil, onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void = { _ in })
        throws -> (NativeSession, ReaderTestWindow, () -> [EPUBReaderEvent]) {
        let publication = try EPUBPublication.open(data: data)
        var events: [EPUBReaderEvent] = []
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: action) {
            events.append($0)
            onEvent($0)
        } as? NativeSession)
        return (session, ReaderTestWindow(session: session), { events })
    }

    private func locations(_ events: [EPUBReaderEvent]) -> [EPUBLocation] {
        events.compactMap { if case .relocated(let location) = $0 { return location }; return nil }
    }

    func testPublicControlStateAndSearchCompletion() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        let state = try XCTUnwrap(session.readerState)
        try await wait("ready and first location") { state.status.lifecycle == .ready && state.status.location != nil }
        XCTAssertEqual(state.status.canGoPrevious, false)
        XCTAssertEqual(state.status.canGoNext, true)
        let model = EPUBReaderControls(publication: session.publication, session: session)
        XCTAssertTrue(model.isReady, "late attachment reads current state without taking over events")
        try await session.send(.searchHighlight(text: "Opening words"))
        XCTAssertEqual(state.status.search, .completed(query: "Opening words", hasMatches: true))
        XCTAssertTrue(events().contains(.searchChanged(.searching(query: "Opening words"))))
        XCTAssertTrue(events().contains(.searchChanged(.completed(query: "Opening words", hasMatches: true))))
        try await session.send(.searchHighlight(text: "absent unicorn"))
        XCTAssertEqual(state.status.search, .completed(query: "absent unicorn", hasMatches: false))
        for query in [" ", String(repeating: "x", count: 513)] {
            do { try await session.send(.searchHighlight(text: query)); XCTFail("Invalid query accepted") }
            catch {
                guard case .failed(let submitted, _) = state.status.search else { return XCTFail("No search error feedback") }
                XCTAssertEqual(submitted, query)
            }
        }
        try await session.send(.clearSearch)
        XCTAssertEqual(state.status.search, .idle)
        XCTAssertTrue(session.drawnHighlights.filter { $0.kind == .search }.isEmpty)
        XCTAssertEqual(state.status.activeCommands, 0)
        let original = try XCTUnwrap(state.status.location)
        model.changeStyle { $0.fontSize = 21 }
        model.changeStyle { $0.isDark = true }
        model.changeStyle { $0.flow = .scrolled }
        await model.waitForCommands()
        XCTAssertEqual(state.status.style, .init(fontSize: 21, isDark: true, flow: .scrolled))
        try await wait("style position") { state.status.location?.href == original.href }
        XCTAssertTrue(events().contains(.ready), "host event callback still receives readiness")
        session.close()
        XCTAssertEqual(state.status.lifecycle, .closed)
        XCTAssertFalse(model.isReady)
    }

    func testSystemAppearanceFollowsEnvironmentAndExplicitModesStayFixed() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let (session, window, events) = try open(Fixture.epub())
            defer { session.close(); window.close() }
            let state = try XCTUnwrap(session.readerState)
            window.pageControls.colorScheme = .dark
            try await wait("initial System appearance") {
                events().contains(.ready) && session.book.isComplete && session.book.typography.isDark &&
                    session.canvas?.configuration.isDark == true && state.status.effectiveAppearance == .dark
            }
            XCTAssertEqual(state.status.style.appearance, .system)
            try await session.send(.style(.init(fontSize: 23, flow: flow)))
            try await session.send(.search(text: "unique destination"))
            let match = try XCTUnwrap(session.drawnHighlights.first { $0.kind == .search }?.range)

            for scheme in [ColorScheme.light, .dark] {
                window.pageControls.colorScheme = scheme
                let dark = scheme == .dark
                try await wait("live System appearance and rebuilt book") {
                    session.systemIsDark == dark && session.book.isComplete && session.book.typography.isDark == dark &&
                        session.canvas?.configuration.isDark == dark && state.status.effectiveAppearance == (dark ? .dark : .light)
                }
                XCTAssertEqual(state.status.style, .init(fontSize: 23, flow: flow))
                XCTAssertEqual(session.drawnHighlights.filter { $0.kind == .search }.map(\.range), [match])
                let visible = try XCTUnwrap(session.visibleRange)
                XCTAssertTrue(visible.start <= match.start && match.start < visible.end, "Theme change lost the matched position")
                let color = session.book.section(match.start.section)?.string.attribute(.foregroundColor, at: match.start.offset, effectiveRange: nil) as? PlatformColor
                XCTAssertEqual(color, ReaderPalette.text(dark: dark), "Rebuilt text must use the new palette")
            }

            for appearance in [EPUBReaderAppearance.light, .dark] {
                try await session.send(.style(.init(fontSize: 23, appearance: appearance, flow: flow)))
                let dark = appearance == .dark
                try await wait("explicit appearance") { session.book.isComplete && session.book.typography.isDark == dark }
                for scheme in [ColorScheme.light, .dark] {
                    window.pageControls.colorScheme = scheme
                    try await wait("host color scheme change") { session.systemIsDark == (scheme == .dark) }
                    XCTAssertEqual(state.status.style.appearance, appearance)
                    XCTAssertEqual(state.status.effectiveAppearance, appearance)
                    XCTAssertEqual(session.canvas?.configuration.isDark, dark)
                    XCTAssertEqual(session.book.typography.isDark, dark)
                }
            }
            try await session.send(.style(.init(fontSize: 23, appearance: .system, flow: flow)))
            XCTAssertEqual(state.status.effectiveAppearance, .dark, "System must use the latest preference after an override")
            session.close()
            let closedState = state.status
            session.updateSystemAppearance(isDark: false)
            XCTAssertEqual(state.status, closedState, "OS changes must not update a closed session")
        }
    }

    /// A reader mounted for a test opens light and is dark only while the test asks, whatever
    /// appearance the machine is in, so what a System style resolves to is the test's to say.
    func testATestWindowKeepsItsReaderLightUntilTheTestAsksForDark() async throws {
        #if os(macOS)
        // Dark for this process alone, as a machine in dark appearance gives every window that sets none.
        prepareMacTestApplication()
        let application = NSApplication.shared, own = application.appearance
        application.appearance = NSAppearance(named: .darkAqua)
        defer { application.appearance = own }
        let plain = makeMacTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertEqual(plain.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua, "the machine is not dark to this test")
        #endif

        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        #if !os(macOS)
        // A test process cannot make its device dark, so the window is asked whose style it has.
        XCTAssertEqual(window.window.overrideUserInterfaceStyle, .light, "the test window follows the device")
        #endif
        let state = try XCTUnwrap(session.readerState)
        func shows(dark: Bool) -> Bool {
            session.systemIsDark == dark && session.book.isComplete && session.book.typography == NativeTypography(isDark: dark)
                && session.canvas?.configuration.isDark == dark && state.status.effectiveAppearance == (dark ? .dark : .light)
        }
        try await wait("the opened reader") { events().contains(.ready) && session.book.isComplete }
        XCTAssertEqual(state.status.style.appearance, .system)
        XCTAssertTrue(shows(dark: false), "a System style opened \(state.status.effectiveAppearance) in a test window")
        window.pageControls.colorScheme = .dark
        try await wait("the dark the test asked for") { shows(dark: true) }
        window.pageControls.colorScheme = nil
        try await wait("the window's own light") { shows(dark: false) }
    }

    func testToolbarSearchOpensFirstOffscreenMatchAndKeepsHighlights() async throws {
        let padding = String(repeating: "<p>Ordinary text before the destination.</p>", count: 80)
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Destination</title></head><body>
        \(padding)<p>Findneedle first match.</p>\(padding)<p>Findneedle second match.</p>
        </body></html>
        """
        let opening = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Opening</title></head><body>
        <p style="display:none">Findneedle hidden match.</p><p>Visible opening text.</p>
        </body></html>
        """
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let (session, window, events) = try open(Fixture.epub(overrides: ["OPS/one.xhtml": opening, "OPS/two.xhtml": chapter]))
            defer { session.close(); window.close() }
            try await wait("built book and location") { session.book.isComplete && session.lastLocation != nil }
            try await session.send(.style(.init(flow: flow)))
            let original = session.visibleRange
            try await session.send(.searchHighlight(text: "findneedle"))
            XCTAssertEqual(session.visibleRange, original, "highlight-only API must not navigate")
            let controls = EPUBReaderControls(publication: session.publication, session: session)
            controls.searchText = "findneedle"
            XCTAssertEqual(session.visibleRange, original, "typing must not navigate")
            controls.submitSearch()
            await controls.waitForCommands()
            let matches = session.drawnHighlights.filter { $0.kind == .search }.sorted { $0.range.start < $1.range.start }
            XCTAssertEqual(matches.count, 2)
            let first = try XCTUnwrap(matches.first?.range)
            XCTAssertEqual(first.start.section, 1)
            XCTAssertGreaterThan(first.start.offset, 0)
            try await wait("first match visible") {
                guard let visible = session.visibleRange else { return false }
                return visible.start <= first.start && first.start < visible.end
            }
            XCTAssertNil(session.selection, "search highlights should not become an editing selection")
            XCTAssertEqual(session.readerState?.status.search, .completed(query: "findneedle", hasMatches: true))
            let foundPosition = session.visibleRange
            controls.searchText = "absent unicorn"
            controls.submitSearch()
            await controls.waitForCommands()
            XCTAssertEqual(session.visibleRange, foundPosition, "no-match search must preserve position")
            XCTAssertEqual(session.readerState?.status.search, .completed(query: "absent unicorn", hasMatches: false))
            XCTAssertTrue(events().contains(.searchChanged(.completed(query: "findneedle", hasMatches: true))))
        }
    }

    func testNewerNavigationWinsOverPendingSearch() async throws {
        var retained: NativeSession?
        var navigation: Task<Void, Error>?
        let (session, window, events) = try open(Fixture.epub(), onEvent: { event in
            if case .searchChanged(.searching) = event {
                navigation = Task { try await retained?.send(.navigate(href: "OPS/one.xhtml#start")) }
            }
        })
        retained = session
        defer { session.close(); window.close() }
        try await wait("ready and location") { events().contains(.ready) && session.lastLocation != nil }
        try await session.send(.search(text: "unique destination"))
        try await navigation?.value
        XCTAssertEqual(session.visibleRange?.start.section, 0)
        XCTAssertEqual(session.readerState?.status.search, .completed(query: "unique destination", hasMatches: true))
    }

    func testClearSupersedesSearchAndSuppressesStaleCompletion() async throws {
        var retained: NativeSession?
        var clear: Task<Void, Error>?
        let (session, window, events) = try open(Fixture.epub(), onEvent: { event in
            if case .searchChanged(.searching) = event {
                clear = Task { try await retained?.send(.clearSearch) }
            }
        })
        retained = session
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let original = session.visibleRange
        try await session.send(.search(text: "unique destination"))
        try await clear?.value
        XCTAssertEqual(session.readerState?.status.search, .idle)
        XCTAssertFalse(events().contains(.searchChanged(.completed(query: "unique destination", hasMatches: true))))
        XCTAssertEqual(session.visibleRange, original, "cleared search must not navigate later")
    }

    func testCanceledSearchEndsActivityWithoutCompletion() async throws {
        var search: Task<Void, Error>?
        let (session, window, events) = try open(Fixture.epub(), onEvent: { event in
            if case .searchChanged(.searching) = event { search?.cancel() }
        })
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let original = session.visibleRange
        search = Task { try await session.send(.search(text: "unique destination")) }
        do { try await search?.value; XCTFail("Canceled search completed") } catch is CancellationError {}
        XCTAssertEqual(session.readerState?.status.search, .idle)
        XCTAssertEqual(session.readerState?.status.activeCommands, 0)
        XCTAssertFalse(events().contains(.searchChanged(.completed(query: "unique destination", hasMatches: true))))
        XCTAssertEqual(session.visibleRange, original)
    }

    func testPublicBoundariesInPaginatedAndScrolledFlow() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let (session, window, events) = try open(Fixture.epub())
            defer { session.close(); window.close() }
            try await wait("built book") { events().contains(.ready) && session.book.isComplete }
            try await session.send(.style(.init(flow: flow)))
            let state = try XCTUnwrap(session.readerState)
            try await wait("first boundary") { state.status.canGoPrevious == false }
            for _ in 0..<200 {
                if state.status.canGoNext == false { break }
                try await session.send(.nextPage)
                await Task.yield()
            }
            XCTAssertEqual(state.status.canGoNext, false, "last boundary in \(flow)")
            XCTAssertEqual(state.status.canGoPrevious, true)
            for _ in 0..<200 {
                if state.status.canGoPrevious == false { break }
                try await session.send(.previousPage)
                await Task.yield()
            }
            XCTAssertEqual(state.status.canGoPrevious, false, "first boundary in \(flow)")
        }
    }

    func testReusableEngineContract() async throws {
        do {
            try await EPUBEngineContract.verify(engine: NativeEngine(),
                publication: EPUBPublication.open(data: Fixture.epub()),
                firstHref: "OPS/one.xhtml", secondHref: "OPS/two.xhtml", text: "Opening words are visible.") { session in
                    let window = ReaderTestWindow(session: session)
                    return { window.close() }
                }
        } catch let error as EPUBEngineContract.Failure {
            XCTFail(error.description)
        }
    }

    func testMountedModifierUpdatesPreserveSessionSelectionHighlightsAndCommands() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        for flow: EPUBReadingFlow in [.paginated, .scrolled] {
            try await session.send(.style(.init(flow: flow)))
            try await session.send(.locate(text: "Opening words are visible.", highlight: true))
            try await wait("selection") { session.selection != nil }
            try await session.send(.searchHighlight(text: "Opening"))
            let canvas = try XCTUnwrap(session.canvas)
            let views = canvas.textViews
            let range = canvas.visibleRange
            let selection = canvas.currentSelection
            let highlights = session.drawnHighlights
            let location = session.lastLocation
            let relocated = locations(events()).count
            window.pageControls.value = .hostOnly
            try await wait("live controls") { canvas.configuration.pageControls == .hostOnly }
            XCTAssertTrue(session.canvas === canvas)
            XCTAssertEqual(canvas.visibleRange, range)
            XCTAssertEqual(canvas.currentSelection, selection)
            XCTAssertEqual(session.drawnHighlights, highlights)
            XCTAssertEqual(session.lastLocation, location)
            XCTAssertEqual(locations(events()).count, relocated)
            XCTAssertEqual(canvas.textViews.count, views.count)
            XCTAssertTrue(zip(canvas.textViews, views).allSatisfy { $0 === $1 })
            try await session.send(.nextPage)
            try await wait("host next command") { canvas.visibleRange != range }
            window.pageControls.value = EPUBPageControls(keyboardBindings: [
                .init(.character("n"), modifiers: .command, action: .next),
            ])
            try await wait("replacement bindings") { canvas.configuration.pageControls == window.pageControls.value }
        }
    }

    func testNotReadyAndCancellationDoNotSubmit() async throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        let session = try NativeEngine().makeSession(publication: book) { _ in XCTFail("Unmounted reader emitted") }
        defer { session.close() }
        do { try await session.send(.nextPage); XCTFail("Unmounted reader accepted command") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .notReady) }
        let task = Task { try await session.send(.nextPage) }
        task.cancel()
        do { try await task.value; XCTFail("Canceled command accepted") } catch is CancellationError {}
    }

    func testMountedReaderNavigationSelectionRestoreAndClose() async throws {
        var selected: EPUBSelection?
        let (session, window, events) = try open(Fixture.epub(), action: EPUBSelectionAction(title: "Use passage") { selected = $0 })
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        XCTAssertEqual(session.visibleRange?.start.section, 0)
        for invalid in ["", "#fragment", "https://example.invalid/", "../secret"] {
            do { try await session.send(.navigate(href: invalid)); XCTFail("Invalid href accepted: \(invalid)") }
            catch { guard case .invalidCommand = error as? EPUBReaderError else { return XCTFail("Wrong error: \(error)") } }
        }
        try await session.send(.style(.init(fontSize: 23, isDark: true, flow: .scrolled)))
        try await session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait("second section") { session.visibleRange?.start.section == 1 }
        try await session.send(.locate(text: "The unique  destination passage lives here.", highlight: true))
        try await wait("selection") { session.selection?.text.contains("unique destination") == true }
        let selection = try XCTUnwrap(events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        XCTAssertEqual(selection.text, "The unique destination passage lives here.")
        XCTAssertEqual(selection.location.bookmark?.engineID, EPUBReader.identifier)
        canvasRequestsSelectionAction(session)
        XCTAssertEqual(selected?.text, selection.text)
        XCTAssertEqual(selected?.location.publicationID, session.publication.persistentID)

        let saved = try XCTUnwrap(locations(events()).last)
        XCTAssertEqual(saved.href, "OPS/two.xhtml")
        XCTAssertEqual(saved.bookmark?.format, EPUBReader.bookmarkFormat)
        try await session.send(.navigate(href: "OPS/one.xhtml#start"))
        try await wait("first section") { session.visibleRange?.start.section == 0 }
        try await session.send(.restore(saved))
        try await wait("restored section") { session.visibleRange?.start.section == 1 }
        var incompatible = saved
        incompatible.bookmark?.engineID = "another-engine"
        do { try await session.send(.restore(incompatible)); XCTFail("Incompatible bookmark accepted") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation) }

        try await session.send(.locate(text: "Opening words are visible.", highlight: false))
        try await wait("located first section") { session.visibleRange?.start.section == 0 }
        let before = events().count
        try await session.send(.locate(text: "Nothing like this sentence is in the book.", highlight: false))
        try await wait("a miss") { events().dropFirst(before).contains(.notice(NativeSession.passageNotFound)) }

        let count = events().count
        session.close()
        do { try await session.send(.nextPage); XCTFail("Closed session accepted command") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .closed) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events().count, count)
    }

    /// Bookmarks carry EPUBLib's own identity. A CFI the WebKit reader recorded still names the
    /// same position once a host re-tags it; under the old tag it is another engine's bookmark.
    func testBookmarksCarryEPUBLibsIdentityAndForeignTagsAreRefused() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        XCTAssertEqual(EPUBReader.identifier, "org.epublib.reader")
        XCTAssertEqual(EPUBReader.bookmarkFormat, "epublib-cfi-v1")
        // `/6/4` is the second itemref; `/4/2/1:4` is four characters into the h1's text.
        let recorded = "epubcfi(/6/4!/4/2/1:4)"
        let legacy = EPUBLocation(publicationID: session.publication.id, bookmark: EPUBEngineBookmark(
            engineID: "org.epubreaderlib.foliate", format: "epubcfi-v1", value: recorded))
        do { try await session.send(.restore(legacy)); XCTFail("A foliate-tagged bookmark was accepted") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation) }
        let retagged = EPUBLocation(publicationID: session.publication.id, bookmark: EPUBEngineBookmark(
            engineID: EPUBReader.identifier, format: EPUBReader.bookmarkFormat, value: recorded))
        try await session.send(.restore(retagged))
        try await wait("restored section") { session.visibleRange?.start.section == 1 }
    }

    func testScriptsAreDisclosedAndNeverRun() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/one.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>One</title><script>document.title='ran'</script></head>"
                + "<body><h1 id=\"start\">One</h1><p>Opening words are visible.</p><script src=\"x.js\"></script></body></html>",
        ]))
        defer { session.close(); window.close() }
        try await wait("disclosure") {
            events().contains { if case .disclosure(let text) = $0 { return text.contains("interactive") }; return false }
        }
        XCTAssertFalse(session.book.section(0)?.string.string.contains("ran") ?? true)
    }

    func testSearchAndHostHighlightsAreDrawnAndCleared() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.searchHighlight(text: "ORDINARY reading"))
        try await wait("search highlights") { session.drawnHighlights.filter { $0.kind == .search }.count == 100 }
        let match = try XCTUnwrap(session.drawnHighlights.first)
        let text = try XCTUnwrap(session.book.section(match.range.start.section)?.string.string as NSString?)
        XCTAssertEqual(text.substring(with: NSRange(location: match.range.start.offset, length: match.range.end.offset - match.range.start.offset)),
                       "ordinary reading")
        try await session.send(.clearSearch)
        XCTAssertTrue(session.drawnHighlights.isEmpty)

        try await session.send(.locate(text: "The unique destination passage lives here.", highlight: true))
        try await wait("selection") { session.selection != nil }
        let selected = try XCTUnwrap(events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        try await session.send(.setHighlights([EPUBHighlight(id: "note-1", location: selected.location)]))
        try await wait("host highlight") { session.drawnHighlights.contains { $0.id == "note-1" && $0.kind == .annotation } }
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "note-1" }?.range, session.selection?.range)
        var foreign = selected.location
        foreign.publicationID = "another-book"
        let before = events().count
        try await session.send(.setHighlights([EPUBHighlight(id: "foreign", location: foreign)]))
        XCTAssertTrue(session.drawnHighlights.isEmpty)
        XCTAssertTrue(events().dropFirst(before).contains { if case .notice = $0 { return true }; return false })
    }

    private func chapter(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body>\(body)</body></html>"
    }

    func testQuickTypographyChangesLeaveEverySectionAtTheLastSize() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.style(.init(fontSize: 20)))
        try await session.send(.style(.init(fontSize: 30)))
        try await wait("rebuilt book") { session.book.isComplete && session.book.typography.fontSize == 30 }
        for index in 0..<session.book.count {
            let section = try XCTUnwrap(session.book.section(index))
            var sizes = Set<CGFloat>()
            section.string.enumerateAttribute(.font, in: NSRange(location: 0, length: section.string.length)) { value, _, _ in
                if let font = value as? PlatformFont { sizes.insert(font.pointSize) }
            }
            XCTAssertFalse(sizes.contains(20), "section \(index) kept a 20-pt build: \(sizes)")
        }
    }

    /// The session keeps the rendered ranges of search matches and highlights across an appearance
    /// change. A book whose stylesheet shows other words in dark appearance must not move them (#130).
    func testAnAppearanceChangeKeepsSearchAndHighlightRangesOnTheirWords() async throws {
        let css = ".for-dark { display: none } @media (prefers-color-scheme: dark) { .for-light { display: none } .for-dark { display: inline } }"
        let (session, window, events) = try open(Fixture.epub(overrides: ["OPS/one.xhtml": """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title><style>\(css)</style></head><body>\
            <p>See the <span class="for-light">black</span><span class="for-dark">white-on-black</span> figure.</p>\
            <p id="after">After.</p></body></html>
            """]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.style(.init(fontSize: 17, appearance: .light)))
        try await wait("light book") { session.book.isComplete && !session.book.typography.isDark }
        try await session.send(.searchHighlight(text: "After"))
        let after = try XCTUnwrap(session.searchResults?.results.first?.location)
        try await session.send(.setHighlights([EPUBHighlight(id: "after", location: after)]))
        try await session.send(.searchHighlight(text: "figure"))
        func drawn() throws -> [String] {
            try session.drawnHighlights.map { highlight in
                let section = try XCTUnwrap(session.book.section(highlight.range.start.section))
                return "\(highlight.kind) " + section.mappedText(in: highlight.range.start.offset..<highlight.range.end.offset)
            }
        }
        XCTAssertEqual(try drawn(), ["search figure", "annotation After"])
        let light = session.drawnHighlights
        try await session.send(.style(.init(fontSize: 17, appearance: .dark)))
        try await wait("dark book") { session.book.isComplete && session.book.typography.isDark }
        XCTAssertEqual(session.book.section(0)?.string.string.hasPrefix("See the black figure.\nAfter."), true)
        XCTAssertEqual(session.drawnHighlights, light)
        XCTAssertEqual(try drawn(), ["search figure", "annotation After"])
        XCTAssertEqual(session.searchResultRanges, light.filter { $0.kind == .search }.map(\.range))
    }

    func testLocateInsideATableSelectsTheTable() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/two.xhtml": chapter("<p>Before.</p><table><tr><td>Alpha cell</td><td>Beta cell</td></tr><tr><td>1</td><td>2</td></tr></table><p>After the table.</p>"),
        ]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.locate(text: "Beta cell", highlight: true))
        try await wait("selection") { session.selection != nil }
        let selection = try XCTUnwrap(session.selection)
        XCTAssertEqual(selection.range.start.section, 1)
        XCTAssertFalse(selection.range.isEmpty, "the table unit is selected, not an empty range after it")
    }

    func testARangeEndingWithAnImageResolvesToTheSameRange() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/one.xhtml": chapter("<p>Alpha <img src=\"pic.png\" alt=\"a picture\"/></p><p>Next.</p>"),
            "OPS/pic.png": "not really a png",
        ]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let section = try XCTUnwrap(session.book.section(0))
        let end = (section.string.string as NSString).range(of: "\n").location
        XCTAssertGreaterThan(end, 6)
        let range = ReaderTextRange(section: 0, 0..<end)
        session.canvas(try XCTUnwrap(session.canvas), didChangeSelection: ReaderSelection(range: range, text: ""))
        let selected = try XCTUnwrap(events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        try await session.send(.setHighlights([EPUBHighlight(id: "h", location: selected.location)]))
        try await wait("highlight") { session.drawnHighlights.contains { $0.id == "h" } }
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "h" }?.range, range)
    }

    func testARangeEndingWithTheSectionsLastImageResolvesToTheSameRange() async throws {
        // Nothing follows the image in the document, not even white space.
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/one.xhtml": chapter("<p>Alpha <img src=\"pic.png\" alt=\"a picture\"/></p>"),
            "OPS/pic.png": "not really a png",
        ]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let section = try XCTUnwrap(session.book.section(0))
        XCTAssertTrue(section.document.nodes.last?.isHTML("img") == true)
        let image = try XCTUnwrap(section.map.spans.last)
        XCTAssertTrue(image.isUnit)
        XCTAssertEqual(image.location + image.length, section.string.length)
        // The passage with the image, and the image alone, which came back empty and so unresolved.
        for (id, lower) in [("passage", 0), ("image", image.location)] {
            let range = ReaderTextRange(section: 0, lower..<section.string.length)
            session.canvas(try XCTUnwrap(session.canvas), didChangeSelection: ReaderSelection(range: range, text: ""))
            XCTAssertEqual(session.selection?.range, range, id)
            let selected = try lastSelection(events())
            try await session.send(.setHighlights([EPUBHighlight(id: id, location: selected.location)]))
            try await wait("highlight \(id)") { session.drawnHighlights.contains { $0.id == id } }
            XCTAssertEqual(session.drawnHighlights.first { $0.id == id }?.range, range, id)
        }
        XCTAssertFalse(events().contains { if case .notice = $0 { return true }; return false })
    }

    func testABareSectionBookmarkRestoresToThatSection() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: ["OPS/two.xhtml": chapter("")]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let before = events().count
        try await session.send(.restore(EPUBLocation(publicationID: session.publication.id, bookmark: EPUBEngineBookmark(
            engineID: EPUBReader.identifier, format: EPUBReader.bookmarkFormat, value: "epubcfi(/6/4)"))))
        try await wait("restored section") { session.visibleRange?.start.section == 1 }
        XCTAssertFalse(events().dropFirst(before).contains { if case .notice = $0 { return true }; return false })
    }

    func testPassageTextLeavesOutGeneratedQuotes() async throws {
        let (session, window, events) = try open(Fixture.epub(overrides: [
            "OPS/one.xhtml": chapter("<p>She said <q>hello there</q> and left.</p>"),
        ]))
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.locate(text: "She said hello there and left.", highlight: true))
        try await wait("selection") { session.selection != nil }
        XCTAssertEqual(session.selection?.text, "She said hello there and left.")
    }

    /// Three linear sections with a nonlinear note in the middle and page markers in each.
    private func multiSectionFixture(middle: String = "<p id=\"page\">Beta middle words.</p>") throws -> Data {
        var package = String(decoding: try XCTUnwrap(Fixture.files()["OPS/book.opf"]), as: UTF8.self)
        package = package.replacingOccurrences(of: "<item id=\"nav\"", with:
            "<item id=\"note\" href=\"note.xhtml\" media-type=\"application/xhtml+xml\"/>"
            + "<item id=\"three\" href=\"three.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"nav\"")
            .replacingOccurrences(of: "<itemref idref=\"two\"/>", with:
                "<itemref idref=\"note\" linear=\"no\"/><itemref idref=\"two\"/><itemref idref=\"three\"/>")
        let pages = [("one", "A"), ("note", "N"), ("two", "B"), ("three", "C")]
            .map { "<li><a href=\"\($0.0).xhtml#page\">\($0.1)</a></li>" }.joined()
        return try Fixture.epub(overrides: [
            "OPS/book.opf": package,
            "OPS/one.xhtml": chapter("<p id=\"page\">Alpha opening words.</p>"),
            "OPS/note.xhtml": chapter("<p id=\"page\">OMITTED nonlinear note.</p>"),
            "OPS/two.xhtml": chapter(middle),
            "OPS/three.xhtml": chapter("<p id=\"page\">Gamma ending words.</p>"),
            "OPS/nav.xhtml": "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">"
                + "<head><title>Pages</title></head><body><nav epub:type=\"page-list\"><ol>\(pages)</ol></nav></body></html>",
        ])
    }

    private func lastSelection(_ events: [EPUBReaderEvent]) throws -> EPUBSelection {
        try XCTUnwrap(events.compactMap { if case .selectionChanged(let value) = $0 { return value }; return nil }.last)
    }

    private func exerciseMultiSectionSelection(endingAt last: Int) async throws {
        var actionSelection: EPUBSelection?
        let data = try multiSectionFixture()
        let (session, window, events) = try open(data,
            action: EPUBSelectionAction(title: "Save") { actionSelection = $0 })
        defer { session.close(); window.close() }
        try await wait("complete book") { session.isReady && session.book.isComplete }
        try await session.send(.style(.init(flow: .scrolled)))
        try await wait("whole book scroll") { session.canvas?.scrollBook != nil }
        let range = ReaderTextRange(start: .init(section: 0, offset: 4), end: .init(section: last, offset: 5))
        let canvas = try XCTUnwrap(session.canvas)
        canvas.show(range.start, selecting: range)
        try await wait("multi-section selection") { session.selection?.range == range }
        let selected = try lastSelection(events())
        XCTAssertFalse(selected.text.contains("OMITTED"))
        XCTAssertTrue(selected.text.hasPrefix("a opening words."))
        XCTAssertTrue(selected.text.hasSuffix(last == 2 ? "Beta " : "Gamma"))
        XCTAssertEqual(selected.location.rangeBookmarks?.count, last == 2 ? 2 : 3)
        XCTAssertEqual(selected.location.bookmark, selected.location.rangeBookmarks?.first)
        XCTAssertEqual(selected.location.page?.label, "A")
        XCTAssertEqual(selected.location.pages?.map(\.label), last == 2 ? ["A", "B"] : ["A", "B", "C"])
        XCTAssertNil(selected.location.title)
        canvasRequestsSelectionAction(session)
        XCTAssertEqual(actionSelection, selected)
        let saved = try JSONDecoder().decode(EPUBLocation.self, from: JSONEncoder().encode(selected.location))
        XCTAssertEqual(saved, selected.location)

        // Live relayout preserves the selection, including both endpoints and omitted sections.
        for style in [EPUBReaderStyle(fontSize: 28, isDark: true, flow: .scrolled),
                      EPUBReaderStyle(fontSize: 21, flow: .paginated), EPUBReaderStyle(flow: .scrolled)] {
            let before = events().count
            try await session.send(.style(style))
            try await wait("relayout") { session.book.isComplete && canvas.currentSelection?.range == range }
            // Wait past the 150-ms selection debounce so stale session state cannot mask a lost
            // native selection when its text views were replaced during the flow change.
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(canvas.currentSelection?.range, range)
            XCTAssertEqual(session.selection?.range, range)
            XCTAssertFalse(events().dropFirst(before).contains(.selectionChanged(nil)))
            XCTAssertEqual(try lastSelection(events()).location.rangeBookmarks, saved.rangeBookmarks)
        }

        // A new session resolves every saved segment at a different typography and in both flows.
        let (reopened, again, reopenedEvents) = try open(data)
        defer { reopened.close(); again.close() }
        try await wait("reopened ready") { reopened.isReady }
        for style in [EPUBReaderStyle(fontSize: 26), EPUBReaderStyle(fontSize: 31, isDark: true, flow: .scrolled)] {
            try await reopened.send(.style(style))
            try await wait("rebuilt reopened book") { reopened.book.isComplete }
            try await reopened.send(.setHighlights([EPUBHighlight(id: "saved", location: saved)]))
            let segments = reopened.drawnHighlights.filter { $0.id == "saved" }
            XCTAssertEqual(segments.map { $0.range.start.section }, last == 2 ? [0, 2] : [0, 2, 3])
            XCTAssertEqual(segments.first?.range.start, range.start)
            XCTAssertEqual(segments.last?.range.end, range.end)
            XCTAssertTrue(segments.dropFirst().allSatisfy { $0.range.start.offset == 0 })
            let restoredText = try segments.map { segment in
                let section = try XCTUnwrap(reopened.book.section(segment.range.start.section))
                return section.mappedText(in: segment.range.start.offset..<segment.range.end.offset)
            }.joined(separator: "\n")
            XCTAssertEqual(restoredText, selected.text)
            for segment in segments.dropLast() {
                let section = try XCTUnwrap(reopened.book.section(segment.range.start.section))
                // Generated inter-section separators have no DOM CFI; every book character does.
                XCTAssertEqual(segment.range.end.offset, section.map.length)
            }
            XCTAssertFalse(reopenedEvents().contains { if case .notice = $0 { return true }; return false })
            try await reopened.send(.navigate(href: last == 2 ? "OPS/two.xhtml" : "OPS/three.xhtml"))
            try await reopened.send(.restore(saved))
            XCTAssertEqual(reopened.canvas?.visibleRange?.start.section, 0)
            XCTAssertNil(reopened.selection, "restore navigates; setHighlights restores the passage")
        }
    }

    func testSelectionCrossingTwoLinearSectionsRoundTrips() async throws {
        try await exerciseMultiSectionSelection(endingAt: 2)
    }

    func testSelectionCrossingThreeLinearSectionsRoundTrips() async throws {
        try await exerciseMultiSectionSelection(endingAt: 3)
    }

    func testEmptySectionAndZeroOffsetEndDoNotProduceEmptyHighlightSegments() async throws {
        let (session, window, events) = try open(multiSectionFixture(middle: ""))
        defer { session.close(); window.close() }
        try await wait("complete book") { session.isReady && session.book.isComplete }
        XCTAssertEqual(session.book.section(2)?.string.length, 0)
        let canvas = try XCTUnwrap(session.canvas)
        // The exclusive end at the final section's start does not select any of that section.
        let range = ReaderTextRange(start: .init(section: 0, offset: 4), end: .init(section: 3, offset: 0))
        session.canvas(canvas, didChangeSelection: ReaderSelection(range: range, text: ""))
        let selected = try lastSelection(events())
        XCTAssertNil(selected.location.rangeBookmarks, "only one nonempty document was selected")
        XCTAssertEqual(selected.location.href, "OPS/one.xhtml")
        try await session.send(.setHighlights([EPUBHighlight(id: "edge", location: selected.location)]))
        XCTAssertEqual(session.drawnHighlights.count, 1)
        XCTAssertEqual(session.drawnHighlights.first?.range.start, range.start)
        XCTAssertEqual(session.drawnHighlights.first?.range.end.offset, session.book.section(0)?.string.length)
        XCTAssertFalse(selected.text.contains("Gamma"))
        XCTAssertFalse(events().contains { if case .notice = $0 { return true }; return false })

        // Including part of the final document produces two segments, skipping the empty one.
        let extended = ReaderTextRange(start: range.start, end: .init(section: 3, offset: 5))
        session.canvas(canvas, didChangeSelection: ReaderSelection(range: extended, text: ""))
        let saved = try lastSelection(events()).location
        XCTAssertEqual(saved.rangeBookmarks?.count, 2)
        try await session.send(.setHighlights([EPUBHighlight(id: "extended", location: saved)]))
        XCTAssertEqual(session.drawnHighlights.map { $0.range.start.section }, [0, 3])
        XCTAssertFalse(events().contains { if case .notice = $0 { return true }; return false })

        // Starting exactly after the first document's final character names the next meaningful
        // document, without keeping an empty first CFI or a contradictory section href.
        let afterFirst = ReaderTextRange(start: .init(section: 0, offset: try XCTUnwrap(session.book.section(0)?.string.length)),
                                        end: extended.end)
        session.canvas(canvas, didChangeSelection: ReaderSelection(range: afterFirst, text: ""))
        let final = try lastSelection(events()).location
        XCTAssertNil(final.rangeBookmarks)
        XCTAssertEqual(final.href, "OPS/three.xhtml")
        try await session.send(.setHighlights([EPUBHighlight(id: "after-first", location: final)]))
        XCTAssertEqual(session.drawnHighlights.first?.range, ReaderTextRange(section: 3, 0..<5))
    }

    func testGeneratedOnlySectionDoesNotMakeMultiSectionHighlightUnresolvable() async throws {
        let (session, window, events) = try open(multiSectionFixture(middle: "<ol><li/></ol>"))
        defer { session.close(); window.close() }
        try await wait("complete book") { session.isReady && session.book.isComplete }
        let generated = try XCTUnwrap(session.book.section(2))
        XCTAssertGreaterThan(generated.string.length, 0, "the empty list item draws a generated marker")
        XCTAssertTrue(generated.map.spans.isEmpty, "the marker has no source text")
        let range = ReaderTextRange(start: .init(section: 0, offset: 4), end: .init(section: 3, offset: 5))
        session.canvas(try XCTUnwrap(session.canvas), didChangeSelection: ReaderSelection(range: range, text: ""))
        let selected = try lastSelection(events())
        XCTAssertEqual(selected.location.rangeBookmarks?.count, 2)
        XCTAssertFalse(selected.text.contains("1."))
        try await session.send(.setHighlights([EPUBHighlight(id: "generated", location: selected.location)]))
        XCTAssertEqual(session.drawnHighlights.map { $0.range.start.section }, [0, 3])
        XCTAssertFalse(events().contains { if case .notice = $0 { return true }; return false })
    }

    func testMalformedMultiSectionHighlightsAreRejectedWithoutPartialDrawing() async throws {
        let (session, window, events) = try open(multiSectionFixture())
        defer { session.close(); window.close() }
        try await wait("complete book") { session.isReady && session.book.isComplete }
        let canvas = try XCTUnwrap(session.canvas)
        let range = ReaderTextRange(start: .init(section: 0, offset: 4), end: .init(section: 3, offset: 5))
        session.canvas(canvas, didChangeSelection: ReaderSelection(range: range, text: ""))
        let location = try lastSelection(events()).location
        var cases: [EPUBLocation] = []
        var invalid = location; invalid.rangeBookmarks = []; cases.append(invalid)
        invalid = location; invalid.rangeBookmarks?[1].engineID = "foreign"; cases.append(invalid)
        invalid = location; invalid.rangeBookmarks?[1].format = "foreign"; cases.append(invalid)
        invalid = location; invalid.rangeBookmarks?[0].value = "epubcfi(/6/2)"; cases.append(invalid)
        invalid = location; invalid.rangeBookmarks = location.rangeBookmarks?.reversed();
        invalid.bookmark = invalid.rangeBookmarks?.first; cases.append(invalid)
        invalid = location; invalid.rangeBookmarks?[1].value = "epubcfi(/6/4!/4/2/1:2)"; cases.append(invalid) // nonlinear
        invalid = location; invalid.rangeBookmarks?[2].value = "epubcfi(/6/8!/400/2/1:5)"; cases.append(invalid) // unresolved DOM
        invalid = location; invalid.rangeBookmarks?[2].value = "epubcfi(/6/8!/4/2/1:5)"; cases.append(invalid) // empty segment
        invalid = location; invalid.publicationID = "foreign"; cases.append(invalid)
        for (index, invalid) in cases.enumerated() {
            let before = events().count
            try await session.send(.setHighlights([EPUBHighlight(id: "bad-\(index)", location: invalid)]))
            XCTAssertTrue(session.drawnHighlights.isEmpty)
            XCTAssertEqual(events().dropFirst(before).filter { if case .notice = $0 { return true }; return false }.count, 1)
            try await session.send(.navigate(href: "OPS/three.xhtml"))
            let position = session.visibleRange?.start
            do { try await session.send(.restore(invalid)) }
            catch { XCTAssertEqual(error as? EPUBReaderError, .incompatibleLocation) }
            XCTAssertEqual(session.visibleRange?.start, position, "invalid range must not restore its first segment")
        }
    }

    func testLegacySingleSectionCodableLocationStillRestores() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { session.isReady }
        // Exact old schema: no rangeBookmarks, page or pages keys.
        let legacy = Data("""
            {"publicationID":"\(session.publication.id)","bookmark":{"engineID":"org.epublib.reader",            "format":"epublib-cfi-v1","value":"epubcfi(/6/4!/4/2/1:4)"}}
            """.utf8)
        let saved = try JSONDecoder().decode(EPUBLocation.self, from: legacy)
        XCTAssertNil(saved.rangeBookmarks)
        try await session.send(.restore(saved))
        try await wait("legacy section") { session.visibleRange?.start.section == 1 }
        XCTAssertFalse(events().contains { if case .notice = $0 { return true }; return false })
    }

    func testTheWholeBookLeavesOutNonlinearSections() async throws {
        let package = String(decoding: try XCTUnwrap(Fixture.files()["OPS/book.opf"]), as: UTF8.self)
            .replacingOccurrences(of: "<itemref idref=\"two\"/>", with: "<itemref idref=\"two\" linear=\"no\"/>")
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": package]))
        XCTAssertFalse(publication.spine[1].isLinear)
        let book = NativeBook(publication: publication, typography: NativeTypography(), rich: NativeRichContent())
        defer { book.close() }
        for index in publication.spine.indices { _ = await book.build(index) }
        let text = try XCTUnwrap(book.bookText)
        XCTAssertTrue(text.contains(section: 0))
        XCTAssertFalse(text.contains(section: 1))
        XCTAssertEqual(text.string.length, book.section(0)?.string.length)
    }

    func testARemountedReaderShowsItsPlaceAgain() async throws {
        let (session, window, events) = try open(Fixture.epub())
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait("second section") { session.visibleRange?.start.section == 1 }
        window.close()
        let again = ReaderTestWindow(session: session)
        defer { session.close(); again.close() }
        try await wait("remounted canvas") { session.canvas?.visibleRange?.start.section == 1 }
        XCTAssertEqual(events().filter { $0 == .ready }.count, 1)
    }

    // MARK: - Opening position

    /// The first location a freshly opened book reports, once the reader is ready.
    private func openingLocation(_ data: Data) async throws -> (NativeSession, EPUBLocation) {
        let (session, window, events) = try open(data)
        addTeardownBlock { @MainActor in session.close(); window.close() }
        try await wait("first location") { !locations(events()).isEmpty }
        XCTAssertEqual(events().first, .ready)
        return (session, try XCTUnwrap(locations(events()).first))
    }

    /// With nothing restored, a book opens at its text start, as foliate-js's `showTextStart` did:
    /// a Standard Ebooks title on its first chapter, not its cover or titlepage.
    func testABookOpensAtItsBodymatterLandmark() async throws {
        let (session, first) = try await openingLocation(Fixture.frontMatter())
        XCTAssertEqual(first.href, "OPS/text/chapter-1.xhtml")
        XCTAssertEqual(first.title, "Chapter 1")
        // `/6/6` is the third itemref.
        XCTAssertTrue(first.bookmark?.value.hasPrefix("epubcfi(/6/6!") == true, first.bookmark?.value ?? "no bookmark")
        XCTAssertEqual(session.visibleRange?.start, ReaderTextPosition(section: 2, offset: 0))
        // The front matter is still a page turn away.
        try await session.send(.previousPage)
        try await wait("titlepage") { session.visibleRange?.start.section == 1 }
    }

    func testAnEPUB2BookOpensAtItsGuideTextReference() async throws {
        let (session, first) = try await openingLocation(Fixture.frontMatter(bodymatter: nil, text: "text/chapter-1.xhtml", epub2: true))
        XCTAssertEqual(first.href, "OPS/text/chapter-1.xhtml")
        XCTAssertEqual(session.visibleRange?.start.section, 2)
    }

    func testABookWithoutLandmarksOpensAtItsFirstLinearSection() async throws {
        let (session, first) = try await openingLocation(Fixture.frontMatter(bodymatter: nil))
        XCTAssertEqual(first.href, "OPS/text/cover.xhtml")
        XCTAssertEqual(session.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0))
    }

    /// A fragment resolves as `.navigate(href:)` resolves one: the page holding its anchor.
    func testATextStartFragmentOpensOnTheAnchorsPage() async throws {
        let (session, first) = try await openingLocation(Fixture.frontMatter(bodymatter: "text/chapter-1.xhtml#deep"))
        XCTAssertEqual(first.href, "OPS/text/chapter-1.xhtml")
        let anchor = ReaderTextPosition(section: 2, offset: try XCTUnwrap(session.book.section(2)?.anchors["deep"]))
        let visible = try XCTUnwrap(session.visibleRange)
        XCTAssertGreaterThan(visible.start.offset, 0, "the anchor is pages into its section")
        XCTAssertTrue(visible.start <= anchor && anchor < visible.end, "\(anchor) is not in \(visible)")
    }

    /// A text start that names no section of the book falls back to the first linear section.
    func testATextStartThatDoesNotResolveFallsBackToTheFirstLinearSection() throws {
        for href in ["text/missing.xhtml#chapter-1", "nav.xhtml", "toc.ncx"] {
            let publication = try EPUBPublication.open(data: Fixture.frontMatter(bodymatter: href))
            XCTAssertEqual(publication.landmarks.last?.types.first, "bodymatter", "\(href) is a landmark")
            let target = NativeSession.openingTarget(of: publication)
            XCTAssertEqual(target.section, 0, href)
            XCTAssertNil(target.fragment, href)
        }
        let package = String(decoding: try XCTUnwrap(Fixture.files()["OPS/book.opf"]), as: UTF8.self)
            .replacingOccurrences(of: "<itemref idref=\"one\"/>", with: "<itemref idref=\"one\" linear=\"no\"/>")
        let publication = try EPUBPublication.open(data: Fixture.epub(overrides: ["OPS/book.opf": package]))
        XCTAssertEqual(NativeSession.openingTarget(of: publication).section, 1, "the first linear section")
    }

    /// A host restores a saved position as soon as the reader is ready. The text start shows
    /// first, then the restored position replaces it and stays.
    func testARestoreOnReadyWinsOverTheTextStart() async throws {
        let publication = try EPUBPublication.open(data: Fixture.frontMatter())
        // `/6/4` is the titlepage, before the text start; `/4/2/1:4` is four characters into its h1.
        let saved = EPUBLocation(publicationID: publication.id, bookmark: EPUBEngineBookmark(
            engineID: EPUBReader.identifier, format: EPUBReader.bookmarkFormat, value: "epubcfi(/6/4!/4/2/1:4)"))
        @MainActor final class Reader { var session: NativeSession? }
        let reader = Reader()
        var events: [EPUBReaderEvent] = []
        let made = try NativeEngine().makeSession(publication: publication, selectionAction: nil) { event in
            events.append(event)
            guard event == .ready, let session = reader.session else { return }
            Task {
                do { try await session.send(.restore(saved)) } catch { XCTFail("Restore refused: \(error)") }
            }
        }
        let session = try XCTUnwrap(made as? NativeSession)
        reader.session = session
        let window = ReaderTestWindow(session: session)
        defer { session.close(); window.close() }
        try await wait("restored position") { locations(events).last?.href == "OPS/text/titlepage.xhtml" }
        try await wait("whole book") { session.book.isComplete }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(locations(events).first?.href, "OPS/text/chapter-1.xhtml")
        XCTAssertEqual(locations(events).last?.href, "OPS/text/titlepage.xhtml")
        XCTAssertEqual(session.visibleRange?.start.section, 1)
        XCTAssertFalse(events.contains { if case .notice = $0 { return true }; return false })
    }

    // MARK: - Page list

    /// The page-list entries a range shows, read from every section's anchors: the last entry at
    /// or before its start, then those inside it.
    private func expectedPages(_ session: NativeSession, _ range: ReaderTextRange) throws -> (page: String?, pages: [String]?) {
        var positioned: [(label: String, position: ReaderTextPosition)] = []
        for entry in try XCTUnwrap(session.publication.pageList) {
            let parts = entry.href.split(separator: "#")
            let section = try XCTUnwrap(session.publication.spine.firstIndex { $0.resource.href == parts[0] })
            let offset = try XCTUnwrap(session.book.section(section)?.anchors[String(parts[1])], entry.label)
            positioned.append((entry.label, ReaderTextPosition(section: section, offset: offset)))
        }
        let page = positioned.last { $0.position <= range.start }?.label
        let pages = (page.map { [$0] } ?? []) + positioned.filter { range.start < $0.position && $0.position < range.end }.map(\.label)
        return (page, pages.isEmpty ? nil : pages)
    }

    /// The last location reported, checked against the range on screen.
    @discardableResult
    private func reportedPages(_ session: NativeSession, _ events: [EPUBReaderEvent], _ step: String,
                               file: StaticString = #filePath, line: UInt = #line) throws -> EPUBLocation {
        let location = try XCTUnwrap(locations(events).last, step, file: file, line: line)
        let range = try XCTUnwrap(session.visibleRange, step, file: file, line: line)
        XCTAssertEqual(location, session.lastLocation, step, file: file, line: line)
        let expected = try expectedPages(session, range)
        XCTAssertEqual(location.page?.label, expected.page, "\(step): \(range)", file: file, line: line)
        XCTAssertEqual(location.pages?.map(\.label), expected.pages, "\(step): \(range)", file: file, line: line)
        return location
    }

    private func pageAnchor(_ session: NativeSession, _ section: Int, _ label: String) throws -> ReaderTextPosition {
        ReaderTextPosition(section: section, offset: try XCTUnwrap(session.book.section(section)?.anchors["page-\(label)"]))
    }

    private func wait(_ label: String, showing position: ReaderTextPosition, in session: NativeSession) async throws {
        try await wait(label) { session.visibleRange.map { $0.start <= position && position < $0.end } ?? false }
    }

    /// `Fixture.pageList()` read in one flow: the page in effect where the shown range starts
    /// and the pages it shows, after page turns, scrolling, navigation to markers, a restore and
    /// a resize, and for a selection.
    private func exercisePageList(flow: EPUBReadingFlow) async throws {
        let (session, window, events) = try open(Fixture.pageList())
        defer { session.close(); window.close() }
        try await wait("first location") { !locations(events()).isEmpty }
        XCTAssertNil(locations(events()).first?.page, "the book opens before its first page")
        try await wait("whole book") { session.book.isComplete }
        try await session.send(.style(.init(flow: flow)))
        if flow == .scrolled { try await wait("whole-book scroll") { session.canvas?.scrollBook != nil } }
        try await wait("the book's start") { session.visibleRange?.start == ReaderTextPosition(section: 0, offset: 0) }
        XCTAssertNil(try reportedPages(session, events(), "start").page)

        // Turning through the whole book shows every page, in order.
        let last = ReaderTextPosition(section: 2, offset: try XCTUnwrap(session.book.section(2)?.string.length))
        var seen: [String] = []
        var inEffect: [String?] = []
        for turn in 0..<300 {
            let location = try reportedPages(session, events(), "turn \(turn)")
            inEffect.append(location.page?.label)
            for label in location.pages?.map(\.label) ?? [] where !seen.contains(label) { seen.append(label) }
            let shown = try XCTUnwrap(session.visibleRange)
            if shown.end == last { break }
            try await session.send(.nextPage)
            try await wait("turn \(turn + 1)") { session.visibleRange != shown }
        }
        XCTAssertEqual(seen, Fixture.pageLabels)
        let order = inEffect.map { $0.flatMap { Fixture.pageLabels.firstIndex(of: $0) } ?? -1 }
        XCTAssertEqual(order, order.sorted(), "\(inEffect)")

        if flow == .scrolled {
            // The person scrolls (not through a command).
            let start = try XCTUnwrap(session.visibleRange)
            let view = try XCTUnwrap(session.canvas?.scrollTextView)
            let line = try XCTUnwrap(view.lineFrame(containing: try XCTUnwrap(session.canvas?.scrollBook)
                .location(of: try pageAnchor(session, 1, "3"))))
            // A few lines above it, so the line is on screen whatever the insets.
            let top = line.minY - 3 * line.height
            #if os(macOS)
            let scrollView = try XCTUnwrap(session.canvas?.scrollContainer as? NSScrollView)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            #else
            view.contentOffset = CGPoint(x: 0, y: top)
            #endif
            try await wait("scrolled") { session.visibleRange != start && locations(events()).last == session.lastLocation }
            let scrolled = try reportedPages(session, events(), "scrolled")
            XCTAssertEqual(scrolled.page?.label, "2")
            XCTAssertEqual(scrolled.pages?.filter { ["3", "4"].contains($0.label) }.map(\.label), ["3", "4"], "two markers on one screen")
        }

        try await session.send(.navigate(href: "OPS/chapter-2.xhtml"))
        try await wait("chapter two") { session.visibleRange?.start == ReaderTextPosition(section: 2, offset: 0) }
        XCTAssertEqual(try reportedPages(session, events(), "chapter two").page?.label, "4", "a section opening without a marker")
        try await session.send(.navigate(href: "OPS/chapter-1.xhtml"))
        try await wait("chapter one") { session.visibleRange?.start == ReaderTextPosition(section: 1, offset: 0) }
        XCTAssertEqual(try reportedPages(session, events(), "chapter one").page?.label, "1", "a marker opening its section")
        try await session.send(.navigate(href: "OPS/chapter-1.xhtml#page-2"))
        try await wait("page 2", showing: try pageAnchor(session, 1, "2"), in: session)
        let two = try reportedPages(session, events(), "page 2")
        XCTAssertTrue(two.pages?.map(\.label).contains("2") == true, "a marker mid-paragraph")
        try await session.send(.navigate(href: "OPS/chapter-1.xhtml#page-3"))
        try await wait("page 3", showing: try pageAnchor(session, 1, "3"), in: session)
        let three = try reportedPages(session, events(), "page 3")
        XCTAssertEqual(three.pages?.filter { ["3", "4"].contains($0.label) }.map(\.label), ["3", "4"], "two markers on one screen")

        // A selection's location reports the pages it spans.
        try await session.send(.locate(text: "Page one ends before the break and page two begins after it.", highlight: true))
        try await wait("selection") { session.selection != nil }
        let selection = try XCTUnwrap(events().compactMap { event -> EPUBSelection? in
            if case .selectionChanged(let value) = event { return value }; return nil
        }.last)
        XCTAssertEqual(selection.location.page?.label, "1")
        XCTAssertEqual(selection.location.pages?.map(\.label), ["1", "2"])
        XCTAssertNil(selection.location.title, "selections carry no contents title")

        try await session.send(.navigate(href: "OPS/chapter-2.xhtml#page-5"))
        try await wait("page 5", showing: try pageAnchor(session, 2, "5"), in: session)
        let saved = try reportedPages(session, events(), "page 5")
        XCTAssertTrue(saved.pages?.map(\.label).contains("5") == true)
        try await session.send(.navigate(href: "OPS/front.xhtml"))
        try await wait("the preface") { session.visibleRange?.start.section == 0 }
        try await session.send(.restore(saved))
        try await wait("restored") { session.visibleRange?.start.section == 2 }
        XCTAssertEqual(try reportedPages(session, events(), "restored").page, saved.page)

        try await session.send(.navigate(href: "OPS/chapter-2.xhtml#page-5"))
        let before = try XCTUnwrap(session.visibleRange)
        window.resize(to: CGSize(width: 360, height: 520))
        try await wait("resized") { session.visibleRange != before && locations(events()).last == session.lastLocation }
        try await wait("page 5 after the resize", showing: try pageAnchor(session, 2, "5"), in: session)
        XCTAssertTrue(try reportedPages(session, events(), "resized").pages?.map(\.label).contains("5") == true)
        XCTAssertFalse(events().contains { if case .failed = $0 { return true }; return false })
    }

    func testPagesWhenPaginated() async throws { try await exercisePageList(flow: .paginated) }
    func testPagesWhenScrolled() async throws { try await exercisePageList(flow: .scrolled) }

    /// A book without a page list reports no pages.
    func testABookWithoutAPageListReportsNoPages() async throws {
        let (session, window, events) = try open(Fixture.epub())
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        try await session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait("second section") { session.visibleRange?.start.section == 1 }
        XCTAssertFalse(locations(events()).isEmpty)
        XCTAssertTrue(locations(events()).allSatisfy { $0.page == nil && $0.pages == nil })
        XCTAssertEqual(locations(events()).last?.title, "Second Chapter")
    }

    private func canvasRequestsSelectionAction(_ session: NativeSession) {
        session.canvasDidRequestSelectionAction(try! XCTUnwrap(session.canvas))
    }

    private func exercise(_ kind: Fixture.Rendering) async throws {
        let data = try await Task.detached { try Fixture.rendering(kind) }.value
        let (session, window, events) = try open(data)
        defer { session.close(); window.close() }
        try await wait("ready") { events().contains(.ready) }
        let publication = session.publication
        switch kind {
        case .escapedHref:
            XCTAssertEqual(publication.spine[0].resource.href, "OPS/chapter%20%23100%25%3F.xhtml")
            let toc = try XCTUnwrap(publication.tableOfContents.first?.href)
            try await session.send(.navigate(href: toc))
            try await wait("fragment") { session.visibleRange?.start.section == 0 }
        case .fixedLayout:
            XCTAssertEqual(publication.spine[0].layout, .prePaginated)
            try await wait("fixed-layout disclosure") {
                events().contains { if case .disclosure(let text) = $0 { return text.contains("fixed page layout") }; return false }
            }
            try await session.send(.style(.init(fontSize: 22)))
        case .rightToLeft:
            XCTAssertEqual(publication.pageProgression, .rtl)
            XCTAssertEqual(session.canvas?.configuration.isRightToLeft, true)
        case .vertical:
            try await wait("vertical disclosure") {
                events().contains { if case .disclosure(let text) = $0 { return text.contains("Vertical") }; return false }
            }
        case .largeIllustrated:
            XCTAssertEqual(publication.spine.count, 40)
            XCTAssertGreaterThan(data.count, 20 * 1024 * 1024)
        }
        try await wait("first location") { locations(events()).last?.href == publication.spine[0].resource.href }
        let href = try XCTUnwrap(locations(events()).last?.href)
        try await session.send(.navigate(href: publication.spine.last!.resource.href))
        try await wait("last section") { session.visibleRange?.start.section == publication.spine.count - 1 }
        try await session.send(.navigate(href: href))
        try await wait("first section again") { session.visibleRange?.start.section == 0 }
        XCTAssertEqual(events().filter { $0 == .ready }.count, 1)
        XCTAssertFalse(events().contains { if case .failed = $0 { return true }; return false })
    }

    func testEncodedHrefRoundTrip() async throws { try await exercise(.escapedHref) }
    func testFixedLayoutReflows() async throws { try await exercise(.fixedLayout) }
    func testRightToLeft() async throws { try await exercise(.rightToLeft) }
    func testVerticalWriting() async throws { try await exercise(.vertical) }
    func testLargeIllustratedBook() async throws { try await exercise(.largeIllustrated) }
}
