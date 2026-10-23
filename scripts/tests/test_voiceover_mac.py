"""Pure step/list checks, Safari preflight and the mac-foreground check; never start a speech session."""
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import Mock, patch

from support import SCRIPTS, ScriptTestCase
from _engineering import toolkit_location

REAL_RUN, REAL_POPEN = subprocess.run, subprocess.Popen
VOICEOVER_KEY = 96  # Command-F5, which turns VoiceOver on or off.


class VoiceOverMacTests(ScriptTestCase):
    def setUp(self):
        super().setUp()
        self.runner = self.module("run-voiceover-mac.py")
        self.no_commands = patch.object(self.runner.subprocess, "run", side_effect=AssertionError("Unexpected host command"))
        self.no_commands.start()
        self.addCleanup(self.no_commands.stop)
        processes = patch.object(self.runner.subprocess, "Popen", side_effect=AssertionError("Unexpected host process"))
        processes.start()
        self.addCleanup(processes.stop)

    def test_list_left_open_by_sent_keys(self):
        cases = [
            ([], None), (["rotor"], "rotor"), (["rotor", "listchoose"], "rotor"),
            (["rotor", "listclose"], None), (["actions"], "actions"),
            (["actions", "listdown", "listclose"], None),
            (["rotor", "listclose", "actions"], "actions"),
            (["actions", "listclose", "rotor", "listdown"], "rotor"),
            (["actions", "listclose", "in", "line"], None),
            (["in", "actions", "listchoose", "line"], "actions"),
            (["rotor", "actions", "listclose"], None),
        ]
        for sent, expected in cases:
            with self.subTest(sent=sent):
                self.assertEqual(self.runner.open_list(sent), expected)

    def test_labelled_list_and_observer_steps_do_not_hide_unknown_steps(self):
        steps = ["listchoose=Next Page", "actions", "listdown", "ax:actions", "ax:action=Next Page",
                 "bogus", "listfoo=1", "activate=Next Page"]
        self.assertEqual(self.runner.unknown(steps), ["bogus", "listfoo=1"])

    def test_safari_refuses_xctest_values_before_touching_an_app(self):
        with patch.object(self.runner.Path, "is_dir", return_value=True), \
                patch.object(sys, "argv", ["runner", "--safari", "--xctest-values"]), \
                redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(SystemExit) as exit:
                self.runner.main()
        self.assertEqual(exit.exception.code, 2)
        self.assertIn("would open the reader over Safari", errors.getvalue())

    def test_safari_requires_exactly_one_running_browser(self):
        for pids in ("", "123\n456\n"):
            with self.subTest(pids=pids), patch.object(self.runner.Path, "is_dir", return_value=True), \
                    patch.object(self.runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, pids)) as run, \
                    patch.object(sys, "argv", ["runner", "--safari"]), redirect_stderr(io.StringIO()) as errors:
                with self.assertRaises(SystemExit) as exit:
                    self.runner.main()
                self.assertEqual(exit.exception.code, 2)
                self.assertIn("Open Safari once", errors.getvalue())
                run.assert_called_once_with(["pgrep", "-x", "Safari"], capture_output=True, text=True)


