#!/usr/bin/env python3
"""Small project adapter. The implementation lives in the shared engineering checkout."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
# _engineering.py finds the toolkit, from a worktree too.
sys.path.insert(0, str(root / "scripts"))
try:
    from _engineering import toolkit_location
    toolkit = toolkit_location(root)
    if not (toolkit / "src/python/vocaro_engineering/cli.py").is_file():
        raise ValueError(f"Shared toolkit missing at {toolkit}. Clone vocaro/apple-engineering beside this project's main checkout or set VOCARO_ENGINEERING_ROOT.")
    sys.path.insert(0, str(toolkit / "src/python"))
    from vocaro_engineering.cli import main
    raise SystemExit(main(["--project", str(root), *sys.argv[1:]]))
except (OSError, ValueError) as error:
    print(f"eng: {error}", file=sys.stderr)
    raise SystemExit(2)
