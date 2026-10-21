#!/usr/bin/env python3
"""Check simulator transcript build revisions with fake tools; no simulator or build starts."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "run-voiceover-simulator.py"
STUB = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
name = Path(sys.argv[0]).name
if name == "xcodebuild":
    if args == ["-version"]:
        print("Xcode fake\nBuild version fake")
    elif "build-for-testing" in args:
        if os.environ.get("PROBE_BUILD_FAIL"):
            sys.exit(65)
        if os.environ.get("PROBE_BUILD_HANG"):
            time.sleep(30)
        derived = Path(args[args.index("-derivedDataPath") + 1])
        products = derived / "Build/Products"
        products.mkdir(parents=True, exist_ok=True)
        if not os.environ.get("PROBE_BUILD_NO_PRODUCTS"):
            (products / "VoiceOverProbeIOS_fake.xctestrun").touch()
    elif "test-without-building" in args:
        print("VOICEOVER_EVENT 2026-10-19T00:00:00.000Z finished: fake probe")
        print("Executed 1 test, with 0 failures")
        print("VOICEOVER_EVENT timestamp input_steps: " + os.environ["TEST_RUNNER_VOICEOVER_STEPS"])
        print("Test Case '-[VoiceOverProbeIOS.VoiceOverProbe testCaptureNavigation]' passed (0.1 seconds)")
    else:
        raise AssertionError(args)
elif name == "xcrun":
    if args == ["simctl", "list", "runtimes", "--json"]:
        # A recognized runtime name with an unrecognized build must fail closed even
        # when cursor dispatch was selected implicitly by the command-line default.
        print(json.dumps({"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                                        "buildversion": "unknown-build"}]}))
    elif args[:2] == ["simctl", "create"]:
        print("fake-owned-device")
    elif args[:2] in (["simctl", "boot"], ["simctl", "bootstatus"],
                     ["simctl", "shutdown"], ["simctl", "delete"]):
        assert args[2] == "fake-owned-device", args
    elif args[:3] in (["devicectl", "device", "settings"], ["devicectl", "device", "info"]):
        assert args[args.index("--device") + 1] == "fake-owned-device", args
        print(json.dumps({"result": {"volume": 0, "enabled": False}}))
    else:
        raise AssertionError(args)
elif name == "pgrep":
    sys.exit(1)
elif name != "xcodegen":
    raise AssertionError(name)
'''


class SimulatorBuildRevisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="epublib-simulator-revision-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPT.with_name("_engineering.py"), self.root / "scripts/_engineering.py")
        configuration = json.loads((SCRIPT.parent.parent / "engineering.json").read_text())
        configuration["toolkit"]["path"] = str((SCRIPT.parent.parent / configuration["toolkit"]["path"]).resolve())
        (self.root / "engineering.json").write_text(json.dumps(configuration))
        shutil.copyfile(SCRIPT, self.root / "scripts" / SCRIPT.name)
        shutil.copyfile(SCRIPT.with_name("simulator_voiceover_activation.py"), self.root / "scripts/simulator_voiceover_activation.py")
        shutil.copyfile(SCRIPT.with_name("probe-simulator-voiceover-activation.py"), self.root / "scripts/probe-simulator-voiceover-activation.py")
        generator = self.root / "scripts/make-voiceover-fixture.py"
        generator.touch()
        resources = self.root / "Examples/VoiceOverVerification/Resources"
        resources.mkdir(parents=True)
        (resources / "sample.epub").touch()
        self.source = self.root / "source.txt"
        self.source.write_text("initial source\n")
        self.git("init", "-q")
        self.git("add", "scripts", "source.txt")
        self.git("-c", "user.name=Probe Test", "-c", "user.email=probe@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "initial")
        self.original = self.revision()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for command in ["xcrun", "xcodebuild", "xcodegen", "pgrep"]:
            stub = self.bin / command
            stub.write_text(STUB)
            stub.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.env.pop("EPUB_SIM_RUNTIME", None)
        self.env.pop("EPUB495_OVERRIDE", None)
        self.derived = self.root / "derived"
        self.results = self.root / "results"
        self.record = self.derived / "voiceover-build-revision.txt"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def revision(self):
        return self.git("describe", "--always", "--dirty")

    def run_probe(self, *args, expected=0, mode="stock", entry=SCRIPT.name, **environment):
        result = subprocess.run([
            sys.executable, str(self.root / "scripts" / entry),
            "--derived-data", str(self.derived), "--results", str(self.results),
            "--device", "fake-device", *([] if mode is None else ["--activation", mode]), *args],
            env=dict(self.env, **environment), capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        if expected:
            return result.stdout
        transcript = max(self.results.glob("*.transcript.txt"), key=lambda path: path.stat().st_mtime_ns)
        text = transcript.read_text()
        self.assertIn("RESULT the probe passed", text)
        return text

    def assert_revisions(self, transcript, build, checkout):
        self.assertEqual([line.split(" BUILD ", 1)[1] for line in transcript.splitlines() if " BUILD " in line],
                         [f"{build}, Xcode fake Build version fake"])
        self.assertEqual([line.split(" CHECKOUT ", 1)[1] for line in transcript.splitlines() if " CHECKOUT " in line],
                         [checkout])

    def test_device_steps_are_recorded_and_sent_to_the_probe(self):
        text = self.run_probe('--steps', 'read', '--device-steps', 'fake-device=visible,wait=1')
        self.assertIn(' STEPS visible,wait=1', text)
        self.assertIn(' input_steps: visible,wait=1', text)
        self.run_probe('--device-steps', 'unrequested=read', expected=2)

    def test_default_pinned_runtime_refuses_an_unknown_build_before_building(self):
        self.assertIn("does not support this runtime/build", self.run_probe(mode=None, expected=125))
        self.assertFalse(self.record.exists())
        self.assertFalse(list(self.results.glob("*.transcript.txt")))

    def test_other_runtimes_default_to_stock_and_explicit_cursor_still_refuses(self):
        other = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        for args, environment in [(("--runtime", other), {}), ((), {"EPUB_SIM_RUNTIME": other})]:
            with self.subTest(args=args, environment=environment):
                text = self.run_probe(*args, mode=None, **environment)
                self.assertIn(other, text)
                self.assertIn("ACTIVATION stock (unmodified)", text)
        self.assertIn("does not support this runtime/build",
                      self.run_probe("--runtime", other, mode="cursor", expected=125))

    def test_explicit_stock_retains_the_pinned_runtime_without_injection(self):
        text = self.run_probe()
        self.assertIn("com.apple.CoreSimulator.SimRuntime.iOS-27-2", text)
        self.assertIn("ACTIVATION stock (unmodified)", text)

    def test_compatibility_entry_uses_default_but_retains_explicit_legacy_control(self):
        entry = "probe-simulator-voiceover-activation.py"
        self.assertIn("does not support this runtime/build",
                      self.run_probe(mode=None, entry=entry, expected=125))
        self.assertIn("ACTIVATION stock (unmodified)",
                      self.run_probe(mode=None, entry=entry, EPUB495_OVERRIDE="0"))

    def test_reused_build_keeps_revision_after_commit_and_dirty_edits(self):
        self.assert_revisions(self.run_probe(), self.original, self.original)
        self.assertEqual(self.record.read_text().strip(), self.original)
        self.source.write_text("committed later\n")
        self.git("add", "source.txt")
        self.git("-c", "user.name=Probe Test", "-c", "user.email=probe@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "later")
        self.assert_revisions(self.run_probe("--skip-build"), self.original, self.revision())
        self.source.write_text("uncommitted later\n")
        self.assert_revisions(self.run_probe("--skip-build"), self.original, self.revision())

    def test_dirty_build_is_recorded_and_kept_after_checkout_becomes_clean(self):
        self.source.write_text("experiment\n")
        dirty = self.revision()
        self.assertTrue(dirty.endswith("-dirty"))
        self.assert_revisions(self.run_probe(), dirty, dirty)
        self.git("restore", "source.txt")
        self.assert_revisions(self.run_probe("--skip-build"), dirty, self.original)

    def test_external_build_without_record_is_unknown(self):
        products = self.derived / "Build/Products"
        products.mkdir(parents=True)
        (products / "VoiceOverProbeIOS_external.xctestrun").touch()
        self.assert_revisions(self.run_probe("--skip-build"), "unknown", self.original)
        self.assertFalse(self.record.exists())

    def test_explicit_derived_data_reads_its_own_record(self):
        self.derived = self.root / "elsewhere"
        products = self.derived / "Build/Products"
        products.mkdir(parents=True)
        (products / "VoiceOverProbeIOS_external.xctestrun").touch()
        (self.derived / "voiceover-build-revision.txt").write_text("other-revision-dirty\n")
        self.assert_revisions(self.run_probe("--skip-build"), "other-revision-dirty", self.original)

    def test_empty_record_is_unknown(self):
        self.run_probe()
        self.record.write_text("\n")
        self.assert_revisions(self.run_probe("--skip-build"), "unknown", self.original)

    def test_failed_and_timed_out_rebuilds_remove_old_record(self):
        self.run_probe()
        for environment in [{"PROBE_BUILD_FAIL": "1"}, {"PROBE_BUILD_HANG": "1"}]:
            with self.subTest(environment=environment):
                self.record.write_text("stale-revision\n")
                self.run_probe("--build-timeout", "1", expected=125, **environment)
                self.assertFalse(self.record.exists())
                self.assert_revisions(self.run_probe("--skip-build"), "unknown", self.original)

    def test_success_without_products_does_not_record_revision(self):
        self.assertIn("No built probe", self.run_probe(expected=125, PROBE_BUILD_NO_PRODUCTS="1"))
        self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
