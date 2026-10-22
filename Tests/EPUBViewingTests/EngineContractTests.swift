import EPUBCore
import EPUBReading
import EPUBViewing
import EPUBViewingTestSupport
import EPUBTestSupport
import SwiftUI
import XCTest

@MainActor private struct ContractNativeEngine: EPUBReaderEngine {
    enum Fault {
        case none, duplicateReady, noReady, acceptsCancellation, callbackAfterClose, timedCallbackAfterClose, callbackDuringClose
        case acceptsForeignBookmark, failureAfterReady
        // Identity faults: locations that carry the file's hash, and a restore that refuses it (#679).
        case fileIdentity, refusesEarlierIdentity
        // Search-result faults, for an engine with `Search.results`.
        case resultsAfterCompletion, noWrap, acceptsStaleResult, keepsResultsAfterClear, stepsAfterClear, timedStepsAfterClear
    }
    /// What the engine does with search: nothing, highlighting alone, or a result list as well.
    enum Search { case none, highlightOnly, results }
    let id = "contract.native"
    let fault: Fault
    var search = Search.none
    /// Whether a step's relocation and a clear's idle state come 30 ms after their command, from
    /// a timer of the engine's own: a correct engine that reports once its view has settled.
    var reportsLate = false
    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction?,
                     onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        ContractNativeSession(book: publication, fault: fault, search: search, reportsLate: reportsLate, onEvent: onEvent)
    }
}

