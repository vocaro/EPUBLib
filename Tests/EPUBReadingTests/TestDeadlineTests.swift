import EPUBTestSupport
import Foundation
import XCTest

final class TestDeadlineTests: XCTestCase {
    /// Clocks a test sets by hand.
    private final class Clocks: @unchecked Sendable {
        private let lock = NSLock()
        private var now = TestDeadline.Reading(awake: 100, coreWait: 7, memoryPressure: false)
        func read() -> TestDeadline.Reading { lock.withLock { now } }
        func advance(_ seconds: Double, waiting: Double = 0, pressure: Bool = false) {
            lock.withLock {
                now.awake += seconds
                now.coreWait += waiting
                now.memoryPressure = pressure
            }
        }
        func deadline(_ seconds: Double, slack: Double = 10) -> TestDeadline {
            TestDeadline(seconds: seconds, slack: slack) { [self] in read() }
        }
    }

    func testOnAQuietHostTheLimitIsTheWallClock() {
        let clocks = Clocks(), deadline = clocks.deadline(20)
        clocks.advance(19.9)
        XCTAssertEqual(deadline.state, .running)
        XCTAssertEqual(deadline.remaining, 0.1, accuracy: 1e-9)
        clocks.advance(0.1)
        XCTAssertEqual(deadline.state, .exceeded, "a hung or sleeping wait ends at its limit")
        XCTAssertEqual(deadline.remaining, 0)
    }

    func testTheSecondsSpentWaitingForACoreAreLeftOut() {
        let clocks = Clocks(), deadline = clocks.deadline(20)
        clocks.advance(50, waiting: 35)
        XCTAssertEqual(deadline.state, .running, "15 s of the process's own time")
        XCTAssertEqual(deadline.remaining, 5, accuracy: 1e-9)
        clocks.advance(5)
        XCTAssertEqual(deadline.state, .exceeded)
    }

    func testTheBackstopLeavesAWaitTheHostDecidedUnmeasured() {
        let clocks = Clocks(), deadline = clocks.deadline(20)
        XCTAssertEqual(deadline.backstop, 80)
        clocks.advance(79.9, waiting: 70)
        XCTAssertEqual(deadline.state, .running)
        clocks.advance(0.1)
        XCTAssertEqual(deadline.state, .unmeasured("the 80 s backstop passed with 70 s spent waiting for a core, inside the 20 s limit"))
        // Waits are summed over threads, so they can outrun the wall clock; the backstop still holds.
        let crowded = clocks.deadline(0.2)
        XCTAssertEqual(crowded.backstop, 10.2, accuracy: 1e-9, "a short limit gets ten seconds more")
        clocks.advance(10.1, waiting: 400)
        XCTAssertEqual(crowded.state, .running)
        clocks.advance(0.2)
        guard case .unmeasured = crowded.state else { return XCTFail("\(crowded.state)") }
        XCTAssertEqual(clocks.deadline(0.15, slack: 2).backstop, 2.15, accuracy: 1e-9, "a pause's")
        XCTAssertEqual(clocks.deadline(1, slack: 2).backstop, 4, "four times the limit when that is more")
    }

    func testALimitReachedUnderMemoryPressureIsUnmeasured() {
        let clocks = Clocks(), deadline = clocks.deadline(5)
        clocks.advance(4, pressure: true)
        XCTAssertEqual(deadline.state, .running)
        clocks.advance(1, pressure: true)
        XCTAssertEqual(deadline.state, .unmeasured("the 5 s limit passed under memory pressure"),
                       "a thread waiting for its own pages is not runnable, so no clock leaves that wait out")
        clocks.advance(0)
        XCTAssertEqual(deadline.state, .exceeded)
    }

    func testAPauseLastsItsDuration() async throws {
        let wall = ContinuousClock(), started = wall.now
        try await TestDeadline.pause(.milliseconds(150))
        XCTAssertGreaterThanOrEqual(started.duration(to: wall.now), .milliseconds(150))
    }

    /// The positive control for the core-wait clock on this platform: more busy threads at
    /// background priority than the cores the system gives that priority wait for one, and the
    /// clock sees it. Without it a platform that could not read the clock would quietly hold
    /// every deadline on the wall clock.
    func testTheClockSeesThreadsWaitingForACore() {
        let before = TestDeadline.reading(), group = DispatchGroup()
        for _ in 0..<(2 * ProcessInfo.processInfo.activeProcessorCount) {
            group.enter()
            let thread = Thread {
                var checksum = 1
                let end = Date().addingTimeInterval(0.1)
                while Date() < end { for value in 0..<4_096 { checksum = (checksum &* 1_664_525) &+ value } }
                if checksum == 0 { print("") }
                group.leave()
            }
            thread.qualityOfService = .background
            thread.start()
        }
        group.wait()
        let after = TestDeadline.reading()
        XCTAssertGreaterThan(after.coreWait - before.coreWait, 0.05)
        XCTAssertGreaterThan(after.awake - before.awake, 0.09)
    }
}
