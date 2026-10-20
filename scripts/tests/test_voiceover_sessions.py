"""Session validation and orchestration, with applications, clock and probe stubbed."""
from contextlib import redirect_stdout
import io
import os
import subprocess
import sys
from unittest.mock import patch

from support import ScriptTestCase


class SessionSettingsTests(ScriptTestCase):
    def check(self, steps="", **settings):
        return self.run_script("run-voiceover-sessions.py", "--check", VOICEOVER_STEPS=steps,
                               **{f"VOICEOVER_{key.upper()}": value for key, value in settings.items()})

    def test_mixed_settings_and_commands(self):
        cases = [
            ("width=600 text_size=17 ax:next ax:focus in line ; ax:next ax:focus in line ; "
             "flow=scrolled width=600 ax:next ax:focus in line", {},
             ["600 wide at 17 points, paginated", "1100 wide at 23 points, paginated",
              "600 wide at 23 points, scrolled"]),
            ("width=600 text_size=17 ; text_size=17 ; pause=3", {"width": "900"},
             ["600 wide at 17 points", "900 wide at 17 points", "900 wide at 23 points, paginated, 3 s pause"]),
            ("advance_after=0.5 pause=4 in line\nadvance_after= in line\nin line", {"advance_after": "0.25"},
             ["next key 0.5 s after a phrase", "--pause 5 ax:width=1100 in line",
              "next key 0.25 s after a phrase"]),
            ("text_size=17.5 flow=paginated width=0600 'activate=Next Page' in", {},
             ["600 wide at 17.5 points", "'activate=Next Page' in"]),
            ('"launch=-SampleHref OPS/labels.xhtml" width=600 ax:links in ; in line ; launch= in ; '
             '"launch=-VerificationBook \'two words\'" pause=3 in', {"launch": "-SampleHref OPS/other.xhtml"},
             ["-SampleHref OPS/labels.xhtml", "-SampleHref OPS/other.xhtml", "-VerificationBook 'two words'"]),
        ]
        for steps, settings, expected in cases:
            with self.subTest(steps=steps):
                result = self.check(steps, **settings)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                for text in expected:
                    self.assertIn(text, result.stdout)

    def test_invalid_sessions_are_one_line_refusals(self):
        cases = [
            ("width=wide in line", {}, "width must be a number"),
            ("in line ; width=600.5 in", {}, "Session 2: width must be a number"),
            ("in ; in ; text_size=-3 in", {}, "Session 3: text_size must be a number"),
            ("flow=sideways in", {}, "flow must be paginated or scrolled"),
            ("pause=long in", {}, "pause must be a number"),
            ("advance_after=-1 in", {}, "advance_after must be a number"),
            ("width= in", {}, "width must be a number"),
            ("text_size= in", {}, "text_size must be a number"),
            ("in line width=600 nextline", {}, "follows a step"),
            ("width=600 width=700 in", {}, "width is given twice"),
            ("in ; flow=scrolled", {}, "give the steps of a continuous-scroll session"),
            ("flow=scrolled", {"flow": "paginated"}, "give the steps of a continuous-scroll session"),
            ("text_size=17 ; width=600", {"flow": "scrolled"}, "give the steps of a continuous-scroll session"),
            ("widht=600 in", {}, "Unknown steps: widht=600"),
            ("width=100000 in", {}, "width must be a number"),
            ("text_size=nan in", {}, "text_size must be a number"),
            ('"launch=-SampleHref \'OPS" in', {}, "No closing quotation"),
            ("in line launch=-X", {}, "follows a step"),
            ("'in", {}, "VOICEOVER_STEPS: No closing quotation"),
            (" ; \n ; ", {}, "VOICEOVER_STEPS holds no step"),
        ]
        for steps, settings, message in cases:
            with self.subTest(steps=steps, settings=settings):
                result = self.check(steps, **settings)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
                self.assertIn(message, result.stderr)

    def test_safari_beside_reader_has_its_own_options(self):
        result = self.check("safari=OPS/grids.xhtml width=600 pause=4 in line ; in line",
                            launch="-SampleHref OPS/labels.xhtml", flow="scrolled", text_size="30")
        self.assertEqual(result.returncode, 0, result.stderr)
        safari, reader = result.stdout.splitlines()
        self.assertEqual(safari, "Session 1: Safari at OPS/grids.xhtml, 600 wide, 4 s pause; ; "
                         "--pause 4 --safari ax:width=600 in line")
        self.assertIn("1100 wide at 30 points, scrolled, -SampleHref OPS/labels.xhtml", reader)

    def test_safari_refuses_reader_settings_non_fixture_paths_and_no_steps(self):
        cases = [(f"safari=OPS/grids.xhtml {setting} in", "is the reader's")
                 for setting in ("flow=scrolled", "text_size=17", "launch=-X")]
        cases += [(f"safari={path} in", "must be a section of the fixture")
                  for path in ("/etc/passwd", "OPS/../secret.xhtml", "OPS/grids.xhtml/extra")]
        cases += [("safari=OPS/grids.xhtml", "give the steps of a session of Safari")]
        for steps, message in cases:
            with self.subTest(steps=steps):
                result = self.check(steps)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)


