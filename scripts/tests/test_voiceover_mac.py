"""Pure step/list checks and Safari preflight; never start a speech session."""
from contextlib import redirect_stderr
import io
import subprocess
import sys
from unittest.mock import patch

from support import ScriptTestCase


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