@MainActor private final class ContractNativeSession: EPUBReaderSession {
    let capabilities: Set<EPUBReaderCapability>
    let book: EPUBPublication
    let fault: ContractNativeEngine.Fault
    let search: ContractNativeEngine.Search
    let reportsLate: Bool
    var onEvent: ((EPUBReaderEvent) -> Void)?
    var closed = false
    var ready = false
    /// One synthetic result per spine document, while a search is complete.
    var results: EPUBSearchResults?
    init(book: EPUBPublication, fault: ContractNativeEngine.Fault, search: ContractNativeEngine.Search,
         reportsLate: Bool, onEvent: @escaping (EPUBReaderEvent) -> Void) {
        self.book = book; self.fault = fault; self.search = search; self.reportsLate = reportsLate; self.onEvent = onEvent
        var capabilities: Set<EPUBReaderCapability> = [.navigateHref, .bookmarks]
        if search != .none { capabilities.insert(.searchHighlight) }
        if search == .results { capabilities.formUnion([.search, .searchResults]) }
        self.capabilities = capabilities
    }
    func makeView() -> AnyView {
        guard !closed else { return AnyView(EmptyView()) }
        if !ready && fault != .noReady {
            ready = true
            onEvent?(.ready)
            if fault == .duplicateReady { onEvent?(.ready) }
            if fault == .failureAfterReady { onEvent?(.failed(.engineFailure("synthetic failure"))) }
        }
        return AnyView(Text(book.metadata.title))
    }
    private func relocate(_ href: String?) {
        guard let href else { return }
        onEvent?(.relocated(.init(publicationID: fault == .fileIdentity ? book.id : book.persistentID, href: href,
            bookmark: .init(engineID: "contract.native", format: "href-v1", value: href))))
    }
    /// Sends 30 ms on, from a timer of the engine's own, which can end together with one of the
    /// verifier's.
    private func later(_ send: @escaping () -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            send()
        }
    }
    private func show(_ index: Int) {
        results?.currentIndex = index
        onEvent?(.searchResultsChanged(results))
        let href = results?.current?.location.href
        if reportsLate { later { self.relocate(href) } } else { relocate(href) }
    }
    private func runSearch(_ text: String, opensFirst: Bool) {
        if results != nil { results = nil; onEvent?(.searchResultsChanged(nil)) }
        onEvent?(.searchChanged(.searching(query: text)))
        guard search == .results else {
            onEvent?(.searchChanged(.completed(query: text, hasMatches: true)))
            return
        }
        let listed = book.spine.enumerated().map { index, item in
            EPUBSearchResult(index: index, location: .init(publicationID: book.persistentID, href: item.resource.href, quote: text),
                             spineIndex: index, sectionTitle: "Section \(index + 1)", matchedText: text)
        }
        results = EPUBSearchResults(query: text, results: listed, currentIndex: opensFirst ? 0 : nil)
        if fault == .resultsAfterCompletion { onEvent?(.searchChanged(.completed(query: text, hasMatches: true))) }
        onEvent?(.searchResultsChanged(results))
        if opensFirst { relocate(listed.first?.location.href) }
        if fault != .resultsAfterCompletion { onEvent?(.searchChanged(.completed(query: text, hasMatches: true))) }
    }
    func send(_ command: EPUBReaderCommand) async throws {
        if fault != .acceptsCancellation { try Task.checkCancellation() }
        else if Task.isCancelled { return }
        guard !closed else { throw EPUBReaderError.closed }
        guard ready else { throw EPUBReaderError.notReady }
        switch command {
        case .navigate(let href): relocate(href)
        case .restore(let location):
            let identities = fault == .refusesEarlierIdentity ? [book.persistentID] : book.publicationIDs
            guard fault == .acceptsForeignBookmark || (identities.contains(location.publicationID) &&
                location.bookmark?.engineID == "contract.native" && location.bookmark?.format == "href-v1") else {
                throw EPUBReaderError.incompatibleLocation
            }
            relocate(location.href)
        case .nextPage, .previousPage: throw EPUBReaderError.unsupported(.pagination)
        case .locate: throw EPUBReaderError.unsupported(.locateText)
        case .search(let text):
            guard search == .results else { throw EPUBReaderError.unsupported(.search) }
            runSearch(text, opensFirst: true)
        case .searchHighlight(let text):
            guard search != .none else { throw EPUBReaderError.unsupported(.searchHighlight) }
            runSearch(text, opensFirst: false)
        case .clearSearch:
            guard search != .none else { throw EPUBReaderError.unsupported(.searchHighlight) }
            if results != nil, fault != .keepsResultsAfterClear, fault != .stepsAfterClear {
                results = nil
                onEvent?(.searchResultsChanged(nil))
            } else if fault == .stepsAfterClear { onEvent?(.searchResultsChanged(nil)) }
            // Reported late, the search is idle unless another has listed its results by then.
            if reportsLate { later { if self.results == nil { self.onEvent?(.searchChanged(.idle)) } } }
            else { onEvent?(.searchChanged(.idle)) }
        case .nextSearchResult, .previousSearchResult:
            guard search == .results else { throw EPUBReaderError.unsupported(.searchResults) }
            guard let results, var index = results.steppedIndex(forward: command == .nextSearchResult) else {
                // With nothing to step through the reader still moves, once the engine's timer ends.
                if fault == .timedStepsAfterClear { later { self.relocate(self.book.spine.first?.resource.href) } }
                return
            }
            if fault == .noWrap, let current = results.currentIndex {
                index = min(max(current + (command == .nextSearchResult ? 1 : -1), 0), results.count - 1)
            }
            show(index)
        case .showSearchResult(let result):
            guard search == .results else { throw EPUBReaderError.unsupported(.searchResults) }
            if fault == .acceptsStaleResult { return relocate(result.location.href) }
            guard let results, results.results.indices.contains(result.index), results.results[result.index] == result else {
                throw EPUBReaderError.invalidCommand("Not a current search result")
            }
            show(result.index)
        case .setHighlights: throw EPUBReaderError.unsupported(.highlights)
        case .style(let style): throw EPUBReaderError.unsupported(style.flow == .scrolled ? .scrolling : .typography)
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        results = nil
        if fault == .callbackDuringClose { onEvent?(.notice("synchronous late callback")) }
        switch fault {
        case .callbackAfterClose:
            // Queued, with no timer: the main actor runs it the first time the verifier waits.
            Task { onEvent?(.notice("late")) }
        case .timedCallbackAfterClose: later { self.onEvent?(.notice("late, from a timer")) }
        default: onEvent = nil
        }
    }
}

