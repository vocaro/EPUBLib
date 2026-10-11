#!/usr/bin/env python3
"""Build and run the isolated native Mac Search-focus regression."""
import argparse
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-window-focus", action="store_true",
                        help="Acknowledge permission for brief qualification-window focus")
    parser.add_argument("--escape", action="store_true", help="Dismiss the first Search with Escape")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This probe requires macOS")
    if not args.allow_window_focus:
        parser.error("Explicit --allow-window-focus is required")
    repo = pathlib.Path(__file__).resolve().parents[2]
    swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    subprocess.run([swift, "build", "--product", "SearchFocusProbe"], cwd=repo, check=True)
    binaries = pathlib.Path(subprocess.check_output([swift, "build", "--show-bin-path"], cwd=repo, text=True).strip())
    with tempfile.TemporaryDirectory(prefix="epublib-search-focus-") as temporary:
        contents = pathlib.Path(temporary) / "SearchFocusProbe.app" / "Contents"
        executable = contents / "MacOS" / "SearchFocusProbe"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binaries / "SearchFocusProbe", executable)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.epublib.qualification.search-focus",
            "CFBundleName": "EPUBLib Search Focus Qualification",
            "CFBundleExecutable": "SearchFocusProbe", "CFBundlePackageType": "APPL",
            "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "27.0",
        }))
        command = [str(executable)] + (["--escape"] if args.escape else [])
        try:
            return subprocess.run(command, timeout=90).returncode
        except subprocess.TimeoutExpired:
            print("FAIL: qualification process exceeded 90 seconds", file=sys.stderr)
            return 2


if __name__ == "__main__":
    raise SystemExit(main())
