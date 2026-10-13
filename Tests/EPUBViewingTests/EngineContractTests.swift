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
            // Queued here and not sent after a sleep: the main actor then runs it the first time
            // the verifier waits, ahead of the verifier's own wake. A sleep raced that wake.
            Task { onEvent?(.notice("late")) }
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

// TEMPORARY, removed before the pull request: measures which changes to the end of
// `EPUBEngineContract.verify` catch a callback an engine sends from a 30 ms timer of its own
// (issue 62). Not for main.
@MainActor private final class LateCallbackProbe {
    enum Engine: String { case task = "Task.sleep", dispatch = "main.asyncAfter", timer = "Timer" }
    var onEvent: (() -> Void)?
    var started: ContinuousClock.Instant?
    var called: ContinuousClock.Instant?
    private func call() { called = .now; onEvent?() }
    /// As a session's `close()` that sends a callback 30 ms later, from a timer of the kind given.
    func close(_ engine: Engine) {
        switch engine {
        case .task:
            // As the broken engine of `EngineContractTests` did before pull request 421.
            Task {
                started = .now
                try? await Task.sleep(for: .milliseconds(30))
                call()
            }
        case .dispatch:
            started = .now
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { MainActor.assumeIsolated { self.call() } }
        case .timer:
            started = .now
            Timer.scheduledTimer(withTimeInterval: 0.03, repeats: false) { _ in MainActor.assumeIsolated { self.call() } }
        }
    }
}

