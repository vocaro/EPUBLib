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
    // TEMPORARY, for the probe at the end of this file.
    static var probeOnClose: (() -> Void)?
    static var probeClosed: ContinuousClock.Instant?
    static var probeCalled: ContinuousClock.Instant?
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
        switch fault {
        case .callbackAfterClose:
            // Queued, with no timer: the main actor runs it the first time the verifier waits.
            Task { onEvent?(.notice("late")) }
        case .timedCallbackAfterClose:
            // From a timer of the engine's own, which can end together with the verifier's.
            Self.probeClosed = .now
            Self.probeOnClose?()
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                Self.probeCalled = .now
                onEvent?(.notice("late, from a timer"))
            }
        default: onEvent = nil
        }
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
    enum Engine: String {
        case task = "Task.sleep", dispatch = "main.asyncAfter", timer = "Timer"
        case stalled = "Task.sleep begun after the main thread was held 160 ms"
    }
    var onEvent: (() -> Void)?
    var started: ContinuousClock.Instant?
    var called: ContinuousClock.Instant?
    private func call() { called = .now; onEvent?() }
    private nonisolated func stall() { usleep(160_000) }
    /// As a session's `close()` that sends a callback 30 ms later, from a timer of the kind given.
    func close(_ engine: Engine) {
        switch engine {
        case .task, .stalled:
            // As the broken engine of `EngineContractTests` did before pull request 421. Stalled:
            // as when the machine keeps the main thread from what the engine queued.
            Task {
                if engine == .stalled { stall() }
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
        let id: String
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
    private func attempt(_ shape: Shape, stopper: ProcessStopper?) async throws -> (seen: Int?, start: Double, call: Double, look: Double) {
        var events = 0
        let probe = LateCallbackProbe()
        probe.onEvent = { events += 1 }
        let closed = ContinuousClock.now
        stopper?.stopSoon()
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
    /// Runs a shape and prints one line. With a stopper, only the attempts in which the stop covered
    /// both sleeps are counted: the callback and the first look both came after it.
    private func measure(_ shape: Shape, stopper: ProcessStopper?) async throws {
        var missed = Array(repeating: 0, count: shape.ladder.count + 1), counted = 0, late = 0, together = 0
        var lateness: [Double] = [], calls: [Double] = []
        for _ in 0..<shape.attempts {
            let result = try await attempt(shape, stopper: stopper)
            if stopper != nil, result.call < 170 || result.look < 170 { continue }
            counted += 1
            // Missed by a look: the callback had not come by then.
            for look in missed.indices where result.seen.map({ $0 > look }) ?? true { missed[look] += 1 }
            if result.seen != 0 { lateness.append(result.call - result.look) }
            if result.call > 100 { late += 1 }
            if abs(result.call - result.look) < 1 { together += 1 }
            calls.append(result.call)
        }
        calls.sort(); lateness.sort()
        var fields = ["attempts=\(shape.attempts)", "counted=\(counted)", "missed by the first look=\(missed[0])"]
        var sofar: [String] = []
        for (index, step) in shape.ladder.enumerated() {
            sofar.append(step.name)
            fields.append("missed after \(sofar.joined(separator: " + "))=\(missed[index + 1])")
        }
        fields += ["callback over 100 ms after close=\(late)", "callback within 1 ms of the first look=\(together)",
                   String(format: "most ms from close to callback=%.1f", calls.last ?? 0),
                   String(format: "most ms from a first look that missed to the callback=%.3f", lateness.last ?? 0),
                   String(format: "median ms from a first look that missed to the callback=%.3f", lateness.isEmpty ? 0 : lateness[lateness.count / 2])]
        print("PROBE|\(shape.id)|\(stopper == nil ? "as it comes" : "process stopped across both sleeps")|\(shape.name)|" + fields.joined(separator: "|"))
    }
    /// The real verifier against the broken engine that sleeps 30 ms.
    private func verifier(id: String, attempts: Int, stopper: ProcessStopper?) async throws {
        var counted = 0, passed = 0, caught = 0, other: [String: Int] = [:]
        ContractNativeSession.probeOnClose = stopper.map { stopper in { stopper.stopSoon() } }
        defer { ContractNativeSession.probeOnClose = nil }
        for _ in 0..<attempts {
            ContractNativeSession.probeClosed = nil; ContractNativeSession.probeCalled = nil
            var verdict = "passed"
            do {
                try await EPUBEngineContract.verify(engine: ContractNativeEngine(fault: .timedCallbackAfterClose),
                    publication: EPUBPublication.open(data: Fixture.epub()), firstHref: "OPS/one.xhtml",
                    secondHref: "OPS/two.xhtml", text: "Opening words", timeout: 0.2) { session in
                        _ = session.makeView()
                        return {}
                    }
            } catch let failure as EPUBEngineContract.Failure { verdict = failure.description }
            while ContractNativeSession.probeCalled == nil { try await Task.sleep(for: .milliseconds(5)) }
            let call = milliseconds(ContractNativeSession.probeCalled! - ContractNativeSession.probeClosed!)
            if stopper != nil, call < 170 { continue }
            counted += 1
            switch verdict {
            case "passed": passed += 1
            case "Callback after close": caught += 1
            default: other[verdict, default: 0] += 1
            }
        }
        print("PROBE|\(id)|\(stopper == nil ? "as it comes" : "process stopped across both sleeps")|the real verifier against the engine that sleeps 30 ms|attempts=\(attempts)|counted=\(counted)|engine let through=\(passed)|engine caught=\(caught)|other failures=\(other.values.reduce(0, +))" + (other.isEmpty ? "" : "|which: \(other)"))
    }
    func testWhichHardeningCatchesATimer() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scale = Double(environment["EPUBLIB_PROBE_SCALE"] ?? "") ?? 1
        let parts = environment["EPUBLIB_PROBE_PARTS"] ?? "ABCD"
        func count(_ attempts: Int) -> Int { max(Int(Double(attempts) * scale), 2) }
        print("PROBE priority \(Task.currentPriority.rawValue), scale \(scale), parts \(parts)")
        let rest: [Step] = [.yields(1), .yields(9), .sleep(1), .sleep(20)]
        let stopper = try ProcessStopper()
        defer { stopper.end() }
        if parts.contains("A") {
            // Both sleeps overdue together, every attempt. The first look is the verifier as it is.
            for shape in [
                Shape(id: "A1", engine: .task, quiet: [.sleep(150)], ladder: [.yields(1), .yields(1), .yields(8), .yields(90), .sleep(20)], attempts: count(200)),
                Shape(id: "A2", engine: .task, quiet: [.sleep(150)], ladder: [.sleep(20)], attempts: count(200)),
                // A yield first lets what the engine queued while closing start before the quiet
                // period does, so a timer it starts there is due before the period's own.
                Shape(id: "A3", engine: .task, quiet: [.yields(1), .sleep(150)], ladder: [.sleep(20)], attempts: count(200)),
                Shape(id: "A4", engine: .task, quiet: [.sleep(150)], ladder: [.sleep(1), .sleep(20)], attempts: count(100)),
                Shape(id: "A5", engine: .task, quiet: [.sleep(150)], ladder: [.hops(1), .hops(1), .sleep(20)], attempts: count(50)),
                Shape(id: "A6", engine: .task, quiet: [.exactSleep(150)], ladder: rest, attempts: count(50)),
                Shape(id: "A7", engine: .dispatch, quiet: [.sleep(150)], ladder: rest, attempts: count(100)),
                Shape(id: "A8", engine: .timer, quiet: [.sleep(150)], ladder: rest, attempts: count(100)),
            ] { try await measure(shape, stopper: stopper) }
        }
        if parts.contains("B") {
            // The engine's queued work kept waiting past the quiet period: seen once on this Mac.
            for shape in [
                Shape(id: "B1", engine: .stalled, quiet: [.sleep(150)], ladder: [.sleep(20)], attempts: count(20)),
                Shape(id: "B2", engine: .stalled, quiet: [.yields(1), .sleep(150)], ladder: [.sleep(20)], attempts: count(20)),
            ] { try await measure(shape, stopper: nil) }
        }
        if parts.contains("C") {
            // Nothing forced: this machine as it is.
            for shape in [
                Shape(id: "C1", engine: .task, quiet: [.sleep(150)], ladder: [.sleep(20)], attempts: count(200)),
                Shape(id: "C2", engine: .task, quiet: [.yields(1), .sleep(150)], ladder: [.sleep(20)], attempts: count(200)),
            ] { try await measure(shape, stopper: nil) }
        }
        if parts.contains("D") {
            try await verifier(id: "D1", attempts: count(200), stopper: stopper)
            try await verifier(id: "D2", attempts: count(200), stopper: nil)
        }
    }
}