def later(minutes):
    return (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()


class Later(datetime):
    """Two hours from now, past the end of the owner's approval."""

    @classmethod
    def now(cls, tz=None):
        return datetime.now(tz) + timedelta(hours=2)


class ForegroundReservationTests(ScriptTestCase):
    """On the owner's Mac no key goes out unless the session holds mac-foreground (#818).

    A whole session runs with VoiceOver, the probe and the observer stubbed, and keystroke records
    each key in place of sending it. The device record is a real one of the test's own.
    """

    def setUp(self):
        super().setUp()
        kit = toolkit_location(SCRIPTS.parent)
        sys.path.insert(0, str(kit / "src/python"))
        from vocaro_engineering import devices
        if not hasattr(devices, "require_foreground"):
            self.skipTest(f"the toolkit at {kit} predates mac-foreground (apple-engineering 521a95b); update it")
        self.devices = devices
        # The record refuses /private/tmp, which a restart empties, even when TMPDIR is there.
        base = Path(tempfile.gettempdir())
        if devices.restart_emptied(base):
            base = Path(REAL_RUN(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip())
        directory = tempfile.TemporaryDirectory(dir=base, prefix="epublib-device-record-")
        self.addCleanup(directory.cleanup)
        self.record_path = Path(directory.name) / "device-handoff.json"
        self.record = devices.Record(self.record_path)
        self.runner = self.module("run-voiceover-mac.py")
        (self.root / ".build/voiceover/mac/Build/Products/Debug/VoiceOverVerificationMac.app").mkdir(parents=True)
        (self.root / "Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj").mkdir(parents=True)
        self.results = self.root / "results"
        self.results.mkdir()
        # Newer than its source, so the observer is not compiled.
        observer = self.results / "voiceover-ax-observer"
        observer.touch()
        os.utime(observer, (2**32, 2**32))
        self.keys = []
        self.voiceover = False
        self.after_first_step = None
        for patcher in (patch.object(self.runner, "keystroke", side_effect=self.keystroke),
                        patch.object(self.runner, "enabled", side_effect=lambda: self.voiceover),
                        patch.object(self.runner, "keyboard_owner", return_value=self.runner.READER),
                        patch.object(self.runner.subprocess, "run", side_effect=self.host_command),
                        patch.object(self.runner.subprocess, "Popen", side_effect=self.start)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def keystroke(self, code, modifiers, times=1):
        self.keys.append(code)
        if code == VOICEOVER_KEY:
            self.voiceover = not self.voiceover
        elif self.after_first_step and len([key for key in self.keys if key != VOICEOVER_KEY]) == 1:
            self.after_first_step()

    def host_command(self, command, **options):
        if command[:2] == ["pgrep", "-x"]:
            return subprocess.CompletedProcess(command, 0, "4242\n" if command[2] == "VoiceOverVerificationMac" else "")
        if command[0] == "ps":  # The record reads the start of a process it recorded.
            return REAL_RUN(command, **options)
        raise AssertionError(f"Unexpected host command: {command}")

    def start(self, command, stdout=None, **options):
        """The probe has its first phrase in its log as soon as it starts; it and the observer end when asked."""
        if command[0] in ("ps", sys.executable):  # The record's ps, through subprocess.run, and the test's sleeper.
            return REAL_POPEN(command, stdout=stdout, **options)
        if command[0] == "xcodebuild":
            stdout.write("VOICEOVER_EVENT 2026-10-23T00:00:00.000Z heard: VoiceOver on Verification Reader\n")
            stdout.flush()
        elif command[0] != str(self.results / "voiceover-ax-observer"):
            raise AssertionError(f"Unexpected host process: {command}")
        return Mock(pid=4243, args=command, poll=Mock(return_value=0), wait=Mock(return_value=0))

    def hold(self, owner="session-a"):
        return self.record.reserve(self.devices.FOREGROUND, owner=owner, revision=0, purpose="attended Mac speech capture",
                                   release_by=later(30), approval={"by": "owner", "at": later(-1), "until": later(60)})

    def session(self, owner="session-a", **environment):
        """Run the steps in and line; the exit status, or the SystemExit's message, and what it printed."""
        variables = {"VOCARO_DEVICE_RECORD": str(self.record_path), **environment}
        if owner:
            variables["VOCARO_DEVICE_OWNER"] = owner
        with patch.dict(os.environ, variables), redirect_stdout(io.StringIO()) as output, \
                patch.object(sys, "argv", ["runner", "--results", str(self.results), "--pause", "0", "in", "line"]):
            # As on the owner's Mac, whatever runs the tests.
            for name in ("RUNNER_ENVIRONMENT", "VOCARO_DEVICE_OWNER"):
                if name not in variables:
                    os.environ.pop(name, None)
            try:
                return self.runner.main(), output.getvalue()
            except SystemExit as stop:
                return stop.code, output.getvalue()

    def sleeper(self):
        """A process of the test's own, for the record to see running and then gone."""
        child = REAL_POPEN([sys.executable, "-c", "import time; time.sleep(60)"])
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        return child

    def change(self, **changes):
        entry = self.record.entry(self.devices.FOREGROUND)
        self.record.update(self.devices.FOREGROUND, owner="session-a", revision=entry["revision"], **changes)

    def uncertain(self):
        self.change(state="restoration-unverified")

    def reset(self):
        self.record_path.unlink(missing_ok=True)
        self.keys.clear()
        self.voiceover = False
        self.after_first_step = None

    IN, LINE = 125, 37  # The steps' keys.

    def test_a_held_reservation_lets_every_key_through(self):
        self.hold()
        status, output = self.session()
        self.assertEqual(status, 0, output)
        self.assertEqual(self.keys, [VOICEOVER_KEY, self.IN, self.LINE, VOICEOVER_KEY])

    def test_refuses_before_its_first_key(self):
        def orphaned():
            self.hold()
            child = self.sleeper()
            self.change(state="testing", activeRun=True, hostProcessIdentifier=child.pid)
            child.kill()
            child.wait()

        cases = [
            ("nobody holds it", lambda: None, {}, "nobody holds mac-foreground"),
            ("another session holds it", lambda: self.hold(owner="session-b"), {}, "held by session-b"),
            ("no session is named", self.hold, {"owner": None}, "name the session"),
            ("it is orphaned", orphaned, {}, "mac-foreground is orphan"),
            ("it is uncertain", lambda: (self.hold(), self.uncertain()), {}, "mac-foreground is uncertain"),
            ("the approval has ended",
             lambda: (self.hold(), stack.enter_context(patch.object(self.devices, "datetime", Later))), {}, "ended"),
        ]
        for name, arrange, options, reason in cases:
            with self.subTest(name):
                with ExitStack() as stack:
                    self.reset()
                    arrange()
                    status, output = self.session(**options)
                self.assertIn("Refused before the first key", str(status))
                self.assertIn(reason, str(status))
                self.assertEqual(self.keys, [], output)

    def test_stops_before_the_next_key_and_only_restores(self):
        child = None

        def run():
            nonlocal child
            child = self.sleeper()
            self.change(state="testing", activeRun=True, hostProcessIdentifier=child.pid)

        def release():
            entry = self.record.entry(self.devices.FOREGROUND)
            self.record.release(self.devices.FOREGROUND, owner="session-a", revision=entry["revision"],
                                outcome="ended early", restoration="VoiceOver off", frontmost="restored")

        cases = [
            ("the session released it", lambda: None, release, "nobody holds mac-foreground"),
            ("it became uncertain", lambda: None, self.uncertain, "mac-foreground is uncertain"),
            ("it became orphaned", run, lambda: (child.kill(), child.wait()), "mac-foreground is orphan"),
            ("the approval ended", lambda: None,
             lambda: stack.enter_context(patch.object(self.devices, "datetime", Later)), "ended"),
        ]
        for name, arrange, change, reason in cases:
            with self.subTest(name):
                with ExitStack() as stack:
                    self.reset()
                    self.hold()
                    arrange()
                    self.after_first_step = change
                    status, output = self.session()
                self.assertEqual(status, 125, output)
                self.assertIn("Refused before line", output)
                self.assertIn(reason, output)
                # VoiceOver on and the first step's key; after the refusal only VoiceOver back off.
                self.assertEqual(self.keys, [VOICEOVER_KEY, self.IN, VOICEOVER_KEY], output)

    def test_a_hosted_run_needs_no_reservation(self):
        status, output = self.session(owner=None, RUNNER_ENVIRONMENT="github-hosted")
        self.assertEqual(status, 0, output)
        self.assertEqual(self.keys, [VOICEOVER_KEY, self.IN, self.LINE, VOICEOVER_KEY])
