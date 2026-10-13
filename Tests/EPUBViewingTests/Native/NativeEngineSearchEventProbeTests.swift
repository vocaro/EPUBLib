import EPUBCore
import EPUBReading
import EPUBTestSupport
import EPUBViewingTestSupport
import SwiftUI
import XCTest
@testable import EPUBViewing

// TEMPORARY, removed before the pull request: whether EPUBLib's own engine sends anything during
// the verifier's search-results check while no command is being sent to it, which is what a
// timer or a queued task of its own would do.

@MainActor private final class EventRecorder {
    var sending = 0
    var last = "nothing", lastAt = ContinuousClock.now
    /// From the check's first command, a result shown with no search, to the style change after it.
    var checking = false
    var inside = 0, outside = 0
    var lines: [String] = []
    private func name(_ value: Any) -> String { String(String(describing: value).prefix { $0 != "(" }) }
    func begin(_ command: EPUBReaderCommand?) {
        if case .showSearchResult = command, !checking, last == "previousSearchResult" || last == "setHighlights" { checking = true }
        if case .style = command { checking = false }
        if command == nil { checking = false }
        last = command.map(name) ?? "close"
        lastAt = .now
        if checking { lines.append("command \(last)") }
    }
    func note(_ event: EPUBReaderEvent) {
        guard checking else { return }
        let elapsed = ContinuousClock.now - lastAt
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        if sending > 0 { inside += 1 } else { outside += 1 }
        lines.append(String(format: "    %@ %@, %.1f ms after %@ began", sending > 0 ? "inside" : "OUTSIDE", name(event), ms, last))
    }
}

@MainActor private final class RecordingSession: EPUBReaderSession {
    let inner: any EPUBReaderSession
    let recorder: EventRecorder
    init(inner: any EPUBReaderSession, recorder: EventRecorder) { self.inner = inner; self.recorder = recorder }
    var capabilities: Set<EPUBReaderCapability> { inner.capabilities }
    var readerState: EPUBReaderState? { inner.readerState }
    func makeView() -> AnyView { inner.makeView() }
    func send(_ command: EPUBReaderCommand) async throws {
        recorder.begin(command)
        recorder.sending += 1
        defer { recorder.sending -= 1 }
        try await inner.send(command)
    }
    func close() { recorder.begin(nil); inner.close() }
}

@MainActor private struct RecordingEngine: EPUBReaderEngine {
    let inner: any EPUBReaderEngine
    let recorder: EventRecorder
    var id: String { inner.id }
    func makeSession(publication: EPUBPublication, selectionAction: EPUBSelectionAction?,
                     onEvent: @escaping @MainActor (EPUBReaderEvent) -> Void) throws -> any EPUBReaderSession {
        let recorder = recorder
        let session = try inner.makeSession(publication: publication, selectionAction: selectionAction) { event in
            recorder.note(event)
            onEvent(event)
        }
        return RecordingSession(inner: session, recorder: recorder)
    }
}

@MainActor final class NativeEngineSearchEventProbeTests: XCTestCase {
    func testWhatTheNativeEngineSendsOutsideACommand() async throws {
        guard let runs = Int(ProcessInfo.processInfo.environment["EPUBLIB_PROBE_NATIVE"] ?? "") else {
            throw XCTSkip("Set EPUBLIB_PROBE_NATIVE to a number of runs")
        }
        var inside = 0, outside = 0, failures: [String] = []
        for run in 0..<runs {
            let recorder = EventRecorder()
            do {
                try await EPUBEngineContract.verify(engine: RecordingEngine(inner: NativeEngine(), recorder: recorder),
                    publication: EPUBPublication.open(data: Fixture.epub()),
                    firstHref: "OPS/one.xhtml", secondHref: "OPS/two.xhtml", text: "Opening words are visible.") { session in
                        let window = ReaderTestWindow(session: session)
                        return { window.close() }
                    }
            } catch let error as EPUBEngineContract.Failure { failures.append(error.description) }
            inside += recorder.inside; outside += recorder.outside
            if run == 0 || recorder.outside > 0 { for line in recorder.lines { print("NATIVE|run \(run)|\(line)") } }
        }
        print("NATIVE|runs=\(runs)|events during the search check sent inside a command=\(inside)|outside any command=\(outside)|verifier failures=\(failures.count)" + (failures.isEmpty ? "" : "|\(failures)"))
    }
}
