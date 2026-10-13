import EPUBCore
import EPUBReading
import EPUBViewing
import Foundation

/// Reusable, toolkit-independent checks. Link this product to an adapter's test target.
/// Use a two-section publication and mount the supplied session in a real visible test window.
@MainActor public enum EPUBEngineContract {
    public struct Failure: LocalizedError, CustomStringConvertible {
        public let description: String
        public var errorDescription: String? { description }
    }

    // TEMPORARY, for the probe at the end of EngineContractTests.swift: which of the search
    // check's three fixed waits get a yield before them and 20 ms after. Not for main.
    public static var probeTreated: Set<Int> = []
    /// Called with a wait's number at the moment its 150 ms ends.
    public static var probeEnded: ((Int) -> Void)?

    /// Tests lifecycle, advertised commands, cancellation, location identity and bookmark restoration.
    /// Rendering fidelity, input gestures and resource release require adapter-specific tests.
    /// The mount closure returns cleanup; it must retain its window until cleanup runs.
    public static func verify(
        engine: any EPUBReaderEngine, publication: EPUBPublication,
        firstHref: String, secondHref: String, text: String,
        timeout: TimeInterval = 20,
        mount: (any EPUBReaderSession) throws -> (@MainActor () -> Void)
    ) async throws {
        var events: [EPUBReaderEvent] = []
        let session = try engine.makeSession(publication: publication, selectionAction: nil) { events.append($0) }
        defer { session.close() }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        try require(timeout.isFinite && timeout > 0, "Timeout must be positive and finite")
        try require(firstHref != secondHref && publication.spine.contains { $0.resource.href == firstHref }
            && publication.spine.contains { $0.resource.href == secondHref }, "Provide two distinct spine resource hrefs")
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if let failure = events.compactMap({ event -> EPUBReaderError? in
                    if case .failed(let error) = event { return error }; return nil
                }).first { throw Failure(description: "Engine failed: \(failure)") }
                guard Date() < deadline else { throw Failure(description: "Timed out waiting for \(label)") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func expect(_ command: EPUBReaderCommand, error expected: EPUBReaderError) async throws {
            do { try await session.send(command) }
            catch let error as EPUBReaderError {
                try require(error == expected, "Expected \(expected), received \(error)")
                return
            }
            throw Failure(description: "Accepted command that should throw \(expected)")
        }
        func locations(since index: Int = 0) -> [EPUBLocation] {
            events.dropFirst(index).compactMap {
                if case .relocated(let location) = $0 { return location }; return nil
            }
        }
        /// An engine advertising `.searchResults` lists `text`'s occurrences before it reports the
        /// search complete, steps and selects as `EPUBSearchResults.steppedIndex` says, mirrors the
        /// results in `readerState` when it has one, and withdraws them when the search is cleared,
        /// after which a kept result is refused and no step moves the reader.
        func verifySearchResults(unlisted: EPUBSearchResult) async throws {
            func published(since index: Int) -> [EPUBSearchResults?] {
                events.dropFirst(index).compactMap { if case .searchResultsChanged(let results) = $0 { return .some(results) }; return nil }
            }
            func isCompletion(_ event: EPUBReaderEvent) -> Bool {
                if case .searchChanged(.completed) = event { return true }; return false
            }
            func refused(_ command: EPUBReaderCommand, _ message: String) async throws {
                do { try await session.send(command) }
                catch EPUBReaderError.invalidCommand { return }
                throw Failure(description: message)
            }
            // TEMPORARY, for the probe: one of the three fixed waits, as it is or treated.
            func pause(_ number: Int) async throws {
                let treated = EPUBEngineContract.probeTreated.contains(number)
                if treated { await Task.yield() }
                try await Task.sleep(for: .milliseconds(150))
                EPUBEngineContract.probeEnded?(number)
                if treated { try await Task.sleep(for: .milliseconds(20)) }
            }
            let navigates = session.capabilities.contains(.search)
            try require(navigates || session.capabilities.contains(.searchHighlight), "Search results need a search command")
            try await refused(.showSearchResult(unlisted), "Accepted a search result with no search")

            let start = events.count
            try await session.send(navigates ? .search(text: text) : .searchHighlight(text: text))
            try await wait("search completion") { events.dropFirst(start).contains(where: isCompletion) }
            let completion = events.dropFirst(start).firstIndex(where: isCompletion)!
            guard let listed = published(since: start).compactMap({ $0 }).last else {
                throw Failure(description: "Search completed without publishing results")
            }
            let firstPublished = events.dropFirst(start).firstIndex {
                if case .searchResultsChanged(.some) = $0 { return true }; return false
            }
            try require(firstPublished.map { $0 < completion } ?? false, "Results must be published before search completion")
            try require(!listed.isEmpty, "The supplied text must have at least one search result")
            try require(listed.query == text, "Results name another query")
            try require(listed.results.map(\.index) == Array(listed.results.indices), "Result indices must match their order")
            try require(listed.results.allSatisfy { $0.location.publicationID == publication.id }, "Result belongs to another publication")
            try require(listed.currentIndex.map(listed.results.indices.contains) ?? true, "Current match is not a listed result")
            func current() -> Int? { published(since: start).last.flatMap { $0 }?.currentIndex }

            var expected = listed.steppedIndex(forward: true)
            try await session.send(.nextSearchResult)
            try await wait("next search result") { current() == expected }
            try await session.send(.showSearchResult(listed.results[0]))
            try await wait("selected search result") { current() == 0 }
            var selected = listed
            selected.currentIndex = 0
            expected = selected.steppedIndex(forward: false)
            try await session.send(.previousSearchResult)
            try await wait("previous search result") { current() == expected }
            var stale = listed.results[0]
            stale.index = listed.count
            try await refused(.showSearchResult(stale), "Accepted a search result that is not listed")
            if let state = session.readerState {
                try require(state.status.searchResults == published(since: start).last.flatMap { $0 },
                            "Reader state does not mirror the published search results")
            }

            guard session.capabilities.contains(.searchHighlight) else { return }
            // Let the last step's relocation arrive before judging what a stale command does.
            try await pause(1)
            let cleared = events.count
            try await session.send(.clearSearch)
            try await wait("withdrawn search results") { published(since: cleared).last == .some(nil) }
            if let state = session.readerState {
                try require(state.status.searchResults == nil, "Reader state kept cleared search results")
            }
            try await pause(2)
            let quiet = events.count
            try await session.send(.nextSearchResult)
            try await session.send(.previousSearchResult)
            try await refused(.showSearchResult(listed.results[0]), "Accepted a result of a cleared search")
            try await pause(3)
            try require(events.count == quiet, "A step or result of a cleared search still had an effect")
        }
        let cancelled = Task { try await session.send(.nextPage) }
        cancelled.cancel()
        do { try await cancelled.value; throw Failure(description: "Pre-cancelled command was accepted") }
        catch is CancellationError {}
        let unmount = try mount(session)
        defer { unmount() }
        try await wait("ready") { events.contains(.ready) }
        if session.capabilities.contains(.navigateHref) {
            try await session.send(.navigate(href: firstHref))
            try await wait("first href") { locations().last?.href == firstHref }
            let saved = locations().last!
            try require(saved.publicationID == publication.id, "Wrong publication identity")
            let secondStart = events.count
            try await session.send(.navigate(href: secondHref))
            try await wait("second href") { locations(since: secondStart).contains { $0.href == secondHref } }
            if session.capabilities.contains(.bookmarks) {
                try require(saved.bookmark?.engineID == engine.id, "Missing or wrong bookmark engine identity")
                let restoreStart = events.count
                try await session.send(.restore(saved))
                try await wait("restoration") { locations(since: restoreStart).contains { $0.href == saved.href } }
                var foreign = saved
                foreign.publicationID += "-different"
                try await expect(.restore(foreign), error: .incompatibleLocation)
                foreign = saved; foreign.bookmark?.engineID += "-different"
                try await expect(.restore(foreign), error: .incompatibleLocation)
                foreign = saved; foreign.bookmark?.format += "-different"
                try await expect(.restore(foreign), error: .incompatibleLocation)
            }
        }
        if !session.capabilities.contains(.bookmarks) {
            try await expect(.restore(.init(publicationID: publication.id)), error: .unsupported(.bookmarks))
        } else {
            try await wait("bookmark") { locations().contains { $0.bookmark != nil } }
            for location in locations() {
                try require(location.publicationID == publication.id, "Location belongs to another publication")
                if let bookmark = location.bookmark {
                    try require(bookmark.engineID == engine.id && !bookmark.format.isEmpty && !bookmark.value.isEmpty,
                                "Invalid engine bookmark")
                }
            }
        }
        let commands: [(EPUBReaderCapability, EPUBReaderCommand)] = [
            (.pagination, .nextPage), (.pagination, .previousPage),
            (.navigateHref, .navigate(href: firstHref)),
            (.locateText, .locate(text: text, highlight: false)),
            (.search, .search(text: text)),
            (.searchHighlight, .searchHighlight(text: text)), (.searchHighlight, .clearSearch),
            // With the search cleared there is nothing to step through: accepted, without effect.
            (.searchResults, .nextSearchResult), (.searchResults, .previousSearchResult),
            (.highlights, .setHighlights([])),
        ]
        for (capability, command) in commands {
            if session.capabilities.contains(capability) { try await session.send(command) }
            else { try await expect(command, error: .unsupported(capability)) }
        }
        let unlisted = EPUBSearchResult(index: 0, location: .init(publicationID: publication.id), spineIndex: 0, matchedText: text)
        if session.capabilities.contains(.searchResults) {
            try await verifySearchResults(unlisted: unlisted)
        } else {
            try await expect(.showSearchResult(unlisted), error: .unsupported(.searchResults))
            try require(!events.contains { if case .searchResultsChanged = $0 { return true }; return false },
                        "Search results published without the capability")
        }
        if session.capabilities.contains(.typography) {
            try await session.send(.style(.init(fontSize: 21)))
        } else { try await expect(.style(.init(fontSize: 21)), error: .unsupported(.typography)) }
        if session.capabilities.contains(.scrolling) {
            try await session.send(.style(.init(flow: .scrolled)))
            try await session.send(.style(.init()))
        } else { try await expect(.style(.init(flow: .scrolled)), error: .unsupported(.scrolling)) }
        try require(!events.contains { if case .failed = $0 { return true }; return false }, "Engine emitted a failure")
        try require(events.filter { $0 == .ready }.count == 1, "Ready must be emitted exactly once")
        let count = events.count
        session.close(); session.close()
        try await expect(.nextPage, error: .closed)
        // The quiet period. The yield lets what the engine queued while closing start first, so
        // that a timer it starts there is due before the 150 ms end. The second sleep is for a
        // callback delivered with that end: two sleeps overdue together resume in either order.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(150))
        try await Task.sleep(for: .milliseconds(20))
        try require(events.count == count, "Callback after close")
    }
}
