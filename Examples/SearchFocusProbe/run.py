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
    parser.add_argument("--results-keyboard", action="store_true",
                        help="Check native result-list selection, row activation and dismissal focus")
    parser.add_argument("--temporarily-enable-keyboard-navigation", action="store_true",
                        help="Acknowledge approval to restore the original system setting afterward")
    args = parser.parse_args()
    if args.results_keyboard and not args.temporarily_enable_keyboard_navigation:
        parser.error("Result-list traversal requires --temporarily-enable-keyboard-navigation")
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
        if args.results_keyboard:
            command.append("--results-keyboard")
        original = subprocess.run(["defaults", "read", "-g", "AppleKeyboardUIMode"],
                                  capture_output=True, text=True)
        try:
            if args.temporarily_enable_keyboard_navigation:
                subprocess.run(["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "3"], check=True)
            try:
                return subprocess.run(command, timeout=90).returncode
            except subprocess.TimeoutExpired:
                print("FAIL: qualification process exceeded 90 seconds", file=sys.stderr)
                return 2
        finally:
            if args.temporarily_enable_keyboard_navigation:
                if original.returncode == 0:
                    subprocess.run(["defaults", "write", "-g", "AppleKeyboardUIMode", "-int",
                                    original.stdout.strip()], check=True)
                else:
                    subprocess.run(["defaults", "delete", "-g", "AppleKeyboardUIMode"], check=True)


if __name__ == "__main__":
    raise SystemExit(main())