class SessionRunTests(ScriptTestCase):
    def setUp(self):
        super().setUp()
        self.sessions = self.module("run-voiceover-sessions.py")
        self.sessions.RESULTS = self.root / "results"
        self.summary = self.root / "summary.md"
        self.launched, self.safari, self.ran = [], [], []

    def run_sessions(self, steps, codes, until=None, write_transcript=True):
        def run(arguments, **kwargs):
            self.assertEqual(arguments[:2], [sys.executable, str(self.scripts / "run-voiceover-mac.py")])
            self.assertEqual(kwargs, {})
            self.ran.append(arguments[2:])
            if write_transcript:
                stamp = f"mac-20261013-000000-{len(self.ran):06}"
                (self.sessions.RESULTS / f"{stamp}.transcript.txt").write_text(
                    "2026-10-13T00:00:00.000Z STEP in\n"
                    "2026-10-13T00:00:01.000Z heard: Chapter one\n"
                    "2026-10-13T00:00:01.500Z STATE WINDOW 600x850 TEXTCOUNT 1\n")
            return subprocess.CompletedProcess(arguments, codes[len(self.ran) - 1])

        environment = dict(self.env, VOICEOVER_STEPS=steps, GITHUB_STEP_SUMMARY=str(self.summary))
        argv = ["run-voiceover-sessions.py"] + (["--until", str(until)] if until else [])
        with patch.dict(os.environ, environment, clear=True), patch.object(sys, "argv", argv), \
                patch.object(self.sessions, "fresh_reader", side_effect=lambda *args: self.launched.append(args)), \
                patch.object(self.sessions, "fresh_safari", side_effect=lambda *args: self.safari.append(args)), \
                patch.object(self.sessions.subprocess, "run", side_effect=run), \
                patch.object(self.sessions.time, "time", side_effect=lambda: 1500 if len(self.ran) >= 3 else 1000), \
                redirect_stdout(io.StringIO()):
            return self.sessions.main()

    def test_mixed_run_records_failure_summary_and_unrun_session(self):
        status = self.run_sessions('width=600 text_size=17 "launch=-SampleHref OPS/labels.xhtml" in line ; '
                                   'in line ; flow=scrolled pause=3 advance_after=0.5 ax:next in ; text_size=30 in',
                                   [0, 124, 0], until=1400)
        self.assertEqual(status, 1)
        self.assertEqual(self.launched, [
            (["-SampleFlow", "paginated", "-SampleFontSize", "17", "-SampleHref", "OPS/labels.xhtml"], False),
            (["-SampleFlow", "paginated", "-SampleFontSize", "23"], False),
            (["-SampleFlow", "scrolled", "-SampleFontSize", "23"], False)])
        self.assertEqual(self.ran, [
            ["--timeout", "300", "--pause", "5", "ax:width=600", "in", "line"],
            ["--timeout", "300", "--pause", "5", "ax:width=1100", "in", "line"],
            ["--timeout", "300", "--pause", "3", "--advance-after", "0.5", "ax:width=1100", "ax:next", "in"]])
        lines = (self.sessions.RESULTS / "sessions.txt").read_text().splitlines()
        self.assertEqual(len(lines), 4)
        for number in range(3):
            self.assertIn(f"mac-20261013-000000-{number + 1:06}.transcript.txt", lines[number])
        self.assertIn("ended early or reached its deadline (exit 124)", lines[1])
        self.assertIn("30 points", lines[3])
        self.assertIn("not run, because the job's time was used up; no transcript", lines[3])
        summary = self.summary.read_text()
        self.assertIn("STEP in", summary)
        self.assertIn("heard: Chapter one", summary)
        self.assertNotIn("STATE WINDOW", summary)
        self.assertIn("Session 4:", summary)
        self.assertIn("not run, because the job's time was used up", summary)

    def test_safari_ownership_is_passed_to_later_sessions(self):
        status = self.run_sessions("in ; safari=OPS/grids.xhtml width=600 pause=4 in ; in ; safari=OPS/labels.xhtml in",
                                   [0, 0, 0, 0])
        self.assertEqual(status, 0)
        self.assertEqual([safari for _, safari in self.launched], [False, True])
        self.assertEqual(self.safari, [("OPS/grids.xhtml", 2, False), ("OPS/labels.xhtml", 4, True)])
        self.assertEqual(self.ran[1], ["--timeout", "300", "--pause", "4", "--safari", "ax:width=600", "in"])

    def test_runner_failure_without_transcript_is_kept(self):
        status = self.run_sessions("in", [126], write_transcript=False)
        self.assertEqual(status, 1)
        record = (self.sessions.RESULTS / "sessions.txt").read_text()
        self.assertIn("VoiceOver not restored (exit 126)", record)
        self.assertIn("no transcript", record)

    def test_fresh_safari_refuses_workstation_before_any_side_effect(self):
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(self.sessions, "closed") as closed, \
                patch.object(self.sessions.shutil, "rmtree") as remove, \
                patch.object(self.sessions.subprocess, "run") as run:
            with self.assertRaisesRegex(SystemExit, "hosted runner only"):
                self.sessions.fresh_safari("OPS/grids.xhtml", 1, False)
            closed.assert_not_called()
            remove.assert_not_called()
            run.assert_not_called()

    def test_closed_quits_safari_only_after_this_job_opened_it(self):
        for owned in (False, True):
            with self.subTest(owned=owned), patch.object(self.sessions, "running", return_value=False), \
                    patch.object(self.sessions, "quit_safari", return_value=True) as quit_safari, \
                    patch.object(self.sessions.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run, \
                    patch.object(self.sessions.time, "sleep"):
                self.sessions.closed(owned)
                run.assert_called_once_with(["pkill", "-x", "VoiceOverVerificationMac"])
                self.assertEqual(quit_safari.call_count, int(owned))
