import Darwin

/// Cost of synchronous work on the calling thread, excluding time it is not scheduled.
/// Do not use across an `await`, a dispatch to another thread, or a deadline wait.
public enum TestCPUClock {
    public static func seconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    public static func measure(_ work: () throws -> Void) rethrows -> Double {
        let start = seconds()
        try work()
        return seconds() - start
    }
}
