#!/usr/bin/env python3
"""Run the isolated Mac speech probe with a deadline and restore VoiceOver state.

Build and normally launch the verification reader first; see doc/voiceover-testing.md.
Steps are VoiceOver commands sent while the probe records speech, or `ax:STEP` for a
step of scripts/voiceover-ax-observer.swift such as `ax:focus` or `ax:next`.
`activate=LABEL` presses the item in the VoiceOver cursor only if VoiceOver just named it.
The steps, speech and observer events are merged by time into one transcript.
This script never changes the VoiceOver AppleScript setting or the clipboard.
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import signal
import subprocess
import time

# VoiceOver commands as (key code, with Shift), all with Control-Option.
COMMANDS = {
    "in": (125, True), "out": (126, True), "right": (124, False), "left": (123, False),
    "line": (37, False), "nextline": (125, False), "previousline": (126, False),
    "word": (13, False), "firstword": (115, False), "lastword": (119, False),
    "textstart": (115, True), "textend": (119, True), "readall": (0, False), "activate": (49, False),
    "linecount": (99, False)}
TWICE = {"linecount"}  # Control-Option-F3 twice reads the total and visible line counts.
READER_KEYS = {"pagedown": 121, "pageup": 116}  # The reader's own keys, without modifiers.


def enabled():
    result = subprocess.run(
        ["defaults", "read", "com.apple.universalaccess", "voiceOverOnOffKey"],
        capture_output=True, text=True, timeout=5)
    value = result.stdout.strip()
    if result.returncode or value not in ("0", "1"):
        raise RuntimeError("Cannot determine the original VoiceOver state; aborting")
    return value == "1"


def keystroke(code, modifiers, times=1):
    subprocess.run(
        ["osascript"] + ["-e", f'tell application "System Events" to key code {code} using {{{modifiers}}}'] * times,
        check=True, timeout=5)


def set_state(desired):
    if enabled() != desired:
        keystroke(96, "command down")
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


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def keyboard_owner():
    """The frontmost application, or a password dialog holding secure keyboard input over it."""
    registry = subprocess.run(["ioreg", "-l", "-w", "0", "-d", "1"], capture_output=True, text=True, timeout=5).stdout
    if "kCGSSessionSecureInputPID" in registry:
        return "a secure text field"
    return subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to return bundle identifier of '
         'first application process whose frontmost is true'],
        capture_output=True, text=True, timeout=5).stdout.strip()


def phrases(log_path):
    """The time and text of each phrase the probe has recorded, in order."""
    return [line.split(" ", 3)[1::2] for line in log_path.read_text(errors="replace").splitlines()
            if line.startswith("VOICEOVER_EVENT ") and line.split(" ", 3)[2:3] == ["heard:"]]


def other_tests():
    """Unit-test hosts of other sessions: VoiceOver announces their windows and menus too."""
    return subprocess.run(["pgrep", "-x", "xctest"], capture_output=True, text=True).stdout.split()


def main():
    root = Path(__file__).resolve().parents[1]
    source = root / "scripts/voiceover-ax-observer.swift"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, default=root / ".build/voiceover/mac")
    parser.add_argument("--results", type=Path, default=root / ".build/voiceover/results")
    parser.add_argument("--timeout", type=int, default=150)
    parser.add_argument("--pause", type=float, default=5, help="seconds of speech to record after each step")
    parser.add_argument("--advance-after", type=float, metavar="SECONDS",
                        help="send the next step this long after a key's first new phrase, and wait "
                             "--pause only when none is recorded; later phrases of that key are cut short")
    parser.add_argument("--xctest-values", action="store_true", help="also record XCTest's snapshot of each column")
    parser.add_argument("steps", nargs="*", metavar="STEP",
                        help=f"ax:STEP or one of {', '.join(list(COMMANDS) + list(READER_KEYS))}")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300:
        parser.error("--timeout must be between 1 and 300 seconds")
    unknown = [step for step in args.steps
               if step.split("=")[0] not in COMMANDS and step not in READER_KEYS and not step.startswith("ax:")]
    if unknown:
        parser.error(f"Unknown steps: {' '.join(unknown)}")
    app = args.derived_data / "Build/Products/Debug/VoiceOverVerificationMac.app"
    project = root / "Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj"
    if not app.is_dir() or not project.is_dir():
        parser.error("Generate and build the signed verification project first")
    readers = subprocess.run(["pgrep", "-x", "VoiceOverVerificationMac"], capture_output=True, text=True).stdout.split()
    if len(readers) != 1:
        parser.error("Normally launch exactly one verification reader before running this probe")
    args.results.mkdir(parents=True, exist_ok=True)
    # Compiled once, so each ax: step acts immediately.
    observer = [str(args.results / "voiceover-ax-observer")]
    if not os.path.exists(observer[0]) or os.path.getmtime(observer[0]) < source.stat().st_mtime:
        subprocess.run(["xcrun", "swiftc", "-O", str(source), "-o", observer[0]], check=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    bundle = args.results / f"mac-{stamp}.xcresult"
    log_path = args.results / f"mac-{stamp}.log"
    events_path = args.results / f"mac-{stamp}.ax.log"
    transcript = [f"{now()} OTHER_TESTS {pid}" for pid in other_tests()]
    if args.advance_after is not None:
        transcript.append(f"{now()} ADVANCE {args.advance_after:g} s after a new phrase, or after {args.pause:g} s")
    finished = args.results / f"mac-{stamp}.finished"
    environment = dict(os.environ, TEST_RUNNER_VOICEOVER_STOP=str(finished))
    if args.xctest_values:
        environment["TEST_RUNNER_VOICEOVER_SNAPSHOTS"] = "1"
    deadline = time.monotonic() + args.timeout
    original = enabled()
    process = watcher = None
    try:
        set_state(True)
        with log_path.open("w") as log, events_path.open("w") as events:
            # One observer sees every event of the session and performs the ax: steps in order.
            watcher = subprocess.Popen(observer + [readers[0], str(args.timeout), "-"], stdin=subprocess.PIPE,
                                       stdout=events, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            process = subprocess.Popen([
                "xcodebuild", "-project", str(project), "-scheme", "VoiceOverProbeMac",
                "-destination", "platform=macOS", "-derivedDataPath", str(args.derived_data),
                "-resultBundlePath", str(bundle),
                "-only-testing:VoiceOverProbeMac/VoiceOverProbe/testCaptureNavigation",
                "test-without-building"], stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True, env=environment)
            try:
                # The probe records once attached; commands sent earlier would go unheard.
                while "VOICEOVER_EVENT" not in log_path.read_text(errors="replace"):
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise subprocess.TimeoutExpired(process.args, args.timeout)
                    time.sleep(0.5)
                time.sleep(args.pause)
                for step in args.steps:
                    transcript.append(f"{now()} STEP {step}")
                    if step.startswith("ax:"):
                        done = events_path.read_text(errors="replace").count(" STEPPED ")
                        watcher.stdin.write(step[3:] + "\n")
                        watcher.stdin.flush()
                        while events_path.read_text(errors="replace").count(" STEPPED ") == done:
                            if watcher.poll() is not None or time.monotonic() >= deadline:
                                raise subprocess.TimeoutExpired(watcher.args, args.timeout)
                            time.sleep(0.1)
                    else:
                        # Another controller may have taken the keyboard; never send it VoiceOver commands.
                        owner = keyboard_owner()
                        if owner != "org.epubreaderlib.voiceoververify.mac":
                            raise RuntimeError(f"Keyboard focus went to {owner} before {step}; session stopped")
                        name, _, label = step.partition("=")
                        if label and not any(label in text for _, text in phrases(log_path)[-2:]):
                            raise RuntimeError(f"VoiceOver did not name {label} before {step}; session stopped")
                        sent = now()
                        if name in READER_KEYS:
                            keystroke(READER_KEYS[name], "")
                        else:
                            code, shift = COMMANDS[name]
                            keystroke(code, "control down, option down" + (", shift down" if shift else ""),
                                      2 if name in TWICE else 1)
                        if args.advance_after is None:
                            time.sleep(args.pause)
                            continue
                        # A phrase equal to the one before it is not recorded again; such a key waits out the pause.
                        limit = time.monotonic() + args.pause
                        while time.monotonic() < limit and not any(
                                heard >= sent and not text.startswith("ERROR ") for heard, text in phrases(log_path)):
                            time.sleep(0.05)
                        time.sleep(max(0, min(args.advance_after, limit - time.monotonic())))
                finished.touch()
                return process.wait(timeout=max(1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                print("The probe ended early or its deadline was reached; stopping this session.")
                return 124
            except RuntimeError as error:
                print(error)
                return 125
    finally:
        try:
            for child in (process, watcher):
                if child is not None:
                    stop(child)
        finally:
            set_state(original)
            print(f"VoiceOver restored to {'on' if original else 'off'}.")
            finished.unlink(missing_ok=True)
            transcript += [f"{now()} OTHER_TESTS {pid}" for pid in other_tests()]
            if log_path.exists():
                transcript += [line.removeprefix("VOICEOVER_EVENT ") for line in
                               log_path.read_text(errors="replace").splitlines() if line.startswith("VOICEOVER_EVENT ")]
            if events_path.exists():
                # What the reader reported and exposed, beside what VoiceOver said about it.
                kinds = (" EVENT AXValueChanged", " EVENT AXLayoutChanged", " STATE", " LINE", " PRESS", " RESIZE", " FOCUS", " MISSING")
                transcript += [line for line in events_path.read_text(errors="replace").splitlines() if line[24:].startswith(kinds)]
            transcript_path = args.results / f"mac-{stamp}.transcript.txt"
            transcript_path.write_text("\n".join(sorted(transcript)) + "\n")
            print(f"Transcript: {transcript_path}\nObserver events: {events_path}\nLog: {log_path}\nResult bundle: {bundle}")


if __name__ == "__main__":
    raise SystemExit(main())
