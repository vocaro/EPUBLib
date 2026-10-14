import EPUBTestSupport
import Foundation
import XCTest

final class TestCPUClockTests: XCTestCase {
    func testSynchronousSleepDoesNotSpendThePerformanceBudget() {
        let wall = ContinuousClock()
        let started = wall.now
        let cpu = TestCPUClock.measure { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThanOrEqual(started.duration(to: wall.now), .milliseconds(200))
        XCTAssertGreaterThanOrEqual(cpu, 0)
        XCTAssertLessThan(cpu, 0.1, "sleeping or waiting to be scheduled must not count as expensive work")
    }

    func testSynchronousWorkSpendsThePerformanceBudget() {
        let wall = ContinuousClock()
        let started = wall.now
        var checksum = 1
        let cpu = TestCPUClock.measure {
            let end = TestCPUClock.seconds() + 0.05
            while TestCPUClock.seconds() < end {
                for value in 0..<4_096 { checksum = (checksum &* 1_664_525) &+ value }
            }
        }
        XCTAssertNotEqual(checksum, 0, "keep the synchronous work observable in release builds")
        XCTAssertGreaterThanOrEqual(cpu, 0.05, "CPU work must still consume the performance budget")
        XCTAssertGreaterThanOrEqual(started.duration(to: wall.now), .seconds(cpu))
    }
}
