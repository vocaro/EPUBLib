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
    // TEMPORARY, for the probe at the end of this file.
    static var probe: SearchWaitProbe?
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
        onEvent?(.relocated(.init(publicationID: book.id, href: href,
            bookmark: .init(engineID: "contract.native", format: "href-v1", value: href))))
    }
    /// Sends 30 ms on, from a timer of the engine's own, which can end together with one of the
    /// verifier's.
    private func later(_ send: @escaping () -> Void) {
        let measured = Self.probe?.timerStarts() ?? false // TEMPORARY
        Task {
            if measured { Self.probe?.stall() } // TEMPORARY
            try? await Task.sleep(for: .milliseconds(30))
            if measured { Self.probe?.sent = .now } // TEMPORARY
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
        Self.probe?.received(command, listed: results != nil) // TEMPORARY
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
        Self.probe?.received(nil, listed: false) // TEMPORARY
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

// TEMPORARY, removed before the pull request: measures how often each of the three fixed waits in
// the search-results check of `EPUBEngineContract.verify` is beaten by an event an engine sends
// from a 30 ms timer of its own, as the waits are and with a yield before and 20 ms after
// (issue 62). Not for main.

/// What the test engine tells of one run of the verifier: when the timer for the measured wait
/// started, when its event was sent, and when the verifier next acted, which is its look.
@MainActor final class SearchWaitProbe {
    /// 1: the wait before `cleared` is counted; 2: before `quiet` is; 3: before the last check.
    let wait: Int
    let stalls: Bool
    let onStart: () -> Void
    /// 1 once the last step is taken, 2 once the search is cleared after it, 3 at a stale step.
    private var stage = 0
    var started, sent, looked: ContinuousClock.Instant?
    /// Whether the event had been sent when the verifier looked.
    var seen = false
    init(wait: Int, stalls: Bool, onStart: @escaping () -> Void) {
        self.wait = wait; self.stalls = stalls; self.onStart = onStart
    }
    private func look() {
        guard started != nil, looked == nil else { return }
        looked = .now
        seen = sent != nil
    }
    /// A command reaching the engine, or its close when nil. The verifier counts its events, or
    /// makes its last check, and reaches the engine again with nothing between.
    func received(_ command: EPUBReaderCommand?, listed: Bool) {
        switch command {
        case .some(.previousSearchResult) where listed: stage = 1
        case .some(.clearSearch) where stage == 1:
            stage = 2
            if wait == 1 { look() }
        case .some(.nextSearchResult) where stage == 2:
            stage = 3
            if wait == 2 { look() }
        case .some(.style) where stage == 3, .none where stage == 3:
            if wait == 3 { look() }
        default: break
        }
    }
    /// Whether a timer the engine starts now is the one measured: the last step's relocation,
    /// the clear's idle state, or the first stale step's effect.
    func timerStarts() -> Bool {
        guard started == nil, stage == wait else { return false }
        started = .now
        onStart()
        return true
    }
    /// As when the machine keeps the main thread from what the engine queued.
    nonisolated func stall() { if stalls { usleep(160_000) } }
}

#if os(macOS)
/// Stops this process for 200 ms, from about 5 ms after it is asked. Every timer that comes due
/// meanwhile is overdue when the process continues, and they are delivered together: what
/// GitHub's runner did to a 30 ms sleep and a 150 ms one in a quarter of attempts.
@MainActor private final class ProcessStopper {
    private let helper = Process()
    private let pipe = Pipe()
    init() throws {
        let process = ProcessInfo.processInfo.processIdentifier
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while read line; do /bin/sleep 0.005; kill -STOP \(process); /bin/sleep 0.2; kill -CONT \(process); done"]
        helper.standardInput = pipe
        try helper.run()
    }
    func stopSoon() { pipe.fileHandleForWriting.write(Data("stop\n".utf8)) }
    func end() { try? pipe.fileHandleForWriting.close(); helper.waitUntilExit() }
}

@MainActor final class EngineContractTimingProbeTests: XCTestCase {
    private static let effect = "A step or result of a cleared search still had an effect"
    /// One of the three waits, as it is or treated, against the engine that races it.
    private final class Shape {
        let id: String, wait: Int, treated: Bool
        var attempts = 0, counted = 0, beaten = 0, unmeasured = 0
        var verdicts: [String: Int] = [:]
        /// Of the counted attempts: from the look to the event where the look came first, and
        /// from the event to the look where the event did.
        var behind: [Double] = [], ahead: [Double] = []
        init(_ id: String, wait: Int, treated: Bool) { self.id = id; self.wait = wait; self.treated = treated }
        var name: String {
            let which = ["before the count taken as `cleared`", "before the count taken as `quiet`", "before the last check"][wait - 1]
            let engine = wait == 3 ? "a broken engine whose stale step has its effect" : "a correct engine that reports"
            return "wait \(wait), \(which)|\(treated ? "a yield before, 20 ms after" : "as it is")|\(engine) from a 30 ms sleep"
        }
    }
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    /// One run of the real verifier. With a stopper the process is stopped across the measured
    /// wait, and the attempt is counted only if the stop covered both sleeps: the event and the
    /// look both came 170 ms or more after the engine's timer started.
    private func attempt(_ shape: Shape, book: EPUBPublication, stopper: ProcessStopper?, stalls: Bool) async throws {
        let probe = SearchWaitProbe(wait: shape.wait, stalls: stalls) { stopper?.stopSoon() }
        ContractNativeSession.probe = probe
        EPUBEngineContract.probeTreated = shape.treated ? [shape.wait] : []
        defer { ContractNativeSession.probe = nil; EPUBEngineContract.probeTreated = [] }
        let engine = shape.wait == 3 ? ContractNativeEngine(fault: .timedStepsAfterClear, search: .results)
            : ContractNativeEngine(fault: .none, search: .results, reportsLate: true)
        var verdict = "passed"
        do {
            try await EPUBEngineContract.verify(engine: engine, publication: book, firstHref: "OPS/one.xhtml",
                secondHref: "OPS/two.xhtml", text: "Opening words", timeout: 0.2) { session in
                    _ = session.makeView()
                    return {}
                }
        } catch let failure as EPUBEngineContract.Failure { verdict = failure.description }
        while probe.started != nil, probe.sent == nil { try await Task.sleep(for: .milliseconds(5)) }
        shape.attempts += 1
        guard let started = probe.started, let sent = probe.sent, let looked = probe.looked else {
            shape.unmeasured += 1
            return
        }
        let call = milliseconds(sent - started), look = milliseconds(looked - started)
        if stopper != nil, call < 170 || look < 170 { return }
        shape.counted += 1
        shape.verdicts[verdict, default: 0] += 1
        if probe.seen { shape.ahead.append(look - call) } else {
            shape.beaten += 1
            shape.behind.append(call - look)
        }
    }
    /// Takes the shapes in turn, an attempt of each, so that all of them meet the same machine.
    private func measure(_ part: String, _ shapes: [Shape], attempts: Int, stopper: ProcessStopper?, stalls: Bool = false) async throws {
        let book = try EPUBPublication.open(data: Fixture.epub())
        for _ in 0..<attempts {
            for shape in shapes { try await attempt(shape, book: book, stopper: stopper, stalls: stalls) }
        }
        for shape in shapes {
            let passed = shape.verdicts["passed", default: 0], effect = shape.verdicts[Self.effect, default: 0]
            let other = shape.verdicts.filter { $0.key != "passed" && $0.key != Self.effect }
            shape.behind.sort(); shape.ahead.sort()
            print("PROBE|\(shape.id)|\(part)|\(shape.name)|attempts=\(shape.attempts)|counted=\(shape.counted)|beaten=\(shape.beaten)"
                + "|verifier passed=\(passed)|verifier failed for an effect of a cleared search=\(effect)|other failures=\(other.values.reduce(0, +))"
                + "|not measured=\(shape.unmeasured)"
                + String(format: "|most ms from the look to the event=%.3f|median=%.3f|least ms from the event to the look=%.3f",
                         shape.behind.last ?? 0, shape.behind.isEmpty ? 0 : shape.behind[shape.behind.count / 2], shape.ahead.first ?? 0)
                + (other.isEmpty ? "" : "|which: \(other)"))
        }
    }
    private func shapes(_ prefix: String) -> [Shape] {
        (1...3).flatMap { wait in [Shape("\(prefix)\(wait)a", wait: wait, treated: false), Shape("\(prefix)\(wait)t", wait: wait, treated: true)] }
    }
    func testWhichSearchWaitsATimerBeats() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let parts = environment["EPUBLIB_PROBE_PARTS"] else { throw XCTSkip("Set EPUBLIB_PROBE_PARTS to run the probe") }
        let scale = Double(environment["EPUBLIB_PROBE_SCALE"] ?? "") ?? 1
        func count(_ attempts: Int) -> Int { max(Int(Double(attempts) * scale), 2) }
        print("PROBE priority \(Task.currentPriority.rawValue), scale \(scale), parts \(parts)")
        let stopper = try ProcessStopper()
        defer { stopper.end() }
        // Both sleeps overdue together, every attempt.
        if parts.contains("A") {
            try await measure("process stopped across both sleeps", shapes("A"), attempts: count(200), stopper: stopper)
        }
        // The engine's queued work kept from starting for 160 ms.
        if parts.contains("B") {
            try await measure("main thread held 160 ms before the engine's timer starts", shapes("B"), attempts: count(20), stopper: nil, stalls: true)
        }
        // Nothing forced: this machine as it is.
        if parts.contains("C") {
            try await measure("as it comes", shapes("C"), attempts: count(200), stopper: nil)
        }
    }
}
#endif
