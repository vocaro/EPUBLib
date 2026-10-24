import EPUBTestSupport
import XCTest

extension TestDeadline {
    /// Whether a wait is over: false while it runs, true once it reached its limit. A wait the
    /// host decided is skipped as unmeasured, which the gate reports (doc/testing.md, "Local gate").
    func hasPassed() throws -> Bool {
        switch state {
        case .running: return false
        case .exceeded: return true
        case .unmeasured(let reason): throw XCTSkip("Unmeasured: \(reason)")
        }
    }

    /// Whether `expectations` were fulfilled within `seconds` as a deadline counts them. XCTest
    /// waits on the wall clock, and only once for an expectation, so it waits to the backstop and
    /// the deadline then judges: one fulfilled after the limit is late.
    static func fulfillment(of expectations: [XCTestExpectation], within seconds: TimeInterval) async throws -> Bool {
        let deadline = TestDeadline(seconds: seconds)
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: deadline.backstop)
        return try !deadline.hasPassed() && result == .completed
    }
}

extension TestDeadline.Unmeasured {
    /// The skip for a wait that `EPUBEngineContract` could not decide.
    var skip: XCTSkip { XCTSkip("Unmeasured: \(description)") }
}
