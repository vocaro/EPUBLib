import Darwin

/// A time limit for an asynchronous wait that a busy host does not decide. It is held against the
/// seconds since it was set less the seconds this process's threads were ready to run and waiting
/// for a core, so on a quiet host it is the wall clock, and a hung or sleeping wait still ends at
/// the limit. A wall-clock backstop, four times the limit and at least `slack` seconds more than
/// it, ends a wait whatever the host does. A wait the backstop ends while still inside its own limit,
/// or one that reaches its limit while macOS reports memory pressure, is unmeasured, not exceeded
/// ([CPU, scheduling and core-wait time](https://github.com/vocaro/apple-engineering/blob/main/guides/measurement.md#cpu-scheduling-and-core-wait-time)).
/// The clocks are the whole process's, so a wait is also lenient toward other threads' waits.
public struct TestDeadline: Sendable {
    public enum State: Equatable, Sendable {
        case running, exceeded
        /// The host decided the wait, and why.
        case unmeasured(String)
    }

    /// What a wait that cannot say whether it was late throws where XCTest is not at hand.
    public struct Unmeasured: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(description: String) { self.description = description }
    }

    /// The host's awake seconds, the seconds this process's threads have waited for a core, and
    /// whether macOS reports memory pressure.
    public struct Reading: Sendable {
        public var awake: Double, coreWait: Double, memoryPressure: Bool
        public init(awake: Double, coreWait: Double, memoryPressure: Bool) {
            self.awake = awake
            self.coreWait = coreWait
            self.memoryPressure = memoryPressure
        }
    }

    public let seconds: Double, backstop: Double
    private let start: Reading
    private let read: @Sendable () -> Reading

    public init(seconds: Double, slack: Double = 10) { self.init(seconds: seconds, slack: slack, read: Self.reading) }

    /// A deadline on clocks of the caller's own, for the deadline's tests.
    public init(seconds: Double, slack: Double = 10, read: @escaping @Sendable () -> Reading) {
        self.seconds = seconds
        backstop = max(seconds * 4, seconds + slack)
        self.read = read
        start = read()
    }

    public var state: State {
        let now = read()
        let elapsed = now.awake - start.awake, waited = max(0, now.coreWait - start.coreWait)
        if elapsed - waited < seconds {
            guard elapsed >= backstop else { return .running }
            return .unmeasured("the \(Self.format(backstop)) s backstop passed with \(Self.format(waited)) s spent waiting for a core, inside the \(Self.format(seconds)) s limit")
        }
        if now.memoryPressure { return .unmeasured("the \(Self.format(seconds)) s limit passed under memory pressure") }
        return .exceeded
    }

    /// The seconds left on the limit as the clocks stand, never less than zero.
    public var remaining: Double {
        let now = read()
        return max(0, seconds - (now.awake - start.awake) + max(0, now.coreWait - start.coreWait))
    }

    /// Sleeps until `duration` has passed on the deadline's clocks, or its backstop. For a fixed
    /// wait that lets the reader's own timers and settling run before a test looks: on a busy
    /// host, it waits on for the seconds those had to wait for a core. A pause is never late, so
    /// its backstop is at least two seconds more, not ten: a test with many pauses on a crowded
    /// host, whose threads' waits add up faster than the clock, is not slowed by ten seconds each.
    public static func pause(_ duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let deadline = TestDeadline(seconds: seconds, slack: 2)
        while deadline.state == .running {
            try await Task.sleep(nanoseconds: UInt64(max(0.005, deadline.remaining) * 1e9))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let tenths = (seconds * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(tenths)
    }

    /// The host's own clocks. Awake seconds leave out a sleep of the Mac, which keeps no test late.
    public static func reading() -> Reading {
        var info = rusage_info_v4()
        let status = withUnsafeMutableBytes(of: &info) { proc_rusage(getpid(), RUSAGE_INFO_V4, $0.baseAddress!) }
        // `ri_runnable_time` counts a thread's running as well as its waiting to run.
        let coreWait = status == 0 ? Double(info.ri_runnable_time) - Double(info.ri_user_time + info.ri_system_time) : 0
        var level: Int32 = 0, size = MemoryLayout<Int32>.size
        // 1 is normal; 2 and 4 are warning and critical.
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 && level > 1
        return Reading(awake: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9,
                       coreWait: max(0, coreWait) * tickSeconds, memoryPressure: pressure)
    }

    /// `rusage_info` times are in Mach ticks, which are not nanoseconds on Apple silicon.
    private static let tickSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()
}

// <libproc.h> is not in the iOS SDK; libSystem has the function on every platform.
@_silgen_name("proc_pid_rusage")
private func proc_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32
