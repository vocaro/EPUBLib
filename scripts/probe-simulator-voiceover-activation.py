#!/usr/bin/env python3
"""Compatibility entry point for #495's original experiment; uses the guarded runner."""
import importlib.util
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('simulator_probe', root / 'scripts/run-voiceover-simulator.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
if '--activation' not in sys.argv and 'EPUB495_OVERRIDE' in os.environ:
    sys.argv += ['--activation', 'cursor' if os.environ.get('EPUB495_OVERRIDE') == '1' else 'stock']
if '--runtime' not in sys.argv and os.environ.get('EPUB495_OVERRIDE') == '1':
    sys.argv += ['--runtime', probe.activation.RUNTIME]
sys.exit(probe.main())