@MainActor final class EngineContractTests: XCTestCase {
    private func verify(_ fault: ContractNativeEngine.Fault, search: ContractNativeEngine.Search = .none,
                        reportsLate: Bool = false) async throws {
        try await EPUBEngineContract.verify(engine: ContractNativeEngine(fault: fault, search: search, reportsLate: reportsLate),
            publication: EPUBPublication.open(data: Fixture.epub()), firstHref: "OPS/one.xhtml",
            secondHref: "OPS/two.xhtml", text: "Opening words", timeout: 0.2) { session in
                _ = session.makeView()
                return {}
            }
    }
    func testNativeContractPassesWithoutWebKit() async throws { try await verify(.none) }
    func testContractRejectsBrokenAdapters() async throws {
        for (fault, expected) in [(ContractNativeEngine.Fault.noReady, "Timed out"),
                                 (.duplicateReady, "exactly once"), (.acceptsCancellation, "Pre-cancelled"),
                                 (.callbackAfterClose, "Callback after close"), (.timedCallbackAfterClose, "Callback after close"),
                                 (.callbackDuringClose, "Callback after close"),
                                 (.acceptsForeignBookmark, "incompatibleLocation"), (.failureAfterReady, "failure"),
                                 (.fileIdentity, "Wrong publication identity"), (.refusesEarlierIdentity, "saved under the book's id")] {
            do { try await verify(fault); XCTFail("Broken adapter passed: \(fault)") }
            catch let error as EPUBEngineContract.Failure { XCTAssertTrue(error.description.contains(expected), error.description) }
        }
    }
    /// An engine that only highlights passes without a result model: its result commands must
    /// answer `.unsupported(.searchResults)` and it must publish no results.
    func testHighlightOnlyEnginePassesWithoutSearchResults() async throws {
        try await verify(.none, search: .highlightOnly)
        let book = try EPUBPublication.open(data: Fixture.epub())
        var events: [EPUBReaderEvent] = []
        let session = try ContractNativeEngine(fault: .none, search: .highlightOnly)
            .makeSession(publication: book, selectionAction: nil) { events.append($0) }
        defer { session.close() }
        _ = session.makeView()
        XCTAssertEqual(session.capabilities, [.navigateHref, .bookmarks, .searchHighlight])
        try await session.send(.searchHighlight(text: "Opening words"))
        XCTAssertTrue(events.contains(.searchChanged(.completed(query: "Opening words", hasMatches: true))))
        for command in [EPUBReaderCommand.nextSearchResult, .previousSearchResult,
                        .showSearchResult(.init(index: 0, location: .init(publicationID: book.persistentID), spineIndex: 0, matchedText: "Opening words"))] {
            do { try await session.send(command); XCTFail("Highlight-only engine accepted \(command)") }
            catch { XCTAssertEqual(error as? EPUBReaderError, .unsupported(.searchResults)) }
        }
        XCTAssertFalse(events.contains { if case .searchResultsChanged = $0 { return true }; return false })
    }
    func testContractChecksSearchResults() async throws {
        try await verify(.none, search: .results)
        // What a correct engine sends from a timer of its own is not taken for a stale step's effect.
        try await verify(.none, search: .results, reportsLate: true)
        for (fault, expected) in [(ContractNativeEngine.Fault.resultsAfterCompletion, "before search completion"),
                                 (.noWrap, "previous search result"), (.acceptsStaleResult, "search result"),
                                 (.keepsResultsAfterClear, "withdrawn search results"),
                                 (.stepsAfterClear, "cleared search"), (.timedStepsAfterClear, "still had an effect")] {
            do { try await verify(fault, search: .results); XCTFail("Broken search results passed: \(fault)") }
            catch let error as EPUBEngineContract.Failure { XCTAssertTrue(error.description.contains(expected), "\(fault): \(error.description)") }
        }
    }
}
