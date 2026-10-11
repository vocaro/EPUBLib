#!/usr/bin/env python3
"""Run the isolated Mac speech probe with a deadline and restore VoiceOver state.

Build and normally launch the verification reader first; see doc/voiceover-testing.md.
This script never changes the VoiceOver AppleScript setting or the clipboard.
"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import signal
import subprocess
import time


def enabled():
    result = subprocess.run(
        ["defaults", "read", "com.apple.universalaccess", "voiceOverOnOffKey"],
        capture_output=True, text=True, timeout=5)
    value = result.stdout.strip()
    if result.returncode or value not in ("0", "1"):
        raise RuntimeError("Cannot determine the original VoiceOver state; aborting")
    return value == "1"


def toggle():
    subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to key code 96 using {command down}'],
        check=True, timeout=5)


def set_state(desired):
    if enabled() != desired:
        toggle()
    deadline = time.monotonic() + 5
    while enabled() != desired:
        if time.monotonic() >= deadline:
            raise RuntimeError("VoiceOver did not reach the requested state; check it manually")
        time.sleep(0.25)


def stop(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGINT)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, default=root / ".build/voiceover/mac")
    parser.add_argument("--results", type=Path, default=root / ".build/voiceover/results")
    parser.add_argument("--timeout", type=int, default=150)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300:
        parser.error("--timeout must be between 1 and 300 seconds")
    app = args.derived_data / "Build/Products/Debug/VoiceOverVerificationMac.app"
    project = root / "Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj"
    if not app.is_dir() or not project.is_dir():
        parser.error("Generate and build the signed verification project first")
    running = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to return exists process "VoiceOverVerificationMac"'],
        check=True, capture_output=True, text=True, timeout=5)
    if running.stdout.strip() != "true":
        parser.error("Normally launch exactly one verification reader before running this probe")
    args.results.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    bundle = args.results / f"mac-{stamp}.xcresult"
    log_path = args.results / f"mac-{stamp}.log"
    original = enabled()
    process = None
    try:
        set_state(True)
        with log_path.open("w") as log:
            process = subprocess.Popen([
                "xcodebuild", "-project", str(project), "-scheme", "VoiceOverProbeMac",
                "-destination", "platform=macOS", "-derivedDataPath", str(args.derived_data),
                "-resultBundlePath", str(bundle),
                "-only-testing:VoiceOverProbeMac/VoiceOverProbe/testCaptureNavigation",
                "test-without-building"], stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True)
            try:
                return process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                print("Probe deadline reached; stopping this test process group.")
                return 124
    finally:
        try:
            if process is not None:
                stop(process)
        finally:
            set_state(original)
            print(f"VoiceOver restored to {'on' if original else 'off'}.")
            print(f"Log: {log_path}\nResult bundle: {bundle}")


if __name__ == "__main__":
    raise SystemExit(main())