@MainActor final class EngineContractTimingProbeTests: XCTestCase {
    /// One thing the verifier's side does: before it first looks for the callback, or between looks.
    private enum Step {
        case sleep(Int), exactSleep(Int), slices(Int, of: Int), yields(Int), hops(Int)
        var name: String {
            switch self {
            case .sleep(let ms): "\(ms) ms sleep"
            case .exactSleep(let ms): "\(ms) ms sleep with no tolerance"
            case .slices(let count, let ms): "\(count) sleeps of \(ms) ms"
            case .yields(let count): count == 1 ? "1 yield" : "\(count) yields"
            case .hops(let count): count == 1 ? "1 hop to a global queue and back" : "\(count) hops"
            }
        }
        @MainActor func run() async throws {
            switch self {
            case .sleep(let ms): try await Task.sleep(for: .milliseconds(ms))
            case .exactSleep(let ms): try await Task.sleep(for: .milliseconds(ms), tolerance: .zero)
            case .slices(let count, let ms): for _ in 0..<count { try await Task.sleep(for: .milliseconds(ms)) }
            case .yields(let count): for _ in 0..<count { await Task.yield() }
            case .hops(let count):
                // The queue a sleep's timer is delivered on, for a task of this priority.
                let queue = DispatchQueue.global(qos: Task.currentPriority >= .userInitiated ? .userInitiated : .default)
                for _ in 0..<count {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        queue.async { continuation.resume() }
                    }
                }
            }
        }
    }
    /// A quiet period after close, and what is then tried one after another, with a look after each.
    private struct Shape {
        let engine: LateCallbackProbe.Engine
        let quiet: [Step]
        let ladder: [Step]
        let attempts: Int
        var name: String { "\(engine.rawValue) engine; quiet period: \(quiet.map(\.name).joined(separator: " + "))" }
    }
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    /// One attempt as the verifier ends: close, wait, then look for the callback, and look again
    /// after each step of the ladder. `seen` is the look that first found it: 0 the first, nil none.
    private func attempt(_ shape: Shape) async throws -> (seen: Int?, start: Double, call: Double, look: Double) {
        var events = 0
        let probe = LateCallbackProbe()
        probe.onEvent = { events += 1 }
        let closed = ContinuousClock.now
        probe.close(shape.engine)
        for step in shape.quiet { try await step.run() }
        let looked = ContinuousClock.now
        var seen: Int? = events == 1 ? 0 : nil
        for (index, step) in shape.ladder.enumerated() {
            try await step.run()
            if seen == nil, events == 1 { seen = index + 1 }
        }
        while probe.called == nil { try await Task.sleep(for: .milliseconds(5)) }
        return (seen, milliseconds(probe.started! - closed), milliseconds(probe.called! - closed), milliseconds(looked - closed))
    }
    func testWhichHardeningCatchesATimer() async throws {
        let scale = Double(ProcessInfo.processInfo.environment["EPUBLIB_PROBE_SCALE"] ?? "") ?? 1
        func count(_ attempts: Int) -> Int { max(Int(Double(attempts) * scale), 2) }
        print("PROBE priority \(Task.currentPriority.rawValue), scale \(scale)")
        let rest: [Step] = [.yields(1), .yields(9), .sleep(1), .sleep(20)]
        let shapes = [
            // The candidates, each beside the verifier as it is: the first look is the verifier's.
            Shape(engine: .task, quiet: [.sleep(150)], ladder: [.yields(1), .yields(1), .yields(8), .yields(90)], attempts: count(200)),
            Shape(engine: .task, quiet: [.sleep(150)], ladder: [.sleep(20)], attempts: count(200)),
            // A yield first lets what the engine queued while closing start before the quiet
            // period does, so a timer it starts there is due before the period's own.
            Shape(engine: .task, quiet: [.yields(1), .sleep(150)], ladder: [.sleep(20)], attempts: count(200)),
            Shape(engine: .task, quiet: [.sleep(150)], ladder: [.sleep(1), .sleep(20)], attempts: count(100)),
            Shape(engine: .task, quiet: [.sleep(150)], ladder: [.hops(1), .hops(1), .sleep(20)], attempts: count(50)),
            // Other ways to spend the quiet period itself.
            Shape(engine: .task, quiet: [.exactSleep(150)], ladder: rest, attempts: count(50)),
            Shape(engine: .task, quiet: [.slices(15, of: 10)], ladder: rest, attempts: count(50)),
            // Other timers an engine might use.
            Shape(engine: .dispatch, quiet: [.sleep(150)], ladder: rest, attempts: count(100)),
            Shape(engine: .timer, quiet: [.sleep(150)], ladder: rest, attempts: count(100)),
        ]
        for (number, shape) in shapes.enumerated() {
            var missed = Array(repeating: 0, count: shape.ladder.count + 1), never = 0, late = 0, together = 0
            var lateness: [Double] = [], calls: [Double] = [], starts: [Double] = []
            for _ in 0..<shape.attempts {
                let result = try await attempt(shape)
                // Missed by a look: the callback had not come by then.
                for look in missed.indices where result.seen.map({ $0 > look }) ?? true { missed[look] += 1 }
                if result.seen == nil { never += 1 }
                if result.seen != 0 { lateness.append(result.call - result.look) }
                if result.call > 100 { late += 1 }
                if abs(result.call - result.look) < 1 { together += 1 }
                calls.append(result.call); starts.append(result.start)
            }
            calls.sort(); starts.sort(); lateness.sort()
            var fields = ["first look=\(missed[0])"]
            var sofar: [String] = []
            for (index, step) in shape.ladder.enumerated() {
                sofar.append(step.name)
                fields.append("then \(sofar.joined(separator: " + "))=\(missed[index + 1])")
            }
            print("PROBE|\(number + 1)|\(shape.name)|attempts=\(shape.attempts)|missed after: " + fields.joined(separator: "; ")
                + String(format: "|callback over 100 ms after close=%d|within 1 ms of the first look=%d|callback after close: median %.1f ms, most %.1f ms|engine started after close: most %.1f ms|callback after a first look that missed it: most %.3f ms, median %.3f ms",
                         late, together, calls[calls.count / 2], calls.last!, starts.last!,
                         lateness.last ?? 0, lateness.isEmpty ? 0 : lateness[lateness.count / 2]))
        }
        // A 30 ms sleep with no other timer waiting in the process: how long it takes.
        var alone: [Double] = []
        for _ in 0..<count(200) {
            let began = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(30))
            alone.append(milliseconds(ContinuousClock.now - began))
        }
        alone.sort()
        print(String(format: "PROBE|10|a 30 ms sleep alone|attempts=%d|took: median %.1f ms, 99th percentile %.1f ms, most %.1f ms|over 40 ms=%d|over 100 ms=%d",
                     alone.count, alone[alone.count / 2], alone[alone.count - 1 - alone.count / 100], alone.last!,
                     alone.filter { $0 > 40 }.count, alone.filter { $0 > 100 }.count))
    }
}
