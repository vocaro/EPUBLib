#!/usr/bin/env python3
"""The activation lane must reject missing evidence and unknown runtime binaries."""
import json
import importlib.util
from contextlib import redirect_stdout
from io import StringIO
from types import SimpleNamespace
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import simulator_voiceover_activation as activation

MARKED = "vot[1:abc] (cursor.dylib) " + activation.MARKER


class ActivationGuards(unittest.TestCase):
    def test_missing_hook_or_canary_cannot_pass(self):
        self.assertEqual(len(activation.evidence_failures('', '')), 2)
        self.assertEqual(len(activation.evidence_failures('VOICEOVER_ACTIVATION_CHECK passed:', '')), 1)
        self.assertEqual(len(activation.evidence_failures('', MARKED)), 1)
        self.assertFalse(activation.evidence_failures('VOICEOVER_ACTIVATION_CHECK passed:', MARKED))
        self.assertTrue(activation.evidence_failures('VOICEOVER_ACTIVATION_CHECK passed:', MARKED + '\nEPUB495: refused'))

    def test_every_restarted_voiceover_process_must_confirm_the_hook(self):
        log = 'VOICEOVER_ACTIVATION_CHECK passed:'
        self.assertFalse(activation.evidence_failures(log, MARKED))
        self.assertTrue(activation.evidence_failures(log, MARKED + '\nvot[2:def] restarted'))
        self.assertFalse(activation.evidence_failures(log, MARKED + '\nvot[2:def] ' + activation.MARKER))

    def test_unknown_build_stops_before_compilation_or_injection(self):
        calls = []
        def run(*command, **options):
            calls.append(command)
            return json.dumps({'runtimes': [{'identifier': activation.RUNTIME, 'buildversion': 'future-build'}]})
        with self.assertRaisesRegex(RuntimeError, 'runtime/build'):
            activation.prepare(Path('.'), Path('.'), activation.RUNTIME, run)
        self.assertEqual(len(calls), 1)

    def test_changed_binary_stops_before_compilation_or_injection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'System/Library/CoreServices/VoiceOverTouch.app/vot'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'changed executable')
            calls = []
            def run(*command, **options):
                calls.append(command)
                return json.dumps({'runtimes': [{'identifier': activation.RUNTIME, 'buildversion': activation.BUILD, 'runtimeRoot': str(root)}]})
            with self.assertRaisesRegex(RuntimeError, 'SHA-256'):
                activation.prepare(root, root, activation.RUNTIME, run)
            self.assertEqual(len(calls), 1)


class RunnerEvidence(unittest.TestCase):
    def test_runner_rejects_zero_tests_or_missing_hook_evidence(self):
        spec = importlib.util.spec_from_file_location('simulator_runner', Path(__file__).resolve().parents[1] / 'run-voiceover-simulator.py')
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = SimpleNamespace(log=root / 'run.log', vot=root / 'vot.log', recovered=[],
                activation=True, process=object(), note=None, late=False, udid='owned-device',
                started=None, finished=None, unmuted=[], unread=[], transcript=[], kind='test',
                bundle=root / 'result.xcresult', stream=None)
            passed = ("Test Case '-[VoiceOverProbe testCaptureNavigation]' passed (1.0 seconds)\n"
                      'VOICEOVER_EVENT timestamp finished: all 1 steps\n')
            session.log.write_text(passed + 'Executed 0 tests, with 0 failures\n')
            session.vot.write_text('')
            state = lambda *args: {'enabled': False, 'volume': 0}
            with patch.object(runner, 'state', state), redirect_stdout(StringIO()):
                self.assertNotEqual(runner.report(session), 0)
                session.log.write_text(passed + 'Executed 1 test, with 0 failures\n')
                self.assertNotEqual(runner.report(session), 0)
                session.vot.write_text(MARKED)
                self.assertNotEqual(runner.report(session), 0)
                session.log.write_text(passed + 'Executed 1 test, with 0 failures\nVOICEOVER_ACTIVATION_CHECK passed:\n')
                self.assertEqual(runner.report(session), 0)


if __name__ == '__main__':
    unittest.main()
