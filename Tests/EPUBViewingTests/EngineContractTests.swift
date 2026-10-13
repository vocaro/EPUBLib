import EPUBCore
import EPUBReading
import EPUBViewing
import EPUBViewingTestSupport
import EPUBTestSupport
import SwiftUI
import XCTest

@MainActor private struct ContractNativeEngine: EPUBReaderEngine {
    enum Fault {
        case none, duplicateReady, noReady, acceptsCancellation, callbackAfterClose, callbackDuringClose, acceptsForeignBookmark, failureAfterReady
        // Search-result faults, for an engine with `Search.results`.
        case resultsAfterCompletion, noWrap, acceptsStaleResult, keepsResultsAfterClear, stepsAfterClear
    }
    /// What the engine does with search: nothing, highlighting alone, or a result list as well.
    enum Search { case none, highlightOnly, results }
    let id = "contract.native"
    let fault: Fault
    var search = Search.none
    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction?,
                     onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        ContractNativeSession(book: publication, fault: fault, search: search, onEvent: onEvent)
    }
}

@MainActor private final class ContractNativeSession: EPUBReaderSession {
    let capabilities: Set<EPUBReaderCapability>
    let book: EPUBPublication
    let fault: ContractNativeEngine.Fault
    let search: ContractNativeEngine.Search
    var onEvent: ((EPUBReaderEvent) -> Void)?
    var closed = false
    var ready = false
    /// One synthetic result per spine document, while a search is complete.
    var results: EPUBSearchResults?
    init(book: EPUBPublication, fault: ContractNativeEngine.Fault, search: ContractNativeEngine.Search,
         onEvent: @escaping (EPUBReaderEvent) -> Void) {
        self.book = book; self.fault = fault; self.search = search; self.onEvent = onEvent
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
        onEvent?(.relocated(.init(publicationID: book.id, href: href,
            bookmark: .init(engineID: "contract.native", format: "href-v1", value: href))))
    }
    private func show(_ index: Int) {
        results?.currentIndex = index
        onEvent?(.searchResultsChanged(results))
        relocate(results?.current?.location.href)
    }
    private func runSearch(_ text: String, opensFirst: Bool) {
        if results != nil { results = nil; onEvent?(.searchResultsChanged(nil)) }
        onEvent?(.searchChanged(.searching(query: text)))
        guard search == .results else {
            onEvent?(.searchChanged(.completed(query: text, hasMatches: true)))
            return
        }
        let listed = book.spine.enumerated().map { index, item in
            EPUBSearchResult(index: index, location: .init(publicationID: book.id, href: item.resource.href, quote: text),
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
            guard fault == .acceptsForeignBookmark || (location.publicationID == book.id &&
                location.bookmark?.engineID == "contract.native" && location.bookmark?.format == "href-v1") else {
                throw EPUBReaderError.incompatibleLocation
            }
            onEvent?(.relocated(location))
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
            onEvent?(.searchChanged(.idle))
        case .nextSearchResult, .previousSearchResult:
            guard search == .results else { throw EPUBReaderError.unsupported(.searchResults) }
            guard let results, var index = results.steppedIndex(forward: command == .nextSearchResult) else { return }
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
        if fault == .callbackAfterClose {
            Task { try? await Task.sleep(for: .milliseconds(30)); onEvent?(.notice("late")) }
        } else { onEvent = nil }
    }
}

@MainActor final class EngineContractTests: XCTestCase {
    private func verify(_ fault: ContractNativeEngine.Fault, search: ContractNativeEngine.Search = .none) async throws {
        try await EPUBEngineContract.verify(engine: ContractNativeEngine(fault: fault, search: search),
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
                                 (.callbackAfterClose, "Callback after close"), (.callbackDuringClose, "Callback after close"),
                                 (.acceptsForeignBookmark, "incompatibleLocation"), (.failureAfterReady, "failure")] {
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
                        .showSearchResult(.init(index: 0, location: .init(publicationID: book.id), spineIndex: 0, matchedText: "Opening words"))] {
            do { try await session.send(command); XCTFail("Highlight-only engine accepted \(command)") }
            catch { XCTAssertEqual(error as? EPUBReaderError, .unsupported(.searchResults)) }
        }
        XCTAssertFalse(events.contains { if case .searchResultsChanged = $0 { return true }; return false })
    }
    func testContractChecksSearchResults() async throws {
        try await verify(.none, search: .results)
        for (fault, expected) in [(ContractNativeEngine.Fault.resultsAfterCompletion, "before search completion"),
                                 (.noWrap, "previous search result"), (.acceptsStaleResult, "search result"),
                                 (.keepsResultsAfterClear, "withdrawn search results"),
                                 (.stepsAfterClear, "cleared search")] {
            do { try await verify(fault, search: .results); XCTFail("Broken search results passed: \(fault)") }
            catch let error as EPUBEngineContract.Failure { XCTAssertTrue(error.description.contains(expected), "\(fault): \(error.description)") }
        }
    }
}

// TEMPORARY, removed in the next commit: measures the race behind "Broken adapter passed:
// callbackAfterClose" (issue 62). Not for main.
@MainActor private final class LateCallbackProbe {
    var onEvent: (() -> Void)?
    var started: ContinuousClock.Instant?
    var called: ContinuousClock.Instant?
    /// As `ContractNativeSession.close()` with `.callbackAfterClose`: a callback 30 ms later,
    /// or with `sleeps` false one queued on the main actor with no timer.
    func close(sleeps: Bool) {
        Task {
            started = .now
            if sleeps { try? await Task.sleep(for: .milliseconds(30)) }
            called = .now
            onEvent?()
        }
    }
}

@MainActor final class EngineContractTimingProbeTests: XCTestCase {
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    /// One pass as the verifier ends: close, sleep 150 ms, then look for the callback.
    /// Returns whether it had come, and the time left between it and the look.
    private func pass(sleeps: Bool) async throws -> (caught: Bool, margin: Double, start: Double, detail: String) {
        var events = 0
        let probe = LateCallbackProbe()
        probe.onEvent = { events += 1 }
        let closed = ContinuousClock.now
        probe.close(sleeps: sleeps)
        try await Task.sleep(for: .milliseconds(150))
        let looked = ContinuousClock.now
        let caught = events == 1
        while probe.called == nil { try await Task.sleep(for: .milliseconds(5)) }
        let start = milliseconds(probe.started! - closed), call = milliseconds(probe.called! - closed), look = milliseconds(looked - closed)
        return (caught, look - call, start, String(format: "task started %.1f ms after close, called back at %.1f ms, verifier looked at %.1f ms", start, call, look))
    }
    func testWhichSleeperResumesFirst() async throws {
        let passes = Int(ProcessInfo.processInfo.environment["EPUBLIB_PROBE_PASSES"] ?? "") ?? 200
        var passedByTheVerifier = 0
        for shape in [true, false] {
            let name = shape ? "30 ms sleep" : "queued task"
            var margins: [(Double, String)] = [], starts: [Double] = [], missed = 0
            for _ in 0..<passes {
                let result = try await pass(sleeps: shape)
                margins.append((result.margin, result.detail))
                starts.append(result.start)
                if !result.caught { missed += 1; print("PROBE \(name) MISSED: \(result.detail)") }
            }
            margins.sort { $0.0 < $1.0 }
            for (margin, detail) in margins.prefix(3) { print(String(format: "PROBE %@ margin %.1f ms: %@", name, margin, detail)) }
            print(String(format: "PROBE %@: %d passes, %d missed, %d within 1 ms; margin least %.1f ms, 1st percentile %.1f ms, median %.1f ms", name, passes, missed,
                         margins.filter { $0.0 < 1 }.count, margins[0].0, margins[passes / 100].0, margins[passes / 2].0))
            starts.sort()
            print(String(format: "PROBE %@: task started after close: median %.2f ms, 99th percentile %.1f ms, most %.1f ms, %d over 20 ms", name,
                         starts[passes / 2], starts[passes - 1 - passes / 100], starts[passes - 1], starts.filter { $0 > 20 }.count))
        }
        // The real verifier against the real fake, as testContractRejectsBrokenAdapters runs it.
        for _ in 0..<passes {
            do {
                try await EPUBEngineContract.verify(engine: ContractNativeEngine(fault: .callbackAfterClose),
                    publication: EPUBPublication.open(data: Fixture.epub()), firstHref: "OPS/one.xhtml",
                    secondHref: "OPS/two.xhtml", text: "Opening words", timeout: 0.2) { session in
                        _ = session.makeView()
                        return {}
                    }
                passedByTheVerifier += 1
            } catch is EPUBEngineContract.Failure {}
        }
        print("PROBE verifier: \(passes) passes, the broken adapter passed in \(passedByTheVerifier)")
    }
}
