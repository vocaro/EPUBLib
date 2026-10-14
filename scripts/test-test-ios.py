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
    print("Executed 2 tests, with 0 failures", flush=True)
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

    def run_gate(self, **environment):
        result = subprocess.run(["bash", "scripts/test-ios.sh"], cwd=self.root,
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

    def test_stalled_boot_is_bounded_and_preserves_its_last_stage(self):
        result = self.run_gate(TEST_IOS_HANG_BOOT="mock-" + KINDS[0])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("bootstatus failed or exceeded 1s", result.stdout)
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
