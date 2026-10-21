#!/usr/bin/env python3
"""Project adapter for the maintained shared engineering implementation."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from _engineering import load

load(globals(), 'src/python/vocaro_engineering/voiceover/hosted_run.py')
