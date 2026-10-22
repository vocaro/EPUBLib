#!/usr/bin/env python3
"""Keep marked documentation snippets identical to the compiled example code. --write regenerates.

The shared check this adds to: https://github.com/vocaro/apple-engineering/blob/main/guides/maintenance.md#documentation-checks
"""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument("--write", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
snippets = {}
for source in (root / "Examples/VoiceOverVerification/Shared").glob("*.swift"):
    for name, code in re.findall(r"// snippet:start (\w+)\n(.*?)// snippet:end \1", source.read_text(), re.S):
        assert name not in snippets, f"Duplicate snippet {name}"
        snippets[name] = code.rstrip()
checked = 0
for doc in [root / "README.md", *sorted((root / "doc").glob("*.md"))]:
    original = doc.read_text()
    def replace(match):
        global checked
        name = match[1]
        assert name in snippets, f"Unknown snippet {name} in {doc}"
        checked += 1
        return f"<!-- snippet:{name} -->\n```swift\n{snippets[name]}\n```\n<!-- /snippet -->"
    updated = re.sub(r"<!-- snippet:(\w+) -->\n```swift\n.*?\n```\n<!-- /snippet -->", replace, original, flags=re.S)
    if args.write:
        if updated != original:
            doc.write_text(updated)
    else:
        assert updated == original, f"Stale snippet in {doc}; run scripts/check-docs.py --write"
assert checked >= 2, "Expected navigation and lifecycle examples"
print(f"Verified {checked} snippets against compiled Swift sources.")
