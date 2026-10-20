#!/usr/bin/env python3
"""Run the activation guard regressions; also included by scripts/check-all.sh."""
from pathlib import Path
import unittest

suite = unittest.defaultTestLoader.discover(str(Path(__file__).with_name('tests')),
                                          pattern='test_simulator_voiceover_activation.py')
raise SystemExit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
