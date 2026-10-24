#!/usr/bin/env python3
"""Check test-ios.sh failure/cleanup paths with fake tools; no simulator or build starts."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name("test-ios.sh")
KINDS = ["iPhone-17-Pro", "iPad-Air-13-inch-M4"]
STUB = r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
name = Path(sys.argv[0]).name
trace = Path(os.environ["TEST_IOS_TRACE"])
devices_file = Path(os.environ["TEST_IOS_DEVICES"])
def record(*event):
    with trace.open("a") as log:
        log.write(json.dumps(event) + "\n")
if name == "xcrun":
    assert args[0] == "simctl", args
    action = args[1]
    if action == "create":
        kind = args[3].split(".")[-1]
        record("create", kind)
        if os.environ.get("TEST_IOS_FAIL_CREATE") == kind:
            sys.exit(1)
        devices = json.loads(devices_file.read_text())
        devices["devices"]["runtime"].append({"name": args[2], "udid": "mock-" + kind})
        devices_file.write_text(json.dumps(devices))
        if os.environ.get("TEST_IOS_HANG_CREATE") == kind:
            if os.environ.get("TEST_IOS_IGNORE_TERM") == "YES":
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            print("mock-" + kind, flush=True)
            record("creating", os.getpid())
            time.sleep(30)
        elif os.environ.get("TEST_IOS_HANG_CREATE_WITHOUT_OUTPUT") == kind:
            record("creating", os.getpid())
            time.sleep(30)
        print("mock-" + kind)
    elif action == "list":
        assert args[2:] == ["devices", "--json"], args
        print(devices_file.read_text())
    else:
        device = args[2]
        record(action, device)
        if action == "boot" and os.environ.get("TEST_IOS_FAIL_BOOT") == device:
            sys.exit(1)
        if action == "bootstatus" and os.environ.get("TEST_IOS_FAIL_BOOTSTATUS") == device:
            print("Unable to boot device", flush=True)
            sys.exit(149)
        if action == "bootstatus" and os.environ.get("TEST_IOS_HANG_BOOT") == device:
            print("Waiting on Data Migration: fake.addressbook.migrator", flush=True)
            time.sleep(30)
elif name == "xcodebuild":
    destination = args[args.index("-destination") + 1]
    device = destination.split("id=")[1]
    record("test", device, args)
    if os.environ.get("TEST_IOS_HANG_TEST") == device:
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        record("child", child.pid)
        time.sleep(30)
    if os.environ.get("TEST_IOS_FAIL_TEST") == device:
        print("fake test failure", flush=True)
        sys.exit(65)
    if os.environ.get("TEST_IOS_UNMEASURED") == device:
        print("/tmp/Tests/X.swift:9: -[EPUBViewingTests.XTests testY] : Test skipped - Unmeasured: the 80 s backstop passed", flush=True)
    if os.environ.get("TEST_IOS_NO_TESTS") == device:
        print("Test Suite 'All tests' passed at 2026-10-23 00:00:00.000.\n"
              "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds", flush=True)
        sys.exit(0)
    # As xcodebuild reports them: each bundle's classes and its All tests, or Selected tests when
    # filtered, then Swift Testing's run.
    top = "Selected tests" if any(arg.startswith("-only-testing:") for arg in args) else "All tests"
    print("Test Suite 'ZIPTests' passed at 2026-10-23 00:00:00.000.\n"
          "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n"
          "Test Suite 'EPUBReadingTests.xctest' passed at 2026-10-23 00:00:00.000.\n"
          "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n"
          f"Test Suite '{top}' passed at 2026-10-23 00:00:00.000.\n"
          "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n"
          "━ Test run with 1 test in 1 suite passed after 0.001 seconds.\n"
          f"Test Suite '{top}' passed at 2026-10-23 00:00:01.000.\n"
          "\t Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.001 (0.001) seconds",
          flush=True)
else:
    raise AssertionError(name)
'''


class IOSGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="epublib-test-ios-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.root / "scripts/test-ios.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for command in ["xcrun", "xcodebuild"]:
            stub = self.bin / command
            stub.write_text(STUB)
            stub.chmod(0o755)
        self.trace = self.root / "trace.jsonl"
        self.devices = self.root / "devices.json"
        self.devices.write_text(json.dumps({"devices": {"runtime": [
            {"name": "another-session", "udid": "unowned-device"}]}}))
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TEST_IOS_TRACE=str(self.trace), TEST_IOS_DEVICES=str(self.devices),
                        EPUB_SIM_BOOT_TIMEOUT="1")

    def events(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()]

    def run_gate(self, *arguments, **environment):
        result = subprocess.run(["bash", "scripts/test-ios.sh", *arguments], cwd=self.root,
                                env=dict(self.env, **environment), capture_output=True,
                                text=True, timeout=15)
        self.assertEqual(result.stderr, "", result.stderr)
        return result

    def assert_cleanup(self, kinds):
        for kind in kinds:
            for action in ["shutdown", "delete"]:
                self.assertEqual(self.events().count([action, "mock-" + kind]), 1)

    def test_both_devices_pass_with_explicit_destinations_and_no_diagnostics(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout.count("Passed:"), 2)
        tests = [event for event in self.events() if event[0] == "test"]
        self.assertEqual([event[1] for event in tests], ["mock-" + kind for kind in KINDS])
        for _, _, args in tests:
            self.assertEqual(args[args.index("-destination-timeout") + 1], "600")
            self.assertEqual(args[args.index("-collect-test-diagnostics") + 1], "never")
            self.assertEqual(args[args.index("-jobs") + 1], "4", "the build's workers are bounded")
            self.assertEqual(args[-1], "test")
        self.assertNotIn("Unmeasured", result.stdout)
        self.assert_cleanup(KINDS)

    def test_build_workers_follow_the_environment_and_must_be_a_positive_number(self):
        result = self.run_gate(EPUB_BUILD_JOBS="2")
        self.assertEqual(result.returncode, 0, result.stdout)
        for event in self.events():
            if event[0] == "test":
                self.assertEqual(event[2][event[2].index("-jobs") + 1], "2")
        for value in ["0", "-1", "four"]:
            result = subprocess.run(["bash", "scripts/test-ios.sh"], cwd=self.root, capture_output=True, text=True,
                                    env=dict(self.env, EPUB_BUILD_JOBS=value), timeout=15)
            self.assertEqual(result.returncode, 2, value)
            self.assertIn("EPUB_BUILD_JOBS must be a positive number", result.stderr)

    def test_a_test_the_host_decided_leaves_the_run_unmeasured_not_passed(self):
        result = self.run_gate(TEST_IOS_UNMEASURED="mock-" + KINDS[0])
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(result.stdout.count("Passed:"), 2, "both devices still run")
        self.assertIn(f"Unmeasured: {KINDS[0]} (com.apple.CoreSimulator.SimRuntime.iOS-27-0): 1 tests a busy host decided", result.stdout)
        self.assertIn("Test skipped - Unmeasured: the 80 s backstop passed", result.stdout)
        self.assertIn("left 1 tests or devices unmeasured", result.stdout)
        self.assert_cleanup(KINDS)

    def test_a_failure_outranks_an_unmeasured_test(self):
        result = self.run_gate(TEST_IOS_UNMEASURED="mock-" + KINDS[0], TEST_IOS_FAIL_TEST="mock-" + KINDS[1])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Unmeasured: " + KINDS[0], result.stdout)
        self.assertIn("Failed: " + KINDS[1], result.stdout)
        self.assert_cleanup(KINDS)

    def test_each_device_reports_its_tests_over_every_bundle_and_framework(self):
        # Two bundles' All tests, 2 and 3, and Swift Testing's 1; ZIPTests' own 2 is in the first bundle's.
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)
        for kind in KINDS:
            self.assertIn(f"Passed: {kind} (com.apple.CoreSimulator.SimRuntime.iOS-27-0): Executed 6 tests\n",
                          result.stdout)

    def test_arguments_reach_each_devices_test_action(self):
        selection = "-only-testing:EPUBViewingTests/NativeSessionTests"
        result = self.run_gate(selection)
        self.assertEqual(result.returncode, 0, result.stdout)
        tests = [event for event in self.events() if event[0] == "test"]
        self.assertEqual(len(tests), 2)
        for _, _, args in tests:
            self.assertEqual(args.count(selection), 1)
            self.assertLess(args.index(selection), args.index("test"))
        # A filtered run's bundles report under Selected tests, not All tests.
        for kind in KINDS:
            self.assertIn(f"Passed: {kind} (com.apple.CoreSimulator.SimRuntime.iOS-27-0): Executed 6 tests\n",
                          result.stdout)
        self.assert_cleanup(KINDS)

    def test_a_device_that_ran_no_tests_fails_and_the_other_still_runs(self):
        result = self.run_gate(TEST_IOS_NO_TESTS="mock-" + KINDS[0])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"Failed: {KINDS[0]} (com.apple.CoreSimulator.SimRuntime.iOS-27-0): no tests ran", result.stdout)
        self.assertIn("Passed: " + KINDS[1], result.stdout)
        self.assert_cleanup(KINDS)

    def test_failed_first_test_still_runs_second_and_fails_gate(self):
        result = self.run_gate(TEST_IOS_FAIL_TEST="mock-" + KINDS[0])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Failed: " + KINDS[0], result.stdout)
        self.assertIn("Passed: " + KINDS[1], result.stdout)
        self.assert_cleanup(KINDS)

    def test_failed_creation_still_runs_second(self):
        result = self.run_gate(TEST_IOS_FAIL_CREATE=KINDS[0])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("simulator creation", result.stdout)
        self.assertIn("Passed: " + KINDS[1], result.stdout)
        self.assert_cleanup(KINDS[1:])
        self.assertNotIn(["delete", "mock-" + KINDS[0]], self.events())

    def test_failed_boot_still_runs_second_and_deletes_first(self):
        result = self.run_gate(TEST_IOS_FAIL_BOOT="mock-" + KINDS[0])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("simulator boot", result.stdout)
        self.assertIn("Passed: " + KINDS[1], result.stdout)
        self.assert_cleanup(KINDS)

    def test_a_bootstatus_that_fails_before_its_limit_is_a_failure(self):
        result = self.run_gate(TEST_IOS_FAIL_BOOTSTATUS="mock-" + KINDS[0])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"Failed: {KINDS[0]} (com.apple.CoreSimulator.SimRuntime.iOS-27-0): bootstatus failed", result.stdout)
        self.assertIn("Unable to boot device", result.stdout)
        self.assertIn("Passed: " + KINDS[1], result.stdout)
        self.assert_cleanup(KINDS)

    def test_stalled_boot_is_bounded_unmeasured_and_preserves_its_last_stage(self):
        result = self.run_gate(TEST_IOS_HANG_BOOT="mock-" + KINDS[0])
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertIn(f"Unmeasured: {KINDS[0]} (com.apple.CoreSimulator.SimRuntime.iOS-27-0): the boot exceeded 1s", result.stdout)
        self.assertNotIn("Failed:", result.stdout)
        self.assertIn("fake.addressbook.migrator", result.stdout)
        self.assertIn("Passed: " + KINDS[1], result.stdout)
        log = self.root / ".build/validation" / (KINDS[0] + "-boot.log")
        self.assertIn("fake.addressbook.migrator", log.read_text())
        self.assertFalse(any(event[:2] == ["test", "mock-" + KINDS[0]] for event in self.events()))
        self.assert_cleanup(KINDS)

    def interrupt_creation(self, environment):
        process = subprocess.Popen(["bash", "scripts/test-ios.sh"], cwd=self.root,
                                   env=dict(self.env, **environment),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        deadline = time.monotonic() + 10
        create_pid = None
        while time.monotonic() < deadline:
            if self.trace.exists():
                create_pid = next((event[1] for event in self.events() if event[0] == "creating"), None)
            if create_pid:
                break
            time.sleep(0.01)
        self.assertIsNotNone(create_pid, "the fake creation never reached its wait")
        started = time.monotonic()
        process.send_signal(signal.SIGTERM)
        output, errors = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 143, output + errors)
        self.assertLess(time.monotonic() - started, 5, "TERM must not wait for the 30-second creation")
        self.assert_cleanup(KINDS[:1])
        self.assertNotIn(["create", KINDS[1]], self.events())
        self.assertFalse(any(event[:2] == ["delete", "unowned-device"] for event in self.events()))
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(create_pid)],
                               capture_output=True, text=True, timeout=5).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), "active creation remains: " + state)

    def test_term_during_creation_recovers_written_identifier_and_deletes_device(self):
        self.interrupt_creation({"TEST_IOS_HANG_CREATE": KINDS[0]})

    def test_term_during_creation_without_output_recovers_only_unique_owned_name(self):
        self.interrupt_creation({"TEST_IOS_HANG_CREATE_WITHOUT_OUTPUT": KINDS[0]})

    def test_term_during_creation_that_ignores_term_is_still_bounded(self):
        self.interrupt_creation({"TEST_IOS_HANG_CREATE": KINDS[0], "TEST_IOS_IGNORE_TERM": "YES"})

    def test_term_stops_active_command_descendants_and_deletes_owned_device(self):
        process = subprocess.Popen(["bash", "scripts/test-ios.sh"], cwd=self.root,
                                   env=dict(self.env, TEST_IOS_HANG_TEST="mock-" + KINDS[0]),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        deadline = time.monotonic() + 10
        child_pid = None
        while time.monotonic() < deadline:
            if self.trace.exists():
                child_pid = next((event[1] for event in self.events() if event[0] == "child"), None)
            if child_pid:
                break
            time.sleep(0.01)
        self.assertIsNotNone(child_pid, "the fake build never started its child")
        process.send_signal(signal.SIGTERM)
        output, errors = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 143, output + errors)
        self.assert_cleanup(KINDS[:1])
        self.assertNotIn(["create", KINDS[1]], self.events())
        # A killed descendant can be briefly retained as a zombie by the operating system.
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(child_pid)],
                               capture_output=True, text=True, timeout=5).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), "active child remains: " + state)


if __name__ == "__main__":
    unittest.main()
