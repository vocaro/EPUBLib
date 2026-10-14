#if os(macOS)
import AppKit
import Darwin
import XCTest

@MainActor final class ReaderTestWindowTests: XCTestCase {
    func testRestorationOptOutUsesOnlyTheArgumentDomainAndPreservesOtherArguments() throws {
        let suite = "EPUBLib.WindowRestorationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let existing = ["ApplePersistenceIgnoreState": false, "XCTest": "SelectedTest"] as [String: Any]
        defaults.setVolatileDomain(existing, forName: UserDefaults.argumentDomain)
        XCTAssertNil(defaults.persistentDomain(forName: suite))

        prepareMacTestApplication(defaults: defaults)
        prepareMacTestApplication(defaults: defaults)

        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        XCTAssertEqual(arguments["ApplePersistenceIgnoreState"] as? Bool, true)
        XCTAssertEqual(arguments["XCTest"] as? String, "SelectedTest")
        XCTAssertTrue(defaults.bool(forKey: "ApplePersistenceIgnoreState"))
        XCTAssertNil(defaults.persistentDomain(forName: suite), "the harness must not persist a user preference")
    }

    /// Run by itself with EPUBLIB_TEST_KILL_WINDOW_PROCESS=YES, then run the window tests
    /// again without a launch-argument workaround. SIGKILL ends only this process and does
    /// not raise a CrashReporter dialog on the shared Mac.
    func testKilledWindowProcessProbe() throws {
        guard ProcessInfo.processInfo.environment["EPUBLIB_TEST_KILL_WINDOW_PROCESS"] == "YES" else {
            throw XCTSkip("opt in to kill this test process after mounting a window")
        }
        let window = makeMacTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.orderFront(nil)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState"))
        kill(getpid(), SIGKILL)
        XCTFail("the opt-in probe must terminate its own process")
    }

    func testWindowFactoryOptsOutOfRestorationForTheTestProcess() {
        let window = makeMacTestWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        XCTAssertEqual(arguments["ApplePersistenceIgnoreState"] as? Bool, true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState"))
    }
}
#endif
