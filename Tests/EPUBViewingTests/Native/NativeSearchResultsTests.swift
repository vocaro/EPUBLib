import EPUBCore
import EPUBReading
import EPUBTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

/// Search results in the native engine: a mounted session in a real window, driven through the
/// public commands and observed through its events, published state and visible range.
@MainActor final class NativeSearchResultsTests: XCTestCase {
    private func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func open(_ data: Data, onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void = { _ in })
        throws -> (NativeSession, ReaderTestWindow, () -> [EPUBReaderEvent]) {
        let publication = try EPUBPublication.open(data: data)
        var events: [EPUBReaderEvent] = []
        var created: NativeSession?
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) {
            events.append($0)
            // Whatever a host observes from a callback, published results belong to a completed search.
            if let status = created?.readerState?.status, status.searchResults != nil {
                if case .completed = status.search {} else { XCTFail("Results published while search is \(status.search)") }
            }
            onEvent($0)
        } as? NativeSession)
        created = session
        return (session, ReaderTestWindow(session: session), { events })
    }

    /// Three spine documents. “findneedle” renders three times in the first (once under a later
    /// contents entry, once accented), never in the second, and three times in the third (once
    /// in a table cell); a hidden paragraph in the first holds one more that never renders.
    nonisolated static func book() throws -> Data {
        func page(_ title: String, _ body: String) -> String {
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(title) document</title></head><body>\(body)</body></html>"
        }
        let filler = String(repeating: "<p>Plain filler prose that pads the page out for pagination.</p>", count: 60)
        var files = try Fixture.files().mapValues { String(decoding: $0, as: UTF8.self) }
        files["OPS/book.opf"] = files["OPS/book.opf"]!
            .replacingOccurrences(of: "<item id=\"two\"", with: "<item id=\"three\" href=\"three.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"two\"")
            .replacingOccurrences(of: "<itemref idref=\"two\"/>", with: "<itemref idref=\"two\"/><itemref idref=\"three\"/>")
        files["OPS/nav.xhtml"] = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body>
        <nav epub:type="toc"><ol><li><a href="one.xhtml#start">First Chapter</a><ol><li><a href="one.xhtml#later">Later Part</a></li></ol></li>
        <li><a href="two.xhtml">Second Chapter</a></li><li><a href="three.xhtml">Third Chapter</a></li></ol></nav>
        <nav epub:type="page-list"><ol><li><a href="one.xhtml#start">1</a></li><li><a href="one.xhtml#later">2</a></li>
        <li><a href="three.xhtml#last">3</a></li></ol></nav></body></html>
        """
        files["OPS/one.xhtml"] = page("One", """
        <h1 id="start">First Chapter</h1><p style="display:none">Findneedle hidden from every reader.</p>
        <p>Alpha comes before findneedle one, then more.</p>\(filler)
        <h2 id="later">Later Part</h2><p>Beta has FINDNEEDLE   two and findnéedle three close together.</p>\(filler)
        """)
        files["OPS/two.xhtml"] = page("Two", "<h1>Second Chapter</h1>\(filler)")
        files["OPS/three.xhtml"] = page("Three", """
        <h1>Third Chapter</h1><p>Gamma carries findneedle four here.</p>
        <table><tr><td>Plain cell</td><td>Cell holding findneedle five inside</td></tr></table>\(filler)
        <p id="last">Omega ends with findneedle six.</p>
        """)
        return try Fixture.archive(files)
    }

    private func results(in events: [EPUBReaderEvent]) -> [EPUBSearchResults?] {
        events.compactMap { if case .searchResultsChanged(let results) = $0 { return .some(results) }; return nil }
    }

    private func isVisible(_ index: Int, in session: NativeSession) -> Bool {
        guard let visible = session.visibleRange, session.searchResultRanges.indices.contains(index) else { return false }
        let start = session.searchResultRanges[index].start
        return visible.start <= start && start < visible.end
    }

    func testResultsListEveryRenderedMatchInSpineOrderWithSectionAndContext() async throws {
        let (session, window, events) = try open(Self.book())
        defer { session.close(); window.close() }
        try await wait("ready and location") { events().contains(.ready) && session.lastLocation != nil }
        XCTAssertTrue(session.capabilities.contains(.searchResults))
        XCTAssertNil(session.readerState?.status.searchResults)

        try await session.send(.search(text: "Findneedle"))
        let state = try XCTUnwrap(session.readerState)
        let found = try XCTUnwrap(state.status.searchResults)
        XCTAssertEqual(state.status.search, .completed(query: "Findneedle", hasMatches: true))
        XCTAssertEqual(found.query, "Findneedle")
        XCTAssertEqual(found.count, 6, "six rendered occurrences; the hidden one is not a result")
        XCTAssertFalse(found.isTruncated)
        XCTAssertEqual(found.results.map(\.index), Array(0..<6))
        XCTAssertEqual(found.results.map(\.spineIndex), [0, 0, 0, 2, 2, 2], "spine order, then document order")
        XCTAssertEqual(found.results.map(\.location.href), ["OPS/one.xhtml", "OPS/one.xhtml", "OPS/one.xhtml",
                                                           "OPS/three.xhtml", "OPS/three.xhtml", "OPS/three.xhtml"])
        XCTAssertEqual(found.results.map(\.sectionTitle), ["First Chapter", "Later Part", "Later Part",
                                                          "Third Chapter", "Third Chapter", "Third Chapter"])
        XCTAssertEqual(found.results.map(\.location.title), found.results.map(\.sectionTitle))
        XCTAssertEqual(found.results.map(\.matchedText), ["findneedle", "FINDNEEDLE", "findnéedle", "findneedle", "findneedle", "findneedle"])
        XCTAssertEqual(found.results.map(\.location.quote), found.results.map { Optional($0.matchedText) })
        XCTAssertEqual(found.results.map(\.location.page?.label), ["1", "2", "2", "2", "2", "3"])
        XCTAssertTrue(found.results.allSatisfy { $0.location.publicationID == session.publication.id })

        XCTAssertEqual(found.results[0].contextBefore, "Alpha comes before ")
        XCTAssertEqual(found.results[0].contextAfter, " one, then more.")
        XCTAssertEqual(found.results[1].contextBefore, "Beta has ", "context stays within the occurrence's paragraph")
        XCTAssertEqual(found.results[1].contextAfter, " two and findnéedle three close together.")
        XCTAssertEqual(found.results[2].contextBefore, "Beta has FINDNEEDLE two and ")
        XCTAssertEqual(found.results[2].contextAfter, " three close together.")
        XCTAssertEqual(found.results[3].snippet, "Gamma carries findneedle four here.")
        XCTAssertEqual(found.results[4].contextBefore, "Cell holding ")
        XCTAssertEqual(found.results[4].contextAfter, " five inside")
        XCTAssertEqual(found.results[5].snippet, "Omega ends with findneedle six.")
        XCTAssertEqual(found.results[1].snippet, found.results[2].snippet, "two occurrences in one paragraph share its text")
        XCTAssertEqual(Set(found.results.map { [$0.contextBefore, $0.matchedText, $0.contextAfter] }).count, 6,
                       "where the occurrence falls in its context tells every one apart")

        // Results precede completion, and each drawn match is one result's range.
        let all = events()
        let published = try XCTUnwrap(all.firstIndex(of: .searchResultsChanged(found)))
        let completed = try XCTUnwrap(all.firstIndex(of: .searchChanged(.completed(query: "Findneedle", hasMatches: true))))
        XCTAssertLessThan(published, completed)
        try await wait("every match drawn") { session.drawnHighlights.filter { $0.kind == .search }.count == 6 }
        XCTAssertEqual(session.drawnHighlights.filter { $0.kind == .search }.map(\.range).sorted { $0.start < $1.start },
                       session.searchResultRanges)

        // `.search` opens the first result and makes it current; its bookmark names the occurrence.
        XCTAssertEqual(found.currentIndex, 0)
        try await wait("first result visible") { self.isVisible(0, in: session) }
        XCTAssertEqual(session.drawnHighlights.filter { $0.kind == .currentSearch }.map(\.range), [session.searchResultRanges[0]])
        for result in found.results {
            let bookmark = try XCTUnwrap(result.location.bookmark)
            XCTAssertEqual(bookmark.engineID, EPUBReader.identifier)
            XCTAssertEqual(bookmark.format, EPUBReader.bookmarkFormat)
        }
        try await session.send(.setHighlights([EPUBHighlight(id: "saved", location: found.results[5].location)]))
        try await wait("result location drawn as a host highlight") { session.drawnHighlights.contains { $0.id == "saved" } }
        XCTAssertEqual(session.drawnHighlights.first { $0.id == "saved" }?.range, session.searchResultRanges[5])
        try await session.send(.restore(found.results[3].location))
        try await wait("result location restored") { session.visibleRange?.start.section == 2 }
        XCTAssertEqual(session.readerState?.status.searchResults?.currentIndex, 0, "restoring elsewhere leaves the current match")
    }

    func testHighlightOnlyCommandListsResultsWithoutACurrentMatch() async throws {
        let (session, window, events) = try open(Self.book())
        defer { session.close(); window.close() }
        try await wait("ready and location") { events().contains(.ready) && session.lastLocation != nil }
        let original = session.visibleRange
        try await session.send(.searchHighlight(text: "findneedle"))
        let found = try XCTUnwrap(session.readerState?.status.searchResults)
        XCTAssertEqual(found.count, 6)
        XCTAssertNil(found.currentIndex)
        XCTAssertNil(found.current)
        XCTAssertEqual(session.visibleRange, original, "the highlight-only command keeps its position")
        XCTAssertTrue(session.drawnHighlights.filter { $0.kind == .currentSearch }.isEmpty)
        try await session.send(.previousSearchResult)
        XCTAssertEqual(session.readerState?.status.searchResults?.currentIndex, 5, "with no current match, previous shows the last")
        try await wait("last result visible") { self.isVisible(5, in: session) }
        try await session.send(.searchHighlight(text: "findneedle"))
        XCTAssertNil(session.readerState?.status.searchResults?.currentIndex)
        try await session.send(.nextSearchResult)
        XCTAssertEqual(session.readerState?.status.searchResults?.currentIndex, 0, "with no current match, next shows the first")
    }

    func testSteppingAndSelectingShowTheMatchInBothFlows() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let (session, window, events) = try open(Self.book())
            defer { session.close(); window.close() }
            try await wait("built book and location") { session.book.isComplete && session.lastLocation != nil }
            try await session.send(.style(.init(flow: flow)))
            try await session.send(.search(text: "findneedle"))
            let state = try XCTUnwrap(session.readerState)
            let found = try XCTUnwrap(state.status.searchResults)
            XCTAssertEqual(found.count, 6)
            func current() -> Int? { state.status.searchResults?.currentIndex }
            func expectShown(_ index: Int, _ label: String) async throws {
                XCTAssertEqual(current(), index, "\(label) in \(flow)")
                try await wait("\(label) visible in \(flow)") { self.isVisible(index, in: session) }
                XCTAssertEqual(session.drawnHighlights.filter { $0.kind == .currentSearch }.map(\.range),
                               [session.searchResultRanges[index]], "\(label) is the one emphasized match")
                XCTAssertEqual(session.drawnHighlights.filter { $0.kind == .search }.count, 6, "every match stays highlighted")
                XCTAssertNil(session.selection, "showing a match selects nothing")
            }
            try await expectShown(0, "first result")
            for index in 1..<6 {
                try await session.send(.nextSearchResult)
                try await expectShown(index, "next result \(index)")
            }
            XCTAssertEqual(state.status.searchResults?.isAtLast, true)
            try await session.send(.nextSearchResult)
            try await expectShown(0, "wrap from the last result to the first")
            XCTAssertEqual(state.status.searchResults?.isAtFirst, true)
            try await session.send(.previousSearchResult)
            try await expectShown(5, "wrap from the first result to the last")
            try await session.send(.previousSearchResult)
            try await expectShown(4, "previous result in a table cell")
            try await session.send(.showSearchResult(found.results[1]))
            try await expectShown(1, "selected result")
            try await session.send(.showSearchResult(found.results[3]))
            try await expectShown(3, "selected result in another document")
            XCTAssertEqual(session.visibleRange?.start.section, 2)
            XCTAssertEqual(results(in: events()).last, state.status.searchResults, "every change of the current match is reported")
            XCTAssertEqual(state.status.search, .completed(query: "findneedle", hasMatches: true))
        }
    }

    func testCurrentMatchSurvivesPageNavigationStyleAndRemount() async throws {
        let (session, window, events) = try open(Self.book())
        defer { session.close(); window.close() }
        try await wait("built book and location") { session.book.isComplete && session.lastLocation != nil }
        try await session.send(.search(text: "findneedle"))
        let state = try XCTUnwrap(session.readerState)
        let found = try XCTUnwrap(state.status.searchResults)
        try await session.send(.nextSearchResult)
        XCTAssertEqual(state.status.searchResults?.currentIndex, 1)
        let reports = results(in: events()).count

        try await session.send(.nextPage)
        try await session.send(.nextPage)
        try await session.send(.navigate(href: "OPS/three.xhtml"))
        try await wait("third document") { session.visibleRange?.start.section == 2 }
        try await session.send(.style(.init(fontSize: 22, flow: .scrolled)))
        try await wait("rebuilt book") { session.book.isComplete && session.book.typography.fontSize == 22 }
        try await session.send(.previousPage)
        var expected = found
        expected.currentIndex = 1
        XCTAssertEqual(state.status.searchResults, expected, "page turns, navigation, typography and flow leave the results alone")
        XCTAssertEqual(results(in: events()).count, reports, "and report no change")
        XCTAssertEqual(session.drawnHighlights.filter { $0.kind == .currentSearch }.map(\.range), [session.searchResultRanges[1]])

        // Stepping continues from the match last shown, not from the visible page.
        try await session.send(.nextSearchResult)
        XCTAssertEqual(state.status.searchResults?.currentIndex, 2)
        try await wait("result after the current match") { self.isVisible(2, in: session) }
        XCTAssertEqual(session.visibleRange?.start.section, 0)

        // A new view for the same session keeps the query's results and current match.
        window.close()
        let second = ReaderTestWindow(session: session)
        defer { second.close() }
        try await wait("remounted") { session.canvas != nil && state.status.lifecycle == .ready }
        XCTAssertEqual(state.status.searchResults?.currentIndex, 2)
        XCTAssertEqual(state.status.search, .completed(query: "findneedle", hasMatches: true))
        XCTAssertEqual(session.drawnHighlights.filter { $0.kind == .currentSearch }.map(\.range), [session.searchResultRanges[2]])
        try await session.send(.nextSearchResult)
        XCTAssertEqual(state.status.searchResults?.currentIndex, 3)
        try await wait("next result after remount") { self.isVisible(3, in: session) }
    }

    func testClearReplaceFailureLocateAndCloseInvalidateResultsAndSuppressNavigation() async throws {
        let (session, window, events) = try open(Self.book())
        defer { session.close(); window.close() }
        try await wait("built book and location") { session.book.isComplete && session.lastLocation != nil }
        let state = try XCTUnwrap(session.readerState)
        func search(_ text: String) async throws -> EPUBSearchResults {
            try await session.send(.search(text: text))
            return try XCTUnwrap(state.status.searchResults)
        }
        func expectNoNavigation(_ label: String, _ command: EPUBReaderCommand, throwing: Bool) async throws {
            let before = session.visibleRange, count = events().count
            do {
                try await session.send(command)
                XCTAssertFalse(throwing, "\(label): the stale result was accepted")
            } catch { XCTAssertEqual(error as? EPUBReaderError, .invalidCommand("That search result is no longer available"), label) }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(session.visibleRange, before, "\(label): stale navigation moved the reader")
            XCTAssertNil(state.status.searchResults?.currentIndex, "\(label): a current match appeared")
            XCTAssertEqual(events().count, count, "\(label): events after a suppressed command")
            XCTAssertEqual(state.status.activeCommands, 0)
        }

        // Clear.
        let first = try await search("findneedle")
        try await session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait("second document") { session.visibleRange?.start.section == 1 }
        try await session.send(.clearSearch)
        XCTAssertNil(state.status.searchResults)
        XCTAssertEqual(state.status.search, .idle)
        XCTAssertEqual(results(in: events()).last, .some(nil), "withdrawal is reported")
        XCTAssertTrue(session.drawnHighlights.isEmpty)
        try await expectNoNavigation("next after clear", .nextSearchResult, throwing: false)
        try await expectNoNavigation("previous after clear", .previousSearchResult, throwing: false)
        try await expectNoNavigation("result after clear", .showSearchResult(first.results[4]), throwing: true)

        // Replace: the old query's results are refused, the new query's are accepted.
        _ = try await search("findneedle")
        let replaced = try await search("Gamma carries")
        XCTAssertEqual(replaced.query, "Gamma carries")
        XCTAssertEqual(replaced.count, 1)
        XCTAssertEqual(replaced.currentIndex, 0)
        do { try await session.send(.showSearchResult(first.results[4])); XCTFail("A replaced query's result was accepted") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .invalidCommand("That search result is no longer available")) }
        var outOfRange = replaced.results[0]
        outOfRange.index = 1
        do { try await session.send(.showSearchResult(outOfRange)); XCTFail("An unlisted result was accepted") }
        catch { XCTAssertEqual(error as? EPUBReaderError, .invalidCommand("That search result is no longer available")) }
        XCTAssertEqual(state.status.searchResults, replaced)
        try await session.send(.showSearchResult(replaced.results[0]))
        try await session.send(.nextSearchResult)
        XCTAssertEqual(state.status.searchResults?.currentIndex, 0, "a single result stays current")

        // A rejected query.
        do { try await session.send(.search(text: String(repeating: "x", count: 513))); XCTFail("Invalid query accepted") }
        catch { guard case .failed = state.status.search else { return XCTFail("No search error feedback") } }
        XCTAssertNil(state.status.searchResults)
        XCTAssertTrue(session.drawnHighlights.filter { $0.kind == .currentSearch }.isEmpty)
        try await session.send(.navigate(href: "OPS/two.xhtml"))
        try await wait("second document") { session.visibleRange?.start.section == 1 }
        try await expectNoNavigation("next after a failed query", .nextSearchResult, throwing: false)
        try await expectNoNavigation("result after a failed query", .showSearchResult(replaced.results[0]), throwing: true)

        // Locating a passage clears search.
        let located = try await search("findneedle")
        try await session.send(.locate(text: "Second Chapter", highlight: false))
        XCTAssertNil(state.status.searchResults)
        XCTAssertEqual(state.status.search, .idle)
        try await expectNoNavigation("next after locate", .nextSearchResult, throwing: false)

        // No matches is a completed search with an empty list.
        let none = try await search("absent unicorn")
        XCTAssertEqual(state.status.search, .completed(query: "absent unicorn", hasMatches: false))
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(none.currentIndex)
        try await expectNoNavigation("next with no matches", .nextSearchResult, throwing: false)
        let hidden = try await search("hidden from every reader")
        XCTAssertTrue(hidden.isEmpty, "a match that renders nothing is not a result")
        XCTAssertEqual(state.status.search, .completed(query: "hidden from every reader", hasMatches: false))

        // Close.
        _ = try await search("findneedle")
        let count = events().count
        session.close()
        XCTAssertNil(state.status.searchResults)
        XCTAssertNil(session.searchResults)
        for command in [EPUBReaderCommand.nextSearchResult, .previousSearchResult, .showSearchResult(located.results[0])] {
            do { try await session.send(command); XCTFail("Closed session accepted \(command)") }
            catch { XCTAssertEqual(error as? EPUBReaderError, .closed) }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events().count, count, "no callbacks after close")
    }

    func testSupersededAndCanceledSearchesPublishNoResults() async throws {
        // A clear submitted while the search is pending wins: no results, no navigation.
        var retained: NativeSession?
        var clear: Task<Void, Error>?
        let (session, window, events) = try open(Self.book(), onEvent: { event in
            if event == .searchChanged(.searching(query: "findneedle")) { clear = Task { try await retained?.send(.clearSearch) } }
        })
        retained = session
        defer { session.close(); window.close() }
        try await wait("ready and location") { events().contains(.ready) && session.lastLocation != nil }
        let state = try XCTUnwrap(session.readerState)
        try await session.send(.search(text: "Gamma carries"))
        XCTAssertEqual(state.status.searchResults?.count, 1)
        try await session.send(.navigate(href: "OPS/one.xhtml"))
        try await wait("first document") { session.visibleRange?.start.section == 0 }
        let original = session.visibleRange
        let reported = results(in: events()).count
        try await session.send(.search(text: "findneedle"))
        try await clear?.value
        XCTAssertNil(state.status.searchResults)
        XCTAssertEqual(state.status.search, .idle)
        XCTAssertEqual(results(in: events()).dropFirst(reported).map { $0 == nil }, [true],
                       "the replaced query's results are withdrawn once; the superseded search publishes none")
        XCTAssertEqual(session.visibleRange, original)
        try await session.send(.nextSearchResult)
        XCTAssertEqual(session.visibleRange, original, "a step after the clear finds nothing to show")

        // Cancellation.
        var search: Task<Void, Error>?
        let (second, secondWindow, secondEvents) = try open(Self.book(), onEvent: { event in
            if case .searchChanged(.searching) = event { search?.cancel() }
        })
        defer { second.close(); secondWindow.close() }
        try await wait("ready") { secondEvents().contains(.ready) }
        search = Task { try await second.send(.search(text: "findneedle")) }
        do { try await search?.value; XCTFail("Canceled search completed") } catch is CancellationError {}
        XCTAssertNil(second.readerState?.status.searchResults)
        XCTAssertEqual(second.readerState?.status.search, .idle)
        XCTAssertTrue(results(in: secondEvents()).isEmpty)
        let before = second.visibleRange
        try await second.send(.nextSearchResult)
        XCTAssertEqual(second.visibleRange, before)
    }

    func testNewerNavigationLeavesResultsWithoutACurrentMatch() async throws {
        var retained: NativeSession?
        var navigation: Task<Void, Error>?
        let (session, window, events) = try open(Self.book(), onEvent: { event in
            if case .searchChanged(.searching) = event {
                navigation = Task { try await retained?.send(.navigate(href: "OPS/two.xhtml")) }
            }
        })
        retained = session
        defer { session.close(); window.close() }
        try await wait("ready and location") { events().contains(.ready) && session.lastLocation != nil }
        try await session.send(.search(text: "findneedle"))
        try await navigation?.value
        let found = try XCTUnwrap(session.readerState?.status.searchResults)
        XCTAssertEqual(found.count, 6)
        XCTAssertNil(found.currentIndex, "the search did not move the reader, so no match is current")
        XCTAssertEqual(session.visibleRange?.start.section, 1)
        XCTAssertTrue(session.drawnHighlights.filter { $0.kind == .currentSearch }.isEmpty)
        try await session.send(.nextSearchResult)
        XCTAssertEqual(session.readerState?.status.searchResults?.currentIndex, 0)
        try await wait("first result visible") { self.isVisible(0, in: session) }
    }

    func testResultListIsBoundedAndSaysSo() async throws {
        let (session, window, events) = try open(Self.book())
        defer { session.close(); window.close() }
        try await wait("ready and location") { events().contains(.ready) && session.lastLocation != nil }
        session.maximumSearchResults = 4
        try await session.send(.search(text: "findneedle"))
        let found = try XCTUnwrap(session.readerState?.status.searchResults)
        XCTAssertEqual(found.count, 4)
        XCTAssertTrue(found.isTruncated)
        XCTAssertEqual(found.results.map(\.spineIndex), [0, 0, 0, 2])
        try await wait("every match still drawn") { session.drawnHighlights.filter { $0.kind == .search }.count == 6 }
        try await session.send(.previousSearchResult)
        XCTAssertEqual(session.readerState?.status.searchResults?.currentIndex, 3, "stepping stays within the listed results")
        try await session.send(.nextSearchResult)
        XCTAssertEqual(session.readerState?.status.searchResults?.currentIndex, 0)

        session.maximumSearchResults = 3
        try await session.send(.search(text: "findneedle"))
        let exact = try XCTUnwrap(session.readerState?.status.searchResults)
        XCTAssertEqual(exact.count, 3)
        XCTAssertTrue(exact.isTruncated, "matches in a later document are not listed")
        session.maximumSearchResults = 6
        try await session.send(.search(text: "findneedle"))
        XCTAssertEqual(session.readerState?.status.searchResults?.isTruncated, false, "exactly at the bound is complete")
    }

    func testMatchStepsAreLogicalInARightToLeftBook() async throws {
        for flow in [EPUBReadingFlow.paginated, .scrolled] {
            let (session, window, events) = try open(Fixture.rendering(.rightToLeft))
            defer { session.close(); window.close() }
            XCTAssertEqual(session.publication.pageProgression, .rtl)
            try await wait("built book and location") { session.book.isComplete && session.lastLocation != nil && events().contains(.ready) }
            try await session.send(.style(.init(flow: flow)))
            try await session.send(.search(text: "القراءة"))
            let state = try XCTUnwrap(session.readerState)
            let found = try XCTUnwrap(state.status.searchResults)
            XCTAssertEqual(found.count, 100)
            XCTAssertEqual(found.results.map(\.spineIndex), Array(repeating: 0, count: 50) + Array(repeating: 1, count: 50))
            XCTAssertEqual(session.searchResultRanges.map(\.start), session.searchResultRanges.map(\.start).sorted(),
                           "result order is reading order, whatever the page direction")
            XCTAssertEqual(found.currentIndex, 0)
            // A page turn is not a match step, and a match step is not a page turn.
            try await session.send(.nextPage)
            XCTAssertEqual(state.status.searchResults?.currentIndex, 0)
            try await session.send(.nextSearchResult)
            XCTAssertEqual(state.status.searchResults?.currentIndex, 1)
            try await wait("second result visible in \(flow)") { self.isVisible(1, in: session) }
            try await session.send(.previousSearchResult)
            try await session.send(.previousSearchResult)
            XCTAssertEqual(state.status.searchResults?.currentIndex, 99, "previous from the first result is the last, in the last document")
            try await wait("last result visible in \(flow)") { self.isVisible(99, in: session) }
            XCTAssertEqual(session.visibleRange?.start.section, 1)
        }
    }

    /// How far down continuous scroll the line holding a result stands: its top's distance from
    /// the top of the visible area, as a share of the area's height. `line` is the line's own
    /// height as the same share.
    private func depth(of index: Int, in session: NativeSession) throws -> CGFloat { try placement(of: index, in: session).depth }

    private func placement(of index: Int, in session: NativeSession) throws -> (depth: CGFloat, line: CGFloat) {
        let canvas = try XCTUnwrap(session.canvas)
        let view = try XCTUnwrap(canvas.scrollTextView)
        let book = try XCTUnwrap(canvas.scrollBook, "the whole book is in the scroll view")
        let line = try XCTUnwrap(view.lineFrame(containing: book.location(of: session.searchResultRanges[index].start)))
        let visible = canvas.scrollVisibleContainerRect
        return ((line.minY - visible.minY) / visible.height, line.height / visible.height)
    }

    /// A match shown in continuous scroll rests about a third of the way down the view, with the
    /// text before it above, and not at the top: there a match was a line above the view after
    /// the search sheet closed on an iPhone, and a toolbar's popover hangs over it (#49). A
    /// change of height leaves it on screen. A match in a section's first lines has the
    /// section's start at the top, so the location stays in its section.
    func testAShownMatchRestsAThirdOfTheWayDownInContinuousScroll() async throws {
        let (session, window, _) = try open(Self.book())
        defer { session.close(); window.close() }
        try await wait("built book and location") { session.book.isComplete && session.lastLocation != nil }
        try await session.send(.style(.init(flow: .scrolled)))
        try await wait("the whole book in the scroll view") { session.canvas?.scrollBook != nil }
        try await session.send(.search(text: "findneedle"))
        let state = try XCTUnwrap(session.readerState)
        // The first match is the second paragraph of its section.
        try await wait("first result visible") { self.isVisible(0, in: session) }
        XCTAssertEqual(session.visibleRange?.start, ReaderTextPosition(section: 0, offset: 0), "the section's start is at the top")
        XCTAssertLessThan(try depth(of: 0, in: session), 0.3)
        // The second and third are sixty paragraphs into the same section.
        for index in [1, 2] {
            try await session.send(.nextSearchResult)
            XCTAssertEqual(state.status.searchResults?.currentIndex, index)
            try await wait("result \(index) visible") { self.isVisible(index, in: session) }
            // The line at the top is the first mostly below a third of the view above the match.
            let placed = try placement(of: index, in: session)
            XCTAssertEqual(placed.depth, 1.0 / 3, accuracy: placed.line, "result \(index) is \(placed.depth) of the way down")
            XCTAssertEqual(session.visibleRange?.start.section, 0)
        }
        // A sheet and its keyboard made the reader shorter and gave its height back.
        let size = window.window.frame.size
        for height in [size.height * 0.55, size.height] {
            window.resize(to: CGSize(width: size.width, height: height))
            try await Task.sleep(for: .milliseconds(300))
            try await wait("result 2 on screen at \(Int(height)) points") { self.isVisible(2, in: session) }
            XCTAssertGreaterThanOrEqual(try depth(of: 2, in: session), 0, "result 2 is below the top at \(Int(height)) points")
        }
        let again = try placement(of: 2, in: session)
        XCTAssertEqual(again.depth, 1.0 / 3, accuracy: again.line, "result 2 is a third of the way down again")
        // The fourth opens the third section.
        try await session.send(.nextSearchResult)
        try await wait("result 3 visible") { self.isVisible(3, in: session) }
        XCTAssertEqual(session.visibleRange?.start, ReaderTextPosition(section: 2, offset: 0))
    }

    #if os(iOS)
    /// The keyboard a search field raises covers the foot of the reader and does not make it
    /// shorter. Made shorter, the reader laid the book out again as the keyboard rose and again
    /// as a search put it away, and on an iPad one column became two and back (#49).
    func testTheReaderKeepsItsSizeUnderTheKeyboard() async throws {
        let publication = try EPUBPublication.open(data: Self.book())
        let session = try XCTUnwrap(try NativeEngine().makeSession(publication: publication, selectionAction: nil) { _ in } as? NativeSession)
        let field = UITextField()
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        window.rootViewController = UIHostingController(rootView: EPUBReaderView(session: session))
        window.makeKeyAndVisible()
        defer { field.resignFirstResponder(); session.close(); window.isHidden = true; window.rootViewController = nil }
        try await wait("built book and location") { session.book.isComplete && session.lastLocation != nil }
        let canvas = try XCTUnwrap(session.canvas)
        let before = canvas.convert(canvas.bounds, to: window)
        let spread = canvas.spread
        field.frame = CGRect(x: 0, y: 80, width: 200, height: 32)
        window.addSubview(field)
        let guide = window.keyboardLayoutGuide
        func keyboard() -> CGRect {
            window.layoutIfNeeded()
            return guide.layoutFrame
        }
        XCTAssertTrue(field.becomeFirstResponder())
        try await wait("the keyboard", timeout: 10) { keyboard().height > 100 }
        XCTAssertTrue(keyboard().intersects(before), "the keyboard \(keyboard()) is over the reader \(before)")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(canvas.convert(canvas.bounds, to: window), before, "the reader kept its frame under the keyboard")
        XCTAssertEqual(canvas.spread, spread, "and its pages")
    }
    #endif
}
